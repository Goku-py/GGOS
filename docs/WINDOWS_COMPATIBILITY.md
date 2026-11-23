# NEXTRIX — Windows Compatibility

**Status:** Phase 6 deliverable (Wave 5, W5-C) · written 2026-11-23.
**Scope:** which Windows 11 builds, editions and capabilities NEXTRIX targets; how it detects them; what it does on machines it does not support.
**Companion document:** `HARDWARE_COMPATIBILITY.md` (CPU/GPU/RAM/storage/chassis gates).

**Evidence key**

| Tag | Meaning |
|---|---|
| `[REG]` | Field in `registry/NX*.json` |
| `[CODE]` | `src/nxcore/*.ps1`, `tools/*.ps1`, generated `playbook/` |
| `[RES]` | `COMPATIBILITY_RESEARCH.md`, `PROJECT_RESEARCH.md`, `TWEAK_RESEARCH.md` |
| `[ADR]` | `DECISIONS.md` |
| `[DOC]` | `KNOWN_ISSUES.md`, `SECURITY_POLICY.md`, `TWEAK_CLASSIFICATION.md`, `PROFILE_MATRIX.md` |

**Reading rules**

1. "Supported build" means the playbook targets it and the engine will attempt entries on it. **No NEXTRIX entry has been functionally validated on any build** (`KNOWN_ISSUES.md` A.2–A.5, `TWEAK_CLASSIFICATION.md` §3); 242 entries are `SyntaxValidated`, 40 are `Defined` `[REG]`.
2. No performance claim appears in this document. Functional verification is not performance verification `[DOC] TWEAK_CLASSIFICATION.md §4`.
3. Where the wizard, the engine and the registry do not agree, all three are stated.

---

## 1. Supported builds

| Marketing name | Build | In NEXTRIX scope | Playbook `SupportedBuilds` | Default entry range | Notes |
|---|---|---|---|---|---|
| Windows 11 23H2 | **22631** | Yes | Declared | 22631–26300 | Minimum in scope `[ADR] ADR-003` |
| Windows 11 24H2 | **26100** | Yes, **caution zone** | Declared | 22631–26300 | Reference-divergent build; extra capability checks (§2) |
| Windows 11 25H2 | **26200** | Yes | Declared | 22631–26300 | — |
| Windows 11 26H2 | **26300** | Yes, projection-based | Declared | 22631–26300 (default max) | Build number confirmed by four independent reference projects; **no NEXTRIX tweak validated on it** `[ADR] ADR-003`, `[DOC] KNOWN_ISSUES.md A.5` |
| 26H1 interim | 28000 | **No** | Not declared | — | ARM-only interim per reference code; explicitly unsupported `[RES] §1` |
| 22H2 / beta channels | 22621 / 22635 | **No** | Not declared | — | Below the scope floor / beta channel `[RES] §1` |
| Windows 10 (19044/19045) | — | **No** | Not declared | — | Out of scope `[ADR] ADR-003` |

Grounds for the table: `registry/schema.json:5` (`supportedBuildRange` 22631–26300), `playbook/playbook.conf:36-45` (the four `<string>` entries), `[CODE] NxBuild.ps1:41-45` (marketing map and scope check), `tools/Test-NxRegistry.ps1:62-66` (validator rejects any entry whose range leaves 22631–26300).

**What is *not* checked:** there is **no UBR floor**. `UBR` is read and reported (`NxBuild`), never gated. Sophia's `UBR ≥ 9974` rule was **not** adopted — a hard UBR floor breaks the script as Microsoft ships patches `[RES] §1`, `PROJECT_RESEARCH.md` (Sophia cautions).

**Desk verification, not validation.** Several entries record read-only value-name verification on **build 26300.9974 (2026-11-23)** (e.g. NX01-001, NX15 category note). That establishes the value names exist on that build; it is not functional or performance validation and does not promote an entry's status.

---

## 2. The 24H2 caution zone

