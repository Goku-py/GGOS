# GGOS per-user tweaks (v0.2) - triple sweep (spec B1) + first-logon hook (B5).
# Applies per-user registry settings to three sweep targets, in order:
#   1. Every loaded interactive user hive under HKU: SIDs matching
#      S-1-5-21-<domain>-<a>-<b>-<rid> that carry a 'Volatile Environment'
#      subkey (community-validated interactive-profile marker). _Classes
#      subkeys, service accounts (S-1-5-18/19/20) and virtual accounts
#      (S-1-5-96-*) are excluded by the SID pattern; special profiles are
#      additionally skipped via Win32_UserProfile.
#   2. HKU\.DEFAULT (LocalSystem hive - values visible at the logon screen;
#      the Office telemetry block is skipped there as it is not
#      logon-screen-relevant).
#   3. The Default profile template hive (C:\Users\Default\NTUSER.DAT).
#      If AME Wizard already mounted it as HKU\AME_UserHive_Default, that
#      mount is reused (never unloaded). Otherwise it is mounted as
#      HKU\GGOS_DefaultHive via reg load, with a leftover-mount cleanup and
#      an unload-in-finally with retry-on-delay pattern.
# Before writing to a hive, the whole hive is exported via reg.exe to
# %SystemRoot%\GGOS\hive-backups\<hiveName>-<stamp>.reg (reg.exe writes the
# .reg file with its own BOM handling; the export is never re-encoded).
# Every external call goes through Invoke-GGCommand (spec B2 bounded timeout;
# timeouts are appended to %SystemRoot%\GGOS\skipped.txt by the wrapper).
# After the Default template sweep, a RunOnce value is written into the
# template hive pointing at %SystemRoot%\GGOS\first-logon.ps1 so brand-new
# accounts receive the cosmetic subset at first logon (spec B5).
# All value paths below are hive-root-relative, so the Registry::HKEY_USERS\<target>
# prefix resolves them per-hive (including any desktop-relative entries).
# Structure re-expressed from TBOK's per-user routine and the FSOS-X sweep
# model (reference only); no upstream code or comments copied.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force

$reg = Join-Path $env:SystemRoot 'System32\reg.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dataDir = Join-Path $env:SystemRoot 'GGOS'
$backupDir = Join-Path $dataDir 'hive-backups'

