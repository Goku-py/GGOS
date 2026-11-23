#Requires -Version 5.1
<#
    NX05.ps1 - NEXTRIX Memory Management category functions (workstream W2-B).

    Companion to registry/NX05.json (single source of truth for NX05-001..NX05-011).

    Dependencies (dot-source AFTER the core modules, as Import-NxCore does):
      NxJournal.ps1  -> Capture-NxRegistryValue, Add-NxJournalEntry, Read-NxJournal,
                        Read-NxManifest
      NxVerify.ps1   -> Test-NxConfigurationState
      NxApply.ps1    -> Set-NxRegistryValue (declarative registry routes only)
      NxRollback.ps1 -> core rollback delegation target (Invoke-Nx05Rollback)

    Loading this file defines functions only: no registry writes, no CIM reads, no
    service control and no network access happen at dot-source time.

    TARGETS (all distinct value names; no cross-category duplication):
      HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management
        AutomaticManagedPagefile, PagingFiles   -> NX05-001/002/003
        LargeSystemCache                        -> NX05-007 (declarative, engine)
        ClearPageFileAtShutdown                 -> NX05-008 (declarative, engine)
        PoolUsageMaximum, PagedPoolSize,
        NonPagedPoolSize                        -> NX05-010
      HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl
        CrashDumpEnabled                        -> NX05-009
      MMAgent cmdlet state (no registry contract) -> NX05-004

    PAGEFILE ORIGINAL-STATE STRATEGY (why restore is exact):
      The pagefile configuration is journaled as TWO exact registry descriptors,
      not as a WMI summary:
        1. AutomaticManagedPagefile - full Capture-NxRegistryValue descriptor
           (keyExisted/existed/kind/value), so an absent value is restored by
           deleting it again instead of inventing 0.
        2. PagingFiles - the complete REG_MULTI_SZ, entry for entry (for example
           "C:\pagefile.sys 2048 4096"), so other drives' entries, ordering and
           the 0/0 system-managed form are reproduced byte-for-byte.
      Win32_ComputerSystem.AutomaticManagedPagefile and Win32_PageFileSetting are
      captured read-only as REPORTED context only. They are never the restore
      anchor: WMI can lag, summarizes, and does not preserve per-drive entries.
      Consequence documented in every pagefile entry: Windows may rewrite
      PagingFiles itself while automatic management is on, so rollback restores
      both journaled values exactly rather than trusting the live layout.

    SAFETY / POLICY BOUNDARIES:
      - No pagefile entry in a preset; disabling the pagefile is TROUBLESHOOTING
        and requires -AcknowledgeCommitRisk (NEXTRIX never disables it by default).
      - No continuous standby-memory cleaner, no EmptyStandbyList, no scheduled
        list trimming anywhere: NX05-006 is a read-only report.
      - SysMain is never started/stopped (NX11 owns it); Disable/Enable-MMAgent
        simply fail cleanly when SysMain is not running (documented error 1058).
      - Memory compression is not configured through undocumented registry values;
        Disable-MMAgent's backing store is not a public registry contract (r4).
      - Crash-dump configuration refuses "None": crash-dump destruction is a
        rejected recovery-sabotage pattern in the REJECT register.
      - Pool limits require an explicit documented-symptom note (E0 troubleshooting).

    VERIFICATION DISCIPLINE: configuration verification only. Nothing in this
    module claims a performance outcome (directive Section 6).
#>

$script:Nx05MemoryPath      = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$script:Nx05CrashControlPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
$script:Nx05AutoManagedName = 'AutomaticManagedPagefile'
$script:Nx05PagingFilesName = 'PagingFiles'

# ----------------------------------------------------------------------------
# Internal helpers (pure logic or exact registry primitives; no tweak policy)
# ----------------------------------------------------------------------------

function Assert-Nx05JournalReady {
    # No mutation without an initialized, capture-Complete journal (adopt #2).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JournalRoot)
    $state = Read-NxManifest -Path $JournalRoot
    if (-not $state.present) {
        throw "journal not initialized at '$JournalRoot' - refusing to mutate (journal-first invariant; run NX16-004 / preflight first)"
    }
    if ([string]$state.manifest.captureStatus -ne 'Complete') {
        throw "journal captureStatus is '$($state.manifest.captureStatus)' - refusing to mutate (capture must be Complete)"
    }
}

function ConvertFrom-Nx05PagingFiles {
    # Parses the PagingFiles REG_MULTI_SZ. Unparsable non-empty lines are kept
    # verbatim (parseOk=false) so a custom-size edit never silently drops them.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][string[]]$Entries)
    $list = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Entries) { return $list.ToArray() }
    foreach ($raw in $Entries) {
        if ($null -eq $raw) { continue }
        $text = ([string]$raw).Trim()
        if ($text.Length -eq 0) { continue }
        $item = [pscustomobject]@{
            raw = $text; path = $null; drive = $null
            initialSizeMB = $null; maximumSizeMB = $null
            systemManaged = $false; parseOk = $false
        }
        $m = [regex]::Match($text, '^(?<path>[A-Za-z?]:\\[^\s]+)(?:\s+(?<initial>[0-9]+)\s+(?<maximum>[0-9]+))?$')
        if ($m.Success) {
            $item.path = $m.Groups['path'].Value
            $drv = $m.Groups['path'].Value.Substring(0, 2)
            if ($drv -eq '?:') { $item.drive = '?' } else { $item.drive = $drv.ToUpperInvariant() }
            if ($m.Groups['initial'].Success) {
                $item.initialSizeMB = [int64]$m.Groups['initial'].Value
                $item.maximumSizeMB = [int64]$m.Groups['maximum'].Value
                if ($item.initialSizeMB -eq 0 -and $item.maximumSizeMB -eq 0) { $item.systemManaged = $true }
            } else {
                # Path-only form (for example "?:\pagefile.sys"): Windows decides
                # the size, i.e. system-managed on that drive.
                $item.systemManaged = $true
            }
            $item.parseOk = $true
        }
        $list.Add($item)
    }
    return $list.ToArray()
}

function New-Nx05PagingFileEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Drive,
        [Parameter(Mandatory)][int64]$InitialSizeMB,
        [Parameter(Mandatory)][int64]$MaximumSizeMB
    )
    return ('{0}\pagefile.sys {1} {2}' -f $Drive.TrimEnd('\'), $InitialSizeMB, $MaximumSizeMB)
}

function Get-Nx05MergedPagingFiles {
    <#
        Pure merge used by NX05-002: replaces the entry for -Drive with the
        requested size, collapses duplicate entries for that drive, keeps every
        other drive's entry verbatim and in order, and appends when the drive has
        no entry yet. The wildcard form "?:\pagefile.sys" is the system drive's
        pagefile, so a custom size for the system drive replaces it.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Existing,
        [Parameter(Mandatory)][string]$Drive,
        [Parameter(Mandatory)][int64]$InitialSizeMB,
        [Parameter(Mandatory)][int64]$MaximumSizeMB,
        [string]$SystemDrive = $env:SystemDrive
    )
    $driveNorm = $Drive.Trim().ToUpperInvariant().TrimEnd('\')
    $systemNorm = ([string]$SystemDrive).Trim().ToUpperInvariant()
    $newEntry = New-Nx05PagingFileEntry -Drive $driveNorm -InitialSizeMB $InitialSizeMB -MaximumSizeMB $MaximumSizeMB
    $desired = New-Object System.Collections.Generic.List[string]
    $replaced = $false
    if ($null -ne $Existing) {
        foreach ($raw in $Existing) {
            $text = ([string]$raw).Trim()
            if ($text.Length -eq 0) { continue }
            $parsed = @(ConvertFrom-Nx05PagingFiles -Entries @($text))
            $isTarget = $false
            if ($parsed.Count -gt 0 -and $parsed[0].parseOk -and $parsed[0].drive) {
                if ($parsed[0].drive.ToUpperInvariant() -eq $driveNorm) { $isTarget = $true }
                elseif ($parsed[0].drive -eq '?' -and $driveNorm -eq $systemNorm) { $isTarget = $true }
            }
            if ($isTarget) {
                if (-not $replaced) { $desired.Add($newEntry); $replaced = $true }
                continue
            }
            $desired.Add($text)
        }
    }
    if (-not $replaced) { $desired.Add($newEntry) }
    return $desired.ToArray()
}

function ConvertTo-Nx05DwordStored {
    # Registry DWORDs are signed 32-bit in .NET: the documented PagedPoolSize
    # 0xFFFFFFFF (4294967295) reads back as -1. Normalizes for compare/verify.
    [CmdletBinding()]
    param([Parameter(Mandatory)][int64]$Value)
    if ($Value -gt 2147483647) { return [int64]($Value - 4294967296) }
    return $Value
}

function Get-Nx05CimData {
    # Read-only CIM helper. Failure is data (report it), never a guessed value.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClassName)
    try {
        $items = @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
        return [pscustomobject]@{ ok = $true; instances = $items; error = $null }
    } catch {
        return [pscustomobject]@{ ok = $false; instances = @(); error = [string]$_.Exception.Message }
    }
}

function ConvertTo-Nx05PagingFilesArray {
    # Normalizes a PagingFiles value into a comparable string array (blank lines
    # dropped, whitespace trimmed). Comparison only - never used for writing.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()]$Value)
    if ($null -eq $Value) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($Value)) {
        if ($null -eq $v) { continue }
        $t = ([string]$v).Trim()
        if ($t.Length -gt 0) { $out.Add($t) }
    }
    return $out.ToArray()
}

