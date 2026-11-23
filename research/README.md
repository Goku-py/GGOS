# NEXTRIX Research (Phase 1)

Methodology, source map and synthesis plan for reference-project research.
Access date for all automated research: **2026-11-23**.

## Methodology

Each reference project is inspected **beyond its README**: repository structure, release notes, actual tweak source files (playbook/YAML/PowerShell/JSON), registry actions, service configurations, rollback mechanisms, dependencies and licenses. Findings carry mandatory evidence tags:

| Tag | Meaning |
|---|---|
| IMPLEMENTED | Verified in source actually inspected (file path cited) |
| DOCUMENTED | Claimed in official readme/site, not verified in source |
| COMMUNITY-CLAIM | Third-party / community statement |
| DEV-BENCHMARK | Developer-reported performance numbers |
| VERIFIED | Independently verified performance results (rare) |

An advertised feature is never recorded as proof of performance. Unreachable/private/paywalled sources are recorded as research limitations — never guessed.

## Source map (research agents r1–r6)

| Agent | File | Covers | Status (2026-11-23) |
|---|---|---|---|
| R1 | `sources/r1-fsosx-xos.md` | FSOS-X (fsosx.com), XOS Playbook, XOS Toolkit | **COMPLETE** — inspected; reconciled |
| R2 | `sources/r2-atlasos-revios.md` | AtlasOS, ReviOS Playbook | **COMPLETE** — inspected; reconciled |
| R3 | `sources/r3-sapphire-vain.md` | SapphireOS, SapphireOS-Playbook, Vain-Playbook | **COMPLETE** — inspected; reconciled |
| R4 | `sources/r4-synergy-ultraos.md` | SynergyOS, SynToolkit, UltraOS Playbook | **COMPLETE** — inspected; reconciled |
| R5 | `sources/r5-winutil-sophia.md` | Chris Titus WinUtil, Sophia Script | **COMPLETE** — inspected; reconciled |
| R6 | `sources/r6-hone-amewizard.md` | Hone (hone.gg), AME Wizard platform (schema, undo architecture, licensing/distribution terms) | **COMPLETE** — inspected; reconciled |

All six streams returned on 2026-11-23 and were read in full by the coordinator. Reconciliation decisions live in `docs/RESEARCH_RECONCILIATION.md`; synthesized deliverables (`PROJECT_RESEARCH.md`, `PLAYBOOK_COMPARISON.md`, `TWEAK_RESEARCH.md`, `COMPATIBILITY_RESEARCH.md`, `LICENSING_REVIEW.md`, `KNOWN_ISSUES.md`) are generated in the consolidated pass.

R6 is weighted highest in consequences: the owner has chosen the **AME Wizard playbook** as NEXTRIX's engine (ADR-002), so the platform's real schema capabilities, undo/rollback architecture and licensing/distribution terms directly shape `PROJECT_ARCHITECTURE.md`.

## Synthesis plan (after r1–r6 return)

| Required output | Built from |
|---|---|
| `PROJECT_RESEARCH.md` | All six files: per-project identity, findings, limitations |
| `PLAYBOOK_COMPARISON.md` | Cross-project feature comparison matrix |
| `TWEAK_RESEARCH.md` | Per-tweak-idea provenance, evidence tags, adopt/reject/adapt decisions |
| `COMPATIBILITY_RESEARCH.md` | Build guards, hardware conditions, known compatibility issues observed |
| `LICENSING_REVIEW.md` | License table per project + AME Wizard distribution terms |
| `KNOWN_ISSUES.md` | Compatibility issues, broken behaviors, rejected-idea cautions |

Findings then reconcile into `TWEAK_CATALOGUE.md` (evidence levels corrected, candidates added/dropped) and `PROJECT_ARCHITECTURE.md` (platform facts confirmed or revised).

## Standing constraints on all research

- Read-only web research; no tweaks executed anywhere.
- No copying of source beyond short (<10-line) illustrative snippets, each marked with source URL and license.
- Closed-source products (FSOS-X, Hone) are documented as claims only — never as verified implementation.
- Commercial/restricted licenses are recorded, not worked around.
