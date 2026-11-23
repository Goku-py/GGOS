#Requires -Version 5.1
<#
    NX11.ps1 - Background Activity & Services engine functions
    (registry entries NX11-001..019).

    Companion to registry/NX11.json (single source of truth for the category).

    Dependencies (dot-sourced before use; see Import-NxCore):
        NxJournal.ps1  - Capture-NxRegistryValue, Add-NxJournalEntry, Read-NxJournal,
                         Read-NxManifest, Test-NxCurrentEqualsDescriptor
        NxVerify.ps1   - Test-NxConfigurationState
        NxApply.ps1    - Set-NxRegistryValue (registry writes only through NX11 helpers)
        NxRollback.ps1 - Restore-NxRegistryOriginal (safe-stop recovery only)
        NX16.ps1       - Export-NxTaskState / Export-NxServiceState are REUSED when loaded
                         (optional; NX11 falls back to its own per-task XML export).

    Mutation surface (SECURITY_POLICY section 4 - this module never exceeds it):
        Set-NxStartupItemState        - StartupApproved values ONLY (binary enable/disable
                                        marker). Run/RunOnce COMMANDS are never edited or
                                        deleted - the Task Manager enable/disable mirror is
                                        the only mechanism (journaled exact bytes).
        Set-NxAppPermission           - AppPrivacy per-app policy list values ONLY
                                        (LetAppsRunInBackground_ForceAllowTheseApps /
                                        _ForceDenyTheseApps / _UserInControlOfTheseApps).
                                        The global LetAppsRunInBackground enum belongs to
                                        NX01-008 and is never written here.
        Set-NxEdgeBackgroundMode      - Edge policy BackgroundModeEnabled (documented).
        Set-NxEdgeStartupBoost        - Edge policy StartupBoostEnabled (documented).
        Set-NxScheduledTaskState      - allow-listed non-critical tasks ONLY; per-task XML
                                        backup BEFORE change; 3 verified fallbacks; protected
                                        task patterns are hard-skips.
        Set-NxSearchServiceConfig     - WSearch service startup type / optional stop.
        Set-NxSysMainConfig           - SysMain service startup type / optional stop.
        Set-NxXboxServicesConfig      - XboxGipSvc + XboxNetApiSvc ONLY (GamingServices /
                                        GamingServicesNet are report-only: Game Pass owners).
        Set-NxBluetoothServiceConfig  - bthserv + BthAvctpSvc service startup type.
        Set-NxFaxServiceConfig        - Fax service startup type.
        Set-NxRemoteRegistryConfig    - RemoteRegistry service startup type.
        Set-NxWerReportingConfig      - documented WER machine policy Disabled=1/0 ONLY
                                        (ErrorReporting.admx; WerSvc is NOT disabled).
        Set-NxMapsServiceConfig       - MapsBroker service startup type.
        Set-NxDiagTrackConfig         - DiagTrack service startup type (NX13 owns telemetry
                                        policy; no firewall blocking is ever written here).
        Set-NxThirdPartyServiceConfig - one explicitly named, non-Microsoft service per call,
                                        with -ConfirmService; never-touch list enforced.

    Read-only functions:
        Get-NxStartupInventory, Get-NxAppPermissionInventory,
        Get-NxScheduledTaskInventory, Get-NxScheduledTaskCandidates,
        Get-NxResourceHeavyProcessReport, Get-NxPrintSpoolerReport,
        Get-NxThirdPartyServiceInventory, Get-NxServiceDependencyReport.

    HARD BOUNDARIES (registry/schema.json + directive):
      - The never-touch service list is enforced in code for EVERY service path
        ($script:Nx11NeverTouchServices). The registry validator also rejects any
        declarative 'service' action targeting those names. Print Spooler is
        report-only by design (NX11-011 status Defined).
      - Update stack, audio, security health, profile/state, Store, networking core,
        VSS and firewall services are never started/stopped/reconfigured here.
      - Never a blanket service list: every service entry is single-purpose,
        detection-gated and journal-stamped.
      - No performance claims anywhere; reports describe observed configuration only.
      - PowerShell 5.1 syntax only (no ternary, no ??, no PS7-only cmdlets).
      - Journal-first: no mutation without a preceding Add-NxJournalEntry.
#>

# ============================================================================
# Policy data (never-touch + protected task patterns)
# ============================================================================

# Mirror of registry/schema.json neverTouchServices (the validator is authoritative;
# this code-side list closes the gap for function-routed service changes).
$script:Nx11NeverTouchServices = @(
    'wuauserv', 'BITS', 'UsoSvc', 'DoSvc', 'WaaSMedicSvc', 'TrustedInstaller',
    'Spooler', 'Audiosrv', 'AudioEndpointBuilder', 'Winmgmt', 'Schedule',
    'profsvc', 'UserMgr', 'StateRepository', 'InstallService', 'AppXSvc',
    'ClipSVC', 'SecurityHealthService', 'MDCoreSvc', 'WinDefend', 'WdNisSvc',
    'WdFilter', 'WdBoot', 'WdNisDrv', 'wscsvc', 'BFE', 'mpssvc', 'WlanSvc',
    'Netman', 'netprofm', 'NlaSvc', 'CDPSvc', 'CDPUserSvc', 'cryptsvc',
    'msiserver', 'wuapi', 'EFS', 'hidserv', 'DsmSvc', 'DevQueryBroker',
    'LicenseManager', 'VSS', 'swprv'
)

# Tasks that are never touched even if a caller names them: update stack, Defender,
# recovery/backup, WDI and Task Scheduler internals (r1 protected-skip precedent;
# cancelled with the recovery-sabotage policy in docs/RESEARCH_RECONCILIATION.md).
$script:Nx11ProtectedTaskPatterns = @(
    '\Microsoft\Windows\WDI\*',
    '\Microsoft\Windows\UpdateOrchestrator\*',
    '\Microsoft\Windows\WindowsUpdate\*',
    '\Microsoft\Windows\InstallService\*',
    '\Microsoft\Windows\Defender\*',
    '\Microsoft\Windows\BitLocker\*',
    '\Microsoft\Windows\SystemRestore\*',
    '\Microsoft\Windows\WindowsBackup\*',
    '\Microsoft\Windows\Registry\RegIdleBackup',
    '\Microsoft\Windows\TaskScheduler\*'
)

# Allow-listed scheduled-task candidates (non-critical, documented consumer tasks).
# Anything not on this list is refused by Set-NxScheduledTaskState.
$script:Nx11TaskAllowList = @(
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'Microsoft Compatibility Appraiser'; Caption = 'Application compatibility telemetry appraiser' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'ProgramDataUpdater'; Caption = 'Application Experience program data updater' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'StartupAppTask'; Caption = 'Startup application inventory task' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'PcaPatchDbTask'; Caption = 'Program Compatibility Assistant patch database task' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'MareBackup'; Caption = 'Application Experience backup task' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'Consolidator'; Caption = 'CEIP data consolidator' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'UsbCeip'; Caption = 'CEIP USB telemetry collector' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Feedback\Siuf\'; TaskName = 'DmClient'; Caption = 'Feedback (SIUF) client' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Feedback\Siuf\'; TaskName = 'DmClientOnScenarioDownload'; Caption = 'Feedback (SIUF) scenario download client' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Windows Error Reporting\'; TaskName = 'QueueReporting'; Caption = 'Windows Error Reporting queue flush' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\DiskDiagnostic\'; TaskName = 'Microsoft-Windows-DiskDiagnosticDataCollector'; Caption = 'Disk diagnostic data collector' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Maps\'; TaskName = 'MapsToastTask'; Caption = 'Maps toast notification task' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Maps\'; TaskName = 'MapsUpdateTask'; Caption = 'Maps offline data update task' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Maintenance\'; TaskName = 'WinSAT'; Caption = 'Windows System Assessment Tool maintenance' },
    [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Autochk\'; TaskName = 'Proxy'; Caption = 'Autochk proxy connectivity check' }
)

# ============================================================================
# Internal helpers (read-only except where explicitly named)
# ============================================================================

function New-Nx11Step {
    param([int]$Seq, [string]$Name, [string]$Outcome, [string]$Detail)
    return [pscustomobject][ordered]@{ step = $Seq; name = $Name; outcome = $Outcome; detail = $Detail }
}

function Get-Nx11Stamp {
    return (Get-Date -Format 'yyyyMMdd-HHmmss')
}

function Get-Nx11BackupRoot {
    return (Join-Path $env:ProgramData 'NEXTRIX\Backups')
}

function Resolve-Nx11BackupDestination {
    [CmdletBinding()]
    param([string]$DestinationPath)
    $dest = $DestinationPath
    if (-not $dest) { $dest = Join-Path (Get-Nx11BackupRoot) (Get-Nx11Stamp) }
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }
    return $dest
}

function Get-Nx11NonOverwritePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir = Split-Path -Parent $Path
    $base = [IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [IO.Path]::GetExtension($Path)
    $n = 2
    while (Test-Path -LiteralPath (Join-Path $dir "$base-$n$ext")) { $n++ }
    return (Join-Path $dir "$base-$n$ext")
}

function Get-Nx11SafeFileName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text, [int]$MaxLength = 150)
    $safe = ($Text -replace '[:\\/ ]', '_') -replace '[^A-Za-z0-9._\-]', '_'
    if ($safe.Length -gt $MaxLength) { $safe = $safe.Substring(0, $MaxLength) }
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'item' }
    return $safe
}

function Assert-Nx11JournalReady {
    # No mutation without an initialized, capture-Complete journal (adopt #2).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JournalRoot)
    if ([string]::IsNullOrWhiteSpace($JournalRoot)) { throw 'NX11: a journal root is required (journal-first invariant)' }
    $state = Read-NxManifest -Path $JournalRoot
    if (-not $state.present) { throw "NX11: journal not initialized at '$JournalRoot' - refusing to mutate (run NX16-004 pre-flight first)" }
    if ([string]$state.manifest.captureStatus -ne 'Complete') {
        throw "NX11: journal captureStatus is '$($state.manifest.captureStatus)' - destructive steps refuse unless capture is Complete"
    }
}

function Test-Nx11Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Nx11NeverTouchService {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    foreach ($n in $script:Nx11NeverTouchServices) {
        if ([string]::Equals($n, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-Nx11TaskPathProtected {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName)
    $full = $TaskPath.TrimEnd('\') + '\' + $TaskName
    if ($TaskPath.Trim() -eq '\' -or $TaskPath.Trim() -eq '') { $full = '\' + $TaskName }
    foreach ($p in $script:Nx11ProtectedTaskPatterns) {
        if ($full -like $p) { return $true }
    }
    return $false
}

function Get-Nx11TaskAllowEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName)
    $tp = $TaskPath.Trim()
    if ($tp -ne '\' -and -not $tp.EndsWith('\')) { $tp = $tp + '\' }
    foreach ($e in $script:Nx11TaskAllowList) {
        if ([string]::Equals($e.TaskPath, $tp, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($e.TaskName, $TaskName, [System.StringComparison]::OrdinalIgnoreCase)) { return $e }
    }
    return $null
}

function Get-Nx11StartValueName {
    param([int]$Value)
    $map = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
    if ($map.ContainsKey($Value)) { return $map[$Value] }
    return 'Unknown'
}

function Get-Nx11StartupApprovedState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Capture)
    if (-not $Capture.existed) { return 'NoApprovalValue' }
    if ([string]$Capture.kind -ne 'Binary') { return 'UnsupportedValue' }
    $b = @($Capture.value)
    if ($b.Count -lt 1) { return 'UnsupportedValue' }
    $first = [int]$b[0]
    if ($first -eq 2) { return 'Enabled' }
    if ($first -eq 3) { return 'Disabled' }
    return 'Unknown'
}

function Test-Nx11ByteEqual {
    [CmdletBinding()]
    param($A, $B)
    $a = @($A); $b = @($B)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ([int]$a[$i] -ne [int]$b[$i]) { return $false }
    }
    return $true
}

function Get-Nx11ServiceRecord {
    <# Read-only service snapshot: status plus startup type derived from the
       CurrentControlSet Start DWORD (authoritative; PS 5.1 ServiceController
       StartType is not relied upon). Missing services are honest, not guessed. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $rec = [ordered]@{
        name = $Name
        present = $false
        displayName = $null
        status = $null
        startType = 'Unknown'
        startValue = $null
        startKind = $null
        delayedAutostart = $null
    }
    if ($Name -notmatch '^[A-Za-z0-9._\-]{1,256}$') { $rec.startType = 'InvalidName'; return [pscustomobject]$rec }
    $svc = $null
    try { $svc = Get-Service -Name ([System.Management.Automation.WildcardPattern]::Escape($Name)) -ErrorAction Stop } catch { $svc = $null }
    $keyPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    $startCap = Capture-NxRegistryValue -Path $keyPath -Name 'Start'
    $delayCap = Capture-NxRegistryValue -Path $keyPath -Name 'DelayedAutostart'
    if ($null -ne $svc) {
        $rec.present = $true
        $rec.status = [string]$svc.Status
        try { $rec.displayName = [string]$svc.DisplayName } catch { }
    }
    if ($startCap.existed -and [string]$startCap.kind -eq 'DWord') {
        $rec.startValue = [int]$startCap.value
        $rec.startKind = 'DWord'
        $rec.startType = Get-Nx11StartValueName -Value ([int]$startCap.value)
    } elseif ($startCap.existed) {
        $rec.startKind = [string]$startCap.kind
        $rec.startType = 'UnsupportedValue'
    } elseif ($null -ne $svc) {
        try { if ($null -ne $svc.StartType) { $rec.startType = [string]$svc.StartType } } catch { }
    }
    if ($delayCap.existed) { $rec.delayedAutostart = $delayCap.value }
    return [pscustomobject]$rec
}

function Get-Nx11RamGb {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($null -ne $cs.TotalPhysicalMemory) {
            return [math]::Round(([double]$cs.TotalPhysicalMemory / 1GB), 1)
        }
    } catch { }
    return $null
}

function Get-Nx11SystemDiskMediaType {
    # Best-effort: Storage module mapping first, then an honest Unknown.
    try {
        $driveLetter = ($env:SystemDrive -replace ':','')
        $part = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop | Select-Object -First 1
        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop | Select-Object -First 1
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
        if ($null -ne $pd -and $pd.MediaType) {
            return [pscustomobject]@{ mediaType = [string]$pd.MediaType; source = 'Get-PhysicalDisk'; systemDrive = $env:SystemDrive }
        }
    } catch { }
    return [pscustomobject]@{ mediaType = 'Unknown'; source = 'unavailable (Storage module mapping failed)'; systemDrive = $env:SystemDrive }
}

function Get-Nx11BluetoothDevices {
    [CmdletBinding()]
    param()
    $out = New-Object System.Collections.Generic.List[object]
    $unc = New-Object System.Collections.Generic.List[string]
    $pnp = Get-Command -Name 'Get-PnpDevice' -ErrorAction SilentlyContinue
    if ($null -ne $pnp) {
        try {
            foreach ($d in @(Get-PnpDevice -Class Bluetooth -ErrorAction Stop)) {
                $out.Add([pscustomobject]@{ name = [string]$d.FriendlyName; status = [string]$d.Status; instanceId = [string]$d.InstanceId })
            }
        } catch { $unc.Add('Get-PnpDevice -Class Bluetooth failed: ' + [string]$_.Exception.Message) }
    } else {
        try {
            foreach ($d in @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPClass='Bluetooth'" -ErrorAction Stop)) {
                $out.Add([pscustomobject]@{ name = [string]$d.Name; status = [string]$d.Status; instanceId = [string]$d.DeviceID })
            }
        } catch { $unc.Add('Win32_PnPEntity Bluetooth query failed: ' + [string]$_.Exception.Message) }
    }
    return [pscustomobject]@{ devices = $out.ToArray(); uncertainty = $unc.ToArray() }
}

function Get-Nx11OfflineMapEvidence {
    [CmdletBinding()]
    param()
    $evidence = New-Object System.Collections.Generic.List[object]
    try {
        $pkg = Get-AppxPackage -Name 'Microsoft.WindowsMaps' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $pkg) { $evidence.Add([pscustomobject]@{ kind = 'appx'; detail = 'Microsoft.WindowsMaps ' + [string]$pkg.Version }) }
    } catch { }
    try {
        $base = Join-Path $env:LOCALAPPDATA 'Packages'
        if (Test-Path -LiteralPath $base) {
            foreach ($d in @(Get-ChildItem -LiteralPath $base -Directory -Filter 'Microsoft.WindowsMaps_*' -ErrorAction SilentlyContinue)) {
                foreach ($sub in @('LocalState\OfflineMaps','LocalState\MapData')) {
                    $p = Join-Path $d.FullName $sub
                    if (Test-Path -LiteralPath $p) {
                        $count = @(Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue).Count
                        $evidence.Add([pscustomobject]@{ kind = 'offlineData'; detail = $p; fileCount = $count })
                    }
                }
            }
        }
    } catch { }
    return $evidence.ToArray()
}

