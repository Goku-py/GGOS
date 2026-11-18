# GGOS verification pass (v0.2, spec B3).
# Cross-checks representative marker values for every option recorded in
# %SystemRoot%\GGOS\ggos-options.txt (written by Tasks/options-ledger.yml).
# Ground truth comes from the Configuration/Tasks/*.yml files and the per-user
# value table in per-user.ps1:
#   system-optimization -> system-registry.yml (LongPathsEnabled, WaitToKill,
#                          DeliveryOptimization DODownloadMode)
#   services            -> services.yml (AppVClient disabled, PcaSvc manual)
#   telemetry           -> telemetry.yml (AllowTelemetry 0, DiagTrack disabled,
#                          DoNotShowFeedbackNotifications 1)
#   ads-ui              -> system-registry.yml (Windows Feeds, AdvertisingInfo)
#   per-user            -> per-user.ps1 core values on HKCU
#   f8-boot             -> system-registry.yml (bcdedit bootmenupolicy legacy)
#   verbose-logon       -> system-registry.yml (VerboseStatus 1)
#   pagefile            -> system-registry.yml (explicit page-file settings)
#   bloat-copilot       -> system-registry.yml Copilot policy keys
#   bloat-bing          -> appx.yml (Microsoft.BingSearch gone)
#   bloat-widgets       -> appx.yml (Widgets packages gone)
#   bloat-oem           -> no static marker (publisher-wildcard sweep is
#                          dynamic) -> reported as NOTE
#   office-telemetry    -> per-user.ps1 Office block on HKCU
#   gaming              -> gaming.yml (HWSchMode, SystemResponsiveness,
#                          build-gated kernel timer values)
#   cleanup / cleanup-aggressive / winget-update -> file/process effects, no
#                          static marker -> reported as NOTE
#   network-latency     -> spec C7 (TcpAckFrequency=1 on any interface)
#   pc-auto / pc-desktop / pc-laptop -> HKLM\SOFTWARE\GGOS\HardwarePolicy
#                          'Chassis' stamp written by hardware-policy.ps1
#                          (informational correlation - audit F7)
#   epp-perf            -> hardware-tuning.ps1 mode 'epp': PERFEPP = 0 on the
#                          active scheme (live AC index via powercfg /q)
#   desktop-device-power -> hardware-tuning.ps1 mode 'devices': PCIe ASPM = 0
#   nvme-latency / nvme-latency-laptop -> hardware-tuning.ps1 mode 'nvme':
#                          Primary NVMe idle timeout = 60000 ms (0xEA60) on AC
#   laptop-power        -> gaming-power.ps1: GGOS Laptop fixed-GUID plan
#                          present in powercfg /list
#   wifi-tuning         -> wifi-tuning.ps1: PnPCapabilities=24 on at least one
#                          NIC class instance (fallback path; driver advanced
#                          properties are live state, not statically verifiable)
#   input-accel         -> input-tuning.ps1 mode 'accel': HKCU Control Panel\Mouse
#                          MouseSpeed / MouseThreshold1 / MouseThreshold2 = '0'
#   input-queue         -> input-tuning.ps1 mode 'queue': mouse/keyboard data
#                          queue sizes = 8 under mouclass/kbdclass Parameters
#   wireless-input      -> hardware-tuning.ps1 mode 'wireless': USB selective
#                          suspend = 0 on AC + Bluetooth radio PnPCapabilities=24
#   network-bufferbloat -> network-tuning.ps1 mode 'bufferbloat': live TCP
#                          global pacing profile = always (netsh; English builds)
#   network-nic         -> network-tuning.ps1 mode 'nic': the option's undo
#                          record under NetworkUndo\NicUndo (driver props are
#                          live state, so the run marker is the honest check)
#   network-ultra       -> NOTE: interrupt moderation/RSC are live driver state
#                          with driver-dependent exposure - no fixed marker
# Results are written to %SystemRoot%\GGOS\ggos-verify.txt and echoed; HKLM
# stamps (Installed, AppliedVersion, LastVerify) are written under
# HKLM\SOFTWARE\GGOS with AppliedVersion parsed from playbook.conf.
# The script ALWAYS exits 0: verification reports, it must not fail the run.
# All reg.exe calls go through Invoke-GGCommand (spec B2).

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force

$reg = Join-Path $env:SystemRoot 'System32\reg.exe'
$bcdedit = Join-Path $env:SystemRoot 'System32\bcdedit.exe'
$dataDir = Join-Path $env:SystemRoot 'GGOS'
$optionsFile = Join-Path $dataDir 'ggos-options.txt'
$verifyFile = Join-Path $dataDir 'ggos-verify.txt'

