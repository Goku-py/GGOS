#Requires -Version 5.1
<#
    NX14.ps1 - NEXTRIX Security Configuration category functions
    (entries NX14-001..NX14-015).

    Companion to registry/NX14.json (single source of truth for the category).

    POLICY (directive Section 15; SECURITY_POLICY.md Section 1):
      Security protections stay ON by default. This file never disables
      Defender, Firewall, UAC, SmartScreen, Secure Boot, TPM, VBS/Memory
      Integrity, Credential Guard, BitLocker, mitigation masks or the
      vulnerable-driver blocklist. Every mutating function is limited to a
      documented, security-neutral-or-stronger change; reductions are simply
      not implemented (the reference-ecosystem teardowns in
      docs/RESEARCH_RECONCILIATION.md are the rejected inverse).

    MUTATION SURFACE (declared per SECURITY_POLICY.md Section 4):
      Set-Nx14UacLevel              - three documented UAC values ONLY
                                      (EnableLUA=1, ConsentPromptBehaviorAdmin
                                      1|2|5, PromptOnSecureDesktop=1).
      Set-Nx14SmartScreen           - documented Shell SmartScreen policy ONLY
                                      (EnableSmartScreen=1, level Warn|Block).
      Set-Nx14MemoryIntegrity       - HVCI Enabled=1 ONLY (never 0), with
                                      ExplicitConsent + driver-review gate.
      Set-Nx14ControlledFolderAccess- CFA mode 1|2 and per-app allow-list
                                      (never mode 0) via documented Defender
                                      preference cmdlets.
      Set-Nx14MitigationPolicy      - per-process mitigation ENABLE only via
                                      the documented Set-ProcessMitigation.
      Set-Nx14WindowsSandbox        - Containers-DisposableClientVM feature.
      Set-Nx14VirtualizationPlatform- HyperV / VirtualMachinePlatform /
                                      HypervisorPlatform optional feature.
      Nothing else. No service, no scheduled task, no BCD, no firewall rule,
      no Defender exclusion, no credential material.

    BANNED-TARGET GUARD: every registry write passes
      Test-Nx14BannedRegistryTarget (a code-level mirror of
      registry/schema.json bannedRegistryTargets + hardControlSetWrites), so a
      banned write fails at runtime even if a future edit bypasses the static
      validator. This is deliberate defence in depth, not duplication.

    DEFAULT APPLY ACTIONS: NX14-008's apply action is the consent-gated enable
      itself (ExplicitConsent + -DriverCompatibilityReviewed, hard-refused on
      detected blockers). NX14-011 (mitigation report) and NX14-014
      (virtualization/dependency report) default to their read-only report: their
      mutating functions require owner-supplied specifics (per-process mitigation
      names, component+direction) and are never invoked by a preset.
      NX14-003/004/010/013 apply their documented, security-neutral-or-stronger
      change directly (pinned by the registry).

    CONTRACT (same as every mutating category function):
      Capture exact original state -> journal-first -> mutate -> verify ->
      journal. Already-correct targets journal a 'skip' (AlreadyApplied) and
      are never rewritten. A verification failure restores the exact recorded
      original (safe stop) and journals 'failed'. Mutating functions refuse to
      run without -Approved; -WhatIf plans without any journal write or
      mutation. Every unreadable value becomes an explicit uncertainty entry -
      never a guessed boolean.

    READ-ONLY functions (no journal, no mutation):
      Get-Nx14DefenderStatusReport, Get-Nx14FirewallStatusReport,
      Get-Nx14SecureBootStatus, Get-Nx14TpmStatus, Get-Nx14DeviceGuardStatus,
      Get-Nx14CredentialGuardStatus, Get-Nx14BitLockerStatus,
      Get-Nx14SecurityHealthReport, plus the state helpers
      Get-Nx14UacStatus, Get-Nx14SmartScreenStatus,
      Get-Nx14ControlledFolderAccessStatus, Get-Nx14MemoryIntegrityStatus,
      Get-Nx14ExploitProtectionReport, Get-Nx14WindowsSandboxStatus,
      Get-Nx14VirtualizationPlatformStatus.

    Dependencies (dot-source AFTER the core modules, Import-NxCore order):
      NxJournal.ps1  -> Capture-NxRegistryValue, Add-NxJournalEntry,
                        Read-NxJournal
      NxVerify.ps1   -> Test-NxConfigurationState
      NxApply.ps1    -> Set-NxRegistryValue
      NxRollback.ps1 -> Restore-NxRegistryOriginal (safe-stop restore)
      NxBuild.ps1    -> Get-NxBuildReport (edition id, optional/reused)
      NX01.ps1       -> Set-NxOptionalFeatureState (reused when loaded; the
                        local fallback uses the same documented pipeline)
    Loading this file defines functions only: no registry/CIM/event-log reads
    and no writes happen at load time.

    ROLLBACK: registry targets are handled by the core engine (each write is a
    targetType='registry' journal entry). Invoke-Nx14Rollback (called by the
    core engine) covers the target types the registry engine does not:
    'defenderPreference' (NX14-010), 'optionalFeature' (NX14-013/014),
    'feature' (NX14-013/014 when the NX01 engine journaled the change) and
    'processMitigation' (NX14-011). Same semantics as the core engine:
    integrity-gated, reverse order, only-if-ours, every step journaled and
    verified.

    PRIVACY / LOG HYGIENE: no credential material, no BitLocker key IDs or
    recovery passwords, no Defender exclusion paths, no LSA secrets and no
    machine identifiers are emitted. Defender exclusions are reported as counts
    only; BitLocker protectors as types only; CFA allowed-app paths are
    configuration state required for exact restore (not secrets).
#>

# ============================================================================
# Constants
# ============================================================================

$script:Nx14UacKey                  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$script:Nx14SmartScreenPolicyKey    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
$script:Nx14SmartScreenLegacyKey    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
$script:Nx14DeviceGuardPolicyKey    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard'
$script:Nx14DeviceGuardRootKey      = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
$script:Nx14HvciKey                 = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
$script:Nx14SecureBootStateKey      = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'
$script:Nx14DeviceGuardNamespace    = 'root\Microsoft\Windows\DeviceGuard'
$script:Nx14SecurityCenterNamespace = 'root\SecurityCenter2'
$script:Nx14IfeoKey                 = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$script:Nx14SandboxFeature          = 'Containers-DisposableClientVM'

$script:Nx14SecurityServiceNames = @{
    1 = 'Credential Guard'
    2 = 'Hypervisor-enforced Code Integrity'
    3 = 'System Guard Secure Launch'
    4 = 'SMM Firmware Measurement'
}

$script:Nx14SecurityPropertyNames = @{
    1 = 'Hypervisor-based security support'
    2 = 'Secure Boot'
    3 = 'DMA protection'
    4 = 'Secure Memory Overwrite'
    5 = 'NX/XD protections'
    6 = 'SMM Security Mitigations 1.0'
    7 = 'Mode-based execution control'
    8 = 'APIC virtualization'
}

# ============================================================================
# Small read-only helpers (no journal, no mutation)
# ============================================================================

function Get-Nx14PropertyValue {
    <# Safe property reader: a missing property and a $null property both yield
       $null, and no attempt is made to invoke a method on a null object. #>
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function ConvertTo-Nx14BoolState {
    <# Normalises the several shapes a Windows boolean can take in PS 5.1
       (GpoBoolean enum 0/1, True/False, 'Enabled'/'Disabled'). Returns $null
       for anything unrecognised so callers report uncertainty instead of a
       guess. #>
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ($s -in @('1','True','Enabled','On')) { return $true }
    if ($s -in @('0','False','Disabled','Off')) { return $false }
    return $null
}

function Test-Nx14IsElevated {
    <# Read-only token check. Used to explain access-denied results honestly. #>
    [CmdletBinding()]
    param()
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $null
    }
}

function Get-Nx14RegistryText {
    <# Human-readable state of one registry value; never guesses a default. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $cap = Capture-NxRegistryValue -Path $Path -Name $Name
    if (-not $cap.existed) {
        return [pscustomobject]@{ text = 'absent'; existed = $false; kind = $null; value = $null }
    }
    return [pscustomobject]@{ text = ("{0} ({1})" -f [string]$cap.value, [string]$cap.kind); existed = $true; kind = [string]$cap.kind; value = $cap.value }
}

function Get-Nx14NestedValue {
    <# Reads a dotted property path (e.g. 'Cfg.Enable') from a cmdlet object. #>
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)][string]$Path)
    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        $prop = $current.PSObject.Properties[$segment]
        if ($null -eq $prop) { return $null }
        $current = $prop.Value
    }
    return $current
}

function Get-Nx14EditionId {
    <# Reuses the NxBuild edition report when loaded, else reads CurrentVersion
       read-only. Returns $null when neither source works (never a guess). #>
    [CmdletBinding()]
    param()
    $cmd = Get-Command -Name 'Get-NxBuildReport' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        try {
            $build = Get-NxBuildReport
            if ($null -ne $build -and $build.readSucceeded -and -not [string]::IsNullOrWhiteSpace([string]$build.editionId)) {
                return [string]$build.editionId
            }
        } catch { }
    }
    $cap = Capture-NxRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID'
    if ($cap.existed) { return [string]$cap.value }
    return $null
}

function Get-Nx14AvProducts {
    <# Registered antivirus/firewall products from SecurityCenter2. Names and
       raw ProductState only: Microsoft does not publish an official decoding
       table, so the value is never decoded or asserted. #>
    [CmdletBinding()]
    param([ValidateSet('AntiVirusProduct','FirewallProduct')][string]$ClassName = 'AntiVirusProduct')
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $items = @(Get-CimInstance -Namespace $script:Nx14SecurityCenterNamespace -ClassName $ClassName -ErrorAction Stop)
        foreach ($item in $items) {
            $rows.Add([pscustomobject]@{
                displayName  = [string](Get-Nx14PropertyValue -Object $item -Name 'displayName')
                productState = [string](Get-Nx14PropertyValue -Object $item -Name 'productState')
                stateDecoded = $null
            })
        }
        return [pscustomobject]@{ supported = $true; products = $rows.ToArray(); reason = $null; uncertainty = @() }
    } catch {
        return [pscustomobject]@{
            supported = $false; products = @(); reason = [string]$_.Exception.Message
            uncertainty = @("root\SecurityCenter2 $ClassName unavailable ($($_.Exception.Message)) - third-party registration cannot be reported")
        }
    }
}

# ============================================================================
# Banned-target guard (code-level mirror of registry/schema.json)
# ============================================================================

function Test-Nx14BannedRegistryTarget {
    <#
    .SYNOPSIS
        Returns whether a registry write is on the NEXTRIX banned list.
    .DESCRIPTION
        Mirrors registry/schema.json bannedRegistryTargets plus
        hardControlSetWrites. Invoke-Nx14RegistryTarget throws on a banned
        target BEFORE the journal write, so NX14 cannot write:
          - EnableLUA=0 (UAC off)
          - VulnerableDriverBlocklistEnable=0
          - SaveZoneInformation=1 (MOTW off)
          - Explorer SmartScreenEnabled='Off'
          - HVCI Enabled=0 (any consent - NX14 does not implement HVCI off)
          - PreventDeviceEncryption=1
          - FeatureSettingsOverride / MitigationOptions (any value)
          - any direct ControlSet001/002 path
        This is deliberately stricter than the schema for the HVCI and
        mitigation keys: the schema allows them under ExplicitConsent for other
        categories, while NX14 never writes them at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )
    $result = [pscustomobject]@{ banned = $false; reason = $null }
    $p = ($Path -replace '/', '\')
    if ($p -match 'ControlSet00[12]') {
        $result.banned = $true
        $result.reason = 'direct ControlSet001/002 writes are forbidden - use CurrentControlSet (schema.json hardControlSetWrites)'
        return $result
    }
    $numericZero = $false
    if ($null -ne $Value) {
        $parsed = 0
        if ([int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -eq 0) { $numericZero = $true }
    }

    if ($p -eq $script:Nx14UacKey -and $Name -eq 'EnableLUA' -and $numericZero) {
        $result.banned = $true
        $result.reason = 'EnableLUA=0 disables UAC and is never a NEXTRIX target (schema.json; directive S15)'
        return $result
    }
    if ($Name -eq 'VulnerableDriverBlocklistEnable' -and $p -match 'Control\\CI\\Config$' -and $numericZero) {
        $result.banned = $true
        $result.reason = 'VulnerableDriverBlocklistEnable=0 removes the vulnerable-driver blocklist (r2: breaks THE FINALS; security-relevant)'
        return $result
    }
    if ($Name -eq 'SaveZoneInformation' -and $p -eq 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' -and [string]$Value -eq '1') {
        $result.banned = $true
        $result.reason = 'SaveZoneInformation=1 kills Mark-of-the-Web (r1-r4)'
        return $result
    }
    if ($Name -eq 'SmartScreenEnabled' -and $p -eq $script:Nx14SmartScreenLegacyKey -and [string]$Value -eq 'Off') {
        $result.banned = $true
        $result.reason = "Explorer SmartScreenEnabled='Off' removes SmartScreen and is never a NEXTRIX target (directive S15)"
        return $result
    }
    if ($Name -eq 'Enabled' -and $p -eq $script:Nx14HvciKey -and $numericZero) {
        $result.banned = $true
        $result.reason = 'HVCI Enabled=0 disables Memory Integrity - NX14 never writes this value (schema.json; directive S15)'
        return $result
    }
    if ($Name -eq 'PreventDeviceEncryption' -and $p -match '\\Control\\BitLocker$' -and [string]$Value -eq '1') {
        $result.banned = $true
        $result.reason = 'PreventDeviceEncryption=1 disables automatic device encryption (ReviOS pattern rejected, r2)'
        return $result
    }
    if ($Name -eq 'FeatureSettingsOverride' -and $p -match 'Session Manager\\Memory Management$') {
        $result.banned = $true
        $result.reason = 'mitigation override masks are consent-gated troubleshooting only and are never written by NX14'
        return $result
    }
    if ($Name -eq 'MitigationOptions' -and $p -match 'Session Manager\\kernel$') {
        $result.banned = $true
        $result.reason = 'system-wide mitigation masks are on the banned list (anti-cheat triggers, r2/r4) and are never written by NX14'
        return $result
    }
    return $result
}

# ============================================================================
# Journal-first registry pipeline (one place only)
# ============================================================================

function Invoke-Nx14RegistryTarget {
    <#
        Capture -> banned guard -> (idempotency skip) -> journal 'apply' ->
        write -> verify -> journal result. Returns a per-target result object.
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
    $guard = Test-Nx14BannedRegistryTarget -Path $Path -Name $Name -Value $Value
    if ($guard.banned) {
        throw "$TweakId : refusing banned registry target $Path :: $Name = $Value - $($guard.reason)"
    }
    $target = "$Path :: $Name"
    $orig = Capture-NxRegistryValue -Path $Path -Name $Name
    $modified = [pscustomobject]@{ targetType = 'registry'; path = $Path; name = $Name; kind = $Kind; value = $Value }

    if (-not $PSCmdlet.ShouldProcess($target, "Set $Kind to the intended value")) {
        return [pscustomobject]@{ target = $target; changed = $false; verified = $false; journalSeq = $null; reason = 'WhatIf/Confirm: no mutation, no journal write' }
    }

    # Idempotency: desired state already present -> journal a skip, never rewrite.
    if ($orig.existed -and ([string]$orig.kind -eq $Kind)) {
        $existing = ConvertTo-Json -InputObject $orig.value -Depth 6 -Compress
        $desired = ConvertTo-Json -InputObject $Value -Depth 6 -Compress
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
        try { Restore-NxRegistryOriginal -Entry ([pscustomobject]@{ original = $orig }) | Out-Null } catch { }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles
        return [pscustomobject]@{ target = $target; changed = $false; verified = $false; journalSeq = $applyJournal.seq; reason = "mutation failed: $err" }
    }
}

# ============================================================================
# NX14-001 - Defender status & health report (read-only)
# ============================================================================

function Get-Nx14DefenderStatusReport {
    <#
    .SYNOPSIS
        Read-only Defender status/preference report (no exclusions paths).
    .DESCRIPTION
        Reports the documented Get-MpComputerStatus/Get-MpPreference property
        subset, exclusion/secondary counts (never paths), and registered AV
        products (names + raw state, undecoded). Provider failures, missing
        cmdlets and access-denied are explicit unavailable reasons with
        uncertainty entries - never a claim that Defender is disabled.
    #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $defender = [ordered]@{
        cmdletAvailable = $false
        statusRead      = $false
        preferenceRead  = $false
        availabilityReason = $null
        status          = $null
        preferences     = $null
        exclusionCounts = $null
    }

    $statusCmd = Get-Command -Name 'Get-MpComputerStatus' -ErrorAction SilentlyContinue
    $prefCmd = Get-Command -Name 'Get-MpPreference' -ErrorAction SilentlyContinue
    $defender.cmdletAvailable = ($null -ne $statusCmd)

    if ($null -eq $statusCmd) {
        $defender.availabilityReason = 'Get-MpComputerStatus is not available (Defender module absent or the feature/component is not installed)'
        $uncertainty.Add($defender.availabilityReason)
    } else {
        try {
            $raw = Get-MpComputerStatus -ErrorAction Stop
            $status = [ordered]@{}
            foreach ($p in @(
                'AntivirusEnabled','AntispywareEnabled','RealTimeProtectionEnabled',
                'BehaviorMonitorEnabled','IoavProtectionEnabled','OnAccessProtectionEnabled',
                'AMServiceEnabled','AMRunningMode','IsTamperProtected','TamperProtectionSource',
                'AMEngineVersion','AMProductVersion','AntivirusSignatureVersion',
                'AntivirusSignatureLastUpdated','NISEnabled','IsVirtualMachine',
                'QuickScanAge','FullScanAge'
            )) {
                $status[$p] = Get-Nx14PropertyValue -Object $raw -Name $p
            }
            $defender.status = [pscustomobject]$status
            $defender.statusRead = $true
        } catch {
            $defender.availabilityReason = "Get-MpComputerStatus failed: $($_.Exception.Message)"
            $uncertainty.Add("Defender status could not be read ($($_.Exception.Message)) - this is an availability failure, not evidence that Defender is disabled")
        }
    }

    if ($null -eq $prefCmd) {
        if ($null -eq $defender.availabilityReason) {
            $defender.availabilityReason = 'Get-MpPreference is not available'
        }
        $uncertainty.Add('Get-MpPreference is unavailable - Defender preference state (PUA, cloud, network protection, CFA) is unreported')
    } else {
        try {
            $prefRaw = Get-MpPreference -ErrorAction Stop
            $prefs = [ordered]@{}
            foreach ($p in @(
                'DisableRealtimeMonitoring','DisableBehaviorMonitoring',
                'DisableIOAVProtection','DisableScriptScanning','PUAProtection',
                'MAPSReporting','SubmitSamplesConsent','CloudBlockLevel',
                'EnableNetworkProtection','EnableControlledFolderAccess'
            )) {
                $prefs[$p] = Get-Nx14PropertyValue -Object $prefRaw -Name $p
            }
            $defender.preferences = [pscustomobject]$prefs
            $defender.preferenceRead = $true
            # Counts only: exclusion paths routinely contain usernames and are
            # not needed for a status verdict (log hygiene).
            $exPaths = Get-Nx14PropertyValue -Object $prefRaw -Name 'ExclusionPath'
            $exExts = Get-Nx14PropertyValue -Object $prefRaw -Name 'ExclusionExtension'
            $exProcs = Get-Nx14PropertyValue -Object $prefRaw -Name 'ExclusionProcess'
            $defender.exclusionCounts = [pscustomobject]@{
                paths      = @($exPaths | Where-Object { $null -ne $_ }).Count
                extensions = @($exExts | Where-Object { $null -ne $_ }).Count
                processes  = @($exProcs | Where-Object { $null -ne $_ }).Count
            }
        } catch {
            $uncertainty.Add("Get-MpPreference failed ($($_.Exception.Message)) - preference state unreported")
        }
    }

    $av = Get-Nx14AvProducts -ClassName 'AntiVirusProduct'
    foreach ($u in @($av.uncertainty)) { $uncertainty.Add($u) }

    return [pscustomobject]@{
        readOnly     = $true
        tweakId      = 'NX14-001'
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        elevation    = [pscustomobject]@{ isElevated = (Test-Nx14IsElevated) }
        defender     = [pscustomobject]$defender
        registeredAv = $av.products
        uncertainty  = $uncertainty.ToArray()
        notes        = @(
            'Configuration state only - no performance claim and no security score is produced.',
            'Exclusion paths, process names and extensions are deliberately not emitted (counts only).',
            'A WMI provider failure is reported as unavailable, never as "Defender is off".'
        )
    }
}

