#Requires -Version 5.1
<#
    NX04.ps1 - GPU & Graphics category module (registry/NX04.json engine functions).

    HONESTY CONTRACT (the core engineering value of this category):
    - Per-profile vendor driver settings (NVIDIA 009-016, AMD 017-022, Intel 023)
      are NOT writable through documented native Windows APIs. This module
      never fakes a driver-profile write: vendor entries are read-only status
      helpers (Get-NxNvidiaStatus / Get-NxAmdStatus / Get-NxIntelStatus) plus
      the guided Get-NxVendorGraphicsGuide workflow. Vendor behavior text is
      quoted from vendor documentation with sources; no performance claims.
    - Windows-side mechanisms are implemented only where a documented or
      reference-corroborated route exists: per-app GpuPreference (Microsoft-
      documented value family) and the DirectX global-settings component
      composer (shared value with NX02-005 - single composer prevents the
      clobbering a declarative whole-value write would cause).

    MUTATION SURFACE: exactly two journaled write functions -
        Set-NxGpuPreference          (HKCU UserGpuPreferences, per-app value)
        Set-NxDirectXGlobalSetting   (same key, DirectXUserGlobalSettings RMW)
    Both refuse to run without -Approved + -JournalRoot, capture the exact
    original via the standard pipeline first, journal before mutation, verify
    after, and best-effort restore on failed verification (NxApply pattern).
    Everything else in this module is strictly read-only.

    LOADING: read-only functions work standalone. The two write functions
    require the NxCore pipeline first (run Import-NxCore; Assert-NxWritePipeline
    enforces it with a clear failure). Validation of this module on the
    authoring host used parsing plus read-only queries/plan mode only - no
    host mutation (hard rule).
#>

# ============================================================================
# Internal read-only helpers (never mutate)
# ============================================================================

function Get-NxGpuVramMap {
    # Read-only scan of the display class key for 64-bit qwMemorySize values,
    # indexed by MatchingDeviceId (NxHardware pattern: WMI AdapterRAM wraps
    # above 4 GB; one unreadable subkey must not sink the scan, r4).
    $map = @{}
    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    if (-not (Test-Path $classKey)) { return $map }
    foreach ($sub in (Get-ChildItem $classKey -ErrorAction SilentlyContinue)) {
        try {
            $matchId = (Get-ItemProperty -Path $sub.PSPath -Name MatchingDeviceId -ErrorAction Stop).MatchingDeviceId
            $mem = (Get-ItemProperty -Path $sub.PSPath -Name 'HardwareInformation.qwMemorySize' -ErrorAction Stop).'HardwareInformation.qwMemorySize'
            if ($matchId -and $mem) { $map[[string]$matchId] = [int64]$mem }
        } catch { continue }
    }
    return $map
}

function Get-NxGpuAdaptersInternal {
    # Read-only adapter enumeration with PCI vendor-ID classification
    # (VEN_10DE/1002/8086 - SynToolkit pattern, r4; never name-guessing).
    [CmdletBinding()]
    param()
    $vendorMap = @{ '10DE' = 'NVIDIA'; '1002' = 'AMD'; '8086' = 'Intel' }
    $adapters = @(); $uncertainty = @()
    $vramMap = Get-NxGpuVramMap
    try {
        $controllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
        foreach ($c in $controllers) {
            $vendor = 'Uncertain'; $ven = $null
            if (([string]$c.PNPDeviceID) -match 'VEN_([0-9A-Fa-f]{4})') { $ven = $Matches[1].ToUpper() }
            if ($ven -and $vendorMap.ContainsKey($ven)) { $vendor = $vendorMap[$ven] }
            elseif (([string]$c.Name) -match 'Microsoft Basic Display|Microsoft Remote Display') { $vendor = 'None' }
            else { $uncertainty += "unmapped GPU vendor for '$($c.Name)' (VEN_$ven)" }
            $vramBytes = $null; $vramSource = 'unavailable'
            if ($ven) {
                foreach ($mid in @($vramMap.Keys)) {
                    if (([string]$c.PNPDeviceID) -like "*$mid*") {
                        $vramBytes = [int64]$vramMap[$mid]
                        $vramSource = 'registry qwMemorySize (64-bit class key)'
                        break
                    }
                }
            }
            if ($null -eq $vramBytes -and $c.AdapterRAM) {
                $vramBytes = [int64]$c.AdapterRAM
                $vramSource = 'WMI AdapterRAM (uint32, wraps >4 GB - treat as minimum)'
            }
            $dd = $null
            if ($c.DriverDate) { try { $dd = ([datetime]$c.DriverDate).ToString('yyyy-MM-dd') } catch { $dd = [string]$c.DriverDate } }
            $adapters += [pscustomobject]@{
                name                        = [string]$c.Name
                vendor                      = $vendor
                driverVersion               = [string]$c.DriverVersion
                driverDate                  = $dd
                pnpDeviceId                 = [string]$c.PNPDeviceID
                vramBytes                   = $vramBytes
                vramSource                  = $vramSource
                currentHorizontalResolution = $c.CurrentHorizontalResolution
                currentVerticalResolution   = $c.CurrentVerticalResolution
                currentRefreshRate          = $c.CurrentRefreshRate
            }
        }
    } catch { $uncertainty += "Win32_VideoController read failed: $($_.Exception.Message)" }
    return [pscustomobject]@{ adapters = $adapters; uncertainty = $uncertainty }
}

function ConvertTo-NxDirectXGlobalComponents {
    # Parses the INI-style DirectXUserGlobalSettings string into an ordered
    # component dictionary ('k=v; k=v;' - reference-corroborated format, r1).
    param([string]$SettingsString)
    $components = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($SettingsString)) { return $components }
    foreach ($pair in ($SettingsString -split ';')) {
        $t = $pair.Trim()
        if (-not $t) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -le 0) { continue }
        $k = $t.Substring(0, $eq).Trim()
        $v = $t.Substring($eq + 1).Trim()
        if ($k) { $components[$k] = $v }
    }
    return $components
}

function ConvertTo-NxDirectXGlobalSettingsString {
    # Deterministic serialization: components joined with '; ' plus trailing ';'
    # (XOS-observed format, r1). Sibling component VALUES are preserved; byte
    # layout may differ from a Settings-authored string - documented honesty.
    param([System.Collections.IDictionary]$Components)
    $parts = @()
    foreach ($k in @($Components.Keys)) { $parts += "$k=$($Components[$k])" }
    return ($parts -join '; ') + ';'
}

function Assert-NxWritePipeline {
    # Journaled writes depend on the NxCore pipeline primitives; fail loudly
    # (never a silent continue) when they are not loaded.
    foreach ($fn in @('Capture-NxRegistryValue','Add-NxJournalEntry','Test-NxConfigurationState','Set-NxRegistryValue')) {
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) {
            throw "NX04 journaled writes require the NxCore pipeline (run Import-NxCore first); missing function: $fn"
        }
    }
}

