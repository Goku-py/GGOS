# GGOS hardware tuning - v0.3 (research-backed, mode-based)
#
# Modes (each gated by its own playbook option):
#   epp      - Energy Performance Preference = 0 (max performance) on the ACTIVE scheme
#              and the GGOS Performance plan. AC only. Documented hidden setting
#              (PERFEPP); desktop-only - enforced by the chassis guard, not by
#              page placement (see v0.4.0 note below).
#   devices  - PCIe Link State Power Management (ASPM) off on AC. Desktop page.
#   nvme     - Unhide + raise Primary NVMe Idle Timeout (documented GUID
#              D639518A-E56D-4345-8AF2-B9F32FB26109) to 60000 ms on AC only.
#              DC (battery) untouched by design. SEC NVMe timeout is build-dependent
#              and is attempted best-effort via alias discovery.
#   wireless - USB selective suspend off on AC (documented wireless dongle stutter
#              fix) + Bluetooth radio power-management off (PnPCapabilities=24,
#              originals recorded). Laptop: AC only, DC untouched.
#
# v0.4.0 chassis guard: the wizard now shows the "Desktop-only power" and
# "Laptop" pages on EVERY machine (page placement no longer hides them), so
# this script enforces desktop-only gating itself. Modes 'epp' and 'devices'
# are refused on a Laptop or Unknown chassis (logged + appended to skipped.txt,
# exit 0 - a skip by design is not a playbook failure). Modes 'nvme' and
# 'wireless' are documented laptop-safe and are NOT gated. The option-ledger
# entry 'pc-desktop' in %SystemRoot%\GGOS\ggos-options.txt (explicit user
# choice) beats chassis detection, mirroring hardware-policy.ps1.
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
    $ok, $exit, $out = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList $args -TimeoutSeconds 20 -Description "powercfg query $Subgroup $Setting"
    # Read-only query: a nonzero exit or a pattern miss both mean "value not
    # exposed" here, reported as ABSENT (unchanged silent-ABSENT semantics).
    if (-not ($ok -and $exit -eq 0)) { return 'ABSENT' }
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
    $ok, $exit, $ggOut = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @("/$flag", 'SCHEME_CURRENT', $Subgroup, $Setting, $Value) -TimeoutSeconds 20 -Description "$Description ($flag)"
    if (-not $ok) { Write-GGLog "$Description set timed out."; return }
    if ($exit -ne 0) { Write-GGLog "$Description set failed (exit $exit)."; return }
    # Re-apply the scheme so the change takes effect without a reboot.
    $null, $null, $null = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('/setactive', 'SCHEME_CURRENT') -TimeoutSeconds 20 -Description "$Description re-apply scheme"
    Write-GGLog "$Description set ($scope = $Value; was $original)."
}

function Resolve-GGChassis {
    # Chassis resolution with the same precedence as hardware-policy.ps1:
    #   1. The stamp already computed by hardware-policy.ps1
    #      (HKLM\SOFTWARE\GGOS\HardwarePolicy\Chassis - it runs earlier in
    #      main.yml). Plain Get-ItemProperty, no external calls.
    #   2. Local detection when the stamp is absent/unreadable:
    #      Win32_SystemEnclosure ChassisTypes with a battery fallback.
    #   3. Ledger override: 'pc-desktop' / 'pc-laptop' in ggos-options.txt
    #      (explicit user choice) beats detection.
    # -LedgerFile exists for testability (scratch tests pass a fake ledger);
    # the default is the real playbook option ledger.
    # Note: in-function Write-GGLog calls are piped to Write-Host so they stay
    # off the return pipeline (Write-GGLog uses Write-Output; the guard captures
    # this function's return). The message text still flows through Write-GGLog.
    param([string]$LedgerFile = (Join-Path $env:SystemRoot 'GGOS\ggos-options.txt'))

    $chassis = 'Unknown'

    # 1. Prefer the stamp written by hardware-policy.ps1.
    $stamp = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\GGOS\HardwarePolicy' `
        -Name 'Chassis' -ErrorAction SilentlyContinue).Chassis
    if ($stamp -in 'Desktop', 'Laptop', 'Unknown') { $chassis = $stamp }

    # 2. Stamp absent or unreadable: detect locally, exactly like hardware-policy.ps1.
    if ($chassis -eq 'Unknown') {
        try {
            $types = @((Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
            if ($types -match '^(8|9|10|11|12|14|18|21|23|30|31|32)$') { $chassis = 'Laptop' }
            elseif ($types -match '^(3|4|5|6|7|13|15|16|24|35|36)$') { $chassis = 'Desktop' }
        } catch {
            Write-GGLog "Chassis detection failed: $($_.Exception.Message)" | Write-Host
        }
        if ($chassis -eq 'Unknown') {
            # Battery fallback: a machine with a battery is treated as a laptop.
            $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
            if ($battery) { $chassis = 'Laptop'; Write-GGLog 'Battery detected - treating as laptop.' | Write-Host }
        }
    }

    # 3. User override from the option ledger beats detection.
    if (Test-Path $LedgerFile) {
        $choices = @(Get-Content $LedgerFile -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() })
        if ($choices -contains 'pc-desktop') { $chassis = 'Desktop'; Write-GGLog 'User selected Desktop in the wizard - overriding detection.' | Write-Host }
        elseif ($choices -contains 'pc-laptop') { $chassis = 'Laptop'; Write-GGLog 'User selected Laptop in the wizard - overriding detection.' | Write-Host }
    }

    return $chassis
}

