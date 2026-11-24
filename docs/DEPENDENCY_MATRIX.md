# NEXTRIX - Dependency Matrix

**Status:** generated artifact - do not edit by hand.
**Generator:** `tools/Export-NxMatrices.ps1`
**Source of truth:** `registry/NX*.json` (20 category files, 282 entries) and `registry/schema.json`.
**Regenerate:** `powershell.exe -NoProfile -File tools\Export-NxMatrices.ps1` (or `pwsh`).
**Determinism:** ordinal sorts, no timestamps, UTF-8 without BOM, LF line endings.

| Metric | Value |
|---|---|
| Registry entries | 282 |
| Entries declaring dependencies | 75 |
| Dependency edges | 110 |
| Entries that others depend on | 48 |
| Rows in section 3 (has dependencies and/or dependents) | 116 |
| Entries with an engine function action | 239 |
| Distinct applied engine functions | 200 |
| Applied functions resolved to a src module | 196 |
| Applied functions not found in src at export time | 4 |
| Topological layers | 4 |
| Dependency cycles | 0 (hard check below) |

## 1. Legend

**Risk classes** (`registry/schema.json` `riskClasses`, definitions from `TWEAK_CLASSIFICATION.md`):

| Class | Meaning | Preset behavior |
|---|---|---|
| CORE | Low-risk, well-understood, journal-reversible, no functional sacrifice | Default-on candidate in matching profiles (still deselectable) |
| CONDITIONAL | Valid for a workload/hardware/preference with a stated trade-off | Offered, never auto-applied |
| ADVANCED | Higher blast radius or multi-factor compatibility | Opt-in only; preset-excluded or ExplicitConsent |
| EXPERIMENTAL | Uncertain/hardware-dependent, weak generalization | Never in presets; explicit warnings |
| TROUBLESHOOTING | Targets a named symptom, not general performance | Never in presets; symptom-only |

**Evidence levels** (`TWEAK_CLASSIFICATION.md`): E0 unverified community configuration; E1 documented Windows/vendor behavior; E2 evaluated on one owner machine; E3 evaluated on multiple machines; E4 independently reproducible. Registry assignments start at E0/E1 only.

**Dependency semantics:** the playbook (and a rollback replay) must satisfy a dependency before the dependent entry. A dependency here is a logical prerequisite, not necessarily a value write - see section 4 for engine-function calls that are not expressible as settings.

## 2. Dependency rows

One row per entry that declares dependencies and/or is depended upon. `Depends on` lists ids with names; `Dependents` is the reverse edge set (ids only, sorted). `Notes` are derived from the registry text and the engine inventory; curated engine notes are labelled in section 3.

