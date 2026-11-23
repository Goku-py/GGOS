#Requires -Version 5.1
<#
    NX20.ps1 - Hardware & Driver Management report functions
    (registry entries NX20-001..NX20-011).

    CATEGORY POLICY (catalogue NX20 header, directive): driver installation and
    removal stay separate from gaming optimization. Nothing in this module
    installs, removes, rolls back or flashes anything. Every entry is a READ-ONLY
    report or an owner-action guidance document. There is no Windows mutation
    surface in this file at all: no registry writes, no service changes, no
    pnputil/dism/start-process/flashing calls. The only writes are optional JSON
    report files inside a folder the owner explicitly passes (-OutputFolder).

    Dependencies (dot-sourced before use; see Import-NxCore):
        NxHardware.ps1  - Get-NxHardwareReport / Get-NxCpuReport / Get-NxGpuReport /
                          Get-NxMemoryReport / Get-NxStorageReport / Get-NxChassisReport /
                          Convert-NxCleanText (junk-SMBIOS sanitization)
        NxBuild.ps1     - Get-NxBuildReport
    Optional composition (guarded by Get-Command; absent is recorded as
    uncertainty, never guessed):
        NX04.ps1        - Get-NxGpuAdaptersInternal, Get-NxNvidiaStatus,
                          Get-NxAmdStatus, Get-NxIntelStatus, Get-NxHagsCapability,
                          Get-NxHybridGraphicsReport
        NX07.ps1        - Get-Nx07AdapterInventory (network capability map)
        NX16.ps1        - Get-NxDriverInventory (driver enumeration mechanics)
        NxCompat.ps1    - Get-NxTweakEligibility (eligibility evaluation on request)

    HONESTY MODEL (SynToolkit pattern, r4):
        - Unavailable vendor/hardware data is never fabricated. Every report
          carries an `uncertainty` array; a failed read is recorded there and the
          corresponding field stays $null / 'Uncertain'.
        - 'Missing' is not 'off' and 'unreadable' is not 'unsupported'.
        - VRAM comes from the 64-bit class-key value when available (WMI
          AdapterRAM wraps above 4 GB); the source is recorded per adapter.
        - Serial numbers are never emitted (device identifiers are withheld by
          policy), MAC addresses are masked to the OUI, and serial-like USB
          instance suffixes are redacted.

    Hard rules honored:
        - PowerShell 5.1 syntax only (no ternary, no ??).
        - No performance/FPS/latency claims. Guidance describes documented
          mechanisms and owner steps only.
        - Driver installation/removal/flashing: NeverAutomated, everywhere.
#>

# ============================================================================
# Internal helpers (read-only; no mutation anywhere in this section)
# ============================================================================

function Write-Nx20ReportFile {
    # Optional report export. Only writes when the owner passes -OutputFolder;
    # never overwrites an existing file (timestamped name, NX07/NX09 pattern).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$FileName,
        [string]$OutputFolder
    )
    if ([string]::IsNullOrWhiteSpace($OutputFolder)) { return $null }
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $OutputFolder -PathType Container)) {
        throw "output folder '$OutputFolder' exists but is not a folder"
    }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $path = Join-Path $OutputFolder ($FileName + '-' + $stamp + '.json')
    if (Test-Path -LiteralPath $path) {
        throw "report file '$path' already exists - refusing to overwrite"
    }
    $Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Convert-Nx20DateTime {
    # Honest datetime conversion: DateTime passthrough, WMI DMTF strings
    # (yyyymmddHHmmss.xxxxxx+zzz), best-effort parse; $null when unparseable.
    # Kept local so NX20 does not depend on NX16 load order.
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    if ($s -match '^\d{14}\.') {
        try { return [System.Management.ManagementDateTimeConverter]::ToDateTime($s) } catch { }
        if ($s -match '^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})') {
            return [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6])
        }
    }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($s, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-Nx20CimSafe {
    # One failing CIM class must never sink the whole report (r4). Failures are
    # appended to the caller's uncertainty list; no value is ever invented.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClassName,
        [System.Collections.Generic.List[string]]$Uncertainty
    )
    try {
        return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
    } catch {
        if ($null -ne $Uncertainty) { $Uncertainty.Add(($ClassName + ' read failed: ' + [string]$_.Exception.Message)) }
        return @()
    }
}

function Get-Nx20FirmwareType {
    # Firmware mode for reports. Ordered, source-recorded detection:
    #   1. HKLM\SYSTEM\CurrentControlSet\Control :: PEFirmwareType (1=Legacy, 2=UEFI;
    #      documented SynToolkit read, r4) - absent on many modern systems;
    #   2. %firmware_type% environment hint (corroborating only - not a contract);
    #   3. Get-ComputerInfo -Property BiosFirmwareType (documented cmdlet; slower,
    #      only used when 1 and 2 are unavailable);
    #   4. 'Uncertain' with the reasons recorded.
    [CmdletBinding()]
    param()
    $unc = @()
    try {
        $v = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction Stop).PEFirmwareType
        if ([int]$v -eq 1) { return [pscustomobject][ordered]@{ firmwareType = 'LegacyBios'; source = 'registry PEFirmwareType'; uncertainty = @() } }
        if ([int]$v -eq 2) { return [pscustomobject][ordered]@{ firmwareType = 'Uefi'; source = 'registry PEFirmwareType'; uncertainty = @() } }
        $unc += "PEFirmwareType value '$v' is outside the documented 1/2 mapping"
    } catch {
        $unc += 'PEFirmwareType registry value unavailable'
    }
    if ($env:firmware_type -eq 'UEFI') {
        return [pscustomobject][ordered]@{ firmwareType = 'Uefi'; source = 'environment firmware_type (corroborating hint)'; uncertainty = $unc }
    }
    if ($env:firmware_type -eq 'BIOS') {
        return [pscustomobject][ordered]@{ firmwareType = 'LegacyBios'; source = 'environment firmware_type (corroborating hint)'; uncertainty = $unc }
    }
    if ($null -ne (Get-Command -Name Get-ComputerInfo -ErrorAction SilentlyContinue)) {
        try {
            $ft = [string](Get-ComputerInfo -Property BiosFirmwareType -ErrorAction Stop).BiosFirmwareType
            if ($ft -eq 'Uefi') { return [pscustomobject][ordered]@{ firmwareType = 'Uefi'; source = 'Get-ComputerInfo BiosFirmwareType'; uncertainty = $unc } }
            if ($ft -eq 'Bios') { return [pscustomobject][ordered]@{ firmwareType = 'LegacyBios'; source = 'Get-ComputerInfo BiosFirmwareType'; uncertainty = $unc } }
            $unc += "Get-ComputerInfo returned BiosFirmwareType '$ft'"
        } catch {
            $unc += 'Get-ComputerInfo BiosFirmwareType failed: ' + [string]$_.Exception.Message
        }
    } else {
        $unc += 'Get-ComputerInfo not available in this host'
    }
    return [pscustomobject][ordered]@{ firmwareType = 'Uncertain'; source = $null; uncertainty = $unc }
}

function Get-Nx20DriverRecordMap {
    # One read-only Win32_PnPSignedDriver pass, keyed by DeviceID, shared by the
    # GPU/network/USB/inspection reports. NX16-010 owns the *inventory* report and
    # NX16-011 owns package cleanup; this helper exists only so NX20 reports can
    # join a device to its installed driver without re-querying per device.
    [CmdletBinding()]
    param([System.Collections.Generic.List[string]]$Uncertainty)
    $map = @{}
    $rows = @()
    try {
        $rows = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)
    } catch {
        if ($null -ne $Uncertainty) { $Uncertainty.Add('Win32_PnPSignedDriver read failed: ' + [string]$_.Exception.Message) }
        return [pscustomobject][ordered]@{ available = $false; map = $map; recordCount = 0 }
    }
    foreach ($r in $rows) {
        $id = ([string]$r.DeviceID).Trim().ToLower()
        if (-not $id) { continue }
        $map[$id] = [pscustomobject][ordered]@{
            deviceId     = $id
            deviceName   = [string]$r.DeviceName
            deviceClass  = [string]$r.DeviceClass
            provider     = [string]$r.DriverProviderName
            version      = [string]$r.DriverVersion
            driverDate   = (Convert-Nx20DateTime $r.DriverDate)
            infName      = [string]$r.InfName
            isSigned     = [bool]$r.IsSigned
            signer       = [string]$r.Signer
        }
    }
    return [pscustomobject][ordered]@{ available = $true; map = $map; recordCount = $rows.Count }
}

function Select-Nx20MaskedInstanceId {
    # Privacy rule: USB serial-like instance suffixes are redacted; bus/port
    # topology suffixes (contain '&') are kept because they are not device
    # identifiers. PCI/ACPI/SWD instance paths contain no serial and are kept.
    [CmdletBinding()]
    param([string]$InstanceId)
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $null }
    $s = $InstanceId.Trim()
    if ($s -match '^(USB\\[^\\]+)\\([^\\]+)$') {
        $suffix = $Matches[2]
        if ($suffix -notmatch '&' -and $suffix.Length -ge 6) { return ($Matches[1] + '\REDACTED') }
    }
    return $s
}

function Select-Nx20MaskedMac {
    # MAC addresses are device identifiers: vendor OUI only (same rule as NX07).
    [CmdletBinding()]
    param([string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return $null }
    $hex = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($hex.Length -lt 6) { return 'REDACTED' }
    return (($hex.Substring(0, 2) + ':' + $hex.Substring(2, 2) + ':' + $hex.Substring(4, 2) + ':xx:xx:xx'))
}

function Get-Nx20InstalledPrograms {
    # Read-only uninstall-registry inventory, filtered by vendor terms, used only
    # to report which vendor software is *installed*. No uninstall key path,
    # install location or user identifier is emitted.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$MatchTerms,
        [System.Collections.Generic.List[string]]$Uncertainty
    )
    $results = @()
    $seen = @{}
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $root)) { continue }
        try {
            foreach ($k in @(Get-ChildItem -Path $root -ErrorAction Stop)) {
                try {
                    $p = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop
                    $dn = [string]$p.DisplayName
                    if ([string]::IsNullOrWhiteSpace($dn)) { continue }
                    $matched = $false
                    foreach ($t in $MatchTerms) { if ($dn -like ('*' + $t + '*')) { $matched = $true; break } }
                    if (-not $matched) { continue }
                    $ver = [string]$p.DisplayVersion
                    $key = ($dn.Trim().ToLower() + '|' + $ver.Trim().ToLower())
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    $results += [pscustomobject][ordered]@{
                        displayName    = $dn
                        displayVersion = $ver
                        publisher      = [string]$p.Publisher
                    }
                } catch { continue }  # one unreadable entry must not sink the scan (r4)
            }
        } catch {
            if ($null -ne $Uncertainty) { $Uncertainty.Add('uninstall enumeration failed under ' + $root + ': ' + [string]$_.Exception.Message) }
        }
    }
    return @($results | Sort-Object displayName)
}

