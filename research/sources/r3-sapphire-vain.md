# R3 Reference-Project Research: SapphireOS, SapphireOS-Playbook, Vain-Playbook

Read-only web research for NEXTRIX Phase 1. No Windows settings were modified, no tweak or
script was executed on the host. Evidence tags used throughout:
- **[IMPLEMENTED]** — verified in source text actually fetched (file path / raw URL cited)
- **[DOCUMENTED]** — claim from the project's own README/site/release notes, not verified in source
- **[COMMUNITY-CLAIM]** — third-party statement (issues, comments)
- **[DEV-BENCHMARK]** — developer-published performance number (none found for these projects)
- **[VERIFIED]** — independently reproduced measurement (none; this was a read-only source review)

Note on benchmarks: none of the three projects publishes measured performance numbers.
Vain's own release notes state the Thread Director "can help a lot or cost FPS" without
figures [DOCUMENTED]. No DEV-BENCHMARK or VERIFIED performance claims are recorded here.

---

## Project 1 — SapphireOS (HickerDicker/SapphireOS)

### Identity table

| Field | Value |
|---|---|
| Name | SapphireOS |
| Repo | https://github.com/HickerDicker/SapphireOS (default branch `main`) |
| Type | Modified Windows ISO project ("Superlite"/"Ultralite" editions) + post-install scripts |
| Primary language | Batchfile (per GitHub API) |
| License | LICENSE file = GNU GPL v3.0 (35,149 bytes; GitHub API reports `gpl-3.0`). Identical LICENSE blob (`f288702d…`) also in SapphireOS-Playbook. Caveat below on bundled third-party works |
| Latest release | **None.** `/releases/latest` returns 404. ISO versions advertised via Discord only (README: "Download Links Can Only Be Found In The Discord"). Community-posted ISO links in issue #7 mention "SapphireOS 11 23H2 0.9", "24H2 0.3", "SapphireOS 10 0.7", "Server 0.9" [COMMUNITY-CLAIM] |
| Repo activity | created 2023-08-17; last push 2026-05-04; 88 stars; 8 open issues (at access date) |
| Supported Windows (from code) | Script.bat writes BCD description "SapphireOS 10 22H2" [IMPLEMENTED]; src/Regs/SapphireOS.reg sets OEM Model "SapphireOS 11" [IMPLEMENTED]; issue #7 lists Win10/Win11/Server ISOs [COMMUNITY-CLAIM] |
| Dependencies (ISO src tree) | Bundled 7-Zip 26.00, Dism++ 10.1.1002.1B, VisualCppRedist AIO installers 2005–2022, .NET Desktop Runtime 8.0.23, NSudo/MinSudo/PowerRun-style TrustedInstaller tools, DevManView (NirSoft), InSpectre.exe (GRC), NVCleanstall 1.18.0, nvidiaProfileInspector, RadeonSoftwareSlimmer (ships a .pdb), CRU, Autoruns.exe (Sysinternals), hidusbf polling-rate driver (SweetLow), SCEWIN 5.05.01.0002 (AMI, with `amifldrv64.sys`/`amigendrv64.sys` kernel drivers), closed-source `SapphireOSPostInstall.exe` |
| Key URLs inspected | `api.github.com/repos/HickerDicker/SapphireOS` (+ `/contents/`, `/git/trees/main?recursive=1`, `/issues?state=all`, `/issues/10/comments`); raw fetches: `/main/README.md`, `/main/src/Modules/Script.bat`, `/main/src/PreInstall/backup.bat`, `/main/src/PreInstall/disable-process-mitigations.bat`, `/main/src/PreInstall/PreinstallScript.bat`, `/main/src/Regs/SapphireOS.reg` |

### Repository structure (from full git tree) [IMPLEMENTED]
```
LICENSE, README.md
src/Fonts/               (17 Josefin Sans TTFs)
src/Modules/Script.bat   (main post-install script, 22.6 KB)
src/PostInstall/         (AntiCheat DEP bats, GPU AMD/Nvidia bats+exes, Mitigations/InSpectre.exe,
                         Others/* revert pairs, Resync, Services/*.reg, Tweaks/* incl. ReservedCpuSets.exe,
                         Interrupt Affinity Policy Tool.exe, MSI Mode Utility.exe, hidusbf, SCEWIN, CRU, Autoruns…)
src/PostScript/SapphireOSPostInstall.exe (462 KB, closed binary)
src/PreInstall/          (PreinstallScript.bat, privacy-script.bat 94 KB, disable-process-mitigations.bat,
                         disable-scheduled-tasks.ps1, minimal-services.ini, backup.bat, SapphireOS.pow,
                         Dism++10.1.1002.1B/, VisualCPPAIO/, 7z2600-x64.exe, service-list-builder/)
src/Regs/SapphireOS.reg  (30.4 KB main registry file)
```
The repo contains the ISO build sources but **not** the built ISOs; ISOs are Discord-gated [DOCUMENTED, README].

### Findings by area

**License / reuse of others' work (recorded exactly as observed)**
- [IMPLEMENTED] Root LICENSE is a single GPL-3.0 text (35,149 bytes — matches canonical GPLv3;
  GitHub API license `gpl-3.0`). The same LICENSE blob is used in SapphireOS-Playbook.
- [IMPLEMENTED] The tree bundles many third-party binaries with their own licenses, and there is
  **no THIRD-PARTY-NOTICES file** aggregating them. Only one bundled license file was seen:
  `src/PostInstall/GPU/AMD/radeon software slimmer/7-Zip/License.txt` (7-Zip's own LGPL/BSD-style
  text) and a `hidusbf/SweetLow.CER` certificate file. Bundled tools observed: DevManView (NirSoft
  freeware), Autoruns.exe (Sysinternals EULA), InSpectre.exe (GRC freeware), NVCleanstall
  (TechPowerUp), nvidiaProfileInspector, CRU (ToastyX), NSudo/MinSudo, PowerRun, Dism++
  (Chuyu Team), SCEWIN (AMI) with two kernel-mode drivers. Whether each redistributor license
  permits this bundling was not assessed — the observation is that GPL-3.0 is declared globally
  while proprietary-licensed third-party binaries are committed alongside it.
- [IMPLEMENTED] `SapphireOSPostInstall.exe` and `SapphireTool.exe` (in the Playbook repo) are
  closed-source binaries; `SapphireTool.pdb` is committed. Issue #10 (2025-07-24) alleges
  "junk Trojans and miners" in SapphireOS/SapphireTool; the comment thread shows **no evidence
  provided** and community/maintainer pushback [COMMUNITY-CLAIM, unverified]. The ISO binaries
  are not auditable from this repo (Discord-only distribution), so the claim can be neither
  confirmed nor refuted from public source.

**Windows build compatibility approach**
- [IMPLEMENTED] The ISO repo has no build guard logic beyond version-named ISOs; Script.bat is
  hardware-adaptive but not build-adaptive. `disable-process-mitigations.bat` uses
  `PowerShell Set-ProcessMitigation -System -Disable CFG` as an availability probe
  ("error: unsupported windows version" on failure), then derives the mitigation mask length
  from the live system (version-adaptive, see snippet below).
- [IMPLEMENTED] The Playbook (separate repo) gates by build list in `playbook.conf` (see Project 2).

**Registry modifications observed (src/Regs/SapphireOS.reg + Script.bat + PreinstallScript.bat)** [IMPLEMENTED]
- `HKLM\...\Policies\System: EnableLUA=0` (UAC fully off in the base image .reg)
- `PriorityControl: Win32PrioritySeparation=0x2a` (42); `Multimedia\SystemProfile: SystemResponsiveness=0x0a`
- `Session Manager\kernel: DisableExceptionChainValidation=1`
- `Memory Management: FeatureSettingsOverride/…Mask` not in this file; Spectre/Meltdown handled via
  mask method in `disable-process-mitigations.bat` and IFEO per-image MitigationOptions for
  fontdrvhost, dwm, lsass, svchost, WmiPrvSE, winlogon, csrss, audiodg, ntoskrnl, services
  (PreinstallScript.bat)
- IFEO `debugger=noop.exe` hijacks: DeviceCensus.exe, CompatTelRunner.exe, AggregatorHost.exe
- IFEO PerfOptions: csrss CpuPriorityClass=3/IoPriority=3; fontdrvhost, lsass, sihost, sppsvc =1;
  ctfmon, SearchIndexer, OriginWebHelperService, ShareX, EpicWebHelper, UplayWebCore,
  SocialClubHelper, steamwebhelper =5
- `DeviceInstall\Settings: DisableSystemRestore=1` — **disables System Restore**
- `Session Manager: DisableWpbtExecution=1`; LLMNR `EnableMulticast=0`; `Lsa: RestrictAnonymous=1`;
  `LanmanServer: RestrictNullSessAccess=1`; `Kernel DMA Protection: DeviceEnumerationPolicy=0`
- Windows Update frozen via `UpdatePolicy\PolicyState` / `UX\Settings` with **hardcoded timestamps**
  (`PauseQualityUpdatesEndTime="2050-01-01T10:38:56Z"`, start times `"2021-10-05T16:02:16Z"`)
