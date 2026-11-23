# NEXTRIX — Playbook Comparison

**Status:** Phase 1 deliverable · generated 2026-11-23 from `research/sources/r1–r6` (all evidence-tagged there). Comparison covers the 12 tweak-implementing references + the AME platform + Hone as a claims-only contrast.

## A. Architecture & safety dimensions

| Project | Build gate (code) | Defender | Windows Update default | Rollback architecture | Verification tooling |
|---|---|---|---|---|---|
| FSOS-X | claims-only | optional full removal | unchanged (claims) | per-toggle Dash; no pre-change capture claim | vendor QA only |
| XOS PB | 19045/22631/26200/26300 | disable default (option) | off by default | stock-capture + only-if-ours restore + per-area backups | per-step logs, exit codes |
| Atlas | 26200/26300 GA-only | CBS removal (choice) + SAC/Phishing off always | **off by default** | validated service backup; transactional state; honest limits | ~130 Pester files; VM gate; read-only health check |
| ReviOS | 19044–26300 | **force-disabled during every run**; disable default | paused to 2038 | upgrade-only revert ledger; uninstall = packages + ISO repair | CI hash pinning |
| SapphireOS/-PB | 19044–26200 | removal + permanent root cert | frozen to 2050 | Start-exports + toggle kit; recovery substrate disabled | none observed |
| Vain | 22631–28000 | file deletion (irreversible) | policy-locked | session self-revert (closed); shadows deleted | none public; closed engine |
| SynergyOS | 19044–26300 (incl. 22635) | CBS removal + root cert | paused to 2038; drivers blocked | Start-export helper; wizard re-run | GitHub release workflow |
| UltraOS | 26100/26200/26300 exact | **never touched** | automatic or notify-only, never off | **4 layers (L0–L4) with honest scope** | dry-run engine simulator + hard-error validator |
| WinUtil | none (tolerant) | sample-consent tweak only | explicit disable flow (opt-in) | undo-metadata field-flip; conditional service undo | Pester over tweak data |
| Sophia | pinned 26300/UBR≥9974 | kept; hardening functions on | untouched | paired-parameter undo + forced restore point; no journal | guard chain; no test suite published |
| Hone | none published | not removed (claims) | untouched (claims) | per-value backup (claims) + session auto-restore | self-published 7-gate methodology |
| AME Wizard | per-playbook + per-action | normalized as requirements | n/a | **none (ISO repair; pre-1.0 roadmap)** | discretionary manual verification |

## B. Engineering-quality dimensions

| Project | Hardware awareness | Documentation honesty | Integrity incidents observed |
|---|---|---|---|
| FSOS-X | chassis/VRR/iGPU detection (closed) | honest FAQ; "no known issues" over-reach | MPO toggle pulled twice; upgrade once deleted OneDrive files (R7) |
| XOS PB/TK | best-in-class topology derivation (open) | per-value logs; VM-only beta disclaimer | repo ahead of stable release; stable C# unauditable |
| Atlas | vendor-aware mitigation values; VM gate per arch | "what we don't change and why" tables; no perf claims | same-day 0.6.0→0.6.1 hotfix; AMD chipset breakage #1618 |
| ReviOS | none significant | revert ledger names its own breakage | force-disable during deploy; VBS silent no-op #222; modsfire distribution |
| SapphireOS | chassis split; SSD/HDD pairs; VMware case | README "unsupported" lists honest | contradictory reg sections; malware accusation (evidence-free); Discord gating |
| Vain | closed heuristic (X3D/CCD claims) | honest beta labeling | closed self-signed engine; hardcoded game list |
| SynergyOS | NIC Ndi\Params probing (good) vs blanket sweeps (bad) | reversible/irreversible labels | vbs.bat referenced but missing from tree; 26H2 "experimental" |
| SynToolkit | uncertainty-state detection model (best in class) | in-code honesty comments | README/code floor mismatch (17763 vs 19041) |
| UltraOS | only-if-present NIC writes; RAM/NVMe thresholds in labels | per-action provenance; placebo list | INSTALL.md undo over-claim vs UNDO.ps1; two self-audited doc/code gaps |
| WinUtil | RAM-conditional tweak data; laptop warnings as categories | known-issues page maintained | Revert-Start-Menu dead since KB5089573 while still offered |
| Sophia | arch/edition/NPU/laptop guards | edition-honest telemetry floor | refusal path mutates system; pinned-UBR brick risk |
| Hone | claims only | methodology unusually honest; Epic listing over-claims | AV-flag reports; ToS restricts scrutiny |
| AME Wizard | per-action cpuArch gating | docs admit no uninstall | unsigned + exclusion instructions; AV-evasion packaging rationale |

