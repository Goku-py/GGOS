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
#       appx-provisioned | build-gated-dword | tcpip-latency | note
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

    @{ Area = 'network-latency'; Kind = 'tcpip-latency'; Desc = 'TcpAckFrequency=1 present on at least one interface' }
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-GGRegValue {
    # Returns $true, $type, $data when the value exists (reg.exe query).
    # Note: Invoke-GGCommand reports "completed within timeout", not the exit
    # code, so existence is decided from the parsed output, not from $ok.
    param([string]$Path, [string]$Name)
    $qArgs = @('query', $Path)
    if ($Name) { $qArgs += @('/v', $Name) } else { $qArgs += '/ve' }
    $ok, $out = Invoke-GGCommand -FilePath $reg -ArgumentList $qArgs -TimeoutSeconds 20 -Description ('registry query ' + $Path + ' ' + $Name)
    if (-not $ok) { return $false, '', '' }
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
                $ok, $out = Invoke-GGCommand -FilePath $bcdedit -ArgumentList @('/enum', '{current}') -TimeoutSeconds 30 -Description 'bcdedit boot menu policy check'
                $found = $false
                if ($ok) {
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
                $ok, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('query', 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces', '/s', '/v', 'TcpAckFrequency') -TimeoutSeconds 30 -Description 'TcpAckFrequency recursive query'
                $found = $false
                if ($ok) {
                    foreach ($line in @($out)) {
                        if ($line -match 'TcpAckFrequency' -and $line -match '0x1\b') { $found = $true; break }
                    }
                }
                if ($found) { $status = 'PASS' }
                else { $status = 'DRIFT'; $detail = 'no interface with TcpAckFrequency=1 found' }
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
    $ok, $out = Invoke-GGCommand -FilePath $reg -ArgumentList $stampCmd.Args -TimeoutSeconds 20 -Description $stampCmd.Desc
    # Invoke-GGCommand reports completion, not the exit code - reg add prints
    # a success line, so validate from the output.
    $succeeded = $ok -and (@($out) | Where-Object { $_ -match 'operation completed successfully' })
    if (-not $succeeded) { $stampOk = $false }
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
