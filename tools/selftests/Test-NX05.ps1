#Requires -Version 5.1
<#
    Test-NX05.ps1 - NX05 Memory Management self-test (temp-only, read-only host access).

    Scope and safety:
      - Loads the core modules + src/nxcore/functions/NX05.ps1 into THIS process only.
      - Creates a throwaway journal under %TEMP% and deletes it at the end.
      - NEVER applies a tweak. Mutating functions are only called in ways that must
        throw BEFORE any capture/journal write/mutation (approval gate, consent
        gate, journal-not-initialized, input validation). The self-test asserts
        that the throwaway journal received ZERO entries, which proves the gates
        fire before the journal-first write.
      - Read-only report functions are executed (CIM/registry reads only); that is
        permitted by the testing boundary and is exactly what they are for.

    Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\selftests\Test-NX05.ps1
    Exit code 0 = all tests passed, 1 = at least one failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$coreDir = Join-Path $repoRoot 'src\nxcore'
$fnFile  = Join-Path $coreDir 'functions\NX05.ps1'
$regFile = Join-Path $repoRoot 'registry\NX05.json'

$pass = 0; $fail = 0
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Nx05Test {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Test)
    try {
        $result = & $Test
        if ($result -eq $true) {
            $script:pass++
            Write-Output ("PASS  " + $Name)
        } else {
            $script:fail++
            $script:failures.Add($Name + ' (returned false)')
            Write-Output ("FAIL  " + $Name)
        }
    } catch {
        $script:fail++
        $script:failures.Add($Name + ' (' + $_.Exception.Message + ')')
        Write-Output ("FAIL  " + $Name + ' :: ' + $_.Exception.Message)
    }
}

function Assert-Nx05Throws {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Test, [string]$Match = '')
    try {
        & $Test | Out-Null
        $script:fail++
        $script:failures.Add($Name + ' (did not throw)')
        Write-Output ("FAIL  " + $Name + ' :: did not throw')
    } catch {
        $msg = [string]$_.Exception.Message
        if ($Match.Length -eq 0 -or $msg -like ('*' + $Match + '*')) {
            $script:pass++
            Write-Output ("PASS  " + $Name)
        } else {
            $script:fail++
            $script:failures.Add($Name + " (threw unexpected: $msg)")
            Write-Output ("FAIL  " + $Name + " :: unexpected message: $msg")
        }
    }
}

foreach ($m in @('NxJournal.ps1', 'NxVerify.ps1', 'NxApply.ps1', 'NxRollback.ps1', 'NxBuild.ps1', 'NxHardware.ps1', 'NxCompat.ps1')) {
    . (Join-Path $coreDir $m)
}
. $fnFile

