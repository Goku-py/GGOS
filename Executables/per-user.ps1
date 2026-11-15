# GGOS per-user tweaks
# Applies per-user registry settings to:
#   1. every loaded user profile hive (via HKU), and
#   2. the Default profile hive (future users), mounted temporarily.
# Special/service profiles are skipped. Each touched hive is exported first to a
# GGOS-backup directory. Hives are always unloaded in a finally block.
# Semantics ported from TBOK's per-user ApplySettings routine (reference only,
# re-expressed; no upstream code or comments copied).

param(
    [string]$BackupRoot = (Join-Path $env:SystemDrive 'GGOS-backup')
)

$ErrorActionPreference = 'Stop'

function Write-GGLog {
    param([string]$Message)
    Write-Output "GGOS per-user: $Message"
}

# ---------------------------------------------------------------------------
# Per-user value set. Paths are relative to the target hive root.
# Ops: 'set' writes the value, 'del' removes it (TBOK deletes PeriodInNanoSeconds).
# ---------------------------------------------------------------------------
$UserValues = @(
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                       Name = 'LaunchTo';                              Type = 'DWord';  Data = 1 },                # Explorer opens at This PC
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications';           Name = 'GlobalUserDisabled';                    Type = 'DWord';  Data = 1 },                # Store apps: no background execution
    @{ Op = 'set'; Path = 'Software\Microsoft\GameBar';                                                       Name = 'AutoGameModeEnabled';                   Type = 'DWord';  Data = 1 },                # Game Mode always on
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; Name = 'TaskbarEndTask';                     Type = 'DWord';  Data = 1 },                # End Task in taskbar right-click
    @{ Op = 'set'; Path = 'SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32';      Name = '';                                      Type = 'Key';    Data = $null },            # Classic full context menu (key only, Win11)
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Search';                                 Name = 'BingSearchEnabled';                     Type = 'DWord';  Data = 0 },                # Local start-menu search only
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'Start_Layout';                          Type = 'DWord';  Data = 1 },                # Start menu: more pins, less waste
    @{ Op = 'set'; Path = 'Control Panel\Desktop';                                                            Name = 'MenuShowDelay';                         Type = 'String'; Data = '10' },             # Menu delay 400ms -> 10ms
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects';                 Name = 'VisualFXSetting';                       Type = 'DWord';  Data = 3 },                # Visual effects: custom
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'TaskbarAnimations';                     Type = 'DWord';  Data = 0 },                # Taskbar animations off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'TaskbarAI';                             Type = 'DWord';  Data = 0 },                # Copilot icon off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'ShowCopilotButton';                     Type = 'DWord';  Data = 0 },                # Copilot icon off (second key)
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'ListviewAlphaSelect';                   Type = 'DWord';  Data = 1 },                # Selection rectangle alpha on
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'ListviewShadow';                        Type = 'DWord';  Data = 1 },                # Icon shadows on
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'TaskbarMn';                             Type = 'DWord';  Data = 0 },                # People/chat band off
    @{ Op = 'set'; Path = 'Control Panel\Desktop';                                                            Name = 'DragFullWindows';                       Type = 'String'; Data = '1' },              # Show window contents while dragging
    @{ Op = 'set'; Path = 'Control Panel\Desktop\WindowMetrics';                                              Name = 'MinAnimate';                            Type = 'String'; Data = '0' },              # Minimize/restore animation off
    @{ Op = 'set'; Path = 'Control Panel\Keyboard';                                                           Name = 'KeyboardDelay';                         Type = 'String'; Data = '0' },              # Keyboard repeat delay short
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\DWM';                                                   Name = 'EnableAeroPeek';                        Type = 'DWord';  Data = 0 },                # Aero Peek off
    @{ Op = 'set'; Path = 'Software\Policies\Microsoft\Windows\Explorer';                                     Name = 'DisableSearchBoxSuggestions';           Type = 'DWord';  Data = 1 },                # Search box suggestions off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'ShowSyncProviderNotifications';         Type = 'DWord';  Data = 0 },                # Explorer sync-provider ads off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'Start_AccountNotifications';            Type = 'DWord';  Data = 0 },                # Start menu account notifications off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement';                  Name = 'ScoobeSystemSettingEnabled';            Type = 'DWord';  Data = 0 },                # "Finish setting up" prompts off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'RotatingLockScreenOverlayEnabled';      Type = 'DWord';  Data = 0 },                # Lock screen tips/ads off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo';                        Name = 'Enabled';                               Type = 'DWord';  Data = 0 },                # Personalized ad ID off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-310093Enabled';       Type = 'DWord';  Data = 0 },                # Welcome experience off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-338387Enabled';       Type = 'DWord';  Data = 0 },                # Settings suggestions off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-353694Enabled';       Type = 'DWord';  Data = 0 },                # Suggestions off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-353696Enabled';       Type = 'DWord';  Data = 0 },                # Suggestions off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SystemPaneSuggestionsEnabled';          Type = 'DWord';  Data = 0 },                # Start menu suggestions off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-338388Enabled';       Type = 'DWord';  Data = 0 },                # Silent app installs off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-338389Enabled';       Type = 'DWord';  Data = 0 },                # General tips off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-338393Enabled';       Type = 'DWord';  Data = 0 },                # Home screen suggestions off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SubscribedContent-353698Enabled';       Type = 'DWord';  Data = 0 },                # Timeline suggestions off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'SilentInstalledAppsEnabled';            Type = 'DWord';  Data = 0 },                # Silent suggested-app installs off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'ContentDeliveryAllowed';                Type = 'DWord';  Data = 0 },                # Content delivery off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'OemPreInstalledAppsEnabled';            Type = 'DWord';  Data = 0 },                # OEM app auto-enable off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'PreInstalledAppsEnabled';               Type = 'DWord';  Data = 0 },                # Preinstalled app auto-enable off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                 Name = 'PreInstalledAppsEverEnabled';           Type = 'DWord';  Data = 0 },                # Preinstalled app re-enable off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Siuf\Rules';                                                    Name = 'NumberOfSIUFInPeriod';                  Type = 'DWord';  Data = 0 },                # Feedback request frequency 0
    @{ Op = 'del'; Path = 'SOFTWARE\Microsoft\Siuf\Rules';                                                    Name = 'PeriodInNanoSeconds';                   Type = '';       Data = $null },            # Stale feedback timer removed
    @{ Op = 'set'; Path = 'SOFTWARE\Policies\Microsoft\Windows\CloudContent';                                 Name = 'DisableTailoredExperiencesWithDiagnosticData'; Type = 'DWord'; Data = 1 },           # Tailored experiences off
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager';        Name = 'EnthusiastMode';                        Type = 'DWord';  Data = 1 },                # Show more file-operation detail
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'Start_IrisRecommendations';             Type = 'DWord';  Data = 0 },                # Start menu recommendation ads off
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Privacy';                                Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Type = 'DWord'; Data = 0 },           # Tailored experiences off (settings key)
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                      Name = 'ShowTaskViewButton';                    Type = 'DWord';  Data = 0 },                # Task View button hidden
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People';               Name = 'PeopleBand';                            Type = 'DWord';  Data = 0 },                # People band hidden
    @{ Op = 'set'; Path = 'Control Panel\Desktop';                                                            Name = 'AutoEndTasks';                          Type = 'String'; Data = '0' },              # Apps may prompt to save at sign-out
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';                      Name = 'HideSCAMeetNow';                        Type = 'DWord';  Data = 1 },                # Meet Now icon hidden
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\Search';                                 Name = 'SearchboxTaskbarMode';                  Type = 'DWord';  Data = 1 },                # Search box: icon only
    @{ Op = 'set'; Path = 'Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration';        Name = 'IsResumeAllowed';                       Type = 'DWord';  Data = 0 },                # Cross-device resume off
    @{ Op = 'set'; Path = 'Software\Policies\Microsoft\Windows\WindowsCopilot';                               Name = 'TurnOffWindowsCopilot';                 Type = 'DWord';  Data = 1 },                # Copilot off (per-user policy)
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsCopilot';                         Name = 'AllowCopilotRuntime';                   Type = 'DWord';  Data = 0 },                # Copilot runtime off
    # Office logging / telemetry (versions 15.0 and 16.0)
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\15.0\Outlook\Options\Mail';                              Name = 'EnableLogging';                         Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\15.0\Outlook\Options\Calendar';                          Name = 'EnableCalendarLogging';                 Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\15.0\Word\Options';                                      Name = 'EnableLogging';                         Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Policies\Microsoft\Office\15.0\OSM';                                      Name = 'EnableLogging';                         Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Policies\Microsoft\Office\15.0\OSM';                                      Name = 'EnableUpload';                          Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\15.0\Common';                                            Name = 'QMEnable';                              Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\15.0\Common\Feedback';                                   Name = 'Enabled';                               Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Outlook\Options\Mail';                              Name = 'EnableLogging';                         Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Outlook\Options\Calendar';                          Name = 'EnableCalendarLogging';                 Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Word\Options';                                      Name = 'EnableLogging';                         Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Policies\Microsoft\Office\16.0\OSM';                                      Name = 'EnableLogging';                         Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Policies\Microsoft\Office\16.0\OSM';                                      Name = 'EnableUpload';                          Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Common';                                            Name = 'QMEnable';                              Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Common\Feedback';                                   Name = 'Enabled';                               Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\Common\ClientTelemetry';                                 Name = 'DisableTelemetry';                      Type = 'DWord';  Data = 1 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry';                            Name = 'DisableTelemetry';                      Type = 'DWord';  Data = 1 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\Common\ClientTelemetry';                                 Name = 'VerboseLogging';                        Type = 'DWord';  Data = 0 },
    @{ Op = 'set'; Path = 'SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry';                            Name = 'VerboseLogging';                        Type = 'DWord';  Data = 0 }
)

