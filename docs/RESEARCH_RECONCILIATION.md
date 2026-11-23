# NEXTRIX — Research Reconciliation Log (v2)

All six Phase 1 streams COMPLETE and inspected in full by the coordinator. This log converts findings into NEXTRIX design impacts. Deep detail lives in `research/sources/r1–r6`; this file records decisions.

---

## Stream status

| Agent | Artifact (inspected) | Evidence quality notes |
|---|---|---|
| R1 | `r1-fsosx-xos.md` (75.5 KB) | FSOS-X closed-source → DOCUMENTED/DEV-BENCHMARK only; XOS CC BY-NC-ND → reference-only; no COMMUNITY evidence (search quota) |
| R2 | `r2-atlasos-revios.md` (341 lines) | 78 IMPLEMENTED / 22 DOCUMENTED / 12 COMMUNITY-CLAIM / 2 DEV-BENCHMARK / 0 VERIFIED; authenticated MCP used past API rate limits |
| R3 | `r3-sapphire-vain.md` (808 lines) | Vain scheduling engine closed + RE-prohibited → NX19 claims unverifiable; Sapphire Discord-gated ISOs unauditable |
| R4 | `r4-synergy-ultraos.md` (981 lines) | SynergyOS has NO license → zero reuse; SynToolkit GPL-3.0; UltraOS GPL-3.0 + NOTICE |
| R5 | `r5-winutil-sophia.md` (629 lines) | Both MIT (verified license texts); no DEV-BENCHMARK/VERIFIED anywhere in either project |
| R6 | `r6-hone-amewizard.md` (594 lines) | Hone closed-source → all claims; AME platform facts from official docs; wizard EULA text unpublished (limitation) |

**Global evidence verdict:** zero VERIFIED performance results exist across all 14 reference projects. All performance numbers found anywhere (Hone +51%/+27.7%, ReviOS TSX "4–5×", FSOS-X RAM/process counts) are DEV-BENCHMARK or DOCUMENTED claims. **None may be cited in NEXTRIX as evidence of performance** — the directive's evidence discipline is fully validated.

---

## Cross-cutting ADOPT register (design impacts; source streams tagged)

