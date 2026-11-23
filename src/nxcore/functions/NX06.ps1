#Requires -Version 5.1
<#
    NX06.ps1 - NEXTRIX Storage & Filesystem category functions (NX06-001..013).

    Dependencies: dot-source AFTER the core modules (Import-NxCore order):
      NxJournal.ps1  -> Capture-NxRegistryValue, Add-NxJournalEntry, Read-NxManifest
      NxVerify.ps1   -> Test-NxConfigurationState
      NxApply.ps1    -> Set-NxRegistryValue
      NxRollback.ps1 -> Restore-NxRegistryOriginal (best-effort restore on failed verify)
    This file defines functions only. Loading it performs no registry/CIM/service reads
    or writes and no network access.

    Pipeline contract (NxApply.ps1, directive Section 8 - no exceptions):
      capture exact original -> journal BEFORE mutation -> mutate -> verify -> journal.
    Registry mutations reached through this file journal targetType 'registry', so the
    shared rollback engine (NxRollback.ps1) restores them exactly (absent values are
    deleted, existing values are rewritten with their original kind). Mutations of
    other target types ('fsutilBehavior', 'scheduledTask') and irreversible deletions
    are restored/reported by Invoke-Nx06Rollback, which NxRollback.ps1 discovers by
    naming convention (Invoke-Nx<cc>Rollback).

    Safety boundaries (directive Section 16 + the NX06 workstream brief):
      - Never apply, clean up or delete anything on the development machine from tests.
        Production functions only run when the caller supplies -Approved (engine
        contract) and, for destructive cleanups, an explicit -Consent switch.
      - Cleanup functions are on-demand only: they report what would be deleted and
        delete nothing without consent. NEXTRIX never schedules a silent deletion.
      - Windows Update: wuauserv/BITS/UsoSvc are on the schema never-touch list. This
        file never disables them or changes their StartType. A temporary stop is
        possible only with -ConsentToTemporaryServiceStop, is journaled with the exact
        prior service states, and every stopped service is restarted in a finally
        block (failure to restart is reported, never hidden).
      - Plan-level power settings (SUB_DISK DISKIDLE, sleep/hibernate) are NX09's.
        NX06 only READS plan state for context and owns the storage-stack D3 policy
        (documented at HKLM\SYSTEM\CurrentControlSet\Control\Storage).
      - Component-store cleanup (/StartComponentCleanup, /ResetBase) is NX16-009.
        Nothing in this file touches the component store.
      - No performance claims: verification answers "does the recorded configuration
        hold?", never "is it faster" (TWEAK_CLASSIFICATION.md section 4).
#>

# ---------------------------------------------------------------------------
# 0. Constants and internal helpers (not exported as tweak actions)
# ---------------------------------------------------------------------------

$script:Nx06FileSystemKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$script:Nx06StorageSensePolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'
$script:Nx06StorageKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Storage'
$script:Nx06DefragTaskPath = '\Microsoft\Windows\Defrag\'
$script:Nx06DefragTaskName = 'ScheduledDefrag'
$script:Nx06FsutilNames = @('disabledeletenotify', 'disablelastaccess', 'disable8dot3', 'memoryusage')
# Documented persistence value names (fsutil behavior remarks name the keys it updates).
$script:Nx06FsutilRegistryMap = @{
    'disabledeletenotify' = 'NtfsDisableDeleteNotify'
    'disablelastaccess'   = 'NtfsDisableLastAccessUpdate'
    'disable8dot3'        = 'NtfsDisable8dot3NameCreation'
    'memoryusage'         = 'NtfsMemoryUsage'
}
# Storage Sense policy cadence values (Policy CSP - Storage, fetched 2026-11-23).
$script:Nx06StorageSenseCadence = @{ 'LowSpace' = 0; 'Daily' = 1; 'Weekly' = 7; 'Monthly' = 30 }

function Invoke-Nx06Native {
    # Wrapper for documented CLI tools (fsutil, powercfg). Output lines are captured
    # as data: native stderr must never become a terminating PowerShell error.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $lines = @()
    $code = -1
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    } catch {
        $lines = @([string]$_.Exception.Message)
        $code = -1
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{
        filePath  = $FilePath
        arguments = $Arguments
        exitCode  = $code
        lines     = $lines
        text      = ($lines -join "`n")
        succeeded = ($code -eq 0)
    }
}

function Get-Nx06FsutilExe {
    $p = Join-Path $env:SystemRoot 'System32\fsutil.exe'
    if (-not (Test-Path -LiteralPath $p)) { throw "fsutil.exe not found at '$p'" }
    return $p
}

function Assert-Nx06JournalReady {
    # No mutation without an initialized, capture-Complete journal (adopt register #2).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JournalRoot)
    if ([string]::IsNullOrWhiteSpace($JournalRoot)) {
        throw 'journal root not supplied - refusing to mutate (journal-first invariant)'
    }
    $state = Read-NxManifest -Path $JournalRoot
    if (-not $state.present) {
        throw "journal not initialized at '$JournalRoot' - refusing to mutate (journal-first invariant; run Invoke-NxPreFlight / NX16-004 first)"
    }
    if ([string]$state.manifest.captureStatus -ne 'Complete') {
        throw "journal captureStatus is '$($state.manifest.captureStatus)' - destructive steps refuse unless capture is Complete"
    }
}

function Invoke-Nx06RegistryWrite {
    <#
        Local journaled registry writer (NX01.ps1 defines an equivalent helper for its
        own category; this one is deliberately self-contained so NX06 can be dot-sourced
        alone - no cross-category function dependency, no name collision).
        Steps: capture -> idempotent skip -> journal -> write -> verify -> journal.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$TweakId,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')][string]$Kind,
        [Parameter(Mandatory)]$Value,
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @()
    )
    $target = "$Path :: $Name"
    $orig = Capture-NxRegistryValue -Path $Path -Name $Name
    $modified = [pscustomobject]@{ targetType = 'registry'; path = $Path; name = $Name; kind = $Kind; value = $Value }

    if (-not $PSCmdlet.ShouldProcess($target, "Set $Kind to the intended value")) {
        return [pscustomobject]@{ target = $target; changed = $false; verified = $false; journalSeq = $null; reason = 'WhatIf/Confirm: no mutation, no journal write' }
    }

    # Idempotency: desired state already present -> record a skip, never rewrite.
    if ($orig.existed -and ([string]$orig.kind -eq $Kind)) {
        $existing = ConvertTo-Json -InputObject $orig.value -Depth 6 -Compress
        $desired = ConvertTo-Json -InputObject $Value -Depth 6 -Compress
        if ($existing -eq $desired) {
            $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $orig -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
            return [pscustomobject]@{ target = $target; changed = $false; verified = $true; journalSeq = $skip.seq; reason = 'already in desired state' }
        }
    }

    $apply = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $orig -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Set-NxRegistryValue -Path $Path -Name $Name -Kind $Kind -Value $Value
        $check = Test-NxConfigurationState -Path $Path -Name $Name -Kind $Kind -ExpectedValue $Value
        if ($check.verified) {
            $ver = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $orig -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles $Profiles
            return [pscustomobject]@{ target = $target; changed = $true; verified = $true; journalSeq = $apply.seq; verifySeq = $ver.seq; reason = $check.reason }
        }
        try { Restore-NxRegistryOriginal -Entry ([pscustomobject]@{ original = $orig }) | Out-Null } catch { }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles
        return [pscustomobject]@{ target = $target; changed = $true; verified = $false; journalSeq = $apply.seq; reason = $check.reason }
    } catch {
        $err = [string]$_.Exception.Message
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles
        return [pscustomobject]@{ target = $target; changed = $false; verified = $false; journalSeq = $apply.seq; reason = "mutation failed: $err" }
    }
}

function New-Nx06Result {
    param(
        [string]$TweakId,
        [string]$Outcome = 'Report',
        [string]$Reason = '',
        [bool]$Verified = $false,
        $JournalSeq = $null,
        [string[]]$Warnings = @(),
        $Details = $null
    )
    return [pscustomobject]@{
        tweakId    = $TweakId
        outcome    = $Outcome
        reason     = $Reason
        verified   = $Verified
        journalSeq = $JournalSeq
        warnings   = @($Warnings)
        details    = $Details
    }
}

# ---------------------------------------------------------------------------
# 1. Storage inventory & classification (NX06-001) - read-only
# ---------------------------------------------------------------------------

function Get-NxStorageInventory {
    <#
    .SYNOPSIS
        NX06-001: read-only physical-disk / volume inventory with media classification.
    .DESCRIPTION
        Documented sources only: Get-PhysicalDisk (MediaType/BusType/HealthStatus),
        Get-Disk (partition style, boot/system flags) and Get-Volume. No WMI class is
        written; nothing is journaled. The classification feeds every storage-
        conditional decision in the playbook (TRIM applicability, D3 applicability).
        Uncertain values are reported as 'Unknown' with an uncertainty note - a
        missing read is never reported as "no SSD".
    #>
    [CmdletBinding()]
    param()
    $unc = New-Object System.Collections.Generic.List[string]
    $disks = New-Object System.Collections.Generic.List[object]
    $vols = New-Object System.Collections.Generic.List[object]

    $physical = @()
    try {
        $physical = @(Get-PhysicalDisk -ErrorAction Stop)
    } catch {
        $unc.Add("Get-PhysicalDisk failed: $($_.Exception.Message)")
    }
    $logical = @()
    try {
        $logical = @(Get-Disk -ErrorAction Stop)
    } catch {
        $unc.Add("Get-Disk failed: $($_.Exception.Message)")
    }

    foreach ($d in $physical) {
        $media = [string]$d.MediaType
        $bus = [string]$d.BusType
        $classification = 'unknown'
        if ($media -eq 'SSD' -and $bus -eq 'NVMe') { $classification = 'nvme-ssd' }
        elseif ($media -eq 'SSD') { $classification = 'ssd' }
        elseif ($media -eq 'HDD') { $classification = 'hdd' }
        elseif ($media -eq 'SCM') { $classification = 'scm' }
        elseif ($bus -eq 'USB') { $classification = 'usb' }
        elseif ($media -eq 'Unspecified') { $classification = 'unknown' }

        $logicalDisk = @($logical | Where-Object { [string]$_.Number -eq [string]$d.DeviceId })
        $isBoot = $null; $isSystem = $null; $partitionStyle = $null
        if ($logicalDisk.Count -gt 0) {
            $isBoot = [bool]$logicalDisk[0].IsBoot
            $isSystem = [bool]$logicalDisk[0].IsSystem
            $partitionStyle = [string]$logicalDisk[0].PartitionStyle
        }
        $disks.Add([pscustomobject][ordered]@{
            deviceId          = [string]$d.DeviceId
            friendlyName      = [string]$d.FriendlyName
            mediaType         = $media
            busType           = $bus
            classification    = $classification
            sizeBytes         = [int64]$d.Size
            healthStatus      = [string]$d.HealthStatus
            operationalStatus = (@($d.OperationalStatus | ForEach-Object { [string]$_ }) -join ',')
            isBoot            = $isBoot
            isSystem          = $isSystem
            partitionStyle    = $partitionStyle
            trimApplicable    = ($classification -in @('nvme-ssd', 'ssd', 'scm'))
            rotational        = ($classification -eq 'hdd')
        })
    }

    try {
        foreach ($v in @(Get-Volume -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace([string]$v.DriveLetter)) { continue }
            $vols.Add([pscustomobject][ordered]@{
                driveLetter     = [string]$v.DriveLetter
                fileSystemLabel = [string]$v.FileSystemLabel
                fileSystem      = [string]$v.FileSystem
                driveType       = [string]$v.DriveType
                sizeBytes       = [int64]$v.Size
                freeBytes       = [int64]$v.SizeRemaining
                healthStatus    = [string]$v.HealthStatus
            })
        }
    } catch {
        $unc.Add("Get-Volume failed: $($_.Exception.Message)")
    }

    $hasSolid = @($disks | Where-Object { $_.trimApplicable }).Count -gt 0
    $hasHdd = @($disks | Where-Object { $_.rotational }).Count -gt 0
    $hasNvme = @($disks | Where-Object { $_.busType -eq 'NVMe' }).Count -gt 0
    $systemDisk = @($disks | Where-Object { $_.isSystem -eq $true })[0]
    $totalBytes = 0; $totalFree = 0
    foreach ($x in $disks) { $totalBytes += [int64]$x.sizeBytes }
    foreach ($x in $vols) { $totalFree += [int64]$x.freeBytes }

    if ($physical.Count -eq 0) { $unc.Add('no physical disk was enumerated - classification is Unknown, not "no SSD"') }

    return [pscustomobject][ordered]@{
        functionName   = 'Get-NxStorageInventory'
        tweakId        = 'NX06-001'
        readOnly       = $true
        readSucceeded  = ($physical.Count -gt 0)
        generatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        physicalDisks  = $disks.ToArray()
        volumes        = $vols.ToArray()
        storageClasses = [pscustomobject][ordered]@{
            diskCount        = $disks.Count
            hasSolidState    = $hasSolid
            hasHdd           = $hasHdd
            hasNvme          = $hasNvme
            systemDiskNumber = $(if ($null -ne $systemDisk) { $systemDisk.deviceId } else { $null })
            totalDiskBytes   = $totalBytes
            totalVolumeFree  = $totalFree
        }
        uncertainty    = $unc.ToArray()
        classificationNotes = @(
            'MediaType and BusType come from the documented MSFT_PhysicalDisk properties; Unspecified stays Unknown.',
            'trimApplicable marks SSD/SCM media only. Rotational media ignore unmap/trim (documented fsutil behavior).',
            'Plan-level disk idle (SUB_DISK DISKIDLE) is NX09 territory; this report does not read or write power plans.'
        )
    }
}

# ---------------------------------------------------------------------------
# 2. NTFS behavior (fsutil) - shared reader/parser for NX06-002/008/009/010
# ---------------------------------------------------------------------------

