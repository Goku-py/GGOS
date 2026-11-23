# NEXTRIX — Hardware Compatibility

**Status:** Phase 6 deliverable (Wave 5, W5-C) · written 2026-11-23 · sources dated 2026-11-23.
**Scope:** what hardware NEXTRIX targets, what it can detect, what it refuses, and what remains unproven.
**Companion document:** `WINDOWS_COMPATIBILITY.md` (build, edition and capability gates).

**Evidence key used in this document**

| Tag | Meaning |
|---|---|
| `[REG]` | Field in a `registry/NX*.json` entry — the single source of truth |
| `[CODE]` | Behaviour read from `src/nxcore/*.ps1` |
| `[RES]` | `COMPATIBILITY_RESEARCH.md`, `PROJECT_RESEARCH.md`, `TWEAK_RESEARCH.md` |
| `[ADR]` | `DECISIONS.md` |
| `[DOC]` | `KNOWN_ISSUES.md`, `SECURITY_POLICY.md`, `TWEAK_CLASSIFICATION.md`, `PROFILE_MATRIX.md` |

**Reading rules**

1. "Supported" in this document means *the engine will attempt the entry and the registry declares how it is gated*. It does **not** mean validated on that hardware. No NEXTRIX entry holds any status above `SyntaxValidated`/`Defined` (242 `SyntaxValidated`, 40 `Defined`, 282 total, 2026-11-23) `[REG]`.
2. No performance claim appears anywhere in this document, and none may be inferred from "supported".
3. Where the registry and the engine disagree, both are stated and the gap is named. The gaps are recorded in §3.1 (gates outside `requiredHardware`), §5.5 (`excludedHardware` unread by the resolver) and §2.1 (no architecture gate).

---

## 1. How a hardware decision is made

The hardware gate is the **first** stage of eligibility, before build/capability, dependency and risk checks `[DOC] PROFILE_MATRIX.md §4` `[CODE] NxCompat.ps1:35`.

| Signal | Read by | Report field | Consumed by | If the read fails |
|---|---|---|---|---|
| CPU vendor | `Win32_Processor.Manufacturer` (GenuineIntel / AuthenticAMD substring) | `cpu.vendor` = `Intel`/`AMD`/`Uncertain` | Per-entry gates inside functions (NX03-011, NX03-012); reports | `vendor='Uncertain'` + uncertainty note; no CPU-vendor claim made `[CODE] NxHardware.ps1:37-40` |
| CPU topology (cores, SMT, P/E tiers, dies/CCDs, per-die L3, CPU Set map) | `GetLogicalProcessorInformationEx`, `GetSystemCpuSetInformation` | `Get-NxTopologyReport` (NX19-001) | NX19-002…011, NX17-007 (read-only feed) | `topologyAvailable=false` with the reason; nothing fabricated `[REG] NX19-001` |
| Hybrid / X3D classification | Per-die L3 asymmetry > 2× (strict) and EfficiencyClass tiers | `BestEffort` / `NoAsymmetryDetected` / `NotDeterminable` | NX19-011 guidance, NX19-002 pools | `NotDeterminable`; no name-based guess `[REG] NX19-011` |
| GPU vendor | PCI vendor ID from `PNPDeviceID` (`VEN_10DE`→NVIDIA, `VEN_1002`→AMD, `VEN_8086`→Intel) | `gpu.vendorsPresent[]`, `gpu.gpus[].vendor` | `requiredHardware.gpuVendor` gate, NX04/NX20 functions | `Uncertain` + `unmapped GPU vendor for '…' (VEN_x)` `[CODE] NxHardware.ps1:55-64` |
| VRAM | Display class key `HardwareInformation.qwMemorySize` (64-bit), WMI `AdapterRAM` only as a fallback | `vramBytes` + `vramSource` | Reports only | `vramSource='unavailable'`; WMI value explicitly marked as wrapping >4 GB `[CODE] NxHardware.ps1:65-84` `[RES] §2.8` |
| RAM total | `Win32_ComputerSystem.TotalPhysicalMemory` | `memory.totalGb` (rounded 0.1) | `minRamGB` gate (NX05-004) and NX11-009's own gate | `totalGb=null`; threshold check skipped **with a warning**, not a skip `[CODE] NxCompat.ps1:55-61` |
| Storage class | `Get-PhysicalDisk` MediaType/BusType (± `Get-Disk`, `Get-Volume` for the deep report) | `storage.hasSsd/hasHdd`, NX06-001 classification `nvme-ssd/ssd/scm/hdd/usb/unknown` | `requiredHardware.requiresSsd`, NX06-002, NX11-009 HDD gate | `hasSsd=false` → SSD-gated entries skip with a reason; storage class reported unknown, never assumed `[CODE] NxHardware.ps1:120-138` `[REG] NX06-001` |
| Chassis class | `Win32_Battery` presence **first**, else `Win32_SystemEnclosure.ChassisTypes` (≤7 = Desktop) | `chassis.chassisClass` = `Laptop`/`Desktop`/`NonDesktop`/`Uncertain` | `requiredHardware.chassis` (5 entries) | `Uncertain` → Laptop-gated entries skip with the detected value named `[CODE] NxHardware.ps1:140-161` |
| Power source | `Win32_Battery.BatteryStatus` (1 = Battery, 2 = AC) | `chassis.onAcPower` = `AC`/`Battery`/`Uncertain` | Reports (NX10-007), owner decisions | `Uncertain`; no AC/DC conclusion drawn `[CODE] NxHardware.ps1:154-159` |