# ============================================================================
# NX14-002 - Firewall status & profile report (read-only)
# ============================================================================

function Get-Nx14FirewallStatusReport {
    <#
    .SYNOPSIS
        Read-only per-profile Windows Defender Firewall report.
    .DESCRIPTION
        Reports enabled/default-action/logging state per profile and derived
        summary flags. No rule change, no service change, no BFE/mpssvc touch.
    #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $rows = New-Object System.Collections.Generic.List[object]
    $read = $false
    $reason = $null

    $cmd = Get-Command -Name 'Get-NetFirewallProfile' -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        $reason = 'Get-NetFirewallProfile is unavailable (NetSecurity module missing)'
        $uncertainty.Add($reason)
    } else {
        try {
            foreach ($p in @(Get-NetFirewallProfile -ErrorAction Stop)) {
                $rows.Add([pscustomobject]@{
                    name                  = [string]$p.Name
                    enabled               = ConvertTo-Nx14BoolState (Get-Nx14PropertyValue -Object $p -Name 'Enabled')
                    enabledRaw            = [string](Get-Nx14PropertyValue -Object $p -Name 'Enabled')
                    defaultInboundAction  = [string](Get-Nx14PropertyValue -Object $p -Name 'DefaultInboundAction')
                    defaultOutboundAction = [string](Get-Nx14PropertyValue -Object $p -Name 'DefaultOutboundAction')
                    allowInboundRules     = ConvertTo-Nx14BoolState (Get-Nx14PropertyValue -Object $p -Name 'AllowInboundRules')
                    allowLocalFirewallRules = ConvertTo-Nx14BoolState (Get-Nx14PropertyValue -Object $p -Name 'AllowLocalFirewallRules')
                    notifyOnListen        = ConvertTo-Nx14BoolState (Get-Nx14PropertyValue -Object $p -Name 'NotifyOnListen')
                    logAllowed            = ConvertTo-Nx14BoolState (Get-Nx14PropertyValue -Object $p -Name 'LogAllowed')
                    logBlocked            = ConvertTo-Nx14BoolState (Get-Nx14PropertyValue -Object $p -Name 'LogBlocked')
                    logFileName           = [string](Get-Nx14PropertyValue -Object $p -Name 'LogFileName')
                })
            }
            $read = $true
        } catch {
            $reason = "Get-NetFirewallProfile failed: $($_.Exception.Message)"
            $uncertainty.Add($reason)
        }
    }

    $known = @($rows | Where-Object { $null -ne $_.enabled })
    $allEnabled = ($known.Count -gt 0 -and @($known | Where-Object { $_.enabled -ne $true }).Count -eq 0)
    $disabledProfiles = @($known | Where-Object { $_.enabled -eq $false } | ForEach-Object { $_.name })

    $fwProducts = Get-Nx14AvProducts -ClassName 'FirewallProduct'
    foreach ($u in @($fwProducts.uncertainty)) { $uncertainty.Add($u) }

    return [pscustomobject]@{
        readOnly          = $true
        tweakId           = 'NX14-002'
        generatedUtc      = (Get-Date).ToUniversalTime().ToString('o')
        firewall          = [pscustomobject]@{ statusRead = $read; reason = $reason }
        profiles          = $rows.ToArray()
        allProfilesEnabled = $allEnabled
        disabledProfiles  = $disabledProfiles
        anyProfileDisabled = ($disabledProfiles.Count -gt 0)
        publicProfileDisabled = (@($known | Where-Object { $_.name -eq 'Public' -and $_.enabled -eq $false }).Count -gt 0)
        registeredFirewallProducts = $fwProducts.products
        uncertainty       = $uncertainty.ToArray()
        notes             = @(
            'Profile metadata only: NEXTRIX has no firewall-rule mutation surface.',
            'Remote Assistance / File-and-Printer-Sharing rule edits (r2) are out of scope and never performed.'
        )
    }
}

# ============================================================================
# NX14-003 helpers - documented UAC levels (never 0 / never insecure desktop)
# ============================================================================

function Get-Nx14UacLevelMap {
    <#
    .SYNOPSIS
        Pure documented UAC level map.
    .DESCRIPTION
        ConsentPromptBehaviorAdmin values from Microsoft's UAC settings
        reference: 1 = prompt for credentials on the secure desktop,
        2 = prompt for consent on the secure desktop, 5 = prompt for consent
        for non-Windows binaries (default). Every level keeps EnableLUA=1 and
        PromptOnSecureDesktop=1. 0 (elevate without prompting), 3/4
        (non-secure-desktop prompts) and PromptOnSecureDesktop=0 are
        structurally absent.
    #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{
            level = 'Default'; enableLua = 1; consentPromptBehaviorAdmin = 5; promptOnSecureDesktop = 1
            description = 'Windows default: prompt for consent when non-Windows binaries request elevation, on the secure desktop.'
        }
        [pscustomobject]@{
            level = 'AlwaysNotify'; enableLua = 1; consentPromptBehaviorAdmin = 2; promptOnSecureDesktop = 1
            description = 'Always notify: prompt for consent on the secure desktop for every elevation request.'
        }
        [pscustomobject]@{
            level = 'CredentialsOnSecureDesktop'; enableLua = 1; consentPromptBehaviorAdmin = 1; promptOnSecureDesktop = 1
            description = 'Prompt for credentials on the secure desktop for administrator elevation (strictest documented prompt).'
        }
    )
}

function Get-Nx14UacStatus {
    <#
    .SYNOPSIS
        Read-only UAC state with the documented level name and findings.
    #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $values = @{}
    foreach ($n in @('EnableLUA','ConsentPromptBehaviorAdmin','PromptOnSecureDesktop')) {
        $values[$n] = Get-Nx14RegistryText -Path $script:Nx14UacKey -Name $n
    }
    $level = 'Unknown'
    $findings = New-Object System.Collections.Generic.List[string]
    $consent = $null
    $lua = $null
    if ($null -ne $values['ConsentPromptBehaviorAdmin'].value) { [void][int]::TryParse([string]$values['ConsentPromptBehaviorAdmin'].value, [ref]$consent) }
    if ($null -ne $values['EnableLUA'].value) { [void][int]::TryParse([string]$values['EnableLUA'].value, [ref]$lua) }

    if ($null -ne $lua -and $lua -eq 0) {
        $level = 'UacDisabled'
        $findings.Add('EnableLUA=0: UAC is disabled for the machine. This is a security finding; NEXTRIX can restore a documented level (security increase) but never sets 0.')
    } elseif ($null -ne $consent) {
        switch ($consent) {
            5 { $level = 'Default' }
            2 { $level = 'AlwaysNotify' }
            1 { $level = 'CredentialsOnSecureDesktop' }
            0 { $level = 'ElevateWithoutPrompting'; $findings.Add('ConsentPromptBehaviorAdmin=0 elevates without prompting (UAC effectively off for administrators).') }
            3 { $level = 'PromptForCredentials'; $findings.Add('ConsentPromptBehaviorAdmin=3 prompts without the secure desktop.') }
            4 { $level = 'PromptForConsent'; $findings.Add('ConsentPromptBehaviorAdmin=4 prompts without the secure desktop.') }
            default { $level = 'Unrecognized'; $uncertainty.Add("ConsentPromptBehaviorAdmin=$consent is outside the documented 0-5 range") }
        }
    } else {
        $uncertainty.Add('ConsentPromptBehaviorAdmin is absent or not numeric - the level cannot be named')
    }
    if ($values['PromptOnSecureDesktop'].existed -and [string]$values['PromptOnSecureDesktop'].value -eq '0') {
        $findings.Add('PromptOnSecureDesktop=0: elevation prompts are not shown on the secure desktop and can be spoofed (documented consequence; Atlas r2 rejects this).')
    }
    if (-not $values['EnableLUA'].existed) {
        $uncertainty.Add('EnableLUA is absent; Windows treats an absent value as the default (UAC enabled).')
    }

    return [pscustomobject]@{
        readOnly            = $true
        level               = $level
        enableLua           = $values['EnableLUA']
        consentPromptBehaviorAdmin = $values['ConsentPromptBehaviorAdmin']
        promptOnSecureDesktop = $values['PromptOnSecureDesktop']
        findings            = $findings.ToArray()
        uncertainty         = $uncertainty.ToArray()
    }
}

# ============================================================================
# NX14-004 helpers - documented SmartScreen policy levels (never Off)
# ============================================================================

function Get-Nx14SmartScreenLevelMap {
    <#
    .SYNOPSIS
        Pure documented SmartScreen policy map (Warn/Block only).
    #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ level = 'Warn'; enableSmartScreen = 1; shellSmartScreenLevel = 'Warn'; description = 'Documented default: warn before running unrecognised downloads/apps.' }
        [pscustomobject]@{ level = 'Block'; enableSmartScreen = 1; shellSmartScreenLevel = 'Block'; description = 'Documented stricter option: block unrecognised downloads/apps instead of warning.' }
    )
}

function Get-Nx14SmartScreenStatus {
    <#
    .SYNOPSIS
        Read-only SmartScreen policy/legacy state.
    #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $enable = Get-Nx14RegistryText -Path $script:Nx14SmartScreenPolicyKey -Name 'EnableSmartScreen'
    $levelValue = Get-Nx14RegistryText -Path $script:Nx14SmartScreenPolicyKey -Name 'ShellSmartScreenLevel'
    $legacy = Get-Nx14RegistryText -Path $script:Nx14SmartScreenLegacyKey -Name 'SmartScreenEnabled'
    $state = 'WindowsDefault'
    $findings = New-Object System.Collections.Generic.List[string]

    if ($enable.existed) {
        $enableInt = $null
        [void][int]::TryParse([string]$enable.value, [ref]$enableInt)
        if ($null -ne $enableInt -and $enableInt -eq 0) {
            $state = 'DisabledByPolicy'
            $findings.Add('EnableSmartScreen=0: SmartScreen is disabled by policy. NEXTRIX reports this finding and can restore the documented policy (security increase), never set 0.')
        } elseif ($null -ne $enableInt -and $enableInt -eq 1) {
            $lvl = [string]$levelValue.value
            if ($lvl -eq 'Block') { $state = 'Block' }
            elseif ($lvl -eq 'Warn') { $state = 'Warn' }
            else {
                $state = 'EnabledLevelUnspecified'
                $uncertainty.Add("EnableSmartScreen=1 with ShellSmartScreenLevel='$lvl' (expected Warn/Block) - the effective prompt strength is not asserted")
            }
        } else {
            $uncertainty.Add("EnableSmartScreen='$($enable.value)' is outside the documented 0/1 range")
        }
    }
    if ($legacy.existed -and [string]$legacy.value -eq 'Off') {
        $findings.Add("Legacy Explorer SmartScreenEnabled='Off' is present. NEXTRIX does not rewrite undocumented UI state values; the documented Shell policy above is the supported mechanism (Windows Security can re-enable the UI switch).")
    }

    return [pscustomobject]@{
        readOnly            = $true
        state               = $state
        enableSmartScreen   = $enable
        shellSmartScreenLevel = $levelValue
        legacyExplorerValue = $legacy
        findings            = $findings.ToArray()
        uncertainty         = $uncertainty.ToArray()
    }
}

# ============================================================================
# NX14-005 - Secure Boot status report (read-only)
# ============================================================================

