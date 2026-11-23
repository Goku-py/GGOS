#Requires -Version 5.1
<#
    NX09.ps1 - NEXTRIX Power Management functions (category NX09, entries NX09-001..015).

    MUTATION SURFACE (declared per SECURITY_POLICY.md Section 4):
      On TARGET machines only (never on the engineering machine - directive
      Section 16; tools/selftests/Test-NX09.ps1 proves the parse/journal
      plumbing without any powercfg mutation):
        - powercfg plan operations: /setactive, /duplicatescheme, /changename,
          /setacvalueindex, /setdcvalueindex, /delete (ONLY plans the journal
          proves NEXTRIX created - never stock schemes, never the active plan),
          /h on|off, /export, /import, /energy, /batteryreport, /lastwake,
          /devicequery, /a, /list, /query, /getactivescheme (last five are
          read-only).
        - One registry value: HKLM\SYSTEM\CurrentControlSet\Control\Session
          Manager\Power :: HiberbootEnabled (NX09-009, Fast Startup).
        - Report/backup files under user-chosen output paths only.
      Nothing else. `powercfg /restoredefaultschemes` is FORBIDDEN in NEXTRIX:
      it destroys every custom plan on the machine (Vain's delete-all is the
      rejected inverse; adopt register #14, docs/RESEARCH_RECONCILIATION.md).

    PLAN-LIFECYCLE POLICY (adopt register #14 - XOS r1 pattern):
      1. Never delete the active plan - switch away first: to the journaled
         prior-active scheme; if that plan was deleted, to the documented stock
         fallback (Balanced); every fallback is recorded as divergence context.
      2. Delete only plans whose GUID the journal recorded at creation time;
         a hard guard additionally refuses the four stock scheme GUIDs.
      3. Stock schemes stay restorable: Balanced / High performance /
         Power saver / the Ultimate Performance template GUID are never
         mutated or deleted by NEXTRIX.

    AC/DC DISCIPLINE (PROJECT_ARCHITECTURE.md Section 5): every per-plan
    setting capture queries the AC and DC index SEPARATELY via a single
    shared `powercfg /query` parser, journals BOTH planes in the original
    state, mutates only the requested planes, verifies by re-query, and the
    restore path writes both planes back with per-plane only-if-ours
    divergence handling.

    PARSER / LOCALE HONESTY: the parser targets the documented English
    powercfg output format (verified against live 23H2 output). On localized
    Windows the parse fails CLOSED (parseOk=false) and every mutating
    function refuses to act - no verified capture means no mutation.
    NX09-009's registry route (HiberbootEnabled) is locale-independent.

    NX03 BOUNDARY: processor min/max/boost/EPP/parking settings (the whole
    SUB_PROCESSOR subgroup 54533251-82be-4824-96c1-47b60b740d00) are NX03
    territory. New-NxCustomPowerPlan hard-rejects override entries that
    touch that subgroup, and Set-NxPlanSettingValue re-checks the boundary.

    Required core modules: NxJournal.ps1 (journal + registry capture). For
    Set-NxFastStartup additionally NxVerify.ps1 (Test-NxConfigurationState).
    NX09 self-test: tools/selftests/Test-NX09.ps1.

    Idempotency: every mutating function detects AlreadyAtState and journals
    a 'skip' entry instead of re-applying.
#>

# ---------------------------------------------------------------------------
# A. Constants (stock + NEXTRIX GUIDs; all power-setting GUIDs verified
#    against live powercfg /aliases + /query + the PowerSettings store on
#    2026-11-23; the Power saver GUID is the live-verified
#    a1841308-3541-4fab-bc81-f71556f20b4a, NOT the commonly mis-cited variant).
# ---------------------------------------------------------------------------
$script:NxStockSchemeGuids = @{
    '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Balanced'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'High performance'
    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Power saver'
    'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Ultimate Performance'   # hidden template scheme (duplicable, not listed)
}

$script:NxUltimatePerformanceTemplateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$script:NxUltimatePlanGuid = '6e657472-6978-4e58-5452-4958504c414e'   # NEXTRIX Ultimate Performance plan (ASCII mnemonic "nextri-ix-NX-TR-IXPLAN")
$script:NxCustomPlanGuid  = '6e657472-6978-4e58-5452-49584353544d'   # NEXTRIX Custom plan (ASCII mnemonic "...IXCSTM")

$script:NxPowerSettingGuids = @{
    SubgroupPciExpress = '501a4d13-42af-4429-9fd1-a8218c268e20'
    SettingAspm        = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
    SubgroupUsb        = '2a737441-1930-4402-8d77-b2bebba308a3'
    SettingUsbSelectiveSuspend = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    SubgroupVideo      = '7516b95f-f776-4464-8c53-06167f40cc99'
    SettingVideoIdle   = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
    SubgroupSleep      = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    SettingStandbyIdle = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
    SubgroupButtons    = '4f971e89-eebd-4455-a8de-9e59040e7347'
    SettingLidAction   = '5ca83367-6e45-459f-a27b-476b1d01c936'   # live-verified in PowerSettings store ("Lid close action")
    SubgroupProcessor  = '54533251-82be-4824-96c1-47b60b740d00'   # NX03 territory - hard boundary for NX09
}

$script:NxHibernateRegistryPath  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'                    # HibernateEnabled, HiberFileSizePercent
$script:NxFastStartupRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'    # HiberbootEnabled

# ---------------------------------------------------------------------------
# B. powercfg wrapper + read-only parsers
# ---------------------------------------------------------------------------

function Get-NxTruncatedText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [int]$Max = 400)
    if ($Text.Length -le $Max) { return $Text }
    return ($Text.Substring(0, $Max) + '...[truncated]')
}

function Invoke-NxPowerCfg {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$PowerCfgArgs,
        [switch]$RequireSuccess
    )
    # PS 5.1: stderr lines become ErrorRecords that are PROMOTED to terminating
    # errors under $ErrorActionPreference='Stop' - capture under 'Continue'.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = $null; $code = -1
    try {
        $raw = & powercfg.exe @PowerCfgArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -ne $raw) { foreach ($l in @($raw)) { $lines.Add([string]$l) } }
    $res = [pscustomobject]@{
        args     = ($PowerCfgArgs -join ' ')
        exitCode = $code
        output   = ($lines -join "`n")
        ok       = ($code -eq 0)
    }
    if ($RequireSuccess -and -not $res.ok) {
        throw "powercfg $($res.args) failed (exit $($res.exitCode)): $(Get-NxTruncatedText $res.output)"
    }
    return $res
}

function Parse-NxHexIndex {
    # '0x00000064' -> 100 ; '100' -> 100 ; anything else -> $null (parse failure).
    param([Parameter(Mandatory)][string]$Value)
    $v = $Value.Trim()
    if ($v -match '^0x[0-9a-fA-F]+$') { return [Convert]::ToInt64($v.Substring(2), 16) }
    if ($v -match '^\d+$')            { return [Convert]::ToInt64($v, 10) }
    return $null
}

function ConvertFrom-NxPowerCfgQuery {
    <#
        THE shared powercfg /query parser. Parses the documented English output
        format into {setting, AC, DC} triples:

            Power Scheme GUID: <guid>  (Name)
              Subgroup GUID: <guid>  (Name)
                GUID Alias: SUB_X
                Power Setting GUID: <guid>  (Name)
                  GUID Alias: SETX
                  ... possible-settings lines (tolerated, ignored) ...
                Current AC Power Setting Index: 0x00000000
                Current DC Power Setting Index: 0x00000000

        Unknown label = unrecognized locale/format -> parseOk=$false so callers
        fail closed (never mutate what could not be captured).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$QueryOutput,
        [string]$ExpectSettingGuid
    )
    $guidRx   = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $schemeRx = "^\s*Power Scheme GUID:\s*($guidRx)\s*(?:\((.*)\))?"
    $subRx    = "^\s*Subgroup GUID:\s*($guidRx)\s*(?:\((.*)\))?"
    $setRx    = "^\s*Power Setting GUID:\s*($guidRx)\s*(?:\((.*)\))?"
    $aliasRx  = '^\s*GUID Alias:\s*(\S+)\s*$'
    $acRx     = '^\s*Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+|\d+)\s*$'
    $dcRx     = '^\s*Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+|\d+)\s*$'
    $toleratedRx = '^\s*(Minimum Possible Setting:|Maximum Possible Setting:|Possible Settings increment:|Possible Settings units:|Possible Setting Index:|Possible Setting Friendly Name:)'

    $settings = New-Object System.Collections.Generic.List[object]
    $unknown  = New-Object System.Collections.Generic.List[string]
    $parseOk  = $true
    $schemeGuid = $null; $schemeName = $null
    $curSub = $null; $curSet = $null

    foreach ($rawLine in ($QueryOutput -split "`r?`n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match $schemeRx) {
            $schemeGuid = $Matches[1].ToLower()
            $schemeName = $Matches[2]; if (-not $schemeName) { $schemeName = $null }
            $curSub = $null; $curSet = $null
            continue
        }
        if ($line -match $subRx) {
            $nm = $Matches[2]; if (-not $nm) { $nm = $null }
            $curSub = [pscustomobject]@{ guid = $Matches[1].ToLower(); name = $nm; alias = $null }
            $curSet = $null
            continue
        }
        if ($line -match $setRx) {
            $nm = $Matches[2]; if (-not $nm) { $nm = $null }
            $curSet = [pscustomobject]@{
                settingGuid = $Matches[1].ToLower(); settingName = $nm; settingAlias = $null
                acIndex = $null; dcIndex = $null
                subgroupGuid = $null; subgroupName = $null; subgroupAlias = $null
            }
            if ($null -ne $curSub) {
                $curSet.subgroupGuid  = $curSub.guid
                $curSet.subgroupName  = $curSub.name
                $curSet.subgroupAlias = $curSub.alias
            }
            continue
        }
        if ($line -match $aliasRx) {
            if ($null -ne $curSet) { $curSet.settingAlias = $Matches[1] }
            elseif ($null -ne $curSub) { $curSub.alias = $Matches[1] }
            continue
        }
        if ($line -match $acRx) {
            if ($null -eq $curSet) { $parseOk = $false; continue }
            $curSet.acIndex = Parse-NxHexIndex $Matches[1]
            if ($null -eq $curSet.acIndex) { $parseOk = $false }
            continue
        }
        if ($line -match $dcRx) {
            if ($null -eq $curSet -or $null -eq $curSet.acIndex) { $parseOk = $false; continue }
            $curSet.dcIndex = Parse-NxHexIndex $Matches[1]
            if ($null -eq $curSet.dcIndex) { $parseOk = $false; continue }
            $settings.Add($curSet)
            $curSet = $null
            continue
        }
        if ($line -match $toleratedRx) { continue }
        # Unknown label: unrecognized locale/format - fail the whole parse closed.
        $parseOk = $false
        if ($unknown.Count -lt 5) { $unknown.Add($line) }
    }
    if ($null -ne $curSet) { $parseOk = $false }   # dangling setting block without a DC line

    $selected = $settings.ToArray()
    if ($ExpectSettingGuid) { $selected = @($settings | Where-Object { $_.settingGuid -eq $ExpectSettingGuid.ToLower() }) }
    return [pscustomobject]@{
        parseOk      = $parseOk
        unknownLines = $unknown.ToArray()
        schemeGuid   = $schemeGuid
        schemeName   = $schemeName
        settings     = @($selected)
        allSettings  = $settings.ToArray()
    }
}

