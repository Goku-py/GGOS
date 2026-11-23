#Requires -Version 5.1
<#
    Test-NX12.ps1 - NX12 Windows Debloating self-test.

    SAFETY (SECURITY_POLICY.md; workstream rule "never remove/reinstall anything"):
    This test NEVER calls Remove-AppxPackage, Remove-AppxProvisionedPackage,
    Remove-WindowsCapability, winget install or any other mutating command. It
    exercises only:
      1. the protected-dependency guard (pure decisions + read-only report),
      2. catalog/allow-list invariants (pure data),
      3. read-only plans, scope report, dependency graph, capability inventory,
      4. the empty-selection no-op and the approval gates (must throw BEFORE
         any mutation),
      5. the guarded plan path (a protected selection is refused, not removed),
      6. journal/ledger/rollback mechanics in a throwaway temp journal using a
         synthetic package name that does not exist on the machine,
      7. registry/NX12.json <-> function consistency and declared conflicts.

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
. (Join-Path $root 'src\nxcore\functions\NX12.ps1')

$pass = 0; $fail = 0
function Assert-Nx([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('nextrix-nx12-selftest-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $temp -ItemType Directory -Force | Out-Null
try {
    # -----------------------------------------------------------------------
    # 1. Guard decisions (pure)
    # -----------------------------------------------------------------------
    $store = Test-Nx12PackageProtected -PackageName 'Microsoft.WindowsStore'
    Assert-Nx 'Store is protected' ($store.protected -eq $true -and $store.ruleId -eq 'store') $store.reason
    $installer = Test-Nx12PackageProtected -PackageName 'Microsoft.DesktopAppInstaller'
    Assert-Nx 'App Installer is protected' ($installer.protected -eq $true)
    $vclibs = Test-Nx12PackageProtected -PackageName 'Microsoft.VCLibs.140.00' -SignatureKind 'Store'
    Assert-Nx 'VCLibs pattern is protected' ($vclibs.protected -eq $true -and $vclibs.matchedBy -eq 'pattern')
    $wv = Test-Nx12PackageProtected -PackageName 'Microsoft.Win32WebViewHost'
    Assert-Nx 'WebView2 host is protected' ($wv.protected -eq $true)
    $wvPattern = Test-Nx12PackageProtected -PackageName 'Vendor.SomeWebView2Wrapper'
    Assert-Nx 'WebView2 name pattern is protected' ($wvPattern.protected -eq $true)
    $system = Test-Nx12PackageProtected -PackageName 'Vendor.Unlisted.Component' -SignatureKind 'System'
    Assert-Nx 'System-signed package is protected by rule' ($system.protected -eq $true -and $system.matchedBy -eq 'signature')
    $consumer = Test-Nx12PackageProtected -PackageName 'Microsoft.BingNews' -SignatureKind 'Store'
    Assert-Nx 'Consumer app is not protected' ($consumer.protected -eq $false)
    $vv = Test-Nx12PackageProtected -PackageName 'Microsoft.VisualStudio.2022' -SignatureKind 'Store'
    Assert-Nx 'Unlisted Store app is not protected' ($vv.protected -eq $false)

    # -----------------------------------------------------------------------
    # 2. Catalog invariants (pure data)
    # -----------------------------------------------------------------------
    Assert-Nx 'consumer catalog has 21 apps' (@($script:Nx12ConsumerCatalog).Count -eq 21) (@($script:Nx12ConsumerCatalog).Count)
    Assert-Nx 'consumer catalog names are unique' (@($script:Nx12ConsumerCatalog | Group-Object name | Where-Object { $_.Count -gt 1 }).Count -eq 0)
    Assert-Nx 'no consumer app is protected' (@($script:Nx12ConsumerCatalog | Where-Object { (Test-Nx12PackageProtected -PackageName $_.name).protected }).Count -eq 0)
    Assert-Nx 'no consumer app is system-reserved' (@($script:Nx12ConsumerCatalog | Where-Object { $_.name -match '(?i)Store|WebView|VCLibs|GamingServices|XboxIdentity' }).Count -eq 0)
    Assert-Nx 'communication catalog marks Teams acknowledgement' ((@($script:Nx12CommunicationCatalog | Where-Object { $_.name -eq 'MSTeams' })[0]).acknowledge -eq 'AcknowledgeTeamsWorkload')
    Assert-Nx 'Xbox catalog is app-only (no GamingServices/identity)' (@($script:Nx12XboxCatalog | Where-Object { $_.name -match 'GamingServices|IdentityProvider|GameCallable' }).Count -eq 0)
    Assert-Nx 'Phone Link catalog is Microsoft.YourPhone only' (@($script:Nx12PhoneLinkCatalog).Count -eq 1 -and $script:Nx12PhoneLinkCatalog[0].name -eq 'Microsoft.YourPhone')
    Assert-Nx 'provisioning families are unique' (@($script:Nx12ProvisioningFamilies | Group-Object familyId | Where-Object { $_.Count -gt 1 }).Count -eq 0)
    Assert-Nx 'capability allow-list has no duplicates' (@($script:Nx12CapabilityAllowList | Group-Object name | Where-Object { $_.Count -gt 1 }).Count -eq 0)

    # -----------------------------------------------------------------------
    # 3. Guard enforcement + read-only reports
    # -----------------------------------------------------------------------
    $report = Get-NxProtectedDependencyReport
    Assert-Nx 'protected report is read-only' ($report.readOnly -eq $true)
    Assert-Nx 'protected report exposes rules' (@($report.rules).Count -ge 20)
    Assert-Nx 'protected probes include a protected and an unprotected decision' ((@($report.probes | Where-Object { $_.protected }).Count -gt 0) -and (@($report.probes | Where-Object { -not $_.protected }).Count -gt 0))

    $plan = Get-Nx12RemovalPlan -Family Consumer
    Assert-Nx 'consumer plan is read-only' ($plan.readOnly -eq $true)
    Assert-Nx 'consumer plan lists all 21 catalog apps' (@($plan.candidates).Count -eq 21)
    Assert-Nx 'consumer plan never silently selects anything' (@($plan.candidates | Where-Object { $_.selected }).Count -eq 0)
    $oemPlan = Get-Nx12RemovalPlan -Family Oem
    Assert-Nx 'OEM plan excludes Microsoft-published apps' (@($oemPlan.candidates | Where-Object { $_.name -match '^Microsoft[\.]' }).Count -eq 0)
    $scope = Get-NxRemovalScopeReport -PackageNames @('Microsoft.BingNews')
    Assert-Nx 'scope report is read-only' ($scope.readOnly -eq $true)
    Assert-Nx 'scope report documents all three scopes' (@($scope.rows)[0].scopes.PSObject.Properties.Name -contains 'CurrentUser' -and @($scope.rows)[0].scopes.PSObject.Properties.Name -contains 'AllUsers' -and @($scope.rows)[0].scopes.PSObject.Properties.Name -contains 'Provisioned')
    $graph = Get-NxAppxDependencyGraph -FocusPackage @('Microsoft.WindowsStore')
    Assert-Nx 'dependency graph is read-only' ($graph.readOnly -eq $true)
    Assert-Nx 'protected focus is not safe to remove' ((@($graph.focus)[0]).safeToRemove -eq $false)
    $caps = Get-NxOptionalCapabilityInventory
    Assert-Nx 'capability inventory is read-only' ($caps.readOnly -eq $true)
    Assert-Nx 'language capability is refused' ((Test-Nx12CapabilityAllowed -Name 'Language.Basic~~~en-US~0.0.1.0').allowed -eq $false)
    Assert-Nx 'allow-listed capability is accepted' ((Test-Nx12CapabilityAllowed -Name 'Print.Management.Console').allowed -eq $true)

    # -----------------------------------------------------------------------
    # 4. No hidden removal + approval gates
    # -----------------------------------------------------------------------
    $journal = Join-Path $temp 'journal'
    $init = Initialize-NxJournal -Path $journal
    Assert-Nx 'temp journal initialised' ($init.created -eq $true)

    $empty = Set-NxConsumerAppState -JournalRoot $journal
    Assert-Nx 'empty selection is a no-op report' ($empty.outcome -eq 'NoSelection' -and $empty.readOnly -eq $true)
    $emptyEngine = Invoke-Nx12Removal -JournalRoot $journal -TweakId 'NX12-001' -PackageNames @() -Approved
    Assert-Nx 'engine empty selection is a no-op report' ($emptyEngine.removedCount -eq 0 -and $emptyEngine.steps[0].outcome -eq 'NoSelection')

    $threw = $false
    try { $null = Set-NxConsumerAppState -JournalRoot $journal -PackageNames 'Microsoft.BingNews' } catch { $threw = $true }
    Assert-Nx 'removal without -Approved throws before mutation' $threw

    $threw = $false
    try { $null = Remove-NxProvisionedPackageControl -JournalRoot $journal -ProvisionedPackageNames 'Contoso.Synthetic_1.0.0.0_neutral_~_abc' -Approved -Approval 'Selection' } catch { $threw = $true }
    Assert-Nx 'provisioned removal requires ExplicitConsent' $threw

    $threw = $false
    try { $null = Remove-NxOptionalCapability -JournalRoot $journal -CapabilityNames 'Print.Management.Console' -Approved -Approval 'Selection' } catch { $threw = $true }
    Assert-Nx 'capability removal requires ExplicitConsent' $threw

    $protectedPlan = Invoke-Nx12Removal -JournalRoot $journal -TweakId 'NX12-001' -PackageNames 'Microsoft.WindowsStore' -Plan
    Assert-Nx 'engine refuses a protected selection in plan mode' (@($protectedPlan.results | Where-Object { $_.outcome -eq 'Refused-Protected' }).Count -eq 1)
    Assert-Nx 'plan mode writes no journal entries' ((Read-NxJournal -Path $journal).entries.Count -eq 0)

    $unknown = Set-NxNewUserProvisioningPolicy -JournalRoot $journal -FamilyIds @('NotAFamily') -Plan
    Assert-Nx 'unknown provisioning family is refused' ($unknown.outcome -eq 'Refused-UnknownFamily')

    # -----------------------------------------------------------------------
    # 5. Journal/ledger/rollback mechanics (synthetic package only)
    # -----------------------------------------------------------------------
    $synthetic = 'Contoso.Nx12SyntheticApp'
    $orig = [pscustomobject]@{ targetType = 'appx'; packageName = $synthetic; packageFullName = 'Contoso.Nx12SyntheticApp_1.0.0.0_x64__test'; packageFamilyName = 'Contoso.Nx12SyntheticApp_test'; version = '1.0.0.0'; architecture = 'X64'; scope = 'CurrentUser'; provisionedState = 'NotProvisioned' }
    $mod = [pscustomobject]@{ targetType = 'appx'; packageName = $synthetic; scope = 'CurrentUser'; removalState = 'Removed'; provisionedState = 'Unchanged'; reversibility = 'StoreReinstallable'; reinstallRoute = 'Store/library' }
    $null = Add-NxJournalEntry -Path $journal -TweakId 'NX12-001' -TweakVersion '1' -Operation 'apply' -Approval 'SelectionPlusConfirmation' -Original $orig -Modified $mod -Result 'InProgress' -Verification 'NotRun'
    $null = Add-NxJournalEntry -Path $journal -TweakId 'NX12-001' -TweakVersion '1' -Operation 'verify' -Approval 'SelectionPlusConfirmation' -Original ([pscustomobject]@{ targetType = 'appx'; packageName = $synthetic; scope = 'CurrentUser' }) -Modified $mod -Result 'Success-Irreversible' -Verification 'VerifiedAbsent'
    $ledger = Get-NxRemovalLedger -JournalRoot $journal
    Assert-Nx 'ledger finds the synthetic removal' (@($ledger.items).Count -eq 1)
    Assert-Nx 'ledger carries the honest reversibility label' ($ledger.items[0].reversibility -eq 'StoreReinstallable')
    Assert-Nx 'ledger reports the package as absent (Removed)' ($ledger.items[0].status -eq 'Removed')
    Assert-Nx 'ledger counts Store-reinstallable items' ($ledger.counts.storeReinstallable -eq 1)
    $rb = Invoke-Nx12Rollback -JournalRoot $journal -TweakId 'NX12-001'
    Assert-Nx 'rollback restores nothing for an AppX removal' (@($rb.restored).Count -eq 0)
    Assert-Nx 'rollback reports the removal as irreversible' (@($rb.irreversible).Count -eq 1 -and $rb.irreversible[0].status -eq 'Irreversible')
    Assert-Nx 'rollback never reinstalls (report only)' ($rb.irreversible[0].restorePath -match 'Restore-NxRemovedApp')
    $reinstall = Restore-NxRemovedApp -JournalRoot $journal -Mode Report
    Assert-Nx 'reinstall helper defaults to read-only report' ($reinstall.readOnly -eq $true -and @($reinstall.items).Count -eq 1)
    $threw = $false
    try { $null = Restore-NxRemovedApp -JournalRoot $journal -Mode Install -PackageNames $synthetic -Approved } catch { $threw = $true }
    Assert-Nx 'Install mode refuses to guess a Store product id' $threw

    # -----------------------------------------------------------------------
    # 6. Registry <-> function consistency, conflicts, evidence
    # -----------------------------------------------------------------------
    $reg = Get-Content (Join-Path $root 'registry\NX12.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Nx 'registry defines 14 NX12 entries' (@($reg.tweaks).Count -eq 14)
    Assert-Nx 'every registry apply function exists in NX12.ps1' (@($reg.tweaks | Where-Object { -not (Get-Command -Name $_.apply.actions[0].function -CommandType Function -ErrorAction SilentlyContinue) }).Count -eq 0)
    $c004 = @($reg.tweaks | Where-Object { $_.id -eq 'NX12-004' })[0]
    Assert-Nx 'NX12-004 declares the NX13-012 conflict' (@($c004.conflicts) -contains 'NX13-012')
    $c005 = @($reg.tweaks | Where-Object { $_.id -eq 'NX12-005' })[0]
    Assert-Nx 'NX12-005 declares NX02-008 and NX11-010 conflicts' ((@($c005.conflicts) -contains 'NX02-008') -and (@($c005.conflicts) -contains 'NX11-010'))
    $c006 = @($reg.tweaks | Where-Object { $_.id -eq 'NX12-006' })[0]
    Assert-Nx 'NX12-006 stays E0 (build-conditional AI surface)' ($c006.evidence -eq 'E0')
    Assert-Nx 'all removal entries label rollback unreversible' (@($reg.tweaks | Where-Object { @('NX12-001','NX12-003','NX12-004','NX12-005','NX12-006','NX12-007','NX12-009','NX12-011','NX12-012','NX12-013') -contains $_.id -and $_.rollback.reversible -eq $true }).Count -eq 0)
    $marketing = @('faster','fps','latency','smoother')
    $badClaims = @($reg.tweaks | ForEach-Object { @($_.description, $_.objective, ($_.sideEffects -join ' ')) } | Where-Object { $t = $_; @($marketing | Where-Object { $t -match ('(?i)\b' + $_ + '\b') }).Count -gt 0 })
    Assert-Nx 'no performance-marketing wording in removal text' ($badClaims.Count -eq 0)
    Assert-Nx 'category note documents the protected-by-default rule' ($reg.categoryNote -match 'protected by default')
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ("RESULT: " + $(if ($fail -eq 0) { 'PASSED' } else { 'FAILED' }) + " - $pass passed, $fail failed")
if ($fail -gt 0) { exit 1 }
exit 0
