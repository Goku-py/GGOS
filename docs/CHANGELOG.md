# Changelog

All notable changes to the NEXTRIX repository. Dates are ISO. Statuses follow the verification ladder in `TWEAK_CLASSIFICATION.md`.

## 2026-11-24 - QoL choice surface (v0.9.4)

- **The wizard no longer shows technical tweak names.** The 12 checkboxes are quality-of-life choices: cleaner Start/notifications; files, Explorer and storage; animations/transparency; healthy Windows/reports; less tracking/ads; fewer background apps; remove apps; network/DNS; Game Mode/recording; graphics smoothness; mouse/keyboard feel; performance/battery.
- **Visual QoL is split three ways** (NX15 re-gated): animations/transparency, Explorer/file extensions, and Start/taskbar/notifications/lock screen. These person-to-person preferences no longer sit inside one opaque visual bundle.
- **4 pages total** (Desktop/Laptop + 3 QoL pages); descriptions 67/69/64 chars, labels <= 36 chars, 231 journaled actions preserved.
- Underlying per-tweak journaling is unchanged; presetExcluded/advanced entries stay CLI-only.
- **No NEXTRIX modification applied to any machine.**

## 2026-11-24 - Form factor page + page copy rewrite (v0.9.3)

- **First page is now Desktop or Laptop** (`RadioPage`, default Desktop). The radio guarantees exactly one form factor: Laptop re-gates 12 hardware-specific tweaks (hybrid graphics, Modern Standby storage D3, adapter/Wi-Fi/Bluetooth power, PCIe ASPM, USB selective suspend, lid close, battery reports, AC/DC thermal); Desktop gates Ultimate Performance provisioning. Selecting a form factor applies its hardware-specific tweaks independently of the bundle pages.
- **Page text rewritten inside the AME 50-85 char limit and now names the tweaks**: Gaming 66, Everyday 71, Privacy 73, form factor 67 chars; every option label <= 40 chars.
- **Quieter progress:** per-category status lines were removed from `main.yml` and every category task file. The progress stream now shows the pre-flight, the selected actions and completion - it no longer announces "applying selected tweaks" for categories the user did not select.
- **Info page shortened** to a ~50-word summary; it no longer narrates the pre-flight/apply process.
- **4 wizard pages total** (form factor + 3 use-case pages); the hard 4-page budget and 4-options/page limits are still enforced by the generator.
- Underlying per-tweak journaling is unchanged; presetExcluded entries stay CLI-only.
- **No NEXTRIX modification applied to any machine.**

## 2026-11-24 - Use-case selection, 3 pages, no undo page (v0.9.2)

- **The Undo page is gone from the installer.** Rollback was never an install-time choice; it is a post-install CLI action (`Invoke-NxRollback` from the bundled NxCore). The playbook no longer emits a rollback page or `Tasks/rollback.yml`.
- **Selection rebuilt around use cases: 3 pages / 12 checkboxes.** Page 1 Gaming: Game Mode & Game Bar, GPU & display tuning, CPU/power/memory, Input & USB. Page 2 Everyday: Windows cleanup, Storage & filesystem, Network & DNS, Maintenance & recovery (pre-selected). Page 3 Privacy & reporting: Privacy & telemetry, Startup & background apps, Optional app removal (plans), Security & hardware reports.
- **Hard 4-page budget** (3 selection pages + the playbook info screen), max 4 options/page, Description 50-85 chars, labels <= 40 chars. The generator fails the build on any violation.
- Underlying tweaks are unchanged: every action is still journaled per tweak by NxCore; only the selection surface is bundled. presetExcluded (advanced/troubleshooting) entries remain CLI-only with explicit consent.
- **No NEXTRIX modification applied to any machine.**

## 2026-11-24 - Upgrade support (v0.9.1)

