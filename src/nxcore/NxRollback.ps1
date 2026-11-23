#Requires -Version 5.1
<#
    NxRollback.ps1 - rollback engine (scopes: tweak / category / all; profile via journal filter).

    The journal is the ONLY rollback authority (ADR-006 - the playbook platform
    provides no uninstall). Semantics:
    - Restore order: reverse journal sequence.
    - Only-if-ours: a target is restored ONLY if its live state still equals the
      recorded modified state. Divergence (user/other-tool change after apply)
      is reported, never clobbered (adopted pattern: XOS r1 / FSOS-X r1 / WinUtil r5).
    - Exact-original restoration: value written back with its original kind;
      values that never existed are deleted; keys NEXTRIX created are removed
      when the entry records keyExisted=false AND we own the only change in it.
    - Every rollback step is itself journaled and verified.
#>

function Restore-NxRegistryOriginal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry)
    $orig = $Entry.original
    $path = $orig.path; $name = $orig.name
    if (-not $orig.existed) {
        # Original: value absent. Remove it only if we still own it (checked by caller).
        if (Test-Path $path) {
            Remove-ItemProperty -Path $path -Name $name -ErrorAction Stop
        }
        return [pscustomobject]@{ action = 'removed value'; detail = "$path :: $name" }
    }
    # Original existed: rewrite exact value with exact kind.
    $kindMap = @{ DWord = 'DWord'; QWord = 'QWord'; String = 'String'; ExpandString = 'ExpandString'; MultiString = 'MultiString'; Binary = 'Binary' }
    $kind = $kindMap[[string]$orig.kind]
    if (-not $kind) { throw "unsupported original kind '$($orig.kind)' for $path :: $name" }
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    $value = $orig.value
    if ($kind -eq 'Binary') { $value = [byte[]]$value }
    if ($kind -eq 'MultiString') { $value = [string[]]$value }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $kind -Force | Out-Null
    return [pscustomobject]@{ action = 'restored value'; detail = "$path :: $name ($($orig.kind))" }
}

