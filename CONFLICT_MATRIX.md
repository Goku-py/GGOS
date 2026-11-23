# NEXTRIX - Conflict Matrix

**Status:** generated artifact - do not edit by hand.
**Generator:** `tools/Export-NxMatrices.ps1`
**Source of truth:** `registry/NX*.json` (282 entries); declared conflicts only.
**Regenerate:** `powershell.exe -NoProfile -File tools\Export-NxMatrices.ps1` (or `pwsh`).

A declared conflict means two entries reach the same feature, target or mechanism: they are alternatives (select one) or one destroys the other's state. Being in an overlap group (section 5) is NOT a conflict - it is an ownership/coordination note.

## 1. Summary

| Metric | Value |
|---|---|
| Declared conflict pairs (unique, sorted) | 12 |
| Symmetric pairs | 12 |
| Asymmetric pairs (warnings) | 0 |
| Conflict groups (connected components) | 5 |
| Cross-category shared engine functions (composer candidates) | 1 |
| Cross-reference overlap edges | 9 |
| Cross-reference overlap groups | 6 |
| Curated preset-pairing hazards | 5 |

## 2. Legend and verification rules

- **registry-declared**: at least one entry lists the other in `conflicts`. Symmetry is checked both ways; asymmetric declarations are reported as warnings (the validator treats them the same way).
- **CURATED**: an agent-authored note that is not a registry conflict declaration. Curated rows are labelled and their tokens are asserted against the registry text at export time; if the text changes, the export fails instead of publishing a stale claim.
- **Derived**: computed from the registry (conflict graph, shared functions, XREF sentences).

## 3. Declared conflict pairs

`Group` points at the connected component in section 4, which carries the curated resolution. `Registry evidence` is the first registry sentence that names the other entry (a fact from the text, not necessarily a resolution).

| Pair | A risk | B risk | Directions | Group | Registry evidence |
|---|---|---|---|---|---|
| NX02-008 <-> NX12-005 | CONDITIONAL | CONDITIONAL | symmetric (A<->B) | G1 | Conflict with NX12-005 (Xbox app removal) is declared in both the registry entry and the report output. |
| NX05-001 <-> NX05-002 | CONDITIONAL | ADVANCED | symmetric (A<->B) | G2 | Validation: drive must be an existing 'X:' root; sizes are whole MB with a 16 MB floor (the System Properties page-file dialog minimum), maximum >= initial, and 0/0 is refused because that means system-managed and belongs to NX05-001. |
| NX05-001 <-> NX05-003 | CONDITIONAL | TROUBLESHOOTING | symmetric (A<->B) | G2 | Never disables the pagefile (that is NX05-003, troubleshooting-only). |
| NX05-002 <-> NX05-003 | ADVANCED | TROUBLESHOOTING | symmetric (A<->B) | G2 | No registry sentence names the other entry; declaration only. |
| NX05-003 <-> NX05-009 | TROUBLESHOOTING | CONDITIONAL | symmetric (A<->B) | G2 | Kernel, complete and automatic memory dumps cannot be produced without a pagefile on the boot volume (NX05-009 conflict). |
| NX07-016 <-> NX07-021 | CONDITIONAL | TROUBLESHOOTING | symmetric (A<->B) | G3 | No registry sentence names the other entry; declaration only. |
| NX07-017 <-> NX07-021 | ADVANCED | TROUBLESHOOTING | symmetric (A<->B) | G3 | No registry sentence names the other entry; declaration only. |
| NX07-018 <-> NX07-021 | TROUBLESHOOTING | TROUBLESHOOTING | symmetric (A<->B) | G3 | No registry sentence names the other entry; declaration only. |
| NX07-020 <-> NX07-021 | TROUBLESHOOTING | TROUBLESHOOTING | symmetric (A<->B) | G3 | No registry sentence names the other entry; declaration only. |
| NX11-010 <-> NX12-005 | CONDITIONAL | CONDITIONAL | symmetric (A<->B) | G1 | CONFLICT NX12-005: Xbox app removal and Xbox service management must be resolved together; Game Pass users are excluded. |
| NX12-004 <-> NX13-012 | CONDITIONAL | CONDITIONAL | symmetric (A<->B) | G4 | Continue on PC / phone linking stops for that profile; NX13-012 policy is the alternative control for the same feature. |
| NX19-003 <-> NX19-004 | ADVANCED | ADVANCED | symmetric (A<->B) | G5 | This is deliberately separate from NX19-003. |

