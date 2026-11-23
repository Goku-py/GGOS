#Requires -Version 5.1
<#
    NX10.ps1 - NEXTRIX Thermal Management functions (category NX10, entries NX10-001..008).

    MUTATION SURFACE (declared per SECURITY_POLICY.md Section 4):
      NONE for NX10-001..007. Those functions perform read-only queries only:
        - Get-CimInstance: Win32_Processor, Win32_VideoController, Win32_Battery,
          Win32_Fan, Win32_SystemEnclosure, Win32_TemperatureProbe,
          root\WMI MSAcpi_ThermalZoneTemperature, root\WMI BatteryStatus.
        - Get-Counter: '\Processor Information(_Total)\% of Maximum Frequency',
          '\Thermal Zone Information(*)\Temperature'.
        - powercfg.exe /getactivescheme and /query (READ-ONLY subcommands only).
        - nvidia-smi.exe --query-gpu / --help-query-gpu (READ-ONLY; never -pl, -lgc,
          -lmc, -r, -e, -dm or any setter).
      NX10-008 (Invoke-NxThermalSessionLog) writes EXACTLY ONE file at the
      owner-chosen -OutputPath (plus its parent directory if missing) and performs
      no Windows configuration change. It NEVER writes to %ProgramData% implicitly:
      the path is a mandatory parameter.
      This file never writes registry values, services, tasks, power settings,
      firmware, fan curves or OEM interfaces.

    CATEGORY DIRECTIVE (TWEAK_CATALOGUE.md NX10):
      - NO universal fan-control registry tweaks and NO firmware modifications.
      - Monitoring/diagnostic only; NEXTRIX never changes fan behaviour.
      - No performance claims anywhere in this module: values are OS/vendor
        reported readings, never an outcome claim.

    UNCERTAINTY VOCABULARY (mandatory - a fabricated number is never emitted):
      'Uncertain-Unavailable'       the platform/driver does not expose the value;
                                    no number is invented.
      'Uncertain-VendorDependent'   a vendor-private interface would be required;
                                    NEXTRIX does not use undocumented ones.
      'Uncertain-NotConclusive'     a signal was read but cannot be classified
                                    (e.g. reduced clock frequency is not proof of
                                    thermal throttling).
      'Uncertain-SourceDisagreement' two documented/observed sources disagree;
                                    both values are reported side by side.

    DATA SOURCES AND THEIR LIMITS (each report states its own as well):
      1. Win32_TemperatureProbe (root\cimv2) - E1, Microsoft-documented BUT the
         documentation states CurrentReading is not populated by current WMI
         implementations. A zero-instance or zero-reading result is EXPECTED and is
         reported as Uncertain-Unavailable, never as 0 degrees.
      2. MSAcpi_ThermalZoneTemperature (root\WMI) - E0 provenance: the class is
         present on most ACPI machines and returns tenths of degrees KELVIN
         (verified live: 3232 = 323.2 K = 50.0 C), but no current Microsoft
         documentation page for the class was verifiable on 2026-11-23. Zone names
         (ACPI\ThermalZone\THRM_0) are opaque: a zone is not guaranteed to be a CPU
         package sensor.
      3. '\Thermal Zone Information(*)\Temperature' performance counter - E0
         provenance: present and readable on this machine (Kelvin), no verified
         Microsoft documentation page. Counter names are localized, so non-English
         Windows fails closed into Uncertain-Unavailable.
      4. Win32_Processor CurrentClockSpeed/MaxClockSpeed/LoadPercentage - E1
         (documented properties). CurrentClockSpeed is frequently static on modern
         firmware, so a 1:1 ratio is NOT proof that no throttling occurs.
      5. '\Processor Information(_Total)\% of Maximum Frequency' - E0 provenance,
         advisory only: a value below 100 while the CPU is busy may be power
         management, thermal, or firmware policy - NEXTRIX never classifies it as
         throttling (classifiedAsThrottle is always $false in this module).
      6. nvidia-smi.exe --query-gpu - E1 vendor-documented (NVIDIA System
         Management Interface). Fields may be reported as '[N/A]' per device/driver
         (observed live: power.limit [N/A] while enforced.power.limit = 60.00 W);
         '[N/A]' is reported as Uncertain-Unavailable for that field only.
      7. AMD/Intel GPU telemetry - Uncertain-VendorDependent: AMD ADL/Radeon
         Software and Intel IGCL are SDK/GUI surfaces with no vendor-documented,
         WMI-based read contract used by NEXTRIX.
      8. Win32_Fan - E1 (documented), but DesiredSpeed is the CURRENTLY REQUESTED
         speed (revolutions per minute) when VariableSpeed is true, not a measured
         tachometer value, and most consumer firmware omits the class entirely
         (0 instances is normal, not an error).
      9. powercfg /query - E1 (documented command). English output format is
         parsed; a localized system fails the parse CLOSED (parseOk=false) and the
         caller reports Uncertain-Unavailable instead of guessing.

    BOUNDARIES:
      - NX09 owns every power-plan WRITE (active scheme, per-plan AC/DC indexes,
        hibernation, Fast Startup). NX10 only READS powercfg output.
      - NX03 owns processor power settings (SUB_PROCESSOR min/max/boost writes).
        NX10 reports them as context and never writes them.
      - NX09-012 owns OEM performance-mode detection; NX10-006 detects OEM
        cooling/fan interfaces (namespaces/classes/services) without invoking any
        method.
      - No elevation is required for the reads themselves; a hardened machine may
        restrict performance-counter access, which is reported, not hidden.

    PRIVACY / LOG PROTECTION (SECURITY_POLICY.md Section 3):
      - No computer name, user name, SID, serial, token or credential is emitted by
        any function here. Get-Counter's CounterSamples.Path is deliberately NOT
        used because it embeds '\\<computername>'.
      - NX10-008's journal record stores only the log file's LEAF name (a full path
        can contain a user name), plus durations and counts.

    Required core modules: NxJournal.ps1 (Read-NxManifest, Add-NxJournalEntry).
    Self-test: tools/selftests/Test-NX10.ps1 (temp-only, no system mutation).
#>

# ---------------------------------------------------------------------------
# A. Constants and shared vocabulary
# ---------------------------------------------------------------------------

$script:Nx10Unavailable       = 'Uncertain-Unavailable'
$script:Nx10VendorDependent   = 'Uncertain-VendorDependent'
$script:Nx10NotConclusive     = 'Uncertain-NotConclusive'
$script:Nx10SourceDisagreement = 'Uncertain-SourceDisagreement'

# Documented power-setting GUIDs used for READ-ONLY context (never written here).
$script:Nx10ProcessorSubgroup      = '54533251-82be-4824-96c1-47b60b740d00'   # SUB_PROCESSOR (NX03 territory for writes)
$script:Nx10SettingMaxProcessor    = 'bc5038f7-23e0-4960-96da-33abaf5935ec'   # PROCTHROTTLEMAX ("Maximum processor state")
$script:Nx10SettingMinProcessor    = '893dee8e-2bef-41e0-89c6-b55d0929964c'   # PROCTHROTTLEMIN ("Minimum processor state")
$script:Nx10SettingBoostMode       = 'be337238-0d82-4146-a960-4f3749d470c7'   # PERFBOOSTMODE ("Processor performance boost mode")
$script:Nx10SettingCoolingPolicy   = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'   # SYSCOOLPOL ("System cooling policy")

# NVML clocks-event bit names, in ascending bit order. The NAMES are the ones
# nvidia-smi documents under "Clocks Event Reasons"; the bit assignment comes from
# the NVML enum documented at https://docs.nvidia.com/deploy/nvml-api/index.html .
# Stored as an ordered list of pairs (not a hashtable): Windows PowerShell 5.1
# mis-binds hex numeric hashtable-literal keys, so pairs are explicit and testable.
$script:Nx10ThrottleBits = @(
    [pscustomobject]@{ bit = 1;    name = 'GpuIdle' }
    [pscustomobject]@{ bit = 2;    name = 'ApplicationsClocksSetting' }
    [pscustomobject]@{ bit = 4;    name = 'SwPowerCap' }
    [pscustomobject]@{ bit = 8;    name = 'HwSlowdown' }
    [pscustomobject]@{ bit = 16;   name = 'SyncBoost' }
    [pscustomobject]@{ bit = 32;   name = 'SwThermalSlowdown' }
    [pscustomobject]@{ bit = 64;   name = 'HwThermalSlowdown' }
    [pscustomobject]@{ bit = 128;  name = 'HwPowerBrakeSlowdown' }
    [pscustomobject]@{ bit = 256;  name = 'DisplayClockSetting' }
)

# ---------------------------------------------------------------------------
# B. Generic helpers (read-only, no external state)
# ---------------------------------------------------------------------------

function Get-Nx10TruncatedText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [int]$Max = 300)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return ($Text.Substring(0, $Max) + '...[truncated]')
}