| Tweak | Name | Risk / Evidence | Depends on | Dependents | Notes |
|---|---|---|---|---|---|
| NX01-015 | Optional features & components management | CORE / E1 | - | NX14-013, NX14-014 | - |
| NX02-010 | Game-specific launch configuration | CONDITIONAL / E0 | NX02-012 Game launcher detection registry | - | - |
| NX02-011 | Game-specific background app handling | CONDITIONAL / E0 | NX02-012 Game launcher detection registry | - | - |
| NX02-012 | Game launcher detection registry | CONDITIONAL / E0 | - | NX02-010, NX02-011 | - |
| NX04-002 | Per-application GPU preference | CONDITIONAL / E1 | NX04-008 Hybrid graphics reporting & app routing | - | - |
| NX04-008 | Hybrid graphics reporting & app routing | CONDITIONAL / E1 | - | NX04-002 | - |
| NX04-009 | NVIDIA power management mode (per-profile) | CONDITIONAL / E1 | - | NX04-016 | - |
| NX04-010 | NVIDIA Low Latency Mode (per-profile) | CONDITIONAL / E1 | - | NX04-016 | - |
| NX04-011 | NVIDIA vertical sync mode (per-profile) | CONDITIONAL / E1 | - | NX04-016 | - |
| NX04-012 | NVIDIA Maximum Frame Rate (per-profile) | CONDITIONAL / E1 | - | NX04-016 | - |
| NX04-013 | NVIDIA Threaded Optimization (per-profile) | CONDITIONAL / E1 | - | NX04-016 | - |
| NX04-014 | NVIDIA texture filtering quality (per-profile) | CONDITIONAL / E1 | - | NX04-016 | - |
| NX04-015 | NVIDIA shader cache policy | CONDITIONAL / E0 | - | NX04-016 | - |
| NX04-016 | NVIDIA per-game profile framework | CONDITIONAL / E1 | NX04-009 NVIDIA power management mode (per-profile); NX04-010 NVIDIA Low Latency Mode (per-profile); NX04-011 NVIDIA vertical sync mode (per-profile); NX04-012 NVIDIA Maximum Frame Rate (per-profile); NX04-013 NVIDIA Threaded Optimization (per-profile); NX04-014 NVIDIA texture filtering quality (per-profile); NX04-015 NVIDIA shader cache policy | - | - |
| NX04-017 | AMD Radeon Anti-Lag (per-profile) | CONDITIONAL / E1 | - | NX04-022 | - |
| NX04-018 | AMD Radeon Chill (per-profile) | CONDITIONAL / E1 | - | NX04-022 | - |
| NX04-019 | AMD Enhanced Sync (per-profile) | CONDITIONAL / E1 | - | NX04-022 | - |
| NX04-020 | AMD Wait for Vertical Refresh (per-profile) | CONDITIONAL / E1 | - | NX04-022 | - |
| NX04-021 | AMD Surface Format Optimization | CONDITIONAL / E0 | - | NX04-022 | - |
| NX04-022 | AMD per-game profile framework + shader cache | CONDITIONAL / E0 | NX04-017 AMD Radeon Anti-Lag (per-profile); NX04-018 AMD Radeon Chill (per-profile); NX04-019 AMD Enhanced Sync (per-profile); NX04-020 AMD Wait for Vertical Refresh (per-profile); NX04-021 AMD Surface Format Optimization | - | - |
| NX05-005 | Memory pressure & commit monitoring report | CORE / E1 | - | NX05-011 | - |
| NX05-006 | Standby memory diagnostic report | CORE / E1 | - | NX05-011 | - |
| NX05-011 | Memory diagnostics suite | CORE / E1 | NX05-005 Memory pressure & commit monitoring report; NX05-006 Standby memory diagnostic report | - | - |
| NX07-001 | Adapter inventory & capability report | CORE / E1 | - | NX07-003, NX07-004, NX07-005, NX07-006, NX07-007, NX07-008, NX07-009, NX07-010, NX07-011, NX07-012, NX07-013, NX07-014, NX07-015 | - |
| NX07-003 | Energy Efficient Ethernet | ADVANCED / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX07-004 | Interrupt moderation | ADVANCED / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX07-005 | Receive Side Scaling configuration | ADVANCED / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX07-006 | Receive Segment Coalescing | ADVANCED / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX07-007 | Large Send Offload | ADVANCED / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX07-008 | Checksum offloads (TCP/UDP) | ADVANCED / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX07-009 | Flow Control | ADVANCED / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX07-010 | Jumbo Frames | ADVANCED / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX07-011 | Receive/Transmit buffer sizing | ADVANCED / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX07-012 | Wi-Fi roaming aggressiveness | CONDITIONAL / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX07-013 | Wi-Fi preferred band | CONDITIONAL / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX07-014 | Wi-Fi channel width | ADVANCED / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX07-015 | Wi-Fi transmit power | CONDITIONAL / E1 | NX07-001 Adapter inventory & capability report | - | - |
| NX09-001 | Active power plan selection | CONDITIONAL / E1 | - | NX18-005 | - |
| NX11-005 | Scheduled task inventory report | CORE / E1 | - | NX11-006 | - |
| NX11-006 | Selective scheduled task management | CONDITIONAL / E0 | NX11-005 Scheduled task inventory report | - | - |
| NX11-008 | Windows Search service configuration | CONDITIONAL / E1 | NX11-019 Service dependency inspection engine | - | - |
| NX11-009 | SysMain service configuration | CONDITIONAL / E1 | NX11-019 Service dependency inspection engine | - | - |
| NX11-010 | Xbox services configuration | CONDITIONAL / E1 | NX11-019 Service dependency inspection engine | - | - |
| NX11-012 | Bluetooth service configuration | CONDITIONAL / E1 | NX11-019 Service dependency inspection engine | - | - |
| NX11-013 | Fax service configuration | CONDITIONAL / E1 | NX11-019 Service dependency inspection engine | - | - |
| NX11-014 | Remote Registry configuration | CONDITIONAL / E1 | NX11-019 Service dependency inspection engine | - | - |
| NX11-016 | Maps-related services configuration | CONDITIONAL / E0 | NX11-019 Service dependency inspection engine | - | - |
| NX11-017 | DiagTrack (Connected User Experiences) configuration | CONDITIONAL / E0 | NX11-019 Service dependency inspection engine | - | - |
| NX11-018 | Third-party service inventory & selective configuration | CONDITIONAL / E1 | NX11-019 Service dependency inspection engine | - | - |
| NX11-019 | Service dependency inspection engine | CORE / E1 | - | NX11-008, NX11-009, NX11-010, NX11-012, NX11-013, NX11-014, NX11-016, NX11-017, NX11-018 | - |
| NX12-001 | Consumer app inventory & selective removal | CONDITIONAL / E1 | NX12-002 Protected-dependency guard; NX12-014 AppX dependency graph verification engine | - | - |
| NX12-002 | Protected-dependency guard | CORE / E1 | - | NX12-001, NX12-003, NX12-004, NX12-005, NX12-006, NX12-007, NX12-009, NX12-012, NX12-013 | - |
| NX12-003 | OEM/promotional third-party app removal | CONDITIONAL / E1 | NX12-002 Protected-dependency guard; NX12-014 AppX dependency graph verification engine | - | - |
| NX12-004 | Phone Link removal (optional) | CONDITIONAL / E1 | NX12-002 Protected-dependency guard; NX12-014 AppX dependency graph verification engine | - | - |
| NX12-005 | Xbox app removal (optional) | CONDITIONAL / E1 | NX12-002 Protected-dependency guard; NX12-014 AppX dependency graph verification engine | - | - |
| NX12-006 | Copilot / AI feature configuration | CONDITIONAL / E0 | NX12-002 Protected-dependency guard; NX12-014 AppX dependency graph verification engine | - | - |
| NX12-007 | Communication apps optional removal | CONDITIONAL / E1 | NX12-002 Protected-dependency guard; NX12-014 AppX dependency graph verification engine | - | - |
| NX12-009 | Provisioned package removal control | CONDITIONAL / E1 | NX12-002 Protected-dependency guard; NX12-014 AppX dependency graph verification engine | - | - |
| NX12-010 | Removal history & reversibility ledger | CORE / E1 | - | NX12-011 | - |
| NX12-011 | Reinstallation helper (Store-based) | CORE / E1 | NX12-010 Removal history & reversibility ledger | - | - |
| NX12-012 | Windows capabilities selective removal | CONDITIONAL / E1 | NX12-002 Protected-dependency guard; NX12-014 AppX dependency graph verification engine | - | - |
| NX12-013 | New-user app provisioning policy | CONDITIONAL / E1 | NX12-002 Protected-dependency guard; NX12-014 AppX dependency graph verification engine | - | - |
| NX12-014 | AppX dependency graph verification engine | CORE / E1 | - | NX12-001, NX12-003, NX12-004, NX12-005, NX12-006, NX12-007, NX12-009, NX12-012, NX12-013 | - |
| NX14-001 | Defender status & health report | CORE / E1 | - | NX14-010, NX14-015 | - |
| NX14-002 | Firewall status & profile report | CORE / E1 | - | NX14-015 | - |
| NX14-005 | Secure Boot status report | CORE / E1 | - | NX14-015 | - |
| NX14-006 | TPM status report | CORE / E1 | - | NX14-012, NX14-015 | - |
| NX14-007 | VBS / HVCI status report | CORE / E1 | - | NX14-008, NX14-009, NX14-015 | - |
| NX14-008 | Memory Integrity consent-gated configuration | ADVANCED / E1 | NX14-007 VBS / HVCI status report | - | - |
| NX14-009 | Credential Guard status report | CORE / E1 | NX14-007 VBS / HVCI status report | NX14-015 | - |
| NX14-010 | Controlled Folder Access configuration | CONDITIONAL / E1 | NX14-001 Defender status & health report | NX14-015 | - |
| NX14-012 | BitLocker status report | CORE / E1 | NX14-006 TPM status report | NX14-015 | - |
| NX14-013 | Windows Sandbox provisioning | CONDITIONAL / E1 | NX01-015 Optional features & components management | - | engine call: Set-NxOptionalFeatureState (NX01-015); cross-category dependency: NX01-015 (NX01) |
| NX14-014 | Hyper-V / virtualization platform configuration | ADVANCED / E1 | NX01-015 Optional features & components management | - | cross-category dependency: NX01-015 (NX01) |
| NX14-015 | Windows Security health aggregate report | CORE / E1 | NX14-001 Defender status & health report; NX14-002 Firewall status & profile report; NX14-005 Secure Boot status report; NX14-006 TPM status report; NX14-007 VBS / HVCI status report; NX14-009 Credential Guard status report; NX14-010 Controlled Folder Access configuration; NX14-012 BitLocker status report | - | - |
| NX16-001 | System Restore enablement & configuration | CORE / E1 | - | NX16-002 | - |
| NX16-002 | Pre-change restore point creation ritual | CORE / E1 | NX16-001 System Restore enablement & configuration | NX16-004 | - |
| NX16-003 | Targeted registry backup | CORE / E1 | - | NX16-004 | - |
| NX16-004 | Pre-flight original-state snapshot bundle | CORE / E1 | NX16-002 Pre-change restore point creation ritual; NX16-003 Targeted registry backup; NX16-005 Service configuration backup; NX16-006 Scheduled task backup | - | - |
| NX16-005 | Service configuration backup | CORE / E1 | - | NX16-004 | - |
| NX16-006 | Scheduled task backup | CORE / E1 | - | NX16-004 | - |
| NX16-010 | Driver inventory & history report | CORE / E1 | - | NX16-011, NX20-008 | - |
| NX16-011 | Driver Store selective cleanup | ADVANCED / E1 | NX16-010 Driver inventory & history report | - | - |
| NX16-012 | Windows build & UBR verification report | CORE / E1 | - | NX16-017 | - |
| NX16-013 | Individual tweak rollback | CORE / E1 | - | NX16-014, NX16-015, NX16-016 | - |
| NX16-014 | Category rollback | CORE / E1 | NX16-013 Individual tweak rollback | - | - |
| NX16-015 | Profile rollback | CORE / E1 | NX16-013 Individual tweak rollback | - | - |
| NX16-016 | Full NEXTRIX rollback | CORE / E1 | NX16-013 Individual tweak rollback | - | - |
| NX16-017 | Owner support-bundle export | CORE / E0 | NX16-012 Windows build & UBR verification report | - | engine call: Get-NxBuildReport (NX16-012) |
| NX18-001 | Running game detection engine | CONDITIONAL / E0 | - | NX18-002, NX18-004, NX18-009 | engine module outside src/nxcore: Get-Nx18Capability (src/nxsession/NX18.ps1) |
| NX18-002 | Launcher & child-process relationship mapping | CONDITIONAL / E0 | NX18-001 Running game detection engine | - | engine module outside src/nxcore: Get-Nx18Capability (src/nxsession/NX18.ps1) |
| NX18-003 | Game-specific session profiles | CONDITIONAL / E0 | - | NX18-006, NX18-007, NX18-008, NX18-010 | engine module outside src/nxcore: Get-Nx18Capability (src/nxsession/NX18.ps1) |
| NX18-004 | Session CPU Sets application | ADVANCED / E0 | NX18-001 Running game detection engine; NX19-002 CPU Set derivation engine; NX19-003 Per-process CPU Set application | - | engine module outside src/nxcore: Get-Nx18Capability (src/nxsession/NX18.ps1); engine call: New-NxCpuSetPlan (NX19-002); cross-category dependency: NX19-002 (NX19); wave-order inversion: playbook wave order emits NX19-002 (NX19) after NX18; engine call: Set-NxProcessCpuSets (NX19-003); cross-category dependency: NX19-003 (NX19); wave-order inversion: playbook wave order emits NX19-003 (NX19) after NX18 |
| NX18-005 | Session power plan switching | CONDITIONAL / E1 | NX09-001 Active power plan selection | - | engine module outside src/nxcore: Get-Nx18Capability (src/nxsession/NX18.ps1); engine call: Set-NxActivePowerPlan (NX09-001); cross-category dependency: NX09-001 (NX09) |
| NX18-006 | Session background app management | CONDITIONAL / E0 | NX18-003 Game-specific session profiles; NX19-002 CPU Set derivation engine; NX19-005 Per-process priority policy | - | engine module outside src/nxcore: Get-Nx18Capability (src/nxsession/NX18.ps1); cross-category dependency: NX19-002 (NX19); wave-order inversion: playbook wave order emits NX19-002 (NX19) after NX18; engine call: Set-NxProcessPriority (NX19-005); cross-category dependency: NX19-005 (NX19); wave-order inversion: playbook wave order emits NX19-005 (NX19) after NX18 |
| NX18-007 | Session service suspension (allowlisted) | ADVANCED / E0 | NX18-003 Game-specific session profiles | - | engine module outside src/nxcore: Get-Nx18Capability (src/nxsession/NX18.ps1) |
| NX18-008 | Session graphics configuration | CONDITIONAL / E0 | NX18-003 Game-specific session profiles | - | engine module outside src/nxcore: Get-Nx18Capability (src/nxsession/NX18.ps1) |
| NX18-009 | Session process priority configuration | CONDITIONAL / E1 | NX18-001 Running game detection engine; NX19-005 Per-process priority policy | - | engine module outside src/nxcore: Get-Nx18Capability (src/nxsession/NX18.ps1); engine call: Set-NxProcessPriority (NX19-005); cross-category dependency: NX19-005 (NX19); wave-order inversion: playbook wave order emits NX19-005 (NX19) after NX18 |
| NX18-010 | Session journal & crash/interruption recovery | CORE / E0 | NX18-003 Game-specific session profiles | NX18-011 | engine module outside src/nxcore: Get-Nx18Capability (src/nxsession/NX18.ps1) |
| NX18-011 | Manual session control | CORE / E0 | NX18-010 Session journal & crash/interruption recovery | - | engine module outside src/nxcore: Get-Nx18Capability (src/nxsession/NX18.ps1) |
| NX19-001 | CPU topology detection & report engine | CORE / E1 | - | NX19-002, NX19-011 | - |
| NX19-002 | CPU Set derivation engine | CORE / E1 | NX19-001 CPU topology detection & report engine | NX18-004, NX18-006, NX19-003, NX19-004, NX19-006, NX19-007, NX19-008, NX19-009, NX19-010 | - |
| NX19-003 | Per-process CPU Set application | ADVANCED / E0 | NX19-002 CPU Set derivation engine | NX18-004 | - |
| NX19-004 | Per-process affinity application | ADVANCED / E1 | NX19-002 CPU Set derivation engine | - | - |
| NX19-005 | Per-process priority policy | CONDITIONAL / E1 | - | NX18-006, NX18-009 | - |
| NX19-006 | Scheduling profile: Competitive | CONDITIONAL / E0 | NX19-002 CPU Set derivation engine | - | - |
| NX19-007 | Scheduling profile: Balanced gaming | CONDITIONAL / E0 | NX19-002 CPU Set derivation engine | - | - |
| NX19-008 | Scheduling profile: Streaming | CONDITIONAL / E0 | NX19-002 CPU Set derivation engine | - | - |
| NX19-009 | Scheduling profile: Productivity | CONDITIONAL / E0 | NX19-002 CPU Set derivation engine | - | engine call: New-NxCpuSetPlan (NX19-002) |
| NX19-010 | Scheduling profile: Custom builder | CONDITIONAL / E0 | NX19-002 CPU Set derivation engine | - | - |
| NX19-011 | AMD X3D / CCD-aware placement guidance | EXPERIMENTAL / E0 | NX19-001 CPU topology detection & report engine | - | - |
| NX20-002 | GPU vendor & driver capability report | CORE / E1 | - | NX20-003, NX20-004, NX20-005 | - |
| NX20-003 | NVIDIA driver management (inventory, guidance, profile inspection) | CONDITIONAL / E1 | NX20-002 GPU vendor & driver capability report | - | - |
| NX20-004 | AMD driver management (equivalent) | CONDITIONAL / E1 | NX20-002 GPU vendor & driver capability report | - | - |
| NX20-005 | Intel driver management (equivalent) | CONDITIONAL / E1 | NX20-002 GPU vendor & driver capability report | - | - |
| NX20-008 | Installed driver history report | CORE / E1 | NX16-010 Driver inventory & history report | - | engine call: Get-NxDriverInventory (NX16-010); cross-category dependency: NX16-010 (NX16) |

