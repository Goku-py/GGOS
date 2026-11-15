# GGOS Wi-Fi latency tuning - v0.1 (research-backed; Wi-Fi adapters ONLY)
#
# Rationale: Wi-Fi drivers trade latency and throughput for battery life.
# Disabling the power-saving hooks removes wake-up latency spikes at a modest
# idle-power cost:
#   MIMO Power Save (SMPS)  - lets the radio drop spatial streams / width when
#                             idle-ish; 'No SMPS' keeps all spatial streams
#                             active (throughput + latency win on 802.11ac/ax).
#   U-APSD                  - WMM power-save scheduling; many drivers implement
#                             it badly (multi-second latency spikes, missed
#                             beacons). Off where the driver exposes it.
#   Roaming Aggressiveness  - lowest = 'sticky client'. HONEST trade-off: on
#                             multi-AP homes the client may hold a weak AP too
#                             long before roaming to a stronger one. If you
#                             roam between 2+ APs, raise this one value back
#                             manually after applying.
#   Power Saving Mode       - some Intel/Realtek drivers expose a global power
#                             save knob; 'Maximum Performance'/0 where present.
#   Adapter power mgmt      - stops Windows suspending the device ('Allow the
#                             computer to turn off this device'): documented
#                             NetAdapter cmdlet when present, else the classic
#                             PnPCapabilities=24 registry toggle (0x18: no
#                             device power-off, no wake; applies after the
#                             adapter restarts).
#   Per-profile power save  - netsh wlan set profileparameter ... powerManagement=
#                             disabled, ONLY if this netsh build accepts the
#                             parameter (verified at runtime, logged honestly).
#
# Filter: physical Wi-Fi adapters only (PhysicalMediaType 9/10 native 802.11,
# virtual/VPN/Bluetooth/WAN Miniport excluded) - the INVERSE of
# network-tuning.ps1's Test-IsWiredPhysical.
#
# UNDO strategy: the ORIGINAL value of every touched advanced property (or an
# 'ABSENT' marker when the driver does not expose it) plus the adapter's
# PnPCapabilities are recorded under
#   HKLM\SOFTWARE\GGOS\NetworkUndo\WifiUndo\<adapter name>
# BEFORE any change, so a future revert task can restore them.
#
# Log-and-continue: every step is best-effort, each result is logged with the
# 'GGOS wifi:' prefix, a per-adapter summary line is written at the end, and
# the script always exits 0 (it never halts the playbook).

$ErrorActionPreference = 'Continue'

Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force

function Write-GGLog {
    param([string]$Message)
    Write-Output "GGOS wifi: $Message"
}