function Get-Nx20GpuAdapterDetail {
    # Normalized GPU adapter view. Prefers the NX04 helper (driver date, current
    # mode) when loaded; otherwise falls back to the NxHardware GPU report and
    # enriches from the driver map. Never guesses a vendor (PCI VID only).
    [CmdletBinding()]
    param(
        [System.Collections.Generic.List[string]]$Uncertainty,
        $DriverMap
    )
    $adapters = @()
    $source = 'NxHardware Get-NxGpuReport'
    if ($null -ne (Get-Command -Name Get-NxGpuAdaptersInternal -CommandType Function -ErrorAction SilentlyContinue)) {
        try {
            $g = Get-NxGpuAdaptersInternal
            foreach ($u in @($g.uncertainty)) { if ($u) { $Uncertainty.Add([string]$u) } }
            foreach ($a in @($g.adapters)) {
                $adapters += [pscustomobject][ordered]@{
                    name                  = $a.name
                    vendor                = $a.vendor
                    driverVersion         = $a.driverVersion
                    driverDate            = $a.driverDate
                    driverDateSource      = $(if ($a.driverDate) { 'Win32_VideoController DriverDate' } else { $null })
                    pnpDeviceId           = $a.pnpDeviceId
                    vramBytes             = $a.vramBytes
                    vramSource            = $a.vramSource
                    currentResolution     = $(if ($a.currentHorizontalResolution -and $a.currentVerticalResolution) { ([string]$a.currentHorizontalResolution + 'x' + [string]$a.currentVerticalResolution) } else { $null })
                    currentRefreshRate    = $a.currentRefreshRate
                    infName               = $null
                    signer                = $null
                }
            }
            if ($adapters.Count -gt 0) { $source = 'NX04 Get-NxGpuAdaptersInternal' }
        } catch {
            $Uncertainty.Add('Get-NxGpuAdaptersInternal failed: ' + [string]$_.Exception.Message + ' - falling back to NxHardware GPU report')
        }
    }
    if ($adapters.Count -eq 0) {
        try {
            $hwGpu = Get-NxGpuReport
            foreach ($u in @($hwGpu.uncertainty)) { if ($u) { $Uncertainty.Add([string]$u) } }
            foreach ($a in @($hwGpu.gpus)) {
                $adapters += [pscustomobject][ordered]@{
                    name               = $a.name
                    vendor             = $a.vendor
                    driverVersion      = $a.driverVersion
                    driverDate         = $null
                    driverDateSource   = $null
                    pnpDeviceId        = $a.pnpDeviceId
                    vramBytes          = $a.vramBytes
                    vramSource         = $a.vramSource
                    currentResolution  = $null
                    currentRefreshRate = $null
                    infName            = $null
                    signer             = $null
                }
            }
        } catch {
            $Uncertainty.Add('Get-NxGpuReport failed: ' + [string]$_.Exception.Message)
        }
    }
    # Enrich from the single driver-map read (date/inf/signer only).
    if ($null -ne $DriverMap -and $DriverMap.available) {
        foreach ($a in $adapters) {
            $id = ([string]$a.pnpDeviceId).Trim().ToLower()
            if (-not $id -or -not $DriverMap.map.ContainsKey($id)) { continue }
            $rec = $DriverMap.map[$id]
            if (-not $a.driverDate -and $rec.driverDate) {
                $a.driverDate = $rec.driverDate.ToString('yyyy-MM-dd')
                $a.driverDateSource = 'Win32_PnPSignedDriver DriverDate'
            }
            $a.infName = $rec.infName
            $a.signer = $rec.signer
        }
    }
    return [pscustomobject][ordered]@{ adapters = $adapters; source = $source }
}

# Vendor guidance metadata. Every route/URL below is a real vendor or Microsoft
# page; no claim about outcomes is made, and nothing here is executed.
$script:Nx20VendorGuidance = @{
    'NVIDIA' = @{
        driverPage = 'https://www.nvidia.com/en-us/drivers/'
        supportRoute = 'NVIDIA official driver download page (select the exact GPU model, product series and OS build) or NVIDIA App'
        cleanInstallNote = 'NVIDIA installers have historically offered a clean-installation option; the label and availability depend on the installer version, so verify it in the downloaded package. NEXTRIX never runs installers.'
        toolingNote = 'nvidia-smi is the NVIDIA-documented read-only status CLI (driver version/p-state/persistence/compute mode). Per-profile settings are not part of its documented surface (NX04 mechanism note).'
        softwareTerms = @('NVIDIA')
        doc = 'https://docs.nvidia.com/deploy/nvidia-smi/index.html'
    }
    'AMD' = @{
        driverPage = 'https://www.amd.com/en/support'
        supportRoute = 'AMD official support page (select the exact Radeon product and OS) or AMD Software: Adrenalin'
        cleanInstallNote = 'AMD Software: Adrenalin installers offer a factory-reset option in some versions; the label and availability depend on the installer version, so verify it in the downloaded package. NEXTRIX never runs installers.'
        toolingNote = 'There is no documented read-only consumer CLI for Radeon per-profile state; driver version via WMI/registry is the documented read route used here (NX04 mechanism note).'
        softwareTerms = @('AMD Software', 'Radeon')
        doc = 'https://www.amd.com/en/support'
    }
    'Intel' = @{
        driverPage = 'https://www.intel.com/content/www/us/en/support/detect.html'
        supportRoute = 'Intel official support/download page or Intel Driver & Support Assistant (select the exact graphics product)'
        cleanInstallNote = 'Intel publishes official driver packages and the Intel Driver & Support Assistant as the update route; verify the package lists the exact graphics product and OS build. NEXTRIX never runs installers.'
        toolingNote = 'Scriptable vendor interfaces for per-game settings are limited; driver version via WMI/registry is the documented read route used here (NX04 mechanism note).'
        softwareTerms = @('Intel')
        doc = 'https://www.intel.com/content/www/us/en/support/detect.html'
    }
}

function Get-Nx20CleanInstallGuidance {
    # The documented owner workflow behind NX20-003/004/005. Text only: the
    # function performs and schedules nothing.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('NVIDIA', 'AMD', 'Intel')][string]$Vendor)
    $g = $script:Nx20VendorGuidance[$Vendor]
    return [pscustomobject][ordered]@{
        automationPolicy   = 'NeverAutomated'
        performedBy        = 'Owner'
        driverPage         = $g.driverPage
        supportRoute       = $g.supportRoute
        beforeStateXref    = 'NX20-002 (GPU vendor & driver capability report) - run it and keep the output as the before-state'
        restorePointXref   = 'NX16-002 (pre-change restore point) - create one before any driver change'
        ownerSteps         = @(
            'Record the current report (NX20-002 / this report) and keep it as the before-state snapshot.',
            'Create a restore point (NX16-002) and keep recovery media available; driver changes are not journal-reversible.',
            ('Download the driver ONLY from the vendor page recorded here (' + $g.driverPage + '); confirm the exact GPU model and OS build in the package description.'),
            'If (and only if) the vendor or its support documentation calls for a clean uninstall: run a third-party uninstaller such as DDU per ITS OWN documentation, in Safe Mode. NEXTRIX does not bundle, download or execute it.',
            'Run the vendor installer as the owner. Use any clean-install/factory-reset option only when that installer offers it.',
            'Reboot, re-run this report, and compare driverVersion/driverDate with the before-state.',
            'If the device misbehaves: use Device Manager "Roll Back Driver" where the previous package is still available, or reinstall the previous vendor package.'
        )
        vendorCleanInstallNote = $g.cleanInstallNote
        thirdPartyUninstaller = [pscustomobject][ordered]@{
            name            = 'Display Driver Uninstaller (DDU)'
            role            = 'Third-party clean-uninstall utility referenced by community/vendor-support troubleshooting; owner-run only'
            source          = 'https://www.wagnardsoft.com/'
            nextrixBundles  = $false
            nextrixRuns     = $false
            note            = 'DDU is not a Microsoft or GPU-vendor product. NEXTRIX never downloads, bundles or executes it and makes no claim about its behavior; follow its own documentation and the vendor support guidance.'
        }
        rollbackNote       = 'Driver installation is NOT journal-reversible (NX16-010/011 own inventory and Driver Store mechanics). Rollback means reinstalling the previous vendor package or Device Manager driver rollback - keep the old installer.'
        noThirdPartyBoosterNote = 'Third-party "driver booster"/auto-updater utilities are not used: driver updates are owner decisions from vendor sources.'
    }
}

# ============================================================================
# NX20-001 - Hardware inventory master report (read-only)
# ============================================================================

