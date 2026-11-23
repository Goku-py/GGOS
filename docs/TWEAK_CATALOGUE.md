# NEXTRIX — Tweak Catalogue (PROPOSED)

**Status:** v0.5 - Phases 0-6 complete (v0.7.0-rc). **Nothing has been applied to any machine.** Per-entry implementation status lives in `registry/*.json` (the source of truth: 282 entries; 242 SyntaxValidated / 40 Defined). This catalogue remains the reviewed inventory; evidence corrections from Phases 1-6 are applied below, and no performance evidence exists anywhere.
**Conventions**

- Entry status lives in `registry/*.json` (see the ladder in `TWEAK_CLASSIFICATION.md`); nothing in this repository holds an owner-gated status.
- **Class** = risk class (CORE / CONDITIONAL / ADVANCED / EXPERIMENTAL / TROUBLESHOOTING). **Ev** = evidence desk assignment (E0 community-known · E1 Microsoft/vendor-documented); E2+ only via owner testing.
- **One primary category per tweak.** Where the master directive lists an item in two categories, the catalogue assigns one owner and cross-references (`XREF`). Registry target duplication under different names is a build-validation failure.
- Mechanism-owner rule: a *mechanism* (e.g. per-app GPU preference, USB selective suspend, SysMain service config) is owned by exactly one entry; other categories reference or parameterize it.
- IDs are stable once approved; they never change if names move.

---

## NX01 — Windows Foundation

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX01-001 | Disable Windows tips & suggestions | CORE | E0 | CDM `SubscribedContent-338388Enabled` family; per-user; value-existence journaled |
| NX01-002 | Disable welcome experience | CORE | E0 | `SubscribedContent-310093Enabled`; per-user |
| NX01-003 | Disable consumer experience / suggested apps | CORE | E1 | ADMX `DisableWindowsConsumerFeatures` policy path; per-user profile interplay noted |
| NX01-004 | Disable Start menu suggestions | CORE | E0 | Build-conditional values (23H2 vs 24H2+ families); capability-checked |
| NX01-005 | Disable silent promotional app installs | CORE | E0 | `SilentInstalledAppsEnabled`; same key family as -001, distinct values |
| NX01-006 | Disable lock-screen promotional content | CORE | E0 | Spotlight overlay values; XREF NX15-012 (image choice) |
| NX01-007 | Notification defaults configuration | CORE | E1 | Per-user toast settings + documented policy paths |
| NX01-008 | Global UWP background-app permission policy | CONDITIONAL | E0 | Per-user global toggle; per-app management lives NX11-002 |
| NX01-009 | Windows Search indexing scope configuration | CONDITIONAL | E1 | Documented indexing scope mgmt; SSD/HDD parameters via NX06 guidance; XREF NX11-008 |
| NX01-010 | Disable search highlights | CORE | E1 | Microsoft-documented AllowSearchHighlights/EnableDynamicContentInWSB policy covers the same feature (verified 2026-11-23); per-user |
| NX01-011 | Delivery Optimization configuration | CONDITIONAL | E1 | Documented DO mode/bandwidth policies; E1 |
| NX01-012 | Automatic maintenance schedule | CONDITIONAL | E1 | Documented MaintenanceSettings; wake-time trade-off stated |
| NX01-013 | Windows Update active hours configuration | CORE | E1 | Documented policy; owner-chosen window |
| NX01-014 | Restart notification configuration | CONDITIONAL | E1 | Active-hours-adjacent policies |
| NX01-015 | Optional features & components management | CORE | E1 | CIM/DISM documented; inventory + selective enable/disable |
| NX01-016 | Default application associations | CORE | E1 | Documented XML app-association export/import |

## NX02 — Gaming & Esports

Mechanisms owned by NX04 (HAGS, per-app GPU preference, VRR, Auto HDR, FSO per-game, MPO) are XREF'd there, not duplicated here.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX02-001 | Windows Game Mode configuration | CORE | E1 | Documented Settings toggle; registry family journaled |
| NX02-002 | Xbox Game Bar configuration | CONDITIONAL | E1 | Microsoft-documented values (UseNexusForGameBarEnabled etc., verified 2026-11-23); Game Pass users cautioned |
| NX02-003 | Disable Game DVR | CONDITIONAL | E1 | Microsoft-documented AllowGameDVR policy (GameDVR.admx, verified 2026-11-23); Streamer profile excludes |
| NX02-004 | Disable background game recording | CONDITIONAL | E0 | Conflict: capture/streaming users — profile-guarded |
| NX02-005 | Optimizations for windowed games | CONDITIONAL | E0 | Corrected from E1: no Microsoft documentation exists for the DirectXUserGlobalSettings encoding (verified 2026-11-23); community-established across three references; capability-checked |
| NX02-006 | Game Mode notification suppression | CORE | E0 | Per-user |
| NX02-007 | Game capture configuration | CONDITIONAL | E1 | Microsoft-documented VKM shortcut values (verified 2026-11-23); Streamer/capture preservation rules apply |
| NX02-008 | Xbox Gaming Services management | CONDITIONAL | E0 | Dependency-aware (Game Pass, NX12 Xbox removal conflict) |
| NX02-009 | Per-game driver graphics application | CONDITIONAL | E0 | COMPOSITION of NX04-009…023 per game; no duplicate targets |
| NX02-010 | Game-specific launch configuration | CONDITIONAL | E0 | COMPOSITION of NX19-004/005 at launch |
| NX02-011 | Game-specific background app handling | CONDITIONAL | E0 | COMPOSITION of NX18-006 rules per game |
| NX02-012 | Game launcher detection registry | CONDITIONAL | E0 | Detection data feeding NX18; no Windows mutation |

## NX03 — CPU & Processor Configuration

