#Requires -Version 5.1
<#
    NX16.ps1 - Maintenance & Recovery engine functions
    (registry entries NX16-001..011 and NX16-017; NX16-012..016 live in NxBuild/NxRollback).

    Dependencies (must be dot-sourced before use; see Import-NxCore):
        NxJournal.ps1   - Get-NxSha256Hex, Initialize-NxJournal, Capture-NxRegistryValue,
                          Add-NxJournalEntry, Read-NxJournal, Test-NxCurrentEqualsDescriptor
        NxVerify.ps1    - Test-NxConfigurationState
        NxBuild.ps1     - Get-NxBuildReport
        NxHardware.ps1  - Get-NxHardwareReport
        NxRollback.ps1  - Restore-NxRegistryOriginal (safe-stop recovery only)

    Mutation surface (SECURITY_POLICY section 4 - this module never exceeds it):
        Enable-NxSystemRestore    - the two policy values DisableSR/DisableConfig under
                                    HKLM\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore
                                    (removed only-if-present, journaled before change) plus
                                    Enable-ComputerRestore on the system drive.
                                    SystemRestorePointCreationFrequency is NEVER touched here
                                    (that override belongs to Checkpoint-NxSystem).
        Checkpoint-NxSystem       - SystemRestorePointCreationFrequency (temporarily 0,
                                    restored only-if-ours) + one restore point via
                                    Checkpoint-Computer. NEVER deletes restore points or
                                    shadow copies (restore-point honesty model,
                                    docs/RESEARCH_RECONCILIATION.md adopt #13).
        Export-NxRegistryTargets  - backup files only (reg.exe export is read-only).
        Export-NxServiceState    - backup files only (reads HKLM\SYSTEM\CurrentControlSet
                                    \Services, never writes it; no ControlSet001/002 access).
        Export-NxTaskState        - backup files only.
        Invoke-NxPreFlight        - journal directory + backup files + read-only queries;
                                    the capture gate callers use before any mutation.
        Invoke-NxDismHealth       - read-only by default; /RestoreHealth ONLY via -Repair
                                    (owner-initiated).
        Invoke-NxSfcVerify        - read-only (sfc /verifyonly); repair is never automatic
                                    and never executed by NEXTRIX (r6 contrast documented).
        Invoke-NxComponentCleanup - plan-only by default; DISM StartComponentCleanup runs
                                    ONLY via -Execute. /ResetBase is NEVER emitted
                                    (policy - WinUtil rejected pattern, r5).
        Get-NxDriverInventory     - strictly read-only.
        Invoke-NxDriverStoreClean  - enumeration + pre-list export only; deletes ONLY
                                    packages explicitly named via -ConfirmPackage, orphan-
                                    only, NEVER /force; deletion honestly labeled NOT
                                    journal-reversible (journal result 'Success-Irreversible'
                                    deliberately never matches Invoke-NxRollback's
                                    operation='apply' result='Success' candidate filter).
        Export-NxSupportBundle    - one zip at the owner-chosen path + temp staging;
                                    read-only queries; machine identifiers scrubbed from
                                    all text content; journal values excluded by design.

    Hard rules honored:
        - PowerShell 5.1 syntax only (no ternary, no ??).
        - CurrentControlSet only; never-touch services are only ever READ here.
        - No secrets in any artifact; support bundle scrubs identifiers (SECURITY_POLICY 3).
        - Host capability honesty (SynToolkit r4): cmdlets missing from the current host
          (e.g. System Restore cmdlets under non-desktop hosts) produce explicit
          CmdletUnavailable results, never silent success.
#>

# ============================================================================
# Internal helpers (no mutation anywhere in this section)
# ============================================================================

function Test-NxElevated {
    [CmdletBinding()]
    param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NxCommandIfExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-NxStamp {
    # Filesystem-safe local timestamp for backup-set folder names.
    return (Get-Date -Format 'yyyyMMdd-HHmmss')
}

function Get-NxDefaultBackupRoot {
    [CmdletBinding()]
    param()
    return (Join-Path $env:ProgramData 'NEXTRIX\Backups')
}

function New-NxBackupSetPath {
    [CmdletBinding()]
    param(
        [string]$Root,
        [string]$Stamp
    )
    if (-not $Root) { $Root = Get-NxDefaultBackupRoot }
    if (-not $Stamp) { $Stamp = Get-NxStamp }
    return (Join-Path $Root $Stamp)
}

function Get-NxNonOverwritingPath {
    # Atlas first-backup-kept pattern (r2): an existing artifact is never overwritten.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir  = Split-Path -Parent $Path
    $base = [IO.Path]::GetFileNameWithoutExtension($Path)
    $ext  = [IO.Path]::GetExtension($Path)
    $n = 2
    while (Test-Path -LiteralPath (Join-Path $dir "$base-$n$ext")) { $n++ }
    return (Join-Path $dir "$base-$n$ext")
}

function New-NxStep {
    param([int]$Seq, [string]$Name, [string]$Outcome, [string]$Detail)
    return [pscustomobject][ordered]@{ step = $Seq; name = $Name; outcome = $Outcome; detail = $Detail }
}

function Convert-NxToDateTime {
    # Honest multi-format datetime conversion: DateTime passthrough, WMI DMTF strings
    # (yyyymmddHHmmss.xxxxxx+zzz), and best-effort parse. Never guessed on failure: $null.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    $s = [string]$Value
    if ($s.Trim().Length -eq 0) { return $null }
    if ($s -match '^\d{14}\.') {
        try { return [System.Management.ManagementDateTimeConverter]::ToDateTime($s) } catch { }
        if ($s -match '^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})') {
            return [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6])
        }
    }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($s, [ref]$parsed)) { return $parsed }
    return $null
}

function Find-NxProtectingRestorePoint {
    # PURE predicate for the Windows 24h restore-point throttle honesty model: given the
    # enumerated restore points, is one of them newer than -WithinHours? Returns the newest
    # such point (or $null when nothing protects the machine). Testable with mocked sequences.
    [CmdletBinding()]
    param(
        [object[]]$Points = @(),
        [double]$WithinHours = 24,
        [datetime]$AsOf = (Get-Date)
    )
    $best = $null; $bestCt = $null; $unparseable = 0
    foreach ($p in @($Points)) {
        if ($null -eq $p) { continue }
        $ct = Convert-NxToDateTime $p.CreationTime
        if ($null -eq $ct) { $unparseable++; continue }
        # Negative age (clock skew / future point) still counts as protecting.
        if ($AsOf.Subtract($ct).TotalHours -le $WithinHours) {
            if ($null -eq $best -or $ct -gt $bestCt) { $best = $p; $bestCt = $ct }
        }
    }
    return [pscustomobject][ordered]@{ point = $best; unparseableCount = $unparseable }
}

function Convert-NxToRegExePath {
    # Accepts provider form (HKLM:\SOFTWARE\Foo) or reg.exe form (HKLM\SOFTWARE\Foo).
    # Returns $null for anything that is not a registry hive path.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.Trim()
    if ($p -match '^(HKLM|HKCU|HKCR|HKU|HKCC):\\(.*)$') { return ($Matches[1] + '\' + $Matches[2]) }
    if ($p -match '^(HKLM|HKCU|HKCR|HKU|HKCC)\\') { return $p }
    return $null
}

function Convert-NxToProviderPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.Trim()
    if ($p -match '^(HKLM|HKCU|HKCR|HKU|HKCC):\\') { return $p }
    if ($p -match '^(HKLM|HKCU|HKCR|HKU|HKCC)\\(.*)$') { return ($Matches[1] + ':\' + $Matches[2]) }
    return $p
}

function Get-NxSafeFileName {
    # Filesystem-safe, collision-resistant name for an arbitrary registry/task path.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$Maxlength = 180
    )
    $safe = ($Text -replace '[:\\/ ]', '_') -replace '[^A-Za-z0-9._\-]', '_'
    if ($safe.Length -gt $Maxlength) {
        $h = (Get-NxSha256Hex $Text).Substring(0, 8)
        $safe = $safe.Substring(0, $Maxlength) + '-' + $h
    }
    return $safe
}

function Read-NxRegFileHeader {
    # reg.exe writes UTF-16LE .reg files. Validates the "Windows Registry Editor" header
    # line; returns $null when the file is not a readable .reg (honest, never guessed).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($enc in @('Unicode', 'UTF8', 'Default')) {
        try {
            $first = @(Get-Content -LiteralPath $Path -TotalCount 1 -Encoding $enc)[0]
            if ($first -and $first -match 'Windows Registry Editor') { return $first }
        } catch { continue }
    }
    return $null
}

function Write-NxJsonFile {
    # Non-overwriting JSON writer (first backup never overwritten, Atlas r2 pattern).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 8
    )
    $target = Get-NxNonOverwritingPath -Path $Path
    $Object | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $target -Encoding UTF8
    return $target
}

function Remove-NxMachineIdentifiers {
    # PURE scrubber (testable on sample text): redacts machine identifiers from text.
    # Literal identifiers (longest first, case-insensitive) plus always-on pattern
    # classes: local SIDs, MAC addresses, serial-labeled values, UUID/machine-id labels.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string[]]$ComputerNames = @(),
        [string[]]$UserNames = @(),
        [string[]]$Identifiers = @()
    )
    $out = $Text
    $redactions = New-Object System.Collections.Generic.List[object]

    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($c in @($ComputerNames)) {
        if ($c -and $c.Trim().Length -ge 2) { $pairs.Add((New-Object psobject -Property @{ pat = [regex]::Escape($c.Trim()); repl = 'COMPUTERNAME-REDACTED'; kind = 'computerName' })) }
    }
    foreach ($u in @($UserNames)) {
        if ($u -and $u.Trim().Length -ge 2) { $pairs.Add((New-Object psobject -Property @{ pat = [regex]::Escape($u.Trim()); repl = 'USERNAME-REDACTED'; kind = 'userName' })) }
    }
    foreach ($i in @($Identifiers)) {
        if ($i -and $i.Trim().Length -ge 4) { $pairs.Add((New-Object psobject -Property @{ pat = [regex]::Escape($i.Trim()); repl = 'IDENTIFIER-REDACTED'; kind = 'identifier' })) }
    }
    # Longest literals first so DOMAIN\user is replaced before its computer-name substring.
    $sorted = @($pairs | Sort-Object { $_.pat.Length } -Descending)
    foreach ($p in $sorted) {
        $count = [regex]::Matches($out, $p.pat, 'IgnoreCase').Count
        if ($count -gt 0) {
            $out = [regex]::Replace($out, $p.pat, $p.repl, 'IgnoreCase')
            $redactions.Add((New-Object psobject -Property @{ kind = $p.kind; count = $count }))
        }
    }

    $patternRules = @(
        (New-Object psobject -Property @{ kind = 'sid';    pat = 'S-1-5-21-\d{1,10}(-\d{1,10}){2,3}'; repl = 'SID-REDACTED' }),
        (New-Object psobject -Property @{ kind = 'mac';    pat = '\b(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b'; repl = 'MAC-REDACTED' }),
        (New-Object psobject -Property @{ kind = 'serial'; pat = '(?i)(serial\s*(?:number)?\s*[:=]\s*)(\S{3,})'; repl = '$1REDACTED' }),
        (New-Object psobject -Property @{ kind = 'machineId'; pat = '(?i)("(?:uuid|machineguid|machine\s*id|identifyingnumber)"\s*[:=]\s*")([^"]{4,})(")'; repl = '$1REDACTED$3' })
    )
    foreach ($r in $patternRules) {
        $count = [regex]::Matches($out, $r.pat, 'IgnoreCase').Count
        if ($count -gt 0) {
            $out = [regex]::Replace($out, $r.pat, $r.repl, 'IgnoreCase')
            $redactions.Add((New-Object psobject -Property @{ kind = $r.kind; count = $count }))
        }
    }
    return [pscustomobject][ordered]@{ text = $out; redactions = $redactions.ToArray() }
}

