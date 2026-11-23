#Requires -Version 5.1
<#
    NX08.ps1 - NEXTRIX Input & Peripherals category functions (8 entries:
    NX08-001 .. NX08-008).

    Dependencies: dot-source AFTER the core modules (Import-NxCore order):
      NxJournal.ps1  -> Capture-NxRegistryValue, Add-NxJournalEntry, Read-NxManifest,
                        Get-NxSha256Hex
      NxVerify.ps1   -> Test-NxConfigurationState
      NxApply.ps1    -> Set-NxRegistryValue
      NxRollback.ps1 -> Restore-NxRegistryOriginal (best-effort restore on failed verify)
    This file defines functions only. Loading it performs no registry reads or writes,
    no service/CIM reads and no network access.

    Scope boundaries (catalogue XREF map):
      - USB selective suspend POLICY (per-plan, powercfg) is NX09-005. This module
        only INSPECTS USB/HID devices (NX08-007) so that decision is informed; it
        never writes selective-suspend policy or per-device power sweeps.
      - IRQ affinity / MSI mode is NX17. NX08-007 names controllers + instance IDs;
        it never writes MSI/interrupt state.
      - Full USB hardware inventory is NX20-007. NX08-007 is the controller/HID
        decision-support view only.
      - Bluetooth SERVICE startup (bthserv/BthAvctpSvc) is NX11-012. NX08-006 reports
        the service state read-only as a dependency signal and never changes it.
      - NX08-008 configures the UNDOCUMENTED mouclass/kbdclass data-queue depth
        (E0). It refuses values below the community-observed floor 16 and above the
        driver default 100, never creates a class-driver key, and makes no
        performance claim (the effect is unverified).
      - Mouse polling-rate "tuning" via kernel filter drivers (hidusbf and similar)
        is REJECTED: NEXTRIX ships no kernel drivers and never installs third-party
        ones. NX08-003 reports what Windows documents and says Unknown otherwise.

    Pipeline contract (NxApply.ps1, directive Section 8 - no exceptions):
      Capture-NxRegistryValue -> Add-NxJournalEntry -> mutate -> Test-NxConfigurationState
      -> Add-NxJournalEntry (result). Journal-first: no mutation without a preceding
      journal entry. Idempotent: an already-correct target journals a 'skip'
      (AlreadyApplied) and is never rewritten. Verification failures perform a
      best-effort restore of the exact recorded original, then journal 'failed'.
      Real application requires -Approved; -WhatIf plans only (no journal, no write).

    Honesty rules applied throughout:
      - No performance/latency/aim claims anywhere. Entries describe configuration
        intent, and the registry records the trade-offs.
      - No fabricated measurements: reports mark unreadable values Unknown and state
        the documented limit instead of inferring a number.
      - Device instance IDs are masked in reports (the trailing segment can encode a
        device serial); the journal still records exact paths for exact rollback.
#>

# ---------------------------------------------------------------------------
# A. Shared helpers (module-local; intentionally prefixed to avoid collisions)
# ---------------------------------------------------------------------------

function Test-Nx08JournalReady {
    # Journal-first gate: no mutation without an initialized, capture-Complete journal.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JournalRoot)
    $state = Read-NxManifest -Path $JournalRoot
    if (-not $state.present) {
        throw "journal not initialized at '$JournalRoot' - refusing to mutate (journal-first invariant; run the NX16 pre-flight first)"
    }
    if ([string]$state.manifest.captureStatus -ne 'Complete') {
        throw "journal captureStatus is '$($state.manifest.captureStatus)' - refusing to mutate unless capture is Complete"
    }
    return $true
}

function Invoke-Nx08JournaledRegistryWrite {
    <#
        Internal helper: the exact journaled registry pipeline with idempotent skip.
        Every mutating NX08 function routes its registry writes through here so the
        capture -> journal -> apply -> verify -> journal order exists in one place.
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
        [string[]]$Profiles = @(),
        [string]$DisplayTarget = ''
    )
    $target = "$Path :: $Name"
    $displayTarget = $(if ([string]::IsNullOrWhiteSpace($DisplayTarget)) { $target } else { $DisplayTarget })

    # Steps 2-6: read exact current state (read-only capture; kind and existence included).
    $orig = Capture-NxRegistryValue -Path $Path -Name $Name
    $modified = [pscustomobject]@{ targetType = 'registry'; path = $Path; name = $Name; kind = $Kind; value = $Value }

    if (-not $PSCmdlet.ShouldProcess($displayTarget, "Set $Kind to the intended value")) {
        return [pscustomobject]@{ target = $displayTarget; changed = $false; verified = $false; journalSeq = $null; planned = $true; reason = 'WhatIf/Confirm: no mutation, no journal write' }
    }

    # Idempotency: desired state already present -> record a skip, never rewrite.
    if ($orig.existed -and ([string]$orig.kind -eq $Kind)) {
        $existing = ConvertTo-Json -InputObject $orig.value -Depth 6 -Compress
        $desired  = ConvertTo-Json -InputObject $Value -Depth 6 -Compress
        if ($existing -eq $desired) {
            $skipJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $orig -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
            return [pscustomobject]@{ target = $displayTarget; changed = $false; verified = $true; journalSeq = $skipJournal.seq; planned = $false; reason = 'already in desired state' }
        }
    }

    # Step 7: journal BEFORE any mutation.
    $applyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $orig -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        # Step 8: apply.
        Set-NxRegistryValue -Path $Path -Name $Name -Kind $Kind -Value $Value
        # Step 9: verify the configuration effect only (never a performance question).
        $check = Test-NxConfigurationState -Path $Path -Name $Name -Kind $Kind -ExpectedValue $Value
        if ($check.verified) {
            $verifyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $orig -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles $Profiles
            return [pscustomobject]@{ target = $displayTarget; changed = $true; verified = $true; journalSeq = $applyJournal.seq; verifySeq = $verifyJournal.seq; planned = $false; reason = $check.reason }
        }
        # Safe stop: restore the exact recorded original, then journal the failure.
        try { Restore-NxRegistryOriginal -Entry ([pscustomobject]@{ original = $orig }) | Out-Null } catch { }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles
        return [pscustomobject]@{ target = $displayTarget; changed = $true; verified = $false; journalSeq = $applyJournal.seq; planned = $false; reason = $check.reason }
    } catch {
        $err = [string]$_.Exception.Message
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles
        return [pscustomobject]@{ target = $displayTarget; changed = $false; verified = $false; journalSeq = $applyJournal.seq; planned = $false; reason = "mutation failed: $err" }
    }
}

function Resolve-Nx08ReportPath {
    # Caller-chosen output folder only; never an implicit system location, never an
    # overwrite. Module-local (same contract as NX07/NX09) so NX08 loads alone.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$OutputFolder,
        [Parameter(Mandatory)][string]$FileName
    )
    if ([string]::IsNullOrWhiteSpace($OutputFolder)) {
        throw 'an output folder must be chosen (reports are never written to implicit system locations)'
    }
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $OutputFolder -PathType Container)) {
        throw "path '$OutputFolder' exists but is not a folder"
    }
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext  = [IO.Path]::GetExtension($FileName)
    if ([string]::IsNullOrEmpty($ext)) { $ext = '.json' }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $full = Join-Path $OutputFolder ("$base-$stamp$ext")
    if (Test-Path -LiteralPath $full) {
        throw "report file '$full' already exists - refusing to overwrite (timestamped names make this rare)"
    }
    return [pscustomobject]@{ folder = $OutputFolder; filePath = $full }
}

function ConvertTo-Nx08MaskedInstanceId {
    <#
        Reports must not leak device serials. A PnP instance ID is
        "<bus>\<hardware-id(s)>[\<instance-specific segment>]"; the trailing segment
        can encode a serial number, so only the bus + hardware-ID segment is kept.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$InstanceId)
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return '' }
    $parts = @($InstanceId.Trim() -split '\\')
    $keep = @()
    for ($i = 0; $i -lt $parts.Count -and $i -lt 2; $i++) {
        if (-not [string]::IsNullOrWhiteSpace($parts[$i])) { $keep += $parts[$i] }
    }
    if ($keep.Count -eq 0) { return '<unknown>' }
    return (($keep -join '\') + '\...')
}

function Get-Nx08InstanceIdKey {
    # Stable, non-reversible correlation key for a full instance ID (no serial kept).
    [CmdletBinding()]
    param([AllowEmptyString()][string]$InstanceId)
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return '' }
    $hex = Get-NxSha256Hex -Text $InstanceId
    return $hex.Substring(0, 16)
}

