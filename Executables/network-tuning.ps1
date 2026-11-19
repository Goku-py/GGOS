# GGOS network tuning - v0.2.3 (research-backed)
#
# Modes (v0.6.0: called unconditionally from network.yml - no wizard option):
#   bufferbloat - TCP pacing (smooths send bursts) + ECN enabled (AQMs mark instead of
#                 drop = fewer losses) + receive auto-tuning pinned to Normal (the common
#                 'disabled' tweak lowers ping but kills throughput). NOTE: the full
#                 bufferbloat fix is Smart Queue Management on the ROUTER (fq_codel /
#                 CAKE / PIE) - Windows has no AQM qdisc; these settings only stop the
#                 PC itself from bloating the path.
#   nic         - NIC low-latency without speed cost: Energy-Efficient Ethernet /
#                 Green Ethernet / Gigabit Lite / Power Saving off (removes wake-up
#                 latency spikes), Flow Control off (prevents pause-frame stalls).
#   ultra       - Additionally Interrupt Moderation off + RSC off (+ UDP RSC 'URO' off
#                 on 24H2+ when the cmdlet exists). Lowest latency, slightly higher CPU
#                 use under heavy packet rates - so it stays desktop-only: the chassis
#                 guard below leaves laptops on the nic-mode settings.
# Wired physical adapters only; WiFi/virtual/VPN excluded (same filter as
# network-latency.ps1). Original NIC property values recorded to
# HKLM\SOFTWARE\GGOS\NetworkUndo\NicUndo before changes.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('bufferbloat', 'nic', 'ultra')]
    [string]$Mode
)

Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force
$ErrorActionPreference = 'Continue'

function Write-GGLog {
    param([string]$Message)
    Write-Output "GGOS network: $Message"
}

function Test-IsWiredPhysical {
    param($Adapter)
    if ($Adapter.PhysicalMediaType -in 9, 10) { return $false }                # native 802.11
    $desc = [string]$Adapter.InterfaceDescription
    if ($desc -match 'Virtual|VPN|TAP|Hyper-V|Loopback|Bluetooth|WAN Miniport') { return $false }
    if ([string]$Adapter.MediaType -and [string]$Adapter.MediaType -ne '802.3') { return $false }
    return $true
}

function Get-OriginalNicValue {
    param($Adapter, [string]$DisplayName)
    try {
        $prop = Get-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName $DisplayName -ErrorAction Stop
        return [string]$prop.RegistryValue
    } catch { return 'ABSENT' }
}

# ---- v0.6.0 chassis guard (ultra only) --------------------------------------
# Ultra mode is applied automatically now (the wizard has no checkbox for it).
# Disabling interrupt moderation + RSC raises CPU use under heavy packet rates,
# so it stays desktop-only by design: laptops keep the nic-mode settings and
# their battery behaviour. Chassis resolution is the shared Get-GGChassis
# helper (ggos-common.psm1) - silent, so the boolean stays unambiguous.
if ($Mode -eq 'ultra' -and (Get-GGChassis) -ne 'Desktop') {
    Write-GGLog 'Ultra NIC mode is desktop-only (higher CPU cost under load); adapter settings left unchanged.'
    exit 0
}