function ConvertTo-Nx10NullableNumber {
    <#
        nvidia-smi prints '[N/A]' for unsupported fields. Convert numeric text to
        [double] or $null - never 0, so a missing value cannot look like a reading.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return $null }
    $t = $Text.Trim()
    if ($t.Length -eq 0) { return $null }
    if ($t -match '^(?i)\[?N/?A\]?$') { return $null }
    $d = 0.0
    if ([double]::TryParse($t, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function ConvertFrom-Nx10KelvinTenths {
    <#
        MSAcpi_ThermalZoneTemperature.CurrentTemperature is tenths of degrees Kelvin.
        Returns $null for implausible values instead of publishing a garbage number.
        Plausibility window: 1732..3732 tenths K (-100.0 C .. +100.0 C).
    #>
    param([Parameter(Mandatory)][int]$TenthsKelvin)
    if ($TenthsKelvin -lt 1732 -or $TenthsKelvin -gt 3732) { return $null }
    $kelvin = $TenthsKelvin / 10.0
    return [pscustomobject][ordered]@{
        kelvin  = [math]::Round($kelvin, 1)
        celsius = [math]::Round($kelvin - 273.15, 1)
    }
}

function ConvertFrom-Nx10Kelvin {
    param([Parameter(Mandatory)][double]$Kelvin)
    if ($Kelvin -lt 173.2 -or $Kelvin -gt 373.2) { return $null }
    return [pscustomobject][ordered]@{
        kelvin  = [math]::Round($Kelvin, 1)
        celsius = [math]::Round($Kelvin - 273.15, 1)
    }
}

function ConvertFrom-Nx10ThrottleMask {
    <#
        Decodes an NVML clocks-event bitmask into documented reason names.
        Unknown bits are reported as 'UnknownBit0x...' rather than guessed.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Mask)
    if ([string]::IsNullOrWhiteSpace($Mask)) {
        return [pscustomobject][ordered]@{ maskHex = $null; reasons = @(); unknownBits = @() }
    }
    $t = $Mask.Trim()
    $value = [int64]0
    $parsed = $false
    if ($t -match '^0x([0-9a-fA-F]+)$') {
        try { $value = [Convert]::ToInt64($Matches[1], 16); $parsed = $true } catch { $parsed = $false }
    } else {
        if ([int64]::TryParse($t, [ref]$value)) { $parsed = $true }
    }
    if (-not $parsed) {
        return [pscustomobject][ordered]@{ maskHex = $t; reasons = @(); unknownBits = @(); parseOk = $false }
    }
    $reasons = New-Object System.Collections.Generic.List[string]
    $unknown = New-Object System.Collections.Generic.List[string]
    $known = [int64]0
    foreach ($entry in $script:Nx10ThrottleBits) {
        $known = $known -bor [int64]$entry.bit
        if (($value -band [int64]$entry.bit) -eq [int64]$entry.bit) { $reasons.Add([string]$entry.name) }
    }
    $rest = $value -band (-bnot $known)
    if ($rest -ne 0) { $unknown.Add(('0x{0:x}' -f $rest)) }
    return [pscustomobject][ordered]@{
        maskHex = ('0x{0:x}' -f $value)
        reasons = $reasons.ToArray()
        unknownBits = $unknown.ToArray()
        parseOk = $true
    }
}

function Invoke-Nx10External {
    <#
        Bounded read-only external command runner (nvidia-smi / powercfg).
        Uses System.Diagnostics.Process directly so a wedged driver cannot block the
        wizard: the child is killed after -TimeoutMs and the timeout is reported.
        No temp files, no shell, no output redirection to disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutMs = 10000
    )
    $result = [pscustomobject][ordered]@{
        ok        = $false
        timedOut  = $false
        exitCode  = $null
        output    = ''
        error     = ''
        command   = ('"' + $FilePath + '" ' + (($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')).Trim()
    }
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        $result.error = "executable not found: $FilePath"
        return $result
    }
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.Arguments = (($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
        try { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        try { $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 } catch { }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit($TimeoutMs)
        if (-not $exited) {
            $result.timedOut = $true
            try { $proc.Kill() } catch { }
            try { $null = $proc.WaitForExit(2000) } catch { }
        }
        try { if ($outTask.Wait(3000)) { $result.output = [string]$outTask.Result } } catch { }
        try { if ($errTask.Wait(3000)) { $result.error = [string]$errTask.Result } } catch { }
        if (-not $result.timedOut) {
            try { $result.exitCode = [int]$proc.ExitCode } catch { $result.exitCode = $null }
        }
        $result.ok = ((-not $result.timedOut) -and $result.exitCode -eq 0)
    } catch {
        $result.error = [string]$_.Exception.Message
    } finally {
        if ($null -ne $proc) { try { $proc.Dispose() } catch { } }
    }
    return $result
}

# ---------------------------------------------------------------------------
# C. Source collectors (one function per data source; every one uncertainty-marked)
# ---------------------------------------------------------------------------

function Get-Nx10CpuClock {
    <# Win32_Processor (documented) + the advisory '% of Maximum Frequency' counter. #>
    [CmdletBinding()]
    param()
    $unc = @()
    $processors = @()
    try {
        foreach ($p in @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)) {
            $processors += [pscustomobject][ordered]@{
                name            = [string]$p.Name
                loadPercent     = $(if ($null -ne $p.LoadPercentage) { [int]$p.LoadPercentage } else { $null })
                currentClockMhz = $(if ($null -ne $p.CurrentClockSpeed) { [int]$p.CurrentClockSpeed } else { $null })
                maxClockMhz     = $(if ($null -ne $p.MaxClockSpeed) { [int]$p.MaxClockSpeed } else { $null })
                cores           = $(if ($null -ne $p.NumberOfCores) { [int]$p.NumberOfCores } else { $null })
            }
        }
    } catch {
        $unc += "Win32_Processor read failed: $([string]$_.Exception.Message)"
    }
    if ($processors.Count -eq 0 -and $unc.Count -eq 0) { $unc += 'Win32_Processor returned no instances' }

    $headline = $(if ($processors.Count -gt 0) { $processors[0] } else { $null })
    $ratio = $null
    if ($null -ne $headline -and $null -ne $headline.currentClockMhz -and $null -ne $headline.maxClockMhz -and $headline.maxClockMhz -gt 0) {
        $ratio = [math]::Round(($headline.currentClockMhz / $headline.maxClockMhz) * 100.0, 1)
    }

    $pctMaxFreq = $null
    $pctState = $script:Nx10Unavailable
    try {
        $sample = Get-Counter -Counter '\Processor Information(_Total)\% of Maximum Frequency' -ErrorAction Stop
        $cs = @($sample.CounterSamples)
        if ($cs.Count -gt 0 -and $null -ne $cs[0].CookedValue) {
            $pctMaxFreq = [math]::Round([double]$cs[0].CookedValue, 1)
            $pctState = 'Available'
        } else {
            $unc += 'percent-of-maximum-frequency counter returned no samples'
        }
    } catch {
        # Localized counter names / hardened perf counters land here. Read-only, so
        # this is uncertainty - never a fabricated fallback.
        $unc += "percent-of-maximum-frequency counter unavailable: $([string]$_.Exception.Message)"
    }

    return [pscustomobject][ordered]@{
        processors             = $processors
        currentClockMhz        = $(if ($null -ne $headline) { $headline.currentClockMhz } else { $null })
        maxClockMhz            = $(if ($null -ne $headline) { $headline.maxClockMhz } else { $null })
        loadPercent            = $(if ($null -ne $headline) { $headline.loadPercent } else { $null })
        clockRatioPercent      = $ratio
        clockRatioNote         = 'CurrentClockSpeed is often static on modern firmware; a 100% ratio is not proof that no throttling occurs.'
        percentOfMaximumFrequency = $pctMaxFreq
        frequencyCounterState  = $pctState
        frequencyCounterSource = '\Processor Information(_Total)\% of Maximum Frequency (E0 provenance; advisory only)'
        uncertainty            = $unc
    }
}

function Get-Nx10AcpiThermalZones {
    <# MSAcpi_ThermalZoneTemperature (root\WMI), tenths of degrees Kelvin. #>
    [CmdletBinding()]
    param()
    $zones = @()
    $unc = @()
    try {
        foreach ($z in @(Get-CimInstance -Namespace 'root\WMI' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop)) {
            $raw = $null
            if ($null -ne $z.CurrentTemperature) { $raw = [int]$z.CurrentTemperature }
            $conv = $null
            if ($null -ne $raw) { $conv = ConvertFrom-Nx10KelvinTenths -TenthsKelvin $raw }
            if ($null -ne $raw -and $null -eq $conv) {
                $unc += "zone '$($z.InstanceName)' reported implausible CurrentTemperature $raw (expected tenths of Kelvin)"
            }
            $passive = $null; $critical = $null
            if ($null -ne $z.PassiveTripPoint) {
                $c = ConvertFrom-Nx10KelvinTenths -TenthsKelvin ([int]$z.PassiveTripPoint)
                if ($null -ne $c) { $passive = $c.celsius }
            }
            if ($null -ne $z.CriticalTripPoint) {
                $c = ConvertFrom-Nx10KelvinTenths -TenthsKelvin ([int]$z.CriticalTripPoint)
                if ($null -ne $c) { $critical = $c.celsius }
            }
            $zones += [pscustomobject][ordered]@{
                instanceName       = [string]$z.InstanceName
                rawTenthsKelvin    = $raw
                temperatureCelsius = $(if ($null -ne $conv) { $conv.celsius } else { $null })
                temperatureKelvin  = $(if ($null -ne $conv) { $conv.kelvin } else { $null })
                active             = $(if ($null -ne $z.Active) { [bool]$z.Active } else { $null })
                passiveTripCelsius = $passive
                criticalTripCelsius = $critical
            }
        }
    } catch {
        $unc += "root\WMI MSAcpi_ThermalZoneTemperature read failed: $([string]$_.Exception.Message)"
    }
    if ($zones.Count -eq 0 -and $unc.Count -eq 0) { $unc += 'MSAcpi_ThermalZoneTemperature returned no instances' }
    $readable = @($zones | Where-Object { $null -ne $_.temperatureCelsius })
    return [pscustomobject][ordered]@{
        source     = 'MSAcpi_ThermalZoneTemperature (root\WMI)'
        units      = 'tenths of degrees Kelvin'
        evidence   = 'E0'
        limitation = 'Class presence is not documented on current Microsoft Learn; zone names are opaque (a zone is not guaranteed to be a CPU package sensor).'
        state      = $(if ($readable.Count -gt 0) { 'Available' } else { $script:Nx10Unavailable })
        zones      = $zones
        maxCelsius = $(if ($readable.Count -gt 0) { ($readable | Measure-Object -Property temperatureCelsius -Maximum).Maximum } else { $null })
        uncertainty = $unc
    }
}

function Get-Nx10ThermalZoneCounters {
    <# '\Thermal Zone Information(*)\Temperature' (Kelvin). Path is never exposed (hostname). #>
    [CmdletBinding()]
    param()
    $zones = @()
    $unc = @()
    try {
        $sample = Get-Counter -Counter '\Thermal Zone Information(*)\Temperature' -ErrorAction Stop
        foreach ($cs in @($sample.CounterSamples)) {
            $conv = $null
            if ($null -ne $cs.CookedValue) { $conv = ConvertFrom-Nx10Kelvin -Kelvin ([double]$cs.CookedValue) }
            if ($null -ne $cs.CookedValue -and $null -eq $conv) {
                $unc += "counter instance '$($cs.InstanceName)' reported implausible temperature $($cs.CookedValue) K"
            }
            $inst = [string]$cs.InstanceName
            if ($inst.StartsWith('\')) { $inst = $inst.Substring(1) }
            $zones += [pscustomobject][ordered]@{
                instanceName       = $inst
                rawKelvin          = $(if ($null -ne $cs.CookedValue) { [math]::Round([double]$cs.CookedValue, 1) } else { $null })
                temperatureCelsius = $(if ($null -ne $conv) { $conv.celsius } else { $null })
            }
        }
    } catch {
        $unc += "Thermal Zone Information counter unavailable (localized counter names fail closed): $([string]$_.Exception.Message)"
    }
    $readable = @($zones | Where-Object { $null -ne $_.temperatureCelsius })
    if ($zones.Count -eq 0 -and $unc.Count -eq 0) { $unc += 'Thermal Zone Information counter returned no instances' }
    return [pscustomobject][ordered]@{
        source     = '\Thermal Zone Information(*)\Temperature'
        units      = 'Kelvin'
        evidence   = 'E0'
        limitation = 'No verified Microsoft documentation page; counter-set names are localized. Values are OS-reported zone temperatures, not package sensors.'
        state      = $(if ($readable.Count -gt 0) { 'Available' } else { $script:Nx10Unavailable })
        zones      = $zones
        maxCelsius = $(if ($readable.Count -gt 0) { ($readable | Measure-Object -Property temperatureCelsius -Maximum).Maximum } else { $null })
        uncertainty = $unc
    }
}

function Get-Nx10TemperatureProbe {
    <# Win32_TemperatureProbe (documented) - documented as NOT populated by WMI. #>
    [CmdletBinding()]
    param()
    $probes = @()
    $unc = @()
    try {
        foreach ($p in @(Get-CimInstance -ClassName Win32_TemperatureProbe -ErrorAction Stop)) {
            $reading = $null
            if ($null -ne $p.CurrentReading) { $reading = [int]$p.CurrentReading }
            $probes += [pscustomobject][ordered]@{
                deviceId            = [string]$p.DeviceID
                name                = [string]$p.Name
                status              = [string]$p.Status
                currentReadingTenthsCelsius = $reading
                temperatureCelsius  = $(if ($null -ne $reading -and $reading -ne 0) { [math]::Round($reading / 10.0, 1) } else { $null })
            }
        }
    } catch {
        $unc += "Win32_TemperatureProbe read failed: $([string]$_.Exception.Message)"
    }
    $readable = @($probes | Where-Object { $null -ne $_.temperatureCelsius })
    return [pscustomobject][ordered]@{
        source     = 'Win32_TemperatureProbe (root\cimv2)'
        units      = 'tenths of degrees Celsius'
        evidence   = 'E1'
        limitation = 'Microsoft documents that current WMI implementations do not populate CurrentReading (the property is reserved for future use), so zero instances or zero readings are expected and are reported as unavailable.'
        state      = $(if ($readable.Count -gt 0) { 'Available' } else { $script:Nx10Unavailable })
        probes     = $probes
        uncertainty = $unc
    }
}

function Get-Nx10GpuAdapters {
    <# Win32_VideoController inventory with PCI vendor mapping (read-only). #>
    [CmdletBinding()]
    param()
    $adapters = @()
    $unc = @()
    $vendorMap = @{ '10DE' = 'NVIDIA'; '1002' = 'AMD'; '8086' = 'Intel' }
    try {
        foreach ($c in @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)) {
            $vendor = 'Uncertain'
            $ven = $null
            if ([string]$c.PNPDeviceID -match 'VEN_([0-9A-Fa-f]{4})') { $ven = $Matches[1].ToUpperInvariant() }
            if ($null -ne $ven -and $vendorMap.ContainsKey($ven)) { $vendor = $vendorMap[$ven] }
            elseif ([string]$c.Name -match '(?i)Microsoft Basic Display|Microsoft Remote Display') { $vendor = 'None' }
            else { $unc += "unmapped GPU vendor for adapter '$([string]$c.Name)' (VEN_$ven)" }
            $adapters += [pscustomobject][ordered]@{
                name          = [string]$c.Name
                vendor        = $vendor
                driverVersion = [string]$c.DriverVersion
                pnpDeviceId   = [string]$c.PNPDeviceID
                status        = [string]$c.Status
            }
        }
    } catch {
        $unc += "Win32_VideoController read failed: $([string]$_.Exception.Message)"
    }
    return [pscustomobject][ordered]@{ adapters = $adapters; uncertainty = $unc }
}

function Get-Nx10NvidiaSmiPath {
    [CmdletBinding()]
    param()
    $candidates = @()
    $cmd = Get-Command -Name 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and $cmd.Source) { $candidates += [string]$cmd.Source }
    if ($env:SystemRoot) { $candidates += (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe') }
    if (${env:ProgramFiles}) { $candidates += (Join-Path ${env:ProgramFiles} 'NVIDIA Corporation\NVSMI\nvidia-smi.exe') }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    return $null
}

function Get-Nx10NvidiaSnapshot {
    <#
        Single read-only nvidia-smi query (one process invocation) covering
        temperature, clocks, power, fan and clocks-event reasons. Degrades to
        'index,name,temperature.gpu' when a driver rejects a field.
        Never calls a setter (-pl/-lgc/-lmc/-r/-e/-dm are never used).
    #>
    [CmdletBinding()]
    param([int]$TimeoutMs = 10000)
    $unc = @()
    $path = Get-Nx10NvidiaSmiPath
    if (-not $path) {
        return [pscustomobject][ordered]@{
            available = $false
            path = $null
            gpus = @()
            degraded = $false
            queryFields = $null
            state = $script:Nx10VendorDependent
            uncertainty = @('nvidia-smi.exe not found - NVIDIA telemetry unavailable on this machine (expected when no NVIDIA driver tooling is installed)')
        }
    }

    $fullFields = 'index,name,temperature.gpu,clocks.current.graphics,clocks.max.graphics,power.draw,power.limit,power.default_limit,power.max_limit,enforced.power.limit,fan.speed,utilization.gpu,clocks_throttle_reasons.active,clocks_throttle_reasons.gpu_idle,clocks_throttle_reasons.sw_power_cap,clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown'
    $minFields = 'index,name,temperature.gpu'
    $query = Invoke-Nx10External -FilePath $path -Arguments @(('--query-gpu=' + $fullFields), '--format=csv,noheader,nounits') -TimeoutMs $TimeoutMs
    $fields = $fullFields
    $degraded = $false
    if (-not $query.ok) {
        $degraded = $true
        $unc += "full nvidia-smi field query failed (exit $($query.exitCode)): $(Get-Nx10TruncatedText ($query.error + ' ' + $query.output) 160)"
        $query = Invoke-Nx10External -FilePath $path -Arguments @(('--query-gpu=' + $minFields), '--format=csv,noheader,nounits') -TimeoutMs $TimeoutMs
        $fields = $minFields
    }
    if (-not $query.ok) {
        return [pscustomobject][ordered]@{
            available = $false
            path = $path
            gpus = @()
            degraded = $degraded
            queryFields = $fields
            state = $script:Nx10Unavailable
            uncertainty = @($unc + "nvidia-smi query failed (exit $($query.exitCode), timedOut=$($query.timedOut)): $(Get-Nx10TruncatedText ($query.error + ' ' + $query.output) 200)")
        }
    }

    $gpus = @()
    foreach ($line in @($query.output -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = @($line -split ',' | ForEach-Object { $_.Trim() })
        if ($parts.Count -lt 3) { $unc += "unparseable nvidia-smi line: $(Get-Nx10TruncatedText $line 120)"; continue }
        $rec = [ordered]@{
            index        = $(if ($null -ne (ConvertTo-Nx10NullableNumber $parts[0])) { [int](ConvertTo-Nx10NullableNumber $parts[0]) } else { $null })
            name         = [string]$parts[1]
            temperatureCelsius = ConvertTo-Nx10NullableNumber $parts[2]
        }
        # Optional columns: present only in the full field profile.
        $col = 3
        foreach ($name in @('currentGraphicsClockMhz','maxGraphicsClockMhz','powerDrawWatts','powerLimitWatts','powerDefaultLimitWatts','powerMaxLimitWatts','enforcedPowerLimitWatts','fanPercent','utilizationGpuPercent')) {
            $rec[$name] = $null
            if ($fields -eq $fullFields -and $parts.Count -gt $col) { $rec[$name] = ConvertTo-Nx10NullableNumber $parts[$col] }
            $col++
        }
        $rec['throttleMask'] = $null
        $rec['throttleReasons'] = @()
        $rec['throttleNamed'] = [ordered]@{}
        if ($fields -eq $fullFields -and $parts.Count -gt $col) {
            $rec['throttleMask'] = [string]$parts[$col]
            $decoded = ConvertFrom-Nx10ThrottleMask -Mask ([string]$parts[$col])
            $rec['throttleReasons'] = @($decoded.reasons)
            $col++
            foreach ($named in @('gpuIdle','swPowerCap','hwSlowdown','hwThermalSlowdown','swThermalSlowdown')) {
                if ($parts.Count -gt $col) { $rec['throttleNamed'][$named] = [string]$parts[$col] }
                $col++
            }
        }
        $gpus += [pscustomobject]$rec
    }
    if ($gpus.Count -eq 0) { $unc += 'nvidia-smi returned no GPU rows' }

    # Per-field [N/A] honesty: name the fields the driver refused.
    foreach ($g in $gpus) {
        foreach ($f in @('temperatureCelsius','powerLimitWatts','enforcedPowerLimitWatts','fanPercent')) {
            if ($null -eq $g.$f) { $unc += "GPU $($g.index): field '$f' reported [N/A] by nvidia-smi (not supported on this device/driver)" }
        }
    }
    return [pscustomobject][ordered]@{
        available = $true
        path = $path
        gpus = $gpus
        degraded = $degraded
        queryFields = $fields
        state = $(if (@($gpus | Where-Object { $null -ne $_.temperatureCelsius }).Count -gt 0) { 'Available' } else { $script:Nx10Unavailable })
        uncertainty = $unc
    }
}

function Get-Nx10PowerSource {
    <# AC/DC state from Win32_Battery (documented) + root\WMI BatteryStatus corroboration. #>
    [CmdletBinding()]
    param()
    $unc = @()
    $hasBattery = $false
    $batteryStatusRaw = $null
    $chargePercent = $null
    $powerOnline = $null
    try {
        $b = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $b) {
            $hasBattery = $true
            if ($null -ne $b.BatteryStatus) { $batteryStatusRaw = [int]$b.BatteryStatus }
            if ($null -ne $b.EstimatedChargeRemaining) { $chargePercent = [int]$b.EstimatedChargeRemaining }
        }
    } catch {
        $unc += "Win32_Battery read failed: $([string]$_.Exception.Message)"
    }
    try {
        $bs = Get-CimInstance -Namespace 'root\WMI' -ClassName 'BatteryStatus' -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $bs -and $null -ne $bs.PowerOnline) { $powerOnline = [bool]$bs.PowerOnline }
    } catch {
        # Older desktops and some firmware omit this class; not an error worth flagging
        # unless no other AC/DC signal exists (checked below).
    }

    $powerSource = $script:Nx10Unavailable
    $sourceDetail = 'no AC/DC signal available'
    $fromBatteryStatus = $null
    if ($null -ne $batteryStatusRaw) {
        switch ($batteryStatusRaw) {
            1 { $fromBatteryStatus = 'Battery'; $sourceDetail = 'Win32_Battery.BatteryStatus=1 (discharging)' }
            2 { $fromBatteryStatus = 'AC'; $sourceDetail = 'Win32_Battery.BatteryStatus=2 (system has AC access)' }
            3 { $fromBatteryStatus = 'AC'; $sourceDetail = 'Win32_Battery.BatteryStatus=3 (fully charged, AC connected)' }
            4 { $fromBatteryStatus = 'Battery'; $sourceDetail = 'Win32_Battery.BatteryStatus=4 (low)' }
            5 { $fromBatteryStatus = 'Battery'; $sourceDetail = 'Win32_Battery.BatteryStatus=5 (critical)' }
            6 { $fromBatteryStatus = 'AC'; $sourceDetail = 'Win32_Battery.BatteryStatus=6 (charging)' }
            7 { $fromBatteryStatus = 'AC'; $sourceDetail = 'Win32_Battery.BatteryStatus=7 (charging, high)' }
            8 { $fromBatteryStatus = 'AC'; $sourceDetail = 'Win32_Battery.BatteryStatus=8 (charging, low)' }
            9 { $fromBatteryStatus = 'AC'; $sourceDetail = 'Win32_Battery.BatteryStatus=9 (charging, critical)' }
            default { $sourceDetail = "Win32_Battery.BatteryStatus=$batteryStatusRaw not mapped to AC/DC" }
        }
    }
    if ($null -ne $powerOnline) {
        # PowerOnline is the more direct signal; report any disagreement with BatteryStatus.
        $powerSource = $(if ($powerOnline) { 'AC' } else { 'Battery' })
        $statusDetail = $(if ($null -ne $batteryStatusRaw) { "; $sourceDetail" } else { '' })
        $sourceDetail = 'root\WMI BatteryStatus.PowerOnline (E0 provenance)' + $statusDetail
        if ($null -ne $fromBatteryStatus -and $fromBatteryStatus -ne $powerSource) {
            $unc += "AC/DC signals disagree: PowerOnline=$powerOnline but Win32_Battery.BatteryStatus=$batteryStatusRaw implies $fromBatteryStatus; PowerOnline is reported"
        }
    } elseif ($null -ne $fromBatteryStatus) {
        $powerSource = $fromBatteryStatus
    } else {
        $unc += 'no battery present and no PowerOnline signal: this is a desktop without a battery, so AC/DC power-plane comparison does not apply'
    }
    return [pscustomobject][ordered]@{
        hasBattery          = $hasBattery
        powerSource         = $powerSource
        powerSourceDetail   = $sourceDetail
        batteryStatusRaw    = $batteryStatusRaw
        estimatedChargePercent = $chargePercent
        powerOnline         = $powerOnline
        uncertainty         = $unc
    }
}

function Get-Nx10PowerCfgSetting {
    <#
        READ-ONLY powercfg /query wrapper. Parses the documented English output:
        friendly names, units, enumerated 'Possible Setting Index / Friendly Name'
        pairs and the AC/DC indexes. Non-English output fails CLOSED (parseOk=false)
        so callers report uncertainty instead of publishing a wrong number.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubgroupGuid,
        [Parameter(Mandatory)][string]$SettingGuid,
        [string]$SchemeGuid = 'SCHEME_CURRENT'
    )
    $result = [pscustomobject][ordered]@{
        ok = $false; parseOk = $false; found = $false
        settingName = $null; units = $null
        acIndex = $null; dcIndex = $null
        acFriendlyName = $null; dcFriendlyName = $null
        possibleSettings = @()
        exitCode = $null; outputSample = ''
    }
    $exe = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        $result.outputSample = 'powercfg.exe not found'
        return $result
    }
    $r = Invoke-Nx10External -FilePath $exe -Arguments @('/query', $SchemeGuid, $SubgroupGuid, $SettingGuid) -TimeoutMs 15000
    $result.exitCode = $r.exitCode
    $result.outputSample = Get-Nx10TruncatedText (($r.output + ' ' + $r.error).Trim()) 300
    if (-not $r.ok) { return $result }
    $result.ok = $true

    $lines = @($r.output -split "\r?\n")
    $possible = @()
    $pendingIndex = $null
    $ac = $null; $dc = $null
    $nameSeen = $false
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t.Length -eq 0) { continue }
        if (-not $nameSeen -and $t -match '^Power Setting GUID:\s*[0-9a-fA-F\-]{36}\s+\((.+)\)\s*$') {
            $result.settingName = $Matches[1].Trim(); $nameSeen = $true; continue
        }
        if ($t -match '^Possible Settings units:\s*(.+)$') { $result.units = $Matches[1].Trim(); continue }
        if ($t -match '^Possible Setting Index:\s*(\d+)\s*$') { $pendingIndex = [int]$Matches[1]; continue }
        if ($t -match '^Possible Setting Friendly Name:\s*(.+)$') {
            $possible += [pscustomobject][ordered]@{ index = $pendingIndex; friendlyName = $Matches[1].Trim() }
            $pendingIndex = $null
            continue
        }
        if ($t -match '^Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)\s*$') { $ac = [Convert]::ToInt64($Matches[1], 16); continue }
        if ($t -match '^Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)\s*$') { $dc = [Convert]::ToInt64($Matches[1], 16); continue }
    }
    $result.possibleSettings = $possible
    # 'found' == the setting block was printed with at least one index (a query for a
    # setting absent from the plan prints only the scheme header - documented behavior).
    if ($null -ne $ac -or $null -ne $dc) {
        $result.found = $true
        $result.parseOk = $true
        $result.acIndex = $ac
        $result.dcIndex = $dc
        if ($null -ne $ac) {
            $m = @($possible | Where-Object { $_.index -eq $ac })
            if ($m.Count -gt 0) { $result.acFriendlyName = $m[0].friendlyName }
        }
        if ($null -ne $dc) {
            $m = @($possible | Where-Object { $_.index -eq $dc })
            if ($m.Count -gt 0) { $result.dcFriendlyName = $m[0].friendlyName }
        }
    } elseif ($lines.Count -gt 0 -and ($lines[0] -match '^Power Scheme GUID:')) {
        # Header parsed, no setting block: the setting is not exposed on this plan.
        $result.parseOk = $true
        $result.found = $false
    }
    return $result
}

