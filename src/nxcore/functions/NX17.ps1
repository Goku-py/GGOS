#Requires -Version 5.1
<#
    NX17.ps1 - NEXTRIX Advanced Windows Configuration category functions
    (NX17-001 .. NX17-014).

    Dependencies: dot-source AFTER the core modules (the order the generated
    playbook loader and Import-NxCore use):
      NxJournal.ps1  -> Capture-NxRegistryValue, Add-NxJournalEntry
      NxVerify.ps1   -> Test-NxConfigurationState
      NxApply.ps1    -> Set-NxRegistryValue
      NxRollback.ps1 -> Restore-NxRegistryOriginal (best-effort restore on failed verify)
    This file defines functions only. Loading it performs no registry reads or writes,
    no BCD queries, no device queries, no service queries and no network access.

    CATEGORY SAFETY POSTURE (deliberate, and the reason most entries are Defined):
      - BCD is written by NOTHING in this file. Microsoft's own BCDEdit reference
        warns that a /set can render the computer inoperable and that BitLocker and
        Secure Boot may need to be suspended first. NEXTRIX therefore ships read-only
        BCD state capture plus exact documented procedures (NX17-002/-003/-005) and
        leaves the write to the owner, under explicit consent, with a recovery path.
      - Per-device MSI / interrupt-affinity is INSPECTION ONLY here. The per-device
        registry values (MSISupported, DevicePolicy, DevicePriority,
        AssignmentSetOverride) are not documented public contracts, and a wrong write
        can destabilise a device. A per-device write needs per-instance consent, a
        reboot and a device-stability gate that this engine does not have, so the
        mutation stays Defined (NX17-006/-007).
      - No mitigation masks. This file never reads or writes MitigationOptions,
        MitigationAuditOptions, FeatureSettingsOverride or FeatureSettingsOverrideMask
        (registry/schema.json banned targets; r2/r4 all-2s finding).
      - No blanket BCD writer, no global MSI switch, no HPET/platform-clock forcing.
      - Every mutating function here is journal-first, idempotent, verifies its own
        write and restores the exact recorded original on a failed verification.
      - No function in this file makes a performance claim. Configuration intent and
        documented behavior only; outcomes stay PENDING until owner evidence (E2+).
#>

# ---------------------------------------------------------------------------
# Read-only helpers
# ---------------------------------------------------------------------------

function Get-Nx17ValueState {
    <#
    .SYNOPSIS
        Read-only capture of one registry value, literal-path safe.
    .DESCRIPTION
        Same descriptor shape as NxJournal's Capture-NxRegistryValue (keyExisted,
        existed, kind, value) but using -LiteralPath, because per-device Enum paths
        contain characters (&, {, }, .) that must never be treated as wildcards.
        Never creates, writes or deletes anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    $descriptor = [ordered]@{
        path       = $Path
        name       = $Name
        keyExisted = $false
        existed    = $false
        kind       = $null
        value      = $null
    }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]$descriptor }
        $descriptor.keyExisted = $true
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $raw = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $raw) { return [pscustomobject]$descriptor }
        $descriptor.existed = $true
        $descriptor.kind = $key.GetValueKind($Name).ToString()
        $descriptor.value = $raw
    } catch {
        # Unreadable is reported as not-read, never guessed (uncertainty pattern).
        $descriptor['readError'] = [string]$_.Exception.Message
    }
    return [pscustomobject]$descriptor
}

function ConvertFrom-Nx17BcdEnumText {
    <#
    .SYNOPSIS
        Pure parser for `bcdedit /enum` text (no execution, no mutation).
    .DESCRIPTION
        Returns one note property per BCD element found, lower-cased element name to
        trimmed string value. Section titles and separator lines are ignored. The
        parser works on element names, which are stable ASCII identifiers; localized
        section titles do not affect it. Duplicate element names keep the first
        occurrence. Values are returned as text, not coerced, so a caller can tell
        "Yes"/"No"/"Standard"/"Legacy" apart without inventing a default.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $map = [ordered]@{}
    foreach ($line in ($Text -split "\r?\n")) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0) { continue }
        if ($trimmed -match '^-{3,}$') { continue }
        # Element lines start at column 0 and separate name/value with 2+ spaces
        # (bcdedit pads with a tab). Indented continuation lines and headers fall through.
        if ($trimmed -notmatch '^(?<name>[A-Za-z0-9_:\.\{\}\-]+)[\t ]{2,}(?<value>\S.*)$') { continue }
        $name = $Matches['name'].ToLowerInvariant()
        if ($map.Contains($name)) { continue }
        $map[$name] = $Matches['value'].Trim()
    }
    $obj = New-Object psobject
    foreach ($k in $map.Keys) {
        $obj | Add-Member -NotePropertyName $k -NotePropertyValue $map[$k]
    }
    return $obj
}

function Get-Nx17BcdElements {
    <#
    .SYNOPSIS
        Read-only `bcdedit /enum <entry>` capture and parse.
    .DESCRIPTION
        Executes ONLY the read-only /enum form. A write is never issued by this file.
        Non-elevated sessions usually receive "Access is denied"; that is reported as
        readSucceeded=false with the tool's own text, never swallowed and never
        retried through another mechanism. The raw text is returned only when the
        caller explicitly asks for it (it can contain machine-specific identifiers).
    #>
    [CmdletBinding()]
    param(
        [string]$Entry = '{current}',
        [switch]$IncludeRawText
    )
    $result = [ordered]@{
        readSucceeded = $false
        entry         = $Entry
        elements      = $null
        rawText       = $null
        error         = $null
    }
    $exe = Join-Path $env:SystemRoot 'System32\bcdedit.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        $result.error = 'bcdedit.exe not found under %SystemRoot%\System32 (unexpected on Windows 11)'
        return [pscustomobject]$result
    }
    try {
        $output = & $exe /enum $Entry 2>&1
        $exitCode = $LASTEXITCODE
        $text = (@($output) | ForEach-Object { [string]$_ }) -join "`r`n"
        if ($exitCode -ne 0) {
            $result.error = "bcdedit /enum $Entry exited $exitCode : $($text.Trim())"
            return [pscustomobject]$result
        }
        $result.elements = ConvertFrom-Nx17BcdEnumText -Text $text
        $result.readSucceeded = $true
        if ($IncludeRawText) { $result.rawText = $text }
    } catch {
        $result.error = [string]$_.Exception.Message
    }
    return [pscustomobject]$result
}

