#Requires -Version 5.1
<#
    NX12.ps1 - NEXTRIX Windows Debloating category functions.

    Scope (registry/NX12.json): NX12-001 .. NX12-014.

    Safety model - read this before changing anything:
    - NOTHING is removed without an explicit per-app/per-package selection AND
      -Approved. Empty selections return a read-only plan; they never mean "all".
    - The protected-dependency guard (NX12-002) is enforced inside the removal
      engine itself, so no removal entry can bypass it:
        * Store, Store Purchase App, App Installer (winget), Edge/WebView2 host,
          VCLibs / .NET Native / UI.Xaml / Windows App Runtime families,
          shell/security/compositor hosts, Xbox identity + Gaming Services
          packages are protected by exact name or pattern;
        * any package whose SignatureKind is 'System' is protected by default
          (OS component rule) - an explicit list is not required to be safe.
    - Every removal journals the package identity, scope and provisioned state
      BEFORE the mutation, then journals a result entry labeled
      'Success-Irreversible'. NEXTRIX never claims an AppX/capability removal is
      journal-restorable: the labeled restore path is NX12-011.
    - Rollback delegates here (Invoke-Nx12Rollback) and reports removals as
      irreversible, with the documented reinstall route. It never re-downloads
      or reinstalls anything.
    - Reports are read-only: Get-NxProtectedDependencyReport,
      Get-Nx12RemovalPlan, Get-NxRemovalScopeReport, Get-NxRemovalLedger,
      Get-NxAppxDependencyGraph, Get-NxOptionalCapabilityInventory.
    - No performance claims anywhere in this file. App removal is a
      configuration change, not a performance result.

    Dependencies (dot-source AFTER the core modules, Import-NxCore order):
      NxJournal.ps1  -> Capture-NxRegistryValue, Add-NxJournalEntry, Read-NxJournal
      NxBuild.ps1    -> Get-NxBuildReport (edition/build read-only)
    Loading this file performs no package, registry, DISM or service reads/writes.

    Two read-only observation windows are used for evidence and verification:
    Get-AppxPackage (current user, -AllUsers when elevated) and
    Get-AppxProvisionedPackage/Get-WindowsCapability (DISM; may be unavailable,
    in which case the report says Unverified instead of guessing).
#>

# ============================================================================
# Static definitions - protected families, candidates, capability allow-list
# ============================================================================

# NX12-002: the protected-by-default list. Exact entries are matched first;
# wildcard patterns cover versioned runtime families. Every removal engine path
# calls Test-Nx12PackageProtected before journaling or mutating.
$script:Nx12ProtectionDefinitions = @(
    [pscustomobject]@{ id = 'store'; category = 'Store / app platform'; exact = 'Microsoft.WindowsStore'; pattern = $null; reason = 'Microsoft Store: without it apps cannot be installed, updated or reinstalled through the documented Store route (NX12-011 depends on it).' }
    [pscustomobject]@{ id = 'store-purchase'; category = 'Store / app platform'; exact = 'Microsoft.StorePurchaseApp'; pattern = $null; reason = 'Store purchase/licensing companion app; removing it breaks Store purchase and license flows.' }
    [pscustomobject]@{ id = 'app-installer'; category = 'Store / app platform'; exact = 'Microsoft.DesktopAppInstaller'; pattern = $null; reason = 'App Installer / winget: the documented package source used by the NX12-011 reinstall helper and by Windows app servicing.' }
    [pscustomobject]@{ id = 'webview-host'; category = 'WebView2 / browser platform'; exact = 'Microsoft.Win32WebViewHost'; pattern = $null; reason = 'System WebView2 host package used by shell and inbox apps; research records 15+ apps depending on WebView2 (r4).' }
    [pscustomobject]@{ id = 'webview-pattern'; category = 'WebView2 / browser platform'; exact = $null; pattern = '*WebView2*'; reason = 'Any package carrying the WebView2 identity is protected; the Evergreen WebView2 Runtime itself is a Win32 component and is never touched by AppX removal commands.' }
    [pscustomobject]@{ id = 'edge'; category = 'WebView2 / browser platform'; exact = 'Microsoft.MicrosoftEdge.Stable'; pattern = $null; reason = 'Edge is the WebView2 platform component; removal has documented Store/update consequences (r1, r4, r5) and is not a NEXTRIX target.' }
    [pscustomobject]@{ id = 'vclibs'; category = 'Runtime dependency'; exact = $null; pattern = 'Microsoft.VCLibs.*'; reason = 'Visual C++ UWP runtime: many Store apps fail to start without it; ReviOS had to re-provision VCLibs to fix a wsappx loop (r2).' }
    [pscustomobject]@{ id = 'net-native'; category = 'Runtime dependency'; exact = $null; pattern = 'Microsoft.NET.Native.*'; reason = '.NET Native framework/runtime used by UWP apps; removing it breaks dependent apps.' }
    [pscustomobject]@{ id = 'ui-xaml'; category = 'Runtime dependency'; exact = $null; pattern = 'Microsoft.UI.Xaml*'; reason = 'WinUI/XAML runtime used by inbox and Store apps; removal breaks their UI.' }
    [pscustomobject]@{ id = 'winapp-runtime'; category = 'Runtime dependency'; exact = $null; pattern = 'Microsoft.WindowsAppRuntime*'; reason = 'Windows App SDK runtime (framework + CBS variants) required by modern inbox/Store apps.' }
    [pscustomobject]@{ id = 'store-engagement'; category = 'Runtime dependency'; exact = 'Microsoft.Services.Store.Engagement'; pattern = $null; reason = 'Store engagement SDK used by Store-installed apps for notifications/ratings; a dependency, not a consumer app.' }
    [pscustomobject]@{ id = 'shell-host'; category = 'OS shell / security'; exact = 'Microsoft.Windows.ShellExperienceHost'; pattern = $null; reason = 'Shell experience host (Start, search UI surfaces); removing it breaks the shell.' }
    [pscustomobject]@{ id = 'start-host'; category = 'OS shell / security'; exact = 'Microsoft.Windows.StartMenuExperienceHost'; pattern = $null; reason = 'Start menu host process; an OS component, never a debloat target.' }
    [pscustomobject]@{ id = 'aad-broker'; category = 'OS shell / security'; exact = 'Microsoft.AAD.BrokerPlugin'; pattern = $null; reason = 'Account/identity broker used by Store, Office and Windows sign-in.' }
    [pscustomobject]@{ id = 'accounts-control'; category = 'OS shell / security'; exact = 'Microsoft.AccountsControl'; pattern = $null; reason = 'Account control UI used by Settings and identity flows.' }
    [pscustomobject]@{ id = 'cloud-experience'; category = 'OS shell / security'; exact = 'Microsoft.Windows.CloudExperienceHost'; pattern = $null; reason = 'OOBE/cloud identity host; required for sign-in and first-run flows.' }
    [pscustomobject]@{ id = 'people-host'; category = 'OS shell / security'; exact = 'Microsoft.Windows.PeopleExperienceHost'; pattern = $null; reason = 'System People host package (not the People app); shell component.' }
    [pscustomobject]@{ id = 'defender-ui'; category = 'OS shell / security'; exact = 'Microsoft.Windows.SecHealthUI'; pattern = $null; reason = 'Windows Security UI; security-relevant component, never removed.' }
    [pscustomobject]@{ id = 'smartscreen-ui'; category = 'OS shell / security'; exact = 'Microsoft.Windows.Apprep.ChxApp'; pattern = $null; reason = 'SmartScreen prompt UI; removing it degrades a security protection (directive S15).' }
    [pscustomobject]@{ id = 'secure-assessment'; category = 'OS shell / security'; exact = 'Microsoft.Windows.SecureAssessmentBrowser'; pattern = $null; reason = 'Windows Security secure assessment surface; OS security component.' }
    [pscustomobject]@{ id = 'search-host'; category = 'OS shell / security'; exact = 'Microsoft.Windows.Search'; pattern = $null; reason = 'Windows Search UI package; NX11-008 owns service configuration and the app itself is not a removal target.' }
    [pscustomobject]@{ id = 'xbox-identity'; category = 'Gaming dependency'; exact = 'Microsoft.XboxIdentityProvider'; pattern = $null; reason = 'Xbox identity provider used by Store sign-in and many games; NX12-005 removes the Xbox app, never the identity provider.' }
    [pscustomobject]@{ id = 'gaming-services'; category = 'Gaming dependency'; exact = 'Microsoft.GamingServices'; pattern = $null; reason = 'Gaming Services package: Game Pass install/update/play depends on it (r2, NX02-008, NX11-010).' }
    [pscustomobject]@{ id = 'gaming-services-net'; category = 'Gaming dependency'; exact = 'Microsoft.GamingServicesNet'; pattern = $null; reason = 'Gaming Services networking companion; required by the Gaming Services stack.' }
    [pscustomobject]@{ id = 'xbox-callable'; category = 'Gaming dependency'; exact = 'Microsoft.XboxGameCallableUI'; pattern = $null; reason = 'Xbox game UI plumbing used by titles; not a consumer app.' }
    [pscustomobject]@{ id = 'shell-client'; category = 'OS shell / security'; exact = $null; pattern = 'MicrosoftWindows.Client.*'; reason = 'Windows shell client composable packages; OS components, not debloat candidates.' }
)

# NX12-001 consumer catalog. Package names are the AppX Name identities used by
# Get-AppxPackage/Remove-AppxPackage. Every row is individually selectable.
$script:Nx12ConsumerCatalog = @(
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.BingNews'; displayName = 'Microsoft News'; usage = 'News feed app; no system dependency.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.BingWeather'; displayName = 'MSN Weather'; usage = 'Weather app; no system dependency.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.MicrosoftSolitaireCollection'; displayName = 'Microsoft Solitaire Collection'; usage = 'Games bundle; includes promotional surfaces.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.Clipchamp'; displayName = 'Clipchamp'; usage = 'Video editor; not a codec dependency. Keep if you edit video.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.ZuneMusic'; displayName = 'Media Player (legacy Groove)'; usage = 'Media player app; codecs are OS components and are not removed.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.ZuneVideo'; displayName = 'Movies & TV'; usage = 'Video library app; playback of local files may need another player.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.WindowsMaps'; displayName = 'Maps'; usage = 'Offline maps app; NX11-016 owns Maps service configuration separately. Keep if you use offline maps.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.WindowsFeedbackHub'; displayName = 'Feedback Hub'; usage = 'Feedback submission app; not required for Windows operation.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.GetHelp'; displayName = 'Get Help'; usage = 'Support contact app; removing it only removes the in-box support entry point.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.Getstarted'; displayName = 'Tips'; usage = 'Tips/tutorial app; no system dependency.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.MicrosoftOfficeHub'; displayName = 'Microsoft 365 (Office) hub'; usage = 'Office hub/promotional entry point; it does not remove installed Office.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.WindowsAlarms'; displayName = 'Clock (Alarms)'; usage = 'Alarm/timer/stopwatch app; keep if you use alarms.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.WindowsCamera'; displayName = 'Camera'; usage = 'Camera app; webcam use from other apps is unaffected, but the in-box camera UI goes away.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.WindowsSoundRecorder'; displayName = 'Sound Recorder'; usage = 'Voice recording app; no system dependency.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.MicrosoftStickyNotes'; displayName = 'Sticky Notes'; usage = 'Notes app; existing notes live in app data and are not deleted by removal.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.Whiteboard'; displayName = 'Microsoft Whiteboard'; usage = 'Collaboration canvas; no system dependency.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.PowerAutomateDesktop'; displayName = 'Power Automate'; usage = 'Desktop automation app; keep if you run flows.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.MixedReality.Portal'; displayName = 'Mixed Reality Portal'; usage = 'VR headset portal; keep if you use Windows Mixed Reality.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.Microsoft3DViewer'; displayName = '3D Viewer'; usage = '3D model viewer; no system dependency.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'Microsoft.Todos'; displayName = 'Microsoft To Do'; usage = 'Task app; no system dependency.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Consumer'; name = 'MicrosoftCorporationII.QuickAssist'; displayName = 'Quick Assist'; usage = 'Remote-assistance app used for support sessions; keep if you provide or receive support.'; reversibility = 'StoreReinstallable' }
)

# NX12-004: only the Phone Link app is targeted. The Cross Device Service host is
# deliberately left alone (it also serves other cross-device features and the
# documented phone-PC linking policy belongs to NX13-012).
$script:Nx12PhoneLinkCatalog = @(
    [pscustomobject]@{ family = 'PhoneLink'; name = 'Microsoft.YourPhone'; displayName = 'Phone Link'; usage = 'Phone-PC linking app. Cross-device clipboard/linking policies are NX13-012 (declared conflict).'; reversibility = 'StoreReinstallable' }
)

# NX12-005: the Xbox app only. Identity, Gaming Services, Game Bar and the
# callable UI package are protected above.
$script:Nx12XboxCatalog = @(
    [pscustomobject]@{ family = 'Xbox'; name = 'Microsoft.GamingApp'; displayName = 'Xbox app'; usage = 'Xbox/Game Pass client UI; Game Pass users are excluded by evidence gate.'; reversibility = 'StoreReinstallable' }
    [pscustomobject]@{ family = 'Xbox'; name = 'Microsoft.XboxApp'; displayName = 'Xbox Console Companion (legacy)'; usage = 'Legacy Xbox app; only removed when explicitly selected.'; reversibility = 'StoreReinstallable' }
)

$script:Nx12CopilotCatalog = @(
    [pscustomobject]@{ family = 'Copilot'; name = 'Microsoft.Copilot'; displayName = 'Microsoft Copilot app'; usage = 'Consumer Copilot app. Microsoft documents uninstall via Remove-AppxPackage; the TurnOffWindowsCopilot policy is documented as legacy/near-deprecation.'; reversibility = 'StoreReinstallable' }
)

# NX12-007: communication apps. MSTeams is the unified work/personal client and
# therefore needs an explicit workload acknowledgement.
$script:Nx12CommunicationCatalog = @(
    [pscustomobject]@{ family = 'Communications'; name = 'Microsoft.SkypeApp'; displayName = 'Skype'; usage = 'Consumer Skype app; no system dependency.'; reversibility = 'StoreReinstallable'; acknowledge = $null }
    [pscustomobject]@{ family = 'Communications'; name = 'Microsoft.WindowsCommunicationsApps'; displayName = 'Mail and Calendar'; usage = 'Legacy Mail/Calendar app; new Outlook is a separate package. Contacts store remains in People.'; reversibility = 'StoreReinstallable'; acknowledge = $null }
    [pscustomobject]@{ family = 'Communications'; name = 'Microsoft.People'; displayName = 'People'; usage = 'Contact store UI; removing it affects contact management surfaces used by Mail/Calendar.'; reversibility = 'StoreReinstallable'; acknowledge = $null }
    [pscustomobject]@{ family = 'Communications'; name = 'Microsoft.OutlookForWindows'; displayName = 'new Outlook for Windows'; usage = 'New Outlook app; removing it removes the in-box Outlook entry point, not other mail clients.'; reversibility = 'StoreReinstallable'; acknowledge = $null }
    [pscustomobject]@{ family = 'Communications'; name = 'MSTeams'; displayName = 'Microsoft Teams'; usage = 'Unified Teams client (personal AND work/school). Work or school sign-in stops working after removal.'; reversibility = 'StoreReinstallable'; acknowledge = 'AcknowledgeTeamsWorkload' }
    [pscustomobject]@{ family = 'Communications'; name = 'MicrosoftTeams'; displayName = 'Microsoft Teams (legacy package identity)'; usage = 'Legacy Teams package identity; only present on older installations.'; reversibility = 'StoreReinstallable'; acknowledge = 'AcknowledgeTeamsWorkload' }
)

