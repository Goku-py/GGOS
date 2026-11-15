# GGOS disk cleanup
# Ported from TBOK's BeardSweeper cleanup routine (reference only, re-expressed; no
# upstream code or comments copied).
#
# SAFE section (cleanup option): caches, temp files and logs only.
# AGGRESSIVE section (cleanup-aggressive option, -Aggressive switch): Windows Search
# index reset, Disk Cleanup with update/component-store handlers, SoftwareDistribution
# cache removal, previous Windows installation folders.
#
# Hard guarantees:
#   - The Recycle Bin is NEVER emptied by this script.
#   - DISM /ResetBase is NOT run by any wired task (-ResetBase exists but is not
#     referenced from any task file; it permanently removes update-uninstall data).
#   - Office auto-recover/unsaved-work locations are never cleaned.
#   - iTunes mobile-device backups are never cleaned.

param(
    [switch]$Aggressive,
    [switch]$SkipSafe,
    [switch]$ResetBase
)

$ErrorActionPreference = 'Continue'

function Write-GGLog {
    param([string]$Message)
    Write-Output "GGOS cleanup: $Message"
}

function Get-FreeBytes {
    param([string]$Drive)
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $Drive + "'") -ErrorAction Stop
        return [double]$d.FreeSpace
    }
    catch { return $null }
}

function Remove-Tree {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-GGLog "Removed: $Path"
    }
    catch {
        # Locked or permission-restricted items are tolerated; remaining files stay.
        Write-GGLog "Warning: could not fully remove ${Path}: $($_.Exception.Message)"
    }
}

function Remove-Items {
    param([string]$Path, [string]$Filter = '*')
    $full = Join-Path $Path $Filter
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Get-ChildItem -LiteralPath $Path -ErrorAction Stop | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-GGLog "Cleaned: $full"
    }
    catch {
        Write-GGLog "Warning: could not clean ${Path}: $($_.Exception.Message)"
    }
}

function Stop-ServiceForCleanup {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return 'absent' }
    if ($svc.Status -ne 'Running') { return 'not-running' }
    try {
        Stop-Service -Name $Name -Force -ErrorAction Stop
        return 'stopped'
    }
    catch {
        Write-GGLog "Warning: service $Name could not be stopped; locked files may remain."
        return 'not-running'
    }
}

function Restore-ServiceAfterCleanup {
    param([string]$Name, [string]$State)
    if ($State -ne 'stopped') { return }
    try {
        Start-Service -Name $Name -ErrorAction Stop
        Write-GGLog "Restarted service $Name."
    }
    catch {
        Write-GGLog "Warning: service $Name was running before cleanup but could not be restarted."
    }
}

$systemDrive = $env:SystemDrive
$freeBefore = Get-FreeBytes $systemDrive

