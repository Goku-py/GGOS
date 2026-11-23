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
        return [pscustomobject]@{ aborted = $true; integrityErrors = $journal.integrityErrors; restored = @(); diverged = @(); failed = @() }
    }
    $candidates = @($journal.entries | Where-Object { $_.operation -eq 'apply' -and $_.result -eq 'Success' })
    if ($TweakId)  { $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId }) }
    if ($Category) { $candidates = @($candidates | Where-Object { $_.tweakId -like "$Category-*" }) }
    if ($Profile)  { $candidates = @($candidates | Where-Object { @($_.profiles) -contains $Profile }) }
    $restored = @(); $diverged = @(); $failed = @()
    # Reverse order: undo the most recent changes first.
    [array]::Reverse($candidates)
    foreach ($e in $candidates) {
        $orig = $e.original
        if ($orig.targetType -ne 'registry') { $failed += [pscustomobject]@{ entry = $e; reason = "target type '$($orig.targetType)' rollback not implemented in engine v0.1" }; continue }
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
    return [pscustomobject]@{ aborted = $false; restored = $restored; diverged = $diverged; failed = $failed; integrityErrors = @() }
}
