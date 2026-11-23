# NEXTRIX — Known Issues

**Status:** Phase 1 deliverable · 2026-11-23. Scope: (A) NEXTRIX's own current limitations, (B) reference-ecosystem issue knowledge that shapes our design, (C) open risks with mitigations. No NEXTRIX code exists yet, so there are no NEXTRIX code defects — only phase limitations, stated honestly.

---

## A. NEXTRIX current limitations (truthful status)

1. **Nothing is implemented.** All 272 catalogue entries hold status CANDIDATE; no apply/rollback code, no playbook, no tooling exists yet. This document set is design + research.
2. **All evidence is desk-level.** E0/E1 only across the catalogue; zero performance claims anywhere in the repository. E2+ requires the owner's physical testing (workflow defined in `TWEAK_RESEARCH.md` §15).
3. **Engine platform carries documented limitations** (owner-accepted in ADR-006): AME Beta v0.8.4 has no standardized playbook uninstall; it is unsigned and its official instructions require Defender exclusions; verification status is discretionary and NEXTRIX will ship unverified. Compensations are binding (journal-only rollback, `UseKernelDriver: false`, no security-neutralization requirements, disclosed trust posture, pinned wizard version, hash-pinned artifacts).
4. **Wizard EULA text is unpublished** (PD-2 residual) — user-facing docs must state this rather than assert unknown terms.
5. **26H2 (26300) support is projection-based:** confirmed as the build number by four references' code, but no NEXTRIX tweak has been validated on it; SynergyOS already labels 26H2 "experimental, unexpected bugs may arise."
6. **Research gaps inherited:** SapphireOS ISOs (Discord-gated), Vain's scheduling engine (closed, RE-prohibited), FSOS-X/Hone internals (closed), XOS's stable C# toolkit, all bundled binaries — unauditable, and documented as such; several large source files were not fetched (enumerated per stream in `research/sources/r1–r6` limitations sections).
7. **24H2 (26100) is the divergent build** — skipped by XOS, UCPD-quirky per SynergyOS; 24H2-targeted tweaks carry extra capability checks by policy.
8. **Per-tweak documentation depth is queued:** the 30-field registry entries are written during Phase 3/4 per category; the catalogue currently carries summary-level metadata.

## B. Ecosystem issue knowledge shaping NEXTRIX (summary; full citations in `COMPATIBILITY_RESEARCH.md` §3)

- Update-hostile changes cause cascading breakage (Revi #49; Edge→WU loops; Home-edition policy ignores).
- Anti-cheat is the dominant gaming constraint (THE FINALS/Vanguard/Valorant/FACEIT/EAC incidents; mitigation and driver-blocklist changes are the trigger class).
- Hardware-specific breakage is real and recurring (AMD chipset installer; ROG Ally sleep; Secured-core VBS silent no-ops; Killer/Realtek NIC keyword forcing; MPO composition errors; iGPU priority fallout).
- Removal operations are the least reversible and most incident-prone class (Defender residue and recovery-screen bugs; WebView2 dependency fallout; OneDrive data-loss incident history).
- Engine/tooling failures are predictable and testable (UltraOS load-rule and folder-name incidents → dry-run harness requirement; UCPD write failures → policy fallbacks; launch-protected services → direct-write workaround).
- Reference negative-results ledger (16 anti-patterns with breakage evidence) is encoded as validator regression data (`TWEAK_RESEARCH.md` §14).

## C. Open risks and mitigations

| # | Risk | Mitigation (in force) |
|---|---|---|
| R1 | Platform (AME Beta) schema drift under a 0.x version breaks generated playbook | Wizard version pinned in testing; docs changelog tracked; generated source validated against the documented 14-action schema; UltraOS `ame-wizard-format-spec.md` + `ame-dryrun.py` flagged for Phase 3 tooling hardening |
| R2 | Journal/rollback layer must carry 100% of reversibility (platform gives nothing) | Architecture already isolates NxJournal/NxRollback as sole rollback authority (ADR-006 compensation 1); only-if-ours restore + capture-refusal semantics adopted from validated reference patterns |
| R3 | Owner testing bandwidth vs 272-candidate catalogue | Phase 4 implements priority categories first (NX01/NX02/NX09/NX04/NX16); manual test sheets scoped per tweak; E2 promotion only where the owner chooses to test |
| R4 | Hardcoded-value drift across builds (per-user service suffixes, UCPD protection, removed code paths) | Runtime name resolution, existence checks, policy fallbacks — all mandated patterns (`COMPATIBILITY_RESEARCH.md` §2) |
| R5 | Trust perception (wizard exclusions, AV-evasion packaging) | Honest disclosure in docs; NEXTRIX artifacts hash-pinned, contents public, zero bundled binaries |
| R6 | Scope creep toward "more tweaks" | Catalogue policy: no entry without purpose, deps, conflicts, rollback; validator rejects duplicate modification targets; rejected list is research-confirmed and growing only with evidence |
| R7 | Single-machine evidence mistaken for general truth | Evidence ladder: E2 = one configuration; only owner-supplied multi-config results reach E3; docs forbid generalizing E2 |

## D. Issue tracking

New issues discovered during implementation or owner testing are appended here with: date, affected tweak ID(s), evidence, status (open/mitigated/closed), and the catalogue/validator change that resolves them. No entries yet — nothing has run.
