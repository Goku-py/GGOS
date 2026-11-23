# R5 — Reference Research: WinUtil & Sophia Script (PowerShell engines)

Read-only web research for NEXTRIX Phase 1. Two PowerShell-based Windows-tweak reference projects,
studied as implementation references for a PowerShell engine (contrast to AME-Wizard-style playbooks).
No tweaks were executed; all findings are from fetching public repository files and GitHub API metadata.

Evidence tags used: **IMPLEMENTED** (verified in source I actually read; path/URL cited) ·
**DOCUMENTED** (official readme/site/release-note claim, not verified in source) ·
**COMMUNITY-CLAIM** (third-party statement) · **DEV-BENCHMARK** (developer-reported numbers) ·
**VERIFIED** (independently verified results). No DEV-BENCHMARK or VERIFIED performance claims exist in
either project (neither publishes benchmark numbers); those tags are therefore unused.

---

# Project 1 — Chris Titus WinUtil

## 1.1 Identity table

| Field | Value | Evidence |
|---|---|---|
| Name | winutil ("Chris Titus Tech's Windows Utility") | IMPLEMENTED — https://github.com/ChrisTitusTech/winutil (API) |
| Repo / default branch | https://github.com/ChrisTitusTech/winutil · branch `main` | IMPLEMENTED — https://api.github.com/repos/ChrisTitusTech/winutil |
| Description | "Install Programs, Tweaks, Fixes, and Updates" | IMPLEMENTED — repo API `description` |
| Language / license | PowerShell · MIT License, "Copyright (c) 2022 CT Tech Group LLC" | IMPLEMENTED — https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/LICENSE (full standard MIT text; no extra terms) |
| Latest release | `26.11.13`, published 2026-11-13; asset `winutil.ps1` (1,309,739 bytes, sha256 `e9d05a59…`, 352,924 downloads) | IMPLEMENTED — https://api.github.com/repos/ChrisTitusTech/winutil/releases/latest |
| Stars / created / last push | 66,557 stars · created 2022-04-28 · pushed 2026-11-23 | IMPLEMENTED — repo API |
| Docs / launch | https://winutil.christitus.com/ · `irm https://christitus.com/win \| iex` | DOCUMENTED — README.md |
| Supported Windows | No global build guard found in inspected source; targets Windows 10 and 11 via per-tweak data (see 1.3-9) | IMPLEMENTED (absence verified in start.ps1, SPEC.md, tweaks executor) |
| Dependencies | Windows PowerShell 5.1 or 7, WPF, admin rights (auto-relaunches elevated), optional winget/choco for app installs, optional network (`-Offline` switch exists) | IMPLEMENTED — scripts/start.ps1; SPEC.md |
| Repo layout | `Compile.ps1`, `scripts/{start,main}.ps1`, `functions/{public,private}/*.ps1`, `config/*.json`, `xaml/inputXML.xaml`, `tools/autounattend.xml`, `pester/`, `lint/`, `docs/` (Astro site), `SPEC.md`, `AGENTS.md` | IMPLEMENTED — root contents API + SPEC.md |

## 1.2 Module architecture & build model

- **IMPLEMENTED** — Distributed artifact is ONE compiled script (`winutil.ps1`); repo is modular source.
  `Compile.ps1` concatenates: `scripts/start.ps1` (with `#{replaceme}` → `yy.MM.dd` version) → every file
  under `functions/` recursively → each `config/*.json` embedded as here-string into `$sync.configs`
  (applications get `WPFInstall` key prefix; PNG icons embedded as base64) → XAML → autounattend.xml →
  `scripts/main.ps1`. Source: https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/Compile.ps1
- **IMPLEMENTED** — SPEC.md ("Project contract") codifies: runtime is not a PowerShell module; shared
  mutable state lives in a synchronized `$sync` hashtable; long operations run in runspaces so the UI
  stays responsive; "code cannot rely on runtime module imports or source-relative dot-sourcing".
  Source: https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/SPEC.md
- **IMPLEMENTED** — Naming convention: element `WPFThingButton` maps to function `Invoke-WPFThingButton`
  (SPEC.md, "UI And Event Contract").