# NX12-013 new-user provisioning decisions, per app family. Only consumer
# families listed here can be deprovisioned; app families owned by other NX12
# entries (Phone Link, Xbox, Copilot, communications) are deliberately absent.
$script:Nx12ProvisioningFamilies = @(
    [pscustomobject]@{ familyId = 'ConsumerNewsWeather'; displayName = 'News & Weather'; packages = @('Microsoft.BingNews','Microsoft.BingWeather'); note = 'Consumer content apps; no dependency.' }
    [pscustomobject]@{ familyId = 'ConsumerGames'; displayName = 'Consumer games'; packages = @('Microsoft.MicrosoftSolitaireCollection'); note = 'Solitaire bundle; no dependency.' }
    [pscustomobject]@{ familyId = 'ConsumerMedia'; displayName = 'Consumer media'; packages = @('Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.Clipchamp'); note = 'Player/editor apps; codecs are OS components and are not touched.' }
    [pscustomobject]@{ familyId = 'ConsumerProductivity'; displayName = 'Consumer productivity'; packages = @('Microsoft.MicrosoftOfficeHub','Microsoft.Todos','Microsoft.PowerAutomateDesktop','Microsoft.Whiteboard','Microsoft.MicrosoftStickyNotes'); note = 'Hub/notes/automation apps; does not uninstall Office.' }
    [pscustomobject]@{ familyId = 'SupportApps'; displayName = 'Support & feedback apps'; packages = @('Microsoft.WindowsFeedbackHub','Microsoft.GetHelp','Microsoft.Getstarted','MicrosoftCorporationII.QuickAssist'); note = 'Feedback/tips/support entry points.' }
    [pscustomobject]@{ familyId = 'MixedReality3D'; displayName = 'Mixed Reality & 3D'; packages = @('Microsoft.MixedReality.Portal','Microsoft.Microsoft3DViewer'); note = 'VR/3D viewers; keep if you use a headset.' }
)

# Known OEM/promotional title fragments used only to *nominate* candidates for
# NX12-003. Selection stays per package and per-app consent is mandatory; the
# candidate rule also requires a non-Microsoft publisher.
$script:Nx12OemPromotionPatterns = @(
    'McAfee','Norton','WildTangent','Booking.com','Spotify','Disney','Prime Video','Amazon',
    'TikTok','Facebook','Instagram','Candy Crush','LinkedIn','Netflix','Dropbox','Evernote',
    'WinZip','CyberLink','Dolby','Priceline','Expedia','Hulu','iHeartRadio','Pandora','Snapchat'
)

# NX12-012 capability allow-list. Anything not matched here is refused - this is
# an allow-list, never a deny-list sweep. Prefix entries (trailing '.') cover the
# versioned RSAT capability names.
$script:Nx12CapabilityAllowList = @(
    [pscustomobject]@{ name = 'MathRecognizer'; displayName = 'Math Recognizer'; usage = 'Math Input Panel recognition. Reinstall: Settings > Optional features or Add-WindowsCapability.'; reinstall = 'Add-WindowsCapability -Online -Name MathRecognizer' }
    [pscustomobject]@{ name = 'Media.WindowsMediaPlayer'; displayName = 'Windows Media Player (legacy)'; usage = 'Legacy player; modern Media Player is a Store app and is not touched.'; reinstall = 'Add-WindowsCapability -Online -Name Media.WindowsMediaPlayer' }
    [pscustomobject]@{ name = 'Microsoft.Windows.PowerShell.ISE'; displayName = 'Windows PowerShell ISE'; usage = 'Optional scripting IDE; PowerShell itself is not affected.'; reinstall = 'Add-WindowsCapability -Online -Name Microsoft.Windows.PowerShell.ISE' }
    [pscustomobject]@{ name = 'Microsoft.Windows.WordPad'; displayName = 'WordPad'; usage = 'Optional rich-text editor; not present on newer builds by default.'; reinstall = 'Add-WindowsCapability -Online -Name Microsoft.Windows.WordPad' }
    [pscustomobject]@{ name = 'OpenSSH.Client'; displayName = 'OpenSSH Client'; usage = 'SSH client used by developers; keep for development workloads.'; reinstall = 'Add-WindowsCapability -Online -Name OpenSSH.Client' }
    [pscustomobject]@{ name = 'Print.Management.Console'; displayName = 'Print Management Console'; usage = 'Administrative print console; printing itself is unaffected.'; reinstall = 'Add-WindowsCapability -Online -Name Print.Management.Console' }
    [pscustomobject]@{ name = 'StepsRecorder'; displayName = 'Steps Recorder'; usage = 'Diagnostic screen recorder; no system dependency.'; reinstall = 'Add-WindowsCapability -Online -Name StepsRecorder' }
    [pscustomobject]@{ name = 'VBSCRIPT'; displayName = 'VBScript'; usage = 'Legacy scripting engine; some enterprise scripts depend on it.'; reinstall = 'Add-WindowsCapability -Online -Name VBSCRIPT' }
    [pscustomobject]@{ name = 'WMIC'; displayName = 'WMIC'; usage = 'Deprecated WMI command-line tool; PowerShell CIM cmdlets remain.'; reinstall = 'Add-WindowsCapability -Online -Name WMIC' }
    [pscustomobject]@{ name = 'Browser.InternetExplorer'; displayName = 'Internet Explorer 11'; usage = 'IE mode/legacy LOB browser; keep if line-of-business sites require it.'; reinstall = 'Add-WindowsCapability -Online -Name Browser.InternetExplorer' }
    [pscustomobject]@{ name = 'App.Support.QuickAssist'; displayName = 'Quick Assist (capability form)'; usage = 'Remote assistance; keep if you provide or receive support.'; reinstall = 'Add-WindowsCapability -Online -Name App.Support.QuickAssist' }
    [pscustomobject]@{ name = 'App.WirelessDisplay.Connect'; displayName = 'Wireless Display'; usage = 'Miracast projection; keep if you project to TVs/projectors.'; reinstall = 'Add-WindowsCapability -Online -Name App.WirelessDisplay.Connect' }
    [pscustomobject]@{ name = 'XPS.Viewer'; displayName = 'XPS Viewer'; usage = 'XPS document viewer; no system dependency.'; reinstall = 'Add-WindowsCapability -Online -Name XPS.Viewer' }
    [pscustomobject]@{ name = 'Rsat.'; displayName = 'RSAT administration tools'; usage = 'Remote Server Administration Tools; administrative, keep for IT work.'; reinstall = 'Add-WindowsCapability -Online -Name <exact capability name>' }
)

# Capability patterns that are refused even if someone asks for them. The
# allow-list is the primary gate; these exist so a future allow-list edit cannot
# turn a language pack, biometric component or framework into a removal target.
$script:Nx12CapabilityProtectedPatterns = @(
    'Language.*', 'Hello.*', 'NetFX.*', 'Microsoft.Windows.Notepad*',
    'Microsoft.Windows.Paint*', 'Microsoft.Windows.Shell*', 'Microsoft.Windows.Client*',
    'Microsoft.Windows.Photos*', 'OpenSSH.Server*'
)

# ============================================================================
# Internal helpers
# ============================================================================

function New-Nx12Step {
    param([int]$Seq, [string]$Name, [string]$Outcome, [string]$Detail)
    return [pscustomobject][ordered]@{ step = $Seq; name = $Name; outcome = $Outcome; detail = $Detail }
}

function Test-Nx12Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Nx12JournalReady {
    # No mutation without an initialized, capture-Complete journal (adopt #2).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JournalRoot)
    if ([string]::IsNullOrWhiteSpace($JournalRoot)) { throw 'NX12: a journal root is required (journal-first invariant)' }
    $state = Read-NxManifest -Path $JournalRoot
    if (-not $state.present) { throw "NX12: journal not initialized at '$JournalRoot' - refusing to mutate (run NX16-004 pre-flight first)" }
    if ([string]$state.manifest.captureStatus -ne 'Complete') {
        throw "NX12: journal captureStatus is '$($state.manifest.captureStatus)' - destructive steps refuse unless capture is Complete"
    }
}

function Assert-Nx12ApprovalEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TweakId,
        [string]$Approval = 'Selection',
        [string]$ApprovalModel = 'SelectionPlusConfirmation',
        [switch]$Approved,
        [switch]$Plan
    )
    if ($Plan) { return }
    if (-not $Approved) { throw "$TweakId : real application requires -Approved (nothing is removed without explicit approval evidence)" }
    if ($ApprovalModel -eq 'ExplicitConsent' -and $Approval -ne 'ExplicitConsent') {
        throw "$TweakId : this entry's approval model is ExplicitConsent; pass -Approval ExplicitConsent"
    }
}

function Test-Nx12PackageProtected {
    <#
        NX12-002 guard. Matching order: exact definitions, then patterns, then
        the SignatureKind='System' OS-component rule. Returns a decision object
        (never throws) so callers can report a refusal instead of failing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageName,
        [string]$SignatureKind
    )
    $name = ([string]$PackageName).Trim()
    foreach ($d in @($script:Nx12ProtectionDefinitions | Where-Object { $_.exact })) {
        if ([string]::Equals([string]$d.exact, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject][ordered]@{ protected = $true; packageName = $name; ruleId = $d.id; category = $d.category; matchedBy = 'exact'; reason = $d.reason }
        }
    }
    foreach ($d in @($script:Nx12ProtectionDefinitions | Where-Object { $_.pattern })) {
        if ($name -like $d.pattern) {
            return [pscustomobject][ordered]@{ protected = $true; packageName = $name; ruleId = $d.id; category = $d.category; matchedBy = 'pattern'; reason = $d.reason }
        }
    }
    if ([string]::Equals($SignatureKind, 'System', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject][ordered]@{ protected = $true; packageName = $name; ruleId = 'system-signature'; category = 'OS component'; matchedBy = 'signature'; reason = "Package is system-signed (SignatureKind='System'); NEXTRIX protects OS components by default." }
    }
    return [pscustomobject][ordered]@{ protected = $false; packageName = $name; ruleId = $null; category = $null; matchedBy = $null; reason = 'not on the protected list and not system-signed' }
}

function Get-Nx12PackageNameFromProvisionedName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProvisionedName)
    $n = [string]$ProvisionedName
    if ($n -match '^(.+?)_[0-9]') { return $Matches[1] }
    return ($n -split '_')[0]
}

function Get-Nx12PackageSnapshot {
    <# Read-only snapshot. Every failed read becomes an uncertainty string; a
       failed read never becomes a guessed value. #>
    [CmdletBinding()]
    param(
        [switch]$IncludeAllUsers,
        [switch]$IncludeProvisioned
    )
    $unc = New-Object System.Collections.Generic.List[string]
    $current = @(); $all = @(); $prov = @()
    $allUsersAvailable = $false
    try { $current = @(Get-AppxPackage -ErrorAction Stop) }
    catch { $unc.Add('Get-AppxPackage (current user) failed: ' + [string]$_.Exception.Message) }
    if ($IncludeAllUsers) {
        try { $all = @(Get-AppxPackage -AllUsers -ErrorAction Stop); $allUsersAvailable = $true }
        catch { $unc.Add('Get-AppxPackage -AllUsers failed (elevation or Appx subsystem unavailable): ' + [string]$_.Exception.Message) }
    }
    if ($IncludeProvisioned) {
        try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) }
        catch { $unc.Add('Get-AppxProvisionedPackage -Online failed (DISM/Appx provisioning unavailable): ' + [string]$_.Exception.Message) }
    }
    $currentFull = @{}
    foreach ($p in $current) { if ($p.PackageFullName) { $currentFull[[string]$p.PackageFullName] = $true } }
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($p in $all) {
        $records.Add((ConvertTo-Nx12PackageRecord -Package $p -InCurrentUser $currentFull.ContainsKey([string]$p.PackageFullName)))
    }
    if (-not $allUsersAvailable) {
        foreach ($p in $current) {
            $records.Add((ConvertTo-Nx12PackageRecord -Package $p -InCurrentUser $true))
        }
    }
    $provRecords = New-Object System.Collections.Generic.List[object]
    foreach ($p in $prov) {
        $provRecords.Add([pscustomobject][ordered]@{
            displayName     = [string]$p.DisplayName
            packageName     = [string]$p.PackageName
            baseName        = Get-Nx12PackageNameFromProvisionedName -ProvisionedName ([string]$p.PackageName)
            version         = [string]$p.Version
            architecture    = [string]$p.Architecture
            installLocation = [string]$p.InstallLocation
        })
    }
    return [pscustomobject][ordered]@{
        packages           = $records.ToArray()
        provisioned        = $provRecords.ToArray()
        allUsersAvailable  = $allUsersAvailable
        provisionedAvailable = ($provRecords.Count -gt 0 -or $unc.Count -eq 0)
        uncertainty        = $unc.ToArray()
    }
}

function ConvertTo-Nx12PackageRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package, [bool]$InCurrentUser)
    $deps = @()
    try {
        foreach ($d in @($Package.Dependencies)) {
            if ($null -ne $d -and $d.PackageFamilyName) { $deps += [string]$d.PackageFamilyName }
        }
    } catch { }
    return [pscustomobject][ordered]@{
        name            = [string]$Package.Name
        fullName        = [string]$Package.PackageFullName
        family          = [string]$Package.PackageFamilyName
        version         = [string]$Package.Version
        architecture    = [string]$Package.Architecture
        publisher       = [string]$Package.Publisher
        signatureKind   = [string]$Package.SignatureKind
        installLocation = [string]$Package.InstallLocation
        isFramework     = [bool]$Package.IsFramework
        dependencies    = @($deps | Sort-Object -Unique)
        inCurrentUser   = $InCurrentUser
    }
}

function Get-Nx12DependencyIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)
    $index = @{}
    foreach ($r in $Records) {
        foreach ($dep in @($r.dependencies)) {
            $key = [string]$dep
            if (-not $index.ContainsKey($key)) { $index[$key] = New-Object System.Collections.Generic.List[string] }
            if (-not $index[$key].Contains([string]$r.name)) { $index[$key].Add([string]$r.name) }
        }
    }
    return $index
}