function Test-Nx08SafeInstanceId {
    # Defensive input validation for registry paths built from a device instance ID:
    # reject wildcard metacharacters so a crafted ID cannot widen a registry read/write.
    [CmdletBinding()]
    param([AllowEmptyString()][string]$InstanceId)
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $false }
    if ($InstanceId -match '[\[\]\*\?]') { return $false }
    if ($InstanceId -match '[\r\n]') { return $false }
    return $true
}

function Get-Nx08PnpSnapshot {
    <#
        Read-only PnP device snapshot from Win32_PnPEntity (documented CIM class).
        Returned fields are the ones the reports use; nothing is interpreted as a
        performance or capability claim.
    #>
    [CmdletBinding()]
    param()
    $items = New-Object System.Collections.Generic.List[object]
    $readError = ''
    try {
        foreach ($p in @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)) {
            $items.Add([pscustomobject]@{
                instanceId   = [string]$p.PNPDeviceID
                name         = [string]$p.Name
                className    = [string]$p.PNPClass
                status       = [string]$p.Status
                service      = [string]$p.Service
                manufacturer = [string]$p.Manufacturer
                hardwareIds  = @($p.HardwareID)
                classGuid    = [string]$p.ClassGuid
            })
        }
    } catch {
        $readError = [string]$_.Exception.Message
    }
    return [pscustomobject]@{ readOk = ($readError -eq ''); readError = $readError; devices = $items.ToArray() }
}

function ConvertFrom-Nx08BusHint {
    # Bus inference from the documented PnP instance-ID prefix (identity, not capability).
    [CmdletBinding()]
    param([AllowEmptyString()][string]$InstanceId)
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return 'Unknown' }
    if ($InstanceId -match '^(?i)USB\\') { return 'USB' }
    if ($InstanceId -match '^(?i)BTHENUM\\|^(?i)BTHLE\\') { return 'Bluetooth' }
    if ($InstanceId -match '^(?i)HID\\') { return 'HID' }
    if ($InstanceId -match '^(?i)ACPI\\') { return 'ACPI' }
    if ($InstanceId -match '^(?i)PCI\\') { return 'PCI' }
    if ($InstanceId -match '^(?i)ROOT\\|^(?i)SWD\\') { return 'Virtual' }
    return 'Unknown'
}

function Get-Nx08SignedDriverMap {
    # DeviceID -> signed driver info (Win32_PnPSignedDriver, documented). Read-only.
    [CmdletBinding()]
    param()
    $map = @{}
    try {
        foreach ($d in @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)) {
            $id = [string]$d.DeviceID
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $map[$id.ToLowerInvariant()] = [pscustomobject]@{
                driverVersion  = [string]$d.DriverVersion
                driverProvider = [string]$d.DriverProvider
                driverDate     = [string]$d.DriverDate
            }
        }
    } catch { }
    return $map
}

function Get-Nx08DriverInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DriverMap,
        [AllowEmptyString()][string]$InstanceId
    )
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $null }
    $key = $InstanceId.ToLowerInvariant()
    if ($DriverMap.ContainsKey($key)) { return $DriverMap[$key] }
    # Interface nodes (MI_xx) do not always carry their own signed-driver row;
    # fall back to a driver row for the same bus + hardware-ID segment only
    # (never a bare substring match, which could attribute the wrong driver).
    $parts = @($key -split '\\')
    if ($parts.Count -lt 2) { return $null }
    $prefix = $parts[0] + '\' + $parts[1] + '\'
    foreach ($k in $DriverMap.Keys) {
        if ($k.StartsWith($prefix)) { return $DriverMap[$k] }
    }
    return $null
}

function Read-Nx08DevicePowerValues {
    <#
        Read-only inspection of value PRESENCE under a device's Device Parameters key.
        The value names are community-known (E0 provenance, research r1/r3); they are
        reported verbatim and never written by NX08-007. NX09-005 owns the per-plan
        policy; NX08-006 owns the documented Bluetooth remote-wake values only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$InstanceId
    )
    $names = @(
        'SelectiveSuspendEnabled', 'SelectiveSuspendOn', 'EnhancedPowerManagementEnabled',
        'AllowIdleIrpInD3', 'DeviceSelectiveSuspended', 'D3ColdSupported',
        'WdfDirectedPowerTransitionEnable', 'EnableIdlePowerManagement',
        'WakeEnabled', 'RemoteWakeEnabled', 'DeviceRemoteWakeSupported'
    )
    $probes = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Nx08SafeInstanceId -InstanceId $InstanceId)) {
        return [pscustomobject]@{ readable = $false; keyPathMasked = ''; reason = 'unsafe or empty instance id - not probed'; values = @() }
    }
    $keyPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId\Device Parameters"
    $exists = $false
    try { $exists = Test-Path -LiteralPath $keyPath } catch { $exists = $false }
    if (-not $exists) {
        return [pscustomobject]@{ readable = $false; keyPathMasked = ((ConvertTo-Nx08MaskedInstanceId -InstanceId $InstanceId) + '\Device Parameters'); reason = 'Device Parameters key not present'; values = @() }
    }
    foreach ($n in $names) {
        $st = Capture-NxRegistryValue -Path $keyPath -Name $n
        $probes.Add([pscustomobject]@{ name = $n; present = [bool]$st.existed; kind = $st.kind; value = $st.value })
    }
    return [pscustomobject]@{
        readable      = $true
        keyPathMasked = ((ConvertTo-Nx08MaskedInstanceId -InstanceId $InstanceId) + '\Device Parameters')
        reason        = ''
        values        = $probes.ToArray()
    }
}

function Add-Nx08ReportJournalNote {
    # Report-only journal note (never an apply entry): proves the report ran without
    # implying any configuration change.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TweakId,
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [Parameter(Mandatory)][string]$ReportKind,
        [string]$JournalRoot = '',
        [string]$ReportPath = ''
    )
    if ([string]::IsNullOrWhiteSpace($JournalRoot)) { return }
    if (-not (Test-Path -LiteralPath $JournalRoot)) { return }
    $state = Read-NxManifest -Path $JournalRoot
    if (-not $state.present) { return }
    $record = [pscustomobject]@{
        targetType = 'inputDiagnostic'; changedConfiguration = $false
        reportKind = $ReportKind; reportPath = $ReportPath
    }
    Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $record -Modified $record -Result 'ReportOnly' -Verification 'Inspected' -Profiles $Profiles | Out-Null
}

function Write-Nx08ReportFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][string]$FileName
    )
    $path = Resolve-Nx08ReportPath -OutputFolder $OutputFolder -FileName $FileName
    $Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path.filePath -Encoding UTF8
    return $path.filePath
}

# ---------------------------------------------------------------------------
# B. Pointer configuration (NX08-001, NX08-002)
# ---------------------------------------------------------------------------

function Set-NxMouseAcceleration {
    <#
    .SYNOPSIS
        NX08-001: set the per-user pointer-acceleration triple (journaled, idempotent).
    .DESCRIPTION
        Writes HKCU\Control Panel\Mouse: MouseSpeed, MouseThreshold1,
        MouseThreshold2 as REG_SZ values (verified live: all three are String on
        Windows 11). MouseSpeed is the acceleration level documented by
        mouse_event/SystemParametersInfo SPI_GETMOUSE (0 = no acceleration; 1 and 2
        enable one/two threshold doublings). Thresholds are relative-motion
        distances in pixels and are inert while MouseSpeed is 0.
        Evidence honesty: the SPI/mouse_event semantics are documented (Microsoft),
        but the mapping of those settings to these registry value NAMES is
        community-known -> the registry entry is E0. Defaults are not asserted:
        callers pass explicit values, and rollback restores the captured originals.
        No performance/aim claim is made; this changes cursor mapping only.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId = 'NX08-001',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [ValidateRange(0,2)][int]$MouseSpeed = 0,
        [ValidateRange(0,2147483647)][int]$MouseThreshold1 = 0,
        [ValidateRange(0,2147483647)][int]$MouseThreshold2 = 0,
        [switch]$Approved
    )
    $mouseKey = 'HKCU:\Control Panel\Mouse'
    $plan = @(
        [pscustomobject]@{ name = 'MouseSpeed';      value = [string]$MouseSpeed }
        [pscustomobject]@{ name = 'MouseThreshold1'; value = [string]$MouseThreshold1 }
        [pscustomobject]@{ name = 'MouseThreshold2'; value = [string]$MouseThreshold2 }
    )
    $notes = New-Object System.Collections.Generic.List[string]
    $notes.Add('Per-user setting (HKCU); no administrator rights are used.')
    $notes.Add('Documented semantics: SystemParametersInfo SPI_GETMOUSE/SPI_SETMOUSE and mouse_event describe the acceleration level and two thresholds; the registry value names are community-known (E0).')
    $notes.Add('Windows may hold the previous pointer mapping for the current session; a sign-out/sign-in can be needed before every surface reflects it.')

    if (-not $PSCmdlet.ShouldProcess($mouseKey, "Set pointer acceleration (MouseSpeed=$MouseSpeed, thresholds $MouseThreshold1/$MouseThreshold2)")) {
        return [pscustomobject]@{
            tweakId = $TweakId; planned = $true; skipped = $false; failed = $false
            allVerified = $false; layers = @($plan | ForEach-Object { [pscustomobject]@{ target = "$mouseKey :: $($_.name)"; planned = $true; value = $_.value } })
            notes = $notes.ToArray()
        }
    }
    if (-not $Approved) {
        throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    Test-Nx08JournalReady -JournalRoot $JournalRoot | Out-Null

    $layers = New-Object System.Collections.Generic.List[object]
    foreach ($p in $plan) {
        $layers.Add((Invoke-Nx08JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $mouseKey -Name $p.name -Kind String -Value $p.value -Profiles $Profiles))
    }
    $failed = (@($layers.ToArray() | Where-Object { -not $_.verified }).Count -gt 0)
    return [pscustomobject]@{
        tweakId = $TweakId; planned = $false; skipped = $false; failed = $failed
        allVerified = (-not $failed); layers = $layers.ToArray(); notes = $notes.ToArray()
    }
}