function Get-Nx14SecureBootStatus {
    <#
    .SYNOPSIS
        Read-only Secure Boot verdict with explicit unsupported handling.
    .DESCRIPTION
        Confirm-SecureBootUEFI is authoritative. On legacy/unsupported
        platforms the cmdlet throws and the report returns
        secureBootEnabled=$null with a reason - never a guessed False. A
        registry cross-check is included only as an E0 observation.
    #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $supported = $false
    $enabled = $null
    $reason = $null

    $cmd = Get-Command -Name 'Confirm-SecureBootUEFI' -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        $reason = 'Confirm-SecureBootUEFI is unavailable (SecureBoot module missing)'
        $uncertainty.Add($reason)
    } else {
        try {
            $enabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
            $supported = $true
        } catch {
            $reason = [string]$_.Exception.Message
            $uncertainty.Add("Secure Boot could not be confirmed on this platform ($reason) - reported as unknown, not disabled")
        }
    }

    $firmwareType = $null
    try {
        $ci = Get-ComputerInfo -Property BiosFirmwareType -ErrorAction Stop
        $firmwareType = [string](Get-Nx14PropertyValue -Object $ci -Name 'BiosFirmwareType')
    } catch {
        $uncertainty.Add("Get-ComputerInfo BiosFirmwareType failed ($($_.Exception.Message)) - firmware mode unreported")
    }
    $crossCheck = Get-Nx14RegistryText -Path $script:Nx14SecureBootStateKey -Name 'UEFISecureBootEnabled'

    return [pscustomobject]@{
        readOnly          = $true
        tweakId           = 'NX14-005'
        generatedUtc      = (Get-Date).ToUniversalTime().ToString('o')
        supported         = $supported
        secureBootEnabled = $enabled
        firmwareType      = $firmwareType
        reason            = $reason
        registryCrossCheck = [pscustomobject]@{ text = $crossCheck.text; provenance = 'E0 observation (not authoritative; the cmdlet result governs)' }
        uncertainty       = $uncertainty.ToArray()
        notes             = @('Read-only: NEXTRIX never calls Set-SecureBootUEFI, clears keys or writes BCD.')
    }
}

# ============================================================================
# NX14-006 - TPM status report (read-only)
# ============================================================================

function Get-Nx14TpmStatus {
    <#
    .SYNOPSIS
        Read-only TPM status; no ownership/clear/provision command exists.
    #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $statusRead = $false
    $reason = $null
    $fields = $null

    $cmd = Get-Command -Name 'Get-Tpm' -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        $reason = 'Get-Tpm is unavailable (TrustedPlatformModule module missing)'
        $uncertainty.Add($reason)
    } else {
        try {
            $tpm = Get-Tpm -ErrorAction Stop
            $projected = [ordered]@{}
            foreach ($p in @(
                'TpmPresent','TpmReady','TpmEnabled','TpmActivated','TpmOwned',
                'LockedOut','AutoProvisioning','ManagedAuthLevel','SpecVersion',
                'ManufacturerVersion','PhysicalPresenceVersion','LockoutCount',
                'LockoutHealTime','LockoutMax'
            )) {
                $projected[$p] = Get-Nx14PropertyValue -Object $tpm -Name $p
            }
            $manufacturerText = [string](Get-Nx14PropertyValue -Object $tpm -Name 'ManufacturerIdTxt')
            if ([string]::IsNullOrEmpty($manufacturerText)) {
                $manufacturerText = [string](Get-Nx14PropertyValue -Object $tpm -Name 'ManufacturerId')
            }
            $projected['ManufacturerText'] = ($manufacturerText -replace '[^\x20-\x7E]', '').Trim()
            if ($null -eq $projected['SpecVersion']) {
                $uncertainty.Add('Get-Tpm did not expose SpecVersion on this build - the TPM specification version is unreported')
            }
            $fields = [pscustomobject]$projected
            $statusRead = $true
        } catch {
            $reason = [string]$_.Exception.Message
            $uncertainty.Add("Get-Tpm failed ($reason) - TPM state unknown")
        }
    }

    return [pscustomobject]@{
        readOnly    = $true
        tweakId     = 'NX14-006'
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        tpm         = [pscustomobject]@{ statusRead = $statusRead; reason = $reason; fields = $fields }
        uncertainty = $uncertainty.ToArray()
        notes       = @(
            'Read-only: Initialize-Tpm / Clear-Tpm / Set-TpmOwnerAuth are never called by NEXTRIX.',
            'TPM presence does not by itself mean BitLocker, Windows Hello or Credential Guard are configured.'
        )
    }
}

# ============================================================================
# NX14-007 - VBS / HVCI report (read-only)
# ============================================================================

function Get-Nx14DeviceGuardStatus {
    <#
    .SYNOPSIS
        Read-only Win32_DeviceGuard report with configured-vs-running.
    .DESCRIPTION
        Never claims effective protection from a registry value. A missing
        CIM class yields supported=false with the reason (VM/older platform).
    #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $supported = $false
    $reason = $null
    $vbsStatus = $null
    $vbsText = 'Unknown'
    $configured = @()
    $running = @()
    $configuredNames = @()
    $runningNames = @()
    $propertyNames = @()
    $availableProperties = @()
    $requiredProperties = @()
    $codeIntegrityStatus = $null

    try {
        $dg = Get-CimInstance -Namespace $script:Nx14DeviceGuardNamespace -ClassName 'Win32_DeviceGuard' -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $dg) { throw 'Win32_DeviceGuard returned no instance' }
        $supported = $true
        $vbsStatus = Get-Nx14PropertyValue -Object $dg -Name 'VirtualizationBasedSecurityStatus'
        switch ([string]$vbsStatus) {
            '0' { $vbsText = 'Not enabled' }
            '1' { $vbsText = 'Enabled but not running' }
            '2' { $vbsText = 'Running' }
            default { $vbsText = "Unknown ($vbsStatus)"; $uncertainty.Add("VirtualizationBasedSecurityStatus '$vbsStatus' is outside the documented 0/1/2 values") }
        }
        $configured = @(Get-Nx14PropertyValue -Object $dg -Name 'SecurityServicesConfigured' | Where-Object { $null -ne $_ })
        $running = @(Get-Nx14PropertyValue -Object $dg -Name 'SecurityServicesRunning' | Where-Object { $null -ne $_ })
        foreach ($id in $configured) {
            $key = [int]$id
            if ($script:Nx14SecurityServiceNames.ContainsKey($key)) { $configuredNames += $script:Nx14SecurityServiceNames[$key] }
            else { $configuredNames += "Unknown service id $key"; $uncertainty.Add("unknown Device Guard service id $key in SecurityServicesConfigured") }
        }
        foreach ($id in $running) {
            $key = [int]$id
            if ($script:Nx14SecurityServiceNames.ContainsKey($key)) { $runningNames += $script:Nx14SecurityServiceNames[$key] }
            else { $runningNames += "Unknown service id $key"; $uncertainty.Add("unknown Device Guard service id $key in SecurityServicesRunning") }
        }
        $availableProperties = @(Get-Nx14PropertyValue -Object $dg -Name 'AvailableSecurityProperties' | Where-Object { $null -ne $_ })
        foreach ($id in $availableProperties) {
            $key = [int]$id
            if ($script:Nx14SecurityPropertyNames.ContainsKey($key)) { $propertyNames += $script:Nx14SecurityPropertyNames[$key] }
            else { $propertyNames += "Unknown property id $key" }
        }
        $requiredProperties = @(Get-Nx14PropertyValue -Object $dg -Name 'RequiredSecurityProperties' | Where-Object { $null -ne $_ })
        $codeIntegrityStatus = Get-Nx14PropertyValue -Object $dg -Name 'CodeIntegrityPolicyEnforcementStatus'
    } catch {
        $reason = [string]$_.Exception.Message
        $uncertainty.Add("Win32_DeviceGuard could not be read ($reason) - VBS/HVCI state unknown on this platform")
    }

    $hvciRegistry = Get-Nx14RegistryText -Path $script:Nx14HvciKey -Name 'Enabled'
    $vbsLocked = Get-Nx14RegistryText -Path $script:Nx14DeviceGuardRootKey -Name 'Locked'
    $hvciConfigured = ($configuredNames -contains $script:Nx14SecurityServiceNames[2])
    $hvciRunning = ($runningNames -contains $script:Nx14SecurityServiceNames[2])
    $hvciEffective = 'Not configured'
    if ($hvciRunning) { $hvciEffective = 'Running' }
    elseif ($hvciConfigured) { $hvciEffective = 'Configured but not running' }
    if ($hvciRegistry.existed -and [string]$hvciRegistry.value -eq '1' -and -not $hvciRunning) {
        $uncertainty.Add('HVCI is Enabled=1 in the registry but the runtime service is not running - UEFI lock, policy or a driver-compatibility block can cause this; effective state is not claimed (r2 #222).')
    }

    return [pscustomobject]@{
        readOnly                 = $true
        tweakId                  = 'NX14-007'
        generatedUtc             = (Get-Date).ToUniversalTime().ToString('o')
        supported                = $supported
        reason                   = $reason
        vbsStatus                = $vbsStatus
        vbsStatusText            = $vbsText
        securityServicesConfigured = $configured
        securityServicesRunning  = $running
        configuredNames          = $configuredNames
        runningNames             = $runningNames
        availableSecurityProperties = $availableProperties
        availableSecurityPropertyNames = $propertyNames
        requiredSecurityProperties = $requiredProperties
        codeIntegrityPolicyEnforcementStatus = $codeIntegrityStatus
        hvci                     = [pscustomobject]@{ registry = $hvciRegistry; configured = $hvciConfigured; running = $hvciRunning; effective = $hvciEffective }
        vbsLocked                = $vbsLocked
        uncertainty              = $uncertainty.ToArray()
        notes                    = @(
            'Configured and running are reported separately: a registry value alone is not proof of effective protection.',
            'Read-only: no bcdedit call, no service change and no DeviceGuard registry write.'
        )
    }
}

# ============================================================================
# NX14-008 - Memory Integrity (HVCI): report + consent-gated enable only
# ============================================================================

function Get-Nx14CodeIntegrityBlockEvents {
    <#
    .SYNOPSIS
        Bounded read of CodeIntegrity operational HVCI block events.
    .DESCRIPTION
        Heuristic compatibility signal only (E0 provenance): the authoritative
        incompatible-driver list is the Windows Security UI, which has no
        documented public read API. A channel that exists but has no matching
        events is read=$true/count=0, not a failure.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 50)][int]$MaxEvents = 10,
        [ValidateRange(1, 365)][int]$Days = 30
    )
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-CodeIntegrity/Operational'
            Id = 3033
            StartTime = (Get-Date).AddDays(-1 * $Days)
        } -MaxEvents $MaxEvents -ErrorAction Stop)
        foreach ($e in $events) {
            $message = ''
            try { $message = [string]$e.Message } catch { }
            if ($message.Length -gt 200) { $message = $message.Substring(0, 200) + '...[truncated]' }
            $rows.Add([pscustomobject]@{ timeCreatedUtc = $e.TimeCreated.ToUniversalTime().ToString('o'); id = $e.Id; message = $message })
        }
        return [pscustomobject]@{ read = $true; count = $rows.Count; events = $rows.ToArray(); reason = $null }
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match '(?i)no events were found') {
            return [pscustomobject]@{ read = $true; count = 0; events = @(); reason = 'no matching events' }
        }
        return [pscustomobject]@{ read = $false; count = 0; events = @(); reason = $msg }
    }
}

function Get-Nx14MemoryIntegrityStatus {
    <#
    .SYNOPSIS
        Read-only Memory Integrity (HVCI) status and enable-eligibility report.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 50)][int]$MaxCompatibilityEvents = 10
    )
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $dg = Get-Nx14DeviceGuardStatus
    foreach ($u in @($dg.uncertainty)) { $uncertainty.Add($u) }

    $policyHvci = Get-Nx14RegistryText -Path $script:Nx14DeviceGuardPolicyKey -Name 'HypervisorEnforcedCodeIntegrity'
    $policyVbs = Get-Nx14RegistryText -Path $script:Nx14DeviceGuardPolicyKey -Name 'EnableVirtualizationBasedSecurity'
    $policyLsa = Get-Nx14RegistryText -Path $script:Nx14DeviceGuardPolicyKey -Name 'LsaCfgFlags'
    $policyManaged = ($policyHvci.existed -or $policyVbs.existed)
    if ($policyManaged) {
        $uncertainty.Add('A DeviceGuard policy value is present - a local HVCI write can be overridden by policy; change the policy source instead')
    }

    $events = Get-Nx14CodeIntegrityBlockEvents -MaxEvents $MaxCompatibilityEvents
    if (-not $events.read) {
        $uncertainty.Add("CodeIntegrity/Operational could not be read ($($events.reason)) - driver-compatibility detection is incomplete; the Windows Security UI remains authoritative")
    } elseif ($events.count -gt 0) {
        $uncertainty.Add("$($events.count) recent CodeIntegrity HVCI block event(s) found - this is a heuristic signal, not the authoritative incompatible-driver list")
    }

    $hvciValue = $null
    if ($dg.hvci.registry.existed) { [void][int]::TryParse([string]$dg.hvci.registry.value, [ref]$hvciValue) }
    $vbsCapable = (@($dg.availableSecurityProperties) -contains 1)
    if ($dg.supported -and -not $vbsCapable) {
        $uncertainty.Add('Win32_DeviceGuard did not report hypervisor-based security support - HVCI cannot be enabled on this platform as observed')
    }
    $locked = ($dg.vbsLocked.existed -and [string]$dg.vbsLocked.value -eq '1')
    if ($locked) {
        $uncertainty.Add('VBS is UEFI-locked (DeviceGuard\\Locked=1) - a local write is expected to no-op silently (ReviOS #222); NX14 refuses instead of claiming success')
    }

    return [pscustomobject]@{
        readOnly       = $true
        tweakId        = 'NX14-008'
        generatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        deviceGuard    = $dg
        hvciEnabled    = $hvciValue
        hvciRegistry   = $dg.hvci.registry
        hvciConfigured = $dg.hvci.configured
        hvciRunning    = $dg.hvci.running
        hvciEffective  = $dg.hvci.effective
        vbsCapable     = $vbsCapable
        vbsStatusText  = $dg.vbsStatusText
        locked         = $locked
        policyManaged  = $policyManaged
        policyValues   = [pscustomobject]@{ hypervisorEnforcedCodeIntegrity = $policyHvci; enableVirtualizationBasedSecurity = $policyVbs; lsaCfgFlags = $policyLsa }
        codeIntegrityBlockEvents = $events.events
        codeIntegrityBlockEventCount = $events.count
        compatibilityEventsRead = $events.read
        enableEligible = ($dg.supported -and $vbsCapable -and -not $locked -and -not $policyManaged)
        uncertainty    = $uncertainty.ToArray()
        notes          = @(
            'The authoritative incompatible-driver list is Windows Security > Device security > Core isolation > Memory integrity; this report can only provide a bounded event-log heuristic.',
            'Enabling is the only direction NX14 implements; disabling Memory Integrity is never a NEXTRIX action.',
            'No performance effect is claimed in either direction.'
        )
    }
}

