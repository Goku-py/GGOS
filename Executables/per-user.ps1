# GGOS per-user tweaks (v0.3, spec V03-B) - triple sweep (spec B1) + first-logon hook (B5).
# The sweep machinery (hive enumeration, per-hive backups, value application,
# template hive load/unload with AME_UserHive_Default reuse) lives in the shared
# engine Apply-GGUserValues in ggos-common.psm1; this script owns the value
# table and the B5 RunOnce hook.
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
$dataDir = Join-Path $env:SystemRoot 'GGOS'

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

# ---------------------------------------------------------------------------
# Apply the full value set through the shared per-user engine in
# ggos-common (Apply-GGUserValues): the triple sweep (loaded interactive
# hives with the 'Volatile Environment' marker and special-profile
# exclusion, HKU\.DEFAULT with the core-only subset, and the Default
# template hive with AME_UserHive_Default reuse / reg load + unload retry),
# the per-hive reg export backups and the bounded-timeout reg.exe calls all
# live there now. This script keeps the value table above and the B5
# first-logon hook below.
# ---------------------------------------------------------------------------
$result = Apply-GGUserValues -ValueTable $UserValues -Groups @('core', 'office') -DefaultGroups @('core')

# ---------------------------------------------------------------------------
# B5: RunOnce first-logon hook into the Default template hive
# ---------------------------------------------------------------------------
$hookTarget = $result.TemplateMount
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
        $ok, $exit, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('add', $runOnceKey, '/v', 'GGOSFirstLogon', '/t', 'REG_SZ', '/d', $hookCmd, '/f') -TimeoutSeconds 30 -Description 'RunOnce first-logon hook write'
        if (Test-GGRegSuccess $ok $exit $out) {
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
Write-GGLog ('Hives processed: ' + $result.HivesTouched + '; values applied: ' + $result.Applied + '; failures: ' + $result.Failures + '.')
Write-GGLog ('Per-hive exports are in ' + $result.BackupDir + '.')

if ($result.Failures -gt 0) {
    Write-GGLog 'Completed with warnings (failed values above).'
    exit 0
}

if ($result.HivesTouched -eq 0) {
    Write-GGLog 'No profile hives could be processed.'
    exit 1
}

exit 0
