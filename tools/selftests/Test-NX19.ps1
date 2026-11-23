#Requires -Version 5.1
<#
    Test-NX19.ps1 - NX19 (CPU Topology & Scheduling) category self-test.

    SAFETY BOUNDARY (directive Section 16):
      - Synthetic byte buffers only: the topology parsers, model, derivation,
        profile and custom-rule logic are exercised without touching any API.
      - One READ-ONLY live topology probe (Get-NxTopologyReport) is allowed and
        expected; it changes nothing.
      - The process-application functions are exercised with -WhatIf or with
        inputs that are refused before any handle is opened. NO process affinity,
        CPU set or priority is changed on this machine, and NO journal is written
        (the temp path is asserted absent).
      - Nothing is installed, downloaded or persisted. The only filesystem access
        is reading the repository files named below; the temp directory is never
        created by a mutation path.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..\..'
$core = Join-Path $repo 'src\nxcore'
foreach ($m in 'NxJournal.ps1', 'NxBuild.ps1', 'NxVerify.ps1', 'NxHardware.ps1', 'NxCompat.ps1', 'NxRollback.ps1', 'NxApply.ps1') {
    . (Join-Path $core $m)
}
. (Join-Path $core 'functions\NX19.ps1')

$script:pass = 0
$script:fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$tmpJournal = Join-Path ([IO.Path]::GetTempPath()) ('nx19-selftest-' + [guid]::NewGuid().ToString('N'))

# ---------------------------------------------------------------------------
# Synthetic buffer builders (documented struct offsets; no API calls)
# ---------------------------------------------------------------------------

function New-Nx19TestMask {
    param([int[]]$Indexes)
    $m = [uint64]0
    foreach ($i in @($Indexes)) {
        $m = $m -bor [uint64][math]::Pow(2, $i)
    }
    return $m
}

function New-Nx19TestGroupSpec {
    param([int]$Group, [int[]]$Indexes)
    return @{ Group = $Group; Mask = (New-Nx19TestMask -Indexes $Indexes) }
}

function New-Nx19TestLpEntry {
    param([int]$Relationship, [hashtable]$Spec)
    $ptr = [IntPtr]::Size
    $stride = $ptr + 8
    $groups = @($Spec.Groups)
    $size = 32 + ($groups.Count * $stride)
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    try {
        $w.Write([uint32]$Relationship)
        $w.Write([uint32]$size)
        $w.Write([byte]$Spec.Flags)
        $w.Write([byte]$Spec.EfficiencyClass)
        $w.Write([uint16]$Spec.RelativePerformance)
        $w.Write([uint16]$Spec.RelativeEfficiency)
        $w.Write((New-Object byte[] 16))
        $w.Write([uint16]$groups.Count)
        foreach ($g in $groups) {
            if ($ptr -eq 8) { $w.Write([uint64]$g.Mask) } else { $w.Write([uint32]$g.Mask) }
            $w.Write([uint16]$g.Group)
            $w.Write((New-Object byte[] 6))
        }
        $w.Flush()
        $bytes = $ms.ToArray()
        return $bytes
    } finally {
        $w.Dispose()
        $ms.Dispose()
    }
}

function New-Nx19TestCacheEntry {
    param([int]$Level, [uint32]$CacheSize, [int]$Type, [hashtable[]]$Groups)
    $ptr = [IntPtr]::Size
    $stride = $ptr + 8
    $groups = @($Groups)
    $size = 40 + ($groups.Count * $stride)
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    try {
        $w.Write([uint32]2)
        $w.Write([uint32]$size)
        $w.Write([byte]$Level)
        $w.Write([byte]8)
        $w.Write([uint16]64)
        $w.Write([uint32]$CacheSize)
        $w.Write([uint32]$Type)
        $w.Write((New-Object byte[] 18))
        $w.Write([uint16]$groups.Count)
        foreach ($g in $groups) {
            if ($ptr -eq 8) { $w.Write([uint64]$g.Mask) } else { $w.Write([uint32]$g.Mask) }
            $w.Write([uint16]$g.Group)
            $w.Write((New-Object byte[] 6))
        }
        $w.Flush()
        return $ms.ToArray()
    } finally {
        $w.Dispose()
        $ms.Dispose()
    }
}

function New-Nx19TestCpuSetEntry {
    param([uint32]$Id, [uint16]$Group, [byte]$LpIndex, [byte]$EfficiencyClass = 0, [uint32]$Type = 0)
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    try {
        $w.Write([uint32]48)
        $w.Write([uint32]$Type)
        $w.Write([uint32]$Id)
        $w.Write([uint16]$Group)
        $w.Write([byte]$LpIndex)
        $w.Write([byte]0)
        $w.Write([byte]0)
        $w.Write([byte]0)
        $w.Write([byte]$EfficiencyClass)
        $w.Write([byte]0)
        $w.Write([byte]0)
        $w.Write([uint32]0)
        $w.Write([uint64]0)
        $w.Write((New-Object byte[] 15))
        $w.Flush()
        return $ms.ToArray()
    } finally {
        $w.Dispose()
        $ms.Dispose()
    }
}

function New-Nx19TestJoin {
    param([object[]]$Entries)
    $list = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($e in @($Entries)) { $list.AddRange([byte[]]$e) }
    return $list.ToArray()
}

function New-Nx19TestModel {
    param(
        [hashtable[]]$Cores,
        [hashtable[]]$Dies = @(),
        [object[]]$Caches = @(),
        [int[]]$SetLogicalProcessors = @(),
        [int]$GroupCount = 1,
        [int[]]$GroupProcessorCounts = @()
    )
    $coreBuffer = New-Nx19TestJoin -Entries @($Cores | ForEach-Object { New-Nx19TestLpEntry -Relationship 0 -Spec $_ })
    $dieBuffer = $null
    if (@($Dies).Count -gt 0) { $dieBuffer = New-Nx19TestJoin -Entries @($Dies | ForEach-Object { New-Nx19TestLpEntry -Relationship 5 -Spec $_ }) }
    $cacheBuffer = $null
    if (@($Caches).Count -gt 0) { $cacheBuffer = New-Nx19TestJoin -Entries @($Caches) }
    $setEntries = @()
    foreach ($lp in @($SetLogicalProcessors)) {
        $setEntries += New-Nx19TestCpuSetEntry -Id ([uint32](1000 + $lp)) -Group ([uint16][Math]::Floor($lp / 64)) -LpIndex ([byte]($lp % 64))
    }
    $setBuffer = $null
    if ($setEntries.Count -gt 0) { $setBuffer = New-Nx19TestJoin -Entries $setEntries }
    $coreParse = ConvertFrom-NxLpCoreBuffer -Buffer $coreBuffer
    $dieBufferForParse = [byte[]]@()
    if ($null -ne $dieBuffer) { $dieBufferForParse = $dieBuffer }
    $cacheBufferForParse = [byte[]]@()
    if ($null -ne $cacheBuffer) { $cacheBufferForParse = $cacheBuffer }
    $setBufferForParse = [byte[]]@()
    if ($null -ne $setBuffer) { $setBufferForParse = $setBuffer }
    $dieParse = ConvertFrom-NxLpDieBuffer -Buffer $dieBufferForParse
    $cacheParse = ConvertFrom-NxLpCacheBuffer -Buffer $cacheBufferForParse
    $setParse = ConvertFrom-NxCpuSetBuffer -Buffer $setBufferForParse
    return New-NxTopologyModel -CoreEntries $coreParse.entries -CacheEntries $cacheParse.entries -DieEntries $dieParse.entries -CpuSetEntries $setParse.entries -GroupCount $GroupCount -GroupProcessorCounts $GroupProcessorCounts
}