The chassis classifier is **battery-first** on purpose: a device with a battery is treated as a laptop even when its enclosure type is a convertible/tablet code `[CODE] NxHardware.ps1:153` `[RES] §2 (XOS r1)`.

---

## 2. Supported platform matrix

### 2.1 CPU architecture

| Architecture | Status | Grounds |
|---|---|---|
| x64 (AMD64) | **Target** | All engine code is `#Requires -Version 5.1` Windows PowerShell; DISM is invoked as `%SystemRoot%\System32\dism.exe` with a 32-bit-host uncertainty note `[CODE] NX16.ps1:1131-1134`; `NxBuild` records `PROCESSOR_ARCHITECTURE` `[CODE] NxBuild.ps1:22` |
| ARM64 | **Out of scope until separately validated** | `[ADR] ADR-003` scope is Windows 11 builds only and no architecture statement or gate exists anywhere in the engine or playbook; 26H1 (28000) is the ARM-only interim and explicitly unsupported `[RES] §1`; the vendor tooling NX04/NX20 reference is not the ARM64 path |
| x86 (32-bit OS) | **Out of scope** | A 32-bit Windows 11 install does not exist; the engine only treats a 32-bit host as a DISM uncertainty condition `[CODE] NX16.ps1:1132` |

**Gap, stated plainly:** no architecture gate is enforced in code today. `NxBuild` records the architecture; `NxCompat` does not read it, and the playbook generator emits no `cpuArch` gate (`tools/Invoke-NxBuild.ps1`, playbook files: no occurrence). On an ARM64 machine the build-number gate would pass and entries would be attempted. Until an architecture gate is added, "ARM64 out of scope" is a documentation and release policy statement, not a mechanical block.

### 2.2 CPU vendors and topology

| CPU class | Entries affected | Behaviour | Status |
|---|---|---|---|
| Intel, hybrid P/E | NX03-012 (report), NX19-001/002 (tier derivation), NX19-003/004 (placement) | P/E tiers come from `EfficiencyClass` and, when present, `RelativePerformance`. The report states whether each was OS-supplied; the power-policy report marks hybrid topology `Uncertain-HybridTopologyRequiresNX19Engine` until NX19 has run `[REG] NX03-012` | Implemented as reports; **not hardware-validated** |
| Intel, symmetric | same entries | One efficiency class → `Standard` role label, no P/E split; conservative plan polarity guard `[REG] NX19-002` | Not validated |
| AMD, single CCD | NX03-011 (CPPC report), NX19-011 (X3D guidance) | CPPC: preferred-core control is `NotDocumented`, state `Unknown`. X3D: one die → `NoAsymmetryDetected`, no placement offered `[REG] NX03-011`, `NX19-011` | Not validated |
| AMD, dual-CCD / X3D | NX03-011, NX19-002/011 | X3D only via >2× per-die L3 asymmetry, always `BestEffort`; guidance names the derived large-L3 LPs and applies nothing `[REG] NX19-011` | Not validated |
| Any CPU, no CPPC / no hetero settings | NX03-011/012 | Reports applicability inside the function and returns `platformAvailable=false` with a reason `[REG] NX03-011/012` | Not validated |

There is **no CPU-vendor field in the registry**. NX03-011/012 deliberately leave `requiredHardware` empty and gate inside the function, because `requiredHardware.gpuVendor` would gate on the wrong component `[REG] NX03-011 technicalExplanation`. NX19 gates on the API result, not the vendor name. Any future CPU gate belongs in `NxCompat` as a new predicate — not in `gpuVendor`.

> **Prompt-vs-registry note:** the brief for this document assumed RAM gates in NX03. The registry has none: NX03's gates are CPU-vendor/topology only. RAM gates live in NX05-004 and NX11-009 (§2.4).

### 2.3 GPU vendors