function Test-Nx05StringArraysEqual {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()]$Left, [AllowNull()][AllowEmptyCollection()]$Right)
    $a = @(ConvertTo-Nx05PagingFilesArray -Value $Left)
    $b = @(ConvertTo-Nx05PagingFilesArray -Value $Right)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i] -ne $b[$i]) { return $false }
    }
    return $true
}

function Test-Nx05DescriptorEquals {
    # Exact descriptor equality against a live capture (value + kind + existence).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Live, [Parameter(Mandatory)]$Recorded)
    if ([bool]$Live.existed -ne [bool]$Recorded.existed) { return $false }
    if (-not $Recorded.existed) { return $true }
    if ([string]$Live.kind -ne [string]$Recorded.kind) { return $false }
    if ([string]$Recorded.kind -eq 'MultiString') {
        # JSON round-trips a one-entry MULTI_SZ as a bare string; compare the
        # normalized entry lists so a single-entry pagefile list never reports a
        # false divergence.
        return (Test-Nx05StringArraysEqual -Left $Live.value -Right $Recorded.value)
    }
    $a = ConvertTo-Json -InputObject $Live.value -Depth 6 -Compress
    $b = ConvertTo-Json -InputObject $Recorded.value -Depth 6 -Compress
    return ($a -eq $b)
}

function Set-Nx05ExactValue {
    # Exact-kind registry write used by apply/restore paths. Exists because the
    # registry provider cannot reliably write a zero-entry REG_MULTI_SZ, which is
    # exactly the state "no paging files" (NX05-003) and a legitimate original.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('String','ExpandString','Binary','DWord','MultiString','QWord')][string]$Kind,
        [AllowNull()]$Value
    )
    if (-not $Path.StartsWith('HKLM:\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Set-Nx05ExactValue supports HKLM only (got '$Path')"
    }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    $sub = $Path.Substring(6)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub, $true)
    if ($null -eq $key) { throw "cannot open registry key '$sub' for writing" }
    try {
        switch ($Kind) {
            'DWord'        {
                # Registry DWORDs are signed in .NET: 0xFFFFFFFF is stored as -1.
                $dword = [int64]$Value
                if ($dword -gt [int]::MaxValue) { $dword = $dword - 4294967296 }
                $key.SetValue($Name, [int]$dword, [Microsoft.Win32.RegistryValueKind]::DWord)
            }
            'QWord'        { $key.SetValue($Name, [int64]$Value, [Microsoft.Win32.RegistryValueKind]::QWord) }
            'String'       { $key.SetValue($Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]::String) }
            'ExpandString' { $key.SetValue($Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
            'Binary'       { $key.SetValue($Name, [byte[]]$Value, [Microsoft.Win32.RegistryValueKind]::Binary) }
            'MultiString'  {
                $arr = @()
                if ($null -ne $Value) { $arr = @($Value | ForEach-Object { [string]$_ }) }
                try {
                    $key.SetValue($Name, [string[]]$arr, [Microsoft.Win32.RegistryValueKind]::MultiString)
                } catch {
                    # Zero-entry fallback: a single empty string is the same
                    # "no entries" state to the Windows loader and still round-trips
                    # through the journaled exact-original value.
                    if ($arr.Count -eq 0) {
                        $key.SetValue($Name, [string]::Empty, [Microsoft.Win32.RegistryValueKind]::MultiString)
                    } else { throw }
                }
            }
        }
    } finally { $key.Dispose() }
}

function Restore-Nx05DescriptorValue {
    # Restores ONE captured descriptor exactly: rewrite (same kind) when it
    # existed, delete when it did not, no-op when it did not exist and is absent.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Descriptor)
    $path = [string]$Descriptor.path
    $name = [string]$Descriptor.name
    if ($Descriptor.existed) {
        Set-Nx05ExactValue -Path $path -Name $name -Kind ([string]$Descriptor.kind) -Value $Descriptor.value
        return
    }
    if (-not (Test-Path $path)) { return }
    $key = Get-Item -Path $path
    $live = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($null -ne $live) { Remove-ItemProperty -Path $path -Name $name -ErrorAction Stop }
}

function Set-Nx05PagingFilesValue {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][string[]]$Entries)
    $arr = @($Entries)
    if ($null -eq $Entries) { $arr = @() }
    Set-Nx05ExactValue -Path $script:Nx05MemoryPath -Name $script:Nx05PagingFilesName -Kind 'MultiString' -Value $arr
}

function Get-Nx05PagefileState {
    # Read-only composite snapshot. Registry descriptors are authoritative; CIM
    # values are reported context. All failures surface as uncertainty.
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]

    $auto = Capture-NxRegistryValue -Path $script:Nx05MemoryPath -Name $script:Nx05AutoManagedName
    $pf   = Capture-NxRegistryValue -Path $script:Nx05MemoryPath -Name $script:Nx05PagingFilesName

    $rawEntries = @()
    if ($pf.existed) {
        if ($pf.value -is [array]) { $rawEntries = @($pf.value) }
        elseif ($null -ne $pf.value) { $rawEntries = @([string]$pf.value) }
    }
    $entries = @(ConvertFrom-Nx05PagingFiles -Entries $rawEntries)
    $unparsed = @($entries | Where-Object { -not $_.parseOk })

    $reportedAuto = $null
    $cs = Get-Nx05CimData -ClassName 'Win32_ComputerSystem'
    if ($cs.ok -and @($cs.instances).Count -gt 0) {
        $reportedAuto = @($cs.instances)[0].AutomaticManagedPagefile
    } elseif (-not $cs.ok) {
        $uncertainty.Add("Win32_ComputerSystem read failed: $($cs.error)")
    }

    $settings = @()
    $pfs = Get-Nx05CimData -ClassName 'Win32_PageFileSetting'
    if ($pfs.ok) {
        foreach ($s in $pfs.instances) {
            $settings += [pscustomobject]@{
                name = [string]$s.Name; initialSizeMB = $s.InitialSize; maximumSizeMB = $s.MaximumSize
            }
        }
    } else {
        $uncertainty.Add("Win32_PageFileSetting read failed: $($pfs.error)")
    }

    return [pscustomobject]@{
        readOnly                = $true
        capturedUtc             = (Get-Date).ToUniversalTime().ToString('o')
        automaticManaged        = $auto
        pagingFiles             = $pf
        entries                 = $entries
        entryCount              = $entries.Count
        unparsedEntryCount      = $unparsed.Count
        systemManagedEntryCount = @($entries | Where-Object { $_.systemManaged }).Count
        pagingFilesRaw          = @($rawEntries | ForEach-Object { [string]$_ })
        reportedAutomaticManaged = $reportedAuto
        reportedPageFileSettings = $settings
        uncertainty             = $uncertainty.ToArray()
    }
}

function Test-Nx05PagefileStateMatches {
    # Only-if-ours predicate for pagefileState entries 'systemManaged' | 'custom' |
    # 'disabled'. Uses the recorded "modified" descriptor, never the original.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Live, [Parameter(Mandatory)]$Modified)
    $autoValue = $null
    if ($Live.automaticManaged.existed) { $autoValue = [int]$Live.automaticManaged.value }
    switch ([string]$Modified.mode) {
        'systemManaged' { return ($null -ne $autoValue -and $autoValue -eq 1) }
        'custom' {
            if ($null -eq $autoValue -or $autoValue -ne 0) { return $false }
            return (Test-Nx05StringArraysEqual -Left $Live.pagingFilesRaw -Right $Modified.pagingFiles)
        }
        'disabled' {
            if ($null -eq $autoValue -or $autoValue -ne 0) { return $false }
            return ([int]$Live.entryCount -eq 0)
        }
    }
    return $false
}

