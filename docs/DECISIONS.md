# NEXTRIX — Architecture Decision Records

Owner-approved and pending decisions. Each ADR records context, decision, owner and consequences. Genuinely consequential or destructive decisions are escalated to the project owner before implementation — never taken silently.

---

## ADR-001 — Greenfield baseline (Phase 0)

- **Date:** 2026-11-23
- **Status:** Accepted (fact record)
- **Context:** Phase 0 inspection of `D:\College\Me\Projects\Tweaks\NEXTRIX` found **zero files** — no existing playbook, scripts, backups or compatibility checks.
- **Decision:** Record greenfield status. No working functionality exists to preserve; no duplicate-implementation risk from prior work. Git initialization is recommended before Phase 3 implementation begins (owner action).
- **Consequences:** The implementation-format choice (ADR-002) is fully open rather than constrained by an existing format.

## ADR-002 — Primary engine: AME Wizard playbook

- **Date:** 2026-11-23
- **Decision by:** Project owner (presented by coordinator with a PowerShell-engine recommendation; owner selected AME Wizard).
- **Context:** Empty repository; directive Section 12 permits AME Wizard, PowerShell or data-driven formats. Many primary reference projects (ReviOS, AtlasOS, XOS, SapphireOS, Vain, UltraOS) ship as AME Wizard playbooks.
- **Decision:** NEXTRIX is authored as an **AME Wizard playbook**, following the platform's current documented schema, with modular feature declarations, conditional actions, declared supported builds and explicit dependencies.
- **Consequences & implications (engineering position):**
  1. NEXTRIX's mandatory differentiators — exact original-state journaling, hardware-aware eligibility, dependency/conflict resolution, evidence-tagged metadata — must be carried by **bundled helper logic invoked from playbook actions** and by the **registry→playbook build pipeline**, to the extent the platform schema supports them. R6's platform research verifies exactly what the schema and its undo architecture can and cannot carry; architecture will be reconciled against it.
  2. The single source of truth remains the NEXTRIX tweak registry (structured files); a build step emits/validates playbook source from it, so the 30-field metadata, duplicate-ID checks, dependency cycles and conflict declarations are enforced at build time, not by hand-authoring discipline.
  3. Distribution/licensing constraints of the AME Wizard platform apply to NEXTRIX releases — recorded in `LICENSING_REVIEW.md` once R6 reports.
  4. NX18 (Game Session Manager) is a runtime subsystem, not an install-time action; it is delivered as a bundled companion component installed by the playbook (design in `PROJECT_ARCHITECTURE.md` §7).

## ADR-003 — Windows target scope: Windows 11 only

- **Date:** 2026-11-23
- **Decision by:** Project owner.
- **Decision:** Supported targets are Windows 11 23H2 (build 22631), 24H2 (26100), 25H2 (26200) and 26H2 (build **26300** — confirmed in code by four independent reference projects: Atlas `atlas.json`, ReviOS `playbook.conf`, Sophia `supported_windows_builds.json` (UBR ≥ 9974), UltraOS `playbook.conf`; accessed 2026-11-23; see `docs/RESEARCH_RECONCILIATION.md`). Insider builds are treated as experimental. Windows 10 is out of scope.
- **Consequences:** Build gates target Win11 23H2+; capability detection remains the primary applicability mechanism per directive Section 10 (build number alone never implies a feature exists).

## ADR-004 — Phase gating: no mass implementation before catalogue approval

- **Date:** 2026-11-23
- **Status:** Accepted (directive-conformant)
- **Decision:** This cycle delivers Phase 0 + Phase 1 (research) + Phase 2 proposals only. No tweak implementations are written until the owner reviews `TWEAK_CATALOGUE.md` and the Phase 1 research is reconciled into it.
- **Rationale:** Directive final instruction: establish the foundation first; do not immediately implement hundreds of modifications.

## ADR-005 — Evidence discipline

- **Date:** 2026-11-23
- **Status:** Accepted (directive-conformant)
- **Decision:** No performance claims without owner-supplied benchmark evidence. Initial evidence levels in the catalogue are desk assignments (E0/E1 only). Only the owner can promote verification status beyond configuration-validated.

## ADR-006 — Engine decision reaffirmed: AME Wizard, with eyes open

