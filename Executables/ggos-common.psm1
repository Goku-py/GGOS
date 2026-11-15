# GGOS shared PowerShell helpers (v0.2, spec B2).
# Imported by the GGOS Executables scripts:
#   Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force
# Semantics re-expressed from community playbook structure (FSOS-X hardening
# phase model, reference only) - no upstream code copied.

function Write-GGLog {
    param([string]$Message)
    Write-Output ('GGOS: ' + $Message)
}

# B2 bounded-timeout wrapper. Runs an external command inside a job with a hard
# timeout. On success returns ($true, outputLines); on timeout the job is
# stopped, the item is appended to %SystemRoot%\GGOS\skipped.txt, and
# ($false, @()) is returned. Every reg.exe / schtasks / sc / DISM / powercfg
# call in GGOS scripts must go through this wrapper.
function Invoke-GGCommand {
    param([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSeconds = 20, [string]$Description)
    $job = Start-Job -ScriptBlock { param($fp, $al) & $fp @al 2>&1 } -ArgumentList $FilePath, $ArgumentList
    if (Wait-Job $job -Timeout $TimeoutSeconds) {
        $out = @(Receive-Job $job); Remove-Job $job -Force
        return $true, $out
    }
    Stop-Job $job; Remove-Job $job -Force
    $dir = Join-Path $env:SystemRoot 'GGOS'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Add-Content -Path (Join-Path $dir 'skipped.txt') -Value ('{0} SKIPPED(timeout {1}s): {2}' -f (Get-Date -Format s), $TimeoutSeconds, $Description)
    return $false, @()
}

# ---------------------------------------------------------------------------
# Per-user apply engine (spec V03-B). The former per-user.ps1 triple sweep,
# re-expressed as a reusable function so other scripts (e.g. input-tuning.ps1)
# can apply a small per-user value table through the identical machinery.
#
# Sweep targets, in order:
#   1. Every loaded interactive user hive under HKU: SIDs matching
#      S-1-5-21-<domain>-<a>-<b>-<rid> that carry a 'Volatile Environment'
#      subkey (community-validated interactive-profile marker). _Classes
#      subkeys, service accounts (S-1-5-18/19/20) and virtual accounts
#      (S-1-5-96-*) are excluded by the SID pattern; special profiles are
#      additionally skipped via Win32_UserProfile.
#   2. HKU\.DEFAULT (LocalSystem hive) - receives $DefaultGroups only.
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
# Value table entries: hashtables with Op ('set'|'del'), Path (hive-root
# relative), Name, Type ('DWord'|'String'|'Key'), Data, Group. Group must be
# present in $Groups (live hives + template) or $DefaultGroups (.DEFAULT).
# Returns a result object with HivesTouched, Applied, Failures, TemplateMount
# (the template mount path for post-apply hooks such as the B5 RunOnce
# write, or $null) and BackupDir. Logging is done through Write-GGPrefixLog
# so the caller controls the prefix: 'GGOS' (per-user.ps1) reproduces the
# original per-user output exactly; 'GGOS input' (input-tuning.ps1) brands
# the same sweep for the input-tuning log. Invoke-GGCommand itself is
# untouched (spec B2 contract).
# ---------------------------------------------------------------------------

$script:GGRegExe = Join-Path $env:SystemRoot 'System32\reg.exe'

function Write-GGPrefixLog {
    # Internal: scoped log line so engine callers can brand the output. The
    # exported Write-GGLog keeps its fixed 'GGOS:' prefix contract.
    param([string]$Prefix, [string]$Message)
    Write-Output ($Prefix + ': ' + $Message)
}

function Test-GGRegSuccess {
    # Invoke-GGCommand reports "completed within timeout", not the exit code.
    # reg.exe prints "The operation completed successfully." on success, so
    # validate from the captured output.
    param([bool]$Completed, [object[]]$Output)
    if (-not $Completed) { return $false }
    return [bool](@($Output) | Where-Object { $_ -match 'operation completed successfully' })
}

function Test-GGServiceSid {
    param([string]$Sid)
    $profile = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.SID -eq $Sid } | Select-Object -First 1
    if ($profile -and $profile.Special) { return $true }
    # Service accounts that are not tracked by Win32_UserProfile (defence in
    # depth; the SID regex already excludes these).
    if ($Sid -match '^S-1-5-(18|19|20)$') { return $true }
    return $false
}

