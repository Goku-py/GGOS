# NEXTRIX — Tweak Research

**Status:** Phase 1 deliverable · generated 2026-11-23. Maps reference-project behavior per tweak family to NEXTRIX catalogue decisions. Evidence tags and sources in `research/sources/r1–r6`; decisions cross-referenced to `TWEAK_CATALOGUE.md` IDs. **No performance claim below is evidence-backed; none may be promoted beyond E0/E1 without owner-supplied results.**

---

## 1. Gaming & capture (NX02/NX04)

- **Game Mode / Game Bar / DVR:** XOS kills GameBar via IFEO `Debugger=systray.exe` hijack [r1, IMPLEMENTED — rejected]; ReviOS/Sapphire set capture-off values [r2, r3]; FSOS-X keeps Game Mode configurable [r1]. → NEXTRIX: NX02-001 keeps Game Mode CORE; DVR/capture off stays CONDITIONAL with Streamer-profile exclusion. IFEO hijacks are on the rejected list.
- **HAGS:** set ON by Vain/Synergy without capability checks [r3, r4]; XOS gates on build ≥19041 [r1]; Sophia gates on WDDM ≥2.7 + dGPU [r5]. → NX04-001 ADVANCED with vendor/driver/build gates stands. SapphireOS's comment/value contradiction (`HwSchMode=2` labeled "Disable") is the canonical NxVerify argument [r3].
- **FSO:** Vain forces FSE behavior values globally [r3]; XOS *deletes* FSE override values (restoring default) [r1]. → Directive rule confirmed: NX04-005 per-game TROUBLESHOOTING only; no global disable.
- **MPO:** disabled globally by XOS/Sapphire [r1, r3]; FSOS-X's own MPO history (pulled R10 after user-reported crashes/composition errors, returned R11 as AMD-automatic + TDR fix) [r1]. → NX04-006 TROUBLESHOOTING, symptom-gated, vendor-conditional. Never a preset item.
- **VRR / windowed-games optimization:** both documented toggles; Vain enables `SwapEffectUpgradeEnable=1` [r3]; XOS enables it but turns VRR-windowed off [r1]. → NX04-003/NX02-005 CONDITIONAL E1 as catalogued.

## 2. CPU & scheduling (NX03/NX19)

