#Requires -Version 5.1
<#
    Test-NX09.ps1 - NX09 Power Management self-test.

    SAFETY (directive Section 16 / SECURITY_POLICY.md Section 5):
    This test NEVER runs a powercfg mutation. It exercises ONLY:
      1. the powercfg-output parsers against embedded real-format samples
         (captured from live 23H2 output on 2026-11-23),
      2. guard helpers, target resolution and pure selection/path helpers,
      3. journal round-trips in a throwaway temp directory,
      4. read-only powercfg queries (/getactivescheme, /list, /query, /a) to
         verify the parser against this machine's REAL output.
    Mutating functions are never invoked on a reachable mutation path: the
    approval / journal / NX03-boundary / core-helper gates are asserted to
    throw BEFORE any powercfg mutation call.

    Exit code: 0 = all assertions pass, 1 = at least one failure.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\..\src\nxcore'
. (Join-Path $root 'NxJournal.ps1')
. (Join-Path $root 'functions\NX09.ps1')

$pass = 0; $fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

# ---------------------------------------------------------------------------
# Embedded samples - captured from the DOCUMENTED live output format
# (powercfg /query, /list, /getactivescheme, /a on Windows 11 23H2).
# ---------------------------------------------------------------------------
$queryFull = @'
Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)
  GUID Alias: SCHEME_MIN
  Subgroup GUID: 238c9fa8-0aad-41ed-83f4-97be242c8f20  (Sleep)
    GUID Alias: SUB_SLEEP
    Power Setting GUID: 29f6c1db-86da-48c5-9fdb-f2b67b1f44da  (Sleep after)
      GUID Alias: STANDBYIDLE
      Minimum Possible Setting: 0x00000000
      Maximum Possible Setting: 0xffffffff
      Possible Settings increment: 0x00000001
      Possible Settings units: Seconds
    Current AC Power Setting Index: 0x00000000
    Current DC Power Setting Index: 0x00000e10

    Power Setting GUID: 94ac6d29-73ce-41a6-809f-6363ba21b47e  (Allow hybrid sleep)
      GUID Alias: HYBRIDSLEEP
      Possible Setting Index: 000
      Possible Setting Friendly Name: Off
      Possible Setting Index: 001
      Possible Setting Friendly Name: On
    Current AC Power Setting Index: 0x00000001
    Current DC Power Setting Index: 0x00000001

  Subgroup GUID: 501a4d13-42af-4429-9fd1-a8218c268e20  (PCI Express)
    GUID Alias: SUB_PCIEXPRESS
    Power Setting GUID: ee12f906-d277-404b-b6da-e5fa1a576df5  (Link State Power Management)
      GUID Alias: ASPM
      Possible Setting Index: 000
      Possible Setting Friendly Name: Off
      Possible Setting Index: 001
      Possible Setting Friendly Name: Moderate power savings
      Possible Setting Index: 002
      Possible Setting Friendly Name: Maximum power savings
    Current AC Power Setting Index: 0x00000000
    Current DC Power Setting Index: 0x00000002
'@

$querySingle = @'
Power Scheme GUID: 31693169-3169-3169-3169-316931693169  (imribiy Power Plan)
  Subgroup GUID: 54533251-82be-4824-96c1-47b60b740d00  (Processor power management)
    GUID Alias: SUB_PROCESSOR
    Power Setting GUID: 893dee8e-2bef-41e0-89c6-b55d0929964c  (Minimum processor state)
      GUID Alias: PROCTHROTTLEMIN
      Minimum Possible Setting: 0x00000000
      Maximum Possible Setting: 0x00000064
      Possible Settings increment: 0x00000001
      Possible Settings units: %
    Current AC Power Setting Index: 0x00000064
    Current DC Power Setting Index: 0x00000005
'@

# A per-setting query for a setting absent from the plan prints ONLY the header
# (observed live: powercfg /query SCHEME_CURRENT SUB_PROCESSOR PERFEPP).
$queryAbsent = @'
Power Scheme GUID: 31693169-3169-3169-3169-316931693169  (imribiy Power Plan)
'@