function Get-NxActivePowerScheme {
    # Read-only. powercfg /getactivescheme -> 'Power Scheme GUID: <guid>  (Name)'
    [CmdletBinding()]
    param()
    $r = Invoke-NxPowerCfg -PowerCfgArgs @('/getactivescheme')
    $guidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $guid = $null; $name = $null; $parseOk = $false
    if ($r.ok -and $r.output -match "Power Scheme GUID:\s*($guidRx)\s*(?:\((.*)\))?") {
        $guid = $Matches[1].ToLower()
        $name = $Matches[2]; if (-not $name) { $name = $null }
        $parseOk = $true
    }
    return [pscustomobject]@{
        parseOk = $parseOk; guid = $guid; name = $name
        exitCode = $r.exitCode; raw = $r
    }
}

function Get-NxPowerSchemeList {
    # Read-only. powercfg /list; the ACTIVE plan carries ' *' after its name.
    [CmdletBinding()]
    param()
    $r = Invoke-NxPowerCfg -PowerCfgArgs @('/list')
    $guidRx   = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $schemeRx = "^Power Scheme GUID:\s*($guidRx)\s*(?:\((.*)\))?\s*(\*)?\s*$"
    $schemes = New-Object System.Collections.Generic.List[object]
    $unknown = New-Object System.Collections.Generic.List[string]
    $parseOk = $true
    foreach ($rawLine in ($r.output -split "`r?`n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^Existing Power Schemes') { continue }
        if ($line -match '^-{3,}$') { continue }
        if ($line -match $schemeRx) {
            $nm = $Matches[2]; if (-not $nm) { $nm = $null }
            $schemes.Add([pscustomobject]@{ guid = $Matches[1].ToLower(); name = $nm; isActive = ($Matches[3] -eq '*') })
            continue
        }
        $parseOk = $false
        if ($unknown.Count -lt 5) { $unknown.Add($line) }
    }
    $active = @($schemes | Where-Object { $_.isActive })
    return [pscustomobject]@{
        parseOk = $parseOk; commandOk = $r.ok; exitCode = $r.exitCode
        schemes = $schemes.ToArray()
        activeGuid = $(if ($active.Count -gt 0) { $active[0].guid } else { $null })
        unknownLines = $unknown.ToArray(); raw = $r
    }
}

function Get-NxPowerSettingValue {
    # Read-only capture of ONE setting's CURRENT AC and DC indexes (separate planes).
    [CmdletBinding()]
    param(
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [Parameter(Mandatory)][string]$SubgroupGuid,
        [Parameter(Mandatory)][string]$SettingGuid
    )
    $r = Invoke-NxPowerCfg -PowerCfgArgs @('/query', $SchemeGuid, $SubgroupGuid, $SettingGuid)
    $p = ConvertFrom-NxPowerCfgQuery -QueryOutput $r.output -ExpectSettingGuid $SettingGuid
    $found = ($r.ok -and $p.parseOk -and $p.settings.Count -gt 0)
    $s = $null
    if ($found) { $s = $p.settings[0] }
    return [pscustomobject]@{
        found    = $found
        parseOk  = $p.parseOk
        commandOk = $r.ok
        exitCode = $r.exitCode
        schemeGuid = $p.schemeGuid; schemeName = $p.schemeName
        subgroupGuid = $(if ($found) { $s.subgroupGuid } else { $null })
        subgroupName = $(if ($found) { $s.subgroupName } else { $null })
        settingGuid  = $(if ($found) { $s.settingGuid } else { $null })
        settingName  = $(if ($found) { $s.settingName } else { $null })
        acIndex = $(if ($found) { $s.acIndex } else { $null })
        dcIndex = $(if ($found) { $s.dcIndex } else { $null })
        unknownLines = @($p.unknownLines)
        raw = $r
    }
}

function ConvertFrom-NxSleepStateText {
    # Text-level parser for powercfg /a output (English). Testable without
    # powercfg; values: Available/Unavailable/Unknown (Unknown = not listed or
    # no section header seen). INFORMATIONAL context only - the authoritative
    # journal anchor for NX09-008 is the HibernateEnabled registry value.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $section = $null
    $s0 = 'Unknown'; $s3 = 'Unknown'; $s4 = 'Unknown'; $fastStartup = 'Unknown'; $hybrid = 'Unknown'
    $sawHeader = $false
    foreach ($rawLine in ($Text -split "`r?`n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^The following sleep states are available on this system:') { $section = 'Available'; $sawHeader = $true; continue }
        if ($line -match '^The following sleep states are not available on this system:') { $section = 'Unavailable'; $sawHeader = $true; continue }
        # Real output: 'Standby (S0 Low Power Idle) Network Connected' - suffix tolerated.
        if ($line -match '^\s*Standby \(S0 Low Power Idle\)(\s+.*)?$') { $s0 = $section; continue }
        if ($line -match '^\s*Standby \(S3\)\s*$')                { $s3 = $section; continue }
        if ($line -match '^\s*Hibernate\s*$')                     { $s4 = $section; continue }
        if ($line -match '^\s*Fast Startup\s*$')                  { $fastStartup = $section; continue }
        if ($line -match '^\s*Hybrid Sleep\s*$')                   { $hybrid = $section; continue }
        # anything else is a reason/annotation line - retained, not a parse failure
    }
    return [pscustomobject]@{
        parseOk = $sawHeader
        s0LowPowerIdle = $s0; s3 = $s3; s4 = $s4; fastStartup = $fastStartup; hybridSleep = $hybrid
    }
}

function Get-NxSleepStateAvailability {
    # Read-only. powercfg /a -> parsed firmware-level sleep capability context.
    # Informational only (see ConvertFrom-NxSleepStateText).
    [CmdletBinding()]
    param()
    $r = Invoke-NxPowerCfg -PowerCfgArgs @('/a')
    $p = ConvertFrom-NxSleepStateText -Text $r.output
    return [pscustomobject]@{
        parseOk = ($r.ok -or $p.parseOk)
        s0LowPowerIdle = $p.s0LowPowerIdle; s3 = $p.s3; s4 = $p.s4
        fastStartup = $p.fastStartup; hybridSleep = $p.hybridSleep
        exitCode = $r.exitCode; raw = $r
    }
}

function Get-NxWakeSourceReport {
    # Read-only: powercfg /lastwake (raw text) + /devicequery wake_armed (device list).
    [CmdletBinding()]
    param()
    $last  = Invoke-NxPowerCfg -PowerCfgArgs @('/lastwake')
    $armed = Invoke-NxPowerCfg -PowerCfgArgs @('/devicequery', 'wake_armed')
    $devices = @()
    if ($armed.ok) {
        foreach ($l in ($armed.output -split "`r?`n")) { $t = $l.Trim(); if ($t) { $devices += $t } }
    }
    return [pscustomobject]@{
        readOnly = $true
        lastWakeRaw = $last.output
        lastWakeExitCode = $last.exitCode
        wakeArmedDevices = @($devices)
        wakeArmedExitCode = $armed.exitCode
    }
}

# ---------------------------------------------------------------------------
# C. Guards + resolution helpers
# ---------------------------------------------------------------------------

function Test-NxStockSchemeGuid {
    # Hard guard: true when the GUID is one of the four documented stock schemes.
    param([Parameter(Mandatory)][string]$Guid)
    return [bool]$script:NxStockSchemeGuids.ContainsKey($Guid.ToLower())
}

function Test-NxProcessorSubgroupBoundary {
    # NX03 boundary: true when the subgroup GUID is SUB_PROCESSOR (NX03 territory).
    param([Parameter(Mandatory)][string]$SubgroupGuid)
    return ($SubgroupGuid.ToLower() -eq $script:NxPowerSettingGuids.SubgroupProcessor)
}

function Assert-NxJournalReady {
    # No mutation without an initialized, capture-Complete journal (adopt register #2).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JournalRoot)
    $state = Read-NxManifest -Path $JournalRoot
    if (-not $state.present) {
        throw "journal not initialized at '$JournalRoot' - refusing to mutate (journal-first invariant; run Invoke-NxPreFlight / NX16-004 first)"
    }
    if ([string]$state.manifest.captureStatus -ne 'Complete') {
        throw "journal captureStatus is '$($state.manifest.captureStatus)' - destructive steps refuse unless capture is Complete"
    }
}

function Test-NxJournalPresent {
    param([Parameter(Mandatory)][string]$JournalRoot)
    $state = Read-NxManifest -Path $JournalRoot
    return [bool]$state.present
}

function Resolve-NxTargetPlanGuid {
    # Resolves 'Balanced'/'HighPerformance'/'PowerSaver'/'UltimatePerformance'
    # or an explicit GUID against the live scheme list. Refuses plans that do
    # not exist (NEXTRIX never auto-provisions inside selection - provisioning
    # is NX09-002/003 territory).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetPlan,
        [Parameter(Mandatory)]$SchemeList
    )
    $t = $TargetPlan.Trim()
    $guidRx = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $guid = $null; $reason = $null
    switch ($t.ToLower()) {
        'balanced'           { $guid = '381b4222-f694-41f0-9685-ff5bb260df2e' }
        'highperformance'     { $guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
        'powersaver'          { $guid = 'a1841308-3541-4fab-bc81-f71556f20b4a' }
        'ultimateperformance' { $guid = $script:NxUltimatePlanGuid; $reason = 'Ultimate Performance must be provisioned first (NX09-002)' }
        default {
            if ($t -match $guidRx) { $guid = $t.ToLower() }
            else { return [pscustomobject]@{ ok = $false; guid = $null; name = $null; reason = "target plan '$TargetPlan' is not a known stock alias or a GUID" } }
        }
    }
    if ($t.ToLower() -eq 'ultimateperformance') { $reason = $null }   # presence check decides below
    $entry = @($SchemeList.schemes | Where-Object { $_.guid -eq $guid })
    if ($entry.Count -eq 0) {
        $extra = ''
        if ($t.ToLower() -eq 'ultimateperformance') { $extra = ' (NX09-002 provisions the NEXTRIX Ultimate Performance plan)' }
        elseif (@('balanced','highperformance','powersaver') -contains $t.ToLower()) { $extra = ' (hidden stock schemes are never auto-created; use NX09-003 with that template to materialize them)' }
        return [pscustomobject]@{ ok = $false; guid = $guid; name = $null; reason = "plan '$guid' is not present in powercfg /list$extra - nothing activated" }
    }
    return [pscustomobject]@{ ok = $true; guid = $guid; name = $entry[0].name; reason = $null }
}

function Resolve-NxReportOutputPath {
    # User-chosen output folder -> timestamped report path. Creates the folder
    # if missing (additive); refuses to overwrite an existing report file.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$OutputFolder,
        [Parameter(Mandatory)][string]$FileName
    )
    if ([string]::IsNullOrWhiteSpace($OutputFolder)) {
        throw "an output folder must be chosen (reports are never written to implicit system locations)"
    }
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $OutputFolder -PathType Container)) {
        throw "path '$OutputFolder' exists but is not a folder"
    }
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext  = [IO.Path]::GetExtension($FileName)
    if ([string]::IsNullOrEmpty($ext)) { $ext = '.txt' }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $full = Join-Path $OutputFolder ("$base-$stamp$ext")
    if (Test-Path -LiteralPath $full) {
        throw "report file '$full' already exists - refusing to overwrite (timestamped names make this rare)"
    }
    return [pscustomobject]@{ folder = $OutputFolder; filePath = $full }
}

