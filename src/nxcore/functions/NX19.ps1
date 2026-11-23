#Requires -Version 5.1
<#
    NX19.ps1 - NEXTRIX CPU Topology & Scheduling category functions.

    DESIGN REFERENCE (reference-only, no code copied): the XOS Toolkit topology
    approach summarised in research/sources/r1-fsosx-xos.md and adopted in
    docs/RESEARCH_RECONCILIATION.md register items 6/7:
      GetLogicalProcessorInformationEx(RelationProcessorCore)
        -> per-core SMT flag + EfficiencyClass tier (and RelativePerformance/
           RelativeEfficiency when the OS supplies them)
      RelationProcessorDie -> die / CCD groups
      RelationCache (level 3) -> per-die L3 bytes -> X3D by >2x asymmetry,
        NEVER by a CPU marketing-name list
      GetSystemCpuSetInformation -> logical-processor-index -> CPU Set ID map
      cross-group logical indexing = group*64 + lp
    This implementation is original NEXTRIX code: every index is derived from
    the OS buffers at run time; no core index, die index or CPU name is baked
    into any selection rule.

    SAFETY / SCOPE:
      - Read-only diagnostics by default. NX19-001/002/006-011 never mutate.
      - Process CPU sets (003), process affinity (004) and process priority (005)
        are SESSION-SCOPED: they last only while the target process lives, write
        no registry value and are not persisted. Every application is journaled
        with targetType 'processCpuSets' / 'processAffinity' / 'processPriority'
        for audit; rollback restores the recorded original while the process is
        still running (a process that already ended needs no restore).
      - CPU Sets and affinity are SEPARATE mechanisms. CPU Sets are the default
        (Microsoft: "soft" affinity compatible with power management); affinity
        is opt-in and refused unless the selection fits one processor group.
      - Anti-cheat rationale (reference-reported, XOS README [r1], not a
        Microsoft guarantee): default CPU sets are tolerated by more anti-cheat
        software than affinity masks, which some anti-cheats block or override.
      - No performance claim is made anywhere in this module.

    DOCUMENTED APIs (Microsoft Learn; all verified in this session):
      https://learn.microsoft.com/windows/win32/api/sysinfoapi/nf-sysinfoapi-getlogicalprocessorinformationex
      https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-processor_relationship
      https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-system_cpu_set_information
      https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemcpusetinformation
      https://learn.microsoft.com/windows/win32/procthread/cpu-sets
      https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocessdefaultcpusets
      https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessdefaultcpusets
      https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-getprocessaffinitymask
      https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-setprocessaffinitymask
      https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-setpriorityclass

    Dependencies: dot-source AFTER the core modules. This file USES:
      Add-NxJournalEntry, Read-NxJournal, Read-NxManifest (NxJournal.ps1)
    Loading it defines functions only: no Add-Type, no process access, no file
    or registry access happens at load time.
#>

# ---------------------------------------------------------------------------
# 0. Native interop (lazy; a failure is reported as uncertainty, never guessed)
# ---------------------------------------------------------------------------

$script:Nx19NativeState = $null
$script:Nx19MaxSelectedCpuSets = 32   # NEXTRIX implementation bound (bounded payload)
$script:Nx19MaxProcessMatches = 16     # bounded fan-out for a process-name rule

$script:Nx19AntiCheatNote = 'Microsoft documents CPU Sets as a declared, "soft" affinity mechanism that the scheduler applies together with power management (learn.microsoft.com/windows/win32/procthread/cpu-sets). The XOS Toolkit README (reference, r1) reports that default CPU sets are tolerated by more anti-cheat software than affinity masks, which it says some anti-cheats block or override. NEXTRIX therefore defaults to CPU Sets and treats affinity as an explicit opt-in mechanism. This is a reference-reported compatibility note, not a Microsoft-documented guarantee.'

function Get-Nx19NativeSource {
    # Inline C# interop. No configuration is read or written; the class only
    # exposes documented kernel32 entry points and returns raw buffers.
    return @'
using System;
using System.Runtime.InteropServices;

public static class Nx19Native
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetLogicalProcessorInformationEx(int relationship, IntPtr buffer, ref uint returnedLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemCpuSetInformation(IntPtr info, uint bufferLength, ref uint returnedLength, IntPtr process, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessDefaultCpuSets(IntPtr process, uint[] cpuSetIds, uint count);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessDefaultCpuSets(IntPtr process, [Out] uint[] cpuSetIds, uint count, out uint required);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessAffinityMask(IntPtr process, UIntPtr mask);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessAffinityMask(IntPtr process, out UIntPtr processMask, out UIntPtr systemMask);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetPriorityClass(IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetPriorityClass(IntPtr process, uint priorityClass);

    [DllImport("kernel32.dll")]
    private static extern uint GetActiveProcessorGroupCount();

    [DllImport("kernel32.dll")]
    private static extern uint GetActiveProcessorCount(ushort groupNumber);

    public static byte[] ReadRelationshipBuffer(int relationship, out int error)
    {
        error = 0;
        uint length = 0;
        GetLogicalProcessorInformationEx(relationship, IntPtr.Zero, ref length);
        int first = Marshal.GetLastWin32Error();
        if (length == 0) { error = first; return null; }
        IntPtr buffer = Marshal.AllocHGlobal((int)length);
        try
        {
            uint returned = length;
            if (!GetLogicalProcessorInformationEx(relationship, buffer, ref returned))
            {
                error = Marshal.GetLastWin32Error();
                return null;
            }
            int copyLength = (int)Math.Min(returned, length);
            byte[] copy = new byte[copyLength];
            Marshal.Copy(buffer, copy, 0, copyLength);
            return copy;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static byte[] ReadCpuSetBuffer(out int error)
    {
        error = 0;
        uint length = 0;
        GetSystemCpuSetInformation(IntPtr.Zero, 0, ref length, IntPtr.Zero, 0);
        int first = Marshal.GetLastWin32Error();
        if (length == 0) { error = first; return null; }
        IntPtr buffer = Marshal.AllocHGlobal((int)length);
        try
        {
            uint returned = length;
            if (!GetSystemCpuSetInformation(buffer, length, ref returned, IntPtr.Zero, 0))
            {
                error = Marshal.GetLastWin32Error();
                return null;
            }
            int copyLength = (int)Math.Min(returned, length);
            byte[] copy = new byte[copyLength];
            Marshal.Copy(buffer, copy, 0, copyLength);
            return copy;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static uint GetGroupCount() { return GetActiveProcessorGroupCount(); }

    public static uint GetGroupProcessorCount(ushort group) { return GetActiveProcessorCount(group); }

    public static IntPtr Open(uint access, uint pid) { return OpenProcess(access, false, pid); }

    public static bool Close(IntPtr handle) { return CloseHandle(handle); }

    public static uint[] ReadDefaultCpuSets(IntPtr process, out int error)
    {
        error = 0;
        uint required = 0;
        if (!GetProcessDefaultCpuSets(process, null, 0, out required))
        {
            int e = Marshal.GetLastWin32Error();
            if (e != 122) { error = e; return null; }
        }
        if (required == 0) { return new uint[0]; }
        uint[] ids = new uint[required];
        uint filled = 0;
        if (!GetProcessDefaultCpuSets(process, ids, required, out filled))
        {
            error = Marshal.GetLastWin32Error();
            return null;
        }
        if (filled < (uint)ids.Length) { Array.Resize(ref ids, (int)filled); }
        return ids;
    }

    public static bool WriteDefaultCpuSets(IntPtr process, uint[] ids)
    {
        return SetProcessDefaultCpuSets(process, ids, (uint)(ids == null ? 0 : ids.Length));
    }

    public static bool ClearDefaultCpuSets(IntPtr process)
    {
        return SetProcessDefaultCpuSets(process, null, 0);
    }

    public static bool ReadAffinity(IntPtr process, out ulong processMask, out ulong systemMask, out int error)
    {
        error = 0;
        processMask = 0;
        systemMask = 0;
        UIntPtr p;
        UIntPtr s;
        if (!GetProcessAffinityMask(process, out p, out s))
        {
            error = Marshal.GetLastWin32Error();
            return false;
        }
        processMask = p.ToUInt64();
        systemMask = s.ToUInt64();
        return true;
    }

    public static bool WriteAffinity(IntPtr process, ulong mask, out int error)
    {
        error = 0;
        if (!SetProcessAffinityMask(process, new UIntPtr(mask)))
        {
            error = Marshal.GetLastWin32Error();
            return false;
        }
        return true;
    }

    public static uint ReadPriority(IntPtr process, out int error)
    {
        error = 0;
        uint value = GetPriorityClass(process);
        if (value == 0) { error = Marshal.GetLastWin32Error(); }
        return value;
    }

    public static bool WritePriority(IntPtr process, uint value, out int error)
    {
        error = 0;
        if (!SetPriorityClass(process, value))
        {
            error = Marshal.GetLastWin32Error();
            return false;
        }
        return true;
    }
}
'@
}

function Initialize-Nx19Native {
    <#
    .SYNOPSIS
        Lazily compiles the NX19 interop class. Returns an explicit state object.
    .DESCRIPTION
        A compile or load failure is NOT fatal: every caller receives
        available=false with the reason and must report Uncertainty instead of
        guessing a topology. The result is cached for the session.
    #>
    [CmdletBinding()]
    param()
    if ($null -ne $script:Nx19NativeState) { return $script:Nx19NativeState }

    $state = [pscustomobject]@{
        attempted   = $true
        available   = $false
        reason      = $null
        compiledUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    try {
        $existing = $null
        try { $existing = 'Nx19Native' -as [type] } catch { $existing = $null }
        if ($null -eq $existing) {
            Add-Type -TypeDefinition (Get-Nx19NativeSource) -Language CSharp -ErrorAction Stop
        }
        $state.available = $true
        $state.reason = 'Interop class loaded.'
    } catch {
        $state.available = $false
        $state.reason = "P/Invoke interop unavailable: $($_.Exception.Message)"
    }
    $script:Nx19NativeState = $state
    return $state
}

function Get-Nx19NativeStatus {
    <#
    .SYNOPSIS
        Read-only report of the interop layer state (no API call is made here).
    .DESCRIPTION
        Reports whether Add-Type succeeded, the process bitness (which determines
        the KAFFINITY width used by the parsers) and the maximum CPU set bound.
        available=false means every topology function reports Uncertainty.
    #>
    [CmdletBinding()]
    param()
    $state = Initialize-Nx19Native
    return [pscustomobject]@{
        readOnly                  = $true
        noWritesPerformed         = $true
        available                 = [bool]$state.available
        reason                    = [string]$state.reason
        processBitness            = [int]([IntPtr]::Size * 8)
        affinityMaskWidth         = [int]([IntPtr]::Size * 8)
        maxSelectedCpuSets        = [int]$script:Nx19MaxSelectedCpuSets
        maxProcessMatchesPerRule  = [int]$script:Nx19MaxProcessMatches
        groupAffinityStrideBytes  = [int]([IntPtr]::Size + 8)
        compiledUtc               = [string]$state.compiledUtc
    }
}

# ---------------------------------------------------------------------------
# 1. Pure byte-buffer parsers (synthetic-buffer testable; no API calls)
# ---------------------------------------------------------------------------

function Get-NxMaskLogicalProcessors {
    <#
    .SYNOPSIS
        Pure helper: expands one GROUP_AFFINITY mask into global logical indexes.
    .DESCRIPTION
        Cross-group indexing is group*64 + bit, per the documented processor-group
        model. The mask is walked one bit at a time so bit 63 is handled without
        relying on host-specific shift behaviour.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uint64]$Mask,
        [Parameter(Mandatory)][uint16]$Group
    )
    $list = New-Object System.Collections.Generic.List[int]
    $value = [uint64]$Mask
    for ($bit = 0; $bit -lt 64; $bit++) {
        if (($value -band [uint64]1) -eq [uint64]1) {
            $list.Add(([int]$Group * 64) + $bit)
        }
        $value = [uint64]($value -shr 1)
    }
    return $list.ToArray()
}

function Read-NxGroupAffinityArray {
    # Internal: reads GroupCount GROUP_AFFINITY entries starting at Offset.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Buffer,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][int]$GroupCount
    )
    $groups = New-Object System.Collections.Generic.List[object]
    $stride = [IntPtr]::Size + 8
    for ($g = 0; $g -lt $GroupCount; $g++) {
        $pos = $Offset + ($g * $stride)
        if (($pos + $stride) -gt $Buffer.Length) { break }
        if ([IntPtr]::Size -eq 8) {
            $mask = [uint64][System.BitConverter]::ToUInt64($Buffer, $pos)
        } else {
            $mask = [uint64][System.BitConverter]::ToUInt32($Buffer, $pos)
        }
        $group = [uint16][System.BitConverter]::ToUInt16($Buffer, ($pos + [IntPtr]::Size))
        $groups.Add([pscustomobject]@{
            group               = $group
            mask                = $mask
            logicalProcessors   = @(Get-NxMaskLogicalProcessors -Mask $mask -Group $group)
        })
    }
    return $groups.ToArray()
}

function ConvertFrom-NxLpCoreBuffer {
    <#
    .SYNOPSIS
        PURE parser: SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX buffer with
        Relationship = RelationProcessorCore (0).
    .DESCRIPTION
        Reads consecutive variable-sized entries, using each entry's Size field to
        advance (the documented iteration contract). Fixed offsets used:
          +0  DWORD Relationship (0 = RelationProcessorCore)
          +4  DWORD Size              +8  BYTE Flags (bit 0 = LTP_PC_SMT)
          +9  BYTE EfficiencyClass
          +10 WORD  RelativePerformance (may be 0 on older builds)
          +12 WORD  RelativeEfficiency  (may be 0 on older builds)
          +30 WORD  GroupCount        +32 GroupMask[GroupCount]
        Entries with another relationship id are skipped, not trusted. A short or
        malformed buffer stops the scan and sets truncated=$true - the caller must
        surface that as uncertainty rather than infer the missing cores.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Buffer
    )
    $entries = New-Object System.Collections.Generic.List[object]
    $truncated = $false
    $skipped = 0
    $offset = 0
    $index = 0
    while (($offset + 8) -le $Buffer.Length) {
        $relationship = [System.BitConverter]::ToUInt32($Buffer, $offset)
        $sizeValue = [System.BitConverter]::ToUInt32($Buffer, ($offset + 4))
        if ($sizeValue -lt 8 -or (([long]$offset + [long]$sizeValue) -gt [long]$Buffer.Length)) { $truncated = $true; break }
        $size = [int]$sizeValue
        if ($relationship -ne 0) { $skipped++; $offset += $size; continue }
        if (($offset + 32) -gt $Buffer.Length) { $truncated = $true; break }
        $flags = [int]$Buffer[$offset + 8]
        $efficiencyClass = [int]$Buffer[$offset + 9]
        $relativePerformance = [int][System.BitConverter]::ToUInt16($Buffer, ($offset + 10))
        $relativeEfficiency = [int][System.BitConverter]::ToUInt16($Buffer, ($offset + 12))
        $groupCount = [int][System.BitConverter]::ToUInt16($Buffer, ($offset + 30))
        $groups = @()
        if ($groupCount -gt 0) {
            $groups = @(Read-NxGroupAffinityArray -Buffer $Buffer -Offset ($offset + 32) -GroupCount $groupCount)
        } else {
            $truncated = $true
        }
        $lps = @($groups | ForEach-Object { $_.logicalProcessors } | Sort-Object -Unique)
        $primary = $null
        if ($lps.Count -gt 0) { $primary = [int]($lps | Measure-Object -Minimum).Minimum }
        $entries.Add([pscustomobject]@{
            coreIndex             = $index
            efficiencyClass       = $efficiencyClass
            relativePerformance   = $relativePerformance
            relativeEfficiency    = $relativeEfficiency
            hasSmt                = (($flags -band 1) -eq 1)
            groupCount            = $groupCount
            groups                = $groups
            logicalProcessors     = $lps
            primaryLogicalProcessor = $primary
        })
        $index++
        $offset += $size
    }
    return [pscustomobject]@{
        entries       = $entries.ToArray()
        entryCount    = $entries.Count
        skippedEntries = $skipped
        truncated     = $truncated
        parsedBytes   = $offset
        bufferBytes   = $Buffer.Length
    }
}

function ConvertFrom-NxLpCacheBuffer {
    <#
    .SYNOPSIS
        PURE parser: RelationCache (2) entries from the same buffer family.
    .DESCRIPTION
        Fixed offsets:
          +0 DWORD Relationship  +4 DWORD Size
          +8 BYTE Level  +9 BYTE Associativity  +10 WORD LineSize
          +12 DWORD CacheSize  +16 DWORD Type (0 unified, 1 instruction, 2 data, 3 trace)
          +38 WORD GroupCount  +40 GroupMask[GroupCount]
        Level and size are reported verbatim; callers filter level 3.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Buffer
    )
    $entries = New-Object System.Collections.Generic.List[object]
    $truncated = $false
    $skipped = 0
    $offset = 0
    $index = 0
    while (($offset + 8) -le $Buffer.Length) {
        $relationship = [System.BitConverter]::ToUInt32($Buffer, $offset)
        $sizeValue = [System.BitConverter]::ToUInt32($Buffer, ($offset + 4))
        if ($sizeValue -lt 8 -or (([long]$offset + [long]$sizeValue) -gt [long]$Buffer.Length)) { $truncated = $true; break }
        $size = [int]$sizeValue
        if ($relationship -ne 2) { $skipped++; $offset += $size; continue }
        if (($offset + 40) -gt $Buffer.Length) { $truncated = $true; break }
        $groupCount = [int][System.BitConverter]::ToUInt16($Buffer, ($offset + 38))
        $groups = @()
        if ($groupCount -gt 0) {
            $groups = @(Read-NxGroupAffinityArray -Buffer $Buffer -Offset ($offset + 40) -GroupCount $groupCount)
        } else {
            $truncated = $true
        }
        $lps = @($groups | ForEach-Object { $_.logicalProcessors } | Sort-Object -Unique)
        $entries.Add([pscustomobject]@{
            cacheIndex        = $index
            level             = [int]$Buffer[$offset + 8]
            associativity     = [int]$Buffer[$offset + 9]
            lineSize          = [int][System.BitConverter]::ToUInt16($Buffer, ($offset + 10))
            cacheSize         = [long][System.BitConverter]::ToUInt32($Buffer, ($offset + 12))
            type              = [uint32][System.BitConverter]::ToUInt32($Buffer, ($offset + 16))
            groupCount        = $groupCount
            groups            = $groups
            logicalProcessors = $lps
        })
        $index++
        $offset += $size
    }
    return [pscustomobject]@{
        entries        = $entries.ToArray()
        entryCount     = $entries.Count
        skippedEntries = $skipped
        truncated      = $truncated
        parsedBytes    = $offset
        bufferBytes    = $Buffer.Length
    }
}

function ConvertFrom-NxLpDieBuffer {
    <#
    .SYNOPSIS
        PURE parser: RelationProcessorDie (5) entries.
    .DESCRIPTION
        The die relationship reuses the PROCESSOR_RELATIONSHIP payload layout
        (Flags/EfficiencyClass/GroupCount/GroupMask), so the same fixed offsets
        as the core parser apply. An empty buffer is a normal "dies unsupported"
        result on builds that reject RelationProcessorDie; the caller must flag
        it, never invent a die layout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Buffer
    )
    $entries = New-Object System.Collections.Generic.List[object]
    $truncated = $false
    $skipped = 0
    $offset = 0
    $index = 0
    while (($offset + 8) -le $Buffer.Length) {
        $relationship = [System.BitConverter]::ToUInt32($Buffer, $offset)
        $sizeValue = [System.BitConverter]::ToUInt32($Buffer, ($offset + 4))
        if ($sizeValue -lt 8 -or (([long]$offset + [long]$sizeValue) -gt [long]$Buffer.Length)) { $truncated = $true; break }
        $size = [int]$sizeValue
        if ($relationship -ne 5) { $skipped++; $offset += $size; continue }
        if (($offset + 32) -gt $Buffer.Length) { $truncated = $true; break }
        $groupCount = [int][System.BitConverter]::ToUInt16($Buffer, ($offset + 30))
        $groups = @()
        if ($groupCount -gt 0) {
            $groups = @(Read-NxGroupAffinityArray -Buffer $Buffer -Offset ($offset + 32) -GroupCount $groupCount)
        } else {
            $truncated = $true
        }
        $lps = @($groups | ForEach-Object { $_.logicalProcessors } | Sort-Object -Unique)
        $entries.Add([pscustomobject]@{
            dieIndex          = $index
            groupCount        = $groupCount
            groups            = $groups
            logicalProcessors = $lps
        })
        $index++
        $offset += $size
    }
    return [pscustomobject]@{
        entries        = $entries.ToArray()
        entryCount     = $entries.Count
        skippedEntries = $skipped
        truncated      = $truncated
        parsedBytes    = $offset
        bufferBytes    = $Buffer.Length
    }
}

function ConvertFrom-NxCpuSetBuffer {
    <#
    .SYNOPSIS
        PURE parser: SYSTEM_CPU_SET_INFORMATION entries from
        GetSystemCpuSetInformation.
    .DESCRIPTION
        Documented layout (winnt.h) at the documented offsets:
          +0 DWORD Size  +4 DWORD Type (0 = CpuSet)
          +8 DWORD Id    +12 WORD Group  +14 BYTE LogicalProcessorIndex
          +15 BYTE CoreIndex  +16 BYTE LastLevelCacheIndex
          +17 BYTE NumaNodeIndex  +18 BYTE EfficiencyClass
          +19 BYTE flags (Parked/Allocated/AllocatedToTargetProcess/RealTime)
          +20 BYTE SchedulingClass (union with a reserved DWORD)
        The structure is variable-sized for future expansion: each entry's Size
        advances the scan. Unknown Type values are skipped as documented.
        globalLogicalProcessor = Group*64 + LogicalProcessorIndex.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Buffer
    )
    $entries = New-Object System.Collections.Generic.List[object]
    $truncated = $false
    $skipped = 0
    $offset = 0
    while (($offset + 8) -le $Buffer.Length) {
        $sizeValue = [System.BitConverter]::ToUInt32($Buffer, $offset)
        if ($sizeValue -lt 32 -or (([long]$offset + [long]$sizeValue) -gt [long]$Buffer.Length)) { $truncated = $true; break }
        $size = [int]$sizeValue
        $type = [System.BitConverter]::ToUInt32($Buffer, ($offset + 4))
        if ($type -ne 0) { $skipped++; $offset += $size; continue }
        $group = [uint16][System.BitConverter]::ToUInt16($Buffer, ($offset + 12))
        $lpIndex = [int]$Buffer[$offset + 14]
        $flags = [int]$Buffer[$offset + 19]
        $entries.Add([pscustomobject]@{
            cpuSetId                 = [uint32][System.BitConverter]::ToUInt32($Buffer, ($offset + 8))
            group                    = $group
            logicalProcessorIndex    = $lpIndex
            globalLogicalProcessor   = ([int]$group * 64) + $lpIndex
            coreIndex                = [int]$Buffer[$offset + 15]
            lastLevelCacheIndex      = [int]$Buffer[$offset + 16]
            numaNodeIndex            = [int]$Buffer[$offset + 17]
            efficiencyClass          = [int]$Buffer[$offset + 18]
            schedulingClass          = [int]$Buffer[$offset + 20]
            parked                   = (($flags -band 1) -eq 1)
            allocated                = (($flags -band 2) -eq 2)
            allocatedToTargetProcess = (($flags -band 4) -eq 4)
            realTime                 = (($flags -band 8) -eq 8)
            entrySize                = $size
        })
        $offset += $size
    }
    return [pscustomobject]@{
        entries        = $entries.ToArray()
        entryCount     = $entries.Count
        skippedEntries = $skipped
        truncated      = $truncated
        parsedBytes    = $offset
        bufferBytes    = $Buffer.Length
    }
}