# Accessibility (StickyKeys) is deliberately not changed.
# Explorer Bags/BagMRU reset is deliberately not performed (upstream is opt-in only).

$script:Failures = 0
$script:Applied  = 0
$script:HivesTouched = 0

function Backup-Hive {
    param([string]$HiveKey, [string]$FileName)
    $target = Join-Path $backupDir $FileName
    & reg.exe export $HiveKey $target /y 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-GGLog "Warning: export of $HiveKey to $FileName failed (continuing without that backup)."
        return $false
    }
    Write-GGLog "Exported $HiveKey to $FileName."
    return $true
}

function Apply-ToHive {
    param([string]$Root)
    foreach ($entry in $UserValues) {
        try {
            if ($entry.Op -eq 'del') {
                $keyPath = "Registry::$Root\$($entry.Path)"
                if (Test-Path -LiteralPath $keyPath) {
                    Remove-ItemProperty -LiteralPath $keyPath -Name $entry.Name -ErrorAction Stop
                }
                $script:Applied++
                continue
            }
            if ($entry.Type -eq 'Key') {
                # Value-less key creation (classic context menu override).
                $keyPath = "Registry::$Root\$($entry.Path)"
                if (-not (Test-Path -LiteralPath $keyPath)) {
                    New-Item -Path $keyPath -Force -ErrorAction Stop | Out-Null
                }
                $script:Applied++
                continue
            }
            $keyPath = "Registry::$Root\$($entry.Path)"
            if (-not (Test-Path -LiteralPath $keyPath)) {
                New-Item -Path $keyPath -Force -ErrorAction Stop | Out-Null
            }
            $kind = if ($entry.Type -eq 'DWord') { 'DWord' } else { 'String' }
            New-ItemProperty -LiteralPath $keyPath -Name $entry.Name -PropertyType $kind -Value $entry.Data -Force -ErrorAction Stop | Out-Null
            $script:Applied++
        }
        catch {
            $script:Failures++
            Write-GGLog "Warning: '$($entry.Path)\$($entry.Name)' failed on ${Root}: $($_.Exception.Message)"
        }
    }
}