function Sort-Nx12RemovalOrder {
    <# Dependents-first ordering for a selection. Returns ordered names plus any
       cycle that could not be ordered (cycles are refused by the engine). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PackageNames, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)
    $names = @($PackageNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $familyToName = @{}
    $depsOf = @{}
    foreach ($n in $names) {
        $depsOf[$n] = @()
        foreach ($r in @($Records | Where-Object { $_.name -eq $n })) {
            if ($r.family) { $familyToName[[string]$r.family] = $n }
        }
    }
    foreach ($n in $names) {
        $d = New-Object System.Collections.Generic.List[string]
        foreach ($r in @($Records | Where-Object { $_.name -eq $n })) {
            foreach ($fam in @($r.dependencies)) {
                if ($familyToName.ContainsKey([string]$fam)) {
                    $depName = $familyToName[[string]$fam]
                    if ($depName -ne $n -and -not $d.Contains($depName)) { $d.Add($depName) }
                }
            }
        }
        $depsOf[$n] = $d.ToArray()
    }
    $dependentCount = @{}
    foreach ($n in $names) { $dependentCount[$n] = 0 }
    foreach ($n in $names) {
        foreach ($dep in @($depsOf[$n])) { $dependentCount[$dep] = [int]$dependentCount[$dep] + 1 }
    }
    $remaining = New-Object System.Collections.Generic.List[string]
    foreach ($n in $names) { $remaining.Add($n) }
    $ordered = New-Object System.Collections.Generic.List[string]
    $cycle = @()
    while ($remaining.Count -gt 0) {
        $pick = $null
        foreach ($n in $remaining) { if ([int]$dependentCount[$n] -eq 0) { $pick = $n; break } }
        if ($null -eq $pick) {
            $cycle = @($remaining.ToArray())
            foreach ($n in $remaining) { $ordered.Add($n) }
            break
        }
        $ordered.Add($pick)
        $null = $remaining.Remove($pick)
        foreach ($dep in @($depsOf[$pick])) {
            if ($dependentCount.ContainsKey($dep)) { $dependentCount[$dep] = [int]$dependentCount[$dep] - 1 }
        }
    }
    return [pscustomobject][ordered]@{ order = $ordered.ToArray(); cycle = $cycle }
}

function Get-Nx12LiveInstalledNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PackageNames, [switch]$AllUsers)
    $installed = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($PackageNames | Sort-Object -Unique)) {
        try {
            $live = @()
            if ($AllUsers) { $live = @(Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue) }
            else { $live = @(Get-AppxPackage -Name $n -ErrorAction SilentlyContinue) }
            if ($live.Count -gt 0) { $installed.Add($n) }
        } catch { }
    }
    return $installed.ToArray()
}

function Get-Nx12GamePassEvidence {
    <# NX12-005 exclusion evidence. Strong evidence = installed Xbox/Game Pass
       game folders. Gaming Services presence is weak evidence (it ships with
       Windows) and is reported without blocking on its own. #>
    [CmdletBinding()]
    param()
    $strong = New-Object System.Collections.Generic.List[string]
    $weak = New-Object System.Collections.Generic.List[string]
    $drive = $env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = 'C:' }
    $xboxRoot = Join-Path $drive 'XboxGames'
    if (Test-Path -LiteralPath $xboxRoot) {
        try {
            $games = @(Get-ChildItem -LiteralPath $xboxRoot -Directory -ErrorAction SilentlyContinue)
            if ($games.Count -gt 0) { $strong.Add("Installed Xbox/Game Pass game folders found under $xboxRoot ($($games.Count) folder(s))") }
        } catch { $weak.Add("Could not enumerate $xboxRoot : $($_.Exception.Message)") }
    }
    try {
        if (@(Get-AppxPackage -Name 'Microsoft.GamingServices' -ErrorAction SilentlyContinue).Count -gt 0) {
            $weak.Add('Gaming Services package is present (ships broadly; not proof of a Game Pass subscription)')
        }
    } catch { }
    try {
        if (@(Get-Service -Name 'GamingServices' -ErrorAction SilentlyContinue).Count -gt 0) {
            $weak.Add('GamingServices service exists')
        }
    } catch { }
    return [pscustomobject][ordered]@{
        strongEvidence = $strong.ToArray()
        weakEvidence   = $weak.ToArray()
        gamePassLikely = ($strong.Count -gt 0)
        excluded       = ($strong.Count -gt 0)
    }
}

function Get-Nx12FamilyCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Consumer','Oem','PhoneLink','Xbox','Copilot','Communications','Provisioned','ProvisioningPolicy')][string]$Family)
    switch ($Family) {
        'Consumer'          { return [pscustomobject]@{ family = 'Consumer'; displayName = 'Consumer apps'; writeFunction = 'Set-NxConsumerAppState'; approvalModel = 'SelectionPlusConfirmation'; defaultScope = 'CurrentUser'; entries = @($script:Nx12ConsumerCatalog) } }
        'Oem'               { return [pscustomobject]@{ family = 'Oem'; displayName = 'OEM / promotional third-party apps'; writeFunction = 'Remove-NxOemPromotionalApp'; approvalModel = 'ExplicitConsent'; defaultScope = 'CurrentUser'; entries = @() } }
        'PhoneLink'         { return [pscustomobject]@{ family = 'PhoneLink'; displayName = 'Phone Link'; writeFunction = 'Set-NxPhoneLinkState'; approvalModel = 'SelectionPlusConfirmation'; defaultScope = 'CurrentUser'; entries = @($script:Nx12PhoneLinkCatalog) } }
        'Xbox'              { return [pscustomobject]@{ family = 'Xbox'; displayName = 'Xbox app'; writeFunction = 'Set-NxXboxAppState'; approvalModel = 'SelectionPlusConfirmation'; defaultScope = 'CurrentUser'; entries = @($script:Nx12XboxCatalog) } }
        'Copilot'           { return [pscustomobject]@{ family = 'Copilot'; displayName = 'Microsoft Copilot app'; writeFunction = 'Set-NxCopilotState'; approvalModel = 'SelectionPlusConfirmation'; defaultScope = 'CurrentUser'; entries = @($script:Nx12CopilotCatalog) } }
        'Communications'    { return [pscustomobject]@{ family = 'Communications'; displayName = 'Communication apps'; writeFunction = 'Set-NxCommunicationAppState'; approvalModel = 'SelectionPlusConfirmation'; defaultScope = 'CurrentUser'; entries = @($script:Nx12CommunicationCatalog) } }
        'Provisioned'       { return [pscustomobject]@{ family = 'Provisioned'; displayName = 'Provisioned packages'; writeFunction = 'Remove-NxProvisionedPackageControl'; approvalModel = 'ExplicitConsent'; defaultScope = 'Provisioned'; entries = @() } }
        'ProvisioningPolicy'{ return [pscustomobject]@{ family = 'ProvisioningPolicy'; displayName = 'New-user provisioning policy'; writeFunction = 'Set-NxNewUserProvisioningPolicy'; approvalModel = 'ExplicitConsent'; defaultScope = 'Provisioned'; entries = @() } }
    }
}

function Get-Nx12OemCandidates {
    <# Read-only OEM/promotional candidate nomination. A package qualifies only
       when: publisher is not Microsoft, it is not protected, it is not a
       framework, and either it is provisioned (preinstalled) or it matches a
       known promotional title fragment. User-installed apps are excluded unless
       -IncludeUserInstalled is explicitly supplied. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot, [switch]$IncludeUserInstalled)
    $provisionedNames = @{}
    foreach ($p in @($Snapshot.provisioned)) { $provisionedNames[$p.baseName.ToLowerInvariant()] = $true }
    # Never re-nominate anything owned by another NX12 entry, and never a
    # Microsoft-published consumer app: 003 is strictly third-party OEM/promo.
    $excluded = @{}
    foreach ($e in @($script:Nx12ConsumerCatalog + $script:Nx12CommunicationCatalog + $script:Nx12XboxCatalog + $script:Nx12CopilotCatalog + $script:Nx12PhoneLinkCatalog)) {
        $excluded[([string]$e.name).ToLowerInvariant()] = $true
    }
    $candidates = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($r in @($Snapshot.packages)) {
        if ($seen.ContainsKey($r.name.ToLowerInvariant())) { continue }
        $seen[$r.name.ToLowerInvariant()] = $true
        if ($r.publisher -match '(?i)CN=Microsoft Corporation') { continue }
        if ($r.name -match '^Microsoft[\.]') { continue }
        if ($excluded.ContainsKey($r.name.ToLowerInvariant())) { continue }
        if ($r.isFramework) { continue }
        $guard = Test-Nx12PackageProtected -PackageName $r.name -SignatureKind $r.signatureKind
        if ($guard.protected) { continue }
        $isProvisioned = $provisionedNames.ContainsKey($r.name.ToLowerInvariant())
        $promoMatch = $null
        foreach ($pat in @($script:Nx12OemPromotionPatterns)) {
            if ($r.name -match ('(?i)' + [regex]::Escape($pat))) { $promoMatch = $pat; break }
        }
        if (-not $isProvisioned -and -not $promoMatch -and -not $IncludeUserInstalled) { continue }
        $candidates.Add([pscustomobject][ordered]@{
            name          = $r.name
            displayName   = $null
            publisher     = $r.publisher
            signatureKind = $r.signatureKind
            provisioned   = $isProvisioned
            promoMatch    = $promoMatch
            userInstalled = (-not $isProvisioned -and -not $promoMatch)
            family        = $r.family
        })
    }
    # Add provisioned records that are not installed for the current user.
    foreach ($p in @($Snapshot.provisioned)) {
        if ($p.baseName -match '(?i)^Microsoft') { continue }
        if ($excluded.ContainsKey($p.baseName.ToLowerInvariant())) { continue }
        if (@($candidates | Where-Object { $_.name -eq $p.baseName }).Count -gt 0) { continue }
        $candidates.Add([pscustomobject][ordered]@{
            name          = $p.baseName
            displayName   = $p.displayName
            publisher     = $null
            signatureKind = $null
            provisioned   = $true
            promoMatch    = $null
            userInstalled = $false
            family        = $null
        })
    }
    return $candidates.ToArray()
}

function Test-Nx12CapabilityAllowed {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    foreach ($p in @($script:Nx12CapabilityProtectedPatterns)) {
        if ($Name -like $p) {
            return [pscustomobject]@{ allowed = $false; protected = $true; entry = $null; reason = "matches protected capability pattern '$p'" }
        }
    }
    foreach ($e in @($script:Nx12CapabilityAllowList)) {
        if ($e.name.EndsWith('.')) {
            if ($Name.StartsWith($e.name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ allowed = $true; protected = $false; entry = $e; reason = 'allow-listed by prefix' }
            }
        } elseif ([string]::Equals($e.name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ allowed = $true; protected = $false; entry = $e; reason = 'allow-listed by exact name' }
        }
    }
    return [pscustomobject]@{ allowed = $false; protected = $false; entry = $null; reason = 'not on the NX12 capability allow-list (never a blanket removal)' }
}