Standard configuration vs advanced scheduling experiments are separated; topology/scheduling mechanisms live in NX19.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX03-001 | Minimum processor state | ADVANCED | E1 | powercfg `PROCTHROTTLEMIN`; per-plan, AC/DC split; battery caution |
| NX03-002 | Maximum processor state | ADVANCED | E1 | `PROCTHROTTLEMAX`; boost interplay documented |
| NX03-003 | Processor boost mode policy | ADVANCED | E1 | `PERFBOOSTMODE`; vendor support varies |
| NX03-004 | Energy Performance Preference | ADVANCED | E1 | `PERFEPP`; AMD/Intel behavioral differences recorded |
| NX03-005 | Core parking policy | ADVANCED | E1 | Hidden power settings; hardware-dependent; XREF NX19 profiles |
| NX03-006 | CPU power throttling policy | CONDITIONAL | E1 | Documented `PowerThrottling`; Intel hybrid interplay |
| NX03-007 | MMCSS configuration | ADVANCED | E1 | Documented service + profile keys; XREF NX17-008/-010 |
| NX03-008 | Win32PrioritySeparation | ADVANCED | E1 | Documented value; widely misused — full explanation mandatory; preset-excluded |
| NX03-009 | Processor performance policy set | ADVANCED | E1 | Threshold/hysteresis/time-check family; per-plan |
| NX03-010 | SMT / Hyper-Threading configuration | ADVANCED | E1 | Documented OS option; high blast radius; preset-excluded |
| NX03-011 | AMD CPPC preferred cores | EXPERIMENTAL | E0 | AMD-platform conditional; X3D/CCD interplay; R1/R3 research |
| NX03-012 | Intel hybrid P/E power policy | EXPERIMENTAL | E0 | Intel hybrid conditional; topology-fed |
| NX03-013 | CPU inventory & frequency report | CORE | E1 | Read-only diagnostic; feeds recommendation engine |

## NX04 — GPU & Graphics

Windows-graphics mechanisms are owned here; NVIDIA/AMD/Intel sections gate on detected vendor. Driver-profile mechanisms depend on vendor-documented interfaces — external-tool policy (if any) is owner-approved and recorded per entry.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX04-001 | Hardware-Accelerated GPU Scheduling | ADVANCED | E1 | Documented; driver+build+vendor conditional; restart; XREF NX02 |
| NX04-002 | Per-application GPU preference | CONDITIONAL | E1 | Documented mechanism; app-parameterized instances (incl. games); hybrid/multi-GPU relevance |
| NX04-003 | Variable Refresh Rate (windowed) | CONDITIONAL | E1 | Documented; VRR-capable display required |
| NX04-004 | Auto HDR | CONDITIONAL | E1 | Documented; HDR display required |
| NX04-005 | Fullscreen Optimizations per-game override | TROUBLESHOOTING | E0 | Per-game only — **global disable forbidden**; documented-problem gate |
| NX04-006 | MPO troubleshooting configuration | TROUBLESHOOTING | E0 | Symptom: documented MPO artifact class; reversibility verified |
| NX04-007 | Display presentation configuration | CONDITIONAL | E0 | Presentation-mode policy; build-conditional |
| NX04-008 | Hybrid graphics reporting & app routing | CONDITIONAL | E1 | Laptop profile; feeds NX04-002 routing |
| NX04-009 | NVIDIA power management mode (per-profile) | CONDITIONAL | E1 | Vendor-documented driver setting; NVIDIA-only gate |
| NX04-010 | NVIDIA Low Latency Mode (per-profile) | CONDITIONAL | E1 | Vendor-documented; per-game profile |
| NX04-011 | NVIDIA vertical sync mode (per-profile) | CONDITIONAL | E1 | Vendor-documented |
| NX04-012 | NVIDIA Maximum Frame Rate (per-profile) | CONDITIONAL | E1 | Vendor-documented |
| NX04-013 | NVIDIA Threaded Optimization (per-profile) | CONDITIONAL | E1 | Vendor-documented |
| NX04-014 | NVIDIA texture filtering quality (per-profile) | CONDITIONAL | E1 | Vendor-documented |
| NX04-015 | NVIDIA shader cache policy | CONDITIONAL | E0 | Cache size/behavior; vendor-version conditional |
| NX04-016 | NVIDIA per-game profile framework | CONDITIONAL | E1 | Mechanism applying -009…-015 per game; tool interface recorded |
| NX04-017 | AMD Radeon Anti-Lag (per-profile) | CONDITIONAL | E1 | Vendor-documented; AMD-only gate |
| NX04-018 | AMD Radeon Chill (per-profile) | CONDITIONAL | E1 | Vendor-documented; frame-cap semantics explained |
| NX04-019 | AMD Enhanced Sync (per-profile) | CONDITIONAL | E1 | Vendor-documented |
| NX04-020 | AMD Wait for Vertical Refresh (per-profile) | CONDITIONAL | E1 | Vendor-documented |
| NX04-021 | AMD Surface Format Optimization | CONDITIONAL | E0 | Vendor setting; visual-quality trade-off stated |
| NX04-022 | AMD per-game profile framework + shader cache | CONDITIONAL | E0 | AMD-only gate |
| NX04-023 | Intel graphics / Arc settings framework | CONDITIONAL | E0 | Scriptable vendor interfaces limited — limitations stated honestly |