function Get-Nx17BcdElementState {
    <#
    .SYNOPSIS
        Read-only presence/value probe for one element of one BCD store entry.
    .DESCRIPTION
        Distinguishes "element absent" (Windows default applies and rollback would be
        a /deletevalue) from "element present with value" (rollback restores that
        exact value). Absent is NOT reported as "off".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$BcdResult,
        [Parameter(Mandatory)][string]$ElementName
    )
    $state = [ordered]@{
        element   = $ElementName
        present   = $false
        value     = $null
        bcdRead   = [bool]$BcdResult.readSucceeded
        error     = $BcdResult.error
    }
    if (-not $BcdResult.readSucceeded -or $null -eq $BcdResult.elements) {
        $state.value = 'Unknown'
        return [pscustomobject]$state
    }
    $prop = $BcdResult.elements.PSObject.Properties[$ElementName.ToLowerInvariant()]
    if ($null -ne $prop) {
        $state.present = $true
        $state.value = [string]$prop.Value
    }
    return [pscustomobject]$state
}

function Get-Nx17HpetDeviceState {
    <#
    .SYNOPSIS
        Read-only presence/status probe for the ACPI High Precision Event Timer device.
    .DESCRIPTION
        Uses Get-PnpDevice -PresentOnly only (a query). Nothing is disabled, enabled,
        restarted or written. Availability is reported explicitly: missing cmdlets or
        a denied query produce probeAvailable=false + error, never a guessed "absent".
    #>
    [CmdletBinding()]
    param()
    $state = [ordered]@{
        probeAvailable = $false
        present        = $false
        friendlyName   = $null
        instanceId     = $null
        status         = $null
        error          = $null
    }
    if ($null -eq (Get-Command -Name 'Get-PnpDevice' -ErrorAction SilentlyContinue)) {
        $state.error = 'Get-PnpDevice is not available in this session'
        return [pscustomobject]$state
    }
    try {
        $present = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
        $state.probeAvailable = $true
        $hpet = @($present | Where-Object {
            [string]$_.FriendlyName -match '(?i)high\s*precision\s*event\s*timer' -or [string]$_.InstanceId -match '(?i)PNP0103'
        })
        if ($hpet.Count -gt 0) {
            $state.present = $true
            $state.friendlyName = [string]$hpet[0].FriendlyName
            $state.instanceId = [string]$hpet[0].InstanceId
            $state.status = [string]$hpet[0].Status
        }
    } catch {
        $state.error = [string]$_.Exception.Message
    }
    return [pscustomobject]$state
}

function Get-Nx17PciInterruptInventory {
    <#
    .SYNOPSIS
        Internal read-only inventory of per-device MSI and interrupt-affinity values.
    .DESCRIPTION
        For every present PCI device (or only the caller-supplied instance id), reads:
          ...\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties :: MSISupported
          ...\Device Parameters\Interrupt Management\Affinity Policy :: DevicePolicy / DevicePriority / AssignmentSetOverride
        All reads are value-presence aware and literal-path safe. No device property is
        written; no device is restarted. When -InstanceId is supplied the device
        enumeration is skipped entirely (used by the self-test, which must not touch
        devices on the host).
    #>
    [CmdletBinding()]
    param([string]$InstanceId)
    $devices = New-Object System.Collections.Generic.List[object]
    $enumerationError = $null
    $enumerationSkipped = $false
    $meta = @{}
    $ids = @()

    if (-not [string]::IsNullOrWhiteSpace($InstanceId)) {
        $enumerationSkipped = $true
        $ids = @($InstanceId)
    } elseif ($null -eq (Get-Command -Name 'Get-PnpDevice' -ErrorAction SilentlyContinue)) {
        $enumerationError = 'Get-PnpDevice is not available - PCI device enumeration skipped'
    } else {
        try {
            $pnp = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { [string]$_.InstanceId -like 'PCI\*' })
            foreach ($d in $pnp) {
                $id = [string]$d.InstanceId
                $ids += $id
                $meta[$id.ToLowerInvariant()] = [pscustomobject]@{
                    friendlyName = [string]$d.FriendlyName
                    className    = [string]$d.Class
                    status       = [string]$d.Status
                }
            }
        } catch {
            $enumerationError = [string]$_.Exception.Message
        }
    }

    foreach ($id in $ids) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $base = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id"
        $deviceDesc = Get-Nx17ValueState -Path $base -Name 'DeviceDesc'
        $service = Get-Nx17ValueState -Path $base -Name 'Service'
        $interruptRoot = "$base\Device Parameters\Interrupt Management"
        $msiPath = "$interruptRoot\MessageSignaledInterruptProperties"
        $affinityPath = "$interruptRoot\Affinity Policy"
        $msiSupported = Get-Nx17ValueState -Path $msiPath -Name 'MSISupported'
        $devicePolicy = Get-Nx17ValueState -Path $affinityPath -Name 'DevicePolicy'
        $devicePriority = Get-Nx17ValueState -Path $affinityPath -Name 'DevicePriority'
        $override = Get-Nx17ValueState -Path $affinityPath -Name 'AssignmentSetOverride'
        $m = $null
        if ($meta.ContainsKey($id.ToLowerInvariant())) { $m = $meta[$id.ToLowerInvariant()] }
        $devices.Add([pscustomobject]@{
            instanceId                = $id
            friendlyName              = $(if ($null -ne $m) { $m.friendlyName } else { $null })
            className                 = $(if ($null -ne $m) { $m.className } else { $null })
            status                    = $(if ($null -ne $m) { $m.status } else { $null })
            deviceDescRaw             = $deviceDesc.value
            driverService             = $service.value
            msiKeyExisted             = $msiSupported.keyExisted
            msiSupportedPresent       = $msiSupported.existed
            msiSupportedKind          = $msiSupported.kind
            msiSupportedValue         = $msiSupported.value
            affinityKeyExisted        = $devicePolicy.keyExisted
            devicePolicyPresent       = $devicePolicy.existed
            devicePolicyValue         = $devicePolicy.value
            devicePriorityPresent     = $devicePriority.existed
            devicePriorityValue       = $devicePriority.value
            assignmentSetPresent      = $override.existed
            assignmentSetKind         = $override.kind
        })
    }

    return [pscustomobject]@{
        readOnly             = $true
        deviceCount          = $devices.Count
        enumerationSkipped   = $enumerationSkipped
        enumerationError     = $enumerationError
        valuePresenceGated   = $true
        globalWriteSupported = $false
        devices              = $devices.ToArray()
    }
}

# ---------------------------------------------------------------------------
# NX17-001 - Timer resolution behavior (EXPERIMENTAL, read-only)
# ---------------------------------------------------------------------------

