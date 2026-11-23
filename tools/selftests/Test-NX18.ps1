#Requires -Version 5.1
<#
    Test-NX18.ps1 - NX18 (Game Session Manager) category self-test.

    SAFETY BOUNDARY: no host mutation of any kind.
      - The engine and NX18 modules are dot-sourced (no side effects at load).
      - Registry/NX18.json is validated statically.
      - The protected-process guard, profile validation, plan derivation, the
        session state machine, the cooldown, the monitor heartbeat and the
        recovery replay are exercised with injected process tables, a synthetic
        topology model, temp session roots and a temp journal.
      - No session is started against a live game; Start-NxSession is called
        with -Plan only (asserted to write nothing).
      - No process, service, power plan or registry value on the host is
        touched; recovery uses an injected restore handler.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..\..'
$core = Join-Path $repo 'src\nxcore'
$sessionModule = Join-Path $repo 'src\nxsession\NX18.ps1'

$script:pass = 0
$script:fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('nx18-selftest-' + [guid]::NewGuid().ToString('N'))
$sessionRoot = Join-Path $tmp 'sessions'
$profileRoot = Join-Path $tmp 'profiles'
$journalRoot = Join-Path $tmp 'journal'
$planRoot = Join-Path $tmp 'plan-only-sessions'
New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null

function New-Nx18TestTopology {
    $cores = @(0..7 | ForEach-Object { [pscustomobject]@{ coreIndex = $_; logicalProcessors = @($_, ([int]$_ + 8)); primaryLogicalProcessor = $_ } })
    return [pscustomobject]@{
        logicalProcessorCount = 16
        isHybrid = $false
        rankingCertainty = 'NotApplicable-SingleTier'
        uncertainty = @()
        cores = $cores
        allLogicalProcessors = @(0..15)
        classPools = [ordered]@{ Standard = [pscustomobject]@{ role = 'Standard'; coreIndexes = @(0..7); logicalProcessors = @(0..15); primaryLogicalProcessors = @(0..7) } }
        cpuSetMapping = @(0..15 | ForEach-Object { [pscustomobject]@{ globalLogicalProcessor = $_; group = 0; cpuSetId = [uint32](1000 + $_) } })
        fingerprint = 'nx18-selftest'
        dies = @()
        caches = @()
    }
}

function New-Nx18TestRecord {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Jr,
        [Parameter(Mandatory)]$Plan,
        [string]$Profile = 'Test'
    )
    $r = New-Nx18SessionRecord -GameExe 'testgame.exe' -GameImageName 'testgame.exe' -ProfileName $Profile -ProfileHash 'hash' -Plan $Plan -JournalRoot $Jr -CooldownSeconds 60
    $null = Save-Nx18SessionRecord -Record $r -SessionRoot $Root
    return $r
}