| GPU vendor | Registry-declared entries | Guidance-only entries | If the vendor is absent |
|---|---|---|---|
| NVIDIA | NX04-009…016 (8), NX20-003 | NX04-002 (OS-side routing), NX04-008 (report) | Resolver reason `required GPU vendor 'NVIDIA' not present (detected: …)`; the guide function independently returns `mechanismAvailability='VendorHardwareAbsent'` `[CODE] NxCompat.ps1:37-42`, `NX04.ps1:818-826` |
| AMD | NX04-017…022 (6), NX20-004 | same | Same two-stage refusal |
| Intel | NX04-023, NX20-005 | same | Same two-stage refusal |
| None / Microsoft Basic Display | — | NX04-008 reports `vendor='None'` for `Microsoft Basic Display`/`Remote Display` | Reports only `[CODE] NxHardware.ps1:63` |

**Vendor-specific entries can never apply cross-vendor.** This is enforced twice: the compat resolver (`requiredHardware.gpuVendor`, single-vendor AND semantics — every listed vendor must be present `[CODE] NxCompat.ps1:37-42`) and the engine functions themselves (`Get-NxNvidiaStatus`/`Get-NxAmdStatus`/`Get-NxIntelStatus`; a false `supported` short-circuits to `VendorHardwareAbsent`). The generated playbook emits **no** hardware gate (`tools/Invoke-NxBuild.ps1`), so inside the wizard the function-level check is the effective one — that is the second, independent guarantee, not a duplicate.

**Honesty rule for driver profiles (NX04).** Per-profile driver settings are not writable through documented native Windows APIs. NX04 ships *guided* workflows plus read-only vendor-status snapshots; no entry fakes a driver-profile write, and any benefit claim is owner-testing territory `[REG] NX04 categoryNote, NX04-009..023` `[DOC] TWEAK_CLASSIFICATION.md §4`. Two consequences for hardware compatibility:

- "NVIDIA/AMD/Intel support" for NX04-009…023 means *the guide will run and will tell you the documented vendor route*, not that NEXTRIX configures the GPU.
- NEXTRIX cannot journal-revert a change the owner makes in vendor tooling; the entry says so `[REG] NX04-009 rollback`.

Hybrid graphics (iGPU + dGPU, or two dGPUs) is reported read-only by **NX04-008** (`Get-NxHybridGraphicsReport`): adapters with PCI-VID vendor classification, VRAM via `qwMemorySize`, driver versions, and the current per-app `UserGpuPreferences` routing, with uncertainty marks wherever a read fails. Desktops with iGPU+dGPU qualify equally; the laptop emphasis is a profile rule, not a hardware restriction `[REG] NX04-008` `[DOC] PROFILE_MATRIX.md §3 (P3)`.

### 2.4 Memory

| Gate | Declared in registry | Enforced in code | Behaviour below the threshold |
|---|---|---|---|
| Memory compression (NX05-004) | `requiredHardware.minRamGB = 16`; `excludedHardware.ramBelowGB = 16` | `Set-NxMemoryCompression -MinimumRamGB` (default 16) refuses with a named override `[REG] NX05-004` | Resolver skips; the function also refuses unless `-AllowBelowThreshold` is passed explicitly. Rationale: reference research records increased hard faults on 8–16 GB systems `[RES] §3` |
| SysMain configuration (NX11-009) | none (code-level) | Refuses `Disabled` below 16 GB unless `-AcknowledgeLowMemory`; refuses on an HDD boot volume unless `-AcknowledgeHdd` `[REG] NX11-009` | Returns `outcome='Skipped'` with the gate text; `Manual` and `Automatic` remain available |
| Pagefile entries (NX05-001/002/003) | none | Sizes are owner-supplied; disabling the pagefile states the commit-limit and dump consequences `[REG] NX05-003` | No automatic RAM-based sizing anywhere |

`minRamGB` is an inclusive floor (`totalGb < minRamGB` → skip). Unknown total RAM produces a **warning**, not a skip, so a failed memory read never silently enables a low-RAM path — it also never blocks it. That is a deliberate asymmetry: the function's own floor is the backstop `[CODE] NxCompat.ps1:55-61` `[REG] NX05-004`.

### 2.5 Storage

| Class / condition | Used for | Behaviour |
|---|---|---|
| NVMe SSD (`nvme-ssd`), SATA SSD (`ssd`), SCM (`scm`) | TRIM applicability, Optimize Drives, D3 | TRIM-off is documented as a no-op on rotational media, so NX06-002 refuses without SSD/SCM media `[REG] NX06-002` |
| HDD (`hdd`) | SysMain HDD gate; TRIM skip | `hasHdd=true` plus HDD boot volume → SysMain `Disabled` requires acknowledgement `[REG] NX11-009` |
| USB (`usb`), unknown media, `MediaType='Unspecified'` | Reporting | Kept as `unknown`; **not** rounded down to "not an SSD" `[REG] NX06-001` |
| `Get-PhysicalDisk` unavailable / SATA-NVMe class query failed | All storage gates | `hasSsd=false` + uncertainty note; SSD-gated entries skip with "requires an SSD, none detected (or storage class unreadable)" `[CODE] NxCompat.ps1:63-65` |
| Single SSD vs mixed SSD+HDD | NX06-003 schedule, NX06-011 per-device write cache, NX06-012 S0ix | Per-device; never a blanket sweep `[REG] NX06-011/012` |

