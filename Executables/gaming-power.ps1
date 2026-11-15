# GGOS gaming power configuration (chassis-aware) - v0.2 C2/C4 rework
# Ported from TBOK's GamingTweaks routine (reference only, re-expressed; no upstream
# code or comments copied).
#   - Removes an explicit bcdedit useplatformclock override from the default boot
#     entry (reset HPET dependency detection).
#   - Detects the chassis type via Win32_SystemEnclosure.
#   - Desktop: disables power throttling (across control sets), imports the built-in
#     Ultimate Performance template under a fixed GGOS plan GUID (the user's prior
#     active plan GUID is recorded to HKLM\SOFTWARE\GGOS\PreviousPowerPlan for manual
#     restore), removes stray "(2)"/"(3)" duplicate-named copies, activates the plan,
#     zeroes AC monitor/standby timeouts, sets processor boost mode "Aggressive" on
#     both AC and DC, and writes the Win32PrioritySeparation decision record (0x26).
#   - Laptop: the user's power plan is left completely untouched. Reason: switching a
#     laptop's plan trades away the OS's own AC/DC power management on battery for a
#     marginal performance gain, so only processor boost mode "Efficient Aggressive"
#     is applied to the current plan (battery-life-preserving policy).
#   - Unknown chassis: boot and power-plan changes are skipped; MMCS registry
#     values are applied by the YAML task either way.
#
# B2: every external process call (bcdedit, reg.exe, powercfg) runs through
# Invoke-GGCommand (ggos-common.psm1) with a bounded timeout; on failure or timeout
# the item is logged and the script continues (never halts the playbook).

$ErrorActionPreference = 'Continue'
$hadCritical = $false

function Write-GGLog {
    param([string]$Message)
    Write-Output "GGOS gaming: $Message"
}

