# R2 Reference Research: AtlasOS & ReviOS Playbook

**NEXTRIX Phase 1 — reference-project research (subagent R2).**
Read-only web research. No tweaks were executed, no scripts were run against the host; only public pages/repos were fetched and this one notes file was written.

Evidence tags used throughout (exactly one per finding):

| Tag | Meaning |
|---|---|
| `IMPLEMENTED` | Verified in source actually fetched (raw file cited with repo path + URL) |
| `DOCUMENTED` | Official README/site/release-note claim, not verified in source |
| `COMMUNITY-CLAIM` | Third-party statement (GitHub issue reports, forum-style citations) |
| `DEV-BENCHMARK` | Developer-reported performance numbers (never proof of performance) |
| `VERIFIED` | Independently verified performance results — **none appear in this report**; no benchmarking was performed |

Repo states inspected (default branch `main` for both): Atlas-OS/Atlas @ tree `08ceb0ff613403610bc4c7527397d7e964713c90`; meetrevision/playbook @ tree `c9cdbd1b7d92666d4bffe67326cf1c8631eedef3`.

---

# Project 1: AtlasOS (Atlas-OS/Atlas)

## 1.1 Identity table

| Field | Value | Evidence |
|---|---|---|
| Name | Atlas ("AtlasOS"), described as "An open and lightweight modification to Windows, designed to optimise performance, privacy and usability" | [DOCUMENTED] https://raw.githubusercontent.com/Atlas-OS/Atlas/main/README.md |
| Repository | https://github.com/Atlas-OS/Atlas (default branch `main`, created 2021-02-08, pushed 2026-11-23, 22,190 stars, 784 forks, 18 open issues) | [IMPLEMENTED] https://api.github.com/repos/Atlas-OS/Atlas |
| Homepage / docs | https://atlasos.net / https://atlasos.net/docs/ | [DOCUMENTED] README |
| License | **GPL-3.0** — LICENSE file fetched and verified: "GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007" | [IMPLEMENTED] https://raw.githubusercontent.com/Atlas-OS/Atlas/main/LICENSE |
| Latest release | **0.6.1, published 2026-11-22** (0.6.0 published the same day). Assets: `AtlasManager.exe`, `Atlas-v0.6.1.atlaspkg` (44 MB), `SHA256SUMS.txt`. 0.6.1 is a hotfix "fixes several install and update failures reported after 0.6.0" | [IMPLEMENTED] https://api.github.com/repos/Atlas-OS/Atlas/releases/latest + releases list |
| Supported Windows (from code, not claims) | Windows 11 **25H2 build 26200** and **26H2 build 26300** only, from `supportedBuilds` in `package/atlas.json`; corroborated by README/docs; Insider/preview builds refused | [IMPLEMENTED] https://raw.githubusercontent.com/Atlas-OS/Atlas/main/package/atlas.json |
| Architectures | x64 and ARM64 client editions; Home, LTSC, IoT LTSC, Server refused by install checks | [IMPLEMENTED] docs/windows-release-policy.md + docs/front-door.md (both fetched, URLs below) |
| Historical format | `AtlasPlaybook_v*.apbx` (AME Wizard playbook) shipped from v0.1.0 (2023-04) through v0.5.0-hotfix (2025-10); v0.6.0 (2026-11-22) moved to `AtlasManager.exe` + `.atlaspkg` | [IMPLEMENTED] https://api.github.com/repos/Atlas-OS/Atlas/releases?per_page=15 (asset names enumerated per tag) |
| Key dependencies | Own Rust app (Atlas Manager, GPUI-based, source in `app/`); PowerShell 5.1 install engine; TrustedInstaller broker; CBS CABs built by Atlas-OS/sxsc (pinned SHA); bundled tools ViVeTool v0.3.3, SetTimerResolution.exe, StoreFixer.exe, MeasureSleep.exe (all listed with source/license in `package/Executables/AtlasModules/README.md`, existence verified in tree) | [IMPLEMENTED] repo tree + tools/sxsc/README.md |
| Distribution transparency | `.atlaspkg` is "a password-protected ZIP file that you can open with the password `atlasos`"; binary inventory and tweak/toggle catalogs published in-repo | [DOCUMENTED] README ("What Atlas changes"/"Check what Atlas does" sections) |

### URLs actually inspected (Atlas)