Two storage distinctions worth naming, because "optimize" and "TRIM" are often conflated:

- **NX06-002** acts only on the TRIM/NTFS delete-notify state and refuses without SSD/SCM media; it is not a defragmentation control `[REG] NX06-002`.
- **NX06-003** configures only the maintenance schedule (Period/Deadline) of `\Microsoft\Windows\Defrag\ScheduledDefrag`; it never disables or deletes the task, never invents a trigger, and reports-and-skips a task without `MaintenanceSettings` `[REG] NX06-003`.

### 2.6 Chassis

| Chassis value | Definition | Entries gated on it |
|---|---|---|
| `Laptop` | `Win32_Battery` present (battery-first) | NX09-010 (lid), NX09-011 (battery conservation), NX09-015 (battery report), NX10-006 (OEM cooling), NX10-007 (AC/DC thermal) |
| `Desktop` | No battery; `ChassisTypes` contains a code ≤ 7 | none declared |
| `NonDesktop` | No battery; enclosure codes above 7 (tablet, convertible, embedded…) | none declared |
| `Uncertain` | Neither read succeeded | Laptop-gated entries skip: `requires chassis 'Laptop', detected 'Uncertain'` |

Consequence worth stating: a laptop whose battery is not reported by WMI (rare firmware/VM cases) classifies as `Desktop`/`NonDesktop` if the enclosure read succeeded, and the five laptop-gated entries skip rather than assert laptop behaviour. Servers are not a target class and are treated as `NonDesktop` at best.

### 2.7 Power source

| Aspect | Behaviour | Grounds |
|---|---|---|
| AC vs DC detection | `AC`/`Battery`/`Uncertain` from `BatteryStatus`; nothing inferred on desktops | `[CODE] NxHardware.ps1:154-159` |
| AC/DC separation of power values | Every per-plan capture journals the AC and DC index **separately**; changing one plane never alters the other | `[REG] NX09 categoryNote`, NX09-006 |
| Playbook delivery requirement | The generated playbook declares `PluggedIn` (with `Internet`) as a platform requirement | `playbook/playbook.conf:46-49` |
| Thermal comparison | NX10-007 reports that an AC-vs-DC comparison requires observing both; one snapshot cannot produce one | `[REG] NX10-007` |
| Modern Standby (S0ix) | Classic plan settings are partially ignored on S0ix systems — power entries carry the caveat `[RES] §2.7 (UltraOS)`; NX06-012 additionally skips when `powercfg /a` shows no S0 state `[REG] NX06-012` | Not validated |

### 2.8 Hybrid graphics

Covered in §2.3 (NX04-008). Summary: read-only adapter topology and routing report; it *feeds* NX04-002 (OS per-app GPU preference) and never writes vendor profile state. Routing preferences themselves are OS-level (`UserGpuPreferences`) and owned by NX04-002; vendor per-profile settings stay in vendor tooling.

---

## 3. Registry-declared hardware gates (complete list)

25 of 282 entries declare `requiredHardware`; 1 declares `excludedHardware`. Full list, generated from the registry:

| Entry | Name | Declared gate | Builds | Editions |
|---|---|---|---|---|
| NX04-009 | NVIDIA power management mode | `gpuVendor:[NVIDIA]` | 22631–26300 | all |
| NX04-010 | NVIDIA Low Latency Mode | `gpuVendor:[NVIDIA]` | 22631–26300 | all |
| NX04-011 | NVIDIA vertical sync mode | `gpuVendor:[NVIDIA]` | 22631–26300 | all |
| NX04-012 | NVIDIA Maximum Frame Rate | `gpuVendor:[NVIDIA]` | 22631–26300 | all |
| NX04-013 | NVIDIA Threaded Optimization | `gpuVendor:[NVIDIA]` | 22631–26300 | all |
| NX04-014 | NVIDIA texture filtering quality | `gpuVendor:[NVIDIA]` | 22631–26300 | all |
| NX04-015 | NVIDIA shader cache policy | `gpuVendor:[NVIDIA]` | 22631–26300 | all |
| NX04-016 | NVIDIA per-game profile framework | `gpuVendor:[NVIDIA]` | 22631–26300 | all |
| NX04-017 | AMD Radeon Anti-Lag | `gpuVendor:[AMD]` | 22631–26300 | all |
| NX04-018 | AMD Radeon Chill | `gpuVendor:[AMD]` | 22631–26300 | all |
| NX04-019 | AMD Enhanced Sync | `gpuVendor:[AMD]` | 22631–26300 | all |
| NX04-020 | AMD Wait for Vertical Refresh | `gpuVendor:[AMD]` | 22631–26300 | all |
| NX04-021 | AMD Surface Format Optimization | `gpuVendor:[AMD]` | 22631–26300 | all |
| NX04-022 | AMD per-game profile framework + shader cache | `gpuVendor:[AMD]` | 22631–26300 | all |
| NX04-023 | Intel graphics / Arc settings framework | `gpuVendor:[Intel]` | 22631–26300 | all |
| NX05-004 | Memory compression configuration | `minRamGB:16` + `excludedHardware.ramBelowGB:16` | 22631–26300 | all |
| NX06-002 | TRIM enable & verification | `requiresSsd:true` | 22631–26300 | all |
| NX09-010 | Lid close behavior | `chassis:"Laptop"` | 22631–26300 | all |
| NX09-011 | OEM battery conservation reporting | `chassis:"Laptop"` | 22631–26300 | all |
| NX09-015 | Battery report | `chassis:"Laptop"` | 22631–26300 | all |
| NX10-006 | OEM fan/cooling profile detection | `chassis:"Laptop"` | 22631–26300 | all |
| NX10-007 | AC/DC thermal behavior report | `chassis:"Laptop"` | 22631–26300 | all |
| NX20-003 | NVIDIA driver management | `gpuVendor:[NVIDIA]` | 22631–26300 | all |
| NX20-004 | AMD driver management | `gpuVendor:[AMD]` | 22631–26300 | all |
| NX20-005 | Intel driver management | `gpuVendor:[Intel]` | 22631–26300 | all |