# ---------------------------------------------------------------------------
# D. Mutating functions (10-step pipeline: capture BOTH planes -> journal ->
#    mutate -> verify -> journal; AC/DC journaled separately everywhere).
#    Real application requires -Approved (mirrors Invoke-NxApply).
# ---------------------------------------------------------------------------

function Set-NxActivePowerPlan {
    <# NX09-001 - Active power plan selection. Capture the active scheme GUID,
       journal it, switch, verify by re-read. Rollback (Invoke-Nx09Rollback)
       switches back only-if-ours. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$TargetPlan,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $tweakId = 'NX09-001'
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    Assert-NxJournalReady -JournalRoot $JournalRoot

    $list = Get-NxPowerSchemeList
    $steps.Add([pscustomobject]@{ step = 2; name = 'capture-list'; outcome = $(if ($list.parseOk) { 'Captured' } else { 'Refused' }); detail = "schemes=$($list.schemes.Count) parseOk=$($list.parseOk)" })
    if (-not $list.parseOk) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = 'powercfg /list output unparseable (locale/format) - no capture, no mutation'; steps = $steps.ToArray() }
    }
    $target = Resolve-NxTargetPlanGuid -TargetPlan $TargetPlan -SchemeList $list
    if (-not $target.ok) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = $target.reason; steps = $steps.ToArray() }
    }
    $active = Get-NxActivePowerScheme
    if (-not $active.parseOk) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = 'powercfg /getactivescheme output unparseable - no capture, no mutation'; steps = $steps.ToArray() }
    }
    $original = [pscustomobject]@{ targetType = 'powerPlanSelection'; schemeGuid = $active.guid; schemeName = $active.name }
    $modified = [pscustomobject]@{ targetType = 'powerPlanSelection'; schemeGuid = $target.guid; schemeName = $target.name }
    if ($active.guid -eq $target.guid) {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'AlreadyAtState'; reason = "plan '$($target.name)' is already active"; steps = $steps.ToArray() }
    }
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Invoke-NxPowerCfg -PowerCfgArgs @('/setactive', $target.guid) -RequireSuccess | Out-Null
        $check = Get-NxActivePowerScheme
        $verified = ($check.parseOk -and $check.guid -eq $target.guid)
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            if (@($list.schemes | Where-Object { $_.guid -eq $active.guid }).Count -gt 0) {
                Invoke-NxPowerCfg -PowerCfgArgs @('/setactive', $active.guid) | Out-Null   # best-effort switch-back
            }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo 'active scheme did not verify after /setactive' -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = 'verification failed; best-effort switch-back attempted'; steps = $steps.ToArray() }
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = [string]$_.Exception.Message; steps = $steps.ToArray() }
    }
    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = "active=$($check.guid)" })
    return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Applied'; original = $original; modified = $modified; journalSeq = $jr.seq; steps = $steps.ToArray() }
}

function Set-NxPlanSettingValue {
    <# Internal engine behind NX09-004..007/010 and NX09-003 overrides.
       Per-plan setacvalueindex/setdcvalueindex with BOTH planes captured,
       journaled, verified and restorable separately. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TweakId,
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$SubgroupGuid,
        [Parameter(Mandatory)][string]$SettingGuid,
        [Parameter(Mandatory)][AllowNull()][int]$AcIndex,      # $null = leave the AC plane untouched
        [Parameter(Mandatory)][AllowNull()][int]$DcIndex,      # $null = leave the DC plane untouched
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [switch]$Approved
    )
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    Assert-NxJournalReady -JournalRoot $JournalRoot

    if (Test-NxProcessorSubgroupBoundary -SubgroupGuid $SubgroupGuid) {
        throw "tweak ${TweakId}: subgroup $SubgroupGuid is the processor subgroup - min/max/boost/EPP/parking are NX03 territory (refused)"
    }
    if ($null -eq $AcIndex -and $null -eq $DcIndex) {
        throw "tweak ${TweakId}: at least one of -AcIndex/-DcIndex must be non-null"
    }

    # Resolve the target scheme (default: the currently active one).
    $list = Get-NxPowerSchemeList
    if (-not $list.parseOk) {
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Refused'; reason = 'powercfg /list output unparseable (locale/format) - no capture, no mutation'; steps = $steps.ToArray() }
    }
    $resolvedGuid = $SchemeGuid
    if ($SchemeGuid -eq 'SCHEME_CURRENT') { $resolvedGuid = $list.activeGuid }
    $schemeEntry = @($list.schemes | Where-Object { $_.guid -eq $resolvedGuid })
    if ($schemeEntry.Count -eq 0) {
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Skipped'; reason = "plan '$resolvedGuid' not present in powercfg /list - nothing configured"; steps = $steps.ToArray() }
    }
    $schemeName = $schemeEntry[0].name

    # Capture BOTH planes BEFORE any change (read-only).
    $cap = Get-NxPowerSettingValue -SchemeGuid $resolvedGuid -SubgroupGuid $SubgroupGuid -SettingGuid $SettingGuid
    if (-not $cap.parseOk) {
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Refused'; reason = "powercfg /query output unparseable (locale/format) for setting $SettingGuid - no capture, no mutation; unknown lines: $(@($cap.unknownLines) -join ' | ')"; steps = $steps.ToArray() }
    }
    if (-not $cap.found) {
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Skipped'; reason = "setting $SettingGuid is not present on plan '$schemeName' (e.g. lid settings on desktop plans) - nothing configured"; steps = $steps.ToArray() }
    }
    $steps.Add([pscustomobject]@{ step = 2; name = 'capture-original'; outcome = 'Captured'; detail = "plan=$resolvedGuid sub=$($cap.subgroupGuid) set=$SettingGuid AC=$($cap.acIndex) DC=$($cap.dcIndex) (planes captured separately)" })

    $original = [pscustomobject]@{
        targetType = 'powerSetting'; schemeGuid = $resolvedGuid; schemeName = $schemeName
        subgroupGuid = $cap.subgroupGuid; subgroupName = $cap.subgroupName
        settingGuid = $SettingGuid.ToLower(); settingName = $cap.settingName
        acIndex = $cap.acIndex; dcIndex = $cap.dcIndex     # BOTH planes journaled
    }
    $acTouched = ($null -ne $AcIndex -and [int64]$AcIndex -ne [int64]$cap.acIndex)
    $dcTouched = ($null -ne $DcIndex -and [int64]$DcIndex -ne [int64]$cap.dcIndex)
    $newAc = $(if ($null -ne $AcIndex) { [int64]$AcIndex } else { [int64]$cap.acIndex })
    $newDc = $(if ($null -ne $DcIndex) { [int64]$DcIndex } else { [int64]$cap.dcIndex })
    $modified = [pscustomobject]@{
        targetType = 'powerSetting'; schemeGuid = $resolvedGuid
        subgroupGuid = $cap.subgroupGuid; settingGuid = $SettingGuid.ToLower()
        acIndex = $newAc; dcIndex = $newDc; acTouched = $acTouched; dcTouched = $dcTouched
    }
    if (-not $acTouched -and -not $dcTouched) {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'AlreadyAtState'; reason = "AC=$($cap.acIndex) DC=$($cap.dcIndex) already at requested values"; steps = $steps.ToArray() }
    }

    # Journal-first (step 7), then mutate (step 8), then verify (step 9), then journal result (step 10).
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        if ($acTouched) { Invoke-NxPowerCfg -PowerCfgArgs @('/setacvalueindex', $resolvedGuid, $SubgroupGuid, $SettingGuid, [string]$AcIndex) -RequireSuccess | Out-Null }
        if ($dcTouched) { Invoke-NxPowerCfg -PowerCfgArgs @('/setdcvalueindex', $resolvedGuid, $SubgroupGuid, $SettingGuid, [string]$DcIndex) -RequireSuccess | Out-Null }
        $check = Get-NxPowerSettingValue -SchemeGuid $resolvedGuid -SubgroupGuid $SubgroupGuid -SettingGuid $SettingGuid
        $verified = ($check.parseOk -and $check.found -and [int64]$check.acIndex -eq $newAc -and [int64]$check.dcIndex -eq $newDc)
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            # Safe stop + best-effort restore of BOTH planes to the captured original.
            try {
                Invoke-NxPowerCfg -PowerCfgArgs @('/setacvalueindex', $resolvedGuid, $SubgroupGuid, $SettingGuid, [string]$original.acIndex) | Out-Null
                Invoke-NxPowerCfg -PowerCfgArgs @('/setdcvalueindex', $resolvedGuid, $SubgroupGuid, $SettingGuid, [string]$original.dcIndex) | Out-Null
            } catch { }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo "post-apply re-query mismatch (AC=$($check.acIndex) DC=$($check.dcIndex), expected AC=$newAc DC=$newDc)" -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = 'post-apply re-query mismatch; both planes restored best-effort'; steps = $steps.ToArray() }
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = [string]$_.Exception.Message; steps = $steps.ToArray() }
    }
    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = "AC=$($check.acIndex) DC=$($check.dcIndex)" })
    return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Applied'; original = $original; modified = $modified; journalSeq = $jr.seq; steps = $steps.ToArray() }
}