try {
    . (Join-Path $core 'Import-NxCore.ps1')
    . $sessionModule

    # ------------------------------------------------------------------------
    # 0. Module surface, loader contract and forbidden-code guard
    # ------------------------------------------------------------------------
    $fns = @(
        'Test-Nx18ProtectedProcess','Get-Nx18ProtectedPolicy','Get-Nx18LauncherMapping',
        'Resolve-Nx18GameIdentity','Get-Nx18ProcessTable','Find-Nx18GameProcess',
        'Test-Nx18Profile','Read-Nx18Profile','New-Nx18SessionPlan',
        'Set-Nx18SessionCpuSetStep','Set-Nx18SessionGamePriority','Set-Nx18SessionBackgroundTrim',
        'Set-Nx18SessionPowerPlan','Set-Nx18SessionGraphicOverlay','Get-Nx18ServiceSuspensionPlan',
        'New-Nx18SessionRecord','Save-Nx18SessionRecord','Read-Nx18SessionRecord','Get-Nx18SessionRecords',
        'Set-Nx18SessionState','Test-Nx18Cooldown','Wait-Nx18SessionGameExit','Resolve-Nx18JournalRoot',
        'Restore-Nx18PowerPlanStep','Restore-Nx18VerifiedStep','Invoke-Nx18SessionRestore',
        'Start-NxSession','Stop-NxSession','Get-NxSessionStatus','Invoke-NxSessionRecovery',
        'Invoke-Nx18Rollback','Get-Nx18Capability'
    )
    $missing = @($fns | Where-Object { $null -eq (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue) })
    Assert-Nx 'all NX18 functions are defined' ($missing.Count -eq 0) ($missing -join ',')

    $moduleText = Get-Content -LiteralPath $sessionModule -Raw -Encoding UTF8
    Assert-Nx 'NX18 module self-loads NxCore when run standalone' ($moduleText -match 'Import-NxCore\.ps1' -and $moduleText -match "Add-NxJournalEntry")
    $importerText = Get-Content -LiteralPath (Join-Path $core 'Import-NxCore.ps1') -Raw -Encoding UTF8
    Assert-Nx 'Import-NxCore does not load NX18 (separate subsystem)' ($importerText -notmatch 'NX18|nxsession')
    Assert-Nx 'no process termination / suspension / launch code path' (
        ($moduleText -notmatch 'Stop-Process') -and ($moduleText -notmatch 'Suspend-Process') -and
        ($moduleText -notmatch 'taskkill') -and ($moduleText -notmatch 'Start-Process')
    )
    Assert-Nx 'no service mutation code path' (($moduleText -notmatch 'Set-Service') -and ($moduleText -notmatch 'Stop-Service') -and ($moduleText -notmatch 'sc\.exe'))

    # ------------------------------------------------------------------------
    # 1. Registry: 12 entries, schema depth, statuses, capability actions
    # ------------------------------------------------------------------------
    $schema = Get-Content (Join-Path $repo 'registry\schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cat = Get-Content (Join-Path $repo 'registry\NX18.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $tweaks = @($cat.tweaks)
    Assert-Nx 'NX18.json category id' ($cat.category -eq 'NX18')
    Assert-Nx 'NX18.json declares 12 entries' ($tweaks.Count -eq 12) ("count=$($tweaks.Count)")
    $expectedIds = @(1..12 | ForEach-Object { 'NX18-{0:000}' -f $_ })
    $actualIds = @($tweaks | ForEach-Object { $_.id })
    Assert-Nx 'all NX18-001..012 present' ((@($expectedIds | Where-Object { $actualIds -notcontains $_ })).Count -eq 0)

    $fieldIssues = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tweaks) {
        foreach ($rf in @($schema.requiredFields)) {
            if (-not $t.PSObject.Properties[$rf]) { $fieldIssues.Add("$($t.id): missing $rf") }
        }
        if (@($schema.riskClasses) -notcontains $t.risk) { $fieldIssues.Add("$($t.id): risk") }
        if (@($schema.evidenceLevels) -notcontains $t.evidence) { $fieldIssues.Add("$($t.id): evidence") }
        if (@($schema.statuses) -notcontains $t.status) { $fieldIssues.Add("$($t.id): status") }
        if (@($schema.modificationTypes) -notcontains $t.modificationType) { $fieldIssues.Add("$($t.id): modificationType") }
        if (@($schema.kinds) -notcontains $t.kind) { $fieldIssues.Add("$($t.id): kind") }
        if (@($schema.approvalModels) -notcontains $t.approval) { $fieldIssues.Add("$($t.id): approval") }
        if (-not $t.presetExcluded) { $fieldIssues.Add("$($t.id): NX18 entries must be presetExcluded") }
        if ([int]$t.builds.min -lt [int]$schema.supportedBuildRange.min -or [int]$t.builds.max -gt [int]$schema.supportedBuildRange.max) { $fieldIssues.Add("$($t.id): build range") }
        $actions = @($t.apply.actions)
        if ($actions.Count -ne 1 -or $actions[0].type -ne 'function' -or $actions[0].function -ne 'Get-Nx18Capability') {
            $fieldIssues.Add("$($t.id): apply action must be the read-only Get-Nx18Capability probe")
        } elseif ([string]$actions[0].parameters.capability -ne $t.id) {
            $fieldIssues.Add("$($t.id): capability parameter mismatch")
        }
    }
    Assert-Nx 'required fields/enums/builds/presetExcluded/capability actions valid' ($fieldIssues.Count -eq 0) ($fieldIssues -join '; ')

    $byId = @{}
    foreach ($t in $tweaks) { $byId[$t.id] = $t }
    Assert-Nx 'NX18-007 is the only Defined entry (honest service gate)' ($byId['NX18-007'].status -eq 'Defined' -and @($tweaks | Where-Object { $_.status -eq 'Defined' }).Count -eq 1)
    $advanced = @($tweaks | Where-Object { $_.risk -eq 'ADVANCED' })
    Assert-Nx 'ADVANCED entries exist and are ExplicitConsent + presetExcluded' ($advanced.Count -eq 2 -and @($advanced | Where-Object { $_.approval -ne 'ExplicitConsent' -or -not $_.presetExcluded }).Count -eq 0)
    Assert-Nx 'evidence levels match the catalogue (005/009 E1, rest E0)' ($byId['NX18-005'].evidence -eq 'E1' -and $byId['NX18-009'].evidence -eq 'E1' -and @($tweaks | Where-Object { $_.evidence -eq 'E0' }).Count -eq 10)
    $perfClaim = @($tweaks | Where-Object { (@($_.sideEffects) -join ' ') -match '(?i)\b(faster|smoother|lower latency|fps|boost)\b' })
    Assert-Nx 'no performance claims in sideEffects' ($perfClaim.Count -eq 0) (@($perfClaim | ForEach-Object { $_.id }) -join ',')
    $depIssues = @($tweaks | ForEach-Object { $t = $_; @($t.dependencies) | Where-Object { $_ -like 'NX18-*' -and $null -eq $byId[$_] } })
    Assert-Nx 'NX18 internal dependencies resolve' ($depIssues.Count -eq 0) ($depIssues -join ',')
    Assert-Nx 'NX18-005 depends on NX09-001 and NX18-004 on NX19-003' ((@($byId['NX18-005'].dependencies) -contains 'NX09-001') -and (@($byId['NX18-004'].dependencies) -contains 'NX19-003'))

    # ------------------------------------------------------------------------
    # 2. Protected-process guard (NX18-012), table-driven
    # ------------------------------------------------------------------------
    $protectedTable = @(
        @{ Name = 'EasyAntiCheat_EOS'; Category = 'AntiCheat' }, @{ Name = 'easyanticheat_eos.exe'; Category = 'AntiCheat' },
        @{ Name = 'BEService'; Category = 'AntiCheat' }, @{ Name = 'BEService_x64'; Category = 'AntiCheat' },
        @{ Name = 'vgk'; Category = 'AntiCheat' }, @{ Name = 'vgc'; Category = 'AntiCheat' }, @{ Name = 'Ricochet_x64'; Category = 'AntiCheat' },
        @{ Name = 'MsMpEng'; Category = 'Security' }, @{ Name = 'SecurityHealthService'; Category = 'Security' }, @{ Name = 'NisSrv'; Category = 'Security' },
        @{ Name = 'obs64'; Category = 'Recording' }, @{ Name = 'obs32'; Category = 'Recording' },
        @{ Name = 'Nvidia Share.exe'; Category = 'Recording' }, @{ Name = 'AMDRSServ'; Category = 'Recording' }, @{ Name = 'Medal'; Category = 'Recording' },
        @{ Name = 'audiodg'; Category = 'Audio' }, @{ Name = 'audiosrv'; Category = 'Audio' },
        @{ Name = 'iCUE'; Category = 'Peripherals' }, @{ Name = 'G HUB'; Category = 'Peripherals' }, @{ Name = 'LGHUB'; Category = 'Peripherals' },
        @{ Name = 'Razer Synapse'; Category = 'Peripherals' }, @{ Name = 'LogiOptions'; Category = 'Peripherals' },
        @{ Name = 'steam'; Category = 'Launcher' }, @{ Name = 'steamwebhelper'; Category = 'Launcher' },
        @{ Name = 'EpicGamesLauncher'; Category = 'Launcher' }, @{ Name = 'Battle.net'; Category = 'Launcher' },
        @{ Name = 'RiotClientServices'; Category = 'Launcher' }, @{ Name = 'UbisoftConnect'; Category = 'Launcher' },
        @{ Name = 'EA Desktop'; Category = 'Launcher' }, @{ Name = 'EADesktop'; Category = 'Launcher' }, @{ Name = 'Origin'; Category = 'Launcher' }
    )
    $guardFailures = New-Object System.Collections.Generic.List[string]
    foreach ($row in $protectedTable) {
        $g = Test-Nx18ProtectedProcess -ProcessName $row.Name
        if (-not $g.protected -or $g.category -ne $row.Category) { $guardFailures.Add("$($row.Name) -> protected=$($g.protected) category=$($g.category)") }
    }
    Assert-Nx 'every protected class name is guarded with the right category' ($guardFailures.Count -eq 0) ($guardFailures -join '; ')

    $allowedNames = @('explorer','chrome','firefox','msedge','Discord','slack','testgame','cs2','VALORANT-Win64-Shipping','notepad')
    $badAllowed = @($allowedNames | Where-Object { (Test-Nx18ProtectedProcess -ProcessName $_).protected })
    Assert-Nx 'ordinary apps and games are not protected' ($badAllowed.Count -eq 0) ($badAllowed -join ',')
    $policy = Get-Nx18ProtectedPolicy
    Assert-Nx 'protected policy cannot be overridden by a user allowlist' ($policy.userOverrideAllowed -eq $false -and $policy.categories.Count -eq 6)
    $guardParams = @((Get-Command -Name 'Test-Nx18ProtectedProcess').Parameters.Keys)
    $overrideLike = @($guardParams | Where-Object { $_ -match '(?i)allow|override|exclude|white|except' })
    Assert-Nx 'guard accepts only a process name (no allowlist/override parameter)' ($guardParams -contains 'ProcessName' -and $overrideLike.Count -eq 0) ($overrideLike -join ',')
    $launcherMap = Get-Nx18LauncherMapping
    Assert-Nx 'launcher mapping is detection-only' ($launcherMap.readOnly -eq $true -and $launcherMap.managed -eq $false -and @($launcherMap.entries).Count -ge 8)

    # guard is enforced again at every mutation boundary (no engine call happens)
    $trimRefused = Set-Nx18SessionBackgroundTrim -ProcessName 'obs64' -PriorityClass 'BelowNormal' -JournalRoot (Join-Path $tmp 'never-created-journal')
    Assert-Nx 'background trim refuses a protected app before any journal/engine call' ($trimRefused.refused -eq $true -and $trimRefused.terminationPerformed -eq $false -and $trimRefused.suspensionPerformed -eq $false -and -not (Test-Path (Join-Path $tmp 'never-created-journal')))
    $cpuRefused = Set-Nx18SessionCpuSetStep -ProcessName 'vgk' -CpuSetIds @(1000) -JournalRoot (Join-Path $tmp 'never-created-journal')
    Assert-Nx 'CPU-set wrapper refuses a protected anti-cheat process' ($cpuRefused.refused -eq $true -and @($cpuRefused.processes).Count -eq 0)
    $prioRefused = Set-Nx18SessionGamePriority -ProcessName 'MsMpEng' -PriorityClass 'BelowNormal' -JournalRoot (Join-Path $tmp 'never-created-journal')
    Assert-Nx 'game-priority wrapper refuses a protected security process' ($prioRefused.refused -eq $true)
    $dispatcherRefused = $false
    try {
        $null = Invoke-Nx18PlanStep -Step ([pscustomobject]@{ stepId = 'S99'; tweakId = 'NX18-009'; targetType = 'processPriority'; processName = 'EasyAntiCheat_EOS'; parameters = [pscustomobject]@{ priorityClass = 'Idle' } }) -JournalRoot (Join-Path $tmp 'never-created-journal')
    } catch { $dispatcherRefused = $true }
    Assert-Nx 'apply dispatcher refuses a protected process step' $dispatcherRefused

    # ------------------------------------------------------------------------
    # 3. Profile validation (NX18-003)
    # ------------------------------------------------------------------------
    $validProfile = [pscustomobject]@{
        schemaVersion = 1
        profileName = 'Test'
        scheduling = [pscustomobject]@{ cpuSetProfile = 'Balanced' }
        priority = [pscustomobject]@{ gamePriorityClass = 'AboveNormal' }
        power = [pscustomobject]@{ targetPlan = 'High performance' }
        backgroundApps = @(
            [pscustomobject]@{ processName = 'chrome'; priorityClass = 'BelowNormal'; mode = 'PriorityTrim' },
            [pscustomobject]@{ processName = 'discord'; priorityClass = 'Idle'; mode = 'PriorityTrim' }
        )
        graphics = [pscustomobject]@{ registry = @([pscustomobject]@{ path = 'HKCU:\Software\NEXTRIX\Session'; name = 'TestOverlay'; kind = 'DWord'; value = 1 }) }
    }
    $pv = Test-Nx18Profile -Profile $validProfile -Name 'Test'
    Assert-Nx 'valid profile accepted' ($pv.valid -eq $true) ($pv.issues -join '; ')

    $protectedApp = [pscustomobject]@{ schemaVersion = 1; profileName = 'Bad'; backgroundApps = @([pscustomobject]@{ processName = 'obs64'; priorityClass = 'BelowNormal' }) }
    $pv1 = Test-Nx18Profile -Profile $protectedApp -Name 'Bad'
    Assert-Nx 'protected background app rejected' ($pv1.valid -eq $false -and (@($pv1.issues) -join ' ') -match 'protected')

    $highPriority = [pscustomobject]@{ schemaVersion = 1; profileName = 'Bad'; priority = [pscustomobject]@{ gamePriorityClass = 'High' } }
    $pv2 = Test-Nx18Profile -Profile $highPriority -Name 'Bad'
    Assert-Nx 'High/RealTime game priority rejected' ($pv2.valid -eq $false)

    $bannedValue = [pscustomobject]@{ schemaVersion = 1; profileName = 'Bad'; graphics = [pscustomobject]@{ registry = @([pscustomobject]@{ path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; name = 'EnableLUA'; kind = 'DWord'; value = 0 }) } }
    $pv3 = Test-Nx18Profile -Profile $bannedValue -Name 'Bad'
    Assert-Nx 'banned registry value name rejected' ($pv3.valid -eq $false -and (@($pv3.issues) -join ' ') -match 'banned')

    $systemPath = [pscustomobject]@{ schemaVersion = 1; profileName = 'Bad'; graphics = [pscustomobject]@{ registry = @([pscustomobject]@{ path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Test'; name = 'X'; kind = 'DWord'; value = 1 }) } }
    $pv4 = Test-Nx18Profile -Profile $systemPath -Name 'Bad'
    Assert-Nx 'HKLM:\SYSTEM registry path rejected' ($pv4.valid -eq $false)

    $controlSet = [pscustomobject]@{ schemaVersion = 1; profileName = 'Bad'; graphics = [pscustomobject]@{ registry = @([pscustomobject]@{ path = 'HKCU:\ControlSet001\Test'; name = 'X'; kind = 'DWord'; value = 1 }) } }
    $pv5 = Test-Nx18Profile -Profile $controlSet -Name 'Bad'
    Assert-Nx 'ControlSet001/002 path rejected' ($pv5.valid -eq $false)

    $duplicateTarget = [pscustomobject]@{ schemaVersion = 1; profileName = 'Bad'; graphics = [pscustomobject]@{ registry = @(
        [pscustomobject]@{ path = 'HKCU:\Software\X'; name = 'Y'; kind = 'DWord'; value = 1 },
        [pscustomobject]@{ path = 'HKCU:\Software\X'; name = 'Y'; kind = 'DWord'; value = 2 }
    ) } }
    $pv6 = Test-Nx18Profile -Profile $duplicateTarget -Name 'Bad'
    Assert-Nx 'duplicate registry overlay target rejected' ($pv6.valid -eq $false)

    $traversal = Read-Nx18Profile -ProfileName '..\evil' -ProfileRoot $profileRoot
    Assert-Nx 'profile name traversal rejected' ($traversal.valid -eq $false -and $traversal.found -eq $false)
    $absent = Read-Nx18Profile -ProfileName 'DoesNotExist' -ProfileRoot (Join-Path $tmp 'no-profiles-here')
    Assert-Nx 'missing profile refused without creating anything' ($absent.valid -eq $false -and -not (Test-Path (Join-Path $tmp 'no-profiles-here')))

    # file-based profile round trip used by the plan-mode test
    $validProfile | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $profileRoot 'Test.json') -Encoding UTF8

    # ------------------------------------------------------------------------
    # 4. Plan derivation (NX18-004..009) and -Plan writes nothing
    # ------------------------------------------------------------------------
    $topology = New-Nx18TestTopology
    $plan = New-Nx18SessionPlan -Profile $validProfile -GameImageName 'testgame.exe' -Topology $topology
    Assert-Nx 'plan derives CPU set IDs from the NX19 map (no literals)' (
        $plan.steps[0].tweakId -eq 'NX18-004' -and @($plan.steps[0].parameters.cpuSetIds).Count -eq 16 -and
        @($plan.steps[0].parameters.cpuSetIds)[0] -eq 1000 -and @($plan.steps[0].parameters.cpuSetIds)[15] -eq 1015 -and
        @($plan.steps[0].parameters.logicalProcessors) -contains 3
    )
    Assert-Nx 'plan includes game priority, two background trims, power and registry steps' (
        @($plan.steps | Where-Object { $_.tweakId -eq 'NX18-009' }).Count -eq 1 -and
        @($plan.steps | Where-Object { $_.tweakId -eq 'NX18-006' }).Count -eq 2 -and
        @($plan.steps | Where-Object { $_.tweakId -eq 'NX18-005' }).Count -eq 1 -and
        @($plan.steps | Where-Object { $_.tweakId -eq 'NX18-008' }).Count -eq 1
    )
    $planNoTopology = New-Nx18SessionPlan -Profile $validProfile -GameImageName 'testgame.exe' -Topology ([pscustomobject]@{})
    $cpuStep = @($planNoTopology.steps | Where-Object { $_.tweakId -eq 'NX18-004' })[0]
    Assert-Nx 'unavailable topology marks the CPU step Unavailable with no fabricated IDs' (
        $cpuStep.preflight -eq 'Unavailable' -and @($cpuStep.parameters.cpuSetIds).Count -eq 0 -and [bool]$cpuStep.reason
    )
    $emptyProfile = [pscustomobject]@{ schemaVersion = 1; profileName = 'Empty' }
    $emptyPlan = New-Nx18SessionPlan -Profile $emptyProfile -GameImageName 'testgame.exe' -Topology $topology
    Assert-Nx 'profile with no declarations yields zero steps' ($emptyPlan.stepCount -eq 0)
    $notNeeded = Get-Nx18StepOutcome -Step ([pscustomobject]@{ stepId = 'S09'; tweakId = 'NX18-005'; targetType = 'powerPlanSelection'; processName = $null }) -EngineResult ([pscustomobject]@{ outcome = 'AlreadyAtState'; reason = 'active plan already equals the session target' })
    Assert-Nx 'already-at-state power step is NotNeeded (does not stop later steps)' ($notNeeded.status -eq 'NotNeeded' -and $notNeeded.verified -eq $false)

    $processTable = @(
        [pscustomobject]@{ id = 100; processName = 'steamwebhelper.exe'; parentId = 50 },
        [pscustomobject]@{ id = 4200; processName = 'testgame.exe'; parentId = 100 }
    )
    $planRun = Start-NxSession -GameExe 'testgame.exe' -ProfileName 'Test' -Plan -SessionRoot $planRoot -ProfileRoot $profileRoot -JournalRoot (Join-Path $tmp 'plan-journal') -Topology $topology -ProcessTable $processTable
    Assert-Nx '-Plan reports wrote=false and the plan' ($planRun.plan -eq $true -and $planRun.wrote -eq $false -and $planRun.sessionPlan.readyCount -ge 5)
    Assert-Nx '-Plan writes no session record and no journal directory' (-not (Test-Path -LiteralPath $planRoot) -and -not (Test-Path -LiteralPath (Join-Path $tmp 'plan-journal')))
    $planRun2 = Start-NxSession -GameExe 'testgame.exe' -ProfileName 'Test' -Plan -SessionRoot (Join-Path $tmp 'plan-root-2') -ProfileRoot $profileRoot -JournalRoot (Join-Path $tmp 'plan-journal-2') -Topology $topology -ProcessTable @()
    Assert-Nx '-Plan with no running game still plans and writes nothing' ($planRun2.detected -eq $false -and $planRun2.sessionPlan.stepCount -ge 5 -and -not (Test-Path (Join-Path $tmp 'plan-root-2')))

    # ------------------------------------------------------------------------
    # 5. Detection & launcher mapping (NX18-001/002)
    # ------------------------------------------------------------------------
    $det = Find-Nx18GameProcess -GameExe 'testgame.exe' -ProcessTable $processTable
    Assert-Nx 'running game detected with PID' ($det.matched -eq $true -and @($det.processes).Count -eq 1 -and $det.processes[0].id -eq 4200)
    Assert-Nx 'launcher ancestor mapped and protected' (@($det.launchers).Count -eq 1 -and $det.launchers[0].processName -eq 'steamwebhelper.exe' -and $det.launchers[0].protected -eq $true)
    $detEmpty = Find-Nx18GameProcess -GameExe 'testgame.exe' -ProcessTable @()
    Assert-Nx 'absent game reports matched=false (never launched)' ($detEmpty.matched -eq $false -and [bool]$detEmpty.reason)
    $detProtected = Find-Nx18GameProcess -GameExe 'steam.exe' -ProcessTable $processTable
    Assert-Nx 'protected launcher rejected as a session game' ($detProtected.valid -eq $false -and $detProtected.matched -eq $false)
    $detPath = Find-Nx18GameProcess -GameExe 'C:\Games\Test Game\testgame.exe' -ProcessTable $processTable
    Assert-Nx 'full path input resolves to the same process' ($detPath.matched -eq $true -and $detPath.imageName -eq 'testgame.exe')

    # ------------------------------------------------------------------------
    # 6. Session record lifecycle state machine (temp SessionRoot only)
    # ------------------------------------------------------------------------
    $record = New-Nx18TestRecord -Root $sessionRoot -Jr $journalRoot -Plan $plan
    $recordFile = Join-Path $sessionRoot ('session-' + $record.sessionId + '.json')
    Assert-Nx 'session record file follows session-<guid>.json' (Test-Path -LiteralPath $recordFile)
    $badFilePathRejected = $false
    try { $null = Get-Nx18SessionFilePath -SessionId '..\evil' -SessionRoot $sessionRoot } catch { $badFilePathRejected = $true }
    Assert-Nx 'session id path traversal rejected' $badFilePathRejected
    $jrExplicit = Resolve-Nx18JournalRoot -Record $record -Explicit $journalRoot
    $jrOutside = Resolve-Nx18JournalRoot -Record ([pscustomobject]@{ journalRoot = 'C:\Windows\Temp\not-ours' }) -Explicit ''
    $nxParent = Split-Path (Get-Nx18DefaultJournalRoot) -Parent
    $jrInside = Resolve-Nx18JournalRoot -Record ([pscustomobject]@{ journalRoot = (Join-Path $nxParent 'Journal\probe') }) -Explicit ''
    Assert-Nx 'journal root resolution: explicit wins, outside-NEXTRIX record path ignored' (
        $jrExplicit -eq $journalRoot -and $jrOutside -eq (Get-Nx18DefaultJournalRoot) -and
        $jrInside -eq [IO.Path]::GetFullPath((Join-Path $nxParent 'Journal\probe'))
    )
    $rawRecord = Get-Content -LiteralPath $recordFile -Raw -Encoding UTF8
    Assert-Nx 'record timestamps survive JSON round-trip (no /Date())' ($rawRecord -notmatch '/Date\(' -and $rawRecord -match 'createdAtUtc')

    $null = Set-Nx18SessionState -Record $record -NewState 'applied' -SessionRoot $sessionRoot
    $null = Set-Nx18SessionState -Record $record -NewState 'monitoring' -SessionRoot $sessionRoot
    Assert-Nx 'planned -> applied -> monitoring accepted' ($record.state -eq 'monitoring')
    $illegal = $false
    try { $null = Set-Nx18SessionState -Record $record -NewState 'completed' -SessionRoot $sessionRoot } catch { $illegal = $true }
    Assert-Nx 'monitoring -> completed is illegal' $illegal
    $null = Set-Nx18SessionState -Record $record -NewState 'restoring' -SessionRoot $sessionRoot
    $null = Set-Nx18SessionState -Record $record -NewState 'completed' -SessionRoot $sessionRoot -CompletionKind 'Normal'
    Assert-Nx 'restoring -> completed with completion kind' ($record.state -eq 'completed' -and $record.completionKind -eq 'Normal' -and [bool]$record.cooldownUntilUnixMs)
    $terminalIllegal = $false
    try { $null = Set-Nx18SessionState -Record $record -NewState 'applied' -SessionRoot $sessionRoot } catch { $terminalIllegal = $true }
    Assert-Nx 'terminal state is final' $terminalIllegal

    # crash path: monitoring -> interrupted, read back from disk, then terminal
    $crashRecord = New-Nx18TestRecord -Root $sessionRoot -Jr $journalRoot -Plan $plan
    $null = Set-Nx18SessionState -Record $crashRecord -NewState 'applied' -SessionRoot $sessionRoot
    $null = Set-Nx18SessionState -Record $crashRecord -NewState 'monitoring' -SessionRoot $sessionRoot
    $null = Set-Nx18SessionState -Record $crashRecord -NewState 'interrupted' -SessionRoot $sessionRoot
    $crashRead = Read-Nx18SessionRecord -SessionId $crashRecord.sessionId -SessionRoot $sessionRoot
    Assert-Nx 'interrupted record persists and is terminal' ($crashRead.found -eq $true -and $crashRead.record.state -eq 'interrupted' -and $crashRead.record.completionKind -eq 'Interrupted')
    $stateAfterRead = $false
    try { $null = Set-Nx18SessionState -Record $crashRead.record -NewState 'completed' -SessionRoot $sessionRoot } catch { $stateAfterRead = $true }
    Assert-Nx 'state machine still rejects after a JSON round-trip' $stateAfterRead

    # ------------------------------------------------------------------------
    # 7. Cooldown (FSOS-X R8 guard)
    # ------------------------------------------------------------------------
    $now = Get-Nx18UtcNowMs
    $cooldownRecent = Test-Nx18Cooldown -SessionRoot $sessionRoot -CooldownSeconds 60 -NowUnixMs $now
    Assert-Nx 'recent terminal session blocks a new session' ($cooldownRecent.allowed -eq $false -and $cooldownRecent.reason -eq 'Cooldown' -and $cooldownRecent.remainingSeconds -gt 0)
    $cooldownElapsed = Test-Nx18Cooldown -SessionRoot $sessionRoot -CooldownSeconds 60 -NowUnixMs ($now + 61000)
    Assert-Nx 'cooldown elapses' ($cooldownElapsed.allowed -eq $true)
    $activeRoot = Join-Path $tmp 'cooldown-active'
    $activeRecord = New-Nx18TestRecord -Root $activeRoot -Jr $journalRoot -Plan $plan
    $cooldownActive = Test-Nx18Cooldown -SessionRoot $activeRoot -CooldownSeconds 60
    Assert-Nx 'an active session blocks a second session' ($cooldownActive.allowed -eq $false -and $cooldownActive.reason -eq 'ActiveSession' -and $cooldownActive.activeSessionId -eq $activeRecord.sessionId)
    $noHistory = Test-Nx18Cooldown -SessionRoot (Join-Path $tmp 'no-sessions-here')
    Assert-Nx 'no history allows the first session' ($noHistory.allowed -eq $true -and $noHistory.reason -eq 'NoSessionHistory')

    # ------------------------------------------------------------------------
    # 8. Monitor heartbeat / exit detection (injected probe, no host process)
    # ------------------------------------------------------------------------
    $monitorRoot = Join-Path $tmp 'monitor'
    $monitorRecord = New-Nx18TestRecord -Root $monitorRoot -Jr $journalRoot -Plan $plan
    $null = Set-Nx18SessionState -Record $monitorRecord -NewState 'applied' -SessionRoot $monitorRoot
    $null = Set-Nx18SessionState -Record $monitorRecord -NewState 'monitoring' -SessionRoot $monitorRoot
    $wait = Wait-Nx18SessionGameExit -Record $monitorRecord -SessionRoot $monitorRoot -PollSeconds 0 -ProcessProbe { param($cycle) return ($cycle -le 2) }
    $monitorRead = Read-Nx18SessionRecord -SessionId $monitorRecord.sessionId -SessionRoot $monitorRoot
    Assert-Nx 'monitor detects exit and stamps a heartbeat per live cycle' ($wait.exited -eq $true -and $wait.cycles -eq 3 -and [bool]$monitorRead.record.heartbeatUnixMs)

    # ------------------------------------------------------------------------
    # 9. Recovery replay: verified steps only, reverse order, tamper refusal
    # ------------------------------------------------------------------------
    $null = Initialize-NxJournal -Path $journalRoot | Out-Null
    $recoveryRoot = Join-Path $tmp 'recovery'
    $rr = New-Nx18TestRecord -Root $recoveryRoot -Jr $journalRoot -Plan $plan
    $null = Set-Nx18SessionState -Record $rr -NewState 'applied' -SessionRoot $recoveryRoot
    $null = Set-Nx18SessionState -Record $rr -NewState 'monitoring' -SessionRoot $recoveryRoot
    $rr.verifiedSteps = @(
        [pscustomobject]@{ stepId = 'S01'; tweakId = 'NX18-004'; targetType = 'processCpuSets'; processName = 'testgame.exe'; mechanism = $null },
        [pscustomobject]@{ stepId = 'S02'; tweakId = 'NX18-005'; targetType = 'powerPlanSelection'; mechanism = 'powerPlanSelection'; originalSchemeGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'; modifiedSchemeGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
    )
    $rr.applyResult = @([pscustomobject]@{ stepId = 'S03'; status = 'Failed'; detail = 'simulated: never verified' })
    $null = Save-Nx18SessionRecord -Record $rr -SessionRoot $recoveryRoot
    $script:restoreOrder = New-Object System.Collections.Generic.List[string]
    $handler = {
        param($step)
        $script:restoreOrder.Add([string]$step.stepId)
        return [pscustomobject]@{ stepId = $step.stepId; tweakId = $step.tweakId; restored = @([pscustomobject]@{ ok = $true }); diverged = @(); failed = @(); irreversible = @(); verified = $true }
    }
    $recovery = Invoke-NxSessionRecovery -SessionRoot $recoveryRoot -JournalRoot $journalRoot -RestoreHandler $handler
    $rrRead = Read-Nx18SessionRecord -SessionId $rr.sessionId -SessionRoot $recoveryRoot
    Assert-Nx 'recovery restores only verified steps in reverse order' (($script:restoreOrder -join ',') -eq 'S02,S01') ("order=$($script:restoreOrder -join ',')")
    Assert-Nx 'recovery marks the record recovered' ($recovery.aborted -eq $false -and $recovery.recovered -eq 1 -and $rrRead.record.state -eq 'completed' -and $rrRead.record.completionKind -eq 'Recovered' -and [bool]$rrRead.record.recoveredAtUtc)

    # a failed apply step is never restored even when it is listed in applyResult
    Assert-Nx 'failed/unverified step (S03) was not restored' (@($script:restoreOrder) -notcontains 'S03')

    # WhatIf must not change state
    $whatIfRoot = Join-Path $tmp 'recovery-whatif'
    $wr = New-Nx18TestRecord -Root $whatIfRoot -Jr $journalRoot -Plan $plan
    $null = Set-Nx18SessionState -Record $wr -NewState 'applied' -SessionRoot $whatIfRoot
    $wi = Invoke-NxSessionRecovery -SessionRoot $whatIfRoot -JournalRoot $journalRoot -WhatIf
    $wrRead = Read-Nx18SessionRecord -SessionId $wr.sessionId -SessionRoot $whatIfRoot
    Assert-Nx 'recovery WhatIf reports and changes no record' ($wi.aborted -eq $false -and $wi.records[0].outcome -eq 'WouldRecover' -and $wrRead.record.state -eq 'applied')

    # tampered journal: refuse without touching any record
    $tamperRoot = Join-Path $tmp 'recovery-tamper'
    $tr = New-Nx18TestRecord -Root $tamperRoot -Jr $journalRoot -Plan $plan
    $null = Set-Nx18SessionState -Record $tr -NewState 'applied' -SessionRoot $tamperRoot
    $tr.verifiedSteps = @([pscustomobject]@{ stepId = 'S01'; tweakId = 'NX18-009'; targetType = 'processPriority'; processName = 'testgame.exe'; mechanism = $null })
    $null = Save-Nx18SessionRecord -Record $tr -SessionRoot $tamperRoot
    $null = Add-NxJournalEntry -Path $journalRoot -TweakId 'NX18-011' -TweakVersion '1' -Operation 'skip' -Approval 'SessionApproved' -Original ([pscustomobject]@{ targetType = 'none' }) -Modified ([pscustomobject]@{ targetType = 'none' })
    $journalLines = @(Get-Content -LiteralPath (Join-Path $journalRoot 'journal.jsonl') -Encoding UTF8)
    $journalLines[$journalLines.Count - 1] = $journalLines[$journalLines.Count - 1] -replace '"result":"Success"', '"result":"Tampered"'
    Set-Content -LiteralPath (Join-Path $journalRoot 'journal.jsonl') -Value $journalLines -Encoding UTF8
    $script:tamperCalls = 0
    $tamper = Invoke-NxSessionRecovery -SessionRoot $tamperRoot -JournalRoot $journalRoot -RestoreHandler { param($s) $script:tamperCalls++; return [pscustomobject]@{ restored = @(); diverged = @(); failed = @(); irreversible = @(); verified = $true } }
    $trRead = Read-Nx18SessionRecord -SessionId $tr.sessionId -SessionRoot $tamperRoot
    Assert-Nx 'tampered journal aborts recovery and touches no record' ($tamper.aborted -eq $true -and @($tamper.integrityErrors).Count -gt 0 -and $script:tamperCalls -eq 0 -and $trRead.record.state -eq 'applied')

    # missing journal: refuse that record, leave it non-terminal
    $missingRoot = Join-Path $tmp 'recovery-missing-journal'
    $mr = New-Nx18TestRecord -Root $missingRoot -Jr (Join-Path $tmp 'journal-not-there') -Plan $plan
    $null = Set-Nx18SessionState -Record $mr -NewState 'applied' -SessionRoot $missingRoot
    $missing = Invoke-NxSessionRecovery -SessionRoot $missingRoot -JournalRoot (Join-Path $tmp 'journal-not-there')
    $mrRead = Read-Nx18SessionRecord -SessionId $mr.sessionId -SessionRoot $missingRoot
    Assert-Nx 'missing journal is refused without guessing' ($missing.refused -eq 1 -and $mrRead.record.state -eq 'applied' -and $missing.records[0].outcome -eq 'Refused')

    # no non-terminal records
    $terminalOnly = Join-Path $tmp 'recovery-none'
    $nr = New-Nx18TestRecord -Root $terminalOnly -Jr $journalRoot -Plan $plan
    $null = Set-Nx18SessionState -Record $nr -NewState 'completed' -SessionRoot $terminalOnly
    $none = Invoke-NxSessionRecovery -SessionRoot $terminalOnly -JournalRoot $journalRoot
    Assert-Nx 'recovery with no non-terminal records is a no-op' ($none.recovered -eq 0 -and $none.reason -match 'no non-terminal')

    $corruptRoot = Join-Path $tmp 'corrupt-record'
    New-Item -ItemType Directory -Path $corruptRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $corruptRoot ('session-' + [guid]::NewGuid().ToString('D') + '.json')) -Value 'this is not json' -Encoding UTF8
    $corruptScan = Get-Nx18SessionRecords -SessionRoot $corruptRoot
    $corruptRecovery = Invoke-NxSessionRecovery -SessionRoot $corruptRoot -JournalRoot $journalRoot
    Assert-Nx 'an unreadable session record is reported, not silently ignored' (@($corruptScan.unreadable).Count -eq 1 -and @($corruptScan.records).Count -eq 0 -and @($corruptRecovery.unreadable).Count -eq 1)

    # ------------------------------------------------------------------------
    # 10. Manual control status / stop semantics
    # ------------------------------------------------------------------------
    $status = Get-NxSessionStatus -SessionId $rr.sessionId -SessionRoot $recoveryRoot
    Assert-Nx 'status reports the recovered session' ($status.found -eq $true -and $status.state -eq 'completed' -and $status.terminal -eq $true -and $status.verifiedStepCount -eq 2)
    $list = Get-NxSessionStatus -SessionRoot $recoveryRoot
    Assert-Nx 'status lists terminal sessions' ($list.found -eq $true -and @($list.terminal).Count -ge 1)
    $stop = Stop-NxSession -SessionId $rr.sessionId -SessionRoot $recoveryRoot -JournalRoot $journalRoot
    Assert-Nx 'Stop-NxSession on a terminal session is a no-op' ($stop.alreadyTerminal -eq $true -and $stop.restored -eq 0)

    $stopRoot = Join-Path $tmp 'manual-stop'
    $stopJournal = Join-Path $tmp 'journal-clean'
    $null = Initialize-NxJournal -Path $stopJournal | Out-Null
    $sr2 = New-Nx18TestRecord -Root $stopRoot -Jr $stopJournal -Plan $plan
    $null = Set-Nx18SessionState -Record $sr2 -NewState 'applied' -SessionRoot $stopRoot
    $null = Set-Nx18SessionState -Record $sr2 -NewState 'monitoring' -SessionRoot $stopRoot
    $sr2.verifiedSteps = @(
        [pscustomobject]@{ stepId = 'S01'; tweakId = 'NX18-009'; targetType = 'processPriority'; processName = 'testgame.exe' },
        [pscustomobject]@{ stepId = 'S02'; tweakId = 'NX18-008'; targetType = 'registry' }
    )
    $null = Save-Nx18SessionRecord -Record $sr2 -SessionRoot $stopRoot
    $script:stopOrder = New-Object System.Collections.Generic.List[string]
    $stopResult = Stop-NxSession -SessionId $sr2.sessionId -SessionRoot $stopRoot -JournalRoot $stopJournal -RestoreHandler {
        param($step)
        $script:stopOrder.Add([string]$step.stepId)
        return [pscustomobject]@{ stepId = $step.stepId; tweakId = $step.tweakId; restored = @([pscustomobject]@{ ok = $true }); diverged = @(); failed = @(); irreversible = @(); verified = $true }
    }
    $sr2Read = Read-Nx18SessionRecord -SessionId $sr2.sessionId -SessionRoot $stopRoot
    Assert-Nx 'Stop-NxSession restores verified steps in reverse and marks ManualStop' ($stopResult.restored -eq 2 -and ($script:stopOrder -join ',') -eq 'S02,S01' -and $sr2Read.record.state -eq 'completed' -and $sr2Read.record.completionKind -eq 'ManualStop')

    $tamperedStopRoot = Join-Path $tmp 'manual-stop-tampered'
    $tsr = New-Nx18TestRecord -Root $tamperedStopRoot -Jr $journalRoot -Plan $plan
    $null = Set-Nx18SessionState -Record $tsr -NewState 'applied' -SessionRoot $tamperedStopRoot
    $null = Set-Nx18SessionState -Record $tsr -NewState 'monitoring' -SessionRoot $tamperedStopRoot
    $tamperedStop = Stop-NxSession -SessionId $tsr.sessionId -SessionRoot $tamperedStopRoot -JournalRoot $journalRoot
    $tsrRead = Read-Nx18SessionRecord -SessionId $tsr.sessionId -SessionRoot $tamperedStopRoot
    Assert-Nx 'Stop-NxSession refuses a tampered journal and leaves the session open' ($tamperedStop.aborted -eq $true -and @($tamperedStop.integrityErrors).Count -gt 0 -and $tsrRead.record.state -eq 'monitoring')

    # ------------------------------------------------------------------------
    # 11. Service suspension is Defined (plan-only) and capability probe
    # ------------------------------------------------------------------------
    $svcPlan = Get-Nx18ServiceSuspensionPlan -Services @('Audiosrv','DiagTrack','WinDefend')
    Assert-Nx 'service suspension is plan-only and touches no service' ($svcPlan.readOnly -eq $true -and $svcPlan.implemented -eq $false -and $svcPlan.servicesTouched -eq 0)
    $audioRow = @($svcPlan.entries | Where-Object { $_.service -eq 'Audiosrv' })[0]
    $trackRow = @($svcPlan.entries | Where-Object { $_.service -eq 'DiagTrack' })[0]
    Assert-Nx 'never-touch service classified and blocked' ($audioRow.neverTouch -eq $true -and $audioRow.eligible -eq $false -and $trackRow.eligible -eq $false)

    $caps = @()
    foreach ($n in 1..12) {
        $cid = 'NX18-{0:000}' -f $n
        $caps += Get-Nx18Capability -Capability $cid
    }
    Assert-Nx 'capability probe covers 001..012 and marks 007 not implemented' (
        @($caps).Count -eq 12 -and @($caps | Where-Object { $_.implemented -eq $false }).Count -eq 1 -and
        (@($caps | Where-Object { $_.implemented -eq $false })[0].capability -eq 'NX18-007')
    )
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ("RESULT: " + $(if ($script:fail -eq 0) { 'PASSED' } else { 'FAILED' }) + " - $script:pass passed, $script:fail failed")
if ($script:fail -gt 0) { exit 1 }
exit 0
