# GGOS hardware tuning - v0.3 (research-backed, mode-based)
#
# Modes (each gated by its own playbook option):
#   epp      - Energy Performance Preference = 0 (max performance) on the ACTIVE scheme
#              and the GGOS Performance plan. AC only. Documented hidden setting
#              (PERFEPP); desktop-only by page placement - scripts do not assume it.
#   devices  - PCIe Link State Power Management (ASPM) off on AC. Desktop page.
#   nvme     - Unhide + raise Primary NVMe Idle Timeout (documented GUID
#              D639518A-E56D-4345-8AF2-B9F32FB26109) to 60000 ms on AC only.
#              DC (battery) untouched by design. SEC NVMe timeout is build-dependent
#              and is attempted best-effort via alias discovery.
#   wireless - USB selective suspend off on AC (documented wireless dongle stutter
#              fix) + Bluetooth radio power-management off (PnPCapabilities=24,
#              originals recorded). Laptop: AC only, DC untouched.
#
# All external calls go through ggos-common Invoke-GGCommand (bounded timeouts,
# skipped.txt logging). Originals recorded under HKLM\SOFTWARE\GGOS\HardwarePolicy\Undo.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('epp', 'devices', 'nvme', 'wireless')]
    [string]$Mode
)

Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force

$ErrorActionPreference = 'Continue'
$undoRoot = 'HKLM:\SOFTWARE\GGOS\HardwarePolicy\Undo'

function Write-GGLog {
    param([string]$Message)
    Write-Output "GGOS hardware: $Message"
}

function Save-UndoValue {
    param([string]$Area, [string]$Name, [string]$Value)
    $key = Join-Path $undoRoot $Area
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Get-PowerValue {
    # Returns the current AC (or DC) value of a powercfg setting as a string, or ABSENT.
    param([string]$Subgroup, [string]$Setting, [switch]$DC)
    $args = @('/q', 'SCHEME_CURRENT', $Subgroup, $Setting)
    $ok, $out = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList $args -TimeoutSeconds 20 -Description "powercfg query $Subgroup $Setting"
    if (-not $ok) { return 'ABSENT' }
    $lines = $out -join "`n"
    if ($DC) { $pattern = 'Current (DC|Battery) Power Setting Index:\s*(0x[0-9a-fA-F]+)' }
    else { $pattern = 'Current (AC|Plugged) Power Setting Index:\s*(0x[0-9a-fA-F]+)' }
    if ($lines -match $pattern) { return $Matches[2] }
    return 'ABSENT'
}

function Set-PowerValue {
    # Sets AC (or DC) index on the active scheme, records the original, then applies.
    param([string]$Subgroup, [string]$Setting, [string]$Value, [string]$Description, [switch]$DC)
    $scope = if ($DC) { 'DC' } else { 'AC' }
    $original = Get-PowerValue -Subgroup $Subgroup -Setting $Setting -DC:$DC
    Save-UndoValue -Area $Description -Name "Power$($scope)_$Setting" -Value $original
    $flag = if ($DC) { 'setdcvalueindex' } else { 'setacvalueindex' }
    $ok, $ggOut = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @("/$flag", 'SCHEME_CURRENT', $Subgroup, $Setting, $Value) -TimeoutSeconds 20 -Description "$Description ($flag)"
    if (-not $ok) { Write-GGLog "$Description set failed or timed out."; return }
    # Re-apply the scheme so the change takes effect without a reboot.
    $null, $null = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('/setactive', 'SCHEME_CURRENT') -TimeoutSeconds 20 -Description "$Description re-apply scheme"
    Write-GGLog "$Description set ($scope = $Value; was $original)."
}

switch ($Mode) {

    'epp' {
        # EPP = 0 (max performance) - AC only, documented hidden setting PERFEPP.
        Set-PowerValue -Subgroup 'SUB_PROCESSOR' -Setting 'PERFEPP' -Value '0' -Description 'EPP max performance'
        # Also stamp the GGOS Performance plan if present, so the value survives plan switches.
        $ggPlan = 'd4a3b2c1-5f6e-4a7d-9b8c-2e1f0a3d5b6c'
        $ok, $ggOut = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('/setacvalueindex', $ggPlan, 'SUB_PROCESSOR', 'PERFEPP', '0') -TimeoutSeconds 20 -Description 'EPP on GGOS Performance plan'
        if ($ok) { Write-GGLog 'EPP also stamped onto the GGOS Performance plan.' }
    }

    'devices' {
        # PCIe ASPM off on AC (desktop): SUB_PCIEXPRESS / ASPM. 0 = Off.
        Set-PowerValue -Subgroup 'SUB_PCIEXPRESS' -Setting 'ASPM' -Value '0' -Description 'PCIe ASPM off'
    }

    'nvme' {
        # Unhide the documented Primary NVMe Idle Timeout, then raise it on AC.
        $null, $null = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('-attributes', 'SUB_DISK', 'D639518A-E56D-4345-8AF2-B9F32FB26109', '-ATTRIB_HIDE') -TimeoutSeconds 20 -Description 'unhide Primary NVMe Idle Timeout'
        Set-PowerValue -Subgroup 'SUB_DISK' -Setting 'D639518A-E56D-4345-8AF2-B9F32FB26109' -Value '60000' -Description 'NVMe idle timeout raised'
        # SEC NVMe idle timeout: build-dependent GUID, best-effort via alias discovery.
        $ok, $aliases = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('/aliases') -TimeoutSeconds 20 -Description 'powercfg alias discovery'
        if ($ok) {
            $secLine = @($aliases) | Where-Object { $_ -match 'SEC NVMe' } | Select-Object -First 1
            if ($secLine -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                Set-PowerValue -Subgroup 'SUB_DISK' -Setting $Matches[1] -Value '60000' -Description 'SEC NVMe idle timeout raised'
            } else {
                Write-GGLog 'SEC NVMe setting not exposed on this build - Primary raised only.'
            }
        }
    }

    'wireless' {
        # USB selective suspend off on AC: SUB_USB / USBSELECTIVESUSPEND. 0 = Off.
        Set-PowerValue -Subgroup 'SUB_USB' -Setting 'USBSELECTIVESUSPEND' -Value '0' -Description 'USB selective suspend off'
        # Bluetooth radio: disable "allow the computer to turn off this device".
        $btClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{e0cbf06c-cd8b-4647-bb8a-263b43f0f974}'
        try {
            $btKeys = Get-ChildItem -Path $btClass -ErrorAction Stop | Where-Object { $_.PSChildName -match '^\d{4}$' }
            foreach ($k in $btKeys) {
                $props = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $props) { continue }
                $driverDesc = [string]$props.DriverDesc
                if (-not $driverDesc) { continue }
                $orig = 'ABSENT'
                if ($null -ne $props.PnPCapabilities) { $orig = [string]$props.PnPCapabilities }
                Save-UndoValue -Area 'BluetoothRadio' -Name $driverDesc -Value $orig
                New-ItemProperty -Path $k.PSPath -Name 'PnPCapabilities' -Value 24 -PropertyType DWord -Force | Out-Null
                Write-GGLog "Bluetooth radio '$driverDesc': power management disabled (PnPCapabilities=24)."
            }
            if (-not $btKeys) { Write-GGLog 'No Bluetooth radio device keys found - skipped.' }
        } catch {
            Write-GGLog "Bluetooth radio power management skipped: $($_.Exception.Message)"
        }
    }
}

exit 0

