# NEXTRIX — Rollback Design

**Status:** v1.0 — the 10-step protocol and registry-scope rollback are IMPLEMENTED (`src/nxcore/NxApply.ps1`, `NxRollback.ps1`); other target types arrive with their categories in Phase 4, using the same journal and the same rules.

## 1. The 10-step apply protocol (directive Section 8 — no exceptions)

```
1  identify target          eligibility resolver (Get-NxTweakEligibility) - skip gracefully with reason
2  read current state       Capture-NxRegistryValue (read-only)
3  record exact value       original.value
4  record type             original.kind (ExpandString captured unexpanded)
5  record value existence  original.existed
6  record key existence    original.keyExisted
7  persist to journal      Add-NxJournalEntry (BEFORE any mutation - journal-first invariant)
8  apply                    Set-NxRegistryValue (never New-Item -Force an existing key)
9  verify                   Test-NxConfigurationState - configuration effect only, never performance claims
10 update journal          result + verification; failure => safe stop + immediate exact-original restore,
                           journaled as failed-restored-original
```

**Plan mode** (`-Plan`) performs the read-only evaluation and emits the full plan — never writes, never journals. **Approval gate:** real application requires `-Approved`; the approval model of the tweak is recorded in every journal entry.

## 2. Restoration rules (per modification family)

| Family | Preserved before change | Restored on rollback | Engine status |
|---|---|---|---|
| **Registry** (v0.1) | path, name, kind, value, value-existence, key-existence | exact original value/kind; created values deleted | **Implemented + self-tested** |
| Service | startup type, running state, dependencies | exact original startup/state after dependency re-check | design fixed, lands with NX11 |
| Scheduled task | path, state, exported XML | re-import or exact state restore | lands with NX11 |
| Power | active scheme GUID + values, **AC and DC separately** | both planes restored; generated plans deleted, stock plans never deleted | lands with NX09 |
| AppX | package identity, user scope, provisioned state, **honest reversibility label** (Store-reinstallable vs media-requiring) | labeled restore path; never claimed "fully reversible" when it is not | lands with NX12 |

## 3. Only-if-ours divergence handling

Rollback reads the live state first. If it no longer equals the recorded modified state, the target is **skipped and reported** (`Result: Diverged`, journaled) — the user's later change wins, and NEXTRIX never clobbers it. This is the semantics three independent references converged on (XOS 0.6.4, FSOS-X R10, WinUtil `KeepServiceStartup` — `RESEARCH_RECONCILIATION.md` adopt register).

## 4. Integrity gating

`Invoke-NxRollback` verifies the journal's full hash chain before touching anything; any integrity error → **refuse to roll back** (a partial restore from untrusted history is worse than no restore). Tampering is detectable by design (STATE_JOURNAL.md §3.3, proven by self-test).

## 5. Scope matrix (all four scopes `Implemented`, registry scope)

| Scope | Evidence command |
|---|---|
| Individual tweak | `Invoke-NxRollback -TweakId NXcc-nnn` (NX16-013) |
| Category | `Invoke-NxRollback -Category NXcc` (NX16-014) |
| Profile | `Invoke-NxRollback -Profile Pn` (NX16-015) — explicit resolution for targets shared across combined profiles |
| Full NEXTRIX | `Invoke-NxRollback -All` (NX16-016) — success stamps `restoredVerifiedUtc`, capture re-arms |

## 6. Pre-flight dependency (NX16-002/003/004/005/006)

Before the first mutation of a session: restore point → registry/service/task backups → journal armed. Destructive steps are gated on capture completeness (XOS event-channel gate pattern, r1). The pre-flight ritual's functions are `Defined` status — they ship with this category's remaining functions in the Phase 4 NX16 completion.

## 7. Failure modes and honest labels

- Verification failure after apply → immediate exact-original restore, journaled `failed-restored-original`, session stops (no silent continue).
- Irreversible-by-nature operations (driver-package deletion, AppX removal) are **labeled as such in the registry** (`reversible: false` + restoration method describing what IS preserved) — the directive forbids disguising irreversibility.
- The engine never "restores Windows defaults" — it restores *your* recorded state, the exact thing the reference ecosystem does not do (PROJECT_RESEARCH: no reference restores the user's actual prior configuration wholesale).
