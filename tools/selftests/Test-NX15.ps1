#Requires -Version 5.1
<#
    Test-NX15.ps1 - NX15 (Visual & Interface) category self-test.

    SAFETY BOUNDARY: this test is read-only toward Windows and writes only to a
    throwaway temp path that it never creates through the mutation pipeline.
      - It dot-sources the engine and NX15 functions (no side effects at load).
      - It validates registry/NX15.json statically against the schema requirements.
      - It calls Get-NxContextMenuState (read-only detector).
      - It exercises Set-NxTaskbarConfiguration / Set-NxStartRecommendations with
        -WhatIf only, asserting branch selection (23H2 per-user widgets vs 24H2+
        documented policy) and that no journal directory or mutation is produced.
      - It NEVER applies, journals, or changes a Windows setting.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..\..'
$core = Join-Path $repo 'src\nxcore'
foreach ($m in 'NxJournal.ps1', 'NxBuild.ps1', 'NxVerify.ps1', 'NxHardware.ps1', 'NxCompat.ps1', 'NxRollback.ps1', 'NxApply.ps1') {
    . (Join-Path $core $m)
}
. (Join-Path $core 'functions\NX15.ps1')

$script:pass = 0
$script:fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$tmpJournal = Join-Path ([IO.Path]::GetTempPath()) ('nx15-selftest-' + [guid]::NewGuid().ToString('N'))