Counts by predicate: `gpuVendor` 18 (NVIDIA 9, AMD 7, Intel 2) · `chassis` 5 · `minRamGB` 1 · `requiresSsd` 1 · `excludedGpuVendor` 0.

### 3.1 Gates that live in code, not in `requiredHardware`

| Entry(s) | Gate | Where enforced | Skip behaviour |
|---|---|---|---|
| NX03-011 | AMD platform with CPPC | `Get-NxAmdPreferredCoreReport` reads `Manufacturer` | `platformAvailable=false` + reason; report still returns |
| NX03-012 | Intel hybrid platform | `Get-NxIntelHybridPolicyReport` | `hybridTopology='Uncertain-HybridTopologyRequiresNX19Engine'` until NX19 runs |
| NX06-001 | Storage class known | `Get-NxStorageInventory` | `readSucceeded=false`; classification `unknown` |
| NX06-012 | Platform has an S0 standby state | `powercfg /a` text parse | Skips with the reason; writes no value |
| NX11-009 | ≥16 GB RAM; non-HDD boot volume | `Set-NxSysMainConfig` | `outcome='Skipped'` + gate text |
| NX11-010 | Xbox devices / Game Pass presence | `Set-NxXboxServicesConfig` evidence read | `Skipped` without acknowledgement |
| NX11-012 | Bluetooth-class device presence | `Set-NxBluetoothServiceConfig` (`Get-PnpDevice` + fallback) | `Skipped` without acknowledgement |
| NX17-007 | Topology loaded before any affinity choice | Read-only inventory; refuses to choose processors | Reports `topologyAvailable` state |
| NX19-001…011 | `GetLogicalProcessorInformationEx` succeeded; single group for affinity | NX19 engine | `topologyAvailable=false`; affinity refuses group-spanning masks |
| NX20-003/004/005 | Vendor present (double-gate) | `Get-NxNvidiaStatus`/`Get-NxAmdStatus`/`Get-NxIntelStatus` | `VendorHardwareAbsent` |
| NX04-009…023 | Vendor present (double-gate) | `Get-NxVendorGraphicsGuide` | `VendorHardwareAbsent` |

This split is intentional but it is a *split*: a machine can pass the resolver and still be refused inside the function. The owner sees both, because the function's outcome record carries the reason (`Skipped`, `Refused`, `platformAvailable=false`, `VendorHardwareAbsent`), while the resolver's own reason appears in the apply summary's step-1 detail `[CODE] NxApply.ps1:48-52`.

---

## 4. Per-category hardware dependency summary