function Get-Nx12ReinstallRoute {
    [CmdletBinding()]
    param([string]$Reversibility, [string]$DisplayName)
    switch ($Reversibility) {
        'StoreReinstallable' { return ("Microsoft Store: open Library > install '" + $DisplayName + "' again, or run 'winget search `"" + $DisplayName + "`" --source msstore' and install the verified result (NX12-011).") }
        'MediaRequired'      { return "Requires the original app package/image payload: re-provision with Add-AppxProvisionedPackage -Online -PackagePath <appx> or reinstall Windows media content (NX12-011 reports the exact route)." }
        'OptionalFeature'    { return "Reinstall through Settings > Optional features, or Add-WindowsCapability -Online -Name <capability> (Windows Update or media source may be required)." }
        default              { return 'Reinstall route not documented for this item; review the NX12-010 ledger entry before acting.' }
    }
}

# ============================================================================
# NX12-002 - protected-dependency guard report (read-only)
# ============================================================================

function Get-NxProtectedDependencyReport {
    <#
    .SYNOPSIS
        NX12-002: report the protected-by-default list and enforce it.
    .DESCRIPTION
        Read-only. Enumerates installed/provisioned packages, matches them against
        the protected list (exact, pattern, system-signature rule), reports the
        WebView2 Win32-runtime distinction, and returns guard decisions for probe
        packages. This is the evidence surface for "report + refuse": the same
        Test-Nx12PackageProtected decision is what every removal engine calls.
    #>
    [CmdletBinding()]
    param(
        [string[]]$PackageNames = @('Microsoft.WindowsStore','Microsoft.DesktopAppInstaller','Microsoft.Win32WebViewHost','Microsoft.VCLibs.140.00','Microsoft.GamingServices','Microsoft.BingNews')
    )
    $snapshot = Get-Nx12PackageSnapshot -IncludeAllUsers -IncludeProvisioned
    $installed = @($snapshot.packages)
    $findings = New-Object System.Collections.Generic.List[object]
    $reported = @{}
    foreach ($r in $installed) {
        $guard = Test-Nx12PackageProtected -PackageName $r.name -SignatureKind $r.signatureKind
        if ($guard.protected) {
            $key = $r.name.ToLowerInvariant()
            if ($reported.ContainsKey($key)) { continue }
            $reported[$key] = $true
            $findings.Add([pscustomobject][ordered]@{
                packageName = $r.name
                displayName = $null
                installed   = $true
                provisioned = (@($snapshot.provisioned | Where-Object { $_.baseName -eq $r.name }).Count -gt 0)
                ruleId      = $guard.ruleId
                category    = $guard.category
                matchedBy   = $guard.matchedBy
                reason      = $guard.reason
            })
        }
    }
    foreach ($p in @($snapshot.provisioned)) {
        $key = $p.baseName.ToLowerInvariant()
        if ($reported.ContainsKey($key)) { continue }
        $guard = Test-Nx12PackageProtected -PackageName $p.baseName
        if ($guard.protected) {
            $reported[$key] = $true
            $findings.Add([pscustomobject][ordered]@{
                packageName = $p.baseName
                displayName = $p.displayName
                installed   = $false
                provisioned = $true
                ruleId      = $guard.ruleId
                category    = $guard.category
                matchedBy   = $guard.matchedBy
                reason      = $guard.reason
            })
        }
    }
    $probes = New-Object System.Collections.Generic.List[object]
    foreach ($n in @($PackageNames)) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        $live = @($installed | Where-Object { $_.name -eq $n } | Select-Object -First 1)
        $sig = $null
        if ($live.Count -gt 0) { $sig = $live[0].signatureKind }
        $guard = Test-Nx12PackageProtected -PackageName $n -SignatureKind $sig
        $probes.Add([pscustomobject][ordered]@{
            packageName = $n
            present     = ($live.Count -gt 0)
            protected   = [bool]$guard.protected
            ruleId      = $guard.ruleId
            matchedBy   = $guard.matchedBy
            reason      = $guard.reason
        })
    }
    # WebView2 runtime honesty: the Evergreen runtime is a Win32 component, not an
    # AppX package, so AppX removal commands never touch it. Report both facts.
    $webView2Runtime = $null
    $wvKeys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    foreach ($k in $wvKeys) {
        try {
            if (Test-Path -LiteralPath $k) {
                $props = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
                $webView2Runtime = [pscustomobject][ordered]@{
                    detected = $true
                    key      = $k
                    name     = [string]$props.name
                    version  = [string]$props.pv
                    note     = 'Win32 Evergreen WebView2 Runtime - outside AppX removal scope and never touched by NX12.'
                }
                break
            }
        } catch { }
    }
    if ($null -eq $webView2Runtime) {
        $webView2Runtime = [pscustomobject][ordered]@{ detected = $false; key = $null; name = $null; version = $null; note = 'No EdgeUpdate WebView2 client key found; the runtime may be absent or installed per-user. The WebView2 *host packages* remain protected by the list above.' }
    }
    $categories = @($script:Nx12ProtectionDefinitions | Group-Object category | ForEach-Object {
        [pscustomobject][ordered]@{ category = $_.Name; rules = $_.Count }
    })
    return [pscustomobject][ordered]@{
        tweakId        = 'NX12-002'
        readOnly       = $true
        protectionModel = 'exact name + wildcard pattern + SignatureKind=System OS-component rule'
        rules          = @($script:Nx12ProtectionDefinitions)
        categories     = $categories
        findings       = $findings.ToArray()
        probes         = $probes.ToArray()
        webView2Runtime = $webView2Runtime
        counts         = [pscustomobject][ordered]@{
            installedPackages = $installed.Count
            protectedFound    = $findings.Count
            systemSignedFound = @($installed | Where-Object { $_.signatureKind -eq 'System' } | ForEach-Object { $_.name } | Sort-Object -Unique).Count
        }
        notes          = @(
            'The guard is enforced inside Invoke-Nx12Removal/Invoke-Nx12ProvisionedRemoval/Invoke-Nx12CapabilityRemoval - a caller cannot bypass it by selecting a protected name.',
            'Store, Store Purchase App, App Installer, Edge/WebView2 host, VCLibs/.NET Native/UI.Xaml/Windows App Runtime, shell/security hosts and the Xbox identity/Gaming Services stack are protected by default.',
            'Research: 15+ apps depend on WebView2 (r4); ReviOS had to re-provision VCLibs to fix a wsappx loop (r2); removing Xbox-coupled components produced the ms-gamebar popup (r1).'
        )
        uncertainty    = @($snapshot.uncertainty)
    }
}

# ============================================================================
# NX12-001 / 003 / 004 / 005 / 006 / 007 / 009 / 013 - shared removal plan
# ============================================================================

function Get-Nx12RemovalPlan {
    <#
    .SYNOPSIS
        Read-only selection plan for a removal family (apply action of the
        removal entries). Emits candidates, protection/dependency/Game-Pass
        refusals, scope options and the exact write function to call.
    .DESCRIPTION
        No mutation and no journal write. Empty or partial selections are not
        expanded: the plan exists so the owner selects specific apps.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Consumer','Oem','PhoneLink','Xbox','Copilot','Communications','Provisioned','ProvisioningPolicy')][string]$Family,
        [string[]]$PackageNames = @(),
        [switch]$IncludeUserInstalled
    )
    $catalog = Get-Nx12FamilyCatalog -Family $Family
    $snapshot = Get-Nx12PackageSnapshot -IncludeAllUsers -IncludeProvisioned
    $index = Get-Nx12DependencyIndex -Records @($snapshot.packages)
    $selection = @($PackageNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    $selectionSet = @{}
    foreach ($s in $selection) { $selectionSet[$s.ToLowerInvariant()] = $true }

    $candidates = New-Object System.Collections.Generic.List[object]
    $entries = @($catalog.entries)
    if ($Family -eq 'Oem') { $entries = @(Get-Nx12OemCandidates -Snapshot $snapshot -IncludeUserInstalled:$IncludeUserInstalled) }

    if ($Family -eq 'Provisioned') {
        foreach ($p in @($snapshot.provisioned)) {
            $guard = Test-Nx12PackageProtected -PackageName $p.baseName
            $candidates.Add([pscustomobject][ordered]@{
                name          = $p.packageName
                displayName   = $p.displayName
                baseName      = $p.baseName
                provisioned   = $true
                installed     = (@($snapshot.packages | Where-Object { $_.name -eq $p.baseName }).Count -gt 0)
                protected     = [bool]$guard.protected
                refusalReason = $(if ($guard.protected) { $guard.reason } else { $null })
                selectable    = (-not $guard.protected)
                usage         = 'Provisioned package: removing it prevents installation for NEW users; existing user installs are unaffected (Microsoft-documented).'
            })
        }
    } elseif ($Family -eq 'ProvisioningPolicy') {
        foreach ($fam in @($script:Nx12ProvisioningFamilies)) {
            $rows = New-Object System.Collections.Generic.List[object]
            foreach ($pkg in @($fam.packages)) {
                $guard = Test-Nx12PackageProtected -PackageName $pkg
                $rows.Add([pscustomobject][ordered]@{
                    packageName = $pkg
                    provisioned = (@($snapshot.provisioned | Where-Object { $_.baseName -eq $pkg }).Count -gt 0)
                    installed   = (@($snapshot.packages | Where-Object { $_.name -eq $pkg }).Count -gt 0)
                    protected   = [bool]$guard.protected
                })
            }
            $candidates.Add([pscustomobject][ordered]@{
                familyId      = $fam.familyId
                displayName   = $fam.displayName
                packages      = $rows.ToArray()
                selectable    = (@($rows | Where-Object { $_.provisioned }).Count -gt 0)
                usage         = $fam.note
            })
        }
    } else {
        foreach ($e in $entries) {
            $recs = @($snapshot.packages | Where-Object { $_.name -eq $e.name })
            $guard = Test-Nx12PackageProtected -PackageName $e.name -SignatureKind $(if ($recs.Count -gt 0) { $recs[0].signatureKind } else { $null })
            $dependents = @()
            foreach ($r in $recs) {
                if ($index.ContainsKey([string]$r.family)) {
                    foreach ($d in $index[[string]$r.family]) {
                        if (-not $selectionSet.ContainsKey(([string]$d).ToLowerInvariant())) { $dependents += [string]$d }
                    }
                }
            }
            $blockedReason = $null
            if ($guard.protected) { $blockedReason = $guard.reason }
            elseif ($dependents.Count -gt 0) { $blockedReason = 'Installed packages depend on it: ' + (@($dependents | Sort-Object -Unique) -join ', ') }
            $provisioned = (@($snapshot.provisioned | Where-Object { $_.baseName -eq $e.name }).Count -gt 0)
            $selected = $selectionSet.ContainsKey($e.name.ToLowerInvariant())
            $candidates.Add([pscustomobject][ordered]@{
                name            = $e.name
                displayName     = $e.displayName
                present         = ($recs.Count -gt 0)
                provisioned     = $provisioned
                currentUser     = (@($recs | Where-Object { $_.inCurrentUser }).Count -gt 0)
                protected       = [bool]$guard.protected
                dependents      = @($dependents | Sort-Object -Unique)
                refusalReason   = $blockedReason
                selectable      = ($null -eq $blockedReason -and $recs.Count -gt 0)
                selected        = $selected
                usage           = $e.usage
                reversibility   = $e.reversibility
                reinstallRoute  = Get-Nx12ReinstallRoute -Reversibility $e.reversibility -DisplayName $e.displayName
                requiresAcknowledge = $(if ($e.PSObject.Properties['acknowledge']) { $e.acknowledge } else { $null })
            })
        }
    }

    $notes = New-Object System.Collections.Generic.List[string]
    $notes.Add('Removal is never automatic: select specific names and call ' + $catalog.writeFunction + ' -Approved -Approval ' + $catalog.approvalModel + '.')
    $notes.Add('Every removal journals package identity, scope and provisioned state BEFORE the change and labels the result Success-Irreversible.')
    $notes.Add('Removed inbox apps can return after a Windows feature update - this is documented Microsoft behavior (feature-update images re-apply provisioned apps); re-run the ledger (NX12-010) to see returned items.')
    if ($Family -eq 'Xbox') {
        $gp = Get-Nx12GamePassEvidence
        $notes.Add('Game Pass exclusion: strong evidence present = ' + [bool]$gp.gamePassLikely + '. ' + (@($gp.strongEvidence) -join '; '))
        if (@($gp.weakEvidence).Count -gt 0) { $notes.Add('Weak evidence (not blocking on its own): ' + (@($gp.weakEvidence) -join '; ')) }
    }
    if ($Family -eq 'PhoneLink') {
        $notes.Add('Declared conflict with NX13-012 (phone-PC linking policy). Removing the app and disabling the policy attack the same feature; choose one.')
    }
    if ($Family -eq 'Communications') {
        $notes.Add('MSTeams is the unified personal AND work/school client: removal requires -AcknowledgeTeamsWorkload and breaks work/school sign-in.')
    }
    if ($Family -eq 'Copilot') {
        $notes.Add('Microsoft documents the Copilot app uninstall (Get-AppxPackage Microsoft.Copilot | Remove-AppxPackage) and marks TurnOffWindowsCopilot legacy/near-deprecation; NEXTRIX does not write the deprecated policy.')
        $notes.Add('Copilot availability is build/region/update dependent: absence of the package is reported, never treated as an error.')
    }
    if ($Family -eq 'Provisioned' -or $Family -eq 'ProvisioningPolicy') {
        $notes.Add('Provisioned removal affects only NEW user profiles: packages are not installed when new accounts are created; existing installs are untouched (Microsoft-documented).')
        $notes.Add('Re-provisioning needs the original package payload (media/Store download); the ledger labels this MediaRequired.')
    }

    return [pscustomobject][ordered]@{
        tweakId        = $null
        readOnly       = $true
        family         = $Family
        displayName    = $catalog.displayName
        writeFunction  = $catalog.writeFunction
        approvalModel  = $catalog.approvalModel
        defaultScope   = $catalog.defaultScope
        scopeOptions   = @('CurrentUser','AllUsers')
        candidates     = $candidates.ToArray()
        counts         = [pscustomobject][ordered]@{
            candidates     = $candidates.Count
            selectable     = @($candidates | Where-Object { $_.selectable }).Count
            present        = @($candidates | Where-Object { $_.PSObject.Properties['present'] -and $_.present }).Count
            protected      = @($candidates | Where-Object { $_.protected }).Count
            provisioned    = @($candidates | Where-Object { $_.PSObject.Properties['provisioned'] -and $_.provisioned }).Count
        }
        notes          = $notes.ToArray()
        uncertainty    = @($snapshot.uncertainty)
    }
}

# ============================================================================
# Core removal engine - every AppX removal goes through here
# ============================================================================

function Invoke-Nx12Removal {
    <#
        Journal-first AppX removal. Used by the per-entry write functions only.
        Refuses: empty selection, protected package, installed dependents outside
        the selection, unresolved dependency cycle, Game Pass evidence (Xbox,
        enforced by the caller), missing elevation for AllUsers.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$TweakId,
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string]$ApprovalModel = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PackageNames,
        [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
        [switch]$RemoveProvisioned,
        [switch]$Approved,
        [switch]$Plan,
        [string]$Family = 'Consumer'
    )
    $isPlan = ($Plan.IsPresent -or $WhatIfPreference)
    $steps = New-Object System.Collections.Generic.List[object]
    $results = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    $unc = New-Object System.Collections.Generic.List[string]
    $selection = @($PackageNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)

    $summary = [pscustomobject][ordered]@{
        tweakId = $TweakId; family = $Family; plan = [bool]$isPlan; scope = $Scope
        selection = $selection; removedCount = 0; skippedCount = 0; refusedCount = 0
        failedCount = 0; irreversible = $true; results = @(); steps = @(); notes = @(); uncertainty = @()
    }

    if ($selection.Count -eq 0) {
        $notes.Add('NoSelection: an empty selection never means "all". Use Get-Nx12RemovalPlan to choose specific apps, then pass their names explicitly.')
        $summary.results = @()
        $summary.steps = @(New-Nx12Step 1 'selection' 'NoSelection' 'empty selection - read-only no-op')
        $summary.notes = $notes.ToArray()
        return $summary
    }

    Assert-Nx12ApprovalEvidence -TweakId $TweakId -Approval $Approval -ApprovalModel $ApprovalModel -Approved:$Approved -Plan:$isPlan
    if (-not $isPlan) { Assert-Nx12JournalReady -JournalRoot $JournalRoot }
    if ($Scope -eq 'AllUsers' -and -not $isPlan -and -not (Test-Nx12Elevated)) {
        throw "$TweakId : -Scope AllUsers requires administrator rights"
    }

    $snapshot = Get-Nx12PackageSnapshot -IncludeAllUsers -IncludeProvisioned
    foreach ($u in @($snapshot.uncertainty)) { $unc.Add($u) }
    $records = @($snapshot.packages)
    $index = Get-Nx12DependencyIndex -Records $records
    $ordered = Sort-Nx12RemovalOrder -PackageNames $selection -Records $records
    if (@($ordered.cycle).Count -gt 0) {
        $notes.Add('Dependency cycle detected in the selection: ' + (@($ordered.cycle) -join ', ') + '. The affected packages are refused (no blind ordering).')
    }
    $selectionSet = @{}
    foreach ($s in $selection) { $selectionSet[$s.ToLowerInvariant()] = $true }
    $seq = 0

    foreach ($name in @($ordered.order)) {
        if (@($ordered.cycle) -contains $name) {
            $seq++
            $results.Add([pscustomobject][ordered]@{ packageName = $name; outcome = 'Refused-DependencyCycle'; removed = $false; journalSeq = $null; verifySeq = $null; reason = 'selection contains a dependency cycle; order cannot be proven' })
            $steps.Add((New-Nx12Step $seq 'dependency-cycle' 'Refused' $name))
            $summary.refusedCount++
            continue
        }
        $recs = @($records | Where-Object { $_.name -eq $name })
        $guard = Test-Nx12PackageProtected -PackageName $name -SignatureKind $(if ($recs.Count -gt 0) { $recs[0].signatureKind } else { $null })
        if ($guard.protected) {
            $seq++
            $results.Add([pscustomobject][ordered]@{ packageName = $name; outcome = 'Refused-Protected'; removed = $false; journalSeq = $null; verifySeq = $null; reason = $guard.reason; ruleId = $guard.ruleId })
            $steps.Add((New-Nx12Step $seq 'protected-guard' 'Refused' "$name : $($guard.reason)"))
            $summary.refusedCount++
            continue
        }
        $provisionedMatches = @($snapshot.provisioned | Where-Object { $_.baseName -eq $name })
        $provisionedState = 'NotProvisioned'
        if ($provisionedMatches.Count -gt 0) { $provisionedState = 'Provisioned' }
        elseif (@($snapshot.uncertainty | Where-Object { $_ -like '*ProvisionedPackage*' }).Count -gt 0) { $provisionedState = 'Unknown' }

        if ($recs.Count -eq 0) {
            if (-not $RemoveProvisioned -or $provisionedMatches.Count -eq 0) {
                $seq++
                $results.Add([pscustomobject][ordered]@{ packageName = $name; outcome = 'Skipped-NotFound'; removed = $false; journalSeq = $null; verifySeq = $null; reason = 'package is not installed for the selected scope and no provisioned match was requested' })
                $steps.Add((New-Nx12Step $seq 'locate-package' 'Skipped' "$name not present"))
                $summary.skippedCount++
                continue
            }
        }

        # Dependency gate: any installed dependent still present outside the
        # selection blocks the removal. Dependents selected earlier in the
        # dependents-first order have already been removed, so a live re-check
        # is the accurate test.
        $blockers = @()
        foreach ($r in $recs) {
            if ($index.ContainsKey([string]$r.family)) {
                foreach ($d in $index[[string]$r.family]) {
                    if (-not $selectionSet.ContainsKey(([string]$d).ToLowerInvariant())) { $blockers += [string]$d }
                }
            }
        }
        $blockers = @($blockers | Sort-Object -Unique)
        $stillInstalled = @()
        if ($Scope -eq 'AllUsers') { $stillInstalled = @(Get-Nx12LiveInstalledNames -PackageNames $blockers -AllUsers) }
        else { $stillInstalled = @(Get-Nx12LiveInstalledNames -PackageNames $blockers) }
        if ($stillInstalled.Count -gt 0) {
            $seq++
            $results.Add([pscustomobject][ordered]@{ packageName = $name; outcome = 'Refused-Dependents'; removed = $false; journalSeq = $null; verifySeq = $null; reason = 'installed packages depend on it: ' + ($stillInstalled -join ', '); dependents = $stillInstalled })
            $steps.Add((New-Nx12Step $seq 'dependency-gate' 'Refused' "$name <- $($stillInstalled -join ', ')"))
            $summary.refusedCount++
            continue
        }

        $rev = 'StoreReinstallable'
        $displayName = $name
        $route = Get-Nx12ReinstallRoute -Reversibility $rev -DisplayName $displayName
        $journalSeqs = New-Object System.Collections.Generic.List[object]

        if ($recs.Count -eq 0) {
            # Provisioned-only handling is performed below; nothing to remove for users.
            $seq++
            $steps.Add((New-Nx12Step $seq 'user-removal' 'Skipped' "$name has no installed package for scope $Scope"))
        }

        $removeErrors = New-Object System.Collections.Generic.List[string]
        foreach ($rec in $recs) {
            $original = [pscustomobject][ordered]@{
                targetType       = 'appx'
                packageName      = $rec.name
                packageFullName  = $rec.fullName
                packageFamilyName = $rec.family
                version          = $rec.version
                architecture     = $rec.architecture
                publisher        = $rec.publisher
                signatureKind    = $rec.signatureKind
                installLocation  = $rec.installLocation
                scope            = $Scope
                provisionedState = $provisionedState
                currentUserInstalled = $rec.inCurrentUser
                dependencies     = @($rec.dependencies)
            }
            $modified = [pscustomobject][ordered]@{
                targetType       = 'appx'
                packageName      = $rec.name
                packageFamilyName = $rec.family
                scope            = $Scope
                removalState     = 'Removed'
                provisionedState = 'Unchanged'
                reversibility    = $rev
                reinstallRoute   = $route
                mechanism        = 'Remove-AppxPackage'
            }
            if ($isPlan) {
                $seq++
                $steps.Add((New-Nx12Step $seq 'plan-remove' 'Planned' "would Remove-AppxPackage -Package $($rec.fullName) $(if($Scope -eq 'AllUsers'){'-AllUsers'})"))
                continue
            }
            # Journal-first: identity + scope + provisioned state BEFORE mutation.
            $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
            $journalSeqs.Add($jr.seq)
            try {
                if ($Scope -eq 'AllUsers') { Remove-AppxPackage -Package $rec.fullName -AllUsers -ErrorAction Stop }
                else { Remove-AppxPackage -Package $rec.fullName -ErrorAction Stop }
                $seq++
                $steps.Add((New-Nx12Step $seq 'remove' 'Complete' "$($rec.fullName) ($Scope)"))
            } catch {
                $removeErrors.Add("$($rec.fullName): $([string]$_.Exception.Message)")
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
                $seq++
                $steps.Add((New-Nx12Step $seq 'remove' 'FAILED' "$($rec.fullName): $([string]$_.Exception.Message)"))
            }
        }

        # Optional provisioned removal in the same selection (per package only).
        $provisionedRemoved = 0
        if ($RemoveProvisioned -and $provisionedMatches.Count -gt 0) {
            foreach ($pm in $provisionedMatches) {
                $pguard = Test-Nx12PackageProtected -PackageName $pm.baseName
                if ($pguard.protected) { continue }
                $porig = [pscustomobject][ordered]@{
                    targetType       = 'appxProvisioned'
                    packageName      = $pm.packageName
                    baseName         = $pm.baseName
                    displayName      = $pm.displayName
                    version          = $pm.version
                    architecture     = $pm.architecture
                    installLocation  = $pm.installLocation
                    scope            = 'Provisioned'
                    provisionedState = 'Provisioned'
                }
                $pmod = [pscustomobject][ordered]@{
                    targetType       = 'appxProvisioned'
                    packageName      = $pm.packageName
                    baseName         = $pm.baseName
                    scope            = 'Provisioned'
                    removalState     = 'NotProvisioned'
                    provisionedState = 'NotProvisioned'
                    reversibility    = 'MediaRequired'
                    reinstallRoute   = (Get-Nx12ReinstallRoute -Reversibility 'MediaRequired' -DisplayName $pm.displayName)
                    mechanism        = 'Remove-AppxProvisionedPackage'
                }
                if ($isPlan) {
                    $seq++
                    $steps.Add((New-Nx12Step $seq 'plan-provisioned' 'Planned' "would Remove-AppxProvisionedPackage $($pm.packageName)"))
                    continue
                }
                $pjr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $porig -Modified $pmod -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
                $journalSeqs.Add($pjr.seq)
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $pm.packageName -ErrorAction Stop | Out-Null
                    $provisionedRemoved++
                    $seq++
                    $steps.Add((New-Nx12Step $seq 'provisioned-remove' 'Complete' $pm.packageName))
                } catch {
                    $removeErrors.Add("provisioned $($pm.packageName): $([string]$_.Exception.Message)")
                    $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $porig -Modified $pmod -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
                    $seq++
                    $steps.Add((New-Nx12Step $seq 'provisioned-remove' 'FAILED' ([string]$_.Exception.Message)))
                }
            }
        }

        if ($isPlan) {
            $results.Add([pscustomobject][ordered]@{ packageName = $name; outcome = 'Planned'; removed = $false; journalSeq = $null; verifySeq = $null; reason = "would remove $($recs.Count) package record(s)$(if($provisionedMatches.Count -gt 0){' + provisioned package'})" })
            continue
        }

        # Verify absence and journal the honest result label.
        $verify = $null
        if ($recs.Count -gt 0) {
            try {
                if ($Scope -eq 'AllUsers') { $live = @(Get-AppxPackage -AllUsers -Name $name -ErrorAction Stop) }
                else { $live = @(Get-AppxPackage -Name $name -ErrorAction Stop) }
                if ($live.Count -eq 0) {
                    $verify = [pscustomobject]@{ verified = $true; verification = 'VerifiedAbsent'; detail = 'package no longer present for the selected scope' }
                } else {
                    $verify = [pscustomobject]@{ verified = $false; verification = 'StillPresent'; detail = "$($live.Count) package record(s) still present" }
                }
            } catch {
                $verify = [pscustomobject]@{ verified = $false; verification = 'Unverified'; detail = 'verification read failed: ' + [string]$_.Exception.Message }
            }
        } else {
            $verify = [pscustomobject]@{ verified = $true; verification = 'VerifiedAbsent'; detail = 'nothing installed for this scope; provisioned state handled separately' }
        }

        $outcome = 'Success-Irreversible'
        if ($removeErrors.Count -gt 0) { $outcome = 'Failed' }
        elseif (-not $verify.verified) { $outcome = 'Success-Unverified' }

        foreach ($jseq in $journalSeqs) {
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original ([pscustomobject]@{ targetType = 'appx'; packageName = $name; scope = $Scope }) -Modified ([pscustomobject]@{ targetType = 'appx'; packageName = $name; scope = $Scope; removalState = 'Removed'; reversibility = $rev }) -Result $(if ($outcome -eq 'Failed') { 'Failed' } else { 'Success-Irreversible' }) -Verification $verify.verification -ErrorInfo (@($removeErrors) -join '; ') -Profiles $Profiles
        }

        $results.Add([pscustomobject][ordered]@{
            packageName = $name
            outcome     = $outcome
            removed     = ($recs.Count -gt 0 -and $removeErrors.Count -eq 0)
            provisionedRemoved = [bool]($provisionedRemoved -gt 0)
            journalSeq  = $(if ($journalSeqs.Count -gt 0) { @($journalSeqs.ToArray()) } else { @() })
            verification = $verify.verification
            reversibility = $rev
            reinstallRoute = $route
            reason      = $(if ($removeErrors.Count -gt 0) { @($removeErrors) -join '; ' } else { $verify.detail })
        })
        if ($outcome -eq 'Failed') { $summary.failedCount++ }
        elseif ($outcome -eq 'Success-Unverified') { $summary.removedCount++ }
        else { $summary.removedCount++ }
        $seq++
        $steps.Add((New-Nx12Step $seq 'verify' $(if ($outcome -eq 'Failed') { 'FAILED' } else { 'Verified' }) "$name : $($verify.verification)"))
    }

    $notes.Add('Result labels are honest: AppX/provisioned removals are labeled Success-Irreversible; restoration is the documented NX12-011 path, not a journal replay.')
    $notes.Add('Existing user profiles are unaffected by provisioned-only removal (Microsoft-documented).')
    $summary.results = $results.ToArray()
    $summary.steps = $steps.ToArray()
    $summary.notes = $notes.ToArray()
    $summary.uncertainty = $unc.ToArray()
    return $summary
}

# ============================================================================
# Entry write functions
# ============================================================================

function Set-NxConsumerAppState {
    <# NX12-001: per-app consumer removal. Selection is mandatory and restricted
       to the catalog. Empty selection returns the read-only plan (no-op). #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string[]]$PackageNames = @(),
        [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Plan
    )
    $catalogNames = @($script:Nx12ConsumerCatalog | ForEach-Object { $_.name })
    $selection = @($PackageNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    if ($selection.Count -eq 0) {
        $planReport = Get-Nx12RemovalPlan -Family Consumer
        return [pscustomobject][ordered]@{ tweakId = 'NX12-001'; outcome = 'NoSelection'; readOnly = $true; plan = $planReport; notes = @('Select specific consumer app names; an empty selection never means all.') }
    }
    $unknown = @($selection | Where-Object { $catalogNames -notcontains $_ })
    if ($unknown.Count -gt 0) {
        return [pscustomobject][ordered]@{ tweakId = 'NX12-001'; outcome = 'Refused-UnknownSelection'; readOnly = $true; refused = $unknown; notes = @('Only NX12-001 catalog names are accepted; use Get-Nx12RemovalPlan -Family Consumer.') }
    }
    $r = Invoke-Nx12Removal -JournalRoot $JournalRoot -TweakId 'NX12-001' -TweakVersion $TweakVersion -Approval $Approval -ApprovalModel 'SelectionPlusConfirmation' -Profiles $Profiles -PackageNames $selection -Scope $Scope -Approved:$Approved -Plan:$Plan -Family 'Consumer'
    return $r
}

function Remove-NxOemPromotionalApp {
    <# NX12-003: per-app OEM/promotional removal. Detection nominates; the caller
       must pass exact package footprints and ExplicitConsent. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PackageFootprints,
        [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
        [switch]$IncludeUserInstalled,
        [switch]$Approved,
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Plan
    )
    $snapshot = Get-Nx12PackageSnapshot -IncludeAllUsers -IncludeProvisioned
    $candidates = @(Get-Nx12OemCandidates -Snapshot $snapshot -IncludeUserInstalled:$IncludeUserInstalled)
    $selection = @($PackageFootprints | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    if ($selection.Count -eq 0) {
        return [pscustomobject][ordered]@{ tweakId = 'NX12-003'; outcome = 'NoSelection'; readOnly = $true; candidates = $candidates; notes = @('Pass exact package names/family names from Get-Nx12RemovalPlan -Family Oem.') }
    }
    $resolved = New-Object System.Collections.Generic.List[string]
    $refused = New-Object System.Collections.Generic.List[object]
    foreach ($s in $selection) {
        $hit = @($candidates | Where-Object { $_.name -eq $s -or $_.family -eq $s -or $_.displayName -eq $s } | Select-Object -First 1)
        if ($hit.Count -eq 0) {
            $refused.Add([pscustomobject]@{ selection = $s; reason = 'not nominated as an OEM/promotional candidate (use Get-Nx12RemovalPlan -Family Oem)' })
            continue
        }
        $resolved.Add([string]$hit[0].name)
    }
    if ($resolved.Count -eq 0) {
        return [pscustomobject][ordered]@{ tweakId = 'NX12-003'; outcome = 'Refused-NoCandidate'; readOnly = $true; refused = $refused.ToArray(); notes = @('No provided footprint matched an OEM/promotional candidate.') }
    }
    $r = Invoke-Nx12Removal -JournalRoot $JournalRoot -TweakId 'NX12-003' -TweakVersion $TweakVersion -Approval $Approval -ApprovalModel 'ExplicitConsent' -Profiles $Profiles -PackageNames $resolved.ToArray() -Scope $Scope -Approved:$Approved -Plan:$Plan -Family 'Oem'
    $r | Add-Member -NotePropertyName preflightRefusals -NotePropertyValue $refused.ToArray() -Force
    return $r
}

function Set-NxPhoneLinkState {
    <# NX12-004: Phone Link app removal. Conflict NX13-012 is reported, not hidden. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Plan
    )
    $policyNote = $null
    $mmx = Capture-NxRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'EnableMmx'
    if ($mmx.existed) { $policyNote = 'NX13-012 policy EnableMmx is already configured on this machine; removing the app as well is redundant (declared conflict).' }
    $r = Invoke-Nx12Removal -JournalRoot $JournalRoot -TweakId 'NX12-004' -TweakVersion $TweakVersion -Approval $Approval -ApprovalModel 'SelectionPlusConfirmation' -Profiles $Profiles -PackageNames @('Microsoft.YourPhone') -Scope $Scope -Approved:$Approved -Plan:$Plan -Family 'PhoneLink'
    $r | Add-Member -NotePropertyName conflicts -NotePropertyValue @('NX13-012') -Force
    if ($policyNote) { $r | Add-Member -NotePropertyName conflictNote -NotePropertyValue $policyNote -Force }
    return $r
}

function Set-NxXboxAppState {
    <# NX12-005: Xbox app removal with the Game Pass exclusion and the documented
       ms-gamebar/Game Bar fallout acknowledgement. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string[]]$PackageNames = @('Microsoft.GamingApp'),
        [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
        [switch]$AcknowledgeGameBarRisk,
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Plan
    )
    $catalogNames = @($script:Nx12XboxCatalog | ForEach-Object { $_.name })
    $selection = @($PackageNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    if ($selection.Count -eq 0) {
        return [pscustomobject][ordered]@{ tweakId = 'NX12-005'; outcome = 'NoSelection'; readOnly = $true; notes = @('Select Microsoft.GamingApp and/or the legacy Microsoft.XboxApp explicitly.') }
    }
    $unknown = @($selection | Where-Object { $catalogNames -notcontains $_ })
    if ($unknown.Count -gt 0) {
        return [pscustomobject][ordered]@{ tweakId = 'NX12-005'; outcome = 'Refused-UnknownSelection'; readOnly = $true; refused = $unknown }
    }
    $gp = Get-Nx12GamePassEvidence
    if ($gp.excluded) {
        return [pscustomobject][ordered]@{
            tweakId = 'NX12-005'; outcome = 'Refused-GamePass'; readOnly = $true
            reason = 'Game Pass evidence found: ' + (@($gp.strongEvidence) -join '; ')
            evidence = $gp
            conflicts = @('NX02-008','NX11-010')
            notes = @('Game Pass users are excluded from Xbox app removal; use NX11-010 service configuration instead if the goal is background service control.')
        }
    }
    if (-not $AcknowledgeGameBarRisk -and -not $Plan -and -not $WhatIfPreference) {
        return [pscustomobject][ordered]@{
            tweakId = 'NX12-005'; outcome = 'Refused-Acknowledgement'; readOnly = $true
            reason = 'Removing the Xbox app while Game Bar remains can produce the documented ms-gamebar controller popup (r1). Pass -AcknowledgeGameBarRisk after reading this note.'
            evidence = $gp
            conflicts = @('NX02-008','NX11-010')
        }
    }
    $r = Invoke-Nx12Removal -JournalRoot $JournalRoot -TweakId 'NX12-005' -TweakVersion $TweakVersion -Approval $Approval -ApprovalModel 'SelectionPlusConfirmation' -Profiles $Profiles -PackageNames $selection -Scope $Scope -Approved:$Approved -Plan:$Plan -Family 'Xbox'
    $r | Add-Member -NotePropertyName conflicts -NotePropertyValue @('NX02-008','NX11-010') -Force
    $r | Add-Member -NotePropertyName gamePassEvidence -NotePropertyValue $gp -Force
    return $r
}

function Set-NxCopilotState {
    <# NX12-006: build/capability-checked Copilot app removal using Microsoft's
       documented uninstall procedure. Never writes the deprecated policy. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Plan
    )
    $build = $null
    try { $build = Get-NxBuildReport } catch { $build = $null }
    if ($null -ne $build -and $build.readSucceeded -and [int]$build.build -lt 22631) {
        return [pscustomobject][ordered]@{ tweakId = 'NX12-006'; outcome = 'Refused-UnsupportedBuild'; readOnly = $true; reason = "build $($build.build) is outside the ADR-003 scope" }
    }
    $present = @(Get-AppxPackage -Name 'Microsoft.Copilot' -ErrorAction SilentlyContinue)
    if ($present.Count -eq 0) {
        return [pscustomobject][ordered]@{
            tweakId = 'NX12-006'; outcome = 'Skipped-NotFound'; readOnly = $true
            notes = @('Microsoft.Copilot is not installed on this machine/build. Copilot availability is build/region/update dependent; absence is reported, never treated as failure.')
            documentation = 'https://learn.microsoft.com/en-us/windows/client-management/manage-windows-copilot'
        }
    }
    $r = Invoke-Nx12Removal -JournalRoot $JournalRoot -TweakId 'NX12-006' -TweakVersion $TweakVersion -Approval $Approval -ApprovalModel 'SelectionPlusConfirmation' -Profiles $Profiles -PackageNames @('Microsoft.Copilot') -Scope $Scope -Approved:$Approved -Plan:$Plan -Family 'Copilot'
    $r | Add-Member -NotePropertyName documentedAlternative -NotePropertyValue 'Microsoft marks TurnOffWindowsCopilot as a legacy policy subject to near-term deprecation and points administrators to AppLocker. NEXTRIX does not write the deprecated policy and does not manage AppLocker.' -Force
    return $r
}

function Set-NxCommunicationAppState {
    <# NX12-007: per-app communication removal; Teams needs a workload ack. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PackageNames,
        [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
        [switch]$AcknowledgeTeamsWorkload,
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Plan
    )
    $catalogNames = @($script:Nx12CommunicationCatalog | ForEach-Object { $_.name })
    $selection = @($PackageNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    if ($selection.Count -eq 0) {
        return [pscustomobject][ordered]@{ tweakId = 'NX12-007'; outcome = 'NoSelection'; readOnly = $true; notes = @('Select specific communication app names; an empty selection never means all.') }
    }
    $unknown = @($selection | Where-Object { $catalogNames -notcontains $_ })
    if ($unknown.Count -gt 0) {
        return [pscustomobject][ordered]@{ tweakId = 'NX12-007'; outcome = 'Refused-UnknownSelection'; readOnly = $true; refused = $unknown }
    }
    $teamsSelected = @($selection | Where-Object { $_ -eq 'MSTeams' -or $_ -eq 'MicrosoftTeams' })
    if ($teamsSelected.Count -gt 0 -and -not $AcknowledgeTeamsWorkload -and -not $Plan -and -not $WhatIfPreference) {
        return [pscustomobject][ordered]@{ tweakId = 'NX12-007'; outcome = 'Refused-Acknowledgement'; readOnly = $true; reason = 'MSTeams is the unified personal AND work/school client. Pass -AcknowledgeTeamsWorkload to confirm work/school sign-in is no longer needed.' }
    }
    $r = Invoke-Nx12Removal -JournalRoot $JournalRoot -TweakId 'NX12-007' -TweakVersion $TweakVersion -Approval $Approval -ApprovalModel 'SelectionPlusConfirmation' -Profiles $Profiles -PackageNames $selection -Scope $Scope -Approved:$Approved -Plan:$Plan -Family 'Communications'
    return $r
}

# ============================================================================
# NX12-008 - removal scope report (read-only)
# ============================================================================

function Get-NxRemovalScopeReport {
    <# Per-user vs all-users vs provisioned semantics, with live counts. No SIDs
       or user identifiers are returned (privacy-safe reporting). #>
    [CmdletBinding()]
    param([string[]]$PackageNames = @())
    $snapshot = Get-Nx12PackageSnapshot -IncludeAllUsers -IncludeProvisioned
    $rows = New-Object System.Collections.Generic.List[object]
    $names = @($PackageNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    if ($names.Count -eq 0) {
        $names = @($snapshot.packages | Where-Object { $_.inCurrentUser } | ForEach-Object { $_.name } | Sort-Object -Unique | Select-Object -First 25)
    }
    foreach ($n in $names) {
        $current = @($snapshot.packages | Where-Object { $_.name -eq $n -and $_.inCurrentUser })
        $all = @($snapshot.packages | Where-Object { $_.name -eq $n })
        $prov = @($snapshot.provisioned | Where-Object { $_.baseName -eq $n })
        $rows.Add([pscustomobject][ordered]@{
            packageName          = $n
            currentUserInstalled = ($current.Count -gt 0)
            allUsersRecords      = $all.Count
            provisioned          = ($prov.Count -gt 0)
            provisionedNames     = @($prov | ForEach-Object { $_.packageName })
            scopes               = [pscustomobject][ordered]@{
                CurrentUser = 'Removes the package registration for the signed-in profile only. Other profiles keep it. Requires no elevation for your own profile.'
                AllUsers    = 'Removes the package registration for every profile on the machine. Requires administrator rights. Microsoft documents -AllUsers on Remove-AppxPackage for this scope.'
                Provisioned = 'Removes the provisioned package so NEW user profiles do not receive it. Existing profiles are NOT changed. Requires elevation and the DISM provisioning subsystem.'
            }
        })
    }
    return [pscustomobject][ordered]@{
        tweakId     = 'NX12-008'
        readOnly    = $true
        rows        = $rows.ToArray()
        counts      = [pscustomobject][ordered]@{
            packageRows        = $rows.Count
            allUsersAvailable  = [bool]$snapshot.allUsersAvailable
            provisionedCount   = @($snapshot.provisioned).Count
        }
        notes       = @(
            'Scope is journaled per removal (original.scope), so the ledger and the rollback report can distinguish profile-level from machine-level removals.',
            'AllUsers affects every profile and must be chosen deliberately; provisioned removal affects only future profiles (Microsoft-documented).',
            'User identifiers/SIDs are deliberately not reported: counts and booleans only.'
        )
        uncertainty = @($snapshot.uncertainty)
    }
}

# ============================================================================
# NX12-009 / NX12-013 - provisioned package control
# ============================================================================

function Invoke-Nx12ProvisionedRemoval {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$TweakId,
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [string]$ApprovalModel = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [Parameter(Mandatory)][string[]]$ProvisionedPackageNames,
        [switch]$Approved,
        [switch]$Plan
    )
    $isPlan = ($Plan.IsPresent -or $WhatIfPreference)
    $selection = @($ProvisionedPackageNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    $results = New-Object System.Collections.Generic.List[object]
    $steps = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    $summary = [pscustomobject][ordered]@{ tweakId = $TweakId; plan = [bool]$isPlan; scope = 'Provisioned'; removedCount = 0; skippedCount = 0; refusedCount = 0; failedCount = 0; irreversible = $true; existingUserInstallsUnaffected = $true; results = @(); steps = @(); notes = @(); uncertainty = @() }
    if ($selection.Count -eq 0) {
        $summary.notes = @('NoSelection: provide exact provisioned package names (PackageName identities), never a blanket sweep.')
        $summary.steps = @(New-Nx12Step 1 'selection' 'NoSelection' 'empty selection')
        return $summary
    }
    Assert-Nx12ApprovalEvidence -TweakId $TweakId -Approval $Approval -ApprovalModel $ApprovalModel -Approved:$Approved -Plan:$isPlan
    if (-not $isPlan) { Assert-Nx12JournalReady -JournalRoot $JournalRoot }
    if (-not $isPlan -and -not (Test-Nx12Elevated)) { throw "$TweakId : provisioned removal requires administrator rights" }
    $snapshot = Get-Nx12PackageSnapshot -IncludeProvisioned
    $unc = @($snapshot.uncertainty)
    if (@($snapshot.provisioned).Count -eq 0) {
        if (@($unc).Count -gt 0) {
            $summary.notes = @('No provisioned package list could be read (DISM/Appx provisioning unavailable). Nothing is removed and the result is Unverified, not success.')
            $summary.steps = @(New-Nx12Step 1 'provisioned-enumeration' 'Unverified' (@($unc) -join '; '))
        } else {
            $summary.notes = @('The provisioned package list is readable and empty: there is nothing to deprovision on this machine.')
            $summary.steps = @(New-Nx12Step 1 'provisioned-enumeration' 'Skipped' 'zero provisioned packages')
        }
        $summary.uncertainty = $unc
        return $summary
    }
    $seq = 0
    foreach ($pn in $selection) {
        $matches = @($snapshot.provisioned | Where-Object { $_.packageName -eq $pn -or $_.baseName -eq $pn })
        if ($matches.Count -eq 0) {
            $seq++
            $results.Add([pscustomobject][ordered]@{ packageName = $pn; outcome = 'Skipped-NotFound'; journalSeq = $null; reason = 'not in the provisioned package list' })
            $steps.Add((New-Nx12Step $seq 'locate-provisioned' 'Skipped' $pn))
            $summary.skippedCount++
            continue
        }
        foreach ($m in $matches) {
            $guard = Test-Nx12PackageProtected -PackageName $m.baseName
            if ($guard.protected) {
                $seq++
                $results.Add([pscustomobject][ordered]@{ packageName = $m.packageName; outcome = 'Refused-Protected'; journalSeq = $null; reason = $guard.reason; ruleId = $guard.ruleId })
                $steps.Add((New-Nx12Step $seq 'protected-guard' 'Refused' $m.baseName))
                $summary.refusedCount++
                continue
            }
            $original = [pscustomobject][ordered]@{
                targetType = 'appxProvisioned'; packageName = $m.packageName; baseName = $m.baseName
                displayName = $m.displayName; version = $m.version; architecture = $m.architecture
                installLocation = $m.installLocation; scope = 'Provisioned'; provisionedState = 'Provisioned'
            }
            $modified = [pscustomobject][ordered]@{
                targetType = 'appxProvisioned'; packageName = $m.packageName; baseName = $m.baseName
                scope = 'Provisioned'; removalState = 'NotProvisioned'; provisionedState = 'NotProvisioned'
                reversibility = 'MediaRequired'; reinstallRoute = (Get-Nx12ReinstallRoute -Reversibility 'MediaRequired' -DisplayName $m.displayName)
                mechanism = 'Remove-AppxProvisionedPackage'
            }
            if ($isPlan) {
                $seq++
                $steps.Add((New-Nx12Step $seq 'plan-provisioned' 'Planned' $m.packageName))
                $results.Add([pscustomobject][ordered]@{ packageName = $m.packageName; outcome = 'Planned'; journalSeq = $null; reason = 'would remove the provisioned package' })
                continue
            }
            $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $m.packageName -ErrorAction Stop | Out-Null
                $verify = 'Unverified'
                try {
                    $after = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.PackageName -eq $m.packageName })
                    if ($after.Count -eq 0) { $verify = 'VerifiedAbsent' } else { $verify = 'StillPresent' }
                } catch { $verify = 'Unverified' }
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result 'Success-Irreversible' -Verification $verify -Profiles $Profiles
                $seq++
                $steps.Add((New-Nx12Step $seq 'provisioned-remove' 'Complete' "$($m.packageName) : $verify"))
                $results.Add([pscustomobject][ordered]@{ packageName = $m.packageName; outcome = 'Success-Irreversible'; journalSeq = $jr.seq; verification = $verify; reversibility = 'MediaRequired' })
                $summary.removedCount++
            } catch {
                $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
                $seq++
                $steps.Add((New-Nx12Step $seq 'provisioned-remove' 'FAILED' ([string]$_.Exception.Message)))
                $results.Add([pscustomobject][ordered]@{ packageName = $m.packageName; outcome = 'Failed'; journalSeq = $jr.seq; reason = [string]$_.Exception.Message })
                $summary.failedCount++
            }
        }
    }
    $notes.Add('Provisioned removal affects NEW user profiles only; existing user installs are not removed (Microsoft-documented by Remove-AppxProvisionedPackage).')
    $notes.Add('Removal is labeled Success-Irreversible: re-provisioning needs the original package payload (media/Store download), reported as MediaRequired.')
    $summary.results = $results.ToArray()
    $summary.steps = $steps.ToArray()
    $summary.notes = $notes.ToArray()
    $summary.uncertainty = $unc
    return $summary
}

function Remove-NxProvisionedPackageControl {
    <# NX12-009: exact provisioned-package removal with identity journaling. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ProvisionedPackageNames,
        [switch]$Approved,
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Plan
    )
    return (Invoke-Nx12ProvisionedRemoval -JournalRoot $JournalRoot -TweakId 'NX12-009' -TweakVersion $TweakVersion -Approval $Approval -ApprovalModel 'ExplicitConsent' -Profiles $Profiles -ProvisionedPackageNames $ProvisionedPackageNames -Approved:$Approved -Plan:$Plan)
}

function Set-NxNewUserProvisioningPolicy {
    <# NX12-013: deprovision per app family (new-user policy). Opens the family
       catalog, refuses protected/unknown families, and delegates to the
       provisioned-removal engine. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$FamilyIds,
        [switch]$Approved,
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Plan
    )
    $ids = @($FamilyIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    if ($ids.Count -eq 0) {
        return [pscustomobject][ordered]@{ tweakId = 'NX12-013'; outcome = 'NoSelection'; readOnly = $true; families = @($script:Nx12ProvisioningFamilies); notes = @('Choose one or more family ids; an empty selection never means all.') }
    }
    $unknown = @($ids | Where-Object { @($script:Nx12ProvisioningFamilies | ForEach-Object { $_.familyId }) -notcontains $_ })
    if ($unknown.Count -gt 0) {
        return [pscustomobject][ordered]@{ tweakId = 'NX12-013'; outcome = 'Refused-UnknownFamily'; readOnly = $true; refused = $unknown; families = @($script:Nx12ProvisioningFamilies) }
    }
    $packages = New-Object System.Collections.Generic.List[string]
    foreach ($f in @($script:Nx12ProvisioningFamilies | Where-Object { $ids -contains $_.familyId })) {
        foreach ($p in @($f.packages)) { $packages.Add($p) }
    }
    $snapshot = Get-Nx12PackageSnapshot -IncludeProvisioned
    $provNames = @()
    foreach ($p in $packages) {
        $provNames += @($snapshot.provisioned | Where-Object { $_.baseName -eq $p } | ForEach-Object { $_.packageName })
    }
    if (@($provNames).Count -eq 0) {
        return [pscustomobject][ordered]@{
            tweakId = 'NX12-013'; outcome = 'Skipped-NotProvisioned'; readOnly = $true
            families = $ids; packages = $packages.ToArray()
            notes = @('None of the selected family packages is provisioned on this machine (or the provisioned list is unreadable). Nothing to deprovision.')
            uncertainty = @($snapshot.uncertainty)
        }
    }
    $r = Invoke-Nx12ProvisionedRemoval -JournalRoot $JournalRoot -TweakId 'NX12-013' -TweakVersion $TweakVersion -Approval $Approval -ApprovalModel 'ExplicitConsent' -Profiles $Profiles -ProvisionedPackageNames $provNames -Approved:$Approved -Plan:$Plan
    $r | Add-Member -NotePropertyName families -NotePropertyValue $ids -Force
    $r | Add-Member -NotePropertyName scopeOfChange -NotePropertyValue 'New user profiles only; existing installs are not removed.' -Force
    return $r
}

# ============================================================================
# NX12-010 - removal history & reversibility ledger (read-only)
# ============================================================================

function Get-NxRemovalLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$PackageName
    )
    $journal = Read-NxJournal -Path $JournalRoot
    if ($journal.integrityErrors.Count -gt 0) {
        return [pscustomobject][ordered]@{
            tweakId = 'NX12-010'; readOnly = $true; aborted = $true
            integrityErrors = @($journal.integrityErrors); entries = @(); counts = $null
            notes = @('Journal integrity errors: the ledger refuses to present a partial/tampered history as fact.')
        }
    }
    $relevant = @($journal.entries | Where-Object {
        $tt = [string]$_.original.targetType
        ($tt -eq 'appx' -or $tt -eq 'appxProvisioned' -or $tt -eq 'capability')
    })
    if (-not [string]::IsNullOrWhiteSpace($PackageName)) {
        $relevant = @($relevant | Where-Object {
            ([string]$_.original.packageName -eq $PackageName) -or ([string]$_.original.baseName -eq $PackageName) -or ([string]$_.original.name -eq $PackageName)
        })
    }
    $groups = @{}
    foreach ($e in $relevant) {
        $key = ([string]$e.original.targetType + '|' + [string]$e.original.packageName + '|' + [string]$e.original.scope).ToLowerInvariant()
        if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.Generic.List[object] }
        $groups[$key].Add($e)
    }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($key in $groups.Keys) {
        $list = @($groups[$key] | Sort-Object seq)
        $latest = $list[$list.Count - 1]
        $rev = [string]$latest.modified.reversibility
        if ([string]::IsNullOrWhiteSpace($rev)) { $rev = 'Unknown' }
        $state = [string]$latest.modified.removalState
        if ([string]::IsNullOrWhiteSpace($state)) { $state = [string]$latest.result }
        $present = $null
        $baseName = [string]$latest.original.packageName
        if ([string]$latest.original.targetType -eq 'appx') {
            try { $present = (@(Get-AppxPackage -Name $baseName -ErrorAction SilentlyContinue).Count -gt 0) } catch { $present = $null }
        }
        $status = 'Removed'
        if ($present -eq $true) { $status = 'ReturnedOrReinstalled' }
        elseif ($present -eq $false) { $status = 'Removed' }
        elseif ([string]$latest.original.targetType -ne 'appx') { $status = 'RemovedOrProvisionedStateChanged' }
        else { $status = 'Unknown' }
        if ([string]$latest.operation -eq 'failed' -or [string]$latest.result -like 'Failed*') { $status = 'RemovalIncomplete' }
        $items.Add([pscustomobject][ordered]@{
            targetType      = [string]$latest.original.targetType
            packageName     = [string]$latest.original.packageName
            displayName     = [string]$latest.original.displayName
            scope           = [string]$latest.original.scope
            provisionedState = [string]$latest.original.provisionedState
            lastSeq         = [int]$latest.seq
            lastOperation   = [string]$latest.operation
            lastResult      = [string]$latest.result
            verification    = [string]$latest.verification
            reversibility   = $rev
            status          = $status
            stillPresent    = $present
            reinstallRoute  = [string]$latest.modified.reinstallRoute
            historyCount    = $list.Count
        })
    }
    $sorted = @($items.ToArray() | Sort-Object packageName)
    $counts = [pscustomobject][ordered]@{
        entries             = $relevant.Count
        items               = $sorted.Count
        storeReinstallable  = @($sorted | Where-Object { $_.reversibility -eq 'StoreReinstallable' }).Count
        mediaRequired       = @($sorted | Where-Object { $_.reversibility -eq 'MediaRequired' }).Count
        optionalFeature     = @($sorted | Where-Object { $_.reversibility -eq 'OptionalFeature' }).Count
        returnedOrReinstalled = @($sorted | Where-Object { $_.status -eq 'ReturnedOrReinstalled' }).Count
        incomplete          = @($sorted | Where-Object { $_.status -eq 'RemovalIncomplete' }).Count
    }
    return [pscustomobject][ordered]@{
        tweakId   = 'NX12-010'
        readOnly  = $true
        aborted   = $false
        items     = $sorted
        counts    = $counts
        notes     = @(
            'Reversibility labels are honest: StoreReinstallable = Store/library reinstall; MediaRequired = original package payload/image needed; OptionalFeature = Settings > Optional features or Add-WindowsCapability.',
            'Status ReturnedOrReinstalled means the journal recorded a removal but the package is present now. Removed inbox apps can return after Windows feature updates (documented Microsoft behavior) or be reinstalled by the user/Store.',
            'This ledger is report-only. Restoration is the separate NX12-011 helper; NEXTRIX never silently re-installs anything.'
        )
    }
}

# ============================================================================
# NX12-011 - reinstallation helper (documented Store-based path)
# ============================================================================

function Restore-NxRemovedApp {
    <# Report mode is read-only and the default. Install mode requires
       -Mode Install -ProductId <Store product id> -Approved: NEXTRIX does not
       guess Store product ids. Reinstall attempts are journaled as 'verify'
       entries (never as apply), so rollback never mistakes them for removals. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string[]]$PackageNames = @(),
        [ValidateSet('Report','Install')][string]$Mode = 'Report',
        [string]$ProductId,
        [switch]$Approved,
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Plan
    )
    $isPlan = ($Plan.IsPresent -or $WhatIfPreference)
    $ledger = Get-NxRemovalLedger -JournalRoot $JournalRoot
    $removed = @($ledger.items | Where-Object { @('Removed','RemovedOrProvisionedStateChanged') -contains $_.status -and @('appx','capability','appxProvisioned') -contains $_.targetType })
    $names = @($PackageNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    if ($names.Count -gt 0) { $removed = @($removed | Where-Object { $names -contains $_.packageName }) }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in $removed) {
        $dn = $item.packageName
        if ($item.targetType -eq 'capability') {
            $rows.Add([pscustomobject][ordered]@{
                packageName   = $item.packageName
                displayName   = $dn
                targetType    = 'capability'
                reversibility = $item.reversibility
                storeSearch   = $null
                storeInstall  = $null
                storeUi       = 'Settings > System > Optional features > Add a feature (or Add-WindowsCapability -Online -Name <capability>)'
                note          = $(if ($item.reinstallRoute) { $item.reinstallRoute } else { 'Capability reinstall may require Windows Update or installation media.' })
            })
            continue
        }
        if ($item.targetType -eq 'appxProvisioned') {
            $rows.Add([pscustomobject][ordered]@{
                packageName   = $item.packageName
                displayName   = $dn
                targetType    = 'appxProvisioned'
                reversibility = $item.reversibility
                storeSearch   = $null
                storeInstall  = $null
                storeUi       = 'Re-provisioning needs the original app package payload (Add-AppxProvisionedPackage -Online -PackagePath <appx>) or Windows media.'
                note          = 'Provisioned removal affects new profiles only; existing user installs are unchanged (MediaRequired).'
            })
            continue
        }
        $rows.Add([pscustomobject][ordered]@{
            packageName   = $item.packageName
            displayName   = $dn
            targetType    = 'appx'
            reversibility = $item.reversibility
            storeSearch   = "winget search `"$dn`" --source msstore"
            storeInstall  = 'winget install --id <verified ProductId> --source msstore --accept-source-agreements --accept-package-agreements'
            storeUi       = 'Microsoft Store > Library > install the app again.'
            note          = 'NEXTRIX does not guess Microsoft Store product ids; verify the search result before installing.'
        })
    }
    $result = [pscustomobject][ordered]@{
        tweakId  = 'NX12-011'
        readOnly = ($Mode -eq 'Report' -or $isPlan)
        mode     = $Mode
        items    = $rows.ToArray()
        counts   = [pscustomobject][ordered]@{ candidates = $rows.Count }
        notes    = @(
            'Restore is a separate documented path: Microsoft Store/library reinstall or winget with the msstore source. The journal does not contain the package payload and cannot replay it.',
            'Install mode requires -Mode Install -ProductId <id> -Approved; the product id must come from a verified Store/winget search result.',
            'Reinstall attempts are recorded as verify entries; app data deleted with the package is not restored.'
        )
        uncertainty = @()
    }
    if ($Mode -eq 'Report' -or $isPlan) { return $result }
    if (-not $Approved) { throw 'NX12-011 : Install mode requires -Approved' }
    if ([string]::IsNullOrWhiteSpace($ProductId)) { throw 'NX12-011 : Install mode requires a verified -ProductId (the Store id is never guessed)' }
    if ($names.Count -ne 1) { throw 'NX12-011 : Install mode requires exactly one -PackageNames entry per call (explicit, auditable reinstall)' }
    $targetRow = @($rows | Where-Object { $_.packageName -eq $names[0] } | Select-Object -First 1)
    if ($targetRow.Count -eq 0) { throw "NX12-011 : '$($names[0])' is not a removed item in the ledger" }
    if ([string]$targetRow[0].targetType -ne 'appx') { throw "NX12-011 : Install mode (winget/Store) supports removed Store apps only; $($targetRow[0].targetType) items use the documented $($targetRow[0].storeUi) route" }
    $winget = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        return [pscustomobject][ordered]@{ tweakId = 'NX12-011'; readOnly = $false; mode = $Mode; outcome = 'Blocked-WingetMissing'; items = $rows.ToArray(); notes = @('App Installer/winget is not available. Use Microsoft Store > Library instead; App Installer is protected by NX12-002 and is never removed by NEXTRIX.') }
    }
    $name = $names[0]
    $identity = [pscustomobject][ordered]@{ targetType = 'appx'; packageName = $name; scope = 'Reinstall'; provisionedState = 'Unknown' }
    $add = [pscustomobject][ordered]@{ targetType = 'appx'; packageName = $name; scope = 'Reinstall'; removalState = 'Reinstalled'; mechanism = 'winget msstore'; productId = $ProductId }
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX12-011' -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $identity -Modified $add -Result 'ReinstallRequested' -Verification 'NotRun' -Profiles $Profiles
    try {
        & $winget.Source install --id $ProductId --source msstore --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
        $exit = $LASTEXITCODE
        $present = (@(Get-AppxPackage -Name $name -ErrorAction SilentlyContinue).Count -gt 0)
        $ver = $(if ($present) { 'VerifiedPresent' } else { 'Unverified' })
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX12-011' -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $identity -Modified $add -Result $(if ($exit -eq 0) { 'ReinstallRequested' } else { 'ReinstallFailed' }) -Verification $ver -ErrorInfo "winget exit $exit" -Profiles $Profiles
        return [pscustomobject][ordered]@{ tweakId = 'NX12-011'; readOnly = $false; mode = $Mode; outcome = $(if ($present) { 'Reinstalled' } else { 'Unverified' }); wingetExit = $exit; journalSeq = $jr.seq; items = $rows.ToArray(); notes = @('Verify the app and sign-in state manually; app data is not restored.') }
    } catch {
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX12-011' -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $identity -Modified $add -Result 'ReinstallFailed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
        return [pscustomobject][ordered]@{ tweakId = 'NX12-011'; readOnly = $false; mode = $Mode; outcome = 'Failed'; reason = [string]$_.Exception.Message; items = $rows.ToArray() }
    }
}