switch ($Mode) {

    'bufferbloat' {
        # ---- TCP pacing: smooth bursts instead of dumping them into the path ----
        $ok = $false
        try {
            Set-NetTCPSetting -SettingName Internet -PacingProfile Always -ErrorAction Stop
            $ok = $true
        } catch {
            Write-GGLog "Set-NetTCPSetting pacing failed: $($_.Exception.Message)"
        }
        if (-not $ok) {
            $discard, $discardExit, $ggOut = Invoke-GGCommand -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'pacingprofile=always') -Description 'netsh pacingprofile=always'
            if (-not ($discard -and $discardExit -eq 0)) { Write-GGLog "netsh pacingprofile=always fallback $(if ($discard) { "failed (exit $discardExit)" } else { 'timed out' })." }
        }
        # ---- ECN: congestion routers mark instead of drop -> fewer packet losses ----
        try {
            Set-NetTCPSetting -SettingName Internet -EcnCapability Enabled -ErrorAction Stop
            Write-GGLog 'ECN capability enabled on the Internet TCP template.'
        } catch {
            $discard, $discardExit, $ggOut = Invoke-GGCommand -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'ecncapability=enabled') -Description 'netsh ecncapability=enabled'
            Write-GGLog "ECN capability fallback via netsh $(if ($discard -and $discardExit -eq 0) { 'applied' } else { "did not succeed (exit $discardExit)" })."
        }
        # ---- Auto-tuning pinned to Normal: speed-preserving default ----
        try {
            Set-NetTCPSetting -SettingName Internet -AutoTuningLevelLocal Normal -ErrorAction Stop
            Write-GGLog 'Receive-window auto-tuning set to Normal (speed preserved).'
        } catch {
            $discard, $discardExit, $ggOut = Invoke-GGCommand -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'autotuninglevel=normal') -Description 'netsh autotuninglevel=normal'
            Write-GGLog "Auto-tuning fallback via netsh $(if ($discard -and $discardExit -eq 0) { 'applied' } else { "did not succeed (exit $discardExit)" })."
        }
        Write-GGLog 'Bufferbloat stack applied. Full fix is router SQM (fq_codel/CAKE/PIE) - see README.'
    }

    'nic' {
        $targets = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { Test-IsWiredPhysical $_ })
        if ($targets.Count -eq 0) {
            Write-GGLog 'No wired physical adapters found - NIC tuning skipped.'
            exit 0
        }
        $labels = @('Energy-Efficient Ethernet', 'Advanced EEE', 'Green Ethernet', 'Gigabit Lite',
                    'Power Saving Mode', 'EEE', 'Energy Efficient Ethernet')
        foreach ($adapter in $targets) {
            Write-GGLog ("Tuning NIC '{0}' ({1})" -f $adapter.Name, $adapter.InterfaceDescription)
            # Flow control off - record original first.
            $orig = Get-OriginalNicValue $adapter 'Flow Control'
            $undoKey = 'HKLM:\SOFTWARE\GGOS\NetworkUndo\NicUndo'
            New-Item -Path $undoKey -Force | Out-Null
            New-ItemProperty -Path $undoKey -Name ($adapter.Name + '::Flow Control') -Value $orig -PropertyType String -Force | Out-Null
            try {
                Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName 'Flow Control' -RegistryValue 0 -ErrorAction Stop
                Write-GGLog 'Flow Control disabled.'
            } catch { Write-GGLog "Flow Control not changeable: $($_.Exception.Message)" }
            # Power-saving / EEE family off where the driver exposes them.
            foreach ($label in $labels) {
                try {
                    $prop = Get-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $label -ErrorAction Stop
                    $origVal = Get-OriginalNicValue $adapter $label
                    New-ItemProperty -Path $undoKey -Name ($adapter.Name + '::' + $label) -Value $origVal -PropertyType String -Force | Out-Null
                    Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $label -RegistryValue 0 -ErrorAction Stop
                    Write-GGLog "$label disabled."
                } catch { }
            }
        }
    }

    'ultra' {
        $targets = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { Test-IsWiredPhysical $_ })
        foreach ($adapter in $targets) {
            # Interrupt moderation off: lowest latency, higher CPU under load (opt-in trade-off).
            try {
                Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName 'Interrupt Moderation' -RegistryValue 0 -ErrorAction Stop
                Write-GGLog ("'{0}': Interrupt Moderation disabled." -f $adapter.Name)
            } catch { Write-GGLog ("'{0}': Interrupt Moderation not exposed - skipped." -f $adapter.Name) }
            # RSC (TCP receive coalescing) off: adds receive latency when batching.
            try {
                Disable-NetAdapterRsc -Name $adapter.Name -ErrorAction Stop
                Write-GGLog ("'{0}': RSC disabled." -f $adapter.Name)
            } catch { Write-GGLog ("'{0}': RSC cmdlet unavailable - skipped." -f $adapter.Name) }
            # URO (UDP receive coalescing, 24H2+): off for latency if the cmdlet exists.
            $uro = Get-Command Disable-NetAdapterUro -ErrorAction SilentlyContinue
            if ($uro) {
                try {
                    Disable-NetAdapterUro -Name $adapter.Name -ErrorAction Stop
                    Write-GGLog ("'{0}': UDP RSC (URO) disabled." -f $adapter.Name)
                } catch { Write-GGLog ("'{0}': URO disable failed - skipped." -f $adapter.Name) }
            } else {
                Write-GGLog 'URO cmdlet not present on this build (pre-24H2) - skipped.'
            }
        }
    }
}

exit 0