function Set-NxPcieAspm {
    <# NX09-004 - PCIe ASPM link policy per plan. 0=Off, 1=Moderate, 2=Maximum. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateRange(0,2)][AllowNull()][int]$AcValue,
        [Parameter(Mandatory)][ValidateRange(0,2)][AllowNull()][int]$DcValue,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Approved
    )
    return Set-NxPlanSettingValue -TweakId 'NX09-004' -JournalRoot $JournalRoot `
        -SubgroupGuid $script:NxPowerSettingGuids.SubgroupPciExpress -SettingGuid $script:NxPowerSettingGuids.SettingAspm `
        -AcIndex $AcValue -DcIndex $DcValue -SchemeGuid $SchemeGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approved:$Approved
}

function Set-NxUsbSelectiveSuspend {
    <# NX09-005 - USB selective suspend policy per plan. 0=Disabled, 1=Enabled.
       Plan-level policy only; per-device checkbox values are never blanket-swept
       (the blanket Enum power-value zeroing pattern is on the rejected list). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateRange(0,1)][AllowNull()][int]$AcValue,
        [Parameter(Mandatory)][ValidateRange(0,1)][AllowNull()][int]$DcValue,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Approved
    )
    return Set-NxPlanSettingValue -TweakId 'NX09-005' -JournalRoot $JournalRoot `
        -SubgroupGuid $script:NxPowerSettingGuids.SubgroupUsb -SettingGuid $script:NxPowerSettingGuids.SettingUsbSelectiveSuspend `
        -AcIndex $AcValue -DcIndex $DcValue -SchemeGuid $SchemeGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approved:$Approved
}

function Set-NxDisplayTimeout {
    <# NX09-006 - Display timeout per plan (seconds), AC/DC independent. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateRange(0,2147483647)][AllowNull()][int]$AcSeconds,
        [Parameter(Mandatory)][ValidateRange(0,2147483647)][AllowNull()][int]$DcSeconds,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Approved
    )
    return Set-NxPlanSettingValue -TweakId 'NX09-006' -JournalRoot $JournalRoot `
        -SubgroupGuid $script:NxPowerSettingGuids.SubgroupVideo -SettingGuid $script:NxPowerSettingGuids.SettingVideoIdle `
        -AcIndex $AcSeconds -DcIndex $DcSeconds -SchemeGuid $SchemeGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approved:$Approved
}

function Set-NxSleepTimeout {
    <# NX09-007 - Sleep (standby) timeout per plan (seconds), AC/DC independent.
       The result carries a read-only wake-source report (lastwake + wake_armed). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateRange(0,2147483647)][AllowNull()][int]$AcSeconds,
        [Parameter(Mandatory)][ValidateRange(0,2147483647)][AllowNull()][int]$DcSeconds,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Approved
    )
    $res = Set-NxPlanSettingValue -TweakId 'NX09-007' -JournalRoot $JournalRoot `
        -SubgroupGuid $script:NxPowerSettingGuids.SubgroupSleep -SettingGuid $script:NxPowerSettingGuids.SettingStandbyIdle `
        -AcIndex $AcSeconds -DcIndex $DcSeconds -SchemeGuid $SchemeGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approved:$Approved
    $res | Add-Member -NotePropertyName wakeSourceReport -NotePropertyValue (Get-NxWakeSourceReport) -Force
    return $res
}

function Set-NxLidCloseAction {
    <# NX09-010 - Lid close behavior (laptops). 0=Do nothing, 1=Sleep,
       2=Hibernate, 3=Shut down. AC/DC independent. Skips gracefully on plans
       that lack the lid setting (desktop plans). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateRange(0,3)][AllowNull()][int]$AcValue,
        [Parameter(Mandatory)][ValidateRange(0,3)][AllowNull()][int]$DcValue,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Approved
    )
    return Set-NxPlanSettingValue -TweakId 'NX09-010' -JournalRoot $JournalRoot `
        -SubgroupGuid $script:NxPowerSettingGuids.SubgroupButtons -SettingGuid $script:NxPowerSettingGuids.SettingLidAction `
        -AcIndex $AcValue -DcIndex $DcValue -SchemeGuid $SchemeGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approved:$Approved
}

function Add-NxUltimatePerformancePlan {
    <# NX09-002 - Provision Ultimate Performance by duplicating the documented
       template scheme e9a42b02-d5df-448d-aa00-03f14749eb61 into a NEXTRIX GUID.
       The journal records the CREATED GUID so rollback deletes only OUR plan,
       never stock schemes and never while active (switch away first). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$PlanName = 'NEXTRIX Ultimate Performance',
        [string]$Description = 'NEXTRIX-provisioned duplicate of the documented Ultimate Performance scheme (NX09-002)',
        [string]$DestinationGuid = $script:NxUltimatePlanGuid,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $tweakId = 'NX09-002'
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    Assert-NxJournalReady -JournalRoot $JournalRoot
    if (Test-NxStockSchemeGuid -Guid $DestinationGuid) {
        throw "tweak ${tweakId}: destination GUID '$DestinationGuid' is a stock scheme GUID - NEXTRIX never provisions onto stock GUIDs"
    }

    $list = Get-NxPowerSchemeList
    if (-not $list.parseOk) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = 'powercfg /list output unparseable (locale/format) - no capture, no mutation'; steps = $steps.ToArray() }
    }
    $existing = @($list.schemes | Where-Object { $_.guid -eq $DestinationGuid })
    $original = [pscustomobject]@{
        targetType = 'powerPlanLifecycle'; phase = 'create'
        templateGuid = $script:NxUltimatePerformanceTemplateGuid
        destinationGuid = $DestinationGuid
        priorActiveGuid = $list.activeGuid
        priorActiveName = $(if ($list.activeGuid) { (@($list.schemes | Where-Object { $_.guid -eq $list.activeGuid }))[0].name } else { $null })
    }
    $modified = [pscustomobject]@{ targetType = 'powerPlanLifecycle'; phase = 'create'; schemeGuid = $DestinationGuid; schemeName = $PlanName }
    if ($existing.Count -gt 0) {
        if ($existing[0].name -eq $PlanName) {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyProvisioned' -Verification 'NotRun' -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'AlreadyAtState'; reason = "NEXTRIX Ultimate Performance plan already provisioned as GUID $DestinationGuid"; steps = $steps.ToArray() }
        }
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = "destination GUID '$DestinationGuid' is occupied by a non-NEXTRIX plan ('$($existing[0].name)') - refusing to touch it"; steps = $steps.ToArray() }
    }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    $createdGuid = $null
    try {
        # Preferred form: duplicate INTO the fixed NEXTRIX GUID (XOS r1 pattern).
        $dup = Invoke-NxPowerCfg -PowerCfgArgs @('/duplicatescheme', $script:NxUltimatePerformanceTemplateGuid, $DestinationGuid)
        if ($dup.ok -and $dup.output -match [regex]::Escape($DestinationGuid)) {
            $createdGuid = $DestinationGuid
        } else {
            # Fallback: older builds reject an explicit destination GUID -> let
            # powercfg generate one and journal the ACTUAL created GUID.
            $dup2 = Invoke-NxPowerCfg -PowerCfgArgs @('/duplicatescheme', $script:NxUltimatePerformanceTemplateGuid)
            $guidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
            if ($dup2.ok -and $dup2.output -match "Power Scheme GUID:\s*($guidRx)") { $createdGuid = $Matches[1].ToLower() }
        }
        if (-not $createdGuid) { throw "duplicatescheme produced no parseable scheme GUID (exit $($dup.exitCode)): $(Get-NxTruncatedText $dup.output)" }
        Invoke-NxPowerCfg -PowerCfgArgs @('/changename', $createdGuid, $PlanName, $Description) -RequireSuccess | Out-Null
        # Rebuild the journaled original with the ACTUAL created GUID (fallback-safe
        # creation may have produced a different GUID than the destination asked for).
        $original = [pscustomobject]@{
            targetType = 'powerPlanLifecycle'; phase = 'create'; schemeGuid = $createdGuid
            destinationGuid = $DestinationGuid; templateGuid = $original.templateGuid
            priorActiveGuid = $original.priorActiveGuid; priorActiveName = $original.priorActiveName
        }
        $modified = [pscustomobject]@{ targetType = 'powerPlanLifecycle'; phase = 'create'; schemeGuid = $createdGuid; schemeName = $PlanName }
        $verifyList = Get-NxPowerSchemeList
        $entry = @($verifyList.schemes | Where-Object { $_.guid -eq $createdGuid })
        $verified = ($verifyList.parseOk -and $entry.Count -gt 0 -and $entry[0].name -eq $PlanName)
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            try { if ($createdGuid -ne $verifyList.activeGuid) { Invoke-NxPowerCfg -PowerCfgArgs @('/delete', $createdGuid) | Out-Null } } catch { }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo 'created plan did not verify in /list; best-effort delete attempted' -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = 'provisioned plan did not verify'; steps = $steps.ToArray() }
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = [string]$_.Exception.Message; steps = $steps.ToArray() }
    }
    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = "created plan $createdGuid '$PlanName' (template $($original.templateGuid)); stock schemes untouched" })
    return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Applied'; createdGuid = $createdGuid; planName = $PlanName; original = $original; modified = $modified; journalSeq = $jr.seq; steps = $steps.ToArray() }
}

