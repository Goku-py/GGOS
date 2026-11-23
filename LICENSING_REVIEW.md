# NEXTRIX — Licensing Review

**Status:** Phase 1 deliverable · generated 2026-11-23 from license texts actually fetched and read (`research/sources/r1–r6`; every LICENSE file cited there). Governs what NEXTRIX may reuse, reference, or redistribute.

---

## 1. Reference-project license table

| Project | License (verified from source) | Reuse rule for NEXTRIX |
|---|---|---|
| Chris Titus WinUtil | MIT (© 2022 CT Tech Group LLC — full text read) | Reuse permitted with attribution |
| Sophia Script | MIT (© 2023 farag2 — full text read; no extra clauses) | Reuse permitted with attribution; maintainer's anti-wrapper stance is community policy, not license — respected as such |
| trusted-uninstaller-cli (AME engine) | MIT (© Ameliorated LLC — full text read) | Permitted with notice; not currently needed |
| ame-assassin / appfetch / jumper (AME org) | MIT | Permitted with notice |
| AtlasOS | GPL-3.0 | **Reimplement patterns only — no code copying** (GPL contagion) |
| SynToolkit | GPL-3.0 (+ retained MIT-licensed material documented in-repo) | Reimplement patterns only |
| UltraOS | GPL-3.0 + `NOTICE` (full attribution chain incl. Atlas GPL, ReviOS CC BY-SA values, winutil MIT) | Reimplement patterns only; NOTICE is the model practice if attribution is ever needed |
| SapphireOS / -Playbook | GPL-3.0 declared globally over bundled proprietary binaries with **no third-party notices** | Reference only; a hygiene failure, not a pattern to copy |
| XOS Playbook + Toolkit | **CC BY-NC-ND 4.0** | **Reference-only** — no copying of code, YAML, branding, `.nip` profiles; non-commercial clause also applies |
| ReviOS | CC BY-SA 4.0 (changed from CC BY-NC-SA in 25.10) | Ideas only; content reuse would force share-alike |
| SynergyOS | **No license at all** (verified: no LICENSE in tree; API `license: null`) | **Facts only; zero code/YAML reuse** (registry paths and value semantics are facts; scripts are not) |
| Vain Playbook | Custom all-rights-reserved (third-party file properly quarantined as MIT: PS-SFTA, RunAsTI) | Reference only |
| FSOS-X | Polyform Non-Commercial, "source available" = password-protected commercial archive | No copying; no commercial use |
| Hone | Restrictive ToS (AuraSide, Inc.) | **Citation-only**: no redistribution, no public/commercial display of content *including screenshots* without written permission; mandatory arbitration/class waiver noted. NEXTRIX references Hone only by URL and short quotation for research |

## 2. Platform terms (AME Wizard — binding on NEXTRIX releases per ADR-006)

1. **Wizard GUI source is not published** (9-repo org inspected; absence verified). The engine (`trusted-uninstaller-cli`) is MIT; the GUI the user actually runs is closed.
2. **Official playbooks ship without LICENSE files** (Privacy+, AME 10 — verified). Default copyright applies: no permission to modify/redistribute their playbook content. NEXTRIX does not copy any playbook task code.
3. **Wizard EULA text is not published online** (residual unknown, PD-2). The wizard displays a license agreement at runtime; NEXTRIX documentation must note this to users rather than assert terms we cannot read.
4. **Verification is centralized and discretionary** (Discord/Telegram handles), and is lost on any modification. A NEXTRIX playbook would ship permanently unverified on the platform; docs must disclose this.
5. **`.apbx` packaging uses a fixed public password whose documented purpose is AV-scanning evasion.** NEXTRIX discloses this honestly and compensates with hash-pinned, contents-published artifacts (ADR-006 compensation 5).
6. ReviOS's docs require "removing their product code before modification" of their playbook — the ecosystem norm is fork-hostile; NEXTRIX authoring is fully original.

## 3. Distribution-model cautions recorded

- **Discord-gated distribution** (SapphireOS) makes binaries unauditable and left an unresolved malware accusation in the public tracker — NEXTRIX distributes via public, hash-pinned artifacts only.
- **Third-party file hosts** (ReviOS via modsfire) weaken the supply chain even with SHA-256 published — NEXTRIX releases attach artifacts with `SHA256SUMS` (UltraOS release-hygiene model).
- **Floating downloads at install time** (Vain updater; Sapphire .NET/vcpp fetches; XOS Toolkit components) — unpinned, unhashed. NEXTRIX: zero floating downloads (global constraint + ADR-006).
- **Bundled binaries** (Sapphire/Synergy/SynToolkit ship .exe/.sys blobs incl. a kernel driver) — NEXTRIX target is zero bundled binaries; if ever unavoidable, per-component licenses + `THIRD-PARTY-NOTICES.md` are mandatory (UltraOS/Vain- notices practices).

## 4. Research-time compliance (already honored, recorded for audit)

- All research snippets across `research/sources/` are under 10 lines, each labeled with source URL and license (GPL-3.0, CC BY-NC-ND 4.0, MIT, custom — as applicable).
- No proprietary or licensed implementation was copied into NEXTRIX documents; findings describe behavior and record facts.
- Closed/licensed products (FSOS-X, Hone, Vain tools) were never downloaded, extracted, decompiled or reverse-engineered; Vain's license forbids RE and this was respected as a hard research limit.

## 5. NEXTRIX's own licensing (open owner decision — PD-6)

Options for the repository license (owner decides before first public release):

- **MIT / Apache-2.0** — maximal reuse friendliness; consistent with a transparency-first tool; no copyleft obligations on downstream.
- **GPL-3.0** — ecosystem-common among references; ensures derivative playbooks stay open; complicates any future proprietary packaging.
- Patterns adopted from GPL projects (Atlas, SynToolkit, UltraOS) are **reimplemented, never copied**, so NEXTRIX is not compelled to any license by its research; the choice is purely product strategy. The tweak *registry data* (paths, values) are facts and not copyrightable; NEXTRIX's original descriptions, schema and code are the protected/authored layers.