function Set-Nx14MemoryIntegrity {
    <#
    .SYNOPSIS
        NX14-008: enable Memory Integrity (HVCI) with ExplicitConsent and a
        recorded driver-compatibility review.
    .DESCRIPTION
        Writes exactly one value: HVCI Enabled=1 (DWord). Refuses when VBS is
        not reported available, UEFI-locked, policy-managed, when CodeIntegrity
        reports HVCI block events, or when -DriverCompatibilityReviewed is
        absent. Never writes Enabled=0.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateSet('Enable')][string]$Mode,
        [switch]$DriverCompatibilityReviewed,
        [switch]$Approved,
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$TweakId = 'NX14-008',
        [string]$TweakVersion = '1'
    )
    if (-not $Approved -and -not $WhatIfPreference) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }

    $status = Get-Nx14MemoryIntegrityStatus
    $blockers = New-Object System.Collections.Generic.List[string]
    if (-not $status.deviceGuard.supported) { $blockers.Add('DeviceGuard WMI state unavailable - support cannot be established') }
    if (-not $status.vbsCapable) { $blockers.Add('hardware/firmware does not report hypervisor-based security support') }
    if ($status.locked) { $blockers.Add('VBS is UEFI-locked; a local write would silently no-op (r2 #222)') }
    if ($status.policyManaged) { $blockers.Add('DeviceGuard policy values are present; change the policy source instead of the local key') }
    if ($status.codeIntegrityBlockEventCount -gt 0) { $blockers.Add("$($status.codeIntegrityBlockEventCount) recent CodeIntegrity HVCI block event(s) - resolve incompatible drivers first") }
    if (-not $DriverCompatibilityReviewed.IsPresent) { $blockers.Add('-DriverCompatibilityReviewed is required (recorded review of Windows Security > Core isolation)') }

    if (-not $PSCmdlet.ShouldProcess('Memory Integrity (HVCI)', 'Set Enabled=1 (restart required; exact prior value journaled)')) {
        return [pscustomobject]@{
            tweakId = $TweakId; planned = $true; mode = $Mode; changed = $false; verified = $false
            applied = $false; blockers = $blockers.ToArray(); status = $status
            notes = @('WhatIf: no journal entry and no registry write. Blockers are reported so the plan is honest.')
        }
    }
    if ($blockers.Count -gt 0) {
        throw "$TweakId : refusing to enable Memory Integrity - " + ($blockers -join '; ')
    }
    if ($status.hvciEnabled -eq 1 -and $status.hvciRunning) {
        $descriptor = [pscustomobject]@{ targetType = 'registry'; path = $script:Nx14HvciKey; name = 'Enabled'; kind = 'DWord'; value = 1 }
        $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $descriptor -Modified $descriptor -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        return [pscustomobject]@{
            tweakId = $TweakId; planned = $false; changed = $false; verified = $true; applied = $true
            journalSeq = $skip.seq; restartRequired = $false; effective = 'Running'
            notes = @('Memory Integrity was already enabled and running; no rewrite.')
        }
    }

    $result = Invoke-Nx14RegistryTarget -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $script:Nx14HvciKey -Name 'Enabled' -Kind DWord -Value 1 -Profiles $Profiles
    $after = Get-Nx14MemoryIntegrityStatus -MaxCompatibilityEvents 1
    $verification = 'NotVerified'
    if ($result.verified) {
        if ($after.hvciRunning) { $verification = 'Verified-Effective' }
        else { $verification = 'Verified-RestartPending' }
    }
    return [pscustomobject]@{
        tweakId         = $TweakId
        planned         = $false
        mode            = $Mode
        changed         = $result.changed
        verified        = $result.verified
        applied         = $result.verified
        verification    = $verification
        journalSeq      = $result.journalSeq
        restartRequired = [bool]($result.verified -and -not $after.hvciRunning)
        driverCompatibilityReviewed = $DriverCompatibilityReviewed.IsPresent
        blockers        = @()
        before          = $status
        reason          = $result.reason
        notes           = @(
            'Only HVCI Enabled=1 was written; the exact prior value is journaled.',
            'Drivers or anti-cheat/DRM components that do not meet HVCI requirements may fail to load after the restart.',
            'Reversal is a manual Windows Security action or an explicit NX16 rollback of this journals entry - NEXTRIX never auto-disables Memory Integrity.',
            'No performance claim is made.'
        )
    }
}

# ============================================================================
# NX14-009 - Credential Guard status report (read-only)
# ============================================================================

function Get-Nx14CredentialGuardStatus {
    <#
    .SYNOPSIS
        Read-only Credential Guard configured/running report. Reads no
        credential material.
    #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $dg = Get-Nx14DeviceGuardStatus
    foreach ($u in @($dg.uncertainty)) { $uncertainty.Add($u) }

    $cgConfigured = ($dg.configuredNames -contains $script:Nx14SecurityServiceNames[1])
    $cgRunning = ($dg.runningNames -contains $script:Nx14SecurityServiceNames[1])

    $policyLsa = Get-Nx14RegistryText -Path $script:Nx14DeviceGuardPolicyKey -Name 'LsaCfgFlags'
    $bootLsa = Get-Nx14RegistryText -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\LSA' -Name 'LsaCfgFlags'
    $policyText = 'No explicit DeviceGuard policy value observed'
    if ($policyLsa.existed) {
        switch ([string]$policyLsa.value) {
            '0' { $policyText = '0 - disabled by policy' }
            '1' { $policyText = '1 - enabled with UEFI lock' }
            '2' { $policyText = '2 - enabled without lock' }
            default { $policyText = "$($policyLsa.value) - outside the documented 0/1/2 values"; $uncertainty.Add('LsaCfgFlags is outside the documented 0/1/2 values') }
        }
    }
    $state = 'NotConfigured'
    if ($cgRunning) {
        $state = 'Running'
        if (-not $policyLsa.existed) { $state = 'Running (no explicit policy observed)' }
    } elseif ($cgConfigured) {
        $state = 'Configured but not running'
    } elseif ($policyLsa.existed -and [string]$policyLsa.value -eq '0') {
        $state = 'DisabledByPolicy'
    }
    if ($cgConfigured -and -not $cgRunning) {
        $uncertainty.Add('Credential Guard is configured but not running (firmware, virtualization or policy blocker) - effective state is not claimed')
    }

    return [pscustomobject]@{
        readOnly      = $true
        tweakId       = 'NX14-009'
        generatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        state         = $state
        configured    = $cgConfigured
        running       = $cgRunning
        policyValue   = $policyLsa
        policyText    = $policyText
        bootObservation = $bootLsa
        vbsStatusText = $dg.vbsStatusText
        uncertainty   = $uncertainty.ToArray()
        notes         = @(
            'Read-only: no credential, LSA secret, certificate or key material is read.',
            'Credential Guard is never disabled or reconfigured by NEXTRIX.'
        )
    }
}

# ============================================================================
# NX14-010 - Controlled Folder Access: snapshot, status, consent-gated setter
# ============================================================================

function Get-Nx14CfaModeMap {
    <#
    .SYNOPSIS
        Pure CFA mode map. Mode 0 (disabled) is deliberately absent.
    #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ mode = 'Enabled'; value = 1; description = 'Block unauthorised changes to protected folders (documented CFA on).' }
        [pscustomobject]@{ mode = 'Audit'; value = 2; description = 'Record would-be blocks in the Defender event log without blocking (documented audit mode).' }
    )
}

function Get-Nx14CfaSnapshot {
    <#
    .SYNOPSIS
        Read-only CFA preference snapshot (mode + exact allow/protected lists).
    #>
    [CmdletBinding()]
    param()
    $snap = [ordered]@{
        supported = $false; readSucceeded = $false; reason = $null
        modeValue = $null; mode = $null
        allowedApplications = @(); protectedFolders = @()
    }
    $cmd = Get-Command -Name 'Get-MpPreference' -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        $snap.reason = 'Get-MpPreference is unavailable (Defender module absent or the feature is not installed)'
        return [pscustomobject]$snap
    }
    $snap.supported = $true
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        $snap.readSucceeded = $true
        $rawMode = Get-Nx14PropertyValue -Object $pref -Name 'EnableControlledFolderAccess'
        if ($null -ne $rawMode) { $snap.modeValue = [int]$rawMode }
        switch ([string]$snap.modeValue) {
            '0' { $snap.mode = 'Disabled' }
            '1' { $snap.mode = 'Enabled' }
            '2' { $snap.mode = 'Audit' }
            default { $snap.mode = $(if ($null -eq $snap.modeValue) { 'Unknown (value absent)' } else { "Unknown ($($snap.modeValue))" }) }
        }
        $apps = Get-Nx14PropertyValue -Object $pref -Name 'ControlledFolderAccessAllowedApplications'
        $folders = Get-Nx14PropertyValue -Object $pref -Name 'ControlledFolderAccessProtectedFolders'
        $snap.allowedApplications = @($apps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        $snap.protectedFolders = @($folders | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    } catch {
        $snap.reason = [string]$_.Exception.Message
    }
    return [pscustomobject]$snap
}

function Get-Nx14ControlledFolderAccessStatus {
    <#
    .SYNOPSIS
        NX14-010 read-only status view.
    #>
    [CmdletBinding()]
    param()
    $snap = Get-Nx14CfaSnapshot
    $uncertainty = New-Object System.Collections.Generic.List[string]
    if (-not $snap.supported -or -not $snap.readSucceeded) {
        $uncertainty.Add("Controlled Folder Access state unavailable ($($snap.reason))")
    }
    return [pscustomobject]@{
        readOnly    = $true
        tweakId     = 'NX14-010'
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        supported   = $snap.supported
        readSucceeded = $snap.readSucceeded
        mode        = $snap.mode
        modeValue   = $snap.modeValue
        allowedApplications = $snap.allowedApplications
        protectedFolders = $snap.protectedFolders
        reason      = $snap.reason
        uncertainty = $uncertainty.ToArray()
        notes       = @(
            'Allowed-application paths are local configuration state required for exact restore; no credential or secret is read.',
            'NEXTRIX never turns Controlled Folder Access off (mode 0 is not implemented).'
        )
    }
}

function Restore-Nx14CfaPreference {
    <#
    .SYNOPSIS
        Best-effort exact restore of a captured CFA preference (mode + list).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Original)
    $notes = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Original.modeValue) { throw 'captured CFA mode is missing - cannot restore' }
    Set-MpPreference -EnableControlledFolderAccess ([int]$Original.modeValue) -ErrorAction Stop
    $notes.Add("mode->$($Original.modeValue)")
    $live = Get-Nx14CfaSnapshot
    if (-not $live.readSucceeded) { throw "CFA restore could not re-read preferences ($($live.reason))" }
    $origSet = @($Original.allowedApplications)
    foreach ($app in $origSet) {
        if (@($live.allowedApplications) -notcontains [string]$app) {
            Add-MpPreference -ControlledFolderAccessAllowedApplications ([string]$app) -ErrorAction Stop
            $notes.Add("added:$app")
        }
    }
    foreach ($app in @($live.allowedApplications)) {
        if ($origSet -notcontains [string]$app) {
            Remove-MpPreference -ControlledFolderAccessAllowedApplications ([string]$app) -ErrorAction Stop
            $notes.Add("removed:$app")
        }
    }
    return [pscustomobject]@{ restored = $true; actions = $notes.ToArray() }
}

function Set-Nx14ControlledFolderAccess {
    <#
    .SYNOPSIS
        NX14-010: enable/audit CFA and add/remove exact allowed applications.
    .DESCRIPTION
        Mode 0 (off) is structurally absent. Per-app paths are validated before
        the journal write (no wildcards, must exist as a file). Journal-first;
        verification failure restores the captured mode/list.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateSet('Enabled','Audit')][string]$Mode,
        [string[]]$AddAllowedApplication = @(),
        [string[]]$RemoveAllowedApplication = @(),
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakId = 'NX14-010',
        [string]$TweakVersion = '1'
    )
    if (-not $Approved -and -not $WhatIfPreference) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    $modeMap = Get-Nx14CfaModeMap
    $selectedMode = @($modeMap | Where-Object { $_.mode -eq $Mode })[0]
    if ($null -eq $selectedMode) { throw "$TweakId : mode '$Mode' is not in the documented allow-list" }

    $adds = @($AddAllowedApplication | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    $removes = @($RemoveAllowedApplication | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    foreach ($app in @($adds + $removes)) {
        if ($app -match '[\*\?]') { throw "$TweakId : '$app' contains a wildcard - exact application paths only" }
        if (-not [System.IO.Path]::IsPathRooted($app)) { throw "$TweakId : '$app' is not an absolute path - refusing a relative CFA allow-list entry" }
    }
    foreach ($app in $adds) {
        if (-not (Test-Path -LiteralPath $app -PathType Leaf)) { throw "$TweakId : allow-list application '$app' does not exist as a file" }
    }

    $before = Get-Nx14CfaSnapshot
    if (-not $before.readSucceeded) {
        if ($WhatIfPreference) {
            return [pscustomobject]@{ tweakId = $TweakId; planned = $true; changed = $false; verified = $false; reason = "CFA unavailable: $($before.reason)" }
        }
        throw "$TweakId : Controlled Folder Access is unavailable on this machine ($($before.reason)) - nothing changed"
    }

    $desired = New-Object System.Collections.Generic.List[string]
    foreach ($app in @($before.allowedApplications)) {
        if ($removes -notcontains [string]$app) { $desired.Add([string]$app) }
    }
    foreach ($app in $adds) {
        if (-not ($desired -contains $app)) { $desired.Add($app) }
    }
    $desiredArray = $desired.ToArray()
    $changed = ($before.modeValue -ne [int]$selectedMode.value) -or ($adds.Count -gt 0) -or ($removes.Count -gt 0)

    $plan = [pscustomobject]@{
        tweakId = $TweakId; planned = $true; mode = $Mode; modeValue = $selectedMode.value
        changed = $changed; verified = $false; applied = $false
        addAllowedApplication = $adds; removeAllowedApplication = $removes
        before = $before; desiredAllowedApplications = $desiredArray
        restartRequired = $false
    }
    if (-not $PSCmdlet.ShouldProcess('Controlled Folder Access', "Set mode $Mode and apply $($adds.Count) add / $($removes.Count) remove allow-list entries")) {
        return $plan
    }
    if (-not $changed) {
        $descriptor = [pscustomobject]@{ targetType = 'defenderPreference'; name = 'ControlledFolderAccess'; mode = $before.mode; modeValue = $before.modeValue; allowedApplications = @($before.allowedApplications) }
        $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $descriptor -Modified $descriptor -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        $plan.changed = $false; $plan.verified = $true; $plan.applied = $true
        return [pscustomobject]@{ tweakId = $TweakId; changed = $false; verified = $true; applied = $true; journalSeq = $skip.seq; reason = 'already in desired state'; before = $before; restartRequired = $false }
    }

    $orig = [pscustomobject]@{
        targetType = 'defenderPreference'; name = 'ControlledFolderAccess'
        mode = $before.mode; modeValue = $before.modeValue
        allowedApplications = @($before.allowedApplications)
        protectedFolders = @($before.protectedFolders)
    }
    $mod = [pscustomobject]@{
        targetType = 'defenderPreference'; name = 'ControlledFolderAccess'
        mode = $Mode; modeValue = [int]$selectedMode.value
        allowedApplications = $desiredArray
        addAllowedApplication = $adds; removeAllowedApplication = $removes
    }
    $applyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $orig -Modified $mod -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Set-MpPreference -EnableControlledFolderAccess ([int]$selectedMode.value) -ErrorAction Stop
        foreach ($app in $adds) { Add-MpPreference -ControlledFolderAccessAllowedApplications $app -ErrorAction Stop }
        foreach ($app in $removes) { Remove-MpPreference -ControlledFolderAccessAllowedApplications $app -ErrorAction Stop }

        $after = Get-Nx14CfaSnapshot
        $modeOk = ($after.readSucceeded -and $after.modeValue -eq [int]$selectedMode.value)
        $addsOk = $true
        foreach ($app in $adds) { if (@($after.allowedApplications) -notcontains $app) { $addsOk = $false } }
        $removesOk = $true
        foreach ($app in $removes) { if (@($after.allowedApplications) -contains $app) { $removesOk = $false } }
        $verified = ($modeOk -and $addsOk -and $removesOk)
        $detail = "mode=$($after.modeValue) addsOk=$addsOk removesOk=$removesOk"
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $orig -Modified $mod -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $detail -Profiles $Profiles
        if (-not $verified) {
            $restoreNote = ''
            try { $restoreNote = ((Restore-Nx14CfaPreference -Original $orig).actions -join '; ') } catch { $restoreNote = "restore failed: $($_.Exception.Message)" }
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $mod -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo "$detail; restore: $restoreNote" -Profiles $Profiles
            return [pscustomobject]@{ tweakId = $TweakId; changed = $true; verified = $false; applied = $false; journalSeq = $applyJournal.seq; reason = "CFA verification failed ($detail); restore attempted: $restoreNote"; restartRequired = $false }
        }
        return [pscustomobject]@{
            tweakId = $TweakId; changed = $true; verified = $true; applied = $true
            journalSeq = $applyJournal.seq; mode = $Mode; modeValue = [int]$selectedMode.value
            allowedApplications = @($after.allowedApplications); restartRequired = $false
            reason = 'CFA mode and allow-list verified'
        }
    } catch {
        $err = [string]$_.Exception.Message
        $restoreNote = ''
        try { $restoreNote = ((Restore-Nx14CfaPreference -Original $orig).actions -join '; ') } catch { $restoreNote = "restore failed: $($_.Exception.Message)" }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $mod -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo ("$err; restore: $restoreNote") -Profiles $Profiles
        return [pscustomobject]@{ tweakId = $TweakId; changed = $false; verified = $false; applied = $false; journalSeq = $applyJournal.seq; reason = "CFA change failed: $err (restore: $restoreNote)"; restartRequired = $false }
    }
}

# ============================================================================
# NX14-011 - Exploit Protection: report (default) + per-process opt-in
# ============================================================================