function Get-Nx11XboxEvidence {
    [CmdletBinding()]
    param()
    $packages = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('Microsoft.GamingServices','Microsoft.GamingApp')) {
        try {
            $p = Get-AppxPackage -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
            $packages.Add([pscustomobject]@{ name = $name; present = ($null -ne $p) })
        } catch { $packages.Add([pscustomobject]@{ name = $name; present = $null }) }
    }
    $marker = $false
    try { $marker = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\GamingServices' } catch { }
    $peripherals = @()
    try {
        $pnp = Get-Command -Name 'Get-PnpDevice' -ErrorAction SilentlyContinue
        if ($null -ne $pnp) {
            $peripherals = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like '*Xbox*' } | ForEach-Object { [string]$_.FriendlyName })
        }
    } catch { }
    return [pscustomobject]@{ packages = $packages.ToArray(); gamingServicesKeyPresent = $marker; xboxDevices = $peripherals }
}

# ============================================================================
# Journaled registry write helper (the only NX11 registry mutation path)
# ============================================================================

function Invoke-Nx11RegistryWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TweakId,
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string]$JournalRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('String','ExpandString','Binary','DWord','MultiString','QWord')][string]$Kind,
        [Parameter(Mandatory)]$Value,
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$Plan
    )
    $orig = Capture-NxRegistryValue -Path $Path -Name $Name
    $modified = [pscustomobject][ordered]@{ targetType = 'registry'; path = $Path; name = $Name; kind = $Kind; value = $Value }
    $state = [pscustomobject][ordered]@{ tweakId = $TweakId; target = "$Path :: $Name"; changed = $false; verified = $false; journalSeq = $null; reason = $null }

    if (-not $Plan -and -not $Approved) { throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    if (-not $Plan) { Assert-Nx11JournalReady -JournalRoot $JournalRoot }

    if ($orig.existed -and [string]$orig.kind -eq $Kind) {
        $same = $false
        if ($Kind -eq 'Binary') { $same = (Test-Nx11ByteEqual $orig.value $Value) }
        else {
            $a = ConvertTo-Json -InputObject $orig.value -Depth 6 -Compress
            $b = ConvertTo-Json -InputObject $Value -Depth 6 -Compress
            $same = ($a -eq $b)
        }
        if ($same) {
            if (-not $Plan) {
                $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $orig -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
                $state.journalSeq = $jr.seq
            }
            $state.changed = $false; $state.verified = $true; $state.reason = 'already in desired state'
            return $state
        }
    }

    if ($Plan) {
        $state.changed = $false; $state.verified = $false; $state.reason = "planned: would set $Path :: $Name = $Kind"
        return $state
    }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $orig -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    $state.journalSeq = $jr.seq
    try {
        Set-NxRegistryValue -Path $Path -Name $Name -Kind $Kind -Value $Value
        $check = Test-NxConfigurationState -Path $Path -Name $Name -Kind $Kind -ExpectedValue $Value
        if ($check.verified) {
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $orig -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles $Profiles
            $state.changed = $true; $state.verified = $true; $state.reason = $check.reason
            return $state
        }
        try { Restore-NxRegistryOriginal -Entry ([pscustomobject]@{ original = $orig }) | Out-Null } catch { }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo ([string]$check.reason) -Profiles $Profiles
        $state.changed = $true; $state.verified = $false; $state.reason = [string]$check.reason
        return $state
    } catch {
        $err = [string]$_.Exception.Message
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles
        $state.changed = $false; $state.verified = $false; $state.reason = 'mutation failed: ' + $err
        return $state
    }
}

# ============================================================================
# NX11-001 - Startup app inventory & selective management
# ============================================================================