function Get-Nx17TimerResolutionReport {
    <#
    .SYNOPSIS
        NX17-001: read-only timer-resolution behavior report. No mutation is shipped.
    .DESCRIPTION
        Reports the performance-counter frequency (documented Stopwatch property) and
        the observed state of the community-established GlobalTimerResolutionRequests
        value. It deliberately does NOT present the current system timer resolution as
        a single global number: since Windows 10 2004, timer-resolution requests are
        process/window scoped, so a machine-wide "1 ms timer" reading would misrepresent
        reality (UltraOS finding, r4; TWEAK_RESEARCH.md section 7).

        The classic "force 1 ms system timer" ritual is NOT implemented. No documented
        global write exists that makes every process run on a 1 ms timer, and the
        reference ecosystem's own placebo list calls the ritual folklore (r4). Owners
        who need a finer timer for a specific application should use that application's
        documented per-process mechanism.
    #>
    [CmdletBinding()]
    param()
    $kernel = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
    $globalRequests = Get-Nx17ValueState -Path $kernel -Name 'GlobalTimerResolutionRequests'

    return [pscustomobject]@{
        tweakId                          = 'NX17-001'
        readOnly                         = $true
        status                           = 'Defined'
        mutationSupported                = $false
        stopwatchFrequency               = [System.Diagnostics.Stopwatch]::Frequency
        stopwatchIsHighResolution        = [System.Diagnostics.Stopwatch]::IsHighResolution
        ticksPerSecond                   = [System.TimeSpan]::TicksPerSecond
        globalTimerResolutionRequests    = $globalRequests
        globalRequestsProvenance         = 'Community-established value name; Microsoft documents timer-resolution APIs and MMCSS behavior, not this persistence value as a supported tuning contract. Read-only observation; never written by NEXTRIX.'
        perWindowBehavior                = 'Since Windows 10 2004, timer-resolution requests are scoped to the requesting process/window family; background processes do not inherit another process request (UltraOS finding, r4).'
        guidance                         = @(
            'This entry ships a report, not a timer change: no documented global write produces a machine-wide 1 ms timer.',
            'Do not use an unsigned timer-forcing utility. A kernel-adjacent hack for a contested, unmeasurable outcome is outside NEXTRIX policy.',
            'If an application documents a per-process timer mechanism, configure it in that application rather than changing the machine.'
        )
        researchFinding                  = 'UltraOS no-placebo section: "Since Windows 10 2004, timer resolution is per-window and background processes do not benefit; the 1 ms gaming timer ritual is mostly folklore." (r4-synergy-ultraos.md)'
    }
}

# ---------------------------------------------------------------------------
# NX17-002 - Dynamic Tick policy (BCD, read-only + documented procedure)
# ---------------------------------------------------------------------------

