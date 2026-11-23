#Requires -Version 5.1
<#
    New-NxPackage.ps1 - build the NEXTRIX release package staging tree.

    Steps:
      1. Regenerate the playbook (tools/Invoke-NxBuild.ps1 -Version <v>) unless
         -SkipPlaybookGenerate is given.
      2. Create <OutDir>\NEXTRIX-v<v> (default OutDir: .\build\package).
      3. Copy the generated playbook source: playbook.conf, Configuration/**,
         Executables/nxcore-manifest.json.
      4. FLATTEN the runtime engine into Executables\NxCore\:
           src/nxcore/Nx*.ps1              (core modules)
           src/nxcore/functions/*.ps1      (category engine functions)
           src/nxsession/NX18.ps1          (session subsystem; outside src/nxcore)
           src/nxcore/Import-NxCore.ps1    (loader used by the bootstrap)
         The generated playbook dot-sources every Nx*.ps1 found in its working
         directory (Executables/, exeDir: true), not a subdirectory. The package
         therefore also writes ONE bootstrap, Executables\NxCoreBootstrap.ps1,
         which the generated loader picks up and which loads the NxCore tree in
         dependency order. This keeps the mandated Executables\NxCore\ layout
         functional without touching the generator (integration note in
         docs/PACKAGING.md).
      5. Write PACKAGING-NOTES.txt with the exact owner-side .apbx command.
      6. Write SHA256SUMS.txt (sha256, relative forward-slash paths, sorted).
      7. Optionally write <OutDir>\NEXTRIX-v<v>-inspect.zip for content review
         (Compress-Archive; NOT the playbook container).

    Safety: this tool never executes the playbook, downloads anything, or runs
    7-Zip. It writes only under -OutDir (build/ is gitignored) plus the normal
    playbook/ regeneration performed by Invoke-NxBuild.ps1. It refuses an OutDir
    that is the repository root or an ancestor of it.

    Exit codes: 0 = package staged; 1 = failure (no partial package is accepted).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$OutDir,
    [switch]$SkipPlaybookGenerate
)

$ErrorActionPreference = 'Stop'
$repoRoot   = Split-Path $PSScriptRoot -Parent
$playbookDir = Join-Path $repoRoot 'playbook'

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $repoRoot 'build\package'
} elseif (-not [System.IO.Path]::IsPathRooted($OutDir)) {
    $OutDir = Join-Path $repoRoot $OutDir
}
$OutDir = [System.IO.Path]::GetFullPath($OutDir)

if ($Version -notmatch '^\d+(\.\d+){0,2}$') {
    Write-Output "FATAL: -Version '$Version' is not a plain version number (AME accepts 1 / 0.1 / 0.0.1)."
    exit 1
}
if ($OutDir.TrimEnd('\') -match '^[A-Za-z]:$') {
    Write-Output "FATAL: -OutDir refuses a drive root ('$OutDir')."
    exit 1
}
$outNorm  = $OutDir.TrimEnd('\')
$repoNorm = $repoRoot.TrimEnd('\')
if ($outNorm -eq $repoNorm -or $repoNorm.StartsWith($outNorm + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Output "FATAL: -OutDir must not be the repository root or an ancestor of it ('$OutDir')."
    exit 1
}

$stage = Join-Path $OutDir "NEXTRIX-v$Version"
$stageNorm = [System.IO.Path]::GetFullPath($stage).TrimEnd('\')
if (-not $stageNorm.StartsWith($outNorm + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Output "FATAL: refusing to use a staging path outside -OutDir ('$stageNorm')."
    exit 1
}

$errors   = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-NxTextFile([string]$Path, [string]$Content) {
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $script:utf8NoBom)
}

function Get-NxRelPath([string]$Root, [string]$FullName) {
    $r = $Root.TrimEnd('\')
    if (-not $FullName.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "path '$FullName' is not under '$Root'"
    }
    return $FullName.Substring($r.Length + 1).Replace('\', '/')
}

# ----------------------------------------------------------------------------
# 1. Regenerate the playbook (canonical generated tree, owned by the generator)
# ----------------------------------------------------------------------------
if (-not $SkipPlaybookGenerate) {
    $buildScript = Join-Path $PSScriptRoot 'Invoke-NxBuild.ps1'
    if (-not (Test-Path -LiteralPath $buildScript)) { Write-Output "FATAL: generator not found: $buildScript"; exit 1 }
    Write-Output "==> generating playbook v$Version (tools/Invoke-NxBuild.ps1)"
    $global:LASTEXITCODE = 0
    & $buildScript -Version $Version
    if ($LASTEXITCODE -ne 0) { Write-Output "FATAL: playbook generation failed (exit $LASTEXITCODE)"; exit 1 }
    if (-not (Test-Path -LiteralPath (Join-Path $playbookDir 'playbook.conf'))) {
        Write-Output 'FATAL: playbook.conf was not generated'; exit 1
    }
} else {
    Write-Output '==> -SkipPlaybookGenerate: using the existing playbook/ tree'
}

# ----------------------------------------------------------------------------
# 2. Validate generated inputs (version gate first; a mismatched artifact is
#    never packaged)
# ----------------------------------------------------------------------------
$manifestPath = Join-Path $playbookDir 'Executables\nxcore-manifest.json'
foreach ($required in @((Join-Path $playbookDir 'playbook.conf'), (Join-Path $playbookDir 'Configuration\main.yml'), $manifestPath)) {
    if (-not (Test-Path -LiteralPath $required)) { Write-Output "FATAL: missing generated input: $required"; exit 1 }
}
try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Write-Output "FATAL: nxcore-manifest.json is not valid JSON: $($_.Exception.Message)"; exit 1 }
if ([string]$manifest.nextrixVersion -ne [string]$Version) {
    Write-Output "FATAL: version mismatch - manifest says '$($manifest.nextrixVersion)', requested '$Version'. Regenerate without -SkipPlaybookGenerate."
    exit 1
}

# ----------------------------------------------------------------------------
# 3. Fresh staging tree
# ----------------------------------------------------------------------------
if (Test-Path -LiteralPath $stage) {
    Write-Output "==> cleaning previous staging tree: $stage"
    Remove-Item -LiteralPath $stage -Recurse -Force
}
New-Item -ItemType Directory -Path $stage -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'Configuration') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'Executables') -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $playbookDir 'playbook.conf') -Destination (Join-Path $stage 'playbook.conf') -Force
# Copy the CONTENTS of Configuration (destination already exists, so copying the
# directory itself would nest it as Configuration\Configuration).
Copy-Item -Path (Join-Path $playbookDir 'Configuration\*') -Destination (Join-Path $stage 'Configuration') -Recurse -Force
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stage 'Executables\nxcore-manifest.json') -Force

$configFiles = @(Get-ChildItem -LiteralPath (Join-Path $stage 'Configuration') -Recurse -File | Sort-Object -Property FullName)
if ($configFiles.Count -eq 0) { Write-Output 'FATAL: Configuration/ is empty after the copy'; exit 1 }

# ----------------------------------------------------------------------------
# 4. Flatten the runtime engine into Executables\NxCore
# ----------------------------------------------------------------------------
$nxCoreDir = Join-Path $repoRoot 'src\nxcore'
$nxSessionDir = Join-Path $repoRoot 'src\nxsession'
$engineOut = Join-Path $stage 'Executables\NxCore'
New-Item -ItemType Directory -Path $engineOut -Force | Out-Null

$engineEntries = @()
foreach ($f in @(Get-ChildItem -LiteralPath $nxCoreDir -Filter 'Nx*.ps1' -File -ErrorAction SilentlyContinue)) {
    $engineEntries += [pscustomobject]@{ file = $f; rel = ('src/nxcore/' + $f.Name) }
}
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $nxCoreDir 'functions') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
    $engineEntries += [pscustomobject]@{ file = $f; rel = ('src/nxcore/functions/' + $f.Name) }
}
$nx18Path = Join-Path $nxSessionDir 'NX18.ps1'
if (Test-Path -LiteralPath $nx18Path) { $engineEntries += [pscustomobject]@{ file = (Get-Item -LiteralPath $nx18Path); rel = 'src/nxsession/NX18.ps1' } }
$importPath = Join-Path $nxCoreDir 'Import-NxCore.ps1'
if (Test-Path -LiteralPath $importPath) { $engineEntries += [pscustomobject]@{ file = (Get-Item -LiteralPath $importPath); rel = 'src/nxcore/Import-NxCore.ps1' } }
$engineEntries = @($engineEntries | Sort-Object -Property @{ Expression = { $_.file.Name } })

if ($engineEntries.Count -eq 0) { Write-Output 'FATAL: no engine modules found under src/nxcore'; exit 1 }
foreach ($e in $engineEntries) { if (-not (Test-Path -LiteralPath $e.file.FullName)) { $errors.Add("engine module missing: $($e.file.FullName)") } }

$engineNames = @{}
foreach ($e in $engineEntries) {
    if ($engineNames.ContainsKey($e.file.Name)) { $errors.Add("duplicate engine file name '$($e.file.Name)' - the flat layout cannot hold both") ; continue }
    $engineNames[$e.file.Name] = $true
}
if ($errors.Count -gt 0) {
    Write-Output 'ENGINE INVENTORY FAILED:'
    foreach ($e in $errors) { Write-Output "  ERROR: $e" }
    exit 1
}

foreach ($e in $engineEntries) {
    Copy-Item -LiteralPath $e.file.FullName -Destination (Join-Path $engineOut $e.file.Name) -Force
}

# Bootstrap: the ONE file matching the generated loader's Nx*.ps1 filter at the
# Executables/ root. It loads the engine tree in dependency order.
$bootstrapPath = Join-Path $stage 'Executables\NxCoreBootstrap.ps1'
$bootstrap = @'
# NEXTRIX NxCore runtime loader. GENERATED by tools/New-NxPackage.ps1 - do not edit.
#
# Why this file exists: the generated playbook executes each !powerShell action
# with exeDir: true and dot-sources every Nx*.ps1 in THAT directory (the
# playbook's Executables/ root). The engine bundle lives in Executables/NxCore/,
# so this bootstrap is the only Nx*.ps1 the loader sees; it loads the bundle in
# dependency order and fails before any mutation if the core entry points are
# missing.
$ErrorActionPreference = 'Stop'

$nxCoreRoot = Join-Path $PSScriptRoot 'NxCore'
if (-not (Test-Path -LiteralPath $nxCoreRoot)) {
    throw "NEXTRIX: NxCore bundle not found at '$nxCoreRoot'."
}

# The bundle is FLAT (no functions/ subdirectory), so Import-NxCore.ps1 (which
# dot-sources .\functions\*.ps1) cannot be used as-is. Load the same modules in
# the same documented order instead.
$coreOrder = @('NxJournal.ps1', 'NxBuild.ps1', 'NxHardware.ps1', 'NxCompat.ps1', 'NxVerify.ps1', 'NxRollback.ps1', 'NxApply.ps1')
foreach ($coreModule in $coreOrder) {
    $corePath = Join-Path $nxCoreRoot $coreModule
    if (-not (Test-Path -LiteralPath $corePath)) { throw "NEXTRIX: missing core module '$coreModule'." }
    . $corePath
}

# Category engine functions (NX01..NX20) and the NX18 session subsystem. NX18 is
# loaded here after the core, so its guard sees Add-NxJournalEntry and does not
# try to re-load the src tree.
$categoryModules = @(Get-ChildItem -LiteralPath $nxCoreRoot -File | Where-Object { $_.Name -match '^NX\d{2}\.ps1$' } | Sort-Object -Property Name)
if ($categoryModules.Count -eq 0) { throw 'NEXTRIX: no NXnn engine modules found in NxCore.' }
foreach ($module in $categoryModules) { . $module.FullName }

foreach ($requiredFunction in @('Invoke-NxPreFlight', 'Invoke-NxRegistryTweak', 'Invoke-NxRollback')) {
    if ($null -eq (Get-Command -Name $requiredFunction -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "NEXTRIX: NxCore loaded but '$requiredFunction' is missing - refusing to run the playbook."
    }
}
'@
Write-NxTextFile $bootstrapPath ($bootstrap.Replace("`r`n", "`n").Replace("`n", "`r`n"))

# ----------------------------------------------------------------------------
# 5. Verify copied engine hashes against nxcore-manifest.json (where applicable)
# ----------------------------------------------------------------------------
$manifestHashes = @{}
foreach ($mf in @($manifest.files)) {
    if ($null -ne $mf.PSObject.Properties['source']) { $manifestHashes[[string]$mf.source] = [string]$mf.sha256 }
}
$copiedEngine = @(Get-ChildItem -LiteralPath $engineOut -File | Sort-Object -Property Name)
$hashMatched = 0
$hashMismatched = 0
$hashUnpinned = @()
$copiedRelSet = @{}
foreach ($e in $engineEntries) {
    $rel = $e.rel
    $actualPath = Join-Path $engineOut $e.file.Name
    $actual = (Get-FileHash -LiteralPath $actualPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $copiedRelSet[$rel] = $true
    if ($manifestHashes.ContainsKey($rel)) {
        if ($manifestHashes[$rel] -eq $actual) { $hashMatched++ }
        else { $hashMismatched++; $errors.Add("manifest hash mismatch for $rel (manifest $($manifestHashes[$rel]), package $actual)") }
    } else {
        $hashUnpinned += $rel
    }
}
$manifestEngineSources = @($manifestHashes.Keys | Where-Object { $_ -like 'src/nxcore/*' })
foreach ($ms in @($manifestEngineSources | Sort-Object)) {
    if (-not $copiedRelSet.ContainsKey($ms)) { $errors.Add("manifest lists $ms but the package did not copy it") }
}
if ($errors.Count -gt 0) {
    Write-Output 'PACKAGE INTEGRITY FAILED:'
    foreach ($e in $errors) { Write-Output "  ERROR: $e" }
    exit 1
}

# ----------------------------------------------------------------------------
# 6. PACKAGING-NOTES.txt (written before SHA256SUMS so it is covered by it)
# ----------------------------------------------------------------------------
$configYmlCount = @($configFiles | Where-Object { $_.Name -like '*.yml' }).Count
$unpinnedLine = ''
if (@($hashUnpinned).Count -gt 0) {
    $unpinnedLine = '  Not in the manifest (bundled by this tool): ' + (@($hashUnpinned) -join ', ')
}
$notesTemplate = @'
NEXTRIX v{{VERSION}} - release package notes

GENERATED FILE - do not edit. Produced by tools/New-NxPackage.ps1.
No timestamp is recorded so the staging tree is reproducible from the registry.

WHAT IS INSIDE
  playbook.conf                          AME Wizard playbook metadata (v{{VERSION}})
  Configuration/main.yml                 entry point (pre-flight -> categories -> rollback)
  Configuration/**                       {{CONFIGCOUNT}} YAML files (main.yml + task files)
  Executables/nxcore-manifest.json       generator manifest with SHA256 pins
  Executables/NxCore/*.ps1               {{ENGINECOUNT}} runtime engine modules (flattened)
  Executables/NxCoreBootstrap.ps1        loader the generated playbook picks up (see below)
  SHA256SUMS.txt                         sha256 of every file in this tree (self-excluded)
  PACKAGING-NOTES.txt                    this file

RUNTIME ENGINE LAYOUT
  The generated playbook dot-sources every Nx*.ps1 in the Executables directory
  (exeDir: true). The engine therefore cannot sit only in a subdirectory:
  NxCoreBootstrap.ps1 is the single Nx*.ps1 at the Executables root. It loads
  the core modules in Import-NxCore order, then NX01..NX20 (which includes
  NX18.ps1, the session subsystem), and refuses to continue unless
  Invoke-NxPreFlight, Invoke-NxRegistryTweak and Invoke-NxRollback are in scope.
  Import-NxCore.ps1 is bundled for source parity, but the flat bundle has no
  functions/ subdirectory, so the bootstrap performs the same load order itself.
  NX18 is pinned by nxcore-manifest.json (the generator now inventories
  src/nxsession/NX18.ps1: 28 engine pins); the hash sync below covers it.

HASH SYNC
  Engine files compared to nxcore-manifest.json: {{MATCH}} match, {{MISMATCH}} mismatch.
{{UNPINNEDLINE}}

OWNER STEP - BUILD THE .apbx (NEXTRIX does not do this and bundles no 7-Zip)
  The AME .apbx container is a 7-Zip archive whose fixed password is the
  platform convention "malte". Run the following INSIDE this staging directory
  (the NEXTRIX-v{{VERSION}} folder), with 7-Zip installed by the owner:

      7z a -tzip NEXTRIX-v{{VERSION}}.apbx * -p"malte"

  Run it once. Delete a previously created .apbx before re-running, or the
  archive command will include the old archive in the new one.
  The command creates: {{STAGE}}\NEXTRIX-v{{VERSION}}.apbx

SHA256SUMS
  Verify with Windows PowerShell (hashes are lowercase; relative paths use /):
    $bad = 0
    Get-Content .\SHA256SUMS.txt | ForEach-Object {
      $hash, $rel = $_ -split '  ', 2
      $actual = (Get-FileHash -LiteralPath ($rel -replace '/', '\') -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actual -ne $hash) { $bad++; Write-Output "MISMATCH $rel" }
    }
    if ($bad -eq 0) { "SHA256SUMS OK" } else { exit 1 }

  The walkthrough is in docs/PACKAGING.md.

TRUST POSTURE (ADR-006 / SECURITY_POLICY)
  - AME Wizard is an UNSIGNED beta (tested against v0.8.4). Its own
    instructions require Defender exclusions and it may be flagged as a
    "Trojan Script". NEXTRIX does not add exclusions or bypass detections.
  - The .apbx fixed-password container exists for platform compatibility.
    Its documented purpose upstream is AV-scan evasion; NEXTRIX uses the
    convention, publishes full contents here, and hash-pins them.
  - Playbook "verified" status is discretionary and lost on modification.
    NEXTRIX claims no verified status.
  - UseKernelDriver=false; requirements are Internet and PluggedIn only.
    NEXTRIX never requires Defender/security toggles to be disabled.
  - Rollback is NEXTRIX-owned (NxJournal/NxRollback); the wizard has no uninstall.

WHAT THIS PACKAGE DOES NOT DO
  It does not run the playbook, download anything, bundle third-party binaries,
  or modify the repository. The inspect .zip next to the staging directory is
  NOT the playbook container.
'@
$notesText = $notesTemplate.Replace('{{VERSION}}', $Version)
$notesText = $notesText.Replace('{{CONFIGCOUNT}}', [string]$configYmlCount)
$notesText = $notesText.Replace('{{ENGINECOUNT}}', [string]$copiedEngine.Count)
$notesText = $notesText.Replace('{{MATCH}}', [string]$hashMatched)
$notesText = $notesText.Replace('{{MISMATCH}}', [string]$hashMismatched)
$notesText = $notesText.Replace('{{UNPINNEDLINE}}', $unpinnedLine)
$notesText = $notesText.Replace('{{STAGE}}', $stage)
$notesText = $notesText.Replace("`r`n", "`n").Replace("`n", "`r`n")
Write-NxTextFile (Join-Path $stage 'PACKAGING-NOTES.txt') $notesText

# ----------------------------------------------------------------------------
# 7. SHA256SUMS.txt (sorted, relative, self-excluded)
# ----------------------------------------------------------------------------
$allStageFiles = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object -Property FullName)
$sumRel = @()
foreach ($f in $allStageFiles) {
    $rel = Get-NxRelPath $stage $f.FullName
    if ($rel -eq 'SHA256SUMS.txt') { continue }
    $sumRel += $rel
}
$sumRel = @($sumRel | Sort-Object)
# Ordinal (culture-invariant) ordering keeps SHA256SUMS stable across machines.
$sumRel = [string[]]$sumRel
[array]::Sort($sumRel, [System.StringComparer]::Ordinal)
$sumLines = New-Object 'System.Collections.Generic.List[string]'
foreach ($rel in $sumRel) {
    $full = Join-Path $stage ($rel.Replace('/', '\'))
    $h = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    $sumLines.Add("$h  $rel")
}
Write-NxTextFile (Join-Path $stage 'SHA256SUMS.txt') (($sumLines.ToArray() -join "`r`n") + "`r`n")

$finalFiles = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
$sumCount = $sumLines.Count

# ----------------------------------------------------------------------------
# 8. Optional inspect zip (clearly NOT the playbook container)
# ----------------------------------------------------------------------------
$inspectZip = Join-Path $OutDir "NEXTRIX-v$Version-inspect.zip"
try {
    if (Test-Path -LiteralPath $inspectZip) { Remove-Item -LiteralPath $inspectZip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $inspectZip -CompressionLevel Optimal -Force
} catch {
    $warnings.Add("inspect zip was not created: $($_.Exception.Message)")
}

# ----------------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------------
Write-Output ''
Write-Output "Staging tree: $stage"
Write-Output "Files in staging (including SHA256SUMS.txt): $($finalFiles.Count)"
Write-Output "Configuration files: $($configFiles.Count)"
Write-Output "Engine modules in Executables/NxCore: $($copiedEngine.Count)"
Write-Output "Manifest hash sync: $hashMatched matched, $hashMismatched mismatched, $(@($hashUnpinned).Count) unpinned (not in manifest)."
Write-Output "SHA256SUMS entries: $sumCount"
Write-Output "Inspect zip (NOT the playbook container): $inspectZip"
Write-Output ''
Write-Output 'OWNER STEP (not performed): inside the staging directory run'
Write-Output ("  7z a -tzip NEXTRIX-v$Version.apbx * -p`"malte`"")
Write-Output 'Then verify SHA256SUMS and follow docs/PACKAGING.md.'
if ($warnings.Count -gt 0) {
    Write-Output ''
    Write-Output "Warnings ($($warnings.Count)):"
    foreach ($w in $warnings) { Write-Output "  - $w" }
}
Write-Output "RESULT: OK - package staged, 0 error(s), $($warnings.Count) warning(s)."
exit 0