function Get-Nx05MmAgentState {
    # Captures the documented MMAgent state (Get-MMAgent), never registry values.
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $available = $false
    $memoryCompression = $null
    $bag = [ordered]@{}

    try {
        $mma = Get-MMAgent -ErrorAction Stop
        foreach ($p in $mma.PSObject.Properties) {
            if (@('CimClass', 'CimInstanceProperties', 'CimSystemProperties', 'PSComputerName') -contains $p.Name) { continue }
            $bag[$p.Name] = $p.Value
        }
        $available = $true
        if ($bag.Contains('MemoryCompression')) { $memoryCompression = [bool]$bag['MemoryCompression'] }
        else { $uncertainty.Add('Get-MMAgent returned no MemoryCompression property on this build') }
    } catch {
        $uncertainty.Add("Get-MMAgent failed: $($_.Exception.Message)")
    }

    $sysMainStatus = $null
    $sysMainStartType = $null
    try {
        $svc = Get-Service -Name 'SysMain' -ErrorAction Stop
        $sysMainStatus = [string]$svc.Status
        $sysMainStartType = [string]$svc.StartType
    } catch {
        $uncertainty.Add("SysMain service read failed: $($_.Exception.Message)")
    }

    return [pscustomobject]@{
        readOnly          = $true
        available         = $available
        cmdlet            = 'Get-MMAgent'
        properties        = $bag
        memoryCompression = $memoryCompression
        sysMainStatus     = $sysMainStatus
        sysMainStartType  = $sysMainStartType
        uncertainty       = $uncertainty.ToArray()
    }
}

function Get-Nx05TotalPhysicalMemoryBytes {
    [CmdletBinding()]
    param()
    $cs = Get-Nx05CimData -ClassName 'Win32_ComputerSystem'
    if (-not $cs.ok -or @($cs.instances).Count -eq 0) { return $null }
    $value = @($cs.instances)[0].TotalPhysicalMemory
    if ($null -eq $value) { return $null }
    return [int64]$value
}

function Get-Nx05PerfMemorySnapshot {
    # WMI PerfOS_Memory page-list/pool counters (locale-independent class query).
    [CmdletBinding()]
    param()
    $names = @(
        'AvailableBytes', 'CacheBytes', 'CommitLimit', 'CommittedBytes',
        'FreeAndZeroPageListBytes', 'ModifiedPageListBytes',
        'PoolNonpagedBytes', 'PoolPagedBytes',
        'StandbyCacheCoreBytes', 'StandbyCacheNormalPriorityBytes', 'StandbyCacheReserveBytes'
    )
    $fields = [ordered]@{}
    $missing = New-Object System.Collections.Generic.List[string]
    $data = Get-Nx05CimData -ClassName 'Win32_PerfRawData_PerfOS_Memory'
    if ($data.ok -and @($data.instances).Count -gt 0) {
        $inst = @($data.instances)[0]
        foreach ($n in $names) {
            $prop = $inst.PSObject.Properties[$n]
            if ($null -ne $prop -and $null -ne $prop.Value) { $fields[$n] = [int64]$prop.Value }
            else { $missing.Add($n) }
        }
    } else {
        foreach ($n in $names) { $missing.Add($n) }
    }
    return [pscustomobject]@{
        available = [bool]$data.ok
        className = 'Win32_PerfRawData_PerfOS_Memory'
        fields    = $fields
        missing   = $missing.ToArray()
        error     = $data.error
    }
}

function Get-Nx05Percent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double]$Part, [Parameter(Mandatory)][double]$Whole)
    if ($Whole -le 0) { return $null }
    return [math]::Round(($Part / $Whole) * 100, 1)
}

function ConvertTo-Nx05MBFromKB {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double]$Kilobytes)
    return [math]::Round($Kilobytes / 1024, 1)
}

# ----------------------------------------------------------------------------
# NX05-001 - normalize to system-managed pagefile (CONDITIONAL)
# ----------------------------------------------------------------------------
function Set-NxSystemManagedPagefile {
    <#
    .SYNOPSIS
        NX05-001: sets AutomaticManagedPagefile=1 (system-managed) with an
        exact registry capture of both pagefile values for restore.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId = 'NX05-001',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved
    )
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    Assert-Nx05JournalReady -JournalRoot $JournalRoot

    $state = Get-Nx05PagefileState
    $steps.Add([pscustomobject]@{
        step = 2; name = 'capture-original'; outcome = 'Captured'
        detail = "AutomaticManagedPagefile existed=$($state.automaticManaged.existed) kind=$($state.automaticManaged.kind) value=$($state.automaticManaged.value); PagingFiles existed=$($state.pagingFiles.existed) entries=$($state.entryCount); reportedAuto=$($state.reportedAutomaticManaged)"
    })

    $original = [pscustomobject]@{
        targetType       = 'pagefileState'
        automaticManaged = $state.automaticManaged
        pagingFiles      = $state.pagingFiles
        reported         = [pscustomobject]@{
            automaticManagedPagefile = $state.reportedAutomaticManaged
            pageFileSettings         = $state.reportedPageFileSettings
            capturedUtc              = $state.capturedUtc
        }
    }
    $modified = [pscustomobject]@{
        targetType = 'pagefileState'; mode = 'systemManaged'; automaticManagedPagefile = 1
    }

    $already = ($state.automaticManaged.existed -and [int]$state.automaticManaged.value -eq 1)
    if ($already) {
        $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        $steps.Add([pscustomobject]@{ step = 8; name = 'apply'; outcome = 'AlreadyApplied'; detail = 'AutomaticManagedPagefile is already 1' })
        return [pscustomobject]@{
            tweakId = $TweakId; outcome = 'AlreadyApplied'; journalSeq = $skip.seq
            effectiveAt = 'AlreadyInEffect'; steps = $steps.ToArray(); uncertainty = @($state.uncertainty)
        }
    }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    $verified = $false
    $notes = New-Object System.Collections.Generic.List[string]
    try {
        Set-Nx05ExactValue -Path $script:Nx05MemoryPath -Name $script:Nx05AutoManagedName -Kind 'DWord' -Value 1
        $check = Test-NxConfigurationState -Path $script:Nx05MemoryPath -Name $script:Nx05AutoManagedName -Kind 'DWord' -ExpectedValue 1
        $verified = [bool]$check.verified
        if (-not $verified) { Restore-Nx05DescriptorValue -Descriptor $state.automaticManaged }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = $check.reason; journalSeq = $jr.seq; steps = $steps.ToArray() }
        }
    } catch {
        $err = [string]$_.Exception.Message
        try { Restore-Nx05DescriptorValue -Descriptor $state.automaticManaged } catch { $notes.Add("best-effort restore failed: $($_.Exception.Message)") }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = $err; journalSeq = $jr.seq; steps = $steps.ToArray() }
    }

    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = 'AutomaticManagedPagefile=DWord:1 (Windows owns pagefile sizing from the next restart)' })
    return [pscustomobject]@{
        tweakId        = $TweakId
        outcome        = 'Applied'
        original       = $original
        modified       = $modified
        journalSeq     = $jr.seq
        effectiveAt    = 'NextRestart'
        pagingFilesNote = 'Windows may rewrite PagingFiles itself while automatic management is on; rollback restores the exact journaled PagingFiles array and AutomaticManagedPagefile value, which reproduces the pre-change state.'
        notes          = $notes.ToArray()
        uncertainty    = @($state.uncertainty)
        steps          = $steps.ToArray()
    }
}