## 3. Engine-function dependencies

### 3.1 Entries whose engine module lives outside `src/nxcore` (mechanical)

Grouped by defining module; the packaging consequence is identical for every entry in a group.

| Entries | Applied function | Defining module | Packaging consequence |
|---|---|---|---|
| NX18-001, NX18-002, NX18-003, NX18-004, NX18-005, NX18-006, NX18-007, NX18-008, NX18-009, NX18-010, NX18-011, NX18-012 | Get-Nx18Capability | `src/nxsession/NX18.ps1` | Bundled by `tools/New-NxPackage.ps1`; NOT inventoried by `tools/Invoke-NxBuild.ps1` (KNOWN_ISSUES 16), so the manifest cannot hash-pin it. |

### 3.2 Cross-category engine calls (CURATED, token-verified)

These calls are documented in the registry text but are not registry dependencies of a setting: the consumer runs an engine function that belongs to, or delegates to, another category's engine. Each row's token is asserted against the owning entry at export time, so the note cannot silently drift. This is the NX18 -> NX19/NX09 dependency family (NX18 is the session subsystem; its CPU-set, priority and power steps call NX19/NX09 engine functions).

| Consumer | Provider / owner | Engine function(s) | Evidence in registry text |
|---|---|---|---|
| NX18-004 | NX19-002 | New-NxCpuSetPlan | `NX18-004` text contains `New-NxCpuSetPlan` |
| NX18-004 | NX19-003 | Set-NxProcessCpuSets | `NX18-004` text contains `Set-NxProcessCpuSets` |
| NX18-005 | NX09-001 | Set-NxActivePowerPlan | `NX18-005` text contains `Set-NxActivePowerPlan` |
| NX18-006 | NX19-005 | Set-NxProcessPriority | `NX18-006` text contains `Set-NxProcessPriority` |
| NX18-006 | NX19-002 | New-NxCpuSetPlan | `NX18-006` text contains `NX19-002` |
| NX18-009 | NX19-005 | Set-NxProcessPriority | `NX18-009` text contains `Set-NxProcessPriority` |
| NX18-008 | (NxApply/NxRollback) | Invoke-NxRegistryTweak / Invoke-NxRollback | `NX18-008` text contains `Invoke-NxRegistryTweak` |
| NX18-010 | (NX19/NX09/NxApply engines) | journal read/restore engines | `NX18-010` text contains `NX19/NX09/NxApply` |
| NX18-011 | (Nx18 session engine) | Start-NxSession -> owning engines | `NX18-011` text contains `All mutation goes through the engines` |

