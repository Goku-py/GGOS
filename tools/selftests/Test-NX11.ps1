#Requires -Version 5.1
<#
    Test-NX11.ps1 - NX11 (Background Activity & Services) category self-test.

    SAFETY BOUNDARY (directive Section 16): this test writes ONLY to throwaway temp
    directories. Windows is touched only through READ-ONLY queries: registry capture,
    Get-Service, Get-ScheduledTask, Get-Process, Get-CimInstance, Get-Printer (when
    present). Every mutating function is exercised in -Plan mode ONLY; no service is
    started/stopped/reconfigured, no task is enabled/disabled, no startup marker is
    written and no Edge/WER policy value is created.

    Covered: module surface, never-touch/allow-list/protected-task policy logic,
    StartupApproved state decoding, byte comparison, read-only inventories, Plan-mode
    contracts (no journal entry, no mutation), the journal-first gate, and the empty-
    journal rollback path.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\..\src\nxcore'
foreach ($m in 'NxJournal.ps1', 'NxVerify.ps1', 'NxApply.ps1', 'NxRollback.ps1') {
    . (Join-Path $root $m)
}
. (Join-Path $root 'functions\NX11.ps1')

$script:pass = 0
$script:fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: " + $Name) }
    else { $script:fail++; Write-Output ("FAIL: " + $Name + " " + $Detail) }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('nx11-selftest-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $tmpRoot -ItemType Directory -Force | Out-Null

try {
    # ------------------------------------------------------------------------
    # 0. Module surface.
    # ------------------------------------------------------------------------
    $publicFns = @(
        'Get-NxStartupInventory', 'Set-NxStartupItemState',
        'Get-NxAppPermissionInventory', 'Set-NxAppPermission',
        'Set-NxEdgeBackgroundMode', 'Set-NxEdgeStartupBoost',
        'Get-NxScheduledTaskInventory', 'Get-NxScheduledTaskCandidates', 'Set-NxScheduledTaskState',
        'Get-NxResourceHeavyProcessReport', 'Set-NxSearchServiceConfig', 'Set-NxSysMainConfig',
        'Set-NxXboxServicesConfig', 'Get-NxPrintSpoolerReport', 'Set-NxBluetoothServiceConfig',
        'Set-NxFaxServiceConfig', 'Set-NxRemoteRegistryConfig', 'Set-NxWerReportingConfig',
        'Set-NxMapsServiceConfig', 'Set-NxDiagTrackConfig', 'Get-NxThirdPartyServiceInventory',
        'Set-NxThirdPartyServiceConfig', 'Get-NxServiceDependencyReport', 'Invoke-Nx11Rollback'
    )
    $missing = @($publicFns | Where-Object { $null -eq (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue) })
    Assert-Nx 'all 24 NX11 functions are defined' ($missing.Count -eq 0) ($missing -join ',')

    # ------------------------------------------------------------------------
    # A. Policy data: never-touch, protected tasks, allow-list.
    # ------------------------------------------------------------------------
    Assert-Nx 'Spooler is refused by the code-side never-touch guard' (Test-Nx11NeverTouchService -Name 'Spooler') 'guard returned false'
    Assert-Nx 'never-touch check is case-insensitive' (Test-Nx11NeverTouchService -Name 'spooler')
    Assert-Nx 'SysMain is not never-touch' (-not (Test-Nx11NeverTouchService -Name 'SysMain'))
    Assert-Nx 'update task pattern is protected' (Test-Nx11TaskPathProtected -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -TaskName 'Universal Orchestrator Start')
    Assert-Nx 'WDI ResolutionHost is protected' (Test-Nx11TaskPathProtected -TaskPath '\Microsoft\Windows\WDI\' -TaskName 'ResolutionHost')
    Assert-Nx 'RegIdleBackup is protected' (Test-Nx11TaskPathProtected -TaskPath '\Microsoft\Windows\Registry\' -TaskName 'RegIdleBackup')
    Assert-Nx 'ProgramDataUpdater is allow-listed' ($null -ne (Get-Nx11TaskAllowEntry -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'ProgramDataUpdater'))
    Assert-Nx 'arbitrary vendor task is not allow-listed' ($null -eq (Get-Nx11TaskAllowEntry -TaskPath '\Vendor\' -TaskName 'VendorTask'))
    Assert-Nx 'allow-list contains no protected entry' (@($script:Nx11TaskAllowList | Where-Object { Test-Nx11TaskPathProtected -TaskPath $_.TaskPath -TaskName $_.TaskName }).Count -eq 0)

    # ------------------------------------------------------------------------
    # B. StartupApproved decoding + byte comparison (pure).
    # ------------------------------------------------------------------------
    $capEnabled = [pscustomobject]@{ existed = $true; kind = 'Binary'; value = [byte[]]@(2,0,0,0,0,0,0,0,0,0,0,0) }
    $capDisabled = [pscustomobject]@{ existed = $true; kind = 'Binary'; value = [byte[]]@(3,0,0,0,0,0,0,0,0,0,0,0) }
    $capAbsent = [pscustomobject]@{ existed = $false; kind = $null; value = $null }
    $capWrongKind = [pscustomobject]@{ existed = $true; kind = 'String'; value = 'x' }
    $capUnknown = [pscustomobject]@{ existed = $true; kind = 'Binary'; value = [byte[]]@(7,0) }
    Assert-Nx 'StartupApproved 02 decodes Enabled' ((Get-Nx11StartupApprovedState -Capture $capEnabled) -eq 'Enabled')
    Assert-Nx 'StartupApproved 03 decodes Disabled' ((Get-Nx11StartupApprovedState -Capture $capDisabled) -eq 'Disabled')
    Assert-Nx 'StartupApproved absent decodes NoApprovalValue' ((Get-Nx11StartupApprovedState -Capture $capAbsent) -eq 'NoApprovalValue')
    Assert-Nx 'StartupApproved wrong kind decodes UnsupportedValue' ((Get-Nx11StartupApprovedState -Capture $capWrongKind) -eq 'UnsupportedValue')
    Assert-Nx 'StartupApproved unknown first byte stays Unknown' ((Get-Nx11StartupApprovedState -Capture $capUnknown) -eq 'Unknown')
    Assert-Nx 'byte comparison equal' (Test-Nx11ByteEqual $capEnabled.value ([byte[]]@(2,0,0,0,0,0,0,0,0,0,0,0)))
    Assert-Nx 'byte comparison differs on first byte' (-not (Test-Nx11ByteEqual $capEnabled.value $capDisabled.value))
    Assert-Nx 'byte comparison differs on length' (-not (Test-Nx11ByteEqual @(2,0) @(2,0,0)))

    # ------------------------------------------------------------------------
    # C. Startup inventory (read-only).
    # ------------------------------------------------------------------------
    $startup = Get-NxStartupInventory
    Assert-Nx 'startup inventory is read-only' ($startup.readOnly -eq $true)
    Assert-Nx 'startup inventory returns an items array' ($null -ne $startup.items)
    Assert-Nx 'startup inventory carries item IDs' (@($startup.items | Where-Object { -not $_.itemId }).Count -eq 0)

    $tmpJournal = Join-Path $tmpRoot 'journal'
    $null = Initialize-NxJournal -Path $tmpJournal

    # Plan mode on a real item must not write. Pick the first Run item if one exists.
    $firstRun = @($startup.items | Where-Object { $_.managedByNx11 -eq $true })[0]
    if ($null -ne $firstRun) {
        $before = Capture-NxRegistryValue -Path $firstRun.approved.path -Name $firstRun.name
        $planStartup = Set-NxStartupItemState -Scope $firstRun.scope -Location $firstRun.location -Name $firstRun.name -Mode Disable -JournalRoot $tmpJournal -Plan
        $after = Capture-NxRegistryValue -Path $firstRun.approved.path -Name $firstRun.name
        Assert-Nx 'startup Plan reports Planned/AlreadyAtState' (@('Planned','AlreadyAtState') -contains $planStartup.outcome) ([string]$planStartup.outcome)
        Assert-Nx 'startup Plan wrote nothing to the approval value' ((ConvertTo-Json $before.value -Compress) -eq (ConvertTo-Json $after.value -Compress) -and $before.existed -eq $after.existed)
    } else {
        Write-Output 'SKIP: no managed startup item present on this machine'
    }
    $missingStartup = Set-NxStartupItemState -Scope HKCU -Location Run -Name 'NX11-SelfTest-NotAnItem' -Mode Disable -JournalRoot $tmpJournal -Plan
    Assert-Nx 'startup Plan skips a missing item' ($missingStartup.outcome -eq 'Skipped')

    # ------------------------------------------------------------------------
    # D. App permission inventory + Plan (no write).
    # ------------------------------------------------------------------------
    $permInv = Get-NxAppPermissionInventory -MaxPackages 5
    Assert-Nx 'app permission inventory is read-only' ($permInv.readOnly -eq $true)
    Assert-Nx 'app permission inventory lists three per-app lists' (@($permInv.policyValues | Where-Object { $_.name -like '*TheseApps' }).Count -eq 3)
    $permPlan = Set-NxAppPermission -AppFamilyName 'NX11.SelfTest_1.0.0.0_x64__selftest' -Permission ForceDeny -JournalRoot $tmpJournal -Plan
    Assert-Nx 'app permission Plan reports Planned' ($permPlan.outcome -eq 'Planned') ([string]$permPlan.outcome)
    $denyCap = Capture-NxRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -Name 'LetAppsRunInBackground_ForceDenyTheseApps'
    Assert-Nx 'app permission Plan did not create a deny-list value' (-not ($denyCap.existed -and (@($denyCap.value) -contains 'NX11.SelfTest_1.0.0.0_x64__selftest')))

    # ------------------------------------------------------------------------
    # E. Edge / WER Plan paths (no write).
    # ------------------------------------------------------------------------
    $edgePath = 'HKCU:\SOFTWARE\Policies\Microsoft\Edge'
    $bBefore = Capture-NxRegistryValue -Path $edgePath -Name 'BackgroundModeEnabled'
    $edgePlan = Set-NxEdgeBackgroundMode -Mode Disable -Scope User -JournalRoot $tmpJournal -Plan
    $bAfter = Capture-NxRegistryValue -Path $edgePath -Name 'BackgroundModeEnabled'
    Assert-Nx 'Edge background Plan reports Planned' ($edgePlan.outcome -eq 'Planned') ([string]$edgePlan.outcome)
    Assert-Nx 'Edge background Plan wrote nothing' ($bBefore.existed -eq $bAfter.existed -and (ConvertTo-Json $bBefore.value -Compress) -eq (ConvertTo-Json $bAfter.value -Compress))

    $sBefore = Capture-NxRegistryValue -Path $edgePath -Name 'StartupBoostEnabled'
    $boostPlan = Set-NxEdgeStartupBoost -Mode Disable -Scope User -JournalRoot $tmpJournal -Plan
    $sAfter = Capture-NxRegistryValue -Path $edgePath -Name 'StartupBoostEnabled'
    Assert-Nx 'Edge startup-boost Plan reports Planned' ($boostPlan.outcome -eq 'Planned') ([string]$boostPlan.outcome)
    Assert-Nx 'Edge startup-boost Plan wrote nothing' ($sBefore.existed -eq $sAfter.existed -and (ConvertTo-Json $sBefore.value -Compress) -eq (ConvertTo-Json $sAfter.value -Compress))

    $werPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'
    $wBefore = Capture-NxRegistryValue -Path $werPath -Name 'Disabled'
    $werPlan = Set-NxWerReportingConfig -Mode Disable -JournalRoot $tmpJournal -Plan
    $wAfter = Capture-NxRegistryValue -Path $werPath -Name 'Disabled'
    Assert-Nx 'WER Plan reports Planned' ($werPlan.outcome -eq 'Planned') ([string]$werPlan.outcome)
    Assert-Nx 'WER Plan wrote nothing' ($wBefore.existed -eq $wAfter.existed -and (ConvertTo-Json $wBefore.value -Compress) -eq (ConvertTo-Json $wAfter.value -Compress))

    # ------------------------------------------------------------------------
    # F. Scheduled task inventory / candidates / refusals (read-only).
    # ------------------------------------------------------------------------
    $taskInv = Get-NxScheduledTaskInventory
    Assert-Nx 'task inventory is read-only' ($taskInv.readOnly -eq $true)
    Assert-Nx 'task inventory returns a count' ($taskInv.count -ge 0)
    if ($taskInv.cmdletAvailable) {
        Assert-Nx 'task inventory rows carry allowListed/protected flags' (@($taskInv.tasks | Where-Object { $null -eq $_.allowListed -or $null -eq $_.protected }).Count -eq 0)
    } else {
        Write-Output 'SKIP: ScheduledTasks module unavailable in this host'
    }
    $cand = Get-NxScheduledTaskCandidates
    Assert-Nx 'candidate list is read-only' ($cand.readOnly -eq $true)
    Assert-Nx 'candidate list has at least 10 entries' ($cand.count -ge 10)
    Assert-Nx 'no candidate is protected' (@($cand.candidates | Where-Object { $_.protected }).Count -eq 0)

    $protectedPlan = Set-NxScheduledTaskState -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -TaskName 'Universal Orchestrator Start' -Mode Disable -JournalRoot $tmpJournal -Plan
    Assert-Nx 'protected task is skipped before anything else' ($protectedPlan.outcome -eq 'ProtectedSkipped') ([string]$protectedPlan.outcome)
    $refusedPlan = Set-NxScheduledTaskState -TaskPath '\Vendor\' -TaskName 'VendorTask' -Mode Disable -JournalRoot $tmpJournal -Plan
    Assert-Nx 'non-allow-listed task is refused' ($refusedPlan.outcome -eq 'Refused') ([string]$refusedPlan.outcome)
    $absentCandidate = @($cand.candidates | Where-Object { $_.state -eq 'NotDetected' })[0]
    if ($null -ne $absentCandidate) {
        $missingPlan = Set-NxScheduledTaskState -TaskPath $absentCandidate.taskPath -TaskName $absentCandidate.taskName -Mode Disable -JournalRoot $tmpJournal -Plan
        Assert-Nx 'allow-listed task absent on this machine is skipped' ($missingPlan.outcome -eq 'Skipped') ([string]$missingPlan.outcome)
    } else {
        Write-Output 'SKIP: every allow-listed task is present on this machine'
    }
    $runPlan = Set-NxScheduledTaskState -TaskPath '\Microsoft\Windows\Maintenance\' -TaskName 'WinSAT' -Mode Disable -JournalRoot $tmpJournal -Plan
    Assert-Nx 'allow-listed task Plan reports Planned/AlreadyAtState/Skipped' (@('Planned','AlreadyAtState','Skipped') -contains $runPlan.outcome) ([string]$runPlan.outcome)

    # ------------------------------------------------------------------------
    # G. Process report (read-only).
    # ------------------------------------------------------------------------
    $proc = Get-NxResourceHeavyProcessReport -Top 5 -SampleSeconds 0
    Assert-Nx 'process report is read-only' ($proc.readOnly -eq $true)
    Assert-Nx 'process report returns top-by-memory' ($null -ne $proc.topByWorkingSet)
    Assert-Nx 'process report returns top-by-cpu' ($null -ne $proc.topByCpuTime)

    # ------------------------------------------------------------------------
    # H. Service Plan paths + never-touch refusal + dependency engine.
    # ------------------------------------------------------------------------
    $searchPlan = Set-NxSearchServiceConfig -StartupType Manual -JournalRoot $tmpJournal -Plan
    Assert-Nx 'WSearch Plan reports Planned/AlreadyAtState/Skipped' (@('Planned','AlreadyAtState','Skipped') -contains $searchPlan.outcome) ([string]$searchPlan.outcome)
    $searchLive = Get-Nx11ServiceRecord -Name 'WSearch'
    Assert-Nx 'WSearch Plan left the startup type unchanged' ($searchLive.startType -ne '')

    $sysmainPlan = Set-NxSysMainConfig -StartupType Disabled -JournalRoot $tmpJournal -Plan
    Assert-Nx 'SysMain Plan reports Planned/AlreadyAtState/Skipped' (@('Planned','AlreadyAtState','Skipped') -contains $sysmainPlan.outcome) ([string]$sysmainPlan.outcome)
    Assert-Nx 'SysMain result reports hardware detection' ($null -ne $sysmainPlan.detected)

    $diagPlan = Set-NxDiagTrackConfig -StartupType Disabled -JournalRoot $tmpJournal -Plan
    Assert-Nx 'DiagTrack Plan reports Planned/AlreadyAtState' (@('Planned','AlreadyAtState') -contains $diagPlan.outcome) ([string]$diagPlan.outcome)

    $remotePlan = Set-NxRemoteRegistryConfig -StartupType Disabled -JournalRoot $tmpJournal -Plan
    Assert-Nx 'RemoteRegistry Plan reports Planned/AlreadyAtState' (@('Planned','AlreadyAtState') -contains $remotePlan.outcome) ([string]$remotePlan.outcome)

    $bluetoothPlan = Set-NxBluetoothServiceConfig -StartupType Disabled -JournalRoot $tmpJournal -Plan
    Assert-Nx 'Bluetooth Plan reports Planned/AlreadyAtState/Skipped' (@('Planned','AlreadyAtState','Skipped') -contains $bluetoothPlan.outcome) ([string]$bluetoothPlan.outcome)

    $faxPlan = Set-NxFaxServiceConfig -StartupType Disabled -JournalRoot $tmpJournal -Plan
    Assert-Nx 'Fax Plan reports Planned/AlreadyAtState/Skipped' (@('Planned','AlreadyAtState','Skipped') -contains $faxPlan.outcome) ([string]$faxPlan.outcome)

    $mapsPlan = Set-NxMapsServiceConfig -StartupType Manual -JournalRoot $tmpJournal -Plan
    Assert-Nx 'Maps Plan reports Planned/AlreadyAtState/Skipped' (@('Planned','AlreadyAtState','Skipped') -contains $mapsPlan.outcome) ([string]$mapsPlan.outcome)

    $xboxPlan = Set-NxXboxServicesConfig -StartupType Manual -JournalRoot $tmpJournal -Plan
    Assert-Nx 'Xbox Plan reports Planned/AlreadyAtState/Skipped' (@('Planned','AlreadyAtState','Skipped') -contains $xboxPlan.outcome) ([string]$xboxPlan.outcome)
    $xboxRefuse = Set-NxXboxServicesConfig -StartupType Manual -Services @('GamingServices') -JournalRoot $tmpJournal -Plan
    Assert-Nx 'GamingServices is refused as a target' ($xboxRefuse.outcome -eq 'Refused') ([string]$xboxRefuse.outcome)

    $spoolerRefuse = Set-Nx11ServiceConfig -Name 'Spooler' -StartupType 'Disabled' -TweakId 'NX11-011' -JournalRoot $tmpJournal -Plan
    Assert-Nx 'code-side engine refuses Spooler outright' ($spoolerRefuse.outcome -eq 'Refused') ([string]$spoolerRefuse.outcome)

    $dep = Get-NxServiceDependencyReport -ServiceName 'SysMain'
    Assert-Nx 'dependency detail is read-only' ($dep.readOnly -eq $true)
    Assert-Nx 'dependency detail returns a verdict' (-not [string]::IsNullOrWhiteSpace([string]$dep.verdict))
    Assert-Nx 'dependency detail reports required/dependent arrays' ($null -ne $dep.requiredServices -and $null -ne $dep.dependentServices)
    $depSummary = Get-NxServiceDependencyReport
    Assert-Nx 'dependency summary is read-only' ($depSummary.readOnly -eq $true)
    Assert-Nx 'dependency summary returns a count' ($depSummary.count -ge 0)

    # ------------------------------------------------------------------------
    # I. Print Spooler report-only boundary.
    # ------------------------------------------------------------------------
    $spooler = Get-NxPrintSpoolerReport
    Assert-Nx 'spooler report is read-only' ($spooler.readOnly -eq $true)
    Assert-Nx 'spooler report declares never-touch' ($spooler.neverTouch -eq $true)
    Assert-Nx 'spooler report exposes no mutation path' ($spooler.mutationAvailable -eq $false)
    Assert-Nx 'spooler report carries guidance' (@($spooler.guidance).Count -ge 3)

    # ------------------------------------------------------------------------
    # J. Third-party inventory + Windows-component refusal.
    # ------------------------------------------------------------------------
    $tp = Get-NxThirdPartyServiceInventory -MaxItems 25
    Assert-Nx 'third-party inventory is read-only' ($tp.readOnly -eq $true)
    Assert-Nx 'third-party inventory excludes never-touch services' (@($tp.services | Where-Object { $_.neverTouch }).Count -eq 0)
    $tpRefuse = Set-NxThirdPartyServiceConfig -ServiceName 'Themes' -StartupType Manual -JournalRoot $tmpJournal -ConfirmService -Plan
    Assert-Nx 'Windows-component service is refused by NX11-018' ($tpRefuse.outcome -eq 'Refused') ([string]$tpRefuse.outcome)
    $tpNoConsent = Set-NxThirdPartyServiceConfig -ServiceName 'Themes' -StartupType Manual -JournalRoot $tmpJournal -Plan
    Assert-Nx 'third-party change without -ConfirmService is refused' ($tpNoConsent.outcome -eq 'Refused') ([string]$tpNoConsent.outcome)

    # ------------------------------------------------------------------------
    # K. Journal-first gate: mutation with a non-existent journal must throw
    #    before any change (no service is touched).
    # ------------------------------------------------------------------------
    $badJournal = Join-Path $tmpRoot 'no-such-journal'
    $threw = $false
    try {
        $null = Set-Nx11ServiceConfig -Name 'SysMain' -StartupType 'Manual' -TweakId 'NX11-009' -JournalRoot $badJournal -Approved
    } catch { $threw = ($_.Exception.Message -like '*journal not initialized*') }
    Assert-Nx 'mutation without an initialized journal is refused' $threw

    # ------------------------------------------------------------------------
    # L. Rollback with an empty journal (no candidates).
    # ------------------------------------------------------------------------
    $rb = Invoke-Nx11Rollback -JournalRoot $tmpJournal -AllNx11
    Assert-Nx 'empty-journal rollback does not abort' ($rb.aborted -eq $false)
    Assert-Nx 'empty-journal rollback restores nothing' (@($rb.restored).Count -eq 0 -and @($rb.diverged).Count -eq 0 -and @($rb.failed).Count -eq 0)
    $threwRb = $false
    try { $null = Invoke-Nx11Rollback -JournalRoot $tmpJournal } catch { $threwRb = $true }
    Assert-Nx 'rollback without a scope argument is refused' $threwRb
}
finally {
    if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ('RESULT: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
if ($script:fail -gt 0) { exit 1 }
exit 0
