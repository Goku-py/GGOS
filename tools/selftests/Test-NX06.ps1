#Requires -Version 5.1
<#
    Test-NX06.ps1 - NX06 (Storage & Filesystem) category self-test.

    SAFETY BOUNDARY (directive Section 16): every write in this test goes to a
    throwaway temp directory. Windows is touched only through READ-ONLY paths:
    fsutil behavior query, Get-PhysicalDisk/Get-Disk/Get-Volume,
    Get-StorageReliabilityCounter, Get-StorageAdvancedProperty, Get-ScheduledTask /
    Export-ScheduledTask, Get-Service, Get-DeliveryOptimizationStatus, powercfg /a
    and registry reads. This test NEVER:
      - applies TRIM, last-access, 8.3, memory-usage, Storage Sense, D3 or write-cache
        settings (-Approved paths are exercised only with an UNINITIALIZED journal so
        the journal-first guard throws before any mutation, or in -WhatIf mode)
      - rewrites the Optimize Drives task (only its read-only report is called)
      - deletes anything under Windows or a user temp directory: the deletion test
        creates its own temp root and deletes only files it created there
      - stops or starts any service, or touches Windows Update / Delivery Optimization
        cache content (report paths only; no -Consent).

    Covers: module surface, registry<->function parameter contract, the fsutil output
    parser (documented samples + garbage), the temp-root allow-list, dry-run vs
    consented deletion in a temp root with journal + irreversible rollback reporting,
    the pure update-idle gate, journal-first refusals, report-mode no-mutation checks,
    rollback candidate selection, and every read-only report function.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\..\src\nxcore'
foreach ($m in 'NxJournal.ps1', 'NxBuild.ps1', 'NxVerify.ps1', 'NxHardware.ps1', 'NxRollback.ps1', 'NxApply.ps1') {
    . (Join-Path $root $m)
}
. (Join-Path $root 'functions\NX06.ps1')

