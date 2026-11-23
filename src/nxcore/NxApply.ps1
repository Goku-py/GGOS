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
    if ($Kind -eq 'DWord')     { $v = [int][int64]$Value }
    if ($Kind -eq 'QWord')     { $v = [int64]$Value }
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
    if (-not $elig.eligible) { $summary | Add-Member -NotePropertyName skipped -NotePropertyValue $true; $summary.steps = $steps; return $summary }
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
                    $summary.steps = $steps
                    return $summary
                }
            } catch {
                Add-NxJournalEntry -Path $JournalRoot -TweakId $Tweak.id -TweakVersion ([string]$Tweak.version) -Operation 'failed' -Approval $approval -Original $orig -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
                $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'FAILED'; detail = [string]$_.Exception.Message }
                $summary | Add-Member -NotePropertyName failed -NotePropertyValue $true
                $summary.steps = $steps
                return $summary
            }
            $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Applied'; detail = "seq $($jr.seq) -> verified seq $($jr2.seq)" }
        }
        elseif ($a.type -eq 'service') {
            if ($Plan) { $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Planned'; detail = "service action '$($a.function)' (engine function, category implementation phase)" }; continue }
            $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'NotImplemented'; detail = "service engine function '$($a.function)' ships with its category implementation (Phase 4)" }
        }
        elseif ($a.type -eq 'function') {
            if ($Plan) {
                $pdesc = ''
                if ($a.parameters) { $pdesc = ($a.parameters | ConvertTo-Json -Compress -Depth 4) }
                $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Planned'; detail = "function '$($a.function)' $pdesc" }
                continue
            }
            # Category function dispatcher: resolve the function, pass declared
            # parameters + engine context only where the signature accepts them.
            $cmd = Get-Command -Name ([string]$a.function) -CommandType Function -ErrorAction SilentlyContinue
            if ($null -eq $cmd) {
                $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'NotImplemented'; detail = "engine function '$($a.function)' is not loaded (category module missing for this build)" }
                $summary | Add-Member -NotePropertyName failed -NotePropertyValue $true
                return $summary
            }
            $splat = @{}
            if ($a.parameters) {
                foreach ($p in $a.parameters.PSObject.Properties) { $splat[$p.Name] = $p.Value }
            }
            $context = @{
                JournalRoot = $JournalRoot; Approved = $true; Profiles = $Profiles
                TweakVersion = ([string]$Tweak.version); Approval = ([string]$Tweak.approval); TweakId = ([string]$Tweak.id)
            }
            foreach ($k in $context.Keys) {
                if ($cmd.Parameters.ContainsKey($k)) { $splat[$k] = $context[$k] }
            }
            # Some category modules name the journal parameter -JournalPath instead.
            if (-not $cmd.Parameters.ContainsKey('JournalRoot') -and $cmd.Parameters.ContainsKey('JournalPath')) { $splat['JournalPath'] = $JournalRoot }
            $engineEntry = [pscustomobject]@{ targetType = 'function'; name = [string]$a.function; parameters = $a.parameters }
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $Tweak.id -TweakVersion ([string]$Tweak.version) -Operation 'apply' -Approval ([string]$Tweak.approval) -Original $engineEntry -Modified $engineEntry -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
            try {
                $fnResult = & $cmd.Name @splat
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $Tweak.id -TweakVersion ([string]$Tweak.version) -Operation 'verify' -Approval ([string]$Tweak.approval) -Original $engineEntry -Modified $engineEntry -Result 'Success' -Verification 'FunctionExecuted' -Profiles $Profiles
                $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'FunctionExecuted'; detail = "function '$($a.function)' completed (function journals its own mutations)" }
            } catch {
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $Tweak.id -TweakVersion ([string]$Tweak.version) -Operation 'failed' -Approval ([string]$Tweak.approval) -Original $engineEntry -Modified $engineEntry -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
                $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'FAILED'; detail = [string]$_.Exception.Message }
                $summary | Add-Member -NotePropertyName failed -NotePropertyValue $true
                $summary.steps = $steps
                return $summary
            }
        }
        else {
            $steps += [pscustomobject]@{ step = 8; name = 'apply'; outcome = 'UnknownActionType'; detail = "action type '$($a.type)'" }
        }
    }
    $summary | Add-Member -NotePropertyName applied -NotePropertyValue $true
    $summary.steps = $steps
    return $summary
}

