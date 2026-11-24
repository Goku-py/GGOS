# NEXTRIX — Owner Manual Testing Guide

**Document ID:** W5-A · **Version:** 1.0 · **Date:** 2026-11-23
**Scope:** all 20 registry categories, 282 entries (`registry/NX01.json` … `registry/NX20.json`)
**Audience:** the project owner, performing physical testing on owner-controlled hardware
**Status of this document:** procedure only. It grants no verification status to any entry.

> **Read this first**
>
> 1. **The owner performs all physical testing.** No agent, script, CI run or self-test can promote an entry beyond `ConfigurationValidated`. Promotion beyond that line is owner-only (`TWEAK_CLASSIFICATION.md` §3).
> 2. **Nothing in this repository claims performance.** Configuration checks prove that a setting holds the intended value. They do not prove FPS, frame time, latency, DPC behaviour, thermals, battery life or stability under load.
> 3. **Use a disposable test machine or a VM with a snapshot.** Never test on the development machine. Never test a destructive entry on a daily driver without a full disk image.
> 4. **One tweak at a time.** Apply one entry, verify it, roll it back, verify the original state. Batch applies destroy attribution and make rollback evidence ambiguous.
> 5. **A skipped entry is a result, not a failure.** Hardware/build gates are designed to skip with a reason. Record the reason.

---

## Contents

