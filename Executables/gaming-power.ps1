# GGOS gaming power configuration (chassis-aware)
# Ported from TBOK's GamingTweaks routine (reference only, re-expressed; no upstream
# code or comments copied).
#   - Removes an explicit bcdedit useplatformclock override from the default boot
#     entry (reset HPET dependency detection).
#   - Detects the chassis type via Win32_SystemEnclosure.
#   - Desktop: disables power throttling (across control sets), activates the
#     Ultimate Performance plan, sets processor boost mode "Aggressive".
#   - Laptop: keeps the current power plan, sets boost mode "Efficient Aggressive".
#   - Unknown chassis: boot and power-plan changes are skipped; MMCS registry
#     values are applied by the YAML task either way.

$ErrorActionPreference = 'Continue'

function Write-GGLog {
    param([string]$Message)
    Write-Output "GGOS gaming: $Message"
}

$hadCritical = $false

# ---------------------------------------------------------------------------
# 1. bcdedit useplatformclock
# ---------------------------------------------------------------------------
try {
    $bcd = & bcdedit.exe /enum '{default}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-GGLog "Could not query the default boot entry: useplatformclock unchanged."
        $hadCritical = $true
    }
    elseif (($bcd | Out-String) -match 'useplatformclock') {
        & bcdedit.exe /deletevalue '{default}' useplatformclock 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-GGLog 'Removed explicit useplatformclock override.' }
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
        $row = (& reg.exe query 'HKLM\SYSTEM\Select' /v $valueName 2>$null) -join ' '
        if ($row -match '0x([0-9a-fA-F]+)') {
            $n = [int]('0x' + $Matches[1])
            if ($n -gt 0) {
                $cs = 'ControlSet{0:D3}' -f $n
                if ($cs -notin $sets) { $sets += $cs }
            }
        }
    }
    $failed = $false
    foreach ($cs in $sets) {
        & reg.exe add ("HKLM\SYSTEM\" + $cs + "\" + $RelPath) /v $Name /t $Type /d $Data /f 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-GGLog "Warning: could not write $cs\$RelPath\$Name."
            $failed = $true
        }
    }
    return -not $failed
}

# ---------------------------------------------------------------------------
# 4. Power-plan / boost-mode helpers
# ---------------------------------------------------------------------------
function Set-BoostMode {
    param([int]$AcValue, [int]$DcValue, [string]$Description)
    & powercfg.exe -attributes SUB_PROCESSOR PERFBOOSTMODE -ATTRIB_HIDE 2>&1 | Out-Null
    $a = $LASTEXITCODE
    & powercfg.exe -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE $AcValue 2>&1 | Out-Null
    $b = $LASTEXITCODE
    & powercfg.exe -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE $DcValue 2>&1 | Out-Null
    $c = $LASTEXITCODE
    & powercfg.exe -setactive SCHEME_CURRENT 2>&1 | Out-Null
    $d = $LASTEXITCODE
    if ($a -eq 0 -and $b -eq 0 -and $c -eq 0 -and $d -eq 0) {
        Write-GGLog "Processor boost mode configured: $Description."
        return $true
    }
    Write-GGLog "Warning: processor boost mode ($Description) did not complete cleanly (codes $a/$b/$c/$d)."
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

function Set-UltimatePerformancePlan {
    $guid = $null
    $list = & powercfg.exe /list 2>$null
    $line = ($list | Out-String) -split "`r?`n" | Where-Object { $_ -match 'Ultimate Performance' } | Select-Object -First 1
    if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $guid = $Matches[1]
    }
    if (-not $guid) {
        $dup = & powercfg.exe -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
        $line = ($dup | Out-String)
        if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $guid = $Matches[1]
            Write-GGLog 'Ultimate Performance plan was not present - created it.'
        }
    }
    if (-not $guid) {
        Write-GGLog 'Warning: could not find or create the Ultimate Performance plan.'
        return $false
    }
    & powercfg.exe /setactive $guid 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-GGLog "Warning: failed to activate Ultimate Performance plan $guid."
        return $false
    }
    Write-GGLog "Ultimate Performance plan activated: $guid."
    return $true
}

# ---------------------------------------------------------------------------
# 5. Branch by chassis
# ---------------------------------------------------------------------------
switch ($chassis) {
    'Desktop' {
        Write-GGLog 'Desktop policy: disabling power throttling and activating Ultimate Performance.'
        if (-not (Write-ControlSets 'Control\Power\PowerThrottling' 'PowerThrottlingOff' 'REG_DWORD' '1')) { $hadCritical = $true }
        # Not documented by Microsoft; community-derived values ported from the reference.
        Write-ControlSets 'Control\Power\PowerThrottling' 'NoLazyMode' 'REG_DWORD' '1' | Out-Null
        Write-ControlSets 'Control\Power\PowerThrottling' 'AlwaysOn' 'REG_DWORD' '0' | Out-Null
        Set-UltimatePerformancePlan | Out-Null
        Set-BoostMode 2 2 'Aggressive' | Out-Null
        Unlock-HiddenPowerSettings | Out-Null
    }
    'Laptop' {
        Write-GGLog 'Laptop policy: desktop-only power tweaks skipped; boost mode set to Efficient Aggressive.'
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