# Playbook-facing journaled registry writer: the generator routes registry
# actions through this function so NO configuration change can bypass the
# journal (ADR-006 journal-first invariant; replaces raw !registryValue writes).
function Invoke-NxRegistryTweak {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('String','ExpandString','DWord','QWord')][string]$Kind,
        [Parameter(Mandatory)][string]$Data,
        [Parameter(Mandatory)][string]$TweakId,
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string]$JournalRoot,
        [string[]]$Profiles = @(),
        [switch]$Plan,
        [switch]$Approved
    )
    # Binary/MultiString are refused from command-line routing (no lossless
    # string encoding); entries using them must ship as dedicated functions.
    $state = Read-NxManifest -Path $JournalRoot
    if (-not $state.present) { throw "$TweakId : journal not initialized at '$JournalRoot' - refusing to mutate (journal-first invariant)" }
    $value = $Data
    switch ($Kind) {
        'DWord' { $n = [int64]0; if (-not [int64]::TryParse($Data, [ref]$n) -or $n -lt 0 -or $n -gt 4294967295) { throw "$TweakId : DWord data '$Data' out of range" }; $value = [int]$n }
        'QWord' { $n = [int64]0; if (-not [int64]::TryParse($Data, [ref]$n)) { throw "$TweakId : QWord data '$Data' invalid" }; $value = $n }
        default { $value = $Data }
    }
    $steps = New-Object System.Collections.Generic.List[object]
    $summary = [pscustomobject]@{ tweakId = $TweakId; plan = $Plan.IsPresent; steps = $null; planned = $false; skipped = $false; failed = $false; applied = $false }
    $orig = Capture-NxRegistryValue -Path $Path -Name $Name
    $modified = [pscustomobject]@{ targetType = 'registry'; path = $Path; name = $Name; kind = $Kind; value = $value }
    $steps.Add([pscustomobject]@{ step = 2; name = 'capture-original'; outcome = 'Captured'; detail = "keyExisted=$($orig.keyExisted) existed=$($orig.existed) kind=$($orig.kind)" })
    if (-not $Plan -and -not $Approved) { throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)" }
    if ($Plan) {
        $steps.Add([pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Planned'; detail = "would set $Path :: $Name = $Kind : $Data" })
        $summary | Add-Member -NotePropertyName planned -NotePropertyValue $true
        $summary.steps = $steps.ToArray(); return $summary
    }
    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $orig -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Set-NxRegistryValue -Path $Path -Name $Name -Kind $Kind -Value $value
        $check = Test-NxConfigurationState -Path $Path -Name $Name -Kind $Kind -ExpectedValue $value
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $orig -Modified $modified -Result $(if ($check.verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($check.verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles
        if (-not $check.verified) {
            Restore-NxRegistryOriginal -Entry ([pscustomobject]@{ original = $orig }) | Out-Null
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles
            $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'FAILED'; detail = $check.reason })
            $summary | Add-Member -NotePropertyName failed -NotePropertyValue $true
            $summary.steps = $steps.ToArray(); return $summary
        }
        $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = $check.reason })
    } catch {
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
        $steps.Add([pscustomobject]@{ step = 8; name = 'apply'; outcome = 'FAILED'; detail = [string]$_.Exception.Message })
        $summary | Add-Member -NotePropertyName failed -NotePropertyValue $true
        $summary.steps = $steps.ToArray(); return $summary
    }
    $steps.Add([pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Applied'; detail = "$Path :: $Name" })
    $summary | Add-Member -NotePropertyName applied -NotePropertyValue $true
    $summary.steps = $steps.ToArray()
    return $summary
}

# Module loading: dot-source src/nxcore/Import-NxCore.ps1 at YOUR script scope:
#   . (Join-Path $PSScriptRoot 'src\nxcore\Import-NxCore.ps1')
# A function cannot persist dot-sourced definitions to its caller's scope
# (PowerShell scoping; found by W3-E 2026-11-23), so the old Import-NxCore
# function was removed. The generated playbook uses its own inline loader.
