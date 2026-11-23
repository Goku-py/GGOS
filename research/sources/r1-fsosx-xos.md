# NEXTRIX Phase 1 — Reference-Project Research Notes (Subagent R1)

Scope: READ-ONLY web research into three reference projects for NEXTRIX (hardware-aware, modular,
rollback-safe Windows optimization playbook). NX18 (Game Session Manager) is inspired by FSOS-X
"Competitive Mode"; NX19 (CPU topology/scheduling) is inspired by XOS. No Windows settings were
modified, no tweak or script executed on the host; only public web pages were fetched and these
notes were written.

Evidence tags used throughout (exactly one per finding):
- **IMPLEMENTED** — verified in source actually read (file path / raw URL cited).
- **DOCUMENTED** — official site/readme/release-note claim, not verified in source.
- **COMMUNITY-CLAIM** — third-party statement.
- **DEV-BENCHMARK** — developer-reported performance numbers or test outcomes.
- **VERIFIED** — independently verified performance results (none exist in this research).

---

## 1. FSOS-X (FrameSync)

### 1.1 Identity

| Field | Value | Evidence |
|---|---|---|
| Name / vendor | FSOS-X, by FrameSync / FrameSync Labs | DOCUMENTED (fsosx.com) |
| Product type | Windows 10/11 modification (debloat + gaming + privacy) distributed as an AME Wizard playbook (`.apbx`), plus a companion desktop app "FSOS-X Dash" | DOCUMENTED (fsosx.com) |
| Latest version | R11H2, dated September 4, 2026 (previous: R11H1 Sep 2, 2026) | DOCUMENTED (site changelog) |
| Download | `FSOS-XR11H2.apbx`, 416.1 MB, SHA-256 `75d0e6a716f722d452d7ed9b9d403c9b9ef20207f35a84ada4213e043fc62741` | DOCUMENTED (site download block) |
| License | "Polyform · Non-Commercial · Source Available" — "Source available" means the `.apbx` archive can be opened with any ZIP tool using the AME default password `malte`. **No public repository is linked anywhere on the site.** | DOCUMENTED (fsosx.com) |
| Pricing | Free; donations via ko-fi.com/framesync; commercial "pro-level optimization" service sold separately at framesynclabs.com | DOCUMENTED (fsosx.com) |
| Dependencies | AME Wizard (linked: `https://download.ameliorated.io/AME Beta.zip`); optional autounattend.xml; stock Windows 10/11 ISO | DOCUMENTED (fsosx.com install guide) |
| Community | Discord (`discord.gg/FSL`), YouTube `@FrameSyncLabs`, X `@framesynclabs` | DOCUMENTED (site footer) |
| Claimed traction | "300,000+ Downloads" | DEV-BENCHMARK (developer-claimed, unverifiable) |

URLs actually inspected: `https://fsosx.com/` (full landing page incl. install guide, known-issues, changelog R3→R11H2, FAQ).

### 1.2 Findings by area

**Product structure** — DOCUMENTED
- Two components: (a) the playbook applied via AME Wizard (10–15 min, applied on top of an
  existing stock Windows; no reinstall required, though fresh install recommended), and (b)
  "FSOS-X Dash", a native desktop toolkit bundled with the playbook for post-install management
  (initial release: R6, May 23, 2026).
- Dash advertised capabilities: Competitive Mode + game profiles, "hundreds of system tweaks",
  shader-cache cleaner with scheduling, 67-app installer across 12 categories, 20+ power plans,
  network & security toggles, live system status, app reinstaller, Services page, Favorites,
  "Recent Changes" page (history of last 50 changes with timestamps), Uninstaller page with
  "deep clean", "Export PC Specs" (text file with full specs + latest install log), Downloads
  page with search, browser installs (Chrome→replaced by Thorium in R9; LibreWolf, Brave,
  Vivaldi, Helium), NVIDIA `.nip` profile.
- Bundles VCRedist + DirectX runtimes pre-install.
- Disclaimer: "FSOS-X optimizes ~80% of your operating system (Windows). It doesn't directly
  affect firmware (BIOS) or hardware components (CPU, GPU, RAM)." (DOCUMENTED)

**Performance claims** — DEV-BENCHMARK (developer-reported; not independently verified; no VERIFIED results exist)
- 55–65 base processes ("process count cut in half"); idle RAM 1.2–2.3 GB ("up to 52% less");
  17 GB install footprint ("3X lighter"); zero preinstalled bloat.
- Competitive Mode "Disable Windows Search" claims ~100–200 MB RAM saved (R11 changelog);
  "Reduce Steam Resource Usage" (closing Steam's web helper during play) claims ~600 MB saved
  (R9 changelog, credits Aetopia and @nobbybo11ocks).

**Competitive Mode — how it is described to work (detect → apply temporary config → restore)** — DOCUMENTED (every item below is a site/changelog claim; no source was available to verify)
- *Detect*: game scanning with a scan cache for slow drives (R10H1); launcher-chain detection —
  Dash opens Epic Games / Battle.net / Riot Client itself before launching (R9); BattlEye games
  detection fixed (R8); Riot Client found on drives other than C/D/E (R11); waits up to 10 minutes
  for slow-launching games and shows "Waiting for game to launch..." (R9); waits for games with a
  pending update instead of reporting failure (R9); launcher games (Fortnite, COD) shortcut launch
  fixed (R9); game launchers excluded from Competitive Mode (R6.2); "Rescan Games" (R6.3);
  favorite games pinned to top of list (R11); manually-added Riot games launch through the Riot
  Client like detected ones (R11).
- *Apply (temporary, per-session)*: pause non-essential services while gaming (9 extra services
  added in R11); stop the Windows search process + search indexer during the session (added R11);
  CPU Sets restricted to "Performant Cores" (list of cores used shown next to the label, R11);
  GPU Priority control in the Active Session panel (dropdown; "Real-time" and "below Normal"
  options removed in R10; CPU/GPU/I/O priorities default to Normal since R10 — was High before);
  power plan auto-switching: user selects a Gaming plan and a Standard plan, switched automatically
  when a game starts/ends (R8); "Reduce Steam Resource Usage" closes Steam's web helper during
  play (R9); "Game Focus" throttling (fixed in R11 so it no longer throttles OBS, ShadowPlay,
  Medal — i.e., capture software excluded); desktop game shortcuts embedding saved Competitive
  Mode settings (R6.4); anti-cheat blocking reported: "Competitive Mode now reports when an
  anti-cheat blocks the CPU Sets or GPU Priority it applied" (R11).
- *Performant Cores selection heuristic (vendor-described, R9)*: picks the X3D/CCD0 die on
  dual-CCD AMD instead of the higher-clocked one; on Intel drops E-cores, drops all SMT/HT
  threads and excludes core 0; if fewer than six cores would be left, it leaves SMT and core 0
  alone so small CPUs are "not stripped bare"; improved topology and E-core detection for
  Arrow Lake / Meteor Lake; cores grouped and labelled per-CCD in Competitive Mode for dual-CCD
  chips; separate "Disable CCD1" button (fixed in R9).
- *Restore (on exit)*: paused services restarted (and since R11 a service that failed to pause is
  no longer restarted at session end — pause success is verified before restore); search process
  and indexer restored when the game exits; power plan switched back to Standard; Steam web
  helper returns after the game closes (bug where it never returned fixed in R11).
- *Guard-rails*: cooldown with on-screen countdown on the Start button so Competitive Mode can't
  be spam-launched (R8 — added after repeated rapid starts triggered anti-cheat false positives);
  warning when launching with UAC disabled (FiveM refuses to start; one-click UAC re-enable, R8);
  UAC notice with "Don't Show Again" (R11); warning when Process Lasso is running to avoid
  conflicts (R9); warning when the selected game is already running (R7); Competitive Mode can
  apply tweaks while a game is already running (R7); "Close Dash After Game Launch" option.

**Versioning / release cadence** — DOCUMENTED
- Scheme: R<number>[H1/H2 hotfix]. Releases found in changelog: R3 EA (2026-04-26), R4 EA
  (2026-05-03), R6 (2026-05-08), R6 Stable (2026-05-23), R6.1 (06-03), R6.2 (06-07), R6.3
  (06-09), R6.4 (06-17), R7 (07-02), R8 (07-13), R9 (07-28), R10 (08-22), R10H1 (08-24), R11
  (09-02), R11H1 (09-02), R11H2 (09-04). Very high cadence (multi-release weeks, same-day
  hotfixes). Update notification bell in Dash with one-click download + changelog link (R7).

**Supported Windows versions** — DOCUMENTED (no build-guard code was inspectable)
- Hero claim: "officially supports Windows 10 & 11 versions 21H2 to 26H2, including LTSC."
- Download block (more specific): "Windows 10 21H2–22H2 · Windows 11 23H2–26H2".
- History: 23H2 support removed in R6.1 "due to ongoing issues", reintroduced experimental in R9;
  Win10 21H2 added experimental in R10, 22H2 in R9; LTSC added in R11.
- Install guide: stock Windows 11 (preferably 25H2) recommended as base; Win10 21H2/22H2 (incl.
  LTSC editions) if the PC cannot run Windows 11. FAQ: "We recommend Windows 11 25H2 Home."
- Fresh-install requirement: "stock Windows 10 or 11 installed in the past 40 hours" (FAQ; R3
  added the 40-hour check); "anti-custom-OS stacking detection" (R3); "Application on top of other
  custom OS is not advised."
- Minor internal inconsistency: hero (21H2–26H2) vs download block (Win11 starts at 23H2) —
  treat the download block as authoritative.

**Rollback / undo mechanisms and their limits** — DOCUMENTED
- Dash is the undo surface: individual toggles, a Restoration page (incl. Gaming Services to fix
  Game Pass titles, Phone Link restoration), an Uninstaller/ deep-clean page, and re-install of
  removed apps via the Downloads page. "Recent Changes" (R11H2) gives an audit trail of the last
  50 changes for troubleshooting.
- Upgrade behavior: upgrades no longer re-add desktop shortcuts (R11H2), no longer re-apply saved
  settings silently after an update — Dash shows a diff and lets the user pick what to restore or
  keep (R10); Dash asks before putting back a setting changed outside of it (R10); protection of
  user settings against Windows resetting them (R10H1).
- Limits (explicit or implied): uninstall/restore is per-tweak from Dash; no claim of restoring
  the *pre-FSOS-X* configuration exists anywhere on the site; removed Store apps must be
  reinstalled; a fresh Windows reinstall is the stated recovery path of last resort; FAQ
  explicitly targets a fresh-install audience ("backup your files first").
- Dash bug history relevant to rollback safety: "Fixed certain Dash toggles deleting registry
  values instead of restoring Windows defaults" (R10); "Fixed certain Dash toggles that used to
  revert themselves after restart" (R10); toggles with wrong state reading (Mouse Throttling
  swapped, R11H2; Power Saving/UAC partial-state reporting, R9/R10).