function Set-NxMousePointerSpeed {
    <#
    .SYNOPSIS
        NX08-002: set the per-user pointer speed (journaled, idempotent).
    .DESCRIPTION
        Writes HKCU\Control Panel\Mouse :: MouseSensitivity (REG_SZ) to a value in
        the documented SystemParametersInfo SPI_GETMOUSESPEED range 1..20
        (1 = slowest, 20 = fastest; 10 is the documented default). The registry
        value-name mapping itself is community-known -> the entry is E0.
        This is a pointer-distance preference, not a DPI/mouse-firmware change:
        NEXTRIX never writes vendor driver or device configuration.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId = 'NX08-002',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [ValidateRange(1,20)][int]$MouseSensitivity = 10,
        [switch]$Approved
    )
    $mouseKey = 'HKCU:\Control Panel\Mouse'
    $notes = @(
        'Per-user setting (HKCU).',
        'Range 1..20 and the default of 10 are documented for SystemParametersInfo SPI_GETMOUSESPEED; the mapping to the MouseSensitivity value name is community-known (E0).',
        'No DPI, polling-rate or vendor driver state is touched; a sign-out/sign-in can be needed before every surface reflects the new speed.'
    )
    if (-not $PSCmdlet.ShouldProcess("$mouseKey :: MouseSensitivity", "Set pointer speed to $MouseSensitivity (documented range 1..20)")) {
        return [pscustomobject]@{
            tweakId = $TweakId; planned = $true; skipped = $false; failed = $false
            allVerified = $false; layers = @([pscustomobject]@{ target = "$mouseKey :: MouseSensitivity"; planned = $true; value = [string]$MouseSensitivity })
            notes = $notes
        }
    }
    if (-not $Approved) {
        throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    Test-Nx08JournalReady -JournalRoot $JournalRoot | Out-Null

    $layer = Invoke-Nx08JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $mouseKey -Name 'MouseSensitivity' -Kind String -Value ([string]$MouseSensitivity) -Profiles $Profiles
    return [pscustomobject]@{
        tweakId = $TweakId; planned = $false; skipped = $false; failed = (-not $layer.verified)
        allVerified = [bool]$layer.verified; layers = @($layer); notes = $notes
    }
}

# ---------------------------------------------------------------------------
# C. Keyboard configuration (NX08-004)
# ---------------------------------------------------------------------------

function Set-NxKeyboardRepeat {
    <#
    .SYNOPSIS
        NX08-004: set per-user keyboard repeat delay and rate (journaled, idempotent).
    .DESCRIPTION
        Writes HKCU\Control Panel\Keyboard :: KeyboardDelay (REG_SZ, documented
        range 0..3: 0 is about 250 ms, 3 is about 1 s) and KeyboardSpeed
        (REG_SZ, documented range 0..31: 0 is about 2.5 repetitions/second,
        31 is about 30 repetitions/second; rates are hardware-dependent and may
        deviate from a linear scale by up to 20% - SystemParametersInfo
        SPI_GETKEYBOARDDELAY / SPI_GETKEYBOARDSPEED). The value-name mapping is
        community-known; the value semantics are documented (E1).
        This is a text-entry preference; no input-latency claim is made.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateRange(0,3)][int]$KeyboardDelay,
        [Parameter(Mandatory)][ValidateRange(0,31)][int]$KeyboardSpeed,
        [string]$TweakId = 'NX08-004',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [switch]$Approved
    )
    $kbdKey = 'HKCU:\Control Panel\Keyboard'
    $plan = @(
        [pscustomobject]@{ name = 'KeyboardDelay'; value = [string]$KeyboardDelay }
        [pscustomobject]@{ name = 'KeyboardSpeed'; value = [string]$KeyboardSpeed }
    )
    $notes = @(
        'Per-user setting (HKCU).',
        'Documented ranges: delay 0 (~250 ms) .. 3 (~1 s); speed 0 (~2.5/s) .. 31 (~30/s), hardware-dependent (SystemParametersInfo SPI_GETKEYBOARDDELAY/SPI_GETKEYBOARDSPEED).',
        'Repeat behavior is a text-entry preference; accessibility features (Filter Keys/Sticky Keys) are not modified.',
        'A sign-out/sign-in can be needed before every surface reflects the new repeat settings.'
    )
    if (-not $PSCmdlet.ShouldProcess($kbdKey, "Set keyboard repeat (delay=$KeyboardDelay, speed=$KeyboardSpeed)")) {
        return [pscustomobject]@{
            tweakId = $TweakId; planned = $true; skipped = $false; failed = $false
            allVerified = $false; layers = @($plan | ForEach-Object { [pscustomobject]@{ target = "$kbdKey :: $($_.name)"; planned = $true; value = $_.value } })
            notes = $notes
        }
    }
    if (-not $Approved) {
        throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    Test-Nx08JournalReady -JournalRoot $JournalRoot | Out-Null

    $layers = New-Object System.Collections.Generic.List[object]
    foreach ($p in $plan) {
        $layers.Add((Invoke-Nx08JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $kbdKey -Name $p.name -Kind String -Value $p.value -Profiles $Profiles))
    }
    $failed = (@($layers.ToArray() | Where-Object { -not $_.verified }).Count -gt 0)
    return [pscustomobject]@{
        tweakId = $TweakId; planned = $false; skipped = $false; failed = $failed
        allVerified = (-not $failed); layers = $layers.ToArray(); notes = $notes
    }
}

# ---------------------------------------------------------------------------
# C2. Input class-driver data-queue sizes (NX08-008)
# ---------------------------------------------------------------------------