try {
    # ------------------------------------------------------------------------
    # 0. Module surface
    # ------------------------------------------------------------------------
    $publicFns = @(
        'Get-Nx19NativeStatus', 'Initialize-Nx19Native',
        'ConvertFrom-NxLpCoreBuffer', 'ConvertFrom-NxLpCacheBuffer', 'ConvertFrom-NxLpDieBuffer', 'ConvertFrom-NxCpuSetBuffer',
        'Test-NxX3dAsymmetry', 'New-NxTopologyModel', 'Get-NxTopologyReport',
        'Resolve-NxTopologyPool', 'ConvertTo-NxCpuSetIds', 'ConvertTo-NxAffinityMask',
        'Get-NxSchedulingProfileDefinition', 'New-NxCpuSetPlan', 'New-NxSchedulingPlan',
        'Test-NxCpuSetRule', 'New-NxCustomSchedulingPlan', 'Get-NxX3dPlacementGuidance',
        'Get-NxProcessCpuSetState', 'Set-NxProcessCpuSets', 'Set-NxProcessAffinity',
        'Set-NxProcessPriority', 'Invoke-Nx19Rollback'
    )
    $missing = @($publicFns | Where-Object { $null -eq (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue) })
    Assert-Nx 'all NX19 functions are defined' ($missing.Count -eq 0) ($missing -join ',')

    $nativeStatus = Get-Nx19NativeStatus
    Assert-Nx 'native status is read-only' ($nativeStatus.readOnly -eq $true -and $nativeStatus.noWritesPerformed -eq $true)
    Assert-Nx 'selected CPU set bound is 32' ($nativeStatus.maxSelectedCpuSets -eq 32)
    Assert-Nx 'process match fan-out is bounded' ($nativeStatus.maxProcessMatchesPerRule -eq 16)

    # ------------------------------------------------------------------------
    # 1. Registry file: 11 entries, full fields, gates, no registry actions
    # ------------------------------------------------------------------------
    $schema = Get-Content (Join-Path $repo 'registry\schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cat = Get-Content (Join-Path $repo 'registry\NX19.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $tweaks = @($cat.tweaks)
    Assert-Nx 'NX19.json declares 11 entries' ($tweaks.Count -eq 11) ("count=$($tweaks.Count)")
    Assert-Nx 'NX19.json category id' ($cat.category -eq 'NX19' -and $cat.categoryName -like 'CPU Topology*')

    $expectedIds = @(1..11 | ForEach-Object { 'NX19-{0:000}' -f $_ })
    $actualIds = @($tweaks | ForEach-Object { $_.id })
    Assert-Nx 'all NX19-001..011 present' ((@($expectedIds | Where-Object { $actualIds -notcontains $_ })).Count -eq 0) (($expectedIds | Where-Object { $actualIds -notcontains $_ }) -join ',')

    $fieldIssues = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tweaks) {
        foreach ($rf in @($schema.requiredFields)) {
            if (-not $t.PSObject.Properties[$rf]) { $fieldIssues.Add("$($t.id): missing $rf") }
        }
        foreach ($pair in @(@('risk', $schema.riskClasses), @('evidence', $schema.evidenceLevels), @('status', $schema.statuses), @('kind', $schema.kinds), @('modificationType', $schema.modificationTypes), @('privileges', $schema.privileges), @('restart', $schema.restartRequirements), @('approval', $schema.approvalModels))) {
            $v = $t.($pair[0])
            if (@($pair[1]) -notcontains $v) { $fieldIssues.Add("$($t.id): $($pair[0])='$v'") }
        }
        if ($t.id.Substring(0, 4) -ne $t.category) { $fieldIssues.Add("$($t.id): category mismatch") }
        if (@($t.apply.actions).Count -eq 0) { $fieldIssues.Add("$($t.id): no apply action") }
    }
    Assert-Nx 'required fields and enums valid' ($fieldIssues.Count -eq 0) ($fieldIssues -join '; ')

    $registryActions = @($tweaks | ForEach-Object { @($_.apply.actions) } | Where-Object { $_.type -eq 'registry' -or $_.type -eq 'service' })
    Assert-Nx 'no registry/service actions in NX19' ($registryActions.Count -eq 0)

    $fnIssues = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tweaks) {
        foreach ($a in @($t.apply.actions)) {
            if ($a.type -ne 'function') { continue }
            if ($null -eq (Get-Command -Name ([string]$a.function) -CommandType Function -ErrorAction SilentlyContinue)) { $fnIssues.Add("$($t.id): $($a.function)") }
        }
    }
    Assert-Nx 'every function action resolves' ($fnIssues.Count -eq 0) ($fnIssues -join '; ')

    $riskMap = @{}
    foreach ($t in $tweaks) { $riskMap[$t.id] = $t }
    Assert-Nx '001/002 are CORE E1 read-only engines' ($riskMap['NX19-001'].risk -eq 'CORE' -and $riskMap['NX19-001'].evidence -eq 'E1' -and $riskMap['NX19-002'].risk -eq 'CORE' -and $riskMap['NX19-002'].evidence -eq 'E1')
    Assert-Nx '003/004 are ADVANCED, preset-excluded, ExplicitConsent' (@('NX19-003','NX19-004' | ForEach-Object { $riskMap[$_].risk -eq 'ADVANCED' -and $riskMap[$_].presetExcluded -eq $true -and $riskMap[$_].approval -eq 'ExplicitConsent' }) -notcontains $false)
    Assert-Nx '011 is EXPERIMENTAL E0 and preset-excluded' ($riskMap['NX19-011'].risk -eq 'EXPERIMENTAL' -and $riskMap['NX19-011'].evidence -eq 'E0' -and $riskMap['NX19-011'].presetExcluded -eq $true)
    Assert-Nx 'E1 entries cite a Microsoft documentation URL' (@('NX19-001','NX19-002','NX19-004','NX19-005' | ForEach-Object { @($riskMap[$_].documentationSource | Where-Object { $_ -like 'https://learn.microsoft.com/*' }).Count -gt 0 }) -notcontains $false)

    $perfPattern = '(?i)\b(faster|smoother|lower latency|higher fps|frames per second)\b'
    $perfClaims = @($tweaks | Where-Object { ($_.description -match $perfPattern) -or ($_.technicalExplanation -match $perfPattern) -or (@($_.sideEffects | Where-Object { $_ -match $perfPattern }).Count -gt 0) })
    Assert-Nx 'no performance claims in NX19 text' ($perfClaims.Count -eq 0) (($perfClaims | ForEach-Object { $_.id }) -join ',')

    $depIssues = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tweaks) {
        foreach ($d in @($t.dependencies)) { if ($actualIds -notcontains $d) { $depIssues.Add("$($t.id) -> $d") } }
    }
    Assert-Nx 'dependencies resolve inside NX19' ($depIssues.Count -eq 0) ($depIssues -join '; ')
    $asym = @($tweaks | Where-Object {
        $tweak = $_
        @($tweak.conflicts | Where-Object { $_ -like 'NX19-*' -and $actualIds -contains $_ } | ForEach-Object {
            $conflictId = $_
            if (@($riskMap[$conflictId].conflicts) -notcontains $tweak.id) { "$($tweak.id)->$conflictId" }
        })
    })
    Assert-Nx 'conflict declarations are symmetric' ($asym.Count -eq 0) ($asym -join '; ')
    Assert-Nx 'all entries are Implemented/SyntaxValidated with actions' (@($tweaks | Where-Object { $_.status -notin @('Implemented','SyntaxValidated') -or @($_.apply.actions).Count -eq 0 }).Count -eq 0)

    # ------------------------------------------------------------------------
    # 2. Read-only live topology probe (the only live API use)
    # ------------------------------------------------------------------------
    $live = Get-NxTopologyReport
    Assert-Nx 'live probe is read-only' ($live.readOnly -eq $true -and $live.noWritesPerformed -eq $true)
    Assert-Nx 'live probe result is explicit' (($live.topologyAvailable -eq $true) -or (@($live.uncertainty).Count -gt 0))
    if ($live.topologyAvailable) {
        Assert-Nx 'live probe derives processors' ($live.logicalProcessorCount -ge 1 -and $live.physicalCoreCount -ge 1)
        $allLive = @($live.topologyModel.allLogicalProcessors)
        $subsetOk = $true
        foreach ($c in @($live.cores)) { foreach ($lp in @($c.logicalProcessors)) { if ($allLive -notcontains [int]$lp) { $subsetOk = $false } } }
        Assert-Nx 'every core LP belongs to the derived LP set' $subsetOk
        Assert-Nx 'live CPU set map is present or explicitly missing' (($live.cpuSetMap.available -eq $true -and $live.cpuSetMap.entryCount -gt 0) -or ($live.cpuSetMap.available -eq $false))
        Assert-Nx 'live group count is derived' ($live.groupCount -ge 1)
        Assert-Nx 'live fingerprint is non-empty' (-not [string]::IsNullOrWhiteSpace([string]$live.fingerprint))
        Assert-Nx 'live probe never asserts X3D without data' ($live.x3d.indicated -eq $true -or @('BestEffort','NoAsymmetryDetected','NotDeterminable') -contains $live.x3d.confidence)
    } else {
        Assert-Nx 'unavailable probe explains itself' (@($live.uncertainty).Count -gt 0)
    }

    # Simulated interop failure: the guard must report Uncertainty, never guess.
    $savedNativeState = $script:Nx19NativeState
    $script:Nx19NativeState = [pscustomobject]@{ attempted = $true; available = $false; reason = 'simulated interop failure'; compiledUtc = (Get-Date).ToUniversalTime().ToString('o') }
    $failedReport = Get-NxTopologyReport
    Assert-Nx 'interop failure yields an uncertain report, not a guessed topology' ($failedReport.topologyAvailable -eq $false -and (@($failedReport.uncertainty | Where-Object { $_ -match 'simulated interop failure' }).Count -eq 1) -and $null -eq $failedReport.topologyModel)
    $failedPlan = New-NxCpuSetPlan -Profile Competitive
    Assert-Nx 'interop failure yields an unavailable plan' ($failedPlan.topologyAvailable -eq $false -and $failedPlan.certainty -eq 'Unavailable' -and @($failedPlan.rules).Count -eq 0)
    $failedGuidance = Get-NxX3dPlacementGuidance
    Assert-Nx 'interop failure yields unavailable X3D guidance' ($failedGuidance.topologyAvailable -eq $false -and $failedGuidance.confidence -eq 'Unavailable')
    $script:Nx19NativeState = $savedNativeState

    # ------------------------------------------------------------------------
    # 3. Intel hybrid A: 8 P cores (SMT) + 8 E cores, single group, 24 LPs
    # ------------------------------------------------------------------------
    $coresA = @()
    for ($i = 0; $i -lt 8; $i++) {
        $coresA += @{ Flags = 1; EfficiencyClass = 0; RelativePerformance = 100; RelativeEfficiency = 100; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @((2 * $i), (2 * $i + 1)))) }
    }
    for ($i = 0; $i -lt 8; $i++) {
        $coresA += @{ Flags = 0; EfficiencyClass = 1; RelativePerformance = 60; RelativeEfficiency = 220; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(16 + $i))) }
    }
    $lpsA = @(0..23)
    $modelA = New-Nx19TestModel -Cores $coresA -SetLogicalProcessors $lpsA -GroupCount 1 -GroupProcessorCounts @(24)
    Assert-Nx 'Intel A: 16 cores / 24 LPs derived' ($modelA.coreCount -eq 16 -and $modelA.logicalProcessorCount -eq 24)
    Assert-Nx 'Intel A: hybrid with 2 tiers' ($modelA.isHybrid -eq $true -and $modelA.tierCount -eq 2)
    Assert-Nx 'Intel A: ranking from RelativePerformance' ($modelA.rankingSource -eq 'RelativePerformance' -and $modelA.rankingCertainty -eq 'DerivedFromRelativePerformance')
    Assert-Nx 'Intel A: P pool has 16 LPs' (@($modelA.classPools['P'].logicalProcessors).Count -eq 16)
    Assert-Nx 'Intel A: E pool has 8 LPs' (@($modelA.classPools['E'].logicalProcessors).Count -eq 8)
    Assert-Nx 'Intel A: P primary threads = 8' (@($modelA.classPools['P'].primaryLogicalProcessors).Count -eq 8)
    Assert-Nx 'Intel A: E primary threads = 8' (@($modelA.classPools['E'].primaryLogicalProcessors).Count -eq 8)
    Assert-Nx 'Intel A: SMT flag detected on 8 cores' (@($modelA.cores | Where-Object { $_.hasSmt }).Count -eq 8)
    Assert-Nx 'Intel A: efficiency classes preserved' ((@($modelA.efficiencyClasses) -join ',') -eq '0,1')
    Assert-Nx 'Intel A: P roles are derived, not hardcoded' (@($modelA.cores | Where-Object { $_.tierRole -eq 'P' } | ForEach-Object { $_.logicalProcessors } | Sort-Object) -join ',' -eq ((@(0..15)) -join ','))
    Assert-Nx 'Intel A: no die data is reported as unavailable' ($modelA.diesSupported -eq $false -and @($modelA.dies).Count -eq 1 -and $modelA.dies[0].synthetic -eq $true)

    $planBalancedA = New-NxCpuSetPlan -Topology $modelA -Profile Balanced
    Assert-Nx 'Balanced A: game pool is performance-logical' (@($planBalancedA.rules).Count -eq 1 -and $planBalancedA.rules[0].class -eq 'Game' -and @($planBalancedA.rules[0].logicalProcessors).Count -eq 16)
    Assert-Nx 'Balanced A: no background rule (responsiveness preserved)' (@($planBalancedA.rules | Where-Object { $_.class -eq 'Background' }).Count -eq 0)
    Assert-Nx 'Balanced A: plan is restrictive' ($planBalancedA.restrictive -eq $true)
    Assert-Nx 'Balanced A: CPU set IDs resolved from the map' ($planBalancedA.rules[0].cpuSetIdsResolved -eq $true -and @($planBalancedA.rules[0].cpuSetIds).Count -eq 16)

    $planCompA = New-NxCpuSetPlan -Topology $modelA -Profile Competitive
    $compGame = @($planCompA.rules | Where-Object { $_.class -eq 'Game' })[0]
    $compBg = @($planCompA.rules | Where-Object { $_.class -eq 'Background' })
    Assert-Nx 'Competitive A: game uses P primary threads (8)' ($compGame.pool -eq 'PerformancePrimary' -and @($compGame.logicalProcessors).Count -eq 8)
    Assert-Nx 'Competitive A: background uses E logical processors (8)' ($compBg.Count -eq 1 -and @($compBg[0].logicalProcessors).Count -eq 8)
    Assert-Nx 'Competitive A: game/background selections are disjoint' (@($compGame.logicalProcessors | Where-Object { @($compBg[0].logicalProcessors) -contains $_ }).Count -eq 0)
    Assert-Nx 'Competitive A: affinity alternative is single-group' ($compGame.affinity.supported -eq $true -and $compGame.affinity.group -eq 0)

    $planStreamA = New-NxCpuSetPlan -Topology $modelA -Profile Streaming
    $streamCapture = @($planStreamA.rules | Where-Object { $_.class -eq 'Capture' })
    $streamBg = @($planStreamA.rules | Where-Object { $_.class -eq 'Background' })
    Assert-Nx 'Streaming A: capture reserve is the E tier' ($streamCapture.Count -eq 1 -and @($streamCapture[0].logicalProcessors).Count -eq 8)
    Assert-Nx 'Streaming A: background excludes the capture reserve' ($streamBg.Count -eq 0)
    Assert-Nx 'Streaming A: capture and game are disjoint' (@($streamCapture[0].logicalProcessors | Where-Object { @($compGame.logicalProcessors) -contains $_ }).Count -eq 0)

    # ------------------------------------------------------------------------
    # 4. Intel three-tier: P / E / LP-E
    # ------------------------------------------------------------------------
    $coresB = @(
        @{ Flags = 1; EfficiencyClass = 0; RelativePerformance = 100; RelativeEfficiency = 100; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(0,1))) },
        @{ Flags = 1; EfficiencyClass = 0; RelativePerformance = 100; RelativeEfficiency = 100; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(2,3))) }
    )
    for ($i = 0; $i -lt 8; $i++) {
        $coresB += @{ Flags = 0; EfficiencyClass = 1; RelativePerformance = 70; RelativeEfficiency = 200; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(4 + $i))) }
    }
    $coresB += @{ Flags = 0; EfficiencyClass = 2; RelativePerformance = 40; RelativeEfficiency = 300; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(12))) }
    $coresB += @{ Flags = 0; EfficiencyClass = 2; RelativePerformance = 40; RelativeEfficiency = 300; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(13))) }
    $modelB = New-Nx19TestModel -Cores $coresB -SetLogicalProcessors @(0..13)
    Assert-Nx '3-tier: tier count is 3' ($modelB.tierCount -eq 3)
    Assert-Nx '3-tier: LP-E pool exists with 2 LPs' ($modelB.classPools.Contains('LP-E') -and @($modelB.classPools['LP-E'].logicalProcessors).Count -eq 2)
    Assert-Nx '3-tier: roles ordered P/E/LP-E by RelativePerformance' (@($modelB.cores | Where-Object { $_.efficiencyClass -eq 0 }).Count -eq 2 -and @($modelB.cores | Where-Object { $_.tierRole -eq 'LP-E' }).Count -eq 2)
    Assert-Nx '3-tier: P pool excludes LP-E' (@($modelB.classPools['P'].logicalProcessors) -notcontains 12 -and @($modelB.classPools['P'].logicalProcessors) -notcontains 13)

    # ------------------------------------------------------------------------
    # 5. AMD dual-CCD: asymmetric L3 (X3D) and symmetric variants
    # ------------------------------------------------------------------------
    $coresC = @()
    for ($i = 0; $i -lt 16; $i++) {
        $coresC += @{ Flags = 1; EfficiencyClass = 0; RelativePerformance = 0; RelativeEfficiency = 0; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @((2 * $i), (2 * $i + 1)))) }
    }
    $diesC = @(
        @{ Flags = 0; EfficiencyClass = 0; RelativePerformance = 0; RelativeEfficiency = 0; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(0..15))) },
        @{ Flags = 0; EfficiencyClass = 0; RelativePerformance = 0; RelativeEfficiency = 0; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(16..31))) }
    )
    $cachesC = @(
        (New-Nx19TestCacheEntry -Level 2 -CacheSize ([uint32]1048576) -Type 0 -Groups @((New-Nx19TestGroupSpec -Group 0 -Indexes @(0..15)))),
        (New-Nx19TestCacheEntry -Level 3 -CacheSize ([uint32]100663296) -Type 0 -Groups @((New-Nx19TestGroupSpec -Group 0 -Indexes @(0..15)))),
        (New-Nx19TestCacheEntry -Level 3 -CacheSize ([uint32]33554432) -Type 0 -Groups @((New-Nx19TestGroupSpec -Group 0 -Indexes @(16..31))))
    )
    $modelC = New-Nx19TestModel -Cores $coresC -Dies $diesC -Caches $cachesC -SetLogicalProcessors @(0..31)
    Assert-Nx 'AMD C: 2 dies detected' ($modelC.diesSupported -eq $true -and @($modelC.dies).Count -eq 2)
    Assert-Nx 'AMD C: per-die L3 attributed 96MB/32MB' ($modelC.dies[0].l3Bytes -eq 100663296 -and $modelC.dies[1].l3Bytes -eq 33554432) ("$($modelC.dies[0].l3Bytes)/$($modelC.dies[1].l3Bytes)")
    Assert-Nx 'AMD C: X3D indicated with BestEffort confidence' ($modelC.x3d.indicated -eq $true -and $modelC.x3d.confidence -eq 'BestEffort')
    Assert-Nx 'AMD C: large die is die 0' ((@($modelC.x3d.largeDieIndexes) -join ',') -eq '0')
    Assert-Nx 'AMD C: observed asymmetry ratio is 3' ($modelC.x3d.observedRatio -eq 3)
    Assert-Nx 'AMD C: single-tier AMD is not treated as hybrid' ($modelC.isHybrid -eq $false)
    Assert-Nx 'AMD C: single-tier ranking is not flagged uncertain' ($modelC.rankingCertainty -eq 'NotApplicable-SingleTier')

    $guideC = Get-NxX3dPlacementGuidance -Topology $modelC
    Assert-Nx 'X3D guidance: large-die LPs are 0..15' ($guideC.x3dIndicated -eq $true -and (@($guideC.largeDieLogicalProcessors | Sort-Object) -join ',') -eq ((@(0..15)) -join ','))
    Assert-Nx 'X3D guidance: other-die LPs are 16..31' ((@($guideC.otherDieLogicalProcessors | Sort-Object) -join ',') -eq ((@(16..31)) -join ','))
    Assert-Nx 'X3D guidance: says guidance only, nothing applied' (@($guideC.guidance | Where-Object { $_ -match 'guidance only' }).Count -ge 1)

    $planCompC = New-NxCpuSetPlan -Topology $modelC -Profile Competitive
    Assert-Nx 'Competitive C: single-tier game pool is every physical primary thread' ($planCompC.rules[0].pool -eq 'PerformancePrimary' -and @($planCompC.rules[0].logicalProcessors).Count -eq 16)
    $planStreamC = New-NxCpuSetPlan -Topology $modelC -Profile Streaming
    $capC = @($planStreamC.rules | Where-Object { $_.class -eq 'Capture' })
    Assert-Nx 'Streaming C: capture reserved to the smaller-L3 die' ($capC.Count -eq 1 -and (@($capC[0].logicalProcessors | Sort-Object) -join ',') -eq ((@(16..31)) -join ','))
    Assert-Nx 'Streaming C: game is reserved to the larger-L3 die primary threads' ((@($planStreamC.rules | Where-Object { $_.class -eq 'Game' })[0].logicalProcessors | Sort-Object) -join ',' -eq ((@(0..15 | ForEach-Object { 2 * $_ })) -join ','))

    $cachesSymmetric = @(
        (New-Nx19TestCacheEntry -Level 3 -CacheSize ([uint32]33554432) -Type 0 -Groups @((New-Nx19TestGroupSpec -Group 0 -Indexes @(0..15)))),
        (New-Nx19TestCacheEntry -Level 3 -CacheSize ([uint32]33554432) -Type 0 -Groups @((New-Nx19TestGroupSpec -Group 0 -Indexes @(16..31))))
    )
    $modelCSym = New-Nx19TestModel -Cores $coresC -Dies $diesC -Caches $cachesSymmetric -SetLogicalProcessors @(0..31)
    Assert-Nx 'AMD symmetric: no X3D asymmetry claimed' ($modelCSym.x3d.indicated -eq $false -and $modelCSym.x3d.confidence -eq 'NoAsymmetryDetected')
    $guideSym = Get-NxX3dPlacementGuidance -Topology $modelCSym
    Assert-Nx 'X3D guidance on symmetric: no large-L3 die' ($guideSym.x3dIndicated -eq $false -and @($guideSym.largeDieLogicalProcessors).Count -eq 0)

    # ------------------------------------------------------------------------
    # 6. X3D pure heuristic boundaries
    # ------------------------------------------------------------------------
    Assert-Nx 'X3D heuristic: 96/32 fires' ((Test-NxX3dAsymmetry -PerDieL3Bytes @([long]100663296, [long]33554432)).indicated -eq $true)
    Assert-Nx 'X3D heuristic: 64/32 is not >2x' ((Test-NxX3dAsymmetry -PerDieL3Bytes @([long]67108864, [long]33554432)).indicated -eq $false)
    Assert-Nx 'X3D heuristic: 65/32 fires' ((Test-NxX3dAsymmetry -PerDieL3Bytes @([long]68157440, [long]33554432)).indicated -eq $true)
    $threeDies = Test-NxX3dAsymmetry -PerDieL3Bytes @([long]100663296, [long]33554432, [long]33554432)
    Assert-Nx 'X3D heuristic: 3 dies flags only the large one' ((@($threeDies.largeDieIndexes) -join ',') -eq '0')
    Assert-Nx 'X3D heuristic: all-zero dies is not determinable' ((Test-NxX3dAsymmetry -PerDieL3Bytes @([long]0, [long]0)).confidence -eq 'NotDeterminable')
    Assert-Nx 'X3D heuristic: dies unsupported is not determinable' ((Test-NxX3dAsymmetry -PerDieL3Bytes @([long]1, [long]1) -DiesSupported $false).confidence -eq 'NotDeterminable')
    Assert-Nx 'X3D heuristic: single die is no-asymmetry' ((Test-NxX3dAsymmetry -PerDieL3Bytes @([long]33554432)).confidence -eq 'NoAsymmetryDetected')

    # ------------------------------------------------------------------------
    # 7. CPU set parser + ID resolution
    # ------------------------------------------------------------------------
    $setBuf = New-Nx19TestJoin -Entries @(
        (New-Nx19TestCpuSetEntry -Id 7 -Group 0 -LpIndex 0),
        (New-Nx19TestCpuSetEntry -Id 8 -Group 0 -LpIndex 1),
        (New-Nx19TestCpuSetEntry -Id 9 -Group 0 -LpIndex 2),
        (New-Nx19TestCpuSetEntry -Id 999 -Group 0 -LpIndex 3 -Type 5)
    )
    $setParse = ConvertFrom-NxCpuSetBuffer -Buffer $setBuf
    Assert-Nx 'CPU set parser: valid entries parsed' ($setParse.entryCount -eq 3 -and $setParse.skippedEntries -eq 1)
    Assert-Nx 'CPU set parser: ID and global index derived' ($setParse.entries[0].cpuSetId -eq 7 -and $setParse.entries[1].globalLogicalProcessor -eq 1)
    $resolveOk = ConvertTo-NxCpuSetIds -GlobalIndexes @(0, 1, 2) -CpuSetEntries $setParse.entries
    Assert-Nx 'CPU set IDs resolve when every LP is mapped' ($resolveOk.resolved -eq $true -and (@($resolveOk.cpuSetIds) -join ',') -eq '7,8,9')
    $resolveMissing = ConvertTo-NxCpuSetIds -GlobalIndexes @(0, 1, 3) -CpuSetEntries $setParse.entries
    Assert-Nx 'CPU set IDs refuse to fabricate a missing ID' ($resolveMissing.resolved -eq $false -and (@($resolveMissing.unresolvedLogicalProcessors) -join ',') -eq '3' -and @($resolveMissing.cpuSetIds).Count -eq 2)
    $resolveNone = ConvertTo-NxCpuSetIds -GlobalIndexes @(0) -CpuSetEntries @()
    Assert-Nx 'CPU set IDs report an unavailable map' ($resolveNone.mapAvailable -eq $false -and $resolveNone.resolved -eq $false)
    $modelMissing = New-Nx19TestModel -Cores $coresA -SetLogicalProcessors @(0..20)
    Assert-Nx 'model flags LPs missing from the CPU set map' (@($modelMissing.missingCpuSetLogicalProcessors | Sort-Object) -join ',' -eq '21,22,23')

    # ------------------------------------------------------------------------
    # 8. Affinity mask conversion (separate mechanism, single group)
    # ------------------------------------------------------------------------
    $aff = ConvertTo-NxAffinityMask -GlobalIndexes @(0, 5, 63)
    $expectedMask = New-Nx19TestMask -Indexes @(0, 5, 63)
    Assert-Nx 'affinity: single-group selection supported' ($aff.supported -eq $true -and $aff.group -eq 0)
    Assert-Nx 'affinity: mask bits are exact' ($aff.mask -eq $expectedMask) ("$($aff.mask) vs $expectedMask")
    Assert-Nx 'affinity: index 64 alone is group 1' ((ConvertTo-NxAffinityMask -GlobalIndexes @(64)).supported -eq $true)
    $affCross = ConvertTo-NxAffinityMask -GlobalIndexes @(0, 64)
    Assert-Nx 'affinity: cross-group selection refused' ($affCross.supported -eq $false -and $affCross.reason -match 'groups')
    Assert-Nx 'affinity: empty selection refused' ((ConvertTo-NxAffinityMask -GlobalIndexes @()).supported -eq $false)
    $affG1 = ConvertTo-NxAffinityMask -GlobalIndexes @(64, 65)
    Assert-Nx 'affinity: group-1 mask is group-relative' ($affG1.supported -eq $true -and $affG1.group -eq 1 -and $affG1.mask -eq 3)
    $maskDesc = [pscustomobject]@{ affinityMask = '9223372036854775809'; affinityMaskDecimal = '9223372036854775809' }
    Assert-Nx 'journal mask descriptor parses the full uint64 range' ((Get-NxMaskFromDescriptor -Descriptor $maskDesc) -eq [uint64]::Parse('9223372036854775809'))
    $maskDescLegacy = [pscustomobject]@{ affinityMask = [uint64]255 }
    Assert-Nx 'journal mask descriptor accepts a legacy numeric value' ((Get-NxMaskFromDescriptor -Descriptor $maskDescLegacy) -eq 255)

    # ------------------------------------------------------------------------
    # 9. Single-group 64 LPs and multi-group parsing
    # ------------------------------------------------------------------------
    $cores64 = @()
    for ($i = 0; $i -lt 32; $i++) {
        $cores64 += @{ Flags = 1; EfficiencyClass = 0; RelativePerformance = 0; RelativeEfficiency = 0; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @((2 * $i), (2 * $i + 1)))) }
    }
    $model64 = New-Nx19TestModel -Cores $cores64 -SetLogicalProcessors @(0..63) -GroupCount 1 -GroupProcessorCounts @(64)
    Assert-Nx '64-LP single group: 32 cores / 64 LPs' ($model64.coreCount -eq 32 -and $model64.logicalProcessorCount -eq 64)
    Assert-Nx '64-LP single group: highest LP is 63' ((@($model64.allLogicalProcessors) | Measure-Object -Maximum).Maximum -eq 63)
    Assert-Nx '64-LP single group: affinity at LP 63 supported' ((ConvertTo-NxAffinityMask -GlobalIndexes @(63)).supported -eq $true)

    $coresG = @()
    for ($g = 0; $g -lt 2; $g++) {
        for ($i = 0; $i -lt 4; $i++) {
            $coresG += @{ Flags = 0; EfficiencyClass = 0; RelativePerformance = 0; RelativeEfficiency = 0; Groups = @((New-Nx19TestGroupSpec -Group $g -Indexes @((2 * $i), (2 * $i + 1)))) }
        }
    }
    $modelG = New-Nx19TestModel -Cores $coresG -SetLogicalProcessors (@(0..7) + @(64..71)) -GroupCount 2 -GroupProcessorCounts @(8, 8)
    Assert-Nx 'multi-group: cross-group indexing is group*64+lp' ((@($modelG.allLogicalProcessors) -contains 64) -and (@($modelG.allLogicalProcessors) -contains 71))
    Assert-Nx 'multi-group: group count reported' ($modelG.groupCount -eq 2 -and (@($modelG.groupProcessorCounts) -join ',') -eq '8,8')
    Assert-Nx 'multi-group: affinity across groups refused' ((ConvertTo-NxAffinityMask -GlobalIndexes @(0, 64)).supported -eq $false)

    # ------------------------------------------------------------------------
    # 10. Truncation / malformed buffers never throw
    # ------------------------------------------------------------------------
    $validCoreBuf = New-Nx19TestJoin -Entries @($coresA | ForEach-Object { New-Nx19TestLpEntry -Relationship 0 -Spec $_ })
    $cut = New-Object byte[] ($validCoreBuf.Length - 10)
    [Array]::Copy($validCoreBuf, $cut, $cut.Length)
    $cutParse = ConvertFrom-NxLpCoreBuffer -Buffer $cut
    Assert-Nx 'truncated core buffer stops without throwing' ($cutParse.truncated -eq $true -and $cutParse.entryCount -lt 16)
    $garbage = New-Object byte[] 64
    for ($i = 0; $i -lt 64; $i++) { $garbage[$i] = [byte](255 - $i) }
    $garbageParse = ConvertFrom-NxLpCoreBuffer -Buffer $garbage
    Assert-Nx 'garbage buffer reports truncation' ($garbageParse.truncated -eq $true -and $garbageParse.entryCount -eq 0)
    $emptyParse = ConvertFrom-NxLpCoreBuffer -Buffer ([byte[]]@())
    Assert-Nx 'empty buffer is an explicit empty result' ($emptyParse.entryCount -eq 0 -and $emptyParse.truncated -eq $false)
    $wrongRel = ConvertFrom-NxLpCacheBuffer -Buffer $validCoreBuf
    Assert-Nx 'wrong-relationship entries are skipped' ($wrongRel.entryCount -eq 0 -and $wrongRel.skippedEntries -ge 1)
    $badSets = New-Nx19TestJoin -Entries @((New-Nx19TestCpuSetEntry -Id 1 -Group 0 -LpIndex 0), ([byte[]](1, 2, 3, 4, 5, 6, 7, 8)))
    $badSetParse = ConvertFrom-NxCpuSetBuffer -Buffer $badSets
    Assert-Nx 'malformed CPU set trailing bytes are truncated' ($badSetParse.truncated -eq $true -and $badSetParse.entryCount -eq 1)

    # ------------------------------------------------------------------------
    # 11. Derivation edge cases
    # ------------------------------------------------------------------------
    $coresSmall = @(
        @{ Flags = 1; EfficiencyClass = 0; RelativePerformance = 100; RelativeEfficiency = 100; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(0,1))) },
        @{ Flags = 0; EfficiencyClass = 1; RelativePerformance = 60; RelativeEfficiency = 200; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(2))) },
        @{ Flags = 0; EfficiencyClass = 1; RelativePerformance = 60; RelativeEfficiency = 200; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(3))) }
    )
    $modelSmall = New-Nx19TestModel -Cores $coresSmall -SetLogicalProcessors @(0..3)
    $planSmall = New-NxCpuSetPlan -Topology $modelSmall -Profile Competitive
    Assert-Nx 'small P tier: game pool widens rather than stripping the CPU' ($planSmall.rules[0].pool -eq 'AllLogical' -and @($planSmall.rules[0].logicalProcessors).Count -eq 4)
    Assert-Nx 'small P tier: uncertainty explains the widening' (@($planSmall.uncertainty | Where-Object { $_ -match 'fewer than 4' }).Count -ge 1)

    $coresUncertain = @(
        @{ Flags = 1; EfficiencyClass = 0; RelativePerformance = 0; RelativeEfficiency = 0; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(0,1))) },
        @{ Flags = 1; EfficiencyClass = 0; RelativePerformance = 0; RelativeEfficiency = 0; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(2,3))) },
        @{ Flags = 0; EfficiencyClass = 1; RelativePerformance = 0; RelativeEfficiency = 0; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(4))) },
        @{ Flags = 0; EfficiencyClass = 1; RelativePerformance = 0; RelativeEfficiency = 0; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(5))) }
    )
    $modelUncertain = New-Nx19TestModel -Cores $coresUncertain -SetLogicalProcessors @(0..5)
    Assert-Nx 'polarity uncertainty is flagged when RelativePerformance is absent' ($modelUncertain.rankingCertainty -eq 'DocumentedPolarity-Uncertain')
    $planUncertain = New-NxCpuSetPlan -Topology $modelUncertain -Profile Competitive
    Assert-Nx 'polarity uncertainty withholds P/E pinning' ($planUncertain.rules[0].pool -eq 'AllPrimaryThreads' -and @($planUncertain.rules[0].logicalProcessors).Count -eq 4 -and @($planUncertain.rules | Where-Object { $_.class -eq 'Background' }).Count -eq 0)

    $modelNoDiesNoE = New-Nx19TestModel -Cores @(
        @{ Flags = 1; EfficiencyClass = 0; RelativePerformance = 0; RelativeEfficiency = 0; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(0,1))) },
        @{ Flags = 1; EfficiencyClass = 0; RelativePerformance = 0; RelativeEfficiency = 0; Groups = @((New-Nx19TestGroupSpec -Group 0 -Indexes @(2,3))) }
    ) -SetLogicalProcessors @(0..3)
    $planStreamFallback = New-NxCpuSetPlan -Topology $modelNoDiesNoE -Profile Streaming
    $capFallback = @($planStreamFallback.rules | Where-Object { $_.class -eq 'Capture' })
    Assert-Nx 'capture reserve falls back to a core-count-derived slice' ($capFallback.Count -eq 1 -and @($capFallback[0].logicalProcessors).Count -eq 1 -and $capFallback[0].poolDerivedFrom -match 'core-count-derived')

    $planProd = New-NxCpuSetPlan -Topology $modelA -Profile Productivity
    Assert-Nx 'Productivity derives no restriction' ($planProd.restrictive -eq $false -and @($planProd.rules).Count -eq 0)

    # ------------------------------------------------------------------------
    # 12. Profiles as data
    # ------------------------------------------------------------------------
    $profileNames = @('Competitive','Balanced','Streaming','Productivity','Custom')
    $profileIssues = New-Object System.Collections.Generic.List[string]
    foreach ($n in $profileNames) {
        $d = Get-NxSchedulingProfileDefinition -Name $n
        if (-not $d.defined -or -not $d.implementedAsData) { $profileIssues.Add("$n not implemented as data") }
        if ($d.gameClass -ne 1 -or $d.backgroundClass -ne 3 -or $d.captureClass -ne 2) { $profileIssues.Add("$n class ids") }
        foreach ($p in @('game','background','capture')) {
            $v = $d.priority.$p
            if ($v -and @('Idle','BelowNormal','Normal','AboveNormal') -notcontains $v) { $profileIssues.Add("$n priority $p=$v") }
        }
        if ($d.affinityFallback -ne $false) { $profileIssues.Add("$n affinity fallback") }
    }
    Assert-Nx 'five profile definitions with correct class ids' ($profileIssues.Count -eq 0) ($profileIssues -join '; ')
    Assert-Nx 'profile ids map to NX19-006..010' ((@($profileNames | ForEach-Object { (Get-NxSchedulingProfileDefinition -Name $_).id }) -join ',') -eq 'NX19-006,NX19-007,NX19-008,NX19-009,NX19-010')
    $plan006 = New-NxSchedulingPlan -Profile Competitive -Topology $modelA
    Assert-Nx 'New-NxSchedulingPlan attaches the profile id' ($plan006.profileId -eq 'NX19-006' -and $plan006.profile -eq 'Competitive' -and $plan006.tweakId -eq 'NX19-006')

    # ------------------------------------------------------------------------
    # 13. Custom builder validation
    # ------------------------------------------------------------------------
    $customValid = New-NxCustomSchedulingPlan -Topology $modelA -Rules @(
        @{ processName = 'game.exe'; class = 'Game'; pool = 'PerformancePrimary' },
        @{ processName = 'obs64.exe'; class = 'Capture'; pool = 'CaptureReserve' }
    )
    Assert-Nx 'custom: two valid rules accepted' ($customValid.valid -eq $true -and @($customValid.rules).Count -eq 2)
    Assert-Nx 'custom: class ids Game=1 / Capture=2' ($customValid.rules[0].classId -eq 1 -and $customValid.rules[1].classId -eq 2)
    Assert-Nx 'custom: plan is restrictive and named' ($customValid.restrictive -eq $true -and $customValid.rules[0].processName -eq 'game.exe')

    $customUnknown = New-NxCustomSchedulingPlan -Topology $modelA -Rules @(
        @{ processName = 'game.exe'; class = 'Game'; logicalProcessors = @(0, 99) }
    )
    Assert-Nx 'custom: unknown LP is rejected, not clamped' ($customUnknown.valid -eq $false -and (@($customUnknown.issues | Where-Object { $_ -match '99' }).Count -ge 1))

    $customDuplicate = New-NxCustomSchedulingPlan -Topology $modelA -Rules @(
        @{ processName = 'game.exe'; class = 'Game'; pool = 'PerformancePrimary' },
        @{ processName = 'GAME.exe'; class = 'Background'; pool = 'EfficiencyLogical' }
    )
    Assert-Nx 'custom: duplicate process names rejected' ($customDuplicate.valid -eq $false -and (@($customDuplicate.issues | Where-Object { $_ -match 'Duplicate' }).Count -eq 1))

    $customNoGame = New-NxCustomSchedulingPlan -Topology $modelA -Rules @(
        @{ processName = 'obs64.exe'; class = 'Capture'; pool = 'CaptureReserve' }
    )
    Assert-Nx 'custom: a Game rule is required' ($customNoGame.valid -eq $false -and (@($customNoGame.issues | Where-Object { $_ -match 'Game' }).Count -ge 1))

    $customWildcard = New-NxCustomSchedulingPlan -Topology $modelA -Rules @(
        @{ processName = 'game*.exe'; class = 'Game'; pool = 'PerformancePrimary' }
    )
    Assert-Nx 'custom: wildcard names rejected' ($customWildcard.valid -eq $false -and (@($customWildcard.issues | Where-Object { $_ -match 'wildcard' }).Count -eq 1))

    $customPlaceholder = New-NxCustomSchedulingPlan -Topology $modelA -Rules @(
        @{ processName = '<game>.exe'; class = 'Game'; pool = 'PerformancePrimary' }
    )
    Assert-Nx 'custom: placeholder names rejected' ($customPlaceholder.valid -eq $false -and (@($customPlaceholder.issues | Where-Object { $_ -match 'placeholder' }).Count -eq 1))

    $customPath = New-NxCustomSchedulingPlan -Topology $modelA -Rules @(
        @{ processName = 'C:\Games\game.exe'; class = 'Game'; pool = 'PerformancePrimary' }
    )
    Assert-Nx 'custom: path rules rejected in favour of image names' ($customPath.valid -eq $false -and (@($customPath.issues | Where-Object { $_ -match 'not a path' }).Count -eq 1))

    $customNoRules = New-NxCustomSchedulingPlan -Topology $modelA -Rules @()
    Assert-Nx 'custom: no rules is an explicit rejection' ($customNoRules.valid -eq $false -and @($customNoRules.rules).Count -eq 0)

    $customExplicit = New-NxCustomSchedulingPlan -Topology $modelA -Rules @(
        @{ processName = 'game.exe'; class = 'Game'; logicalProcessors = @(0, 2, 4, 6) }
    )
    Assert-Nx 'custom: explicit topology LPs accepted' ($customExplicit.valid -eq $true -and (@($customExplicit.rules[0].logicalProcessors) -join ',') -eq '0,2,4,6')

    # ------------------------------------------------------------------------
    # 14. Application safety: -WhatIf / refusals, no journal, no host mutation
    # ------------------------------------------------------------------------
    $whatIfSets = Set-NxProcessCpuSets -ProcessName 'explorer' -CpuSetIds @(1000, 1001) -WhatIf
    Assert-Nx 'CPU sets -WhatIf plans without applying' ($whatIfSets.planned -eq $true -and $whatIfSets.applied -eq $false)
    Assert-Nx 'CPU sets -WhatIf marks session scope' ($whatIfSets.sessionScoped -eq $true -and $whatIfSets.persistence -eq 'None' -and $whatIfSets.registryWrites -eq $false)
    Assert-Nx 'CPU sets -WhatIf opens no handle result path' (@($whatIfSets.processes | Where-Object { $_.planned }).Count -ge 1)
    Assert-Nx 'CPU sets -WhatIf created no journal directory' (-not (Test-Path -LiteralPath $tmpJournal))

    $whatIfAff = Set-NxProcessAffinity -ProcessName 'explorer' -LogicalProcessors @(0, 1) -WhatIf
    Assert-Nx 'affinity -WhatIf plans without applying' ($whatIfAff.planned -eq $true -and $whatIfAff.applied -eq $false)
    Assert-Nx 'affinity -WhatIf reports the separate mechanism' ($whatIfAff.mechanism -eq 'Affinity' -and $whatIfAff.inheritedByChildren -eq $true)
    $affCrossRefuse = Set-NxProcessAffinity -ProcessName 'explorer' -LogicalProcessors @(0, 64) -WhatIf
    Assert-Nx 'affinity cross-group selection refused before apply' ($affCrossRefuse.refused -eq $true -and $affCrossRefuse.reason -match 'groups')

    $whatIfPri = Set-NxProcessPriority -ProcessName 'explorer' -PriorityClass AboveNormal -WhatIf
    Assert-Nx 'priority -WhatIf plans without applying' ($whatIfPri.planned -eq $true -and $whatIfPri.applied -eq $false)
    $prioHighRejected = $false
    try { Set-NxProcessPriority -ProcessName 'explorer' -PriorityClass High -WhatIf | Out-Null } catch { $prioHighRejected = $true }
    Assert-Nx 'priority High is refused by the parameter contract' $prioHighRejected

    $placeholder = Set-NxProcessCpuSets -ProcessName '<game>.exe' -CpuSetIds @(1) -WhatIf
    Assert-Nx 'registry placeholder is refused before lookup' ($placeholder.refused -eq $true -and $placeholder.reason -match 'placeholder')
    $pathRefused = Set-NxProcessCpuSets -ProcessName 'C:\Games\game.exe' -CpuSetIds @(1) -WhatIf
    Assert-Nx 'process path is refused in favour of an image name' ($pathRefused.refused -eq $true -and $pathRefused.reason -match 'not a path')

    $noJournal = Set-NxProcessCpuSets -ProcessName 'explorer' -CpuSetIds @(1000)
    Assert-Nx 'real CPU-set apply without a journal is refused' ($noJournal.refused -eq $true -and $noJournal.reason -match 'Journal')
    Assert-Nx 'refused apply still created no journal directory' (-not (Test-Path -LiteralPath $tmpJournal))

    $stateMissing = Get-NxProcessCpuSetState -ProcessName '__nx19_process_does_not_exist__'
    Assert-Nx 'state probe on a missing process is read-only' ($stateMissing.readOnly -eq $true -and $stateMissing.matched -eq $false)
    $selfName = (Get-Process -Id $PID).ProcessName
    $stateSelf = Get-NxProcessCpuSetState -ProcessName $selfName
    Assert-Nx 'state probe reads the current process without mutation' ($stateSelf.matched -eq $true -and @($stateSelf.processes).Count -ge 1 -and $null -ne $stateSelf.processes[0].priorityClass)

    $rollbackEmpty = Invoke-Nx19Rollback -JournalRoot $tmpJournal -TweakId 'NX19-003'
    Assert-Nx 'rollback with an empty journal is a safe no-op' ($rollbackEmpty.aborted -eq $false -and @($rollbackEmpty.restored).Count -eq 0 -and @($rollbackEmpty.failed).Count -eq 0)

    # ------------------------------------------------------------------------
    # 15. Source integrity: no hardcoded indexes, names, registry or persistence
    # ------------------------------------------------------------------------
    $enginePath = Join-Path $core 'functions\NX19.ps1'
    $source = Get-Content -LiteralPath $enginePath -Raw -Encoding UTF8
    $namePattern = '(?i)\b(9800X3D|7800X3D|7950X3D|7900X3D|13900K|14900K|13700K|12900K|9700X|Ryzen|Threadripper|EPYC|Core i[3579]|Alder Lake|Raptor Lake|Arrow Lake|Meteor Lake|Zen [2345])\b'
    Assert-Nx 'no CPU marketing-name lists in the engine' (-not ($source -match $namePattern))
    Assert-Nx 'no hardcoded logical-processor array literal' (-not ($source -match 'logicalProcessors\s*=\s*@\(\s*\d'))
    Assert-Nx 'no hardcoded core-index selection literal' (-not ($source -match 'cores\s*=\s*@\(\s*\d'))
    Assert-Nx 'no registry write path in NX19' (-not ($source -match '(?i)(Set-ItemProperty|New-ItemProperty|Set-NxRegistryValue|reg\.exe|HKLM:|HKCU:)'))
    Assert-Nx 'no persistence or task-creation path in NX19' (-not ($source -match '(?i)(New-ScheduledTask|schtasks|RunOnce|Start-Process|Invoke-WebRequest|Invoke-RestMethod|curl\.exe)'))
    Assert-Nx 'no .NET affinity/priority setter bypass' (-not ($source -match '\.ProcessorAffinity\s*='))
    Assert-Nx 'no copied Rust/XOS identifiers' (-not ($source -match '(?i)(parse_cores|parse_caches|parse_cpu_set_entries|enumerate_dies|l3_per_die|xos_cpu|xos-cpu)'))
    Assert-Nx 'no service.json access' (-not ($source -match 'service\.json'))
    Assert-Nx 'derivation functions require a topology/model input' (((Get-Command New-NxCpuSetPlan).Parameters.Keys -contains 'Topology') -and ((Get-Command New-NxCustomSchedulingPlan).Parameters.Keys -contains 'Topology') -and ((Get-Command Resolve-NxTopologyPool).Parameters.Keys -contains 'Model') -and ((Get-Command New-NxTopologyModel).Parameters.Keys -contains 'CoreEntries'))
    Assert-Nx 'process application functions expose -WhatIf' (((Get-Command Set-NxProcessCpuSets).Parameters.Keys -contains 'WhatIf') -and ((Get-Command Set-NxProcessAffinity).Parameters.Keys -contains 'WhatIf') -and ((Get-Command Set-NxProcessPriority).Parameters.Keys -contains 'WhatIf'))
    Assert-Nx 'registry text documents no performance outcomes' (-not ((Get-Content (Join-Path $repo 'registry\NX19.json') -Raw -Encoding UTF8) -match $perfPattern))
}
finally {
    if (Test-Path -LiteralPath $tmpJournal) { Remove-Item -LiteralPath $tmpJournal -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ("RESULT: " + $(if ($script:fail -eq 0) { 'PASSED' } else { 'FAILED' }) + " - $script:pass passed, $script:fail failed")
if ($script:fail -gt 0) { exit 1 }
exit 0