# ---------------------------------------------------------------------------
# Per-user value set. Paths are relative to the target hive root.
# Ops: 'set' writes the value, 'del' removes it.
# Group 'core' is applied to every sweep target; Group 'office' entries are
# skipped on HKU\.DEFAULT (spec: .DEFAULT receives logon-screen-relevant
# values only).
# ---------------------------------------------------------------------------
$UserValues = @(
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                       Name = 'LaunchTo';                              Type = 'DWord';  Data = 1;  Group = 'core' },              # Explorer opens at This PC
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications';           Name = 'GlobalUserDisabled';                    Type = 'DWord';  Data = 1;  Group = 'core' },              # Store apps: no background execution
    @{ Op = 'set'; Path = 'Software\Microsoft\GameBar';                                                       Name = 'AutoGameModeEnabled';                   Type = 'DWord';  Data = 1;  Group = 'core' },              # Game Mode always on
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; Name = 'TaskbarEndTask';                     Type = 'DWord';  Data = 1;  Group = 'core' },              # End Task in taskbar right-click
    @{ Op = 'set'; Path = 'SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32';      Name = '';                                      Type = 'Key';    Data = $null; Group = 'core' },           # Classic full context menu (key only, Win11)
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Search';                                 Name = 'BingSearchEnabled';                     Type = 'DWord';  Data = 0;  Group = 'core' },              # Local start-menu search only
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'Start_Layout';                          Type = 'DWord';  Data = 1;  Group = 'core' },              # Start menu: more pins, less waste
    @{ Op = 'set'; Path = 'Control Panel\Desktop';                                                            Name = 'MenuShowDelay';                         Type = 'String'; Data = '10'; Group = 'core' },             # Menu delay 400ms -> 10ms
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects';                 Name = 'VisualFXSetting';                       Type = 'DWord';  Data = 3;  Group = 'core' },              # Visual effects: custom
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'TaskbarAnimations';                     Type = 'DWord';  Data = 0;  Group = 'core' },              # Taskbar animations off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'TaskbarAI';                             Type = 'DWord';  Data = 0;  Group = 'core' },              # Copilot icon off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'ShowCopilotButton';                     Type = 'DWord';  Data = 0;  Group = 'core' },              # Copilot icon off (second key)
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'ListviewAlphaSelect';                   Type = 'DWord';  Data = 1;  Group = 'core' },              # Selection rectangle alpha on
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'ListviewShadow';                        Type = 'DWord';  Data = 1;  Group = 'core' },              # Icon shadows on
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'TaskbarMn';                             Type = 'DWord';  Data = 0;  Group = 'core' },              # People/chat band off
    @{ Op = 'set'; Path = 'Control Panel\Desktop';                                                            Name = 'DragFullWindows';                       Type = 'String'; Data = '1'; Group = 'core' },             # Show window contents while dragging
    @{ Op = 'set'; Path = 'Control Panel\Desktop\WindowMetrics';                                              Name = 'MinAnimate';                            Type = 'String'; Data = '0'; Group = 'core' },             # Minimize/restore animation off
    @{ Op = 'set'; Path = 'Control Panel\Keyboard';                                                           Name = 'KeyboardDelay';                         Type = 'String'; Data = '0'; Group = 'core' },             # Keyboard repeat delay short
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\DWM';                                                   Name = 'EnableAeroPeek';                        Type = 'DWord';  Data = 0;  Group = 'core' },              # Aero Peek off
    @{ Op = 'set'; Path = 'Software\Policies\Microsoft\Windows\Explorer';                                     Name = 'DisableSearchBoxSuggestions';           Type = 'DWord';  Data = 1;  Group = 'core' },              # Search box suggestions off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'ShowSyncProviderNotifications';         Type = 'DWord';  Data = 0;  Group = 'core' },              # Explorer sync-provider ads off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'Start_AccountNotifications';            Type = 'DWord';  Data = 0;  Group = 'core' },              # Start menu account notifications off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement';                  Name = 'ScoobeSystemSettingEnabled';            Type = 'DWord';  Data = 0;  Group = 'core' },              # "Finish setting up" prompts off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'RotatingLockScreenOverlayEnabled';      Type = 'DWord';  Data = 0;  Group = 'core' },              # Lock screen tips/ads off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo';                        Name = 'Enabled';                               Type = 'DWord';  Data = 0;  Group = 'core' },              # Personalized ad ID off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-310093Enabled';       Type = 'DWord';  Data = 0;  Group = 'core' },              # Welcome experience off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-338387Enabled';       Type = 'DWord';  Data = 0;  Group = 'core' },              # Settings suggestions off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-353694Enabled';       Type = 'DWord';  Data = 0;  Group = 'core' },              # Suggestions off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-353696Enabled';       Type = 'DWord';  Data = 0;  Group = 'core' },              # Suggestions off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SystemPaneSuggestionsEnabled';          Type = 'DWord';  Data = 0;  Group = 'core' },              # Start menu suggestions off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-338388Enabled';       Type = 'DWord';  Data = 0;  Group = 'core' },              # Silent app installs off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-338389Enabled';       Type = 'DWord';  Data = 0;  Group = 'core' },              # General tips off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-338393Enabled';       Type = 'DWord';  Data = 0;  Group = 'core' },              # Home screen suggestions off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-353698Enabled';       Type = 'DWord';  Data = 0;  Group = 'core' },              # Timeline suggestions off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SilentInstalledAppsEnabled';            Type = 'DWord';  Data = 0;  Group = 'core' },              # Silent suggested-app installs off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'ContentDeliveryAllowed';                Type = 'DWord';  Data = 0;  Group = 'core' },              # Content delivery off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'OemPreInstalledAppsEnabled';            Type = 'DWord';  Data = 0;  Group = 'core' },              # OEM app auto-enable off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'PreInstalledAppsEnabled';               Type = 'DWord';  Data = 0;  Group = 'core' },              # Preinstalled app auto-enable off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'PreInstalledAppsEverEnabled';           Type = 'DWord';  Data = 0;  Group = 'core' },              # Preinstalled app re-enable off
    @{ Op = 'set'; Path = 'Software\Microsoft\Siuf\Rules';                                                    Name = 'NumberOfSIUFInPeriod';                  Type = 'DWord';  Data = 0;  Group = 'core' },              # Feedback request frequency 0
    @{ Op = 'del'; Path = 'Software\Microsoft\Siuf\Rules';                                                    Name = 'PeriodInNanoSeconds';                   Type = '';       Data = $null; Group = 'core' },           # Stale feedback timer removed
    @{ Op = 'set'; Path = 'SOFTWARE\Policies\Microsoft\Windows\CloudContent';                                 Name = 'DisableTailoredExperiencesWithDiagnosticData'; Type = 'DWord'; Data = 1; Group = 'core' },        # Tailored experiences off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager';        Name = 'EnthusiastMode';                        Type = 'DWord';  Data = 1;  Group = 'core' },              # Show more file-operation detail
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'Start_IrisRecommendations';             Type = 'DWord';  Data = 0;  Group = 'core' },              # Start menu recommendation ads off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Privacy';                                Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Type = 'DWord'; Data = 0; Group = 'core' },        # Tailored experiences off (settings key)
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'ShowTaskViewButton';                    Type = 'DWord';  Data = 0;  Group = 'core' },              # Task View button hidden
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People';               Name = 'PeopleBand';                            Type = 'DWord';  Data = 0;  Group = 'core' },              # People band hidden
    @{ Op = 'set'; Path = 'Control Panel\Desktop';                                                            Name = 'AutoEndTasks';                          Type = 'String'; Data = '0'; Group = 'core' },             # Apps may prompt to save at sign-out
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';                      Name = 'HideSCAMeetNow';                        Type = 'DWord';  Data = 1;  Group = 'core' },              # Meet Now icon hidden
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Search';                                 Name = 'SearchboxTaskbarMode';                  Type = 'DWord';  Data = 1;  Group = 'core' },              # Search box: icon only
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration';        Name = 'IsResumeAllowed';                       Type = 'DWord';  Data = 0;  Group = 'core' },              # Cross-device resume off
    @{ Op = 'set'; Path = 'Software\Policies\Microsoft\Windows\WindowsCopilot';                               Name = 'TurnOffWindowsCopilot';                 Type = 'DWord';  Data = 1;  Group = 'core' },              # Copilot off (per-user policy)
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsCopilot';                         Name = 'AllowCopilotRuntime';                   Type = 'DWord';  Data = 0;  Group = 'core' },              # Copilot runtime off
    # Office logging / telemetry (versions 15.0 and 16.0)
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\15.0\Outlook\Options\Mail';                              Name = 'EnableLogging';                         Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\15.0\Outlook\Options\Calendar';                          Name = 'EnableCalendarLogging';                 Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\15.0\Word\Options';                                      Name = 'EnableLogging';                         Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Policies\Microsoft\Office\15.0\OSM';                                      Name = 'EnableLogging';                         Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Policies\Microsoft\Office\15.0\OSM';                                      Name = 'EnableUpload';                          Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\15.0\Common';                                            Name = 'QMEnable';                              Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\15.0\Common\Feedback';                                   Name = 'Enabled';                               Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Outlook\Options\Mail';                              Name = 'EnableLogging';                         Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Outlook\Options\Calendar';                          Name = 'EnableCalendarLogging';                 Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Word\Options';                                      Name = 'EnableLogging';                         Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Policies\Microsoft\Office\16.0\OSM';                                      Name = 'EnableLogging';                         Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Policies\Microsoft\Office\16.0\OSM';                                      Name = 'EnableUpload';                          Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Common';                                            Name = 'QMEnable';                              Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Common\Feedback';                                   Name = 'Enabled';                               Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\Common\ClientTelemetry';                                 Name = 'DisableTelemetry';                      Type = 'DWord';  Data = 1;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry';                            Name = 'DisableTelemetry';                      Type = 'DWord';  Data = 1;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\Common\ClientTelemetry';                                 Name = 'VerboseLogging';                        Type = 'DWord';  Data = 0;  Group = 'office' },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry';                            Name = 'VerboseLogging';                        Type = 'DWord';  Data = 0;  Group = 'office' }
)