# ---------------------------------------------------------------------------
# SAFE SECTION
# ---------------------------------------------------------------------------
if (-not $SkipSafe) {
    Write-GGLog 'Starting safe cleanup (caches, temp files, logs only).'

    # Remove orphaned Appx installer leftovers (built-in Appx deployment helper).
    & rundll32.exe AppxDeploymentClient.dll,AppxCleanupOrphanPackages 2>&1 | Out-Null

    # Stuck spooler print jobs (print-queue files only, not user documents).
    $spooler = Stop-ServiceForCleanup 'Spooler'
    Remove-Items (Join-Path $env:SystemRoot 'System32\spool\printers')
    Restore-ServiceAfterCleanup 'Spooler' $spooler

    # Windows font cache.
    $fontCache = Stop-ServiceForCleanup 'FontCache'
    Remove-Items (Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Local\FontCache')
    Restore-ServiceAfterCleanup 'FontCache' $fontCache

    # Windows temp and kernel crash-report files.
    Remove-Items (Join-Path $env:SystemRoot 'Temp')
    Remove-Items (Join-Path $env:SystemRoot 'LiveKernelReports') '*.dmp'
    Remove-Items (Join-Path $env:SystemRoot 'appcompat\backuptest')
    # Prefetch is intentionally NOT cleared: wiping it slows the next boots while
    # it is rebuilt, and it undoes the prefetch policy set by the memory tweak.

    # Windows log folders (netsetup, setup/ servicing, DISM, update and USO logs).
    $logRoot = Join-Path $env:SystemRoot 'Logs'
    foreach ($folder in @('NetSetup', 'SIH', 'CBS', 'WindowsUpdate', 'DISM', 'MeasuredBoot')) {
        Remove-Items (Join-Path $logRoot $folder)
    }
    Remove-Items $logRoot '*.LOG'
    Remove-Items (Join-Path $env:SystemRoot 'SoftwareDistribution\DataStore\Logs')
    Remove-Item -LiteralPath (Join-Path $env:SystemRoot 'runSW.log') -Force -ErrorAction SilentlyContinue
    Remove-Items (Join-Path $env:ProgramData 'USOshared\Logs\User')
    # Delivery Optimization log files.
    Remove-Items (Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Logs')
    # The SRU database (System32\sru) is intentionally NOT deleted: it backs Task
    # Manager app history and the network data-usage graph.

    # Per-user caches and temp files.
    foreach ($profileDir in (Get-ChildItem (Join-Path $systemDrive 'Users') -Directory -ErrorAction SilentlyContinue)) {
        $u = $profileDir.FullName
        Remove-Items (Join-Path $u 'AppData\Local\Temp')
        Remove-Items (Join-Path $u 'AppData\Local\Microsoft\Explorer\ThumbCacheToDelete')
        Remove-Items (Join-Path $u 'AppData\Local\Microsoft\explorer\thumbcache')
        Remove-Items (Join-Path $u 'AppData\Local\CrashDumps')
        Remove-Items (Join-Path $u 'AppData\LocalLow\Microsoft\CryptnetUrlCache\Content')
        Remove-Items (Join-Path $u 'AppData\Roaming\Microsoft\Teams\Service Worker\CacheStorage')
        Remove-Items (Join-Path $u 'AppData\Local\Microsoft\Terminal Server Client\Cache')
        Remove-Items (Join-Path $u 'AppData\Roaming\Microsoft\Windows\WebCache')
        Remove-Items (Join-Path $u 'AppData\Local\Microsoft\Windows\INetCache')
        Remove-Items (Join-Path $u 'AppData\Local\Microsoft\Windows\Temporary Internet Files')
        # OfficeFileCache, Word/Excel roaming folders and OneNote cache are
        # intentionally NOT cleaned: they can hold edits waiting to upload or
        # auto-recover files.
        # Snipping Tool recordings/snips are user captures and are NOT cleaned.

        # Teams (classic + new) caches.
        $teamsCache = Join-Path $u 'AppData\Roaming\Microsoft\Teams'
        foreach ($folder in @('blob_storage', 'cache', 'databases', 'gpucache', 'tmp')) {
            Remove-Items (Join-Path $teamsCache $folder)
        }
        # indexeddb and Local Storage are skipped (may hold app state).

        # Outlook caches.
        Remove-Tree (Join-Path $u 'AppData\Local\Microsoft\Outlook\RoamCache')
        Remove-Tree (Join-Path $u 'AppData\Local\Microsoft\Windows\INetCache\Content.Outlook')

        # OneDrive caches (logs/temp/telemetry only; synced files are never touched).
        $od = Join-Path $u 'AppData\Local\Microsoft\OneDrive'
        foreach ($folder in @('logs', 'temp', 'Telemetry')) {
            Remove-Items (Join-Path $od $folder)
        }
        Remove-Items (Join-Path $u 'AppData\Local\OneDrive\Cache\qmlcache')

        # Apple installer/firmware caches (installers and iOS firmware only;
        # mobile-device backups are never removed).
        Remove-Tree (Join-Path $env:ProgramData 'Apple Inc\Installer Cache')
        Remove-Tree (Join-Path $env:ProgramData 'Apple Computer\Installer Cache')
        Remove-Tree (Join-Path $u 'AppData\Roaming\Apple Computer\iTunes\iPhone Software Updates')
        Remove-Tree (Join-Path $u 'AppData\Roaming\Apple Computer\iTunes\iPod Software Updates')

        # Browser caches: Chrome, Edge, Firefox (locked files are left in place;
        # running browsers are not terminated).
        $chromeData = Join-Path $u 'AppData\Local\Google\Chrome\User Data'
        if (Test-Path -LiteralPath $chromeData) {
            foreach ($profilePath in @(Get-ChildItem $chromeData -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
                $p = $profilePath.FullName
                foreach ($folder in @('Cache\Cache_Data', 'Code Cache\js', 'Code Cache\wasm', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache', 'GPUCache')) {
                    Remove-Items (Join-Path $p $folder)
                }
            }
            foreach ($folder in @('extensions_crx_cache', 'component_crx_cache', 'GrShaderCache', 'ShaderCache')) {
                Remove-Items (Join-Path $chromeData $folder)
            }
        }

        $edgeData = Join-Path $u 'AppData\Local\Microsoft\Edge\User Data'
        if (Test-Path -LiteralPath $edgeData) {
            foreach ($profilePath in @(Get-ChildItem $edgeData -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
                $p = $profilePath.FullName
                foreach ($folder in @('Cache\Cache_Data', 'Code Cache\js', 'Code Cache\wasm', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache', 'GPUCache', 'Media Cache', 'Crashpad', 'OptimizationGuidePredictionModels')) {
                    Remove-Items (Join-Path $p $folder)
                }
            }
            foreach ($folder in @('extensions_crx_cache', 'BrowserMetrics', 'component_crx_cache', 'GrShaderCache', 'ShaderCache')) {
                Remove-Items (Join-Path $edgeData $folder)
            }
        }

        $ffRoot = Join-Path $u 'AppData\Local\Mozilla\Firefox\Profiles'
        if (Test-Path -LiteralPath $ffRoot) {
            foreach ($ffProfile in (Get-ChildItem $ffRoot -Directory -ErrorAction SilentlyContinue)) {
                Remove-Items (Join-Path $ffProfile.FullName 'cache2\entries')
                Remove-Items (Join-Path $ffProfile.FullName 'startupCache')
            }
        }
    }

    Write-GGLog 'Safe cleanup finished.'
}

# ---------------------------------------------------------------------------
# AGGRESSIVE SECTION
# ---------------------------------------------------------------------------
if ($Aggressive) {
    Write-GGLog 'Starting aggressive cleanup (opt-in).'

    # ---- Windows Search index reset ----
    $searchSvc = Get-Service -Name WSearch -ErrorAction SilentlyContinue
    if ($searchSvc) {
        $searchWas = $searchSvc.StartType
        try {
            Set-Service -Name WSearch -StartupType Disabled -ErrorAction Stop
            if ($searchSvc.Status -eq 'Running') { Stop-Service -Name WSearch -Force -ErrorAction Stop }
            # Flag the index for rebuild and clear the existing search database.
            New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name SetupCompletedSuccessfully -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Items (Join-Path $env:ProgramData 'Microsoft\Search\Data\Applications\Windows')
            # Restore the previous startup type (GGOS never disables WSearch permanently).
            if ($searchWas -eq 'Disabled') { Set-Service -Name WSearch -StartupType Disabled }
            else { Set-Service -Name WSearch -StartupType AutomaticDelayedStart }
            Write-GGLog 'Windows Search index reset - results will be limited while it rebuilds.'
        }
        catch {
            Write-GGLog "Warning: Windows Search reset failed: $($_.Exception.Message)"
            try { Set-Service -Name WSearch -StartupType $searchWas -ErrorAction SilentlyContinue } catch { }
        }
    }

    # ---- Windows Update cache removal ----
    $updateServices = @('wuauserv', 'BITS', 'CryptSvc')
    $states = @{ }
    foreach ($name in $updateServices) { $states[$name] = Stop-ServiceForCleanup $name }
    Remove-Items (Join-Path $env:ALLUSERSPROFILE 'Application Data\Microsoft\Network\Downloader')
    Remove-Tree (Join-Path $env:SystemRoot 'SoftwareDistribution\Download')
    Remove-Tree (Join-Path $env:SystemRoot 'system32\catroot2')
    foreach ($name in $updateServices) { Restore-ServiceAfterCleanup $name $states[$name] }
    # AppIDSvc is intentionally not stopped or disabled (security rule).
    # $PatchCache$ is intentionally kept (preserves MSI update rollback).

    # ---- Disk Cleanup (safe handlers; Recycle Bin explicitly excluded) ----
    $flags = 'StateFlags0069'
    $handlers = @(
        'Active Setup Temp Folders', 'BranchCache', 'Content Indexer Cleaner',
        'Delivery Optimization Files', 'Diagnostic Data Viewer database Files',
        'D3D Shader Cache', 'Downloaded Program Files', 'Internet Cache Files',
        'Language Pack', 'Offline Pages Files', 'Old ChkDsk Files',
        'RetailDemo Offline Content', 'ServicePack Cleanup', 'Setup Log Files',
        'System error memory dump files', 'System error minidump files',
        'Temporary Files', 'Thumbnail Cache', 'Windows Defender',
        'Windows Error Reporting Files', 'Windows Upgrade Log Files'
    )
    foreach ($handler in $handlers) {
        & reg.exe add ("HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\" + $handler) /v $flags /t REG_DWORD /d 2 /f 2>&1 | Out-Null
    }
    # Remove any Recycle Bin flag from earlier versions so cleanmgr never empties it.
    & reg.exe delete ("HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Recycle Bin") /v $flags /f 2>&1 | Out-Null
    Write-GGLog 'Running Disk Cleanup (this can take a while).'
    $cleanmgr = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cleanmgr.exe') -ArgumentList '/sagerun:69' -PassThru
    try {
        Wait-Process -Id $cleanmgr.Id -Timeout 1800 -ErrorAction Stop
        Write-GGLog 'Disk Cleanup completed.'
    }
    catch {
        if (-not $cleanmgr.HasExited) { Stop-Process -Id $cleanmgr.Id -Force -ErrorAction SilentlyContinue }
        Write-GGLog 'Warning: Disk Cleanup exceeded 30 minutes and was terminated.'
    }
    foreach ($handler in $handlers) {
        & reg.exe delete ("HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\" + $handler) /v $flags /f 2>&1 | Out-Null
    }

    # ---- Component store cleanup ----
    $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    if ($ResetBase) {
        # Only reachable by explicitly invoking this script with -ResetBase;
        # no task file passes it. /ResetBase makes installed updates uninstallable.
        $dismArgs += '/ResetBase'
        Write-GGLog 'Component store cleanup WITH /ResetBase (updates cannot be uninstalled afterwards).'
    }
    else {
        Write-GGLog 'Running component store cleanup without /ResetBase (updates stay uninstallable).'
    }
    $dism = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\Dism.exe') -ArgumentList $dismArgs -PassThru
    try {
        Wait-Process -Id $dism.Id -Timeout 1800 -ErrorAction Stop
        if ($dism.ExitCode -eq 0) { Write-GGLog 'Component store cleanup completed.' }
        else { Write-GGLog "Warning: component store cleanup returned exit code $($dism.ExitCode)." }
    }
    catch {
        if (-not $dism.HasExited) { Stop-Process -Id $dism.Id -Force -ErrorAction SilentlyContinue }
        Write-GGLog 'Warning: component store cleanup exceeded 30 minutes and was terminated.'
    }

    # ---- Previous Windows installation folders ----
    # Removing these means the PC can no longer roll back to the previous install.
    foreach ($legacy in @('Windows.old', '$Windows.~BT', '$Windows.~WS')) {
        $legacyPath = Join-Path $systemDrive $legacy
        if (Test-Path -LiteralPath $legacyPath) {
            Write-GGLog "Removing previous Windows installation folder: $legacyPath"
            & takeown.exe /F $legacyPath /A /R /D Y 2>&1 | Out-Null
            & icacls.exe $legacyPath /grant '*S-1-5-32-544:F' /T /C /Q 2>&1 | Out-Null
            Remove-Tree $legacyPath
        }
    }

    # Recycle Bin: deliberately NOT touched at any aggressiveness level.
    # Restore points / shadow copies: deliberately NOT deleted.

    Write-GGLog 'Aggressive cleanup finished.'
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$freeAfter = Get-FreeBytes $systemDrive
if ($null -ne $freeBefore -and $null -ne $freeAfter) {
    $saved = [math]::Round(($freeAfter - $freeBefore) / 1GB, 2)
    Write-GGLog ("Disk space recovered: {0} GB (free now {1} GB)." -f $saved, [math]::Round($freeAfter / 1GB, 2))
}
else {
    Write-GGLog 'Disk-space totals could not be compared.'
}

exit 0
