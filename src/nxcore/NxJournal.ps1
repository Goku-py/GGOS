#Requires -Version 5.1
<#
    NxJournal.ps1 - NEXTRIX State Journal (sole rollback authority, ADR-006).

    Mutation surface of this module: ONLY the journal directory passed to it
    (%ProgramData%\NEXTRIX\Journal on target machines; self-tests use a temp path).
    It never reads or writes any Windows configuration itself except read-only
    registry capture helpers provided here for the apply pipeline.

    Semantics (validated against reference research, docs/RESEARCH_RECONCILIATION.md):
    - Capture-refusal:  never treat an already-NEXTRIX-tweaked state as "original".
    - Only-if-ours:      rollback restores only if current == recorded modified state.
    - Integrity chain:   each entry hash = SHA256(prevHash + canonical entry + seq).
    - No secrets:        journal stores configuration states only.
#>

function Get-NxSha256Hex {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Initialize-NxJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Force
    )
    $manifestPath = Join-Path $Path 'manifest.json'
    $entriesPath  = Join-Path $Path 'journal.jsonl'
    $rearmReason  = $null
    if (Test-Path $manifestPath) {
        $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $restoredMarker = $null
        if ($existing.PSObject.Properties['restoredVerifiedUtc']) { $restoredMarker = [string]$existing.restoredVerifiedUtc }
        if ($existing.captureStatus -eq 'Complete' -and -not $restoredMarker -and -not $Force) {
            # Capture-refusal (stacking detection): an existing journal means this
            # machine state is not pristine stock. Refuse to re-arm silently.
            return [pscustomobject]@{
                created = $false; path = $Path
                reason  = 'CAPTURE_REFUSAL_EXISTING_JOURNAL'
                manifest = $existing
            }
        }
        # Re-arm path: a verified full restore (restoredVerifiedUtc) or -Force.
        # The old entries file is ARCHIVED so audit history survives the reset.
        if (Test-Path $entriesPath) {
            $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
            Move-Item -Path $entriesPath -Destination (Join-Path $Path ("journal.$stamp.jsonl")) -Force -ErrorAction SilentlyContinue
        }
        $rearmReason = 'REARMED_AFTER_VERIFIED_RESTORE'
    }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
    $manifest = [ordered]@{
        schemaVersion = 1
        journalVersion = '1.1'
        createdAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        captureStatus  = 'Complete'
        entries        = 0
        lastHash       = 'GENESIS'
        journalPath    = $entriesPath
    }
    if (-not (Test-Path $entriesPath)) { New-Item -Path $entriesPath -ItemType File | Out-Null }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8
    return [pscustomobject]@{ created = $true; path = $Path; reason = $rearmReason; manifest = $manifest }
}

function Read-NxManifest {
    param([Parameter(Mandatory)][string]$Path)
    $manifestPath = Join-Path $Path 'manifest.json'
    if (-not (Test-Path $manifestPath)) {
        return [pscustomobject]@{ present = $false }
    }
    $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    return [pscustomobject]@{ present = $true; manifest = $m }
}

function Save-NxManifest {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Manifest)
    $manifestPath = Join-Path $Path 'manifest.json'
    $tmp = "$manifestPath.tmp"
    $Manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $manifestPath -Force
}

# Read-only capture of a registry value's exact current state (never writes).
function Capture-NxRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    $descriptor = [ordered]@{
        targetType = 'registry'
        path       = $Path
        name       = $Name
        keyExisted = $false
        existed    = $false
        kind       = $null
        value      = $null
    }
    if (-not (Test-Path $Path)) { return [pscustomobject]$descriptor }
    $descriptor.keyExisted = $true
    $key = Get-Item -Path $Path -ErrorAction SilentlyContinue
    if ($null -eq $key) { return [pscustomobject]$descriptor }
    $raw = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($null -eq $raw) { return [pscustomobject]$descriptor }
    $descriptor.existed = $true
    $descriptor.kind    = $key.GetValueKind($Name).ToString()
    $descriptor.value   = $raw
    return [pscustomobject]$descriptor
}