function Get-Nx17DynamicTickPolicy {
    <#
    .SYNOPSIS
        NX17-002: read-only dynamic-tick BCD state plus the exact consented procedure.
    .DESCRIPTION
        Reads `bcdedit /enum {current}` only. The mutation (disabledynamictick) is
        DEFINED, not shipped:
          - Microsoft's BCDEdit reference marks disabledynamictick "should only be used
            for debugging" and warns that a /set can render the computer inoperable and
            that BitLocker/Secure Boot may need to be suspended first.
          - ReviOS removed its own "disabledynamictick yes" after it broke sleep on the
            ROG Ally (#167, r2) - a concrete hardware regression, not a theoretical one.
        The report returns the exact prior state (absent vs present+value) so an owner
        can journal it before any manual change, and the inverse command for rollback.
    #>
    [CmdletBinding()]
    param()
    $bcd = Get-Nx17BcdElements -Entry '{current}'
    $tick = Get-Nx17BcdElementState -BcdResult $bcd -ElementName 'disabledynamictick'

    $effective = 'Unknown'
    if ($tick.bcdRead) {
        if (-not $tick.present) { $effective = 'NotConfigured-WindowsDefault' }
        elseif ([string]$tick.value -match '^(?i)yes$') { $effective = 'DynamicTickDisabled' }
        elseif ([string]$tick.value -match '^(?i)no$') { $effective = 'DynamicTickEnabledByConfig' }
        else { $effective = 'UnrecognizedValue' }
    }

    return [pscustomobject]@{
        tweakId               = 'NX17-002'
        readOnly              = $true
        status                = 'Defined'
        mutationSupported     = $false
        bcdReadSucceeded      = $bcd.readSucceeded
        bcdError              = $bcd.error
        element               = $tick
        effectiveState        = $effective
        explicitConsentNeeded = $true
        restartRequired       = $true
        knownRegression       = 'ReviOS #167: disabledynamictick broke sleep on the ROG Ally and the setting was removed from their playbook (r2-atlasos-revios.md; COMPATIBILITY_RESEARCH section 3).'
        bcdToolWarning        = 'Microsoft BCDEdit reference: changing boot-entry options can render the computer inoperable; suspend BitLocker/Secure Boot first where applicable; alternatives (MSConfig, Startup Settings) should be preferred.'
        requiredProcedure     = @(
            'Capture the exact prior state before changing anything: bcdedit /enum {current} (this report already reads it; journal/extract the disabledynamictick line).',
            'Owner confirms the machine is a test/target device and that sleep/resume behaviour is acceptable to risk (laptop/handheld especially).',
            'Owner runs, elevated, exactly one of: bcdedit /set {current} disabledynamictick yes  OR  bcdedit /deletevalue {current} disabledynamictick',
            'Restart, then verify with bcdedit /enum {current}: the element must show the intended value or be absent.',
            'Rollback: if the element was absent before, run bcdedit /deletevalue {current} disabledynamictick; if it held a value, set that exact value back, then restart.'
        )
        verifiedDocumentation = 'https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--set (disabledynamictick: "Enables and disables dynamic timer tick feature"; "should only be used for debugging"; BitLocker/Secure Boot note; fetched 2026-11-23)'
    }
}

# ---------------------------------------------------------------------------
# NX17-003 - HPET policy (TROUBLESHOOTING, detection only, forcing rejected)
# ---------------------------------------------------------------------------

function Get-Nx17HpetPolicy {
    <#
    .SYNOPSIS
        NX17-003: read-only HPET/platform-clock detection for a named symptom.
    .DESCRIPTION
        Reports the BCD clock-source elements and whether the HPET device is present.
        NEXTRIX ships NO HPET forcing and NO device disable:
          - Microsoft documents useplatformclock/useplatformtick as debugging-only.
          - The reference ecosystem disagrees in every direction (SapphireOS forces the
            platform tick and disables HPET; Vain and XOS delete the values), and none
            ships forcing as safe (TWEAK_CATALOGUE rejected list, r1/r3).
        If a platform-clock value is present, the symptom-gated remedy is to REMOVE it
        (bcdedit /deletevalue), not to force the opposite. Both directions are risky,
        so both remain owner-performed, consented and reversible only via the captured
        prior state.
    #>
    [CmdletBinding()]
    param()
    $bcd = Get-Nx17BcdElements -Entry '{current}'
    $platformClock = Get-Nx17BcdElementState -BcdResult $bcd -ElementName 'useplatformclock'
    $platformTick = Get-Nx17BcdElementState -BcdResult $bcd -ElementName 'useplatformtick'
    $tscSync = Get-Nx17BcdElementState -BcdResult $bcd -ElementName 'tscsyncpolicy'
    $hpet = Get-Nx17HpetDeviceState

    $forcedSources = New-Object System.Collections.Generic.List[string]
    if ($platformClock.present -and [string]$platformClock.value -match '^(?i)yes$') { $forcedSources.Add('useplatformclock=Yes (platform clock forced as performance counter)') }
    if ($platformTick.present -and [string]$platformTick.value -match '^(?i)yes$') { $forcedSources.Add('useplatformtick=Yes (platform-backed tick forced, no synthetic timers)') }

    return [pscustomobject]@{
        tweakId              = 'NX17-003'
        readOnly             = $true
        status               = 'Defined'
        mutationSupported    = $false
        symptomGated         = $true
        forcingRejected      = $true
        bcdReadSucceeded     = $bcd.readSucceeded
        bcdError             = $bcd.error
        useplatformclock     = $platformClock
        useplatformtick      = $platformTick
        tscsyncpolicy        = $tscSync
        hpetDevice           = $hpet
        forcedSourcesPresent = $forcedSources.ToArray()
        diagnosisNote        = 'A clock-source override is never a general optimization. Only a named, reproducible symptom (timer/clock-related instability or an application that documents an HPET/platform-clock interaction) justifies touching it, and removal of an existing override is the preferred direction.'
        requiredProcedure    = @(
            'Capture bcdedit /enum {current} and journal the exact useplatformclock/useplatformtick/tscsyncpolicy lines before any change.',
            'Identify the named symptom and confirm with the application/driver vendor that a clock-source override is implicated.',
            'Owner runs, elevated, only the removal direction first: bcdedit /deletevalue {current} useplatformclock (or useplatformtick), then restarts and re-tests the symptom.',
            'If the symptom is unchanged, restore the captured prior values; do not escalate to disabling the HPET device or to forcing the opposite source.',
            'Never disable the High Precision Event Timer device through NEXTRIX: the event is hardware/model-specific and no reference project ships it as safe.'
        )
        verifiedDocumentation = 'https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--set (useplatformclock: "Forces the use of the platform clock as the system''s performance counter"; useplatformtick: "Forces the clock to be backed by a platform source, no synthetic timers are allowed"; both marked debugging-only; fetched 2026-11-23)'
    }
}

# ---------------------------------------------------------------------------
# NX17-004 - Platform clock source inspection (CORE, read-only)
# ---------------------------------------------------------------------------

function Get-Nx17PlatformClockReport {
    <#
    .SYNOPSIS
        NX17-004: read-only report of the configured platform clock/tick source.
    .DESCRIPTION
        Combines the BCD clock elements with the ACPI HPET device state and the
        documented performance-counter frequency. Answers "what is configured?" and
        never changes it. Also flags undocumented custom:* BCD elements present in the
        current entry without interpreting or touching them (Atlas custom:16000069
        precedent, r2).
    #>
    [CmdletBinding()]
    param()
    $bcd = Get-Nx17BcdElements -Entry '{current}'
    $clock = Get-Nx17BcdElementState -BcdResult $bcd -ElementName 'useplatformclock'
    $tick = Get-Nx17BcdElementState -BcdResult $bcd -ElementName 'useplatformtick'
    $dyn = Get-Nx17BcdElementState -BcdResult $bcd -ElementName 'disabledynamictick'
    $tsc = Get-Nx17BcdElementState -BcdResult $bcd -ElementName 'tscsyncpolicy'
    $hpet = Get-Nx17HpetDeviceState

    $customElements = @()
    if ($bcd.readSucceeded -and $null -ne $bcd.elements) {
        $customElements = @($bcd.elements.PSObject.Properties | Where-Object { $_.Name -like 'custom:*' } | ForEach-Object {
            [pscustomobject]@{ element = $_.Name; value = [string]$_.Value; documented = $false }
        })
    }

    $selection = 'WindowsDefaultSelection'
    if (($clock.present -and [string]$clock.value -match '^(?i)yes$') -or ($tick.present -and [string]$tick.value -match '^(?i)yes$')) {
        $selection = 'ForcedByBcd'
    }

    return [pscustomobject]@{
        tweakId            = 'NX17-004'
        readOnly           = $true
        status             = 'Implemented'
        mutationSupported  = $false
        bcdReadSucceeded   = $bcd.readSucceeded
        bcdError           = $bcd.error
        selection          = $selection
        useplatformclock   = $clock
        useplatformtick    = $tick
        disabledynamictick = $dyn
        tscsyncpolicy      = $tsc
        hpetDevice         = $hpet
        customBcdElements  = $customElements
        counterFrequency   = [System.Diagnostics.Stopwatch]::Frequency
        notes              = @(
            'A "No"/absent element means Windows default selection applies; it is not evidence that the platform clock is or is not in use at runtime.',
            'Microsoft documents useplatformclock and useplatformtick as debugging options. NEXTRIX reports their presence only.',
            'Undocumented custom:* BCD elements are reported by name only and are never read as policy, interpreted, or modified.',
            'This report is configuration evidence, not a timing measurement and not a performance claim.'
        )
        verifiedDocumentation = 'https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--set (clock/tick element semantics; custom:* is not documented by Microsoft; fetched 2026-11-23)'
    }
}

# ---------------------------------------------------------------------------
# NX17-005 - Curated BCD configuration set (read-only, one documented case)
# ---------------------------------------------------------------------------

function Get-Nx17CuratedBcdConfiguration {
    <#
    .SYNOPSIS
        NX17-005: read-only curated BCD report; no bulk writer exists.
    .DESCRIPTION
        The only curated case NEXTRIX defines is the DOCUMENTED bootmenupolicy
        (Standard/Legacy). A boot menu policy is a display/behaviour choice, not a
        performance tweak, and Microsoft documents both values. Nothing is written:
        each would-be change needs its own approval and its own captured prior state,
        and no "optimize BCD" bulk action is permitted (directive; TWEAK_CATALOGUE).

        The report also lists bootmgr timeout (context only) and flags any undocumented
        custom:* element. Atlas's custom:16000069 (spinning animations) is the named
        example of a value NEXTRIX will not adopt: it is undocumented even by its own
        comment (r2).
    #>
    [CmdletBinding()]
    param()
    $current = Get-Nx17BcdElements -Entry '{current}'
    $bootMgr = Get-Nx17BcdElements -Entry '{bootmgr}'

    $bootMenu = Get-Nx17BcdElementState -BcdResult $current -ElementName 'bootmenupolicy'
    $timeout = Get-Nx17BcdElementState -BcdResult $bootMgr -ElementName 'timeout'

    $customElements = @()
    if ($current.readSucceeded -and $null -ne $current.elements) {
        $customElements = @($current.elements.PSObject.Properties | Where-Object { $_.Name -like 'custom:*' } | ForEach-Object {
            [pscustomobject]@{ element = $_.Name; value = [string]$_.Value; documented = $false }
        })
    }

    return [pscustomobject]@{
        tweakId                 = 'NX17-005'
        readOnly                = $true
        status                  = 'Defined'
        mutationSupported       = $false
        bulkWriteSupported      = $false
        perEntryApprovalNeeded  = $true
        currentEntryRead        = $current.readSucceeded
        currentEntryError       = $current.error
        bootManagerRead         = $bootMgr.readSucceeded
        bootManagerError        = $bootMgr.error
        bootmenupolicy          = $bootMenu
        bootManagerTimeout      = $timeout
        undocumentedElements    = $customElements
        curatedCases            = @(
            [pscustomobject]@{
                element       = 'bootmenupolicy'
                values        = @('Standard','Legacy')
                documented    = $true
                rationale     = 'Documented boot-menu presentation option. Defined only so a machine left on Legacy by a third-party playbook can be reported and, with explicit consent, restored to Standard. Not a performance change.'
                procedure     = @(
                    'Capture bcdedit /enum {current} and journal the bootmenupolicy line.',
                    'Owner runs, elevated: bcdedit /set {current} bootmenupolicy Standard',
                    'Restart and verify with bcdedit /enum {current}.',
                    'Rollback: restore the captured value (usually Legacy) with the same /set form; if the element was absent, bcdedit /deletevalue {current} bootmenupolicy.'
                )
            }
        )
        rejectedExamples        = @(
            'bootstatuspolicy IgnoreAllFailures (suppresses boot-failure UX / automatic repair) - rejected (r2).',
            'custom:16000069 (undocumented spinning-animation element) - rejected; undocumented even by its community source (r2).',
            'Any blanket "BCD optimization" multi-element write - rejected; each element would need its own approval, capture and rollback.'
        )
        verifiedDocumentation   = 'https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--set (bootmenupolicy Standard/Legacy semantics; fetched 2026-11-23)'
    }
}

# ---------------------------------------------------------------------------
# NX17-006 - MSI mode per-device inspection (read-only)
# ---------------------------------------------------------------------------

function Get-Nx17MsiModeInventory {
    <#
    .SYNOPSIS
        NX17-006: per-device MSI state inventory; selective enable is Defined only.
    .DESCRIPTION
        Inventories the per-device MSISupported value and reports whether it already
        exists (value-presence gate). Global MSI forcing is forbidden by directive.
        The per-device enable is deliberately NOT shipped:
          - MSISupported is not a documented public registry contract.
          - Enabling MSI changes interrupt delivery and needs a device restart/reboot
            plus a stability observation window; a failed placement can hang a device.
          - The journal can restore the value exactly, but this engine has no
            device-stability gate, so the mutation stays Defined with a per-instance,
            per-consent procedure.
    #>
    [CmdletBinding()]
    param([string]$InstanceId)
    $inventory = Get-Nx17PciInterruptInventory -InstanceId $InstanceId

    return [pscustomobject]@{
        tweakId              = 'NX17-006'
        readOnly             = $true
        status               = 'Defined'
        mutationSupported    = $false
        globalWriteSupported = $false
        perDeviceOnly        = $true
        valuePresenceGated   = $true
        deviceCount          = $inventory.deviceCount
        enumerationSkipped   = $inventory.enumerationSkipped
        enumerationError     = $inventory.enumerationError
        devices              = $inventory.devices
        notes                = @(
            'MSISupported is reported only where the per-device value already exists; a missing value is reported as "not present", never as 0.',
            'Global MSI forcing (all PCI devices at once) is forbidden by NEXTRIX directive; only a single device instance can ever be a candidate.',
            'Enabling MSI on one device requires: explicit per-device consent, the exact prior descriptor journaled, a device restart/reboot, and an observation window for the device class.'
        )
        requiredProcedure    = @(
            'Select exactly one device instance from this inventory whose MSISupported value is already present (value-presence gate).',
            'Journal the exact per-device descriptor: key existence, value existence, kind and data for ...\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties :: MSISupported.',
            'Owner changes that one instance to 1, restarts the device (or reboots), and observes the device class for stability.',
            'Rollback: restore the exact captured value, or delete the value if it did not exist before; restart the device/reboot.',
            'Never apply a global MSI switch, and never write a per-device value that did not already exist.'
        )
        researchBasis        = 'r1-fsosx-xos.md: XOS enables MSI only where MSISupported already exists as 0/1 and backs up each prior value (MsiModeBackup). TWEAK_CATALOGUE rejected list item 4: global MSI-mode forcing is rejected; per-device only.'
    }
}

# ---------------------------------------------------------------------------
# NX17-007 - Interrupt affinity policy per-device (read-only)
# ---------------------------------------------------------------------------

function Get-Nx17InterruptAffinityInventory {
    <#
    .SYNOPSIS
        NX17-007: per-device interrupt affinity state inventory; read-only/Defined.
    .DESCRIPTION
        Reports DevicePolicy, DevicePriority and AssignmentSetOverride per PCI device
        without interpreting undocumented bitmasks as a recommendation. No topology-fed
        write is shipped: NX19 (topology derivation) is not loaded in this build, the
        affinity policy values are not documented public contracts, and
        AssignmentSetOverride is a processor bitmask whose meaning depends on the
        machine's processor groups. Writing it without a verified topology is prohibited.
    #>
    [CmdletBinding()]
    param([string]$InstanceId)
    $inventory = Get-Nx17PciInterruptInventory -InstanceId $InstanceId

    $topologyFunction = 'Get-NxTopologyReport'
    $topologyStatus = 'Unavailable'
    if ($null -ne (Get-Command -Name $topologyFunction -CommandType Function -ErrorAction SilentlyContinue)) {
        $topologyStatus = 'Available'
    }

    return [pscustomobject]@{
        tweakId              = 'NX17-007'
        readOnly             = $true
        status               = 'Defined'
        mutationSupported    = $false
        perDeviceOnly        = $true
        topologySource       = 'NX19'
        topologyFunction     = $topologyFunction
        topologyStatus       = $topologyStatus
        deviceCount          = $inventory.deviceCount
        enumerationSkipped   = $inventory.enumerationSkipped
        enumerationError     = $inventory.enumerationError
        devices              = $inventory.devices
        notes                = @(
            'DevicePolicy / DevicePriority / AssignmentSetOverride are per-device registry values, not documented public tuning contracts; reported raw only.',
            'AssignmentSetOverride is a processor bitmask interpreted against the machine processor groups; without NX19-derived topology a write would be a guess and is therefore not shipped.',
            'When NX19 is loaded its read-only Get-NxTopologyReport supplies the derived topology; this entry still selects no processors because no affinity write is shipped.',
            'No global affinity policy is written; affinity is not the same mechanism as CPU Sets (NX19 owns the CPU Sets path).'
        )
        verifiedDocumentation = 'r1-fsosx-xos.md (XOS removes the Affinity Policy DevicePriority value as part of its MSI pass); r4-synergy-ultraos.md (GoInterruptPolicy bundled as a manual tool; no scripted affinity logic)'
    }
}

# ---------------------------------------------------------------------------
# NX17-008 - System responsiveness value (XREF NX03-007, read-only)
# ---------------------------------------------------------------------------

function Get-Nx17SystemResponsivenessState {
    <#
    .SYNOPSIS
        NX17-008: read-only SystemResponsiveness report; write path owned by NX03-007.
    .DESCRIPTION
        Delegation entry: NX03-007 (MMCSS configuration) owns the single write path for
        SystemResponsiveness. This function exists so NX17 can report the machine-wide
        MMCSS policy without duplicating the target (the validator hard-errors on
        duplicate registry targets). Microsoft documents the clamping semantics and
        that 100 disables MMCSS; no performance claim is made here.
    #>
    [CmdletBinding()]
    param()
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $value = Get-Nx17ValueState -Path $path -Name 'SystemResponsiveness'

    return [pscustomobject]@{
        tweakId            = 'NX17-008'
        readOnly           = $true
        status             = 'Defined'
        mutationSupported  = $false
        ownerTweak         = 'NX03-007'
        writeDelegated     = $true
        keyExists          = $value.keyExisted
        valuePresent       = $value.existed
        kind               = $value.kind
        value              = $value.value
        documentedSemantics = 'REG_DWORD percentage of CPU reserved for low-priority work; values not divisible by 10 round down; values below 10 or above 100 are clamped to 20; 100 disables MMCSS (STATUS_SERVER_DISABLED).'
        notes              = @(
            'NX03-007 performs the only write of this value (journaled, ADVANCED, preset-excluded). NX17-008 never writes it.',
            'Stock Windows 11 reference value in the research is 20; a written 10 is the classic community intent, not a measured benefit (r4).',
            'Changing this value changes how multimedia-tagged and lower-priority work compete machine-wide. Configuration intent only.'
        )
        verifiedDocumentation = 'https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service (SystemResponsiveness semantics and clamping; fetched 2026-11-23)'
    }
}

# ---------------------------------------------------------------------------
# NX17-009 - Network throttling index (read-only, honest scope)
# ---------------------------------------------------------------------------

function Get-Nx17NetworkThrottlingState {
    <#
    .SYNOPSIS
        NX17-009: read-only NetworkThrottlingIndex report with an explicit scope note.
    .DESCRIPTION
        NetworkThrottlingIndex lives beside SystemResponsiveness and is community-known
        but is NOT described by Microsoft's MMCSS page, so the evidence stays E0 for the
        value name. Its scope is narrow: it throttles network packets for
        MMCSS-tagged multimedia traffic only - it is not general TCP throughput tuning.
        No NEXTRIX writer exists (NX03-007 owns MMCSS and does not write it), so this is
        a Defined, read-only observer with the honest scope note.
    #>
    [CmdletBinding()]
    param()
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $value = Get-Nx17ValueState -Path $path -Name 'NetworkThrottlingIndex'

    return [pscustomobject]@{
        tweakId           = 'NX17-009'
        readOnly          = $true
        status            = 'Defined'
        mutationSupported = $false
        ownerTweak        = 'None (documentation-only XREF to NX03-007 for MMCSS)'
        keyExists         = $value.keyExisted
        valuePresent      = $value.existed
        kind              = $value.kind
        value             = $value.value
        scopeNote         = 'Applies to network packets generated by MMCSS-tagged multimedia traffic. It is not a general network-throughput, latency or TCP tuning control, and changing it does not affect ordinary downloads or games that do not use MMCSS.'
        provenance        = 'Community-established value name (XOS writes 10, r1). Microsoft documents MMCSS itself but not this value as a supported tuning contract, hence E0; no write is shipped.'
        notes             = @(
            'Do not present this as a gaming or streaming optimization: the documented mechanism only covers MMCSS-tagged traffic.',
            'NX03-007 owns the MMCSS value family and does not write this value; NX17-009 does not either.',
            'Reading this value is safe; interpreting a stock 10 as a problem is not.'
        )
        verifiedDocumentation = 'https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service (documents MMCSS and SystemResponsiveness; NetworkThrottlingIndex is NOT documented there - fetched 2026-11-23)'
    }
}

# ---------------------------------------------------------------------------
# NX17-010 - Multimedia scheduler configuration (XREF NX03-007, read-only)
# ---------------------------------------------------------------------------

function Get-Nx17MultimediaSchedulerState {
    <#
    .SYNOPSIS
        NX17-010: read-only composition view of the MMCSS surface; owner is NX03-007.
    .DESCRIPTION
        Reports service state (read-only Get-Service) and the existing MMCSS task keys
        with their documented Priority / Scheduling Category values. It never writes a
        task value and never invents a task key. NX03-007 owns the writes; this entry is
        a composition/report so the owner can see the MMCSS surface in one place.
    #>
    [CmdletBinding()]
    param()
    $serviceState = [ordered]@{ available = $false; status = $null; startType = $null; error = $null }
    try {
        $svc = Get-Service -Name 'MMCSS' -ErrorAction Stop
        $serviceState.available = $true
        $serviceState.status = [string]$svc.Status
        $serviceState.startType = [string]$svc.StartType
    } catch {
        $serviceState.error = [string]$_.Exception.Message
    }

    $tasks = @()
    $tasksPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks'
    if (Test-Path -LiteralPath $tasksPath) {
        try {
            foreach ($key in @(Get-ChildItem -LiteralPath $tasksPath -ErrorAction Stop)) {
                $priority = Get-Nx17ValueState -Path $key.PSPath -Name 'Priority'
                $category = Get-Nx17ValueState -Path $key.PSPath -Name 'Scheduling Category'
                $tasks += [pscustomobject]@{
                    name                    = $key.PSChildName
                    priorityPresent         = $priority.existed
                    priorityValue           = $priority.value
                    schedulingCategoryPresent = $category.existed
                    schedulingCategoryValue = $category.value
                }
            }
        } catch { }
    }

    return [pscustomobject]@{
        tweakId           = 'NX17-010'
        readOnly          = $true
        status            = 'Defined'
        mutationSupported = $false
        ownerTweak        = 'NX03-007'
        writeDelegated    = $true
        service           = [pscustomobject]$serviceState
        taskCount         = @($tasks).Count
        tasks             = $tasks
        notes             = @(
            'NX03-007 writes SystemResponsiveness and, opt-in, Priority / Scheduling Category for EXISTING task keys. NX17-010 reports only.',
            'GPU Priority and SFIO Priority are documented as unused; Clock Rate lost its guarantee in Windows 7; none is written anywhere in NEXTRIX.',
            'Disabling the MMCSS service would make every MMCSS value meaningless and is out of scope (service ownership is NX11).'
        )
        verifiedDocumentation = 'https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service (task value table and documented unused values; fetched 2026-11-23)'
    }
}

# ---------------------------------------------------------------------------
# NX17-011 - Device installation / driver-update restriction policy (implemented)
# ---------------------------------------------------------------------------

function Set-Nx17DeviceInstallationPolicy {
    <#
    .SYNOPSIS
        NX17-011: the documented "Do not include drivers with Windows Updates" policy.
    .DESCRIPTION
        Applies the documented policy ExcludeWUDriversInQualityUpdate (DWord) under
        HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate (WindowsUpdate.admx;
        Policy CSP Update/ExcludeWUDriversInQualityUpdate). Mode:
          Excluded -> 1 : Windows Update does not include updates with a Driver
                          classification in quality updates.
          Default  -> 0 : allow Windows Update drivers again.

        This restricts the WINDOWS UPDATE DRIVER-DELIVERY path only. It does not block
        manual driver installation, OEM updater tools, or Device Manager. The trade-off
        is explicit: new devices may need a vendor-supplied driver instead of arriving
        automatically. Edition note: the CSP table lists Pro/Enterprise/Education/IoT;
        Home is included with documentation-limited enforcement (the value is written
        and verified, but Home's policy enforcement is not claimed).

        Pipeline: capture exact original -> idempotent skip -> journal apply -> write
        -> verify -> journal; a failed verification restores the exact original and
        journals the failure. Nothing applies without -Approved (or -WhatIf planning).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Excluded','Default')][string]$Mode = 'Excluded',
        [string]$TweakId = 'NX17-011',
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [switch]$Approved
    )
    $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $name = 'ExcludeWUDriversInQualityUpdate'
    $target = "$path :: $name"
    $data = 0
    if ($Mode -eq 'Excluded') { $data = 1 }

    # Journal contract: no real mutation without approval evidence (WhatIf plans only).
    if (-not $Approved -and -not $WhatIfPreference) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }

    # Steps 2-6: exact original state, read-only.
    $orig = Capture-NxRegistryValue -Path $path -Name $name
    $modified = [pscustomobject]@{ targetType = 'registry'; path = $path; name = $name; kind = 'DWord'; value = $data }

    if (-not $PSCmdlet.ShouldProcess($target, "Set DWord $data (Windows Update driver delivery: $Mode)")) {
        return [pscustomobject]@{
            tweakId = $TweakId; target = $target; mode = $Mode; changed = $false
            verified = $false; planned = $true; journalSeq = $null
            reason = 'WhatIf/Confirm: no mutation, no journal write'
        }
    }

    # Idempotency: desired state already present -> journal a skip, never rewrite.
    if ($orig.existed -and [string]$orig.kind -eq 'DWord') {
        $liveValue = 0
        if ([int64]::TryParse([string]$orig.value, [ref]$liveValue) -and $liveValue -eq [int64]$data) {
            $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' `
                -Approval $Approval -Original $orig -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
            return [pscustomobject]@{
                tweakId = $TweakId; target = $target; mode = $Mode; changed = $false
                verified = $true; planned = $false; journalSeq = $skip.seq
                reason = 'already in desired state'
            }
        }
    }

    # Step 7: journal BEFORE any mutation (journal-first invariant).
    $apply = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' `
        -Approval $Approval -Original $orig -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Set-NxRegistryValue -Path $path -Name $name -Kind DWord -Value $data
        $check = Test-NxConfigurationState -Path $path -Name $name -Kind DWord -ExpectedValue $data
        if ($check.verified) {
            $verify = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' `
                -Approval $Approval -Original $orig -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles $Profiles
            return [pscustomobject]@{
                tweakId = $TweakId; target = $target; mode = $Mode; changed = $true
                verified = $true; planned = $false; journalSeq = $apply.seq; verifySeq = $verify.seq
                reason = $check.reason
                workflowImpact = 'Windows Update stops offering Driver-classified updates in quality updates. New hardware may need a vendor-supplied driver; manual installation and OEM updaters are unaffected.'
                homeEditionNote = 'Documentation-limited: the value is written and verified, but Microsoft''s CSP editions table lists Pro/Enterprise/Education/IoT only; Home enforcement is not claimed.'
            }
        }
        # Safe stop: restore the exact original, then journal the failure.
        try { Restore-NxRegistryOriginal -Entry ([pscustomobject]@{ original = $orig }) | Out-Null } catch { }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' `
            -Approval $Approval -Original $orig -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles
        return [pscustomobject]@{
            tweakId = $TweakId; target = $target; mode = $Mode; changed = $true
            verified = $false; planned = $false; journalSeq = $apply.seq; reason = $check.reason
        }
    } catch {
        $err = [string]$_.Exception.Message
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' `
            -Approval $Approval -Original $orig -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles
        return [pscustomobject]@{
            tweakId = $TweakId; target = $target; mode = $Mode; changed = $false
            verified = $false; planned = $false; journalSeq = $apply.seq
            reason = "mutation failed: $err"
        }
    }
}

