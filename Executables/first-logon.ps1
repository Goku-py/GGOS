# GGOS first-logon tweaks (v0.2, spec B5).
# Runs at the first logon of a brand-new account via the RunOnce value that
# per-user.ps1 writes into the Default template hive. Applies only the
# cosmetic subset of the per-user values for the CURRENT user (HKCU), writes a
# done-marker, then removes its own RunOnce value. Idempotent: exits
# immediately (after clearing the hook) when the marker already exists.
# This script is self-contained on purpose: it is copied standalone to
# %SystemRoot%\GGOS\first-logon.ps1 at playbook run time and must not depend
# on the playbook directory or ggos-common.psm1.

$ErrorActionPreference = 'Continue'

function Write-GGLog {
    param([string]$Message)
    Write-Output ('GGOS: ' + $Message)
}

$markerKey = 'HKCU:\Software\GGOS\FirstLogon'
$runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$hookName = 'GGOSFirstLogon'

if (Test-Path -LiteralPath $markerKey) {
    # Already ran for this profile; make sure the hook value is gone and exit.
    Remove-ItemProperty -Path $runOncePath -Name $hookName -ErrorAction SilentlyContinue
    Write-GGLog 'first-logon tweaks already applied for this profile.'
    exit 0
}

# Cosmetic subset only (spec B5): classic context menu, taskbar End Task,
# This PC as Explorer default, ads off. Full tuning ran per-hive already.
$cosmetic = @(
    @{ Path = 'HKCU:\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32';            KeyOnly = $true },                                                                                                       # Classic full context menu (key only, Win11)
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings';    Name = 'TaskbarEndTask';              Type = 'DWord'; Data = 1 },                                                        # End Task in taskbar right-click
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                             Name = 'LaunchTo';                    Type = 'DWord'; Data = 1 },                                                        # Explorer opens at This PC
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo';                               Name = 'Enabled';                     Type = 'DWord'; Data = 0 },                                                        # Personalized ad ID off
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                        Name = 'SilentInstalledAppsEnabled';  Type = 'DWord'; Data = 0 },                                                        # Silent suggested-app installs off
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                        Name = 'SubscribedContent-338388Enabled'; Type = 'DWord'; Data = 0 },                                                    # Silent app installs off
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';                        Name = 'SubscribedContent-338389Enabled'; Type = 'DWord'; Data = 0 },                                                    # General tips off
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                             Name = 'ShowSyncProviderNotifications'; Type = 'DWord'; Data = 0 },                                                      # Explorer sync-provider ads off
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';                             Name = 'Start_IrisRecommendations';   Type = 'DWord'; Data = 0 }                                                         # Start menu recommendation ads off
)

$failures = 0
foreach ($item in $cosmetic) {
    try {
        if ($item.KeyOnly) {
            # Value-less key creation (classic context menu override).
            if (-not (Test-Path -LiteralPath $item.Path)) {
                New-Item -Path $item.Path -Force -ErrorAction Stop | Out-Null
            }
        }
        else {
            if (-not (Test-Path -LiteralPath $item.Path)) {
                New-Item -Path $item.Path -Force -ErrorAction Stop | Out-Null
            }
            New-ItemProperty -LiteralPath $item.Path -Name $item.Name -PropertyType $item.Type -Value $item.Data -Force -ErrorAction Stop | Out-Null
        }
    }
    catch {
        $failures++
        Write-GGLog ('Warning: cosmetic value failed on ' + $item.Path + ': ' + $_.Exception.Message)
    }
}

# Done-marker under HKCU\Software\GGOS\FirstLogon makes the script a no-op on
# any later invocation of the hook.
try {
    New-Item -Path $markerKey -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $markerKey -Name 'Applied' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
}
catch {
    Write-GGLog ('Warning: done-marker could not be written: ' + $_.Exception.Message)
}

# Delete our RunOnce value (Windows normally removes it before execution;
# this is the belt-and-braces path).
Remove-ItemProperty -Path $runOncePath -Name $hookName -ErrorAction SilentlyContinue

if ($failures -eq 0) {
    Write-GGLog 'first-logon tweaks applied'
}
else {
    Write-GGLog ('first-logon tweaks applied with warnings (' + $failures + ' values failed; see log above).')
}
exit 0