function New-NxCustomPowerPlan {
    <# NX09-003 - Custom NEXTRIX plan generated from a template duplicate
       (XOS r1 pattern), then user-authored overrides applied with per-override
       capture/journal/verify. Processor-subgroup overrides are hard-rejected
       (NX03 boundary). Rollback restores every override, then deletes the
       created plan - never stock schemes, never while active. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TemplatePlan = 'SCHEME_CURRENT',
        [string]$PlanName = 'NEXTRIX Custom Plan',
        [string]$Description = 'NEXTRIX custom plan (template-derived, journal-linked lifecycle, NX09-003)',
        $Overrides = @(),
        [string]$DestinationGuid = $script:NxCustomPlanGuid,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $tweakId = 'NX09-003'
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    Assert-NxJournalReady -JournalRoot $JournalRoot
    if (Test-NxStockSchemeGuid -Guid $DestinationGuid) {
        throw "tweak ${tweakId}: destination GUID '$DestinationGuid' is a stock scheme GUID - NEXTRIX never provisions onto stock GUIDs"
    }
    # Validate the override list BEFORE any mutation (atomic refusal).
    $cleanOverrides = @()
    foreach ($o in @($Overrides)) {
        if (-not $o -or -not $o.subgroupGuid -or -not $o.settingGuid) {
            throw "tweak ${tweakId}: every override needs subgroupGuid + settingGuid (+ optional acIndex/dcIndex); got: $(ConvertTo-Json $o -Depth 3 -Compress)"
        }
        if (Test-NxProcessorSubgroupBoundary -SubgroupGuid ([string]$o.subgroupGuid)) {
            throw "tweak ${tweakId}: override touches the processor subgroup - min/max/boost/EPP/parking are NX03 territory (refused before any plan was created)"
        }
        $ac = $null; $dc = $null
        if ($null -ne $o.acIndex) { $ac = [int]$o.acIndex }
        if ($null -ne $o.dcIndex) { $dc = [int]$o.dcIndex }
        if ($null -eq $ac -and $null -eq $dc) {
            throw "tweak ${tweakId}: override for setting $($o.settingGuid) sets neither AC nor DC - nothing to do"
        }
        $cleanOverrides += [pscustomobject]@{ subgroupGuid = ([string]$o.subgroupGuid); settingGuid = ([string]$o.settingGuid); acIndex = $ac; dcIndex = $dc }
    }

    $list = Get-NxPowerSchemeList
    if (-not $list.parseOk) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = 'powercfg /list output unparseable (locale/format) - no capture, no mutation'; steps = $steps.ToArray() }
    }
    # Resolve the duplicate source template (default: current active scheme - XOS r1).
    $templateGuid = $TemplatePlan
    $templateNote = $null
    if ($TemplatePlan -eq 'SCHEME_CURRENT') {
        $templateGuid = $list.activeGuid
        $templateNote = 'current active scheme'
        if (-not $templateGuid) { return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = 'no active scheme to use as template'; steps = $steps.ToArray() } }
    } else {
        $t = Resolve-NxTargetPlanGuid -TargetPlan $TemplatePlan -SchemeList $list
        if (-not $t.ok -and $TemplatePlan -eq $script:NxUltimatePerformanceTemplateGuid) { $templateGuid = $TemplatePlan; $templateNote = 'hidden Ultimate Performance template' }
        elseif (-not $t.ok) { return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = "template plan not usable: $($t.reason)"; steps = $steps.ToArray() } }
        else { $templateGuid = $t.guid; $templateNote = $t.name }
    }

    $existing = @($list.schemes | Where-Object { $_.guid -eq $DestinationGuid })
    $original = [pscustomobject]@{
        targetType = 'powerPlanLifecycle'; phase = 'create'
        templateGuid = $templateGuid; templateNote = $templateNote
        destinationGuid = $DestinationGuid
        priorActiveGuid = $list.activeGuid
        priorActiveName = $(if ($list.activeGuid) { (@($list.schemes | Where-Object { $_.guid -eq $list.activeGuid }))[0].name } else { $null })
    }
    $modified = [pscustomobject]@{ targetType = 'powerPlanLifecycle'; phase = 'create'; schemeGuid = $DestinationGuid; schemeName = $PlanName }
    if ($existing.Count -gt 0) {
        if ($existing[0].name -eq $PlanName) {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyProvisioned' -Verification 'NotRun' -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'AlreadyAtState'; reason = "NEXTRIX Custom plan already provisioned as GUID $DestinationGuid"; steps = $steps.ToArray() }
        }
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = "destination GUID '$DestinationGuid' is occupied by a non-NEXTRIX plan ('$($existing[0].name)') - refusing to touch it"; steps = $steps.ToArray() }
    }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    $createdGuid = $null
    try {
        $dup = Invoke-NxPowerCfg -PowerCfgArgs @('/duplicatescheme', $templateGuid, $DestinationGuid)
        if ($dup.ok -and $dup.output -match [regex]::Escape($DestinationGuid)) { $createdGuid = $DestinationGuid }
        else {
            $dup2 = Invoke-NxPowerCfg -PowerCfgArgs @('/duplicatescheme', $templateGuid)
            $guidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
            if ($dup2.ok -and $dup2.output -match "Power Scheme GUID:\s*($guidRx)") { $createdGuid = $Matches[1].ToLower() }
        }
        if (-not $createdGuid) { throw "duplicatescheme produced no parseable scheme GUID (exit $($dup.exitCode)): $(Get-NxTruncatedText $dup.output)" }
        Invoke-NxPowerCfg -PowerCfgArgs @('/changename', $createdGuid, $PlanName, $Description) -RequireSuccess | Out-Null
        # Rebuild the journaled original with the ACTUAL created GUID (fallback-safe
        # creation may have produced a different GUID than the destination asked for).
        $original = [pscustomobject]@{
            targetType = 'powerPlanLifecycle'; phase = 'create'; schemeGuid = $createdGuid
            destinationGuid = $DestinationGuid; templateGuid = $original.templateGuid
            priorActiveGuid = $original.priorActiveGuid; priorActiveName = $original.priorActiveName
        }
        $modified = [pscustomobject]@{ targetType = 'powerPlanLifecycle'; phase = 'create'; schemeGuid = $createdGuid; schemeName = $PlanName }
        $verifyList = Get-NxPowerSchemeList
        $entry = @($verifyList.schemes | Where-Object { $_.guid -eq $createdGuid })
        $verified = ($verifyList.parseOk -and $entry.Count -gt 0 -and $entry[0].name -eq $PlanName)
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            try { if ($createdGuid -ne $verifyList.activeGuid) { Invoke-NxPowerCfg -PowerCfgArgs @('/delete', $createdGuid) | Out-Null } } catch { }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo 'created plan did not verify in /list; best-effort delete attempted' -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = 'created plan did not verify'; steps = $steps.ToArray() }
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = [string]$_.Exception.Message; steps = $steps.ToArray() }
    }

    # Apply user-authored overrides; EACH one captures the plan's template value
    # first (per-plane), journals, sets, verifies, and is restorable in reverse.
    $overrideResults = @()
    $anyFailed = $false
    foreach ($o in $cleanOverrides) {
        $r = Set-NxPlanSettingValue -TweakId $tweakId -JournalRoot $JournalRoot `
            -SubgroupGuid $o.subgroupGuid -SettingGuid $o.settingGuid -AcIndex $o.acIndex -DcIndex $o.dcIndex `
            -SchemeGuid $createdGuid -Profiles $Profiles -TweakVersion $TweakVersion -Approval $Approval -Approved
        $overrideResults += $r
        if ($r.outcome -eq 'Failed') { $anyFailed = $true; break }
    }
    if ($anyFailed) {
        # Best-effort cleanup: restore values is unnecessary if we delete the fresh plan;
        # delete only OUR just-created plan (never active - we never activated it).
        $after = Get-NxPowerSchemeList
        if ($after.parseOk -and $after.activeGuid -ne $createdGuid) {
            try { Invoke-NxPowerCfg -PowerCfgArgs @('/delete', $createdGuid) | Out-Null } catch { }
        }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo 'override failed; the just-created plan was deleted best-effort' -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = 'an override failed; the created plan was deleted best-effort (nothing left behind)'; overrideResults = $overrideResults; steps = $steps.ToArray() }
    }
    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = "created plan $createdGuid '$PlanName' with $($cleanOverrides.Count) journaled override(s) (template $($original.templateGuid))" })
    return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Applied'; createdGuid = $createdGuid; planName = $PlanName; overrideResults = $overrideResults; original = $original; modified = $modified; journalSeq = $jr.seq; steps = $steps.ToArray() }
}