| Category | Declared gates | Code-level hardware dependence | Notes |
|---|---|---|---|
| NX01 Windows Foundation | 0 | None (per-user/machine policy keys) | 10 registry actions declare `capabilityPath` |
| NX02 Gaming & Esports | 0 | NX02-005 build ≥ 26100; NX02-009 is a composition shell over NX04 vendor guides (Defined; writes nothing today) | No GPU gate declared; per-game driver settings are guided |
| NX03 CPU & Processor | 0 | CPU vendor (NX03-011/012), topology (NX03-013 inventory) | No RAM gate |
| NX04 GPU & Graphics | **15** | HAGS driver-side capability marked uncertain (NX04-001); hybrid routing report (NX04-008); MPO symptom-gated and vendor-conditional (NX04-006) | Vendor guides write nothing |
| NX05 Memory Management | 1 | Function-level 16 GB floor (NX05-004) | `excludedHardware` not read by resolver (§5.5) |
| NX06 Storage & Filesystem | 1 | Media class (NX06-001), S0ix presence (NX06-012), per-device write cache (NX06-011) | TRIM refuses non-SSD |
| NX07 Network Optimization | 0 | Per-adapter keyword presence; virtual-adapter exclusion | Only-if-present writes `[RES] §5` |
| NX08 Input & Peripherals | 0 | Class-driver `Parameters` keys must already exist (NX08-008) | Never creates driver keys |
| NX09 Power Management | **3** | AC/DC planes; Modern Standby caveat; powercfg parse locale-dependent | `PluggedIn` playbook requirement |
| NX10 Thermal Management | **2** | OEM namespaces (NX10-006); battery presence for DC plane (NX10-007) | No firmware writes |
| NX11 Background & Services | 0 | 16 GB / HDD gates (NX11-009); device presence (NX11-010/012) | Never touches never-touch services `[DOC] SECURITY_POLICY.md §1` |
| NX12 Debloating | 0 | None; package presence only | Missing package = skip |
| NX13 Privacy & Telemetry | 0 | None; edition floor is edition logic | 20 registry actions with `capabilityPath` |
| NX14 Security Configuration | 0 | Firmware virtualization + SLAT for Sandbox (NX14-013); feature presence reports (NX14-014) | Refuses Enable on unsupported editions |
| NX15 Visual & Interface | 0 | None; UCPD fallback is build logic | 10 registry actions with `capabilityPath` |
| NX16 Maintenance & Recovery | 0 | Restore-point availability, DISM/VSS availability | Read-only health paths by default |
| NX17 Advanced Configuration | 0 | Topology-fed read-only inventory (NX17-007); per-device MSI | No hardcoded processor indexes |
| NX18 Game Session Manager | 0 | Protected process classes (anti-cheat, capture, audio, peripherals) | Session-scoped |
| NX19 CPU Topology & Scheduling | 0 | Whole category depends on the topology API; >64 LP single-group affinity rule | No name lists, no hardcoded indexes |
| NX20 Hardware & Driver Mgmt | **3** | Vendor presence double-gate; read-only inventory | No install/remove/flash, ever |

---

## 5. Unavailable and uncertain data policy

### 5.1 Uncertainty marks you will actually see

| Field | Non-final values | Meaning |
|---|---|---|
| `cpu.vendor` | `Uncertain` | `Manufacturer` unmapped; no vendor claim follows |
| `cpu.smt` | `Uncertain` | Core counts unavailable |
| `cpu.hybrid` | `Uncertain-TopologyEnginePending` | NX19 has not run; never guessed from the marketing name `[CODE] NxHardware.ps1:28` |
| `gpu.gpus[].vendor` | `Uncertain` / `None` | Unmapped PCI VID / Microsoft basic display |
| `gpu.gpus[].vramSource` | `registry qwMemorySize` / `WMI AdapterRAM (uint32, wraps >4GB - treat as minimum)` / `unavailable` | Provenance is always stated |
| `storage.disks[].mediaType` | `Uncertain` | MediaType not SSD/HDD |
| `chassis.chassisClass` | `Uncertain` | Neither battery nor enclosure readable |
| `chassis.onAcPower` | `Uncertain` | Battery status not 1 or 2 |
| NX19 detection | `BestEffort` / `NoAsymmetryDetected` / `NotDeterminable` | X3D/large-L3 confidence |
| NX19 topology | `topologyAvailable=false` + reason | API or interop failure |
| NX04-001 HAGS | `Uncertain-DriverSide` | Driver-side support is not machine-readable through the routes NxCore uses; the Settings toggle is the authoritative signal `[REG] NX04-001` |
| NX03-012 hybrid | `Uncertain-HybridTopologyRequiresNX19Engine` | Deliberate dependency, not a failure |
| NX10-006 cooling | `profileState='Unknown'`, `switchingSupport='None-NotImplemented'` | No vendor-readable cooling contract implemented |
| NX10-007 SYSCOOLPOL | `NotExposedOnActivePlan` | Known absence, distinct from uncertainty |
| NX20 reports | `uncertainty[]` array; `profileInspection='NotAvailable'`; `currency='ManualComparisonRequired'` | Never fabricates absent vendor data |

Three rules govern all of the above `[CODE] NxHardware.ps1 header` `[DOC] KNOWN_ISSUES.md R4`:

1. **Never fabricate.** A failed read yields a sentinel and a reason, never a plausible default.
2. **Missing is not "off".** An absent value means "system default / not configured", not zero and not disabled (SynToolkit honesty model, `[RES] §2`).
3. **Wrong type is not overwritten.** `Test-NxRegistryCapability` refuses an existing value whose kind differs from the declared kind `[CODE] NxBuild.ps1:73-76`.