# v0.4.0 chassis guard (see the header note): desktop-only modes refuse to run
# unless the machine resolved as Desktop. On Laptop/Unknown the option is
# skipped by design (errorAction for these actions is Notify), not failed.
if ($Mode -in 'epp', 'devices') {
    $chassis = Resolve-GGChassis
    Write-GGLog "Mode '$Mode': resolved chassis category: $chassis."
    if ($chassis -ne 'Desktop') {
        Write-GGLog "$Mode is desktop-only; resolved chassis: $chassis (use of this option on laptops is intentionally skipped)."
        # Best-effort skip record: a non-elevated context must not produce error
        # records here (the playbook runs elevated; the skip is still logged
        # above even when this file write is denied).
        try {
            $ggDir = Join-Path $env:SystemRoot 'GGOS'
            New-Item -ItemType Directory -Path $ggDir -Force -ErrorAction Stop | Out-Null
            Add-Content -Path (Join-Path $ggDir 'skipped.txt') `
                -Value ('{0} SKIPPED(chassis {1}): {2}' -f (Get-Date -Format s), $chassis, "desktop-only tuning ($Mode)") -ErrorAction Stop
        }
        catch {
            Write-GGLog "Warning: could not append to skipped.txt: $($_.Exception.Message)"
        }
        exit 0
    }
}

switch ($Mode) {

    'epp' {
        # EPP = 0 (max performance) - AC only, documented hidden setting PERFEPP.
        Set-PowerValue -Subgroup 'SUB_PROCESSOR' -Setting 'PERFEPP' -Value '0' -Description 'EPP max performance'
        # Also stamp the GGOS Performance plan if present, so the value survives plan switches.
        $ggPlan = 'd4a3b2c1-5f6e-4a7d-9b8c-2e1f0a3d5b6c'
        $ok, $exit, $ggOut = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('/setacvalueindex', $ggPlan, 'SUB_PROCESSOR', 'PERFEPP', '0') -TimeoutSeconds 20 -Description 'EPP on GGOS Performance plan'
        if ($ok -and $exit -eq 0) { Write-GGLog 'EPP also stamped onto the GGOS Performance plan.' }
        elseif ($ok) { Write-GGLog "Warning: EPP stamp onto the GGOS Performance plan failed (exit $exit)." }
    }

    'devices' {
        # PCIe ASPM off on AC (desktop): SUB_PCIEXPRESS / ASPM. 0 = Off.
        Set-PowerValue -Subgroup 'SUB_PCIEXPRESS' -Setting 'ASPM' -Value '0' -Description 'PCIe ASPM off'
    }

    'nvme' {
        # Unhide the documented Primary NVMe Idle Timeout, then raise it on AC.
        $null, $null, $null = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('-attributes', 'SUB_DISK', 'D639518A-E56D-4345-8AF2-B9F32FB26109', '-ATTRIB_HIDE') -TimeoutSeconds 20 -Description 'unhide Primary NVMe Idle Timeout'
        Set-PowerValue -Subgroup 'SUB_DISK' -Setting 'D639518A-E56D-4345-8AF2-B9F32FB26109' -Value '60000' -Description 'NVMe idle timeout raised'
        # SEC NVMe idle timeout: build-dependent GUID, best-effort via alias discovery.
        $ok, $exit, $aliases = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('/aliases') -TimeoutSeconds 20 -Description 'powercfg alias discovery'
        if ($ok -and $exit -eq 0) {
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