| Fact | Consequence in NEXTRIX | Grounds |
|---|---|---|
| 24H2 (26100) is skipped outright by one major reference (XOS) and special-cased by another (Synergy) | 26100 stays in scope but every run on it carries an explicit warning | `[RES] §1`, `[CODE] NxCompat.ps1:32` |
| UCPD protects the per-user `TaskbarDa` value on 24H2+ | The widgets layer **never writes** `TaskbarDa` on 26100+; it writes the documented `AllowNewsAndInterests=0` policy instead | `[CODE] NX15.ps1:163-171`, `[RES] §2.2`, `[REG] NX15-004` |
| Start-menu suggestion families differ between 23H2 and 24H2+ | Per-family capability paths; each family skips independently if absent | `[REG] NX01-004` |
| Copilot availability is build/region/update dependent | Absence is reported (`Skipped-NotFound`), never treated as a failure | `[CODE] NX12.ps1:1279-1287` |
| NX14 tri-state numeric encoding was observed on 26100 | Labelled E0 in output even where the cmdlet is E1-documented; not asserted as a contract | `[CODE] NX14.ps1:1547` |
| Classic context menu behaviour on 24H2+ is unverified | NX15-009 is a read-only report (`buildClass='24H2PlusUnverified'`), mutation unsupported | `[CODE] NX15.ps1:266`, `[REG] NX15-009` |

The rule behind every row: on 26100 the engine assumes **nothing** about a value's presence or writability; it probes, then chooses a documented alternative or skips.

---

## 3. Insider builds and unrecognised builds

| Case | Detected by | Engine behaviour | Wizard behaviour |
|---|---|---|---|
| Insider channel (`BuildLabEx`/`DisplayVersion` matching `insider.`, `.dev.`, `.beta.`) | `[CODE] NxBuild.ps1:46-47` | `insiderChannel=true`; the entry is still evaluated, plus warning `Insider channel: experimental per directive Section 10` | Build not in `SupportedBuilds` → not run (most Insider builds are outside the four strings) |
| Build number in 22631–26300 but not one of the four (e.g. 26120) | `NxBuild` marketing map miss | `marketing='Unclassified'` + uncertainty note; `inSupportedScope` still true, so capability gates decide | Typically refused, because the wizard list is the four marketing builds |
| Build > 26300 (e.g. future 26H2+1) | Scope check | Every entry fails the build gate: `build N above tweak maximum 26300` | Refused (not listed); `AllowUnsupportedUpgrades` is `false` `[CODE] playbook.conf:50` |
| Build < 22631 | Scope check | Every entry fails: `build N below tweak minimum 22631`; NX12-006 returns `Refused-UnsupportedBuild`; NX15 functions return `skipped=true` without writing | Refused (not listed) |
| Build registry unreadable | `CurrentVersion` read failure | `readSucceeded=false`, and **every** entry skips with `build report unavailable (read failed)`; the pre-flight records `build-report Failed` | Pre-flight Halt policy |

The wizard's `SupportedBuilds` list is authoritative at delivery time. The engine's numeric range is deliberately more permissive (it accepts any build in 22631–26300) because it is also used directly by the tooling and tests. A build that the wizard accepts is therefore always one of the four; the engine's permissiveness never widens delivery. The exact platform refusal wording is supplied by AME Wizard and is **not asserted** here.

---

## 4. Capability detection is the primary gate

Directive Section 10 and `[ADR] ADR-003`: a build number never implies a feature exists. `NxCompat` evaluates capability before dependency and risk `[CODE] NxCompat.ps1:67-80`.

### 4.1 Mechanisms in use

| Mechanism | Implementation | Applied to | On failure |
|---|---|---|---|
| Registry **key existence** | `Test-NxRegistryCapability` — `Test-Path` first | Registry action `capabilityPath` | `supported=false`, reason `key missing: <path>`; entry skips |
| Registry **value kind** | `GetValueKind` compared to `ExpectedKind` | Available, **currently unused by the registry** (no entry declares a kind) | Reason `value '…' exists as <kind>, expected <kind> (never overwrite wrong-kind values)` |
| Registry **value absence** | Missing value returns `supported=true` with `value absent (tweak would create it)` | Entries using `RemoveEntry` semantics | Not a skip — a missing value is a valid starting state |
| **Service presence** | `Test-NxServiceCapability` (`Get-Service`) | Declared `service` actions | `service missing: <name>`; skip unless the action declares `SkipGracefully` |
| **Vendor presence** | `Get-NxNvidiaStatus` / `Get-NxAmdStatus` / `Get-NxIntelStatus`, PCI-VID based | NX04 guides, NX20 reports | `VendorHardwareAbsent` |
| **Topology availability** | `Get-NxTopologyReport` | NX19, NX17-007 | `topologyAvailable=false` + reason |
| **UCPD policy fallback** | Build-conditional branch writing the documented policy | NX15-004 widgets, NX15-005 Start | Never attempts the protected per-user value |
| **Text-output parsing** | `powercfg /a`, `/query`, `/list` parsers | NX09, NX06-012 | Parse fails closed: no capture, no mutation |
| **DISM via executable** | `dism.exe` invoked directly | NX16-007/009 | Uncertainty notes instead of cmdlet failure |

