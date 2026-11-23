#Requires -Version 5.1
<#
    NX03.ps1 - NEXTRIX CPU & Processor Configuration (category NX03, entries NX03-001..013).

    Companion to registry/NX03.json (single source of truth for the entries).

    BOUNDARY (hard, enforced by design not convention):
      NX09.ps1 owns the power-PLAN lifecycle (selection/duplication/deletion) and
      the display/sleep/hibernate/fast-startup/lid/PCIe-ASPM/USB-suspend settings.
      NX03 owns the SUB_PROCESSOR subgroup (54533251-82be-4824-96c1-47b60b740d00)
      plus the three scheduler-adjacent machine knobs the catalogue assigns here
      (MMCSS SystemProfile, PriorityControl\Win32PrioritySeparation, and the
      PowerThrottling policy switch). No NX03 function creates, renames, activates
      or deletes a power plan; NX09's Set-NxPlanSettingValue keeps its own hard
      rejection of this subgroup - NX03 has its own engine for its own settings
      and never weakens or bypasses that guard.

    SHARED HELPERS ARE REUSED, NEVER REDEFINED (NX09.ps1 owns them):
      Invoke-NxPowerCfg, ConvertFrom-NxPowerCfgQuery, Get-NxPowerSettingValue,
      Get-NxPowerSchemeList, Assert-NxJournalReady. Core modules own:
      Capture-NxRegistryValue / Add-NxJournalEntry / Read-NxManifest
      (NxJournal.ps1), Set-NxRegistryValue (NxApply.ps1),
      Test-NxConfigurationState (NxVerify.ps1).
      Every mutating function asserts the helpers are loaded and fails with a
      clear message instead of half-working.

    AC/DC DISCIPLINE (PROJECT_ARCHITECTURE.md Section 5): every per-plan capture
    queries the AC and DC index SEPARATELY through the shared fail-closed
    powercfg /query parser, journals BOTH planes in one original descriptor
    (separate fields), mutates only the planes the caller asked for, verifies by
    re-querying BOTH indexes, and restores both planes on a failed verify.
    Rollback is per-plane only-if-ours: a plane the owner changed after apply is
    reported diverged and never clobbered.

    OVERRIDE-ABSENCE POLICY (exact-restorability invariant, not convenience):
      powercfg /query reports only a plan's OWN overrides. A setting a plan does
      not carry is inherited from the processor power-profile defaults, and
      powercfg exposes no documented "remove this override" operation - so
      NEXTRIX cannot journal an absence it could restore byte-exactly. Such
      settings are reported Skipped (no mutation) with an exact reason and the
      documented recovery steps (unhide + set once in the Windows power UI, which
      creates the override NEXTRIX can then capture and restore). This mirrors
      NX09's fail-closed discipline: no verified capture means no mutation.

    HIDDEN SETTING UNHIDE (NX03-003/004/005/009) is DOCUMENTED, NOT PERFORMED:
      Microsoft documents these settings as "Hidden setting: Yes". Value writes
      work regardless of UI visibility; visibility is a machine-wide UI
      attribute outside the plan. NEXTRIX reports the exact documented command
      form (powercfg -attributes SUB_PROCESSOR <guid> -ATTRIB_HIDE) and never
      flips that attribute itself: an undocumented write surface with no
      per-plan scope is not worth taking for a UI-only effect.

    VALUE-CHOICE HONESTY (registry/NX03.json carries the full reasoning):
      - NX03-008 Win32PrioritySeparation: Microsoft documents the registry target
        mapping (Win32_OperatingSystem.ForegroundApplicationBoost ->
        PriorityControl\Win32PrioritySeparation) and the boost-level meaning, but
        NOT the six-bit quantum field encoding quoted by every community guide.
        Five references ship 36/38/42/0x2A/26 with zero evidence. NEXTRIX never
        picks an "optimized" value: the function requires an explicit value,
        defaults only to the documented class default (2), and labels any
        bit-field reading as undocumented.
      - NX03-009 exposes only settings with a per-setting Microsoft page (values,
        units, range). The processor performance time check interval is
        deliberately NOT writable: Microsoft publishes no unit/range page for it,
        so every reference sets it by folklore.
      - NX03-011/012 are EXPERIMENTAL read-only platform reports. No AMD
        preferred-core or Intel P/E pinning interface is documented, so nothing
        is written and no gate is invented: the CPU-vendor gate lives INSIDE the
        read-only function (NxCompat has no CPU-vendor gate; gating on
        requiredHardware.gpuVendor would gate on the wrong component).

    MUTATION SURFACE (declared per SECURITY_POLICY.md Section 4; TARGET machines
    only - never the engineering machine, directive Section 16;
    tools/selftests/Test-NX03.ps1 asserts every gate without reaching a mutation
    path):
      - powercfg /setacvalueindex and /setdcvalueindex on the active-by-default
        plan, processor subgroup only, only for settings the plan already
        carries (fail-closed capture before, re-query verification after).
      - Registry DWords/Strings under exactly three key families:
          HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling
          HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\
            SystemProfile (+ \Tasks\<existing task>)
          HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl
      Nothing else. No firmware writes: SMT, P/E policy and CPPC preferred cores
      are read-only reports plus guidance.

    Idempotency: every mutating function detects AlreadyAtState and journals a
    'skip' entry instead of re-applying.
#>

# ---------------------------------------------------------------------------
# A. Constants - every GUID was verified against the live
#    HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings store on
#    2026-11-23 (subgroup 54533251-82be-4824-96c1-47b60b740d00); each setting's
#    semantics/values/range against its Microsoft Learn page (documentationSource
#    in registry/NX03.json). PROCTHROTTLEMIN/MAX also appear in powercfg
#    /aliases on this build.
# ---------------------------------------------------------------------------
$script:Nx03SubgroupProcessor = '54533251-82be-4824-96c1-47b60b740d00'

$script:Nx03Settings = @{
    MinState = [pscustomobject]@{
        key = 'MinState'; guid = '893dee8e-2bef-41e0-89c6-b55d0929964c'; alias = 'PROCTHROTTLEMIN'
        friendlyName = 'Minimum processor state'; min = 0; max = 100; unit = '%'; hidden = $false
        documentation = 'https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-minperformance'
    }
    MaxState = [pscustomobject]@{
        key = 'MaxState'; guid = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; alias = 'PROCTHROTTLEMAX'
        friendlyName = 'Maximum processor state'; min = 0; max = 100; unit = '%'; hidden = $false
        documentation = 'https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-maxperformance'
    }
    BoostMode = [pscustomobject]@{
        key = 'BoostMode'; guid = 'be337238-0d82-4146-a960-4f3749d470c7'; alias = 'PERFBOOSTMODE'
        friendlyName = 'Processor performance boost mode'; min = 0; max = 4; unit = 'index'; hidden = $true
        documentation = 'https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfboostmode'
    }
    Epp = [pscustomobject]@{
        key = 'Epp'; guid = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'; alias = 'PERFEPP'
        friendlyName = 'Processor energy performance preference policy'; min = 0; max = 100; unit = '%'; hidden = $true
        documentation = 'https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfenergypreference'
    }
    CpMinCores = [pscustomobject]@{
        key = 'CpMinCores'; guid = '0cc5b647-c1df-4637-891a-dec35c318583'; alias = 'CPMINCORES'
        friendlyName = 'Processor performance core parking min cores'; min = 0; max = 100; unit = '%'; hidden = $true
        documentation = 'https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-core-parking-cpmincores'
    }
    CpMaxCores = [pscustomobject]@{
        key = 'CpMaxCores'; guid = 'ea062031-0e34-4ff1-9b6d-eb1059334028'; alias = 'CPMAXCORES'
        friendlyName = 'Processor performance core parking max cores'; min = 0; max = 100; unit = '%'; hidden = $true
        documentation = 'https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-core-parking-cpmaxcores'
    }
    PerfIncreaseThreshold = [pscustomobject]@{
        key = 'PerfIncreaseThreshold'; guid = '06cadf0e-64ed-448a-8927-ce7bf90eb35d'; alias = 'PERFINCTHRESHOLD'
        friendlyName = 'Processor performance increase threshold'; min = 0; max = 100; unit = '%'; hidden = $true
        documentation = 'https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfincreasethreshold'
    }
    PerfDecreaseThreshold = [pscustomobject]@{
        key = 'PerfDecreaseThreshold'; guid = '12a0ab44-fe28-4fa9-b3bd-4b64f44960a6'; alias = 'PERFDECTHRESHOLD'
        friendlyName = 'Processor performance decrease threshold'; min = 0; max = 100; unit = '%'; hidden = $true
        documentation = 'https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfdecreasethreshold'
    }
    PerfIncreaseTime = [pscustomobject]@{
        key = 'PerfIncreaseTime'; guid = '984cf492-3bed-4488-a8f9-4286c97bf5aa'; alias = 'PERFINCTIME'
        friendlyName = 'Processor performance increase time'; min = 0; max = 100; unit = 'time check intervals'; hidden = $true
        documentation = 'https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfincreasetime'
    }
    PerfDecreaseTime = [pscustomobject]@{
        key = 'PerfDecreaseTime'; guid = 'd8edeb9b-95cf-4f95-a73c-b061973693c8'; alias = 'PERFDECTIME'
        friendlyName = 'Processor performance decrease time'; min = 0; max = 100; unit = 'time check intervals'; hidden = $true
        documentation = 'https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfdecreasetime'
    }
    PerfIncreasePolicy = [pscustomobject]@{
        key = 'PerfIncreasePolicy'; guid = '465e1f50-b610-473a-ab58-00d1077dc418'; alias = 'PERFINCPOL'
        friendlyName = 'Processor performance increase policy'; min = 0; max = 3; unit = 'index'; hidden = $true
        documentation = 'https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfincreasepolicy'
    }
    PerfDecreasePolicy = [pscustomobject]@{
        key = 'PerfDecreasePolicy'; guid = '40fbefc7-2e9d-4d25-a185-0cfd8574bac6'; alias = 'PERFDECPOL'
        friendlyName = 'Processor performance decrease policy'; min = 0; max = 2; unit = 'index'; hidden = $true
        documentation = 'https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfdecreasepolicy'
    }
}