function Test-ServiceSid {
    param([string]$Sid)
    $profile = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.SID -eq $Sid } | Select-Object -First 1
    if ($profile -and $profile.Special) { return $true }
    # Service accounts that are not tracked by Win32_UserProfile.
    if ($Sid -match '^S-1-5-(18|19|20)$') { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# 1. Backup directory
# ---------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $BackupRoot "per-user-$stamp"
try {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}
catch {
    Write-GGLog "Could not create backup directory '$backupDir': $($_.Exception.Message)"
    exit 1
}

if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
}

# ---------------------------------------------------------------------------
# 2. Loaded user hives
# ---------------------------------------------------------------------------
Write-GGLog 'Applying per-user settings to loaded profile hives.'
$loadedSids = @()
try {
    $loadedSids = @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction Stop |
        Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-' -and $_.PSChildName -notmatch '_Classes$' } |
        Select-Object -ExpandProperty PSChildName)
}
catch {
    Write-GGLog "Could not enumerate loaded hives: $($_.Exception.Message)"
}

foreach ($sid in $loadedSids) {
    if (Test-ServiceSid $sid) {
        Write-GGLog "Skipping service/special profile SID: $sid"
        continue
    }
    Write-GGLog "Processing loaded hive $sid."
    Backup-Hive "HKU\$sid" "$sid-export.reg" | Out-Null
    Apply-ToHive "HKEY_USERS\$sid"
    $script:HivesTouched++
}