function Get-NxDataQueueState {
    <#
    .SYNOPSIS
        NX08-008 read-only: mouclass/kbdclass data-queue depth report.
    .DESCRIPTION
        Reports MouseDataQueueSize (mouclass) and KeyboardDataQueueSize (kbdclass)
        exactly as stored: present DWORD, present with another kind, or absent.
        Absent means the driver default 100 is in effect - a community-observed
        default (poolmon measurements / ReactOS registration), NOT a value Microsoft
        documents as user-tweakable. Entry sizes are documented structures:
        MOUSE_INPUT_DATA = 24 bytes (ntddmou.h), KEYBOARD_INPUT_DATA = 12 bytes
        (ntddkbd.h), so the default 100 corresponds to 2,400 / 1,200 bytes of
        nonpaged pool per device object. No mutation, no journal requirement.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputFolder = '',
        [string]$JournalRoot = '',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @()
    )
    $tweakId = 'NX08-008'
    $definitions = @(
        [pscustomobject]@{ device = 'Mouse';    path = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'; name = 'MouseDataQueueSize';    entrySizeBytes = 24 }
        [pscustomobject]@{ device = 'Keyboard'; path = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; name = 'KeyboardDataQueueSize'; entrySizeBytes = 12 }
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($d in $definitions) {
        $cap = Capture-NxRegistryValue -Path $d.path -Name $d.name
        $isDword = ([bool]$cap.existed -and [string]$cap.kind -eq 'DWord')
        $effective = $null
        $source = ''
        if ($isDword) {
            $effective = [int]$cap.value
            $source = 'registry value'
        } elseif ($cap.existed) {
            $source = 'value present with a non-DWORD kind - interpretation withheld (the class driver expects DWORD)'
        } else {
            $effective = 100
            $source = 'value absent - driver default 100 (community-observed; Microsoft does not document this parameter)'
        }
        $rows.Add([pscustomobject]@{
            device                  = $d.device
            keyPath                 = $d.path
            keyExisted              = [bool]$cap.keyExisted
            valueName               = $d.name
            present                 = [bool]$cap.existed
            kind                    = $cap.kind
            value                   = $cap.value
            effectiveQueueDepth     = $effective
            effectiveSource         = $source
            entrySizeBytes          = [int]$d.entrySizeBytes
            nonpagedPoolBytes       = $(if ($null -ne $effective) { [int]$effective * [int]$d.entrySizeBytes } else { $null })
            nonpagedPoolBytesAtDefault = (100 * [int]$d.entrySizeBytes)
            withinCommunityFloor    = $(if ($null -ne $effective) { ([int]$effective -ge 16) } else { $null })
        })
    }
    $report = [pscustomobject]@{
        readOnly          = $true
        noWritesPerformed = $true
        tweakId           = $tweakId
        generatedUtc      = (Get-Date).ToUniversalTime().ToString('o')
        values            = $rows.ToArray()
        limitations       = @(
            'MouseDataQueueSize/KeyboardDataQueueSize are undocumented as user-tweakable parameters; the names, default 100 and byte arithmetic are community-researched (djdallmann poolmon/ReactOS) plus documented structure sizes.',
            'No Microsoft-documented floor exists. 16 is a community claim only; community reports at 1 describe clicks/cursor keystrokes stopping until reboot.',
            'No independent benchmark exists for an input-latency effect; community sources contradict each other (the originating overclock.net thread calls the tweak placebo; the Nov 2026 xbitlabs article is recorded in TWEAK_RESEARCH.md section 16).',
            'The queue depth applies to every device using the class driver; vendor stacks that bypass kbdclass/mouclass are unaffected.',
            'Queue depth is configuration state, not a performance measurement; no verdict is derived.'
        )
        provenanceNote    = 'Default 100 is corroborated by community poolmon measurements and the ReactOS kbdclass registration table; Microsoft documents the structures and the class-driver architecture, not these values as user-tweakable.'
    }
    if ($OutputFolder) {
        $report | Add-Member -NotePropertyName reportPath -NotePropertyValue (Write-Nx08ReportFile -Report $report -OutputFolder $OutputFolder -FileName 'NEXTRIX-NX08-data-queue-state.json') -Force
    }
    Add-Nx08ReportJournalNote -JournalRoot $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -ReportKind 'inputDataQueueState' -ReportPath $(if ($report.PSObject.Properties['reportPath']) { $report.reportPath } else { '' })
    return $report
}

function Set-NxDataQueueSize {
    <#
    .SYNOPSIS
        NX08-008: set mouclass/kbdclass input data-queue depth (journaled, gated).
    .DESCRIPTION
        Writes MouseDataQueueSize under HKLM\SYSTEM\CurrentControlSet\Services\
        mouclass\Parameters and/or KeyboardDataQueueSize under ...\kbdclass\
        Parameters as DWORDs. Queue depth is in entries; entry sizes are the
        documented MOUSE_INPUT_DATA (24 bytes) and KEYBOARD_INPUT_DATA (12 bytes)
        structures, so 100 entries = 2,400/1,200 bytes of nonpaged pool per device.
        Range 16..100: values above 100 have no documented purpose and are refused;
        values below 16 are refused rather than clamped because 16 is a
        COMMUNITY-observed floor (Microsoft documents no floor) and community
        reports at 1 describe clicks/cursor keystrokes stopping until reboot.
        The parameter itself is undocumented as user-tweakable, so this entry is E0
        and makes no performance claim; the effect is unverified.
        Journal-first per value (capture -> journal -> write -> verify -> journal),
        idempotent skip, and safe-stop (application stops at the first failed
        layer). The class-driver Parameters keys must already exist; this function
        never creates them.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateSet('Mouse','Keyboard','Both')][string]$Device,
        # QueueSize is validated in the body rather than with ValidateRange so the
        # refusal can name the community floor and the click-loss report at 1.
        [Parameter(Mandatory)][int]$QueueSize,
        [string]$TweakId = 'NX08-008',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved
    )
    if ($QueueSize -lt 16) {
        throw "tweak ${TweakId}: queue size $QueueSize is below the community-observed floor of 16. Microsoft documents no floor for these undocumented class-driver parameters, and community reports at 1 describe clicks or cursor keystrokes stopping until reboot. NEXTRIX refuses rather than silently clamping."
    }
    if ($QueueSize -gt 100) {
        throw "tweak ${TweakId}: queue size $QueueSize is above the driver default of 100. This entry only reduces queue depth (range 16..100) and refuses larger values that have no documented purpose."
    }

    $targets = @()
    if ($Device -eq 'Mouse' -or $Device -eq 'Both') {
        $targets += [pscustomobject]@{ label = 'Mouse'; path = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'; name = 'MouseDataQueueSize' }
    }
    if ($Device -eq 'Keyboard' -or $Device -eq 'Both') {
        $targets += [pscustomobject]@{ label = 'Keyboard'; path = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'; name = 'KeyboardDataQueueSize' }
    }
    $available = @()
    $missingKeys = @()
    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t.path) { $available += $t } else { $missingKeys += $t.label }
    }
    $notes = @(
        'Undocumented as user-tweakable: default 100 is community-observed; Microsoft documents the class-driver architecture and structures, not this value.',
        'Range 16..100: the floor is a community claim (no Microsoft floor); queue depth below it, and especially 1, is associated in community reports with lost clicks.',
        'No performance effect is claimed; the configuration effect is verifiable but any latency effect is unverified (E0).',
        'A reboot is required for the class driver to read the new depth at device start.'
    )
    if ($available.Count -eq 0) {
        return [pscustomobject]@{
            tweakId = $TweakId; device = $Device; queueSize = $QueueSize
            planned = $false; skipped = $true; failed = $false; allVerified = $false
            layers = @(); missingKeys = $missingKeys
            notes = @($notes + 'None of the requested class-driver Parameters keys exists; nothing was written (this entry never creates a class-driver key).')
        }
    }
    if (-not $PSCmdlet.ShouldProcess(($available | ForEach-Object { $_.label }) -join '+', "Set input data-queue size to $QueueSize (range 16..100)")) {
        return [pscustomobject]@{
            tweakId = $TweakId; device = $Device; queueSize = $QueueSize
            planned = $true; skipped = $false; failed = $false; allVerified = $false
            layers = @($available | ForEach-Object { [pscustomobject]@{ target = "$($_.path) :: $($_.name)"; planned = $true; value = $QueueSize } })
            missingKeys = $missingKeys; notes = $notes
        }
    }
    if (-not $Approved) {
        throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    Test-Nx08JournalReady -JournalRoot $JournalRoot | Out-Null

    $layers = New-Object System.Collections.Generic.List[object]
    foreach ($t in $available) {
        $layer = Invoke-Nx08JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $t.path -Name $t.name -Kind DWord -Value $QueueSize -Profiles $Profiles
        $layers.Add($layer)
        if (-not $layer.verified) {
            $notes += "Stopped after a failed value ($($layer.target)); later planned writes were not attempted."
            break
        }
    }
    $all = $layers.ToArray()
    $failed = (@($all | Where-Object { -not $_.verified }).Count -gt 0)
    $complete = (@($all).Count -eq $available.Count)
    if (-not $complete -and -not $failed) {
        # Defensive: a stop without a failed layer would be a logic error; report it.
        $failed = $true
        $notes += 'Application did not cover every available target; reported as failed for safety.'
    }
    return [pscustomobject]@{
        tweakId = $TweakId; device = $Device; queueSize = $QueueSize
        planned = $false; skipped = $false; failed = $failed; allVerified = (-not $failed)
        layers = $all; missingKeys = $missingKeys; notes = $notes
    }
}

# ---------------------------------------------------------------------------
# D. Read-only inspection: mouse polling rate (NX08-003)
# ---------------------------------------------------------------------------