- API metadata: `https://api.github.com/repos/Atlas-OS/Atlas`, `.../releases/latest`, `.../releases?per_page=15`, `.../git/trees/main?recursive=1` (full tree, 1,867 entries)
- Raw files fetched: `README.md`, `LICENSE`, `package/atlas.json`, `docs/services-startup-policy.md`, `docs/windows-release-policy.md`, `docs/upgrading.md`, `docs/compatibility.md`, `docs/install-state.md`, `docs/power-saving-policy.md`, `docs/front-door.md`, `tools/sxsc/README.md`, `tools/sxsc/Atlas-Defender-Remover.yaml`, `tools/sxsc/Atlas-NoTelemetry.yaml` (component names extracted), `package/Executables/AtlasModules/Scripts/Modules/Atlas.Security/Domain/Defender.ps1`, `.../Modules/Atlas.Services/Domain/Backup.ps1`, `package/Executables/AtlasModules/Toggles/Security/Mitigations.ps1`, `.../Toggles/Boot/{KernelParameters,HighestMode,SpinningAnimations,AutomaticRepair,NewBootMenu,AdvancedBootOptions}.ps1`
- Website: `https://atlasos.net/docs/atlas-configuration/security/`
- Issues: `https://api.github.com/repos/Atlas-OS/Atlas/issues/...` (#1618 body fetched; issue list + search fetched)

## 1.2 Findings by area

### A. Architecture, delivery and AME Wizard history

- [IMPLEMENTED] Current install path: Atlas Manager (Rust, `app/`, GPUI UI) extracts the `.atlaspkg` and runs the "front door" `package/Executables/AtlasModules/Scripts/Entry/Install-Atlas.ps1` elevated via `powershell.exe -Command` with an `-Option` array. All privileged work runs as **TrustedInstaller** via a broker that runs `Invoke-AtlasInstallSession.ps1` in two phases (Capture, Run) with 5-minute and 2-hour limits. Source: docs/front-door.md (fetched) and repo tree (`Scripts/Entry/`, `Scripts/Install/Phases/`).
- [IMPLEMENTED] **AME Wizard era is over but visible in compat code**: `docs/compatibility.md` documents that pre-0.6 releases wrote the version marker `Atlas Playbook v<version>`, that 0.6.0 test builds kept `playbook.conf` staging copies and a `Playbooks` app-data folder, and pins each legacy artifact to a removal condition tied to `updatableFrom`. Release history confirms `AtlasPlaybook_v*.apbx` assets through 0.5.0-hotfix (`.apbx` is the AME Wizard playbook format).
- [IMPLEMENTED] The Atlas package installs itself into `%windir%\AtlasModules` and state into `%windir%\AtlasOS\{Install,state.json,...}`; a consumer-facing "AtlasDesktop" folder of numbered `.cmd` toggle launchers is deployed (tree: `package/Executables/AtlasDesktop/1..9`).

### B. Build/version guards (from code)

- [IMPLEMENTED] `package/atlas.json` declares `supportedBuilds: [{26200,"25H2"},{26300,"26H2"}]`, `updatableFrom: ["0.4.1","0.5.0","0.6.0"]`, `minimumManagerVersion: "0.6.0"`, `requirements: ["windows-security-off","no-third-party-antivirus","plugged-in"]`, and the full user-facing `choices` schema (defender, mitigations, auto-updates, keyboard, system, apps, extras, browser).
- [IMPLEMENTED] docs/windows-release-policy.md: only **public GA** builds qualify; Insider/Canary/Dev/Beta/Release-Preview refused; build number alone is insufficient — running-system checks read build + UBR, ISO checks read DISM four-part version + SPBuild; unlisted revisions are looked up online against Microsoft's Windows 11 release-health page (15 s deadline, 1 MiB body cap, ≤3 same-origin redirects, 15-minute in-memory cache) and classified `Released / Preview / Unlisted / Unknown`. The policy explicitly warns: "Eligibility isn't an authenticity check. Don't describe it as cryptographic verification."
- [IMPLEMENTED] docs/front-door.md requirement checks (each prints OK/FAIL/WARN; FAIL ⇒ exit code 2): Windows edition (client only; Home/LTSC/IoT-LTSC/Server refused), Windows build (in `supportedBuilds`), Windows release (GA catalog), User account (**UAC must be ON**, non-elevated token present, not Entra ID, not built-in Administrator), No pending reboot, No pending file replacements (informational), Plugged in, No third-party antivirus, Windows Security switches off (only when `windows-security-off` requirement present), No Windows update in progress. Distinct exit codes: 0 ok, 1 failed (resumable), 2 requirement unmet, 3 not elevated, 4 launcher fault, 5 preparation unfinished. Staging copy under `%windir%\AtlasOS\Staging` gets an ACL (SYSTEM+Administrators) and the copy refuses symlinks/junctions in the package.

### C. Service configuration approach — what exactly changes

- [IMPLEMENTED] docs/services-startup-policy.md (fetched in full) — **Atlas leaves most services/drivers at Windows defaults.** Complete list of startup-value changes:
  - File Sharing (Disable state, applied by default on fresh installs): driver `NetBT` → `Start=4` (after writing `NetbiosOptions=2` per interface); Enable restores `Start=1` + `NetbiosOptions=1`.
  - Location (Disable state, default): `lfsvc`, `MapsBroker` → Disabled and stopped.
  - `disable-pca` privacy tweak: `PcaSvc` → Disabled + stopped, after setting the documented `DisablePCA` policy, and disables `PcaPatchDbTask` (because a starting PcaSvc re-enables it).
  - `disallow-data-collection` privacy tweak: `DiagTrack` → Disabled + stopped, plus `AllowTelemetry`, `LimitDumpCollection`, `LimitDiagnosticLogCollection` policies.
  - Disable Printing toggle: `Spooler`, `PrintWorkFlowUserSvc` (user-run toggle, not a default).
  - Explicitly **kept at Windows default** (with per-service Microsoft-doc citations in the doc): `OneSyncSvc`, `TrkWks`, `diagnosticshub.standardcollector.service`, `wercplsupport`, `UCPD` ("Protection stays on. Atlas doesn't require UCPDDisabled"), `GpuEnergyDrv`, generic `Telemetry`, `WerSvc` (uses the documented ErrorReporting **policy**, not a startup change).
- [IMPLEMENTED] **Service backup before defaults**: before File Sharing/Location defaults, install exports every service/driver `Start` DWORD (valid 0–4 only) to `%windir%\AtlasModules\Other\winServices.reg`, a hand-importable `.reg`. First backup is never overwritten ("keeping any earlier backup"); the file is written to a temp name, validated, then moved. Defender's services are excluded from backup (`WdBoot`, `WdFilter`, `WdNisDrv`, `WdNisSvc`, `WinDefend`) because the Defender choice owns them. Restore validates the whole file before applying anything and skips services that no longer exist (`Set-AtlasServiceStartup -AllowMissing`). Source: `package/Executables/AtlasModules/Scripts/Modules/Atlas.Services/Domain/Backup.ps1` (fetched in full). A user-facing restore exists (`9. Troubleshooting\Set services to defaults.cmd` → `Entry/Restore-AtlasServiceDefaults.ps1`).
- [IMPLEMENTED] The doc defines a **"VM gate"**: any new production startup change requires a disposable-VM evidence record covering every supported release on x64 *and* ARM64, including clean-image service key type/Start/triggers/dependencies, post-servicing state, and results of dependent features, updates, repair, sleep telemetry, WER, default-app protection, file sharing, per-user provisioning, and Atlas reapply/restore. "A service missing from one image doesn't prove that `-AllowMissing` is safe on every build."
- [IMPLEMENTED] Atlas explicitly scopes Microsoft's own service-hardening tables (IoT Enterprise / VDI / Server guidance) as evidence only for those deployment types — they refuse to generalize VDI lists to general-purpose PCs.

### D. Security-relevant behavior (special attention)

- [IMPLEMENTED] **Defender removal is a CBS package transaction.** `tools/sxsc/Atlas-Defender-Remover.yaml` (fetched in full) defines package `Z-Atlas-NoDefender-Package` replacing ~90 Windows components including: `Security-Malware-Windows-Defender`, AM engine/signatures/definitions, Application Guard, Defender events/GPO/MDM/CSP+ADMX policy definitions, Defender Offline, `Windows-Defender-Service`, NIS service + drivers, Defender UI (with policy registry values `DisableNotifications=1`, `UILockdown=1` under Windows Defender Security Center), `Windows-SenseClient-*` (Defender for Endpoint), the entire `Microsoft-OneCore-WebThreatDefense-*` stack (driver, clipboard monitor, service), and SmartScreen (`Microsoft-Windows-AppRep*`, `Microsoft-Windows-SmartScreen`). Registry values the package writes include `EnableSmartScreen=0` (`...\Policies\Microsoft\System`), `SmartScreenEnabled='Off'` (Explorer), Edge `SmartScreenEnabled=0`, `EnabledV9=0` (phishing filter), **`SaveZoneInformation=1` (disables Mark-of-the-Web)** under `...\Policies\Attachments`, and `ModRiskFileTypes` under `...\Policies\Associations`.
- [IMPLEMENTED] `Atlas.Security/Domain/Defender.ps1` (fetched in full): state is judged by presence of the installed NoDefender package; **removal cannot simply write `MDCoreSvc` Start because Defender Tamper Protection is kernel-enforced until restart and denies the write even as TrustedInstaller** — instead a one-shot SYSTEM startup task (`AtlasDisableMDCoreSvc`) writes `Start=4` after the restart then deletes itself; restore sets `Start=2` *before* the package is removed (while Defender is still gone, so Tamper Protection cannot refuse). The interactive menu forces the user past "Only disable Windows Defender after reading the Atlas documentation" and the warning "Disabling Windows Defender leaves this PC without real-time antivirus protection."
- [IMPLEMENTED] `tools/sxsc/README.md`: four CABs (NoDefender/NoTelemetry × amd64/arm64) are built in CI from pinned `SXSC_REF` commit; **Atlas pins each CAB's SHA-256 in `Atlas-CbsHashes.psd1` and refuses to install a CAB missing from that file or hash-mismatched**; candidate CABs must be tested "on a disposable VM of each architecture you changed" before acceptance.
- [IMPLEMENTED] `tools/sxsc/Atlas-NoTelemetry.yaml` (component names extracted): removes `Microsoft-Windows-Compat-Appraiser`, `CompatTelRunner` (+ daily task), `Microsoft-Windows-Unified-Telemetry-Client` (aggregators, autologger, decoder host, settings, WoW64), `TelemetryClient`, `DeviceCensus-Schedule-ClientServer`, Application-Experience inventory components, Feedback services, `KeyboardDiagnostic`, `SIUF` settings handlers, `Power-EnergyEstimationEngine-Client-Overrides`, etc. (Commented-out components show deliberate restraint: e.g. `Microsoft-Windows-Application-Experience-Infrastructure` left in.)
- [IMPLEMENTED] `package/atlas.json` + docs security page: **whichever Defender answer is chosen, Atlas turns off Smart App Control, Enhanced Phishing Protection and Find my device**; Defender removal additionally removes SmartScreen; the docs state the consequence plainly ("Your PC has no antivirus protection until you install another antivirus app, and Windows doesn't warn you before you open unrecognised apps or downloads"). [DOCUMENTED] consequences from https://atlasos.net/docs/atlas-configuration/security/.
- [IMPLEMENTED] **CPU mitigations toggle is hardware-aware.** `Toggles/Security/Mitigations.ps1` (fetched in full): Disable does `Set-ProcessMitigation -System -Disable CFG`, `bcdedit /set nx OptIn`, fills `MitigationOptions`/`MitigationAuditOptions` masks with `0x22` at `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel` — **and re-enables CFG per-process for Riot Vanguard binaries (`valorant`, `valorant-win64-shipping`, `vgtray`, `vgc`) because "Vanguard requires CFG on its own processes even when it is disabled system-wide."** Enable-all computes `FeatureSettingsOverride` from CPU inventory: ARM64→64, Intel→0, AMD→64, throws on unsupported vendor or mixed-vendor CPUs, sets `FeatureSettingsOverrideMask=3`, `ProtectionMode=1`, `MinVmVersionForCpuBasedMitigations='1.0'`, `bcdedit /set nx AlwaysOn`. A 9-line excerpt (GPL-3.0, source https://raw.githubusercontent.com/Atlas-OS/Atlas/main/package/Executables/AtlasModules/Toggles/Security/Mitigations.ps1):

```powershell
$cpuOverrides = @($processors | ForEach-Object {
        if ([int]$_.Architecture -eq 12) { # ARM64
            64
        }
        elseif ([string]$_.Manufacturer -match '(?i)Intel') {
            0
        }
        elseif ([string]$_.Manufacturer -match '(?i)AMD') {
            64
        }
```

- [DOCUMENTED] Mitigations consequences per Atlas docs: any perf gain is CPU-dependent; "on some recent processors, such as AMD Zen 4, turning them off reduces performance" (cites Phoronix — third-party [COMMUNITY-CLAIM] corroboration, not a benchmark by Atlas); anti-cheat breakage is anticipated ("Run it if an anti-cheat stops working after you turn protections off"). Fault Tolerant Heap is off by default.
- [IMPLEMENTED] VBS/core isolation is a choice (`disable-core-isolation`), not a default; [DOCUMENTED] Atlas docs: "A policy on your PC, or a UEFI lock, can keep VBS as it is; Atlas then leaves it unchanged and says why" — matches `upgrading.md`'s `Left VBS as it is: <reason>.` behavior.
- [IMPLEMENTED] **UAC**: install *requires* UAC on (front-door check), and Atlas "has no file to turn UAC off"; the single UAC change is disabling the secure-desktop prompt ([DOCUMENTED] docs security page states the consequence: without the secure desktop "other apps can draw over [prompts] or read credentials you type"). The tweak exists as `Tweaks/qol/security/disable-uac-secure-desktop.psd1` (tree-verified).
- [DOCUMENTED] Firewall: "Atlas keeps Windows Defender Firewall on, and has no file to turn it off"; it only disables Remote Assistance rules and (by default) File and Printer Sharing / Network Discovery rules.
- [IMPLEMENTED] Update posture: the **default** choice in `atlas.json` is `auto-updates-disable` ("Install updates myself"), and the choice description says "Atlas keeps Windows on its current version, which gets security fixes only until Microsoft ends support for it" — i.e. automatic updates off *and* feature updates held back by default (tweaks `qol/windows-update/disable-auto-updates.psd1`, `disable-feature-updates.ps1`, tree-verified).

### E. Registry modifications observed (representative, from files fetched)

- Defender/SmartScreen policy values listed in section D (EnableSmartScreen, SmartScreenEnabled, EnabledV9, SaveZoneInformation, ModRiskFileTypes, UILockdown, DisableNotifications).
- Mitigations: `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel\MitigationOptions`/`MitigationAuditOptions` (binary masks `0x11`/`0x22`), `...\Memory Management\FeatureSettingsOverride{,Mask}`, `...\Session Manager\ProtectionMode`, `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\MinVmVersionForCpuBasedMitigations`.
- Telemetry: `AllowTelemetry`, `LimitDumpCollection`, `LimitDiagnosticLogCollection` policies (services-startup-policy.md).
- Toggle records store: `HKLM\SOFTWARE\AtlasOS\Services\<Name>` (DWORD `state`), machine state `%windir%\AtlasOS\state.json`, power rollback value `HKLM\SOFTWARE\AtlasOS\Services\PowerSaving\PreviousPowerSchemeGuid` (REG_SZ plan GUID).
- Power: only four AC values on a Balanced duplicate — NVMe NOPPME `fc7372b6-...`=0, Allow Throttle States `3b04d4fd-...`=0, display-off `3c0bc021-...`=0, processor perf time-check interval `4d2b0152-...`=200 ms ([IMPLEMENTED] docs/power-saving-policy.md).

### F. Scheduled task changes

- [IMPLEMENTED] `AtlasDisableMDCoreSvc` one-shot SYSTEM startup task (Defender.ps1, section D).
- [IMPLEMENTED] `disable-pca` disables `PcaPatchDbTask` (services-startup-policy.md).
- [IMPLEMENTED] Tweak `Tweaks/debloat/disable-scheduled-tasks.psd1` exists (tree-verified; contents not fetched — see limitations). `disable-automatic-maintenance` and `config-automatic-maintenance` tweaks exist as `.psd1` files.
- [IMPLEMENTED] User work (per-account settings, toggle user halves) is applied via **one-time sign-in migrations** stamped under `HKLM\SOFTWARE\AtlasOS\UpgradeUsers`, executed by `Entry/Update-AtlasUser.ps1` at next sign-in, with per-account transcripts in `%LOCALAPPDATA%\AtlasOS\Logs` (install-state.md).

### G. Power settings (hardware-aware scope control)

- [IMPLEMENTED] docs/power-saving-policy.md (fetched in full): the "Atlas Power Scheme" (`11111111-1111-1111-1111-111111111111`) is a duplicate of Balanced with **only four AC values changed**; DC/battery values untouched. An explicit "What the toggle doesn't change" table refuses blanket changes and gives the reason for each: `HKLM\SYSTEM\...\Enum` per-device idle/wake/D-state values, ACPI Processor Aggregator, localized-WMI-name device matching, bulk `MSPower_DeviceEnable`, network-adapter `*EEE`/`*SelectiveSuspend`, `StorageD3InModernStandby`, StorNVMe `IdlePowerMode`, NDIS `DefaultPnPCapabilities`, `PowerThrottlingOff` (kept "so leaving it alone keeps rollback exact"), NVMe idle timeouts / USB hub suspend / USB selective suspend / USB3 link power management / display dim zeros. Stated principle: settings are excluded "because it has no safe, exactly reversible way to apply them on all hardware, not because Windows lacks support."
- [IMPLEMENTED] Known rollback hole, self-documented: the separate network step `atlas-network-settings` sets five PCI adapter properties (`AutoDisableGigabit`, `ApCompatMode`, `SipsEnabled`, `ReduceSpeedOnPowerDown`, `DMACoalescing`) to 0 **without recording earlier values**; recovery is only the blunt "Reset Network to Windows Default" (network stack reset + adapter reinstall). Older Atlas versions' per-device `Enum` changes are left in place with "No compatibility switch restores the old per-device changes."
- [IMPLEMENTED] Implementation details: machine-wide mutex `Global\AtlasOS.PowerSaving.Transaction.v1`; rollback GUID saved before any plan change; every `powercfg` call's exit code checked; active plan read back before success is reported; never runs `powercfg /restoredefaultschemes`.

### H. BCD edits

- [IMPLEMENTED] Boot toggles (each fetched): `bcdedit /set {globalsettings} optionsedit true|removed` (KernelParameters), `{globalsettings} highestmode true|removed` (HighestMode), `{globalsettings} advancedoptions true|removed` (AdvancedBootOptions), `{current} bootstatuspolicy IgnoreAllFailures|DisplayAllFailures` (AutomaticRepair — note IgnoreAllFailures suppresses boot-failure UX), `{current} bootmenupolicy legacy|standard` (NewBootMenu), `{globalsettings} custom:16000069 true|removed` (SpinningAnimations — Atlas's own comment: "Microsoft does not document custom:16000069. Community source: winaero.com"), and `bcdedit /set nx OptIn|AlwaysOn` (Mitigations). All are opt-in post-install toggles with Enable/Disable pairs, not install defaults.

### I. Rollback / undo / backup mechanisms and their limits

- [IMPLEMENTED] Service backup/restore (winServices.reg): section C — validated, first-backup-kept, Defender services excluded, missing services skipped at restore.
- [IMPLEMENTED] Toggle engine: every applied state is recorded under `HKLM\SOFTWARE\AtlasOS\Services\<Name>` + mirrored in `state.json` with `updatedAt`; updates **replay every record** with the new release's definitions; drift between record and PC is logged ("shows declarations a newer Windows build ignores"); the store "never keeps executable paths". A toggle state that also changes services is never *adopted* from registry coincidence — only single-registry-value states can be inferred. (docs/install-state.md, fetched.)
- [IMPLEMENTED] Update semantics (docs/upgrading.md, fetched): updates keep Start/taskbar layouts, file associations and first-install service backups; `Keep my choices` locks choices to observed PC state (with `Kept ...` log lines); `Choose again` re-applies differing choices, **but some changes are explicitly irreversible in an update**: removed Edge stays removed (reinstall via Atlas folder app), Snipping Tool removals per-account are not undone, "Neither way repeats Atlas's other app removals, or its Phone Link, OneDrive or Smart App Control changes."
- [IMPLEMENTED] Defender reversibility is conditional: "Keeping it puts Defender's core service back and takes Atlas's NoDefender package off… Atlas can take off only its own package, so a Defender missing for another reason stays missing, with a warning."
- [IMPLEMENTED] Crash-safe install state machine: `%windir%\AtlasOS\Install\active.json` (schema-checked, atomic write via temp+move, `active.json.bak` recovery, global mutex `Global\AtlasOS.InstallState.v1`, `transactionId`, `completedSteps`, `lastError` capped at 4096 chars, replay rules `Once`/`Always`); failed installs resume at the first incomplete step; a retry with different options is refused and names the original ones.
- [IMPLEMENTED] Completion honesty: the PC is re-read after install; choices that didn't take effect are surfaced (`notApplied` in `state.json` history, "Some choices didn't take effect" + Open log file); toggles keep their records in step; **"Microsoft Defender is still removed"** warning when record and reality disagree.
- [IMPLEMENTED] Stated limits: per-device power changes have no exact rollback (section G); network adapter properties unrecorded (section G); updates can't undo app removals (above); pre-0.6 Toolbox records are repaired only partially, with a `Customized old Atlas Toolbox record ... was retained.` warning when keys hold foreign values.

### J. Testing / evidence discipline

- [IMPLEMENTED] ~130 Pester test files in `tests/` (tree-enumerated), e.g. `Atlas.DefenderChoice.Tests.ps1`, `Atlas.ResetServices.Tests.ps1`, `Atlas.ServiceDefaultsReset.Tests.ps1`, `Atlas.UpgradeSafety.Tests.ps1`, `Atlas.WindowsRelease.Tests.ps1`, `Atlas.SetupSafety.Tests.ps1`, `Atlas.PowerSavingPlanChoices.Tests.ps1`, `Atlas.MitigationsToggle.Tests.ps1`; a lab runner `tools/lab/Invoke-AtlasLabRun.ps1` "restores a Hyper-V checkpoint, installs through the front door and runs the health check" ([DOCUMENTED] front-door.md quote of testing.md).
- [IMPLEMENTED] `Check Atlas Health.cmd` (`Entry/Test-AtlasHealth.ps1`) "reports what Atlas installed and what has changed since, **without changing anything**" — a read-only post-install verifier.

### K. Known compatibility issues (issues/release notes)

- [DOCUMENTED] 0.6.1 release body: hotfix for "several install and update failures reported after 0.6.0" — 0.6.0 and 0.6.1 published the same day (2026-11-22); an install-quality incident acknowledged in the release itself.
- [COMMUNITY-CLAIM] Issue **#1618 "[BUG] — Atlas breaks AMD chipset drivers installer"** (closed 2026-05-13, 54 comments): reporter states the AMD chipset installer fails at 64% / "intended to be deployed only on an AMD system" even with VBScript enabled, and that "I installed Windows 11 vanilla without preserving my apps and it finally worked, so Atlas OS has probably something to do with this." Body fetched; the fix commit was not traced (see limitations).
- [COMMUNITY-CLAIM] Issue **#1739 "[FEATURE] — Support for Windows 26H2 / Windows 26H2 Compatibility"** (open at fetch time, 3 comments) — 26H2 support landed in the 0.6.0/0.6.1 releases the same week.
- [COMMUNITY-CLAIM] Issue **#1763** (open): installs fail `0x80073CF9 / 0x80070490` "because of orphaned rows in StateRepository-Deployment.srd".
- [COMMUNITY-CLAIM] Issue **#1493** (closed): "Atlas v0.5.0 / 25H2 — Explorer keeps restarting"; **#1749** (closed): iCloud for Windows fails to initialize Passwords/Keychain on 25H2; **#1623** (closed, AME-era): AME Beta extracting `TrustedUninstaller.CLI.exe` as ARM64 on x64.
- [COMMUNITY-CLAIM] Issue **#704 "[FEATURE REQUEST] — Keep Windows Defender and related"** (closed, 15 reactions) — community pressure that plausibly shaped today's "Keep Defender (recommended)" choice design.
- [DOCUMENTED] Atlas's own consequence warnings: Defender removal (no AV, no MOTW-era warnings), mitigations off (may *reduce* perf on recent CPUs; anti-cheat risk), VBS off (apps requiring VBS affected), UAC secure-desktop off (spoofable prompts). These are the project's own documented compatibility consequences for its security modifications.

### L. Evidence vs assertion, and reputation

- [IMPLEMENTED/observation] Atlas is unusual among Windows debloat projects in citing Microsoft Learn URLs inline for nearly every service/power decision, publishing per-component removal manifests (sxsc YAML), pinning binary hashes, and explicitly labeling perf claims as non-guarantees ("An Atlas product choice, not a performance or DPC-latency guarantee"). No FPS/latency benchmark numbers appear anywhere in the fetched sources; the only performance statements are the mitigations note (citing Phoronix, third-party) and README's "Performance results depend on your hardware and workload."
- [COMMUNITY-CLAIM] Reputation signals from the issue tracker: few open issues (18), the sharpest documented incidents being the AMD chipset installer breakage (#1618), the same-day 0.6.0→0.6.1 hotfix, and StateRepository install failures (#1763). No repository-side mass of "boot failure" issues was observed in the fetched sample; no forum anecdotes were used.

## 1.3 Useful ideas for NEXTRIX (Atlas shortlist)

1. **VM gate with a written evidence record** before any production service/startup change (per-build, per-arch, clean-image baselines + servicing + repair flows). Directly transferable to NEXTRIX's "hardware-aware, rollback-safe" charter.
2. **Service Start backup as a hand-importable `.reg`** with validation, first-backup preservation, AV-service exclusion list, and `-AllowMissing` restore counting.
3. **supportedBuilds manifest + GA release catalog** (offline JSON with SHA-pinned source doc) + classified unlisted-revision handling; treating "build number alone" as insufficient.
4. **Resumable transactional installer**: active.json with transactionId/completedSteps/replay rules; refusals name the original options; staging under ACL-protected folder refusing symlinks.
5. **Record-what-the-PC-shows, not what-was-asked**: post-install re-read, `notApplied` list, warnings when record ≠ reality ("Defender is still removed").
6. **"What we do NOT change and why" tables** (power policy) — an exact-rollback admission test for every candidate tweak: if you can't restore the prior value exactly, don't ship it.
7. **CPU-vendor-aware mitigation values** (Intel 0 / AMD 64 / ARM64 64, refuse mixed) + per-app mitigation exceptions for anti-cheat (Vanguard CFG).
8. **Choice UI that forces consequence-reading** (Defender menu gates on documentation; Windows Security step requires user to flip switches themselves).
9. **Read-only health verifier** that reports drift without changing anything — cheap trust-builder.
10. **Binary inventory + hash pinning** for every bundled executable/CAB; inspectable package (password-published ZIP).
11. Exit-code contract (0/1/2/3/4/5) for an install script — makes automation and support triage deterministic.
12. One-shot startup task pattern for writes blocked by kernel-enforced Tamper Protection — with self-delete, and the inverse order on restore.

## 1.4 Reject / caution (Atlas)

1. **Defender + SmartScreen + WebThreatDefense CBS removal and `SaveZoneInformation=1` (MOTW off)** — deep, risky, and outside a tweak playbook's remit; NEXTRIX should not replicate component-level AV removal.
2. **`custom:16000069` BCD value** — undocumented even by Atlas's own comment (winaero community source).
3. **`bootstatuspolicy IgnoreAllFailures`** — suppresses boot-failure diagnosis UX; a repair-hiding change.
4. **Automatic updates off + feature updates held back as the default choice** — security-posture cost documented by Atlas itself ("gets security fixes only until Microsoft ends support").
5. **UAC secure-desktop off** — Atlas honestly documents that prompts become spoofable; NEXTRIX should not ship this as a default.
6. **Smart App Control / Enhanced Phishing / Find-my-device turned off regardless of the Defender choice** — coupling "even if you keep Defender" losses to every install.
7. **MDCoreSvc scheduled-task race** — clever, but a restart-dependent timing hack; if NEXTRIX never removes Defender it never needs it.
8. **Network adapter properties written without recording prior values** — Atlas's own self-identified rollback hole; the pattern to avoid.
9. Historical **`BypassWindows11Requirements.cmd`** (0.3.x release assets) and the "Shortcut Icon: None (security risk)" launcher — examples of shipping risk-flagged actions to end users.

## 1.5 Research limitations (Atlas)

- Raw fetches reflect `main` at access date (tree `08ceb0f...`); the shipped `.atlaspkg` (44 MB) was not downloaded or executed, so package-build fidelity to the tree is assumed from docs, not verified byte-for-byte.
- `docs/catalog/toggles.md` and `docs/catalog/tweaks.md` (the full per-tweak registry catalogs) were referenced but not fetched (size); some per-tweak registry paths are therefore only tree-verified by filename (e.g. `disable-scheduled-tasks.psd1` contents unread).
- Files referenced but not fetched: `docs/architecture.md`, `docs/preparation.md`, `docs/windows-transition.md`, `docs/package-format.md`, `app/` Rust sources, `AtlasDesktop` `.cmd` wrappers, `Toggles/Security/{VbsState,ConfigVBS,ToggleDefender}.ps1` bodies.
- Issue #1618's 54 comments were not read; the closing fix commit was not identified — the report therefore records the incident, not its root cause.
- GitHub's unauthenticated REST API rate limit was hit mid-session (issue list search); issue data was completed via an authenticated GitHub MCP client. No atlasos.net FAQ pages beyond the security page were fetched.
- No Atlas claims were executed or benchmarked; there are **no VERIFIED tags** for Atlas. Discord/GitHub Discussions were not searched; community signals come from the issue tracker only.

---

# Project 2: ReviOS Playbook (meetrevision/playbook)

## 2.1 Identity table

| Field | Value | Evidence |
|---|---|---|
| Name | ReviOS Playbook — "A lightweight, stable, and performance-focused customized version of Windows that enhances privacy and compatibility"; playbook for AME Wizard | [IMPLEMENTED] https://raw.githubusercontent.com/meetrevision/playbook/main/README.md + repo API description |
| Repository | https://github.com/meetrevision/playbook (default branch `main`, created 2023-03-31, pushed 2026-11-23, 2,140 stars, 126 forks, 6 open issues) | [IMPLEMENTED] https://api.github.com/repos/meetrevision/playbook |
| Homepage / docs | https://www.revi.cc / https://revi.cc/docs | [DOCUMENTED] README |
| License | **CC-BY-SA-4.0** — LICENSE file fetched and verified ("Attribution-ShareAlike 4.0 International"). Release 25.10 notes a license change **from CC BY-NC-SA 4.0 to CC BY-SA 4.0** | [IMPLEMENTED] https://raw.githubusercontent.com/meetrevision/playbook/main/LICENSE + [DOCUMENTED] release 25.10 body |
| Latest release | **26.10, published 2026-10-09**; **no playbook asset on GitHub** — release body: "We decided to not provide playbook file on GitHub. Please use following link: 📌Link: https://modsfire.com/1Gk32tw44w139Bc" with SHA256 `7698B5...C74A`; bundled Revision Tool [2.13.0] with its own SHA256 | [IMPLEMENTED] https://api.github.com/repos/meetrevision/playbook/releases/latest |
| Supported Windows (from code) | `src/playbook.conf` `<SupportedBuilds>`: **19044 (Win10 21H2 +LTSC), 19045 (22H2), 22631 (Win11 23H2), 26100 (24H2 +LTSC), 26200 (25H2), 28000 (26H1), 26300 (26H2)** — README lists the same with "(+ LTSC)" notes and states "Any other build **is not** supported by Revision." ISO injection: Windows 11 ISOs only | [IMPLEMENTED] https://raw.githubusercontent.com/meetrevision/playbook/main/src/playbook.conf |
| Architectures | AMD64 and ARM64 per README; Brave installer fetched per-arch (`cpuArch: X64`/`Arm64`) in software.yml; 24.06 release note: ARM64 support initially "only … Windows 11" | [IMPLEMENTED] README + `src/Configuration/Tasks/software.yml` + [DOCUMENTED] release 24.06 |
| Dependencies | **AME Wizard** (README links amelabs.net; install docs link ameliorated.io; ISO mode requires **AME Wizard Beta**). Core tweak engine: **Revision Tool** (`revitool.exe`) — downloaded from `meetrevision/revision-tool/releases/latest` at install with bundled fallback (pinned in CI to the latest release with SHA256 verification); system-component removals via CBS-style packages from the separate `meetrevision/packages` repo | [IMPLEMENTED] `.github/workflows/main.yml` + `src/Configuration/Tasks/start.yml` + `Tasks/packages/win-sxs.yml`; [DOCUMENTED] revi.cc docs pages |
| Build/packaging | CI: version = `YY.MM` date; playbook source archived with `7z a -pmalte -mhe=on Revi-PB-<version>.apbx` (AME Wizard playbook container, password `malte`); `playbook.conf` `<Version>` and `FINALIZE.cmd` version are rewritten by CI | [IMPLEMENTED] https://raw.githubusercontent.com/meetrevision/playbook/main/.github/workflows/main.yml |
| AME Wizard metadata | `playbook.conf`: `UpgradableFrom: any`, `UseKernelDriver: false`, `ProductCode: 32`, `UniqueId 6a93ec26-284d-4943-9fc4-c9616def55c6`, `SupportsISO: true` with `<ISO><DisableBitLocker>true</DisableBitLocker><DisableHardwareRequirements>true</DisableHardwareRequirements></ISO>`; `<Requirements>`: `DefenderToggled, NoPendingUpdates, NoAntivirus, Internet, PluggedIn` | [IMPLEMENTED] src/playbook.conf |

### URLs actually inspected (ReviOS)

- API metadata: `https://api.github.com/repos/meetrevision/playbook`, `.../releases/latest`, `.../git/trees/main?recursive=1` (full tree), releases 23.12→26.10 (via GitHub MCP), issues list + issue #222 (via GitHub MCP)
- Raw files fetched: `README.md`, `LICENSE`, `.github/workflows/main.yml`, `src/playbook.conf`, `src/Configuration/main.yml`, `src/Configuration/Tasks/{start,software,services,registry,revert,final}.yml`, `src/Configuration/Tasks/packages/{win-sxs,appx}.yml`, `src/Configuration/Tasks/registry/{security/{security,vbs,bitlocker}.yml, system/{boot,bypass-requirements,crash-control,ifeo,kernel,multimedia-unread,win32ps,power}.yml, updates/{updates,drivers}.yml, privacy/telemetry.yml}`, `src/Executables/{hosts,FINALIZE.cmd}`
- Website: `https://revi.cc/docs/playbook/install`, `https://revi.cc/docs/playbook/uninstall`, `https://revi.cc/docs/playbook/iso`

## 2.2 Findings by area

### A. Playbook structure, feature declarations and defaults

- [IMPLEMENTED] AME Wizard task graph in `src/Configuration/main.yml`: os-info → start (hosts copy, VCRedist, Revision Tool install, ngen) → app-win32 → win-sxs → appx → **kills Explorer/SearchApp/SearchHost/RuntimeBroker/TextInputHost/ShellExperienceHost/backgroundTaskHost/Widgets** → software → services → registry → revert (upgrade-only) → final. Privilege model: tasks run as `Admin` or **`TrustedInstaller`** per task file.
- [IMPLEMENTED] `playbook.conf` feature pages and defaults: browser radio (Brave default); **Defender radio default = `disable-defender`** ("Disabling Windows Defender can improve system performance, but at the cost of security."); hibernate default = disable ("Disabling may overheat laptops in sleep mode"); removal checkboxes default-on: `remove-edge`, `remove-onedrive`, `remove-winsxs-ai` (Recall & Copilot), `remove-teams`, `remove-appx-photos`, `remove-appx-devhome`, `remove-appx-yourphone`; default-off: `remove-appx-xbox`, `disable-automatic-maintenance`; appearance defaults-on: wallpaper, dark mode, legacy context menu, transparency effects off, Start pins removed.
- [IMPLEMENTED] Option-gating uses AME Wizard `option:`/negation (`!name`) semantics throughout the task files (e.g. `option: 'enable-defender'`, `option: '!remove-appx-xbox'`).

### B. Service configuration

- [IMPLEMENTED] `Tasks/services.yml` (fetched in full) — services set to `startup: 4` (Disabled): `dam`, `GpuEnergyDrv`, `NetBT`, `Telemetry` (Intel telemetry service), `diagnosticshub.standardcollector.service`, `WerSvc`, `DiagTrack`, `wisvc`, `PcaSvc`, `WdiServiceHost`, `WdiSystemHost`, `tcpipreg` (**commented "experimental"**), `Wecsvc`, `UCPD` (+ `Disable-ScheduledTask` on `UCPD velocity`). `edgeupdate` set to Manual with the comment "Disabling it breaks WebView installation via Visual Studio". `condrv` set to Automatic to fix error 0xd000003a (issue #184). Commented-out (not applied): `Beep`, `GraphicsPerfSvc`, `bam`, `Ndu`. 6-line excerpt (CC-BY-SA-4.0, source https://raw.githubusercontent.com/meetrevision/playbook/main/src/Configuration/Tasks/services.yml):

```yaml
  # === Unified Telemetry Client - Disabled
  - !service: {name: 'DiagTrack', operation: change, startup: 4}
  # == UCPD velocity - Disabled
  - !service: {name: 'UCPD', operation: change, startup: 4}
  - !powerShell: {command: "Disable-ScheduledTask -TaskPath '\\Microsoft\\Windows\\AppxDeploymentClient' -TaskName 'UCPD velocity'"}
```

- [IMPLEMENTED] **Direct contrast with Atlas**: ReviOS disables `UCPD` (the default-app-protection filter driver) and its velocity task — Atlas explicitly keeps UCPD protection on and documents why; ReviOS disables `WerSvc` via startup — Atlas uses the documented ErrorReporting policy instead; ReviOS disables `diagnosticshub.standardcollector.service` — Atlas reviewed it and kept default.
- [COMMUNITY-CLAIM] Consequence in the tracker: **issue #228 "[BUG]: SMB 1.0 stops working"** (open, 9 comments) — consistent with the implemented `NetBT`/`tcpipreg` disables.

### C. Security-relevant behavior (Defender, VBS, BitLocker, SmartScreen, updates)

- [IMPLEMENTED] **Defender is force-disabled during every deployment** regardless of final user choice: `win-sxs.yml` runs `revitool.exe tweaks security defender disable --force` unconditionally; `final.yml` re-enables only `option: 'enable-defender'`, with the comment "Defender is always disabled during deployment to avoid access-denied errors on policy keys (e.g. EnableFeeds, AllowNewsAndInterests). See: issue #243." The default radio choice in `playbook.conf` is **disable**.
- [IMPLEMENTED] `registry/security/security.yml`: hides the Account Protection page state (`AccountProtection_MicrosoftAccount_Disconnected=0`); Defender reporting `DisableGenericRePorts=1`; `SubmitSamplesConsent=2` (never prompt/send samples); `DisableScheduledSignatureUpdateOnBattery=1` (**signature updates on battery disabled**); SmartScreen `ConfigureAppInstallControlEnabled=1` + `ConfigureAppInstallControl='Anywhere'` (app-install warnings effectively off); `EnableWebContentEvaluation=0`; Edge `PhishingFilter\EnabledV9=0`; **Windows Security tray hidden (`HideSystray=1`) and `SecurityHealth` autorun deleted**.
- [IMPLEMENTED] `registry/security/vbs.yml`: runs `revitool tweaks security vbs disable` — "automatically disables Memory Integrity (HVCI) as well" — with the comment "Disabling VBS improves gaming performance" linking a Microsoft support page about gaming performance. **No option gate on this task**; it is invoked unconditionally from `registry.yml`. [COMMUNITY-CLAIM] Issue **#222**: on Secured-core PCs (HP EliteBook, UEFI-locked VBS) the disable silently fails — "ReviOS control settings Security says it's off" but VBS stays on; maintainer reply: "Try out the latest version of the Revision tool".
- [IMPLEMENTED] `registry/security/bitlocker.yml`: `HKLM\SYSTEM\ControlSet001\Control\BitLocker\PreventDeviceEncryption=1` — automatic device encryption disabled (unconditional).
- [IMPLEMENTED] Windows Update posture (`registry/updates/updates.yml` + win-sxs.yml): **updates paused to 2038-01-19** via `revitool tweaks updates wu-pause-updates enable` (the `FlightSettingsMaxPauseDays` trick); driver updates via WU disabled (`wu-drivers disable`); `DODownloadMode=0`; Insider `AllowBuildPreview=0`; reserved storage disabled (`ShippedWithReserves=0`); DevHome/Outlook OOBE orchestrator updates blocked; `MRT\DontReportInfectionInformation=1`; `HideMCTLink=1`, `RestartNotificationsAllowed2=0`. The old `NoAutoUpdate=1` AU policy is commented out ("Used to break Xbox Sign-in in older Windows 10 versions"). [DOCUMENTED] The uninstall docs page confirms the pause mechanism must be manually turned off to uninstall.
- [IMPLEMENTED] IFEO abuse (`registry/system/ifeo.yml`): sets `Debugger = %windir%\System32\taskkill.exe` under `Image File Execution Options` for `CompatTelRunner.exe`, `AggregatorHost.exe`, `DeviceCensus.exe`, `FeatureLoader.exe` (PC Manager), `BingChatInstaller.exe`, `BGAUpsell.exe`, `BCILauncher.exe` — i.e., kills those system binaries at launch via debugger redirection. Same file sets `PerfOptions` CPU priorities: `SearchIndexer.exe`=5 (below normal), `ctfmon.exe`=5, `fontdrvhost.exe`=1, **`lsass.exe`=1**, `sihost.exe`=1 (+ IoPriority 0).
- [IMPLEMENTED] TSX: `registry/system/kernel.yml` runs `revitool tweaks performance intel-tsx enable`; comment: "By default it's disabled due to security reasons; Enabling it makes 4~5 times faster in database transaction and around 40% faster in specific workloads" (issue #100 cited). **[DEV-BENCHMARK]** — developer-reported numbers; enabling TSX re-exposes side-channel vulnerability class on affected CPUs.
- [IMPLEMENTED] Boot/crash: `boot.yml` sets `BootExecute = autocheck autochk /k:C*` (**disables automatic disk checking on boot**); `crash-control.yml` sets `AutoReboot=0`, `CrashDumpEnabled=3` (small 64 KB dumps only).
- [IMPLEMENTED] Requirements bypass: `bypass-requirements.yml` writes `HKLM\SYSTEM\Setup\LabConfig\{BypassSecureBootCheck,BypassTPMCheck,BypassCPUCheck,BypassRAMCheck,BypassStorageCheck}=1`, `MoSetup\AllowUpgradesWithUnsupportedTPMOrCPU=1`, `UnsupportedHardwareNotificationCache\SV1/SV2=0`, `OOBE\BypassNRO=1` — comment: "most of them are only for boot.wim". ISO mode additionally declares `DisableBitLocker=true` + `DisableHardwareRequirements=true` in `playbook.conf`. [DOCUMENTED] revi.cc ISO known issues: **Ctrl+Alt+Del disabled** on ISO installs (workaround `reg delete ...OOBE\SystemProtected /v DisableCAD`), Bluetooth failure after setup (workaround deletes `OOBEInProgressDriverUpdatesPostponed`), classic context menu missing.
- [IMPLEMENTED] Accounts: `FINALIZE.cmd` runs `net accounts /maxpwage:unlimited`.
- [IMPLEMENTED] Memory: `final.yml` runs `Disable-MMAgent -mc` (memory compression off).

### D. Registry modifications observed (beyond section C)

- `Win32PrioritySeparation=38` (`system/win32ps.yml`).
- Telemetry (`privacy/telemetry.yml`): `AllowTelemetry=0` across 7 locations (HKCU/HKLM policies, `CurrentVersion\Policies\DataCollection`, Wow6432Node, PolicyManager default, CPSS DevicePolicy/Store), `AllowCommercialDataPipeline=0`, `AllowDeviceNameInTelemetry=0`, `DisableEnterpriseAuthProxy=1`, `MicrosoftEdgeDataOptIn=0`, opt-in UX/notification disables, `AllowExperimentation=0`, `EnableConfigFlighting=0`, WMI autologgers `Diagtrack-Listener`, `SQMLogger`, `SetupPlatformTel` → `Start=0`.
- Power/logon: `power.yml` (hibernation+fast startup per option via revitool, `ShowSleepOption=1`, **`ShutdownWithoutLogon=1`**).
- Branding/OEM: `os-info/edition.yml`, `oem-info.yml` tasks; `FINALIZE.cmd` writes `bcdedit /set description "ReviOS 11 <version>"`, `OEMInformation\Model`, `RegisteredOrganization`.

### E. Scheduled tasks, event logs, hosts file, component removal

- [IMPLEMENTED] `FINALIZE.cmd` (fetched in full) disables scheduled tasks: `Power Efficiency Diagnostics\AnalyzeSystem`, `MemoryDiagnostic\{ProcessMemoryDiagnosticEvents,RunFullMemoryDiagnostic}`, `WindowsUpdate\Scheduled Start`, `Windows Error Reporting\QueueReporting`, `Application Experience\{AitAgent,Microsoft Compatibility Appraiser}`, `DiskDiagnostic\...DataCollector`, `CEIP\{Consolidator,UsbCeip,KernelCeipTask}`, `UpdateOrchestrator\{StartOobeAppsScanAfterUpdate,Start Oobe Expedite Work,Schedule Scan}`; `final.yml` disables all `\Microsoft\Office\*` tasks. It also disables diagnostic event logs (`wevtutil sl ...SleepStudy/Diagnostic`, `Kernel-Processor-Power/Diagnostic`, `UserModePowerService/Diagnostic`), uninstalls **Microsoft Update Health Tools, PC Health Check, Windows Installation Assistant**, runs `Disable-WindowsErrorReporting`, and sets `DOTNET_CLI_TELEMETRY_OPTOUT`/`POWERSHELL_TELEMETRY_OPTOUT`.
- [IMPLEMENTED] `FINALIZE.cmd` BCD edits: `bcdedit /deletevalue useplatformclock`; `disabledynamictick` **removed** with the comment "bcdedit /set disabledynamictick yes — breaks ROG Ally sleep, see #167"; `bootmenupolicy Legacy`; `lastknowngood yes`; Teredo reset to defaults.
- [IMPLEMENTED] `start.yml` **overwrites `%WINDIR%\System32\drivers\etc\hosts`** with the bundled file (`copy /y`) and flushes DNS. The hosts file (fetched) blocks ~60 endpoints with `0.0.0.0`, including Watson/WER cab-upload endpoints, DiagTrack event endpoints, **Brave's `cr.brave.com` and `star-randsrv.bsg.brave.com`**, and Visual Studio/VSCode telemetry; one line is commented out "breaks Visual Studio Download page" — evidence they hit breakage and narrowed the list rather than removing the technique.
- [IMPLEMENTED] Appx removal (`packages/appx.yml`): ~41 packages removed for all users via `revitool appx --all-users --remove` (Camera, Alarms, Maps, Sticky Notes, communicationsapps, People, Bing*, Solitaire, FeedbackHub, GetHelp/GetStarted, Cortana, QuickAssist, Family, Zune*, SoundRecorder, Clipchamp, Whiteboard, SurfaceHub Teams/Mail, PowerBI, Skype, OfficeHub, Office{Excel,PowerPoint,Word,OneNote}, OutlookForWindows, Spotify, OutlookPWA, 3DViewer, Advertising, MixedReality, Paint3D, StartExperiencesApp…) + gated Photos/DevHome/YourPhone(+CrossDevice). VCLibs re-provisioned (issue #219 / wsappx CPU-loop fix).
- [IMPLEMENTED] WinSxS/CBS removals (`packages/win-sxs.yml`): `revitool winpackage --install {system-components-removal, telemetry-removal, ai-removal, onedrive-removal, xbox-removal}`; the file's comment states the AME `!systemPackage` action is "now deprecated and not recommended by Revision, as it is one of the main cause of #49". [DOCUMENTED] Release 26.10 claims core-telemetry removal (`Unified-Telemetry-Client`, `SQMApi`) has "Full compatibility, No boot failures or broken dependencies" — developer assertion, not independently verified.
- [IMPLEMENTED] Performance odds and ends: NTFS last-access and 8.3 names disabled via revitool; `.NET NGEN` run (`ngen.ps1`); service grouping set to "recommended" ("Alternative way to group services without breaking services like XboxGipSvc"); Revision power plan applied via revitool (26.04 release: USB3 link power management off; 24.06 release: "Prevent P-Cores parking for hybrid CPUs" — both [DOCUMENTED]/dev claims; the actual logic lives in the revision-tool repo, not inspected).

### F. Rollback / undo support and its limits

- [IMPLEMENTED] `Tasks/revert.yml` is titled "Rollback Tweaks" but is **`onUpgrade: true`** — it runs when upgrading from a previous playbook version to remove outdated changes, not a user-facing undo. It is a self-documented history of past breakage, each with its reason/issue:
  - BBR2 congestion provider → websocket breakage (#27), reverted to `default`;
  - `SvcHostSplitThresholdInKB=3670016` (svchost split threshold) → "Breaks XboxGipSvc" (#34);
  - disabling `bam` → "Breaks Efficiency Mode in Task Manager" (restored to `startup: 1`);
  - `VulnerableDriverBlocklistEnable=0` → "Setting it to 0 breaks THE FINALS" (restored to 1);
  - disabling core Superfetch → breaks `defrag c: -b` (re-enabled via revitool);
  - GameBar `AppCaptureEnabled` deletion → grayed-out recording (#74);
  - background-apps disable → "breaks Xbox Game Bar KGL update" (re-enabled + `*XboxGamingOverlay*` cache clear);
  - `MouseHoverTime` reduction → overlapping unreadable hints (restored to 400 ms);
  - `DisableAutomaticRestartSignOn` → "Fixes slow logon times when account is protected with Windows Hello" (the 26.10 release-note fix);
  - `DisableWindowsConsumerFeatures` → "Breaks 'Your Phone'"; IE policy leftovers; `RestrictCommunication`; `DisableRootAutoUpdate` ("Needed for MS Store to work"); Defender signature-update policy keys partially deleted/kept.
- [DOCUMENTED] **Official uninstall path** (revi.cc/docs/playbook/uninstall, requires ReviOS 25.10+): turn off update-pausing in Revision Tool, then `revitool winpackage --uninstall {system-components-removal, telemetry-removal, defender-removal, ai-removal, onedrive-removal, xbox-removal}` ("Command errors are safe to ignore"), restart, then **Settings → Recovery → "Fix problems using Windows Update → Reinstall now"** — i.e. component-level undo plus an in-place OS reinstall to restore components. **Limits**: this uninstalls the CBS packages and the update pause; the registry tweaks, service startup changes, hosts file, BCD edits (`bootmenupolicy Legacy`, `lastknowngood yes`, branding description), disabled scheduled tasks, IFEO debugger entries, `maxpwage:unlimited`, disabled event logs and settings-UI changes are **not** covered by the documented uninstall.
- [IMPLEMENTED] The `playbook.conf` declares `UpgradableFrom: any`, and AME Wizard itself is the transactional layer for playbook actions (its per-action backup behavior is AME Wizard's, not auditable in this repo — see limitations).
- [IMPLEMENTED] Re-enables Defender only if chosen (`enable-defender`), after having force-disabled it during deployment (section C).

### G. Known compatibility issues (issues + release notes)

- [COMMUNITY-CLAIM] Open issues at access date: **#228 SMB 1.0 stops working** (9 comments); **#222 VBS/Core Isolation not disabled** on Secured-core PCs (silent no-op); **#231 Drag and Drop not working**; **#245 Old search UI**; **#239 performance problems with the latest playbook** (filed in Chinese); **#229 blank OneDrive icon in Quick Access after removal**.
- [DOCUMENTED] Release-note history of breakage-and-fix: 23.12 "Windows Updates incompatibility issues — #49" (the deprecated `!systemPackage` removal made WU unable to reinstall packages and broke updates; CAB approach adopted "so Windows Updates won't be able to reinstall system packages after updating anymore"); 24.12 "Fixed issue with Brave not updating"; 26.10 fixed slow Windows Hello logons, the `wsappx` infinite CPU loop (VCLibs re-provision), and "Incorrect updates policy values/comments".
- [DOCUMENTED] Docs-level cautions: install page — "Do not run the Playbook on third-party modified Windows ISOs. This causes boot and dependency failures"; Smart App Control must be manually turned off or AME Wizard fails with "Could not load file or assembly WmiLight"; ISO page — "ISO injection is an experimental feature of AME Wizard Beta. Always test generated media."
- [COMMUNITY-CLAIM] Issue #184 (`condrv` fix in services.yml) and #167 (ROG Ally sleep breakage comment in FINALIZE.cmd) are in-code references to user-reported hardware breakage fixed by the playbook itself.

### H. Evidence vs assertion, and reputation

- [IMPLEMENTED/observation] Comments in ReviOS YAML frequently cite sources, but the source quality is mixed: Microsoft Learn/admx.help for policies, but also tenforums/howtogeek/windowslatest blog posts and winaero-style community knowledge; performance claims (TSX "4~5× faster", VBS "improves gaming performance", "Full compatibility, No boot failures") are developer assertions — **no independently reproduced benchmarks exist in anything fetched**.
- [COMMUNITY-CLAIM] Reputation per the tracker: small issue count (6 open), but recurring themes are service-disable fallout (SMB1), silent no-op security toggles on locked firmware (VBS), and upgrade/install robustness (StateRepository-style issues on the Atlas side; WU breakage #49 historically on the ReviOS side). The project's own revert.yml is the strongest stability evidence: it enumerates seven+ past tweaks that broke real software and were withdrawn.

## 2.3 Useful ideas for NEXTRIX (ReviOS shortlist)

1. **Option-gated task files** with a single declarative format (AME Wizard YAML `option:`/`!negation`) — cheap way to make every aggressive change opt-out-able and auditable in one place.
2. **`onUpgrade: true` revert task** — a dedicated "remove our own outdated tweaks" pass on upgrade, with each revert annotated by the bug/issue that motivated it. NEXTRIX should adopt the *pattern* (a first-class deprecation ledger), not the specific content.
3. **Component-level uninstall procedure** (`winpackage --uninstall ...` + Windows Update "Reinstall now") as the documented recovery path — a realistic model for NEXTRIX's rollback story *for component removals*.
4. **Known-issues page per risky delivery mode** (ISO injection) with concrete `reg delete` workarounds — honest failure documentation.
5. **CI date-based versioning (YY.MM) + SHA256 of the artifact and of every bundled tool printed in the release body**, with CI verifying the bundled tool's hash against its upstream release digest.
6. **Micro-patch channel** (`revitool tweaks patches`) so minor fixes ship without a full playbook release — reduces the pressure to ship risky monolithic updates.
7. Splitting *policy-style* changes (registry `!registryValue` lists, reviewable in one place) from *engine* changes (a separate tool) — good separation of concerns for NEXTRIX's "playbook vs runtime" boundary.
8. Per-choice description strings that name the downside in the installer UI ("⚠️ Disabling may overheat laptops in sleep mode") — cheap, effective risk communication.
9. Their hard-won negative results are NEXTRIX data: the revert.yml list (SvcHostSplitThresholdInKB, bam, Superfetch, background-apps vs GameBar KGL, disabledynamictick vs ROG Ally sleep, BBR2, MouseHoverTime, VulnerableDriverBlocklistEnable) is a ready-made **"tweaks known to break real software"** catalog to encode as NEXTRIX anti-patterns/tests.

## 2.4 Reject / caution (ReviOS)

1. **Defender force-disabled during every deployment + default-disable choice** — the force-off is a deployment workaround (issue #243), but making `disable-defender` the default radio is a security-posture decision NEXTRIX must not copy.
2. **Unconditional VBS/HVCI disable** — silently no-ops on Secured-core machines (issue #222); NEXTRIX must detect UEFI locks and *report*, never claim success.
3. **Unconditional BitLocker device-encryption prevention** (`PreventDeviceEncryption=1`) — disables a data-protection default for a performance product; out of scope and risky.
4. **IFEO `Debugger=taskkill.exe` hijack technique** — kills system binaries at launch; brittle across builds, defeats MS servicing assumptions, and touches `AggregatorHost`/`CompatTelRunner` whose absence has second-order effects. A known abuse pattern.
5. **hosts-file blocking incl. Brave/VS endpoints** — unverifiable blocklist, breaks download pages (their own comment), survives "uninstall", defeats endpoints other features may need.
6. **Windows Updates paused to 2038 by default** — the machine stops receiving security fixes silently; the single most dangerous default in either project.
7. **`tcpipreg` disable marked "experimental"** in their own file; **`lsass.exe` priority 1** and `Win32PrioritySeparation=38` — speculative, compat-risky.
8. **chkdsk auto-check disabled** (`autocheck autochk /k:C*`) — data-integrity loss for boot-time fixup.
9. **Intel TSX enable** — re-exposes TAA-class vulnerabilities; the perf claim is a [DEV-BENCHMARK] from their own issue tracker.
10. **ISO-mode `DisableHardwareRequirements` + LabConfig bypasses + `DisableCAD` (Ctrl+Alt+Del off)** — requirement-bypass and logon-security tampering outside a performance playbook's remit; ReviOS itself labels ISO injection experimental.
11. **`net accounts /maxpwage:unlimited`, `ShutdownWithoutLogon=1`** — security-policy changes smuggled into an optimization flow.
12. **UCPD + UCPD-velocity disable** — removes default-app protection that Microsoft documents and Atlas deliberately preserves; directly contradicted by the SMB1 fallout pattern.
13. Distribution via **modsfire third-party link** instead of GitHub assets — supply-chain caution for anyone consuming their artifact (SHA256 is at least published).

## 2.5 Research limitations (ReviOS)

- The compiled `Revi-PB-26.10.apbx` on modsfire was **not downloaded** (third-party host; read-only research scope). All source findings come from `main` @ tree `c9cdbd1...`; the shipped artifact could differ from the tree.
- **Revision Tool (`revitool.exe`) internals were not inspected** (separate repo meetrevision/revision-tool, binary releases). All `revitool`-invoked logic — Defender disable, VBS/HVCI disable, update-pause-to-2038, power plan, TSX, NTFS, service-grouping, driver-update disable, `tweaks patches` — is verified only as *invoked* by the playbook, not as implemented. Those internals are tagged accordingly.
- The `meetrevision/packages` repo (CBS package contents for system/telemetry/defender/ai/onedrive/xbox removals) was not inspected; component lists for ReviOS are therefore **not** enumerated the way Atlas's sxsc YAMLs are.
- AME Wizard's **minimum version is not stated in the repo**; docs link generically to ameliorated.io (install) and AME Wizard Beta (ISO), and release 24.12 references "AME Wizard's 2024-06-12 changes" — the dependency is dated, not pinned; AME Wizard's own registry-backup/undo behavior was not audited (closed-source third-party).
- Registry task files fetched selectively: `explorer/win-settings.yml` (31 KB), `control-panel.yml` (11 KB), `privacy/privacy.yml` (12.8 KB), `classic-photo-viewer.yml` (13 KB), `oobe.yml`, `logon.yml`, `multimedia.yml`, `ms-store.yml`, `deprovisioned-apps.yml`, `packages/app-win32.yml`, `Executables/EDGE.ps1`, `CLEANER.ps1`, `DISM-FEATURES.ps1` were **not fetched** — registry specifics for Explorer/Settings-UI/OOBE areas are not recorded here (tree-verified only). `multimedia.yml` was attempted in a batch but not returned; its contents remain unread.
- No ReviOS claims were executed or benchmarked; no `VERIFIED` tags. Issue #222's resolution status beyond the maintainer comment was not traced.
- GitHub unauthenticated API rate-limited mid-session; remaining issue/release queries were completed through an authenticated GitHub MCP client.

---

## Cross-project synthesis for NEXTRIX (one paragraph, decision-oriented)

Both projects converged on the same architectural lesson NEXTRIX should internalize: **state must be recorded and replayable, and the most dangerous operations are component removals**. Atlas (GPL-3.0) now treats services near-untouchable, gates every aggressive change behind an explicit user choice, backs up service Start values before touching them, refuses changes it cannot roll back exactly (its power policy is the model), and requires disposable-VM evidence per build before shipping a startup change — but still defaults to disabling automatic updates and always disables Smart App Control/Enhanced Phishing/Find-my-device. ReviOS (CC-BY-SA-4.0) remains a fire-and-forget playbook: unconditional VBS/BitLocker/chkdsk/MOTW-adjacent changes, hosts-file blocking, IFEO debugger hijacks, updates paused to 2038 by default, and its own revert.yml is a public ledger of at least nine tweaks that broke real software (Xbox services, Task Manager, THE FINALS, GameBar, ROG Ally sleep, Hello logons, websockets, defrag, Your Phone) — while its official uninstall only reverses component packages plus the update pause. Neither project publishes independently reproduced performance numbers; every performance claim found is developer-asserted. For a hardware-aware, rollback-safe playbook, Atlas's *engineering process* (build guards, VM gate, state machine, honest consequence docs) is the transferable asset; ReviOS's *negative-results ledger* is the transferable data; the aggressive defaults of both are the cautionary tale.

Access date: 2026-11-23. Researcher: NEXTRIX subagent R2.