function Set-NxHibernate {
    <# NX09-008 - Hibernate on/off via the documented `powercfg /h on|off`.
       Original state is journaled as the HibernateEnabled registry descriptor
       plus HiberFileSizePercent context and powercfg /a S4 availability. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][bool]$Enabled,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $tweakId = 'NX09-008'
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    Assert-NxJournalReady -JournalRoot $JournalRoot

    $hb   = Capture-NxRegistryValue -Path $script:NxHibernateRegistryPath -Name 'HibernateEnabled'
    $hfp  = Capture-NxRegistryValue -Path $script:NxHibernateRegistryPath -Name 'HiberFileSizePercent'
    $states = Get-NxSleepStateAvailability
    $targetValue = 0; if ($Enabled) { $targetValue = 1 }
    $currentOn = ($hb.existed -and [int]$hb.value -ne 0)
    $steps.Add([pscustomobject]@{ step = 2; name = 'capture-original'; outcome = 'Captured'; detail = "HibernateEnabled existed=$($hb.existed) value=$($hb.value); s4=$($states.s4) (registry-anchored, /a informational)" })

    $original = [pscustomobject]@{
        targetType = 'hibernateState'
        hibernateEnabled = $hb          # exact registry descriptor (path/kind/existed/value)
        hiberFileSizePercent = $hfp      # co-managed context (hiberfile sizing)
        s4Availability = $states.s4
    }
    $modified = [pscustomobject]@{
        targetType = 'hibernateState'
        hibernateEnabledValue = $targetValue
        direction = $(if ($Enabled) { 'on' } else { 'off' })
    }
    if ($hb.existed -and ($currentOn -eq $Enabled)) {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'AlreadyAtState'; reason = "hibernate is already $(if ($Enabled) { 'enabled' } else { 'disabled' }) (HibernateEnabled=$($hb.value))"; steps = $steps.ToArray() }
    }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        $direction = 'off'; if ($Enabled) { $direction = 'on' }
        Invoke-NxPowerCfg -PowerCfgArgs @('/h', $direction) -RequireSuccess | Out-Null
        $live = Capture-NxRegistryValue -Path $script:NxHibernateRegistryPath -Name 'HibernateEnabled'
        $verified = ($live.existed -and [int]$live.value -eq $targetValue)
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            $back = 'off'; if ($currentOn) { $back = 'on' }
            try { Invoke-NxPowerCfg -PowerCfgArgs @('/h', $back) | Out-Null } catch { }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo "HibernateEnabled=$($live.value) after /h $direction, expected $targetValue" -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = 'registry anchor did not verify after /h; original direction restored best-effort'; steps = $steps.ToArray() }
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = [string]$_.Exception.Message; steps = $steps.ToArray() }
    }
    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = "HibernateEnabled=$targetValue (direction $direction); s4=$($states.s4) at capture time" })
    return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Applied'; original = $original; modified = $modified; journalSeq = $jr.seq; steps = $steps.ToArray() }
}

function Set-NxFastStartup {
    <# NX09-009 - Fast Startup via the documented HiberbootEnabled registry
       value (locale-independent route). Full registry pipeline: exact capture
       -> journal -> set -> verify. Honest capability note: fast startup has no
       effect while hibernation is disabled (NX09-008 owns hibernate). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][bool]$Enabled,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $tweakId = 'NX09-009'
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    Assert-NxJournalReady -JournalRoot $JournalRoot
    if (-not (Get-Command Set-NxRegistryValue -ErrorAction SilentlyContinue)) {
        throw "core helper Set-NxRegistryValue (NxApply.ps1) is not loaded - load NxCore modules first"
    }

    $cap = Capture-NxRegistryValue -Path $script:NxFastStartupRegistryPath -Name 'HiberbootEnabled'
    $targetValue = 0; if ($Enabled) { $targetValue = 1 }
    $steps.Add([pscustomobject]@{ step = 2; name = 'capture-original'; outcome = 'Captured'; detail = "HiberbootEnabled existed=$($cap.existed) kind=$($cap.kind) value=$($cap.value)" })

    if ($cap.existed -and [int]$cap.value -eq $targetValue) {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $cap -Modified ([pscustomobject]@{ targetType = 'registry'; path = $cap.path; name = $cap.name; kind = 'DWord'; value = $targetValue }) -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'AlreadyAtState'; reason = "HiberbootEnabled already $targetValue"; steps = $steps.ToArray() }
    }

    $modified = [pscustomobject]@{ targetType = 'registry'; path = $cap.path; name = $cap.name; kind = 'DWord'; value = $targetValue }
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $cap -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Set-NxRegistryValue -Path $cap.path -Name $cap.name -Kind 'DWord' -Value $targetValue
        $check = Test-NxConfigurationState -Path $cap.path -Name $cap.name -Kind 'DWord' -ExpectedValue $targetValue
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $cap -Modified $modified -Result $(if ($check.verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($check.verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $check.verified) {
            # Safe stop: restore the exact original (delete if it never existed).
            if ($cap.existed) { New-ItemProperty -Path $cap.path -Name $cap.name -Value $cap.value -PropertyType $cap.kind -Force | Out-Null }
            elseif (Test-Path $cap.path) { Remove-ItemProperty -Path $cap.path -Name $cap.name -ErrorAction SilentlyContinue }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $cap -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = $check.reason; steps = $steps.ToArray() }
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $cap -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = [string]$_.Exception.Message; steps = $steps.ToArray() }
    }
    # Honest capability note (config-held vs effective-function distinction).
    $warn = $null
    if ($Enabled) {
        $states = Get-NxSleepStateAvailability
        if ($states.s4 -ne 'Available') {
            $warn = "configuration holds, but powercfg /a reports hibernation unavailable (s4=$($states.s4)); fast startup will not take effect until hibernate is enabled - NX09-008 owns that decision"
        }
    }
    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = "HiberbootEnabled=$targetValue$(if ($warn) { " [note: $warn" + ' ]' })" })
    return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Applied'; original = $cap; modified = $modified; journalSeq = $jr.seq; capabilityNote = $warn; steps = $steps.ToArray() }
}

function Export-NxPowerPlan {
    <# NX09-013 (export half) - powercfg /export to a user-chosen .pow path.
       Additive file operation; never overwrites without -Force; stock schemes
       are exportable (read-only w.r.t. configuration). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$SchemeGuid = 'SCHEME_CURRENT',
        [Parameter(Mandatory)][AllowEmptyString()][string]$OutputPath,
        [string]$TweakVersion = '1',
        [string[]]$Profiles = @(),
        [string]$Approval = 'Selection',
        [switch]$Force
    )
    $tweakId = 'NX09-013'
    $steps = New-Object System.Collections.Generic.List[object]
    Assert-NxJournalReady -JournalRoot $JournalRoot

    $list = Get-NxPowerSchemeList
    if (-not $list.parseOk) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = 'powercfg /list output unparseable (locale/format)'; steps = $steps.ToArray() }
    }
    $guid = $SchemeGuid
    if ($SchemeGuid -eq 'SCHEME_CURRENT') { $guid = $list.activeGuid }
    $entry = @($list.schemes | Where-Object { $_.guid -eq $guid })
    if ($entry.Count -eq 0) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = "plan '$guid' not present in powercfg /list - nothing exported"; steps = $steps.ToArray() }
    }

    # OutputPath: a folder, or a full .pow file path (user-chosen either way).
    $filePath = $null
    $lower = $OutputPath.ToLower()
    if ($lower.EndsWith('.pow')) {
        $filePath = $OutputPath
        $parent = Split-Path -Parent $filePath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
    } else {
        $short = ($guid -replace '^(.{8}).*', '$1')
        $resolved = Resolve-NxReportOutputPath -OutputFolder $OutputPath -FileName "NEXTRIX-powerplan-$short.pow"
        $filePath = $resolved.filePath
    }
    if ((Test-Path -LiteralPath $filePath) -and -not $Force) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = "output file '$filePath' exists - pass -Force to overwrite"; steps = $steps.ToArray() }
    }

    $original = [pscustomobject]@{ targetType = 'powerPlanFile'; phase = 'export'; changedConfiguration = $false; schemeGuid = $guid; schemeName = $entry[0].name }
    $modified = [pscustomobject]@{ targetType = 'powerPlanFile'; phase = 'export'; schemeGuid = $guid; filePath = $filePath }
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Invoke-NxPowerCfg -PowerCfgArgs @('/export', $filePath, $guid) -RequireSuccess | Out-Null
        $exists = (Test-Path -LiteralPath $filePath)
        $size = 0
        if ($exists) { $size = (Get-Item -LiteralPath $filePath).Length }
        $verified = ($exists -and $size -gt 0)
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo "export did not produce a non-empty file at '$filePath'" -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = 'export file missing or empty'; steps = $steps.ToArray() }
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = [string]$_.Exception.Message; steps = $steps.ToArray() }
    }
    return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Applied'; schemeGuid = $guid; schemeName = $entry[0].name; filePath = $filePath; bytes = $size; journalSeq = $jr.seq; steps = $steps.ToArray() }
}

function Import-NxPowerPlan {
    <# NX09-013 (import half) - powercfg /import from a user-chosen .pow file
       into an explicit target GUID. Refuses stock GUIDs (never), the active
       plan (never), and any existing plan without -AllowOverwrite consent.
       Rollback (Invoke-Nx09Rollback) deletes ONLY the imported GUID. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$TargetGuid,
        [switch]$AllowOverwrite,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $tweakId = 'NX09-013'
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (importing a plan changes machine state)" }
    Assert-NxJournalReady -JournalRoot $JournalRoot
    if (Test-NxStockSchemeGuid -Guid $TargetGuid) {
        throw "tweak ${tweakId}: target GUID '$TargetGuid' is a stock scheme GUID - importing onto stock GUIDs is forbidden"
    }
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = "source file '$FilePath' does not exist"; steps = $steps.ToArray() }
    }

    $list = Get-NxPowerSchemeList
    if (-not $list.parseOk) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = 'powercfg /list output unparseable (locale/format)'; steps = $steps.ToArray() }
    }
    $existing = @($list.schemes | Where-Object { $_.guid -eq $TargetGuid })
    if ($existing.Count -gt 0) {
        if ($list.activeGuid -eq $TargetGuid) {
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = "target GUID '$TargetGuid' is the ACTIVE plan - importing over the active plan is forbidden"; steps = $steps.ToArray() }
        }
        if (-not $AllowOverwrite) {
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = "target GUID '$TargetGuid' already exists ('$($existing[0].name)') - pass -AllowOverwrite to replace it (journaled, deletable on rollback)"; steps = $steps.ToArray() }
        }
    }

    $full = (Get-Item -LiteralPath $FilePath).FullName
    $original = [pscustomobject]@{
        targetType = 'powerPlanLifecycle'; phase = 'import'
        schemeGuid = $TargetGuid
        sourceFilePath = $full; targetGuid = $TargetGuid
        priorActiveGuid = $list.activeGuid
        priorActiveName = $(if ($list.activeGuid) { (@($list.schemes | Where-Object { $_.guid -eq $list.activeGuid }))[0].name } else { $null })
        overwrote = ($existing.Count -gt 0)
    }
    $modified = [pscustomobject]@{ targetType = 'powerPlanLifecycle'; phase = 'import'; schemeGuid = $TargetGuid; schemeName = 'imported' }
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Invoke-NxPowerCfg -PowerCfgArgs @('/import', $full, $TargetGuid) -RequireSuccess | Out-Null
        $verifyList = Get-NxPowerSchemeList
        $verified = ($verifyList.parseOk -and (@($verifyList.schemes | Where-Object { $_.guid -eq $TargetGuid }).Count -gt 0))
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo 'imported plan did not appear in /list' -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = 'imported plan did not verify in /list'; steps = $steps.ToArray() }
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = [string]$_.Exception.Message; steps = $steps.ToArray() }
    }
    return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Applied'; schemeGuid = $TargetGuid; filePath = $full; journalSeq = $jr.seq; steps = $steps.ToArray() }
}