function ConvertFrom-Nx06FsutilOutput {
    <#
    .SYNOPSIS
        Pure parser for documented `fsutil behavior query` output (unit-testable).
    .DESCRIPTION
        Locale tolerance: only the value tokens and numbers are matched. A line that
        cannot be recognized leaves recognized=false so callers can refuse instead of
        guessing (fail-closed, mirroring the NX09 powercfg parser).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('disabledeletenotify', 'disablelastaccess', 'disable8dot3', 'memoryusage')][string]$Name,
        [string[]]$Lines = @()
    )
    $text = ($Lines -join "`n")
    $out = [ordered]@{
        name       = $Name
        raw        = $text
        recognized = $false
        parsed     = $null
        semantic   = 'Unknown'
        entries    = @()
        extra      = @{}
    }

    if ($Name -eq 'disabledeletenotify') {
        $entries = New-Object System.Collections.Generic.List[object]
        foreach ($l in $Lines) {
            $m = [regex]::Match($l, '(?i)(NTFS|ReFS)\s+DisableDeleteNotify\s*=\s*(-?\d+)')
            if ($m.Success) {
                $val = [int]$m.Groups[2].Value
                $entries.Add([pscustomobject]@{ fileSystem = $m.Groups[1].Value; value = $val; state = $(if ($val -eq 0) { 'TrimEnabled' } else { 'TrimDisabled' }) })
                continue
            }
            $m2 = [regex]::Match($l, '(?i)(NTFS|ReFS)\s+DisableDeleteNotify\s+is\s+not\s+currently\s+set')
            if ($m2.Success) {
                $entries.Add([pscustomobject]@{ fileSystem = $m2.Groups[1].Value; value = $null; state = 'NotConfigured' })
            }
        }
        $ntfs = @($entries | Where-Object { $_.fileSystem -eq 'NTFS' })
        $out.entries = $entries.ToArray()
        if ($ntfs.Count -gt 0) {
            $out.recognized = $true
            if ($null -ne $ntfs[0].value) {
                $out.parsed = [int]$ntfs[0].value
                $out.semantic = $(if ([int]$ntfs[0].value -eq 0) { 'TrimEnabled' } else { 'TrimDisabled' })
            } else {
                $out.semantic = 'TrimEnabled'   # documented default: NTFS trim enabled
            }
        }
    } elseif ($Name -eq 'disablelastaccess') {
        $m = [regex]::Match($text, '(?i)DisableLastAccess\s*=\s*(-?\d+)')
        if ($m.Success) {
            $rawVal = [int64]$m.Groups[1].Value
            # fsutil prints the low value and states the management mode in the
            # parenthetical ("User Managed" / "System Managed"); on some builds the
            # printed number keeps the high bit. Read the text first, fall back to bit 31.
            $userManaged = (($rawVal -band [int64]0x80000000) -ne 0)
            if ($text -match '(?i)user\s+managed') { $userManaged = $true }
            elseif ($text -match '(?i)system\s+managed') { $userManaged = $false }
            $flag = [int64]($rawVal -band [int64]0x7FFFFFFF)
            $out.recognized = $true
            $out.parsed = [int]$flag
            $out.semantic = $(if ($flag -eq 1) { 'Disabled' } elseif ($flag -eq 0) { 'Enabled' } else { 'Unknown' })
            $out.extra = @{ userManaged = $userManaged; rawValue = $rawVal }
        }
    } elseif ($Name -eq 'disable8dot3') {
        $mReg = [regex]::Match($text, '(?i)registry state is:\s*(-?\d+)')
        $mVol = [regex]::Match($text, '(?i)volume state is:\s*(-?\d+)')
        $mEff = [regex]::Match($text, '(?i)8dot3 name creation is\s+(DISABLED|ENABLED)')
        if ($mReg.Success) {
            $out.recognized = $true
            $out.parsed = [int]$mReg.Groups[1].Value
            $out.extra = @{
                registryState = [int]$mReg.Groups[1].Value
                volumeState   = $(if ($mVol.Success) { [int]$mVol.Groups[1].Value } else { $null })
                effective     = $(if ($mEff.Success) { $mEff.Groups[1].Value } else { $null })
            }
            $out.semantic = $(if ($mEff.Success) { $(if ($mEff.Groups[1].Value -eq 'DISABLED') { 'Disabled' } else { 'Enabled' }) } else { 'Unknown' })
        }
    } elseif ($Name -eq 'memoryusage') {
        $m = [regex]::Match($text, '(?i)MemoryUsage\s*=\s*(-?\d+)')
        if ($m.Success) {
            $val = [int]$m.Groups[1].Value
            $out.recognized = $true
            $out.parsed = $val
            # Query output on current builds reports 0 for the documented default (1).
            $out.semantic = $(if ($val -eq 2) { 'Increased' } elseif ($val -eq 0 -or $val -eq 1) { 'Default' } else { 'Unknown' })
        }
    }
    return [pscustomobject]$out
}

function Get-NxNtfsBehaviorState {
    <#
    .SYNOPSIS
        Read-only state of the four NTFS behavior settings NX06 manages.
    .DESCRIPTION
        Runs the documented `fsutil behavior query` forms plus a `fsutil 8dot3name
        query` per volume, and records the documented persistence registry values
        (fsutil's own remarks name the values it updates). Every raw output is kept so
        an unparsed locale never becomes a silent guess.
    #>
    [CmdletBinding()]
    param([switch]$SkipVolumes)
    $unc = New-Object System.Collections.Generic.List[string]
    $state = [ordered]@{}
    $fsutil = $null
    try { $fsutil = Get-Nx06FsutilExe } catch { $unc.Add([string]$_.Exception.Message) }

    foreach ($name in $script:Nx06FsutilNames) {
        $query = $null
        if ($null -ne $fsutil) {
            $query = Invoke-Nx06Native -FilePath $fsutil -Arguments @('behavior', 'query', $name)
        }
        $parsed = $null
        if ($null -ne $query) {
            $parsed = ConvertFrom-Nx06FsutilOutput -Name $name -Lines $query.lines
        } else {
            $parsed = ConvertFrom-Nx06FsutilOutput -Name $name -Lines @()
        }
        $regName = $script:Nx06FsutilRegistryMap[$name]
        $reg = $null
        if ($regName) { $reg = Capture-NxRegistryValue -Path $script:Nx06FileSystemKey -Name $regName }
        if (-not $parsed.recognized) {
            $unc.Add("fsutil behavior query $name output not recognized - value reported Unknown (raw output retained)")
        }
        $state[$name] = [pscustomobject][ordered]@{
            name         = $name
            queryExitCode = $(if ($null -ne $query) { $query.exitCode } else { $null })
            raw          = $parsed.raw
            recognized   = $parsed.recognized
            value        = $parsed.parsed
            semantic     = $parsed.semantic
            entries      = $parsed.entries
            extra        = $parsed.extra
            registryName = $regName
            registry     = $reg
        }
    }

    $volumes = @()
    if (-not $SkipVolumes -and $null -ne $fsutil) {
        $volList = @()
        try {
            $volList = @(Get-Volume -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.DriveLetter) })
        } catch { $unc.Add("Get-Volume failed for per-volume 8.3 report: $($_.Exception.Message)") }
        foreach ($v in $volList) {
            $letter = "$($v.DriveLetter):"
            $q = Invoke-Nx06Native -FilePath $fsutil -Arguments @('behavior', 'query', 'disable8dot3', $letter)
            $p = ConvertFrom-Nx06FsutilOutput -Name 'disable8dot3' -Lines $q.lines
            $volumes += [pscustomobject][ordered]@{
                volumePath    = $letter
                fileSystem    = [string]$v.FileSystem
                sizeBytes     = [int64]$v.Size
                raw           = $p.raw
                recognized    = $p.recognized
                registryState = $(if ($p.extra.ContainsKey('registryState')) { $p.extra['registryState'] } else { $null })
                volumeState   = $(if ($p.extra.ContainsKey('volumeState')) { $p.extra['volumeState'] } else { $null })
                effective     = $(if ($p.extra.ContainsKey('effective')) { $p.extra['effective'] } else { $null })
            }
        }
    }

    return [pscustomobject][ordered]@{
        functionName    = 'Get-NxNtfsBehaviorState'
        readOnly        = $true
        generatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        fileSystemKey   = $script:Nx06FileSystemKey
        disabledeletenotify = $state['disabledeletenotify']
        disablelastaccess   = $state['disablelastaccess']
        disable8dot3        = $state['disable8dot3']
        memoryusage         = $state['memoryusage']
        volumes         = $volumes
        uncertainty     = $unc.ToArray()
    }
}

function Set-Nx06FsutilBehavior {
    # Runs the documented `fsutil behavior set` form and returns the raw result.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('disabledeletenotify', 'disablelastaccess', 'disable8dot3', 'memoryusage')][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    $fsutil = Get-Nx06FsutilExe
    return Invoke-Nx06Native -FilePath $fsutil -Arguments @('behavior', 'set', $Name, $Value)
}

function Restore-Nx06FsutilOriginal {
    <#
        Exact-original restore used by apply safe-stop and Invoke-Nx06Rollback.

        Order matters for byte-exactness: the documented persistence value is restored
        first (rewritten with its original kind, or deleted when it did not exist -
        the common "default enabled" state). Only when the registry restore is not
        possible, or the live semantic still disagrees with the recorded original, does
        the documented fsutil command run - that command always re-encodes the value as
        "user managed", so it is the fallback, never the first choice.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Original)
    $actions = New-Object System.Collections.Generic.List[string]
    $reg = $Original.registry
    $registryName = [string]$Original.registryName
    if ([string]::IsNullOrWhiteSpace($registryName) -and $null -ne $reg) { $registryName = [string]$reg.name }
    $registryRestored = $false
    if ($null -ne $reg -and -not [string]::IsNullOrWhiteSpace($registryName)) {
        $path = $script:Nx06FileSystemKey
        $name = $registryName
        try {
            if ($reg.existed) {
                Set-NxRegistryValue -Path $path -Name $name -Kind ([string]$reg.kind) -Value $reg.value
                $actions.Add("registry restored: $name = $($reg.kind):$($reg.value)")
            } else {
                if (Test-Path $path) {
                    $live = Capture-NxRegistryValue -Path $path -Name $name
                    if ($live.existed) { Remove-ItemProperty -Path $path -Name $name -ErrorAction Stop }
                }
                $actions.Add("registry restored: $name absent (as before apply)")
            }
            $registryRestored = $true
        } catch {
            $actions.Add("registry restore failed for ${name}: $($_.Exception.Message)")
        }
    }

    $semantic = $null
    if ($null -ne $Original.value) { $semantic = [string]$Original.value }
    if ($null -ne $semantic) {
        $needFsutil = (-not $registryRestored)
        if (-not $needFsutil) {
            try {
                $liveState = Get-NxNtfsBehaviorState -SkipVolumes
                $prop = $liveState.PSObject.Properties[[string]$Original.name]
                if ($null -eq $prop -or -not $prop.Value.recognized) { $needFsutil = $true }
                elseif ($null -ne $prop.Value.value -and [int]$prop.Value.value -ne [int]$semantic) { $needFsutil = $true }
            } catch {
                $needFsutil = $true
                $actions.Add("semantic re-read failed: $($_.Exception.Message)")
            }
        }
        if ($needFsutil) {
            try {
                $r = Set-Nx06FsutilBehavior -Name ([string]$Original.name) -Value $semantic
                $actions.Add("fsutil behavior set $($Original.name) $semantic -> exit $($r.exitCode)")
            } catch {
                $actions.Add("fsutil restore failed: $($_.Exception.Message)")
            }
        } else {
            $actions.Add("fsutil set not needed: registry restore reproduced the original semantic")
        }
    }
    return $actions.ToArray()
}

function Add-Nx06SkipEntry {
    # Idempotent-skip journaling that is harmless when no journal is armed yet
    # (an already-correct configuration needs no mutation, so refusing to report it
    # would be worse than recording nothing).
    [CmdletBinding()]
    param(
        [string]$JournalRoot,
        [Parameter(Mandatory)][string]$TweakId,
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [Parameter(Mandatory)]$Original,
        [Parameter(Mandatory)]$Modified,
        [string[]]$Profiles = @()
    )
    if ([string]::IsNullOrWhiteSpace($JournalRoot)) { return $null }
    $state = Read-NxManifest -Path $JournalRoot
    if (-not $state.present) { return $null }
    return Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $Original -Modified $Modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
}

# ---------------------------------------------------------------------------
# 3. NX06-002 - TRIM enable & verification
# ---------------------------------------------------------------------------

function Set-NxTrimEnabled {
    <#
    .SYNOPSIS
        NX06-002: ensure NTFS delete notification (TRIM/unmap) is enabled, journaled.
    .DESCRIPTION
        Documented command: `fsutil behavior set disabledeletenotify 0` (NTFS default
        is enabled). Applicability is hardware-gated: on a machine with no SSD/SCM
        media the entry skips with a reason (rotational media ignore trim; the
        SapphireOS "TRIM off on HDD" pair is deliberately NOT adopted - r3).
        Original capture records the raw fsutil output, the parsed NTFS/ReFS values and
        the undocumented-but-observed persistence value (NtfsDisableDeleteNotify) so
        rollback can restore exact presence/absence as well as the semantic.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Enable', 'Report')][string]$Mode = 'Enable',
        [switch]$Approved,
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$TweakId = 'NX06-002'
    )
    $warnings = @(
        'TRIM/unmap is a no-op on rotational media: the device ignores the command. Disabling it on an HDD (the SapphireOS SSD/HDD pair, r3) has no documented benefit and is not adopted.',
        'Microsoft documents that some devices can degrade with delete notification enabled; the change is fully reversible - roll back NX06-002 to restore the exact prior state.',
        'No restart is required for this setting (documented); TRIM takes effect on the next unmap command.'
    )
    $inv = Get-NxStorageInventory
    $state = Get-NxNtfsBehaviorState -SkipVolumes
    $trim = $state.disabledeletenotify

    if (-not $inv.readSucceeded) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Refused' -Reason "storage inventory unreadable: $($inv.uncertainty -join '; ')" -Warnings $warnings -Details ([pscustomobject]@{ inventory = $inv; trimState = $trim })
    }
    if (-not $inv.storageClasses.hasSolidState) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Skipped' -Reason 'no SSD/SCM media detected - TRIM is not applicable to rotational-only storage' -Warnings $warnings -Details ([pscustomobject]@{ inventory = $inv; trimState = $trim })
    }
    if ($Mode -eq 'Report' -or -not $Approved) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason "current NTFS delete-notification state: $($trim.semantic) (parsed value $($trim.value)); nothing written (report mode or approval missing)" -Warnings $warnings -Details ([pscustomobject]@{ inventory = $inv; trimState = $trim })
    }
    if (-not $trim.recognized) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Refused' -Reason 'fsutil behavior query disabledeletenotify output not recognized - no capture means no mutation' -Warnings $warnings -Details ([pscustomobject]@{ trimState = $trim })
    }
    if ($null -ne $trim.value -and [int]$trim.value -eq 0) {
        $null = Add-Nx06SkipEntry -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Original ([pscustomobject]@{ targetType = 'fsutilBehavior'; name = 'disabledeletenotify'; value = $trim.value; registry = $trim.registry }) -Modified ([pscustomobject]@{ targetType = 'fsutilBehavior'; name = 'disabledeletenotify'; value = 0 }) -Profiles $Profiles
        return New-Nx06Result -TweakId $TweakId -Outcome 'AlreadyApplied' -Reason 'NTFS delete notification is already enabled' -Verified $true -Warnings $warnings -Details ([pscustomobject]@{ trimState = $trim })
    }

    Assert-Nx06JournalReady -JournalRoot $JournalRoot
    $original = [pscustomobject][ordered]@{
        targetType = 'fsutilBehavior'
        name       = 'disabledeletenotify'
        value      = $trim.value
        semantic   = $trim.semantic
        raw        = $trim.raw
        entries    = $trim.entries
        registryName = $trim.registryName
        registry   = $trim.registry
    }
    $modified = [pscustomobject][ordered]@{
        targetType = 'fsutilBehavior'
        name       = 'disabledeletenotify'
        value      = 0
        semantic   = 'TrimEnabled'
        command    = 'fsutil behavior set disabledeletenotify 0'
    }
    if (-not $PSCmdlet.ShouldProcess('NTFS delete notification', 'Enable TRIM (fsutil behavior set disabledeletenotify 0)')) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'WhatIf: no mutation, no journal write' -Warnings $warnings
    }
    $apply = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        $run = Set-Nx06FsutilBehavior -Name 'disabledeletenotify' -Value '0'
        $after = Get-NxNtfsBehaviorState -SkipVolumes
        $ok = ($after.disabledeletenotify.recognized -and $after.disabledeletenotify.semantic -eq 'TrimEnabled')
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified ([pscustomobject]@{ targetType = 'fsutilBehavior'; name = 'disabledeletenotify'; value = 0; semantic = 'TrimEnabled'; observed = $after.disabledeletenotify.semantic; observedValue = $after.disabledeletenotify.value; exitCode = $run.exitCode }) -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $(if ($ok) { '' } else { $run.text }) -Profiles $Profiles
        if (-not $ok) {
            $restore = Restore-Nx06FsutilOriginal -Original $original
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo ("post-set query did not report TrimEnabled; restore: " + ($restore -join '; ')) -Profiles $Profiles
            return New-Nx06Result -TweakId $TweakId -Outcome 'Failed' -Reason 'TRIM state did not verify after fsutil set; best-effort exact restore attempted' -Warnings $warnings -Details ([pscustomobject]@{ fsutil = $run; after = $after.disabledeletenotify; restore = $restore })
        }
        return New-Nx06Result -TweakId $TweakId -Outcome 'Applied' -Reason "NTFS delete notification enabled (observed $($after.disabledeletenotify.semantic))" -Verified $true -JournalSeq $apply.seq -Warnings $warnings -Details ([pscustomobject]@{ fsutil = $run; after = $after.disabledeletenotify })
    } catch {
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
        return New-Nx06Result -TweakId $TweakId -Outcome 'Failed' -Reason ([string]$_.Exception.Message) -Warnings $warnings
    }
}