- **AME upgrades are now allowed:** `playbook.conf` declares `UpgradableFrom: any`, so installing v0.9.1 over an older NEXTRIX playbook no longer shows "NEXTRIX does not allow upgrades".
- **Existing journals are reused, never reinitialized**, on upgrade/re-run: `Invoke-NxPreFlight` treats a present NEXTRIX journal as Complete with `journalReused=true`; the stock originals from the first session stay authoritative for rollback (stacking detection preserved).
- **Idempotent registry writes:** `Invoke-NxRegistryTweak` now detects an already-at-target state, journals a `skip` (AlreadyAtState) and writes nothing - upgrades cannot overwrite first-session originals.
- Tests updated: NX16 63/63 (second-run reuse + gate-open assertions), journal 11/11, registry 282 clean.
- **No NEXTRIX modification applied to any machine.**

## 2026-11-24 - Bundle selection UI (v0.9.0)

- **Wizard selection reduced to 2 pages of bundles + the Undo page** (3 pages, 12 options total): Windows cleanup, Gaming & performance, Privacy & app cleanup, Maintenance (pre-selected), plus optional Network & DNS, Input & USB, GPU guidance (read-only), Storage & memory maintenance.
- **Bundle options apply their journaled tweak groups.** The underlying tweaks keep identical per-tweak journaling and rollback; only the selection surface is bundled. presetExcluded (advanced/troubleshooting) entries remain CLI-only with explicit consent.
- **Less detail during install:** per-tweak `!status` lines were removed from the progress stream (one category-level line remains); the playbook intro and Details were trimmed to essentials (no category dump).
- AME limits still enforced by the generator (Description 50-85 chars, labels <= 40 chars, <= 4 options/page, <= 8 pages) - build fails on violation.
- **No NEXTRIX modification applied to any machine.**

## 2026-11-23 - Wizard UX redesign (v0.8.0)

- **Selection UI rebuilt to match the platform, not the registry:** the AME wizard now exposes **7 pages / 23 curated groups** instead of 76 per-tweak pages. Research basis: AME docs (CheckboxPage Description 50-85 chars, short option text, max 4 options/page) and the established playbooks (ReviOS/XOS/Sapphire/UltraOS: 4-8 pages, 16-25 options; documented in the release notes of this version).
- **AME UI rules enforced by the generator** (fails the build on violation): Description 50-85 characters; option Text <= 40 chars; <= 4 options per page; <= 8 pages. The previous per-tweak labels (tweak ID + full name, way over the limit) caused the text overflow in the wizard UI.
- **Groups map to tweak sets** (e.g. `g-suggestions` = tips/promos; `g-vendor` = read-only GPU guidance; `g-cpu` = processor + scheduling reports); per-action YAML gating now uses the group option, so selecting a group applies its journaled members.
- **presetExcluded entries are no longer wizard options** (advanced/troubleshooting/pending functions): they remain individually selectable through the NXCore CLI with explicit consent (TWEAK_CLASSIFICATION Section 5). NX17 is tooling-only; NX18 session controls are runtime/CLI by design.
- Defaults: Maintenance & recovery plus Hardware & driver reports checked; all other groups unchecked.
- Validation: generator throws on any Description/label/page violation; structural check: 7 pages, 27 options (23 groups + 4 rollback scopes), every YAML option name resolves to a page.
- **No NEXTRIX modification applied to any machine.**

## 2026-11-23 - Phase 6 Documentation & Handover (v0.7.0-rc)