function Get-Nx20HardwareInventoryReport {
    <#
        Composes the existing detection modules instead of re-implementing them:
        Get-NxHardwareReport (CPU/GPU/RAM/storage/chassis, NxHardware.ps1) plus
        board/BIOS CIM data and build context. Serials are withheld by policy;
        junk SMBIOS strings are sanitized (Convert-NxCleanText, r4); firmware mode
        is reported with its source. Strictly read-only.
    #>
    [CmdletBinding()]
    param([string]$OutputFolder)

    $unc = New-Object System.Collections.Generic.List[string]
    $hw = $null
    try { $hw = Get-NxHardwareReport } catch { $unc.Add('Get-NxHardwareReport failed: ' + [string]$_.Exception.Message) }

    $boards = @(Get-Nx20CimSafe -ClassName 'Win32_BaseBoard' -Uncertainty $unc)
    $bioss  = @(Get-Nx20CimSafe -ClassName 'Win32_BIOS' -Uncertainty $unc)
    $systems = @(Get-Nx20CimSafe -ClassName 'Win32_ComputerSystem' -Uncertainty $unc)

    $board = $null
    if ($boards.Count -gt 0) {
        $b = $boards[0]
        $serialRaw = Convert-NxCleanText ([string]$b.SerialNumber)
        $board = [pscustomobject][ordered]@{
            manufacturer    = Convert-NxCleanText ([string]$b.Manufacturer)
            product         = Convert-NxCleanText ([string]$b.Product)
            version         = Convert-NxCleanText ([string]$b.Version)
            serialPresent   = ($null -ne $serialRaw)
            serialWithheld  = $true
            serialPolicy    = 'Device serial numbers are never emitted (identifier policy; same rule as the support-bundle scrubber).'
        }
    } else {
        $unc.Add('Win32_BaseBoard returned no instances - board fields are Unknown, not guessed')
    }

    $bios = $null
    if ($bioss.Count -gt 0) {
        $b = $bioss[0]
        $serialRaw = Convert-NxCleanText ([string]$b.SerialNumber)
        $fw = Get-Nx20FirmwareType
        foreach ($u in @($fw.uncertainty)) { if ($u) { $unc.Add([string]$u) } }
        $bios = [pscustomobject][ordered]@{
            manufacturer     = Convert-NxCleanText ([string]$b.Manufacturer)
            smbiosBiosVersion = Convert-NxCleanText ([string]$b.SMBIOSBIOSVersion)
            biosVersion       = Convert-NxCleanText ([string]$b.Version)
            releaseDate       = (Convert-Nx20DateTime $b.ReleaseDate)
            smbiosMajor       = $b.SMBIOSMajorVersion
            smbiosMinor       = $b.SMBIOSMinorVersion
            firmwareType      = $fw.firmwareType
            firmwareTypeSource = $fw.source
            serialPresent     = ($null -ne $serialRaw)
            serialWithheld    = $true
        }
    } else {
        $unc.Add('Win32_BIOS returned no instances - BIOS fields are Unknown, not guessed')
    }

    $computer = $null
    if ($systems.Count -gt 0) {
        $cs = $systems[0]
        $computer = [pscustomobject][ordered]@{
            manufacturer = Convert-NxCleanText ([string]$cs.Manufacturer)
            model        = Convert-NxCleanText ([string]$cs.Model)
            systemFamily = Convert-NxCleanText ([string]$cs.SystemFamily)
            systemSku    = Convert-NxCleanText ([string]$cs.SystemSKUNumber)
            totalRamGb   = $(if ($hw -and $hw.memory) { $hw.memory.totalGb } else { $null })
        }
    }

    $os = $null
    if ($null -ne (Get-Command -Name Get-NxBuildReport -CommandType Function -ErrorAction SilentlyContinue)) {
        try {
            $b = Get-NxBuildReport
            $os = [pscustomobject][ordered]@{
                productName      = $b.productName
                editionId        = $b.editionId
                displayVersion   = $b.displayVersion
                build            = $b.build
                ubr              = $b.ubr
                marketing        = $b.marketing
                architecture     = $b.architecture
                inSupportedScope = $b.inSupportedScope
                insiderChannel   = $b.insiderChannel
                readSucceeded    = $b.readSucceeded
            }
            foreach ($u in @($b.uncertainty)) { if ($u) { $unc.Add([string]$u) } }
        } catch { $unc.Add('Get-NxBuildReport failed: ' + [string]$_.Exception.Message) }
    } else {
        $unc.Add('Get-NxBuildReport not loaded - OS build context omitted (NX16-012 owns the build report)')
    }

    $allUnc = @()
    if ($hw) { $allUnc += @($hw.uncertainty) }
    $allUnc += $unc.ToArray()

    $report = [pscustomobject][ordered]@{
        functionName       = 'Get-Nx20HardwareInventoryReport'
        readOnly           = $true
        generatedUtc       = (Get-Date).ToUniversalTime().ToString('o')
        hardwareReadSucceeded = ($null -ne $hw)
        computer           = $computer
        board              = $board
        bios               = $bios
        cpu                = $(if ($hw) { $hw.cpu } else { $null })
        gpu                = $(if ($hw) { $hw.gpu } else { $null })
        memory             = $(if ($hw) { $hw.memory } else { $null })
        storage            = $(if ($hw) { $hw.storage } else { $null })
        chassis            = $(if ($hw) { $hw.chassis } else { $null })
        os                 = $os
        categoryPolicy     = [pscustomobject][ordered]@{
            driverInstallRemove = 'Separate from optimization; never automated by NX20'
            firmwareFlash       = 'Never automated (NX20-011 is report/guidance only)'
            driverInventoryOwner = 'NX16-010 (mechanics) / NX20-008 (history view)'
        }
        notes              = @(
            'Composition entry: CPU/GPU/RAM/storage/chassis come from Get-NxHardwareReport (NxHardware.ps1); board/BIOS are read here because no other category owns them.',
            'Uncertainty entries are part of the contract: a missing value is Unknown, never a fabricated default.',
            'GPU vendor classification is PCI vendor-ID based (VEN_10DE/1002/8086) - never name guessing (r4).'
        )
        uncertainty        = $allUnc
    }
    $path = Write-Nx20ReportFile -Report $report -FileName 'NEXTRIX-NX20-hardware-inventory' -OutputFolder $OutputFolder
    if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
    return $report
}

# ============================================================================
# NX20-002 - GPU vendor & driver capability report (read-only)
# ============================================================================

