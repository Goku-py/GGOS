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

### Wave 1 — IN FLIGHT (launched 2026-11-23; gate: release v0.3.0)

| # | Task | Owner (agent) | Files owned | Status |
|---|---|---|---|---|
| 1.1 | Finish NX16 engine functions (12 `Defined` → `Implemented`) | W1-A | `registry/NX16.json`, `src/nxcore/functions/NX16.ps1`, `tools/selftests/Test-NX16.ps1` | IN FLIGHT |
| 1.2 | AME playbook generator (registry → playbook source, dry-run mode) | W1-B | `tools/Invoke-NxBuild.ps1`, `playbook/**` | IN FLIGHT |
| 1.3 | NX01 Windows Foundation (16 entries) | W1-C | `registry/NX01.json`, `src/nxcore/functions/NX01.ps1` | IN FLIGHT |
| 1.4 | NX02 Gaming & Esports (12 entries; per-game FSO stays in NX04) | W1-D | `registry/NX02.json`, `src/nxcore/functions/NX02.ps1` | IN FLIGHT |
| 1.5 | NX09 Power Management (15 entries; AC/DC journaled separately; never delete active/stock plans) | W1-E | `registry/NX09.json`, `src/nxcore/functions/NX09.ps1` | IN FLIGHT |
| 1.6 | NX04 GPU & Graphics (23 entries; vendor-gated; undocumented driver interfaces stay `Defined` + guided) | W1-F | `registry/NX04.json`, `src/nxcore/functions/NX04.ps1` | IN FLIGHT |

Gate 1 checklist (coordinator): full validator across all `registry/NX*.json` · parser check all functions · independent review agent audits wave for policy compliance · integrate · release v0.3.0.

### Wave 2 — PENDING (launch after Gate 1)

| # | Task | Files owned |
|---|---|---|
| 2.1 | NX03 CPU & Processor (13) | `registry/NX03.json`, `functions/NX03.ps1` |
| 2.2 | NX05 Memory Management (11) | `registry/NX05.json`, `functions/NX05.ps1` |
| 2.3 | NX06 Storage & Filesystem (13) | `registry/NX06.json`, `functions/NX06.ps1` |
| 2.4 | NX07 Network (22; adapter-parameterized, only-if-present writes) | `registry/NX07.json`, `functions/NX07.ps1` |
| 2.5 | NX11 Background & Services (19; detection-gated, never blanket) | `registry/NX11.json`, `functions/NX11.ps1` |
| 2.6 | NX13 Privacy & Telemetry (14; edition-aware floors) | `registry/NX13.json`, `functions/NX13.ps1` |
| 2.7 | NX15 Visual & Interface (14; cosmetic-only framing) | `registry/NX15.json`, `functions/NX15.ps1` |

### Wave 3 — PENDING (launch after Gate 2)

| # | Task | Notes |
|---|---|---|
| 3.1 | NX08 Input & Peripherals (7) | mouse/keyboard/HID read-heavy |
| 3.2 | NX10 Thermal Management (8) | read-only monitoring; no firmware writes |
| 3.3 | NX12 Windows Debloat (14) | AppX honesty labels; protected-dependency guard |
| 3.4 | NX14 Security Configuration (15) | reports + consent gates; Section 15 enforced |
| 3.5 | NX17 Advanced Windows Config (14) | isolated; individually selectable only |
| 3.6 | NX19 CPU Topology & Scheduling (11) | **hardest module** — open topology engine (P/Invoke `GetLogicalProcessorInformationEx`, CPU-Set-ID mapping); no hardcoded indexes |
| 3.7 | NX20 Hardware & Driver Management (11) | read-only inventory; never automated driver ops |

## PHASE 5 — Game Session Manager (Wave 4, PENDING)

| # | Task | Notes |
|---|---|---|
| 4.1 | NX18 session engine | `src/nxsession/` + `registry/NX18.json`. Session lifecycle per PROJECT_ARCHITECTURE §7: detect → profile match → approval → journal-armed temporary changes → monitor → verified-step restore on any exit path. Protected-process guard (anti-cheat/security/launcher/OBS/recording/audio/peripherals) is non-negotiable. Boot-time interrupted-session recovery. Session journal separate from main journal, same schema. |
| 4.2 | NX18 self-tests | crash/kill simulation in temp; recovery ritual proof |

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
| 1 | v0.3.0 | Gate 1 passed (validator + review + integration) |
| 2 | v0.4.0 | Gate 2 passed |
| 3 | v0.5.0 | Gate 3 passed |
| 4 | v0.6.0 | NX18 self-tested |
| 5 | v0.7.0-rc | Full doc set + handover report; `ReleaseApproved` remains owner-only |