function Get-Nx10ActiveScheme {
    <# READ-ONLY powercfg /getactivescheme. #>
    [CmdletBinding()]
    param()
    $result = [pscustomobject][ordered]@{ ok = $false; parseOk = $false; guid = $null; name = $null; outputSample = '' }
    $exe = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { $result.outputSample = 'powercfg.exe not found'; return $result }
    $r = Invoke-Nx10External -FilePath $exe -Arguments @('/getactivescheme') -TimeoutMs 15000
    $result.outputSample = Get-Nx10TruncatedText (($r.output + ' ' + $r.error).Trim()) 200
    if (-not $r.ok) { return $result }
    $result.ok = $true
    foreach ($line in @($r.output -split "\r?\n")) {
        $t = $line.Trim()
        if ($t -match '^Power Scheme GUID:\s*([0-9a-fA-F\-]{36})\s*(?:\((.+)\))?\s*$') {
            $result.guid = $Matches[1].ToLowerInvariant()
            if ($Matches[2]) { $result.name = ([string]$Matches[2]).Trim() }
            $result.parseOk = $true
            break
        }
    }
    return $result
}

function Test-Nx10JournalPresent {
    <# Local journal-presence probe so NX10 does not depend on NX09 being loaded. #>
    param([Parameter(Mandatory)][string]$JournalRoot)
    try {
        $state = Read-NxManifest -Path $JournalRoot
        return [bool]$state.present
    } catch { return $false }
}