**Known compatibility issues** — DOCUMENTED (release notes; "known issues" page)
- R11H2 states: "No known issues." Historically fixed issues (evidence the project hit them):
  stutters/crashes/sluggish gameplay for a small number of users (R11H2); Win10 Settings search
  breaking when "Disable WebView2" ticked (fix needs fresh install, R11H2); "digital signature
  could not be verified" recovery screen after removing Windows Defender (R11H1); leftover
  Defender files/driver files/Security Center folder not removed (R11H1); Android emulators, WSL
  and VMs reporting virtualization disabled after playbook (R11); "ms-gamebar" popup after Xbox
  removal when connecting a controller (R11); GPU Priority changeable on integrated graphics
  breaking the in-game mouse (R11); audio issues with COD and other games (R11H1); CS2 mouse
  desync after Alt-Tab on stretched resolution (R10); Minecraft Bedrock stutter (R10); MPO
  disabling caused "desktop composition is disabled" errors and game crashes (R8) and the MPO
  toggle was pulled in R10 "due to multiple users reporting issues" before returning in R11 with
  automatic MPO-disabling for AMD-dGPU PCs and an automatic TDR fix; COD TPM attestation issues
  "TBC" (R9); screen share/recording broken in Discord/OBS (R10); installation hangs of many
  kinds across R3–R10; rare BSODs for a small number of users (R7); anti-cheat false positives
  from spam-launching Competitive Mode (R8) and "rare game anticheat false-positive detections"
  (R7); FiveM elevated-privileges/UAC errors (R7/R8); AV false positives when disabling
  CrossDeviceResume (R7); BitLocker: detection added that stops the install if BitLocker/Device
  Encryption is enabled, "preventing recovery lockouts" (R8); upgrades once deleted OneDrive
  files (R7, "critical bug"); mice/keyboards allowed to sleep leaving them unresponsive (R10);
  mice/USB unreliable in some cases (R10H1); fast startup not disabled correctly (R6.4);
  Control Flow Guard re-enabling on upgrade (R6.4).

**Safety-relevant behavior** — DOCUMENTED
- Windows Defender: optional full removal ("tool-less Defender removal method", R6 May 8) with a
  Defender cleanup task; repeated fixes show removal completeness was a recurring problem
  (R11/R11H1). Users choosing to remove it get AV false-positive fixes as release items.
- Security mitigations: "CPU Mitigations" toggle plus "Other Security Mitigations" toggle
  (R11H2), on by default unless disabled; FAQ: "Should I disable security mitigations? If you
  play Faceit or are a high rank in Valorant, no." Install-guide warning: CS2 Faceit and Valorant
  players must NOT disable security mitigations "as it's required for the game anti-cheats to
  function properly."
- UAC: playbook option + Dash Security-page toggle; UAC-disabled state blocks FiveM (warned).
- Virtualization: "Remove Hyper-V and Virtualization" became an opt-in choice in R11 (the stack
  is only removed if chosen); Hyper-V re-enable toggle in Dash since R7.
- Firewall: "Removed 9 broken Windows Firewall rules" (R6 May 8) — described as broken rules,
  not a firewall disable; network toggles "target only your main/current NIC" (R10H1).
- BitLocker/Device Encryption detection stops install (R8) — a genuinely safety-positive gate.
- Scheduled tasks/optional features: "removal of unnecessary optional Windows features and
  scheduled tasks" (R11); "Fixed 12 scheduled tasks not being disabled properly" (R11).
- Other safety-relevant Dash toggles documented: Mouse Throttling, Timer resolution ("Adjusted
  the timer resolution toggle in Dash to correctly handle everything, not just global timer
  resolution requests", R11), Foreground App Boost (= Win32PrioritySeparation named options with
  a confirmation dialog "explaining the downsides", R9), Win32PrioritySeparation values (R9),
  CTFMon toggle, Search Indexing toggle, MPO toggle, "Optimizations for Windowed Games", VRR,
  hibernation/"Sleep in start menu" restore.
- "FSOS-X is now verified by the AME team" (R7) — third-party-ish verification of the playbook
  packaging by the AME Wizard team; still DOCUMENTED from the vendor site, not independently
  confirmed.

**CPU/GPU/hardware-specific logic** — DOCUMENTED (vendor-described)
- AMD: dual-CCD chips get per-CCD core grouping and labelling (R9); "Performant Cores" prefers
  the X3D/CCD0 die (R9); "Disable CCD1" button; automatic MPO disable and automatic TDR fix
  (`TdrDelay`-style behavior implied) for dedicated-AMD-GPU PCs (R11).
- Intel: E-core dropping, SMT dropping, core-0 exclusion with the "fewer than six cores" guard
  (R9); Arrow Lake / Meteor Lake topology detection improvements (R9).
- Monitors: automatic setting of every monitor to its highest supported refresh rate (R11).
- GPU: GPU Priority limited to non-Real-time options (R10), not offered on integrated graphics
  (R11 fix); VRR status detection (R7); iGPU/dGPU detection fixes (R6.4).

### 1.3 Useful ideas for NEXTRIX (NX18 shortlist)

1. **Session lifecycle as first-class object** (detect → apply → restore) with explicit
   restoration of only what was successfully applied — FSOS-X's R11 fix ("a paused service being
   restarted at the end of a session even when it had failed to pause") is a concrete lesson:
   verify each apply step, and restore only verified steps.
2. **Anti-cheat-aware session manager**: report when an anti-cheat blocks CPU Sets/GPU Priority;
   default priorities to Normal (not High); keep Real-time unavailable; cooldown on session start
   to prevent spam-launch false positives; explicit guidance that competitive titles
   (Valorant/FACEIT/CS2) need mitigations/VBS left on.
3. **Launcher-chain detection**: open/attach to Epic/Battle.net/Riot, wait for pending updates,
   long startup waits (10 min) with live "waiting" status, exclude launchers themselves from
   tweaks, per-game favorites and desktop shortcuts embedding the profile.
4. **Gaming vs Standard power-plan pair** switched automatically at session start/end (R8) —
   cleaner than a single plan because the restore target is explicit.
5. **"Recent Changes" audit trail** (last 50 changes with timestamps) — cheap, high-value for
   troubleshooting and for NEXTRIX's rollback-safety story.
6. **Support bundle**: one-click "Export PC specs + latest install log" to Desktop.
7. **Hardware gates before risky actions**: BitLocker/Device-Encryption detection that *stops*
   the install; iGPU detection that hides GPU-priority controls; chassis/battery-aware toggles
   (their laptop/desktop differentiation is implied by the dual-boot/multi-tasker note).
