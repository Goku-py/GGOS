# NEXTRIX Reference Research — R4: SynergyOS, SynToolkit, UltraOS Playbook

Read-only web research for Phase 1 (reference-project research). No Windows settings were
modified, no tweak or script was executed on the host, and no repository file was changed.
All findings below were obtained by fetching public GitHub API metadata, repository file
trees, and raw source files (`raw.githubusercontent.com`), plus release notes and issue pages.

**Evidence tag legend (each finding carries exactly one tag):**
- **IMPLEMENTED** — verified in source actually read; file path / URL cited.
- **DOCUMENTED** — official README/site/release-note claim, not (or only partially) verified against source.
- **COMMUNITY-CLAIM** — third-party statement (e.g., user issue report); not independently reproduced.
- **DEV-BENCHMARK** — developer-reported performance numbers. **None were found in any inspected
  material for these three projects** (SynergyOS markets "latency" in topics/badges but publishes
  no numbers in the files read; UltraOS explicitly refuses benchmark claims). No DEV-BENCHMARK findings exist in this file.
- **VERIFIED** — independently verified performance results. **None.** No benchmarks were run (read-only
  research mandate; no test VM available to this subagent). No advertised feature or benchmark is
  treated below as proof of performance.

---

## Project 1 — SynergyOS

### 1.1 Identity table

| Field | Value | Evidence |
|---|---|---|
| Name | SynergyOS — AME Wizard playbook ("Simple Lightweight Playbook… performance optimizations and privacy improvements") | IMPLEMENTED — [api.github.com/repos/Synergy-Tweaks/SynergyOS](https://api.github.com/repos/Synergy-Tweaks/SynergyOS) |
| Repo | https://github.com/Synergy-Tweaks/SynergyOS (default branch `main`, Batchfile primary language, 50 stars / 6 forks) | IMPLEMENTED — repo API |
| License | **NONE.** No LICENSE file exists anywhere in the file tree (recursive tree listing inspected) and the GitHub API reports `license: null`. Default copyright (all rights reserved) applies to all SynergyOS code. | IMPLEMENTED — tree API `git/trees/main?recursive=1` (no LICENSE path present); repo API `license: null` |
| Latest release | Tag `1.7`, titled "SynergyOS v0.7", published **2026-10-23**; asset `SynergyOS.apbx` (21.4 MB, sha256 `a2861380…68eef`, 1,533 downloads). Repo `main` is ahead of the release: `playbook.conf` declares **Version 1.8.0**. (Tag/title/conf versioning is inconsistent: tag 1.7, title v0.7, conf 1.8.0.) | IMPLEMENTED — [releases/latest API](https://api.github.com/repos/Synergy-Tweaks/SynergyOS/releases/latest); [playbook.conf](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/playbook.conf) |
| Supported Windows (from code, not claims) | `SupportedBuilds`: **19044, 19045, 22000, 22621, 22631, 22635, 26100, 26200, 26300** → Windows 10 21H2/22H2 and Windows 11 21H2 through 26H2 (incl. one Beta build, 22635). README badge says "Windows 11 & 10"; README text says "clean, stock Windows ISO (22H2 through 26H2, LTSC supported)" — LTSC builds (e.g. 19044-based LTSC) are not separately enumerated in code. | IMPLEMENTED — playbook.conf `SupportedBuilds`; DOCUMENTED — [readme.md](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/readme.md) |
| Engine / dependencies | AME Wizard (Ameliorated) — installation guide links `https://download.ameliorated.io/AME%20Beta.zip` (the "AME Beta" build). **No specific AME Wizard minimum version is pinned anywhere in the repo.** Runtime prerequisites: .NET 8 Desktop Runtime (x64+x86 downloaded from aka.ms); `NoDefender.cab` bundled in repo; bundled third-party executables: MinSudo.exe, PowerRun.exe, GoInterruptPolicy.exe, Autoruns.exe, DeviceCleanup.exe, RunAsTI.reg. | IMPLEMENTED — [docs/Installation Guide.md](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/docs/Installation%20Guide.md); [Configuration/Tasks/software.yml](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Configuration/Tasks/software.yml); tree listing |
| Wizard-enforced requirements | `DefenderToggled`, `NoPendingUpdates`, `NoAntivirus`, `Internet`, `PluggedIn`, `PasswordSet`; `UpgradableFrom: any`; `SupportsISO: true` (ISO injection: `DisableBitLocker=true`, `DisableHardwareRequirements=true`); OOBE `Internet: Force` | IMPLEMENTED — playbook.conf |
| Structure | `Configuration/custom.yml` (orchestrator, trustedInstaller privilege) + `Configuration/Tasks/{registry/{settings,privacy}.yml, services.yml, software.yml, package/{appx,components}.yml, updates/{update,driver}.yml}`; `Executables/` (~50 .bat/.ps1/.reg files + `SOS/` post-install toggle folder + bundled binaries); `playbook.conf`; `readme.md`; `docs/Installation Guide.md`; `.github/workflows/release.yml` | IMPLEMENTED — tree API + files read |

URLs actually inspected for SynergyOS: repo API, tree API, releases/latest API, `readme.md`,
`playbook.conf`, `Configuration/custom.yml`, `Configuration/Tasks/registry/settings.yml`,
`Configuration/Tasks/registry/privacy.yml`, `Configuration/Tasks/services.yml`,
`Configuration/Tasks/updates/update.yml`, `Configuration/Tasks/updates/driver.yml`,
`Configuration/Tasks/software.yml`, `Configuration/Tasks/package/appx.yml`,
`Configuration/Tasks/package/components.yml`, `Executables/DisableDefender.ps1`,
`Executables/DisableDefenderServices.bat`, `Executables/backup.ps1`, `Executables/suitability.ps1`,
`Executables/devices.ps1`, `Executables/mitigations.bat`, `Executables/vbs.bat`,
`Executables/power.bat`, `Executables/network.bat`, `Executables/final.bat`,
`Executables/SOS/2. Main Configuration/Mitigations/off.bat`,
`Executables/SOS/3. Optional Configuration/Win32 Priority Seperation/24 (SOS Default).reg`,
`docs/Installation Guide.md`, issues list page, issues #3 and #20.

### 1.2 Findings by area

#### Installation flow and gating
- Orchestrator `custom.yml` runs everything as **trustedInstaller** privilege, starting with
  `suitability.ps1`, then `reg import RunAsTI.reg` (a TrustedInstaller-rights registry shim), file
  copies (`Windows`→`%windir%`, `SOS`→`%systemdrive%\SOS`), then option-gated Defender teardown,
  then the task files, ending with `visuals.bat`, `ngen.ps1`, `final.bat`, `updhealth.bat`,
  `cleanup.ps1`. **[IMPLEMENTED]** — [custom.yml](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Configuration/custom.yml)
- `suitability.ps1` gates the install to **fresh, non-OEM systems only**: if `C:\SOS` exists it exits 0
  (already installed); if `HKLM\…\OEMInformation` has any of Manufacturer/Model/SupportURL non-empty it
  shows "Custom OS/OEM installations are not supported. Please try again on a fresh installation of
  Windows." and kills the AME process. It performs **no hardware checks**. **[IMPLEMENTED]** — [suitability.ps1](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Executables/suitability.ps1)
- The wizard's `DefenderToggled` requirement is satisfied manually: the install guide instructs the
  user to disable Real-Time/Cloud/Sample/Tamper protection in Windows Security before continuing.
  **[DOCUMENTED]** — docs/Installation Guide.md (Step 3 screenshots)

#### Option/checkbox model
- Default-checked options (applied unless user unchecks): **Remove Edge (labeled irreversible)**,
  **Disable Xbox Services (reversible)**, **Install SynToolkit**. Default-unchecked security
  trade-offs: Disable VBS/HVCI, Disable Defender (labeled permanent), Disable Exploit Mitigations;
  UAC is a radio page defaulting to Enable. **[IMPLEMENTED]** — playbook.conf FeaturePages
- README's security table states the trade-offs plainly (Defender = "Permanent component teardown";
  mitigations = "most anti-cheats refuse to run"; UAC = "UWP/Store apps stop working"; VBS =
  "LSA Protection is what stops credential-dumping tools reading lsass"). **[DOCUMENTED]** — readme.md

#### Registry modifications observed (selection; all **[IMPLEMENTED]** from the cited files)
- Identity/branding: `HKLM\…\OEMInformation` Model/Manufacturer/SupportURL; `RegisteredOwner` /
  `RegisteredOrganization`; BCD boot description "SynergyOS 11/10" set per build in `final.bat`.
  — custom.yml; final.bat
- UAC (`Policies\System`): `EnableLUA`, `PromptOnSecureDesktop`, `ConsentPromptBehaviorAdmin`,
  `ValidateAdminCodeSignatures` (enable=1/1/5/0, disable=0/0/0/0). — custom.yml
- Scheduling/CPU: `PriorityControl\Win32PrioritySeparation = 36` (0x24; the SOS folder also ships
  picker .reg files for 16/18/22/24/26/28 with "24 (SOS Default)" — both 24 and 36 decimal appear;
  36 is what the playbook actually writes). — settings.yml; `24 (SOS Default).reg`
- MMCSS: `Multimedia\SystemProfile` `SystemResponsiveness=10`, `NetworkThrottlingIndex=10`,
  `NoLazyMode=1` (final.bat). Note UltraOS records stock `SystemResponsiveness` as 20.
- Timer/kernel: `Session Manager\kernel` `SerializeTimerExpiration=1`, `TimerCheckFlags=0` (final.bat);
  `DisableWpbtExecution=1` (WPBT/OEM firmware binaries blocked; written twice — settings.yml and final.bat).
- `Session Manager\Power`: `HiberbootEnabled=0` (Fast Startup off), `IdleScanInterval=0`.
- `SvcHostSplitThresholdInKB = 4294967295` (svchost split forced off machine-wide). — final.bat
- GPU: `GraphicsDrivers\HwSchMode = 2` (**HAGS force-enabled**, no GPU-capability check);
  `DirectX\UserGpuPreferences` `SwapEffectUpgradeEnable=1` (windowed-game optimization). — final.bat
- Input: `Control Panel\Mouse` `MouseSpeed=0`, `MouseSensitivity=10`, `MouseHoverTime=0`;
  ctfmon/text-input neutralized via `HKLM\SOFTWARE\Microsoft\Input` `InputServiceEnabled=0`,
  `InputServiceEnabledForCCI=0` and `TextInputManagementService\Parameters\ServiceDll` repointed to
  `MSCTF.DLL`. — settings.yml; final.bat
- Privacy: `AllowTelemetry=0` (two paths), `DisableWindowsConsumerFeatures=1`, `DisableInventory=1`,
  `DisableUAR=1`, `DisablePCA=1` (+`PcaSvc` Start=4), AdvertisingInfo `Enabled=0`, TIPC `Enabled=0`,
  location policies off, biometrics `Enabled=0`. — privacy.yml
- **Security-relevant privacy writes:** `Policies\Attachments\SaveZoneInformation=1` (kills
  Mark-of-the-Web on downloaded files) and Edge `PhishingFilter\EnabledV9=0` (SmartScreen off in
  Edge). — privacy.yml
- Updates: quality/feature updates paused to **2038-01-19** via `WindowsUpdate\UX\Settings`
  `Pause*EndTime`, `NoAutoUpdate=1`, `AUOptions=2`, `DoNotConnectToWindowsUpdateInternetLocations=1`,
  Insider `AllowBuildPreview=0`, `BlockedOobeUpdaters=["MS_Outlook"]`, MRT
  `DontReportInfectionInformation=1`. — update.yml (README confirms "Windows Update is paused
  (until 2038) by this playbook regardless of the options above" and the Settings page is left
  reachable so the user can resume.)
- Drivers: `ExcludeWUDriversInQualityUpdate=1` on four paths, `DriverSearching\SearchOrderConfig=0`,
  `DontSearchWindowsUpdate=1`, `PreventDeviceMetadataFromNetwork=1` — **Windows Update driver
  delivery is fully blocked.** — driver.yml
- Widgets workaround: comment in settings.yml states "TaskbarDa is protected by UCPD on 24H2+
  (Access denied), use the policy instead" → `Policies\Dsh\AllowNewsAndInterests=0`. — settings.yml
- GameBar: `UseNexusForGameBarEnabled=0` and `HKCR\ms-gamebar` protocol repointed to `systray.exe`;
  GameDVR off (`AppCaptureEnabled=0`, `AllowGameDVR=0`). — settings.yml; final.bat
- Explorer/shell: classic context menu CLSID `{86ca1aa0-…}\InprocServer32`, `HideFileExt=0`,
  `TaskbarAl=0`, `SearchboxTaskbarMode=0`, `HideRecommendedSection=1`, 13 "This PC" namespace keys
  re-added, Gallery namespace key deleted, 25H2 `HideCategoryView=1`. — settings.yml; final.bat
- Memory compression disabled via `Disable-MMAgent -MemoryCompression` — with an inline comment
  that `Disable-MMAgent` requires SysMain running (error 1058 otherwise), so SysMain is temporarily
  started (Manual) before `services.yml` disables it again. — settings.yml

#### Service configurations
- **49 services set to startup=4 (Disabled)** — full list in file: AxInstSV, bam,
  **BcastDVRUserService_389fd** (note: per-build suffix `_389fd` is hardcoded — on other builds the
  per-user-service suffix differs, a known AME-playbook fragility), BDESVC (BitLocker), Beep, CldFlt,
  CscService, diagsvc, DiagTrack, dmwappushservice, dps, dusmsvc, Fax, icssvc, **LanmanServer**
  (file/printer sharing server), lltdio, MsLldp, kdnic, lfsvc, lltdsvc, MapsBroker, NetBIOS, NetBT,
  NetTcpPortSharing, onecyncsvc, pcasvc, PhoneSvc, PrintNotify, PrintWorkflowUserSv, rspndr, QWAVE,
  RemoteAccess, RetailDemo, ScDeviceEnum, SEMgrSvc, SharedAccess, **Spooler** (printing),
  SSDPSRV, stisvc, sysmain, TrkWks, TroubleshootingSvc, UevAgentService, WdiServiceHost,
  WdiSystemHost, wercplsupport, WerSvc, wisvc, WMPNetworkSvc, WpcMonSvc. All applied with
  `iso: true` (offline injection preferred "more reliable than at first boot"). **[IMPLEMENTED]** — [services.yml](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Configuration/Tasks/services.yml)
- Under `disable-defender`: **17 security/Defender services disabled** via MinSudo
  (`--TrustedInstaller --Privileged`): MsSecCore, MsSecFlt, MsSecWfp, SecurityHealthService, Sense,
  WdBoot, WdFilter, WdNisDrv, WdNisSvc, WinDefend, **wscsvc** (Windows Security Center), MDCoreSvc,
  SgrmAgent, SgrmBroker, webthreatdefsvc, webthreatdefusersvc — plus `SecHealthUI` AppX removal and
  `SecurityHealth` Run-key deletion. **[IMPLEMENTED]** — [DisableDefenderServices.bat](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Executables/DisableDefenderServices.bat); appx.yml; settings.yml
- Under `remove-edge`: `edgeupdate`, `edgeupdatem`, `MicrosoftEdgeElevationService` **deleted**
  (operation: delete), Edge AppX family removed, Deprovisioned keys added. OneDrive:
  `OneSyncSvc*` service deleted, OneDriveSetup.exe files deleted. AI: `WSAIFabricSvc` service
  deleted. **[IMPLEMENTED]** — [components.yml](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Configuration/Tasks/package/components.yml)

#### Scheduled task changes
- `schtasks /Change /TN "\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem" /Disable`.
  **[IMPLEMENTED]** — settings.yml
- `\Microsoft\Windows\WindowsAI` task **folders deleted** (`deleteFolder` for `WindowsAI\Recall`,
  `WindowsAI\Settings`, and `WindowsAI` itself). **[IMPLEMENTED]** — components.yml
- Diagnostic event logs disabled with `wevtutil set-log … /e:false` for SleepStudy,
  Kernel-Processor-Power, UserModePowerService. **[IMPLEMENTED]** — settings.yml

#### Power settings
- `powercfg /h off` (hibernation off); custom power plan `SOS.pow` imported as fixed GUID
  `77777777-7777-7777-7777-777777777777` (existing plan with that GUID deleted first) and set
  active. **[IMPLEMENTED]** — [power.bat](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Executables/power.bat)
- **Blanket device power-management disable:** a `reg query HKLM\SYSTEM\CurrentControlSet\Enum /s /f`
  loop zeroes 13 power values (`EnhancedPowerManagementEnabled`, `AllowIdleIrpInD3`,
  `EnableSelectiveSuspend`, `DeviceSelectiveSuspended`, `SelectiveSuspendEnabled`,
  `SelectiveSuspendOn`, `EnumerationRetryCount`, `ExtPropDescSemaphore`, `WaitWakeEnabled`,
  `D3ColdSupported`, `WdfDirectedPowerTransitionEnable`, `EnableIdlePowerManagement`,
  `IdleInWorkingState`) on **every device instance found** — no per-device capability check.
  **[IMPLEMENTED]** — power.bat
- `Control\Power`: `EnergyEstimationEnabled=0`, `SleepStudyDisabled=1`, `CoalescingFlushInterval=0`,
  `CoalescingTimerInterval=0`, `EventProcessorEnabled=0`, `FxAccountingTelemetryDisabled=1`,
  `SleepstudyAccountingEnabled=0`, `MSDisabled=1`, `PlatformAoAcOverride=0`, `PlatformRoleOverride=0`;
  `usbflags`: `DisableHCS0Idle=1`, `Allow64KLowOrFullSpeedControlTransfers=1`; NVMe:
  `stornvme\Parameters\Device` `IdlePowerMode=0`, `DisableDSTThrottle=1`; `Storage`:
  `StorageD3InModernStandby=0`. WMI `MSPower_DeviceWakeEnable` / `MSPower_DeviceEnable` set
  `Enable=false`. **[IMPLEMENTED]** — power.bat
- `final.bat` additionally zeroes `UserWriteCacheSetting=1` across all SCSI Enum device parameters
  (disk write-cache policy) and disables DMA remapping: queries every `Services` subkey for
  `DmaRemappingCompatible` and sets it to 0 wherever found. **[IMPLEMENTED]** — final.bat

#### CPU / GPU / hardware-specific logic
- **Network adapters (the strongest hardware-aware code in the repo):** `network.bat` enumerates the
  NIC class key `{4D36E972-E325-11CE-BFC1-08002bE10318}`, skips virtual/remote adapters via a
  term list (microsoft miniport, virtual, kernel debug, bluetooth, teredo, tunnel, loopback, tap-,
  openvpn, wireguard, vmware, virtualbox, hyper-v, npcap, ras, async, pppoe, wintun, zerotier,
  hamachi, tailscale, nordlynx), requires the adapter to be present via `Get-NetAdapter`, then sets
  ~25 advanced keywords (`*EEE`, `*FlowControl`, `*InterruptModeration`, `*JumboPacket` cap 1514,
  `*LsoV2IPv4/6`, `*RscIPv4/6`, `*RSS=1`, `*ReceiveBuffers` cap 1024, `*TransmitBuffers` cap 512,
  wake/WoL off, `*SelectiveSuspend`, Realtek set: GreenEthernet/GigaLite/PowerSavingMode…, Intel
  set: `ULPMode`, `SipsEnabled`, `ITR`…). **Capability-aware:** each keyword is only written after
  reading the driver's `Ndi\Params\<Keyword>` `type`/`min`/`max`/`enum` — "Missing keywords are
  skipped (NIC-specific detection)", EXACT/MIN/CAP modes clamp to the driver-allowed range.
  **[IMPLEMENTED]** — [network.bat](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Executables/network.bat)
- GPU-vendor materials are shipped as **links/manual tools, not automated detection**: `SOS/1.
  Graphics Configuration/{AMD,Intel,Nvidia}` hold .url shortcuts (NVCleanstall, Radeon Slimmer,
  NVIDIA Profile Inspector, "Imribiy's AMD Tweaks", Kwanteks' GPU Debloat Guide) plus an
  experimental Intel iGPU .reg set (`Disallow Deep CStates`, `No Delayed Detection for DP and
  HDMI`, `Disable HDMI Deep Color`, `Disable Overlay Quality Enhancement`, `Disable Color
  Features`) and a 24 KB NVIDIA `.nip` profile (`Synergy.nip` for Profile Inspector, binary not
  inspected). `HwSchMode=2` (HAGS on) is applied unconditionally with no GPU support check.
  **[IMPLEMENTED]** — tree listing; final.bat
- Build detection in `final.bat` parses `ver` to branch branding at 22000 (Win11 vs Win10 naming).
  **[IMPLEMENTED]** — final.bat
- Three PnP devices disabled outright via `Disable-PnpDevice`: Composite Bus Enumerator, Microsoft
  RRAS Root Enumerator, Microsoft GS Wavetable Synth. **[IMPLEMENTED]** — [devices.ps1](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Executables/devices.ps1)
- `GoInterruptPolicy.exe` (Microsoft Sysinternals-era interrupt-affinity tool) is bundled in
  `SOS/3. Optional Configuration` as a manual tool — no scripted interrupt-affinity logic exists in
  the repo. **[IMPLEMENTED]** — tree listing

#### Windows build compatibility approach
- Hard gate = AME Wizard `SupportedBuilds` list (19044–26300). Per-build behavior is otherwise ad
  hoc: one inline comment about UCPD/TaskbarDa on 24H2+, the 22000 branding branch, the hardcoded
  `BcastDVRUserService_389fd` suffix, and release notes calling 26H2 "experimental, unexpected
  bugs may arise". There is **no systematic build-conditional layer** (no per-build task gating in
  the files read). **[IMPLEMENTED]** — playbook.conf; settings.yml; services.yml; release notes

#### Rollback / undo / backup mechanisms — and their limits
- The playbook relies primarily on **AME Wizard's native re-run model** (`UpgradableFrom: any`,
  README: "re-open AME Wizard and click Run Again"). **[IMPLEMENTED/DOCUMENTED]** — playbook.conf; readme.md
