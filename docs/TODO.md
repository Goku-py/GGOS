# NEXTRIX — Execution TODO (Phases 4 → 6)

**Living tracking document.** Statuses are updated by the coordinator only, after each workstream's evidence is verified. Wave completion gates: full-registry validator run, syntax check of all modules, independent review of the wave, integration commit, version release with short notes (ADR-007).

## Standing rules (every workstream, every agent)

1. **File ownership is absolute.** A workstream owns exactly its listed files. Shared files (schema, validator, core `src/nxcore/*` modules, `TWEAK_CATALOGUE.md`, `CHANGELOG.md`, `KNOWN_ISSUES.md`, `README.md`, `docs/DECISIONS.md`) are coordinator-only. Findings that need shared-file changes are reported, never self-applied.
2. **Testing boundary (directive §16):** never apply/execute any tweak against the development machine. Validation = registry validator + PowerShell parser + temp-folder self-tests + read-only queries only.
3. **Evidence discipline:** E1 requires a Microsoft/vendor documentation URL; otherwise E0 with provenance noted. Zero performance claims anywhere.
4. **Validator is law:** `tools/Test-NxRegistry.ps1` must show zero errors attributable to the workstream's files. Banned targets / never-touch services / preset rules / duplicate targets are hard errors by design.
5. **Every mutation path goes through the pipeline:** capture (`Capture-NxRegistryValue`) → journal (`Add-NxJournalEntry`) → apply → verify (`Test-NxConfigurationState`) → journal result.

---

## PHASE 4 — Tweak implementation (waves 1–3)

### Wave 1 — COMPLETE (all six workstreams delivered 2026-11-23; gate: release v0.3.0)

| # | Task | Owner (agent) | Files owned | Status |
|---|---|---|---|---|
| 1.1 | Finish NX16 engine functions (12 `Defined` → `Implemented`) | W1-A | `registry/NX16.json`, `src/nxcore/functions/NX16.ps1`, `tools/selftests/Test-NX16.ps1` | DONE |
| 1.2 | AME playbook generator (registry → playbook source, dry-run mode) | W1-B | `tools/Invoke-NxBuild.ps1`, `playbook/**` | DONE |
| 1.3 | NX01 Windows Foundation (16 entries) | W1-C | `registry/NX01.json`, `src/nxcore/functions/NX01.ps1` | DONE |
| 1.4 | NX02 Gaming & Esports (12 entries; per-game FSO stays in NX04) | W1-D | `registry/NX02.json`, `src/nxcore/functions/NX02.ps1` | DONE |
| 1.5 | NX09 Power Management (15 entries; AC/DC journaled separately; never delete active/stock plans) | W1-E | `registry/NX09.json`, `src/nxcore/functions/NX09.ps1` | DONE |
| 1.6 | NX04 GPU & Graphics (23 entries; vendor-gated; undocumented driver interfaces stay `Defined` + guided) | W1-F | `registry/NX04.json`, `src/nxcore/functions/NX04.ps1` | DONE |

Gate 1 result (2026-11-23): **PASSED** — validator 0 errors/0 warnings (83 tweaks); self-tests 63/63 (NX16), 62/62 (NX09), 11/11 (journal, incl. a 40-iteration integrity regression loop); generator 0 errors, 34 journaled registry writes, 0 raw writes; parser clean on PowerShell 5.1 + 7. Released as **v0.3.0**. Wave 2 launching immediately after.

### Wave 2 — COMPLETE (all seven delivered 2026-11-23; gate: release v0.4.0)

| # | Task | Files owned |
|---|---|---|
| 2.1 | NX03 CPU & Processor (13) — **DONE** | `registry/NX03.json`, `functions/NX03.ps1` |
| 2.2 | NX05 Memory Management (11) — **DONE** | `registry/NX05.json`, `functions/NX05.ps1` |
| 2.3 | NX06 Storage & Filesystem (13) | `registry/NX06.json`, `functions/NX06.ps1` |
| 2.4 | NX07 Network (22; adapter-parameterized, only-if-present writes) — **DONE** | `registry/NX07.json`, `functions/NX07.ps1` |
| 2.5 | NX11 Background & Services (19; detection-gated, never blanket) — **DONE** | `registry/NX11.json`, `functions/NX11.ps1` |
| 2.6 | NX13 Privacy & Telemetry (14; edition-aware floors) — **DONE** | `registry/NX13.json`, `functions/NX13.ps1` |
| 2.7 | NX15 Visual & Interface (14; cosmetic-only framing) — **DONE** | `registry/NX15.json`, `functions/NX15.ps1` |