1. [Purpose and boundaries](#1-purpose-and-boundaries)
2. [Environment and preconditions](#2-environment-and-preconditions)
3. [Standard test workflow for one tweak](#3-standard-test-workflow-for-one-tweak)
4. [Per-category test sheets (NX01–NX20)](#4-per-category-test-sheets)
5. [Session Manager (NX18) test protocol](#5-session-manager-nx18-test-protocol)
6. [Evidence recording and performance testing](#6-evidence-recording-and-performance-testing)
7. [Release acceptance checklist](#7-release-acceptance-checklist)
8. [Known host flakiness and the bounded runner](#8-known-host-flakiness-and-the-bounded-runner)
9. [Appendices](#9-appendices)

---

## 1. Purpose and boundaries

### 1.1 What this guide is, and what it is not

| This guide is | This guide is not |
|---|---|
| A per-entry test sheet generated from the actual registry | A benchmark suite |
| A procedure for proving apply → verify → rollback on real hardware | Evidence that any tweak improves performance |
| A way to record owner evidence against a registry entry | A promotion mechanism that an agent can operate |
| A description of the configuration effect each entry intends | A claim about user-perceived smoothness, latency or stability |

### 1.2 Three different questions — never merge them

| Question | What answers it | What a pass proves | What it does **not** prove |
|---|---|---|---|
| **Configuration validation** — does the engine produce the intended plan and target the right value? | `Invoke-NxApply -Plan`, `Get-NxTweakEligibility`, `Test-NxRegistry`, syntax checks, self-tests | The code path is coherent and read-only evaluation works | That the change applies or holds on real hardware |
| **Functional verification** — does the change apply, hold, and revert exactly? | The entry's verify procedure + journal + `Invoke-NxRollback` | The intended configuration state exists after apply and the recorded original state returns after rollback | That the change improves any metric, or is stable in every workload |
| **Performance verification** — does a named metric change under a controlled test? | Owner benchmark runs (§6.4) | A measured change on that machine, under that workload, with that method | A general improvement, a cross-machine result, or a different metric |

**Functional verification is not performance verification.** A verify procedure that reads a registry value, a power setting or a service state is a configuration check. It must never be written up as “faster”, “smoother”, “lower latency” or “reduced stutter”.

**Configuration validation is not owner evidence.** Plan mode and self-tests run without mutation. They are necessary and insufficient. Only the owner's physical run creates `OwnerFunctionallyValidated` evidence.

### 1.3 Verification-status ladder

The registry's `status` field uses the keys below. The ladder names are from `TWEAK_CLASSIFICATION.md` §3.

| Registry status | Ladder name | Meaning | Who can grant | Entries today |
|---|---|---|---|---:|
| `Candidate` | CANDIDATE | Proposed; nothing written | Coordinator | 0 |
| `Defined` | DEFINED | Registry entry complete and schema-valid; implementation absent or plan-only | Coordinator | 40 |
| `Implemented` | IMPLEMENTED | Apply/rollback/verify code exists | Coordinator | 0 |
| `SyntaxValidated` | SYNTAX-VALIDATED | Static/syntax validation passed; the modification has not been executed on a host | Coordinator | 242 |
| `ConfigurationValidated` | CONFIGURATION-VALIDATED | Plan/dry-run and compatibility checks validated against a machine snapshot without mutation | Coordinator | 0 |
| `OwnerFunctionallyValidated` | FUNCTIONALLY-VALIDATED | **Owner** confirmed the change applies and holds on test hardware | **Owner only** | 0 |
| `OwnerHardwareTested` | MANUALLY-HARDWARE-TESTED | **Owner** completed the entry's test sheet on physical hardware, including rollback and side effects | **Owner only** | 0 |
| `PerformanceTested` | PERFORMANCE-TESTED | **Owner** supplied benchmark evidence for the entry's defined metric and method | **Owner only** | 0 |
| `ReleaseApproved` | RELEASE-APPROVED | **Owner** approved inclusion in a release | **Owner only** | 0 |

Two consequences follow directly:

- **40 entries are `Defined`**: they may be plan-only, read-only or designed but not shipped. Their sheets say `Defined: not shipped`. Do not attempt a functional apply test on them; test the plan/report output and record it as such.
- **No entry is `ConfigurationValidated` yet.** The registry currently stops at `SyntaxValidated`. The first owner run in this guide is therefore creating the first evidence above that line.

> **Document inconsistency, recorded:** `TWEAK_CLASSIFICATION.md` ends with “No entry in this repository currently holds any status beyond CANDIDATE.” That sentence is stale; the registry is authoritative (242 `SyntaxValidated`, 40 `Defined`). It should be corrected by the coordinator.

### 1.4 Evidence levels (what an E-level means)

| Level | Meaning | Current count |
|---|---|---:|
| **E0** | Unverified claim; community-known configuration without authoritative documentation of the claimed behaviour | 84 |
| **E1** | Documented Windows/vendor behaviour; the documentation source is recorded in the entry | 198 |
| **E2** | Experimentally evaluated on one owner configuration | 0 |
| **E3** | Repeatedly evaluated on multiple owner hardware configurations | 0 |
| **E4** | Independently reproducible across diverse configurations | 0 |

Rules that apply to every sheet:

1. An E-level describes what is known about the **setting's behaviour**, not whether it improves anything.
2. `E2` and above require owner-supplied results. They cannot be inferred from a successful apply.
3. One machine is `E2`, never `E3`. Do not generalise a single-machine result.
4. A configuration check pass does not raise the evidence level. Only a completed functional or performance test does.

### 1.5 Risk classes and approval models in this registry

| Risk class | Count | Testing consequence |
|---|---:|---|
| CORE | 78 | Normal single-entry test; still verify side effects |
| CONDITIONAL | 147 | Record the applicability condition and the trade-off before applying |
| ADVANCED | 41 | Opt-in only; read the technical explanation and side effects first; never batch |
| EXPERIMENTAL | 4 | Never in a preset; expect a best-effort or uncertain result; record uncertainty explicitly |
| TROUBLESHOOTING | 12 | Apply only against the named symptom; record the symptom before and after |

| Approval model | Count | Manual-test requirement |
|---|---:|---|
| `Selection` | 162 | Selection is the approval; record it |
| `SelectionPlusConfirmation` | 57 | Record the confirmation step in the evidence |
| `ExplicitConsent` | 63 | Write an explicit consent line in the evidence **before** apply (`consent: ExplicitConsent acknowledged for <ID>`) |

72 entries are `presetExcluded: true`; those must never be applied as part of a batch or preset test.

### 1.6 Non-negotiable testing rules

1. **Snapshot first.** A VM snapshot or full image is the outer rollback layer; the journal is the inner one.
2. **One change at a time.** No second tweak until the first is rolled back and verified.
3. **Journal-first.** Never bypass `Invoke-NxApply`/`Invoke-NxRollback` with direct registry writes. A change outside the journal cannot be rolled back by NEXTRIX.
4. **Read-only first.** Use `-Plan`, report modes and `Get-*` functions before any mutation.
5. **Stop on verification failure.** The engine auto-restores and records `failed`/`Failed-RestoredOriginal`. Do not re-apply until the journal is understood.
6. **Divergence is not a pass.** If rollback reports `Diverged`, the live state changed after apply; the owner's later change wins. Record it and resolve manually.
7. **No performance language.** Describe configuration intent, not outcome.
8. **No secrets or personal data in evidence.** Use the support bundle's scrubber; redact machine names and serials in screenshots.

---

## 2. Environment and preconditions

### 2.1 Machine choice

| Environment | Suitable for | Not suitable for |
|---|---|---|
| **VM with snapshot** (Hyper-V, VMware, VirtualBox) | Registry, UI, policy, service, task, most power-plan checks; destructive debloat tests; repeatable rollback drills | GPU-vendor behaviour, real sensor readings, battery/lid behaviour, topology claims, driver/firmware behaviour |
| **Physical test PC** (disposable or fully imaged) | Everything; required for `OwnerHardwareTested` on hardware-sensitive entries | Nothing, provided a full image exists |
| **Daily driver** | Nothing in this guide | All destructive, security, power, storage and debloat entries |

Hardware-sensitive families that require physical hardware for a meaningful result: NX04 (GPU vendor paths), NX08 (peripherals), NX09 (battery/lid/Modern Standby), NX10 (thermal sensors), NX19 (topology/scheduling), NX20 (inventory/vendor drivers). A VM can still be used to prove that an unsupported entry **skips with a reason** — record that as a gate test, not as a hardware result.

### 2.2 Preconditions checklist

| # | Precondition | How to confirm | If it fails |
|---|---|---|---|
| 1 | Windows 11 build 22631–26300 | `Get-NxBuildReport` → `inSupportedScope = True` | Stop; the build is outside ADR-003 scope |
| 2 | Windows PowerShell **5.1** | `$PSVersionTable.PSVersion` in `powershell.exe` | Re-open in `powershell.exe`; do not use PS7 for DISM/Appx/TPM paths |
| 3 | Elevated session | `([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)` | Relaunch elevated |
| 4 | Snapshot or image exists | VM snapshot name / image timestamp recorded | Take one; do not proceed |
| 5 | No pending reboot / update | `Get-NxBuildReport`, Windows Update status | Finish updates and reboot first |
| 6 | Free disk for journal + backups | ≥ 5 GB free on the system drive | Free space or use a larger test disk |
| 7 | No unresolved NEXTRIX journal | `Read-NxJournal -Path <journal>` → `integrityErrors.Count = 0`; no non-terminal session records | Roll back or start from a fresh snapshot / fresh journal root |
| 8 | Entry status known | Registry `status`; `Defined` entries are plan/report-only | Do not attempt a functional apply; record `Defined: not shipped` |
| 9 | Consent recorded for `ExplicitConsent` | Evidence line written before apply | Do not apply |
| 10 | Test label and evidence folder created | `C:\NEXTRIX-Evidence\<date>-<ID>\` | Create it before starting |

### 2.3 Loading the engine

Open **Windows PowerShell 5.1** elevated, then:

```powershell
Set-Location 'D:\College\Me\Projects\Tweaks\NEXTRIX'
. .\src\nxcore\Import-NxCore.ps1
```

`Import-NxCore.ps1` must be **dot-sourced** (leading dot). It loads `NxJournal`, `NxBuild`, `NxHardware`, `NxCompat`, `NxVerify`, `NxRollback`, `NxApply` and every category module under `src/nxcore/functions`.

For Session Manager work, load the separate module instead — it loads NxCore itself when needed:

```powershell
. .\src\nxsession\NX18.ps1
```

Do not load `NX18.ps1` and `Import-NxCore.ps1` twice in the same scope for the same session; the guard is safe but duplicate definitions make the console output harder to audit.

Verify the loader:

```powershell
Get-Command Invoke-NxApply, Invoke-NxRollback, Test-NxConfigurationState, Get-NxBuildReport |
    Select-Object Name, CommandType
```

### 2.4 Where NEXTRIX keeps state

| Item | Default location | Contents |
|---|---|---|
| Journal root | `%ProgramData%\NEXTRIX\Journal\` | `journal.jsonl` (append-only entries), `manifest.json` (count, `lastHash`, `captureStatus`, `restoredVerifiedUtc`) |
| Backups | `%ProgramData%\NEXTRIX\Backups\<timestamp>\` | Registry `.reg` exports, service/task baselines, `hardware.json`, `build.json` |
| Session records | `%ProgramData%\NEXTRIX\Sessions\` | `session-<guid>.json` per NX18 session (state, heartbeat, `verifiedSteps`) |
| Session profiles | `%ProgramData%\NEXTRIX\Sessions\profiles\` | User-authored per-game JSON; NEXTRIX never creates one |
| Support bundle | Owner-chosen path | Scrubbed zip from NX16-017; nothing is uploaded |

**Recommended isolation for manual tests:** give each test run its own journal root, e.g. `C:\NEXTRIX-Test\Journal-NX02-002-20261123-141500`. This keeps evidence attributable, avoids capture-refusal from a previous test, and lets you archive the exact journal with the evidence. The production path remains `%ProgramData%\NEXTRIX\Journal` for playbook runs.

> **Capture-refusal and re-arm caveat (verified by static inspection, not executed):** `Initialize-NxJournal` refuses an existing journal with `captureStatus = Complete`. `Complete-NxJournalRestore` sets `restoredVerifiedUtc`, but `Initialize-NxJournal` does not currently consult that marker. For repeat tests, use a fresh journal root or a fresh snapshot. **Never** use `-Force` on a journal whose `journal.jsonl` already has entries: the manifest entry count resets to zero while the entries remain, which makes the hash chain fail.

### 2.5 Pre-flight sequence (before the first mutation)

One action per step. Record the output of steps 4–8 in the evidence file.

1. **Snapshot the VM / confirm the image.** Record the snapshot name or image timestamp.
2. **Open an elevated Windows PowerShell 5.1 window.**
3. **Set location and load the engine** (§2.3).
4. **Record the build.** `Get-NxBuildReport | Format-List` — record `editionId`, `displayVersion`, `build`, `ubr`, `inSupportedScope`.
5. **Record the hardware.** `Get-NxHardwareReport | ConvertTo-Json -Depth 6` — save `hardware.json`.
6. **Choose the journal root and run the pre-flight gate.** The pre-flight is registry entry **NX16-004** (pre-flight original-state snapshot bundle), implemented by `Invoke-NxPreFlight`. It initializes the journal, writes reports and takes backups; it never mutates Windows configuration.

```powershell
$journal = 'C:\NEXTRIX-Test\Journal-NX02-002-20261123-141500'
$tweak   = (Get-Content .\registry\NX02.json -Raw | ConvertFrom-Json).tweaks |
           Where-Object id -eq 'NX02-002'

$regPaths = @($tweak.apply.actions | Where-Object type -eq 'registry' |
              ForEach-Object path | Sort-Object -Unique)
$svcNames = @($tweak.apply.actions | Where-Object type -eq 'service' |
              ForEach-Object name | Sort-Object -Unique)

$pre = Invoke-NxPreFlight -JournalRoot $journal -IncludeRestorePoint `
       -RegistryPaths $regPaths -ServiceNames $svcNames
$pre | Format-List allComplete, backupSetPath, journalRoot
$pre.steps | Format-Table step, name, outcome, detail -AutoSize
```

7. **Gate on `allComplete = True`.** If any step is `Failed`, stop. A capture failure means “no mutation without verified prior state”.
8. **Confirm the journal manifest.**

```powershell
Get-Content (Join-Path $journal 'manifest.json') -Raw | ConvertFrom-Json |
    Format-List captureStatus, entries, lastHash, restoredVerifiedUtc
```

9. **Save the pre-flight report** to the evidence folder (`$pre | ConvertTo-Json -Depth 8 | Set-Content ...`).

`-IncludeRestorePoint` invokes the NX16-002 checkpoint ritual. Windows' 24-hour restore-point throttle is handled honestly: if creation is throttled and a point newer than 24 hours exists, that point is kept and reported; this is not a failure. NEXTRIX never deletes restore points or shadow copies.

### 2.6 Playbook version pinning

If the test uses the generated AME playbook rather than the direct engine, pin and record both versions before running it.

```powershell
# Generate (or dry-run) from the registry. -Version is mandatory.
.\tools\Invoke-NxBuild.ps1 -Version '0.6.0-owner-test-1' -OutDir '.\playbook-build'

# Hash every generated file so the exact artifact is identifiable.
Get-ChildItem .\playbook-build -Recurse -File |
    Get-FileHash -Algorithm SHA256 |
    Select-Object Path, Hash |
    Export-Csv .\NX-PLAYBOOK-HASHES.csv -NoTypeInformation
```

Record in the evidence: playbook `-Version`, the hash manifest, the AME Wizard version (if the wizard is used), and the run date. The wizard version is pinned because the platform is a 0.x beta and schema drift is a tracked risk (`SECURITY_POLICY.md` §2; `KNOWN_ISSUES.md` R1).

Two packaging facts affect the test:

- The generator inventories `src/nxcore` only. `src/nxsession/NX18.ps1` must be bundled separately for NX18 runtime tests (`KNOWN_ISSUES.md` 16). The playbook's NX18 options are informational probes until that packaging step.
- Rollback is CLI-only (the installer has no undo page). Run `Invoke-NxRollback -TweakId`/`-Category`/`-Profile`/`-All` from the bundled NxCore (`KNOWN_ISSUES.md` 10).

### 2.7 Exporting the evidence bundle (NX16-017)

At the end of a test session:

```powershell
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bundle = "C:\NEXTRIX-Evidence\$stamp-NX02-002.zip"
Export-NxSupportBundle -DestinationPath $bundle -JournalRoot $journal `
    -IncludeHealth
```

The bundle contains `hardware.json`, `build.json`, a journal **summary** (IDs, timestamps, results — never original/modified values, `errorInfo` or hashes) and optional health reports. Machine identifiers are scrubbed from all text. It refuses to overwrite an existing file; choose a new path. Nothing is uploaded.

Use `-IncludeDismScan` / `-IncludeSfc` only when the entry under test is NX16-007/NX16-008 or the evidence needs a component-health baseline; these scans are slow and are not needed for every tweak.

---

## 3. Standard test workflow for one tweak

This is the procedure for one registry entry, start to finish. It assumes §2 is complete and the pre-flight gate returned `allComplete = True`.

### 3.1 Step 1 — Record the entry ID and read the whole entry

```powershell
$tweak = (Get-Content .\registry\NX02.json -Raw | ConvertFrom-Json).tweaks |
         Where-Object id -eq 'NX02-002'
$tweak | Format-List id, name, risk, evidence, status, approval, restart, privileges
$tweak.apply.actions | Format-List type, path, name, kind, data, function, parameters
$tweak.verify | Format-List
$tweak.rollback | Format-List
$tweak.sideEffects
```

Record: ID, risk, evidence level, status, approval model, restart requirement, dependencies, conflicts and every listed side effect. If `status` is `Defined`, stop here: this entry has no shipped mutation path. Test only its report/plan output and record `Defined: not shipped` in the result.

### 3.2 Step 2 — Capture the pre-state (read-only)

For **registry actions**, capture every target before doing anything:

```powershell
$preState = foreach ($a in @($tweak.apply.actions | Where-Object type -eq 'registry')) {
    Capture-NxRegistryValue -Path $a.path -Name $a.name
}
$preState | ConvertTo-Json -Depth 6 | Set-Content "C:\NEXTRIX-Evidence\$($tweak.id)-pre.json" -Encoding UTF8
$preState | Format-Table path, name, keyExisted, existed, kind, value -AutoSize
```

`Capture-NxRegistryValue` is read-only and records `keyExisted`, `existed`, `kind` and the exact value; `ExpandString` is captured unexpanded. This descriptor is the definition of “original” for this test.

For **function actions**, use the entry's own read-only mode first:

```powershell
Get-Command -Name $tweak.apply.actions.function -ErrorAction SilentlyContinue |
    Select-Object Name, Parameters
```

If the function supports `-Plan` or a report mode (for example `mode=Report`), run it and save the output. If it does not, the function's own pre-mutation capture is the authoritative record; the journal entry written before the mutation is the evidence. Do not substitute a guessed Windows default.

For **power, service, task and AppX** entries, capture the specific state named in the Verify column (`powercfg /query`, `Get-Service`, `Get-ScheduledTask`, `Get-AppxPackage`).

### 3.3 Step 3 — Apply with explicit approval

Plan first. `-Plan` performs read-only evaluation and writes nothing (no journal entry, no mutation).

```powershell
$hw    = Get-NxHardwareReport
$build = Get-NxBuildReport

$plan = Invoke-NxApply -Tweak $tweak -HardwareReport $hw -BuildReport $build `
        -JournalRoot $journal -Profiles P2 -Plan
$plan | Format-List tweakId, plan, skipped, failed
$plan.steps | Format-Table step, name, outcome, detail -AutoSize
```

Expected: `plan = True`, steps say `Planned`, and the journal entry count is unchanged. For a **function action**, `-Plan` records the intended function call but does not execute the function's own planner; use the function's `-Plan`/report mode from §3.2 for the pre-state. If `skipped = True`, read the eligibility reasons and record the skip; do not force the entry.

Apply for real. `-Approved` is mandatory; nothing applies without it.

```powershell
$run = Invoke-NxApply -Tweak $tweak -HardwareReport $hw -BuildReport $build `
       -JournalRoot $journal -Profiles P2 -Approved
$run | Format-List tweakId, plan, skipped, failed, applied
$run.steps | Format-Table step, name, outcome, detail -AutoSize
```

`-Profiles` records the journal tag used by profile-scoped rollback. It is not a profile-eligibility filter; choose the profile you are actually testing (or omit it and record `none`).

Expected success: `applied = True`, the apply step says `Applied`, the verify step says `Verified`, and the detail names the journal sequence numbers.

For a **function action**, the engine step is `FunctionExecuted`, not `Verified`. `applied = True` only means the function returned without throwing. Read the function's own result object and its journaled per-value verification entries; a function can return a result that reports a failed sub-step. Do not record a pass on `applied = True` alone.

Expected graceful skip: `skipped = True` with a machine-readable reason (hardware vendor absent, build out of range, dependency missing, SSD absent). This is a correct result for that machine.

Expected failure: `failed = True`. The engine journals the failure and, for a verification failure, restores the exact original immediately (journal result `Failed-RestoredOriginal`). Do not re-apply. Go to §3.7.

> **ExplicitConsent entries:** `Invoke-NxApply -Approved` is one global switch, not a per-entry consent dialog. For the 63 `ExplicitConsent` entries, write `consent: ExplicitConsent acknowledged for <ID> by owner` in the evidence file before running the apply command. The wizard cannot express per-tweak dialogs either (`KNOWN_ISSUES.md` 9); selection-level enforcement is the platform limit.

> **Playbook alternative:** selecting the entry in the generated playbook performs the same journaled pipeline. Use the playbook for end-to-end release tests, and the direct engine for single-tweak diagnosis. Record the playbook version and wizard version (§2.6).

### 3.4 Step 4 — Verify the configuration effect

Use the entry's Verify procedure. The common patterns:

| Target type | Read-back command |
|---|---|
| Registry value | `Get-ItemProperty -Path <path> -Name <name>`; for engine parity, `Test-NxConfigurationState -Path <path> -Name <name> -Kind <kind> -ExpectedValue <value>` |
| Power setting | `powercfg /query <scheme> <subgroup> <setting>`; `Get-NxActivePowerScheme` for the active plan |
| Service | `Get-Service -Name <name>` and the `Start` value under `HKLM:\SYSTEM\CurrentControlSet\Services\<name>` |
| Scheduled task | `Get-ScheduledTask -TaskPath <path> -TaskName <name>`; compare exported XML if the entry preserves it |
| AppX package | `Get-AppxPackage -Name <name>`; `Get-AppxProvisionedPackage -Online` for provisioned state |
| Function/report | The `Get-*` or report function named in the Verify column; save its JSON |
| Session | `Get-NxSessionStatus`, `Get-NxProcessCpuSetState`, `Get-NxActivePowerScheme` |

Record the actual command and its output. “Verified” means the **configuration state** matches the intended state. It does not mean the tweak is beneficial, stable under load, or performance-relevant.

If the entry has multiple values, verify each one. If a layer is skipped by design (for example a per-user layer on a machine policy), record the skip reason from the verify output.

### 3.5 Step 5 — Verify the listed side effects

Read `$tweak.sideEffects` and check each item in the real UI or workload. Examples:

- Capture entries: confirm Game Bar/recording actually stops working as described.
- Service entries: confirm the dependent application still starts, or record the expected loss.
- Power entries: check AC and DC separately; do not assume the DC plane followed the AC plane.
- Debloat entries: confirm the app is gone, and confirm the protected dependencies still work.
- UI entries: confirm the visual change and confirm no unreadable/overlapping UI.

Record each side effect as `expected/observed`, `unexpected/observed`, or `not observable in this environment`. “Not checked” is not a pass.

### 3.6 Step 6 — Roll back through the journal

```powershell
$rb = Invoke-NxRollback -JournalRoot $journal -TweakId $tweak.id
$rb | Format-List aborted, integrityErrors
$rb.restored   | Format-Table tweakId, action, detail, verified -AutoSize
$rb.diverged   | Format-Table tweakId, target, reason -AutoSize
$rb.failed     | Format-Table tweakId, reason -AutoSize
$rb.irreversible | Format-Table tweakId, target, reason -AutoSize
```

`-JournalRoot` is mandatory on `Invoke-NxRollback` even when the prompt shorthand says only `-TweakId`. Other scopes:

| Scope | Command | Use |
|---|---|---|
| Tweak | `Invoke-NxRollback -JournalRoot $journal -TweakId NX02-002` | Normal single-entry test |
| Category | `Invoke-NxRollback -JournalRoot $journal -Category NX02` | After a category batch test |
| Profile | `Invoke-NxRollback -JournalRoot $journal -Profile P2` | After a profile-tagged test |
| Full | `Invoke-NxRollback -JournalRoot $journal -All` | End of a session / disaster cleanup |

For power, service, task and AppX target types, the main engine delegates to the category rollback engine (`Invoke-Nx09Rollback`, `Invoke-Nx11Rollback`, and so on). The delegated result appears in `$rb.delegated`. A category engine that is not loaded is reported as a failure, not silently skipped.

Rollback semantics to expect:

- **Reverse order** — newest journal entry first.
- **Only-if-ours** — a target is restored only if its live state still equals the value NEXTRIX recorded writing. A later user/other-tool change is `Diverged` and is left untouched.
- **Exact original** — original kind and value; a value that never existed is deleted.
- **Integrity-gated** — a tampered journal aborts the run before any restoration.
- **Irreversible entries** — AppX removal, temp/deleted caches and driver-package deletion are labeled at apply time and reported in `$rb.irreversible`; follow the entry's documented manual route.

### 3.7 Step 7 — Verify the exact original state returned

For registry entries, re-capture and compare:

```powershell
$postState = foreach ($p in $preState) {
    Capture-NxRegistryValue -Path $p.path -Name $p.name
}

function Test-NxSameDescriptor($before, $after) {
    ($before.keyExisted -eq $after.keyExisted) -and
    ($before.existed    -eq $after.existed) -and
    ($before.kind       -eq $after.kind) -and
    ((ConvertTo-Json -InputObject $before.value -Depth 6 -Compress) -eq
     (ConvertTo-Json -InputObject $after.value  -Depth 6 -Compress))
}

$comparison = for ($i = 0; $i -lt @($preState).Count; $i++) {
    [pscustomobject]@{
        Path       = $preState[$i].path
        Name       = $preState[$i].name
        ExactMatch = Test-NxSameDescriptor $preState[$i] $postState[$i]
        Before     = ($preState[$i] | ConvertTo-Json -Depth 6 -Compress)
        After      = ($postState[$i] | ConvertTo-Json -Depth 6 -Compress)
    }
}
$comparison | Format-List
```

Pass criteria: every row `ExactMatch = True`, including `existed = False` rows (the value must be absent, not set to a guessed default). For non-registry entries, use the category rollback's `verified` flags and the manual query in the Verify column.

If a rollback reports `Diverged`, the original was not restored by NEXTRIX because the live state was no longer ours. Record the live value, decide manually, and do not call the test a pass.

> **Static inspection caveat (not executed during documentation):** `Test-NxConfigurationState` declares `-ExpectedValue` as mandatory without `[AllowNull()]`. `NxRollback.ps1` calls it with `$null` when the original value did not exist, which PowerShell 5.1 rejects. If a rollback of a previously-absent value reports a failed rollback step even though the value is gone, verify the absence manually and record the engine behaviour as a finding for the coordinator. Do not “fix” it by writing a default.

### 3.8 Step 8 — Record the evidence

Write the record using the template in §6. At minimum, capture:

- tweak ID and name, risk, evidence, status, approval, restart;
- build, UBR, edition, hardware label and VM snapshot;
- journal root, apply/verify/rollback sequence numbers;
- pre-state and post-apply state; post-rollback state;
- exact verify command and output;
- side effects observed;
- rollback result (`restored`/`diverged`/`failed`/`irreversible`);
- `exactOriginal = True/False`;
- result: `PASS`, `FAIL`, `BLOCKED`, `SKIPPED` or `N/A (Defined)`;
- artifacts: screenshots, saved JSON, support bundle path.

Find the sequence numbers:

```powershell
$j = Read-NxJournal -Path $journal
$j.entries |
    Where-Object tweakId -eq $tweak.id |
    Select-Object seq, operation, result, verification, tsUtcUnixMs |
    Format-Table -AutoSize
```

Do **not** write `@($j.entries)` in Windows PowerShell 5.1; `.entries` is a `List[object]` and the array subexpression can throw “Argument types do not match” (`STATE_JOURNAL.md` §3.8). Use `.Count` or the pipeline form above.

### 3.9 Failure recovery matrix

| Symptom | Meaning | Safe action |
|---|---|---|
| Apply returns `skipped = True` | Eligibility gate rejected the entry for this machine/build/hardware | Record the reasons; test a matching machine or accept the skip |
| Apply returns `failed = True` before verify | The function or write threw | Read the journal `failed` entry; confirm the live state is unchanged; do not re-apply blindly |
| Apply verification failed | The configuration did not read back as intended | The engine already restored the exact original; confirm with §3.7; record `FAIL`; report the verify output |
| Rollback `aborted = True` | Journal integrity errors | **Do not force.** Restore the backup `.reg`/snapshot; report the integrity errors |
| Rollback `diverged` non-empty | The live value changed after apply (user or another tool) | Leave it; record the live value; resolve manually |
| Rollback `failed` non-empty | Restore threw or a category engine is missing | Use the NX16-003 backup or snapshot; report the engine error |
| `irreversible` non-empty | The entry is honestly labeled non-journal-reversible | Follow the entry's documented manual route (reinstall media/Store/NX12-011) |
| Function reports `NotImplemented` | Module missing or entry `Defined` | Load the correct module; do not hand-write the change |

### 3.10 Security notes for the test session

- Run elevated only for the test window; close the elevated shell afterwards.
- The journal stores configuration states, not passwords, tokens or user data. Keep it that way: never paste credentials into a tweak parameter or an evidence file.
- Screenshots can contain machine names, usernames, product keys or serials. Crop or scrub them before sharing.
- Do not disable Defender, Firewall, UAC, SmartScreen, Secure Boot, TPM, VBS/HVCI or mitigations to “make a test work”. Those are not NEXTRIX test steps; they are out of policy (`SECURITY_POLICY.md` §1).
- The AME Wizard platform is an unsigned beta whose official instructions ask for Defender exclusions. Testing it is a disclosed platform risk; it does not authorize weakening security on the test machine beyond the documented, isolated test window (`SECURITY_POLICY.md` §2).

---

## 4. Per-category test sheets

### 4.1 How these tables were produced

Each row is generated from the registry entry itself: `id`, `name`, `risk`, `evidence`, `apply.actions`, `verify.procedure`, `rollback.procedure`, `dependencies`, `conflicts`, `restart`, `sideEffects` and `status`. Nothing is invented. The tables were mechanically checked so that every one of the 282 IDs appears exactly once (Appendix C).

Column meanings:

| Column | Meaning |
|---|---|
| **ID** | Registry identifier; use it verbatim in the evidence |
| **Name** | Registry display name |
| **Risk** | CORE / CONDITIONAL / ADVANCED / EXPERIMENTAL / TROUBLESHOOTING |
| **Evidence** | E0/E1 desk level today; E2+ only after owner testing |
| **Apply** | Engine function name(s). `Invoke-NxRegistryTweak ×N` means N registry actions routed through the journaled writer; `Get-Nx18Capability` is the NX18 capability probe (a session is started separately) |
| **Verify (short)** | Abbreviated from the entry's verify procedure; the full text in the registry is authoritative |
| **Rollback (short)** | Abbreviated restoration semantics; `None (read-only)` and `None (additive)` need no rollback; `Not journal-reversible` requires the documented manual route |
| **Notes** | `Defined: not shipped`, dependencies (`Dep`), conflicts, restart and the first listed side effect |

**Read-only and additive entries** are marked `Read-only report` or `Additive artifact` in Notes. They require no rollback. The per-category paragraphs state how many there are.

**Short fields are deliberately short.** Where the verify or rollback text is essential (power AC/DC, services, irreversible removals, sessions), open the registry entry and read the full procedure before testing.

### 4.2 NX01 — Windows Foundation (16 entries)

Foundation entries are almost all registry policy/value writes with exact journal restore. There is one `Defined` entry (NX01-009, Search indexing scope) and no read-only report. Typical risks are scope mistakes (per-user vs machine policy) and UI expectations. Several update/maintenance policy entries are documented for Pro/Enterprise/Education; Home may show the policy as not applicable. Record the edition and do not infer Home enforcement. Verify each value's kind as well as its data; policy values frequently do not exist beforehand, so rollback must delete them rather than write a guessed default. NX01-008 needs a new session before the change is visible; NX01-015 needs a reboot.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX01-001 | Disable Windows tips & suggestions | CORE | E0 | Invoke-NxRegistryTweak ×3 | Test-NxConfigurationState (NxVerify) confirms each value is DWord 0 after apply… | Journaled restore (exact original, only-if-ours) | Side: Windows tips and suggestion content no longer appear… |
| NX01-002 | Disable welcome experience | CORE | E0 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms SubscribedContent-310093Enabled is DWord 0 after apply | Journaled restore (exact original, only-if-ours) | Side: The post-update welcome/'what's new' experience no longer… |
| NX01-003 | Disable consumer experience / suggested apps | CORE | E1 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms DisableWindowsConsumerFeatures is DWord 1 after apply… | Journaled restore (exact original, only-if-ours) | Side: ReviOS revert.yml documents that DisableWindowsConsumerFeatu… |
| NX01-004 | Disable Start menu suggestions | CORE | E0 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms each applied value is DWord 0… | Journaled restore (exact original, only-if-ours) | Side: Start menu promotional suggestions stop for the current… |
| NX01-005 | Disable silent promotional app installs | CORE | E0 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms SilentInstalledAppsEnabled is DWord 0 after apply | Journaled restore (exact original, only-if-ours) | Side: Promoted/suggested apps are no longer installed silently… |
| NX01-006 | Disable lock-screen promotional content | CORE | E0 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms both values are DWord 0 after apply | Journaled restore (exact original, only-if-ours) | Side: Lock-screen tips/tricks/fun-fact overlays stop… |
| NX01-007 | Notification defaults configuration | CORE | E1 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms both values are DWord as proposed… | Journaled restore (exact original, only-if-ours) | Side: Lock-screen toast previews stop for the current user |
| NX01-008 | Global UWP background-app permission policy | CONDITIONAL | E0 | Set-NxBackgroundAppsGlobal | Function re-reads each written value via Test-NxConfigurationState and journals a verify entry… | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: Background apps stop updating tiles/notifications… |
| NX01-009 | Windows Search indexing scope configuration | CONDITIONAL | E1 | Set-NxSearchIndexingScope | Get-NxSearchCrawlScopeInventory reports current scope/policy state before and after any future mutation… | None (not shipped) | Defined: not shipped; Side: None in v0.1 (defined only) |
| NX01-010 | Disable search highlights | CORE | E1 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms both values are DWord 0 after apply… | Journaled restore (exact original, only-if-ours) | Side: Search highlights (rotating seasonal/promotional content)… |
| NX01-011 | Delivery Optimization configuration | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms DODownloadMode is DWord 0 after apply… | Journaled restore (exact original, only-if-ours) | Side: No peer-shared update downloads/uploads while set to 0 |
| NX01-012 | Automatic maintenance schedule | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms WakeUp is DWord 0; Security and Maintenance still reports Automatic… | Journaled restore (exact original, only-if-ours) | Side: Maintenance no longer wakes the machine (good for laptop… |
| NX01-013 | Windows Update active hours configuration | CORE | E1 | Invoke-NxRegistryTweak ×3 | Test-NxConfigurationState confirms the three values; windows longer than 18 hours fail verification… | Journaled restore (exact original, only-if-ours) | Side: Active hours become machine-fixed for all users while set… |
| NX01-014 | Restart notification configuration | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms both values are DWord 1… | Journaled restore (exact original, only-if-ours) | Side: Update-completion/tip notifications are suppressed… |
| NX01-015 | Optional features & components management | CORE | E1 | Get-NxOptionalFeatureInventory + Set-NxOptionalFeatureState | Set-NxOptionalFeatureState re-reads the feature state after mutation and journals Verified (or… | Documented inverse (manual) | Restart: Reboot; Side: Disabling a feature removes its functionality and may… |
| NX01-016 | Default application associations | CORE | E1 | Invoke-NxDefaultAppAssociations | DISM exit code 0 plus a post-import re-export; diff count of association entries reported and journaled | Documented inverse (manual) | Side: New profiles get the imported defaults… |

### 4.3 NX02 — Gaming & Esports (12 entries)

Two entries are read-only reports (NX02-008 Xbox services dependency, NX02-012 launcher detection) and three are `Defined` composition entries (NX02-009/-010/-011). The shipped mutations cover Game Mode, Game Bar, Game DVR/capture and the windowed-games DirectX user setting. Verify the capture side effects explicitly — especially if the machine is also used for streaming — and remember that NX02-008 conflicts with the Xbox app removal entry NX12-005.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX02-001 | Windows Game Mode configuration | CORE | E1 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState read-back of both values equals the intended DWord state… | Journaled restore (exact original, only-if-ours) | Side: Game Mode behavior is Windows-defined… |
| NX02-002 | Xbox Game Bar configuration | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState read-back equals DWord 0; verification journaled | Journaled restore (exact original, only-if-ours) | Side: The controller nexus/Xbox button no longer opens Game Bar… |
| NX02-003 | Disable Game DVR | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×3 | Test-NxConfigurationState read-back of all three values equals DWord 0… | Journaled restore (exact original, only-if-ours) | Side: Game Bar recording/broadcast becomes unavailable (per-user… |
| NX02-004 | Disable background game recording | CONDITIONAL | E0 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState read-back equals DWord 0; verification journaled | Journaled restore (exact original, only-if-ours) | Side: 'Record the last X minutes' no longer works while… |
| NX02-005 | Optimizations for windowed games | CONDITIONAL | E0 | Set-NxDirectXGlobalSetting | Test-NxConfigurationState read-back equals the intended String with kind preserved… | Journaled restore (exact original, only-if-ours) | Side: Sibling fields inside the same REG_SZ value (e.g |
| NX02-006 | Game Mode notification suppression | CORE | E0 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState read-back equals DWord 0; verification journaled | Journaled restore (exact original, only-if-ours) | Side: Game Bar startup panel/tips no longer appear (per-user)… |
| NX02-007 | Game capture configuration | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×3 | Test-NxConfigurationState read-back of all three values equals DWord 0… | Journaled restore (exact original, only-if-ours) | Side: Win+Alt+R / Win+Alt+B / Win+Alt+G-historical shortcut… |
| NX02-008 | Xbox Gaming Services management | CONDITIONAL | E0 | Get-NxXboxServicesDependencyReport | Report object returns with tweakId NX02-008, readOnly=true… | None (read-only) | Read-only report; Conflict NX12-005; Side: None - strictly read-only (process/service/registry/appx… |
| NX02-009 | Per-game driver graphics application | CONDITIONAL | E0 | Invoke-NxPerGameDriverGraphics | Future: composed NX04 apply steps each verify their own configuration state… | Future design (not shipped) | Defined: not shipped; Side: Not yet applicable - composition unimplemented (Defined) |
| NX02-010 | Game-specific launch configuration | CONDITIONAL | E0 | Invoke-NxGameLaunchConfiguration | Future: composed NX19 apply steps each verify their own configuration state… | Future design (not shipped) | Defined: not shipped; Dep NX02-012; Side: Not yet applicable - composition unimplemented (Defined) |
| NX02-011 | Game-specific background app handling | CONDITIONAL | E0 | Invoke-NxGameBackgroundHandling | Future: NX18 session report lists every managed process with its journaled before/after state… | Future design (not shipped) | Defined: not shipped; Dep NX02-012; Side: Not yet applicable - composition unimplemented (Defined) |
| NX02-012 | Game launcher detection registry | CONDITIONAL | E0 | Get-NxLauncherDetectionReport | Report object returns with tweakId NX02-012, readOnly=true, one entry per known launcher with a verdict… | None (read-only) | Read-only report; Side: None - strictly read-only (process/service/registry/appx… |

### 4.4 NX03 — CPU & Processor (13 entries)

This category is dominated by power-plan settings (AC and DC separately) and has 11 entries above CORE. Four entries are read-only or `Defined` (NX03-010 SMT report, NX03-011 AMD preferred cores, NX03-012 Intel hybrid policy, NX03-013 CPU inventory). Test AC and DC as separate observations; a change that holds on AC may be ignored or different on DC. NX03-008 `Win32PrioritySeparation` is contested across references and is preset-excluded: it is an ADVANCED, explanation-mandatory entry, and a configuration pass is not evidence of a scheduling benefit.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX03-001 | Minimum processor state | ADVANCED | E1 | Set-NxProcessorMinState | powercfg /query re-read of PROCTHROTTLEMIN on the target plan returns the chosen AC and DC indexes… | NX03 rollback (AC/DC originals, only-if-ours) | Side: A high minimum state keeps the processor out of low-power… |
| NX03-002 | Maximum processor state | ADVANCED | E1 | Set-NxProcessorMaxState | powercfg /query re-read of PROCTHROTTLEMAX returns the chosen AC and DC indexes… | NX03 rollback (AC/DC originals, only-if-ours) | Side: A cap below 100 % deliberately lowers the performance… |
| NX03-003 | Processor boost mode policy | ADVANCED | E1 | Set-NxProcessorBoostMode | powercfg /query re-read of PERFBOOSTMODE returns the chosen AC and DC indexes… | NX03 rollback (AC/DC originals, only-if-ours) | Side: Boost policy influences how far above nominal the platform… |
| NX03-004 | Energy Performance Preference | ADVANCED | E1 | Set-NxProcessorEnergyPreference | powercfg /query re-read of PERFEPP returns the chosen AC and DC indexes… | NX03 rollback (AC/DC originals, only-if-ours) | Side: Where CPPC v2 autonomous mode is active… |
| NX03-005 | Core parking policy | ADVANCED | E1 | Set-NxCoreParkingPolicy | powercfg /query re-read of CPMINCORES (and CPMAXCORES when supplied) returns the chosen AC and DC… | NX03 rollback (AC/DC originals, only-if-ours) | Side: Parking bounds change which logical processors the OS keeps… |
| NX03-006 | CPU power throttling policy | CONDITIONAL | E1 | Set-NxPowerThrottlingPolicy (mode=Disabled) | Test-NxConfigurationState read-back of PowerThrottlingOff equals the chosen DWord… | Journaled restore (exact original, only-if-ours) | Side: Removes the OS's documented QoS-lowering lever… |
| NX03-007 | MMCSS configuration | ADVANCED | E1 | Set-NxMmcssConfiguration (systemResponsiveness=10) | Test-NxConfigurationState read-back of each written value (SystemResponsiveness… | Journaled restore (exact original, only-if-ours) | Side: MMCSS reserves CPU for low-priority work: lowering… |
| NX03-008 | Win32PrioritySeparation | ADVANCED | E1 | Set-NxWin32PrioritySeparation (value=2) | Test-NxConfigurationState read-back of Win32PrioritySeparation equals the supplied DWord… | Journaled restore (exact original, only-if-ours) | Side: Foreground/background quantum policy is global: every… |
| NX03-009 | Processor performance policy set | ADVANCED | E1 | Set-NxProcessorPerformancePolicy | powercfg /query re-read of each written setting returns the chosen AC and DC indexes… | NX03 rollback (AC/DC originals, only-if-ours) | Side: Thresholds and hysteresis times change how eagerly the OS… |
| NX03-010 | SMT / Hyper-Threading configuration | ADVANCED | E1 | Get-NxSmtTopologyReport | Report returns readOnly=true, noWritesPerformed=true, per-socket counts… | None (not shipped) | Defined: not shipped; Side: None (read-only CIM/WMI queries) |
| NX03-011 | AMD CPPC preferred cores | EXPERIMENTAL | E0 | Get-NxAmdPreferredCoreReport | Report returns readOnly=true, noWritesPerformed=true, cpuVendor from CIM… | None (not shipped) | Defined: not shipped; Side: None (read-only) |
| NX03-012 | Intel hybrid P/E power policy | EXPERIMENTAL | E0 | Get-NxIntelHybridPolicyReport | Report returns readOnly=true, noWritesPerformed=true, cpuVendor from CIM… | None (not shipped) | Defined: not shipped; Side: None (read-only) |
| NX03-013 | CPU inventory & frequency report | CORE | E1 | Get-NxCpuInventoryReport | Report returns readOnly=true, noWritesPerformed=true, readSucceeded=true with at least one socket entry… | None (read-only) | Read-only report; Side: None beyond a brief CIM query and a dozen read-only… |

### 4.5 NX04 — GPU & Graphics (23 entries)

Only four shipped mutations exist here: NX04-001 HAGS (reboot), NX04-002 per-app GPU preference, NX04-003 windowed VRR and NX04-006 MPO troubleshooting. Three entries are read-only reports (NX04-004, -007, -008). The remaining 16 are `Defined` guided workflows (vendor tools, or the per-game Compatibility tab for NX04-005): NEXTRIX validates and explains, but the owner makes the change in the vendor/OS UI, and the owner reverts it there. Test on the actual vendor hardware; a VM cannot exercise these paths. Record driver version for every GPU test.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX04-001 | Hardware-Accelerated GPU Scheduling | ADVANCED | E1 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState reads HwSchMode back as DWord:2; Get-NxHagsCapability reports state Enabled… | Journaled restore (exact original) | Restart: Reboot; Side: GPU scheduling behavior changes driver-internally… |
| NX04-002 | Per-application GPU preference | CONDITIONAL | E1 | Set-NxGpuPreference | Test-NxConfigurationState expects the exact 'GpuPreference=<1/2>;' string for the app's value name… | Journaled restore (exact original) | Dep NX04-008; Side: Running instances of the target app keep their current… |
| NX04-003 | Variable Refresh Rate (windowed) | CONDITIONAL | E1 | Set-NxDirectXGlobalSetting | Test-NxConfigurationState verifies the whole composed value… | Journaled restore (exact original) | Side: Running games pick the change up at relaunch… |
| NX04-004 | Auto HDR | CONDITIONAL | E1 | Get-NxAutoHdrReport | Report enumerates displays, shows the observed AutoHDREnable component state (if present)… | None (not shipped) | Defined: not shipped; Side: None (read-only) |
| NX04-005 | Fullscreen Optimizations per-game override | TROUBLESHOOTING | E0 | Get-NxGameFsoOverrideGuide | Get-NxGameFsoState -AppPath <exe> shows the per-app Layers override present… | Owner reverts via documented UI | Defined: not shipped; Side: FSO-off can cost windowed-mode features for that game… |
| NX04-006 | MPO troubleshooting configuration | TROUBLESHOOTING | E0 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState reads OverlayTestMode back as DWord:5… | Journaled restore (exact original) | Restart: Session; Side: Overlay-plane composition off system-wide can raise DWM… |
| NX04-007 | Display presentation configuration | CONDITIONAL | E0 | Get-NxGamePresentationPolicyReport | Report classifies all six policy values with per-value states, names mismatched kinds/values… | None (not shipped) | Defined: not shipped; Side: None (read-only) |
| NX04-008 | Hybrid graphics reporting & app routing | CONDITIONAL | E1 | Get-NxHybridGraphicsReport | Report lists adapters with vendor/VRAM/driver data and current per-app routing… | None (read-only) | Read-only report; Side: None (read-only) |
| NX04-009 | NVIDIA power management mode (per-profile) | CONDITIONAL | E1 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired'… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX (read-only guidance)… |
| NX04-010 | NVIDIA Low Latency Mode (per-profile) | CONDITIONAL | E1 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired', the NVIDIA status snapshot… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX; driver-profile changes in vendor tooling… |
| NX04-011 | NVIDIA vertical sync mode (per-profile) | CONDITIONAL | E1 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired', the NVIDIA status snapshot… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX; driver-profile changes in vendor tooling… |
| NX04-012 | NVIDIA Maximum Frame Rate (per-profile) | CONDITIONAL | E1 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired', the NVIDIA status snapshot… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX; a driver-level cap bounds the profile's… |
| NX04-013 | NVIDIA Threaded Optimization (per-profile) | CONDITIONAL | E1 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired', the NVIDIA status snapshot… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX; per-profile driver changes affect… |
| NX04-014 | NVIDIA texture filtering quality (per-profile) | CONDITIONAL | E1 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired', the NVIDIA status snapshot… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX; filtering changes alter… |
| NX04-015 | NVIDIA shader cache policy | CONDITIONAL | E0 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired', the NVIDIA status snapshot… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX; cache behavior changes made by the owner… |
| NX04-016 | NVIDIA per-game profile framework | CONDITIONAL | E1 | Get-NxVendorGraphicsGuide | Composed guide enumerates every -009..-015 setting with mechanismAvailability='VendorToolRequired'… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Dep NX04-009,NX04-010,NX04-011,NX04-012,NX04-013,NX04-014,NX04-015; Side: None from NEXTRIX; the owner's vendor-tool changes follow… |
| NX04-017 | AMD Radeon Anti-Lag (per-profile) | CONDITIONAL | E1 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired', the Get-NxAmdStatus snapshot… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX; the documented Anti-Lag+ anti-cheat… |
| NX04-018 | AMD Radeon Chill (per-profile) | CONDITIONAL | E1 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired', the AMD status snapshot… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX; Chill bounds the game's frame output… |
| NX04-019 | AMD Enhanced Sync (per-profile) | CONDITIONAL | E1 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired', the AMD status snapshot… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX; Enhanced Sync changes frame-presentation… |
| NX04-020 | AMD Wait for Vertical Refresh (per-profile) | CONDITIONAL | E1 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired', the AMD status snapshot… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX; v-sync changes alter frame-presentation… |
| NX04-021 | AMD Surface Format Optimization | CONDITIONAL | E0 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired', the AMD status snapshot… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX; enabling compressed surface formats… |
| NX04-022 | AMD per-game profile framework + shader cache | CONDITIONAL | E0 | Get-NxVendorGraphicsGuide | Composed guide enumerates every -017..-021 setting with mechanismAvailability='VendorToolRequired'… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Dep NX04-017,NX04-018,NX04-019,NX04-020,NX04-021; Side: None from NEXTRIX; the owner's AMD Software changes follow… |
| NX04-023 | Intel graphics / Arc settings framework | CONDITIONAL | E0 | Get-NxVendorGraphicsGuide | Guide output records mechanismAvailability='VendorToolRequired', the Get-NxIntelStatus snapshot… | None (not shipped) | Defined: not shipped; Guided: vendor tool; Side: None from NEXTRIX; Intel Graphics Software profile changes… |

### 4.6 NX05 — Memory Management (11 entries)

Three entries are read-only reports (NX05-005, -006, -011), and six require a reboot. Pagefile entries conflict with each other and with crash-dump configuration: test only one pagefile shape per snapshot. Disabling the pagefile is TROUBLESHOOTING and can lower the commit limit below installed RAM; treat it as a symptom-specific test, not a default. Verify with `Get-Nx05PagefileState` and real commit figures; do not infer a memory benefit from a registry value.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX05-001 | Normalize pagefile to system-managed | CONDITIONAL | E1 | Set-NxSystemManagedPagefile | Get-Nx05PagefileState re-reads AutomaticManagedPagefile (DWord=1) from the registry and journals… | NX05 rollback (exact originals, only-if-ours) | Conflict NX05-002,NX05-003; Restart: Reboot; Side: Windows may resize the pagefile after restart within… |
| NX05-002 | Custom pagefile configuration | ADVANCED | E1 | Set-NxCustomPagefile | Get-Nx05PagefileState parses the live PagingFiles array and confirms the requested drive entry equals… | NX05 rollback (exact originals, only-if-ours) | Conflict NX05-001,NX05-003; Restart: Reboot; Side: A pagefile whose maximum is below the peak commit demand… |
| NX05-003 | Disable pagefile | TROUBLESHOOTING | E1 | Disable-NxPagefile | Get-Nx05PagefileState confirms AutomaticManagedPagefile is DWord:0 and that no non-empty PagingFiles… | NX05 rollback (exact originals, only-if-ours) | Conflict NX05-001,NX05-002,NX05-009; Restart: Reboot; Side: Commit limit drops to slightly below installed RAM… |
| NX05-004 | Memory compression configuration | ADVANCED | E1 | Set-NxMemoryCompression | Get-MMAgent is re-read and MemoryCompression compared to the requested value… | NX05 rollback (exact originals, only-if-ours) | Side: With compression disabled, more distinct physical pages… |
| NX05-005 | Memory pressure & commit monitoring report | CORE | E1 | Get-NxMemoryPressureReport | The returned object has readOnly=true and carries every value with its source class… | None (read-only) | Read-only report; Side: A single instantaneous sample; peak values outside… |
| NX05-006 | Standby memory diagnostic report | CORE | E1 | Get-NxStandbyMemoryReport | The returned object has readOnly=true, cleanerPresent=false and one entry per page-list bucket… | None (read-only) | Read-only report; Side: Instantaneous sample only; no history, no alerting… |
| NX05-007 | Large System Cache | ADVANCED | E0 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState reads LargeSystemCache back as DWord:1 (configuration verification only… | Journaled restore (exact original) | Restart: Reboot; Side: File-cache bias at the expense of process working sets… |
| NX05-008 | Clear pagefile at shutdown | TROUBLESHOOTING | E1 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState reads ClearPageFileAtShutdown back as DWord:1… | Journaled restore (exact original) | Side: Clean shutdown takes longer in proportion to pagefile size… |
| NX05-009 | Crash dump configuration | CONDITIONAL | E1 | Set-NxCrashDumpConfiguration (dumpType=Automatic) | Test-NxConfigurationState re-reads CrashDumpEnabled as the documented DWord for the chosen type… | NX05 rollback (exact originals, only-if-ours) | Conflict NX05-003; Restart: Reboot; Side: Complete dumps can occupy roughly RAM + 257 MB on the boot… |
| NX05-010 | Pool limit configuration | TROUBLESHOOTING | E0 | Set-NxPoolLimitConfiguration | Each targeted value is re-read with Test-NxConfigurationState and reported per value… | NX05 rollback (exact originals, only-if-ours) | Restart: Reboot; Side: Kernel pool sizing is a global memory-manager parameter… |
| NX05-011 | Memory diagnostics suite | CORE | E1 | Get-NxMemoryDiagnosticsReport | The returned object has readOnly=true and separate sections for mmAgent, ramModules, commit, pagefiles… | None (read-only) | Read-only report; Dep NX05-005,NX05-006; Side: Instantaneous sample; Get-MMAgent state may require… |

### 4.7 NX06 — Storage & Filesystem (13 entries)

Two entries are read-only (NX06-001 inventory, NX06-013 SMART health), four require a reboot, and three cleanup entries are honestly non-reversible (NX06-005 temp files, NX06-006 Windows Update cache, NX06-007 Delivery Optimization cache). Test filesystem changes on a snapshot and on a real SSD; verify `fsutil` output and the registry together. Write-caching changes carry a power-loss trade-off and stay per-device and consent-gated.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX06-001 | Storage inventory & SSD/HDD/NVMe classification | CORE | E1 | Get-NxStorageInventory | Report has readSucceeded=true and at least one physical disk… | None (read-only) | Read-only report; Side: None (read-only storage queries) |
| NX06-002 | TRIM enable & verification | CORE | E1 | Set-NxTrimEnabled (mode=Enable) | fsutil behavior query disabledeletenotify re-parses to 'TrimEnabled' for NTFS… | NX06 rollback (exact originals, only-if-ours) | Side: None expected: enabling delete notification is the Windows… |
| NX06-003 | Optimize Drives schedule configuration | CONDITIONAL | E1 | Set-NxOptimizeDrivesSchedule | Get-ScheduledTask re-read returns the requested MaintenanceSettings Period and Deadline (and Enabled… | NX06 rollback (exact originals, only-if-ours) | Side: Windows may run optimize/retrim maintenance during its idle… |
| NX06-004 | Storage Sense policy configuration | CONDITIONAL | E1 | Set-NxStorageSensePolicy (mode=Enable,cadence=Keep) | Each written policy value is re-read and must equal the requested DWord… | Journaled restore (exact original, only-if-ours) | Side: Documented policy lockdown: with AllowStorageSenseGlobal… |
| NX06-005 | Temporary files cleanup (on-demand) | CONDITIONAL | E1 | Clear-NxTemporaryFiles | Dry-run report lists accepted/refused roots, candidate count and bytes first | Not reversible; documented manual path | Side: Deleted temp files are gone permanently… |
| NX06-006 | Windows Update cache cleanup (on-demand) | CONDITIONAL | E1 | Clear-NxWindowsUpdateCache | Idle verdict is reported before any deletion (busy = Refused, nothing deleted) | Not reversible; documented manual path | Side: Active updates are refused rather than interrupted |
| NX06-007 | Delivery Optimization cache cleanup (on-demand) | CONDITIONAL | E1 | Clear-NxDeliveryOptimizationCache (consent=True) | Cmdlet availability and active job count are reported first… | Not reversible; documented manual path | Side: Cached peer content is removed and may be re-downloaded… |
| NX06-008 | NTFS last-access update policy | CONDITIONAL | E1 | Set-NxNtfsLastAccessPolicy (mode=Disable) | fsutil behavior query disablelastaccess re-parses to the requested low-bit state… | NX06 rollback (exact originals, only-if-ours) | Restart: Reboot; Side: Backup/remote-storage tooling that relies on Last Access… |
| NX06-009 | NTFS 8.3 short-name creation policy | CONDITIONAL | E1 | Set-NxNtfs8dot3Policy (mode=Disable) | fsutil behavior query disable8dot3 re-parses to the requested registry state… | NX06 rollback (exact originals, only-if-ours) | Restart: Reboot; Side: Legacy installers or utilities that depend on 8.3 short… |
| NX06-010 | NTFS memory usage configuration | ADVANCED | E1 | Set-NxNtfsMemoryUsage (mode=Report) | Report mode: current value, raw fsutil output, registry DWord and memory totals… | NX06 rollback (exact originals, only-if-ours) | Restart: Reboot; Side: Increasing NTFS pool memory can reduce pool memory… |
| NX06-011 | Write caching policy (per-device) | CONDITIONAL | E0 | Set-NxWriteCachePolicy (mode=Report) | Report mode: per-disk registry state plus the documented IsDeviceCacheEnabled/IsPowerProtected view… | Journaled restore (exact original, only-if-ours) | Restart: Reboot; Side: POWER-LOSS TRADE-OFF: with write caching enabled… |
| NX06-012 | Disk device power management (storage D3 in Modern Standby) | CONDITIONAL | E1 | Set-NxStorageD3Policy (mode=PreventD3) | The registry value re-reads as the requested DWord (kind DWord)… | Journaled restore (exact original, only-if-ours) | Side: Latency-vs-power trade-off: disabling storage D3 keeps… |
| NX06-013 | Drive health (SMART) report | CORE | E1 | Get-NxDriveHealthReport | Report enumerates every physical disk with health/operational status and a verdict from the documented… | None (read-only) | Read-only report; Side: None (read-only) |

### 4.8 NX07 — Network Optimization (22 entries)

Fourteen entries are above CORE. Every mutation is adapter-parameterized and only-if-present; record the exact adapter name, GUID and driver before testing. Virtual adapters, VPN adapters and disconnected NICs are expected to skip; that is a gate result, not a failure. DNS changes include a resolve-probe verify-and-auto-rollback path. NX07-021 (network stack reset) is explicitly NOT journal-reversible and is a last-resort TROUBLESHOOTING test on a snapshot.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX07-001 | Adapter inventory & capability report | CORE | E1 | Get-Nx07AdapterInventory | Report lists every adapter with its media type, exclusion decision… | None (read-only) | Read-only report; Side: None (read-only) |
| NX07-002 | Adapter power management | CONDITIONAL | E0 | Set-Nx07AdapterPowerManagement | Get-NetAdapterPowerManagement re-read shows every changed property at the requested value… | NX07 rollback (captured values, only-if-ours) | Side: Higher idle power draw / heat when sleep-on-disconnect… |
| NX07-003 | Energy Efficient Ethernet | ADVANCED | E1 | Set-Nx07EnergyEfficientEthernet (enabled=False) | Re-read of the same RegistryKeyword returns the requested RegistryValue… | Only-if-ours restore of captured original | Dep NX07-001; Side: Link-partner dependent behavior; a marginal cable/switch… |
| NX07-004 | Interrupt moderation | ADVANCED | E1 | Set-Nx07InterruptModeration (enabled=False) | Re-read of *InterruptModeration returns the requested value… | Only-if-ours restore of captured original | Dep NX07-001; Side: Vendor-defined behavior; a specific driver may expose only… |
| NX07-005 | Receive Side Scaling configuration | ADVANCED | E1 | Set-Nx07ReceiveSideScaling | Re-read of *RSS (and *MaxRssProcessors when requested) matches the requested/clamped values… | Only-if-ours restore of captured original | Dep NX07-001; Side: Queue distribution is driver- and topology-dependent… |
| NX07-006 | Receive Segment Coalescing | ADVANCED | E1 | Set-Nx07ReceiveSegmentCoalescing (enabled=False) | Per-keyword re-read shows the requested value; absent families are reported as skipped with the probed… | Only-if-ours restore of captured original | Dep NX07-001; Side: Coalescing can interact with capture/filter drivers… |
| NX07-007 | Large Send Offload | ADVANCED | E1 | Set-Nx07LargeSendOffload (enabled=False) | Per-keyword re-read matches the request; absent keywords produce a PropertyNotExposed skip… | Only-if-ours restore of captured original | Dep NX07-001; Side: Documented driver-dependent frame handling… |
| NX07-008 | Checksum offloads (TCP/UDP) | ADVANCED | E1 | Set-Nx07ChecksumOffload (mode=TxRxEnabled) | Every written keyword re-reads to the requested registry value… | Only-if-ours restore of captured original | Dep NX07-001; Side: Disabling checksum offloads moves checksum work to the CPU… |
| NX07-009 | Flow Control | ADVANCED | E1 | Set-Nx07FlowControl (mode=TxRxEnabled) | Re-read of *FlowControl matches the requested registry value… | Only-if-ours restore of captured original | Dep NX07-001; Side: Switch-dependent: a host-side setting cannot guarantee… |
| NX07-010 | Jumbo Frames | ADVANCED | E1 | Set-Nx07JumboFrame (mtu=9014) | Re-read of *JumboPacket equals the enumerated value; the interface MTU is reported separately… | Only-if-ours restore of captured original | Dep NX07-001; Side: Any hop without matching MTU support can drop or fragment… |
| NX07-011 | Receive/Transmit buffer sizing | ADVANCED | E1 | Set-Nx07AdapterBufferSize | Re-read of each written keyword equals the clamped value; the clamp note records requested vs written… | Only-if-ours restore of captured original | Dep NX07-001; Side: Larger buffers reserve more driver/host memory… |
| NX07-012 | Wi-Fi roaming aggressiveness | CONDITIONAL | E1 | Set-Nx07WifiRoamingAggressiveness (aggressiveness=Lowest) | Re-read of the resolved keyword equals the requested driver value… | Only-if-ours restore of captured original | Dep NX07-001; Side: RF-environment dependent: behavior can change near roaming… |
| NX07-013 | Wi-Fi preferred band | CONDITIONAL | E1 | Set-Nx07WifiPreferredBand (band=Prefer5GHz) | Re-read of the resolved keyword matches the requested display/registry value… | Only-if-ours restore of captured original | Dep NX07-001; Side: If the AP does not serve the preferred band… |
| NX07-014 | Wi-Fi channel width | ADVANCED | E1 | Set-Nx07WifiChannelWidth (band=5,width=80) | Re-read of the resolved keyword equals the requested value… | Only-if-ours restore of captured original | Dep NX07-001; Side: AP- and interference-dependent; a width the AP cannot use… |
| NX07-015 | Wi-Fi transmit power | CONDITIONAL | E1 | Set-Nx07WifiTransmitPower (strength=Highest) | Re-read of the resolved keyword matches the requested display value; the driver's level list is reported | Only-if-ours restore of captured original | Dep NX07-001; Side: Regulatory/driver caps apply; lower power can reduce usable… |
| NX07-016 | DNS configuration | CONDITIONAL | E1 | Set-Nx07DnsConfiguration | Re-read proves the interface's server lists equal the requested ones AND Resolve-DnsName answered… | Only-if-ours restore of captured original | Conflict NX07-021; Side: A non-answering resolver is rolled back automatically… |
| NX07-017 | TCP auto-tuning & ECN inspection/config | ADVANCED | E1 | Set-Nx07TcpGlobalSetting | Re-parsed `netsh int tcp show global` matches each requested value… | Only-if-ours restore of captured original | Conflict NX07-021; Side: A non-default auto-tuning level or ECN mode changes stack… |
| NX07-018 | MTU inspection & configuration | TROUBLESHOOTING | E1 | Set-Nx07InterfaceMtu | Re-read of Get-NetIPInterface returns the requested NlMtuBytes for the target interface/family… | Only-if-ours restore of captured original | Conflict NX07-021; Side: An MTU above what the path supports can drop large packets… |
| NX07-019 | Network diagnostics report | CORE | E1 | Get-Nx07NetworkDiagnosticReport | Report carries readOnly=true, every adapter with counters, the IP/route/DNS sections… | None (read-only) | Read-only report; Side: None (read-only) |
| NX07-020 | DNS cache management | TROUBLESHOOTING | E1 | Clear-Nx07DnsCache | Clear-DnsClientCache succeeded and the entry count is 0 (Verified) or non-zero with a Partial note… | None - transient operation | Conflict NX07-021; Side: Next resolutions are uncached until the cache warms again… |
| NX07-021 | Network stack reset | TROUBLESHOOTING | E1 | Invoke-Nx07NetworkStackReset | Each reset command's exit code is recorded; the verify entry is Success-Irreversible with RebootRequired… | NOT journal-reversible; documented manual path | Conflict NX07-016,NX07-017,NX07-018,NX07-020; Restart: Reboot; Side: Network briefly disconnects; adapters re-enumerate |
| NX07-022 | Per-game QoS/DSCP profile | CONDITIONAL | E0 | Set-Nx07GameQosProfile | Get-NetQosPolicy -Name <recorded name> -PolicyStore <computer> returns a policy whose application path… | Removes only the recorded policy (only-if-ours) | Side: Marking is effective only if network equipment honors DSCP… |

### 4.9 NX08 — Input & Peripherals (8 entries)

Three entries are read-only (NX08-003 polling rate, NX08-005 controllers, NX08-007 USB/HID inventory); two require a reboot (NX08-006 Bluetooth power policy, NX08-008 data-queue size). Peripherals may be absent in a VM, in which case the entry should report an uncertain/absent state rather than fail. Test input changes with the real device and record the device model; do not convert a configuration change into a polling-rate or latency claim.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX08-001 | Disable Enhance Pointer Precision | CONDITIONAL | E0 | Set-NxMouseAcceleration | Set-NxMouseAcceleration re-reads each written value with Test-NxConfigurationState and journals a verify… | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: With acceleration off, fast physical movements no longer… |
| NX08-002 | Mouse pointer speed/sensitivity | CONDITIONAL | E0 | Set-NxMousePointerSpeed (mouseSensitivity=10) | Set-NxMousePointerSpeed re-reads MouseSensitivity with Test-NxConfigurationState (kind String)… | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: Pointer distance per physical motion changes… |
| NX08-003 | Mouse polling rate inspection | CORE | E0 | Get-NxMousePollingRateReport | Report carries readOnly=true, noWritesPerformed=true, one entry per Win32_PointingDevice row… | None (read-only) | Read-only report; Side: None (read-only) |
| NX08-004 | Keyboard repeat delay/rate | CONDITIONAL | E1 | Set-NxKeyboardRepeat | Set-NxKeyboardRepeat re-reads both values with Test-NxConfigurationState (kind String) and journals… | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: A shorter repeat delay and higher repeat rate produce more… |
| NX08-005 | Game controller inspection & configuration | CONDITIONAL | E0 | Get-NxGameControllerReport | Report carries readOnly=true, noWritesPerformed=true, controllerCount… | None (read-only) | Read-only report; Side: None (read-only); no controller, driver… |
| NX08-006 | Bluetooth peripheral inspection & power policy | CONDITIONAL | E1 | Set-NxBluetoothPowerPolicy (remoteWake=Disabled) | Every planned value is re-read with Test-NxConfigurationState and journaled… | Journaled restore (exact original, only-if-ours) | Restart: Reboot; Side: With remote wake disabled, a Bluetooth keyboard or mouse… |
| NX08-007 | USB controller & HID device inspection | CORE | E1 | Get-NxUsbHidReport | Report carries readOnly=true, noWritesPerformed=true, controllerCount, controllerAssociations… | None (read-only) | Read-only report; Side: None (read-only); no device is disabled… |
| NX08-008 | Mouse/keyboard data-queue size configuration | CONDITIONAL | E0 | Set-NxDataQueueSize (device=Both,queueSize=16) | Each written value is re-read with Test-NxConfigurationState (kind DWord) and journaled… | Journaled restore (exact original, only-if-ours) | Restart: Reboot; Side: A shallower input queue buffers fewer entries… |

### 4.10 NX09 — Power Management (15 entries)

Four entries are read-only (NX09-011 OEM battery conservation, NX09-012 OEM performance mode, NX09-014 energy report, NX09-015 battery report). Every setting that has AC and DC planes must be tested on both; the journal records them separately. Never delete the active or a stock power plan: NX09-002/-003 create plans and rollback deletes only the created GUID, while NX09-013 deletes only the imported plan. Hibernate and Fast Startup change boot/sleep behaviour and may need a restart to observe. On Modern Standby (S0ix) systems, classic plan settings can be partially ignored — record that as an observed platform limitation, not a tweak pass or fail.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX09-001 | Active power plan selection | CONDITIONAL | E1 | Set-NxActivePowerPlan | Get-NxActivePowerScheme re-read returns the selected GUID; the journal verify entry records Verified… | Restores prior active plan (only-if-ours) | Side: The switch is immediate and applies to both AC and DC… |
| NX09-002 | Ultimate Performance provisioning | CONDITIONAL | E1 | Add-NxUltimatePerformancePlan | powercfg /list parse shows the NEXTRIX GUID with the NEXTRIX plan name… | Deletes only the created plan (never active/stock) | Side: One additional power scheme appears in the picker… |
| NX09-003 | Custom NEXTRIX plan generation | CONDITIONAL | E1 | New-NxCustomPowerPlan | powercfg /list shows the created plan with the NEXTRIX name… | Deletes only the created plan (never active/stock) | Side: One additional power scheme appears… |
| NX09-004 | PCIe ASPM link policy | CONDITIONAL | E1 | Set-NxPcieAspm | powercfg /query re-read of the setting returns the chosen AC and DC indexes… | NX09 rollback (AC/DC originals, only-if-ours) | Side: ASPM changes apply to all PCIe devices honoring the plan… |
| NX09-005 | USB selective suspend policy | CONDITIONAL | E1 | Set-NxUsbSelectiveSuspend | powercfg /query re-read returns the chosen AC and DC indexes… | NX09 rollback (AC/DC originals, only-if-ours) | Side: Disabling suspend keeps USB controllers active (power… |
| NX09-006 | Display timeout configuration | CONDITIONAL | E1 | Set-NxDisplayTimeout | powercfg /query re-read returns the chosen AC and DC second values… | NX09 rollback (AC/DC originals, only-if-ours) | Side: A zero display timeout (never off) increases idle power… |
| NX09-007 | Sleep configuration | CONDITIONAL | E1 | Set-NxSleepTimeout | powercfg /query re-read returns the chosen AC and DC second values… | NX09 rollback (AC/DC originals, only-if-ours) | Side: Zero standby timeout keeps the machine from sleeping… |
| NX09-008 | Hibernate configuration | CONDITIONAL | E1 | Set-NxHibernate (enabled=False) | HibernateEnabled re-capture equals the chosen value; journal verify entry records Verified… | Restores journaled hibernate direction (only-if-ours) | Side: Toggling /h creates or deletes hiberfil.sys (disk space… |
| NX09-009 | Fast Startup configuration | CONDITIONAL | E1 | Set-NxFastStartup (enabled=False) | Test-NxConfigurationState read-back of HiberbootEnabled equals the chosen DWord… | Journaled restore (exact original, only-if-ours) | Side: Fast Startup changes next-boot behavior only (no restart… |
| NX09-010 | Lid close behavior (laptops) | CONDITIONAL | E1 | Set-NxLidCloseAction | powercfg /query re-read returns the chosen AC and DC lid action indexes… | NX09 rollback (AC/DC originals, only-if-ours) | Side: 'Do nothing' on AC keeps the machine running hot… |
| NX09-011 | OEM battery conservation reporting | CORE | E0 | Get-NxOemBatteryConservationState | Report enumerates every probe with interfaceDetected, state (Unknown unless documented)… | None (read-only) | Read-only report; Side: None (read-only; existence-level probes only) |
| NX09-012 | OEM performance mode detection | CORE | E0 | Get-NxOemPerformanceMode | Report lists matched services with display names and status; modeState=Unknown with uncertainty note… | None (read-only) | Read-only report; Side: None (read-only service enumeration) |
| NX09-013 | Power plan export/import/restore tooling | CORE | E1 | Export-NxPowerPlan + Import-NxPowerPlan | Export: the .pow file exists at the chosen path with non-zero size and is journaled… | Deletes only the imported plan (export retained) | Side: Files land only at user-chosen paths… |
| NX09-014 | Energy report (powercfg /energy) | CORE | E1 | Invoke-NxEnergyReport | The .htm report exists at the chosen folder with non-zero size… | None (read-only) | Read-only report; Side: Takes at least the configured duration to observe… |
| NX09-015 | Battery report (powercfg /batteryreport) | CORE | E1 | Invoke-NxBatteryReport | The .html report exists at the chosen folder with non-zero size… | None (read-only) | Read-only report; Side: Writes one report file to the user-chosen folder |

### 4.11 NX10 — Thermal Management (8 entries)

All eight entries are read-only. They read firmware/WMI/performance-counter sources and must report `Uncertain` when a source is absent rather than guessing. In a VM, most sensors are unavailable: that is a valid `Uncertain` result, not a failure. NX10-008 writes a CSV at the owner-chosen path (thermal session logging) and is additive. No entry writes firmware, fan curves or power limits.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX10-001 | CPU temperature & throttling detection report | CORE | E1 | Get-NxCpuThermalReport | Report carries three temperature source records, each with source/evidence/limitation/state… | None (read-only) | Read-only report; Side: Brief WMI queries and two performance-counter reads… |
| NX10-002 | GPU temperature & throttling report | CORE | E1 | Get-NxGpuThermalReport (timeoutMs=10000) | Report lists every adapter with a temperatureState; NVIDIA adapters show a numeric temperature… | None (read-only) | Read-only report; Side: Runs nvidia-smi with a bounded timeout (killed… |
| NX10-003 | CPU power-limit monitoring | CONDITIONAL | E0 | Get-NxCpuPowerLimitReport | powerLimit.state is 'Uncertain-VendorDependent' with pl1Watts/pl2Watts null and a stated reason… | None (read-only) | Read-only report; Side: Three read-only powercfg /query calls and a service… |
| NX10-004 | GPU power-limit monitoring | CONDITIONAL | E0 | Get-NxGpuPowerLimitReport (timeoutMs=10000) | Each NVIDIA GPU record reports numeric-or-null power fields (never a guessed value) with a state… | None (read-only) | Read-only report; Side: One bounded nvidia-smi query; no configuration or firmware… |
| NX10-005 | Fan speed monitoring (where exposed) | CONDITIONAL | E0 | Get-NxFanSpeedReport (timeoutMs=10000) | Every fan record has source/speedKind/state; an empty result yields state 'Uncertain-Unavailable'… | None (read-only) | Read-only report; Side: None beyond a read-only WMI query and one bounded… |
| NX10-006 | OEM fan/cooling profile detection | CONDITIONAL | E0 | Get-NxOemCoolingProfile | Every OEM record reports namespacesProbed, namespacesPresent, thermalFanClasses, matchingServices… | None (read-only) | Read-only report; Side: Namespace class enumeration on OEM management namespaces… |
| NX10-007 | AC/DC thermal behavior report | CONDITIONAL | E0 | Get-NxAcDcThermalReport | powerSource.current is AC/Battery/Uncertain-Unavailable; each thermalPolicy plane state… | None (read-only) | Read-only report; Side: Five read-only powercfg calls plus WMI reads |
| NX10-008 | Thermal session logging for owner testing | CORE | E0 | Invoke-NxThermalSessionLog | The chosen file exists with the provenance comment, header and >=1 data row; result reports sampleRows… | None - transient operation | Read-only report; Side: Writes one CSV file at the owner-chosen path… |

### 4.12 NX11 — Background Activity & Services (19 entries)

Four entries are read-only or plan-only: NX11-005 task inventory, NX11-007 resource-heavy processes, NX11-011 Print Spooler report (`Defined`), NX11-019 service dependency engine. The service entries are detection-gated and never blanket: each has an unused-condition and a dependency check. Test one service at a time, then launch the dependent application. Never-touch services (update stack, security, audio, firewall, Store, VSS and the validator list) must be refused, not reconfigured. `bam` and the Xbox service set have documented cross-effects.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX11-001 | Startup app inventory & selective management | CORE | E1 | Get-NxStartupInventory (includeWmi=True) | Inventory lists each item with approvalState; after Set-NxStartupItemState the marker is re-read… | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: A disabled startup app does not run at user sign-in… |
| NX11-002 | Per-app background permissions (UWP) | CONDITIONAL | E0 | Get-NxAppPermissionInventory (maxPackages=200) | After Set-NxAppPermission, each changed list is re-read via Test-NxConfigurationState and must equal… | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: A denied app stops background updates… |
| NX11-003 | Edge background mode disable | CONDITIONAL | E1 | Set-NxEdgeBackgroundMode (mode=Disable,scope=User) | Read-back of BackgroundModeEnabled equals 0 at the chosen scope; verify journaled | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: While Edge is closed, background extensions and background… |
| NX11-004 | Edge startup boost disable | CONDITIONAL | E1 | Set-NxEdgeStartupBoost (mode=Disable,scope=User) | Read-back of StartupBoostEnabled equals 0 at the chosen scope; verify journaled | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: Edge no longer preloads at sign-in… |
| NX11-005 | Scheduled task inventory report | CORE | E1 | Get-NxScheduledTaskInventory | Report returns cmdletAvailable=true and a task array with states… | None (read-only) | Read-only report; Side: None on task state (read-only) |
| NX11-006 | Selective scheduled task management | CONDITIONAL | E0 | Get-NxScheduledTaskCandidates | Set-NxScheduledTaskState re-reads the task state after each fallback… | NX11 rollback (startup/state originals) | Dep NX11-005; Side: The disabled task stops performing… |
| NX11-007 | Resource-heavy process identification report | CORE | E1 | Get-NxResourceHeavyProcessReport (top=15,sampleSeconds=0) | Report contains topByWorkingSet and topByCpuTime arrays; processCount matches the enumerated process… | None (read-only) | Read-only report; Side: None on processes; -SampleSeconds briefly waits to collect… |
| NX11-008 | Windows Search service configuration | CONDITIONAL | E1 | Set-NxSearchServiceConfig | Start read-back equals the requested startup type; when -StopService is used the status must also… | NX11 rollback (startup/state originals) | Dep NX11-019; Side: Manual keeps search/indexing available on demand without… |
| NX11-009 | SysMain service configuration | CONDITIONAL | E1 | Set-NxSysMainConfig | Start read-back equals the requested startup type; detection values (RAM GB… | NX11 rollback (startup/state originals) | Dep NX11-019; Side: On <16 GB systems, disabling SysMain can increase hard… |
| NX11-010 | Xbox services configuration | CONDITIONAL | E1 | Set-NxXboxServicesConfig | Per-service start read-back equals the requested type; dependency verdicts and detection evidence are… | NX11 rollback (startup/state originals) | Dep NX11-019; Conflict NX12-005; Side: Xbox accessory management and Xbox Live networking features… |
| NX11-011 | Print Spooler configuration | CONDITIONAL | E1 | Get-NxPrintSpoolerReport | Report returns readOnly=true, neverTouch=true and mutationAvailable=false… | None (not shipped) | Defined: not shipped; Side: None (read-only) |
| NX11-012 | Bluetooth service configuration | CONDITIONAL | E1 | Set-NxBluetoothServiceConfig | Per-service Start read-back equals the requested type; detection evidence and gates are reported… | NX11 rollback (startup/state originals) | Dep NX11-019; Side: Bluetooth peripherals stop working when the services are… |
| NX11-013 | Fax service configuration | CONDITIONAL | E1 | Set-NxFaxServiceConfig | Start read-back equals the requested startup type; detection evidence and dependency verdict are… | NX11 rollback (startup/state originals) | Dep NX11-019; Side: Fax send/receive through this service stops while disabled |
| NX11-014 | Remote Registry configuration | CONDITIONAL | E1 | Set-NxRemoteRegistryConfig | Start read-back equals Disabled; dependency verdict is reported; verify journaled | NX11 rollback (startup/state originals) | Dep NX11-019; Side: Remote registry tools and some enterprise management… |
| NX11-015 | Windows Error Reporting configuration | CONDITIONAL | E0 | Set-NxWerReportingConfig (mode=Disable) | Read-back of the policy Disabled value equals 1 (or 0 on the Enable path); verify journaled | Journaled restore (exact original, only-if-ours) | Side: Crash reports and WER queue data stop being collected/sent… |
| NX11-016 | Maps-related services configuration | CONDITIONAL | E0 | Set-NxMapsServiceConfig | Start read-back equals the requested startup type; offline-map evidence and gate outcome are reported… | NX11 rollback (startup/state originals) | Dep NX11-019; Side: With MapsBroker disabled, offline map updates… |
| NX11-017 | DiagTrack (Connected User Experiences) configuration | CONDITIONAL | E0 | Set-NxDiagTrackConfig | Start read-back equals the requested startup type; dependency verdict is reported; verify journaled | NX11 rollback (startup/state originals) | Dep NX11-019; Side: Xbox achievements and Feedback Hub can be affected… |
| NX11-018 | Third-party service inventory & selective configuration | CONDITIONAL | E1 | Get-NxThirdPartyServiceInventory (maxItems=400) | Inventory lists non-Microsoft services only; Set-NxThirdPartyServiceConfig re-reads the Start value… | NX11 rollback (startup/state originals) | Dep NX11-019; Side: Changing a vendor service can break the vendor application… |
| NX11-019 | Service dependency inspection engine | CORE | E1 | Get-NxServiceDependencyReport | Detailed mode returns service, startType, requiredServices, dependentServices, runningDependents… | None (read-only) | Read-only report; Side: None (read-only) |

### 4.13 NX12 — Windows Debloating (14 entries)

**This build's NX12 apply action surfaces the safe removal plan (`Get-Nx12RemovalPlan`), not the removal write.** The guarded removal functions exist but require explicit-selection wiring (`KNOWN_ISSUES.md` 13). Test the plan, the protected-dependency guard, the scope report and the reinstall ledger. Nine entries are honestly labeled non-journal-reversible once removal is wired; removal is the least reversible class in the registry. Do not hand-invoke removal functions unless the owner explicitly chooses a destructive drill on a disposable snapshot. Verify protected dependencies (Store, WebView2, App Installer, VCLibs) before and after any removal drill.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX12-001 | Consumer app inventory & selective removal | CONDITIONAL | E1 | Get-Nx12RemovalPlan (family=Consumer) | Plan lists the catalog with installed/provisioned/protected/dependent state; after a selected removal… | NOT journal-reversible; documented manual path | Dep NX12-002,NX12-014; Side: The selected app and its Start entry disappear… |
| NX12-002 | Protected-dependency guard | CORE | E1 | Get-NxProtectedDependencyReport | Report returns readOnly=true with rules, findings and guard probes; Microsoft.WindowsStore… | None (read-only) | Read-only report; Side: Protected packages cannot be selected for removal by any… |
| NX12-003 | OEM/promotional third-party app removal | CONDITIONAL | E1 | Get-Nx12RemovalPlan (family=Oem) | Plan lists nominated candidates with publisher/provisioned/promo reason… | NOT journal-reversible; documented manual path | Dep NX12-002,NX12-014; Side: The vendor app and its integrations (e.g |
| NX12-004 | Phone Link removal (optional) | CONDITIONAL | E1 | Get-Nx12RemovalPlan (family=PhoneLink) | Plan shows Microsoft.YourPhone present/absent and protected=false… | NOT journal-reversible; documented manual path | Dep NX12-002,NX12-014; Conflict NX13-012; Side: Phone Link, its Start entry and phone-screen/messaging… |
| NX12-005 | Xbox app removal (optional) | CONDITIONAL | E1 | Get-Nx12RemovalPlan (family=Xbox) | Plan reports Game Pass evidence and candidate state; removal refuses when strong Game Pass evidence… | NOT journal-reversible; documented manual path | Dep NX12-002,NX12-014; Conflict NX02-008,NX11-010; Side: The Xbox app UI, its game-library entry point… |
| NX12-006 | Copilot / AI feature configuration | CONDITIONAL | E0 | Get-Nx12RemovalPlan (family=Copilot) | Function reports build scope and package presence; absent package -> Skipped-NotFound… | NOT journal-reversible; documented manual path | Dep NX12-002,NX12-014; Side: The Copilot app and its app-level entry points disappear… |
| NX12-007 | Communication apps optional removal | CONDITIONAL | E1 | Get-Nx12RemovalPlan (family=Communications) | Plan shows each communication app with present/protected/dependent state and the Teams acknowledgement… | NOT journal-reversible; documented manual path | Dep NX12-002,NX12-014; Side: Selected clients and their Start entries disappear… |
| NX12-008 | Removal scope control (per-user / all-users) | CONDITIONAL | E1 | Get-NxRemovalScopeReport | Report returns readOnly=true, per-package current/all-users/provisioned rows and the three scope… | None (read-only) | Read-only report; Side: None (read-only) |
| NX12-009 | Provisioned package removal control | CONDITIONAL | E1 | Get-Nx12RemovalPlan (family=Provisioned) | Plan lists provisioned identities with protected flags; after removal Get-AppxProvisionedPackage -Online… | NOT journal-reversible; documented manual path | Dep NX12-002,NX12-014; Side: New user profiles will not receive the removed package… |
| NX12-010 | Removal history & reversibility ledger | CORE | E1 | Get-NxRemovalLedger | Ledger returns readOnly=true, per-item labels/status/reinstall routes and counts… | None (read-only) | Read-only report; Side: None (read-only) |
| NX12-011 | Reinstallation helper (Store-based) | CORE | E1 | Restore-NxRemovedApp (mode=Report) | Report mode lists removed items with Store/library and winget-search routes and is read-only… | Additive; remove the app again to undo | Dep NX12-010; Side: Install mode uses the network and Microsoft Store/App… |
| NX12-012 | Windows capabilities selective removal | CONDITIONAL | E1 | Get-NxOptionalCapabilityInventory | Inventory returns the allow-list with state/usage/reinstall routes… | NOT journal-reversible; documented manual path | Dep NX12-002,NX12-014; Side: The selected capability's feature disappears until… |
| NX12-013 | New-user app provisioning policy | CONDITIONAL | E1 | Get-Nx12RemovalPlan | Plan lists families with per-package provisioned/installed/protected state… | NOT journal-reversible; documented manual path | Dep NX12-002,NX12-014; Side: New profiles created after apply will not receive… |
| NX12-014 | AppX dependency graph verification engine | CORE | E1 | Get-NxAppxDependencyGraph | Report returns readOnly=true with node/edge counts, protected node count, anomalies and focus verdicts… | None (read-only) | Read-only report; Side: None when used as a report |

### 4.14 NX13 — Privacy & Telemetry (14 entries)

One entry is read-only (NX13-014 permission audit). Diagnostic-data level is edition-aware: Home/Pro stop at the documented Required floor rather than 0; record the edition. Task changes are selective and re-read per task. Cross-device experiences conflict with Phone Link removal (NX12-004). These are privacy changes; a configuration pass is not a privacy audit and must not be described as a performance change.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX13-001 | Advertising ID disable | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms both values are DWord as proposed after apply… | Journaled restore (exact original, only-if-ours) | Side: Ads shown by apps are no longer personalized… |
| NX13-002 | Activity history disable | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×3 | Test-NxConfigurationState confirms all three values are DWord 0 after apply… | Journaled restore (exact original, only-if-ours) | Side: Activity history is no longer stored/roamed/uploaded… |
| NX13-003 | Tailored experiences disable | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms the value is DWord 1 after apply… | Journaled restore (exact original, only-if-ours) | Side: Recommendations, tips and offers still appear but are no… |
| NX13-004 | Diagnostic data level (edition-aware documented floor) | CONDITIONAL | E1 | Set-NxDiagnosticDataLevel (level=Minimal) | The function re-reads every written value via Test-NxConfigurationState and journals one verify entry… | Journaled restore (exact original, only-if-ours) | Side: On Home/Pro the diagnostics level stops at Required (1)… |
| NX13-005 | App permission defaults (location/camera/microphone/contacts/calendar) | CONDITIONAL | E1 | Set-NxAppPermissionDefaults | The function re-reads each written value (Test-NxConfigurationState) and journals a verify entry per… | Journaled restore (exact original, only-if-ours) | Side: Force-deny blocks Windows (packaged) apps… |
| NX13-006 | App launch tracking policy (non-Start_Track) | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms NoInstrumentation is DWord 1 after apply… | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: Windows no longer records program usage for Start/search… |
| NX13-007 | General consent & ad-personalization toggles | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms both values are DWord 1 after apply… | Journaled restore (exact original, only-if-ours) | Side: Websites no longer receive the user's language list… |
| NX13-008 | Feedback frequency configuration | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×3 | Test-NxConfigurationState confirms all three values are DWord as proposed… | Journaled restore (exact original, only-if-ours) | Side: Windows stops asking for feedback; the user can still send… |
| NX13-009 | Inking & typing personalization policy | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms both values are DWord 1 after apply… | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: Handwriting-recognition and typing-suggestion… |
| NX13-010 | Cloud content search preferences | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms both values are DWord 0 after apply… | Journaled restore (exact original, only-if-ours) | Side: No web/Bing answers and no OneDrive/SharePoint cloud… |
| NX13-011 | Clipboard history configuration | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms both values are DWord 0… | Journaled restore (exact original, only-if-ours) | Side: Clipboard history (Win+V) retains nothing new… |
| NX13-012 | Cross-device experiences configuration | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms both values are DWord 0… | Journaled restore (exact original, only-if-ours) | Conflict NX12-004; Restart: Reboot; Side: No phone-PC linking / Continue-on-PC experiences… |
| NX13-013 | Telemetry-related scheduled tasks (selective) | CONDITIONAL | E0 | Set-NxTelemetryTasks | The function re-reads each task's State via Get-ScheduledTask and journals Disabled/Unchanged per task… | NX13 rollback (task states, only-if-ours) | Side: Compatibility appraisal, CEIP uploads and feedback-prompt… |
| NX13-014 | Permission audit report | CORE | E1 | Get-NxPrivacyAuditReport | The report object has readOnly=true, a non-empty findings array… | None (read-only) | Read-only report; Side: None (read-only registry/CIM reads… |

### 4.15 NX14 — Security Configuration (15 entries)

Eight entries are read-only reports. Four require a reboot (NX14-003 UAC, NX14-008 Memory Integrity, NX14-013 Windows Sandbox, NX14-014 Hyper-V/virtualization). No mutation may lower protection: Controlled Folder Access is Enabled/Audit with Off omitted; SmartScreen stays on; UAC changes elevation prompts, not the enable/disable policy. Test Hyper-V/WSL2-dependent workloads before and after NX14-014, and verify Defender/Firewall health after any security-area change. `ExplicitConsent` evidence is mandatory for the consent-gated entries.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX14-001 | Defender status & health report | CORE | E1 | Get-Nx14DefenderStatusReport | The returned object has readOnly=true, a defender.statusRead flag… | None (read-only) | Read-only report; Side: A few seconds of Defender WMI queries… |
| NX14-002 | Firewall status & profile report | CORE | E1 | Get-Nx14FirewallStatusReport | The returned object has readOnly=true, one row per profile and explicit statusRead/reason fields… | None (read-only) | Read-only report; Side: Negligible - profile metadata query only |
| NX14-003 | UAC level configuration | CONDITIONAL | E1 | Set-Nx14UacLevel (level=Default) | Each of the three values is re-read through Test-NxConfigurationState after the write… | Journaled restore (exact original, only-if-ours) | Restart: Reboot; Side: Elevation prompts for administrators change according… |
| NX14-004 | SmartScreen configuration | CONDITIONAL | E1 | Set-Nx14SmartScreen (level=Warn) | EnableSmartScreen (DWord 1) and ShellSmartScreenLevel (String Warn/Block) are re-read after the write… | Journaled restore (exact original, only-if-ours) | Side: Policy-managed machines show the policy as set by NEXTRIX… |
| NX14-005 | Secure Boot status report | CORE | E1 | Get-Nx14SecureBootStatus | The report carries readOnly=true, supported, secureBootEnabled and firmwareType… | None (read-only) | Read-only report; Side: None (read-only) |
| NX14-006 | TPM status report | CORE | E1 | Get-Nx14TpmStatus | The report carries readOnly=true and a statusRead flag; unsupported/denied cases carry a reason (never… | None (read-only) | Read-only report; Side: None (read-only) |
| NX14-007 | VBS / HVCI status report | CORE | E1 | Get-Nx14DeviceGuardStatus | The report carries readOnly=true, vbsStatus text, configured/running service name arrays… | None (read-only) | Read-only report; Side: None (read-only) |
| NX14-008 | Memory Integrity consent-gated configuration | ADVANCED | E1 | Set-Nx14MemoryIntegrity | The Enabled value is re-read after the write; a read-back of 1 yields Verified-RestartPending… | Journaled restore (exact original, only-if-ours) | Dep NX14-007; Restart: Reboot; Side: A restart is required before Memory Integrity is effective |
| NX14-009 | Credential Guard status report | CORE | E1 | Get-Nx14CredentialGuardStatus | The report has readOnly=true, configured/running booleans, the policy value text and an uncertainty… | None (read-only) | Read-only report; Dep NX14-007; Side: None (read-only; no credential or secret access) |
| NX14-010 | Controlled Folder Access configuration | CONDITIONAL | E1 | Set-Nx14ControlledFolderAccess (mode=Enabled) | The preference is re-read after the change: mode equals the requested value and the allow-list contains… | NX14 rollback (delegated originals) | Dep NX14-001; Side: Apps the owner has not allowed can no longer write… |
| NX14-011 | Exploit Protection report & selective policy | ADVANCED | E1 | Get-Nx14ExploitProtectionReport | The report carries readOnly=true and per-family rows; the opt-in path re-reads each selected mitigation… | NX14 rollback (delegated originals) | Side: Per-process mitigations can break an application… |
| NX14-012 | BitLocker status report | CORE | E1 | Get-Nx14BitLockerStatus | The report has readOnly=true, one row per volume, protector TYPE names only… | None (read-only) | Read-only report; Dep NX14-006; Side: None beyond metadata queries; no secret is read or emitted |
| NX14-013 | Windows Sandbox provisioning | CONDITIONAL | E1 | Set-Nx14WindowsSandbox (state=Enabled) | The feature is re-read after the change; Enabled or EnablePending yields… | NX14 rollback (delegated originals) | Dep NX01-015; Restart: Reboot; Side: A restart is required before Windows Sandbox is usable |
| NX14-014 | Hyper-V / virtualization platform configuration | ADVANCED | E1 | Get-Nx14VirtualizationPlatformStatus | The read-only report lists each component state and detected consumers… | NX14 rollback (delegated originals) | Dep NX01-015; Restart: Reboot; Side: Disabling Hyper-V/VirtualMachinePlatform breaks WSL2… |
| NX14-015 | Windows Security health aggregate report | CORE | E1 | Get-Nx14SecurityHealthReport | The report has readOnly=true, one area row per covered report, merged uncertainty… | None (read-only) | Read-only report; Dep NX14-001,NX14-002,NX14-005,NX14-006,NX14-007,NX14-009,NX14-010,NX14-012; Side: A few seconds of read-only queries across the security… |

### 4.16 NX15 — Visual & Interface (14 entries)

One entry is `Defined` and plan-only (NX15-009 context menu). The rest are cosmetic registry changes; none is a performance entry. Several are per-user and need a session restart or Explorer restart to observe. UCPD can protect some taskbar values on newer builds; the registry entry should use a policy-path fallback or report the protected state, and the tester must not fight UCPD. Verify readability and usability, not just the value.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX15-001 | Visual effects policy (animations set) | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms TurnOffSPIAnimations is DWord 1 after apply… | Journaled restore (exact original, only-if-ours) | Side: Window, menu and control animations no longer play… |
| NX15-002 | Transparency effects | CONDITIONAL | E0 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms EnableTransparency is DWord 0 after apply… | Journaled restore (exact original, only-if-ours) | Side: Start, taskbar and supported app surfaces render opaque… |
| NX15-003 | Window shadows & menu show delay | CONDITIONAL | E0 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms MenuShowDelay is String '0' after apply… | Journaled restore (exact original, only-if-ours) | Side: Menus open immediately on hover instead of after… |
| NX15-004 | Taskbar configuration set | CONDITIONAL | E0 | Set-NxTaskbarConfiguration | Set-NxTaskbarConfiguration re-reads every written value with Test-NxConfigurationState and journals… | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: Taskbar icons move left; the search box and Task View… |
| NX15-005 | Start menu recommendations configuration | CONDITIONAL | E0 | Set-NxStartRecommendations | Set-NxStartRecommendations re-reads each layer with Test-NxConfigurationState and journals a verify… | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: The Start Recommended section no longer appears… |
| NX15-006 | Explorer configuration set | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms LaunchTo and SeparateProcess are DWord 1 after apply… | Journaled restore (exact original, only-if-ours) | Side: File Explorer opens at This PC instead of Home |
| NX15-007 | File extension visibility | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms HideFileExt is DWord 0 after apply… | Journaled restore (exact original, only-if-ours) | Side: File name extensions are shown for all files in File… |
| NX15-008 | Hidden files visibility | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms Hidden is DWord 1 after apply… | Journaled restore (exact original, only-if-ours) | Side: Ordinary hidden files and folders become visible in File… |
| NX15-009 | Context menu configuration (classic / new) | CONDITIONAL | E0 | Get-NxContextMenuState | Get-NxContextMenuState reports build class (22H2/23H2 vs 24H2+), CLSID key presence… | None (not shipped) | Defined: not shipped; Side: None in v0.1 (defined only; the apply action performs… |
| NX15-010 | Explorer compact view | CONDITIONAL | E1 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms UseCompactMode is DWord 1 after apply… | Journaled restore (exact original, only-if-ours) | Side: File Explorer item views use tighter spacing… |
| NX15-011 | Notification Center configuration | CONDITIONAL | E0 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms DisableNotificationCenter is DWord 1 after apply… | Journaled restore (exact original, only-if-ours) | Restart: Session; Side: The notification center panel and its history are… |
| NX15-012 | Lock screen configuration (image vs Spotlight) | CONDITIONAL | E0 | Invoke-NxRegistryTweak ×1 | Test-NxConfigurationState confirms RotatingLockScreenEnabled is DWord 0 after apply… | Journaled restore (exact original, only-if-ours) | Side: The lock screen stops rotating Windows Spotlight images… |
| NX15-013 | Desktop icon configuration | CONDITIONAL | E0 | Invoke-NxRegistryTweak ×3 | Test-NxConfigurationState confirms HideIcons is DWord 0 and both GUID values are DWord 0… | Journaled restore (exact original, only-if-ours) | Side: Desktop icons are visible; This PC and Recycle Bin are… |
| NX15-014 | Font smoothing configuration | CONDITIONAL | E0 | Invoke-NxRegistryTweak ×2 | Test-NxConfigurationState confirms FontSmoothing is String '2' and FontSmoothingType is DWord 2… | Journaled restore (exact original, only-if-ours) | Side: Text uses ClearType subpixel smoothing… |

### 4.17 NX16 — Maintenance & Recovery (17 entries)

Test this category first: it is the recovery substrate every other category depends on. Nine entries are read-only or additive: registry/service/task backups, pre-flight, DISM/SFC checks, driver inventory, build report and the support bundle. NX16-002 and NX16-001 are additive recovery changes. NX16-009 component cleanup and NX16-011 Driver Store cleanup are honestly non-reversible; NX16-011 additionally needs per-package `ExplicitConsent`. NX16-013…-016 are rollback engine scopes, not tweaks: exercise them through real apply/rollback tests rather than applying them.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX16-001 | System Restore enablement & configuration | CORE | E1 | Enable-NxSystemRestore | Get-ComputerRestorePoint lists points and protection is enabled for the system drive | Disable-ComputerRestore for the system drive; prior policy values restored from journal | Side: Disk space consumed by restore points within the chosen… |
| NX16-002 | Pre-change restore point creation ritual | CORE | E1 | Checkpoint-NxSystem | Get-ComputerRestorePoint returns a point newer than session start… | Additive only - NEXTRIX never deletes restore points; the temporary frequency override… | Dep NX16-001; Side: Brief VSS activity during point creation |
| NX16-003 | Targeted registry backup | CORE | E1 | Export-NxRegistryTargets | Backup set exists and every selected tweak's key path has a .reg file listed in the index manifest | None (additive) | Additive artifact; Side: Small disk usage under %ProgramData%\NEXTRIX\Backups |
| NX16-004 | Pre-flight original-state snapshot bundle | CORE | E1 | Invoke-NxPreFlight | Pre-flight report shows all capture steps Complete; journal manifest present; no Failed steps | None (additive) | Additive artifact; Dep NX16-002,NX16-003,NX16-005,NX16-006; Side: Disk usage for reports and backups |
| NX16-005 | Service configuration backup | CORE | E1 | Export-NxServiceState | Baseline files exist and enumerate every session target service | None (additive) | Additive artifact; Side: Small disk usage |
| NX16-006 | Scheduled task backup | CORE | E1 | Export-NxTaskState | Backup set contains one XML + state record per session target task | None (additive) | Additive artifact; Side: Small disk usage |
| NX16-007 | DISM health check & repair tooling | CORE | E1 | Invoke-NxDismHealth (mode=Scan) | Report shows CheckHealth/ScanHealth output with a clear health verdict | None (read-only) | Read-only report; Side: ScanHealth can take several minutes |
| NX16-008 | SFC verification tooling | CORE | E1 | Invoke-NxSfcVerify | Report contains the verifyonly verdict | None (read-only) | Read-only report; Side: Verify pass can take minutes |
| NX16-009 | Component store cleanup (on-demand) | CONDITIONAL | E1 | Invoke-NxComponentCleanup | DISM completes successfully; store size reported before/after | Not reversible; documented manual path | Side: Takes several minutes; temporary elevated CPU/disk usage |
| NX16-010 | Driver inventory & history report | CORE | E1 | Get-NxDriverInventory | Report enumerates drivers with version/provider/date | None (read-only) | Read-only report; Side: None (read-only) |
| NX16-011 | Driver Store selective cleanup | ADVANCED | E1 | Invoke-NxDriverStoreClean | pnputil enum no longer lists the removed orphaned packages; in-use drivers untouched | NOT journal-reversible; manual reinstall required | Dep NX16-010; Side: Removing the wrong package can break a device - hence… |
| NX16-012 | Windows build & UBR verification report | CORE | E1 | Get-NxBuildReport | Report fields populated; readSucceeded true | None (read-only) | Read-only report; Side: None (read-only) |
| NX16-013 | Individual tweak rollback | CORE | E1 | Invoke-NxRollback (tweakId=<tweak>) | Rollback result object: restored targets verified; diverged/failed lists empty or explained | Rollback steps are journaled; applying the tweak again re-journals a new original | Side: None beyond the restored configuration; Engine scope; do not apply directly |
| NX16-014 | Category rollback | CORE | E1 | Invoke-NxRollback (category=<NXcc>) | Rollback result: every category target restored or explicitly reported diverged/failed | Journaled; re-apply re-arms | Dep NX16-013; Side: None beyond restored configuration; Engine scope; do not apply directly |
| NX16-015 | Profile rollback | CORE | E1 | Invoke-NxRollback (profile=<Pn>) | Rollback result: profile-tagged targets restored; shared-target resolutions logged | Journaled; re-apply re-arms | Dep NX16-013; Side: None beyond restored configuration; Engine scope; do not apply directly |
| NX16-016 | Full NEXTRIX rollback | CORE | E1 | Invoke-NxRollback (all=True) | Rollback result: restored/diverged/failed summary; manifest carries restoredVerifiedUtc | Journaled; re-apply re-arms capture | Dep NX16-013; Side: Long-running on large journals; progress is reported per…; Engine scope; do not apply directly |
| NX16-017 | Owner support-bundle export | CORE | E0 | Export-NxSupportBundle | Bundle exists, contains the listed reports, scrub list applied | None (additive) | Additive artifact; Dep NX16-012; Side: Writes one zip file to the owner-chosen location |

### 4.18 NX17 — Advanced Windows Configuration (14 entries)

Twelve entries are `Defined` and read-only/plan-only by design; NX17-004 is a shipped read-only report; only NX17-011 (device installation restriction policy) ships a mutation. This is deliberate: BCD, timer, HPET, MSI-mode, interrupt-affinity and driver-verifier changes stay behind expert review. Do not hand-apply a `Defined` BCD or device policy change. Test the detection reports, confirm the refusal/`mutationSupported=false` statements, and treat any owner-applied BCD change as an owner action outside NEXTRIX rollback.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX17-001 | Timer resolution behavior | EXPERIMENTAL | E0 | Get-Nx17TimerResolutionReport | Get-Nx17TimerResolutionReport returns readOnly=true, mutationSupported=false… | None (not shipped) | Defined: not shipped; Side: None (read-only) |
| NX17-002 | Dynamic Tick policy (BCD) | ADVANCED | E1 | Get-Nx17DynamicTickPolicy | Get-Nx17DynamicTickPolicy returns bcdReadSucceeded with the parsed element state (present=false… | None (not shipped) | Defined: not shipped; Restart: Reboot; Side: If the owner applies disabledynamictick… |
| NX17-003 | HPET policy (BCD) | TROUBLESHOOTING | E1 | Get-Nx17HpetPolicy | Get-Nx17HpetPolicy returns forcingRejected=true, symptomGated=true, mutationSupported=false… | None (not shipped) | Defined: not shipped; Restart: Reboot; Side: None in v0.1 (detection only) |
| NX17-004 | Platform clock source inspection | CORE | E1 | Get-Nx17PlatformClockReport | Get-Nx17PlatformClockReport returns readOnly=true, mutationSupported=false, a selection classification… | None (read-only) | Read-only report; Side: None (read-only) |
| NX17-005 | Curated BCD configuration set | ADVANCED | E1 | Get-Nx17CuratedBcdConfiguration | Get-Nx17CuratedBcdConfiguration returns bulkWriteSupported=false, perEntryApprovalNeeded=true… | None (not shipped) | Defined: not shipped; Restart: Reboot; Side: None in v0.1 (read-only report) |
| NX17-006 | MSI mode per-device inspection & selective enable | ADVANCED | E0 | Get-Nx17MsiModeInventory | Get-Nx17MsiModeInventory returns globalWriteSupported=false, perDeviceOnly=true… | None (not shipped) | Defined: not shipped; Restart: Reboot; Side: None in v0.1 (read-only inventory) |
| NX17-007 | Interrupt affinity policy per-device | ADVANCED | E0 | Get-Nx17InterruptAffinityInventory | Get-Nx17InterruptAffinityInventory returns perDeviceOnly=true, mutationSupported=false… | None (not shipped) | Defined: not shipped; Restart: Reboot; Side: None (read-only) |
| NX17-008 | System responsiveness value | ADVANCED | E0 | Get-Nx17SystemResponsivenessState | Get-Nx17SystemResponsivenessState returns writeDelegated=true, ownerTweak=NX03-007… | None (not shipped) | Defined: not shipped; Side: None (read-only) |
| NX17-009 | Network throttling index | ADVANCED | E0 | Get-Nx17NetworkThrottlingState | Get-Nx17NetworkThrottlingState returns mutationSupported=false, the key/value presence… | None (not shipped) | Defined: not shipped; Side: None (read-only) |
| NX17-010 | Multimedia scheduler configuration | ADVANCED | E0 | Get-Nx17MultimediaSchedulerState | Get-Nx17MultimediaSchedulerState returns writeDelegated=true, ownerTweak=NX03-007… | None (not shipped) | Defined: not shipped; Side: None (read-only) |
| NX17-011 | Device installation restriction policy | ADVANCED | E1 | Set-Nx17DeviceInstallationPolicy (mode=Excluded) | Test-NxConfigurationState reads ExcludeWUDriversInQualityUpdate back as DWord 1 after apply… | Journaled restore (exact original, only-if-ours) | Side: Windows Update stops offering Driver-classified updates… |
| NX17-012 | Memory Manager curated set | TROUBLESHOOTING | E0 | Get-Nx17MemoryManagerState | Get-Nx17MemoryManagerState returns mutationSupported=false and exactly five value records… | None (not shipped) | Defined: not shipped; Side: None (read-only) |
| NX17-013 | Power throttling registry override | TROUBLESHOOTING | E0 | Get-Nx17PowerThrottlingState | Get-Nx17PowerThrottlingState returns writeDelegated=true, ownerTweak=NX03-006, key/value presence, kind… | None (not shipped) | Defined: not shipped; Side: None (read-only) |
| NX17-014 | Driver Verifier diagnostic configuration | TROUBLESHOOTING | E1 | Get-Nx17DriverVerifierState | Get-Nx17DriverVerifierState returns mutationSupported=false, querySucceeded/exitCode… | None (not shipped) | Defined: not shipped; Restart: Reboot; Side: None in v0.1 (read-only report) |

### 4.19 NX18 — Game Session Manager (12 entries)

Four entries are read-only (NX18-001 detection, -002 launcher mapping, -003 profile validation, -012 protected guard) and NX18-007 is a `Defined` plan-only service-suspension capability. The runtime entries (NX18-004/-005/-006/-008/-009/-010/-011) are exercised through the session protocol in §5, not by calling their apply functions directly. All NX18 entries are preset-excluded and consent-gated. Protected processes are hard-coded and cannot be overridden by a profile.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX18-001 | Running game detection engine | CONDITIONAL | E0 | Get-Nx18Capability (NX18-001) | Get-Nx18Capability -Capability NX18-001 returns implemented=true | None (read-only) | Read-only report; Side: One read-only process enumeration per detection call |
| NX18-002 | Launcher & child-process relationship mapping | CONDITIONAL | E0 | Get-Nx18Capability (NX18-002) | Get-Nx18LauncherMapping returns readOnly=true, managed=false and the Launcher-class entries | None (read-only) | Read-only report; Dep NX18-001; Side: Bounded ancestor walk (maximum 10 levels per game PID) |
| NX18-003 | Game-specific session profiles | CONDITIONAL | E0 | Get-Nx18Capability (NX18-003) | Read-Nx18Profile -ProfileName <name> returns valid=true for a conforming file and valid=false… | None (read-only) | Read-only report; Side: None on Windows configuration - validation is pure |
| NX18-004 | Session CPU Sets application | ADVANCED | E0 | Get-Nx18Capability (NX18-004) | The apply result must show verified=true for the process (NX19-003 re-reads SetProcessDefaultCpuSets… | Session restore (verified steps only) | Dep NX18-001,NX19-002,NX19-003; Side: CPU Set assignment is a soft affinity mechanism… |
| NX18-005 | Session power plan switching | CONDITIONAL | E1 | Get-Nx18Capability (NX18-005) | Get-NxActivePowerScheme after apply reports the session target GUID… | Session restore (verified steps only) | Dep NX09-001; Side: The active power plan changes for the duration… |
| NX18-006 | Session background app management | CONDITIONAL | E0 | Get-Nx18Capability (NX18-006) | Get-NxProcessCpuSetState (read-only) before/after shows the recorded priority class change for a named… | Session restore (verified steps only) | Dep NX18-003,NX19-005; Side: Only the named apps are affected; every non-allowlisted… |
| NX18-007 | Session service suspension (allowlisted) | ADVANCED | E0 | Get-Nx18Capability (NX18-007) | Get-Nx18Capability -Capability NX18-007 returns implemented=false | None (not shipped) | Defined: not shipped; Dep NX18-003; Side: None - the capability is plan-only and reports what… |
| NX18-008 | Session graphics configuration | CONDITIONAL | E0 | Get-Nx18Capability (NX18-008) | Capture-NxRegistryValue before/after shows the overlay value… | Session restore (verified steps only) | Dep NX18-003; Side: Only the declared overlay values change… |
| NX18-009 | Session process priority configuration | CONDITIONAL | E1 | Get-Nx18Capability (NX18-009) | Get-NxProcessCpuSetState reports priorityClass equal to the requested class during the session and equal… | Session restore (verified steps only) | Dep NX18-001,NX19-005; Side: Priority classes above Normal are never used (no… |
| NX18-010 | Session journal & crash/interruption recovery | CORE | E0 | Get-Nx18Capability (NX18-010) | Invoke-NxSessionRecovery -WhatIf lists non-terminal records with their verified-step counts and touches… | Recovery run (verified steps only) | Dep NX18-003; Side: One small JSON record per session under the session root |
| NX18-011 | Manual session control | CORE | E0 | Get-Nx18Capability (NX18-011) | Start-NxSession -Plan returns wrote=false and leaves the session root absent (self-test asserts it) | Session restore (verified steps only) | Dep NX18-010; Side: A session applies its plan for as long as the game runs… |
| NX18-012 | Protected-process policy guard | CORE | E0 | Get-Nx18Capability (NX18-012) | Get-Nx18ProtectedPolicy returns userOverrideAllowed=false and the six classes | None (read-only) | Read-only report; Side: A session refuses to manage a protected name… |

### 4.20 NX19 — CPU Topology & Scheduling (11 entries)

Eight entries are read-only plans/reports (NX19-001, -002, -006…-011). The three mutations are process-scoped: CPU Sets (NX19-003), affinity (NX19-004, single-group only) and priority (NX19-005); each ends with the process and has no persistent registry state. Test on the three hardware classes in §5.5: Intel hybrid, AMD dual-CCD X3D and a >64-LP system. Record the derived topology and the anti-cheat response; a refused CPU-set change is a reported platform outcome, not a NEXTRIX failure.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX19-001 | CPU topology detection & report engine | CORE | E1 | Get-NxTopologyReport | Report returns readOnly=true and either topologyAvailable=true with a non-zero logicalProcessorCount… | None (read-only) | Read-only report; Side: One-time in-memory compile of the interop class (Add-Type)… |
| NX19-002 | CPU Set derivation engine | CORE | E1 | New-NxCpuSetPlan (profile=Balanced) | Plan returns readOnly=true; every rule's logicalProcessors is a subset of the topology's derived LP set… | None (read-only) | Read-only report; Dep NX19-001; Side: None beyond the topology probe (NX19-001) |
| NX19-003 | Per-process CPU Set application | ADVANCED | E0 | Set-NxProcessCpuSets | The per-process report shows the requested CPU Set IDs as the process default… | Session-scoped; ends with the process | Dep NX19-002; Conflict NX19-004; Restart: Session; Side: Changes which logical processors the process may use while… |
| NX19-004 | Per-process affinity application | ADVANCED | E1 | Set-NxProcessAffinity | GetProcessAffinityMask for the target pid equals the requested single-group mask… | Session-scoped; ends with the process | Dep NX19-002; Conflict NX19-003; Restart: Session; Side: Hard affinity overrides CPU-set assignments… |
| NX19-005 | Per-process priority policy | CONDITIONAL | E1 | Set-NxProcessPriority | GetPriorityClass for the target pid returns the requested class… | Session-scoped; ends with the process | Restart: Session; Side: Changes scheduler priority relative to other processes… |
| NX19-006 | Scheduling profile: Competitive | CONDITIONAL | E0 | New-NxSchedulingPlan (profile=Competitive) | The plan reports profile=Competitive, restrictive=true when the topology has more LPs than the game… | None (read-only) | Read-only report; Dep NX19-002; Side: Choosing this profile expresses an intent only… |
| NX19-007 | Scheduling profile: Balanced gaming | CONDITIONAL | E0 | New-NxSchedulingPlan (profile=Balanced) | The plan reports profile=Balanced with a Game rule and no Background rule… | None (read-only) | Read-only report; Dep NX19-002; Side: Choosing this profile expresses an intent only… |
| NX19-008 | Scheduling profile: Streaming | CONDITIONAL | E0 | New-NxSchedulingPlan (profile=Streaming) | The plan reports profile=Streaming with Game classId 1 and Capture classId 2 rules whose LP sets are… | None (read-only) | Read-only report; Dep NX19-002; Side: Choosing this profile expresses an intent only… |
| NX19-009 | Scheduling profile: Productivity | CONDITIONAL | E0 | New-NxSchedulingPlan (profile=Productivity) | The plan reports profile=Productivity, restrictive=false and zero rules… | None (read-only) | Read-only report; Dep NX19-002; Side: None by design: the profile applies no CPU Set… |
| NX19-010 | Scheduling profile: Custom builder | CONDITIONAL | E0 | New-NxCustomSchedulingPlan (rules=) | With no rules the plan reports valid=false and the reason 'At least one rule is required' (no plan… | None (read-only) | Read-only report; Dep NX19-002; Side: Nothing is applied by the builder; an invalid rule set… |
| NX19-011 | AMD X3D / CCD-aware placement guidance | EXPERIMENTAL | E0 | Get-NxX3dPlacementGuidance | The report's detection is LargeL3DieAsymmetry, NoAsymmetry or NotDeterminable; when LargeL3DieAsymmetry… | None (read-only) | Read-only report; Dep NX19-001; Side: None: guidance text only; any placement must be selected… |

### 4.21 NX20 — Hardware & Driver Management (11 entries)

All eleven entries are read-only inventory/report entries. They never install, remove or update a driver; driver operations stay owner actions. Vendor-gated reports (NVIDIA/AMD/Intel) must report `supported=false` when the vendor is absent rather than inventing data. Run the inventory on both a VM and physical hardware to see the uncertainty states, and record BIOS/firmware versions without treating “newer” as automatically required.

| ID | Name | Risk | Evidence | Apply | Verify (short) | Rollback (short) | Notes |
|---|---|---|---|---|---|---|---|
| NX20-001 | Hardware inventory master report | CORE | E1 | Get-Nx20HardwareInventoryReport | Report object: hardwareReadSucceeded plus computer/board/bios (bios.firmwareType and firmwareTypeSource… | None (read-only) | Read-only report; Side: None (read-only) |
| NX20-002 | GPU vendor & driver capability report | CORE | E1 | Get-Nx20GpuCapabilityReport | Report object: adapters[] each with vendor, driverVersion, driverDate and driverDateSource… | None (read-only) | Read-only report; Side: None (read-only) |
| NX20-003 | NVIDIA driver management (inventory, guidance, profile inspection) | CONDITIONAL | E1 | Get-Nx20VendorDriverReport (Vendor=NVIDIA) | Report object: supported=true only when an NVIDIA adapter is present (otherwise supported=false… | None (read-only) | Read-only report; Dep NX20-002; Side: None (read-only) |
| NX20-004 | AMD driver management (equivalent) | CONDITIONAL | E1 | Get-Nx20VendorDriverReport (Vendor=AMD) | Report object: supported=true only with an AMD adapter present… | None (read-only) | Read-only report; Dep NX20-002; Side: None (read-only) |
| NX20-005 | Intel driver management (equivalent) | CONDITIONAL | E1 | Get-Nx20VendorDriverReport (Vendor=Intel) | Report object: supported=true only with an Intel adapter present… | None (read-only) | Read-only report; Dep NX20-002; Side: None (read-only) |
| NX20-006 | Network driver inspection & version report | CORE | E1 | Get-Nx20NetworkDriverReport | Report object: adapterSource names the reused inventory (NX07 or fallback)… | None (read-only) | Read-only report; Side: None (read-only) |
| NX20-007 | USB hardware inventory report | CORE | E1 | Get-Nx20UsbInventoryReport | Report object: controllerCount/controllers[]; deviceCount/hubCount; devices[] with role, vendorId… | None (read-only) | Read-only report; Side: None (read-only) |
| NX20-008 | Installed driver history report | CORE | E1 | Get-Nx20DriverHistoryReport | Report object: inventorySource names NX16-010 (or the explicit fallback)… | None (read-only) | Read-only report; Dep NX16-010; Side: Reads the Driver Store folder size (read-only metadata… |
| NX20-009 | Hardware compatibility report generator | CORE | E1 | Get-Nx20CompatibilityReport | Report object: gateInputs.gpu.vendorsPresent, memory.totalGb, storage.hasSsd/hasHdd… | None (read-only) | Read-only report; Side: None (read-only) |
| NX20-010 | Device configuration inspection | CORE | E1 | Get-Nx20DeviceConfigurationReport | Inventory mode: totalDeviceCount/listedDeviceCount/devices[] with status, problem and hasProblem… | None (read-only) | Read-only report; Side: None (read-only) |
| NX20-011 | BIOS/version currency guidance (report only) | CORE | E0 | Get-Nx20BiosCurrencyReport | Report object: system/board/bios, installedBiosVersion and installedBiosReleaseDate… | None (read-only) | Read-only report; Side: None (read-only) |

---

## 5. Session Manager (NX18) test protocol

NX18 is a runtime subsystem, not an install-time tweak set. The playbook only probes capability; a session is started by the owner with `Start-NxSession`. All Windows mutations made during a session go through the main journal (NX19 process state, NX09 active power plan, NxApply registry overlay). There is no background service in this build.

### 5.1 What a session may and may not touch

| May touch (journaled, session-scoped) | Must never touch |
|---|---|
| The target game process: CPU Sets (NX18-004), priority class (NX18-009) | Protected process classes: anti-cheat, security, recording, audio, peripherals, launchers |
| The active power plan, restored on exit (NX18-005) | Any other power setting |
| Explicitly allowlisted background apps: priority trim / CPU-set steering (NX18-006) | Terminating, suspending or sweeping other processes |
| Up to eight validated registry overlay values under HKCU or HKLM\SOFTWARE (NX18-008) | HKLM\SYSTEM, ControlSet001/002, security-policy value names |
| A per-session record under the session root | A Windows service, scheduled task or persistent setting |

### 5.2 Preparation

1. **Snapshot the VM.** A session writes process state, plan selection and a temporary registry overlay.
2. **Load NX18** in an elevated Windows PowerShell 5.1 window:

```powershell
Set-Location 'D:\College\Me\Projects\Tweaks\NEXTRIX'
. .\src\nxsession\NX18.ps1
```

3. **Run the pre-flight** (§2.5) with a dedicated journal root, e.g. `C:\NEXTRIX-Test\Journal-NX18-drill`.
4. **Create a drill profile.** NEXTRIX never creates a profile; the owner authors it.

```powershell
$drillRoot = 'C:\NX18-Drill'
New-Item -Path "$drillRoot\profiles" -ItemType Directory -Force | Out-Null

@'
{
  "schemaVersion": 1,
  "profileName": "drill",
  "game": { "exe": "notepad.exe" },
  "scheduling": { "cpuSetProfile": "Balanced" },
  "priority": { "gamePriorityClass": "BelowNormal" },
  "power": { "targetPlan": "" },
  "backgroundApps": [],
  "graphics": {
    "registry": [
      {
        "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer",
        "name": "NEXTRIXDrillMarker",
        "kind": "DWord",
        "value": 1
      }
    ]
  }
}
'@ | Set-Content "$drillRoot\profiles\drill.json" -Encoding UTF8
```

The overlay targets an existing key and a value name that does not exist. Its purpose is to prove that a session-applied value is restored (deleted) on exit or recovery. Do not use a real user setting for a drill.

5. **Validate the profile without running a session:**

```powershell
Test-Nx18Profile -Profile (Get-Content "$drillRoot\profiles\drill.json" -Raw | ConvertFrom-Json) -Name drill |
    Format-List valid, issues, warnings
```

Expected: `valid = True`; a no-step profile would produce only a warning, but this drill declares CPU sets, priority and an overlay.

### 5.3 Plan mode — must write nothing

```powershell
$before = @(Get-ChildItem $drillRoot -Filter 'session-*.json' -ErrorAction SilentlyContinue).Count
$plan = Start-NxSession -GameExe notepad.exe -ProfileName drill `
        -SessionRoot $drillRoot -ProfileRoot "$drillRoot\profiles" `
        -JournalRoot 'C:\NEXTRIX-Test\Journal-NX18-drill' -Plan
$plan | Format-List plan, wrote, sessionId, gameImageName, profileName, detected
$after = @(Get-ChildItem $drillRoot -Filter 'session-*.json' -ErrorAction SilentlyContinue).Count
"records before=$before after=$after"
```

Pass criteria:

- `plan = True`, `wrote = False`, `sessionId = $null`.
- No `session-*.json` was created; no journal entry was added.
- `sessionPlan.steps` shows the derived steps with `preflight = Ready` or a stated `Unavailable` reason.
- The console prints `Plan mode wrote nothing (no session record, no journal entry, no directory).`

If a record or journal entry appears in plan mode, stop and report a product defect; do not proceed to a real session.

### 5.4 Protected-process guard spot checks

```powershell
Test-Nx18ProtectedProcess -ProcessName 'EasyAntiCheat.exe' |
    Format-List processName, protected, category, matchedPattern
Test-Nx18ProtectedProcess -ProcessName 'obs64.exe' |
    Format-List processName, protected, category
Test-Nx18ProtectedProcess -ProcessName 'steam.exe' |
    Format-List processName, protected, category
Test-Nx18ProtectedProcess -ProcessName 'explorer.exe' |
    Format-List processName, protected, category

Get-Nx18ProtectedPolicy | Format-List userOverrideAllowed, categories
```

Expected:

| Input | Expected result |
|---|---|
| `EasyAntiCheat.exe` | `protected = True`, category `AntiCheat` |
| `obs64.exe` | `protected = True`, category `Recording` |
| `steam.exe` | `protected = True`, category `Launcher` |
| `explorer.exe` | `protected = False`, no category |
| policy | `userOverrideAllowed = False`; six categories: AntiCheat, Security, Recording, Audio, Peripherals, Launcher |

Attempt to start a session against a protected name — it must refuse before any profile read or session record:

```powershell
Start-NxSession -GameExe 'vgk.exe' -ProfileName drill `
    -SessionRoot $drillRoot -ProfileRoot "$drillRoot\profiles" `
    -JournalRoot 'C:\NEXTRIX-Test\Journal-NX18-drill' -Plan
```

Expected: a terminating error naming `protected class 'AntiCheat'`. No session record, no journal entry, no process change. Record the exact error text.

Also test a profile that tries to smuggle a protected background app: set `"backgroundApps": [{ "processName": "obs64.exe", "priorityClass": "BelowNormal", "mode": "PriorityTrim" }]` in a copy of the profile and run `Test-Nx18Profile`. Expected: `valid = False` with an issue stating that the user allowlist cannot override the protected list.

### 5.5 Hardware target matrix

These are the three hardware classes that materially change the topology/scheduling result. Run the read-only probes first; then, only if the owner wants a real session, run the session drill.

| Target class | What to record | Entries exercised |
|---|---|---|
| **Intel hybrid (P/E cores)** | `isHybrid`, `tierCount`, `efficiencyClasses`, `rankingSource`, `rankingCertainty`; whether the plan avoids a wrong P/E pin when the ranking is only documented-direction | NX19-001, NX19-002, NX19-011, NX18-004, NX18-009 |
| **AMD dual-CCD X3D** | `dies`, per-die L3 size, `x3d.indicated`, `x3d.confidence`, `largeDieIndexes`; guidance must say `LargeL3DieAsymmetry`, `NoAsymmetryDetected` or `NotDeterminable` — never infer from the marketing name | NX19-001, NX19-002, NX19-011, NX18-004 |
| **>64 logical processors (multi-group)** | `logicalProcessorCount`, processor group count, CPU Set IDs per group; affinity is single-group only, so NX19-004 must refuse or report the group limit while NX19-003 uses CPU Sets | NX19-001, NX19-003, NX19-004, NX18-004 |
| **Control: single-CCD / ≤64 LP** | Same reports, expecting no X3D asymmetry and a single group | NX19-001, NX19-002, NX19-011 |

Commands:

```powershell
Get-NxTopologyReport | ConvertTo-Json -Depth 8 |
    Set-Content 'C:\NEXTRIX-Evidence\topology.json' -Encoding UTF8

Get-NxX3dPlacementGuidance |
    Format-List detection, confidence, x3dIndicated, largeDieIndexes, largeDieLogicalProcessors, otherDieLogicalProcessors

New-NxCpuSetPlan -Profile Balanced |
    ConvertTo-Json -Depth 8 |
    Set-Content 'C:\NEXTRIX-Evidence\cpuset-plan-balanced.json' -Encoding UTF8
```

Pass criteria:

- Topology is derived from the documented APIs; every field that cannot be read is `$null`/`Uncertain`, never a guessed value.
- CPU Set IDs come from the derived map, not a literal list in code.
- X3D is indicated only by >2× per-die L3 asymmetry, not by CPU name. The result stays `EXPERIMENTAL`/`E0`.
- On >64 LP, the affinity path reports its single-group limitation; CPU Sets are used for cross-group placement.
- An anti-cheat refusal of CPU Sets/priority is recorded as a platform outcome, not bypassed.

### 5.6 Real session lifecycle

Start Notepad as the drill game (NEXTRIX never launches a game itself), then start the session in a **separate elevated PowerShell window** so the monitor loop is easy to interrupt:

```powershell
# In the separate window, after loading NX18:
Start-NxSession -GameExe notepad.exe -ProfileName drill `
    -SessionRoot 'C:\NX18-Drill' -ProfileRoot 'C:\NX18-Drill\profiles' `
    -JournalRoot 'C:\NEXTRIX-Test\Journal-NX18-drill' `
    -Approved -WaitSeconds 15 -PollSeconds 2 -CooldownSeconds 10
```

`-CooldownSeconds 10` is a **drill-only** shortening. Production default is 90 seconds; record which value was used.

In the first window, watch the state:

```powershell
Get-NxSessionStatus -SessionRoot 'C:\NX18-Drill' |
    Select-Object total, active, terminal
$status = (Get-NxSessionStatus -SessionRoot 'C:\NX18-Drill').active[0]
$status | Format-List state, heartbeatAgeSeconds, stale, verifiedStepCount, gameImageName, profileName
```

Expected: the record moves through `planned` → `applied` → `monitoring`; `verifiedStepCount` counts only steps whose engine read-back matched; the heartbeat age stays below 30 seconds while monitoring.

Check the temporary overlay while the session is monitoring:

```powershell
Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' `
    -Name NEXTRIXDrillMarker -ErrorAction SilentlyContinue
```

Expected: `NEXTRIXDrillMarker = 1` only while the session is active.

End the session normally by closing Notepad, or manually:

```powershell
$id = (Get-NxSessionStatus -SessionRoot 'C:\NX18-Drill').active[0].sessionId
Stop-NxSession -SessionId $id -SessionRoot 'C:\NX18-Drill' |
    Format-List state, alreadyTerminal, completionKind, restored
```

Expected:

- `completionKind` is `GameExit` or `ManualStop`.
- Only `verifiedSteps` are restored, in reverse order.
- The overlay value is gone afterwards (absent, not set to 0).
- No process was terminated to “undo” a priority/CPU-set change.
- The record becomes terminal; a second `Stop-NxSession` returns `alreadyTerminal = True`.

### 5.7 Simulated crash and recovery

This drill proves that an interrupted session is discoverable and restorable. Do it only on the disposable VM.

1. Start Notepad and start a session with a long monitor window (`-MaxMonitorSeconds 600`), in a separate elevated window.
2. Wait until `Get-NxSessionStatus` shows `state = monitoring` and `verifiedStepCount ≥ 1`.
3. **Kill the session host process**, not Notepad. If you launched the host with `Start-Process ... -PassThru`, use `Stop-Process -Id <hostPid> -Force`. Killing the host is the simulated crash.
4. Confirm the record is still non-terminal and its heartbeat is stale after 30 seconds:

```powershell
Get-NxSessionStatus -SessionRoot 'C:\NX18-Drill' |
    Select-Object total, active, terminal
```

5. **Dry run the recovery first.** `-WhatIf` lists the non-terminal records and touches nothing:

```powershell
Invoke-NxSessionRecovery -SessionRoot 'C:\NX18-Drill' `
    -JournalRoot 'C:\NEXTRIX-Test\Journal-NX18-drill' -WhatIf |
    Format-List aborted, recovered, refused, reason
```

6. **Run the real recovery:**

```powershell
$rec = Invoke-NxSessionRecovery -SessionRoot 'C:\NX18-Drill' `
       -JournalRoot 'C:\NEXTRIX-Test\Journal-NX18-drill'
$rec | Format-List aborted, recovered, refused, integrityErrors
$rec.records | Format-Table sessionId, outcome, restored, failed, reason -AutoSize
```

Expected:

- Only `verifiedSteps` are restored; a step that failed to apply is not in the list and is never restored.
- The overlay value is removed; process priority/CPU sets are restored only if the process still exists.
- The record ends `completed` (or is explicitly refused with a reason), never silently left mid-restore.
- A second recovery run reports `no non-terminal session records`.
- If the journal was tampered with, recovery aborts with `aborted = True` and `integrityErrors` and leaves every record unchanged.

7. **Tamper test (optional, VM only):** after a new interrupted session, modify one line in `journal.jsonl`, run recovery, and confirm it refuses without touching the record. Restore the snapshot afterwards. Do not tamper with a journal you still need.

### 5.8 Cooldown behaviour

After a session ends, rapid re-session is blocked to avoid the anti-cheat false-positive pattern.

```powershell
$rec = Get-ChildItem 'C:\NX18-Drill\session-*.json' |
       Sort-Object LastWriteTime -Descending |
       Select-Object -First 1 |
       Get-Content -Raw | ConvertFrom-Json
$rec.cooldownUntilUnixMs
[DateTimeOffset]::FromUnixTimeMilliseconds([int64]$rec.cooldownUntilUnixMs).LocalDateTime
```

Immediately try to start again against the running Notepad (keep the game process alive). Expected: a terminating error with `session cooldown active (Cooldown); <n>s remaining`. Run `Get-NxSessionStatus` and confirm no new record was created and no journal entry was written. After the cooldown expires (or with a new snapshot), the start succeeds. If another session record is still non-terminal, the reason is `ActiveSession`; recover or stop it first.

### 5.9 NX18 pass criteria and evidence

A session drill passes only when all of these are true:

- Plan mode wrote nothing.
- Protected names were refused at detection, start and profile validation; `userOverrideAllowed = False`.
- A real session applied only its declared steps and only after each step's read-back matched.
- Normal exit, manual stop and crash recovery each restored exactly the verified steps; nothing unverified was restored; nothing diverged was clobbered.
- No process was terminated or suspended; no service was touched; no game was launched by NEXTRIX.
- Cooldown blocked an immediate restart.
- Topology-derived CPU Sets matched the hardware class; the X3D result stayed heuristic and honestly labeled.

Evidence: the session record JSON, the journal entries for NX18-004/-005/-006/-008/-009, `Get-NxSessionStatus` before/after, the recovery report, and before/after registry captures for the overlay.

---

## 6. Evidence recording and performance testing

### 6.1 Evidence folder layout

One folder per entry per run. Never overwrite a previous run.

```
C:\NEXTRIX-Evidence\20261123-141500-NX02-002\
  record.md                 # human-readable record (§6.2)
  record.json               # machine-readable record (§6.3)
  pre.json                  # Capture-NxRegistryValue output before apply
  plan.json                 # Invoke-NxApply -Plan output
  apply.json                # apply result and step table
  verify.txt                # exact verify commands + output
  rollback.json             # Invoke-NxRollback result (all arrays)
  post.json                 # re-captured descriptors after rollback
  journal.jsonl             # copy of the journal (do not edit)
  manifest.json             # copy of the manifest
  sha256.txt                # hashes of the copies above
  screenshots\              # cropped, scrubbed UI proof
  support-bundle.zip        # NX16-017 output
```

Hash the artifacts at the end so the record is reproducible:

```powershell
Get-ChildItem 'C:\NEXTRIX-Evidence\20261123-141500-NX02-002' -Recurse -File |
    Where-Object Name -ne 'sha256.txt' |
    Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "{0}  {1}" -f $_.Hash, $_.Path } |
    Set-Content 'C:\NEXTRIX-Evidence\20261123-141500-NX02-002\sha256.txt' -Encoding ASCII
```

Do not edit `journal.jsonl`. It is append-only and hash-chained; any edit invalidates the evidence.

### 6.2 Markdown record template

Copy this block into `record.md` and fill every field. Use `UNKNOWN` only when the value truly cannot be read; never guess.

```markdown
## NEXTRIX manual test record

| Field | Value |
|---|---|
| Tweak ID | NX00-000 |
| Name | |
| Category | NX00 |
| Risk / Evidence / Status | CORE / E1 / SyntaxValidated |
| Approval model | Selection |
| Test type | Functional / Hardware / Performance |
| Date (UTC) | 2026-11-23T14:15:00Z |
| Owner | |
| Machine label | VM-01 / DESKTOP-TEST |
| VM snapshot or image | |
| Windows edition / build / UBR | Pro / 22631 / 0000 |
| CPU / GPU / RAM / storage | |
| PowerShell version | 5.1.x |
| Playbook version / wizard version | n/a / n/a |
| Journal root | C:\NEXTRIX-Test\Journal-... |
| Journal seq: apply / verify / rollback | 1 / 2 / 3 |
| Journal integrity | PASS (no integrityErrors) |
| Pre-flight allComplete | True |
| Pre-state | path / name / keyExisted / existed / kind / value |
| Post-apply state | |
| Verify command and output | |
| Side effects: expected/observed | |
| Side effects: unexpected | |
| Rollback result | restored n / diverged n / failed n / irreversible n |
| Post-rollback state | |
| Exact original returned | True / False |
| Result | PASS / FAIL / BLOCKED / SKIPPED / N/A (Defined) |
| Limitations / notes | |
| Artifacts | record.json, pre.json, verify.txt, rollback.json, support-bundle.zip |
```

For `ExplicitConsent` entries add this line above the apply section, before running the command:

```text
consent: ExplicitConsent acknowledged for NX00-000 by <owner> on 2026-11-23T14:10:00Z
```

### 6.3 JSON record skeleton

```json
{
  "schemaVersion": 1,
  "tweakId": "NX00-000",
  "name": "<registry name>",
  "category": "NX00",
  "risk": "CORE",
  "evidence": "E1",
  "registryStatus": "SyntaxValidated",
  "approval": "Selection",
  "testType": "functional",
  "dateUtc": "2026-11-23T14:15:00Z",
  "owner": "<owner label>",
  "machine": {
    "label": "VM-01",
    "vm": true,
    "snapshot": "<snapshot name or image timestamp>",
    "cpu": "<model>",
    "gpu": "<model and driver version>",
    "ramGb": 16,
    "storage": "<model/type>",
    "windows": {
      "edition": "Pro",
      "build": 22631,
      "ubr": 0,
      "displayVersion": "23H2"
    }
  },
  "engine": {
    "powershell": "5.1.22621.0000",
    "playbookVersion": null,
    "wizardVersion": null,
    "registryEntryVersion": 1
  },
  "journal": {
    "root": "C:\\NEXTRIX-Test\\Journal-NX00-000-20261123-141500",
    "seqApply": 1,
    "seqVerify": 2,
    "seqRollback": 3,
    "integrityErrors": 0,
    "manifestCaptureStatus": "Complete"
  },
  "preflight": {
    "allComplete": true,
    "backupSetPath": "C:\\ProgramData\\NEXTRIX\\Backups\\20261123-141500"
  },
  "capture": {
    "before": {
      "path": "HKLM:\\SOFTWARE\\...",
      "name": "<value name>",
      "keyExisted": true,
      "existed": false,
      "kind": null,
      "value": null
    },
    "afterApply": {
      "existed": true,
      "kind": "DWord",
      "value": 0
    },
    "afterRollback": {
      "existed": false,
      "kind": null,
      "value": null
    },
    "exactOriginal": true
  },
  "verification": {
    "procedure": "<entry verify procedure, abbreviated>",
    "command": "<exact command>",
    "output": "<exact output or file reference>",
    "result": "PASS"
  },
  "sideEffects": [
    {
      "expected": "<listed side effect>",
      "observed": "<what happened>",
      "status": "PASS"
    }
  ],
  "rollback": {
    "command": "Invoke-NxRollback -JournalRoot <root> -TweakId NX00-000",
    "restored": 1,
    "diverged": 0,
    "failed": 0,
    "irreversible": 0,
    "aborted": false
  },
  "result": "PASS",
  "limitations": [],
  "notes": "<anything the next tester must know>",
  "artifacts": [
    "pre.json",
    "verify.txt",
    "rollback.json",
    "post.json",
    "journal.jsonl",
    "manifest.json",
    "support-bundle.zip"
  ]
}
```

Use `null` for values that do not exist, not `""`. For a value that existed with no data, `existed` is true and `kind`/`value` are recorded exactly. Boolean `exactOriginal` must be derived from the comparison in §3.7, not asserted. For an entry with multiple targets, replace `capture` with a `captures` array holding one `{ before, afterApply, afterRollback, exactOriginal }` object per target, or write one record per target.

### 6.4 Performance-testing appendix (optional; owner-only)

Most entries have **no defined performance metric**. Without a metric-matched question, an entry cannot reach `PerformanceTested`; the correct result is `N/A`. The candidates explicitly identified for owner testing in `TWEAK_RESEARCH.md` §15 are: NX03-008, NX17-001, NX17-002, NX04-005, NX19-003, NX19-006, NX18-008, NX18-009, NX02-005 and NX04-010. This list is a research queue, not a claim that those entries improve anything; several are `Defined` in this build and cannot be applied until implemented.

#### 6.4.1 Design

1. **Define the metric and the workload before changing anything.** The metric must match the intended behaviour. For a frame-rate question use 1% low, 0.1% low and frame-time percentiles, not average FPS alone. For a boot/launch question use measured time. For a thermal question use the same sensor and sampling window. For battery use the same discharge profile.
2. **Freeze the machine.** Same build/UBR, same driver, same power plan, same background set, same game/app build and settings, same ambient conditions as far as possible. Record all of it.
3. **Warm up once, then run 3–5 baseline runs.** Do not use the first run as a baseline if the workload has a warm-up phase.
4. **Change exactly one thing** — one tweak ID. No driver update, no game patch, no Windows update, no new background app.
5. **Run 3–5 after runs** with the same harness, same duration, same order discipline. Alternating A/B/A/B is preferred when the harness permits it.
6. **Keep the raw logs.** Screenshots are not raw data. Save the benchmark CSV/JSON and the tool version.
7. **Report median and range**, not the best run. State the number of runs. Do not claim statistical significance from three runs; describe the observed difference and its variance.

| Run | Phase | Date/time | Metric | Value | Conditions / notes |
|---:|---|---|---|---:|---|
| 1 | baseline | | | | |
| 2 | baseline | | | | |
| 3 | baseline | | | | |
| 4 | after | | | | |
| 5 | after | | | | |
| 6 | after | | | | |

#### 6.4.2 Evidence levels

- **E2** = one owner configuration, complete controlled run set. One machine only.
- **E3** = the same controlled method repeated on multiple owner hardware configurations, with each result reported separately.
- **E4** = independently reproducible across diverse configurations; not grantable from a single owner's lab alone.

A configuration check, a plan, or a successful apply is **not** performance evidence. An `E2` result does not generalize to another CPU, GPU, driver, build or workload.

#### 6.4.3 Claim wording (only after the data exists)

> On `<machine>` (`<CPU>` / `<GPU>` / `<RAM>` / Windows `<build>.<UBR>`), for `<workload>` at `<resolution and settings>`, `<metric>` median was `<X>` (range `<A>–<B>`, n=`<N>`) before and `<Y>` (range `<C>–<D>`, n=`<N>`) after applying `<ID>`. No other change was made. This is an E2 single-machine result and does not generalize.

If the ranges overlap heavily or the change is within run-to-run noise, the honest conclusion is “no measurable change under this method”. Record it. A negative result is valuable and must not be suppressed.

#### 6.4.4 What NOT to claim

- Do not claim “faster”, “smoother”, “lower latency”, “less stutter”, “higher FPS” or “better 1% lows” from a configuration check.
- Do not claim a result from a single run or from the best of several runs.
- Do not claim a result from a different workload, resolution, game build or metric than the one measured.
- Do not import a number from a reference project, a vendor slide or a community post as NEXTRIX evidence.
- Do not bundle several tweaks and attribute the result to one.
- Do not generalize an E2 result to other hardware; that requires E3.
- Do not claim stability, safety or absence of side effects from a benchmark. Stability needs its own functional test.
- Do not claim a battery, thermal or power benefit from a registry value; measure the actual runtime, temperature or energy report.

---

## 7. Release acceptance checklist

Promotion is **owner-only** beyond `ConfigurationValidated`. The coordinator updates the registry `status` only after the owner supplies the evidence record. No bulk promotion, no promotion by label, no promotion from a plan or a self-test.

### 7.1 Promotion criteria

| Target status | Minimum criteria | Evidence required |
|---|---|---|
| `OwnerFunctionallyValidated` | One owner run on a supported build (VM or physical; physical required for hardware-sensitive entries): apply succeeds, configuration verifies, listed side effects are checked, rollback returns the exact original, journal integrity passes | `record.md` + `record.json` + `pre.json` + `verify.txt` + `rollback.json` + journal copies |
| `OwnerHardwareTested` | The full sheet for the entry is completed on **physical** hardware; restart/session behaviour observed; dependencies and conflicts exercised; recovery path tested; at least one hardware class matching `requiredHardware` | Complete record set + screenshots + support bundle + VM/physical machine identification |
| `PerformanceTested` | A defined, metric-matched question; 3–5 baseline and 3–5 after runs; one change; raw data; median and range reported; E2 (or E3 for multi-config) | Raw benchmark files, harness/tool version, run table, claim wording, machine/driver/build record |
| `ReleaseApproved` | Every shipped entry is at least `OwnerHardwareTested`; every performance statement is backed by a `PerformanceTested` entry; no open blocker; docs, known issues and compatibility notes updated; artifact versions and hashes pinned | Release checklist + owner sign-off + full evidence index |

`ConfigurationValidated` remains a coordinator/engineering status. The owner does not need to grant it; the owner's first functional run is what moves an entry above it.

### 7.2 Release gate checklist

- [ ] All 282 entries have a current registry status and no contradictory catalogue text.
- [ ] Every entry intended for the release is at least `OwnerHardwareTested`.
- [ ] Every performance claim maps to a `PerformanceTested` entry and a metric-matched record.
- [ ] All `Defined` entries are either excluded from the release or documented as plan-only/read-only.
- [ ] All irreversible entries are labeled in the release notes with their manual restore route.
- [ ] All `ExplicitConsent` entries have a consent record in the evidence.
- [ ] No entry exceeds its evidence level; no E2 result is described as general.
- [ ] `tools/Test-NxRegistry.ps1` reports zero errors; `tools/Test-NxAll.ps1` reports 18/18 PASS (or a documented host timeout, rerun).
- [ ] Playbook version, wizard version, registry hash and release hashes are pinned.
- [ ] `KNOWN_ISSUES.md`, compatibility docs and the support matrix reflect the tested builds/hardware.
- [ ] Owner has signed the release approval.

### 7.3 Downgrade rule

Any change to an entry's apply/verify/rollback path, target value, build range or dependency invalidates prior owner evidence for that entry. Re-test the affected entry; do not carry a status forward on an unchanged label. A registry version bump without a re-test is not evidence.

---

## 8. Known host flakiness and the bounded runner

### 8.1 Host flakiness (not product defects)

These are documented host/provider behaviours. Record them as environmental notes; do not turn them into a tweak FAIL or PASS.

| Symptom | Likely cause | Diagnostic | Safe action |
|---|---|---|---|
| DISM/Appx cmdlet hangs, especially NX12 | PowerShell 7's DISM/Appx surface on some hosts (`KNOWN_ISSUES.md` 15) | Re-run in Windows PowerShell 5.1 | Use 5.1; do not kill a DISM operation mid-flight |
| WMI/TPM/DeviceGuard query stalls | Slow or flaky provider | Per-suite timeout; query again | Wait/retry; record `Uncertain`, not a guessed value |
| `Test-NxAll.ps1` reports `TIMEOUT` | A suite exceeded its bounded time (150 s; NX12 240 s) | Check which suite; rerun alone | A timeout is not a suite failure; rerun and record both |
| Restore point creation throttled | Windows 24-hour SR frequency | `Get-ComputerRestorePoint` shows a point <24 h old | Keep the existing point; NX16-002 reports it; not a failure |
| Journal read reports integrity errors under AV scan | Transient partial read | `Read-NxJournal` already retries with a fresh permissive read | If it persists on both attempts, treat as tampering/integrity and stop |
| `nvidia-smi` absent or times out | Driver/tool not installed, or VM | GPU report shows `Uncertain` with the reason | Record; do not install a tool just to make a report pass |
| Store/winget reinstall fails | Network, region, Store state | Check network and Store sign-in | Environmental; retry later; do not mark the tweak failed |
| Sensors absent in a VM | Virtual hardware exposes no thermal/battery sensor | NX10/NX09 reports `Uncertain`/unavailable | Expected; test on physical hardware for a hardware result |
| UCPD blocks a taskbar value | OS protects the value on newer builds | Entry reports protected/no-write | Use the documented policy fallback or record the block; do not fight UCPD |
| Classic power settings ignored on Modern Standby | S0ix platform behaviour (`TWEAK_RESEARCH.md` §6) | Compare AC/DC and the active scheme; note the platform | Record the platform limitation; do not claim the setting took effect |
| Apps return after a feature update | Documented Windows behaviour | Check the NX12 removal ledger | Re-run the intended removal after the update; not a rollback failure |
| Anti-cheat refuses CPU sets/priority | Documented platform behaviour | `Get-NxSessionStatus`/engine reports refusal | Record it; never bypass |

### 8.2 The bounded runner (`tools/Test-NxAll.ps1`)

The runner executes the journal self-test plus all 17 category self-test suites under Windows PowerShell 5.1, each in a child process with a timeout.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-NxAll.ps1
```

Interpretation:

- Exit code **0** = all suites PASS; **1** = any FAIL/TIMEOUT.
- Expected healthy output ends with `BOUNDED RUN RESULT: 18 PASS, 0 FAIL/TIMEOUT`.
- `-TimeoutSeconds` (default 150) and `-DismSuiteTimeoutSeconds` (default 240) can be raised for a slow host; record any change.
- A `TIMEOUT` on NX12/DISM or a WMI/TPM suite is a host-provider issue until proven otherwise; rerun the suite alone.

What the runner **is**: a static/self-test gate. It verifies journal invariants, parsers, planners, guard tables and temp-folder behaviour.

What the runner **is not**: a hardware test, a performance test, or a substitute for this guide. It does not apply a tweak to the host, does not prove a configuration holds, and cannot grant any owner status.

Also run the registry validator directly when changing or reviewing entries:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-NxRegistry.ps1
```

Zero errors is the release gate. Warnings must be understood, not suppressed.

---

## 9. Appendices

### 9.1 Appendix A — Command quick reference

All commands assume an elevated Windows PowerShell 5.1 window at the repository root.

| Task | Command |
|---|---|
| Load the engine | `. .\src\nxcore\Import-NxCore.ps1` |
| Load NX18 | `. .\src\nxsession\NX18.ps1` |
| Build report | `Get-NxBuildReport \| Format-List` |
| Hardware report | `Get-NxHardwareReport \| ConvertTo-Json -Depth 6` |
| Pre-flight / journal init | `Invoke-NxPreFlight -JournalRoot <root> -IncludeRestorePoint -RegistryPaths <paths>` |
| Read journal | `$j = Read-NxJournal -Path <root>; $j.integrityErrors; ($j.entries \| Measure-Object).Count` |
| Plan one tweak | `Invoke-NxApply -Tweak <entry> -HardwareReport <hw> -BuildReport <build> -JournalRoot <root> -Plan` |
| Apply one tweak | `Invoke-NxApply -Tweak <entry> -HardwareReport <hw> -BuildReport <build> -JournalRoot <root> -Profiles <Pn> -Approved` |
| Verify a registry value | `Test-NxConfigurationState -Path <path> -Name <name> -Kind <kind> -ExpectedValue <value>` |
| Roll back one tweak | `Invoke-NxRollback -JournalRoot <root> -TweakId NX00-000` |
| Roll back a category | `Invoke-NxRollback -JournalRoot <root> -Category NX00` |
| Roll back a profile | `Invoke-NxRollback -JournalRoot <root> -Profile P1` |
| Roll back everything | `Invoke-NxRollback -JournalRoot <root> -All` |
| Copy the pre-state | `Capture-NxRegistryValue -Path <path> -Name <name>` |
| Export the evidence bundle | `Export-NxSupportBundle -DestinationPath <zip> -JournalRoot <root> -IncludeHealth` |
| Session plan (writes nothing) | `Start-NxSession -GameExe <exe> -ProfileName <name> -Plan` |
| Session status | `Get-NxSessionStatus -SessionRoot <root>` |
| Stop a session | `Stop-NxSession -SessionId <id> -SessionRoot <root>` |
| Recovery dry run | `Invoke-NxSessionRecovery -SessionRoot <root> -JournalRoot <root> -WhatIf` |
| Recovery | `Invoke-NxSessionRecovery -SessionRoot <root> -JournalRoot <root>` |
| Protected-process probe | `Test-Nx18ProtectedProcess -ProcessName <name>` |
| Registry validator | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-NxRegistry.ps1` |
| Bounded self-tests | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-NxAll.ps1` |

### 9.2 Appendix B — How to read a registry entry

| Field group | Fields | What the tester uses it for |
|---|---|---|
| Identity | `id`, `name`, `category`, `subcategory`, `kind` | Test record identity; `kind` distinguishes a configuration change from a diagnostic/engine/composition entry |
| Explanation | `description`, `objective`, `technicalExplanation` | Understand the mechanism and the intended configuration effect before applying |
| Change | `defaultState`, `proposedState`, `modificationType` | Know what should change; `modificationType` is `registry`, `service`, `task`, `power`, `appx`, `function` or `none` |
| Safety | `risk`, `sideEffects`, `approval`, `privileges`, `restart` | Decide whether to test, what to watch, and how much confirmation is required |
| Applicability | `profiles`, `workloads`, `requiredHardware`, `excludedHardware`, `editions`, `builds` | Predict a graceful skip; never force a hardware/build gate |
| Relationships | `dependencies`, `conflicts` | Test prerequisites first; avoid a known conflict |
| Action | `apply.actions` | Engine function(s) or registry target(s); the table's Apply column comes from here |
| Verification | `verify.procedure` | The configuration check to run; this is not a performance metric |
| Rollback | `rollback.procedure`, `rollback.reversible` | Restoration semantics and whether the entry is honestly irreversible |
| Original state | `originalState.method` | What the journal captures before mutation |
| Evidence | `evidence`, `documentationSource` | E0/E1 desk level and the Microsoft/vendor source (or reference provenance) |
| Governance | `status`, `presetExcluded`, `version` | Current ladder position, preset exclusion, entry version |

`modificationType: none` does **not** always mean “no file is written”: an additive backup or report may still write a file at an owner-chosen path. The Rollback column distinguishes `None (read-only)`, `None (additive)`, `None (not shipped)` and true no-op engine capabilities.

### 9.3 Appendix C — Coverage audit

Generated from `registry/NX01.json` … `registry/NX20.json` on 2026-11-23 (HEAD `744b87d`).

| Category | Entries | `Defined` | No journaled mutation (read-only/additive/plan-only) | Reboot required |
|---|---:|---:|---:|---:|
| NX01 Windows Foundation | 16 | 1 | 0 | 1 |
| NX02 Gaming & Esports | 12 | 3 | 2 | 0 |
| NX03 CPU & Processor | 13 | 3 | 4 | 0 |
| NX04 GPU & Graphics | 23 | 18 | 3 | 1 |
| NX05 Memory Management | 11 | 0 | 3 | 6 |
| NX06 Storage & Filesystem | 13 | 0 | 2 | 4 |
| NX07 Network Optimization | 22 | 0 | 2 | 1 |
| NX08 Input & Peripherals | 8 | 0 | 3 | 2 |
| NX09 Power Management | 15 | 0 | 4 | 0 |
| NX10 Thermal Management | 8 | 0 | 8 | 0 |
| NX11 Background Activity & Services | 19 | 1 | 4 | 0 |
| NX12 Windows Debloating | 14 | 0 | 4 | 0 |
| NX13 Privacy & Telemetry | 14 | 0 | 1 | 1 |
| NX14 Security Configuration | 15 | 0 | 8 | 4 |
| NX15 Visual & Interface | 14 | 1 | 0 | 0 |
| NX16 Maintenance & Recovery | 17 | 0 | 9 | 0 |
| NX17 Advanced Windows Configuration | 14 | 12 | 2 | 6 |
| NX18 Game Session Manager | 12 | 1 | 5 | 0 |
| NX19 CPU Topology & Scheduling | 11 | 0 | 8 | 0 |
| NX20 Hardware & Driver Management | 11 | 0 | 11 | 0 |
| **Total** | **282** | **40** | **83** | **26** |

Mechanical check performed for this document:

- Every ID from all 20 registry files appears in exactly one sheet row.
- 282 registry IDs, 282 sheet rows, 0 missing, 0 duplicates.
- The check is read-only: it parses the JSON files and the generated tables; it does not load or apply any tweak.

### 9.4 Appendix D — Known documentation and registry issues found while writing this guide

These are recorded for the coordinator. This guide does not modify the files involved.

1. **Stale classification sentence.** `TWEAK_CLASSIFICATION.md` §3 says no entry holds a status beyond `CANDIDATE`; the registry actually has 242 `SyntaxValidated` and 40 `Defined`. The registry is authoritative.
2. **Stale inventory counts in README.** `README.md` still says 272/273 candidates and “no NEXTRIX modification has been implemented or applied anywhere yet”; the registry now contains 282 entries and implemented engines. Documentation sync is a coordinator task.
3. **NX07 missing `reversible`.** 18 NX07 entries omit `rollback.reversible` — all except NX07-001, NX07-019, NX07-020 and NX07-021. Their rollback prose is clear, but a schema consumer should not rely on the field being present. The registry should add it or document the default.
4. **Capture re-arm mismatch.** `STATE_JOURNAL.md` says a `restoredVerifiedUtc` marker re-arms capture. `Complete-NxJournalRestore` sets the marker, but `Initialize-NxJournal` still refuses a `Complete` journal without `-Force`. The workaround in §2.4 is a fresh journal root or snapshot. Static inspection only; not executed.
5. **Null `ExpectedValue` binding.** `Test-NxConfigurationState`'s `-ExpectedValue` is mandatory without `[AllowNull()]`; `NxRollback.ps1` passes `$null` for values that never existed. This can throw and be journaled as a failed rollback step after the deletion already succeeded. See §3.7. Static inspection only; not executed.
6. **NX12 removal is plan-only.** The registry/apply path surfaces `Get-Nx12RemovalPlan`; the guarded removal write functions require explicit-selection wiring (`KNOWN_ISSUES.md` 13). The test sheets say so rather than implying removal is shipped.
7. **NX18 packaging.** `src/nxsession/NX18.ps1` is outside `src/nxcore`; the playbook generator flags it as not found at generate time (`KNOWN_ISSUES.md` 16). The session runtime tests must load it explicitly.
8. **No entry has been tested.** All owner-status columns are zero; this guide creates the procedure, not the evidence.

### 9.5 Document control

| Item | Value |
|---|---|
| Owner | Project owner |
| Author workstream | W5-A |
| Source of truth | `registry/NX01.json` … `registry/NX20.json` (schema version 1) |
| Generated against | HEAD `744b87d`, 2026-11-23 |
| Update rule | Regenerate the category tables whenever the registry changes; re-run the ID coverage check; bump the document version |
| Promotion authority | Owner only, beyond `ConfigurationValidated` |
| Performance claims | None in this document. Any future claim must cite an owner `PerformanceTested` record. |

---

**End of guide.** If a test result and this guide disagree, the registry entry and the journal are the authorities; report the discrepancy and do not silently edit either.
