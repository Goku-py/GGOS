# GGOS hardware policy - v0.2.1
#
# Detects the machine class (desktop/laptop), system-drive type (SSD/HDD) and installed RAM,
# then applies the hardware-dependent CORE settings (outside the gaming option):
#   - Desktop: hibernation + Fast Startup off (frees disk, avoids SSD write amplification)
#   - Laptop:  hibernation + Fast Startup left untouched (battery/mobility value)
#   - SSD:     scheduled defrag disabled (TRIM ensured instead) - defragging SSDs is harmful
#   - HDD:     scheduled defrag left enabled (weekly optimization remains useful)
# The resolved policy is recorded under HKLM\SOFTWARE\GGOS\HardwarePolicy for other
# scripts (gaming-power.ps1 re-detects chassis for its own branches) and for verification.
#
# Chassis detection uses Win32_SystemEnclosure ChassisTypes with a battery fallback
# (a battery present means laptop even when the enclosure read fails).

Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force

$ErrorActionPreference = 'Continue'
$policyRoot = 'HKLM:\SOFTWARE\GGOS\HardwarePolicy'

function Write-GGLog {
    param([string]$Message)
    Write-Output "GGOS hardware: $Message"
}

# ---- 1. Chassis detection ----
$chassis = 'Unknown'
try {
    $types = @((Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
    if ($types -match '^(8|9|10|11|12|14|18|21|23|30|31|32)$') { $chassis = 'Laptop' }
    elseif ($types -match '^(3|4|5|6|7|13|15|16|24|35|36)$') { $chassis = 'Desktop' }
} catch {
    Write-GGLog "Chassis detection failed: $($_.Exception.Message)"
}
if ($chassis -eq 'Unknown') {
    # Battery fallback: a machine with a battery is treated as a laptop.
    $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    if ($battery) { $chassis = 'Laptop'; Write-GGLog 'Battery detected - treating as laptop.' }
}
Write-GGLog "Chassis category: $chassis"

# ---- 2. System drive type ----
$driveType = 'Unknown'
try {
    $partition = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    if ($disk.MediaType -match 'SSD|SCM' -or $disk.BusType -eq 'NVMe') { $driveType = 'SSD' }
    elseif ($disk.MediaType -eq 'HDD') { $driveType = 'HDD' }
} catch {
    Write-GGLog "Drive type detection failed: $($_.Exception.Message)"
}
Write-GGLog "System drive type: $driveType"

# ---- 3. Installed RAM ----
$ramMB = 0
try {
    $ramMB = [math]::Round(((Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop |
        Measure-Object Capacity -Sum).Sum) / 1MB, 0)
} catch {
    Write-GGLog "RAM detection failed: $($_.Exception.Message)"
}
Write-GGLog "Installed RAM: $ramMB MB"

# ---- 4. Chassis-dependent core settings ----
$hibernationPolicy = 'Unchanged'
if ($chassis -eq 'Desktop') {
    $ok, $ggOut = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('/hibernate', 'off') `
        -TimeoutSeconds 30 -Description 'powercfg /hibernate off (desktop)'
    if ($ok) {
        $hibernationPolicy = 'Disabled'
        Write-GGLog 'Desktop policy: hibernation and Fast Startup disabled.'
    } else {
        Write-GGLog 'powercfg /hibernate off failed or timed out - hibernation left unchanged.'
    }
    $ok2, $ggOut = Invoke-GGCommand -FilePath 'reg.exe' -ArgumentList @(
        'add', 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power',
        '/v', 'HiberbootEnabled', '/t', 'REG_DWORD', '/d', '0', '/f') `
        -TimeoutSeconds 20 -Description 'Fast Startup off (HiberbootEnabled=0)'
    if (-not $ok2) { Write-GGLog 'HiberbootEnabled write failed or timed out.' }
} elseif ($chassis -eq 'Laptop') {
    Write-GGLog 'Laptop policy: hibernation and Fast Startup left enabled.'
} else {
    Write-GGLog 'Chassis unknown: hibernation and Fast Startup left unchanged.'
}

# ---- 5. Drive-type-dependent settings ----
$defragPolicy = 'Unchanged'
if ($driveType -eq 'SSD') {
    $ok3, $ggOut = Invoke-GGCommand -FilePath 'schtasks.exe' -ArgumentList @(
        '/change', '/tn', '\Microsoft\Windows\Defrag\ScheduledDefrag', '/disable') `
        -TimeoutSeconds 20 -Description 'disable ScheduledDefrag (SSD)'
    if ($ok3) {
        $defragPolicy = 'Disabled'
        Write-GGLog 'SSD policy: scheduled defrag disabled.'
    } else {
        Write-GGLog 'ScheduledDefrag disable failed or timed out (task may be absent).'
    }
    # TRIM must stay enabled on SSDs; 0 means NOT disabled.
    $ok4, $ggOut = Invoke-GGCommand -FilePath 'fsutil.exe' -ArgumentList @(
        'behavior', 'set', 'disabledeletenotify', '0') `
        -TimeoutSeconds 20 -Description 'ensure TRIM enabled (fsutil)'
    if ($ok4) { Write-GGLog 'SSD policy: TRIM confirmed enabled.' }
} elseif ($driveType -eq 'HDD') {
    $ok5, $ggOut = Invoke-GGCommand -FilePath 'schtasks.exe' -ArgumentList @(
        '/change', '/tn', '\Microsoft\Windows\Defrag\ScheduledDefrag', '/enable') `
        -TimeoutSeconds 20 -Description 'ensure ScheduledDefrag enabled (HDD)'
    if ($ok5) {
        $defragPolicy = 'Enabled'
        Write-GGLog 'HDD policy: scheduled defrag confirmed enabled.'
    } else {
        Write-GGLog 'ScheduledDefrag enable failed or timed out (task may be absent).'
    }
} else {
    Write-GGLog 'Drive type unknown: defrag and TRIM settings left unchanged.'
}

# ---- 6. Record the resolved policy ----
try {
    New-Item -Path $policyRoot -Force | Out-Null
    New-ItemProperty -Path $policyRoot -Name 'Chassis' -Value $chassis -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $policyRoot -Name 'DriveType' -Value $driveType -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $policyRoot -Name 'RamMB' -Value $ramMB -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $policyRoot -Name 'HibernationPolicy' -Value $hibernationPolicy -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $policyRoot -Name 'DefragPolicy' -Value $defragPolicy -PropertyType String -Force | Out-Null
    Write-GGLog "Policy recorded under HKLM\SOFTWARE\GGOS\HardwarePolicy."
} catch {
    Write-GGLog "Failed to record policy: $($_.Exception.Message)"
}

exit 0