function Get-Nx11RunKeyDescriptors {
    return @(
        [pscustomobject]@{ Scope = 'HKCU'; Location = 'Run'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; ApprovedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        [pscustomobject]@{ Scope = 'HKCU'; Location = 'RunOnce'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; ApprovedPath = $null },
        [pscustomobject]@{ Scope = 'HKLM'; Location = 'Run'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; ApprovedPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        [pscustomobject]@{ Scope = 'HKLM'; Location = 'RunOnce'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; ApprovedPath = $null },
        [pscustomobject]@{ Scope = 'HKLM32'; Location = 'Run'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; ApprovedPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' },
        [pscustomobject]@{ Scope = 'HKLM32'; Location = 'RunOnce'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; ApprovedPath = $null }
    )
}

function Get-NxStartupInventory {
    <# NX11-001 (read half) - approved-run-keys inventory. Read-only.
       Sources: Win32_StartupCommand, HKCU/HKLM Run+RunOnce (64/32), the per-user and
       machine Startup folders, and the StartupApproved enable/disable mirror. #>
    [CmdletBinding()]
    param([switch]$IncludeWmi)
    $items = New-Object System.Collections.Generic.List[object]
    $uncertainty = New-Object System.Collections.Generic.List[string]

    foreach ($d in @(Get-Nx11RunKeyDescriptors)) {
        if (-not (Test-Path -LiteralPath $d.Path)) { continue }
        $key = Get-Item -LiteralPath $d.Path -ErrorAction SilentlyContinue
        if ($null -eq $key) { $uncertainty.Add("Run key unreadable: $($d.Path)"); continue }
        foreach ($name in @($key.GetValueNames() | Sort-Object)) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $cmd = $null
            try { $cmd = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } catch { }
            $approved = $null; $approvedState = 'NotManaged'
            if ($d.ApprovedPath) {
                $cap = Capture-NxRegistryValue -Path $d.ApprovedPath -Name $name
                $approvedState = Get-Nx11StartupApprovedState -Capture $cap
                $approved = [pscustomobject][ordered]@{
                    path = $d.ApprovedPath; name = $name
                    existed = $cap.existed; kind = [string]$cap.kind; value = $cap.value; state = $approvedState
                }
            }
            $idText = "$($d.Scope)|$($d.Location)|$name"
            $hash = Get-NxSha256Hex $idText
            $items.Add([pscustomobject][ordered]@{
                itemId = 'st-' + $hash.Substring(0, 12)
                source = 'RunKey'
                scope = $d.Scope
                location = $d.Location
                name = $name
                command = [string]$cmd
                enabled = $(if ($d.ApprovedPath) { if ($approvedState -eq 'Enabled' -or $approvedState -eq 'NoApprovalValue') { $true } elseif ($approvedState -eq 'Disabled') { $false } else { $null } } else { $null })
                approvalState = $approvedState
                approved = $approved
                managedByNx11 = [bool]($d.ApprovedPath -and $d.Location -eq 'Run')
            })
        }
    }

    $folderPairs = @(
        @{ Scope = 'HKCU'; Folder = [Environment]::GetFolderPath('Startup'); ApprovedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
        @{ Scope = 'HKLM'; Folder = [Environment]::GetFolderPath('CommonStartup'); ApprovedPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    )
    foreach ($fp in $folderPairs) {
        if (-not $fp.Folder -or -not (Test-Path -LiteralPath $fp.Folder)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $fp.Folder -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $cap = Capture-NxRegistryValue -Path $fp.ApprovedPath -Name $f.Name
            $approvedState = Get-Nx11StartupApprovedState -Capture $cap
            $items.Add([pscustomobject][ordered]@{
                itemId = 'st-' + (Get-NxSha256Hex ("$($fp.Scope)|StartupFolder|$($f.Name)")).Substring(0, 12)
                source = 'StartupFolder'
                scope = $fp.Scope
                location = 'StartupFolder'
                name = $f.Name
                command = $f.FullName
                enabled = $(if ($approvedState -eq 'Enabled' -or $approvedState -eq 'NoApprovalValue') { $true } elseif ($approvedState -eq 'Disabled') { $false } else { $null })
                approvalState = $approvedState
                approved = [pscustomobject][ordered]@{ path = $fp.ApprovedPath; name = $f.Name; existed = $cap.existed; kind = [string]$cap.kind; value = $cap.value; state = $approvedState }
                managedByNx11 = $true
            })
        }
    }

    $wmi = @()
    if ($IncludeWmi) {
        try {
            $wmi = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ name = [string]$_.Name; command = [string]$_.Command; location = [string]$_.Location; user = [string]$_.User }
            })
        } catch { $uncertainty.Add('Win32_StartupCommand read failed: ' + [string]$_.Exception.Message) }
    }

    return [pscustomobject][ordered]@{
        tweakId = 'NX11-001'
        readOnly = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        items = $items.ToArray()
        enabledCount = @($items | Where-Object { $_.approvalState -eq 'Enabled' }).Count
        disabledCount = @($items | Where-Object { $_.approvalState -eq 'Disabled' }).Count
        unmanagedCount = @($items | Where-Object { $_.approvalState -eq 'NotManaged' -or $_.approvalState -eq 'Unknown' -or $_.approvalState -eq 'UnsupportedValue' }).Count
        wmiStartupCommands = $wmi
        notes = @(
            'Run/RunOnce commands are inventoried, never edited or deleted.',
            'Selective management writes only the StartupApproved binary marker (Task Manager enable/disable mirror).',
            'RunOnce entries are inventory-only: Windows does not honor a StartupApproved RunOnce mirror reliably.',
            'HKCU resolves to the invoking user when the engine runs elevated.'
        )
        uncertainty = $uncertainty.ToArray()
    }
}

function Set-NxStartupItemState {
    <# NX11-001 (write half) - per-item consent management of one Run/StartupFolder item.
       Journals the exact StartupApproved binary value before writing the 02/03 marker.
       Never touches the Run command value itself. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('HKCU','HKLM','HKLM32')][string]$Scope,
        [Parameter(Mandatory)][ValidateSet('Run','StartupFolder')][string]$Location,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Disable','Enable')][string]$Mode,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$BackupDestination,
        [switch]$Approved,
        [switch]$Plan
    )
    $steps = New-Object System.Collections.Generic.List[object]
    $seq = 0
    $result = [ordered]@{
        tweakId = 'NX11-001'; plan = [bool]$Plan.IsPresent; item = $Name; mode = $Mode
        outcome = 'Unknown'; steps = $null; backupFile = $null; journalSeq = $null
    }
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 260 -or $Name -match '[\x00-\x1f]') {
        $result.outcome = 'Refused'; $result.steps = @(New-Nx11Step 1 'validate-name' 'Failed' 'invalid item name'); return [pscustomobject]$result
    }

    $descriptor = $null
    if ($Location -eq 'Run') {
        foreach ($d in @(Get-Nx11RunKeyDescriptors)) {
            if ($d.Scope -eq $Scope -and $d.Location -eq 'Run') { $descriptor = $d; break }
        }
    } else {
        if ($Scope -eq 'HKLM32') { $result.outcome = 'Refused'; $result.steps = @(New-Nx11Step 1 'validate-scope' 'Failed' 'StartupFolder has no WOW6432Node scope'); return [pscustomobject]$result }
        $folder = $null; $approvedPath = $null
        if ($Scope -eq 'HKCU') { $folder = [Environment]::GetFolderPath('Startup'); $approvedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
        else { $folder = [Environment]::GetFolderPath('CommonStartup'); $approvedPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
        $descriptor = [pscustomobject]@{ Scope = $Scope; Location = 'StartupFolder'; Path = $folder; ApprovedPath = $approvedPath }
    }
    if ($null -eq $descriptor -or -not $descriptor.ApprovedPath) {
        $result.outcome = 'Refused'; $result.steps = @(New-Nx11Step 1 'resolve-target' 'Failed' 'no StartupApproved mirror exists for this item'); return [pscustomobject]$result
    }

    # The item must exist before its approval marker is changed.
    $exists = $false
    if ($Location -eq 'Run') {
        $runKey = Get-Item -LiteralPath $descriptor.Path -ErrorAction SilentlyContinue
        if ($null -ne $runKey) { $exists = (@($runKey.GetValueNames()) -contains $Name) }
    } else {
        $exists = (Test-Path -LiteralPath (Join-Path $descriptor.Path $Name))
    }
    $seq++; $steps.Add((New-Nx11Step $seq 'locate-item' $(if ($exists) { 'Complete' } else { 'Skipped' }) "scope=$Scope location=$Location name=$Name"))
    if (-not $exists) {
        $result.outcome = 'Skipped'; $result.steps = $steps.ToArray(); return [pscustomobject]$result
    }

    $cap = Capture-NxRegistryValue -Path $descriptor.ApprovedPath -Name $Name
    $currentState = Get-Nx11StartupApprovedState -Capture $cap
    # Journal a startupApproved descriptor (NOT the raw registry descriptor) so
    # Invoke-NxRollback delegates this target to Invoke-Nx11Rollback, which restores
    # the exact bytes with only-if-ours semantics.
    $original = [pscustomobject][ordered]@{
        targetType = 'startupApproved'; path = $descriptor.ApprovedPath; name = $Name
        keyExisted = $cap.keyExisted; existed = $cap.existed; kind = [string]$cap.kind; value = $cap.value
        scope = $Scope; location = $Location
    }
    $seq++; $steps.Add((New-Nx11Step $seq 'capture-approval' 'Captured' ("existed=$($cap.existed) kind=$($cap.kind) state=$currentState")))

    $desiredFirstByte = 3
    if ($Mode -eq 'Enable') { $desiredFirstByte = 2 }
    $sameState = (($Mode -eq 'Disable' -and $currentState -eq 'Disabled') -or ($Mode -eq 'Enable' -and $currentState -eq 'Enabled'))

    if ($sameState) {
        if (-not $Plan -and $JournalRoot) {
            $skip = [pscustomobject][ordered]@{ targetType = 'startupApproved'; path = $descriptor.ApprovedPath; name = $Name; action = 'AlreadyAtState' }
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX11-001' -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $skip -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        }
        $seq++; $steps.Add((New-Nx11Step $seq 'apply' 'Complete' "already $currentState - no write needed (idempotent)"))
        $result.outcome = 'AlreadyAtState'; $result.steps = $steps.ToArray(); return [pscustomobject]$result
    }

    $newBytes = $null
    if ($cap.existed -and [string]$cap.kind -eq 'Binary' -and @($cap.value).Count -ge 1) {
        $newBytes = @($cap.value)
        $newBytes[0] = [byte]$desiredFirstByte
    } else {
        $newBytes = [byte[]]@($desiredFirstByte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
    $modified = [pscustomobject][ordered]@{
        targetType = 'startupApproved'
        path = $descriptor.ApprovedPath
        name = $Name
        kind = 'Binary'
        value = $newBytes
        scope = $Scope
        location = $Location
        runPath = $(if ($Location -eq 'Run') { $descriptor.Path } else { $null })
    }

    if ($Plan) {
        $seq++; $steps.Add((New-Nx11Step $seq 'apply' 'Planned' "would set StartupApproved marker byte to $desiredFirstByte ($Mode)"))
        $result.outcome = 'Planned'; $result.steps = $steps.ToArray(); return [pscustomobject]$result
    }
    if (-not $Approved) { throw 'NX11-001: real application requires -Approved (explicit per-item consent)' }
    Assert-Nx11JournalReady -JournalRoot $JournalRoot

    # Defense-in-depth export of the approval key before change (optional target folder).
    if ($BackupDestination) {
        try {
            $dest = Resolve-Nx11BackupDestination -DestinationPath $BackupDestination
            $regPath = $descriptor.ApprovedPath -replace '^HK(LM|CU):\\', 'HK$1\'
            $file = Get-Nx11NonOverwritePath -Path (Join-Path $dest ('startupapproved-' + (Get-Nx11SafeFileName $Name) + '.reg'))
            & (Join-Path $env:SystemRoot 'System32\reg.exe') export $regPath $file /y | Out-Null
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $file)) { $result.backupFile = $file }
        } catch { $steps.Add((New-Nx11Step $seq 'backup' 'Warn' 'optional .reg export failed: ' + [string]$_.Exception.Message)) }
    }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX11-001' -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    $result.journalSeq = $jr.seq
    try {
        if (-not (Test-Path -LiteralPath $descriptor.ApprovedPath)) { New-Item -Path $descriptor.ApprovedPath -Force | Out-Null }
        New-ItemProperty -Path $descriptor.ApprovedPath -Name $Name -Value ([byte[]]$newBytes) -PropertyType Binary -Force | Out-Null
        $live = Capture-NxRegistryValue -Path $descriptor.ApprovedPath -Name $Name
        $liveState = Get-Nx11StartupApprovedState -Capture $live
        $expectedState = $(if ($Mode -eq 'Disable') { 'Disabled' } else { 'Enabled' })
        if ($liveState -eq $expectedState) {
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX11-001' -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles $Profiles
            $seq++; $steps.Add((New-Nx11Step $seq 'verify' 'Verified' "StartupApproved state=$liveState"))
            $result.outcome = 'Applied'; $result.steps = $steps.ToArray(); return [pscustomobject]$result
        }
        # Safe stop: restore the exact original bytes, then journal the failure.
        try {
            if ($cap.existed) { New-ItemProperty -Path $descriptor.ApprovedPath -Name $Name -Value ([byte[]]@($cap.value)) -PropertyType Binary -Force | Out-Null }
            else { Remove-ItemProperty -Path $descriptor.ApprovedPath -Name $Name -ErrorAction Stop }
        } catch { }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX11-001' -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo "verification read '$liveState'" -Profiles $Profiles
        $seq++; $steps.Add((New-Nx11Step $seq 'verify' 'Failed' "expected $expectedState, read $liveState"))
        $result.outcome = 'Failed'; $result.steps = $steps.ToArray(); return [pscustomobject]$result
    } catch {
        $err = [string]$_.Exception.Message
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX11-001' -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles
        $seq++; $steps.Add((New-Nx11Step $seq 'apply' 'Failed' $err))
        $result.outcome = 'Failed'; $result.steps = $steps.ToArray(); return [pscustomobject]$result
    }
}

# ============================================================================
# NX11-002 - Per-app background permissions (AppPrivacy policy lists)
# ============================================================================

function Get-NxAppPermissionInventory {
    <# NX11-002 (read half) - documented AppPrivacy per-app policy list values.
       The global LetAppsRunInBackground enum is NX01-008's target; reported only. #>
    [CmdletBinding()]
    param([int]$MaxPackages = 200)
    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
    $names = @('LetAppsRunInBackground','LetAppsRunInBackground_ForceAllowTheseApps','LetAppsRunInBackground_ForceDenyTheseApps','LetAppsRunInBackground_UserInControlOfTheseApps')
    $values = @()
    foreach ($n in $names) {
        $cap = Capture-NxRegistryValue -Path $policyPath -Name $n
        $values += [pscustomobject][ordered]@{ name = $n; existed = $cap.existed; kind = [string]$cap.kind; value = $cap.value }
    }
    $packages = @()
    $unc = @()
    try {
        $packages = @(Get-AppxPackage -ErrorAction Stop | Select-Object -First $MaxPackages | ForEach-Object {
            [pscustomobject]@{ name = [string]$_.Name; familyName = [string]$_.PackageFamilyName; version = [string]$_.Version }
        })
    } catch { $unc += 'Get-AppxPackage failed: ' + [string]$_.Exception.Message }
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-002'
        readOnly = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        policyPath = $policyPath
        policyValues = $values
        globalEnumOwner = 'NX01-008 (LetAppsRunInBackground enum; never written by NX11-002)'
        machineApps = $packages
        perAppMechanism = 'Machine policy multi-text lists (verified in local AppPrivacy.admx, build 26300): ForceAllowTheseApps / ForceDenyTheseApps / UserInControlOfTheseApps.'
        guidance = @(
            'Select one app (PackageFamilyName) at a time; NEXTRIX never proposes a blanket list.',
            'The per-app lists replace the whole REG_MULTI_SZ value; NEXTRIX performs a read-modify-write so sibling entries are preserved.',
            'Background denial can stop tile/notification updates and background mail sync (Microsoft CSP warning).'
        )
        packagesTruncated = ($packages.Count -ge $MaxPackages)
        uncertainty = $unc
    }
}

function Set-NxAppPermission {
    <# NX11-002 (write half) - per-app background permission override.
       Moves ONE PackageFamilyName between the three documented AppPrivacy lists.
       The global enum is deliberately untouched (NX01-008 owns it). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppFamilyName,
        [Parameter(Mandatory)][ValidateSet('ForceDeny','ForceAllow','UserInControl','RemoveOverride')][string]$Permission,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$Plan
    )
    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
    $listNames = @{
        ForceAllow = 'LetAppsRunInBackground_ForceAllowTheseApps'
        ForceDeny = 'LetAppsRunInBackground_ForceDenyTheseApps'
        UserInControl = 'LetAppsRunInBackground_UserInControlOfTheseApps'
    }
    $steps = New-Object System.Collections.Generic.List[object]
    $seq = 0
    $result = [ordered]@{ tweakId = 'NX11-002'; plan = [bool]$Plan.IsPresent; app = $AppFamilyName; permission = $Permission; steps = $null; outcome = 'Unknown'; journalSeqs = @() }

    if ($AppFamilyName -notmatch '^[A-Za-z0-9._\-]{3,200}$') {
        $result.outcome = 'Refused'; $result.steps = @(New-Nx11Step 1 'validate-app' 'Failed' 'PackageFamilyName is malformed'); return [pscustomobject]$result
    }
    if ($Permission -ne 'RemoveOverride' -and -not $listNames.ContainsKey($Permission)) {
        $result.outcome = 'Refused'; $result.steps = @(New-Nx11Step 1 'validate-permission' 'Failed' 'unknown permission target'); return [pscustomobject]$result
    }

    $captures = @{}
    foreach ($k in @('ForceAllow','ForceDeny','UserInControl')) {
        $captures[$k] = Capture-NxRegistryValue -Path $policyPath -Name $listNames[$k]
    }
    $seq++; $steps.Add((New-Nx11Step $seq 'capture-lists' 'Captured' 'three AppPrivacy per-app lists captured (exact current values)'))

    foreach ($k in @('ForceAllow','ForceDeny','UserInControl')) {
        $cap = $captures[$k]
        $items = @()
        if ($cap.existed -and @($cap.value).Count -gt 0) { $items = @($cap.value) }
        $filtered = @($items | Where-Object { -not [string]::Equals([string]$_, $AppFamilyName, [System.StringComparison]::OrdinalIgnoreCase) })
        $wanted = ($Permission -ne 'RemoveOverride' -and $k -eq $Permission)
        if ($wanted) { $filtered += $AppFamilyName }
        $newValue = [string[]]$filtered
        $oldValue = [string[]]$items
        $changed = (ConvertTo-Json -InputObject $oldValue -Depth 4 -Compress) -ne (ConvertTo-Json -InputObject $newValue -Depth 4 -Compress)
        if (-not $changed) {
            $seq++; $steps.Add((New-Nx11Step $seq ('list-' + $k) 'Complete' 'unchanged (idempotent)'))
            continue
        }
        $w = Invoke-Nx11RegistryWrite -TweakId 'NX11-002' -TweakVersion $TweakVersion -Approval $Approval -JournalRoot $JournalRoot -Path $policyPath -Name $listNames[$k] -Kind MultiString -Value $newValue -Profiles $Profiles -Approved:$Approved -Plan:$Plan
        $result.journalSeqs += $w.journalSeq
        $seq++; $steps.Add((New-Nx11Step $seq ('list-' + $k) $(if ($w.verified) { 'Verified' } elseif ($Plan) { 'Planned' } else { 'Failed' }) $w.reason))
        if (-not $Plan -and -not $w.verified) { $result.outcome = 'Failed'; $result.steps = $steps.ToArray(); return [pscustomobject]$result }
    }

    if ($Plan) { $result.outcome = 'Planned' } else { $result.outcome = 'Applied' }
    $result.steps = $steps.ToArray()
    return [pscustomobject]$result
}

# ============================================================================
# NX11-003 / NX11-004 - Edge documented policies
# ============================================================================