### 5.2 How uncertainty changes eligibility

| Situation | Effect |
|---|---|
| RAM total unknown | **Warning**; `minRamGB` check skipped; the function's own floor still applies |
| Storage unreadable or no SSD | **Skip** for `requiresSsd` entries, with the unreadable qualifier in the reason |
| GPU vendor `Uncertain` | `gpuVendor` entries **skip** (an unmapped vendor is not the required vendor) |
| Chassis `Uncertain` | Laptop-gated entries **skip** |
| Build report read failed | **Every** entry skips: `build report unavailable (read failed)` `[CODE] NxCompat.ps1:23-25` |
| Topology unavailable | NX19 scheduling entries cannot derive pools; NX17-007 refuses to choose processors |

### 5.3 How the owner sees it

- **Pre-flight backup set.** `%ProgramData%\NEXTRIX\Journal\…\hardware.json` and `build.json` are written before any mutation `[CODE] NX16.ps1 Invoke-NxPreFlight steps 3-4`, `playbook/Configuration/Tasks/nxcore.yml`.
- **Per-entry reports.** Every report-returning entry carries an `uncertainty` array in its result object (NX19, NX20, NX06-001, NX10-007, NX03-011/012).
- **Eligibility reasons.** In `-Plan` mode and in the apply summary, step 1 lists the resolver's reasons and the warnings separately (`eligibility` vs `eligibility-warning`) `[CODE] NxApply.ps1:48-52`.
- **Function outcomes.** `Skipped`, `Refused`, `Failed`, `NotDeterminable`, `VendorHardwareAbsent` appear verbatim in the function's returned object.

### 5.4 What is *not* collected (privacy boundary)

Serial numbers are withheld, MAC addresses are masked to the OUI, and serial-like USB instance suffixes are redacted in NX20 output `[REG] NX20 categoryNote`. The hardware report is stored locally in the journal's backup set and is not transmitted.

### 5.5 Known resolver gap

`excludedHardware` is **not read** by `Get-NxTweakEligibility` (`NxCompat.ps1` has no reference to the field). NX05-004's `excludedHardware.ramBelowGB:16` is therefore descriptive; the enforced gate is `requiredHardware.minRamGB` plus the function's own floor. The two agree today, so behaviour is correct, but the field is not a second line of defence. Flagged for the resolver owner (`W3` engine workstream) — this document does not change code.

---

## 6. Hardware-specific incident guardrails

Every row is a documented reference-ecosystem failure that shaped a NEXTRIX rule `[RES] §3`.