# ---------------------------------------------------------------------------
# 4. NX06-003 - Optimize Drives (ScheduledDefrag) schedule configuration
# ---------------------------------------------------------------------------

function Get-NxOptimizeDrivesState {
    <#
    .SYNOPSIS
        NX06-003 read-only state: task state, maintenance schedule, last run result.
    .DESCRIPTION
        The Windows 11 Optimize Drives task is a maintenance task (MaintenanceSettings
        Period/Deadline, no triggers on a stock machine). This report never enables,
        disables or rewrites anything. Plan-level disk idle is NX09's and is not read
        here.
    #>
    [CmdletBinding()]
    param()
    $unc = New-Object System.Collections.Generic.List[string]
    $out = [ordered]@{
        functionName = 'Get-NxOptimizeDrivesState'
        readOnly     = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        taskPath     = $script:Nx06DefragTaskPath
        taskName     = $script:Nx06DefragTaskName
        present      = $false
        state        = $null
        enabled      = $null
        maintenancePeriod = $null
        maintenanceDeadline = $null
        maintenanceExclusive = $null
        triggerCount = $null
        triggers     = @()
        actionCommand = $null
        actionArguments = $null
        lastRunTime  = $null
        lastRunResult = $null
        nextRunTime  = $null
        xml          = $null
        uncertainty  = @()
    }
    $tm = Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue
    if ($null -eq $tm) {
        $unc.Add('ScheduledTasks module unavailable - task state Unknown (fail-closed)')
        $out.uncertainty = $unc.ToArray()
        return [pscustomobject]$out
    }
    try {
        $task = Get-ScheduledTask -TaskPath $script:Nx06DefragTaskPath -TaskName $script:Nx06DefragTaskName -ErrorAction Stop
        $out.present = $true
        $out.state = [string]$task.State
        $out.enabled = $(if ($null -ne $task.Settings) { [bool]$task.Settings.Enabled } else { $null })
        if ($null -ne $task.Settings -and $null -ne $task.Settings.MaintenanceSettings) {
            $out.maintenancePeriod = [string]$task.Settings.MaintenanceSettings.Period
            $out.maintenanceDeadline = [string]$task.Settings.MaintenanceSettings.Deadline
            $out.maintenanceExclusive = [bool]$task.Settings.MaintenanceSettings.Exclusive
        } else {
            $unc.Add('task has no MaintenanceSettings (trigger-based schedule or non-stock task)')
        }
        $triggers = @($task.Triggers)
        $out.triggerCount = $triggers.Count
        $out.triggers = @($triggers | ForEach-Object {
            [pscustomobject]@{
                type          = $_.CimClass.CimClassName
                startBoundary = $(if ($_.PSObject.Properties['StartBoundary']) { [string]$_.StartBoundary } else { $null })
                daysInterval  = $(if ($_.PSObject.Properties['DaysInterval']) { $_.DaysInterval } else { $null })
                weeksInterval = $(if ($_.PSObject.Properties['WeeksInterval']) { $_.WeeksInterval } else { $null })
                daysOfWeek    = $(if ($_.PSObject.Properties['DaysOfWeek']) { [string]$_.DaysOfWeek } else { $null })
            }
        })
        if ($null -ne $task.Actions -and @($task.Actions).Count -gt 0) {
            $out.actionCommand = [string]$task.Actions[0].Execute
            $out.actionArguments = [string]$task.Actions[0].Arguments
        }
        try {
            $info = Get-ScheduledTaskInfo -TaskPath $script:Nx06DefragTaskPath -TaskName $script:Nx06DefragTaskName -ErrorAction Stop
            $out.lastRunTime = $info.LastRunTime
            $out.lastRunResult = $info.LastTaskResult
            $out.nextRunTime = $info.NextRunTime
        } catch { $unc.Add("Get-ScheduledTaskInfo failed: $($_.Exception.Message)") }
        try { $out.xml = Export-ScheduledTask -TaskPath $script:Nx06DefragTaskPath -TaskName $script:Nx06DefragTaskName -ErrorAction Stop } catch { $unc.Add("Export-ScheduledTask failed: $($_.Exception.Message)") }
    } catch {
        $out.present = $false
        $unc.Add("Get-ScheduledTask failed: $($_.Exception.Message)")
    }
    $out.uncertainty = $unc.ToArray()
    return [pscustomobject]$out
}

function Set-NxOptimizeDrivesSchedule {
    <#
    .SYNOPSIS
        NX06-003: set the documented Optimize Drives maintenance schedule; optionally
        re-enable a disabled task (opt-in, never silently).
    .DESCRIPTION
        Applies through Set-ScheduledTask -Settings on the live task object: only
        MaintenanceSettings.Period/Deadline (and Settings.Enabled when -EnableTask is
        given) change. Triggers, actions, principal and every other setting are left
        untouched. The full original task XML is journaled for exact restore; NEXTRIX
        never disables the task and never rewrites a trigger-based schedule.
        Background: reference projects disable ScheduledDefrag (Sapphire r3 line 367);
        ReviOS' ledger records `defrag` breakage from unrelated service changes (r2).
        This entry is the inversion: keep the OS task healthy and explicit.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Weekly', 'Monthly')][string]$Cadence = 'Weekly',
        [switch]$EnableTask,
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$TweakId = 'NX06-003'
    )
    $warnings = @(
        'This entry never disables the Optimize Drives task; disabling it is not offered by NEXTRIX.',
        'The maintenance schedule controls when Windows optimizes/retrims volumes. No performance outcome is claimed: the entry records configuration intent only.',
        'Per-volume optimization history and media type are reported; forcing a defrag/retrim run is not part of this action.'
    )
    $st = Get-NxOptimizeDrivesState
    if (-not $st.present) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Skipped' -Reason "Optimize Drives task not present ($($st.uncertainty -join '; ')) - NEXTRIX never recreates Microsoft tasks from scratch" -Warnings $warnings -Details $st
    }
    if ($null -eq $st.maintenancePeriod) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Skipped' -Reason 'task has no MaintenanceSettings (trigger-based schedule) - NEXTRIX does not rewrite trigger-based Microsoft task schedules; report only' -Warnings $warnings -Details $st
    }
    $desiredPeriod = $(if ($Cadence -eq 'Monthly') { 'P1M' } else { 'P7D' })
    $desiredDeadline = 'P1M'
    $desiredEnabled = $st.enabled
    if ($EnableTask) { $desiredEnabled = $true }

    $scheduleChanged = ($st.maintenancePeriod -ne $desiredPeriod) -or ($st.maintenanceDeadline -ne $desiredDeadline)
    $enabledChanged = ($desiredEnabled -ne $st.enabled)
    if (-not $scheduleChanged -and -not $enabledChanged) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'AlreadyApplied' -Reason "task already enabled=$($st.enabled) with Period=$($st.maintenancePeriod) Deadline=$($st.maintenanceDeadline)" -Verified $true -Warnings $warnings -Details $st
    }
    if (-not $Approved) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason "would set Period=$desiredPeriod Deadline=$desiredDeadline enabled=$desiredEnabled (approval missing; nothing written)" -Warnings $warnings -Details $st
    }
    Assert-Nx06JournalReady -JournalRoot $JournalRoot
    if (-not $PSCmdlet.ShouldProcess("$($script:Nx06DefragTaskPath)$($script:Nx06DefragTaskName)", "Set maintenance schedule Period=$desiredPeriod Deadline=$desiredDeadline enabled=$desiredEnabled")) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'WhatIf: no mutation, no journal write' -Warnings $warnings -Details $st
    }

    $original = [pscustomobject][ordered]@{
        targetType          = 'scheduledTask'
        taskPath            = $script:Nx06DefragTaskPath
        taskName            = $script:Nx06DefragTaskName
        state               = $st.state
        enabled             = $st.enabled
        maintenancePeriod   = $st.maintenancePeriod
        maintenanceDeadline = $st.maintenanceDeadline
        triggerCount        = $st.triggerCount
        xml                 = $st.xml
    }
    $modified = [pscustomobject][ordered]@{
        targetType          = 'scheduledTask'
        taskPath            = $script:Nx06DefragTaskPath
        taskName            = $script:Nx06DefragTaskName
        enabled             = $desiredEnabled
        maintenancePeriod   = $desiredPeriod
        maintenanceDeadline = $desiredDeadline
        method              = 'Set-ScheduledTask -Settings (MaintenanceSettings only)'
    }
    $apply = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        $task = Get-ScheduledTask -TaskPath $script:Nx06DefragTaskPath -TaskName $script:Nx06DefragTaskName -ErrorAction Stop
        $settings = $task.Settings
        $settings.MaintenanceSettings.Period = $desiredPeriod
        $settings.MaintenanceSettings.Deadline = $desiredDeadline
        if ($null -ne $desiredEnabled) { $settings.Enabled = [bool]$desiredEnabled }
        Set-ScheduledTask -TaskPath $script:Nx06DefragTaskPath -TaskName $script:Nx06DefragTaskName -Settings $settings -ErrorAction Stop | Out-Null

        $after = Get-NxOptimizeDrivesState
        $ok = ($after.present -and $after.maintenancePeriod -eq $desiredPeriod -and $after.maintenanceDeadline -eq $desiredDeadline)
        if ($null -ne $desiredEnabled) { $ok = $ok -and ([bool]$after.enabled -eq [bool]$desiredEnabled) }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified ([pscustomobject]@{ targetType = 'scheduledTask'; enabled = $after.enabled; maintenancePeriod = $after.maintenancePeriod; maintenanceDeadline = $after.maintenanceDeadline; state = $after.state }) -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles
        if (-not $ok) {
            $restoreNote = 'best-effort restore skipped: original XML not re-registered automatically after a failed verify (re-run rollback NX06-003 to restore the journaled XML)'
            try {
                if ($st.xml) { Register-ScheduledTask -TaskPath $script:Nx06DefragTaskPath -TaskName $script:Nx06DefragTaskName -Xml $st.xml -Force -ErrorAction Stop | Out-Null; $restoreNote = 'original XML re-registered' }
            } catch { $restoreNote = "original XML restore failed: $($_.Exception.Message)" }
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $restoreNote -Profiles $Profiles
            return New-Nx06Result -TweakId $TweakId -Outcome 'Failed' -Reason "schedule did not verify after apply; $restoreNote" -Warnings $warnings -Details ([pscustomobject]@{ before = $st; after = $after })
        }
        return New-Nx06Result -TweakId $TweakId -Outcome 'Applied' -Reason "Period=$($after.maintenancePeriod) Deadline=$($after.maintenanceDeadline) enabled=$($after.enabled) state=$($after.state)" -Verified $true -JournalSeq $apply.seq -Warnings $warnings -Details ([pscustomobject]@{ before = $st; after = $after })
    } catch {
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
        return New-Nx06Result -TweakId $TweakId -Outcome 'Failed' -Reason ([string]$_.Exception.Message) -Warnings $warnings -Details $st
    }
}

# ---------------------------------------------------------------------------
# 5. NX06-004 - Storage Sense policy (documented ADMX/CSP values)
# ---------------------------------------------------------------------------

