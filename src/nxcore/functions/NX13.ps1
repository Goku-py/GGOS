#Requires -Version 5.1
<#
    NX13.ps1 - NEXTRIX Privacy & Telemetry category functions.

    Entries implemented here as functions (complex, edition-aware, selective or
    read-only): NX13-004 (diagnostic data level), NX13-005 (app permission
    defaults), NX13-013 (telemetry tasks, plus the delegated rollback engine) and
    NX13-014 (read-only permission audit). Entries NX13-001/002/003/006/007/008/
    009/010/011/012 are declarative registry actions in registry/NX13.json and are
    applied by the engine pipeline in NxApply.ps1.

    Dependencies (dot-source AFTER the core modules, Import-NxCore order):
      NxJournal.ps1  -> Capture-NxRegistryValue, Add-NxJournalEntry, Read-NxJournal
      NxBuild.ps1    -> Get-NxBuildReport (edition id, read-only)
      NxVerify.ps1   -> Test-NxConfigurationState
      NxApply.ps1    -> Set-NxRegistryValue
      NxRollback.ps1 -> Restore-NxRegistryOriginal (best-effort restore on failed verify)
    Loading this file defines functions only: no registry/CIM/task reads or writes
    and no network access happen at load time.

    Contract (same as every mutating category function):
      Capture exact original state -> journal-first -> mutate -> verify -> journal.
      An already-correct target journals a 'skip' (AlreadyApplied), never a rewrite.
      A verification failure performs a best-effort restore of the exact recorded
      original and journals 'failed' - a safe stop, never a silent continue.
      Mutating functions refuse to run without -Approved (the wizard checkbox /
      explicit consent is the approval event); -WhatIf plans without touching
      anything (no journal write, no registry/task change).

    Directives honoured throughout:
      - Privacy changes are never described as performance improvements.
      - Edition-aware behaviour is honest: Microsoft documents AllowTelemetry=0 as
        Enterprise/Education/Server-only and states that on other editions the value
        is equivalent to 1, so Home/Pro get the documented floor 1 - no placebo 0.
      - Ownership: Start_Track* (NX15), ContentDeliveryManager consumer content
        (NX01), per-app permission override lists (NX11-002), generic task
        management (NX11-006) and services (never-touch list) are NOT touched here.
      - No hosts-file modification, no service reconfiguration, no ControlSet00x
        writes anywhere in this file.
#>

# ============================================================================
# Internal helper - the 10-step journaled registry pipeline (one place only)
# ============================================================================

function Invoke-Nx13RegistryTarget {
    <#
        Capture -> (idempotency skip) -> journal 'apply' -> write -> verify ->
        journal result. Returns a per-target result object. Used by every mutating
        NX13 function so the journal-first order exists in exactly one place.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$TweakId,
        [string]$TweakVersion = '1',
        [Parameter(Mandatory)][string]$Approval,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('String','ExpandString','Binary','DWord','MultiString','QWord')][string]$Kind,
        [Parameter(Mandatory)]$Value,
        [string[]]$Profiles = @()
    )
    $target = "$Path :: $Name"
    $orig = Capture-NxRegistryValue -Path $Path -Name $Name
    $modified = [pscustomobject]@{ targetType = 'registry'; path = $Path; name = $Name; kind = $Kind; value = $Value }

    if (-not $PSCmdlet.ShouldProcess($target, "Set $Kind to the intended value")) {
        return [pscustomobject]@{ target = $target; changed = $false; verified = $false; journalSeq = $null; reason = 'WhatIf/Confirm: no mutation, no journal write' }
    }

    # Idempotency: desired state already present -> record a skip, never rewrite.
    if ($orig.existed -and ([string]$orig.kind -eq $Kind)) {
        $existing = ConvertTo-Json -InputObject $orig.value -Depth 6 -Compress
        $desired  = ConvertTo-Json -InputObject $Value -Depth 6 -Compress
        if ($existing -eq $desired) {
            $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $orig -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
            return [pscustomobject]@{ target = $target; changed = $false; verified = $true; journalSeq = $skip.seq; reason = 'already in desired state' }
        }
    }

    $applyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $orig -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Set-NxRegistryValue -Path $Path -Name $Name -Kind $Kind -Value $Value
        $check = Test-NxConfigurationState -Path $Path -Name $Name -Kind $Kind -ExpectedValue $Value
        if ($check.verified) {
            $verifyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $orig -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles $Profiles
            return [pscustomobject]@{ target = $target; changed = $true; verified = $true; journalSeq = $applyJournal.seq; verifySeq = $verifyJournal.seq; reason = $check.reason }
        }
        # Safe stop: best-effort restore of the exact original, then journal failure.
        try { Restore-NxRegistryOriginal -Entry ([pscustomobject]@{ original = $orig }) | Out-Null } catch { }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles
        return [pscustomobject]@{ target = $target; changed = $true; verified = $false; journalSeq = $applyJournal.seq; reason = $check.reason }
    } catch {
        $err = [string]$_.Exception.Message
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles
        return [pscustomobject]@{ target = $target; changed = $false; verified = $false; journalSeq = $applyJournal.seq; reason = "mutation failed: $err" }
    }
}

# ============================================================================
# NX13-004 - edition-aware diagnostic data floor
# ============================================================================