# ---------------------------------------------------------------------------
# 0. Shared command wrapper (B2)
# ---------------------------------------------------------------------------
# ArgumentList elements are passed as raw tokens; the wrapper is responsible for
# quoting any token that contains spaces when it builds the command line.
$ggCommonPath = Join-Path $PSScriptRoot 'ggos-common.psm1'
if (Test-Path -LiteralPath $ggCommonPath) {
    Import-Module $ggCommonPath -Force
}
if (-not (Get-Command Invoke-GGCommand -ErrorAction SilentlyContinue)) {
    # Fallback shim when the shared module is absent: run the command directly
    # (without the bounded timeout) so the tweak still applies instead of failing.
    function Invoke-GGCommand {
        param(
            [Parameter(Mandatory = $true)][string]$FilePath,
            [string[]]$ArgumentList = @(),
            [int]$TimeoutSeconds = 20,
            [string]$Description = $FilePath
        )
        Write-GGLog "Warning: ggos-common module not found - running without timeout: $Description"
        try {
            $out = (& $FilePath @ArgumentList 2>&1) -join "`n"
            return ($LASTEXITCODE -eq 0), [string]$out
        }
        catch {
            return $false, $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# 1. bcdedit useplatformclock
# ---------------------------------------------------------------------------
try {
    $okBcd, $bcd = Invoke-GGCommand -FilePath bcdedit.exe -ArgumentList @('/enum', '{default}') -TimeoutSeconds 20 -Description 'query default boot entry (useplatformclock)'
    if (-not $okBcd) {
        Write-GGLog "Could not query the default boot entry: useplatformclock unchanged."
        $hadCritical = $true
    }
    elseif (($bcd | Out-String) -match 'useplatformclock') {
        $okDel, $delOut = Invoke-GGCommand -FilePath bcdedit.exe -ArgumentList @('/deletevalue', '{default}', 'useplatformclock') -TimeoutSeconds 20 -Description 'remove useplatformclock override'
        if ($okDel) { Write-GGLog 'Removed explicit useplatformclock override.' }
        else { Write-GGLog 'Warning: failed to remove the useplatformclock override.'; $hadCritical = $true }
    }
    else {
        Write-GGLog 'useplatformclock is not explicitly configured; no change needed.'
    }
}
catch {
    Write-GGLog "Warning: bcdedit query failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 2. Chassis detection
# ---------------------------------------------------------------------------
$chassis = 'Unknown'
try {
    $types = @((Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
    if ($types -match '^(8|9|10|11|12|14|18|21|23|30|31|32)$') { $chassis = 'Laptop' }
    elseif ($types -match '^(3|4|5|6|7|13|15|16|24|35|36)$') { $chassis = 'Desktop' }
}
catch {
    Write-GGLog "Warning: chassis detection failed: $($_.Exception.Message)"
}
Write-GGLog "Detected chassis category: $chassis"

# ---------------------------------------------------------------------------
# 3. Control-set-wide power throttling keys (desktop only)
# ---------------------------------------------------------------------------
function Write-ControlSets {
    param([string]$RelPath, [string]$Name, [string]$Type, [string]$Data)
    # Resolve Current, Default and LastKnownGood control sets from HKLM\SYSTEM\Select.
    $sets = @()
    foreach ($valueName in @('Current', 'Default', 'LastKnownGood')) {
        $okSel, $row = Invoke-GGCommand -FilePath reg.exe -ArgumentList @('query', 'HKLM\SYSTEM\Select', '/v', $valueName) -TimeoutSeconds 20 -Description "query HKLM\SYSTEM\Select\$valueName"
        if (-not $okSel) { continue }
        if (($row | Out-String) -match '0x([0-9a-fA-F]+)') {
            $n = [int]('0x' + $Matches[1])
            if ($n -gt 0) {
                $cs = 'ControlSet{0:D3}' -f $n
                if ($cs -notin $sets) { $sets += $cs }
            }
        }
    }
    $failed = $false
    foreach ($cs in $sets) {
        $okAdd, $addOut = Invoke-GGCommand -FilePath reg.exe -ArgumentList @('add', ("HKLM\SYSTEM\" + $cs + "\" + $RelPath), '/v', $Name, '/t', $Type, '/d', $Data, '/f') -TimeoutSeconds 20 -Description "write $cs\$RelPath\$Name"
        if (-not $okAdd) {
            Write-GGLog "Warning: could not write $cs\$RelPath\$Name."
            $failed = $true
        }
    }
    return -not $failed
}

# ---------------------------------------------------------------------------
# 4. Power-plan / boost-mode helpers
# ---------------------------------------------------------------------------
# C2: fixed GUID for the GGOS desktop gaming power plan. Chosen once and stable
# across runs so re-imports never spawn "(2)"/"(3)"-style renamed copies.
$script:GGOSPlanGuid = 'd4a3b2c1-5f6e-4a7d-9b8c-2e1f0a3d5b6c'
$script:GGOSPlanName = 'GGOS Performance'
# Built-in Ultimate Performance template used as the import source.
$script:UltimatePerfTemplateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

function Set-BoostMode {
    param([int]$AcValue, [int]$DcValue, [string]$Description)
    Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('-attributes', 'SUB_PROCESSOR', 'PERFBOOSTMODE', '-ATTRIB_HIDE') -TimeoutSeconds 20 -Description 'unhide processor boost mode setting' | Out-Null
    $okAc, $oAc = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('-setacvalueindex', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PERFBOOSTMODE', "$AcValue") -TimeoutSeconds 20 -Description "boost mode AC=$AcValue"
    $okDc, $oDc = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('-setdcvalueindex', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PERFBOOSTMODE', "$DcValue") -TimeoutSeconds 20 -Description "boost mode DC=$DcValue"
    $okRe, $oRe = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('-setactive', 'SCHEME_CURRENT') -TimeoutSeconds 20 -Description 're-apply current power scheme (boost mode)'
    if ($okAc -and $okDc -and $okRe) {
        Write-GGLog "Processor boost mode configured: $Description."
        return $true
    }
    Write-GGLog "Warning: processor boost mode ($Description) did not complete cleanly."
    return $false
}

function Unlock-HiddenPowerSettings {
    $keys = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings' -Recurse -ErrorAction SilentlyContinue
    $failed = 0
    foreach ($key in $keys) {
        if ($key.Name -match 'DefaultPowerSchemeValues') { continue }
        try {
            Set-ItemProperty -Path $key.PSPath -Name Attributes -Value 2 -Force -ErrorAction SilentlyContinue
        }
        catch { $failed++ }
    }
    if ($failed -gt 0) {
        Write-GGLog "Warning: $failed hidden power settings could not be unlocked."
        return $false
    }
    Write-GGLog 'Hidden power-plan settings unlocked.'
    return $true
}

function Get-ActiveSchemeGuid {
    $okScheme, $out = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('/getactivescheme') -TimeoutSeconds 20 -Description 'read active power scheme'
    if (-not $okScheme) { return $null }
    $m = [regex]::Match(($out | Out-String), '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
    return $null
}

function Get-PowerSchemeList {
    $okList, $out = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('/list') -TimeoutSeconds 20 -Description 'enumerate power schemes'
    if (-not $okList) { return $null }
    return ($out | Out-String)
}

function Remove-GGOSPlanDuplicates {
    param([string]$ListText, [string]$FixedGuid)
    # Parse "Power Scheme GUID: <guid>  (<name>)" lines from powercfg /list.
    $schemes = @()
    foreach ($line in ($ListText -split "`r?`n")) {
        if ($line -match 'Power Scheme GUID:\s*([0-9a-fA-F-]{36})\s*\((.*)\)') {
            $schemes += [pscustomobject]@{ Guid = $Matches[1].ToLowerInvariant(); Name = $Matches[2].Trim() }
        }
    }
    $ours = $schemes | Where-Object { $_.Guid -eq $FixedGuid } | Select-Object -First 1
    if (-not $ours) {
        Write-GGLog 'Duplicate cleanup skipped: GGOS plan name could not be resolved.'
        return
    }
    # Only delete copies named "<our plan name> (N)" - the user's own plans that
    # merely happen to end in "(2)" are never matched.
    $dupPattern = [regex]::Escape($ours.Name) + '\s*\((\d+)\)$'
    foreach ($s in ($schemes | Where-Object { $_.Guid -ne $FixedGuid -and $_.Name -match $dupPattern })) {
        $okDel, $delOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('-delete', $s.Guid) -TimeoutSeconds 20 -Description "delete duplicate power plan copy '$($s.Name)'"
        if ($okDel) { Write-GGLog "Removed duplicate power plan copy: $($s.Name)." }
        else { Write-GGLog "Warning: could not remove duplicate power plan copy '$($s.Name)' (possibly active)."; }
    }
}

# ---------------------------------------------------------------------------
# 5. C2 desktop plan: fixed-GUID import, prior-plan record, activate, value pairs
# ---------------------------------------------------------------------------
function Set-GGOSDesktopPlan {
    $fixedGuid = $script:GGOSPlanGuid.ToLowerInvariant()

    # 5a. Record the user's prior active plan GUID for manual restore. Skipped when
    #     our plan is already active (a previous GGOS run), otherwise the record
    #     would point at our own plan instead of the user's original.
    $activeGuid = Get-ActiveSchemeGuid
    if ($activeGuid -and $activeGuid -ne $fixedGuid) {
        $okRec, $recOut = Invoke-GGCommand -FilePath reg.exe -ArgumentList @('add', 'HKLM\SOFTWARE\GGOS\PreviousPowerPlan', '/v', 'PreviousPlanGuid', '/t', 'REG_SZ', '/d', $activeGuid, '/f') -TimeoutSeconds 20 -Description 'record previous power plan GUID'
        if ($okRec) { Write-GGLog "Previous active plan recorded for restore: $activeGuid" }
        else { Write-GGLog 'Warning: previous power plan GUID could not be recorded.' }
    }

    # 5b. Ensure the fixed-GUID plan exists (import the Ultimate Performance
    #     template under our GUID; specifying the destination GUID keeps the name
    #     stable and avoids the "(2)"-style renames).
    $listText = Get-PowerSchemeList
    if ($null -eq $listText) {
        Write-GGLog 'Warning: could not enumerate power plans.'
        return $false
    }
    $planExists = $listText -match [regex]::Escape($fixedGuid)
    if ($planExists) {
        # 5c. A previous GGOS run already imported the plan: remove stray
        #     duplicate-named copies, then re-activate and re-apply values below.
        Write-GGLog 'GGOS performance plan already present.'
        Remove-GGOSPlanDuplicates $listText $fixedGuid
    }
    else {
        $okDup, $dupOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('-duplicatescheme', $script:UltimatePerfTemplateGuid, $script:GGOSPlanGuid) -TimeoutSeconds 20 -Description 'create GGOS performance plan from Ultimate Performance template'
        if (-not $okDup) {
            Write-GGLog 'Warning: could not create the GGOS performance plan.'
            return $false
        }
        Write-GGLog 'GGOS performance plan imported (Ultimate Performance template).'
        Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('-changename', $script:GGOSPlanGuid, $script:GGOSPlanName, 'GGOS desktop gaming performance plan (prior plan recorded under HKLM\SOFTWARE\GGOS\PreviousPowerPlan)') -TimeoutSeconds 20 -Description 'rename GGOS performance plan' | Out-Null
    }

    # 5d. Activate the plan.
    $okAct, $actOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('/setactive', $script:GGOSPlanGuid) -TimeoutSeconds 20 -Description 'activate GGOS performance plan'
    if (-not $okAct) {
        Write-GGLog 'Warning: failed to activate the GGOS performance plan.'
        return $false
    }
    Write-GGLog "GGOS performance plan activated: $($script:GGOSPlanGuid)."

    # 5e. AC/DC value pairs on the now-active plan (SCHEME_CURRENT).
    #     Desktop policy: performance values on both AC and DC (boost mode is set
    #     by Set-BoostMode 2/2 in the desktop branch); monitor/standby timeouts
    #     are zeroed on AC only - DC defaults stay untouched.
    $pairs = @(
        @('SUB_VIDEO', 'VIDEOIDLE', '0'),   # monitor timeout
        @('SUB_SLEEP', 'STANDBYIDLE', '0')  # standby (sleep) timeout
    )
    $pairsOk = $true
    foreach ($p in $pairs) {
        $okPair, $pairOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('/setacvalueindex', 'SCHEME_CURRENT', $p[0], $p[1], $p[2]) -TimeoutSeconds 20 -Description "set AC $($p[0])\$($p[1]) = $($p[2])"
        if (-not $okPair) {
            Write-GGLog "Warning: could not set AC $($p[0]) $($p[1]) = $($p[2])."
            $pairsOk = $false
        }
    }
    $okApply, $applyOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('/setactive', 'SCHEME_CURRENT') -TimeoutSeconds 20 -Description 're-apply current power scheme (timeouts)'
    if (-not $okApply) {
        Write-GGLog 'Warning: re-applying the active power scheme after timeout changes failed.'
        $pairsOk = $false
    }
    return $pairsOk
}

# ---------------------------------------------------------------------------
# 6. Branch by chassis
# ---------------------------------------------------------------------------
switch ($chassis) {
    'Desktop' {
        Write-GGLog 'Desktop policy: power throttling off, fixed-GUID GGOS performance plan, decision-recorded priority separation.'
        $throttleOk = (Write-ControlSets 'Control\Power\PowerThrottling' 'PowerThrottlingOff' 'REG_DWORD' '1') | Select-Object -Last 1
        if (-not $throttleOk) { $hadCritical = $true }
        # Not documented by Microsoft; community-derived values ported from the reference.
        Write-ControlSets 'Control\Power\PowerThrottling' 'NoLazyMode' 'REG_DWORD' '1' | Out-Null
        Write-ControlSets 'Control\Power\PowerThrottling' 'AlwaysOn' 'REG_DWORD' '0' | Out-Null

        # C2: plan rework. Runs before boost mode so SCHEME_CURRENT targets our plan.
        # Write-GGLog emits via Write-Output, so the boolean is the LAST pipeline
        # element of the function - Select-Object -Last 1 keeps the log lines and
        # still tests the real result.
        $planOk = (Set-GGOSDesktopPlan) | Select-Object -Last 1
        if (-not $planOk) { $hadCritical = $true }

        # C4 decision record - Win32PrioritySeparation.
        # Decision: 0x26 (short/variable/high-boost — the Windows default) set explicitly
        # to document intent; fixed-quantum values rejected due to community conflict
        # and benchmark variance. Skipped on laptop by design (least-surprise policy).
        $okWps, $wpsOut = Invoke-GGCommand -FilePath reg.exe -ArgumentList @('add', 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl', '/v', 'Win32PrioritySeparation', '/t', 'REG_DWORD', '/d', '38', '/f') -TimeoutSeconds 20 -Description 'set Win32PrioritySeparation decision record (0x26/38)'
        if ($okWps) { Write-GGLog 'Win32PrioritySeparation decision record written: 0x26 (38).' }
        else { Write-GGLog 'Warning: Win32PrioritySeparation could not be written.'; $hadCritical = $true }

        Set-BoostMode 2 2 'Aggressive' | Out-Null
        Unlock-HiddenPowerSettings | Out-Null
    }
    'Laptop' {
        Write-GGLog 'Laptop policy: power plan left untouched (battery life); boost mode set to Efficient Aggressive.'
        Set-BoostMode 3 3 'Efficient Aggressive' | Out-Null
        Unlock-HiddenPowerSettings | Out-Null
    }
    default {
        Write-GGLog 'Chassis type unknown: power plan and throttling changes skipped.'
    }
}

if ($hadCritical) {
    Write-GGLog 'Gaming power configuration completed with critical warnings (see above).'
    exit 0
}

Write-GGLog 'Gaming power configuration complete.'
exit 0
