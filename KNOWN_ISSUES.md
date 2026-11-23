# NEXTRIX — Known Issues

**Status:** Phase 1 deliverable · 2026-11-23. Scope: (A) NEXTRIX's own current limitations, (B) reference-ecosystem issue knowledge that shapes our design, (C) open risks with mitigations. No NEXTRIX code exists yet, so there are no NEXTRIX code defects — only phase limitations, stated honestly.

---

## A. NEXTRIX current limitations (truthful status)

1. **Phase 3 foundation is implemented and self-tested** (v0.2.0): journal, detection, eligibility/verify/rollback/apply pipeline, validator, NX16 registry at full depth. NX16-012/013/014/015/016 hold status **Implemented** (registry-scope engine); the remaining NX16 functions and all other categories are `Defined`/`Candidate` — the apply pipeline reports unimplemented engine functions explicitly instead of pretending. Playbook generator not yet written.
2. **All evidence is desk-level.** E0/E1 only across the catalogue; zero performance claims anywhere in the repository. E2+ requires the owner's physical testing (workflow defined in `TWEAK_RESEARCH.md` §15).
3. **Engine platform carries documented limitations** (owner-accepted in ADR-006): AME Beta v0.8.4 has no standardized playbook uninstall; it is unsigned and its official instructions require Defender exclusions; verification status is discretionary and NEXTRIX will ship unverified. Compensations are binding (journal-only rollback, `UseKernelDriver: false`, no security-neutralization requirements, disclosed trust posture, pinned wizard version, hash-pinned artifacts).
4. **Wizard EULA text is unpublished** (PD-2 residual) — user-facing docs must state this rather than assert unknown terms.
5. **26H2 (26300) support is projection-based:** confirmed as the build number by four references' code, but no NEXTRIX tweak has been validated on it; SynergyOS already labels 26H2 "experimental, unexpected bugs may arise."
6. **Research gaps inherited:** SapphireOS ISOs (Discord-gated), Vain's scheduling engine (closed, RE-prohibited), FSOS-X/Hone internals (closed), XOS's stable C# toolkit, all bundled binaries — unauditable, and documented as such; several large source files were not fetched (enumerated per stream in `research/sources/r1–r6` limitations sections).
7. **24H2 (26100) is the divergent build** — skipped by XOS, UCPD-quirky per SynergyOS; 24H2-targeted tweaks carry extra capability checks by policy.
8. **Per-tweak documentation depth:** NX16 now carries full 32-field registry metadata; the remaining 19 categories are queued for the same depth as they are implemented (Phase 4 order: NX01, NX02, NX09, NX04, then the rest).
9. **Wizard confirmation UX:** the AME platform cannot express per-tweak confirmation dialogs; `SelectionPlusConfirmation`/`ExplicitConsent` models are journal-recorded but enforced at selection level in the generated playbook (platform limitation, disclosed).
10. **Parameterized rollback in the wizard UI:** the wizard cannot collect free-text parameters; per-tweak/-category/-profile rollback calls in `rollback.yml` carry placeholders to edit, while `-All` is fully functional (documented).
11. **Packaging not yet automated:** the generator emits playbook source + a SHA256-pinned NxCore manifest; copying NxCore flat into `Executables/` and building the `.apbx` remains a documented manual step (TODO Wave 5).
12. **HKCU scope in the generated playbook:** journaled registry writes execute as the invoking elevated user, so HKCU resolves to that user's hive (journal-consistent, matches `Invoke-NxApply`). Per-user rollout to other profiles would require dedicated functions (documented, W1-B note).
13. **NX12 removal actions are plan-only in the generated playbook** (intentional): the removal write functions exist and are guarded, but require explicit-selection wiring in the selection tooling (Phase 6) before the wizard can remove apps. No hidden removals; the option currently surfaces the safe plan only.
14. **NX14 interpretation decisions (ratified 2026-11-23):** Controlled Folder Access is implemented as Enabled/Audit with Off omitted (Section 15 forbids lowering protection via a CONDITIONAL entry); NX14-014's playbook action is the read-only dependency report, with the setter available for explicit owner use.
15. **Host provider hangs during validation (not a product defect):** PowerShell 7's DISM/Appx path and some WMI/TPM calls hang or are extremely slow on the dev host (NX12 was caught in PS7 DISM enumeration; NX14 once stalled on TPM/DeviceGuard queries). Gate runs now use `tools/Test-NxAll.ps1` under Windows PowerShell 5.1 with per-suite timeouts; a TIMEOUT on a flaky provider does not imply a suite failure — agent-run evidence stands and reruns confirm.
16. **NX18 lives outside `src/nxcore`:** the playbook generator flags its functions as "not found at generate time" because it inventories `src/nxcore` only. Runtime packaging (Phase 6) must bundle `src/nxsession/NX18.ps1` (it dot-sources `Import-NxCore.ps1` itself). Playbook NX18 options are informational probes until that packaging step.
17. **PD-4 recommendation pending owner:** keep session recovery manual/boot-time for Phase 5 (process steps expire with the process; only power/registry need replay and both are journal-covered). If automation is later required, prefer a consent-gated logon scheduled task calling `Invoke-NxSessionRecovery` over a background service, via a separate ADR.

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
