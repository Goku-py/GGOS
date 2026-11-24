# NEXTRIX - Release Packaging

**Status:** v0.1 (Phase 6 / Wave 5) - tooling implemented and validated; owner-side `.apbx` creation remains a documented manual step.
**Owners:** `tools/New-NxPackage.ps1` and this document (W5-B). The playbook generator (`tools/Invoke-NxBuild.ps1`) and the generated `playbook/` tree are owned by W1-B; the registry is authored by the category workstreams.
**Scope:** how to turn the registry into a verified AME Wizard release package, and what that package does and does not claim.

---

## 1. Pipeline at a glance

```text
registry/NX*.json
      |
      |  tools/Test-NxRegistry.ps1        (gate: 0 errors before release)
      |  tools/Export-NxMatrices.ps1      (review: dependency/conflict matrices)
      v
tools/Invoke-NxBuild.ps1 -Version X.Y.Z
      |
      |  playbook.conf, Configuration/**, Executables/nxcore-manifest.json
      v
tools/New-NxPackage.ps1 -Version X.Y.Z
      |
      |  build/package/NEXTRIX-vX.Y.Z/   (staging tree + SHA256SUMS.txt)
      v
OWNER: 7z a -tzip NEXTRIX-vX.Y.Z.apbx * -p"malte"   (inside the staging dir)
      |
      v
verify SHA256SUMS  ->  install through AME Wizard  ->  NxJournal/NxRollback
```

Nothing in this pipeline executes the playbook, downloads files at build time, or bundles a third-party binary. The only network requirement is the playbook's own `Internet` requirement at install time (AME Wizard requirements are `Internet` and `PluggedIn` only).

Prerequisites:

- Windows PowerShell 5.1 (`powershell.exe`) or PowerShell 7 (`pwsh.exe`); both are parser-checked for the tooling.
- 7-Zip installed **by the owner**, only for the `.apbx` step. NEXTRIX does not bundle or download 7-Zip.
- A clean worktree is recommended before a release build (`git status`). Concurrent workstream edits can invalidate a generation/copy pair - the packager fails loudly when source hashes move mid-run.

---

## 2. Step 1 - validate the registry

```powershell
powershell.exe -NoProfile -File tools\Test-NxRegistry.ps1
```

Required result: `RESULT: PASSED - 0 errors`. Warnings are permitted but must be understood before release.

Then regenerate the review artifacts:

```powershell
powershell.exe -NoProfile -File tools\Export-NxMatrices.ps1
```

This writes `DEPENDENCY_MATRIX.md` and `CONFLICT_MATRIX.md` at the repository root. Both are generated, deterministic, and committed. They are review aids, not enforcement: the validator and the generator are the hard gates. The matrices fail loudly on missing/cyclic dependencies and verify declared conflict symmetry.

---

## 3. Step 2 and 3 - generate and stage the package

```powershell
powershell.exe -NoProfile -File tools\New-NxPackage.ps1 -Version 0.7.0
```

Parameters:

| Parameter | Meaning |
|---|---|
| `-Version` | Required. Plain version (`1`, `0.1`, `0.0.1`); must match the generated manifest's `nextrixVersion`. |
| `-OutDir` | Optional. Default `.\build\package` (resolved against the repository root). `build/` is gitignored. |
| `-SkipPlaybookGenerate` | Optional. Use the existing `playbook/` tree instead of regenerating it. The version gate still applies. |

What the tool does:

