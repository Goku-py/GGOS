# GGOS — AME Wizard Playbook

An interactive Windows optimization, debloat and cleanup playbook for
[AME Wizard](https://amelabs.net/), implemented clean-room as original
YAML/PowerShell. GGOS combines ideas from TBOK-Win11Optimizer (hardware-aware
tuning, per-user tweaks), CTT WinUtil (MIT) and community playbook patterns
(Atlas, ReviOS, FSOS-X, Nova, Sapphire, Synergy, PeakOS, vain, XOS).

![GGOS logo](playbook.png)

**Version 0.4.0** · 10 feature pages · 33 unique options · 18 task files ·
rollback gate → option ledger → verification pass.

> This repository is intentionally minimal: it contains only the playbook
> content AME Wizard consumes. Release notes double as the changelog (see the
> GitHub Releases), and packaging/build tooling is maintained locally and is
> not published.

## Requirements

- **Windows 11 22H2 (build 22621) through 26H2 (26300).** The playbook declares
  `<SupportedBuilds>` and AME Wizard refuses unlisted builds. Several values are
  build-gated (24H2 timer semantics, Recall policies, Widgets packages).
  Windows 10 is **not** a supported target.
- **AME Wizard Beta** (the `.apbx` format is 7z/AES-256, password `malte`).
- **Administrator / TrustedInstaller** — supplied by AME's `!powerShell` default
  `runas`; no separate elevation tool is shipped.
- Free disk space for a System Restore point plus registry exports.

## Structure

```text
GGOS/
├── playbook.conf            # Metadata, requirements, 10 feature pages, icon ref
├── playbook.png             # 256x256 icon (AME expects playbook.png at the root)
├── Configuration/
│   ├── main.yml             # Task orchestration (rollback gate first)
│   └── Tasks/               # 18 action files (registry, services, appx, power, ...)
├── Executables/             # 13 PowerShell files + GGOSSetTimerResolution.exe
└── dist/                    # Built .apbx artifacts (untracked)
```

## Packaging

The released `.apbx` is built with maintainer-local tooling that is
deliberately not part of this repository. The package contains only what AME
Wizard requires: `playbook.conf`, `playbook.png`, `Configuration\` and
`Executables\`. The shipped timer helper binary is pinned by SHA-256 and the
packaging tool fails closed if the shipped bytes differ from the pin. The
archive is 7z format with LZMA2 + AES-256 and **header
encryption on**, which is what AME Beta's loader accepts (a legacy ZipCrypto
archive is rejected with "Wrong password").

## Feature pages (v0.4.0, in the order AME shows them)

| # | Page | Options |
|---|------|---------|
| 1 | **PC type** (radio) | Auto-detect (recommended) · Desktop · Laptop |
| 2 | **Core** | Core system tweaks · Service tuning · Telemetry hardening · Ads & clutter |
| 3 | **Profiles & optional** (`DependsOn` core) | All user profiles · Detailed logon · F8 boot menu · Page file |
| 4 | **Bloatware** | Copilot · Bing Search · Widgets · OEM trial apps |
| 5 | **Office & gaming** | Office telemetry · Gaming mode |
| 6 | **Cleanup & software** | Safe cleanup · Deep cleanup (cannot be undone) · WinGet updates |
| 7 | **Desktop power** | CPU EPP · PCIe ASPM off · NVMe idle timeout |
| 8 | **Laptop** | GGOS Laptop plan · Wi-Fi latency fix · NVMe idle timeout (AC) |
| 9 | **Input devices** | Mouse acceleration off · Input buffer latency · Wireless dongle fix |
| 10 | **Network (wired)** | Lower ping (TCP) · Bufferbloat relief · NIC low-latency · Ultra NIC mode |

> **Hardware pages (fixed in 0.4.0, audit F1–F3):** both hardware pages are now
> always visible; desktop-only tweaks (EPP, ASPM) are refused on laptops by the
> script-side chassis guard (`hardware-tuning.ps1`), and the laptop NVMe option
> has its own `nvme-latency-laptop` name. The desktop/laptop *radio* choice
> remains an override; auto-detect is the default.

## Option → task map

| Option | Task file(s) | Executable / action |
|---|---|---|
| `system-optimization` | `system-registry.yml`, `scheduled-tasks.yml`, `hardware-policy.yml` | registry + `hardware-policy.ps1` |
| `services` | `services.yml` | 142 service changes (138 manual, 4 disabled) |
| `telemetry` | `telemetry.yml`, `scheduled-tasks.yml` | registry + services + tasks |
| `ads-ui` | `system-registry.yml` | registry |
| `per-user` | `user-registry.yml` | `per-user.ps1` (71 values × loaded hives, `.DEFAULT`, Default template) |
| `verbose-logon` · `f8-boot` · `pagefile` | `system-registry.yml` | inline PowerShell |
| `bloat-copilot` · `bloat-bing` · `bloat-widgets` · `bloat-oem` | `appx.yml` | 29 Appx family removals |
| `office-telemetry` | `user-registry.yml` (office group), `scheduled-tasks.yml` | per-user hive sweep |
| `gaming` | `gaming.yml` | registry + timer task + `gaming-power.ps1` |
| `cleanup` · `cleanup-aggressive` | `cleanup.yml`, `cleanup-aggressive.yml` | `cleanup-sweep.ps1` (`-Aggressive`) |
| `winget-update` | `winget.yml` | `winget upgrade --all` as current user |
| `epp-perf` · `desktop-device-power` · `nvme-latency` · `nvme-latency-laptop` · `wireless-input` | `hardware-tuning.yml` | `hardware-tuning.ps1 -Mode …` (AC only; `epp`/`devices` refuse laptop chassis) |
| `laptop-power` | `hardware-tuning.yml` | `gaming-power.ps1 -LaptopPlan` |
| `wifi-tuning` | `network.yml` | `wifi-tuning.ps1` |
| `input-accel` · `input-queue` | `input-tuning.yml` | `input-tuning.ps1 -Mode …` |
| `network-latency` · `network-bufferbloat` · `network-nic` · `network-ultra` | `network.yml` | `network-latency.ps1`, `network-tuning.ps1 -Mode …` |

## Safety rules (non-negotiable)

1. **Restore point before any change.** System Restore is enabled if needed, the
   24-hour creation throttle is bypassed, the point is created **and verified**,
   and the original throttle is restored. If no restore point can be made,
   targeted `HKLM\SOFTWARE` + `HKLM\SYSTEM\CurrentControlSet` registry exports are
   written instead; if neither works the playbook halts (fail-closed). A restore
   point covers system files and the registry — **not** Appx removals, deleted
   cleanup targets, winget updates or per-user hive edits.
2. **Desktop/laptop split.** Hardware tuning writes **AC values only**; a laptop
   is never given desktop-only EPP/ASPM settings. DC values are written only by
   the explicitly opt-in laptop power features (processor boost mode and the
   GGOS Laptop plan timeouts); every other path leaves the OS's AC/DC management
   intact.
3. **Security is out of scope.** Defender (`WinDefend`, `SecurityHealthService`,
   `wscsvc`), SmartScreen, Windows Update (`wuauserv`, `UsoSvc`, `BITS`),
   AppLocker (`AppIDSvc`) and event collection (`Wecsvc`) are never disabled.
   The only Defender value written is `ScanAvgCPULoadFactor=25` (scheduled-scan
   CPU cap; real-time protection untouched).
4. **Destructive cleanup is opt-in, default-unticked, and labelled "cannot be
   undone".** The Recycle Bin, Office auto-recover data and iTunes backups are
   never touched; `DISM /ResetBase` is not wired to any task.
5. **Everything is logged and cross-checked.** Writes go to
   `%SystemRoot%\GGOS\`: `ggos-options.txt` (ledger), `hive-backups\` (per-hive
   `.reg` exports), `skipped.txt` (bounded-timeout skips),
   `rollback-manifest.txt`, and `ggos-verify.txt` (PASS/DRIFT/NOTE). HKLM stamps
   live under `HKLM\SOFTWARE\GGOS`. Verification maps **all 33 options**;
   only the five by-design dynamic areas (`bloat-oem`, `cleanup`,
   `cleanup-aggressive`, `winget-update`, `network-ultra`) report `NOTE`.

## Verification and logging

| Artefact | Writer | Meaning |
|---|---|---|
| `%SystemRoot%\GGOS\ggos-options.txt` | `options-ledger.yml` | Options the user selected |
| `%SystemRoot%\GGOS\rollback-manifest.txt` | `rollback.ps1` | Restore-point sequence / export paths |
| `%SystemRoot%\GGOS\skipped.txt` | `Invoke-GGCommand` | Commands that exceeded their timeout |
| `%SystemRoot%\GGOS\hive-backups\*.reg` | `per-user.ps1`, `input-tuning.ps1` | Per-hive registry exports before writes |
| `%SystemRoot%\GGOS\ggos-verify.txt` | `verify.ps1` | PASS / DRIFT / NOTE per mapped option |
| `HKLM\SOFTWARE\GGOS` | `verify.ps1` | `Installed`, `AppliedVersion`, `LastVerify` |
| `HKLM\SOFTWARE\GGOS\HardwarePolicy` | `hardware-policy.ps1` | Chassis, drive type, RAM, policies |
| `HKLM\SOFTWARE\GGOS\PreviousPowerPlan` | `gaming-power.ps1` | Prior plan GUID for manual restore |
| `HKLM\SOFTWARE\GGOS\NetworkUndo` | network scripts | Prior TCP/NIC/Wi-Fi values |

## Research notes (why these tweaks exist)

- **Timer resolution (24H2):** Windows 11 24H2 stopped applying user-process timer
  requests system-wide; `GlobalTimerResolutionRequests`/`SerializeTimerExpiration`
  restore it (build-gated `>=22621`). The resident helper holds 0.5 ms from a
  SYSTEM boot task.
- **Bufferbloat:** the full fix is router-side Smart Queue Management
  (fq_codel/CAKE/PIE) — see
  [bufferbloat.net](https://bufferbloat.net/projects/bloat/wiki/What_can_I_do_about_Bufferbloat/).
  Windows-side GGOS only stops the PC from *contributing*: TCP pacing, ECN,
  auto-tuning pinned to Normal.
- **UDP:** URO (UDP Receive Segment Coalescing Offload) is documented from
  Windows 11 24H2 —
  [UDP RSC Offload](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/udp-rsc-offload).
  Most other community "UDP buffer" tweaks are placebo; only the documented
  surface is touched.
- **CPU EPP:** `PERFEPP` is a documented hidden power setting; Intel's guidance
  uses `powercfg /setacvalueindex … PERFEPP 0`. Applied desktop-only, AC-only;
  never on laptops (Thread Director wins there).
- **NVMe idle states:** "Primary NVMe Idle Timeout" is documented (GUID
  `D639518A-E56D-4345-8AF2-B9F32FB26109`); raising it on AC removes wake-latency
  micro-stutters without a battery tax.
- **Input:** `MouseDataQueueSize`/`KeyboardDataQueueSize` are community-contested;
  GGOS ships value 8 (inside the ~8–16 floor; lower than 3 drops inputs) as an
  explicit opt-in.
- **Wi-Fi:** MIMO Power Save (No SMPS), U-APSD off, roaming aggressiveness low and
  the adapter power-off toggle are documented latency-spike causes.
  `netsh wlan autoconfig off` is deliberately **not** used.
- **What GGOS deliberately does NOT ship:** CPU mitigation/VBS/Defender/hypervisor
  removal, event-channel mass-disable, device-manager disabling (HPET/ACPI),
  MSI-mode sweeps, `!systemPackage`, and any default-on security trade-off.

## Attribution / licenses

- **CTT WinUtil** (`ChrisTitusTech/winutil`, MIT): specific registry/service/task
  values re-used where noted — MIT notice preserved in task file headers.
- **TBOK-Win11Optimizer**: no upstream license; used as a reference specification
  only (semantics ported, no code copied). No affiliation implied.
- **Community playbooks** (Atlas GPL-3.0, ReviOS CC BY-SA 4.0, FSOS-X PolyForm NC,
  others unlicensed): studied for patterns and engineering discipline; no code
  copied, upstream binaries not redistributed.

## Documentation

The historical design documents (v0.2 specification, project audit with
findings and dispositions, changelog, VM smoke-test checklist) live in the
git history and in the v0.4.0 release notes on GitHub — the working tree
intentionally keeps only playbook content.

## Status

**v0.4.0** — feature-page repairs (F1/F2/F3/F9), engine-verified option-gating
semantics (F14), exit-code-aware command wrapper (F4), `SupportedBuilds`
(F8), reproducible timer helper + strict package manifest (F10/F11), full
verification coverage (F7).

The runtime AME Wizard smoke test on a disposable VM remains the open gate;
see the v0.4.0 release notes for the verification status of every item.
