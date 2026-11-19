# GGOS — verification-first Windows 11 playbook for AME Wizard

![GGOS logo](playbook.png)

> GGOS speeds up and cleans up Windows 11 without trading a single security
> feature — and it ends every run by writing a report that proves what changed.

[![Release](https://img.shields.io/github/v/release/Goku-py/GGOS?style=flat-square&label=release)](https://github.com/Goku-py/GGOS/releases)
[![Downloads](https://img.shields.io/github/downloads/Goku-py/GGOS/total?style=flat-square&label=downloads)](https://github.com/Goku-py/GGOS/releases)
<!-- Discord badge placeholder — GGOS has no Discord server yet. Create the
     server first, then uncomment with the real server ID and invite code:
[![Discord](https://img.shields.io/discord/SERVER-ID?style=flat-square&label=Discord)](https://discord.gg/INVITE-CODE)
-->

**License:** GGOS ships no `LICENSE` file yet. Everything here is clean-room
original with per-source attribution — see
[Attribution / licenses](#attribution--licenses).

**Version 0.5.0** · 16 feature pages · 48 unique options · 26 task files ·
rollback gate → option ledger → verification pass.

> This repository is intentionally small: playbook content, the build scripts,
> the native timer source and `docs\CHANGELOG.md`. The GitHub release notes
> mirror the changelog.

GGOS is an interactive optimization, debloat and cleanup playbook for
[AME Wizard](https://amelabs.net/), written for gamers and power users who
want a faster, quieter Windows **without** breaking anti-cheat or switching
security off. You tick what you want across 16 feature pages — every option
explains itself, and hardware is auto-detected so desktops and laptops get
different values. Before anything changes, a System Restore point is created
**and verified**; when the run finishes, a verification pass writes a
PASS / DRIFT / NOTE report for every option you selected. The implementation
is clean-room original YAML/PowerShell, and nothing in it disables Defender,
Windows Update, UAC, VBS/HVCI or CPU exploit mitigations.

## The numbers

Every number on this page is countable from the repository:

| Number | What it counts |
|---|---|
| **16 feature pages** | 10 carried over from v0.4.0 + six new: Theming, Apps & browsers, OneDrive & extras, Power plan, Security check, GGOS Toolkit |
| **48 unique options** | 33 carried over + 15 new; each one independently selectable |
| **142 service changes** | 138 set to Manual, 4 disabled — security services excluded by policy |
| **71 per-user values** | swept across all loaded hives, `.DEFAULT` and the Default profile template |
| **100% option verification coverage** | every ledger option has a marker check; `ggos-verify.txt` reports PASS / DRIFT / NOTE |
| **1 verified restore point** | created before any change; the run fail-closes if none can be made |

No FPS, RAM or download figures appear on this page. The repository has none
to cite, and GGOS would rather show you its verification report than a
benchmark it cannot reproduce.

## Stock Windows vs a GGOS run

Qualitative on purpose — every row below is checkable on the machine itself:

| | Stock Windows 11 | A GGOS run |
|---|---|---|
| **Telemetry** | On at default levels, spread across registry, services and scheduled tasks | One option (`telemetry`) hardens all three surfaces |
| **Ads and bundled apps** | Start-menu suggestions, Bing results in Search, Widgets, Copilot, OEM trialware | Removed by default; OEM trial apps and the extras set (Outlook "new", consumer Teams, Clipchamp) stay opt-in |
| **Who gets the tweaks** | A tweak you paste yourself covers the profile you are logged into | 71 values swept across every loaded hive, `.DEFAULT` and the Default profile template |
| **Safety net** | None — a pasted `.reg` has no gate | Verified restore point first, per-hive `.reg` exports, a rollback manifest; fail-closed if none can be made |
| **Proof** | You hope the script did what the forum post said | An option ledger plus a PASS / DRIFT / NOTE verification report in `%SystemRoot%\GGOS\` |
| **Security** | Defender, SmartScreen, Update, UAC, VBS — all on | Identical, by policy. Nothing GGOS ships disables any of them, and the read-only `ggos-security.txt` confirms it after the run |

## Security stance

Many optimization playbooks ship a page of security trade-offs — checkboxes
that disable Defender, kernel mitigations or memory isolation for a few
percent of performance. GGOS ships the inverted table: the four trade-offs
the scene commonly offers, and the policy reason each one is absent here.

| What others ship it as | Why GGOS does not ship it |
|---|---|
| **Disable Defender / antivirus** — a "free up RAM" checkbox | A permanent teardown of the one component that catches everything else — including anything a playbook or a bad download later runs. Re-enabling Defender months on does nothing about what landed while it was off. GGOS's only Defender write is a scheduled-scan CPU cap (`ScanAvgCPULoadFactor=25`); real-time protection is never touched. |
| **Disable CPU exploit mitigations** — "Spectre/Meltdown off" flags sold as free performance | Every process on the machine — the browser you bank in included — is exposed to documented transient-execution attacks, for a gain measured in low single digits. Anti-cheat-conscious playbooks tell their Valorant and FACEIT players the same; GGOS goes further and does not ship the checkbox at all. |
| **Disable UAC** — "kill the prompts" | With the boundary gone, everything you launch runs with a full admin token — one stray download away from total system control. The prompt costs seconds; the boundary is the cheapest security on the machine. |
| **Disable VBS / HVCI** — memory isolation switched off, sold back as FPS | Virtualization-based security is what keeps credential-theft tooling out of `lsass`. Turning it off hands every process on the machine a clearer path to your credentials for a gain you will struggle to measure honestly. |

The positive counterpart is page 15: `security-posture` is a **read-only**
report of Defender, SmartScreen and Windows Update status, written to
`%SystemRoot%\GGOS\ggos-security.txt`. It changes nothing — it exists so you
can confirm, in one file, that the security surface is exactly as Windows
shipped it.

This stance is the differentiator. GGOS makes no performance claim that
requires turning security off; the performance work lives in scheduler,
service, power, network and input tuning that leaves the security surface
untouched.

## Feature pages (v0.5.0, in the order AME shows them)

| # | Page | Options |
|---|------|---------|
| 1 | **PC type** (radio) | Auto-detect (recommended) · Desktop · Laptop |
| 2 | **Core** | Core system tweaks · Service tuning · Telemetry hardening · Ads & clutter |
| 3 | **Profiles & optional** (`DependsOn` core) | All user profiles · Detailed logon · F8 boot menu · Page file |
| 4 | **Bloatware** | Copilot · Bing Search · Widgets · OEM trial apps |
| 5 | **Office & gaming** | Office telemetry · Gaming mode |
| 6 | **Cleanup & software** | Safe cleanup · Deep cleanup (cannot be undone) · Clean GPU shader caches · WinGet updates |
| 7 | **Desktop power** | CPU EPP · PCIe ASPM off · NVMe idle timeout |
| 8 | **Laptop** | GGOS Laptop plan · Wi-Fi latency fix · NVMe idle timeout (AC) |
| 9 | **Input devices** | Mouse acceleration off · Input buffer latency · Wireless dongle fix |
| 10 | **Network (wired)** | Lower ping (TCP) · Bufferbloat relief · NIC low-latency · Ultra NIC mode |
| 11 | **Theming** | Apply GGOS wallpaper |
| 12 | **Apps & browsers** | Firefox · Brave · 7-Zip · PowerToys · Steam · Discord · VLC — installed via winget as the current user |
| 13 | **OneDrive & extras** | Remove OneDrive (official uninstaller) · Disable Recall (default on, 26100+ only) · Remove extra bloatware (Outlook "new" / consumer Teams / Clipchamp) |
| 14 | **Power plan** | Ultimate Performance plan (built-in; previous plan recorded for restore) |
| 15 | **Security check** | Read-only security posture report → `ggos-security.txt` |
| 16 | **GGOS Toolkit** | Install GGOS Toolkit v0.1 (default on) |

> **Hardware pages (unchanged since 0.4.0, audit F1–F3):** both hardware pages
> are always visible; desktop-only tweaks (EPP, ASPM) are refused on laptops by
> the script-side chassis guard (`hardware-tuning.ps1`), and the laptop NVMe
> option has its own `nvme-latency-laptop` name. The desktop/laptop *radio*
> choice remains an override; auto-detect is the default.

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
| `bloat-extra` | `appx.yml` | Outlook "new" / consumer Teams / Clipchamp removals |
| `office-telemetry` | `user-registry.yml` (office group), `scheduled-tasks.yml` | per-user hive sweep |
| `gaming` | `gaming.yml` | registry + timer task + `gaming-power.ps1` |
| `cleanup` · `cleanup-aggressive` | `cleanup.yml`, `cleanup-aggressive.yml` | `cleanup-sweep.ps1` (`-Aggressive`) |
| `shader-cache` | `shader-cache.yml` | GPU shader cache cleaner (also exposed in the Toolkit) |
| `winget-update` | `winget.yml` | `winget upgrade --all` as current user |
| `ggos-theme` | `theming.yml` | apply the GGOS wallpaper |
| `app-firefox` · `app-brave` · `app-7zip` · `app-powertoys` · `app-steam` · `app-discord` · `app-vlc` | `apps.yml` | winget installs as the current user |
| `onedrive-remove` | `onedrive.yml` | Microsoft's official OneDrive uninstaller; cloud files untouched |
| `recall-disable` | `recall.yml` | WindowsAI policies (default on; 26100+ only) |
| `power-ultimate` | `power-plans.yml` | duplicate the built-in Ultimate Performance plan; record the previous plan for restore |
| `security-posture` | `security-posture.yml` | read-only status report → `%SystemRoot%\GGOS\ggos-security.txt` |
| `toolkit-install` | `toolkit.yml` | copy the GGOS Toolkit to `%SystemRoot%\GGOS\` + Start menu shortcut |
| `epp-perf` · `desktop-device-power` · `nvme-latency` · `nvme-latency-laptop` · `wireless-input` | `hardware-tuning.yml` | `hardware-tuning.ps1 -Mode …` (AC only; `epp`/`devices` refuse laptop chassis) |
| `laptop-power` | `hardware-tuning.yml` | `gaming-power.ps1 -LaptopPlan` |
| `wifi-tuning` | `network.yml` | `wifi-tuning.ps1` |
| `input-accel` · `input-queue` | `input-tuning.yml` | `input-tuning.ps1 -Mode …` |
| `network-latency` · `network-bufferbloat` · `network-nic` · `network-ultra` | `network.yml` | `network-latency.ps1`, `network-tuning.ps1 -Mode …` |

## Safety rules (non-negotiable)

1. **Restore point before any change.** System Restore is enabled if needed,
   the 24-hour creation throttle is bypassed, the point is created **and
   verified**, and the original throttle is restored. If no restore point can
   be made, targeted `HKLM\SOFTWARE` + `HKLM\SYSTEM\CurrentControlSet` registry
   exports are written instead; if neither works the playbook halts
   (fail-closed). A restore point covers system files and the registry —
   **not** Appx removals, deleted cleanup targets, winget updates, app
   installs, OneDrive removal or per-user hive edits.
2. **Desktop/laptop split.** Hardware tuning writes **AC values only**; a
   laptop is never given desktop-only EPP/ASPM settings. DC values are written
   only by the explicitly opt-in laptop power features (processor boost mode
   and the GGOS Laptop plan timeouts); every other path leaves the OS's AC/DC
   management intact.
3. **Security is out of scope.** Defender (`WinDefend`, `SecurityHealthService`,
   `wscsvc`), SmartScreen, Windows Update (`wuauserv`, `UsoSvc`, `BITS`),
   AppLocker (`AppIDSvc`) and event collection (`Wecsvc`) are never disabled.
   The only Defender value written is `ScanAvgCPULoadFactor=25`
   (scheduled-scan CPU cap; real-time protection untouched).
4. **Destructive cleanup is opt-in, default-unticked, and labelled "cannot be
   undone".** The Recycle Bin, Office auto-recover data and iTunes backups are
   never touched; `DISM /ResetBase` is not wired to any task.
5. **Everything is logged and cross-checked.** Writes go to
   `%SystemRoot%\GGOS\`: `ggos-options.txt` (ledger), `hive-backups\`
   (per-hive `.reg` exports), `skipped.txt` (bounded-timeout skips),
   `rollback-manifest.txt`, and `ggos-verify.txt` (PASS/DRIFT/NOTE). HKLM
   stamps live under `HKLM\SOFTWARE\GGOS`. Verification maps **all 48
   options**; by-design dynamic areas (package removals and installs,
   cleanups, live driver state) report `NOTE` instead of a pretended PASS.
6. **The v0.5.0 surfaces follow the same rules.** OneDrive removal runs
   Microsoft's official uninstaller and never touches cloud files — anything
   already in OneDrive stays in OneDrive. The security check is read-only: it
   reports status and writes one text file, nothing else. App installs run as
   the current user via winget, not as TrustedInstaller. Recall disabling is
   registry policy only (WindowsAI), build-gated to 26100+ where Recall
   exists.

## Verification and logging

| Artefact | Writer | Meaning |
|---|---|---|
| `%SystemRoot%\GGOS\ggos-options.txt` | `options-ledger.yml` | Options the user selected |
| `%SystemRoot%\GGOS\rollback-manifest.txt` | `rollback.ps1` | Restore-point sequence / export paths |
| `%SystemRoot%\GGOS\skipped.txt` | `Invoke-GGCommand` | Commands that exceeded their timeout |
| `%SystemRoot%\GGOS\hive-backups\*.reg` | `per-user.ps1`, `input-tuning.ps1` | Per-hive registry exports before writes |
| `%SystemRoot%\GGOS\ggos-verify.txt` | `verify.ps1` | PASS / DRIFT / NOTE per mapped option |
| `%SystemRoot%\GGOS\ggos-security.txt` | `security-posture.yml` | Read-only Defender / SmartScreen / Windows Update status report |
| `%SystemRoot%\GGOS\` (Toolkit app) | `toolkit.yml` | GGOS Toolkit v0.1 files + Start menu shortcut |
| `HKLM\SOFTWARE\GGOS` | `verify.ps1` | `Installed`, `AppliedVersion`, `LastVerify` |
| `HKLM\SOFTWARE\GGOS\HardwarePolicy` | `hardware-policy.ps1` | Chassis, drive type, RAM, policies |
| `HKLM\SOFTWARE\GGOS\PreviousPowerPlan` | `gaming-power.ps1` | Prior plan GUID for manual restore |
| `HKLM\SOFTWARE\GGOS\NetworkUndo` | network scripts | Prior TCP/NIC/Wi-Fi values |

## GGOS Toolkit v0.1

Page 16 installs the **GGOS Toolkit v0.1** — a single-file PowerShell WinForms
companion app copied to `%SystemRoot%\GGOS\` with a Start menu shortcut. The
companion-app idea is proven elsewhere in the scene (the XOS Toolkit, FSOS's
Dash); GGOS's version is one script with no dependencies:

- **Dashboard** — reads the `HKLM\SOFTWARE\GGOS` stamps and shows what was
  applied, on which version, and what the last verification said.
- **Re-run verification** — the same verification pass as the playbook,
  refreshable any time; rewrites `ggos-verify.txt`.
- **Shader cache cleaner** — the page-6 GPU shader cache clean, available on
  demand.
- **Curated installs** — the page-12 app set (Firefox, Brave, 7-Zip,
  PowerToys, Steam, Discord, VLC) via winget as the current user.
- **Restore guidance** — points to the restore point, `rollback-manifest.txt`
  and the per-hive exports, and states plainly what is not reversible.

It is labelled **v0.1** because it is v0.1: it reads the playbook's state and
offers its two repeatable actions. The playbook remains the source of truth;
the Toolkit reads its stamps rather than becoming a second control surface.

## Research notes (why these tweaks exist)

- **Timer resolution (24H2):** Windows 11 24H2 stopped applying user-process
  timer requests system-wide; `GlobalTimerResolutionRequests`/
  `SerializeTimerExpiration` restore it (build-gated `>=22621`). The resident
  helper holds 0.5 ms from a SYSTEM boot task.
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
  uses `powercfg /setacvalueindex … PERFEPP 0`. Applied desktop-only,
  AC-only; never on laptops (Thread Director wins there).
- **NVMe idle states:** "Primary NVMe Idle Timeout" is documented (GUID
  `D639518A-E56D-4345-8AF2-B9F32FB26109`); raising it on AC removes
  wake-latency micro-stutters without a battery tax.
- **Input:** `MouseDataQueueSize`/`KeyboardDataQueueSize` are
  community-contested; GGOS ships value 8 (inside the ~8–16 floor; lower than
  3 drops inputs) as an explicit opt-in.
- **Wi-Fi:** MIMO Power Save (No SMPS), U-APSD off, roaming aggressiveness
  low and the adapter power-off toggle are documented latency-spike causes.
  `netsh wlan autoconfig off` is deliberately **not** used.
- **Ultimate Performance plan:** page 14 offers Microsoft's built-in
  `Ultimate Performance` scheme (duplicated, not hand-rolled), and records the
  previous plan first so the switch is reversible with one
  `powercfg /setactive` call.
- **Recall:** disabled through the documented `WindowsAI` policy keys; the
  option is build-gated to 26100+ where Recall's snapshot pipeline ships.
- **What GGOS deliberately does NOT ship:** CPU mitigation/VBS/Defender/
  hypervisor removal, event-channel mass-disable, device-manager disabling
  (HPET/ACPI), MSI-mode sweeps, `!systemPackage`, and any default-on security
  trade-off.

## Attribution / licenses

- **CTT WinUtil** (`ChrisTitusTech/winutil`, MIT): specific registry/service/
  task values re-used where noted — MIT notice preserved in task file headers.
- **TBOK-Win11Optimizer**: no upstream license; used as a reference
  specification only (semantics ported, no code copied). No affiliation
  implied.
- **Community playbooks** (Atlas GPL-3.0, ReviOS CC BY-SA 4.0, FSOS-X
  PolyForm NC, XOS CC BY-NC-ND, others unlicensed): studied for patterns and
  engineering discipline; no code copied, upstream binaries not
  redistributed.

GGOS ships no `LICENSE` file yet; everything in this repository is clean-room
original with the attributions above.

## FAQ

### How do I install it?

1. Install **AME Wizard (Beta)** from [amelabs.net](https://amelabs.net/).
2. Download the newest `.apbx` from the
   [releases page](https://github.com/Goku-py/GGOS/releases) — the release
   badge above always points at the latest tag.
3. Open it with AME Wizard, pick options across the 16 pages, and let it run.
   The Wizard enforces the declared gates: supported builds only
   (22621–26300), no pending updates, plugged in. Elevation is supplied by
   AME's `!powerShell` default `runas`; no separate elevation tool is
   shipped.
4. When it finishes, read `%SystemRoot%\GGOS\ggos-verify.txt` — every option
   you selected, PASS / DRIFT / NOTE.

AME Wizard also polls this repository's releases, so an installed playbook
offers its own updates when a new version ships.

### Is it anti-cheat safe?

Yes. Nothing GGOS ships breaks EAC, Vanguard or FACEIT: the playbook never
disables Defender or real-time protection, never turns off CPU exploit
mitigations, VBS/HVCI or UAC, and contains no driver-level "tweaks",
MSI-mode sweeps or device-manager disabling. Nothing it does touches the
kernel security surface those anti-cheats run on. GGOS cannot promise what
third-party software does on your machine, but it promises its own surface —
zero security trade-offs — and the read-only `ggos-security.txt` report lets
you check that surface after any run.

### Can I undo it?

Partly, and GGOS states exactly which part. The verified restore point (or
the targeted registry exports, if no point can be created) covers system
files and the HKLM registry — every core, service, task, power and network
change. Not covered, by design: Appx removals, cleanup deletions, winget
updates, newly installed apps, OneDrive removal and the Toolkit copy. Those
options are labelled accordingly — deep cleanup says "cannot be undone" on
the page itself. Per-user hive edits are covered separately by the `.reg`
exports in `%SystemRoot%\GGOS\hive-backups\`. The Ultimate Performance
switch records your previous plan; network scripts record prior values under
`HKLM\SOFTWARE\GGOS\NetworkUndo`.

### Does the OneDrive option delete my files?

No. `onedrive-remove` runs Microsoft's official OneDrive uninstaller and
removes the app — not your account and not your data. Anything already
stored in OneDrive stays in the cloud, and you can reinstall the app and
sign back in at any time. GGOS never deletes user files.

### How is GGOS different from XOS, FSOS-X or SynergyOS?

All four projects want the same thing — a faster, cleaner Windows — and each
is good at something. **XOS** leads with reversibility: every change undoable
from the XOS Toolkit, plus video guides. **FSOS-X** has the widest reach — a
polished marketing site, concrete before/after numbers, the Dash companion
app, and anti-cheat-conscious guidance for Valorant and FACEIT players.
**SynergyOS** documents its security trade-offs honestly, down to why you
might not want some of them, and supports LTSC.

GGOS differentiates on three things: the **verification pass** (a
PASS/DRIFT/NOTE report written for every selected option at the end of every
run), a **hard no-security-trade-off policy** (the four common trade-offs
are not offered anywhere in the playbook), and **clean-room original code**
with per-source attribution. v0.5.0 closes the companion-app gap with the
GGOS Toolkit, and where others document their trade-offs, GGOS documents why
it never ships them.

### Does it support Windows 10?

No. Windows 11 22H2–26H2 only (builds 22621 / 22631 / 26100 / 26200 / 26300),
by design: several tweaks target 24H2-and-newer behaviour (timer resolution
semantics, Recall policies, Widgets packages), and AME Wizard refuses
unlisted builds outright. If you need Windows 10 or LTSC coverage, SynergyOS
declares LTSC support.

## Requirements

- **Windows 11 22H2 (build 22621) through 26H2 (26300).** The playbook declares
  `<SupportedBuilds>` and AME Wizard refuses unlisted builds. Several values
  are build-gated (24H2 timer semantics, Recall policies, Widgets packages).
  Windows 10 is **not** a supported target.
- **AME Wizard Beta** (the `.apbx` format is 7z/AES-256, password `malte`).
- **Administrator / TrustedInstaller** — supplied by AME's `!powerShell`
  default `runas`; no separate elevation tool is shipped.
- Free disk space for a System Restore point plus registry exports.

## Structure

```text
GGOS/
├── playbook.conf            # Metadata, requirements, 16 feature pages, icon ref
├── playbook.png             # 256x256 icon (AME expects playbook.png at the root)
├── Configuration/
│   ├── main.yml             # Task orchestration (rollback gate runs first)
│   └── Tasks/               # Action files: registry, services, appx, power, cleanup,
│                            # theming, apps, onedrive, recall, security, toolkit, …
├── Executables/             # PowerShell scripts + pinned GGOSSetTimerResolution.exe
├── docs/CHANGELOG.md        # Per-version history
└── dist/                    # Built .apbx artifacts (untracked)
```

## Packaging

The released `.apbx` is built by maintainer-local `Build-Playbook` scripts
that are deliberately not part of this repository — they are developer
tooling, not user content. The package contains only what AME Wizard
requires: `playbook.conf`, `playbook.png`, `Configuration\` and
`Executables\`. The shipped timer helper binary is pinned by SHA-256 and
the packaging tool fails closed if the shipped bytes differ from the pin.
The archive is 7z format with LZMA2 + AES-256 and **header encryption
on**, which is what AME Beta's loader accepts (a legacy ZipCrypto archive
is rejected with "Wrong password").

The password is public (`malte`) on purpose: anyone can open the package with
7-Zip and read every task before running it. Nothing in the archive is
hidden.

## Documentation

The historical design documents (v0.2 specification, project audits, VM
smoke-test materials) live in the git history and the release notes;
`docs\CHANGELOG.md` carries the per-version history. The working tree
intentionally stays small.

## Status

**v0.5.0** — feature expansion: six new feature pages (Theming, Apps &
browsers, OneDrive & extras, Power plan, Security check, GGOS Toolkit), a
shader-cache cleanup option on the Cleanup page, 48 options across 16 pages,
and the GGOS Toolkit v0.1 companion app.

The runtime AME Wizard smoke test on a disposable VM remains the open gate;
see the release notes for the verification status of every item.
