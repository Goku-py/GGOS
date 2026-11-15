# GGOS — AME Wizard Playbook

An interactive Windows 10/11 optimization, debloat and cleanup playbook for
[AME Wizard](https://amelabs.net/). GGOS combines ideas from TBOK-Win11Optimizer
(hardware-aware tuning, per-user tweaks for all profiles), CTT WinUtil (MIT) and
community playbook patterns (Atlas, ReviOS, FSOS-X, Nova, Sapphire, Synergy, PeakOS,
vain, XOS) — implemented clean-room as original YAML/PowerShell.

![GGOS logo](playbook.png)

## Structure

```
GGOS/
├── playbook.conf            # Metadata, requirements, interactive feature pages, icon ref
├── playbook.png             # 256x256 icon (AME expects playbook.png at the root)
├── Configuration/
│   ├── main.yml             # Task orchestration
│   └── Tasks/               # Action files (registry, services, appx, power, ...)
├── Executables/             # PowerShell helpers + GGOSSetTimerResolution.exe
├── Native/                  # C# source for the native helper (repo-only, not packaged)
└── docs/                    # Specs and decision records
```

Build the `.apbx` with `..\Build-Playbook.ps1 -Path .\GGOS` (7-Zip, password `malte`,
AME-native 7z/AES format, round-trip verified).

## Feature pages (v0.3.0)

1. **PC type** — Auto-detect / Desktop / Laptop (radio; explicit choice overrides detection)
2. **Core** — system tweaks · service tuning (~140 to manual) · telemetry hardening · ads/clutter
3. **Profiles & optional** — per-user tweaks for all profiles · verbose logon · F8 boot · pagefile
4. **Bloatware** — Copilot · Bing Search · Widgets · OEM trial apps
5. **Office & gaming** — Office telemetry · gaming mode (chassis-aware)
6. **Desktop-only power** — CPU EPP · PCIe ASPM off · NVMe idle timeout
7. **Laptop-only** — GGOS Laptop power plan · Wi-Fi latency fix · NVMe idle timeout (AC)
8. **Input devices** — mouse acceleration off · input buffer latency · wireless dongle stutter fix
9. **Cleanup & software** — safe cleanup · deep cleanup · WinGet app updates
10. **Network (wired)** — lower ping (TCP) · bufferbloat relief · NIC low-latency · ultra NIC mode

## Safety rules (non-negotiable)

1. Restore point + registry export **before any change** (fail-closed; playbook halts otherwise).
2. Desktop/laptop split: **battery (DC) power settings are never modified** — laptop plans
   preserve the OS's own AC/DC management.
3. Security is out of scope: Defender, SmartScreen, Windows Update (`wuauserv`, `BITS`,
   `UsoSvc`), AppLocker (`AppIDSvc`) are never disabled.
4. Destructive cleanup is opt-in, default-unticked, and labelled "cannot be undone";
   the Recycle Bin and Office autorecover data are never touched.
5. Every change is logged (`%SystemRoot%\GGOS\`), recorded for undo where possible, and
   verified at the end of the run (`ggos-verify.txt`).

## Research notes (why these tweaks exist)

- **Timer resolution (24H2):** Windows 11 24H2 stopped applying user-process timer requests
  system-wide; `GlobalTimerResolutionRequests`/`SerializeTimerExpiration` restore it
  (community-documented, build-gated `>=22621` in our YAML).
- **Bufferbloat:** the full fix is router-side Smart Queue Management (fq_codel/CAKE/PIE) —
  see [bufferbloat.net](https://bufferbloat.net/projects/bloat/wiki/What_can_I_do_about_Bufferbloat/).
  Windows-side we only stop the PC from *contributing*: TCP pacing, ECN enabled (routers mark
  congestion instead of dropping → no packet loss), auto-tuning pinned to Normal.
- **UDP:** Microsoft documents URO (UDP Receive Segment Coalescing Offload) from Windows 11
  24H2 — [UDP RSC Offload](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/udp-rsc-offload).
  Most other "UDP buffer" tweaks circulating in the community are placebo; we touch only the
  documented surface.
- **CPU EPP:** `PERFEPP` is a documented hidden power setting; Intel's own guidance uses
  `powercfg /setacvalueindex scheme_current sub_processor PERFEPP 0`. Win11 overrides EPP
  per-thread via QoS hints, so we apply it desktop-only, AC-only, and never on laptops
  (Thread Director wins there).
- **NVMe idle states:** "Primary NVMe Idle Timeout" is a documented power setting
  (GUID `D639518A-E56D-4345-8AF2-B9F32FB26109`); raising it on AC removes wake-latency
  micro-stutters without a battery tax.
- **Input:** `MouseDataQueueSize`/`KeyboardDataQueueSize` are community-contested
  (see xbitlabs' "Placebo or an Actual Improvement?"); we ship value 8 — inside the
  validated floor (~8-16; lower than 3 drops inputs) — as an explicit opt-in.
- **Wi-Fi:** MIMO Power Save (No SMPS), U-APSD off, roaming aggressiveness low and the
  adapter power-off toggle are documented latency-spike causes (Microsoft Q&A, Intel forums).
  `netsh wlan autoconfig off` is deliberately **not** used (breaks WLAN service functionality).
- **What we deliberately do NOT ship:** CPU mitigation/VBS/Defender/hypervisor removal,
  event-channel mass-disable, device-manager disabling (HPET/ACPI devices), MSI-mode sweeps,
  `!systemPackage` (deprecated upstream with breakage evidence), and any default-on
  security trade-off.

## Attribution / licenses

- **CTT WinUtil** (`ChrisTitusTech/winutil`, MIT): specific registry/service/task values
  re-used where noted — MIT notice preserved in task file headers.
- **TBOK-Win11Optimizer**: no license exists upstream; used as a reference specification
  only (semantics ported, no code copied). No affiliation implied.
- **Community playbooks** (Atlas GPL-3.0, ReviOS CC BY-SA 4.0, FSOS-X PolyForm NC, others
  unlicensed): studied for patterns and engineering discipline; no code copied, upstream
  binaries not redistributed.

## Status

v0.3.0 — ten feature pages, hardware-aware desktop/laptop branching, rollback gate,
option ledger + verification pass, native timer-resolution helper, researched network
stack. Runtime smoke-testing in AME Wizard on a disposable VM is the final gate.
