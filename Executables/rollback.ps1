# GGOS rollback protection
# - Creates a System Restore point (enabling System Restore on the system drive if needed).
# - Falls back to HKLM/HKCU registry exports if the restore point cannot be created.
# - Exits non-zero so the playbook halts when NO rollback method could be established.

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $env:SystemDrive \"GGOS-backup\$stamp\"

function Write-GGLog {
    param([string]$Message)
    Write-Output "GGOS rollback: $Message"
}

# 1. Prepare System Restore
try {
    Enable-ComputerRestore -Drive $env:SystemDrive -ErrorAction SilentlyContinue
    # Allow immediate restore point creation (default 1440-minute throttle)
    $freqPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $freqProp = Get-ItemProperty -Path $freqPath -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
    New-ItemProperty -Path $freqPath -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null

    $rpCreated = $false
    foreach ($desc in @('GGOS pre-optimization', 'GGOS rollback point')) {
        try {
            Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            $rpCreated = $true
            break
        } catch { $rpCreated = $false }
    }

    if ($null -ne $freqProp) {
        Set-ItemProperty -Path $freqPath -Name SystemRestorePointCreationFrequency -Value $freqProp.SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
    } else {
        Remove-ItemProperty -Path $freqPath -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
    }
} catch {
    Write-GGLog "Restore point preparation failed: $($_.Exception.Message)"
    $rp = $null
}

if ($rpCreated) {
    Write-GGLog 'Restore point created.'
    exit 0
}

# 2. Fallback: registry exports
Write-GGLog 'Restore point unavailable - falling back to registry exports.'
try {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
} catch {
    Write-GGLog "Could not create backup directory: $($_.Exception.Message)"
    exit 1
}

$failed = $false
reg.exe export HKLM (Join-Path $backupDir 'HKLM-export.reg') /y *> $null
if ($LASTEXITCODE -ne 0) { $failed = $true; Write-GGLog 'HKLM export failed.' } else { Write-GGLog 'HKLM exported.' }

reg.exe export HKCU (Join-Path $backupDir 'HKCU-export.reg') /y *> $null
if ($LASTEXITCODE -ne 0) { $failed = $true; Write-GGLog 'HKCU export failed.' } else { Write-GGLog 'HKCU exported.' }

if ($failed) {
    Write-GGLog 'No complete rollback method available - halting playbook.'
    exit 1
}

Write-GGLog "Registry exports completed at $backupDir (exports are NOT a full system restore)."
exit 0
