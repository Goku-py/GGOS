#Requires -Version 5.1
<#
    Test-NxJournal.ps1 - NxCore journal self-test.

    SAFETY: this test writes ONLY to a throwaway temp directory and reads only
    registry values (read-only capture). It never modifies any Windows
    configuration. It proves: manifest lifecycle, capture-refusal (stacking
    detection), entry chain integrity, tamper detection, and only-if-ours
    comparison semantics.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\src\nxcore'
foreach ($m in 'NxJournal.ps1','NxBuild.ps1','NxVerify.ps1') { . (Join-Path $root $m) }

$pass = 0; $fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("nx-journal-selftest-" + [guid]::NewGuid().ToString('N'))
try {
    # 1. Fresh init arms the journal.
    $j1 = Initialize-NxJournal -Path $tmp
    Assert-Nx 'fresh initialize creates journal' ($j1.created -eq $true)

    # 2. Capture-refusal: second init must refuse (stacking detection).
    $j2 = Initialize-NxJournal -Path $tmp
    Assert-Nx 'capture-refusal on existing journal' ($j2.created -eq $false -and $j2.reason -eq 'CAPTURE_REFUSAL_EXISTING_JOURNAL')

    # 3. Read-only capture of a real, guaranteed-present value.
    $cap = Capture-NxRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'ProductName'
    Assert-Nx 'registry capture reads live value' ($cap.existed -eq $true -and $cap.keyExisted -eq $true -and $cap.kind -eq 'String')

    # 4. Journal two entries.
    $modified = [pscustomobject]@{ targetType='registry'; path=$cap.path; name=$cap.name; kind='String'; value='NEXTRIX-selftest' }
    $null = Add-NxJournalEntry -Path $tmp -TweakId 'NX16-999' -TweakVersion '1' -Operation 'apply' -Approval 'SelfTest' -Original $cap -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles @('P9')
    $null = Add-NxJournalEntry -Path $tmp -TweakId 'NX16-998' -TweakVersion '1' -Operation 'verify' -Approval 'SelfTest' -Original $cap -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles @('P9')

    # 5. Read back: chain intact.
    $rd = Read-NxJournal -Path $tmp
    Assert-Nx 'journal read returns 2 entries' ($rd.entries.Count -eq 2)
    Assert-Nx 'integrity chain verifies clean journal' ($rd.integrityErrors.Count -eq 0)
    Assert-Nx 'entry carries profile tag' (@($rd.entries[0].profiles) -contains 'P9')

    # 6. Tamper detection: corrupt the first journal line, chain must break.
    $entriesPath = Join-Path $tmp 'journal.jsonl'
    $lines = @(Get-Content $entriesPath -Encoding UTF8)
    $lines[0] = $lines[0] -replace '"seq":1', '"seq":9'   # falsify seq on entry 1
    Set-Content -Path $entriesPath -Value $lines -Encoding UTF8
    $rd2 = Read-NxJournal -Path $tmp
    Assert-Nx 'tampered journal is detected' ($rd2.integrityErrors.Count -gt 0)

    # 7. Only-if-ours semantics.
    $same   = Test-NxCurrentEqualsDescriptor -Descriptor $cap -Kind 'String' -Value $cap.value
    $diff   = Test-NxCurrentEqualsDescriptor -Descriptor $cap -Kind 'String' -Value 'something-else'
    $wrongK = Test-NxCurrentEqualsDescriptor -Descriptor $cap -Kind 'DWord' -Value $cap.value
    Assert-Nx 'only-if-ours: matching state accepted' ($same -eq $true)
    Assert-Nx 'only-if-ours: different value rejected' ($diff -eq $false)
    Assert-Nx 'only-if-ours: wrong kind rejected' ($wrongK -eq $false)

    # 8. Manifest restore marker re-arms capture.
    Complete-NxJournalRestore -Path $tmp
    $m = Read-NxManifest -Path $tmp
    Assert-Nx 'restore marker recorded' ($null -ne $m.manifest.restoredVerifiedUtc)
}
finally {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
}
Write-Output ("SELFTEST RESULT: pass=$pass fail=$fail")
if ($fail -gt 0) { exit 1 } else { exit 0 }