# Heterogeneous (P/E) policy settings - READ-ONLY in this module (NX03-012).
# GUIDs live-verified in the same PowerSettings store dump; Microsoft documents
# this settings family for OEM tuning only, with no end-user policy contract.
$script:Nx03HeteroSettings = @(
    [pscustomobject]@{ key = 'HeteroPolicyInEffect';        guid = '7f2f5cfa-f10c-4823-b5e1-e93ae85f46b5'; friendlyName = 'Heterogeneous policy in effect' }
    [pscustomobject]@{ key = 'HeteroThreadScheduling';      guid = '93b8b6dc-0698-4d1c-9ee4-0644e900c85d'; friendlyName = 'Heterogeneous thread scheduling policy' }
    [pscustomobject]@{ key = 'HeteroShortThreadScheduling'; guid = 'bae08b81-2d5e-4688-ad6a-13243356654b'; friendlyName = 'Heterogeneous short running thread scheduling policy' }
)

$script:Nx03AutonomousModeGuid = '8baa4a8a-14c6-4451-8e8b-14bdbd197537'   # Processor performance autonomous mode (live-verified)

$script:Nx03MmcssPath        = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$script:Nx03MmcssTasksPath   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks'
$script:Nx03ThrottlingPath   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
$script:Nx03PriorityCtrlPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'

# ---------------------------------------------------------------------------
# B. Guards / small helpers
# ---------------------------------------------------------------------------

function Assert-Nx03Prerequisites {
    <# Fails loudly when a required shared helper is not loaded. NX03 never
       redefines the NX09 power helpers or the core journal helpers - it uses
       them. #>
    [CmdletBinding()]
    param(
        [switch]$ForPowerConfig,
        [switch]$ForRegistryWrite
    )
    $need = New-Object System.Collections.Generic.List[string]
    foreach ($fn in @('Read-NxManifest', 'Add-NxJournalEntry', 'Assert-NxJournalReady')) {
        if (-not (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) { $need.Add($fn) }
    }
    if ($ForPowerConfig) {
        foreach ($fn in @('Invoke-NxPowerCfg', 'ConvertFrom-NxPowerCfgQuery', 'Get-NxPowerSettingValue', 'Get-NxPowerSchemeList')) {
            if (-not (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) { $need.Add($fn) }
        }
    }
    if ($ForRegistryWrite) {
        foreach ($fn in @('Capture-NxRegistryValue', 'Set-NxRegistryValue', 'Test-NxConfigurationState')) {
            if (-not (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) { $need.Add($fn) }
        }
    }
    if ($need.Count -gt 0) {
        throw ("NX03 requires shared helpers that are not loaded: {0}. Load the NxCore modules first (Import-NxCore loads NxJournal/NxVerify/NxApply plus the functions folder, where NX09.ps1 owns the powercfg parser and journal gate) - nothing was changed." -f ($need -join ', '))
    }
}

function Get-Nx03SettingDescriptor {
    <# Descriptor lookup by stable key (never by user-supplied text). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SettingKey)
    if (-not $script:Nx03Settings.ContainsKey($SettingKey)) {
        throw "unknown processor setting key '$SettingKey' (expected one of: $((@($script:Nx03Settings.Keys) | Sort-Object) -join ', '))"
    }
    return $script:Nx03Settings[$SettingKey]
}

function Test-Nx03ValueInRange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Descriptor,
        [AllowNull()][Nullable[int]]$Value
    )
    if ($null -eq $Value) { return $true }
    return ([int]$Value -ge [int]$Descriptor.min -and [int]$Value -le [int]$Descriptor.max)
}

function Get-Nx03HiddenSettingGuidance {
    <# DOCUMENTATION of the unhide procedure, never an action. Microsoft
       documents every processor setting used here as a hidden setting; value
       writes work regardless - only UI visibility is affected. NEXTRIX does not
       flip a machine-wide UI attribute that has no per-plan scope. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SettingKey)
    $d = Get-Nx03SettingDescriptor -SettingKey $SettingKey
    if (-not $d.hidden) { return $null }
    return [pscustomobject]@{
        settingKey                = $d.key
        friendlyName              = $d.friendlyName
        hiddenInWindowsUI         = $true
        valueAppliesWithoutUnhide = $true
        unhideCommand             = "powercfg -attributes SUB_PROCESSOR $($d.guid) -ATTRIB_HIDE"
        rehideCommand             = "powercfg -attributes SUB_PROCESSOR $($d.guid) +ATTRIB_HIDE"
        note                      = 'Visibility is a machine-wide UI attribute, not a plan value. NEXTRIX never flips it; the documented command form is reported for the owner. Run the unhide command, then set the value once in the Windows power-plan UI so a plan-level override exists that NEXTRIX can capture and restore exactly.'
        provenance                = 'Microsoft documents the setting as hidden. The -attributes/-ATTRIB_HIDE form is the long-standing powercfg mechanism for hidden power settings (widely used; not covered by the current powercfg command-line reference page) - reported as guidance, never executed by NEXTRIX.'
    }
}

function ConvertTo-Nx03Comparable {
    # Stable string form for value comparison (kind is compared separately).
    param([AllowNull()]$Value)
    return (ConvertTo-Json -InputObject $Value -Depth 6 -Compress)
}

function Restore-Nx03RegistryCapture {
    <# Exact-original registry restore used inside the NX03 transaction engine for
       its own failed verification (the journal-driven rollback path is the shared
       engine's). Writes the captured kind back verbatim; a value that never
       existed is deleted. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Descriptor)
    if ($Descriptor.existed) {
        if (-not (Test-Path $Descriptor.path)) { New-Item -Path $Descriptor.path -Force | Out-Null }
        $v = $Descriptor.value
        switch ([string]$Descriptor.kind) {
            'Binary'      { $v = [byte[]]$Descriptor.value }
            'MultiString' { $v = [string[]]$Descriptor.value }
        }
        New-ItemProperty -Path $Descriptor.path -Name $Descriptor.name -Value $v -PropertyType ([string]$Descriptor.kind) -Force | Out-Null
        return [pscustomobject]@{ action = 'restored value'; detail = "$($Descriptor.path) :: $($Descriptor.name) ($($Descriptor.kind))" }
    }
    if (Test-Path $Descriptor.path) {
        Remove-ItemProperty -Path $Descriptor.path -Name $Descriptor.name -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ action = 'removed value'; detail = "$($Descriptor.path) :: $($Descriptor.name) (never existed before apply)" }
}

function Restore-Nx03WrittenSet {
    <# Reverse-order restore of every value already written by one transaction. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Written)
    $reverse = @($Written)
    [array]::Reverse($reverse)
    $details = @()
    foreach ($w in $reverse) {
        try { $details += (Restore-Nx03RegistryCapture -Descriptor $w.capture).detail } catch { $details += "restore failed for $($w.name): $($_.Exception.Message)" }
    }
    return $details
}

# ---------------------------------------------------------------------------
# C. NX03 per-plan processor engine (own subgroup; NX09's guard is untouched)
# ---------------------------------------------------------------------------

