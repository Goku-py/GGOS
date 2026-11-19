# GGOS GPU shader cache cleanup (v0.6.0) - always applied, no wizard option.
#
# Enumerates ONLY documented GPU shader cache locations under each loaded
# interactive user profile. Existence-checked: only directories that already
# exist are touched. With -Clean, ONLY FILES inside those cache directories
# are deleted - the directories themselves are kept, subdirectories are kept,
# and nothing outside the listed roots is ever touched. Without -Clean the
# script is a dry run: it reports per-path file counts and sizes and deletes
# nothing. The Recycle Bin, Office auto-recover data and iTunes backups are
# not on the path list by construction (repo safety rules).
#
# Documented locations (relative to a user profile root):
#   NVIDIA (driver shader caches):
#     AppData\Local\NVIDIA\DXCache                    - DirectX shader cache
#     AppData\Local\NVIDIA\GLCache                    - OpenGL shader cache
#     AppData\Local\NVIDIA Corporation\NV_Cache        - NVIDIA App / GeForce
#                                                       Experience shader cache
#     AppData\LocalLow\NVIDIA\PerDriverVersion\DXCache - recent NVIDIA drivers
#                                                       moved DXCache here
#   AMD (Radeon shader caches):
#     AppData\Local\AMD\DxCache                      - DirectX shader cache
#     AppData\Local\AMD\Dx9Cache                     - DirectX 9 shader cache
#   Windows:
#     AppData\Local\D3DSCache                        - Windows Direct3D shader
#                                                       cache
# Path conventions cross-checked against published driver-cache cleanup
# references ("How to clear NVIDIA and DirectX cache", Gaijin support;
# DXCache/GLCache/D3DSCache path tables published by disk-cleanup guides).
# A convention that has moved on some driver version is simply a no-op here
# (existence check), and driver-locked files are counted as failed, never
# retried destructively.
#
# Profiles are resolved from the loaded interactive hives (S-1-5-21-* SIDs
# carrying the 'Volatile Environment' marker - the same enumeration discipline
# as the shared per-user engine in ggos-common.psm1) via each hive's
# USERPROFILE value, so the caches of every signed-in user (including the
# wizard's own user) are covered. HKU\.DEFAULT and service profiles are
# deliberately skipped: their caches belong to system accounts and are not
# trivially safe to sweep.
# Every path is processed in its own try/catch; failures are logged and the
# run continues. Results are logged per path to
# %SystemRoot%\GGOS\ggos-shaderclean.txt in both modes (CLEAN or DRY-RUN).
# The script always exits 0.

param(
    [switch]$Clean
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force

$dataDir = Join-Path $env:SystemRoot 'GGOS'
$logFile = Join-Path $dataDir 'ggos-shaderclean.txt'

# Documented cache paths, relative to a user profile root (see header).
$CachePaths = @(
    'AppData\Local\NVIDIA\DXCache',
    'AppData\Local\NVIDIA\GLCache',
    'AppData\Local\NVIDIA Corporation\NV_Cache',
    'AppData\LocalLow\NVIDIA\PerDriverVersion\DXCache',
    'AppData\Local\AMD\DxCache',
    'AppData\Local\AMD\Dx9Cache',
    'AppData\Local\D3DSCache'
)

try { New-Item -ItemType Directory -Path $dataDir -Force -ErrorAction Stop | Out-Null }
catch { Write-GGLog ('Warning: could not create ' + $dataDir + ': ' + $_.Exception.Message) }

$script:Log = New-Object System.Collections.Generic.List[string]
$script:TotalDeleted = 0
$script:TotalFailed = 0

function Add-CacheLogLine {
    param([string]$Line)
    $script:Log.Add($Line)
    Write-GGLog $Line
}

# ---------------------------------------------------------------------------
# Resolve the loaded interactive user profiles (same marker discipline as the
# shared per-user engine).
# ---------------------------------------------------------------------------
$profiles = @()
try {
    $loadedSids = @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction Stop |
        Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' -and $_.PSChildName -notmatch '_Classes$' } |
        Select-Object -ExpandProperty PSChildName)
    foreach ($sid in $loadedSids) {
        $profileRoot = $null
        try {
            $ve = Get-ItemProperty -LiteralPath ('Registry::HKEY_USERS\' + $sid + '\Volatile Environment') -ErrorAction Stop
            $profileRoot = [string]$ve.USERPROFILE
        }
        catch { continue }
        if (-not $profileRoot -or -not (Test-Path -LiteralPath $profileRoot)) { continue }
        $profiles += [pscustomobject]@{ Sid = $sid; Root = $profileRoot }
    }
}
catch {
    Add-CacheLogLine ('WARNING: could not enumerate loaded user hives: ' + $_.Exception.Message)
}

if ($profiles.Count -eq 0) {
    Add-CacheLogLine 'No loaded interactive user profiles found - nothing to do.'
}

# ---------------------------------------------------------------------------
# Sweep every documented cache path per profile
# ---------------------------------------------------------------------------
$mode = 'DRY-RUN'
if ($Clean) { $mode = 'CLEAN' }
Add-CacheLogLine ('--- GPU shader cache ' + $mode + ' - ' + (Get-Date -Format s) + ' ---')

foreach ($p in $profiles) {
    foreach ($rel in $CachePaths) {
        $dir = Join-Path $p.Root $rel
        # Existence check: only touch directories that exist on this machine.
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        try {
            $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction Stop)
            $sum = 0
            if ($files.Count -gt 0) { $sum = [int64](($files | Measure-Object -Property Length -Sum).Sum) }
            if ($Clean) {
                $deleted = 0
                $failed = 0
                foreach ($f in $files) {
                    # Files only - the cache directory itself is never removed
                    # and nothing outside $dir is ever enumerated.
                    try {
                        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                        $deleted++
                    }
                    catch {
                        $failed++
                    }
                }
                $script:TotalDeleted += $deleted
                $script:TotalFailed += $failed
                Add-CacheLogLine ('CLEAN    {0}: deleted {1} file(s) ({2} bytes); {3} file(s) locked or failed' -f $dir, $deleted, $sum, $failed)
            }
            else {
                Add-CacheLogLine ('DRY-RUN  {0}: {1} file(s), {2} bytes (nothing deleted - run with -Clean to delete)' -f $dir, $files.Count, $sum)
            }
        }
        catch {
            Add-CacheLogLine ('WARNING  {0}: could not enumerate: {1}' -f $dir, $_.Exception.Message)
        }
    }
}

if ($Clean) {
    Add-CacheLogLine ('Shader cache clean complete: {0} file(s) deleted, {1} locked or failed.' -f $script:TotalDeleted, $script:TotalFailed)
}
else {
    Add-CacheLogLine 'Shader cache dry-run complete - no files were deleted.'
}

# ---------------------------------------------------------------------------
# Write the log file
# ---------------------------------------------------------------------------
try {
    Set-Content -LiteralPath $logFile -Value $script:Log -ErrorAction Stop
    Write-GGLog ('Shader cache log written to ' + $logFile)
}
catch {
    Write-GGLog ('Warning: the shader cache log could not be written: ' + $_.Exception.Message)
}

# Always exit 0 - a locked or missing cache directory must not fail the run.
exit 0