function Get-NxRegistryValueRaw {
    # Read-only exact capture of one registry value (kind + raw value with
    # environment expansion disabled), shared by the state readers below.
    param([string]$Path, [string]$Name)
    $out = [pscustomobject]@{ keyExisted = $false; existed = $false; kind = $null; value = $null }
    if (-not (Test-Path $Path)) { return $out }
    $out.keyExisted = $true
    $key = $null
    try { $key = Get-Item -Path $Path -ErrorAction Stop } catch { return $out }
    if ($null -eq $key) { return $out }
    $raw = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($null -eq $raw) { return $out }
    $out.existed = $true
    $out.kind = $key.GetValueKind($Name).ToString()
    $out.value = $raw
    return $out
}

# ============================================================================
# Read-only capability & state helpers
# ============================================================================

function Get-NxHagsCapability {
    <#
        HAGS capability/state report with the SynToolkit honesty model (r4):
        2 = Enabled, 1 = Disabled, missing = DefaultSystemDecides (explicitly
        NOT the same as Off and NOT evidence the GPU lacks support), wrong
        kind/value = UnsupportedValue. Driver-side capability (WDDM 2.7+,
        Sophia's documented condition, r5) is NOT machine-verifiable through
        any documented registry/WMI route NxCore uses -> reported as
        Uncertain-DriverSide with the Settings UI named as the authoritative
        signal. Mechanism floor: build 19041 (XOS gate, r1).
    #>
    [CmdletBinding()]
    param()
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $name = 'HwSchMode'
    $uncertainty = @()
    $state = 'Uncertain'; $readSucceeded = $false
    $raw = Get-NxRegistryValueRaw -Path $path -Name $name
    if ($raw.keyExisted) {
        if ($raw.existed) {
            if ($raw.kind -eq 'DWord') {
                if ([int]$raw.value -eq 2)      { $state = 'Enabled';  $readSucceeded = $true }
                elseif ([int]$raw.value -eq 1) { $state = 'Disabled'; $readSucceeded = $true }
                else { $state = 'UnsupportedValue'; $readSucceeded = $true }
            } else {
                $state = 'UnsupportedValue'
                $readSucceeded = $true
                $uncertainty += "HwSchMode kind is $($raw.kind), expected DWord - verify-actual-state rule (SapphireOS comment/value contradiction, r3)"
            }
        } else { $state = 'DefaultSystemDecides'; $readSucceeded = $true }
    } else { $state = 'DefaultSystemDecides'; $readSucceeded = $true }

    $build = $null
    try {
        $build = [int]((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber)
    } catch { $uncertainty += "CurrentBuildNumber read failed: $($_.Exception.Message)" }

    $floorSatisfied = $null
    if ($null -ne $build) { $floorSatisfied = ($build -ge 19041) }

    return [pscustomobject]@{
        tweakId                = 'NX04-001'
        path                   = $path
        name                   = $name
        readSucceeded          = $readSucceeded
        hagsState              = $state
        rawKind                = $raw.kind
        rawValue               = $raw.value
        valueExisted           = $raw.existed
        mechanismFloorBuild    = 19041
        build                  = $build
        buildFloorSatisfied    = $floorSatisfied
        driverCapability       = 'Uncertain-DriverSide'
        driverCapabilityNote   = 'Driver-side HAGS support (WDDM 2.7+, Sophia condition r5) is not readable through a documented registry/WMI route; the Settings > System > Display > Graphics toggle state is the authoritative driver signal. NEXTRIX refuses to claim driver support it cannot read.'
        restartPolicy          = 'Reboot required for any HwSchMode change to take effect.'
        uncertainty            = $uncertainty
    }
}

function Get-NxMpoState {
    <#
        MPO state report (read-only). OverlayTestMode is documented in
        NVIDIA's support KB (a_id/5157); Microsoft does NOT document the
        value (hence E0 in the catalogue). 5 = overlay planes disabled;
        absent = MPO default active. Reversible by deleting the value;
        DWM reloads at sign-out (Session), reboot is the conservative route.
    #>
    [CmdletBinding()]
    param()
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'
    $name = 'OverlayTestMode'
    $uncertainty = @()
    $state = 'Uncertain'; $readSucceeded = $false
    $raw = Get-NxRegistryValueRaw -Path $path -Name $name
    if ($raw.keyExisted) {
        if ($raw.existed) {
            if ($raw.kind -eq 'DWord') {
                if ([int]$raw.value -eq 5) { $state = 'OverlaysDisabled-VendorKbRoute'; $readSucceeded = $true }
                else { $state = 'UncertainValue'; $readSucceeded = $true; $uncertainty += "OverlayTestMode=$($raw.value) is not the documented troubleshooting value 5" }
            } else {
                $state = 'UnsupportedValue'; $readSucceeded = $true
                $uncertainty += "OverlayTestMode kind is $($raw.kind), expected DWord"
            }
        } else { $state = 'Default-MpoActive'; $readSucceeded = $true }
    } else { $state = 'Default-MpoActive'; $readSucceeded = $true }

    return [pscustomobject]@{
        tweakId          = 'NX04-006'
        path             = $path
        name             = $name
        readSucceeded    = $readSucceeded
        mpoState         = $state
        rawKind          = $raw.kind
        rawValue         = $raw.value
        valueExisted     = $raw.existed
        documentationNote = 'Value documented by NVIDIA KB only (Microsoft documents MPO the capability, not this value) - catalogue E0. FSOS-X incident history: pulled R10 after user-reported composition errors/crashes, returned R11 as AMD-automatic (r1).'
        reversibilityNote = 'Value absent = MPO default active; rollback deletes the value; DWM reloads at sign-out (Session restart), reboot is the conservative documented route.'
        uncertainty       = $uncertainty
    }
}

function Get-NxGpuPreferenceState {
    <#
        Read-only report of the per-user DirectX GPU preference state:
        per-app UserGpuPreferences values (value name = exe path, data
        'GpuPreference=<1|2>;') plus the parsed DirectXUserGlobalSettings
        components (VRROptimizeEnable / SwapEffectUpgradeEnable / observed
        AutoHDREnable with an explicit not-Microsoft-documented honesty
        label when present).
    #>
    [CmdletBinding()]
    param()
    $path = 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences'
    $keyPresent = $false
    $perApp = @()
    $components = [ordered]@{}
    $globalExisted = $false; $globalRaw = $null
    $uncertainty = @()
    try {
        if (Test-Path $path) {
            $keyPresent = $true
            $key = Get-Item -Path $path -ErrorAction Stop
            foreach ($vname in @($key.GetValueNames())) {
                $data = $key.GetValue($vname, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($vname -eq 'DirectXUserGlobalSettings') {
                    $globalExisted = $true
                    $globalRaw = [string]$data
                    $components = ConvertTo-NxDirectXGlobalComponents -SettingsString $globalRaw
                    continue
                }
                $pref = $null; $prefLabel = 'Uncertain'
                if (([string]$data) -match 'GpuPreference\s*=\s*([0-9]+)') {
                    $pref = $Matches[1]
                    switch ($pref) {
                        '1' { $prefLabel = 'PowerSaving' }
                        '2' { $prefLabel = 'HighPerformance' }
                        default { $prefLabel = 'ObservedOther' }
                    }
                }
                $appExists = $false
                if ($vname -like '?:\*') { $appExists = Test-Path -LiteralPath $vname }
                $perApp += [pscustomobject]@{
                    appPath          = $vname
                    appExists        = $appExists
                    rawValue         = [string]$data
                    gpuPreferenceValue = $pref
                    preferenceLabel  = $prefLabel
                }
            }
        }
    } catch { $uncertainty += "UserGpuPreferences read failed: $($_.Exception.Message)" }

    $compStates = @()
    foreach ($cn in @('VRROptimizeEnable','SwapEffectUpgradeEnable','AutoHDREnable')) {
        $present = $components.Contains($cn)
        $val = $null; $stateText = 'Default-MissingComponent'
        if ($present) {
            $val = [string]$components[$cn]
            if ($val -eq '1') { $stateText = 'Enabled' }
            elseif ($val -eq '0') { $stateText = 'Disabled' }
            else { $stateText = 'UncertainValue' }
        }
        $honesty = 'reference-corroborated component of the DirectX global settings value'
        if ($cn -eq 'AutoHDREnable') { $honesty = 'community-known component - NOT Microsoft-documented; NEXTRIX reports it read-only and never writes it' }
        $compStates += [pscustomobject]@{
            component = $cn; present = $present; value = $val
            state = $stateText; documentationHonesty = $honesty
        }
    }

    return [pscustomobject]@{
        path = $path
        keyPresent = $keyPresent
        directXGlobalSettings = [pscustomobject]@{
            existed = $globalExisted
            rawValue = $globalRaw
            componentStates = $compStates
        }
        perAppPreferences = $perApp
        uncertainty = $uncertainty
    }
}

function Get-NxGameFsoState {
    <#
        Read-only FSO/presentation-policy state (SynToolkit FsoDetection
        model, r4): six HKCU System\GameConfigStore DWORDs (missing value =
        enabled-position; non-DWORD kind reported as mismatch), observed
        global-forcing combos flagged with citations (never claimed as
        exact semantics - build-conditional, E0), per-app compat Layers
        override check (community-known DISABLEDXMAXIMIZEDWINDOWEDMODE
        flag; documented activation route is the Compatibility tab), and
        the machine __COMPAT_LAYER value when present.
    #>
    [CmdletBinding()]
    param([string]$AppPath)

    $policyPath = 'HKCU:\System\GameConfigStore'
    $policyNames = @(
        'GameDVR_EFSEFeatureFlags','GameDVR_FSEBehaviorMode','GameDVR_FSEBehavior',
        'GameDVR_DSEBehavior','GameDVR_DXGIHonorFSEWindowsCompatible','GameDVR_HonorUserFSEBehaviorMode'
    )
    $values = @(); $uncertainty = @()

    foreach ($n in $policyNames) {
        $raw = $null
        try { $raw = Get-NxRegistryValueRaw -Path $policyPath -Name $n }
        catch { $uncertainty += "GameConfigStore read failed for ${n}: $($_.Exception.Message)" }
        if ($null -eq $raw) {
            $values += [pscustomobject]@{ name = $n; present = $false; kind = $null; value = $null; state = 'Default-Missing' }
            continue
        }
        if (-not $raw.existed) {
            $values += [pscustomobject]@{ name = $n; present = $false; kind = $null; value = $null; state = 'Default-Missing' }
            continue
        }
        if ($raw.kind -ne 'DWord') {
            $values += [pscustomobject]@{ name = $n; present = $true; kind = $raw.kind; value = $raw.value; state = 'KindMismatch' }
            continue
        }
        $values += [pscustomobject]@{ name = $n; present = $true; kind = 'DWord'; value = [int]$raw.value; state = 'Present-DWord' }
    }

    $getVal = {
        param($nm)
        $v = ($values | Where-Object { $_.name -eq $nm })
        if ($v -and $v.present -and $v.kind -eq 'DWord') { return [int]$v.value }
        return $null
    }
    $fseMode  = & $getVal 'GameDVR_FSEBehaviorMode'
    $honorMode = & $getVal 'GameDVR_HonorUserFSEBehaviorMode'
    $fseBehavior = & $getVal 'GameDVR_FSEBehavior'

    $forcingComboDetected = $null
    if ($null -ne $fseMode -and $null -ne $honorMode -and $null -ne $fseBehavior) {
        if ($fseMode -eq 1 -and $honorMode -eq 1 -and $fseBehavior -eq 2) {
            $forcingComboDetected = 'Observed global FSE forcing combo (Vain, r3) - build-conditional semantics, flagged for restore-to-default guidance only'
        }
        elseif ($fseMode -eq 2 -and $honorMode -eq 2 -and $fseBehavior -eq 2) {
            $forcingComboDetected = 'Observed global FSE forcing combo (community-observed disabled-FSO pattern) - build-conditional semantics, flagged for restore-to-default guidance only'
        }
    }

    $divergent = @($values | Where-Object { $_.state -ne 'Default-Missing' })
    $classification = 'Default-EnabledPosition'
    if ($forcingComboDetected) { $classification = 'GlobalForcingComboDetected' }
    elseif ($divergent.Count -gt 0) { $classification = 'Modified' }

    $override = $null
    if ($AppPath) {
        $hkcuLayersPath = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
        $hklmLayersPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
        $hkcuRaw = $null; $hkcuPresent = $false
        $hklmRaw = $null; $hklmPresent = $false
        try {
            $r = Get-NxRegistryValueRaw -Path $hkcuLayersPath -Name $AppPath
            if ($r.existed) { $hkcuRaw = [string]$r.value; $hkcuPresent = ($hkcuRaw -match 'DISABLEDXMAXIMIZEDWINDOWEDMODE') }
        } catch { $uncertainty += "HKCU Layers read failed: $($_.Exception.Message)" }
        try {
            $r = Get-NxRegistryValueRaw -Path $hklmLayersPath -Name $AppPath
            if ($r.existed) { $hklmRaw = [string]$r.value; $hklmPresent = ($hklmRaw -match 'DISABLEDXMAXIMIZEDWINDOWEDMODE') }
        } catch { $uncertainty += "HKLM Layers read failed: $($_.Exception.Message)" }
        $override = [pscustomobject]@{
            appPath = $AppPath
            hkcuLayerRaw = $hkcuRaw
            hkcuOverridePresent = $hkcuPresent
            hklmLayerRaw = $hklmRaw
            hklmOverridePresent = $hklmPresent
            flagHonesty = 'DISABLEDXMAXIMIZEDWINDOWEDMODE is community-known (Microsoft Q&A corroborated; Vain compound-string evidence, r3); the documented activation route is the executable Compatibility tab - NEXTRIX does not write this value.'
        }
    }

    $machineCompatLayer = $null
    try {
        $r = Get-NxRegistryValueRaw -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name '__COMPAT_LAYER'
        if ($r.existed) { $machineCompatLayer = [string]$r.value }
    } catch { $uncertainty += "machine __COMPAT_LAYER read failed: $($_.Exception.Message)" }

    return [pscustomobject]@{
        policyValues = $values
        policyClassification = $classification
        forcingComboDetected = $forcingComboDetected
        divergentValueCount = $divergent.Count
        perAppOverride = $override
        machineCompatLayer = $machineCompatLayer
        uncertainty = $uncertainty
    }
}

function Get-NxGameFsoOverrideGuide {
    <#
        NX04-005 guided workflow (read-only): the documented per-game route
        is the Compatibility tab; NEXTRIX never writes the community-known
        layer flag itself. Includes the documented-problem gate text and a
        read-only verification reader.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppPath)
    $state = Get-NxGameFsoState -AppPath $AppPath
    $appExists = $false
    try { $appExists = Test-Path -LiteralPath $AppPath -PathType Leaf } catch { }
    return [pscustomobject]@{
        tweakId = 'NX04-005'
        appPath = $AppPath
        appExists = $appExists
        risk = 'TROUBLESHOOTING'
        documentedProblemGate = 'Apply ONLY against a named game with a documented FSO-related symptom class (stutter/latency/alt-tab behavior) confirmed by the owner - never as a general tweak. Global FSO disable is forbidden (directive; Vain global forcing rejected r3).'
        mechanismAvailability = 'DocumentedOwnerUiRoute'
        guidedSteps = @(
            'Right-click the game executable -> Properties -> Compatibility tab.',
            'Check "Disable fullscreen optimizations" -> OK (this writes the app-compat Layers value through the documented UI).',
            'Relaunch the game and test the documented symptom.',
            'Verify read-only: Get-NxGameFsoState -AppPath <exe> shows hkcuOverridePresent=true.'
        )
        honestyStatement = 'The underlying Layers flag (DISABLEDXMAXIMIZEDWINDOWEDMODE) is community-known, not Microsoft-documented - NEXTRIX does not write it; the Compatibility tab is the documented route.'
        currentState = $state
    }
}

function Get-NxGamePresentationPolicyReport {
    <#
        NX04-007 read-only classification of the GameConfigStore
        fullscreen-presentation policy with guided restore-to-default
        (XOS pattern, r1: delete divergent override values). NEXTRIX never
        writes a non-default presentation policy.
    #>
    [CmdletBinding()]
    param()
    $state = Get-NxGameFsoState
    $divergent = @($state.policyValues | Where-Object { $_.state -ne 'Default-Missing' })
    return [pscustomobject]@{
        tweakId = 'NX04-007'
        policyValues = $state.policyValues
        policyClassification = $state.policyClassification
        forcingComboDetected = $state.forcingComboDetected
        divergentValues = $divergent
        policyGuidance = 'Restore-to-default guidance (XOS pattern, r1): delete the divergent GameConfigStore override values so Windows default FSO behavior returns. NEXTRIX v0.1 reports read-only; a later version may ship the journaled restore function. NEXTRIX never writes a non-default presentation policy (Vain forcing rejected, r3).'
        restartNote = 'Policy applies to newly launched games.'
        honestyStatement = 'Value semantics are build-conditional (E0); combos are flagged as observed forcing patterns with citations, never claimed as exact documented semantics.'
        uncertainty = $state.uncertainty
    }
}

function Get-NxAutoHdrReport {
    <#
        NX04-004 read-only Auto HDR context report. HONESTY: no
        Microsoft-documented registry write exists for the per-display Auto
        HDR toggle; the community-known AutoHDREnable component is reported
        read-only and never written; display HDR capability is not exposed
        via the WMI/registry routes NxCore uses.
    #>
    [CmdletBinding()]
    param()
    $adaptersData = Get-NxGpuAdaptersInternal
    $pref = Get-NxGpuPreferenceState
    $autoHdrComponent = @($pref.directXGlobalSettings.componentStates | Where-Object { $_.component -eq 'AutoHDREnable' })[0]
    return [pscustomobject]@{
        tweakId = 'NX04-004'
        displays = $adaptersData.adapters
        autoHdrComponentState = $autoHdrComponent
        hdrCapabilityNote = 'Display HDR capability is not exposed through the WMI/registry routes NxCore uses; the Settings > System > Display > HDR page is the authoritative per-display capability view (honest limitation).'
        documentedActivationRoute = 'Settings > System > Display > HDR > Auto HDR (per HDR-capable display; Microsoft support article "HDR settings in Windows").'
        honestyStatement = 'No Microsoft-documented registry write exists for the per-display Auto HDR toggle; the community-known AutoHDREnable component is reported read-only and never written by NEXTRIX.'
        uncertainty = @($adaptersData.uncertainty) + @($pref.uncertainty)
    }
}

function Get-NxHybridGraphicsReport {
    <#
        NX04-008 read-only topology + routing report feeding NX04-002
        decisions. Vendor classification via PCI vendor IDs; VRAM via the
        64-bit class-key route; current per-app routing cross-referenced.
        iGPU/dGPU naming beyond vendor classification is deliberately NOT
        guessed from VRAM heuristics (directive Section 9 honesty).
    #>
    [CmdletBinding()]
    param()
    $adaptersData = Get-NxGpuAdaptersInternal
    $vendorAdapters = @($adaptersData.adapters | Where-Object { $_.vendor -ne 'None' })
    $class = 'NoVendorAdapter'
    if ($vendorAdapters.Count -eq 1) { $class = 'SingleVendorAdapter' }
    elseif ($vendorAdapters.Count -ge 2) { $class = 'MultiAdapter-RoutingRelevant' }
    $pref = Get-NxGpuPreferenceState
    $vendors = @($adaptersData.adapters | ForEach-Object { $_.vendor } | Select-Object -Unique)
    return [pscustomobject]@{
        tweakId = 'NX04-008'
        adapters = $adaptersData.adapters
        vendorsPresent = $vendors
        topologyClass = $class
        routingRelevant = ($vendorAdapters.Count -ge 2)
        routingEntries = $pref.perAppPreferences
        topologyHonesty = 'Adapter vendor classification is PCI-VID based; iGPU/dGPU roles are not guessed beyond that (no VRAM heuristic naming).'
        profileNote = 'P3 Laptop Gamer: hybrid-graphics routing is the standing-rule focus; desktops with iGPU+dGPU qualify equally (PROFILE_MATRIX).'
        uncertainty = @($adaptersData.uncertainty) + @($pref.uncertainty)
    }
}

# ============================================================================
# Vendor status helpers (read-only; documented interfaces only)
# ============================================================================

function Get-NxNvidiaStatus {
    <#
        Read-only NVIDIA status: WMI/registry driver data always; documented
        nvidia-smi status queries (driver version, p-state, persistence mode,
        compute mode) when the tool is present - read-only queries ONLY.
        Per-profile settings are NOT part of nvidia-smi's documented write
        surface and are never attempted. Vendor gating is double-enforced
        (compat resolver requiredHardware.gpuVendor + this check).
    #>
    [CmdletBinding()]
    param()
    $adaptersData = Get-NxGpuAdaptersInternal
    $nvidia = @($adaptersData.adapters | Where-Object { $_.vendor -eq 'NVIDIA' })
    $present = @($adaptersData.adapters | ForEach-Object { $_.vendor })
    if ($nvidia.Count -eq 0) {
        return [pscustomobject]@{
            vendor = 'NVIDIA'; supported = $false
            reason = "no NVIDIA adapter detected (vendors present: $($present -join ', '))"
            mechanismAvailability = 'VendorHardwareAbsent'
            adapters = $adaptersData.adapters
            uncertainty = $adaptersData.uncertainty
        }
    }
    $smiRecords = @(); $smiUncertainty = @()
    $smi = Get-Command -Name nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($smi) {
        $queryArgs = @('--query-gpu=name,driver_version,pstate,persistence_mode,compute_mode','--format=csv,noheader,nounits')
        $out = @()
        try { $out = & $smi.Path @queryArgs 2>$null } catch { $smiUncertainty += "nvidia-smi query failed: $($_.Exception.Message)" }
        if ($LASTEXITCODE -ne 0 -and @($out).Count -eq 0 -and $smiUncertainty.Count -eq 0) {
            $smiUncertainty += "nvidia-smi exited with code $LASTEXITCODE (elevation or driver RPC may be required)"
        }
        foreach ($line in @($out)) {
            $parts = @($line -split ',') | ForEach-Object { $_.Trim() }
            if ($parts.Count -ge 5) {
                $smiRecords += [pscustomobject]@{
                    name = $parts[0]; driverVersion = $parts[1]; pstate = $parts[2]
                    persistenceMode = $parts[3]; computeMode = $parts[4]
                }
            }
        }
    } else {
        $smiUncertainty += 'nvidia-smi not found on PATH - status limited to WMI/registry driver data (read-only; per-profile settings remain vendor-tool territory in any case)'
    }
    $hags = Get-NxHagsCapability
    return [pscustomobject]@{
        vendor = 'NVIDIA'; supported = $true
        mechanismAvailability = 'StatusOnly'
        adapters = $nvidia
        nvidiaSmi = [pscustomobject]@{
            available = [bool]$smi
            records = $smiRecords
            documentedInterface = 'https://docs.nvidia.com/deploy/nvidia-smi/index.html'
            queryScope = 'read-only status queries (driver version, p-state, persistence mode, compute mode)'
        }
        hags = $hags
        mechanismNote = 'Per-profile NVIDIA driver settings (NX04-009..NX04-016) are stored in NVIDIA proprietary profile stores and are NOT writable through documented native Windows APIs; NVIDIA App / NVIDIA Control Panel is the documented route. Even XOS bundles NVIDIA Profile Inspector for this (r1).'
        uncertainty = @($adaptersData.uncertainty) + $smiUncertainty
    }
}

function Get-NxAmdStatus {
    <#
        Read-only AMD status: driver version via WMI/registry is the
        documented read route (always available). Radeon per-profile
        settings are driven by AMD Software: Adrenalin; no documented
        consumer CLI status interface exists for per-profile state - stated
        honestly rather than papered over.
    #>
    [CmdletBinding()]
    param()
    $adaptersData = Get-NxGpuAdaptersInternal
    $amd = @($adaptersData.adapters | Where-Object { $_.vendor -eq 'AMD' })
    $present = @($adaptersData.adapters | ForEach-Object { $_.vendor })
    $supported = ($amd.Count -gt 0)
    $reason = $null
    if (-not $supported) { $reason = "no AMD adapter detected (vendors present: $($present -join ', '))" }
    $mech = 'StatusOnly'
    if (-not $supported) { $mech = 'VendorHardwareAbsent' }
    return [pscustomobject]@{
        vendor = 'AMD'; supported = $supported
        reason = $reason
        mechanismAvailability = $mech
        adapters = $amd
        mechanismNote = 'Radeon per-profile settings (NX04-017..NX04-022) are driven by AMD Software: Adrenalin and are NOT writable through documented native Windows APIs. Driver version via WMI/registry is the documented read route used here; no documented consumer CLI status interface exists for Radeon per-profile state - stated honestly.'
        uncertainty = $adaptersData.uncertainty
    }
}

function Get-NxIntelStatus {
    <#
        Read-only Intel status: driver version via WMI/registry is the
        documented read route. Intel per-game settings are managed through
        Intel Graphics Software; scriptable vendor interfaces are limited -
        stated plainly per the catalogue note.
    #>
    [CmdletBinding()]
    param()
    $adaptersData = Get-NxGpuAdaptersInternal
    $intel = @($adaptersData.adapters | Where-Object { $_.vendor -eq 'Intel' })
    $present = @($adaptersData.adapters | ForEach-Object { $_.vendor })
    $supported = ($intel.Count -gt 0)
    $reason = $null
    if (-not $supported) { $reason = "no Intel adapter detected (vendors present: $($present -join ', '))" }
    $mech = 'StatusOnly'
    if (-not $supported) { $mech = 'VendorHardwareAbsent' }
    return [pscustomobject]@{
        vendor = 'Intel'; supported = $supported
        reason = $reason
        mechanismAvailability = $mech
        adapters = $intel
        mechanismNote = 'Intel per-game settings (NX04-023) are managed through Intel Graphics Software; scriptable vendor interfaces are LIMITED - stated honestly. Driver version via WMI/registry is the documented read route used here.'
        uncertainty = $adaptersData.uncertainty
    }
}

# ============================================================================
# Vendor guided workflow (read-only; the honest substitute for a
# driver-profile write NEXTRIX cannot and will not fake)
# ============================================================================

$script:NxVendorSettingMeta = @{
    NVIDIA = @{
        powerManagementMode = @{
            label = 'Power management mode'
            route = 'NVIDIA App / NVIDIA Control Panel -> Manage 3D Settings -> Program Settings -> <game> -> Power management mode'
            behavior = 'NVIDIA documents Power management mode as controlling how the driver manages GPU power and clock behavior per profile (Manage 3D Settings reference - source recorded in the registry entry documentationSource). NEXTRIX asserts no outcome.'
            doc = 'https://www.nvidia.com/content/Control-Panel-Help/vLatest/en-us/mergedProjects/nv3d/Manage_3D_Settings_(reference).htm'
        }
        lowLatencyMode = @{
            label = 'Low Latency Mode'
            route = 'NVIDIA App / NVIDIA Control Panel -> Manage 3D Settings -> Program Settings -> <game> -> Low Latency Mode'
            behavior = 'NVIDIA documents Low Latency Mode as controlling render-queue depth behavior (frames submitted "just in time" per the vendor reference). Vendor-documented description only - TWEAK_RESEARCH section 15 lists per-profile Low Latency Mode as pending owner evidence.'
            doc = 'https://www.nvidia.com/content/Control-Panel-Help/vLatest/en-us/mergedProjects/nv3d/Manage_3D_Settings_(reference).htm'
        }
        verticalSyncMode = @{
            label = 'Vertical sync'
            route = 'NVIDIA App / NVIDIA Control Panel -> Manage 3D Settings -> Program Settings -> <game> -> Vertical sync'
            behavior = 'NVIDIA documents Vertical sync as controlling the application frame-presentation synchronization mode per profile, with vendor-documented interplay notes (e.g. with G-SYNC-capable displays).'
            doc = 'https://www.nvidia.com/content/Control-Panel-Help/vLatest/en-us/mergedProjects/nv3d/Manage_3D_Settings_(reference).htm'
        }
        maxFrameRate = @{
            label = 'Max Frame Rate'
            route = 'NVIDIA App / NVIDIA Control Panel -> Manage 3D Settings -> Program Settings -> <game> -> Max Frame Rate'
            behavior = 'NVIDIA documents Maximum Frame Rate as a driver-level per-profile frame-rate cap. Cap semantics stated exactly; no smoothness/latency outcome claimed.'
            doc = 'https://www.nvidia.com/content/Control-Panel-Help/vLatest/en-us/mergedProjects/nv3d/Manage_3D_Settings_(reference).htm'
        }
        threadedOptimization = @{
            label = 'Threaded Optimization'
            route = 'NVIDIA App / NVIDIA Control Panel -> Manage 3D Settings -> Program Settings -> <game> -> Threaded Optimization'
            behavior = 'NVIDIA documents Threaded Optimization as controlling multi-threaded shader optimization per profile (vendor reference scope stated exactly).'
            doc = 'https://www.nvidia.com/content/Control-Panel-Help/vLatest/en-us/mergedProjects/nv3d/Manage_3D_Settings_(reference).htm'
        }
        textureFilteringQuality = @{
            label = 'Texture filtering quality family'
            route = 'NVIDIA App / NVIDIA Control Panel -> Manage 3D Settings -> Program Settings -> <game> -> texture filtering settings'
            behavior = 'NVIDIA documents the texture-filtering quality controls (quality level, anisotropic sample optimizer, negative LOD bias) as per-profile image-quality settings with a vendor-stated quality-vs-throughput trade-off direction.'
            doc = 'https://www.nvidia.com/content/Control-Panel-Help/vLatest/en-us/mergedProjects/nv3d/Manage_3D_Settings_(reference).htm'
        }
        shaderCachePolicy = @{
            label = 'Shader cache policy'
            route = 'NVIDIA App / NVIDIA Control Panel -> Manage 3D Settings (global/program) -> Shader Cache'
            behavior = 'Shader cache controls are vendor-documented but driver-version-conditional (catalogue E0). NEXTRIX records no cache-size-forcing guidance and no cache-clearing rituals - honesty over ritual.'
            doc = 'https://www.nvidia.com/content/Control-Panel-Help/vLatest/en-us/mergedProjects/nv3d/Manage_3D_Settings_(reference).htm'
        }
        perGameProfileFramework = @{
            label = 'NVIDIA per-game profile framework (composition of NX04-009..015)'
            route = 'NVIDIA App / NVIDIA Control Panel -> Manage 3D Settings -> Program Settings per game; NVIDIA Profile Inspector (.nip) is the community tool the reference projects bundle (r1, r4) - recorded as a tool-interface note only, never downloaded or executed by NEXTRIX'
            behavior = 'Composition entry: each of NX04-009..015 is delivered through its documented vendor route with the same honesty rule - per-profile settings are not writable through documented native Windows APIs.'
            doc = 'https://www.nvidia.com/content/Control-Panel-Help/vLatest/en-us/mergedProjects/nv3d/Manage_3D_Settings_(reference).htm'
        }
    }
    AMD = @{
        antiLag = @{
            label = 'Radeon Anti-Lag / Anti-Lag+'
            route = 'AMD Software: Adrenalin -> Games -> <game> -> Graphics -> Radeon Anti-Lag (per-game application profile, AMD DH3-033/DH3-012)'
            behavior = 'AMD documents Anti-Lag as reducing input-to-response lag by dynamically adjusting frame timing, best in GPU-limited scenarios (DH3-033). Vendor-documented description only.'
            antiCheat = 'Documented incident: Radeon Anti-Lag+ triggered anti-cheat bans (Call of Duty Ricochet; CS2 VAC reports) and AMD disabled Anti-Lag+ in Adrenalin 23.10.2 (AMD statement, Oct 2023). Per-title verification during owner testing is mandatory (anti-cheat is a first-class gate).'
            doc = 'https://www.amd.com/en/resources/support-articles/faqs/DH3-033.html'
        }
        radeonChill = @{
            label = 'Radeon Chill'
            route = 'AMD Software: Adrenalin -> Games -> <game> -> Graphics -> Radeon Chill (per-game profile)'
            behavior = 'AMD documents Chill as a power-saving feature that dynamically regulates frame rate between an owner-set minimum and maximum based on in-game movement (DH3-033) - a bounded dynamic cap, not a fixed limiter and not a latency feature.'
            doc = 'https://www.amd.com/en/resources/support-articles/faqs/DH3-033.html'
        }
        enhancedSync = @{
            label = 'Radeon Enhanced Sync'
            route = 'AMD Software: Adrenalin -> Games -> <game> -> Graphics -> Enhanced Sync'
            behavior = 'AMD documents Enhanced Sync as the driver v-sync alternative allowing tearing only when frame rate exceeds the display refresh rate. Vendor-stated semantics only; behavior is display/VRR-conditional.'
            doc = 'https://www.amd.com/en/resources/support-articles/faqs/DH3-033.html'
        }
        waitForVerticalRefresh = @{
            label = 'Wait for Vertical Refresh'
            route = 'AMD Software: Adrenalin -> Games -> <game> -> Graphics -> Wait for Vertical Refresh'
            behavior = 'AMD documents Wait for Vertical Refresh as the per-profile v-sync control with documented mode positions from Always Off to Always On around application control.'
            doc = 'https://www.amd.com/en/resources/support-articles/faqs/DH3-033.html'
        }
        surfaceFormatOptimization = @{
            label = 'Surface Format Optimization'
            route = 'AMD Software: Adrenalin -> Graphics settings (global) -> Surface Format Optimization'
            behavior = 'Vendor-documented setting enabling compressed surface formats - the trade-off direction is image quality (catalogue note, E0). Owner visual verification recommended; no outcome claim.'
            doc = 'https://www.amd.com/en/resources/support-articles/faqs/DH3-012.html'
        }
        perGameProfileFramework = @{
            label = 'AMD per-game profile framework + shader cache (composition of NX04-017..021)'
            route = 'AMD Software: Adrenalin per-game application profiles (DH3-012); shader-cache setting is driver-version-conditional vendor tooling - guidance only, no size forcing, no clearing rituals'
            behavior = 'Composition entry: each of NX04-017..021 is delivered through its documented AMD Software route with the same honesty rule; the Anti-Lag+ anti-cheat note from NX04-017 is carried into every composition.'
            doc = 'https://www.amd.com/en/resources/support-articles/faqs/DH3-012.html'
        }
    }
    Intel = @{
        intelGraphicsFramework = @{
            label = 'Intel graphics / Arc settings framework'
            route = 'Intel Graphics Software -> per-game/application profiles (applies stored settings automatically)'
            behavior = 'Intel documents Intel Graphics Software applying stored per-game settings automatically; scriptable vendor interfaces are LIMITED - stated honestly per the catalogue note. Driver version via WMI/registry is the documented read route used here.'
            doc = 'https://www.intel.com/content/www/us/en/products/details/discrete-gpus/arc/software/graphics-software.html'
        }
    }
}

function Get-NxVendorGraphicsGuide {
    <#
        The honest engine function behind NX04-009..NX04-023: a vendor-gated
        guided workflow. Read-only. mechanismAvailability is ALWAYS
        'VendorToolRequired' for per-profile settings - the function reports
        the documented route, the vendor-documented behavior (quoted with
        source), the current vendor status snapshot and the anti-cheat note
        when applicable. It never writes anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('NVIDIA','AMD','Intel')][string]$Vendor,
        [Parameter(Mandatory)][string]$SettingKey,
        [switch]$PerGame
    )
    $status = $null
    switch ($Vendor) {
        'NVIDIA' { $status = Get-NxNvidiaStatus }
        'AMD'    { $status = Get-NxAmdStatus }
        'Intel'  { $status = Get-NxIntelStatus }
    }
    $m = $null
    if ($script:NxVendorSettingMeta.ContainsKey($Vendor) -and $script:NxVendorSettingMeta[$Vendor].ContainsKey($SettingKey)) {
        $m = $script:NxVendorSettingMeta[$Vendor][$SettingKey]
    }
    if ($null -eq $m) {
        return [pscustomobject]@{
            vendor = $Vendor; settingKey = $SettingKey; supported = $false
            mechanismAvailability = 'UnknownSettingKey'
            reason = "unknown settingKey '$SettingKey' for vendor $Vendor"
        }
    }
    if (-not $status.supported) {
        return [pscustomobject]@{
            vendor = $Vendor; settingKey = $SettingKey; supported = $false
            mechanismAvailability = 'VendorHardwareAbsent'
            reason = $status.reason
            eligibilityNote = 'requiredHardware.gpuVendor gating already excludes this machine (compat resolver) - the guide refuses to run vendor guidance on other vendors hardware (directive).'
            uncertainty = $status.uncertainty
        }
    }
    return [pscustomobject]@{
        vendor = $Vendor
        settingKey = $SettingKey
        perGame = $PerGame.IsPresent
        supported = $true
        mechanismAvailability = 'VendorToolRequired'
        settingLabel = $m.label
        documentedRoute = $m.route
        vendorDocumentedBehavior = $m.behavior
        antiCheatNote = $m.antiCheat
        documentation = $m.doc
        vendorStatus = $status
        windowsSideXref = 'NX04-002 (Set-NxGpuPreference) - Windows-side per-app GPU routing is the OS-level companion to driver-profile settings.'
        honestyStatement = 'Per-profile driver settings are not writable through documented native Windows APIs. NEXTRIX performs no write here; configuration happens in the vendor documented tooling, and this snapshot is recorded for before/after comparison. Vendor behavior text is quoted with source; NEXTRIX asserts no performance outcome.'
    }
}