- `Mouse: RawMouseThrottleDuration=0x14`; mouse acceleration off (`MouseSpeed/Threshold1/2=0`)
- `FTH: Enabled=0`; hibernate/fast-startup off; Superfetch event channels off;
  `WaitToKillAppTimeOut/HungAppTimeout/WaitToKillServiceTimeout=2000`
- Code-quality note [IMPLEMENTED]: SapphireOS.reg contains duplicated contradictory sections —
  it sets `BackgroundAccessApplications: GlobalUserDisabled=1` early and `=0` later in the same
  file ("Disable Background Apps" block).

**Services / devices / BCD (Script.bat, PreinstallScript.bat)** [IMPLEMENTED]
- BCD: `nx AlwaysOff` (DEP fully off), `disabledynamictick yes`, **`useplatformtick yes`**,
  `/deletevalue useplatformclock`, `bootmenupolicy legacy`, `hypervisorlaunchtype off`,
  `integrityservices disable`, `isolatedcontext No`, **`loadoptions DISABLE-LSA-ISO,DISABLE-VBS`**,
  `vsmlaunchtype Off`, `vm no`, `/timeout 3`; volume label renamed to "SapphireOS"
- ~250 services/drivers set to `Start=4` via MinSudo TrustedInstaller loop (PreinstallScript.bat),
  including `Tcpip6`, `tcpipreg`, `NetBIOS`, `NetBT`, `VSS` (Volume Shadow Copy), `WaaSMedicSvc`,
  `WSearch`, `SysMain`, `Themes`, `Spooler`, `LanmanServer/Workstation`, `cdrom/cdfs/udfs`,
  `lfsvc`, `FontCache`, all Hyper-V/VM services, `SecurityHealthService`, `WarpJITSvc`
- Device-class filter drivers wiped: `UpperFilters`/`LowerFilters` set empty for classes
  `{4d36e96c…}` (hdc), `{6bdd1fc6…}`, `{ca3e7ab9…}`, `{4d36e967…}` (disk), `{71a27cdd…}` (volume);
  `Dhcp/Dnscache DependOnService` rewritten
- DevManView disables devices: **High precision event timer (HPET)**, **System Timer**,
  **Programmable Interrupt Controller**, **Numeric Data Processor**, **Intel Management Engine**,
  **AMD PSP**, **Intel SMBus**, PCI Encryption/Decryption Controller, PCI (standard RAM/Memory)
  Controller, WAN Miniports (all), COM1, Radio Device Enumeration Bus, GS Wavetable Synth,
  Microsoft Device Association Root Enumerator, RRAS Root Enumerator
- CPU microcode update DLLs renamed to `.old` via MinSudo (`mcupdate_GenuineIntel.dll`,
  `mcupdate_AuthenticAMD.dll`) — blocks future microcode updates until renamed back
- `VulnerableDriverBlocklistEnable=0` ("RW Fix for w11") — disables Microsoft's vulnerable-driver
  blocklist so driver-level tools work
- NIC sweep over class `{4d36e972…}`: ~45 adapter values (EEE/GreenEthernet/GigaLite/ULPMode/
  FlowControl/InterruptModeration/ITR/RSS/WoL/SelectiveSuspend variants) zeroed/disabled;
  `Disable-NetAdapterBinding … ms_tcpip6` (drops IPv6 binding on all adapters) plus
  ms_lldp, ms_lltdio, ms_implat, ms_rspndr, ms_server, ms_msclient, vmware_bridge
- netsh: rss=enabled, timestamps=disabled, dca/netdma=enabled (netdma is a legacy/removed
  setting on current builds), initialRto=2000, icw=10
- MSI mode forced on for all PCI USB/Video/Network/IDE controllers; interrupt `DevicePriority`
  values deleted/created undefined; **VMware special case**: if `Win32_ComputerSystem.Manufacturer`
  = VMWare, sets DevicePriority=2 on all PCI NICs
- `Disable-MMAgent -MemoryCompression`
- Script ends with `shutdown -r -t 60`, a `msg *` warning, temp cleanup, and **self-deletes**
  (`start /b "" cmd /c del "%~f0"`)

**CPU/topology/scheduling specifics (NX19-relevant)**
- [IMPLEMENTED] Scheduling knobs are **global, not per-core**: Win32PrioritySeparation=0x2a,
  SystemResponsiveness=10. No CPU-set, no affinity, no core-index logic anywhere in the readable
  SapphireOS sources. No logical-processor-index derivation exists in scripts — nothing to flag
  as hardcoded because nothing computes topology at all.
- [IMPLEMENTED] Desktop/laptop hardware split via `Win32_SystemEnclosure.CassisTypes` (laptop set
  `8 9 10 11 12 13 14 18 21 30 31 32`): laptops keep **Balanced** power plan
  (`381b4222-f694-41f0-9685-ff5bb260df2e`), PowerThrottlingOff=0, serial/wmiacpi services
  re-enabled; desktops get PowerThrottlingOff=1, `DisplayEnhancementService` disabled, and the
  bulk device power-save registry sweep.
- [IMPLEMENTED] Per-process priority shaping only via IFEO `PerfOptions` (list above) and svchost
  isolation: `SvcHostSplitThresholdInKB=0xffffffff` (PreinstallScript) — with the comment
  "works best for all RAM size" (i.e., no RAM-size adaptation, contrary to NEXTRIX aims).
- [IMPLEMENTED] Post-install tooling ships `ReservedCpuSets.exe/.dll`,
  `Interrupt Affinity Policy Tool.exe`, `MSI Mode Utility.exe`, `PowerSettingsExplorer.exe`,
  hidusbf 1k/2–4k/4–8kHz variants — **manual** user-run tools; no scripted CPU-set logic.

**Power settings** [IMPLEMENTED]
- `SapphireOS.pow` power plan (16 KB binary, in src/PreInstall and Playbook `Executables/`),
  imported on desktops under hardcoded GUID `3669b9e3-17ce-4e11-9c13-6e9e0724b157`, then the
  .pow file deleted (Playbook `powerplan.bat`); hibernate off (`powercfg -h off`), Sleep Study
  and Kernel-Processor-Power/UserModePowerService diagnostic logs disabled via wevtutil;
  `MSPower_DeviceEnable=false` WMI sweep; `SleepStudyDisabled=1`, `HiberbootEnabled=0`.

**GPU/hardware-specific logic** [IMPLEMENTED]
- Nvidia post-install bats: `!Disable HDCP.bat`, `!Disable telemetry (Breaks Geforce).bat`,
  `!No ECC.bat`, `!P-State 0.bat`, `!Unrestricted Clock Policy by Cancerogeno.bat`,
  `mpo disable/enable.bat`, NIP profile (`Settings.nip` + nvidiaProfileInspector),
  NVCleanstall 1.18.0
- AMD: `AMD Dwords by imribiy.bat` (17 KB registry batch), `Mpo_disable.reg`
  (`HKLM\SOFTWARE\Microsoft\Windows\Dwm: OverlayTestMode=5` — disables MPO),
  `disable_dx11navi.exe` (7 MB closed binary), RadeonSoftwareSlimmer
- Storage: SSD-vs-HDD `.reg` pair with **opposite values** (`support windows on ssd(Default).reg`:
  Prefetcher/Superfetch=0, SysMain/FontCache Start=4, TRIM notify on;
  `support-windows-on-hdd.reg`: Prefetcher/Superfetch=3, services Start=2, TRIM notify off)
  — a storage-media-aware default pair
- `Write-cache`: `CacheIsPowerProtected=1`, `UserWriteCacheSetting=1` on all SCSI enum devices;
  StorPort `EnableIdlePowerManagement=0`; HIPM/DIPM/HDDParking=0
- Mouse: hidusbf driver 1/2–4/4–8 kHz variants, `MouseTester.exe`, `Mouse Movement Recorder.exe`

**Rollback/undo/backup mechanisms and their limits**
- [IMPLEMENTED] **Service-State export-before-change**: `backup.bat` and `sapphireosservices.bat`
  iterate `HKLM\SYSTEM\CurrentControlSet\Services`, exporting every service's `Start` value to
  `C:\PostInstall\Services\SapphireOS-Default-services.reg`; PreinstallScript.bat writes
  `Windows-Default-services.reg` the same way before disabling. Limits: only the `Start` value is
  captured — not other service properties, not device state, not registry tweaks, not files.
- [IMPLEMENTED] Shipped revert pairs in PostInstall: `Windows-Default-services.reg`,
  `SapphireOS-Default-services.reg`, `minimal-services.reg` (note: in the Playbook the
  "SapphireOS-Default" file is generated at install time by sapphireosservices.bat, not a static
  pristine copy); `EnableDefender.ps1/EnableDefenderServices.bat` vs disable pair;
  `exes enable.bat` vs `exes.bat` (renames ctfmon.exe/TextInputHost.exe/backgroundTaskHost.exe
  to `.exee` — reversible by renaming back); DEP NX trio (AlwaysOff default / optin for
  Valorant / `bcdedit /deletevalue nx` for FACEIT); `Enable/Disable SerializeTimerExpiration.reg`
  (=2 / =1); `Enable/Disable DMA Remapping.bat`; `bootmenupolicy` pair; Alt-Tab pair;
  Action Center pair; `mpo enable/disable.bat`; SSD/HDD pair; `Revert Network Tweaks.bat`;
  `Run this if you had to install a network driver.bat` (10 KB re-apply helper);
  `resync.bat` (temporarily enables w32time, resyncs, re-disables)
