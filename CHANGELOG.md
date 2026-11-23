# Changelog

All notable changes to the NEXTRIX repository. Dates are ISO. Statuses follow the verification ladder in `TWEAK_CLASSIFICATION.md`.

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