# ---------------------------------------------------------------------------
# 2. Topology model (pure composition of parsed buffers)
# ---------------------------------------------------------------------------

function Test-NxX3dAsymmetry {
    <#
    .SYNOPSIS
        PURE X3D heuristic: >2x per-die L3 asymmetry, never a CPU-name list.
    .DESCRIPTION
        A die is "large L3" when its summed L3 is strictly more than twice the
        smallest positive per-die L3. Fewer than two dies reporting L3, missing
        die data, or equal sizes produce an explicit NotDeterminable /
        NoAsymmetryDetected result - the function never guesses X3D from a name.
        The threshold (2x, strict) is NEXTRIX's documented heuristic, adopted
        from the reference approach (r1), and is always flagged BestEffort when
        it fires.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][long[]]$PerDieL3Bytes,
        [bool]$DiesSupported = $true
    )
    $values = @($PerDieL3Bytes)
    if (-not $DiesSupported) {
        return [pscustomobject]@{
            indicated            = $false
            confidence           = 'NotDeterminable'
            evidence             = 'per-die-L3-asymmetry'
            largeDieIndexes      = @()
            perDieL3Bytes        = $values
            thresholdRatio       = 2.0
            observedRatio        = $null
            reason               = 'The processor-die relationship is unavailable on this system, so per-die L3 cannot be attributed. No X3D inference is made.'
        }
    }
    if ($values.Count -lt 1) {
        return [pscustomobject]@{
            indicated            = $false
            confidence           = 'NotDeterminable'
            evidence             = 'per-die-L3-asymmetry'
            largeDieIndexes      = @()
            perDieL3Bytes        = $values
            thresholdRatio       = 2.0
            observedRatio        = $null
            reason               = 'No dies were reported; per-die L3 asymmetry cannot be evaluated. No X3D inference is made.'
        }
    }
    if ($values.Count -eq 1) {
        return [pscustomobject]@{
            indicated            = $false
            confidence           = 'NoAsymmetryDetected'
            evidence             = 'per-die-L3-asymmetry'
            largeDieIndexes      = @()
            perDieL3Bytes        = $values
            thresholdRatio       = 2.0
            observedRatio        = $null
            reason               = 'A single die was reported, so there is no inter-die L3 asymmetry to evaluate. No X3D-specific placement is offered (a single-CCD layout has no second die to steer work to).'
        }
    }
    $positive = @()
    for ($i = 0; $i -lt $values.Count; $i++) {
        if ($values[$i] -gt 0) { $positive += [pscustomobject]@{ index = $i; size = [long]$values[$i] } }
    }
    if ($positive.Count -lt 2) {
        return [pscustomobject]@{
            indicated            = $false
            confidence           = 'NotDeterminable'
            evidence             = 'per-die-L3-asymmetry'
            largeDieIndexes      = @()
            perDieL3Bytes        = $values
            thresholdRatio       = 2.0
            observedRatio        = $null
            reason               = 'Only one die reports a positive level-3 cache size; asymmetry cannot be evaluated. No X3D inference is made.'
        }
    }
    $sizes = @($positive | ForEach-Object { [long]$_.size })
    $min = [long](($sizes | Measure-Object -Minimum).Minimum)
    $max = [long](($sizes | Measure-Object -Maximum).Maximum)
    $large = @()
    foreach ($p in $positive) {
        if ([long]$p.size -gt ([long]$min * 2)) { $large += [int]$p.index }
    }
    $ratio = $null
    if ($min -gt 0) { $ratio = [math]::Round(([double]$max / [double]$min), 4) }
    if ($large.Count -gt 0) {
        return [pscustomobject]@{
            indicated            = $true
            confidence           = 'BestEffort'
            evidence             = 'per-die-L3-asymmetry'
            largeDieIndexes      = $large
            perDieL3Bytes        = $values
            thresholdRatio       = 2.0
            observedRatio        = $ratio
            reason               = ("Per-die level-3 cache is asymmetric beyond 2x (largest {0} bytes vs smallest {1} bytes); die(s) {2} are treated as large-L3 dies. This is a best-effort cache-size signal, not a CPU-name identification." -f $max, $min, (($large | ForEach-Object { "CCD $_" }) -join ', '))
        }
    }
    return [pscustomobject]@{
        indicated            = $false
        confidence           = 'NoAsymmetryDetected'
        evidence             = 'per-die-L3-asymmetry'
        largeDieIndexes      = @()
        perDieL3Bytes        = $values
        thresholdRatio       = 2.0
        observedRatio        = $ratio
        reason               = 'Per-die level-3 cache sizes do not differ by more than 2x; no large-L3 die is indicated. No X3D-specific placement is offered.'
    }
}