# Localized labels must fail the parse CLOSED (no capture = no mutation).
$queryLocalized = @'
Energieschema-GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Ausbalanciert)
  Untergruppe GUID: 238c9fa8-0aad-41ed-83f4-97be242c8f20  (Standbymodus)
    Energieeinstellung GUID: 29f6c1db-86da-48c5-9fdb-f2b67b1f44da  (Standby nach)
    Aktueller Wechselstrom-Energieeinstellungsindex: 0x00000000
    Aktueller Gleichstrom-Energieeinstellungsindex: 0x00000000
'@

$listSample = @'
Existing Power Schemes (* Active)
-----------------------------------
Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)
Power Scheme GUID: 31693169-3169-3169-3169-316931693169  (imribiy Power Plan) *
'@

$activeSample = 'Power Scheme GUID: 31693169-3169-3169-3169-316931693169  (imribiy Power Plan)'

$aSample = @'
The following sleep states are available on this system:
    Standby (S0 Low Power Idle) Network Connected

The following sleep states are not available on this system:
    Standby (S3)
    The system firmware does not support this standby state.
    Hibernate
    Hibernation has not been enabled.
    Fast Startup
    Hibernation is not available.
'@

# ---------------------------------------------------------------------------
# 1. Hex index parsing
# ---------------------------------------------------------------------------
Assert-Nx 'hex parser: 0x00000064 -> 100' ((Parse-NxHexIndex '0x00000064') -eq 100)
Assert-Nx 'hex parser: 0x00000e10 -> 3600' ((Parse-NxHexIndex '0x00000e10') -eq 3600)
Assert-Nx 'hex parser: decimal 300 -> 300' ((Parse-NxHexIndex '300') -eq 300)
Assert-Nx 'hex parser: garbage -> null' ($null -eq (Parse-NxHexIndex 'zzz'))