# ----------------------------------------------------------------------------
# NX05-002 - custom pagefile size (ADVANCED)
# ----------------------------------------------------------------------------
function Set-NxCustomPagefile {
    <#
    .SYNOPSIS
        NX05-002: per-drive custom pagefile entry with exact MB values. Never
        disables the pagefile; other drives' PagingFiles entries are preserved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$Drive,
        [Parameter(Mandatory)][int64]$InitialSizeMB,
        [Parameter(Mandatory)][int64]$MaximumSizeMB,
        [string]$TweakId = 'NX05-002',
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [switch]$Approved
    )
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }

    # ---- input validation (untrusted boundary) ----
    $driveNorm = $Drive.Trim().ToUpperInvariant().TrimEnd('\')
    if ($driveNorm -notmatch '^[A-Z]:$') { throw "drive '$Drive' must be a drive letter root such as 'C:'" }
    if (-not (Test-Path ($driveNorm + '\'))) { throw "drive '$driveNorm' is not present on this machine" }
    if ($InitialSizeMB -eq 0 -and $MaximumSizeMB -eq 0) {
        throw "0/0 means system-managed sizing, which is NX05-001's job - refusing to disguise it as a custom size"
    }
    if ($InitialSizeMB -lt 16 -or $InitialSizeMB -gt 1048576) { throw "initialSizeMB must be 16..1048576 (whole MB); got $InitialSizeMB" }
    if ($MaximumSizeMB -lt 16 -or $MaximumSizeMB -gt 4194304) { throw "maximumSizeMB must be 16..4194304 (whole MB); got $MaximumSizeMB" }
    if ($MaximumSizeMB -lt $InitialSizeMB) { throw "maximumSizeMB ($MaximumSizeMB) must be >= initialSizeMB ($InitialSizeMB)" }

    Assert-Nx05JournalReady -JournalRoot $JournalRoot
    $state = Get-Nx05PagefileState
    $steps.Add([pscustomobject]@{
        step = 2; name = 'capture-original'; outcome = 'Captured'
        detail = "AutomaticManagedPagefile existed=$($state.automaticManaged.existed) value=$($state.automaticManaged.value); PagingFiles entries=$($state.entryCount) raw=[$($state.pagingFilesRaw -join ' | ')]"
    })

    $desiredArray = @(Get-Nx05MergedPagingFiles -Existing $state.pagingFilesRaw -Drive $driveNorm -InitialSizeMB $InitialSizeMB -MaximumSizeMB $MaximumSizeMB)

    $original = [pscustomobject]@{
        targetType       = 'pagefileState'
        automaticManaged = $state.automaticManaged
        pagingFiles      = $state.pagingFiles
        reported         = [pscustomobject]@{
            automaticManagedPagefile = $state.reportedAutomaticManaged
            pageFileSettings         = $state.reportedPageFileSettings
            capturedUtc              = $state.capturedUtc
        }
    }
    $modified = [pscustomobject]@{
        targetType = 'pagefileState'; mode = 'custom'
        automaticManagedPagefile = 0
        drive = $driveNorm; initialSizeMB = $InitialSizeMB; maximumSizeMB = $MaximumSizeMB
        pagingFiles = $desiredArray
    }

    # Idempotency: same drive entry plus automatic management off -> nothing to do.
    $liveMatches = (Test-Nx05PagefileStateMatches -Live $state -Modified $modified)
    if ($liveMatches) {
        $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'AlreadyApplied'; journalSeq = $skip.seq; desiredPagingFiles = $desiredArray; steps = $steps.ToArray(); uncertainty = @($state.uncertainty) }
    }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        # Custom sizes are ignored while Windows manages the pagefile: turn
        # automatic management off first, then write the exact MULTI_SZ.
        Set-Nx05ExactValue -Path $script:Nx05MemoryPath -Name $script:Nx05AutoManagedName -Kind 'DWord' -Value 0
        Set-Nx05PagingFilesValue -Entries $desiredArray
        $live = Get-Nx05PagefileState
        $autoOk = ($live.automaticManaged.existed -and [int]$live.automaticManaged.value -eq 0)
        $pfOk = Test-Nx05StringArraysEqual -Left $live.pagingFilesRaw -Right $desiredArray
        $verified = ($autoOk -and $pfOk)
        if (-not $verified) {
            try { Restore-Nx05DescriptorValue -Descriptor $state.pagingFiles } catch { }
            try { Restore-Nx05DescriptorValue -Descriptor $state.automaticManaged } catch { }
        }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            $reason = "autoManagedOk=$autoOk pagingFilesOk=$pfOk live=[$($live.pagingFilesRaw -join ' | ')]"
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $reason -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = $reason; journalSeq = $jr.seq; steps = $steps.ToArray() }
        }
    } catch {
        $err = [string]$_.Exception.Message
        try { Restore-Nx05DescriptorValue -Descriptor $state.pagingFiles } catch { }
        try { Restore-Nx05DescriptorValue -Descriptor $state.automaticManaged } catch { }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = $err; journalSeq = $jr.seq; steps = $steps.ToArray() }
    }

    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = "PagingFiles [$($desiredArray -join ' | ')] with AutomaticManagedPagefile=0" })
    return [pscustomobject]@{
        tweakId           = $TweakId
        outcome           = 'Applied'
        original          = $original
        modified          = $modified
        journalSeq        = $jr.seq
        desiredPagingFiles = $desiredArray
        effectiveAt       = 'NextRestart'
        warnings          = @(
            "A maximum below this machine's peak commit charge can cause commit-limit allocation failures (Microsoft page-file guidance defines the commit limit as RAM + page files).",
            "Kernel/complete/automatic crash dumps need a boot-volume pagefile large enough for the dump type (NX05-009)."
        )
        uncertainty       = @($state.uncertainty)
        steps             = $steps.ToArray()
    }
}

# ----------------------------------------------------------------------------
# NX05-003 - disable pagefile (TROUBLESHOOTING, preset-excluded)
# ----------------------------------------------------------------------------
function Disable-NxPagefile {
    <#
    .SYNOPSIS
        NX05-003: removes all paging files with an explicit commit-risk consent
        gate. Effective at the next restart; exact prior configuration journaled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [switch]$AcknowledgeCommitRisk,
        [string]$TweakId = 'NX05-003',
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [switch]$Approved
    )
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    if (-not $AcknowledgeCommitRisk) {
        throw "tweak ${TweakId}: refusing to remove the pagefile without -AcknowledgeCommitRisk. Documented risk: the commit limit becomes slightly less than installed RAM (Microsoft page-file guidance); allocations can fail at peak commit and kernel/complete/automatic dumps cannot be written."
    }
    Assert-Nx05JournalReady -JournalRoot $JournalRoot

    $state = Get-Nx05PagefileState
    $steps.Add([pscustomobject]@{
        step = 2; name = 'capture-original'; outcome = 'Captured'
        detail = "AutomaticManagedPagefile existed=$($state.automaticManaged.existed) value=$($state.automaticManaged.value); PagingFiles entries=$($state.entryCount) raw=[$($state.pagingFilesRaw -join ' | ')]"
    })

    $original = [pscustomobject]@{
        targetType       = 'pagefileState'
        automaticManaged = $state.automaticManaged
        pagingFiles      = $state.pagingFiles
        reported         = [pscustomobject]@{
            automaticManagedPagefile = $state.reportedAutomaticManaged
            pageFileSettings         = $state.reportedPageFileSettings
            capturedUtc              = $state.capturedUtc
        }
    }
    $modified = [pscustomobject]@{
        targetType = 'pagefileState'; mode = 'disabled'
        automaticManagedPagefile = 0; pagingFiles = @()
    }

    if (Test-Nx05PagefileStateMatches -Live $state -Modified $modified) {
        $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'AlreadyApplied'; journalSeq = $skip.seq; steps = $steps.ToArray(); uncertainty = @($state.uncertainty) }
    }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Set-Nx05ExactValue -Path $script:Nx05MemoryPath -Name $script:Nx05AutoManagedName -Kind 'DWord' -Value 0
        Set-Nx05PagingFilesValue -Entries @()
        $live = Get-Nx05PagefileState
        $autoOk = ($live.automaticManaged.existed -and [int]$live.automaticManaged.value -eq 0)
        $noEntries = ([int]$live.entryCount -eq 0)
        $verified = ($autoOk -and $noEntries)
        if (-not $verified) {
            try { Restore-Nx05DescriptorValue -Descriptor $state.pagingFiles } catch { }
            try { Restore-Nx05DescriptorValue -Descriptor $state.automaticManaged } catch { }
        }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            $reason = "autoManagedOk=$autoOk noEntries=$noEntries liveEntries=$($live.entryCount) raw=[$($live.pagingFilesRaw -join ' | ')]"
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $reason -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = $reason; journalSeq = $jr.seq; steps = $steps.ToArray() }
        }
    } catch {
        $err = [string]$_.Exception.Message
        try { Restore-Nx05DescriptorValue -Descriptor $state.pagingFiles } catch { }
        try { Restore-Nx05DescriptorValue -Descriptor $state.automaticManaged } catch { }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = $err; journalSeq = $jr.seq; steps = $steps.ToArray() }
    }

    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = 'registry configuration for "no paging files" holds (effective at the next restart)' })
    return [pscustomobject]@{
        tweakId      = $TweakId
        outcome      = 'Applied'
        original     = $original
        modified     = $modified
        journalSeq   = $jr.seq
        effectiveAt  = 'NextRestart'
        liveStateNote = 'Win32_PageFileUsage still reports the currently active pagefile until the restart; the registry configuration is what Windows will use next boot.'
        warnings     = @(
            'Commit limit becomes slightly less than installed RAM (Microsoft page-file guidance); allocations can fail at peak commit.',
            'Kernel/complete/automatic memory dumps cannot be written with no boot-volume pagefile (NX05-009 conflict).',
            'TROUBLESHOOTING/preset-excluded: never a general performance setting.'
        )
        uncertainty  = @($state.uncertainty)
        steps        = $steps.ToArray()
    }
}