- [IMPLEMENTED] **Rollback limits baked in**: `DisableSystemRestore=1` (SapphireOS.reg) +
  `\Microsoft\Windows\SystemRestore\SR` scheduled task disabled; `VSS` service disabled;
  BitLocker decrypted (Playbook `Bitlocker.ps1` disables BitLocker on every drive with a `pause`
  per volume); BCD `recoveryenabled no` + `disableelamdrivers yes` (Playbook commands.yml);
  `CrashDumpEnabled=0`, `LogEvent=0` (Playbook registry.yml); microcode DLLs renamed (renamable
  but undocumented to users); Script.bat self-deletes; smartscreen.exe renamed to `.old`
  (renamable); the ISO itself ships without Windows recovery/backup-restore per README.
- Summary: SapphireOS undo story = services + selected toggles only; the OS's own recovery
  features (System Restore, VSS, WinRE checks, crash dumps) are deliberately disabled.

**Known compatibility issues** [COMMUNITY-CLAIM unless noted]
- README "Unsupported" lists (both editions) [DOCUMENTED]: BitLocker, Windows Defender, Windows
  Update, Windows recovery, OOBE (default), biometrics, Windows Backup/Restore Points, OneDrive,
  Cortana; Ultralite adds: Hyper-V, VBS, printing, spell checking, search indexing, mixed reality,
  speech recognition ("may break games like Hogwarts Legacy and phasmophobia iirc"), IME
  (CJK/Korean input), 57-bit linear addressing, touch screens, kernel debugging; "Some Drivers on
  Windows Server … Like AMD Video Drivers and Some Network Drivers"
- Issue #8 (2025-03-22): touchpad disable ineffective — "changes the value of
  PrecisionTouchPad\Status to 0 in regedit but it still works"
- Issue #10 (2025-07-24): "Trojans and miners" accusation with no evidence provided in-thread
- Issues #11/#13/#15 (2025–2026): recurring complaints that downloads are gated behind Discord
  verification/captchas and account-age checks
- PRs #1–3 (2023, closed unmerged): titled "Defender is stripped…" corroborating Defender removal

### Useful ideas for NEXTRIX
1. **Export-before-change service backup** (backup.bat pattern): snapshot `Start` values of every
   service to a dated .reg before any service modification. [IMPLEMENTED origin; trivially portable]
2. **Toggle pairs shipped with the install** (DEP NX trio, SerializeTimerExpiration, DMA remapping,
   SSD/HDD, MPO, Action Center, network revert) — every risky tweak gets a named, user-runnable
   inverse. The DEP trio even encodes anticheat compatibility knowledge (FACEIT needs DEP on;
   Valorant works with optin).
3. **Chassis-type desktop/laptop split** (`Win32_SystemEnclosure.ChassisTypes`) with laptop =
   Balanced plan + throttling kept, desktop = aggressive plan. A cheap, robust hardware guard.
4. **Storage-media-aware reg pair** (SSD vs HDD with opposite prefetch/TRIM values).
5. **Version-adaptive mitigation mask** (see snippet): derives mask length from the live system
   instead of hardcoding — more robust across Windows builds than Vain's fixed 45-byte mask.
6. **Temporary enable→act→disable micro-pattern** (resync.bat): turns a service on, performs one
   action, restores disabled state.
7. **VMware/vendor special-casing** of interrupt DevicePriority shows a precedent for
   virtualization guards before applying interrupt tweaks.