function Get-NxMousePollingRateReport {
    <#
    .SYNOPSIS
        NX08-003: read-only pointing-device report with honest polling-rate limits.
    .DESCRIPTION
        Windows exposes no documented user-mode API or WMI/CIM property that
        returns a USB HID polling rate. The endpoint interval (bInterval) lives in
        the USB descriptor; reading it requires raw descriptor access, and every
        scripted "polling rate" route observed in the reference projects is a
        third-party kernel filter driver (hidusbf) - REJECTED here (no kernel
        drivers, no unsigned/vendor-bundled driver installation).
        Therefore this report never fabricates a rate: per device it reports the
        documented identity surfaces (Win32_PointingDevice fields, bus hint from
        the PnP instance ID, signed-driver info) and marks the rate Unknown with
        the exact reason. No mutation, no journal requirement.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputFolder = '',
        [string]$JournalRoot = '',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @()
    )
    $tweakId = 'NX08-003'
    $driverMap = Get-Nx08SignedDriverMap
    $devices = New-Object System.Collections.Generic.List[object]
    $readError = ''
    try {
        foreach ($p in @(Get-CimInstance -ClassName Win32_PointingDevice -ErrorAction Stop)) {
            $id = [string]$p.PNPDeviceID
            $drv = Get-Nx08DriverInfo -DriverMap $driverMap -InstanceId $id
            $devices.Add([pscustomobject]@{
                instanceIdMasked      = (ConvertTo-Nx08MaskedInstanceId -InstanceId $id)
                instanceIdKey         = (Get-Nx08InstanceIdKey -InstanceId $id)
                reportedName          = [string]$p.Name
                hardwareType          = [string]$p.HardwareType
                numberOfButtons       = $p.NumberOfButtons
                pointingType          = $p.PointingType
                statusReported        = [string]$p.Status
                busHint               = (ConvertFrom-Nx08BusHint -InstanceId $id)
                driverVersion         = $(if ($drv) { $drv.driverVersion } else { '' })
                driverProvider        = $(if ($drv) { $drv.driverProvider } else { '' })
                pollingRateHz         = $null
                pollingRateAvailable  = $false
                pollingRateReason     = 'Windows documents no user-mode API or CIM property for USB HID polling rate; bInterval is a USB descriptor field. NEXTRIX refuses kernel filter drivers (e.g. hidusbf) and never infers a value.'
            })
        }
    } catch {
        $readError = [string]$_.Exception.Message
    }

    $report = [pscustomobject]@{
        readOnly            = $true
        noWritesPerformed   = $true
        tweakId             = $tweakId
        generatedUtc        = (Get-Date).ToUniversalTime().ToString('o')
        pointingDeviceCount = $devices.Count
        readSucceeded       = ($readError -eq '')
        readError           = $readError
        pollingRateAvailable = $false
        devices             = $devices.ToArray()
        limitations         = @(
            'Polling rate is not exposed by documented Windows user-mode surfaces; Win32_PointingDevice/Win32_PnPEntity carry identity, not the endpoint interval.',
            'The USB endpoint descriptor bInterval field requires raw USB descriptor access; the reference projects read/force it with a third-party kernel driver (hidusbf) - NEXTRIX ships no kernel drivers and installs none.',
            'Vendor utilities may display a configured polling rate; NEXTRIX neither queries nor changes vendor software or device firmware.',
            'NumberOfButtons/PointingType are reported verbatim; 0 may mean the driver does not populate the field (no interpretation is added).',
            'No latency, consistency or aim verdict is produced from this report.'
        )
        privacyNote         = 'PnP instance IDs are masked to bus + hardware ID; the trailing instance segment (which can encode a device serial) is not exported.'
    }
    if ($OutputFolder) {
        $report | Add-Member -NotePropertyName reportPath -NotePropertyValue (Write-Nx08ReportFile -Report $report -OutputFolder $OutputFolder -FileName 'NEXTRIX-NX08-mouse-polling-report.json') -Force
    }
    Add-Nx08ReportJournalNote -JournalRoot $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -ReportKind 'mousePollingInspection' -ReportPath $(if ($report.PSObject.Properties['reportPath']) { $report.reportPath } else { '' })
    return $report
}

# ---------------------------------------------------------------------------
# E. Read-only inspection: game controllers (NX08-005)
# ---------------------------------------------------------------------------

function Get-NxGameControllerReport {
    <#
    .SYNOPSIS
        NX08-005: read-only game-controller inspection with vendor-UI guidance.
    .DESCRIPTION
        Detection is deliberately narrow because naive "controller" matching also
        matches host/network/interrupt/memory controllers (observed on the
        reference machine). A device is reported only when its name matches the
        game-controller vocabulary (Xbox, gamepad, DualSense, DualShock, Joy-Con,
        Pro Controller, 8BitDo, Steam Controller, wheel/stick families) or its
        PnP class is a composite-controller class, AND it is not one of the
        excluded system-controller families.
        Windows has no documented system-wide deadzone setting: XInput dead-zone
        handling is per application (Microsoft's XInput guidance), and per-device
        deadzone/sensitivity is vendor-utility territory. This entry therefore
        inspects and guides; it never writes vendor drivers/software or device
        firmware, and it installs nothing.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputFolder = '',
        [string]$JournalRoot = '',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @()
    )
    $tweakId = 'NX08-005'
    $snapshot = Get-Nx08PnpSnapshot
    $driverMap = Get-Nx08SignedDriverMap

    $namePattern    = '(?i)(xbox|gamepad|game pad|dualsense|dualshock|joy-?con|pro controller|8bitdo|steam controller|thrustmaster|joystick|flight stick|racing wheel|razer (raiju|wolverine|kishi))'
    $excludePattern = '(?i)(host controller|interrupt controller|memory controller|network controller|family controller|storage controller|raid controller|gpio controller|embedded controller|dma controller|i2c controller|usb .*controller|extensible host|scsi|nvme|sata|pci express|root complex)'
    $compositeClasses = @('XnaComposite','XBOXComposite','XboxComposite','XBOXController','XboxController')

    $controllers = New-Object System.Collections.Generic.List[object]
    foreach ($d in @($snapshot.devices)) {
        $name = [string]$d.name
        $isComposite = ($compositeClasses -contains [string]$d.className)
        $nameMatch = ($name -match $namePattern)
        if (-not ($isComposite -or $nameMatch)) { continue }
        if ($name -match $excludePattern) { continue }
        $drv = Get-Nx08DriverInfo -DriverMap $driverMap -InstanceId ([string]$d.instanceId)
        $controllers.Add([pscustomobject]@{
            instanceIdMasked = (ConvertTo-Nx08MaskedInstanceId -InstanceId ([string]$d.instanceId))
            instanceIdKey    = (Get-Nx08InstanceIdKey -InstanceId ([string]$d.instanceId))
            reportedName     = $name
            className        = [string]$d.className
            statusReported   = [string]$d.status
            busHint          = (ConvertFrom-Nx08BusHint -InstanceId ([string]$d.instanceId))
            manufacturer     = [string]$d.manufacturer
            driverVersion    = $(if ($drv) { $drv.driverVersion } else { '' })
            driverProvider   = $(if ($drv) { $drv.driverProvider } else { '' })
            xinputHint       = ($name -match '(?i)xbox|xinput' -or [string]$d.instanceId -match '(?i)VID_045E' -or $isComposite)
        })
    }

    $report = [pscustomobject]@{
        readOnly             = $true
        noWritesPerformed    = $true
        tweakId              = $tweakId
        generatedUtc         = (Get-Date).ToUniversalTime().ToString('o')
        pnpReadSucceeded     = [bool]$snapshot.readOk
        pnpReadError         = [string]$snapshot.readError
        controllerCount      = $controllers.Count
        controllers          = $controllers.ToArray()
        configurationSupported = $false
        configurationNote    = 'No documented Windows system-wide controller deadzone/sensitivity setting exists; XInput dead-zone handling is per application. NEXTRIX writes no vendor driver, device or firmware state and installs no vendor software.'
        guidance             = @(
            'Per-device deadzone/sensitivity: use the vendor utility (for example the Xbox Accessories app for Xbox controllers, the matching vendor app for other brands).',
            'Per-game deadzone/sensitivity: use the in-game settings, or the launcher overlay mapping (e.g. Steam Input) where the owner already uses it.',
            'Windows-level inspection only: this report identifies the device, its bus and its driver; it changes nothing.'
        )
        detectionNote        = 'Controller detection is a name/class heuristic; unrelated system controllers (host/network/interrupt/memory) are explicitly excluded. A zero result is a valid outcome, and PnP presence is not a claim about XInput slots (XInput exposes up to four controllers per application).'
        privacyNote          = 'PnP instance IDs are masked to bus + hardware ID; trailing instance segments (possible serials) are not exported.'
    }
    if ($OutputFolder) {
        $report | Add-Member -NotePropertyName reportPath -NotePropertyValue (Write-Nx08ReportFile -Report $report -OutputFolder $OutputFolder -FileName 'NEXTRIX-NX08-game-controller-report.json') -Force
    }
    Add-Nx08ReportJournalNote -JournalRoot $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -ReportKind 'gameControllerInspection' -ReportPath $(if ($report.PSObject.Properties['reportPath']) { $report.reportPath } else { '' })
    return $report
}

# ---------------------------------------------------------------------------
# F. Bluetooth peripherals & documented power policy (NX08-006)
# ---------------------------------------------------------------------------

