#Requires -Version 5.1
<#
    Test-NX10.ps1 - NX10 Thermal Management self-test.

    SAFETY (directive Section 16 / SECURITY_POLICY.md Section 5):
    This test performs NO system mutation. It exercises ONLY:
      1. pure helpers (Kelvin conversions, '[N/A]' handling, throttle-bit decoding,
         CSV escaping, log-path resolution),
      2. the read-only report functions (001..007) against this machine, asserting
         their read-only invariants and uncertainty vocabulary,
      3. NX10-008 session logging inside a THROWAWAY TEMP directory, with a temp
         journal, and the journal record it writes,
      4. a static scan of src/nxcore/functions/NX10.ps1 for forbidden mutation
         cmdlets and for absent personal identifiers in report output.

    Every assertion is a claim a reviewer can reproduce. The temp tree is removed in
    a finally block even when an assertion fails.

    Exit code: 0 = all assertions pass, 1 = at least one failure.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\..\src\nxcore'
$srcPath = Join-Path $root 'functions\NX10.ps1'
. (Join-Path $root 'NxJournal.ps1')
. $srcPath

$pass = 0; $fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

# ---------------------------------------------------------------------------
# 1. Pure helpers - temperature conversion and '[N/A]' handling
# ---------------------------------------------------------------------------
$k = ConvertFrom-Nx10KelvinTenths -TenthsKelvin 3232
Assert-Nx 'kelvin-tenths: 3232 -> 323.2 K' ($null -ne $k -and [math]::Abs($k.kelvin - 323.2) -lt 0.01)
Assert-Nx 'kelvin-tenths: 3232 -> 50.0 C' ($null -ne $k -and [math]::Abs($k.celsius - 50.05) -le 0.1)
Assert-Nx 'kelvin-tenths: 0 is implausible -> $null' ($null -eq (ConvertFrom-Nx10KelvinTenths -TenthsKelvin 0))
Assert-Nx 'kelvin-tenths: 9999 is implausible -> $null' ($null -eq (ConvertFrom-Nx10KelvinTenths -TenthsKelvin 9999))
$kc = ConvertFrom-Nx10Kelvin -Kelvin 358.0
Assert-Nx 'kelvin: 358.0 -> 84.9 C' ($null -ne $kc -and [math]::Abs($kc.celsius - 84.85) -le 0.1)
Assert-Nx 'kelvin: 20 K is implausible -> $null' ($null -eq (ConvertFrom-Nx10Kelvin -Kelvin 20.0))

Assert-Nx "'[N/A]' -> null (never 0)" ($null -eq (ConvertTo-Nx10NullableNumber '[N/A]'))
Assert-Nx "'N/A' -> null" ($null -eq (ConvertTo-Nx10NullableNumber 'N/A'))
Assert-Nx "'60.00' -> 60.0" ([double](ConvertTo-Nx10NullableNumber '60.00') -eq 60.0)
Assert-Nx "'' -> null" ($null -eq (ConvertTo-Nx10NullableNumber ''))

# ---------------------------------------------------------------------------
# 2. Throttle bitmask decoding (documented NVML reason names)
# ---------------------------------------------------------------------------
$d1 = ConvertFrom-Nx10ThrottleMask -Mask '0x0000000000000001'
Assert-Nx 'mask 0x1 -> GpuIdle only' (@($d1.reasons).Count -eq 1 -and $d1.reasons[0] -eq 'GpuIdle')
$d2 = ConvertFrom-Nx10ThrottleMask -Mask '0x0000000000000002'
Assert-Nx 'mask 0x2 -> ApplicationsClocksSetting' (@($d2.reasons).Count -eq 1 -and $d2.reasons[0] -eq 'ApplicationsClocksSetting')
$d4 = ConvertFrom-Nx10ThrottleMask -Mask '0x0000000000000004'
Assert-Nx 'mask 0x4 -> SwPowerCap' (@($d4.reasons).Count -eq 1 -and $d4.reasons[0] -eq 'SwPowerCap')
$dT = ConvertFrom-Nx10ThrottleMask -Mask '0x0000000000000060'
Assert-Nx 'mask 0x60 -> SW+HW thermal slowdown' ((@($dT.reasons) -contains 'HwThermalSlowdown') -and (@($dT.reasons) -contains 'SwThermalSlowdown'))
$dU = ConvertFrom-Nx10ThrottleMask -Mask '0x0000000000000200'
Assert-Nx 'unknown bit 0x200 reported as unknown, not guessed' (@($dU.reasons).Count -eq 0 -and @($dU.unknownBits).Count -eq 1)
$dBad = ConvertFrom-Nx10ThrottleMask -Mask 'garbage'
Assert-Nx 'unparseable mask -> parseOk false' ($dBad.parseOk -eq $false)