8. **Per-CCD core selection UI**: show the actual core list chosen ("list of cores used shown
   next to Performant Cores") — transparency beats silent heuristics.
9. **Don't throttle capture/OBS-class processes** when applying "game focus" — explicit
   exclusion list learned from their R11 bug.
10. **Upgrade hygiene**: never silently re-apply saved settings after an update; diff-and-choose
    UI; never re-add shortcuts; only-on-fresh-install side effects.

### 1.4 Reject / caution (with reasons)

- **All performance numbers (55–65 processes, 1.2–2.3 GB RAM, 17 GB, "300k downloads")** —
  DEV-BENCHMARK only; no methodology, no source; do not cite in NEXTRIX as evidence.
- **License/derivation**: Polyform Non-Commercial — even though the archive is inspectable with
  password `malte`, NEXTRIX must not copy FSOS-X content (also commercial use prohibited).
- **Defender removal as a headline feature** — their own changelog shows a trail of removal
  failures, a boot-recovery-screen bug, and AV false positives; NEXTRIX should treat Defender
  removal as out-of-scope or as an explicitly-gated, high-risk module with a verified restore.
- **Security-mitigation disabling offered to gamers** — creates direct conflict with
  anti-cheat requirements (their own FAQ has to talk users out of it). If NEXTRIX offers
  mitigation control at all, it should default to safe and hard-block when competitive
  anti-cheats are detected.
- **MPO disable as a general toggle** — their own history (pulled in R10 "due to multiple users
  reporting issues", composition-disabled errors in R8) shows it is machine-dependent; treat as
  per-GPU-vendor, opt-in, documented-risk only.
- **"No known issues" as a QA claim** — marketing statement; the long fixed-issue history
  contradicts a blanket safety narrative.
- **Fresh-install-40-hours + no-stacking policy** — legitimate vendor choice, but NEXTRIX's
  stated goal (apply safely to existing systems, rollback-safe) is a different (and harder)
  contract; do not inherit FSOS-X's "reinstall Windows" recovery assumption.

### 1.5 Research limitations (FSOS-X)

- Closed-source product: no public repository exists or is linked; the "source" is a
  password-protected 416 MB commercial archive. Per the read-only rules of this subtask, the
  archive was NOT downloaded, extracted or inspected. Therefore **zero FSOS-X findings are
  IMPLEMENTED**; every feature/number is DOCUMENTED or DEV-BENCHMARK.
- No third-party/community coverage could be gathered (see §5 Global limitations), so no
  COMMUNITY-CLAIM evidence exists for FSOS-X either; Discord/YouTube channels were not joined
  (would require account interaction; out of scope).
- Registry paths, service names and scheduled tasks for FSOS-X are therefore NOT observable;
  only feature-level descriptions from the changelog could be recorded.
- The "verified by the AME team" claim (R7) could not be independently confirmed.

---

## 2. XOS Playbook (imribiy/xos-playbook)

### 2.1 Identity

| Field | Value | Evidence |
|---|---|---|
| Name / owner | XOS Playbook, by imribiy | IMPLEMENTED (repo + API) |
| Repo | `https://github.com/imribiy/xos-playbook` (public, default branch `main`, 21 commits, language PowerShell, created 2026-10-25, last push 2026-11-22; hub repo `imribiy/XOS` (installation guide/FAQ/branding) dates to 2023-08-07 with 88 stars — the project predates the split repos) | IMPLEMENTED (GitHub API) |
| Latest stable release | **XOS V0.777** — tag `xos-v0.777`, published 2026-11-14, asset `XOS.V0.777.apbx` (9,438,532 bytes; SHA-256 `3D65DD63CFE8736CE409BE2F5E979F21386F38F0DBE3793A4C7B4B0F0DDE6F2E`; 938 downloads). "Last public release with the original C# XOS Toolkit (Toolkit 0.2.178). This release's source is not in the repository; the repository holds the current source." | DOCUMENTED (release notes) — note the release/repo divergence below |
| Repo source version | `playbook.conf` in `main` says **v0.812** (`<Version>0.812</Version>`, Title "XOS Playbook v0.812"), i.e. the repo is AHEAD of the latest stable release; dev betas up to V0.818 live in `imribiy/xos-beta` | IMPLEMENTED (`playbook.conf`, raw URL) |
| License | **CC BY-NC-ND 4.0** (LICENSE fetched in full: "you may share this work unchanged, with credit, for non-commercial purposes only... may not sell it, use it commercially, or distribute modified or rebranded versions." GitHub API reports `Other/NOASSERTION` because CC licenses are not OSI.) | IMPLEMENTED (LICENSE file) |
| Dependencies | AME Wizard — "XOS is tested on Beta 0.8.4"; `XSudo.exe` (Rust TrustedInstaller elevation helper, source in xos-toolkit `XSudo/`); `DefenderOFF.ps1` "based on LeanAndMean by AveYo (MIT)"; bundled in releases: MinSudo (NanaRun, MIT), Nvidia Profile Inspector (Orbmu2k, MIT), Chocolatey (Apache 2.0), Open-Shell Fluent-Metro skins | DOCUMENTED (README + release notes) |
| Packaging | Zip repo contents (minus `.git`, `.gitignore`, README, LICENSE) with password `malte` (AME default) into `XOS V<version>.apbx`; `XOS-Toolkit-Setup.exe` must be added to `Executables/` before packing (not in repo) | DOCUMENTED (README build section) |
| Issue tracker | 0 open; 3 closed — all filed by the owner: two "test" issues and one "Real hardware test on W11 25H2" (Toolkit 0.6.1, build 26200.9974, "No bugs detected on my end" + diagnostic bundle) | DOCUMENTED (issues API; owner-filed) |

URLs actually inspected: repo page, `api.github.com/repos/imribiy/xos-playbook` (+ `/releases/latest`, `/contents/Configuration`, `/contents/Executables`, closed `/issues`), raw `LICENSE`, `playbook.conf`, `Configuration/custom.yml` (1,745 lines, ~171 KB — majority read), `Executables/detect-windows-build.ps1`, `Executables/StockValueCapture.ps1`, `Executables/laptop-desktop.bat`, `Executables/ApplyPowerPlan.bat`, `Executables/DisableScheduledTasks.ps1`, `Executables/network.bat`, plus hub repo `imribiy/XOS` metadata + README.

### 2.2 Findings by area

**Repository structure** — IMPLEMENTED
```
.github/ISSUE_TEMPLATE/   Configuration/custom.yml   Executables/ (25 helper files + XSudo.exe + Windows/ dir)
playbook.conf  playbook.png  README.md  LICENSE  .gitignore
```
`Configuration/custom.yml` is "every action the playbook runs" (README claim confirmed: a single
1,745-line AME-Wizard YAML action list, grouped into ~58 `writeStatus` sections). Helper scripts
in `Executables/`: ApplyPowerPlan.bat, DefenderOFF.ps1 (14,789 B), DefenderRunBackup.ps1,
DeviceStateBackup.ps1, DisableScheduledTasks.ps1 (14,268 B), EventChannelBackup.ps1,
InstallDiagnostics.ps1 (Start/Finish phases), OptionalFeatures.ps1, PCHealthCheck.ps1,
RemoveAppx.ps1, RemoveEdge.ps1 (31,173 B), RemoveEdgeStartup.ps1, SetWallpaper.ps1,
StockValueCapture.ps1 (13,313 B), TakeOwnership.reg, UPDHEALTH.bat, W10STARTMENU.ps1,
W11STARTMENU.ps1, WebView2State.ps1, WidgetsPolicy.ps1, detect-windows-build.ps1 (15,898 B),
feeds-home.bat, laptop-desktop.bat (17,351 B), network.bat, onedrive.bat, taskbar.bat, XSudo.exe
(401,408 B, binary in repo).

**Windows build compatibility approach** — IMPLEMENTED
1. Hard guard in `playbook.conf`: `<SupportedBuilds>19045, 22631, 26200, 26300</SupportedBuilds>`
   (Win10 22H2, Win11 23H2, 25H2, 26H2) — AME Wizard refuses other builds (README: "including
   older Windows 10 releases, Windows 11 24H2 and the device-only Windows 11 26H1, is refused").
   Also `<Requirements>DefenderToggled, NoAntivirus</Requirements>`, `<Overhaul>false</Overhaul>`,
   `<UseKernelDriver>false</UseKernelDriver>`, `<UpgradableFrom>any</UpgradableFrom>`.
2. Runtime guards inside scripts: `CurrentBuildNumber -ge 19041` gates HAGS (`HwSchMode=2`);
   `-ge 22000` selects the Win11 branch; nested `-ge 22631` gates Taskbar End Task; `-ge 18362`
   gates VRR on the Win10 branch; `EditionID -like 'Core*'` + build `< 22000` gates the
   Win10-Home "News and Interests" logon-script fallback (all in `detect-windows-build.ps1` and
   `custom.yml`).
3. Server-edition detection: six registry values under
   `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` checked for the string "server"
   (CompositionEditionID, EditionID, InstallationType, ProductName, SoftwareType, System); the
   server branch disables ServerManager task, MSDTC, removes Azure Arc Setup.
4. Existence checks before mutation throughout: service changes are preceded by a `Type` value
   check (`if ($null -eq (Get-ItemProperty ... -Name 'Type')) { continue }`), so tweaks skip
   cleanly on builds that lack the service.
5. `ProgressText` honestly warns: "this playbook tries to aim wide range of Windows versions,
   some errors may occur."
6. `TargetReleaseVersionInfo` is pinned to the machine's current `DisplayVersion` (custom.yml
   "Optimizing Scheduled Tasks" section) — prevents feature-upgrade drift while updates are off.

**Windows version support (from code, not claims)** — IMPLEMENTED: exactly 19045 / 22631 / 26200
/ 26300. DOCUMENTED caveat: "Use the Pro edition if you can: on Home, Windows ignores the policy
XOS uses to turn off automatic updates."

**Options model (playbook.conf)** — IMPLEMENTED
- Radio pages: Defender `disable-defender` (default) vs `enable-defender`; UAC `enable-uac`
  (default) vs `disable-uac` ("may break Microsoft login"); Edge `remove-edge` (default; removes
  Edge + shared WebView2, reinstallable from Toolkit) vs `keep-edge`; wallpaper `change-wallpaper`
  (default); printing `disable-printing` (default — disables Print Spooler, related services,
  scheduled tasks and printing Windows features) vs keep.
- Checkboxes (first page, checked by default): cleanup-taskbar, remove-onedrive, remove-teams,
  remove-wsl. Second page: remove-photos (checked), **remove-xbox (UNCHECKED by default)**,
  remove-ai (Copilot, Recall — checked).

**Registry modifications observed** — IMPLEMENTED (representative, from `Configuration/custom.yml`;
~400 write operations total; each is a discrete `!registryValue`/`!registryKey` action)
- Kernel/memory/scheduler:
  `HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl\Win32PrioritySeparation=38 (REG_DWORD)`;
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\{NoLazyMode=1,
  NetworkThrottlingIndex=10, SystemResponsiveness=10}`; `...\Windows\TimerCoalescing=0`;
  `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power\CoalescingTimerInterval=0`;
  `...\Memory Management\{DisablePageCombining=1, FeatureSettingsOverride=3,
  FeatureSettingsOverrideMask=3}` (Spectre/Meltdown mitigation override);
  `HKLM\SYSTEM\CurrentControlSet\Control\SvcHostSplitThresholdInKB=3670016` (all services in one
  svchost above 3.5 GB RAM) plus `SvcHostSplitDisable=1` on 26 named critical services;
  `...\Session Manager\{SegmentHeap=1, BackgroundLoadKnownDlls=1, BootExecuteNoPnpSync=1,
  TaskhostTimeout=2000}`; `...\Quota System\EnableCpuQuota=0`;
  `...\SCMConfig\EnableSvchostMitigationPolicy=0`;
  `HKLM\SOFTWARE\Policies\Microsoft\Windows\Psched\TimerResolution=10`.
- Defender (option `disable-defender`): `TamperProtection=0` (via XSudo/TrustedInstaller,
  `HKLM\SOFTWARE\Microsoft\Windows Defender\Features`); service `Start=4` writes for WinDefend,
  WdFilter, WdBoot, WdNisDrv, WdNisSvc, MDCoreSvc, Sense, MsSecCore, MsSecWfp, MsSecFlt,
  SgrmBroker, wtd, webthreatdefusersvc, webthreatdefsvc, wscsvc, SecurityHealthService;
  `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\{DisableAntiSpyware=1, DisableAntiVirus=1}`;
  Real-Time Protection `Disable*`=1 suite; WTDS components/feature flags off; SmartScreen:
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SmartScreenEnabled='Off'`,
  `EnableSmartScreen=0`, `ShellSmartScreenLevel='Warn'`, AppHost `Enabled/PreventOverride=0`,
  and an **IFEO hijack**: `HKLM\...\Image File Execution Options\smartscreen.exe \ Debugger =
  %SYSTEMROOT%\System32\taskkill.exe`; `HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy\
  VerifiedAndReputablePolicyState=0`; Spynet `SubmitSamplesConsent=0`, `SpyNetReporting=0`,
  `DisableBlockAtFirstSeen=1`; **DeviceGuard off**:
  `...\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity\Enabled=0`,
  `...\Scenarios\SystemGuard\Enabled=0`,
  `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard\ConfigureSystemGuardLaunch=2`;
  DefenderApiLogger/DefenderAuditLogger autologger `Start=0`; `SecurityHealth`/`WindowsDefender`
  Run entries deleted + StartupApproved byte-blob to hide SecurityHealth;
  `SettingsPageVisibility='hide:windowsdefender'`.
- Defender (option `enable-defender`): keeps Defender; removes its own disable values *only if
  present*; `DisableGenericReReports=1`; samples consent off; SpyNet off; autologgers off;
  renames `OFFmeansOFF.exe` back to `MpCmdRun.exe` (pairs with DefenderOFF.ps1's rename trick).
- UAC: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\{EnableLUA,
  PromptOnSecureDesktop, ConsentPromptBehaviorAdmin}` = 1/1/5 (enable) or 0/0/0 (disable);
  `ValidateAdminCodeSignatures=0` always.
- Graphics: `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\{HwSchMode=2 (HAGS on, build
  ≥19041), MiracastForceDisable=1, TdrDelay=12, WarpSupportsResourceResidency=1}`;
  Win11 branch adds per-user `DirectXUserGlobalSettings='SwapEffectUpgradeEnable=1;
  VRROptimizeEnable=0;'` (windowed-games optimization on, VRR-for-windowed off);
  **MPO disabled globally**: `HKLM\SOFTWARE\Microsoft\Windows\Dwm\OverlayTestMode=5`.
- Game Bar/GameDVR: HKCU GameBar `{AllowAutoGameMode, AutoGameModeEnabled, ShowStartupPanel,
  UseNexusForGameBarEnabled}=0`, GameDVR capture values = 0, policy `AllowGameDVR=0`, and IFEO
  `Debugger='%SystemRoot%\System32\systray.exe'` for GameBar.exe, bcastdvr.exe, GamePanel.exe,
  GameBarPresenceWriter.exe, GameBarFTServer.exe, GameBarFT.exe, XboxGameBarWidgets.exe;
  GameConfigStore FSE override values deleted (restoring default FSE behavior).
- Telemetry/privacy: full policy suite `AllowTelemetry=0`, `MaxTelemetryAllowed=0`,
  `DisableOneSettingsDownloads=1`, WER disabled in 3 places + upload/archive blocks,
  CloudContent consumer features off, AdvertisingInfo off, InputPersonalization/TIPC off,
  activity feed off, `DOTNET_CLI_TELEMETRY_OPTOUT=1` and `POWERSHELL_TELEMETRY_OPTOUT=1` via
  machine `setx`; AI removal (option `remove-ai`): WindowsAI `DisableAIDataAnalysis=1`,
  Copilot policy off, `AllowRecallEnablement=0` (HKCU).
- Cloud sync: SettingSync policy suite off (Disable*=2 with UserOverride=1), cross-device
  clipboard off.
- Windows Update (default state = disabled):
  `HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU\NoAutoUpdate=1`, `DisableDualScan=1`,
  `ExcludeWUDriversInQualityUpdate=1`, driver-searching policies off, `DODownloadMode=0`,
  PreviewBuilds flighting off, Insider page hidden; a "WindowsUpdateLegacy" cleanup pass first
  **removes XOS's own historical pause-trick values** (e.g. `PauseUpdatesExpiryTime` set to
  `2038-01-19`) with per-value logging of old value and success/failure.
- PowerShell (security-relevant convenience): machine
  `HKLM\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell\ExecutionPolicy=
  'Unrestricted'`; module logging and script-block logging disabled; `ftype`/HKCR re-association
  of `.ps1`/`.psm1` to run under powershell.exe directly.
- Input/visuals/logging: dozens of `Start_Track*=0`, autocorrect/cursor-magnetism values = 0,
  `IsInputAppPreloadEnabled=0`, DWM/XAML animation values off, diagnostics/WPP/WDF tracing off.
- App-reinstall blocking: ContentDeliveryManager `SilentInstalledAppsEnabled` etc. = 0;
  `ConfigureChatAutoInstall=0`.
- NTFS: `fsutil behavior set disable8dot3 1`, `disabledeletenotify 0`, `disablelastaccess 1`,
  `encryptpagingfile 0`; `LongPathsEnabled=1`.
- New-account defaults: loads the Default user `NTUSER.DAT` via `reg load`, writes GameBar/
  GameDVR-off (and Toast/ClipboardHistory-on) values with per-value verification, unloads with
  GC-and-retry.
- BCD edits — see "Safety-relevant behavior" below.

**Service configurations** — IMPLEMENTED
- Disabled (Start=4), unconditional list (~28): dmwappushservice,
  diagnosticshub.standardcollector.service, RetailDemo, MapsBroker, CSC, CSCSERVICE, Telemetry,
  WdiSystemHost, WdiServiceHost, troubleshootingsvc, diagsvc, **svsvc (Volume Shadow Copy →
  breaks System Restore)**, diagtrack, wercplsupport, dps, GraphicsPerfSvc, Ndu, pcasvc, dusmsvc,
  DSSvc, wisvc, InventorySvc, WSAIFabricSvc, **amdfendr + amdfendrmgr (AMD Crash Defender)**,
  McpManagementService, TermService, UmRdpService, SessionEnv, gencounter, hyperkbd, hypervideo,
  vmgid, vid, dam, GpuEnergyDrv, **UCPD (User Choice Protection Driver)**, midisrv.
- Hyper-V storage filters (storflt→0, spaceparser→3, bttflt, vpci): **guest-VM detection first**
  — `Win32_ComputerSystem` Manufacturer='Microsoft Corporation' + Model='Virtual Machine' means
  services are left enabled; original values backed up to
  `HKLM\SOFTWARE\XOSToolkit\HyperVServiceBackup` with read-back verification.
- Printing services (Spooler, printworkflowusersvc, stisvc, PrintNotify, usbprint,
  PrintScanBrokerService, PrintDeviceConfigurationService) behind `disable-printing`.
- `MicrosoftCopilotElevationService` behind `remove-ai`; MSDTC → manual (3); bam → manual (3).
- **Firewall services are NOT disabled** — BFE and mpssvc appear only in the Service-Grouping
  list (each forced into its own svchost via `SvcHostSplitDisable=1`).
- Terminal/services (RDP) trio disabled unconditionally (TermService/UmRdpService/SessionEnv).

**Scheduled task changes** — IMPLEMENTED (`DisableScheduledTasks.ps1`, 14,268 B)
- Four modes: `Core` (~110 tasks — the entire UpdateOrchestrator family, WindowsUpdate/
  AUScheduledInstall/RUXIM/sih*, InstallService wake-up scans, CEIP/Appraiser/MareBackup,
  FileHistory, RegIdleBackup, WinSAT, FamilySafety, Sustainability, CloudRestore, plus a
  `\Microsoft\Office\*` wildcard), `AI` (5 WindowsAI tasks: Recall PolicyConfiguration,
  Settings InitialConfiguration, ClickToDo ModelCaching*), `Printing` (3), `Defender` (4 Defender
  maintenance tasks + ExploitGuard MDM policy Refresh).
- Engineering quality worth copying: **verified disable with three fallbacks** per task —
  `Disable-ScheduledTask` → `schtasks /Change /Disable` → Task Scheduler COM (`Schedule.Service`
  `RegisteredTask.Enabled=$false`), each re-checked via COM/Get-ScheduledTask state, 3 attempts;
  known-protected skip list (`\Microsoft\Windows\WDI\ResolutionHost`); per-task failure log to
  `ProgramData\AME\Logs\ScheduledTaskDisable.log`; summary counts
  (`changed/already/missing/protectedSkipped/failed`); **exit 1 if anything failed** so the
  playbook surfaces it.
- Custom task created by the playbook: `XOS-DefenderDisable` — ONSTART, `SYSTEM`, run-level
  HIGHEST, launching `%SystemRoot%\XOS-DD.ps1`, which re-stops Defender services, re-sets their
  `Start=4` (boot-safety re-apply against Windows re-enabling them), deletes the task, and
  deletes itself (custom.yml "Disabling Defender: Boot Safety").
- UScheduler_Oobe `OutlookUpdate`/`DevHomeUpdate` keys deleted.

**Power settings** — IMPLEMENTED (`ApplyPowerPlan.bat` 6,383 B + `laptop-desktop.bat`)
- Fixed custom plan GUID `31693169-3169-3169-3169-316931693169`, FriendlyName
  "imribiy Power Plan" (Description "dsc.gg/xos") written via XSudo/TrustedInstaller (the
  `PowerSchemes` registry tree is TrustedInstaller-owned).
- Creation is template-derived, not hardcoded values-only: delete (never while active —
  switches to High Performance then Balanced first), then `powercfg /duplicatescheme` from
  Ultimate Performance → High Performance → Balanced → *current active scheme*, into the fixed
  GUID; then ~45 `setacvalueindex`/`setdcvalueindex` overrides (video/sleep/USB/PCIe/sub-processor
  settings; hidden-setting `Attributes=2` unhide first).
- Desktop branch (see device logic below): all sleep states off (monitor/disk/standby/hibernate
  AC+DC = 0), `powercfg -h off` (hibernation file removed), processor idle promote/demote
  exposed via "Disable/Enable Idle" desktop context-menu entries, `EnergyEstimationEnabled=0`,
  `PowerThrottlingOff=1`, `Disable-MMAgent -MemoryCompression`, all `MSPower_DeviceEnable` WMI
  instances set `$false` (with put-back), SleepStudy/Processor-Power/UserModePowerService
  diagnostic event channels off.
- Laptop branch: AC timeouts 0 but DC timeouts kept (display 300 s, standby 900 s, hibernate
  3600 s), `PowerThrottlingOff=0` (power throttling preserved), ASPM left at defaults-ish
  (AC=1/DC=2), USB selective-suspend values deleted (restored to default).
- Desktop context menu "Choose Power Plan" cascade: Power Saver / Balanced / High Performance /
  XOS Power Plan / Power Options — implemented as HKCR\DesktopBackground\Shell\PowerPlan
  subcommands calling `powercfg /setactive <GUID>`.
- Per-value results log with applied/skipped counters →
  `%SystemRoot%\service-backups\XOS-PowerPlan.log`.

**CPU/GPU/hardware-specific logic (playbook side)** — IMPLEMENTED
- Device-class detection: `Win32_Battery` presence → laptop; else `Win32_SystemEnclosure
  .ChassisTypes` primary value ≤ 7 → desktop, > 7 → laptop, missing → desktop. Every decision
  logged to `ProgramData\AME\Logs\XOS-Scripts.log` (both `laptop-desktop.bat` and `network.bat`).
- Desktop-only device disabling (chassis ≤ 7): disables PnP devices by name —
  `ACPI Processor Aggregator`, `ACPI Wake Alarm`, `AMD Crash Defender`,
  **`High Precision Event Timer` (HPET)**, `Intel(R) Platform Monitoring Technology Device` —
  via `Win32_PnPEntity.Disable()` with `pnputil /disable-device` fallback.
- DMA remapping disabled (desktop policy `DeviceEnumerationPolicy value=2`, then every service's
  `Parameters\DmaRemappingCompatible` → 0) **with per-service backup** to
  `HKLM\SOFTWARE\XOSToolkit\DmaRemappingBackup` and **NIC services excluded** (enumerated from
  `HKLM\SYSTEM\CurrentControlSet\Enum` ClassGUID `{4d36e972-...}`) so networking/WoL survive.
- MSI mode enabled for all PCI `Win32_IDEController`, `Win32_VideoController`,
  `Win32_NetworkAdapter` devices — only where `MSISupported` already exists and is 0/1; previous
  value backed up (first-writer-wins) to `HKLM\SOFTWARE\XOSToolkit\MsiModeBackup`; the
  interrupt `Affinity Policy DevicePriority` value is removed.
- Device power values (desktop): ~12 named values (`EnhancedPowerManagementEnabled`,
  `AllowIdleIrpInD3`, `EnableSelectiveSuspend`, `DeviceSelectiveSuspended`,
  `SelectiveSuspendEnabled`, `SelectiveSuspendOn`, `WaitWakeEnabled`, `D3ColdSupported`,
  `WdfDirectedPowerTransitionEnable`, `EnableIdlePowerManagement`, `IdleInWorkingState`,
  `WakeEnabled`) set to 0 across **every occurrence under `HKLM\SYSTEM\CurrentControlSet\Enum`**
  — and the script first writes each original value into an auto-generated restore script
  `%SystemRoot%\service-backups\xos-device-power-restore.bat` (a runnable .bat the user can
  execute to put every device back).
- USB power management: `USBHUB3\Parameters\{DisableLPM=1, D3ColdSupported=0, Ceip=0,
  DisableSelectiveSuspendUI=1}`, same for `usbccgp`/`pci` `D3ColdSupported=0` (desktop);
  laptop branch deletes these (default behavior).
- NIC tuning (desktop only): Wi-Fi adapters identified via `*PhysicalMediaType` 9/16 and
  **excluded**; `TcpAckFrequency=1`/`TCPNoDelay=1` per Tcpip interface (except Wi-Fi); ~38
  NIC power values set to "0" **only if already present** (`reg query && reg add` gate);
  `PnPCapabilities=24`; WoL S5 values = 2; `Dnscache\Parameters\DisableCoalescing=1`; WcmSvc
  power management off. Laptop branch: all NIC tweaks skipped.
- GPU: HAGS (`HwSchMode=2`) on all supported builds; TdrDelay=12; Miracast off; MPO off; NVIDIA
  `.nip` profile applied via Toolkit Gaming page (DOCUMENTED).

**Rollback / undo / backup mechanisms AND their limits** — IMPLEMENTED (playbook side) +
DOCUMENTED (toolkit side)
- Stock capture before any change: `StockValueCapture.ps1` runs first and records stock values
  into `HKCU\Software\XOSToolkit\StockValues` and `HKLM\SOFTWARE\XOSToolkit\StockHardware`
  (services' `DmaRemappingCompatible`, every PCI device's `MSISupported`, ~45 NIC power values
  per adapter, `MSPower_DeviceEnable` instances with PnPCapabilities), with a
  `CaptureStatus='Complete'/'Incomplete:<n>'` marker.
- Capture-refusal logic (important): if XOS is *already* present (existing stock store, XOS
  Toolkit uninstall entry, the XOS power-plan GUID, `%windir%\imribiy.pow`) the script **refuses
  to capture** — so it never overwrites true stock values with XOS-modified ones; a
  `RestoredToStock='Verified'` marker (set by the toolkit after a verified restore) causes the
  store to be rebuilt from scratch on the next apply.
- Per-area backups in registry: `DmaRemappingBackup`, `MsiModeBackup`, `HyperVServiceBackup`,
  `EventChannelState`; plus file backups: `DeviceStateBackup.ps1`, `EventChannelBackup.ps1`,
  `DefenderRunBackup.ps1`; plus generated restore scripts under
  `%SystemRoot%\service-backups\` (device-power restore .bat; `XOS-PowerPlan.log`).
- Gating on backup success: the event-channel wipe **throws and refuses to run** unless
  `EventChannelState.CaptureStatus -eq 'Complete'`.
- Diagnostics: `InstallDiagnostics.ps1 -Phase Start/Finish` wraps the run; per-step logs to
  `%ProgramData%\AME\Logs\XOS-Scripts.log` and AME's own logs.
- Limits (explicit, README/toolkit): "To uninstall, use the Troubleshooting page in XOS
  Toolkit. **It restores Windows defaults, not your previous configuration.** Removed Store apps
  have to be reinstalled by hand." Toolkit uninstall "does not undo settings changed by the
  Toolkit or by XOS"; restore controls are per-page/per-change ("You can undo one change
  without resetting the rest"); the uninstaller removes the "XOS CPU Service" task, XSudo and
  shortcuts but keeps user data. Uninstall semantics in newer releases remove values **"each
  only if it still holds the value XOS wrote"** (0.6.4 release notes) — i.e. user-made changes
  are not clobbered. FAQ: "Should I run `sfc /scannow` or use System Restore? Never. Both are
  unreliable and are likely to break XOS's changes."
- Irreversible actions with NO restore: **all event logs are cleared at the end**
  (`wevtutil el | wevtutil cl`), `%TEMP%` and `Windows\Temp` cleared, Edge/WebView2 removal,
  AppX deprovisioning (Store apps must be manually reinstalled), DefenderOFF rename trick,
  `powercfg -h off` (hibernation), deleted scheduled tasks (disable, not delete — reversible),
  BCD value deletions (below).

**Known compatibility issues** — DOCUMENTED (hub README/FAQ, release notes; issue tracker has
no real user reports — see limitations)
- Home edition ignores the update-off policy (Pro recommended).
- Smart App Control on → AME Wizard fails with `FileNotFoundException` (must be turned off; SAC
  can then only be re-enabled by reinstalling Windows).
- FACEIT/ESEA require the latest Windows updates → users must switch Updates page to Normal.
- Valorant/FACEIT/Fortnite/FiveM requiring VBS/HVCI/Core Isolation: documented BIOS checklist
  (TPM 2.0, UEFI not CSM, Secure Boot, SVM/VT-x + IOMMU/VT-d) then enable VBS + HVCI from the
  Toolkit System page — necessary because the playbook (disable-defender default) writes HVCI
  `Enabled=0`.
- FiveM needs services XOS turns off → "Enable FiveM Services" button (Gaming page).
- Xbox controller over Bluetooth, laptop touchpads (Serial Ports + Power Savings toggles),
  Microsoft Store flakiness on 23H2 ("several tries"), WebView2-dependent apps (Store, Teams,
  WhatsApp, Discord, Spotify) — all have documented Toolkit re-enable paths.
- UAC off → some PowerShell commands/Spicetify refuse to run (everything is elevated).
- Rust developer betas are **"tested only in virtual machines... expect bugs, including losing
  access to your Windows installation on the system drive"** (release notes, every beta).
- Windows-version recommendation matrix (DOCUMENTED): choose Win11 if Ryzen with more than one
  CCX (Ryzen 9 or 1000/2000/3000 series), Intel with E-cores, modern AAA games, or >1000 Hz
  input devices.
- Owner's own hardware test report (issue #3, closed): Toolkit 0.6.1 on Win11 Pro 25H2 build
  26200.9974 — "No bugs detected on my end" (owner-filed; treat as a smoke test, not QA).

**Safety-relevant behavior** — IMPLEMENTED
- Defender: full disable path incl. TamperProtection bypass via TrustedInstaller, service
  Start=4 writes, policy disables, WTDS/Web-threat-defense off, SmartScreen off + smartscreen.exe
  IFEO hijack to `taskkill.exe`, boot-safety re-apply scheduled task, Security Center tray removal,
  Windows Defender Settings page hidden. (Keep-Defender path exists but is not the default.)
- Security mitigations: `FeatureSettingsOverride/Mask=3` (Spectre/Meltdown), HVCI/SystemGuard
  off (Defender option), **system-wide process-mitigation disable**: enumerates every valid
  `Set-ProcessMitigation -Disable` value at runtime and applies all, then writes
  `MitigationOptions`/`MitigationAuditOptions` masks of `0x22` bytes to the kernel key and IFEO
  entries for fontdrvhost.exe, dwm.exe, lsass.exe, svchost.exe, WmiPrvSE.exe, winlogon.exe,
  csrss.exe, ntoskrnl.exe, services.exe. This is the single most security-hostile block in the
  playbook and directly conflicts with anti-cheat requirements (the FAQ has to walk users back
  through re-enabling VBS/HVCI).
- UAC fully togglable (disable option sets EnableLUA=0).
- BCD edits (IMPLEMENTED, `custom.yml` "Optimizing Boot Configuration"):
  `bcdedit /deletevalue useplatformclock`, `/deletevalue useplatformtick`,
  `/set bootmenupolicy legacy`, `/timeout 10`, `/set {current} description
  "XOS-Playbook-V0.812"`, volume label `%SystemDrive%` renamed to "XOS"; desktop branch adds
  `bcdedit /set disabledynamictick yes` and `powercfg -h off`.
- PowerShell execution policy set to `Unrestricted` machine-wide; module/script-block logging
  disabled (audit-hostile).
- All event channels disabled (after backup) and all logs cleared at the end.
- UCPD service disabled (Windows will fight this on updates; XOS also ships a UCPD-aware
  fallback for the Feeds key using a staged logon script).
- Windows Update disabled by default via policy (Normal/Security-Focused/Disabled/Hard-Disabled
  modes selectable later in Toolkit; Hard Disabled also blocks update services and "can break
  the Microsoft Store"; unavailable while a Microsoft account is signed in) — DOCUMENTED.
- Firewall: not disabled (services only ungrouped); no firewall rules modified in the playbook.
- Update Health Tools removed (`UPDHEALTH.bat`, TrustedInstaller).
- Positives: BitLocker is not touched (contrast FSOS-X); guest-VM detection preserves Hyper-V
  guest services; NIC services excluded from DMA-remap changes; laptop branch is deliberately
  conservative; MSI/DMA changes gated on value presence and backed up.

### 2.3 Useful ideas for NEXTRIX (NX19 + rollback shortlist)

1. **Derive, don't hardcode, everything topology-related** (the playbook's device logic and the
   toolkit's topology crate both follow this): chassis/battery class detection, service
   existence checks before mutation, `reg query && reg add` presence gates, build-number
   nested guards.
2. **Stock-value capture before first mutation, with capture-refusal when artifacts already
   exist** — the `StockValueCapture.ps2` design (registry-backed stock store +
   `CaptureStatus` marker + `RestoredToStock` verification marker + refuse-to-capture-if-already-
   tweaked) is directly transplantable to NEXTRIX's rollback contract.
3. **Only-if-XOS-value restore semantics** ("each only if it still holds the value XOS wrote")
   — the correct rule for multi-tenant registries; never clobber user changes made after yours.
4. **Per-area backup stores + auto-generated runnable restore scripts** (DmaRemappingBackup,
   MsiModeBackup, generated `xos-device-power-restore.bat`) — cheap, transparent, auditable.
5. **Gate destructive steps on backup completeness** (event channels refuse to disable unless
   capture is Complete) — a rollback-safety pattern NEXTRIX should generalize ("no mutation
   without verified prior state").
6. **Verified multi-fallback task disabling with counters and exit codes** — the
   DisableScheduledTasks.ps1 pattern (3 mechanisms, per-task verification, protected-skip list,
   summary log, exit 1 on any failure).
7. **Never delete the active power plan** — switch away first, then delete, then rebuild from
   the best available template into a fixed GUID; log applied/skipped counts.
8. **Laptop-vs-desktop split with an explicit, logged classifier** (battery → laptop;
   chassis ≤ 7 → desktop) and a materially more conservative laptop branch.
9. **Wi-Fi adapter exclusion via `*PhysicalMediaType`** before NIC tweaks; presence-gated
   value writes.
10. **Guest-VM detection before virtualization-service changes** (Win32_ComputerSystem
    Manufacturer/Model) — prevents bricking Hyper-V guests.
11. **Version pinning** (`TargetReleaseVersionInfo` = current DisplayVersion) as a stability
    measure while updates are paused.
12. **Boot-safety re-apply task that self-deletes** (XOS-DefenderDisable pattern) for settings
    Windows re-enables at boot — but NEXTRIX should weigh whether it wants this at all (it is a
    persistence mechanism).
13. **Default-unsafe options should be non-default** (XOS marks Xbox removal unchecked by
    default while other removals are checked — an example of option-level risk tiering).

### 2.4 Reject / caution (with reasons)

- **License wall**: CC BY-NC-ND 4.0 — the ND clause forbids distributing modified versions, and
  it is not an OSI code license. NEXTRIX may *read and learn* from it but must NOT copy code,
  YAML content, wallpaper/branding, or the `XOS.nip` profile into NEXTRIX. Treat every XOS file
  as reference-only. (Third-party components carry their own permissive licenses: MIT for
  DefenderOFF/AveYo-derived script, Nvidia Profile Inspector, MinSudo; Apache-2.0 Chocolatey —
  but those are third-party works, not XOS's.)
- **System-wide process-mitigation nuking** (runtime-enumerated `Set-ProcessMitigation -Disable`
  everything + 0x22 IFEO/kernel masks) — maximally security-hostile; breaks the exact
  anti-cheat/VBS requirements NEXTRIX users will have. Reject as a design; if NEXTRIX touches
  mitigations at all, scope per-user-choice with per-value backup and hard anti-cheat guards.
- **IFEO Debugger hijacks** (smartscreen.exe → taskkill.exe; GameBar*.exe → systray.exe) —
  crude, detectable as tampering, and globally effective rather than opt-in. Reject.
- **MPO global disable (`OverlayTestMode=5`)** without GPU-class gating — FSOS-X's own history
  shows this is machine-dependent; XOS applies it unconditionally. Reject unconditional use.
- **HPET device disable** on desktops — breaks timing-sensitive setups on some hardware; if
  kept, must be per-device-class and reversible (it is at least device-level and captured).
- **svsvc (VSS) disable** silently destroys System Restore while the FAQ tells users to never use
  it — NEXTRIX's rollback-safe mandate is incompatible with this; System Restore points should
  be *created*, not destroyed.
- **Clearing ALL event logs at the end of install** — destroys forensic/diagnostic history;
  directly anti-rollback-safety. Reject.
- **Windows Update disabled by default** — security-posture risk; XOS at least documents
  FACEIT-driven re-enable and offers four modes. NEXTRIX should default to enabled or
  security-only with explicit user opt-in for full disable.
- **PowerShell ExecutionPolicy=Unrestricted + script-logging off machine-wide** — reject.
- **Defender default-disable** — same verdict as FSOS-X: not NEXTRIX scope; the keep-Defender
  path and the DefenderOFF rename trick both leave awkward states; the boot re-apply task is
  persistence-like behavior.
- **UCPD disable** — fights the OS; Windows re-enables it via updates (XOS itself has to work
  around the UCPD driver blocking its Feeds write). Caution.
- **`wevtutil`-cleared logs + `sfc /scannow` warnings** — a sign the end-state is hard to
  diagnose; NEXTRIX should keep logs intact.
- **Win32PrioritySeparation=38 + SystemResponsiveness=10 + NetworkThrottlingIndex=10** —
  common tweak values with contested evidence; NEXTRIX should treat scheduler-value tuning as
  experiment-gated, not default.

### 2.5 Research limitations (XOS Playbook)

- `Configuration/custom.yml` is 1,745 lines; the majority was read, but not every line: the
  full AppX removal list (~lines 1013–1415) and the Edge-removal block (1416–1549) were sampled,
  and "Cleaning Up Locked Leftovers" (1573–1687) was not read in detail.
- Helper scripts NOT read (sizes recorded only): `DefenderOFF.ps1` (14,789 B), `RemoveEdge.ps1`
  (31,173 B), `EventChannelBackup.ps1`, `OptionalFeatures.ps1`, `PCHealthCheck.ps1`,
  `RemoveAppx.ps1`, `WidgetsPolicy.ps1`, `DeviceStateBackup.ps1`, `InstallDiagnostics.ps1`,
  `UPDHEALTH.bat`, `onedrive.bat`, `taskbar.bat`, `TakeOwnership.reg`.
- The stable release (V0.777) ships C# Toolkit 0.2.178 whose C# source is NOT published —
  findings about toolkit internals come from the repo's Rust source, which is ahead of the
  stable release (Rust betas 0.4.x–0.7.0 correspond to playbook betas V0.811–V0.818 in
  `imribiy/xos-beta`, which was not directly inspected).
- The `xos-beta` repo was not fetched; beta versions (V0.813–V0.818) are known only through
  toolkit release notes.

---

## 3. XOS Toolkit (imribiy/xos-toolkit)

### 3.1 Identity

| Field | Value | Evidence |
|---|---|---|
| Name / owner | XOS Toolkit (app) + XOS-CpuService (background service) + XSudo (elevation helper), by imribiy | IMPLEMENTED (repo) |
| Repo | `https://github.com/imribiy/xos-toolkit` — public, `main`, 18 commits, language Rust (UI: Slint), created 2026-10-25, last push 2026-11-22; 5 stars, 0 open issues | IMPLEMENTED (GitHub API) |
| Latest stable release | **XOS Toolkit 0.2.178 (stable, C#)** — tag `xos-toolkit-v0.2.178`, published 2026-11-14, `XOS-Toolkit-Setup-0.2.178.exe` (8,768,023 B; SHA-256 `3DB775CCE4A2C4AA68FBE80714C41C1F0E369F517BC6ACEFD6FD6D8C7CC6BFCB`; 72 downloads). "This version's C# source is not published; the repository holds the current Rust source." Requires Windows 10/11 64-bit, admin, **.NET Framework 4.7.2+** (C# version). | DOCUMENTED (release notes) |
| Latest developer beta | **XOS Toolkit 0.7.0 (developer beta, Rust)** — published 2026-11-22, `XOS-Toolkit-Setup-0.7.0.exe` (15,390,963 B; SHA-256 `9A8A1472EB7DC62AF044F442DD975F66AA1490140D70EEDD08A8E5A3F186A476`), included in XOS V0.818 beta; **no .NET needed**. Beta line 0.4.1→0.7.0 released Nov 18–22, 2026. | DOCUMENTED (release notes) |
| License | CC BY-NC-ND 4.0 (LICENSE fetched; same text as playbook) | IMPLEMENTED (LICENSE file) |
| Runtime requirements | Windows 10 or 11, 64-bit; administrator rights; app asks for elevation on launch (Rust builds need no .NET) | DOCUMENTED (README) |
| Build deps | Rust (stable, MSVC), VS2022 Build Tools w/ C++ workload, Inno Setup 6 (`installer.iss`); embedded-at-compile-time assets NOT in repo: Nvidia Profile Inspector (MIT), Chocolatey 2.7.1.0 MSI (Apache 2.0), `XSudo.exe` (built from `XSudo/` via `build.ps1 -Install`) | DOCUMENTED (README build section) |
| Bundled third-party (per releases) | Nvidia Profile Inspector (Orbmu2k, MIT), Chocolatey (Apache 2.0), DefenderOFF.ps1 (AveYo LeanAndMean, MIT); stable 0.2.178 also bundles MinSudo (NanaRun, MIT) and Open-Shell Fluent-Metro skins | DOCUMENTED (release notes) |

URLs actually inspected: repo page; `api.github.com/repos/imribiy/xos-toolkit` (+ `/releases`, `/releases/latest`, `/contents/crates`, `/contents/crates/xos-cpu/src`, `/contents/crates/xos-cpuservice/src`); raw `LICENSE`; raw `crates/xos-cpu/src/topology.rs` (26,865 B, full); raw `crates/xos-cpu/src/rules.rs` (11,738 B, full); raw `crates/xos-cpuservice/src/main.rs` (25,950 B, full). The toolkit releases API pagination was cut off in one fetch (older 0.4.x–0.2.x releases truncated) — sufficient coverage obtained via the saved output.

### 3.2 Findings by area

**Repository structure** — IMPLEMENTED
```
crates/xos-toolkit        the app (window, pages, installer icon)
crates/xos-cpuservice    background CPU-rule service
crates/xos-page-*        one crate per Toolkit page (apps, config, cpu, gaming, network,
                         software, system, troubleshoot, update, visuals)
crates/xos-core, xos-sys, xos-helpers, xos-cpu, xos-winupdate, xos-uninstall   shared logic
resources/               embedded data (power plan, service & registry defaults, NVIDIA profiles,
                         XOS Open-Shell skin)
XSudo/                   elevation helper (Rust), built separately into resources\XSudo.exe
installer.iss            Inno Setup script        .cargo/  Cargo.toml/lock  LICENSE  README
```

**CPU topology / identification logic — the NX19 core (all IMPLEMENTED, `crates/xos-cpu/src/topology.rs`)**

- *Processor identification*: CPU name read from
  `HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0 \ ProcessorNameString` (winreg);
  manufacturer classified by lowercase substring (`"amd"`→AMD, `"intel"`→Intel, else Other).
  Note: name-string based, not CPUID vendor based.
- *Hybrid P/E detection*: `GetLogicalProcessorInformationEx(RelationProcessorCore)` parsed from
  raw bytes — each core entry yields `has_threads` (ProcessorFlags bit 0 → SMT), **tier =
  EfficiencyClass byte** and the core's logical-processor set (cross-group indexing
  `global_index = group*64 + lp`). `is_hybrid` = any tier ≥ 1; `is_three_tier_hybrid` = any
  tier ≥ 2 (Intel Core Ultra LP-E class). Labels built per LP: `"P-Core 0 T0"`, `"E-Core 1"`
  style — P/E tagging applied for Intel hybrids only (perf tier = 2 when three-tier else 1).
- *Logical processor indexes are fully derived*, never hardcoded: from the OS core-relationship
  buffer, cross-group via `group*64+lp`, with fallback to
  `std::thread::available_parallelism()` + `"Core {i}"` labels on any init failure
  (`error_message` surfaced to the UI).
- *CPU Set ID mapping*: `GetSystemCpuSetInformation` parsed from raw bytes — map
  `global LP index → CPU Set ID (u32)`. This is the key to applying CPU Sets correctly.
- *AMD X3D/CCD handling*: `RelationProcessorDie` (`enumerate_dies`; Win32 error 31 → treated as
  "dies unsupported" → empty), and `RelationCache` level-3 entries per die. A die is classified
  "3D" when its summed L3 is more than **2× the smallest die's L3**; presets are then
  `"3D Cores"` / `"Non 3D Cores"` (multi-large-die variants labelled `3D Cores {d}`), or
  `"CCD 0..n"` when no 3D asymmetry exists. Quoted heuristic (research excerpt, CC BY-NC-ND
  4.0, source: `https://raw.githubusercontent.com/imribiy/xos-toolkit/main/crates/xos-cpu/src/topology.rs`):
  ```rust
  // l3_per_die computed from RelationCache L3 sizes per die:
  let smallest = *l3_per_die.iter().min().unwrap_or(&0);
  for (d, &size) in l3_per_die.iter().enumerate() {
      if size > smallest * 2 { large.push(d); }   // "3D Cores" dies
  }
  ```
  (i.e., X3D detection is **cache-size asymmetry between dies**, not a CPU-name list.)
- *Presets generated*: Intel hybrid → `P-Cores`, `E-Cores`, (+`LP E-Cores` three-tier);
  multi-die → `3D/Non-3D` or `CCD n`; plus `Physical Cores` (secondary SMT threads filtered out
  via the thread labels) and `Logical Cores` (secondaries only) — the physical preset is only
  offered if any filtering actually occurred.
- *CPU Sets vs affinity usage*:
  - `apply_cpu_set(pid, cores)`: `OpenProcess(PROCESS_SET_LIMITED_INFORMATION = 0x2000)` then
    `SetProcessDefaultCpuSets(handle, ids)` — fails (returns false) if ANY selected LP is
    missing from the CPU-set map.
  - `apply_affinity(pid, cores)`: only when the machine is single-group (all available LPs
    < 64); `OpenProcess(PROCESS_SET_INFORMATION = 0x0200)` + `SetProcessAffinityMask`.
  - README (DOCUMENTED): "**CPU Set is the default and works with most games and anti-cheat
    software. Affinity is stricter, but most anti-cheats block or override it, and it is
    limited to 64 logical processors.**"
- *Testability*: `parse_cores` / `parse_caches` / `parse_cpu_set_entries` are pure functions
  over byte buffers with synthetic-buffer unit tests (hybrid Intel labels/presets; AMD dual-CCD
  with 96 MB vs 32 MB L3 → "3D Cores"/"Non 3D Cores"; bad-size buffer truncation) — the
  topology logic is testable without exotic hardware.

**Per-process / per-game scheduling rules — IMPLEMENTED (`crates/xos-cpu/src/rules.rs` +
`crates/xos-cpuservice/src/main.rs`)**

- Rule contract (JSON at `%AppData%\XOS Toolkit\CpuRules.json`, field names from the serde
  attributes/tests; research excerpt, CC BY-NC-ND 4.0, source:
  `https://raw.githubusercontent.com/imribiy/xos-toolkit/main/crates/xos-cpu/src/rules.rs`):
  ```json
  {"rules":[{"cores":[true,false,true],"maskType":"CPUSet","processName":"game/x.exe"}],
   "userPresets":[{"cores":[false,true],"name":"Mine"}]}
  ```
  One rule = process image name + core-selection bit vector + mask type ("CPUSet"|"Affinity",
  validated exactly). This is per-game scheduling expressed as per-process rules.
- Validation limits: ≤4096 rules/presets, ≤4096 cores per rule, unsupported maskType rejected.
- Export format `"xos-cpu-config"` carries `cpuName`, `exportedUtc`, `format`,
  `logicalProcessors` + rules/presets (so imports can be sanity-checked against the exporting
  machine); 16 MB import cap; BOM-stripped parsing; corrupt file → quarantined as
  `CpuRules.json.corrupt-<timestamp>` with defaults returned (no data loss, no crash).
- Atomic writes: temp file (fsync) then `ReplaceFileW` (preserves target metadata/ACLs) or
  rename; per-write temp names derived from time+pid+counter.
- **XOS-CpuService enforcement loop** (main.rs, IMPLEMENTED):
  - Scheduled task `XOS CPU Service` starts it at sign-in with elevated rights (README);
    single instance via `Global\XOS_CpuService_Mutex`; clean shutdown via
    `Global\XOS_CpuService_Stop` event; **runs itself at BELOW_NORMAL priority class +
    BELOW_NORMAL thread priority** so it never competes with the game.
  - Poll cycle: 1.5 s (`WaitForSingleObject(stop, 1500)`), each cycle wrapped in
    `catch_unwind` with a panic hook logging crashes; **rule reload on file mtime+size
    change** with a 3×200 ms sharing-violation retry (tolerates the UI writing the file);
    unreadable file → keeps previous rules.
  - Process discovery: **`NtQuerySystemInformation(SystemProcessInformation=5)`** with a
    manually parsed buffer — a UTF-16 name-length prefilter (`rule_name_byte_lengths` set)
    before any string decode, self-PID exclusion, 1 ms sleep per 20 entries, buffer growth on
    `STATUS_INFO_LENGTH_MISMATCH`, truncated-scan detection. No WMI/snapshot overhead.
  - Matching: case-insensitive (`fold_name` uppercase) exact image-name match.
  - Application: same Win32 calls as the toolkit crate (`SetProcessDefaultCpuSets` /
    `SetProcessAffinityMask` with the same access rights and single-group guard); success/
    failure tracked per PID; **failed rules retry every cycle** with logged reason
    ("Windows error {n}" or "the rule selects cores this PC does not have"); name-change
    triggers re-apply; 1 ms inter-apply sleep.
  - Observability: `%ProgramData%\XOS Toolkit\Logs\XOS-CpuService.log`, timestamped lines
    (`[OP] Started | PID | Logical processors | CPU sets`, `[RESULT] OK/FAILED ...`), 256 KB
    rotation to `.old.log`, `log_once` dedup with a 50-message cap.
  - Unit tests: affinity mask edge cases (index ≥64 refused), CPU-set selection (missing LP →
    None), config contract, rule-cache case-insensitivity, process-scan bounds/truncation.

**Other toolkit behavior (DOCUMENTED unless noted)** — README + release notes
- Page model: "Most items show their current state and have their own apply, enable, disable
  or restore control. **You can undo one change without resetting the rest.**"
- Coverage: System (Defender, UAC, notifications, power savings, XOS power plan, hibernation,
  VBS/HVCI, Hyper-V, RDP, Search, service grouping, Fast Startup (0.6.3), Windows 11 Resume
  (0.7.0, 23H2+)); Visuals; Gaming (Game Bar, FSO, CPU/GPU priorities, HAGS, VRR, Auto HDR,
  overlays, NVIDIA/AMD tweaks incl. XOS.nip and "Safe/Experimental" AMD tweaks); CPU affinity
  (rules + presets + service toggle + import/export); Network & peripherals; Apps & cleanup;
  Updates (four modes; Known Game List metadata; root certificates); Repair (network reset,
  shell repair, time sync, Windows/XOS service defaults, diagnostic ZIP, Uninstall XOS);
  Backup & monitoring (JSON config export/import with diff preview; critical/error events view).
- Automatic updater since 0.6.0: downloads from GitHub releases, **verifies the SHA-256 GitHub
  publishes**, silent install, stable channel skips pre-releases (IMPLEMENTED claim in release
  notes 0.6.0).
- Diagnostic bundle: "Report a Problem" creates a ZIP (CBS.log trimmed — "On a test machine
  CBS.log went from 21 MB to 2.5 MB" — DEV-BENCHMARK), opens a GitHub issue with versions
  prefilled; **the Toolkit uploads nothing** (user attaches manually).
- Uninstall semantics: removes app, the `XOS CPU Service` task, XSudo + shortcuts; keeps
  `%AppData%\XSudo` saved list; "It does not undo settings changed by the Toolkit or by XOS.
  Use the restore controls on each page, or Troubleshooting > Uninstall XOS... **That does not
  restore your previous configuration, and removed Store apps have to be reinstalled by hand.**"
- Uninstall XOS evolution (release notes, DOCUMENTED): removes AI/Recall/AppCompat policies
  "each only if it still holds the value XOS wrote"; lifts update-service protection before
  fixing BITS when Hard Disabled; turns Fast Startup back on, re-enables Reserved Storage and
  removes its retry task (0.6.3); removes the Resume host setting (0.7.0); a task Windows
  already re-enabled is "confirmed in the log instead of being reported as not verified"
  (0.4.3); Defender running → settings already at Windows default are "logged as done instead
  of failed" (0.6.4).
- XSudo: installed to `%ProgramFiles%\XSudo` with Start-menu shortcut; a window that runs
  programs as TrustedInstaller; Explorer right-click entries (Run/Import/Open as
  TrustedInstaller) off by default on Toolkit-only installs, on when installed by the playbook.
- Rust beta disclaimer on every release: "Not tested on real hardware. Developer betas are
  tested only in virtual machines... expect bugs, including losing access to your Windows
  installation on the system drive."

### 3.3 Useful ideas for NEXTRIX (NX19 shortlist)

1. **Topology derivation chain (verbatim-approach, not code)**:
   `GetLogicalProcessorInformationEx(RelationProcessorCore)` → SMT flag + EfficiencyClass tier
   → P/E/LP-E classes; `RelationProcessorDie` → CCD/die groups; `RelationCache` L3 sizes per
   die → X3D detection by >2× asymmetry; `GetSystemCpuSetInformation` → LP→CPU-set-ID map;
   cross-group LP indexing `group*64+lp`. Zero CPU-name hardcoding.
2. **CPU Sets by default, affinity as opt-in fallback** (single-group ≤64 LPs only), with the
   documented rationale: anti-cheats tolerate default CPU sets, block/override affinity masks.
3. **Per-game scheduling = per-process rules** (image name, case-insensitive; core bit-vector;
   maskType) stored in one small JSON file with validation limits, versioned export carrying
   CPU name + LP count for cross-machine sanity checks.
4. **Enforcement service design**: sign-in scheduled task; single-instance mutex + stop event;
   self-lowering to BELOW_NORMAL priority; 1.5 s poll; mtime+size reload with sharing-retry;
   keep-last-known-good on parse failure; per-PID apply/retry with explicit reasons; UTF-16
   length prefilter before name decode; yield sleeps inside the scan loop; 256 KB log rotation.
5. **Quarantine-don't-delete** for corrupt config files (rename with timestamp, log, fall back
   to defaults).
6. **Atomic file writes via fsync+`ReplaceFileW`** for any state file NEXTRIX writes.
7. **SHA-256-verified self-updater** with a stable/beta channel split (stable skips
  pre-releases) — a trust-building pattern for NEXTRIX distribution.
8. **Pure-function byte-buffer parsers with synthetic unit tests** — NEXTRIX's topology module
   should be testable on any dev machine without exotic CPUs.
9. **Per-undo restore controls with current-state display** ("undo one change without resetting
   the rest") as the toolkit's core UX, plus a diff-preview config import.
10. **Honest failure logging**: "rule selects cores this PC does not have" style human-readable
    reasons instead of raw error codes.

### 3.4 Reject / caution (with reasons)

- **License wall (same as playbook)**: CC BY-NC-ND 4.0 — no code copying into NEXTRIX;
  reference-only.
- **NtQuerySystemInformation raw parsing** — efficient but version-fragile (undocumented
  struct layout assumptions, x64-only offsets) and anti-cheat-sensitive (raw NT calls from a
  background elevated service can look suspicious to heuristics). If NEXTRIX needs a poller,
  consider documented APIs or justify the NT route with the same bounds-safety tests XOS wrote.
- **Rust beta channel quality bar**: VM-only testing with an explicit "you may lose access to
  your Windows installation" disclaimer — NEXTRIX must hold a higher bar (staged rollout,
  restore-path verification) for anything labeled stable.
- **C# stable (0.2.178) source unpublished** — the shipping stable product is partially
  unauditable; a caution about the project's current verification status, not a design choice
  to copy.
- **"Uninstall restores Windows defaults, not your previous configuration"** — NEXTRIX's
  rollback-safe mandate requires true pre-change restoration (XOS's own `StockValueCapture`
  playbook machinery is closer to this; the toolkit's uninstall is not).
- **Diagnostic bundles posted to public GitHub issues** — good privacy instinct (no auto
  upload), but NEXTRIX should scrub machine identifiers and warn about public attachment more
  prominently.

### 3.5 Research limitations (XOS Toolkit)

- Read source is limited to `xos-cpu` (topology.rs, rules.rs) and `xos-cpuservice/main.rs`;
  the page crates (`xos-page-cpu` UI, `xos-page-gaming`, etc.), `xos-core`, `xos-sys`,
  `xos-uninstall`, `xos-winupdate` and the `XSudo/` Rust source were NOT read. Statements about
  page-level behavior come from the README/release notes (DOCUMENTED).
- The GitHub issues API for this repo returned HTTP 403 (rate limit) on the closed-issues
  query; repo metadata shows 0 open issues. Closed-issue content for the toolkit is therefore
  unknown (the playbook's 3 closed owner-filed test issues were retrieved).
- Older releases beyond 0.4.1 were truncated in one API fetch; key facts (0.2.178 C# stable,
  0.5.0–0.7.0 Rust betas) were captured.
- The stable C# Toolkit (what users actually run today per V0.777) cannot be source-audited.

---

## 4. Cross-project observations (decision-relevant)

- **Distribution model convergence**: both FSOS-X and XOS are AME Wizard `.apbx` playbooks
  (zip password `malte`) + a native companion app, applied on stock Windows rather than a
  modified ISO. XOS explicitly justifies this: drivers and Windows Update "work far better than
  on a modified ISO" (DOCUMENTED).
- **Anti-cheat is the dominant compatibility constraint** for both: FSOS-X warns Faceit/Valorant
  users against mitigation disabling and reports anti-cheat blocking of CPU Sets/GPU priority;
  XOS documents CPU Set-vs-affinity anti-cheat behavior, a VBS/HVCI re-enable checklist, and a
  FiveM services toggle. NEXTRIX's NX18/NX19 must treat anti-cheat detection as a first-class
  gate.
- **Rollback maturity differs**: XOS has real, inspectable backup machinery (stock capture,
  per-area backups, only-if-XOS-value restore, verified task disabling); FSOS-X's restore
  story is per-toggle Dash controls with no pre-change capture claims. Neither restores the
  user's *previous* configuration wholesale — exactly the gap NEXTRIX's rollback-safety mandate
  targets.
- **Size/philosophy**: XOS playbook ≈9 MB (minimal, opt-in heavy defaults like Xbox removal
  unchecked); FSOS-X ≈416 MB (bundles browsers/runtimes, "tick everything" FAQ advice).
- **No VERIFIED performance evidence exists for either project.** Every FPS/RAM/process-count
  claim found is DEV-BENCHMARK. NEXTRIX must not cite either project as proof of performance.

## 5. Global research limitations

1. **Web search unavailable**: the web-search tool failed (HTTP 402 quota) for the planned
   supplementary queries (FSOS-X community coverage, third-party reviews). As a result, this
   memo contains **no COMMUNITY-CLAIM evidence** and no VERIFIED evidence; FSOS-X findings are
   DOCUMENTED/DEV-BENCHMARK only, and XOS findings are IMPLEMENTED/DOCUMENTED only.
2. **FSOS-X is closed-source** (no linked repository; "source available" = downloadable
   password-protected commercial archive). The 416 MB `.apbx` was deliberately NOT downloaded or
   extracted (read-only web research; no third-party binary inspection). All FSOS-X internal
   mechanics (registry keys, service lists, task lists) remain unobservable.
3. **GitHub API rate limiting**: the xos-toolkit closed-issues endpoint returned 403; the
   toolkit release list was truncated below 0.4.1; no other endpoints failed.
4. **XOS toolkit page-crate and XSudo sources not read** (see §3.5); RemoveEdge.ps1 and
   DefenderOFF.ps1 internals not read (see §2.5).
5. `imribiy/xos-beta` was not directly inspected; beta version facts come from toolkit release
   notes.
6. Nothing was executed, applied, benchmarked or installed on this machine at any point; no
   Windows settings were read or changed. All evidence is from fetched public pages listed in
   the "URLs actually inspected" lines.
7. Snippet policy: only two code excerpts are quoted, each well under 10 lines, each labeled
   with its source URL and license (CC BY-NC-ND 4.0), for identification/discussion only. No
   code was copied for reuse.

Access date: 2026-11-23. Researcher: NEXTRIX subagent R1.