# ---------------------------------------------------------------------------
# Version stamp: parse playbook.conf (two levels up from Executables\)
# ---------------------------------------------------------------------------
$version = 'UNKNOWN'
$confCandidates = @(
    (Join-Path $PSScriptRoot '..\playbook.conf'),
    (Join-Path (Get-Location).Path 'playbook.conf')
)
foreach ($cand in $confCandidates) {
    if (Test-Path -LiteralPath $cand) {
        try {
            [xml]$doc = Get-Content -LiteralPath $cand -Raw
            if ($doc.Playbook -and $doc.Playbook.Version) { $version = [string]$doc.Playbook.Version }
        }
        catch {
            Write-GGLog ('Warning: playbook.conf could not be parsed for the version stamp: ' + $_.Exception.Message)
        }
        break
    }
}

# ---------------------------------------------------------------------------
# Expected-marker map (area -> representative checks)
# Kind: reg-dword | reg-sz | reg-key | bcdedit-f8 | pagefile | appx-allusers |
#       appx-provisioned | build-gated-dword | tcpip-latency | chassis-stamp |
#       powercfg-index | power-plan | class-pnp | undo-record |
#       netsh-tcp-global | note
# ---------------------------------------------------------------------------
$Checks = @(
    @{ Area = 'system-optimization'; Kind = 'reg-dword'; Path = 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'; Name = 'LongPathsEnabled'; Expected = '1'; Desc = 'Long paths enabled' },
    @{ Area = 'system-optimization'; Kind = 'reg-sz';    Path = 'HKLM\SYSTEM\CurrentControlSet\Control'; Name = 'WaitToKillServiceTimeout'; Expected = '5000'; Desc = 'Service shutdown timeout 5000 ms' },
    @{ Area = 'system-optimization'; Kind = 'reg-dword'; Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Expected = '0'; Desc = 'Delivery Optimization download mode 0' },

    @{ Area = 'services'; Kind = 'reg-dword'; Path = 'HKLM\SYSTEM\CurrentControlSet\Services\AppVClient'; Name = 'Start'; Expected = '4'; Desc = 'AppVClient disabled' },
    @{ Area = 'services'; Kind = 'reg-dword'; Path = 'HKLM\SYSTEM\CurrentControlSet\Services\PcaSvc'; Name = 'Start'; Expected = '3'; Desc = 'PcaSvc manual' },

    @{ Area = 'telemetry'; Kind = 'reg-dword'; Path = 'HKLM\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Expected = '0'; Desc = 'Diagnostic data policy 0' },
    @{ Area = 'telemetry'; Kind = 'reg-dword'; Path = 'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack'; Name = 'Start'; Expected = '4'; Desc = 'DiagTrack disabled' },
    @{ Area = 'telemetry'; Kind = 'reg-dword'; Path = 'HKLM\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'DoNotShowFeedbackNotifications'; Expected = '1'; Desc = 'Feedback notifications off' },

    @{ Area = 'ads-ui'; Kind = 'reg-dword'; Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; Name = 'EnableFeeds'; Expected = '0'; Desc = 'Windows feeds off' },
    @{ Area = 'ads-ui'; Kind = 'reg-dword'; Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; Name = 'DisabledByGroupPolicy'; Expected = '1'; Desc = 'Advertising ID blocked by policy' },

    @{ Area = 'per-user'; Kind = 'reg-dword'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'LaunchTo'; Expected = '1'; Desc = 'Explorer opens at This PC' },
    @{ Area = 'per-user'; Kind = 'reg-key';   Path = 'HKCU\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; Name = ''; Expected = ''; Desc = 'Classic context menu key present' },
    @{ Area = 'per-user'; Kind = 'reg-dword'; Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Expected = '0'; Desc = 'Silent suggested-app installs off' },

    @{ Area = 'f8-boot'; Kind = 'bcdedit-f8'; Desc = 'Legacy F8 boot menu policy' },

    @{ Area = 'verbose-logon'; Kind = 'reg-dword'; Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'VerboseStatus'; Expected = '1'; Desc = 'Verbose logon status messages on' },

    @{ Area = 'pagefile'; Kind = 'pagefile'; Desc = 'Explicit page-file settings present' },

    @{ Area = 'bloat-copilot'; Kind = 'reg-dword'; Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Expected = '1'; Desc = 'Copilot policy off' },
    @{ Area = 'bloat-copilot'; Kind = 'reg-dword'; Path = 'HKLM\SOFTWARE\Microsoft\Windows\Shell\Copilot'; Name = 'IsCopilotAvailable'; Expected = '0'; Desc = 'Copilot shell availability 0' },

    @{ Area = 'bloat-bing'; Kind = 'appx-allusers';    Name = 'Microsoft.BingSearch'; Desc = 'Bing Search package removed (all users)' },
    @{ Area = 'bloat-bing'; Kind = 'appx-provisioned'; Name = 'Microsoft.BingSearch'; Desc = 'Bing Search not provisioned' },

    @{ Area = 'bloat-widgets'; Kind = 'appx-allusers';    Name = 'Microsoft.WidgetsPlatformRuntime'; Desc = 'Widgets Platform Runtime removed' },
    @{ Area = 'bloat-widgets'; Kind = 'appx-provisioned'; Name = 'MicrosoftWindows.Client.WebExperience'; Desc = 'Web Experience Pack not provisioned' },

    @{ Area = 'bloat-oem'; Kind = 'note'; Desc = 'no static marker - OEM sweep removes publisher-wildcard packages dynamically' },

    @{ Area = 'office-telemetry'; Kind = 'reg-dword'; Path = 'HKCU\SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry'; Name = 'DisableTelemetry'; Expected = '1'; Desc = 'Office client telemetry disabled' },
    @{ Area = 'office-telemetry'; Kind = 'reg-dword'; Path = 'HKCU\SOFTWARE\Microsoft\Office\15.0\Common'; Name = 'QMEnable'; Expected = '0'; Desc = 'Office 15.0 QM off' },

    @{ Area = 'gaming'; Kind = 'reg-dword'; Path = 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HWSchMode'; Expected = '2'; Desc = 'Hardware-accelerated GPU scheduling on' },
    @{ Area = 'gaming'; Kind = 'reg-dword'; Path = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'SystemResponsiveness'; Expected = '10'; Desc = 'SystemResponsiveness 10' },
    @{ Area = 'gaming'; Kind = 'build-gated-dword'; Path = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'; Name = 'GlobalTimerResolutionRequests'; Expected = '1'; MinBuild = 22621; Desc = '24H2 global timer resolution requests (22621+ only)' },

    @{ Area = 'cleanup'; Kind = 'note'; Desc = 'no static marker - cleanup removes files, not registry values' },
    @{ Area = 'cleanup-aggressive'; Kind = 'note'; Desc = 'no static marker - component store/DISM results are transient' },
    @{ Area = 'winget-update'; Kind = 'note'; Desc = 'no static marker - app update state changes continuously after the run' },

    @{ Area = 'network-latency'; Kind = 'tcpip-latency'; Desc = 'TcpAckFrequency=1 present on at least one interface' },

    # ---- v0.4.0 (audit F7): hardware/input/network option coverage ----
    # Every Expected value below was read from the cited ground-truth script,
    # not invented.
    @{ Area = 'pc-auto';    Kind = 'chassis-stamp'; Desc = 'chassis stamp recorded by hardware-policy.ps1' },
    @{ Area = 'pc-desktop'; Kind = 'chassis-stamp'; Desc = 'chassis stamp recorded by hardware-policy.ps1' },
    @{ Area = 'pc-laptop';  Kind = 'chassis-stamp'; Desc = 'chassis stamp recorded by hardware-policy.ps1' },

    # Ground truth: hardware-tuning.ps1 mode 'epp' (Set-PowerValue PERFEPP = 0, AC).
    # The PERFEPP alias is build-registered (not listed by powercfg /aliases on
    # all builds), so no GUID exists in ground truth - the block is matched by
    # its standard English friendly name (English-builds caveat, like netsh).
    @{ Area = 'epp-perf'; Kind = 'powercfg-index'; Subgroup = 'SUB_PROCESSOR'; NamePattern = 'Energy Performance Preference'; Expected = '0'; Desc = 'EPP = 0 (max performance) on the active scheme' },
    # Ground truth: hardware-tuning.ps1 mode 'devices' (SUB_PCIEXPRESS ASPM = 0, AC).
    # ASPM GUID read from powercfg /aliases (ee12f906-...).
    @{ Area = 'desktop-device-power'; Kind = 'powercfg-index'; Subgroup = 'SUB_PCIEXPRESS'; SettingGuid = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; Expected = '0'; Desc = 'PCIe ASPM off on AC' },
    # Ground truth: hardware-tuning.ps1 mode 'nvme' (Primary NVMe Idle Timeout =
    # 60000 ms AC; the script cites the documented GUID D639518A-...; same value
    # for the laptop-named option).
    @{ Area = 'nvme-latency';        Kind = 'powercfg-index'; Subgroup = 'SUB_DISK'; SettingGuid = 'D639518A-E56D-4345-8AF2-B9F32FB26109'; Expected = '60000'; Desc = 'Primary NVMe idle timeout 60000 ms on AC' },
    @{ Area = 'nvme-latency-laptop'; Kind = 'powercfg-index'; Subgroup = 'SUB_DISK'; SettingGuid = 'D639518A-E56D-4345-8AF2-B9F32FB26109'; Expected = '60000'; Desc = 'Primary NVMe idle timeout 60000 ms on AC (laptop option)' },
    # Ground truth: hardware-tuning.ps1 mode 'wireless' (SUB_USB USBSELECTIVESUSPEND = 0 AC).
    # No GUID in ground truth (alias build-registered) - friendly-name match.
    @{ Area = 'wireless-input'; Kind = 'powercfg-index'; Subgroup = 'SUB_USB'; NamePattern = 'USB\s*Selective\s*Suspend'; Expected = '0'; Desc = 'USB selective suspend off on AC' },
    # Ground truth: hardware-tuning.ps1 mode 'wireless' (Bluetooth radio PnPCapabilities = 24).
    @{ Area = 'wireless-input'; Kind = 'class-pnp'; ClassKey = 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{e0cbf06c-cd8b-4647-bb8a-263b43f0f974}'; Expected = '24'; Desc = 'Bluetooth radio power mgmt off (PnPCapabilities=24 on at least one radio)' },

    # Ground truth: gaming-power.ps1 $script:GGOSLaptopPlanGuid ('GGOS Laptop').
    @{ Area = 'laptop-power'; Kind = 'power-plan'; Guid = 'c7d3a1e9-8b4f-4c62-9d5a-3f2e1b4a7c8d'; Desc = 'GGOS Laptop plan present in powercfg /list' },

    # Ground truth: wifi-tuning.ps1 Set-WifiPowerManagement (PnPCapabilities=24
    # fallback on the NIC class instance key). The primary cmdlet path leaves no
    # registry marker, so an absent value can also mean "applied via cmdlet" -
    # the DRIFT detail says so.
    @{ Area = 'wifi-tuning'; Kind = 'class-pnp'; ClassKey = 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'; Expected = '24'; Desc = 'Wi-Fi/NIC adapter power mgmt off (PnPCapabilities=24 on at least one NIC)' },

    # Ground truth: input-tuning.ps1 mode 'accel' (per-user.ps1 has no accel
    # entries; the accel option applies through the shared Apply-GGUserValues
    # engine with the values below, REG_SZ '0' - the native type Windows keeps).
    @{ Area = 'input-accel'; Kind = 'reg-sz'; Path = 'HKCU\Control Panel\Mouse'; Name = 'MouseSpeed';      Expected = '0'; Desc = 'mouse acceleration off (MouseSpeed=0)' },
    @{ Area = 'input-accel'; Kind = 'reg-sz'; Path = 'HKCU\Control Panel\Mouse'; Name = 'MouseThreshold1'; Expected = '0'; Desc = 'mouse threshold1 = 0' },
    @{ Area = 'input-accel'; Kind = 'reg-sz'; Path = 'HKCU\Control Panel\Mouse'; Name = 'MouseThreshold2'; Expected = '0'; Desc = 'mouse threshold2 = 0' },

    # Ground truth: input-tuning.ps1 mode 'queue' (REG_DWORD 8 under the class
    # driver Parameters keys).
    @{ Area = 'input-queue'; Kind = 'reg-dword'; Path = 'HKLM\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'; Name = 'MouseDataQueueSize';     Expected = '8'; Desc = 'mouse data queue size 8' },
    @{ Area = 'input-queue'; Kind = 'reg-dword'; Path = 'HKLM\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; Name = 'KeyboardDataQueueSize'; Expected = '8'; Desc = 'keyboard data queue size 8' },

    # Ground truth: network-tuning.ps1 mode 'bufferbloat' (PacingProfile Always
    # via Set-NetTCPSetting, netsh fallback identical). Live-state check.
    @{ Area = 'network-bufferbloat'; Kind = 'netsh-tcp-global'; Expected = 'always'; Desc = 'TCP pacing profile always (netsh int tcp show global)' },
    # Ground truth: network-tuning.ps1 mode 'nic' (undo record written under
    # NetworkUndo\NicUndo before each change; driver-level live state is not
    # statically verifiable, so the run marker is the honest registry check).
    @{ Area = 'network-nic'; Kind = 'undo-record'; Path = 'HKLM\SOFTWARE\GGOS\NetworkUndo\NicUndo'; MatchName = '::Flow Control'; Desc = 'NIC tuning ran (undo record in NetworkUndo\NicUndo)' },
    # Ground truth: network-tuning.ps1 mode 'ultra' - interrupt moderation/RSC
    # writes are driver-dependent live state with no fixed offline marker.
    @{ Area = 'network-ultra'; Kind = 'note'; Desc = 'no fixed offline marker - interrupt moderation/RSC are live driver state (exposure varies by driver)' }
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-GGRegValue {
    # Returns $true, $type, $data when the value exists (reg.exe query).
    # Since v0.4.0 (audit F4) Invoke-GGCommand returns the exit code; reg.exe
    # exits 1 for a missing key/value, so existence is decided from the exit
    # code first, then from the parsed output.
    param([string]$Path, [string]$Name)
    $qArgs = @('query', $Path)
    if ($Name) { $qArgs += @('/v', $Name) } else { $qArgs += '/ve' }
    $ok, $exit, $out = Invoke-GGCommand -FilePath $reg -ArgumentList $qArgs -TimeoutSeconds 20 -Description ('registry query ' + $Path + ' ' + $Name)
    if (-not ($ok -and $exit -eq 0)) { return $false, '', '' }
    $typePattern = 'REG_(SZ|EXPAND_SZ|MULTI_SZ|DWORD|QWORD|BINARY|NONE)'
    $dataLines = @(@($out) | Where-Object { $_ -match $typePattern })
    if ($dataLines.Count -eq 0) { return $false, '', '' }
    # Line format: <name><spaces><TYPE><spaces><data...>
    $type = ''
    $data = ''
    if ($dataLines[0] -match ('^\s*\S+\s+' + $typePattern + '\s?(.*)$')) {
        $type = $Matches[1]
        $data = $Matches[2].Trim()
    }
    # MULTI_SZ continuation lines (reg.exe indents continuation data).
    if ($type -eq 'MULTI_SZ' -and $dataLines.Count -gt 1) {
        $extra = @()
        for ($i = 1; $i -lt $dataLines.Count; $i++) { $extra += $dataLines[$i].Trim() }
        $data = (@($data) + $extra) -join ' | '
    }
    return $true, $type, $data
}

function ConvertTo-GGDword {
    param([string]$Text)
    if ($Text -match '^0x([0-9a-fA-F]+)$') { return [int]('0x' + $Matches[1]) }
    $n = 0
    if ([int]::TryParse($Text.Trim(), [ref]$n)) { return $n }
    return $null
}

# ---------------------------------------------------------------------------
# Evaluate
# ---------------------------------------------------------------------------
$selected = @()
if (Test-Path -LiteralPath $optionsFile) {
    $selected = @(Get-Content -LiteralPath $optionsFile -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' } |
        Select-Object -Unique)
}

$lines = @()
$passCount = 0
$driftCount = 0
$noteCount = 0

if ($selected.Count -eq 0) {
    $lines += 'GGOS verify: option ledger was empty or missing - nothing to verify.'
    Write-GGLog 'Option ledger was empty or missing - nothing to verify.'
}

foreach ($area in $selected) {
    $areaChecks = @($Checks | Where-Object { $_.Area -eq $area })
    if ($areaChecks.Count -eq 0) {
        $lines += ('NOTE  {0}: no expected marker map defined for this area' -f $area)
        $noteCount++
        continue
    }
    foreach ($c in $areaChecks) {
        $status = 'NOTE'
        $detail = ''
        switch ($c.Kind) {
            'reg-dword' {
                $exists, $type, $data = Get-GGRegValue -Path $c.Path -Name $c.Name
                if (-not $exists) {
                    $status = 'DRIFT'; $detail = ('value missing (expected {0})' -f $c.Expected)
                }
                else {
                    $num = ConvertTo-GGDword $data
                    if ($null -eq $num) { $status = 'DRIFT'; $detail = ('unreadable data ''{0}'' (expected {1})' -f $data, $c.Expected) }
                    elseif ($num -ne [int]$c.Expected) { $status = 'DRIFT'; $detail = ('found {0} (expected {1})' -f $num, $c.Expected) }
                    else { $status = 'PASS' }
                }
            }
            'reg-sz' {
                $exists, $type, $data = Get-GGRegValue -Path $c.Path -Name $c.Name
                if (-not $exists) { $status = 'DRIFT'; $detail = ('value missing (expected ''{0}'')' -f $c.Expected) }
                elseif ($data -ne $c.Expected) { $status = 'DRIFT'; $detail = ('found ''{0}'' (expected ''{1}'')' -f $data, $c.Expected) }
                else { $status = 'PASS' }
            }
            'reg-key' {
                # Cmdlet check (no external process): map HKCU/HKLM to the
                # Registry:: provider path and test key existence directly.
                $psPath = $c.Path -replace '^HKCU\\', 'HKEY_CURRENT_USER\' -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\'
                if (Test-Path -LiteralPath ('Registry::' + $psPath)) { $status = 'PASS' }
                else { $status = 'DRIFT'; $detail = 'key missing' }
            }
            'bcdedit-f8' {
                $ok, $exit, $out = Invoke-GGCommand -FilePath $bcdedit -ArgumentList @('/enum', '{current}') -TimeoutSeconds 30 -Description 'bcdedit boot menu policy check'
                $found = $false
                if ($ok -and $exit -eq 0) {
                    foreach ($line in @($out)) {
                        if ($line -match 'bootmenupolicy' -and $line -match 'Legacy') { $found = $true; break }
                    }
                }
                if ($found) { $status = 'PASS' }
                else { $status = 'DRIFT'; $detail = 'bootmenupolicy Legacy not found in {current}' }
            }
            'pagefile' {
                $exists, $type, $data = Get-GGRegValue -Path 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'PagingFiles'
                $explicit = $false
                if ($exists) {
                    foreach ($entry in ($data -split ' \| ')) {
                        if ($entry -match '(?i)^[a-z]:\\.*pagefile.*\.sys') { $explicit = $true; break }
                    }
                }
                if ($explicit) { $status = 'PASS' }
                else { $status = 'DRIFT'; $detail = 'page file still automatic (no explicit drive-letter setting)' }
            }
            'appx-allusers' {
                $pkgs = @(Get-AppxPackage -AllUsers -Name $c.Name -ErrorAction SilentlyContinue)
                if ($pkgs.Count -eq 0) { $status = 'PASS' }
                else { $status = 'DRIFT'; $detail = ('{0} package(s) still present' -f $pkgs.Count) }
            }
            'appx-provisioned' {
                $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $c.Name })
                if ($prov.Count -eq 0) { $status = 'PASS' }
                else { $status = 'DRIFT'; $detail = ('{0} provisioned package(s) still present' -f $prov.Count) }
            }
            'build-gated-dword' {
                $build = 0
                $exists, $type, $data = Get-GGRegValue -Path 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuildNumber'
                if ($exists) { $build = ConvertTo-GGDword $data }
                if ($build -lt [int]$c.MinBuild) {
                    $status = 'NOTE'; $detail = ('build {0} < {1} - value is not expected on this build' -f $build, $c.MinBuild)
                }
                else {
                    $vExists, $vType, $vData = Get-GGRegValue -Path $c.Path -Name $c.Name
                    $num = $null
                    if ($vExists) { $num = ConvertTo-GGDword $vData }
                    if ($null -ne $num -and $num -eq [int]$c.Expected) { $status = 'PASS' }
                    else { $status = 'DRIFT'; $detail = ('found {0} (expected {1} on build {2})' -f $num, $c.Expected, $build) }
                }
            }
            'tcpip-latency' {
                $ok, $exit, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('query', 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces', '/s', '/v', 'TcpAckFrequency') -TimeoutSeconds 30 -Description 'TcpAckFrequency recursive query'
                $found = $false
                if ($ok -and $exit -eq 0) {
                    foreach ($line in @($out)) {
                        if ($line -match 'TcpAckFrequency' -and $line -match '0x1\b') { $found = $true; break }
                    }
                }
                if ($found) { $status = 'PASS' }
                else { $status = 'DRIFT'; $detail = 'no interface with TcpAckFrequency=1 found' }
            }
            'chassis-stamp' {
                # v0.4.0 (audit F7): pc-auto / pc-desktop / pc-laptop. Informational
                # correlation with the 'Chassis' stamp written by hardware-policy.ps1
                # (ground truth: hardware-policy.ps1 section 6). PASS = stamp exists.
                # Review fix (0.4.0): when system-optimization was NOT selected,
                # hardware-policy.yml is gated off and the stamp is legitimately
                # absent - that is NOTE, not DRIFT.
                $exists, $type, $data = Get-GGRegValue -Path 'HKLM\SOFTWARE\GGOS\HardwarePolicy' -Name 'Chassis'
                if ($exists) { $status = 'PASS' }
                elseif ($selected -notcontains 'system-optimization') {
                    $status = 'NOTE'; $detail = 'hardware-policy did not run (system-optimization not selected) - no chassis stamp expected'
                }
                else { $status = 'DRIFT'; $detail = 'HKLM\SOFTWARE\GGOS\HardwarePolicy Chassis stamp missing (hardware-policy.ps1 did not run or failed)' }
            }
            'powercfg-index' {
                # v0.4.0 (audit F7): live AC index of a powercfg setting on the
                # active scheme. Ground truth per entry: the option's tuning
                # script (cited in $Checks).
                # The SUBGROUP-WIDE query is used on purpose: a direct per-setting
                # query (powercfg /q <scheme> <sub> <setting>) exits 0 with only
                # the scheme header when the setting is hidden and never set, so
                # it cannot distinguish "absent" from a real block. The subgroup
                # enumeration lists every present setting as a block; the target
                # block is matched by full GUID (SettingGuid, from ground truth)
                # or by its English friendly name (NamePattern - English-builds
                # caveat, same as the netsh parses). Hidden settings appear here
                # once the tuning script has unhidden them. The Current AC/DC
                # index lines print at a lower indent but belong to the preceding
                # setting block, so the first AC-index line after a matching
                # block header is that block's value.
                $ok, $exit, $out = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('/q', 'SCHEME_CURRENT', $c.Subgroup) -TimeoutSeconds 20 -Description "powercfg query $($c.Subgroup)"
                $index = $null
                # Review fix (0.4.0): epp-perf and desktop-device-power are
                # desktop-only; on a laptop/unknown chassis the tuning script's
                # chassis guard skips them by design (skipped.txt), so a missing
                # marker is the EXPECTED outcome - report NOTE, not DRIFT.
                if ($c.Area -in 'epp-perf', 'desktop-device-power') {
                    $stampExists, $stampType, $stampData = Get-GGRegValue -Path 'HKLM\SOFTWARE\GGOS\HardwarePolicy' -Name 'Chassis'
                    if (-not $stampExists -or $stampData -ne 'Desktop') {
                        $resolvedChassis = if ($stampExists) { $stampData } else { 'Unknown' }
                        $status = 'NOTE'
                        $detail = ('desktop-only option skipped by the chassis guard (resolved chassis: {0}) - setting left untouched by design' -f $resolvedChassis)
                        break
                    }
                }
                if ($ok -and $exit -eq 0) {
                    $inTarget = $false
                    foreach ($line in @($out)) {
                        if ($line -match 'Power Setting GUID:\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                            $inTarget = ($null -ne $c.SettingGuid -and $Matches[1] -ieq $c.SettingGuid)
                            if (-not $inTarget -and $c.NamePattern) { $inTarget = ($line -match $c.NamePattern) }
                            continue
                        }
                        if ($inTarget -and $line -match 'Current (AC|Plugged) Power Setting Index:\s*(0x[0-9a-fA-F]+)') {
                            $index = ConvertTo-GGDword $Matches[2]; break
                        }
                    }
                }
                $expectedNum = ConvertTo-GGDword $c.Expected
                if ($null -eq $index) { $status = 'DRIFT'; $detail = 'setting not exposed in the subgroup enumeration or powercfg query failed' }
                elseif ($index -ne $expectedNum) { $status = 'DRIFT'; $detail = ('found 0x{0:X} (expected 0x{1:X})' -f $index, $expectedNum) }
                else { $status = 'PASS' }
            }
            'power-plan' {
                # v0.4.0 (audit F7): fixed-GUID plan presence in powercfg /list
                # (ground truth: gaming-power.ps1 fixed-GUID plan machinery).
                $ok, $exit, $out = Invoke-GGCommand -FilePath 'powercfg.exe' -ArgumentList @('/list') -TimeoutSeconds 20 -Description 'powercfg list'
                $found = $false
                if ($ok -and $exit -eq 0) {
                    foreach ($line in @($out)) {
                        if ($line -match [regex]::Escape($c.Guid)) { $found = $true; break }
                    }
                }
                if ($found) { $status = 'PASS' }
                else { $status = 'DRIFT'; $detail = ('plan GUID {0} not present in powercfg /list' -f $c.Guid) }
            }
            'class-pnp' {
                # v0.4.0 (audit F7): recursive PnPCapabilities scan over one device
                # class key (mirrors the tcpip-latency pattern). PnPCapabilities is
                # written as REG_DWORD, so reg query shows hex (24 -> 0x18).
                $ok, $exit, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('query', $c.ClassKey, '/s', '/v', 'PnPCapabilities') -TimeoutSeconds 30 -Description ('PnPCapabilities recursive query ' + $c.ClassKey)
                $found = $false
                $pnpHex = '0x{0:X}' -f (ConvertTo-GGDword $c.Expected)
                if ($ok -and $exit -eq 0) {
                    foreach ($line in @($out)) {
                        if ($line -match 'PnPCapabilities' -and $line -match ($pnpHex + '\b')) { $found = $true; break }
                    }
                }
                if ($found) { $status = 'PASS' }
                else { $status = 'DRIFT'; $detail = ('no device under {0} with PnPCapabilities={1} (not applied, no eligible device, or applied via cmdlet)' -f $c.ClassKey, $pnpHex) }
            }
            'undo-record' {
                # v0.4.0 (audit F7): presence of the option script's own undo
                # record - the honest registry-visible marker when the setting
                # itself is live driver state. reg query of the key lists every
                # value name; MatchName appears in the recorded value names.
                $ok, $exit, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('query', $c.Path) -TimeoutSeconds 20 -Description ('undo-record query ' + $c.Path)
                $found = $false
                if ($ok -and $exit -eq 0) {
                    foreach ($line in @($out)) {
                        if ($line -match [regex]::Escape($c.MatchName)) { $found = $true; break }
                    }
                }
                if ($found) { $status = 'PASS' }
                else { $status = 'DRIFT'; $detail = ('no ''{0}'' record under {1} (option did not run or no eligible target)' -f $c.MatchName, $c.Path) }
            }
            'netsh-tcp-global' {
                # v0.4.0 (audit F7): live TCP global state. English builds only
                # (same locale caveat as the wifi profile parse in wifi-tuning).
                # Pacing Profile is the non-default discriminator; ECN/auto-tuning
                # are checked for information only (can be OS defaults).
                $ok, $exit, $out = Invoke-GGCommand -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'show', 'global') -TimeoutSeconds 20 -Description 'netsh int tcp show global'
                $found = $false
                if ($ok -and $exit -eq 0) {
                    foreach ($line in @($out)) {
                        if ($line -match ('Pacing Profile\s*:\s*' + [regex]::Escape($c.Expected) + '\s*$')) { $found = $true; break }
                    }
                }
                if ($found) { $status = 'PASS' }
                else { $status = 'DRIFT'; $detail = ('Pacing Profile is not ''{0}'' (netsh int tcp show global)' -f $c.Expected) }
            }
            'note' {
                $status = 'NOTE'; $detail = $c.Desc
            }
        }
        if ($status -eq 'PASS') {
            $passCount++
            $lines += ('PASS  {0}: {1}' -f $area, $c.Desc)
        }
        elseif ($status -eq 'DRIFT') {
            $driftCount++
            $lines += ('DRIFT {0}: {1} ({2})' -f $area, $c.Desc, $detail)
        }
        else {
            $noteCount++
            $lines += ('NOTE  {0}: {1}' -f $area, $detail)
        }
    }
}

# ---------------------------------------------------------------------------
# Summary, verify file, HKLM stamps
# ---------------------------------------------------------------------------
$summary = ('{0} PASS / {1} DRIFT / {2} NOTE (version {3})' -f $passCount, $driftCount, $noteCount, $version)
$lines += ('GGOS: verification summary: {0}' -f $summary)

try {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    Set-Content -LiteralPath $verifyFile -Value $lines -ErrorAction Stop
    Write-GGLog ('Verification report written to ' + $verifyFile)
}
catch {
    Write-GGLog ('Warning: verify report could not be written: ' + $_.Exception.Message)
}

$stampOk = $true
foreach ($stampCmd in @(
    @{ Args = @('add', 'HKLM\SOFTWARE\GGOS', '/v', 'Installed', '/t', 'REG_DWORD', '/d', '1', '/f'); Desc = 'HKLM\SOFTWARE\GGOS Installed stamp' },
    @{ Args = @('add', 'HKLM\SOFTWARE\GGOS', '/v', 'AppliedVersion', '/t', 'REG_SZ', '/d', $version, '/f'); Desc = 'HKLM\SOFTWARE\GGOS AppliedVersion stamp' },
    @{ Args = @('add', 'HKLM\SOFTWARE\GGOS', '/v', 'LastVerify', '/t', 'REG_SZ', '/d', $summary, '/f'); Desc = 'HKLM\SOFTWARE\GGOS LastVerify stamp' }
)) {
    $ok, $exit, $out = Invoke-GGCommand -FilePath $reg -ArgumentList $stampCmd.Args -TimeoutSeconds 20 -Description $stampCmd.Desc
    # Success = completed within timeout AND reg.exe exited 0 (audit F4).
    $succeeded = ($ok -and $exit -eq 0)
    if (-not $succeeded) { $stampOk = $false; Write-GGLog "Warning: $($stampCmd.Desc) $(if ($ok) { "failed (exit $exit)" } else { 'timed out' })." }
}

if ($stampOk) {
    Write-GGLog ('HKLM\SOFTWARE\GGOS stamped: Installed=1, AppliedVersion=' + $version + ', LastVerify=' + $summary)
}
else {
    Write-GGLog 'Warning: one or more HKLM\SOFTWARE\GGOS stamps failed (see skipped.txt on timeouts).'
}

Write-GGLog ('Verification summary: ' + $summary)

# Always exit 0 - verification reports, it must not fail the playbook run.
exit 0