Snippet (9 lines, GPL-3.0, https://raw.githubusercontent.com/HickerDicker/SapphireOS/main/src/PreInstall/disable-process-mitigations.bat)
— version-adaptive mitigation mask:
```bat
:: get current mask
for /f "tokens=3 skip=2" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" /v "MitigationAuditOptions"') do (
    set "mitigation_mask=%%a"
)
:: set all values in current mask to 2 (disable all mitigations)
for /L %%a in (0,1,9) do (
    set "mitigation_mask=!mitigation_mask:%%a=2!"
)
```
(Quoted as evidence of the *technique* only; NEXTRIX would invert its purpose — the same
derivation pattern works for restoring an original mask.)

### Reject / caution for NEXTRIX
1. **`bcdedit /set nx AlwaysOff` as default** — full DEP off breaks anticheats and removes a core
   exploit mitigation; Vain chose `optin` instead. Reject as a default; keep DEP optin or on.
2. **`useplatformtick yes` + deleting `useplatformclock` + disabling the HPET device and System
   Timer device** — timer forcing is motherboard/firmware-sensitive; SapphireOS itself ships it as
   a toggle, evidence there is no universally safe value. NEXTRIX should detect/measure, not force.
3. **Disabling the vulnerable-driver blocklist** (`VulnerableDriverBlocklistEnable=0`) — done so
   NSudo/SCEWIN-class tools work; NEXTRIX must not ship kernel-driver tools that require this,
   and must not disable the blocklist.
4. **Renaming CPU microcode update DLLs to `.old`** — permanently blocks security microcode;
   reject outright.
5. **`Tcpip6` service + IPv6 adapter binding removal** — breaks IPv6 entirely; reject.
6. **Wiping storage device-class UpperFilters/LowerFilters** — risks breaking filter-driver
   stacks (e.g., laptop storage filters); reject without per-class allowlisting.
7. **Hardcoded WU freeze timestamps (`2050-01-01`)** and hardcoded power-plan GUID — brittle;
   reject in favor of computed dates/dynamic GUIDs.
8. **Discord-gated, non-auditable ISO distribution** — the model NEXTRIX must not copy: unverifiable
   binaries + unresolved malware accusations (issue #10) are exactly what a rollback-safe,
   transparent playbook must avoid.
9. **GPL-3.0 declared over a tree of proprietary third-party binaries with no notices** — if
   NEXTRIX bundles tools, per-file licensing and a THIRD-PARTY-NOTICES file are mandatory.

### Research limitations (Project 1)
- The actual ISO images are Discord-only; the removals baked into the ISO (the "Ultralite"
  component stripping) could not be inspected — only the in-repo scripts were read.
- `src/PreInstall/privacy-script.bat` (94 KB) and `Executables/EDGE.ps1` (22 KB) were not fetched
  (budget); `SapphireOSPostInstall.exe`, `SapphireTool.exe`, `disable_dx11navi.exe`,
  `SapphireOS.pow`, `NoDefender.cab` are binaries not inspectable as text.
- Script.bat calls `%WINDIR%\Modules\disable-process-mitigations.bat` — a file baked into the ISO
  that is NOT present in the repo (repo only has the PreInstall copy); the ISO-baked variant may differ.
- Discord content (actual ISO links, guides) was not accessed (login-gated).

---

## Project 2 — SapphireOS-Playbook (HickerDicker/SapphireOS-Playbook)

### Identity table

| Field | Value |
|---|---|
| Name | SapphireOS Playbook |
| Repo | https://github.com/HickerDicker/SapphireOS-Playbook (default branch `main`) |
| Type | AME Wizard playbook (`.apbx`) applying SapphireOS-style tweaks to an existing install |
| License | LICENSE file identical blob to SapphireOS (`f288702d…`, GPL-3.0). Same caveat: bundles third-party binaries (DevManView, Autoruns, CRU, NSudo, InSpectre, NVCleanstall, RadeonSoftwareSlimmer, hidusbf, SCEWIN, PowerRun.exe, SapphireTool closed binary, NoDefender.cab) with no aggregated notices [IMPLEMENTED] |
| Latest release | **None** (`/releases/latest` 404). `playbook.conf` declares `<Version>0.0.1</Version>` [IMPLEMENTED] |
| Repo activity | created 2026-05-17, pushed same day (snapshot); 3 stars; 0 issues |
| Supported Windows (code-checked) | `playbook.conf` `<SupportedBuilds>`: **19044, 19045, 22621, 22631, 26100, 26200** → Win10 21H2/22H2, Win11 22H2/23H2/24H2/25H2 [IMPLEMENTED] |
| Requirements (AME Wizard) | `DefenderToggled`, `NoAntivirus`, `Internet`, `PluggedIn`; `UseKernelDriver=false` [IMPLEMENTED] |
| Dependencies | AME Wizard; .NET Desktop Runtime 8.0.20 downloaded at install from `builds.dotnet.microsoft.com`; abbodi1406 VisualCppRedist_AIO v0.101.0 from GitHub; Open-Shell 4.4.198 (option); PowerRun.exe for TrustedInstaller |
| Key URLs inspected | `api.github.com/repos/HickerDicker/SapphireOS-Playbook` (+ `/git/trees/main?recursive=1`); raw: `/main/playbook.conf`, `/main/Configuration/custom.yml`, `/main/Configuration/SapphireOS/FinalTasks.yml`, `/main/Configuration/SapphireOS/debloat/{components,appx}.yml`, `/main/Configuration/SapphireOS/tweaks/{commands,registry,services,ScheduledTasks}.yml`, `/main/Configuration/SapphireOS/tweaks/DISABLEDEFENDER.bat`, `/main/Executables/{powerplan.bat,svchost.ps1,Bitlocker.ps1,DisableDefender.ps1,filters.bat,sapphireosservices.bat}`, `/main/Executables/PostInstall/…` (AntiCheat bats, Drives regs, SerializeTimerExpiration regs, resync.bat, exes.bat, GPU/AMD Mpo_disable.reg, Auto DSCP & FSE.bat) |

### Repository structure [IMPLEMENTED]
```
.gitattributes, LICENSE, playbook.conf
Configuration/custom.yml                (task order)
Configuration/SapphireOS/
  FinalTasks.yml                         (cache clear, wallpaper, powerplan.bat, DISM reserved-storage off)
  debloat/{appx.yml, components.yml}
  tweaks/{registry.yml (80 KB), services.yml, commands.yml, ScheduledTasks.yml, DISABLEDEFENDER.bat}
Executables/                             (PowerRun.exe, SapphireOS.pow, SapphireTool/, NoDefender.cab,
                                         Windows/Web/Sapphire wallpaper, DisableDefender pair,
                                         EDGE.ps1, svchost.ps1, Bitlocker.ps1, WALLPAPER.ps1, …)
Executables/PostInstall/                (user-facing toggle kit copied to C:\PostInstall)
```
Execution order (custom.yml): registry.yml → services.yml → commands.yml → components.yml →
appx.yml → ScheduledTasks.yml → FinalTasks.yml [IMPLEMENTED].

### Findings by area

**Option model (playbook.conf)** [IMPLEMENTED]
- Checked-by-default: `disable-defender`, `remove-edge`, `remove-onedrive` (i.e., Defender removal
  is the default path); unchecked: `disable-uac`, `disable-process-mitigations`,
  `disable-spectre-meltdown`, `disable-hyperv` (labeled "Disable Hyper-V and VBS"), `disable-wu`,
  `disable-print`, `disable-bluetooth`, `disable-vpn`, `disable-powersave`, dark mode, legacy
  context menu, photo viewer swap, Open-Shell.
- AME Wizard `<Requirements>` includes `DefenderToggled` — the user must have manually toggled
  Defender off before the playbook runs (matches the Vain flow).

**Registry modifications (registry.yml, 596 lines)** [IMPLEMENTED]
- Same core set as Project 1 (Win32PrioritySeparation=42, SystemResponsiveness=10, FTH off,
  IFEO taskkill.exe hijacks, consent-store Deny-all, ATMFD=1, hibernate off) **plus playbook-only**:
  - `HKLM\SOFTWARE\Microsoft\Ole: EnableDCOM='N'` — **DCOM disabled system-wide**
  - `GraphicsDrivers: HwSchMode=2` under the comment "Disable Hardware Accelerated GPU
    Scheduling" — the value `2` *enables* HAGS; comment contradicts value [IMPLEMENTED inconsistency]
  - `CrashControl: CrashDumpEnabled=0, LogEvent=0, StorageTelemetry DeviceDumpEnabled=0`
  - `BitLocker: PreventDeviceEncryption=1`; `DeliveryOptimization: DODownloadMode=100` (bypass);
    ReadyBoost off; `DisableExceptionChainValidation=1`
  - Autologger `Start=0` for ~27 sessions (written to `ControlSet001` directly, not
    CurrentControlSet)
  - WU freeze block identical to SapphireOS.reg incl. hardcoded `2021-10-05`/`2050-01-01`
    timestamps, all `option: 'disable-wu'`
  - VBS: `DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity Enabled=0` (option disable-hyperv);
    Spectre/Meltdown: `FeatureSettingsOverride=3`, `…Mask=3` (option disable-spectre-meltdown);
    UAC: `EnableLUA=0` (option disable-uac)
  - SapphireTool state keys (`HKCU\SOFTWARE\SapphireTool`): Win32PrioritySeparation,
    DisableDefender, DisableBluetooth, DisableVPN, DisablePrinter, DisableHyperV,
    DisableNotifications, DisableDCOM, ActionCenter, DisablePrefetch, Services — a
    closed-source GUI consumes these
  - COM hardening `Ole\AppCompat: RequireIntegrityActivationAuthenticationLevel=1` (one of the few
    genuinely hardening values present)

**Services (services.yml + helpers)** [IMPLEMENTED]
- ~200 `!service {…, startup: 4}` entries, option-gated subsets (print/bluetooth/vpn/powersave);
  includes `Tcpip6`, `VSS`, `WaaSMedicSvc`, `SysMain`, `Themes`, `WSearch`, all Hyper-V set,
  `SecurityHealthService`, `edgeupdate`, `WSAIFabricSvc`
- `svchost.ps1`: enumerates every service under `HKLM\SYSTEM\CurrentControlSet\Services`
  **excluding names matching `Xbl|Xbox`** and sets `SvcHostSplitDisable=1` — gaming services
  deliberately spared; also `SvcHostSplitThresholdInKB=0xffffffff` elsewhere
- `filters.bat`: same class-filter wipe + DependOnService rewrites as Project 1
- `Bitlocker.ps1`: `Disable-BitLocker` on every drive letter (interactive `pause` per drive)
- `sapphireosservices.bat`: regenerates `SapphireOS-Default-services.reg` from the current
  (already-tweaked?) machine state — as shipped in this repo's flow it runs *during* services.yml,
  i.e., the "default backup" is a point-in-time snapshot, not necessarily pristine

**Scheduled tasks (ScheduledTasks.yml, TrustedInstaller)** [IMPLEMENTED]
- ~80 tasks disabled, incl. `\Microsoft\Windows\WindowsUpdate`, UpdateOrchestrator set
  (Schedule Scan/Wake/USO_UxBroker/Start Oobe Expedite), `WaaSMedic`, `.NET Framework NGEN`
  (all 4), `Defrag\ScheduledDefrag`, `WinSAT`, MemoryDiagnostic pair, CEIP, `MareBackup`,
  Compatibility Appraiser, `Diagnosis\Scheduled`, **`\Microsoft\Windows\SystemRestore\SR`** and
  **`\Microsoft\Windows\Registry\RegIdleBackup`** (both rollback-relevant), Time Synchronization
  pair, `SilentCleanup`, StorageSense, maps/input-sync tasks.

**Defender / security (commands.yml, DISABLEDEFENDER.bat, DisableDefender.ps1, DisableDefenderServices.bat)** [IMPLEMENTED]
- commands.yml runs everything at `privilege: TrustedInstaller`
- BCD: description "SapphireOS", `bootmenupolicy Legacy`, `disabledynamictick yes`,
  **`recoveryenabled no`**, **`disableelamdrivers yes`**, `integrityservices disable`,
  hypervisor/vm/vsmlaunchtype off (option), `powercfg -h off`, `label %systemdrive% SapphireOS`
- DISABLEDEFENDER.bat: `Set-MpPreference -DisableRealtimeMonitoring 1`; PowerRun sets Start=4 on
  WinDefend, Sense, Wd* set, MsSec*, SgrmAgent/Broker, webthreatdef*, MDCoreSvc, wscsvc,
  SecurityHealthService; deletes SecurityHealth Run key; kills smartscreen.exe and
  **renames it to smartscreen.exe.old (copy kept — reversible, unlike Vain)**;
  `PUAProtection=0`; **`CI\Config: VulnerableDriverBlocklistEnable=0`**;
  `CI\Policy: VerifiedAndReputablePolicyState=0` (Smart App Control off); HVCI Enabled=0;
  disables the 4 Windows Defender scheduled tasks
- DisableDefender.ps1: installs `C:\Windows\NoDefender.cab` via `Add-WindowsPackage -Online`,
  verifies the cab's Authenticode cert has EKU `1.3.6.1.4.1.311.10.3.6`, and **permanently adds
  the signer cert `8A334AA8…` to the Trusted Root store** ("isn't cleared later as it's required
  for the alt repair source") — a persistent trust-anchor change
- Re-enable pair exists (`EnableDefender.ps1` 124 B, `EnableDefenderServices.bat`) — likely
  restores Start values/realtime setting; not fetched (budget), so exact restore semantics unverified

**Power (FinalTasks.yml + powerplan.bat)** [IMPLEMENTED]
- Chassis split (same as Project 1); desktops import `SapphireOS.pow` under GUID
  `3669b9e3-17ce-4e11-9c13-6e9e0724b157` then delete the .pow file; laptops get Balanced plus
  processor subgroup `{54533251…}\{4d2b0152…}` = 5000 on AC/DC
- `DISM /Online /set-reservedstoragestate /state:disabled`; appx cache clears for CBS,
  StartMenuExperienceHost, Windows.Search, TCUI

**Per-game QoS tool (Auto DSCP & FSE.bat)** [IMPLEMENTED]
- Interactive, run after games are installed: asks a profile name + picks the game EXE via an
  embedded PowerShell file dialog; writes `HKLM\SOFTWARE\Policies\Microsoft\Windows\QoS\<profile>`
  (Application Name, DSCP Value=46, Throttle Rate=-1, wildcards elsewhere); FSE via
  `AppCompatFlags\Layers: "<exe>"="~ DISABLEDXMAXIMIZEDWINDOWEDMODE HIGHDPIAWARE"`; optional
  `GpuPreference=2` (dGPU). A clean example of per-game, opt-in profiles.

**Rollback/undo and limits** [IMPLEMENTED]
- The whole `Executables/PostInstall` tree is copied to `C:\PostInstall` (services.yml) — a
  user-facing revert kit (pairs listed under Project 1). Plus service Start exports
  (`sapphireosservices.bat`, `defaultservices.bat`) and `Windows-Default-services.reg` shipped.
- Limits: same as Project 1 — SystemRestore\SR task + RegIdleBackup disabled by this very
  playbook, WinRE `recoveryenabled no`, ELAM drivers disabled, crash dumps off, DCOM off
  (no inverse shipped), root cert added (no removal step shipped), NoDefender.cab left installed,
  TrustedInstaller-level writes with no manifest of what changed.

**Known compatibility issues**
- 0 open issues [IMPLEMENTED, API]. No release notes exist. Nothing else to report; the parent
  ISO project's issues (Project 1) apply contextually.

### Useful ideas for NEXTRIX
1. **AME Wizard option gating with sane defaults**: Defender removal pre-checked but UAC/VBS/
   Spectre mitigations *not* pre-checked — the riskiest security items are opt-in, unlike Vain
   where everything is default-on.
2. **Per-game opt-in QoS profile generator** (Auto DSCP & FSE.bat) — NEXTRIX's NX19-adjacent
   network category could adopt "profile per game EXE, DSCP 46, FSE compatibility flag".
3. **Xbox/Xbl exclusion when sweeping services** (svchost.ps1) — gaming workloads deliberately
   protected during bulk changes.
4. **State registry** (`HKCU\SOFTWARE\SapphireTool`) recording which options were applied — a
   cheap machine-readable manifest for later undo (though here it feeds a closed tool).
5. **Requirements pre-flight** (`DefenderToggled`, `PluggedIn`, `Internet`) as a compatibility gate.

### Reject / caution for NEXTRIX
1. **TrustedInstaller as the blanket privilege for the entire commands file** — over-privilege;
   each step should use the least privilege that works.
2. **`recoveryenabled no` + `disableelamdrivers yes`** — both strip recovery/security layers;
   reject.
3. **Permanent test root certificate in the Trusted Root store** (DisableDefender.ps1) — a
   lasting attack-surface widening; reject; if a cab must be installed, remove the cert afterwards.
4. **`EnableDCOM='N'`** — system-wide DCOM off breaks RPC/COM software with no inverse shipped.
5. **Comment/value contradiction on HwSchMode** ("Disable…" while setting enable value 2) —
   exemplifies why NEXTRIX needs machine-verifiable semantics for every write.
6. **Writing to `ControlSet001` directly** (autologgers, some values) instead of
   CurrentControlSet — brittle if the active control set differs.
7. **Bulk service disable incl. `Tcpip6`, `VSS`, `WaaSMedicSvc`** without hardware/env checks —
   IPv6, shadow copies and update remediation are casualties.
8. **Floating downloads at install time** (.NET runtime, vcpp AIO, Open-Shell) with no hash
   pinning — supply-chain risk for a "rollback-safe" tool.

### Research limitations (Project 2)
- `EDGE.ps1` (22.8 KB), `WALLPAPER.ps1`, `defaultservices.bat`, `disable-write-cache-buffering.bat`,
  `disable-netbios.bat`, `disable-powersavings.bat`, `EnableDefender.ps1`, `exes enable.bat`,
  `AMD Dwords by imribiy.bat`, `NIP/Settings.nip`, `NoDefender.cab` and the two big service .reg
  exports (62–64 KB) were not fetched (size/budget); their exact contents are unverified.
- The repo has no releases/issues, so "known compatibility issues" evidence is limited to the
  parent project.
- AME Wizard itself (amelabs.net) was not reviewed; playbook semantics (`!registryValue`,
  `builds:` filters, `option:` gating) were inferred from the YAML as used by these repos.

---

## Project 3 — Vain-Playbook (flashhez/Vain-Playbook) — SPECIAL ATTENTION: NX19 CPU/topology/scheduling

### Identity table

| Field | Value |
|---|---|
| Name | Vain Playbook (vendor: VAIN, site vain.zone; team "flash and p467121") |
| Repo | https://github.com/flashhez/Vain-Playbook (default branch `main`) |
| Type | AME Wizard overhaul playbook ("Sets up a fresh Windows 11 install for games, with Vain Tools") |
| License | **Custom proprietary-style** `LICENSE.txt`: "Copyright (c) 2024-2026 VAIN. All rights reserved." Free to use on any number of computers; distribution only via the official page; no modified-form distribution; no charging for install services. GitHub API: `Other / NOASSERTION` [IMPLEMENTED]. Third-party code is properly quarantined: `THIRD-PARTY-NOTICES.txt` lists **PS-SFTA (MIT, Danysys 2022)** and **RunAsTI (MIT, AveYo 2021)** with full MIT texts and per-file mapping (`Executables\SetFileTypeAssociation.ps1`, `Executables\RunAsTi.reg`) [IMPLEMENTED] |
| Latest release | **v2.0.0** — "Vain Playbook 2.0.0", published **2026-11-15**. Assets: `Vain-Playbook-v2.0.0.apbx` (10,209,103 B, sha256 `95c10b49…`, 2,539 downloads) and `Disable.Automatic.Updates.reg` (799 B, 2,474 downloads) [IMPLEMENTED, API]. First release on GitHub |
| Repo activity | created 2026-11-15, last push 2026-11-15; 4 stars; 0 open issues |
| Supported Windows (code-checked) | `playbook.conf` `<SupportedBuilds>`: **22631, 26100, 26200, 26300, 28000** (Win11 23H2/24H2/25H2/26H2 + 28000 dev channel) [IMPLEMENTED]. vain.zone guide: "W11 23H2, 24H2, 25H2, or 26H2 ISO" [DOCUMENTED] |
| Requirements | `DefenderToggled`, **`DefenderDisabled`**, `NoAntivirus`, `NoPendingUpdates`, `PluggedIn`, **`FreshInstall`**, `Internet`; `Overhaul=true`; `UseKernelDriver=false`; `EstimatedMinutes=5` [IMPLEMENTED] |
| Dependencies | AME Wizard (amelabs.net); Vain Tools downloaded at run time from `https://raw.githubusercontent.com/flashhez/VainTools/main/VainUpdater.exe` and run `/silent` (unpinned, no hash) [IMPLEMENTED]; VC++ runtimes, DirectX, 7-Zip and the chosen browser downloaded from publishers during install [DOCUMENTED]. Browsers "require AVX2" [DOCUMENTED, playbook.conf] |
| Key URLs inspected | `api.github.com/repos/flashhez/Vain-Playbook` (+ `/git/trees/main?recursive=1`, `/releases/latest`); raw: `/main/playbook.conf`, `README.md`, `CHANGELOG.md`, `LICENSE.txt`, `THIRD-PARTY-NOTICES.txt`, `Build.bat`, `Disable Automatic Updates.reg`, `Executables/hosts`, `Configuration/custom.yml`, `Configuration/vain/{01-setup,02-security,03-apps–04-debloat listed,05-services,06-performance,07-scheduled-tasks,08-tweaks,11-system,12-finalize,13-network}.yml`; `api.github.com/repos/flashhez/VainTools/git/trees/main?recursive=1`; raw `VainTools/main/README.md`, `VainTools/main/vain/LICENSE.txt`; `https://vain.zone/guide-playbook.html` |

### Repository structure [IMPLEMENTED]
```
Build.bat, CHANGELOG.md, LICENSE.txt, THIRD-PARTY-NOTICES.txt, README.md, playbook.conf, playbook.png
Disable Automatic Updates.reg          (standalone WU-off reg, applied before going online)
Configuration/custom.yml               (task order: 01…13, network LAST)
Configuration/vain/01-setup.yml … 13-network.yml   (13 ordered task files, ~313 KB total YAML)
Executables/  hosts, vain.pow (24 KB power plan), RunAsTi.reg, SetFileTypeAssociation.ps1,
              blank.ico, user.png, wallpaper.jpg
Images/       browser logos
```
Build.bat packs the `.apbx` with 7-Zip as a zip **with the literal password `malte`**
[IMPLEMENTED, see snippet].

### Findings by area

#### CPU topology / scheduling / Thread Director (NX19 focus)

**A. Kernel-level scheduling knobs (06-performance.yml)** [IMPLEMENTED]
`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel`:
- `Win32PrioritySeparation=36` (0x24) under `PriorityControl`
- `SerializeTimerExpiration=1` (timer-expiration serialization ON — opposite of SapphireOS's
  shipped "disable" toggle)
- `EnablePerCpuClockTickScheduling=1` (per-CPU clock tick distribution)
- `TimerCheckFlags=0`, `InterruptSteeringFlags=1`, `ForceParkingRequested=0`,
  `CacheAwareScheduling=39`, `AlwaysTrackIoBoosting=0`, `ForceEnableMutantAutoboost=1`,
  `ForceBugcheckForDpcWatchdog=0`
- `Multimedia\SystemProfile: SystemResponsiveness=10` (MMCSS reserves 10%)
- `Memory Management: DisablePagingExecutive=1, DisablePageCombining=1, TrackLockedPages=0`
- `Power: HeteroMultiClassParkingEnabled=0` (heterogeneous-core parking off — P/E-core related),
  `IdleProcessorsRequireQosManagement=0`, coalescing values zeroed
  (`CoalescingTimerInterval=0`, `CoalescingFlushInterval=0`, `DeepIoCoalescingEnabled=0`)
- All values are **global**; no per-CPU-index computation appears anywhere in the playbook.

**B. Thread Director — what is verifiable vs not**
- [IMPLEMENTED] `12-finalize.yml` writes per-process rules consumed by Vain Governor under
  `HKCU\Software\VainGovernor\Profiles\1\Rules\<image>.exe`:
  - `ThreadDirector=1` for **36 hardcoded game EXE names** (aces, AimLab_tb, BF2042, bf6, cod,
    cs2, deadlock, DeltaForceClient-Win64-Shipping, Discovery, dota2, EscapeFromTarkov, FC26,
    FortniteClient-Win64-Shipping, FPSAimTrainer, HaloInfinite, HuntGame, League of Legends,
    Marvel-Win64-Shipping, osu!, Overwatch, PioneerGame, Polaris-Win64-Shipping, r5apex,
    r5apex_dx12, RainbowSix, RobloxPlayerBeta, RocketLeague, RustClient, SC2_x64,
    StreetFighter6, tf_win64, TslGame, VALORANT-Win64-Shipping, WorldOfTanks) — in-file comment:
    "1 = Game; the director only starts for a process set to Game".
  - `ThreadDirector=3` ("3 = Background; kept off the games cores, also with no game running")
    for launchers: Battle.net, EpicGamesLauncher, EpicWebHelper, LeagueClient(Ux/Render),
    Riot Client, RiotClientServices, UbisoftConnect, upc, EA set, steam, steamservice,
    steamwebhelper.
  - `BoostEnabled=0` for ~39 background processes (dwm, explorer, svchost, audiodg, ctfmon, lsass,
    winlogon, fontdrvhost, RuntimeBroker, SearchHost, NVIDIA Overlay, NVDisplay.Container,
    msedgewebview2, Discord, gamingservices, WmiPrvSE, …).
  - **Thread-level rules** for dwm.exe: `Threads\0: MatchDescription="DWM Kernel Sensor Thread"`,
  `Threads\1: MatchDescription="DWM Master Input Thread"`, both `Priority=15` — rules match
    threads by description, then set priority 15.
  - `HKCU\Software\VainGovernor: SelectedProfile=1`; Governor GUI refresh 400 ms/tray 3000 ms.
- **HARDCODING FLAG (requested)**: the game/launcher/background lists are **hardcoded EXE-name
  tables in YAML** — no detection, no wildcard, no user extension point in the playbook itself.
- [IMPLEMENTED + critical] The scheduling **engine** — Vain Governor / Thread Director — is
  **closed-source**: the flashhez/VainTools repo contains only compiled binaries
  (`Vain Governor.exe` 903 KB, `Vain Toolbox.exe`, `Vain Start.exe`, `Vain Tools.exe`,
  WinUI DLLs, `dwmcorei.dll`, `dcompi.dll`, `VainUpdater.exe`) and its README states
  "**The source is not public**" [IMPLEMENTED]. Therefore:
  - how logical processor indexes are derived (CPU enumeration vs hardcoded ranges) **cannot be
    verified**;
  - whether CPU Sets (`SetProcessDefaultCpuSets`) or classic affinity masks are used **cannot be
    verified**;
  - release-note claims are [DOCUMENTED], not source-verified: "puts its busiest threads on the
    best cores, gives the heaviest ones cores of their own, and keeps other apps out of their way.
    All of it is undone when the game closes. It works on Intel CPUs with P-cores and E-cores and
    on Ryzen, two-die X3D chips included"; README adds Governor "sets CPU affinity and scheduler
    behaviour per app"; Toolbox "sets interrupt affinity for every device".
  - The vendor's own honesty note is useful evidence of maturity: "It is still in an early beta.
    Depending on the game and the CPU it can help a lot or cost FPS" [DOCUMENTED].
- [IMPLEMENTED] Governor binary is **self-signed**: "The programs are signed with VAIN's own
  certificate, so Windows shows their publisher as unknown" [DOCUMENTED, VainTools README].
- [IMPLEMENTED] VainTools license forbids reverse engineering ("You may not … decompile,
  disassemble or otherwise reverse engineer it") — so the topology question cannot be closed
  even by permitted inspection; recorded as a hard research limit.
- **CPU Sets tooling note**: unlike SapphireOS (ships `ReservedCpuSets.exe`), the Vain playbook
  ships **no** CPU-affinity/CPU-set tool of its own; all scheduling runs through Governor.

**C. Hardware-aware guards observed in the playbook** [IMPLEMENTED]
- `01-setup.yml`/`11-system.yml`: disables ACPI Processor Aggregator, ACPI Thermal Zone, ACPI
  Wake Alarm, "Intel(R) Platform Monitoring Technology Device" (`intelpmt` service also disabled
  in 05-services.yml — Intel-only, enumerated by name).
- `11-system.yml` desktop exception: `$c=(Get-CimInstance Win32_SystemEnclosure).ChassisTypes[0];
  if($c -le 7){ … Disable 'PCI standard ISA bridge', 'Microsoft Windows Management Interface for
  ACPI'; disable WmiAcpi and msisadrv services }` — chassis ≤7 treated as desktop, extra devices
  disabled; simpler and less careful than SapphireOS's explicit laptop list.
- `13-network.yml`: NIC device removal/re-enumeration via `pnputil /remove-device` +
  `/scan-devices` with a 60-s wait loop for adapters to return (`InstanceId -notmatch '^(ROOT|SWD|BTH)\'`
  filter); adapter-key sweeps only write values that already exist on each NIC key
  (`if (Get-ItemProperty … -Name "*EEE")`) — exist-checked per-device writes, not blind creation.
- `06-performance.yml`: a recursive sweep over `HKLM\SYSTEM\CurrentControlSet\Enum` zeroing ~30
  power-management values on **every** device instance (blind bulk; the opposite philosophy).
- Build gating inside actions: `EnforceAusterityMode=0` carries `builds: ['>=26100']` — per-build
  conditional writes are supported by the playbook engine and used at least once [IMPLEMENTED].

#### Registry modifications (other areas)
- [IMPLEMENTED] 02-security: Defender policy keys, service-key deletions (below), SmartScreen off
  (`EnableSmartScreen=0`, Explorer `SmartScreenEnabled='Off'`, Edge SmartScreenEnabled='0'),
  Spynet `SubmitSamplesConsent=0/SpyNetReporting=0`, UAC: `EnableLUA=0`,
  `PromptOnSecureDesktop=0`, `ConsentPromptBehaviorAdmin=0`, `ValidateAdminCodeSignatures=0`,
  `luafv` startup 4.
- [IMPLEMENTED] 11-system: mitigation kill via `kernel: MitigationOptions` +
  `MitigationAuditOptions` = REG_BINARY **hardcoded 45-byte string of '2's**
  (`2222…222` — contrast with SapphireOS's length-adaptive derivation); CFG/XFG/SEHOP off
  (`DisableControlFlowGuardXfg=1`, `DisableExceptionChainValidation=1`); Spectre:
  `FeatureSettingsOverride=3/Mask=3/FeatureSettings=1`; VBS/HVCI/KernelShadowStacks/
  CredentialGuard/RunAsPPL all 0; DMA remapping `DmaRemappingCompatible=0` bulk loop;
  WU lockdown (NoAutoUpdate=1, TargetReleaseVersion pinned to current DisplayVersion via
  PowerShell, DoNotConnectToWindowsUpdateInternetLocations=1, SetDisableUXWUAccess=1,
  Store AutoDownload=2, driver updates excluded, DODownloadMode=0, StorageHealth updates off);
  `defaultuser0` deleted; OEM info overwritten (Manufacturer=Flashhez, SupportURL=vain.zone).
- [IMPLEMENTED] 08-tweaks: `SvcHostSplitThresholdInKB=4294967295` (ControlSet001); FSE behavior
  values (`GameConfigStore: GameDVR_FSEBehaviorMode=1, GameDVR_HonorUserFSEBehaviorMode=1,
  GameDVR_FSEBehavior=2`); HAGS ON (`GraphicsDrivers: HwSchMode=2`, plus
  `HwSchTreatExperimentalAsStable=1`); `SwapEffectUpgradeEnable=1` (windowed-games
  optimization); NTFS fsutil set (incl. `enablenonpagedntfs 1`, `MemoryUsage 2`,
  `usn deletejournal /d C:`); autologger Start=0 for ~45 sessions; app permissions (location
  Deny, webcam/mic Allow); mouse acceleration off; setting-sync fully off.
- [IMPLEMENTED] 01-setup: Smart App Control off (`CI\Policy: VerifiedAndReputablePolicyState=0`);
  PowerShell ExecutionPolicy Unrestricted; PowerShell module/script-block logging disabled;
  hosts file replaced (Microsoft Watson/telemetry + Brave/Mozilla/Google analytics, ~40 lines);
  dark theme; NGEN; WpnService disabled (notifications).

#### Services (05-services.yml) [IMPLEMENTED]
~50 services set startup 4: BDESVC (BitLocker), CldFlt, **UCPD (User Choice Protection Driver)**,
onesyncsvc, ShellHWDetection, sysmain, **themes**, Beep, CloudIdSvc, WPCMonSvc, MapsBroker, fhsvc,
semgrsvc, wisvc, Wdi*, diagnosticshub, diagsvc, **intelpmt** (Intel PMT), pla, WerSvc, svsvc,
diagtrack, kdnic, Wecsvc, dps, pcasvc, dusmsvc, ndu, DSSvc, acpipagr, AcpiPmi, PRM, acpitime, bam,
dam, full printing set (+ DISM printing features off). Hyper-V set (~23 services) + `bcdedit
hypervisorlaunchtype off / vm no / vsmlaunchtype Off` + `DISM /Disable-Feature
Microsoft-Hyper-V-All` + PnP device disables.

#### Scheduled tasks (07-scheduled-tasks.yml) [IMPLEMENTED]
~110 disables/deletes: full UpdateOrchestrator + WindowsUpdate set, WaaSMedic (×2),
InstallService, **RegIdleBackup** (registry backup task), **VerifyWinRE** (WinRE verification),
ScheduledDefrag, WinSAT, memory diagnostics, ExploitGuard/BitLocker MDM refresh, FamilySafety,
CEIP deletes (Consolidator, UsbCeip), MareBackup delete, USO_UxBroker delete, Edge update task
deletes, DeviceDirectoryClient deleteFolder, input-sync/pens/touchpad/mouse tasks, diagnostics,
StorageSense, appuriverifier, Wininet CacheTask, Shell IndexerAutomaticMaintenance.

#### BCD / boot / timer behavior (05-services.yml) [IMPLEMENTED]
`bcdedit /set {current} description "vain"`, `bootmenupolicy Legacy`, `disabledynamictick yes`,
`/deletevalue useplatformclock`, `/deletevalue useplatformtick` (does NOT force platform tick,
unlike SapphireOS), **`nx optin`** (DEP opt-in, not AlwaysOff), **`recoveryenabled no`**,
**`disableelamdrivers yes`**, `integrityservices disable`, `powercfg -h off`,
`label %systemdrive% vain`. Notably: no `useplatformtick yes`, no isolatedcontext/loadoptions
tricks — Vain's timer approach is milder than SapphireOS's.

#### Power settings [IMPLEMENTED]
- `vain.pow` power plan imported under hardcoded GUID `01010110-0110-0001-0110-100101101110`,
  set active, then **all other power schemes deleted** (`powercfg -list` → `powercfg -delete`
  loop) — the Balanced/High performance defaults are removed from the machine.
- 06-performance: `HibernateEnabledDefault=0`, `HiberbootEnabled=0`, watchdog timeouts zeroed
  (`WatchdogResumeTimeout/SleepTimeout`, `PowerWatchdog*` set), `EnforceAusterityMode=0`
  (build-gated ≥26100), `MSDisabled=1`, `DisableInboxPepGeneratedConstraints=1`,
  `IgnoreCsComplianceCheck=1`, USB selective-suspend sweep (`usbflags DisableHCS0Idle=1`,
  `Allow64KLowOrFullSpeedControlTransfers=1`, `DisableLPM` on all 12-char usbflags keys),
  `stornvme: IdlePowerMode=0, DisableDSTThrottle=1`, `Storage: StorageD3InModernStandby=0`,
  `Session Manager\Power: IdleScanInterval=0, SkipTickOverride=0`.

#### GPU / hardware-specific [IMPLEMENTED]
- No direct GPU registry writes in the playbook; GPU work is delegated to Vain Toolbox
  ("installs and cleans up the GPU driver, keeps NVIDIA and AMD tuning profiles, sets interrupt
  affinity for every device") [DOCUMENTED, README]. GPU driver cleanup + profiles are closed-source.
- Device power sweep: `MSPower_DeviceEnable=false` (same as SapphireOS); the Enum-tree sweep
  above; `Class\{4d36e96c…}\PowerSettings` (Idle/Performance/Conservation idle times zeroed — disk
  class); RIT timer powersave off (`RITdemonTimerPowerSaveElapse/Coalescing=0`); mouse
  `RawMouseThrottle*` values; `HKLM\Software\Microsoft\Input: InputServiceEnabled=0`.
- 13-network: full stack reset (`netsh int ip/ipv4/ipv6/tcp reset`, `winsock reset`), NIC
  remove/re-scan, then ~60 exist-checked adapter key writes (EEE, GigaLite, ULPMode,
  InterruptModeration=0, ITR=0, **\*RSS=0** — RSS disabled, unlike SapphireOS's RSS=enabled —,
  offloads mostly =1/=3 enabled, `*UdpRsc=0`, bindings off incl. ms_lldp/ms_lltdio/ms_implat/
  ms_rspndr/ms_server/ms_msclient — **IPv6 binding kept**, unlike SapphireOS), `netsh int tcp set
  security profiles=disabled`, `timestamps=disabled`, `uro=enabled`. Order rationale documented
  in-file and custom.yml comment: "Last: the network reset drops the connection, so every
  download comes before it."

#### Removals / file deletions (02-security, 04-debloat etc.) [IMPLEMENTED]
- Defender removal is **destructive**: registry service keys deleted (Sense, WinDefend, MsSecCore,
  wscsvc, WdFilter, WdBoot, WdNisDrv, WdNisSvc, MsSecWfp, MsSecFlt, wtd, webthreatdef*, 
  SecurityHealthService) **and files deleted** (SecurityHealth* set, `%ProgramW6432%\Windows
  Defender`, ProgramData Defender dirs, WdNisDrv.sys, smartscreen.exe, smartscreenps.dll, 
  Update Health Tools, PCHealthCheck) + `DISM /Disable-Feature Windows-Defender-Default-Definitions`.
  README: "removes Windows Defender, which can't be undone short of reinstalling Windows" [DOCUMENTED].
- mobsync.exe renamed `.old` (renamable); EPP context-menu handlers deleted; Defender tasks deleted.

#### Rollback/undo/backup mechanisms and limits
- [IMPLEMENTED] `12-finalize.yml` cleanup is actively anti-rollback: `vssadmin delete shadows /all
  /quiet` (deletes all restore points/shadow copies), `wevtutil el` + `cl` loop (clears **all**
  event logs), deletes `%SystemDrive%\PerfLogs`, `inetpub`, Windows Temp.
- [DOCUMENTED] Vain Toolbox can re-enable UAC, VBS, Memory Integrity and CPU mitigations
  ("Vain Toolbox > System > Security, each one with its own switch. Restart afterwards.")
  — plausible because 02-security/11-system only wrote registry/BCD values, no Defender-style
  file deletion for those four.
- [DOCUMENTED] Thread Director "All of it is undone when the game closes" — session-scoped,
  self-reverting scheduling (the one genuinely rollback-safe mechanism advertised).
- Limits: Defender file deletion is permanent (vendor-confirmed); UAC/VBS/HVCI/mitigations
  recovery is closed-source behavior (not verifiable); hosts file replaced without backup of the
  original; power schemes other than vain.pow deleted; firewall `FirewallRules` key deleted and
  rebuilt with block rules written to `ControlSet001` only (if the active control set differs,
  rules land in a dead set); `wevtutil` log wipes are unrecoverable; playbook.conf `<Overhaul>true`
  and `FreshInstall` requirement mean AME Wizard's own change-tracking is the only generic undo —
  not present here.
- [DOCUMENTED, guide] The install flow tells users to import `Disable Automatic Updates.reg`
  before first network connection and to disable Defender's four toggles manually in Windows
  Security (real-time, cloud, sample submission, **Tamper Protection**) — i.e., the user performs
  the irreversible consent steps interactively before the playbook's "Prepare System" pass.

#### Safety-relevant behavior (summary for NEXTRIX risk register)
- [IMPLEMENTED] Defender+SmartScreen removed (files deleted — permanent); UAC off; all CPU
  mitigations off (CFG, XFG, SEHOP, Spectre/Meltdown via FeatureSettingsOverride, 45×'2' mask);
  VBS/HVCI/KernelShadowStacks/CredentialGuard/LSA-PPL off; DMA remapping off; ELAM drivers
  disabled (BCD); WinRE recovery disabled; BitLocker service disabled; PowerShell logging off;
  protected event logging off; firewall rules key wiped and rebuilt with outbound block rules for
  SearchApp/SearchHost/StartMenuExperienceHost/SystemSettings/**explorer.exe**; PowerShell
  ExecutionPolicy=Unrestricted; RunAsTI context menu added; crash/dpc-watchdog bugcheck paths
  zeroed; UCPD disabled (defeats default-browser protection); WinRE verify + RegIdleBackup tasks
  disabled; VSS shadows deleted; all event logs cleared.
- [IMPLEMENTED] One genuinely balancing item: FTH disable + `DisableATMFD`-style hardening is NOT
  present (that was SapphireOS); Vain instead enables webcam/mic Allow and HAGS.

#### Known compatibility issues
- 0 open issues [IMPLEMENTED, API]; first GitHub release is 8 days old at access date.
- [DOCUMENTED] Vendor-documented caveats: Thread Director beta "can help a lot or cost FPS";
  "Touchscreen require startmenu" (playbook.conf bottom line — removing Start breaks touch);
  browsers need AVX2 CPUs; playbook is "for a fresh install only".
- [DOCUMENTED] Business model note: playbook is free; paid live sessions for BIOS/OC tuning are
  sold on vain.zone (site footer shows Polish VAT ID NIP 4660440150). Relevant context for
  judging why the engine stays closed-source.

### Useful ideas for NEXTRIX (Vain)
1. **Session-scoped, self-reverting scheduling** — Thread Director's core design ("all of it is
   undone when the game closes") is exactly the rollback-safety property NEXTRIX wants for NX19:
   scheduling changes that live and die with the game process, never persisted to registry.
2. **Per-process rule schema** (`Profiles\1\Rules\<exe>` with class semantics Game=1/
   Background=3) and **thread-description matching** (DWM input/sensor threads → priority 15) —
   a clean, inspectable data model for per-game scheduling profiles, even if NEXTRIX's engine
   must be open.
3. **Network-last ordering with documented rationale** — every download precedes the
   connection-dropping NIC reset; ordering constraints like this belong in NEXTRIX's planner.
4. **Exist-checked adapter writes** (13-network: only set `*EEE`/`ITR`/etc. on keys that already
   expose the value) — safer than SapphireOS's blind creation.
5. **Per-build conditional writes** (`builds: ['>=26100']`) — precedent for build-gated tweaks in
   the playbook engine NEXTRIX might use.
6. **DEP `nx optin` instead of AlwaysOff**, and deleting `useplatformtick`/`useplatformclock`
   rather than forcing them — Vain's timer stance is the safer of the two projects.
7. **Pre-flight requirements incl. `FreshInstall` + `NoPendingUpdates`** as an AME Wizard gate.
8. **Honest beta labeling + per-game/CPU feedback channel** for a scheduling feature — the
   operational humility (explicit "may cost FPS", Discord feedback loop for tuning) is worth
   copying for any NEXTRIX experimental profile.

### Reject / caution for NEXTRIX (Vain)
1. **The Thread Director engine itself is closed-source and self-signed** — NEXTRIX cannot build
   NX19 on an unverifiable binary. How logical processor indexes are derived, and whether CPU
   Sets or affinity masks are used, are **unknown**; the project's scheduling claims remain
   [DOCUMENTED], not evidence. Reimplement openly; treat Vain's behavior as a hypothesis to test.
2. **Hardcoded game EXE tables** (36 games + launcher list) in YAML — brittle (breaks on
   renames/new titles); NEXTRIX should derive classes by measurement or user mapping, not static
   name lists.
3. **Hardcoded 45-byte mitigation mask** (`'2'×45`) — mask length varies by Windows build; a
   SapphireOS-style derived mask is more robust. (Both approaches are dangerous — NEXTRIX
   shouldn't disable mitigations at all by default.)
4. **Defender removed by file deletion** — irreversible; against NEXTRIX's rollback-safe mandate.
5. **`vssadmin delete shadows /all` + all-event-log wipe in "cleanup"** — destroys the user's
   rollback substrate; reject categorically.
6. **UAC/VBS/HVCI/mitigations off as unrequested defaults** — Vain turns all four off
   automatically (only Start-menu removal and browser are options); NEXTRIX must keep every
   security-lowering change explicit, opt-in, and reversible.
7. **Unpinned floating download** of `VainUpdater.exe` from `raw.githubusercontent.com` at install
   with `/silent`, plus password-protected `.apbx` packaging — supply-chain opacity; NEXTRIX
   should pin versions and hashes.
8. **All other power schemes deleted** after importing vain.pow — removes the OS's own fallback
   plans; NEXTRIX should keep stock plans restorable.
9. **Firewall block rules for explorer.exe/SystemSettings.exe** — breaking shell networking can
   have wide blast radius; needs per-app rationale.
10. **Custom all-rights-reserved license** on the playbook (fine for them) means NEXTRIX may
    *read* but must not copy Vain's YAML/text wholesale; the MIT third-party parts (PS-SFTA,
    RunAsTI) are the only freely reusable pieces, per their own licenses.

Snippet (3 lines, Vain custom license — quoted for factual documentation only,
https://raw.githubusercontent.com/flashhez/Vain-Playbook/main/Build.bat):
```bat
for /f "tokens=3 delims=<>" %%V in ('findstr /c:"<Version>" playbook.conf') do set "VER=%%V"
del "Vain-Playbook-v%VER%.apbx" 2>nul
"C:\Program Files\7-Zip\7z.exe" a -tzip "Vain-Playbook-v%VER%.apbx" Configuration Executables Images playbook.conf playbook.png -p"malte"
```
(Shows: `.apbx` = zip with fixed password `malte`; version parsed from playbook.conf.)

### Research limitations (Project 3)
- **Vain Tools source is closed** (vendor-confirmed). The Thread Director's core mechanics —
  logical-processor-index derivation, CPU Sets vs affinity, "best cores" ranking on Intel P/E and
  dual-CCD X3D — could not be verified in source; all such claims remain [DOCUMENTED]. The
  license forbids reverse engineering, so this cannot be closed by disassembly either.
- `03-apps.yml` (85 KB), `04-debloat.yml` (30 KB), `09-privacy.yml` (23 KB), `10-explorer.yml`
  (38 KB) and `Executables/RunAsTi.reg`, `SetFileTypeAssociation.ps1`, `vain.pow` (binary) were
  not fetched in full (budget); their contents are partially covered by the release notes
  [DOCUMENTED] but not line-verified. In particular Copilot/AI-removal specifics live in the
  unfetched files.
- VainTools `THIRD-PARTY-NOTICES.txt` (362 KB, Windows App SDK notices) was not fetched.
- Discord (support/feedback channel) was not accessed; community reports on Thread Director
  behavior are not captured. `vain.zone/guide-first-steps.html` (Toolbox first-run steps) was
  not fetched.
- No performance measurements of any kind were attempted (read-only mandate); there are no
  DEV-BENCHMARK numbers published by the vendor to even relay — Vain's only performance
  statement is qualitative ("can help a lot or cost FPS") [DOCUMENTED].

---

## Cross-project comparison notes (for the NEXTRIX memo)

| Dimension | SapphireOS / -Playbook | Vain |
|---|---|---|
| Distribution | Discord-gated ISOs (unauditable) + GPL repo | GitHub release `.apbx` (zip, password `malte`), closed engine |
| Build support | 19044–26200 (playbook conf) | 22631–28000, per-build YAML filters |
| DEP default | `nx AlwaysOff` (ISO) / optin+FACEIT bats (playbook) | `nx optin` |
| Timer forcing | `useplatformtick yes`, HPET device disabled | values deleted, nothing forced |
| Mitigation disable | Mask derived from system (adaptive) + per-image IFEO | Hardcoded 45×'2' mask |
| Defender | Renames/blocks + NoDefender.cab + root cert (re-enable pair exists) | File deletion (permanent, vendor-stated) |
| Service backup | Start-value .reg export before change | None observed |
| Scheduling granularity | Global knobs + IFEO priorities; CPU tools shipped manual | Closed per-thread/per-core engine + hardcoded game list |
| Hardware guards | ChassisTypes list, SSD/HDD pair, VMware case, Intel ME/PSP device disables | Chassis ≤7 check, exist-checked NIC writes, Intel PMT service |
| Rollback posture | Toggle kit + service .reg, but System Restore/VSS/WinRE disabled | Toolbox switches (UAC/VBS/HVCI/mitigations), Thread Director self-reverts; shadows deleted |

Key negative findings for NEXTRIX: neither project derives CPU topology in inspectable source;
SapphireOS has no topology logic at all, and Vain's is hidden in a closed binary — so NX19's
topology derivation cannot be *copied* from either reference, only its rule-schema and
self-revert design emulated. Both projects sabotage the OS's own rollback systems (System
Restore/VSS/RegIdleBackup/WinRE/crash dumps), which is precisely the axis on which NEXTRIX
must differ.

Access date: 2026-11-23. Researcher: NEXTRIX subagent R3.