function Get-Nx11EdgePolicyPath {
    param([ValidateSet('User','Machine')][string]$Scope = 'User')
    if ($Scope -eq 'Machine') { return 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' }
    return 'HKCU:\SOFTWARE\Policies\Microsoft\Edge'
}

function Set-NxEdgeBackgroundMode {
    <# NX11-003 - documented Edge BackgroundModeEnabled policy (per-user default). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Disable','Enable')][string]$Mode = 'Disable',
        [ValidateSet('User','Machine')][string]$Scope = 'User',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$Plan
    )
    $path = Get-Nx11EdgePolicyPath -Scope $Scope
    $value = 1
    if ($Mode -eq 'Disable') { $value = 0 }
    $w = Invoke-Nx11RegistryWrite -TweakId 'NX11-003' -TweakVersion $TweakVersion -Approval $Approval -JournalRoot $JournalRoot -Path $path -Name 'BackgroundModeEnabled' -Kind DWord -Value $value -Profiles $Profiles -Approved:$Approved -Plan:$Plan
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-003'; mode = $Mode; scope = $Scope; policyPath = $path; valueName = 'BackgroundModeEnabled'; value = $value
        outcome = $(if ($Plan) { 'Planned' } elseif ($w.verified) { $(if ($w.changed) { 'Applied' } else { 'AlreadyAtState' }) } else { 'Failed' })
        verified = $w.verified; journalSeq = $w.journalSeq; detail = $w.reason
        note = 'Documented Edge policy (deployedge/microsoft-edge-policies/backgroundmodeenabled); Edge must be restarted to read the policy.'
    }
}

function Set-NxEdgeStartupBoost {
    <# NX11-004 - documented Edge StartupBoostEnabled policy (per-user default). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Disable','Enable')][string]$Mode = 'Disable',
        [ValidateSet('User','Machine')][string]$Scope = 'User',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$Plan
    )
    $path = Get-Nx11EdgePolicyPath -Scope $Scope
    $value = 1
    if ($Mode -eq 'Disable') { $value = 0 }
    $w = Invoke-Nx11RegistryWrite -TweakId 'NX11-004' -TweakVersion $TweakVersion -Approval $Approval -JournalRoot $JournalRoot -Path $path -Name 'StartupBoostEnabled' -Kind DWord -Value $value -Profiles $Profiles -Approved:$Approved -Plan:$Plan
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-004'; mode = $Mode; scope = $Scope; policyPath = $path; valueName = 'StartupBoostEnabled'; value = $value
        outcome = $(if ($Plan) { 'Planned' } elseif ($w.verified) { $(if ($w.changed) { 'Applied' } else { 'AlreadyAtState' }) } else { 'Failed' })
        verified = $w.verified; journalSeq = $w.journalSeq; detail = $w.reason
        note = 'Documented Edge policy (deployedge/microsoft-edge-policies/startupboostenabled); trade-off: Edge no longer preloads at sign-in, so first launch may be slower.'
    }
}

# ============================================================================
# NX11-005 / NX11-006 - Scheduled tasks
# ============================================================================

function Get-NxScheduledTaskInventory {
    <# NX11-005 - read-only full scheduled-task inventory. Optional XML export. #>
    [CmdletBinding()]
    param(
        [string]$DestinationPath,
        [switch]$ExportXml,
        [switch]$IncludeInfo
    )
    $getCmd = Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue
    if ($null -eq $getCmd) {
        return [pscustomobject][ordered]@{ tweakId = 'NX11-005'; readOnly = $true; cmdletAvailable = $false; tasks = @(); count = 0; uncertainty = @('Get-ScheduledTask unavailable in this host (ScheduledTasks module required)') }
    }
    $tasks = New-Object System.Collections.Generic.List[object]
    $unc = New-Object System.Collections.Generic.List[string]
    $dest = $null
    if ($ExportXml) {
        $dest = Resolve-Nx11BackupDestination -DestinationPath $DestinationPath
    }
    $expCmd = Get-Command -Name 'Export-ScheduledTask' -ErrorAction SilentlyContinue
    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction Stop | Sort-Object TaskPath, TaskName)) {
            $actions = @()
            foreach ($a in @($t.Actions)) {
                $line = [string]$a.Execute
                if ($a.Arguments) { $line = $line + ' ' + [string]$a.Arguments }
                $actions += $line
            }
            $rec = [ordered]@{
                taskPath = [string]$t.TaskPath
                taskName = [string]$t.TaskName
                state = [string]$t.State
                author = [string]$t.Author
                description = [string]$t.Description
                actions = $actions
                allowListed = ($null -ne (Get-Nx11TaskAllowEntry -TaskPath ([string]$t.TaskPath) -TaskName ([string]$t.TaskName)))
                protected = (Test-Nx11TaskPathProtected -TaskPath ([string]$t.TaskPath) -TaskName ([string]$t.TaskName))
            }
            if ($IncludeInfo) {
                try {
                    $info = Get-ScheduledTaskInfo -TaskPath ([System.Management.Automation.WildcardPattern]::Escape([string]$t.TaskPath)) -TaskName ([System.Management.Automation.WildcardPattern]::Escape([string]$t.TaskName)) -ErrorAction Stop
                    $rec.lastRunTime = [string]$info.LastRunTime
                    $rec.lastTaskResult = $info.LastTaskResult
                    $rec.nextRunTime = [string]$info.NextRunTime
                } catch { $unc.Add("info read failed for $($t.TaskPath)$($t.TaskName)") }
            }
            if ($ExportXml) {
                if ($null -eq $expCmd) { $unc.Add('Export-ScheduledTask unavailable - XML not exported') }
                else {
                    try {
                        $xml = Export-ScheduledTask -TaskPath ([System.Management.Automation.WildcardPattern]::Escape([string]$t.TaskPath)) -TaskName ([System.Management.Automation.WildcardPattern]::Escape([string]$t.TaskName)) -ErrorAction Stop
                        $file = Get-Nx11NonOverwritePath -Path (Join-Path $dest ('task-' + (Get-Nx11SafeFileName ([string]$t.TaskPath + [string]$t.TaskName)) + '.xml'))
                        Set-Content -LiteralPath $file -Value $xml -Encoding Unicode
                        $rec.xmlFile = $file
                    } catch { $unc.Add("XML export failed for $($t.TaskPath)$($t.TaskName): " + [string]$_.Exception.Message) }
                }
            }
            $tasks.Add([pscustomobject]$rec)
        }
    } catch {
        $unc.Add('Get-ScheduledTask enumeration failed: ' + [string]$_.Exception.Message)
    }
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-005'; readOnly = $true; cmdletAvailable = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        destinationPath = $dest
        count = $tasks.Count
        runningCount = @($tasks | Where-Object { $_.state -eq 'Running' }).Count
        disabledCount = @($tasks | Where-Object { $_.state -eq 'Disabled' }).Count
        allowListedCount = @($tasks | Where-Object { $_.allowListed }).Count
        tasks = $tasks.ToArray()
        note = 'Read-only inventory. Task XML export is additive and never changes task state.'
        uncertainty = $unc.ToArray()
    }
}

function Get-NxScheduledTaskCandidates {
    <# NX11-006 (selection surface) - allow-listed candidates with current state. #>
    [CmdletBinding()]
    param()
    $out = New-Object System.Collections.Generic.List[object]
    $unc = New-Object System.Collections.Generic.List[string]
    $getCmd = Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue
    foreach ($e in $script:Nx11TaskAllowList) {
        $state = 'NotDetected'; $protected = (Test-Nx11TaskPathProtected -TaskPath $e.TaskPath -TaskName $e.TaskName)
        if ($null -ne $getCmd) {
            try {
                $t = Get-ScheduledTask -TaskPath ([System.Management.Automation.WildcardPattern]::Escape($e.TaskPath)) -TaskName ([System.Management.Automation.WildcardPattern]::Escape($e.TaskName)) -ErrorAction Stop
                if ($null -ne $t) { $state = [string]$t.State }
            } catch { $state = 'NotDetected' }
        } else { $unc.Add('Get-ScheduledTask unavailable') }
        $out.Add([pscustomobject][ordered]@{ taskPath = $e.TaskPath; taskName = $e.TaskName; caption = $e.Caption; state = $state; protected = $protected; selectable = (-not $protected) })
    }
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-006'; readOnly = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        candidates = $out.ToArray(); count = $out.Count
        note = 'Only these allow-listed tasks may be disabled; each change requires its own call, XML backup and verification.'
        uncertainty = $unc.ToArray()
    }
}

function Get-Nx11TaskObject {
    param([string]$TaskPath, [string]$TaskName)
    $cmd = Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $null }
    try {
        return (Get-ScheduledTask -TaskPath ([System.Management.Automation.WildcardPattern]::Escape($TaskPath)) -TaskName ([System.Management.Automation.WildcardPattern]::Escape($TaskName)) -ErrorAction Stop)
    } catch { return $null }
}

function Set-Nx11TaskEnabled {
    <# Verified 3-fallback task enable/disable (r1 XOS DisableScheduledTasks pattern):
       cmdlet -> schtasks -> Task Scheduler COM, each re-checked via Get-ScheduledTask. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName, [Parameter(Mandatory)][bool]$Enabled)
    $attempts = New-Object System.Collections.Generic.List[object]
    $fullName = $TaskPath.TrimEnd('\') + '\' + $TaskName
    if ($TaskPath.Trim() -eq '\' -or $TaskPath.Trim() -eq '') { $fullName = '\' + $TaskName }

    for ($round = 1; $round -le 3; $round++) {
        # Mechanism 1: ScheduledTasks cmdlets.
        $mech = 'Disable-ScheduledTask'
        if ($Enabled) { $mech = 'Enable-ScheduledTask' }
        try {
            if ($Enabled) { Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null }
            else { Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null }
        } catch { $attempts.Add([pscustomobject]@{ round = $round; mechanism = $mech; error = [string]$_.Exception.Message }) }
        $t = Get-Nx11TaskObject -TaskPath $TaskPath -TaskName $TaskName
        if ($null -ne $t -and ((($Enabled) -and ([string]$t.State -ne 'Disabled')) -or ((-not $Enabled) -and ([string]$t.State -eq 'Disabled')))) {
            return [pscustomobject]@{ success = $true; mechanism = $mech; attempts = $attempts.ToArray(); state = [string]$t.State }
        }

        # Mechanism 2: schtasks.exe.
        $mech = 'schtasks'
        try {
            $flag = '/DISABLE'
            if ($Enabled) { $flag = '/ENABLE' }
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & (Join-Path $env:SystemRoot 'System32\schtasks.exe') /Change /TN $fullName $flag | Out-Null
            $exit = $LASTEXITCODE
            $ErrorActionPreference = $prev
            if ($exit -ne 0) { $attempts.Add([pscustomobject]@{ round = $round; mechanism = $mech; error = "schtasks exit code $exit" }) }
        } catch { $attempts.Add([pscustomobject]@{ round = $round; mechanism = $mech; error = [string]$_.Exception.Message }) }
        $t = Get-Nx11TaskObject -TaskPath $TaskPath -TaskName $TaskName
        if ($null -ne $t -and ((($Enabled) -and ([string]$t.State -ne 'Disabled')) -or ((-not $Enabled) -and ([string]$t.State -eq 'Disabled')))) {
            return [pscustomobject]@{ success = $true; mechanism = $mech; attempts = $attempts.ToArray(); state = [string]$t.State }
        }

        # Mechanism 3: Task Scheduler COM.
        $mech = 'Schedule.Service COM'
        $schedule = $null; $folder = $null; $task = $null
        try {
            $schedule = New-Object -ComObject Schedule.Service
            $schedule.Connect()
            $folder = $schedule.GetFolder($TaskPath)
            $task = $folder.GetTask($TaskName)
            $task.Enabled = $Enabled
        } catch { $attempts.Add([pscustomobject]@{ round = $round; mechanism = $mech; error = [string]$_.Exception.Message }) }
        finally {
            if ($null -ne $task) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($task) } catch { } }
            if ($null -ne $folder) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($folder) } catch { } }
            if ($null -ne $schedule) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($schedule) } catch { } }
        }
        $t = Get-Nx11TaskObject -TaskPath $TaskPath -TaskName $TaskName
        if ($null -ne $t -and ((($Enabled) -and ([string]$t.State -ne 'Disabled')) -or ((-not $Enabled) -and ([string]$t.State -eq 'Disabled')))) {
            return [pscustomobject]@{ success = $true; mechanism = $mech; attempts = $attempts.ToArray(); state = [string]$t.State }
        }
    }
    $last = Get-Nx11TaskObject -TaskPath $TaskPath -TaskName $TaskName
    $lastState = $null
    if ($null -ne $last) { $lastState = [string]$last.State }
    return [pscustomobject]@{ success = $false; mechanism = $null; attempts = $attempts.ToArray(); state = $lastState }
}