## NX05 — Memory Management

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX05-001 | Normalize pagefile to system-managed | CONDITIONAL | E1 | Repair-oriented; journal original |
| NX05-002 | Custom pagefile configuration | ADVANCED | E1 | Requires RAM/workload analysis; never preset |
| NX05-003 | Disable pagefile | TROUBLESHOOTING | E1 | **Preset-excluded**; heavy warnings; commit-failure risk documented |
| NX05-004 | Disable memory compression | ADVANCED | E1 | `Disable-MMAgent` documented; trade-off stated; preset-excluded |
| NX05-005 | Memory pressure & commit monitoring report | CORE | E1 | Read-only diagnostics |
| NX05-006 | Standby memory diagnostic report | CORE | E1 | Diagnostics only — **no continuous standby cleaner** (directive) |
| NX05-007 | Large System Cache | ADVANCED | E0 | Legacy-era setting; strong caution |
| NX05-008 | Clear pagefile at shutdown | TROUBLESHOOTING | E1 | Shutdown-time cost; security-motivated; not perf |
| NX05-009 | Crash dump configuration | CONDITIONAL | E1 | Dump type selection; disk-space trade-off |
| NX05-010 | Pool limit configuration | TROUBLESHOOTING | E0 | Only with documented symptom; preset-excluded |
| NX05-011 | Memory diagnostics suite | CORE | E1 | MMAgent state, RAM report; read-only |

## NX06 — Storage & Filesystem

SysMain service config is owned by NX11-009; indexing scope by NX01-009.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX06-001 | Storage inventory & SSD/HDD/NVMe classification | CORE | E1 | `Get-PhysicalDisk` documented; feeds all storage-conditional logic |
| NX06-002 | TRIM enable & verification | CORE | E1 | `fsutil behavior` documented; verify reported state |
| NX06-003 | Optimize Drives schedule configuration | CONDITIONAL | E1 | SSD-aware (retrim) vs HDD (defrag) distinction |
| NX06-004 | Storage Sense configuration | CONDITIONAL | E1 | Documented settings; user cadence choice |
| NX06-005 | Temporary files cleanup (on-demand) | CONDITIONAL | E1 | Journaled deletions; no scheduled silent deletion |
| NX06-006 | Windows Update cache cleanup (on-demand) | CONDITIONAL | E1 | Safe-stop conditions (active update) checked |
| NX06-007 | Delivery Optimization cache cleanup | CONDITIONAL | E1 | XREF NX01-011 |
| NX06-008 | NTFS last-access update policy | CONDITIONAL | E1 | `fsutil` documented; per-volume |
| NX06-009 | NTFS 8.3 name creation policy | CONDITIONAL | E1 | Legacy-installer compatibility caution |
| NX06-010 | NTFS memory usage configuration | ADVANCED | E1 | Mostly diagnostic; preset-excluded |
| NX06-011 | Write caching policy (per-device) | CONDITIONAL | E0 | Power-loss trade-off mandatory in explanation |
| NX06-012 | Disk device power management (storage D3 / idle boundary) | CONDITIONAL | E1 | Latency-vs-power trade-off stated; plan-level spin-down stays NX09 (W2-C naming correction) |
| NX06-013 | Drive health (SMART) report | CORE | E1 | Read-only health status |

## NX07 — Network Optimization

All adapter-level entries are **adapter-instance-parameterized** and preserve original values. No DNS-change latency claims (directive).

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX07-001 | Adapter inventory & capability report | CORE | E1 | Read-only; exposes which advanced properties exist per driver |
| NX07-002 | Adapter power management | CONDITIONAL | E0 | Per-adapter; disconnect-issue trade-off |
| NX07-003 | Energy Efficient Ethernet | ADVANCED | E1 | Driver-exposed; per-adapter |
| NX07-004 | Interrupt moderation | ADVANCED | E1 | Per-adapter; latency-vs-CPU trade-off |
| NX07-005 | Receive Side Scaling configuration | ADVANCED | E1 | Per-adapter; queue count vs CPU topology |
| NX07-006 | Receive Segment Coalescing | ADVANCED | E1 | Per-adapter |
| NX07-007 | Large Send Offload | ADVANCED | E1 | Per-adapter; community-controversial — honest note |
| NX07-008 | Checksum offloads (TCP/UDP) | ADVANCED | E1 | Per-adapter |
| NX07-009 | Flow Control | ADVANCED | E1 | Per-adapter; switch-dependent |
| NX07-010 | Jumbo Frames | ADVANCED | E1 | End-to-end path requirement documented |
| NX07-011 | Receive/Transmit buffer sizing | ADVANCED | E1 | Driver-dependent ranges; per-adapter |
| NX07-012 | Wi-Fi roaming aggressiveness | CONDITIONAL | E1 | Per-adapter; environment-dependent |
| NX07-013 | Wi-Fi preferred band | CONDITIONAL | E1 | Per-adapter; AP capability check |
| NX07-014 | Wi-Fi channel width | ADVANCED | E1 | AP-dependent; interference trade-off |
| NX07-015 | Wi-Fi transmit power | CONDITIONAL | E1 | Per-adapter |
| NX07-016 | DNS configuration | CONDITIONAL | E1 | Documented cmdlets; **no game-latency claims**; privacy/motivation stated |
| NX07-017 | TCP auto-tuning & ECN inspection/config | ADVANCED | E1 | `netsh` documented; current-state report included |
| NX07-018 | MTU inspection & configuration | TROUBLESHOOTING | E1 | Path-MTU documented symptom gate |
| NX07-019 | Network diagnostics report | CORE | E1 | Read-only baselines (pathping, adapter stats) |
| NX07-020 | DNS cache management | TROUBLESHOOTING | E1 | Symptom-gated; journaled |
| NX07-021 | Network stack reset | TROUBLESHOOTING | E1 | Last resort; full pre-state journal; user-informed |
| NX07-022 | Per-game QoS/DSCP profile | CONDITIONAL | E0 | Opt-in, router/infrastructure-dependent (SapphireOS-Playbook `Auto DSCP & FSE` [IMPLEMENTED, r3]); honest scope — no blanket latency claims |

## NX08 — Input & Peripherals