function New-Nx10PlaneRecord {
    <#
        Projects one powercfg setting record into an AC/DC plane record. A missing
        setting is 'NotExposedOnActivePlan' (a known absence, not uncertainty); an
        unparseable query is 'Uncertain-Unavailable'. Friendly names come from the
        plan's own "Possible Setting Friendly Name" output - never hardcoded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][string]$Units
    )
    if (-not $Record.parseOk) {
        return [pscustomobject][ordered]@{ setting = $Label; state = $script:Nx10Unavailable; ac = $null; dc = $null; units = $Units; acMeaning = $null; dcMeaning = $null }
    }
    if (-not $Record.found) {
        return [pscustomobject][ordered]@{ setting = $Label; state = 'NotExposedOnActivePlan'; ac = $null; dc = $null; units = $Units; acMeaning = $null; dcMeaning = $null }
    }
    return [pscustomobject][ordered]@{
        setting = $Label
        state = 'Available'
        ac = $Record.acIndex
        dc = $Record.dcIndex
        units = $(if ($Record.units) { $Record.units } else { $Units })
        acMeaning = $Record.acFriendlyName
        dcMeaning = $Record.dcFriendlyName
    }
}

# ---------------------------------------------------------------------------
# D. NX10-001 - CPU temperature & throttling detection report (read-only)
# ---------------------------------------------------------------------------