if ($loadedSids.Count -eq 0) {
    Write-GGLog 'No loaded user SID hives were found.'
}

# ---------------------------------------------------------------------------
# 3. Default profile hive (future users)
# ---------------------------------------------------------------------------
$defaultDat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
if (Test-Path -LiteralPath $defaultDat) {
    $mountPath = 'Registry::HKEY_USERS\GGOSDefaultHive'
    $mount = 'HKU\GGOSDefaultHive'
    # Clear a leftover mount from an earlier interrupted run.
    if (Get-Item -LiteralPath $mountPath -ErrorAction SilentlyContinue) {
        & reg.exe unload $mount 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-GGLog 'Warning: could not unload a previously mounted GGOSDefaultHive; Default profile was skipped.'
        }
    }
    if (-not (Get-Item -LiteralPath $mountPath -ErrorAction SilentlyContinue)) {
        & reg.exe load $mount $defaultDat 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-GGLog 'Warning: loading the Default profile hive failed; future users were not configured.'
        }
        else {
            try {
                Backup-Hive $mount 'Default-NTUSER-export.reg' | Out-Null
                Write-GGLog 'Processing Default profile hive.'
                Apply-ToHive 'HKEY_USERS\GGOSDefaultHive'
                $script:HivesTouched++
            }
            finally {
                & reg.exe unload $mount 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-GGLog 'ERROR: could not unload the Default profile hive. A reboot clears the mount.'
                    $script:Failures++
                }
            }
        }
    }
}
else {
    Write-GGLog 'Default profile NTUSER.DAT was not found; future users were not configured.'
}

# ---------------------------------------------------------------------------
# 4. Summary
# ---------------------------------------------------------------------------
Write-GGLog "Hives processed: $script:HivesTouched; values applied: $script:Applied; failures: $script:Failures."
Write-GGLog "Per-hive exports are in $backupDir."

if ($script:Failures -gt 0) {
    Write-GGLog 'Completed with warnings (failed values above).'
    exit 0
}

if ($script:HivesTouched -eq 0) {
    Write-GGLog 'No profile hives could be processed.'
    exit 1
}

exit 0