function Get-Nx13DiagnosticDataFloor {
    <#
    .SYNOPSIS
        Pure resolver: which AllowTelemetry level Microsoft documents for an edition.
    .DESCRIPTION
        Policy CSP System (AllowTelemetry) states that value 0 ("Security") is only
        applicable to Enterprise/Education/Server editions and that using it on other
        devices "is equivalent to setting the value of 1". This resolver therefore
        returns floor 0 only for the documented families and floor 1 otherwise -
        including unknown editions, which are treated conservatively with an explicit
        uncertainty flag instead of being guessed.

        Returns: editionId, family, floor, floorDocumented, explanation, uncertainty.
    #>
    [CmdletBinding()]
    param(
        [string]$EditionId,
        [string]$ProductName
    )
    $id = ([string]$EditionId).Trim()
    $out = [ordered]@{
        editionId      = $id
        productName    = [string]$ProductName
        family         = 'Unknown'
        floor          = 1
        floorDocumented = $true
        explanation    = ''
        uncertainty    = @()
    }

    $enterpriseIds = @('Enterprise','EnterpriseN','EnterpriseS','EnterpriseSN','EnterpriseG','EnterpriseGN','IoTEnterprise','IoTEnterpriseS','ServerStandard','ServerDatacenter','ServerSolution','ServerEnterprise','ServerRdsh')
    $educationIds  = @('Education','EducationN')
    $proIds        = @('Professional','ProfessionalN','ProfessionalEducation','ProfessionalWorkstation','ProfessionalWorkstationN')
    $homeIds       = @('Core','CoreN','CoreSingleLanguage','CoreCountrySpecific','CoreConnected','CoreConnectedN','Starter')

    if ($enterpriseIds -contains $id) {
        $out.family = 'Enterprise'
        $out.floor = 0
        $out.explanation = "Microsoft documents diagnostic data off (AllowTelemetry=0) for the $id edition; floor 0 is applied."
    } elseif ($educationIds -contains $id) {
        $out.family = 'Education'
        $out.floor = 0
        $out.explanation = "Microsoft documents diagnostic data off (AllowTelemetry=0) for the $id edition; floor 0 is applied."
    } elseif ($proIds -contains $id) {
        $out.family = 'Pro'
        $out.floor = 1
        $out.explanation = "Microsoft documents AllowTelemetry=0 as Enterprise/Education/Server-only and states that using it on other editions is equivalent to 1; the documented floor for $id is 1 (required diagnostic data)."
    } elseif ($homeIds -contains $id) {
        $out.family = 'Home'
        $out.floor = 1
        $out.explanation = "Microsoft documents AllowTelemetry=0 as Enterprise/Education/Server-only and states that using it on other editions is equivalent to 1; the documented floor for $id is 1 (required diagnostic data)."
    } else {
        $out.family = 'Unknown'
        $out.floor = 1
        $out.floorDocumented = $false
        $out.explanation = "Edition id '$id' is not in NEXTRIX's documented mapping; the conservative floor 1 is applied and the edition is reported as uncertain (never guessed as Enterprise)."
        $out.uncertainty += "unrecognised edition id '$id' - conservative floor 1 applied"
    }
    return [pscustomobject]$out
}

function Set-NxDiagnosticDataLevel {
    <#
    .SYNOPSIS
        NX13-004: lowest documented diagnostic-data level for this edition.
    .DESCRIPTION
        Enterprise/Education/Server -> AllowTelemetry=0; Home/Pro -> AllowTelemetry=1
        (the documented floor - Microsoft states 0 is equivalent to 1 there).
        Always adds LimitDumpCollection=1 and LimitDiagnosticLogCollection=1.
        Deliberately does not write undocumented HKCU DiagTrack "shadow" values and
        never reconfigures the DiagTrack service (NX11-017 territory).
        -EditionId exists so tests/future callers can resolve a specific edition;
        by default the live edition is read read-only.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Minimal')][string]$Level = 'Minimal',
        [switch]$Approved,
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [string]$TweakId = 'NX13-004',
        [string]$TweakVersion = '1',
        [string]$EditionId
    )
    if (-not $Approved -and -not $WhatIfPreference) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }

    $uncertainty = New-Object System.Collections.Generic.List[string]
    $editionIdResolved = $EditionId
    $productName = $null
    if ([string]::IsNullOrWhiteSpace($editionIdResolved)) {
        $build = $null
        try { $build = Get-NxBuildReport } catch { $build = $null }
        if ($null -ne $build -and $build.readSucceeded) {
            $editionIdResolved = [string]$build.editionId
            $productName = [string]$build.productName
        } else {
            $uncertainty.Add('build report unavailable - edition could not be resolved before apply')
        }
    }
    $floor = Get-Nx13DiagnosticDataFloor -EditionId $editionIdResolved -ProductName $productName
    foreach ($u in @($floor.uncertainty)) { $uncertainty.Add($u) }

    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
    $targets = @(
        @{ name = 'AllowTelemetry';                data = [int]$floor.floor },
        @{ name = 'LimitDumpCollection';           data = 1 },
        @{ name = 'LimitDiagnosticLogCollection';  data = 1 }
    )

    $results = New-Object System.Collections.Generic.List[object]
    $placeboLeftInPlace = $false
    foreach ($t in $targets) {
        # Honesty guard: on Home/Pro the documented floor is 1, but a machine may
        # already carry a community-written 0 - which Microsoft documents as
        # equivalent to 1. Rewriting a behaviourally identical value would be a
        # pointless mutation, so the existing value is left in place and reported.
        if ($t.name -eq 'AllowTelemetry' -and [int]$floor.floor -eq 1 -and -not $WhatIfPreference) {
            $current = Capture-NxRegistryValue -Path $policyPath -Name 'AllowTelemetry'
            if ($current.existed -and [string]$current.kind -eq 'DWord' -and [int]$current.value -eq 0) {
                $descriptor = [pscustomobject]@{ targetType = 'registry'; path = $policyPath; name = 'AllowTelemetry'; kind = 'DWord'; value = 0 }
                $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $current -Modified $descriptor -Result 'DocumentedPlaceboEquivalence' -Verification 'NotRun' -Profiles $Profiles
                $placeboLeftInPlace = $true
                $results.Add([pscustomobject]@{ target = "$policyPath :: AllowTelemetry"; changed = $false; verified = $true; journalSeq = $skip.seq; reason = 'existing 0 on this edition is documented as equivalent to 1 - left in place (no pointless rewrite)' })
                continue
            }
        }
        $results.Add((Invoke-Nx13RegistryTarget -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $policyPath -Name $t.name -Kind DWord -Value $t.data -Profiles $Profiles))
    }

    $applied = @($results | Where-Object { $_.verified }).Count
    $notes = New-Object System.Collections.Generic.List[string]
    $notes.Add($floor.explanation)
    if ($placeboLeftInPlace) {
        $notes.Add('A pre-existing AllowTelemetry=0 was found on an edition where Microsoft documents 0 as equivalent to 1; it was left in place and recorded as a documented-placebo equivalence instead of being rewritten.')
    }
    if ($floor.floor -gt 0) {
        $notes.Add('Requested "Minimal" resolves to the documented floor 1 on this edition: a 0 written here would be documented as equivalent to 1 (placebo) and is deliberately not written.')
    }
    $notes.Add('Undocumented HKCU DiagTrack shadow values (MaxTelemetryAllowed / ShowedToastAtLevel) are not written; they are not documented values.')
    $notes.Add('The DiagTrack service is not reconfigured by this entry (service ownership: NX11-017, recorded for the coordinator).')

    return [pscustomobject]@{
        tweakId          = $TweakId
        level            = $Level
        edition          = [pscustomobject]@{ editionId = $floor.editionId; family = $floor.family; floor = $floor.floor; floorDocumented = $floor.floorDocumented }
        appliedLevel     = [int]$floor.floor
        floorHonoured    = $true
        placeboLeftInPlace = $placeboLeftInPlace
        targets          = $results.ToArray()
        targetsVerified  = $applied
        allVerified      = ($applied -eq $targets.Count)
        notes            = $notes.ToArray()
        uncertainty      = $uncertainty.ToArray()
    }
}