function Get-NxCpuThermalReport {
    <#
    .SYNOPSIS
        Read-only CPU temperature and clock/throttle SIGNAL report (NX10-001).
    .DESCRIPTION
        Queries three temperature sources (Win32_TemperatureProbe, root\WMI
        MSAcpi_ThermalZoneTemperature, the Thermal Zone Information counter) and the
        documented processor-clock properties, then reports every reading together
        with its source, evidence level and limitation.

        A headline temperature is published ONLY when a single source is available or
        when the available sources agree within 5 C. Disagreement is reported as
        'Uncertain-SourceDisagreement' with both values - NEXTRIX never averages or
        picks a winner silently.

        Throttling is never asserted: classifiedAsThrottle is always $false and the
        assessment is 'NoSignalDetected', 'PossibleReducedFrequency-Uncertain' or
        'Uncertain-Unavailable', with its basis stated.
    #>
    [CmdletBinding()]
    param()
    $clock = Get-Nx10CpuClock
    $probe = Get-Nx10TemperatureProbe
    $acpi = Get-Nx10AcpiThermalZones
    $counter = Get-Nx10ThermalZoneCounters

    $unc = @()
    $unc += @($clock.uncertainty)
    $unc += @($probe.uncertainty)
    $unc += @($acpi.uncertainty)
    $unc += @($counter.uncertainty)

    $candidates = @()
    if ($null -ne $acpi.maxCelsius) { $candidates += [pscustomobject]@{ source = $acpi.source; celsius = [double]$acpi.maxCelsius } }
    if ($null -ne $counter.maxCelsius) { $candidates += [pscustomobject]@{ source = $counter.source; celsius = [double]$counter.maxCelsius } }
    if ($probe.state -eq 'Available') {
        $pv = @($probe.probes | Where-Object { $null -ne $_.temperatureCelsius } | Select-Object -First 1)
        if ($pv.Count -gt 0) { $candidates += [pscustomobject]@{ source = $probe.source; celsius = [double]$pv[0].temperatureCelsius } }
    }

    $headline = [pscustomobject][ordered]@{
        state      = $script:Nx10Unavailable
        celsius    = $null
        source     = $null
        comparison = @()
        note       = 'No OS-exposed CPU temperature source responded on this machine; no value is invented.'
    }
    if ($candidates.Count -eq 1) {
        $headline.state = 'Available'
        $headline.celsius = [math]::Round($candidates[0].celsius, 1)
        $headline.source = $candidates[0].source
        $headline.note = 'Single source available; no cross-check possible.'
    } elseif ($candidates.Count -gt 1) {
        $values = @($candidates | ForEach-Object { $_.celsius })
        $delta = [math]::Round((($values | Measure-Object -Maximum).Maximum - ($values | Measure-Object -Minimum).Minimum), 1)
        $headline.comparison = @($candidates | ForEach-Object { [pscustomobject][ordered]@{ source = $_.source; celsius = [math]::Round($_.celsius, 1) } })
        if ($delta -le 5.0) {
            $headline.state = 'Available'
            $headline.celsius = [math]::Round($candidates[0].celsius, 1)
            $headline.source = $candidates[0].source
            $headline.note = "Multiple sources agree within $delta C; the first source's value is shown and all values are listed in comparison."
        } else {
            $headline.state = $script:Nx10SourceDisagreement
            $headline.note = "Sources disagree by $delta C (threshold 5 C). NEXTRIX publishes no single value: they measure different zones and the OS does not expose which one is the CPU package. Use the owner's vendor tool for a package reading."
            $unc += "CPU temperature sources disagree by $delta C - reported side by side, not averaged"
        }
    }

    $assessment = [pscustomobject][ordered]@{
        conclusion  = $script:Nx10Unavailable
        basis       = 'OS-reported clock signals only. Reduced frequency is not diagnostic of thermal throttling (power management and firmware limits produce the same signal).'
        classifiedAsThrottle = $false
        observations = @()
        uncertainty = @()
    }
    if ($clock.frequencyCounterState -eq 'Available') {
        $obs = "percentOfMaximumFrequency=$($clock.percentOfMaximumFrequency); loadPercent=$($clock.loadPercent); clockRatioPercent=$($clock.clockRatioPercent)"
        $assessment.observations += $obs
        if ($null -ne $clock.percentOfMaximumFrequency -and $clock.percentOfMaximumFrequency -lt 99.0 -and $null -ne $clock.loadPercent -and $clock.loadPercent -ge 40) {
            $assessment.conclusion = 'PossibleReducedFrequency-Uncertain'
            $assessment.uncertainty += "OS reports $($clock.percentOfMaximumFrequency)% of maximum frequency at $($clock.loadPercent)% load. This may be power management, thermal policy or firmware - not classified."
        } else {
            $assessment.conclusion = 'NoSignalDetected'
        }
    } else {
        $assessment.uncertainty += 'percent-of-maximum-frequency counter unavailable - no throttle signal can be assessed'
        if ($null -ne $clock.clockRatioPercent -and $clock.clockRatioPercent -lt 99.0) {
            $assessment.conclusion = 'PossibleReducedFrequency-Uncertain'
            $assessment.uncertainty += "currentClockSpeed is $($clock.clockRatioPercent)% of maxClockSpeed, but CurrentClockSpeed is frequently static on modern firmware"
        }
    }
    if ($assessment.conclusion -eq $script:Nx10Unavailable -and $clock.clockRatioPercent -ne $null) {
        # Clock ratio readable but no counter: still not conclusive either way.
        $assessment.conclusion = $script:Nx10NotConclusive
    }

    return [pscustomobject][ordered]@{
        functionName = 'Get-NxCpuThermalReport'
        tweakId = 'NX10-001'
        category = 'NX10'
        readOnly = $true
        noWritesPerformed = $true
        cpu = [pscustomobject][ordered]@{
            name = $(if ($clock.processors.Count -gt 0) { $clock.processors[0].name } else { $null })
            processorCount = $clock.processors.Count
            loadPercent = $clock.loadPercent
            currentClockMhz = $clock.currentClockMhz
            maxClockMhz = $clock.maxClockMhz
            clockRatioPercent = $clock.clockRatioPercent
            percentOfMaximumFrequency = $clock.percentOfMaximumFrequency
            frequencyCounterState = $clock.frequencyCounterState
            clockRatioNote = $clock.clockRatioNote
        }
        temperature = [pscustomobject][ordered]@{
            headline = $headline
            sources = @($probe, $acpi, $counter)
        }
        throttleAssessment = $assessment
        dataSources = @(
            'Win32_TemperatureProbe (E1; documented as not populated by current WMI)',
            'MSAcpi_ThermalZoneTemperature root\WMI (E0 provenance; tenths of Kelvin)',
            '\Thermal Zone Information(*)\Temperature (E0 provenance; Kelvin)',
            'Win32_Processor CurrentClockSpeed/MaxClockSpeed/LoadPercentage (E1)',
            '\Processor Information(_Total)\% of Maximum Frequency (E0 provenance; advisory)'
        )
        uncertainty = $unc
        summary = 'CPU thermal report: every reading is attributed to its source; unavailable or disagreeing sources are marked Uncertain-* and no throttling conclusion is asserted.'
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ---------------------------------------------------------------------------
# E. NX10-002 - GPU temperature & throttling report (read-only)
# ---------------------------------------------------------------------------

function Get-NxGpuThermalReport {
    <#
    .SYNOPSIS
        Read-only GPU temperature and clocks-event report (NX10-002).
    .DESCRIPTION
        NVIDIA adapters are read through nvidia-smi (vendor-documented), including the
        clocks-event reasons nvidia-smi itself reports. AMD/Intel adapters are marked
        'Uncertain-VendorDependent' because NEXTRIX does not use undocumented
        vendor interfaces. Throttle classification is copied from the vendor's own
        reason flags (classifiedByNextrix = $false).
    #>
    [CmdletBinding()]
    param([int]$TimeoutMs = 10000)
    $inv = Get-Nx10GpuAdapters
    $nv = Get-Nx10NvidiaSnapshot -TimeoutMs $TimeoutMs
    $unc = @()
    $unc += @($inv.uncertainty)
    $unc += @($nv.uncertainty)

    $nvidiaAdapters = @($inv.adapters | Where-Object { $_.vendor -eq 'NVIDIA' })
    $merged = @()
    $mappingNote = $null
    if ($nv.available -and $nv.gpus.Count -gt 0 -and $nvidiaAdapters.Count -gt 0) {
        if ($nv.gpus.Count -eq $nvidiaAdapters.Count) {
            for ($i = 0; $i -lt $nvidiaAdapters.Count; $i++) {
                $merged += [pscustomobject][ordered]@{ adapter = $nvidiaAdapters[$i]; telemetry = $nv.gpus[$i] }
            }
        } else {
            $mappingNote = "nvidia-smi reported $($nv.gpus.Count) GPU(s) for $($nvidiaAdapters.Count) NVIDIA adapter(s); telemetry is listed separately rather than mis-attributed."
            $unc += $mappingNote
        }
    } elseif ($nv.available -and $nvidiaAdapters.Count -eq 0) {
        $mappingNote = 'nvidia-smi reported telemetry but Win32_VideoController shows no NVIDIA adapter; telemetry is listed separately.'
    }

    $records = @()
    foreach ($a in $inv.adapters) {
        $rec = [ordered]@{
            name = $a.name
            vendor = $a.vendor
            driverVersion = $a.driverVersion
            temperatureState = $script:Nx10Unavailable
            temperatureCelsius = $null
            clocks = $null
            throttle = $null
            limitation = $null
        }
        if ($a.vendor -eq 'NVIDIA') {
            $match = @($merged | Where-Object { $_.adapter.pnpDeviceId -eq $a.pnpDeviceId }) | Select-Object -First 1
            if ($null -ne $match) {
                $t = $match.telemetry
                if ($null -ne $t.temperatureCelsius) {
                    $rec.temperatureState = 'Available'
                    $rec.temperatureCelsius = [math]::Round([double]$t.temperatureCelsius, 1)
                } else {
                    $rec.limitation = 'nvidia-smi reported [N/A] for temperature.gpu on this device/driver'
                }
                $rec.clocks = [pscustomobject][ordered]@{
                    currentGraphicsMhz = $t.currentGraphicsClockMhz
                    maxGraphicsMhz = $t.maxGraphicsClockMhz
                }
                $reasons = @($t.throttleReasons)
                $conclusion = 'Uncertain-Unavailable'
                if ($null -ne $t.throttleNamed -and $t.throttleNamed.Count -gt 0) {
                    $thermal = (@($t.throttleNamed['hwThermalSlowdown'], $t.throttleNamed['swThermalSlowdown']) | Where-Object { $_ -eq 'Active' }).Count -gt 0
                    $powerCap = ($t.throttleNamed['swPowerCap'] -eq 'Active')
                    $idle = ($t.throttleNamed['gpuIdle'] -eq 'Active')
                    $otherReasons = @($reasons | Where-Object { $_ -ne 'GpuIdle' })
                    if ($thermal) { $conclusion = 'ThermalSlowdown-VendorReported' }
                    elseif ($powerCap) { $conclusion = 'PowerCap-VendorReported' }
                    elseif ($otherReasons.Count -gt 0) { $conclusion = 'OtherReason-VendorReported' }
                    elseif ($idle -or (@($reasons | Where-Object { $_ -eq 'GpuIdle' }).Count -gt 0)) { $conclusion = 'Idle-VendorReported' }
                    else { $conclusion = 'None-VendorReported' }
                }
                $rec.throttle = [pscustomobject][ordered]@{
                    conclusion = $conclusion
                    reasons = $reasons
                    maskHex = $t.throttleMask
                    classifiedByNextrix = $false
                    basis = 'nvidia-smi clocks-event reason flags (vendor-reported)'
                }
            } else {
                $rec.temperatureState = $(if ($nv.available) { $script:Nx10Unavailable } else { $script:Nx10VendorDependent })
                $rec.limitation = $(if ($nv.available) { 'telemetry could not be attributed to this adapter (see mapping note)' } else { 'NVIDIA adapter present but nvidia-smi telemetry is unavailable' })
            }
        } elseif ($a.vendor -eq 'AMD') {
            $rec.temperatureState = $script:Nx10VendorDependent
            $rec.limitation = 'AMD GPU temperature is exposed through ADL/Radeon Software (SDK/GUI); NEXTRIX uses no vendor-documented WMI read contract, so no value is reported.'
        } elseif ($a.vendor -eq 'Intel') {
            $rec.temperatureState = $script:Nx10VendorDependent
            $rec.limitation = 'Intel GPU temperature is exposed through IGCL/support libraries; no vendor-documented WMI read contract is used by NEXTRIX.'
        } elseif ($a.vendor -eq 'None') {
            $rec.temperatureState = 'NotApplicable'
            $rec.limitation = 'Microsoft Basic/Remote Display adapter: no thermal sensor exists.'
        } else {
            $rec.limitation = 'GPU vendor not identified; no telemetry source attempted.'
        }
        $records += [pscustomobject]$rec
    }

    $readable = @($records | Where-Object { $_.temperatureState -eq 'Available' })
    $coverage = 'Unavailable'
    if ($readable.Count -gt 0 -and $readable.Count -eq $records.Count) { $coverage = 'Full' }
    elseif ($readable.Count -gt 0) { $coverage = 'Partial' }

    return [pscustomobject][ordered]@{
        functionName = 'Get-NxGpuThermalReport'
        tweakId = 'NX10-002'
        category = 'NX10'
        readOnly = $true
        noWritesPerformed = $true
        temperatureCoverage = $coverage
        adapters = $records
        nvidiaSmi = [pscustomobject][ordered]@{
            available = $nv.available
            path = $nv.path
            degradedQuery = $nv.degraded
            queryFields = $nv.queryFields
            gpuCount = $nv.gpus.Count
            unmappedTelemetry = @($nv.gpus)
            mappingNote = $mappingNote
        }
        dataSources = @(
            'nvidia-smi.exe --query-gpu (E1 vendor-documented; [N/A] fields are reported as unavailable)',
            'Win32_VideoController vendor mapping (E1; PCI VEN_ ids)',
            'AMD ADL / Intel IGCL: not used (no vendor-documented WMI read contract) -> Uncertain-VendorDependent'
        )
        limitation = 'GPU temperature reports what the vendor driver exposes. NEXTRIX does not query undocumented sensors, does not set clocks/power/voltage and never touches firmware.'
        uncertainty = $unc
        summary = "GPU thermal report: $($readable.Count) of $($records.Count) adapter(s) with vendor-reported temperature; coverage=$coverage."
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ---------------------------------------------------------------------------
# F. NX10-003 - CPU power-limit monitoring (read-only, vendor-dependent)
# ---------------------------------------------------------------------------

function Get-NxCpuPowerLimitReport {
    <#
    .SYNOPSIS
        Read-only CPU package power-limit report (NX10-003).
    .DESCRIPTION
        Hardware PL1/PL2 (Intel RAPL MSR 0x610) and AMD SMU limits are not exposed by
        any documented Windows API; reading them requires a kernel driver, which
        NEXTRIX does not install. The report therefore states
        'Uncertain-VendorDependent' for the limits themselves and publishes the
        documented OS-level policy context (processor max/min state, boost mode) that
        owners can actually see - clearly labelled as policy, not as a power limit.
    #>
    [CmdletBinding()]
    param()
    $unc = @()
    $maxState = Get-Nx10PowerCfgSetting -SubgroupGuid $script:Nx10ProcessorSubgroup -SettingGuid $script:Nx10SettingMaxProcessor
    $minState = Get-Nx10PowerCfgSetting -SubgroupGuid $script:Nx10ProcessorSubgroup -SettingGuid $script:Nx10SettingMinProcessor
    $boost = Get-Nx10PowerCfgSetting -SubgroupGuid $script:Nx10ProcessorSubgroup -SettingGuid $script:Nx10SettingBoostMode

    if (-not $maxState.parseOk) { $unc += 'powercfg /query for Maximum processor state was unparseable (localized output?) - policy context unavailable' }
    if (-not $minState.parseOk) { $unc += 'powercfg /query for Minimum processor state was unparseable (localized output?) - policy context unavailable' }
    if ($boost.ok -and -not $boost.found) { $unc += 'Processor performance boost mode is not exposed on the active plan (normal on some firmware)' }
    if (-not $boost.ok) { $unc += 'powercfg /query for Processor performance boost mode failed - boost policy context unavailable' }

    $vendorTools = @()
    try {
        foreach ($s in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '(?i)Ryzen Master|Extreme Tuning|XTU3|ThrottleStop|Intel\(R\) Extreme' })) {
            $vendorTools += [pscustomobject][ordered]@{ service = $s.Name; displayName = $s.DisplayName; status = [string]$s.Status }
        }
    } catch { }

    $policyRecord = New-Nx10PlaneRecord -Record $maxState -Label 'Maximum processor state (PROCTHROTTLEMAX)' -Units '%'
    $policyMin = New-Nx10PlaneRecord -Record $minState -Label 'Minimum processor state (PROCTHROTTLEMIN)' -Units '%'
    $policyBoost = New-Nx10PlaneRecord -Record $boost -Label 'Processor performance boost mode (PERFBOOSTMODE)' -Units $null

    return [pscustomobject][ordered]@{
        functionName = 'Get-NxCpuPowerLimitReport'
        tweakId = 'NX10-003'
        category = 'NX10'
        readOnly = $true
        noWritesPerformed = $true
        powerLimit = [pscustomobject][ordered]@{
            state = $script:Nx10VendorDependent
            pl1Watts = $null
            pl2Watts = $null
            tauSeconds = $null
            evidence = 'E0'
            reason = 'Package power limits (Intel PL1/PL2 in MSR 0x610, AMD SMU limits) are not exposed through a documented Windows API. Reading them requires a kernel-mode driver, which NEXTRIX deliberately does not install or ship.'
            nextOwnerAction = 'Read PL1/PL2 in the platform vendor''s own tuning utility (e.g. Intel XTU, AMD Ryzen Master) if the vendor supports it.'
        }
        osPolicyContext = [pscustomobject][ordered]@{
            kind = 'OS policy context - NOT a hardware power limit'
            source = 'powercfg /query SCHEME_CURRENT SUB_PROCESSOR ... (read-only, E1 documented command)'
            maximumProcessorState = $policyRecord
            minimumProcessorState = $policyMin
            performanceBoostMode = $policyBoost
            note = 'These indexes cap the OS P-state policy; the firmware may apply a lower hardware limit regardless. NEXTRIX does not write them here (NX03 owns processor settings).'
        }
        vendorTooling = [pscustomobject][ordered]@{
            detectedServices = $vendorTools
            existenceOnly = $true
            note = 'Vendor tuning utilities are detected by service display name only; NEXTRIX never drives them.'
        }
        dataSources = @(
            'powercfg /query SUB_PROCESSOR (E1 documented command; read-only)',
            'Hardware package power limits: no documented Windows interface (E0) -> Uncertain-VendorDependent'
        )
        uncertainty = $unc
        summary = 'CPU power-limit report: hardware PL1/PL2 are not readable through documented Windows interfaces, so they are marked Uncertain-VendorDependent; OS processor policy is reported separately as context.'
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ---------------------------------------------------------------------------
# G. NX10-004 - GPU power-limit monitoring (read-only, vendor-dependent)
# ---------------------------------------------------------------------------

function Get-NxGpuPowerLimitReport {
    <#
    .SYNOPSIS
        Read-only GPU power/limit report (NX10-004).
    .DESCRIPTION
        For NVIDIA GPUs, nvidia-smi reports power draw and several limit fields; each
        field is reported independently because drivers legitimately return [N/A] for
        some of them (observed live: power.limit [N/A] while enforced.power.limit and
        power.default_limit are present). AMD/Intel adapters are
        'Uncertain-VendorDependent'. NEXTRIX never sets a power limit
        (nvidia-smi -pl is a hardware/firmware write and is never invoked).
    #>
    [CmdletBinding()]
    param([int]$TimeoutMs = 10000)
    $inv = Get-Nx10GpuAdapters
    $nv = Get-Nx10NvidiaSnapshot -TimeoutMs $TimeoutMs
    $unc = @()
    $unc += @($inv.uncertainty)

    $gpuRecords = @()
    foreach ($g in @($nv.gpus)) {
        $headroom = $null
        if ($null -ne $g.enforcedPowerLimitWatts -and $null -ne $g.powerMaxLimitWatts) {
            $headroom = [math]::Round([double]$g.powerMaxLimitWatts - [double]$g.enforcedPowerLimitWatts, 2)
        }
        $gpuRecords += [pscustomobject][ordered]@{
            index = $g.index
            name = $g.name
            powerDrawWatts = $g.powerDrawWatts
            powerLimitWatts = $g.powerLimitWatts
            powerDefaultLimitWatts = $g.powerDefaultLimitWatts
            powerMaxLimitWatts = $g.powerMaxLimitWatts
            enforcedPowerLimitWatts = $g.enforcedPowerLimitWatts
            headroomToMaxWatts = $headroom
            state = $(if ($null -ne $g.powerDrawWatts -or $null -ne $g.enforcedPowerLimitWatts -or $null -ne $g.powerDefaultLimitWatts) { 'Available' } else { $script:Nx10Unavailable })
            fieldNote = "'power.limit' is frequently [N/A] on laptop GPUs: these platforms enforce limits through firmware (enforced.power.limit / default limit) rather than a settable driver limit."
        }
    }

    $otherVendors = @()
    foreach ($a in @($inv.adapters | Where-Object { $_.vendor -eq 'AMD' -or $_.vendor -eq 'Intel' })) {
        $otherVendors += [pscustomobject][ordered]@{
            name = $a.name
            vendor = $a.vendor
            state = $script:Nx10VendorDependent
            reason = 'GPU power/limit telemetry is available only through vendor SDK/GUI surfaces (AMD ADL / Radeon Software, Intel IGCL); no vendor-documented WMI read contract is used by NEXTRIX.'
        }
    }
    if ($otherVendors.Count -gt 0) { $unc += "$($otherVendors.Count) non-NVIDIA adapter(s) have no documented power/limit read path (Uncertain-VendorDependent)" }
    if ($nv.available -and $gpuRecords.Count -eq 0) { $unc += 'nvidia-smi returned no GPU rows - no NVIDIA power data' }
    if (-not $nv.available) { $unc += @($nv.uncertainty) }

    $readable = @($gpuRecords | Where-Object { $_.state -eq 'Available' })
    return [pscustomobject][ordered]@{
        functionName = 'Get-NxGpuPowerLimitReport'
        tweakId = 'NX10-004'
        category = 'NX10'
        readOnly = $true
        noWritesPerformed = $true
        powerLimitChangesPerformed = $false
        gpus = $gpuRecords
        adaptersWithoutTelemetry = $otherVendors
        state = $(if ($readable.Count -gt 0) { 'Available-Partial' } elseif ($otherVendors.Count -gt 0) { $script:Nx10VendorDependent } else { $script:Nx10Unavailable })
        dataSources = @(
            'nvidia-smi --query-gpu power.draw / power.limit / power.default_limit / power.max_limit / enforced.power.limit (E1 vendor-documented)',
            'AMD / Intel: no documented WMI power-limit read path (E0) -> Uncertain-VendorDependent'
        )
        policy = 'NEXTRIX never sets a GPU power limit. nvidia-smi -pl and vendor tuning tools write hardware/firmware state and are out of scope for this category.'
        uncertainty = $unc
        summary = "GPU power-limit report: $($readable.Count) NVIDIA GPU(s) with vendor-reported power fields; $($otherVendors.Count) adapter(s) marked Uncertain-VendorDependent."
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ---------------------------------------------------------------------------
# H. NX10-005 - Fan speed monitoring where exposed (read-only, no fan control)
# ---------------------------------------------------------------------------

function Get-NxFanSpeedReport {
    <#
    .SYNOPSIS
        Read-only fan speed report (NX10-005). Never controls a fan.
    .DESCRIPTION
        Win32_Fan reports a requested speed (RPM) only when a variable-speed fan is
        exposed - most consumer firmware omits the class entirely, which is reported
        as 'Uncertain-Unavailable' rather than as 0 RPM. NVIDIA fan percentage comes
        from nvidia-smi when the device exposes it. fanControlPerformed is always
        $false and no fan/OEM interface is invoked.
    #>
    [CmdletBinding()]
    param([int]$TimeoutMs = 10000)
    $fans = @()
    $unc = @()
    try {
        foreach ($f in @(Get-CimInstance -ClassName Win32_Fan -ErrorAction Stop)) {
            $rpm = $null
            if ($null -ne $f.DesiredSpeed) {
                $raw = [double]$f.DesiredSpeed
                if ($raw -gt 0 -and $raw -lt 100000) { $rpm = [int][math]::Round($raw, 0) }
            }
            $fans += [pscustomobject][ordered]@{
                source = 'Win32_Fan'
                deviceId = [string]$f.DeviceID
                name = [string]$f.Name
                status = [string]$f.Status
                activeCooling = $(if ($null -ne $f.ActiveCooling) { [bool]$f.ActiveCooling } else { $null })
                variableSpeed = $(if ($null -ne $f.VariableSpeed) { [bool]$f.VariableSpeed } else { $null })
                desiredSpeedRpm = $rpm
                speedKind = 'RequestedSpeed-RPM (not a measured tachometer value)'
                state = $(if ($null -ne $rpm) { 'Available' } else { $script:Nx10Unavailable })
            }
        }
    } catch {
        $unc += "Win32_Fan read failed: $([string]$_.Exception.Message)"
    }
    if ($fans.Count -eq 0) {
        $unc += 'Win32_Fan returned no instances - normal on most consumer firmware, which does not expose fan devices to WMI'
    }

    $nv = Get-Nx10NvidiaSnapshot -TimeoutMs $TimeoutMs
    foreach ($g in @($nv.gpus)) {
        if ($null -ne $g.fanPercent) {
            $fans += [pscustomobject][ordered]@{
                source = 'nvidia-smi'
                deviceId = "GPU$($g.index)"
                name = $g.name
                status = $null
                activeCooling = $null
                variableSpeed = $null
                desiredSpeedRpm = $null
                fanPercentOfMax = [math]::Round([double]$g.fanPercent, 1)
                speedKind = 'PercentOfMaxNoiseToleranceFanSpeed (intended speed, vendor-reported)'
                state = 'Available'
            }
        } elseif ($nv.available) {
            $unc += "GPU $($g.index): nvidia-smi reported [N/A] for fan.speed (fan telemetry often absent on laptops whose fan is controlled by the platform)"
        }
    }
    $unc += @($nv.uncertainty)

    $readable = @($fans | Where-Object { $_.state -eq 'Available' })
    return [pscustomobject][ordered]@{
        functionName = 'Get-NxFanSpeedReport'
        tweakId = 'NX10-005'
        category = 'NX10'
        readOnly = $true
        noWritesPerformed = $true
        fanControlPerformed = $false
        fanControlSupported = $false
        fans = $fans
        state = $(if ($readable.Count -gt 0) { 'Available' } else { $script:Nx10Unavailable })
        dataSources = @(
            'Win32_Fan (E1 documented; DesiredSpeed is a requested RPM, class often absent)',
            'nvidia-smi --query-gpu fan.speed (E1 vendor-documented, percent of max)'
        )
        policy = 'NEXTRIX never controls fans: no fan-curve registry tweak, no OEM fan-interface call, no firmware write. Fan behaviour stays under the platform/OEM controller.'
        uncertainty = $unc
        summary = "Fan speed report: $($readable.Count) readable fan reading(s); fan control never performed."
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ---------------------------------------------------------------------------
# I. NX10-006 - OEM fan/cooling profile detection (read-only, no switching)
# ---------------------------------------------------------------------------

function Get-NxOemCoolingProfile {
    <#
    .SYNOPSIS
        Read-only detection of OEM cooling/fan interfaces (NX10-006).
    .DESCRIPTION
        Probes documented-or-community-known OEM management namespaces and services
        and enumerates class NAMES matching thermal/fan/cool inside namespaces that
        exist. No method is ever invoked, no BIOS/WMI setter is called and no OEM
        utility is driven, so the current profile stays 'Unknown' unless a
        vendor-documented read interface exists (none is implemented here).
        E0: OEM class names are community-known; vendor documentation exists per OEM
        but was not fetched for this entry.
    #>
    [CmdletBinding()]
    param()
    $unc = @()
    $candidates = @(
        @{ oem = 'Dell';    namespaces = @('root\dcim\sysman');                        services = '(?i)Dell (Command|Data Vault|SupportAssist|Power Manager)|SupportAssistAgent' }
        @{ oem = 'Lenovo';  namespaces = @('root\Lenovo');                             services = '(?i)Lenovo|Legion|Vantage|ImController' }
        @{ oem = 'HP';      namespaces = @('root\HP');                                 services = '(?i)HP (System Event|Power|Command)|Omen|HPAppHelper' }
        @{ oem = 'ASUS';    namespaces = @('root\ASUS');                               services = '(?i)ASUS|Armoury|MyASUS|ATK' }
        @{ oem = 'MSI';     namespaces = @();                                          services = '(?i)\bMSI\b|Dragon Center|Mystic Light' }
        @{ oem = 'Gigabyte'; namespaces = @();                                         services = '(?i)\bGigabyte\b|\bAorus\b' }
        @{ oem = 'Acer';    namespaces = @();                                          services = '(?i)\bPredator\b|\bAcer\b' }
        @{ oem = 'Razer';   namespaces = @();                                          services = '(?i)\bRazer\b|\bSynapse\b' }
    )
    $results = @()
    foreach ($c in $candidates) {
        $namespacesPresent = @()
        $classNames = @()
        foreach ($ns in @($c.namespaces)) {
            try {
                $classes = @(Get-CimClass -Namespace $ns -ClassName '*' -ErrorAction Stop)
                $namespacesPresent += $ns
                $matched = @($classes | Where-Object { $_.CimClassName -match '(?i)thermal|fan|cool' } | ForEach-Object { [string]$_.CimClassName } | Sort-Object -Unique)
                $classNames += $matched
            } catch {
                # Namespace absent or access-denied: normal on machines from other OEMs.
            }
        }
        $svc = @()
        try {
            $svc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $c.services } |
                ForEach-Object { [pscustomobject][ordered]@{ service = $_.Name; displayName = $_.DisplayName; status = [string]$_.Status } })
        } catch { }
        $detected = (($namespacesPresent.Count -gt 0) -or ($svc.Count -gt 0))
        if ($detected) {
            $unc += "$($c.oem): OEM management layer present; cooling/fan profile state is not readable without a vendor-documented contract"
        }
        $results += [pscustomobject][ordered]@{
            oem = $c.oem
            namespacesProbed = @($c.namespaces)
            namespacesPresent = $namespacesPresent
            thermalFanClasses = @($classNames | Select-Object -First 25)
            matchingServices = $svc
            interfaceDetected = [bool]$detected
            profileState = 'Unknown'
            switchingSupport = 'None-NotImplemented'
            methodInvocation = 'none'
            provenance = 'E0 community-known OEM management namespaces/services; per-OEM vendor documentation exists but was not fetched for this entry'
            uncertainty = $(if ($detected) { 'interface presence only; the active cooling profile is not exposed through a documented readable contract here' } else { 'no OEM management interface detected' })
        }
    }

    $detectedCount = @($results | Where-Object { $_.interfaceDetected }).Count
    return [pscustomobject][ordered]@{
        functionName = 'Get-NxOemCoolingProfile'
        tweakId = 'NX10-006'
        category = 'NX10'
        readOnly = $true
        noWritesPerformed = $true
        firmwareWriteAttempted = $false
        oemInterfaceInvoked = $false
        interfaces = $results
        detectedCount = $detectedCount
        dataSources = @(
            'OEM management WMI namespaces (existence + class-name enumeration only)',
            'OEM utility service display names (existence only)'
        )
        policy = 'Detection only. NEXTRIX does not switch cooling/fan profiles: no OEM method is invoked, no BIOS setting is written, no firmware is touched. Any future switching requires a vendor-documented interface and a per-OEM module.'
        uncertainty = $unc
        summary = "OEM cooling profile detection: $detectedCount OEM interface layer(s) detected; every profile state is Unknown and no interface is invoked."
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ---------------------------------------------------------------------------
# J. NX10-007 - AC/DC thermal behavior report (read-only)
# ---------------------------------------------------------------------------

function Get-NxAcDcThermalReport {
    <#
    .SYNOPSIS
        Read-only AC/DC thermal-behaviour report (NX10-007).
    .DESCRIPTION
        Reports the AC and DC planes of the documented processor policy settings
        (maximum/minimum processor state, performance boost mode) and the System
        cooling policy (SYSCOOLPOL) for the active plan, plus the current power
        source. Values are read with powercfg /query only - NX09 owns all writes and
        NX10 writes nothing.

        A true AC-vs-DC thermal comparison requires observing the machine on both
        power sources; the report says so and points at NX10-008 logging instead of
        inventing a comparison from a single snapshot.
    #>
    [CmdletBinding()]
    param()
    $unc = @()
    $ps = Get-Nx10PowerSource
    $unc += @($ps.uncertainty)
    $scheme = Get-Nx10ActiveScheme
    if (-not $scheme.parseOk) { $unc += 'powercfg /getactivescheme could not be parsed - active plan name unavailable' }

    $maxState = Get-Nx10PowerCfgSetting -SubgroupGuid $script:Nx10ProcessorSubgroup -SettingGuid $script:Nx10SettingMaxProcessor
    $minState = Get-Nx10PowerCfgSetting -SubgroupGuid $script:Nx10ProcessorSubgroup -SettingGuid $script:Nx10SettingMinProcessor
    $boost = Get-Nx10PowerCfgSetting -SubgroupGuid $script:Nx10ProcessorSubgroup -SettingGuid $script:Nx10SettingBoostMode
    $cooling = Get-Nx10PowerCfgSetting -SubgroupGuid $script:Nx10ProcessorSubgroup -SettingGuid $script:Nx10SettingCoolingPolicy

    foreach ($pair in @(
        @{ name = 'Maximum processor state'; rec = $maxState },
        @{ name = 'Minimum processor state'; rec = $minState },
        @{ name = 'Processor performance boost mode'; rec = $boost }
    )) {
        if (-not $pair.rec.parseOk) { $unc += "$($pair.name): powercfg /query unparseable (localized output?) - reported as Uncertain-Unavailable" }
    }
    if ($cooling.parseOk -and -not $cooling.found) {
        $unc += 'System cooling policy (SYSCOOLPOL) is not exposed on the active plan - a documented setting that OEM images sometimes hide; no value is invented'
    } elseif (-not $cooling.parseOk) {
        $unc += 'System cooling policy query unparseable - reported as Uncertain-Unavailable'
    }

    $dcApplicable = [bool]$ps.hasBattery

    return [pscustomobject][ordered]@{
        functionName = 'Get-NxAcDcThermalReport'
        tweakId = 'NX10-007'
        category = 'NX10'
        readOnly = $true
        noWritesPerformed = $true
        powerSource = [pscustomobject][ordered]@{
            current = $ps.powerSource
            detail = $ps.powerSourceDetail
            hasBattery = $ps.hasBattery
            dcApplicable = $dcApplicable
            batteryStatusRaw = $ps.batteryStatusRaw
            estimatedChargePercent = $ps.estimatedChargePercent
            powerOnline = $ps.powerOnline
        }
        activeScheme = [pscustomobject][ordered]@{
            state = $(if ($scheme.parseOk) { 'Available' } else { $script:Nx10Unavailable })
            guid = $scheme.guid
            name = $scheme.name
        }
        thermalPolicy = [pscustomobject][ordered]@{
            source = 'powercfg /query SCHEME_CURRENT SUB_PROCESSOR (read-only; writes are NX09/NX03 territory)'
            maximumProcessorState = (New-Nx10PlaneRecord -Record $maxState -Label 'Maximum processor state' -Units '%')
            minimumProcessorState = (New-Nx10PlaneRecord -Record $minState -Label 'Minimum processor state' -Units '%')
            performanceBoostMode = (New-Nx10PlaneRecord -Record $boost -Label 'Processor performance boost mode' -Units $null)
            systemCoolingPolicy = (New-Nx10PlaneRecord -Record $cooling -Label 'System cooling policy' -Units $null)
            note = 'Indexes are OS power policy. Friendly names are taken from the plan''s own "Possible Setting Friendly Name" output, never from a hardcoded guess.'
        }
        samplingNote = 'A real AC-versus-DC thermal comparison requires observing the machine on both power sources. Use NX10-008 (thermal session logging) once per power source and compare the logged series; this snapshot cannot.'
        dataSources = @(
            'powercfg /query and /getactivescheme (E1 documented; read-only)',
            'Win32_Battery / root\WMI BatteryStatus PowerOnline (E1 / E0 provenance)'
        )
        uncertainty = $unc
        summary = "AC/DC thermal report: powerSource=$($ps.powerSource); cooling policy $(if ($cooling.found) { 'present' } else { 'not exposed' }); processor policy planes reported for AC and DC separately."
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# ---------------------------------------------------------------------------
# K. NX10-008 - Thermal session logging for owner testing (writes ONE chosen file)
# ---------------------------------------------------------------------------

function Resolve-Nx10LogPath {
    <#
        Validates the owner-chosen log path. Refuses placeholder text (the registry
        ships '<user-chosen log file path>' and the playbook generator emits declared
        parameters verbatim), refuses silent overwrite without -Append, creates the
        parent directory when missing, and defaults the extension to .csv.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$OutputPath,
        [switch]$Append
    )
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        throw 'a log file path must be chosen (-OutputPath); NEXTRIX never writes logs to an implicit system location'
    }
    if ($OutputPath -match '[<>]') {
        throw "output path '$OutputPath' is a placeholder, not a real path - pass the owner's chosen log file path"
    }
    $full = $OutputPath
    try { $full = [System.IO.Path]::GetFullPath($OutputPath) } catch { throw "output path '$OutputPath' is not a valid path: $($_.Exception.Message)" }
    if (Test-Path -LiteralPath $full -PathType Container) {
        $full = Join-Path $full ('NEXTRIX-thermal-session-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.csv')
    }
    if ([string]::IsNullOrEmpty([System.IO.Path]::GetExtension($full))) { $full = $full + '.csv' }
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $existed = Test-Path -LiteralPath $full -PathType Leaf
    if ($existed -and -not $Append) {
        throw "log file '$full' already exists - pass -Append to extend it or choose another path (NEXTRIX never silently overwrites the owner's evidence)"
    }
    return [pscustomobject][ordered]@{
        filePath = $full
        fileName = [System.IO.Path]::GetFileName($full)
        existed  = [bool]$existed
        append   = [bool]$Append.IsPresent
    }
}

function ConvertTo-Nx10CsvField {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    $t = [string]$Text
    if ($t -match '[,"\r\n]') { return '"' + ($t -replace '"', '""') + '"' }
    return $t
}

function New-Nx10ThermalSample {
    <# One lightweight sample for the session log (sources reused from the reports). #>
    [CmdletBinding()]
    param([double]$ElapsedSeconds = 0, [int]$TimeoutMs = 8000)
    $unc = @()
    $acpi = Get-Nx10AcpiThermalZones
    $counter = Get-Nx10ThermalZoneCounters
    $clock = Get-Nx10CpuClock
    $ps = Get-Nx10PowerSource
    $nv = Get-Nx10NvidiaSnapshot -TimeoutMs $TimeoutMs

    $cpuTemp = $null
    $cpuTempSource = $null
    $cpuTempState = $script:Nx10Unavailable
    if ($null -ne $acpi.maxCelsius) {
        $cpuTemp = [double]$acpi.maxCelsius; $cpuTempSource = 'ACPI zone (max)'
        $cpuTempState = 'Available'
    } elseif ($null -ne $counter.maxCelsius) {
        $cpuTemp = [double]$counter.maxCelsius; $cpuTempSource = 'Thermal Zone counter (max)'
        $cpuTempState = 'Available'
    }
    if ($null -ne $acpi.maxCelsius -and $null -ne $counter.maxCelsius) {
        $delta = [math]::Abs([double]$acpi.maxCelsius - [double]$counter.maxCelsius)
        if ($delta -gt 5.0) {
            $cpuTemp = $null; $cpuTempSource = 'ACPI zone (max) vs Thermal Zone counter (max)'
            $cpuTempState = $script:Nx10SourceDisagreement
            $unc += "CPU temperature sources disagree by $([math]::Round($delta,1)) C in this sample"
        }
    }

    $gpuParts = @()
    $gpuState = $script:Nx10Unavailable
    foreach ($g in @($nv.gpus)) {
        $bits = @()
        if ($null -ne $g.temperatureCelsius) { $bits += ('{0}C' -f [math]::Round([double]$g.temperatureCelsius, 1)) } else { $bits += 'temp[N/A]' }
        if ($null -ne $g.powerDrawWatts) { $bits += ('{0}W' -f [math]::Round([double]$g.powerDrawWatts, 1)) }
        if ($null -ne $g.enforcedPowerLimitWatts) { $bits += ('limit {0}W' -f [math]::Round([double]$g.enforcedPowerLimitWatts, 1)) }
        if ($null -ne $g.fanPercent) { $bits += ('fan {0}%' -f [math]::Round([double]$g.fanPercent, 1)) }
        if ($null -ne $g.throttleReasons -and @($g.throttleReasons).Count -gt 0) { $bits += ('throttle:' + (@($g.throttleReasons) -join '+')) }
        if ($null -ne $g.temperatureCelsius) { $gpuState = 'Available' }
        $gpuParts += ("GPU$($g.index) $($g.name) [" + ($bits -join ' ') + ']')
    }
    $fanParts = @()
    foreach ($f in @($nv.gpus)) {
        if ($null -ne $f.fanPercent) { $fanParts += ('GPU{0} {1}%' -f $f.index, [math]::Round([double]$f.fanPercent, 1)) }
    }
    $unc += @($acpi.uncertainty)
    $unc += @($counter.uncertainty)
    $unc += @($clock.uncertainty)
    $unc += @($ps.uncertainty)
    $unc += @($nv.uncertainty)

    return [pscustomobject][ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        elapsedSeconds = [math]::Round($ElapsedSeconds, 1)
        powerSource = $ps.powerSource
        cpuLoadPercent = $clock.loadPercent
        cpuPercentMaxFrequency = $clock.percentOfMaximumFrequency
        cpuClockMhz = $clock.currentClockMhz
        cpuMaxClockMhz = $clock.maxClockMhz
        cpuTempCelsius = $(if ($null -ne $cpuTemp) { [math]::Round($cpuTemp, 1) } else { $null })
        cpuTempSource = $cpuTempSource
        cpuTempState = $cpuTempState
        gpuTelemetry = $(if ($gpuParts.Count -gt 0) { $gpuParts -join '; ' } else { 'no NVIDIA telemetry' })
        gpuState = $gpuState
        fanTelemetry = $(if ($fanParts.Count -gt 0) { $fanParts -join '; ' } else { $script:Nx10Unavailable })
        uncertainty = (@($unc | Select-Object -Unique) -join ' | ')
    }
}

function Invoke-NxThermalSessionLog {
    <#
    .SYNOPSIS
        Thermal session logging for owner testing (NX10-008).
    .DESCRIPTION
        Samples the OS-exposed thermal, clock, power-source and NVIDIA telemetry at a
        fixed interval for a bounded duration and appends one CSV row per sample to
        the OWNER-CHOSEN -OutputPath. Nothing in Windows is configured: no registry
        value, service, task, power setting or OEM interface is written.

        Bounds: -DurationSeconds 1..3600 (default 300), -SampleIntervalSeconds 1..300
        (default 10), so a session is always finite and cannot run away.

        The file starts with one '#' provenance comment line (data sources and their
        limits), then a stable CSV header. An existing file is only extended with
        -Append; otherwise the function refuses to overwrite.

        Journal: when -JournalRoot points at an initialized journal, ONE 'verify'
        record is written (result Success/Failed) describing the run. It is
        deliberately NOT an 'apply' record - nothing restorable changed, and the
        rollback engine only considers 'apply' entries. The record stores the log
        file's leaf name only (a full path can contain a user name).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [ValidateRange(1, 3600)][int]$DurationSeconds = 300,
        [ValidateRange(1, 300)][int]$SampleIntervalSeconds = 10,
        [switch]$Append,
        [string]$JournalRoot,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection'
    )
    $tweakId = 'NX10-008'
    $resolved = Resolve-Nx10LogPath -OutputPath $OutputPath -Append:$Append
    $unc = @()
    if ($SampleIntervalSeconds -lt 5) {
        $unc += 'sample interval below 5 s: each sample invokes nvidia-smi and performance counters, so sampling overhead is visible in the series'
    }
    if (-not $resolved.append -and $resolved.existed) {
        # Defensive: Resolve-Nx10LogPath already refuses this case.
        throw "log file '$($resolved.filePath)' exists and -Append was not supplied"
    }

    $header = 'timestampUtc,elapsedSeconds,powerSource,cpuLoadPct,cpuPctMaxFreq,cpuClockMhz,cpuMaxClockMhz,cpuTempC,cpuTempSource,cpuTempState,gpuTelemetry,gpuState,fanTelemetry,uncertainty'
    $writeHeader = (-not $resolved.existed) -or (-not $resolved.append)
    $encoding = New-Object System.Text.UTF8Encoding($true)
    $writer = $null
    $rows = 0
    $start = Get-Date
    $deadline = $start.AddSeconds($DurationSeconds)
    try {
        $writer = New-Object System.IO.StreamWriter($resolved.filePath, $resolved.append, $encoding)
        if ($writeHeader) {
            $writer.WriteLine('# NEXTRIX thermal session log (NX10-008). Sources: MSAcpi_ThermalZoneTemperature root\WMI (E0 provenance, tenths Kelvin), Thermal Zone Information counter (E0, Kelvin), Win32_Processor + % of Maximum Frequency counter, Win32_Battery/root\WMI BatteryStatus, nvidia-smi --query-gpu (E1). Values are OS/vendor reported only; Uncertain-* tokens mean no value is available. NEXTRIX changes no thermal setting.')
            $writer.WriteLine('# powerSource; cpuTempC is published only when temperature sources agree within 5 C; cpuPctMaxFreq is advisory and is never classified as throttling; gpuTelemetry embeds per-GPU vendor readings.')
            $writer.WriteLine($header)
        }
        while ((Get-Date) -lt $deadline) {
            $elapsed = ((Get-Date) - $start).TotalSeconds
            $sample = New-Nx10ThermalSample -ElapsedSeconds $elapsed
            $fields = @(
                (ConvertTo-Nx10CsvField $sample.timestampUtc),
                (ConvertTo-Nx10CsvField ([string]$sample.elapsedSeconds)),
                (ConvertTo-Nx10CsvField ([string]$sample.powerSource)),
                (ConvertTo-Nx10CsvField ([string]$sample.cpuLoadPercent)),
                (ConvertTo-Nx10CsvField ([string]$sample.cpuPercentMaxFrequency)),
                (ConvertTo-Nx10CsvField ([string]$sample.cpuClockMhz)),
                (ConvertTo-Nx10CsvField ([string]$sample.cpuMaxClockMhz)),
                (ConvertTo-Nx10CsvField ([string]$sample.cpuTempCelsius)),
                (ConvertTo-Nx10CsvField ([string]$sample.cpuTempSource)),
                (ConvertTo-Nx10CsvField ([string]$sample.cpuTempState)),
                (ConvertTo-Nx10CsvField ([string]$sample.gpuTelemetry)),
                (ConvertTo-Nx10CsvField ([string]$sample.gpuState)),
                (ConvertTo-Nx10CsvField ([string]$sample.fanTelemetry)),
                (ConvertTo-Nx10CsvField ([string]$sample.uncertainty))
            )
            if ($null -ne $sample.cpuPercentMaxFrequency -and $null -ne $sample.cpuLoadPercent -and $sample.cpuPercentMaxFrequency -lt 99.0 -and $sample.cpuLoadPercent -ge 40) {
                $unc += "sample at $($sample.timestampUtc): reduced frequency at load (not classified)"
            }
            $writer.WriteLine(($fields -join ','))
            $writer.Flush()
            $rows++
            $remaining = ($deadline - (Get-Date)).TotalSeconds
            if ($remaining -le 0) { break }
            $sleepMs = [int][math]::Min($SampleIntervalSeconds * 1000, [math]::Max(0, $remaining * 1000))
            if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
        }
    } finally {
        if ($null -ne $writer) { try { $writer.Dispose() } catch { } }
    }

    $size = 0
    if (Test-Path -LiteralPath $resolved.filePath -PathType Leaf) { $size = (Get-Item -LiteralPath $resolved.filePath).Length }
    $ok = ($rows -gt 0 -and $size -gt 0)
    if (-not $ok) { $unc += 'no sample rows were written' }

    $journaled = $false
    if ($JournalRoot -and (Test-Nx10JournalPresent -JournalRoot $JournalRoot)) {
        $original = [pscustomobject][ordered]@{
            targetType = 'thermalSessionLog'
            changedConfiguration = $false
            existedBefore = [bool]$resolved.existed
        }
        $modified = [pscustomobject][ordered]@{
            targetType = 'thermalSessionLog'
            changedConfiguration = $false
            fileName = $resolved.fileName          # leaf only: a full path may contain a user name
            pathRecorded = 'fileNameOnly'
            durationSeconds = $DurationSeconds
            sampleIntervalSeconds = $SampleIntervalSeconds
            sampleRows = $rows
        }
        try {
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($ok) { 'Success' } else { 'Failed' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $(if ($ok) { '' } else { 'no rows written' }) -Profiles $Profiles
            $journaled = $true
        } catch {
            $unc += "journal record failed: $([string]$_.Exception.Message)"
        }
    } elseif ($JournalRoot) {
        $unc += "journal at '$JournalRoot' is not initialized - the session ran but was not journaled"
    }

    $dataSources = @(
        'MSAcpi_ThermalZoneTemperature root\WMI (E0 provenance; tenths Kelvin)',
        '\Thermal Zone Information(*)\Temperature (E0 provenance; Kelvin)',
        'Win32_Processor + \Processor Information(_Total)\% of Maximum Frequency (E1 / E0 provenance)',
        'Win32_Battery + root\WMI BatteryStatus (E1 / E0 provenance)',
        'nvidia-smi --query-gpu (E1 vendor-documented; [N/A] fields marked unavailable)'
    )
    return [pscustomobject][ordered]@{
        functionName = 'Invoke-NxThermalSessionLog'
        tweakId = $tweakId
        category = 'NX10'
        readOnly = $false
        writes = 'one log file at the owner-chosen path only'
        changedConfiguration = $false
        noWritesPerformed = $false
        outcome = $(if ($ok) { 'Applied' } else { 'Failed' })
        filePath = $resolved.filePath
        fileName = $resolved.fileName
        bytes = $size
        sampleRows = $rows
        durationSeconds = $DurationSeconds
        sampleIntervalSeconds = $SampleIntervalSeconds
        journaled = $journaled
        journalOperation = 'verify (deliberately not apply: nothing restorable changed)'
        dataSources = $dataSources
        limitation = 'Sampling resolves what the OS/driver exposes at the sampled instants; it is not a hardware logger. Counter and class names are localized on non-English Windows, which produces Uncertain-Unavailable columns instead of values.'
        uncertainty = @($unc | Select-Object -Unique)
        summary = "Thermal session log: $rows sample row(s) written to the owner-chosen file; no Windows configuration changed."
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}