function Get-Nx08BluetoothInventory {
    <#
        Internal read-only inventory shared by the NX08-006 report and setter.
        Radios are Win32_PnPEntity rows with PNPClass 'Bluetooth'. Peripherals are
        BTHENUM\ / BTHLE\ enumerated devices. Per-radio documented remote-wake
        values are read from the device's Device Parameters key; the machine-level
        value is read from Bthport\Parameters. Nothing is written here.
    #>
    [CmdletBinding()]
    param()
    $snapshot = Get-Nx08PnpSnapshot
    $driverMap = Get-Nx08SignedDriverMap
    $radios = New-Object System.Collections.Generic.List[object]
    $otherBt = New-Object System.Collections.Generic.List[object]
    $peripherals = New-Object System.Collections.Generic.List[object]
    foreach ($d in @($snapshot.devices)) {
        $id = [string]$d.instanceId
        if ([string]$d.className -eq 'Bluetooth') {
            $transport = ConvertFrom-Nx08BusHint -InstanceId $id
            if ($transport -ne 'USB') {
                # Bluetooth-class software nodes (enumerators/protocol helpers) are
                # reported separately: the documented per-radio wake path is USB-specific.
                $otherBt.Add([pscustomobject]@{
                    instanceIdMasked = (ConvertTo-Nx08MaskedInstanceId -InstanceId $id)
                    instanceIdKey    = (Get-Nx08InstanceIdKey -InstanceId $id)
                    reportedName     = [string]$d.name
                    statusReported   = [string]$d.status
                    transportHint    = $transport
                })
                continue
            }
            $keyPath = ''
            $power = [pscustomobject]@{ readable = $false; reason = 'unsafe or empty instance id - not probed'; values = @() }
            if (Test-Nx08SafeInstanceId -InstanceId $id) {
                $keyPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id\Device Parameters"
                $power = Read-Nx08DevicePowerValues -InstanceId $id
            }
            $drv = Get-Nx08DriverInfo -DriverMap $driverMap -InstanceId $id
            $radios.Add([pscustomobject]@{
                instanceIdFull   = $id
                instanceIdMasked = (ConvertTo-Nx08MaskedInstanceId -InstanceId $id)
                instanceIdKey    = (Get-Nx08InstanceIdKey -InstanceId $id)
                friendlyName     = [string]$d.name
                statusReported   = [string]$d.status
                transportHint    = $transport
                driverVersion    = $(if ($drv) { $drv.driverVersion } else { '' })
                driverProvider   = $(if ($drv) { $drv.driverProvider } else { '' })
                deviceParametersKey = $keyPath
                deviceParametersReadable = [bool]$power.readable
                remoteWakeEnabled = @($power.values | Where-Object { $_.name -eq 'RemoteWakeEnabled' })
                deviceRemoteWakeSupported = @($power.values | Where-Object { $_.name -eq 'DeviceRemoteWakeSupported' })
                powerValuesReadable = [bool]$power.readable
                powerReadReason  = [string]$power.reason
            })
            continue
        }
        if ($id -match '^(?i)(BTHENUM|BTHLE)\\') {
            $drv = Get-Nx08DriverInfo -DriverMap $driverMap -InstanceId $id
            $peripherals.Add([pscustomobject]@{
                instanceIdMasked = (ConvertTo-Nx08MaskedInstanceId -InstanceId $id)
                instanceIdKey    = (Get-Nx08InstanceIdKey -InstanceId $id)
                reportedName     = [string]$d.name
                className        = [string]$d.className
                statusReported   = [string]$d.status
                driverVersion    = $(if ($drv) { $drv.driverVersion } else { '' })
                driverProvider   = $(if ($drv) { $drv.driverProvider } else { '' })
            })
        }
    }
    $machineRemoteWake = Capture-NxRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Bthport\Parameters' -Name 'SystemRemoteWakeSupported'
    $services = @()
    foreach ($n in @('bthserv','BthAvctpSvc')) {
        try {
            $s = Get-Service -Name $n -ErrorAction Stop
            $services += [pscustomobject]@{ name = [string]$s.Name; status = [string]$s.Status; startType = [string]$s.StartType }
        } catch {
            $services += [pscustomobject]@{ name = $n; status = 'NotFound'; startType = '' }
        }
    }
    return [pscustomobject]@{
        readSucceeded     = [bool]$snapshot.readOk
        readError         = [string]$snapshot.readError
        radios            = $radios.ToArray()
        otherBluetoothDevices = $otherBt.ToArray()
        bluetoothClassDeviceCount = ($radios.Count + $otherBt.Count)
        peripherals       = $peripherals.ToArray()
        machineRemoteWake = $machineRemoteWake
        services          = $services
    }
}

function Get-NxBluetoothPeripheralReport {
    <#
    .SYNOPSIS
        NX08-006 (read-only half): Bluetooth radios/peripherals and power surfaces.
    .DESCRIPTION
        Reports Bluetooth-class radios, BTHENUM/BTHLE peripherals, the Bluetooth
        Support Service state (read-only; startup type is NX11-012's territory),
        the documented machine-level remote-wake value, and each radio's documented
        per-device remote-wake values.
        Documentation basis: Microsoft Bluetooth FAQ documents remote wake for
        Bluetooth keyboards/mice (Bthport\Parameters SystemRemoteWakeSupported;
        per-radio Device Parameters RemoteWakeEnabled / DeviceRemoteWakeSupported).
        The Device Manager "Allow the computer to turn off this device to save
        power" checkbox has no Microsoft-documented registry contract; it is never
        written by NX08. No mutation, no journal requirement.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputFolder = '',
        [string]$JournalRoot = '',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @()
    )
    $tweakId = 'NX08-006'
    $inv = Get-Nx08BluetoothInventory

    $report = [pscustomobject]@{
        readOnly          = $true
        noWritesPerformed = $true
        tweakId           = $tweakId
        generatedUtc      = (Get-Date).ToUniversalTime().ToString('o')
        readSucceeded     = [bool]$inv.readSucceeded
        readError         = [string]$inv.readError
        bluetoothHardwarePresent = ([int]$inv.bluetoothClassDeviceCount -gt 0)
        radioCount        = @($inv.radios).Count
        bluetoothClassDeviceCount = [int]$inv.bluetoothClassDeviceCount
        otherBluetoothDeviceCount = @($inv.otherBluetoothDevices).Count
        otherBluetoothDevices = @($inv.otherBluetoothDevices)
        radios            = @($inv.radios | ForEach-Object {
            [pscustomobject]@{
                instanceIdMasked          = $_.instanceIdMasked
                instanceIdKey             = $_.instanceIdKey
                friendlyName              = $_.friendlyName
                statusReported            = $_.statusReported
                transportHint             = $_.transportHint
                documentedPerRadioPathApplicable = ([string]$_.transportHint -eq 'USB')
                driverVersion             = $_.driverVersion
                driverProvider            = $_.driverProvider
                deviceParametersReadable  = $_.deviceParametersReadable
                powerReadReason           = $_.powerReadReason
                remoteWakeEnabled         = @($_.remoteWakeEnabled)
                deviceRemoteWakeSupported = @($_.deviceRemoteWakeSupported)
            }
        })
        peripheralCount   = @($inv.peripherals).Count
        peripherals       = @($inv.peripherals)
        bluetoothServices = @($inv.services)
        machineRemoteWake = [pscustomobject]@{
            path    = 'HKLM:\SYSTEM\CurrentControlSet\Services\Bthport\Parameters'
            name    = 'SystemRemoteWakeSupported'
            keyExisted = [bool]$inv.machineRemoteWake.keyExisted
            existed = [bool]$inv.machineRemoteWake.existed
            kind    = $inv.machineRemoteWake.kind
            value   = $inv.machineRemoteWake.value
        }
        documentedPowerSurface = 'Microsoft Bluetooth FAQ: remote wake requires Bthport\Parameters SystemRemoteWakeSupported=1 and, per USB radio, Device Parameters RemoteWakeEnabled=1 and DeviceRemoteWakeSupported=1.'
        undocumentedSurface    = 'Device Manager per-device "Allow the computer to turn off this device to save power" has no Microsoft-documented registry contract; NX08 reports documented values only and never writes that checkbox surface.'
        xref              = 'Service startup (bthserv/BthAvctpSvc) is NX11-012; this entry reads it as a dependency signal and never changes it.'
        privacyNote       = 'PnP instance IDs are masked to bus + hardware ID; trailing instance segments (possible serials) are not exported.'
    }
    if ($OutputFolder) {
        $report | Add-Member -NotePropertyName reportPath -NotePropertyValue (Write-Nx08ReportFile -Report $report -OutputFolder $OutputFolder -FileName 'NEXTRIX-NX08-bluetooth-peripheral-report.json') -Force
    }
    Add-Nx08ReportJournalNote -JournalRoot $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -ReportKind 'bluetoothPeripheralInspection' -ReportPath $(if ($report.PSObject.Properties['reportPath']) { $report.reportPath } else { '' })
    return $report
}

