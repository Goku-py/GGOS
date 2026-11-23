# NEXTRIX — Compatibility Research

**Status:** Phase 1 deliverable · generated 2026-11-23 from `research/sources/r1–r6`. Covers build guards, capability-detection patterns, and documented compatibility incidents across the reference ecosystem, with their NEXTRIX implications.

---

## 1. Build-guard matrix (code-checked, not claimed)

| Project | Supported builds | Guard mechanism | Notable guard facts |
|---|---|---|---|
| XOS Playbook | 19045, 22631, 26200, 26300 | `SupportedBuilds` + nested runtime `-ge` checks | **Skips 24H2 (26100)**; refuses "device-only 26H1"; Home-edition WU-policy caveat documented |
| Atlas | 26200, 26300 only | manifest + GA-release catalog + UBR checks | Insider/preview refused; unlisted revisions classified online (Released/Preview/Unlisted/Unknown); "eligibility isn't authenticity" |
| ReviOS | 19044, 19045, 22631, 26100, 26200, 28000 (26H1), 26300 (26H2) | `SupportedBuilds` | labels 28000 as 26H1; ISO mode = AME Beta only, "experimental" |
| SapphireOS-PB | 19044, 19045, 22621, 22631, 26100, 26200 | `SupportedBuilds` | includes 22H2 (22621) |
| Vain | 22631, 26100, 26200, 26300, 28000 | `SupportedBuilds` + per-action `builds:['>=26100']` | per-action build filtering in active use |
| SynergyOS | 19044, 19045, 22000, 22621, 22631, **22635 (beta)**, 26100, 26200, 26300 | `SupportedBuilds` | 26H2 marked "experimental" in release notes |
| UltraOS | 26100, 26200, 26300 only | hard list + wizard refusal | single servicing-branch rationale; 26H1 (28000, ARM interim) explicitly unsupported |
| Sophia (Win11 variant) | 26300 with UBR ≥ 9974 | JSON build+UBR guard, online with offline fallback | refusal triggers update-guidance UX (but mutates system — rejected part) |
| WinUtil | none | tolerant executors | stale tweaks silently no-op (cautionary) |

**Resolutions and cautions for NEXTRIX:**

- **Windows 11 26H2 = build 26300** (ADR-003 amended; four independent code sources agree: Atlas, ReviOS, Sophia, UltraOS). 28000 is the 26H1 ARM-only interim; 22635 is the beta channel.
- **24H2 (26100) is the divergent build:** skipped by XOS, marked with UCPD-specific workarounds by Synergy (`TaskbarDa` protected; policy fallback required), supported by five others. → NEXTRIX: 24H2-targeted tweaks get extra capability checks and the UCPD policy-fallback pattern; capability detection remains primary everywhere.
- No reference matrix is inheritable wholesale; NEXTRIX keeps Win11 23H2–26H2 with per-tweak capability gates (directive Section 10 confirmed as the only defensible model).

## 2. Capability-detection patterns adopted

1. **Existence checks before mutation** (service `Type` check, `reg query`-before-`reg add`, missing-service = skip-not-error) [XOS r1; WinUtil r5].
2. **UCPD-aware writes:** when a direct value is UCPD-protected (24H2+ `TaskbarDa`), write the policy instead — with the failure mode publicly documented [Synergy r4].
3. **Launch-protected services** (`WaaSMedicSvc`): `Set-Service` fails; direct registry `Start` write is the documented workaround; third-party SYSTEM deny-ACEs must be cleared first [WinUtil r5].
4. **Per-user service naming is build-fragile** (`BcastDVRUserService_389fd` hardcoded suffix) → resolve names at runtime [Synergy r4].
5. **KB5089573 (May 2026) removed legacy Start-menu code** — Start-menu-revert tweaks are dead on current builds; capability gate required [WinUtil r5].
6. **MSIX PowerShell 7 breaks DISM cmdlets** ("Class not registered") → shell out to `powershell.exe` for DISM operations from PS7 contexts [WinUtil r5].
7. **Modern Standby (S0ix) partially ignores classic plan settings** — power entries carry the caveat [UltraOS r4].
8. **WMI `AdapterRAM` wraps >4 GB** — use the GPU class-key `qwMemorySize` with per-subkey fault tolerance [SynToolkit r4].
9. **`Disable-MMAgent` requires SysMain running** (error 1058) — temporarily start before disabling; ordering matters [Synergy r4].
10. **`New-Item -Force` on an existing registry key deletes the key and subkeys first** — Test-Path guards mandatory [WinUtil r5].
11. **Restore-point 24 h throttle** — sequence-diff verification; keep-existing-point behavior; `Unverified` ≠ `Failed` [SynToolkit r4; UltraOS r4].
12. **Smart App Control blocks AME Wizard loading** (`FileNotFoundException`) — detected and reported before the user wastes a run [XOS r1].