Symmetry check: PASS - every declared conflict is declared in both directions (0 asymmetric pairs).

## 4. Conflict groups (derived connected components)

Groups are the connected components of the declared conflict graph. A group is a set of entries from which at most one alternative should be selected for the same target; the resolution column is CURATED where a note exists.

| Group | Members (id + name) | Risk mix | Resolution (CURATED where noted) |
|---|---|---|---|
| G1 | NX02-008 Xbox Gaming Services management; NX11-010 Xbox services configuration; NX12-005 Xbox app removal (optional) | CONDITIONAL | (CURATED) Xbox app removal (NX12-005) and Xbox service configuration (NX11-010) change the same Xbox/Game Pass surface; NX02-008 is the read-only dependency report that must be consulted before either change and its report declares the NX12-005 conflict. |
| G2 | NX05-001 Normalize pagefile to system-managed; NX05-002 Custom pagefile configuration; NX05-003 Disable pagefile; NX05-009 Crash dump configuration | ADVANCED, CONDITIONAL, TROUBLESHOOTING | (CURATED) Pagefile modes are mutually exclusive: NX05-001 (system-managed), NX05-002 (custom size) and NX05-003 (no pagefile) write the same Session Manager Memory Management values. NX05-009 needs a boot-volume pagefile for kernel/complete dumps, so it conflicts with NX05-003. Select one pagefile mode; pair crash-dump type with NX05-001 or NX05-002. |
| G3 | NX07-016 DNS configuration; NX07-017 TCP auto-tuning & ECN inspection/config; NX07-018 MTU inspection & configuration; NX07-020 DNS cache management; NX07-021 Network stack reset | ADVANCED, CONDITIONAL, TROUBLESHOOTING | (CURATED) NX07-021 resets Winsock and the TCP/IPv4/IPv6 stacks and can clear the DNS, MTU and TCP-global settings written by NX07-016/017/018; NX07-020 (DNS cache flush) is also subsumed during a reset. Run the reset alone, then re-apply targeted settings; never select the reset as a tidy-up after configuration. |
| G4 | NX12-004 Phone Link removal (optional); NX13-012 Cross-device experiences configuration | CONDITIONAL | (CURATED) Phone Link removal (app) and the phone-PC linking policy (NX13-012) reach the same feature from two directions; choose one. NX13-012 leaves the app installed and disables the policy; NX12-004 removes the app while NX13-012 keeps policy ownership. |
| G5 | NX19-003 Per-process CPU Set application; NX19-004 Per-process affinity application | ADVANCED | (CURATED) CPU Sets (soft placement) and affinity (hard mask) are two mechanisms for the same per-process placement; affinity overrides CPU sets. Select one per process, and never both for the same image. |

## 5. Cross-reference overlap groups (derived, coordination only)

Derived mechanically: a sentence in the registry text that contains an ownership marker (`XREF`, `overlap`, `alternative control`, `choose one`, `do not pair`, `two directions`) and at least two tweak ids creates an edge. These groups mean the entries touch the same subsystem or delegate to one another; **they are not conflicts** unless they also appear in section 3 or 7. Use them to review preset composition and ownership handoffs.

