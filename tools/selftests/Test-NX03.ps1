#Requires -Version 5.1
<#
    Test-NX03.ps1 - NX03 CPU & Processor Configuration self-test.

    SAFETY (directive Section 16 / SECURITY_POLICY.md Section 5):
    This test NEVER performs a configuration mutation. It exercises only:
      1. the module's static contracts (setting table, ranges, hidden flags),
      2. registry/NX03.json conformance (ids, enums, function/parameter drift,
         E1 documentation URLs, boundary separation from NX09),
      3. gate assertions - every mutating function is proven to refuse BEFORE a
         mutation call is reached (approval, journal, descriptor lookup, value
         validation, transaction kind validation, NX09's processor boundary),
      4. journal round-trips plus NX03 rollback-candidate selection in a
         throwaway temp directory,
      5. the read-only reports against this machine (no writes, ever).

    Exit code: 0 = all assertions pass, 1 = at least one failure.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\..\src\nxcore'
. (Join-Path $root 'NxJournal.ps1')
. (Join-Path $root 'NxVerify.ps1')
. (Join-Path $root 'functions\NX09.ps1')
. (Join-Path $root 'functions\NX03.ps1')

$pass = 0; $fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("nx03-selftest-" + [guid]::NewGuid().ToString('N'))
New-Item -Path $tmp -ItemType Directory -Force | Out-Null
$journalDir = Join-Path $tmp 'journal'

try {
    # -----------------------------------------------------------------------
    # 1. Setting table contracts
    # -----------------------------------------------------------------------
    Assert-Nx 'constants: SUB_PROCESSOR GUID' ($script:Nx03SubgroupProcessor -eq '54533251-82be-4824-96c1-47b60b740d00')
    Assert-Nx 'constants: twelve processor settings registered' ($script:Nx03Settings.Count -eq 12) "count=$($script:Nx03Settings.Count)"
    $guidRx = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    $guids = @()
    $badGuids = @(); $badAliases = @(); $badDocs = @()
    foreach ($k in $script:Nx03Settings.Keys) {
        $d = $script:Nx03Settings[$k]
        $guids += $d.guid
        if ($d.guid -notmatch $guidRx) { $badGuids += $k }
        if ([string]::IsNullOrWhiteSpace($d.alias)) { $badAliases += $k }
        if ($d.documentation -notlike 'https://learn.microsoft.com/*') { $badDocs += $k }
    }
    Assert-Nx 'constants: every setting GUID is well-formed' ($badGuids.Count -eq 0) ($badGuids -join ',')
    Assert-Nx 'constants: GUIDs are unique' (($guids | Sort-Object -Unique).Count -eq $guids.Count)
    Assert-Nx 'constants: every setting has an alias' ($badAliases.Count -eq 0) ($badAliases -join ',')
    Assert-Nx 'constants: every setting has a Microsoft doc URL' ($badDocs.Count -eq 0) ($badDocs -join ',')

    Assert-Nx 'range: min/max state 0..100' ($script:Nx03Settings['MinState'].max -eq 100 -and $script:Nx03Settings['MaxState'].max -eq 100)
    Assert-Nx 'range: boost mode 0..4 (documented index table)' ($script:Nx03Settings['BoostMode'].min -eq 0 -and $script:Nx03Settings['BoostMode'].max -eq 4)
    Assert-Nx 'range: EPP 0..100' ($script:Nx03Settings['Epp'].max -eq 100)
    Assert-Nx 'range: core parking min/max 0..100' ($script:Nx03Settings['CpMinCores'].max -eq 100 -and $script:Nx03Settings['CpMaxCores'].max -eq 100)
    Assert-Nx 'range: increase policy 0..3 / decrease policy 0..2' ($script:Nx03Settings['PerfIncreasePolicy'].max -eq 3 -and $script:Nx03Settings['PerfDecreasePolicy'].max -eq 2)
    Assert-Nx 'unit: hysteresis times are time check intervals (not micro/percent)' ($script:Nx03Settings['PerfIncreaseTime'].unit -eq 'time check intervals')
    Assert-Nx 'hidden flags: boost/EPP/parking/policy family hidden; min/max not' (
        $script:Nx03Settings['BoostMode'].hidden -and $script:Nx03Settings['Epp'].hidden -and
        $script:Nx03Settings['CpMinCores'].hidden -and $script:Nx03Settings['PerfIncreaseTime'].hidden -and
        (-not $script:Nx03Settings['MinState'].hidden))

    Assert-Nx 'range helper: null passes, out-of-range fails' (
        (Test-Nx03ValueInRange -Descriptor $script:Nx03Settings['Epp'] -Value $null) -and
        (-not (Test-Nx03ValueInRange -Descriptor $script:Nx03Settings['Epp'] -Value 101)))

    $threw = $false
    try { Get-Nx03SettingDescriptor -SettingKey 'DoesNotExist' | Out-Null } catch { $threw = $true }
    Assert-Nx 'descriptor lookup: unknown key throws' $threw

    # -----------------------------------------------------------------------
    # 2. Hidden-setting guidance (documented, never executed)
    # -----------------------------------------------------------------------
    Assert-Nx 'guidance: visible setting returns null' ($null -eq (Get-Nx03HiddenSettingGuidance -SettingKey 'MinState'))
    $g = Get-Nx03HiddenSettingGuidance -SettingKey 'CpMinCores'
    Assert-Nx 'guidance: hidden setting reports unhide command' ($g.unhideCommand -like 'powercfg -attributes SUB_PROCESSOR 0cc5b647-* -ATTRIB_HIDE') $g.unhideCommand
    Assert-Nx 'guidance: rehide command present' ($g.rehideCommand -like '*+ATTRIB_HIDE')
    Assert-Nx 'guidance: value applies without unhide (UI-only flag)' ($g.valueAppliesWithoutUnhide -eq $true)

    # -----------------------------------------------------------------------
    # 3. Prerequisite gate (no NxApply loaded yet)
    # -----------------------------------------------------------------------
    Assert-Nx03Prerequisites -ForPowerConfig   # must not throw: NX09 + journal helper loaded
    $threw = $false; $msg = ''
    try { Assert-Nx03Prerequisites -ForRegistryWrite } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: registry-write prerequisites name the missing NxApply helper' ($threw -and $msg -like '*Set-NxRegistryValue*') $msg

    . (Join-Path $root 'NxApply.ps1')          # defines Set-NxRegistryValue (no mutation at load)
    $threw = $false
    try { Assert-Nx03Prerequisites -ForRegistryWrite } catch { $threw = $true }
    Assert-Nx 'gate: registry-write prerequisites pass once NxApply is loaded' (-not $threw)

    # -----------------------------------------------------------------------
    # 4. Approval / journal / validation gates (each refuses before any write)
    # -----------------------------------------------------------------------
    $threw = $false; $msg = ''
    try { Set-NxProcessorMinState -JournalRoot $journalDir -AcPercent 100 -DcPercent 100 | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX03-001 refuses without -Approved' ($threw -and $msg -like '*requires -Approved*') $msg

    # Registry transaction engine must refuse without an initialized journal
    # (proven BEFORE any journal exists, so the refusal is certainly not a write).
    $threw = $false; $msg = ''
    try {
        Set-Nx03RegistryValueSet -TweakId 'NX03-TEST' -JournalRoot $journalDir -Approved -Values @(
            [pscustomobject]@{ path = 'HKLM:\SOFTWARE\NX03SelfTestNonexistent'; name = 'X'; kind = 'DWord'; value = 1; role = 'r' }
        ) | Out-Null
    } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: transaction engine refuses when the journal is not initialized' ($threw -and $msg -like '*journal not initialized*') $msg

    # Initialized journal (still no mutation: the next calls refuse earlier/validate-only).
    $null = Initialize-NxJournal -Path $journalDir
    $threw = $false; $msg = ''
    try { Set-Nx03ProcessorSetting -TweakId 'NX03-TEST' -JournalRoot $journalDir -SettingKey 'NotASetting' -AcIndex 1 -DcIndex 1 -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: unknown setting key refuses before any powercfg call' ($threw -and $msg -like '*unknown processor setting key*') $msg

    $threw = $false; $msg = ''
    try { Set-Nx03ProcessorSetting -TweakId 'NX03-TEST' -JournalRoot $journalDir -SettingKey 'BoostMode' -AcIndex 9 -DcIndex 1 -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: out-of-range index refuses (boost mode max 4)' ($threw -and $msg -like '*outside the documented range*') $msg

    $threw = $false; $msg = ''
    try { Set-NxCoreParkingPolicy -JournalRoot $journalDir -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX03-005 requires at least one core-parking value' ($threw -and $msg -like '*supply at least one of*') $msg

    $threw = $false; $msg = ''
    try { Set-NxCoreParkingPolicy -JournalRoot $journalDir -AcMinCores 80 -AcMaxCores 40 -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX03-005 rejects an inverted AC min>max pair' ($threw -and $msg -like '*exceeds AC maximum*') $msg

    $threw = $false; $msg = ''
    try { Set-NxMmcssConfiguration -JournalRoot $journalDir -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX03-007 requires a value to configure' ($threw -and $msg -like '*supply -SystemResponsiveness*') $msg

    $threw = $false; $msg = ''
    try { Set-NxMmcssConfiguration -JournalRoot $journalDir -SystemResponsiveness 5 -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX03-007 rejects a SystemResponsiveness the OS would clamp' ($threw -and $msg -like '*clamped to 20*') $msg

    $threw = $false; $msg = ''
    try { Set-NxMmcssConfiguration -JournalRoot $journalDir -TaskName 'NX03NoSuchTask' -TaskPriority 5 -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX03-007 never invents an MMCSS task key' ($threw -and $msg -like '*does not exist on this machine*') $msg

    $threw = $false; $msg = ''
    try { Set-NxMmcssConfiguration -JournalRoot $journalDir -TaskName 'Games' -SchedulingCategory 'Critical' -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX03-007 rejects an undocumented scheduling category' ($threw -and $msg -like '*High, Medium or Low*') $msg

    $threw = $false; $msg = ''
    try { Set-NxWin32PrioritySeparation -JournalRoot $journalDir -Value 64 -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX03-008 enforces the 6-bit field width (0..63)' ($threw -and $msg -like '*range*') $msg

    $threw = $false; $msg = ''
    try { Set-NxPowerThrottlingPolicy -JournalRoot $journalDir -Mode 'Sometimes' -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX03-006 accepts only documented modes' ($threw -and $msg -like '*does not belong to the set*') $msg

    $threw = $false; $msg = ''
    try {
        Set-Nx03RegistryValueSet -TweakId 'NX03-TEST' -JournalRoot $journalDir -Approved -Values @(
            [pscustomobject]@{ path = 'HKLM:\SOFTWARE\NX03SelfTestNonexistent'; name = 'X'; kind = 'Binary'; value = @(1, 2) }
        ) | Out-Null
    } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: transaction engine refuses Binary kinds before any write' ($threw -and $msg -like '*not supported by the NX03 engine*') $msg

    # NX09 boundary still holds after NX03 is loaded (NX03 must not weaken it).
    $threw = $false; $msg = ''
    try {
        Set-NxPlanSettingValue -TweakId 'NX03-BOUNDARY-PROBE' -JournalRoot $journalDir `
            -SubgroupGuid $script:Nx03SubgroupProcessor -SettingGuid $script:Nx03Settings['MinState'].guid `
            -AcIndex 1 -DcIndex 1 -Approved | Out-Null
    } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'boundary: NX09 still hard-rejects the processor subgroup' ($threw -and $msg -like '*NX03 territory*') $msg

    # -----------------------------------------------------------------------
    # 5. Journal round-trip + rollback candidate selection (no restore executed)
    # -----------------------------------------------------------------------
    $orig = [pscustomobject]@{
        targetType = 'powerSetting'; schemeGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'; schemeName = 'Balanced'
        subgroupGuid = $script:Nx03SubgroupProcessor; settingGuid = $script:Nx03Settings['MinState'].guid
        settingName = 'Minimum processor state'; settingAlias = 'PROCTHROTTLEMIN'
        acIndex = 5; dcIndex = 5                      # both planes, separately
    }
    $mod = [pscustomobject]@{
        targetType = 'powerSetting'; schemeGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
        subgroupGuid = $script:Nx03SubgroupProcessor; settingGuid = $script:Nx03Settings['MinState'].guid
        acIndex = 100; dcIndex = 5; acTouched = $true; dcTouched = $false
    }
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX03-001' -TweakVersion '1' -Operation 'apply' -Approval 'SelfTest' -Original $orig -Modified $mod -Result 'InProgress' -Verification 'NotRun' -Profiles @('P1')
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX03-001' -TweakVersion '1' -Operation 'verify' -Approval 'SelfTest' -Original $orig -Modified $mod -Result 'Success' -Verification 'Verified' -Profiles @('P1')
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX03-001' -TweakVersion '1' -Operation 'skip' -Approval 'SelfTest' -Original $orig -Modified $mod -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles @('P1')
    # A registry-target entry (006/007/008 shape) must NOT become an NX03 rollback candidate.
    $regOrig = [pscustomobject]@{ targetType = 'registry'; path = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'; name = 'Win32PrioritySeparation'; kind = 'DWord'; value = 38 }
    $regMod = [pscustomobject]@{ targetType = 'registry'; path = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'; name = 'Win32PrioritySeparation'; kind = 'DWord'; value = 2 }
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX03-008' -TweakVersion '1' -Operation 'verify' -Approval 'SelfTest' -Original $regOrig -Modified $regMod -Result 'Success' -Verification 'Verified' -Profiles @('P1')
    # An NX09 entry must stay out of NX03's selection.
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX09-006' -TweakVersion '1' -Operation 'verify' -Approval 'SelfTest' -Original $orig -Modified $mod -Result 'Success' -Verification 'Verified' -Profiles @('P1')

    $rd = Read-NxJournal -Path $journalDir
    Assert-Nx 'journal: five entries with a clean integrity chain' ($rd.entries.Count -eq 5 -and $rd.integrityErrors.Count -eq 0) (($rd.integrityErrors | ForEach-Object { $_ }) -join '; ')
    $verifyEntry = @($rd.entries | Where-Object { $_.tweakId -eq 'NX03-001' -and $_.operation -eq 'verify' })[0]
    Assert-Nx 'journal: original keeps AC and DC separate' ([int64]$verifyEntry.original.acIndex -eq 5 -and [int64]$verifyEntry.original.dcIndex -eq 5)
    Assert-Nx 'journal: modified keeps both planes and touched flags' ([int64]$verifyEntry.modified.acIndex -eq 100 -and [int64]$verifyEntry.modified.dcIndex -eq 5 -and $verifyEntry.modified.acTouched)

    $cands = @(Get-Nx03RollbackCandidates -JournalEntries $rd.entries)
    Assert-Nx 'rollback candidates: exactly the verified NX03 powerSetting entry' (
        $cands.Count -eq 1 -and $cands[0].tweakId -eq 'NX03-001' -and $cands[0].operation -eq 'verify') "count=$($cands.Count)"

    $threw = $false; $msg = ''
    try { Invoke-Nx03Rollback -JournalRoot $journalDir | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx 'gate: NX03 rollback requires explicit scope' ($threw -and $msg -like '*specify -TweakId or -AllNx03*') $msg

    # Shared-engine delegation: NxRollback.ps1 must hand NX03 powerSetting entries
    # to Invoke-Nx03Rollback. The journaled plan GUID below does not exist, so the
    # delegated run reports divergence and writes nothing (safe, read-only effect).
    . (Join-Path $root 'NxRollback.ps1')
    $delegDir = Join-Path $tmp 'delegate-journal'
    $null = Initialize-NxJournal -Path $delegDir
    $ghostOrig = [pscustomobject]@{
        targetType = 'powerSetting'; schemeGuid = '00000000-0000-0000-0000-000000000000'; schemeName = 'ghost'
        subgroupGuid = $script:Nx03SubgroupProcessor; settingGuid = $script:Nx03Settings['MaxState'].guid
        acIndex = 100; dcIndex = 100
    }
    $ghostMod = [pscustomobject]@{
        targetType = 'powerSetting'; schemeGuid = '00000000-0000-0000-0000-000000000000'
        subgroupGuid = $script:Nx03SubgroupProcessor; settingGuid = $script:Nx03Settings['MaxState'].guid
        acIndex = 90; dcIndex = 90; acTouched = $true; dcTouched = $true
    }
    $null = Add-NxJournalEntry -Path $delegDir -TweakId 'NX03-002' -TweakVersion '1' -Operation 'apply' -Approval 'SelfTest' -Original $ghostOrig -Modified $ghostMod -Result 'InProgress' -Verification 'NotRun' -Profiles @('P1')
    $null = Add-NxJournalEntry -Path $delegDir -TweakId 'NX03-002' -TweakVersion '1' -Operation 'verify' -Approval 'SelfTest' -Original $ghostOrig -Modified $ghostMod -Result 'Success' -Verification 'Verified' -Profiles @('P1')
    $rb = Invoke-NxRollback -JournalRoot $delegDir -TweakId 'NX03-002'
    $nx03Delegation = @($rb.delegated | Where-Object { $_.delegatedTo -eq 'Invoke-Nx03Rollback' })
    Assert-Nx 'delegation: shared rollback engine routes NX03 powerSetting entries to Invoke-Nx03Rollback' ($nx03Delegation.Count -eq 1) "delegated=$(@($rb.delegated).Count)"
    Assert-Nx 'delegation: missing plan is reported diverged, nothing restored/written' (@($rb.diverged).Count -eq 1 -and @($rb.restored).Count -eq 0)

    # -----------------------------------------------------------------------
    # 6. registry/NX03.json contract
    # -----------------------------------------------------------------------
    $regPath = Join-Path $PSScriptRoot '..\..\registry\NX03.json'
    $reg = Get-Content -LiteralPath $regPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Nx 'registry: 13 entries' (@($reg.tweaks).Count -eq 13) "count=$(@($reg.tweaks).Count)"
    $ids = @($reg.tweaks | ForEach-Object { $_.id })
    $expectedIds = @(1..13 | ForEach-Object { 'NX03-{0:000}' -f $_ })
    Assert-Nx 'registry: ids NX03-001..013 in order' ((($ids -join ',') -eq ($expectedIds -join ',')))
    Assert-Nx 'registry: category matches id prefix' (@($reg.tweaks | Where-Object { $_.category -ne 'NX03' }).Count -eq 0)
    Assert-Nx 'registry: risk classes preserved from the catalogue' (
        @($reg.tweaks)[0].risk -eq 'ADVANCED' -and @($reg.tweaks)[5].risk -eq 'CONDITIONAL' -and
        @($reg.tweaks)[10].risk -eq 'EXPERIMENTAL' -and @($reg.tweaks)[12].risk -eq 'CORE')
    Assert-Nx 'registry: EXPERIMENTAL/ADVANCED entries are preset-excluded' (
        @($reg.tweaks | Where-Object { (@('ADVANCED', 'EXPERIMENTAL') -contains $_.risk) -and (-not $_.presetExcluded) }).Count -eq 0)
    Assert-Nx 'registry: 008 and 010 preset-excluded (catalogue mandate)' (
        ($reg.tweaks | Where-Object { $_.id -eq 'NX03-008' }).presetExcluded -and
        ($reg.tweaks | Where-Object { $_.id -eq 'NX03-010' }).presetExcluded)
    Assert-Nx 'registry: 011/012 requiredHardware does NOT gate on gpuVendor' (
        @($reg.tweaks | Where-Object { $_.id -in @('NX03-011', 'NX03-012') } | Where-Object { $_.requiredHardware.PSObject.Properties['gpuVendor'] }).Count -eq 0)
    Assert-Nx 'registry: honest statuses (010/011/012 Defined, rest Implemented/SyntaxValidated)' (
        ($reg.tweaks | Where-Object { $_.id -eq 'NX03-010' }).status -eq 'Defined' -and
        ($reg.tweaks | Where-Object { $_.id -eq 'NX03-011' }).status -eq 'Defined' -and
        ($reg.tweaks | Where-Object { $_.id -eq 'NX03-012' }).status -eq 'Defined' -and
        @($reg.tweaks | Where-Object { $_.id -notin @('NX03-010', 'NX03-011', 'NX03-012') -and $_.status -notin @('Implemented','SyntaxValidated') }).Count -eq 0)

    $e1WithoutDoc = @()
    foreach ($t in @($reg.tweaks)) {
        if ($t.evidence -eq 'E1') {
            $urls = @($t.documentationSource | Where-Object { $_ -like 'https://*' })
            if ($urls.Count -eq 0) { $e1WithoutDoc += $t.id }
        }
    }
    Assert-Nx 'registry: every E1 entry carries a real https documentation URL' ($e1WithoutDoc.Count -eq 0) ($e1WithoutDoc -join ',')

    # Function existence + parameter drift + no cross-category mutation overlap.
    $drift = @(); $missingFn = @()
    foreach ($t in @($reg.tweaks)) {
        foreach ($a in @($t.apply.actions)) {
            if ($a.type -ne 'function') { continue }
            $cmd = Get-Command -Name ([string]$a.function) -CommandType Function -ErrorAction SilentlyContinue
            if ($null -eq $cmd) { $missingFn += "$($t.id):$($a.function)"; continue }
            if ($a.parameters) {
                foreach ($p in $a.parameters.PSObject.Properties) {
                    if (-not $cmd.Parameters.ContainsKey([string]$p.Name)) { $drift += "$($t.id):$($a.function) -$($p.Name)" }
                }
            }
        }
    }
    Assert-Nx 'registry: every action function exists in the module' ($missingFn.Count -eq 0) ($missingFn -join ',')
    Assert-Nx 'registry: no registry-parameter/signature drift' ($drift.Count -eq 0) ($drift -join '; ')

    # Boundary: no powercfg write path here addresses NX09-owned settings.
    $nx09Guids = @(
        '501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5',
        '2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226',
        '7516b95f-f776-4464-8c53-06167f40cc99', '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e',
        '238c9fa8-0aad-41ed-83f4-97be242c8f20', '29f6c1db-86da-48c5-9fdb-f2b67b1f44da',
        '4f971e89-eebd-4455-a8de-9e59040e7347', '5ca83367-6e45-459f-a27b-476b1d01c936'
    )
    $overlap = @($guids | Where-Object { $nx09Guids -contains $_ })
    Assert-Nx 'boundary: no NX03 setting GUID belongs to NX09' ($overlap.Count -eq 0) ($overlap -join ',')
    $moduleText = Get-Content -LiteralPath (Join-Path $root 'functions\NX03.ps1') -Raw
    Assert-Nx 'boundary: module never calls powercfg plan-lifecycle verbs' (
        $moduleText -notmatch "/duplicatescheme|/setactive|/delete|/restoredefaultschemes|/changename|/import")
    Assert-Nx 'boundary: module never writes firmware/OEM interfaces' (
        $moduleText -notmatch 'root\\wmi|Set-CimInstance|Invoke-CimMethod|MSPower_DeviceEnable')

    # -----------------------------------------------------------------------
    # 7. Live read-only reports (no writes anywhere)
    # -----------------------------------------------------------------------
    $inv = Get-NxCpuInventoryReport
    Assert-Nx 'live: CPU inventory is read-only' ($inv.readOnly -eq $true -and $inv.noWritesPerformed -eq $true)
    Assert-Nx 'live: CPU inventory read succeeded' ($inv.readSucceeded -eq $true) (($inv.uncertainty) -join '; ')
    Assert-Nx 'live: CPU inventory reports a known-or-explicit vendor' (@('Intel', 'AMD', 'Uncertain') -contains $inv.vendor) "vendor=$($inv.vendor)"
    Assert-Nx 'live: CPU inventory covers all twelve processor settings' ($inv.processorSettingsAvailable -eq $true -and @($inv.processorSettings).Count -eq 12) "count=$(@($inv.processorSettings).Count)"
    Assert-Nx 'live: inventory frequency note disclaims measurement' ($inv.frequencyNote -like '*not measurements*')

    $smt = Get-NxSmtTopologyReport
    Assert-Nx 'live: SMT report is read-only' ($smt.readOnly -eq $true -and $smt.noWritesPerformed -eq $true)
    Assert-Nx 'live: SMT report states no OS-level toggle exists' ($smt.osLevelToggleAvailable -eq $false -and $smt.osLevelToggleReason -like '*firmware*')
    Assert-Nx 'live: SMT state is one of the honest states' (@('Enabled-AppearsActive', 'Disabled-AppearsInactiveOrUnsupported', 'Uncertain') -contains $smt.smtState) "state=$($smt.smtState)"

    $psr = Get-NxWin32PrioritySeparationReport
    Assert-Nx 'live: priority-separation report is read-only' ($psr.readOnly -eq $true -and $psr.noWritesPerformed -eq $true)
    Assert-Nx 'live: priority-separation report keeps decoding labelled undocumented' (
        ($null -eq $psr.bitField) -or ($psr.bitField.documented -eq $false))
    Assert-Nx 'live: priority-separation report cites the reconciliation register' ((($psr.sources -join ' ') -like '*RESEARCH_RECONCILIATION*'))

    $amd = Get-NxAmdPreferredCoreReport
    Assert-Nx 'live: AMD report is read-only' ($amd.readOnly -eq $true -and $amd.noWritesPerformed -eq $true)
    Assert-Nx 'live: AMD gate matches the detected vendor' ($amd.platformAvailable -eq ($amd.cpuVendor -eq 'AMD'))
    Assert-Nx 'live: AMD preferred-core state stays Unknown' ($amd.preferredCoreState -eq 'Unknown' -and $amd.preferredCoreControl -eq 'NotDocumented')

    $intel = Get-NxIntelHybridPolicyReport
    Assert-Nx 'live: Intel report is read-only' ($intel.readOnly -eq $true -and $intel.noWritesPerformed -eq $true)
    Assert-Nx 'live: Intel gate matches the detected vendor' ($intel.platformAvailable -eq ($intel.cpuVendor -eq 'Intel'))
    Assert-Nx 'live: Intel hybrid topology is not guessed' ($intel.hybridTopology -eq 'Uncertain-HybridTopologyRequiresNX19Engine')
    if ($intel.platformAvailable) {
        Assert-Nx 'live: Intel report reads the three heterogeneous settings' (@($intel.heterogeneousPolicySettingsReadOnly).Count -eq 3)
    }

    # -----------------------------------------------------------------------
    # 8. No function-name collisions with other category modules
    # -----------------------------------------------------------------------
    $myNames = @(
        'Set-NxProcessorMinState', 'Set-NxProcessorMaxState', 'Set-NxProcessorBoostMode',
        'Set-NxProcessorEnergyPreference', 'Set-NxCoreParkingPolicy', 'Set-NxProcessorPerformancePolicy',
        'Set-NxPowerThrottlingPolicy', 'Set-NxMmcssConfiguration', 'Set-NxWin32PrioritySeparation',
        'Get-NxCpuInventoryReport', 'Get-NxSmtTopologyReport', 'Get-NxAmdPreferredCoreReport',
        'Get-NxIntelHybridPolicyReport', 'Get-NxWin32PrioritySeparationReport',
        'Get-Nx03RollbackCandidates', 'Invoke-Nx03Rollback'
    )
    $dupes = @()
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'functions') -Filter '*.ps1' -File | Where-Object { $_.Name -ne 'NX03.ps1' })) {
        $text = Get-Content -LiteralPath $f.FullName -Raw
        foreach ($n in $myNames) {
            if ($text -match ('(?m)^\s*function\s+' + [regex]::Escape($n) + '\b')) { $dupes += "$n in $($f.Name)" }
        }
    }
    Assert-Nx 'ownership: no NX03 function name is redefined by another module' ($dupes.Count -eq 0) ($dupes -join '; ')
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ("RESULT: " + $pass + " passed, " + $fail + " failed")
if ($fail -gt 0) { exit 1 }
exit 0