- **Docs delivered:** `MANUAL_TESTING_GUIDE.md` (282 per-tweak sheets, generation-verified: 0 missing/duplicate IDs, 33 code blocks parsed), `HARDWARE_COMPATIBILITY.md` + `WINDOWS_COMPATIBILITY.md` (registry/engine-traced matrices), `DEPENDENCY_MATRIX.md` + `CONFLICT_MATRIX.md` (generated: 109 edges, 12 symmetric pairs, 5 groups, cycle PASS), `PACKAGING.md`, `OWNER_HANDOVER.md`.
- **Resolver hardening from the compatibility audit:** `excludedHardware` evaluated; `builds.excluded` honoured; edition gate (Home/Pro/Enterprise/Education mapping, unknown-edition = warning) and x64 architecture gate added and live-verified; null-element hardening for synthetic inputs.
- **Two engine defects found by the testing-guide audit and fixed:** `NxVerify` null `ExpectedValue` binding (rollback of never-existed values could throw) and journal re-arm after a verified restore now archives the old entries file instead of losing audit history (`Initialize-NxJournal` semantics updated).
- **Data/schema completeness:** `rollback.reversible` added to the 18 NX07 entries and required by the validator; NX18-006 declares its NX19-002 dependency; README/classification/catalogue counts synced (282 entries; 242 SyntaxValidated / 40 Defined).
- **Packaging verified:** staging 56 files, 28/28 manifest hashes matched (NX18 pinned), 55 `SHA256SUMS`; bootstrap loader proven in a clean PowerShell 5.1 process; owner 7-Zip step documented.
- **Gate 5:** 18/18 suites, **1,293 assertions, 0 failures**; validator 0/0 (282 tweaks / 20 files). Final release candidate **v0.7.0-rc**. **Phases 0-6 complete; owner hardware validation remains owner-only.**
- **No NEXTRIX modification applied to any machine.**

## 2026-11-23 - Phase 5 NX18 Game Session Manager (v0.6.0)

- **NX18 subsystem delivered** (`src/nxsession/NX18.ps1`, 12 registry entries): game/launcher detection (read-only, never launches), user-authored profile store, plan-first start with `-Approved`, journaled apply, 2 s monitor with heartbeat, **verified-step restore** (failed steps are never restored - FSOS-X R11 lesson), cooldown against rapid re-sessions, manual stop, integrity-gated crash recovery (`Invoke-NxSessionRecovery`) with journal-root restriction (session records treated as untrusted data), and the hard-coded **protected-process guard** across anti-cheat/security/recording/audio/peripherals/launchers with no override parameter.
- **11 Implemented / 1 Defined**: NX18-007 service suspension is plan-only by design (no journaled service-state engine exists yet); it classifies never-touch services and touches none.
- **Playbook actions for NX18 are read-only capability probes** - the playbook never starts a session. Runtime packaging of `src/nxsession/NX18.ps1` belongs to the Phase 6 packaging step (KNOWN_ISSUES 16).
- **Gate 4:** 18/18 suites, **1,293 assertions, 0 failures**; validator 0/0 (282 tweaks / 20 files); parser clean; playbook v0.6.0 (25 files, 0 errors); 11 NX18 entries promoted to SyntaxValidated; four suite status assertions updated to accept the CI tier.
- **No NEXTRIX modification applied to any machine.**

## 2026-11-23 - Phase 4 Wave 3 (v0.5.0)

- **NX08 Input & Peripherals** (8) - incl. researched **NX08-008 DataQueueSize** (mouclass/kbdclass queue depth; default 100; community floor 16 enforced in code; placebo contradiction and click-loss-at-1 recorded; no performance claim). 53 assertions.
- **NX10 Thermal Management** (8) - read-only monitoring with hard uncertainty discipline (disagreeing temperature sources reported as Uncertain-SourceDisagreement, never averaged). 130 assertions.
- **NX12 Windows Debloating** (14) - three-layer protected-dependency guard enforced inside the removal engines; journaled identity/scope before removal; honest Success-Irreversible labels; playbook actions are plan-first (removal write functions await explicit-selection wiring - KNOWN_ISSUES 13). 57 assertions.
- **NX14 Security Configuration** (15) - read-only reports plus mutation surfaces that can never lower a protection; banned-target code guard mirrors the schema and is stricter; ExplicitConsent gates. 152 assertions.
- **NX17 Advanced Windows Configuration** (14) - 2 Implemented / 12 read-only Defined by design (BCD writes, device MSI/affinity, Driver Verifier, timer/HPET forcing deliberately withheld). 41 assertions.
- **NX19 CPU Topology & Scheduling** (11) - open P/Invoke engine: GetLogicalProcessorInformationEx tiers, dies/CCD, X3D via >2x per-die L3 asymmetry, LP-to-CPU-Set-ID map; synthetic coverage for Intel hybrid/two- and three-tier, AMD dual-CCD/X3D/boundary cases, bit 63, multi-group; no hardcoded indexes (audited). 149 assertions.
- **NX20 Hardware & Driver Management** (11) - read-only inventory reusing NxHardware; found and drove the fix of an NX16 null-date truncation (driver inventory 26 to 164 rows).
- **Engine** - Import-NxCore function removed (function scoping defect; dot-source src/nxcore/Import-NxCore.ps1); bounded test runner tools/Test-NxAll.ps1 (per-suite timeouts, Windows PowerShell 5.1) after a PS7 DISM enumeration hang was diagnosed.
- **Validations:** 1,216 assertions across 17 suites, 0 failures; validator 0/0 (270 tweaks / 19 files); parser 46 files clean; playbook 24 files, 0 errors, 71 journaled writes, 0 raw; status promotion 231 entries to SyntaxValidated.
- **No NEXTRIX modification applied to any machine.**

