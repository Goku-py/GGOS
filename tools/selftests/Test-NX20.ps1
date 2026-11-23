#Requires -Version 5.1
<#
    Test-NX20.ps1 - NX20 (Hardware & Driver Management) category self-test.

    SAFETY BOUNDARY (directive Section 16): this test writes ONLY to throwaway
    temp directories. Windows is touched ONLY through READ-ONLY queries (CIM,
    registry reads, Get-PnpDevice/Get-PnpDeviceProperty, nvidia-smi status when
    present, Get-BitLockerVolume/Get-Tpm when permitted). This test NEVER:
      - installs, removes, rolls back or updates a driver
      - runs pnputil, DISM, bcdedit, DDU or any vendor installer
      - flashes firmware or changes a device property/state
      - writes outside the temp folder

    Besides the report contracts, the test statically proves the module contains
    no mutating command invocation (AST command scan), which is the strongest
    read-only evidence available without executing a mutation.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\..\src\nxcore'
foreach ($m in 'NxJournal.ps1', 'NxBuild.ps1', 'NxVerify.ps1', 'NxHardware.ps1', 'NxCompat.ps1', 'NxRollback.ps1') {
    . (Join-Path $root $m)
}
# Load ONLY the category modules NX20 composes with (NX04 GPU helpers, NX07 adapter
# inventory, NX16 driver inventory, NX20 itself). Loading every file in functions/
# would make this test hostage to unrelated, concurrently-edited categories.
foreach ($fn in 'NX04.ps1', 'NX07.ps1', 'NX16.ps1', 'NX20.ps1') {
    $p = Join-Path $root ('functions\' + $fn)
    if (-not (Test-Path -LiteralPath $p)) { throw "required category module missing: $p" }
    . $p
}

$script:pass = 0
$script:fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('nx20-selftest-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $tmpRoot -ItemType Directory -Force | Out-Null

try {
    # ------------------------------------------------------------------------
    # 0. Module surface + static read-only proof (AST command scan).
    # ------------------------------------------------------------------------
    $publicFns = @(
        'Get-Nx20HardwareInventoryReport', 'Get-Nx20GpuCapabilityReport',
        'Get-Nx20VendorDriverReport', 'Get-Nx20NetworkDriverReport',
        'Get-Nx20UsbInventoryReport', 'Get-Nx20DriverHistoryReport',
        'Get-Nx20CompatibilityReport', 'Get-Nx20DeviceConfigurationReport',
        'Get-Nx20BiosCurrencyReport'
    )
    $missingFns = @($publicFns | Where-Object { $null -eq (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue) })
    Assert-Nx 'all 9 NX20 report functions are defined (11 registry entries)' ($missingFns.Count -eq 0) ($missingFns -join ',')

    $modulePath = Join-Path $root 'functions\NX20.ps1'
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
    Assert-Nx 'NX20.ps1 parses with zero errors' (@($parseErrors).Count -eq 0) (@($parseErrors | ForEach-Object { $_.Message }) -join '; ')

    $banned = @(
        'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Remove-Item',
        'Set-Service', 'New-Service', 'Start-Process', 'Start-Job', 'Invoke-Expression',
        'Set-CimInstance', 'New-CimInstance', 'Remove-CimInstance', 'Invoke-CimMethod',
        'pnputil', 'dism', 'bcdedit', 'shutdown', 'Restart-Computer', 'Stop-Computer',
        'Enable-PnpDevice', 'Disable-PnpDevice', 'Restart-NetAdapter', 'Set-NetAdapter',
        'Set-Disk', 'Initialize-Disk', 'Format-Volume'
    )
    $cmdNames = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    $hits = @($cmdNames | Where-Object { $banned -contains $_ })
    Assert-Nx 'NX20.ps1 invokes no mutating/driver/firmware command (AST scan)' ($hits.Count -eq 0) ($hits -join ',')
    Assert-Nx 'NX20.ps1 has no documented write route (no Set-ItemProperty in command set)' ($cmdNames -notcontains 'Set-ItemProperty')

    # Registry <-> code contract: 11 read-only function entries, every function resolvable.
    $regPath = Join-Path $PSScriptRoot '..\..\registry\NX20.json'
    $cat = Get-Content -LiteralPath $regPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Nx 'registry: NX20 defines 11 entries' (@($cat.tweaks).Count -eq 11)
    $allFunctionActions = $true
    $allReadOnly = $true
    $unresolved = @()
    foreach ($t in @($cat.tweaks)) {
        if ([string]$t.modificationType -ne 'none') { $allReadOnly = $false }
        foreach ($a in @($t.apply.actions)) {
            if ([string]$a.type -ne 'function') { $allFunctionActions = $false; continue }
            if ($null -eq (Get-Command -Name ([string]$a.function) -CommandType Function -ErrorAction SilentlyContinue)) { $unresolved += ([string]$a.function) }
        }
    }
    Assert-Nx 'registry: every NX20 action is a read-only function report' ($allFunctionActions -and $allReadOnly)
    Assert-Nx 'registry: every NX20 apply function resolves in the loaded module' ($unresolved.Count -eq 0) ($unresolved -join ',')
    Assert-Nx 'registry: no NX20 entry declares a registry/service modification target' (@($cat.tweaks | Where-Object { @($_.apply.actions | Where-Object { $_.type -in @('registry','service','task','power','appx') }).Count -gt 0 }).Count -eq 0)

    # ------------------------------------------------------------------------
    # A. NX20-001 hardware inventory master report.
    # ------------------------------------------------------------------------
    $r1 = Get-Nx20HardwareInventoryReport
    Assert-Nx '001: readOnly flag true' ($r1.readOnly -eq $true)
    Assert-Nx '001: hardware report read succeeded' ($r1.hardwareReadSucceeded -eq $true)
    Assert-Nx '001: CPU section composed from NxHardware' ($null -ne $r1.cpu -and -not [string]::IsNullOrWhiteSpace([string]$r1.cpu.name))
    Assert-Nx '001: board present with manufacturer/product' ($null -ne $r1.board -and -not [string]::IsNullOrWhiteSpace([string]$r1.board.manufacturer))
    Assert-Nx '001: BIOS present with SMBIOS version' ($null -ne $r1.bios -and -not [string]::IsNullOrWhiteSpace([string]$r1.bios.smbiosBiosVersion))
    Assert-Nx '001: serial withheld by policy, no serial field emitted' ($r1.board.serialWithheld -eq $true -and $r1.bios.serialWithheld -eq $true -and $null -eq $r1.board.PSObject.Properties['serial'])
    Assert-Nx '001: firmware type classified with a recorded source' ($r1.bios.firmwareType -in @('Uefi','LegacyBios','Uncertain') -and ($r1.bios.firmwareType -ne 'Uncertain' -or @($r1.uncertainty).Count -gt 0))
    Assert-Nx '001: OS build context composed (NX16-012 xref)' ($null -ne $r1.os -and $r1.os.build -gt 0)
    Assert-Nx '001: uncertainty is an array' ($r1.uncertainty -is [array])

    # ------------------------------------------------------------------------
    # B. NX20-002 GPU capability report + vendor-gate consistency.
    # ------------------------------------------------------------------------
    $r2 = Get-Nx20GpuCapabilityReport
    Assert-Nx '002: readOnly flag true' ($r2.readOnly -eq $true)
    Assert-Nx '002: adapters enumerated with vramSource honesty' (@($r2.adapters | Where-Object { $null -eq $_.vramSource }).Count -eq 0)
    $gateConsistent = $true
    foreach ($v in @('NVIDIA', 'AMD', 'Intel')) {
        $count = @($r2.adapters | Where-Object { $_.vendor -eq $v }).Count
        if ([bool]$r2.vendorGates[$v].present -ne ($count -gt 0)) { $gateConsistent = $false }
        if ([int]$r2.vendorGates[$v].adapterCount -ne $count) { $gateConsistent = $false }
    }
    Assert-Nx '002: vendorGates present/adapterCount match the adapter list' $gateConsistent
    Assert-Nx '002: vendorsPresent matches adapter vendors' ((@($r2.vendorsPresent) | Sort-Object) -join ',' -eq ((@($r2.adapters | ForEach-Object { $_.vendor } | Where-Object { $_ } | Select-Object -Unique) | Sort-Object) -join ','))
    Assert-Nx '002: gate mechanism points at NxCompat, not a duplicate gate' ([string]$r2.gateMechanism -like '*Get-NxTweakEligibility*')

    # ------------------------------------------------------------------------
    # C. NX20-003/004/005 vendor driver reports (inventory + guidance only).
    #      Every vendor is callable; supported mirrors hardware presence.
    # ------------------------------------------------------------------------
    $vendorPresence = @{
        'NVIDIA' = [bool]$r2.vendorGates['NVIDIA'].present
        'AMD'    = [bool]$r2.vendorGates['AMD'].present
        'Intel'  = [bool]$r2.vendorGates['Intel'].present
    }
    foreach ($vendor in @('NVIDIA', 'AMD', 'Intel')) {
        $vr = Get-Nx20VendorDriverReport -Vendor $vendor
        Assert-Nx ("$vendor driver report: supported mirrors adapter presence") ([bool]$vr.supported -eq $vendorPresence[$vendor])
        if ($vr.supported) {
            Assert-Nx ("$vendor driver report: adapter driver version/date reported") (@($vr.adapters | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.driverVersion) }).Count -eq 0)
            Assert-Nx ("$vendor driver report: currency requires manual vendor comparison") ($vr.currencyCheck.method -eq 'ManualComparisonRequired' -and -not [string]::IsNullOrWhiteSpace([string]$vr.currencyCheck.vendorDriverPage))
            Assert-Nx ("$vendor driver report: clean-install workflow documented (>=5 owner steps)") (@($vr.cleanInstallGuidance.ownerSteps).Count -ge 5)
            Assert-Nx ("$vendor driver report: DDU recorded but never bundled/run") ($vr.cleanInstallGuidance.thirdPartyUninstaller.nextrixBundles -eq $false -and $vr.cleanInstallGuidance.thirdPartyUninstaller.nextrixRuns -eq $false)
            Assert-Nx ("$vendor driver report: all driver operations NeverAutomated") ($vr.driverOperationPolicy.install -eq 'NeverAutomated' -and $vr.driverOperationPolicy.removal -eq 'NeverAutomated' -and $vr.driverOperationPolicy.firmwareFlash -eq 'NeverAutomated')
            Assert-Nx ("$vendor driver report: profile inspection honestly NotAvailable") ($vr.profileInspection.status -eq 'NotAvailable')
        } else {
            Assert-Nx ("$vendor driver report: absent hardware returns a reason, no guidance") (-not [string]::IsNullOrWhiteSpace([string]$vr.reason) -and $null -eq $vr.cleanInstallGuidance)
        }
    }

    # ------------------------------------------------------------------------
    # D. NX20-006 network driver report (reuses NX07).
    # ------------------------------------------------------------------------
    $r6 = Get-Nx20NetworkDriverReport
    Assert-Nx '006: adapterCount matches adapters array' ([int]$r6.adapterCount -eq @($r6.adapters).Count)
    Assert-Nx '006: capability ownership XREF to NX07 present' ([string]$r6.capabilityXref -like '*NX07*')
    Assert-Nx '006: driver provider list populated when adapters exist' ((@($r6.adapters).Count -eq 0) -or (@($r6.driverProviders).Count -gt 0))
    Assert-Nx '006: no MAC leaked in fallback-shaped fields' (@($r6.adapters | Where-Object { $_.PSObject.Properties['maskedMac'] -and ([string]$_.maskedMac -match '^[0-9A-F]{2}(:[0-9A-F]{2}){5}$') }).Count -eq 0)

    # ------------------------------------------------------------------------
    # E. NX20-007 USB inventory + instance-id masking rules.
    # ------------------------------------------------------------------------
    $r7 = Get-Nx20UsbInventoryReport
    Assert-Nx '007: deviceCount matches devices array' ([int]$r7.deviceCount -eq @($r7.devices).Count)
    Assert-Nx '007: controllers array consistent' ([int]$r7.controllerCount -eq @($r7.controllers).Count)
    Assert-Nx '007: NX08-007/NX09-005 cross-reference stated' ((@($r7.notes) -join ' ') -like '*NX08-007*' -and (@($r7.notes) -join ' ') -like '*NX09-005*')
    $maskSerial = Select-Nx20MaskedInstanceId 'USB\VID_1234&PID_5678\SERIAL123456'
    $maskPort = Select-Nx20MaskedInstanceId 'USB\ROOT_HUB30\5&315B279C&0&0'
    $maskPci = Select-Nx20MaskedInstanceId 'PCI\VEN_10DE&DEV_2520&SUBSYS_00000000&REV_A1\4&1A2B3C4D&0&0800'
    Assert-Nx '007: serial-like USB suffix redacted' ($maskSerial -eq 'USB\VID_1234&PID_5678\REDACTED')
    Assert-Nx '007: USB bus/port topology not over-redacted' ($maskPort -eq 'USB\ROOT_HUB30\5&315B279C&0&0')
    Assert-Nx '007: non-USB instance id untouched' ($maskPci -eq 'PCI\VEN_10DE&DEV_2520&SUBSYS_00000000&REV_A1\4&1A2B3C4D&0&0800')
    $rawUsb = @($r7.devices | Where-Object { $_.instanceId -match '(?i)^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\[0-9A-Z]{8,}$' -and $_.instanceId -notmatch '(?i)\\REDACTED$' })
    Assert-Nx '007: no serial-shaped USB instance id is emitted unmasked' ($rawUsb.Count -eq 0) (($rawUsb | ForEach-Object { $_.instanceId }) -join ',')

    # ------------------------------------------------------------------------
    # F. NX20-008 driver history reuses NX16-010.
    # ------------------------------------------------------------------------
    $r8 = Get-Nx20DriverHistoryReport
    $inv = Get-NxDriverInventory
    Assert-Nx '008: inventory source names NX16-010' ([string]$r8.inventorySource -like '*NX16*' -or [string]$r8.inventorySource -like '*Get-NxDriverInventory*')
    Assert-Nx '008: driverCount covers the reused NX16-010 enumeration' ([int]$r8.driverCount -ge [int]$inv.driverCount)
    Assert-Nx '008: completeness is explicitly labeled' ($r8.inventoryCompleteness -in @('Complete','Partial','Partial-CompletedFromDriverMap','FallbackDriverMap'))
    Assert-Nx '008: non-complete inventories carry an explanation' ($r8.inventoryCompleteness -eq 'Complete' -or -not [string]::IsNullOrWhiteSpace([string]$r8.completionNote))
    Assert-Nx '008: cleanup ownership XREF to NX16-011 stated' ((@($r8.notes) -join ' ') -like '*NX16-011*')
    Assert-Nx '008: no driver operation columns (report-only shape)' ($null -eq $r8.PSObject.Properties['removed'] -and $null -eq $r8.PSObject.Properties['installed'])

    # ------------------------------------------------------------------------
    # G. NX20-009 compatibility report + real resolver evaluation.
    # ------------------------------------------------------------------------
    $r9 = Get-Nx20CompatibilityReport
    Assert-Nx '009: gate inputs carry GPU vendors/RAM/SSD/chassis/build' ($null -ne $r9.gateInputs.gpu.vendorsPresent -and $null -ne $r9.gateInputs.memory.totalGb -and $null -ne $r9.gateInputs.storage.hasSsd -and -not [string]::IsNullOrWhiteSpace([string]$r9.gateInputs.chassis.chassisClass) -and $r9.gateInputs.build.build -gt 0)
    $fakePass = [pscustomobject]@{ id = 'NX-SELFTEST-PASS'; requiredHardware = [pscustomobject]@{ gpuVendor = @($r9.gateInputs.gpu.vendorsPresent[0]) }; builds = [pscustomobject]@{ min = 22631; max = 26300 }; risk = 'CORE'; apply = [pscustomobject]@{ actions = @() } }
    $fakeFail = [pscustomobject]@{ id = 'NX-SELFTEST-FAIL'; requiredHardware = [pscustomobject]@{ gpuVendor = @('ThisVendorDoesNotExist') }; builds = [pscustomobject]@{ min = 22631; max = 26300 }; risk = 'CORE'; apply = [pscustomobject]@{ actions = @() } }
    $r9b = Get-Nx20CompatibilityReport -Tweaks @($fakePass, $fakeFail)
    Assert-Nx '009: eligibility evaluated through the real resolver' ($r9b.eligibilityEvaluated -eq $true -and @($r9b.eligibility).Count -eq 2)
    $passRow = @($r9b.eligibility | Where-Object { $_.tweakId -eq 'NX-SELFTEST-PASS' })[0]
    $failRow = @($r9b.eligibility | Where-Object { $_.tweakId -eq 'NX-SELFTEST-FAIL' })[0]
    Assert-Nx '009: present vendor tweak is eligible' ($passRow.eligible -eq $true)
    Assert-Nx '009: absent vendor tweak is skipped with a reason' ($failRow.eligible -eq $false -and @($failRow.reasons).Count -gt 0)

    # ------------------------------------------------------------------------
    # H. NX20-010 device inspection (inventory + documented detail allowlist).
    # ------------------------------------------------------------------------
    $r10 = Get-Nx20DeviceConfigurationReport -MaxDevices 5
    Assert-Nx '010: inventory totals present' ($r10.mode -eq 'Inventory' -and $r10.totalDeviceCount -gt 0)
    Assert-Nx '010: inventory obeys the MaxDevices bound' (@($r10.devices).Count -le 5 -and $r10.listedDeviceCount -eq @($r10.devices).Count)
    $anyDev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $anyDev) {
        $r10d = Get-Nx20DeviceConfigurationReport -InstanceId $anyDev.InstanceId
        Assert-Nx '010: detail mode returns the documented property allowlist' ($r10d.mode -eq 'Detail' -and @($r10d.properties).Count -gt 0)
        Assert-Nx '010: serial-number properties deliberately absent' (@($r10d.properties | Where-Object { $_.key -like '*SerialNumber*' }).Count -eq 0)
        Assert-Nx '010: detail instance id masked where serial-like' (($r10d.device.instanceId -notmatch '(?i)USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\[0-9A-Z]{8,}$') -or ($r10d.device.instanceId -match '(?i)\\REDACTED$'))
    } else {
        Assert-Nx '010: no present device available to detail (environment limitation recorded)' $true
    }

    # ------------------------------------------------------------------------
    # I. NX20-011 BIOS currency guidance: never a flash path.
    # ------------------------------------------------------------------------
    $r11 = Get-Nx20BiosCurrencyReport
    Assert-Nx '011: installed BIOS version reported' (-not [string]::IsNullOrWhiteSpace([string]$r11.installedBiosVersion))
    Assert-Nx '011: currency is manual comparison, not a verdict' ($r11.currencyStatus -eq 'ManualComparisonRequired')
    Assert-Nx '011: flashing never automated and never performed' ($r11.updateGuidance.automationPolicy -eq 'NeverAutomated' -and $r11.updateGuidance.flashingPerformed -eq $false)
    Assert-Nx '011: OEM-only/AC-power/no-interruption prohibitions documented' ((@($r11.updateGuidance.prohibited) -join ' ') -match '(?i)third-party' -and (@($r11.updateGuidance.prohibited) -join ' ') -match '(?i)interrupt')
    Assert-Nx '011: firmware mode state restricted to known values' ($r11.bios.firmwareType -in @('Uefi','LegacyBios','Uncertain'))
    Assert-Nx '011: unknown Secure Boot/TPM states are Uncertain with reasons' (($r11.secureBoot.state -ne 'Uncertain' -or @($r11.uncertainty).Count -gt 0) -and $r11.tpm.state -in @('Read','Uncertain'))

    # ------------------------------------------------------------------------
    # J. Optional JSON export goes ONLY to the temp folder and is valid JSON.
    # ------------------------------------------------------------------------
    $outDir = Join-Path $tmpRoot 'reports'
    $e1 = Get-Nx20HardwareInventoryReport -OutputFolder $outDir
    $e11 = Get-Nx20BiosCurrencyReport -OutputFolder $outDir
    Assert-Nx 'export: report files created in the temp folder' ((Test-Path $e1.reportPath) -and (Test-Path $e11.reportPath) -and $e1.reportPath.StartsWith($tmpRoot))
    $parsed = $null
    try { $parsed = Get-Content -LiteralPath $e11.reportPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $parsed = $null }
    Assert-Nx 'export: exported JSON parses back' ($null -ne $parsed -and $parsed.functionName -eq 'Get-Nx20BiosCurrencyReport')
    Assert-Nx 'export: no report written when -OutputFolder is omitted' ($null -eq (Get-Nx20NetworkDriverReport).reportPath)
}
finally {
    if (Test-Path $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ('RESULT: {0} passed, {1} failed' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