| Group | Members (id + name) | Evidence edges |
|---|---|---|
| X1 | NX02-008 Xbox Gaming Services management; NX11-010 Xbox services configuration; NX12-005 Xbox app removal (optional) | NX02-008 <-> NX11-010 [text: NX12-005.documentationSource]; NX02-008 <-> NX12-005 [text: NX11-010.documentationSource]; NX11-010 <-> NX12-005 [text: NX12-005.documentationSource] |
| X2 | NX03-007 MMCSS configuration; NX17-008 System responsiveness value; NX17-010 Multimedia scheduler configuration | NX03-007 <-> NX17-008 [text: NX03-007.documentationSource]; NX17-008 <-> NX17-010 [text: NX03-007.technicalExplanation] |
| X3 | NX05-007 Large System Cache; NX17-012 Memory Manager curated set | NX05-007 <-> NX17-012 [text: NX05-007.documentationSource] |
| X4 | NX08-006 Bluetooth peripheral inspection & power policy; NX11-012 Bluetooth service configuration | NX08-006 <-> NX11-012 [text: NX08-006.documentationSource] |
| X5 | NX09-005 USB selective suspend policy; NX20-007 USB hardware inventory report | NX09-005 <-> NX20-007 [text: NX08-007.documentationSource] |
| X6 | NX12-004 Phone Link removal (optional); NX13-012 Cross-device experiences configuration | NX12-004 <-> NX13-012 [text: NX12-004.technicalExplanation] |

## 6. Shared-value / composer groups (derived)

An engine function shared by entries in more than one category is a shared-value candidate: the function owns a read-modify-write contract, so the entries must compose rather than collide. Same-category shared functions are omitted here (plan builders and shared helpers inside one category are ordinary implementation reuse).

| Engine function | Consumers | Categories | Verdict |
|---|---|---|---|
| Set-NxDirectXGlobalSetting | NX02-005 Optimizations for windowed games; NX04-003 Variable Refresh Rate (windowed) | NX02, NX04 | (CURATED) Composer-enforced sharing: NX02-005 writes SwapEffectUpgradeEnable and NX04-003 writes VRROptimizeEnable inside the same DirectXUserGlobalSettings REG_SZ. The function preserves sibling components by read-modify-write and journals the whole original value, so the pair is SAFE to combine; the registry states "No conflict remains (composer-enforced sharing)". |

## 7. Preset-pairing hazards (CURATED where marked)

These are composition hazards that the declared conflict graph does not fully express. `registry-declared` rows restate a declared conflict with an operational resolution; `CURATED` rows are agent findings and must not be presented as registry declarations.

| Pair | Status | Hazard | Resolution | Evidence |
|---|---|---|---|---|
| NX11-006 <-> NX13-013 | CURATED hazard (no declared conflict) | Both can disable the same scheduled tasks; NX13-013 states that 8 of its 9 task names overlap NX11-006. Either entry is idempotent against the other, but selecting both for the same task is redundant. | Pick one owner: NX13-013 for the telemetry task set (it owns that curation), NX11-006 for non-telemetry allow-listed tasks. Do not select both for the same task in one preset. | NX13-013.sideEffects / NX11-006.technicalExplanation |
| NX11-009 <-> NX05-004 | CURATED hazard (no declared conflict) | Memory-compression changes require SysMain to be running; NX11-009 can disable SysMain, after which the compression change fails cleanly (service dependency, error 1058) or cannot take effect. | Do not disable SysMain in a preset that changes memory compression. Leave compression at its default when SysMain is disabled, or keep SysMain running when compression is selected. | NX11-009.sideEffects / NX05-004.sideEffects |
| NX12-004 <-> NX13-012 | registry-declared symmetric conflict; curated resolution | App removal and policy disable reach the same phone-PC linking feature from two directions; selecting both is redundant. | Choose one. NX13-012 disables phone-PC linking and cross-device clipboard without deleting an app; NX12-004 removes the Phone Link app. | NX12-004.technicalExplanation / NX13-012.sideEffects |
| NX12-005 <-> NX11-010 | registry-declared symmetric conflict; curated resolution | Removing the Xbox app and configuring Xbox services both change the Xbox client surface; service background activity is NX11 territory while app removal is NX12 territory. | Choose the removal (NX12-005) or the service configuration (NX11-010), not both in one preset. Game Pass users are excluded from NX12-005 by its evidence gate. | NX12-005.technicalExplanation / NX11-010.sideEffects |
| NX12-005 <-> NX02-008 | registry-declared symmetric conflict; curated resolution | NX12-005 removes the Xbox app; NX02-008 is the read-only Xbox dependency report that must inform that decision. The report itself mutates nothing, so the conflict is about decision order, not mechanical exclusion. | Run/read NX02-008 first (report only), then decide on NX12-005. Never treat the report as an applied change; do not bundle the pair as "the Xbox preset" without the Game Pass gate. | NX02-008.technicalExplanation / NX12-005.sideEffects |