## 2026-11-23 - Phase 4 Wave 2 (v0.4.0)

- **Seven categories delivered:** NX03 CPU (13), NX05 Memory (11), NX06 Storage (13), NX07 Network (22), NX11 Services (19), NX13 Privacy (14), NX15 Visual (14) - 106 new tweaks, all validator-clean at the gate.
- **Highlights:** processor power settings with AC/DC journaled separately; pagefile exact-state capture as the restore anchor; DNS with mandatory proof-and-rollback; never-touch service enforcement (Print Spooler report-only); edition-aware telemetry floor with placebo guard (Home/Pro value kept but reported honestly); UCPD policy fallbacks for taskbar values.
- **Engine:** function dispatcher wired into Invoke-NxApply; steps-list fix; rollback category delegation (Invoke-Nx09Rollback); journal integrity fix (integer timestamps, v1.1); validator 5.1 PSScriptRoot fix; NX02-005 migrated to the shared DirectX composer (key-path correction).
- **Validations:** 561 assertions across 10 suites; validator 0/0 (189 tweaks / 12 files); parser 31 files; playbook 17 files, 0 errors, 71 journaled writes at that point.
- **No NEXTRIX modification applied to any machine.**

## 2026-11-23 - Phase 4 Wave 1 (v0.3.0)

- **NX01 Windows Foundation** — 16 entries (15 Implemented, 1 honest Defined); Microsoft documentation verified for policy evidence; CDM registry families E0 with provenance.
- **NX02 Gaming & Esports** — 12 entries (9 Implemented, 3 composition Defines); Streamer-profile exclusions verified programmatically; no global FSO/IFEO patterns.
- **NX04 GPU & Graphics** — 23 entries (5 Implemented, 18 honesty-driven Defined): vendor driver-profile settings are guided-only because no documented OS write path exists; vendor gating demonstrated live (Intel gate refused on an AMD+NVIDIA host).
- **NX09 Power Management** — 15/15 Implemented; AC/DC journaled separately; powercfg parser fails closed; never-delete-active/stock-plan enforced and self-tested (62 assertions).
- **NX16 Maintenance & Recovery** — all 17 entries Implemented; 63-assertion self-test (throttle-keep logic, identifier scrubber, secret-leak checks, capture gate).
- **AME playbook generator** (`tools/Invoke-NxBuild.ps1`) — registry → playbook source, deterministic; 82 options, preflight-first ordering, presetExcluded mechanically unchecked, rollback surface emitted, NxCore manifest SHA256-pinned.
- **Engine hardening** — function dispatcher with signature-aware context, `JournalPath` mapping, `$steps` summary fix, rollback category delegation (`Invoke-Nx09Rollback`), rollback filter fix, **journaled registry writer `Invoke-NxRegistryTweak`** so no configuration change can bypass the journal; validator 5.1 `$PSScriptRoot` fix; NX02-005 migrated to the shared DirectX composer (key-path correction).
- **Journal integrity fix (found via flake investigation):** entry timestamps are now integers (`tsUtcUnixMs`, journal v1.1) because JSON date-like strings are auto-converted by `ConvertFrom-Json` and re-serialize lossily (~1 in 10 writes produced a phantom integrity mismatch that would have blocked rollback). Verified with a 40-iteration regression loop and 3× self-test runs. Read path also retries a fresh, permissively-shared read once so transient I/O can never be misreported as tampering.
- **Validations:** registry validator 0 errors / 0 warnings (83 tweaks); parser 17 files clean; self-tests 63/63 (NX16), 62/62 (NX09), 11/11 (journal). No NEXTRIX modification applied to any machine.