- **Win32PrioritySeparation:** values observed 36 (Vain, Synergy) / 38 (XOS, Revi) / 42 (Sapphire) / 26-with-picker-UI (Synergy SOS folder) — five references, five values, zero evidence [r1–r4, all IMPLEMENTED]. → NX03-008 stays ADVANCED, preset-excluded, full-explanation-mandatory; owner testing would be the only legitimate E2 path.
- **Topology/scheduling:** no open reference implementation exists to copy (Sapphire has none; Vain's is closed; XOS's is open but CC BY-NC-ND). → NX19 implements the documented-API derivation chain openly (r1's validated approach); X3D via L3-asymmetry heuristic stays best-effort/flagged (NX19-011).
- **CPU Sets vs affinity:** XOS documents anti-cheats tolerating default CPU Sets while blocking/overriding affinity masks [r1, DOCUMENTED]; FSOS-X reports anti-cheat blocking back to the user [r1]. → NX19-003/004 split stands; NX18-012 anti-cheat guard extended with per-title verification during owner testing.
- **svchost splitting:** RAM-blind global thresholds (Vain/Sapphire `0xffffffff`; XOS 3670016; WinUtil RAM-derived per-machine; Synergy 4 GB constant) — ReviOS's own ledger records it breaking XboxGipSvc [r2]. → Rejected as a NEXTRIX tweak; WinUtil's RAM-derived conditional version is recorded as the only defensible variant and it still stays out of the catalogue (no demonstrated need).
- **MMCSS `SystemResponsiveness`:** 10 written by XOS/Vain/Sapphire/Synergy; stock is 20 (UltraOS records stock correctly) [r1–r4]. → NX03-007/NX17-008 ADVANCED, stock-state journaled, no preset.
- **Mitigations:** system-wide nuking in four references; Atlas's vendor-aware values + Vanguard CFG exception is the only careful variant [r2]; UltraOS ships a deliberately narrow 4-item opt-in and refuses the blanket mask [r4]. → NEXTRIX: no mitigation changes in any preset (Section 15); any per-item consent-gated exception inherits Atlas's vendor-awareness and anti-cheat exception pattern if ever implemented (currently none catalogued).

## 3. Memory (NX05)

- **Memory compression:** disabled unconditionally by Vain/Sapphire/Synergy [r3, r4]; UltraOS restricts to 16 GB+ RAM and reverts via `Enable-MMAgent` (not registry) [r4]. → NX05-004 ADVANCED with RAM-threshold parameters; SysMain+compression-without-thresholds joins the rejected list (UltraOS: increases hard faults on 8–16 GB).
- **Pagefile:** references leave it managed or don't touch it (XOS forces `AutomaticManagedPagefile=$true` as a *stability probe* [r5-Sophia, r1-XOS]). → NX05-001/002 as catalogued; NX05-003 stays troubleshooting-only, preset-excluded.
- **`DisablePagingExecutive`/`DisablePageCombining`:** Vain sets both [r3] — undocumented-benefit territory. → NX17-012 curated TROUBLESHOOTING only, if ever; not implemented by default.

## 4. Storage & filesystem (NX06)

- **NTFS 8.3 / last-access:** common across references via documented `fsutil` [r1–r4]. → NX06-008/009 CONDITIONAL E1 confirmed; per-volume journaled.
- **TRIM:** verified enable-and-check is documented behavior [r4 capability notes]. → NX06-002 CORE stands.
- **Write-cache sweeps:** Sapphire's blanket `UserWriteCacheSetting`/`CacheIsPowerProtected` writes [r3] rejected — power-loss risk without per-device consent; NX06-011 stays per-device CONDITIONAL with the trade-off text mandatory.
- **Component cleanup:** WinUtil's `DISM /ResetBase` (makes updates uninstallable) [r5] rejected; Sophia/UltraOS cleanup without `/ResetBase` [r4, r5] → NX16-009's "reset-base explicitly not default" confirmed correct.

## 5. Network (NX07)

- **NIC advanced keywords:** capability probing before every write (Synergy `Ndi\Params` min/max/enum — unlicensed, idea only [r4]); only-if-present writes (Vain [r3]; UltraOS [r4]); virtual-adapter exclusion (Synergy/Vain); explicit "unknown benefit — do not touch" list: LSO, FlowControl, offloads (UltraOS, fixing an Atlas loop bug) [r4]. → NX07 ADVANCED family rules adopted; EEE/IM/RSS/buffers stay per-adapter-parameterized CONDITIONAL/ADVANCED with driver-range clamping.
- **DNS:** WinUtil's latency-benchmarked selection + abort-on-failure [r5]; Sophia's resolve-probe verify-and-auto-rollback [r5]; both use the documented DoH registry interface. → NX07-016 adopts verify-and-auto-rollback as a mandatory design element; no latency claims (directive).
- **Stack reset / IPv6:** Vain resets the full stack + removes/re-enumerates NICs at install [r3]; Sapphire kills IPv6 service+bindings [r3]. → NX07-021 stays TROUBLESHOOTING-last-resort; IPv6 removal rejected outright.
- **QoS per game:** Sapphire's DSCP-46 + FSE + GpuPreference per-game generator [r3]. → NX07-022 added (CONDITIONAL, router-dependent, honest scope).

## 6. Power (NX09)

- **Plan lifecycle:** Vain deletes all stock schemes after importing its own [r3 — rejected]; XOS never deletes the active plan and rebuilds from templates [r1 — adopted]; WinUtil restores defaults via `powercfg /restoredefaultschemes` [r5]. → NX09-003/013 rules confirmed.
- **Hibernate/Fast Startup:** off-by-default across most references [r1–r4]; Revi documents laptop overheating-in-sleep risk in its own option text [r2]. → NX09-008/009 CONDITIONAL, never preset; trade-off text mandatory.
- **Device power sweeps:** blanket Enum zeroing (Sapphire/Synergy/Vain [r3, r4]) rejected; UltraOS's `-OLD` rename backup is the only defensible variant [r4]; XOS generates a runnable restore script [r1]. → NX09-004/005 per-setting CONDITIONAL; NEXTRIX's journal supersedes both patterns.
- **Modern Standby:** UltraOS documents classic-plan settings being partially ignored on S0ix [r4]. → NX09 entries carry a Modern-Standby caveat note.

## 7. Boot, BCD & timers (NX17)

- **Dynamic tick:** forced off by XOS/Sapphire/Synergy [r1, r3, r4]; ReviOS *removed* its own setting after ROG Ally sleep breakage [r2]. → NX17-002 ADVANCED, consent+restart, never preset.
- **HPET/platform clock:** Sapphire forces `useplatformtick` + disables HPET devices [r3]; Vain/XOS delete the values instead [r1, r3]. → NX17-003 TROUBLESHOOTING symptom-gated only; forcing rejected.
- **Timer resolution:** UltraOS's assessment (per-window since Win10 2004; "1 ms gaming timer" mostly folklore; FSOS-X R11 had to fix its own toggle for global-request semantics) [r4, r1]. → NX17-001 EXPERIMENTAL stands, never preset, honest note mandatory.
- **Undocumented BCD:** Atlas's `custom:16000069` (self-labeled community-source) [r2]; `bootstatuspolicy IgnoreAllFailures` (repair-hiding) [r2]. → Rejected list; NX17-005's curated, individually-approved set confirmed as the only BCD policy.

## 8. Services & scheduled tasks (NX11)

- **Policy split:** blanket lists (50–250 services) with documented fallout [r2–r4] vs Sophia's individual documented reversible functions [r5] vs Atlas's near-default policy with VM-gated exceptions [r2] vs UltraOS's 12-service Balanced tier with per-service Microsoft-doc citations + never-touch validator [r4]. → NEXTRIX follows the UltraOS/Sophia/Atlas end of the spectrum: NX11 stays selective, detection-gated (Print Spooler/Bluetooth/Fax only when unused), journaled; never-touch list enforced by the build validator.
- **UCPD:** disabled by XOS/Revi/Synergy [r1, r2, r4]; UltraOS/Atlas never fight it (policy routes or leave alone) [r2, r4]; Synergy documents the `TaskbarDa`-is-protected failure mode with a policy fallback [r4]. → NEXTRIX: UCPD left alone; NX15 taskbar entries use policy-path fallbacks where UCPD protects direct values.
- **Task disabling:** XOS's verified 3-fallback mechanism with protected-skip list and exit codes [r1] adopted for NX11-006/NX16-006.

## 9. Debloat & AppX (NX12)

- **Edge removal:** documented WU-loop consequence across the ecosystem; WinUtil's dummy-exe hack rejected [r5]; UltraOS keeps WebView2 and sweeps Edge updater tasks [r4]; XOS ships remove-edge as default-irreversible [r1]. → NEXTRIX: Edge is not in the default candidate set; if the owner wants it, it ships as an explicitly-labeled one-way door with the documented reinstall-first workflow (owner decision at catalogue approval).
- **WebView2/Store/App Installer protection:** UltraOS: "15+ apps depend on WebView2" [r4]; Revi re-provisions VCLibs to fix a wsappx CPU loop [r2]. → NX12-002 protected list confirmed.
- **Removed apps return after feature updates:** documented Microsoft behavior (feature-update images pre-date blocklists) [r4, r2]. → NX12 gets re-run idempotency + honest docs; removal history ledger (NX12-010) confirmed necessary.
- **Xbox set:** XOS excludes Xbox from service sweeps and defaults Xbox removal to unchecked [r1]; FSOS-X documents the ms-gamebar controller-popup fallout [r1]. → NX12-005 conflict rules with NX02-008 stand.

## 10. Privacy & telemetry (NX13)

- **Edition-honest telemetry floor** (Sophia: Home/Pro → required-data value, Enterprise → 0) [r5] adopted for NX13-004 parameters; policy-vs-real-key hygiene (visible in UI) adopted.
- **Hosts-file blocking** (Revi incl. Brave/VS endpoints; WinUtil Adobe list) [r2, r5] → rejected (unverifiable blocklists, survives uninstall, breaks documented pages).
- **Telemetry task set:** convergent across references (CEIP/Appraiser/Consolidator/etc.) [r1–r4]; UltraOS marks uncertain-on-26H2 tasks honestly with `ignoreErrors` [r4]. → NX11-006/NX13-013 selective set confirmed; NEXTRIX adds existence-verification instead of error suppression.

## 11. Security (NX14)

All references that touch security defaults show documented fallout (Defender residue + recovery-screen bugs [r1]; anti-cheat refusals [r2–r4]; Secured-core silent no-ops [r2]; MOTW-era warning loss [r2, r4]). → NX14 stays reports + consent-gated exceptions; ADR-006 compensations bar `DefenderDisabled`/`UCPDDisabled` requirements from NEXTRIX's own playbook.

## 12. Session management (NX18 — converged design)

FSOS-X (verified-step restore, launcher waits, cooldown, capture exclusions) [r1] + Hone (watchdog ~5 s, exclusion lists, session report) [r6] + Vain (self-revert contract) [r3] → NX18-010 session journal with boot-time recovery is the NEXTRIX-specific addition none of them evidence (Vain's crash-recovery is unverified; FSOS-X's restore bugs are documented). Protected-process classes confirmed: anti-cheat, security, launchers, OBS/ShadowPlay/AMD-recording, audio, peripherals.

## 13. Hardware detection (NX20/NxHardware)

SynToolkit's uncertainty-state model + WMI inventory + VRAM wraparound fix + sanitization [r4]; chassis classifiers (battery-first, ChassisTypes ≤7) [r1, r3, r4]; GPU PCI-VID vendor gating [r4]; AMD chipset-driver install breakage incident (Atlas #1618) [r2] → NxHardware design confirmed; detection remains strictly read-only ("Specs layer never modifies the system" [r4]).

## 14. Negative-results ledger (permanent anti-pattern data; sources as cited)

| Anti-pattern | Broke | Source | NEXTRIX action |
|---|---|---|---|
| Global svchost-split forcing | XboxGipSvc | Revi #34 [r2] | Rejected; validator regression test |
| `bam` service disable | Task Manager Efficiency Mode | Revi [r2] | NX11 never disables bam |
| Mitigations off | THE FINALS; Vanguard needs CFG | Revi; Atlas [r2] | No preset mitigation changes |
| `disabledynamictick yes` | ROG Ally sleep | Revi #167 [r2] | NX17-002 consent-gated, never preset |
| BBR2 congestion provider | Websockets | Revi #27 [r2] | Not catalogued |
| Background-apps blanket off | Game Bar KGL updates | Revi [r2] | Per-app conditional only (NX11-002) |
| `VulnerableDriverBlocklistEnable=0` | THE FINALS | Revi [r2] | Rejected outright |
| MPO global disable | Composition errors, crashes | FSOS-X R8/R10 [r1] | TROUBLESHOOTING only |
| MouseHoverTime cut | Overlapping unreadable tooltips | Revi [r2] | Not catalogued |
| Edge removal | Windows Update loops | ecosystem-wide [r4] | Owner-gated one-way door with workflow |
| UCPD disable | SMB1 fallout pattern; OS fights back | Revi/XOS [r1, r2] | UCPD untouched; policy fallbacks |
| HAGS forced without driver check | Vendor-conditional failures | Synergy [r4] | NX04-001 capability-gated |
| Defender removal | Recovery-screen signature bug; AV false positives; residue | FSOS-X R11H1 [r1]; Revi [r2] | Out of NEXTRIX scope |
| Updates paused to 2038 | Silent security starvation; FACEIT update requirements | Synergy/Revi/XOS [r1, r2, r4] | No update-disable defaults |
| Blanket NIC keyword forcing | Killer/Realtek misbehavior | UltraOS research [r4] | Only-if-present writes |
| `SvcHostSplitThresholdInKB` RAM-blind | 8–16 GB hard-fault increase | UltraOS research [r4] | Not catalogued |
| Hardcoded per-user service suffix | Cross-build misses | Synergy `_389fd` [r4] | Name-resolution at runtime |

## 15. Pending owner testing (the only legitimate E2 path)

Per the Hone-style admission scorecard adapted for NEXTRIX: metric-matched claim → baseline runs (3–5) → single change → after runs (3–5) → one-PC result (E2) → multi-config results (E3). Candidates whose *configuration* effect is verifiable now but whose *performance* effect requires owner evidence: NX03-008 (Win32PrioritySeparation), NX17-001/-002 (timer/dynamic tick), NX04-005 (per-game FSO), NX19-003/-006 (CPU Sets, competitive profile), NX18-008/-009 (session graphics/priority), NX02-005 (windowed-games optimization), NX04-010 (Low Latency Mode per-profile). Until owner results exist, all remain at their catalogued E0/E1 with performance expressly PENDING.