- **IMPLEMENTED** — `scripts/start.ps1` params: `-Config <path|URL>`, `-Preset [Standard|Minimal|Advanced]`,
  `-Offline`. Initializes `$sync` with job-queue fields (`ActiveJob`, `JobQueue`, `JobHandoff`,
  `JobClosePromptOpen`), step timings, logged errors, selection lists. Session log:
  `%LocalAppData%\winutil\logs\winutil_<timestamp>.log` ("Not a transcript, as that only records this
  runspace"). Source: https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/scripts/start.ps1
- **IMPLEMENTED** — Job model: user actions queue and "run one at a time", reorderable/cancellable, pause
  during close confirmation; ISO and USB jobs refuse to queue (SPEC.md "Runtime Model"; release notes
  26.11.13 "feat: queue actions while a job is running, with reorder and cancel").

## 1.3 Findings by area

### 1.3-1 How tweaks are declared (JSON, not inline)
- **IMPLEMENTED** — Tweaks are declarative in `config/tweaks.json` (~2,014 lines, 72.5 KB). Each entry:
  `Content`, `Description`, `category` ("Essential Tweaks", "Customize Preferences",
  "z__Advanced Tweaks - CAUTION" — `z__` prefix forces sort order, "Performance Plans - NOT FOR LAPTOPS"),
  `panel`, and change payloads: `registry[]` (`Path`, `Name`, `Value`, `Type`, **`OriginalValue`**),
  `service[]` (`Name`, `StartupType`, **`OriginalType`**), `InvokeScript[]`, `UndoScript[]`, `appx[]`,
  plus `link` to per-tweak docs page. Source:
  https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/config/tweaks.json
- **IMPLEMENTED** — `OriginalValue` may be the sentinel `"<RemoveEntry>"` = "this policy value did not
  exist before; undo deletes it". Example (`WPFTweaksConsumerFeatures`):
  `HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent → DisableWindowsConsumerFeatures = 1 (DWord),
  OriginalValue <RemoveEntry>`.
- **IMPLEMENTED** — Toggle entries add `Type: "Toggle"` + `DefaultState: true|false`; Combobox entries
  add `ComboItems` + per-choice `Values` maps on registry entries (e.g. `WPFMultiplaneOverlay`);
  Button entries just reference a function (`Type: "Button"` + `function:` in feature.json).

### 1.3-2 Interactive menu model
- **IMPLEMENTED** — WPF GUI from `xaml/inputXML.xaml`; named controls discovered into `$sync`;
  tabs ("Install", "Tweaks", "Features", "Updates", "Legacy Panels", …) via `Invoke-WPFTab`;
  central button dispatcher `Invoke-WPFButton` (9.1 KB) routes by naming convention; app list and tweak
  lists are data-driven from JSON; search helpers `Find-TweaksByNameOrDescription`. Sources: SPEC.md;
  functions/public listing (Invoke-WPFButton.ps1, Invoke-WPFTab.ps1, Find-TweaksByNameOrDescription.ps1
  under https://github.com/ChrisTitusTech/winutil/tree/main/functions).
- **IMPLEMENTED** — State reconciliation: `Invoke-WinUtilCurrentSystem` reads current registry/service
  state per tweak and checks the boxes for tweaks already applied (registry compare with
  `DefaultState` fallback; service `StartType` compare; app detection via `choco list` and a parsed
  `winget list`). Missing service ⇒ treated as "not applied", not an error. Source:
  https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/functions/private/Invoke-WinUtilCurrentSystem.ps1
- **IMPLEMENTED** — Toggles read live state via `Get-WinUtilToggleStatus`; toggle status cache is
  invalidated before apply ("The next status read must hit the registry, not a value cached before this
  change"). Source: Invoke-WinUtilTweaks.ps1.

### 1.3-3 Config import/export
- **IMPLEMENTED** — `Invoke-WPFImpex`: export = flat JSON array of selected keys
  (apps+tweaks+toggles+features+appx) via SaveFileDialog; also copies a share one-liner to clipboard:
  `& ([ScriptBlock]::Create((Invoke-RestMethod 'https://christitus.com/win'))) -Config '<path>'`.
  Import accepts file **or URL**; detects legacy config shape (`Install`/`WPFInstall` object) and
  flattens; legacy imports use `-SkipUnknown` and report skipped retired keys; modern imports are
  validated fully BEFORE replacing state ("keeps a malformed config from leaving partial selections
  behind"). Headless flag `-ThrowOnError` for automation. Source:
  https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/functions/public/Invoke-WPFImpex.ps1
- **IMPLEMENTED** — Presets: `-Preset Standard|Minimal|Advanced` (start.ps1 param, ValidateSet).
  `config/preset.json` defines `Standard`, `Minimal`, `Advanced` (tweak key lists) and `AppxDefault`
  (default appx removals: Feedback Hub, Get Help, Office Hub, Clipchamp, Alarms, QuickAssist, SoundRecorder,
  Sticky Notes, To Do, Solitaire, PowerAutomate, DevHome, BingWeather/News, StartExperiencesApp, Copilot,
  BingSearch, Calculator). Sources: start.ps1; config/preset.json.
- **DOCUMENTED** — Docs "Config Builder" web tool builds share links from the same JSON (SPEC.md).

### 1.3-4 UNDO / rollback capability (and limits)
- **IMPLEMENTED** — Core undo: `Invoke-WinUtilTweaks -undo` flips the field map —
  `Registry: "Value"→"OriginalValue"`, `Service: "StartupType"→"OriginalType"`,
  `ScriptType: "InvokeScript"→"UndoScript"`. Snippet (MIT, https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/functions/private/Invoke-WinUtilTweaks.ps1):
  ```powershell
  $Values = @{
      Registry     = "OriginalValue"
      Service      = "OriginalType"
      ScriptType   = "UndoScript"
  }
  ```
- **IMPLEMENTED** — Service-undo guard (`KeepServiceStartup`): undo only restores `OriginalType` when the
  service still sits at the `StartupType` this tweak applies — "a service already at StartupType before
  apply is indistinguishable from one changed by this tweak"; user/other-tool changes are left alone and
  the skip is logged. Missing services are skipped with a warning, not an error.
- **IMPLEMENTED** — `Invoke-WPFundoall` undoes **selected** tweaks only, as a queued job with progress;
  no global "undo everything ever applied" without re-selecting. Source: Invoke-WPFundoall.ps1.
- **IMPLEMENTED** — `Set-WinUtilRegistry` implements `<RemoveEntry>` idempotently: value already absent ⇒
  "already in the requested state", logged, no error; creates missing key paths; catches
  SecurityException/ItemNotFound/UnauthorizedAccess. Source:
  https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/functions/private/Set-WinUtilRegistry.ps1
- **IMPLEMENTED** — Limits of undo: appx removal is apply-only ("if (!$undo … Remove-WinUtilAPPX" — undo
  does not reinstall appx); tweaks lacking `OriginalValue`/`UndoScript` fields are not reversible;
  combobox (`Values`) registry entries are handled by a separate `Set-WinUtilRegistryComboState` path.
  Source: Invoke-WinUtilTweaks.ps1.
- **IMPLEMENTED** — Optional restore point: `WPFTweaksRestorePoint` runs FIRST, before all other tweaks
  (special-cased in `Invoke-WPFtweaksbutton`); sets
  `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore → SystemRestorePointCreationFrequency = 0`
  then `Checkpoint-Computer -RestorePointType MODIFY_SETTINGS`. Source: Invoke-WPFtweaksbutton.ps1 + tweaks.json.
- **DOCUMENTED** — SPEC.md safety requirement: "Tweak changes include undo metadata when the schema
  supports it, so changes stay reversible."

### 1.3-5 DNS / network functions
- **IMPLEMENTED** — `config/dns.json`: 8 providers (Google, Cloudflare, Cloudflare_Malware,
  Cloudflare_Malware_Adult, Open_DNS, Quad9, AdGuard_Ads_Trackers, AdGuard family) each with
  Primary/Secondary IPv4+IPv6 + `DohTemplate` URL + `BenchmarkEligible` flag. UI combobox:
  `Default DHCP Fastest Google Cloudflare …`. Sources: config/dns.json; tweaks.json `WPFchangedns`.
- **IMPLEMENTED** — `Set-WinUtilDNS`: "Default" ⇒ no change; "Fastest" ⇒ TCP-latency benchmark
  (`Get-WinUtilDNSBenchmark`), aborts DNS change if all probes fail ("keeping current network adapter
  DNS settings"); applies to **all Up adapters** via `Set-DnsClientServerAddress` (v4+v6); registers DoH
  via `Add/Set-DnsClientDohServerAddress` + registry `DohFlags=1` under
  `HKLM:\System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\<GUID>\DohInterfaceSettings`;
  "DHCP" reset removes DoH registrations; `Clear-DnsClientCache` at end. Returns `$true/$false` — and
  **a failed DNS change aborts the whole tweak run** ("Carrying on after the DNS change failed leaves the
  machine half configured"). Sources: Set-WinUtilDNS.ps1; Invoke-WPFtweaksbutton.ps1.
- **IMPLEMENTED** — Fix buttons: `Network - Reset` (`Invoke-WPFFixesNetwork`), `NTP Server - Enable`
  (replaces time.windows.com with pool.ntp.org), `WinGet - Reinstall`. Source: config/feature.json.

### 1.3-6 Driver install functions
- **IMPLEMENTED** — No dedicated driver-install engine; drivers are app-catalog entries installed via
  winget/choco in `config/applications.json` (~2,151 lines, 92 KB): Display Driver Uninstaller
  (`Wagnardsoft.DisplayDriverUninstaller`), Snappy Driver Installer Origin
  (`GlennDelahoy.SnappyDriverInstallerOrigin`), NVCleanstall (`TechPowerUp.NVCleanstall`), GeForce NOW,
  MSI Afterburner, GPU-Z/CPU-Z/HWiNFO, NTLite. Installed by `Install-WinUtilProgramWinget` /
  `Install-WinUtilProgramChoco` / `Install-WinUtilAPPX`. Sources: applications.json (fetched + grep);
  functions/private listing.
- **IMPLEMENTED** — Driver-blocking tweaks (see 1.3-9): Razer auto-install block, Logitech Download
  Assistant block, `SearchOrderConfig=0` + `DisableCoInstallers=1`, `PreventDeviceMetadataFromNetwork=1`.

### 1.3-7 O&OShutUp-style privacy toggles
- **IMPLEMENTED** — `WPFOOSUbutton` ("O&O ShutUp10++ - Run") **downloads OOSU10.exe from
  dl5.oo-software.com and launches it** — WinUtil does not implement O&O-style toggles itself; the
  external tool is run manually. Snippet (MIT, https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/functions/public/Invoke-WPFOOSU.ps1):
  ```powershell
  Save-WinUtilFile -Uri "https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe" `
      -DestinationPath $DownloadPath
  Start-Process -FilePath $DownloadPath
  ```
- **IMPLEMENTED** — WinUtil's own privacy tweaks (tweaks.json): Telemetry (diagtrack+WerSvc disabled +
  ~13 HKCU/HKLM values incl. `AllowTelemetry=0`), Activity History, Location (lfsvc Disabled + ConsentStore
  location=Deny), ConsumerFeatures, WPBT, Speech/ink collection, advertising ID, tailored experiences.

### 1.3-8 Registry / service / scheduled-task / power changes observed
- **IMPLEMENTED** — Registry paths written (representative, from tweaks.json + update functions):
  `HKLM:\SOFTWARE\Policies\Microsoft\Windows\{System,CloudContent,DataCollection,Device Metadata,
  DriverSearching,DeliveryOptimization,WindowsUpdate,WindowsUpdate\AU,WindowsNotepad,Explorer}`,
  `HKLM:\SOFTWARE\Policies\{Microsoft\Edge,Microsoft\EdgeUpdate,BraveSoftware\Brave}`,
  `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager` (DisableWpbtExecution),
  `HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters` (DisabledComponents 1/32/255),
  `HKLM:\SOFTWARE\Microsoft\Windows\Dwm` (OverlayTestMode), `HKCU:\Software\Microsoft\Windows\CurrentVersion\*`,
  `HKCU:\Control Panel\*`, hosts file (Adobe block), `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`
  (autologin), `HKU:\.Default` (NumLock).
- **IMPLEMENTED** — Services (tweaks.json + update functions): `DiagTrack`→Disabled, `WerSvc`→Disabled,
  `lfsvc`→Disabled, `CscService`→Disabled, `SharedAccess`→Disabled, `MapsBroker`/`StorSvc`→Manual,
  `WSearch`→Disabled (new 26.11.13 tweak; UndoScript restarts it), `OneSyncSvc`→Disabled (guarded by
  Test-Path on per-user template), `WSAIFabricSvc`→Disabled (guarded). Update modes: `BITS`/`wuauserv`/`UsoSvc`
  disabled by "Disable Windows Update"; Manual/Manual/Automatic by "Security" and "Default" modes.
  `Set-WinUtilService` is idempotent (skips if already at target) and handles `AutomaticDelayedStart`
  via `sc.exe config start= delayed-auto` on PS5.
- **IMPLEMENTED** — Scheduled tasks: "Disable Windows Update" disables task paths
  `\Microsoft\Windows\{InstallService,UpdateOrchestrator,UpdateAssistant,WaaSMedic,WindowsUpdate}\*`;
  Security/Default modes re-enable them. `WPFFeatureRegBackup` registers daily 00:30 task `AutoRegBackup`
  running `schtasks /run /tn "\Microsoft\Windows\Registry\RegIdleBackup"` + `EnablePeriodicBackup=1`.
- **IMPLEMENTED** — Power: `Invoke-WPFUltimatePerformance` duplicates scheme GUID
  `e9a42b02-d5df-448d-aa00-03f14749eb61` via `powercfg /duplicatescheme`, activates it; disable does
  `powercfg /restoredefaultschemes`. Category literally named "Performance Plans - NOT FOR LAPTOPS".
  `WPFTweaksHiber`: `powercfg /hibernate off` + HibernateEnabled=0. BCD: feature.json
  `bcdedit /set bootmenupolicy legacy|standard` (F8 boot menu).

### 1.3-9 Hardware-aware logic
- **IMPLEMENTED** — `WPFTweaksSvcHostSplitting` reads physical RAM via
  `Get-CimInstance Win32_PhysicalMemory` and sets `SvcHostSplitThresholdInKB` to total KB (disables
  svchost splitting); description targets "low-performance systems with 12 GB of RAM or less"; undo
  restores Windows default 3670016. Snippet (MIT, tweaks.json URL above):
  ```powershell
  $Memory = (Get-CimInstance Win32_PhysicalMemory |
      Measure-Object Capacity -Sum).Sum / 1KB
  Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" `
      -Name SvcHostSplitThresholdInKB -Value $Memory -Type DWord
  ```
- **IMPLEMENTED** — `WPFMultiplaneOverlay` combobox (GPU: DWM overlay issues), `WPFToggleS3Sleep`
  (PlatformAoAcOverride — Modern Standby vs S3), `WPFToggleStandbyFix` (S0 network connectivity),
  WSearch-disable description scoped to "mechanical hard drives", GameBar/GameMode toggles,
  "Ultimate Performance … NOT FOR LAPTOPS", `WPFTweaksUTC` (dual-boot with Linux).

### 1.3-10 Windows build compatibility approach
- **IMPLEMENTED** — **No global build guard.** start.ps1 checks only Constrained Language Mode and
  elevation; SPEC.md documents no version gate. Compatibility is handled per-tweak in prose
  (e.g. `WPFTweaksRevertStartMenu`: "On newer versions of Windows !!THIS TWEAK WILL NOT WORK!!") and via
  tolerant executors (missing service/value ⇒ warn and continue).
- **IMPLEMENTED** — Known-issues doc: Revert-Start-Menu tweak dead since **KB5089573 (May 2026)**
  ("Microsoft completely removed the old Start Menu code"); Ultimate Performance "may not work on some
  laptops … expected behavior on unsupported hardware"; MSIX (Store) PowerShell 7 breaks DISM cmdlets
  (`Class not registered`) — which is why the WindowsAI tweak shells out to `powershell.exe` for
  `Disable-WindowsOptionalFeature -FeatureName Recall`. Sources:
  https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/docs/src/content/docs/knownissues.mdx; tweaks.json.
- **IMPLEMENTED** — Elevation UX: if not admin, relaunches via `pwsh`/`powershell -ExecutionPolicy Bypass
  -NoProfile -EncodedCommand <base64>` with `-Verb RunAs`; launch parameters are
  `PSSerializer`-serialized inside base64 so "quotes in Config cannot become PowerShell code";
  declined UAC ⇒ exit code 1; headless runs wait for the elevated child and propagate its exit code.
  Source: scripts/start.ps1.

### 1.3-11 Safety-relevant behavior (Defender / firewall / UAC / security mitigations)
- **IMPLEMENTED** — Telemetry tweak calls `Set-MpPreference -SubmitSamplesConsent 2` (Disable Defender
  sample submission) with explicit tolerance for Defender error 0x800106ba when Defender is unavailable
  (release note: "don't fail the Telemetry tweak when Defender is unavailable"). Source: tweaks.json
  `WPFTweaksTelemetry`.
- **IMPLEMENTED** — `WPFTweaksDisableBitLocker` checks `Get-BitLockerVolume … FullyDecrypted` first
  (release note: "Skip disabling BitLocker when the system drive is already decrypted"); UndoScript is a
  bare `Enable-BitLocker -MountPoint $Env:SystemDrive` (won't re-encrypt without further params).
- **IMPLEMENTED** — `WPFTweaksRemoveOneDrive`: captures OneDrive folder ACL, `icacls /deny
  "*S-1-5-32-544:(D,DC)"` to protect user files, runs uninstaller, `finally` restores ACL; kills
  Explorer/FileCoAuth; removes leftovers; disables OneSyncSvc only if template key exists.
- **IMPLEMENTED** — "Disable Windows Update" flow stops+disables `BITS, wuauserv, UsoSvc`, deletes
  `C:\Windows\SoftwareDistribution\*`, disables update tasks — behind a YesNo confirmation dialog that
  states "Security updates will not be installed until defaults are restored". Registry writes use
  Test-Path guard because "New-Item -Force on an existing registry key deletes the key and its subkeys
  first". Source: Invoke-WPFUpdatesdisable.ps1.
- **IMPLEMENTED** — "Restore Defaults" (`Invoke-WPFUpdatesdefault`) removes every WinUtil-managed update
  policy value, clears **SYSTEM (S-1-5-18) deny ACLs** on BITS/wuauserv/UsoSvc/WaaSMedicSvc service keys
  ("Other tweak tools can deny SYSTEM write access to these keys"), restores startup types, and — because
  `WaaSMedicSvc` is launch-protected — writes `Start=3 (Manual)` **directly in the registry**.
- **IMPLEMENTED** — "Windows Update - Reset" (`Invoke-WPFFixesUpdate`): 13-step repair incl. stopping
  services, renaming SoftwareDistribution\Download, re-registering ~36 DLLs, removing WSUS client keys,
  `netsh winsock reset`, deleting all BITS jobs; **Aggressive mode** additionally runs SFC/DISM repair,
  renames DataStore/CatRoot2, resets service security descriptors via `sc.exe sdset`, and deletes whole
  policy trees (`HKLM:\Software\Policies`, `HKCU:\Software\Policies`, WOW6432Node equivalents,
  GroupPolicy folders) + `secedit /configure defltbase.inf`. Labeled a "Fix", not a tweak.

## 1.4 Useful ideas for NEXTRIX (from WinUtil)
1. **Undo-metadata-in-data schema** — every registry/service change carries its own original value/state
   (`OriginalValue`/`OriginalType`), with a `"<RemoveEntry>"` sentinel for values that never existed.
   This makes rollback a mechanical field-flip instead of a second hand-written script. (IMPLEMENTED)
2. **Conditional service undo** — only restore `OriginalType` if the service still matches the tweak's
   applied state; protects user/other-tool changes; log the skip. (IMPLEMENTED)
3. **Restore point first, always** — special-case it to run before the queue; also Sophia's default. (IMPLEMENTED)
4. **Strict config import with pre-validation** — validate every imported key before touching state;
   reject unknown keys in strict mode, report them in legacy mode; one-liner share command. (IMPLEMENTED)
5. **Abort-on-failure ordering** — DNS change failure aborts the run instead of half-configuring. (IMPLEMENTED)
6. **Idempotent executors** — "already in requested state" is success, not error (registry absent case,
   service already at target, winget already installed). (IMPLEMENTED)
7. **Launch-protected service workaround** — write `Start` value directly for WaaSMedicSvc/AppIDSvc;
   clear third-party SYSTEM deny ACEs before `Set-Service`. Real-world compat lesson. (IMPLEMENTED)
8. **Session logging + per-step error accounting** — `%LocalAppData%\<tool>\logs`, step timings, job
   error counters so a job can fail loudly without throwing. (IMPLEMENTED)
9. **Hardware-conditional tweaks as data** — RAM threshold for svchost splitting, HDD-scoped WSearch,
   laptop warnings as category names ("NOT FOR LAPTOPS"). (IMPLEMENTED)
10. **DNS provider registry as JSON** (v4/v6/DoH template/benchmark eligibility) rather than hardcoded. (IMPLEMENTED)
11. **Pester tests over the tweak data** (config schema tests) + auto-generated per-tweak docs pages. (IMPLEMENTED)
12. **Safe elevation** — PSSerializer+base64 EncodedCommand relaunch; headless exit-code propagation;
    CLM detection with clear refusal message. (IMPLEMENTED)

## 1.5 Reject / caution (WinUtil)
- **Reject for NEXTRIX defaults**: "Disable Windows Update" (service+task+SoftwareDistribution wipe) —
  security posture risk even with confirmation. (IMPLEMENTED)
- **Reject**: `WPFTweaksDiskCleanup` runs `DISM /StartComponentCleanup /ResetBase` — permanently removes
  superseded component versions; installed updates can no longer be uninstalled. Irreversible. (IMPLEMENTED)
- **Reject**: `WPFTweaksRemoveEdge` dummy `MicrosoftEdge.exe` + `--force-uninstall` hack; breaks WebView
  dependencies and update paths; "Undo" is just `winget install Microsoft.Edge`. (IMPLEMENTED)
- **Reject**: `WPFTweaksBlockAdobeNet` appends a third-party GitHub hosts list into the system hosts file —
  supply-chain and licensing hazards; also the exact condition Sophia's guard refuses to run on. (IMPLEMENTED)
- **Caution**: Telemetry tweak disables Defender sample submission (`SubmitSamplesConsent 2`) — must be
  an explicit, disclosed security decision in NEXTRIX. (IMPLEMENTED)
- **Caution**: `WPFTweaksDisableBitLocker` sits in "Essential Tweaks" and the Advanced preset while being
  a disk-encryption change; UndoScript is under-specified. (IMPLEMENTED)
- **Caution**: `WPFTweaksWindowsAI` uses an `EndOfLife\<SID>` AppxAllUserStore trick to remove CoreAI and
  `winget uninstall Copilot` — undocumented mechanism, fragile across builds. (IMPLEMENTED)
- **Caution**: `WPFTweaksRevertStartMenu` writes `HKLM:\SYSTEM\ControlSet001\...` (hardcoded control set,
  not CurrentControlSet) and is dead on KB5089573+ anyway. (IMPLEMENTED)
- **Caution**: FixUpdate's aggressive mode deletes entire `HKLM:\Software\Policies` trees and GroupPolicy
  folders — repair-only action, never a default. (IMPLEMENTED)
- **Caution**: no build guard means stale tweaks can silently no-op or misfire across Windows builds;
  NEXTRIX should add per-tweak build applicability metadata instead. (IMPLEMENTED — absence)
- **Caution**: launch depends on `christitus.com` shortlink; known-issues page itself suggests a VPN when
  the download fails. (IMPLEMENTED)

## 1.6 Research limitations (WinUtil)
- `functions/private` directory listing was truncated mid-alphabet in preview (saved single-line JSON);
  files after `Invoke-WinUtilUninstallPSProfile.ps1` were not enumerated, though the ones I fetched
  directly (Set-WinUtilRegistry/Service/DNS, Invoke-WinUtilCurrentSystem, Invoke-WinUtilISO* exist per
  listing) all resolved successfully.
- `applications.json` was inspected for lines 1–1190 of 2151 plus targeted greps (driver-related entries);
  the remaining ~960 lines of app entries were not individually reviewed.
- MicroWin/ISO workflow internals (`Invoke-WinUtilISO.ps1` 39 KB, `Invoke-WinUtilISOScript.ps1` 43 KB)
  were not read; behavior taken from SPEC.md ("ISO workflows never modify the user's original ISO file;
  they work on copied/mounted content") — DOCUMENTED, not IMPLEMENTED.
- `xaml/inputXML.xaml`, `themes.json`, `appnavigation.json`, Pester test files, and the compiled
  `winutil.ps1` release artifact were not read.
- Behavior findings are static source analysis; nothing was executed (per mandate).

---

# Project 2 — Sophia Script for Windows

## 2.1 Identity table

| Field | Value | Evidence |
|---|---|---|
| Name | Sophia Script for Windows ("The most advanced PowerShell module on GitHub for fine-tuning Windows") | IMPLEMENTED — repo API + README.md |
| Repo / default branch | https://github.com/farag2/Sophia-Script-for-Windows · branch `main` | IMPLEMENTED — https://api.github.com/repos/farag2/Sophia-Script-for-Windows |
| License | MIT License, "Copyright (c) 2023 farag2" — full standard MIT text, no additional clauses in LICENSE; module manifest Copyright "(c) 2014—2026 Team Sophia". NOTE: the frequently-cited "specific terms" are NOT in the license file; they concern the author's stance against wrappers (see 2.3-8), which is community policy, not license text. | IMPLEMENTED — https://raw.githubusercontent.com/farag2/Sophia-Script-for-Windows/main/LICENSE; SophiaScript.psd1 |
| Latest release | `8.1.0` "31.10.2026", published 2026-10-31; 10 assets: Windows 11 v8.1.0 (PS5.1 + PS7), Windows 11 Arm (PS5.1 + PS7), Windows 11 LTSC 2024 (PS5.1 + PS7), Windows 10 v7.1.0 (PS5.1 + PS7), Windows 10 LTSC 2019 v7.1.0, Windows 10 LTSC 2021 v7.1.0, plus a WinGet `.exe`. Win11 zip: 489,722 bytes; PS7 zip: 10,645,753 bytes. Download counts read from API (e.g. Win11 PS5.1 zip 3,423). | IMPLEMENTED — https://api.github.com/repos/farag2/Sophia-Script-for-Windows/releases/latest |
| Stars / created / push | 9,978 stars · created 2018-10-17 · pushed 2026-11-22 | IMPLEMENTED — repo API |
| Supported builds (exact, from guard data) | Windows 11: build **26300 (26H2) with UBR ≥ 9974**; Windows 10 22H2: **19045 with UBR ≥ 7846**; LTSC 2019: 17763.9245; LTSC 2021: 19044.7725; Win11 LTSC 2024 / Win11: 26100.9974 floor + 26300 major; ARM64 variant (arch check) | IMPLEMENTED — https://raw.githubusercontent.com/farag2/Sophia-Script-for-Windows/main/supported_windows_builds.json and Windows_Builds.json; InitialActions.ps1 |
| Editions | README table: Win11 26H2+ Home/Pro/Enterprise; Win10 x64 22H2 Home/Pro/Enterprise; Win11 Enterprise LTSC 2024; Win10 LTSC 2021; Win10 1809 LTSC 2019 | DOCUMENTED — README.md (matches JSON + branding check) |
| Dependencies | PowerShell 5.1 x64 (this variant; separate PS7/ARM/LTSC builds); WPF assemblies for pop-up dialogs; compiled WinAPI types (P/Invoke); admin (`#Requires -RunAsAdministrator`); internet optional (online latest-version check warns on failure) | IMPLEMENTED — Sophia.ps1 header; InitialActions.ps1 |
| Repo layout | `src/Sophia_Script_for_Windows_11/{Sophia.ps1, Import-TabCompletion.ps1, Module/{Sophia.psm1 (315 KB), SophiaScript.psd1, Localizations/, Private/}}` × 10 variants; `Scripts/` (CI/build: Lint, SignPath, VirusTotal, WinGet, Chocolatey); Cursors/; HEVC/; CHANGELOG.md (133 KB); CODE_SIGNING_POLICY.md; supported_windows_builds.json | IMPLEMENTED — contents API listings |
| Code signing | SignPath Foundation certificate | DOCUMENTED — README "Acknowledgements"; CODE_SIGNING_POLICY.md exists (not read) |

## 2.2 Function-per-tweak architecture
- **IMPLEMENTED** — `Sophia.ps1` is a **preset file** (65.7 KB): each line is a function call the user
  uncomments/comments; every call sits directly above its commented "(default value)" counterpart, e.g.
  `DiagTrackService -Disable` / `# DiagTrackService -Enable`. Header states: "Every tweak in the preset
  file has its corresponding function to restore the default settings".
  Source: https://raw.githubusercontent.com/farag2/Sophia-Script-for-Windows/main/src/Sophia_Script_for_Windows_11/Sophia.ps1
- **IMPLEMENTED** — `#Requires -RunAsAdministrator`, `#Requires -Version 5.1`; dot-sources
  `Module\Private\InitialActions.ps1` and calls `InitialActions` before any tweak.
- **IMPLEMENTED** — `Module/Sophia.psm1` (315,377 bytes, 10,419 lines) exports **121 public functions**
  (enumerated by grep): Logging, CreateRestorePoint, DiagTrackService, DiagnosticDataLevel, ErrorReporting,
  RecommendedTroubleshooting, FeedbackFrequency, ScheduledTasks, … (privacy/UI/OneDrive/WSL/VCRedist/
  DotNet/Sandbox/StorageSense/LongPaths/PowerPlan/NetworkAdaptersSavePower/…), Uninstall-UWPApps, XBOXGameBar,
  GPUScheduling, CleanupTask, SoftwareDistributionTask, TempTask, NetworkProtection, PUAppsDetection,
  DefenderSandbox, EventViewerCustomView, AppsSmartScreen, SaveZoneInformation, DNSoverHTTPS,
  LocalSecurityAuthority, AdminApprovalMode, ScanRegistryPolicies, …
- **IMPLEMENTED** — Selective invocation: dot-source `Import-TabCompletion.ps1`, then
  `Sophia -Functions "DiagTrackService -Disable", "DiagnosticDataLevel -Minimal", Uninstall-UWPApps`
  (README + Import-TabCompletion.ps1 exists in src).
- **IMPLEMENTED** — Interactive pop-ups (WPF windows constructed in code): ScheduledTasks checkbox dialog,
  Uninstall-UWPApps, WindowsFeatures, WindowsCapabilities, Install-WSL — plus `Show-Menu` arrow-key Yes/No
  console menus and native toast notifications (WinAPI.ps1 P/Invoke).

## 2.3 Findings by area

### 2.3-1 Supported-build policy (exact refusal mechanism)
- **IMPLEMENTED** — `InitialActions` (v8.1.0, 31.10.2026) fetches `Windows_Builds.json` from the repo
  (TimeoutSec 5); **offline fallback uses hardcoded 26300/9974**. Guard logic, snippet (MIT,
  https://raw.githubusercontent.com/farag2/Sophia-Script-for-Windows/main/src/Sophia_Script_for_Windows_11/Module/Private/InitialActions.ps1):
  ```powershell
  $CurrentBuild = [int]$CurrentVersion.CurrentBuild
  $UBR          = [int]$CurrentVersion.UBR
  if (($CurrentBuild -lt $LatestSupportedMajorBuild) -or
      (($CurrentBuild -eq $LatestSupportedMajorBuild) -and
       ($UBR -lt $LatestSupportedMinorBuild)))
  ```
  On refusal it warns "UpdateWindowsBuild", then **takes action**: sets
  `HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings → AllowMUUpdateService = 1`, triggers
  `UsoClient.exe StartInteractiveScan`, runs an MDM UWP UpdateScanMethod, opens
  `ms-settings:windowsupdate`, and `exit`s. It refuses anything below build 26300 or 26300.9974.
- **IMPLEMENTED** — Preceding it, a branding check: `%WINDOWS_LONG%` (via WinAPI Winbrand
  `BrandingFormatString`) must match "Windows 11" and not "LTSC", else "WrongSophiaScriptVersion" + same
  update-triggering exit. Wrong-variant refusal therefore also nudges the user to update Windows.

### 2.3-2 Full startup guard chain (stability-first philosophy)
All **IMPLEMENTED** — InitialActions.ps1, in order:
1. Unblock-File all script files; TLS 1.2; `ProgressPreference=SilentlyContinue`; StrictMode Latest.
2. **File-integrity check**: all 12 localizations + 12 private files + module + manifest + tab-completion
   must exist, else "download the archive from the release page for your system" + exit.
3. Localization import with en-US fallback; **FullLanguage mode required** else exit.
4. **PowerShell major version must equal 5** for this variant (PS7 has its own archive) else exit.
5. **Windows component stability probe** (any failure ⇒ "Windows component stability disrupted …
   Reinstall Windows" + exit): services `Windefend, SecurityHealthService, wscsvc, wdFilter` must exist;
   SecurityHealthService must start; **SysMain forced to Automatic and started**;
   `AutomaticManagedPageFile` forced `$true`; WMI providers probed (CIM_OperatingSystem, Win32_Volume,
   Win32_ShadowStorage, MSFT_NetAdapter, CIM_ComputerSystem, MDM_EnterpriseModernAppManagement,
   Win32_EncryptableVolume, MSFT_MpComputerStatus, AntiVirusProduct, Get-MpPreference).
6. **CPU architecture = 9 (x64)** required (`CIM_Processor.Architecture`), else UnsupportedArchitecture exit.
7. Online latest-version check vs `Sophia_Script_Releases.json` (network failure ⇒ warning only).
8. Logged-in user must be the session's explorer.exe owner (admin-identity check).
9. Refuses ISE and VS Code hosts.
10. **Harmful-tweaker fingerprinting** — refuses to run if any of these are detected (per-tool probe):
    Ghost Toolbox (`run.ghost.cmd` path), Win 10 Tweaker (`HKCU:\Software\Win 10 Tweaker`), Revision Tool,
    AtlasOS (`%SystemRoot%\AtlasModules`), BoosterX, WinClean, PCNP, Tron (`C:\logs\tron`), CrystalCry,
    defendnot, RemoveWindowsAI, AutoSettingsPS, Modern Tweaker — "harmful tweaker found … Reinstall Windows".
11. Microsoft Store + `MicrosoftWindows.Client.CBS` (Feature Experience Pack) must be installed, else exit.
12. Defender components must exist (`smartscreen.exe`, `SecurityHealthSystray.exe`, `CompatTelRunner.exe`);
    Defender must be the default AV (AMRunningMode "Normal", no active third-party AV via
    SecurityCenter2 productState bits); **Controlled Folder Access enabled ⇒ opens
    `windowsdefender://RansomwareProtection` and exits**.
13. **Pending reboot check** (CBS RebootPending/RebootInProgress/PackagesPending, WU PostRebootReporting/
    RebootRequired) ⇒ exit.
14. Windows Terminal (if host) must be ≥ 1.24 else prompts update.
15. hosts-file check: any third-party entry ⇒ interactive Yes/No; No opens the hosts folder and exits.
16. BitLocker sanity: drive FullyEncrypted but ProtectionStatus Off ⇒ interactive choice; Yes calls
    `Disable-BitLocker` (with restart caveat on failure).
17. Secure Boot: enabled ⇒ checks UEFI `db` for "Windows UEFI CA 2023" and warns with Microsoft links if
    stale; disabled ⇒ verbose warning only.
18. Removes `OnlyUseLatestCLR` (.NET) legacy override; saves open Explorer windows for later restore;
    **interactive preset confirmation** ("did you customize the preset?") — No opens the preset file and exits.

### 2.3-3 Telemetry / privacy functions
- **IMPLEMENTED** — `DiagTrackService -Disable`: stops + disables DiagTrack AND **blocks the "DiagTrack"
  firewall rule group** (`Get-NetFirewallRule -Group DiagTrack | Set-NetFirewallRule -Action Block`);
  `-Enable` restores Automatic + Allow. Not documented as reversible side effect: XBOX achievements and
  Feedback Hub are affected (comment in source).
- **IMPLEMENTED** — `DiagnosticDataLevel -Minimal`: **edition-aware** — Enterprise/Education ⇒
  `AllowTelemetry=0`; Home/Pro ⇒ `AllowTelemetry=1` ("Send required diagnostic data"); both get
  `MaxTelemetryAllowed=1` + `ShowedToastAtLevel=1` (HKCU DiagTrack). `-Default` ⇒ 3/3/3. All policy keys
  (`HKLM:\SOFTWARE\Policies\...\DataCollection → AllowTelemetry`) are removed first "to make changes
  visible in UI" — real settings keys are used instead of policy keys.
- **IMPLEMENTED** — `ErrorReporting -Disable`: WerSvc must exist (else stability warning); disables
  QueueReporting task, stops+disables WerSvc, `Disable-WindowsErrorReporting`. **RecommendedTroubleshooting**
  warns when it will override what DiagnosticDataLevel/ErrorReporting previously set (cross-function
  dependency warning, `$ChangedFunctions`).
- **IMPLEMENTED** — `ScheduledTasks -Disable`: interactive WPF checkbox dialog over tasks: MareBackup,
  Microsoft Compatibility Appraiser (+Exp), StartupAppTask, Proxy, Consolidator, UsbCeip,
  Microsoft-Windows-DiskDiagnosticDataCollector, MapsToastTask, MapsUpdateTask; user picks which to disable
  (`-Enable` shows disabled ones). Uses `Send-ConsoleBackspace` to unfreeze the console after the dialog.
- **IMPLEMENTED** — Privacy set: SigninInfo (UserARSO OptOut=1 per-SID), LanguageListAccess
  (HttpAcceptLanguageOptOut=1), AdvertisingID (Enabled=0), WindowsWelcomeExperience/WindowsTips/
  SettingsSuggestedContent/AppsSilentInstalling/WhatsNewInWindows (ContentDeliveryManager
  SubscribedContent-* / SilentInstalledAppsEnabled / ScoobeSystemSettingEnabled), TailoredExperiences,
  BingSearch (DisableSearchBoxSuggestions=1 in HKCU + **Add-Policy to Registry.pol so it shows in gpedit**).

### 2.3-4 Service functions — states and reasoning
- **IMPLEMENTED** — Complete service-state changes in the Win11 8.1.0 module (grep of Sophia.psm1):
  `DiagTrack` (Disabled ⇄ Automatic), `WerSvc` (Disabled ⇄ Manual), `VSS`+`swprv` (Disabled→Manual inside
  CreateRestorePoint "never skip creating a restore point"). In InitialActions: `SecurityHealthService`
  started; `SysMain` set Automatic + started. **There is no bulk "set services to manual" list function in
  the current Win11 module** — service tweaks are individual, documented, and reversible.
- **IMPLEMENTED** — Reasoning embedded per function: DiagTrack disable may break XBOX achievements/
  Feedback Hub; ErrorReporting requires WerSvc presence (stability probe first); restore point function
  re-enables VSS/swprv only if currently Disabled.

### 2.3-5 DNS change approach
- **IMPLEMENTED** — `DNSoverHTTPS` with providers Cloudflare (1.1.1.1/1.0.0.1), Google (8.8.8.8/8.8.4.4),
  Quad9 (9.9.9.9/149.112.112.112), AdGuard (94.140.14.14/15), OpenDNS (208.67.222.220/220.220);
  `-Reset` returns to ISP DNS. Mechanism: finds the **active adapter via `Find-NetRoute -RemoteIPAddress
  1.1.1.1`**; resets existing DNS; sets new servers; writes DoH into
  `HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\<GUID>\DohInterfaceSettings\Doh\<ip>`
  (`DohFlags=2` QWord + `DohTemplate` string); `Clear-DnsClientCache` + `Register-DnsClient`; then
  **verification with rollback**: resolves `dns.msftncsi.com` via WinAPI DNS P/Invoke before and after
  (2 attempts, "prevents a rollback because of a single lost query"); if the new DNS fails — "e.g. it was
  withdrawn from the user's country" — **automatically rolls back to default DNS** and reports
  "DNSServerNotResponding". No active adapter ⇒ function skips with an error, does not guess.

### 2.3-6 Undo capability (and limits)
- **IMPLEMENTED** — Undo is the paired parameter set of every function (`-Disable ⇄ -Enable`,
  `-Show ⇄ -Hide`, `-Register ⇄ -Delete`, `-Minimal ⇄ -Default`, etc.); the preset file always displays the
  default-restoring call right below the selected one. There is **no batch "undo all" and no change
  journal**; the safety net is `CreateRestorePoint` (run by default in the preset) plus `Start-Transcript`
  logging (`Logging` function, transcript to script folder).
- **IMPLEMENTED** — `CreateRestorePoint`: removes DisableSR/DisableConfig policies (registry **and**
  Registry.pol), re-enables VSS/swprv if disabled, verifies System Protection is on (SPP\Clients GUID
  check, `Enable-ComputerRestore` if not), temporarily sets
  `SystemRestorePointCreationFrequency=0` ("Never skip creating a restore point"),
  `Checkpoint-Computer -RestorePointType MODIFY_SETTINGS`, then removes the frequency override.
- **IMPLEMENTED** — Limits: Uninstall-UWPApps/-OneDrive/-Edge removals are one-way (reinstall path exists
  but is separate); `OneDrive -Uninstall` refuses to run if the user is signed in (HKCU Accounts
  UserEmail present) and deletes the OneDrive folder **only if empty** — else it opens the folder instead.

### 2.3-7 Scheduled task changes
- **IMPLEMENTED** — `CleanupTask -Register`: task folder `\Sophia\`; sets `StateFlags1337` on 15
  VolumeCaches categories (incl. "Device Driver Packages", "Windows Defender", "Update Cleanup"); task
  script kills running cleanmgr/DISM, runs `cleanmgr.exe /sagerun:1337`, waits for exit, then
  `Dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart` (**no /ResetBase** — reversible
  component cleanup); registers AppUserModelId "Sophia" + a `WindowsCleanup://` URL protocol so the toast
  "Run" button starts the task; toast every 30 days; `-Delete` removes tasks + scripts.
- **IMPLEMENTED** — `SoftwareDistributionTask -Register`: cleans `%SystemRoot%\SoftwareDistribution\Download`
  every 90 days, "will wait until the Windows Update service finishes running". `TempTask -Register`:
  every 60 days, **only files older than one day**; documented path list includes
  `%SystemDrive%\$WinREAgent, $SysReset, $Windows.~WS, $GetCurrent, ESD, Intel, PerfLogs`,
  NetworkService temp, `%LOCALAPPDATA%\CrashDumps`, `tw-*.tmp`. (README confirms same lists — DOCUMENTED+IMPLEMENTED.)
- **IMPLEMENTED** — `RegistryBackup -Enable` (preset default): restores Win10-1803-removed registry backup
  via `EnablePeriodicBackup`/`BackupCount` + RegIdleBackup task (mirrors WinUtil's feature).

### 2.3-8 License terms & the Wrapper relationship
- **IMPLEMENTED** — LICENSE file is verbatim MIT: "MIT License / Copyright (c) 2023 farag2 / Permission
  is hereby granted, free of charge…" with the standard warranty disclaimer; **no extra clauses** (the
  "specific licensing terms" sometimes attributed to this project are not present in the LICENSE).
  Manifest: `(c) 2014—2026 Team Sophia`; LicenseUri points at the LICENSE file.
- **DOCUMENTED** — Release notes 8.1.0: "The Wrapper's story has come to end: https://t.me/SophiaNews/5470
  — The Wrapper was removed from the repository and it will stopped working — @BenchTweakGaming has opened
  its sources (https://github.com/BenchTweakGaming/SophiaScriptWrapper)". I.e. the Sophia Script *Wrapper*
  (a third-party GUI by BenchTweakGaming that bundled the script) was dropped in 8.1.0 and is dead.
- **IMPLEMENTED** — No Wrapper files exist in the current repository tree (root contents listing).
- SophiApp 2.0 (C# + WinUI 3, Sophia-Community/SophiApp) is the successor GUI project — **DOCUMENTED**
  (README), not inspected.

### 2.3-9 Security-relevant behavior
- **IMPLEMENTED** — Defender *hardening* functions (preset enables several): `NetworkProtection -Enable`
  (Exploit Guard network protection), `PUAppsDetection -Enable` (PUA protection), `DefenderSandbox -Enable`
  (restart needed), `EventViewerCustomView -Enable` (process-creation auditing incl. PowerShell script
  logging + custom Event Viewer view), `AppsSmartScreen -Enable` (default preset KEEPS SmartScreen on).
- **IMPLEMENTED** — `SaveZoneInformation -Disable` removes Mark-of-the-Web — **security-relevant
  weakening**; it is selected in the default preset.
- **IMPLEMENTED** — `AdminApprovalMode -Never` sets `ConsentPromptBehaviorAdmin=0` (no UAC prompt for
  admins) — but note `EnableLUA` stays 1 and PromptOnSecureDesktop=1, so UAC itself is not disabled.
  Selected in the default preset; `-Default` restores value 5.
- **IMPLEMENTED** — `LocalSecurityAuthority -Enable` (LSA protection, commented out by default);
  `DiagnosticDataLevel -Minimal` is edition-honest (Home/Pro get 1, not 0).
- **IMPLEMENTED** — Guard chain treats security as a precondition: refuses to run under third-party AV
  detection anomalies, missing Defender binaries, enabled Controlled Folder Access, pending reboots,
  non-Secure-Boot (warning), stale UEFI CA 2023 certs, and systems tainted by known harmful tweakers
  (incl. `defendnot`, which removes Defender) — with "Reinstall Windows" advice.

### 2.3-10 Hardware-specific logic
- **IMPLEMENTED** — `GPUScheduling -Enable` (hardware-accelerated GPU scheduling, default preset): note in
  source "Only if you have a dedicated GPU and the WDDM version is 2.7 or higher" (restart needed).
- **IMPLEMENTED** — `WindowsAI -Disable` probes for an **NPU**: `Win32_PnPEntity` where
  `PNPClass -eq "ComputeAccelerator"` and warns "PCNPUSupport" if none; disables Recall via
  `Disable-WindowsOptionalFeature -FeatureName Recall` and removes `Microsoft.Copilot` appx.
- **IMPLEMENTED** — Architecture gate (CIM_Processor.Architecture = 9 x64; ARM has its own build);
  `PowerPlan -High` "Not recommended for laptops"; `Hibernation -Disable` "Not recommended for laptops";
  `NetworkAdaptersSavePower -Disable` (PnP power management on NICs) "Not recommended for laptops".
- **IMPLEMENTED** — Initial checks force `AutomaticManagedPageFile=$true` and SysMain on (stability bias
  over "optimization").

## 2.4 Useful ideas for NEXTRIX (from Sophia Script)
1. **Build+UBR guard data as a versioned JSON** in the repo, fetched at runtime with a pinned offline
   fallback — decouples "supported builds" policy from code. (IMPLEMENTED)
2. **Refuse-and-redirect refusal UX**: when the build is unsupported, don't just exit — enable MU updates
   and open Windows Update so the user can fix the precondition. (IMPLEMENTED)
3. **Preflight health probes before any change** (Defender present & default, WMI providers, pending
   reboot, Store/CBS present) — fail fast on compromised systems rather than mid-run. (IMPLEMENTED)
4. **Harmful-tweaker fingerprint list** with per-tool file/registry probes — refuses to operate on systems
   damaged by other optimizers; protects NEXTRIX's own reputation and diagnostics. (IMPLEMENTED)
5. **Paired parameter sets as the undo model** + the preset always showing the restore call next to the
   applied call — undo is never more than one documented invocation away. (IMPLEMENTED)
6. **Policy hygiene**: strip `Policies\*` overrides "to make changes visible in UI", set real setting keys,
   and (where gpedit visibility matters) write true Registry.pol entries via Add-Policy/Remove-Policy
   with a single write-back in PostActions. (IMPLEMENTED)
7. **DNS change with verify-and-auto-rollback** (resolve probe before/after, 2 attempts, revert on
   failure) — the pattern NEXTRIX should require for any network-path change. (IMPLEMENTED)
8. **Destructive-op preconditions**: OneDrive uninstall refuses when signed-in and only deletes empty
   folders; BitLocker prompt only when state is inconsistent; restore point never skipped. (IMPLEMENTED)
9. **Cross-function dependency warnings** (RecommendedTroubleshooting reports that it overrides previously
   set DiagnosticDataLevel/ErrorReporting). (IMPLEMENTED)
10. **Cleanup tasks that respect system activity**: SoftwareDistribution task waits for WU to finish; Temp
    task deletes only files older than 1 day; DISM cleanup without /ResetBase keeps updates uninstallable.
    (IMPLEMENTED)
11. **Per-variant distribution matrix** (PS5.1/PS7 × Home/LTSC/ARM) with its own version numbers — clear
    compatibility surface. (IMPLEMENTED)
12. **Edition-aware telemetry floor** (AllowTelemetry=0 only on Enterprise/Education) — honest, documented
    behavior instead of a placebo value. (IMPLEMENTED)
13. **P/Invoke WinAPI helper for things PowerShell can't do safely** (native DNS resolve, shell32
    localized strings, toast AppUserModelId) instead of external binaries. (IMPLEMENTED)

## 2.5 Reject / caution (Sophia Script)
- **Reject for NEXTRIX defaults**: `SaveZoneInformation -Disable` (disables MOTW) and
  `AdminApprovalMode -Never` (silent elevation) — both are selected in the stock preset and both weaken
  security; NEXTRIX should keep them opt-in with explicit warnings at most. (IMPLEMENTED)
- **Caution — guard strictness**: refusing to run below the *latest* patch UBR (26300.9974) is stricter
  than feature-compatibility requires; NEXTRIX should pin per-feature build ranges rather than "current
  patch level only", or the playbook bricks itself whenever Microsoft ships a newer UBR than the pinned
  JSON (the online JSON mitigates this; the offline fallback goes stale). (IMPLEMENTED)
- **Caution**: the refusal path *mutates the system* (sets AllowMUUpdateService=1, triggers scans) before
  exiting — a "check" with side effects; NEXTRIX checks should be read-only. (IMPLEMENTED)
- **Caution**: `ErrorReporting -Disable` fully disables WerSvc — side effects on troubleshooters are
  only partially compensated (RecommendedTroubleshooting re-enables it, with warning). (IMPLEMENTED)
- **Caution**: no batch undo / no change journal — restoring means re-running paired functions one by one;
  only the restore point and transcript limit damage. (IMPLEMENTED)
- **Caution**: `CleanupTask` force-kills running cleanmgr/DISM processes. (IMPLEMENTED)
- **Caution**: wrong-variant selection (Win11 build on Win10) exits — 10 archives/variants is a UX hazard
  NEXTRIX should solve with a single auto-detecting entry point. (IMPLEMENTED)
- **Caution (license/community policy)**: while the LICENSE is plain MIT, the project's maintainer
  actively opposes wrapper GUIs (Wrapper removed & killed in 8.1.0). Anyone building a NEXTRIX GUI on top
  of Sophia code should respect that stance; code reuse itself is MIT-permitted with attribution.
  (IMPLEMENTED license + DOCUMENTED release notes)

## 2.6 Research limitations (Sophia Script)
- The defunct Wrapper repository (BenchTweakGaming/SophiaScriptWrapper) could not be verified: the GitHub
  API returned **HTTP 403** (blocked/private or rate-limited) — its current state is unknown.
- The Telegram announcement behind the Wrapper removal (https://t.me/SophiaNews/5470) was not fetched
  (messaging-platform content); the Wrapper story is evidenced only by the 8.1.0 release notes text.
- `CHANGELOG.md` (133 KB) was not read; version history beyond 8.1.0/7.1.0 release notes is unexamined.
- Only the **Windows 11 v8.1.0 (PS5.1)** variant's sources were inspected (Sophia.ps1, InitialActions.ps1,
  Sophia.psm1 partially — 121 function signatures enumerated, ~1,960 of 10,419 lines read in full plus
  targeted function reads; functions not read in full: Uninstall-UWPApps body, WindowsFeatures/
  WindowsCapabilities dialogs, Set-UserShellFolderLocation, Install-WSL, Export/Import-Associations, etc.).
  The Windows 10 v7.1.0, LTSC and ARM variants were not opened; their build floors are known only from
  `supported_windows_builds.json`.
- `CODE_SIGNING_POLICY.md`, `Scripts/Lint.ps1`, localizations, and SophiApp 2.0 were not inspected.
- `WinAPI.ps1` (22 KB P/Invoke helpers) was not read in full; its roles (GetStrings, Winbrand, DnsClient
  resolve, toasts) are cited from call sites in the files I did read.
- Nothing was executed; all findings are static source analysis (per mandate).

---

## Cross-project notes for the NEXTRIX engine decision
- Two viable PowerShell engine shapes observed: **data-driven compiled monolith with generic executors**
  (WinUtil: JSON declares registry/service/script/appx changes + undo metadata; one engine applies/undoes
  any entry) vs. **code-driven module with paired-parameter functions** (Sophia: every tweak is a named,
  documented, self-reversing function behind a strict guard chain). For a rollback-safe playbook, WinUtil's
  undo-metadata schema and Sophia's guard/verify patterns are complementary.
- Both create System Restore points (WinUtil: optional-but-first; Sophia: forced) and log to local files
  (WinUtil: `%LocalAppData%\winutil\logs\winutil_*.log`; Sophia: `Start-Transcript` in script folder).
- Neither project publishes performance benchmarks; no DEV-BENCHMARK or VERIFIED claims were found in
  either repository, so no performance numbers from these projects may be cited for NEXTRIX.
- Both implement DNS-over-HTTPS via the same registry location
  (`...\Services\Dnscache\InterfaceSpecificParameters\<GUID>\DohInterfaceSettings`) — a NEXTRIX DNS module
  can follow either; Sophia adds verify-and-rollback, WinUtil adds provider data + latency benchmark.
- Windows 11 26H2 (build 26300) is the current Win11 target for Sophia (released Sept 2026 per the
  Microsoft update-history link in its README); WinUtil tracks Windows 10 and 11 without a guard. Any
  NEXTRIX build matrix must decide between WinUtil-style tolerance and Sophia-style pinning.

Access date: 2026-11-23. Researcher: NEXTRIX subagent R5.