## 2026-11-23 — Phase 3 Foundation (v0.2.0)

- **Rollback engine implemented and self-tested:** state journal (`src/nxcore/NxJournal.ps1`) with capture-refusal (stacking detection), SHA-256 integrity chain, only-if-ours restore semantics, tamper detection — `tools/Test-NxJournal.ps1` **11/11 PASS**.
- **Detection layer:** `NxBuild.ps1` (edition/build/UBR/scope/Insider + registry/service capability probes with Failed/Uncertain sentinels) and `NxHardware.ps1` (CPU/GPU/RAM/storage/chassis, PCI-VID vendor gating, qwMemorySize VRAM fix, junk-SMBIOS sanitization — strictly read-only, uncertain values marked, never guessed).
- **Pipeline:** `NxCompat.ps1` (eligibility with graceful skip + reasons), `NxVerify.ps1` (configuration verification only), `NxRollback.ps1` (four scopes, reverse-order, divergence-reporting), `NxApply.ps1` (the 10-step protocol with Plan mode and an explicit approval gate).
- **Registry:** `registry/schema.json` (32-field tweak schema; banned targets; never-touch services; preset rules) + **first category populated: NX16 Maintenance & Recovery, 17 entries at full metadata depth** (5 Implemented, 12 Defined pending their category functions).
- **Validator:** `tools/Test-NxRegistry.ps1` — duplicate IDs/targets, dependency cycles, conflict symmetry, build ranges, banned targets, never-touch enforcement. **PASSED: 17 tweaks, 0 errors.**
- **Syntax validation:** 9/9 PowerShell files parse clean (5.1-compatible).
- **Design docs delivered:** `STATE_JOURNAL.md`, `ROLLBACK_DESIGN.md`, `SECURITY_POLICY.md`.
- **Not yet done (honest):** playbook generator (`tools/Invoke-NxBuild.ps1`), NX16's remaining engine functions, all other categories — queued next.
- **No NEXTRIX modification applied to any machine:** validation was static, syntax-level, and temp-folder self-tests only.

## 2026-11-23

- **Phase 0 complete:** repository discovery — empty greenfield repository confirmed; nothing to preserve (ADR-001).
- **Owner decisions recorded:** ADR-002 (primary engine: AME Wizard playbook), ADR-003 (Windows 11 only targets).
- **Phase 1 launched:** six research agents (r1–r6) covering all 14 primary reference projects plus the AME Wizard platform; notes to `research/sources/`.
- **Phase 2 proposals drafted (v0.1, none implemented):**
  - `README.md` — project identity, status, operating rules.
  - `PROJECT_ARCHITECTURE.md` — proposed architecture: registry → validation → playbook build → AME Wizard delivery; NXCore helpers; state journal; rollback scopes.
  - `TWEAK_CATALOGUE.md` — proposed inventory: 20 categories, ~270 candidate tweaks, initial risk/evidence classes, rejected & excluded lists.
  - `TWEAK_CLASSIFICATION.md` — risk classes, evidence ladder, verification-status ladder, promotion rules.
  - `PROFILE_MATRIX.md` — 9 composable user profiles, eligibility and conflict-resolution rules.
  - `DECISIONS.md` — ADR log with pending decisions.
  - `research/README.md` — Phase 1 methodology and synthesis plan.

No NEXTRIX modifications have been applied to any machine. No performance claims are made.

### Research progress (same day)