1. **Journal semantics confirmed by three independent references:** stock-capture with capture-refusal-if-already-tweaked (XOS `StockValueCapture` [R1]); restore-only-if-current-still-equals-what-we-wrote (XOS 0.6.4 [R1]; FSOS-X R10 [R1]; WinUtil `KeepServiceStartup` conditional undo [R5]); `<RemoveEntry>` sentinel = "value never existed, undo deletes it" (WinUtil undo metadata [R5]). → NxJournal/NxRollback design (architecture §3.5/3.6 gains these semantics explicitly).
2. **No mutation without verified prior state:** destructive steps refuse to run unless capture is Complete (XOS [R1]); full-services/AppX/tasks snapshot before first change (UltraOS L1 [R4]); validated first-backup-kept `winServices.reg` (Atlas [R2]).
3. **Layered rollback L0–L4** (UltraOS [R4]: restore-point → pre-change snapshots → Start-only service undo with baseline diffing → never-executed stock inventory → per-toggle pairs + per-change install report) — convergent with NX16/NxRollback; adopt its honest scope statements and its "never blind-import ImagePath/Security blobs" rationale.
4. **Never-touch service list enforced by the build validator** (UltraOS CI hard-errors [R4]) → `tools/Test-NxRegistry.ps1` requirement.
5. **Uncertainty-state detection pattern** (SynToolkit [R4]): missing ≠ off; wrong registry type = explicit `UnsupportedValue`; restore-point `Unverified` ≠ `Failed`; version-read failure = sentinel state; junk-SMBIOS sanitization; WMI `AdapterRAM` wraparound fixed via `qwMemorySize` registry read. → NxHardware/NxVerify/NxBuild.
6. **Topology derivation chain** (XOS Toolkit `topology.rs` [R1], reference-only): `GetLogicalProcessorInformationEx` core relations → SMT/EfficiencyClass tiers → dies/CCD → **X3D by >2× per-die L3 asymmetry** → LP→CPU-Set-ID map via `GetSystemCpuSetInformation`; cross-group `group*64+lp`; pure-function parsers with synthetic tests. → NX19 open implementation confirmed feasible; neither SapphireOS (no topology logic) nor Vain (closed engine) can be copied.
7. **CPU Sets default, affinity opt-in fallback** (single-group ≤64 LPs), vendor-documented anti-cheat rationale (XOS [R1]) → NX19-003/004.
8. **NIC discipline:** read `Ndi\Params` type/min/max/enum before writing any keyword; only-if-present writes; virtual-adapter exclusion lists; explicit "unknown benefit — do not touch" list (LSO/FlowControl/offloads); `-OLD` rename before destructive overwrites (SynergyOS idea-only [R4]; Vain [R3]; UltraOS [R4]) → NX07 implementation rules.
9. **Anti-cheat as a first-class gate:** FACEIT requires DEP on; Valorant works with `optin` (SapphireOS DEP trio [R3]); Vanguard requires CFG on its own processes even when system-disabled (Atlas [R2]); anti-cheat blocking of CPU Sets/GPU priority is reported to the user (FSOS-X [R1]); cooldown prevents spam-launch false positives (FSOS-X [R1]) → NX18-012 + conflict-resolver data + per-tweak anti-cheat compatibility notes.
10. **Session lifecycle:** apply at game start → watchdog re-check (~5 s, Hone [R6]) → restore only verified-applied steps (FSOS-X R11 [R1]) → session report (Hone [R6]); capture/OBS/audio/security processes excluded everywhere (FSOS-X, Hone, Vain) → NX18.
11. **Preflight requirement gates** (AME 12-value schema [R6]; Sophia guard chain [R5]; Atlas front-door with distinct exit codes [R2]) → NxCompat preflight. **Rejection must be read-only** — Sophia's refusal mutates the system (reject that part [R5]).
12. **Build/UBR guard data as versioned JSON + offline fallback** (Sophia [R5]) but **per-feature build ranges, not pinned-latest-UBR** (Sophia's own strictness is a brick-risk [R5]); GA-release classification for unlisted revisions (Atlas [R2]); narrow audited matrix is the safer default (UltraOS's own bug history [R4]) → WINDOWS_COMPATIBILITY.
13. **Restore-point honesty model** (SynToolkit [R4]: sequence-diff verification, throttle awareness, always-close-begin/end; UltraOS [R4]: never delete shadows, keep existing point on throttle) → NX16-001/002.
14. **Power-plan lifecycle:** never delete the active plan; switch away first; rebuild from template; keep stock schemes restorable (XOS [R1]; Vain's delete-all counter-example [R3]) → NX09-003/013.
15. **Tweak-admission scorecard** (Hone 7-gate: real problem → mechanism → known risks → metric-matched goal → 6–10 controlled runs on one PC → risk/benefit → explicit scope [R6]) → adopt as NEXTRIX's owner-testing methodology template (feeds MANUAL_TESTING_GUIDE); metric discipline: 1%/0.1% lows and frame times over average FPS.
16. **Negative-results ledger:** ReviOS `revert.yml` = 9+ tweaks that broke real software (svchost-split→XboxGipSvc, bam→Task Manager, mitigations→THE FINALS, disabledynamictick→ROG Ally sleep, BBR2→websockets, MouseHoverTime, VulnerableDriverBlocklist→FINALS, background-apps→GameBar KGL, consumer-features→Your Phone); UltraOS placebo list (1 ms timer ritual, blanket services); FSOS-X MPO toggle history → encode as NEXTRIX anti-pattern catalog + validation tests.
17. **Declarative action vocabulary with per-action build/cpuArch gating** (AME's 14 typed actions [R6]) → NEXTRIX manifest schema model regardless of engine outcome.
18. **Dry-run harness replicating the real engine's load rules + selftest reproducing a historical failure** (UltraOS `ame-dryrun.py` [R4]) → NEXTRIX build tooling requirement.
19. **Distribution hygiene:** SHA256SUMS release assets, hash-pinned downloads, zero floating downloads, no AV-evasion packaging, THIRD-PARTY-NOTICES when bundling (target: zero bundled binaries) (UltraOS [R4]; Vain counter-examples [R3]; AME cautions [R6]).
20. **Upgrade/deprecation ledger** (`onUpgrade` revert pass, each entry annotated with the bug that motivated it — ReviOS [R2]) → NEXTRIX registry maintenance discipline.
21. **Record-what-the-PC-shows:** post-apply re-read, `notApplied` reporting, warnings when record ≠ reality (Atlas [R2]; SynToolkit "current state" reads [R5]) → NxVerify.

## REJECT register (consolidated; queued for the catalogue's rejected list with evidence tags)

- **Security teardowns:** Defender removal in every flavor (CBS package + permanent root-store test cert [Sapphire R3, Synergy R4, Atlas R2]; file deletion, vendor-confirmed irreversible [Vain R3]); MoTW off (`SaveZoneInformation=1`) [Sapphire, Synergy, Atlas, ReviOS]; UAC off; unconditional VBS/HVCI disable (silently no-ops on Secured-core — detect and report instead) [ReviOS #222]; unconditional BitLocker `PreventDeviceEncryption` [ReviOS]; SAC/Enhanced-Phishing/Find-my-device off coupled to every install [Atlas]; chkdsk auto-check off [ReviOS]; Intel TSX enable [ReviOS]; system-wide mitigation nuking (runtime-enumerated `-Disable` all / all-2s masks) [XOS, Synergy, Sapphire, Vain]; IFEO `Debugger` hijacks [XOS, ReviOS, Sapphire]; UCPD disable [XOS, ReviOS, Synergy]; Defender sample-submission disable hidden inside a "telemetry" tweak [WinUtil].
- **Recovery sabotage:** System Restore/VSS/WinRE/RegIdleBackup/crash-dump/event-log destruction and `vssadmin delete shadows /all` [Sapphire, Vain, XOS, ReviOS, Synergy] — the axis NEXTRIX explicitly inverts.
- **Update starvation:** WU paused to 2038 / hardcoded 2050-01-01 freezes / driver delivery blocked as defaults [Synergy, ReviOS, XOS, Sapphire].
- **Timer/BCD forcing:** `useplatformtick yes`, HPET/System-Timer device disable, `disabledynamictick yes` without backup, undocumented `custom:16000069`, `bootstatuspolicy IgnoreAllFailures` [Sapphire, Synergy, Atlas].
- **Blind sweeps:** blanket Enum power-value zeroing; storage class-filter wipes; IPv6 removal/binding strip; DCOM off; hosts-file blocklists; RAM-blind global svchost-split thresholds; unconditional SysMain/memory-compression disable without RAM/NVMe thresholds (increases hard faults on 8–16 GB — UltraOS's own research); hardcoded per-user service suffixes; hardcoded 36-game EXE tables; direct `ControlSet001` writes.
- **Trust posture:** unsigned binaries requiring Defender exclusions; fixed-password AV-evasion packaging; unpinned floating downloads (`VainUpdater.exe` raw + `/silent`); `Set-ExecutionPolicy Unrestricted -Force`; kernel-driver helpers (`inpoutx64`); blanket TrustedInstaller privilege.
- **Integrity:** "no known issues" marketing; "fully revertible" over-claims (Hone Epic listing vs its own narrower wording; UltraOS INSTALL.md vs UNDO.ps1); doc/code mismatches (SynToolkit 17763-vs-19041 floor; SynergyOS vbs.bat missing-while-referenced) → NEXTRIX generates support matrices from code.

## Licensing constraints (feeds LICENSING_REVIEW.md)

| Project | License | Reuse posture for NEXTRIX |
|---|---|---|
| WinUtil / Sophia | MIT (verified) | Reuse permitted with attribution; Sophia maintainer's anti-wrapper stance respected |
| trusted-uninstaller-cli (AME engine), ame-assassin, appfetch, jumper | MIT | Permitted with notice (not currently needed) |
| Atlas / SynToolkit / UltraOS | GPL-3.0 (UltraOS ships a model NOTICE with full attribution chain) | Reimplement patterns, never copy code (GPL contagion) |
| SapphireOS/-Playbook | GPL-3.0 declared over bundled proprietary binaries, no notices | Hygiene failure; reference only |
| XOS Playbook + Toolkit | CC BY-NC-ND 4.0 | Reference only — no copying |
| ReviOS | CC BY-SA 4.0 | Ideas only; reuse forces share-alike |
| SynergyOS | **None (all rights reserved)** | Facts only; zero code/YAML reuse |
| Vain | Custom all-rights-reserved (+MIT third-party file) | Reference only |
| FSOS-X | Polyform Non-Commercial | No copying, no commercial use |
| Hone | Restrictive ToS (no content/screenshots without written permission; arbitration/class waiver) | Citation-only |
| AME Wizard platform | Wizard GUI unpublished; official playbooks ship with no LICENSE; verification discretionary via Discord/Telegram, lost on modification | No playbook-content copying; NEXTRIX would ship "unverified" by their gate |

## Build-matrix evidence (feeds WINDOWS_COMPATIBILITY.md)

- **PD-3 RESOLVED: Windows 11 26H2 = build 26300** — confirmed in code by four independent projects (Atlas `atlas.json` {26300,"26H2"}; ReviOS `playbook.conf` 26300→26H2; Sophia `supported_windows_builds.json` 26300/UBR≥9974; UltraOS `playbook.conf` 26100/26200/26300), all accessed 2026-11-23. 28000 = 26H1 ARM-only interim (UltraOS/ReviOS). 22635 = beta channel (SynergyOS).
- 24H2 (26100) is **skipped by XOS** but supported by Sapphire/Vain/UltraOS/ReviOS → 24H2 tweaks get extra capability checks; capability detection stays primary everywhere.
- UCPD-protected values (e.g. `TaskbarDa` on 24H2+) require policy fallbacks (SynergyOS precedent [R4]); KB5089573 removed legacy Start-menu code paths (WinUtil known-issues [R5]) — both recorded for per-tweak build notes.
- Reference matrices diverge wildly (Sapphire 19044–26200 · XOS 19045/22631/26200/26300 · Vain 22631–28000 · Synergy 19044–26300 · UltraOS 26100–26300 · Atlas 26200/26300 only) — no consensus matrix exists to inherit; NEXTRIX keeps Win11 23H2+ with per-tweak capability gates.

## Engine-decision escalation (→ ADR-006)

R6's platform findings materially affect ADR-002 (owner's AME Wizard choice, made before this evidence existed):

1. **Rollback:** AME's official docs state there is *no standardized way to uninstall playbooks*; Privacy+ removal requires a **Windows ISO in-place upgrade**; "universal reversibility" is future pre-1.0 work, not shipping in v0.8.4. NEXTRIX's mandatory rollback pillar would rest entirely on our own bundled journal layer (already the architecture) — the platform adds nothing to it.
2. **Trust posture:** unsigned beta binary instructing users to add **Defender exclusions** and allow a "Trojan Script" detection; `.apbx` fixed-password encryption whose documented purpose is **AV-scanning evasion**; `UseKernelDriver` option; Defender/UCPD neutralization normalized as preflight requirements. This conflicts with NEXTRIX's security-by-default pillar (Section 15) and would force users to weaken Defender just to run the delivery tool.
3. **Licensing/verification:** wizard GUI source unpublished; official playbooks ship without licenses; "verified playbook" status is discretionary (Discord/Telegram), centralized, and lost on any modification — NEXTRIX would permanently ship unverified on that platform.
4. **Ecosystem signal:** AtlasOS — one of the two flagship verified playbooks — **moved off AME Wizard this same week** (v0.6.0, 2026-11-22) to its own Rust manager + TrustedInstaller-brokered PowerShell install, citing similar engineering control needs.
5. **Countervailing:** the AME authoring schema itself is well-designed (14 typed actions, per-action `builds`/`cpuArch`/`errorAction`, requirement gates, feature pages, upgrade semantics) and directly portable; `.apbx` is a plain password-zip (no technical lock-in); the wizard's UX and user base are the real assets.

Escalated to the project owner on 2026-11-23 with three options (PowerShell engine emulating the AME schema · hybrid PS-core + optional later AME export · keep AME Wizard with documented compensations). Outcome recorded as ADR-006 in `docs/DECISIONS.md`.

## Catalogue change queue (applied in the consolidated pass)

1. Add `NX07-022` per-game QoS/DSCP profile — CONDITIONAL, E0, router-dependent (Sapphire `Auto DSCP & FSE` [R3]; Vain per-game composition [R3]).
2. Add `NX16-017` owner support-bundle export (scrubbed specs + journal summary) — CORE, E0 (FSOS-X Export PC Specs [R1]; XOS diagnostic ZIP [R1]).
3. Strengthen the catalogue's rejected/excluded list with the REJECT register above (evidence-tagged).
4. Class/evidence confirmations — no E-level raises: MPO stays TROUBLESHOOTING (FSOS-X pulled it twice [R1]); timer resolution stays EXPERIMENTAL (UltraOS: per-window since Win10 2004 [R4]); NX19-011 X3D heuristic implementable openly (L3 asymmetry [R1]) but stays best-effort/flagged; SysMain conditional gains RAM/NVMe threshold parameters (UltraOS 16 GB/NVMe guidance [R4]); `SvcHostSplitThresholdInKB` global forcing joins the rejected list (breaks XboxGipSvc — ReviOS ledger [R2]); `Win32PrioritySeparation` values stay ADVANCED/preset-excluded (contested, reference-divergent: 36/38/42/0x2a across five projects with no evidence).
5. Architecture updates after ADR-006: journal semantics (adopt items 1–3), validator never-touch list (item 4), uncertainty states (item 5), preflight read-only refusal (item 11), dry-run tooling (item 18), NX18 session details (item 10).