function Set-NxScheduledTaskState {
    <# NX11-006 (write half) - selective scheduled-task management.
       Allow-list enforced, protected patterns hard-skipped, per-task XML exported BEFORE
       the change, exact prior state journaled, 3 verified fallbacks. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][ValidateSet('Disable','Enable')][string]$Mode,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$BackupDestination,
        [switch]$Approved,
        [switch]$Plan
    )
    $steps = New-Object System.Collections.Generic.List[object]
    $seq = 0
    $TaskPath = ([string]$TaskPath).Trim()
    if ($TaskPath -ne '\' -and -not $TaskPath.EndsWith('\')) { $TaskPath = $TaskPath + '\' }
    $result = [ordered]@{
        tweakId = 'NX11-006'; plan = [bool]$Plan.IsPresent; task = ($TaskPath + $TaskName); mode = $Mode
        outcome = 'Unknown'; mechanism = $null; attempts = @(); xmlFile = $null; journalSeq = $null; steps = $null
    }
    if (Test-Nx11TaskPathProtected -TaskPath $TaskPath -TaskName $TaskName) {
        $result.outcome = 'ProtectedSkipped'
        $result.steps = @(New-Nx11Step 1 'protected-check' 'Skipped' 'task matches a protected pattern (update/Defender/recovery/WDI) - never touched')
        return [pscustomobject]$result
    }
    $allow = Get-Nx11TaskAllowEntry -TaskPath $TaskPath -TaskName $TaskName
    if ($null -eq $allow) {
        $result.outcome = 'Refused'
        $result.steps = @(New-Nx11Step 1 'allow-list' 'Failed' 'task is not on the NX11 allow-list - use Get-NxScheduledTaskCandidates')
        return [pscustomobject]$result
    }
    $task = Get-Nx11TaskObject -TaskPath $TaskPath -TaskName $TaskName
    if ($null -eq $task) {
        $result.outcome = 'Skipped'
        $result.steps = @(New-Nx11Step 1 'locate-task' 'Skipped' 'task not found on this machine')
        return [pscustomobject]$result
    }
    $currentState = [string]$task.State
    $seq++; $steps.Add((New-Nx11Step $seq 'locate-task' 'Complete' "state=$currentState allowListed=$($allow.Caption)"))

    $already = (($Mode -eq 'Disable' -and $currentState -eq 'Disabled') -or ($Mode -eq 'Enable' -and $currentState -ne 'Disabled'))
    if ($already) {
        if (-not $Plan -and $JournalRoot) {
            $skipMod = [pscustomobject][ordered]@{ targetType = 'task'; taskPath = $TaskPath; taskName = $TaskName; state = $currentState; action = 'AlreadyAtState' }
            $skipOrg = [pscustomobject][ordered]@{ targetType = 'task'; taskPath = $TaskPath; taskName = $TaskName; state = $currentState }
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX11-006' -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $skipOrg -Modified $skipMod -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        }
        $seq++; $steps.Add((New-Nx11Step $seq 'apply' 'Complete' "already $currentState - no change needed (idempotent)"))
        $result.outcome = 'AlreadyAtState'; $result.steps = $steps.ToArray(); return [pscustomobject]$result
    }

    if ($Plan) {
        $seq++; $steps.Add((New-Nx11Step $seq 'apply' 'Planned' "would $Mode task after exporting its XML"))
        $result.outcome = 'Planned'; $result.steps = $steps.ToArray(); return [pscustomobject]$result
    }
    if (-not $Approved) { throw 'NX11-006: real application requires -Approved (per-task consent)' }
    Assert-Nx11JournalReady -JournalRoot $JournalRoot

    # Mandatory per-task XML backup BEFORE any state change (r1 / NX16-006 pattern).
    $dest = Resolve-Nx11BackupDestination -DestinationPath $BackupDestination
    $xmlOk = $false
    $exportFn = Get-Command -Name 'Export-NxTaskState' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $exportFn) {
        try {
            $exp = Export-NxTaskState -Tasks @([pscustomobject]@{ TaskPath = $TaskPath; TaskName = $TaskName }) -DestinationPath $dest
            $rec = @($exp.entries)[0]
            if ($null -ne $rec -and $rec.result -eq 'Exported') { $xmlOk = $true; $result.xmlFile = $rec.file }
        } catch { $xmlOk = $false }
    }
    if (-not $xmlOk) {
        # Local fallback: Export-ScheduledTask XML directly.
        try {
            $xml = Export-ScheduledTask -TaskPath ([System.Management.Automation.WildcardPattern]::Escape($TaskPath)) -TaskName ([System.Management.Automation.WildcardPattern]::Escape($TaskName)) -ErrorAction Stop
            if ($null -ne $xml -and ([string]$xml).TrimStart().StartsWith('<?xml')) {
                $file = Get-Nx11NonOverwritePath -Path (Join-Path $dest ('task-' + (Get-Nx11SafeFileName ($TaskPath + $TaskName)) + '.xml'))
                Set-Content -LiteralPath $file -Value $xml -Encoding Unicode
                $xmlOk = $true; $result.xmlFile = $file
            }
        } catch { }
    }
    $seq++; $steps.Add((New-Nx11Step $seq 'xml-backup' $(if ($xmlOk) { 'Complete' } else { 'Failed' }) $(if ($xmlOk) { $result.xmlFile } else { 'per-task XML export failed - refusing to change the task' })))
    if (-not $xmlOk) {
        $result.outcome = 'Failed'; $result.steps = $steps.ToArray(); return [pscustomobject]$result
    }

    $original = [pscustomobject][ordered]@{ targetType = 'task'; taskPath = $TaskPath; taskName = $TaskName; state = $currentState; xmlFile = $result.xmlFile }
    $modifiedState = 'Enabled'
    if ($Mode -eq 'Disable') { $modifiedState = 'Disabled' }
    $modified = [pscustomobject][ordered]@{ targetType = 'task'; taskPath = $TaskPath; taskName = $TaskName; state = $modifiedState }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX11-006' -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    $result.journalSeq = $jr.seq
    $enabled = ($Mode -eq 'Enable')
    $set = Set-Nx11TaskEnabled -TaskPath $TaskPath -TaskName $TaskName -Enabled $enabled
    $result.mechanism = $set.mechanism
    $result.attempts = $set.attempts
    $verified = ($set.success -and (($Mode -eq 'Disable' -and $set.state -eq 'Disabled') -or ($Mode -eq 'Enable' -and $set.state -ne 'Disabled')))
    if ($verified) {
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX11-006' -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles $Profiles
        $seq++; $steps.Add((New-Nx11Step $seq 'apply' 'Verified' "mechanism=$($set.mechanism) state=$($set.state)"))
        $result.outcome = 'Applied'; $result.steps = $steps.ToArray(); return [pscustomobject]$result
    }
    # Safe stop: best-effort return to the exact prior state, then journal the failure.
    $revertEnabled = ($currentState -ne 'Disabled')
    if ($revertEnabled -ne $enabled) { $null = Set-Nx11TaskEnabled -TaskPath $TaskPath -TaskName $TaskName -Enabled $revertEnabled }
    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX11-006' -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo ("3-fallback change failed; last state '$($set.state)'") -Profiles $Profiles
    $seq++; $steps.Add((New-Nx11Step $seq 'verify' 'Failed' "3-fallback change failed; last state '$($set.state)'"))
    $result.outcome = 'Failed'; $result.steps = $steps.ToArray(); return [pscustomobject]$result
}

# ============================================================================
# NX11-007 - Resource-heavy process report (read-only)
# ============================================================================

function Get-NxResourceHeavyProcessReport {
    <# NX11-007 - read-only evidence for an owner decision. No performance claims:
       CPU values are cumulative process CPU time, memory is current working set. #>
    [CmdletBinding()]
    param([int]$Top = 15, [int]$SampleSeconds = 0)
    $procs = @()
    $unc = @()
    try {
        $procs = @(Get-Process -ErrorAction Stop)
    } catch { $unc += 'Get-Process failed: ' + [string]$_.Exception.Message }
    $rows = @()
    $cpuDelta = @{}
    if ($SampleSeconds -gt 0 -and $procs.Count -gt 0) {
        $before = @{}
        foreach ($p in $procs) { try { $before[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds } catch { } }
        Start-Sleep -Seconds $SampleSeconds
        $logical = [Environment]::ProcessorCount
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            if (-not $before.ContainsKey($p.Id)) { continue }
            try {
                $delta = $p.TotalProcessorTime.TotalMilliseconds - $before[$p.Id]
                if ($delta -ge 0) { $cpuDelta[$p.Id] = [math]::Round(($delta / ($SampleSeconds * 1000 * $logical)) * 100, 1) }
            } catch { }
        }
    }
    foreach ($p in $procs) {
        $ws = 0; $cpu = 0; $start = $null; $company = $null; $path = $null
        try { $ws = [math]::Round($p.WorkingSet64 / 1MB, 1) } catch { }
        try { $cpu = [math]::Round($p.TotalProcessorTime.TotalSeconds, 1) } catch { }
        try { $start = $p.StartTime } catch { }
        try { $company = [string]$p.Company } catch { }
        try { $path = [string]$p.Path } catch { }
        $row = [pscustomobject][ordered]@{
            id = $p.Id; name = $p.ProcessName; workingSetMB = $ws; cpuSecondsCumulative = $cpu
            cpuPercentSampled = $(if ($cpuDelta.ContainsKey($p.Id)) { $cpuDelta[$p.Id] } else { $null })
            startTime = $start; company = $company; path = $path
        }
        $rows += $row
    }
    $byMem = @($rows | Sort-Object workingSetMB -Descending | Select-Object -First $Top)
    $byCpu = @($rows | Sort-Object cpuSecondsCumulative -Descending | Select-Object -First $Top)
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-007'; readOnly = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        sampleSeconds = $SampleSeconds; processCount = $rows.Count
        topByWorkingSet = $byMem; topByCpuTime = $byCpu
        note = 'CPU time is cumulative since each process started; sampled percent is an interval observation. Reports describe observed state only - no performance claim is made.'
        uncertainty = $unc
    }
}

# ============================================================================
# Service configuration engine (NX11-008/009/010/012/013/014/016/017/018)
# ============================================================================

function Get-NxServiceDependencyReport {
    <# NX11-019 - read-only service dependency inspection engine. With -ServiceName it
       reports one service; without it, a machine-wide dependency summary. This is the
       gate every NX11 service change uses before mutation. #>
    [CmdletBinding()]
    param([string]$ServiceName)
    if ([string]::IsNullOrWhiteSpace($ServiceName)) {
        $rows = @()
        $unc = @()
        try {
            foreach ($s in @(Get-Service -ErrorAction Stop | Sort-Object Name)) {
                $dependents = @()
                try { $dependents = @($s.DependentServices) } catch { }
                if ($dependents.Count -eq 0) { continue }
                $rec = Get-Nx11ServiceRecord -Name $s.Name
                $rows += [pscustomobject][ordered]@{
                    name = $s.Name; status = [string]$s.Status; startType = $rec.startType
                    dependentCount = $dependents.Count
                    runningDependentCount = @($dependents | Where-Object { $_.Status -eq 'Running' }).Count
                    protectedDependents = @($dependents | Where-Object { Test-Nx11NeverTouchService -Name $_.Name } | ForEach-Object { $_.Name })
                }
            }
        } catch { $unc += 'machine-wide service enumeration failed: ' + [string]$_.Exception.Message }
        return [pscustomobject][ordered]@{
            tweakId = 'NX11-019'; readOnly = $true; mode = 'summary'; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            servicesWithDependents = $rows; count = $rows.Count
            note = 'Read-only. Individual changes must call this function with -ServiceName first (Set-Nx*ServiceConfig does so internally).'
            uncertainty = $unc
        }
    }

    $record = Get-Nx11ServiceRecord -Name $ServiceName
    $required = @(); $dependent = @(); $runningDependent = @(); $protectedDependent = @()
    $unc = @()
    if ($ServiceName -notmatch '^[A-Za-z0-9._\-]{1,256}$') {
        return [pscustomobject][ordered]@{ tweakId = 'NX11-019'; readOnly = $true; service = $ServiceName; verdict = 'InvalidName'; requiredServices = @(); dependentServices = @(); uncertainty = @('service name is malformed') }
    }
    $svc = $null
    try { $svc = Get-Service -Name ([System.Management.Automation.WildcardPattern]::Escape($ServiceName)) -ErrorAction Stop } catch { $svc = $null }
    if ($null -ne $svc) {
        try {
            foreach ($r in @($svc.RequiredServices)) { $required += [pscustomobject]@{ name = $r.Name; status = [string]$r.Status } }
        } catch { $unc += 'required-services read failed: ' + [string]$_.Exception.Message }
        try {
            foreach ($d in @($svc.DependentServices)) {
                $name = $d.Name; $status = $null
                try { $status = [string]$d.Status } catch { }
                $dependent += [pscustomobject]@{ name = $name; status = $status; neverTouch = (Test-Nx11NeverTouchService -Name $name) }
                if ($status -eq 'Running') { $runningDependent += $name }
                if (Test-Nx11NeverTouchService -Name $name) { $protectedDependent += $name }
            }
        } catch { $unc += 'dependent-services read failed: ' + [string]$_.Exception.Message }
    }
    $binary = $null
    try {
        $wmi = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $ServiceName.Replace("'", "''") + "'") -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $wmi) { $binary = [string]$wmi.PathName }
    } catch { $unc += 'Win32_Service path read failed: ' + [string]$_.Exception.Message }

    $verdict = 'SafeForStartupChange'
    if (-not $record.present) { $verdict = 'ServiceMissing' }
    elseif ($protectedDependent.Count -gt 0) { $verdict = 'RefuseProtectedDependents' }
    elseif ($runningDependent.Count -gt 0) { $verdict = 'RequiresDependentAcknowledgement' }

    return [pscustomobject][ordered]@{
        tweakId = 'NX11-019'; readOnly = $true; mode = 'detail'; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        service = $ServiceName
        present = $record.present
        status = $record.status
        startType = $record.startType
        startValue = $record.startValue
        delayedAutostart = $record.delayedAutostart
        binaryPath = $binary
        neverTouch = (Test-Nx11NeverTouchService -Name $ServiceName)
        requiredServices = $required
        dependentServices = $dependent
        runningDependents = $runningDependent
        protectedDependents = $protectedDependent
        verdict = $verdict
        note = 'Read-only gate. Disabling a service with running dependents needs explicit acknowledgement; protected dependents are a hard refusal.'
        uncertainty = $unc
    }
}