- **R3 complete** (`research/sources/r3-sapphire-vain.md`, 63 KB): source-level research on SapphireOS, SapphireOS-Playbook, Vain. Headline: both references disable the OS's own recovery substrate (System Restore/VSS/WinRE/event logs) — NEXTRIX inverts this by design; Vain's scheduling engine is closed-source with hardcoded game lists, so NX19's open topology derivation is confirmed as the only compliant route.
- **R1 complete** (`research/sources/r1-fsosx-xos.md`, 75.5 KB): FSOS-X (closed-source, claims-only), XOS Playbook (CC BY-NC-ND — reference only), XOS Toolkit (open Rust topology engine: P/E tiers, CCD/X3D via L3 asymmetry, LP→CPU-Set-ID mapping — approach validated, code not copyable).
- **Reconciliation log created** (`RESEARCH_RECONCILIATION.md`): ADOPT/ADAPT/REJECT registers, licensing constraints, catalogue change queue (2 candidate additions, rejected-list strengthening, evidence confirmations), consolidated-pass checklist.
- All six research streams complete (`research/sources/r1–r6`, all read in full by the coordinator); reconciliation log finalized (`RESEARCH_RECONCILIATION.md`).

### Phase 1 complete + consolidated pass (same day)

- **All streams returned and inspected:** R2 (AtlasOS, ReviOS), R4 (SynergyOS, SynToolkit, UltraOS), R5 (WinUtil, Sophia), R6 (Hone, AME Wizard platform) joined R1/R3. **Global verdict: zero independently verified performance evidence exists across all 14 references; no reference number may be cited as proof.**
- **ADR-006 recorded (owner decision):** AME Wizard engine **reaffirmed with eyes open** after re-escalation with R6's platform evidence (no standardized uninstall; unsigned beta + Defender-exclusion instructions; AV-evasion packaging rationale; discretionary verification). Binding compensations: journal-only rollback, `UseKernelDriver: false`, zero security-neutralization requirements, disclosed trust posture, pinned wizard version (v0.8.4), hash-pinned artifacts.
- **PD-3 resolved:** Windows 11 26H2 = build 26300 (four independent code sources); ADR-003 amended. PD-2 partially resolved (wizard EULA text remains unpublished). PD-6 added (repository license decision).
- **Six synthesis deliverables generated:** `PROJECT_RESEARCH.md`, `PLAYBOOK_COMPARISON.md`, `TWEAK_RESEARCH.md` (incl. 16-entry negative-results ledger + owner-testing methodology), `COMPATIBILITY_RESEARCH.md` (build matrix, capability patterns, incident catalog), `LICENSING_REVIEW.md` (all 16 license texts verified; reuse rules; platform terms), `KNOWN_ISSUES.md` (honest phase limitations + risk register).
- **Catalogue change queue applied (v0.2):** +`NX07-022` per-game QoS/DSCP (CONDITIONAL, E0); +`NX16-017` owner support-bundle export (CORE, E0); rejected list expanded from 10 to 17 research-confirmed items; all desk evidence assignments confirmed with **no E-level raises**. 272 candidates total; every entry still CANDIDATE.
- **Architecture reconciled (v0.2):** journal gains only-if-ours restore + capture-refusal semantics; validator gains never-touch service list + anti-pattern regression tests; §8 records confirmed platform facts + ADR-006 compensations; Phase 3 follow-up flagged (UltraOS AME format spec + dry-run harness read for tooling hardening).

No NEXTRIX modifications have been applied to any machine. No performance claims are made anywhere in the repository.

### Repository & distribution (2026-11-23)

- Official GitHub remote connected: `Goku-py/NEXTRIX` (private). Previous repository content (the GGOS project: branch history, 5 tags, releases) removed at owner instruction; **full mirror backup taken locally before deletion** (ADR-007).
- Release policy set (ADR-007): every version release = commits pushed + GitHub Release with short, easy-to-understand notes specific to that release; the detailed engineering log remains here.
- First release published: **v0.1.0 — Foundation** (this commit).
- Owner confirmed the old-content backup was not needed; the local mirror backup was deleted at owner instruction (ADR-007 execution note updated).