# ---------------------------------------------------------------------------
# 3. CSV escaping and log-path resolution (temp directory only)
# ---------------------------------------------------------------------------
Assert-Nx 'csv: plain value unchanged' ((ConvertTo-Nx10CsvField 'abc') -eq 'abc')
Assert-Nx 'csv: comma quoted' ((ConvertTo-Nx10CsvField 'a,b') -eq '"a,b"')
Assert-Nx 'csv: quote doubled' ((ConvertTo-Nx10CsvField 'a"b') -eq '"a""b"')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('nx10-selftest-' + [guid]::NewGuid().ToString('N'))
try {
    $logDir = Join-Path $tmp 'logs'
    $rp = Resolve-Nx10LogPath -OutputPath (Join-Path $logDir 'session.csv')
    Assert-Nx 'log path: parent directory created' (Test-Path -LiteralPath $logDir -PathType Container)
    Assert-Nx 'log path: absolute path returned' ([System.IO.Path]::IsPathRooted($rp.filePath))
    Assert-Nx 'log path: leaf name preserved' ($rp.fileName -eq 'session.csv')

    $rpDir = Resolve-Nx10LogPath -OutputPath $logDir
    Assert-Nx 'log path: directory input -> generated csv name' ($rpDir.fileName -like 'NEXTRIX-thermal-session-*.csv')

    $noExt = Resolve-Nx10LogPath -OutputPath (Join-Path $logDir 'noext')
    Assert-Nx 'log path: missing extension -> .csv' ($noExt.fileName -eq 'noext.csv')

    $threwPlaceholder = $false
    try { Resolve-Nx10LogPath -OutputPath '<user-chosen log file path>' | Out-Null } catch { $threwPlaceholder = $true }
    Assert-Nx 'log path: registry placeholder refused' $threwPlaceholder

    $existing = Join-Path $logDir 'existing.csv'
    Set-Content -LiteralPath $existing -Value 'x'
    $threwOverwrite = $false
    try { Resolve-Nx10LogPath -OutputPath $existing | Out-Null } catch { $threwOverwrite = $true }
    Assert-Nx 'log path: existing file refused without -Append' $threwOverwrite
    $rpAppend = Resolve-Nx10LogPath -OutputPath $existing -Append
    Assert-Nx 'log path: -Append accepts an existing file' ($rpAppend.append -and $rpAppend.existed)

    # -----------------------------------------------------------------------
    # 4. NX10-008 session log: one temp file + one temp journal 'verify' record
    # -----------------------------------------------------------------------
    $journalDir = Join-Path $tmp 'journal'
    $null = Initialize-NxJournal -Path $journalDir
    $sessionPath = Join-Path $logDir 'session-run.csv'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $sess = Invoke-NxThermalSessionLog -OutputPath $sessionPath -DurationSeconds 2 -SampleIntervalSeconds 1 -JournalRoot $journalDir
    $sw.Stop()
    Assert-Nx 'session: file written' (Test-Path -LiteralPath $sessionPath -PathType Leaf)
    Assert-Nx 'session: outcome Applied' ($sess.outcome -eq 'Applied')
    Assert-Nx 'session: at least one sample row' ($sess.sampleRows -ge 1) ("rows=$($sess.sampleRows)")
    Assert-Nx 'session: bounded duration honoured (<25 s)' ($sw.Elapsed.TotalSeconds -lt 25)
    Assert-Nx 'session: changedConfiguration=false' ($sess.changedConfiguration -eq $false)
    Assert-Nx 'session: journaled' ($sess.journaled -eq $true)

    $sessionLines = @(Get-Content -LiteralPath $sessionPath)
    Assert-Nx 'session: provenance comment first' ($sessionLines[0] -like '# NEXTRIX thermal session log*')
    Assert-Nx 'session: csv header line present' ($sessionLines[2] -like 'timestampUtc,elapsedSeconds,powerSource,*')
    Assert-Nx 'session: data rows follow the header' ($sessionLines.Count -gt 3)
    $body = ($sessionLines | Select-Object -Skip 3) -join "`n"
    Assert-Nx 'session: uncertainty vocabulary present in rows' ($body -match 'Uncertain-|Available')

    $rd = Read-NxJournal -Path $journalDir
    Assert-Nx 'journal: exactly one entry, integrity clean' ($rd.entries.Count -eq 1 -and $rd.integrityErrors.Count -eq 0) (($rd.integrityErrors | ForEach-Object { $_ }) -join '; ')
    # PS 5.1: @($list) on a List[object] property throws 'Argument types do not
    # match'; pipe instead (the repository's other self-tests use the same form).
    $entry = $rd.entries | Select-Object -First 1
    Assert-Nx 'journal: operation is verify (never apply)' ($entry.operation -eq 'verify')
    Assert-Nx 'journal: tweak id NX10-008' ($entry.tweakId -eq 'NX10-008')
    Assert-Nx 'journal: records changedConfiguration=false' ($entry.modified.changedConfiguration -eq $false)
    Assert-Nx 'journal: stores leaf name only (no path)' ($entry.modified.pathRecorded -eq 'fileNameOnly' -and ([string]$entry.modified.fileName) -notmatch '[\\/]')

    # The rollback engine only considers 'apply' entries: this record must be invisible to it.
    $rollbackCandidates = @($rd.entries | Where-Object { $_.operation -eq 'apply' -and ($_.result -eq 'InProgress' -or $_.result -eq 'Success') })
    Assert-Nx 'rollback: thermal log record is not a restore candidate' ($rollbackCandidates.Count -eq 0)

    # So the owner cannot silently destroy evidence.
    $threwSessionOverwrite = $false
    try { Invoke-NxThermalSessionLog -OutputPath $sessionPath -DurationSeconds 1 -SampleIntervalSeconds 1 | Out-Null } catch { $threwSessionOverwrite = $true }
    Assert-Nx 'session: overwrite refused without -Append' $threwSessionOverwrite

    $appendRun = Invoke-NxThermalSessionLog -OutputPath $sessionPath -DurationSeconds 1 -SampleIntervalSeconds 1 -Append
    Assert-Nx 'session: -Append extends the file' ($appendRun.outcome -eq 'Applied' -and (Get-Content -LiteralPath $sessionPath).Count -gt $sessionLines.Count)

    # -----------------------------------------------------------------------
    # 5. Read-only report functions (001..007) on this machine
    # -----------------------------------------------------------------------
    $reports = [ordered]@{
        'NX10-001' = Get-NxCpuThermalReport
        'NX10-002' = Get-NxGpuThermalReport
        'NX10-003' = Get-NxCpuPowerLimitReport
        'NX10-004' = Get-NxGpuPowerLimitReport
        'NX10-005' = Get-NxFanSpeedReport
        'NX10-006' = Get-NxOemCoolingProfile
        'NX10-007' = Get-NxAcDcThermalReport
    }
    $stateVocab = @('Available', 'Available-Partial', 'Uncertain-Unavailable', 'Uncertain-VendorDependent', 'Uncertain-NotConclusive', 'Uncertain-SourceDisagreement', 'NotApplicable', 'NotExposedOnActivePlan', 'Partial', 'Full', 'Unavailable')
    foreach ($id in $reports.Keys) {
        $r = $reports[$id]
        Assert-Nx "$id : returns an object" ($null -ne $r)
        Assert-Nx "$id : tweakId matches" ($r.tweakId -eq $id)
        Assert-Nx "$id : readOnly = true" ($r.readOnly -eq $true)
        Assert-Nx "$id : noWritesPerformed = true" ($r.noWritesPerformed -eq $true)
        Assert-Nx "$id : states the data sources" (@($r.dataSources).Count -ge 1)
        Assert-Nx "$id : has an uncertainty collection" ($null -ne $r.PSObject.Properties['uncertainty'])
        Assert-Nx "$id : has a summary string" (-not [string]::IsNullOrWhiteSpace([string]$r.summary))
        Assert-Nx "$id : no personal identifier in output" (-not ($r | ConvertTo-Json -Depth 8).Contains($env:COMPUTERNAME))
    }

    $cpu = $reports['NX10-001']
    Assert-Nx 'NX10-001: throttle never classified' ($cpu.throttleAssessment.classifiedAsThrottle -eq $false)
    Assert-Nx 'NX10-001: three temperature sources probed' (@($cpu.temperature.sources).Count -eq 3)
    Assert-Nx 'NX10-001: headline state in vocabulary' ($stateVocab -contains [string]$cpu.temperature.headline.state)
    $headlineConsistent = (($cpu.temperature.headline.state -eq 'Available' -and $null -ne $cpu.temperature.headline.celsius) -or ($cpu.temperature.headline.state -ne 'Available' -and $null -eq $cpu.temperature.headline.celsius))
    Assert-Nx 'NX10-001: headline never publishes a value while uncertain' $headlineConsistent
    Assert-Nx 'NX10-001: every source carries evidence + limitation' (@($cpu.temperature.sources | Where-Object { $_.evidence -and $_.limitation }).Count -eq 3)

    $gpu = $reports['NX10-002']
    Assert-Nx 'NX10-002: coverage state in vocabulary' ($stateVocab -contains [string]$gpu.temperatureCoverage)
    $gpuNvidia = @($gpu.adapters | Where-Object { $_.vendor -eq 'NVIDIA' })
    if ($gpuNvidia.Count -gt 0 -and $gpuNvidia[0].temperatureState -eq 'Available') {
        Assert-Nx 'NX10-002: nvidia temperature is numeric when Available' ($null -ne $gpuNvidia[0].temperatureCelsius)
    }
    Assert-Nx 'NX10-002: non-NVIDIA adapters marked VendorDependent' (@($gpu.adapters | Where-Object { ($_.vendor -eq 'AMD' -or $_.vendor -eq 'Intel') -and $_.temperatureState -ne 'Uncertain-VendorDependent' }).Count -eq 0)

    $pl = $reports['NX10-003']
    Assert-Nx 'NX10-003: hardware power limit Uncertain-VendorDependent' ($pl.powerLimit.state -eq 'Uncertain-VendorDependent' -and $null -eq $pl.powerLimit.pl1Watts)
    Assert-Nx 'NX10-003: OS policy context labelled as not a power limit' ($pl.osPolicyContext.kind -like '*NOT a hardware power limit*')

    $gpl = $reports['NX10-004']
    Assert-Nx 'NX10-004: never changes a power limit' ($gpl.powerLimitChangesPerformed -eq $false)
    Assert-Nx 'NX10-004: nvidia limit fields numeric or null (never a guess)' (@($gpl.gpus | Where-Object { $null -ne $_.enforcedPowerLimitWatts -and $_.enforcedPowerLimitWatts -le 0 }).Count -eq 0)

    $fan = $reports['NX10-005']
    Assert-Nx 'NX10-005: fan control never performed' ($fan.fanControlPerformed -eq $false -and $fan.fanControlSupported -eq $false)
    Assert-Nx 'NX10-005: state in vocabulary' ($stateVocab -contains [string]$fan.state)

    $oem = $reports['NX10-006']
    Assert-Nx 'NX10-006: no OEM interface invoked' ($oem.oemInterfaceInvoked -eq $false -and $oem.firmwareWriteAttempted -eq $false)
    Assert-Nx 'NX10-006: every profile state Unknown' (@($oem.interfaces | Where-Object { $_.profileState -ne 'Unknown' }).Count -eq 0)
    Assert-Nx 'NX10-006: switching support None' (@($oem.interfaces | Where-Object { $_.switchingSupport -ne 'None-NotImplemented' }).Count -eq 0)

    $acdc = $reports['NX10-007']
    Assert-Nx 'NX10-007: power source in vocabulary' (@('AC', 'Battery', 'Uncertain-Unavailable') -contains [string]$acdc.powerSource.current)
    foreach ($planeName in @('maximumProcessorState', 'minimumProcessorState', 'performanceBoostMode', 'systemCoolingPolicy')) {
        Assert-Nx "NX10-007: $planeName state in vocabulary" ($stateVocab -contains [string]$acdc.thermalPolicy.$planeName.state)
    }
    Assert-Nx 'NX10-007: dcApplicable follows battery presence' ($acdc.powerSource.dcApplicable -eq $acdc.powerSource.hasBattery)

    # -----------------------------------------------------------------------
    # 6. Static mutation scan of the module source (no forbidden cmdlets)
    # -----------------------------------------------------------------------
    $source = Get-Content -LiteralPath $srcPath -Raw
    $forbidden = @(
        'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Remove-Item ',
        'Set-Service', 'Stop-Service', 'Start-Service', 'Set-CimInstance', 'Invoke-CimMethod', 'Set-ScheduledTask',
        'Set-ExecutionPolicy', 'bcdedit', 'reg add', 'reg delete', 'Set-NxRegistryValue', 'Invoke-NxRegistryTweak',
        '/setacvalueindex', '/setdcvalueindex', '/setactive', '/restoredefaultschemes', 'SetSpeed\(', 'SetPowerState'
    )
    $hits = @()
    foreach ($f in $forbidden) { if ($source -match $f) { $hits += $f } }
    Assert-Nx 'source: no forbidden mutation cmdlet present' ($hits.Count -eq 0) ($hits -join ', ')
    # The only directory/file creation allowed is the owner-chosen log path's parent
    # directory (NX10-008). Count it explicitly instead of banning New-Item outright.
    $newItemLines = @([regex]::Matches($source, 'New-Item'))
    Assert-Nx 'source: exactly one New-Item (log directory creation only)' ($newItemLines.Count -eq 1)
    Assert-Nx 'source: that New-Item targets the log directory' (($source -match "New-Item -Path \`$dir -ItemType Directory -Force"))
    Assert-Nx 'source: nvidia-smi never called with a setter' (-not ($source -match "'-pl'|'-lgc'|'-lmc'|'-r'")) 
    Assert-Nx 'source: declares its mutation surface' ($source -match 'MUTATION SURFACE')
    Assert-Nx 'source: states the no-fan-control policy' ($source -match 'never controls fans|NO universal fan-control')
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ("RESULT: " + $pass + " passed, " + $fail + " failed")
if ($fail -gt 0) { exit 1 }
exit 0