# ============================================================================
# Journaled write functions (documented routes only; standard pipeline)
# ============================================================================

function Set-NxGpuPreference {
    <#
        NX04-002 journaled write: per-app GPU preference
        (HKCU UserGpuPreferences, value named after the exe path, data
        'GpuPreference=<1|2>;' - the Microsoft-documented mechanism family).
        -Plan performs the read-only capture + plan report and never writes.
        -Approved + -JournalRoot are mandatory for real application;
        journal-first, verify-after, best-effort restore on failed verify
        (NxApply 10-step pattern).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppPath,
        [Parameter(Mandatory)][ValidateSet('PowerSaving','HighPerformance')][string]$Preference,
        [string]$TweakId = 'NX04-002',
        [string]$Approval = 'Selection',
        [string]$JournalRoot,
        [string[]]$Profiles = @(),
        [switch]$Plan,
        [switch]$Approved
    )
    $steps = New-Object System.Collections.Generic.List[object]
    $summary = [pscustomobject]@{ tweakId = $TweakId; plan = $Plan.IsPresent; appPath = $AppPath; preference = $Preference; steps = $steps }

    # Step 1: capability - the per-app value is NAMED after the executable
    # path, so the exe must exist (refuse a write for a nonexistent app).
    $appExists = $false
    try { $appExists = Test-Path -LiteralPath $AppPath -PathType Leaf } catch { }
    if (-not $appExists) {
        $steps.Add([pscustomobject]@{ step = 1; name = 'capability'; outcome = 'Skip'; detail = "target exe not found: $AppPath (the per-app value is named after the executable path - refusing a write for a nonexistent app)" })
        $summary | Add-Member -NotePropertyName failed -NotePropertyValue $true
        return $summary
    }
    $steps.Add([pscustomobject]@{ step = 1; name = 'capability'; outcome = 'Pass'; detail = "target exe exists: $AppPath" })

    # Approval gate: real application requires -Approved (never automatic).
    if (-not $Plan -and -not $Approved) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    if (-not $Plan) {
        if (-not $JournalRoot) { throw "$TweakId : -JournalRoot is required for a journaled write" }
        Assert-NxWritePipeline
    }

    $prefValueMap = @{ 'PowerSaving' = 1; 'HighPerformance' = 2 }
    $dataString = "GpuPreference=$($prefValueMap[$Preference]);"
    $path = 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences'

    # Steps 2-6: capture exact original (read-only).
    $orig = Capture-NxRegistryValue -Path $path -Name $AppPath
    $steps.Add([pscustomobject]@{ step = 2; name = 'capture-original'; outcome = 'Captured'; detail = "path=$path keyExisted=$($orig.keyExisted) existed=$($orig.existed) kind=$($orig.kind)" })

    $modified = [pscustomobject]@{ targetType = 'registry'; path = $path; name = $AppPath; kind = 'String'; value = $dataString }
    if ($Plan) {
        $steps.Add([pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Planned'; detail = "would set $path :: <app exe value name> = String:$dataString" })
        return $summary
    }

    # Step 7: journal BEFORE any mutation (journal-first invariant).
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion '1' -Operation 'apply' -Approval $Approval -Original $orig -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        # Step 8: apply.
        Set-NxRegistryValue -Path $path -Name $AppPath -Kind 'String' -Value $dataString
        # Step 9: verify configuration effect.
        $check = Test-NxConfigurationState -Path $path -Name $AppPath -Kind 'String' -ExpectedValue $dataString
        # Step 10: journal the result.
        $res = 'Success'
        if (-not $check.verified) { $res = 'FailedVerification' }
        $verText = 'NotVerified'
        if ($check.verified) { $verText = 'Verified' }
        $jr2 = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion '1' -Operation 'verify' -Approval $Approval -Original $orig -Modified $modified -Result $res -Verification $verText -Profiles $Profiles
        $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = $verText; detail = $check.reason })
        if (-not $check.verified) {
            # Safe stop + best-effort restore of the exact original (NxApply pattern).
            if ($orig.existed) {
                Set-NxRegistryValue -Path $path -Name $AppPath -Kind ([string]$orig.kind) -Value $orig.value
            } elseif (Test-Path $path) {
                Remove-ItemProperty -Path $path -Name $AppPath -ErrorAction SilentlyContinue
            }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion '1' -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles | Out-Null
            $summary | Add-Member -NotePropertyName failed -NotePropertyValue $true
            return $summary
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion '1' -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        $steps.Add([pscustomobject]@{ step = 8; name = 'apply'; outcome = 'FAILED'; detail = [string]$_.Exception.Message })
        $summary | Add-Member -NotePropertyName failed -NotePropertyValue $true
        return $summary
    }
    $steps.Add([pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Applied'; detail = "seq $($jr.seq) -> verified seq $($jr2.seq)" })
    $summary | Add-Member -NotePropertyName applied -NotePropertyValue $true
    return $summary
}

function Set-NxDirectXGlobalSetting {
    <#
        NX04-003 journaled component write: read-modify-write of ONE
        component inside HKCU UserGpuPreferences :: DirectXUserGlobalSettings
        (INI-style string). The same value hosts SwapEffectUpgradeEnable
        (mechanism owned by NX02-005) and the community-known AutoHDREnable
        component NEXTRIX never writes - hence a single shared composer is
        the only safe write path (a declarative whole-value write would
        clobber siblings and duplicate the NX02-005 target).
        AutoHDREnable is deliberately NOT in the writable component set.
        -Plan performs the read-only capture + composed-plan report and
        never writes. -Approved + -JournalRoot mandatory for real writes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('VRROptimizeEnable','SwapEffectUpgradeEnable')][string]$Component,
        [Parameter(Mandatory)][ValidateRange(0,1)][int]$Value,
        [string]$TweakId = 'NX04-003',
        [string]$Approval = 'Selection',
        [string]$JournalRoot,
        [string[]]$Profiles = @(),
        [switch]$Plan,
        [switch]$Approved
    )
    $steps = New-Object System.Collections.Generic.List[object]
    $summary = [pscustomobject]@{ tweakId = $TweakId; plan = $Plan.IsPresent; component = $Component; value = $Value; steps = $steps }

    # Approval gate: real application requires -Approved (never automatic).
    if (-not $Plan -and -not $Approved) {
        throw "$TweakId : real application requires -Approved (nothing applies without explicit approval evidence)"
    }
    if (-not $Plan) {
        if (-not $JournalRoot) { throw "$TweakId : -JournalRoot is required for a journaled write" }
        Assert-NxWritePipeline
    }

    $path = 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences'
    $name = 'DirectXUserGlobalSettings'

    # Steps 2-6: capture exact original whole value (read-only).
    $orig = Capture-NxRegistryValue -Path $path -Name $name
    $components = ConvertTo-NxDirectXGlobalComponents -SettingsString ([string]$orig.value)
    $siblingCount = @($components.Keys).Count
    $steps.Add([pscustomobject]@{ step = 2; name = 'capture-original'; outcome = 'Captured'; detail = "path=$path name=$name keyExisted=$($orig.keyExisted) existed=$($orig.existed) kind=$($orig.kind) siblingComponents=$siblingCount" })

    # Read-modify-write: set ONE component, preserve every other component.
    $components[$Component] = [string]$Value
    $newString = ConvertTo-NxDirectXGlobalSettingsString -Components $components
    $steps.Add([pscustomobject]@{ step = 8; name = 'compose'; outcome = 'Composed'; detail = "component $Component=$Value; preserved siblings: $((@($components.Keys) | Where-Object { $_ -ne $Component }) -join ', ')" })

    $modified = [pscustomobject]@{ targetType = 'registry'; path = $path; name = $name; kind = 'String'; value = $newString }
    if ($Plan) {
        $steps.Add([pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Planned'; detail = "would set $path :: $name = String:$newString (component compose, siblings preserved)" })
        return $summary
    }

    # Step 7: journal BEFORE any mutation (journal-first invariant).
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion '1' -Operation 'apply' -Approval $Approval -Original $orig -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        # Step 8: apply the composed whole value.
        Set-NxRegistryValue -Path $path -Name $name -Kind 'String' -Value $newString
        # Step 9: verify the whole value (the value is the atomic unit).
        $check = Test-NxConfigurationState -Path $path -Name $name -Kind 'String' -ExpectedValue $newString
        # Step 10: journal the result + component-level re-parse report.
        $res = 'Success'
        if (-not $check.verified) { $res = 'FailedVerification' }
        $verText = 'NotVerified'
        if ($check.verified) { $verText = 'Verified' }
        $jr2 = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion '1' -Operation 'verify' -Approval $Approval -Original $orig -Modified $modified -Result $res -Verification $verText -Profiles $Profiles
        $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = $verText; detail = $check.reason })
        if (-not $check.verified) {
            if ($orig.existed) {
                Set-NxRegistryValue -Path $path -Name $name -Kind ([string]$orig.kind) -Value $orig.value
            } elseif (Test-Path $path) {
                Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue
            }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion '1' -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles | Out-Null
            $summary | Add-Member -NotePropertyName failed -NotePropertyValue $true
            return $summary
        }
        # Component-level re-parse report (read-only, informational).
        $live = Capture-NxRegistryValue -Path $path -Name $name
        $liveComponents = ConvertTo-NxDirectXGlobalComponents -SettingsString ([string]$live.value)
        $steps.Add([pscustomobject]@{ step = 10; name = 'component-report'; outcome = 'Reported'; detail = "components after apply: $(@($liveComponents.Keys) -join ', ')" })
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion '1' -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        $steps.Add([pscustomobject]@{ step = 8; name = 'apply'; outcome = 'FAILED'; detail = [string]$_.Exception.Message })
        $summary | Add-Member -NotePropertyName failed -NotePropertyValue $true
        return $summary
    }
    $steps.Add([pscustomobject]@{ step = 8; name = 'apply'; outcome = 'Applied'; detail = "seq $($jr.seq) -> verified seq $($jr2.seq)" })
    $summary | Add-Member -NotePropertyName applied -NotePropertyValue $true
    return $summary
}