function Get-Nx20GpuCapabilityReport {
    <#
        Evidence report behind NX04's vendor gates: which GPU vendors are present
        (PCI VID), each adapter's driver version/date/VRAM source, present-mode
        facts, and the vendor status snapshot when the NX04 helpers are loaded.
        This function does NOT gate anything itself - Get-NxTweakEligibility
        (NxCompat) enforces requiredHardware.gpuVendor from the hardware report.
    #>
    [CmdletBinding()]
    param([string]$OutputFolder)

    $unc = New-Object System.Collections.Generic.List[string]
    $dm = Get-Nx20DriverRecordMap -Uncertainty $unc
    $detail = Get-Nx20GpuAdapterDetail -DriverMap $dm -Uncertainty $unc
    $adapters = @($detail.adapters)

    $vendors = @($adapters | ForEach-Object { $_.vendor } | Where-Object { $_ } | Select-Object -Unique)
    $gates = [ordered]@{}
    foreach ($v in @('NVIDIA', 'AMD', 'Intel')) {
        $matching = @($adapters | Where-Object { $_.vendor -eq $v })
        $gates[$v] = [pscustomobject][ordered]@{
            present        = ($matching.Count -gt 0)
            adapterCount   = $matching.Count
            driverVersions = @($matching | ForEach-Object { $_.driverVersion } | Where-Object { $_ } | Select-Object -Unique)
        }
    }

    $statusFns = @{ 'NVIDIA' = 'Get-NxNvidiaStatus'; 'AMD' = 'Get-NxAmdStatus'; 'Intel' = 'Get-NxIntelStatus' }
    $vendorStatus = [ordered]@{}
    foreach ($v in @('NVIDIA', 'AMD', 'Intel')) {
        $fn = $statusFns[$v]
        if ($null -eq (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) {
            $vendorStatus[$v] = [pscustomobject][ordered]@{ available = $false; reason = ($fn + ' not loaded (NX04 module absent) - vendor mechanism detail omitted, never guessed') }
            continue
        }
        try {
            $st = & $fn
            $vendorStatus[$v] = [pscustomobject][ordered]@{
                available             = $true
                supported             = $st.supported
                reason                = $st.reason
                mechanismAvailability = $st.mechanismAvailability
                mechanismNote         = $st.mechanismNote
                uncertainty           = @($st.uncertainty)
            }
        } catch {
            $vendorStatus[$v] = [pscustomobject][ordered]@{ available = $false; reason = ($fn + ' failed: ' + [string]$_.Exception.Message) }
            $unc.Add($fn + ' failed: ' + [string]$_.Exception.Message)
        }
    }

    $hags = $null
    if ($null -ne (Get-Command -Name Get-NxHagsCapability -CommandType Function -ErrorAction SilentlyContinue)) {
        try { $hags = Get-NxHagsCapability } catch { $unc.Add('Get-NxHagsCapability failed: ' + [string]$_.Exception.Message) }
    }

    $hybrid = $null
    if ($null -ne (Get-Command -Name Get-NxHybridGraphicsReport -CommandType Function -ErrorAction SilentlyContinue)) {
        try { $hybrid = Get-NxHybridGraphicsReport } catch { $unc.Add('Get-NxHybridGraphicsReport failed: ' + [string]$_.Exception.Message) }
    }

    $report = [pscustomobject][ordered]@{
        functionName         = 'Get-Nx20GpuCapabilityReport'
        readOnly             = $true
        generatedUtc         = (Get-Date).ToUniversalTime().ToString('o')
        adapterSource        = $detail.source
        adapters             = $adapters
        vendorGates          = $gates
        vendorsPresent       = $vendors
        vendorStatus         = $vendorStatus
        hagsCapability       = $hags
        hybridGraphics       = $hybrid
        gateMechanism        = 'Get-NxTweakEligibility (NxCompat.ps1) evaluates Tweak.requiredHardware.gpuVendor against HardwareReport.gpu.vendorsPresent (from Get-NxHardwareReport). This report supplies the evidence; it is not a second gate.'
        vramHonesty          = 'VRAM always carries vramSource. registry qwMemorySize (64-bit class key) is authoritative; WMI AdapterRAM is a uint32 that wraps above 4 GB and is reported as a minimum only (r4).'
        driverDateHonesty    = 'driverDate may come from Win32_VideoController or Win32_PnPSignedDriver (driverDateSource records which). OEM driver dates can be newer than the release date or carry timezone artifacts; no date is corrected or invented.'
        notes                = @(
            'Feeds NX04 vendor gates (XREF NX04-002..023) and NX20-003/004/005 vendor driver reports.',
            'Vendor classification is PCI vendor-ID based; a Microsoft Basic Display adapter is recorded as vendor None, not as a real GPU.'
        )
        uncertainty          = @($unc.ToArray())
    }
    $path = Write-Nx20ReportFile -Report $report -FileName 'NEXTRIX-NX20-gpu-capability' -OutputFolder $OutputFolder
    if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
    return $report
}

# ============================================================================
# NX20-003 / NX20-004 / NX20-005 - Vendor driver management
# (inventory + clean-install guidance; DDU workflow documented, never automated)
# ============================================================================

function Get-Nx20VendorDriverReport {
    <#
        One engine function behind three registry entries (NVIDIA/AMD/Intel).
        Read-only inventory of the vendor adapters and their installed driver
        packages, installed vendor software, and the documented owner-run
        clean-install workflow. Strictly no installs, no removals, no downloads,
        no DDU execution, no flashing - `driverOperationPolicy` states this in
        the returned object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('NVIDIA', 'AMD', 'Intel')][string]$Vendor,
        [string]$OutputFolder
    )

    $unc = New-Object System.Collections.Generic.List[string]
    $guidance = $script:Nx20VendorGuidance[$Vendor]
    $dm = Get-Nx20DriverRecordMap -Uncertainty $unc
    $detail = Get-Nx20GpuAdapterDetail -DriverMap $dm -Uncertainty $unc
    $vendorAdapters = @($detail.adapters | Where-Object { $_.vendor -eq $Vendor })

    $policy = [pscustomobject][ordered]@{
        install                  = 'NeverAutomated'
        removal                  = 'NeverAutomated'
        cleanInstall             = 'DocumentedOwnerWorkflow'
        firmwareFlash            = 'NeverAutomated'
        downloads                = 'None - NEXTRIX links the vendor page; the owner downloads'
        driverStoreCleanupXref   = 'NX16-011 (separate, ADVANCED, per-package explicit consent; not part of NX20)'
        journalNote              = 'Driver changes are not journal-reversible; this function journals nothing because it changes nothing.'
    }

    if ($vendorAdapters.Count -eq 0) {
        $report = [pscustomobject][ordered]@{
            functionName         = 'Get-Nx20VendorDriverReport'
            vendor               = $Vendor
            readOnly             = $true
            generatedUtc         = (Get-Date).ToUniversalTime().ToString('o')
            supported            = $false
            reason               = ('no ' + $Vendor + ' adapter detected (vendors present: ' + (@($detail.adapters | ForEach-Object { $_.vendor } | Where-Object { $_ } | Select-Object -Unique) -join ', ') + ')')
            mechanismAvailability = 'VendorHardwareAbsent'
            adapters             = @()
            installedDriverSummary = $null
            driverRecords        = @()
            vendorSoftware       = @()
            vendorTooling        = $null
            currencyCheck        = $null
            cleanInstallGuidance = $null
            profileInspection    = [pscustomobject][ordered]@{ status = 'NotAvailable'; reason = 'Vendor hardware absent - no profile store exists to inspect'; xref = 'NX04 vendor guidance entries'; inspected = $false }
            driverOperationPolicy = $policy
            uncertainty          = @($unc.ToArray())
        }
        $path = Write-Nx20ReportFile -Report $report -FileName ('NEXTRIX-NX20-' + $Vendor.ToLower() + '-driver') -OutputFolder $OutputFolder
        if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
        return $report
    }

    # Installed driver records: adapter-matched rows plus DISPLAY-class rows from
    # this vendor (some systems expose the display driver under a sibling node).
    $records = @()
    $recordSeen = @{}
    if ($dm.available) {
        foreach ($a in $vendorAdapters) {
            $id = ([string]$a.pnpDeviceId).Trim().ToLower()
            if ($id -and $dm.map.ContainsKey($id) -and -not $recordSeen.ContainsKey($id)) {
                $recordSeen[$id] = $true
                $records += $dm.map[$id]
            }
        }
        foreach ($rec in @($dm.map.Values)) {
            if ($rec.deviceClass -ne 'DISPLAY') { continue }
            if ([string]$rec.provider -notlike ('*' + $Vendor + '*') -and [string]$rec.deviceName -notlike ('*' + $Vendor + '*')) { continue }
            if ($recordSeen.ContainsKey($rec.deviceId)) { continue }
            $recordSeen[$rec.deviceId] = $true
            $records += $rec
        }
    } else {
        $unc.Add('installed driver package detail unavailable (Win32_PnPSignedDriver read failed) - adapter driver version/date still reported from the GPU query')
    }

    $versions = @($vendorAdapters | ForEach-Object { $_.driverVersion } | Where-Object { $_ } | Select-Object -Unique)
    $dates = @($vendorAdapters | ForEach-Object { $_.driverDate } | Where-Object { $_ } | Sort-Object)
    $summary = [pscustomobject][ordered]@{
        driverVersions   = $versions
        newestDriverDate = $(if ($dates.Count -gt 0) { $dates[$dates.Count - 1] } else { $null })
        oldestDriverDate = $(if ($dates.Count -gt 0) { $dates[0] } else { $null })
        infNames         = @($records | ForEach-Object { $_.infName } | Where-Object { $_ } | Select-Object -Unique)
        drivers          = @($records)
    }

    $software = @(Get-Nx20InstalledPrograms -MatchTerms @($guidance.softwareTerms) -Uncertainty $unc)

    $tooling = $null
    if ($Vendor -eq 'NVIDIA') {
        $smi = Get-Command -Name 'nvidia-smi.exe' -ErrorAction SilentlyContinue
        $smiRecords = @()
        $smiNote = $null
        if ($smi) {
            $out = @()
            try {
                $out = @(& $smi.Path '--query-gpu=name,driver_version,pstate,persistence_mode,compute_mode' '--format=csv,noheader,nounits' 2>$null)
            } catch { $smiNote = 'nvidia-smi query failed: ' + [string]$_.Exception.Message }
            if ($LASTEXITCODE -ne 0 -and @($out).Count -eq 0 -and -not $smiNote) {
                $smiNote = 'nvidia-smi exited with code ' + [string]$LASTEXITCODE + ' (elevation or driver RPC may be required)'
            }
            foreach ($line in @($out)) {
                $parts = @($line -split ',') | ForEach-Object { $_.Trim() }
                if ($parts.Count -ge 5) {
                    $smiRecords += [pscustomobject][ordered]@{ name = $parts[0]; driverVersion = $parts[1]; pstate = $parts[2]; persistenceMode = $parts[3]; computeMode = $parts[4] }
                }
            }
        } else {
            $smiNote = 'nvidia-smi not found on PATH - read-only status limited to WMI/registry driver data'
        }
        $tooling = [pscustomobject][ordered]@{
            name        = 'nvidia-smi'
            available   = [bool]$smi
            queryScope  = 'read-only status queries (driver version, p-state, persistence mode, compute mode)'
            records     = $smiRecords
            note        = $smiNote
            documented  = $guidance.doc
        }
        if ($smiNote) { $unc.Add($smiNote) }
    } else {
        $tooling = [pscustomobject][ordered]@{
            name      = 'none documented for status'
            available = $false
            note      = $guidance.toolingNote
            documented = $guidance.doc
        }
    }

    $currency = [pscustomobject][ordered]@{
        method                 = 'ManualComparisonRequired'
        installedDriverVersions = $versions
        installedVendorSoftwareVersions = @($software | ForEach-Object { [pscustomobject][ordered]@{ displayName = $_.displayName; displayVersion = $_.displayVersion } })
        vendorDriverPage       = $guidance.driverPage
        versionSchemeNote      = 'Windows reports a 4-part driver version (e.g. 32.0.16.1742) while the vendor package may advertise a marketing version (e.g. 617.42). Both are listed here so the owner compares the vendor page against the right string; NEXTRIX performs no remote lookup and asserts no currency verdict.'
        lastCheckedUtc         = (Get-Date).ToUniversalTime().ToString('o')
    }

    $profileInspection = [pscustomobject][ordered]@{
        status   = 'NotAvailable'
        reason   = 'Per-profile driver settings are stored in vendor-proprietary profile stores with no documented native read API. NEXTRIX does not read undocumented stores; the documented route is the vendor tooling described by the NX04 vendor-guidance entries.'
        xref     = 'NX04 vendor guidance entries (per-profile settings) - different mechanism owner, same honesty rule.'
        inspected = $false
    }

    $report = [pscustomobject][ordered]@{
        functionName          = 'Get-Nx20VendorDriverReport'
        vendor                = $Vendor
        readOnly              = $true
        generatedUtc          = (Get-Date).ToUniversalTime().ToString('o')
        supported             = $true
        reason                = $null
        mechanismAvailability = 'StatusAndGuidanceOnly'
        adapters              = $vendorAdapters
        installedDriverSummary = $summary
        driverRecords         = $records
        vendorSoftware        = $software
        vendorTooling         = $tooling
        currencyCheck         = $currency
        cleanInstallGuidance  = (Get-Nx20CleanInstallGuidance -Vendor $Vendor)
        profileInspection     = $profileInspection
        driverOperationPolicy = $policy
        notes                 = @(
            'Vendor software list is uninstall-registry inventory filtered by vendor name; it may include chipset/audio/telemetry components that are not GPU driver packages - reported as inventory, never judged.',
            'The clean-install workflow is documentation for the owner. This function performs no installation, removal, download, or uninstaller execution.',
            'XREF NX04 vendor guidance entries (per-profile driver settings) - different mechanism owner, same honesty rule.'
        )
        uncertainty           = @($unc.ToArray())
    }
    $path = Write-Nx20ReportFile -Report $report -FileName ('NEXTRIX-NX20-' + $Vendor.ToLower() + '-driver') -OutputFolder $OutputFolder
    if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
    return $report
}

# ============================================================================
# NX20-006 - Network driver inspection & version report (read-only)
# ============================================================================

function Get-Nx20NetworkDriverReport {
    <#
        Driver-version/history view of the network adapters. Reuses the NX07
        adapter inventory (including its advanced-property capability map) when
        loaded; otherwise falls back to Win32_NetworkAdapter + the driver map.
        Read-only: no adapter restart, no property write, no reset.
    #>
    [CmdletBinding()]
    param([string]$OutputFolder)

    $unc = New-Object System.Collections.Generic.List[string]
    $dm = Get-Nx20DriverRecordMap -Uncertainty $unc
    $adapters = @()
    $source = 'Win32_NetworkAdapter fallback'

    if ($null -ne (Get-Command -Name Get-Nx07AdapterInventory -CommandType Function -ErrorAction SilentlyContinue)) {
        try {
            $inv = Get-Nx07AdapterInventory
            foreach ($a in @($inv.adapters)) {
                $adapters += [pscustomobject][ordered]@{
                    name                  = $a.name
                    description           = $a.interfaceDesc
                    status                = $a.status
                    mediaType             = $a.mediaType
                    linkSpeed             = $a.linkSpeed
                    driverVersion         = $a.driverVersion
                    driverProvider        = $a.driverProvider
                    driverDate            = $a.driverDate
                    isVirtual             = $a.isVirtual
                    tunable               = $a.tunable
                    exclusionReason       = $a.exclusionReason
                    advancedPropertyCount = $a.advancedPropertyCount
                    pnpDeviceId           = $a.pnpDeviceId
                }
            }
            if ($inv.note) { $unc.Add('NX07 inventory note: ' + [string]$inv.note) }
            $source = 'NX07 Get-Nx07AdapterInventory'
        } catch {
            $unc.Add('Get-Nx07AdapterInventory failed: ' + [string]$_.Exception.Message + ' - falling back to Win32_NetworkAdapter')
        }
    } else {
        $unc.Add('NX07 inventory helper not loaded - using Win32_NetworkAdapter + driver map (capability-keyword map unavailable)')
    }

    if ($adapters.Count -eq 0) {
        $nics = @(Get-Nx20CimSafe -ClassName 'Win32_NetworkAdapter' -Uncertainty $unc)
        foreach ($n in $nics) {
            if ($n.PhysicalAdapter -ne $true) { continue }
            $id = ([string]$n.PNPDeviceID).Trim().ToLower()
            $rec = $null
            if ($id -and $dm.available -and $dm.map.ContainsKey($id)) { $rec = $dm.map[$id] }
            $adapters += [pscustomobject][ordered]@{
                name                  = [string]$n.NetConnectionID
                description           = [string]$n.Name
                status                = [string]$n.NetConnectionStatus
                mediaType             = [string]$n.AdapterType
                linkSpeed             = $n.Speed
                driverVersion         = $(if ($rec) { $rec.version } else { $null })
                driverProvider        = $(if ($rec) { $rec.provider } else { $null })
                driverDate            = $(if ($rec -and $rec.driverDate) { $rec.driverDate.ToString('yyyy-MM-dd') } else { $null })
                isVirtual             = $false
                tunable               = $null
                exclusionReason       = 'not classified (NX07 helper unavailable)'
                advancedPropertyCount = $null
                pnpDeviceId           = [string]$n.PNPDeviceID
                maskedMac             = (Select-Nx20MaskedMac ([string]$n.MACAddress))
            }
        }
    }

    $netDrivers = @()
    if ($dm.available) {
        $netDrivers = @($dm.map.Values | Where-Object { $_.deviceClass -eq 'NET' } | Sort-Object provider, version | ForEach-Object {
            [pscustomobject][ordered]@{
                deviceName  = $_.deviceName
                provider    = $_.provider
                version     = $_.version
                driverDate  = $(if ($_.driverDate) { $_.driverDate.ToString('yyyy-MM-dd') } else { $null })
                infName     = $_.infName
                isSigned    = $_.isSigned
                signer      = $_.signer
            }
        })
    }

    $physical = @($adapters | Where-Object { $_.isVirtual -eq $false })
    $report = [pscustomobject][ordered]@{
        functionName        = 'Get-Nx20NetworkDriverReport'
        readOnly            = $true
        generatedUtc        = (Get-Date).ToUniversalTime().ToString('o')
        adapterSource       = $source
        adapterCount        = $adapters.Count
        physicalCount       = $physical.Count
        virtualCount        = @($adapters | Where-Object { $_.isVirtual -eq $true }).Count
        adapters            = $adapters
        netClassDrivers     = $netDrivers
        driverProviders     = @($adapters | ForEach-Object { $_.driverProvider } | Where-Object { $_ } | Select-Object -Unique)
        capabilityXref      = 'Advanced-property availability (registry keywords, driver value lists) is owned by NX07-001 (Get-Nx07AdapterInventory). This report is the driver version/date view that NX07 capability decisions depend on - it reports the capability count but does not re-implement the keyword map.'
        notes               = @(
            'Read-only: no adapter restart, no advanced-property write, no network stack reset.',
            'MAC addresses are masked to the vendor OUI when the NX07 inventory is unavailable (identifiers are never emitted).',
            'Virtual/VPN/WAN adapters are listed for completeness; NX07 owns the tuning-exclusion decision.'
        )
        uncertainty         = @($unc.ToArray())
    }
    $path = Write-Nx20ReportFile -Report $report -FileName 'NEXTRIX-NX20-network-drivers' -OutputFolder $OutputFolder
    if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
    return $report
}

