#Requires -Version 5.1
<#
    Test-NX08.ps1 - NX08 (Input & Peripherals) category self-test.

    SAFETY BOUNDARY: read-only toward Windows. It writes nothing to the registry,
    starts no service, loads no driver, and uses only a throwaway temp path for
    -WhatIf bookkeeping (no journal is ever created).
      - Dot-sources the engine + NX08 functions (loading performs no I/O).
      - Validates registry/NX08.json statically against the schema and the
        catalogue's declared risk/evidence pair for each entry.
      - Cross-checks that no other category declares the same modification targets.
      - Exercises the read-only reports (they may read CIM/PnP state).
      - Exercises every mutating function with -WhatIf only, and verifies the
        approval gate and journal-first gate refuse before any write.
      - NEVER applies, journals or changes a Windows setting.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..\..'
$core = Join-Path $repo 'src\nxcore'
foreach ($m in 'NxJournal.ps1', 'NxBuild.ps1', 'NxVerify.ps1', 'NxHardware.ps1', 'NxCompat.ps1', 'NxRollback.ps1', 'NxApply.ps1') {
    . (Join-Path $core $m)
}
. (Join-Path $core 'functions\NX08.ps1')

$script:pass = 0
$script:fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$tmpJournal = Join-Path ([IO.Path]::GetTempPath()) ('nx08-selftest-' + [guid]::NewGuid().ToString('N'))