# ============================================================================
# NX13-005 - documented AppPrivacy permission defaults (per-item consent)
# ============================================================================

function Get-Nx13PermissionMap {
    <#
        Pure map: NEXTRIX permission key -> documented AppPrivacy value name and the
        OS consent-store capability name (camera->webcam, calendar->appointments are
        the real consent-store folder names, verified read-only on build 26300).
    #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ key = 'location';   valueName = 'LetAppsAccessLocation';   consentStore = 'location' }
        [pscustomobject]@{ key = 'camera';     valueName = 'LetAppsAccessCamera';     consentStore = 'webcam' }
        [pscustomobject]@{ key = 'microphone'; valueName = 'LetAppsAccessMicrophone'; consentStore = 'microphone' }
        [pscustomobject]@{ key = 'contacts';   valueName = 'LetAppsAccessContacts';   consentStore = 'contacts' }
        [pscustomobject]@{ key = 'calendar';   valueName = 'LetAppsAccessCalendar';   consentStore = 'appointments' }
    )
}

function Get-NxAppPermissionState {
    <#
    .SYNOPSIS
        Read-only per-capability permission picture (policy + per-user consent store).
    .DESCRIPTION
        Never journals, never mutates. Per-app enumeration is bounded by
        -MaxAppsPerCapability (the total count is still reported). A missing key or
        value is reported as absent, never as 'denied'.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('location','camera','microphone','contacts','calendar')][string[]]$Permissions = @('location','camera','microphone','contacts','calendar'),
        [ValidateRange(0, 500)][int]$MaxAppsPerCapability = 25
    )
    $policyPath  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
    $consentRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
    $map = Get-Nx13PermissionMap
    $rows = New-Object System.Collections.Generic.List[object]
    $uncertainty = New-Object System.Collections.Generic.List[string]

    $meaning = @{ 0 = 'user in control'; 1 = 'force allow'; 2 = 'force deny' }
    foreach ($m in $map) {
        if ($Permissions -notcontains $m.key) { continue }
        $policy = Capture-NxRegistryValue -Path $policyPath -Name $m.valueName
        $policyText = 'absent'
        if ($policy.existed -and [string]$policy.kind -eq 'DWord') {
            $iv = 0
            if ([int]::TryParse([string]$policy.value, [ref]$iv) -and $meaning.ContainsKey($iv)) { $policyText = [string]$iv + ' (' + $meaning[$iv] + ')' }
            else { $policyText = [string]$policy.value + ' (unrecognised value)'; $uncertainty.Add("$($m.valueName): value '$($policy.value)' is outside the documented 0/1/2 range") }
        } elseif ($policy.existed) {
            $policyText = "$($policy.kind) (wrong kind - not evaluated)"
            $uncertainty.Add("$($m.valueName): stored as $($policy.kind), documented kind is DWord")
        }

        $consentValue = $null
        $allow = 0; $deny = 0; $total = 0; $apps = @()
        $consentKey = Join-Path $consentRoot $m.consentStore
        if (Test-Path $consentKey) {
            $k = Get-Item -Path $consentKey -ErrorAction SilentlyContinue
            if ($null -ne $k) {
                $v = $k.GetValue('Value', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($null -ne $v) { $consentValue = [string]$v }
            }
            $subs = @(Get-ChildItem -Path $consentKey -ErrorAction SilentlyContinue)
            $total = $subs.Count
            foreach ($s in $subs) {
                $sv = $s.GetValue('Value', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($null -eq $sv) { continue }
                if ([string]$sv -eq 'Allow') { $allow++ } elseif ([string]$sv -eq 'Deny') { $deny++ }
                if ($apps.Count -lt $MaxAppsPerCapability) {
                    $apps += [pscustomobject]@{ app = $s.PSChildName; consent = [string]$sv }
                }
            }
        } else {
            $uncertainty.Add("consent-store key missing for '$($m.consentStore)' (per-app detail unavailable)")
        }

        $rows.Add([pscustomobject]@{
            permission     = $m.key
            policyValue    = $m.valueName
            policyState    = $policyText
            consentValue   = $consentValue
            appsAllow      = $allow
            appsDeny       = $deny
            appsTotal      = $total
            appsTruncated  = ($total -gt $apps.Count)
            apps           = $apps
        })
    }
    return [pscustomobject]@{ readOnly = $true; permissions = $rows.ToArray(); uncertainty = $uncertainty.ToArray() }
}

function Set-NxAppPermissionDefaults {
    <#
    .SYNOPSIS
        NX13-005: force-deny (2) or return to user-control (0) selected AppPrivacy
        capability defaults, per capability, journaled.
    .DESCRIPTION
        -Permissions is mandatory: per-item consent is structural, not a blanket
        sweep. Writes only the documented "default for all apps" value for each
        selected capability. Per-app override lists are NX11-002 territory and are
        never written. Returns the pre-change report plus per-capability results.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateSet('location','camera','microphone','contacts','calendar')][string[]]$Permissions,
        [ValidateSet('Deny','UserControl')][string]$Mode = 'Deny',
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakId = 'NX13-005',
        [string]$TweakVersion = '1'
    )
    if (-not $Approved -and -not $WhatIfPreference) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    if (@($Permissions).Count -eq 0) { throw "$TweakId : -Permissions is required (per-item consent)" }

    $before = Get-NxAppPermissionState -Permissions $Permissions
    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
    $map = Get-Nx13PermissionMap
    $value = if ($Mode -eq 'Deny') { 2 } else { 0 }
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($p in $map) {
        if ($Permissions -notcontains $p.key) { continue }
        $r = Invoke-Nx13RegistryTarget -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $policyPath -Name $p.valueName -Kind DWord -Value $value -Profiles $Profiles
        $r | Add-Member -NotePropertyName permission -NotePropertyValue $p.key -Force
        $results.Add($r)
    }

    $applied = @($results | Where-Object { $_.verified }).Count
    return [pscustomobject]@{
        tweakId        = $TweakId
        mode           = $Mode
        writtenValue   = $value
        before         = $before
        targets        = $results.ToArray()
        targetsVerified = $applied
        allVerified    = ($applied -eq $results.Count)
        notes          = @(
            'Force-deny blocks Windows (packaged) apps for every user of the device; affected apps must be restarted (Microsoft-documented).',
            'Desktop (Win32) apps are governed by the separate documented namespace policies, which this entry does not write.',
            'Per-app override lists (NX11-002) and the background-apps global value (NX01-008) are not touched.'
        )
    }
}