function Get-NxStorageSenseState {
    <#
    .SYNOPSIS
        NX06-004 read-only state: documented Storage Sense policies plus the per-user
        toggle (read-only, community-known, labeled as such).
    #>
    [CmdletBinding()]
    param()
    $names = @('AllowStorageSenseGlobal', 'ConfigStorageSenseGlobalCadence', 'AllowStorageSenseTemporaryFilesCleanup', 'ConfigStorageSenseRecycleBinCleanupThreshold', 'ConfigStorageSenseDownloadsCleanupThreshold')
    $policies = New-Object System.Collections.Generic.List[object]
    foreach ($n in $names) {
        $cap = Capture-NxRegistryValue -Path $script:Nx06StorageSensePolicyKey -Name $n
        $policies.Add([pscustomobject]@{ name = $n; existed = $cap.existed; kind = $cap.kind; value = $cap.value })
    }
    $userKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
    $userToggle = Capture-NxRegistryValue -Path $userKey -Name '01'
    $cadenceMeaning = $null
    $cadenceCap = @($policies | Where-Object { $_.name -eq 'ConfigStorageSenseGlobalCadence' })[0]
    if ($cadenceCap.existed) {
        switch ([int]$cadenceCap.value) {
            0 { $cadenceMeaning = 'During low free disk space' }
            1 { $cadenceMeaning = 'Daily' }
            7 { $cadenceMeaning = 'Weekly' }
            30 { $cadenceMeaning = 'Monthly' }
            default { $cadenceMeaning = "Unrecognized cadence value $($cadenceCap.value)" }
        }
    }
    return [pscustomobject][ordered]@{
        functionName   = 'Get-NxStorageSenseState'
        readOnly       = $true
        generatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        policyKey      = $script:Nx06StorageSensePolicyKey
        policies       = $policies.ToArray()
        cadenceMeaning = $cadenceMeaning
        userToggle     = [pscustomobject]@{ path = $userKey; name = '01'; existed = $userToggle.existed; value = $userToggle.value; note = 'per-user Settings toggle, undocumented value name (reported read-only, never written)' }
        documentation  = 'https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-storage'
    }
}

function Set-NxStorageSensePolicy {
    <#
    .SYNOPSIS
        NX06-004: configure documented Storage Sense policies (journaled, idempotent).
    .DESCRIPTION
        Writes only documented policy values under
        HKLM\SOFTWARE\Policies\Microsoft\Windows\StorageSense:
          AllowStorageSenseGlobal           1 = on, 0 = off
          ConfigStorageSenseGlobalCadence   0 low space / 1 daily / 7 weekly / 30 monthly
        Recycle-Bin and Downloads cleanup thresholds are NEVER written by this entry
        (they delete user data); they are reported if present.
        Documented consequence (disclosed): an enabled AllowStorageSenseGlobal policy
        removes the user's ability to switch Storage Sense off in Settings; with the
        cadence unset the user keeps its choice (the default action therefore does not
        write the cadence).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Enable', 'Disable', 'Report')][string]$Mode = 'Enable',
        [ValidateSet('Keep', 'LowSpace', 'Daily', 'Weekly', 'Monthly')][string]$Cadence = 'Keep',
        [switch]$Approved,
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$TweakId = 'NX06-004'
    )
    $warnings = @(
        'Documented consequence: while AllowStorageSenseGlobal is configured, users cannot turn Storage Sense off in Settings; they can still adjust cadence unless ConfigStorageSenseGlobalCadence is also set (this entry leaves cadence alone by default).',
        'NEXTRIX never enables Recycle Bin or Downloads cleanup policies - those delete user data and stay a user decision in Settings.',
        'Storage Sense itself is documented Windows behavior (Microsoft); enabling it is not a performance claim.'
    )
    $state = Get-NxStorageSenseState
    if ($Mode -eq 'Report' -or -not $Approved) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'report mode or approval missing: nothing written' -Warnings $warnings -Details $state
    }
    Assert-Nx06JournalReady -JournalRoot $JournalRoot
    if (-not $PSCmdlet.ShouldProcess($script:Nx06StorageSensePolicyKey, "Set Storage Sense policy (Mode=$Mode Cadence=$Cadence)")) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'WhatIf: no mutation, no journal write' -Warnings $warnings -Details $state
    }
    $layers = New-Object System.Collections.Generic.List[object]
    $allowValue = $(if ($Mode -eq 'Enable') { 1 } else { 0 })
    $layers.Add((Invoke-Nx06RegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $script:Nx06StorageSensePolicyKey -Name 'AllowStorageSenseGlobal' -Kind DWord -Value $allowValue -Profiles $Profiles))
    if ($Cadence -ne 'Keep') {
        $cadenceValue = [int]$script:Nx06StorageSenseCadence[$Cadence]
        $layers.Add((Invoke-Nx06RegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $script:Nx06StorageSensePolicyKey -Name 'ConfigStorageSenseGlobalCadence' -Kind DWord -Value $cadenceValue -Profiles $Profiles))
    }
    $allOk = (@($layers | Where-Object { -not $_.verified }).Count -eq 0)
    $after = Get-NxStorageSenseState
    return New-Nx06Result -TweakId $TweakId -Outcome $(if ($allOk) { 'Applied' } else { 'Failed' }) -Reason ("policy layers: " + (($layers | ForEach-Object { "$($_.target)=$($_.reason)" }) -join ' | ')) -Verified $allOk -JournalSeq (@($layers)[0].journalSeq) -Warnings $warnings -Details ([pscustomobject]@{ layers = $layers.ToArray(); before = $state; after = $after })
}

# ---------------------------------------------------------------------------
# 6. Cleanup engine (NX06-005/006/007) - explicit path lists, dry-run first,
#    journaled operation records with honest irreversibility labels.
# ---------------------------------------------------------------------------

function Get-Nx06FileCandidates {
    <#
        Manual, reparse-point-safe traversal. Junctions/symlinks are never followed and
        never deleted (a cleanup must not escape its root). Bounded by MaxFiles so a
        pathological temp tree cannot stall the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [Parameter(Mandatory)][datetime]$OlderThanUtc,
        [int]$MaxFiles = 200000
    )
    $files = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $skippedReparse = 0
    $truncated = $false
    $stack = New-Object System.Collections.Stack
    foreach ($r in $Roots) { if (Test-Path -LiteralPath $r -PathType Container) { $stack.Push($r) } }
    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        $items = @()
        try { $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop) } catch { $errors.Add("enumerate failed: $($_.Exception.Message)"); continue }
        foreach ($i in $items) {
            if ($files.Count -ge $MaxFiles) { $truncated = $true; break }
            $isReparse = (([int]$i.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)
            if ($isReparse) { $skippedReparse++; continue }
            if ($i.PSIsContainer) { $stack.Push($i.FullName); continue }
            if ($i.LastWriteTimeUtc -ge $OlderThanUtc) { continue }
            $files.Add([pscustomobject]@{ path = $i.FullName; bytes = [int64]$i.Length; lastWriteUtc = $i.LastWriteTimeUtc })
        }
        if ($truncated) { break }
    }
    $bytes = [int64]0
    foreach ($f in $files) { $bytes += [int64]$f.bytes }
    return [pscustomobject]@{
        files          = $files.ToArray()
        fileCount      = $files.Count
        bytes          = $bytes
        errors         = $errors.ToArray()
        skippedReparse = $skippedReparse
        truncated      = $truncated
        cutoffUtc      = $OlderThanUtc
    }
}

function Remove-Nx06FileSet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Files)
    $deleted = 0; $failed = 0; $bytesDeleted = [int64]0
    $failures = New-Object System.Collections.Generic.List[object]
    foreach ($f in @($Files)) {
        try {
            Remove-Item -LiteralPath $f.path -Force -ErrorAction Stop
            $deleted++
            $bytesDeleted += [int64]$f.bytes
        } catch {
            $failed++
            if ($failures.Count -lt 25) { $failures.Add([pscustomobject]@{ path = $f.path; error = [string]$_.Exception.Message }) }
        }
    }
    return [pscustomobject]@{ deletedCount = $deleted; failedCount = $failed; bytesDeleted = $bytesDeleted; failures = $failures.ToArray() }
}

function Test-Nx06CleanupRoot {
    <#
        Path allow-list for temporary-file cleanup. Only a directory whose leaf name is
        Temp/Tmp and which lives under the Windows directory or a user profile is
        accepted. Drive roots, Windows itself, profile roots and reparse points are
        refused. Returns refused=true with a reason instead of throwing so the caller
        can report per-path decisions.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $refused = $false; $reason = ''
    $full = $null
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return [pscustomobject]@{ path = $Path; accepted = $false; reason = "invalid path: $($_.Exception.Message)"; fullPath = $null } }
    if ([string]::IsNullOrWhiteSpace($full)) { return [pscustomobject]@{ path = $Path; accepted = $false; reason = 'empty path'; fullPath = $null } }
    $leaf = Split-Path -Leaf $full
    if ($leaf -notmatch '^(?i:temp|tmp)$') { $refused = $true; $reason = "leaf directory '$leaf' is not a temp directory" }
    elseif ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) { $refused = $true; $reason = 'drive root refused' }
    elseif ($full -ieq ([IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\'))) { $refused = $true; $reason = 'the Windows directory itself is refused' }
    elseif (-not ($full -like "$($env:SystemRoot)\*" -or $full -like ([IO.Path]::GetPathRoot($env:SystemRoot).TrimEnd('\') + '\Users\*'))) { $refused = $true; $reason = 'path is outside the Windows directory and user profiles' }
    if (-not $refused -and (Test-Path -LiteralPath $full)) {
        try {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { $refused = $true; $reason = 'path is a reparse point (junction/symlink) - refused' }
        } catch { $refused = $true; $reason = "path could not be inspected: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ path = $Path; fullPath = $full; accepted = (-not $refused); reason = $reason }
}

function Get-NxTemporaryFileReport {
    <#
    .SYNOPSIS
        NX06-005 dry-run/report: exactly what would be deleted, with no deletion.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Paths = @(),
        [ValidateRange(0, 3650)][int]$MinimumAgeDays = 7
    )
    $roots = New-Object System.Collections.Generic.List[object]
    $candidatePaths = @()
    if ($Paths -and @($Paths).Count -gt 0) { $candidatePaths = @($Paths) }
    else {
        $candidatePaths = @((Join-Path $env:SystemRoot 'Temp'), $env:TEMP)
        try {
            $local = Join-Path $env:LOCALAPPDATA 'Temp'
            if ($local) { $candidatePaths += $local }
        } catch { }
    }
    $seen = @{}
    $accepted = New-Object System.Collections.Generic.List[string]
    foreach ($p in $candidatePaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $verdict = Test-Nx06CleanupRoot -Path $p
        if ($verdict.accepted) {
            if (-not $seen.ContainsKey($verdict.fullPath.ToLower())) { $seen[$verdict.fullPath.ToLower()] = $true; $accepted.Add($verdict.fullPath) }
            $roots.Add([pscustomobject]@{ path = $verdict.fullPath; accepted = $true; reason = 'accepted' })
        } else {
            $roots.Add([pscustomobject]@{ path = $p; accepted = $false; reason = $verdict.reason })
        }
    }
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-1 * $MinimumAgeDays)
    if ($accepted.Count -gt 0) {
        $scan = Get-Nx06FileCandidates -Roots $accepted.ToArray() -OlderThanUtc $cutoff
    } else {
        $scan = [pscustomobject]@{ files = @(); fileCount = 0; bytes = [int64]0; errors = @('no accepted temp root - nothing enumerated'); skippedReparse = 0; truncated = $false; cutoffUtc = $cutoff }
    }
    $sample = @($scan.files | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ name = (Split-Path -Leaf $_.path); bytes = $_.bytes; lastWriteUtc = $_.lastWriteUtc } })
    return [pscustomobject][ordered]@{
        functionName    = 'Get-NxTemporaryFileReport'
        readOnly        = $true
        generatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        roots           = $roots.ToArray()
        minimumAgeDays  = $MinimumAgeDays
        cutoffUtc       = $cutoff
        fileCount       = $scan.fileCount
        bytes           = $scan.bytes
        sampleNames     = $sample
        skippedReparse  = $scan.skippedReparse
        truncated       = $scan.truncated
        errors          = $scan.errors
        irreversibility = 'Deletion cannot be undone by the journal; the operation record is written for audit, not restore.'
    }
}

function Clear-NxTemporaryFiles {
    <#
    .SYNOPSIS
        NX06-005: on-demand temporary-file cleanup. Reports first; deletes only with
        -Consent plus engine approval (-Approved).
    .DESCRIPTION
        Explicit path list only (Windows\Temp, the current user's %TEMP%; no wildcard
        sweeping, no AppData browsing). Files newer than -MinimumAgeDays and reparse
        points are never touched; locked files are skipped and reported. A journal
        'apply' record is written before deletion and a verify record after, both
        labeled irreversible. NEXTRIX never schedules this.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$JournalRoot,
        [string[]]$Paths = @(),
        [ValidateRange(0, 3650)][int]$MinimumAgeDays = 7,
        [switch]$Consent,
        [switch]$Approved,
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$TweakId = 'NX06-005'
    )
    $warnings = @(
        'Deletion is NOT reversible: temp files cannot be restored from the journal - the record is an audit trail only.',
        'Open/locked files are skipped, not forced (no handle breaking, no service stops for temp cleanup).',
        'Installer caches in %TEMP% may be removed; Windows and applications re-create what they need.'
    )
    $report = Get-NxTemporaryFileReport -Paths $Paths -MinimumAgeDays $MinimumAgeDays
    if (-not $Consent -or -not $Approved) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason ("dry-run: $($report.fileCount) file(s), $($report.bytes) bytes older than $MinimumAgeDays day(s) would be deleted; nothing deleted (consent/approval missing)") -Warnings $warnings -Details $report
    }
    if ($report.fileCount -eq 0) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'AlreadyApplied' -Reason 'no eligible temp files' -Verified $true -Warnings $warnings -Details $report
    }
    Assert-Nx06JournalReady -JournalRoot $JournalRoot
    if (-not $PSCmdlet.ShouldProcess("$($report.fileCount) temporary file(s)", "Delete files older than $MinimumAgeDays day(s) under the reported roots")) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'WhatIf: nothing deleted, no journal write' -Warnings $warnings -Details $report
    }
    $original = [pscustomobject][ordered]@{
        targetType      = 'fileDeletionSet'
        roots           = @($report.roots | Where-Object { $_.accepted } | ForEach-Object { $_.path })
        minimumAgeDays  = $MinimumAgeDays
        plannedFileCount = $report.fileCount
        plannedBytes    = $report.bytes
        irreversibility = 'NOT REVERSIBLE - audit record only'
    }
    $modified = [pscustomobject][ordered]@{
        targetType = 'fileDeletionSet'
        operation  = 'delete temporary files (on-demand, explicit consent)'
        consent    = $true
        irreversibility = 'NOT REVERSIBLE - audit record only'
    }
    $apply = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    $scan = Get-Nx06FileCandidates -Roots @($original.roots) -OlderThanUtc $report.cutoffUtc
    $del = Remove-Nx06FileSet -Files $scan.files
    $ok = ($del.failedCount -eq 0)
    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified ([pscustomobject]@{ targetType = 'fileDeletionSet'; deletedCount = $del.deletedCount; failedCount = $del.failedCount; bytesDeleted = $del.bytesDeleted; sampleFailures = @($del.failures | ForEach-Object { [pscustomobject]@{ name = (Split-Path -Leaf $_.path); error = $_.error } }); irreversibility = 'NOT REVERSIBLE' }) -Result $(if ($ok) { 'Success-Irreversible' } else { 'Partial-Irreversible' }) -Verification $(if ($ok) { 'Verified' } else { 'Partial' }) -ErrorInfo $(if ($ok) { '' } else { "$($del.failedCount) file(s) could not be deleted (locked or access denied)" }) -Profiles $Profiles
    return New-Nx06Result -TweakId $TweakId -Outcome $(if ($ok) { 'Applied' } else { 'Partial' }) -Reason ("deleted $($del.deletedCount) file(s) / $($del.bytesDeleted) bytes; $($del.failedCount) skipped") -Verified $ok -JournalSeq $apply.seq -Warnings $warnings -Details ([pscustomobject]@{ report = $report; deletion = $del })
}

