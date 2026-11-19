# GGOS power plan: built-in Ultimate Performance enable (v0.5.0) - option power-ultimate.
#
# Duplicates the built-in Ultimate Performance power plan template
# (GUID e9a42b02-d5df-448d-aa00-03f14749eb61 - the same built-in template the
# gaming option's desktop plan duplicates from in gaming-power.ps1), sets the
# duplicate active, and records the restore trail:
#   - powercfg -duplicatescheme assigns the new plan a system-generated GUID,
#     which is recorded under HKLM\SOFTWARE\GGOS\UltimatePowerPlan (PlanGuid)
#     so re-runs re-use the same plan (no "(2)"-style duplicate copies, the
#     same discipline as the fixed-GUID GGOS plans in gaming-power.ps1) and
#     verification can find it in powercfg /list.
#   - The user's previous active plan GUID is recorded under
#     HKLM\SOFTWARE\GGOS\PreviousPowerPlan (PreviousPlanGuid) ONLY when that
#     value does not already exist (read-before-write, per the gaming-power.ps1
#     record-once discipline: a later GGOS plan must never overwrite the
#     user's original plan GUID; a GGOS plan being active is also never
#     recorded as 'previous').
# Ordering note: main.yml runs this task after gaming.yml on purpose. If both
# gaming and power-ultimate are selected, both plans exist in powercfg /list
# and the one activated last (Ultimate Performance) is active.
# All external calls go through Invoke-GGCommand (spec B2 bounded timeout;
# timeouts are appended to %SystemRoot%\GGOS\skipped.txt by the wrapper).

param()

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force

$reg = Join-Path $env:SystemRoot 'System32\reg.exe'

# ---- v0.6.0 chassis guard ---------------------------------------------------
# The wizard no longer offers this as a checkbox (the plan is enabled as part of
# the automatic tuning), so the desktop-only decision now lives here. Ultimate
# Performance pins the processor at maximum: on a laptop or unknown chassis it
# is refused by design and the battery policy is left alone. Chassis resolution
# is the shared Get-GGChassis helper (ggos-common.psm1).
$resolvedChassis = Get-GGChassis
if ($resolvedChassis -ne 'Desktop') {
    Write-GGLog "Ultimate Performance is desktop-only; resolved chassis: $resolvedChassis - plan left unchanged."
    Write-Output 'GGOS power: Ultimate Performance skipped (not a desktop chassis).'
    exit 0
}

# Built-in Ultimate Performance template GUID (see header).
$templateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
# GGOS plan GUIDs from gaming-power.ps1 - never recorded as the user's
# 'previous' plan (a re-run must not point the restore record at ourselves).
$ggosPlanGuids = @(
    'd4a3b2c1-5f6e-4a7d-9b8c-2e1f0a3d5b6c',  # GGOS Performance (desktop)
    'c7d3a1e9-8b4f-4c62-9d5a-3f2e1b4a7c8d'   # GGOS Laptop
)