function Get-Nx14MitigationAllowList {
    <#
    .SYNOPSIS
        Pure allow-list of per-process mitigations this entry may ENABLE.
    .DESCRIPTION
        Only security-increasing, documented Set-ProcessMitigation names.
        Disable/Remove of an administrator-set value is not a public action;
        system-wide mitigation masks are never written.
    #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ name = 'CFG';                    propertyPath = 'Cfg.Enable';                        documentedName = 'Control Flow Guard' }
        [pscustomobject]@{ name = 'SEHOP';                  propertyPath = 'Sehop.Enable';                      documentedName = 'Validate exception chains (SEHOP)' }
        [pscustomobject]@{ name = 'ForceRelocateImages';    propertyPath = 'Aslr.ForceRelocateImages';          documentedName = 'Force randomization for images (Mandatory ASLR)' }
        [pscustomobject]@{ name = 'BlockRemoteImageLoads';  propertyPath = 'ImageLoad.BlockRemoteImageLoads';   documentedName = 'Block remote image loads' }
        [pscustomobject]@{ name = 'DisableExtensionPoints'; propertyPath = 'ExtensionPoint.DisableExtensionPoints'; documentedName = 'Disable extension points' }
        [pscustomobject]@{ name = 'StrictHandle';           propertyPath = 'StrictHandle.Enable';               documentedName = 'Validate handle usage (strict handle)' }
        [pscustomobject]@{ name = 'BottomUp';               propertyPath = 'Aslr.BottomUp';                     documentedName = 'Randomize memory allocations (bottom-up ASLR)' }
        [pscustomobject]@{ name = 'HighEntropy';            propertyPath = 'Aslr.HighEntropy';                  documentedName = 'High-entropy ASLR' }
    )
}

function Get-Nx14MitigationStateText {
    <# Observed cmdlet tri-state encoding (0/1/2). Labeled E0 in output. #>
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return 'Unknown (property absent)' }
    $v = 0
    if (-not [int]::TryParse([string]$Value, [ref]$v)) { return "Unknown ($Value)" }
    switch ($v) {
        0 { return 'Off' }
        1 { return 'On' }
        2 { return 'Not configured (inherits the effective default)' }
        default { return "Unknown ($v)" }
    }
}

function Get-Nx14ExploitProtectionReport {
    <#
    .SYNOPSIS
        NX14-011 read-only exploit-protection report (system + IFEO presence).
    #>
    [CmdletBinding()]
    param([ValidateRange(1, 500)][int]$MaxIfeoKeys = 300)

    $uncertainty = New-Object System.Collections.Generic.List[string]
    $rows = New-Object System.Collections.Generic.List[object]
    $systemRead = $false
    $reason = $null
    $cmd = Get-Command -Name 'Get-ProcessMitigation' -ErrorAction SilentlyContinue

    if ($null -eq $cmd) {
        $reason = 'Get-ProcessMitigation is unavailable (ProcessMitigations module missing)'
        $uncertainty.Add($reason)
    } else {
        try {
            $system = Get-ProcessMitigation -System -ErrorAction Stop
            foreach ($def in (Get-Nx14MitigationAllowList)) {
                $value = Get-Nx14NestedValue -Object $system -Path $def.propertyPath
                $state = Get-Nx14MitigationStateText -Value $value
                if ($null -ne $value -and $state -like 'Unknown*') { $uncertainty.Add("$($def.name): unexpected value '$value'") }
                $rows.Add([pscustomobject]@{
                    mitigation = $def.name; documentedName = $def.documentedName; propertyPath = $def.propertyPath
                    value = $value; state = $state; source = 'System'
                })
            }
            $systemRead = $true
        } catch {
            $reason = "Get-ProcessMitigation -System failed: $($_.Exception.Message)"
            $uncertainty.Add($reason)
        }
    }

    # Per-process configuration presence (names only; bounded).
    $perProcess = New-Object System.Collections.Generic.List[string]
    try {
        $keys = @(Get-ChildItem -Path $script:Nx14IfeoKey -ErrorAction Stop | Select-Object -First $MaxIfeoKeys)
        foreach ($key in $keys) {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if ($null -ne $props -and ($null -ne $props.PSObject.Properties['MitigationOptions'] -or $null -ne $props.PSObject.Properties['MitigationAuditOptions'])) {
                $perProcess.Add([string]$key.PSChildName)
            }
        }
        if (@($keys).Count -ge $MaxIfeoKeys) {
            $uncertainty.Add("IFEO enumeration capped at $MaxIfeoKeys keys; additional per-process entries may exist")
        }
    } catch {
        $uncertainty.Add("IFEO enumeration failed ($($_.Exception.Message)) - per-process configuration list is incomplete")
    }

    return [pscustomobject]@{
        readOnly        = $true
        tweakId         = 'NX14-011'
        generatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        systemMitigationsRead = $systemRead
        reason          = $reason
        systemMitigations = $rows.ToArray()
        perProcessConfigured = $perProcess.ToArray()
        perProcessCount = $perProcess.Count
        allowedMitigations = @(Get-Nx14MitigationAllowList | ForEach-Object { $_.name })
        uncertainty     = $uncertainty.ToArray()
        notes           = @(
            'The numeric tri-state encoding (0 Off / 1 On / 2 Not configured) is an observation from build 26100, not a published contract - labeled E0 in output while the cmdlet itself is E1-documented.',
            'Per-process hardening is opt-in via Set-Nx14MitigationPolicy with per-item ExplicitConsent; the default action of this entry writes nothing.',
            'System-wide mitigation masks (kernel MitigationOptions / FeatureSettingsOverride) are banned targets and are never written by NX14.',
            'No performance claim is made for any mitigation setting.'
        )
    }
}

function Get-Nx14ProcessMitigationSnapshot {
    <#
    .SYNOPSIS
        Read-only per-process mitigation tri-state for the allow-listed set.
    .DESCRIPTION
        Get-ProcessMitigation -Name returns $null when the process has no
        per-process configuration (verified on build 26100); that is recorded
        as existed=false, never as Off.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProcessName)
    $out = [ordered]@{
        processName = $ProcessName; available = $false; reason = $null
        source = $null; existed = $false; values = @{}
    }
    $cmd = Get-Command -Name 'Get-ProcessMitigation' -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        $out.reason = 'Get-ProcessMitigation is unavailable'
        return [pscustomobject]$out
    }
    try {
        $pm = Get-ProcessMitigation -Name $ProcessName -ErrorAction Stop
    } catch {
        $out.reason = [string]$_.Exception.Message
        return [pscustomobject]$out
    }
    $out.available = $true
    if ($null -eq $pm) {
        $out.existed = $false
        $out.source = $null
        return [pscustomobject]$out
    }
    $out.source = [string](Get-Nx14PropertyValue -Object $pm -Name 'Source')
    $out.existed = ($out.source -eq 'Registry')
    foreach ($def in (Get-Nx14MitigationAllowList)) {
        $value = Get-Nx14NestedValue -Object $pm -Path $def.propertyPath
        if ($null -ne $value) {
            $parsed = 0
            if ([int]::TryParse([string]$value, [ref]$parsed)) { $out.values[$def.name] = $parsed }
        }
    }
    return [pscustomobject]$out
}

function Set-Nx14MitigationPolicy {
    <#
    .SYNOPSIS
        NX14-011 opt-in: ENABLE allow-listed mitigations for one named process.
    .DESCRIPTION
        Never disables anything. Refuses wildcards/relative names, a mitigation
        already explicitly configured, and any process whose mitigation cannot
        be read. Journals the exact tri-state, exports the full cmdlet JSON as
        the original-state artifact, verifies by re-read, and on failure removes
        only what it enabled.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$ProcessName,
        [Parameter(Mandatory)][string[]]$Mitigations,
        [switch]$Approved,
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$TweakId = 'NX14-011',
        [string]$TweakVersion = '1'
    )
    if (-not $Approved -and -not $WhatIfPreference) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    if ($null -eq (Get-Command -Name 'Set-ProcessMitigation' -ErrorAction SilentlyContinue)) {
        throw "$TweakId : Set-ProcessMitigation is unavailable (ProcessMitigations module missing)"
    }
    $leaf = [System.IO.Path]::GetFileName($ProcessName)
    if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -match '[\*\?]' -or $leaf -notmatch '(?i)\.exe$') {
        throw "$TweakId : '$ProcessName' must resolve to a concrete .exe image name (no wildcards)"
    }
    $allow = Get-Nx14MitigationAllowList
    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($m in @($Mitigations)) {
        $match = @($allow | Where-Object { $_.name -eq $m })
        if ($match.Count -eq 0) { throw "$TweakId : mitigation '$m' is not on the NX14 allow-list (never a free-form mitigation string)" }
        if (@($selected | Where-Object { $_.name -eq $m }).Count -gt 0) { continue }
        $selected.Add($match[0])
    }
    if ($selected.Count -eq 0) { throw "$TweakId : at least one allow-listed mitigation is required" }

    $before = Get-Nx14ProcessMitigationSnapshot -ProcessName $leaf
    $blockers = New-Object System.Collections.Generic.List[string]
    if (-not $before.available) { $blockers.Add("per-process mitigation state could not be read ($($before.reason))") }
    foreach ($def in $selected) {
        if ($before.values.ContainsKey($def.name) -and [int]$before.values[$def.name] -ne 2) {
            $stateText = Get-Nx14MitigationStateText -Value $before.values[$def.name]
            $blockers.Add("$($def.name) is already explicitly '$stateText' for $leaf - NEXTRIX does not fight an existing explicit setting")
        }
    }

    if (-not $PSCmdlet.ShouldProcess($leaf, "Enable mitigations: $((@($selected | ForEach-Object { $_.name })) -join ', ')")) {
        return [pscustomobject]@{
            tweakId = $TweakId; planned = $true; processName = $leaf
            mitigations = @($selected | ForEach-Object { $_.name }); changed = $false; verified = $false
            blockers = $blockers.ToArray(); before = $before
        }
    }
    if ($blockers.Count -gt 0) { throw "$TweakId : refusing - " + ($blockers -join '; ') }

    $exportDir = Join-Path $JournalRoot 'mitigation-exports'
    if (-not (Test-Path $exportDir)) { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }
    $safe = ($leaf -replace '[^A-Za-z0-9\.\-_]', '_')
    $snapshotPath = Join-Path $exportDir ("process-$safe-" + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '.json')
    $snapshotNote = $null
    try {
        $raw = Get-ProcessMitigation -Name $leaf -ErrorAction Stop
        if ($null -eq $raw) {
            '{"note":"Get-ProcessMitigation returned no per-process configuration before the NX14 change"}' | Set-Content -LiteralPath $snapshotPath -Encoding UTF8
        } else {
            $raw | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $snapshotPath -Encoding UTF8
        }
    } catch {
        $snapshotNote = "snapshot export failed: $($_.Exception.Message)"
        $snapshotPath = $null
    }

    $orig = [pscustomobject]@{
        targetType = 'processMitigation'; processName = $leaf; existed = [bool]$before.existed
        source = $before.source; values = $before.values; snapshotPath = $snapshotPath; snapshotNote = $snapshotNote
    }
    $afterValues = @{}
    foreach ($def in $selected) { $afterValues[$def.name] = 1 }
    $mod = [pscustomobject]@{ targetType = 'processMitigation'; processName = $leaf; values = $afterValues }
    $applyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $orig -Modified $mod -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    $names = @($selected | ForEach-Object { $_.name })
    try {
        Set-ProcessMitigation -Name $leaf -Enable $names -ErrorAction Stop
        $live = Get-Nx14ProcessMitigationSnapshot -ProcessName $leaf
        $ok = $live.available
        $detail = New-Object System.Collections.Generic.List[string]
        foreach ($def in $selected) {
            $value = $null
            if ($live.values.ContainsKey($def.name)) { $value = [int]$live.values[$def.name] }
            if ($null -eq $value -or $value -ne 1) { $ok = $false }
            $detail.Add("$($def.name)=$(Get-Nx14MitigationStateText -Value $value)")
        }
        $detailText = $detail -join '; '
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $detailText -Profiles $Profiles
        if (-not $ok) {
            $restoreNote = ''
            try { Set-ProcessMitigation -Name $leaf -Remove $names -ErrorAction Stop; $restoreNote = 'enabled mitigations removed (returned to the prior configuration)' } catch { $restoreNote = "remove failed: $($_.Exception.Message)" }
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $mod -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo "$detailText; restore: $restoreNote" -Profiles $Profiles
            return [pscustomobject]@{ tweakId = $TweakId; changed = $true; verified = $false; applied = $false; journalSeq = $applyJournal.seq; reason = "verification failed ($detailText); restore: $restoreNote"; snapshotPath = $snapshotPath }
        }
        return [pscustomobject]@{
            tweakId = $TweakId; changed = $true; verified = $true; applied = $true
            journalSeq = $applyJournal.seq; processName = $leaf; mitigations = $names
            verification = 'Verified'; snapshotPath = $snapshotPath
            reason = 'mitigations read back enabled'
        }
    } catch {
        $err = [string]$_.Exception.Message
        $restoreNote = ''
        try { Set-ProcessMitigation -Name $leaf -Remove $names -ErrorAction Stop; $restoreNote = 'attempted removal of enabled mitigations' } catch { $restoreNote = "remove failed: $($_.Exception.Message)" }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $mod -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo ("$err; restore: $restoreNote") -Profiles $Profiles
        return [pscustomobject]@{ tweakId = $TweakId; changed = $false; verified = $false; applied = $false; journalSeq = $applyJournal.seq; reason = "mitigation enable failed: $err (restore: $restoreNote)"; snapshotPath = $snapshotPath }
    }
}

# ============================================================================
# NX14-012 - BitLocker status report (read-only, no key material)
# ============================================================================

function Get-Nx14BitLockerStatus {
    <#
    .SYNOPSIS
        Read-only BitLocker volume report; protector TYPES only, never IDs or
        recovery passwords.
    #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $rows = New-Object System.Collections.Generic.List[object]
    $read = $false
    $reason = $null
    $cmd = Get-Command -Name 'Get-BitLockerVolume' -ErrorAction SilentlyContinue

    if ($null -eq $cmd) {
        $reason = 'Get-BitLockerVolume is unavailable (BitLocker module not present on this edition/role)'
        $uncertainty.Add($reason)
    } else {
        try {
            foreach ($v in @(Get-BitLockerVolume -ErrorAction Stop)) {
                $typeText = 'Unknown'
                switch ([string]$v.VolumeType) {
                    '0' { $typeText = 'OperatingSystem' }
                    '1' { $typeText = 'FixedData' }
                    '2' { $typeText = 'Removable' }
                    default { $typeText = "Unknown ($($v.VolumeType))" }
                }
                $protectionText = 'Unknown'
                switch ([string]$v.ProtectionStatus) {
                    '0' { $protectionText = 'Off' }
                    '1' { $protectionText = 'On' }
                    '2' { $protectionText = 'Unknown' }
                }
                $lockText = 'Unknown'
                switch ([string]$v.LockStatus) {
                    '0' { $lockText = 'Unlocked' }
                    '1' { $lockText = 'Locked' }
                }
                # Protector TYPES only: KeyProtectorId and any key material are
                # deliberately not read into the output.
                $protectorTypes = @(@($v.KeyProtector) | ForEach-Object { [string]$_.KeyProtectorType } | Where-Object { $_ } | Sort-Object -Unique)
                $rows.Add([pscustomobject]@{
                    mountPoint          = [string]$v.MountPoint
                    volumeType          = [int]$v.VolumeType
                    volumeTypeText      = $typeText
                    protectionStatus    = [int]$v.ProtectionStatus
                    protectionStatusText = $protectionText
                    lockStatus          = $lockText
                    encryptionPercentage = [int]$v.EncryptionPercentage
                    encryptionMethod    = [string]$v.EncryptionMethod
                    autoUnlockEnabled   = ConvertTo-Nx14BoolState (Get-Nx14PropertyValue -Object $v -Name 'AutoUnlockEnabled')
                    keyProtectorTypes   = $protectorTypes
                })
            }
            $read = $true
        } catch {
            $reason = "Get-BitLockerVolume failed: $($_.Exception.Message)"
            $uncertainty.Add($reason)
        }
    }

    $osVolume = @($rows | Where-Object { $_.volumeType -eq 0 })
    $osProtected = $null
    if ($osVolume.Count -gt 0) { $osProtected = ($osVolume[0].protectionStatus -eq 1) }
    $fixedVolumes = @($rows | Where-Object { $_.volumeType -eq 1 })
    $unprotectedFixed = @($fixedVolumes | Where-Object { $_.protectionStatus -ne 1 }).Count

    return [pscustomobject]@{
        readOnly          = $true
        tweakId           = 'NX14-012'
        generatedUtc      = (Get-Date).ToUniversalTime().ToString('o')
        bitLocker         = [pscustomobject]@{ statusRead = $read; reason = $reason }
        volumes           = $rows.ToArray()
        osVolumeProtected = $osProtected
        fixedVolumesCount = $fixedVolumes.Count
        unprotectedFixedVolumes = $unprotectedFixed
        uncertainty       = $uncertainty.ToArray()
        notes             = @(
            'Protector TYPES only: KeyProtectorId, recovery passwords and key material are never read or emitted.',
            'Protection state does not prove that a recovery key is backed up or escrowed - NEXTRIX does not manage recovery keys.',
            'Read-only: BitLocker is never disabled, suspended or re-keyed by NEXTRIX.'
        )
    }
}