# ---------------------------------------------------------------------------
# NX17-012 - Memory Manager curated set (read-only, XREF NX05-007)
# ---------------------------------------------------------------------------

function Get-Nx17MemoryManagerState {
    <#
    .SYNOPSIS
        NX17-012: read-only curated Memory Manager value report. No writes shipped.
    .DESCRIPTION
        Reports a short, named set of legacy Memory Management values so an owner can
        see what a third-party playbook left behind. Nothing is written:
          - LargeSystemCache is NX05-007's target (ADVANCED, E0) and is reported here
            for visibility only.
          - DisablePagingExecutive / DisablePageCombining / ClearPageFileAtShutdown /
            SecondLevelDataCache are legacy community values without a current
            Microsoft contract for Windows 11 client behavior; their trade-offs are
            real (kernel paging, page combining, shutdown time, cache sizing) and no
            verified benefit exists in the six reference projects.
        Mitigation values in this key family (FeatureSettingsOverride, ...Mask) are
        banned registry targets and are deliberately neither read nor written.
    #>
    [CmdletBinding()]
    param()
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $names = @('LargeSystemCache','DisablePagingExecutive','DisablePageCombining','ClearPageFileAtShutdown','SecondLevelDataCache')
    $values = New-Object System.Collections.Generic.List[object]
    foreach ($n in $names) {
        $v = Get-Nx17ValueState -Path $path -Name $n
        $owner = 'NX17-012'
        $evidence = 'E0-legacy'
        if ($n -eq 'LargeSystemCache') { $owner = 'NX05-007'; $evidence = 'E0-legacy; the WMI mirror property exists but is marked DEPRECATED/not supported by Microsoft; Windows 11 client behavior is not documented' }
        $values.Add([pscustomobject]@{
            name      = $n
            present   = $v.existed
            kind      = $v.kind
            value     = $v.value
            owner     = $owner
            evidence  = $evidence
        })
    }

    return [pscustomobject]@{
        tweakId           = 'NX17-012'
        readOnly          = $true
        status            = 'Defined'
        mutationSupported = $false
        keyExists         = (Test-Path -LiteralPath $path)
        values            = $values.ToArray()
        notes             = @(
            'NX05-007 owns the only LargeSystemCache write (journaled, ADVANCED, preset-excluded). NX17-012 reports it; it does not duplicate the target.',
            'The other four values are legacy community knobs: individually approved, symptom-driven troubleshooting only. No blanket "memory optimization" write exists.',
            'DisablePagingExecutive keeps kernel code/data resident at the cost of available pageable memory; DisablePageCombining removes page combining; ClearPageFileAtShutdown lengthens shutdown. These are trade-offs, not optimizations.',
            'Mitigation override values in this key family are banned targets and are not touched by this report.'
        )
        verifiedDocumentation = 'https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem (LargeSystemCache property existence); TWEAK_RESEARCH.md section on DisablePagingExecutive/DisablePageCombining (r3); NX05-007 XREF'
    }
}

