# NEXTRIX — State Journal Design

**Status:** v1.0 — IMPLEMENTED (engine v0.1, registry-scope) and self-tested. Implementation: `src/nxcore/NxJournal.ps1`. Self-test: `tools/Test-NxJournal.ps1` — **11/11 PASS (2026-11-23)**.

The journal is NEXTRIX's **sole rollback authority** (ADR-006 — the playbook platform provides no uninstall; the wizard is apply-and-select only).

## 1. Storage

| Item | Location |
|---|---|
| Root (target machines) | `%ProgramData%\NEXTRIX\Journal\` |
| Entries | `journal.jsonl` — append-only, one JSON object per line |
| Manifest | `manifest.json` — schema/journal version, entry count, `lastHash`, `captureStatus`, `restoredVerifiedUtc` |
| Backups (defense-in-depth) | `%ProgramData%\NEXTRIX\Backups\<timestamp>\` (reg exports, service/task baselines — NX16-003/005/006) |

No secrets ever: the journal stores configuration states, tweak IDs, approvals and results only — never passwords, tokens, or unrelated user data (directive Section 8).

## 2. Entry schema (one per apply/rollback/verify/failed step)

`seq` · `utc` · `tweakId` · `tweakVersion` · `operation` (apply/rollback/skip/verify/failed) · `approval` · `profiles[]` · `original` · `modified` · `result` · `verification` · `errorInfo` · `hash`

Original-state descriptors (registry scope in engine v0.1; one descriptor type per modification family as categories land):

- **registry:** `path`, `name`, `keyExisted`, `existed`, `kind`, `value` (ExpandString captured **unexpanded**; Binary/MultiString as typed arrays)

## 3. Invariants (all machine-enforced, all covered by the self-test)

1. **Journal-first:** the original-state entry is written BEFORE any mutation (step 7 of the 10-step protocol before step 8). No journal record → no change, ever.
2. **Capture-refusal (stacking detection):** `Initialize-NxJournal` refuses to arm over an existing journal — an already-NEXTRIX-tweaked state is never treated as "original". A `restoredVerifiedUtc` marker (set by verified full rollback) re-arms capture.
3. **Integrity chain:** every entry carries `hash = SHA256(prevHash | seq | canonicalJSON)`. `Read-NxJournal` re-verifies the whole chain; rollback **refuses to run** on a tampered journal (test 6: falsified `seq` detected).
4. **Only-if-ours restore:** a target is restored only if its live state still equals the recorded modified state; divergence (user/other-tool change after apply) is reported, never clobbered (tests 7–9).
5. **Exact-original restoration:** values are rewritten with their original kind; values that never existed are deleted; the original **existence** and **key existence** are part of the record — never guessed Windows defaults.
6. **Concurrency:** appends hold a named mutex (`Local\NEXTRIX_Journal_v1`); the manifest is rewritten via temp-file + atomic move.
7. **Protection:** append-only entries + hash chain make silent modification detectable. On target machines the apply session is elevated; ACL tightening of the journal root is applied by the pre-flight (NX16-004) when it lands.

## 4. Scopes (NX16-013…016, all `Implemented`)

| Scope | Invocation | Semantics |
|---|---|---|
| Tweak | `Invoke-NxRollback -TweakId NXcc-nnn` | Reverse-order restore of that tweak's apply entries |
| Category | `Invoke-NxRollback -Category NXcc` | Same, filtered by id prefix |
| Profile | `Invoke-NxRollback -Profile Pn` | Journal `profiles[]` tags; shared targets are resolved explicitly, never silently |
| Full | `Invoke-NxRollback -All` | Whole-journal reverse replay; success stamps `restoredVerifiedUtc` and re-arms capture |

Every rollback step is itself journaled and verified; integrity errors abort the run before any restoration.

## 5. Retention and extension

- Entries are never edited or deleted — rollback appends `rollback`/`failed` records; history stays auditable.
- Per-type descriptors (service startup+state+dependencies, task XML+state, power AC/DC values, AppX identity+scope+reversibility label) are added with their categories in Phase 4, extending the same schema — engine v0.1 reports unimplemented target types explicitly (`failed` with reason) rather than pretending.
