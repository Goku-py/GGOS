#Requires -Version 5.1
<#
    Test-NX17.ps1 - NX17 (Advanced Windows Configuration) category self-test.

    SAFETY BOUNDARY (stricter than the general category tests, because this category
    is BCD/device-adjacent):
      - It dot-sources the engine and NX17 functions (no side effects at load).
      - It validates registry/NX17.json statically against the schema requirements.
      - It calls ONLY read-only functions that touch the registry/service table and
        the pure BCD text parser. It NEVER invokes bcdedit, verifier, Get-PnpDevice or
        any device query on this machine, and it NEVER writes BCD, a device property,
        a Driver Verifier setting or a Windows setting.
      - It exercises Set-Nx17DeviceInstallationPolicy with -WhatIf only and asserts
        that no journal directory or mutation is produced.
    Run with Windows PowerShell 5.1 from the repo root:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\selftests\Test-NX17.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..\..'
$core = Join-Path $repo 'src\nxcore'
foreach ($m in 'NxJournal.ps1', 'NxBuild.ps1', 'NxVerify.ps1', 'NxHardware.ps1', 'NxCompat.ps1', 'NxRollback.ps1', 'NxApply.ps1') {
    . (Join-Path $core $m)
}
. (Join-Path $core 'functions\NX17.ps1')

$script:pass = 0
$script:fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$tmpJournal = Join-Path ([IO.Path]::GetTempPath()) ('nx17-selftest-' + [guid]::NewGuid().ToString('N'))