# ============================================================================
# Optional-feature helpers (NX01-015 mechanism reused, never duplicated)
# ============================================================================

function Get-Nx14FeatureState {
    <#
    .SYNOPSIS
        Read-only optional-feature state (DISM). Requires elevation on Windows.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FeatureName)
    $out = [ordered]@{ featureName = $FeatureName; readSucceeded = $false; state = $null; reason = $null }
    $cmd = Get-Command -Name 'Get-WindowsOptionalFeature' -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        $out.reason = 'Get-WindowsOptionalFeature is unavailable (DISM module missing)'
        return [pscustomobject]$out
    }
    try {
        Import-Module Dism -ErrorAction Stop
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
        if ($null -eq $feature) { throw "DISM returned no object for feature '$FeatureName'" }
        $out.state = [string]$feature.State
        $out.readSucceeded = $true
    } catch {
        $out.reason = [string]$_.Exception.Message
    }
    return [pscustomobject]$out
}

function Set-Nx14FeatureStateRaw {
    <# Low-level feature state change WITHOUT journaling: used by the rollback
       replay only. The apply path always journals first. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FeatureName,
        [Parameter(Mandatory)][ValidateSet('Enabled','Disabled')][string]$State
    )
    Import-Module Dism -ErrorAction Stop
    if ($State -eq 'Enabled') {
        Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction Stop | Out-Null
    } else {
        Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction Stop | Out-Null
    }
}

function Set-Nx14FeatureStateJournaled {
    <#
    .SYNOPSIS
        Journaled feature change. Delegates to NX01-015's verified pipeline when
        it is loaded (its own journaling is reused); otherwise runs the same
        documented capture -> journal -> change -> verify pipeline locally with
        the targetType 'optionalFeature'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FeatureName,
        [Parameter(Mandatory)][ValidateSet('Enabled','Disabled')][string]$State,
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$TweakId,
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @()
    )
    $delegate = Get-Command -Name 'Set-NxOptionalFeatureState' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $delegate -and $delegate.Parameters.ContainsKey('TweakId') -and $delegate.Parameters.ContainsKey('Approval')) {
        $r = Set-NxOptionalFeatureState -FeatureName $FeatureName -State $State -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles
        return [pscustomobject]@{
            changed = [bool]$r.changed; verified = [bool]$r.verified; reason = [string]$r.reason
            originalState = [string]$r.originalState; newState = [string]$r.newState
            restartNeeded = $r.restartNeeded; via = 'NX01-015 Set-NxOptionalFeatureState'
        }
    }

    # Local fallback: identical documented pipeline, separate target type.
    $before = Get-Nx14FeatureState -FeatureName $FeatureName
    if (-not $before.readSucceeded) {
        throw "$TweakId : optional feature '$FeatureName' could not be read ($($before.reason)) - refusing to change it without a prior state"
    }
    $orig = [pscustomobject]@{ targetType = 'optionalFeature'; featureName = $FeatureName; existed = $true; state = $before.state }
    $mod = [pscustomobject]@{ targetType = 'optionalFeature'; featureName = $FeatureName; state = $State }
    if ($before.state -eq $State) {
        $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $orig -Modified $mod -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        return [pscustomobject]@{ changed = $false; verified = $true; reason = 'already in desired state'; originalState = $before.state; newState = $before.state; restartNeeded = $false; via = 'local optionalFeature pipeline'; journalSeq = $skip.seq }
    }
    $apply = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $orig -Modified $mod -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Set-Nx14FeatureStateRaw -FeatureName $FeatureName -State $State
        $after = Get-Nx14FeatureState -FeatureName $FeatureName
        $pending = if ($State -eq 'Enabled') { 'EnablePending' } else { 'DisablePending' }
        $verified = ($after.readSucceeded -and ($after.state -eq $State -or $after.state -eq $pending))
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $orig -Modified $mod -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -ErrorInfo "state now '$($after.state)'" -Profiles $Profiles
        return [pscustomobject]@{ changed = $true; verified = $verified; reason = "state now '$($after.state)'"; originalState = $before.state; newState = $after.state; restartNeeded = ($after.state -eq $pending); via = 'local optionalFeature pipeline'; journalSeq = $apply.seq }
    } catch {
        $err = [string]$_.Exception.Message
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles
        return [pscustomobject]@{ changed = $false; verified = $false; reason = "feature change failed: $err"; originalState = $before.state; newState = $null; restartNeeded = $null; via = 'local optionalFeature pipeline'; journalSeq = $apply.seq }
    }
}

# ============================================================================
# NX14-013 - Windows Sandbox provisioning
# ============================================================================

function Get-Nx14WindowsSandboxStatus {
    <#
    .SYNOPSIS
        Read-only Windows Sandbox feature + virtualization prerequisite report.
    #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $feature = Get-Nx14FeatureState -FeatureName $script:Nx14SandboxFeature
    if (-not $feature.readSucceeded) { $uncertainty.Add("Windows Sandbox feature state unavailable ($($feature.reason))") }

    $edition = Get-Nx14EditionId
    $editionSupport = 'Unknown'
    if (-not [string]::IsNullOrWhiteSpace($edition)) {
        if ($edition -match '(?i)^(Core|CoreN|CoreSingleLanguage|CoreCountrySpecific|CoreConnected|Starter)') { $editionSupport = 'Unsupported' }
        elseif ($edition -match '(?i)^(Professional|Enterprise|Education|ProfessionalWorkstation|EnterpriseS|EnterpriseG|IoTEnterprise|Server)') { $editionSupport = 'Supported' }
        else { $uncertainty.Add("edition '$edition' is not in the documented Sandbox support list - support not asserted") }
    } else {
        $uncertainty.Add('edition id could not be read - Sandbox edition support not asserted')
    }

    $hypervisorPresent = $null
    try {
        $cs = Get-CimInstance -ClassName 'Win32_ComputerSystem' -ErrorAction Stop | Select-Object -First 1
        $hypervisorPresent = ConvertTo-Nx14BoolState (Get-Nx14PropertyValue -Object $cs -Name 'HypervisorPresent')
    } catch {
        $uncertainty.Add("Win32_ComputerSystem HypervisorPresent unavailable ($($_.Exception.Message))")
    }
    $virtualizationFirmwareEnabled = $null
    $slat = $null
    try {
        $proc = Get-CimInstance -ClassName 'Win32_Processor' -ErrorAction Stop | Select-Object -First 1
        $virtualizationFirmwareEnabled = ConvertTo-Nx14BoolState (Get-Nx14PropertyValue -Object $proc -Name 'VirtualizationFirmwareEnabled')
        $slat = ConvertTo-Nx14BoolState (Get-Nx14PropertyValue -Object $proc -Name 'SecondLevelAddressTranslationExtensions')
    } catch {
        $uncertainty.Add("Win32_Processor virtualization facts unavailable ($($_.Exception.Message))")
    }
    if ($hypervisorPresent -eq $true -and $virtualizationFirmwareEnabled -eq $false) {
        $uncertainty.Add('VirtualizationFirmwareEnabled reports False while a hypervisor is present - the CPU is already owned by the hypervisor; this is not treated as unsupported')
    }

    return [pscustomobject]@{
        readOnly    = $true
        tweakId     = 'NX14-013'
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        featureName = $script:Nx14SandboxFeature
        feature     = $feature
        edition     = $edition
        editionSupport = $editionSupport
        hypervisorPresent = $hypervisorPresent
        virtualizationFirmwareEnabled = $virtualizationFirmwareEnabled
        slatSupported = $slat
        uncertainty = $uncertainty.ToArray()
        notes       = @(
            'Windows Sandbox requires a supported edition and firmware virtualization; the report refuses to promise a feature that cannot work.',
            'Third-party hypervisors can conflict with the Windows hypervisor stack.',
            'A restart is required after provisioning.'
        )
    }
}

function Set-Nx14WindowsSandbox {
    <#
    .SYNOPSIS
        NX14-013: provision (or remove) the documented Windows Sandbox feature.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateSet('Enabled','Disabled')][string]$State,
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakId = 'NX14-013',
        [string]$TweakVersion = '1'
    )
    if (-not $Approved -and -not $WhatIfPreference) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    $status = Get-Nx14WindowsSandboxStatus
    $blockers = New-Object System.Collections.Generic.List[string]
    if (-not $status.feature.readSucceeded) { $blockers.Add("Windows Sandbox feature could not be read ($($status.feature.reason)) - the edition may not offer it") }
    if ($State -eq 'Enabled') {
        if ($status.editionSupport -eq 'Unsupported') { $blockers.Add("Windows Sandbox is not documented as available on edition '$($status.edition)'") }
        if ($status.virtualizationFirmwareEnabled -eq $false -and $status.hypervisorPresent -ne $true) {
            $blockers.Add('firmware virtualization is reported disabled and no hypervisor is present')
        }
    }
    $warnings = @(
        'Windows Sandbox and third-party hypervisors (VMware/VirtualBox) can conflict.',
        'Nested virtualization inside a virtual machine is not supported.',
        'A restart is required before Windows Sandbox is usable.'
    )

    if (-not $PSCmdlet.ShouldProcess($script:Nx14SandboxFeature, "Set optional feature state to $State")) {
        return [pscustomobject]@{ tweakId = $TweakId; planned = $true; state = $State; changed = $false; verified = $false; blockers = $blockers.ToArray(); status = $status; warnings = $warnings; restartRequired = $true }
    }
    if ($blockers.Count -gt 0) { throw "$TweakId : refusing - " + ($blockers -join '; ') }

    $result = Set-Nx14FeatureStateJournaled -FeatureName $script:Nx14SandboxFeature -State $State -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles
    return [pscustomobject]@{
        tweakId = $TweakId; planned = $false; state = $State
        changed = $result.changed; verified = $result.verified; applied = $result.verified
        journalSeq = $result.journalSeq; originalState = $result.originalState; newState = $result.newState
        restartRequired = [bool]($result.restartNeeded -or ($result.verified -and $State -eq 'Enabled'))
        via = $result.via; reason = $result.reason; warnings = $warnings
    }
}

# ============================================================================
# NX14-014 - Hyper-V / virtualization platform
# ============================================================================

function Get-Nx14VirtualizationComponents {
    <# Pure component map (single place). #>
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ key = 'HyperV';                 featureName = 'Microsoft-Hyper-V-All';            display = 'Hyper-V' }
        [pscustomobject]@{ key = 'VirtualMachinePlatform'; featureName = 'VirtualMachinePlatform';           display = 'Virtual Machine Platform (WSL2/Docker)' }
        [pscustomobject]@{ key = 'HypervisorPlatform';     featureName = 'HypervisorPlatform';               display = 'Windows Hypervisor Platform' }
        [pscustomobject]@{ key = 'WindowsSubsystemForLinux'; featureName = 'Microsoft-Windows-Subsystem-Linux'; display = 'Windows Subsystem for Linux (optional component)' }
        [pscustomobject]@{ key = 'WindowsSandbox';         featureName = 'Containers-DisposableClientVM';     display = 'Windows Sandbox' }
    )
}

function Get-Nx14VirtualizationPlatformStatus {
    <#
    .SYNOPSIS
        Read-only virtualization-platform + consumer report.
    #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($c in (Get-Nx14VirtualizationComponents)) {
        $state = Get-Nx14FeatureState -FeatureName $c.featureName
        if (-not $state.readSucceeded) {
            $uncertainty.Add("$($c.display) state unavailable ($($state.reason))")
        }
        $rows.Add([pscustomobject]@{ key = $c.key; display = $c.display; featureName = $c.featureName; readSucceeded = $state.readSucceeded; state = $state.state; reason = $state.reason })
    }

    $hypervisorPresent = $null
    try {
        $cs = Get-CimInstance -ClassName 'Win32_ComputerSystem' -ErrorAction Stop | Select-Object -First 1
        $hypervisorPresent = ConvertTo-Nx14BoolState (Get-Nx14PropertyValue -Object $cs -Name 'HypervisorPresent')
    } catch {
        $uncertainty.Add("Win32_ComputerSystem HypervisorPresent unavailable ($($_.Exception.Message))")
    }

    $wslPresent = ($null -ne (Get-Command -Name 'wsl.exe' -ErrorAction SilentlyContinue))
    $dockerService = $null; $vmComputeService = $null
    try { $dockerService = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue } catch { }
    try { $vmComputeService = Get-Service -Name 'vmcompute' -ErrorAction SilentlyContinue } catch { }
    $sandboxRow = @($rows | Where-Object { $_.key -eq 'WindowsSandbox' })[0]
    $wslFeatureRow = @($rows | Where-Object { $_.key -eq 'WindowsSubsystemForLinux' })[0]

    $dependencyWarnings = New-Object System.Collections.Generic.List[string]
    $dependencyWarnings.Add('WSL2 requires VirtualMachinePlatform plus the WSL feature (or the Store WSL package).')
    $dependencyWarnings.Add('Docker Desktop requires VirtualMachinePlatform or Hyper-V; disabling either breaks it.')
    $dependencyWarnings.Add('Windows Sandbox requires Containers-DisposableClientVM.')
    if ($wslPresent) { $dependencyWarnings.Add('wsl.exe is present on this machine - WSL is in use; disabling the virtualization platform will break it.') }
    if ($null -ne $dockerService) { $dependencyWarnings.Add("Docker service 'com.docker.service' is present - Docker Desktop is installed; disabling the platform will break it.") }
    if ($null -ne $sandboxRow -and $sandboxRow.state -eq 'Enabled') { $dependencyWarnings.Add('Windows Sandbox is enabled - disabling the virtualization platform will break it.') }
    if ($null -ne $vmComputeService) { $dependencyWarnings.Add("Hyper-V Host Compute Service 'vmcompute' is present.") }

    return [pscustomobject]@{
        readOnly    = $true
        tweakId     = 'NX14-014'
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        edition     = (Get-Nx14EditionId)
        components  = $rows.ToArray()
        hypervisorPresent = $hypervisorPresent
        consumers   = [pscustomobject]@{
            wslPresent = $wslPresent
            dockerServicePresent = ($null -ne $dockerService)
            vmComputeServicePresent = ($null -ne $vmComputeService)
            wslFeatureState = $(if ($null -ne $wslFeatureRow) { $wslFeatureRow.state } else { $null })
            sandboxState = $(if ($null -ne $sandboxRow) { $sandboxRow.state } else { $null })
        }
        dependencyWarnings = $dependencyWarnings.ToArray()
        uncertainty = $uncertainty.ToArray()
        notes       = @(
            'Read-only by default: this entry never changes a virtualization feature unless the owner explicitly invokes Set-Nx14VirtualizationPlatform.',
            'Enabling or disabling virtualization changes the hypervisor environment; re-check NX14-007/VBS after the restart.',
            'No performance claim is made in either direction; BCD is never touched (NX17 owns it).'
        )
    }
}