function Get-NxMachineIdentifierCandidates {
    # READ-ONLY collection of the live machine's identifiers (for scrubbing).
    # Any single query failure is recorded as uncertainty - never guessed, never fatal.
    [CmdletBinding()]
    param()
    $computerNames = @(); $userNames = @(); $other = @(); $unc = @()
    $junk = @('to be filled by o.e.m.','to be filled by o.e.m','unknown','none','n/a','not specified','not available','default string','system serial number','no asset tag','asset tag','chassis manufacture','chassis manufacturer','o.e.m','tbd','tba','empty','xxxxxxxx')

    if ($env:COMPUTERNAME) { $computerNames += $env:COMPUTERNAME }
    if ($env:USERNAME) { $userNames += $env:USERNAME }
    if ($env:USERDOMAIN) { $userNames += $env:USERDOMAIN; $userNames += ($env:USERDOMAIN + '\' + $env:USERNAME) }

    $wimQueries = @(
        @{ cls = 'Win32_BIOS';                   props = @('SerialNumber') },
        @{ cls = 'Win32_ComputerSystemProduct';  props = @('IdentifyingNumber', 'UUID') },
        @{ cls = 'Win32_BaseBoard';              props = @('SerialNumber') },
        @{ cls = 'Win32_SystemEnclosure';        props = @('SerialNumber') },
        @{ cls = 'Win32_ComputerSystem';         props = @('Name', 'Domain') },
        @{ cls = 'Win32_DiskDrive';              props = @('SerialNumber') }
    )
    foreach ($q in $wimQueries) {
        try {
            $instances = @(Get-CimInstance -ClassName $q.cls -ErrorAction Stop)
            foreach ($inst in $instances) {
                foreach ($pr in @($q.props)) {
                    $v = $inst.$pr
                    if (-not $v) { continue }
                    $sv = ([string]$v).Trim()
                    if ($sv.Length -lt 4) { continue }
                    if ($junk -contains $sv.ToLower()) { continue }
                    if ($sv -match '^0+$') { continue }
                    if ($pr -eq 'Name') { $computerNames += $sv } else { $other += $sv }
                }
            }
        } catch { $unc += ($q.cls + ' read failed: ' + [string]$_.Exception.Message) }
    }
    try {
        foreach ($nic in @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -ErrorAction Stop)) {
            if ($nic.MACAddress) { $other += ([string]$nic.MACAddress).Trim() }
        }
    } catch { $unc += ('Win32_NetworkAdapterConfiguration read failed: ' + [string]$_.Exception.Message) }

    $dedupe = @{}
    $computerNames = @($computerNames | Where-Object { $v = $_.Trim(); $v.Length -ge 2 -and -not $dedupe.ContainsKey($v.ToLower()) -and ($dedupe[$v.ToLower()] = $true) })
    $dedupe = @{}
    $userNames = @($userNames | Where-Object { $v = $_.Trim(); $v.Length -ge 2 -and -not $dedupe.ContainsKey($v.ToLower()) -and ($dedupe[$v.ToLower()] = $true) })
    $dedupe = @{}
    $other = @($other | Where-Object { $v = $_.Trim(); $v.Length -ge 4 -and -not $dedupe.ContainsKey($v.ToLower()) -and ($dedupe[$v.ToLower()] = $true) })
    return [pscustomobject][ordered]@{ computerNames = $computerNames; userNames = $userNames; otherIdentifiers = $other; uncertainty = $unc }
}

function Write-NxScrubbedTextFile {
    # Writes text content through the scrubber; returns the redaction records.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string[]]$ComputerNames = @(),
        [string[]]$UserNames = @(),
        [string[]]$Identifiers = @()
    )
    $scrubbed = Remove-NxMachineIdentifiers -Text $Text -ComputerNames $ComputerNames -UserNames $UserNames -Identifiers $Identifiers
    Set-Content -LiteralPath $Path -Value $scrubbed.text -Encoding UTF8
    return $scrubbed.redactions
}

# ============================================================================
# NX16-001 - System Restore enablement
# ============================================================================