function New-NxTopologyModel {
    <#
    .SYNOPSIS
        PURE composition: parsed relation buffers -> derived topology model.
    .DESCRIPTION
        Tiers: each distinct EfficiencyClass becomes a tier. The performance
        ranking uses RelativePerformance when the OS supplies it; otherwise it
        uses the documented EfficiencyClass direction ("a core with a higher
        value for the efficiency class has intrinsically greater performance",
        PROCESSOR_RELATIONSHIP/MS docs) and marks that ranking uncertain because
        vendor enumeration can differ in practice. Roles are descriptive:
        P (highest performance rank), E (next), LP-E (lower ranks), or Standard
        when a single class exists. Raw numeric classes are always preserved.
        Dies: RelationProcessorDie groups; L3 caches are attributed to the die
        with the largest logical-processor overlap. Everything here is derived -
        no index or name is assumed.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$CoreEntries = @(),
        [AllowEmptyCollection()][object[]]$CacheEntries = @(),
        [AllowEmptyCollection()][object[]]$DieEntries = @(),
        [AllowEmptyCollection()][object[]]$CpuSetEntries = @(),
        [int]$GroupCount = 1,
        [int[]]$GroupProcessorCounts = @(),
        [AllowEmptyCollection()][string[]]$Uncertainty = @()
    )
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($u in @($Uncertainty)) { if ($u) { $notes.Add([string]$u) } }

    $coresRaw = @($CoreEntries)
    $cachesRaw = @($CacheEntries)
    $diesRaw = @($DieEntries)
    $setsRaw = @($CpuSetEntries)

    # ---- efficiency tiers -------------------------------------------------
    $classMap = @{}
    foreach ($c in $coresRaw) {
        $cls = [int]$c.efficiencyClass
        if (-not $classMap.ContainsKey($cls)) {
            $classMap[$cls] = [pscustomobject]@{
                efficiencyClass        = $cls
                coreIndexes            = New-Object System.Collections.Generic.List[int]
                logicalProcessors      = New-Object System.Collections.Generic.List[int]
                maxRelativePerformance = 0
                maxRelativeEfficiency  = 0
                role                   = 'Standard'
            }
        }
        $classMap[$cls].coreIndexes.Add([int]$c.coreIndex)
        if ($null -ne $c.logicalProcessors) { foreach ($lp in @($c.logicalProcessors)) { $classMap[$cls].logicalProcessors.Add([int]$lp) } }
        if ([int]$c.relativePerformance -gt $classMap[$cls].maxRelativePerformance) { $classMap[$cls].maxRelativePerformance = [int]$c.relativePerformance }
        if ([int]$c.relativeEfficiency -gt $classMap[$cls].maxRelativeEfficiency) { $classMap[$cls].maxRelativeEfficiency = [int]$c.relativeEfficiency }
    }
    $classes = @($classMap.Keys | Sort-Object)
    $isHybrid = ($classes.Count -gt 1)
    $relativeAvailable = $false
    if ($classes.Count -gt 0) {
        $relativeAvailable = (@($classes | Where-Object { $classMap[$_].maxRelativePerformance -le 0 }).Count -eq 0)
    }
    $rankingSource = 'EfficiencyClassDocumentedPolarity'
    $rankingCertainty = 'DocumentedPolarity-Uncertain'
    $ranked = @()
    if ($classes.Count -gt 0 -and -not $isHybrid) {
        $rankingSource = 'SingleTier'
        $rankingCertainty = 'NotApplicable-SingleTier'
        $ranked = @($classMap[$classes[0]])
    } elseif ($relativeAvailable) {
        $rankingSource = 'RelativePerformance'
        $rankingCertainty = 'DerivedFromRelativePerformance'
        $ranked = @($classes | ForEach-Object { $classMap[$_] } | Sort-Object -Property @{ Expression = { $_.maxRelativePerformance }; Descending = $true }, @{ Expression = { $_.efficiencyClass }; Descending = $true })
    } else {
        # Documented direction: higher EfficiencyClass = greater performance.
        $ranked = @($classes | ForEach-Object { $classMap[$_] } | Sort-Object -Property @{ Expression = { $_.efficiencyClass }; Descending = $true })
        if ($isHybrid) {
            $notes.Add('Efficiency-class polarity: RelativePerformance was not supplied by the OS, so performance ranking follows the documented direction (higher EfficiencyClass = greater performance, learn.microsoft.com PROCESSOR_RELATIONSHIP). Some platforms enumerate cores in the opposite numeric order; the raw class values are reported so the owner can verify. P/E-specific pinning is withheld when this ranking is uncertain.')
        }
    }
    for ($i = 0; $i -lt $ranked.Count; $i++) {
        $role = 'Standard'
        if ($isHybrid) {
            if ($i -eq 0) { $role = 'P' }
            elseif ($i -eq 1) { $role = 'E' }
            else { $role = 'LP-E' }
        }
        $ranked[$i].role = $role
    }

    # ---- cores with derived roles ----------------------------------------
    $cores = New-Object System.Collections.Generic.List[object]
    foreach ($c in $coresRaw) {
        $cls = [int]$c.efficiencyClass
        $role = 'Standard'
        if ($classMap.ContainsKey($cls)) { $role = [string]$classMap[$cls].role }
        $lps = @()
        if ($null -ne $c.logicalProcessors) { $lps = @($c.logicalProcessors | Sort-Object -Unique) }
        $cores.Add([pscustomobject]@{
            coreIndex               = [int]$c.coreIndex
            efficiencyClass         = $cls
            tierRole                = $role
            hasSmt                  = [bool]$c.hasSmt
            relativePerformance     = [int]$c.relativePerformance
            relativeEfficiency      = [int]$c.relativeEfficiency
            groupCount              = [int]$c.groupCount
            logicalProcessors       = $lps
            logicalProcessorCount   = $lps.Count
            primaryLogicalProcessor = $c.primaryLogicalProcessor
        })
    }

    # ---- class pools ------------------------------------------------------
    $classPools = [ordered]@{}
    foreach ($role in @('P','E','LP-E','Standard')) {
        $roleCores = @($cores | Where-Object { $_.tierRole -eq $role })
        if ($roleCores.Count -eq 0) { continue }
        $roleLps = @($roleCores | ForEach-Object { $_.logicalProcessors } | Sort-Object -Unique)
        $rolePrimary = @($roleCores | ForEach-Object { $_.primaryLogicalProcessor } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
        $classPools[$role] = [pscustomobject]@{
            role                    = $role
            coreIndexes             = @($roleCores | ForEach-Object { $_.coreIndex })
            logicalProcessors       = $roleLps
            primaryLogicalProcessors = $rolePrimary
        }
    }

    # ---- dies and per-die L3 ---------------------------------------------
    $allLps = @($cores | ForEach-Object { $_.logicalProcessors } | Sort-Object -Unique)
    $diesSupported = ($diesRaw.Count -gt 0)
    $dies = New-Object System.Collections.Generic.List[object]
    if ($diesSupported) {
        foreach ($d in $diesRaw) {
            $lps = @()
            if ($null -ne $d.logicalProcessors) { $lps = @($d.logicalProcessors | Sort-Object -Unique) }
            $dies.Add([pscustomobject]@{
                dieIndex          = [int]$d.dieIndex
                label             = ("CCD $($d.dieIndex)")
                logicalProcessors = $lps
                l3Bytes           = [long]0
                synthetic         = $false
            })
        }
    } else {
        $dies.Add([pscustomobject]@{
            dieIndex          = 0
            label             = 'Die grouping unavailable'
            logicalProcessors = $allLps
            l3Bytes           = [long]0
            synthetic         = $true
        })
        $notes.Add('The processor-die relationship (RelationProcessorDie) returned no usable entries. Die/CCD grouping and per-die L3 attribution are unavailable; no die label is invented.')
    }

    $l3Caches = @($cachesRaw | Where-Object { [int]$_.level -eq 3 })
    $l3Attributed = $false
    foreach ($cache in $l3Caches) {
        $best = -1
        $bestOverlap = 0
        for ($i = 0; $i -lt $dies.Count; $i++) {
            $overlap = 0
            if ($null -ne $cache.logicalProcessors) {
                foreach ($lp in @($cache.logicalProcessors)) {
                    if (@($dies[$i].logicalProcessors) -contains [int]$lp) { $overlap++ }
                }
            }
            if ($overlap -gt $bestOverlap) { $bestOverlap = $overlap; $best = $i }
        }
        if ($best -ge 0) {
            $dies[$best].l3Bytes = [long]$dies[$best].l3Bytes + [long]$cache.cacheSize
            $l3Attributed = $true
        }
    }
    if ($l3Caches.Count -eq 0) {
        $notes.Add('No level-3 cache entries were reported; per-die L3 asymmetry cannot be evaluated.')
    } elseif (-not $l3Attributed) {
        $notes.Add('Level-3 cache entries could not be attributed to any die; X3D asymmetry remains undetermined.')
    }

    $x3d = Test-NxX3dAsymmetry -PerDieL3Bytes @($dies | ForEach-Object { [long]$_.l3Bytes }) -DiesSupported $diesSupported
    if ($x3d.indicated) {
        $notes.Add('X3D indication is best-effort (per-die L3 asymmetry >2x); it is never derived from a CPU marketing name. Verify the report on the owner hardware before relying on placement guidance.')
    }

    # ---- CPU set map ------------------------------------------------------
    $cpuSetLookup = @{}
    $cpuSetMapping = New-Object System.Collections.Generic.List[object]
    foreach ($s in $setsRaw) {
        $global = [int]$s.globalLogicalProcessor
        if (-not $cpuSetLookup.ContainsKey($global)) { $cpuSetLookup[$global] = $s }
        $cpuSetMapping.Add($s)
    }
    $missingSetLps = @()
    foreach ($lp in $allLps) {
        if (-not $cpuSetLookup.ContainsKey([int]$lp)) { $missingSetLps += [int]$lp }
    }
    $cpuSetMapAvailable = ($setsRaw.Count -gt 0)
    if (-not $cpuSetMapAvailable) {
        $notes.Add('GetSystemCpuSetInformation returned no usable entries; CPU Set IDs are unavailable and no ID is fabricated. CPU-set application must be refused, while affinity (single-group) remains a separate opt-in mechanism.')
    } elseif ($missingSetLps.Count -gt 0) {
        $notes.Add(("CPU Set map is missing logical processors {0}; selections containing them cannot be resolved." -f (($missingSetLps | Sort-Object) -join ',')))
    }

    # ---- group sanity -----------------------------------------------------
    if ($GroupCount -lt 1) { $GroupCount = 1 }
    $groupTotal = 0
    foreach ($n in @($GroupProcessorCounts)) { $groupTotal += [int]$n }
    if ($groupTotal -gt 0 -and $allLps.Count -gt 0 -and $groupTotal -ne $allLps.Count) {
        $notes.Add("Active processor counts from the OS ($groupTotal) differ from the parsed logical-processor count ($($allLps.Count)); results are reported with that discrepancy.")
    }

    $fingerprint = "lps=$($allLps.Count);cores=$($cores.Count);classes=$($classes -join '.');dies=$($dies.Count);l3=$((@($dies | ForEach-Object { $_.l3Bytes })) -join '.')"

    return [pscustomobject]@{
        readOnly                  = $true
        coreCount                 = $cores.Count
        logicalProcessorCount     = $allLps.Count
        allLogicalProcessors      = $allLps
        smtEnabled                = (@($cores | Where-Object { $_.hasSmt }).Count -gt 0)
        isHybrid                  = $isHybrid
        tierCount                 = $classes.Count
        efficiencyClasses         = $classes
        rankingSource             = $rankingSource
        rankingCertainty          = $rankingCertainty
        classPools                = $classPools
        cores                     = $cores.ToArray()
        diesSupported             = $diesSupported
        dies                      = $dies.ToArray()
        l3CacheEntryCount         = $l3Caches.Count
        x3d                       = $x3d
        cpuSetMapAvailable        = $cpuSetMapAvailable
        cpuSetLookup              = $cpuSetLookup
        cpuSetMapping             = $cpuSetMapping.ToArray()
        missingCpuSetLogicalProcessors = $missingSetLps
        groupCount                = $GroupCount
        groupProcessorCounts      = @($GroupProcessorCounts)
        fingerprint               = $fingerprint
        uncertainty               = $notes.ToArray()
    }
}

# ---------------------------------------------------------------------------
# 3. Live read-only topology probe (NX19-001)
# ---------------------------------------------------------------------------

function Get-NxTopologyReport {
    <#
    .SYNOPSIS
        NX19-001: derived CPU topology report. Read-only; no host mutation.
    .DESCRIPTION
        Calls the documented APIs, parses their buffers with the pure parsers
        above and returns a report with explicit uncertainty. Any interop failure
        yields topologyAvailable=false and never a guessed topology. No process
        affinity or CPU set is changed here; no registry value is touched.
    #>
    [CmdletBinding()]
    param()
    $uncertainty = New-Object System.Collections.Generic.List[string]
    $state = Initialize-Nx19Native
    $apiStatus = [pscustomobject]@{
        nativeAvailable  = [bool]$state.available
        nativeReason     = [string]$state.reason
        coreRelation     = 'NotCalled'
        cacheRelation    = 'NotCalled'
        dieRelation      = 'NotCalled'
        cpuSetInformation = 'NotCalled'
        groupCountCall   = 'NotCalled'
    }
    if (-not $state.available) {
        $uncertainty.Add([string]$state.reason)
        return [pscustomobject]@{
            tweakId            = 'NX19-001'
            readOnly           = $true
            noWritesPerformed  = $true
            generatedUtc       = (Get-Date).ToUniversalTime().ToString('o')
            topologyAvailable  = $false
            apiStatus          = $apiStatus
            logicalProcessorCount = $null
            physicalCoreCount  = $null
            smtEnabled         = $null
            isHybrid           = $null
            tierCount          = $null
            efficiencyClasses  = @()
            rankingSource      = 'Unavailable'
            rankingCertainty   = 'Unavailable'
            classPools         = [ordered]@{}
            cores              = @()
            diesSupported      = $null
            dies               = @()
            x3d                = [pscustomobject]@{ indicated = $false; confidence = 'NotDeterminable'; evidence = 'per-die-L3-asymmetry'; largeDieIndexes = @(); reason = 'Interop unavailable.' }
            cpuSetMap          = [pscustomobject]@{ available = $false; entryCount = 0; mapping = @(); missingLogicalProcessors = @() }
            groupCount         = $null
            groupProcessorCounts = @()
            fingerprint        = $null
            uncertainty        = $uncertainty.ToArray()
            topologyModel      = $null
        }
    }

    $coreBuffer = $null
    $cacheBuffer = $null
    $dieBuffer = $null
    $setBuffer = $null
    $coreError = 0
    try { $coreBuffer = [Nx19Native]::ReadRelationshipBuffer(0, [ref]$coreError) } catch { $coreError = -1; $coreBuffer = $null }
    if ($null -eq $coreBuffer) { $apiStatus.coreRelation = "Failed (error $coreError)"; $uncertainty.Add("RelationProcessorCore buffer unavailable (Win32 error $coreError).") }
    else { $apiStatus.coreRelation = 'Ok' }

    $cacheError = 0
    try { $cacheBuffer = [Nx19Native]::ReadRelationshipBuffer(2, [ref]$cacheError) } catch { $cacheError = -1; $cacheBuffer = $null }
    if ($null -eq $cacheBuffer) { $apiStatus.cacheRelation = "Failed (error $cacheError)"; $uncertainty.Add("RelationCache buffer unavailable (Win32 error $cacheError).") }
    else { $apiStatus.cacheRelation = 'Ok' }

    $dieError = 0
    try { $dieBuffer = [Nx19Native]::ReadRelationshipBuffer(5, [ref]$dieError) } catch { $dieError = -1; $dieBuffer = $null }
    if ($null -eq $dieBuffer) {
        $apiStatus.dieRelation = "Unsupported (error $dieError)"
        $uncertainty.Add("RelationProcessorDie is not available on this system (Win32 error $dieError); die/CCD grouping is reported as unavailable.")
    } else { $apiStatus.dieRelation = 'Ok' }

    $setError = 0
    try { $setBuffer = [Nx19Native]::ReadCpuSetBuffer([ref]$setError) } catch { $setError = -1; $setBuffer = $null }
    if ($null -eq $setBuffer) { $apiStatus.cpuSetInformation = "Failed (error $setError)"; $uncertainty.Add("GetSystemCpuSetInformation buffer unavailable (Win32 error $setError).") }
    else { $apiStatus.cpuSetInformation = 'Ok' }

    $groupCount = 0
    try { $groupCount = [int][Nx19Native]::GetGroupCount(); $apiStatus.groupCountCall = 'Ok' } catch { $apiStatus.groupCountCall = "Failed ($($_.Exception.Message))"; $uncertainty.Add('Processor-group count query failed.') }
    $groupCounts = New-Object System.Collections.Generic.List[int]
    if ($groupCount -gt 0) {
        for ($g = 0; $g -lt $groupCount; $g++) {
            try { $groupCounts.Add([int][Nx19Native]::GetGroupProcessorCount([uint16]$g)) } catch { $groupCounts.Add(0) }
        }
    }

    $coreParseBuffer = [byte[]]@()
    if ($null -ne $coreBuffer) { $coreParseBuffer = $coreBuffer }
    $cacheParseBuffer = [byte[]]@()
    if ($null -ne $cacheBuffer) { $cacheParseBuffer = $cacheBuffer }
    $dieParseBuffer = [byte[]]@()
    if ($null -ne $dieBuffer) { $dieParseBuffer = $dieBuffer }
    $setParseBuffer = [byte[]]@()
    if ($null -ne $setBuffer) { $setParseBuffer = $setBuffer }
    $coreParse = ConvertFrom-NxLpCoreBuffer -Buffer $coreParseBuffer
    $cacheParse = ConvertFrom-NxLpCacheBuffer -Buffer $cacheParseBuffer
    $dieParse = ConvertFrom-NxLpDieBuffer -Buffer $dieParseBuffer
    $setParse = ConvertFrom-NxCpuSetBuffer -Buffer $setParseBuffer
    if ($coreParse.entryCount -eq 0) { $uncertainty.Add('RelationProcessorCore returned no usable entries; the topology is unavailable rather than guessed.') }
    if ($coreParse.truncated) { $uncertainty.Add('RelationProcessorCore buffer scan stopped early (short or malformed entry); topology is partial.') }
    if ($cacheParse.truncated) { $uncertainty.Add('RelationCache buffer scan stopped early (short or malformed entry); cache data is partial.') }
    if ($dieParse.truncated) { $uncertainty.Add('RelationProcessorDie buffer scan stopped early (short or malformed entry); die data is partial.') }
    if ($setParse.truncated) { $uncertainty.Add('CPU-set buffer scan stopped early (short or malformed entry); the LP-to-set map is partial.') }

    $model = New-NxTopologyModel -CoreEntries $coreParse.entries -CacheEntries $cacheParse.entries -DieEntries $dieParse.entries -CpuSetEntries $setParse.entries -GroupCount $groupCount -GroupProcessorCounts $groupCounts.ToArray() -Uncertainty $uncertainty.ToArray()
    if ($model.logicalProcessorCount -le 0) {
        return [pscustomobject]@{
            tweakId            = 'NX19-001'
            readOnly           = $true
            noWritesPerformed  = $true
            generatedUtc       = (Get-Date).ToUniversalTime().ToString('o')
            topologyAvailable  = $false
            apiStatus          = $apiStatus
            logicalProcessorCount = 0
            physicalCoreCount  = 0
            smtEnabled         = $null
            isHybrid           = $null
            tierCount          = 0
            efficiencyClasses  = @()
            rankingSource      = 'Unavailable'
            rankingCertainty   = 'Unavailable'
            classPools         = [ordered]@{}
            cores              = @()
            diesSupported      = $model.diesSupported
            dies               = $model.dies
            x3d                = $model.x3d
            cpuSetMap          = [pscustomobject]@{ available = $model.cpuSetMapAvailable; entryCount = @($model.cpuSetMapping).Count; mapping = @($model.cpuSetMapping); missingLogicalProcessors = @($model.missingCpuSetLogicalProcessors) }
            groupCount         = $model.groupCount
            groupProcessorCounts = @($model.groupProcessorCounts)
            fingerprint        = $model.fingerprint
            uncertainty        = @($model.uncertainty)
            topologyModel      = $null
        }
    }

    return [pscustomobject]@{
        tweakId            = 'NX19-001'
        readOnly           = $true
        noWritesPerformed  = $true
        generatedUtc       = (Get-Date).ToUniversalTime().ToString('o')
        topologyAvailable  = $true
        apiStatus          = $apiStatus
        logicalProcessorCount = $model.logicalProcessorCount
        physicalCoreCount  = $model.coreCount
        smtEnabled         = $model.smtEnabled
        isHybrid           = $model.isHybrid
        tierCount          = $model.tierCount
        efficiencyClasses  = @($model.efficiencyClasses)
        rankingSource      = $model.rankingSource
        rankingCertainty   = $model.rankingCertainty
        classPools         = $model.classPools
        cores              = @($model.cores)
        diesSupported      = $model.diesSupported
        dies               = @($model.dies)
        x3d                = $model.x3d
        cpuSetMap          = [pscustomobject]@{
            available             = $model.cpuSetMapAvailable
            entryCount            = @($model.cpuSetMapping).Count
            mapping               = @($model.cpuSetMapping)
            missingLogicalProcessors = @($model.missingCpuSetLogicalProcessors)
        }
        groupCount         = $model.groupCount
        groupProcessorCounts = @($model.groupProcessorCounts)
        fingerprint        = $model.fingerprint
        uncertainty        = @($model.uncertainty)
        topologyModel      = $model
    }
}

# ---------------------------------------------------------------------------
# 4. Derived pool selection + CPU Set / affinity conversion (pure)
# ---------------------------------------------------------------------------

function Get-NxModelFromTopologyInput {
    # Internal: accepts a model, a live report (unwraps topologyModel) or $null
    # (runs the read-only probe).
    [CmdletBinding()]
    param([object]$Topology)
    if ($null -eq $Topology) {
        $report = Get-NxTopologyReport
        if (-not $report.topologyAvailable) { return $null }
        return $report.topologyModel
    }
    if ($Topology.PSObject.Properties['topologyModel'] -and $null -ne $Topology.topologyModel) {
        return $Topology.topologyModel
    }
    if ($Topology.PSObject.Properties['classPools'] -and $Topology.PSObject.Properties['cores']) {
        if ([int]$Topology.logicalProcessorCount -le 0) { return $null }
        return $Topology
    }
    return $null
}

