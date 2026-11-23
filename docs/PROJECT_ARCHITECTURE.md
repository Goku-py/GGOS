# NEXTRIX — Project Architecture

**Status:** v0.2 DRAFT PROPOSAL — owner decisions ADR-002/003/006 recorded; Phase 1 research reconciled (2026-11-23). Pending: owner approval of the catalogue.
**Engine (ADR-002/ADR-006):** AME Wizard playbook — **NxJournal/NxRollback is the sole rollback authority** (the platform provides no standardized uninstall). **Targets (ADR-003):** Windows 11 23H2 (22631), 24H2 (26100), 25H2 (26200), 26H2 (26300). Insider builds: experimental.
**Nothing in this document has been implemented or applied.**

---

## 1. Product goals and non-goals

**Goals**

1. Hardware-aware, workload-aware, individually selectable Windows configuration.
2. Exact original-state preservation and independent rollback for every modification.
3. Windows build compatibility through capability detection, not build-number assumption.
4. Transparent, documented, evidence-tagged configuration changes.
5. Maintainable modular architecture that survives future Windows builds.

**Non-goals**

- Being the tweak-count champion. No tweak without a purpose.
- Automatic application of everything eligible. Nothing applies without explicit selection and consent.
- Disguising functionality removal as performance optimization.
- Any performance claim without owner-supplied benchmark evidence.

## 2. High-level architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  NEXTRIX authoring side (this repository)                               │
│                                                                         │
│  registry/NX01..NX20.json ──► tools/Test-NxRegistry.ps1                │
│  (single source of truth:      (schema, duplicate IDs/targets,          │
│   30-field tweak metadata)      dependency cycles, conflicts,           │
│                                build ranges, rollback declarations)    │
│              │                                                          │
│              ▼                                                          │
│  tools/Invoke-NxBuild.ps1 ──► playbook/ (AME Wizard playbook source:   │
│  (generate + verify)          modular features per category,           │
│                                conditional actions, declared builds)    │
│              │                                                          │
│              ▼                                                          │
│  playbook/ + src/nxcore/ + testing/  ──► packaged .apbx release         │
└─────────────────────────────────────────────────────────────────────────┘
              │  (owner installs via AME Wizard on target machine)
              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Target machine runtime                                                  │