function Backup-GGHiveKey {
    param([string]$RegKey, [string]$HiveName, [string]$BackupDir, [string]$Stamp, [string]$Prefix)
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    $file = Join-Path $BackupDir ('{0}-{1}.reg' -f $HiveName, $Stamp)
    # reg.exe writes the .reg file itself (UTF-16 LE BOM is reg.exe's own
    # format); the output is never re-encoded.
    # Invoke-GGCommand reports "completed within timeout", not the exit code,
    # so success is confirmed by the export file existing.
    $ok, $out = Invoke-GGCommand -FilePath $script:GGRegExe -ArgumentList @('export', $RegKey, $file, '/y') -TimeoutSeconds 60 -Description ('hive export ' + $RegKey)
    if ($ok -and (Test-Path -LiteralPath $file)) {
        Write-GGPrefixLog $Prefix ('Exported ' + $RegKey + ' to ' + $file + '.')
        return $true
    }
    Write-GGPrefixLog $Prefix ('Warning: export of ' + $RegKey + ' failed (continuing without that backup).')
    return $false
}

function Apply-GGEntriesToHive {
    # Applies one value table to one hive root (Registry::HKEY_USERS\<target>
    # style). Ops: 'set' writes the value, 'del' removes it; Type 'Key'
    # creates a value-less key. Failures are logged per entry and counted in
    # $Stats; they never abort the sweep.
    param([string]$Root, [object[]]$Table, [string[]]$Groups, [hashtable]$Stats, [string]$Prefix)
    foreach ($entry in $Table) {
        if ($entry.Group -notin $Groups) { continue }
        try {
            $keyPath = 'Registry::' + $Root + '\' + $entry.Path
            if ($entry.Op -eq 'del') {
                if (Test-Path -LiteralPath $keyPath) {
                    Remove-ItemProperty -LiteralPath $keyPath -Name $entry.Name -ErrorAction Stop
                }
                $Stats.Applied++
                continue
            }
            if ($entry.Type -eq 'Key') {
                # Value-less key creation (classic context menu override).
                if (-not (Test-Path -LiteralPath $keyPath)) {
                    New-Item -Path $keyPath -Force -ErrorAction Stop | Out-Null
                }
                $Stats.Applied++
                continue
            }
            if (-not (Test-Path -LiteralPath $keyPath)) {
                New-Item -Path $keyPath -Force -ErrorAction Stop | Out-Null
            }
            $kind = if ($entry.Type -eq 'DWord') { 'DWord' } else { 'String' }
            New-ItemProperty -LiteralPath $keyPath -Name $entry.Name -PropertyType $kind -Value $entry.Data -Force -ErrorAction Stop | Out-Null
            $Stats.Applied++
        }
        catch {
            $Stats.Failures++
            Write-GGPrefixLog $Prefix ('Warning: ''' + $entry.Path + '\' + $entry.Name + ''' failed on ' + $Root + ': ' + $_.Exception.Message)
        }
    }
}

function Unload-GGHive {
    # reg unload can fail transiently while a handle is still open; retry with
    # a delay (community TryUnload pattern, re-expressed).
    param([string]$MountName)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $ok, $out = Invoke-GGCommand -FilePath $script:GGRegExe -ArgumentList @('unload', ('HKU\' + $MountName)) -TimeoutSeconds 30 -Description ('hive unload ' + $MountName)
        if (Test-GGRegSuccess -Completed $ok -Output $out) { return $true }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 2
    }
    return $false
}

function Apply-GGUserValues {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ValueTable,
        # Groups applied to live user hives and the Default template.
        [string[]]$Groups = @('core'),
        # Groups applied to HKU\.DEFAULT (the logon-screen-relevant subset).
        [string[]]$DefaultGroups = @('core'),
        # Scope flags (all sweeps run unless skipped).
        [switch]$SkipLoadedUsers,
        [switch]$SkipDefault,
        [switch]$SkipTemplate,
        # Log prefix, e.g. 'GGOS' (per-user.ps1) or 'GGOS input' (input-tuning.ps1).
        [string]$LogPrefix = 'GGOS'
    )

    $ErrorActionPreference = 'Stop'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dataDir = Join-Path $env:SystemRoot 'GGOS'
    $backupDir = Join-Path $dataDir 'hive-backups'

    $stats = @{ Applied = 0; Failures = 0; HivesTouched = 0 }
    $templateMount = $null

    try {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    catch {
        Write-GGPrefixLog $LogPrefix ('Could not create backup directory ''' + $backupDir + ''': ' + $_.Exception.Message)
        return [pscustomobject]@{ HivesTouched = 0; Applied = 0; Failures = 1; TemplateMount = $null; BackupDir = $backupDir }
    }

    # -----------------------------------------------------------------------
    # Sweep 1: loaded interactive user hives
    # -----------------------------------------------------------------------
    if (-not $SkipLoadedUsers) {
        Write-GGPrefixLog $LogPrefix 'Sweep 1: applying per-user settings to loaded interactive profile hives.'
        $loadedSids = @()
        try {
            $loadedSids = @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction Stop |
                Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' -and $_.PSChildName -notmatch '_Classes$' } |
                Select-Object -ExpandProperty PSChildName)
        }
        catch {
            Write-GGPrefixLog $LogPrefix ('Could not enumerate loaded hives: ' + $_.Exception.Message)
        }

        foreach ($sid in $loadedSids) {
            if (-not (Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $sid + '\Volatile Environment'))) {
                # No interactive-profile marker: likely a disconnected or partial mount.
                Write-GGPrefixLog $LogPrefix ('Skipping SID without an interactive profile marker: ' + $sid)
                continue
            }
            if (Test-GGServiceSid $sid) {
                Write-GGPrefixLog $LogPrefix ('Skipping service/special profile SID: ' + $sid)
                continue
            }
            Write-GGPrefixLog $LogPrefix ('Processing loaded hive ' + $sid + '.')
            Backup-GGHiveKey -RegKey ('HKU\' + $sid) -HiveName $sid -BackupDir $backupDir -Stamp $stamp -Prefix $LogPrefix | Out-Null
            Apply-GGEntriesToHive -Root ('HKEY_USERS\' + $sid) -Table $ValueTable -Groups $Groups -Stats $stats -Prefix $LogPrefix
            $stats.HivesTouched++
        }

        if ($loadedSids.Count -eq 0) {
            Write-GGPrefixLog $LogPrefix 'No loaded interactive user SID hives were found.'
        }
    }

    # -----------------------------------------------------------------------
    # Sweep 2: HKU\.DEFAULT (LocalSystem hive, logon-screen-visible values)
    # -----------------------------------------------------------------------
    if (-not $SkipDefault) {
        if (Test-Path -LiteralPath 'Registry::HKEY_USERS\.DEFAULT') {
            Write-GGPrefixLog $LogPrefix 'Sweep 2: applying per-user settings to HKU\.DEFAULT (logon-screen values).'
            Backup-GGHiveKey -RegKey 'HKU\.DEFAULT' -HiveName 'DEFAULT-hive' -BackupDir $backupDir -Stamp $stamp -Prefix $LogPrefix | Out-Null
            Apply-GGEntriesToHive -Root 'HKEY_USERS\.DEFAULT' -Table $ValueTable -Groups $DefaultGroups -Stats $stats -Prefix $LogPrefix
            $stats.HivesTouched++
        }
        else {
            Write-GGPrefixLog $LogPrefix 'HKU\.DEFAULT was not available; logon-screen values were skipped.'
        }
    }

    # -----------------------------------------------------------------------
    # Sweep 3: Default profile template (future users)
    # -----------------------------------------------------------------------
    if (-not $SkipTemplate) {
        $defaultDat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
        $ameMount = 'HKEY_USERS\AME_UserHive_Default'
        $ggosMountName = 'GGOS_DefaultHive'

        if (Test-Path -LiteralPath $defaultDat) {
            if (Test-Path -LiteralPath ('Registry::' + $ameMount)) {
                # AME Wizard loaded the Default template itself; reuse the mount and
                # never unload it (AME owns that lifecycle).
                Write-GGPrefixLog $LogPrefix 'Sweep 3: reusing the existing AME_UserHive_Default mount for the Default template.'
                Backup-GGHiveKey -RegKey 'HKU\AME_UserHive_Default' -HiveName 'Default-template' -BackupDir $backupDir -Stamp $stamp -Prefix $LogPrefix | Out-Null
                Apply-GGEntriesToHive -Root $ameMount -Table $ValueTable -Groups $Groups -Stats $stats -Prefix $LogPrefix
                $templateMount = $ameMount
                $stats.HivesTouched++
            }
            else {
                # Clear a leftover mount from an earlier interrupted run.
                if (Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $ggosMountName)) {
                    Write-GGPrefixLog $LogPrefix ('Clearing a leftover ' + $ggosMountName + ' mount from an earlier run.')
                    $cleared = Unload-GGHive $ggosMountName
                    if (-not $cleared) {
                        Write-GGPrefixLog $LogPrefix ('Warning: leftover ' + $ggosMountName + ' mount could not be unloaded; Default template was skipped.')
                    }
                }
                if (-not (Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $ggosMountName))) {
                    $ok, $out = Invoke-GGCommand -FilePath $script:GGRegExe -ArgumentList @('load', ('HKU\' + $ggosMountName), $defaultDat) -TimeoutSeconds 60 -Description 'Default template hive load'
                    if (-not (Test-GGRegSuccess -Completed $ok -Output $out)) {
                        Write-GGPrefixLog $LogPrefix 'Warning: loading the Default profile hive failed; future users were not configured.'
                    }
                    else {
                        try {
                            Write-GGPrefixLog $LogPrefix 'Sweep 3: applying per-user settings to the Default template hive.'
                            Backup-GGHiveKey -RegKey ('HKU\' + $ggosMountName) -HiveName 'Default-template' -BackupDir $backupDir -Stamp $stamp -Prefix $LogPrefix | Out-Null
                            Apply-GGEntriesToHive -Root ('HKEY_USERS\' + $ggosMountName) -Table $ValueTable -Groups $Groups -Stats $stats -Prefix $LogPrefix
                            $templateMount = 'HKEY_USERS\' + $ggosMountName
                            $stats.HivesTouched++
                        }
                        finally {
                            Start-Sleep -Seconds 1
                            $unloaded = Unload-GGHive $ggosMountName
                            if (-not $unloaded) {
                                Write-GGPrefixLog $LogPrefix 'ERROR: could not unload the Default template hive. A reboot clears the mount.'
                                $stats.Failures++
                            }
                        }
                    }
                }
            }
        }
        else {
            Write-GGPrefixLog $LogPrefix 'Default profile NTUSER.DAT was not found; future users were not configured.'
        }
    }

    return [pscustomobject]@{
        HivesTouched  = $stats.HivesTouched
        Applied       = $stats.Applied
        Failures      = $stats.Failures
        TemplateMount = $templateMount
        BackupDir     = $backupDir
    }
}

Export-ModuleMember -Function @('Write-GGLog', 'Invoke-GGCommand', 'Apply-GGUserValues', 'Test-GGRegSuccess')