function Get-Nx06UpdateIdleVerdict {
    <#
        PURE idle-gate logic (unit-testable): pending reboot, an active servicing
        process, or a running Windows Update service means "not idle".
    #>
    [CmdletBinding()]
    param(
        [string[]]$PendingRebootReasons = @(),
        [string[]]$BusyProcesses = @(),
        [string[]]$RunningServices = @(),
        [switch]$AllowServiceStop
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    foreach ($r in $PendingRebootReasons) { $reasons.Add("pending reboot: $r") }
    foreach ($p in $BusyProcesses) { $reasons.Add("servicing process running: $p") }
    $blockingServices = @($RunningServices | Where-Object { $_ -in @('wuauserv', 'UsoSvc', 'TrustedInstaller') })
    if ($blockingServices.Count -gt 0 -and -not $AllowServiceStop) {
        foreach ($s in $blockingServices) { $reasons.Add("Windows Update service running: $s") }
    }
    return [pscustomobject]@{
        idle       = ($reasons.Count -eq 0)
        reasons    = $reasons.ToArray()
        toleratesServiceStop = $AllowServiceStop.IsPresent
        blockingServices = $blockingServices
    }
}

function Get-NxWindowsUpdateCacheReport {
    <#
    .SYNOPSIS
        NX06-006 read-only report: cache size, idle/lock evidence, pending reboot.
    #>
    [CmdletBinding()]
    param()
    $unc = New-Object System.Collections.Generic.List[string]
    $download = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    $size = [int64]0; $count = 0
    if (Test-Path -LiteralPath $download) {
        try {
            $m = Get-ChildItem -LiteralPath $download -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            $size = [int64]($m.Sum); $count = [int]$m.Count
        } catch { $unc.Add("cache enumeration failed: $($_.Exception.Message)") }
    } else { $unc.Add("cache path not found: $download") }

    $pending = New-Object System.Collections.Generic.List[string]
    foreach ($k in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
        if (Test-Path -LiteralPath $k) { $pending.Add($k) }
    }
    $pfr = Capture-NxRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations'
    if ($pfr.existed) { $pending.Add('PendingFileRenameOperations present') }

    $busyNames = @('TiWorker', 'TrustedInstaller', 'wuauclt', 'MoUsoCoreWorker', 'SetupHost', 'WindowsUpdateBox')
    $busy = @()
    try { $busy = @(Get-Process -Name $busyNames -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName }) } catch { }

    $svcStates = @()
    foreach ($n in @('wuauserv', 'BITS', 'UsoSvc', 'TrustedInstaller')) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($null -ne $s) {
            $st = [string]$s.Status
            $svcStates += [pscustomobject]@{ name = $n; status = $st; startType = $(try { [string]$s.StartType } catch { $null }) }
        }
    }
    $running = @($svcStates | Where-Object { $_.status -eq 'Running' } | ForEach-Object { $_.name })
    $verdict = Get-Nx06UpdateIdleVerdict -PendingRebootReasons $pending.ToArray() -BusyProcesses $busy -RunningServices $running

    return [pscustomobject][ordered]@{
        functionName = 'Get-NxWindowsUpdateCacheReport'
        readOnly     = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        cachePath    = $download
        fileCount    = $count
        bytes        = $size
        pendingReboot = $pending.ToArray()
        busyProcesses = $busy
        services      = $svcStates
        idleVerdict   = $verdict
        uncertainty   = $unc.ToArray()
        policyNote    = 'NX06 never disables Windows Update or changes any service StartType; the cache is re-downloadable data.'
    }
}

function Clear-NxWindowsUpdateCache {
    <#
    .SYNOPSIS
        NX06-006: on-demand Windows Update download-cache cleanup with a hard idle gate.
    .DESCRIPTION
        Safety chain, in order:
          1. refuse when a reboot is pending or a servicing process is running;
          2. refuse when wuauserv/UsoSvc/TrustedInstaller are running unless
             -ConsentToTemporaryServiceStop is explicitly given;
          3. delete only under %SystemRoot%\SoftwareDistribution\Download, only files
             older than -MinimumAgeDays, never reparse points;
          4. restart every service this function stopped in a finally block, verify it,
             and never modify a StartType (asserted in the record).
        The journal records the exact prior service states and the deletion plan; the
        deletion itself is labeled irreversible (audit only). No scheduling, ever.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$JournalRoot,
        [ValidateRange(0, 3650)][int]$MinimumAgeDays = 0,
        [switch]$Consent,
        [switch]$ConsentToTemporaryServiceStop,
        [switch]$Approved,
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$TweakId = 'NX06-006'
    )
    $warnings = @(
        'Windows Update services (wuauserv/BITS/UsoSvc) are never disabled and their StartType is never changed. A temporary stop happens only with -ConsentToTemporaryServiceStop and is undone in a finally block.',
        'Deleting downloads during an active update can corrupt that download - the idle gate refuses instead of racing Windows Update.',
        'Deletion is NOT reversible; downloads are re-fetched by Windows Update when needed.'
    )
    $report = Get-NxWindowsUpdateCacheReport
    $verdict = $report.idleVerdict
    $stopNeeded = @($verdict.blockingServices).Count -gt 0
    if (-not $verdict.idle) {
        if (-not ($stopNeeded -and $ConsentToTemporaryServiceStop -and @($verdict.reasons | Where-Object { $_ -notlike 'Windows Update service running*' }).Count -eq 0)) {
            return New-Nx06Result -TweakId $TweakId -Outcome 'Refused' -Reason ("Windows Update is not idle: " + ($verdict.reasons -join '; ')) -Warnings $warnings -Details $report
        }
    }
    if (-not $Consent -or -not $Approved) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason ("dry-run: $($report.fileCount) file(s) / $($report.bytes) bytes under $($report.cachePath); nothing deleted (consent/approval missing)") -Warnings $warnings -Details $report
    }
    Assert-Nx06JournalReady -JournalRoot $JournalRoot
    if (-not $PSCmdlet.ShouldProcess($report.cachePath, "Delete $($report.fileCount) cached update file(s)")) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'WhatIf: nothing deleted, no journal write' -Warnings $warnings -Details $report
    }

    $cacheRoot = [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'SoftwareDistribution\Download')).TrimEnd('\')
    $original = [pscustomobject][ordered]@{
        targetType      = 'fileDeletionSet'
        root            = $cacheRoot
        minimumAgeDays  = $MinimumAgeDays
        plannedFileCount = $report.fileCount
        plannedBytes    = $report.bytes
        servicesBefore  = $report.services
        idleVerdict     = $verdict
        irreversibility = 'NOT REVERSIBLE - audit record only'
    }
    $modified = [pscustomobject][ordered]@{
        targetType = 'fileDeletionSet'
        operation  = 'delete Windows Update download cache (on-demand, explicit consent)'
        serviceStopRequested = $ConsentToTemporaryServiceStop.IsPresent
        irreversibility = 'NOT REVERSIBLE - audit record only'
    }
    $apply = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles

    $stopped = New-Object System.Collections.Generic.List[object]
    $restarted = New-Object System.Collections.Generic.List[object]
    $serviceErrors = New-Object System.Collections.Generic.List[string]
    $del = $null
    $deleteError = $null
    try {
        if ($stopNeeded -and $ConsentToTemporaryServiceStop) {
            foreach ($s in @($report.services | Where-Object { $_.status -eq 'Running' -and $_.name -in @('wuauserv', 'UsoSvc', 'BITS') })) {
                try {
                    Stop-Service -Name $s.name -ErrorAction Stop
                    $stopped.Add($s)
                } catch { $serviceErrors.Add("stop $($s.name) failed: $($_.Exception.Message)") }
            }
            Start-Sleep -Milliseconds 750
        }
        $scan = Get-Nx06FileCandidates -Roots @($cacheRoot) -OlderThanUtc ((Get-Date).ToUniversalTime().AddDays(-1 * $MinimumAgeDays))
        $del = Remove-Nx06FileSet -Files $scan.files
    } catch {
        $deleteError = [string]$_.Exception.Message
        $serviceErrors.Add("deletion failed: $deleteError")
    } finally {
        foreach ($s in $stopped) {
            try { Start-Service -Name $s.name -ErrorAction Stop; $restarted.Add($s.name) }
            catch { $serviceErrors.Add("restart $($s.name) failed: $($_.Exception.Message)") }
        }
    }
    if ($null -eq $del) { $del = [pscustomobject]@{ deletedCount = 0; failedCount = 0; bytesDeleted = [int64]0; failures = @() } }
    $postServices = @()
    $startTypeChanged = $false
    foreach ($s in @($report.services)) {
        $live = Get-Service -Name $s.name -ErrorAction SilentlyContinue
        if ($null -ne $live) {
            $liveStart = try { [string]$live.StartType } catch { $null }
            $postServices += [pscustomobject]@{ name = $s.name; status = [string]$live.Status; startType = $liveStart }
            if ($null -ne $s.startType -and $null -ne $liveStart -and $s.startType -ne $liveStart) { $startTypeChanged = $true }
        }
    }
    $restartOk = @($stopped | Where-Object { $restarted -notcontains $_.name }).Count -eq 0
    $ok = ($null -eq $deleteError) -and ($del.failedCount -eq 0) -and $restartOk -and (-not $startTypeChanged)
    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified ([pscustomobject]@{ targetType = 'fileDeletionSet'; deletedCount = $del.deletedCount; failedCount = $del.failedCount; bytesDeleted = $del.bytesDeleted; stopped = @($stopped | ForEach-Object { $_.name }); restarted = $restarted.ToArray(); startTypeChanged = $startTypeChanged; servicesAfter = $postServices; irreversibility = 'NOT REVERSIBLE' }) -Result $(if ($ok) { 'Success-Irreversible' } else { 'Partial-Irreversible' }) -Verification $(if ($ok) { 'Verified' } else { 'Partial' }) -ErrorInfo (($serviceErrors + @("deleted $($del.deletedCount)/$(($del.deletedCount + $del.failedCount)) files")) -join '; ') -Profiles $Profiles
    return New-Nx06Result -TweakId $TweakId -Outcome $(if ($ok) { 'Applied' } else { 'Partial' }) -Reason ("deleted $($del.deletedCount) file(s) / $($del.bytesDeleted) bytes; $($del.failedCount) skipped; services restarted: $($restarted.Count); startTypeChanged=$startTypeChanged") -Verified $ok -JournalSeq $apply.seq -Warnings $warnings -Details ([pscustomobject]@{ report = $report; deletion = $del; stopped = @($stopped | ForEach-Object { $_.name }); restarted = $restarted.ToArray(); serviceErrors = $serviceErrors.ToArray(); servicesAfter = $postServices })
}

function Get-NxDeliveryOptimizationCacheReport {
    <#
    .SYNOPSIS
        NX06-007 read-only report: DO cmdlet availability, active jobs, cache folder size.
    #>
    [CmdletBinding()]
    param()
    $unc = New-Object System.Collections.Generic.List[string]
    $statusCmd = Get-Command Get-DeliveryOptimizationStatus -ErrorAction SilentlyContinue
    $deleteCmd = Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue
    $jobs = @()
    if ($null -ne $statusCmd) {
        try {
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { $jobs = @(Get-DeliveryOptimizationStatus -ErrorAction Stop) } catch { $unc.Add("Get-DeliveryOptimizationStatus: $($_.Exception.Message)") } finally { $ErrorActionPreference = $prev }
        } catch { }
    } else { $unc.Add('DeliveryOptimization module/cmdlet unavailable') }
    $cacheFolder = Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
    $bytes = $null; $files = $null
    if (Test-Path -LiteralPath $cacheFolder) {
        try {
            $m = Get-ChildItem -LiteralPath $cacheFolder -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            $bytes = [int64]$m.Sum; $files = [int]$m.Count
        } catch { $unc.Add("cache folder enumeration failed: $($_.Exception.Message)") }
    } else { $unc.Add("observed cache folder not present: $cacheFolder (path is not Microsoft-documented - reported only when found)") }
    return [pscustomobject][ordered]@{
        functionName   = 'Get-NxDeliveryOptimizationCacheReport'
        readOnly       = $true
        generatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        cmdletAvailable = [pscustomobject]@{ status = ($null -ne $statusCmd); delete = ($null -ne $deleteCmd) }
        activeJobCount = $jobs.Count
        activeJobs     = $jobs
        cacheFolder    = $cacheFolder
        cacheFolderBytes = $bytes
        cacheFolderFiles = $files
        uncertainty    = $unc.ToArray()
        boundaryNote   = 'Delivery Optimization MODE (DODownloadMode) is NX01-011; this entry deletes cache content only and never changes policy.'
    }
}