## C. NEXTRIX positioning

**Adopted from each (open reimplementation, license-compliant):**

- **FSOS-X** — NX18 session lifecycle requirements: verified-step restore, launcher waits, capture exclusions, plan pair, cooldown, anti-cheat blocking reports.
- **XOS** — journal semantics (capture-refusal, only-if-ours), topology derivation chain, CPU-Sets-default policy, verified task disabling, plan lifecycle safety.
- **Atlas** — VM-gate evidence discipline for service changes, post-apply re-read with `notApplied`, exit-code contract, never-change-without-exact-rollback test, hash pinning.
- **ReviOS** — the negative-results ledger as permanent regression-test data; onUpgrade deprecation ledger pattern.
- **SapphireOS** — anti-cheat DEP compatibility knowledge (FACEIT/Valorant); SSD/HDD parameterization; resync micro-pattern; mask-derivation technique.
- **Vain** — session self-revert *contract* (implemented openly), per-process rule schema, per-action build gating, `nx optin` stance, beta honesty.
- **SynergyOS** — NIC `Ndi\Params` capability probing and virtual-adapter exclusion (facts only; unlicensed repo).
- **SynToolkit** — uncertainty-state detection pattern, VRAM wraparound fix, junk-SMBIOS sanitization, restore-point honesty model, BCD-via-WMI with read-after-write.
- **UltraOS** — layered rollback L0–L4, never-touch validator, honest-uncertainty annotations, dry-run harness requirement, placebo list, zero-bundled-binary packaging.
- **WinUtil** — undo-metadata-in-data schema (`OriginalValue`/`OriginalType`/`<RemoveEntry>`), conditional service undo, idempotent executors, import pre-validation.
- **Sophia** — preflight guard chains (read-only refusal), edition-aware settings, policy hygiene, DNS verify-and-auto-rollback, harmful-tweaker detection as a reporting feature.
- **Hone** — tweak-admission scorecard and metric discipline as the owner-testing methodology template (results still owner-only).
- **AME Wizard** — the 14-action declarative schema, per-action build/cpuArch gating, requirement gates, feature pages, upgrade semantics (generated against; runtime trust debt declined via ADR-006 compensations).

**Inverted versus every reference:** recovery-substrate sabotage. References disable System Restore/VSS/WinRE/crash dumps/event logs; NEXTRIX NX16 *creates* restore points, preserves every recovery mechanism, and journals everything.

**Exceeded versus every reference:** (1) exact-original-state journal with conditional restore — no reference restores the user's actual prior configuration wholesale (XOS closest; its own toolkit uninstall "restores Windows defaults, not your previous configuration"); (2) hardware-aware eligibility on every entry (XOS/SynToolkit approach, generalized); (3) evidence discipline — every entry carries risk + evidence tags, and performance claims are structurally impossible until the owner supplies results; (4) honest reversibility labeling per modification (Store-reinstallable vs media-requiring), per directive Section 8.

**Key divergences that shaped decisions:** every reference that disabled Defender documented recurring fallout; every reference that starved updates documented breakage cascades; the two best-engineered projects (Atlas, UltraOS) both converge on conservative service policy + strict build gates + layered rollback — which is precisely the NEXTRIX posture already encoded in the catalogue and classification documents.