function Get-NxTopologyClassPool {
    # Internal: safe access to a role pool.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$Role
    )
    $pools = $Model.classPools
    if ($null -eq $pools) { return $null }
    if ($pools.Contains($Role)) { return $pools[$Role] }
    return $null
}

function Resolve-NxTopologyPool {
    <#
    .SYNOPSIS
        PURE pool derivation from the model. Returns LP sets with provenance.
    .DESCRIPTION
        Pools are derived from tiers, dies and SMT flags only:
          AllLogical            every derived LP
          PerformanceLogical    all LPs of the highest-performance tier
          PerformancePrimary    one (first enumerated) LP per performance core
          EfficiencyLogical     all LPs of lower-performance tiers (E + LP-E)
          EfficiencyPrimary     one LP per lower-tier core
          PerformanceDie        LPs of the die with the largest L3 (multi-die only)
          NonPerformanceDie     LPs of the die with the smallest L3 (multi-die only)
          CaptureReserve        NonPerformanceDie, else efficiency LPs, else a
                                core-count-derived slice of primary threads
        A pool that cannot be derived is empty and carries a note; it is never
        filled with a hardcoded index.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][ValidateSet('AllLogical','PerformanceLogical','PerformancePrimary','EfficiencyLogical','EfficiencyPrimary','PerformanceDie','NonPerformanceDie','CaptureReserve')][string]$Pool
    )
    $p = Get-NxTopologyClassPool -Model $Model -Role 'P'
    if ($null -eq $p) { $p = Get-NxTopologyClassPool -Model $Model -Role 'Standard' }
    $eRoleLps = @()
    foreach ($role in @('E','LP-E')) {
        $rp = Get-NxTopologyClassPool -Model $Model -Role $role
        if ($null -ne $rp) { $eRoleLps += @($rp.logicalProcessors) }
    }
    $eRoleLps = @($eRoleLps | Sort-Object -Unique)
    $ePrimary = @()
    foreach ($role in @('E','LP-E')) {
        $rp = Get-NxTopologyClassPool -Model $Model -Role $role
        if ($null -ne $rp) { $ePrimary += @($rp.primaryLogicalProcessors) }
    }
    $ePrimary = @($ePrimary | Sort-Object -Unique)

    switch ($Pool) {
        'AllLogical' {
            return [pscustomobject]@{ pool = $Pool; logicalProcessors = @($Model.allLogicalProcessors); derivedFrom = 'every derived logical processor'; note = $null }
        }
        'PerformanceLogical' {
            if ($null -ne $p) {
                return [pscustomobject]@{ pool = $Pool; logicalProcessors = @($p.logicalProcessors); derivedFrom = "all logical processors of tier role $($p.role)"; note = $null }
            }
            return [pscustomobject]@{ pool = $Pool; logicalProcessors = @($Model.allLogicalProcessors); derivedFrom = 'fallback: no tier pool, all logical processors'; note = 'No performance tier could be derived; the pool falls back to every logical processor.' }
        }
        'PerformancePrimary' {
            if ($null -ne $p) {
                return [pscustomobject]@{ pool = $Pool; logicalProcessors = @($p.primaryLogicalProcessors); derivedFrom = "first logical processor of each $($p.role) core (SMT siblings excluded)"; note = $null }
            }
            return [pscustomobject]@{ pool = $Pool; logicalProcessors = @($Model.allLogicalProcessors); derivedFrom = 'fallback: all logical processors'; note = 'No performance tier could be derived; the pool falls back to every logical processor.' }
        }
        'EfficiencyLogical' {
            if ($eRoleLps.Count -gt 0) {
                return [pscustomobject]@{ pool = $Pool; logicalProcessors = $eRoleLps; derivedFrom = 'all logical processors of tiers E and LP-E'; note = $null }
            }
            return [pscustomobject]@{ pool = $Pool; logicalProcessors = @(); derivedFrom = 'no lower-performance tier exists'; note = 'This topology has no lower-performance tier; no efficiency pool exists (background apps are not pinned by this plan).' }
        }
        'EfficiencyPrimary' {
            if ($ePrimary.Count -gt 0) {
                return [pscustomobject]@{ pool = $Pool; logicalProcessors = $ePrimary; derivedFrom = 'first logical processor of each E/LP-E core'; note = $null }
            }
            return [pscustomobject]@{ pool = $Pool; logicalProcessors = @(); derivedFrom = 'no lower-performance tier exists'; note = 'This topology has no lower-performance tier.' }
        }
        'PerformanceDie' {
            $dies = @($Model.dies)
            if ($dies.Count -lt 2) {
                return [pscustomobject]@{ pool = $Pool; logicalProcessors = @(); derivedFrom = 'single-die or undetected die grouping'; note = 'Die-specific placement needs at least two detected dies.' }
            }
            $best = $dies[0]
            foreach ($d in $dies) { if ([long]$d.l3Bytes -gt [long]$best.l3Bytes) { $best = $d } }
            return [pscustomobject]@{ pool = $Pool; logicalProcessors = @($best.logicalProcessors); derivedFrom = "die with the largest level-3 cache ($($best.label))"; note = $null }
        }
        'NonPerformanceDie' {
            $dies = @($Model.dies)
            if ($dies.Count -lt 2) {
                return [pscustomobject]@{ pool = $Pool; logicalProcessors = @(); derivedFrom = 'single-die or undetected die grouping'; note = 'Die-specific placement needs at least two detected dies.' }
            }
            $worst = $dies[0]
            foreach ($d in $dies) { if ([long]$d.l3Bytes -lt [long]$worst.l3Bytes) { $worst = $d } }
            return [pscustomobject]@{ pool = $Pool; logicalProcessors = @($worst.logicalProcessors); derivedFrom = "die with the smallest level-3 cache ($($worst.label))"; note = $null }
        }
        'CaptureReserve' {
            $dies = @($Model.dies)
            if ($dies.Count -ge 2) {
                $worst = $dies[0]
                foreach ($d in $dies) { if ([long]$d.l3Bytes -lt [long]$worst.l3Bytes) { $worst = $d } }
                return [pscustomobject]@{ pool = $Pool; logicalProcessors = @($worst.logicalProcessors); derivedFrom = "capture/encode reserved to the smaller-L3 die ($($worst.label))"; note = $null }
            }
            if ($eRoleLps.Count -gt 0) {
                return [pscustomobject]@{ pool = $Pool; logicalProcessors = $eRoleLps; derivedFrom = 'capture/encode reserved to the lower-performance tiers'; note = $null }
            }
            $primary = @($Model.cores | ForEach-Object { $_.primaryLogicalProcessor } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
            if ($primary.Count -gt 0) {
                $reserveCount = [int][Math]::Floor($primary.Count / 8)
                if ($reserveCount -lt 1) { $reserveCount = 1 }
                if ($reserveCount -gt $primary.Count) { $reserveCount = $primary.Count }
                $tail = @($primary | Select-Object -Last $reserveCount)
                return [pscustomobject]@{ pool = $Pool; logicalProcessors = @($tail); derivedFrom = ("core-count-derived reserve: {0} of {1} physical cores (highest indexes)" -f $reserveCount, $primary.Count); note = 'No die or efficiency tier was usable; the capture reserve is derived from the physical core count (1/8, minimum 1).' }
            }
            return [pscustomobject]@{ pool = $Pool; logicalProcessors = @(); derivedFrom = 'no derivable reserve'; note = 'No capture reserve could be derived; capture is not pinned.' }
        }
    }
    return [pscustomobject]@{ pool = $Pool; logicalProcessors = @(); derivedFrom = 'unresolved'; note = "Unknown pool '$Pool'." }
}

function ConvertTo-NxCpuSetIds {
    <#
    .SYNOPSIS
        PURE: map global logical indexes to CPU Set IDs from the OS map.
    .DESCRIPTION
        Never fabricates an ID. If the map is unavailable or a selected LP is not
        present, the result is resolved=false with the unresolved indexes listed.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][int[]]$GlobalIndexes = @(),
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CpuSetEntries = @()
    )
    $lookup = @{}
    foreach ($s in @($CpuSetEntries)) { $lookup[[int]$s.globalLogicalProcessor] = [uint32]$s.cpuSetId }
    $ids = New-Object System.Collections.Generic.List[uint32]
    $unresolved = New-Object System.Collections.Generic.List[int]
    foreach ($lp in @($GlobalIndexes | Sort-Object -Unique)) {
        if ($lookup.ContainsKey([int]$lp)) { $ids.Add([uint32]$lookup[[int]$lp]) }
        else { $unresolved.Add([int]$lp) }
    }
    return [pscustomobject]@{
        mapAvailable  = ($lookup.Count -gt 0)
        resolved      = ($unresolved.Count -eq 0)
        cpuSetIds     = $ids.ToArray()
        unresolvedLogicalProcessors = $unresolved.ToArray()
        selectedLogicalProcessors   = @($GlobalIndexes | Sort-Object -Unique)
    }
}

function ConvertTo-NxAffinityMask {
    <#
    .SYNOPSIS
        PURE: build a single-group affinity mask from global logical indexes.
    .DESCRIPTION
        SetProcessAffinityMask is documented to accept a mask for processors in a
        single processor group on systems with more than 64 processors. This
        function refuses (supported=false) any selection spanning groups, and
        returns the group-relative mask otherwise. No index is assumed.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][int[]]$GlobalIndexes = @()
    )
    $indexes = @($GlobalIndexes | Sort-Object -Unique)
    if ($indexes.Count -eq 0) {
        return [pscustomobject]@{ supported = $false; group = $null; mask = [uint64]0; reason = 'No logical processors selected.'; globalIndexes = @() }
    }
    $groups = @()
    foreach ($lp in $indexes) {
        if ($lp -lt 0) {
            return [pscustomobject]@{ supported = $false; group = $null; mask = [uint64]0; reason = "Invalid logical index $lp."; globalIndexes = $indexes }
        }
        $g = [int][Math]::Floor($lp / 64)
        if ($groups -notcontains $g) { $groups += $g }
    }
    if ($groups.Count -ne 1) {
        return [pscustomobject]@{ supported = $false; group = $null; mask = [uint64]0; reason = ("Selection spans processor groups {0}; SetProcessAffinityMask accepts one group only (documented). Use CPU Sets instead." -f ($groups -join ',')); globalIndexes = $indexes }
    }
    $group = [int]$groups[0]
    $inGroup = @()
    foreach ($lp in $indexes) { $inGroup += [int]($lp - ($group * 64)) }
    $mask = [uint64]0
    for ($bit = 0; $bit -lt 64; $bit++) {
        if ($inGroup -contains $bit) {
            $value = [uint64]1
            for ($shift = 0; $shift -lt $bit; $shift++) { $value = [uint64]($value -shl 1) }
            $mask = [uint64]($mask -bor $value)
        }
    }
    return [pscustomobject]@{
        supported     = $true
        group         = $group
        mask          = $mask
        reason        = "Single-group selection: group $group, $($indexes.Count) logical processor(s)."
        globalIndexes = $indexes
    }
}

# ---------------------------------------------------------------------------
# 5. Scheduling profiles as data (NX19-006..010)
# ---------------------------------------------------------------------------