function Clear-NxDeliveryOptimizationCache {
    <#
    .SYNOPSIS
        NX06-007: on-demand Delivery Optimization cache cleanup via the documented
        Delete-DeliveryOptimizationCache cmdlet.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$JournalRoot,
        [switch]$Consent,
        [switch]$IncludePinnedFiles,
        [switch]$Approved,
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$TweakId = 'NX06-007'
    )
    $warnings = @(
        'Deletion cannot be undone (documented by Microsoft for Delete-DeliveryOptimizationCache).',
        'Pinned files are preserved unless -IncludePinnedFiles is given; pinned content may be intentional (e.g. shared LAN content).',
        'Delivery Optimization MODE and policy belong to NX01-011; this function never changes DODownloadMode.'
    )
    $report = Get-NxDeliveryOptimizationCacheReport
    if (-not $report.cmdletAvailable.delete) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Skipped' -Reason 'Delete-DeliveryOptimizationCache unavailable on this system - nothing deleted' -Warnings $warnings -Details $report
    }
    if (-not $Consent -or -not $Approved) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'dry-run: cache report only; nothing deleted (consent/approval missing)' -Warnings $warnings -Details $report
    }
    Assert-Nx06JournalReady -JournalRoot $JournalRoot
    if (-not $PSCmdlet.ShouldProcess('Delivery Optimization cache', "Delete cached files (IncludePinnedFiles=$($IncludePinnedFiles.IsPresent))")) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'WhatIf: nothing deleted, no journal write' -Warnings $warnings -Details $report
    }
    $original = [pscustomobject][ordered]@{
        targetType = 'deliveryOptimizationCache'
        cacheFolder = $report.cacheFolder
        cacheFolderBytes = $report.cacheFolderBytes
        activeJobCount = $report.activeJobCount
        irreversibility = 'NOT REVERSIBLE - audit record only'
    }
    $modified = [pscustomobject][ordered]@{
        targetType = 'deliveryOptimizationCache'
        operation = 'Delete-DeliveryOptimizationCache'
        includePinnedFiles = $IncludePinnedFiles.IsPresent
        irreversibility = 'NOT REVERSIBLE - audit record only'
    }
    $apply = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($IncludePinnedFiles) { Delete-DeliveryOptimizationCache -IncludePinnedFiles -Force -ErrorAction Stop | Out-Null }
            else { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null }
            $err = $null
        } catch {
            $err = [string]$_.Exception.Message
        } finally { $ErrorActionPreference = $prev }
        $after = Get-NxDeliveryOptimizationCacheReport
        $ok = ($null -eq $err)
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified ([pscustomobject]@{ targetType = 'deliveryOptimizationCache'; cacheFolderBytesAfter = $after.cacheFolderBytes; activeJobCountAfter = $after.activeJobCount; irreversibility = 'NOT REVERSIBLE' }) -Result $(if ($ok) { 'Success-Irreversible' } else { 'Failed-Irreversible' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $(if ($ok) { '' } else { $err }) -Profiles $Profiles
        return New-Nx06Result -TweakId $TweakId -Outcome $(if ($ok) { 'Applied' } else { 'Failed' }) -Reason $(if ($ok) { "cache cleanup completed (size before: $($report.cacheFolderBytes) bytes)" } else { $err }) -Verified $ok -JournalSeq $apply.seq -Warnings $warnings -Details ([pscustomobject]@{ before = $report; after = $after })
    } catch {
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
        return New-Nx06Result -TweakId $TweakId -Outcome 'Failed' -Reason ([string]$_.Exception.Message) -Warnings $warnings -Details $report
    }
}

# ---------------------------------------------------------------------------
# 7. NTFS policies NX06-008 / 009 / 010
# ---------------------------------------------------------------------------

function Set-NxNtfsLastAccessPolicy {
    <#
    .SYNOPSIS
        NX06-008: disable (or restore) NTFS last-access timestamp updates.
    .DESCRIPTION
        Documented: `fsutil behavior set disablelastaccess {1|0}`; the query reports
        "User Managed / System Managed" plus ENABLED/DISABLED. System-managed values
        (high bit clear) make the effective behavior volume-dependent; the rest of the
        state is captured raw so nothing is inferred.
        Restart required (documented). Trade-off documented by Microsoft: backup and
        remote-storage tools that rely on Last Access Time are affected.
        Mutation goes through the documented fsutil command; the exact persistence
        value (NtfsDisableLastAccessUpdate, including the 0x80000000 user-managed bit)
        is journaled for byte-exact restore.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Disable', 'Enable', 'Report')][string]$Mode = 'Disable',
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$TweakId = 'NX06-008'
    )
    $warnings = @(
        'Microsoft documents that disabling Last Access Time updates can affect programs such as Backup and Remote Storage that rely on this timestamp.',
        'A restart is required for the setting to take effect (documented).',
        'System-managed modes make the effective policy volume-dependent; the raw fsutil output and the exact registry DWord are recorded so the state is never guessed.'
    )
    $state = Get-NxNtfsBehaviorState -SkipVolumes
    $cur = $state.disablelastaccess
    if ($Mode -eq 'Report' -or -not $Approved) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason "current last-access policy: $($cur.semantic) (raw value $($cur.registry.value), parsed $($cur.value)); nothing written" -Warnings $warnings -Details $state
    }
    if (-not $cur.recognized) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Refused' -Reason 'fsutil behavior query disablelastaccess output not recognized - no capture means no mutation' -Warnings $warnings -Details $cur
    }
    $desiredFlag = $(if ($Mode -eq 'Disable') { 1 } else { 0 })
    $desiredSemantic = $(if ($Mode -eq 'Disable') { 'Disabled' } else { 'Enabled' })
    if ([int]$cur.value -eq $desiredFlag) {
        $null = Add-Nx06SkipEntry -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Original ([pscustomobject]@{ targetType = 'fsutilBehavior'; name = 'disablelastaccess'; value = $cur.value; registry = $cur.registry }) -Modified ([pscustomobject]@{ targetType = 'fsutilBehavior'; name = 'disablelastaccess'; value = $desiredFlag }) -Profiles $Profiles
        return New-Nx06Result -TweakId $TweakId -Outcome 'AlreadyApplied' -Reason "last-access policy is already $desiredSemantic" -Verified $true -Warnings $warnings -Details $cur
    }
    Assert-Nx06JournalReady -JournalRoot $JournalRoot
    $original = [pscustomobject][ordered]@{
        targetType   = 'fsutilBehavior'
        name         = 'disablelastaccess'
        value        = $cur.value
        semantic     = $cur.semantic
        raw          = $cur.raw
        registryName = $cur.registryName
        registry     = $cur.registry
        userManaged  = $(if ($cur.extra.ContainsKey('userManaged')) { $cur.extra['userManaged'] } else { $null })
    }
    $modified = [pscustomobject][ordered]@{
        targetType = 'fsutilBehavior'
        name       = 'disablelastaccess'
        value      = $desiredFlag
        semantic   = $desiredSemantic
        command    = "fsutil behavior set disablelastaccess $desiredFlag"
        restartRequired = $true
    }
    if (-not $PSCmdlet.ShouldProcess('NTFS last-access updates', "Set $desiredSemantic (fsutil behavior set disablelastaccess $desiredFlag)")) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'WhatIf: no mutation, no journal write' -Warnings $warnings -Details $cur
    }
    $apply = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        $run = Set-Nx06FsutilBehavior -Name 'disablelastaccess' -Value ([string]$desiredFlag)
        $after = Get-NxNtfsBehaviorState -SkipVolumes
        $ok = ($after.disablelastaccess.recognized -and [int]$after.disablelastaccess.value -eq $desiredFlag)
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified ([pscustomobject]@{ targetType = 'fsutilBehavior'; name = 'disablelastaccess'; value = $after.disablelastaccess.value; semantic = $after.disablelastaccess.semantic; registryAfter = $after.disablelastaccess.registry; restartRequired = $true; exitCode = $run.exitCode }) -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified-RestartPending' } else { 'NotVerified' }) -ErrorInfo $(if ($ok) { '' } else { $run.text }) -Profiles $Profiles
        if (-not $ok) {
            $restore = Restore-Nx06FsutilOriginal -Original $original
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo ("post-set value mismatch; restore: " + ($restore -join '; ')) -Profiles $Profiles
            return New-Nx06Result -TweakId $TweakId -Outcome 'Failed' -Reason 'last-access policy did not verify after fsutil set; best-effort exact restore attempted' -Warnings $warnings -Details ([pscustomobject]@{ run = $run; after = $after.disablelastaccess; restore = $restore })
        }
        return New-Nx06Result -TweakId $TweakId -Outcome 'Applied' -Reason "last-access policy now $($after.disablelastaccess.semantic); restart required (documented)" -Verified $true -JournalSeq $apply.seq -Warnings $warnings -Details ([pscustomobject]@{ run = $run; after = $after.disablelastaccess })
    } catch {
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
        return New-Nx06Result -TweakId $TweakId -Outcome 'Failed' -Reason ([string]$_.Exception.Message) -Warnings $warnings
    }
}

function Set-NxNtfs8dot3Policy {
    <#
    .SYNOPSIS
        NX06-009: disable (or restore) global 8.3 short-name creation.
    .DESCRIPTION
        Documented: `fsutil behavior set disable8dot3 {1|0}` (global registry state),
        `fsutil behavior query disable8dot3 <volume>` for the per-volume state.
        Existing short names are NOT deleted by this setting - it governs creation of
        new ones only (documented). Legacy-installer caution: old setup programs can
        depend on short names; per-volume state is reported so the owner can see where
        short names were explicitly enabled. Restart required (documented).
        ReviOS disables 8.3 via revitool (r2) - reference note only, no performance
        claim is made here.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Disable', 'Enable', 'Report')][string]$Mode = 'Disable',
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$TweakId = 'NX06-009'
    )
    $warnings = @(
        'Legacy-installer caution: some old setup programs and 16-bit-era utilities depend on 8.3 short names. Per-volume state is reported before any change.',
        'This setting governs CREATION of new short names only; existing short names are not removed (documented).',
        'A restart is required for the setting to take effect (documented).'
    )
    $state = Get-NxNtfsBehaviorState
    $cur = $state.disable8dot3
    if ($Mode -eq 'Report' -or -not $Approved) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason "current 8.3 registry state: $($cur.registry.value) (parsed $($cur.value)); nothing written" -Warnings $warnings -Details $state
    }
    if (-not $cur.recognized) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Refused' -Reason 'fsutil behavior query disable8dot3 output not recognized - no capture means no mutation' -Warnings $warnings -Details $cur
    }
    $desired = $(if ($Mode -eq 'Disable') { 1 } else { 0 })
    if ([int]$cur.value -eq $desired) {
        $null = Add-Nx06SkipEntry -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Original ([pscustomobject]@{ targetType = 'fsutilBehavior'; name = 'disable8dot3'; value = $cur.value; registry = $cur.registry }) -Modified ([pscustomobject]@{ targetType = 'fsutilBehavior'; name = 'disable8dot3'; value = $desired }) -Profiles $Profiles
        return New-Nx06Result -TweakId $TweakId -Outcome 'AlreadyApplied' -Reason "8.3 creation policy already at registry state $desired" -Verified $true -Warnings $warnings -Details $cur
    }
    Assert-Nx06JournalReady -JournalRoot $JournalRoot
    $original = [pscustomobject][ordered]@{
        targetType   = 'fsutilBehavior'
        name         = 'disable8dot3'
        value        = $cur.value
        semantic     = $cur.semantic
        raw          = $cur.raw
        volumes      = $state.volumes
        registryName = $cur.registryName
        registry     = $cur.registry
    }
    $modified = [pscustomobject][ordered]@{
        targetType = 'fsutilBehavior'
        name       = 'disable8dot3'
        value      = $desired
        semantic   = $(if ($desired -eq 1) { 'Disabled' } else { 'Enabled' })
        command    = "fsutil behavior set disable8dot3 $desired"
        restartRequired = $true
    }
    if (-not $PSCmdlet.ShouldProcess('NTFS 8.3 name creation', "Set registry state $desired (fsutil behavior set disable8dot3 $desired)")) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'WhatIf: no mutation, no journal write' -Warnings $warnings -Details $cur
    }
    $apply = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        $run = Set-Nx06FsutilBehavior -Name 'disable8dot3' -Value ([string]$desired)
        $after = Get-NxNtfsBehaviorState
        $ok = ($after.disable8dot3.recognized -and [int]$after.disable8dot3.value -eq $desired)
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified ([pscustomobject]@{ targetType = 'fsutilBehavior'; name = 'disable8dot3'; value = $after.disable8dot3.value; volumes = $after.volumes; restartRequired = $true; exitCode = $run.exitCode }) -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified-RestartPending' } else { 'NotVerified' }) -ErrorInfo $(if ($ok) { '' } else { $run.text }) -Profiles $Profiles
        if (-not $ok) {
            $restore = Restore-Nx06FsutilOriginal -Original $original
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo ("post-set value mismatch; restore: " + ($restore -join '; ')) -Profiles $Profiles
            return New-Nx06Result -TweakId $TweakId -Outcome 'Failed' -Reason '8.3 policy did not verify after fsutil set; best-effort exact restore attempted' -Warnings $warnings -Details ([pscustomobject]@{ run = $run; after = $after.disable8dot3; restore = $restore })
        }
        return New-Nx06Result -TweakId $TweakId -Outcome 'Applied' -Reason "8.3 registry state now $($after.disable8dot3.value); restart required (documented); existing short names untouched" -Verified $true -JournalSeq $apply.seq -Warnings $warnings -Details ([pscustomobject]@{ run = $run; after = $after.disable8dot3; volumes = $after.volumes })
    } catch {
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
        return New-Nx06Result -TweakId $TweakId -Outcome 'Failed' -Reason ([string]$_.Exception.Message) -Warnings $warnings
    }
}