# ----------------------------------------------------------------------------
# NX05-004 - memory compression configuration (ADVANCED)
# ----------------------------------------------------------------------------
function Set-NxMemoryCompression {
    <#
    .SYNOPSIS
        NX05-004: Enable/Disable-MMAgent -MemoryCompression with a RAM threshold
        gate, SysMain precondition reporting and full Get-MMAgent state journaled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][bool]$Enabled,
        [int]$MinimumRamGB = 16,
        [switch]$AllowBelowThreshold,
        [string]$TweakId = 'NX05-004',
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [switch]$Approved
    )
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    if ($MinimumRamGB -lt 0 -or $MinimumRamGB -gt 4096) { throw "minimumRamGB '$MinimumRamGB' is out of range (0..4096)" }
    Assert-Nx05JournalReady -JournalRoot $JournalRoot

    $targetValue = $false
    if ($Enabled) { $targetValue = $true }

    $mma = Get-Nx05MmAgentState
    $steps.Add([pscustomobject]@{
        step = 2; name = 'capture-original'; outcome = 'Captured'
        detail = "Get-MMAgent available=$($mma.available) MemoryCompression=$($mma.memoryCompression); SysMain=$($mma.sysMainStatus)/$($mma.sysMainStartType)"
    })
    if (-not $mma.available) {
        throw "tweak ${TweakId}: Get-MMAgent is unavailable on this host ($($mma.uncertainty -join '; ')) - cannot capture or verify MMAgent state, refusing to change it"
    }
    if ($null -eq $mma.memoryCompression) {
        throw "tweak ${TweakId}: Get-MMAgent did not report MemoryCompression on this build - refusing to change an unverifiable setting"
    }

    # Hardware gate: reference research restricts compression disabling to 16 GB+.
    if (-not $Enabled) {
        $ramBytes = Get-Nx05TotalPhysicalMemoryBytes
        if ($null -eq $ramBytes) {
            if (-not $AllowBelowThreshold) {
                throw "tweak ${TweakId}: unable to read installed RAM (Win32_ComputerSystem) - the ${MinimumRamGB} GB threshold gate cannot be evaluated; pass -AllowBelowThreshold only if you accept the documented hard-fault trade-off on smaller systems"
            }
        } else {
            $ramGB = [math]::Round($ramBytes / 1GB, 1)
            if ($MinimumRamGB -gt 0 -and $ramGB -lt $MinimumRamGB -and -not $AllowBelowThreshold) {
                throw "tweak ${TweakId}: installed RAM ${ramGB} GB is below the ${MinimumRamGB} GB threshold. Reference research (UltraOS) records that disabling compression on 8-16 GB systems increases hard faults under memory pressure. Pass -AllowBelowThreshold to override explicitly."
            }
        }
    }

    $original = [pscustomobject]@{
        targetType        = 'mmAgentState'
        cmdlet            = 'Get-MMAgent'
        memoryCompression = $mma.memoryCompression
        properties        = $mma.properties
        sysMainStatus     = $mma.sysMainStatus
        capturedUtc       = (Get-Date).ToUniversalTime().ToString('o')
    }
    $modified = [pscustomobject]@{
        targetType = 'mmAgentState'; memoryCompression = $targetValue
        direction = $(if ($Enabled) { 'enable' } else { 'disable' })
    }

    if ($mma.memoryCompression -eq $targetValue) {
        $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'AlreadyApplied'; journalSeq = $skip.seq; currentState = $mma; steps = $steps.ToArray(); uncertainty = @($mma.uncertainty) }
    }

    # Documented precondition: the MMAgent cmdlets fail with error 1058 when
    # SysMain is not running. NEXTRIX never starts services (NX11-009 owns SysMain).
    if ($null -ne $mma.sysMainStatus -and $mma.sysMainStatus -ne 'Running') {
        throw "tweak ${TweakId}: SysMain is '$($mma.sysMainStatus)' ($($mma.sysMainStartType)). Disable-MMAgent/Enable-MMAgent -MemoryCompression require SysMain running (documented error 1058). NEXTRIX does not start services - enable SysMain through NX11 first if this change is really wanted."
    }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        if ($Enabled) { Enable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null }
        else { Disable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null }
        $after = Get-Nx05MmAgentState
        $verified = ($after.available -and $null -ne $after.memoryCompression -and $after.memoryCompression -eq $targetValue)
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            $reason = "Get-MMAgent MemoryCompression=$($after.memoryCompression) after cmdlet (expected $targetValue)"
            try {
                if ([bool]$original.memoryCompression) { Enable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null }
                else { Disable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null }
            } catch { }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $reason -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = $reason; journalSeq = $jr.seq; steps = $steps.ToArray() }
        }
    } catch {
        $err = [string]$_.Exception.Message
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = $err; journalSeq = $jr.seq; steps = $steps.ToArray() }
    }

    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = "Get-MMAgent MemoryCompression=$targetValue (all other MMAgent aspects untouched)" })
    return [pscustomobject]@{
        tweakId   = $TweakId
        outcome   = 'Applied'
        original  = $original
        modified  = $modified
        journalSeq = $jr.seq
        afterState = $after
        warnings  = @(
            'With compression off, the same working set occupies more distinct physical pages; on 8-16 GB systems the reference research records increased hard faults under memory pressure.',
            'Requires SysMain running; NEXTRIX does not start or stop services (NX11-009 owns SysMain).'
        )
        uncertainty = @($mma.uncertainty)
        steps     = $steps.ToArray()
    }
}

# ----------------------------------------------------------------------------
# NX05-005 - memory pressure & commit report (read-only)
# ----------------------------------------------------------------------------
function Get-NxMemoryPressureReport {
    <#
    .SYNOPSIS
        NX05-005: read-only physical/commit/pagefile snapshot. Writes nothing.
    #>
    [CmdletBinding()]
    param([string]$TweakId = 'NX05-005')
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $observations = New-Object System.Collections.Generic.List[string]

    $os = Get-Nx05CimData -ClassName 'Win32_OperatingSystem'
    $physical = $null; $commit = $null
    if ($os.ok -and @($os.instances).Count -gt 0) {
        $o = @($os.instances)[0]
        $totalPhysKB = [int64]$o.TotalVisibleMemorySize
        $freePhysKB  = [int64]$o.FreePhysicalMemory
        $commitLimitKB = [int64]$o.TotalVirtualMemorySize
        $commitFreeKB  = [int64]$o.FreeVirtualMemory
        $commitUsedKB  = $commitLimitKB - $commitFreeKB
        $physical = [pscustomobject]@{
            source = 'Win32_OperatingSystem'
            totalMB = ConvertTo-Nx05MBFromKB -Kilobytes $totalPhysKB
            usedMB  = ConvertTo-Nx05MBFromKB -Kilobytes ($totalPhysKB - $freePhysKB)
            availableMB = ConvertTo-Nx05MBFromKB -Kilobytes $freePhysKB
            usedPercent = Get-Nx05Percent -Part ($totalPhysKB - $freePhysKB) -Whole $totalPhysKB
        }
        $commit = [pscustomobject]@{
            source = 'Win32_OperatingSystem.TotalVirtualMemorySize/FreeVirtualMemory'
            limitKB = $commitLimitKB
            usedKB  = $commitUsedKB
            availableKB = $commitFreeKB
            limitMB = ConvertTo-Nx05MBFromKB -Kilobytes $commitLimitKB
            usedMB  = ConvertTo-Nx05MBFromKB -Kilobytes $commitUsedKB
            availableMB = ConvertTo-Nx05MBFromKB -Kilobytes $commitFreeKB
            usedPercent = Get-Nx05Percent -Part $commitUsedKB -Whole $commitLimitKB
        }
        $observations.Add("Commit charge is $($commit.usedMB) MB of a $($commit.limitMB) MB commit limit ($($commit.usedPercent)%); Microsoft's page-file guidance defines the commit limit as physical memory plus all page files.")
        $observations.Add("Physical memory in use: $($physical.usedMB) MB of $($physical.totalMB) MB ($($physical.usedPercent)%).")
    } else {
        $uncertainty.Add("Win32_OperatingSystem read failed: $($os.error)")
    }

    $usage = @()
    $u = Get-Nx05CimData -ClassName 'Win32_PageFileUsage'
    if ($u.ok) {
        foreach ($p in $u.instances) {
            $usage += [pscustomobject]@{
                source = 'Win32_PageFileUsage'
                name = [string]$p.Name
                allocatedMB = $p.AllocatedBaseSize
                currentUsageMB = $p.CurrentUsage
                peakUsageMB = $p.PeakUsage
                temporary = [bool]$p.TempPageFile
            }
        }
        if (@($usage).Count -eq 0) { $uncertainty.Add('Win32_PageFileUsage returned no pagefile instances (no pagefile configured, or it will be created at next boot).') }
    } else {
        $uncertainty.Add("Win32_PageFileUsage read failed: $($u.error)")
    }

    $settings = @()
    $s = Get-Nx05CimData -ClassName 'Win32_PageFileSetting'
    if ($s.ok) {
        foreach ($p in $s.instances) {
            $settings += [pscustomobject]@{
                source = 'Win32_PageFileSetting'
                name = [string]$p.Name; initialSizeMB = $p.InitialSize; maximumSizeMB = $p.MaximumSize
                systemManaged = ([int]$p.InitialSize -eq 0 -and [int]$p.MaximumSize -eq 0)
            }
        }
    } else {
        $uncertainty.Add("Win32_PageFileSetting read failed: $($s.error)")
    }

    $pagefileState = Get-Nx05PagefileState
    foreach ($x in @($pagefileState.uncertainty)) { $uncertainty.Add($x) }

    return [pscustomobject]@{
        tweakId        = $TweakId
        readOnly       = $true
        generatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        physical       = $physical
        commit         = $commit
        pageFileUsage  = $usage
        pageFileSettings = $settings
        registryConfiguration = [pscustomobject]@{
            automaticManagedValue = $(if ($pagefileState.automaticManaged.existed) { [int]$pagefileState.automaticManaged.value } else { $null })
            pagingFilesEntries    = $pagefileState.pagingFilesRaw
        }
        observations   = $observations.ToArray()
        noPerformanceClaim = $true
        uncertainty    = $uncertainty.ToArray()
    }
}