try {
    # ------------------------------------------------------------------------
    # 0. Module surface
    # ------------------------------------------------------------------------
    $expectedFunctions = @(
        'Set-NxMouseAcceleration', 'Set-NxMousePointerSpeed', 'Get-NxMousePollingRateReport',
        'Set-NxKeyboardRepeat', 'Get-NxGameControllerReport', 'Get-NxBluetoothPeripheralReport',
        'Set-NxBluetoothPowerPolicy', 'Get-NxUsbHidReport', 'Set-NxDataQueueSize', 'Get-NxDataQueueState'
    )
    $missing = @($expectedFunctions | Where-Object { $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    Assert-Nx 'NX08 public functions are defined' ($missing.Count -eq 0) ($missing -join ',')

    $mutating = @('Set-NxMouseAcceleration', 'Set-NxMousePointerSpeed', 'Set-NxKeyboardRepeat', 'Set-NxBluetoothPowerPolicy', 'Set-NxDataQueueSize')
    $contractIssues = New-Object System.Collections.Generic.List[string]
    foreach ($fn in $mutating) {
        $cmd = Get-Command -Name $fn
        foreach ($p in @('JournalRoot', 'Approved', 'Approval', 'Profiles', 'TweakVersion')) {
            if (-not $cmd.Parameters.ContainsKey($p)) { $contractIssues.Add("$fn missing -$p") }
        }
        if (-not $cmd.Parameters.ContainsKey('WhatIf')) { $contractIssues.Add("$fn missing -WhatIf (SupportsShouldProcess)") }
    }
    Assert-Nx 'mutating functions expose the required contract parameters' ($contractIssues.Count -eq 0) ($contractIssues -join '; ')

    # ------------------------------------------------------------------------
    # 1. Registry file: 8 entries, required fields, catalogue risk/evidence
    # ------------------------------------------------------------------------
    $schema = Get-Content (Join-Path $repo 'registry\schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cat = Get-Content (Join-Path $repo 'registry\NX08.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $tweaks = @($cat.tweaks)
    Assert-Nx 'NX08.json declares 8 entries' ($tweaks.Count -eq 8) ("count=$($tweaks.Count)")
    Assert-Nx 'NX08.json category/categoryName' ($cat.category -eq 'NX08' -and $cat.categoryName -eq 'Input & Peripherals')

    $expectedIds = @(1..8 | ForEach-Object { 'NX08-{0:000}' -f $_ })
    $actualIds = @($tweaks | ForEach-Object { $_.id })
    Assert-Nx 'all NX08-001..008 present' ((@($expectedIds | Where-Object { $actualIds -notcontains $_ })).Count -eq 0)

    $fieldIssues = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tweaks) {
        foreach ($rf in @($schema.requiredFields)) {
            if (-not $t.PSObject.Properties[$rf]) { $fieldIssues.Add("$($t.id): $rf") }
        }
        if (@($schema.riskClasses) -notcontains $t.risk) { $fieldIssues.Add("$($t.id): risk") }
        if (@($schema.evidenceLevels) -notcontains $t.evidence) { $fieldIssues.Add("$($t.id): evidence") }
        if (@($schema.statuses) -notcontains $t.status) { $fieldIssues.Add("$($t.id): status") }
        if (@($schema.modificationTypes) -notcontains $t.modificationType) { $fieldIssues.Add("$($t.id): modificationType") }
        if (@($schema.privileges) -notcontains $t.privileges) { $fieldIssues.Add("$($t.id): privileges") }
        if (@($schema.restartRequirements) -notcontains $t.restart) { $fieldIssues.Add("$($t.id): restart") }
        if (@($schema.approvalModels) -notcontains $t.approval) { $fieldIssues.Add("$($t.id): approval") }
        if ([int]$t.builds.min -lt 22631 -or [int]$t.builds.max -gt 26300) { $fieldIssues.Add("$($t.id): build range") }
        if (@($t.apply.actions).Count -eq 0) { $fieldIssues.Add("$($t.id): empty apply.actions") }
    }
    Assert-Nx 'required fields and enums valid' ($fieldIssues.Count -eq 0) ($fieldIssues -join '; ')

    # Catalogue alignment (TWEAK_CATALOGUE.md NX08 table: class/evidence per row).
    $catalogue = @{
        'NX08-001' = @{ risk = 'CONDITIONAL'; evidence = 'E0' }
        'NX08-002' = @{ risk = 'CONDITIONAL'; evidence = 'E0' }
        'NX08-003' = @{ risk = 'CORE';        evidence = 'E0' }
        'NX08-004' = @{ risk = 'CONDITIONAL'; evidence = 'E1' }
        'NX08-005' = @{ risk = 'CONDITIONAL'; evidence = 'E0' }
        'NX08-006' = @{ risk = 'CONDITIONAL'; evidence = 'E1' }
        'NX08-007' = @{ risk = 'CORE';        evidence = 'E1' }
        'NX08-008' = @{ risk = 'CONDITIONAL'; evidence = 'E0' }
    }
    $alignIssues = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tweaks) {
        if (-not $catalogue.ContainsKey($t.id)) { $alignIssues.Add("$($t.id): not in catalogue map"); continue }
        if ($t.risk -ne $catalogue[$t.id].risk) { $alignIssues.Add("$($t.id): risk $($t.risk) != $($catalogue[$t.id].risk)") }
        if ($t.evidence -ne $catalogue[$t.id].evidence) { $alignIssues.Add("$($t.id): evidence $($t.evidence) != $($catalogue[$t.id].evidence)") }
    }
    Assert-Nx 'risk/evidence match the catalogue rows' ($alignIssues.Count -eq 0) ($alignIssues -join '; ')

    # Function actions must resolve to the functions this module defines.
    $fnActions = @($tweaks | ForEach-Object { @($_.apply.actions) } | Where-Object { $_.type -eq 'function' })
    $unresolved = @($fnActions | Where-Object { $null -eq (Get-Command -Name ([string]$_.function) -CommandType Function -ErrorAction SilentlyContinue) } | ForEach-Object { $_.function })
    Assert-Nx 'every declared function action resolves' ($unresolved.Count -eq 0) ($unresolved -join ',')
    Assert-Nx 'all 8 entries route through functions' (@($fnActions).Count -eq 8) ("actions=$(@($fnActions).Count)")

    # XREF obligations from the catalogue/Mission text.
    $byId = @{}
    foreach ($t in $tweaks) { $byId[$t.id] = $t }
    $text = { param($id) ((@($byId[$id].technicalExplanation) + @($byId[$id].sideEffects) + @($byId[$id].documentationSource)) -join ' ') }
    Assert-Nx 'NX08-003 states the polling-rate limit' ((& $text 'NX08-003') -match 'pollingRate|polling rate|hidusbf')
    Assert-Nx 'NX08-006 references NX11-012 and remote wake' (((& $text 'NX08-006') -match 'NX11-012') -and ((& $text 'NX08-006') -match 'remote wake|RemoteWake'))
    Assert-Nx 'NX08-007 references NX09-005, NX17 and NX20-007' (((& $text 'NX08-007') -match 'NX09-005') -and ((& $text 'NX08-007') -match 'NX17') -and ((& $text 'NX08-007') -match 'NX20-007'))
    Assert-Nx 'NX08-008 states the undocumented status, community floor and no-claim stance' (((& $text 'NX08-008') -match 'undocumented|not document') -and ((& $text 'NX08-008') -match 'community') -and ((& $text 'NX08-008') -match 'unverified|no latency'))

    # No performance claims in published descriptions/side effects.
    $claimPattern = '(?i)\b(faster|smoother|lower latency|fps|boost)\b'
    $claims = @($tweaks | Where-Object { (@($_.description) + @($_.sideEffects)) -match $claimPattern } | ForEach-Object { $_.id })
    Assert-Nx 'no performance claims in descriptions/side effects' ($claims.Count -eq 0) ($claims -join ',')

    # ------------------------------------------------------------------------
    # 2. Cross-category target collision check
    # ------------------------------------------------------------------------
    $guardedTargets = @(
        'hkcu:\control panel\mouse|mousespeed',
        'hkcu:\control panel\mouse|mousethreshold1',
        'hkcu:\control panel\mouse|mousethreshold2',
        'hkcu:\control panel\mouse|mousesensitivity',
        'hkcu:\control panel\keyboard|keyboarddelay',
        'hkcu:\control panel\keyboard|keyboardspeed',
        'hklm:\system\currentcontrolset\services\bthport\parameters|systemremotewakesupported',
        'hklm:\system\currentcontrolset\services\mouclass\parameters|mousedataqueuesize',
        'hklm:\system\currentcontrolset\services\kbdclass\parameters|keyboarddataqueuesize'
    )
    $collisions = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem -Path (Join-Path $repo 'registry') -Filter 'NX*.json' -File)) {
        $other = $null
        try { $other = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        foreach ($t in @($other.tweaks)) {
            foreach ($a in @($t.apply.actions)) {
                if ($a.type -ne 'registry') { continue }
                $key = (([string]$a.path) + '|' + ([string]$a.name)).ToLower()
                if ($guardedTargets -contains $key -and $t.id -notlike 'NX08-*') {
                    $collisions.Add("$($t.id) -> $key")
                }
            }
        }
    }
    Assert-Nx 'no other category declares an NX08 registry target' ($collisions.Count -eq 0) ($collisions -join '; ')

    # Explicit ownership boundaries (USB policy / IRQ / inventory / BT service).
    $nx09 = Get-Content (Join-Path $repo 'registry\NX09.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $usbPolicy = @($nx09.tweaks | Where-Object { $_.id -eq 'NX09-005' })
    Assert-Nx 'NX09-005 exists as the USB policy owner' ($usbPolicy.Count -eq 1)
    $nx11 = Get-Content (Join-Path $repo 'registry\NX11.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $btSvc = @($nx11.tweaks | Where-Object { $_.id -eq 'NX11-012' })
    Assert-Nx 'NX11-012 exists as the Bluetooth service owner' ($btSvc.Count -eq 1)

    # ------------------------------------------------------------------------
    # 3. Read-only reports (real reads; no writes)
    # ------------------------------------------------------------------------
    $poll = Get-NxMousePollingRateReport
    Assert-Nx 'polling report is read-only and reports the limit' ($poll.readOnly -eq $true -and $poll.noWritesPerformed -eq $true -and $poll.pollingRateAvailable -eq $false)
    Assert-Nx 'polling report gives a reason for every device' (@($poll.devices | Where-Object { [string]::IsNullOrWhiteSpace($_.pollingRateReason) }).Count -eq 0)
    Assert-Nx 'polling report has no fabricated rate' (@($poll.devices | Where-Object { $null -ne $_.pollingRateHz }).Count -eq 0)

    $pad = Get-NxGameControllerReport
    Assert-Nx 'controller report is read-only with guidance only' ($pad.readOnly -eq $true -and $pad.noWritesPerformed -eq $true -and $pad.configurationSupported -eq $false)
    $falsePositives = @($pad.controllers | Where-Object { $_.reportedName -match '(?i)host controller|interrupt controller|network controller|extensible host' })
    Assert-Nx 'controller report excludes system controllers' ($falsePositives.Count -eq 0) (@($falsePositives | ForEach-Object { $_.reportedName }) -join '; ')

    $bt = Get-NxBluetoothPeripheralReport
    Assert-Nx 'bluetooth report is read-only' ($bt.readOnly -eq $true -and $bt.noWritesPerformed -eq $true)
    Assert-Nx 'bluetooth report exposes the documented machine value' ($null -ne $bt.machineRemoteWake -and $bt.machineRemoteWake.name -eq 'SystemRemoteWakeSupported')
    Assert-Nx 'bluetooth report states the NX11-012 boundary' ([string]$bt.xref -match 'NX11-012')

    $usb = Get-NxUsbHidReport
    Assert-Nx 'usb/hid report is read-only' ($usb.readOnly -eq $true -and $usb.noWritesPerformed -eq $true)
    Assert-Nx 'usb/hid report is structured' ($usb.PSObject.Properties['controllers'] -and $usb.PSObject.Properties['hidDevices'] -and $usb.PSObject.Properties['feeds'])
    Assert-Nx 'usb/hid report states its NX09-005/NX17/NX20-007 boundaries' (((@($usb.feeds) -join ' ') -match 'NX09-005') -and ((@($usb.feeds) -join ' ') -match 'NX17') -and ((@($usb.feeds) -join ' ') -match 'NX20-007'))

    $queue = Get-NxDataQueueState
    $queueRows = @($queue.values)
    Assert-Nx 'data-queue state is read-only' ($queue.readOnly -eq $true -and $queue.noWritesPerformed -eq $true)
    Assert-Nx 'data-queue state covers both class drivers' ($queueRows.Count -eq 2 -and (@($queueRows | ForEach-Object { $_.device }) -contains 'Mouse') -and (@($queueRows | ForEach-Object { $_.device }) -contains 'Keyboard'))
    Assert-Nx 'data-queue state marks absent values as the driver default 100' (@($queueRows | Where-Object { -not $_.present -and ($_.effectiveQueueDepth -ne 100 -or [string]$_.effectiveSource -notmatch 'default 100') }).Count -eq 0)
    Assert-Nx 'data-queue state never fabricates a depth for a non-DWORD value' (@($queueRows | Where-Object { $_.present -and $_.kind -ne 'DWord' -and $null -ne $_.effectiveQueueDepth }).Count -eq 0)
    Assert-Nx 'data-queue byte arithmetic uses the documented structure sizes' (@($queueRows | Where-Object { ($_.device -eq 'Mouse' -and $_.nonpagedPoolBytesAtDefault -ne 2400) -or ($_.device -eq 'Keyboard' -and $_.nonpagedPoolBytesAtDefault -ne 1200) }).Count -eq 0)

    # Privacy: every masked instance ID must drop the trailing instance segment.
    $maskedIds = @()
    $maskedIds += @($poll.devices | ForEach-Object { $_.instanceIdMasked })
    $maskedIds += @($pad.controllers | ForEach-Object { $_.instanceIdMasked })
    $maskedIds += @($usb.usbDevices | ForEach-Object { $_.instanceIdMasked })
    $maskedIds += @($usb.hidDevices | ForEach-Object { $_.instanceIdMasked })
    $badMask = @($maskedIds | Where-Object { $_ -and ($_ -notmatch '\\\.\.\.$') })
    Assert-Nx 'report instance IDs are masked (trailing segment removed)' ($badMask.Count -eq 0) (@($badMask | Select-Object -First 5) -join '; ')

    # ------------------------------------------------------------------------
    # 4. Mutating functions: WhatIf plans only (no journal, no mutation)
    # ------------------------------------------------------------------------
    $m1 = Set-NxMouseAcceleration -JournalRoot $tmpJournal -WhatIf
    Assert-Nx 'mouse acceleration WhatIf: three planned values' ($m1.planned -eq $true -and @($m1.layers).Count -eq 3)
    $m2 = Set-NxMousePointerSpeed -JournalRoot $tmpJournal -MouseSensitivity 12 -WhatIf
    Assert-Nx 'pointer speed WhatIf: one planned value' ($m2.planned -eq $true -and @($m2.layers).Count -eq 1 -and @($m2.layers)[0].value -eq '12')
    $m3 = Set-NxKeyboardRepeat -JournalRoot $tmpJournal -KeyboardDelay 1 -KeyboardSpeed 20 -WhatIf
    Assert-Nx 'keyboard repeat WhatIf: two planned values' ($m3.planned -eq $true -and @($m3.layers).Count -eq 2)
    $m4 = Set-NxBluetoothPowerPolicy -JournalRoot $tmpJournal -RemoteWake Disabled -WhatIf
    Assert-Nx 'bluetooth policy WhatIf plans or skips without writing' (($m4.planned -eq $true -or $m4.skipped -eq $true) -and @($m4.layers | Where-Object { $_.verified -eq $true }).Count -eq 0)
    $m5 = Set-NxDataQueueSize -JournalRoot $tmpJournal -Device Both -QueueSize 16 -WhatIf
    Assert-Nx 'queue size WhatIf plans the existing class keys without writing' ($m5.planned -eq $true -and @($m5.layers).Count -ge 1 -and @($m5.layers | Where-Object { $_.verified -eq $true }).Count -eq 0)
    Assert-Nx 'WhatIf created no journal directory' (-not (Test-Path -LiteralPath $tmpJournal))

    # ------------------------------------------------------------------------
    # 5. Refusal gates: approval, journal-first, parameter validation
    # ------------------------------------------------------------------------
    $approvalRefused = $false
    try { $null = Set-NxMouseAcceleration -JournalRoot $tmpJournal } catch { $approvalRefused = ([string]$_.Exception.Message -match 'requires -Approved') }
    Assert-Nx 'missing -Approved is refused before any write' ($approvalRefused -and -not (Test-Path -LiteralPath $tmpJournal))

    $journalRefused = $false
    try { $null = Set-NxKeyboardRepeat -JournalRoot $tmpJournal -KeyboardDelay 0 -KeyboardSpeed 5 -Approved } catch { $journalRefused = ([string]$_.Exception.Message -match 'journal not initialized') }
    Assert-Nx 'journal-first gate refuses an uninitialized journal' ($journalRefused -and -not (Test-Path -LiteralPath $tmpJournal))

    $rangeRefused = $false
    try { $null = Set-NxMousePointerSpeed -JournalRoot $tmpJournal -MouseSensitivity 21 -WhatIf } catch { $rangeRefused = $true }
    Assert-Nx 'out-of-range pointer speed is rejected at the boundary' $rangeRefused

    $rangeRefused = $false
    try { $null = Set-NxKeyboardRepeat -JournalRoot $tmpJournal -KeyboardDelay 4 -KeyboardSpeed 10 -WhatIf } catch { $rangeRefused = $true }
    Assert-Nx 'out-of-range keyboard delay is rejected at the boundary' $rangeRefused

    $floorMessage = ''
    try { $null = Set-NxDataQueueSize -JournalRoot $tmpJournal -Device Mouse -QueueSize 15 -WhatIf } catch { $floorMessage = [string]$_.Exception.Message }
    Assert-Nx 'below-16 queue size is refused with the community-floor reason' ($floorMessage -match 'floor' -and $floorMessage -match '16' -and $floorMessage -match 'community')

    $ceilingMessage = ''
    try { $null = Set-NxDataQueueSize -JournalRoot $tmpJournal -Device Mouse -QueueSize 101 -WhatIf } catch { $ceilingMessage = [string]$_.Exception.Message }
    Assert-Nx 'above-100 queue size is refused' ($ceilingMessage -match 'above' -and $ceilingMessage -match '100')

    $queueApprovalRefused = $false
    try { $null = Set-NxDataQueueSize -JournalRoot $tmpJournal -Device Mouse -QueueSize 16 } catch { $queueApprovalRefused = ([string]$_.Exception.Message -match 'requires -Approved') }
    Assert-Nx 'queue size change requires -Approved' ($queueApprovalRefused -and -not (Test-Path -LiteralPath $tmpJournal))

    # ------------------------------------------------------------------------
    # 6. Journal integration (temp journal only; no Windows configuration write)
    # ------------------------------------------------------------------------
    $init = Initialize-NxJournal -Path $tmpJournal
    Assert-Nx 'temp journal initializes' ($init.created -eq $true -and (Test-Path -LiteralPath (Join-Path $tmpJournal 'manifest.json')))

    $null = Get-NxMousePollingRateReport -JournalRoot $tmpJournal
    $j1 = Read-NxJournal -Path $tmpJournal
    $e1 = $j1.entries.ToArray()
    Assert-Nx 'read-only report journals exactly one ReportOnly skip' ($j1.integrityErrors.Count -eq 0 -and $e1.Count -eq 1 -and $e1[0].operation -eq 'skip' -and $e1[0].result -eq 'ReportOnly' -and $e1[0].tweakId -eq 'NX08-003')

    $null = Set-NxKeyboardRepeat -JournalRoot $tmpJournal -KeyboardDelay 0 -KeyboardSpeed 10 -WhatIf
    $j2 = Read-NxJournal -Path $tmpJournal
    Assert-Nx 'WhatIf adds no journal entry even when a journal exists' ($j2.entries.ToArray().Count -eq 1)

    $null = Get-NxUsbHidReport -JournalRoot $tmpJournal
    $j3 = Read-NxJournal -Path $tmpJournal
    Assert-Nx 'second report note is additive and the chain stays intact' ($j3.entries.ToArray().Count -eq 2 -and $j3.integrityErrors.Count -eq 0 -and $j3.entries.ToArray()[1].tweakId -eq 'NX08-007')

    $outDir = Join-Path ([IO.Path]::GetTempPath()) ('nx08-report-' + [guid]::NewGuid().ToString('N'))
    try {
        $fileReport = Get-NxMousePollingRateReport -OutputFolder $outDir
        Assert-Nx 'report file is written only to the chosen folder' ($fileReport.PSObject.Properties['reportPath'] -and (Test-Path -LiteralPath $fileReport.reportPath) -and ([string]$fileReport.reportPath).StartsWith($outDir))
        $parsed = Get-Content -LiteralPath $fileReport.reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Nx 'report JSON parses and carries the honesty flags' ($parsed.readOnly -eq $true -and $parsed.pollingRateAvailable -eq $false)
    } finally {
        if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
finally {
    if (Test-Path -LiteralPath $tmpJournal) { Remove-Item -LiteralPath $tmpJournal -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ("RESULT: " + $(if ($script:fail -eq 0) { 'PASSED' } else { 'FAILED' }) + " - $script:pass passed, $script:fail failed")
if ($script:fail -gt 0) { exit 1 }
exit 0