function Set-NxNtfsMemoryUsage {
    <#
    .SYNOPSIS
        NX06-010 (ADVANCED): NTFS paged/non-paged pool cache levels - report first.
    .DESCRIPTION
        Documented values: `fsutil behavior set memoryusage 1|2` - 1 = default pool
        usage, 2 = increased lookaside lists and memory thresholds. Microsoft also
        documents the risk: when other processes/cache already use large amounts of
        memory, raising the NTFS pool limit reduces pool memory available to them and
        "might reduce overall system performance".
        Therefore the default action is REPORT ONLY; Increased requires explicit
        consent, is preset-excluded, and requires a restart. No performance claim is
        made in either direction.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Report', 'Increased', 'Default')][string]$Mode = 'Report',
        [switch]$Approved,
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$TweakId = 'NX06-010'
    )
    $warnings = @(
        'Microsoft documents that increasing NTFS pool memory can reduce pool memory available to other processes and "might reduce overall system performance" - this is opt-in only.',
        'A restart is required for the setting to take effect (documented).',
        'Report mode is the default and the only action a preset can never trigger: this entry is ADVANCED and preset-excluded.'
    )
    $state = Get-NxNtfsBehaviorState -SkipVolumes
    $cur = $state.memoryusage
    $mem = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $mem = [pscustomobject]@{
            totalVisibleBytes = [int64]$os.TotalVisibleMemorySize * 1024
            freePhysicalBytes = [int64]$os.FreePhysicalMemory * 1024
        }
    } catch { }
    if ($Mode -eq 'Report' -or -not $Approved) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason "current NTFS memory usage: $($cur.semantic) (raw $($cur.registry.value), parsed $($cur.value)); report-only action (no mutation)" -Warnings $warnings -Details ([pscustomobject]@{ state = $cur; memory = $mem; fullState = $state })
    }
    if (-not $cur.recognized) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Refused' -Reason 'fsutil behavior query memoryusage output not recognized - no capture means no mutation' -Warnings $warnings -Details $cur
    }
    $desired = $(if ($Mode -eq 'Increased') { 2 } else { 1 })
    if ([int]$cur.value -eq $desired) {
        $null = Add-Nx06SkipEntry -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Original ([pscustomobject]@{ targetType = 'fsutilBehavior'; name = 'memoryusage'; value = $cur.value; registry = $cur.registry }) -Modified ([pscustomobject]@{ targetType = 'fsutilBehavior'; name = 'memoryusage'; value = $desired }) -Profiles $Profiles
        return New-Nx06Result -TweakId $TweakId -Outcome 'AlreadyApplied' -Reason "NTFS memory usage already $desired" -Verified $true -Warnings $warnings -Details $cur
    }
    Assert-Nx06JournalReady -JournalRoot $JournalRoot
    $original = [pscustomobject][ordered]@{ targetType = 'fsutilBehavior'; name = 'memoryusage'; value = $cur.value; semantic = $cur.semantic; raw = $cur.raw; registryName = $cur.registryName; registry = $cur.registry }
    $modified = [pscustomobject][ordered]@{ targetType = 'fsutilBehavior'; name = 'memoryusage'; value = $desired; command = "fsutil behavior set memoryusage $desired"; restartRequired = $true }
    if (-not $PSCmdlet.ShouldProcess('NTFS pool memory usage', "Set memoryusage $desired (restart required)")) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'WhatIf: no mutation, no journal write' -Warnings $warnings -Details $cur
    }
    $apply = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        $run = Set-Nx06FsutilBehavior -Name 'memoryusage' -Value ([string]$desired)
        $after = Get-NxNtfsBehaviorState -SkipVolumes
        $ok = ($after.memoryusage.recognized -and [int]$after.memoryusage.value -eq $desired)
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified ([pscustomobject]@{ targetType = 'fsutilBehavior'; name = 'memoryusage'; value = $after.memoryusage.value; registryAfter = $after.memoryusage.registry; restartRequired = $true; exitCode = $run.exitCode }) -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified-RestartPending' } else { 'NotVerified' }) -ErrorInfo $(if ($ok) { '' } else { $run.text }) -Profiles $Profiles
        if (-not $ok) {
            $restore = Restore-Nx06FsutilOriginal -Original $original
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo ("post-set value mismatch; restore: " + ($restore -join '; ')) -Profiles $Profiles
            return New-Nx06Result -TweakId $TweakId -Outcome 'Failed' -Reason 'NTFS memory usage did not verify after fsutil set; best-effort exact restore attempted' -Warnings $warnings -Details ([pscustomobject]@{ run = $run; after = $after.memoryusage; restore = $restore })
        }
        return New-Nx06Result -TweakId $TweakId -Outcome 'Applied' -Reason "NTFS memory usage now $($after.memoryusage.value); restart required (documented)" -Verified $true -JournalSeq $apply.seq -Warnings $warnings -Details ([pscustomobject]@{ run = $run; after = $after.memoryusage; memory = $mem })
    } catch {
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
        return New-Nx06Result -TweakId $TweakId -Outcome 'Failed' -Reason ([string]$_.Exception.Message) -Warnings $warnings
    }
}

# ---------------------------------------------------------------------------
# 8. Device policies NX06-011 (write cache, E0) and NX06-012 (storage D3, E1)
# ---------------------------------------------------------------------------

function Get-NxWriteCacheState {
    <#
    .SYNOPSIS
        NX06-011 read-only state: per-device write-cache registry values plus the
        documented storage API view (IsDeviceCacheEnabled / IsPowerProtected).
    .DESCRIPTION
        The registry value UserWriteCacheSetting (device instance, Device
        Parameters\Disk) is COMMUNITY-KNOWN, not Microsoft-documented - this entry is
        E0. The documented read surface is Get-StorageAdvancedProperty (Storage module).
    #>
    [CmdletBinding()]
    param([int]$DiskNumber = -1)
    $unc = New-Object System.Collections.Generic.List[string]
    $rows = New-Object System.Collections.Generic.List[object]
    $disks = @()
    try { $disks = @(Get-PhysicalDisk -ErrorAction Stop) } catch { $unc.Add("Get-PhysicalDisk failed: $($_.Exception.Message)") }
    $pnpById = @{}
    try {
        foreach ($d in @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)) {
            $pnpById[[string]$d.Index] = [string]$d.PNPDeviceID
        }
    } catch { $unc.Add("Win32_DiskDrive failed: $($_.Exception.Message)") }

    foreach ($d in $disks) {
        $num = [int]$d.DeviceId
        if ($DiskNumber -ge 0 -and $num -ne $DiskNumber) { continue }
        $pnp = $pnpById[[string]$num]
        $devPath = $null
        if (-not [string]::IsNullOrWhiteSpace($pnp)) { $devPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$pnp" }
        $diskParamsPath = $null
        $userCache = $null; $powerProtectedReg = $null
        if ($devPath) {
            $diskParamsPath = Join-Path $devPath 'Device Parameters\Disk'
            $userCache = Capture-NxRegistryValue -Path $diskParamsPath -Name 'UserWriteCacheSetting'
            $powerProtectedReg = Capture-NxRegistryValue -Path $diskParamsPath -Name 'CacheIsPowerProtected'
        } else {
            $unc.Add("disk $num : device instance path unavailable (write-cache registry state Unknown)")
        }
        $adv = $null
        try {
            $pd = Get-PhysicalDisk -DeviceNumber $num -ErrorAction Stop
            $advObj = Get-StorageAdvancedProperty -PhysicalDisk $pd -ErrorAction Stop
            $adv = [pscustomobject]@{ isDeviceCacheEnabled = [bool]$advObj.IsDeviceCacheEnabled; isPowerProtected = [bool]$advObj.IsPowerProtected }
        } catch { $unc.Add("disk $num : Get-StorageAdvancedProperty failed: $($_.Exception.Message)") }
        $rows.Add([pscustomobject][ordered]@{
            deviceNumber     = $num
            friendlyName     = [string]$d.FriendlyName
            mediaType        = [string]$d.MediaType
            busType          = [string]$d.BusType
            pnpDeviceId      = $pnp
            deviceParametersDiskPath = $diskParamsPath
            userWriteCacheSetting = [pscustomobject]@{ existed = $(if ($userCache) { $userCache.existed } else { $false }); kind = $(if ($userCache) { $userCache.kind } else { $null }); value = $(if ($userCache) { $userCache.value } else { $null }) }
            cacheIsPowerProtected = [pscustomobject]@{ existed = $(if ($powerProtectedReg) { $powerProtectedReg.existed } else { $false }); value = $(if ($powerProtectedReg) { $powerProtectedReg.value } else { $null }) }
            deviceCacheEnabled = $(if ($adv) { $adv.isDeviceCacheEnabled } else { $null })
            powerProtected    = $(if ($adv) { $adv.isPowerProtected } else { $null })
        })
    }
    return [pscustomobject][ordered]@{
        functionName = 'Get-NxWriteCacheState'
        readOnly     = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        disks        = $rows.ToArray()
        uncertainty  = $unc.ToArray()
        evidenceNote = 'UserWriteCacheSetting is community-known (E0); the documented read surface is Get-StorageAdvancedProperty. No Microsoft documentation names this registry value.'
    }
}

function Set-NxWriteCachePolicy {
    <#
    .SYNOPSIS
        NX06-011 (E0, CONDITIONAL): per-device write-cache policy with a mandatory
        power-loss trade-off disclosure.
    .DESCRIPTION
        Report mode is the default and reads Get-StorageAdvancedProperty plus the
        per-device registry values. A change writes UserWriteCacheSetting (DWord 1/0)
        in the device instance's Device Parameters\Disk key, journaling the exact prior
        value/absence. Verification is honest about its level: the registry value is
        re-read; the device's own cache state may only change after re-enumeration or
        a reboot, and that is reported rather than claimed.
        Power-loss trade-off (mandatory): write caching acknowledges writes before the
        media commits them, so an unexpected power loss can lose acknowledged data or
        corrupt the volume. Power-protected caches (IsPowerProtected) reduce that risk.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Report', 'Enable', 'Disable')][string]$Mode = 'Report',
        [int]$DiskNumber = -1,
        [switch]$Approved,
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$TweakId = 'NX06-011'
    )
    $warnings = @(
        'POWER-LOSS TRADE-OFF (mandatory disclosure): with write caching enabled, acknowledged writes may still be in the device cache when power is lost - data loss or volume corruption is possible. Disabling it reduces throughput and does not make the system power-safe by itself.',
        'Registry value UserWriteCacheSetting is community-known (E0); the change is verified at registry level, and device-level effect may require re-enumeration or a reboot.',
        'Virtual machines, USB bridges and RAID controllers may ignore or override this per-device value - the report shows the documented IsDeviceCacheEnabled view for comparison.'
    )
    $state = Get-NxWriteCacheState -DiskNumber $DiskNumber
    if ($Mode -eq 'Report' -or -not $Approved) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'report mode or approval missing: no write-cache value written' -Warnings $warnings -Details $state
    }
    $target = @($state.disks)
    if ($DiskNumber -lt 0) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Refused' -Reason 'a specific -DiskNumber is required for a write-cache change (per-device only; no all-disks sweep)' -Warnings $warnings -Details $state
    }
    if ($target.Count -eq 0) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Skipped' -Reason "disk $DiskNumber not found" -Warnings $warnings -Details $state
    }
    $dev = $target[0]
    if ([string]::IsNullOrWhiteSpace([string]$dev.deviceParametersDiskPath)) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Refused' -Reason "device instance path for disk $DiskNumber unavailable - cannot target the per-device value" -Warnings $warnings -Details $state
    }
    Assert-Nx06JournalReady -JournalRoot $JournalRoot
    $desired = $(if ($Mode -eq 'Enable') { 1 } else { 0 })
    if ($dev.userWriteCacheSetting.existed -and [int]$dev.userWriteCacheSetting.value -eq $desired -and [string]$dev.userWriteCacheSetting.kind -eq 'DWord') {
        return New-Nx06Result -TweakId $TweakId -Outcome 'AlreadyApplied' -Reason "disk $DiskNumber UserWriteCacheSetting already $desired" -Verified $true -Warnings $warnings -Details $dev
    }
    if (-not $PSCmdlet.ShouldProcess("disk $DiskNumber ($($dev.friendlyName))", "Set UserWriteCacheSetting=$desired")) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'WhatIf: no mutation, no journal write' -Warnings $warnings -Details $dev
    }
    $write = Invoke-Nx06RegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $dev.deviceParametersDiskPath -Name 'UserWriteCacheSetting' -Kind DWord -Value $desired -Profiles $Profiles
    $after = Get-NxWriteCacheState -DiskNumber $DiskNumber
    $deviceLevelChanged = $null
    if ($after.disks.Count -gt 0 -and $null -ne $after.disks[0].deviceCacheEnabled -and $null -ne $dev.deviceCacheEnabled) {
        $deviceLevelChanged = ([bool]$after.disks[0].deviceCacheEnabled -ne [bool]$dev.deviceCacheEnabled)
    }
    return New-Nx06Result -TweakId $TweakId -Outcome $(if ($write.verified) { 'Applied' } else { 'Failed' }) -Reason ("registry write: $($write.reason); device-level cache state changed at read time: $deviceLevelChanged (reboot/re-enumeration may be required)") -Verified ([bool]$write.verified) -JournalSeq $write.journalSeq -Warnings $warnings -Details ([pscustomobject]@{ before = $dev; after = $after.disks; write = $write })
}

function Get-NxStorageD3State {
    <#
    .SYNOPSIS
        NX06-012 read-only state: documented StorageD3InModernStandby value, Modern
        Standby evidence, per-disk applicability and the NX09 boundary report.
    .DESCRIPTION
        Documented (Microsoft, power management for storage hardware): global registry
        value StorageD3InModernStandby (REG_DWORD) under
        HKLM\SYSTEM\CurrentControlSet\Control\Storage - 0 disables D3 support,
        1 enables it; unconfigured means Storport consults the ACPI _DSD and then the
        platform allowlist.
        Plan-level disk idle (SUB_DISK DISKIDLE) is NX09's: it is only READ here for
        context and never written. Per-device NVMe idle parameters are reported only -
        blanket Enum/class power-value sweeps are on the rejected list (r1/r2).
    #>
    [CmdletBinding()]
    param()
    $unc = New-Object System.Collections.Generic.List[string]
    $value = Capture-NxRegistryValue -Path $script:Nx06StorageKey -Name 'StorageD3InModernStandby'
    $inv = Get-NxStorageInventory
    $powerRaw = ''
    $s0Mentioned = $false
    $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    if (Test-Path -LiteralPath $powercfg) {
        $r = Invoke-Nx06Native -FilePath $powercfg -Arguments @('/a')
        $powerRaw = $r.text
        $s0Mentioned = $powerRaw -match '(?i)S0'
        if (-not $s0Mentioned) { $unc.Add('powercfg /a does not mention an S0 standby state - Modern Standby applicability uncertain') }
    } else { $unc.Add('powercfg.exe not found - Modern Standby evidence unavailable') }

    $planDiskIdle = @()
    $subDisk = '0012ee47-9041-4b5d-9b77-535fba8b1442'
    $diskIdle = '6738e2c4-e8a5-4a42-b16a-e040e769756e'
    if (Test-Path -LiteralPath $powercfg) {
        foreach ($plane in @('AC', 'DC')) {
            $q = Invoke-Nx06Native -FilePath $powercfg -Arguments @('/query', 'SCHEME_CURRENT', $subDisk, $diskIdle)
            $idx = $null
            $m = [regex]::Match($q.text, "(?is)$plane Power Setting Index:\s*0x([0-9a-fA-F]+)")
            if ($m.Success) { $idx = [Convert]::ToInt64($m.Groups[1].Value, 16) }
            $planDiskIdle += [pscustomobject]@{ plane = $plane; diskIdleSeconds = $idx; note = 'NX09 territory (plan-level power) - reported read-only, never written by NX06' }
        }
    }

    $applicable = @($inv.physicalDisks | Where-Object { $_.busType -in @('NVMe', 'SATA') })
    return [pscustomobject][ordered]@{
        functionName = 'Get-NxStorageD3State'
        readOnly     = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        registryPath = $script:Nx06StorageKey
        registryName = 'StorageD3InModernStandby'
        value        = [pscustomobject]@{ existed = $value.existed; kind = $value.kind; value = $value.value }
        semantic     = $(if (-not $value.existed) { 'NotConfigured (Storport consults ACPI _DSD, then platform allowlist)' } elseif ([int]$value.value -eq 0) { 'D3Disabled' } elseif ([int]$value.value -eq 1) { 'D3Enabled' } else { 'UnrecognizedValue' })
        modernStandbyS0Mentioned = $s0Mentioned
        powercfgRaw  = $powerRaw
        applicableDisks = $applicable
        planDiskIdle = $planDiskIdle
        notes        = @(
            'Plan-level disk idle timeouts (SUB_DISK DISKIDLE) belong to NX09 and are only reported here.',
            'Per-device NVMe/Storport idle registry parameters are never written by NX06 (blanket Enum power-value sweeps are rejected patterns).'
        )
        uncertainty  = $unc.ToArray()
        inventory    = $inv
    }
}