- `Executables/backup.ps1` exports **only the `Start` dword of every service** to a .reg file
  (path passed as parameter). It does not back up registry values, AppX inventory, scheduled
  tasks, BCD, or power schemes. **No invocation of backup.ps1 was found in any playbook file read**
  (`custom.yml` never references it), so its role in the live install flow is unconfirmed — possibly
  an engine convention or a vestigial helper. **[IMPLEMENTED]** — [backup.ps1](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Executables/backup.ps1)
- Post-install `C:\SOS` toggle pairs exist for **Mitigations on/off, VBS on/off, UAC on/off,
  Bluetooth, Wi-Fi, Print, Xbox services** — the Mitigations `off.bat` dynamically enumerates every
  `Set-ProcessMitigation -Disable` valid value from the cmdlet's own parameter metadata, then
  writes the kernel `MitigationOptions`/`MitigationAuditOptions` masks (all-2s) and
  `FeatureSettingsOverride=3/Mask=3`; `on.bat` is the 552-byte inverse. **[IMPLEMENTED]** — tree; [Mitigations/off.bat](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Executables/SOS/2.%20Main%20Configuration/Mitigations/off.bat)
- Irreversibles (project's own labels): Edge removal "irreversible" (reinstall possible, playbook
  reversal not provided); Defender removal "permanent" — release notes: "If you removed defender in
  previous version then you'll need to reinstall windows to apply this version." **[DOCUMENTED]** —
  playbook.conf labels; release notes; readme.md
- BCD edits in `final.bat` have **no backup/undo path in the repo** (see safety section).
  **[IMPLEMENTED]** — final.bat

