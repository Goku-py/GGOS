#Requires -Version 5.1
<#
    NxHardware.ps1 - hardware detection (strictly read-only).

    Rules (directive Section 9): never fabricate unavailable values; mark
    uncertain/unavailable data explicitly. Vendor classification uses PCI
    vendor IDs from PNPDeviceID (documented, SynToolkit pattern r4), not
    name-guessing. VRAM uses the 64-bit registry value to avoid the WMI
    AdapterRAM >4 GB wraparound. Deep topology (P/E, CCD, X3D) is the NX19
    engine, delivered with that category - marked pending, never guessed.
#>

$script:NxJunkSmbios = @('to be filled by o.e.m.','unknown','none','n/a','not specified','default string','system serial number','not available')

function Convert-NxCleanText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($script:NxJunkSmbios -contains $Text.Trim().ToLower()) { return $null }
    return $Text.Trim()
}

function Get-NxCpuReport {
    [CmdletBinding()]
    param()
    $r = [ordered]@{
        readSucceeded = $false; vendor = 'Uncertain'; name = $null
        physicalCores = $null; logicalProcessors = $null; smt = 'Uncertain'
        hybrid = 'Uncertain-TopologyEnginePending'; uncertainty = @()
    }
    try {
        $p = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $p) { $r.uncertainty += 'Win32_Processor empty'; return [pscustomobject]$r }
        $r.readSucceeded     = $true
        $r.name              = Convert-NxCleanText ([string]$p.Name)
        $r.physicalCores     = [int]$p.NumberOfCores
        $r.logicalProcessors = [int]$p.NumberOfLogicalProcessors
        $mfr = ([string]$p.Manufacturer).ToLower()
        if ($mfr -like '*genuineintel*')      { $r.vendor = 'Intel' }
        elseif ($mfr -like '*authenticamd*')  { $r.vendor = 'AMD' }
        else { $r.uncertainty += "unmapped CPU manufacturer '$($p.Manufacturer)'" }
        if ($r.physicalCores -gt 0 -and $r.logicalProcessors -ge $r.physicalCores) {
            $r.smt = ($r.logicalProcessors -gt $r.physicalCores)
        } else { $r.uncertainty += 'core counts unavailable' }
        # Hybrid/P-E classification requires GetLogicalProcessorInformationEx parsing
        # (NX19 engine) - deliberately not guessed from marketing names here.
    } catch { $r.uncertainty += "Win32_Processor read failed: $($_.Exception.Message)" }
    return [pscustomobject]$r
}

function Get-NxGpuReport {
    [CmdletBinding()]
    param()
    $gpus = @()
    $unc = @()
    $vendorMap = @{ '10DE' = 'NVIDIA'; '1002' = 'AMD'; '8086' = 'Intel' }
    try {
        $controllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
        foreach ($c in $controllers) {
            $vendor = 'Uncertain'
            $ven = $null
            if ($c.PNPDeviceID -match 'VEN_([0-9A-Fa-f]{4})') { $ven = $Matches[1].ToUpper() }
            if ($ven -and $vendorMap.ContainsKey($ven)) { $vendor = $vendorMap[$ven] }
            elseif (([string]$c.Name) -match 'Microsoft Basic Display|Microsoft Remote Display') { $vendor = 'None' }
            else { $unc += "unmapped GPU vendor for '$($c.Name)' (VEN_$ven)" }
            # VRAM: prefer the 64-bit class-key value (AdapterRAM wraps >4 GB).
            $vramBytes = $null; $vramSource = 'unavailable'
            try {
                $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
                if (Test-Path $classKey) {
                    foreach ($sub in (Get-ChildItem $classKey -ErrorAction Stop)) {
                        try {
                            $matchId = (Get-ItemProperty -Path $sub.PSPath -Name MatchingDeviceId -ErrorAction Stop).MatchingDeviceId
                            if ($matchId -and ([string]$c.PNPDeviceID) -like "*$matchId*") {
                                $mem = (Get-ItemProperty -Path $sub.PSPath -Name 'HardwareInformation.qwMemorySize' -ErrorAction Stop).'HardwareInformation.qwMemorySize'
                                if ($mem) { $vramBytes = [int64]$mem; $vramSource = 'registry qwMemorySize' }
                                break
                            }
                        } catch { continue }  # one unreadable subkey must not sink the scan (r4)
                    }
                }
            } catch { $unc += "GPU class key scan failed: $($_.Exception.Message)" }
            if ($null -eq $vramBytes -and $c.AdapterRAM) {
                $vramBytes = [int64]$c.AdapterRAM; $vramSource = 'WMI AdapterRAM (uint32, wraps >4GB - treat as minimum)'
            }
            $gpus += [pscustomobject]@{
                name = Convert-NxCleanText ([string]$c.Name)
                vendor = $vendor
                driverVersion = [string]$c.DriverVersion
                pnpDeviceId = [string]$c.PNPDeviceID
                vramBytes = $vramBytes; vramSource = $vramSource
            }
        }
    } catch { $unc += "Win32_VideoController read failed: $($_.Exception.Message)" }
    return [pscustomobject]@{ gpus = $gpus; vendorsPresent = @($gpus | ForEach-Object { $_.vendor } | Select-Object -Unique); uncertainty = $unc }
}