try {
    # ------------------------------------------------------------------------
    # 0. Module surface
    # ------------------------------------------------------------------------
    $fns = @(
        'Get-Nx17TimerResolutionReport', 'Get-Nx17DynamicTickPolicy', 'Get-Nx17HpetPolicy',
        'Get-Nx17PlatformClockReport', 'Get-Nx17CuratedBcdConfiguration', 'Get-Nx17MsiModeInventory',
        'Get-Nx17InterruptAffinityInventory', 'Get-Nx17SystemResponsivenessState',
        'Get-Nx17NetworkThrottlingState', 'Get-Nx17MultimediaSchedulerState',
        'Set-Nx17DeviceInstallationPolicy', 'Get-Nx17MemoryManagerState',
        'Get-Nx17PowerThrottlingState', 'Get-Nx17DriverVerifierState'
    )
    $missing = @($fns | Where-Object { $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    Assert-Nx 'all 14 NX17 entry functions are defined' ($missing.Count -eq 0) ($missing -join ',')

    $setters = @(Get-Command -CommandType Function | Where-Object { $_.Name -like 'Set-Nx17*' } | ForEach-Object { $_.Name })
    Assert-Nx 'exactly one mutating NX17 function exists' ($setters.Count -eq 1 -and $setters[0] -eq 'Set-Nx17DeviceInstallationPolicy') ($setters -join ',')

    # Static proof of the read-only external invocations.
    $bcdDef = (Get-Command -Name 'Get-Nx17BcdElements').Definition
    Assert-Nx 'BCD helper executes only the /enum form' ($bcdDef -match '&\s*\$exe\s+/enum' -and $bcdDef -notmatch '/set\s' -and $bcdDef -notmatch '/deletevalue')
    $verDef = (Get-Command -Name 'Get-Nx17DriverVerifierState').Definition
    Assert-Nx 'Driver Verifier helper queries only (/querysettings)' ($verDef -match '&\s*\$exe\s+/querysettings')
    $setDef = (Get-Command -Name 'Set-Nx17DeviceInstallationPolicy').Definition
    Assert-Nx 'the only write is journal-first and verified' ($setDef -match 'Add-NxJournalEntry' -and $setDef -match 'Test-NxConfigurationState' -and $setDef -match 'Restore-NxRegistryOriginal')

    # ------------------------------------------------------------------------
    # 1. Registry file shape and policy
    # ------------------------------------------------------------------------
    $schema = Get-Content (Join-Path $repo 'registry\schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cat = Get-Content (Join-Path $repo 'registry\NX17.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $tweaks = @($cat.tweaks)
    Assert-Nx 'NX17.json declares 14 entries' ($tweaks.Count -eq 14) ("count=$($tweaks.Count)")
    Assert-Nx 'NX17.json category id' ($cat.category -eq 'NX17')

    $expectedIds = @(1..14 | ForEach-Object { 'NX17-{0:000}' -f $_ })
    $actualIds = @($tweaks | ForEach-Object { $_.id })
    Assert-Nx 'all NX17-001..014 present' ((@($expectedIds | Where-Object { $actualIds -notcontains $_ })).Count -eq 0) (@($expectedIds | Where-Object { $actualIds -notcontains $_ }) -join ',')

    $fieldIssues = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tweaks) {
        foreach ($rf in @($schema.requiredFields)) {
            if (-not $t.PSObject.Properties[$rf]) { $fieldIssues.Add("$($t.id): $rf") }
        }
        foreach ($pair in @(@('risk', $schema.riskClasses), @('evidence', $schema.evidenceLevels), @('status', $schema.statuses), @('kind', $schema.kinds), @('modificationType', $schema.modificationTypes), @('privileges', $schema.privileges), @('restart', $schema.restartRequirements), @('approval', $schema.approvalModels))) {
            if (@($pair[1]) -notcontains $t.($pair[0])) { $fieldIssues.Add("$($t.id): $($pair[0])='$($t.($pair[0]))'") }
        }
        if (-not $t.presetExcluded) { $fieldIssues.Add("$($t.id): presetExcluded must be true") }
        if (@('EXPERIMENTAL', 'TROUBLESHOOTING') -contains $t.risk -and -not $t.presetExcluded) { $fieldIssues.Add("$($t.id): risk requires presetExcluded") }
        if ($t.risk -eq 'ADVANCED' -and [string]$t.approval -ne 'ExplicitConsent') { $fieldIssues.Add("$($t.id): ADVANCED requires ExplicitConsent") }
    }
    Assert-Nx 'required fields, enums, preset exclusion and consent policy valid' ($fieldIssues.Count -eq 0) ($fieldIssues -join '; ')

    # Target-shape discipline: NX17 declares no direct registry action at all, so every
    # write must pass through a named function that journals (NX17-011). The explicit
    # value-name scan below is the anti-duplication gate for that one target.
    $targetMap = @{}
    $dup = New-Object System.Collections.Generic.List[string]
    $badTarget = New-Object System.Collections.Generic.List[string]
    $regActions = New-Object System.Collections.Generic.List[object]
    $fnActions = New-Object System.Collections.Generic.List[object]
    foreach ($t in $tweaks) {
        foreach ($a in @($t.apply.actions)) {
            if ($a.type -eq 'registry') {
                $regActions.Add([pscustomobject]@{ tweakId = $t.id; path = $a.path; name = $a.name })
                $key = ("$($a.path)|$($a.name)").ToLower()
                if ($targetMap.ContainsKey($key)) { $dup.Add("$($t.id) duplicates $($targetMap[$key]) -> $key") } else { $targetMap[$key] = $t.id }
                if ($a.path -match 'ControlSet00[12]') { $badTarget.Add("$($t.id): ControlSet00x") }
                if ($a.name -match '^(MitigationOptions|MitigationAuditOptions|FeatureSettingsOverride|FeatureSettingsOverrideMask)$') { $badTarget.Add("$($t.id): mitigation target") }
                if ("$($a.path) $($a.name)" -match '(?i)bcd|MSISupported|DevicePolicy|DevicePriority|AssignmentSetOverride') { $badTarget.Add("$($t.id): BCD/device target via registry action") }
            } elseif ($a.type -eq 'function') {
                $fnActions.Add([pscustomobject]@{ tweakId = $t.id; function = $a.function })
                if (-not [string]::IsNullOrWhiteSpace([string]$a.path)) { $badTarget.Add("$($t.id): function action carries a path") }
            }
        }
    }
    Assert-Nx 'no duplicate registry targets inside NX17' ($dup.Count -eq 0) ($dup -join '; ')
    Assert-Nx 'no forbidden/banned/BCD/device targets' ($badTarget.Count -eq 0) ($badTarget -join '; ')
    Assert-Nx 'every NX17 action is a named function (no direct registry writer)' ($regActions.Count -eq 0 -and $fnActions.Count -eq 14)

    $writer = @($tweaks | Where-Object { $_.id -eq 'NX17-011' })
    $writerAction = @($writer[0].apply.actions)[0]
    Assert-Nx 'NX17-011 is the only mutating entry and names its dedicated function' ($writer.Count -eq 1 -and $writerAction.type -eq 'function' -and $writerAction.function -eq 'Set-Nx17DeviceInstallationPolicy' -and $writerAction.parameters.mode -eq 'Excluded')

    $setDef2 = (Get-Command -Name 'Set-Nx17DeviceInstallationPolicy').Definition
    Assert-Nx 'the writer targets exactly the documented WU driver-delivery policy value' ($setDef2 -match 'SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate' -and $setDef2 -match "'ExcludeWUDriversInQualityUpdate'" -and $setDef2 -match 'DWord')

    # Anti-duplication across the whole registry + functions tree: this one value name
    # must appear in NX17's registry entry and NX17's function module only.
    $valueName = 'ExcludeWUDriversInQualityUpdate'
    $registryHits = @(Get-ChildItem -Path (Join-Path $repo 'registry') -Filter 'NX*.json' -File | Where-Object { (Get-Content $_.FullName -Raw -Encoding UTF8).Contains($valueName) } | ForEach-Object { $_.Name })
    $functionHits = @(Get-ChildItem -Path (Join-Path $repo 'src\nxcore\functions') -Filter 'NX*.ps1' -File | Where-Object { (Get-Content $_.FullName -Raw -Encoding UTF8).Contains($valueName) } | ForEach-Object { $_.Name })
    Assert-Nx 'the writer value has exactly one registry owner' ($registryHits.Count -eq 1 -and $registryHits[0] -eq 'NX17.json') ($registryHits -join ',')
    Assert-Nx 'the writer value has exactly one function owner' ($functionHits.Count -eq 1 -and $functionHits[0] -eq 'NX17.ps1') ($functionHits -join ',')

    $xrefIds = @('NX17-008', 'NX17-009', 'NX17-010', 'NX17-012', 'NX17-013')
    $xrefViolations = @($tweaks | Where-Object { $xrefIds -contains $_.id } | Where-Object { @($_.apply.actions | Where-Object { $_.type -eq 'registry' }).Count -gt 0 } | ForEach-Object { $_.id })
    Assert-Nx 'XREF entries declare no duplicate write' ($xrefViolations.Count -eq 0) ($xrefViolations -join ',')

    $implemented = @($tweaks | Where-Object { $_.status -in @('Implemented','SyntaxValidated') } | ForEach-Object { $_.id })
    Assert-Nx 'only NX17-004 and NX17-011 are Implemented/SyntaxValidated (rest are Defined by design)' ($implemented.Count -eq 2 -and $implemented -contains 'NX17-004' -and $implemented -contains 'NX17-011') ($implemented -join ',')

    $bcdDefined = @($tweaks | Where-Object { $_.id -in @('NX17-002','NX17-003','NX17-005') } | Where-Object { $_.status -eq 'Defined' -and @($_.apply.actions | Where-Object { $_.type -eq 'registry' }).Count -eq 0 -and @($_.documentationSource) -join ' ' -match 'bcdedit' })
    Assert-Nx 'BCD entries are Defined with documented bcdedit sources and no write' (@($bcdDefined).Count -eq 3) (@($bcdDefined | ForEach-Object { $_.id }) -join ',')

    $e1Missing = @($tweaks | Where-Object { $_.evidence -eq 'E1' } | Where-Object { @($_.documentationSource | Where-Object { $_ -like 'https://learn.microsoft.com/*' }).Count -eq 0 } | ForEach-Object { $_.id })
    Assert-Nx 'every E1 entry cites a Microsoft Learn URL' ($e1Missing.Count -eq 0) ($e1Missing -join ',')

    $perfClaim = @($tweaks | Where-Object { ((@($_.description) + @($_.sideEffects) + @($_.objective)) -join ' ') -match '(?i)\b(faster|smoother|lower latency|fps)\b' } | ForEach-Object { $_.id })
    Assert-Nx 'no performance claims in description/objective/sideEffects' ($perfClaim.Count -eq 0) ($perfClaim -join ',')

    # ------------------------------------------------------------------------
    # 2. Pure BCD parser (no bcdedit execution)
    # ------------------------------------------------------------------------
    $sample = @"
Windows Boot Loader
-------------------
identifier              {current}
device                  partition=C:
description             Windows 11
disabledynamictick      Yes
bootmenupolicy          Legacy
custom:16000069         Yes
timeout                 30
"@
    $parsed = ConvertFrom-Nx17BcdEnumText -Text $sample
    Assert-Nx 'parser reads a present element value' ($parsed.disabledynamictick -eq 'Yes' -and $parsed.bootmenupolicy -eq 'Legacy')
    Assert-Nx 'parser exposes undocumented custom elements by name' ($null -ne $parsed.PSObject.Properties['custom:16000069'] -and $parsed.'custom:16000069' -eq 'Yes')
    $parsed2 = ConvertFrom-Nx17BcdEnumText -Text ("identifier              {current}`r`nuseplatformclock        No")
    Assert-Nx 'parser models absence as absence (no invented default)' ($null -eq $parsed2.PSObject.Properties['disabledynamictick'] -and $parsed2.useplatformclock -eq 'No')

    # ------------------------------------------------------------------------
    # 3. Read-only reports (registry/service reads only)
    # ------------------------------------------------------------------------
    $timer = Get-Nx17TimerResolutionReport
    Assert-Nx 'timer report is read-only and ships no mutation' ($timer.readOnly -eq $true -and $timer.mutationSupported -eq $false -and $timer.status -eq 'Defined')
    Assert-Nx 'timer report carries a counter frequency and the observed value descriptor' ($timer.stopwatchFrequency -gt 0 -and $null -ne $timer.globalTimerResolutionRequests)
    Assert-Nx 'timer report states the per-window behavior honestly' ($timer.perWindowBehavior -match '2004')

    $sr = Get-Nx17SystemResponsivenessState
    Assert-Nx 'SystemResponsiveness is an XREF to NX03-007 with no write' ($sr.ownerTweak -eq 'NX03-007' -and $sr.writeDelegated -eq $true -and $sr.mutationSupported -eq $false)

    $nt = Get-Nx17NetworkThrottlingState
    Assert-Nx 'NetworkThrottlingIndex report carries the MMCSS-only scope note' ($nt.scopeNote -match 'MMCSS' -and $nt.mutationSupported -eq $false)

    $mm = Get-Nx17MemoryManagerState
    Assert-Nx 'Memory Manager report covers exactly the five curated values' (@($mm.values).Count -eq 5)
    Assert-Nx 'Memory Manager report never touches mitigation values' (@($mm.values | Where-Object { $_.name -match 'Mitigation|FeatureSettings' }).Count -eq 0)
    Assert-Nx 'LargeSystemCache is labelled as NX05-007 owned' (@($mm.values | Where-Object { $_.name -eq 'LargeSystemCache' -and $_.owner -eq 'NX05-007' }).Count -eq 1)

    $pt = Get-Nx17PowerThrottlingState
    Assert-Nx 'PowerThrottling is an XREF to NX03-006 with no write' ($pt.ownerTweak -eq 'NX03-006' -and $pt.writeDelegated -eq $true -and $pt.mutationSupported -eq $false)

    $mms = Get-Nx17MultimediaSchedulerState
    Assert-Nx 'MMCSS composition view delegates writes to NX03-007' ($mms.ownerTweak -eq 'NX03-007' -and $mms.writeDelegated -eq $true -and $mms.mutationSupported -eq $false)

    # Caller-supplied instance id: no device enumeration, literal registry read only.
    $msi = Get-Nx17MsiModeInventory -InstanceId 'PCI\SELFTEST\0'
    Assert-Nx 'MSI inventory skips device enumeration when an instance is supplied' ($msi.enumerationSkipped -eq $true -and $msi.deviceCount -eq 1)
    Assert-Nx 'MSI inventory is per-device only and presence-gated' ($msi.globalWriteSupported -eq $false -and $msi.perDeviceOnly -eq $true -and $msi.valuePresenceGated -eq $true)
    Assert-Nx 'absent MSISupported is reported absent, not 0' (@($msi.devices)[0].msiSupportedPresent -eq $false -and $null -eq @($msi.devices)[0].msiSupportedValue)

    $aff = Get-Nx17InterruptAffinityInventory -InstanceId 'PCI\SELFTEST\0'
    Assert-Nx 'affinity inventory is read-only and reports topology availability' ($aff.mutationSupported -eq $false -and $aff.topologyFunction -eq 'Get-NxTopologyReport' -and $aff.topologyStatus -in @('Available','Unavailable'))

    # ------------------------------------------------------------------------
    # 4. Approval gate + WhatIf planning (no journal, no mutation)
    # ------------------------------------------------------------------------
    $threw = $false
    try { $null = Set-Nx17DeviceInstallationPolicy -JournalRoot $tmpJournal -Mode Excluded } catch { $threw = $true }
    Assert-Nx 'real application without -Approved is refused' ($threw -eq $true)

    $plan = Set-Nx17DeviceInstallationPolicy -JournalRoot $tmpJournal -Mode Excluded -WhatIf
    Assert-Nx 'WhatIf returns a plan without mutation' ($plan.planned -eq $true -and $plan.changed -eq $false -and $plan.verified -eq $false)
    Assert-Nx 'WhatIf created no journal directory and no mutation' (-not (Test-Path -LiteralPath $tmpJournal))
}
finally {
    if (Test-Path -LiteralPath $tmpJournal) { Remove-Item -LiteralPath $tmpJournal -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ("RESULT: " + $(if ($script:fail -eq 0) { 'PASSED' } else { 'FAILED' }) + " - $script:pass passed, $script:fail failed")
if ($script:fail -gt 0) { exit 1 }
exit 0