function Get-NxSchedulingProfileDefinition {
    <#
    .SYNOPSIS
        NX19-006..010: scheduling profile definitions as data.
    .DESCRIPTION
        A profile is a parameter set for the derivation engine (002) and the
        application entries (003/004/005): pool names, class ids (Game=1,
        Capture=2, Background=3, per the reference rule schema convention, r3),
        and optional priority intents. Definitions contain no logical-processor
        index and no CPU name. Priority intents never include High or RealTime.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Competitive','Balanced','Streaming','Productivity','Custom')][string]$Name
    )
    $mechanismNote = 'CPU Sets are the default mechanism. Affinity is a separate opt-in mechanism and is never applied by a profile.'
    switch ($Name) {
        'Competitive' {
            return [pscustomobject]@{
                id = 'NX19-006'; name = 'Competitive'; defined = $true; implementedAsData = $true
                tweakId = 'NX19-006'
                description = 'Performance-first placement: the game receives the first logical processor of each performance core; background work is steered to lower-performance tiers when they exist.'
                gameClass = 1; captureClass = 2; backgroundClass = 3
                gamePool = 'PerformancePrimary'; backgroundPool = 'EfficiencyLogical'; capturePool = $null
                priority = [pscustomobject]@{ game = 'AboveNormal'; background = 'BelowNormal'; capture = $null }
                affinityFallback = $false
                minimumGameLogicalProcessors = 4
                mechanismNote = $mechanismNote
                tradeOffs = @(
                    'Excludes SMT siblings from the game selection when at least four performance logical processors are available; a topology with fewer falls back to all performance LPs.',
                    'On a topology with no lower-performance tier, background apps are not pinned (no pool exists) rather than being forced onto game cores.',
                    'Competitive placement can reduce the logical processors available to streaming/encoding; the Streaming profile reserves capture capacity instead.'
                )
                antiCheatNote = $script:Nx19AntiCheatNote
            }
        }
        'Balanced' {
            return [pscustomobject]@{
                id = 'NX19-007'; name = 'Balanced'; defined = $true; implementedAsData = $true
                tweakId = 'NX19-007'
                description = 'Preserves background responsiveness: the game uses all performance-tier logical processors and background work is left under normal OS scheduling.'
                gameClass = 1; captureClass = 2; backgroundClass = 3
                gamePool = 'PerformanceLogical'; backgroundPool = $null; capturePool = $null
                priority = [pscustomobject]@{ game = $null; background = $null; capture = $null }
                affinityFallback = $false
                minimumGameLogicalProcessors = 1
                mechanismNote = $mechanismNote
                tradeOffs = @(
                    'No background set is applied: background apps keep OS-selected placement, which is the profile intent.',
                    'On a topology with a single efficiency tier, the game pool is every logical processor and the plan is non-restrictive.'
                )
                antiCheatNote = $script:Nx19AntiCheatNote
            }
        }
        'Streaming' {
            return [pscustomobject]@{
                id = 'NX19-008'; name = 'Streaming'; defined = $true; implementedAsData = $true
                tweakId = 'NX19-008'
                description = 'Reserves encode/capture capacity away from the game: game on performance cores, capture/encoder processes on the smaller-L3 die or lower-performance tiers.'
                gameClass = 1; captureClass = 2; backgroundClass = 3
                gamePool = 'PerformancePrimary'; backgroundPool = 'EfficiencyLogical'; capturePool = 'CaptureReserve'
                priority = [pscustomobject]@{ game = 'AboveNormal'; background = 'BelowNormal'; capture = 'Normal' }
                affinityFallback = $false
                minimumGameLogicalProcessors = 4
                obsAware = $true
                obsGuidance = 'Apply the Capture class to the encoder/capture processes (for example the OBS process image) and the Game class to the game. Do not apply the Game selection to OBS: encode/capture work must keep the reserved pool.'
                mechanismNote = $mechanismNote
                tradeOffs = @(
                    'Reserving cores for capture reduces the processors available to the game when the topology is small.',
                    'On a single-die topology with no lower-performance tier, the reserve is derived from the physical core count (1/8, minimum 1) and is reported as such.',
                    'The Capture class is a CPU-set selection only; it does not change encoder settings or priority unless the owner selects NX19-005 separately.'
                )
                antiCheatNote = $script:Nx19AntiCheatNote
            }
        }
        'Productivity' {
            return [pscustomobject]@{
                id = 'NX19-009'; name = 'Productivity'; defined = $true; implementedAsData = $true
                tweakId = 'NX19-009'
                description = 'Multitask-friendly: no restrictive CPU-set selection is derived; all logical processors remain available to all workloads.'
                gameClass = 1; captureClass = 2; backgroundClass = 3
                gamePool = $null; backgroundPool = $null; capturePool = $null
                priority = [pscustomobject]@{ game = $null; background = $null; capture = $null }
                affinityFallback = $false
                minimumGameLogicalProcessors = 0
                mechanismNote = $mechanismNote
                tradeOffs = @(
                    'This profile intentionally derives no restriction; it exists so the profile set covers a no-pinning choice without switching to a third-party tool.',
                    'No CPU Set or affinity is applied by this profile.'
                )
                antiCheatNote = $script:Nx19AntiCheatNote
            }
        }
        'Custom' {
            return [pscustomobject]@{
                id = 'NX19-010'; name = 'Custom'; defined = $true; implementedAsData = $true
                tweakId = 'NX19-010'
                description = 'User-defined per-process rules validated against the detected topology before any plan is produced.'
                gameClass = 1; captureClass = 2; backgroundClass = 3
                gamePool = $null; backgroundPool = $null; capturePool = $null
                priority = [pscustomobject]@{ game = $null; background = $null; capture = $null }
                affinityFallback = $false
                minimumGameLogicalProcessors = 0
                userDefined = $true
                maxRules = 64
                mechanismNote = $mechanismNote
                tradeOffs = @(
                    'Every custom logical-processor index must exist in the detected topology; unknown indexes are rejected, never clamped.',
                    'At least one Game-class rule is required so a custom plan has a scheduling intent.',
                    'Duplicate process names are rejected so a process has exactly one rule.'
                )
                antiCheatNote = $script:Nx19AntiCheatNote
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 6. CPU Set plan derivation (NX19-002) and profile plans (006..010)
# ---------------------------------------------------------------------------

function New-NxCpuSetRule {
    # Internal pure helper: one class rule from a pool.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$Class,
        [Parameter(Mandatory)][int]$ClassId,
        [Parameter(Mandatory)][string]$Pool,
        [string]$ProcessName = $null
    )
    $poolResult = Resolve-NxTopologyPool -Model $Model -Pool $Pool
    $lps = @($poolResult.logicalProcessors | Sort-Object -Unique)
    $ids = ConvertTo-NxCpuSetIds -GlobalIndexes $lps -CpuSetEntries @($Model.cpuSetMapping)
    $affinity = ConvertTo-NxAffinityMask -GlobalIndexes $lps
    $notes = @()
    if ($poolResult.note) { $notes += [string]$poolResult.note }
    if (-not $ids.resolved) {
        $notes += ("CPU Set IDs could not be resolved for logical processors {0}; application must be refused for this rule." -f (($ids.unresolvedLogicalProcessors) -join ','))
    }
    return [pscustomobject]@{
        processName                  = $ProcessName
        class                        = $Class
        classId                      = $ClassId
        pool                         = $Pool
        poolDerivedFrom              = $poolResult.derivedFrom
        logicalProcessors            = $lps
        logicalProcessorCount        = $lps.Count
        mechanism                    = 'CpuSet'
        cpuSetIds                    = @($ids.cpuSetIds)
        cpuSetIdsResolved            = [bool]$ids.resolved
        unresolvedLogicalProcessors  = @($ids.unresolvedLogicalProcessors)
        affinity                     = $affinity
        notes                        = $notes
    }
}

function New-NxCpuSetRuleFromSelection {
    # Internal pure helper: one class rule from an explicit LP selection. Used
    # where a pool is not the right abstraction (polarity-independent fallback).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$Class,
        [Parameter(Mandatory)][int]$ClassId,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$LogicalProcessors,
        [Parameter(Mandatory)][string]$PoolLabel,
        [Parameter(Mandatory)][string]$DerivedFrom,
        [string]$ProcessName = $null
    )
    $lps = @($LogicalProcessors | Sort-Object -Unique)
    $ids = ConvertTo-NxCpuSetIds -GlobalIndexes $lps -CpuSetEntries @($Model.cpuSetMapping)
    $notes = @()
    if (-not $ids.resolved) {
        $notes += ("CPU Set IDs could not be resolved for logical processors {0}; application must be refused for this rule." -f (($ids.unresolvedLogicalProcessors) -join ','))
    }
    return [pscustomobject]@{
        processName                  = $ProcessName
        class                        = $Class
        classId                      = $ClassId
        pool                         = $PoolLabel
        poolDerivedFrom              = $DerivedFrom
        logicalProcessors            = $lps
        logicalProcessorCount        = $lps.Count
        mechanism                    = 'CpuSet'
        cpuSetIds                    = @($ids.cpuSetIds)
        cpuSetIdsResolved            = [bool]$ids.resolved
        unresolvedLogicalProcessors  = @($ids.unresolvedLogicalProcessors)
        affinity                     = (ConvertTo-NxAffinityMask -GlobalIndexes $lps)
        notes                        = $notes
    }
}

function New-NxCpuSetPlan {
    <#
    .SYNOPSIS
        NX19-002: pure CPU Set derivation from topology + profile.
    .DESCRIPTION
        Derives per-class CPU-set selections from the topology model. The model
        may be passed directly (synthetic tests) or omitted to run the read-only
        live probe. No process is touched and no registry value is written.

        Conservative polarity rule: when the topology has multiple efficiency
        tiers but the OS supplied no RelativePerformance data, the performance
        ranking is only documented-direction (flagged uncertain). In that case
        the plan does NOT pin P/E differently: it uses one LP per physical core
        across all cores for the game class and omits the background split. This
        prevents a wrong P/E assumption from steering a game onto E cores.
    #>
    [CmdletBinding()]
    param(
        [object]$Topology = $null,
        [ValidateSet('Competitive','Balanced','Streaming','Productivity','Custom')][string]$Profile = 'Balanced'
    )
    $model = Get-NxModelFromTopologyInput -Topology $Topology
    $definition = Get-NxSchedulingProfileDefinition -Name $Profile
    if ($null -eq $model) {
        return [pscustomobject]@{
            tweakId = 'NX19-002'; profile = $Profile; readOnly = $true; noWritesPerformed = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            topologyAvailable = $false; restrictive = $false; rules = @(); definition = $definition
            mechanismDefault = 'CpuSet'; affinityOptIn = $false; sessionScoped = $true
            certainty = 'Unavailable'; uncertainty = @('Topology unavailable: no plan derived.')
            fingerprint = $null; antiCheatNote = $script:Nx19AntiCheatNote
        }
    }
    if ($Profile -eq 'Custom') {
        return New-NxCustomSchedulingPlan -Topology $model -Rules @()
    }

    $uncertainty = New-Object System.Collections.Generic.List[string]
    foreach ($u in @($model.uncertainty)) { $uncertainty.Add([string]$u) }
    $rules = New-Object System.Collections.Generic.List[object]
    $polarityCertain = (-not $model.isHybrid) -or ($model.rankingCertainty -eq 'DerivedFromRelativePerformance')

    if ($Profile -eq 'Productivity') {
        $uncertainty.Add('Productivity profile intentionally derives no restriction; no CPU Set or affinity rule is produced.')
        return [pscustomobject]@{
            tweakId = 'NX19-002'; profile = $Profile; readOnly = $true; noWritesPerformed = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            topologyAvailable = $true; restrictive = $false; rules = @(); definition = $definition
            mechanismDefault = 'CpuSet'; affinityOptIn = $false; sessionScoped = $true
            certainty = 'Derived'; uncertainty = $uncertainty.ToArray()
            fingerprint = $model.fingerprint; antiCheatNote = $script:Nx19AntiCheatNote
        }
    }

    $totalLps = [int]$model.logicalProcessorCount

    if ($Profile -eq 'Competitive') {
        if ($polarityCertain) {
            $gamePool = 'PerformancePrimary'
            $game = Resolve-NxTopologyPool -Model $model -Pool $gamePool
            $gameLps = @($game.logicalProcessors)
            $min = [int]$definition.minimumGameLogicalProcessors
            if ($gameLps.Count -lt $min) {
                $game = Resolve-NxTopologyPool -Model $model -Pool 'PerformanceLogical'
                $gameLps = @($game.logicalProcessors)
                $gamePool = 'PerformanceLogical'
                $uncertainty.Add(("Performance-primary selection has fewer than {0} logical processors; the game pool widened to all performance-tier LPs." -f $min))
            }
            if ($gameLps.Count -lt $min) {
                $game = Resolve-NxTopologyPool -Model $model -Pool 'AllLogical'
                $gameLps = @($game.logicalProcessors)
                $gamePool = 'AllLogical'
                $uncertainty.Add(("Even the performance tier has fewer than {0} logical processors; the game pool widened to every logical processor rather than leaving most of the CPU idle." -f $min))
            }
            $rules.Add((New-NxCpuSetRule -Model $model -Class 'Game' -ClassId 1 -Pool $gamePool -ProcessName $null))
            $bg = Resolve-NxTopologyPool -Model $model -Pool 'EfficiencyLogical'
            if (@($bg.logicalProcessors).Count -gt 0) {
                $rules.Add((New-NxCpuSetRule -Model $model -Class 'Background' -ClassId 3 -Pool 'EfficiencyLogical' -ProcessName $null))
            } else {
                $uncertainty.Add('No lower-performance tier exists; no Background rule is produced and background apps are left unpinned.')
            }
        } else {
            $primary = @($model.cores | ForEach-Object { $_.primaryLogicalProcessor } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
            $selection = $primary
            $poolLabel = 'AllPrimaryThreads'
            $derivedFrom = 'first logical processor of every physical core (polarity-independent)'
            if ($primary.Count -lt [int]$definition.minimumGameLogicalProcessors) {
                $selection = @($model.allLogicalProcessors)
                $poolLabel = 'AllLogical'
                $derivedFrom = 'every logical processor (polarity-independent fallback)'
            }
            $rules.Add((New-NxCpuSetRuleFromSelection -Model $model -Class 'Game' -ClassId 1 -LogicalProcessors $selection -PoolLabel $poolLabel -DerivedFrom $derivedFrom -ProcessName $null))
            $uncertainty.Add('Performance/efficiency tier polarity is not OS-derived on this topology; the Competitive plan therefore avoids P/E-specific pinning and uses physical-core first threads (or all LPs) instead. Background apps are not split.')
        }
    }
    elseif ($Profile -eq 'Balanced') {
        if ($polarityCertain) {
            $rules.Add((New-NxCpuSetRule -Model $model -Class 'Game' -ClassId 1 -Pool 'PerformanceLogical' -ProcessName $null))
            $game = Resolve-NxTopologyPool -Model $model -Pool 'PerformanceLogical'
            if (@($game.logicalProcessors).Count -ge $totalLps) {
                $uncertainty.Add('The performance tier is every logical processor on this topology; the Balanced plan is non-restrictive.')
            }
        } else {
            $uncertainty.Add('Performance/efficiency tier polarity is not OS-derived; the Balanced plan applies no P/E-specific restriction (background responsiveness preserved).')
        }
        # Balanced intentionally leaves background unpinned.
    }
    elseif ($Profile -eq 'Streaming') {
        $gameLps = @()
        $gamePoolName = 'PerformancePrimary'
        if ($polarityCertain) {
            $game = Resolve-NxTopologyPool -Model $model -Pool 'PerformancePrimary'
            $gameLps = @($game.logicalProcessors)
            $min = [int]$definition.minimumGameLogicalProcessors
            if ($gameLps.Count -lt $min) {
                $game = Resolve-NxTopologyPool -Model $model -Pool 'PerformanceLogical'
                $gameLps = @($game.logicalProcessors)
                $gamePoolName = 'PerformanceLogical'
                $uncertainty.Add(("Performance-primary selection has fewer than {0} logical processors; the game pool widened to all performance-tier LPs." -f $min))
            }
            $rules.Add((New-NxCpuSetRule -Model $model -Class 'Game' -ClassId 1 -Pool $gamePoolName -ProcessName $null))
        } else {
            $primary = @($model.cores | ForEach-Object { $_.primaryLogicalProcessor } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
            $selection = $primary
            if ($selection.Count -lt 1) { $selection = @($model.allLogicalProcessors) }
            $rules.Add((New-NxCpuSetRuleFromSelection -Model $model -Class 'Game' -ClassId 1 -LogicalProcessors $selection -PoolLabel 'AllPrimaryThreads' -DerivedFrom 'first logical processor of every physical core (polarity-independent)' -ProcessName $null))
            $uncertainty.Add('Performance/efficiency tier polarity is not OS-derived; Streaming uses physical-core first threads for the game and a core-count-derived capture reserve.')
        }
        $capture = Resolve-NxTopologyPool -Model $model -Pool 'CaptureReserve'
        $captureLps = @($capture.logicalProcessors)
        if (@($captureLps).Count -gt 0) {
            $rules.Add((New-NxCpuSetRule -Model $model -Class 'Capture' -ClassId 2 -Pool 'CaptureReserve' -ProcessName $null))
            $uncertainty.Add(("Capture/encode reserve derived from: {0}" -f $capture.derivedFrom))
        } else {
            $uncertainty.Add('No capture reserve could be derived; the Streaming plan does not pin capture processes.')
        }
        $bg = Resolve-NxTopologyPool -Model $model -Pool 'EfficiencyLogical'
        $bgLps = @($bg.logicalProcessors | Where-Object { $captureLps -notcontains [int]$_ } | Sort-Object -Unique)
        if ($bgLps.Count -gt 0) {
            $rules.Add((New-NxCpuSetRuleFromSelection -Model $model -Class 'Background' -ClassId 3 -LogicalProcessors $bgLps -PoolLabel 'EfficiencyLogicalMinusCapture' -DerivedFrom 'lower-performance tiers excluding the capture reserve' -ProcessName $null))
        }
    }

    $restrictive = $false
    foreach ($r in $rules) {
        if (@($r.logicalProcessors).Count -gt 0 -and @($r.logicalProcessors).Count -lt $totalLps) { $restrictive = $true }
    }
    if (-not $restrictive) { $uncertainty.Add('The derived plan does not restrict any logical processor on this topology.') }

    return [pscustomobject]@{
        tweakId          = 'NX19-002'
        profile          = $Profile
        readOnly         = $true
        noWritesPerformed = $true
        generatedUtc     = (Get-Date).ToUniversalTime().ToString('o')
        topologyAvailable = $true
        restrictive      = $restrictive
        rules            = $rules.ToArray()
        definition       = $definition
        mechanismDefault = 'CpuSet'
        affinityOptIn    = $false
        sessionScoped    = $true
        certainty        = $(if ($uncertainty.Count -eq 0) { 'Derived' } else { 'DerivedWithUncertainty' })
        uncertainty      = $uncertainty.ToArray()
        fingerprint      = $model.fingerprint
        antiCheatNote    = $script:Nx19AntiCheatNote
    }
}

function New-NxSchedulingPlan {
    <#
    .SYNOPSIS
        NX19-006..009: build the plan for a named profile (read-only).
    .DESCRIPTION
        Profiles are data; the derivation engine produces the actual selections.
        The optional -Topology parameter accepts a model or a report and exists so
        the plan can be computed for a synthetic topology in tests. Nothing is
        applied and no process or registry state is touched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Competitive','Balanced','Streaming','Productivity')][string]$Profile,
        [object]$Topology = $null
    )
    $plan = New-NxCpuSetPlan -Topology $Topology -Profile $Profile
    $plan | Add-Member -NotePropertyName profileId -NotePropertyValue $plan.definition.id -Force
    $plan | Add-Member -NotePropertyName tweakId -NotePropertyValue $plan.definition.id -Force
    return $plan
}

function Get-NxRuleProperty {
    # Internal: reads a rule field from either a hashtable or an object, so the
    # custom builder accepts registry-shaped objects and caller hashtables alike.
    [CmdletBinding()]
    param($Rule, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Rule) { return $null }
    if ($Rule -is [System.Collections.IDictionary]) {
        if ($Rule.Contains($Name)) { return $Rule[$Name] }
        return $null
    }
    $prop = $Rule.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

function Test-NxCpuSetRule {
    <#
    .SYNOPSIS
        PURE validator for one user-defined custom rule.
    .DESCRIPTION
        Rejects placeholder/empty names, wildcards, unknown classes, logical
        indexes that do not exist in the detected topology, and unknown pools.
        Returns issues (never throws) so the custom builder can report every
        problem at once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Rule,
        [Parameter(Mandatory)]$Model
    )
    $issues = New-Object System.Collections.Generic.List[string]
    $nameValue = Get-NxRuleProperty -Rule $Rule -Name 'processName'
    $poolValue = Get-NxRuleProperty -Rule $Rule -Name 'pool'
    $lpValue = Get-NxRuleProperty -Rule $Rule -Name 'logicalProcessors'
    $classValue = Get-NxRuleProperty -Rule $Rule -Name 'class'
    if ([string]::IsNullOrWhiteSpace([string]$nameValue)) {
        $issues.Add('processName is required.')
    } else {
        $name = ([string]$nameValue).Trim()
        if ($name.Length -gt 260) { $issues.Add('processName exceeds 260 characters.') }
        if ($name -match '[\*\?]') { $issues.Add("processName '$name' contains a wildcard; exact image names are required.") }
        if ($name -match '[<>]') { $issues.Add("processName '$name' contains a placeholder token; supply the real image name.") }
        if ($name -match '[\\/]') { $issues.Add("processName '$name' must be an image name, not a path.") }
    }
    $class = [string]$classValue
    if (@('Game','Capture','Background') -notcontains $class) { $issues.Add("class '$class' is not Game, Capture or Background.") }
    $hasLps = $false
    $lpList = @()
    if ($null -ne $lpValue) { $lpList = @($lpValue) }
    if ($lpList.Count -gt 0) {
        $hasLps = $true
        $known = @($Model.allLogicalProcessors)
        foreach ($lp in $lpList) {
            $n = 0
            if (-not [int]::TryParse([string]$lp, [ref]$n)) { $issues.Add("logical processor '$lp' is not an integer."); continue }
            if ($known -notcontains $n) { $issues.Add("logical processor $n does not exist in the detected topology (0..$([int](($known | Measure-Object -Maximum).Maximum))).") }
        }
        if (@($lpList | Sort-Object -Unique).Count -ne $lpList.Count) {
            $issues.Add('logicalProcessors contains duplicates.')
        }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$poolValue)) {
        if (@('AllLogical','PerformanceLogical','PerformancePrimary','EfficiencyLogical','EfficiencyPrimary','PerformanceDie','NonPerformanceDie','CaptureReserve') -notcontains [string]$poolValue) {
            $issues.Add("pool '$poolValue' is not a known derived pool.")
        }
    }
    if (-not $hasLps -and [string]::IsNullOrWhiteSpace([string]$poolValue)) {
        $issues.Add('a rule needs either logicalProcessors or a pool name.')
    }
    return [pscustomobject]@{ valid = ($issues.Count -eq 0); issues = $issues.ToArray() }
}

function New-NxCustomSchedulingPlan {
    <#
    .SYNOPSIS
        NX19-010: topology-validated custom scheduling plan (read-only).
    .DESCRIPTION
        Rules are user-defined per-process selections. Every index is validated
        against the detected topology; an unknown index rejects the whole plan
        (it is never clamped or ignored). Bounded: 64 rules, exact names, one
        rule per process name, at least one Game rule. Nothing is applied here.
    #>
    [CmdletBinding()]
    param(
        [object]$Topology = $null,
        [AllowEmptyCollection()][object[]]$Rules = @()
    )
    $model = Get-NxModelFromTopologyInput -Topology $Topology
    $definition = Get-NxSchedulingProfileDefinition -Name 'Custom'
    $uncertainty = New-Object System.Collections.Generic.List[string]
    if ($null -eq $model) {
        return [pscustomobject]@{
            tweakId = 'NX19-010'; profile = 'Custom'; readOnly = $true; noWritesPerformed = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            topologyAvailable = $false; restrictive = $false; rules = @(); definition = $definition
            mechanismDefault = 'CpuSet'; affinityOptIn = $false; sessionScoped = $true
            certainty = 'Unavailable'; uncertainty = @('Topology unavailable: no custom plan derived.')
            fingerprint = $null; antiCheatNote = $script:Nx19AntiCheatNote; valid = $false; issues = @('Topology unavailable.')
        }
    }
    foreach ($u in @($model.uncertainty)) { $uncertainty.Add([string]$u) }
    $inputRules = @($Rules)
    $issues = New-Object System.Collections.Generic.List[string]
    if ($inputRules.Count -eq 0) { $issues.Add('At least one rule is required.') }
    if ($inputRules.Count -gt [int]$definition.maxRules) { $issues.Add(("At most {0} rules are accepted." -f $definition.maxRules)) }
    $seenNames = @{}
    $hasGame = $false
    $built = New-Object System.Collections.Generic.List[object]
    foreach ($rule in $inputRules) {
        if ($null -eq $rule) { $issues.Add('A null rule was supplied.'); continue }
        $check = Test-NxCpuSetRule -Rule $rule -Model $model
        foreach ($i in @($check.issues)) { $issues.Add([string]$i) }
        if (-not $check.valid) { continue }
        $ruleNameValue = Get-NxRuleProperty -Rule $rule -Name 'processName'
        $ruleClassValue = Get-NxRuleProperty -Rule $rule -Name 'class'
        $ruleLpValue = Get-NxRuleProperty -Rule $rule -Name 'logicalProcessors'
        $rulePoolValue = Get-NxRuleProperty -Rule $rule -Name 'pool'
        $name = ([string]$ruleNameValue).Trim()
        $key = $name.ToLowerInvariant()
        if ($seenNames.ContainsKey($key)) { $issues.Add("Duplicate process rule for '$name'."); continue }
        $seenNames[$key] = $true
        $class = [string]$ruleClassValue
        if ($class -eq 'Game') { $hasGame = $true }
        $classId = 3
        if ($class -eq 'Game') { $classId = 1 }
        elseif ($class -eq 'Capture') { $classId = 2 }
        $lps = @()
        $poolName = $null
        $ruleLpList = @()
        if ($null -ne $ruleLpValue) { $ruleLpList = @($ruleLpValue) }
        if ($ruleLpList.Count -gt 0) {
            $lps = @($ruleLpList | ForEach-Object { [int]$_ } | Sort-Object -Unique)
            $poolName = 'Custom'
        } else {
            $poolName = [string]$rulePoolValue
            $pool = Resolve-NxTopologyPool -Model $model -Pool $poolName
            $lps = @($pool.logicalProcessors | Sort-Object -Unique)
            if ($pool.note) { $uncertainty.Add([string]$pool.note) }
        }
        if ($lps.Count -eq 0) { $issues.Add("Rule '$name' derives no logical processors."); continue }
        $ids = ConvertTo-NxCpuSetIds -GlobalIndexes $lps -CpuSetEntries @($model.cpuSetMapping)
        $affinity = ConvertTo-NxAffinityMask -GlobalIndexes $lps
        if (-not $ids.resolved) {
            $uncertainty.Add(("Rule '{0}': CPU Set IDs unresolved for logical processors {1}; application must be refused for this rule." -f $name, (($ids.unresolvedLogicalProcessors) -join ',')))
        }
        $built.Add([pscustomobject]@{
            processName                 = $name
            class                       = $class
            classId                     = $classId
            pool                        = $poolName
            logicalProcessors           = $lps
            logicalProcessorCount       = $lps.Count
            mechanism                   = 'CpuSet'
            cpuSetIds                   = @($ids.cpuSetIds)
            cpuSetIdsResolved           = [bool]$ids.resolved
            unresolvedLogicalProcessors = @($ids.unresolvedLogicalProcessors)
            affinity                    = $affinity
            notes                       = @()
        })
    }
    if ($inputRules.Count -gt 0 -and -not $hasGame) { $issues.Add('At least one Game-class rule is required.') }
    $restrictive = $false
    foreach ($r in $built) {
        if (@($r.logicalProcessors).Count -gt 0 -and @($r.logicalProcessors).Count -lt [int]$model.logicalProcessorCount) { $restrictive = $true }
    }
    if ($issues.Count -gt 0) {
        return [pscustomobject]@{
            tweakId = 'NX19-010'; profile = 'Custom'; readOnly = $true; noWritesPerformed = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            topologyAvailable = $true; restrictive = $false; rules = @(); definition = $definition
            mechanismDefault = 'CpuSet'; affinityOptIn = $false; sessionScoped = $true
            certainty = 'Rejected'; uncertainty = $uncertainty.ToArray()
            fingerprint = $model.fingerprint; antiCheatNote = $script:Nx19AntiCheatNote
            valid = $false; issues = $issues.ToArray()
        }
    }
    return [pscustomobject]@{
        tweakId = 'NX19-010'; profile = 'Custom'; readOnly = $true; noWritesPerformed = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        topologyAvailable = $true; restrictive = $restrictive; rules = $built.ToArray(); definition = $definition
        mechanismDefault = 'CpuSet'; affinityOptIn = $false; sessionScoped = $true
        certainty = $(if ($uncertainty.Count -eq 0) { 'Derived' } else { 'DerivedWithUncertainty' })
        uncertainty = $uncertainty.ToArray()
        fingerprint = $model.fingerprint; antiCheatNote = $script:Nx19AntiCheatNote
        valid = $true; issues = @()
    }
}

# ---------------------------------------------------------------------------
# 7. AMD X3D / CCD-aware placement guidance (NX19-011, EXPERIMENTAL E0)
# ---------------------------------------------------------------------------

function Get-NxX3dPlacementGuidance {
    <#
    .SYNOPSIS
        NX19-011: best-effort X3D/CCD placement guidance (read-only).
    .DESCRIPTION
        Uses ONLY the topology model's per-die L3 asymmetry result. When die data
        is unavailable or the asymmetry is not beyond 2x, the report says so and
        refuses to infer X3D from the CPU marketing name. This function never
        applies placement; it returns guidance text plus the derived LP sets the
        owner could feed to NX19-002/010 explicitly.
    #>
    [CmdletBinding()]
    param([object]$Topology = $null)
    $model = Get-NxModelFromTopologyInput -Topology $Topology
    if ($null -eq $model) {
        return [pscustomobject]@{
            tweakId = 'NX19-011'; readOnly = $true; noWritesPerformed = $true; generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            topologyAvailable = $false; detection = 'Unavailable'; confidence = 'Unavailable'
            x3dIndicated = $false; largeDieIndexes = @(); largeDieLogicalProcessors = @(); otherDieLogicalProcessors = @()
            guidance = @('Topology is unavailable; no X3D/CCD guidance can be produced. Do not infer the CPU class from its marketing name.')
            uncertainty = @('Topology unavailable.')
        }
    }
    $x = $model.x3d
    $largeLps = @()
    $otherLps = @()
    $dies = @($model.dies)
    foreach ($d in $dies) {
        if (@($x.largeDieIndexes) -contains [int]$d.dieIndex) { $largeLps += @($d.logicalProcessors) }
        else { $otherLps += @($d.logicalProcessors) }
    }
    $largeLps = @($largeLps | Sort-Object -Unique)
    $otherLps = @($otherLps | Sort-Object -Unique)
    $guidance = New-Object System.Collections.Generic.List[string]
    $confidence = [string]$x.confidence
    if ($x.indicated) {
        $guidance.Add(("Best-effort detection: per-die level-3 cache differs by more than 2x. Large-L3 die(s): {0}; logical processors {1}." -f (($x.largeDieIndexes | ForEach-Object { "CCD $_" }) -join ', '), ($largeLps -join ',')))
        $guidance.Add('If the owner wants cache-favoured placement, select the large-L3 logical processors for the Game class (NX19-010 explicit rule) and keep background/capture work on the smaller-L3 die. This is guidance only; nothing is applied automatically.')
        $guidance.Add('Detection is cache-size asymmetry, never a CPU name list. Confirm with NX19-001 on the owner hardware; the indication stays EXPERIMENTAL/E0.')
    } elseif ($confidence -eq 'NoAsymmetryDetected') {
        $guidance.Add('No per-die level-3 asymmetry beyond 2x was detected, so no X3D-specific placement is offered. Symmetric multi-CCD systems remain labelled CCD 0..n without a cache preference.')
        $guidance.Add('Do not infer X3D (or non-X3D) from the processor marketing name; only the derived cache data is used.')
    } else {
        $guidance.Add('Per-die L3 data or the die relationship is unavailable, so X3D/CCD-aware placement cannot be evaluated. No cache-favoured placement is offered.')
        $guidance.Add('Do not infer X3D from the processor marketing name; re-run NX19-001 on the owner hardware and treat any result as best-effort.')
    }
    return [pscustomobject]@{
        tweakId              = 'NX19-011'
        readOnly             = $true
        noWritesPerformed    = $true
        generatedUtc         = (Get-Date).ToUniversalTime().ToString('o')
        topologyAvailable    = $true
        detection            = $(if ($x.indicated) { 'LargeL3DieAsymmetry' } elseif ($confidence -eq 'NoAsymmetryDetected') { 'NoAsymmetry' } else { 'NotDeterminable' })
        confidence           = $confidence
        evidence             = 'per-die-L3-asymmetry'
        x3dIndicated         = [bool]$x.indicated
        largeDieIndexes      = @($x.largeDieIndexes)
        perDieL3Bytes        = @($x.perDieL3Bytes)
        largeDieLogicalProcessors = $largeLps
        otherDieLogicalProcessors = $otherLps
        dies                 = $dies
        guidance             = $guidance.ToArray()
        uncertainty          = @($model.uncertainty)
        fingerprint          = $model.fingerprint
    }
}

# ---------------------------------------------------------------------------
# 8. Process application (NX19-003..005). SESSION-SCOPED, journal-first.
# ---------------------------------------------------------------------------

function Test-Nx19ProcessName {
    # Internal pure validation: exact image name, no wildcard or placeholder.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProcessName)
    $issues = New-Object System.Collections.Generic.List[string]
    $name = $ProcessName.Trim()
    if ($name.Length -eq 0) { $issues.Add('processName is empty.') }
    if ($name.Length -gt 260) { $issues.Add('processName exceeds 260 characters.') }
    if ($name -match '[\*\?]') { $issues.Add('processName contains a wildcard; an exact image name is required.') }
    if ($name -match '[<>]') { $issues.Add('processName contains a placeholder token; supply the real image name.') }
    if ($name -match '[\\/]') { $issues.Add('processName must be an image name, not a path (no path separators).') }
    return [pscustomobject]@{ valid = ($issues.Count -eq 0); issues = $issues.ToArray(); normalized = $name }
}

function Resolve-Nx19ProcessTargets {
    # Internal: resolve a process image name to live processes (bounded).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProcessName)
    $validation = Test-Nx19ProcessName -ProcessName $ProcessName
    if (-not $validation.valid) {
        return [pscustomobject]@{ valid = $false; reason = ($validation.issues -join ' '); processes = @() }
    }
    $normalized = $validation.normalized
    $baseName = $normalized
    if ($baseName.ToLowerInvariant().EndsWith('.exe')) { $baseName = $baseName.Substring(0, $baseName.Length - 4) }
    $matches = @()
    try { $matches = @(Get-Process -Name $baseName -ErrorAction SilentlyContinue) } catch { $matches = @() }
    if ($matches.Count -eq 0) {
        return [pscustomobject]@{ valid = $true; reason = "No running process matches image name '$baseName'."; processes = @() }
    }
    if ($matches.Count -gt $script:Nx19MaxProcessMatches) {
        return [pscustomobject]@{ valid = $false; reason = "More than $($script:Nx19MaxProcessMatches) processes match '$baseName'; refusing a broad fan-out."; processes = @() }
    }
    return [pscustomobject]@{ valid = $true; reason = $null; processes = @($matches | Sort-Object -Property Id) }
}

function Get-Nx19Win32Message {
    # Internal: documented Win32 error text for a numeric code.
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Code)
    try { return (New-Object System.ComponentModel.Win32Exception($Code)).Message } catch { return "Win32 error $Code" }
}

