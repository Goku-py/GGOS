# GGOS OneDrive removal (v0.5.0, feature-expansion track) - option onedrive-remove.
#
# Never deletes user files: the uninstaller removes only the application.
# Each user's synchronized folder %USERPROFILE%\OneDrive and everything in it
# is left exactly as it is, and files that were cloud-only remain in the
# cloud. Reinstall path (documented in Tasks/onedrive.yml and revert.yml):
#   winget install --id Microsoft.OneDrive --exact
#   (or the direct installer https://go.microsoft.com/fwlink/?linkid=860984,
#    both documented in the Microsoft Q&A article cited below)
#
# Procedure (documented): run the official uninstaller, then sweep leftovers.
#   - Uninstaller: %SystemRoot%\SysWOW64\OneDriveSetup.exe /uninstall (64-bit
#     Windows), falling back to %SystemRoot%\System32\OneDriveSetup.exe
#     /uninstall - the procedure Microsoft Q&A documents for OneDrive
#     removal ("How can I uninstall OneDrive?",
#     https://learn.microsoft.com/en-us/answers/questions/5001275/how-can-i-uninstall-onedrive)
#     alongside the Settings-app path ("Turn off, disable, or uninstall
#     OneDrive",
#     https://support.microsoft.com/en-us/onedrive/turn-off-disable-or-uninstall-onedrive).
#   - Autorun leftovers: the per-user HKCU Run value 'OneDrive'
#     (Software\Microsoft\Windows\CurrentVersion\Run), swept through the
#     shared per-user engine Apply-GGUserValues (loaded interactive hives +
#     HKU\.DEFAULT + the Default profile template, with per-hive reg.exe
#     export backups - the exact per-user.ps1 sweep pattern; a missing value
#     is a no-op).
#   - Scheduled-task leftovers: OneDrive registers per-SID update/reporting
#     tasks ('OneDrive Reporting Task-S-1-5-21-*',
#     'OneDrive Standalone Update Task-S-1-5-21-*' - community-documented
#     OneDrive behavior, e.g. Microsoft Q&A "OneDrive creates thousands of
#     scheduled reporting tasks"). Only tasks whose name starts with
#     'OneDrive' AND whose path is under \Microsoft\ are unregistered, so
#     user-created tasks are never matched.
# End-state stamp: HKLM\SOFTWARE\GGOS OneDrive = removed (written even when
# OneDrive was already absent - the end state 'not present on this PC' is
# what verification checks).
# Idempotent: every step is a no-op when its target is missing.
# All external calls go through Invoke-GGCommand (spec B2 bounded timeout;
# timeouts are appended to %SystemRoot%\GGOS\skipped.txt by the wrapper).

param()

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force

$reg = Join-Path $env:SystemRoot 'System32\reg.exe'
$dataDir = Join-Path $env:SystemRoot 'GGOS'

# ---------------------------------------------------------------------------
# 1. Official uninstaller (SysWOW64 first on 64-bit Windows, then System32)
# ---------------------------------------------------------------------------
$uninstaller = $null
foreach ($candidate in @(
    (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'),
    (Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe')
)) {
    if (Test-Path -LiteralPath $candidate) { $uninstaller = $candidate; break }
}

if ($uninstaller) {
    Write-GGLog ('Running the official OneDrive uninstaller: ' + $uninstaller)
    $ok, $exit, $out = Invoke-GGCommand -FilePath $uninstaller -ArgumentList @('/uninstall') -TimeoutSeconds 300 -Description 'OneDrive official uninstaller (/uninstall)'
    if ($ok -and $exit -eq 0) { Write-GGLog 'OneDrive uninstaller completed.' }
    elseif ($ok) { Write-GGLog ('Warning: the OneDrive uninstaller exited with code ' + $exit + ' (continuing with the leftover sweep).') }
    else { Write-GGLog 'Warning: the OneDrive uninstaller timed out (continuing with the leftover sweep - see skipped.txt).' }
}
else {
    Write-GGLog 'OneDriveSetup.exe was not found - OneDrive is not installed (or already removed).'
}

# ---------------------------------------------------------------------------
# 2. Per-user autorun leftover: HKCU Run value 'OneDrive' (triple sweep)
# ---------------------------------------------------------------------------
$OneDriveCleanup = @(
    @{ Op = 'del'; Path = 'Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'OneDrive'; Type = ''; Data = $null; Group = 'core' }
)

$result = Apply-GGUserValues -ValueTable $OneDriveCleanup -Groups @('core') -DefaultGroups @('core')
Write-GGLog ('OneDrive Run-key sweep: hives processed ' + $result.HivesTouched + '; values removed/confirmed ' + $result.Applied + '; failures ' + $result.Failures + '.')

# ---------------------------------------------------------------------------
# 3. Scheduled-task leftovers (per-SID OneDrive tasks under \Microsoft\)
# ---------------------------------------------------------------------------
try {
    $tasks = @(Get-ScheduledTask -ErrorAction Stop |
        Where-Object { $_.TaskName -like 'OneDrive*' -and $_.TaskPath -like '\Microsoft\*' })
    if ($tasks.Count -eq 0) {
        Write-GGLog 'No leftover OneDrive scheduled tasks found.'
    }
    foreach ($t in $tasks) {
        try {
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
            Write-GGLog ('Removed OneDrive scheduled task: ' + $t.TaskPath + $t.TaskName)
        }
        catch {
            Write-GGLog ('Warning: could not remove scheduled task ' + $t.TaskPath + $t.TaskName + ': ' + $_.Exception.Message)
        }
    }
}
catch {
    Write-GGLog ('Warning: scheduled-task enumeration failed: ' + $_.Exception.Message)
}

# ---------------------------------------------------------------------------
# 4. End-state stamp: HKLM\SOFTWARE\GGOS OneDrive = removed
# ---------------------------------------------------------------------------
$ok, $exit, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('add', 'HKLM\SOFTWARE\GGOS', '/v', 'OneDrive', '/t', 'REG_SZ', '/d', 'removed', '/f') -TimeoutSeconds 20 -Description 'HKLM\SOFTWARE\GGOS OneDrive stamp'
if (Test-GGRegSuccess $ok $exit $out) {
    Write-GGLog 'HKLM\SOFTWARE\GGOS stamped: OneDrive = removed.'
}
else {
    Write-GGLog 'Warning: the HKLM\SOFTWARE\GGOS OneDrive stamp could not be written.'
}

Write-GGLog 'OneDrive removal complete - user files were not touched; cloud files remain in OneDrive.'
exit 0