USB selective suspend → NX09-005; IRQ affinity / MSI mode → NX17; USB hardware inventory → NX20-007.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX08-001 | Disable Enhance Pointer Precision | CONDITIONAL | E0 | Esports-conditional; per-user; default preserved otherwise |
| NX08-002 | Mouse pointer speed/sensitivity | CONDITIONAL | E0 | Per-user; documented slider mapping |
| NX08-003 | Mouse polling rate inspection | CORE | E0 | Read-only USB inspection; detection limits stated |
| NX08-004 | Keyboard repeat delay/rate | CONDITIONAL | E1 | Documented values; per-user |
| NX08-005 | Game controller inspection & configuration | CONDITIONAL | E0 | Read-only inspection + Deadzone via vendor UI guidance |
| NX08-006 | Bluetooth peripheral inspection & power policy | CONDITIONAL | E1 | XREF NX11-012 (service dependency) |
| NX08-007 | USB controller & HID device inspection | CORE | E1 | Read-only; feeds NX09-005 decisions |
| NX08-008 | Mouse/keyboard data-queue size configuration | CONDITIONAL | E0 | Undocumented mouclass/kbdclass queue depth (default 100, entries×24/12 bytes); community floor 16 enforced in code (click-loss-at-1 report); placebo claims recorded; Reboot; no perf claim (research: TWEAK_RESEARCH §16) |

## NX09 — Power Management

Laptops keep independent AC/DC values everywhere. Processor min/max/boost/EPP/parking are owned by NX03.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX09-001 | Active power plan selection | CONDITIONAL | E1 | Balanced/High/Ultimate; laptop AC/DC guidance |
| NX09-002 | Ultimate Performance provisioning | CONDITIONAL | E1 | Documented clone under own GUID; GUID journaled for rollback deletion |
| NX09-003 | Custom NEXTRIX plan generation | CONDITIONAL | E1 | Generated plan importable/exportable; journal-linked lifecycle |
| NX09-004 | PCIe ASPM link policy | CONDITIONAL | E1 | Per-plan AC/DC; power-vs-latency trade-off |
| NX09-005 | USB selective suspend policy | CONDITIONAL | E1 | Per-plan + per-device options; XREF NX08 |
| NX09-006 | Display timeout configuration | CONDITIONAL | E1 | AC/DC independent |
| NX09-007 | Sleep configuration | CONDITIONAL | E1 | AC/DC independent; wake-source inspection included |
| NX09-008 | Hibernate configuration | CONDITIONAL | E1 | `powercfg /h` documented; disk-space trade-off |
| NX09-009 | Fast Startup configuration | CONDITIONAL | E1 | Dual-boot caution documented |
| NX09-010 | Lid close behavior (laptops) | CONDITIONAL | E1 | AC/DC independent |
| NX09-011 | OEM battery conservation reporting | CORE | E0 | Detection only where OEM exposes an interface |
| NX09-012 | OEM performance mode detection | CORE | E0 | Detection only; no firmware writes (directive NX10 rule) |
| NX09-013 | Power plan export/import/restore tooling | CORE | E1 | Journaled; supports NX16 rollback |
| NX09-014 | Energy report (`powercfg /energy`) | CORE | E1 | Read-only diagnostic |
| NX09-015 | Battery report (`powercfg /batteryreport`) | CORE | E1 | Read-only diagnostic |

## NX10 — Thermal Management

Monitoring/diagnostic-only category. **No universal fan-control registry tweaks, no unsupported firmware modifications** (directive).

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX10-001 | CPU temperature & throttling detection report | CORE | E1 | WMI/vendor sources; availability limits stated |
| NX10-002 | GPU temperature & throttling report | CORE | E1 | Vendor CLIs (nvidia-smi etc.); caveats per vendor |
| NX10-003 | CPU power-limit monitoring | CONDITIONAL | E0 | PL1/PL2 exposure varies — marked uncertain where unavailable |
| NX10-004 | GPU power-limit monitoring | CONDITIONAL | E0 | Vendor-dependent |
| NX10-005 | Fan speed monitoring (where exposed) | CONDITIONAL | E0 | Availability varies by OEM; never a universal tweak |
| NX10-006 | OEM fan/cooling profile detection & switching | CONDITIONAL | E0 | Only where OEM documents an interface; per-OEM module |
| NX10-007 | AC/DC thermal behavior report | CONDITIONAL | E0 | Laptop profile pairing |
| NX10-008 | Thermal session logging for owner testing | CORE | E0 | Logging only; feeds owner's test evidence workflow |

## NX11 — Background Activity & Services

**No disable-all-services option exists anywhere in NEXTRIX.** Every service entry is conditional on detected usage and journal-stamped.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX11-001 | Startup app inventory & selective management | CORE | E1 | Approved-run-keys inventory; per-item selection & journal |
| NX11-002 | Per-app background permissions (UWP) | CONDITIONAL | E0 | Global policy owned by NX01-008 |
| NX11-003 | Edge background mode disable | CONDITIONAL | E1 | Microsoft Edge background-mode policy page verified 2026-11-23 (W2-E); Edge-usage conditional |
| NX11-004 | Edge startup boost disable | CONDITIONAL | E1 | Microsoft Edge startup-boost policy page verified 2026-11-23 (W2-E); trade-off stated |
| NX11-005 | Scheduled task inventory report | CORE | E1 | Read-only full export |
| NX11-006 | Selective scheduled task management | CONDITIONAL | E0 | Allow-listed candidates only; per-task journal; XREF NX13-013 |
| NX11-007 | Resource-heavy process identification report | CORE | E1 | Read-only; evidence for user decisions |
| NX11-008 | Windows Search service configuration | CONDITIONAL | E1 | Indexing dependency notes; XREF NX01-009 |
| NX11-009 | SysMain service configuration | CONDITIONAL | E1 | Storage-class-aware parameters (SSD/HDD/RAM); storage owner NX06 |
| NX11-010 | Xbox services configuration | CONDITIONAL | E1 | Dependency-checked; Game Pass conflict rules |
| NX11-011 | Print Spooler configuration | CONDITIONAL | E1 | Only when no printers detected (hardware-aware gate) |
| NX11-012 | Bluetooth service configuration | CONDITIONAL | E1 | Only when no BT peripherals detected (hardware-aware gate) |
| NX11-013 | Fax service configuration | CONDITIONAL | E1 | Detection-gated; legacy service |
| NX11-014 | Remote Registry configuration | CONDITIONAL | E1 | Security-positive default-off candidate; consent |
| NX11-015 | Windows Error Reporting configuration | CONDITIONAL | E0 | Reporting-only reduction; diagnostics trade-off stated |
| NX11-016 | Maps-related services configuration | CONDITIONAL | E0 | Offline-maps usage conditional |
| NX11-017 | DiagTrack (Connected User Experiences) configuration | CONDITIONAL | E0 | XREF NX13 telemetry policy set |
| NX11-018 | Third-party service inventory & selective configuration | CONDITIONAL | E1 | Per-service consent; vendor dependency notes |
| NX11-019 | Service dependency inspection engine | CORE | E1 | Tooling gate for every service change |