| Incident | Hardware class | NEXTRIX guardrail |
|---|---|---|
| AMD chipset installer fails at 64 % on modified systems (Atlas #1618) | AMD platforms | No chipset/driver writes; NX20-004 is inventory + guidance only |
| `disabledynamictick` broke ROG Ally sleep (Revi #167) | Handheld/laptop | NX17-002 is ADVANCED, consent + restart, never preset `[RES] §7` |
| VBS disable silently no-ops on Secured-core (Revi #222) | UEFI-locked platforms | NX14 reports state; no VBS-disable entry ships |
| Killer/Realtek NICs misbehave when forced keywords they lack | NIC vendors | Only-if-present keyword writes with driver-range clamping `[RES] §5` |
| MPO global disable → composition errors + crashes (FSOS-X R8/R10) | GPU/driver | NX04-006 TROUBLESHOOTING, symptom-gated, never preset |
| GPU priority on integrated graphics broke in-game mouse (FSOS-X R11) | iGPU/hybrid | NX04-002 is OS routing only; hybrid routing is reported, not forced |
| Touchpad disable ineffective despite writes (Sapphire #8) | Laptop input | No NEXTRIX entry disables the touchpad device; NX08 is inspection plus journaled configuration only `[REG] NX08-001…008` |
| Xbox controller + BT touchpads need re-enable paths | Peripherals | NX11-010/012 require acknowledgement when devices are present |
| WMI `AdapterRAM` wraps >4 GB (SynToolkit) | GPU reporting | 64-bit `qwMemorySize` first, WMI only as a labelled minimum |
| Restore-point 24 h throttle (SynToolkit/UltraOS) | All | Keep-existing-point behaviour; `Unverified` ≠ `Failed` |

---

## 7. Owner hardware test matrix (planned, not yet executed)

**Current evidence status:** zero entries hold `OwnerHardwareTested`, `OwnerFunctionallyValidated` or any E2+ evidence. All hardware rows below are **not yet validated**. Promotion requires the owner's physical run per `TWEAK_CLASSIFICATION.md §3` and the method in `TWEAK_RESEARCH.md §15`.

| # | Rig class | Why this rig is needed | Entries it unblocks (primary) | Status |
|---|---|---|---|---|
| H1 | Desktop, Intel hybrid (P/E), NVIDIA dGPU, ≥32 GB, NVMe | Combines P/E tier derivation and NVIDIA gating on one machine | NX19-001/002/003, NX03-012, NX04-001/008/009-016, NX20-003, NX04-002 | **Not yet validated** |
| H2 | Desktop, AMD dual-CCD X3D + AMD GPU | Positive case for >2× per-die L3 asymmetry and AMD gating | NX19-011, NX19-002/006, NX03-011, NX04-017-022, NX20-004 | **Not yet validated** |
| H3 | Desktop, AMD single-CCD (non-X3D) + AMD GPU | Negative case: `NoAsymmetryDetected`, no placement offered | NX19-011, NX19-002, NX03-011 | **Not yet validated** |
| H4 | Intel GPU machine (Arc dGPU or Intel iGPU-only laptop) | Intel vendor gate + Intel guide | NX04-023, NX20-005, NX04-008 | **Not yet validated** |
| H5 | Laptop, hybrid graphics, battery healthy, both AC and DC observed | Chassis gate, AC/DC plane separation, S0ix behaviour, battery reports | NX09-010/011/015, NX10-006/007, NX06-012, NX04-008, NX09 Modern-Standby entries | **Not yet validated** |
| H6 | >64 logical processors, multiple processor groups | Multi-group CPU Set mapping; single-group affinity refusal | NX19-001/002/003/004, NX17-007, NX03-013 | **Not yet validated** |
| H7 | SSD-only NVMe rig **and** a mixed SSD+HDD rig | TRIM/optimize distinctions, HDD gate, per-device write cache | NX06-002/003/011/012, NX11-009 (HDD gate), NX05-001/002 | **Not yet validated** |
| H8 (recommended) | 8–16 GB machine | Negative tests for the two RAM gates | NX05-004 (must refuse), NX11-009 (must refuse `Disabled`) | **Not yet validated** |

Rigs H1–H7 are the minimum honest matrix for the 25 declared gates plus the code-level gates in §3.1. A rig may cover more than one row (an H5 laptop with an Intel iGPU also exercises part of H4), but a row is only "validated" when the named entries have been run on hardware matching that row.

**What each run must record:** build + UBR (`NX16-012`), the pre-flight `hardware.json`, the per-entry outcome, and the journal before/after — the same evidence the apply pipeline already produces.

---

## 8. Out of scope and explicitly unsupported

| Target | Position | Grounds |
|---|---|---|
| Windows 10 hardware | Out of scope | `[ADR] ADR-003` |
| ARM64 devices (including 26H1 28000 devices) | Out of scope until separately validated | `[ADR] ADR-003`, `[RES] §1` |
| Virtual machines | Not a target class; will classify `NonDesktop`, no battery, often no SSD media → laptop- and SSD-gated entries skip | `[CODE] NxHardware.ps1` |
| Servers / multi-socket beyond 64 LP | Engine handles groups defensively, but no server validation exists | §2.2, §7 (H6) |
| Vendor-driver installation, removal, firmware flash | Never automated, on any hardware | `[REG] NX20 categoryNote` |
| External GPU hot-plug, docking-station topology changes | Reported as seen; no behaviour guarantees | No research basis |
| Overclocking, undervolting, fan curves, BIOS writes | Not implemented anywhere | `[REG] NX10-006` |

---

## 9. Freshness and change control

| Item | Rule |
|---|---|
| Re-verify when | A new category ships hardware gates; `NxHardware`/`NxCompat` change; a new build enters scope; any reference incident in §6 recurs |
| Source of truth | `registry/NX*.json` + `src/nxcore/*.ps1`; this document never overrides them |
| Inconsistency handling | Recorded in §5.5 and in the W5-C handover, not silently reconciled |
| Owner | Technical writer (`technical-writer`) with the engine workstream for code-level gates |
| Review date | Next phase gate (Wave 6) or on first owner hardware result, whichever is earlier |

### Reproducing the registry facts in this document (read-only)

```powershell
# Declared hardware gates across all categories
Get-ChildItem registry\NX*.json | ForEach-Object {
  $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
  foreach ($t in $j.tweaks) {
    if (@($t.requiredHardware.PSObject.Properties).Count -gt 0 -or
        @($t.excludedHardware.PSObject.Properties).Count -gt 0) {
      "$($t.id)  RH=$($t.requiredHardware | ConvertTo-Json -Compress)  EH=$($t.excludedHardware | ConvertTo-Json -Compress)"
    }
  }
}

# Build/edition deviations from the default
Get-ChildItem registry\NX*.json | ForEach-Object {
  $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
  foreach ($t in $j.tweaks) {
    if ($t.builds.min -ne 22631 -or $t.builds.max -ne 26300 -or @($t.builds.excluded).Count -gt 0) {
      "$($t.id) builds=$($t.builds | ConvertTo-Json -Compress)"
    }
  }
}
```