function Test-Nx19JournalReady {
    # Internal: journal-first invariant guard for the application functions.
    [CmdletBinding()]
    param([string]$JournalRoot)
    if ([string]::IsNullOrWhiteSpace($JournalRoot)) { return [pscustomobject]@{ ready = $false; reason = 'JournalRoot is required for a real application (journal-first invariant).' } }
    try {
        $state = Read-NxManifest -Path $JournalRoot
        if (-not $state.present) { return [pscustomobject]@{ ready = $false; reason = "Journal is not initialized at '$JournalRoot'; refusing to mutate." } }
    } catch {
        return [pscustomobject]@{ ready = $false; reason = "Journal could not be read: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ ready = $true; reason = $null }
}

function Test-Nx19IdSetEqual {
    # Internal pure: order-insensitive CPU Set ID comparison.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Left = @(),
        [AllowEmptyCollection()][object[]]$Right = @()
    )
    $a = @($Left | ForEach-Object { [uint32]$_ } | Sort-Object)
    $b = @($Right | ForEach-Object { [uint32]$_ } | Sort-Object)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
    return $true
}

function Get-NxMaskFromDescriptor {
    # Internal: reads a journaled affinity mask. The decimal string is
    # authoritative for the full unsigned 64-bit range; the numeric fallback
    # covers descriptors written by earlier builds.
    [CmdletBinding()]
    param($Descriptor, [string]$Name = 'affinityMask')
    if ($null -eq $Descriptor) { return [uint64]0 }
    $decimalName = $Name + 'Decimal'
    $decimalProp = $Descriptor.PSObject.Properties[$decimalName]
    if ($null -ne $decimalProp -and -not [string]::IsNullOrWhiteSpace([string]$decimalProp.Value)) {
        $parsed = [uint64]0
        if ([uint64]::TryParse([string]$decimalProp.Value, [ref]$parsed)) { return $parsed }
    }
    $raw = $Descriptor.$Name
    if ($null -eq $raw) { return [uint64]0 }
    $numeric = [uint64]0
    if ([uint64]::TryParse([string]$raw, [ref]$numeric)) { return $numeric }
    return [uint64]0
}

function Get-Nx19PriorityName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$Value)
    switch ($Value) {
        0x40   { return 'Idle' }
        0x4000 { return 'BelowNormal' }
        0x20   { return 'Normal' }
        0x8000 { return 'AboveNormal' }
        0x80   { return 'High' }
        0x100  { return 'RealTime' }
        default { return ("Unknown(0x{0:X})" -f $Value) }
    }
}

function Get-Nx19PriorityValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Idle','BelowNormal','Normal','AboveNormal')][string]$Name)
    switch ($Name) {
        'Idle'        { return [uint32]0x40 }
        'BelowNormal' { return [uint32]0x4000 }
        'Normal'      { return [uint32]0x20 }
        'AboveNormal' { return [uint32]0x8000 }
    }
}

