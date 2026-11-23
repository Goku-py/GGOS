#Requires -Version 5.1
<#
    Test-NX13.ps1 - NX13 Privacy & Telemetry self-test.

    SAFETY (directive Section 16 / SECURITY_POLICY.md Section 5; workstream rule
    "never apply/test-run tweaks, read-only queries only"):
    This test NEVER mutates a registry value and NEVER changes a task state.
    It exercises only:
      1. the pure edition-floor resolver (synthetic edition ids),
      2. the pure permission map and telemetry-task allow-list invariants,
      3. read-only report functions (Get-NxAppPermissionState,
         Get-NxPrivacyAuditReport) against this machine,
      4. the approval gate: mutating functions must throw BEFORE any mutation
         when -Approved is absent,
      5. -WhatIf planning: no journal write, no registry/task change, using a
         throwaway temp journal directory,
      6. journal round-trip mechanics in the temp directory (no Windows state),
      7. JSON <-> function signature consistency for the declarative entries.

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
. (Join-Path $root 'src\nxcore\functions\NX13.ps1')

$pass = 0; $fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('nextrix-nx13-selftest-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $temp -ItemType Directory -Force | Out-Null
try {
    $journal = Join-Path $temp 'journal'
    $init = Initialize-NxJournal -Path $journal
    Assert-Nx 'temp journal initialised' ($init.created -eq $true) (ConvertTo-Json $init -Compress)

    # -----------------------------------------------------------------------
    # 1. Edition floor resolver - the core honesty requirement
    # -----------------------------------------------------------------------
    $ent = Get-Nx13DiagnosticDataFloor -EditionId 'Enterprise'
    Assert-Nx 'Enterprise floor = 0' ($ent.floor -eq 0 -and $ent.family -eq 'Enterprise') $ent.explanation
    $entS = Get-Nx13DiagnosticDataFloor -EditionId 'EnterpriseS'
    Assert-Nx 'EnterpriseS (LTSC) floor = 0' ($entS.floor -eq 0)
    $edu = Get-Nx13DiagnosticDataFloor -EditionId 'Education'
    Assert-Nx 'Education floor = 0' ($edu.floor -eq 0 -and $edu.family -eq 'Education')
    $pro = Get-Nx13DiagnosticDataFloor -EditionId 'Professional'
    Assert-Nx 'Pro floor = 1 (documented equivalence, not a placebo 0)' ($pro.floor -eq 1 -and $pro.family -eq 'Pro') $pro.explanation
    $core = Get-Nx13DiagnosticDataFloor -EditionId 'CoreSingleLanguage'
    Assert-Nx 'Home floor = 1' ($core.floor -eq 1 -and $core.family -eq 'Home')
    $srv = Get-Nx13DiagnosticDataFloor -EditionId 'ServerDatacenter'
    Assert-Nx 'Server floor = 0' ($srv.floor -eq 0)
    $unknown = Get-Nx13DiagnosticDataFloor -EditionId 'Frobnicated'
    Assert-Nx 'Unknown edition -> conservative floor 1 + uncertainty' ($unknown.floor -eq 1 -and $unknown.floorDocumented -eq $false -and @($unknown.uncertainty).Count -eq 1)
    Assert-Nx 'Floor explanations never claim performance' (-not ($pro.explanation -match '(?i)faster|fps|latency|performance'))

    # -----------------------------------------------------------------------
    # 2. Pure maps and allow-list invariants
    # -----------------------------------------------------------------------
    $map = Get-Nx13PermissionMap
    Assert-Nx 'permission map has 5 capabilities' (@($map).Count -eq 5)
    Assert-Nx 'camera maps to webcam consent store' ((@($map | Where-Object { $_.key -eq 'camera' })[0]).consentStore -eq 'webcam')
    Assert-Nx 'calendar maps to appointments consent store' ((@($map | Where-Object { $_.key -eq 'calendar' })[0]).consentStore -eq 'appointments')
    Assert-Nx 'no NX01 CDM / NX15 Start_Track value names in the map' (@($map | Where-Object { $_.valueName -match 'Start_Track|SubscribedContent|SilentInstalledApps' }).Count -eq 0)

    $allow = Get-Nx13TelemetryTaskAllowList
    Assert-Nx 'telemetry allow-list is non-empty' (@($allow).Count -ge 8)
    Assert-Nx 'allow-list has no duplicate task targets' (@($allow | Group-Object { $_.taskPath + $_.taskName } | Where-Object { $_.Count -gt 1 }).Count -eq 0)
    Assert-Nx 'allow-list never contains Windows Update Scheduled Start' (@($allow | Where-Object { $_.taskName -match '(?i)scheduled start' }).Count -eq 0)
    Assert-Nx 'allow-list never contains UpdateOrchestrator' (@($allow | Where-Object { $_.taskPath -match '(?i)UpdateOrchestrator' }).Count -eq 0)
    Assert-Nx 'QueueReporting is opt-in only (defaultIncluded=false)' ((@($allow | Where-Object { $_.taskName -eq 'QueueReporting' })[0]).defaultIncluded -eq $false)
    Assert-Nx 'allow-list excludes Start_/CDM/NX01 value families' (@($allow | Where-Object { $_.taskName -match 'Start_Track|SubscribedContent' }).Count -eq 0)

    # -----------------------------------------------------------------------
    # 3. Read-only reports against this machine
    # -----------------------------------------------------------------------
    $permState = Get-NxAppPermissionState -Permissions @('location','camera')
    Assert-Nx 'Get-NxAppPermissionState is read-only' ($permState.readOnly -eq $true)
    Assert-Nx 'Get-NxAppPermissionState returns one row per requested capability' (@($permState.permissions).Count -eq 2)
    Assert-Nx 'permission rows carry a policy state string' (@($permState.permissions | Where-Object { [string]::IsNullOrWhiteSpace($_.policyState) }).Count -eq 0)

    $audit = Get-NxPrivacyAuditReport
    Assert-Nx 'Get-NxPrivacyAuditReport is read-only' ($audit.readOnly -eq $true)
    Assert-Nx 'audit report has findings' (@($audit.findings).Count -ge 20)
    Assert-Nx 'audit report exposes app permissions' (@($audit.appPermissions).Count -eq 5)
    Assert-Nx 'audit report reports the edition floor' ($audit.edition.diagnosticFloor -in @(0,1))
    Assert-Nx 'audit report answers configuration, not performance' (-not ([string]$audit.note -match '(?i)faster|fps|performance'))
    Assert-Nx 'audit report carries an uncertainty array' ($null -ne $audit.uncertainty -and $audit.uncertainty -is [array])

    # -----------------------------------------------------------------------
    # 4. Approval gate (must throw before any mutation path is reached)
    # -----------------------------------------------------------------------
    $threw = $false
    try { Set-NxDiagnosticDataLevel -JournalRoot $journal -EditionId 'Enterprise' | Out-Null } catch { $threw = $true }
    Assert-Nx 'Set-NxDiagnosticDataLevel refuses without -Approved' $threw

    $threw = $false
    try { Set-NxAppPermissionDefaults -JournalRoot $journal -Permissions @('camera') | Out-Null } catch { $threw = $true }
    Assert-Nx 'Set-NxAppPermissionDefaults refuses without -Approved' $threw

    $threw = $false
    try { Set-NxTelemetryTasks -JournalRoot $journal | Out-Null } catch { $threw = $true }
    Assert-Nx 'Set-NxTelemetryTasks refuses without -Approved' $threw

    # -----------------------------------------------------------------------
    # 5. -WhatIf leaves no trace (no journal entry, no mutation)
    # -----------------------------------------------------------------------
    $before = (Read-NxJournal -Path $journal).entries.Count
    $plan = Set-NxDiagnosticDataLevel -JournalRoot $journal -EditionId 'Enterprise' -WhatIf
    $after = (Read-NxJournal -Path $journal).entries.Count
    Assert-Nx 'Set-NxDiagnosticDataLevel -WhatIf writes no journal entry' ($after -eq $before) "before=$before after=$after"
    Assert-Nx 'Set-NxDiagnosticDataLevel -WhatIf changes nothing' (@($plan.targets | Where-Object { $_.changed }).Count -eq 0)

    $before = (Read-NxJournal -Path $journal).entries.Count
    $taskPlan = Set-NxTelemetryTasks -JournalRoot $journal -WhatIf
    $after = (Read-NxJournal -Path $journal).entries.Count
    Assert-Nx 'Set-NxTelemetryTasks -WhatIf writes no journal entry' ($after -eq $before) "before=$before after=$after"
    Assert-Nx 'Set-NxTelemetryTasks -WhatIf reports plans only' (@($taskPlan.results | Where-Object { $_.outcome -eq 'Disabled' }).Count -eq 0)

    # Mechanism reuse: when the NX11 module is present, NX13-013 delegates the
    # state change to NX11-006's verified 3-fallback helper (never duplicated).
    $nx11Path = Join-Path $root 'src\nxcore\functions\NX11.ps1'
    if (Test-Path $nx11Path) {
        . $nx11Path
        Assert-Nx 'NX11-006 state changer available for reuse' ($null -ne (Get-Command -Name 'Set-Nx11TaskEnabled' -CommandType Function -ErrorAction SilentlyContinue))
        Assert-Nx 'NX13 task-state helper exists (delegates or falls back)' ($null -ne (Get-Command -Name 'Invoke-Nx13TaskStateChange' -CommandType Function -ErrorAction SilentlyContinue))
    } else {
        Write-Output 'SKIP: NX11 module not present - NX13-013 fallback path only'
    }

    # -----------------------------------------------------------------------
    # 6. Rollback engine on an empty journal: no candidates, no mutation
    # -----------------------------------------------------------------------
    $rb = Invoke-Nx13Rollback -JournalRoot $journal
    Assert-Nx 'Invoke-Nx13Rollback aborts nothing on empty journal' ($rb.aborted -eq $false -and @($rb.restored).Count -eq 0 -and @($rb.failed).Count -eq 0)

    # -----------------------------------------------------------------------
    # 7. Journal round-trip mechanics in the temp directory (no Windows state)
    # -----------------------------------------------------------------------
    $descriptor = Capture-NxRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_TrackDocs'
    $mod = [pscustomobject]@{ targetType = 'registry'; path = $descriptor.path; name = $descriptor.name; kind = 'DWord'; value = 0 }
    $entry = Add-NxJournalEntry -Path $journal -TweakId 'NX13-TEST' -TweakVersion '1' -Operation 'skip' -Approval 'SelfTest' -Original $descriptor -Modified $mod -Result 'SelfTestOnly' -Verification 'NotRun'
    Assert-Nx 'journal accepts a captured descriptor (read-only capture)' ($entry.seq -ge 1)
    $read = Read-NxJournal -Path $journal
    Assert-Nx 'journal integrity chain holds after append' (@($read.integrityErrors).Count -eq 0) (($read.integrityErrors) -join '; ')

    # -----------------------------------------------------------------------
    # 8. JSON <-> function signature consistency
    # -----------------------------------------------------------------------
    $jsonPath = Join-Path $root 'registry\NX13.json'
    $cat = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Nx 'registry file has 14 tweaks' (@($cat.tweaks).Count -eq 14)
    $fnIds = @{}
    foreach ($t in @($cat.tweaks)) {
        foreach ($a in @($t.apply.actions)) {
            if ($a.type -ne 'function') { continue }
            $fnIds[[string]$a.function] = $true
            $cmd = Get-Command -Name ([string]$a.function) -CommandType Function -ErrorAction SilentlyContinue
            Assert-Nx ("function '$($a.function)' exists for $($t.id)") ($null -ne $cmd)
            if ($null -eq $cmd) { continue }
            foreach ($p in @($a.parameters.PSObject.Properties)) {
                Assert-Nx ("$($t.id): parameter '$($p.Name)' declared by $($a.function)") ($cmd.Parameters.ContainsKey([string]$p.Name))
            }
            if ($cmd.Parameters.ContainsKey('JournalRoot')) {
                Assert-Nx ("$($t.id): $($a.function) declares -Approved") ($cmd.Parameters.ContainsKey('Approved'))
                Assert-Nx ("$($t.id): $($a.function) declares -Approval") ($cmd.Parameters.ContainsKey('Approval'))
                Assert-Nx ("$($t.id): $($a.function) declares -Profiles") ($cmd.Parameters.ContainsKey('Profiles'))
                Assert-Nx ("$($t.id): $($a.function) declares -TweakVersion") ($cmd.Parameters.ContainsKey('TweakVersion'))
            }
        }
    }
    Assert-Nx 'declarative entries never use a function' (@($cat.tweaks | Where-Object { $_.modificationType -eq 'registry' -and @($_.apply.actions | Where-Object { $_.type -eq 'function' }).Count -gt 0 }).Count -eq 0)
    Assert-Nx 'no NX13 registry action targets Start_Track* (NX15 ownership)' (@($cat.tweaks | ForEach-Object { $_.apply.actions } | Where-Object { $_.name -match '^Start_Track' }).Count -eq 0)
    Assert-Nx 'no NX13 registry action targets the NX01 CDM family' (@($cat.tweaks | ForEach-Object { $_.apply.actions } | Where-Object { $_.path -match 'ContentDeliveryManager' }).Count -eq 0)
    Assert-Nx 'no NX13 entry claims performance' (@($cat.tweaks | Where-Object { ($_.description + ' ' + $_.objective + ' ' + $_.technicalExplanation + ' ' + (@($_.sideEffects) -join ' ')) -match '(?i)faster|\bfps\b|lower latency|smoother' }).Count -eq 0)
    Assert-Nx 'cross-device entry declares the NX12-004 conflict' (@(@($cat.tweaks | Where-Object { $_.id -eq 'NX13-012' })[0].conflicts) -contains 'NX12-004')
    Assert-Nx 'telemetry-task entry documents the NX11-006 boundary/reuse' ([string](@($cat.tweaks | Where-Object { $_.id -eq 'NX13-013' })[0].technicalExplanation) -match 'NX11-006')
    Assert-Nx 'diagnostic-data entry is edition-aware in its description' ([string](@($cat.tweaks | Where-Object { $_.id -eq 'NX13-004' })[0].description) -match '(?i)edition')
}
finally {
    if (Test-Path $temp) { Remove-Item -Path $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ''
Write-Output ("RESULT: PASS=$pass FAIL=$fail")
if ($fail -gt 0) { exit 1 }
exit 0