function Set-NxBluetoothPowerPolicy {
    <#
    .SYNOPSIS
        NX08-006: documented Bluetooth remote-wake power policy (journaled, gated).
    .DESCRIPTION
        Detection gate: at least one Bluetooth-class radio must be present; with no
        radio the function skips gracefully and writes nothing.
        Policy surface is ONLY the Microsoft-documented remote-wake set:
          machine: HKLM\SYSTEM\CurrentControlSet\Services\Bthport\Parameters :: SystemRemoteWakeSupported (DWORD)
          per USB radio: <Enum>\<instance>\Device Parameters :: RemoteWakeEnabled,
                         DeviceRemoteWakeSupported (DWORD)
        Enable writes the documented policy values (machine
        SystemRemoteWakeSupported=1, per-radio RemoteWakeEnabled=1) and sets the
        DeviceRemoteWakeSupported capability flag only where the radio already
        declares it. Disable writes SystemRemoteWakeSupported=0 and
        RemoteWakeEnabled=0 and deliberately leaves DeviceRemoteWakeSupported (a
        capability declaration) untouched; the inverse of the documented "1" is
        policy-off semantics and is labeled as such.
        Nothing else is touched: no pairing data, no service startup (NX11-012), no
        vendor driver/firmware, and no blanket Enum power-value sweep.
        Trade-off (stated): with remote wake disabled, a Bluetooth keyboard/mouse
        can no longer wake the computer from sleep.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][ValidateSet('Enabled','Disabled')][string]$RemoteWake,
        [string]$TweakId = 'NX08-006',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved
    )
    # Read-only inventory first. Windows PowerShell 5.1 propagates -WhatIf into
    # module auto-loading (CimCmdlets prints Set-Alias WhatIf noise); suppress it
    # only for this local, read-only read and restore before ShouldProcess runs.
    $savedWhatIf = $WhatIfPreference
    $inv = $null
    try {
        $WhatIfPreference = $false
        $inv = Get-Nx08BluetoothInventory
    } finally {
        $WhatIfPreference = $savedWhatIf
    }
    $notes = New-Object System.Collections.Generic.List[string]
    $notes.Add('Documented surface: Microsoft Bluetooth FAQ (remote wake values). No pairing, service, vendor driver or firmware state is changed.')
    $notes.Add('NX11-012 owns Bluetooth service startup; this function only reads the service state as a dependency signal.')

    if (-not $inv.readSucceeded) {
        return [pscustomobject]@{
            tweakId = $TweakId; remoteWake = $RemoteWake; planned = $false; skipped = $true; failed = $false
            allVerified = $false; layers = @()
            notes = @($notes.ToArray() + "PnP read failed: $($inv.readError)")
            inspection = [pscustomobject]@{ radioCount = 0; bluetoothServices = @($inv.services) }
        }
    }
    if ([int]$inv.bluetoothClassDeviceCount -eq 0) {
        $notes.Add('No Bluetooth-class device detected: the detection gate skipped this tweak and wrote nothing.')
        return [pscustomobject]@{
            tweakId = $TweakId; remoteWake = $RemoteWake; planned = $false; skipped = $true; failed = $false
            allVerified = $false; layers = @(); notes = $notes.ToArray()
            inspection = [pscustomobject]@{ radioCount = 0; bluetoothServices = @($inv.services) }
        }
    }

    $machinePath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Bthport\Parameters'
    $plan = New-Object System.Collections.Generic.List[object]
    $unsupported = New-Object System.Collections.Generic.List[string]
    $perRadioPlanned = 0
    if ($RemoteWake -eq 'Enabled') {
        $plan.Add([pscustomobject]@{ path = $machinePath; display = "$machinePath :: SystemRemoteWakeSupported"; name = 'SystemRemoteWakeSupported'; value = 1 })
        foreach ($r in @($inv.radios)) {
            if ([string]$r.transportHint -ne 'USB') {
                $unsupported.Add("$($r.instanceIdMasked): radio is not USB-attached - the documented per-radio Device Parameters path applies to USB radios only; not written")
                continue
            }
            if (-not (Test-Nx08SafeInstanceId -InstanceId ([string]$r.instanceIdFull))) {
                $unsupported.Add("$($r.instanceIdMasked): instance id contains wildcard characters - not written")
                continue
            }
            if (-not $r.deviceParametersReadable) {
                $unsupported.Add("$($r.instanceIdMasked): Device Parameters key not readable - per-radio values not written")
                continue
            }
            $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($r.instanceIdFull)\Device Parameters"
            $displayKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($r.instanceIdMasked)\Device Parameters"
            $plan.Add([pscustomobject]@{ path = $key; display = "$displayKey :: RemoteWakeEnabled"; name = 'RemoteWakeEnabled'; value = 1 })
            $perRadioPlanned++
            # Capability declaration: only assert it where the radio already declares it.
            # Writing 1 to a radio that never declared wake support would fabricate a
            # capability; the documented recipe assumes the vendor verified support.
            $capabilityDeclared = (@($r.deviceRemoteWakeSupported | Where-Object { $_.present }).Count -gt 0)
            if ($capabilityDeclared) {
                $plan.Add([pscustomobject]@{ path = $key; display = "$displayKey :: DeviceRemoteWakeSupported"; name = 'DeviceRemoteWakeSupported'; value = 1 })
            } else {
                $unsupported.Add("$($r.instanceIdMasked): DeviceRemoteWakeSupported is not declared by the radio - capability flag left unset (support not verified)")
            }
        }
    } else {
        foreach ($r in @($inv.radios)) {
            if ([string]$r.transportHint -ne 'USB') {
                $unsupported.Add("$($r.instanceIdMasked): radio is not USB-attached - the documented per-radio Device Parameters path applies to USB radios only; not written")
                continue
            }
            if (-not (Test-Nx08SafeInstanceId -InstanceId ([string]$r.instanceIdFull))) {
                $unsupported.Add("$($r.instanceIdMasked): instance id contains wildcard characters - not written")
                continue
            }
            if (-not $r.deviceParametersReadable) {
                $unsupported.Add("$($r.instanceIdMasked): Device Parameters key not readable - per-radio values not written")
                continue
            }
            $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($r.instanceIdFull)\Device Parameters"
            $displayKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($r.instanceIdMasked)\Device Parameters"
            $plan.Add([pscustomobject]@{ path = $key; display = "$displayKey :: RemoteWakeEnabled"; name = 'RemoteWakeEnabled'; value = 0 })
            $perRadioPlanned++
        }
        $plan.Add([pscustomobject]@{ path = $machinePath; display = "$machinePath :: SystemRemoteWakeSupported"; name = 'SystemRemoteWakeSupported'; value = 0 })
    }

    if ($RemoteWake -eq 'Enabled' -and $perRadioPlanned -eq 0) {
        $notes.Add('Enable requires the documented per-radio values on a USB-attached radio; none could be targeted, so nothing was written (a machine-level flag alone would be an incomplete documented recipe).')
        return [pscustomobject]@{
            tweakId = $TweakId; remoteWake = $RemoteWake; planned = $false; skipped = $true; failed = $false
            allVerified = $false; layers = @(); notes = $notes.ToArray()
            unsupported = $unsupported.ToArray()
            inspection = [pscustomobject]@{ radioCount = @($inv.radios).Count; bluetoothClassDeviceCount = [int]$inv.bluetoothClassDeviceCount; bluetoothServices = @($inv.services) }
        }
    }
    if ($plan.Count -eq 0) {
        $notes.Add('No documented value could be targeted (no safe/readable radio Device Parameters key): nothing was written.')
        return [pscustomobject]@{
            tweakId = $TweakId; remoteWake = $RemoteWake; planned = $false; skipped = $true; failed = $false
            allVerified = $false; layers = @(); notes = $notes.ToArray()
            unsupported = $unsupported.ToArray()
            inspection = [pscustomobject]@{ radioCount = @($inv.radios).Count; bluetoothClassDeviceCount = [int]$inv.bluetoothClassDeviceCount; bluetoothServices = @($inv.services) }
        }
    }

    if (-not $PSCmdlet.ShouldProcess('Bluetooth remote-wake policy', "Set remote wake to $RemoteWake for $($plan.Count) documented value(s)")) {
        return [pscustomobject]@{
            tweakId = $TweakId; remoteWake = $RemoteWake; planned = $true; skipped = $false; failed = $false
            allVerified = $false
            layers = @($plan | ForEach-Object { [pscustomobject]@{ target = [string]$_.display; planned = $true; value = $_.value } })
            notes = $notes.ToArray(); unsupported = $unsupported.ToArray()
            inspection = [pscustomobject]@{ radioCount = @($inv.radios).Count; bluetoothClassDeviceCount = [int]$inv.bluetoothClassDeviceCount; bluetoothServices = @($inv.services) }
        }
    }
    if (-not $Approved) {
        throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    Test-Nx08JournalReady -JournalRoot $JournalRoot | Out-Null

    $layers = New-Object System.Collections.Generic.List[object]
    foreach ($p in $plan) {
        $layer = Invoke-Nx08JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $p.path -Name $p.name -Kind DWord -Value $p.value -Profiles $Profiles -DisplayTarget ([string]$p.display)
        $layers.Add($layer)
        if (-not $layer.verified) {
            # Safe stop: a half-applied wake policy must not continue into broader
            # writes; every completed layer is still journaled for exact rollback.
                    $notes.Add("Stopped after a failed value ($($layer.target)); later planned writes were not attempted. Rollback can restore the journaled originals.")
            break
        }
    }
    $failed = (@($layers.ToArray() | Where-Object { -not $_.verified }).Count -gt 0)
    if ($RemoteWake -eq 'Disabled') {
        $notes.Add('DeviceRemoteWakeSupported (a documented capability declaration) was deliberately left unchanged on disable.')
    } else {
        $notes.Add('Enable writes the documented policy values (machine SystemRemoteWakeSupported and per-radio RemoteWakeEnabled); the DeviceRemoteWakeSupported capability flag is only set where the radio already declares it.')
    }
    $notes.Add('The radio stack reads the wake flags at device start; a reboot (or radio re-enumeration) is the reliable way to apply the policy to subsequent sleep cycles.')
    if (@($unsupported).Count -gt 0) { $notes.Add('Some radios were skipped; see unsupported entries.') }
    return [pscustomobject]@{
        tweakId = $TweakId; remoteWake = $RemoteWake; planned = $false; skipped = $false; failed = $failed
        allVerified = (-not $failed); layers = $layers.ToArray(); notes = $notes.ToArray()
        unsupported = $unsupported.ToArray()
        inspection = [pscustomobject]@{ radioCount = @($inv.radios).Count; bluetoothClassDeviceCount = [int]$inv.bluetoothClassDeviceCount; bluetoothServices = @($inv.services) }
    }
}

