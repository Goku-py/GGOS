#Requires -Version 5.1
<#
    Test-NX14.ps1 - NX14 Security Configuration self-test.

    SAFETY (directive Section 16 / SECURITY_POLICY.md Section 5; workstream rule
    "never apply/test-run security changes, read-only security queries only"):
    This test NEVER changes a security setting. It exercises only:
      1. the pure maps and the banned-target guard (no Windows state),
      2. read-only report functions against this machine,
      3. the approval gate: every mutating function must throw BEFORE any
         mutation when -Approved is absent,
      4. -WhatIf planning with a throwaway temp journal (no journal write, no
         registry/preference/feature change),
      5. the banned-target guard inside the journal-first pipeline (must throw
         before the journal write),
      6. journal round-trip mechanics in the temp directory,
      7. JSON <-> function signature consistency and policy invariants
         (ADVANCED entries preset-excluded + ExplicitConsent; no insecure
         values in the maps or the registry).

    Exit code: 0 = all assertions pass, 1 = at least one failure.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\..'
. (Join-Path $root 'src\nxcore\NxJournal.ps1')
. (Join-Path $root 'src\nxcore\NxBuild.ps1')
. (Join-Path $root 'src\nxcore\NxVerify.ps1')
. (Join-Path $root 'src\nxcore\NxApply.ps1')
. (Join-Path $root 'src\nxcore\NxRollback.ps1')
. (Join-Path $root 'src\nxcore\functions\NX14.ps1')

