# NEXTRIX — Profile Matrix

**Status:** v0.1 — composable user-profile system (directive Sections 5 and 14).
One central tweak registry; eligibility is computed dynamically from profiles. **No tweak is ever duplicated per profile.**

---

## 1. Profiles

| ID | Profile | Priorities |
|---|---|---|
| P1 | Competitive Esports | Frame-time consistency · stable FPS · input responsiveness · appropriate CPU/GPU config · low background interference |
| P2 | Balanced Gamer | Gaming performance · everyday functionality · stability · retained background functionality |
| P3 | Laptop Gamer | AC/DC separation · power management · thermal management · hybrid graphics · battery behavior |
| P4 | Streamer | Gaming performance · OBS compatibility · hardware encoding · audio · capture · background preservation |
| P5 | Content Creator | CPU/GPU workloads · memory · storage · rendering/editing · multitasking |
| P6 | Low-End System | Resource efficiency · startup management · background activity · memory pressure · storage maintenance |
| P7 | Developer | WSL · Hyper-V · virtualization · Docker · dev tools · background workloads |
| P8 | Privacy-Focused | Privacy permissions · telemetry config · app control · cross-device preferences |
| P9 | General User | Stability · usability · maintenance · basic configuration |

Profiles combine freely: P1+P3, P1+P7, P2+P4, P5+P7, etc. When combined, **more conservative (feature-preserving) rules win** — a conflict between a performance entry and a preservation requirement always resolves toward preservation unless the user explicitly overrides at tweak selection.

## 2. Category emphasis per profile

Emphasis: ● recommended attention · ○ conditional/offered · — not recommended.

| Category | P1 | P2 | P3 | P4 | P5 | P6 | P7 | P8 | P9 |
|---|---|---|---|---|---|---|---|---|---|
| NX01 Foundation | ● | ● | ○ | ○ | ○ | ● | ○ | ○ | ● |
| NX02 Gaming | ● | ● | ● | ● | ○ | ○ | — | — | ○ |
| NX03 CPU | ● | ○ | ○ (AC only) | ○ | ○ | ○ | ○ | — | ○ |
| NX04 GPU | ● | ● | ● (hybrid-aware) | ● | ● | ○ | ○ | — | ○ |
| NX05 Memory | ○ | ○ | ○ | ○ | ● | ● | ○ | — | ○ |
| NX06 Storage | ○ | ○ | ○ | ○ | ● | ● | ○ | — | ● |
| NX07 Network | ○ | ○ | ○ (Wi-Fi focus) | ○ | — | ○ | ○ | — | ○ |
| NX08 Input | ● | ○ | ○ | ○ | — | — | — | — | ○ |
| NX09 Power | ● | ● | ● (AC/DC split) | ● | ○ | ○ | ○ | — | ○ |
| NX10 Thermal | ○ | ○ | ● | ○ | ○ | — | — | — | ○ |
| NX11 Background | ● | ○ | ○ | ○ (capture preserved) | ○ | ● | ○ (dev workloads preserved) | ○ | ● |
| NX12 Debloat | ○ | ○ | ○ | ○ | ○ | ● | ○ | ○ | ○ |
| NX13 Privacy | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ● | ○ |
| NX14 Security | report | report | report | report | report | report | ○ (virtualization) | report | ● (health) |
| NX15 Visual | ○ | ○ | ○ (battery cost noted) | ○ | ○ | ○ | — | ○ | ● |
| NX16 Maintenance | ● | ● | ● | ● | ● | ● | ● | ● | ● |
| NX17 Advanced | — (opt-in only) | — | — | — | — | — | — | — | — |
| NX18 Session Mgr | ● | ○ | ○ | ● (capture-safe) | — | — | — | — | — |
| NX19 Scheduling | ● | ○ | ○ | ● | ○ | — | ○ | — | — |
| NX20 Hardware | ● | ● | ● | ● | ● | ● | ● | ○ | ● |

NX16 is always emphasized: maintenance/rollback foundations apply before anything else. NX17 is never profile-recommended — individually opt-in only.

## 3. Profile-specific standing rules

- **P1 Competitive Esports:** background-recording/capture entries default OFF (preserved only if user keeps them); input consistency entries offered; no EXPERIMENTAL entries auto-offered.
- **P3 Laptop Gamer:** every power/thermal entry evaluated per AC and DC separately; battery-impacting recommendations carry the trade-off text; hybrid-graphics routing (NX04-008) is emphasized.
- **P4 Streamer:** OBS/ShadowPlay/AMD-recording processes are protected everywhere (NX18-012 guard); Game DVR/capture entries default preserved; hardware-encoding capacity respected in scheduling profiles (NX19-008).
- **P6 Low-End System:** recommendations lean to startup management, background inventory, storage maintenance; no entries that increase resource pressure (e.g. heavier logging, aggressive cache growth).
- **P7 Developer:** Hyper-V/WSL/virtualization features are **preserved by default** — any tweak conflicting with them is excluded from recommendations, never silently applied (NX14-014 dependency warnings).
- **P8 Privacy-Focused:** NX13 set offered comprehensively; always labeled as privacy (never performance) changes; cross-device removal conflicts surfaced explicitly.
- **P9 General User:** defaults preserve Windows functionality; CORE usability entries only; security health reports emphasized.

## 4. Eligibility filter (recommendation engine order)

1. Hardware gate (NxHardware report: vendor/topology/class/AC-DC).
2. Build/capability gate (NxBuild: feature exists on this machine).
3. Profile & workload fit (this matrix).
4. Dependency satisfaction (registry-declared).
5. Conflict resolution (§5).
6. Risk filter: CORE offered for selection · CONDITIONAL offered with explanation · ADVANCED behind opt-in · EXPERIMENTAL behind opt-in + warning · TROUBLESHOOTING only against documented symptoms.
7. Evidence status shown with every recommendation (E0/E1 today; E2+ only after owner testing).
8. Preserved-functionality declarations (user-stated) are absolute vetoes.

**Never auto-applied:** no eligible set is applied without individual review, selection and consent.

## 5. Conflict resolution

1. Identify the conflict class: target overlap · semantic opposition · profile-policy violation · security policy (Section 15) · hardware mismatch.
2. Explain why it occurs (both entries cited).
3. Exclude the incompatible recommendation.
4. Ask for explicit resolution only when both options are legitimately selectable by the user.
5. Never silently override a user-selected requirement — including across combined profiles.

## 6. Recommendation output format (every entry, per directive)

```
Tweak: <display name> (<ID>)
Reason: <configuration purpose — no invented benefits>
Applicability: <hardware / workload / build conditions>
Trade-off: <what is given up>
Recommendation: <recommended | conditional-review | advanced-opt-in | troubleshooting-only>
Evidence: <E-level + source status>
Action: review and select
```

## 7. Configuration exchange

User selections export to a versioned JSON configuration (profile IDs + tweak IDs + per-tweak parameters + preserved-feature declarations), which can be imported and compared on another machine. Import re-runs the full eligibility pipeline on the target machine — an imported selection is never applied blindly where hardware/build gates fail; failures are reported with reasons.