1. Runs `tools/Invoke-NxBuild.ps1 -Version <v>` unless skipped. The generator writes the canonical `playbook/` tree. Regeneration is semantically deterministic; if the tracked manifest was produced by a different PowerShell edition, the pretty-print/line endings can differ while the JSON content is identical - use `-SkipPlaybookGenerate` when the committed tree is the release source.
2. Creates `<OutDir>\NEXTRIX-v<v>` from scratch (an existing staging tree for the same version is removed; the tool refuses a staging path outside `-OutDir` and refuses `-OutDir` at/above the repository root).
3. Copies `playbook.conf`, `Configuration/**`, and `Executables/nxcore-manifest.json`.
4. Flattens the runtime engine into `Executables\NxCore\`:
   - `src/nxcore/Nx*.ps1` (core modules)
   - `src/nxcore/functions/*.ps1` (category engines NX01-NX20 except NX18)
   - `src/nxsession/NX18.ps1` (session subsystem)
   - `src/nxcore/Import-NxCore.ps1`
5. Writes `Executables\NxCoreBootstrap.ps1` (see section 8).
6. Compares every copied `src/nxcore` module hash to `nxcore-manifest.json`; a mismatch aborts the package before any notes/sums are written.
7. Writes `PACKAGING-NOTES.txt`, then `SHA256SUMS.txt` over every staged file except itself.
8. Writes `<OutDir>\NEXTRIX-v<v>-inspect.zip` with `Compress-Archive` for content review. **This zip is not the playbook container.**

### Staging layout (v0.6.0 measured 2026-11-23)

```text
build/package/NEXTRIX-v0.6.0/
  playbook.conf
  Configuration/
    main.yml
    Tasks/  nx01.yml .. nx20.yml, nxcore.yml      (21 task files)
  Executables/
    nxcore-manifest.json
    NxCoreBootstrap.ps1
    NxCore/  Import-NxCore.ps1, NX01.ps1 .. NX20.ps1 (incl. NX18), NxApply.ps1, NxBuild.ps1,
             NxCompat.ps1, NxHardware.ps1, NxJournal.ps1, NxRollback.ps1, NxVerify.ps1   (28 files)
  PACKAGING-NOTES.txt
  SHA256SUMS.txt
```

Measured counts for v0.6.0: 56 files staged, 55 SHA256SUMS entries, 28 engine modules, 27 engine hashes matched the manifest, 0 mismatches, 1 unpinned file (`src/nxsession/NX18.ps1`).

---

## 4. Step 4 (owner) - build the `.apbx`

The AME `.apbx` container is a 7-Zip archive whose fixed password is the platform convention `malte`. Run this **inside the staging directory**:

```powershell
cd build\package\NEXTRIX-v0.6.0
7z a -tzip NEXTRIX-v0.6.0.apbx * -p"malte"
```

Notes:

- Run it once. If you re-run it, delete the existing `.apbx` first; otherwise the archive command can include the previous archive.
- 7-Zip is not bundled by NEXTRIX and is not downloaded by any NEXTRIX tool.
- The resulting archive is `build/package/NEXTRIX-v0.6.0/NEXTRIX-v0.6.0.apbx`. `.apbx` and `*.zip` are gitignored: release artifacts belong in GitHub Releases, not in git.
- The fixed password is a **platform convention**, not a NEXTRIX security control. Its upstream documented purpose is to defeat AV scanning. NEXTRIX compensates by publishing the complete, hash-pinned contents and by never obfuscating its own code (section 7).

Optional content check before publishing:

```powershell
7z l NEXTRIX-v0.6.0.apbx
```

---

## 5. Step 5 - verify SHA256SUMS

From inside the staging directory, before archiving (or against an extracted copy):

```powershell
$bad = 0
Get-Content .\SHA256SUMS.txt | ForEach-Object {
    $hash, $rel = $_ -split '  ', 2
    $actual = (Get-FileHash -LiteralPath ($rel -replace '/', '\') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $hash) { $bad++; Write-Output "MISMATCH $rel" }
}
if ($bad -eq 0) { "SHA256SUMS OK" } else { exit 1 }
```

Rules:

- Hashes are lowercase SHA-256; paths are relative and use forward slashes.
- `SHA256SUMS.txt` excludes itself (it cannot contain its own hash).
- If the tree is modified after hashing, verification fails by design. Re-run `New-NxPackage.ps1` to produce a new tree and sums.
- Publish the archive's own SHA-256 alongside the release, e.g. `(Get-FileHash .\NEXTRIX-v0.6.0.apbx -Algorithm SHA256).Hash`.

---

## 6. Step 6 - install through AME Wizard

1. Obtain AME Wizard from its official source. The build NEXTRIX is tested against is **AME Beta v0.8.4** (pinned in testing records, ADR-006); schema drift is tracked against the official changelog.
2. Load `NEXTRIX-v<v>.apbx` in the wizard. Confirm the playbook title/version shown by the wizard matches the release.
3. Satisfy the declared requirements: `Internet` and `PluggedIn`. The playbook deliberately declares no `DefenderToggled`, `NoAntivirus` or `UCPDDisabled` requirement, and `UseKernelDriver` is `false`.
4. The wizard runs the mandatory pre-flight first: journal initialization, hardware/build reports, a System Restore point and targeted backups. A pre-flight failure halts the playbook (capture-completeness gate).
5. Only selected options run. `presetExcluded` entries are default-unchecked. Registry writes go through the journaled `Invoke-NxRegistryTweak` pipeline; function actions run the bundled NxCore engine.
6. Rollback is NEXTRIX-owned and CLI-only: the installer has no undo page. After install, run `Invoke-NxRollback` from the bundled NxCore (`Executables/NxCore/`) with `-TweakId`, `-Category`, `-Profile` or `-All`. **The wizard has no uninstall**; the journal at `%ProgramData%\NEXTRIX\Journal` is the rollback authority.

Owner-facing limitations to state honestly:

- The installer does not expose rollback (deliberately: undo is a post-install CLI action, not an install-time checkbox). Pass the target on the command line; the bundled engine reads the journal at `%ProgramData%\NEXTRIX\Journal`.
- Playbook verification is discretionary and is lost on any modification. NEXTRIX does not claim verified status.

---

## 7. Trust posture (ADR-006 / SECURITY_POLICY, disclosed)

| Platform fact | Consequence | NEXTRIX compensation |
|---|---|---|
| AME Wizard is an unsigned beta (v0.8.4 at decision time) | Windows and users cannot authenticate the wizard binary by publisher | Pin the tested wizard build in testing records; publish this disclosure; keep NEXTRIX artifacts hash-pinned and inspectable |
| The wizard's official instructions require Defender exclusions and it may be flagged as a "Trojan Script" | Following them weakens endpoint protection during install | NEXTRIX never adds exclusions or asks the user to disable security features; requirements stay `Internet` + `PluggedIn` |
| `.apbx` fixed-password encryption has AV-scan evasion as its documented upstream purpose | Content is opaque to scanners | Publish the full playbook/NxCore contents, hash-pin every file, and use the container only for platform compatibility - no NEXTRIX code obfuscation or evasion |
| Playbook "verified" status is discretionary (Discord/Telegram) and lost on modification | Users cannot rely on a platform trust badge | Claim no verified status; point users at `SHA256SUMS.txt` and the public repository instead |
| The wizard has no standardized uninstall | A playbook cannot rely on the wizard to undo changes | Every mutation is journaled; `NxJournal`/`NxRollback` is the sole rollback authority (ADR-006) |
| Wizard runtime EULA text is not published online (PD-2 residual) | The runtime agreement is unknown | Documented as unknown; never asserted |

NEXTRIX does not attempt AV evasion beyond the platform's container convention. It bundles zero third-party binaries; if that ever changes, license review, hash pinning and `THIRD-PARTY-NOTICES.md` are mandatory (`LICENSING_REVIEW.md`).

---

## 8. Runtime engine layout and the bootstrap (integration note)

The generated playbook runs each `!powerShell` action with `exeDir: true` and starts with:

```powershell
foreach ($m in (Get-ChildItem -LiteralPath . -Filter 'Nx*.ps1' -File | Sort-Object -Property Name)) { . $m.FullName }
```

That loader reads **only immediate children of `Executables/`**, and only names matching `Nx*.ps1`. Consequences:

- Engine modules cannot live only in `Executables\NxCore\`; the loader would never see them.
- `Import-NxCore.ps1` is not matched by `Nx*.ps1`, and the flat bundle has no `functions/` subdirectory, so the loader file cannot be used as-is.
- Loading `NX18.ps1` before the core modules would throw, because NX18 dot-sources `..\nxcore\Import-NxCore.ps1` when `Add-NxJournalEntry` is not yet defined.

`New-NxPackage.ps1` therefore writes exactly one `Nx*.ps1` at the `Executables/` root, `NxCoreBootstrap.ps1`, which:

1. loads the core modules in the same order as `Import-NxCore.ps1`;
2. loads `NX01.ps1` .. `NX20.ps1` (including the bundled `NX18.ps1`) by name order;
3. throws before any mutation unless `Invoke-NxPreFlight`, `Invoke-NxRegistryTweak` and `Invoke-NxRollback` are in scope.

This is a packaging workaround, not a generator change. If W1-B later makes the generator load `Executables/` recursively (or adds an explicit loader path), the bootstrap can be dropped and `PACKAGING.md` updated - until then, removing it produces a package that fails at the first `!powerShell` action.

### NX18 packaging note

`NX18` (Game Session Manager) lives in `src/nxsession/NX18.ps1`, outside the generator's `src/nxcore` inventory (KNOWN_ISSUES 16). Consequences:

- `tools/Invoke-NxBuild.ps1` reports its `Get-Nx18Capability` actions as "not found in src/nxcore at generate time" and marks them `absent` in `nxcore-manifest.json`; this is expected, not a build failure.
- `New-NxPackage.ps1` bundles `NX18.ps1` and the bootstrap loads it. The playbook's NX18 options are informational probes only until a package built by this tool is used; a bare `playbook/` copy is not a runnable NX18 package.
- NX18's session changes are temporary and journaled (process CPU sets/priority, session power plan, temporary registry overlay). Its session record store lives under `%ProgramData%\NEXTRIX\Sessions` and is an index, not a second rollback authority.
- Because the generator does not inventory NX18, its file is not hash-pinned by `nxcore-manifest.json`; it is covered by the package-level `SHA256SUMS.txt` instead.

---

## 9. Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| `manifest says 'X', requested 'Y'` | Stale `playbook/` used with `-SkipPlaybookGenerate` | Rerun without `-SkipPlaybookGenerate`, or regenerate for the requested version |
| `manifest hash mismatch for src/nxcore/...` | Engine file changed between generation and copy (concurrent edit), or a hand-edited manifest | Re-run the full packager on a stable tree; never edit the manifest |
| `manifest lists ... but the package did not copy it` | Engine file missing from `src` or renamed | Restore the file or regenerate; the package refuses an incomplete engine |
| `NxCore loaded but 'Invoke-NxPreFlight' is missing` | Engine tree incomplete, or a custom package dropped the bootstrap load order | Rebuild with `New-NxPackage.ps1`; do not hand-assemble `Executables/` |
| `7z` not recognized | 7-Zip is not installed (by design, NEXTRIX bundles none) | Owner installs 7-Zip, then reruns the archive command |
| Archive unexpectedly large / contains an `.apbx` | The owner command was run twice without deleting the old archive | Delete the old `.apbx`, rebuild the archive once |
| Wizard flags the download or requires exclusions | Upstream AME beta behavior (ADR-006) | Read section 7; decide as the owner; NEXTRIX adds no exclusions |
| `SHA256SUMS` mismatch after extraction | Tree was modified, or files were extracted with text-mode conversion | Re-extract the archive; verify against the published archive hash |

---

## 10. Non-goals and boundaries

- This tooling does **not** execute the playbook, mutate the host, download anything, or select a paid/licensed component.
- It does not publish releases. GitHub Release upload, tagging and `ReleaseApproved` promotion remain owner/coordinator decisions (`TODO.md` release cadence).
- It does not reimplement the generator. `playbook/` content is W1-B's contract; packaging only copies, flattens and pins.
- It does not make performance or compatibility claims. Evidence levels stay E0/E1 until owner testing promotes them.

---

## 11. Change control

- Change `tools/New-NxPackage.ps1` or this document as one unit; packaging behavior and its disclosure must not drift.
- Changing the engine file list, the loader contract, or the `.apbx` convention requires a coordinator note and a regenerated package.
- Every release package must report: staging path, file count, engine count, manifest hash sync, SHA256SUMS count, and the exact owner archive command.