$pass = 0; $fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('nextrix-nx14-selftest-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $temp -ItemType Directory -Force | Out-Null
try {
    $journal = Join-Path $temp 'journal'
    $init = Initialize-NxJournal -Path $journal
    Assert-Nx 'temp journal initialised' ($init.created -eq $true) (ConvertTo-Json $init -Compress)

    # -----------------------------------------------------------------------
    # 1. Pure maps: no insecure value is representable
    # -----------------------------------------------------------------------
    $uac = Get-Nx14UacLevelMap
    Assert-Nx 'UAC map has exactly 3 documented levels' (@($uac).Count -eq 3)
    Assert-Nx 'UAC map always keeps EnableLUA=1' (@($uac | Where-Object { [int]$_.enableLua -ne 1 }).Count -eq 0)
    Assert-Nx 'UAC map always keeps the secure desktop on' (@($uac | Where-Object { [int]$_.promptOnSecureDesktop -ne 1 }).Count -eq 0)
    Assert-Nx 'UAC map never emits 0/3/4 consent values' (@($uac | Where-Object { @(0,3,4) -contains [int]$_.consentPromptBehaviorAdmin }).Count -eq 0)
    Assert-Nx 'UAC map consent values are documented 1/2/5' (@($uac | Where-Object { @(1,2,5) -notcontains [int]$_.consentPromptBehaviorAdmin }).Count -eq 0)

    $ss = Get-Nx14SmartScreenLevelMap
    Assert-Nx 'SmartScreen map has 2 documented levels' (@($ss).Count -eq 2)
    Assert-Nx 'SmartScreen map never turns the policy off' (@($ss | Where-Object { [int]$_.enableSmartScreen -ne 1 }).Count -eq 0)
    Assert-Nx 'SmartScreen map levels are Warn/Block only' (@($ss | Where-Object { @('Warn','Block') -notcontains [string]$_.shellSmartScreenLevel }).Count -eq 0)

    $cfa = Get-Nx14CfaModeMap
    Assert-Nx 'CFA map has Enabled + Audit' (@($cfa).Count -eq 2)
    Assert-Nx 'CFA map never offers mode 0 (off)' (@($cfa | Where-Object { [int]$_.value -eq 0 }).Count -eq 0)
    Assert-Nx 'CFA map values are 1/2' (@($cfa | Where-Object { @(1,2) -notcontains [int]$_.value }).Count -eq 0)

    $mit = Get-Nx14MitigationAllowList
    Assert-Nx 'mitigation allow-list is non-empty' (@($mit).Count -ge 6)
    Assert-Nx 'mitigation allow-list has unique names' (@($mit | Group-Object name | Where-Object { $_.Count -gt 1 }).Count -eq 0)
    Assert-Nx 'mitigation allow-list has no wildcard/free-form entries' (@($mit | Where-Object { $_.name -match '[\*\?]' }).Count -eq 0)

    # -----------------------------------------------------------------------
    # 2. Banned-target guard (schema mirror, stricter for NX14)
    # -----------------------------------------------------------------------
    $uacPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Assert-Nx 'guard bans EnableLUA=0' ((Test-Nx14BannedRegistryTarget -Path $uacPath -Name 'EnableLUA' -Value 0).banned -eq $true)
    Assert-Nx 'guard permits EnableLUA=1' ((Test-Nx14BannedRegistryTarget -Path $uacPath -Name 'EnableLUA' -Value 1).banned -eq $false)
    Assert-Nx 'guard bans direct ControlSet001 writes' ((Test-Nx14BannedRegistryTarget -Path 'HKLM:\SYSTEM\ControlSet001\Control\BitLocker' -Name 'Anything' -Value 1).banned -eq $true)
    Assert-Nx 'guard bans HVCI Enabled=0 unconditionally' ((Test-Nx14BannedRegistryTarget -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -Value 0).banned -eq $true)
    Assert-Nx 'guard permits HVCI Enabled=1' ((Test-Nx14BannedRegistryTarget -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -Value 1).banned -eq $false)
    Assert-Nx 'guard bans mitigation mask writes' ((Test-Nx14BannedRegistryTarget -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' -Name 'MitigationOptions' -Value '22222222').banned -eq $true)
    Assert-Nx 'guard bans FeatureSettingsOverride writes' ((Test-Nx14BannedRegistryTarget -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'FeatureSettingsOverride' -Value 3).banned -eq $true)
    Assert-Nx 'guard bans SaveZoneInformation=1' ((Test-Nx14BannedRegistryTarget -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' -Name 'SaveZoneInformation' -Value 1).banned -eq $true)
    Assert-Nx 'guard bans SmartScreenEnabled=Off' ((Test-Nx14BannedRegistryTarget -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name 'SmartScreenEnabled' -Value 'Off').banned -eq $true)
    Assert-Nx 'guard permits SmartScreenEnabled=Warn' ((Test-Nx14BannedRegistryTarget -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name 'SmartScreenEnabled' -Value 'Warn').banned -eq $false)
    Assert-Nx 'guard bans VulnerableDriverBlocklistEnable=0' ((Test-Nx14BannedRegistryTarget -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' -Name 'VulnerableDriverBlocklistEnable' -Value 0).banned -eq $true)
    Assert-Nx 'guard bans PreventDeviceEncryption=1' ((Test-Nx14BannedRegistryTarget -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' -Name 'PreventDeviceEncryption' -Value 1).banned -eq $true)

    # -----------------------------------------------------------------------
    # 3. Read-only reports against this machine
    # -----------------------------------------------------------------------
    $beforeEntries = (Read-NxJournal -Path $journal).entries.Count
    $reports = @{}
    foreach ($name in @(
        'Get-Nx14DefenderStatusReport','Get-Nx14FirewallStatusReport','Get-Nx14SecureBootStatus',
        'Get-Nx14TpmStatus','Get-Nx14DeviceGuardStatus','Get-Nx14MemoryIntegrityStatus',
        'Get-Nx14CredentialGuardStatus','Get-Nx14ControlledFolderAccessStatus',
        'Get-Nx14ExploitProtectionReport','Get-Nx14BitLockerStatus',
        'Get-Nx14WindowsSandboxStatus','Get-Nx14VirtualizationPlatformStatus'
    )) {
        try {
            $reports[$name] = & $name
            Assert-Nx "$name runs read-only" ($null -ne $reports[$name] -and $reports[$name].readOnly -eq $true)
            Assert-Nx "$name exposes an uncertainty array" ($null -ne $reports[$name].uncertainty -and $reports[$name].uncertainty -is [array])
        } catch {
            Assert-Nx "$name runs read-only" $false $_.Exception.Message
        }
    }
    $afterEntries = (Read-NxJournal -Path $journal).entries.Count
    Assert-Nx 'no report function writes a journal entry' ($afterEntries -eq $beforeEntries) "before=$beforeEntries after=$afterEntries"

    $agg = Get-Nx14SecurityHealthReport
    Assert-Nx 'aggregate report is read-only' ($agg.readOnly -eq $true)
    Assert-Nx 'aggregate report has at least 10 areas' (@($agg.areas).Count -ge 10)
    Assert-Nx 'aggregate report produces no security score' ($null -eq $agg.securityRating)
    Assert-Nx 'aggregate report declares exclusions' (@($agg.exclusions).Count -ge 3)
    Assert-Nx 'aggregate report statement never claims performance' (-not ([string](@($agg.notes) -join ' ') -match '(?i)faster|\bfps\b|lower latency|smoother'))
    Assert-Nx 'aggregate report does not silently include Sandbox/virtualization' (@($agg.coverage | Where-Object { $_ -match 'Sandbox|virtualization' }).Count -eq 0)

    # -----------------------------------------------------------------------
    # 4. Approval gates (throw before any mutation path is reached)
    # -----------------------------------------------------------------------
    $throwCases = @(
        @{ name = 'Set-Nx14UacLevel';            script = { Set-Nx14UacLevel -JournalRoot (Join-Path $temp 'no-journal') -Level Default } }
        @{ name = 'Set-Nx14SmartScreen';        script = { Set-Nx14SmartScreen -JournalRoot (Join-Path $temp 'no-journal') -Level Warn } }
        @{ name = 'Set-Nx14MemoryIntegrity';    script = { Set-Nx14MemoryIntegrity -JournalRoot (Join-Path $temp 'no-journal') -Mode Enable -DriverCompatibilityReviewed } }
        @{ name = 'Set-Nx14ControlledFolderAccess'; script = { Set-Nx14ControlledFolderAccess -JournalRoot (Join-Path $temp 'no-journal') -Mode Enabled } }
        @{ name = 'Set-Nx14MitigationPolicy';   script = { Set-Nx14MitigationPolicy -JournalRoot (Join-Path $temp 'no-journal') -ProcessName 'notepad.exe' -Mitigations @('CFG') } }
        @{ name = 'Set-Nx14WindowsSandbox';     script = { Set-Nx14WindowsSandbox -JournalRoot (Join-Path $temp 'no-journal') -State Enabled } }
        @{ name = 'Set-Nx14VirtualizationPlatform'; script = { Set-Nx14VirtualizationPlatform -JournalRoot (Join-Path $temp 'no-journal') -Component HyperV -State Enabled } }
    )
    foreach ($case in $throwCases) {
        $threw = $false
        try { & $case.script | Out-Null } catch { $threw = $true }
        Assert-Nx "$($case.name) refuses without -Approved" $threw
    }
    Assert-Nx 'refusal cases created no journal directory' (-not (Test-Path (Join-Path $temp 'no-journal')))

    # -----------------------------------------------------------------------
    # 5. -WhatIf leaves no trace (no journal entry, no mutation)
    # -----------------------------------------------------------------------
    $before = (Read-NxJournal -Path $journal).entries.Count
    $uacPlan = Set-Nx14UacLevel -JournalRoot $journal -Level Default -WhatIf
    $ssPlan = Set-Nx14SmartScreen -JournalRoot $journal -Level Warn -WhatIf
    $cfaPlan = Set-Nx14ControlledFolderAccess -JournalRoot $journal -Mode Enabled -WhatIf
    $hvciPlan = Set-Nx14MemoryIntegrity -JournalRoot $journal -Mode Enable -WhatIf
    $sbPlan = Set-Nx14WindowsSandbox -JournalRoot $journal -State Enabled -WhatIf
    $virtPlan = Set-Nx14VirtualizationPlatform -JournalRoot $journal -Component VirtualMachinePlatform -State Enabled -WhatIf
    $pmPlan = Set-Nx14MitigationPolicy -JournalRoot $journal -ProcessName 'notepad.exe' -Mitigations @('CFG') -WhatIf
    $after = (Read-NxJournal -Path $journal).entries.Count
    Assert-Nx 'all -WhatIf plans write no journal entry' ($after -eq $before) "before=$before after=$after"
    Assert-Nx 'UAC -WhatIf reports a plan, not a change' ($uacPlan.planned -eq $true -and $uacPlan.changed -eq $false)
    Assert-Nx 'SmartScreen -WhatIf reports a plan' ($ssPlan.planned -eq $true)
    Assert-Nx 'CFA -WhatIf reports a plan or an explicit unavailable reason' ($cfaPlan.planned -eq $true)
    Assert-Nx 'Memory Integrity -WhatIf reports blockers instead of throwing' ($hvciPlan.planned -eq $true -and $null -ne $hvciPlan.blockers)
    Assert-Nx 'Memory Integrity -WhatIf requires the driver review in the plan' (@($hvciPlan.blockers | Where-Object { $_ -match 'DriverCompatibilityReviewed' }).Count -ge 1)
    Assert-Nx 'Sandbox -WhatIf reports a plan' ($sbPlan.planned -eq $true)
    Assert-Nx 'Virtualization -WhatIf reports a plan and dependency warnings' ($virtPlan.planned -eq $true -and @($virtPlan.dependencyWarnings).Count -ge 3)
    Assert-Nx 'Mitigation -WhatIf reports a plan' ($pmPlan.planned -eq $true)

    # -----------------------------------------------------------------------
    # 6. Journal-first guard: a banned write throws BEFORE the journal write
    # -----------------------------------------------------------------------
    $before = (Read-NxJournal -Path $journal).entries.Count
    $guardThrew = $false
    try {
        Invoke-Nx14RegistryTarget -JournalRoot $journal -TweakId 'NX14-SELFTEST' -Approval 'SelfTest' -Path $uacPath -Name 'EnableLUA' -Kind DWord -Value 0 -Confirm:$false | Out-Null
    } catch { $guardThrew = $true }
    $after = (Read-NxJournal -Path $journal).entries.Count
    Assert-Nx 'journal pipeline refuses a banned EnableLUA=0 write' $guardThrew
    Assert-Nx 'banned write refusal happens before any journal entry' ($after -eq $before) "before=$before after=$after"

    $planTarget = Invoke-Nx14RegistryTarget -JournalRoot $journal -TweakId 'NX14-SELFTEST' -Approval 'SelfTest' -Path $uacPath -Name 'EnableLUA' -Kind DWord -Value 1 -WhatIf
    $after = (Read-NxJournal -Path $journal).entries.Count
    Assert-Nx 'journal pipeline -WhatIf writes no journal entry' ($after -eq $before)
    Assert-Nx 'journal pipeline -WhatIf reports changed=false' ($planTarget.changed -eq $false)

    # -----------------------------------------------------------------------
    # 7. Journal round-trip mechanics in the temp directory (no Windows state)
    # -----------------------------------------------------------------------
    $descriptor = Capture-NxRegistryValue -Path $uacPath -Name 'ConsentPromptBehaviorAdmin'
    $mod = [pscustomobject]@{ targetType = 'registry'; path = $descriptor.path; name = $descriptor.name; kind = 'DWord'; value = 5 }
    $entry = Add-NxJournalEntry -Path $journal -TweakId 'NX14-TEST' -TweakVersion '1' -Operation 'skip' -Approval 'SelfTest' -Original $descriptor -Modified $mod -Result 'SelfTestOnly' -Verification 'NotRun'
    Assert-Nx 'journal accepts a captured descriptor (read-only capture)' ($entry.seq -ge 1)
    $read = Read-NxJournal -Path $journal
    Assert-Nx 'journal integrity chain holds after append' (@($read.integrityErrors).Count -eq 0) (($read.integrityErrors) -join '; ')

    $rb = Invoke-Nx14Rollback -JournalRoot $journal
    Assert-Nx 'rollback with no NX14 candidates restores nothing and does not fail' ($rb.aborted -eq $false -and @($rb.restored).Count -eq 0 -and @($rb.failed).Count -eq 0)

    # Journal read-back normalisation: a synthetic processMitigation entry must
    # reach the divergence path (never a mutation) because the live process has
    # no configuration. A GUID image name cannot exist in IFEO.
    $fakeExe = 'nx14-selftest-' + [Guid]::NewGuid().ToString('N') + '.exe'
    $origPm = [pscustomobject]@{ targetType = 'processMitigation'; processName = $fakeExe; existed = $false; source = $null; values = [ordered]@{} }
    $modPm = [pscustomobject]@{ targetType = 'processMitigation'; processName = $fakeExe; values = [ordered]@{ CFG = 1 } }
    $null = Add-NxJournalEntry -Path $journal -TweakId 'NX14-TEST2' -TweakVersion '1' -Operation 'apply' -Approval 'SelfTest' -Original $origPm -Modified $modPm -Result 'InProgress' -Verification 'NotRun'
    $rbPm = Invoke-Nx14Rollback -JournalRoot $journal -TweakId 'NX14-TEST2'
    Assert-Nx 'processMitigation rollback normalises the journal map and reports divergence' (@($rbPm.diverged).Count -eq 1 -and @($rbPm.restored).Count -eq 0 -and @($rbPm.failed).Count -eq 0) (ConvertTo-Json $rbPm -Depth 4 -Compress)

    # CFA with an impossible recorded mode must diverge (or fail when the
    # provider is unavailable) and must never attempt a restore.
    $origCfa = [pscustomobject]@{ targetType = 'defenderPreference'; name = 'ControlledFolderAccess'; mode = 'Sentinel'; modeValue = 9; allowedApplications = @() }
    $modCfa = [pscustomobject]@{ targetType = 'defenderPreference'; name = 'ControlledFolderAccess'; mode = 'Sentinel'; modeValue = 9; allowedApplications = @() }
    $null = Add-NxJournalEntry -Path $journal -TweakId 'NX14-TEST3' -TweakVersion '1' -Operation 'apply' -Approval 'SelfTest' -Original $origCfa -Modified $modCfa -Result 'InProgress' -Verification 'NotRun'
    $rbCfa = Invoke-Nx14Rollback -JournalRoot $journal -TweakId 'NX14-TEST3'
    Assert-Nx 'CFA rollback never mutates when the recorded state cannot be ours' (@($rbCfa.restored).Count -eq 0 -and (@($rbCfa.diverged).Count + @($rbCfa.failed).Count) -eq 1) (ConvertTo-Json $rbCfa -Depth 4 -Compress)

    # -----------------------------------------------------------------------
    # 8. JSON <-> function signature consistency + policy invariants
    # -----------------------------------------------------------------------
    $jsonPath = Join-Path $root 'registry\NX14.json'
    $cat = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tweaks = @($cat.tweaks)
    Assert-Nx 'registry file has 15 tweaks' ($tweaks.Count -eq 15)
    $expectedIds = @(1..15 | ForEach-Object { 'NX14-{0:D3}' -f $_ })
    Assert-Nx 'registry IDs are NX14-001..015' (@($tweaks | Where-Object { $expectedIds -notcontains $_.id }).Count -eq 0)

    $mutatingFunctions = @(
        'Set-Nx14UacLevel','Set-Nx14SmartScreen','Set-Nx14MemoryIntegrity',
        'Set-Nx14ControlledFolderAccess','Set-Nx14MitigationPolicy',
        'Set-Nx14WindowsSandbox','Set-Nx14VirtualizationPlatform'
    )
    foreach ($t in $tweaks) {
        foreach ($a in @($t.apply.actions)) {
            if ($a.type -ne 'function') { continue }
            $cmd = Get-Command -Name ([string]$a.function) -CommandType Function -ErrorAction SilentlyContinue
            Assert-Nx ("function '$($a.function)' exists for $($t.id)") ($null -ne $cmd)
            if ($null -eq $cmd) { continue }
            foreach ($p in @($a.parameters.PSObject.Properties)) {
                Assert-Nx ("$($t.id): parameter '$($p.Name)' is declared by $($a.function)") ($cmd.Parameters.ContainsKey([string]$p.Name))
            }
            if ($cmd.Parameters.ContainsKey('JournalRoot')) {
                Assert-Nx ("$($t.id): $($a.function) declares -Approved") ($cmd.Parameters.ContainsKey('Approved'))
                Assert-Nx ("$($t.id): $($a.function) declares -Approval") ($cmd.Parameters.ContainsKey('Approval'))
                Assert-Nx ("$($t.id): $($a.function) declares -Profiles") ($cmd.Parameters.ContainsKey('Profiles'))
                Assert-Nx ("$($t.id): $($a.function) declares -TweakVersion") ($cmd.Parameters.ContainsKey('TweakVersion'))
                Assert-Nx ("$($t.id): $($a.function) supports -WhatIf") ($cmd.Parameters.ContainsKey('WhatIf'))
            }
        }
    }

    $advanced = @($tweaks | Where-Object { $_.risk -eq 'ADVANCED' })
    Assert-Nx 'ADVANCED entries exist (008/011/014)' ($advanced.Count -eq 3)
    Assert-Nx 'every ADVANCED entry is presetExcluded' (@($advanced | Where-Object { $_.presetExcluded -ne $true }).Count -eq 0)
    Assert-Nx 'every ADVANCED entry requires ExplicitConsent' (@($advanced | Where-Object { $_.approval -ne 'ExplicitConsent' }).Count -eq 0)
    Assert-Nx 'Memory Integrity, Exploit Protection and virtualization are the ADVANCED set' ((@($advanced | ForEach-Object { $_.id }) -join ',') -eq 'NX14-008,NX14-011,NX14-014')

    Assert-Nx 'all apply.actions exist (status Implemented requires actions)' (@($tweaks | Where-Object { @($_.apply.actions).Count -eq 0 }).Count -eq 0)
    Assert-Nx 'every declared function is a NEXTRIX category function or report' (@($tweaks | ForEach-Object { $_.apply.actions } | Where-Object { [string]$_.function -notmatch '^Get-Nx14|^Set-Nx14' }).Count -eq 0)

    # No insecure value anywhere in the registry (defence in depth on top of the validator).
    $allActions = @($tweaks | ForEach-Object { $_.apply.actions })
    Assert-Nx 'registry never writes EnableLUA=0' (@($allActions | Where-Object { $_.type -eq 'registry' -and $_.name -eq 'EnableLUA' -and [string]$_.data -eq '0' }).Count -eq 0)
    Assert-Nx 'registry never writes SmartScreenEnabled=Off' (@($allActions | Where-Object { $_.type -eq 'registry' -and $_.name -eq 'SmartScreenEnabled' -and [string]$_.data -eq 'Off' }).Count -eq 0)
    Assert-Nx 'registry never writes HVCI Enabled=0' (@($allActions | Where-Object { $_.type -eq 'registry' -and $_.name -eq 'Enabled' -and [string]$_.data -eq '0' }).Count -eq 0)
    Assert-Nx 'registry never writes PreventDeviceEncryption=1' (@($allActions | Where-Object { $_.type -eq 'registry' -and $_.name -eq 'PreventDeviceEncryption' -and [string]$_.data -eq '1' }).Count -eq 0)
    Assert-Nx 'no NX14 entry touches a never-touch service' (@($allActions | Where-Object { $_.type -eq 'service' }).Count -eq 0)
    Assert-Nx 'no NX14 apply action targets ControlSet001/002' (@($allActions | Where-Object { $_.path -match 'ControlSet00[12]' }).Count -eq 0)
    Assert-Nx 'no NX14 proposed state names a ControlSet001/002 path' (@($tweaks | Where-Object { [string]$_.proposedState -match 'ControlSet00[12]' }).Count -eq 0)

    Assert-Nx 'no NX14 entry claims a performance benefit' (@($tweaks | Where-Object { ($_.description + ' ' + $_.objective + ' ' + (@($_.sideEffects) -join ' ')) -match '(?i)faster|\bfps\b|lower latency|smoother|boost(s)? (performance|fps)' }).Count -eq 0)
    Assert-Nx 'every entry documents a Microsoft source or a labelled research source' (@($tweaks | Where-Object { @($_.documentationSource).Count -eq 0 }).Count -eq 0)
    Assert-Nx 'no entry uses an E2+ evidence level without owner testing' (@($tweaks | Where-Object { @('E2','E3','E4') -contains $_.evidence }).Count -eq 0)
    Assert-Nx 'NX14-008 documents the never-disable direction' ([string](@($tweaks | Where-Object { $_.id -eq 'NX14-008' })[0].technicalExplanation) -match '(?i)never disables|never an automated disable|does not implement the disable')
    Assert-Nx 'NX14-010 documents that CFA off is not implemented' ([string](@($tweaks | Where-Object { $_.id -eq 'NX14-010' })[0].technicalExplanation) -match '(?i)not implemented|never turns|catalogue')
    Assert-Nx 'NX14-014 carries mandatory WSL2/Docker warnings' ([string](@($tweaks | Where-Object { $_.id -eq 'NX14-014' })[0].technicalExplanation) -match '(?i)WSL2' -and [string](@($tweaks | Where-Object { $_.id -eq 'NX14-014' })[0].technicalExplanation) -match '(?i)Docker')
    Assert-Nx 'status of every entry is Implemented' (@($tweaks | Where-Object { $_.status -ne 'Implemented' }).Count -eq 0)

} finally {
    if (Test-Path $temp) { Remove-Item -Path $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ''
Write-Output ("RESULT: PASS=$pass FAIL=$fail")
if ($fail -gt 0) { exit 1 }
exit 0
