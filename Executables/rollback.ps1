# GGOS rollback protection
# - Creates a System Restore point (enabling System Restore on the system drive if needed).
# - Verifies that a fresh restore point actually exists before reporting success.
# - Falls back to targeted registry exports if the restore point cannot be created.
# - Exits non-zero so the playbook halts when NO rollback method could be established.
#
# Contract (asserted by Tasks/rollback.yml via errorAction: Halt):
#   exit 0 = a rollback method exists (restore point, or complete registry exports)
#   exit 1 = no rollback method could be established -> the playbook must not continue
#
# Scope note: a System Restore point covers system files, drivers and the registry.
# It does NOT restore removed Appx/provisioned packages, deleted cleanup targets,
# winget-updated applications, or per-user hive values. Those are covered (where
# possible) by per-user.ps1 / input-tuning.ps1 hive exports and are documented as
# non-reversible in README.md.

$ErrorActionPreference = 'Stop'

$stamp         = Get-Date -Format 'yyyyMMdd-HHmmss'
$systemDrive   = $env:SystemDrive.TrimEnd('\')
$backupRoot    = Join-Path $systemDrive 'GGOS-backup'
$backupDir     = Join-Path $backupRoot $stamp
$dataDir       = Join-Path $env:SystemRoot 'GGOS'
$manifestPath  = Join-Path $dataDir 'rollback-manifest.txt'
$rpCreated     = $false

function Write-GGLog {
    param([string]$Message)
    Write-Output "GGOS rollback: $Message"
}

function Write-Manifest {
    # Best-effort audit trail; never fatal.
    param([string]$Line)
    try {
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
        Add-Content -LiteralPath $manifestPath -Value ('{0} {1}' -f (Get-Date -Format s), $Line) -ErrorAction Stop
    } catch { }
}

function Invoke-WithTimeout {
    # Bounded execution for cmdlets that can block for minutes (Checkpoint-Computer).
    # Returns: Completed (bool), Output (array), ErrorText (string).
    param([scriptblock]$Script, [int]$TimeoutSeconds = 300)
    $job = Start-Job -ScriptBlock $Script
    if (Wait-Job $job -Timeout $TimeoutSeconds) {
        $output  = @(Receive-Job $job -ErrorAction SilentlyContinue)
        $state   = [string]$job.State
        $errText = (@($job.ChildJobs[0].Error) | ForEach-Object { $_.ToString() }) -join '; '
        Remove-Job $job -Force
        return ($state -eq 'Completed' -and -not $errText), $output, $errText
    }
    Stop-Job $job
    Remove-Job $job -Force
    return $false, @(), ('timed out after {0}s' -f $TimeoutSeconds)
}

Write-Manifest ('BEGIN rollback protection (pid {0})' -f $PID)

# ---------------------------------------------------------------------------
# 1. Prepare System Restore and create the restore point
# ---------------------------------------------------------------------------
$freqPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$freqProp = $null
try {
    # The cmdlet documents the drive as "C:\"; passing "C:" is not guaranteed.
    Enable-ComputerRestore -Drive ($systemDrive + '\') -ErrorAction SilentlyContinue
} catch {
    Write-GGLog "System Restore could not be enabled: $($_.Exception.Message)"
}

try {
    # Allow immediate restore-point creation even if one was made <24h ago
    # (default SystemRestorePointCreationFrequency is 1440 minutes).
    $freqProp = Get-ItemProperty -Path $freqPath -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
    New-ItemProperty -Path $freqPath -Name SystemRestorePointCreationFrequency -Value 0 `
        -PropertyType DWord -Force -ErrorAction Stop | Out-Null

    foreach ($desc in @('GGOS pre-optimization', 'GGOS rollback point')) {
        # The description is a fixed literal from this array (no user input), so
        # building the job scriptblock as text is safe and avoids relying on
        # closure capture across the job boundary.
        $checkpoint = [scriptblock]::Create(
            "Checkpoint-Computer -Description '$desc' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop")
        $ok, $out, $err = Invoke-WithTimeout -Script $checkpoint -TimeoutSeconds 600
        if ($ok) { $rpCreated = $true; break }
        Write-GGLog ("Restore point attempt '{0}' failed: {1}" -f $desc, $err)
    }
} catch {
    Write-GGLog "Restore point preparation failed: $($_.Exception.Message)"
} finally {
    # Always put the original throttle value back.
    try {
        if ($null -ne $freqProp) {
            Set-ItemProperty -Path $freqPath -Name SystemRestorePointCreationFrequency `
                -Value $freqProp.SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
        } else {
            Remove-ItemProperty -Path $freqPath -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# 2. Verify a fresh restore point exists (best effort, read-only)
# ---------------------------------------------------------------------------
$verified = $false
$rpSequence = 'unknown'
if ($rpCreated) {
    try {
        $rp = Get-ComputerRestorePoint -ErrorAction Stop |
            Sort-Object -Property CreationTime -Descending |
            Select-Object -First 1
        if ($rp) {
            $rpSequence = [string]$rp.SequenceNumber
            $createdTime = $null
            try {
                $createdTime = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$rp.CreationTime)
            } catch {
                try { $createdTime = [datetime]::Parse([string]$rp.CreationTime) } catch { $createdTime = $null }
            }
            if ($createdTime -and ((Get-Date) - $createdTime).TotalMinutes -le 15) {
                $verified = $true
                Write-GGLog ("Restore point verified: sequence {0}, created {1}." -f $rpSequence, $createdTime)
            } else {
                Write-GGLog 'Checkpoint-Computer reported success but no restore point from this run was found - treating it as unverified.'
            }
        } else {
            Write-GGLog 'Restore-point list was empty after Checkpoint-Computer - treating it as unverified.'
        }
    } catch {
        # Some SKUs/builds cannot enumerate restore points; trust the cmdlet result
        # but say so explicitly instead of claiming verification.
        $verified = $true
        Write-GGLog "Restore point created, but verification was not possible: $($_.Exception.Message)"
    }
}

if ($verified) {
    Write-Manifest ("RESULT restore-point sequence={0} verified={1}" -f $rpSequence, $verified)
    Write-GGLog 'Restore point created.'
    exit 0
}

# ---------------------------------------------------------------------------
# 3. Fallback: targeted registry exports
# ---------------------------------------------------------------------------
Write-Manifest 'RESULT restore-point unavailable - falling back to registry exports'
Write-GGLog 'Restore point unavailable - falling back to registry exports.'
try {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
} catch {
    Write-GGLog "Could not create backup directory: $($_.Exception.Message)"
    Write-Manifest ('RESULT FAILED backup directory: {0}' -f $_.Exception.Message)
    exit 1
}

# Target only the machine surfaces GGOS actually writes. Exporting all of HKLM
# produces a multi-gigabyte file that is impractical to import and can stall the run.
# HKCU is deliberately not exported: this script runs elevated (trustedInstaller),
# so HKCU is not the interactive user's hive. Per-user hives are exported by
# per-user.ps1 / input-tuning.ps1 before they are modified.
$exports = @(
    @{ RegPath = 'HKLM\SOFTWARE';                  File = 'HKLM-SOFTWARE.reg';          Timeout = 900  },
    @{ RegPath = 'HKLM\SYSTEM\CurrentControlSet'; File = 'HKLM-SYSTEM-CurrentSet.reg'; Timeout = 900  }
)

$failed = 0
foreach ($item in $exports) {
    $file = Join-Path $backupDir $item.File
    $exportScript = [scriptblock]::Create(
        "& reg.exe export '{0}' '{1}' /y | Out-Null; exit `$LASTEXITCODE" -f $item.RegPath, ($file -replace "'", "''"))
    $ok, $out, $err = Invoke-WithTimeout -Script $exportScript -TimeoutSeconds $item.Timeout
    if ($ok -and (Test-Path -LiteralPath $file)) {
        Write-GGLog ("Exported {0} -> {1}" -f $item.RegPath, $file)
        Write-Manifest ("EXPORT {0} -> {1}" -f $item.RegPath, $file)
    } else {
        $failed++
        Write-GGLog ("Export failed for {0}: {1}" -f $item.RegPath, $err)
        Write-Manifest ("EXPORT FAILED {0}: {1}" -f $item.RegPath, $err)
    }
}

if ($failed -gt 0) {
    Write-GGLog 'No complete rollback method available - halting playbook.'
    Write-Manifest 'RESULT FAILED - no complete rollback method'
    exit 1
}

Write-GGLog "Registry exports completed at $backupDir (exports are NOT a full system restore)."
Write-Manifest ('RESULT registry-exports backupDir={0}' -f $backupDir)
exit 0