function Get-NxProcessCpuSetState {
    <#
    .SYNOPSIS
        Read-only process scheduling state (CPU Sets, affinity mask, priority).
    .DESCRIPTION
        Opens the matching processes with query-only access and reads the three
        documented state surfaces. No mutation, no journal write. A process that
        cannot be opened is reported per PID with its Win32 reason.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProcessName)
    $targets = Resolve-Nx19ProcessTargets -ProcessName $ProcessName
    $result = [pscustomobject]@{
        readOnly        = $true
        noWritesPerformed = $true
        processName     = $ProcessName
        matched         = $targets.valid -and (@($targets.processes).Count -gt 0)
        reason          = $targets.reason
        processes       = @()
        uncertainty     = @()
    }
    $state = Initialize-Nx19Native
    if (-not $state.available) {
        $result.uncertainty = @([string]$state.reason)
        return $result
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($targets.processes)) {
        $entry = [ordered]@{ pid = [int]$p.Id; processName = [string]$p.ProcessName; opened = $false; cpuSets = @(); cpuSetCaptureStatus = 'NotRead'; affinityMask = $null; systemAffinityMask = $null; priorityClass = $null; priorityClassValue = $null; reason = $null }
        $handle = [IntPtr]::Zero
        try {
            $handle = [Nx19Native]::Open([uint32]0x1400, [uint32]$p.Id)
            if ($handle -eq [IntPtr]::Zero) {
                $entry.reason = "OpenProcess failed: $(Get-Nx19Win32Message -Code ([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
            } else {
                $entry.opened = $true
                $err = 0
                $sets = [Nx19Native]::ReadDefaultCpuSets($handle, [ref]$err)
                if ($null -eq $sets) { $entry.cpuSetCaptureStatus = "Unavailable (Win32 $err)" } else { $entry.cpuSets = @($sets); $entry.cpuSetCaptureStatus = 'Captured' }
                $pm = [uint64]0; $sm = [uint64]0; $aerr = 0
                if ([Nx19Native]::ReadAffinity($handle, [ref]$pm, [ref]$sm, [ref]$aerr)) { $entry.affinityMask = $pm; $entry.systemAffinityMask = $sm } else { $entry.reason = "GetProcessAffinityMask failed: $(Get-Nx19Win32Message -Code $aerr)" }
                $perr = 0
                $pc = [Nx19Native]::ReadPriority($handle, [ref]$perr)
                if ($pc -ne 0) { $entry.priorityClassValue = [uint32]$pc; $entry.priorityClass = Get-Nx19PriorityName -Value ([uint32]$pc) } else { $entry.reason = "GetPriorityClass failed: $(Get-Nx19Win32Message -Code $perr)" }
            }
        } catch {
            $entry.reason = [string]$_.Exception.Message
        } finally {
            if ($handle -ne [IntPtr]::Zero) { [void][Nx19Native]::Close($handle) }
        }
        $list.Add([pscustomobject]$entry)
    }
    $result.processes = $list.ToArray()
    return $result
}

function Set-NxProcessCpuSets {
    <#
    .SYNOPSIS
        NX19-003: apply default CPU Sets to a process by image name.
    .DESCRIPTION
        SetProcessDefaultCpuSets assigns the process-default CPU set: threads
        created afterwards inherit it, and Microsoft documents CPU Sets as a
        "soft" affinity mechanism. SESSION-SCOPED - the assignment ends with the
        process, is not persisted, and writes no registry value. The original
        default set is captured and journaled (targetType 'processCpuSets')
        before the call; a failed verification restores it. Requires a journal
        for real application; -WhatIf plans without any mutation.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$ProcessName,
        [uint32[]]$CpuSetIds,
        [ValidateSet('Competitive','Balanced','Streaming','Productivity')][string]$Profile,
        [object]$Topology = $null,
        [string]$JournalRoot,
        [string]$TweakId = 'NX19-003',
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @()
    )
    $summary = [pscustomobject]@{
        tweakId            = $TweakId
        mechanism          = 'CpuSet'
        processName        = $ProcessName
        readOnly           = $false
        sessionScoped      = $true
        scopeEndsWithProcess = $true
        persistence        = 'None'
        registryWrites     = $false
        affectsFutureProcesses = $false
        planned            = $false
        applied            = $false
        verified           = $false
        refused            = $false
        reason             = $null
        processes          = @()
        uncertainty        = @()
    }
    $state = Initialize-Nx19Native
    if (-not $state.available) {
        $summary.refused = $true
        $summary.reason = [string]$state.reason
        return $summary
    }
    $targets = Resolve-Nx19ProcessTargets -ProcessName $ProcessName
    if (-not $targets.valid) {
        $summary.refused = $true
        $summary.reason = $targets.reason
        return $summary
    }
    if (@($targets.processes).Count -eq 0) {
        $summary.refused = $true
        $summary.reason = $targets.reason
        return $summary
    }

    $selection = @()
    if ($PSBoundParameters.ContainsKey('CpuSetIds') -and @($CpuSetIds).Count -gt 0) {
        $selection = @($CpuSetIds | Sort-Object -Unique)
    } elseif ($Profile) {
        $plan = New-NxCpuSetPlan -Profile $Profile -Topology $Topology
        $gameRule = @($plan.rules | Where-Object { $_.class -eq 'Game' } | Select-Object -First 1)
        if ($gameRule.Count -eq 0 -or @($gameRule[0].logicalProcessors).Count -eq 0) {
            $summary.refused = $true
            $summary.reason = "Profile '$Profile' derives no Game CPU-set selection on this topology."
            return $summary
        }
        if (-not $gameRule[0].cpuSetIdsResolved) {
            $summary.refused = $true
            $summary.reason = ("CPU Set IDs are unresolved for logical processors {0}; no ID is fabricated." -f (@($gameRule[0].unresolvedLogicalProcessors) -join ','))
            return $summary
        }
        $selection = @($gameRule[0].cpuSetIds)
    } else {
        $summary.refused = $true
        $summary.reason = 'Supply -CpuSetIds (from NX19-002/010) or a -Profile so the IDs are topology-derived.'
        return $summary
    }
    if ($selection.Count -lt 1) {
        $summary.refused = $true
        $summary.reason = 'No CPU Set IDs were selected.'
        return $summary
    }
    if ($selection.Count -gt $script:Nx19MaxSelectedCpuSets) {
        $summary.refused = $true
        $summary.reason = "Selection has $($selection.Count) CPU Set IDs; the bounded maximum is $($script:Nx19MaxSelectedCpuSets)."
        return $summary
    }

    # Group-crossing note (documented: CPU assignments in groups that do not
    # match the thread's affinity mask are ignored). The IDs themselves remain
    # valid; this is reported, not guessed around.
    $mapping = @()
    if ($null -ne $Topology) {
        $model = Get-NxModelFromTopologyInput -Topology $Topology
        if ($null -ne $model) { $mapping = @($model.cpuSetMapping) }
    }
    if ($mapping.Count -eq 0) {
        $probe = Get-NxTopologyReport
        if ($probe.topologyAvailable) { $mapping = @($probe.cpuSetMap.mapping) }
    }
    if ($mapping.Count -gt 0) {
        $selectedGroups = @()
        foreach ($id in $selection) {
            $found = @($mapping | Where-Object { [uint32]$_.cpuSetId -eq [uint32]$id } | Select-Object -First 1)
            if ($found.Count -gt 0) {
                if ($selectedGroups -notcontains [int]$found[0].group) { $selectedGroups += [int]$found[0].group }
            } else {
                $summary.uncertainty = @($summary.uncertainty) + "CPU Set ID $id is not present in the current system map."
            }
        }
        if ($selectedGroups.Count -gt 1) {
            $summary.uncertainty = @($summary.uncertainty) + ("Selection spans processor groups {0}; Microsoft documents that CPU-set assignments in groups that do not match the thread's affinity mask are ignored." -f ($selectedGroups -join ','))
        }
    }

    $journal = $null
    if (-not $WhatIfPreference) {
        $journal = Test-Nx19JournalReady -JournalRoot $JournalRoot
        if (-not $journal.ready) {
            $summary.refused = $true
            $summary.reason = $journal.reason
            return $summary
        }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($targets.processes)) {
        $entry = [ordered]@{ pid = [int]$p.Id; processName = [string]$p.ProcessName; planned = $false; applied = $false; verified = $false; alreadyApplied = $false; reason = $null; journalSeq = $null }
        if (-not $PSCmdlet.ShouldProcess("pid $($p.Id) ($($p.ProcessName))", "Set process default CPU Sets")) {
            $entry.planned = $true
            $results.Add([pscustomobject]$entry)
            continue
        }
        $handle = [IntPtr]::Zero
        try {
            $handle = [Nx19Native]::Open([uint32]0x3000, [uint32]$p.Id)
            if ($handle -eq [IntPtr]::Zero) {
                $entry.reason = "OpenProcess failed: $(Get-Nx19Win32Message -Code ([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
                $results.Add([pscustomobject]$entry)
                continue
            }
            $err = 0
            $original = [Nx19Native]::ReadDefaultCpuSets($handle, [ref]$err)
            if ($null -eq $original) {
                $entry.reason = "Original default CPU sets could not be captured (Win32 $err): $(Get-Nx19Win32Message -Code $err). Refusing to mutate without a verified prior state."
                if ($journal.ready) {
                    $origDescriptor = [pscustomobject]@{ targetType = 'processCpuSets'; processName = [string]$p.ProcessName; pid = [int]$p.Id; cpuSetIds = @(); captureStatus = 'Unavailable'; sessionScoped = $true }
                    $modDescriptor = [pscustomobject]@{ targetType = 'processCpuSets'; processName = [string]$p.ProcessName; pid = [int]$p.Id; cpuSetIds = @($selection); mechanism = 'SetProcessDefaultCpuSets'; sessionScoped = $true }
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'Failed-CaptureRefused' -Verification 'NotRun' -ErrorInfo $entry.reason -Profiles $Profiles
                }
                $results.Add([pscustomobject]$entry)
                continue
            }
            if (Test-Nx19IdSetEqual -Left $original -Right $selection) {
                $entry.alreadyApplied = $true
                $entry.verified = $true
                $entry.reason = 'The process default CPU sets already equal the selection.'
                if ($journal.ready) {
                    $origDescriptor = [pscustomobject]@{ targetType = 'processCpuSets'; processName = [string]$p.ProcessName; pid = [int]$p.Id; cpuSetIds = @($original); captureStatus = 'Captured'; sessionScoped = $true }
                    $modDescriptor = [pscustomobject]@{ targetType = 'processCpuSets'; processName = [string]$p.ProcessName; pid = [int]$p.Id; cpuSetIds = @($selection); mechanism = 'SetProcessDefaultCpuSets'; sessionScoped = $true }
                    $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
                    $entry.journalSeq = $skip.seq
                }
                $results.Add([pscustomobject]$entry)
                continue
            }
            $origDescriptor = [pscustomobject]@{
                targetType = 'processCpuSets'; processName = [string]$p.ProcessName; pid = [int]$p.Id
                cpuSetIds = @($original); captureStatus = 'Captured'; sessionScoped = $true
            }
            $modDescriptor = [pscustomobject]@{
                targetType = 'processCpuSets'; processName = [string]$p.ProcessName; pid = [int]$p.Id
                cpuSetIds = @($selection); mechanism = 'SetProcessDefaultCpuSets'
                sessionScoped = $true; persistsAfterProcessExit = $false; registryWrites = $false
            }
            $applyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
            $entry.journalSeq = $applyJournal.seq
            $ok = $false
            try {
                $ok = [Nx19Native]::WriteDefaultCpuSets($handle, [uint32[]]$selection)
                if (-not $ok) {
                    $werr = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    throw "SetProcessDefaultCpuSets failed: $(Get-Nx19Win32Message -Code $werr) (Win32 $werr)"
                }
                $verifyErr = 0
                $verify = [Nx19Native]::ReadDefaultCpuSets($handle, [ref]$verifyErr)
                if ($null -eq $verify) { throw "Verification read failed (Win32 $verifyErr): $(Get-Nx19Win32Message -Code $verifyErr)" }
                if (-not (Test-Nx19IdSetEqual -Left $verify -Right $selection)) {
                    throw "Verification mismatch: the process default CPU sets do not equal the selection."
                }
                $entry.applied = $true
                $entry.verified = $true
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'Success' -Verification 'Verified' -Profiles $Profiles
            } catch {
                $entry.reason = [string]$_.Exception.Message
                try {
                    if (@($original).Count -eq 0) { [void][Nx19Native]::ClearDefaultCpuSets($handle) }
                    else { [void][Nx19Native]::WriteDefaultCpuSets($handle, [uint32[]]$original) }
                } catch { }
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $entry.reason -Profiles $Profiles
            }
        } catch {
            $entry.reason = [string]$_.Exception.Message
        } finally {
            if ($handle -ne [IntPtr]::Zero) { [void][Nx19Native]::Close($handle) }
        }
        $results.Add([pscustomobject]$entry)
    }
    $summary.processes = $results.ToArray()
    $summary.planned = (@($results | Where-Object { $_.planned }).Count -gt 0)
    $summary.applied = (@($results | Where-Object { $_.applied }).Count -gt 0)
    $summary.verified = ((@($results | Where-Object { $_.verified }).Count -gt 0) -and (@($results | Where-Object { $_.applied -and -not $_.verified }).Count -eq 0))
    return $summary
}

function Set-NxProcessAffinity {
    <#
    .SYNOPSIS
        NX19-004: apply a process affinity mask (separate, opt-in mechanism).
    .DESCRIPTION
        SetProcessAffinityMask is documented as a hard mask: it is respected above
        conflicting CPU-set assignments, inherited by child processes, and on
        systems with more than 64 processors the mask must name processors in a
        single processor group. This function therefore refuses a selection that
        spans groups (ConvertTo-NxAffinityMask) and a mask outside the system
        affinity mask. SESSION-SCOPED: no registry write, no persistence; the
        original mask is journaled (targetType 'processAffinity').
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$ProcessName,
        [int[]]$LogicalProcessors,
        [ValidateSet('Competitive','Balanced','Streaming','Productivity')][string]$Profile,
        [object]$Topology = $null,
        [string]$JournalRoot,
        [string]$TweakId = 'NX19-004',
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @()
    )
    $summary = [pscustomobject]@{
        tweakId            = $TweakId
        mechanism          = 'Affinity'
        processName        = $ProcessName
        readOnly           = $false
        sessionScoped      = $true
        scopeEndsWithProcess = $true
        persistence        = 'None'
        registryWrites     = $false
        inheritedByChildren = $true
        planned            = $false
        applied            = $false
        verified           = $false
        refused            = $false
        reason             = $null
        affinity           = $null
        processes          = @()
        uncertainty        = @()
    }
    $state = Initialize-Nx19Native
    if (-not $state.available) { $summary.refused = $true; $summary.reason = [string]$state.reason; return $summary }
    $targets = Resolve-Nx19ProcessTargets -ProcessName $ProcessName
    if (-not $targets.valid -or @($targets.processes).Count -eq 0) { $summary.refused = $true; $summary.reason = $targets.reason; return $summary }

    $selection = @()
    if ($PSBoundParameters.ContainsKey('LogicalProcessors') -and @($LogicalProcessors).Count -gt 0) {
        $selection = @($LogicalProcessors | Sort-Object -Unique)
    } elseif ($Profile) {
        $plan = New-NxCpuSetPlan -Profile $Profile -Topology $Topology
        $gameRule = @($plan.rules | Where-Object { $_.class -eq 'Game' } | Select-Object -First 1)
        if ($gameRule.Count -eq 0 -or @($gameRule[0].logicalProcessors).Count -eq 0) {
            $summary.refused = $true
            $summary.reason = "Profile '$Profile' derives no Game selection on this topology."
            return $summary
        }
        $selection = @($gameRule[0].logicalProcessors)
    } else {
        $summary.refused = $true
        $summary.reason = 'Supply -LogicalProcessors (topology-derived) or a -Profile.'
        return $summary
    }
    $affinity = ConvertTo-NxAffinityMask -GlobalIndexes $selection
    $summary.affinity = $affinity
    if (-not $affinity.supported) {
        $summary.refused = $true
        $summary.reason = $affinity.reason
        return $summary
    }
    $journal = $null
    if (-not $WhatIfPreference) {
        $journal = Test-Nx19JournalReady -JournalRoot $JournalRoot
        if (-not $journal.ready) { $summary.refused = $true; $summary.reason = $journal.reason; return $summary }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($targets.processes)) {
        $entry = [ordered]@{ pid = [int]$p.Id; processName = [string]$p.ProcessName; planned = $false; applied = $false; verified = $false; alreadyApplied = $false; reason = $null; journalSeq = $null; originalMask = $null }
        if (-not $PSCmdlet.ShouldProcess("pid $($p.Id) ($($p.ProcessName))", "Set process affinity mask")) {
            $entry.planned = $true
            $results.Add([pscustomobject]$entry)
            continue
        }
        $handle = [IntPtr]::Zero
        try {
            $handle = [Nx19Native]::Open([uint32]0x0600, [uint32]$p.Id)
            if ($handle -eq [IntPtr]::Zero) {
                $entry.reason = "OpenProcess failed: $(Get-Nx19Win32Message -Code ([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
                $results.Add([pscustomobject]$entry)
                continue
            }
            $pm = [uint64]0; $sm = [uint64]0; $aerr = 0
            if (-not [Nx19Native]::ReadAffinity($handle, [ref]$pm, [ref]$sm, [ref]$aerr)) {
                $entry.reason = "Original affinity mask could not be captured (Win32 $aerr): $(Get-Nx19Win32Message -Code $aerr). Refusing to mutate without a verified prior state."
                $results.Add([pscustomobject]$entry)
                continue
            }
            $entry.originalMask = $pm
            if (($affinity.mask -band $sm) -ne $affinity.mask) {
                $entry.reason = ("Requested mask 0x{0:X} is not a subset of the system affinity mask 0x{1:X} (documented requirement)." -f $affinity.mask, $sm)
                $results.Add([pscustomobject]$entry)
                continue
            }
            if ($pm -eq $affinity.mask) {
                $entry.alreadyApplied = $true
                $entry.verified = $true
                $entry.reason = 'The process affinity mask already equals the selection.'
                if ($journal.ready) {
                    $origDescriptor = [pscustomobject]@{ targetType = 'processAffinity'; processName = [string]$p.ProcessName; pid = [int]$p.Id; affinityMask = $pm.ToString([System.Globalization.CultureInfo]::InvariantCulture); affinityMaskDecimal = $pm.ToString([System.Globalization.CultureInfo]::InvariantCulture); captureStatus = 'Captured'; sessionScoped = $true }
                    $modDescriptor = [pscustomobject]@{ targetType = 'processAffinity'; processName = [string]$p.ProcessName; pid = [int]$p.Id; affinityMask = $affinity.mask.ToString([System.Globalization.CultureInfo]::InvariantCulture); affinityMaskDecimal = $affinity.mask.ToString([System.Globalization.CultureInfo]::InvariantCulture); mechanism = 'SetProcessAffinityMask'; sessionScoped = $true }
                    $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
                    $entry.journalSeq = $skip.seq
                }
                $results.Add([pscustomobject]$entry)
                continue
            }
            $origDescriptor = [pscustomobject]@{ targetType = 'processAffinity'; processName = [string]$p.ProcessName; pid = [int]$p.Id; affinityMask = $pm.ToString([System.Globalization.CultureInfo]::InvariantCulture); affinityMaskDecimal = $pm.ToString([System.Globalization.CultureInfo]::InvariantCulture); captureStatus = 'Captured'; sessionScoped = $true }
            $modDescriptor = [pscustomobject]@{ targetType = 'processAffinity'; processName = [string]$p.ProcessName; pid = [int]$p.Id; affinityMask = $affinity.mask.ToString([System.Globalization.CultureInfo]::InvariantCulture); affinityMaskDecimal = $affinity.mask.ToString([System.Globalization.CultureInfo]::InvariantCulture); mechanism = 'SetProcessAffinityMask'; sessionScoped = $true; persistsAfterProcessExit = $false; registryWrites = $false }
            $applyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
            $entry.journalSeq = $applyJournal.seq
            try {
                $werr = 0
                if (-not [Nx19Native]::WriteAffinity($handle, $affinity.mask, [ref]$werr)) {
                    throw "SetProcessAffinityMask failed: $(Get-Nx19Win32Message -Code $werr) (Win32 $werr)"
                }
                $vpm = [uint64]0; $vsm = [uint64]0; $verr = 0
                if (-not [Nx19Native]::ReadAffinity($handle, [ref]$vpm, [ref]$vsm, [ref]$verr)) { throw "Verification read failed (Win32 $verr)." }
                if ($vpm -ne $affinity.mask) { throw ("Verification mismatch: live mask 0x{0:X} does not equal requested 0x{1:X}." -f $vpm, $affinity.mask) }
                $entry.applied = $true
                $entry.verified = $true
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'Success' -Verification 'Verified' -Profiles $Profiles
            } catch {
                $entry.reason = [string]$_.Exception.Message
                try { [void][Nx19Native]::WriteAffinity($handle, $pm, [ref]$aerr) } catch { }
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $entry.reason -Profiles $Profiles
            }
        } catch {
            $entry.reason = [string]$_.Exception.Message
        } finally {
            if ($handle -ne [IntPtr]::Zero) { [void][Nx19Native]::Close($handle) }
        }
        $results.Add([pscustomobject]$entry)
    }
    $summary.processes = $results.ToArray()
    $summary.planned = (@($results | Where-Object { $_.planned }).Count -gt 0)
    $summary.applied = (@($results | Where-Object { $_.applied }).Count -gt 0)
    $summary.verified = ((@($results | Where-Object { $_.verified }).Count -gt 0) -and (@($results | Where-Object { $_.applied -and -not $_.verified }).Count -eq 0))
    return $summary
}