#### Known compatibility issues
- Release v1.7 notes: 26H2 support "experimental, Unexpected bugs may arise"; "Removed Defender
  Removal Checkbox as it was causing bugs with removal" (yet the checkbox is present again in
  `main`'s playbook.conf v1.8.0); ISO injection still under development and requires re-running the
  playbook after installing a modified ISO. **[DOCUMENTED]** — releases/latest body
- Issue #20 "When use playbook in 26H2 but complete with error every time" (closed without logs):
  maintainer reply states "Completed with errors is usually non-fatal," and identifies
  `RegistryValueAction failed to add value 'TaskbarDa'` as "a known non-critical registry write
  that fails on some systems" — matching the UCPD comment in settings.yml. **[COMMUNITY-CLAIM]**
  (user report) + **[DOCUMENTED]** (maintainer's cause statement) — [issue #20](https://github.com/Synergy-Tweaks/SynergyOS/issues/20)
- Issues #3 and #8: "all apps running slow on 25h2" reported by users (and acknowledged by the lead
  developer in #3, marked "Fixed for next release" Jul 13, 2026) with a **recurrence** in SOS 0.5
  ("same problem with 0.4.1") — root cause never stated in the issue threads. **[COMMUNITY-CLAIM + DOCUMENTED]** — issues #3, #8
- Other closed issues (titles only, bodies not read): #11 Microsoft Account Sign In Issue; #9 Export
  of .nip files; #7 "Brave / Toolkit doesn't get installed through Ame when running playbook"; #4
  "Start menu pins doesn't get cleared". **[COMMUNITY-CLAIM]** — issues list page

#### Safety-relevant behavior
- **Defender teardown (option-gated, default off):** `DisableDefender.ps1` installs
  `C:\Windows\NoDefender.cab` via `Add-WindowsPackage -Online`, verifies the cab's Authenticode
  EKU `1.3.6.1.4.1.311.10.3.6`, and **adds a test-signing certificate
  (`8A334AA8…F344`) to the Trusted Root store that is intentionally never removed** ("isn't
  cleared later as it's required for the alt repair source"). Followed by the 17-service disable
  above. **[IMPLEMENTED]** — [DisableDefender.ps1](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Executables/DisableDefender.ps1); DisableDefenderServices.bat
- **Exploit mitigations off (option-gated):** `MitigationOptions` kernel binary mask set to 48
  bytes of `2` (every per-process mitigation disabled), CFG/SEHOP/XFG suppression keys,
  Spectre/Meltdown `FeatureSettingsOverride=3/Mask=3`. **[IMPLEMENTED]** — [mitigations.bat](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Executables/mitigations.bat)
- **VBS/HVCI/Credential Guard/LSA Protection off (option-gated):** `DeviceGuard`
  `EnableVirtualizationBasedSecurity=0`, `RequirePlatformSecurityFeatures=0`, HVCI `Enabled=0`,
  `Lsa\RunAsPPL=0`, `LsaCfgFlags=0`. Notably, `vbs.bat` on `main` contains a self-referential
  comment: "Referenced by Tasks\registry\settings.yml (option: disable-vbs) but was missing from
  the repo" — evidence that a referenced script was absent from the shipped tree at some point.
  **[IMPLEMENTED]** — [vbs.bat](https://raw.githubusercontent.com/Synergy-Tweaks/SynergyOS/main/Executables/vbs.bat)
- **UAC off (option-gated):** `EnableLUA=0` etc. **[IMPLEMENTED]** — custom.yml
- **BCD edits (unconditional):** `bcdedit /timeout 5`, `/set nx optin` (DEP softened for OS
  components), **`/set disabledynamictick yes`**, **`/deletevalue useplatformclock`**,
  **`/deletevalue useplatformtick`**, `/set bootmenupolicy Legacy`. No pre-change BCD backup
  exists in the repo. **[IMPLEMENTED]** — final.bat
- **Timer forcing:** `SerializeTimerExpiration=1`, `TimerCheckFlags=0` (kernel timer behavior),
  alongside the dynamic-tick BCD change — the HPET/timer-forcing pattern NEXTRIX should treat with
  caution. **[IMPLEMENTED]** — final.bat
- `Set-ExecutionPolicy Unrestricted -Force` for PowerShell. **[IMPLEMENTED]** — final.bat
- Mark-of-the-Web disabled (`SaveZoneInformation=1`) and Edge SmartScreen phishing filter off.
  **[IMPLEMENTED]** — privacy.yml
- Windows Update paused to 2038 + driver delivery blocked (security-patch exposure).
  **[IMPLEMENTED]** — update.yml; driver.yml
- SysMain always disabled + memory compression always disabled (regardless of RAM size — no
  hardware threshold logic). **[IMPLEMENTED]** — services.yml; settings.yml
- `wscsvc` (Security Center) and BitLocker service (`BDESVC`) on the disable list via the Defender
  option / unconditional list respectively. **[IMPLEMENTED]** — DisableDefenderServices.bat; services.yml

### 1.3 Useful ideas for NEXTRIX (shortlist)
1. **NIC keyword capability probing** (network.bat): read `Ndi\Params\<Keyword>` type/min/max/enum
   before writing any advanced property; skip missing keywords; clamp to driver range. Directly
   reusable pattern for a hardware-aware network module.
2. **Virtual-adapter exclusion lists** for NIC enumeration (network.bat; mirrored in SynToolkit's
   WMI filter) — a pragmatic way to avoid touching VPN/VM/debug adapters.
3. **UCPD-aware workaround precedent:** writing a *policy* (`AllowNewsAndInterests=0`) when a
   direct value (`TaskbarDa`) is UCPD-protected on 24H2+ — plus the maintainer's public issue reply
   documenting the failure mode.
4. **Option-gating security trade-offs** in the wizard UI with reversible/irreversible labels on
   each checkbox (playbook.conf), and per-toggle .bat pairs in a numbered post-install folder.
5. **Dynamic mitigation enumeration:** deriving the `Set-ProcessMitigation -Disable` value list
   from the cmdlet's own parameter validation so the script survives Windows-version drift
   (SOS Mitigations/off.bat).
6. **Ordering note in settings.yml worth copying as a comment pattern:** `Disable-MMAgent`
   requires SysMain running; temporarily start a service before disabling it later in the pipeline.
7. The **release-notes practice of labeling experimental build support** ("26H2 is experimental")
   and stating one-way doors explicitly ("reinstall windows to apply this version").

### 1.4 Reject / caution list
1. **No license.** Any code or pattern reuse beyond facts/ideas is legally blocked (all rights
   reserved). Registry key paths and value semantics are facts; do not copy scripts.
2. **NoDefender CBS-package Defender removal + permanent test certificate in the Root store** —
   reject outright for NEXTRIX; it is irreversible-by-design and weakens the trust chain.
3. **Machine-wide `MitigationOptions` all-2s nibble mask** — anti-cheat trigger (project's own
   README admits "most anti-cheats refuse to run"); UltraOS deliberately refuses the same mask.
4. **BCD timer forcing (`disabledynamictick yes`, deleting `useplatformclock`/`useplatformtick`)
   with no BCD backup** — hardware-dependent, folkloric gains, hard to undo safely.
5. **Blanket `HKLM\SYSTEM\…\Enum` power-value zeroing across every device** (power.bat) and the
   `UserWriteCacheSetting=1` SCSI sweep — ignores per-device capability; risky on laptops/modern
   standby. Prefer UltraOS's rename-to-`-OLD` backup variant if anything similar is ever done.
6. **Windows Update paused to 2038 + WU driver delivery blocked** — unacceptable for a
   security-conscious playbook; also the direct cause class of "removed apps return / drivers
   never update" complaints.
7. **`SaveZoneInformation=1` (MoTW off) and Edge phishing filter off** — security regressions in
   the default privacy path.
8. **Unconditional SysMain + memory-compression disable with no RAM/NVMe threshold** —
   UltraOS's own research notes this *increases* hard faults on 8–16 GB systems.
9. **Hardcoded per-build service suffix** (`BcastDVRUserService_389fd`) — a known fragility of
   per-user service naming across builds.
10. **`Set-ExecutionPolicy Unrestricted -Force`** — needless persistent weakening of PowerShell
    policy.
11. `svchost` split threshold forced to 4 GB-of-RAM value (`4294967295`) unconditionally —
    behavior changes with actual RAM size; no hardware awareness.

### 1.5 Research limitations (SynergyOS)
- Binary/asset content not inspected: `NoDefender.cab`, `SOS.pow`, `Synergy.nip`, `.skin` files,
  all bundled .exe (MinSudo, PowerRun, GoInterruptPolicy, Autoruns, DeviceCleanup), wallpapers.
  Their behavior is inferred only from names, file context, and scripts that invoke them.
- Files present in the tree but not read: `edge.bat`, `oned.bat`, `visuals.bat`, `updhealth.bat`,
  `cleanup.ps1`, `SOFTWARE.ps1`, `startmen.cmd`, `ngen.ps1`, `RunAsTI.reg`, Intel iGPU .reg
  contents, UAC/VBS/Bluetooth/Wi-Fi/Print/Xbox toggle .bat bodies, `.github/workflows/release.yml`.
- Whether/where `backup.ps1` is invoked during a real install could not be determined from the
  repository (not referenced in `custom.yml` or any read task file); AME Wizard engine internals
  were not inspected to confirm an engine-side convention.
- GitHub's issues REST endpoint returned HTTP 403 (rate limit) during this session; issue data came
  from public HTML pages. Bodies read only for #3 and #20; #4, #7, #8, #9, #11 remain title-only.
- No AME Wizard minimum version is stated by the project; the exact wizard build compatibility is
  unverified.

---

## Project 2 — SynToolkit (hardware-detection focus)

### 2.1 Identity table

| Field | Value | Evidence |
|---|---|---|
| Name | SynToolkit — "Post-installation control panel for SynergyOS"; WinUI 3 (C#) toolkit | IMPLEMENTED — [repo API](https://api.github.com/repos/Synergy-Tweaks/SynToolkit) |
| Repo | https://github.com/Synergy-Tweaks/SynToolkit (default branch `main`, C#, 11 stars / 8 forks) | IMPLEMENTED — repo API |
| License | **GPL-3.0** (`LICENSE`, standard GPL-3.0 text) plus `LICENSE-MIT.md` documenting MIT-licensed Ameliorated material retained in-repo; bundled third-party tools keep their own licenses (7-Zip License.txt, CrystalDiskMark/DiskSpd license files in `Assets/Tools`) | IMPLEMENTED — repo API (`license: gpl-3.0`); tree listing |
| Latest release | Tag `1.7`, "SynToolkit 1.7", published **2026-10-22**; asset `SynToolkit-Setup-1.7.0-Stable.exe` (141 MB, sha256 `705400c1…b09eb`, 2,598 downloads). Distributed through the SynergyOS playbook prompt as well as GitHub. | IMPLEMENTED — [releases/latest API](https://api.github.com/repos/Synergy-Tweaks/SynToolkit/releases/latest) |
| Supported Windows | README claims "Windows 10 (1809 / build 17763) or Windows 11, x64 recommended (x86 and ARM64 also targeted)" — **but the code gate is stricter**: `CompatibilityHelper.IsWindowsCompatible()` requires `Environment.Is64BitOperatingSystem && WindowsVersionService.IsSupported` where `MinimumSupportedBuild = 19041` (Win10 2004). **Doc/code mismatch on the 17763 floor.** | DOCUMENTED (README floor) + IMPLEMENTED (code floor) — [README.md](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/README.md); [WindowsVersionService.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Services/WindowsVersionService.cs); [CompatibilityHelper.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Utils/CompatibilityHelper.cs) |
| Build/deps | .NET 8 (`net8.0-windows10.0.26100.0`), Windows App SDK 1.7, VS2022 to build, Inno Setup 6 for the installer; NLog logging; bundled portable tools under `Assets/Tools`: **CPU-Z (cpuz_x64.exe), GPU-Z 2.70, HWiNFO64, CrystalDiskMark (+DiskSpd), WizTree, EmptyStandbyList**, 7-Zip; a WinRing0-style **`inpoutx64.dll`/`inpoutx64.sys`** driver pair under `Utils/ReadWrite` | DOCUMENTED (README build steps) + IMPLEMENTED (tree listing, csproj target stated in README) |
| Structure | `SynToolkit/` app: `Commands/`, `Controls/`, `Enums/`, `HostBuilder/`, `Models/`, `Services/` (≈170 service files), `Utils/`, `ViewModels/`, `Views/`, `lang/` (16 locales); `SynToolkit.SystemInformationTests/` custom test harness (20 test files + self-contained Program.cs); `Installer/Synergy/` (Inno Setup .iss + `ConfigurationServices` scripts shipped with the installer: Mitigations, SafeMode, VBS, toggleDefender, viewBootValues, NVidia display-container state, SecurityHealthTray add/remove, Troubleshooting incl. Repair Windows Components/Installer, Network WindowsDefaults) | IMPLEMENTED — tree API (parsed full listing) |
| Relationship to SynergyOS | Installed by the SynergyOS playbook (default-checked option); detects a SynergyOS install via OEM registry markers (Model = "SOS 10"/"SOS 11"/"SYNERGYOS", Manufacturer = "Kwanteks", SupportURL = dsc.gg/kwanteks or legacy discord.gg/kwanteks) | IMPLEMENTED — CompatibilityHelper.cs |

URLs actually inspected for SynToolkit: repo API, tree API (full parse), releases/latest API,
`README.md`, `SynToolkit/Services/SystemSpecsService.cs`, `SynToolkit/Services/SystemInformationService.cs`,
`SynToolkit/Services/GpuDetectionService.cs`, `SynToolkit/Services/GpuVendorClassification.cs`,
`SynToolkit/Services/FsoDetection.cs`, `SynToolkit/Services/HagsDetection.cs`,
`SynToolkit/Services/WindowsVersionService.cs`, `SynToolkit/Utils/CompatibilityHelper.cs`,
`SynToolkit/Services/RestorePointService.cs`, `SynToolkit/Services/Bcd/BcdContract.cs`,
`SynToolkit/Services/Bcd/WmiBcdProvider.cs`, `SynToolkit/Services/BcdService.cs`, issues list page.

### 2.2 Findings by area

#### Hardware inventory — Windows interfaces queried (NEXTRIX core interest; all **[IMPLEMENTED]** from
[SystemSpecsService.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Services/SystemSpecsService.cs) unless noted)
- **WMI classes queried:** `Win32_Processor` (Name, NumberOfCores, NumberOfLogicalProcessors,
  MaxClockSpeed), `Win32_VideoController` (Name, AdapterRAM, DriverVersion, PNPDeviceID,
  ConfigManagerErrorCode), `Win32_ComputerSystem` (TotalPhysicalMemory), `Win32_PhysicalMemory`
  (Manufacturer, Capacity, Speed, ConfiguredClockSpeed, SMBIOSMemoryType, FormFactor),
  `Win32_DiskDrive` (Model, Size, MediaType, InterfaceType, FirmwareRevision, PNPDeviceID),
  `Win32_NetworkAdapter` (Name, Manufacturer, MACAddress, NetConnectionID, NetConnectionStatus,
  PhysicalAdapter, PNPDeviceID, ConfigManagerErrorCode, Speed), `Win32_BaseBoard`
  (Manufacturer, Product, Version, SerialNumber, Tag), `Win32_BIOS` (SMBIOSBIOSVersion, Version,
  ReleaseDate, SMBIOSMajor/MinorVersion), `Win32_PhysicalMemoryArray` (MemoryDevices),
  `Win32_SystemSlot` (SlotDesignation, SlotType, CurrentUsage, MaxDataWidth),
  `Win32_SystemEnclosure` (ChassisTypes).
- **Registry reads:** GPU class key `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-…}`
  per-adapter subkeys (`MatchingDeviceId`, `HardwareInformation.qwMemorySize`); firmware mode via
  `HKLM\SYSTEM\CurrentControlSet\Control` `PEFirmwareType` (1=Legacy BIOS, 2=UEFI).
- **GPU VRAM accuracy handling:** WMI's `AdapterRAM` is a 32-bit field that wraps >4 GB — "a
  well-documented WMI limitation, not a hypothetical edge case." The service therefore prefers the
  registry's 64-bit `HardwareInformation.qwMemorySize`, matching subkeys by `MatchingDeviceId`
  contained in the PNPDeviceID, and wraps **each subkey open in try/catch** because "a reserved
  'Properties' key … can throw a permission exception on OpenSubKey. That must not abort the whole
  scan — otherwise … every GPU falls back to WMI's AdapterRAM, which is known to be wrong for
  cards with more than ~4 GB."
- **Memory:** SMBIOSMemoryType → DDR1/2/3/4/5, LPDDR5/5X map with explicit `_ => null` plus a
  comment that "CPU-Z provides a fallback for future values, including DDR6";
  `MemoryModuleInventoryNormalizer.Normalize(modules, totalMemoryBytes)` reconciles module data
  against total RAM.
- **Junk-SMBIOS sanitization:** `CleanText` filters "To Be Filled By O.E.M.", "Unknown", "None",
  "N/A", "Not Specified", "Default string", "System Serial Number" → detail simply not shown
  rather than displaying garbage.
- **Topology:** `Win32_SystemSlot` decodes PCIe slot types 165–170 (unspecified-gen widths) and
  171–200 (gen 2..N, width x1/x2/x4/x8/x16), M.2 detection by designation string
  ("M.2"/"M2"/"NVME"), usage mapping CurrentUsage 3=Available/4=In use/5=Unavailable; NVMe drive
  inventory via PNPDeviceID/InterfaceType; chassis-type map (Desktop/Tower/Laptop/Tablet/…).
- **Network adapter filter:** physical adapters only (`PhysicalAdapter=true`), excludes
  ConfigManagerErrorCode 22 (disabled devices) and name/manufacturer/PNPDeviceID terms
  (Bluetooth, Microsoft, WAN Miniport, Kernel Debug, Virtual, Hyper-V, Teredo, 6to4, ISATAP,
  Loopback, NdisWan, TAP-Windows, WireGuard, Wintun); adapter speed >= long.MaxValue treated as
  invalid; connection-status enum fully mapped (0–12).
- **CPU-Z augmentation (progressive disclosure):** `CpuZProcessorDetailsParser`,
  `CpuZMainboardDetailsParser`, `CpuZMemoryReportService`/`CpuZMemoryTimingParser` — the fuller
  motherboard/socket/memory-timing inventory loads only when the user opens the Motherboard
  expander, because "CPU-Z can take several seconds to generate its report, so it must not delay
  the rest of the Specs tab." Empty NVMe sockets shown only when firmware reports them ("Windows
  does not expose a dependable inventory for every unpopulated NVMe socket").
- **Design constraint stated in code:** the Specs layer "Reads read-only hardware/OS identity via
  WMI … **Never modifies the system.**"

#### GPU vendor detection **[IMPLEMENTED]** — [GpuVendorClassification.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Services/GpuVendorClassification.cs); [GpuDetectionService.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Services/GpuDetectionService.cs)
- PCI vendor ID first: `VEN_1002` = AMD/ATI, `VEN_10DE` = NVIDIA, `VEN_8086` = Intel; name-string
  fallback (Radeon/GeForce/Intel); "Microsoft Basic Display"/"Microsoft Remote Display" adapters →
  Unknown (not treated as a real vendor GPU); multi-GPU priority NVIDIA → AMD → Intel → Unknown.
- WMI enumeration is cached for the process lifetime ("GPU hardware does not change during a
  running session"), with the explicit purpose "so features can be disabled when the relevant
  vendor's hardware isn't present (e.g. the Radeon slimmer on an NVIDIA-only system)" — i.e.,
  **features are gated on detected hardware.**

#### Feature-state detection with uncertainty modeling (all **[IMPLEMENTED]**)
- **HAGS** ([HagsDetection.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Services/HagsDetection.cs)):
  reads `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\HwSchMode` — 2=On, 1=Off,
  **missing = "Default (system decides)" — explicitly "not the same as Off, and not evidence that
  the GPU lacks support."** Build floor 19041 → `NotSupportedByWindowsVersion` below it;
  `UnsupportedHardware` only when a driver-capability query says so; wrong registry type/value →
  `UnsupportedValue` ("Current value is not one this tweak would write") instead of silent
  misclassification; `RestartRequired` computed when requested state ≠ live driver state.
- **FSO** ([FsoDetection.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Services/FsoDetection.cs)):
  pure, registry-free classification function over six HKCU `System\GameConfigStore` DWORDs
  (`GameDVR_EFSEFeatureFlags`, `GameDVR_FSEBehaviorMode`, `GameDVR_FSEBehavior`,
  `GameDVR_DSEBehavior`, `GameDVR_DXGIHonorFSEWindowsCompatible`, `GameDVR_HonorUserFSEBehaviorMode`)
  plus `HKLM\…\Session Manager\Environment\__COMPAT_LAYER`; states Enabled / Disabled /
  **Modified (names the mismatched values)** / Error; missing value treated as enabled-position;
  non-DWORD kind = mismatch; read failure → Error. Scope is deliberately fenced: "Does NOT touch
  GameDVR_Enabled, AppCaptureEnabled, UseNexusForGameBarEnabled, AllowGameDVR, or any other Xbox
  Game Bar / HAGS / MPO values."
- **Windows version** ([WindowsVersionService.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Services/WindowsVersionService.cs)):
  build-number classification (`CurrentBuildNumber`, `UBR`, `DisplayVersion` with `ReleaseId`
  fallback) — "Prefer this over ProductName (which can still say 'Windows 10' on some Windows 11
  builds)"; `WindowsVersionInfo.Failed` sentinel carries `ReadSucceeded=false` and
  `IsSupported` is false on read failure; logging wrapped so "Logging must never crash version
  detection."
- **Custom-OS / playbook identity** ([SystemInformationService.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Services/SystemInformationService.cs)):
  detects custom Windows builds via OEMInformation Model / RegisteredOwner regexes; playbook
  identity via explicit keys (`HKLM\SOFTWARE\SynergyOS\Playbook`, `SOFTWARE\AME\Playbook`,
  `SOFTWARE\Ameliorated\Playbook`, …) then fallback OEM markers, with the comment "Playbook
  detection is deliberately conservative because AME does not require every playbook to persist a
  standard identity marker"; legacy `ProgramData` playbook.conf history kept at lower priority than
  current markers; registry access uses the correct `RegistryView` (Registry64/Registry32).
- **Test coverage for all of the above:** `SynToolkit.SystemInformationTests/` contains
  `FsoDetectionTests.cs`, `HagsDetectionTests.cs`, `WindowsVersionServiceTests.cs`,
  `SystemResponsivenessTests.cs`, `Win32PrioritySeparationTests.cs`, `MultiPlaneOverlayTests.cs`,
  `DisplayModeTests.cs`, `FsoGameBarOwnershipTests.cs`, `TaskbarAlignmentTests.cs`,
  `ContextMenuServiceTests.cs`, `FavoriteIdMigrationTests.cs`, `SteamTrayWebHelperTests.cs`,
  `WindowedGamesOptimizationTests.cs`, `SynToolkitUpdateTests.cs`, `SynergyOsUpdateTests.cs`, plus a
  self-contained `Program.cs` harness — the detection logic is factored specifically to be testable
  "without touching the registry." **[IMPLEMENTED]** — tree listing; FsoDetection.cs doc comments

#### BCD handling — safety-relevant **[IMPLEMENTED]** — [Bcd/WmiBcdProvider.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Services/Bcd/WmiBcdProvider.cs); [Bcd/BcdContract.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Services/Bcd/BcdContract.cs); [BcdService.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Services/BcdService.cs)
- BCD is accessed through **Microsoft's built-in `root\WMI` BCD provider**
  (`BcdStore.OpenStore`/`OpenObject`, `GetElement`, `SetBooleanElement`, `SetIntegerElement`,
  `DeleteElement`) — "deliberately does not invoke or parse BCDEdit, whose display output can be
  localized."
- Numeric element IDs used (boot-configuration UI scope): `0x16000040` AdvancedOptions,
  `0x16000041` OptionsEdit, `0x16000054` HighestMode, `0x16000067/68/69` boot-UX
  logo/text/progress, **`0x25000080` SafeBoot**, `0x26000081` SafeBootAlternateShell,
  `0x250000C2` BootMenuPolicy, `0x250000E0` BootStatusPolicy; well-known objects Default
  `{1CAE1EB7-…}`, GlobalSettings `{7EA2E1AC-…}`, Current `{FA926493-…}`.
- **Read-after-write verification:** every `Set*` re-reads the element and throws
  ("did not retain the requested value"); `DeleteElement` is idempotent (absent → log + return) and
  verifies deletion. Value-kind validation (`Integer 0x5` / `Boolean 0x6` from the element-type
  high nibble) before every call.
- Notably, SynToolkit's boot UI manages **safe boot / boot menu / boot status** — it does **not**
  ship timer/clock BCD changes; those live only in the SynergyOS playbook's raw `bcdedit` calls.

#### System Restore (rollback layer) **[IMPLEMENTED]** — [RestorePointService.cs](https://raw.githubusercontent.com/Synergy-Tweaks/SynToolkit/main/SynToolkit/Services/RestorePointService.cs)
- Uses `srclient.dll` `SRSetRestorePointW` via P/Invoke (BeginSystemChange=100 →
  EndSystemChange=101) with `RestorePointType = MODIFY_SETTINGS (12)` — "the user is saving the
  current configuration, not installing software."
- **Honest outcome model:** verifies creation by diffing restore-point sequence numbers
  before/after; when Windows accepted the request but the list is unreadable, returns
  **`Unverified`** instead of `Failed` ("Reporting Failed would invite a retry that duplicates the
  point or hits the 24h throttle"); detects the Windows restore-point throttle via
  `SystemRestorePointCreationFrequency` (default 1440 min) → `Throttled`; maps ERROR_ACCESS_DENIED
  (5), ERROR_SERVICE_DISABLED (1058), ERROR_SERVICE_NOT_ACTIVE (1062); 45-second timeout;
  "Always close the change. Cancelling between begin and end would leave System Restore
  mid-operation."
- `DisableSR` read to report `ProtectionDisabled`; elevation checked via WindowsPrincipal.

#### Change-application services (name-level survey; bodies not read) **[IMPLEMENTED — existence/size from tree; behavior claims are DOCUMENTED from README/release notes where noted**
- A large `ConfigurationServices/` layer (≈130 files) implements individual toggles — including
  hardware-adjacent ones: `CpuIdleConfigurationService`, `DmaRemappingConfigurationService`,
  `DynamicTickConfigurationService`, `HagsConfigurationService`,
  `MultiPlaneOverlayConfigurationService`, `MmcssOptimizationConfigurationService`,
  `NetworkLatencyConfigurationService`, `XhciImodConfigurationService` (+`XhciDeviceHelper.cs`,
  20 KB), `VbsStateConfigurationService`, `UacConfigurationService`,
  `MitigationsConfigurationService`, `DefenderRealtimeProtectionConfigurationService`,
  `WindowsFirewallConfigurationService`, `SafeModeConfigurationService`,
  `ForegroundAppBoostConfigurationService`, `FullScreenOptimizationsConfigurationService` (23 KB),
  `PowerPlanShellConfigurationService`, plus GPU vendor work: `AmdGpuRegistryHelper`,
  `AmdGpuTweaksPacks`, `NvidiaPerformanceTweaksService` (49.8 KB) with
  **`NvidiaTweaksBackupStore`** (6.5 KB — a backup store specifically for NVIDIA profile-tweak
  rollback), `GpuDriverRemovalService` (20.9 KB).
- README features list (DOCUMENTED): Specs page with live CPU utilization/frequency; Needs
  Attention checks for "drivers, disk space, restore points, clock sync, and updates"; power-plan
  import/activate/edit/restore; GPU driver downloads; startup scanner; context-menu editor;
  audio mixer; games library. Release notes add that "Outdated SynergyOS install detection and
  the cover art fix are still being tested."
- Bundled diagnostic tools (IMPLEMENTED — tree): CPU-Z, GPU-Z, HWiNFO64, CrystalDiskMark
  (DiskSpd), WizTree, EmptyStandbyList — the toolkit's "benchmarks" are these industry tools, not
  custom claims; no performance numbers are published by the project.

#### Known compatibility issues **[COMMUNITY-CLAIM — titles only]**
- Three closed issues: #2 "Memory Trimmer" (feature request, closed Aug 24, 2026); #4 "SynToolkit"
  (bug, closed Aug 20, 2026); #3 "Safe Mode scripts not being able to accessed" (bug, closed Aug
  19, 2026). Bodies not read; the issues list page showed no open issues at access time (repo API
  reports 6 open — likely including PRs).

#### Safety-relevant behavior
- The app itself performs read-only detection (Specs/version layers state this in code comments).
  Its write surface is the toggle layer above; notably it ships **Defender toggle**
  (`DefenderRealtimeProtectionConfigurationService`, `toggleDefender.cmd`,
  `SecurityHealthTray` add/remove .reg) and **VBS on/off** and **Mitigations on/off**
  (ConfigurationServices + Installer scripts) as reversible toggles rather than one-way removals.
  **[IMPLEMENTED — existence] / DOCUMENTED — intent from README "reversible" wording**
- **`inpoutx64.dll` + `inpoutx64.sys`** under `Utils/ReadWrite` (with a 419-byte `InpOut.cs`
  wrapper) — a WinRing0/InpOut-class kernel driver for direct port/MSR-style hardware access.
  Its `ReadWriteHelper.cs` (2.4 KB) exists, but no caller was inspected in this pass. For NEXTRIX:
  treat any kernel-mode hardware access helper as a hard caution item. **[IMPLEMENTED — presence in
  tree; usage unverified]**

### 2.3 Useful ideas for NEXTRIX (shortlist)
1. **The uncertainty-state pattern** (HagsDetection): model every detection as {value, readFailed,
   wrongType, missing} and surface distinct states — On/Off/**Default**/UnsupportedHardware/
   UnsupportedValue/Error/**RestartRequired** — never collapse "missing" into "off". This is the
   single most transferable idea in the whole R4 assignment.
2. **WMI AdapterRAM wraparound fix:** prefer `HardwareInformation.qwMemorySize` from the GPU class
   key over `Win32_VideoController.AdapterRAM` (>4 GB VRAM), with per-subkey try/catch so one
   permission-denied subkey can't degrade every GPU's reading.
3. **Pure, testable detection functions** (FsoDetection): detection takes (value, kind, readSucceeded)
   tuples and is unit-tested without touching the registry; a separate thin adapter does the
   actual registry I/O.
4. **Junk-SMBIOS sanitization list** ("To Be Filled By O.E.M." etc.) and DDR-generation mapping with
   explicit null → CPU-Z fallback for unknown future types.
5. **Progressive disclosure for slow probes:** show the WMI snapshot immediately; layer CPU-Z
   report parsing on demand when the user expands a section.
6. **Feature gating on detected hardware:** GPU-vendor detection exists "so features can be
   disabled when the relevant vendor's hardware isn't present" — the pattern NEXTRIX needs for
   AMD/NVIDIA/Intel-specific modules.
7. **BCD via the WMI provider with read-after-write verification** and typed element contracts —
   strictly safer than parsing `bcdedit` output; also the idempotent delete.
8. **Restore-point honesty model:** sequence-diff verification, `Unverified` vs `Failed`
   distinction, 24h-throttle awareness, always-close-begin/end — a complete reference
   implementation for NEXTRIX's restore-point layer.
9. **Custom-OS/playbook identity markers** (OEMInformation triple + regexes) as a machine-readable
   "what modified this system" detection scheme, with conservative fallbacks.
10. **Test-first layout** for all detection logic (SystemInformationTests project) — the repo
    demonstrates that every tweak-state detector can be a pure function.

### 2.4 Reject / caution list
1. **`inpoutx64.dll/.sys` kernel driver** — direct hardware access from user mode; scan/supply-chain
   and stability risk; do not adopt without a specific, documented need and a signed-driver story.
2. **Bundled unsigned-ish third-party executables** (GPU-Z, CPU-Z, CrystalDiskMark etc. shipped as
   repo blobs) — supply-chain surface; NEXTRIX should download/hash-verify at run time instead.
3. **README/code mismatch on the Windows floor** (17763 claimed vs 19041 enforced) — a
   documentation-integrity lesson; NEXTRIX should generate support matrices from code.
4. **Safe-boot BCD toggles** (element `0x25000080`) are powerful; any equivalent in NEXTRIX must be
   opt-in, verified read-after-write, and ideally paired with an automatic revert on next boot.
5. **GPL-3.0 is contagious**: any SynToolkit-derived *code* in NEXTRIX would force GPL-3.0 on that
   component. Ideas/patterns are not copyrightable — reimplement, don't copy.
6. **Playbook identity via OEM keys is spoofable** (plain registry strings); fine for UX, not for
   security decisions.
7. SynToolkit inherits SynergyOS's aggressive tweak set as its "Tweaks" tab inventory (README); the
   toolkit's quality is in *detection and toggling*, not in the tweak selection itself — evaluate
   each underlying tweak on its own merits before adopting.

### 2.5 Research limitations (SynToolkit)
- The repo is large (~63 MB tree); only the files listed in "URLs inspected" were read. Major
  services **not read** (behavior therefore unknown beyond names/sizes/README): `PowerPlanService.cs`
  (72.9 KB), `PowerPlanSettingsReader.cs` (28.3 KB), `NeedsAttentionService.cs` (39.9 KB),
  `DisplayChainPolicy.cs` (45.6 KB), `DisplayApplyService.cs` (29 KB), `GpuDriverService.cs` /
  `.Amd` / `.AmdCatalog` (47–48 KB each), `NvidiaPerformanceTweaksService.cs` (49.8 KB),
  `NvidiaTweaksBackupStore.cs`, `GpuDriverRemovalService.cs`, `XhciDeviceHelper.cs`,
  `StartupScannerService.cs`, `WingetInstallerService.cs`, `AppFetchService.*`,
  `AmePlaybookDetector.cs` (24.2 KB), `MainWindow.xaml.cs` (55.4 KB), the CPU-Z parser services
  (2.3–9 KB each), all ConfigurationServices bodies, all test bodies, `Installer/Synergy/**`
  scripts, `.github/workflows/build.yml`.
- Consequently the exact Windows interfaces used by Needs Attention checks, power-plan import,
  and GPU driver flows are not verified here (README descriptions are tagged DOCUMENTED).
- The `inpoutx64` driver's actual callers were not identified.
- Issue REST endpoint returned 403 (rate limit); issue information comes from the HTML page; only
  titles were captured.
- The 141 MB release installer was not downloaded or analyzed (binary analysis out of scope).

---

## Project 3 — UltraOS Playbook

### 3.1 Identity table

| Field | Value | Evidence |
|---|---|---|
| Name | UltraOS — "A transparent, reversible Windows 11 optimization playbook for AME Wizard — built Windows 11 26H2-first, licensed GPL-3.0." Repo name `playbook`. | IMPLEMENTED — [repo API](https://api.github.com/repos/UltraOS-Project/playbook); [README.md](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/README.md) |
| Repo | https://github.com/UltraOS-Project/playbook (default branch `main`, Python primary language, 8 stars / 1 fork) | IMPLEMENTED — repo API |
| License | **GPL-3.0** (`LICENSE`) + `NOTICE` with full attribution: derived in part from the **Atlas playbook (GPL-3.0)**; ReviOS values re-implemented (CC BY-SA 4.0, ideas + specific registry values credited); winutil (MIT), Win11Debloat (MIT), Chamber-Playbook (CC BY-NC-SA, ideas), Remove-MS-Edge (CC0, reference), O&O ShutUp10++ (inspiration); AME Wizard engine components run unmodified: **TrustedUninstaller (MIT)** and **ame-assassin (MIT)** | IMPLEMENTED — repo API; [NOTICE](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/NOTICE) |
| Latest release | Tag **v1.2.1**, "UltraOS v1.2.1", published **2026-10-28** (github-actions bot release); assets: `UltraOS-Playbook-v1.2.1.apbx` (166 KB, 913 downloads), `SHA256SUMS.txt`, `README-FIRST.txt`, `Test-WithRealWizard.cmd`, `LICENSE`. | IMPLEMENTED — [releases/latest API](https://api.github.com/repos/UltraOS-Project/playbook/releases/latest) |
| Supported Windows | **Only Windows 11 24H2 (26100), 25H2 (26200), 26H2 (26300)** — `SupportedBuilds` hard-list; `AllowUnsupportedUpgrades=false`; README: "The wizard hard-checks the build number and refuses anything else"; Home **and** Pro explicitly supported ("every tweak is implemented via registry and policy keys that work identically on Home, with no reliance on Group Policy Editor-only mechanisms"). Windows 10 and Insider builds are rejected; 26H1 (28000, ARM-only interim) explicitly unsupported. | IMPLEMENTED — [playbook.conf](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/src/playbook/playbook.conf); DOCUMENTED (refusal behavior) — [docs/TROUBLESHOOTING.md](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/docs/TROUBLESHOOTING.md) |
| Engine / dependencies | AME Wizard from ameliorated.io ("the same wizard AtlasOS and ReviOS use"; INSTALL.md notes "the site now lives under amelabs.net"). **No pinned wizard version.** Engine components under the hood (per NOTICE): TrustedUninstaller + ame-assassin (MIT). Playbook itself: plain-text YAML + PowerShell 5.1 built-ins; **zero bundled executables** (`UseKernelDriver: false`; ANTIVIRUS.md claims "no encoded commands … no binaries"). Requirements: `Internet`, `NoPendingUpdates`, `PluggedIn` — **notably no `DefenderToggled` / `NoAntivirus` requirement** (contrast SynergyOS). `Overhaul: true`; `EstimatedMinutes: 8`; `SupportsISO: true` with `DisableBitLocker`/`DisableHardwareRequirements`. | IMPLEMENTED — playbook.conf; NOTICE; DOCUMENTED — README/INSTALL |
| Structure | `src/playbook/Configuration/main.yml` (pipeline) + `ultraos/{start,services,revert}.yml` + `tweaks/{debloat,network,performance,privacy,qol,security,services,tasks,ultraos,visual}/*.yml` (≈30 modules, each action provenance-commented); `src/playbook/Executables/{APPLYHIVE,BACKUP,CLEANUP,EDGE-UNLOCK,REPORT,RESTOREPOINT,UNDO}.ps1`, `Undo.cmd`, `default-user.reg`, `UltraOSFolder/` post-install toggles (1. Security / 2. Updates / 3. Features / 4. Tools / 5. Software + Scripts); `scripts/{build-playbook.sh, make-artifacts.py, gen-defaultuser-reg.py, gen-skeletons.py, validate-playbook.py, ame-dryrun.py}`; `docs/{ANTIVIRUS,COMPARISON,FAQ,INSTALL,MODULES,TROUBLESHOOTING}.md`; `research/` (13 evidence dossiers incl. `ame-wizard-format-spec.md`, `windows-26h2-analysis.md`, `known-issues-compatibility.md`); `CHANGELOG.md`, `SECURITY.md`, `CONTRIBUTING.md` | IMPLEMENTED — tree API + files read |

URLs actually inspected for UltraOS: repo API, tree API, releases/latest API, `README.md`,
`NOTICE`, `CHANGELOG.md`, `src/playbook/playbook.conf`, `src/playbook/Configuration/main.yml`,
`src/playbook/Configuration/ultraos/revert.yml`, `src/playbook/Configuration/ultraos/services.yml`,
`tweaks/network/nic-config.yml`, `tweaks/performance/power.yml`, `tweaks/security/mitigations.yml`,
`tweaks/tasks/telemetry-tasks.yml`, `src/playbook/Executables/BACKUP.ps1`, `UNDO.ps1`,
`RESTOREPOINT.ps1`, `Undo.cmd`, `docs/INSTALL.md`, `docs/TROUBLESHOOTING.md`.

### 3.2 Findings by area

#### Preset and option model **[IMPLEMENTED]**
- Three depth-tier presets, radio page, default **Balanced**: Safe (disable-only) / Balanced /
  Extreme. Gating is mechanical in YAML: Safe actions ungated; Balanced actions tagged
  `option: '!preset-safe'` (run unless Safe); Extreme adds `preset-extreme` files.
- Eleven opt-in extras, **all unchecked by default, never preset-gated**: `opt-uninstall-edge`
  (WebView2 runtime kept — "15+ apps depend on it"), `opt-disable-mitigations`,
  `opt-disable-vbs`, `opt-max-performance`, `opt-disable-hibernation`, `opt-strip-recall`,
  `opt-disable-sticky-keys`, `opt-disable-sysmain`, `opt-disable-search-indexing`,
  `opt-disable-memory-compression`, `opt-disable-hags`. Each carries its trade-off in the wizard
  text and docs. — playbook.conf; README
- Windows Update radio (default `wu-auto`, alternative `wu-notify`): "UltraOS never fully disables
  updates"; `NoAutoUpdate` deliberately never set (breaks "Receive updates for other Microsoft
  products"). — playbook.conf; revert.yml comment
- Restore-point radio default **on** (`rp-on`), skippable. — playbook.conf

#### Execution pipeline **[IMPLEMENTED]** — [main.yml](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/src/playbook/Configuration/main.yml)
- Order: best-effort `reg unload` + `reg load` default-user hive → `ultraos/start.yml` (upgrade
  cleanup; pinned to run *before* copy-folders after a v1.1.1 bug) → `copy-folders.yml` →
  `RESTOREPOINT.ps1` (rp-on) → `BACKUP.ps1` → services → debloat → privacy (10 files) → scheduled
  tasks → network → performance → visual/qol → security (opt-in) → `APPLYHIVE.ps1` (mirror HKCU
  tweaks to default hive) → `finish.yml` → `reg unload`. Inline comments record two historical
  ordering bugs and their fixes (see Known issues).

#### Registry modifications (representative; all **[IMPLEMENTED]** with per-action provenance comments in the cited files)
- Fast Startup off (`HiberbootEnabled=0`) on every preset. — power.yml
- Telemetry: `AllowTelemetry=0` on three paths (incl. Wow6432Node + CPSS/PolicyManager "shadow
  copies" per CHANGELOG v1.2.0); SQM/setup autologgers off; consent-deny set
  (`DisableTelemetryOptInSettingsUx`, etc.). — CHANGELOG; revert.yml undo = **delete** ("absence of
  the value IS the Windows default")
- Windows Update: notify-only mode writes `AUOptions=2` only (never `NoAutoUpdate`); undo = delete. — revert.yml
- Delivery Optimization `DODownloadMode=0`; feedback `NumberOfSIUFInPeriod=0`; DO/CEIP/WER service
  handling in privacy modules (files not read — mapped in services.yml header).
- Classic context-menu CLSID key with empty `InprocServer32` (undo = delete whole key). — revert.yml
- Input: mouse-acceleration trio (`MouseSpeed`, `MouseThreshold1/2`), `MenuShowDelay 0` at
  Balanced (stock 400), Sticky Keys `Flags` shortcut-disable via PowerShell "on purpose so the
  preference does not leak into future user profiles via default-user.reg". — CHANGELOG; revert.yml
- MMCSS: `SystemResponsiveness=10` (stock 20, revert entry added in v1.1.0 after a gap was
  found); Extreme adds Games task profile (Priority 6 / Games / High — "honestly labeled as
  anecdotal-but-harmless", stock values recorded). — revert.yml; CHANGELOG
- HAGS: only *disabled* via `opt-disable-hags`; stock HwSchMode=2 recorded for undo. — revert.yml
- `PowerThrottlingOff=1`, `StorageD3InModernStandby=0`, `stornvme IdlePowerMode=0` ("harmless
  no-op on SATA-only systems") under opt-max-performance. — power.yml

#### Service configurations **[IMPLEMENTED]** — [ultraos/services.yml](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/src/playbook/Configuration/ultraos/services.yml)
- Balanced tier disables 12 services (OneSyncSvc, TrkWks, PcaSvc, MapsBroker, lfsvc, RetailDemo,
  Fax, WMPNetworkSvc, diagnosticshub.standardcollector.service, wercplsupport, RemoteRegistry as a
  *security* hardening, + template note), each annotated against **Microsoft's own IoT service
  guidance** (learn.microsoft.com cited inline) with per-service trade-offs.
- **Validator-enforced NEVER-TOUCH list** — `scripts/validate-playbook.py` "HARD-ERRORS on any of
  these being disabled (startup 4) or deleted": wuauserv, TrustedInstaller, UsoSvc, DoSvc,
  **Spooler**, Audiosrv, Winmgmt, Schedule, profsvc, UserMgr, StateRepository, InstallService,
  AppXSvc, ClipSVC, **SecurityHealthService, MDCoreSvc**, WlanSvc, netman, netprofm, NlaSvc,
  CDPSvc, CDPUserSvc; policy additions (not machine-checked): WaaSMedicSvc, BITS, cryptsvc,
  msiserver, wuapi, **WdNisSvc**, PrintNotify, AudioEndpointBuilder, EFS, hidserv, DsmSvc,
  DevQueryBroker, LicenseManager, Xbox stack. Rationale quoted: update failures 0x8024xxxx, Store
  0x80D02002, dead audio, broken profiles.
- Extreme-only (`tweaks/services/extreme-services.yml`, not read): SysMain (offered as toggle at
  other tiers), WSearch, NDU, NetBT, GpuEnergyDrv, Telemetry drivers — the header notes T1-g maps
  them to all presets but "the build manifest gates them to Extreme so Balanced keeps legacy
  name-resolution / file-sharing flows intact."
- **UCPD stance:** "UltraOS never writes UserChoice / file-association keys, so the UCPD driver
  service is left alone entirely … Only its velocity scheduled task is handled by the tasks module."
  Default browser is set through the wizard's own `DefaultWebBrowser` flow "the legitimate route
  that UCPD permits." — services.yml; docs/TROUBLESHOOTING.md

#### Scheduled task changes **[IMPLEMENTED]** — [telemetry-tasks.yml](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/src/playbook/Configuration/tweaks/tasks/telemetry-tasks.yml)
- Safe tier disables 9 pure telemetry tasks (Consolidator, UsbCeip, KernelCeipTask, Microsoft
  Compatibility Appraiser, ProgramDataUpdater, QueueReporting, DiskDiagnosticDataCollector,
  Autochk\Proxy, Chkdsk\Proxy) — **every one with `ignoreErrors: true`** because "several Win10-era
  tasks no longer exist on Win11"; KernelCeipTask flagged "⚠️ UNVERIFIED existence on 26H2
  (classic community source only)". Maintenance-task disables (incl. UCPD velocity task) live in
  `maintenance-tasks.yml` (not read).

#### Power settings **[IMPLEMENTED]** — [power.yml](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/src/playbook/Configuration/tweaks/performance/power.yml)
- `opt-max-performance`: duplicates the hidden **Ultimate Performance** scheme
  (`e9a42b02-d5df-448d-aa00-03f14749eb61`) under a fixed UltraOS GUID with an **existence guard**
  (idempotent re-runs), activates + renames it, then applies: NVMe primary/secondary idle timeout
  0, NVMe NOPPME off, USB selective suspend off / hub timeout 0 / USB3 link power management off,
  throttle states off, display never off, CPU performance time-check interval 200 ms ("fewer
  DPCs"), **EPP=0 (AC)**; NIC power keywords off via `Get-NetAdapterAdvancedProperty` (EEE,
  GreenEthernet, ULPMode, uAPSD…); device-level D3/selective-suspend/wake values zeroed across
  `HKLM\SYSTEM\…\Enum` — **with originals renamed to `<value>-OLD` for rollback** (contrast
  SynergyOS's blind zeroing); `MSPower_DeviceEnable` off via WMI.
- Documented costs inline: "higher idle power draw and heat, USB devices never sleep (mouse LEDs
  stay on), possible NIC quirks on some Killer/Realtek chips - not recommended for laptops. On
  Modern Standby (S0ix) machines classic plan settings may be partially ignored." Atlas's
  additional ACPI-device disabling "deliberately NOT included in v1 (too invasive)."
- `opt-disable-hibernation`: `powercfg /h off` (reversible with `powercfg /h on`, printed in docs).

#### CPU/GPU/hardware-specific logic **[IMPLEMENTED]**
- NIC tuning (`nic-config.yml`, Balanced+): enumerate **PCI NICs via
  `Win32_NetworkAdapter` `PNPDeviceID -like 'PCI\VEN_*'`**, resolve each adapter's class key
  through `Enum\<PNPDeviceID>\Driver`, set 5 keywords (`AutoDisableGigabit`, `ApCompatMode`,
  `SipsEnabled`, `ReduceSpeedOnPowerDown`, `DMACoalescing`) to '0' **only if the value already
  exists** — "forcing keywords a driver does not expose can make some Killer/Realtek NICs
  misbehave." Explicitly lists keywords **not** touched (LSO, FlowControl "could cause dropped
  network frames", offloads, PriorityVLANTag…) as "Atlas 'unknown benefit' list". Notes an Atlas
  cmd bug it fixes (Atlas looped only the last enumerated adapter). Non-PCI (USB) NICs out of
  scope; reboot required; idempotent. Intel DMACoalescing latency article cited.
- Mitigations extra (`opt-disable-mitigations`) ships **only four registry-backed items**
  (FeatureSettingsOverride=3/Mask=3, DisableExceptionChainValidation=1, `Set-ProcessMitigation
  -System -Disable CFG`, ProtectionMode=0) and **deliberately refuses** Atlas's blanket
  MitigationOptions nibble mask ("the EAC-adjacent trigger") and `bcdedit /set nx OptIn`;
  honesty note: "on CPUs >= 8th-gen Intel / Ryzen 3000+ disabling mitigations yields near-zero
  real-world gain." — mitigations.yml
- No timer-forcing: README's no-placebos section — "Since Windows 10 2004, timer resolution is
  per-window and background processes don't benefit; the '1 ms gaming timer' ritual is mostly
  folklore. Extreme does apply the documented `GlobalTimerResolutionRequests` pattern with honest
  limitations — and no bundled unsigned binaries to force it." (The Extreme timer action itself
  is in `tweaks/performance/extreme.yml`, not read.) — README (DOCUMENTED for the extreme file's
  content; IMPLEMENTED for the stated policy in README text read).
- Hardware-gated extras with stated thresholds: `opt-disable-sysmain` "only for fast-NVMe machines
  with 16 GB+ RAM; on 8–16 GB systems it increases hard faults under memory pressure";
  `opt-disable-memory-compression` "16 GB+ RAM only"; `opt-disable-hags` "situational
  troubleshooting switch — try it only if you see stutter". — playbook.conf; README
- Memory compression revert is via `Enable-MMAgent -mc` "not via this registry inventory:
  Disable-MMAgent's backing store is not a documented public registry contract." — revert.yml

#### Windows build compatibility approach **[IMPLEMENTED]**
- Exact-match build allow-list (26100/26200/26300) + wizard hard refusal, by design ("the build
  gate protects you from tweaks aimed at a different Windows"); single servicing branch rationale
  ("all three share the same servicing branch, so one playbook covers them all").
- Per-action `ignoreErrors: true` for objects that may not exist per build; wildcard AppX lists
  "tolerate missing packages"; docs describe feature-update re-runs as the expected mechanism.
- Tooling is WMIC-free (CIM cmdlets) per CHANGELOG v1.0.0 ("Windows 11 26H2 readiness … WMIC-free
  tooling").
- **Dry-run harness:** `scripts/ame-dryrun.py` "ports the AME Wizard's actual load pipeline
  rule-for-rule" (container ZipCrypto "malte" + CRC + root layout → strict playbook.conf load →
  page/playbook validation → YAML tag/field/option graph → file references → execution
  simulation); `--selftest` reproduces the v1.0.0 load failure verbatim; simulated fresh-install
  plans resolve "Safe 150, Balanced 333, Extreme 403 actions on build 26300." — CHANGELOG
  (DOCUMENTED for harness internals; the script itself was not read).

#### Rollback / undo / backup mechanisms AND their limits (verified in source)
- **L0 — System Restore** ([RESTOREPOINT.ps1](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/src/playbook/Executables/RESTOREPOINT.ps1), **[IMPLEMENTED]**):
  `Enable-ComputerRestore` (idempotent) → `Checkpoint-Computer -RestorePointType
  MODIFY_SETTINGS`; **24-hour throttle handled honestly:** on failure, enumerates
  `Get-ComputerRestorePoint` for a point newer than 24h → exit 0 "keeping the existing point";
  only exits 1 when nothing protects the machine. Comment verified against the engine's MIT source:
  "the engine only LOGS non-zero exits (PowershellAction.cs:143-144) - a 1 never halts the
  playbook." Contrast stated in-file: "Unlike Atlas (which deletes all restore points in
  CLEANUP.ps1), UltraOS creates one before any change and NEVER deletes shadow copies."
- **L1 — Pre-change backups** ([BACKUP.ps1](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/src/playbook/Executables/BACKUP.ps1), **[IMPLEMENTED]**):
  `services-before.reg` = **full `reg.exe export` of HKLM\SYSTEM\CurrentControlSet\Services**
  (not just Start values); `appx-before.txt` = PackageFamilyName list (`Get-AppxPackage
  -AllUsers` with current-context fallback); `tasks-before.csv` = TaskPath/TaskName/State;
  `meta.json` = build/edition/version/preset/timestamp. Honest re-run semantics: "backups are
  REFRESHED on every playbook run - they capture the state immediately before the LATEST run";
  upgrade path clears `%WinDir%\UltraOS` so stale snapshots cannot survive. Services-export
  failure = exit 1 hard failure; appx/task failures degrade to warnings + empty baselines.
- **L2 — One-click undo** ([UNDO.ps1](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/src/playbook/Executables/UNDO.ps1) + [Undo.cmd](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/src/playbook/Executables/Undo.cmd), **[IMPLEMENTED]**):
  restores **only services whose Start differs from baseline** (generates a Start-only .reg,
  UTF-8 no BOM), re-enables **only tasks that were Ready/Running in baseline and Disabled now**,
  and prints removed-AppX reinstall pointers. **Deliberately does NOT blind-import the full
  services export:** "if Windows servicing changed a service between install and undo,
  re-importing old ImagePath/Security blobs would corrupt it." Header scope statement is explicit:
  registry policy/visual/network tweaks are **not** individually inverted by this script (revert
  data "requires the AME Wizard engine, not this script"); AppX removals and component-level
  changes are manual. `Undo.cmd` self-elevates via `fltmc` ("`net session` depends on the Server
  service and is unreliable on Home").
- **L3 — Stock-values inventory** ([revert.yml](https://raw.githubusercontent.com/UltraOS-Project/playbook/main/src/playbook/Configuration/ultraos/revert.yml), **[IMPLEMENTED]**):
  machine-readable record of Windows defaults, "never executed and intentionally NOT included
  from main.yml (importing it would undo the install immediately)." Honest coverage statement:
  covers the services lists + flagship policies + visual keys; **"NOT COVERED … the full inverse
  of every registryValue in every module file (~400 keys)"**; power-scheme changes are
  powercfg-level, not registry-invertible here.
- **L4 — Per-toggle .cmd pairs** in `C:\Windows\UltraOS\{1. Security, 2. Updates, 3. Features}`
  (Defender enable-only recovery, Mitigations, Core Isolation, GameDVR, Recall, updates mode) +
  install report (`REPORT.ps1`, 22 KB, not read; outputs `install-report.html` + `.txt`
  "every change, grouped per module, with a summary of what was skipped and why").
  **[IMPLEMENTED for file existence; DOCUMENTED for report contents]**
- **Observed doc/implementation discrepancy (important for NEXTRIX):** `docs/INSTALL.md` claims
  Undo "imports the playbook's revert data (stock registry values) to walk back policy and
  privacy changes," but `UNDO.ps1`'s own header says policies are NOT individually inverted there
  and applying revert data "requires the AME Wizard engine," and `Undo.cmd`'s header likewise
  lists only services + tasks. One of the project's few over-promises; the scripts themselves are
  the honest artifacts. **[IMPLEMENTED — the three files contradict the doc]**

#### Known compatibility issues **[DOCUMENTED — project's own CHANGELOG/docs; corroborated as COMMUNITY-REPORT where users found them]**
- **v1.1.1 (2026-10-08):** v1.0.0–v1.1.0 **halted on every fresh install** at
  `PowerShell instance exited with error code: 3` during "Copying UltraOS folder" —
  `Copy-Item` preserved the source folder name so it deployed as `Windows\UltraOSFolder` while
  everything expected `Windows\UltraOS`; "found by a user at runtime — a bug class neither the
  dry-run harness nor the validator could see." Two more re-run landmines fixed: upgrade runs
  deleted the fresh deployment (pipeline order), and a halted run left the default-user hive
  loaded (making re-run `reg load` fail). Also: `Undo.cmd` had shipped LF-only ("CRLF is the line
  ending cmd.exe documents"). — CHANGELOG
- **v1.0.1 (2026-10-08):** v1.0.0 **failed to load in AME Wizard** — engine rules unknown to the
  authors: `RadioPage with a TopLine and BottomLine must not have more than 2 options`;
  self-closing `RadioImagePage` would have crashed `RadioImagePage.Validate()` (NRE);
  `UpgradableFrom: none` is not a legal value. This produced `scripts/ame-dryrun.py`. — CHANGELOG
- **v1.1.0 docs-vs-code audit results (self-reported):** mouse-acceleration-off was documented as
  Safe-tier since v1.0.0 but "never actually shipped"; MMCSS `SystemResponsiveness` was documented
  Safe but gated to Balanced+; the v1.0.x revert inventory had **no stock entry for
  `SystemResponsiveness`, so one-click undo could not restore it.** — CHANGELOG
- **Edge removal → Windows Update loops** ("the single most documented Edge-removal consequence
  in the ecosystem: some Windows Update paths need Edge/WebView bits"); documented fix sequence
  (reinstall Edge → complete updates → re-remove), plus UltraOS's own mitigation (sweeps
  EdgeUpdater tasks and edgeupdate/edgeupdatem services). — docs/TROUBLESHOOTING.md
- **Removed apps return after feature updates** — "documented Microsoft behavior, not a bug":
  feature-update images ship new package versions/renamed families that pre-date the blocklist;
  documented answer: re-run (idempotent, refreshes backups). — docs/TROUBLESHOOTING.md
- **Restore point skipped by the 24h throttle** (documented cause + reassurance that file backups
  are unconditional). — docs/TROUBLESHOOTING.md
- No open GitHub issues at access time (repo API `open_issues_count: 0`). **[IMPLEMENTED — API]**

#### Safety-relevant behavior
- **Defender: never disabled.** "Keep Microsoft Defender and any other antivirus enabled. UltraOS
  does not ask you to disable protection." No `DefenderToggled` wizard requirement; the UltraOS
  folder ships a `Defender (Enable) (default).cmd` recovery toggle (enable-only). (Historical
  note: the v1.0.0 changelog lists a `opt-disable-defender` "Keep Defender disabled" extra among
  the original seven; no such option exists in v1.2.1's playbook.conf — the option was evidently
  dropped.) **[IMPLEMENTED — v1.2.1 playbook.conf has no Defender option; DOCUMENTED — README/INSTALL
  policy statements]**
- **Windows Update: never disabled** (automatic or notify-only); update services on the
  validator-enforced never-touch list. **[IMPLEMENTED]** — services.yml header; playbook.conf
- **UCPD: never fought** — no UserChoice/file-association writes; only the UCPD *velocity task*
  disabled (Balanced+), driver left loaded. **[IMPLEMENTED]** — services.yml; TROUBLESHOOTING
- **No kernel driver, no executables, no encoded commands/obfuscation** (`UseKernelDriver:
  false`); ANTIVIRUS.md documents an audit for dropper/downloader patterns and hash verification
  via `SHA256SUMS.txt`. **[IMPLEMENTED — conf; DOCUMENTED — ANTIVIRUS.md claims]**
- **Mitigations extra deliberately narrower than Atlas** (no all-2s nibble mask, no `nx OptIn`),
  with anti-cheat casualties named (EAC 0xEAC02014 per Atlas issue #1532; "Riot Vanguard … DOES
  require the separate VBS/HVCI option never be disabled") and manual undo instructions in the
  YAML. **[IMPLEMENTED]** — mitigations.yml comments
- **VBS extra carries the strongest warning** ("Not recommended. Breaks Vanguard/FACEIT
  anti-cheat, WSL2, Docker Desktop, Hyper-V"). **[DOCUMENTED]** — README options table
- No BCD edits at all in any file read (no `bcdedit` anywhere in the modules inspected) — a
  deliberate contrast to SynergyOS. **[IMPLEMENTED — absence in all read files; the unread
  `tweaks/*` may contain some, but the modules that would (boot visual changes) ship as registry/
  policy per MODULES references]**

### 3.3 Useful ideas for NEXTRIX (shortlist)
1. **The whole layered-rollback architecture**, honestly scoped: L0 restore point (throttle-aware,
   never deletes shadows) → L1 unconditional full-services/AppX/tasks snapshot → L2 Start-only
   service restore with baseline diffing → L3 never-executed stock-values inventory → L4
   per-toggle pairs + a per-change install report. NEXTRIX's "rollback-safe" requirement maps
   almost 1:1 onto this design.
2. **Start-only service undo with the full-export safety rationale** (never blind-import
   ImagePath/Security blobs that servicing may have changed) — the exact class of subtle
   corruption NEXTRIX must avoid.
3. **Validator-enforced never-touch service lists** — a CI gate that hard-errors when a
   contributing module disables `wuauserv`/`Spooler`/`SecurityHealthService`/etc. Cheap to
   implement in NEXTRIX's build and prevents the most damaging regressions.
4. **Preset depth tiers + never-preset-gated risky extras** with the trade-off written into the
   wizard UI — a clean model for "hardware-aware, modular" profiles.
5. **Honest-uncertainty annotations in tweak files** (e.g., "⚠️ UNVERIFIED existence on 26H2,
   classic community source only, hence ignoreErrors") — provenance discipline NEXTRIX should copy
   for every registry write.
6. **Dry-run harness replicating the AME engine's actual load rules** (incl. the page-layout caps
   that broke v1.0.0) plus a selftest that reproduces a historical failure — NEXTRIX's
   "simulate before apply" story should include exactly this kind of engine-rule port.
7. **Only-if-present NIC keyword writes** with an explicit "unknown benefit — do not touch" list
   (FlowControl/LSO/offloads) and per-adapter class-key resolution via `Enum\<PNPDeviceID>\Driver`;
   also the `-OLD` rename pattern before destructive value overwrites in the power module.
8. **Placebo rejection list with reasons** (pagefile, 1 ms timer ritual, treadmill services,
  RunOnce sprays, full update disable) — a ready-made "don't do this" appendix for NEXTRIX's docs.
9. **Release hygiene:** bot-generated releases with SHA256SUMS + LICENSE as release assets +
  README-FIRST + a real-wizard test script shipped to users.
10. **The research-dossier model** (`research/` directory citing learn.microsoft.com per tweak)
    matches NEXTRIX's source-backed mandate; `ame-wizard-format-spec.md` (42 KB, not read) is the
    community's most detailed write-up of the playbook container format and is worth a follow-up
    read by another subagent.

### 3.4 Reject / caution list
1. **The INSTALL.md undo over-claim** (revert-data import that UNDO.ps1 does not perform) — adopt
   the *scripts'* honesty level, not the doc's; NEXTRIX should enforce doc/code agreement in CI
   (UltraOS itself fixed two such mismatches only after manual audit).
2. **Edge removal is still a one-way-ish door** (WU loops documented) — if NEXTRIX offers it, gate
   it behind explicit warnings + the documented reinstall-first workflow.
3. **Single-branch targeting** (26100–26300 only) is philosophically clean but means no Windows 10
   and no Insider coverage; NEXTRIX's hardware-aware scope must decide whether a wider build matrix
   (SynergyOS-style) or a narrow audited one (UltraOS-style) fits its guarantees — UltraOS's own
   bug history argues the narrow matrix is the safer default.
4. **`opt-disable-vbs` and `opt-disable-mitigations` exist at all** — even opt-in, they carry
   anti-cheat/WSL2 breakage; NEXTRIX should decide its policy (likely: warn-and-document like
   UltraOS, or omit entirely).
5. **Some tuning extras depend on user self-assessment** ("fast NVMe + 16 GB RAM or more") rather
   than measured detection — NEXTRIX's hardware-aware foundation could enforce these thresholds
   automatically instead of trusting the checkbox label (an improvement over the reference, not a
   rejection of it).
6. **GPL-3.0** governs any copied YAML/scripts; like SynToolkit, reimplement patterns, cite
   Atlas/ReviOS attribution chain if specific values are borrowed (NOTICE shows the correct
   attribution practice for exactly this situation).
7. Files not read (extreme network flags, extreme services, appx-removal lists, REPORT.ps1,
   APPLYHIVE.ps1, edge-removal.yml, the dry-run/validator scripts) — do not extend findings in
   those areas beyond what main.yml/CHANGELOG state without a follow-up read.

### 3.5 Research limitations (UltraOS)
- Read files are listed in 3.1's URL list; **not read**: `docs/MODULES.md`, `docs/FAQ.md`,
  `docs/COMPARISON.md`, `docs/ANTIVIRUS.md`, `SECURITY.md`, `CONTRIBUTING.md`, all
  `research/*.md` dossiers, `scripts/*.py|sh` bodies, `tweaks/debloat/*.yml`,
  `tweaks/privacy/*.yml` (10 files), `tweaks/network/{core,extreme}.yml`,
  `tweaks/performance/{input,gaming,system,extreme,extras}.yml`, `tweaks/visual/*.yml`,
  `tweaks/qol/*.yml`, `tweaks/security/vbs.yml`, `tweaks/services/extreme-services.yml`,
  `tweaks/tasks/maintenance-tasks.yml`, `ultraos/{start,finish,copy-folders}.yml`,
  `Executables/{REPORT,APPLYHIVE,CLEANUP,EDGE-UNLOCK}.ps1`, `default-user.reg`,
  `UltraOSFolder/**` toggle bodies, `release-zip/*`. Statements about those files rest on
  main.yml's pipeline, the CHANGELOG, and README/MODULES references and are tagged accordingly.
- The `.apbx` container itself (ZipCrypto packaging, per ame-dryrun notes) was not unpacked;
  container-format claims come from CHANGELOG descriptions.
- No performance measurements exist anywhere in the project's public materials read (and none
  were reproduced here); all "what it does" claims above are about configuration changes, not
  outcomes.

---

## Cross-project synthesis for NEXTRIX (brief)

| Dimension | SynergyOS | SynToolkit | UltraOS |
|---|---|---|---|
| License | **None (all rights reserved)** | GPL-3.0 | GPL-3.0 |
| Build gate | 19044–26300 (9 builds, Win10+Win11) | x64 + ≥19041 (code) | 26100–26300 only (Win11) |
| Defender | Optional permanent CBS removal | Toggle (enable/disable) | Never touched |
| Windows Update | Paused to 2038, drivers blocked | Update-deferral toggles | Automatic or notify-only, never off |
| BCD | Raw `bcdedit` incl. timer forcing, no backup | WMI provider + read-after-write, safe-boot toggles | None in files read |
| Hardware awareness | NIC keyword capability probing; blanket device-power zeroing elsewhere | Full read-only WMI/registry inventory with uncertainty states; features gated on GPU vendor | Only-if-present NIC writes; RAM/NVMe thresholds in option labels; `-OLD` backups |
| Rollback | Minimal (service Start export helper, toggle pairs, wizard re-run) | Restore-point service with honest statuses; NVIDIA tweak backup store | 4-layer audited rollback with documented limits |
| Verification tooling | GitHub release workflow | 20-file test harness for detection logic | Dry-run engine simulator + hard-error validator |

Highest-value imports for NEXTRIX: SynToolkit's **detection/uncertainty-state patterns** (its
documentation-of-missing-data discipline is the best of the three), UltraOS's **rollback
architecture + never-touch enforcement + provenance-comment discipline**, and SynergyOS's
**NIC `Ndi\Params` capability probing** (idea only — the repo is unlicensed). Highest-value
cautions: SynergyOS's irreversible security teardowns, timer/BCD forcing without backups, and
update starvation; UltraOS's one observed doc/undo over-claim; SynToolkit's bundled kernel-mode
`inpoutx64` driver.

---

## Research limitations (global, per strict rules)

1. **Nothing was executed or reproduced.** This was read-only web research: no tweaks were run, no
   VM was used, no Windows setting on this host was inspected or altered. Therefore no VERIFIED
   performance results exist in this file, and no advertised capability should be read as proof of
   outcome. All three projects' claims about what their changes *do to performance* remain
   unverified by this researcher.
2. **GitHub API rate limiting:** the `/issues` REST endpoints returned HTTP 403 during this
   session. Issue data was gathered from public HTML pages instead; only SynergyOS issues #3 and
   #20 bodies were read, the rest are title-only COMMUNITY-CLAIMs. SynToolkit issue bodies were
   not read.
3. **Unread files.** Each project's unread-file list is recorded in its per-project limitations
   (1.5, 2.5, 3.5). In particular, all binaries (NoDefender.cab, SOS.pow, Synergy.nip, bundled
  .exe/.dll/.sys, the 141 MB SynToolkit installer, the .apbx containers) were **not** inspected;
   their behavior is inferred from filenames, invoking scripts, and documentation only.
4. **AME Wizard version dependency is unpinned in all three projects** (SynergyOS links an
   "AME Beta.zip" build; UltraOS links ameliorated.io → amelabs.net). No project states a minimum
   wizard version; that fact is recorded rather than guessed. AME Wizard engine internals
   (TrustedUninstaller) were not fetched.
5. **Doc/code conflicts were recorded as observed**, not adjudicated beyond the evidence (e.g.,
   SynergyOS's absent-but-referenced vbs.bat comment; SynToolkit's 17763-vs-19041 floor;
   UltraOS's INSTALL.md undo claim vs. UNDO.ps1 scope).
6. **Link rot possibility:** all raw.githubusercontent.com fetches succeeded at access time; the
   SynergyOS `Git` field still points at the old `kwanteks/SynergyOS` location while the repo lives
   under `Synergy-Tweaks` (redirection assumed, not verified).
7. Third-party destinations (Discord `dsc.gg/kwanteks`, YouTube channel, projectultraos.web.app)
   were not inspected; any claims exclusive to those channels are absent from this file.

Access date: 2026-11-23. Researcher: NEXTRIX subagent R4.
