# GGOS input tuning - v0.1 (mode-based, spec V03-B)
#
# Modes (each gated by its own playbook option):
#   accel - Disable mouse acceleration ("Enhance pointer precision") per user:
#           MouseSpeed / MouseThreshold1 / MouseThreshold2 = 0 under
#           'Control Panel\Mouse' (REG_SZ - the native type Windows keeps for
#           these values). Applied through the shared Apply-GGUserValues
#           engine in ggos-common.psm1 to the same triple sweep per-user.ps1
#           uses: loaded interactive user hives, HKU\.DEFAULT, and the Default
#           profile template hive (accel subset only, NOT the full cosmetic
#           set). Per-hive results and per-hive reg export backups are logged.
#   queue - Machine-level input buffer latency: MouseDataQueueSize and
#           KeyboardDataQueueSize = 8 (REG_DWORD) under the mouclass /
#           kbdclass driver Parameters keys, creating the Parameters key if
#           absent.
#
#           HONEST ASSESSMENT: Community-contested tweak (xbitlabs: placebo
#           or real?); value 8 is within the community-validated floor of
#           ~8-16; lower values (<3) are known to drop inputs. Previous
#           values (or ABSENT) are recorded to
#           HKLM\SOFTWARE\GGOS\HardwarePolicy\Undo\InputQueue.
#
# Log prefix: 'GGOS input:'. All external calls go through ggos-common
# Invoke-GGCommand (bounded timeouts; timeouts land in skipped.txt), and
# reg.exe success is validated from its own output (Test-GGRegSuccess).

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('accel', 'queue')]
    [string]$Mode
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force

function Write-GGLog {
    param([string]$Message)
    Write-Output ('GGOS input: ' + $Message)
}

$undoRoot = 'HKLM:\SOFTWARE\GGOS\HardwarePolicy\Undo'

function Save-UndoValue {
    param([string]$Area, [string]$Name, [string]$Value)
    $key = Join-Path $undoRoot $Area
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

switch ($Mode) {

    'accel' {
        # Per-user mouse acceleration off. REG_SZ values (the native format on
        # the Control Panel\Mouse key); the engine maps Type 'String' to
        # New-ItemProperty -PropertyType String (REG_SZ). Group 'core' so the
        # subset applies to every sweep target including HKU\.DEFAULT.
        $accelValues = @(
            @{ Op = 'set'; Path = 'Control Panel\Mouse'; Name = 'MouseSpeed';      Type = 'String'; Data = '0'; Group = 'core' },
            @{ Op = 'set'; Path = 'Control Panel\Mouse'; Name = 'MouseThreshold1'; Type = 'String'; Data = '0'; Group = 'core' },
            @{ Op = 'set'; Path = 'Control Panel\Mouse'; Name = 'MouseThreshold2'; Type = 'String'; Data = '0'; Group = 'core' }
        )
        $result = Apply-GGUserValues -ValueTable $accelValues -Groups @('core') -DefaultGroups @('core') -LogPrefix 'GGOS input'
        Write-GGLog ('Hives processed: ' + $result.HivesTouched + '; values applied: ' + $result.Applied + '; failures: ' + $result.Failures + '.')
        Write-GGLog ('Per-hive exports are in ' + $result.BackupDir + '.')
        if ($result.Failures -gt 0) {
            Write-GGLog 'Completed with warnings (failed values above).'
        }
        elseif ($result.HivesTouched -eq 0) {
            Write-GGLog 'No profile hives could be processed.'
            exit 1
        }
    }

    'queue' {
        $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
        $targets = @(
            @{ Key = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'; RegPath = 'HKLM\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'; ValueName = 'MouseDataQueueSize';     Desc = 'mouse data queue size' },
            @{ Key = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; RegPath = 'HKLM\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; ValueName = 'KeyboardDataQueueSize'; Desc = 'keyboard data queue size' }
        )
        foreach ($target in $targets) {
            # Record the previous value (or ABSENT) for the revert path before
            # anything is changed.
            $previous = 'ABSENT'
            $existing = Get-ItemProperty -Path $target.Key -Name $target.ValueName -ErrorAction SilentlyContinue
            if ($null -ne $existing -and $null -ne $existing.($target.ValueName)) {
                $previous = [string]$existing.($target.ValueName)
            }
            Save-UndoValue -Area 'InputQueue' -Name $target.ValueName -Value $previous
            # Create the Parameters key if it is absent, then set the value.
            if (-not (Test-Path -LiteralPath $target.Key)) {
                $ok, $ggOut = Invoke-GGCommand -FilePath $reg -ArgumentList @('add', $target.RegPath, '/f') -TimeoutSeconds 30 -Description ('create ' + $target.RegPath)
                if (-not (Test-GGRegSuccess -Completed $ok -Output $ggOut)) {
                    Write-GGLog ('Warning: could not create ' + $target.RegPath + '; ' + $target.Desc + ' was skipped.')
                    continue
                }
            }
            $ok, $ggOut = Invoke-GGCommand -FilePath $reg -ArgumentList @('add', $target.RegPath, '/v', $target.ValueName, '/t', 'REG_DWORD', '/d', '8', '/f') -TimeoutSeconds 30 -Description ('set ' + $target.Desc + ' = 8')
            if (Test-GGRegSuccess -Completed $ok -Output $ggOut) {
                Write-GGLog ($target.Desc + ' = 8 (was ' + $previous + ').')
            }
            else {
                Write-GGLog ('Warning: setting ' + $target.Desc + ' failed (was ' + $previous + '; undo recorded).')
            }
        }
    }
}

exit 0
