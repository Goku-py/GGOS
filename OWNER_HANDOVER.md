# NEXTRIX — Owner Handover Report

**Version:** v0.7.0-rc (release candidate) · **Date:** 2026-11-23
**Status:** Phases 0–6 delivered per the master directive. **Owner hardware validation is pending — by design, owner-only.**

---

## 1. What NEXTRIX is

An adaptive, hardware-aware Windows 11 optimization playbook: 282 registry-defined tweaks across 20 categories, delivered as an AME Wizard playbook, driven by a PowerShell 5.1 engine whose state journal is the sole rollback authority. Engineered for precision; nothing claims performance without owner evidence.

## 2. Implemented (verified, in-repo, CI-gated)

| Area | What exists | Evidence |
|---|---|---|
| **Engine** | NxJournal (hash-chained, capture-refusal, only-if-ours, re-arm with archival), NxBuild (build/capability + edition/arch gates), NxHardware (read-only detection, uncertainty-marked), NxCompat (hardware/build/edition/architecture/excluded gates), NxVerify, NxRollback (4 scopes + category delegation + irreversible labeling), NxApply (10-step protocol, Plan mode, approval gate, function dispatcher), Import-NxCore.ps1 loader | 18 suites / **1,293 assertions**, validator 282 entries |
| **Registry** | 20 categories, 282 entries, 32-field metadata; 242 SyntaxValidated / 40 Defined (each with a stated reason); banned targets + never-touch services enforced at build | `registry/*.json`, validator PASS |
| **Playbook** | Generated AME source: 25 files, 282 options, 76 FeaturePages, **0 raw registry writes** (71 journaled), rollback surface emitted, presetExcluded mechanically unchecked, `UseKernelDriver: false`, no security-neutralization requirements | `playbook/`, generator dry-run/determinism tests |
| **NX18 Session Manager** | Detection, profile store, plan-first + `-Approved`, journaled apply, monitor/heartbeat, verified-step restore, cooldown, manual stop, integrity-gated crash recovery, protected-process guard (6 classes, no override) | 77 assertions |
| **Tooling** | Registry validator, bounded test runner (per-suite timeouts, PS 5.1), matrix exporter (109 dependency edges; 12 symmetric conflict pairs), packager (28 engine pins, SHA256SUMS, bootstrap loader) | `tools/` |
| **Docs** | Architecture, catalogue, classification, profiles, research (6 streams + synthesis), licensing, security policy, journal/rollback design, compatibility (hardware/Windows), packaging, testing guide, decisions (ADR-001…007) | Root + `docs/` + `research/` |

## 3. Not implemented / deliberately withheld (honest)

1. **Owner-gated statuses:** no entry has been promoted beyond `SyntaxValidated`; E2+ evidence is zero until the owner tests.
2. **NX18-007** service suspension: plan-only (no journaled service-state engine yet).
3. **NX02-009/010/011 + NX01-009:** composition functions pending (emitted by name; playbook options act as probes).
4. **NX12 removals:** playbook actions are the read-only plan; guarded write functions await explicit-selection wiring (Phase 6 selection tooling).
5. **NX17:** 12 of 14 entries read-only by design (BCD/device/verifier paths withheld until documented interfaces and safety gates exist).
6. **GPU vendor driver profiles:** guided-only (no documented OS write path); NEXTRIX does not fake capability.
7. **Packaging:** staging + hashes + bootstrap are automated; the final `.apbx` container is an owner 7-Zip step (documented, by platform convention).

## 4. Unresolved research / open watch items

- AME wizard EULA text is not published online (PD-2 residual); wizard schema drift tracked via docs changelog.
- 26H2 = 26300 is a four-source projection; no NEXTRIX tweak has been owner-validated on it.
- Intel hybrid / AMD dual-CCD X3D behavior is synthetic-tested only; physical validation pending (NX19).
- AME ≥1.0 "universal reversibility" would reopen ADR-006 (compensations already isolate rollback).

## 5. Manual testing instructions

1. Read `MANUAL_TESTING_GUIDE.md` (282 per-tweak sheets; pre-flight section first). **Never test on a daily-driver machine; use a disposable VM or imaged physical disk.**
2. Start with NX16 (restore point, pre-flight, backups), then read-only reports, then CORE entries, then CONDITIONAL; ADVANCED/EXPERIMENTAL only after a snapshot.
3. For each tweak: record pre-state → apply (`-Approved`) → verify per the sheet → inspect side effects → roll back (`Invoke-NxRollback -TweakId`) → verify exact original state → record evidence (journal seq, before/after, screenshots) in the guide's template.
4. Run the static gate before and after: `powershell.exe -File tools\Test-NxAll.ps1` (18 suites) and `pwsh -File tools\Test-NxRegistry.ps1`.
5. Session manager: `Start-NxSession -Plan` first (writes nothing); hardware targets H1–H7 per `HARDWARE_COMPATIBILITY.md`; recovery drill with `Invoke-NxSessionRecovery -WhatIf` then real on a dummy profile.
6. Promote statuses only from real evidence; performance claims require the guide's appendix methodology (metric-matched, 3–5 baseline, one change, 3–5 after runs).

## 6. Known risks

- **Platform trust posture (ADR-006):** unsigned AME beta; Defender exclusions in its documented flow; playbook verification discretionary. NEXTRIX offsets: journal-only rollback, no security-neutralization requirements, hash-pinned artifacts, disclosed posture.
- **Removal irreversibility:** NX12 removals are labeled `Success-Irreversible`; ensure Store reinstall paths exist before removing.
- **Security entries:** NX14 can only maintain or raise protection; consent gates are enforced in code and registry.
- **Host flakiness:** PS7 DISM/Appx + some WMI/TPM calls hang on the dev host; gate uses the bounded runner under PS 5.1. Do not read a provider TIMEOUT as a suite failure.
- **Session records are untrusted input:** journal-root restriction enforced; residual local-writer scenario documented (KNOWN_ISSUES 14 area).

## 7. Compatibility limits

x64 Windows 11 only, builds 22631–26300; Home included where an ADMX-backed local policy exists (documented-limited otherwise); 24H2 is a reference-divergent caution zone; ARM64 and Windows 10 are out of scope; 26H2 data is projection-based.

## 8. Future priorities (in order)

1. Owner hardware validation wave 1 → promote real statuses (NX16/NX01 first).
2. NX12 explicit-selection wiring (removal actions).
3. Composition functions: NX02-009/010/011, NX01-009.
4. NX18-007 once a journaled service engine exists; PD-4 decision (manual/boot-time vs consent-gated logon task — separate ADR).
5. Packaging polish: optional signed release pipeline; AME 1.0 readiness re-check.
6. Parser localization (English-format fail-closed today) and per-user Default-hive support if demand exists.

## 9. Handover checklist

- [ ] Read: `README.md` → `docs/DECISIONS.md` → `PROJECT_ARCHITECTURE.md` → `MANUAL_TESTING_GUIDE.md`.
- [ ] Run the static gate on a clean machine (validator + bounded runner).
- [ ] Build the package (`tools/New-NxPackage.ps1 -Version 0.7.0`), verify `SHA256SUMS`, follow `docs/PACKAGING.md` for the owner 7-Zip step.
- [ ] Snapshot the test machine; execute the guide's NX16 → read-only → CORE path; record evidence.
- [ ] Promote statuses yourself (owner-only) and send findings back into `KNOWN_ISSUES.md`.

**NEXTRIX — ENGINEERED FOR PRECISION.**