# ============================================================================
# NX20-007 - USB hardware inventory report (read-only)
# (owner of USB inventory; NX08-007 and NX09-005 cross-reference this entry)
# ============================================================================

function Get-Nx20UsbInventoryReport {
    <#
        USB controllers (Win32_USBController) plus present USB devices and hubs
        from the documented Get-PnpDevice cmdlet, joined to installed driver
        records. Serial-like instance suffixes are redacted. Inventory only: USB
        selective suspend / power configuration belongs to NX09-005, not here.
    #>
    [CmdletBinding()]
    param([string]$OutputFolder)

    $unc = New-Object System.Collections.Generic.List[string]
    $dm = Get-Nx20DriverRecordMap -Uncertainty $unc

    $controllers = @()
    foreach ($c in @(Get-Nx20CimSafe -ClassName 'Win32_USBController' -Uncertainty $unc)) {
        $controllers += [pscustomobject][ordered]@{
            name         = [string]$c.Name
            manufacturer = Convert-NxCleanText ([string]$c.Manufacturer)
            status       = [string]$c.Status
            deviceId     = (Select-Nx20MaskedInstanceId ([string]$c.DeviceID))
        }
    }

    $devices = @()
    $source = 'Get-PnpDevice'
    if ($null -ne (Get-Command -Name Get-PnpDevice -ErrorAction SilentlyContinue)) {
        try {
            $present = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
            foreach ($d in $present) {
                $iid = [string]$d.InstanceId
                if ($iid -notlike 'USB\*') { continue }
                $vid = $null; $pid2 = $null
                if ($iid -match '(?i)VID_([0-9A-F]{4})') { $vid = $Matches[1].ToUpper() }
                if ($iid -match '(?i)PID_([0-9A-F]{4})') { $pid2 = $Matches[1].ToUpper() }
                $role = 'Device'
                $friendly = [string]$d.FriendlyName
                if ($friendly -match '(?i)root hub') { $role = 'RootHub' }
                elseif ($friendly -match '(?i)\bhub\b') { $role = 'Hub' }
                elseif ($friendly -match '(?i)composite') { $role = 'CompositeDevice' }
                elseif ([string]$d.Class -eq 'HIDClass') { $role = 'HidDevice' }

                $key = $iid.Trim().ToLower()
                $rec = $null
                if ($dm.available -and $dm.map.ContainsKey($key)) { $rec = $dm.map[$key] }
                $problem = [string]$d.Problem
                $devices += [pscustomobject][ordered]@{
                    friendlyName   = $friendly
                    class          = [string]$d.Class
                    role           = $role
                    manufacturer   = Convert-NxCleanText ([string]$d.Manufacturer)
                    status         = [string]$d.Status
                    problem        = $problem
                    problemText    = [string]$d.ProblemDescription
                    hasProblem     = (-not [string]::IsNullOrWhiteSpace($problem) -and $problem -ne 'CM_PROB_NONE')
                    vendorId       = $vid
                    productId      = $pid2
                    instanceId     = (Select-Nx20MaskedInstanceId $iid)
                    service        = [string]$d.Service
                    driverVersion  = $(if ($rec) { $rec.version } else { $null })
                    driverProvider = $(if ($rec) { $rec.provider } else { $null })
                    driverDate     = $(if ($rec -and $rec.driverDate) { $rec.driverDate.ToString('yyyy-MM-dd') } else { $null })
                    infName        = $(if ($rec) { $rec.infName } else { $null })
                    isSigned       = $(if ($rec) { $rec.isSigned } else { $null })
                }
            }
        } catch {
            $unc.Add('Get-PnpDevice failed: ' + [string]$_.Exception.Message)
        }
    } else {
        $source = 'Win32_PnPEntity fallback'
        $unc.Add('Get-PnpDevice unavailable in this host - falling back to Win32_PnPEntity (no problem-code detail)')
        foreach ($p in @(Get-Nx20CimSafe -ClassName 'Win32_PnPEntity' -Uncertainty $unc)) {
            $iid = [string]$p.PNPDeviceID
            if ($iid -notlike 'USB\*') { continue }
            $vid = $null; $pid2 = $null
            if ($iid -match '(?i)VID_([0-9A-F]{4})') { $vid = $Matches[1].ToUpper() }
            if ($iid -match '(?i)PID_([0-9A-F]{4})') { $pid2 = $Matches[1].ToUpper() }
            $devices += [pscustomobject][ordered]@{
                friendlyName   = [string]$p.Name
                class          = [string]$p.PNPClass
                role           = 'Device'
                manufacturer   = Convert-NxCleanText ([string]$p.Manufacturer)
                status         = [string]$p.Status
                problem        = $null
                problemText    = $null
                hasProblem     = $null
                vendorId       = $vid
                productId      = $pid2
                instanceId     = (Select-Nx20MaskedInstanceId $iid)
                service        = [string]$p.Service
                driverVersion  = $null
                driverProvider = $null
                driverDate     = $null
                infName        = $null
                isSigned       = $null
            }
        }
    }

    $byClass = @($devices | Group-Object class | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject][ordered]@{ class = $_.Name; count = $_.Count }
    })
    $problemDevices = @($devices | Where-Object { $_.hasProblem -eq $true })
    $hubCount = @($devices | Where-Object { $_.role -eq 'Hub' -or $_.role -eq 'RootHub' }).Count

    $report = [pscustomobject][ordered]@{
        functionName     = 'Get-Nx20UsbInventoryReport'
        readOnly         = $true
        generatedUtc     = (Get-Date).ToUniversalTime().ToString('o')
        deviceSource     = $source
        controllerCount  = $controllers.Count
        controllers      = $controllers
        hubCount         = $hubCount
        deviceCount      = $devices.Count
        problemDeviceCount = $problemDevices.Count
        devicesByClass   = $byClass
        problemDevices   = $problemDevices
        devices          = $devices
        notes            = @(
            'Owner of USB hardware inventory: NX08-007 (USB troubleshooting) and NX09-005 (USB selective suspend) cross-reference this entry; NEXTRIX does not duplicate USB inventory elsewhere.',
            'Inventory only - no power-management write, no device disable/enable, no driver operation.',
            'USB serial-like instance suffixes are redacted; VID/PID and bus topology are kept because they are not device identifiers.'
        )
        uncertainty      = @($unc.ToArray())
    }
    $path = Write-Nx20ReportFile -Report $report -FileName 'NEXTRIX-NX20-usb-inventory' -OutputFolder $OutputFolder
    if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
    return $report
}

# ============================================================================
# NX20-008 - Installed driver history report (read-only)
# ============================================================================