## NX12 — Windows Debloating

Store, App Installer, WebView2 and runtime dependencies are **protected by default**. Removal entries are individually selected, dependency-checked and honestly labeled for reversibility.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX12-001 | Consumer app inventory & selective removal | CONDITIONAL | E1 | Per-app selection (News, Weather, Solitaire, Clipchamp, …) |
| NX12-002 | Protected-dependency guard | CORE | E1 | Store/AppInstaller/WebView2/runtimes protected list enforcement |
| NX12-003 | OEM/promotional third-party app removal | CONDITIONAL | E1 | OEM-detection; per-app consent |
| NX12-004 | Phone Link removal (optional) | CONDITIONAL | E1 | Conflict NX13-012 cross-device set |
| NX12-005 | Xbox app removal (optional) | CONDITIONAL | E1 | Conflict NX02-008; Game Pass users excluded |
| NX12-006 | Copilot / AI feature configuration | CONDITIONAL | E0 | Build-conditional (24H2+ families); capability-checked |
| NX12-007 | Communication apps optional removal | CONDITIONAL | E1 | Teams consumer etc.; dependency-checked |
| NX12-008 | Removal scope control (per-user / all-users) | CONDITIONAL | E1 | Scope parameter; journaled per scope |
| NX12-009 | Provisioned package removal control | CONDITIONAL | E1 | New-user provisioning impact explained |
| NX12-010 | Removal history & reversibility ledger | CORE | E1 | Honest labels: Store-reinstallable vs media-requiring |
| NX12-011 | Reinstallation helper (Store-based) | CORE | E1 | Uses documented Store mechanisms |
| NX12-012 | Windows capabilities selective removal | CONDITIONAL | E1 | Capability list with usage notes; never blanket |
| NX12-013 | New-user app provisioning policy | CONDITIONAL | E1 | Deprovision decisions per app family |
| NX12-014 | AppX dependency graph verification engine | CORE | E1 | Tooling gate for every removal |

## NX13 — Privacy & Telemetry

Privacy changes are never described as performance improvements (directive).

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX13-001 | Advertising ID disable | CONDITIONAL | E1 | Documented setting; per-user + policy path |
| NX13-002 | Activity history disable | CONDITIONAL | E1 | Documented; per-user |
| NX13-003 | Tailored experiences disable | CONDITIONAL | E1 | Documented |
| NX13-004 | Diagnostic data level (Required vs Optional) | CONDITIONAL | E1 | Documented policy; enterprise interplay noted |
| NX13-005 | Permission defaults (location/camera/mic/contacts/calendar) | CONDITIONAL | E1 | Report + selective policy; per-item consent |
| NX13-006 | App launch tracking policy | CONDITIONAL | E1 | Documented NoInstrumentation policy verified 2026-11-23 (W2-F); per-user layers stay E0 |
| NX13-007 | General consent/ad-personalization toggles | CONDITIONAL | E1 | Documented policy layer verified 2026-11-23 (W2-F); community value layer labeled E0 in-entry |
| NX13-008 | Feedback frequency configuration | CONDITIONAL | E1 | Documented setting |
| NX13-009 | Inking & typing personalization policy | CONDITIONAL | E1 | Documented RestrictImplicitText/InkCollection policies verified 2026-11-23 (W2-F); dictation interplay noted |
| NX13-010 | Cloud content search preferences | CONDITIONAL | E1 | Documented; search-quality trade-off stated |
| NX13-011 | Clipboard history configuration | CONDITIONAL | E1 | Documented; user preference |
| NX13-012 | Cross-device experiences configuration | CONDITIONAL | E1 | Conflict-aware with NX12-004 |
| NX13-013 | Telemetry-related scheduled tasks (selective) | CONDITIONAL | E0 | XREF NX11-006; per-task journal |
| NX13-014 | Permission audit report | CORE | E1 | Read-only; feeds Privacy-Focused profile |

## NX14 — Security Configuration

Status/inspection by default; reductions are ADVANCED/TROUBLESHOOTING, consent-gated, never preset (directive Section 15).

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX14-001 | Defender status & health report | CORE | E1 | Read-only |
| NX14-002 | Firewall status & profile report | CORE | E1 | Read-only |
| NX14-003 | UAC level configuration | CONDITIONAL | E1 | Documented range; **never auto-disable**; preset-excluded beyond default |
| NX14-004 | SmartScreen configuration | CONDITIONAL | E1 | Documented; consent-gated changes |
| NX14-005 | Secure Boot status report | CORE | E1 | `Confirm-SecureBootUEFI` |
| NX14-006 | TPM status report | CORE | E1 | `Get-Tpm` |
| NX14-007 | VBS / HVCI status report | CORE | E1 | DeviceGuard CIM query |
| NX14-008 | Memory Integrity consent-gated configuration | ADVANCED | E1 | Full trade-off documentation; explicit consent; **preset-excluded** |
| NX14-009 | Credential Guard status report | CORE | E1 | Read-only |
| NX14-010 | Controlled Folder Access configuration | CONDITIONAL | E1 | On/off + allowed-apps management; consent |
| NX14-011 | Exploit Protection report & selective policy | ADVANCED | E1 | Mitigation changes preset-excluded; per-item consent |
| NX14-012 | BitLocker status report | CORE | E1 | Read-only |
| NX14-013 | Windows Sandbox provisioning | CONDITIONAL | E1 | Feature enable; virtualization interplay |
| NX14-014 | Hyper-V / virtualization platform configuration | ADVANCED | E1 | WSL2/Docker dependency warnings mandatory |
| NX14-015 | Windows Security health aggregate report | CORE | E1 | Read-only summary feeding all profiles |