function Set-Nx03ProcessorSetting {
    <# Internal engine behind NX03-001/002/003/004/005/009.

       Pipeline (mirrors NX09's per-plan engine, on NX03's own subgroup):
         capture BOTH planes (fail-closed) -> journal original -> write only the
         requested planes -> re-query verify BOTH -> journal result; on a
         verification failure both planes are restored best-effort and the
         failure is journaled with safe-stop semantics.

       Skips (no mutation) when the plan carries no override for the setting:
       powercfg cannot restore "no override", so an exact-rollback promise would
       be a lie (see OVERRIDE-ABSENCE POLICY in the module header). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TweakId,
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$SettingKey,
        [Parameter(Mandatory)][AllowNull()][int]$AcIndex,
        [Parameter(Mandatory)][AllowNull()][int]$DcIndex,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    Assert-Nx03Prerequisites -ForPowerConfig
    Assert-NxJournalReady -JournalRoot $JournalRoot

    $d = Get-Nx03SettingDescriptor -SettingKey $SettingKey
    if ($null -eq $AcIndex -and $null -eq $DcIndex) {
        throw "tweak ${TweakId}: at least one of -AcIndex/-DcIndex must be non-null"
    }
    foreach ($pair in @(@{ name = 'AcIndex'; value = $AcIndex }, @{ name = 'DcIndex'; value = $DcIndex })) {
        if (-not (Test-Nx03ValueInRange -Descriptor $d -Value $pair.value)) {
            throw "tweak ${TweakId}: $($pair.name) $($pair.value) is outside the documented range $($d.min)..$($d.max) $($d.unit) for '$($d.friendlyName)'"
        }
    }

    $list = Get-NxPowerSchemeList
    if (-not $list.parseOk) {
        return [pscustomobject]@{ tweakId = $TweakId; settingKey = $d.key; outcome = 'Refused'; reason = 'powercfg /list output unparseable (locale/format) - no capture, no mutation'; steps = $steps.ToArray() }
    }
    $resolvedGuid = $SchemeGuid
    if ($SchemeGuid -eq 'SCHEME_CURRENT') { $resolvedGuid = $list.activeGuid }
    $schemeEntry = @($list.schemes | Where-Object { $_.guid -eq $resolvedGuid })
    if ($schemeEntry.Count -eq 0) {
        return [pscustomobject]@{ tweakId = $TweakId; settingKey = $d.key; outcome = 'Skipped'; reason = "plan '$resolvedGuid' is not present in powercfg /list - nothing configured"; steps = $steps.ToArray() }
    }
    $schemeName = $schemeEntry[0].name

    # Read-only capture of BOTH planes BEFORE any change.
    $cap = Get-NxPowerSettingValue -SchemeGuid $resolvedGuid -SubgroupGuid $script:Nx03SubgroupProcessor -SettingGuid $d.guid
    if (-not $cap.parseOk) {
        return [pscustomobject]@{
            tweakId = $TweakId; settingKey = $d.key; outcome = 'Refused'
            reason = "powercfg /query output unparseable (locale/format) for '$($d.friendlyName)' ($($d.guid)) - no capture, no mutation; unknown lines: $(@($cap.unknownLines) -join ' | ')"
            steps = $steps.ToArray()
        }
    }
    if (-not $cap.found) {
        return [pscustomobject]@{
            tweakId = $TweakId; settingKey = $d.key; outcome = 'Skipped'
            reason = "plan '$schemeName' carries no plan-level override for '$($d.friendlyName)' ($($d.guid)); the value is inherited from the processor power-profile defaults and powercfg exposes no documented way to remove an override, so NEXTRIX cannot journal an absence it could restore byte-exactly - nothing was changed. To make it manageable: run the documented unhide command, set the value once in the Windows power-plan UI (that creates the override), then re-run."
            hiddenSettingGuidance = (Get-Nx03HiddenSettingGuidance -SettingKey $d.key)
            steps = $steps.ToArray()
        }
    }
    $steps.Add([pscustomobject]@{ step = 2; name = 'capture-original'; outcome = 'Captured'; detail = "plan=$resolvedGuid setting=$($d.guid) AC=$($cap.acIndex) DC=$($cap.dcIndex) (planes captured separately)" })

    $original = [pscustomobject]@{
        targetType = 'powerSetting'
        schemeGuid = $resolvedGuid; schemeName = $schemeName
        subgroupGuid = $script:Nx03SubgroupProcessor; subgroupName = $cap.subgroupName
        settingGuid = $d.guid; settingName = $d.friendlyName; settingAlias = $d.alias
        acIndex = $cap.acIndex; dcIndex = $cap.dcIndex     # BOTH planes journaled
    }
    $acTouched = ($null -ne $AcIndex -and [int64]$AcIndex -ne [int64]$cap.acIndex)
    $dcTouched = ($null -ne $DcIndex -and [int64]$DcIndex -ne [int64]$cap.dcIndex)
    $newAc = $(if ($null -ne $AcIndex) { [int64]$AcIndex } else { [int64]$cap.acIndex })
    $newDc = $(if ($null -ne $DcIndex) { [int64]$DcIndex } else { [int64]$cap.dcIndex })
    $modified = [pscustomobject]@{
        targetType = 'powerSetting'; schemeGuid = $resolvedGuid
        subgroupGuid = $script:Nx03SubgroupProcessor; settingGuid = $d.guid
        acIndex = $newAc; dcIndex = $newDc; acTouched = $acTouched; dcTouched = $dcTouched
    }
    if (-not $acTouched -and -not $dcTouched) {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; settingKey = $d.key; outcome = 'AlreadyAtState'; reason = "AC=$($cap.acIndex) DC=$($cap.dcIndex) already at the requested value(s)"; steps = $steps.ToArray() }
    }

    # Journal-first, then mutate, then verify, then journal the result.
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        if ($acTouched) { Invoke-NxPowerCfg -PowerCfgArgs @('/setacvalueindex', $resolvedGuid, $script:Nx03SubgroupProcessor, $d.guid, [string]$AcIndex) -RequireSuccess | Out-Null }
        if ($dcTouched) { Invoke-NxPowerCfg -PowerCfgArgs @('/setdcvalueindex', $resolvedGuid, $script:Nx03SubgroupProcessor, $d.guid, [string]$DcIndex) -RequireSuccess | Out-Null }
        $check = Get-NxPowerSettingValue -SchemeGuid $resolvedGuid -SubgroupGuid $script:Nx03SubgroupProcessor -SettingGuid $d.guid
        $verified = ($check.parseOk -and $check.found -and [int64]$check.acIndex -eq $newAc -and [int64]$check.dcIndex -eq $newDc)
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            # Safe stop + best-effort restore of BOTH planes to the captured original.
            try {
                Invoke-NxPowerCfg -PowerCfgArgs @('/setacvalueindex', $resolvedGuid, $script:Nx03SubgroupProcessor, $d.guid, [string]$original.acIndex) | Out-Null
                Invoke-NxPowerCfg -PowerCfgArgs @('/setdcvalueindex', $resolvedGuid, $script:Nx03SubgroupProcessor, $d.guid, [string]$original.dcIndex) | Out-Null
            } catch { }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo "post-apply re-query mismatch (AC=$($check.acIndex) DC=$($check.dcIndex), expected AC=$newAc DC=$newDc)" -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $TweakId; settingKey = $d.key; outcome = 'Failed'; reason = 'post-apply re-query mismatch; both planes restored best-effort'; steps = $steps.ToArray() }
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; settingKey = $d.key; outcome = 'Failed'; reason = [string]$_.Exception.Message; steps = $steps.ToArray() }
    }
    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = "AC=$($check.acIndex) DC=$($check.dcIndex) ($($d.alias))" })
    return [pscustomobject]@{
        tweakId = $TweakId; settingKey = $d.key; outcome = 'Applied'
        original = $original; modified = $modified; journalSeq = $jr.seq
        hiddenSettingGuidance = (Get-Nx03HiddenSettingGuidance -SettingKey $d.key)
        steps = $steps.ToArray()
    }
}

# ---------------------------------------------------------------------------
# D. NX03 registry transaction engine (multi-value, all-or-nothing)
# ---------------------------------------------------------------------------

function Set-Nx03RegistryValueSet {
    <# Internal engine behind NX03-006/007/008.

       Transaction semantics: every requested value is captured FIRST, the whole
       set is validated before the first write, each write is journaled
       (apply/verify), and any failure restores every value already written - in
       reverse order - to its exact captured original before the failure is
       journaled. There is no "some of the set applied" end state.

       Registry targets are journaled with targetType='registry', so the shared
       rollback engine (NxRollback.ps1) restores them with its only-if-ours
       exact-original logic; NX03's own Invoke-Nx03Rollback handles only the
       powerSetting targets NX03 owns. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TweakId,
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)]$Values,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    Assert-Nx03Prerequisites -ForRegistryWrite
    Assert-NxJournalReady -JournalRoot $JournalRoot

    $allowedKinds = @('DWord', 'QWord', 'String', 'ExpandString')
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($v in @($Values)) {
        if ($null -eq $v -or -not $v.path -or -not $v.name) {
            throw "tweak ${TweakId}: every value needs path + name (+ kind + value); got: $(ConvertTo-Json $v -Depth 3 -Compress)"
        }
        $kind = [string]$v.kind
        if ($allowedKinds -notcontains $kind) {
            throw "tweak ${TweakId}: kind '$kind' is not supported by the NX03 engine (allowed: $($allowedKinds -join ', ')); Binary/MultiString entries must ship as dedicated functions (no lossless command-line encoding)"
        }
        $value = $v.value
        switch ($kind) {
            'DWord' { $value = [int][int64]$v.value }
            'QWord' { $value = [int64]$v.value }
            default { $value = [string]$v.value }
        }
        $plan.Add([pscustomobject]@{
            path  = [string]$v.path
            name  = [string]$v.name
            kind  = $kind
            value = $value
            role  = $(if ($v.role) { [string]$v.role } else { $null })
        })
    }
    if ($plan.Count -eq 0) { throw "tweak ${TweakId}: no values supplied - nothing to configure" }

    foreach ($p in $plan) {
        $p | Add-Member -NotePropertyName capture -NotePropertyValue (Capture-NxRegistryValue -Path $p.path -Name $p.name) -Force
    }
    $steps.Add([pscustomobject]@{
        step = 2; name = 'capture-original'; outcome = 'Captured'
        detail = (($plan | ForEach-Object { "$($_.name) existed=$($_.capture.existed) kind=$($_.capture.kind) value=$($_.capture.value)" }) -join '; ')
    })

    $toWrite = @($plan | Where-Object {
        -not ($_.capture.existed -and ([string]$_.capture.kind -eq $_.kind) -and ((ConvertTo-Nx03Comparable $_.capture.value) -eq (ConvertTo-Nx03Comparable $_.value)))
    })
    $modifiedAll = @($plan | ForEach-Object { [pscustomobject]@{ targetType = 'registry'; path = $_.path; name = $_.name; kind = $_.kind; value = $_.value; role = $_.role } })
    if ($toWrite.Count -eq 0) {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $plan[0].capture -Modified $modifiedAll[0] -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'AlreadyAtState'; reason = 'every requested value already holds the requested data'; values = $modifiedAll; steps = $steps.ToArray() }
    }

    $written = New-Object System.Collections.Generic.List[object]
    foreach ($p in $toWrite) {
        $modified = [pscustomobject]@{ targetType = 'registry'; path = $p.path; name = $p.name; kind = $p.kind; value = $p.value; role = $p.role }
        $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $p.capture -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
        $err = $null
        $check = $null
        try {
            Set-NxRegistryValue -Path $p.path -Name $p.name -Kind $p.kind -Value $p.value
            $check = Test-NxConfigurationState -Path $p.path -Name $p.name -Kind $p.kind -ExpectedValue $p.value
        } catch {
            $err = [string]$_.Exception.Message
        }
        if ($err) {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $p.capture -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles | Out-Null
            # The failing write may itself have partially landed: restore it too.
            $restored = @()
            try { $restored += (Restore-Nx03RegistryCapture -Descriptor $p.capture).detail } catch { $restored += "restore failed for $($p.name): $($_.Exception.Message)" }
            $restored += @(Restore-Nx03WrittenSet -Written $written)
            return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = "write failed at '$($p.name)': $err - the whole value set was restored to its exact originals"; restored = $restored; values = $modifiedAll; steps = $steps.ToArray() }
        }
        if (-not $check.verified) {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $p.capture -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles | Out-Null
            $restored = @()
            try { $restored += (Restore-Nx03RegistryCapture -Descriptor $p.capture).detail } catch { $restored += "restore failed for $($p.name): $($_.Exception.Message)" }
            $restored += @(Restore-Nx03WrittenSet -Written $written)
            return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = "$($check.reason) at '$($p.name)' - the whole value set was restored to its exact originals"; restored = $restored; values = $modifiedAll; steps = $steps.ToArray() }
        }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $p.capture -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles $Profiles | Out-Null
        $written.Add([pscustomobject]@{ capture = $p.capture; name = $p.name; seq = $jr.seq })
        $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = "$($p.path) :: $($p.name) = $($p.kind):$($p.value)" })
    }
    return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Applied'; values = $modifiedAll; journalSeq = @($written | ForEach-Object { $_.seq }); steps = $steps.ToArray() }
}