# ----------------------------------------------------------------------------
# NX05-006 - standby memory report (read-only; explicitly NO cleaner)
# ----------------------------------------------------------------------------
function Get-NxStandbyMemoryReport {
    <#
    .SYNOPSIS
        NX05-006: read-only standby/page-list snapshot. NEXTRIX contains no
        standby-list purger and schedules no cleaner.
    #>
    [CmdletBinding()]
    param([string]$TweakId = 'NX05-006')
    $uncertainty = New-Object System.Collections.Generic.List[string]

    $snap = Get-Nx05PerfMemorySnapshot
    if (-not $snap.available) {
        $uncertainty.Add("Win32_PerfRawData_PerfOS_Memory read failed: $($snap.error)")
    }
    foreach ($m in @($snap.missing)) {
        $uncertainty.Add("counter '$m' is not exposed by Win32_PerfRawData_PerfOS_Memory on this build - reported as unknown, never as zero")
    }

    $list = New-Object System.Collections.Generic.List[object]
    $bucketMap = [ordered]@{
        'FreeAndZeroPageListBytes'        = 'Free and zero page list'
        'ModifiedPageListBytes'           = 'Modified page list'
        'StandbyCacheCoreBytes'           = 'Standby cache - core'
        'StandbyCacheNormalPriorityBytes' = 'Standby cache - normal priority'
        'StandbyCacheReserveBytes'        = 'Standby cache - reserve'
    }
    foreach ($key in $bucketMap.Keys) {
        if ($snap.fields.Contains($key)) {
            $list.Add([pscustomobject]@{
                bucket = $bucketMap[$key]; counter = $key
                bytes = $snap.fields[$key]
                MB = [math]::Round(($snap.fields[$key] / 1MB), 1)
            })
        }
    }

    $standbyKeys = @('StandbyCacheCoreBytes', 'StandbyCacheNormalPriorityBytes', 'StandbyCacheReserveBytes')
    $standbyTotal = $null
    $standbyFound = 0
    $sum = [int64]0
    foreach ($k in $standbyKeys) {
        if ($snap.fields.Contains($k)) { $sum += [int64]$snap.fields[$k]; $standbyFound++ }
    }
    if ($standbyFound -gt 0) { $standbyTotal = $sum }
    else { $uncertainty.Add('No standby-cache counter was available; standby total is unknown (not zero).') }

    return [pscustomobject]@{
        tweakId      = $TweakId
        readOnly     = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        source       = 'Win32_PerfRawData_PerfOS_Memory'
        availableBytes = $(if ($snap.fields.Contains('AvailableBytes')) { $snap.fields['AvailableBytes'] } else { $null })
        cacheBytes     = $(if ($snap.fields.Contains('CacheBytes')) { $snap.fields['CacheBytes'] } else { $null })
        poolPagedBytes    = $(if ($snap.fields.Contains('PoolPagedBytes')) { $snap.fields['PoolPagedBytes'] } else { $null })
        poolNonpagedBytes = $(if ($snap.fields.Contains('PoolNonpagedBytes')) { $snap.fields['PoolNonpagedBytes'] } else { $null })
        standbyTotalBytes = $standbyTotal
        pageLists    = $list.ToArray()
        cleanerPresent = $false
        policyNote   = 'Diagnostics only. NEXTRIX ships no standby-list purger, no EmptyStandbyList helper, no scheduled cleaner and no configuration that empties standby lists; emptying standby lists is a measurement technique that discards cached file data, not a tuning action.'
        uncertainty  = $uncertainty.ToArray()
    }
}

# ----------------------------------------------------------------------------
# NX05-009 - crash dump configuration (CONDITIONAL)
# ----------------------------------------------------------------------------
function Set-NxCrashDumpConfiguration {
    <#
    .SYNOPSIS
        NX05-009: writes one documented CrashControl CrashDumpEnabled value.
        'None' is refused: NEXTRIX never disables crash dumps.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Small', 'Kernel', 'Automatic', 'Complete')][string]$DumpType,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId = 'NX05-009',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [switch]$Approved
    )
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    Assert-Nx05JournalReady -JournalRoot $JournalRoot

    # Documented CrashDumpEnabled values (Microsoft memory-dump options):
    # 0x3 small, 0x2 kernel, 0x7 automatic, 0x1 complete. 0x0 (None) refused.
    $map = @{ Small = 3; Kernel = 2; Automatic = 7; Complete = 1 }
    $targetValue = [int]$map[$DumpType]

    $cap = Capture-NxRegistryValue -Path $script:Nx05CrashControlPath -Name 'CrashDumpEnabled'
    $companionNames = @('AutoReboot', 'DumpFile', 'LogEvent', 'MinidumpDir', 'Overwrite', 'AlwaysKeepMemoryDump', 'FilterPages')
    $companions = [ordered]@{}
    foreach ($n in $companionNames) {
        $d = Capture-NxRegistryValue -Path $script:Nx05CrashControlPath -Name $n
        $companions[$n] = [pscustomobject]@{ existed = $d.existed; kind = $d.kind; value = $d.value }
    }
    $steps.Add([pscustomobject]@{
        step = 2; name = 'capture-original'; outcome = 'Captured'
        detail = "CrashDumpEnabled existed=$($cap.existed) kind=$($cap.kind) value=$($cap.value) -> target $DumpType ($targetValue); companion values captured read-only"
    })

    $original = [pscustomobject]@{
        targetType = 'crashDumpState'
        crashDumpEnabled = $cap
        companions = $companions
        capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $modified = [pscustomobject]@{
        targetType = 'crashDumpState'; dumpType = $DumpType; crashDumpEnabled = $targetValue
    }

    if ($cap.existed -and [int]$cap.value -eq $targetValue) {
        $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'AlreadyApplied'; journalSeq = $skip.seq; companions = $companions; steps = $steps.ToArray() }
    }

    # Disk-space / capability warning (not a failure): kernel-class dumps need a
    # boot-volume pagefile. Reported honestly, never silently ignored.
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($DumpType -ne 'Small') {
        $settings = Get-Nx05CimData -ClassName 'Win32_PageFileSetting'
        $boot = ([string]$env:SystemDrive).ToUpperInvariant()
        $bootPagefile = $false
        if ($settings.ok) {
            foreach ($p in $settings.instances) {
                $name = ([string]$p.Name).ToUpperInvariant()
                if ($name.StartsWith($boot + '\')) { $bootPagefile = $true }
            }
            if (-not $bootPagefile) {
                $warnings.Add("No pagefile is configured on the boot volume ($boot). $DumpType dumps cannot be written without one; NX05-003 conflicts with this entry.")
            }
        } else {
            $warnings.Add("Win32_PageFileSetting read failed ($($settings.error)); boot-volume pagefile availability for $DumpType dumps could not be checked.")
        }
        if ($DumpType -eq 'Complete') {
            $warnings.Add('A complete memory dump requires a boot-volume pagefile of at least installed RAM + 257 MB (Microsoft documentation).')
        }
    }
    $warnings.Add('A restart is required before the new dump type is used (Microsoft documentation).')

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Set-NxRegistryValue -Path $script:Nx05CrashControlPath -Name 'CrashDumpEnabled' -Kind 'DWord' -Value $targetValue
        $check = Test-NxConfigurationState -Path $script:Nx05CrashControlPath -Name 'CrashDumpEnabled' -Kind 'DWord' -ExpectedValue $targetValue
        $verified = [bool]$check.verified
        if (-not $verified) { Restore-Nx05DescriptorValue -Descriptor $cap }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = $check.reason; journalSeq = $jr.seq; steps = $steps.ToArray() }
        }
    } catch {
        $err = [string]$_.Exception.Message
        try { Restore-Nx05DescriptorValue -Descriptor $cap } catch { }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = $err; journalSeq = $jr.seq; steps = $steps.ToArray() }
    }

    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = "CrashDumpEnabled=DWord:$targetValue ($DumpType); restart required" })
    return [pscustomobject]@{
        tweakId    = $TweakId
        outcome    = 'Applied'
        dumpType   = $DumpType
        original   = $original
        modified   = $modified
        journalSeq = $jr.seq
        companions = $companions
        effectiveAt = 'NextRestart'
        warnings   = $warnings.ToArray()
        steps      = $steps.ToArray()
    }
}