## NX15 — Visual & Interface

Cosmetic changes are never counted or described as performance modifications.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX15-001 | Visual effects policy (animations set) | CONDITIONAL | E1 | Per-user; documented sets |
| NX15-002 | Transparency effects | CONDITIONAL | E0 | Corrected from E1: Microsoft documents the setting but not the applied value encoding (verified 2026-11-23, W2-G); per-user |
| NX15-003 | Window shadows & menu show delay | CONDITIONAL | E0 | Per-user visual family |
| NX15-004 | Taskbar configuration set | CONDITIONAL | E0 | Alignment/widgets/search/taskview per-item toggles; build-conditional |
| NX15-005 | Start menu recommendations configuration | CONDITIONAL | E0 | Build-conditional; XREF NX01-004 family |
| NX15-006 | Explorer configuration set | CONDITIONAL | E1 | Launch-to-This-PC, separate-process etc. |
| NX15-007 | File extension visibility | CONDITIONAL | E1 | Per-user |
| NX15-008 | Hidden files visibility | CONDITIONAL | E1 | Per-user |
| NX15-009 | Context menu configuration | CONDITIONAL | E0 | Build-conditional classic/new toggles |
| NX15-010 | Explorer compact view | CONDITIONAL | E1 | Per-user |
| NX15-011 | Notification Center configuration | CONDITIONAL | E0 | Per-user |
| NX15-012 | Lock screen configuration | CONDITIONAL | E0 | Image/spotlight choice; promo owned by NX01-006 |
| NX15-013 | Desktop icon configuration | CONDITIONAL | E0 | Corrected from E1: value encoding undocumented (verified 2026-11-23, W2-G); per-user |
| NX15-014 | Font smoothing configuration | CONDITIONAL | E0 | Corrected from E1: value encoding undocumented (verified 2026-11-23, W2-G); per-user |

## NX16 — Maintenance & Recovery (foundational)

This category is implemented **first**, before any mutating tweak category.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX16-001 | System Restore enablement & configuration | CORE | E1 | Documented; disk allocation choice |
| NX16-002 | Pre-change restore point creation ritual | CORE | E1 | Runs before first mutation of every apply session |
| NX16-003 | Targeted registry backup | CORE | E1 | Exports of every touched key family before change |
| NX16-004 | Pre-flight original-state snapshot bundle | CORE | E1 | Journal init + service/task/power export bundle |
| NX16-005 | Service configuration backup | CORE | E1 | Startup+state+deps for candidate services |
| NX16-006 | Scheduled task backup (selected) | CORE | E1 | Task XML export before task changes |
| NX16-007 | DISM health check & repair tooling | CORE | E1 | CheckHealth/ScanHealth/RestoreHealth |
| NX16-008 | SFC verification tooling | CORE | E1 | `sfc /verifyonly` first; owner-invoked repair |
| NX16-009 | Component store cleanup (on-demand) | CONDITIONAL | E1 | `StartComponentCleanup`; reset-base explicitly not default |
| NX16-010 | Driver inventory & history report | CORE | E1 | CIM/pnputil; read-only |
| NX16-011 | Driver Store selective cleanup | ADVANCED | E1 | Orphaned-package detection; per-package consent; journal |
| NX16-012 | Windows build & UBR verification report | CORE | E1 | Feeds every build gate |
| NX16-013 | Individual tweak rollback | CORE | E1 | Engine scope 1 of 4 |
| NX16-014 | Category rollback | CORE | E1 | Engine scope 2 of 4 |
| NX16-015 | Profile rollback | CORE | E1 | Engine scope 3 of 4 |
| NX16-016 | Full NEXTRIX rollback | CORE | E1 | Engine scope 4 of 4; order-aware |
| NX16-017 | Owner support-bundle export | CORE | E0 | Specs + journal summary, machine identifiers scrubbed; feeds the owner's manual-testing workflow (FSOS-X "Export PC Specs" [DOCUMENTED, r1]; XOS diagnostic ZIP [DOCUMENTED, r1]) |

## NX17 — Advanced Windows Configuration