function Set-Nx11DelayedAutostart {
    # Exact restoration aid: PS 5.1 Set-Service cannot express AutomaticDelayedStart,
    # so delayed-autostart originals are restored through the documented sc.exe syntax.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Delayed)
    if ($Name -notmatch '^[A-Za-z0-9._\-]{1,256}$') { return $false }
    $startArg = 'auto'
    if ($Delayed) { $startArg = 'delayed-auto' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & (Join-Path $env:SystemRoot 'System32\sc.exe') config $Name start= $startArg | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
    finally { $ErrorActionPreference = $prev }
}

function Restore-Nx11ServiceState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Original)
    $restored = $false; $started = $false; $detail = @()
    if ([string]::IsNullOrWhiteSpace([string]$Original.startupType) -or [string]$Original.startupType -eq 'Unknown') {
        return [pscustomobject]@{ restored = $false; started = $false; detail = 'original startup type is unknown - refusing to guess' }
    }
    try {
        Set-Service -Name $Name -StartupType ([string]$Original.startupType) -ErrorAction Stop
        $restored = $true
        $detail += ('startup type restored to ' + [string]$Original.startupType)
    } catch { $detail += ('startup restore failed: ' + [string]$_.Exception.Message) }
    if ($restored -and [string]$Original.startupType -eq 'Automatic' -and $Original.delayedAutostart -eq 1) {
        $delayOk = Set-Nx11DelayedAutostart -Name $Name -Delayed $true
        if ($delayOk) { $detail += 'delayed-autostart flag restored' }
        else { $detail += 'delayed-autostart flag restore failed' }
    }
    if ($restored -and [string]$Original.status -eq 'Running') {
        try {
            $live = Get-Service -Name ([System.Management.Automation.WildcardPattern]::Escape($Name)) -ErrorAction Stop
            if ([string]$live.Status -ne 'Running') {
                Start-Service -Name $Name -ErrorAction Stop
                $started = $true
                $detail += 'service started to match original running state'
            }
        } catch { $detail += ('start failed: ' + [string]$_.Exception.Message) }
    }
    return [pscustomobject]@{ restored = $restored; started = $started; detail = ($detail -join '; ') }
}

function Set-Nx11ServiceConfig {
    <# Shared NX11 service change engine:
       never-touch guard -> dependency report gate -> journal exact startup/status
       -> Set-Service (+ optional stop) -> verify -> journal. Safe-stop restores the
       exact original startup type and running state on failure. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Automatic','Manual','Disabled')][string]$StartupType,
        [Parameter(Mandatory)][string]$TweakId,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$StopService,
        [switch]$AcknowledgeDependents,
        [switch]$Plan
    )
    $steps = New-Object System.Collections.Generic.List[object]
    $seq = 0
    $out = [ordered]@{
        tweakId = $TweakId; service = $Name; targetStartupType = $StartupType; plan = [bool]$Plan.IsPresent
        outcome = 'Unknown'; original = $null; modified = $null; dependencyReport = $null
        journalSeq = $null; steps = $null; stopRequested = [bool]$StopService.IsPresent
    }
    if (Test-Nx11NeverTouchService -Name $Name) {
        $out.outcome = 'Refused'
        $out.steps = @(New-Nx11Step 1 'never-touch' 'Failed' "service '$Name' is on the never-touch list - no action permitted")
        return [pscustomobject]$out
    }
    $rec = Get-Nx11ServiceRecord -Name $Name
    if (-not $rec.present) {
        $out.outcome = 'Skipped'
        $out.steps = @(New-Nx11Step 1 'locate-service' 'Skipped' "service '$Name' not present on this machine")
        return [pscustomobject]$out
    }
    $dep = Get-NxServiceDependencyReport -ServiceName $Name
    $out.dependencyReport = $dep
    $seq++; $steps.Add((New-Nx11Step $seq 'dependency-report' 'Complete' "verdict=$($dep.verdict) runningDependents=$(@($dep.runningDependents).Count) protectedDependents=$(@($dep.protectedDependents).Count)"))
    if ($dep.verdict -eq 'RefuseProtectedDependents') {
        $out.outcome = 'Refused'
        $seq++; $steps.Add((New-Nx11Step $seq 'dependency-gate' 'Failed' ('protected dependent services: ' + (@($dep.protectedDependents) -join ', '))))
        $out.steps = $steps.ToArray(); return [pscustomobject]$out
    }
    if ($StartupType -eq 'Disabled' -and @($dep.runningDependents).Count -gt 0 -and -not $AcknowledgeDependents) {
        $out.outcome = 'Skipped'
        $seq++; $steps.Add((New-Nx11Step $seq 'dependency-gate' 'Skipped' ('running dependents need acknowledgement: ' + (@($dep.runningDependents) -join ', '))))
        $out.steps = $steps.ToArray(); return [pscustomobject]$out
    }
    if ($rec.startType -eq 'UnsupportedValue' -or $rec.startType -eq 'Unknown' -or $null -eq $rec.startValue) {
        $out.outcome = 'Refused'
        $seq++; $steps.Add((New-Nx11Step $seq 'capture-original' 'Failed' "startup type '$($rec.startType)' / Start value '$($rec.startValue)' - exact original state cannot be recorded, so no change is permitted"))
        $out.steps = $steps.ToArray(); return [pscustomobject]$out
    }

    $already = ($rec.startType -eq $StartupType)
    if ($StopService -and $StartupType -eq 'Disabled' -and [string]$rec.status -eq 'Running') { $already = $false }
    if ($already) {
        if (-not $Plan) {
            $skipOrg = [pscustomobject][ordered]@{ targetType = 'service'; name = $Name; startupType = $rec.startType; startValue = $rec.startValue; status = $rec.status }
            $skipMod = [pscustomobject][ordered]@{ targetType = 'service'; name = $Name; startupType = $StartupType; stopRequested = [bool]$StopService.IsPresent; action = 'AlreadyAtState' }
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $skipOrg -Modified $skipMod -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        }
        $out.outcome = 'AlreadyAtState'
        $seq++; $steps.Add((New-Nx11Step $seq 'apply' 'Complete' 'startup type and running state already match (idempotent)'))
        $out.steps = $steps.ToArray(); return [pscustomobject]$out
    }

    $original = [pscustomobject][ordered]@{ targetType = 'service'; name = $Name; startupType = $rec.startType; startValue = $rec.startValue; status = $rec.status; delayedAutostart = $rec.delayedAutostart }
    $modified = [pscustomobject][ordered]@{ targetType = 'service'; name = $Name; startupType = $StartupType; stopRequested = [bool]$StopService.IsPresent }
    $out.original = $original; $out.modified = $modified

    if ($Plan) {
        $out.outcome = 'Planned'
        $seq++; $steps.Add((New-Nx11Step $seq 'apply' 'Planned' "would set startup type $StartupType" + $(if ($StopService) { ' and stop the running service' } else { '' })))
        $out.steps = $steps.ToArray(); return [pscustomobject]$out
    }
    if (-not $Approved) { throw "tweak ${TweakId}: real application requires -Approved" }
    Assert-Nx11JournalReady -JournalRoot $JournalRoot
    if (-not (Test-Nx11Elevated)) {
        try { $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo 'administrator elevation is required' -Profiles $Profiles } catch { }
        $out.outcome = 'Failed'
        $seq++; $steps.Add((New-Nx11Step $seq 'elevation' 'Failed' 'administrator elevation is required to change a service startup type'))
        $out.steps = $steps.ToArray(); return [pscustomobject]$out
    }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    $out.journalSeq = $jr.seq
    try {
        if ($rec.startType -ne $StartupType) {
            Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        }
        if ($StopService -and $StartupType -eq 'Disabled') {
            $live = Get-Service -Name ([System.Management.Automation.WildcardPattern]::Escape($Name)) -ErrorAction Stop
            if ([string]$live.Status -eq 'Running') { Stop-Service -Name $Name -ErrorAction Stop }
        }
        $after = Get-Nx11ServiceRecord -Name $Name
        $startOk = ($after.startType -eq $StartupType)
        $stopOk = $true
        if ($StopService -and $StartupType -eq 'Disabled' -and $after.status -eq 'Running') { $stopOk = $false }
        if ($startOk -and $stopOk) {
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles $Profiles
            $seq++; $steps.Add((New-Nx11Step $seq 'verify' 'Verified' "startupType=$($after.startType) status=$($after.status)"))
            $out.outcome = 'Applied'; $out.steps = $steps.ToArray(); return [pscustomobject]$out
        }
        $reason = "verification failed: startupType=$($after.startType) status=$($after.status) (wanted $StartupType$(if ($StopService) { ', stopped' }))"
        $rest = Restore-Nx11ServiceState -Name $Name -Original $original
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo ($reason + '; ' + $rest.detail) -Profiles $Profiles
        $seq++; $steps.Add((New-Nx11Step $seq 'verify' 'Failed' ($reason + '; ' + $rest.detail)))
        $out.outcome = 'Failed'; $out.steps = $steps.ToArray(); return [pscustomobject]$out
    } catch {
        $err = [string]$_.Exception.Message
        $rest = Restore-Nx11ServiceState -Name $Name -Original $original
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ($err + '; ' + $rest.detail) -Profiles $Profiles
        $seq++; $steps.Add((New-Nx11Step $seq 'apply' 'Failed' ($err + '; ' + $rest.detail)))
        $out.outcome = 'Failed'; $out.steps = $steps.ToArray(); return [pscustomobject]$out
    }
}

# ============================================================================
# NX11-008 - Windows Search service configuration
# ============================================================================

function Set-NxSearchServiceConfig {
    <# NX11-008 - WSearch startup type. Scope ownership of WHAT is indexed stays with
       NX01-009; this function only configures the service. SSD gate for Disabled. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Automatic','Manual','Disabled')][string]$StartupType = 'Manual',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$StopService,
        [switch]$AcknowledgeDependents,
        [switch]$AcknowledgeMedia,
        [switch]$Plan
    )
    $disk = Get-Nx11SystemDiskMediaType
    $gate = $null
    if ($StartupType -eq 'Disabled' -and $disk.mediaType -eq 'HDD' -and -not $AcknowledgeMedia) {
        $gate = 'HDD boot volume detected: reference guidance (r5) scopes Windows Search disabling to mechanical drives, but acknowledgement is still required.'
    }
    if ($StartupType -eq 'Disabled' -and $disk.mediaType -eq 'SSD' -and -not $AcknowledgeMedia) {
        $gate = 'SSD boot volume detected: indexing is usually wanted on SSDs; disable only with explicit acknowledgement (scope is NX01-009).'
    }
    $w = $null
    if ($null -eq $gate) {
        $w = Set-Nx11ServiceConfig -Name 'WSearch' -StartupType $StartupType -TweakId 'NX11-008' -JournalRoot $JournalRoot -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -StopService:$StopService -AcknowledgeDependents:$AcknowledgeDependents -Plan:$Plan
    }
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-008'; service = 'WSearch'; targetStartupType = $StartupType; plan = [bool]$Plan.IsPresent
        systemDisk = $disk; systemDiskGate = $gate
        outcome = $(if ($null -ne $gate) { 'Skipped' } else { $w.outcome })
        result = $w
        notes = @(
            'Indexing SCOPE (what gets indexed) is owned by NX01-009; this entry only changes service startup type.',
            'Manual keeps on-demand search/indexing available without automatic startup.',
            'Disabling stops automatic indexing; existing index files remain and search falls back to non-indexed behavior.'
        )
    }
}

# ============================================================================
# NX11-009 - SysMain service configuration
# ============================================================================

function Set-NxSysMainConfig {
    <# NX11-009 - SysMain startup type with documented detection gates:
       disabling is refused on <16 GB RAM unless acknowledged (hard-fault risk noted by
       UltraOS research, r4) and on HDD boot volumes unless acknowledged. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Automatic','Manual','Disabled')][string]$StartupType = 'Disabled',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$StopService,
        [switch]$AcknowledgeDependents,
        [switch]$AcknowledgeLowMemory,
        [switch]$AcknowledgeHdd,
        [switch]$Plan
    )
    $ramGb = Get-Nx11RamGb
    $disk = Get-Nx11SystemDiskMediaType
    $gates = New-Object System.Collections.Generic.List[string]
    if ($StartupType -eq 'Disabled') {
        if ($null -ne $ramGb -and $ramGb -lt 16 -and -not $AcknowledgeLowMemory) {
            $gates.Add("RAM is $ramGb GB (<16 GB): disabling SysMain can increase hard faults; acknowledgement required (-AcknowledgeLowMemory).")
        }
        if ($disk.mediaType -eq 'HDD' -and -not $AcknowledgeHdd) {
            $gates.Add('HDD boot volume detected: SysMain prefetch behavior is more valuable on rotational media; acknowledgement required (-AcknowledgeHdd).')
        }
    }
    $w = $null
    if ($gates.Count -eq 0) {
        $w = Set-Nx11ServiceConfig -Name 'SysMain' -StartupType $StartupType -TweakId 'NX11-009' -JournalRoot $JournalRoot -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -StopService:$StopService -AcknowledgeDependents:$AcknowledgeDependents -Plan:$Plan
    }
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-009'; service = 'SysMain'; targetStartupType = $StartupType; plan = [bool]$Plan.IsPresent
        detected = [pscustomobject]@{ ramGb = $ramGb; systemDisk = $disk }
        gates = $gates.ToArray()
        outcome = $(if ($gates.Count -gt 0) { 'Skipped' } else { $w.outcome })
        result = $w
        notes = @(
            'Research (r4) records unconditional SysMain disabling increasing hard faults on 8-16 GB systems; this entry is conditional, never a default.',
            'Automatic is the restore path; Manual is offered for owner preference.'
        )
    }
}