function Set-NxProcessPriority {
    <#
    .SYNOPSIS
        NX19-005: narrow per-process priority-class policy.
    .DESCRIPTION
        Uses the documented SetPriorityClass API through an explicit handle. The
        allowed classes are Idle, BelowNormal, Normal and AboveNormal; High and
        RealTime are REFUSED because they can starve system and input threads
        (documented priority-class semantics), so this entry stays narrow.
        SESSION-SCOPED; journal records the original priority class
        (targetType 'processPriority'). -WhatIf plans without mutation.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$ProcessName,
        [ValidateSet('Idle','BelowNormal','Normal','AboveNormal')][string]$PriorityClass,
        [string]$JournalRoot,
        [string]$TweakId = 'NX19-005',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @()
    )
    $summary = [pscustomobject]@{
        tweakId            = $TweakId
        mechanism          = 'PriorityClass'
        processName        = $ProcessName
        readOnly           = $false
        sessionScoped      = $true
        scopeEndsWithProcess = $true
        persistence        = 'None'
        registryWrites     = $false
        planned            = $false
        applied            = $false
        verified           = $false
        refused            = $false
        reason             = $null
        priorityClass      = $PriorityClass
        processes          = @()
        uncertainty        = @()
    }
    if ([string]::IsNullOrWhiteSpace($PriorityClass)) {
        $summary.refused = $true
        $summary.reason = 'PriorityClass is required; allowed values are Idle, BelowNormal, Normal, AboveNormal (High/RealTime are refused by design).'
        return $summary
    }
    $state = Initialize-Nx19Native
    if (-not $state.available) { $summary.refused = $true; $summary.reason = [string]$state.reason; return $summary }
    $targets = Resolve-Nx19ProcessTargets -ProcessName $ProcessName
    if (-not $targets.valid -or @($targets.processes).Count -eq 0) { $summary.refused = $true; $summary.reason = $targets.reason; return $summary }
    $desiredValue = Get-Nx19PriorityValue -Name $PriorityClass
    $journal = $null
    if (-not $WhatIfPreference) {
        $journal = Test-Nx19JournalReady -JournalRoot $JournalRoot
        if (-not $journal.ready) { $summary.refused = $true; $summary.reason = $journal.reason; return $summary }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($targets.processes)) {
        $entry = [ordered]@{ pid = [int]$p.Id; processName = [string]$p.ProcessName; planned = $false; applied = $false; verified = $false; alreadyApplied = $false; reason = $null; journalSeq = $null; originalClass = $null }
        if (-not $PSCmdlet.ShouldProcess("pid $($p.Id) ($($p.ProcessName))", "Set process priority class to $PriorityClass")) {
            $entry.planned = $true
            $results.Add([pscustomobject]$entry)
            continue
        }
        $handle = [IntPtr]::Zero
        try {
            $handle = [Nx19Native]::Open([uint32]0x0600, [uint32]$p.Id)
            if ($handle -eq [IntPtr]::Zero) {
                $entry.reason = "OpenProcess failed: $(Get-Nx19Win32Message -Code ([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
                $results.Add([pscustomobject]$entry)
                continue
            }
            $perr = 0
            $current = [Nx19Native]::ReadPriority($handle, [ref]$perr)
            if ($current -eq 0) {
                $entry.reason = "Original priority class could not be captured (Win32 $perr): $(Get-Nx19Win32Message -Code $perr). Refusing to mutate without a verified prior state."
                $results.Add([pscustomobject]$entry)
                continue
            }
            $entry.originalClass = Get-Nx19PriorityName -Value ([uint32]$current)
            if ($current -eq $desiredValue) {
                $entry.alreadyApplied = $true
                $entry.verified = $true
                $entry.reason = 'The process priority class already equals the selection.'
                if ($journal.ready) {
                    $origDescriptor = [pscustomobject]@{ targetType = 'processPriority'; processName = [string]$p.ProcessName; pid = [int]$p.Id; priorityClass = $entry.originalClass; priorityClassValue = [uint32]$current; captureStatus = 'Captured'; sessionScoped = $true }
                    $modDescriptor = [pscustomobject]@{ targetType = 'processPriority'; processName = [string]$p.ProcessName; pid = [int]$p.Id; priorityClass = $PriorityClass; priorityClassValue = [uint32]$desiredValue; mechanism = 'SetPriorityClass'; sessionScoped = $true }
                    $skip = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
                    $entry.journalSeq = $skip.seq
                }
                $results.Add([pscustomobject]$entry)
                continue
            }
            $origDescriptor = [pscustomobject]@{ targetType = 'processPriority'; processName = [string]$p.ProcessName; pid = [int]$p.Id; priorityClass = $entry.originalClass; priorityClassValue = [uint32]$current; captureStatus = 'Captured'; sessionScoped = $true }
            $modDescriptor = [pscustomobject]@{ targetType = 'processPriority'; processName = [string]$p.ProcessName; pid = [int]$p.Id; priorityClass = $PriorityClass; priorityClassValue = [uint32]$desiredValue; mechanism = 'SetPriorityClass'; sessionScoped = $true; persistsAfterProcessExit = $false; registryWrites = $false }
            $applyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
            $entry.journalSeq = $applyJournal.seq
            try {
                $werr = 0
                if (-not [Nx19Native]::WritePriority($handle, [uint32]$desiredValue, [ref]$werr)) {
                    throw "SetPriorityClass failed: $(Get-Nx19Win32Message -Code $werr) (Win32 $werr)"
                }
                $verr = 0
                $after = [Nx19Native]::ReadPriority($handle, [ref]$verr)
                if ($after -ne $desiredValue) { throw ("Verification mismatch: live priority class 0x{0:X} does not equal requested 0x{1:X}." -f $after, $desiredValue) }
                $entry.applied = $true
                $entry.verified = $true
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'Success' -Verification 'Verified' -Profiles $Profiles
            } catch {
                $entry.reason = [string]$_.Exception.Message
                try { [void][Nx19Native]::WritePriority($handle, [uint32]$current, [ref]$perr) } catch { }
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $origDescriptor -Modified $modDescriptor -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $entry.reason -Profiles $Profiles
            }
        } catch {
            $entry.reason = [string]$_.Exception.Message
        } finally {
            if ($handle -ne [IntPtr]::Zero) { [void][Nx19Native]::Close($handle) }
        }
        $results.Add([pscustomobject]$entry)
    }
    $summary.processes = $results.ToArray()
    $summary.planned = (@($results | Where-Object { $_.planned }).Count -gt 0)
    $summary.applied = (@($results | Where-Object { $_.applied }).Count -gt 0)
    $summary.verified = ((@($results | Where-Object { $_.verified }).Count -gt 0) -and (@($results | Where-Object { $_.applied -and -not $_.verified }).Count -eq 0))
    return $summary
}

# ---------------------------------------------------------------------------
# 9. Session rollback (delegated by Invoke-NxRollback for non-registry targets)
# ---------------------------------------------------------------------------

function Invoke-Nx19Rollback {
    <#
    .SYNOPSIS
        Restores journaled NX19 process-scheduling applications (session scope).
    .DESCRIPTION
        Called by the shared rollback engine for targetType processCpuSets /
        processAffinity / processPriority. Only-if-ours: a live process is
        restored only when its current state still equals the recorded modified
        state. A process that already ended needs no restore - the session-scoped
        change ended with it, which is reported honestly as irreversible-by-design
        (nothing is left behind).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId
    )
    $journal = Read-NxJournal -Path $JournalRoot
    if ($journal.integrityErrors.Count -gt 0) {
        return [pscustomobject]@{ aborted = $true; integrityErrors = @($journal.integrityErrors); restored = @(); diverged = @(); failed = @(); irreversible = @() }
    }
    $targetTypes = @('processCpuSets','processAffinity','processPriority')
    $candidates = @($journal.entries | Where-Object { $_.operation -eq 'apply' -and ($targetTypes -contains [string]$_.original.targetType) })
    if ($TweakId) { $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId }) }
    [array]::Reverse($candidates)
    $state = Initialize-Nx19Native
    if (-not $state.available) {
        return [pscustomobject]@{ aborted = $true; integrityErrors = @(); restored = @(); diverged = @(); failed = @([pscustomobject]@{ reason = [string]$state.reason }); irreversible = @() }
    }
    $restored = New-Object System.Collections.Generic.List[object]
    $diverged = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]
    $irreversible = New-Object System.Collections.Generic.List[object]
    foreach ($e in $candidates) {
        $tt = [string]$e.original.targetType
        $pidValue = 0
        try { $pidValue = [int]$e.original.pid } catch { $pidValue = 0 }
        $live = $null
        if ($pidValue -gt 0) { $live = Get-Process -Id $pidValue -ErrorAction SilentlyContinue }
        $expectedName = [string]$e.original.processName
        if ($null -eq $live -or -not ([string]$live.ProcessName).ToLowerInvariant().StartsWith($expectedName.ToLowerInvariant())) {
            $irreversible.Add([pscustomobject]@{ tweakId = $e.tweakId; pid = $pidValue; processName = $expectedName; targetType = $tt; reason = 'The process is no longer running; the session-scoped assignment ended with it. Nothing is left to restore (no persistence).' })
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Skipped-SessionEnded' -Verification 'NotRun' -ErrorInfo 'process ended before rollback' -Profiles @($e.profiles)
            continue
        }
        $handle = [IntPtr]::Zero
        try {
            $handle = [Nx19Native]::Open([uint32]0x3600, [uint32]$pidValue)
            if ($handle -eq [IntPtr]::Zero) { throw "OpenProcess failed: $(Get-Nx19Win32Message -Code ([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
            $ours = $false
            if ($tt -eq 'processCpuSets') {
                $err = 0
                $current = [Nx19Native]::ReadDefaultCpuSets($handle, [ref]$err)
                if ($null -eq $current) { throw "current CPU sets unreadable (Win32 $err)" }
                $ours = Test-Nx19IdSetEqual -Left $current -Right @($e.modified.cpuSetIds)
            } elseif ($tt -eq 'processAffinity') {
                $pm = [uint64]0; $sm = [uint64]0; $err = 0
                if (-not [Nx19Native]::ReadAffinity($handle, [ref]$pm, [ref]$sm, [ref]$err)) { throw "current affinity unreadable (Win32 $err)" }
                $ours = ($pm -eq (Get-NxMaskFromDescriptor -Descriptor $e.modified))
            } else {
                $err = 0
                $current = [Nx19Native]::ReadPriority($handle, [ref]$err)
                if ($current -eq 0) { throw "current priority unreadable (Win32 $err)" }
                $ours = ($current -eq [uint32]$e.modified.priorityClassValue)
            }
            if (-not $ours) {
                $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; pid = $pidValue; processName = $expectedName; targetType = $tt; reason = 'Live state no longer equals the NEXTRIX-recorded modified state; left untouched for the owner.' })
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: live state differs from recorded modified state' -Profiles @($e.profiles)
                continue
            }
            if ($tt -eq 'processCpuSets') {
                $originalIds = @($e.original.cpuSetIds)
                $ok = $false
                if (@($originalIds).Count -eq 0) { $ok = [Nx19Native]::ClearDefaultCpuSets($handle) }
                else { $ok = [Nx19Native]::WriteDefaultCpuSets($handle, [uint32[]]$originalIds) }
                if (-not $ok) { throw "restore call failed: $(Get-Nx19Win32Message -Code ([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
                $err = 0
                $after = [Nx19Native]::ReadDefaultCpuSets($handle, [ref]$err)
                if ($null -eq $after -or -not (Test-Nx19IdSetEqual -Left $after -Right $originalIds)) { throw 'restored CPU sets did not verify.' }
            } elseif ($tt -eq 'processAffinity') {
                $err = 0
                $originalMask = Get-NxMaskFromDescriptor -Descriptor $e.original
                if (-not [Nx19Native]::WriteAffinity($handle, $originalMask, [ref]$err)) { throw "restore call failed (Win32 $err)." }
                $pm = [uint64]0; $sm = [uint64]0
                if (-not [Nx19Native]::ReadAffinity($handle, [ref]$pm, [ref]$sm, [ref]$err) -or $pm -ne $originalMask) { throw 'restored affinity did not verify.' }
            } else {
                $err = 0
                if (-not [Nx19Native]::WritePriority($handle, [uint32]$e.original.priorityClassValue, [ref]$err)) { throw "restore call failed (Win32 $err)." }
                $after = [Nx19Native]::ReadPriority($handle, [ref]$err)
                if ($after -ne [uint32]$e.original.priorityClassValue) { throw 'restored priority did not verify.' }
            }
            $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; pid = $pidValue; processName = $expectedName; targetType = $tt; verified = $true })
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Success' -Verification 'Verified' -Profiles @($e.profiles)
        } catch {
            $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; pid = $pidValue; processName = $expectedName; targetType = $tt; reason = [string]$_.Exception.Message })
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'failed' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles @($e.profiles)
        } finally {
            if ($handle -ne [IntPtr]::Zero) { [void][Nx19Native]::Close($handle) }
        }
    }
    return [pscustomobject]@{
        aborted        = $false
        restored       = $restored.ToArray()
        diverged       = $diverged.ToArray()
        failed         = $failed.ToArray()
        irreversible   = $irreversible.ToArray()
        integrityErrors = @()
    }
}