# ============================================================================
# NX13-013 - telemetry-related scheduled tasks (allow-list, per-task journal)
# ============================================================================

function Get-Nx13TelemetryTaskAllowList {
    <#
        Pure allow-list. Every candidate carries its category and why it is in scope.
        Deliberately EXCLUDED from this list: WindowsUpdate\Scheduled Start,
        UpdateOrchestrator, maintenance/defrag tasks and Windows Error Reporting\
        QueueReporting (the last one is opt-in via -IncludeErrorReportingQueue).
        The lists are kept disjoint from NX11-006's generic task management.
    #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ taskPath = '\Microsoft\Windows\Application Experience\'; taskName = 'Microsoft Compatibility Appraiser'; category = 'compatibility-appraisal'; defaultIncluded = $true;  note = 'compatibility appraiser (absent on some 24H2+/serviced builds)' }
        [pscustomobject]@{ taskPath = '\Microsoft\Windows\Application Experience\'; taskName = 'ProgramDataUpdater';            category = 'compatibility-appraisal'; defaultIncluded = $true;  note = 'application-experience program-data updater' }
        [pscustomobject]@{ taskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; taskName = 'Consolidator';  category = 'ceip';   defaultIncluded = $true;  note = 'CEIP consolidation/upload' }
        [pscustomobject]@{ taskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; taskName = 'UsbCeip';      category = 'ceip';   defaultIncluded = $true;  note = 'CEIP USB inventory' }
        [pscustomobject]@{ taskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; taskName = 'KernelCeipTask'; category = 'ceip'; defaultIncluded = $true;  note = 'kernel CEIP (existence unverified on 26H2 per r4 - probed, never assumed)' }
        [pscustomobject]@{ taskPath = '\Microsoft\Windows\Autochk\'; taskName = 'Proxy';                                     category = 'app-experience'; defaultIncluded = $true;  note = 'app-experience inventory proxy' }
        [pscustomobject]@{ taskPath = '\Microsoft\Windows\DiskDiagnostic\'; taskName = 'Microsoft-Windows-DiskDiagnosticDataCollector'; category = 'diagnostic-collector'; defaultIncluded = $true; note = 'disk diagnostic data collector' }
        [pscustomobject]@{ taskPath = '\Microsoft\Windows\Feedback\Siuf\'; taskName = 'DmClient';                            category = 'feedback'; defaultIncluded = $true;  note = 'feedback prompt client' }
        [pscustomobject]@{ taskPath = '\Microsoft\Windows\Feedback\Siuf\'; taskName = 'DmClientOnScenarioDownload';          category = 'feedback'; defaultIncluded = $true;  note = 'feedback prompt on scenario download' }
        [pscustomobject]@{ taskPath = '\Microsoft\Windows\Windows Error Reporting\'; taskName = 'QueueReporting';            category = 'error-reporting'; defaultIncluded = $false; note = 'queues crash reports for upload - opt-in only (-IncludeErrorReportingQueue), reduces troubleshooting data' }
    )
}

function Invoke-Nx13TaskStateChange {
    <#
        Verified task enable/disable. Mechanism reuse (not duplication): when the
        NX11-006 engine is loaded (Set-Nx11TaskEnabled from src/nxcore/functions/
        NX11.ps1), its r1-verified 3-fallback changer (cmdlet -> schtasks -> Task
        Scheduler COM, each re-read) is used. Only when that engine is not loaded
        does this helper fall back to the single documented cmdlet so NX13-013 can
        still run standalone. The allow-list, XML backup, journaling and rollback
        stay owned by NX13-013 either way.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $escape = { param($s) [System.Management.Automation.WildcardPattern]::Escape($s) }
    $nx11 = Get-Command -Name 'Set-Nx11TaskEnabled' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $nx11) {
        try {
            $r = Set-Nx11TaskEnabled -TaskPath $TaskPath -TaskName $TaskName -Enabled $Enabled
            if ($null -ne $r) {
                return [pscustomobject]@{ success = [bool]$r.success; mechanism = $r.mechanism; attempts = @($r.attempts); state = $r.state; via = 'NX11-006 Set-Nx11TaskEnabled (3-fallback)' }
            }
        } catch { }
    }
    $mech = 'Disable-ScheduledTask'
    if ($Enabled) { $mech = 'Enable-ScheduledTask' }
    try {
        if ($Enabled) { Enable-ScheduledTask -TaskPath (& $escape $TaskPath) -TaskName (& $escape $TaskName) -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskPath (& $escape $TaskPath) -TaskName (& $escape $TaskName) -ErrorAction Stop | Out-Null }
        $t = Get-ScheduledTask -TaskPath (& $escape $TaskPath) -TaskName (& $escape $TaskName) -ErrorAction Stop
        $ok = $false
        if ($null -ne $t) {
            if ($Enabled) { $ok = ([string]$t.State -ne 'Disabled') } else { $ok = ([string]$t.State -eq 'Disabled') }
        }
        return [pscustomobject]@{ success = $ok; mechanism = $mech; attempts = @(); state = $(if ($null -ne $t) { [string]$t.State } else { $null }); via = 'cmdlet fallback' }
    } catch {
        return [pscustomobject]@{ success = $false; mechanism = $mech; attempts = @([string]$_.Exception.Message); state = $null; via = 'cmdlet fallback' }
    }
}

function Set-NxTelemetryTasks {
    <#
    .SYNOPSIS
        NX13-013: disable the allow-listed telemetry tasks, one journaled task at a time.
    .DESCRIPTION
        Per task, in order:
          1. probe with Get-ScheduledTask (missing -> journaled skip, result Missing);
          2. already Disabled -> journaled skip (AlreadyApplied);
          3. export the task XML under <JournalRoot>\task-exports (original-state
             artifact) - if the export fails the task is NOT mutated (no mutation
             without verified prior state);
          4. journal 'apply' (original state + xml path) -> Disable-ScheduledTask ->
             re-read state -> journal 'verify'.
        -Tasks filters by task name (or 'path\name'); it can never add a task outside
        the allow-list. Services are never touched.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string[]]$Tasks = @(),
        [switch]$IncludeErrorReportingQueue,
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakId = 'NX13-013',
        [string]$TweakVersion = '1'
    )
    if (-not $Approved -and -not $WhatIfPreference) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    $getCmd  = Get-Command -Name 'Get-ScheduledTask'  -ErrorAction SilentlyContinue
    $disCmd  = Get-Command -Name 'Disable-ScheduledTask' -ErrorAction SilentlyContinue
    $expCmd  = Get-Command -Name 'Export-ScheduledTask' -ErrorAction SilentlyContinue
    if ($null -eq $getCmd -or $null -eq $disCmd) {
        throw "$TweakId : the ScheduledTasks module (Get-ScheduledTask/Disable-ScheduledTask) is unavailable in this host - requires Windows PowerShell 5.1"
    }

    $allow = Get-Nx13TelemetryTaskAllowList
    $selected = New-Object System.Collections.Generic.List[object]
    $preResults = New-Object System.Collections.Generic.List[object]
    $requested = @($Tasks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $matchedRequests = @{}
    foreach ($a in $allow) {
        $isDefaultIncluded = [bool]$a.defaultIncluded
        if ([string]$a.category -eq 'error-reporting') { $isDefaultIncluded = $IncludeErrorReportingQueue.IsPresent }
        if (-not $isDefaultIncluded -and $requested.Count -eq 0) { continue }
        if ($requested.Count -gt 0) {
            $full = $a.taskPath + $a.taskName
            $match = $false
            foreach ($t in $requested) {
                if ($t -eq $a.taskName -or $t -eq $full -or $t -eq $a.taskPath) { $match = $true; $matchedRequests[$t] = $true; break }
            }
            if (-not $match) { continue }
            if ([string]$a.category -eq 'error-reporting' -and -not $IncludeErrorReportingQueue) {
                # explicit -Tasks selection of QueueReporting still needs the documented opt-in:
                # report it, never apply it silently or skip it silently.
                $preResults.Add([pscustomobject]@{ task = $full; category = $a.category; outcome = 'OptInRequired'; state = $null; reason = 'error-reporting tasks require -IncludeErrorReportingQueue (crash-report upload stops)' })
                continue
            }
        }
        $selected.Add($a)
    }
    foreach ($t in $requested) {
        if ($matchedRequests.ContainsKey($t)) { continue }
        $preResults.Add([pscustomobject]@{ task = $t; category = 'unknown'; outcome = 'NotAllowListed'; state = $null; reason = 'requested task is not on the NX13-013 telemetry allow-list - refused (no blanket sweeps)' })
    }
    if ($selected.Count -eq 0) {
        return [pscustomobject]@{
            tweakId = $TweakId; results = $preResults.ToArray(); applied = 0; skipped = 0; missing = 0; failed = 0; allVerified = ($preResults.Count -eq 0)
            note = $(if ($preResults.Count -gt 0) { 'no allow-listed task was selected for mutation; refusals/opt-ins are reported above' } else { 'no allow-listed task selected' })
        }
    }

    $exportDir = Join-Path $JournalRoot 'task-exports'
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($r in $preResults) { $results.Add($r) }

    foreach ($a in $selected) {
        $full = $a.taskPath + $a.taskName
        $escape = { param($s) [System.Management.Automation.WildcardPattern]::Escape($s) }

        $task = $null
        try { $task = Get-ScheduledTask -TaskPath (& $escape $a.taskPath) -TaskName (& $escape $a.taskName) -ErrorAction Stop } catch { $task = $null }
        $stateBefore = $null
        if ($null -ne $task) { $stateBefore = [string]$task.State }

        # WhatIf/Confirm is evaluated BEFORE any journal write: a plan must leave no trace.
        if (-not $PSCmdlet.ShouldProcess($full, 'Disable telemetry task (original state journaled)')) {
            $results.Add([pscustomobject]@{ task = $full; category = $a.category; outcome = 'WhatIf'; state = $stateBefore; reason = 'no mutation, no journal write' })
            continue
        }

        if ($null -eq $task) {
            $descriptor = [pscustomobject]@{ targetType = 'task'; taskPath = $a.taskPath; taskName = $a.taskName; existed = $false; state = $null; xmlPath = $null; category = $a.category }
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $descriptor -Modified $descriptor -Result 'TaskMissing' -Verification 'NotRun' -ErrorInfo 'task not present on this build - nothing to capture or change' -Profiles $Profiles
            $results.Add([pscustomobject]@{ task = $full; category = $a.category; outcome = 'Missing'; state = $null; reason = 'task not present on this build' })
            continue
        }
        if ($stateBefore -eq 'Disabled') {
            $descriptor = [pscustomobject]@{ targetType = 'task'; taskPath = $a.taskPath; taskName = $a.taskName; existed = $true; state = $stateBefore; xmlPath = $null; category = $a.category }
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $descriptor -Modified $descriptor -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
            $results.Add([pscustomobject]@{ task = $full; category = $a.category; outcome = 'AlreadyDisabled'; state = $stateBefore; reason = 'already disabled on this machine' })
            continue
        }

        # Original-state artifact: task XML, exported BEFORE the state changes.
        $xmlPath = $null
        $exportOk = $false
        if ($null -ne $expCmd) {
            try {
                if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }
                $safe = (($a.taskPath + $a.taskName) -replace '[^A-Za-z0-9\.\-_]', '_')
                $xmlPath = Join-Path $exportDir ('task-' + $safe + '.xml')
                $xml = Export-ScheduledTask -TaskPath (& $escape $a.taskPath) -TaskName (& $escape $a.taskName) -ErrorAction Stop
                if ($null -ne $xml -and ([string]$xml).TrimStart().StartsWith('<?xml')) {
                    Set-Content -LiteralPath $xmlPath -Value $xml -Encoding Unicode
                    $exportOk = $true
                } else { $xmlPath = $null }
            } catch { $xmlPath = $null; $exportOk = $false }
        }
        if (-not $exportOk) {
            $descriptor = [pscustomobject]@{ targetType = 'task'; taskPath = $a.taskPath; taskName = $a.taskName; existed = $true; state = $stateBefore; xmlPath = $null; category = $a.category }
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $descriptor -Modified $descriptor -Result 'Failed-CaptureIncomplete' -Verification 'NotRun' -ErrorInfo 'task XML export failed - refusing to change task state without a prior-state artifact' -Profiles $Profiles
            $results.Add([pscustomobject]@{ task = $full; category = $a.category; outcome = 'Failed'; state = $stateBefore; reason = 'XML export failed; task left untouched (no mutation without prior state)' })
            continue
        }

        $orig = [pscustomobject]@{ targetType = 'task'; taskPath = $a.taskPath; taskName = $a.taskName; existed = $true; state = $stateBefore; xmlPath = $xmlPath; category = $a.category }
        $mod  = [pscustomobject]@{ targetType = 'task'; taskPath = $a.taskPath; taskName = $a.taskName; state = 'Disabled' }
        $apply = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $orig -Modified $mod -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
        try {
            $change = Invoke-Nx13TaskStateChange -TaskPath $a.taskPath -TaskName $a.taskName -Enabled $false
            $disabled = [bool]$change.success
            $res = if ($disabled) { 'Success' } else { 'FailedVerification' }
            $detail = "mechanism=$($change.mechanism) via=$($change.via) state=$($change.state)"
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $orig -Modified $mod -Result $res -Verification $(if ($disabled) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $detail -Profiles $Profiles
            if (-not $disabled) {
                # Safe stop: try to put the task back the way we found it.
                $null = Invoke-Nx13TaskStateChange -TaskPath $a.taskPath -TaskName $a.taskName -Enabled $true
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $mod -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo ("task state was not Disabled after apply; re-enable attempted ($detail)") -Profiles $Profiles
                $results.Add([pscustomobject]@{ task = $full; category = $a.category; outcome = 'Failed'; state = [string]$change.state; reason = "state did not read back Disabled ($detail); task re-enable attempted" })
            } else {
                $results.Add([pscustomobject]@{ task = $full; category = $a.category; outcome = 'Disabled'; state = 'Disabled'; reason = "seq $($apply.seq) exported to $xmlPath ($detail)" })
            }
        } catch {
            $err = [string]$_.Exception.Message
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles
            $results.Add([pscustomobject]@{ task = $full; category = $a.category; outcome = 'Failed'; state = $stateBefore; reason = "disable failed: $err" })
        }
    }

    $applied = @($results | Where-Object { $_.outcome -eq 'Disabled' }).Count
    $skipped = @($results | Where-Object { $_.outcome -eq 'AlreadyDisabled' }).Count
    $missing = @($results | Where-Object { $_.outcome -eq 'Missing' }).Count
    $failed  = @($results | Where-Object { $_.outcome -eq 'Failed' }).Count
    $refused = @($results | Where-Object { $_.outcome -eq 'NotAllowListed' }).Count
    $optIn   = @($results | Where-Object { $_.outcome -eq 'OptInRequired' }).Count
    return [pscustomobject]@{
        tweakId    = $TweakId
        results    = $results.ToArray()
        applied    = $applied
        skipped    = $skipped
        missing    = $missing
        failed     = $failed
        refused    = $refused
        optInRequired = $optIn
        allVerified = ($failed -eq 0)
        exportDir  = $exportDir
        notes      = @(
            'Allow-list only: Windows Update, UpdateOrchestrator, maintenance/defrag tasks are never touched (blanket sweeps are on the rejected list).',
            'Missing tasks are reported honestly - reference task sets disagree by build.',
            'Services (including DiagTrack/WerSvc) are never reconfigured by this entry.'
        )
    }
}

function Invoke-Nx13Rollback {
    <#
    .SYNOPSIS
        NX13 delegated rollback: restores 'task' targets journaled by NX13-013.
    .DESCRIPTION
        Called by the core engine (Invoke-NxRollback) for target types the registry
        engine does not cover. Same semantics as the core engine: integrity-gated,
        reverse order, only-if-ours, every step journaled and verified.
        only-if-ours for a task = the live state must still be 'Disabled' (what we
        recorded writing). A task the user re-enabled afterwards is reported as
        diverged and left untouched. A task that no longer exists is reported, never
        recreated (the exported XML is the manual restore artifact).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId
    )
    $journal = Read-NxJournal -Path $JournalRoot
    if ($journal.integrityErrors.Count -gt 0) {
        return [pscustomobject]@{ aborted = $true; integrityErrors = $journal.integrityErrors; restored = @(); diverged = @(); failed = @() }
    }
    $candidates = @($journal.entries | Where-Object {
        $_.operation -eq 'apply' -and
        ($_.result -eq 'InProgress' -or $_.result -eq 'Success') -and
        [string]$_.original.targetType -eq 'task' -and
        $_.tweakId -like 'NX13-*'
    })
    if (-not [string]::IsNullOrWhiteSpace($TweakId)) { $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId }) }
    [array]::Reverse($candidates)

    $restored = New-Object System.Collections.Generic.List[object]
    $diverged = New-Object System.Collections.Generic.List[object]
    $failed   = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $getCmd = Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue
    if ($null -eq $getCmd) {
        return [pscustomobject]@{ aborted = $true; integrityErrors = @('ScheduledTasks module unavailable in this host'); restored = @(); diverged = @(); failed = @() }
    }

    foreach ($e in $candidates) {
        $orig = $e.original; $mod = $e.modified
        $key = ([string]$orig.taskPath + '|' + [string]$orig.taskName).ToLower()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $escape = { param($s) [System.Management.Automation.WildcardPattern]::Escape($s) }
        $live = $null
        try { $live = Get-ScheduledTask -TaskPath (& $escape $orig.taskPath) -TaskName (& $escape $orig.taskName) -ErrorAction Stop } catch { $live = $null }

        if ($null -eq $live) {
            $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = ($orig.taskPath + $orig.taskName); reason = 'task no longer exists - not recreated; exported XML is the manual restore artifact' })
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'task missing at rollback time' -Profiles @($e.profiles)
            continue
        }
        if ([string]$live.State -ne 'Disabled') {
            $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = ($orig.taskPath + $orig.taskName); reason = "live state '$($live.State)' is not the NEXTRIX-recorded 'Disabled' - left untouched for user decision" })
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: task state differs from recorded modified state' -Profiles @($e.profiles)
            continue
        }
        if ([string]$orig.state -eq 'Disabled') {
            # Never made a change (defensive: skip entries are not candidates, but stay safe).
            $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'no change needed'; detail = ($orig.taskPath + $orig.taskName); verified = $true })
            continue
        }
        try {
            $change = Invoke-Nx13TaskStateChange -TaskPath $orig.taskPath -TaskName $orig.taskName -Enabled $true
            $after = Get-ScheduledTask -TaskPath (& $escape $orig.taskPath) -TaskName (& $escape $orig.taskName) -ErrorAction Stop
            $verified = ($null -ne $after -and [string]$after.State -ne 'Disabled')
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles)
            if ($verified) {
                $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 're-enabled task'; detail = ($orig.taskPath + $orig.taskName); verified = $true })
            } else {
                $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = "task state '$([string]$after.State)' after re-enable (mechanism=$($change.mechanism))" })
            }
        } catch {
            $err = [string]$_.Exception.Message
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'failed' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles @($e.profiles)
            $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = "re-enable failed: $err" })
        }
    }
    return [pscustomobject]@{ aborted = $false; integrityErrors = @(); restored = $restored.ToArray(); diverged = $diverged.ToArray(); failed = $failed.ToArray() }
}