# ============================================================================
# NX11-010 - Xbox services configuration
# ============================================================================

function Set-NxXboxServicesConfig {
    <# NX11-010 - XboxGipSvc + XboxNetApiSvc only. GamingServices/GamingServicesNet are
       report-only (Game Pass). Dependency report runs first. Game Pass/accessory gates. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Automatic','Manual','Disabled')][string]$StartupType = 'Manual',
        [string[]]$Services = @('XboxGipSvc','XboxNetApiSvc'),
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$StopService,
        [switch]$AcknowledgeDependents,
        [switch]$AcknowledgeGamePass,
        [switch]$AcknowledgePeripherals,
        [switch]$Plan
    )
    $allowed = @('XboxGipSvc','XboxNetApiSvc')
    $unknown = @($Services | Where-Object { $allowed -notcontains $_ })
    if ($unknown.Count -gt 0) {
        return [pscustomobject][ordered]@{
            tweakId = 'NX11-010'; outcome = 'Refused'
            reason = ('only XboxGipSvc and XboxNetApiSvc are configurable here; refused: ' + ($unknown -join ', ') + '. GamingServices/GamingServicesNet are Game Pass dependencies and are report-only.')
        }
    }
    $xbox = Get-Nx11XboxEvidence
    $depReports = @()
    foreach ($s in $Services) { $depReports += (Get-NxServiceDependencyReport -ServiceName $s) }
    $gates = New-Object System.Collections.Generic.List[string]
    $gamePassPresent = $false
    foreach ($p in @($xbox.packages)) { if ($p.present -eq $true) { $gamePassPresent = $true } }
    if ($xbox.gamingServicesKeyPresent) { $gamePassPresent = $true }
    if ($StartupType -eq 'Disabled' -and $gamePassPresent -and -not $AcknowledgeGamePass) {
        $gates.Add('Xbox/Gaming Services packages detected: Game Pass owners must not disable Xbox services; acknowledgement required (-AcknowledgeGamePass).')
    }
    if ($StartupType -eq 'Disabled' -and @($xbox.xboxDevices).Count -gt 0 -and -not $AcknowledgePeripherals) {
        $gates.Add('Xbox input devices detected: accessory handling depends on XboxGipSvc; acknowledgement required (-AcknowledgePeripherals).')
    }
    $results = @()
    if ($gates.Count -eq 0) {
        foreach ($s in $Services) {
            $results += (Set-Nx11ServiceConfig -Name $s -StartupType $StartupType -TweakId 'NX11-010' -JournalRoot $JournalRoot -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -StopService:$StopService -AcknowledgeDependents:$AcknowledgeDependents -Plan:$Plan)
        }
    }
    $failed = @($results | Where-Object { $_.outcome -eq 'Failed' }).Count
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-010'; targetStartupType = $StartupType; services = $Services; plan = [bool]$Plan.IsPresent
        detection = $xbox; dependencyReports = $depReports; gates = $gates.ToArray()
        outcome = $(if ($gates.Count -gt 0) { 'Skipped' } elseif ($failed -gt 0) { 'Failed' } elseif (@($results | Where-Object { $_.outcome -eq 'Applied' }).Count -gt 0) { 'Applied' } else { 'AlreadyAtState' })
        results = $results
        notes = @(
            'GamingServices and GamingServicesNet are never touched: Game Pass install/update/play depends on them.',
            'CONFLICT NX12-005: Xbox app removal and Xbox service management must be resolved together; Game Pass users are excluded.',
            'Xbox Game Bar capture has its own per-user BcastDVRUserService_* family - not touched here.'
        )
    }
}

# ============================================================================
# NX11-011 - Print Spooler (report-only by boundary)
# ============================================================================

function Get-NxPrintSpoolerReport {
    <# NX11-011 - READ-ONLY report + guidance. Spooler is on the validator's never-touch
       list; NEXTRIX has no code path that stops, disables or reconfigures it. #>
    [CmdletBinding()]
    param()
    $record = Get-Nx11ServiceRecord -Name 'Spooler'
    $printers = @(); $drivers = 0; $unc = @()
    $getPrinter = Get-Command -Name 'Get-Printer' -ErrorAction SilentlyContinue
    if ($null -ne $getPrinter) {
        try {
            $printers = @(Get-Printer -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ name = [string]$_.Name; driverName = [string]$_.DriverName; portName = [string]$_.PortName; printerStatus = [string]$_.PrinterStatus }
            })
        } catch { $unc += 'Get-Printer failed: ' + [string]$_.Exception.Message }
        try { $drivers = @(Get-PrinterDriver -ErrorAction Stop).Count } catch { $unc += 'Get-PrinterDriver failed: ' + [string]$_.Exception.Message }
    } else { $unc += 'PrintManagement module unavailable - printer enumeration skipped' }

    return [pscustomobject][ordered]@{
        tweakId = 'NX11-011'; readOnly = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        service = $record
        neverTouch = $true
        mutationAvailable = $false
        printerCount = $printers.Count
        printerDriverCount = $drivers
        printers = $printers
        guidance = @(
            'Print Spooler (Spooler) is on the schema never-touch list: NEXTRIX never stops, disables or reconfigures it, even when no printers are detected.',
            'Removing printing entirely is a Windows optional-feature decision the owner makes in Settings, outside NEXTRIX automation.',
            'If the spooler is stopped or disabled for another reason, printing and many print-dependent apps fail; restore it with the Windows Services console.'
        )
        boundaryNote = 'Catalogue NX11-011 is implemented as a report-only entry (status Defined) by workstream boundary; a disable path is intentionally absent and the validator would reject it.'
        uncertainty = $unc
    }
}

# ============================================================================
# NX11-012 - Bluetooth services configuration
# ============================================================================

function Set-NxBluetoothServiceConfig {
    <# NX11-012 - bthserv + BthAvctpSvc, detection-gated on present Bluetooth devices.
       Ordering: disable the AVCTP dependent first; enable the radio service first. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Automatic','Manual','Disabled')][string]$StartupType = 'Disabled',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$StopService,
        [switch]$AcknowledgeDependents,
        [switch]$AcknowledgePeripherals,
        [switch]$Plan
    )
    $bt = Get-Nx11BluetoothDevices
    $gate = $null
    if ($StartupType -eq 'Disabled' -and @($bt.devices).Count -gt 0 -and -not $AcknowledgePeripherals) {
        $gate = ('Bluetooth hardware/peripherals detected (' + @($bt.devices).Count + '): disabling the Bluetooth services would break them; acknowledgement required (-AcknowledgePeripherals).')
    }
    $services = @('BthAvctpSvc','bthserv')
    if ($StartupType -ne 'Disabled') { $services = @('bthserv','BthAvctpSvc') }
    $results = @()
    if ($null -eq $gate) {
        foreach ($s in $services) {
            $results += (Set-Nx11ServiceConfig -Name $s -StartupType $StartupType -TweakId 'NX11-012' -JournalRoot $JournalRoot -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -StopService:$StopService -AcknowledgeDependents:$AcknowledgeDependents -Plan:$Plan)
        }
    }
    $failed = @($results | Where-Object { $_.outcome -eq 'Failed' }).Count
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-012'; targetStartupType = $StartupType; services = $services; plan = [bool]$Plan.IsPresent
        detection = $bt; gate = $gate
        outcome = $(if ($null -ne $gate) { 'Skipped' } elseif ($failed -gt 0) { 'Failed' } elseif (@($results | Where-Object { $_.outcome -eq 'Applied' }).Count -gt 0) { 'Applied' } else { 'AlreadyAtState' })
        results = $results
        notes = @(
            'XREF NX08-006: Bluetooth peripheral inspection and power policy are owned by NX08; this entry only configures the service startup type.',
            'Disabling Bluetooth services is meaningful only when no Bluetooth radio/peripheral is in use.'
        )
    }
}

# ============================================================================
# NX11-013 - Fax service configuration
# ============================================================================

function Get-Nx11FaxEvidence {
    $out = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($p in @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.Name -like '*Fax*' })) {
            $out.Add([pscustomobject]@{ kind = 'pnp'; name = [string]$p.Name; status = [string]$p.Status })
        }
    } catch { }
    $getPrinter = Get-Command -Name 'Get-Printer' -ErrorAction SilentlyContinue
    if ($null -ne $getPrinter) {
        try {
            foreach ($p in @(Get-Printer -ErrorAction Stop | Where-Object { $_.Name -like '*Fax*' -or $_.DriverName -like '*Fax*' })) {
                $out.Add([pscustomobject]@{ kind = 'printer'; name = [string]$p.Name; driver = [string]$p.DriverName })
            }
        } catch { }
    }
    return $out.ToArray()
}

function Set-NxFaxServiceConfig {
    <# NX11-013 - legacy Fax service, detection-gated on fax-capable hardware/printers. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Automatic','Manual','Disabled')][string]$StartupType = 'Disabled',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$StopService,
        [switch]$AcknowledgeDependents,
        [switch]$AcknowledgeFaxHardware,
        [switch]$Plan
    )
    $evidence = Get-Nx11FaxEvidence
    $gate = $null
    if ($StartupType -eq 'Disabled' -and @($evidence).Count -gt 0 -and -not $AcknowledgeFaxHardware) {
        $gate = 'Fax-capable hardware/printers detected: acknowledgement required before disabling the Fax service (-AcknowledgeFaxHardware).'
    }
    $w = $null
    if ($null -eq $gate) {
        $w = Set-Nx11ServiceConfig -Name 'Fax' -StartupType $StartupType -TweakId 'NX11-013' -JournalRoot $JournalRoot -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -StopService:$StopService -AcknowledgeDependents:$AcknowledgeDependents -Plan:$Plan
    }
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-013'; service = 'Fax'; targetStartupType = $StartupType; plan = [bool]$Plan.IsPresent
        detection = $evidence; gate = $gate
        outcome = $(if ($null -ne $gate) { 'Skipped' } else { $w.outcome })
        result = $w
        notes = @('Fax is a legacy Windows feature; disabling does not remove the optional component or any documents.')
    }
}

# ============================================================================
# NX11-014 - Remote Registry (security-positive default-off)
# ============================================================================

function Set-NxRemoteRegistryConfig {
    <# NX11-014 - RemoteRegistry startup type. Disabled is the security-positive state;
       re-enabling to Manual requires an explicit security-risk acknowledgement. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Manual','Disabled')][string]$StartupType = 'Disabled',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$StopService,
        [switch]$AcknowledgeDependents,
        [switch]$AcknowledgeSecurityRisk,
        [switch]$Plan
    )
    if ($StartupType -ne 'Disabled' -and -not $AcknowledgeSecurityRisk) {
        return [pscustomobject][ordered]@{
            tweakId = 'NX11-014'; service = 'RemoteRegistry'; targetStartupType = $StartupType; plan = [bool]$Plan.IsPresent
            outcome = 'Skipped'
            reason = 'Enabling Remote Registry re-exposes a remote surface; explicit -AcknowledgeSecurityRisk is required.'
        }
    }
    $w = Set-Nx11ServiceConfig -Name 'RemoteRegistry' -StartupType $StartupType -TweakId 'NX11-014' -JournalRoot $JournalRoot -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -StopService:$StopService -AcknowledgeDependents:$AcknowledgeDependents -Plan:$Plan
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-014'; service = 'RemoteRegistry'; targetStartupType = $StartupType; plan = [bool]$Plan.IsPresent
        outcome = $w.outcome; result = $w
        notes = @(
            'Disabled is the Microsoft security-guidance state for general-purpose PCs.',
            'Remote registry access is used by some enterprise management tools; disabled state is honest and journal-restorable.'
        )
    }
}

# ============================================================================
# NX11-015 - Windows Error Reporting (documented policy, not service disable)
# ============================================================================

function Set-NxWerReportingConfig {
    <# NX11-015 - documented WER machine policy Disabled=1/0
       (ErrorReporting.admx policy WerDisable_2; WerSvc is deliberately NOT disabled). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Disable','Enable')][string]$Mode = 'Disable',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$Plan
    )
    $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'
    $value = 1
    if ($Mode -eq 'Enable') { $value = 0 }
    $w = Invoke-Nx11RegistryWrite -TweakId 'NX11-015' -TweakVersion $TweakVersion -Approval $Approval -JournalRoot $JournalRoot -Path $path -Name 'Disabled' -Kind DWord -Value $value -Profiles $Profiles -Approved:$Approved -Plan:$Plan
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-015'; mode = $Mode; policyPath = $path; valueName = 'Disabled'; value = $value
        outcome = $(if ($Plan) { 'Planned' } elseif ($w.verified) { $(if ($w.changed) { 'Applied' } else { 'AlreadyAtState' }) } else { 'Failed' })
        verified = $w.verified; journalSeq = $w.journalSeq; detail = $w.reason
        notes = @(
            'Documented machine policy (local ErrorReporting.admx: policy WerDisable_2, value Disabled).',
            'WerSvc is NOT disabled: the policy is the documented, fully reversible switch preferred over a service change.',
            'Diagnostics trade-off: crash reports and WER queues stop being useful for troubleshooting while disabled.'
        )
    }
}

# ============================================================================
# NX11-016 - Maps-related services
# ============================================================================