# ---------------------------------------------------------------------------
# NX17-013 - Power throttling registry override (XREF NX03-006, read-only)
# ---------------------------------------------------------------------------

function Get-Nx17PowerThrottlingState {
    <#
    .SYNOPSIS
        NX17-013: read-only PowerThrottling state; write path owned by NX03-006.
    .DESCRIPTION
        Delegation entry. NX03-006 owns the PowerThrottlingOff write (CONDITIONAL,
        documented mechanism, community-established value name, hardware-split
        profiles). This entry reports the current value and the key's presence so the
        override can be seen in the advanced-configuration view without a second
        writer. No performance claim is made: power throttling is a power/thermal
        policy, not a measured speed switch.
    #>
    [CmdletBinding()]
    param()
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
    $value = Get-Nx17ValueState -Path $path -Name 'PowerThrottlingOff'

    return [pscustomobject]@{
        tweakId           = 'NX17-013'
        readOnly          = $true
        status            = 'Defined'
        mutationSupported = $false
        ownerTweak        = 'NX03-006'
        writeDelegated    = $true
        keyExists         = $value.keyExisted
        valuePresent      = $value.existed
        kind              = $value.kind
        value             = $value.value
        interpretation    = 'DWord 1 = power throttling (EcoQoS lowering) disabled machine-wide; 0 = Windows default behaviour; absent = default behaviour on most images.'
        notes             = @(
            'NX03-006 performs the only write (journaled; never offered to the battery-first profile P3). NX17-013 never writes it.',
            'The override removes the OS lever that lowers background work''s QoS class; it changes power/thermal behaviour and interacts with hybrid scheduling hints. Configuration intent only.',
            'Reading the value is always safe; treating a stock image as misconfigured is not.'
        )
        verifiedDocumentation = 'https://learn.microsoft.com/en-us/windows/win32/procthread/quality-of-service (documents the PowerThrottling key and the QoS/EcoQoS mechanism; fetched for NX03-006); NX03-006 XREF'
    }
}