function Set-Nx14VirtualizationPlatform {
    <#
    .SYNOPSIS
        NX14-014 opt-in: enable/disable ONE virtualization component.
    .DESCRIPTION
        Disabling requires -AcknowledgeDependencyImpact because it breaks
        WSL2/Docker/Sandbox/running VMs. ExplicitConsent is the registry
        approval model; the exact prior feature state is journaled.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateSet('HyperV','VirtualMachinePlatform','HypervisorPlatform')][string]$Component,
        [Parameter(Mandatory)][ValidateSet('Enabled','Disabled')][string]$State,
        [switch]$AcknowledgeDependencyImpact,
        [switch]$Approved,
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$TweakId = 'NX14-014',
        [string]$TweakVersion = '1'
    )
    if (-not $Approved -and -not $WhatIfPreference) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    $status = Get-Nx14VirtualizationPlatformStatus
    $map = @(Get-Nx14VirtualizationComponents | Where-Object { $_.key -eq $Component })[0]
    if ($null -eq $map) { throw "$TweakId : component '$Component' is not in the documented map" }
    $row = @($status.components | Where-Object { $_.key -eq $Component })[0]

    $blockers = New-Object System.Collections.Generic.List[string]
    if ($null -eq $row -or -not $row.readSucceeded) {
        $blockers.Add("feature '$($map.featureName)' could not be read - it may not exist on this edition")
    }
    if ($State -eq 'Disabled' -and -not $AcknowledgeDependencyImpact.IsPresent) {
        $blockers.Add('-AcknowledgeDependencyImpact is required to disable a virtualization component (WSL2/Docker/Sandbox/VMs will break)')
    }
    if ($State -eq 'Enabled' -and $status.edition -match '(?i)^(Core|CoreN|CoreSingleLanguage)') {
        $blockers.Add("Hyper-V is not a documented capability of edition '$($status.edition)'")
    }

    if (-not $PSCmdlet.ShouldProcess($map.featureName, "Set optional feature state to $State")) {
        return [pscustomobject]@{
            tweakId = $TweakId; planned = $true; component = $Component; featureName = $map.featureName
            state = $State; changed = $false; verified = $false; blockers = $blockers.ToArray()
            dependencyWarnings = $status.dependencyWarnings; status = $status; restartRequired = $true
        }
    }
    if ($blockers.Count -gt 0) { throw "$TweakId : refusing - " + ($blockers -join '; ') }

    $result = Set-Nx14FeatureStateJournaled -FeatureName $map.featureName -State $State -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles
    return [pscustomobject]@{
        tweakId = $TweakId; planned = $false; component = $Component; featureName = $map.featureName
        state = $State; changed = $result.changed; verified = $result.verified; applied = $result.verified
        journalSeq = $result.journalSeq; originalState = $result.originalState; newState = $result.newState
        restartRequired = [bool]($result.restartNeeded -or $result.verified)
        via = $result.via; reason = $result.reason
        dependencyWarnings = $status.dependencyWarnings
        acknowledgedDependencyImpact = $AcknowledgeDependencyImpact.IsPresent
        notes = @('Re-check NX14-007/VBS after the restart; enabling/disabling the hypervisor can change VBS availability.')
    }
}

# ============================================================================
# NX14-003 - UAC level setter
# ============================================================================

function Set-Nx14UacLevel {
    <#
    .SYNOPSIS
        NX14-003: set one of three documented UAC levels (never UAC-off).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateSet('Default','AlwaysNotify','CredentialsOnSecureDesktop')][string]$Level,
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakId = 'NX14-003',
        [string]$TweakVersion = '1'
    )
    if (-not $Approved -and -not $WhatIfPreference) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    $selected = @(Get-Nx14UacLevelMap | Where-Object { $_.level -eq $Level })[0]
    if ($null -eq $selected) { throw "$TweakId : level '$Level' is not in the documented map" }
    # Structural guard: the map may never emit an insecure value.
    if ([int]$selected.enableLua -ne 1 -or [int]$selected.promptOnSecureDesktop -ne 1 -or @(0,3,4) -contains [int]$selected.consentPromptBehaviorAdmin) {
        throw "$TweakId : internal level map produced an insecure UAC combination - refusing"
    }

    $before = Get-Nx14UacStatus
    $targets = @(
        @{ name = 'EnableLUA';                 value = [int]$selected.enableLua }
        @{ name = 'ConsentPromptBehaviorAdmin'; value = [int]$selected.consentPromptBehaviorAdmin }
        @{ name = 'PromptOnSecureDesktop';      value = [int]$selected.promptOnSecureDesktop }
    )

    if (-not $PSCmdlet.ShouldProcess("UAC level '$Level'", 'Set documented UAC values (EnableLUA=1, secure desktop on)')) {
        return [pscustomobject]@{ tweakId = $TweakId; planned = $true; level = $Level; changed = $false; verified = $false; targets = $targets; before = $before; restartRequired = $true }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($t in $targets) {
        $results.Add((Invoke-Nx14RegistryTarget -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $script:Nx14UacKey -Name $t.name -Kind DWord -Value $t.value -Profiles $Profiles))
    }
    $verifiedCount = @($results | Where-Object { $_.verified }).Count
    $changedCount = @($results | Where-Object { $_.changed }).Count
    $after = Get-Nx14UacStatus
    return [pscustomobject]@{
        tweakId = $TweakId; planned = $false; level = $Level
        changed = ($changedCount -gt 0); verified = ($verifiedCount -eq $results.Count)
        applied = ($verifiedCount -eq $results.Count)
        targets = $results.ToArray(); before = $before; after = $after
        restartRequired = ($changedCount -gt 0)
        notes = @(
            'EnableLUA=1 and PromptOnSecureDesktop=1 are always written; UAC-off and non-secure-desktop prompts are not representable in this entry.',
            'A restart/sign-out is required for an EnableLUA change; prompt-level changes apply to newly started processes.',
            'Managed machines may re-apply their own policy on the next refresh.'
        )
    }
}

# ============================================================================
# NX14-004 - SmartScreen setter
# ============================================================================

function Set-Nx14SmartScreen {
    <#
    .SYNOPSIS
        NX14-004: set the documented SmartScreen policy to Warn or Block.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateSet('Warn','Block')][string]$Level,
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakId = 'NX14-004',
        [string]$TweakVersion = '1'
    )
    if (-not $Approved -and -not $WhatIfPreference) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    $selected = @(Get-Nx14SmartScreenLevelMap | Where-Object { $_.level -eq $Level })[0]
    if ($null -eq $selected) { throw "$TweakId : level '$Level' is not in the documented map" }
    if ([int]$selected.enableSmartScreen -ne 1) { throw "$TweakId : internal map produced EnableSmartScreen != 1 - refusing" }
    $before = Get-Nx14SmartScreenStatus

    if (-not $PSCmdlet.ShouldProcess("SmartScreen policy '$Level'", 'Set EnableSmartScreen=1 and the documented Shell level')) {
        return [pscustomobject]@{ tweakId = $TweakId; planned = $true; level = $Level; changed = $false; verified = $false; before = $before; restartRequired = $false }
    }
    $results = New-Object System.Collections.Generic.List[object]
    $results.Add((Invoke-Nx14RegistryTarget -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $script:Nx14SmartScreenPolicyKey -Name 'EnableSmartScreen' -Kind DWord -Value 1 -Profiles $Profiles))
    $results.Add((Invoke-Nx14RegistryTarget -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $script:Nx14SmartScreenPolicyKey -Name 'ShellSmartScreenLevel' -Kind String -Value ([string]$selected.shellSmartScreenLevel) -Profiles $Profiles))
    $verifiedCount = @($results | Where-Object { $_.verified }).Count
    return [pscustomobject]@{
        tweakId = $TweakId; planned = $false; level = $Level
        changed = (@($results | Where-Object { $_.changed }).Count -gt 0)
        verified = ($verifiedCount -eq $results.Count); applied = ($verifiedCount -eq $results.Count)
        targets = $results.ToArray(); before = $before; after = (Get-Nx14SmartScreenStatus)
        restartRequired = $false
        notes = @(
            'Only the documented Shell policy is written; the legacy Explorer value is reported, never rewritten.',
            'SmartScreen is never turned off by this entry.'
        )
    }
}

# ============================================================================
# NX14-015 - Windows Security health aggregate report (read-only)
# ============================================================================

function Get-Nx14SecurityHealthReport {
    <#
    .SYNOPSIS
        Read-only aggregate of the NX14 status reports.
    .DESCRIPTION
        Each area is probed in isolation: one failing provider degrades one row,
        never the report. Status vocabulary is fixed and factual. No security
        score is produced. Coverage and exclusions are declared in the output.
    #>
    [CmdletBinding()]
    param()
    $areas = New-Object System.Collections.Generic.List[object]
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $addArea = {
        param([string]$Area, [string]$Status, [string]$Summary, [string]$Detail)
        $areas.Add([pscustomobject]@{ area = $Area; status = $Status; summary = $Summary; detail = $Detail })
    }

    # --- Defender ----------------------------------------------------------
    try {
        $d = Get-Nx14DefenderStatusReport
        foreach ($u in @($d.uncertainty)) { $uncertainty.Add("defender: $u") }
        $status = 'Unknown'
        $summary = 'Defender status unavailable'
        if ($d.defender.statusRead) {
            $rt = ConvertTo-Nx14BoolState $d.defender.status.RealTimeProtectionEnabled
            $av = ConvertTo-Nx14BoolState $d.defender.status.AntivirusEnabled
            if ($rt -eq $true -and $av -eq $true) { $status = 'On'; $summary = 'Antivirus and real-time protection report enabled' }
            elseif ($rt -eq $false -or $av -eq $false) { $status = 'Off'; $summary = 'Defender reports a protection feature disabled' }
            else { $summary = 'Defender status read but feature flags are absent' }
        }
        & $addArea 'defender' $status $summary 'NX14-001'
    } catch {
        $uncertainty.Add("defender: report failed ($($_.Exception.Message))")
        & $addArea 'defender' 'Unknown' 'Report failed' 'NX14-001'
    }

    # --- Firewall ----------------------------------------------------------
    try {
        $f = Get-Nx14FirewallStatusReport
        foreach ($u in @($f.uncertainty)) { $uncertainty.Add("firewall: $u") }
        $status = 'Unknown'; $summary = 'Firewall status unavailable'
        if ($f.firewall.statusRead) {
            if ($f.allProfilesEnabled) { $status = 'On'; $summary = 'All firewall profiles enabled' }
            elseif ($f.anyProfileDisabled) { $status = 'Partial'; $summary = "Disabled profile(s): $((@($f.disabledProfiles)) -join ', ')" }
            else { $summary = 'Profiles read but enabled state is unknown' }
        }
        & $addArea 'firewall' $status $summary 'NX14-002'
    } catch {
        $uncertainty.Add("firewall: report failed ($($_.Exception.Message))")
        & $addArea 'firewall' 'Unknown' 'Report failed' 'NX14-002'
    }

    # --- Secure Boot / TPM / VBS / HVCI / Credential Guard -----------------
    try {
        $sb = Get-Nx14SecureBootStatus
        foreach ($u in @($sb.uncertainty)) { $uncertainty.Add("secureBoot: $u") }
        $status = 'Unknown'; $summary = 'Secure Boot unknown'
        if ($sb.supported) {
            if ($sb.secureBootEnabled -eq $true) { $status = 'On'; $summary = 'Secure Boot enabled (Confirm-SecureBootUEFI)' }
            else { $status = 'Off'; $summary = 'Secure Boot disabled (Confirm-SecureBootUEFI)' }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$sb.reason)) { $status = 'Unsupported'; $summary = "Secure Boot cannot be confirmed: $($sb.reason)" }
        & $addArea 'secureBoot' $status $summary 'NX14-005'
    } catch {
        $uncertainty.Add("secureBoot: report failed ($($_.Exception.Message))")
        & $addArea 'secureBoot' 'Unknown' 'Report failed' 'NX14-005'
    }

    try {
        $tpm = Get-Nx14TpmStatus
        foreach ($u in @($tpm.uncertainty)) { $uncertainty.Add("tpm: $u") }
        $status = 'Unknown'; $summary = 'TPM unknown'
        if ($tpm.tpm.statusRead) {
            $present = ConvertTo-Nx14BoolState $tpm.tpm.fields.TpmPresent
            $ready = ConvertTo-Nx14BoolState $tpm.tpm.fields.TpmReady
            if ($present -eq $true -and $ready -eq $true) { $status = 'Configured'; $summary = 'TPM present and ready' }
            elseif ($present -eq $true) { $status = 'NotConfigured'; $summary = 'TPM present but not ready' }
            else { $status = 'NotConfigured'; $summary = 'No TPM reported' }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$tpm.tpm.reason)) { $status = 'Unsupported'; $summary = "TPM state unavailable: $($tpm.tpm.reason)" }
        & $addArea 'tpm' $status $summary 'NX14-006'
    } catch {
        $uncertainty.Add("tpm: report failed ($($_.Exception.Message))")
        & $addArea 'tpm' 'Unknown' 'Report failed' 'NX14-006'
    }

    $dg = $null
    try {
        $dg = Get-Nx14DeviceGuardStatus
        foreach ($u in @($dg.uncertainty)) { $uncertainty.Add("deviceGuard: $u") }
        $status = 'Unknown'; $summary = 'VBS state unknown'
        if ($dg.supported) {
            switch ([string]$dg.vbsStatus) {
                '2' { $status = 'On'; $summary = 'VBS running' }
                '1' { $status = 'Partial'; $summary = 'VBS enabled but not running' }
                '0' { $status = 'NotConfigured'; $summary = 'VBS not enabled' }
                default { $summary = "VBS status '$($dg.vbsStatusText)'" }
            }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$dg.reason)) { $status = 'Unsupported'; $summary = "Device Guard unavailable: $($dg.reason)" }
        & $addArea 'vbs' $status $summary 'NX14-007'
    } catch {
        $uncertainty.Add("deviceGuard: report failed ($($_.Exception.Message))")
        & $addArea 'vbs' 'Unknown' 'Report failed' 'NX14-007'
    }

    if ($null -ne $dg) {
        $status = 'Unknown'; $summary = 'HVCI state unknown'
        switch ([string]$dg.hvci.effective) {
            'Running' { $status = 'On'; $summary = 'Memory Integrity (HVCI) running' }
            'Configured but not running' { $status = 'Partial'; $summary = 'HVCI configured but not running' }
            'Not configured' { $status = 'NotConfigured'; $summary = 'Memory Integrity not configured' }
        }
        if (-not $dg.supported) { $status = 'Unsupported'; $summary = 'Device Guard unavailable' }
        & $addArea 'memoryIntegrity' $status $summary 'NX14-007'
    } else {
        & $addArea 'memoryIntegrity' 'Unknown' 'Device Guard report unavailable' 'NX14-007'
    }

    try {
        $cg = Get-Nx14CredentialGuardStatus
        foreach ($u in @($cg.uncertainty)) { $uncertainty.Add("credentialGuard: $u") }
        $status = 'Unknown'; $summary = 'Credential Guard state unknown'
        if ($cg.running) { $status = 'On'; $summary = 'Credential Guard running' }
        elseif ($cg.configured) { $status = 'Partial'; $summary = 'Credential Guard configured but not running' }
        elseif ($cg.state -eq 'DisabledByPolicy') { $status = 'Off'; $summary = 'Credential Guard disabled by policy' }
        else { $status = 'NotConfigured'; $summary = 'No Credential Guard configuration observed' }
        & $addArea 'credentialGuard' $status $summary 'NX14-009'
    } catch {
        $uncertainty.Add("credentialGuard: report failed ($($_.Exception.Message))")
        & $addArea 'credentialGuard' 'Unknown' 'Report failed' 'NX14-009'
    }

    # --- CFA / BitLocker ---------------------------------------------------
    try {
        $cfa = Get-Nx14ControlledFolderAccessStatus
        foreach ($u in @($cfa.uncertainty)) { $uncertainty.Add("cfa: $u") }
        $status = 'Unknown'; $summary = 'CFA state unknown'
        if ($cfa.readSucceeded) {
            switch ([string]$cfa.mode) {
                'Enabled' { $status = 'On'; $summary = 'Controlled Folder Access blocking' }
                'Audit' { $status = 'Partial'; $summary = 'Controlled Folder Access in audit mode (no blocking)' }
                'Disabled' { $status = 'Off'; $summary = 'Controlled Folder Access disabled' }
                default { $summary = "CFA mode '$($cfa.mode)'" }
            }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$cfa.reason)) { $status = 'Unsupported'; $summary = "CFA unavailable: $($cfa.reason)" }
        & $addArea 'controlledFolderAccess' $status $summary 'NX14-010'
    } catch {
        $uncertainty.Add("cfa: report failed ($($_.Exception.Message))")
        & $addArea 'controlledFolderAccess' 'Unknown' 'Report failed' 'NX14-010'
    }

    try {
        $bl = Get-Nx14BitLockerStatus
        foreach ($u in @($bl.uncertainty)) { $uncertainty.Add("bitLocker: $u") }
        $status = 'Unknown'; $summary = 'BitLocker state unknown'
        if ($bl.bitLocker.statusRead) {
            if (@($bl.volumes).Count -eq 0) { $summary = 'No volumes reported' }
            elseif ($bl.osVolumeProtected -eq $true) { $status = 'On'; $summary = 'OS volume protected' }
            elseif ($bl.unprotectedFixedVolumes -gt 0) { $status = 'Partial'; $summary = "OS volume not protected; $($bl.unprotectedFixedVolumes) fixed volume(s) unprotected" }
            else { $status = 'Off'; $summary = 'No protected volume reported' }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$bl.bitLocker.reason)) { $status = 'Unsupported'; $summary = "BitLocker state unavailable: $($bl.bitLocker.reason)" }
        & $addArea 'bitLocker' $status $summary 'NX14-012'
    } catch {
        $uncertainty.Add("bitLocker: report failed ($($_.Exception.Message))")
        & $addArea 'bitLocker' 'Unknown' 'Report failed' 'NX14-012'
    }

    # --- UAC / SmartScreen / Exploit Protection ----------------------------
    try {
        $uac = Get-Nx14UacStatus
        foreach ($u in @($uac.uncertainty)) { $uncertainty.Add("uac: $u") }
        $status = 'Unknown'; $summary = "UAC level '$($uac.level)'"
        switch ([string]$uac.level) {
            'UacDisabled' { $status = 'Off'; $summary = 'UAC disabled (EnableLUA=0) - security finding' }
            'ElevateWithoutPrompting' { $status = 'Off'; $summary = 'Administrator elevation without prompting - security finding' }
            'Unknown' { $status = 'Unknown' }
            'Default' { $status = 'Configured' }
            'AlwaysNotify' { $status = 'Configured' }
            'CredentialsOnSecureDesktop' { $status = 'Configured' }
            'PromptForConsent' { $status = 'Partial'; $summary = "$summary without the secure desktop" }
            'PromptForCredentials' { $status = 'Partial'; $summary = "$summary without the secure desktop" }
            default { $status = 'Configured' }
        }
        & $addArea 'uac' $status $summary 'NX14-003'
    } catch {
        $uncertainty.Add("uac: report failed ($($_.Exception.Message))")
        & $addArea 'uac' 'Unknown' 'Report failed' 'NX14-003'
    }

    try {
        $ss = Get-Nx14SmartScreenStatus
        foreach ($u in @($ss.uncertainty)) { $uncertainty.Add("smartScreen: $u") }
        $status = 'Unknown'; $summary = "SmartScreen state '$($ss.state)'"
        switch ([string]$ss.state) {
            'Warn' { $status = 'On'; $summary = 'SmartScreen policy Warn' }
            'Block' { $status = 'On'; $summary = 'SmartScreen policy Block' }
            'DisabledByPolicy' { $status = 'Off'; $summary = 'SmartScreen disabled by policy - security finding' }
            'WindowsDefault' { $status = 'Configured'; $summary = 'No SmartScreen policy; Windows default applies' }
            'EnabledLevelUnspecified' { $status = 'Configured' }
        }
        & $addArea 'smartScreen' $status $summary 'NX14-004'
    } catch {
        $uncertainty.Add("smartScreen: report failed ($($_.Exception.Message))")
        & $addArea 'smartScreen' 'Unknown' 'Report failed' 'NX14-004'
    }

    try {
        $ep = Get-Nx14ExploitProtectionReport
        foreach ($u in @($ep.uncertainty)) { $uncertainty.Add("exploitProtection: $u") }
        $status = 'Unknown'; $summary = 'Mitigation report unavailable'
        if ($ep.systemMitigationsRead) {
            $status = 'Configured'
            $on = @($ep.systemMitigations | Where-Object { $_.state -eq 'On' }).Count
            $off = @($ep.systemMitigations | Where-Object { $_.state -eq 'Off' }).Count
            $nc = @($ep.systemMitigations | Where-Object { $_.state -like 'Not configured*' }).Count
            $summary = "System mitigations reported: $on on, $off off, $nc not configured (decoded observation)"
            if (($on + $off + $nc) -lt @($ep.systemMitigations).Count) { $uncertainty.Add('exploitProtection: some mitigation values could not be decoded') }
        }
        & $addArea 'exploitProtection' $status $summary 'NX14-011'
    } catch {
        $uncertainty.Add("exploitProtection: report failed ($($_.Exception.Message))")
        & $addArea 'exploitProtection' 'Unknown' 'Report failed' 'NX14-011'
    }

    $onCount = @($areas | Where-Object { $_.status -in @('On','Configured') }).Count
    $offCount = @($areas | Where-Object { $_.status -in @('Off','NotConfigured') }).Count
    $partialCount = @($areas | Where-Object { $_.status -eq 'Partial' }).Count
    $unavailable = @($areas | Where-Object { $_.status -in @('Unsupported','Unknown') }).Count

    return [pscustomobject]@{
        readOnly       = $true
        tweakId        = 'NX14-015'
        generatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        areas          = $areas.ToArray()
        counts         = [pscustomobject]@{ reportingOnOrConfigured = $onCount; reportingOffOrNotConfigured = $offCount; reportingPartial = $partialCount; unavailableOrUnsupported = $unavailable }
        securityRating = $null
        uncertainty    = $uncertainty.ToArray()
        coverage       = @(
            'Defender (001)', 'Firewall profiles (002)', 'UAC (003)', 'SmartScreen (004)',
            'Secure Boot (005)', 'TPM (006)', 'VBS/HVCI (007)', 'Credential Guard (009)',
            'Controlled Folder Access (010)', 'Exploit Protection summary (011)', 'BitLocker (012)'
        )
        exclusions     = @(
            'Windows Sandbox / virtualization platform feature inventory (013/014) is intentionally excluded from the aggregate to keep it bounded - use their dedicated reports.',
            'No credential material, LSA secrets, BitLocker key IDs/recovery passwords or Defender exclusion paths are read or emitted.',
            'Protection state does not prove recovery-key escrow; NEXTRIX does not manage recovery keys.',
            'This is not a security score. The counts are plain counts of reported states and must not be used as a rating.'
        )
        notes          = @('Feeds the P9 general-user health view and the NX16-017 support bundle. Read-only: no journal entry and no mutation.')
    }
}