# Accessibility (StickyKeys) is deliberately not changed.
# Explorer Bags/BagMRU reset is deliberately not performed (opt-in only).

$script:Failures = 0
$script:Applied  = 0
$script:HivesTouched = 0

function Backup-HiveKey {
    param([string]$RegKey, [string]$HiveName)
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $file = Join-Path $backupDir ('{0}-{1}.reg' -f $HiveName, $stamp)
    # reg.exe writes the .reg file itself (UTF-16 LE BOM is reg.exe's own
    # format); the output is never re-encoded.
    # Invoke-GGCommand reports "completed within timeout", not the exit code,
    # so success is confirmed by the export file existing.
    $ok, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('export', $RegKey, $file, '/y') -TimeoutSeconds 60 -Description ('hive export ' + $RegKey)
    if ($ok -and (Test-Path -LiteralPath $file)) {
        Write-GGLog ('Exported ' + $RegKey + ' to ' + $file + '.')
        return $true
    }
    Write-GGLog ('Warning: export of ' + $RegKey + ' failed (continuing without that backup).')
    return $false
}

function Apply-ToHive {
    param([string]$Root, [string[]]$Groups = @('core', 'office'))
    foreach ($entry in $UserValues) {
        if ($entry.Group -notin $Groups) { continue }
        try {
            $keyPath = 'Registry::' + $Root + '\' + $entry.Path
            if ($entry.Op -eq 'del') {
                if (Test-Path -LiteralPath $keyPath) {
                    Remove-ItemProperty -LiteralPath $keyPath -Name $entry.Name -ErrorAction Stop
                }
                $script:Applied++
                continue
            }
            if ($entry.Type -eq 'Key') {
                # Value-less key creation (classic context menu override).
                if (-not (Test-Path -LiteralPath $keyPath)) {
                    New-Item -Path $keyPath -Force -ErrorAction Stop | Out-Null
                }
                $script:Applied++
                continue
            }
            if (-not (Test-Path -LiteralPath $keyPath)) {
                New-Item -Path $keyPath -Force -ErrorAction Stop | Out-Null
            }
            $kind = if ($entry.Type -eq 'DWord') { 'DWord' } else { 'String' }
            New-ItemProperty -LiteralPath $keyPath -Name $entry.Name -PropertyType $kind -Value $entry.Data -Force -ErrorAction Stop | Out-Null
            $script:Applied++
        }
        catch {
            $script:Failures++
            Write-GGLog ('Warning: ''' + $entry.Path + '\' + $entry.Name + ''' failed on ' + $Root + ': ' + $_.Exception.Message)
        }
    }
}

function Test-ServiceSid {
    param([string]$Sid)
    $profile = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.SID -eq $Sid } | Select-Object -First 1
    if ($profile -and $profile.Special) { return $true }
    # Service accounts that are not tracked by Win32_UserProfile (defence in
    # depth; the SID regex already excludes these).
    if ($Sid -match '^S-1-5-(18|19|20)$') { return $true }
    return $false
}

