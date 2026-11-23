# Changelog

All notable changes to the NEXTRIX repository. Dates are ISO. Statuses follow the verification ladder in `TWEAK_CLASSIFICATION.md`.

## 2026-11-23 — Phase 4 Wave 1 (v0.3.0)

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
  - `docs/DECISIONS.md` — ADR log with pending decisions.
  - `research/README.md` — Phase 1 methodology and synthesis plan.

No NEXTRIX modifications have been applied to any machine. No performance claims are made.

### Research progress (same day)

- **R3 complete** (`research/sources/r3-sapphire-vain.md`, 63 KB): source-level research on SapphireOS, SapphireOS-Playbook, Vain. Headline: both references disable the OS's own recovery substrate (System Restore/VSS/WinRE/event logs) — NEXTRIX inverts this by design; Vain's scheduling engine is closed-source with hardcoded game lists, so NX19's open topology derivation is confirmed as the only compliant route.
- **R1 complete** (`research/sources/r1-fsosx-xos.md`, 75.5 KB): FSOS-X (closed-source, claims-only), XOS Playbook (CC BY-NC-ND — reference only), XOS Toolkit (open Rust topology engine: P/E tiers, CCD/X3D via L3 asymmetry, LP→CPU-Set-ID mapping — approach validated, code not copyable).
- **Reconciliation log created** (`docs/RESEARCH_RECONCILIATION.md`): ADOPT/ADAPT/REJECT registers, licensing constraints, catalogue change queue (2 candidate additions, rejected-list strengthening, evidence confirmations), consolidated-pass checklist.
- All six research streams complete (`research/sources/r1–r6`, all read in full by the coordinator); reconciliation log finalized (`docs/RESEARCH_RECONCILIATION.md`).

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