## 8. Do not combine in one preset

Derived from section 3 (every declared pair) plus the curated hazards in section 7. "Alternative" means select one; "ordered" means the pair may be combined only in the stated order (and is not a preset default); "redundant" means both apply the same change to the same target.

| Pair / set | Kind | Rule | Source |
|---|---|---|---|
| NX02-008 / NX11-010 / NX12-005 | decision-order (set) | Read the read-only dependency report first; then choose at most one change (NX11-010 or NX12-005). | Declared conflict group (derived) |
| NX05-001 / NX05-002 / NX05-003 / NX05-009 | alternative (set) + compatible sub-pair | NX05-001/002/003 are mutually exclusive pagefile modes. NX05-009 (crash-dump type) may be combined with NX05-001 or NX05-002, but never with NX05-003 (no pagefile). | Declared conflict group (derived) |
| NX07-016 / NX07-017 / NX07-018 / NX07-020 / NX07-021 | ordered (set) | The reset rewrites the stack; run it alone, then re-apply targeted settings. Do not bundle reset + configuration in one unattended preset. | Declared conflict group (derived) |
| NX02-008 / NX12-005 | decision-order | Read the report first, then decide on removal; not a mechanical exclusion (the report mutates nothing). | Registry-declared (section 3) |
| NX05-001 / NX05-002 | alternative | Both entries reach the same feature/target; select one. | Registry-declared (section 3) |
| NX05-001 / NX05-003 | alternative | Both entries reach the same feature/target; select one. | Registry-declared (section 3) |
| NX05-002 / NX05-003 | alternative | Both entries reach the same feature/target; select one. | Registry-declared (section 3) |
| NX05-003 / NX05-009 | incompatible | No pagefile means kernel/complete/automatic crash dumps cannot be written; do not pair dump capture with pagefile removal. | Registry-declared (section 3) |
| NX07-016 / NX07-021 | ordered | The reset can clear this setting; run the reset alone, then re-apply. Do not bundle both in one unattended preset. | Registry-declared (section 3) |
| NX07-017 / NX07-021 | ordered | The reset can clear this setting; run the reset alone, then re-apply. Do not bundle both in one unattended preset. | Registry-declared (section 3) |
| NX07-018 / NX07-021 | ordered | The reset can clear this setting; run the reset alone, then re-apply. Do not bundle both in one unattended preset. | Registry-declared (section 3) |
| NX07-020 / NX07-021 | ordered | The reset can clear this setting; run the reset alone, then re-apply. Do not bundle both in one unattended preset. | Registry-declared (section 3) |
| NX11-010 / NX12-005 | alternative | Both entries reach the same feature/target; select one. | Registry-declared (section 3) |
| NX12-004 / NX13-012 | alternative | App removal vs policy disable for phone-PC linking; choose one. | Registry-declared (section 3) |
| NX19-003 / NX19-004 | alternative (mechanism) | CPU Sets vs affinity for the same process; affinity overrides CPU sets, so select one mechanism. | Registry-declared (section 3) |
| NX11-006 / NX13-013 | redundant (same task) | Pick one owner: NX13-013 for the telemetry task set (it owns that curation), NX11-006 for non-telemetry allow-listed tasks. Do not select both for the same task in one preset. | CURATED hazard (section 7) |
| NX11-009 / NX05-004 | redundant (same task) | Do not disable SysMain in a preset that changes memory compression. Leave compression at its default when SysMain is disabled, or keep SysMain running when compression is selected. | CURATED hazard (section 7) |

Not in this list: `NX02-005` + `NX04-003` (DirectX global-settings components) are explicitly safe to combine because `Set-NxDirectXGlobalSetting` is a composer; see section 6.

---

Generated by `tools/Export-NxMatrices.ps1`. Repository source of truth: `registry/`. Curated notes are labelled; everything else is mechanical.