# ---------------------------------------------------------------------------
# G. Read-only inspection: USB controllers & HID devices (NX08-007)
# ---------------------------------------------------------------------------

function Get-NxUsbHidReport {
    <#
    .SYNOPSIS
        NX08-007: read-only USB controller + HID device inspection (decision support).
    .DESCRIPTION
        Documented surfaces: Win32_USBController (controllers), Win32_PnPEntity
        (USB-enumerated devices and HIDClass nodes), Win32_USBControllerDevice
        (controller/device association), Win32_PnPSignedDriver (driver info).
        For every HID node the report lists which per-device power value NAMES are
        present under Device Parameters (community-known names; reported verbatim,
        never written). This feeds NX09-005's per-plan selective-suspend decision
        and NX17's controller/interrupt work; it does not perform either change and
        does not duplicate NX20-007's full USB hardware inventory.
        Documentation honesty: Microsoft's USB selective-suspend page says
        selective suspend is enabled by default and strongly recommends not
        disabling it, while the HID-over-USB page says it is disabled by default to
        avoid resume latency. Both are reported; no verdict is derived.
        No mutation, no journal requirement.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputFolder = '',
        [string]$JournalRoot = '',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @()
    )
    $tweakId = 'NX08-007'
    $snapshot = Get-Nx08PnpSnapshot
    $driverMap = Get-Nx08SignedDriverMap

    # Controllers (documented CIM class).
    $controllers = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($c in @(Get-CimInstance -ClassName Win32_USBController -ErrorAction Stop)) {
            $drv = Get-Nx08DriverInfo -DriverMap $driverMap -InstanceId ([string]$c.DeviceID)
            $controllers.Add([pscustomobject]@{
                name           = [string]$c.Name
                deviceIdMasked = (ConvertTo-Nx08MaskedInstanceId -InstanceId ([string]$c.DeviceID))
                statusReported = [string]$c.Status
                driverVersion  = $(if ($drv) { $drv.driverVersion } else { '' })
                driverProvider = $(if ($drv) { $drv.driverProvider } else { '' })
            })
        }
    } catch { }

    # Controller -> device associations (documented association class; read-only).
    $associations = @()
    try {
        $associations = @(Get-CimInstance -ClassName Win32_USBControllerDevice -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                controllerDeviceIdMasked = (ConvertTo-Nx08MaskedInstanceId -InstanceId ([string]$_.Antecedent.DeviceID))
                deviceIdMasked           = (ConvertTo-Nx08MaskedInstanceId -InstanceId ([string]$_.Dependent.DeviceID))
            }
        })
    } catch { }

    $usbDevices = New-Object System.Collections.Generic.List[object]
    $hidDevices = New-Object System.Collections.Generic.List[object]
    foreach ($d in @($snapshot.devices)) {
        $id = [string]$d.instanceId
        if ($id -match '^(?i)USB\\') {
            $drv = Get-Nx08DriverInfo -DriverMap $driverMap -InstanceId $id
            $usbDevices.Add([pscustomobject]@{
                instanceIdMasked = (ConvertTo-Nx08MaskedInstanceId -InstanceId $id)
                instanceIdKey    = (Get-Nx08InstanceIdKey -InstanceId $id)
                reportedName     = [string]$d.name
                className        = [string]$d.className
                statusReported   = [string]$d.status
                service          = [string]$d.service
                driverVersion    = $(if ($drv) { $drv.driverVersion } else { '' })
                driverProvider   = $(if ($drv) { $drv.driverProvider } else { '' })
            })
        }
        if ([string]$d.className -eq 'HIDClass') {
            $drv = Get-Nx08DriverInfo -DriverMap $driverMap -InstanceId $id
            $power = Read-Nx08DevicePowerValues -InstanceId $id
            $present = @($power.values | Where-Object { $_.present })
            $hidDevices.Add([pscustomobject]@{
                instanceIdMasked = (ConvertTo-Nx08MaskedInstanceId -InstanceId $id)
                instanceIdKey    = (Get-Nx08InstanceIdKey -InstanceId $id)
                reportedName     = [string]$d.name
                statusReported   = [string]$d.status
                busHint          = (ConvertFrom-Nx08BusHint -InstanceId $id)
                driverVersion    = $(if ($drv) { $drv.driverVersion } else { '' })
                driverProvider   = $(if ($drv) { $drv.driverProvider } else { '' })
                powerValuesReadable = [bool]$power.readable
                powerReadReason   = [string]$power.reason
                powerValueNamesPresent = @($present | ForEach-Object { $_.name })
                powerValues       = @($present)
            })
        }
    }

    $report = [pscustomobject]@{
        readOnly            = $true
        noWritesPerformed   = $true
        tweakId             = $tweakId
        generatedUtc        = (Get-Date).ToUniversalTime().ToString('o')
        readSucceeded       = [bool]$snapshot.readOk
        readError           = [string]$snapshot.readError
        controllerCount     = $controllers.Count
        controllers         = $controllers.ToArray()
        controllerAssociations = $associations
        usbDeviceCount      = $usbDevices.Count
        usbDevices          = $usbDevices.ToArray()
        hidDeviceCount      = $hidDevices.Count
        hidDevices          = $hidDevices.ToArray()
        feeds               = @(
            'NX09-005 (USB selective suspend policy): per-device power-value presence informs the plan-level decision; NX08 does not write policy.',
            'NX17 (IRQ affinity / MSI mode): controller/device identity is the input set; NX08 does not write interrupt state.',
            'NX20-007 (USB hardware inventory): owns the full inventory; this report is the controller/HID decision-support view only.'
        )
        documentationNote   = 'Microsoft documents conflicting defaults: the USB selective-suspend page states it is enabled by default and strongly recommends not disabling it; the HID-over-USB page states it is disabled by default to avoid resume latency. Both are recorded without a verdict.'
        provenanceNote      = 'Per-device power value NAMES are community-known (research r1/r3) and are reported read-only; documented CIM classes provide the device/controller identity.'
        boundaries          = @(
            'No device is disabled, enabled or reconfigured.',
            'No selective-suspend/plan power value is written (NX09-005 owns policy).',
            'No MSI/interrupt/affinity value is written (NX17 owns that).',
            'No driver is installed, updated or removed.',
            'No kernel driver is loaded.'
        )
        privacyNote         = 'PnP instance IDs are masked to bus + hardware ID; trailing instance segments (possible serials) are not exported.'
    }
    if ($OutputFolder) {
        $report | Add-Member -NotePropertyName reportPath -NotePropertyValue (Write-Nx08ReportFile -Report $report -OutputFolder $OutputFolder -FileName 'NEXTRIX-NX08-usb-hid-report.json') -Force
    }
    Add-Nx08ReportJournalNote -JournalRoot $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -ReportKind 'usbHidInspection' -ReportPath $(if ($report.PSObject.Properties['reportPath']) { $report.reportPath } else { '' })
    return $report
}