function Set-NxMapsServiceConfig {
    <# NX11-016 - MapsBroker startup type, gated on offline-map evidence. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Automatic','Manual','Disabled')][string]$StartupType = 'Manual',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$StopService,
        [switch]$AcknowledgeDependents,
        [switch]$AcknowledgeOfflineMaps,
        [switch]$Plan
    )
    $evidence = Get-Nx11OfflineMapEvidence
    $gate = $null
    if ($StartupType -eq 'Disabled' -and @($evidence).Count -gt 0 -and -not $AcknowledgeOfflineMaps) {
        $gate = 'Offline map data/app detected: acknowledgement required before disabling MapsBroker (-AcknowledgeOfflineMaps).'
    }
    $w = $null
    if ($null -eq $gate) {
        $w = Set-Nx11ServiceConfig -Name 'MapsBroker' -StartupType $StartupType -TweakId 'NX11-016' -JournalRoot $JournalRoot -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -StopService:$StopService -AcknowledgeDependents:$AcknowledgeDependents -Plan:$Plan
    }
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-016'; service = 'MapsBroker'; targetStartupType = $StartupType; plan = [bool]$Plan.IsPresent
        detection = $evidence; gate = $gate
        outcome = $(if ($null -ne $gate) { 'Skipped' } else { $w.outcome })
        result = $w
        notes = @(
            'MapsBroker is the Downloaded Maps Manager used for offline maps; Manual keeps on-demand use possible.',
            'Installed offline maps are evidence only; this entry never deletes map data or the Maps app.'
        )
    }
}

# ============================================================================
# NX11-017 - DiagTrack
# ============================================================================

function Set-NxDiagTrackConfig {
    <# NX11-017 - DiagTrack startup type. NX13 owns telemetry policy; NEXTRIX never
       blocks firewall rules (WinUtil pattern rejected) and never claims privacy. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Automatic','Manual','Disabled')][string]$StartupType = 'Disabled',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$StopService,
        [switch]$AcknowledgeDependents,
        [switch]$Plan
    )
    $w = Set-Nx11ServiceConfig -Name 'DiagTrack' -StartupType $StartupType -TweakId 'NX11-017' -JournalRoot $JournalRoot -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -StopService:$StopService -AcknowledgeDependents:$AcknowledgeDependents -Plan:$Plan
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-017'; service = 'DiagTrack'; targetStartupType = $StartupType; plan = [bool]$Plan.IsPresent
        outcome = $w.outcome; result = $w
        coordination = @(
            'NX13 owns the telemetry policy set (AllowTelemetry and related policies); NX11-017 only configures the Connected User Experiences and Telemetry service.',
            'Disabling this service is not a privacy guarantee and does not replace NX13 policy decisions.',
            'Documented impact (r5): Xbox achievements and Feedback Hub can be affected; no firewall blocking is written by NEXTRIX.'
        )
    }
}

# ============================================================================
# NX11-018 - Third-party service inventory & selective configuration
# ============================================================================

function Get-Nx11ServiceBinaryPath {
    param([string]$Name)
    try {
        $w = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $Name.Replace("'", "''") + "'") -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $w) { return [string]$w.PathName }
    } catch { }
    return $null
}

function Test-Nx11MicrosoftServicePath {
    [CmdletBinding()]
    param([string]$PathName, [string]$Name)
    if (Test-Nx11NeverTouchService -Name $Name) { return $true }
    # Unknown/empty binary path: cannot prove the service is third-party, so it is
    # treated as protected (excluded from inventory, refused as a change target).
    if ([string]::IsNullOrWhiteSpace($PathName)) { return $true }
    $p = $PathName.Trim()
    if ($p.StartsWith('"')) {
        $end = $p.IndexOf('"', 1)
        if ($end -gt 1) { $p = $p.Substring(1, $end - 1) }
    } else {
        $p = ($p -split ' ')[0]
    }
    try { $p = [Environment]::ExpandEnvironmentVariables($p) } catch { }
    $sys = $env:SystemRoot
    if ($sys -and $p.ToLower().StartsWith($sys.ToLower())) { return $true }
    return $false
}

function Get-NxThirdPartyServiceInventory {
    <# NX11-018 (read half) - non-Microsoft service inventory. Read-only. #>
    [CmdletBinding()]
    param([int]$MaxItems = 400)
    $items = New-Object System.Collections.Generic.List[object]
    $unc = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Sort-Object Name)) {
            $path = [string]$s.PathName
            if (Test-Nx11MicrosoftServicePath -PathName $path -Name ([string]$s.Name)) { continue }
            $items.Add([pscustomobject][ordered]@{
                name = [string]$s.Name
                displayName = [string]$s.DisplayName
                state = [string]$s.State
                startMode = [string]$s.StartMode
                startName = [string]$s.StartName
                pathName = $path
                dependencies = @($s.Dependencies)
                neverTouch = (Test-Nx11NeverTouchService -Name ([string]$s.Name))
            })
            if ($items.Count -ge $MaxItems) { $unc.Add("inventory truncated at $MaxItems items"); break }
        }
    } catch { $unc.Add('Win32_Service enumeration failed: ' + [string]$_.Exception.Message) }
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-018'; readOnly = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        count = $items.Count; services = $items.ToArray()
        note = 'Non-Microsoft services only (binaries outside %SystemRoot%, never-touch names excluded). Configuration requires one named service per call with -ConfirmService.'
        uncertainty = $unc.ToArray()
    }
}

function Set-NxThirdPartyServiceConfig {
    <# NX11-018 (write half) - one explicitly named non-Microsoft service per call. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][ValidateSet('Automatic','Manual','Disabled')][string]$StartupType,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$ConfirmService,
        [switch]$StopService,
        [switch]$AcknowledgeDependents,
        [switch]$Plan
    )
    if (-not $ConfirmService) {
        return [pscustomobject][ordered]@{ tweakId = 'NX11-018'; service = $ServiceName; outcome = 'Refused'; reason = 'per-service consent is mandatory: pass -ConfirmService after reviewing the inventory entry' }
    }
    if (Test-Nx11NeverTouchService -Name $ServiceName) {
        return [pscustomobject][ordered]@{ tweakId = 'NX11-018'; service = $ServiceName; outcome = 'Refused'; reason = 'never-touch service name - no action permitted' }
    }
    $path = Get-Nx11ServiceBinaryPath -Name $ServiceName
    if (Test-Nx11MicrosoftServicePath -PathName $path -Name $ServiceName) {
        return [pscustomobject][ordered]@{ tweakId = 'NX11-018'; service = $ServiceName; outcome = 'Refused'; reason = 'service binary is a Windows component (or path unknown as Microsoft) - use the dedicated NX11 entry for Windows services' }
    }
    $w = Set-Nx11ServiceConfig -Name $ServiceName -StartupType $StartupType -TweakId 'NX11-018' -JournalRoot $JournalRoot -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -StopService:$StopService -AcknowledgeDependents:$AcknowledgeDependents -Plan:$Plan
    return [pscustomobject][ordered]@{
        tweakId = 'NX11-018'; service = $ServiceName; targetStartupType = $StartupType; binaryPath = $path; plan = [bool]$Plan.IsPresent
        outcome = $w.outcome; result = $w
        notes = @(
            'Vendor dependency notes are the owner''s responsibility: consult the vendor before changing a third-party service.',
            'Never a blanket list: exactly one service per call.'
        )
    }
}

# ============================================================================
# NX11 rollback (delegated by Invoke-NxRollback for target types service/task/
# startupApproved; registry targets are restored by the core engine)
# ============================================================================

function Invoke-Nx11Rollback {
    <# NX11 category rollback replay. Integrity-gated, only-if-ours, verified and
       journaled. Restores service startup/status, scheduled-task state and
       StartupApproved parity values in reverse journal order. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId,
        [switch]$AllNx11
    )
    if ([string]::IsNullOrWhiteSpace($TweakId) -and -not $AllNx11) {
        throw 'Invoke-Nx11Rollback: specify -TweakId or -AllNx11 (no implicit full-category rollback)'
    }
    $journal = Read-NxJournal -Path $JournalRoot
    if ($journal.integrityErrors.Count -gt 0) {
        return [pscustomobject]@{ aborted = $true; integrityErrors = $journal.integrityErrors; restored = @(); diverged = @(); failed = @() }
    }
    $candidates = @($journal.entries | Where-Object {
        $_.operation -eq 'apply' -and (@('InProgress','Success') -contains [string]$_.result) -and
        ([string]$_.tweakId).StartsWith('NX11-') -and
        (@('service','task','startupApproved') -contains [string]$_.original.targetType)
    })
    if (-not $AllNx11) { $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId }) }
    [array]::Reverse($candidates)

    $restored = @(); $diverged = @(); $failed = @()
    $seen = @{}
    foreach ($e in $candidates) {
        $tt = [string]$e.original.targetType
        $key = "$tt|$($e.original.name)$($e.original.taskPath)|$($e.original.taskName)|$($e.tweakId)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        try {
            if ($tt -eq 'service') {
                $name = [string]$e.original.name
                $live = Get-Nx11ServiceRecord -Name $name
                $stillOurs = ([string]$live.startType -eq [string]$e.modified.startupType)
                if (-not $stillOurs) {
                    $diverged += [pscustomobject]@{ tweakId = $e.tweakId; target = "service $name"; live = $live.startType; reason = 'startup type no longer equals what NEXTRIX recorded' }
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: service startup type differs' -Profiles @($e.profiles)
                    continue
                }
                $r = Restore-Nx11ServiceState -Name $name -Original $e.original
                $after = Get-Nx11ServiceRecord -Name $name
                $delayOk = $true
                if ([string]$e.original.startupType -eq 'Automatic' -and $e.original.delayedAutostart -eq 1) {
                    $delayOk = ($after.delayedAutostart -eq 1)
                }
                $ok = ($r.restored -and $after.startType -eq [string]$e.original.startupType -and $delayOk)
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $r.detail -Profiles @($e.profiles)
                if ($ok) { $restored += [pscustomobject]@{ tweakId = $e.tweakId; target = "service $name"; action = 'startup type restored'; detail = $r.detail } }
                else { $failed += [pscustomobject]@{ tweakId = $e.tweakId; target = "service $name"; reason = $r.detail } }
            }
            elseif ($tt -eq 'task') {
                $tp = [string]$e.original.taskPath; $tn = [string]$e.original.taskName
                $live = Get-Nx11TaskObject -TaskPath $tp -TaskName $tn
                if ($null -eq $live) {
                    $diverged += [pscustomobject]@{ tweakId = $e.tweakId; target = "task $tp$tn"; reason = 'task no longer exists - left alone' }
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'task missing' -Profiles @($e.profiles)
                    continue
                }
                $stillOurs = $false
                if ([string]$e.modified.state -eq 'Disabled') { $stillOurs = ([string]$live.State -eq 'Disabled') }
                else { $stillOurs = ([string]$live.State -ne 'Disabled') }
                if (-not $stillOurs) {
                    $diverged += [pscustomobject]@{ tweakId = $e.tweakId; target = "task $tp$tn"; live = $live.State; reason = 'task state no longer equals what NEXTRIX recorded' }
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: task state differs' -Profiles @($e.profiles)
                    continue
                }
                $wantEnabled = ([string]$e.original.state -ne 'Disabled')
                $set = Set-Nx11TaskEnabled -TaskPath $tp -TaskName $tn -Enabled $wantEnabled
                $after = Get-Nx11TaskObject -TaskPath $tp -TaskName $tn
                $ok = ($null -ne $after -and ((($wantEnabled) -and ([string]$after.State -ne 'Disabled')) -or ((-not $wantEnabled) -and ([string]$after.State -eq 'Disabled'))))
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles)
                if ($ok) { $restored += [pscustomobject]@{ tweakId = $e.tweakId; target = "task $tp$tn"; action = $(if ($wantEnabled) { 'enabled' } else { 'disabled' }); detail = "mechanism=$($set.mechanism)" } }
                else { $failed += [pscustomobject]@{ tweakId = $e.tweakId; target = "task $tp$tn"; reason = 'task state did not verify after restore' } }
            }
            elseif ($tt -eq 'startupApproved') {
                $path = [string]$e.original.path; $name = [string]$e.original.name
                $live = Capture-NxRegistryValue -Path $path -Name $name
                $stillOurs = ($live.existed -and (Test-Nx11ByteEqual $live.value $e.modified.value))
                if (-not $stillOurs) {
                    $diverged += [pscustomobject]@{ tweakId = $e.tweakId; target = "startupApproved $name"; reason = 'approval value no longer equals what NEXTRIX recorded' }
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: StartupApproved bytes differ' -Profiles @($e.profiles)
                    continue
                }
                if ($e.original.existed) {
                    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
                    New-ItemProperty -Path $path -Name $name -Value ([byte[]]@($e.original.value)) -PropertyType Binary -Force | Out-Null
                } else {
                    if (Test-Path -LiteralPath $path) { Remove-ItemProperty -Path $path -Name $name -ErrorAction Stop }
                }
                $check = Capture-NxRegistryValue -Path $path -Name $name
                $ok = $false
                if ($e.original.existed) { $ok = ($check.existed -and (Test-Nx11ByteEqual $check.value $e.original.value)) }
                else { $ok = (-not $check.existed) }
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles)
                if ($ok) { $restored += [pscustomobject]@{ tweakId = $e.tweakId; target = "startupApproved $name"; action = 'exact bytes restored'; detail = $path } }
                else { $failed += [pscustomobject]@{ tweakId = $e.tweakId; target = "startupApproved $name"; reason = 'restored value did not verify' } }
            }
        } catch {
            $failed += [pscustomobject]@{ tweakId = $e.tweakId; target = $tt; reason = [string]$_.Exception.Message }
            try { $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'failed' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles @($e.profiles) } catch { }
        }
    }
    return [pscustomobject][ordered]@{
        aborted = $false; integrityErrors = @(); restored = $restored; diverged = $diverged; failed = $failed
        note = 'Registry targets of NX11-002/003/004/015 are restored by Invoke-NxRollback core; this engine handles service/task/StartupApproved entries.'
    }
}