# ============================================================================
# NX13-014 - read-only privacy posture / permission audit report (P8 feed)
# ============================================================================

function Get-NxPrivacyAuditReport {
    <#
    .SYNOPSIS
        NX13-014: read-only privacy posture report.
    .DESCRIPTION
        Reports what is configured, never what would be "better", and never changes
        anything (no journal writes). Every value that cannot be read is listed in
        uncertainty[] with the reason (missing key, wrong kind, cmdlet unavailable).
        Stable shape for the P8 Profile-Focused feed:
          findings[]      : area, target, state, meaning
          appPermissions[]: per-capability policy + consent-store summary
          diagnosticData  : level, edition floor, limits
          tasks[]         : telemetry allow-list state
          uncertainty[]   : explicit gaps
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(0, 500)][int]$MaxAppsPerCapability = 25
    )
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $findings = New-Object System.Collections.Generic.List[object]

    $addFinding = {
        param($area, $target, $state, $meaning)
        $findings.Add([pscustomobject]@{ area = $area; target = $target; state = $state; meaning = $meaning })
    }

    # --- edition / diagnostic data ------------------------------------------
    $build = $null
    try { $build = Get-NxBuildReport } catch { $build = $null }
    $editionId = $null; $productName = $null; $buildNo = $null
    if ($null -ne $build -and $build.readSucceeded) {
        $editionId = [string]$build.editionId
        $productName = [string]$build.productName
        $buildNo = [int]$build.build
    } else {
        $uncertainty.Add('build/edition report unavailable (CurrentVersion read failed)')
    }
    $floor = Get-Nx13DiagnosticDataFloor -EditionId $editionId -ProductName $productName
    foreach ($u in @($floor.uncertainty)) { $uncertainty.Add($u) }

    $dcPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
    $telemetry = Capture-NxRegistryValue -Path $dcPath -Name 'AllowTelemetry'
    $dumpLimit = Capture-NxRegistryValue -Path $dcPath -Name 'LimitDumpCollection'
    $logLimit  = Capture-NxRegistryValue -Path $dcPath -Name 'LimitDiagnosticLogCollection'
    $telemetryState = if ($telemetry.existed) { "$($telemetry.value) ($($telemetry.kind))" } else { 'absent (Windows default: required data, optional opt-in allowed)' }
    & $addFinding 'diagnostic-data' 'AllowTelemetry' $telemetryState 'documented diagnostic-data level policy'
    # Placebo honesty: on an edition whose documented floor is 1, a stored 0 is
    # documented by Microsoft as equivalent to 1 - report the EFFECTIVE level too
    # so the owner is never misled by the stored number.
    $placeboStored = $false
    if ($telemetry.existed -and [string]$telemetry.kind -eq 'DWord' -and [int]$telemetry.value -eq 0 -and [int]$floor.floor -eq 1) {
        $placeboStored = $true
        & $addFinding 'diagnostic-data' 'AllowTelemetry (effective level)' ([string]$floor.floor + ' (documented)') 'stored 0 on this edition is documented as equivalent to 1 - the effective level is 1, not 0'
        $uncertainty.Add('AllowTelemetry is stored as 0 on an edition where Microsoft documents 0 as equivalent to 1 (placebo) - effective level reported as 1')
    }
    & $addFinding 'diagnostic-data' 'LimitDumpCollection' $(if ($dumpLimit.existed) { [string]$dumpLimit.value } else { 'absent' }) 'documented dump-collection limit'
    & $addFinding 'diagnostic-data' 'LimitDiagnosticLogCollection' $(if ($logLimit.existed) { [string]$logLimit.value } else { 'absent' }) 'documented diagnostic-log limit'

    # --- app permissions ----------------------------------------------------
    $appPermissions = (Get-NxAppPermissionState -MaxAppsPerCapability $MaxAppsPerCapability)
    foreach ($u in @($appPermissions.uncertainty)) { $uncertainty.Add($u) }
    foreach ($row in @($appPermissions.permissions)) {
        & $addFinding 'app-permission' $row.policyValue $row.policyState ("current-user consent: " + $(if ($null -eq $row.consentValue) { 'unknown' } else { $row.consentValue }) + "; apps allow=$($row.appsAllow) deny=$($row.appsDeny) of $($row.appsTotal)")
    }

    # --- the switches this category manages ---------------------------------
    $switchMap = @(
        @{ area = 'advertising'; target = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo :: Enabled'; meaning = 'advertising ID off when 0' },
        @{ area = 'advertising'; target = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo :: DisabledByGroupPolicy'; meaning = 'documented advertising-ID policy' },
        @{ area = 'activity-history'; target = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System :: EnableActivityFeed'; meaning = 'activity feed disabled when 0' },
        @{ area = 'activity-history'; target = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System :: PublishUserActivities'; meaning = 'user-activity publishing disabled when 0' },
        @{ area = 'activity-history'; target = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System :: UploadUserActivities'; meaning = 'user-activity upload disabled when 0' },
        @{ area = 'tailored-experiences'; target = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent :: DisableTailoredExperiencesWithDiagnosticData'; meaning = 'diagnostic-data personalization disabled when 1' },
        @{ area = 'app-launch-tracking'; target = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer :: NoInstrumentation'; meaning = 'user tracking disabled when 1 (NX15 owns Start_Track*)' },
        @{ area = 'general-toggles'; target = 'HKCU:\Control Panel\International\User Profile :: HttpAcceptLanguageOptOut'; meaning = 'language-list access opted out when 1' },
        @{ area = 'general-toggles'; target = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent :: DisableWindowsSpotlightOnSettings'; meaning = 'Settings suggestions disabled when 1' },
        @{ area = 'feedback'; target = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection :: DoNotShowFeedbackNotifications'; meaning = 'feedback prompts disabled when 1' },
        @{ area = 'feedback'; target = 'HKCU:\Software\Microsoft\Siuf\Rules :: PeriodInNanoSeconds'; meaning = 'documented feedback-frequency period (0 = never)' },
        @{ area = 'feedback'; target = 'HKCU:\Software\Microsoft\Siuf\Rules :: NumberOfSIUFInPeriod'; meaning = 'documented feedback prompts per period (0 = never)' },
        @{ area = 'inking-typing'; target = 'HKCU:\Software\Microsoft\InputPersonalization :: RestrictImplicitTextCollection'; meaning = 'typing data collection restricted when 1' },
        @{ area = 'inking-typing'; target = 'HKCU:\Software\Microsoft\InputPersonalization :: RestrictImplicitInkCollection'; meaning = 'inking data collection restricted when 1' },
        @{ area = 'cloud-search'; target = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search :: AllowCloudSearch'; meaning = 'cloud content search disabled when 0' },
        @{ area = 'cloud-search'; target = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search :: ConnectedSearchUseWeb'; meaning = 'web results disabled when 0' },
        @{ area = 'clipboard'; target = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System :: AllowClipboardHistory'; meaning = 'clipboard history disabled when 0' },
        @{ area = 'clipboard'; target = 'HKCU:\Software\Microsoft\Clipboard :: EnableClipboardHistory'; meaning = 'per-user clipboard history toggle' },
        @{ area = 'cross-device'; target = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System :: EnableMmx'; meaning = 'phone-PC linking disabled when 0' },
        @{ area = 'cross-device'; target = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System :: AllowCrossDeviceClipboard'; meaning = 'cross-device clipboard sync disabled when 0' }
    )
    foreach ($s in $switchMap) {
        $parts = $s.target -split ' :: '
        $cap = Capture-NxRegistryValue -Path $parts[0] -Name $parts[1]
        $state = 'absent'
        if ($cap.existed) { $state = "$($cap.value) ($($cap.kind))" }
        & $addFinding $s.area $s.target $state $s.meaning
    }

    # --- telemetry tasks (read-only) ---------------------------------------
    $taskRows = New-Object System.Collections.Generic.List[object]
    $getCmd = Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue
    if ($null -eq $getCmd) {
        $uncertainty.Add('Get-ScheduledTask unavailable - telemetry task state not reported')
    } else {
        foreach ($a in (Get-Nx13TelemetryTaskAllowList)) {
            $t = $null
            try { $t = Get-ScheduledTask -TaskPath ([System.Management.Automation.WildcardPattern]::Escape($a.taskPath)) -TaskName ([System.Management.Automation.WildcardPattern]::Escape($a.taskName)) -ErrorAction Stop } catch { $t = $null }
            $state = if ($null -eq $t) { 'Missing' } else { [string]$t.State }
            $taskRows.Add([pscustomobject]@{ task = ($a.taskPath + $a.taskName); category = $a.category; state = $state; defaultIncluded = [bool]$a.defaultIncluded })
        }
    }

    return [pscustomobject]@{
        readOnly        = $true
        generatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        edition         = [pscustomobject]@{ editionId = $editionId; productName = $productName; build = $buildNo; diagnosticFloor = $floor.floor; family = $floor.family; floorDocumented = $floor.floorDocumented; explanation = $floor.explanation }
        findings        = $findings.ToArray()
        appPermissions  = $appPermissions.permissions
        diagnosticData  = [pscustomobject]@{ allowTelemetry = $telemetry; limitDumpCollection = $dumpLimit; limitDiagnosticLogCollection = $logLimit; editionFloor = $floor.floor; placeboStored = $placeboStored }
        tasks           = $taskRows.ToArray()
        uncertainty     = $uncertainty.ToArray()
        note            = 'Privacy posture only - configuration state; no speed claim is made. Feeds the P8 Privacy-Focused profile.'
    }
}