function Get-ActiveSchemeGuid {
    $ok, $exit, $out = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('/getactivescheme') -TimeoutSeconds 20 -Description 'read active power scheme'
    if (-not ($ok -and $exit -eq 0)) { return $null }
    $m = [regex]::Match(($out | Out-String), '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    return $null
}

function Get-PowerSchemeListText {
    $ok, $exit, $out = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('/list') -TimeoutSeconds 20 -Description 'enumerate power schemes'
    if (-not ($ok -and $exit -eq 0)) { return $null }
    return ($out | Out-String)
}

function Get-RecordedPlanGuid {
    # Returns the plan GUID previously recorded by a GGOS run, or $null.
    $ok, $exit, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('query', 'HKLM\SOFTWARE\GGOS\UltimatePowerPlan', '/v', 'PlanGuid') -TimeoutSeconds 20 -Description 'query recorded Ultimate plan GUID'
    if (-not ($ok -and $exit -eq 0)) { return $null }
    $m = [regex]::Match(($out | Out-String), '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    return $null
}

# ---------------------------------------------------------------------------
# 1. Resolve the plan: re-use the recorded duplicate, or create it
# ---------------------------------------------------------------------------
$listText = Get-PowerSchemeListText
if ($null -eq $listText) {
    Write-GGLog 'Warning: could not enumerate power plans - Ultimate Performance was not enabled.'
    exit 0
}

$planGuid = $null
$recordedGuid = Get-RecordedPlanGuid
if ($recordedGuid -and ($listText -match [regex]::Escape($recordedGuid))) {
    $planGuid = $recordedGuid
    Write-GGLog 'Ultimate Performance plan from a previous GGOS run is present - re-using it.'
}
else {
    $ok, $exit, $out = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('-duplicatescheme', $templateGuid) -TimeoutSeconds 30 -Description 'duplicate built-in Ultimate Performance template'
    if (-not ($ok -and $exit -eq 0)) {
        if ($ok) { Write-GGLog ('Warning: powercfg -duplicatescheme failed (exit ' + $exit + ').') }
        else { Write-GGLog 'Warning: powercfg -duplicatescheme timed out (see skipped.txt).' }
        exit 0
    }
    # Output: "Power Scheme GUID: <guid>  (Ultimate Performance)".
    $m = [regex]::Match(($out | Out-String), '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    if (-not $m.Success) {
        Write-GGLog 'Warning: could not parse the duplicated plan GUID from powercfg output.'
        exit 0
    }
    $planGuid = $m.Groups[1].Value.ToLowerInvariant()
    Write-GGLog ('Ultimate Performance plan duplicated: ' + $planGuid)
}

# Record the plan GUID (our own stamp - always current).
$ok, $exit, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('add', 'HKLM\SOFTWARE\GGOS\UltimatePowerPlan', '/v', 'PlanGuid', '/t', 'REG_SZ', '/d', $planGuid, '/f') -TimeoutSeconds 20 -Description 'record Ultimate Performance plan GUID'
if (Test-GGRegSuccess $ok $exit $out) { Write-GGLog ('Plan GUID recorded under HKLM\SOFTWARE\GGOS\UltimatePowerPlan: ' + $planGuid) }
else { Write-GGLog 'Warning: the UltimatePowerPlan PlanGuid record could not be written.' }

# ---------------------------------------------------------------------------
# 2. Record the user's previous active plan (ONLY if not already recorded)
# ---------------------------------------------------------------------------
$okPrev, $exitPrev, $outPrev = Invoke-GGCommand -FilePath $reg -ArgumentList @('query', 'HKLM\SOFTWARE\GGOS\PreviousPowerPlan', '/v', 'PreviousPlanGuid') -TimeoutSeconds 20 -Description 'query recorded previous power plan GUID'
$alreadyRecorded = ($okPrev -and $exitPrev -eq 0)
$activeGuid = Get-ActiveSchemeGuid
if ($alreadyRecorded) {
    Write-GGLog 'PreviousPowerPlan record already exists (an earlier GGOS run recorded the original plan) - left untouched.'
}
elseif ($activeGuid -and ($activeGuid -notin ($ggosPlanGuids + @($planGuid)))) {
    $okRec, $exitRec, $recOut = Invoke-GGCommand -FilePath $reg -ArgumentList @('add', 'HKLM\SOFTWARE\GGOS\PreviousPowerPlan', '/v', 'PreviousPlanGuid', '/t', 'REG_SZ', '/d', $activeGuid, '/f') -TimeoutSeconds 20 -Description 'record previous power plan GUID (Ultimate Performance enable)'
    if ($okRec -and $exitRec -eq 0) { Write-GGLog ('Previous active plan recorded for restore: ' + $activeGuid) }
    else { Write-GGLog 'Warning: the previous power plan GUID could not be recorded.' }
}
else {
    Write-GGLog 'Previous plan not recorded (a GGOS plan is already active or the active scheme could not be read).'
}

# ---------------------------------------------------------------------------
# 3. Activate the Ultimate Performance plan
# ---------------------------------------------------------------------------
$okAct, $exitAct, $actOut = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $planGuid) -TimeoutSeconds 20 -Description 'activate Ultimate Performance plan'
if ($okAct -and $exitAct -eq 0) {
    Write-GGLog ('Ultimate Performance plan activated: ' + $planGuid + ' (restore the previous plan with: powercfg /setactive <HKLM\SOFTWARE\GGOS\PreviousPowerPlan PreviousPlanGuid>).')
}
else {
    if ($okAct) { Write-GGLog ('Warning: activating the Ultimate Performance plan failed (exit ' + $exitAct + ').') }
    else { Write-GGLog 'Warning: activating the Ultimate Performance plan timed out (see skipped.txt).' }
}

exit 0