$script:pass = 0
$script:fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('nx06-selftest-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $tmpRoot -ItemType Directory -Force | Out-Null
$tmpJournal = Join-Path $tmpRoot 'journal'
$tmpUnarmed = Join-Path $tmpRoot 'journal-unarmed'

# Snapshot of live read-only state, compared again at the end (proves no mutation).
$liveBefore = [pscustomobject]@{
    fsutil = (Get-NxNtfsBehaviorState -SkipVolumes)
    storageSense = Capture-NxRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' -Name 'AllowStorageSenseGlobal'
    d3 = Capture-NxRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Storage' -Name 'StorageD3InModernStandby'
    task = (Get-NxOptimizeDrivesState)
}

try {
    # ------------------------------------------------------------------------
    # 0. Module surface: every action function the registry references exists.
    # ------------------------------------------------------------------------
    $surface = @(
        'Get-NxStorageInventory', 'Set-NxTrimEnabled', 'Get-NxOptimizeDrivesState',
        'Set-NxOptimizeDrivesSchedule', 'Get-NxStorageSenseState', 'Set-NxStorageSensePolicy',
        'Get-NxTemporaryFileReport', 'Clear-NxTemporaryFiles', 'Get-NxWindowsUpdateCacheReport',
        'Clear-NxWindowsUpdateCache', 'Get-NxDeliveryOptimizationCacheReport',
        'Clear-NxDeliveryOptimizationCache', 'Set-NxNtfsLastAccessPolicy',
        'Set-NxNtfs8dot3Policy', 'Set-NxNtfsMemoryUsage', 'Get-NxWriteCacheState',
        'Set-NxWriteCachePolicy', 'Get-NxStorageD3State', 'Set-NxStorageD3Policy',
        'Get-NxDriveHealthReport', 'Invoke-Nx06Rollback', 'Get-Nx06RollbackCandidates',
        'Get-NxNtfsBehaviorState'
    )
    $missing = @($surface | Where-Object { $null -eq (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue) })
    Assert-Nx 'module surface: all NX06 functions defined' ($missing.Count -eq 0) ($missing -join ',')

    # ------------------------------------------------------------------------
    # 0b. Registry <-> function contract (mirrors the build generator's drift check).
    # ------------------------------------------------------------------------
    $registryPath = Join-Path $PSScriptRoot '..\..\registry\NX06.json'
    $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tweaks = @($registry.tweaks)
    Assert-Nx 'registry: 13 NX06 entries' ($tweaks.Count -eq 13)
    $ids = @($tweaks | ForEach-Object { $_.id })
    Assert-Nx 'registry: ids are NX06-001..013' (($ids -join ',') -eq ((1..13 | ForEach-Object { 'NX06-{0:000}' -f $_ }) -join ','))
    $engineSupplied = @('JournalRoot', 'JournalPath', 'Approved', 'Approval', 'Profiles', 'TweakVersion')
    $drift = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tweaks) {
        foreach ($a in @($t.apply.actions)) {
            if ($a.type -ne 'function') { continue }
            $cmd = Get-Command -Name ([string]$a.function) -CommandType Function -ErrorAction SilentlyContinue
            if ($null -eq $cmd) { $drift.Add("$($t.id): function '$($a.function)' not defined"); continue }
            foreach ($p in $a.parameters.PSObject.Properties) {
                if (-not $cmd.Parameters.ContainsKey([string]$p.Name)) { $drift.Add("$($t.id): parameter '$($p.Name)' not declared by $($a.function)") }
            }
            foreach ($required in @('JournalRoot', 'Approved', 'Approval')) {
                if ($cmd.Parameters.ContainsKey($required)) { continue }
                # Read-only diagnostics legitimately have no journal/approval surface.
                if ($t.modificationType -ne 'none') { $drift.Add("$($t.id): mutating function '$($a.function)' lacks -$required") }
            }
        }
    }
    Assert-Nx 'registry: no parameter/signature drift' ($drift.Count -eq 0) ($drift -join ' | ')
    Assert-Nx 'registry: E1 entries carry a Microsoft URL' (@($tweaks | Where-Object {
                $_.evidence -eq 'E1' -and -not (@($_.documentationSource) | Where-Object { $_ -like 'https://learn.microsoft.com/*' -or $_ -like 'https://support.microsoft.com/*' })
            }).Count -eq 0)

    # ------------------------------------------------------------------------
    # A. fsutil parser on documented sample outputs (pure function).
    # ------------------------------------------------------------------------
    $trimOff = ConvertFrom-Nx06FsutilOutput -Name 'disabledeletenotify' -Lines @('NTFS DisableDeleteNotify = 1', 'ReFS DisableDeleteNotify is not currently set')
    Assert-Nx 'parser trim: NTFS value parsed' ($trimOff.recognized -and [int]$trimOff.parsed -eq 1)
    Assert-Nx 'parser trim: semantic TrimDisabled' ($trimOff.semantic -eq 'TrimDisabled')
    Assert-Nx 'parser trim: ReFS NotConfigured entry kept' (@($trimOff.entries | Where-Object { $_.fileSystem -eq 'ReFS' -and $_.state -eq 'NotConfigured' }).Count -eq 1)
    $trimOn = ConvertFrom-Nx06FsutilOutput -Name 'disabledeletenotify' -Lines @('NTFS DisableDeleteNotify = 0  (Allows TRIM operations to be sent to the storage device)')
    Assert-Nx 'parser trim: enabled detected' ($trimOn.recognized -and $trimOn.semantic -eq 'TrimEnabled')

    $laDisabled = ConvertFrom-Nx06FsutilOutput -Name 'disablelastaccess' -Lines @('DisableLastAccess = 1  (User Managed, Last Access Time Updates DISABLED)')
    Assert-Nx 'parser lastaccess: disabled + user managed' ($laDisabled.recognized -and [int]$laDisabled.parsed -eq 1 -and $laDisabled.semantic -eq 'Disabled' -and $laDisabled.extra['userManaged'] -eq $true)
    $laSystem = ConvertFrom-Nx06FsutilOutput -Name 'disablelastaccess' -Lines @('DisableLastAccess = 0  (System Managed, Last Access Time Updates ENABLED)')
    Assert-Nx 'parser lastaccess: system-managed enabled decodes to 0/Enabled' ($laSystem.recognized -and [int]$laSystem.parsed -eq 0 -and $laSystem.semantic -eq 'Enabled' -and $laSystem.extra['userManaged'] -eq $false)
    $laHighBit = ConvertFrom-Nx06FsutilOutput -Name 'disablelastaccess' -Lines @('DisableLastAccess = -2147483647  (User Managed, Last Access Time Updates DISABLED)')
    Assert-Nx 'parser lastaccess: 0x80000001 encoding decodes to disabled' ($laHighBit.recognized -and [int]$laHighBit.parsed -eq 1 -and $laHighBit.extra['userManaged'] -eq $true)

    $eight = ConvertFrom-Nx06FsutilOutput -Name 'disable8dot3' -Lines @('The registry state is: 1 (8dot3 name creation is DISABLED on all volumes)')
    Assert-Nx 'parser 8dot3: registry state 1 / effective DISABLED' ($eight.recognized -and [int]$eight.parsed -eq 1 -and $eight.extra['effective'] -eq 'DISABLED' -and $eight.semantic -eq 'Disabled')

    $mem = ConvertFrom-Nx06FsutilOutput -Name 'memoryusage' -Lines @('MemoryUsage = 0  (The default memory consumption values are used for caching NTFS metadata)')
    Assert-Nx 'parser memoryusage: 0 treated as documented default' ($mem.recognized -and [int]$mem.parsed -eq 0 -and $mem.semantic -eq 'Default')
    $mem2 = ConvertFrom-Nx06FsutilOutput -Name 'memoryusage' -Lines @('MemoryUsage = 2  (Increased memory consumption values are used)')
    Assert-Nx 'parser memoryusage: 2 = Increased' ($mem2.recognized -and $mem2.semantic -eq 'Increased')

    $garbage = ConvertFrom-Nx06FsutilOutput -Name 'disablelastaccess' -Lines @('Der letzte Zugriff wurde deaktiviert')
    Assert-Nx 'parser: unparseable output is not recognized (fail-closed)' (-not $garbage.recognized -and $garbage.semantic -eq 'Unknown')

    # ------------------------------------------------------------------------
    # B. Cleanup path allow-list (pure; no filesystem change).
    # ------------------------------------------------------------------------
    $driveRoot = [IO.Path]::GetPathRoot($env:SystemRoot)
    $r1 = Test-Nx06CleanupRoot -Path $driveRoot
    Assert-Nx 'allow-list: drive root refused' (-not $r1.accepted)
    $r2 = Test-Nx06CleanupRoot -Path (Join-Path $env:SystemRoot 'System32')
    Assert-Nx 'allow-list: System32 refused (leaf not temp)' (-not $r2.accepted)
    $r3 = Test-Nx06CleanupRoot -Path (Join-Path $env:SystemRoot 'Temp')
    Assert-Nx 'allow-list: Windows\Temp accepted' ($r3.accepted -and $r3.fullPath -like '*\Windows\Temp')
    $r4 = Test-Nx06CleanupRoot -Path (Join-Path $env:ProgramData 'Temp')
    Assert-Nx 'allow-list: ProgramData\Temp refused (outside Windows/profiles)' (-not $r4.accepted)
    $r5 = Test-Nx06CleanupRoot -Path (Join-Path $tmpRoot 'notatemp')
    Assert-Nx 'allow-list: non-temp leaf refused' (-not $r5.accepted)

    # ------------------------------------------------------------------------
    # C. Temp cleanup: dry-run first, then consented deletion inside OUR temp root.
    # ------------------------------------------------------------------------
    $myTemp = Join-Path $tmpRoot 'temp'
    New-Item -Path $myTemp -ItemType Directory -Force | Out-Null
    $oldFile = Join-Path $myTemp 'old-selftest-file.tmp'
    $newFile = Join-Path $myTemp 'new-selftest-file.tmp'
    Set-Content -LiteralPath $oldFile -Value ('x' * 1024) -Encoding ASCII
    Set-Content -LiteralPath $newFile -Value ('y' * 512) -Encoding ASCII
    (Get-Item -LiteralPath $oldFile).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-10)
    (Get-Item -LiteralPath $newFile).LastWriteTimeUtc = (Get-Date).ToUniversalTime()

    $dry = Get-NxTemporaryFileReport -Paths @($myTemp) -MinimumAgeDays 7
    $oldLength = (Get-Item -LiteralPath $oldFile).Length
    Assert-Nx 'temp report: only the old file is a candidate' ($dry.fileCount -eq 1 -and $dry.bytes -eq $oldLength)
    Assert-Nx 'temp report: nothing deleted' ((Test-Path -LiteralPath $oldFile) -and (Test-Path -LiteralPath $newFile))
    Assert-Nx 'temp report: irreversibility label present' ($dry.irreversibility -match 'cannot be undone')

    $dryRun = Clear-NxTemporaryFiles -JournalRoot $tmpJournal -Paths @($myTemp) -MinimumAgeDays 7
    Assert-Nx 'temp cleanup without consent: Report outcome' ($dryRun.outcome -eq 'Report')
    Assert-Nx 'temp cleanup without consent: nothing deleted' ((Test-Path -LiteralPath $oldFile) -and -not (Test-Path $tmpJournal))

    $null = Initialize-NxJournal -Path $tmpJournal
    $applied = Clear-NxTemporaryFiles -JournalRoot $tmpJournal -Paths @($myTemp) -MinimumAgeDays 7 -Consent -Approved -Approval 'ExplicitConsent' -Profiles @('P9')
    Assert-Nx 'temp cleanup consented: Applied + verified' ($applied.outcome -eq 'Applied' -and $applied.verified -eq $true)
    Assert-Nx 'temp cleanup consented: only the old file deleted' ((-not (Test-Path -LiteralPath $oldFile)) -and (Test-Path -LiteralPath $newFile))

    $journalAfterDelete = Read-NxJournal -Path $tmpJournal
    Assert-Nx 'temp cleanup: journal records Success-Irreversible verify entry' (@($journalAfterDelete.entries | Where-Object { $_.tweakId -eq 'NX06-005' -and $_.result -eq 'Success-Irreversible' }).Count -eq 1)
    Assert-Nx 'temp cleanup: apply entry carries the irreversibility label' (@($journalAfterDelete.entries | Where-Object { $_.tweakId -eq 'NX06-005' -and $_.operation -eq 'apply' -and [string]$_.original.irreversibility -match 'NOT REVERSIBLE' }).Count -eq 1)
    $rb = Invoke-Nx06Rollback -JournalRoot $tmpJournal -TweakId 'NX06-005'
    Assert-Nx 'temp cleanup rollback: reported irreversible, nothing restored' (@($rb.irreversible).Count -eq 1 -and @($rb.restored).Count -eq 0 -and @($rb.failed).Count -eq 0)

    # ------------------------------------------------------------------------
    # D. Update idle gate (pure logic).
    # ------------------------------------------------------------------------
    $idleClean = Get-Nx06UpdateIdleVerdict
    Assert-Nx 'idle gate: clean state is idle' ($idleClean.idle -eq $true)
    $idleReboot = Get-Nx06UpdateIdleVerdict -PendingRebootReasons @('CBS RebootPending')
    Assert-Nx 'idle gate: pending reboot blocks' ($idleReboot.idle -eq $false -and $idleReboot.reasons -match 'pending reboot')
    $idleProc = Get-Nx06UpdateIdleVerdict -BusyProcesses @('TiWorker')
    Assert-Nx 'idle gate: servicing process blocks' ($idleProc.idle -eq $false)
    $idleSvc = Get-Nx06UpdateIdleVerdict -RunningServices @('wuauserv')
    Assert-Nx 'idle gate: wuauserv running blocks by default' ($idleSvc.idle -eq $false)
    $idleSvcStop = Get-Nx06UpdateIdleVerdict -RunningServices @('wuauserv') -AllowServiceStop
    Assert-Nx 'idle gate: consenting to a temporary stop tolerates the service' ($idleSvcStop.idle -eq $true -and @($idleSvcStop.blockingServices).Count -eq 1)
    $idleProcStop = Get-Nx06UpdateIdleVerdict -BusyProcesses @('TrustedInstaller') -AllowServiceStop
    Assert-Nx 'idle gate: a servicing process still blocks even with stop consent' ($idleProcStop.idle -eq $false)

    # ------------------------------------------------------------------------
    # E. Journal-first refusals: approval without an initialized journal must
    #    throw BEFORE any mutation. (No live state changes: assert + snapshot below.)
    # ------------------------------------------------------------------------
    $refusals = New-Object System.Collections.Generic.List[string]
    foreach ($case in @(
            @{ name = 'NX06-004'; fn = 'Set-NxStorageSensePolicy'; args = @{ JournalRoot = $tmpUnarmed; Mode = 'Enable'; Approved = $true } },
            @{ name = 'NX06-008'; fn = 'Set-NxNtfsLastAccessPolicy'; args = @{ JournalRoot = $tmpUnarmed; Mode = 'Enable'; Approved = $true } },
            @{ name = 'NX06-009'; fn = 'Set-NxNtfs8dot3Policy'; args = @{ JournalRoot = $tmpUnarmed; Mode = 'Enable'; Approved = $true } },
            @{ name = 'NX06-010'; fn = 'Set-NxNtfsMemoryUsage'; args = @{ JournalRoot = $tmpUnarmed; Mode = 'Increased'; Approved = $true } },
            @{ name = 'NX06-011'; fn = 'Set-NxWriteCachePolicy'; args = @{ JournalRoot = $tmpUnarmed; Mode = 'Disable'; DiskNumber = 0; Approved = $true } },
            @{ name = 'NX06-012'; fn = 'Set-NxStorageD3Policy'; args = @{ JournalRoot = $tmpUnarmed; Mode = 'AllowD3'; Approved = $true } }
        )) {
        $splat = $case.args
        $threw = $false
        $res = $null
        try { $res = & $case.fn @splat } catch { $threw = ([string]$_.Exception.Message -match 'journal not initialized|journal captureStatus') }
        # A machine-specific refusal (no device path / no S0 standby) is also acceptable:
        # what matters is that nothing was mutated without an armed journal.
        $benignSkip = ($null -ne $res -and $res.outcome -in @('Refused', 'Skipped'))
        if (-not $threw -and -not $benignSkip) { $refusals.Add($case.name) }
        if ($benignSkip) { Write-Output ("INFO: $($case.name) refused before the journal guard: $($res.reason)") }
    }
    Assert-Nx 'journal-first: approval without an armed journal refuses for all mutating entries' ($refusals.Count -eq 0) ($refusals -join ',')
    Assert-Nx 'journal-first: refusal created no journal' (-not (Test-Path (Join-Path $tmpUnarmed 'manifest.json')))
    $trimAlready = Set-NxTrimEnabled -JournalRoot $tmpUnarmed -Mode 'Enable' -Approved
    Assert-Nx 'journal-first: already-correct TRIM reports AlreadyApplied without requiring a journal' ($trimAlready.outcome -in @('AlreadyApplied', 'Skipped', 'Report') -and -not (Test-Path (Join-Path $tmpUnarmed 'manifest.json')))

    # ------------------------------------------------------------------------
    # F. Report-mode no-mutation + report contracts.
    # ------------------------------------------------------------------------
    $rawBefore = $liveBefore.fsutil.disablelastaccess.raw
    $tmTrim = Set-NxTrimEnabled -JournalRoot $tmpUnarmed -Mode 'Report'
    Assert-Nx 'trim report: Report outcome, no journal needed' ($tmTrim.outcome -in @('Report', 'AlreadyApplied', 'Skipped'))
    $laReport = Set-NxNtfsLastAccessPolicy -JournalRoot $tmpUnarmed -Mode 'Report'
    Assert-Nx 'lastaccess report: Report outcome' ($laReport.outcome -eq 'Report')
    $eightReport = Set-NxNtfs8dot3Policy -JournalRoot $tmpUnarmed -Mode 'Report'
    Assert-Nx '8dot3 report: Report outcome' ($eightReport.outcome -eq 'Report')
    $memReport = Set-NxNtfsMemoryUsage -JournalRoot $tmpUnarmed -Mode 'Report'
    Assert-Nx 'memoryusage report: Report outcome + honest ADVANCED framing' ($memReport.outcome -eq 'Report' -and @($memReport.warnings | Where-Object { $_ -match 'might reduce overall system performance' }).Count -eq 1)
    $ssReport = Set-NxStorageSensePolicy -JournalRoot $tmpUnarmed -Mode 'Report'
    Assert-Nx 'storage sense report: Report outcome' ($ssReport.outcome -eq 'Report')
    $d3Report = Set-NxStorageD3Policy -JournalRoot $tmpUnarmed -Mode 'Report'
    Assert-Nx 'storage D3 report: Report outcome' ($d3Report.outcome -eq 'Report')
    $wcReport = Set-NxWriteCachePolicy -JournalRoot $tmpUnarmed -Mode 'Report'
    Assert-Nx 'write cache report: Report outcome + power-loss warning present' ($wcReport.outcome -eq 'Report' -and @($wcReport.warnings | Where-Object { $_ -match 'POWER-LOSS TRADE-OFF' }).Count -eq 1)
    $odReport = Set-NxOptimizeDrivesSchedule -JournalRoot $tmpUnarmed -Cadence 'Monthly'
    Assert-Nx 'optimize drives without approval: Report/Skipped, never applied' ($odReport.outcome -in @('Report', 'Skipped', 'AlreadyApplied'))

    $liveAfterReports = Get-NxNtfsBehaviorState -SkipVolumes
    Assert-Nx 'no-mutation: fsutil last-access raw unchanged by report mode' ($liveAfterReports.disablelastaccess.raw -eq $rawBefore)
    $ssAfter = Capture-NxRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' -Name 'AllowStorageSenseGlobal'
    Assert-Nx 'no-mutation: Storage Sense policy unchanged' ((ConvertTo-Json $ssAfter -Compress -Depth 4) -eq (ConvertTo-Json $liveBefore.storageSense -Compress -Depth 4))
    $d3After = Capture-NxRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Storage' -Name 'StorageD3InModernStandby'
    Assert-Nx 'no-mutation: StorageD3InModernStandby unchanged' ((ConvertTo-Json $d3After -Compress -Depth 4) -eq (ConvertTo-Json $liveBefore.d3 -Compress -Depth 4))
    $taskAfterReports = Get-NxOptimizeDrivesState
    Assert-Nx 'no-mutation: Optimize Drives schedule/enabled unchanged' ($taskAfterReports.maintenancePeriod -eq $liveBefore.task.maintenancePeriod -and $taskAfterReports.enabled -eq $liveBefore.task.enabled)

    # ------------------------------------------------------------------------
    # G. Read-only reports.
    # ------------------------------------------------------------------------
    $inv = Get-NxStorageInventory
    Assert-Nx 'inventory: readSucceeded on a real machine' ($inv.readSucceeded -eq $true)
    Assert-Nx 'inventory: classification enum respected' (@($inv.physicalDisks | Where-Object { $_.classification -notin @('nvme-ssd', 'ssd', 'scm', 'hdd', 'usb', 'unknown') }).Count -eq 0)
    Assert-Nx 'inventory: trimApplicable only for solid-state classes' (@($inv.physicalDisks | Where-Object { $_.trimApplicable -and -not ($_.classification -in @('nvme-ssd', 'ssd', 'scm')) }).Count -eq 0)

    $health = Get-NxDriveHealthReport
    Assert-Nx 'health: every disk has a verdict from the documented enum' (@($health.disks | Where-Object { $_.verdict -notin @('Healthy', 'Warning', 'Unhealthy', 'Unknown') }).Count -eq 0)
    Assert-Nx 'health: no-prediction caveat present' (@($health.caveats | Where-Object { $_ -match 'does not predict failure' }).Count -eq 1)

    $wc = Get-NxWriteCacheState
    Assert-Nx 'write cache state: per-disk rows with the documented API view fields' (@($wc.disks | Where-Object { -not $_.PSObject.Properties['deviceCacheEnabled'] }).Count -eq 0)
    Assert-Nx 'write cache state: E0 provenance stated' ($wc.evidenceNote -match 'E0')

    $d3 = Get-NxStorageD3State
    Assert-Nx 'storage D3 state: semantic is an honest enum' ($d3.semantic -in @('D3Disabled', 'D3Enabled', 'UnrecognizedValue') -or $d3.semantic -like 'NotConfigured*')
    Assert-Nx 'storage D3 state: plan disk-idle reported as NX09 territory' (@($d3.planDiskIdle | Where-Object { $_.note -match 'NX09' }).Count -eq @($d3.planDiskIdle).Count)
    Assert-Nx 'storage D3 state: per-device fields never written (notes present)' (@($d3.notes | Where-Object { $_ -match 'never written' -or $_ -match 'only reported' }).Count -ge 1)

    $ss = Get-NxStorageSenseState
    Assert-Nx 'storage sense state: all five documented policies enumerated' (@($ss.policies).Count -eq 5)
    Assert-Nx 'storage sense state: user toggle reported read-only' ($ss.userToggle.note -match 'never written')

    $wu = Get-NxWindowsUpdateCacheReport
    Assert-Nx 'WU cache report: idle verdict object present' ($null -ne $wu.idleVerdict -and $null -ne $wu.idleVerdict.idle)
    Assert-Nx 'WU cache report: never-disables policy note present' ($wu.policyNote -match 'never disables')
    $wuPlan = Clear-NxWindowsUpdateCache -JournalRoot $tmpJournal
    Assert-Nx 'WU cache without consent: no deletion, Report/Refused only' ($wuPlan.outcome -in @('Report', 'Refused'))
    Assert-Nx 'WU cache without consent: no NX06-006 apply entry journaled' (@((Read-NxJournal -Path $tmpJournal).entries | Where-Object { $_.tweakId -eq 'NX06-006' }).Count -eq 0)

    $do = Get-NxDeliveryOptimizationCacheReport
    Assert-Nx 'DO report: cmdlet availability recorded' ($null -ne $do.cmdletAvailable -and $null -ne $do.cmdletAvailable.delete)
    Assert-Nx 'DO report: NX01-011 boundary stated' ($do.boundaryNote -match 'NX01-011')
    $doPlan = Clear-NxDeliveryOptimizationCache -JournalRoot $tmpJournal
    Assert-Nx 'DO cache without consent: no deletion (Report/Skipped)' ($doPlan.outcome -in @('Report', 'Skipped'))
    Assert-Nx 'DO cache without consent: no NX06-007 apply entry journaled' (@((Read-NxJournal -Path $tmpJournal).entries | Where-Object { $_.tweakId -eq 'NX06-007' }).Count -eq 0)

    $tempReport = Get-NxTemporaryFileReport -MinimumAgeDays 30
    Assert-Nx 'default temp report: read-only and complete' ($tempReport.readOnly -eq $true -and $null -ne $tempReport.fileCount)

    # ------------------------------------------------------------------------
    # H. Rollback candidate selection (pure).
    # ------------------------------------------------------------------------
    $fakeEntries = @(
        [pscustomobject]@{ tweakId = 'NX06-002'; operation = 'apply'; result = 'InProgress'; original = [pscustomobject]@{ targetType = 'fsutilBehavior' } },
        [pscustomobject]@{ tweakId = 'NX06-003'; operation = 'apply'; result = 'InProgress'; original = [pscustomobject]@{ targetType = 'scheduledTask' } },
        [pscustomobject]@{ tweakId = 'NX06-006'; operation = 'apply'; result = 'InProgress'; original = [pscustomobject]@{ targetType = 'fileDeletionSet' } },
        [pscustomobject]@{ tweakId = 'NX06-012'; operation = 'apply'; result = 'InProgress'; original = [pscustomobject]@{ targetType = 'registry' } },
        [pscustomobject]@{ tweakId = 'NX06-013'; operation = 'apply'; result = 'InProgress'; original = [pscustomobject]@{ targetType = 'function' } },
        [pscustomobject]@{ tweakId = 'NX09-004'; operation = 'apply'; result = 'InProgress'; original = [pscustomobject]@{ targetType = 'fsutilBehavior' } }
    )
    $cand = Get-Nx06RollbackCandidates -JournalEntries $fakeEntries
    Assert-Nx 'rollback candidates: 3 NX06 non-registry entries selected' (@($cand).Count -eq 3)
    Assert-Nx 'rollback candidates: registry/function entries excluded (engine owns them)' (@($cand | Where-Object { $_.original.targetType -in @('registry', 'function') }).Count -eq 0)
    Assert-Nx 'rollback candidates: other categories excluded' (@($cand | Where-Object { $_.tweakId -notlike 'NX06-*' }).Count -eq 0)

    # ------------------------------------------------------------------------
    # I. Invoke-Nx06Rollback requires an explicit scope.
    # ------------------------------------------------------------------------
    $scoped = $false
    try { Invoke-Nx06Rollback -JournalRoot $tmpJournal | Out-Null } catch { $scoped = ([string]$_.Exception.Message -match 'specify -TweakId or -AllNx06') }
    Assert-Nx 'rollback: refuses an implicit full-category rollback' $scoped

    # ------------------------------------------------------------------------
    # J. WhatIf never writes and never journals.
    # ------------------------------------------------------------------------
    $jrnBefore = (Read-NxJournal -Path $tmpJournal).entries.Count
    $whatif = Set-NxStorageD3Policy -JournalRoot $tmpJournal -Mode 'AllowD3' -Approved -WhatIf
    Assert-Nx 'WhatIf: report outcome with no mutation' ($whatif.outcome -eq 'Report' -and $whatif.reason -match 'WhatIf')
    Assert-Nx 'WhatIf: journal entry count unchanged' ((Read-NxJournal -Path $tmpJournal).entries.Count -eq $jrnBefore)

    # ------------------------------------------------------------------------
    # K. End-of-suite proof: no live state changed.
    # ------------------------------------------------------------------------
    $liveEnd = Get-NxNtfsBehaviorState -SkipVolumes
    Assert-Nx 'end: fsutil trim raw unchanged' ($liveEnd.disabledeletenotify.raw -eq $liveBefore.fsutil.disabledeletenotify.raw)
    Assert-Nx 'end: fsutil last-access raw unchanged' ($liveEnd.disablelastaccess.raw -eq $liveBefore.fsutil.disablelastaccess.raw)
    Assert-Nx 'end: fsutil 8.3 raw unchanged' ($liveEnd.disable8dot3.raw -eq $liveBefore.fsutil.disable8dot3.raw)
    Assert-Nx 'end: fsutil memory raw unchanged' ($liveEnd.memoryusage.raw -eq $liveBefore.fsutil.memoryusage.raw)
    $taskEnd = Get-NxOptimizeDrivesState
    Assert-Nx 'end: Optimize Drives task XML/state unchanged' ($taskEnd.xml -eq $liveBefore.task.xml -and $taskEnd.enabled -eq $liveBefore.task.enabled)
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ("SELFTEST RESULT: pass=$script:pass fail=$script:fail")
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