try {
    # ------------------------------------------------------------------------
    # 0. Module surface
    # ------------------------------------------------------------------------
    $fns = @('Set-NxTaskbarConfiguration', 'Set-NxStartRecommendations', 'Get-NxContextMenuState', 'Get-Nx15BuildNumber')
    $missing = @($fns | Where-Object { $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    Assert-Nx 'NX15 functions are defined' ($missing.Count -eq 0) ($missing -join ',')
    Assert-Nx 'private journaled helper is defined' ($null -ne (Get-Command -Name 'Invoke-Nx15JournaledRegistryWrite' -ErrorAction SilentlyContinue))

    # ------------------------------------------------------------------------
    # 1. Registry file: 14 entries, required fields, unique targets, boundaries
    # ------------------------------------------------------------------------
    $schema = Get-Content (Join-Path $repo 'registry\schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cat = Get-Content (Join-Path $repo 'registry\NX15.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $tweaks = @($cat.tweaks)
    Assert-Nx 'NX15.json declares 14 entries' ($tweaks.Count -eq 14) ("count=$($tweaks.Count)")
    Assert-Nx 'NX15.json category id' ($cat.category -eq 'NX15')

    $expectedIds = @(1..14 | ForEach-Object { 'NX15-{0:000}' -f $_ })
    $actualIds = @($tweaks | ForEach-Object { $_.id })
    Assert-Nx 'all NX15-001..014 present' ((@($expectedIds | Where-Object { $actualIds -notcontains $_ })).Count -eq 0)

    $fieldIssues = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tweaks) {
        foreach ($rf in @($schema.requiredFields)) {
            if (-not $t.PSObject.Properties[$rf]) { $fieldIssues.Add("$($t.id): $rf") }
        }
        if (@($schema.riskClasses) -notcontains $t.risk) { $fieldIssues.Add("$($t.id): risk") }
        if (@($schema.evidenceLevels) -notcontains $t.evidence) { $fieldIssues.Add("$($t.id): evidence") }
        if (@($schema.statuses) -notcontains $t.status) { $fieldIssues.Add("$($t.id): status") }
        if (@($schema.modificationTypes) -notcontains $t.modificationType) { $fieldIssues.Add("$($t.id): modificationType") }
    }
    Assert-Nx 'required fields and enums valid' ($fieldIssues.Count -eq 0) ($fieldIssues -join '; ')

    $targetMap = @{}
    $dup = New-Object System.Collections.Generic.List[string]
    $badTarget = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tweaks) {
        foreach ($a in @($t.apply.actions)) {
            if ($a.type -ne 'registry') { continue }
            $key = ("$($a.path)|$($a.name)").ToLower()
            if ($targetMap.ContainsKey($key)) { $dup.Add("$($t.id) duplicates $($targetMap[$key]) -> $key") } else { $targetMap[$key] = $t.id }
            if ($a.path -match 'ControlSet00[12]') { $badTarget.Add("$($t.id): ControlSet00x") }
            if ($a.name -eq 'Start_IrisRecommendations') { $badTarget.Add("$($t.id): NX01-004 target") }
            if ($a.name -eq 'RotatingLockScreenOverlayEnabled' -or $a.name -eq 'SubscribedContent-338387Enabled') { $badTarget.Add("$($t.id): NX01-006 target") }
            if ($a.name -eq 'ToastEnabled' -and $a.path -like '*PushNotifications') { $badTarget.Add("$($t.id): NX01-007 target") }
        }
    }
    Assert-Nx 'no duplicate registry targets inside NX15' ($dup.Count -eq 0) ($dup -join '; ')
    Assert-Nx 'no forbidden/boundary targets' ($badTarget.Count -eq 0) ($badTarget -join '; ')

    $defined = @($tweaks | Where-Object { $_.status -eq 'Defined' } | ForEach-Object { $_.id })
    Assert-Nx 'NX15-009 is the only Defined entry (honest context-menu gate)' ($defined.Count -eq 1 -and $defined[0] -eq 'NX15-009') ($defined -join ',')
    $fnActions = @($tweaks | Where-Object { @($_.apply.actions) | Where-Object { $_.type -eq 'function' } } | ForEach-Object { $_.id })
    Assert-Nx 'function entries are 004, 005, 009' ($fnActions.Count -eq 3 -and $fnActions -contains 'NX15-004' -and $fnActions -contains 'NX15-005' -and $fnActions -contains 'NX15-009') ($fnActions -join ',')
    $perfClaim = @($tweaks | Where-Object { @($_.sideEffects) -match '(?i)\b(faster|smoother|lower latency|fps)\b' })
    Assert-Nx 'no performance claims in side effects' ($perfClaim.Count -eq 0) (@($perfClaim | ForEach-Object { $_.id }) -join ',')

    # ------------------------------------------------------------------------
    # 2. Read-only detector + WhatIf branch selection (no journal, no mutation)
    # ------------------------------------------------------------------------
    $cm = Get-NxContextMenuState
    Assert-Nx 'context menu detector is read-only' ($cm.readOnly -eq $true)
    Assert-Nx 'context menu mutation not shipped' ($cm.mutationSupported -eq $false -and $cm.status -eq 'Defined')
    Assert-Nx 'context menu detector classifies the build' ($cm.buildClass -in @('22H2Or23H2','24H2PlusUnverified','OutsideVerifiedFamily'))

    $t23 = Set-NxTaskbarConfiguration -JournalRoot $tmpJournal -BuildNumber 22631 -WhatIf
    Assert-Nx 'taskbar 23H2: per-user widgets branch' ($t23.skipped -eq $false -and $t23.widgetsMechanism -eq 'PerUserValue' -and $t23.ucpdPolicyFallback -eq $false)
    Assert-Nx 'taskbar 23H2: four planned layers' (@($t23.layers).Count -eq 4)

    $t24 = Set-NxTaskbarConfiguration -JournalRoot $tmpJournal -BuildNumber 26100 -WhatIf
    Assert-Nx 'taskbar 24H2+: documented policy fallback (no TaskbarDa write)' ($t24.widgetsMechanism -eq 'DocumentedPolicy' -and $t24.ucpdPolicyFallback -eq $true)
    Assert-Nx 'taskbar 24H2+: four planned layers' (@($t24.layers).Count -eq 4)

    $tOut = Set-NxTaskbarConfiguration -JournalRoot $tmpJournal -BuildNumber 30000 -WhatIf
    Assert-Nx 'taskbar out-of-scope build skips with no layers' ($tOut.skipped -eq $true -and @($tOut.layers).Count -eq 0)

    $s23 = Set-NxStartRecommendations -JournalRoot $tmpJournal -BuildNumber 22631 -WhatIf
    Assert-Nx 'start 23H2: no 24H2+ account policy' ($s23.accountNotificationsApplied -eq $false -and @($s23.layers).Count -eq 3)
    $s24 = Set-NxStartRecommendations -JournalRoot $tmpJournal -BuildNumber 26100 -WhatIf
    Assert-Nx 'start 24H2+: documented account policy layer' ($s24.accountNotificationsApplied -eq $true -and @($s24.layers).Count -eq 4)

    Assert-Nx 'WhatIf created no journal directory and no mutation' (-not (Test-Path -LiteralPath $tmpJournal))
}
finally {
    if (Test-Path -LiteralPath $tmpJournal) { Remove-Item -LiteralPath $tmpJournal -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ("RESULT: " + $(if ($script:fail -eq 0) { 'PASSED' } else { 'FAILED' }) + " - $script:pass passed, $script:fail failed")
if ($script:fail -gt 0) { exit 1 }
exit 0
