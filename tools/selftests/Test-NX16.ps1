#Requires -Version 5.1
<#
    Test-NX16.ps1 - NX16 (Maintenance & Recovery) category self-test.

    SAFETY BOUNDARY (directive Section 16): this test writes ONLY to throwaway temp
    directories. Windows is touched only through READ-ONLY queries: registry capture /
    reg.exe export (read), Get-Service, Get-ScheduledTask/Export-ScheduledTask, and
    DISM /CheckHealth (documented instant read-only). This test NEVER:
      - creates a restore point or enables System Restore (Checkpoint/Enable run -Plan only)
      - runs DISM ScanHealth / RestoreHealth (only CheckHealth)
      - runs sfc at all
      - deletes driver packages (Invoke-NxDriverStoreClean is not invoked)
      - changes any Windows configuration.

    Covers what is testable without mutation: backup-set creation into a temp
    -DestinationPath, the 24h throttle-keep decision on mocked restore-point sequences,
    the identifier scrubber on sample text, pre-flight capture gating, and the
    plan-mode contracts (no journal, no mutation).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\..\src\nxcore'
foreach ($m in 'NxJournal.ps1', 'NxBuild.ps1', 'NxVerify.ps1', 'NxHardware.ps1', 'NxRollback.ps1') {
    . (Join-Path $root $m)
}
. (Join-Path $root 'functions\NX16.ps1')