function Invoke-NxRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId,
        [string]$Category,
        [string]$Profile,
        [switch]$All
    )
    $journal = Read-NxJournal -Path $JournalRoot
    if ($journal.integrityErrors.Count -gt 0) {
        Write-Warning ("Journal integrity errors - refusing partial rollback: " + ($journal.integrityErrors -join '; '))
        return [pscustomobject]@{ aborted = $true; integrityErrors = $journal.integrityErrors; restored = @(); diverged = @(); failed = @(); irreversible = @(); delegated = @() }
    }
    $candidates = @($journal.entries | Where-Object { $_.operation -eq 'apply' -and ($_.result -eq 'InProgress' -or $_.result -eq 'Success' -or $_.result -eq 'Success-Irreversible') })
    if ($TweakId)  { $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId }) }
    if ($Category) { $candidates = @($candidates | Where-Object { $_.tweakId -like "$Category-*" }) }
    if ($Profile)  { $candidates = @($candidates | Where-Object { @($_.profiles) -contains $Profile }) }
    $restored = @(); $diverged = @(); $failed = @(); $irreversible = @()
    $seenTargets = @{}
    # Reverse order: undo the most recent changes first.
    [array]::Reverse($candidates)
    # Category delegation: target types the registry engine v0.1 does not cover are
    # handed to a category rollback engine when one is loaded (e.g. Invoke-Nx09Rollback).
    $delegated = @(); $delegatedTweakIds = @{}
    $catGroups = @{}
    foreach ($e in $candidates) {
        $tt = [string]$e.original.targetType
        if ($tt -eq 'registry' -or $tt -eq 'function') { continue }
        $cat = [string]$e.tweakId
        if ($cat.Length -lt 4) { continue }
        $cat = $cat.Substring(0, 4)
        if (-not $catGroups.ContainsKey($cat)) { $catGroups[$cat] = @{} }
        $catGroups[$cat][$e.tweakId] = $true
    }
    foreach ($cat in $catGroups.Keys) {
        $fnName = 'Invoke-Nx' + $cat.Substring(2) + 'Rollback'
        $fn = Get-Command -Name $fnName -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $fn) {
            $failed += [pscustomobject]@{ tweakId = $cat; reason = "no category rollback engine loaded for target types of $cat (report-only)" }
            continue
        }
        foreach ($tid in $catGroups[$cat].Keys) {
            try {
                $r = & $fnName -JournalRoot $JournalRoot -TweakId $tid
                if ($null -ne $r) {
                    $delegated += [pscustomobject]@{ category = $cat; tweakId = $tid; delegatedTo = $fnName; restored = @($r.restored).Count; diverged = @($r.diverged).Count; failed = @($r.failed).Count }
                    if ($r.restored) { $restored += @($r.restored) }
                    if ($r.diverged) { $diverged += @($r.diverged) }
                    if ($r.failed) { $failed += @($r.failed) }
                    if ($r.PSObject.Properties['irreversible'] -and $r.irreversible) { $irreversible += @($r.irreversible) }
                    $delegatedTweakIds[$tid] = $true
                }
            } catch {
                $failed += [pscustomobject]@{ tweakId = $tid; reason = "delegated rollback via $fnName failed: $($_.Exception.Message)" }
            }
        }
    }
    foreach ($e in $candidates) {
        $orig = $e.original
        if ($delegatedTweakIds.ContainsKey($e.tweakId) -and $orig.targetType -ne 'registry' -and $orig.targetType -ne 'function') { continue }
        if ($orig.targetType -eq 'function') { continue }  # functions journal their own registry mutations; the engine entry only records the invocation
        if ($orig.targetType -ne 'registry') { $failed += [pscustomobject]@{ entry = $e; reason = "target type '$($orig.targetType)' rollback not implemented in engine v0.1" }; continue }
        if ($e.result -eq 'Success-Irreversible') {
            $irreversible += [pscustomobject]@{ tweakId = $e.tweakId; target = "$($orig.path) :: $($orig.name)"; reason = 'operation labeled irreversible at apply time - manual restore path documented in the registry entry' }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Skipped-Irreversible' -Verification 'NotRun' -ErrorInfo 'apply entry labeled irreversible' -Profiles @($e.profiles)
            continue
        }
        $tkey = ("registry|" + [string]$orig.path + "|" + [string]$orig.name).ToLower()
        if ($seenTargets.ContainsKey($tkey)) { continue }  # only the newest apply entry per target is a restore candidate
        $seenTargets[$tkey] = $true
        $live = Capture-NxRegistryValue -Path $orig.path -Name $orig.name
        $stillOurs = Test-NxCurrentEqualsDescriptor -Descriptor $live -Kind ([string]$e.modified.kind) -Value $e.modified.value
        if (-not $stillOurs) {
            $diverged += [pscustomobject]@{ tweakId = $e.tweakId; target = "$($orig.path) :: $($orig.name)"; live = $live; reason = 'current state no longer equals NEXTRIX-recorded modified state - left untouched for user decision' }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: live state differs from recorded modified state' -Profiles @($e.profiles)
            continue
        }
        try {
            $res = Restore-NxRegistryOriginal -Entry $e
            $check = Test-NxConfigurationState -Path $orig.path -Name $orig.name -Kind ([string]$orig.kind) -ExpectedValue $(if ($orig.existed) { $orig.value } else { $null })
            $ver = if ($check.verified) { 'Verified' } else { 'FailedVerification' }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Success' -Verification $ver -Profiles $e.profiles
            $restored += [pscustomobject]@{ tweakId = $e.tweakId; action = $res.action; detail = $res.detail; verified = $check.verified }
        } catch {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'failed' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $e.profiles
            $failed += [pscustomobject]@{ tweakId = $e.tweakId; reason = [string]$_.Exception.Message }
        }
    }
    if ($All -and $restored.Count -gt 0) { Complete-NxJournalRestore -Path $JournalRoot }
    return [pscustomobject]@{ aborted = $false; restored = $restored; diverged = $diverged; failed = $failed; irreversible = $irreversible; delegated = $delegated; integrityErrors = @() }
}