Current coverage `[REG]`: **51 of 71** registry actions declare a `capabilityPath` (NX01 10, NX02 11, NX13 20, NX15 10). The remaining 20 write key families that exist on every in-scope build (e.g. `GraphicsDrivers`, `Dwm`, `Session Manager\Memory Management`, `Control Panel\Desktop`) or documented policy keys NEXTRIX intentionally creates (e.g. `Policies\Microsoft\Windows\WindowsUpdate`). The **service-action path in the resolver is currently unused**: all 312 registry actions are `function` (241) or `registry` (71); no entry declares a `service` action, so service presence is enforced inside the NX11 functions instead.

### 4.2 Worked examples from the implementation

**Example A — two build-conditional families behind one entry (NX01-004).**
Each registry action declares its own `capabilityPath`; on a build where the 23H2-era `ContentDeliveryManager` family is absent, that action skips with a reason while the 24H2+ `Start_IrisRecommendations` action proceeds. The entry names KB5089573 as the reason the assumption is unsafe `[REG] NX01-004`.

**Example B — UCPD-protected value with a documented alternative (NX15-004).**
`Set-NxTaskbarConfiguration` writes `TaskbarAl`, `SearchboxTaskbarMode`, `ShowTaskViewButton` normally, then branches: `build ≥ 26100` → policy `HKLM\SOFTWARE\Policies\Microsoft\Dsh :: AllowNewsAndInterests=0`, `widgetsMechanism='DocumentedPolicy'`, `ucpdPolicyFallback=true`; otherwise → per-user `TaskbarDa=0`. The result object reports which mechanism ran `[CODE] NX15.ps1:144-186`.

**Example C — build gate that is narrower than the scope (NX02-005).**
`builds { min: 26100 }` becomes the per-action playbook gate `builds: ['>=26100']` in the generated task file `[CODE] playbook/Configuration/Tasks/nx02.yml:121`, and the resolver skips it below 26100 with `build 22631 below tweak minimum 26100` `[CODE] NxCompat.ps1:26-30`.

**Example D — absence is not failure (NX12-006).**
Copilot not installed → `outcome='Skipped-NotFound'` with a note that availability is build/region/update dependent and the documentation URL; a build below scope → `Refused-UnsupportedBuild` `[CODE] NX12.ps1:1279-1287`.

**Example E — locale-dependent text parse fails closed (NX09).**
The `powercfg` parser targets the documented English output. On a localized system the label is unrecognised, `parseOk=false`, and callers return `Refused` with *"powercfg /query output unparseable (locale/format) … no capture, no mutation"*. NX09-009 (Fast Startup, `HiberbootEnabled`) uses the registry route and is locale-independent `[CODE] NX09.ps1:39-43, 228, 595`.

**Example F — DISM without PowerShell cmdlets (NX16-007/009).**
`dism.exe` is invoked from `%SystemRoot%\System32` with stderr captured as output; elevation and 32-bit-host conditions are reported as uncertainty notes. This sidesteps the documented "MSIX PowerShell 7 breaks DISM cmdlets (`Class not registered`)" failure class by not using the cmdlets at all `[CODE] NX16.ps1:1112-1150`, `[RES] §2.6`, `[DOC] KNOWN_ISSUES.md A.15`.

---

## 5. Edition applicability

### 5.1 Edition differences that are real

| Area | Home | Pro | Enterprise | Education | Evidence |
|---|---|---|---|---|---|
| Diagnostic data floor | `AllowTelemetry=1` | `AllowTelemetry=1` | `AllowTelemetry=0` (Enterprise family) | `AllowTelemetry=0` | Microsoft: value 0 applies only to Enterprise/Education/Server; writing 0 elsewhere equals 1. NX13-004 writes the applicable floor and reports `appliedLevel < requestedLevel` rather than claiming the requested level `[REG] NX13-004` |
| Windows Update policy surface | Documented as ignoring the update-off policy family (XOS r1) | No equivalent Home limitation recorded; not validated | Not validated | Not validated | `[RES] §3` |
| Sandbox / Hyper-V feature availability | No Windows Sandbox (documented Pro/Enterprise/Education prerequisite); the Hyper-V entry is restricted to the same editions | Yes | Yes | Yes | NX14-013 reads edition + firmware virtualization + SLAT and **refuses Enable** on unsupported editions `[REG] NX14-013`, `[REG] NX14-014` |
| Consumer-experience policy | Excluded by the registry (no documented policy surface accepted for Home) | Included | Included | Included | NX01-003 states the CSP edition row is Enterprise/Education/IoT, ADMX present in Pro `[REG] NX01-003` |
| Unknown edition id | Resolves to the conservative telemetry floor 1 with an explicit uncertainty note | — | — | — | `[REG] NX13-004` |