$script:pass = 0
$script:fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('nx16-selftest-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $tmpRoot -ItemType Directory -Force | Out-Null

try {
    # ------------------------------------------------------------------------
    # 0. Module surface: all 12 NX16 engine functions defined after dot-source.
    # ------------------------------------------------------------------------
    $publicFns = @(
        'Enable-NxSystemRestore', 'Checkpoint-NxSystem', 'Export-NxRegistryTargets',
        'Export-NxServiceState', 'Export-NxTaskState', 'Invoke-NxPreFlight',
        'Invoke-NxDismHealth', 'Invoke-NxSfcVerify', 'Invoke-NxComponentCleanup',
        'Get-NxDriverInventory', 'Invoke-NxDriverStoreClean', 'Export-NxSupportBundle'
    )
    $missingFns = @($publicFns | Where-Object { $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    Assert-Nx 'all 12 NX16 engine functions are defined' ($missingFns.Count -eq 0) ($missingFns -join ',')

    # ------------------------------------------------------------------------
    # A. Export-NxRegistryTargets - backup set creation into temp, dedupe,
    #    index manifest, honest Skipped for absent keys.
    # ------------------------------------------------------------------------
    $regDest = Join-Path $tmpRoot 'regbackup'
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion',
        'HKLM:\SOFTWARE\NexTrixSelfTest\DefinitelyAbsent'
    )
    $rA = Export-NxRegistryTargets -Paths $paths -DestinationPath $regDest
    Assert-Nx 'registry export: two .reg files created' (@(Get-ChildItem $regDest -Filter '*.reg' -File).Count -eq 2)
    Assert-Nx 'registry export: index manifest exists' (Test-Path (Join-Path $regDest 'registry-index.json'))
    $idxA = Get-Content (Join-Path $regDest 'registry-index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Nx 'registry export: dedupe (requested 4, distinct 3)' ($idxA.requestedCount -eq 4 -and $idxA.distinctCount -eq 3)
    Assert-Nx 'registry export: both existing keys exported+validated' (@($rA.entries | Where-Object { $_.result -eq 'Exported' -and $_.validated -eq $true }).Count -eq 2)
    Assert-Nx 'registry export: absent key honestly Skipped' (@($rA.entries | Where-Object { $_.result -eq 'Skipped' -and $_.path -like '*DefinitelyAbsent' }).Count -eq 1)
    Assert-Nx 'registry export: allSucceeded (skips are not failures)' ($rA.allSucceeded -eq $true -and $rA.failedCount -eq 0)
    $firstReg = @($rA.entries | Where-Object { $_.result -eq 'Exported' })[0]
    Assert-Nx 'registry export: .reg header validated' ($null -ne (Read-NxRegFileHeader -Path $firstReg.file))

    # ------------------------------------------------------------------------
    # B. Export-NxServiceState - baseline + Start-only .reg + first-backup-kept.
    # ------------------------------------------------------------------------
    $svcDest = Join-Path $tmpRoot 'svcbackup'
    $svcNames = @('Themes', 'W32Time', 'NxMissingService-12345')
    $rB = Export-NxServiceState -Services $svcNames -DestinationPath $svcDest
    $blB = Get-Content (Join-Path $svcDest 'services-baseline.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Nx 'service baseline: enumerates all 3 names' (@($blB.entries).Count -eq 3)
    Assert-Nx 'service baseline: present services have registry Start' (@($blB.entries | Where-Object { $_.present -and $_.registryStart.existed }).Count -eq 2)
    Assert-Nx 'service baseline: missing service recorded Missing' (@($blB.entries | Where-Object { $_.result -eq 'Missing' }).Count -eq 1)
    $regSections = @(@(Get-Content $rB.regFile -Encoding Unicode) | Where-Object { $_.StartsWith('[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\') }).Count
    Assert-Nx 'service baseline: .reg validated with 2 Start sections' ($rB.regValidated -eq $true -and $regSections -eq 2)
    $origHash = (Get-FileHash $rB.regFile -Algorithm SHA256).Hash
    $rB2 = Export-NxServiceState -Services $svcNames -DestinationPath $svcDest
    Assert-Nx 'service baseline: first backup never overwritten (new file name)' ($rB2.regFile -ne $rB.regFile -and (Test-Path $rB.regFile) -and (Test-Path $rB2.regFile))
    Assert-Nx 'service baseline: original file content unchanged' ((Get-FileHash $rB.regFile -Algorithm SHA256).Hash -eq $origHash)

    # ------------------------------------------------------------------------
    # C. Export-NxTaskState - real task XML export + honest Missing.
    # ------------------------------------------------------------------------
    $taskDest = Join-Path $tmpRoot 'taskbackup'
    $tasksC = @(
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Defrag\'; TaskName = 'ScheduledDefrag' },
        [pscustomobject]@{ TaskPath = '\NexTrixSelfTest\'; TaskName = 'DoesNotExist' }
    )
    $rC = Export-NxTaskState -Tasks $tasksC -DestinationPath $taskDest
    $taskCmds = ($null -ne (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) -and ($null -ne (Get-Command Export-ScheduledTask -ErrorAction SilentlyContinue))
    if ($taskCmds) {
        $xmlEntry = @($rC.entries | Where-Object { $_.taskName -eq 'ScheduledDefrag' })[0]
        Assert-Nx 'task backup: xml exported + validated' ($xmlEntry.result -eq 'Exported' -and $xmlEntry.validated -eq $true -and (Test-Path $xmlEntry.file))
        Assert-Nx 'task backup: state recorded' (-not [string]::IsNullOrWhiteSpace($xmlEntry.state))
        Assert-Nx 'task backup: missing task honestly Missing' (@($rC.entries | Where-Object { $_.taskName -eq 'DoesNotExist' -and $_.result -eq 'Missing' }).Count -eq 1)
    } else {
        Assert-Nx 'task backup: honest CmdletUnavailable without ScheduledTasks' (@($rC.entries | Where-Object { $_.result -eq 'CmdletUnavailable' }).Count -eq 2)
    }

    # ------------------------------------------------------------------------
    # D. Convert-NxToDateTime - WMI DMTF / passthrough / honest null.
    # ------------------------------------------------------------------------
    $dt = Convert-NxToDateTime '20261123101530.000000+060'
    Assert-Nx 'datetime: WMI DMTF string parses' ($null -ne $dt -and $dt.Year -eq 2026 -and $dt.Month -eq 11 -and $dt.Day -eq 23)
    Assert-Nx 'datetime: garbage returns null (never guessed)' ($null -eq (Convert-NxToDateTime 'not-a-date'))
    Assert-Nx 'datetime: DateTime passthrough' ((Convert-NxToDateTime ([datetime]'2026-01-02')).Day -eq 2)

    # ------------------------------------------------------------------------
    # E. Find-NxProtectingRestorePoint - the 24h throttle-keep decision on
    #    MOCKED sequences (pure function; no restore point is created/read).
    # ------------------------------------------------------------------------
    $now = [datetime]'2026-11-23 12:00:00'
    $mkPoint = { param($seq, $hours, $desc) [pscustomobject]@{ SequenceNumber = $seq; CreationTime = $now.AddHours($hours); Description = $desc } }
    $p2h = & $mkPoint 5 -2 'two hours old'
    $p30h = & $mkPoint 4 -30 'thirty hours old'
    $e1 = Find-NxProtectingRestorePoint -Points @($p2h) -WithinHours 24 -AsOf $now
    Assert-Nx 'throttle: point newer than 24h protects' ($null -ne $e1.point -and $e1.point.SequenceNumber -eq 5)
    $e2 = Find-NxProtectingRestorePoint -Points @($p30h) -WithinHours 24 -AsOf $now
    Assert-Nx 'throttle: point older than 24h does not protect' ($null -eq $e2.point)
    $newer = & $mkPoint 7 -1 'one hour old'
    $e3 = Find-NxProtectingRestorePoint -Points @($p2h, $p30h, $newer) -WithinHours 24 -AsOf $now
    Assert-Nx 'throttle: newest protecting point returned' ($null -ne $e3.point -and $e3.point.SequenceNumber -eq 7)
    $e4 = Find-NxProtectingRestorePoint -Points @([pscustomobject]@{ SequenceNumber = 1; CreationTime = 'garbage'; Description = 'x' }) -WithinHours 24 -AsOf $now
    Assert-Nx 'throttle: unparseable point skipped, no false protection' ($null -eq $e4.point -and $e4.unparseableCount -eq 1)
    $future = & $mkPoint 9 2 'clock-skew future point'
    $e5 = Find-NxProtectingRestorePoint -Points @($future) -WithinHours 24 -AsOf $now
    Assert-Nx 'throttle: future-dated point still protects (clock skew)' ($null -ne $e5.point -and $e5.point.SequenceNumber -eq 9)
    $e6 = Find-NxProtectingRestorePoint -Points @() -WithinHours 24 -AsOf $now
    Assert-Nx 'throttle: empty sequence protects nothing' ($null -eq $e6.point)

    # ------------------------------------------------------------------------
    # F. Checkpoint-NxSystem -Plan: intent only, no journal, frequency untouched.
    # ------------------------------------------------------------------------
    $jrnF = Join-Path $tmpRoot 'journal-f'
    $freqPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\SystemRestore'
    $freqName = 'SystemRestorePointCreationFrequency'
    $freqBefore = Capture-NxRegistryValue -Path $freqPath -Name $freqName
    $rF = Checkpoint-NxSystem -JournalPath $jrnF -Plan
    $freqAfter = Capture-NxRegistryValue -Path $freqPath -Name $freqName
    Assert-Nx 'checkpoint plan: outcome Planned, allSucceeded' ($rF.plan -eq $true -and $rF.outcome -eq 'Planned' -and $rF.allSucceeded -eq $true)
    Assert-Nx 'checkpoint plan: frequency value untouched' ((ConvertTo-Json $freqBefore -Compress) -eq (ConvertTo-Json $freqAfter -Compress))
    Assert-Nx 'checkpoint plan: no journal created (plan never journals)' (-not (Test-Path (Join-Path $jrnF 'manifest.json')))
    Assert-Nx 'checkpoint plan: restore point step planned' (@($rF.steps | Where-Object { $_.name -eq 'restore-point' -and $_.outcome -eq 'Planned' -and $_.detail -match 'NEXTRIX pre-apply' }).Count -eq 1)

    # ------------------------------------------------------------------------
    # G. Enable-NxSystemRestore -Plan: both policy values listed, no journal.
    # ------------------------------------------------------------------------
    $jrnG = Join-Path $tmpRoot 'journal-g'
    $rG = Enable-NxSystemRestore -JournalPath $jrnG -Plan
    Assert-Nx 'restore plan: both policy values listed' (@($rG.steps | Where-Object { $_.name -eq 'policy-DisableSR' }).Count -eq 1 -and @($rG.steps | Where-Object { $_.name -eq 'policy-DisableConfig' }).Count -eq 1)
    Assert-Nx 'restore plan: enable-protection step present' (@($rG.steps | Where-Object { $_.name -eq 'enable-protection' }).Count -eq 1)
    Assert-Nx 'restore plan: frequency explicitly not touched' ($rG.frequencyNotTouchedByThisFunction -eq $true)
    Assert-Nx 'restore plan: no journal created' (-not (Test-Path (Join-Path $jrnG 'manifest.json')))

    # ------------------------------------------------------------------------
    # H. Invoke-NxPreFlight - the capture gate (temp journal + temp backups).
    # ------------------------------------------------------------------------
    $jrnH = Join-Path $tmpRoot 'journal-h'
    $bkpH = Join-Path $tmpRoot 'preflight-backups'
    $rH = Invoke-NxPreFlight -JournalRoot $jrnH -BackupRoot $bkpH `
        -RegistryPaths @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion', 'HKLM:\SOFTWARE\NexTrixSelfTest\DefinitelyAbsent') `
        -ServiceNames @('Themes') `
        -Tasks @([pscustomobject]@{ TaskPath = '\Microsoft\Windows\Defrag\'; TaskName = 'ScheduledDefrag' })
    Assert-Nx 'preflight: allComplete on first run' ($rH.allComplete -eq $true)
    Assert-Nx 'preflight: no Failed steps on first run' (@($rH.steps | Where-Object { $_.outcome -eq 'Failed' }).Count -eq 0)
    Assert-Nx 'preflight: hardware.json + build.json written' ((Test-Path (Join-Path $rH.backupSetPath 'hardware.json')) -and (Test-Path (Join-Path $rH.backupSetPath 'build.json')))
    Assert-Nx 'preflight: backup artifacts share one set' ((Test-Path (Join-Path $rH.backupSetPath 'registry-index.json')) -and (Test-Path (Join-Path $rH.backupSetPath 'services-baseline.json')) -and (Test-Path (Join-Path $rH.backupSetPath 'tasks-baseline.json')))
    Assert-Nx 'preflight: journal armed at temp root' (Test-Path (Join-Path $jrnH 'manifest.json'))
    $rH2 = Invoke-NxPreFlight -JournalRoot $jrnH -BackupRoot $bkpH
    $jiStep = @($rH2.steps | Where-Object { $_.name -eq 'journal-init' })[0]
    Assert-Nx 'preflight: existing journal is reused on second run (upgrade-safe)' ($jiStep.outcome -eq 'Complete' -and $jiStep.detail -match 'reused')
    Assert-Nx 'preflight: gate open on reuse (allComplete true, journalReused flagged)' ($rH2.allComplete -eq $true -and $rH2.journalReused -eq $true)

    # ------------------------------------------------------------------------
    # I. Invoke-NxComponentCleanup - plan by default, never /ResetBase.
    # ------------------------------------------------------------------------
    $rI = Invoke-NxComponentCleanup
    Assert-Nx 'component cleanup: plan by default (nothing executed)' ($rI.executed -eq $false)
    Assert-Nx 'component cleanup: policy never /ResetBase' ($rI.policyNeverResetBase -eq $true -and $rI.policyNote -match 'ResetBase')
    Assert-Nx 'component cleanup: exact command planned' (@($rI.plannedCommands | Where-Object { $_ -match 'StartComponentCleanup' }).Count -eq 1)
    Assert-Nx 'component cleanup: honest irreversibility labeling' (-not [string]::IsNullOrWhiteSpace($rI.irreversibilityNote))

    # ------------------------------------------------------------------------
    # J. Invoke-NxDismHealth -Mode Check (instant, READ-ONLY).
    # ------------------------------------------------------------------------
    $rJ = Invoke-NxDismHealth -Mode 'Check'
    if (Test-Path (Join-Path $env:SystemRoot 'System32\dism.exe')) {
        Assert-Nx 'DISM check: single CheckHealth step' (@($rJ.steps | Where-Object { $_.name -eq 'CheckHealth' }).Count -eq 1)
        Assert-Nx 'DISM check: exit code recorded' ($rJ.steps.Count -gt 0 -and $null -ne $rJ.steps[0].exitCode)
        Assert-Nx 'DISM check: verdict is an honest enum value' (@('Healthy', 'Repairable', 'Corrupt', 'Uncertain') -contains $rJ.overallVerdict)
    } else {
        Assert-Nx 'DISM check: honest Uncertain report when dism.exe absent' ($rJ.overallVerdict -eq 'Uncertain' -and @($rJ.uncertainty).Count -gt 0)
    }

    # ------------------------------------------------------------------------
    # K. Remove-NxMachineIdentifiers - scrubber on sample text.
    # ------------------------------------------------------------------------
    $sample = 'Server: DESKTOP-XYZ987 | user DOMAIN\john | SID S-1-5-21-111-222-333-1001 | MAC: aa-bb-cc-dd-ee-ff | Serial Number: OTHERSER99 | Windows 11 Pro build 26100'
    $scrub = Remove-NxMachineIdentifiers -Text $sample -ComputerNames @('DESKTOP-XYZ987') -UserNames @('DOMAIN\john')
    Assert-Nx 'scrub: computer name redacted' ((-not $scrub.text.Contains('DESKTOP-XYZ987')) -and $scrub.text.Contains('COMPUTERNAME-REDACTED'))
    Assert-Nx 'scrub: user name redacted' ((-not $scrub.text.Contains('DOMAIN\john')) -and $scrub.text.Contains('USERNAME-REDACTED'))
    Assert-Nx 'scrub: SID redacted' ((-not $scrub.text.Contains('S-1-5-21-111-222-333-1001')) -and $scrub.text.Contains('SID-REDACTED'))
    Assert-Nx 'scrub: MAC redacted' ((-not $scrub.text.ToLower().Contains('aa-bb-cc-dd-ee-ff')) -and $scrub.text.Contains('MAC-REDACTED'))
    Assert-Nx 'scrub: serial-labeled value redacted' ((-not $scrub.text.Contains('OTHERSER99')) -and $scrub.text.Contains('REDACTED'))
    Assert-Nx 'scrub: benign text preserved' ($scrub.text.Contains('Windows 11 Pro') -and $scrub.text.Contains('26100'))
    Assert-Nx 'scrub: redaction records reported' (@($scrub.redactions).Count -ge 4)
    $uuidScrub = Remove-NxMachineIdentifiers -Text '{"uuid": "5f2a9c1e-0000-4b1d-9e2f-a1b2c3d4e5f6"}'
    Assert-Nx 'scrub: uuid JSON label redacted' (-not $uuidScrub.text.Contains('5f2a9c1e-0000-4b1d-9e2f-a1b2c3d4e5f6'))

    # ------------------------------------------------------------------------
    # L. Export-NxSupportBundle - temp zip; journal summary keeps ids/timestamps/
    #    results only; no state values; machine name scrubbed from all text.
    # ------------------------------------------------------------------------
    $jrnL = Join-Path $tmpRoot 'journal-l'
    $null = Initialize-NxJournal -Path $jrnL
    $capL = Capture-NxRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'ProductName'
    $modL = [pscustomobject]@{ targetType = 'registry'; path = $capL.path; name = $capL.name; kind = 'String'; value = 'NxSecretMarker-8841-DoNotLeak' }
    $null = Add-NxJournalEntry -Path $jrnL -TweakId 'NX16-999' -TweakVersion '1' -Operation 'apply' -Approval 'SelfTest' -Original $capL -Modified $modL -Result 'Success' -Verification 'Verified' -Profiles @('P9')
    $zipPath = Join-Path $tmpRoot 'bundle\support.zip'
    New-Item -Path (Split-Path $zipPath -Parent) -ItemType Directory -Force | Out-Null
    $rL = Export-NxSupportBundle -DestinationPath $zipPath -JournalRoot $jrnL
    Assert-Nx 'bundle: zip created + allSucceeded' ($rL.allSucceeded -eq $true -and (Test-Path $rL.bundlePath))
    $expL = Join-Path $tmpRoot 'bundle-expanded'
    Expand-Archive -LiteralPath $rL.bundlePath -DestinationPath $expL -Force
    Assert-Nx 'bundle: core files present' ((Test-Path (Join-Path $expL 'hardware.json')) -and (Test-Path (Join-Path $expL 'build.json')) -and (Test-Path (Join-Path $expL 'journal-summary.json')) -and (Test-Path (Join-Path $expL 'README.txt')))
    $sumL = Get-Content (Join-Path $expL 'journal-summary.json') -Raw -Encoding UTF8
    Assert-Nx 'bundle: journal summary keeps ids/timestamps/results' ($sumL.Contains('NX16-999') -and $sumL.Contains('SelfTest') -and $sumL.Contains('Success'))
    Assert-Nx 'bundle: journal values excluded (secret marker absent)' (-not $sumL.Contains('NxSecretMarker-8841-DoNotLeak'))
    $allText = (@(Get-ChildItem $expL -File | ForEach-Object { Get-Content $_.FullName -Raw -Encoding UTF8 }) -join "`n")
    Assert-Nx 'bundle: no journal state values anywhere in the archive' (-not $allText.Contains('NxSecretMarker-8841-DoNotLeak'))
    if ($env:COMPUTERNAME) {
        Assert-Nx 'bundle: machine name scrubbed from all text' (-not $allText.Contains($env:COMPUTERNAME))
    }
    Assert-Nx 'bundle: nothing-uploaded flag + redaction summary field present' ($rL.nothingUploaded -eq $true -and $null -ne $rL.redactionSummary)
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ("SELFTEST RESULT: pass=$script:pass fail=$script:fail")
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