Individually selectable only; never in presets; BCD/firmware-adjacent entries carry the strongest gates.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX17-001 | Timer resolution behavior | EXPERIMENTAL | E0 | 24H2+ changed timer coalescing behavior — full caution text; research-flagged |
| NX17-002 | Dynamic Tick policy (BCD) | ADVANCED | E1 | `bcdedit`; preset-excluded; restart; per-owner consent |
| NX17-003 | HPET policy (BCD) | TROUBLESHOOTING | E1 | **Arbitrary forcing forbidden**; symptom-gated; both directions risky |
| NX17-004 | Platform clock source inspection | CORE | E1 | Read-only report |
| NX17-005 | Curated BCD configuration set | ADVANCED | E1 | Each entry individually approved + journaled; never blanket |
| NX17-006 | MSI mode per-device inspection & selective enable | ADVANCED | E0 | **Per-device only** — global MSI forbidden (directive); device-stability gate |
| NX17-007 | Interrupt affinity policy per-device | ADVANCED | E0 | Per-device; topology-fed (NX19) |
| NX17-008 | System responsiveness value | ADVANCED | E0 | MMCSS-adjacent; XREF NX03-007 |
| NX17-009 | Network throttling index | ADVANCED | E0 | Honest scope note: applies to MMCSS-tagged traffic only |
| NX17-010 | Multimedia scheduler configuration | ADVANCED | E0 | XREF NX03-007 owner |
| NX17-011 | Device installation restriction policy | ADVANCED | E1 | Consent; driver-update workflow impact explained |
| NX17-012 | Memory Manager curated set | TROUBLESHOOTING | E0 | Individually approved legacy knobs; XREF NX05-007 |
| NX17-013 | Power throttling registry override | TROUBLESHOOTING | E0 | XREF NX03-006 owner |
| NX17-014 | Driver Verifier diagnostic configuration | TROUBLESHOOTING | E1 | Owner-directed test mode; strict guardrails; auto-clear procedure mandatory |

## NX18 — Game Session Manager (subsystem)

Temporary gaming configuration with reliable restoration. Companion runtime (see `PROJECT_ARCHITECTURE.md` §7).

| ID | Capability / Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX18-001 | Running game detection engine | CONDITIONAL | E0 | Detection only; feeds session start |
| NX18-002 | Launcher & child-process relationship mapping | CONDITIONAL | E0 | Launcher processes are protected, never managed |
| NX18-003 | Game-specific session profiles | CONDITIONAL | E0 | Per-game config store; user-authored defaults |
| NX18-004 | Session CPU Sets application | ADVANCED | E0 | Topology-derived (NX19-002); never hardcoded |
| NX18-005 | Session power plan switching | CONDITIONAL | E1 | Journaled; restore-on-exit; crash-safe |
| NX18-006 | Session background app management | CONDITIONAL | E0 | User-allowlist only; **never blanket termination** |
| NX18-007 | Session service suspension (allowlisted) | ADVANCED | E0 | Dependency-checked; auto-restore; never security/audio/AC services |
| NX18-008 | Session graphics configuration | CONDITIONAL | E0 | Temporary per-game composition of NX04 entries |
| NX18-009 | Session process priority configuration | CONDITIONAL | E1 | Game + selected processes only; documented APIs |
| NX18-010 | Session journal & crash/interruption recovery | CORE | E0 | Boot-time recovery check; interrupted-session ritual |
| NX18-011 | Manual session control | CORE | E0 | Start/end CLI; status display |
| NX18-012 | Protected-process policy guard | CORE | E0 | Anti-cheat/security/launcher/OBS/recording/audio/peripherals always protected |

## NX19 — CPU Topology & Scheduling

Indexes are always **derived from detected topology** — hardcoded logical processor indexes are a build-validation failure. CPU Sets and affinity remain separate mechanisms.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX19-001 | Topology detection & report engine | CORE | E1 | Vendor/hybrid/P-core/E-core/SMT/CCD via CIM; X3D detection best-effort + flagged uncertain |
| NX19-002 | CPU Set derivation engine | CORE | E1 | Derives sets from topology + workload profile |
| NX19-003 | Per-process CPU Set application | ADVANCED | E0 | Games + background classes; XREF NX18-004 |
| NX19-004 | Per-process affinity application | ADVANCED | E1 | Separate mechanism from Sets (directive) |
| NX19-005 | Per-process priority policy | CONDITIONAL | E1 | Documented APIs; narrow scope |
| NX19-006 | Scheduling profile: Competitive | CONDITIONAL | E0 | Parameter set for -002/-003/-004/-005 |
| NX19-007 | Scheduling profile: Balanced gaming | CONDITIONAL | E0 | Preserves background responsiveness |
| NX19-008 | Scheduling profile: Streaming | CONDITIONAL | E0 | Reserves encode/capture capacity; OBS-aware |
| NX19-009 | Scheduling profile: Productivity | CONDITIONAL | E0 | Multitask-friendly |
| NX19-010 | Scheduling profile: Custom builder | CONDITIONAL | E0 | User-defined set rules, topology-validated |
| NX19-011 | AMD X3D / CCD-aware placement guidance | EXPERIMENTAL | E0 | Best-effort detection flagged; R1/R3 research reconciliation |

## NX20 — Hardware & Driver Management

Driver install/removal stays separate from gaming optimization; nothing auto-installs or auto-removes drivers.

| ID | Tweak | Class | Ev | Notes |
|---|---|---|---|---|
| NX20-001 | Hardware inventory master report | CORE | E1 | CPU/GPU/RAM/board/BIOS; read-only; uncertainty-marked |
| NX20-002 | GPU vendor & driver capability report | CORE | E1 | Feeds NX04 vendor gates |
| NX20-003 | NVIDIA driver management (inventory, guidance, profile inspection) | CONDITIONAL | E1 | DDU clean-install workflow *documented, never automated* |
| NX20-004 | AMD driver management (equivalent) | CONDITIONAL | E1 | Same boundaries |
| NX20-005 | Intel driver management (equivalent) | CONDITIONAL | E1 | Same boundaries |
| NX20-006 | Network driver inspection & version report | CORE | E1 | Feeds NX07 advanced-property availability |
| NX20-007 | USB hardware inventory report | CORE | E1 | Owner of USB inventory; NX08-007 XREFs here |
| NX20-008 | Installed driver history report | CORE | E1 | Read-only |
| NX20-009 | Hardware compatibility report generator | CORE | E1 | Feeds NxCompat eligibility output |
| NX20-010 | Device configuration inspection | CORE | E1 | Per-device advanced properties; read-only |
| NX20-011 | BIOS/version currency guidance (report only) | CORE | E0 | **Never automated flashing**; owner-action guidance |

---

## Rejected / excluded from NEXTRIX