### 5.2 The house rule and how the registry follows it

`[DOC] TWEAK_CLASSIFICATION.md §6`: include Home when the applied layer is an ADMX-backed local policy Windows evaluates on client SKUs (flag enforcement as documentation-limited where Microsoft's CSP editions table omits Home); exclude Home only where the mechanism is CSP/MDM-only with no local policy path.

| Registry pattern | Count | Entries |
|---|---|---|
| All four editions | 275 | — |
| Home excluded | 7 | NX01-003, NX01-011, NX01-012, NX01-013, NX01-014, NX14-013, NX14-014 |

### 5.3 Two honesty gaps in edition handling

1. **Editions are not enforced by the resolver.** `NxCompat.ps1` contains no edition comparison and no `editions` reference; the generated playbook does not gate on edition either. Edition-applicability today is (a) metadata, (b) function-level checks where implemented (NX13-004, NX14-013), (c) the selection tooling that is not built yet (PD-1). A Home machine that selects NX01-003 would receive a policy value with no documented effect on Home. **Flagged for the selection-tooling workstream**; no code was changed by this document.
2. **Four Home exclusions lack a per-entry rationale.** NX01-011/012/013/014 are ADMX-backed policy writes (Delivery Optimization, maintenance wake, active hours, restart notifications) yet exclude Home, and their entries do not state *why* Home is excluded. The exclusion is consistent with the known Home Update-policy limitation, but §6 of `TWEAK_CLASSIFICATION.md` requires each entry to state which layer applies where. **Flagged for registry review.**

---

## 6. Per-category build gates (generated from the registry)

Every entry in every category uses `builds { min: 22631, max: 26300, excluded: [] }` except one.

| Category | Entries | min | max | excluded | Deviating entries |
|---|---|---|---|---|---|
| NX01 Windows Foundation | 16 | 22631 | 26300 | — | none |
| NX02 Gaming & Esports | 12 | 22631 | 26300 | — | **NX02-005** (min 26100) |
| NX03 CPU & Processor | 13 | 22631 | 26300 | — | none |
| NX04 GPU & Graphics | 23 | 22631 | 26300 | — | none |
| NX05 Memory Management | 11 | 22631 | 26300 | — | none |
| NX06 Storage & Filesystem | 13 | 22631 | 26300 | — | none |
| NX07 Network Optimization | 22 | 22631 | 26300 | — | none |
| NX08 Input & Peripherals | 8 | 22631 | 26300 | — | none |
| NX09 Power Management | 15 | 22631 | 26300 | — | none |
| NX10 Thermal Management | 8 | 22631 | 26300 | — | none |
| NX11 Background & Services | 19 | 22631 | 26300 | — | none |
| NX12 Debloating | 14 | 22631 | 26300 | — | none |
| NX13 Privacy & Telemetry | 14 | 22631 | 26300 | — | none |
| NX14 Security Configuration | 15 | 22631 | 26300 | — | none |
| NX15 Visual & Interface | 14 | 22631 | 26300 | — | none |
| NX16 Maintenance & Recovery | 17 | 22631 | 26300 | — | none |
| NX17 Advanced Configuration | 14 | 22631 | 26300 | — | none |
| NX18 Game Session Manager | 12 | 22631 | 26300 | — | none |
| NX19 Topology & Scheduling | 11 | 22631 | 26300 | — | none |
| NX20 Hardware & Driver Mgmt | 11 | 22631 | 26300 | — | none |

Totals: 282 entries · **1** entry with a non-default `min` (NX02-005) · **0** entries with `builds.excluded` non-empty · 0 entries outside 22631–26300 (validator-enforced).

**Known gap:** the resolver honours `builds.min`/`max` but not `builds.excluded`; the generator *does* translate `excluded` into `!<build>` playbook gates `[CODE] Invoke-NxBuild.ps1:133-146`. With zero entries using `excluded`, the gap is currently inert. Flagged for the resolver owner.

**Where the build gate is translated:** `Get-NxAmeBuildsGate` converts `{min,max,excluded}` into the AME per-action `builds` list, so the wizard and the engine both refuse out-of-range entries — the wizard before the action, the engine in step 1 of the apply pipeline.

---

## 7. Version-specific known issues and how NEXTRIX handles them

| Issue | Affects | NEXTRIX behaviour | Grounds |
|---|---|---|---|
| **UCPD protects per-user association/taskbar values on 24H2+**; direct writes fail with Access Denied (non-fatal in one reference's release) | 26100+ | Never fights UCPD. Documented policy alternative for widgets; UCPD itself is never disabled; no `UCPDDisabled` playbook requirement | `[CODE] NX15.ps1:163-171`, `[RES] §2.2, §3`, `[ADR] ADR-006` |
| **KB5089573 (May 2026) removed legacy Start-menu code paths** | 26100+ | Start-related entries rely on per-family capability paths, not build assumptions; absent families skip with a reason | `[REG] NX01-004`, `[RES] §2.5` |
| **MSIX PowerShell 7 breaks DISM cmdlets** ("Class not registered") | tooling context | Engine targets PS 5.1 and shells to `dism.exe`, avoiding the cmdlet path entirely | `[CODE] NX16.ps1:1112-1150`, `[RES] §2.6`, `[DOC] KNOWN_ISSUES.md A.15` |
| **24H2 alternates** — suggestion/Start families and the classic context menu differ; observed value families differ on 24H2+ | 26100+ | 24H2+ branch writes the documented policy/`Start_IrisRecommendations` family; classic context menu is report-only (`24H2PlusUnverified`) | `[REG] NX01-004`, NX15-009; `[CODE] NX15.ps1:266` |
| **Unsigned wizard posture** — AME Beta v0.8.4 is unsigned, requires Defender exclusions, fixed-password `.apbx`, discretionary verification, no uninstall | all | Disclosed; `UseKernelDriver:false`; no `DefenderDisabled`/`UCPDDisabled` requirements; journal-only rollback; wizard version pinned (v0.8.4, 2026-11-23) | `[ADR] ADR-006`, `[DOC] SECURITY_POLICY.md §2`, `[CODE] playbook.conf:53` |
| **Home ignores the update-off policy family** | Home | No update-disable entry ships at all; Home exclusions on WU-policy entries (§5) | `[RES] §3` |
| **Per-user service names carry a build-fragile suffix** (e.g. `BcastDVRUserService_389fd`) | all | Names resolved at runtime; the capture family is not touched by NX11-010 | `[RES] §2.4`, `[REG] NX11-010` |
| **Modern Standby (S0ix) ignores parts of classic power plans** | S0ix devices | Power entries carry the caveat; NX06-012 skips when `powercfg /a` shows no S0 state | `[RES] §2.7`, `[REG] NX06-012` |
| **Secured-core / UEFI-locked platforms silently ignore VBS-disable** | firmware-locked | No VBS-disable entry ships; NX14 reports state instead of claiming a change | `[RES] §3` (Revi #222) |
| **Localized `powercfg` output** | non-English Windows | Parser fails closed; registry-route entries (NX09-009) remain available | `[CODE] NX09.ps1:39-43` |
| **Removed apps return after feature updates** | all | NX12 logs removal history and documents re-run idempotency; no silent re-removal | `[RES] §3`, `[REG] NX12-010` |
| **Restore-point 24 h throttle** | all | Keep-existing-point behaviour; `Unverified` ≠ `Failed` | `[RES] §2.11` |

---

## 8. Behaviour on an unsupported or ineligible machine

"Unsupported" is not one condition. The engine distinguishes eight, and the effect differs.

| Condition | Wizard | Engine | Journal | Registry keys |
|---|---|---|---|---|
| Build not in `SupportedBuilds` (19045, 22621, 22635, 28000, future build) | Does not run the playbook | Every entry fails the build gate with the numeric reason | No tweak entries; no pre-flight | **None created** |
| Build in 22631–26300 but a required capability is missing | Runs; the per-action gate excludes the entry | `Skip` at step 1 with `key missing: <path>` / `service missing: <name>` | **No entry written** — step 1 returns before journal creation `[CODE] NxApply.ps1:48-52` | **None created**; capability-declared actions never create their gating key |
| Hardware gate fails (vendor, chassis, RAM, SSD) | Runs; entry excluded | `Skip` with the detected value named | No entry written | None created |
| Build report unreadable | Pre-flight `build-report` step = Failed → `Halt` policy | Every entry skips (`build report unavailable`) | Pre-flight backup set may exist (journal init, reports) — **no mutation entries** | None created |
| Insider channel | Runs if the build is one of the four | `insiderChannel=true` + warning; entries attempted | Normal | Per entry |
| 24H2 | Runs | Warning: `24H2 (26100) is the reference-divergent build: extra capability checks apply` | Normal | Per entry, with the documented alternatives |
| Function-level refusal (CPU vendor, RAM/HDD, S0ix, topology) | Runs | `Skipped`/`Refused`/`VendorHardwareAbsent` with the reason in the result | **No mutation entry**; the engine's function-execution audit entry may still record that the function ran (§8.1) | None created |
| Edition mismatch | Runs (no edition gate) | Function-level checks where implemented; otherwise metadata-only (§5.3) | Per entry | Per entry — the documented gap |

**Guarantees that do hold in every row above:** no entry is applied without explicit approval (`-Approved` / wizard selection); no unsupported key family is created by a capability-declared action; a skipped entry never mutates and never *fails* the run (graceful skip, never a halting error) `[CODE] NxCompat.ps1 header`, `NXApply.ps1:48-52`.

### 8.1 Three precise limitations

1. **Pre-flight writes exist before any tweak.** `Invoke-NxPreFlight` initializes the journal and writes `hardware.json`/`build.json` plus backups. That is by design (capture completeness, ADR-006) and is not a configuration mutation — but it means "journal untouched" is true for *skipped tweaks*, not for the journal directory as a whole `[CODE] NX16.ps1 (Invoke-NxPreFlight)`, `playbook/Configuration/Tasks/nxcore.yml`.
2. **Function-level skips can leave an execution-audit entry.** For function-backed entries, `Invoke-NxApply` journals an `apply`/`verify` pair around the call (`FunctionExecuted`) before and after the function runs. When the function then refuses internally (e.g. `Set-NxSysMainConfig` RAM/HDD gates), no state is written and no per-value entry exists, but the audit pair is present. It records *that the function ran*, not that a change occurred. Documented here so the journal is never misread.
3. **Policy-key creation is intentional.** The 20 non-capability registry actions include documented policy paths (`Policies\Microsoft\Windows\…`). Those keys are created deliberately because that is how a local policy is applied; they are journaled (key-existence is captured) and rollback removes what NEXTRIX created.

---

## 9. Verifying these claims

Everything above is reproducible from the repository without executing a modification:

```powershell
# Scope and marketing names
Get-Content registry\schema.json -Raw | ConvertFrom-Json | Select-Object -Expand supportedBuildRange
Get-Content playbook\playbook.conf | Select-String -Pattern '<string>|SupportedBuilds|AllowUnsupportedUpgrades|Requirements'

# Build/edition deviations per entry
Get-ChildItem registry\NX*.json | ForEach-Object {
  $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
  foreach ($t in $j.tweaks) {
    if ($t.builds.min -ne 22631 -or $t.builds.max -ne 26300 -or @($t.builds.excluded).Count -gt 0 -or
        ($t.editions -join '/') -ne 'Home/Pro/Enterprise/Education') {
      "$($t.id) builds=$($t.builds | ConvertTo-Json -Compress) editions=$($t.editions -join '/')"
    }
  }
}

# Capability coverage
(Select-String -Path registry\NX*.json -Pattern 'capabilityPath' -AllMatches).Matches.Count
```

Runtime, read-only:

```powershell
. .\src\nxcore\Import-NxCore.ps1
Get-NxBuildReport      # build, UBR, marketing, inSupportedScope, insiderChannel, uncertainty
Get-NxHardwareReport   # cpu/gpu/memory/storage/chassis + uncertainty
```

---

## 10. Freshness and change control

| Item | Rule |
|---|---|
| Re-verify when | A build enters/leaves scope; a new capability pattern is adopted; a patch removes a code path (KB5089573 class); the playbook schema or wizard version changes |
| Source of truth | `registry/*.json` + `src/nxcore/*.ps1` + generated `playbook/`; this document does not override them |
| Wizard pin | AME Beta v0.8.4, 2026-11-23 (ADR-006) — update this line when the tested build changes |
| Owner | Technical writer (`technical-writer`); resolver findings to the engine workstream |
| Review date | Next phase gate (Wave 6) or first owner build validation, whichever is earlier |