function Get-Nx20DriverHistoryReport {
    <#
        Timeline view over the NX16-010 inventory (Get-NxDriverInventory - reused,
        not re-implemented): newest/oldest driver dates, per-year and per-provider
        counts, unsigned entries, and date anomalies (future-dated OEM metadata is
        reported, never corrected). No deletion, no Driver Store operation.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputFolder,
        [int]$TopCount = 15
    )
    if ($TopCount -lt 1) { $TopCount = 1 }
    if ($TopCount -gt 100) { $TopCount = 100 }

    $unc = New-Object System.Collections.Generic.List[string]
    $inventory = $null
    $source = 'NX16 Get-NxDriverInventory'

    if ($null -ne (Get-Command -Name Get-NxDriverInventory -CommandType Function -ErrorAction SilentlyContinue)) {
        try { $inventory = Get-NxDriverInventory } catch { $unc.Add('Get-NxDriverInventory failed: ' + [string]$_.Exception.Message) }
    } else {
        $unc.Add('NX16 Get-NxDriverInventory not loaded - falling back to the NX20 driver map (subset of the inventory fields)')
    }

    $rows = @()
    $completeness = 'Unknown'
    $completionNote = $null
    if ($null -ne $inventory) {
        foreach ($d in @($inventory.drivers)) {
            $dt = $null
            if ($d.driverDate -is [datetime]) { $dt = $d.driverDate }
            else { $dt = Convert-Nx20DateTime $d.driverDate }
            $rows += [pscustomobject][ordered]@{
                deviceName   = $d.deviceName
                manufacturer = $d.manufacturer
                provider     = $d.provider
                driverVersion = $d.driverVersion
                driverDate   = $dt
                driverDateText = $(if ($dt) { $dt.ToString('yyyy-MM-dd') } else { $null })
                infName      = $d.infName
                isSigned     = $d.isSigned
            }
        }
        $completeness = 'Complete'
        if (@($inventory.uncertainty).Count -gt 0) {
            # The reused module recorded a read failure. Rather than presenting a
            # truncated list as complete, verify against the shared driver map and
            # complete the view, labeling the source transition explicitly.
            $completeness = 'Partial'
            $dmCheck = Get-Nx20DriverRecordMap -Uncertainty $unc
            if ($dmCheck.available) {
                $seen = @{}
                foreach ($r in $rows) {
                    $k = (([string]$r.deviceName) + '|' + ([string]$r.provider) + '|' + ([string]$r.driverVersion) + '|' + ([string]$r.infName)).ToLower()
                    $seen[$k] = $true
                }
                $added = 0
                foreach ($rec in @($dmCheck.map.Values)) {
                    $k = (([string]$rec.deviceName) + '|' + ([string]$rec.provider) + '|' + ([string]$rec.version) + '|' + ([string]$rec.infName)).ToLower()
                    if ($seen.ContainsKey($k)) { continue }
                    $seen[$k] = $true
                    $rows += [pscustomobject][ordered]@{
                        deviceName   = $rec.deviceName
                        manufacturer = $null
                        provider     = $rec.provider
                        driverVersion = $rec.version
                        driverDate   = $rec.driverDate
                        driverDateText = $(if ($rec.driverDate) { $rec.driverDate.ToString('yyyy-MM-dd') } else { $null })
                        infName      = $rec.infName
                        isSigned     = $rec.isSigned
                    }
                    $added++
                }
                if ($added -gt 0) {
                    $completeness = 'Partial-CompletedFromDriverMap'
                    $completionNote = ('NX16-010 enumeration reported a read failure and returned ' + @($inventory.drivers).Count + ' of ' + $dmCheck.recordCount + ' raw PnP driver records; this history view added ' + $added + ' missing rows from the shared read-only driver map (' + @($rows).Count + ' de-duplicated entries; device instances sharing name/provider/version/INF are one entry). The NX16 uncertainty is preserved below for the coordinator/owner.')
                    $source = 'NX16 Get-NxDriverInventory + NX20 driver-map completion'
                    $unc.Add('NX16-010 enumeration was partial (its uncertainty is listed); NX20-008 completed the view from the shared driver map so the history report is not silently truncated')
                } else {
                    $completeness = 'Partial'
                    $completionNote = 'NX16-010 enumeration reported a read failure; no additional rows were recoverable from the shared driver map.'
                }
            } else {
                $completionNote = 'NX16-010 enumeration reported a read failure and the shared driver map was unavailable; the list is partial and labeled as such.'
            }
        }
        if ($null -ne $inventory.driverStoreSizeMb) { $unc.Add('Driver Store size is informational only; cleanup is NX16-011 and is never proposed here') }
    } else {
        $source = 'NX20 driver map fallback'
        $completeness = 'FallbackDriverMap'
        $dm = Get-Nx20DriverRecordMap -Uncertainty $unc
        if ($dm.available) {
            foreach ($rec in @($dm.map.Values)) {
                $rows += [pscustomobject][ordered]@{
                    deviceName   = $rec.deviceName
                    manufacturer = $null
                    provider     = $rec.provider
                    driverVersion = $rec.version
                    driverDate   = $rec.driverDate
                    driverDateText = $(if ($rec.driverDate) { $rec.driverDate.ToString('yyyy-MM-dd') } else { $null })
                    infName      = $rec.infName
                    isSigned     = $rec.isSigned
                }
            }
        }
        $completionNote = 'NX16-010 was unavailable; this view was built from the shared driver map (fewer fields) and is labeled FallbackDriverMap.'
    }

    $now = Get-Date
    $dated = @()
    foreach ($r in $rows) {
        $age = $null
        $anomaly = $null
        if ($r.driverDate) {
            $age = [int][math]::Floor(($now - $r.driverDate).TotalDays)
            if ($r.driverDate -gt $now.AddDays(30)) { $anomaly = 'FutureDatedOemMetadata' }
            elseif ($r.driverDate -lt [datetime]'1990-01-01') { $anomaly = 'Pre1990Metadata' }
        } else {
            $anomaly = 'DateUnparseable'
        }
        $dated += [pscustomobject][ordered]@{
            deviceName    = $r.deviceName
            manufacturer  = $r.manufacturer
            provider      = $r.provider
            driverVersion = $r.driverVersion
            driverDate    = $r.driverDateText
            ageDays       = $age
            dateAnomaly   = $anomaly
            infName       = $r.infName
            isSigned      = $r.isSigned
        }
    }

    $sorted = @($dated | Sort-Object -Property @{ Expression = 'driverDate'; Descending = $true }, @{ Expression = 'deviceName'; Descending = $false })
    $newest = @($sorted | Select-Object -First $TopCount)
    $oldest = @($sorted | Where-Object { $_.driverDate } | Sort-Object -Property driverDate | Select-Object -First $TopCount)

    $byYear = @($dated | Where-Object { $_.driverDate } | ForEach-Object { ([string]$_.driverDate).Substring(0, 4) } | Group-Object | Sort-Object Name -Descending | ForEach-Object {
        [pscustomobject][ordered]@{ year = $_.Name; count = $_.Count }
    })
    $byProvider = @($dated | Where-Object { $_.provider } | Group-Object provider | Sort-Object Count -Descending | Select-Object -First 12 | ForEach-Object {
        [pscustomobject][ordered]@{ provider = $_.Name; count = $_.Count }
    })
    $unsigned = @($dated | Where-Object { $_.isSigned -eq $false })
    $anomalies = @($dated | Where-Object { $_.dateAnomaly })

    $report = [pscustomobject][ordered]@{
        functionName     = 'Get-Nx20DriverHistoryReport'
        readOnly         = $true
        generatedUtc     = (Get-Date).ToUniversalTime().ToString('o')
        inventorySource  = $source
        inventoryCompleteness = $completeness
        completionNote   = $completionNote
        driverCount      = $dated.Count
        driverStorePath  = $(if ($inventory) { $inventory.driverStorePath } else { $null })
        driverStoreSizeMb = $(if ($inventory) { $inventory.driverStoreSizeMb } else { $null })
        driverStoreFileCount = $(if ($inventory) { $inventory.driverStoreFileCount } else { $null })
        newestDrivers    = $newest
        oldestDrivers    = $oldest
        driversByYear    = $byYear
        driversByProvider = $byProvider
        unsignedCount    = $unsigned.Count
        unsignedDrivers  = $unsigned
        dateAnomalyCount = $anomalies.Count
        dateAnomalies    = $anomalies
        notes            = @(
            'Enumeration mechanics are owned by NX16-010 (Get-NxDriverInventory); this entry adds only the timeline/history view and reuses that function.',
            'Driver Store cleanup is NX16-011 (ADVANCED, per-package explicit consent) and is never proposed or performed by NX20.',
            'inventoryCompleteness labels the source: Complete, Partial (the reused enumeration reported a read failure), Partial-CompletedFromDriverMap (missing rows recovered from the shared read-only driver map), or FallbackDriverMap. A partial list is never presented as complete.',
            'driverCount counts de-duplicated history entries, not raw PnP instances: device instances that share name/provider/version/INF are one entry, so a 164-record enumeration can legitimately yield fewer history rows.',
            'ageDays is informational arithmetic; OEM driver dates are frequently future-dated or timezone-shifted, so anomalies are reported and never corrected.'
        )
        uncertainty      = @($unc.ToArray())
    }
    $path = Write-Nx20ReportFile -Report $report -FileName 'NEXTRIX-NX20-driver-history' -OutputFolder $OutputFolder
    if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
    return $report
}

# ============================================================================
# NX20-009 - Hardware compatibility report generator (read-only)
# ============================================================================

function Get-Nx20CompatibilityReport {
    <#
        Produces the machine facts NxCompat consumes (Get-NxTweakEligibility reads
        gpu.vendorsPresent, memory.totalGb, storage.hasSsd, chassis.chassisClass,
        build/insiderChannel) in one documented shape, and - when registry tweak
        objects are supplied - evaluates them through the real resolver instead of
        a parallel implementation. No mutation, no eligibility guessing.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Tweaks = @(),
        [string]$OutputFolder
    )

    $unc = New-Object System.Collections.Generic.List[string]
    $hw = $null
    $build = $null
    try { $hw = Get-NxHardwareReport } catch { $unc.Add('Get-NxHardwareReport failed: ' + [string]$_.Exception.Message) }
    try { $build = Get-NxBuildReport } catch { $unc.Add('Get-NxBuildReport failed: ' + [string]$_.Exception.Message) }

    $gateInputs = [pscustomobject][ordered]@{
        gpu = [pscustomobject][ordered]@{
            vendorsPresent = $(if ($hw) { @($hw.gpu.vendorsPresent) } else { $null })
        }
        memory = [pscustomobject][ordered]@{
            totalGb = $(if ($hw) { $hw.memory.totalGb } else { $null })
        }
        storage = [pscustomobject][ordered]@{
            hasSsd = $(if ($hw) { $hw.storage.hasSsd } else { $null })
            hasHdd = $(if ($hw) { $hw.storage.hasHdd } else { $null })
        }
        chassis = [pscustomobject][ordered]@{
            chassisClass = $(if ($hw) { $hw.chassis.chassisClass } else { $null })
            hasBattery   = $(if ($hw) { $hw.chassis.hasBattery } else { $null })
            onAcPower    = $(if ($hw) { $hw.chassis.onAcPower } else { $null })
        }
        build = [pscustomobject][ordered]@{
            build            = $(if ($build) { $build.build } else { $null })
            ubr              = $(if ($build) { $build.ubr } else { $null })
            editionId        = $(if ($build) { $build.editionId } else { $null })
            displayVersion   = $(if ($build) { $build.displayVersion } else { $null })
            insiderChannel   = $(if ($build) { $build.insiderChannel } else { $null })
            inSupportedScope = $(if ($build) { $build.inSupportedScope } else { $null })
            readSucceeded    = $(if ($build) { $build.readSucceeded } else { $false })
        }
    }

    $eligibility = @()
    $resolverAvailable = ($null -ne (Get-Command -Name Get-NxTweakEligibility -CommandType Function -ErrorAction SilentlyContinue))
    if (@($Tweaks).Count -gt 0) {
        if (-not $resolverAvailable) {
            $unc.Add('Get-NxTweakEligibility not loaded (NxCompat.ps1) - eligibility was not evaluated; gate inputs are still reported')
        } elseif ($null -eq $hw -or $null -eq $build) {
            $unc.Add('hardware or build report unavailable - eligibility evaluation refused rather than guessed')
        } else {
            foreach ($t in @($Tweaks)) {
                try {
                    $e = Get-NxTweakEligibility -Tweak $t -HardwareReport $hw -BuildReport $build
                    $eligibility += [pscustomobject][ordered]@{
                        tweakId  = $e.tweakId
                        eligible = $e.eligible
                        reasons  = @($e.reasons)
                        warnings = @($e.warnings)
                        riskClass = $e.riskClass
                    }
                } catch {
                    $unc.Add('eligibility evaluation failed for tweak ' + [string]$t.id + ': ' + [string]$_.Exception.Message)
                    $eligibility += [pscustomobject][ordered]@{ tweakId = [string]$t.id; eligible = $null; reasons = @('evaluation failed'); warnings = @(); riskClass = [string]$t.risk }
                }
            }
        }
    }

    $allUnc = @()
    if ($hw) { $allUnc += @($hw.uncertainty) }
    if ($build) { $allUnc += @($build.uncertainty) }
    $allUnc += $unc.ToArray()

    $report = [pscustomobject][ordered]@{
        functionName      = 'Get-Nx20CompatibilityReport'
        readOnly          = $true
        generatedUtc      = (Get-Date).ToUniversalTime().ToString('o')
        gateInputs        = $gateInputs
        hardwareSummary   = [pscustomobject][ordered]@{
            cpuVendor      = $(if ($hw) { $hw.cpu.vendor } else { $null })
            cpuName        = $(if ($hw) { $hw.cpu.name } else { $null })
            physicalCores  = $(if ($hw) { $hw.cpu.physicalCores } else { $null })
            logicalProcessors = $(if ($hw) { $hw.cpu.logicalProcessors } else { $null })
            gpuVendors     = $(if ($hw) { @($hw.gpu.vendorsPresent) } else { $null })
            totalRamGb     = $(if ($hw) { $hw.memory.totalGb } else { $null })
            storage        = $(if ($hw) { @($hw.storage.disks) } else { $null })
            chassisClass   = $(if ($hw) { $hw.chassis.chassisClass } else { $null })
        }
        buildSummary      = $(if ($build) { [pscustomobject][ordered]@{ productName = $build.productName; editionId = $build.editionId; displayVersion = $build.displayVersion; build = $build.build; ubr = $build.ubr; marketing = $build.marketing; inSupportedScope = $build.inSupportedScope; insiderChannel = $build.insiderChannel } } else { $null })
        eligibilityEvaluated = ($eligibility.Count -gt 0)
        eligibility       = $eligibility
        resolverNote      = 'Gate inputs are the exact fields Get-NxTweakEligibility reads. When -Tweaks is supplied, the real resolver is called; NX20 never re-implements the rules.'
        capabilityNotes   = @(
            'GPU vendor detection is PCI vendor-ID based (r4) - no marketing-name guessing.',
            'RAM/SSD/chassis gates use NxHardware uncertainty semantics: an unreadable storage class reports hasSsd=false with uncertainty, which the resolver treats as ineligible rather than silently passing.',
            'Administrator-only facts that a user-context report cannot read are recorded in uncertainty, not assumed.'
        )
        uncertainty       = $allUnc
    }
    $path = Write-Nx20ReportFile -Report $report -FileName 'NEXTRIX-NX20-compatibility' -OutputFolder $OutputFolder
    if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
    return $report
}