function Set-NxStorageD3Policy {
    <#
    .SYNOPSIS
        NX06-012: documented storage D3-in-Modern-Standby policy (0 = disable, 1 = enable).
    .DESCRIPTION
        Applies only the documented global value; report mode is available and the
        function skips honestly when no S0 (Modern Standby) state exists at all.
        Trade-off: disabling D3 keeps storage devices out of their deepest idle state
        during Modern Standby (potential resume latency benefit, higher standby power);
        enabling it does the opposite. Both directions are stated, neither is claimed
        as a measured outcome.
        Boundary: plan-level DISKIDLE and sleep settings are NX09's and are never
        written here; per-device idle parameters are never swept.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Report', 'PreventD3', 'AllowD3')][string]$Mode = 'PreventD3',
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$TweakId = 'NX06-012'
    )
    $warnings = @(
        'Trade-off (stated, not measured): disabling storage D3 in Modern Standby keeps drives out of their deepest idle state - potentially better resume behavior at the cost of standby power/heat; enabling D3 favours power savings.',
        'Documented default is "unconfigured": Storport then follows the ACPI _DSD and the platform allowlist. Rolling back NX06-012 restores that exact state (the value is deleted if NEXTRIX created it).',
        'Plan-level disk idle timeouts are NX09 territory and are never written by this entry.'
    )
    $state = Get-NxStorageD3State
    if ($Mode -eq 'Report' -or -not $Approved) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason "current storage D3 policy: $($state.semantic); nothing written" -Warnings $warnings -Details $state
    }
    if (-not $state.modernStandbyS0Mentioned) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Skipped' -Reason 'no S0 standby state is reported by powercfg /a - storage D3 in Modern Standby is not applicable on this platform' -Warnings $warnings -Details $state
    }
    Assert-Nx06JournalReady -JournalRoot $JournalRoot
    $desired = $(if ($Mode -eq 'PreventD3') { 0 } else { 1 })
    if ($state.value.existed -and [string]$state.value.kind -eq 'DWord' -and [int]$state.value.value -eq $desired) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'AlreadyApplied' -Reason "StorageD3InModernStandby already $desired" -Verified $true -Warnings $warnings -Details $state
    }
    if (-not $PSCmdlet.ShouldProcess("$($script:Nx06StorageKey) :: StorageD3InModernStandby", "Set DWord $desired")) {
        return New-Nx06Result -TweakId $TweakId -Outcome 'Report' -Reason 'WhatIf: no mutation, no journal write' -Warnings $warnings -Details $state
    }
    $write = Invoke-Nx06RegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $script:Nx06StorageKey -Name 'StorageD3InModernStandby' -Kind DWord -Value $desired -Profiles $Profiles
    $after = Get-NxStorageD3State
    return New-Nx06Result -TweakId $TweakId -Outcome $(if ($write.verified) { 'Applied' } else { 'Failed' }) -Reason ("registry write: $($write.reason); effective storage-stack behavior is applied at next storage re-enumeration/reboot (no runtime telemetry is claimed)") -Verified ([bool]$write.verified) -JournalSeq $write.journalSeq -Warnings $warnings -Details ([pscustomobject]@{ before = $state; after = $after; write = $write })
}

# ---------------------------------------------------------------------------
# 9. NX06-013 - drive health (SMART via documented storage cmdlets) - read-only
# ---------------------------------------------------------------------------

function Get-NxDriveHealthReport {
    <#
    .SYNOPSIS
        NX06-013: read-only drive health report (health status + storage reliability
        counters). No prediction claim, no writes.
    .DESCRIPTION
        HealthStatus/OperationalStatus come from Get-PhysicalDisk; temperature, wear
        and error/latency counters from Get-StorageReliabilityCounter; volume health
        from Get-Volume. Unsupported counters stay blank with an uncertainty note
        (many USB bridges and some RAID controllers do not forward them).
    #>
    [CmdletBinding()]
    param()
    $unc = New-Object System.Collections.Generic.List[string]
    $rows = New-Object System.Collections.Generic.List[object]
    $disks = @()
    try { $disks = @(Get-PhysicalDisk -ErrorAction Stop) } catch { $unc.Add("Get-PhysicalDisk failed: $($_.Exception.Message)") }
    foreach ($d in $disks) {
        $num = [int]$d.DeviceId
        $counter = [ordered]@{
            temperature = $null; temperatureMax = $null; wear = $null
            powerOnHours = $null; startStopCycleCount = $null; loadUnloadCycleCount = $null
            readErrorsTotal = $null; readErrorsUncorrected = $null; writeErrorsTotal = $null; writeErrorsUncorrected = $null
            readLatencyMax = $null; writeLatencyMax = $null; flushLatencyMax = $null
        }
        $counterAvailable = $false
        try {
            $pd = Get-PhysicalDisk -DeviceNumber $num -ErrorAction Stop
            $c = Get-StorageReliabilityCounter -PhysicalDisk $pd -ErrorAction Stop
            $counterAvailable = $true
            foreach ($p in @('Temperature', 'TemperatureMax', 'Wear', 'PowerOnHours', 'StartStopCycleCount', 'LoadUnloadCycleCount', 'ReadErrorsTotal', 'ReadErrorsUncorrected', 'WriteErrorsTotal', 'WriteErrorsUncorrected', 'ReadLatencyMax', 'WriteLatencyMax', 'FlushLatencyMax')) {
                $prop = $c.PSObject.Properties[$p]
                if ($null -ne $prop) {
                    $name = $p.Substring(0, 1).ToLowerInvariant() + $p.Substring(1)
                    if ($counter.Contains($name)) { $counter[$name] = $prop.Value }
                }
            }
        } catch { $unc.Add("disk $num : Get-StorageReliabilityCounter failed: $($_.Exception.Message)") }

        $health = [string]$d.HealthStatus
        $ops = @($d.OperationalStatus | ForEach-Object { [string]$_ })
        $verdict = 'Unknown'
        if ($health -eq 'Healthy' -and ($ops -notcontains 'Warning') -and ($ops -notcontains 'Degraded')) { $verdict = 'Healthy' }
        elseif ($health -eq 'Unhealthy' -or $ops -contains 'Lost Communication' -or $ops -contains 'Failed') { $verdict = 'Unhealthy' }
        elseif ($health -eq 'Warning' -or $ops -contains 'Warning' -or $ops -contains 'Degraded' -or $ops -contains 'Predictive Failure') { $verdict = 'Warning' }

        $rows.Add([pscustomobject][ordered]@{
            deviceNumber       = $num
            friendlyName       = [string]$d.FriendlyName
            mediaType          = [string]$d.MediaType
            busType            = [string]$d.BusType
            sizeBytes          = [int64]$d.Size
            healthStatus       = $health
            operationalStatus  = ($ops -join ',')
            verdict            = $verdict
            reliabilityCounterAvailable = $counterAvailable
            counters           = [pscustomobject]$counter
        })
    }
    $volHealth = @()
    try {
        $volHealth = @(Get-Volume -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.DriveLetter) } | ForEach-Object {
            [pscustomobject]@{ driveLetter = [string]$_.DriveLetter; fileSystem = [string]$_.FileSystem; healthStatus = [string]$_.HealthStatus }
        })
    } catch { $unc.Add("Get-Volume failed: $($_.Exception.Message)") }

    return [pscustomobject][ordered]@{
        functionName   = 'Get-NxDriveHealthReport'
        tweakId        = 'NX06-013'
        readOnly       = $true
        generatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        disks          = $rows.ToArray()
        volumes        = $volHealth
        uncertainty    = $unc.ToArray()
        caveats        = @(
            'SMART data availability depends on the controller/driver; blank counters mean "not reported", never "zero".',
            'This report does not predict failure. HealthStatus/OperationalStatus are Windows storage-stack verdicts, not a reliability model.',
            'No writes, no self-tests and no firmware actions are performed.'
        )
    }
}

# ---------------------------------------------------------------------------
# 10. NX06 rollback (non-registry target types only; registry entries are
#     restored by the shared engine in NxRollback.ps1)
# ---------------------------------------------------------------------------

function Get-Nx06RollbackCandidates {
    # PURE selection logic (testable without mutation): apply entries whose target
    # type the registry engine cannot restore itself. 'registry'/'function' entries
    # are deliberately excluded - NxRollback.ps1 owns them.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$JournalEntries)
    $restorable = @('fsutilBehavior', 'scheduledTask', 'fileDeletionSet', 'deliveryOptimizationCache', 'tempFileCleanup')
    return @($JournalEntries | Where-Object {
        $_.tweakId -like 'NX06-*' -and
        $_.operation -eq 'apply' -and
        (@('InProgress', 'Success', 'Success-Irreversible') -contains [string]$_.result) -and
        ($restorable -contains [string]$_.original.targetType)
    })
}

function Invoke-Nx06Rollback {
    <#
    .SYNOPSIS
        NX06 rollback replay for target types the shared engine does not handle:
        fsutil behavior values (exact registry restore + semantic alignment),
        the Optimize Drives task (journaled XML re-registration, only-if-ours), and
        irreversible deletions (reported honestly, never faked).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId,
        [switch]$AllNx06
    )
    if (-not $TweakId -and -not $AllNx06) {
        throw 'Invoke-Nx06Rollback: specify -TweakId or -AllNx06 (no implicit full-category rollback)'
    }
    $journal = Read-NxJournal -Path $JournalRoot
    if ($journal.integrityErrors.Count -gt 0) {
        return [pscustomobject]@{ aborted = $true; integrityErrors = $journal.integrityErrors; restored = @(); diverged = @(); failed = @(); irreversible = @() }
    }
    $candidates = Get-Nx06RollbackCandidates -JournalEntries $journal.entries
    if ($TweakId) { $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId }) }
    [array]::Reverse($candidates)

    $restored = New-Object System.Collections.Generic.List[object]
    $diverged = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]
    $irreversible = New-Object System.Collections.Generic.List[object]

    foreach ($e in $candidates) {
        $orig = $e.original; $mod = $e.modified
        $type = [string]$orig.targetType
        try {
            switch ($type) {
                'fsutilBehavior' {
                    $state = Get-NxNtfsBehaviorState -SkipVolumes
                    $liveState = $state.PSObject.Properties[[string]$orig.name]
                    if ($null -eq $liveState) {
                        $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $orig.name; reason = 'live fsutil state unknown for this setting' })
                        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo 'unsupported fsutil setting' -Profiles @($e.profiles)
                        break
                    }
                    $live = $liveState.Value
                    $ours = ($live.recognized -and $null -ne $mod.value -and [int]$live.value -eq [int]$mod.value)
                    if (-not $ours) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $orig.name; live = $live.value; reason = 'live value no longer equals the recorded modified value - left untouched for user decision' })
                        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: live fsutil state differs from recorded modified state' -Profiles @($e.profiles)
                        break
                    }
                    $actions = Restore-Nx06FsutilOriginal -Original $orig
                    $after = Get-NxNtfsBehaviorState -SkipVolumes
                    $afterLive = $null
                    $afterProp = $after.PSObject.Properties[[string]$orig.name]
                    if ($null -ne $afterProp) { $afterLive = $afterProp.Value }
                    $ok = ($null -ne $afterLive)
                    if ($ok -and $null -ne $orig.value -and $null -ne $afterLive.value -and [int]$afterLive.value -ne [int]$orig.value) { $ok = $false }
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified-RestartPending' } else { 'NotVerified' }) -ErrorInfo ($actions -join '; ') -Profiles @($e.profiles)
                    $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = "restored $($orig.name)"; detail = ($actions -join '; '); verified = $ok })
                }
                'scheduledTask' {
                    $live = Get-NxOptimizeDrivesState
                    $ours = ($live.present -and $live.maintenancePeriod -eq $mod.maintenancePeriod -and $live.maintenanceDeadline -eq $mod.maintenanceDeadline)
                    if ($null -ne $mod.enabled) { $ours = $ours -and ([bool]$live.enabled -eq [bool]$mod.enabled) }
                    if (-not $ours) {
                        $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "$($orig.taskPath)$($orig.taskName)"; reason = 'task schedule no longer equals the recorded modified state - left untouched' })
                        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: task state differs from recorded modified state' -Profiles @($e.profiles)
                        break
                    }
                    if ([string]::IsNullOrWhiteSpace([string]$orig.xml)) {
                        $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "$($orig.taskPath)$($orig.taskName)"; reason = 'journaled original XML missing - cannot re-register exactly' })
                        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo 'original task XML absent from journal' -Profiles @($e.profiles)
                        break
                    }
                    Register-ScheduledTask -TaskPath ([string]$orig.taskPath) -TaskName ([string]$orig.taskName) -Xml ([string]$orig.xml) -Force -ErrorAction Stop | Out-Null
                    $after = Get-NxOptimizeDrivesState
                    $ok = ($after.present -and $after.maintenancePeriod -eq $orig.maintenancePeriod -and $after.maintenanceDeadline -eq $orig.maintenanceDeadline)
                    if ($null -ne $orig.enabled) { $ok = $ok -and ([bool]$after.enabled -eq [bool]$orig.enabled) }
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles)
                    $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 're-registered original Optimize Drives task XML'; detail = "enabled=$($after.enabled) period=$($after.maintenancePeriod)"; verified = $ok })
                }
                default {
                    # Deletion-type operations: honest irreversibility, audit record only.
                    $irreversible.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $type; reason = 'operation deleted data at apply time and is labeled irreversible - manual recovery only (audit record kept)' })
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Skipped-Irreversible' -Verification 'NotRun' -ErrorInfo 'apply entry labeled irreversible; no restore path exists' -Profiles @($e.profiles)
                }
            }
        } catch {
            $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $type; reason = [string]$_.Exception.Message })
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'failed' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles @($e.profiles)
        }
    }
    return [pscustomobject]@{
        aborted      = $false
        restored     = $restored.ToArray()
        diverged     = $diverged.ToArray()
        failed       = $failed.ToArray()
        irreversible = $irreversible.ToArray()
        integrityErrors = @()
    }
}