# ---------------------------------------------------------------------------
# E. NX03-001 .. NX03-005, NX03-009 - processor-subgroup settings
# ---------------------------------------------------------------------------

function Set-NxProcessorMinState {
    <# NX03-001 - Minimum processor state (PROCTHROTTLEMIN), 0..100 %, per plane.
       On battery a high minimum keeps the CPU out of low-power states and drains
       the battery faster - stated as a preference, never as a performance claim. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateRange(0, 100)][AllowNull()][int]$AcPercent,
        [Parameter(Mandatory)][ValidateRange(0, 100)][AllowNull()][int]$DcPercent,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    return Set-Nx03ProcessorSetting -TweakId 'NX03-001' -JournalRoot $JournalRoot -SettingKey 'MinState' `
        -AcIndex $AcPercent -DcIndex $DcPercent -SchemeGuid $SchemeGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approval $Approval -Approved:$Approved
}

function Set-NxProcessorMaxState {
    <# NX03-002 - Maximum processor state (PROCTHROTTLEMAX), 0..100 %, per plane.
       Documented interplay: boost mode (NX03-003) decides how far above nominal
       the processor may go; a maximum state below 100 caps the whole operating
       range and is the vendor-independent way to bound it. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateRange(0, 100)][AllowNull()][int]$AcPercent,
        [Parameter(Mandatory)][ValidateRange(0, 100)][AllowNull()][int]$DcPercent,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    return Set-Nx03ProcessorSetting -TweakId 'NX03-002' -JournalRoot $JournalRoot -SettingKey 'MaxState' `
        -AcIndex $AcPercent -DcIndex $DcPercent -SchemeGuid $SchemeGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approval $Approval -Approved:$Approved
}

function Set-NxProcessorBoostMode {
    <# NX03-003 - Processor performance boost mode (PERFBOOSTMODE).
       0 Disabled / 1 Enabled / 2 Aggressive (CPPC/PEP) / 3-4 same as 1-2.
       Documented vendor variance: index meanings depend on the platform type
       (ACPI P-State vs CPPC/PEP vs autonomous CPPC) and Microsoft's own page
       tells tuners to consult the silicon vendor. 3/4 exist for compatibility
       with older definitions and are reported as such. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateRange(0, 4)][AllowNull()][int]$AcMode,
        [Parameter(Mandatory)][ValidateRange(0, 4)][AllowNull()][int]$DcMode,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    return Set-Nx03ProcessorSetting -TweakId 'NX03-003' -JournalRoot $JournalRoot -SettingKey 'BoostMode' `
        -AcIndex $AcMode -DcIndex $DcMode -SchemeGuid $SchemeGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approval $Approval -Approved:$Approved
}

function Set-NxProcessorEnergyPreference {
    <# NX03-004 - Processor energy performance preference policy (PERFEPP),
       0..100 %. Documented: only takes effect where the platform implements
       CPPC v2 with autonomous mode enabled; 0 programs the EPP register toward
       performance, 100 toward energy savings, intermediate values scale as
       (setting*255)/100. AMD and Intel implement CPPC differently, so behaviour
       is platform-specific - the function reports captured values and never
       claims an effect. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateRange(0, 100)][AllowNull()][int]$AcEpp,
        [Parameter(Mandatory)][ValidateRange(0, 100)][AllowNull()][int]$DcEpp,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    return Set-Nx03ProcessorSetting -TweakId 'NX03-004' -JournalRoot $JournalRoot -SettingKey 'Epp' `
        -AcIndex $AcEpp -DcIndex $DcEpp -SchemeGuid $SchemeGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approval $Approval -Approved:$Approved
}

function Set-NxCoreParkingPolicy {
    <# NX03-005 - Core parking min/max cores (CPMINCORES / CPMAXCORES), 0..100 %
       of logical processors per NUMA node. Documented: 100 % minimum disables the
       parking algorithm; both settings are hidden by default and
       hardware-dependent. Each setting is journaled separately with its own AC/DC
       planes, and a failure stops the second write (no half-configured pair).

       -UnhideSettings does NOT write: it returns the documented powercfg
       -attributes guidance (Get-Nx03HiddenSettingGuidance). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [AllowNull()][ValidateRange(0, 100)][Nullable[int]]$AcMinCores,
        [AllowNull()][ValidateRange(0, 100)][Nullable[int]]$DcMinCores,
        [AllowNull()][ValidateRange(0, 100)][Nullable[int]]$AcMaxCores,
        [AllowNull()][ValidateRange(0, 100)][Nullable[int]]$DcMaxCores,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved,
        [switch]$UnhideSettings
    )
    if ($null -eq $AcMinCores -and $null -eq $DcMinCores -and $null -eq $AcMaxCores -and $null -eq $DcMaxCores) {
        throw "tweak NX03-005: supply at least one of -AcMinCores/-DcMinCores/-AcMaxCores/-DcMaxCores"
    }
    $minAc = $null; $minDc = $null; $maxAc = $null; $maxDc = $null
    if ($null -ne $AcMinCores) { $minAc = [int]$AcMinCores }
    if ($null -ne $DcMinCores) { $minDc = [int]$DcMinCores }
    if ($null -ne $AcMaxCores) { $maxAc = [int]$AcMaxCores }
    if ($null -ne $DcMaxCores) { $maxDc = [int]$DcMaxCores }
    if ($null -ne $minAc -and $null -ne $maxAc -and $minAc -gt $maxAc) { throw "tweak NX03-005: AC minimum core percentage ($minAc) exceeds AC maximum ($maxAc)" }
    if ($null -ne $minDc -and $null -ne $maxDc -and $minDc -gt $maxDc) { throw "tweak NX03-005: DC minimum core percentage ($minDc) exceeds DC maximum ($maxDc)" }
    if (-not $Approved) { throw "tweak NX03-005: real application requires -Approved (nothing applies without explicit approval evidence)" }

    $results = New-Object System.Collections.Generic.List[object]
    if ($null -ne $minAc -or $null -ne $minDc) {
        $r = Set-Nx03ProcessorSetting -TweakId 'NX03-005' -JournalRoot $JournalRoot -SettingKey 'CpMinCores' `
            -AcIndex $minAc -DcIndex $minDc -SchemeGuid $SchemeGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approval $Approval -Approved
        $results.Add($r)
        if ($r.outcome -eq 'Failed') {
            return [pscustomobject]@{
                tweakId = 'NX03-005'; outcome = 'Failed'
                reason = 'CPMINCORES step failed; the CPMaxCORES step was not attempted (no half-configured pair)'
                results = $results.ToArray()
                unhideGuidance = @((Get-Nx03HiddenSettingGuidance -SettingKey 'CpMinCores'), (Get-Nx03HiddenSettingGuidance -SettingKey 'CpMaxCores'))
            }
        }
    }
    if ($null -ne $maxAc -or $null -ne $maxDc) {
        $r = Set-Nx03ProcessorSetting -TweakId 'NX03-005' -JournalRoot $JournalRoot -SettingKey 'CpMaxCores' `
            -AcIndex $maxAc -DcIndex $maxDc -SchemeGuid $SchemeGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approval $Approval -Approved
        $results.Add($r)
    }
    $outcomes = @($results | ForEach-Object { $_.outcome })
    $overall = 'Applied'
    if ($outcomes -contains 'Failed') { $overall = 'Failed' }
    elseif (-not ($outcomes -contains 'Applied')) {
        if ($outcomes -contains 'Refused') { $overall = 'Refused' }
        elseif ($outcomes -contains 'Skipped') { $overall = 'Skipped' }
        else { $overall = 'AlreadyAtState' }
    }
    $unhide = $null
    if ($UnhideSettings) {
        $unhide = @(
            (Get-Nx03HiddenSettingGuidance -SettingKey 'CpMinCores'),
            (Get-Nx03HiddenSettingGuidance -SettingKey 'CpMaxCores')
        )
    }
    return [pscustomobject]@{
        tweakId = 'NX03-005'; outcome = $overall; results = $results.ToArray()
        unhideGuidance = $unhide
        note = 'Core parking is hardware-dependent: the effective unparked set is decided by the Windows parking engine per NUMA node; these values only set the documented min/max bounds.'
    }
}