## 3. Documented compatibility incidents (grouped; all sources in r-files)

**Windows Update / servicing**

- Revi #49: deprecated `!systemPackage` removal left WU unable to reinstall packages — technique abandoned for CABs [r2].
- Edge removal → Windows Update loops (most-documented consequence in the ecosystem) [r4].
- Removed apps return after feature updates (Microsoft-documented behavior) [r4, r2].
- Home edition ignores the update-off policy XOS uses [r1].
- WinUtil update-disable flow + its 13-step reset/repair tooling, incl. the blunt policy-tree deletion in aggressive mode [r5].

**Anti-cheat**

- THE FINALS breaks with mitigations off and with the vulnerable-driver blocklist disabled [r2].
- Riot Vanguard requires CFG on its own processes even when system-disabled (Atlas ships a per-process exception) [r2]; Valorant/FACEIT users must keep mitigations/VBS on (FSOS-X FAQ; XOS checklist) [r1].
- EAC-adjacent trigger: the all-2s mitigation mask (UltraOS deliberately refuses it) [r4].
- Anti-cheat false positives from rapid session spam-launching (FSOS-X added a cooldown) [r1].

**Hardware-specific**

- Atlas #1618: AMD chipset installer fails at 64 % on Atlas-modified systems [r2].
- Revi #167: `disabledynamictick` broke ROG Ally sleep [r2].
- Revi #222: VBS disable silently no-ops on Secured-core (UEFI-locked) machines — UI claims success [r2].
- Killer/Realtek NICs misbehave when forced keywords they don't expose [r4].
- MPO disable → "desktop composition is disabled" errors + game crashes (FSOS-X R8) [r1].
- GPU priority on integrated graphics broke in-game mouse (FSOS-X R11) [r1].
- Touchpad disable ineffective despite value writes (Sapphire #8) [r3].
- SMB 1.0 stops working after NetBT/tcpipreg disables (Revi #228) [r2].
- Xbox controller-over-Bluetooth + laptop touchpads need re-enable paths (XOS documented) [r1].

**Removal fallout**

- Defender removal: recovery-screen signature error (FSOS-X R11H1), leftover files/drivers, AV false positives on re-toggles, "reinstall Windows" recovery [r1, r2, r3].
- WebView2 removal broke Settings search (FSOS-X R11H2, fresh-install fix required); 15+ apps depend on WebView2 [r1, r4].
- OneDrive removal once deleted user files (FSOS-X R7 critical bug; WinUtil now ACL-protects user files during removal) [r1, r5].
- Xbox removal → ms-gamebar popup when connecting a controller [r1].
- iCloud Passwords/Keychain init failure (Atlas #1749) [r2].

**Tooling / engine incidents**

- UltraOS v1.0.0 failed to load in AME Wizard (undocumented engine rules: RadioPage option caps, `UpgradableFrom: none` illegal) → produced their dry-run harness [r4].
- UltraOS v1.1.1 halted on every fresh install (folder-name copy bug) — "a bug class neither the dry-run harness nor the validator could see" [r4].
- Synergy #20: 26H2 run "completes with error every time" — UCPD-protected `TaskbarDa` write (non-fatal) [r4].
- Atlas 0.6.0 → same-day 0.6.1 hotfix for install/update failures; StateRepository install failures (#1763) [r2].
- VCLibs re-provision fixed a wsappx infinite CPU loop (Revi 26.10) [r2].
- AME Beta extracting `TrustedUninstaller.CLI.exe` as ARM64 on x64 (Atlas #1623, AME-era) [r2].

## 4. NEXTRIX implications (binding for Phase 3/4)

1. Every catalogue entry carries per-build notes where the matrix diverges (24H2 policy fallbacks; 26H2 experimental status until owner-validated).
2. The incident catalog above becomes regression-test inputs for the build validator and the per-tweak manual test sheets.
3. The never-touch service list (UltraOS) and harmful-tweaker detection (Sophia, as read-only reporting) are foundation requirements, not options.
4. Rejected techniques in `TWEAK_CATALOGUE.md` are mechanically enforced: the validator hard-errors on any entry whose action set matches a documented anti-pattern.
5. Insider/beta builds (22635-class) are experimental per directive — the SynergyOS 26H2 experience says new-build support starts as "expect errors," honestly labeled.