# ----------------------------------------------------------------------------
# NX05-010 - pool limit configuration (TROUBLESHOOTING, E0)
# ----------------------------------------------------------------------------
function Set-NxPoolLimitConfiguration {
    <#
    .SYNOPSIS
        NX05-010: documented-symptom-gated kernel pool limit adjustment with
        per-value exact capture, verification and only-if-ours restore.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [int64]$PagedPoolSizeBytes = 0,
        [int64]$NonPagedPoolSizeBytes = 0,
        [int]$PoolUsageMaximum = 0,
        [string]$SymptomNote = '',
        [switch]$AcknowledgeSymptom,
        [string]$TweakId = 'NX05-010',
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [switch]$Approved
    )
    $steps = New-Object System.Collections.Generic.List[object]
    if (-not $Approved) { throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    if (-not $AcknowledgeSymptom) {
        throw "tweak ${TweakId}: refusing to change kernel pool limits without -AcknowledgeSymptom (TROUBLESHOOTING/E0: only against a documented symptom)"
    }
    if ($null -eq $SymptomNote -or $SymptomNote.Trim().Length -lt 10) {
        throw "tweak ${TweakId}: -SymptomNote must describe the documented symptom (at least 10 characters); pool changes without a named symptom are refused"
    }

    # ---- per-value validation ----
    $targets = New-Object System.Collections.Generic.List[object]
    if ($PoolUsageMaximum -ne 0) {
        if ($PoolUsageMaximum -lt 1 -or $PoolUsageMaximum -gt 100) { throw "poolUsageMaximum must be 1..100 (percent); got $PoolUsageMaximum" }
        $targets.Add([pscustomobject]@{ name = 'PoolUsageMaximum'; kind = 'DWord'; value = [int64]$PoolUsageMaximum; storedValue = [int64]$PoolUsageMaximum })
    }
    foreach ($spec in @(
        [pscustomobject]@{ name = 'PagedPoolSize'; value = $PagedPoolSizeBytes },
        [pscustomobject]@{ name = 'NonPagedPoolSize'; value = $NonPagedPoolSizeBytes }
    )) {
        if ($spec.value -eq 0) { continue }
        if ($spec.value -ne 4294967295 -and ($spec.value -lt 1048576 -or $spec.value -gt 4294967295)) {
            throw "$($spec.name) must be 0 (leave unchanged), 4294967295 (documented maximum) or 1048576..4294967295 bytes; got $($spec.value)"
        }
        $targets.Add([pscustomobject]@{
            name = $spec.name; kind = 'DWord'; value = [int64]$spec.value
            storedValue = (ConvertTo-Nx05DwordStored -Value ([int64]$spec.value))
        })
    }
    if ($targets.Count -eq 0) { throw "tweak ${TweakId}: no pool value selected (PoolUsageMaximum / PagedPoolSize / NonPagedPoolSize are all 0)" }

    Assert-Nx05JournalReady -JournalRoot $JournalRoot

    $originals = New-Object System.Collections.Generic.List[object]
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($t in $targets) {
        $d = Capture-NxRegistryValue -Path $script:Nx05MemoryPath -Name $t.name
        $originals.Add([pscustomobject]@{ name = $t.name; descriptor = $d })
        $already = ($d.existed -and ([string]$d.kind -eq 'DWord') -and ([int64]$d.value -eq [int64]$t.storedValue))
        if (-not $already) { $changes.Add($t) }
    }
    $steps.Add([pscustomobject]@{
        step = 2; name = 'capture-original'; outcome = 'Captured'
        detail = (($originals | ForEach-Object { "$($_.name): existed=$($_.descriptor.existed) value=$($_.descriptor.value)" }) -join '; ')
    })

    $original = [pscustomobject]@{
        targetType = 'poolState'
        symptomNote = $SymptomNote.Trim()
        values = $originals.ToArray()
        capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $modified = [pscustomobject]@{
        targetType = 'poolState'
        values = @($changes | ForEach-Object { [pscustomobject]@{ name = $_.name; kind = 'DWord'; value = $_.storedValue; requestedValue = $_.value } })
    }

    if ($changes.Count -eq 0) {
        $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'AlreadyApplied'; journalSeq = $skip.seq; steps = $steps.ToArray() }
    }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    $written = New-Object System.Collections.Generic.List[object]
    $verifiedAll = $true
    $reasons = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($c in $changes) {
            Set-Nx05ExactValue -Path $script:Nx05MemoryPath -Name $c.name -Kind 'DWord' -Value ([int64]$c.storedValue)
            $written.Add($c)
            $check = Test-NxConfigurationState -Path $script:Nx05MemoryPath -Name $c.name -Kind 'DWord' -ExpectedValue ([int64]$c.storedValue)
            if (-not $check.verified) { $verifiedAll = $false; $reasons.Add("$($c.name): $($check.reason)") }
        }
        if (-not $verifiedAll) {
            foreach ($w in $written) {
                $orig = @($originals | Where-Object { $_.name -eq $w.name })
                if ($orig.Count -gt 0) { try { Restore-Nx05DescriptorValue -Descriptor $orig[0].descriptor } catch { } }
            }
        }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verifiedAll) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verifiedAll) { 'Verified' } else { 'NotVerified' }) -ErrorInfo ($reasons -join '; ') -Profiles $Profiles | Out-Null
        if (-not $verifiedAll) {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo ($reasons -join '; ') -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = ($reasons -join '; '); journalSeq = $jr.seq; steps = $steps.ToArray() }
        }
    } catch {
        $err = [string]$_.Exception.Message
        foreach ($w in $written) {
            $orig = @($originals | Where-Object { $_.name -eq $w.name })
            if ($orig.Count -gt 0) { try { Restore-Nx05DescriptorValue -Descriptor $orig[0].descriptor } catch { } }
        }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; outcome = 'Failed'; reason = $err; journalSeq = $jr.seq; steps = $steps.ToArray() }
    }

    $steps.Add([pscustomobject]@{ step = 9; name = 'verify'; outcome = 'Verified'; detail = (($changes | ForEach-Object { if ($_.value -gt 2147483647) { "$($_.name)=$($_.value) (0x$('{0:X}' -f $_.value))" } else { "$($_.name)=$($_.value)" } }) -join ', ') })

    return [pscustomobject]@{
        tweakId    = $TweakId
        outcome    = 'Applied'
        original   = $original
        modified   = $modified
        journalSeq = $jr.seq
        symptomNote = $SymptomNote.Trim()
        effectiveAt = 'NextRestart'
        warnings   = @(
            'E0 evidence: the Microsoft article that documents these values is 32-bit Windows Server 2003-era and warns that PagedPoolSize=0xFFFFFFFF can exhaust free system PTEs. Configuration verified is not symptom resolution - that remains owner-verified.',
            'Restart required for the pool limits to be re-read.'
        )
        steps      = $steps.ToArray()
    }
}

# ----------------------------------------------------------------------------
# NX05-011 - memory diagnostics suite (read-only composition)
# ----------------------------------------------------------------------------
function Get-NxMemoryDiagnosticsReport {
    <#
    .SYNOPSIS
        NX05-011: composed read-only evidence set - MMAgent state, RAM modules,
        commit limit/charge, pagefile summary, pressure report, page-list report.
    #>
    [CmdletBinding()]
    param([string]$TweakId = 'NX05-011')
    $uncertainty = New-Object System.Collections.Generic.List[string]

    $mma = Get-Nx05MmAgentState
    foreach ($x in @($mma.uncertainty)) { $uncertainty.Add("MMAgent: $x") }

    $modules = New-Object System.Collections.Generic.List[object]
    $totalBytes = $null
    $mem = Get-Nx05CimData -ClassName 'Win32_PhysicalMemory'
    if ($mem.ok) {
        $sum = [int64]0
        foreach ($m in $mem.instances) {
            $cap = [int64]$m.Capacity
            $sum += $cap
            $modules.Add([pscustomobject]@{
                source = 'Win32_PhysicalMemory'
                capacityGB = [math]::Round(($cap / 1GB), 1)
                speedMHz = $m.Speed
                configuredClockSpeedMHz = $m.ConfiguredClockSpeed
                smbiosMemoryType = $m.SMBIOSMemoryType
                formFactor = $m.FormFactor
                bankLabel = [string]$m.BankLabel
                deviceLocator = [string]$m.DeviceLocator
            })
        }
        if ($sum -gt 0) { $totalBytes = $sum }
    } else {
        $uncertainty.Add("Win32_PhysicalMemory read failed: $($mem.error)")
    }
    $physTotalBytes = Get-Nx05TotalPhysicalMemoryBytes
    if ($null -eq $physTotalBytes) { $uncertainty.Add('Win32_ComputerSystem.TotalPhysicalMemory could not be read (installed-RAM total unknown).') }

    $pressure = Get-NxMemoryPressureReport -TweakId 'NX05-005'
    foreach ($x in @($pressure.uncertainty)) { $uncertainty.Add("NX05-005: $x") }
    $pageLists = Get-NxStandbyMemoryReport -TweakId 'NX05-006'
    foreach ($x in @($pageLists.uncertainty)) { $uncertainty.Add("NX05-006: $x") }

    $commitLimitBytes = $null
    $commitUsedBytes = $null
    if ($null -ne $pressure.commit) {
        $commitLimitBytes = [int64]$pressure.commit.limitKB * 1KB
        $commitUsedBytes = [int64]$pressure.commit.usedKB * 1KB
    } else {
        $uncertainty.Add('Commit limit/charge unavailable from Win32_OperatingSystem.')
    }

    return [pscustomobject]@{
        tweakId      = $TweakId
        readOnly     = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        mmAgent      = $mma
        ram          = [pscustomobject]@{
            totalBytes = $physTotalBytes
            totalGB = $(if ($null -ne $physTotalBytes) { [math]::Round($physTotalBytes / 1GB, 1) } else { $null })
            moduleSumBytes = $totalBytes
            modules = $modules.ToArray()
        }
        commit       = [pscustomobject]@{
            limitBytes = $commitLimitBytes
            usedBytes  = $commitUsedBytes
            usedPercent = $(if ($null -ne $pressure.commit) { $pressure.commit.usedPercent } else { $null })
            definition = 'Commit limit = physical memory + all page files (Microsoft page-file guidance); reported by Win32_OperatingSystem.TotalVirtualMemorySize.'
        }
        registryConfiguration = $pressure.registryConfiguration
        pageFileUsage = $pressure.pageFileUsage
        pageFileSettings = $pressure.pageFileSettings
        pressureReport = $pressure
        pageListReport = $pageLists
        noPerformanceClaim = $true
        uncertainty = $uncertainty.ToArray()
    }
}

