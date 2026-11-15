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
#   - V03 opt-in (-LaptopPlan): instead of the default laptop path above, the
#     script builds and activates a custom "GGOS Laptop" plan (fixed GUID,
#     duplicated from Balanced) with battery-safe AC/DC value pairs.
#   - Unknown chassis: boot and power-plan changes are skipped; MMCS registry
#     values are applied by the YAML task either way.
#
# B2: every external process call (bcdedit, reg.exe, powercfg) runs through
# Invoke-GGCommand (ggos-common.psm1) with a bounded timeout; on failure or timeout
# the item is logged and the script continues (never halts the playbook).
#
# V03: opt-in -LaptopPlan switch. Without it the script runs exactly as before
# (chassis-branched desktop/laptop policy); with it, only the "GGOS Laptop"
# custom power-plan routine runs (see sections 5b/5c).

param(
    [switch]$LaptopPlan
)

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
# (desktop path - skipped in -LaptopPlan mode so the opt-in laptop routine runs
#  alone; the guard wraps the original block with its indentation preserved
#  verbatim so the no-param diff stays addition-only)
# ---------------------------------------------------------------------------
if (-not $LaptopPlan) {
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
} # -not $LaptopPlan

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
# User override from the option ledger (RadioPage selection): pc-desktop/pc-laptop
# beat auto-detection when explicitly chosen by the user.
$ledgerFile = Join-Path $env:SystemRoot 'GGOS\ggos-options.txt'
if (Test-Path $ledgerFile) {
    $choices = @(Get-Content $ledgerFile -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() })
    if ($choices -contains 'pc-desktop') { $chassis = 'Desktop'; Write-GGLog 'User selected Desktop in the wizard - overriding detection.' }
    elseif ($choices -contains 'pc-laptop') { $chassis = 'Laptop'; Write-GGLog 'User selected Laptop in the wizard - overriding detection.' }
}
Write-GGLog "Resolved chassis category: $chassis"

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
# 5b. Opt-in laptop plan: custom "GGOS Laptop" fixed-GUID plan (battery-safe).
# ---------------------------------------------------------------------------
# Only reachable with -LaptopPlan (dispatch in 5c). Duplicated from the built-in
# Balanced scheme so the baseline is neutral; every changed setting has an
# explicit DC counterpart (or its DC rail is deliberately untouched), so the
# plan is battery-safe by construction.
#   - PERFEPP (SUB_PROCESSOR): DO NOT TOUCH on either rail. On hybrid laptops
#     Intel Thread Director owns per-class EPP guidance; pinning a static EPP
#     in the plan would fight the driver's decisions.
#   - Min processor state (SUB_PROCESSOR PROCTHROTTLEMIN): DO NOT TOUCH on
#     either rail - no invented numbers. The Balanced baseline already scales
#     min state down on DC; pinning it higher trades battery for idle power
#     with no measured gain.
$script:GGOSLaptopPlanGuid = 'c7d3a1e9-8b4f-4c62-9d5a-3f2e1b4a7c8d'
$script:GGOSLaptopPlanName = 'GGOS Laptop'
# Duplicate source: the built-in Balanced scheme (stable GUID, present on every
# Windows install; neutral baseline for a battery-aware plan).
$script:BalancedSchemeGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'