- **Date:** 2026-11-23
- **Decision by:** Project owner (re-escalated by the coordinator with R6 platform evidence; owner reaffirmed ADR-002 after hearing it).
- **Context (all [DOCUMENTED] from AME's official docs, `research/sources/r6-hone-amewizard.md`):** the platform has no standardized playbook uninstall (Privacy+ removal requires a Windows ISO in-place upgrade; "universal reversibility" is explicitly future pre-1.0 work, absent from v0.8.4); the beta wizard is unsigned and its official instructions require Defender exclusions and allowing a "Trojan Script" detection; `.apbx` fixed-password encryption has AV-scanning evasion as its documented purpose; playbook verification is discretionary (Discord/Telegram), centralized, and lost on any modification; and AtlasOS left the platform the same week (v0.6.0, 2026-11-22) for its own manager + TrustedInstaller-brokered PowerShell.
- **Decision:** NEXTRIX remains an AME Wizard playbook. ADR-002 stands.
- **Mandatory compensations (binding engineering commitments for Phase 3+):**
  1. **NxJournal/NxRollback is the sole rollback authority.** No reliance on wizard undo, which does not exist; every mutation is journaled and reversible by NEXTRIX's own bundled tooling.
  2. `UseKernelDriver: false` always; **no `DefenderDisabled`/`UCPDDisabled` requirements**; NEXTRIX follows the UltraOS model of a playbook whose requirement set needs zero security neutralization wherever the selected tweaks permit.
  3. The wizard's trust posture (unsigned beta, required exclusions, permanently-unverified status) is **disclosed honestly** in user-facing documentation.
  4. The wizard build tested against is **pinned** in testing records (AME Beta v0.8.4 at 2026-11-23); schema drift tracked via the official docs changelog; playbook schema generation is validated against the documented 14-action vocabulary.
  5. Hash-pinned release artifacts; zero floating downloads at install time; `THIRD-PARTY-NOTICES.md` if anything is ever bundled (target remains zero bundled third-party binaries — UltraOS proves a pure-YAML+PowerShell playbook of 166 KB is possible).
  6. This ADR is **re-opened** if AME ≥ 1.0 ships universal reversibility, or if platform changes block any compensation above.

## ADR-007 — Official GitHub remote and release policy

- **Date:** 2026-11-23
- **Decision by:** Project owner (repository instruction).
- **Decision:** `https://github.com/Goku-py/NEXTRIX` (private) is NEXTRIX's official remote repository. The pre-existing repository content — the GGOS Windows-playbook project (branch history, tags 0.3.2 / 0.4.0 / v0.5.0 / v0.6.1 / v1.1.0 and its releases) — was removed at the owner's explicit instruction on 2026-11-23. **A full mirror backup of the removed state was taken before any deletion** and retained locally (execution note below); the backup is not published.
- **Release policy (owner instruction, binding for every release):**
  1. Every version release = commits pushed + version tagged + GitHub Release created/updated.
  2. Release notes are **short, easy-to-understand changelogs specific to that release** — plain language, not the detailed engineering log.
  3. The detailed engineering history remains `CHANGELOG.md` in the repository; GitHub Release notes are the summary layer.
  4. Evidence discipline applies to release notes: no performance claims without owner-supplied results.
- **Versioning:** NEXTRIX starts at **v0.1.0** (Phase 0–2 foundation). The old GGOS tags were deleted with the old content; the version namespace is fresh.
- **Consequences:** PD-5 resolved by execution. Release notes and `CHANGELOG.md` serve different audiences but must not diverge in substance — notes summarize, `CHANGELOG.md` details.

**Execution note (2026-11-23, updated same day):** a full mirror backup of the removed repository state was taken before any deletion, as a safety measure. The owner later confirmed the backup was not needed and instructed its deletion; it has been removed. No copy of the old GGOS content is retained by NEXTRIX.

## Pending decisions (escalated, not yet taken)

| ID | Question | Status / Needed by |
|---|---|---|
| PD-1 | Interface model for tweak selection (wizard-only UX vs wizard + companion selection tool exporting a chosen-tweak configuration) | Phase 3 design |
| PD-2 | AME Wizard platform facts | **Partially resolved by R6** (schema, undo absence, verification, distribution documented in `research/sources/r6-hone-amewizard.md`); residual: wizard EULA text is not published online — treat as unknown; note in SECURITY_POLICY.md |
| PD-3 | Official 26H2 build number | **RESOLVED** — 26H2 = build 26300 (four independent code sources, 2026-11-23); ADR-003 amended |
| PD-4 | NX18 companion component delivery + auto-start model (owner consent required for any background component) | Phase 5 |
| PD-5 | Git initialization and repo hygiene | **RESOLVED** — git initialized; official remote connected; old content removed after local mirror backup (ADR-007) |
| PD-6 | NEXTRIX repository's own license (owner decision; note GPL-3.0 reference projects cannot be copied regardless — patterns are reimplemented, not reused) | Before first public release |