# ============================================================================
# NX12-012 - Windows capabilities (allow-list only)
# ============================================================================

function Get-NxOptionalCapabilityInventory {
    [CmdletBinding()]
    param([string[]]$CapabilityNames = @())
    $unc = New-Object System.Collections.Generic.List[string]
    $rows = New-Object System.Collections.Generic.List[object]
    $caps = @()
    try { $caps = @(Get-WindowsCapability -Online -ErrorAction Stop) }
    catch { $unc.Add('Get-WindowsCapability -Online failed (DISM unavailable): ' + [string]$_.Exception.Message) }
    $filter = @($CapabilityNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    foreach ($c in $caps) {
        $decision = Test-Nx12CapabilityAllowed -Name ([string]$c.Name)
        if (-not $decision.allowed) { continue }
        if ($filter.Count -gt 0 -and $filter -notcontains [string]$c.Name) { continue }
        $rows.Add([pscustomobject][ordered]@{
            name        = [string]$c.Name
            displayName = [string]$c.DisplayName
            state       = [string]$c.State
            usage       = $decision.entry.usage
            reinstall   = $decision.entry.reinstall
        })
    }
    return [pscustomobject][ordered]@{
        tweakId     = 'NX12-012'
        readOnly    = $true
        capabilityCount = $caps.Count
        rows        = $rows.ToArray()
        allowList   = @($script:Nx12CapabilityAllowList)
        protectedPatterns = @($script:Nx12CapabilityProtectedPatterns)
        counts      = [pscustomobject][ordered]@{ candidates = $rows.Count; installed = @($rows | Where-Object { $_.state -eq 'Installed' }).Count }
        notes       = @(
            'This is an allow-list, never a blanket capability removal. Anything not listed (language packs, Hello biometrics, .NET, Notepad/Paint/shell components, OpenSSH Server) is refused.',
            'Capabilities are reinstallable through Settings > Optional features or Add-WindowsCapability; the source may be Windows Update or media, which is why removal is labeled irreversible for NEXTRIX rollback purposes.'
        )
        uncertainty = $unc.ToArray()
    }
}

function Remove-NxOptionalCapability {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CapabilityNames,
        [switch]$Approved,
        [string]$Approval = 'ExplicitConsent',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [switch]$Plan
    )
    $isPlan = ($Plan.IsPresent -or $WhatIfPreference)
    $selection = @($CapabilityNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    $results = New-Object System.Collections.Generic.List[object]
    $steps = New-Object System.Collections.Generic.List[object]
    $summary = [pscustomobject][ordered]@{ tweakId = 'NX12-012'; plan = [bool]$isPlan; removedCount = 0; refusedCount = 0; failedCount = 0; skippedCount = 0; irreversible = $true; results = @(); steps = @(); notes = @(); uncertainty = @() }
    if ($selection.Count -eq 0) {
        $summary.steps = @(New-Nx12Step 1 'selection' 'NoSelection' 'empty selection - capability removal is never blanket')
        $summary.notes = @('Provide exact capability names from Get-NxOptionalCapabilityInventory.')
        return $summary
    }
    Assert-Nx12ApprovalEvidence -TweakId 'NX12-012' -Approval $Approval -ApprovalModel 'ExplicitConsent' -Approved:$Approved -Plan:$isPlan
    if (-not $isPlan) { Assert-Nx12JournalReady -JournalRoot $JournalRoot }
    if (-not $isPlan -and -not (Test-Nx12Elevated)) { throw 'NX12-012 : capability removal requires administrator rights' }
    $caps = @()
    try { $caps = @(Get-WindowsCapability -Online -ErrorAction Stop) }
    catch { $summary.uncertainty = @('Get-WindowsCapability -Online failed: ' + [string]$_.Exception.Message) }
    if ($caps.Count -eq 0 -and @($summary.uncertainty).Count -gt 0) {
        $summary.notes = @('The capability list could not be read (DISM unavailable). Nothing is removed and the result is Unverified, never a guessed success.')
        $summary.steps = @(New-Nx12Step 1 'capability-enumeration' 'Unverified' (@($summary.uncertainty) -join '; '))
        return $summary
    }
    $seq = 0
    foreach ($name in $selection) {
        $decision = Test-Nx12CapabilityAllowed -Name $name
        if (-not $decision.allowed) {
            $seq++
            $results.Add([pscustomobject][ordered]@{ capability = $name; outcome = 'Refused-NotAllowListed'; reason = $decision.reason })
            $steps.Add((New-Nx12Step $seq 'allow-list' 'Refused' "$name : $($decision.reason)"))
            $summary.refusedCount++
            continue
        }
        $cap = @($caps | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
        if ($cap.Count -eq 0) {
            $seq++
            $results.Add([pscustomobject][ordered]@{ capability = $name; outcome = 'Skipped-NotFound'; reason = 'not present in the online capability list' })
            $steps.Add((New-Nx12Step $seq 'locate-capability' 'Skipped' $name))
            $summary.skippedCount++
            continue
        }
        if ([string]$cap[0].State -eq 'NotPresent') {
            $seq++
            $results.Add([pscustomobject][ordered]@{ capability = $name; outcome = 'Skipped-AlreadyNotPresent'; reason = 'capability already NotPresent' })
            $steps.Add((New-Nx12Step $seq 'state-check' 'Skipped' "$name already NotPresent"))
            $summary.skippedCount++
            continue
        }
        $original = [pscustomobject][ordered]@{ targetType = 'capability'; name = $name; packageName = $name; displayName = [string]$cap[0].DisplayName; scope = 'Machine'; provisionedState = 'NotApplicable'; state = [string]$cap[0].State }
        $modified = [pscustomobject][ordered]@{ targetType = 'capability'; name = $name; packageName = $name; scope = 'Machine'; removalState = 'Removed'; reversibility = 'OptionalFeature'; reinstallRoute = $decision.entry.reinstall; mechanism = 'Remove-WindowsCapability' }
        if ($isPlan) {
            $seq++
            $steps.Add((New-Nx12Step $seq 'plan-remove' 'Planned' "would Remove-WindowsCapability -Online -Name $name"))
            $results.Add([pscustomobject][ordered]@{ capability = $name; outcome = 'Planned'; reason = 'would remove capability' })
            continue
        }
        $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX12-012' -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
        try {
            Remove-WindowsCapability -Online -Name $name -ErrorAction Stop | Out-Null
            $verify = 'Unverified'
            try {
                $after = @(Get-WindowsCapability -Online -Name $name -ErrorAction Stop)
                if ($after.Count -gt 0 -and [string]$after[0].State -eq 'NotPresent') { $verify = 'VerifiedAbsent' } elseif ($after.Count -gt 0) { $verify = 'StillPresent' }
            } catch { $verify = 'Unverified' }
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX12-012' -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result 'Success-Irreversible' -Verification $verify -Profiles $Profiles
            $seq++
            $steps.Add((New-Nx12Step $seq 'remove-capability' 'Complete' "$name : $verify"))
            $results.Add([pscustomobject][ordered]@{ capability = $name; outcome = 'Success-Irreversible'; journalSeq = $jr.seq; verification = $verify; reversibility = 'OptionalFeature'; reinstallRoute = $decision.entry.reinstall })
            $summary.removedCount++
        } catch {
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX12-012' -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles
            $seq++
            $steps.Add((New-Nx12Step $seq 'remove-capability' 'FAILED' ([string]$_.Exception.Message)))
            $results.Add([pscustomobject][ordered]@{ capability = $name; outcome = 'Failed'; journalSeq = $jr.seq; reason = [string]$_.Exception.Message })
            $summary.failedCount++
        }
    }
    $summary.notes = @('Capability removal is allow-listed and labeled irreversible: restore through Settings > Optional features or Add-WindowsCapability (source may be Windows Update or media).')
    $summary.results = $results.ToArray()
    $summary.steps = $steps.ToArray()
    return $summary
}

# ============================================================================
# NX12-014 - AppX dependency graph verification engine (read-only)
# ============================================================================

function Get-NxAppxDependencyGraph {
    [CmdletBinding()]
    param(
        [string[]]$FocusPackage = @(),
        [switch]$IncludeProvisioned
    )
    $snapshot = Get-Nx12PackageSnapshot -IncludeAllUsers -IncludeProvisioned:$IncludeProvisioned
    $records = @($snapshot.packages)
    $index = Get-Nx12DependencyIndex -Records $records
    $nodes = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($r in $records) {
        if ($seen.ContainsKey($r.name.ToLowerInvariant())) { continue }
        $seen[$r.name.ToLowerInvariant()] = $true
        $guard = Test-Nx12PackageProtected -PackageName $r.name -SignatureKind $r.signatureKind
        $dependents = @()
        if ($index.ContainsKey([string]$r.family)) { $dependents = @($index[[string]$r.family]) }
        $nodes.Add([pscustomobject][ordered]@{
            name          = $r.name
            family        = $r.family
            version       = $r.version
            protected     = [bool]$guard.protected
            ruleId        = $guard.ruleId
            dependencies  = @($r.dependencies)
            dependents    = @($dependents | Sort-Object -Unique)
            dependentCount = @($dependents | Sort-Object -Unique).Count
        })
    }
    $anomalies = New-Object System.Collections.Generic.List[object]
    $installedFamilies = @{}
    foreach ($r in $records) { if ($r.family) { $installedFamilies[[string]$r.family] = $true } }
    foreach ($n in $nodes) {
        foreach ($dep in @($n.dependencies)) {
            if (-not $installedFamilies.ContainsKey([string]$dep)) {
                $anomalies.Add([pscustomobject][ordered]@{ package = $n.name; dependency = $dep; issue = 'declared dependency family is not installed (dangling or removed dependency)' })
            }
        }
    }
    $focusResults = New-Object System.Collections.Generic.List[object]
    foreach ($f in @($FocusPackage | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $node = @($nodes | Where-Object { $_.name -eq $f } | Select-Object -First 1)
        $direct = @()
        $transitive = New-Object System.Collections.Generic.List[string]
        if ($node.Count -gt 0) {
            $direct = @($node[0].dependents)
            $queue = New-Object System.Collections.Generic.Queue[string]
            foreach ($d in $direct) { $queue.Enqueue($d) }
            $visited = @{}
            while ($queue.Count -gt 0) {
                $cur = $queue.Dequeue()
                if ($visited.ContainsKey($cur.ToLowerInvariant())) { continue }
                $visited[$cur.ToLowerInvariant()] = $true
                $transitive.Add($cur)
                $curNode = @($nodes | Where-Object { $_.name -eq $cur } | Select-Object -First 1)
                if ($curNode.Count -gt 0) {
                    foreach ($d in @($curNode[0].dependents)) { if (-not $visited.ContainsKey($d.ToLowerInvariant())) { $queue.Enqueue($d) } }
                }
            }
        }
        $focusResults.Add([pscustomobject][ordered]@{
            packageName        = $f
            present            = ($node.Count -gt 0)
            protected          = $(if ($node.Count -gt 0) { [bool]$node[0].protected } else { $null })
            directDependents    = $direct
            transitiveDependents = $transitive.ToArray()
            safeToRemove       = ($node.Count -gt 0 -and -not $node[0].protected -and @($direct).Count -eq 0)
        })
    }
    return [pscustomobject][ordered]@{
        tweakId      = 'NX12-014'
        readOnly     = $true
        engine       = 'AppX dependency graph (declared package dependencies -> dependents, transitive closure)'
        nodes        = $nodes.ToArray()
        edges        = @($nodes | Where-Object { @($_.dependencies).Count -gt 0 } | ForEach-Object { [pscustomobject]@{ to = $_.name; dependencies = @($_.dependencies) } })
        focus        = $focusResults.ToArray()
        anomalies    = $anomalies.ToArray()
        counts       = [pscustomobject][ordered]@{
            nodes = $nodes.Count
            protectedNodes = @($nodes | Where-Object { $_.protected }).Count
            edges = @($nodes | Where-Object { @($_.dependencies).Count -gt 0 }).Count
            anomalies = $anomalies.Count
            allUsersAvailable = [bool]$snapshot.allUsersAvailable
        }
        notes        = @(
            'Every removal engine path consults this graph before mutation and refuses a package with installed dependents outside the selection.',
            'Dependencies come from the package metadata Appx reports for installed packages; a failed read is listed as uncertainty, never guessed.',
            'Provisioned-only packages are not graph nodes unless -IncludeProvisioned is supplied and the DISM query succeeds.'
        )
        uncertainty  = @($snapshot.uncertainty)
    }
}

# ============================================================================
# NX12 category rollback delegation
# ============================================================================

function Invoke-Nx12Rollback {
    <# NX12 delegated rollback report. AppX/capability removals are irreversible:
       report them with the labeled restore path; never reinstall anything. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId,
        [switch]$AllNx12
    )
    if ([string]::IsNullOrWhiteSpace($TweakId) -and -not $AllNx12) {
        throw 'Invoke-Nx12Rollback: specify -TweakId or -AllNx12 (no implicit full-category rollback)'
    }
    $journal = Read-NxJournal -Path $JournalRoot
    if ($journal.integrityErrors.Count -gt 0) {
        return [pscustomobject][ordered]@{ aborted = $true; integrityErrors = @($journal.integrityErrors); restored = @(); diverged = @(); failed = @(); irreversible = @() }
    }
    $candidates = @($journal.entries | Where-Object {
        [string]$_.operation -eq 'apply' -and
        ([string]$_.tweakId).StartsWith('NX12-') -and
        (@('appx','appxProvisioned','capability') -contains [string]$_.original.targetType)
    })
    if (-not $AllNx12) { $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId }) }
    [array]::Reverse($candidates)
    $irreversible = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($e in $candidates) {
        $key = ([string]$e.original.targetType + '|' + [string]$e.original.packageName + '|' + [string]$e.original.scope).ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $base = [string]$e.original.packageName
        $present = $null
        if ([string]$e.original.targetType -eq 'appx') {
            try { $present = (@(Get-AppxPackage -Name $base -ErrorAction SilentlyContinue).Count -gt 0) } catch { $present = $null }
        }
        $result = 'Skipped-Irreversible'
        $reason = 'AppX/capability removal is not journal-restorable; use the labeled reinstall path (NX12-011).'
        if ($present -eq $true) { $result = 'AlreadyPresent'; $reason = 'Package is present again (reinstalled or returned after a feature update); no restore needed.' }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $e.original -Modified $e.modified -Result $result -Verification $(if ($present -eq $true) { 'VerifiedPresent' } else { 'NotRun' }) -ErrorInfo $reason -Profiles @($e.profiles)
        $irreversible.Add([pscustomobject][ordered]@{
            tweakId      = $e.tweakId
            targetType   = [string]$e.original.targetType
            packageName  = $base
            scope        = [string]$e.original.scope
            livePresent  = $present
            reversibility = [string]$e.modified.reversibility
            status       = $(if ($present -eq $true) { 'AlreadyPresent' } else { 'Irreversible' })
            reason       = $reason
            restorePath  = 'Restore-NxRemovedApp -JournalRoot <journal> -Mode Report (then Install with a verified Store ProductId)'
        })
    }
    return [pscustomobject][ordered]@{
        aborted      = $false
        integrityErrors = @()
        restored     = @()
        diverged     = @()
        failed       = @()
        irreversible = $irreversible.ToArray()
        note         = 'NX12 removals are intentionally not replayed by the journal. This engine reports the honest label and the documented restore path; it never downloads or reinstalls anything.'
    }
}