# ============================================================================
# NX20-010 - Device configuration inspection (read-only)
# ============================================================================

function Get-Nx20DeviceConfigurationReport {
    <#
        Inventory mode (no -InstanceId): present devices with status/problem code.
        Detail mode (-InstanceId): a documented property allowlist via
        Get-PnpDeviceProperty, joined to the installed driver record, plus the
        parent device. Sensitive property keys (serial numbers) are deliberately
        not read. Read-only: nothing is enabled/disabled/updated.
    #>
    [CmdletBinding()]
    param(
        [string]$InstanceId,
        [string]$Class,
        [int]$MaxDevices = 200,
        [string]$OutputFolder
    )
    if ($MaxDevices -lt 1) { $MaxDevices = 1 }
    if ($MaxDevices -gt 1000) { $MaxDevices = 1000 }

    $unc = New-Object System.Collections.Generic.List[string]
    $pnpAvailable = ($null -ne (Get-Command -Name Get-PnpDevice -ErrorAction SilentlyContinue))
    if (-not $pnpAvailable) {
        $unc.Add('Get-PnpDevice unavailable in this host - device configuration inspection cannot run')
        $report = [pscustomobject][ordered]@{
            functionName = 'Get-Nx20DeviceConfigurationReport'
            readOnly     = $true
            generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            mode         = 'Unavailable'
            reason       = 'The documented PnpDevice cmdlets are not available in this host; NEXTRIX does not substitute an undocumented write-capable path.'
            device       = $null
            devices      = @()
            uncertainty  = @($unc.ToArray())
        }
        $path = Write-Nx20ReportFile -Report $report -FileName 'NEXTRIX-NX20-device-configuration' -OutputFolder $OutputFolder
        if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
        return $report
    }

    $dm = Get-Nx20DriverRecordMap -Uncertainty $unc
    $propertyKeys = @(
        'DEVPKEY_Device_DeviceDesc',
        'DEVPKEY_Device_FriendlyName',
        'DEVPKEY_Device_Class',
        'DEVPKEY_Device_Manufacturer',
        'DEVPKEY_Device_DriverVersion',
        'DEVPKEY_Device_DriverDate',
        'DEVPKEY_Device_DriverProvider',
        'DEVPKEY_Device_DriverDesc',
        'DEVPKEY_Device_DriverInfPath',
        'DEVPKEY_Device_Service',
        'DEVPKEY_Device_ProblemCode',
        'DEVPKEY_Device_LocationInfo',
        'DEVPKEY_Device_Parent',
        'DEVPKEY_Device_HardwareIds',
        'DEVPKEY_Device_CompatibleIds',
        'DEVPKEY_Device_InstallDate',
        'DEVPKEY_Device_LastArrivalDate'
    )

    if (-not [string]::IsNullOrWhiteSpace($InstanceId)) {
        $dev = $null
        try { $dev = Get-PnpDevice -InstanceId $InstanceId -ErrorAction Stop } catch { $unc.Add('Get-PnpDevice -InstanceId failed: ' + [string]$_.Exception.Message) }
        if ($null -eq $dev) {
            $report = [pscustomobject][ordered]@{
                functionName = 'Get-Nx20DeviceConfigurationReport'
                readOnly     = $true
                generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                mode         = 'Detail'
                reason       = 'device not found for the supplied instance id (nothing is guessed)'
                device       = $null
                devices      = @()
                uncertainty  = @($unc.ToArray())
            }
            $path = Write-Nx20ReportFile -Report $report -FileName 'NEXTRIX-NX20-device-configuration' -OutputFolder $OutputFolder
            if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
            return $report
        }

        $props = @()
        $rawParentId = $null
        $batch = @()
        $batchOk = $false
        try {
            # One documented batched call is much faster than 17 round-trips; if the
            # host rejects the batch, fall back to the per-key loop below.
            $batch = @(Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $propertyKeys -ErrorAction Stop)
            $batchOk = ($batch.Count -gt 0)
        } catch {
            $unc.Add('batched Get-PnpDeviceProperty failed: ' + [string]$_.Exception.Message + ' - retrying per key')
        }
        if (-not $batchOk) {
            foreach ($k in $propertyKeys) {
                try {
                    $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $k -ErrorAction Stop
                    if ($null -ne $p) { $batch += $p }
                } catch { continue }  # a property absent for this device is normal, not an error
            }
        }
        foreach ($p in @($batch)) {
            $k = [string]$p.KeyName
            if ([string]::IsNullOrWhiteSpace($k)) { continue }
            $v = $p.Data
            if ($null -eq $v) { continue }
            if ($v -is [array]) { $v = (@($v) | ForEach-Object { [string]$_ }) -join ', ' }
            elseif ($v -is [datetime]) { $v = $v.ToString('o') }
            else { $v = [string]$v }
            if ([string]::IsNullOrWhiteSpace([string]$v)) { continue }
            if ($k -eq 'DEVPKEY_Device_Parent') { $rawParentId = [string]$v; $v = Select-Nx20MaskedInstanceId ([string]$v) }
            $props += [pscustomobject][ordered]@{ key = $k; value = [string]$v }
        }

        $key = ([string]$dev.InstanceId).Trim().ToLower()
        $rec = $null
        if ($dm.available -and $dm.map.ContainsKey($key)) { $rec = $dm.map[$key] }

        $parentName = $null
        if ($rawParentId) {
            try {
                $parent = Get-PnpDevice -InstanceId $rawParentId -ErrorAction SilentlyContinue
                if ($parent) { $parentName = [string]$parent.FriendlyName }
            } catch { $unc.Add('parent device lookup failed: ' + [string]$_.Exception.Message) }
        }

        $report = [pscustomobject][ordered]@{
            functionName = 'Get-Nx20DeviceConfigurationReport'
            readOnly     = $true
            generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            mode         = 'Detail'
            device       = [pscustomobject][ordered]@{
                instanceId    = (Select-Nx20MaskedInstanceId ([string]$dev.InstanceId))
                friendlyName  = [string]$dev.FriendlyName
                className     = [string]$dev.Class
                status        = [string]$dev.Status
                problem       = [string]$dev.Problem
                problemText   = [string]$dev.ProblemDescription
                manufacturer  = [string]$dev.Manufacturer
                service       = [string]$dev.Service
                parentInstanceId = $(if ($rawParentId) { Select-Nx20MaskedInstanceId $rawParentId } else { $null })
                parentFriendlyName = $parentName
                driverVersion = $(if ($rec) { $rec.version } else { $null })
                driverDate    = $(if ($rec -and $rec.driverDate) { $rec.driverDate.ToString('yyyy-MM-dd') } else { $null })
                driverProvider = $(if ($rec) { $rec.provider } else { $null })
                infName       = $(if ($rec) { $rec.infName } else { $null })
                isSigned      = $(if ($rec) { $rec.isSigned } else { $null })
                signer        = $(if ($rec) { $rec.signer } else { $null })
            }
            properties   = $props
            devices      = @()
            propertyPolicy = 'Documented Get-PnpDeviceProperty keys only. Serial-number properties are deliberately not read; instance ids are masked where they can carry a serial.'
            notes        = @('Read-only inspection: no device enable/disable, no driver update, no property write.')
            uncertainty  = @($unc.ToArray())
        }
        $path = Write-Nx20ReportFile -Report $report -FileName 'NEXTRIX-NX20-device-configuration' -OutputFolder $OutputFolder
        if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
        return $report
    }

    # Inventory mode
    $rows = @()
    $total = 0
    try {
        $present = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
        if (-not [string]::IsNullOrWhiteSpace($Class)) { $present = @($present | Where-Object { [string]$_.Class -eq $Class }) }
        $total = $present.Count
        foreach ($d in @($present | Select-Object -First $MaxDevices)) {
            $problem = [string]$d.Problem
            $rows += [pscustomobject][ordered]@{
                instanceId   = (Select-Nx20MaskedInstanceId ([string]$d.InstanceId))
                friendlyName = [string]$d.FriendlyName
                className    = [string]$d.Class
                status       = [string]$d.Status
                problem      = $problem
                problemText  = [string]$d.ProblemDescription
                hasProblem   = (-not [string]::IsNullOrWhiteSpace($problem) -and $problem -ne 'CM_PROB_NONE')
            }
        }
    } catch {
        $unc.Add('device enumeration failed: ' + [string]$_.Exception.Message)
    }

    $report = [pscustomobject][ordered]@{
        functionName = 'Get-Nx20DeviceConfigurationReport'
        readOnly     = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        mode         = 'Inventory'
        classFilter  = $Class
        totalDeviceCount = $total
        listedDeviceCount = $rows.Count
        truncated    = ($rows.Count -lt $total)
        devices      = $rows
        problemDeviceCount = @($rows | Where-Object { $_.hasProblem -eq $true }).Count
        detailHint   = 'Pass -InstanceId <device> for the documented per-device property set (driver, service, location, hardware ids, problem code).'
        propertyPolicy = 'Serial-number properties are deliberately not read; instance ids are masked where they can carry a serial.'
        notes        = @('Read-only inspection: no device enable/disable, no driver update, no property write.')
        uncertainty  = @($unc.ToArray())
    }
    $path = Write-Nx20ReportFile -Report $report -FileName 'NEXTRIX-NX20-device-configuration' -OutputFolder $OutputFolder
    if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
    return $report
}

