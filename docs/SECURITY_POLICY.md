# NEXTRIX — Security Policy

**Status:** v1.0 — binding for all NEXTRIX engineering and releases. Mechanically enforced items carry their enforcement point.

## 1. Security posture (NX14 and directive Section 15)

1. **Security protections stay on by default.** Defender, Firewall, UAC, SmartScreen, Secure Boot, TPM, VBS/HVCI and mitigations are never disabled by any preset, and never automatically. Consent-gated exceptions exist only where a documented reason survives review, always `ADVANCED`/`TROUBLESHOOTING` risk + `ExplicitConsent` approval, always preset-excluded, always journaled.
2. **Preset exclusion list (Section 15)** is enforced by the build validator (`tools/Test-NxRegistry.ps1` + `registry/schema.json`): banned registry targets and never-touch services are **hard errors at build time** — they cannot ship even by accident. Current banned set: `EnableLUA=0`, `VulnerableDriverBlocklistEnable=0`, `SaveZoneInformation=1`, SmartScreen off, HVCI off without consent, `PreventDeviceEncryption=1`, mitigation overrides/masks without ExplicitConsent, direct `ControlSet001/002` writes.
3. **Never-touch services** (validator-enforced): the update stack, audio, security/Defender stack, firewall (BFE/mpssvc), profile/state services, Store, networking core, VSS/swprv — the union of the UltraOS validator list and Atlas/Firewall protections. Blanket "disable-all services" does not exist anywhere in NEXTRIX.
4. **Recovery substrate is inviolable:** NEXTRIX creates restore points and never deletes shadow copies, WinRE verification, crash dumps or event logs — the exact inversion of the reference-ecosystem pattern documented in `PROJECT_RESEARCH.md`.
5. Windows Update is never disabled or frozen by any preset (the 2038-freeze and driver-block patterns are on the rejected list with evidence).

## 2. Platform trust posture (ADR-006 — owner-accepted, disclosed)

The delivery vehicle is AME Wizard (AME Beta v0.8.4 at time of decision), which is an **unsigned beta whose official instructions require Defender exclusions**, packages playbooks in fixed-password encryption whose documented purpose is AV-scan evasion, and grants "verified" status via a discretionary process NEXTRIX cannot obtain. NEXTRIX's binding compensations:

1. NxJournal/NxRollback is the sole rollback authority (the platform provides none).
2. `UseKernelDriver: false` always; **no** `DefenderDisabled`/`UCPDDisabled` requirements in NEXTRIX's own playbook (UltraOS model).
3. This posture is disclosed to users in README/docs — never hidden.
4. Wizard version pinned in testing records; schema drift tracked via the official docs changelog.
5. NEXTRIX release artifacts are hash-pinned (`SHA256SUMS`) with published contents; **zero floating downloads at install time**; target: zero bundled third-party binaries.
6. **Known residual:** the wizard's runtime EULA text is not published online (PD-2 residual) — documented as unknown, never asserted.

## 3. Credential and secret handling

- No secrets in the repository, the journal, or the support bundle (`.gitignore` blocks `.env`/keys/tokens; NX16-017 scrubs machine identifiers).
- Tooling uses the owner's locally cached git credential only through git's own credential helper; tokens are never displayed, logged, or persisted by NEXTRIX tooling.
- Never access `service.json` (standing rule).

## 4. Script and execution policy

- No persistent `ExecutionPolicy Unrestricted/Unrestricted -Force` ever (rejected list, r1–r4). Development validation uses process-scoped `-ExecutionPolicy Bypass` for a single script invocation only.
- All NEXTRIX PowerShell is 5.1-compatible, strict-parameterized (`[CmdletBinding()]`), idempotent, with meaningful exit codes; no encoded/obfuscated commands, no hidden execution, no downloads at apply time.
- Engine functions never run outside their declared mutation surface — each module's header states its surface (read-only modules: NxHardware, NxBuild, NxCompat, NxVerify).

## 5. Testing boundaries (directive Section 16 — permanently in force)

- No NEXTRIX modification is applied to the development machine during engineering. Validation is: static schema/syntax checks, temp-folder self-tests, and read-only detection smoke tests. Functional and performance validation happens only on the owner's test hardware.
- Only the owner promotes statuses beyond `ConfigurationValidated` (TWEAK_CLASSIFICATION.md ladder).

## 6. Supply chain

- Zero bundled binaries target; if a third-party component is ever unavoidable, its license + hash pinning + `THIRD-PARTY-NOTICES.md` are mandatory (LICENSING_REVIEW.md).
- No Discord-gated or third-party-host distribution of NEXTRIX artifacts; GitHub releases with `SHA256SUMS` only (ADR-007).