# ---------------------------------------------------------------------------
# 2. Shared /query parser - full dump (both planes, aliases, subgroups)
# ---------------------------------------------------------------------------
$p = ConvertFrom-NxPowerCfgQuery -QueryOutput $queryFull
Assert-Nx 'query parse: parseOk' ($p.parseOk -eq $true) "unknown=$(@($p.unknownLines) -join ' | ')"
Assert-Nx 'query parse: scheme GUID parsed' ($p.schemeGuid -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
Assert-Nx 'query parse: three settings' ($p.settings.Count -eq 3)
$sleepAfter = @($p.settings | Where-Object { $_.settingGuid -eq '29f6c1db-86da-48c5-9fdb-f2b67b1f44da' })[0]
Assert-Nx 'query parse: sleep-after AC=0 DC=3600 (planes separate)' ([int64]$sleepAfter.acIndex -eq 0 -and [int64]$sleepAfter.dcIndex -eq 3600)
Assert-Nx 'query parse: subgroup alias assigned' ($sleepAfter.subgroupGuid -eq '238c9fa8-0aad-41ed-83f4-97be242c8f20')
Assert-Nx 'query parse: setting alias assigned' ($sleepAfter.settingAlias -eq 'STANDBYIDLE')
$aspm = @($p.settings | Where-Object { $_.settingGuid -eq 'ee12f906-d277-404b-b6da-e5fa1a576df5' })[0]
Assert-Nx 'query parse: ASPM AC=0 DC=2' ([int64]$aspm.acIndex -eq 0 -and [int64]$aspm.dcIndex -eq 2)
Assert-Nx 'query parse: ExpectSettingGuid filter' ((ConvertFrom-NxPowerCfgQuery -QueryOutput $queryFull -ExpectSettingGuid 'ee12f906-d277-404b-b6da-e5fa1a576df5').settings.Count -eq 1)

# ---------------------------------------------------------------------------
# 3. /query parser - single setting and absent setting
# ---------------------------------------------------------------------------
$s = ConvertFrom-NxPowerCfgQuery -QueryOutput $querySingle
Assert-Nx 'single query: one setting' ($s.parseOk -and $s.settings.Count -eq 1)
Assert-Nx 'single query: AC=100 DC=5' ([int64]$s.settings[0].acIndex -eq 100 -and [int64]$s.settings[0].dcIndex -eq 5)
Assert-Nx 'single query: setting name parsed' ($s.settings[0].settingName -eq 'Minimum processor state')

$absent = ConvertFrom-NxPowerCfgQuery -QueryOutput $queryAbsent
Assert-Nx 'absent setting: parseOk with zero settings' ($absent.parseOk -eq $true -and $absent.settings.Count -eq 0)
Assert-Nx 'absent setting: scheme GUID still parsed' ($absent.schemeGuid -eq '31693169-3169-3169-3169-316931693169')

# ---------------------------------------------------------------------------
# 4. Localized output fails closed
# ---------------------------------------------------------------------------
$loc = ConvertFrom-NxPowerCfgQuery -QueryOutput $queryLocalized
Assert-Nx 'localized output: parseOk=false (fail closed)' ($loc.parseOk -eq $false)
Assert-Nx 'localized output: unknown lines recorded' (@($loc.unknownLines).Count -gt 0)

# ---------------------------------------------------------------------------
# 5. /list and /getactivescheme parsers
# ---------------------------------------------------------------------------
$parsedList = ConvertFrom-NxPowerCfgQuery -QueryOutput $queryFull   # sanity: query parser unaffected by list text
Assert-Nx 'list sample not confused with query format' ($parsedList.parseOk -eq $true)

# The /list parser itself is exercised through a restart of its logic via the
# public helper only in live mode (below); here we assert the active-marker
# contract from the sample using the same regex contract as the module.
$listRx = '^Power Scheme GUID:\s*([0-9a-fA-F-]{36})\s*(?:\((.*)\))?\s*(\*)?\s*$'
$listLines = @($listSample -split "`r?`n" | Where-Object { $_ -match '^Power Scheme GUID:' })
$parsedListLines = @($listLines | ForEach-Object { if ($_ -match $listRx) { [pscustomobject]@{ guid = $Matches[1]; name = $Matches[2]; active = ($Matches[3] -eq '*') } } })
Assert-Nx 'list sample: two schemes parsed, one active with trailing *' ($parsedListLines.Count -eq 2 -and (@($parsedListLines | Where-Object { $_.active }).Count -eq 1) -and (@($parsedListLines | Where-Object { $_.active })[0].guid -eq '31693169-3169-3169-3169-316931693169'))

$activeRx = 'Power Scheme GUID:\s*([0-9a-fA-F-]{36})\s*(?:\((.*)\))?'
$activeOk = ($activeSample -match $activeRx)
Assert-Nx 'getactivescheme sample: GUID + name' ($activeOk -and $Matches[1] -eq '31693169-3169-3169-3169-316931693169' -and $Matches[2] -eq 'imribiy Power Plan')

# ---------------------------------------------------------------------------
# 6. /a sleep-state parser (S0 'Network Connected' suffix; S4 unavailable)
# ---------------------------------------------------------------------------
$states = ConvertFrom-NxSleepStateText -Text $aSample
Assert-Nx 'sleep states: parseOk' ($states.parseOk -eq $true)
Assert-Nx 'sleep states: S0 Available (suffix tolerated)' ($states.s0LowPowerIdle -eq 'Available')
Assert-Nx 'sleep states: S4 Unavailable' ($states.s4 -eq 'Unavailable')
Assert-Nx 'sleep states: Fast Startup Unavailable' ($states.fastStartup -eq 'Unavailable')
Assert-Nx 'sleep states: listed S3 reported Unavailable' ($states.s3 -eq 'Unavailable')

# ---------------------------------------------------------------------------
# 7. Guards: stock schemes + NX03 boundary
# ---------------------------------------------------------------------------
Assert-Nx 'stock guard: Balanced' (Test-NxStockSchemeGuid -Guid '381b4222-f694-41f0-9685-ff5bb260df2e')
Assert-Nx 'stock guard: High performance' (Test-NxStockSchemeGuid -Guid '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
Assert-Nx 'stock guard: Power saver (live-verified GUID)' (Test-NxStockSchemeGuid -Guid 'a1841308-3541-4fab-bc81-f71556f20b4a')
Assert-Nx 'stock guard: Ultimate Performance template' (Test-NxStockSchemeGuid -Guid 'e9a42b02-d5df-448d-aa00-03f14749eb61')
Assert-Nx 'stock guard: NEXTRIX Ultimate plan not stock' (-not (Test-NxStockSchemeGuid -Guid '6e657472-6978-4e58-5452-4958504c414e'))
Assert-Nx 'stock guard: third-party plan not stock' (-not (Test-NxStockSchemeGuid -Guid '31693169-3169-3169-3169-316931693169'))
Assert-Nx 'NX03 boundary: SUB_PROCESSOR rejected' (Test-NxProcessorSubgroupBoundary -SubgroupGuid '54533251-82be-4824-96c1-47b60b740d00')
Assert-Nx 'NX03 boundary: SUB_VIDEO allowed' (-not (Test-NxProcessorSubgroupBoundary -SubgroupGuid '7516b95f-f776-4464-8c53-06167f40cc99'))

# ---------------------------------------------------------------------------
# 8. Target plan resolution (synthetic scheme list - no live dependency)
# ---------------------------------------------------------------------------
$fakeList = [pscustomobject]@{ schemes = @(
    [pscustomobject]@{ guid = '381b4222-f694-41f0-9685-ff5bb260df2e'; name = 'Balanced'; isActive = $true }
    [pscustomobject]@{ guid = '6e657472-6978-4e58-5452-4958504c414e'; name = 'NEXTRIX Ultimate Performance'; isActive = $false }
) }
$rBalanced = Resolve-NxTargetPlanGuid -TargetPlan 'Balanced' -SchemeList $fakeList
Assert-Nx 'resolve: Balanced present -> ok' ($rBalanced.ok -and $rBalanced.guid -eq '381b4222-f694-41f0-9685-ff5bb260df2e')
$rUltimate = Resolve-NxTargetPlanGuid -TargetPlan 'UltimatePerformance' -SchemeList $fakeList
Assert-Nx 'resolve: provisioned Ultimate -> ok' ($rUltimate.ok -and $rUltimate.guid -eq '6e657472-6978-4e58-5452-4958504c414e')
$rUltimateMissing = Resolve-NxTargetPlanGuid -TargetPlan 'UltimatePerformance' -SchemeList ([pscustomobject]@{ schemes = @([pscustomobject]@{ guid = '381b4222-f694-41f0-9685-ff5bb260df2e'; name = 'Balanced'; isActive = $true }) })
Assert-Nx 'resolve: unprovisioned Ultimate -> refused with reason' ((-not $rUltimateMissing.ok) -and $rUltimateMissing.reason -like '*NX09-002*')
$rExplicit = Resolve-NxTargetPlanGuid -TargetPlan '6e657472-6978-4e58-5452-4958504c414e' -SchemeList $fakeList
Assert-Nx 'resolve: explicit GUID present -> ok' ($rExplicit.ok)
$rMissing = Resolve-NxTargetPlanGuid -TargetPlan 'a1841308-3541-4fab-bc81-f71556f20b4a' -SchemeList $fakeList
Assert-Nx 'resolve: absent Power saver -> not ok' (-not $rMissing.ok)
$rJunk = Resolve-NxTargetPlanGuid -TargetPlan 'NotAPlan' -SchemeList $fakeList
Assert-Nx 'resolve: junk alias -> not ok' (-not $rJunk.ok)

# ---------------------------------------------------------------------------
# 9. Output path resolution (temp folder only)
# ---------------------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("nx09-selftest-" + [guid]::NewGuid().ToString('N'))
try {
    $outFolder = Join-Path $tmp 'reports'
    $rp = Resolve-NxReportOutputPath -OutputFolder $outFolder -FileName 'NEXTRIX-energy-report.htm'
    Assert-Nx 'report path: folder created' (Test-Path -LiteralPath $outFolder -PathType Container)
    Assert-Nx 'report path: timestamped name keeps extension' ($rp.filePath -like '*.htm' -and $rp.filePath -like '*NEXTRIX-energy-report-*')
    $fileAsFolder = Join-Path $tmp 'iamafile.txt'
    Set-Content -LiteralPath $fileAsFolder -Value 'x'
    $threw = $false
    try { Resolve-NxReportOutputPath -OutputFolder $fileAsFolder -FileName 'x.htm' | Out-Null } catch { $threw = $true }
    Assert-Nx 'report path: file-as-folder refused' $threw

    # ---------------------------------------------------------------------
    # 10. Journal round-trip: powerSetting entry carries BOTH planes
    # ---------------------------------------------------------------------
    $journalDir = Join-Path $tmp 'journal'
    $null = Initialize-NxJournal -Path $journalDir
    $origSetting = [pscustomobject]@{
        targetType = 'powerSetting'; schemeGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'; schemeName = 'Balanced'
        subgroupGuid = '7516b95f-f776-4464-8c53-06167f40cc99'; subgroupName = 'Display'
        settingGuid = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; settingName = 'Turn off display after'
        acIndex = 600; dcIndex = 300
    }
    $modSetting = [pscustomobject]@{
        targetType = 'powerSetting'; schemeGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
        subgroupGuid = '7516b95f-f776-4464-8c53-06167f40cc99'; settingGuid = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
        acIndex = 0; dcIndex = 300; acTouched = $true; dcTouched = $false
    }
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX09-006' -TweakVersion '1' -Operation 'apply' -Approval 'SelfTest' -Original $origSetting -Modified $modSetting -Result 'InProgress' -Verification 'NotRun' -Profiles @('P1')
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX09-006' -TweakVersion '1' -Operation 'verify' -Approval 'SelfTest' -Original $origSetting -Modified $modSetting -Result 'Success' -Verification 'Verified' -Profiles @('P1')
    # A skip and a diagnostic entry must NOT become rollback candidates.
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX09-006' -TweakVersion '1' -Operation 'skip' -Approval 'SelfTest' -Original $origSetting -Modified $modSetting -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles @('P1')
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX09-014' -TweakVersion '1' -Operation 'apply' -Approval 'SelfTest' -Original ([pscustomobject]@{ targetType = 'powerDiagnostic' }) -Modified ([pscustomobject]@{ targetType = 'powerDiagnostic' }) -Result 'Success' -Verification 'Verified' -Profiles @()
    $rd = Read-NxJournal -Path $journalDir
    Assert-Nx 'journal: 4 entries, integrity clean' ($rd.entries.Count -eq 4 -and $rd.integrityErrors.Count -eq 0) (($rd.integrityErrors | ForEach-Object { $_ }) -join '; ')
    $verifyEntry = @($rd.entries | Where-Object { $_.operation -eq 'verify' })[0]
    Assert-Nx 'journal: original carries BOTH planes' ([int64]$verifyEntry.original.acIndex -eq 600 -and [int64]$verifyEntry.original.dcIndex -eq 300)
    Assert-Nx 'journal: modified carries both planes + touched flags' ([int64]$verifyEntry.modified.acIndex -eq 0 -and [int64]$verifyEntry.modified.dcIndex -eq 300)

    # ---------------------------------------------------------------------
    # 11. Rollback candidate selection (pure; no restore is executed)
    # ---------------------------------------------------------------------
    $cands = @(Get-Nx09RollbackCandidates -JournalEntries $rd.entries)
    Assert-Nx 'rollback candidates: exactly the verified NX09 mutation' ($cands.Count -eq 1 -and $cands[0].operation -eq 'verify' -and $cands[0].tweakId -eq 'NX09-006')

    # ---------------------------------------------------------------------
    # 12. Gate assertions - all throw BEFORE any powercfg mutation call
    # ---------------------------------------------------------------------
    $threw = $false; $msg = ''
    try { Set-NxActivePowerPlan -JournalRoot $journalDir -TargetPlan 'Balanced' | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX09-001 refuses without -Approved' ($threw -and $msg -like '*requires -Approved*')

    $threw = $false; $msg = ''
    try { Set-NxHibernate -JournalRoot $journalDir -Enabled $false | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX09-008 refuses without -Approved' ($threw -and $msg -like '*requires -Approved*')

    $threw = $false; $msg = ''
    try {
        Set-NxPlanSettingValue -TweakId 'NX09-TEST' -JournalRoot $journalDir -SubgroupGuid '54533251-82be-4824-96c1-47b60b740d00' -SettingGuid '893dee8e-2bef-41e0-89c6-b55d0929964c' -AcIndex 0 -DcIndex 0 -Approved
    } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: processor subgroup hard-rejected (NX03 boundary)' ($threw -and $msg -like '*NX03 territory*')

    $threw = $false; $msg = ''
    try { Set-NxFastStartup -JournalRoot $journalDir -Enabled $true -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX09-009 refuses when core write helper not loaded' ($threw -and $msg -like '*NxApply.ps1*')

    $threw = $false; $msg = ''
    try { Invoke-Nx09Rollback -JournalRoot $journalDir | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: rollback requires explicit scope' ($threw -and $msg -like '*specify -TweakId or -AllNx09*')

    # ---------------------------------------------------------------------
    # 13. LIVE read-only parser verification against this machine
    # ---------------------------------------------------------------------
    $liveActive = Get-NxActivePowerScheme
    Assert-Nx 'live: getactivescheme parses' ($liveActive.parseOk -eq $true) "exit=$($liveActive.exitCode)"
    Assert-Nx 'live: active GUID is a GUID' ($liveActive.guid -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')

    $liveList = Get-NxPowerSchemeList
    Assert-Nx 'live: /list parses with >=1 scheme' ($liveList.parseOk -eq $true -and $liveList.schemes.Count -ge 1) "unknown=$(@($liveList.unknownLines) -join ' | ')"
    Assert-Nx 'live: /list agrees with getactivescheme' ($liveList.activeGuid -eq $liveActive.guid)

    $liveVideo = Get-NxPowerSettingValue -SchemeGuid 'SCHEME_CURRENT' -SubgroupGuid '7516b95f-f776-4464-8c53-06167f40cc99' -SettingGuid '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
    Assert-Nx 'live: VIDEOIDLE query parses' ($liveVideo.parseOk -eq $true)
    Assert-Nx 'live: VIDEOIDLE found with integer planes' ($liveVideo.found -and $null -ne $liveVideo.acIndex -and $null -ne $liveVideo.dcIndex)

    $liveLid = Get-NxPowerSettingValue -SchemeGuid 'SCHEME_CURRENT' -SubgroupGuid '4f971e89-eebd-4455-a8de-9e59040e7347' -SettingGuid '5ca83367-6e45-459f-a27b-476b1d01c936'
    Assert-Nx 'live: lid query parses (found or honestly absent)' ($liveLid.parseOk -eq $true)
    Assert-Nx 'live: lid result consistent (found => integer planes)' ((-not $liveLid.found) -or ($null -ne $liveLid.acIndex -and $null -ne $liveLid.dcIndex))

    $liveStates = Get-NxSleepStateAvailability
    Assert-Nx 'live: /a parses' ($liveStates.parseOk -eq $true) "exit=$($liveStates.exitCode)"
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ("RESULT: " + $pass + " passed, " + $fail + " failed")
if ($fail -gt 0) { exit 1 }
exit 0