Standing policy items (directive-derived), confirmed by Phase 1 research (2026-11-23; evidence tags per `RESEARCH_RECONCILIATION.md`):

1. **Global Fullscreen Optimizations disable** — forbidden (directive NX02); per-game TROUBLESHOOTING only (NX04-005). Confirmed: XOS disables MPO globally and FSOS-X pulled its MPO toggle twice for user-reported issues [r1].
2. **Blanket service disabling / "disable-all" lists** — no such feature exists (NX11 policy). Confirmed: 50–250-service disable lists observed in four references with documented fallout (SMB1, Task Manager, THE FINALS, GameBar) [r2, r3, r4].
3. **Continuous standby-memory cleaners** — rejected (NX05-006 is diagnostics-only).
4. **Global MSI-mode forcing** — rejected; per-device only (NX17-006). Confirmed: XOS's value-presence-gated, backed-up per-device approach is the only defensible variant [r1].
5. **Arbitrary HPET / platform-clock forcing** — rejected in presets; symptom-gated only (NX17-003). Confirmed: SapphireOS forces `useplatformtick` + disables HPET devices; Vain and XOS delete the values instead — no reference ships forcing as safe [r1, r3].
6. **Universal fan-control registry tweaks / firmware writes** — rejected (NX10 policy).
7. **Hardcoded core indexes, hardcoded game EXE tables, universal adapter values** — build-validation failures. Confirmed: Vain's closed engine + 36-game hardcoded list is the counter-example [r3]; XOS's derived topology is the compliant model [r1].
8. **Pagefile disabling in standard profiles** — rejected (NX05-003 is troubleshooting-only, preset-excluded).
9. **Auto-disabling Defender/Firewall/UAC/SecureBoot/TPM/VBS** — rejected in presets; consent-gated exceptions only where documented (NX14). Confirmed: reference Defender removals are incomplete/irreversible with documented fallout (boot-recovery-screen bug, AV false positives, "reinstall Windows" recovery) [r1, r2, r3, r4].
10. **Undocumented "kitchen-sink" registry dumps from internet lists** — every registry target must trace to E1 documentation or rejected E0 candidate review. Confirmed: `custom:16000069` BCD value is undocumented even by its shipper [r2].

Phase 1 research-confirmed additions (each with source evidence in `research/sources/`):

11. **Security teardowns:** permanent test-root-certificate installation (Sapphire, Synergy [r3, r4]); Defender **file deletion** / CBS package removal (Vain, Sapphire, Synergy, Atlas, Revi [r3, r4, r2]); Mark-of-the-Web off (four references [r1–r4]); unconditional VBS/HVCI disable (silently no-ops on Secured-core — Revi #222 [r2]); unconditional BitLocker device-encryption prevention [r2]; Intel TSX enable [r2]; system-wide mitigation masks (runtime-enumerated or hardcoded) [r1, r3, r4]; IFEO `Debugger` hijacks [r1, r2, r3]; UCPD disable [r1, r2, r4].
12. **Recovery-sabotage:** System Restore / VSS / WinRE verification / RegIdleBackup / crash-dump / event-log destruction and `vssadmin delete shadows /all` (Sapphire, Vain, XOS, Revi, Synergy [r1–r4]) — the axis NEXTRIX explicitly inverts (NX16 creates and preserves recovery).
13. **Update starvation as default:** WU paused to 2038 / hardcoded future timestamps / driver delivery blocked (Synergy, Revi, XOS, Sapphire [r1–r4]).
14. **Timer forcing without backup:** `disabledynamictick yes` unbacked (Revi's own ledger: breaks ROG Ally sleep [r2]); undocumented BCD values; `bootstatuspolicy IgnoreAllFailures` (repair-hiding) [r2].
15. **Blind sweeps:** blanket device-Enum power zeroing; storage class-filter wipes; IPv6 service/binding removal; DCOM system-wide off; hosts-file blocklists; RAM-blind global svchost-split thresholds (Revi ledger: breaks XboxGipSvc [r2]; UltraOS: increases hard faults on 8–16 GB [r4]); unconditional SysMain/memory-compression disable without RAM/NVMe thresholds [r4]; hardcoded per-user service suffixes (`BcastDVRUserService_389fd`) [r4]; direct `ControlSet001` writes [r3].
16. **Trust-posture patterns:** unsigned binaries requiring Defender exclusions; fixed-password AV-evasion packaging; unpinned floating downloads at install time (`VainUpdater.exe` raw + `/silent` [r3]; .NET/vcpp fetches [r3, r4]); `Set-ExecutionPolicy Unrestricted -Force` [r1–r4]; kernel-driver helpers (`inpoutx64`) [r4]; blanket TrustedInstaller privilege for every action [r3].
17. **Integrity violations in user-facing claims:** "fully revertible" over-claims (Hone Epic listing vs its own narrower wording [r6]; UltraOS INSTALL.md vs UNDO.ps1 [r4]); "no known issues" marketing (FSOS-X [r1]); doc/code mismatches — NEXTRIX generates support matrices from code (SynToolkit floor mismatch [r4]).

## Catalogue statistics (v0.1)

282 registry entries across 20 categories (NX08-008 added 2026-11-23; NX18 category included) · risk mix: CORE ≈ 26%, CONDITIONAL ≈ 45%, ADVANCED ≈ 22%, EXPERIMENTAL ≈ 3%, TROUBLESHOOTING ≈ 5% · evidence: E1 ≈ 60%, E0 ≈ 40%, E2+ = 0 (none claimed; E2+ only via owner-supplied results).
Implementation status per entry lives in `registry/*.json` (source of truth). Wave 1 (2026-11-23) implemented NX01/NX02/NX04/NX09/NX16 at the levels recorded there; evidence corrections applied to the rows above (NX01-010, NX02-002/-003/-007 → E1; NX02-005 → E0).