# ----------------------------------------------------------------------------
# NX05 rollback engine (non-registry target types)
# ----------------------------------------------------------------------------
function Get-Nx05RollbackCandidates {
    # PURE selection logic: verified-success NX05 mutations only.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$JournalEntries)
    $restorable = @('pagefileState', 'mmAgentState', 'crashDumpState', 'poolState')
    return @($JournalEntries | Where-Object {
        $_.tweakId -like 'NX05-*' -and
        $_.operation -eq 'verify' -and $_.result -eq 'Success' -and $_.verification -eq 'Verified' -and
        ($restorable -contains [string]$_.original.targetType)
    })
}

function Invoke-Nx05Rollback {
    <#
    .SYNOPSIS
        NX05's own rollback replay for pagefileState / mmAgentState /
        crashDumpState / poolState entries. Integrity-gated, reverse order,
        only-if-ours, per-step journaled and verified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId,
        [switch]$AllNx05
    )
    if (-not $TweakId -and -not $AllNx05) {
        throw "Invoke-Nx05Rollback: specify -TweakId or -AllNx05 (no implicit full-category rollback)"
    }
    $journal = Read-NxJournal -Path $JournalRoot
    if (@($journal.integrityErrors).Count -gt 0) {
        return [pscustomobject]@{ aborted = $true; integrityErrors = $journal.integrityErrors; restored = @(); diverged = @(); failed = @(); irreversible = @() }
    }
    $candidates = @(Get-Nx05RollbackCandidates -JournalEntries $journal.entries)
    if ($TweakId) { $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId }) }
    [array]::Reverse($candidates)

    $restored = New-Object System.Collections.Generic.List[object]
    $diverged = New-Object System.Collections.Generic.List[object]
    $failed   = New-Object System.Collections.Generic.List[object]

    foreach ($e in $candidates) {
        $orig = $e.original; $mod = $e.modified
        $type = [string]$orig.targetType
        try {
            switch ($type) {
                'pagefileState' {
                    $live = Get-Nx05PagefileState
                    if (-not (Test-Nx05PagefileStateMatches -Live $live -Modified $mod)) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = 'pagefile configuration'; reason = "live state no longer equals the recorded modified state (mode '$($mod.mode)'): autoValue=$(if ($live.automaticManaged.existed) { $live.automaticManaged.value } else { 'absent' }), entries=$($live.entryCount) - left untouched" })
                        Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: live pagefile state differs from recorded modified state' -Profiles @($e.profiles) | Out-Null
                        break
                    }
                    Restore-Nx05DescriptorValue -Descriptor $orig.pagingFiles
                    Restore-Nx05DescriptorValue -Descriptor $orig.automaticManaged
                    $after = Get-Nx05PagefileState
                    $autoOk = Test-Nx05DescriptorEquals -Live $after.automaticManaged -Recorded $orig.automaticManaged
                    $pfOk = Test-Nx05DescriptorEquals -Live $after.pagingFiles -Recorded $orig.pagingFiles
                    $ok = ($autoOk -and $pfOk)
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles) | Out-Null
                    $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored pagefile configuration'; detail = "AutomaticManagedPagefile + PagingFiles restored exactly (autoOk=$autoOk pagingFilesOk=$pfOk); effective at next restart"; verified = $ok })
                }
                'mmAgentState' {
                    $live = Get-Nx05MmAgentState
                    $ours = ($live.available -and $null -ne $live.memoryCompression -and $live.memoryCompression -eq [bool]$mod.memoryCompression)
                    if (-not $ours) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = 'MMAgent MemoryCompression'; reason = "live Get-MMAgent MemoryCompression=$($live.memoryCompression) (recorded modified=$($mod.memoryCompression)) - left untouched" })
                        Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: MMAgent state differs from recorded modified state' -Profiles @($e.profiles) | Out-Null
                        break
                    }
                    if ([bool]$orig.memoryCompression) { Enable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null }
                    else { Disable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null }
                    $after = Get-Nx05MmAgentState
                    $ok = ($after.available -and $null -ne $after.memoryCompression -and $after.memoryCompression -eq [bool]$orig.memoryCompression)
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles) | Out-Null
                    $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored MMAgent MemoryCompression'; detail = "set to $($orig.memoryCompression) (verified=$ok)"; verified = $ok })
                }
                'crashDumpState' {
                    $liveDump = Capture-NxRegistryValue -Path $script:Nx05CrashControlPath -Name 'CrashDumpEnabled'
                    if (-not (Test-Nx05DescriptorEquals -Live $liveDump -Recorded ([pscustomobject]@{ existed = $true; kind = 'DWord'; value = [int]$mod.crashDumpEnabled }))) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = 'CrashControl :: CrashDumpEnabled'; reason = "live value '$($liveDump.value)' differs from recorded modified '$($mod.crashDumpEnabled)' - left untouched" })
                        Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: CrashDumpEnabled differs from recorded modified state' -Profiles @($e.profiles) | Out-Null
                        break
                    }
                    Restore-Nx05DescriptorValue -Descriptor $orig.crashDumpEnabled
                    $afterDump = Capture-NxRegistryValue -Path $script:Nx05CrashControlPath -Name 'CrashDumpEnabled'
                    $ok = Test-Nx05DescriptorEquals -Live $afterDump -Recorded $orig.crashDumpEnabled
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles) | Out-Null
                    $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored CrashDumpEnabled'; detail = "original value restored exactly; restart required to apply"; verified = $ok })
                }
                'poolState' {
                    $anyDiverged = $false
                    $restoreFail = New-Object System.Collections.Generic.List[string]
                    foreach ($v in @($mod.values)) {
                        $origEntry = @($orig.values | Where-Object { $_.name -eq $v.name })
                        if ($origEntry.Count -eq 0) { continue }
                        $liveValue = Capture-NxRegistryValue -Path $script:Nx05MemoryPath -Name $v.name
                        $ours = ($liveValue.existed -and [string]$liveValue.kind -eq 'DWord' -and [int64]$liveValue.value -eq [int64]$v.value)
                        if (-not $ours) {
                            $anyDiverged = $true
                            $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "$($v.name)"; reason = "live value '$($liveValue.value)' differs from recorded modified '$($v.value)' - left untouched" })
                            continue
                        }
                        Restore-Nx05DescriptorValue -Descriptor $origEntry[0].descriptor
                        $afterValue = Capture-NxRegistryValue -Path $script:Nx05MemoryPath -Name $v.name
                        if (-not (Test-Nx05DescriptorEquals -Live $afterValue -Recorded $origEntry[0].descriptor)) { $restoreFail.Add($v.name) }
                    }
                    $ok = ($restoreFail.Count -eq 0)
                    $result = 'Success'
                    if (-not $ok) { $result = 'FailedVerification' }
                    elseif ($anyDiverged) { $result = 'Success-PartialDivergence' }
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $result -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $(if ($restoreFail.Count -gt 0) { 'restore verification failed: ' + ($restoreFail -join ', ') } else { '' }) -Profiles @($e.profiles) | Out-Null
                    if ($ok) {
                        $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored pool limits'; detail = "per-value restore verified$(if ($anyDiverged) { ' (diverged values left untouched)' })"; verified = $ok })
                    } else {
                        $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = 'pool value restore verification failed: ' + ($restoreFail -join ', ') })
                    }
                }
                default {
                    $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = "unsupported NX05 rollback target type '$type'" })
                }
            }
        } catch {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'failed' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles @($e.profiles) | Out-Null
            $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = [string]$_.Exception.Message })
        }
    }

    return [pscustomobject]@{
        aborted    = $false
        restored   = $restored.ToArray()
        diverged   = $diverged.ToArray()
        failed     = $failed.ToArray()
        irreversible = @()
        integrityErrors = @()
    }
}