# ---------------------------------------------------------------------------
# NX17-014 - Driver Verifier diagnostic configuration (read-only state + procedure)
# ---------------------------------------------------------------------------

function Get-Nx17DriverVerifierState {
    <#
    .SYNOPSIS
        NX17-014: read-only Driver Verifier settings report; enabling is owner-directed only.
    .DESCRIPTION
        Runs only the read-only `verifier /querysettings` form. Driver Verifier is a
        diagnostic test mode: Microsoft warns it can crash the computer and says to run
        it only on test machines. NEXTRIX therefore never enables it automatically and
        never selects "all drivers" (which the same documentation says can exhaust
        special-pool resources and affect performance). The result carries the mandatory
        guardrails and the auto-clear procedure (`verifier /reset` + restart).

        The raw text is summarized, not trusted: a driver-name match is used only to
        report whether settings appear to list drivers; everything else is returned as
        the tool's own lines with the tool's own exit code.
    #>
    [CmdletBinding()]
    param()
    $result = [ordered]@{
        tweakId             = 'NX17-014'
        readOnly            = $true
        status              = 'Defined'
        mutationSupported   = $false
        toolFound           = $false
        querySucceeded      = $false
        exitCode            = $null
        listedDriverCount   = 0
        listedDrivers       = @()
        settingsActiveLikely = 'Unknown'
        rawLines            = @()
        error               = $null
    }
    $exe = Join-Path $env:SystemRoot 'System32\verifier.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        $result.error = 'verifier.exe not found under %SystemRoot%\System32'
    } else {
        $result.toolFound = $true
        try {
            $output = & $exe /querysettings 2>&1
            $code = $LASTEXITCODE
            $text = (@($output) | ForEach-Object { [string]$_ }) -join "`r`n"
            $result.exitCode = $code
            $result.querySucceeded = ($code -eq 0 -or $code -eq 2)
            $drivers = @([regex]::Matches($text, '(?i)[A-Za-z0-9_\-\.]+\.sys') | ForEach-Object { $_.Value } | Sort-Object -Unique)
            $result.listedDrivers = @($drivers | Select-Object -First 40)
            $result.listedDriverCount = @($drivers).Count
            if (-not $result.querySucceeded) {
                $result.error = "verifier /querysettings exited $code"
            } elseif (@($drivers).Count -gt 0) {
                $result.settingsActiveLikely = 'DriversListed'
            } else {
                $result.settingsActiveLikely = 'NoDriversListed'
            }
            $lines = @($text -split "\r?\n" | Where-Object { $_.Trim().Length -gt 0 })
            $result.rawLines = @($lines | Select-Object -First 60)
        } catch {
            $result.error = [string]$_.Exception.Message
        }
    }

    $result['guardrails'] = @(
        'Run Driver Verifier only on a machine you can afford to crash and reboot; Microsoft says to use it on test computers only.',
        'Never select all drivers: it can exhaust special-pool/resource tracking and it affects performance. Verify the smallest driver set that can reproduce the symptom.',
        'Before enabling anything, set a fail-safe boot mode: verifier /bootmode resetonbootfail  (Driver Verifier disables itself if the system fails to start).',
        'Record the exact prior verifier settings (this report) so the machine can be returned to its previous state.'
    )
    $result['autoClearProcedure'] = @(
        'Run, elevated: verifier /reset',
        'Restart the computer (settings apply/clear after the next boot).',
        'Verify: verifier /querysettings shows no verification settings and verifier /query shows no activity.',
        'If the machine cannot boot with verification active, use the fail-safe boot mode (resetonbootfail) or Windows Recovery to run verifier /reset.'
    )
    $result['verifiedDocumentation'] = 'https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/driver-verifier (crash warning; test machines only); https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/verifier-command-line (/querysettings, /reset, /bootmode resetonbootfail; fetched 2026-11-23)'
    return [pscustomobject]$result
}