function Set-NxProcessorPerformancePolicy {
    <# NX03-009 - Processor performance policy set (threshold / hysteresis / time
       and policy indexes), per plane. Only settings with a Microsoft per-setting
       page are exposed: increase/decrease threshold (0..100 %), increase/decrease
       time (0..100 time-check intervals - NOT microseconds or percentages),
       increase policy (0..3) and decrease policy (0..2).

       Deliberately NOT writable: the processor performance time check interval
       (4d2b0152-7d5c-498b-88e2-34345392a2c5, live-verified GUID). Microsoft
       publishes no unit/range page for it, so exposing it would invite wrong
       magnitudes from folklore. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [AllowNull()][ValidateRange(0, 100)][Nullable[int]]$AcIncreaseThreshold,
        [AllowNull()][ValidateRange(0, 100)][Nullable[int]]$DcIncreaseThreshold,
        [AllowNull()][ValidateRange(0, 100)][Nullable[int]]$AcDecreaseThreshold,
        [AllowNull()][ValidateRange(0, 100)][Nullable[int]]$DcDecreaseThreshold,
        [AllowNull()][ValidateRange(0, 100)][Nullable[int]]$AcIncreaseTime,
        [AllowNull()][ValidateRange(0, 100)][Nullable[int]]$DcIncreaseTime,
        [AllowNull()][ValidateRange(0, 100)][Nullable[int]]$AcDecreaseTime,
        [AllowNull()][ValidateRange(0, 100)][Nullable[int]]$DcDecreaseTime,
        [AllowNull()][ValidateRange(0, 3)][Nullable[int]]$AcIncreasePolicy,
        [AllowNull()][ValidateRange(0, 3)][Nullable[int]]$DcIncreasePolicy,
        [AllowNull()][ValidateRange(0, 2)][Nullable[int]]$AcDecreasePolicy,
        [AllowNull()][ValidateRange(0, 2)][Nullable[int]]$DcDecreasePolicy,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    if (-not $Approved) { throw "tweak NX03-009: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $plan = @(
        @{ key = 'PerfIncreaseThreshold'; ac = $AcIncreaseThreshold; dc = $DcIncreaseThreshold }
        @{ key = 'PerfDecreaseThreshold'; ac = $AcDecreaseThreshold; dc = $DcDecreaseThreshold }
        @{ key = 'PerfIncreaseTime';      ac = $AcIncreaseTime;      dc = $DcIncreaseTime }
        @{ key = 'PerfDecreaseTime';      ac = $AcDecreaseTime;      dc = $DcDecreaseTime }
        @{ key = 'PerfIncreasePolicy';    ac = $AcIncreasePolicy;    dc = $DcIncreasePolicy }
        @{ key = 'PerfDecreasePolicy';    ac = $AcDecreasePolicy;    dc = $DcDecreasePolicy }
    )
    $selected = @($plan | Where-Object { $null -ne $_.ac -or $null -ne $_.dc })
    if ($selected.Count -eq 0) { throw "tweak NX03-009: supply at least one policy value (thresholds, times or policy indexes)" }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($p in $selected) {
        $r = Set-Nx03ProcessorSetting -TweakId 'NX03-009' -JournalRoot $JournalRoot -SettingKey $p.key `
            -AcIndex $p.ac -DcIndex $p.dc -SchemeGuid $SchemeGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approval $Approval -Approved
        $results.Add($r)
        if ($r.outcome -eq 'Failed') {
            return [pscustomobject]@{
                tweakId = 'NX03-009'; outcome = 'Failed'
                reason = "$($p.key) step failed; remaining policy settings were not attempted (every applied step is journaled and restorable)"
                results = $results.ToArray()
            }
        }
    }
    $outcomes = @($results | ForEach-Object { $_.outcome })
    $overall = 'Applied'
    if ($outcomes -contains 'Failed') { $overall = 'Failed' }
    elseif (-not ($outcomes -contains 'Applied')) {
        if ($outcomes -contains 'Refused') { $overall = 'Refused' }
        elseif ($outcomes -contains 'Skipped') { $overall = 'Skipped' }
        else { $overall = 'AlreadyAtState' }
    }
    return [pscustomobject]@{
        tweakId = 'NX03-009'; outcome = $overall; results = $results.ToArray()
        excludedSetting = [pscustomobject]@{
            settingGuid = '4d2b0152-7d5c-498b-88e2-34345392a2c5'
            friendlyName = 'Processor performance time check interval'
            reason = 'no Microsoft documentation of its units/range for this build - not exposed by NEXTRIX (never set an unverified unit)'
        }
    }
}

# ---------------------------------------------------------------------------
# F. NX03-006 - CPU power throttling policy
# ---------------------------------------------------------------------------

function Set-NxPowerThrottlingPolicy {
    <# NX03-006 - CPU power throttling (EcoQoS) policy switch.
       Writes HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling ::
       PowerThrottlingOff as DWord: 1 = power throttling disabled, 0 = Windows
       default behaviour. Microsoft documents the PowerThrottling key and the
       QoS/EcoQoS mechanism it controls (quality-of-service page) - it does not
       document this specific value name, so provenance is stated honestly and
       the trade-off is spelled out: disabling removes the OS's ability to lower
       the QoS class of background work (more consistent background CPU at the
       cost of power/thermal budget). Windows' QoS machinery is also what hybrid
       (P/E) scheduling hints ride on, so on hybrid parts this switch interacts
       with P/E placement decisions the OS would otherwise make. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateSet('Default', 'Disabled')][string]$Mode,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $target = 0
    if ($Mode -eq 'Disabled') { $target = 1 }
    $res = Set-Nx03RegistryValueSet -TweakId 'NX03-006' -JournalRoot $JournalRoot -Values @(
        [pscustomobject]@{
            path = $script:Nx03ThrottlingPath; name = 'PowerThrottlingOff'; kind = 'DWord'; value = $target
            role = "policy switch (mode $Mode)"
        }
    ) -Profiles $Profiles -TweakVersion $TweakVersion -Approval $Approval -Approved:$Approved
    $res | Add-Member -NotePropertyName provenance -NotePropertyValue 'Microsoft documents the PowerThrottling key and the QoS/EcoQoS mechanism (win32/procthread/quality-of-service); the PowerThrottlingOff value name itself is community-established (E0 provenance recorded in registry/NX03.json), so the entry ships as CONDITIONAL and is never preset-applied on battery-first profiles.' -Force
    $res | Add-Member -NotePropertyName hybridInteraction -NotePropertyValue 'On hybrid (P/E) CPUs the OS QoS machinery also carries scheduling hints; disabling power throttling removes that lever machine-wide. NEXTRIX reports this interaction and never couples it to NX03-012 (which is read-only).' -Force
    return $res
}

# ---------------------------------------------------------------------------
# G. NX03-007 - MMCSS configuration
# ---------------------------------------------------------------------------

function Set-NxMmcssConfiguration {
    <# NX03-007 - Multimedia Class Scheduler Service (MMCSS) configuration.
       Documented surface only (win32/procthread/multimedia-class-scheduler-service):
         SystemProfile :: SystemResponsiveness (REG_DWORD) - percentage of CPU
           reserved for low-priority work; values not divisible by 10 round DOWN,
           values below 10 or above 100 are CLAMPED TO 20, and 100 disables MMCSS.
         SystemProfile\Tasks\<task> :: Priority (REG_DWORD 1..8; for a task whose
           Scheduling Category is High this value is always treated as 2) and
           Scheduling Category (REG_SZ High|Medium|Low).
       GPU Priority / SFIO Priority / Clock Rate / Affinity / BackgroundPriority
       are deliberately NOT written: Microsoft documents GPU Priority and SFIO
       Priority as unused, and Clock Rate's guarantee was removed in Windows 7.
       Only EXISTING task keys are modified (no invented tasks).
       Per-task values are opt-in parameters; the default apply action touches
       SystemResponsiveness only. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [AllowNull()][Nullable[int]]$SystemResponsiveness,
        [string]$TaskName,
        [AllowNull()][Nullable[int]]$TaskPriority,
        [string]$SchedulingCategory,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    if ($null -eq $SystemResponsiveness -and [string]::IsNullOrWhiteSpace($TaskName)) {
        throw "tweak NX03-007: supply -SystemResponsiveness and/or -TaskName with -TaskPriority/-SchedulingCategory"
    }
    if ($null -ne $SystemResponsiveness) {
        if ($SystemResponsiveness -lt 10 -or $SystemResponsiveness -gt 100) {
            throw "tweak NX03-007: SystemResponsiveness must be 10..100 - Microsoft documents that values below 10 or above 100 are clamped to 20 and that 100 disables MMCSS"
        }
    }
    $values = New-Object System.Collections.Generic.List[object]
    if ($null -ne $SystemResponsiveness) {
        $values.Add([pscustomobject]@{
            path = $script:Nx03MmcssPath; name = 'SystemResponsiveness'; kind = 'DWord'; value = [int]$SystemResponsiveness
            role = 'percentage of CPU reserved for low-priority work (documented); 100 disables MMCSS'
        })
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskName)) {
        if ($TaskName -match '[\\/]' -or $TaskName -match '[\*\?\[\]]') {
            throw "tweak NX03-007: TaskName '$TaskName' must be a single task key name (no path separators or wildcards)"
        }
        $taskPath = Join-Path $script:Nx03MmcssTasksPath $TaskName
        if (-not (Test-Path -LiteralPath $taskPath)) {
            $existing = @()
            if (Test-Path -LiteralPath $script:Nx03MmcssTasksPath) {
                $existing = @(Get-ChildItem -LiteralPath $script:Nx03MmcssTasksPath -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
            }
            throw "tweak NX03-007: MMCSS task '$TaskName' does not exist on this machine (present: $($existing -join ', ')); NEXTRIX never invents task keys"
        }
        if ($null -eq $TaskPriority -and [string]::IsNullOrWhiteSpace($SchedulingCategory)) {
            throw "tweak NX03-007: -TaskName '$TaskName' needs -TaskPriority (1..8) and/or -SchedulingCategory (High|Medium|Low)"
        }
        if ($null -ne $TaskPriority) {
            if ($TaskPriority -lt 1 -or $TaskPriority -gt 8) { throw "tweak NX03-007: TaskPriority must be 1..8 (documented range)" }
            $values.Add([pscustomobject]@{
                path = $taskPath; name = 'Priority'; kind = 'DWord'; value = [int]$TaskPriority
                role = "task '$TaskName' priority (documented 1..8; a High-category task is always treated as 2)"
            })
        }
        if (-not [string]::IsNullOrWhiteSpace($SchedulingCategory)) {
            $allowed = @('High', 'Medium', 'Low')
            $cat = $SchedulingCategory.Trim()
            $match = @($allowed | Where-Object { $_ -eq $cat })
            if ($match.Count -eq 0) { throw "tweak NX03-007: SchedulingCategory must be High, Medium or Low (documented values); got '$SchedulingCategory'" }
            $values.Add([pscustomobject]@{
                path = $taskPath; name = 'Scheduling Category'; kind = 'String'; value = $match[0]
                role = "task '$TaskName' scheduling category (documented High|Medium|Low)"
            })
        }
    }
    $res = Set-Nx03RegistryValueSet -TweakId 'NX03-007' -JournalRoot $JournalRoot -Values $values.ToArray() -Profiles $Profiles -TweakVersion $TweakVersion -Approval $Approval -Approved:$Approved
    if ($null -ne $SystemResponsiveness -and [int]$SystemResponsiveness -eq 100) {
        $res | Add-Member -NotePropertyName capabilityNote -NotePropertyValue 'SystemResponsiveness=100 disables MMCSS entirely (documented: the driver returns STATUS_SERVER_DISABLED).' -Force
    }
    $res | Add-Member -NotePropertyName scopeNote -NotePropertyValue 'Machine-wide scheduler policy. NX17-008 (system responsiveness value) and NX17-010 (multimedia scheduler configuration) are XREF entries that delegate here - no duplicate writes.' -Force
    return $res
}

# ---------------------------------------------------------------------------
# H. NX03-008 - Win32PrioritySeparation (+ read-only report)
# ---------------------------------------------------------------------------

function Set-NxWin32PrioritySeparation {
    <# NX03-008 - Win32PrioritySeparation (foreground/background quantum policy).
       Documented: Microsoft maps Win32_OperatingSystem.ForegroundApplicationBoost
       ("Win32Registry|SYSTEM\CurrentControlSet\Control\PriorityControl|
       Win32PrioritySeparation") to this value and documents the boost levels
       None(0)/Minimum(1)/Maximum(2) implemented as quantum boosts of 6/12/18.
       NOT documented: the six-bit quantum field encoding every community guide
       quotes, and therefore what 36/38/42/0x2A/26 actually mean. Five reference
       projects ship five different values with zero evidence. NEXTRIX therefore
       never picks one: the caller supplies the value explicitly (0..63 for the
       documented bit-field width), the class default 2 is the only value NEXTRIX
       re-asserts, and the returned interpretation labels bit-field decoding as
       undocumented. No performance claim is made in either direction. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateRange(0, 63)][int]$Value,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $res = Set-Nx03RegistryValueSet -TweakId 'NX03-008' -JournalRoot $JournalRoot -Values @(
        [pscustomobject]@{
            path = $script:Nx03PriorityCtrlPath; name = 'Win32PrioritySeparation'; kind = 'DWord'; value = [int]$Value
            role = 'foreground/background quantum policy (documented target; field encoding undocumented)'
        }
    ) -Profiles $Profiles -TweakVersion $TweakVersion -Approval $Approval -Approved:$Approved
    $res | Add-Member -NotePropertyName interpretation -NotePropertyValue ([pscustomobject]@{
        value = [int]$Value
        documentedBoostLevel = $(if ($Value -le 2) { @('None (0)', 'Minimum (1)', 'Maximum (2)')[$Value] } else { 'not covered by the documented boost-level mapping' })
        sixBitFieldModel = [pscustomobject]@{
            bits = 'AA (short vs long quantum) | BB (variable vs fixed) | CC (boost ratio)'
            documented = $false
            note = 'Widely quoted decoding; NOT documented by Microsoft. Presented as an observation of the bit-field shape only - NEXTRIX draws no conclusion from it and recommends no value.'
        }
        referenceDivergence = 'Values observed in the research corpus: 36 (Vain, SynergyOS), 38 (XOS, ReviOS), 42 / 0x2A (SapphireOS), 26-with-picker-UI (SynergyOS SOS folder) - five references, five values, zero evidence (docs/RESEARCH_RECONCILIATION.md).'
        performanceEffect = 'PENDING - not measured by NEXTRIX; no claim is made.'
    }) -Force
    $res | Add-Member -NotePropertyName caution -NotePropertyValue 'Global scheduler knob: it changes foreground/background quantum behaviour machine-wide and cannot be scoped. ReviOS revert.yml (r2) is the standing ledger of global scheduler/service tweaks that broke real software - reason enough to keep this preset-excluded and explicit-consent only.' -Force
    return $res
}

function Get-NxWin32PrioritySeparationReport {
    <# Read-only companion to NX03-008: current value, its exact registry
       descriptor, and the documented vs undocumented reading kept clearly apart.
       Never writes. #>
    [CmdletBinding()]
    param()
    $cap = Capture-NxRegistryValue -Path $script:Nx03PriorityCtrlPath -Name 'Win32PrioritySeparation'
    $uncertainty = @()
    $boostLevel = 'Unknown'
    $field = $null
    if ($cap.existed -and [string]$cap.kind -eq 'DWord') {
        $v = [int]$cap.value
        if ($v -le 2) { $boostLevel = @('None (0)', 'Minimum (1)', 'Maximum (2)')[$v] }
        else { $boostLevel = 'not covered by the documented boost-level mapping (0..2)' }
        $field = [pscustomobject]@{
            value = $v
            aa = ($v -band 0x3)
            bb = (($v -band 0xC) -shr 2)
            cc = (($v -band 0x30) -shr 4)
            documented = $false
            note = 'Bit slices are reported for completeness only; Microsoft does not document this encoding, so NEXTRIX assigns them no meaning and derives no recommendation.'
        }
    } elseif (-not $cap.existed) {
        $uncertainty += 'Win32PrioritySeparation is absent on this machine (the OS then applies its built-in default); NEXTRIX does not fabricate a value.'
    } else {
        $uncertainty += "Win32PrioritySeparation has unexpected kind '$($cap.kind)' (expected DWord) - reported, not interpreted."
    }
    return [pscustomobject]@{
        tweakId = 'NX03-008'; readOnly = $true; noWritesPerformed = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        registryPath = $script:Nx03PriorityCtrlPath
        valueName = 'Win32PrioritySeparation'
        exists = $cap.existed; kind = $cap.kind; value = $cap.value
        documentedBoostLevel = $boostLevel
        bitField = $field
        referenceDivergence = '36 (Vain, SynergyOS) / 38 (XOS, ReviOS) / 42 or 0x2A (SapphireOS) / 26 (SynergyOS SOS folder) - five references, zero evidence.'
        sources = @(
            'https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem (ForegroundApplicationBoost MappingStrings -> PriorityControl\Win32PrioritySeparation; boost levels None/Minimum/Maximum and quantum boosts of 6/12/18)'
            'docs/RESEARCH_RECONCILIATION.md (catalogue change queue item 4: values stay ADVANCED/preset-excluded)'
        )
        uncertainty = @($uncertainty)
    }
}

# ---------------------------------------------------------------------------
# I. Read-only reports: NX03-013 inventory, NX03-010 SMT, NX03-011 AMD CPPC,
#    NX03-012 Intel hybrid. No firmware writes anywhere (directive NX10-family
#    rule applies to this family too).
# ---------------------------------------------------------------------------

function Get-NxCpuInventoryReport {
    <# NX03-013 - Read-only CPU inventory & frequency report.

       Extends (never replaces) NxHardware's Get-NxCpuReport: when that helper is
       loaded its vendor/name/core-count classification is reused so the two
       reports cannot disagree. Frequency values are the firmware-reported CIM
       fields - explicitly NOT measurements (no sampling, no claims). The report
       also snapshots which processor power settings the ACTIVE plan actually
       overrides, which is the precondition every NX03-001..009 mutation checks. #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $sockets = @()
    $vendor = 'Uncertain'
    $base = $null
    if (Get-Command -Name Get-NxCpuReport -CommandType Function -ErrorAction SilentlyContinue) {
        try { $base = Get-NxCpuReport } catch { $uncertainty.Add("Get-NxCpuReport failed: $($_.Exception.Message)") }
    }
    try {
        $cpus = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        foreach ($p in $cpus) {
            $sockets += [pscustomobject]@{
                deviceId                  = [string]$p.DeviceID
                name                      = ([string]$p.Name).Trim()
                manufacturer              = ([string]$p.Manufacturer).Trim()
                description               = ([string]$p.Description).Trim()
                socketDesignation         = [string]$p.SocketDesignation
                addressWidthBits          = [string]$p.AddressWidth
                numberOfCores             = $p.NumberOfCores
                numberOfLogicalProcessors = $p.NumberOfLogicalProcessors
                maxClockSpeedMhz          = $p.MaxClockSpeed
                currentClockSpeedMhz      = $p.CurrentClockSpeed
                l2CacheKb                 = $p.L2CacheSize
                l3CacheKb                 = $p.L3CacheSize
                virtualizationFirmwareEnabled = $p.VirtualizationFirmwareEnabled
                vmMonitorModeExtensions   = $p.VMMonitorModeExtensions
                secondLevelAddressTranslation = $p.SecondLevelAddressTranslationExtensions
                status                    = [string]$p.Status
            }
        }
    } catch { $uncertainty.Add("Win32_Processor read failed: $($_.Exception.Message)") }

    if ($base) {
        $vendor = [string]$base.vendor
        foreach ($u in @($base.uncertainty)) { $uncertainty.Add("NxHardware: $u") }
    } elseif ($sockets.Count -gt 0) {
        $mfr = ([string]$sockets[0].manufacturer).ToLower()
        if ($mfr -like '*genuineintel*') { $vendor = 'Intel' }
        elseif ($mfr -like '*authenticamd*') { $vendor = 'AMD' }
        else { $uncertainty.Add("unmapped CPU manufacturer '$($sockets[0].manufacturer)'") }
    }

    $physical = 0; $logical = 0
    foreach ($s in $sockets) {
        if ($s.numberOfCores) { $physical += [int]$s.numberOfCores }
        if ($s.numberOfLogicalProcessors) { $logical += [int]$s.numberOfLogicalProcessors }
    }
    $smt = 'Uncertain'
    if ($physical -gt 0 -and $logical -ge $physical) { $smt = ($logical -gt $physical) }

    $hypervisor = $null
    try { $hypervisor = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch { $uncertainty.Add('Win32_ComputerSystem read failed (hypervisor flag unavailable)') }

    # Per-plan override snapshot for every NX03-owned processor setting (read-only).
    $settings = @()
    $settingsAvailable = $false
    if (Get-Command -Name Get-NxPowerSettingValue -CommandType Function -ErrorAction SilentlyContinue) {
        $settingsAvailable = $true
        foreach ($key in (@($script:Nx03Settings.Keys) | Sort-Object)) {
            $d = $script:Nx03Settings[$key]
            $cap = Get-NxPowerSettingValue -SchemeGuid 'SCHEME_CURRENT' -SubgroupGuid $script:Nx03SubgroupProcessor -SettingGuid $d.guid
            if (-not $cap.parseOk) { $uncertainty.Add("processor setting '$($d.alias)' query unparseable - override state unknown") }
            $settings += [pscustomobject]@{
                settingKey      = $d.key
                alias           = $d.alias
                friendlyName    = $d.friendlyName
                guid            = $d.guid
                hiddenSetting   = $d.hidden
                range           = "$($d.min)..$($d.max) $($d.unit)"
                overridePresent = [bool]$cap.found
                acIndex         = $cap.acIndex
                dcIndex         = $cap.dcIndex
                documentation   = $d.documentation
            }
        }
    } else {
        $uncertainty.Add('Get-NxPowerSettingValue (NX09.ps1) is not loaded - per-plan processor setting overrides were not read')
    }

    return [pscustomobject]@{
        tweakId = 'NX03-013'; readOnly = $true; noWritesPerformed = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        readSucceeded = ($sockets.Count -gt 0)
        vendor = $vendor
        sockets = $sockets
        totals = [pscustomobject]@{
            physicalCores = $(if ($physical -gt 0) { $physical } else { $null })
            logicalProcessors = $(if ($logical -gt 0) { $logical } else { $null })
            smtPresent = $smt
        }
        hypervisorPresent = $hypervisor
        frequencyNote = 'MaxClockSpeed / CurrentClockSpeed are firmware-reported CIM fields (nominal and last reported), not measurements. NEXTRIX takes no sample and makes no frequency claim.'
        processorSettingsAvailable = $settingsAvailable
        processorSettings = $settings
        uncertainty = @($uncertainty)
    }
}

function Get-NxSmtTopologyReport {
    <# NX03-010 - SMT / Hyper-Threading READ-ONLY report + guidance.

       Reality: SMT enablement is a firmware (UEFI/BIOS) setting. Windows has no
       supported OS-level SMT toggle - the OS only reports logical vs physical
       processor counts and schedules on what firmware exposed. NEXTRIX therefore
       never implements a "disable SMT" write; it reports the observed topology,
       marks inference uncertainty (a hypervisor can report arbitrary counts),
       and gives the guided steps. High-blast-radius by nature: disabling SMT
       changes the logical processor count available to every workload, which is
       exactly why this stays a documented, guided decision and not a tweak. #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $perSocket = @()
    $physical = 0; $logical = 0
    try {
        foreach ($p in (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)) {
            $c = 0; $l = 0
            if ($p.NumberOfCores) { $c = [int]$p.NumberOfCores }
            if ($p.NumberOfLogicalProcessors) { $l = [int]$p.NumberOfLogicalProcessors }
            $physical += $c; $logical += $l
            $perSocket += [pscustomobject]@{
                socket = [string]$p.DeviceID; name = ([string]$p.Name).Trim()
                physicalCores = $c; logicalProcessors = $l
                smt = $(if ($c -gt 0 -and $l -ge $c) { ($l -gt $c) } else { 'Uncertain' })
            }
        }
    } catch { $uncertainty.Add("Win32_Processor read failed: $($_.Exception.Message)") }

    $smtState = 'Uncertain'
    if ($physical -gt 0 -and $logical -ge $physical) {
        if ($logical -gt $physical) { $smtState = 'Enabled-AppearsActive' }
        else { $smtState = 'Disabled-AppearsInactiveOrUnsupported' }
    } else { $uncertainty.Add('core/logical counts unavailable - SMT state cannot be inferred') }

    $hypervisor = $null
    try { $hypervisor = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch { }
    if ($hypervisor) { $uncertainty.Add('A hypervisor is present: reported core counts describe what the hypervisor exposes, not necessarily the host firmware SMT configuration.') }

    return [pscustomobject]@{
        tweakId = 'NX03-010'; readOnly = $true; noWritesPerformed = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        smtState = $smtState
        totalPhysicalCores = $(if ($physical -gt 0) { $physical } else { $null })
        totalLogicalProcessors = $(if ($logical -gt 0) { $logical } else { $null })
        perSocket = $perSocket
        hypervisorPresent = $hypervisor
        osLevelToggleAvailable = $false
        osLevelToggleReason = 'Windows exposes no supported OS-level SMT/Hyper-Threading switch; SMT is enabled or disabled in firmware (UEFI/BIOS), and the OS schedules on whatever logical processors firmware reports.'
        guidance = @(
            'Confirm the vendor name of the firmware option first (Intel: Hyper-Threading / Hyper-Threading Technology; AMD: SMT Mode / Simultaneous Multithreading). Wording differs per board vendor.',
            'Change it in firmware, not with a registry or powercfg write; NEXTRIX never performs firmware changes.',
            'Expect a logical-processor count change: re-check NX03-013 and any NX19 topology-based selection afterwards.',
            'High blast radius: virtual machines, anti-cheat, and per-core licensed software can behave differently after the change. This is why the entry is ADVANCED and preset-excluded.'
        )
        uncertainty = @($uncertainty)
    }
}

function Get-NxAmdPreferredCoreReport {
    <# NX03-011 - AMD CPPC preferred cores READ-ONLY report (EXPERIMENTAL/E0).

       CPU-vendor gate lives HERE (NxCompat has no CPU-vendor gate; gating on
       requiredHardware.gpuVendor would gate on the wrong component, so the
       registry entry leaves requiredHardware empty and states this explicitly).

       What is real: AMD platforms using CPPC expose an energy-performance
       preference register, and Windows drives it through the documented
       PerfEnergyPreference / autonomous-mode settings (read here, never written
       by this function). What is NOT real: any documented OS interface to choose
       or pin "preferred cores". The preferred-core ranking is firmware/CPPC
       managed, and the X3D/CCD asymmetry question belongs to the NX19 topology
       engine (L3 asymmetry), which this report does not guess at. #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $vendor = 'Uncertain'
    $cpuName = $null
    try {
        $p = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($p) {
            $cpuName = ([string]$p.Name).Trim()
            $mfr = ([string]$p.Manufacturer).ToLower()
            if ($mfr -like '*authenticamd*') { $vendor = 'AMD' }
            elseif ($mfr -like '*genuineintel*') { $vendor = 'Intel' }
            else { $uncertainty.Add("unmapped CPU manufacturer '$($p.Manufacturer)'") }
        } else { $uncertainty.Add('Win32_Processor returned no instance') }
    } catch { $uncertainty.Add("Win32_Processor read failed: $($_.Exception.Message)") }

    $platformAvailable = ($vendor -eq 'AMD')
    $epp = $null; $autonomous = $null
    if ($platformAvailable -and (Get-Command -Name Get-NxPowerSettingValue -CommandType Function -ErrorAction SilentlyContinue)) {
        $eppCap = Get-NxPowerSettingValue -SchemeGuid 'SCHEME_CURRENT' -SubgroupGuid $script:Nx03SubgroupProcessor -SettingGuid $script:Nx03Settings['Epp'].guid
        if ($eppCap.parseOk) { $epp = [pscustomobject]@{ overridePresent = [bool]$eppCap.found; acIndex = $eppCap.acIndex; dcIndex = $eppCap.dcIndex } }
        else { $uncertainty.Add('PERFEPP query unparseable') }
        $autoCap = Get-NxPowerSettingValue -SchemeGuid 'SCHEME_CURRENT' -SubgroupGuid $script:Nx03SubgroupProcessor -SettingGuid $script:Nx03AutonomousModeGuid
        if ($autoCap.parseOk) { $autonomous = [pscustomobject]@{ overridePresent = [bool]$autoCap.found; acIndex = $autoCap.acIndex; dcIndex = $autoCap.dcIndex } }
        else { $uncertainty.Add('autonomous-mode query unparseable (not present on non-CPPC platforms is also a normal result)') }
    }

    return [pscustomobject]@{
        tweakId = 'NX03-011'; readOnly = $true; noWritesPerformed = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        cpuVendor = $vendor
        cpuName = $cpuName
        platformAvailable = $platformAvailable
        platformReason = $(if ($platformAvailable) { 'AMD CPU detected: CPPC-related OS settings exist and are readable' } else { "AMD platform not detected (vendor=$vendor) - the entry is not applicable to this machine; nothing is written on any platform" })
        preferredCoreControl = 'NotDocumented'
        preferredCoreState = 'Unknown'
        preferredCoreReason = 'No Microsoft- or vendor-documented OS interface exists to select or pin preferred cores; CPPC preferred-core ranking is managed by firmware/the platform. NEXTRIX therefore reports and never writes.'
        cppcSettingsReadOnly = [pscustomobject]@{ energyPerformancePreference = $epp; autonomousMode = $autonomous }
        x3dCcdTopology = 'Uncertain - die/CCD and L3-asymmetry detection belongs to the NX19 topology engine; this report does not guess from marketing names'
        evidenceProvenance = 'E0: community-known CPPC/preferred-core behaviour; no vendor state contract documented (research r1/r3)'
        guidance = @(
            'Preferred-core / CPPC behaviour is firmware and platform managed; keep vendor chipset drivers and firmware current rather than writing scheduler values.',
            'On dual-CCD X3D parts, per-die L3 asymmetry (not a name list) is the reliable signal - that detection is NX19 territory and stays flagged best-effort there.',
            'The only documented OS levers on this platform are the CPPC energy-performance preference and autonomous-mode power settings (reported above read-only); NX03-004 owns EPP configuration when the owner explicitly selects it.'
        )
        uncertainty = @($uncertainty)
    }
}

function Get-NxIntelHybridPolicyReport {
    <# NX03-012 - Intel hybrid P/E power policy READ-ONLY report (EXPERIMENTAL/E0).

       CPU-vendor gate lives HERE (same reasoning as NX03-011). Hybrid detection
       is NOT guessed: EfficiencyClass tiers come from
       GetLogicalProcessorInformationEx(RelationProcessorCore), which the NX19
       topology engine owns. Until that engine lands this report says
       'Uncertain', reads the documented heterogeneous policy settings (values
       only - never written), and states plainly that Microsoft documents this
       settings family for OEM/silicon-vendor tuning, not for end-user policy. #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $vendor = 'Uncertain'; $cpuName = $null; $cores = $null; $logical = $null
    try {
        $p = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($p) {
            $cpuName = ([string]$p.Name).Trim()
            if ($p.NumberOfCores) { $cores = [int]$p.NumberOfCores }
            if ($p.NumberOfLogicalProcessors) { $logical = [int]$p.NumberOfLogicalProcessors }
            $mfr = ([string]$p.Manufacturer).ToLower()
            if ($mfr -like '*genuineintel*') { $vendor = 'Intel' }
            elseif ($mfr -like '*authenticamd*') { $vendor = 'AMD' }
            else { $uncertainty.Add("unmapped CPU manufacturer '$($p.Manufacturer)'") }
        } else { $uncertainty.Add('Win32_Processor returned no instance') }
    } catch { $uncertainty.Add("Win32_Processor read failed: $($_.Exception.Message)") }

    $platformAvailable = ($vendor -eq 'Intel')
    $settings = @()
    if ($platformAvailable -and (Get-Command -Name Get-NxPowerSettingValue -CommandType Function -ErrorAction SilentlyContinue)) {
        foreach ($h in $script:Nx03HeteroSettings) {
            $cap = Get-NxPowerSettingValue -SchemeGuid 'SCHEME_CURRENT' -SubgroupGuid $script:Nx03SubgroupProcessor -SettingGuid $h.guid
            if (-not $cap.parseOk) { $uncertainty.Add("'$($h.friendlyName)' query unparseable") }
            $settings += [pscustomobject]@{
                settingKey = $h.key; friendlyName = $h.friendlyName; guid = $h.guid
                overridePresent = [bool]$cap.found; acIndex = $cap.acIndex; dcIndex = $cap.dcIndex
            }
        }
    }

    return [pscustomobject]@{
        tweakId = 'NX03-012'; readOnly = $true; noWritesPerformed = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        cpuVendor = $vendor
        cpuName = $cpuName
        physicalCores = $cores
        logicalProcessors = $logical
        platformAvailable = $platformAvailable
        platformReason = $(if ($platformAvailable) { 'Intel CPU detected: the heterogeneous policy settings family is readable' } else { "Intel platform not detected (vendor=$vendor) - the entry is not applicable to this machine; nothing is written on any platform" })
        hybridTopology = 'Uncertain-HybridTopologyRequiresNX19Engine'
        hybridTopologyReason = 'P/E classification needs EfficiencyClass tiers from GetLogicalProcessorInformationEx(RelationProcessorCore); that topology engine is owned by NX19. NEXTRIX does not infer hybrid status from processor names (research r1: name lists are the unreliable route).'
        heterogeneousPolicySettingsReadOnly = $settings
        documentedScope = 'Microsoft documents the processor power-management settings family (including the Hetero*/efficiency-class variants) as an OEM/silicon-vendor tuning surface and explicitly directs tuners to the silicon vendor before modifying them; there is no end-user P/E policy contract.'
        guidance = @(
            'No documented OS-level P/E pinning interface is available to NEXTRIX; leave P/E placement to Windows plus current firmware/chipset drivers.',
            'Windows Game Mode (NX02-001) is the documented, OS-supported way to influence processor behaviour during play; it is not a P/E policy and NEXTRIX does not conflate them.',
            'Once the NX19 topology engine lands, this report can consume its verified P/E tiers instead of returning Uncertain.'
        )
        evidenceProvenance = 'E0: undocumented end-user behaviour; settings family documented for OEM tuning only (research r1: E-core dropping heuristics are vendor-described, unverified)'
        uncertainty = @($uncertainty)
    }
}

# ---------------------------------------------------------------------------
# J. NX03 rollback path (per-plane only-if-ours; the registry targets NX03-006/
#    007/008 journal are restored by the shared engine, not here)
# ---------------------------------------------------------------------------

function Get-Nx03RollbackCandidates {
    <# PURE selection logic (testable without any mutation): verified-success
       NX03 powerSetting mutations only. Registry-target entries are excluded on
       purpose - the shared rollback engine restores those. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$JournalEntries)
    return @($JournalEntries | Where-Object {
        $_.tweakId -like 'NX03-*' -and
        $_.operation -eq 'verify' -and $_.result -eq 'Success' -and $_.verification -eq 'Verified' -and
        [string]$_.original.targetType -eq 'powerSetting'
    })
}

function Invoke-Nx03Rollback {
    <# NX03's own rollback replay for its powerSetting target type. Same
       semantics as the shared engine: integrity-gated, reverse order,
       per-plane only-if-ours, per-step journaled and verified.

       Registry-target NX03 entries (006/007/008) are NOT handled here: the
       shared Invoke-NxRollback restores targetType='registry' with its
       exact-original + only-if-ours path. Recording them here would double-restore. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId,
        [switch]$AllNx03
    )
    if (-not $TweakId -and -not $AllNx03) {
        throw "Invoke-Nx03Rollback: specify -TweakId or -AllNx03 (no implicit full-category rollback)"
    }
    Assert-Nx03Prerequisites -ForPowerConfig
    $journal = Read-NxJournal -Path $JournalRoot
    if ($journal.integrityErrors.Count -gt 0) {
        return [pscustomobject]@{ aborted = $true; integrityErrors = $journal.integrityErrors; restored = @(); diverged = @(); failed = @() }
    }
    $candidates = @(Get-Nx03RollbackCandidates -JournalEntries $journal.entries)
    if ($TweakId) { $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId }) }
    [array]::Reverse($candidates)

    $restored = New-Object System.Collections.Generic.List[object]
    $diverged = New-Object System.Collections.Generic.List[object]
    $failed   = New-Object System.Collections.Generic.List[object]

    foreach ($e in $candidates) {
        $orig = $e.original; $mod = $e.modified
        try {
            $live = Get-NxPowerSettingValue -SchemeGuid $orig.schemeGuid -SubgroupGuid $orig.subgroupGuid -SettingGuid $orig.settingGuid
            if (-not $live.found) {
                $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "plan $($orig.schemeGuid) :: $($orig.settingGuid)"; reason = 'plan or setting no longer present (plan may have been deleted) - nothing restored' })
                Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'setting no longer present' -Profiles @($e.profiles) | Out-Null
                continue
            }
            $acOurs = ([int64]$live.acIndex -eq [int64]$mod.acIndex)
            $dcOurs = ([int64]$live.dcIndex -eq [int64]$mod.dcIndex)
            $planeInfo = @()
            if ($acOurs) { Invoke-NxPowerCfg -PowerCfgArgs @('/setacvalueindex', $orig.schemeGuid, $orig.subgroupGuid, $orig.settingGuid, [string]$orig.acIndex) -RequireSuccess | Out-Null; $planeInfo += "AC->$($orig.acIndex)" }
            if ($dcOurs) { Invoke-NxPowerCfg -PowerCfgArgs @('/setdcvalueindex', $orig.schemeGuid, $orig.subgroupGuid, $orig.settingGuid, [string]$orig.dcIndex) -RequireSuccess | Out-Null; $planeInfo += "DC->$($orig.dcIndex)" }
            $after = Get-NxPowerSettingValue -SchemeGuid $orig.schemeGuid -SubgroupGuid $orig.subgroupGuid -SettingGuid $orig.settingGuid
            # Per-plane honesty: a plane still ours must read back as its original; a
            # plane the owner changed after apply stays untouched and is reported.
            $acOk = $false
            if ($acOurs) { $acOk = ($after.found -and [int64]$after.acIndex -eq [int64]$orig.acIndex) }
            else         { $acOk = ($after.found -and [int64]$after.acIndex -eq [int64]$live.acIndex) }
            $dcOk = $false
            if ($dcOurs) { $dcOk = ($after.found -and [int64]$after.dcIndex -eq [int64]$orig.dcIndex) }
            else         { $dcOk = ($after.found -and [int64]$after.dcIndex -eq [int64]$live.dcIndex) }
            $divergence = (-not $acOurs) -or (-not $dcOurs)
            $partial = ''
            if ($divergence) {
                $partial = "only-if-ours: AC ours=$acOurs (live $($live.acIndex) vs recorded modified $($mod.acIndex)), DC ours=$dcOurs (live $($live.dcIndex) vs recorded modified $($mod.dcIndex)); diverged planes left untouched"
                $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "plan $($orig.schemeGuid) :: $($orig.settingGuid)"; reason = $partial })
            }
            $restoreOk = ($acOk -and $dcOk -and $after.found)
            $result = 'Success'; $ver = 'Verified'
            if ($restoreOk -and $divergence) { $result = 'Success-PartialDivergence'; $ver = 'Partial' }
            elseif (-not $restoreOk) { $result = 'FailedVerification'; $ver = 'NotVerified' }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $result -Verification $ver -ErrorInfo $partial -Profiles @($e.profiles) | Out-Null
            $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored plan setting'; detail = "plan $($orig.schemeGuid) :: $($orig.settingGuid) ($($planeInfo -join ', '))"; verified = $restoreOk })
        } catch {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'failed' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles @($e.profiles) | Out-Null
            $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = [string]$_.Exception.Message })
        }
    }
    return [pscustomobject]@{ aborted = $false; restored = $restored.ToArray(); diverged = $diverged.ToArray(); failed = $failed.ToArray(); integrityErrors = @() }
}