Structural engine wiring (verified by function definition, not an entry-to-entry dependency):

- `NX16-004` applies `Invoke-NxPreFlight`; the generator routes that function to the unconditional `Tasks/nxcore.yml` pre-flight (errorAction Halt) instead of a user option.
- `NX16-013`..`NX16-016` apply `Invoke-NxRollback`; they are CLI-only and deliberately not emitted as wizard options or playbook tasks.
- `NX16-014`/`NX16-015`/`NX16-016` depend on `NX16-013` (journal read/restore primitives). Rollback runs after the apply session, against the journal.

### 3.3 Applied functions not found in `src` at export time

These names are referenced by registry `apply.actions` but no `function <name>` definition was found while scanning `src/**/*.ps1`. Concurrent authoring or a stale registry edge is the usual cause; the generator emits such names by name and the manifest lists them as expected.

| Function | Declared by |
|---|---|
| Invoke-NxGameBackgroundHandling | NX02-011 |
| Invoke-NxGameLaunchConfiguration | NX02-010 |
| Invoke-NxPerGameDriverGraphics | NX02-009 |
| Set-NxSearchIndexingScope | NX01-009 |

## 4. Topological order

Deterministic Kahn order over all 282 entries (dependencies first; ties broken by ordinal id). Flat order below; the 4 layer boundaries are where the ready set advanced. This order is a correctness reference for replay/rollback, not the playbook's wave order (categories are emitted in wave order by `tools/Invoke-NxBuild.ps1`; cross-category inversions are flagged in section 2).