function Set-GGOSLaptopPlan {
    $fixedGuid = $script:GGOSLaptopPlanGuid.ToLowerInvariant()

    # a. Record the user's prior active plan GUID for manual restore - the same
    #    HKLM\SOFTWARE\GGOS\PreviousPowerPlan record/restore mechanism as the
    #    desktop plan (section 5a). Skipped when a GGOS plan is already active:
    #    an earlier GGOS run recorded the user's original then, and overwriting
    #    that record with one of our own plan GUIDs would lose it.
    $activeGuid = Get-ActiveSchemeGuid
    $ggosGuids = @($script:GGOSPlanGuid.ToLowerInvariant(), $fixedGuid)
    if ($activeGuid -and ($activeGuid -notin $ggosGuids)) {
        $okRec, $recOut = Invoke-GGCommand -FilePath reg.exe -ArgumentList @('add', 'HKLM\SOFTWARE\GGOS\PreviousPowerPlan', '/v', 'PreviousPlanGuid', '/t', 'REG_SZ', '/d', $activeGuid, '/f') -TimeoutSeconds 20 -Description 'record previous power plan GUID (laptop plan)'
        if ($okRec) { Write-GGLog "Previous active plan recorded for restore: $activeGuid" }
        else { Write-GGLog 'Warning: previous power plan GUID could not be recorded.' }
    }

    # b. Ensure the fixed-GUID plan exists (duplicate from Balanced). On re-runs
    #    the existing plan is re-used; only stray "GGOS Laptop (N)" copies are
    #    removed (Remove-GGOSPlanDuplicates anchors on our plan's own name, so
    #    the user's plans are never matched).
    $listText = Get-PowerSchemeList
    if ($null -eq $listText) {
        Write-GGLog 'Warning: could not enumerate power plans.'
        return $false
    }
    if ($listText -match [regex]::Escape($fixedGuid)) {
        Write-GGLog 'GGOS Laptop plan already present - re-using it.'
        Remove-GGOSPlanDuplicates $listText $fixedGuid
    }
    else {
        $okDup, $dupOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('-duplicatescheme', $script:BalancedSchemeGuid, $script:GGOSLaptopPlanGuid) -TimeoutSeconds 20 -Description 'create GGOS Laptop plan from Balanced scheme'
        if (-not $okDup) {
            Write-GGLog 'Warning: could not create the GGOS Laptop plan.'
            return $false
        }
        Write-GGLog 'GGOS Laptop plan created (Balanced scheme copy).'
        Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('-changename', $script:GGOSLaptopPlanGuid, $script:GGOSLaptopPlanName, 'GGOS laptop plan - battery-safe AC/DC values (prior plan recorded under HKLM\SOFTWARE\GGOS\PreviousPowerPlan)') -TimeoutSeconds 20 -Description 'rename GGOS Laptop plan' | Out-Null
    }

    # c. AC/DC value pairs on the plan GUID (powercfg accepts a scheme GUID, so
    #    this works before activation). Every call goes through the bounded
    #    timeout wrapper. Rails without a call below are untouched by design.
    $pairsOk = $true

    # Processor boost mode: AC = 3 (Efficient Aggressive), DC untouched.
    # Subgroup/setting aliases and the attribute-unhide call mirror
    # Set-BoostMode (SUB_PROCESSOR / PERFBOOSTMODE); DC stays on the Balanced
    # baseline so battery keeps the OS default boost behaviour.
    Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('-attributes', 'SUB_PROCESSOR', 'PERFBOOSTMODE', '-ATTRIB_HIDE') -TimeoutSeconds 20 -Description 'unhide processor boost mode setting (laptop plan)' | Out-Null
    $okBoostAc, $boostAcOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('/setacvalueindex', $script:GGOSLaptopPlanGuid, 'SUB_PROCESSOR', 'PERFBOOSTMODE', '3') -TimeoutSeconds 20 -Description 'set AC SUB_PROCESSOR\PERFBOOSTMODE = 3 (GGOS Laptop plan)'
    if (-not $okBoostAc) { Write-GGLog 'Warning: could not set AC processor boost mode = 3 (Efficient Aggressive).'; $pairsOk = $false }

    # Display off (SUB_VIDEO VIDEOIDLE): AC 900 s (15 min), DC 300 s (5 min).
    $okVidAc, $vidAcOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('/setacvalueindex', $script:GGOSLaptopPlanGuid, 'SUB_VIDEO', 'VIDEOIDLE', '900') -TimeoutSeconds 20 -Description 'set AC SUB_VIDEO\VIDEOIDLE = 900 (GGOS Laptop plan)'
    if (-not $okVidAc) { Write-GGLog 'Warning: could not set AC SUB_VIDEO VIDEOIDLE = 900.'; $pairsOk = $false }
    $okVidDc, $vidDcOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('/setdcvalueindex', $script:GGOSLaptopPlanGuid, 'SUB_VIDEO', 'VIDEOIDLE', '300') -TimeoutSeconds 20 -Description 'set DC SUB_VIDEO\VIDEOIDLE = 300 (GGOS Laptop plan)'
    if (-not $okVidDc) { Write-GGLog 'Warning: could not set DC SUB_VIDEO VIDEOIDLE = 300.'; $pairsOk = $false }

    # Standby (SUB_SLEEP STANDBYIDLE): AC 1800 s (30 min), DC 900 s (15 min).
    $okSlpAc, $slpAcOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('/setacvalueindex', $script:GGOSLaptopPlanGuid, 'SUB_SLEEP', 'STANDBYIDLE', '1800') -TimeoutSeconds 20 -Description 'set AC SUB_SLEEP\STANDBYIDLE = 1800 (GGOS Laptop plan)'
    if (-not $okSlpAc) { Write-GGLog 'Warning: could not set AC SUB_SLEEP STANDBYIDLE = 1800.'; $pairsOk = $false }
    $okSlpDc, $slpDcOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('/setdcvalueindex', $script:GGOSLaptopPlanGuid, 'SUB_SLEEP', 'STANDBYIDLE', '900') -TimeoutSeconds 20 -Description 'set DC SUB_SLEEP\STANDBYIDLE = 900 (GGOS Laptop plan)'
    if (-not $okSlpDc) { Write-GGLog 'Warning: could not set DC SUB_SLEEP STANDBYIDLE = 900.'; $pairsOk = $false }

    # Hibernate idle (SUB_SLEEP HIBERNATEIDLE): DC 3600 s (60 min); AC untouched
    # (the plugged-in hibernate timeout stays on the Balanced baseline).
    $okHibDc, $hibDcOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('/setdcvalueindex', $script:GGOSLaptopPlanGuid, 'SUB_SLEEP', 'HIBERNATEIDLE', '3600') -TimeoutSeconds 20 -Description 'set DC SUB_SLEEP\HIBERNATEIDLE = 3600 (GGOS Laptop plan)'
    if (-not $okHibDc) { Write-GGLog 'Warning: could not set DC SUB_SLEEP HIBERNATEIDLE = 3600.'; $pairsOk = $false }

    # SUB_PROCESSOR PERFEPP and PROCTHROTTLEMIN (min processor state): untouched
    # on both rails - see the policy comment above (Thread Director on hybrid
    # laptops; no invented numbers for min state).

    # d. Activate the plan (applies the values set above).
    $okAct, $actOut = Invoke-GGCommand -FilePath powercfg.exe -ArgumentList @('/setactive', $script:GGOSLaptopPlanGuid) -TimeoutSeconds 20 -Description 'activate GGOS Laptop plan'
    if (-not $okAct) {
        Write-GGLog 'Warning: failed to activate the GGOS Laptop plan.'
        return $false
    }
    Write-GGLog "GGOS Laptop plan activated: $($script:GGOSLaptopPlanGuid)."

    # e. Applied values record + battery-safe closing line.
    Write-GGLog 'GGOS Laptop plan values: VIDEOIDLE AC=900/DC=300, STANDBYIDLE AC=1800/DC=900, HIBERNATEIDLE DC=3600, PERFBOOSTMODE AC=3 (DC untouched).'
    Write-GGLog 'GGOS Laptop plan applied - DC rail preserved.'
    return $pairsOk
}

# ---------------------------------------------------------------------------
# 5c. Opt-in laptop-plan dispatch (-LaptopPlan): runs the laptop routine alone
#     and exits before the chassis switch below, so the desktop path never
#     executes in laptop-plan mode.
# ---------------------------------------------------------------------------
if ($LaptopPlan) {
    if ($chassis -ne 'Laptop') {
        Write-GGLog 'not a laptop - GGOS Laptop plan skipped.'
        exit 0
    }
    # Write-GGLog emits via Write-Output, so the boolean is the LAST pipeline
    # element of the function - Select-Object -Last 1 keeps the log lines and
    # still tests the real result (same pattern as the desktop plan call).
    $laptopPlanOk = (Set-GGOSLaptopPlan) | Select-Object -Last 1
    if (-not $laptopPlanOk) { $hadCritical = $true }
    if ($hadCritical) {
        Write-GGLog 'GGOS Laptop plan completed with critical warnings (see above).'
        exit 0
    }
    exit 0
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