function Test-GGRegSuccess {
    # Invoke-GGCommand reports "completed within timeout", not the exit code.
    # reg.exe prints "The operation completed successfully." on success, so
    # validate from the captured output.
    param([bool]$Completed, [object[]]$Output)
    if (-not $Completed) { return $false }
    return [bool](@($Output) | Where-Object { $_ -match 'operation completed successfully' })
}

function Unload-GGHive {
    # reg unload can fail transiently while a handle is still open; retry with
    # a delay (community TryUnload pattern, re-expressed).
    param([string]$MountName)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $ok, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('unload', ('HKU\' + $MountName)) -TimeoutSeconds 30 -Description ('hive unload ' + $MountName)
        if (Test-GGRegSuccess $ok $out) { return $true }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 2
    }
    return $false
}

try {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}
catch {
    Write-GGLog ('Could not create backup directory ''' + $backupDir + ''': ' + $_.Exception.Message)
    exit 1
}

# ---------------------------------------------------------------------------
# Sweep 1: loaded interactive user hives
# ---------------------------------------------------------------------------
Write-GGLog 'Sweep 1: applying per-user settings to loaded interactive profile hives.'
$loadedSids = @()
try {
    $loadedSids = @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction Stop |
        Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' -and $_.PSChildName -notmatch '_Classes$' } |
        Select-Object -ExpandProperty PSChildName)
}
catch {
    Write-GGLog ('Could not enumerate loaded hives: ' + $_.Exception.Message)
}

foreach ($sid in $loadedSids) {
    if (-not (Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $sid + '\Volatile Environment'))) {
        # No interactive-profile marker: likely a disconnected or partial mount.
        Write-GGLog ('Skipping SID without an interactive profile marker: ' + $sid)
        continue
    }
    if (Test-ServiceSid $sid) {
        Write-GGLog ('Skipping service/special profile SID: ' + $sid)
        continue
    }
    Write-GGLog ('Processing loaded hive ' + $sid + '.')
    Backup-HiveKey ('HKU\' + $sid) $sid | Out-Null
    Apply-ToHive ('HKEY_USERS\' + $sid)
    $script:HivesTouched++
}

if ($loadedSids.Count -eq 0) {
    Write-GGLog 'No loaded interactive user SID hives were found.'
}

# ---------------------------------------------------------------------------
# Sweep 2: HKU\.DEFAULT (LocalSystem hive, logon-screen-visible values)
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath 'Registry::HKEY_USERS\.DEFAULT') {
    Write-GGLog 'Sweep 2: applying per-user settings to HKU\.DEFAULT (logon-screen values).'
    Backup-HiveKey 'HKU\.DEFAULT' 'DEFAULT-hive' | Out-Null
    Apply-ToHive 'HKEY_USERS\.DEFAULT' -Groups @('core')
    $script:HivesTouched++
}
else {
    Write-GGLog 'HKU\.DEFAULT was not available; logon-screen values were skipped.'
}

# ---------------------------------------------------------------------------
# Sweep 3: Default profile template (future users)
# ---------------------------------------------------------------------------
$defaultDat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
$ameMount = 'HKEY_USERS\AME_UserHive_Default'
$ggosMountName = 'GGOS_DefaultHive'
$hookTarget = $null   # template mount the RunOnce hook is written into

if (Test-Path -LiteralPath $defaultDat) {
    if (Test-Path -LiteralPath ('Registry::' + $ameMount)) {
        # AME Wizard loaded the Default template itself; reuse the mount and
        # never unload it (AME owns that lifecycle).
        Write-GGLog 'Sweep 3: reusing the existing AME_UserHive_Default mount for the Default template.'
        Backup-HiveKey 'HKU\AME_UserHive_Default' 'Default-template' | Out-Null
        Apply-ToHive $ameMount
        $hookTarget = $ameMount
        $script:HivesTouched++
    }
    else {
        # Clear a leftover mount from an earlier interrupted run.
        if (Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $ggosMountName)) {
            Write-GGLog ('Clearing a leftover ' + $ggosMountName + ' mount from an earlier run.')
            $cleared = Unload-GGHive $ggosMountName
            if (-not $cleared) {
                Write-GGLog ('Warning: leftover ' + $ggosMountName + ' mount could not be unloaded; Default template was skipped.')
            }
        }
        if (-not (Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $ggosMountName))) {
            $ok, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('load', ('HKU\' + $ggosMountName), $defaultDat) -TimeoutSeconds 60 -Description 'Default template hive load'
            if (-not (Test-GGRegSuccess $ok $out)) {
                Write-GGLog 'Warning: loading the Default profile hive failed; future users were not configured.'
            }
            else {
                try {
                    Write-GGLog 'Sweep 3: applying per-user settings to the Default template hive.'
                    Backup-HiveKey ('HKU\' + $ggosMountName) 'Default-template' | Out-Null
                    Apply-ToHive ('HKEY_USERS\' + $ggosMountName)
                    $hookTarget = 'HKEY_USERS\' + $ggosMountName
                    $script:HivesTouched++
                }
                finally {
                    Start-Sleep -Seconds 1
                    $unloaded = Unload-GGHive $ggosMountName
                    if (-not $unloaded) {
                        Write-GGLog 'ERROR: could not unload the Default template hive. A reboot clears the mount.'
                        $script:Failures++
                    }
                }
            }
        }
    }
}
else {
    Write-GGLog 'Default profile NTUSER.DAT was not found; future users were not configured.'
}

# ---------------------------------------------------------------------------
# B5: RunOnce first-logon hook into the Default template hive
# ---------------------------------------------------------------------------
if ($null -ne $hookTarget) {
    $hookDest = Join-Path $dataDir 'first-logon.ps1'
    $hookSrc = Join-Path $PSScriptRoot 'first-logon.ps1'
    $hookInstalled = $false
    if (Test-Path -LiteralPath $hookSrc) {
        try {
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
            Copy-Item -LiteralPath $hookSrc -Destination $hookDest -Force -ErrorAction Stop
            $hookInstalled = $true
        }
        catch {
            Write-GGLog ('Warning: could not stage first-logon.ps1 to ' + $hookDest + ': ' + $_.Exception.Message)
        }
    }
    else {
        Write-GGLog 'Warning: first-logon.ps1 was not found next to per-user.ps1; the RunOnce hook was skipped.'
    }
    if ($hookInstalled) {
        $runOnceKey = $hookTarget + '\Software\Microsoft\Windows\CurrentVersion\RunOnce'
        $hookCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + $hookDest
        $ok, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('add', $runOnceKey, '/v', 'GGOSFirstLogon', '/t', 'REG_SZ', '/d', $hookCmd, '/f') -TimeoutSeconds 30 -Description 'RunOnce first-logon hook write'
        if (Test-GGRegSuccess $ok $out) {
            Write-GGLog 'RunOnce first-logon hook written to the Default template hive.'
        }
        else {
            Write-GGLog 'Warning: the RunOnce first-logon hook could not be written.'
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-GGLog ('Hives processed: ' + $script:HivesTouched + '; values applied: ' + $script:Applied + '; failures: ' + $script:Failures + '.')
Write-GGLog ('Per-hive exports are in ' + $backupDir + '.')

if ($script:Failures -gt 0) {
    Write-GGLog 'Completed with warnings (failed values above).'
    exit 0
}

if ($script:HivesTouched -eq 0) {
    Write-GGLog 'No profile hives could be processed.'
    exit 1
}

exit 0