# ============================================================================
# NX20-011 - BIOS/version currency guidance (report only, never flash)
# ============================================================================

function Get-Nx20BiosCurrencyReport {
    <#
        Facts + owner guidance only. Reports board/BIOS identity, firmware mode,
        Secure Boot and TPM state (when readable), and the documented currency
        procedure: compare the installed SMBIOS BIOS version and release date with
        the OEM support page for the exact model. NEXTRIX never downloads or
        flashes firmware, never interrupts, and never suggests third-party BIOS
        images. Evidence is E0: there is no documented programmatic currency API.
    #>
    [CmdletBinding()]
    param([string]$OutputFolder)

    $unc = New-Object System.Collections.Generic.List[string]
    $boards = @(Get-Nx20CimSafe -ClassName 'Win32_BaseBoard' -Uncertainty $unc)
    $bioss = @(Get-Nx20CimSafe -ClassName 'Win32_BIOS' -Uncertainty $unc)
    $systems = @(Get-Nx20CimSafe -ClassName 'Win32_ComputerSystem' -Uncertainty $unc)
    $fw = Get-Nx20FirmwareType
    foreach ($u in @($fw.uncertainty)) { if ($u) { $unc.Add([string]$u) } }

    $board = $null
    if ($boards.Count -gt 0) {
        $b = $boards[0]
        $board = [pscustomobject][ordered]@{
            manufacturer = Convert-NxCleanText ([string]$b.Manufacturer)
            product      = Convert-NxCleanText ([string]$b.Product)
            version      = Convert-NxCleanText ([string]$b.Version)
        }
    }
    $bios = $null
    if ($bioss.Count -gt 0) {
        $b = $bioss[0]
        $bios = [pscustomobject][ordered]@{
            manufacturer      = Convert-NxCleanText ([string]$b.Manufacturer)
            smbiosBiosVersion = Convert-NxCleanText ([string]$b.SMBIOSBIOSVersion)
            biosVersion       = Convert-NxCleanText ([string]$b.Version)
            releaseDate       = (Convert-Nx20DateTime $b.ReleaseDate)
            smbiosMajor       = $b.SMBIOSMajorVersion
            smbiosMinor       = $b.SMBIOSMinorVersion
            firmwareType      = $fw.firmwareType
            firmwareTypeSource = $fw.source
        }
    } else {
        $unc.Add('Win32_BIOS returned no instances - BIOS currency cannot be judged (no value guessed)')
    }
    $system = $null
    if ($systems.Count -gt 0) {
        $cs = $systems[0]
        $system = [pscustomobject][ordered]@{
            manufacturer = Convert-NxCleanText ([string]$cs.Manufacturer)
            model        = Convert-NxCleanText ([string]$cs.Model)
            systemFamily = Convert-NxCleanText ([string]$cs.SystemFamily)
        }
    }

    # Secure Boot: registry state first (factual), documented cmdlet as fallback.
    $sbState = 'Uncertain'; $sbSource = $null
    try {
        $sbKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'
        if (Test-Path $sbKey) {
            $v = (Get-ItemProperty -Path $sbKey -Name 'UEFISecureBootEnabled' -ErrorAction Stop).UEFISecureBootEnabled
            if ([int]$v -eq 1) { $sbState = 'Enabled' } else { $sbState = 'Disabled' }
            $sbSource = 'registry UEFISecureBootEnabled'
        } else {
            $unc.Add('Secure Boot State registry key absent (typical for legacy-BIOS firmware or unsupported platform)')
        }
    } catch { $unc.Add('Secure Boot registry read failed: ' + [string]$_.Exception.Message) }
    if ($sbState -eq 'Uncertain' -and $null -ne (Get-Command -Name Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)) {
        try {
            if (Confirm-SecureBootUEFI -ErrorAction Stop) { $sbState = 'Enabled' } else { $sbState = 'Disabled' }
            $sbSource = 'Confirm-SecureBootUEFI'
        } catch {
            $unc.Add('Confirm-SecureBootUEFI failed (often requires elevation or non-UEFI firmware): ' + [string]$_.Exception.Message)
        }
    }

    # TPM: Get-Tpm (documented, may require elevation) then Win32_Tpm fallback.
    $tpm = [pscustomobject][ordered]@{ state = 'Uncertain'; present = $null; ready = $null; enabled = $null; activated = $null; specVersion = $null; source = $null }
    if ($null -ne (Get-Command -Name Get-Tpm -ErrorAction SilentlyContinue)) {
        try {
            $t = Get-Tpm -ErrorAction Stop
            $tpm.present = [bool]$t.TpmPresent
            $tpm.ready = [bool]$t.TpmReady
            $tpm.enabled = [bool]$t.TpmEnabled
            $tpm.activated = [bool]$t.TpmActivated
            $tpm.state = 'Read'
            $tpm.source = 'Get-Tpm'
        } catch { $unc.Add('Get-Tpm unavailable/denied: ' + [string]$_.Exception.Message) }
    }
    if ($tpm.state -eq 'Uncertain') {
        try {
            $wt = Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName 'Win32_Tpm' -ErrorAction Stop
            if ($wt) {
                $tpm.present = $true
                $tpm.enabled = [bool]$wt.IsEnabled_InitialValue
                $tpm.activated = [bool]$wt.IsActivated_InitialValue
                $tpm.specVersion = [string]$wt.SpecVersion
                $tpm.state = 'Read'
                $tpm.source = 'Win32_Tpm'
            }
        } catch { $unc.Add('Win32_Tpm read failed: ' + [string]$_.Exception.Message) }
    } elseif ($null -eq $tpm.specVersion) {
        # Get-Tpm reported state but not the spec version on this build: enrich with
        # the documented CIM class rather than leaving an unexplained null.
        try {
            $wt = Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName 'Win32_Tpm' -ErrorAction Stop
            if ($wt -and $wt.SpecVersion) { $tpm.specVersion = [string]$wt.SpecVersion; $tpm.source = 'Get-Tpm + Win32_Tpm (spec version)' }
        } catch { $unc.Add('Win32_Tpm spec-version enrichment failed: ' + [string]$_.Exception.Message) }
    }

    # BitLocker protection state (recovery-key reminder context; read-only).
    $bitlocker = [pscustomobject][ordered]@{ state = 'Uncertain'; volumes = @(); source = $null }
    if ($null -ne (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        try {
            $vols = @()
            foreach ($v in @(Get-BitLockerVolume -ErrorAction Stop)) {
                $vols += [pscustomobject][ordered]@{
                    mountPoint       = [string]$v.MountPoint
                    volumeStatus     = [string]$v.VolumeStatus
                    protectionStatus = [string]$v.ProtectionStatus
                    encryptionMethod = [string]$v.EncryptionMethod
                }
            }
            $bitlocker.volumes = $vols
            $bitlocker.state = 'Read'
            $bitlocker.source = 'Get-BitLockerVolume'
        } catch { $unc.Add('Get-BitLockerVolume unavailable/denied: ' + [string]$_.Exception.Message) }
    } else {
        $unc.Add('Get-BitLockerVolume not available in this host - BitLocker state not reported')
    }

    $report = [pscustomobject][ordered]@{
        functionName        = 'Get-Nx20BiosCurrencyReport'
        readOnly            = $true
        generatedUtc        = (Get-Date).ToUniversalTime().ToString('o')
        system              = $system
        board               = $board
        bios                = $bios
        secureBoot          = [pscustomobject][ordered]@{ state = $sbState; source = $sbSource }
        tpm                 = $tpm
        bitlocker           = $bitlocker
        currencyStatus      = 'ManualComparisonRequired'
        installedBiosVersion = $(if ($bios) { $bios.smbiosBiosVersion } else { $null })
        installedBiosReleaseDate = $(if ($bios) { $bios.releaseDate } else { $null })
        updateGuidance      = [pscustomobject][ordered]@{
            automationPolicy = 'NeverAutomated'
            flashingPerformed = $false
            vendorSupportRoute = 'The OEM support/download page for the EXACT system model (manufacturer + model recorded above). Board model pages are not a substitute for the system model on OEM laptops.'
            ownerSteps = @(
                'Record this report as the before-state (installed SMBIOS BIOS version + release date).',
                'Open the OEM support page for the exact system model and read the latest BIOS version and its release notes/fixes list.',
                'Compare the OEM page version with installedBiosVersion. Only a documented OEM advisory for this model is a reason to update; "newer is better" is not a NEXTRIX recommendation.',
                'Read the OEM update instructions and prerequisites (AC power, no interruption, supported OS, any required intermediate version).',
                'Make the BitLocker recovery key available / suspend protection where the OEM instructions or Microsoft guidance require it (reported state above).',
                'Apply ONLY the OEM-provided package/utility for this exact model. Windows Update may also deliver OEM firmware through the documented UEFI firmware update platform - do not bypass OEM packaging.',
                'After the update, re-run this report and record the new version; resume protection and verify boot/device health.'
            )
            prohibited = @(
                'Flashing from third-party/modded BIOS sites or "unlocked" images.',
                'Interrupting or powering off during a firmware update.',
                'Flashing on battery power or without a recovery path.',
                'Automating a flash from any script - including NEXTRIX.'
            )
            windowsUpdateNote = 'Microsoft documents the Windows UEFI firmware update platform (firmware delivered as a driver package by the OEM). Availability is OEM-controlled; NEXTRIX neither triggers nor blocks it.'
            vendorPages = @(
                'https://learn.microsoft.com/en-us/windows-hardware/drivers/bringup/windows-uefi-firmware-update-platform',
                'https://support.microsoft.com/en-us/windows/update-drivers-in-windows-ec62f46c-ff14-c91d-eead-d7126dc1f7b6'
            )
        }
        evidenceNote        = 'E0 by design: no Microsoft- or vendor-documented programmatic "is my BIOS current" API exists. This entry reports facts and an owner procedure; it makes no currency verdict and no performance claim.'
        notes               = @(
            'Firmware flashing is NEVER automated, never scripted, and never performed by NEXTRIX.',
            'SMBIOS strings are sanitized (junk values such as "To Be Filled By O.E.M." are dropped, r4).',
            'Secure Boot/TPM/BitLocker reads can require elevation; a denied read is recorded as uncertainty, not as "disabled".'
        )
        uncertainty         = @($unc.ToArray())
    }
    $path = Write-Nx20ReportFile -Report $report -FileName 'NEXTRIX-NX20-bios-currency' -OutputFolder $OutputFolder
    if ($path) { $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path }
    return $report
}