# ---------------------------------------------------------------------------
# E. Read-only diagnostics (no firmware writes - directive NX10-family rule)
# ---------------------------------------------------------------------------

function Get-NxOemBatteryConservationState {
    <# NX09-011 - OEM battery conservation REPORTING. Existence-level probes of
       OEM utility interfaces only; state is marked Unknown wherever no
       documented read interface exists. NEVER writes (no firmware writes -
       catalogue directive). Results are uncertainty-marked by construction. #>
    [CmdletBinding()]
    param()
    $results = @()
    $lenovoKey = 'HKLM:\SOFTWARE\Lenovo\ImController\PluginData\LenovoSettingsPlugin_PowerPlugin'
    $lenovoWmi = $false
    try {
        $null = Get-CimInstance -Namespace 'root\Lenovo' -ClassName 'Lenovo_BatteryInformation' -ErrorAction Stop | Select-Object -First 1
        $lenovoWmi = $true
    } catch { $lenovoWmi = $false }
    $results += [pscustomobject]@{
        oem = 'Lenovo'; interface = 'Lenovo Vantage / LenovoUtility power plugin (ImController)'
        interfaceDetected = (Test-Path $lenovoKey) -or $lenovoWmi
        stateReadable = $false; state = 'Unknown'
        uncertainty = 'no vendor-documented read contract for conservation mode state - manage via the OEM utility; detection is existence-level only'
        provenance = 'E0 community-known interface; not vendor-documented'
    }
    foreach ($p in @(
        @{ oem = 'ASUS'; path = 'HKLM:\SOFTWARE\ASUS';  interface = 'ASUS Armoury Crate / MyASUS utility tree' }
        @{ oem = 'Dell';  path = 'HKLM:\SOFTWARE\Dell'; interface = 'Dell Power Manager / SupportAssist tree' }
        @{ oem = 'HP';    path = 'HKLM:\SOFTWARE\HP';   interface = 'HP power/thermal utility tree' }
    )) {
        $results += [pscustomobject]@{
            oem = $p.oem; interface = $p.interface
            interfaceDetected = (Test-Path $p.path)
            stateReadable = $false; state = 'Unknown'
            uncertainty = 'existence-level detection only; conservation/charge-threshold state is not exposed in a documented interface'
            provenance = 'E0 community-known interface; not vendor-documented'
        }
    }
    return [pscustomobject]@{
        readOnly = $true; noWritesPerformed = $true; results = $results
        summary = 'OEM battery conservation reporting: interface presence only; every state is Unknown unless a documented read interface exists (uncertainty-marked, no firmware writes).'
    }
}

function Get-NxOemPerformanceMode {
    <# NX09-012 - OEM performance mode DETECTION. Read-only service/registry
       presence probes; mode state stays Unknown without a documented read
       interface. NEVER writes and NEVER switches modes (no firmware writes -
       catalogue directive; switching belongs to NX10-006's per-OEM modules
       only where an interface is documented). #>
    [CmdletBinding()]
    param()
    $matches = @()
    try {
        $svcs = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -match 'Armoury|MyASUS|Lenovo Vantage|SupportAssist|HP (System Event|Power)|Omen|Legion|Gigabyte|MSI (Center|Dragon)'
        })
        foreach ($s in $svcs) { $matches += [pscustomobject]@{ service = $s.Name; displayName = $s.DisplayName; status = [string]$s.Status } }
    } catch { }
    return [pscustomobject]@{
        readOnly = $true; noWritesPerformed = $true
        detectedUtilityServices = @($matches)
        modeState = 'Unknown'
        uncertainty = 'OEM performance-mode state is not exposed through a documented, scriptable interface on current OEM stacks; this is detection of the utility layer only'
        provenance = 'E0 community-known; no vendor documentation of a state contract'
        summary = 'OEM performance mode detection: utility-service presence reported; mode state Unknown (uncertainty-marked; NEXTRIX never writes firmware).'
    }
}

