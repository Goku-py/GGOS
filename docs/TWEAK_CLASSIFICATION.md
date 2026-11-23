# NEXTRIX — Tweak Classification

**Status:** v0.1 — policy document (directive Section 6 conformance).
This document defines the *only* classification vocabularies used in the registry, catalogue, playbook and testing sheets. An entire category is never labeled SAFE or ADVANCED — classification is per tweak.

---

## 1. Risk classification (per tweak)

| Class | Meaning | Entry criteria | Preset eligibility |
|---|---|---|---|
| **CORE** | Low-risk, well-understood modifications and useful configuration/inspection controls | Well-understood target, reversible via journal, no functional sacrifice, no security impact, works across supported builds | Yes — default-on candidates in matching profiles (still individually deselectable) |
| **CONDITIONAL** | Valid for certain workloads, hardware or user preferences | Clear applicability condition (hardware, workload, preference) and a stated trade-off | Offered, never auto-applied; recommendation text must state the condition and trade-off |
| **ADVANCED** | Changes requiring additional understanding or compatibility checks | Multi-factor compatibility (driver, firmware, topology, build), higher blast radius, or documented side effects | No — opt-in only, with explanation and approval gate |
| **EXPERIMENTAL** | Uncertain, poorly generalized or highly hardware-dependent | Evidence at E0–E1 with weak generalization, or hardware-dependent behavior without cross-config verification | Never in presets; individually selectable with explicit warnings |
| **TROUBLESHOOTING** | Intended to resolve specific documented problems, not to "improve general performance" | Targets a named symptom class (e.g. MPO artifacts, USB reconnection, capture failures) | Never in presets; applied only against the documented symptom, reversible, journal-stamped |

Classification is assigned at proposal, re-checked at implementation review, and recorded in the registry. Any change of class requires a registry version bump and a changelog entry.

## 2. Evidence classification (per tweak)

| Level | Meaning |
|---|---|
| **E0** | Unverified claim — community-known configuration with no authoritative documentation of the behavior claimed |
| **E1** | Documented Windows/vendor behavior — the setting's existence and function are documented by Microsoft or the hardware vendor (documentation source recorded in the registry entry) |
| **E2** | Experimentally evaluated on an individual configuration (owner-supplied results, one machine) |
| **E3** | Repeatedly evaluated on multiple hardware configurations (owner-supplied results, multiple machines) |
| **E4** | Independently reproducible across diverse configurations |

Rules:

1. **Functional verification is not performance verification.** E-levels say what is *known about the setting's behavior*, not that it improves any metric.
2. Initial desk assignments in `TWEAK_CATALOGUE.md` are **E0 or E1 only**. Nothing starts higher.
3. E2+ can only be assigned from **owner-supplied test results** on physical hardware.
4. Every catalogue entry distinguishes the five verification questions: does the setting exist? does the modification work? does it have the intended configuration effect? does it improve the intended performance metric? does it preserve stability and required functionality? — the last two remain **PENDING** until owner evidence exists.

## 3. Implementation status ladder

| Status | Meaning | Who can grant |
|---|---|---|
| CANDIDATE | Proposed in the catalogue; nothing written | Coordinator |
| DEFINED | Full 30-field registry entry written, validated by `Test-NxRegistry` | Coordinator |
| IMPLEMENTED | Apply/rollback/verify code written | Coordinator |
| SYNTAX-VALIDATED | Static/syntax validation passed (no host execution of the modification) | Coordinator |
| CONFIGURATION-VALIDATED | Dry-run/plan mode and compatibility checks validated against a machine snapshot without mutation | Coordinator |
| FUNCTIONALLY-VALIDATED | Owner confirmed the change applies and holds on test hardware | **Owner only** |
| MANUALLY-HARDWARE-TESTED | Owner completed the tweak's manual test sheet on physical hardware | **Owner only** |
| PERFORMANCE-TESTED | Owner supplied benchmark evidence per the tweak's defined metric and methodology | **Owner only** |
| RELEASE-APPROVED | Owner approved inclusion in a release | **Owner only** |

At v0.6.0, **242 entries hold `SyntaxValidated` and 40 hold `Defined`**; no entry holds any owner-gated status (`ConfigurationValidated` and above are owner-only, per the ladder).

## 4. Performance-claim policy

- Repositories, docs, commit messages and UI text must not assert FPS/latency/DPC/frame-pacing improvements without owner-supplied evidence tagged to the tweak ID.
- "Faster", "lower latency", "smoother" are forbidden in tweak descriptions unless backed by owner evidence at E2+ recorded against that tweak.
- Permitted wording describes *configuration intent* ("reduces background capture writes", "pins scheduling to detected physical cores") — never outcomes.
- Vendor-documented behavior is described as such ("NVIDIA documents Low Latency Mode as …") with the source recorded.

## 5. Preset exclusion list (directive Section 15 — mechanically enforced)

Never emitted into Recommended/Competitive presets; individually selectable only, where permitted at all, with explanation and consent:

unrestricted Defender/Firewall removal · automatic UAC disable · automatic Windows Update disable · Secure Boot/TPM disable · unrestricted VBS/HVCI disable · unrestricted CPU-mitigation disable · automatic pagefile disable · blanket service disabling · global MSI configuration · arbitrary HPET forcing · arbitrary platform-clock forcing · unsupported BCD modifications · unrestricted kernel configuration · registry modifications without documented purpose.

Some of these have legitimate TROUBLESHOOTING/ADVANCED use with a documented reason; they stay isolated, explained, consent-gated and reversible. None ever appear in a preset.

## 6. Edition-applicability house rule (2026-11-23)

- **Include Home** where the applied layer is an ADMX-backed local policy (HKCU/HKLM policy path) that Windows evaluates on client SKUs — flag enforcement as documentation-limited where Microsoft's CSP editions table excludes Home.
- **Exclude Home** only where the mechanism is CSP/MDM-only with no local policy-engine path (no local enforcement exists).
- Entries must state which layer applies where; review evidence may never be inflated across editions. This rule resolves the NX01-003 (excluded) vs NX13 (included, flagged) divergence consistently.