Gate 2 result (2026-11-23): **PASSED** — validator 0 errors/0 warnings (189 tweaks / 12 files, both PowerShell hosts); 10 self-test suites = 561 assertions, 0 failures; parser sweep 31 files clean; generator dry-runs 0 errors. Released as **v0.4.0**. Wave 3 launching immediately after.

### Wave 3 — COMPLETE (all seven delivered 2026-11-23; gate: release v0.5.0)

| # | Task | Notes |
|---|---|---|
| 3.1 | NX08 Input & Peripherals (8) — **DONE** | mouse/keyboard/HID; +NX08-008 DataQueueSize (researched 2026-11-23) |
| 3.2 | NX10 Thermal Management (8) — **DONE** | read-only monitoring; no firmware writes |
| 3.3 | NX12 Windows Debloat (14) — **DONE** | AppX honesty labels; protected-dependency guard; removal write functions await explicit-selection wiring |
| 3.4 | NX14 Security Configuration (15) — **DONE** | reports + consent gates; Section 15 enforced; mutations never lower protection |
| 3.5 | NX17 Advanced Windows Config (14) — **DONE** | isolated; individually selectable only; 2 Implemented / 12 read-only Defined by design |
| 3.6 | NX19 CPU Topology & Scheduling (11) — **DONE** | open topology engine (P/Invoke, P/E/CCD/X3D via L3 asymmetry, CPU-Set-ID map); 149/149 synthetic tests; no hardcoded indexes |
| 3.7 | NX20 Hardware & Driver Management (11) — **DONE** | read-only inventory; never automated driver ops |

Gate 3 result (2026-11-23): **PASSED** — 17/17 self-test suites, **1,216 assertions, 0 failures** (bounded runner `tools/Test-NxAll.ps1` under Windows PowerShell 5.1; per-suite timeouts added after a PS7 DISM hang); parser 46 files clean; validator 0/0 (270 tweaks / 19 files) after status promotion (231 entries → SyntaxValidated); playbook v0.5.0 regenerated (24 files, 71 journaled writes, 0 raw). Released as **v0.5.0**. Phase 5 launching.

## PHASE 5 — Game Session Manager (Wave 4, COMPLETE 2026-11-23)

| # | Task | Notes |
|---|---|---|
| 4.1 | NX18 session engine — **DONE** | `src/nxsession/` + `registry/NX18.json`. Session lifecycle: detect → profile match → approval → journal-armed temporary changes → monitor → verified-step restore on any exit path. Protected-process guard (anti-cheat/security/launcher/OBS/recording/audio/peripherals) non-negotiable. Crash recovery via `Invoke-NxSessionRecovery`; no background service (PD-4). 11 Implemented / 1 Defined (007 plan-only). |
| 4.2 | NX18 self-tests — **DONE** | 77 assertions in 5.3s (state machine, guard table, cooldown, recovery reverse-order + tamper refusal, WhatIf). |

Gate 4 result (2026-11-23): **PASSED** — 18/18 suites, **1,293 assertions, 0 failures**; validator 0/0 (282 tweaks / 20 files); parser clean; playbook v0.6.0 (25 files, 0 errors); 11 NX18 entries promoted to SyntaxValidated. Released as **v0.6.0**. Phase 6 (Wave 5) launching.

## PHASE 6 — Documentation & handover (Wave 5, PENDING)

| # | Task | Notes |
|---|---|---|
| 5.1 | MANUAL_TESTING_GUIDE.md | per-tweak manual test sheets generated from the registry (owner is the only promoter past ConfigurationValidated) |
| 5.2 | Matrix tooling + docs | `tools/Export-NxMatrices.ps1` generating `DEPENDENCY_MATRIX.md` + `CONFLICT_MATRIX.md` mechanically from the registry |
| 5.3 | HARDWARE_COMPATIBILITY.md + WINDOWS_COMPATIBILITY.md | from `COMPATIBILITY_RESEARCH.md` + implemented capability gates |
| 5.4 | Catalogue status sync | `TWEAK_CATALOGUE.md` statuses aligned with registry truth (coordinator-owned) |
| 5.5 | Owner handover report | implemented / not implemented / unresolved research / risks / testing instructions / future priorities (directive §18F) |

## Release cadence

| Wave | Version | Trigger |
|---|---|---|
| 1 | v0.3.0 | **RELEASED 2026-11-23** — Gate 1 passed |
| 2 | v0.4.0 | **RELEASED 2026-11-23** — Gate 2 passed |
| 3 | v0.5.0 | **RELEASED 2026-11-23** — Gate 3 passed |
| 4 | v0.6.0 | **RELEASED 2026-11-23** — Gate 4 passed |
| 5 | v0.7.0-rc | Full doc set + handover report; `ReleaseApproved` remains owner-only |