function Invoke-NxEnergyReport {
    <# NX09-014 - Read-only powercfg /energy diagnostic. Observes the system
       for -DurationSeconds and writes energy-report.htm to the chosen folder.
       No configuration is changed; the report file is the only output. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [ValidateRange(1,3600)][int]$DurationSeconds = 60,
        [string]$JournalRoot,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1'
    )
    $tweakId = 'NX09-014'
    $path = Resolve-NxReportOutputPath -OutputFolder $OutputFolder -FileName 'NEXTRIX-energy-report.htm'
    $r = Invoke-NxPowerCfg -PowerCfgArgs @('/energy', '/duration', [string]$DurationSeconds, '/output', $path.filePath)
    $size = 0
    if (Test-Path -LiteralPath $path.filePath) { $size = (Get-Item -LiteralPath $path.filePath).Length }
    $ok = ($r.ok -and $size -gt 0)
    if ($JournalRoot -and (Test-NxJournalPresent -JournalRoot $JournalRoot)) {
        $original = [pscustomobject]@{ targetType = 'powerDiagnostic'; changedConfiguration = $false; command = 'powercfg /energy' }
        $modified = [pscustomobject]@{ targetType = 'powerDiagnostic'; filePath = $path.filePath; durationSeconds = $DurationSeconds }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval 'Selection' -Original $original -Modified $modified -Result $(if ($ok) { 'Success' } else { 'Failed' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $(if ($ok) { '' } else { (Get-NxTruncatedText $r.output) }) -Profiles $Profiles | Out-Null
    }
    return [pscustomobject]@{
        tweakId = $tweakId; outcome = $(if ($ok) { 'Applied' } else { 'Failed' })
        filePath = $path.filePath; bytes = $size; durationSeconds = $DurationSeconds
        exitCode = $r.exitCode; outputSample = (Get-NxTruncatedText $r.output)
    }
}

function Invoke-NxBatteryReport {
    <# NX09-015 - Read-only powercfg /batteryreport diagnostic to the chosen
       folder. Requires a battery; on battery-less desktops the command fails
       honestly (exit code + sample reported, nothing fabricated). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [string]$JournalRoot,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1'
    )
    $tweakId = 'NX09-015'
    $path = Resolve-NxReportOutputPath -OutputFolder $OutputFolder -FileName 'NEXTRIX-battery-report.html'
    $r = Invoke-NxPowerCfg -PowerCfgArgs @('/batteryreport', '/output', $path.filePath)
    $size = 0
    if (Test-Path -LiteralPath $path.filePath) { $size = (Get-Item -LiteralPath $path.filePath).Length }
    $ok = ($r.ok -and $size -gt 0)
    if ($JournalRoot -and (Test-NxJournalPresent -JournalRoot $JournalRoot)) {
        $original = [pscustomobject]@{ targetType = 'powerDiagnostic'; changedConfiguration = $false; command = 'powercfg /batteryreport' }
        $modified = [pscustomobject]@{ targetType = 'powerDiagnostic'; filePath = $path.filePath }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval 'Selection' -Original $original -Modified $modified -Result $(if ($ok) { 'Success' } else { 'Failed' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $(if ($ok) { '' } else { (Get-NxTruncatedText $r.output) }) -Profiles $Profiles | Out-Null
    }
    return [pscustomobject]@{
        tweakId = $tweakId; outcome = $(if ($ok) { 'Applied' } else { 'Failed' })
        filePath = $path.filePath; bytes = $size
        exitCode = $r.exitCode; outputSample = (Get-NxTruncatedText $r.output)
    }
}

# ---------------------------------------------------------------------------
# F. NX09 rollback path (per-plane only-if-ours; never deletes the active
#    plan - switch away first; never deletes stock schemes; restore order is
#    reverse journal sequence so NX09-003 overrides restore before the plan
#    that carries them is deleted).
# ---------------------------------------------------------------------------

function Get-Nx09RollbackCandidates {
    # PURE selection logic (testable without any mutation): verified-success
    # NX09 mutations only. Additive/diagnostic targetTypes never qualify.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$JournalEntries)
    $restorableTypes = @('powerSetting', 'powerPlanSelection', 'powerPlanLifecycle', 'hibernateState', 'registry')
    return @($JournalEntries | Where-Object {
        $_.tweakId -like 'NX09-*' -and
        $_.operation -eq 'verify' -and $_.result -eq 'Success' -and $_.verification -eq 'Verified' -and
        ($restorableTypes -contains [string]$_.original.targetType)
    })
}

function Invoke-Nx09Rollback {
    <# NX09's own rollback replay. Same semantics as NxRollback (integrity-gated,
       reverse order, only-if-ours, per-step journaled and verified), handling
       the NX09 targetTypes the registry-engine v0.1 does not cover. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId,
        [switch]$AllNx09
    )
    if (-not $TweakId -and -not $AllNx09) {
        throw "Invoke-Nx09Rollback: specify -TweakId or -AllNx09 (no implicit full-category rollback)"
    }
    $journal = Read-NxJournal -Path $JournalRoot
    if ($journal.integrityErrors.Count -gt 0) {
        return [pscustomobject]@{ aborted = $true; integrityErrors = $journal.integrityErrors; restored = @(); diverged = @(); failed = @() }
    }
    $candidates = Get-Nx09RollbackCandidates -JournalEntries $journal.entries
    if ($TweakId) { $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId }) }
    [array]::Reverse($candidates)

    $restored = New-Object System.Collections.Generic.List[object]
    $diverged = New-Object System.Collections.Generic.List[object]
    $failed   = New-Object System.Collections.Generic.List[object]

    foreach ($e in $candidates) {
        $orig = $e.original; $mod = $e.modified
        $type = [string]$orig.targetType
        try {
            switch ($type) {
                'powerSetting' {
                    $live = Get-NxPowerSettingValue -SchemeGuid $orig.schemeGuid -SubgroupGuid $orig.subgroupGuid -SettingGuid $orig.settingGuid
                    if (-not $live.found) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "plan $($orig.schemeGuid) :: $($orig.settingGuid)"; reason = 'plan or setting no longer present (plan may have been deleted) - nothing restored' })
                        Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'setting no longer present' -Profiles @($e.profiles)
                        break
                    }
                    $acOurs = ([int64]$live.acIndex -eq [int64]$mod.acIndex)
                    $dcOurs = ([int64]$live.dcIndex -eq [int64]$mod.dcIndex)
                    $planeInfo = @()
                    if ($acOurs) { Invoke-NxPowerCfg -PowerCfgArgs @('/setacvalueindex', $orig.schemeGuid, $orig.subgroupGuid, $orig.settingGuid, [string]$orig.acIndex) -RequireSuccess | Out-Null; $planeInfo += "AC->$($orig.acIndex)" }
                    if ($dcOurs) { Invoke-NxPowerCfg -PowerCfgArgs @('/setdcvalueindex', $orig.schemeGuid, $orig.subgroupGuid, $orig.settingGuid, [string]$orig.dcIndex) -RequireSuccess | Out-Null; $planeInfo += "DC->$($orig.dcIndex)" }
                    $after = Get-NxPowerSettingValue -SchemeGuid $orig.schemeGuid -SubgroupGuid $orig.subgroupGuid -SettingGuid $orig.settingGuid
                    # Per-plane honesty: a plane still ours is restored to its original
                    # index and must read back exactly; a plane the user changed after
                    # apply is reported diverged and must remain untouched (never clobbered).
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
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $result -Verification $ver -ErrorInfo $partial -Profiles @($e.profiles)
                    $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored plan setting'; detail = "plan $($orig.schemeGuid) :: $($orig.settingGuid) ($($planeInfo -join ', '))"; verified = $restoreOk })
                }
                'powerPlanSelection' {
                    $active = Get-NxActivePowerScheme
                    if (-not $active.parseOk -or $active.guid -ne $mod.schemeGuid) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = 'active scheme'; reason = "active scheme is '$($active.guid)' but NEXTRIX recorded setting '$($mod.schemeGuid)' - left untouched for user decision" })
                        Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: active scheme differs from recorded modified state' -Profiles @($e.profiles)
                        break
                    }
                    $list = Get-NxPowerSchemeList
                    if ((@($list.schemes | Where-Object { $_.guid -eq $orig.schemeGuid })).Count -eq 0) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = 'active scheme'; reason = "original plan '$($orig.schemeGuid)' no longer exists - not guessed, nothing switched" })
                        Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'original active plan was deleted' -Profiles @($e.profiles)
                        break
                    }
                    Invoke-NxPowerCfg -PowerCfgArgs @('/setactive', $orig.schemeGuid) -RequireSuccess | Out-Null
                    $after = Get-NxActivePowerScheme
                    $verified = ($after.parseOk -and $after.guid -eq $orig.schemeGuid)
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles)
                    $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'switched active scheme'; detail = "$($orig.schemeGuid) ('$(if ($orig.schemeName) { $orig.schemeName } else { 'unnamed' })')"; verified = $verified })
                }
                'powerPlanLifecycle' {
                    # create/import restore: delete ONLY the journal-recorded plan,
                    # never stock, never while active (switch away first, #14).
                    # GUID resolution is fallback-safe: modified carries the actual
                    # created/imported GUID; originals may carry schemeGuid /
                    # destinationGuid / targetGuid depending on the journal version.
                    $planGuid = $mod.schemeGuid
                    if (-not $planGuid) { $planGuid = $orig.schemeGuid }
                    if (-not $planGuid) { $planGuid = $orig.destinationGuid }
                    if (-not $planGuid) { $planGuid = $orig.targetGuid }
                    if (-not $planGuid) {
                        $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = 'lifecycle journal entry carries no plan GUID - refusing' })
                        Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo 'no plan GUID in journal entry' -Profiles @($e.profiles)
                        break
                    }
                    if (Test-NxStockSchemeGuid -Guid $planGuid) {
                        $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = "stock-scheme guard tripped for $planGuid - refusing (this should never fire)" })
                        Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo 'stock scheme guard tripped - refusing to delete' -Profiles @($e.profiles)
                        break
                    }
                    $list = Get-NxPowerSchemeList
                    if (-not $list.parseOk) {
                        $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = 'powercfg /list unparseable - refusing lifecycle restore' })
                        Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo 'list unparseable' -Profiles @($e.profiles)
                        break
                    }
                    $plan = @($list.schemes | Where-Object { $_.guid -eq $planGuid })
                    if ($plan.Count -eq 0) {
                        $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'plan already gone'; detail = $planGuid; verified = $true })
                        Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Success' -Verification 'Verified' -ErrorInfo 'plan already absent (idempotent rollback)' -Profiles @($e.profiles)
                        break
                    }
                    if ($list.activeGuid -eq $planGuid) {
                        # Never delete the active plan - switch away first.
                        $switchTo = $null; $switchNote = $null
                        if ($orig.priorActiveGuid -and ((@($list.schemes | Where-Object { $_.guid -eq $orig.priorActiveGuid })).Count -gt 0)) {
                            $switchTo = $orig.priorActiveGuid; $switchNote = 'journaled prior-active scheme'
                        } elseif ((@($list.schemes | Where-Object { $_.guid -eq '381b4222-f694-41f0-9685-ff5bb260df2e' })).Count -gt 0) {
                            $switchTo = '381b4222-f694-41f0-9685-ff5bb260df2e'; $switchNote = 'prior-active plan no longer exists; documented stock fallback Balanced (divergence noted)'
                        } else {
                            $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = 'plan is active and no switch-away target exists - refusing to delete the active plan' })
                            Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo 'active plan with no switch-away target' -Profiles @($e.profiles)
                            break
                        }
                        Invoke-NxPowerCfg -PowerCfgArgs @('/setactive', $switchTo) -RequireSuccess | Out-Null
                    }
                    Invoke-NxPowerCfg -PowerCfgArgs @('/delete', $planGuid) -RequireSuccess | Out-Null
                    $after = Get-NxPowerSchemeList
                    $verified = ($after.parseOk -and ((@($after.schemes | Where-Object { $_.guid -eq $planGuid })).Count -eq 0))
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $(if ($switchNote) { $switchNote } else { '' }) -Profiles @($e.profiles)
                    $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'deleted NEXTRIX-created plan'; detail = "$planGuid$(if ($switchNote) { " [$switchNote]" })"; verified = $verified })
                }
                'hibernateState' {
                    $live = Capture-NxRegistryValue -Path $script:NxHibernateRegistryPath -Name 'HibernateEnabled'
                    $ours = ($live.existed -and [int]$live.value -eq [int]$mod.hibernateEnabledValue)
                    if (-not $ours) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = 'HibernateEnabled'; reason = "current value '$($live.value)' differs from recorded modified '$($mod.hibernateEnabledValue)' - left untouched" })
                        Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: HibernateEnabled differs' -Profiles @($e.profiles)
                        break
                    }
                    $direction = 'off'
                    if ($orig.hibernateEnabled.existed -and [int]$orig.hibernateEnabled.value -ne 0) { $direction = 'on' }
                    Invoke-NxPowerCfg -PowerCfgArgs @('/h', $direction) -RequireSuccess | Out-Null
                    $after = Capture-NxRegistryValue -Path $script:NxHibernateRegistryPath -Name 'HibernateEnabled'
                    $verified = ($after.existed -and (($direction -eq 'on') -eq ([int]$after.value -ne 0)))
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles)
                    $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored hibernate direction'; detail = "/h $direction (original HibernateEnabled existed=$($orig.hibernateEnabled.existed) value=$($orig.hibernateEnabled.value))"; verified = $verified })
                }
                'registry' {
                    # NX09-009 HiberbootEnabled: exact original restore, only-if-ours.
                    $live = Capture-NxRegistryValue -Path $orig.path -Name $orig.name
                    $ours = Test-NxCurrentEqualsDescriptor -Descriptor $live -Kind ([string]$mod.kind) -Value $mod.value
                    if (-not $ours) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "$($orig.path) :: $($orig.name)"; reason = 'current value differs from recorded modified state - left untouched' })
                        Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: registry value differs' -Profiles @($e.profiles)
                        break
                    }
                    if ($orig.existed) {
                        if (-not (Test-Path $orig.path)) { New-Item -Path $orig.path -Force | Out-Null }
                        New-ItemProperty -Path $orig.path -Name $orig.name -Value $orig.value -PropertyType $orig.kind -Force | Out-Null
                    } else {
                        if (Test-Path $orig.path) { Remove-ItemProperty -Path $orig.path -Name $orig.name -ErrorAction SilentlyContinue }
                    }
                    $check = Test-NxConfigurationState -Path $orig.path -Name $orig.name -Kind ([string]$orig.kind) -ExpectedValue $(if ($orig.existed) { $orig.value } else { $null })
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($check.verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($check.verified) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles)
                    $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored registry value'; detail = "$($orig.path) :: $($orig.name) ($($orig.kind))"; verified = $check.verified })
                }
                default {
                    $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = "unsupported targetType '$type' in NX09 rollback" })
                }
            }
        } catch {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'failed' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles @($e.profiles)
            $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = [string]$_.Exception.Message })
        }
    }
    return [pscustomobject]@{ aborted = $false; restored = $restored.ToArray(); diverged = $diverged.ToArray(); failed = $failed.ToArray(); integrityErrors = @() }
}