function Get-NxMemoryReport {
    [CmdletBinding()]
    param()
    $unc = @()
    $totalBytes = $null
    $modules = @()
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $totalBytes = [int64]$cs.TotalPhysicalMemory
    } catch { $unc += "TotalPhysicalMemory read failed: $($_.Exception.Message)" }
    try {
        foreach ($m in (Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)) {
            $modules += [pscustomobject]@{
                manufacturer = Convert-NxCleanText ([string]$m.Manufacturer)
                capacityBytes = [int64]$m.Capacity
                speedMhz = $m.Speed; configuredSpeedMhz = $m.ConfiguredClockSpeed
                smbiosType = $m.SMBIOSMemoryType
            }
        }
    } catch { $unc += "Win32_PhysicalMemory read failed: $($_.Exception.Message)" }
    return [pscustomobject]@{ totalBytes = $totalBytes; totalGb = if ($totalBytes) { [math]::Round($totalBytes / 1GB, 1) } else { $null }; modules = $modules; uncertainty = $unc }
}

function Get-NxStorageReport {
    [CmdletBinding()]
    param()
    $disks = @(); $unc = @()
    try {
        foreach ($d in (Get-PhysicalDisk -ErrorAction Stop)) {
            $media = [string]$d.MediaType; $bus = [string]$d.BusType
            if ($media -notmatch '^(SSD|HDD)$') { $media = 'Uncertain' }
            $disks += [pscustomobject]@{
                friendlyName = Convert-NxCleanText ([string]$d.FriendlyName)
                model = Convert-NxCleanText ([string]$d.Model)
                mediaType = $media; busType = $bus
                sizeBytes = [int64]$d.Size
                healthStatus = [string]$d.HealthStatus
            }
        }
    } catch { $unc += "Get-PhysicalDisk failed: $($_.Exception.Message) (SATA/NVMe class query unavailable)" }
    return [pscustomobject]@{ disks = $disks; hasSsd = ($disks | Where-Object { $_.mediaType -eq 'SSD' }).Count -gt 0; hasHdd = ($disks | Where-Object { $_.mediaType -eq 'HDD' }).Count -gt 0; uncertainty = $unc }
}

function Get-NxChassisReport {
    [CmdletBinding()]
    param()
    $unc = @(); $class = 'Uncertain'
    $battery = $null
    try { $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1 } catch { $unc += "Win32_Battery read failed" }
    try {
        $enc = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop | Select-Object -First 1
        $types = @()
        if ($enc -and $enc.ChassisTypes) { $types = @($enc.ChassisTypes) }
        if ($types.Count -gt 0 -and ($types | Where-Object { $_ -le 7 }).Count -gt 0) { $class = 'Desktop' }
        elseif ($types.Count -gt 0) { $class = 'NonDesktop' }
    } catch { $unc += "Win32_SystemEnclosure read failed" }
    if ($null -ne $battery) { $class = 'Laptop' }  # battery-first classifier (XOS pattern, r1)
    $power = 'Uncertain'
    if ($null -ne $battery) {
        switch ([int]$battery.BatteryStatus) {
            1 { $power = 'Battery' } 2 { $power = 'AC' } default { $power = 'Uncertain' }
        }
    }
    return [pscustomobject]@{ chassisClass = $class; onAcPower = $power; hasBattery = ($null -ne $battery); uncertainty = $unc }
}

function Get-NxHardwareReport {
    [CmdletBinding()]
    param()
    $cpu = Get-NxCpuReport
    $gpu = Get-NxGpuReport
    $mem = Get-NxMemoryReport
    $sto = Get-NxStorageReport
    $chs = Get-NxChassisReport
    return [pscustomobject]@{
        cpu = $cpu; gpu = $gpu; memory = $mem; storage = $sto; chassis = $chs
        uncertainty = @($cpu.uncertainty) + @($gpu.uncertainty) + @($mem.uncertainty) + @($sto.uncertainty) + @($chs.uncertainty)
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}
