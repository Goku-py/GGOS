#Requires -Version 5.1
<#
    NxApply.ps1 - the 10-step apply pipeline (directive Section 8, no exceptions):

      1 identify target -> 2 read current state -> 3 record exact original value
      -> 4 record value type -> 5 record value existence -> 6 record key existence
      -> 7 persist to journal -> 8 apply -> 9 verify -> 10 update journal.

    -Plan performs steps 1-7 conceptually (read-only captures + a plan report)
    and NEVER writes: no journal entry, no mutation. A step failure produces a
    clear failure record and a safe stop - never a silent continue.
    -Approved is mandatory for real application: nothing applies without
    explicit approval evidence recorded in the journal.
#>

function Set-NxRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('String','ExpandString','Binary','DWord','MultiString','QWord')][string]$Kind,
        [Parameter(Mandatory)]$Value
    )
    # Never New-Item -Force an EXISTING key (deletes subkeys first - WinUtil lesson r5).
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    $v = $Value
    if ($Kind -eq 'Binary')    { $v = [byte[]]$Value }
    if ($Kind -eq 'MultiString') { $v = [string[]]$Value }
    New-ItemProperty -Path $Path -Name $Name -Value $v -PropertyType $Kind -Force | Out-Null
}

function Invoke-NxApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Tweak,
        [Parameter(Mandatory)]$HardwareReport,
        [Parameter(Mandatory)]$BuildReport,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string[]]$Profiles = @(),
        [switch]$Plan,
        [switch]$Approved
    )
    $steps = @()
    $summary = [pscustomobject]@{ tweakId = $Tweak.id; plan = $Plan.IsPresent; steps = $steps }

    # Step 1: eligibility (graceful skip with reasons - never a hard error).
    $elig = Get-NxTweakEligibility -Tweak $Tweak -HardwareReport $HardwareReport -BuildReport $BuildReport
    $steps += [pscustomobject]@{ step = 1; name = 'eligibility'; outcome = if ($elig.eligible) { 'Pass' } else { 'Skip' }; detail = ($elig.reasons -join '; ') }
    if (-not $elig.eligible) { $summary | Add-Member -NotePropertyName skipped -NotePropertyValue $true; return $summary }
    foreach ($w in $elig.warnings) { $steps += [pscustomobject]@{ step = 1; name = 'eligibility-warning'; outcome = 'Warn'; detail = $w } }

    # Approval gate: real application requires -Approved (never automatic).
    if (-not $Plan -and -not $Approved) {
        throw "tweak $($Tweak.id): real application requires -Approved (nothing applies without explicit approval evidence)"
    }

    foreach ($a in @($Tweak.apply.actions)) {
        $approval = [string]$Tweak.approval
        if ($a.type -eq 'registry') {
            # Steps 2-6: capture exact original state (read-only).
            $orig = Capture-NxRegistryValue -Path $a.path -Name $a.name
            $steps += [pscustomobject]@{
                step = 2; name = 'capture-original'
                outcome = 'Captured'
                detail = "path=$($a.path) name=$($a.name) keyExisted=$($orig.keyExisted) existed=$($orig.existed) kind=$($orig.kind)"
            }
            $modified = [pscustomobject]@{ targetType = 'registry'; path = $a.path; name = $a.name; kind = $a.kind; value = $a.data }
            if ($Plan) {
                $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Planned'; detail = "would set $($a.path) :: $($a.name) = $($a.kind):$($a.data)" }
                continue
            }
            # Step 7: journal BEFORE any mutation (journal-first invariant).
            $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $Tweak.id -TweakVersion ([string]$Tweak.version) -Operation 'apply' -Approval $approval -Original $orig -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
            try {
                # Step 8: apply.
                Set-NxRegistryValue -Path $a.path -Name $a.name -Kind $a.kind -Value $a.data
                # Step 9: verify configuration effect.
                $check = Test-NxConfigurationState -Path $a.path -Name $a.name -Kind $a.kind -ExpectedValue $a.data
                # Step 10: journal the result.
                $res = if ($check.verified) { 'Success' } else { 'FailedVerification' }
                $jr2 = Add-NxJournalEntry -Path $JournalRoot -TweakId $Tweak.id -TweakVersion ([string]$Tweak.version) -Operation 'verify' -Approval $approval -Original $orig -Modified $modified -Result $res -Verification $(if ($check.verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles
                $steps += [pscustomobject]@{ step = 9; name = 'verify'; outcome = $(if ($check.verified) { 'Verified' } else { 'FAILED' }); detail = $check.reason }
                if (-not $check.verified) {
                    # Safe stop + immediate best-effort restore of the exact original.
                    Restore-NxRegistryOriginal -Entry ([pscustomobject]@{ original = $orig }) | Out-Null
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $Tweak.id -TweakVersion ([string]$Tweak.version) -Operation 'failed' -Approval $approval -Original $orig -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles
                    $summary | Add-Member -NotePropertyName failed -NotePropertyValue $true
                    return $summary
                }
            } catch {
                Add-NxJournalEntry -Path $JournalRoot -TweakId $Tweak.id -TweakVersion ([string]$Tweak.version) -Operation 'failed' -Approval $approval -Original $orig -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
                $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'FAILED'; detail = [string]$_.Exception.Message }
                $summary | Add-Member -NotePropertyName failed -NotePropertyValue $true
                return $summary
            }
            $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Applied'; detail = "seq $($jr.seq) -> verified seq $($jr2.seq)" }
        }
        elseif ($a.type -eq 'service') {
            if ($Plan) { $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Planned'; detail = "service action '$($a.function)' (engine function, category implementation phase)" }; continue }
            $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'NotImplemented'; detail = "service engine function '$($a.function)' ships with its category implementation (Phase 4)" }
        }
        elseif ($a.type -eq 'function') {
            if ($Plan) { $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Planned'; detail = "function '$($a.function)' (engine function)" }; continue }
            $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'NotImplemented'; detail = "engine function '$($a.function)' ships with its category implementation (Phase 4)" }
        }
        else {
            $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'UnknownActionType'; detail = "action type '$($a.type)'" }
        }
    }
    $summary | Add-Member -NotePropertyName applied -NotePropertyValue $true
    return $summary
}

# Convenience wrapper: dot-source all NxCore modules in dependency order.
function Import-NxCore {
    [CmdletBinding()]
    param([string]$Root)
    if (-not $Root) { $Root = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\nxcore' }
    foreach ($m in 'NxJournal.ps1','NxBuild.ps1','NxHardware.ps1','NxCompat.ps1','NxVerify.ps1','NxRollback.ps1','NxApply.ps1') {
        . (Join-Path $Root $m)
    }
}