# ============================================================================
# Rollback replay for non-registry NX14 target types
# ============================================================================

function Test-Nx14StringSetEqual {
    <# Case-insensitive set equality for CFR/allow-list comparisons. #>
    [CmdletBinding()]
    param([string[]]$A = @(), [string[]]$B = @())
    $sa = @($A | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $sb = @($B | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if ($sa.Count -ne $sb.Count) { return $false }
    for ($i = 0; $i -lt $sa.Count; $i++) {
        if (-not [string]::Equals($sa[$i], $sb[$i], [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function ConvertTo-Nx14ValueMap {
    <#
    .SYNOPSIS
        Normalises a journal-read descriptor map back into a hashtable.
    .DESCRIPTION
        Add-NxJournalEntry writes a hashtable, but ConvertFrom-Json returns a
        PSCustomObject on read-back (no .ContainsKey/.Keys). Rollback must not
        assume the in-memory shape, so every descriptor map is normalised here.
    #>
    [CmdletBinding()]
    param($Value)
    $map = @{}
    if ($null -eq $Value) { return $map }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) { $map[[string]$key] = $Value[$key] }
        return $map
    }
    if ($Value -is [psobject]) {
        foreach ($prop in @($Value.PSObject.Properties)) { $map[[string]$prop.Name] = $prop.Value }
    }
    return $map
}

function Invoke-Nx14Rollback {
    <#
    .SYNOPSIS
        NX14 delegated rollback for defenderPreference / optionalFeature /
        feature / processMitigation targets.
    .DESCRIPTION
        Same semantics as NxRollback: integrity-gated, reverse order,
        only-if-ours, every step journaled and verified. Registry targets are
        handled by the core engine and are not touched here. Restoration never
        lowers a protection beyond the exact state that existed before the NX14
        change; a target changed by someone else afterwards is reported diverged
        and left untouched.
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
    $supportedTypes = @('defenderPreference','optionalFeature','feature','processMitigation')
    $candidates = @($journal.entries | Where-Object {
        $_.operation -eq 'apply' -and
        ($_.result -eq 'InProgress' -or $_.result -eq 'Success' -or $_.result -eq 'Success-Irreversible') -and
        [string]$_.tweakId -like 'NX14-*' -and
        ($supportedTypes -contains [string]$_.original.targetType)
    })
    if (-not [string]::IsNullOrWhiteSpace($TweakId)) {
        $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId })
    }
    [array]::Reverse($candidates)

    $restored = New-Object System.Collections.Generic.List[object]
    $diverged = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($e in $candidates) {
        $orig = $e.original
        $mod = $e.modified
        $type = [string]$orig.targetType
        $targetKey = ''
        switch ($type) {
            'defenderPreference' { $targetKey = 'cfa|' + [string]$orig.name }
            'processMitigation' { $targetKey = 'pm|' + ([string]$orig.processName).ToLower() }
            default { $targetKey = $type + '|' + ([string]$orig.featureName).ToLower() }
        }
        if ($seen.ContainsKey($targetKey)) { continue }
        $seen[$targetKey] = $true

        try {
            switch ($type) {
                'defenderPreference' {
                    $live = Get-Nx14CfaSnapshot
                    if (-not $live.readSucceeded) {
                        $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; target = 'Controlled Folder Access'; reason = "preference could not be read ($($live.reason))" })
                        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo $live.reason -Profiles @($e.profiles)
                        break
                    }
                    $ours = ($live.modeValue -eq [int]$mod.modeValue) -and (Test-Nx14StringSetEqual -A @($live.allowedApplications) -B @($mod.allowedApplications))
                    if (-not $ours) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = 'Controlled Folder Access'; reason = 'live CFA mode/allow-list no longer equals the recorded post-change state - left untouched' })
                        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: CFA state differs from recorded modified state' -Profiles @($e.profiles)
                        break
                    }
                    $restore = Restore-Nx14CfaPreference -Original $orig
                    $after = Get-Nx14CfaSnapshot
                    $ok = ($after.readSucceeded -and $after.modeValue -eq [int]$orig.modeValue -and (Test-Nx14StringSetEqual -A @($after.allowedApplications) -B @($orig.allowedApplications)))
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo (($restore.actions) -join '; ') -Profiles @($e.profiles)
                    if ($ok) { $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored Controlled Folder Access mode/allow-list'; detail = (($restore.actions) -join '; '); verified = $true }) }
                    else { $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; target = 'Controlled Folder Access'; reason = 'restore re-read did not match the captured original' }) }
                }
                'optionalFeature' {
                    $live = Get-Nx14FeatureState -FeatureName $orig.featureName
                    if (-not $live.readSucceeded) {
                        $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $orig.featureName; reason = "feature state unreadable ($($live.reason))" })
                        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo $live.reason -Profiles @($e.profiles)
                        break
                    }
                    $pending = if ([string]$mod.state -eq 'Enabled') { 'EnablePending' } else { 'DisablePending' }
                    $ours = ([string]$live.state -eq [string]$mod.state -or [string]$live.state -eq $pending)
                    if (-not $ours) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $orig.featureName; reason = "live state '$($live.state)' is not the NEXTRIX-recorded '$($mod.state)' - left untouched" })
                        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: feature state differs from recorded modified state' -Profiles @($e.profiles)
                        break
                    }
                    $origState = [string]$orig.state
                    if ($origState -eq 'Enabled' -or $origState -eq 'Disabled') {
                        Set-Nx14FeatureStateRaw -FeatureName $orig.featureName -State $origState
                    } else {
                        throw "captured original feature state '$origState' cannot be restored automatically"
                    }
                    $after = Get-Nx14FeatureState -FeatureName $orig.featureName
                    $origPending = if ($origState -eq 'Enabled') { 'EnablePending' } else { 'DisablePending' }
                    $ok = ($after.readSucceeded -and ([string]$after.state -eq $origState -or [string]$after.state -eq $origPending))
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo "state now '$($after.state)'" -Profiles @($e.profiles)
                    if ($ok) { $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = "restored feature state $origState"; detail = $orig.featureName; verified = $true }) }
                    else { $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $orig.featureName; reason = "state after restore is '$($after.state)'" }) }
                }
                'feature' {
                    $live = Get-Nx14FeatureState -FeatureName $orig.featureName
                    if (-not $live.readSucceeded) {
                        $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $orig.featureName; reason = "feature state unreadable ($($live.reason))" })
                        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo $live.reason -Profiles @($e.profiles)
                        break
                    }
                    $pending = if ([string]$mod.state -eq 'Enabled') { 'EnablePending' } else { 'DisablePending' }
                    $ours = ([string]$live.state -eq [string]$mod.state -or [string]$live.state -eq $pending)
                    if (-not $ours) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $orig.featureName; reason = "live state '$($live.state)' is not the NEXTRIX-recorded '$($mod.state)' - left untouched" })
                        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: feature state differs from recorded modified state' -Profiles @($e.profiles)
                        break
                    }
                    $origState = [string]$orig.state
                    if ($origState -eq 'Enabled' -or $origState -eq 'Disabled') {
                        Set-Nx14FeatureStateRaw -FeatureName $orig.featureName -State $origState
                    } else {
                        throw "captured original feature state '$origState' cannot be restored automatically"
                    }
                    $after = Get-Nx14FeatureState -FeatureName $orig.featureName
                    $ok = ($after.readSucceeded -and [string]$after.state -eq $origState)
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo "state now '$($after.state)'" -Profiles @($e.profiles)
                    if ($ok) { $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = "restored feature state $origState"; detail = $orig.featureName; verified = $true }) }
                    else { $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $orig.featureName; reason = "state after restore is '$($after.state)'" }) }
                }
                'processMitigation' {
                    $live = Get-Nx14ProcessMitigationSnapshot -ProcessName $orig.processName
                    if (-not $live.available) {
                        $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $orig.processName; reason = "mitigation state unreadable ($($live.reason))" })
                        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo $live.reason -Profiles @($e.profiles)
                        break
                    }
                    # Journal read-back yields PSCustomObjects, not hashtables.
                    $origValues = ConvertTo-Nx14ValueMap -Value $orig.values
                    $modValues = ConvertTo-Nx14ValueMap -Value $mod.values
                    $ours = $true
                    foreach ($name in @($modValues.Keys)) {
                        $liveValue = $null
                        if ($live.values.ContainsKey($name)) { $liveValue = [int]$live.values[$name] }
                        if ($null -eq $liveValue -or $liveValue -ne [int]$modValues[$name]) { $ours = $false }
                    }
                    if (-not $ours) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $orig.processName; reason = 'live per-process mitigation values no longer equal the recorded post-change state - left untouched' })
                        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: mitigation values differ from recorded modified state' -Profiles @($e.profiles)
                        break
                    }
                    $removeNames = New-Object System.Collections.Generic.List[string]
                    foreach ($name in @($modValues.Keys)) {
                        $origValue = $null
                        if ($origValues.ContainsKey($name)) { $origValue = [int]$origValues[$name] }
                        if ($null -ne $origValue -and $origValue -eq 1) { continue }  # was already on before NEXTRIX
                        $removeNames.Add([string]$name)
                    }
                    if ($removeNames.Count -gt 0) {
                        Set-ProcessMitigation -Name $orig.processName -Remove $removeNames.ToArray() -ErrorAction Stop
                    }
                    $after = Get-Nx14ProcessMitigationSnapshot -ProcessName $orig.processName
                    $ok = $after.available
                    foreach ($name in @($modValues.Keys)) {
                        $targetValue = $null
                        if ($origValues.ContainsKey($name)) { $targetValue = [int]$origValues[$name] }
                        $liveValue = $null
                        if ($after.values.ContainsKey($name)) { $liveValue = [int]$after.values[$name] }
                        if ($null -eq $targetValue) {
                            if ($null -ne $liveValue -and $liveValue -ne 2) { $ok = $false }
                        } elseif ($null -eq $liveValue -or $liveValue -ne $targetValue) {
                            $ok = $false
                        }
                    }
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $(if ($removeNames.Count -gt 0) { 'removed: ' + ($removeNames -join ',') } else { 'no change needed' }) -Profiles @($e.profiles)
                    if ($ok) { $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'removed mitigations enabled by NEXTRIX'; detail = $orig.processName; verified = $true }) }
                    else { $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $orig.processName; reason = 'mitigation values after restore do not match the captured original' }) }
                }
            }
        } catch {
            $err = [string]$_.Exception.Message
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'failed' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles @($e.profiles)
            $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $targetKey; reason = $err })
        }
    }

    return [pscustomobject]@{
        aborted = $false; integrityErrors = @()
        restored = $restored.ToArray(); diverged = $diverged.ToArray(); failed = $failed.ToArray()
    }
}