```text
  1. NX01-001
  2. NX01-002
  3. NX01-003
  4. NX01-004
  5. NX01-005
  6. NX01-006
  7. NX01-007
  8. NX01-008
  9. NX01-009
 10. NX01-010
 11. NX01-011
 12. NX01-012
 13. NX01-013
 14. NX01-014
 15. NX01-015
 16. NX01-016
 17. NX02-001
 18. NX02-002
 19. NX02-003
 20. NX02-004
 21. NX02-005
 22. NX02-006
 23. NX02-007
 24. NX02-008
 25. NX02-009
 26. NX02-012
 27. NX02-010
 28. NX02-011
 29. NX03-001
 30. NX03-002
 31. NX03-003
 32. NX03-004
 33. NX03-005
 34. NX03-006
 35. NX03-007
 36. NX03-008
 37. NX03-009
 38. NX03-010
 39. NX03-011
 40. NX03-012
 41. NX03-013
 42. NX04-001
 43. NX04-003
 44. NX04-004
 45. NX04-005
 46. NX04-006
 47. NX04-007
 48. NX04-008
 49. NX04-002
 50. NX04-009
 51. NX04-010
 52. NX04-011
 53. NX04-012
 54. NX04-013
 55. NX04-014
 56. NX04-015
 57. NX04-016
 58. NX04-017
 59. NX04-018
 60. NX04-019
 61. NX04-020
 62. NX04-021
 63. NX04-022
 64. NX04-023
 65. NX05-001
 66. NX05-002
 67. NX05-003
 68. NX05-004
 69. NX05-005
 70. NX05-006
 71. NX05-007
 72. NX05-008
 73. NX05-009
 74. NX05-010
 75. NX05-011
 76. NX06-001
 77. NX06-002
 78. NX06-003
 79. NX06-004
 80. NX06-005
 81. NX06-006
 82. NX06-007
 83. NX06-008
 84. NX06-009
 85. NX06-010
 86. NX06-011
 87. NX06-012
 88. NX06-013
 89. NX07-001
 90. NX07-002
 91. NX07-003
 92. NX07-004
 93. NX07-005
 94. NX07-006
 95. NX07-007
 96. NX07-008
 97. NX07-009
 98. NX07-010
 99. NX07-011
100. NX07-012
101. NX07-013
102. NX07-014
103. NX07-015
104. NX07-016
105. NX07-017
106. NX07-018
107. NX07-019
108. NX07-020
109. NX07-021
110. NX07-022
111. NX08-001
112. NX08-002
113. NX08-003
114. NX08-004
115. NX08-005
116. NX08-006
117. NX08-007
118. NX08-008
119. NX09-001
120. NX09-002
121. NX09-003
122. NX09-004
123. NX09-005
124. NX09-006
125. NX09-007
126. NX09-008
127. NX09-009
128. NX09-010
129. NX09-011
130. NX09-012
131. NX09-013
132. NX09-014
133. NX09-015
134. NX10-001
135. NX10-002
136. NX10-003
137. NX10-004
138. NX10-005
139. NX10-006
140. NX10-007
141. NX10-008
142. NX11-001
143. NX11-002
144. NX11-003
145. NX11-004
146. NX11-005
147. NX11-006
148. NX11-007
149. NX11-011
150. NX11-015
151. NX11-019
152. NX11-008
153. NX11-009
154. NX11-010
155. NX11-012
156. NX11-013
157. NX11-014
158. NX11-016
159. NX11-017
160. NX11-018
161. NX12-002
162. NX12-008
163. NX12-010
164. NX12-011
165. NX12-014
166. NX12-001
167. NX12-003
168. NX12-004
169. NX12-005
170. NX12-006
171. NX12-007
172. NX12-009
173. NX12-012
174. NX12-013
175. NX13-001
176. NX13-002
177. NX13-003
178. NX13-004
179. NX13-005
180. NX13-006
181. NX13-007
182. NX13-008
183. NX13-009
184. NX13-010
185. NX13-011
186. NX13-012
187. NX13-013
188. NX13-014
189. NX14-001
190. NX14-002
191. NX14-003
192. NX14-004
193. NX14-005
194. NX14-006
195. NX14-007
196. NX14-008
197. NX14-009
198. NX14-010
199. NX14-011
200. NX14-012
201. NX14-013
202. NX14-014
203. NX14-015
204. NX15-001
205. NX15-002
206. NX15-003
207. NX15-004
208. NX15-005
209. NX15-006
210. NX15-007
211. NX15-008
212. NX15-009
213. NX15-010
214. NX15-011
215. NX15-012
216. NX15-013
217. NX15-014
218. NX16-001
219. NX16-002
220. NX16-003
221. NX16-005
222. NX16-006
223. NX16-004
224. NX16-007
225. NX16-008
226. NX16-009
227. NX16-010
228. NX16-011
229. NX16-012
230. NX16-013
231. NX16-014
232. NX16-015
233. NX16-016
234. NX16-017
235. NX17-001
236. NX17-002
237. NX17-003
238. NX17-004
239. NX17-005
240. NX17-006
241. NX17-007
242. NX17-008
243. NX17-009
244. NX17-010
245. NX17-011
246. NX17-012
247. NX17-013
248. NX17-014
249. NX18-001
250. NX18-002
251. NX18-003
252. NX18-005
253. NX18-007
254. NX18-008
255. NX18-010
256. NX18-011
257. NX18-012
258. NX19-001
259. NX19-002
260. NX19-003
261. NX18-004
262. NX19-004
263. NX19-005
264. NX18-006
265. NX18-009
266. NX19-006
267. NX19-007
268. NX19-008
269. NX19-009
270. NX19-010
271. NX19-011
272. NX20-001
273. NX20-002
274. NX20-003
275. NX20-004
276. NX20-005
277. NX20-006
278. NX20-007
279. NX20-008
280. NX20-009
281. NX20-010
282. NX20-011
```

## 5. Cycle check

PASS: every dependency edge resolves to a registry entry and the Kahn ordering emitted all entries, so there is no dependency cycle. The exporter fails with exit code 1 and writes no matrix if a cycle, self-dependency or missing dependency id is detected.

## 6. Export-time warnings

None.

---

Generated by `tools/Export-NxMatrices.ps1`. Repository source of truth: `registry/`.