function Enable-NxSystemRestore {
    <#
        Enables System Restore protection on the system drive.
        - Removes DisableSR/DisableConfig policy values ONLY if present; each is captured
          (Capture-NxRegistryValue) and journaled (Add-NxJournalEntry) BEFORE the change.
        - Then Enable-ComputerRestore on the system drive.
        - SystemRestorePointCreationFrequency is NOT touched here (Checkpoint-NxSystem owns it).
        -Plan performs the read-only captures and reports intent; it never journals, never mutates.
        Journal-first invariant: a step that cannot journal does not mutate.
    #>
    [CmdletBinding()]
    param(
        [string]$JournalPath,
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [string]$SystemDrive,
        [switch]$Plan
    )
    if (-not $SystemDrive) { $SystemDrive = "$env:SystemDrive\" }
    $steps = @(); $seq = 0
    $policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
    $removals = @()

    if (-not $Plan) {
        if (-not $JournalPath) { throw 'Enable-NxSystemRestore: real application requires -JournalPath (journal-first invariant)' }
        if (-not (Test-NxElevated)) {
            $steps += New-NxStep 1 'elevation' 'Failed' 'elevation required: Enable-ComputerRestore and policy removal need an administrator engine'
            return [pscustomobject][ordered]@{ functionName = 'Enable-NxSystemRestore'; plan = $false; approval = $Approval; systemDrive = $SystemDrive; removedPolicyValues = @(); steps = $steps; allSucceeded = $false; frequencyNotTouchedByThisFunction = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
        }
    }

    foreach ($pv in @('DisableSR', 'DisableConfig')) {
        $seq++
        $cap = Capture-NxRegistryValue -Path $policyKey -Name $pv
        if (-not $cap.existed) {
            $steps += New-NxStep $seq "policy-$pv" 'Complete' "value absent - no change needed (idempotent)"
            continue
        }
        if ($Plan) {
            $steps += New-NxStep $seq "policy-$pv" 'Planned' "would remove $policyKey :: $pv (current $($cap.kind):$($cap.value))"
            continue
        }
        $modified = [pscustomobject][ordered]@{ targetType = 'registry'; path = $policyKey; name = $pv; kind = [string]$cap.kind; action = 'RemoveValue' }
        try {
            # Journal BEFORE any mutation (NxApply steps 7 pattern).
            $null = Add-NxJournalEntry -Path $JournalPath -TweakId 'NX16-001' -TweakVersion '1' -Operation 'apply' -Approval $Approval -Original $cap -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
            Remove-ItemProperty -Path $policyKey -Name $pv -ErrorAction Stop
            $check = Test-NxConfigurationState -Path $policyKey -Name $pv -Kind ([string]$cap.kind) -ExpectedValue $null
            if ($check.verified) {
                $null = Add-NxJournalEntry -Path $JournalPath -TweakId 'NX16-001' -TweakVersion '1' -Operation 'verify' -Approval $Approval -Original $cap -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles $Profiles
                $steps += New-NxStep $seq "policy-$pv" 'Complete' "removed (was $($cap.kind):$($cap.value)); verified absent"
                $removals += $pv
            } else {
                # Safe stop + immediate best-effort restore of the exact original (NxApply pattern).
                $null = Restore-NxRegistryOriginal -Entry ([pscustomobject]@{ original = $cap })
                $null = Add-NxJournalEntry -Path $JournalPath -TweakId 'NX16-001' -TweakVersion '1' -Operation 'failed' -Approval $Approval -Original $cap -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo ([string]$check.reason) -Profiles $Profiles
                $steps += New-NxStep $seq "policy-$pv" 'Failed' ([string]$check.reason)
                return [pscustomobject][ordered]@{ functionName = 'Enable-NxSystemRestore'; plan = $false; approval = $Approval; systemDrive = $SystemDrive; removedPolicyValues = $removals; steps = $steps; allSucceeded = $false; frequencyNotTouchedByThisFunction = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
            }
        } catch {
            $null = Add-NxJournalEntry -Path $JournalPath -TweakId 'NX16-001' -TweakVersion '1' -Operation 'failed' -Approval $Approval -Original $cap -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
            $steps += New-NxStep $seq "policy-$pv" 'Failed' ([string]$_.Exception.Message)
            return [pscustomobject][ordered]@{ functionName = 'Enable-NxSystemRestore'; plan = $false; approval = $Approval; systemDrive = $SystemDrive; removedPolicyValues = $removals; steps = $steps; allSucceeded = $false; frequencyNotTouchedByThisFunction = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
        }
    }

    $seq++
    if ($Plan) {
        $steps += New-NxStep $seq 'enable-protection' 'Planned' "would run Enable-ComputerRestore -Drive '$SystemDrive'"
    } elseif ($null -eq (Get-NxCommandIfExists 'Enable-ComputerRestore')) {
        $steps += New-NxStep $seq 'enable-protection' 'Failed' 'Enable-ComputerRestore unavailable in this host (requires the Windows PowerShell 5.1 engine)'
    } else {
        try {
            Enable-ComputerRestore -Drive $SystemDrive -ErrorAction Stop
            $steps += New-NxStep $seq 'enable-protection' 'Complete' "Enable-ComputerRestore completed without error on $SystemDrive"
        } catch {
            $steps += New-NxStep $seq 'enable-protection' 'Failed' ([string]$_.Exception.Message)
            return [pscustomobject][ordered]@{ functionName = 'Enable-NxSystemRestore'; plan = $false; approval = $Approval; systemDrive = $SystemDrive; removedPolicyValues = $removals; steps = $steps; allSucceeded = $false; frequencyNotTouchedByThisFunction = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
        }
    }

    # Record-what-the-PC-shows (adopt #21): post-state probe is informational evidence,
    # not a guessed verdict. Fresh enablement may have zero points and that is not an error.
    $seq++
    $probeNote = 'not probed (plan mode)'
    if (-not $Plan) {
        $gcrp = Get-NxCommandIfExists 'Get-ComputerRestorePoint'
        if ($null -eq $gcrp) { $probeNote = 'Get-ComputerRestorePoint unavailable in this host' }
        else {
            try { $pts = @(Get-ComputerRestorePoint -ErrorAction Stop); $probeNote = "enumerable: $($pts.Count) point(s) exist" }
            catch { $probeNote = 'not enumerable: ' + [string]$_.Exception.Message + ' (fresh enablement or service state - verify on target hardware)' }
        }
    }
    $steps += New-NxStep $seq 'post-state-probe' 'Complete' $probeNote

    $failedSteps = @($steps | Where-Object { $_.outcome -eq 'Failed' })
    return [pscustomobject][ordered]@{
        functionName = 'Enable-NxSystemRestore'
        plan = [bool]$Plan.IsPresent
        approval = $Approval
        systemDrive = $SystemDrive
        removedPolicyValues = $removals
        steps = $steps
        allSucceeded = ($failedSteps.Count -eq 0)
        frequencyNotTouchedByThisFunction = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ============================================================================
# NX16-002 - Pre-apply restore point ritual
# ============================================================================

function Checkpoint-NxSystem {
    <#
        The pre-apply restore point ritual (SynToolkit/UltraOS honesty model, adopt #13):
        1. capture prior SystemRestorePointCreationFrequency (journaled before change)
        2. set it to 0 (only when not already 0)
        3. Checkpoint-Computer -RestorePointType MODIFY_SETTINGS
        4. restore the prior frequency value (only-if-ours; divergence reported, never clobbered)
        Windows 24h throttle honesty: on checkpoint failure, enumerate Get-ComputerRestorePoint;
        a point newer than 24h means the machine is protected -> success-with-kept-point.
        Failure is reported ONLY when nothing protects the machine.
        NEXTRIX never deletes restore points or shadow copies (additive only).
        -Plan performs the read-only capture and reports intent; no journal, no mutation.
    #>
    [CmdletBinding()]
    param(
        [string]$JournalPath,
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [switch]$Plan
    )
    $freqPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\SystemRestore'
    $freqName = 'SystemRestorePointCreationFrequency'
    $description = 'NEXTRIX pre-apply ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $steps = @(); $seq = 0
    $uncertainty = @()

    $cap = Capture-NxRegistryValue -Path $freqPath -Name $freqName
    $seq++
    $steps += New-NxStep $seq 'capture-frequency' 'Complete' ("existed=$($cap.existed) keyExisted=$($cap.keyExisted) kind=$($cap.kind) value=$($cap.value)")

    if ($Plan) {
        $seq++; $steps += New-NxStep $seq 'frequency-override' 'Planned' 'would temporarily set SystemRestorePointCreationFrequency=0 (DWord) and restore the prior value after'
        $seq++; $steps += New-NxStep $seq 'restore-point' 'Planned' "would run Checkpoint-Computer -Description '$description' -RestorePointType MODIFY_SETTINGS"
        return [pscustomobject][ordered]@{
            functionName = 'Checkpoint-NxSystem'; plan = $true; approval = $Approval; description = $description
            frequencyOriginal = $cap; outcome = 'Planned'; keptPoint = $null; verification = 'NotRun'
            frequencyRestored = 'NotRun (plan)'; steps = $steps; allSucceeded = $true
            neverDeletesRestorePointsOrShadows = $true
            generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    if (-not $JournalPath) { throw 'Checkpoint-NxSystem: real application requires -JournalPath (journal-first invariant)' }
    if (-not (Test-NxElevated)) {
        return [pscustomobject][ordered]@{
            functionName = 'Checkpoint-NxSystem'; plan = $false; approval = $Approval; description = $description
            frequencyOriginal = $cap; outcome = 'Failed'; keptPoint = $null; verification = 'NotRun'
            frequencyRestored = 'NotRun'; steps = @(New-NxStep 1 'elevation' 'Failed' 'elevation required'); allSucceeded = $false
            neverDeletesRestorePointsOrShadows = $true
            generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    $modified = [pscustomobject][ordered]@{ targetType = 'registry'; path = $freqPath; name = $freqName; kind = 'DWord'; value = 0 }

    # --- 1. journal BEFORE change --------------------------------------------------------
    $freqRestore = 'NotRun'
    $journalApplied = $false
    try {
        $null = Add-NxJournalEntry -Path $JournalPath -TweakId 'NX16-002' -TweakVersion '1' -Operation 'apply' -Approval $Approval -Original $cap -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
        $journalApplied = $true
    } catch {
        # No journal -> no mutation (journal-first invariant).
        return [pscustomobject][ordered]@{
            functionName = 'Checkpoint-NxSystem'; plan = $false; approval = $Approval; description = $description
            frequencyOriginal = $cap; outcome = 'Failed'; keptPoint = $null; verification = 'NotRun'
            frequencyRestored = $freqRestore; steps = @(New-NxStep 1 'journal' 'Failed' ([string]$_.Exception.Message)); allSucceeded = $false
            neverDeletesRestorePointsOrShadows = $true
            generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    # --- 2. frequency override (skip when already 0 - idempotent) -------------------------
    $wrote = $false
    try {
        if ($cap.existed -and [int]$cap.value -eq 0) {
            $seq++; $steps += New-NxStep $seq 'frequency-override' 'Complete' 'already 0 - no write needed (idempotent)'
        } else {
            if (-not (Test-Path $freqPath)) { New-Item -Path $freqPath -Force | Out-Null }   # never -Force an existing key
            New-ItemProperty -Path $freqPath -Name $freqName -PropertyType DWord -Value 0 -Force | Out-Null
            $wrote = $true
            $seq++; $steps += New-NxStep $seq 'frequency-override' 'Complete' 'set to 0 for this checkpoint (original captured in journal)'
        }
    } catch {
        $freqRestore = 'override error: ' + [string]$_.Exception.Message
        $seq++; $steps += New-NxStep $seq 'frequency-override' 'Failed' $freqRestore
    }

    # --- 3. sequence probe before checkpoint (SynToolkit sequence-diff verification) -------
    $gcrp = Get-NxCommandIfExists 'Get-ComputerRestorePoint'
    $beforeMaxSeq = -1
    if ($null -ne $gcrp -and $wrote) {
        try { foreach ($p in @(Get-ComputerRestorePoint -ErrorAction Stop)) { if ([int]$p.SequenceNumber -gt $beforeMaxSeq) { $beforeMaxSeq = [int]$p.SequenceNumber } } } catch { $beforeMaxSeq = -1 }
    }

    # --- 4. checkpoint attempt --------------------------------------------------------------
    $created = $false; $outcome = 'Failed'; $kept = $null; $verification = 'NotRun'; $failReason = $null
    $ckpt = Get-NxCommandIfExists 'Checkpoint-Computer'
    if ($null -eq $ckpt) {
        $failReason = 'Checkpoint-Computer unavailable in this host (requires the Windows PowerShell 5.1 engine)'
        $seq++; $steps += New-NxStep $seq 'restore-point' 'Failed' $failReason
    } else {
        try {
            Checkpoint-Computer -Description $description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            $created = $true
            $seq++; $steps += New-NxStep $seq 'restore-point' 'Complete' 'Checkpoint-Computer returned without error'
        } catch {
            $err = [string]$_.Exception.Message
            $seq++; $steps += New-NxStep $seq 'restore-point' 'ThrottledOrFailed' $err
            # Honesty model: is the machine already protected by a <24h point?
            $pts = @()
            if ($null -ne $gcrp) {
                try { $pts = @(Get-ComputerRestorePoint -ErrorAction Stop) } catch { $pts = @(); $uncertainty += 'restore-point enumeration failed: ' + [string]$_.Exception.Message }
            } else { $uncertainty += 'Get-ComputerRestorePoint unavailable in this host' }
            $prot = Find-NxProtectingRestorePoint -Points $pts -WithinHours 24
            if ($null -ne $prot.point) {
                $outcome = 'KeptExistingPoint'; $kept = $prot.point
                $seq++; $steps += New-NxStep $seq 'checkpoint-honesty' 'Complete' ("throttle honored: existing point newer than 24h protects the machine (seq $($kept.SequenceNumber)) - kept, not failed")
            } else {
                $outcome = 'Failed'
                $failReason = 'checkpoint failed and no restore point newer than 24h exists - nothing protects the machine: ' + $err
                $seq++; $steps += New-NxStep $seq 'checkpoint-honesty' 'Failed' $failReason
            }
        }
    }

    # --- 5. verification when the cmdlet reported success ------------------------------------
    if ($created) {
        if ($null -eq $gcrp) {
            $verification = 'Uncertain'
            $uncertainty += 'cannot verify point creation in this host (Get-ComputerRestorePoint unavailable)'
        } else {
            try {
                $afterPts = @(Get-ComputerRestorePoint -ErrorAction Stop)
                $afterMax = -1
                foreach ($p in $afterPts) { if ([int]$p.SequenceNumber -gt $afterMax) { $afterMax = [int]$p.SequenceNumber } }
                $descMatch = @($afterPts | Where-Object { ([string]$_.Description) -eq $description }).Count -gt 0
                if (($beforeMaxSeq -ge 0 -and $afterMax -gt $beforeMaxSeq) -or $descMatch -or ($beforeMaxSeq -lt 0 -and $afterPts.Count -gt 0)) {
                    $verification = 'Verified'
                } else { $verification = 'NotVerified' }
            } catch { $verification = 'Uncertain'; $uncertainty += 'restore-point enumeration failed: ' + [string]$_.Exception.Message }
        }
        if ($verification -eq 'Verified') {
            $outcome = 'Created'
            $seq++; $steps += New-NxStep $seq 'verify-point' 'Complete' 'new restore point verified (sequence-diff)'
        } else {
            # Our point is not verifiable: apply the same honesty model - an existing <24h
            # point still protects the machine; otherwise report failure honestly.
            $prot = $null
            if ($null -ne $gcrp) {
                try { $prot = Find-NxProtectingRestorePoint -Points @(Get-ComputerRestorePoint -ErrorAction Stop) -WithinHours 24 } catch { $prot = $null }
            }
            if ($null -ne $prot -and $null -ne $prot.point) {
                $outcome = 'KeptExistingPoint'; $kept = $prot.point
                $seq++; $steps += New-NxStep $seq 'verify-point' 'Complete' ("our point unverified ($verification) but an existing <24h point protects the machine (seq $($kept.SequenceNumber)) - kept, not failed")
            } else {
                $outcome = 'Failed'
                $failReason = 'checkpoint reported no error but no new or <24h restore point is verifiable (verification=' + $verification + ')'
                $seq++; $steps += New-NxStep $seq 'verify-point' 'Failed' $failReason
            }
        }
    }

    # --- 6. restore the prior frequency value (only-if-ours; ALWAYS attempted) --------------
    try {
        if (-not $wrote) {
            $freqRestore = 'not changed by this run (value already 0 - nothing to restore)'
        } else {
            $live = Capture-NxRegistryValue -Path $freqPath -Name $freqName
            $ours = Test-NxCurrentEqualsDescriptor -Descriptor $live -Kind 'DWord' -Value 0
            if ($ours) {
                if ($cap.existed) {
                    New-ItemProperty -Path $freqPath -Name $freqName -Value $cap.value -PropertyType ([string]$cap.kind) -Force | Out-Null
                    $freqRestore = 'restored original ' + ([string]$cap.kind) + ':' + ([string]$cap.value)
                } else {
                    Remove-ItemProperty -Path $freqPath -Name $freqName -ErrorAction Stop
                    $freqRestore = 'removed (original state: value absent)'
                }
                $null = Add-NxJournalEntry -Path $JournalPath -TweakId 'NX16-002' -TweakVersion '1' -Operation 'rollback' -Approval $Approval -Original $cap -Modified $modified -Result 'Success' -Verification 'NotRun' -Profiles $Profiles
            } else {
                $freqRestore = 'diverged: live value no longer equals what NEXTRIX wrote - left untouched for user decision'
                $null = Add-NxJournalEntry -Path $JournalPath -TweakId 'NX16-002' -TweakVersion '1' -Operation 'rollback' -Approval $Approval -Original $cap -Modified $modified -Result 'Diverged' -Verification 'NotRun' -ErrorInfo $freqRestore -Profiles $Profiles
            }
        }
    } catch {
        $freqRestore = 'restore error: ' + [string]$_.Exception.Message
        $null = Add-NxJournalEntry -Path $JournalPath -TweakId 'NX16-002' -TweakVersion '1' -Operation 'rollback' -Approval $Approval -Original $cap -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $freqRestore -Profiles $Profiles
    }
    $seq++; $steps += New-NxStep $seq 'frequency-restore' 'Complete' $freqRestore

    # --- 7. journal the ritual outcome ---------------------------------------------------------
    $result = 'Success'
    if ($outcome -eq 'KeptExistingPoint') { $result = 'Success-KeptExistingPoint' }
    if ($outcome -eq 'Failed') { $result = 'Failed' }
    $verif = $verification
    if ($outcome -eq 'KeptExistingPoint' -and $verification -eq 'NotRun') { $verif = 'KeptPoint' }
    try {
        $null = Add-NxJournalEntry -Path $JournalPath -TweakId 'NX16-002' -TweakVersion '1' -Operation 'verify' -Approval $Approval -Original $cap -Modified $modified -Result $result -Verification $verif -ErrorInfo ([string]$failReason) -Profiles $Profiles
    } catch { $uncertainty += 'journal verify entry failed: ' + [string]$_.Exception.Message }

    $keptSummary = $null
    if ($null -ne $kept) {
        $keptSummary = [pscustomobject][ordered]@{
            sequenceNumber = [int]$kept.SequenceNumber
            description = [string]$kept.Description
            creationTime = ([string]$kept.CreationTime)
        }
    }
    $failedSteps = @($steps | Where-Object { $_.outcome -eq 'Failed' })
    return [pscustomobject][ordered]@{
        functionName = 'Checkpoint-NxSystem'
        plan = $false
        approval = $Approval
        description = $description
        frequencyOriginal = $cap
        outcome = $outcome
        keptPoint = $keptSummary
        verification = $verification
        frequencyRestored = $freqRestore
        steps = $steps
        allSucceeded = ($outcome -ne 'Failed' -and $failedSteps.Count -eq 0)
        uncertainty = $uncertainty
        neverDeletesRestorePointsOrShadows = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ============================================================================
# NX16-003 - Targeted registry backup
# ============================================================================

function Export-NxRegistryTargets {
    <#
        reg.exe export of each DISTINCT key path in -Paths to the backup set
        (%ProgramData%\NEXTRIX\Backups\<timestamp> by default, or -DestinationPath for
        self-tests / caller-chosen sets), with an index manifest (registry-index.json).
        Read-only on the machine: this function only writes backup files.
        Absent keys are honestly recorded as Skipped (nothing to back up; the journal
        records existence at capture time). Exports are header/size validated (r2).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [string]$DestinationPath
    )
    # Local scope: reg.exe stderr lines must reach $LASTEXITCODE handling even when the
    # caller runs with $ErrorActionPreference = 'Stop' (PS 5.1 native-redirect quirk).
    $ErrorActionPreference = 'Continue'
    $dest = $DestinationPath
    if (-not $dest) { $dest = New-NxBackupSetPath }
    New-Item -Path $dest -ItemType Directory -Force | Out-Null

    $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
    $seen = @{}; $distinct = @()
    foreach ($p in $Paths) {
        $k = ([string]$p).Trim().TrimEnd('\')
        if ($k -and -not $seen.ContainsKey($k.ToLower())) { $seen[$k.ToLower()] = $true; $distinct += $k }
    }

    $entries = @(); $uncertainty = @()
    foreach ($p in $distinct) {
        $regPath = Convert-NxToRegExePath -Path $p
        if ($null -eq $regPath) {
            $entries += [pscustomobject][ordered]@{ path = $p; result = 'Failed'; error = 'not a registry hive path (expected HKLM|HKCU|HKCR|HKU|HKCC)'; file = $null; validated = $false }
            continue
        }
        $provPath = Convert-NxToProviderPath -Path $p
        if (-not (Test-Path $provPath)) {
            $entries += [pscustomobject][ordered]@{ path = $p; result = 'Skipped'; error = 'key absent - nothing to back up (journal records absence at capture time)'; file = $null; validated = $false }
            continue
        }
        $file = Get-NxNonOverwritingPath -Path (Join-Path $dest ((Get-NxSafeFileName ('reg-' + $regPath)) + '.reg'))
        $exitCode = -1
        try {
            & $reg export $regPath $file /y | Out-Null
            $exitCode = $LASTEXITCODE
        } catch { $uncertainty += 'reg.exe invocation failed: ' + [string]$_.Exception.Message }
        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $file)) {
            $entries += [pscustomobject][ordered]@{ path = $p; result = 'Failed'; error = "reg.exe export exit code $exitCode"; file = $file; validated = $false }
            continue
        }
        $header = Read-NxRegFileHeader -Path $file
        $bytes = (Get-Item -LiteralPath $file).Length
        $validated = ($null -ne $header -and $bytes -gt 0)
        if ($validated) {
            $entries += [pscustomobject][ordered]@{ path = $p; regExePath = $regPath; result = 'Exported'; error = $null; file = $file; bytes = $bytes; validated = $true }
        } else {
            $entries += [pscustomobject][ordered]@{ path = $p; regExePath = $regPath; result = 'Failed'; error = 'export file failed header/size validation'; file = $file; bytes = $bytes; validated = $false }
        }
    }

    $exported = @($entries | Where-Object { $_.result -eq 'Exported' }).Count
    $skipped  = @($entries | Where-Object { $_.result -eq 'Skipped' }).Count
    $failed   = @($entries | Where-Object { $_.result -eq 'Failed' }).Count
    $index = [pscustomobject][ordered]@{
        kind = 'NxRegistryBackupIndex'
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        destinationPath = $dest
        requestedCount = @($Paths).Count
        distinctCount = @($distinct).Count
        entries = $entries
        summary = [pscustomobject][ordered]@{ exported = $exported; skipped = $skipped; failed = $failed }
    }
    $indexPath = Write-NxJsonFile -Object $index -Path (Join-Path $dest 'registry-index.json')

    return [pscustomobject][ordered]@{
        functionName = 'Export-NxRegistryTargets'
        destinationPath = $dest
        indexFile = $indexPath
        entries = $entries
        exportedCount = $exported
        skippedCount = $skipped
        failedCount = $failed
        allSucceeded = ($failed -eq 0)
        uncertainty = $uncertainty
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ============================================================================
# NX16-005 - Service configuration backup
# ============================================================================

function Export-NxServiceState {
    <#
        Whole-state service baseline for the given service names:
        - Get-Service snapshot (Name/Status; startup type comes from the registry Start
          value because PS 5.1's ServiceController has no StartType property) 
        - a validated, hand-importable services-start.reg containing ONLY the Start
          value per service (deliberately minimal: never ImagePath/Security blobs - the
          UltraOS blind-import rationale, adopt #3)
        - services-baseline.json with the full snapshot
        First backup is never overwritten (Atlas r2 pattern): re-running into the same
        destination writes services-start-2.reg etc. and leaves the original intact.
        Read-only on the machine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Services,
        [string]$DestinationPath
    )
    $dest = $DestinationPath
    if (-not $dest) { $dest = New-NxBackupSetPath }
    New-Item -Path $dest -ItemType Directory -Force | Out-Null

    $startNameMap = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
    $baseline = @(); $regLines = New-Object System.Collections.Generic.List[string]
    $regLines.Add('Windows Registry Editor Version 5.00')
    $regLines.Add('')
    $expectedSections = 0
    $uncertainty = @()

    foreach ($s in $Services) {
        $name = ([string]$s).Trim()
        $svc = $null
        try { $svc = Get-Service -Name ([System.Management.Automation.WildcardPattern]::Escape($name)) -ErrorAction Stop } catch { $svc = $null }
        $startCap = Capture-NxRegistryValue -Path ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $name) -Name 'Start'
        $rec = [ordered]@{
            name = $name
            present = ($null -ne $svc)
            status = $null
            derivedStartupType = $null
            registryStart = [pscustomobject][ordered]@{ existed = $startCap.existed; kind = [string]$startCap.kind; value = $startCap.value }
            result = 'Exported'
        }
        if ($null -ne $svc) { $rec.status = [string]$svc.Status }
        else { $rec.result = 'Missing' }
        if ($startCap.existed) {
            $rec.derivedStartupType = [string]$startNameMap[[int]$startCap.value]
        }
        if ($startCap.existed -and ([string]$startCap.kind -eq 'DWord') -and $name -match '^[A-Za-z0-9._-]{1,256}$') {
            $regLines.Add(('[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\' + $name + ']'))
            $regLines.Add(('"Start"=dword:{0:x8}' -f [int]$startCap.value))
            $regLines.Add('')
            $expectedSections++
        } elseif ($startCap.existed) {
            $uncertainty += ("service '" + $name + "': Start present as kind '" + [string]$startCap.kind + "' - recorded in baseline only (reg line requires DWord)")
            $rec.result = 'ExportedBaselineOnly'
        }
        $baseline += [pscustomobject]$rec
    }

    $regTarget = Get-NxNonOverwritingPath -Path (Join-Path $dest 'services-start.reg')
    $regLines | Set-Content -LiteralPath $regTarget -Encoding Unicode
    $header = Read-NxRegFileHeader -Path $regTarget
    $content = @()
    try { $content = @(Get-Content -LiteralPath $regTarget -Encoding Unicode) } catch { $content = @(); $uncertainty += 're-read of services-start.reg failed: ' + [string]$_.Exception.Message }
    $sectionCount = @($content | Where-Object { $_.StartsWith('[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\') }).Count
    $validated = ($null -ne $header -and $sectionCount -eq $expectedSections)

    $index = [pscustomobject][ordered]@{
        kind = 'NxServiceBaseline'
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        destinationPath = $dest
        serviceCount = @($Services).Count
        regFile = [IO.Path]::GetFileName($regTarget)
        regValidated = $validated
        note = 'Startup type is derived from the CurrentControlSet Start value (PS 5.1 Get-Service exposes no StartType).'
        entries = $baseline
    }
    $baselineTarget = Write-NxJsonFile -Object $index -Path (Join-Path $dest 'services-baseline.json')

    return [pscustomobject][ordered]@{
        functionName = 'Export-NxServiceState'
        destinationPath = $dest
        regFile = $regTarget
        baselineFile = $baselineTarget
        entries = $baseline
        regValidated = $validated
        firstBackupNeverOverwritten = $true
        allSucceeded = $validated
        uncertainty = $uncertainty
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ============================================================================
# NX16-006 - Scheduled task backup
# ============================================================================

function Export-NxTaskState {
    <#
        For each given TaskPath/TaskName pair (objects with .TaskPath/.TaskName):
        Export-ScheduledTask XML + current State into the backup set, plus a
        tasks-baseline.json index. Restoring a task is a documented import, not a
        reconstruction (r1 pattern). Read-only on the machine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Tasks,
        [string]$DestinationPath
    )
    $dest = $DestinationPath
    if (-not $dest) { $dest = New-NxBackupSetPath }
    New-Item -Path $dest -ItemType Directory -Force | Out-Null

    $entries = @(); $uncertainty = @()
    $getCmd = Get-NxCommandIfExists 'Get-ScheduledTask'
    $expCmd = Get-NxCommandIfExists 'Export-ScheduledTask'

    foreach ($t in $Tasks) {
        $tp = [string]$t.TaskPath
        $tn = [string]$t.TaskName
        if ([string]::IsNullOrWhiteSpace($tp) -or [string]::IsNullOrWhiteSpace($tn)) {
            $entries += [pscustomobject][ordered]@{ taskPath = $tp; taskName = $tn; result = 'Failed'; error = 'task pair requires both TaskPath and TaskName'; file = $null; state = $null }
            continue
        }
        if ($null -eq $getCmd -or $null -eq $expCmd) {
            $entries += [pscustomobject][ordered]@{ taskPath = $tp; taskName = $tn; result = 'CmdletUnavailable'; error = 'Get-ScheduledTask/Export-ScheduledTask unavailable in this host (requires the ScheduledTasks module of the Windows PowerShell 5.1 engine)'; file = $null; state = $null }
            $uncertainty += 'ScheduledTasks cmdlets unavailable in this host'
            continue
        }
        $task = $null
        try {
            $task = Get-ScheduledTask -TaskPath ([System.Management.Automation.WildcardPattern]::Escape($tp)) -TaskName ([System.Management.Automation.WildcardPattern]::Escape($tn)) -ErrorAction Stop
        } catch { $task = $null }
        if ($null -eq $task) {
            $entries += [pscustomobject][ordered]@{ taskPath = $tp; taskName = $tn; result = 'Missing'; error = 'task not found - recorded honestly (nothing to back up)'; file = $null; state = $null }
            continue
        }
        $xml = $null
        try { $xml = Export-ScheduledTask -TaskPath ([System.Management.Automation.WildcardPattern]::Escape($tp)) -TaskName ([System.Management.Automation.WildcardPattern]::Escape($tn)) -ErrorAction Stop } catch { $xml = $null }
        $validated = ($null -ne $xml -and ([string]$xml).TrimStart().StartsWith('<?xml'))
        if (-not $validated) {
            $entries += [pscustomobject][ordered]@{ taskPath = $tp; taskName = $tn; result = 'Failed'; error = 'export produced no valid task XML'; file = $null; state = [string]$task.State }
            continue
        }
        $file = Get-NxNonOverwritingPath -Path (Join-Path $dest ('task-' + (Get-NxSafeFileName ($tp + $tn)) + '.xml'))
        Set-Content -LiteralPath $file -Value $xml -Encoding Unicode
        $entries += [pscustomobject][ordered]@{ taskPath = $tp; taskName = $tn; result = 'Exported'; error = $null; file = $file; state = [string]$task.State; validated = $true }
    }

    $exported = @($entries | Where-Object { $_.result -eq 'Exported' }).Count
    $failed   = @($entries | Where-Object { $_.result -eq 'Failed' }).Count
    $index = [pscustomobject][ordered]@{
        kind = 'NxTaskBaseline'
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        destinationPath = $dest
        taskCount = @($Tasks).Count
        entries = $entries
    }
    $indexPath = Write-NxJsonFile -Object $index -Path (Join-Path $dest 'tasks-baseline.json')

    return [pscustomobject][ordered]@{
        functionName = 'Export-NxTaskState'
        destinationPath = $dest
        baselineFile = $indexPath
        entries = $entries
        exportedCount = $exported
        failedCount = $failed
        allSucceeded = ($failed -eq 0)
        uncertainty = $uncertainty
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ============================================================================
# NX16-004 - Pre-flight original-state snapshot bundle (the capture gate)
# ============================================================================

function Invoke-NxPreFlight {
    <#
        The pre-mutation ritual, as ONE gate (XOS capture-completeness pattern, adopt #2):
          1. journal init (capture-refusal respected - an unresolved existing journal
             fails the gate; the caller refuses to mutate)
          2. hardware + build reports saved as json into the backup set
          3. registry / service / task backups for the session's target set
        Every step is 'Complete' or 'Failed'. The caller gates ALL mutations on
        allComplete - no mutation without verified prior state.
        -IncludeRestorePoint additionally runs the NX16-002 checkpoint ritual (registry
        NX16-004 full description); by default the apply pipeline runs Checkpoint-NxSystem
        immediately before the first mutation instead.
        All operations here are read-only queries plus journal/backup-file writes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$BackupRoot,
        [string[]]$RegistryPaths = @(),
        [string[]]$ServiceNames = @(),
        [object[]]$Tasks = @(),
        [string]$Approval = 'Selection',
        [switch]$IncludeRestorePoint
    )
    $steps = @(); $seq = 0
    $startedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $setPath = New-NxBackupSetPath -Root $BackupRoot

    # 1. Journal init - capture-refusal is a GATE FAILURE, never silently forced through.
    $seq++
    try {
        $j = Initialize-NxJournal -Path $JournalRoot
        if ($j.created) {
            $steps += New-NxStep $seq 'journal-init' 'Complete' 'journal initialized - capture armed'
        } else {
            $steps += New-NxStep $seq 'journal-init' 'Failed' ('capture-refusal: ' + [string]$j.reason + ' - resolve/verify the existing journal before starting a new apply session (no mutation without verified prior state)')
        }
    } catch {
        $steps += New-NxStep $seq 'journal-init' 'Failed' ([string]$_.Exception.Message)
    }

    # 2. Backup set directory.
    $seq++
    try {
        New-Item -Path $setPath -ItemType Directory -Force | Out-Null
        $steps += New-NxStep $seq 'backup-set' 'Complete' $setPath
    } catch {
        $steps += New-NxStep $seq 'backup-set' 'Failed' ([string]$_.Exception.Message)
    }

    # 3. Hardware report.
    $seq++
    $hwFile = $null
    try {
        $hw = Get-NxHardwareReport
        $hwFile = Write-NxJsonFile -Object $hw -Path (Join-Path $setPath 'hardware.json')
        $steps += New-NxStep $seq 'hardware-report' 'Complete' $hwFile
    } catch {
        $steps += New-NxStep $seq 'hardware-report' 'Failed' ([string]$_.Exception.Message)
    }

    # 4. Build report.
    $seq++
    $brFile = $null
    try {
        $br = Get-NxBuildReport
        $brFile = Write-NxJsonFile -Object $br -Path (Join-Path $setPath 'build.json')
        if ($br.readSucceeded -ne $true) {
            $steps += New-NxStep $seq 'build-report' 'Failed' 'build report read failed (Failed/Uncertain sentinel - never guessed)'
        } else {
            $steps += New-NxStep $seq 'build-report' 'Complete' $brFile
        }
    } catch {
        $steps += New-NxStep $seq 'build-report' 'Failed' ([string]$_.Exception.Message)
    }

    # 5. Registry backup.
    $seq++
    if (@($RegistryPaths).Count -eq 0) {
        $steps += New-NxStep $seq 'registry-backup' 'Complete' 'no registry targets declared for this session'
    } else {
        try {
            $rb = Export-NxRegistryTargets -Paths $RegistryPaths -DestinationPath $setPath
            if ($rb.failedCount -eq 0) {
                $steps += New-NxStep $seq 'registry-backup' 'Complete' ("exported=$($rb.exportedCount) skipped=$($rb.skippedCount) failed=0 (index: $($rb.indexFile))")
            } else {
                $steps += New-NxStep $seq 'registry-backup' 'Failed' ("export failed for $($rb.failedCount) target(s) - capture incomplete")
            }
        } catch {
            $steps += New-NxStep $seq 'registry-backup' 'Failed' ([string]$_.Exception.Message)
        }
    }

    # 6. Service backup.
    $seq++
    if (@($ServiceNames).Count -eq 0) {
        $steps += New-NxStep $seq 'service-backup' 'Complete' 'no service targets declared for this session'
    } else {
        try {
            $sb = Export-NxServiceState -Services $ServiceNames -DestinationPath $setPath
            if ($sb.allSucceeded) {
                $steps += New-NxStep $seq 'service-backup' 'Complete' ("baseline validated: $($sb.regFile)")
            } else {
                $steps += New-NxStep $seq 'service-backup' 'Failed' 'service baseline failed validation - capture incomplete'
            }
        } catch {
            $steps += New-NxStep $seq 'service-backup' 'Failed' ([string]$_.Exception.Message)
        }
    }

    # 7. Task backup.
    $seq++
    if (@($Tasks).Count -eq 0) {
        $steps += New-NxStep $seq 'task-backup' 'Complete' 'no task targets declared for this session'
    } else {
        try {
            $tb = Export-NxTaskState -Tasks $Tasks -DestinationPath $setPath
            if ($tb.failedCount -eq 0) {
                $steps += New-NxStep $seq 'task-backup' 'Complete' ("exported=$($tb.exportedCount) (index: $($tb.baselineFile))")
            } else {
                $steps += New-NxStep $seq 'task-backup' 'Failed' ("task export failed for $($tb.failedCount) target(s) - capture incomplete")
            }
        } catch {
            $steps += New-NxStep $seq 'task-backup' 'Failed' ([string]$_.Exception.Message)
        }
    }

    # 8. Restore point (optional - registry NX16-004 full description).
    if ($IncludeRestorePoint) {
        $seq++
        try {
            $cp = Checkpoint-NxSystem -JournalPath $JournalRoot -Approval $Approval
            if ($cp.allSucceeded) {
                $steps += New-NxStep $seq 'restore-point' 'Complete' ("outcome=$($cp.outcome) verification=$($cp.verification)")
            } else {
                $steps += New-NxStep $seq 'restore-point' 'Failed' ("outcome=$($cp.outcome) - " + [string]$cp.verification)
            }
        } catch {
            $steps += New-NxStep $seq 'restore-point' 'Failed' ([string]$_.Exception.Message)
        }
    }

    $failedSteps = @($steps | Where-Object { $_.outcome -eq 'Failed' })
    return [pscustomobject][ordered]@{
        functionName = 'Invoke-NxPreFlight'
        journalRoot = $JournalRoot
        backupSetPath = $setPath
        steps = $steps
        allComplete = ($failedSteps.Count -eq 0)
        gateNote = 'the caller MUST gate all mutations on allComplete - no mutation without verified prior state (XOS capture-gate pattern, r1)'
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        startedUtc = $startedUtc
    }
}

# ============================================================================
# NX16-007 - DISM health check & repair tooling
# ============================================================================

function Invoke-NxDismHealth {
    <#
        DISM /Online /Cleanup-Image /CheckHealth and /ScanHealth (read-only).
        /RestoreHealth ONLY via -Repair (owner-initiated, never automatic).
        Returns parsed verdicts: Healthy / Repairable / Corrupt / Repaired / Failed /
        Uncertain (SynToolkit uncertainty pattern - never guessed, adopt #5).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Check', 'Scan', 'CheckAndScan')][string]$Mode = 'CheckAndScan',
        [switch]$Repair
    )
    # Local scope: DISM stderr lines must be captured as output, not terminating errors.
    $ErrorActionPreference = 'Continue'
    $dism = Join-Path $env:SystemRoot 'System32\dism.exe'
    $steps = @(); $uncertainty = @()
    if (-not (Test-NxElevated)) { $uncertainty += 'DISM servicing requires elevation; results may be NotElevated errors' }
    if (-not [Environment]::Is64BitProcess) { $uncertainty += '32-bit host: file-system redirection may route to the 32-bit DISM image (use the 64-bit engine)' }

    if (-not (Test-Path $dism)) {
        return [pscustomobject][ordered]@{ functionName = 'Invoke-NxDismHealth'; mode = $Mode; repair = [bool]$Repair.IsPresent; steps = @(); overallVerdict = 'Uncertain'; allSucceeded = $false; uncertainty = @('dism.exe not found at ' + $dism); rebootRequired = $false; generatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    }

    $stepDefs = @()
    if ($Mode -eq 'Check' -or $Mode -eq 'CheckAndScan') { $stepDefs += @{ name = 'CheckHealth';  argv = @('/Online', '/Cleanup-Image', '/CheckHealth') } }
    if ($Mode -eq 'Scan' -or $Mode -eq 'CheckAndScan')  { $stepDefs += @{ name = 'ScanHealth';   argv = @('/Online', '/Cleanup-Image', '/ScanHealth') } }
    if ($Repair) { $stepDefs += @{ name = 'RestoreHealth'; argv = @('/Online', '/Cleanup-Image', '/RestoreHealth'); ownerInitiated = $true } }

    $rebootRequired = $false
    foreach ($sd in $stepDefs) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $exitCode = -1; $lines = @()
        try {
            $lines = @(& $dism @($sd.argv) 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -match '\S' })
            $exitCode = $LASTEXITCODE
        } catch {
            $uncertainty += ($sd.name + ' invocation failed: ' + [string]$_.Exception.Message)
        }
        $sw.Stop()
        $joined = ($lines -join ' ')
        $verdict = 'Uncertain'
        if ($sd.name -eq 'RestoreHealth') {
            if ($joined -match '(?i)the restore operation completed successfully') { $verdict = 'Repaired' }
            elseif ($joined -match '(?i)the restore operation failed') { $verdict = 'Failed' }
        } else {
            if ($joined -match '(?i)no component store corruption detected') { $verdict = 'Healthy' }
            elseif ($joined -match '(?i)the component store is repairable') { $verdict = 'Repairable' }
            elseif ($joined -match '(?i)the component store is corrupt') { $verdict = 'Corrupt' }
        }
        if ($exitCode -eq 3010) { $rebootRequired = $true }
        $keyLines = @($lines | Where-Object { $_ -match '(?i)component store|restore operation|error' } | Select-Object -First 10)
        $steps += [pscustomobject][ordered]@{
            name = [string]$sd.name
            command = ('dism.exe ' + (@($sd.argv) -join ' '))
            exitCode = $exitCode
            verdict = $verdict
            durationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            keyLines = $keyLines
            read = ($sd.name -ne 'RestoreHealth')
            ownerInitiated = [bool]$sd.ownerInitiated
        }
    }

    $verdicts = @($steps | ForEach-Object { $_.verdict })
    $overall = 'Uncertain'
    if ($verdicts.Count -gt 0) {
        if ($verdicts -contains 'Repaired') { $overall = 'Repaired' }
        elseif ($verdicts -contains 'Corrupt') { $overall = 'Corrupt' }
        elseif ($verdicts -contains 'Repairable') { $overall = 'Repairable' }
        elseif (@($verdicts | Where-Object { $_ -ne 'Healthy' }).Count -eq 0) { $overall = 'Healthy' }
    }
    return [pscustomobject][ordered]@{
        functionName = 'Invoke-NxDismHealth'
        mode = $Mode
        repair = [bool]$Repair.IsPresent
        steps = $steps
        overallVerdict = $overall
        rebootRequired = $rebootRequired
        elevationRequired = $true
        repairPolicy = 'RestoreHealth is owner-initiated only (-Repair); never automatic'
        allSucceeded = (($overall -eq 'Healthy') -or ($overall -eq 'Repaired'))
        uncertainty = $uncertainty
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ============================================================================
# NX16-008 - SFC verification tooling
# ============================================================================

function Invoke-NxSfcVerify {
    <#
        sfc /verifyonly - the read-only integrity check. Repair is NEVER automatic:
        the report proposes the owner command (sfc /scannow) and NEXTRIX never runs it
        (r6 contrast: ame-sfc-interface warns against scannow; NEXTRIX reports instead).
        sfc's redirected output is UTF-16; output is captured via cmd redirect and read
        with Unicode encoding, with honest Uncertain fallback + CBS.log pointer.
    #>
    [CmdletBinding()]
    param()
    $sfc = Join-Path $env:SystemRoot 'System32\sfc.exe'
    $uncertainty = @()
    if (-not (Test-Path $sfc)) {
        return [pscustomobject][ordered]@{ functionName = 'Invoke-NxSfcVerify'; verdict = 'Uncertain'; allSucceeded = $false; uncertainty = @('sfc.exe not found at ' + $sfc); generatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    }
    if (-not (Test-NxElevated)) { $uncertainty += 'sfc requires elevation; the run may report NotElevated' }

    $tmpOut = Join-Path ([IO.Path]::GetTempPath()) ('nx-sfc-' + [guid]::NewGuid().ToString('N') + '.txt')
    $exitCode = -1
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $cmdLine = 'sfc /verifyonly > "' + $tmpOut + '" 2>&1'
        & cmd.exe /c $cmdLine | Out-Null
        $exitCode = $LASTEXITCODE
    } catch {
        $uncertainty += 'sfc invocation failed: ' + [string]$_.Exception.Message
    }
    $sw.Stop()

    $lines = @()
    $verdict = 'Uncertain'
    try {
        $lines = @(Get-Content -LiteralPath $tmpOut -Encoding Unicode | Where-Object { $_ -match '\S' })
        $joined = ($lines -join ' ')
        if ($joined -notmatch 'Windows Resource Protection') {
            # Some builds emit ANSI when redirected - honest retry, never a guessed verdict.
            $lines = @(Get-Content -LiteralPath $tmpOut -Encoding Default | Where-Object { $_ -match '\S' })
            $joined = ($lines -join ' ')
        }
        if ($joined -match '(?i)you must be an administrator') { $verdict = 'NotElevated' }
        elseif ($joined -match '(?i)did not find any integrity violations') { $verdict = 'Clean' }
        elseif ($joined -match '(?i)found integrity violations') { $verdict = 'ViolationsFound' }
        elseif ($joined -match '(?i)could not perform the requested operation') { $verdict = 'CouldNotComplete' }
        else { $uncertainty += 'sfc output unparseable - inspect CBS.log' }
    } catch {
        $uncertainty += 'reading sfc output failed: ' + [string]$_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
    }

    $keyLines = @($lines | Where-Object { $_ -match '(?i)Windows Resource Protection|violations' } | Select-Object -First 5)
    return [pscustomobject][ordered]@{
        functionName = 'Invoke-NxSfcVerify'
        command = 'sfc /verifyonly'
        verdict = $verdict
        exitCode = $exitCode
        durationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        keyLines = $keyLines
        cbsLogPath = (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log')
        repairNote = 'repair is never automatic and never executed by NEXTRIX: if the owner decides, the manual owner command is "sfc /scannow" (r6 contrast documented in the registry entry)'
        elevationRequired = $true
        allSucceeded = ($verdict -eq 'Clean')
        uncertainty = $uncertainty
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ============================================================================
# NX16-009 - Component store cleanup (on demand; never /ResetBase)
# ============================================================================

function Invoke-NxComponentCleanup {
    <#
        DISM /Online /Cleanup-Image /StartComponentCleanup.
        - Plan-by-default: without -Execute the function returns the exact command and
          honest irreversible labeling and runs NOTHING (WhatIf-style).
        - /ResetBase is NEVER emitted - it permanently removes update uninstallability
          (WinUtil-rejected pattern, r5); no parameter exists for it.
        - -Analyze runs the read-only /AnalyzeComponentStore before (and after execution)
          and records the reported store sizes verbatim.
    #>
    [CmdletBinding()]
    param(
        [switch]$Execute,
        [switch]$Analyze
    )
    # Local scope: DISM stderr lines must be captured as output, not terminating errors.
    $ErrorActionPreference = 'Continue'
    $dism = Join-Path $env:SystemRoot 'System32\dism.exe'
    $uncertainty = @()
    $executeStep = $null
    $beforeText = $null; $afterText = $null

    if (-not (Test-Path $dism)) {
        return [pscustomobject][ordered]@{ functionName = 'Invoke-NxComponentCleanup'; executed = $false; plannedCommands = @(); exitCode = $null; uncertainty = @('dism.exe not found at ' + $dism); allSucceeded = $false; policyNeverResetBase = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    }

    $planCommands = @('DISM /Online /Cleanup-Image /StartComponentCleanup')
    if ($Analyze) { $planCommands = @('DISM /Online /Cleanup-Image /AnalyzeComponentStore (read-only size report)') + $planCommands }

    $parseSize = {
        param([string[]]$Lines)
        $sizeLines = @($Lines | Where-Object { $_ -match '(?i)actual size of component store|the size of the component store' })
        if ($sizeLines.Count -gt 0) { return ($sizeLines -join ' | ') }
        return $null
    }

    if (-not $Execute) {
        return [pscustomobject][ordered]@{
            functionName = 'Invoke-NxComponentCleanup'
            executed = $false
            plannedCommands = $planCommands
            policyNeverResetBase = $true
            policyNote = '/ResetBase is never used: it permanently removes the ability to uninstall installed updates (WinUtil rejected pattern, r5) - excluded by design'
            irreversibilityNote = 'StartComponentCleanup removes superseded component versions; installed updates remain uninstallable; per-component restore is NOT possible (honest labeling - never disguised as reversible)'
            scheduledTaskNote = 'Windows already runs this cleanup automatically over time via the SilentCleanup maintenance task; this function is the explicit on-demand form, never scheduled silently by NEXTRIX'
            storeSizeReport = $null
            uncertainty = $uncertainty
            allSucceeded = $true
            generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    if (-not (Test-NxElevated)) {
        $uncertainty += 'StartComponentCleanup requires elevation; execution refused honestly'
        return [pscustomobject][ordered]@{ functionName = 'Invoke-NxComponentCleanup'; executed = $false; plannedCommands = $planCommands; policyNeverResetBase = $true; uncertainty = $uncertainty; allSucceeded = $false; generatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    }

    if ($Analyze) {
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $lines = @(& $dism '/Online' '/Cleanup-Image' '/AnalyzeComponentStore' 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -match '\S' })
            $sw.Stop()
            $beforeText = & $parseSize $lines
            if ($null -eq $beforeText) { $uncertainty += 'AnalyzeComponentStore size line not parseable (recorded honestly)' }
        } catch { $uncertainty += 'AnalyzeComponentStore failed: ' + [string]$_.Exception.Message }
    }

    $exitCode = -1; $duration = 0
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lines = @(& $dism '/Online' '/Cleanup-Image' '/StartComponentCleanup' 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -match '\S' })
        $exitCode = $LASTEXITCODE
        $sw.Stop()
        $duration = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    } catch {
        $uncertainty += 'StartComponentCleanup invocation failed: ' + [string]$_.Exception.Message
    }
    $executeStep = [pscustomobject][ordered]@{ command = 'DISM /Online /Cleanup-Image /StartComponentCleanup'; exitCode = $exitCode; durationSeconds = $duration }

    if ($Analyze) {
        try {
            $lines = @(& $dism '/Online' '/Cleanup-Image' '/AnalyzeComponentStore' 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -match '\S' })
            $afterText = & $parseSize $lines
        } catch { $uncertainty += 'post-cleanup AnalyzeComponentStore failed: ' + [string]$_.Exception.Message }
    }

    $ok = ($exitCode -eq 0 -or $exitCode -eq 3010)
    if (-not $ok) { $uncertainty += 'DISM StartComponentCleanup exit code ' + $exitCode }
    return [pscustomobject][ordered]@{
        functionName = 'Invoke-NxComponentCleanup'
        executed = $true
        plannedCommands = $planCommands
        executeStep = $executeStep
        rebootRequired = ($exitCode -eq 3010)
        policyNeverResetBase = $true
        policyNote = '/ResetBase is never used: it permanently removes update uninstallability (WinUtil rejected pattern, r5) - excluded by design'
        irreversibilityNote = 'component store trimmed; per-component restore is NOT possible (documented, explicit, one-way operation)'
        storeSizeBefore = $beforeText
        storeSizeAfter = $afterText
        uncertainty = $uncertainty
        allSucceeded = $ok
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ============================================================================
# NX16-010 - Driver inventory & history report (read-only)
# ============================================================================

function Get-NxDriverInventory {
    <#
        Read-only Win32_PnPSignedDriver enumeration plus DriverStore usage stats.
        Never fabricates unavailable values; failures land in uncertainty (r4 pattern).
    #>
    [CmdletBinding()]
    param()
    $drivers = @(); $unc = @()
    try {
        foreach ($d in @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)) {
            $dd = Convert-NxToDateTime $d.DriverDate
            $drivers += [pscustomobject][ordered]@{
                deviceName = [string]$d.DeviceName
                manufacturer = [string]$d.Manufacturer
                provider = [string]$d.DriverProviderName
                driverVersion = [string]$d.DriverVersion
                driverDate = $dd
                infName = [string]$d.InfName
                isSigned = [bool]$d.IsSigned
            }
        }
    } catch {
        $unc += 'Win32_PnPSignedDriver read failed: ' + [string]$_.Exception.Message
    }
    $storePath = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    $storeBytes = $null; $storeFiles = $null
    try {
        $m = Get-ChildItem -LiteralPath $storePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
        $storeBytes = [int64]$m.Sum
        $storeFiles = [int]$m.Count
    } catch {
        $unc += 'DriverStore size measurement failed: ' + [string]$_.Exception.Message
    }
    return [pscustomobject][ordered]@{
        functionName = 'Get-NxDriverInventory'
        driverCount = @($drivers).Count
        drivers = $drivers
        driverStorePath = $storePath
        driverStoreSizeBytes = $storeBytes
        driverStoreSizeMb = $(if ($null -ne $storeBytes) { [math]::Round($storeBytes / 1MB, 1) } else { $null })
        driverStoreFileCount = $storeFiles
        uncertainty = $unc
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ============================================================================
# NX16-011 - Driver Store selective cleanup (orphan-only, per-package consent)
# ============================================================================

function Invoke-NxDriverStoreClean {
    <#
        Orphan-only pnputil cleanup:
        - Default: enumerate packages (pnputil /enum-drivers), cross-check in-use status
          via Win32_PnPSignedDriver, export the FULL pre-list to the backup set, and
          return the orphan proposal. No deletion happens without explicit naming.
        - Deletion requires -ConfirmPackage <oem##.inf> per package (string[]): each
          named package must exist in the enumeration AND be orphaned. In-use packages
          are ALWAYS refused; /force is NEVER used. Journal result is deliberately
          'Success-Irreversible' so Invoke-NxRollback can never pick it up as a
          reversible candidate (honest labeling at journal level).
    #>
    [CmdletBinding()]
    param(
        [string[]]$ConfirmPackage = @(),
        [string]$DestinationPath,
        [string]$JournalPath,
        [string]$Approval = 'ExplicitConsent'
    )
    # Local scope: pnputil stderr lines must reach $LASTEXITCODE handling.
    $ErrorActionPreference = 'Continue'
    $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    $dest = $DestinationPath
    if (-not $dest) { $dest = New-NxBackupSetPath }
    New-Item -Path $dest -ItemType Directory -Force | Out-Null
    $uncertainty = @()

    if (-not (Test-Path $pnputil)) {
        return [pscustomobject][ordered]@{ functionName = 'Invoke-NxDriverStoreClean'; executed = $false; packages = @(); orphanProposal = @(); deletions = @(); refused = @(); uncertainty = @('pnputil.exe not found at ' + $pnputil); allSucceeded = $false; generatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    }

    # 1. Enumerate packages.
    $raw = @()
    $enumOk = $false
    try {
        $raw = @(& $pnputil '/enum-drivers' 2>&1 | ForEach-Object { [string]$_ })
        $enumOk = ($LASTEXITCODE -eq 0)
    } catch { $uncertainty += 'pnputil /enum-drivers failed: ' + [string]$_.Exception.Message }

    $packages = @()
    $blocks = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[string]
    foreach ($line in $raw) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current.Count -gt 0) { $blocks.Add($current); $current = New-Object System.Collections.Generic.List[string] }
        } else { $current.Add($line) }
    }
    if ($current.Count -gt 0) { $blocks.Add($current) }
    foreach ($b in $blocks) {
        $props = @{}
        foreach ($line in $b) {
            $idx = $line.IndexOf(':')
            if ($idx -gt 0) { $props[$line.Substring(0, $idx).Trim().ToLower()] = $line.Substring($idx + 1).Trim() }
        }
        if ($props.ContainsKey('published name')) {
            $packages += [pscustomobject][ordered]@{
                publishedName = [string]$props['published name']
                originalName = [string]$props['original name']
                provider = [string]$props['provider name']
                className = [string]$props['class name']
                driverVersion = [string]$props['driver version']
                signerName = [string]$props['signer name']
                inUse = $false
            }
        }
    }
    if ($packages.Count -eq 0 -and $raw.Count -gt 0) {
        $uncertainty += 'pnputil output parsed to zero packages (localized/unexpected format) - raw output saved for human review; refusing to propose or delete anything'
        try { $raw | Set-Content -LiteralPath (Get-NxNonOverwritingPath -Path (Join-Path $dest 'pnputil-raw-unparsed.txt')) -Encoding UTF8 } catch { }
    }

    # 2. In-use cross-check (read-only).
    $inUseMap = @{}
    try {
        foreach ($d in @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)) {
            if ($d.InfName) { $inUseMap[([string]$d.InfName).Trim().ToLower()] = $true }
        }
    } catch { $uncertainty += 'in-use cross-check unavailable (Win32_PnPSignedDriver failed): ' + [string]$_.Exception.Message + ' - NO deletion is safe; proposal and confirmation both refused' }
    $crossCheckOk = ($uncertainty.Count -eq 0)
    foreach ($pkg in $packages) {
        if ($inUseMap.ContainsKey($pkg.publishedName.ToLower())) { $pkg.inUse = $true }
    }
    $orphans = @($packages | Where-Object { -not $_.inUse })

    # 3. Export the full pre-list to the backup set (before any deletion).
    $preList = [pscustomobject][ordered]@{
        kind = 'NxDriverStorePreList'
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        enumeratedCount = @($packages).Count
        parseable = ($packages.Count -gt 0)
        inUseCrossCheckAvailable = $crossCheckOk
        packages = $packages
    }
    $preListFile = Write-NxJsonFile -Object $preList -Path (Join-Path $dest 'driverstore-prelist.json')

    # 4. Confirmation handling (orphan-only, per package).
    $deletions = @(); $refused = @()
    $executed = (@($ConfirmPackage).Count -gt 0)
    if ($executed) {
        if (-not $JournalPath) { throw 'Invoke-NxDriverStoreClean: real deletion requires -JournalPath (journal-first invariant)' }
        if (-not (Test-NxElevated)) {
            foreach ($c in $ConfirmPackage) { $refused += [pscustomobject][ordered]@{ package = $c; reason = 'elevation required - deletion refused' } }
        } elseif (-not $crossCheckOk) {
            foreach ($c in $ConfirmPackage) { $refused += [pscustomobject][ordered]@{ package = $c; reason = 'in-use cross-check unavailable - deletion refused (orphan-only scope cannot be proven)' } }
        } else {
            foreach ($c in $ConfirmPackage) {
                $cname = ([string]$c).Trim()
                if ($cname -notmatch '^[Oo][Ee][Mm][0-9]+\.inf$') {
                    $refused += [pscustomobject][ordered]@{ package = $cname; reason = 'not an oem##.inf package name - refused' }
                    continue
                }
                $pkg = @($packages | Where-Object { $_.publishedName -eq $cname } | Select-Object -First 1)
                if ($pkg.Count -eq 0) {
                    $refused += [pscustomobject][ordered]@{ package = $cname; reason = 'unknown package - not in the current enumeration' }
                    continue
                }
                $pkg = $pkg[0]
                if ($pkg.inUse) {
                    $refused += [pscustomobject][ordered]@{ package = $cname; reason = 'package is IN USE - refused (orphan-only scope; /force is never used)' }
                    continue
                }
                $original = [pscustomobject][ordered]@{ targetType = 'driverPackage'; package = $pkg.publishedName; originalName = $pkg.originalName; provider = $pkg.provider; driverVersion = $pkg.driverVersion; inUse = $false }
                $modified = [pscustomobject][ordered]@{ targetType = 'driverPackage'; package = $pkg.publishedName; action = 'DeletePackage'; reversible = $false }
                try {
                    # Journal BEFORE deletion (InProgress), then the irreversible result.
                    $null = Add-NxJournalEntry -Path $JournalPath -TweakId 'NX16-011' -TweakVersion '1' -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun'
                    $out = @(& $pnputil '/delete-driver' $pkg.publishedName 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -match '\S' })
                    $code = $LASTEXITCODE
                    $deleted = ($code -eq 0)
                    $journalResult = 'Success-Irreversible'
                    if (-not $deleted) { $journalResult = 'Failed' }
                    $null = Add-NxJournalEntry -Path $JournalPath -TweakId 'NX16-011' -TweakVersion '1' -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $journalResult -Verification 'NotRun' -ErrorInfo (($out -join ' ')) 
                    $deletions += [pscustomobject][ordered]@{ package = $pkg.publishedName; exitCode = $code; deleted = $deleted; output = ($out -join ' ') }
                } catch {
                    $null = Add-NxJournalEntry -Path $JournalPath -TweakId 'NX16-011' -TweakVersion '1' -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message)
                    $deletions += [pscustomobject][ordered]@{ package = $pkg.publishedName; exitCode = -1; deleted = $false; output = [string]$_.Exception.Message }
                }
            }
        }
    }

    $allOk = $true
    if ($executed) {
        $failedDeletes = @($deletions | Where-Object { -not $_.deleted })
        if ($failedDeletes.Count -gt 0) { $allOk = $false }
    }
    return [pscustomobject][ordered]@{
        functionName = 'Invoke-NxDriverStoreClean'
        executed = $executed
        destinationPath = $dest
        preListFile = $preListFile
        enumeratedCount = @($packages).Count
        inUseCount = @($packages | Where-Object { $_.inUse }).Count
        orphanCount = @($orphans).Count
        packages = $packages
        orphanProposal = $orphans
        deletions = $deletions
        refused = $refused
        policyNotes = @('orphan-only: in-use packages are always refused', '/force is never used', 'per-package explicit consent required (-ConfirmPackage oem##.inf)')
        irreversibilityNote = 'driver-package deletion is NOT journal-reversible: the journal result is deliberately Success-Irreversible so rollback never claims it; reinstall requires the original INF/driver media; the pre-list export records every package for manual reinstall'
        uncertainty = $uncertainty
        allSucceeded = $allOk
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ============================================================================
# NX16-017 - Owner support-bundle export (scrubbed)
# ============================================================================

function Export-NxSupportBundle {
    <#
        One-click, privacy-safe evidence bundle for the owner (XOS diagnostic-ZIP pattern, r1):
        hardware.json + build.json + journal SUMMARY (tweak IDs / timestamps / results
        ONLY - original/modified/errorInfo/hash deliberately excluded because they could
        hold state values or identifiers) + optional health reports, zipped at an
        owner-chosen path. Machine identifiers (computer name, users, SIDs, MACs, serials,
        UUIDs) are scrubbed from ALL text content. Nothing is uploaded - the zip stays
        where the owner saved it. Existing destination files are never overwritten.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$JournalRoot,
        [switch]$IncludeHealth,
        [switch]$IncludeDismScan,
        [switch]$IncludeSfc
    )
    $staging = Join-Path ([IO.Path]::GetTempPath()) ('nx-supportbundle-' + [guid]::NewGuid().ToString('N'))
    $uncertainty = @()
    $contents = @()
    $redactionLog = New-Object System.Collections.Generic.List[object]

    $zipPath = $DestinationPath
    if ($zipPath -notmatch '\.zip$') { $zipPath = $zipPath + '.zip' }
    if (Test-Path -LiteralPath $zipPath) {
        return [pscustomobject][ordered]@{ functionName = 'Export-NxSupportBundle'; bundlePath = $zipPath; allSucceeded = $false; contents = @(); redactionSummary = @(); uncertainty = @('destination exists - refusing to overwrite an existing file (delete it or choose a new path)'); nothingUploaded = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    }

    try {
        New-Item -Path $staging -ItemType Directory -Force | Out-Null
        $ids = Get-NxMachineIdentifierCandidates
        $uncertainty += @($ids.uncertainty)

        # hardware.json
        try {
            $hwText = (Get-NxHardwareReport | ConvertTo-Json -Depth 8)
            $red = Write-NxScrubbedTextFile -Path (Join-Path $staging 'hardware.json') -Text $hwText -ComputerNames $ids.computerNames -UserNames $ids.userNames -Identifiers $ids.otherIdentifiers
            foreach ($r in @($red)) { $redactionLog.Add($r) }
            $contents += 'hardware.json'
        } catch { $uncertainty += 'hardware report failed: ' + [string]$_.Exception.Message }

        # build.json
        try {
            $brText = (Get-NxBuildReport | ConvertTo-Json -Depth 8)
            $red = Write-NxScrubbedTextFile -Path (Join-Path $staging 'build.json') -Text $brText -ComputerNames $ids.computerNames -UserNames $ids.userNames -Identifiers $ids.otherIdentifiers
            foreach ($r in @($red)) { $redactionLog.Add($r) }
            $contents += 'build.json'
        } catch { $uncertainty += 'build report failed: ' + [string]$_.Exception.Message }

        # journal-summary.json (ids/timestamps/results ONLY - never values)
        $jr = $JournalRoot
        if (-not $jr) { $jr = Join-Path $env:ProgramData 'NEXTRIX\Journal' }
        $journalNote = 'not found at ' + $jr
        if (Test-Path -LiteralPath (Join-Path $jr 'manifest.json')) {
            try {
                $rd = Read-NxJournal -Path $jr
                $restoredUtc = $null
                if ($rd.manifest -and $rd.manifest.PSObject.Properties['restoredVerifiedUtc']) { $restoredUtc = $rd.manifest.restoredVerifiedUtc }
                $summary = [pscustomobject][ordered]@{
                    kind = 'NxJournalSummary'
                    generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                    journalRoot = 'REDACTED-PATH'
                    journalPresent = $true
                    manifest = [pscustomobject][ordered]@{
                        entries = [int]$rd.manifest.entries
                        createdAtUtc = $rd.manifest.createdAtUtc
                        captureStatus = $rd.manifest.captureStatus
                        restoredVerifiedUtc = $restoredUtc
                    }
                    integrityErrorCount = @($rd.integrityErrors).Count
                    entries = @($rd.entries | ForEach-Object {
                        [pscustomobject][ordered]@{
                            seq = $_.seq; utc = $_.utc; tweakId = $_.tweakId; tweakVersion = $_.tweakVersion
                            operation = $_.operation; approval = $_.approval; profiles = @($_.profiles)
                            result = $_.result; verification = $_.verification
                        }
                    })
                    excludedFields = @('original', 'modified', 'errorInfo', 'hash')
                }
                $sumText = ($summary | ConvertTo-Json -Depth 8)
                $red = Write-NxScrubbedTextFile -Path (Join-Path $staging 'journal-summary.json') -Text $sumText -ComputerNames $ids.computerNames -UserNames $ids.userNames -Identifiers $ids.otherIdentifiers
                foreach ($r in @($red)) { $redactionLog.Add($r) }
                $contents += 'journal-summary.json'
                $journalNote = 'summary included (values excluded by design)'
            } catch { $journalNote = 'journal read failed: ' + [string]$_.Exception.Message; $uncertainty += $journalNote }
        }
        $null = $journalNote

        # optional health reports (read-only; owner-initiated switches)
        if ($IncludeHealth) {
            try {
                $h = Invoke-NxDismHealth -Mode 'Check'
                $red = Write-NxScrubbedTextFile -Path (Join-Path $staging 'dism-check.json') -Text ($h | ConvertTo-Json -Depth 8) -ComputerNames $ids.computerNames -UserNames $ids.userNames -Identifiers $ids.otherIdentifiers
                foreach ($r in @($red)) { $redactionLog.Add($r) }
                $contents += 'dism-check.json'
            } catch { $uncertainty += 'DISM CheckHealth failed: ' + [string]$_.Exception.Message }
        }
        if ($IncludeDismScan) {
            try {
                $h = Invoke-NxDismHealth -Mode 'Scan'
                $red = Write-NxScrubbedTextFile -Path (Join-Path $staging 'dism-scan.json') -Text ($h | ConvertTo-Json -Depth 8) -ComputerNames $ids.computerNames -UserNames $ids.userNames -Identifiers $ids.otherIdentifiers
                foreach ($r in @($red)) { $redactionLog.Add($r) }
                $contents += 'dism-scan.json'
            } catch { $uncertainty += 'DISM ScanHealth failed: ' + [string]$_.Exception.Message }
        }
        if ($IncludeSfc) {
            try {
                $h = Invoke-NxSfcVerify
                $red = Write-NxScrubbedTextFile -Path (Join-Path $staging 'sfc-verify.json') -Text ($h | ConvertTo-Json -Depth 8) -ComputerNames $ids.computerNames -UserNames $ids.userNames -Identifiers $ids.otherIdentifiers
                foreach ($r in @($red)) { $redactionLog.Add($r) }
                $contents += 'sfc-verify.json'
            } catch { $uncertainty += 'SFC verify failed: ' + [string]$_.Exception.Message }
        }

        # README.txt - contents manifest, scrub statement, owner commands.
        $readme = @(
            'NEXTRIX support bundle',
            'Generated (UTC): ' + (Get-Date).ToUniversalTime().ToString('o'),
            '',
            'Privacy statement:',
            '- Machine identifiers were scrubbed from every text file in this archive',
            '  (computer name, user names, SIDs, MAC addresses, serial/UUID values).',
            '- The journal summary contains tweak IDs, timestamps and results ONLY;',
            '  configuration values and error details are deliberately excluded.',
            '- Nothing was uploaded: this zip stays where the owner saved it.',
            '',
            'Contents: ' + ($contents -join ', '),
            $journalNote,
            '',
            'Deeper owner-run checks (NOT automatically executed by NEXTRIX):',
            '  DISM deep scan : dism /Online /Cleanup-Image /ScanHealth',
            '  SFC verify     : sfc /verifyonly',
            '  Driver report  : Get-NxDriverInventory (NEXTRIX engine function)'
        ) -join [Environment]::NewLine
        $red = Write-NxScrubbedTextFile -Path (Join-Path $staging 'README.txt') -Text $readme -ComputerNames $ids.computerNames -UserNames $ids.userNames -Identifiers $ids.otherIdentifiers
        foreach ($r in @($red)) { $redactionLog.Add($r) }
        $contents += 'README.txt'

        # Zip the staging folder to the owner-chosen destination (never clobber).
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal -ErrorAction Stop
    } catch {
        $uncertainty += 'bundle creation failed: ' + [string]$_.Exception.Message
        return [pscustomobject][ordered]@{ functionName = 'Export-NxSupportBundle'; bundlePath = $zipPath; allSucceeded = $false; contents = @(); redactionSummary = @(); uncertainty = $uncertainty; nothingUploaded = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    $redSummary = @()
    $grouped = @($redactionLog | Group-Object -Property kind)
    foreach ($g in $grouped) {
        $total = 0
        foreach ($r in @($g.Group)) { $total += [int]$r.count }
        $redSummary += [pscustomobject][ordered]@{ kind = [string]$g.Name; count = $total }
    }
    return [pscustomobject][ordered]@{
        functionName = 'Export-NxSupportBundle'
        bundlePath = $zipPath
        contents = $contents
        redactionSummary = $redSummary
        journalSummaryNote = $journalNote
        uncertainty = $uncertainty
        nothingUploaded = $true
        allSucceeded = (Test-Path -LiteralPath $zipPath)
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}