# Appends one journal entry. Single append per apply/rollback step (atomic per line).
function Add-NxJournalEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TweakId,
        [Parameter(Mandatory)][string]$TweakVersion,
        [ValidateSet('apply','rollback','skip','verify','failed')][Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Approval,
        [Parameter(Mandatory)]$Original,
        [Parameter(Mandatory)]$Modified,
        [string]$Result = 'Success',
        [string]$Verification = 'NotRun',
        [string]$ErrorInfo = '',
        [string[]]$Profiles = @()
    )
    $mtx = New-Object System.Threading.Mutex($false, 'Local\NEXTRIX_Journal_v1')
    $null = $mtx.WaitOne(15000)
    try {
        $state = Read-NxManifest -Path $Path
        if (-not $state.present) { throw "Journal not initialized at $Path" }
        $manifest = $state.manifest
        $seq = [int]$manifest.entries + 1
        $entry = [ordered]@{
            seq          = $seq
            # Integer timestamp by design: JSON date-like strings are silently
            # converted to DateTime by ConvertFrom-Json and re-serialize lossily,
            # breaking the integrity chain (~1/10 writes). See STATE_JOURNAL.md.
            tsUtcUnixMs  = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            tweakId      = $TweakId
            tweakVersion = $TweakVersion
            operation    = $Operation
            approval     = $Approval
            profiles     = $Profiles
            original     = $Original
            modified     = $Modified
            result       = $Result
            verification = $Verification
            errorInfo    = $ErrorInfo
        }
        $canonical = ($entry | ConvertTo-Json -Depth 8 -Compress)
        $entry.hash = Get-NxSha256Hex ("$($manifest.lastHash)|$seq|$canonical")
        $entry | ConvertTo-Json -Depth 8 -Compress | Add-Content -Path (Join-Path $Path 'journal.jsonl') -Encoding UTF8
        $manifest.entries  = $seq
        $manifest.lastHash = $entry.hash
        Save-NxManifest -Path $Path -Manifest $manifest
        return [pscustomobject]@{ seq = $seq; hash = $entry.hash }
    } finally {
        $null = $mtx.ReleaseMutex(); $mtx.Dispose()
    }
}

# Reads the journal and verifies the integrity chain end-to-end.
function Read-NxJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $entriesPath = Join-Path $Path 'journal.jsonl'
    $state = Read-NxManifest -Path $Path
    if (-not $state.present) { return [pscustomobject]@{ integrityErrors = @(); entries = @(); manifestPresent = $false } }
    $result = $null
    # Two attempts with fresh, permissively-shared file reads: a transient partial
    # read (AV scanning, concurrent I/O) must not be misreported as tampering.
    # A real modification fails deterministically on every attempt.
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $read = @()
        if (Test-Path $entriesPath) {
            $text = ''
            try { $text = [System.IO.File]::ReadAllText($entriesPath, [System.Text.Encoding]::UTF8) } catch { }
            if ($text.Length -gt 0) {
                $read = @($text -split "\r?\n" | Where-Object { $_.Trim().Length -gt 0 })
            } else {
                $read = @()
            }
        }
        $entries = New-Object System.Collections.Generic.List[object]
        $errors = New-Object System.Collections.Generic.List[string]
        $expectedPrev = 'GENESIS'
        foreach ($line in $read) {
            try {
                $e = $line | ConvertFrom-Json
                $storedHash = $e.hash
                $clone = [ordered]@{}
                foreach ($p in $e.PSObject.Properties) {
                    if ($p.Name -ne 'hash') { $clone[$p.Name] = $p.Value }
                }
                $canonical = ($clone | ConvertTo-Json -Depth 8 -Compress)
                $expected = Get-NxSha256Hex ("$expectedPrev|$($e.seq)|$canonical")
                if ($expected -ne $storedHash) { $errors.Add("seq $($e.seq): integrity mismatch") }
                $expectedPrev = $storedHash
                $entries.Add($e)
            } catch {
                $errors.Add("unparseable journal line: $($_.Exception.Message)")
            }
        }
        if ($entries.Count -ne [int]$state.manifest.entries) {
            $errors.Add("manifest count $($state.manifest.entries) != journal lines $($entries.Count)")
        }
        $result = [pscustomobject]@{ integrityErrors = $errors; entries = $entries; manifestPresent = $true; manifest = $state.manifest }
        if ($errors.Count -eq 0) { break }
        if ($attempt -lt 2) { Start-Sleep -Milliseconds 200 }
    }
    return $result
}

# Only-if-ours predicate: does the live state still equal what we recorded writing?
function Test-NxCurrentEqualsDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Descriptor,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Value
    )
    if (-not $Descriptor.existed) { return $false }
    if ($Descriptor.kind -ne $Kind) { return $false }
    $a = ConvertTo-Json -InputObject $Descriptor.value -Depth 6 -Compress
    $b = ConvertTo-Json -InputObject $Value -Depth 6 -Compress
    return ($a -eq $b)
}

# Marks the journal as verified-restored (re-arms capture per ADR design).
function Complete-NxJournalRestore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $state = Read-NxManifest -Path $Path
    if ($state.present) {
        $m = $state.manifest
        $m | Add-Member -NotePropertyName restoredVerifiedUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        Save-NxManifest -Path $Path -Manifest $m
    }
}