│                                                                          │
│  AME Wizard ── runs playbook features ── each feature:                   │
│    1. NXCore hardware/build/compatibility check (graceful skip + reason) │
│    2. NXCore state capture  ──► State Journal (exact original state)    │
│    3. Apply (registry / service / task / power / AppX action)            │
│    4. NXCore verification ──► journal updated (result, verification)     │
│                                                                          │
│  NXJournal (JSONL, append-only) + NXRollback engine:                     │
│    tweak / category / profile / full rollback scopes                     │
│                                                                          │
│  NXSession (NX18 companion, user-optional): temporary gaming configs    │
│    with session journal + crash/interruption recovery                     │
└─────────────────────────────────────────────────────────────────────────┘
```

**Design principle:** the AME Wizard playbook is the *delivery vehicle and user-selection surface*; NEXTRIX's own registry is the *source of truth*; NXCore bundled PowerShell is the *state, detection and verification brain* invoked by playbook actions. This keeps the playbook schema-simple and modular while carrying the differentiators the directive mandates (journaling, hardware awareness, conflict resolution, evidence metadata).

## 3. Component specifications

### 3.1 Tweak registry (single source of truth)

- One structured file per category: `registry/NX01.json` … `registry/NX20.json`.
- Every entry carries the 30-field metadata set from the master directive (ID, name, category, subcategory, description, objective, technical explanation, modification type, default state, proposed state, risk class, evidence class, profiles, workloads, required/excluded hardware, edition/build compatibility, dependencies, conflicts, privileges, restart, apply, verify, rollback, original-state method, side effects, approval requirements, documentation source, implementation status — plus registry version).
- Stable IDs `NXcc-nnn`; IDs never change even when names/categories move (renames keep the old ID with a redirect note).

### 3.2 Validation tooling (`tools/Test-NxRegistry.ps1`)

Native PowerShell, no external dependencies. Fails the build on:

1. Duplicate IDs anywhere; duplicate *modification targets* (same registry path+value, same service, same task) under different tweak names — the anti-tweak-inflation gate.
2. Missing or cyclic dependencies; undeclared conflicts (target overlap detected mechanically).
3. Build ranges outside ADR-003 scope; missing rollback declarations; missing verification procedure.
4. Registry entries referencing hardware capabilities that the detection schema cannot express.
5. Entries disabling any service/startup on the **never-touch list** (update stack, audio, security health, profile/state services, Store, networking core) — hard error (UltraOS validator pattern, `r4-synergy-ultraos.md`).
6. Entries matching the **reference-derived negative-results ledger** (e.g. RAM-blind global svchost-split forcing, blanket Enum power zeroing) — regression-tested anti-patterns (see `KNOWN_ISSUES.md`).

### 3.3 Playbook build (`tools/Invoke-NxBuild.ps1`)

Generates AME Wizard playbook source from the registry (modular per-category feature files, shared logic separated per directive Section 12), declares supported builds, and enforces the Section 15 preset exclusions **mechanically**: any tweak flagged `presetExcluded: true` cannot be emitted into a preset feature group — it can only exist as an individually selected, explained, consent-gated feature. Schema specifics of generation are pending R6 platform research (PD-2).

### 3.4 NXCore runtime helpers (`src/nxcore/`, bundled)

| Module | Responsibility |
|---|---|
| `NxHardware` | Hardware report: CPU (vendor, topology, hybrid P/E, SMT, CCD where exposed), GPU (vendor/model/driver), RAM, storage (SSD/HDD/NVMe), chassis class, power source. Uncertain or unavailable values are explicitly marked, never fabricated. |
| `NxBuild` | Edition, version, build, UBR, architecture, Insider detection; **capability checks** (registry path/policy availability, service/component existence, expected value types) — the primary applicability gate per directive Section 10. |
| `NxCompat` | Per-tweak eligibility evaluation → apply / skip-with-reason / conflict warnings, fed to the selection surface. |
| `NxJournal` | State journal writer/reader (below). |
| `NxVerify` | Post-apply verification (does the configuration now hold the intended state?) — configuration verification only, never performance claims. |
| `NxRollback` | Rollback engine: tweak/category/profile/full scopes, per-type restoration rules, verification of restoration. |
| `NxSession` | NX18 Game Session Manager companion (§7). |

All helpers: strict error handling, idempotent operations, meaningful exit codes, no external downloads, no hidden execution.

### 3.5 State journal (mandatory architecture element)

- Storage: `%ProgramData%\NEXTRIX\Journal\` (target machine), JSONL, append-only, entries sequenced and integrity-checksummed; ACL-tightened; contains **no secrets** — only configuration states and results.
- Per application of a tweak, one journal record: tweak ID + version, timestamp, user approval evidence, original state, modified state, application result, verification result, rollback status, error info.
- Original-state capture is *per modification type*:
  - **Registry:** key path, value name, type, original value, value-existed flag, key-existed flag.
  - **Services:** startup type, running state, config, dependency info where relevant.
  - **Scheduled tasks:** path, enabled state, registration info where relevant.
  - **Power:** original active scheme GUID + values, **AC and DC separately**.
  - **AppX removal:** package identity, user scope, provisioned state, restoration capability — with **honest reversibility labeling** (Store-reinstallable vs media-requiring; never claimed "fully reversible" when it is not).
- Rollback restores the *actual recorded original state*, never a guessed Windows default.
- **Restore is conditional (only-if-ours semantics):** a value is restored only if its current state still equals the journal-recorded modified state; a divergence (user or third-party change after apply) is flagged for explicit user resolution, never silently clobbered — a pattern validated independently by XOS (`r1`), FSOS-X (`r1`) and WinUtil's conditional service undo (`r5`).
- **Capture refuses dirty state:** journal initialization never treats an already-NEXTRIX-tweaked configuration as "original" (stacking detection, XOS `StockValueCapture` pattern); a verified full restore re-arms capture. Destructive steps refuse to run unless capture is Complete.
- Journal supports four scopes: individual tweak, category, profile, full NEXTRIX rollback.

### 3.6 Apply pipeline (every modification, no exceptions)

1. Identify target configuration → 2. read current state → 3. record exact original value → 4. record type → 5. record value existence → 6. record key existence → 7. persist to journal → 8. apply → 9. verify → 10. update journal. A step failure produces a clear failure message and a safe stop/skip — never a silent continue.

### 3.7 Dependency and conflict resolution

- Declared in the registry, validated at build, evaluated at runtime by `NxCompat`.
- Conflict classes: target overlap, semantic opposition, profile-policy violation (e.g. Streamer profile vs background-recording removal), security policy (Section 15 list), hardware mismatch.
- Resolution order: identify → explain why → exclude incompatible recommendations → ask for explicit resolution when needed → **never silently override a user-selected requirement**.

### 3.8 Recommendation and selection

- Composable profiles (9, see `PROFILE_MATRIX.md`); one central registry, eligibility computed dynamically — no per-profile duplicate tweaks.
- Every recommendation is emitted with the directive's explanation format (reason, applicability, trade-off, recommendation level, action). Recommendation levels: recommended / conditional-review / advanced-opt-in / troubleshooting-only / excluded-from-presets.
- User flow: pick primary profile → add secondary workloads → declare preserved features → review eligible tweaks with explanations → select individually → dry-run plan → apply → export/import/compare configurations.

### 3.9 Safety architecture

- Section 15 exclusion list enforced in the build (§3.3).
- Consent gates: security reductions, BCD edits, driver-store operations, AppX removals, service changes each require explicit per-item approval and are journal-stamped with the approval.
- Pre-flight (NX16) ritual: restore point + targeted registry/service/task backups before the first mutation of a run.
- Journal-first: no mutation without a preceding journal record.

## 4. Windows compatibility model

- Build matrix: 22631 / 26100 / 26200 / 26H2-TBD; Insider = experimental.
- **Capability detection is primary**: a tweak applies only when its registry path/policy/service/value-type/component actually exists on the machine; otherwise it skips gracefully with an explanation. Build numbers are recorded context, not proof.
- Never create unsupported keys to make a tweak "appear applied."

## 5. Hardware compatibility model

`NxHardware` emits a hardware report object consumed by `NxCompat`. Rules:

- Vendor-specific GPU sections (NVIDIA/AMD/Intel) gate on detected vendor — NVIDIA settings can never apply to AMD/Intel devices.
- CPU scheduling (NX19) derives logical processor indexes from detected topology — hardcoded core indexes are a build-validation failure.
- Adapter-level network changes are parameterized by the actual adapter instance and preserve original values.
- Laptop profile splits AC/DC everywhere power is touched.
- Unavailable or uncertain data is marked as such — never fabricated.

## 6. Directory layout

```
registry/     NX01.json … NX20.json          (source of truth)
playbook/     generated AME Wizard source    (per-category feature modules)
src/nxcore/   NxHardware, NxBuild, NxCompat, NxJournal, NxVerify, NxRollback, NxSession
tools/        Test-NxRegistry.ps1, Invoke-NxBuild.ps1, dry-run/plan tools
testing/      per-tweak manual validation sheets, owner checklists
docs/         ADRs, working notes
research/     Phase 1 sources + synthesized outputs
```

## 7. NX18 — Game Session Manager (separate subsystem)

A **runtime companion** (installed by the playbook, user-optional, explicit consent for any background component — PD-4), not an install-time action:

- Workflow per directive Section 11: detect game → identify executable/launcher/children → match game profile → check hardware/eligibility → present planned modifications → obtain approval → capture state → apply temporary modifications → monitor → restore on normal or abnormal exit → record session result.
- Its own **session journal** (same schema family, separate file) + boot-time interrupted-session recovery check.
- Safeguards: protected-process classes (anti-cheat, security, launchers, OBS/ShadowPlay/AMD recording, audio, peripherals) are never touched; only user-allowlisted apps/services are managed; no process is terminated merely for consuming CPU/RAM; temporary changes never overwrite unrelated persistent settings.
- CPU Sets and affinity remain separate mechanisms (NX19) with topology-derived indexes.

## 8. Platform facts (Phase 1, confirmed) and residual items

**Confirmed from AME's official documentation (`r6-hone-amewizard.md`, accessed 2026-11-23):**

1. Authoring schema: `playbook.conf` XML + YAML task files; 14 typed actions (`!registryValue`, `!service`, `!scheduledTask`, `!cmd`, `!powerShell`, `!appx`, `!systemPackage`, `!download`, `!software`, `!status`, `!task`, `!run`, `!registryKey`, `!taskKill`); universal per-action parameters (`weight`, `status`, `errorAction: Ignore/Log/Notify/Halt`, `option`/`options`, `builds` with revision precision, `cpuArch`, `onUpgrade`, `iso`, `oobe`); feature pages (Checkbox/Radio/RadioImage with `DependsOn`, `IsRequired`); 12 requirement gates; `UpgradableFrom`/upgrade semantics; Git-release update channel (tag = version, one `.apbx` per release).
2. **Rollback: the platform guarantees nothing.** No standardized uninstall exists in v0.8.4; Privacy+ removal requires an ISO-based in-place upgrade; "universal reversibility" is pre-1.0 future work. → Division of labor is fixed by ADR-006: NxJournal/NxRollback carries 100% of rollback; the wizard is apply-and-select only.
3. Trust posture: unsigned beta; Defender exclusions documented as required; `.apbx` fixed-password encryption documented as AV-evasion; verification discretionary and lost on modification. → Disclosed to users; NEXTRIX artifacts hash-pinned; no bundled binaries.
4. Wizard version at access: AME Beta v0.8.4 (146 MB). Pinned for testing; docs changelog tracked for schema drift.

**Residual unknowns:** wizard EULA text is not published online (PD-2 residual); 24H2 (26100) is a reference-divergent build (skipped by XOS, supported by four others) → extra capability checks on 24H2-targeted tweaks; UltraOS's `research/ame-wizard-format-spec.md` (42 KB community spec) and `scripts/ame-dryrun.py` (engine-rule port) are flagged for a follow-up read in Phase 3 to harden the playbook build/dry-run tooling.

**ADR-006 compensations bind all Phase 3+ engineering** (see `DECISIONS.md`): journal-only rollback, `UseKernelDriver: false`, zero security-neutralization requirements, disclosed trust posture, pinned wizard version, hash-pinned artifacts.

## 9. Phase gates

- **Phase 3 (Foundation)** starts only after: owner approves this architecture + catalogue reconciled with research + R6 platform facts known.
- **Phase 4 (Implementation)** proceeds category by category, priority order: NX01, NX02, NX09, NX04, NX16, then the rest; advanced/experimental tweaks stay isolated.
- **Phase 5 (NX18)** after core categories are owner-validated.
- Every implemented tweak ships with: definition, apply, rollback, state preservation, compatibility checks, verification, manual test sheet. Statuses on the ladder in `TWEAK_CLASSIFICATION.md`; owner is the only promoter beyond configuration-validated.