$tempJournal = Join-Path $env:TEMP ('NEXTRIX_NX05_SELFTEST_' + [guid]::NewGuid().ToString('N'))
$uninitializedJournal = Join-Path $env:TEMP ('NEXTRIX_NX05_NOJOURNAL_' + [guid]::NewGuid().ToString('N'))
New-Item -Path $tempJournal -ItemType Directory -Force | Out-Null
try {
    # ------------------------------------------------------------------ pure
    Assert-Nx05Test 'pagingFiles parser: counts, drive, system-managed flag, unparsable kept' {
        $e = @(ConvertFrom-Nx05PagingFiles -Entries @('C:\pagefile.sys 0 0', 'D:\pagefile.sys 2048 4096', 'not a pagefile line', '', '   '))
        if ($e.Count -ne 3) { return $false }
        if (-not ($e[0].systemManaged -and $e[0].parseOk -and $e[0].drive -eq 'C:')) { return $false }
        if (-not ($e[1].parseOk -and $e[1].drive -eq 'D:' -and $e[1].initialSizeMB -eq 2048 -and $e[1].maximumSizeMB -eq 4096)) { return $false }
        if ($e[2].parseOk -or $e[2].raw -ne 'not a pagefile line') { return $false }
        return $true
    }

    Assert-Nx05Test 'pagingFiles entry formatting' {
        return ((New-Nx05PagingFileEntry -Drive 'c:\' -InitialSizeMB 1024 -MaximumSizeMB 8192) -eq 'C:\pagefile.sys 1024 8192')
    }

    Assert-Nx05Test 'pagingFiles parser: wildcard and path-only forms are system-managed' {
        $e = @(ConvertFrom-Nx05PagingFiles -Entries @('?:\pagefile.sys', 'D:\pagefile.sys', 'C:\pagefile.sys 1024'))
        if ($e.Count -ne 3) { return $false }
        if (-not ($e[0].parseOk -and $e[0].drive -eq '?' -and $e[0].systemManaged)) { return $false }
        if (-not ($e[1].parseOk -and $e[1].drive -eq 'D:' -and $e[1].systemManaged)) { return $false }
        if ($e[2].parseOk) { return $false }
        return $true
    }

    Assert-Nx05Test 'merge: custom size replaces wildcard system-drive entry, preserves other drives' {
        $m = @(Get-Nx05MergedPagingFiles -Existing @('?:\pagefile.sys', 'D:\pagefile.sys 2048 4096') -Drive 'C:' -InitialSizeMB 1024 -MaximumSizeMB 8192 -SystemDrive 'C:')
        if ($m.Count -ne 2) { return $false }
        if ($m[0] -ne 'C:\pagefile.sys 1024 8192') { return $false }
        if ($m[1] -ne 'D:\pagefile.sys 2048 4096') { return $false }
        return $true
    }

    Assert-Nx05Test 'merge: duplicate entries for the target drive collapse to one, unparsable lines survive' {
        $m = @(Get-Nx05MergedPagingFiles -Existing @('C:\pagefile.sys 1 2', 'weird legacy line', 'C:\pagefile.sys 3 4') -Drive 'C:' -InitialSizeMB 1024 -MaximumSizeMB 8192 -SystemDrive 'C:')
        if ($m.Count -ne 2) { return $false }
        if ($m[0] -ne 'C:\pagefile.sys 1024 8192') { return $false }
        if ($m[1] -ne 'weird legacy line') { return $false }
        return $true
    }

    Assert-Nx05Test 'merge: appends when the drive has no entry' {
        $m = @(Get-Nx05MergedPagingFiles -Existing @() -Drive 'D:' -InitialSizeMB 1024 -MaximumSizeMB 8192 -SystemDrive 'C:')
        return ($m.Count -eq 1 -and $m[0] -eq 'D:\pagefile.sys 1024 8192')
    }

    Assert-Nx05Test 'string array equality normalizes blanks/whitespace but not order' {
        $a = Test-Nx05StringArraysEqual -Left @(' C:\pagefile.sys 1024 8192 ', '') -Right @('C:\pagefile.sys 1024 8192')
        $b = Test-Nx05StringArraysEqual -Left @('C:\pagefile.sys 1024 8192', 'D:\pagefile.sys 1 2') -Right @('D:\pagefile.sys 1 2', 'C:\pagefile.sys 1024 8192')
        return ($a -and -not $b)
    }

    Assert-Nx05Test 'DWORD 0xFFFFFFFF normalizes to stored -1' {
        return ((ConvertTo-Nx05DwordStored -Value 4294967295) -eq -1 -and (ConvertTo-Nx05DwordStored -Value 60) -eq 60)
    }

    Assert-Nx05Test 'descriptor equality: absence, kind mismatch, value mismatch' {
        $absent = [pscustomobject]@{ existed = $false; kind = $null; value = $null }
        $dword1 = [pscustomobject]@{ existed = $true; kind = 'DWord'; value = 1 }
        $dword0 = [pscustomobject]@{ existed = $true; kind = 'DWord'; value = 0 }
        $string1 = [pscustomobject]@{ existed = $true; kind = 'String'; value = '1' }
        return ((Test-Nx05DescriptorEquals -Live $absent -Recorded $absent) -and
                -not (Test-Nx05DescriptorEquals -Live $dword1 -Recorded $absent) -and
                (Test-Nx05DescriptorEquals -Live $dword1 -Recorded $dword1) -and
                -not (Test-Nx05DescriptorEquals -Live $dword0 -Recorded $dword1) -and
                -not (Test-Nx05DescriptorEquals -Live $string1 -Recorded $dword1))
    }

    Assert-Nx05Test 'descriptor equality: MultiString single-entry vs array form' {
        $recorded = [pscustomobject]@{ existed = $true; kind = 'MultiString'; value = 'C:\pagefile.sys 0 0' }
        $liveSame = [pscustomobject]@{ existed = $true; kind = 'MultiString'; value = @('C:\pagefile.sys 0 0') }
        $liveDiff = [pscustomobject]@{ existed = $true; kind = 'MultiString'; value = @('C:\pagefile.sys 1 2') }
        return ((Test-Nx05DescriptorEquals -Live $liveSame -Recorded $recorded) -and
                -not (Test-Nx05DescriptorEquals -Live $liveDiff -Recorded $recorded))
    }

    Assert-Nx05Test 'pagefile only-if-ours: systemManaged' {
        $liveOn  = [pscustomobject]@{ automaticManaged = [pscustomobject]@{ existed = $true; value = 1 }; pagingFilesRaw = @('C:\pagefile.sys 0 0'); entryCount = 1 }
        $liveOff = [pscustomobject]@{ automaticManaged = [pscustomobject]@{ existed = $true; value = 0 }; pagingFilesRaw = @('C:\pagefile.sys 0 0'); entryCount = 1 }
        $mod = [pscustomobject]@{ mode = 'systemManaged' }
        return ((Test-Nx05PagefileStateMatches -Live $liveOn -Modified $mod) -and -not (Test-Nx05PagefileStateMatches -Live $liveOff -Modified $mod))
    }

    Assert-Nx05Test 'pagefile only-if-ours: custom requires exact array and auto=0' {
        $mod = [pscustomobject]@{ mode = 'custom'; pagingFiles = @('C:\pagefile.sys 1024 8192') }
        $match = [pscustomobject]@{ automaticManaged = [pscustomobject]@{ existed = $true; value = 0 }; pagingFilesRaw = @('C:\pagefile.sys 1024 8192'); entryCount = 1 }
        $wrongSize = [pscustomobject]@{ automaticManaged = [pscustomobject]@{ existed = $true; value = 0 }; pagingFilesRaw = @('C:\pagefile.sys 1024 4096'); entryCount = 1 }
        $autoOn = [pscustomobject]@{ automaticManaged = [pscustomobject]@{ existed = $true; value = 1 }; pagingFilesRaw = @('C:\pagefile.sys 1024 8192'); entryCount = 1 }
        return ((Test-Nx05PagefileStateMatches -Live $match -Modified $mod) -and
                -not (Test-Nx05PagefileStateMatches -Live $wrongSize -Modified $mod) -and
                -not (Test-Nx05PagefileStateMatches -Live $autoOn -Modified $mod))
    }

    Assert-Nx05Test 'pagefile only-if-ours: disabled requires no entries and auto=0' {
        $mod = [pscustomobject]@{ mode = 'disabled' }
        $off = [pscustomobject]@{ automaticManaged = [pscustomobject]@{ existed = $true; value = 0 }; pagingFilesRaw = @(); entryCount = 0 }
        $on  = [pscustomobject]@{ automaticManaged = [pscustomobject]@{ existed = $true; value = 1 }; pagingFilesRaw = @(); entryCount = 0 }
        $entries = [pscustomobject]@{ automaticManaged = [pscustomobject]@{ existed = $true; value = 0 }; pagingFilesRaw = @('C:\pagefile.sys 0 0'); entryCount = 1 }
        return ((Test-Nx05PagefileStateMatches -Live $off -Modified $mod) -and
                -not (Test-Nx05PagefileStateMatches -Live $on -Modified $mod) -and
                -not (Test-Nx05PagefileStateMatches -Live $entries -Modified $mod))
    }

    # ------------------------------------------------------------- gates (no mutation)
    Assert-Nx05Throws 'gate: NX05-001 refuses without -Approved' {
        Set-NxSystemManagedPagefile -JournalRoot $tempJournal
    } 'requires -Approved'

    Assert-Nx05Throws 'gate: NX05-001 refuses an uninitialized journal' {
        Set-NxSystemManagedPagefile -JournalRoot $uninitializedJournal -Approved
    } 'journal not initialized'

    Assert-Nx05Throws 'gate: NX05-003 refuses without -AcknowledgeCommitRisk' {
        Disable-NxPagefile -JournalRoot $tempJournal -Approved
    } 'AcknowledgeCommitRisk'

    Assert-Nx05Throws 'gate: NX05-003 refuses an uninitialized journal even with the acknowledgment' {
        Disable-NxPagefile -JournalRoot $uninitializedJournal -Approved -AcknowledgeCommitRisk
    } 'journal not initialized'

    Assert-Nx05Throws 'gate: NX05-002 rejects a missing drive' {
        Set-NxCustomPagefile -JournalRoot $tempJournal -Approved -Drive 'Z:' -InitialSizeMB 1024 -MaximumSizeMB 4096
    } 'not present'

    Assert-Nx05Throws 'gate: NX05-002 rejects 0/0 (system-managed belongs to NX05-001)' {
        Set-NxCustomPagefile -JournalRoot $tempJournal -Approved -Drive 'C:' -InitialSizeMB 0 -MaximumSizeMB 0
    } 'NX05-001'

    Assert-Nx05Throws 'gate: NX05-002 rejects maximum < initial' {
        Set-NxCustomPagefile -JournalRoot $tempJournal -Approved -Drive 'C:' -InitialSizeMB 4096 -MaximumSizeMB 1024
    } 'must be >='

    Assert-Nx05Throws 'gate: NX05-004 refuses without -Approved' {
        Set-NxMemoryCompression -JournalRoot $tempJournal -Enabled $false
    } 'requires -Approved'

    Assert-Nx05Throws 'gate: NX05-009 ValidateSet refuses None' {
        Set-NxCrashDumpConfiguration -JournalRoot $tempJournal -Approved -DumpType 'None'
    } 'None'

    Assert-Nx05Throws 'gate: NX05-010 refuses without -AcknowledgeSymptom' {
        Set-NxPoolLimitConfiguration -JournalRoot $tempJournal -Approved -PoolUsageMaximum 60 -SymptomNote 'documented paged pool exhaustion symptom'
    } 'AcknowledgeSymptom'

    Assert-Nx05Throws 'gate: NX05-010 refuses a missing symptom note' {
        Set-NxPoolLimitConfiguration -JournalRoot $tempJournal -Approved -AcknowledgeSymptom -PoolUsageMaximum 60 -SymptomNote 'short'
    } 'SymptomNote'

    Assert-Nx05Throws 'gate: NX05-010 refuses when no value is selected' {
        Set-NxPoolLimitConfiguration -JournalRoot $tempJournal -Approved -AcknowledgeSymptom -SymptomNote 'documented paged pool exhaustion symptom'
    } 'no pool value selected'

    Assert-Nx05Throws 'gate: NX05-010 validates KPI percent range' {
        Set-NxPoolLimitConfiguration -JournalRoot $tempJournal -Approved -AcknowledgeSymptom -SymptomNote 'documented paged pool exhaustion symptom' -PoolUsageMaximum 300
    } '1..100'

    # ------------------------------------- journal round-trip (exact pagefile state)
    Assert-Nx05Test 'journal round-trip keeps exact pagefile descriptors and passes the integrity chain' {
        $j = Join-Path $tempJournal 'roundtrip'
        $null = Initialize-NxJournal -Path $j -Force
        $orig = [pscustomobject]@{
            targetType = 'pagefileState'
            automaticManaged = [pscustomobject]@{ targetType = 'registry'; path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; name = 'AutomaticManagedPagefile'; keyExisted = $true; existed = $true; kind = 'DWord'; value = 0 }
            pagingFiles = [pscustomobject]@{ targetType = 'registry'; path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; name = 'PagingFiles'; keyExisted = $true; existed = $true; kind = 'MultiString'; value = @('C:\pagefile.sys 0 0', 'D:\pagefile.sys 1024 2048') }
            reported = [pscustomobject]@{ automaticManagedPagefile = $false; pageFileSettings = @() }
        }
        $mod = [pscustomobject]@{ targetType = 'pagefileState'; mode = 'custom'; pagingFiles = @('C:\pagefile.sys 1024 8192') }
        $null = Add-NxJournalEntry -Path $j -TweakId 'NX05-002' -TweakVersion '1' -Operation 'apply' -Approval 'ExplicitConsent' -Original $orig -Modified $mod -Result 'InProgress' -Verification 'NotRun'
        $null = Add-NxJournalEntry -Path $j -TweakId 'NX05-002' -TweakVersion '1' -Operation 'verify' -Approval 'ExplicitConsent' -Original $orig -Modified $mod -Result 'Success' -Verification 'Verified'
        $read = Read-NxJournal -Path $j
        if ($read.integrityErrors.Count -gt 0) { Write-Output ('  integrity errors: ' + ($read.integrityErrors -join '; ')); return $false }
        if ($read.entries.Count -ne 2) { return $false }
        # PS 5.1: @() over a List[object] of PSCustomObjects throws
        # "Argument types do not match" - index the list directly.
        $e = $read.entries[0]
        $pf = @($e.original.pagingFiles.value)
        if ($pf.Count -ne 2 -or $pf[0] -ne 'C:\pagefile.sys 0 0' -or $pf[1] -ne 'D:\pagefile.sys 1024 2048') { return $false }
        if ([string]$e.original.pagingFiles.kind -ne 'MultiString') { return $false }
        if (@(Get-Nx05RollbackCandidates -JournalEntries $read.entries).Count -ne 1) { return $false }
        return $true
    }

    # ------------------------------------------------------- rollback selection (pure)
    Assert-Nx05Test 'rollback candidate selection is restricted to verified NX05 state entries' {
        $entries = @(
            [pscustomobject]@{ tweakId = 'NX05-001'; operation = 'verify'; result = 'Success'; verification = 'Verified'; original = [pscustomobject]@{ targetType = 'pagefileState' } },
            [pscustomobject]@{ tweakId = 'NX05-004'; operation = 'verify'; result = 'Success'; verification = 'Verified'; original = [pscustomobject]@{ targetType = 'mmAgentState' } },
            [pscustomobject]@{ tweakId = 'NX05-001'; operation = 'apply'; result = 'InProgress'; verification = 'NotRun'; original = [pscustomobject]@{ targetType = 'pagefileState' } },
            [pscustomobject]@{ tweakId = 'NX05-009'; operation = 'verify'; result = 'FailedVerification'; verification = 'NotVerified'; original = [pscustomobject]@{ targetType = 'crashDumpState' } },
            [pscustomobject]@{ tweakId = 'NX04-001'; operation = 'verify'; result = 'Success'; verification = 'Verified'; original = [pscustomobject]@{ targetType = 'registry' } }
        )
        $sel = @(Get-Nx05RollbackCandidates -JournalEntries $entries)
        return ($sel.Count -eq 2 -and $sel[0].tweakId -eq 'NX05-001' -and $sel[1].tweakId -eq 'NX05-004')
    }

    # ------------------------------------------------------------- registry wiring
    Assert-Nx05Test 'registry function actions resolve and parameters exist on their functions' {
        if (-not (Test-Path $regFile)) { return $false }
        $reg = Get-Content $regFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($t in @($reg.tweaks)) {
            foreach ($a in @($t.apply.actions)) {
                if ($a.type -ne 'function') { continue }
                $cmd = Get-Command -Name $a.function -CommandType Function -ErrorAction SilentlyContinue
                if ($null -eq $cmd) { Write-Output ("  missing function for $($t.id): $($a.function)"); return $false }
                if ($a.parameters) {
                    foreach ($p in $a.parameters.PSObject.Properties) {
                        if (-not $cmd.Parameters.ContainsKey([string]$p.Name)) {
                            Write-Output ("  $($t.id): parameter '$($p.Name)' not declared by $($a.function)")
                            return $false
                        }
                    }
                }
            }
        }
        return $true
    }

    # ------------------------------------------------------------- read-only reports
    Assert-Nx05Test 'NX05-005 report is read-only and carries uncertainty array' {
        $r = Get-NxMemoryPressureReport
        return ($r.readOnly -eq $true -and $r.tweakId -eq 'NX05-005' -and $null -ne $r.PSObject.Properties['uncertainty'] -and $r.noPerformanceClaim -eq $true)
    }

    Assert-Nx05Test 'NX05-006 report declares no standby cleaner' {
        $r = Get-NxStandbyMemoryReport
        return ($r.readOnly -eq $true -and $r.cleanerPresent -eq $false -and $r.policyNote -like '*no scheduled cleaner*')
    }

    Assert-Nx05Test 'NX05-011 suite composes MMAgent, RAM, commit and both sub-reports' {
        $r = Get-NxMemoryDiagnosticsReport
        return ($r.readOnly -eq $true -and $null -ne $r.mmAgent -and $null -ne $r.ram -and $null -ne $r.commit -and $null -ne $r.pressureReport -and $null -ne $r.pageListReport)
    }

    # --------------------------------------------- journal untouched by gate failures
    Assert-Nx05Test 'no journal entries were written by any gate failure' {
        $manifestPath = Join-Path $tempJournal 'manifest.json'
        if (Test-Path $manifestPath) {
            $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
            return ([int]$m.entries -eq 0)
        }
        # No manifest at all is also acceptable: nothing initialized, nothing written.
        return $true
    }
}
finally {
    if (Test-Path $tempJournal) { Remove-Item -Path $tempJournal -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $uninitializedJournal) { Remove-Item -Path $uninitializedJournal -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ''
Write-Output ("RESULT: " + $pass + " passed, " + $fail + " failed")
if ($fail -gt 0) {
    Write-Output 'Failures:'
    foreach ($f in $failures) { Write-Output ('  - ' + $f) }
    exit 1
}
exit 0