# ---------------------------------------------------------------------------
# Wi-Fi adapter filter (inverse of network-tuning.ps1's Test-IsWiredPhysical)
# ---------------------------------------------------------------------------
function Test-IsWifiPhysical {
    param($Adapter)
    $desc = [string]$Adapter.InterfaceDescription
    if ($desc -match 'Virtual|VPN|TAP|Hyper-V|Loopback|Bluetooth|WAN Miniport') { return $false }
    if ($Adapter.PhysicalMediaType -in 9, 10) { return $true }                 # native 802.11
    if ([string]$Adapter.MediaType -match '802\.11') { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# Undo recording
# ---------------------------------------------------------------------------
$undoRoot = 'HKLM:\SOFTWARE\GGOS\NetworkUndo\WifiUndo'

function Get-WifiUndoKey {
    param($Adapter)
    # Adapter names are generally registry-safe; harden anyway (no backslash etc.).
    $safeName = ([string]$Adapter.Name) -replace '[\\/:*?"<>|]', '_'
    return Join-Path $undoRoot $safeName
}

function Save-WifiUndoValue {
    param([string]$UndoKey, [string]$ValueName, [string]$Original)
    try {
        New-Item -Path $UndoKey -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $UndoKey -Name $ValueName -Value $Original -PropertyType String -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-GGLog "Warning: could not record undo value '$ValueName': $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Registry instance key lookup (for the PnPCapabilities fallback)
# ---------------------------------------------------------------------------
function Get-WifiInstanceKey {
    param($Adapter)
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    if (-not (Test-Path -LiteralPath $classRoot)) { return $null }
    $guid = [string]$Adapter.InterfaceGuid
    if (-not $guid) { return $null }
    foreach ($child in (Get-ChildItem $classRoot -ErrorAction SilentlyContinue)) {
        $props = Get-ItemProperty -Path $child.PSPath -Name 'NetCfgInstanceId' -ErrorAction SilentlyContinue
        if ($props -and ([string]$props.NetCfgInstanceId -ieq $guid)) { return $child }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Advanced property setter: record original first, then apply
# ---------------------------------------------------------------------------
# The value name/data for a given DisplayName varies by driver, so the target
# is resolved from the driver's own enum pairing (DisplayValues[i] maps to
# RegistryValues[i]) and falls back to raw string/numeric candidates, with
# try/catch per attempt.
function Set-WifiAdvancedProperty {
    param(
        $Adapter,
        [string]$UndoKey,
        [string[]]$DisplayNames,
        [string]$MatchPattern,
        [string[]]$FallbackValues
    )
    $prop = $null
    foreach ($displayName in $DisplayNames) {
        try {
            $prop = Get-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName $displayName -ErrorAction Stop
            break
        } catch {
            $prop = $null
        }
    }
    if ($null -eq $prop) {
        Save-WifiUndoValue -UndoKey $UndoKey -ValueName ($DisplayNames[0] + ' (not exposed)') -Original 'ABSENT'
        return ('{0}: not exposed - skipped' -f $DisplayNames[0])
    }

    # Record the ORIGINAL value before any change (undo strategy).
    $original = [string]$prop.RegistryValue
    Save-WifiUndoValue -UndoKey $UndoKey -ValueName ([string]$prop.DisplayName) -Original $original

    $candidates = @()
    try {
        if ($prop.DisplayValues -and $prop.RegistryValues -and
            ($prop.DisplayValues.Count -eq $prop.RegistryValues.Count) -and ($prop.DisplayValues.Count -gt 0)) {
            for ($i = 0; $i -lt $prop.DisplayValues.Count; $i++) {
                if ([string]$prop.DisplayValues[$i] -match $MatchPattern) {
                    $candidates += [string]$prop.RegistryValues[$i]
                    break
                }
            }
        }
    } catch { }
    foreach ($fallback in $FallbackValues) { $candidates += $fallback }

    foreach ($candidate in $candidates) {
        try {
            Set-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName ([string]$prop.DisplayName) -RegistryValue $candidate -ErrorAction Stop
            return ("'{0}' set to '{1}'" -f $prop.DisplayName, $candidate)
        } catch { }
    }
    return ("'{0}' not changeable (no accepted value)" -f $prop.DisplayName)
}

# ---------------------------------------------------------------------------
# Adapter power management: cmdlet when documented, else PnPCapabilities=24
# ---------------------------------------------------------------------------
function Set-WifiPowerManagement {
    param($Adapter, [string]$UndoKey)

    $instKey = Get-WifiInstanceKey $Adapter
    # Record the original PnPCapabilities BEFORE anything (undo covers both paths).
    if ($instKey) {
        $existing = Get-ItemProperty -Path $instKey.PSPath -Name 'PnPCapabilities' -ErrorAction SilentlyContinue
        $origPnp = 'ABSENT'
        if ($existing) { $origPnp = [string]$existing.PnPCapabilities }
        Save-WifiUndoValue -UndoKey $UndoKey -ValueName 'PnPCapabilities' -Original $origPnp
    }

    $pmCmd = Get-Command Disable-NetAdapterPowerManagement -ErrorAction SilentlyContinue
    if (-not $pmCmd) { $pmCmd = Get-Command Set-NetAdapterPowerManagement -ErrorAction SilentlyContinue }
    if ($pmCmd) {
        try {
            $pmArgs = @{ Name = $Adapter.Name }
            if ($pmCmd.Name -eq 'Disable-NetAdapterPowerManagement') { $pmArgs['NoRestart'] = $true }  # avoid dropping the Wi-Fi link mid-run
            & $pmCmd.Name @pmArgs -ErrorAction Stop
            return 'device power management disabled via cmdlet'
        } catch {
            Write-GGLog ("'{0}': power management cmdlet failed, falling back to PnPCapabilities: {1}" -f $Adapter.Name, $_.Exception.Message)
        }
    } else {
        Write-GGLog ("'{0}': no NetAdapter power management cmdlet on this build - using PnPCapabilities fallback." -f $Adapter.Name)
    }
    if ($instKey) {
        try {
            Set-ItemProperty -Path $instKey.PSPath -Name 'PnPCapabilities' -Value 24 -Type DWord -ErrorAction Stop
            return 'PnPCapabilities=24 written (applies after adapter restart)'
        } catch {
            return ('PnPCapabilities write failed: ' + $_.Exception.Message)
        }
    }
    return 'registry instance key not found - power management toggle skipped'
}

# ---------------------------------------------------------------------------
# 1. Enumerate Wi-Fi adapters
# ---------------------------------------------------------------------------
try {
    $targets = @(Get-NetAdapter -ErrorAction Stop | Where-Object { Test-IsWifiPhysical $_ })
} catch {
    Write-GGLog "Get-NetAdapter failed: $($_.Exception.Message) - skipped."
    exit 0
}
if ($targets.Count -eq 0) {
    Write-GGLog 'no Wi-Fi adapters - skipped.'
    exit 0
}

# ---------------------------------------------------------------------------
# 2. Per-adapter driver settings + power management
# ---------------------------------------------------------------------------
foreach ($adapter in $targets) {
    $undoKey = Get-WifiUndoKey $adapter
    Write-GGLog ("Tuning Wi-Fi adapter '{0}' ({1})" -f $adapter.Name, $adapter.InterfaceDescription)
    $results = @()

    # MIMO Power Save -> 'No SMPS'. Value name/data varies by driver
    # (Intel/Realtek/MediaTek expose 'MIMO Power Save Mode', Qualcomm 'SMPS');
    # string or numeric is tried per candidate as the driver exposes it.
    $results += 'MIMO: ' + (Set-WifiAdvancedProperty -Adapter $adapter -UndoKey $undoKey `
        -DisplayNames @('MIMO Power Save Mode', 'MIMO Power Save', 'SMPS') `
        -MatchPattern 'No\s*SMPS' `
        -FallbackValues @('No SMPS', '0'))

    # U-APSD off (driver implementations are the usual latency-spike source).
    $results += 'U-APSD: ' + (Set-WifiAdvancedProperty -Adapter $adapter -UndoKey $undoKey `
        -DisplayNames @('U-APSD Support', 'U-APSD', 'UAPSD') `
        -MatchPattern 'Disable' `
        -FallbackValues @('0', 'Disabled'))

    # Roaming aggressiveness lowest. Trade-off note (see header): sticky client
    # can hold a weak AP too long on multi-AP homes.
    $results += 'Roaming: ' + (Set-WifiAdvancedProperty -Adapter $adapter -UndoKey $undoKey `
        -DisplayNames @('Roaming Aggressiveness', 'Roaming Preference', 'Roaming Sensitivity') `
        -MatchPattern 'Lowest|^Low$' `
        -FallbackValues @('0', '1'))

    # Power Saving Mode -> Maximum Performance / 0 where the driver exposes it.
    $results += 'Power Saving Mode: ' + (Set-WifiAdvancedProperty -Adapter $adapter -UndoKey $undoKey `
        -DisplayNames @('Power Saving Mode') `
        -MatchPattern 'Maximum Performance|Disabled' `
        -FallbackValues @('0', 'Maximum Performance'))

    # 'Allow the computer to turn off this device' off.
    $results += 'Power mgmt: ' + (Set-WifiPowerManagement -Adapter $adapter -UndoKey $undoKey)

    Write-GGLog ("Summary '{0}': {1}" -f $adapter.Name, ($results -join '; '))
}

# ---------------------------------------------------------------------------
# 3. Per-profile power management (netsh) - verify at runtime, log honestly
# ---------------------------------------------------------------------------
# The powerManagement parameter may not exist (or not be accepted) on every
# netsh build; each attempt is read first, then set with try/catch, and any
# rejection is logged and skipped - never fatal.
$okShow, $showOut = Invoke-GGCommand -FilePath 'netsh.exe' -ArgumentList @('wlan', 'show', 'profiles') -TimeoutSeconds 20 -Description 'netsh wlan show profiles'
if ($okShow) {
    $profileNames = @()
    foreach ($line in $showOut) {
        # English builds only; on other locales nothing parses and we log + skip.
        if ($line -match 'All User Profile\s*:\s*(.+?)\s*$') { $profileNames += $Matches[1] }
    }
    if ($profileNames.Count -eq 0) {
        Write-GGLog 'netsh reported no WLAN profiles (or a non-English build) - profile power save step skipped.'
    }
    foreach ($profileName in $profileNames) {
        try {
            # Read the profile first so the log shows whether this netsh build
            # reports a power management state at all.
            $discard, $readOut = Invoke-GGCommand -FilePath 'netsh.exe' -ArgumentList @('wlan', 'show', 'profile', "name=$profileName") -TimeoutSeconds 20 -Description "show profile $profileName"
            $pmLine = $null
            foreach ($line in $readOut) {
                if ($line -match 'Power\s*Manage\w*\s*:') { $pmLine = ([string]$line).Trim(); break }
            }
            if ($pmLine) { Write-GGLog "Profile '$profileName' current state: $pmLine" }

            $okSet, $setOut = Invoke-GGCommand -FilePath 'netsh.exe' -ArgumentList @('wlan', 'set', 'profileparameter', "name=$profileName", 'powerManagement=disabled') -TimeoutSeconds 20 -Description "set profileparameter powerManagement=disabled ($profileName)"
            if ($okSet) {
                $firstOut = ''
                foreach ($line in $setOut) {
                    if ([string]$line) { $firstOut = ([string]$line).Trim(); break }
                }
                if ($firstOut) { Write-GGLog "Profile '${profileName}': netsh replied: $firstOut" }
                else { Write-GGLog "Profile '${profileName}': powerManagement=disabled accepted." }
            } else {
                Write-GGLog "Profile '${profileName}': netsh call timed out or failed - skipped."
            }
        } catch {
            Write-GGLog "Profile '${profileName}': not accepted by netsh on this build - skipped ($($_.Exception.Message))."
        }
    }
} else {
    Write-GGLog 'netsh wlan show profiles failed/timed out - per-profile power save step skipped.'
}

# ---------------------------------------------------------------------------
# 4. Summary
# ---------------------------------------------------------------------------
Write-GGLog "Wi-Fi tuning applied to $($targets.Count) adapter(s); originals recorded under HKLM\SOFTWARE\GGOS\NetworkUndo\WifiUndo for a future revert task."
exit 0
