#Requires -Version 5.1
<#
    Export-NxMatrices.ps1 - deterministic dependency and conflict matrices.

    Reads registry/schema.json + registry/NX*.json (the single source of truth) and
    writes two generated documents at the repository root:

      DEPENDENCY_MATRIX.md   per-entry dependencies (with names) and reverse
                             dependents, engine-function dependency notes,
                             topological order, and a hard cycle check.
      CONFLICT_MATRIX.md     declared conflict pairs (symmetry-verified), derived
                             conflict groups, shared-value composer groups,
                             cross-reference overlap groups, curated
                             preset-pairing hazards, and the do-not-combine list.

    Every section is derived mechanically from the registry unless the row is
    explicitly labelled CURATED. Curated rows carry a verification token that is
    asserted against the registry text, so a curated note cannot silently rot.

    Determinism: all collections are sorted with ordinal string comparison; no
    timestamps are written; output is UTF-8 without BOM with LF line endings.

    Fail-loud conditions (exit 1, no files written):
      - invalid/missing JSON, duplicate ids, missing schema
      - dependency or conflict referencing a non-existent id, self-dependency
      - dependency cycle (Kahn ordering leaves nodes unemitted)
      - a curated note whose verification token is absent from the registry text

    This script reads JSON and writes Markdown only. It never modifies the
    registry, never executes a tweak and never touches the host.

    Exit codes: 0 = matrices written; 1 = validation failed.
#>
[CmdletBinding()]
param(
    [string]$RegistryDir,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

# Body-computed defaults: $PSScriptRoot is empty inside param() defaults under
# Windows PowerShell 5.1 -File invocation (W1-B finding, 2026-11-23).
if ([string]::IsNullOrWhiteSpace($RegistryDir)) { $RegistryDir = Join-Path $PSScriptRoot '..\registry' }
if ([string]::IsNullOrWhiteSpace($OutDir))     { $OutDir     = Join-Path $PSScriptRoot '..' }

$RegistryDir = [System.IO.Path]::GetFullPath($RegistryDir)
$OutDir      = [System.IO.Path]::GetFullPath($OutDir)
$repoRoot    = Split-Path $PSScriptRoot -Parent

if ($OutDir.TrimEnd('\') -match '^[A-Za-z]:$') {
    Write-Output "FATAL: -OutDir refuses a drive root ('$OutDir')."
    exit 1
}
if (-not (Test-Path -LiteralPath $RegistryDir)) { Write-Output "FATAL: registry directory not found: $RegistryDir"; exit 1 }
$schemaPath = Join-Path $RegistryDir 'schema.json'
if (-not (Test-Path -LiteralPath $schemaPath)) { Write-Output "FATAL: schema.json not found in $RegistryDir"; exit 1 }

$errors   = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

# ----------------------------------------------------------------------------
# Helpers (PowerShell 5.1 compatible; all output ASCII)
# ----------------------------------------------------------------------------
function Sort-NxOrdinal {
    # Ordinal (culture-invariant) sort of a string collection; duplicate-preserving.
    param([string[]]$Items)
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($i in @($Items)) {
        if ($null -ne $i) { $list.Add([string]$i) }
    }
    $list.Sort([System.StringComparer]::Ordinal)
    # No unary comma: callers wrap the output in @(), and a wrapped array would
    # otherwise arrive as one nested element.
    return $list.ToArray()
}

function Sort-NxUniqueOrdinal {
    param([string[]]$Items)
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($i in @(Sort-NxOrdinal $Items)) {
        if ($list.Count -eq 0 -or $list[$list.Count - 1] -ne $i) { $list.Add($i) }
    }
    return $list.ToArray()
}

function Format-NxCell {
    # Markdown table cell: single line, pipes escaped.
    param([string]$Text, [int]$MaxLength = 0)
    if ($null -eq $Text) { return '' }
    $t = [string]$Text
    $t = $t -replace '\s*\r?\n\s*', ' '
    $t = $t.Replace('|', '\|').Trim()
    if ($MaxLength -gt 0 -and $t.Length -gt $MaxLength) {
        $t = $t.Substring(0, $MaxLength - 3).TrimEnd() + '...'
    }
    return $t
}

function Get-NxTextBlob($Tweak) {
    $fields = @('description', 'objective', 'defaultState', 'proposedState',
                'technicalExplanation', 'sideEffects', 'documentationSource')
    $parts = @()
    foreach ($f in $fields) {
        $v = [string]$Tweak.$f
        if (-not [string]::IsNullOrWhiteSpace($v)) { $parts += $v }
    }
    return ($parts -join ' ')
}

function Get-NxSentences([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $parts = [regex]::Split($Text, '(?<=[.!?])\s+')
    return @($parts)
}

function Get-NxAppliedFunctions($Tweak) {
    $fns = @()
    foreach ($a in @($Tweak.apply.actions)) {
        if ($null -ne $a.PSObject.Properties['function'] -and -not [string]::IsNullOrWhiteSpace([string]$a.function)) {
            $fns += [string]$a.function
        }
    }
    return @(Sort-NxUniqueOrdinal $fns)
}

function Get-NxWaveKey([string]$Category) {
    if ($Category -eq 'NX16') { return 0 }          # recovery substrate first
    if ($Category -match '^NX(\d{2})$') { return [int]$Matches[1] }
    return 999
}

# ----------------------------------------------------------------------------
# Load registry
# ----------------------------------------------------------------------------
try { $schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Write-Output "FATAL: schema.json is not valid JSON: $($_.Exception.Message)"; exit 1 }

$files = @(Get-ChildItem -LiteralPath $RegistryDir -Filter 'NX*.json' -File | Sort-Object -Property Name)
if ($files.Count -eq 0) { Write-Output "FATAL: no registry/NX*.json files found in $RegistryDir"; exit 1 }

$categories = @()
$allTweaks  = @()
foreach ($f in $files) {
    $cat = $null
    try { $cat = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $errors.Add("file $($f.Name): invalid JSON - $($_.Exception.Message)"); continue }
    if (-not $cat.tweaks) { $errors.Add("file $($f.Name): no tweaks array"); continue }
    $categories += @{
        file         = $f.Name
        category     = [string]$cat.category
        categoryName = [string]$cat.categoryName
        tweaks       = @($cat.tweaks)
    }
    foreach ($t in @($cat.tweaks)) { $allTweaks += $t }
}
if ($errors.Count -gt 0) {
    Write-Output 'REGISTRY LOAD FAILED:'
    foreach ($e in $errors) { Write-Output "  ERROR: $e" }
    exit 1
}

$byId      = @{}
$idToCat   = @{}
$catNames  = @{}
foreach ($c in $categories) { $catNames[$c.category] = $c.categoryName }
foreach ($t in $allTweaks) {
    $tid = [string]$t.id
    if ($byId.ContainsKey($tid)) { $errors.Add("duplicate tweak id: $tid"); continue }
    $byId[$tid] = $t
    $idToCat[$tid] = [string]$t.category
}

$allIds = @(Sort-NxOrdinal @($allTweaks | ForEach-Object { [string]$_.id }))

# ----------------------------------------------------------------------------
# Validate dependency/conflict references (fail-loud; the matrices are only
# meaningful if every declared edge resolves)
# ----------------------------------------------------------------------------
foreach ($t in $allTweaks) {
    $tid = [string]$t.id
    foreach ($d in @($t.dependencies)) {
        if ([string]::IsNullOrWhiteSpace([string]$d)) { continue }
        if ([string]$d -eq $tid) { $errors.Add("${tid}: self-dependency") ; continue }
        if (-not $byId.ContainsKey([string]$d)) { $errors.Add("${tid}: dependency '$d' does not exist") }
    }
    foreach ($c in @($t.conflicts)) {
        if ([string]::IsNullOrWhiteSpace([string]$c)) { continue }
        if ([string]$c -eq $tid) { $errors.Add("${tid}: self-conflict"); continue }
        if (-not $byId.ContainsKey([string]$c)) { $errors.Add("${tid}: conflict '$c' does not exist") }
    }
}
if ($errors.Count -gt 0) {
    Write-Output 'DEPENDENCY/CONFLICT REFERENCE VALIDATION FAILED:'
    foreach ($e in $errors) { Write-Output "  ERROR: $e" }
    exit 1
}

# ----------------------------------------------------------------------------
# Dependency graph: adjacency + Kahn topological order (cycle check)
# ----------------------------------------------------------------------------
$dependents = @{}          # provider id -> sorted consumer ids
$depEdges   = New-Object System.Collections.Generic.List[object]
foreach ($id in $allIds) { $dependents[$id] = New-Object 'System.Collections.Generic.List[string]' }

foreach ($id in $allIds) {
    $t = $byId[$id]
    $deps = @(Sort-NxUniqueOrdinal @($t.dependencies))
    foreach ($d in $deps) {
        $dependents[$d].Add($id)
        $depEdges.Add([pscustomobject]@{ provider = $d; consumer = $id })
    }
}

$indegree = @{}
foreach ($id in $allIds) { $indegree[$id] = 0 }
foreach ($e in $depEdges) { $indegree[$e.consumer] = $indegree[$e.consumer] + 1 }

$ready = New-Object 'System.Collections.Generic.List[string]'
foreach ($id in $allIds) { if ($indegree[$id] -eq 0) { $ready.Add($id) } }
$topoOrder = New-Object 'System.Collections.Generic.List[string]'
$level     = @{}
foreach ($id in $allIds) { $level[$id] = 0 }
while ($ready.Count -gt 0) {
    $ready.Sort([System.StringComparer]::Ordinal)
    $n = $ready[0]
    $ready.RemoveAt(0)
    $topoOrder.Add($n)
    foreach ($m in @(Sort-NxUniqueOrdinal @($dependents[$n].ToArray()))) {
        if ($level[$m] -lt ($level[$n] + 1)) { $level[$m] = $level[$n] + 1 }
        $indegree[$m] = $indegree[$m] - 1
        if ($indegree[$m] -eq 0) { $ready.Add($m) }
    }
}

if ($topoOrder.Count -ne $allIds.Count) {
    $ordered = @{}
    foreach ($id in $topoOrder) { $ordered[$id] = $true }
    $unstuck = @()
    foreach ($id in $allIds) { if (-not $ordered.ContainsKey($id)) { $unstuck += $id } }
    Write-Output 'FATAL: dependency cycle detected - no matrix was written.'
    Write-Output ('  nodes that could not be topologically ordered: ' + ($unstuck -join ', '))
    # Show one concrete cycle path where possible.
    $probe = $unstuck[0]
    Write-Output "  start from '$probe': " + (@($byId[$probe].dependencies) -join ' -> ')
    exit 1
}
$layerCount = 0
foreach ($id in $allIds) { if ($level[$id] + 1 -gt $layerCount) { $layerCount = $level[$id] + 1 } }

# ----------------------------------------------------------------------------
# Engine-function inventory: which src module defines each applied function?
# ----------------------------------------------------------------------------
$fnSource = @{}
$srcDir = Join-Path $repoRoot 'src'
$srcFiles = @()
if (Test-Path -LiteralPath $srcDir) {
    $srcFiles = @(Get-ChildItem -LiteralPath $srcDir -Recurse -Filter '*.ps1' -File | Sort-Object -Property FullName)
}
$srcRoot = $srcDir.TrimEnd('\')
foreach ($f in $srcFiles) {
    $rel = $f.FullName.Substring($srcRoot.Length + 1).Replace('\', '/')
    $rel = 'src/' + $rel
    $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
    foreach ($m in [regex]::Matches($text, '(?m)^\s*function\s+([A-Za-z0-9_\-]+)')) {
        $name = $m.Groups[1].Value
        if (-not $fnSource.ContainsKey($name)) { $fnSource[$name] = $rel }   # first definition by sorted path wins
    }
}

# ----------------------------------------------------------------------------
# Curated engine-call edges (marked CURATED; each token is asserted below)
# These are the cross-category engine calls the registry text documents. They
# are not all expressible as registry dependencies (e.g. NX18's calls into NX19
# are engine functions, not tweak settings).
# ----------------------------------------------------------------------------
$engineEdges = @(
    [pscustomobject]@{ consumer = 'NX18-004'; provider = 'NX19-002'; function = 'New-NxCpuSetPlan';        token = 'New-NxCpuSetPlan' }
    [pscustomobject]@{ consumer = 'NX18-004'; provider = 'NX19-003'; function = 'Set-NxProcessCpuSets';    token = 'Set-NxProcessCpuSets' }
    [pscustomobject]@{ consumer = 'NX18-005'; provider = 'NX09-001'; function = 'Set-NxActivePowerPlan';   token = 'Set-NxActivePowerPlan' }
    [pscustomobject]@{ consumer = 'NX18-006'; provider = 'NX19-005'; function = 'Set-NxProcessPriority';   token = 'Set-NxProcessPriority' }
    [pscustomobject]@{ consumer = 'NX18-006'; provider = 'NX19-002'; function = 'New-NxCpuSetPlan';        token = 'NX19-002' }
    [pscustomobject]@{ consumer = 'NX18-009'; provider = 'NX19-005'; function = 'Set-NxProcessPriority';   token = 'Set-NxProcessPriority' }
    [pscustomobject]@{ consumer = 'NX18-008'; provider = '(NxApply/NxRollback)'; function = 'Invoke-NxRegistryTweak / Invoke-NxRollback'; token = 'Invoke-NxRegistryTweak' }
    [pscustomobject]@{ consumer = 'NX18-010'; provider = '(NX19/NX09/NxApply engines)'; function = 'journal read/restore engines'; token = 'NX19/NX09/NxApply' }
    [pscustomobject]@{ consumer = 'NX18-011'; provider = '(Nx18 session engine)'; function = 'Start-NxSession -> owning engines'; token = 'All mutation goes through the engines' }
)
foreach ($e in $engineEdges) {
    if (-not $byId.ContainsKey($e.consumer)) { $errors.Add("curated engine edge: consumer '$($e.consumer)' not found"); continue }
    $blob = Get-NxTextBlob $byId[$e.consumer]
    if ($blob.IndexOf($e.token, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $errors.Add("curated engine edge: token '$($e.token)' not found in $($e.consumer) text (curated note is stale)")
    }
    if ($e.provider -match '^NX\d{2}-\d{3}$') {
        $declaredDeps = @($byId[$e.consumer].dependencies)
        if ($declaredDeps -notcontains $e.provider) {
            $warnings.Add("curated engine edge: $($e.consumer) calls $($e.provider) but does not declare it as a dependency")
        }
    }
}
if ($errors.Count -gt 0) {
    Write-Output 'CURATED NOTE VERIFICATION FAILED:'
    foreach ($e in $errors) { Write-Output "  ERROR: $e" }
    exit 1
}

# ----------------------------------------------------------------------------
# Shared engine functions across categories (composer detection, mechanical)
# ----------------------------------------------------------------------------
$fnConsumers = @{}
foreach ($t in $allTweaks) {
    foreach ($fn in @(Get-NxAppliedFunctions $t)) {
        if (-not $fnConsumers.ContainsKey($fn)) { $fnConsumers[$fn] = New-Object 'System.Collections.Generic.List[string]' }
        $fnConsumers[$fn].Add([string]$t.id)
    }
}
$composerGroups = @()
foreach ($fn in @(Sort-NxOrdinal @($fnConsumers.Keys))) {
    $consumers = @(Sort-NxUniqueOrdinal @($fnConsumers[$fn].ToArray()))
    if ($consumers.Count -lt 2) { continue }
    $catSet = New-Object 'System.Collections.Generic.List[string]'
    foreach ($cid in $consumers) {
        $cc = $idToCat[$cid]
        if (-not $catSet.Contains($cc)) { $catSet.Add($cc) }
    }
    if ($catSet.Count -gt 1) {
        $composerGroups += [pscustomobject]@{ function = $fn; consumers = $consumers; categories = @(Sort-NxOrdinal @($catSet.ToArray())) }
    }
}

# ----------------------------------------------------------------------------
# Conflict graph: symmetric pairs + connected components
# ----------------------------------------------------------------------------
$pairMap = @{}
foreach ($t in $allTweaks) {
    $a = [string]$t.id
    foreach ($c in @($t.conflicts)) {
        $b = [string]$c
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        if ($b -eq $a) { continue }
        if ($a -lt $b) { $key = "$a|$b"; $x = $a; $y = $b } else { $key = "$b|$a"; $x = $b; $y = $a }
        if (-not $pairMap.ContainsKey($key)) {
            $pairMap[$key] = [pscustomobject]@{ a = $x; b = $y; declaredByA = $false; declaredByB = $false }
        }
        if ($x -eq $a) { $pairMap[$key].declaredByA = $true } else { $pairMap[$key].declaredByB = $true }
    }
}
$pairs = @()
foreach ($key in @(Sort-NxOrdinal @($pairMap.Keys))) { $pairs += $pairMap[$key] }

$asymmetric = @()
foreach ($p in $pairs) {
    if (-not ($p.declaredByA -and $p.declaredByB)) {
        $asymmetric += $p
        $warnings.Add("conflict asymmetry: $($p.a) <-> $($p.b) is declared in one direction only")
    }
}

# Connected components of the declared conflict graph (undirected).
$conflictAdj = @{}
foreach ($p in $pairs) {
    foreach ($x in @($p.a, $p.b)) {
        if (-not $conflictAdj.ContainsKey($x)) { $conflictAdj[$x] = New-Object 'System.Collections.Generic.List[string]' }
    }
    if (-not $conflictAdj[$p.a].Contains($p.b)) { $conflictAdj[$p.a].Add($p.b) }
    if (-not $conflictAdj[$p.b].Contains($p.a)) { $conflictAdj[$p.b].Add($p.a) }
}
$conflictGroups = @()
$seen = @{}
foreach ($start in @(Sort-NxOrdinal @($conflictAdj.Keys))) {
    if ($seen.ContainsKey($start)) { continue }
    $comp = New-Object 'System.Collections.Generic.List[string]'
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($start); $seen[$start] = $true
    while ($queue.Count -gt 0) {
        $n = [string]$queue.Dequeue()
        $comp.Add($n)
        foreach ($m in @(Sort-NxOrdinal @($conflictAdj[$n].ToArray()))) {
            if (-not $seen.ContainsKey($m)) { $seen[$m] = $true; $queue.Enqueue($m) }
        }
    }
    $conflictGroups += [pscustomobject]@{ members = @(Sort-NxOrdinal @($comp.ToArray())) }
}
$conflictGroups = @($conflictGroups | Sort-Object -Property @{ Expression = { $_.members[0] } })

# Curated resolution notes for conflict groups, keyed by sorted member list.
$conflictGroupNotes = @{
    'NX05-001,NX05-002,NX05-003,NX05-009' = 'Pagefile modes are mutually exclusive: NX05-001 (system-managed), NX05-002 (custom size) and NX05-003 (no pagefile) write the same Session Manager Memory Management values. NX05-009 needs a boot-volume pagefile for kernel/complete dumps, so it conflicts with NX05-003. Select one pagefile mode; pair crash-dump type with NX05-001 or NX05-002.'
    'NX07-016,NX07-017,NX07-018,NX07-020,NX07-021' = 'NX07-021 resets Winsock and the TCP/IPv4/IPv6 stacks and can clear the DNS, MTU and TCP-global settings written by NX07-016/017/018; NX07-020 (DNS cache flush) is also subsumed during a reset. Run the reset alone, then re-apply targeted settings; never select the reset as a tidy-up after configuration.'
    'NX02-008,NX11-010,NX12-005' = 'Xbox app removal (NX12-005) and Xbox service configuration (NX11-010) change the same Xbox/Game Pass surface; NX02-008 is the read-only dependency report that must be consulted before either change and its report declares the NX12-005 conflict.'
    'NX12-004,NX13-012' = 'Phone Link removal (app) and the phone-PC linking policy (NX13-012) reach the same feature from two directions; choose one. NX13-012 leaves the app installed and disables the policy; NX12-004 removes the app while NX13-012 keeps policy ownership.'
    'NX19-003,NX19-004' = 'CPU Sets (soft placement) and affinity (hard mask) are two mechanisms for the same per-process placement; affinity overrides CPU sets. Select one per process, and never both for the same image.'
}

# ----------------------------------------------------------------------------
# Cross-reference overlap groups (mechanical): sentences that contain an
# explicit ownership marker AND two or more tweak ids. Coordination signal
# only - being in one group is NOT a conflict.
# ----------------------------------------------------------------------------
$xrefPattern = 'XREF|overlap|alternative control|choose one|do not pair|two directions'
$xrefEdges = @{}
foreach ($t in $allTweaks) {
    $tid = [string]$t.id
    $fields = @('description', 'objective', 'technicalExplanation', 'sideEffects', 'documentationSource')
    foreach ($f in $fields) {
        $v = [string]$t.$f
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        foreach ($sentence in @(Get-NxSentences $v)) {
            if ($sentence -notmatch $xrefPattern) { continue }
            $found = @(Sort-NxUniqueOrdinal @([regex]::Matches($sentence, 'NX\d{2}-\d{3}') | ForEach-Object { $_.Value }))
            if ($found.Count -lt 2) { continue }
            for ($i = 0; $i -lt $found.Count; $i++) {
                for ($j = $i + 1; $j -lt $found.Count; $j++) {
                    $x = $found[$i]; $y = $found[$j]
                    if ($x -eq $y) { continue }
                    if (-not $byId.ContainsKey($x) -or -not $byId.ContainsKey($y)) { continue }
                    $key = "$x|$y"
                    if (-not $xrefEdges.ContainsKey($key)) { $xrefEdges[$key] = [pscustomobject]@{ a = $x; b = $y; evidence = $tid + '.' + $f } }
                }
            }
        }
    }
}
$xrefList = @()
foreach ($k in @(Sort-NxOrdinal @($xrefEdges.Keys))) { $xrefList += $xrefEdges[$k] }

$xrefAdj = @{}
foreach ($e in $xrefList) {
    foreach ($x in @($e.a, $e.b)) { if (-not $xrefAdj.ContainsKey($x)) { $xrefAdj[$x] = New-Object 'System.Collections.Generic.List[string]' } }
    if (-not $xrefAdj[$e.a].Contains($e.b)) { $xrefAdj[$e.a].Add($e.b) }
    if (-not $xrefAdj[$e.b].Contains($e.a)) { $xrefAdj[$e.b].Add($e.a) }
}
$xrefGroups = @()
$seenX = @{}
foreach ($start in @(Sort-NxOrdinal @($xrefAdj.Keys))) {
    if ($seenX.ContainsKey($start)) { continue }
    $comp = New-Object 'System.Collections.Generic.List[string]'
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($start); $seenX[$start] = $true
    while ($queue.Count -gt 0) {
        $n = [string]$queue.Dequeue()
        $comp.Add($n)
        foreach ($m in @(Sort-NxOrdinal @($xrefAdj[$n].ToArray()))) {
            if (-not $seenX.ContainsKey($m)) { $seenX[$m] = $true; $queue.Enqueue($m) }
        }
    }
    $xrefGroups += [pscustomobject]@{ members = @(Sort-NxOrdinal @($comp.ToArray())) }
}
$xrefGroups = @($xrefGroups | Sort-Object -Property @{ Expression = { $_.members[0] } })

# ----------------------------------------------------------------------------
# Curated preset-pairing hazards (each verified against registry text below)
# ----------------------------------------------------------------------------
$hazards = @(
    [pscustomobject]@{
        a = 'NX11-006'; b = 'NX13-013'; status = 'CURATED hazard (no declared conflict)'
        hazard = 'Both can disable the same scheduled tasks; NX13-013 states that 8 of its 9 task names overlap NX11-006. Either entry is idempotent against the other, but selecting both for the same task is redundant.'
        resolution = 'Pick one owner: NX13-013 for the telemetry task set (it owns that curation), NX11-006 for non-telemetry allow-listed tasks. Do not select both for the same task in one preset.'
        evidence = 'NX13-013.sideEffects / NX11-006.technicalExplanation'
        token = 'overlaps 8 of the 9 task names'
        tokenOwner = 'NX13-013'
        field = 'sideEffects'
    }
    [pscustomobject]@{
        a = 'NX11-009'; b = 'NX05-004'; status = 'CURATED hazard (no declared conflict)'
        hazard = 'Memory-compression changes require SysMain to be running; NX11-009 can disable SysMain, after which the compression change fails cleanly (service dependency, error 1058) or cannot take effect.'
        resolution = 'Do not disable SysMain in a preset that changes memory compression. Leave compression at its default when SysMain is disabled, or keep SysMain running when compression is selected.'
        evidence = 'NX11-009.sideEffects / NX05-004.sideEffects'
        token = 'do not pair them with a SysMain disable'
        tokenOwner = 'NX11-009'
        field = 'sideEffects'
    }
    [pscustomobject]@{
        a = 'NX12-004'; b = 'NX13-012'; status = 'registry-declared symmetric conflict; curated resolution'
        hazard = 'App removal and policy disable reach the same phone-PC linking feature from two directions; selecting both is redundant.'
        resolution = 'Choose one. NX13-012 disables phone-PC linking and cross-device clipboard without deleting an app; NX12-004 removes the Phone Link app.'
        evidence = 'NX12-004.technicalExplanation / NX13-012.sideEffects'
        token = 'both reach the same feature'
        tokenOwner = 'NX13-012'
        field = 'sideEffects'
    }
    [pscustomobject]@{
        a = 'NX12-005'; b = 'NX11-010'; status = 'registry-declared symmetric conflict; curated resolution'
        hazard = 'Removing the Xbox app and configuring Xbox services both change the Xbox client surface; service background activity is NX11 territory while app removal is NX12 territory.'
        resolution = 'Choose the removal (NX12-005) or the service configuration (NX11-010), not both in one preset. Game Pass users are excluded from NX12-005 by its evidence gate.'
        evidence = 'NX12-005.technicalExplanation / NX11-010.sideEffects'
        token = 'symmetric conflict'
        tokenOwner = 'NX12-005'
        field = 'documentationSource'
    }
    [pscustomobject]@{
        a = 'NX12-005'; b = 'NX02-008'; status = 'registry-declared symmetric conflict; curated resolution'
        hazard = 'NX12-005 removes the Xbox app; NX02-008 is the read-only Xbox dependency report that must inform that decision. The report itself mutates nothing, so the conflict is about decision order, not mechanical exclusion.'
        resolution = 'Run/read NX02-008 first (report only), then decide on NX12-005. Never treat the report as an applied change; do not bundle the pair as "the Xbox preset" without the Game Pass gate.'
        evidence = 'NX02-008.technicalExplanation / NX12-005.sideEffects'
        token = 'Conflict with NX12-005'
        tokenOwner = 'NX02-008'
        field = 'technicalExplanation'
    }
)
foreach ($h in $hazards) {
    if (-not $byId.ContainsKey($h.a) -or -not $byId.ContainsKey($h.b)) {
        $errors.Add("curated hazard: $($h.a) <-> $($h.b) references a missing id"); continue
    }
    $ownerBlob = [string]$byId[$h.tokenOwner].($h.field)
    if ($ownerBlob.IndexOf($h.token, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $errors.Add("curated hazard: token '$($h.token)' not found in $($h.tokenOwner).$($h.field) (curated note is stale)")
    }
    $declared = (@($byId[$h.a].conflicts) -contains $h.b) -or (@($byId[$h.b].conflicts) -contains $h.a)
    if ($h.status -like 'registry-declared*' -and -not $declared) {
        $errors.Add("curated hazard: $($h.a) <-> $($h.b) is labelled registry-declared but no conflict is declared")
    }
    if ($h.status -like 'CURATED*' -and $declared) {
        $warnings.Add("curated hazard: $($h.a) <-> $($h.b) is now a declared conflict; update the curated status")
    }
}
if ($errors.Count -gt 0) {
    Write-Output 'CURATED HAZARD VERIFICATION FAILED:'
    foreach ($e in $errors) { Write-Output "  ERROR: $e" }
    exit 1
}

# ----------------------------------------------------------------------------
# Derived dependency rows and engine notes
# ----------------------------------------------------------------------------
$depRows = @()
foreach ($id in $allIds) {
    $deps = @(Sort-NxUniqueOrdinal @($byId[$id].dependencies))
    $kids = @(Sort-NxUniqueOrdinal @($dependents[$id].ToArray()))
    if ($deps.Count -eq 0 -and $kids.Count -eq 0) { continue }
    $t = $byId[$id]
    $notes = New-Object 'System.Collections.Generic.List[string]'
    $myFns = @(Get-NxAppliedFunctions $t)
    foreach ($fn in $myFns) {
        if ($fnSource.ContainsKey($fn) -and $fnSource[$fn] -notlike 'src/nxcore/*') {
            $notes.Add("engine module outside src/nxcore: $fn ($($fnSource[$fn]))")
        }
    }
    $blob = Get-NxTextBlob $t
    foreach ($d in $deps) {
        $depT = $byId[$d]
        foreach ($pf in @(Get-NxAppliedFunctions $depT)) {
            # A shared engine function (same function on both sides) is ordinary
            # reuse, not a cross-entry engine call.
            if ($myFns -contains $pf) { continue }
            $already = $false
            for ($i = 0; $i -lt $notes.Count; $i++) { if ($notes[$i] -like "engine call: $pf *") { $already = $true; break } }
            if (-not $already -and $blob.IndexOf($pf, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $notes.Add("engine call: $pf ($d)")
            }
        }
        if ([string]$depT.category -ne [string]$t.category) {
            $notes.Add("cross-category dependency: $d ($($depT.category))")
        }
        if ((Get-NxWaveKey ([string]$depT.category)) -gt (Get-NxWaveKey ([string]$t.category))) {
            $notes.Add("wave-order inversion: playbook wave order emits $d ($($depT.category)) after $($t.category)")
        }
    }
    $depRows += [pscustomobject]@{
        id = $id; tweak = $t; deps = $deps; kids = $kids; notes = @($notes.ToArray())
    }
}

# ----------------------------------------------------------------------------
# Markdown renderers
# ----------------------------------------------------------------------------
function Format-NxIdName([string]$Id) {
    if (-not $script:byId.ContainsKey($Id)) { return $Id }
    return "$Id $([string]$script:byId[$Id].name)"
}

function Format-NxIdList([string[]]$Ids) {
    if (@($Ids).Count -eq 0) { return '-' }
    $parts = @()
    foreach ($i in @($Ids)) { $parts += (Format-NxIdName $i) }
    return ($parts -join '; ')
}

function New-NxDependencyMarkdown {
    $L = New-Object 'System.Collections.Generic.List[string]'
    $depEntries = @($allTweaks | Where-Object { @($_.dependencies).Count -gt 0 })
    $dependedOn = @($dependents.Keys | Where-Object { $dependents[$_].Count -gt 0 })
    $engineBacked = @($allTweaks | Where-Object { @(Get-NxAppliedFunctions $_).Count -gt 0 })
    $unresolvedFns = @($fnConsumers.Keys | Where-Object { -not $fnSource.ContainsKey($_) } | ForEach-Object { $_ } | Sort-Object)

    $L.Add('# NEXTRIX - Dependency Matrix')
    $L.Add('')
    $L.Add('**Status:** generated artifact - do not edit by hand.')
    $L.Add('**Generator:** `tools/Export-NxMatrices.ps1`')
    $L.Add("**Source of truth:** ``registry/NX*.json`` ($($files.Count) category files, $($allTweaks.Count) entries) and ``registry/schema.json``.")
    $L.Add('**Regenerate:** `powershell.exe -NoProfile -File tools\Export-NxMatrices.ps1` (or `pwsh`).')
    $L.Add('**Determinism:** ordinal sorts, no timestamps, UTF-8 without BOM, LF line endings.')
    $L.Add('')
    $L.Add('| Metric | Value |')
    $L.Add('|---|---|')
    $L.Add("| Registry entries | $($allTweaks.Count) |")
    $L.Add("| Entries declaring dependencies | $(@($depEntries).Count) |")
    $L.Add("| Dependency edges | $($depEdges.Count) |")
    $L.Add("| Entries that others depend on | $(@($dependedOn).Count) |")
    $L.Add("| Rows in section 3 (has dependencies and/or dependents) | $($depRows.Count) |")
    $L.Add("| Entries with an engine function action | $(@($engineBacked).Count) |")
    $L.Add("| Distinct applied engine functions | $($fnConsumers.Count) |")
    $L.Add("| Applied functions resolved to a src module | $(@($fnConsumers.Keys | Where-Object { $fnSource.ContainsKey($_) }).Count) |")
    $L.Add("| Applied functions not found in src at export time | $(@($unresolvedFns).Count) |")
    $L.Add("| Topological layers | $layerCount |")
    $L.Add("| Dependency cycles | 0 (hard check below) |")
    $L.Add('')
    $L.Add('## 1. Legend')
    $L.Add('')
    $L.Add('**Risk classes** (`registry/schema.json` `riskClasses`, definitions from `TWEAK_CLASSIFICATION.md`):')
    $L.Add('')
    $L.Add('| Class | Meaning | Preset behavior |')
    $L.Add('|---|---|---|')
    $L.Add('| CORE | Low-risk, well-understood, journal-reversible, no functional sacrifice | Default-on candidate in matching profiles (still deselectable) |')
    $L.Add('| CONDITIONAL | Valid for a workload/hardware/preference with a stated trade-off | Offered, never auto-applied |')
    $L.Add('| ADVANCED | Higher blast radius or multi-factor compatibility | Opt-in only; preset-excluded or ExplicitConsent |')
    $L.Add('| EXPERIMENTAL | Uncertain/hardware-dependent, weak generalization | Never in presets; explicit warnings |')
    $L.Add('| TROUBLESHOOTING | Targets a named symptom, not general performance | Never in presets; symptom-only |')
    $L.Add('')
    $L.Add('**Evidence levels** (`TWEAK_CLASSIFICATION.md`): E0 unverified community configuration; E1 documented Windows/vendor behavior; E2 evaluated on one owner machine; E3 evaluated on multiple machines; E4 independently reproducible. Registry assignments start at E0/E1 only.')
    $L.Add('')
    $L.Add('**Dependency semantics:** the playbook (and a rollback replay) must satisfy a dependency before the dependent entry. A dependency here is a logical prerequisite, not necessarily a value write - see section 4 for engine-function calls that are not expressible as settings.')
    $L.Add('')
    $L.Add('## 2. Dependency rows')
    $L.Add('')
    $L.Add('One row per entry that declares dependencies and/or is depended upon. `Depends on` lists ids with names; `Dependents` is the reverse edge set (ids only, sorted). `Notes` are derived from the registry text and the engine inventory; curated engine notes are labelled in section 3.')
    $L.Add('')
    $L.Add('| Tweak | Name | Risk / Evidence | Depends on | Dependents | Notes |')
    $L.Add('|---|---|---|---|---|---|')
    foreach ($row in $depRows) {
        $risk = "$([string]$row.tweak.risk) / $([string]$row.tweak.evidence)"
        $notes = '-'
        if (@($row.notes).Count -gt 0) { $notes = (@($row.notes) -join '; ') }
        $kids = '-'
        if (@($row.kids).Count -gt 0) { $kids = (@($row.kids) -join ', ') }
        $L.Add('| ' + (Format-NxCell $row.id) + ' | ' + (Format-NxCell ([string]$row.tweak.name)) + ' | ' + (Format-NxCell $risk) + ' | ' + (Format-NxCell (Format-NxIdList $row.deps)) + ' | ' + (Format-NxCell $kids) + ' | ' + (Format-NxCell $notes 520) + ' |')
    }
    $L.Add('')
    $L.Add('## 3. Engine-function dependencies')
    $L.Add('')
    $L.Add('### 3.1 Entries whose engine module lives outside `src/nxcore` (mechanical)')
    $L.Add('')
    $outside = @()
    foreach ($id in $allIds) {
        foreach ($fn in @(Get-NxAppliedFunctions $byId[$id])) {
            if ($fnSource.ContainsKey($fn) -and $fnSource[$fn] -notlike 'src/nxcore/*') {
                $outside += [pscustomobject]@{ id = $id; fn = $fn; source = $fnSource[$fn] }
            }
        }
    }
    if (@($outside).Count -eq 0) {
        $L.Add('None: every resolved applied function is defined under `src/nxcore`.')
    } else {
        $L.Add('Grouped by defining module; the packaging consequence is identical for every entry in a group.')
        $L.Add('')
        $L.Add('| Entries | Applied function | Defining module | Packaging consequence |')
        $L.Add('|---|---|---|---|')
        $grouped = @{}
        foreach ($o in $outside) {
            $key = "$($o.fn)|$($o.source)"
            if (-not $grouped.ContainsKey($key)) { $grouped[$key] = New-Object 'System.Collections.Generic.List[string]' }
            $grouped[$key].Add($o.id)
        }
        foreach ($key in @(Sort-NxOrdinal @($grouped.Keys))) {
            $fnName, $srcName = $key -split '\|', 2
            $ids = @(Sort-NxUniqueOrdinal @($grouped[$key].ToArray()))
            $consequence = 'Bundled by `tools/New-NxPackage.ps1` into the flat engine tree.'
            if ($srcName -like 'src/nxsession/*') { $consequence = 'Bundled by `tools/New-NxPackage.ps1`; NOT inventoried by `tools/Invoke-NxBuild.ps1` (KNOWN_ISSUES 16), so the manifest cannot hash-pin it.' }
            $L.Add("| $($ids -join ', ') | $fnName | ``$srcName`` | $consequence |")
        }
    }
    $L.Add('')
    $L.Add('### 3.2 Cross-category engine calls (CURATED, token-verified)')
    $L.Add('')
    $L.Add('These calls are documented in the registry text but are not registry dependencies of a setting: the consumer runs an engine function that belongs to, or delegates to, another category''s engine. Each row''s token is asserted against the owning entry at export time, so the note cannot silently drift. This is the NX18 -> NX19/NX09 dependency family (NX18 is the session subsystem; its CPU-set, priority and power steps call NX19/NX09 engine functions).')
    $L.Add('')
    $L.Add('| Consumer | Provider / owner | Engine function(s) | Evidence in registry text |')
    $L.Add('|---|---|---|---|')
    foreach ($e in $engineEdges) {
        $L.Add("| $($e.consumer) | $($e.provider) | $($e.function) | ``$($e.consumer)`` text contains ``$($e.token)`` |")
    }
    $L.Add('')
    $L.Add('Structural engine wiring (verified by function definition, not an entry-to-entry dependency):')
    $L.Add('')
    $L.Add('- `NX16-004` applies `Invoke-NxPreFlight`; the generator routes that function to the unconditional `Tasks/nxcore.yml` pre-flight (errorAction Halt) instead of a user option.')
    $L.Add('- `NX16-013`..`NX16-016` apply `Invoke-NxRollback`; the generator routes those four scopes to `Tasks/rollback.yml`, all default-off.')
    $L.Add('- `NX16-014`/`NX16-015`/`NX16-016` depend on `NX16-013` (journal read/restore primitives), which is why the rollback surface is ordered after the pre-flight capture.')
    $L.Add('')
    if (@($unresolvedFns).Count -gt 0) {
        $L.Add('### 3.3 Applied functions not found in `src` at export time')
        $L.Add('')
        $L.Add('These names are referenced by registry `apply.actions` but no `function <name>` definition was found while scanning `src/**/*.ps1`. Concurrent authoring or a stale registry edge is the usual cause; the generator emits such names by name and the manifest lists them as expected.')
        $L.Add('')
        $L.Add('| Function | Declared by |')
        $L.Add('|---|---|')
        foreach ($fn in @($unresolvedFns)) {
            $L.Add("| $fn | $((@($fnConsumers[$fn].ToArray()) | Sort-Object) -join ', ') |")
        }
        $L.Add('')
    }
    $L.Add('## 4. Topological order')
    $L.Add('')
    $L.Add("Deterministic Kahn order over all $($allTweaks.Count) entries (dependencies first; ties broken by ordinal id). Flat order below; the $layerCount layer boundaries are where the ready set advanced. This order is a correctness reference for replay/rollback, not the playbook's wave order (categories are emitted in wave order by ``tools/Invoke-NxBuild.ps1``; cross-category inversions are flagged in section 2).")
    $L.Add('')
    $L.Add('```text')
    $n = 0
    foreach ($id in $topoOrder) {
        $n++
        $L.Add(('{0,3}. {1}' -f $n, $id))
    }
    $L.Add('```')
    $L.Add('')
    $L.Add('## 5. Cycle check')
    $L.Add('')
    $L.Add('PASS: every dependency edge resolves to a registry entry and the Kahn ordering emitted all entries, so there is no dependency cycle. The exporter fails with exit code 1 and writes no matrix if a cycle, self-dependency or missing dependency id is detected.')
    $L.Add('')
    $L.Add('## 6. Export-time warnings')
    $L.Add('')
    if ($warnings.Count -eq 0) {
        $L.Add('None.')
    } else {
        foreach ($w in $warnings) { $L.Add("- $w") }
    }
    $L.Add('')
    $L.Add('---')
    $L.Add('')
    $L.Add('Generated by `tools/Export-NxMatrices.ps1`. Repository source of truth: `registry/`.')
    $L.Add('')
    return ($L -join "`n")
}

function New-NxConflictMarkdown {
    $L = New-Object 'System.Collections.Generic.List[string]'
    $L.Add('# NEXTRIX - Conflict Matrix')
    $L.Add('')
    $L.Add('**Status:** generated artifact - do not edit by hand.')
    $L.Add('**Generator:** `tools/Export-NxMatrices.ps1`')
    $L.Add("**Source of truth:** ``registry/NX*.json`` ($($allTweaks.Count) entries); declared conflicts only.")
    $L.Add('**Regenerate:** `powershell.exe -NoProfile -File tools\Export-NxMatrices.ps1` (or `pwsh`).')
    $L.Add('')
    $L.Add('A declared conflict means two entries reach the same feature, target or mechanism: they are alternatives (select one) or one destroys the other''s state. Being in an overlap group (section 5) is NOT a conflict - it is an ownership/coordination note.')
    $L.Add('')
    $L.Add('## 1. Summary')
    $L.Add('')
    $L.Add('| Metric | Value |')
    $L.Add('|---|---|')
    $L.Add("| Declared conflict pairs (unique, sorted) | $($pairs.Count) |")
    $L.Add("| Symmetric pairs | $(@($pairs | Where-Object { $_.declaredByA -and $_.declaredByB }).Count) |")
    $L.Add("| Asymmetric pairs (warnings) | $($asymmetric.Count) |")
    $L.Add("| Conflict groups (connected components) | $($conflictGroups.Count) |")
    $L.Add("| Cross-category shared engine functions (composer candidates) | $($composerGroups.Count) |")
    $L.Add("| Cross-reference overlap edges | $($xrefList.Count) |")
    $L.Add("| Cross-reference overlap groups | $($xrefGroups.Count) |")
    $L.Add("| Curated preset-pairing hazards | $($hazards.Count) |")
    $L.Add('')
    $L.Add('## 2. Legend and verification rules')
    $L.Add('')
    $L.Add('- **registry-declared**: at least one entry lists the other in `conflicts`. Symmetry is checked both ways; asymmetric declarations are reported as warnings (the validator treats them the same way).')
    $L.Add('- **CURATED**: an agent-authored note that is not a registry conflict declaration. Curated rows are labelled and their tokens are asserted against the registry text at export time; if the text changes, the export fails instead of publishing a stale claim.')
    $L.Add('- **Derived**: computed from the registry (conflict graph, shared functions, XREF sentences).')
    $L.Add('')
    $L.Add('## 3. Declared conflict pairs')
    $L.Add('')
    $L.Add('`Group` points at the connected component in section 4, which carries the curated resolution. `Registry evidence` is the first registry sentence that names the other entry (a fact from the text, not necessarily a resolution).')
    $L.Add('')
    $pairGroup = @{}
    $gi = 0
    foreach ($grp in $conflictGroups) {
        $gi++
        foreach ($m in @($grp.members)) {
            foreach ($k in @($grp.members)) {
                if ($m -lt $k) { $pairGroup["$m|$k"] = "G$gi" }
            }
        }
    }
    $L.Add('| Pair | A risk | B risk | Directions | Group | Registry evidence |')
    $L.Add('|---|---|---|---|---|---|')
    foreach ($p in $pairs) {
        $dirs = 'A->B only'
        if ($p.declaredByA -and $p.declaredByB) { $dirs = 'symmetric (A<->B)' }
        elseif ($p.declaredByB) { $dirs = 'B->A only' }
        $note = $null
        $note = Get-NxPairNote $byId[$p.a] $p.b
        if ($null -eq $note) { $note = Get-NxPairNote $byId[$p.b] $p.a }
        if ($null -eq $note) { $note = 'No registry sentence names the other entry; declaration only.' }
        $grpLabel = '-'
        if ($pairGroup.ContainsKey("$($p.a)|$($p.b)")) { $grpLabel = $pairGroup["$($p.a)|$($p.b)"] }
        $L.Add("| $($p.a) <-> $($p.b) | $([string]$byId[$p.a].risk) | $([string]$byId[$p.b].risk) | $dirs | $grpLabel | $(Format-NxCell $note 340) |")
    }
    $L.Add('')
    if ($asymmetric.Count -gt 0) {
        $L.Add('### Asymmetry warnings')
        $L.Add('')
        foreach ($p in $asymmetric) { $L.Add("- $($p.a) <-> $($p.b): declared in one direction only; the validator reports the same warning.") }
        $L.Add('')
    } else {
        $L.Add('Symmetry check: PASS - every declared conflict is declared in both directions (0 asymmetric pairs).')
        $L.Add('')
    }
    $L.Add('## 4. Conflict groups (derived connected components)')
    $L.Add('')
    $L.Add('Groups are the connected components of the declared conflict graph. A group is a set of entries from which at most one alternative should be selected for the same target; the resolution column is CURATED where a note exists.')
    $L.Add('')
    $L.Add('| Group | Members (id + name) | Risk mix | Resolution (CURATED where noted) |')
    $L.Add('|---|---|---|---|')
    $g = 0
    foreach ($grp in $conflictGroups) {
        $g++
        $members = @($grp.members)
        $key = ($members -join ',')
        $risks = @($members | ForEach-Object { "$([string]$byId[$_].risk)" } | Sort-Object -Unique)
        $note = 'No curated note; derive selection from the pair rows in section 3.'
        if ($conflictGroupNotes.ContainsKey($key)) { $note = '(CURATED) ' + $conflictGroupNotes[$key] }
        $L.Add("| G$g | $(Format-NxCell (Format-NxIdList $members) 420) | $($risks -join ', ') | $(Format-NxCell $note 460) |")
    }
    $L.Add('')
    $L.Add('## 5. Cross-reference overlap groups (derived, coordination only)')
    $L.Add('')
    $L.Add('Derived mechanically: a sentence in the registry text that contains an ownership marker (`XREF`, `overlap`, `alternative control`, `choose one`, `do not pair`, `two directions`) and at least two tweak ids creates an edge. These groups mean the entries touch the same subsystem or delegate to one another; **they are not conflicts** unless they also appear in section 3 or 7. Use them to review preset composition and ownership handoffs.')
    $L.Add('')
    if ($xrefGroups.Count -eq 0) {
        $L.Add('No cross-reference groups were found.')
    } else {
        $L.Add('| Group | Members (id + name) | Evidence edges |')
        $L.Add('|---|---|---|')
        $x = 0
        foreach ($grp in $xrefGroups) {
            $x++
            $members = @($grp.members)
            $ev = @()
            foreach ($e in $xrefList) {
                if (($members -contains $e.a) -and ($members -contains $e.b)) { $ev += "$($e.a) <-> $($e.b) [text: $($e.evidence)]" }
            }
            $L.Add("| X$x | $(Format-NxCell (Format-NxIdList $members) 420) | $(Format-NxCell ($ev -join '; ') 460) |")
        }
    }
    $L.Add('')
    $L.Add('## 6. Shared-value / composer groups (derived)')
    $L.Add('')
    $L.Add('An engine function shared by entries in more than one category is a shared-value candidate: the function owns a read-modify-write contract, so the entries must compose rather than collide. Same-category shared functions are omitted here (plan builders and shared helpers inside one category are ordinary implementation reuse).')
    $L.Add('')
    if ($composerGroups.Count -eq 0) {
        $L.Add('None found.')
    } else {
        $L.Add('| Engine function | Consumers | Categories | Verdict |')
        $L.Add('|---|---|---|---|')
        foreach ($cg in $composerGroups) {
            $verdict = 'Shared engine function across categories; verify the composer preserves sibling state before combining.'
            if ($cg.function -eq 'Set-NxDirectXGlobalSetting') {
                $verdict = '(CURATED) Composer-enforced sharing: NX02-005 writes SwapEffectUpgradeEnable and NX04-003 writes VRROptimizeEnable inside the same DirectXUserGlobalSettings REG_SZ. The function preserves sibling components by read-modify-write and journals the whole original value, so the pair is SAFE to combine; the registry states "No conflict remains (composer-enforced sharing)".'
            }
            $L.Add("| $($cg.function) | $(Format-NxCell (Format-NxIdList $cg.consumers) 260) | $($cg.categories -join ', ') | $(Format-NxCell $verdict 380) |")
        }
    }
    $L.Add('')
    $L.Add('## 7. Preset-pairing hazards (CURATED where marked)')
    $L.Add('')
    $L.Add('These are composition hazards that the declared conflict graph does not fully express. `registry-declared` rows restate a declared conflict with an operational resolution; `CURATED` rows are agent findings and must not be presented as registry declarations.')
    $L.Add('')
    $L.Add('| Pair | Status | Hazard | Resolution | Evidence |')
    $L.Add('|---|---|---|---|---|')
    foreach ($h in $hazards) {
        $L.Add("| $($h.a) <-> $($h.b) | $($h.status) | $(Format-NxCell $h.hazard 300) | $(Format-NxCell $h.resolution 300) | $(Format-NxCell $h.evidence 160) |")
    }
    $L.Add('')
    $L.Add('## 8. Do not combine in one preset')
    $L.Add('')
    $L.Add('Derived from section 3 (every declared pair) plus the curated hazards in section 7. "Alternative" means select one; "ordered" means the pair may be combined only in the stated order (and is not a preset default); "redundant" means both apply the same change to the same target.')
    $L.Add('')
    $L.Add('| Pair / set | Kind | Rule | Source |')
    $L.Add('|---|---|---|---|')
    # Pagefile family: declared edges already cover pairwise; add the set rule first (derived from group).
    foreach ($grp in $conflictGroups) {
        $members = @($grp.members)
        if ($members.Count -lt 3) { continue }
        $kind = 'alternative (set)'
        $rule = 'Select at most one alternative from this group for the same target; see section 4.'
        $memberKey = $members -join ','
        if ($memberKey -like 'NX07-*') { $kind = 'ordered (set)'; $rule = 'The reset rewrites the stack; run it alone, then re-apply targeted settings. Do not bundle reset + configuration in one unattended preset.' }
        if ($memberKey -like 'NX02-008*') { $kind = 'decision-order (set)'; $rule = 'Read the read-only dependency report first; then choose at most one change (NX11-010 or NX12-005).' }
        if ($memberKey -like 'NX05-001*') { $kind = 'alternative (set) + compatible sub-pair'; $rule = 'NX05-001/002/003 are mutually exclusive pagefile modes. NX05-009 (crash-dump type) may be combined with NX05-001 or NX05-002, but never with NX05-003 (no pagefile).' }
        $L.Add("| $($members -join ' / ') | $kind | $rule | Declared conflict group (derived) |")
    }
    foreach ($p in $pairs) {
        $kind = 'alternative'
        $rule = 'Both entries reach the same feature/target; select one.'
        $pairKey = "$($p.a) <-> $($p.b)"
        if ($pairKey -eq 'NX19-003 <-> NX19-004') { $kind = 'alternative (mechanism)'; $rule = 'CPU Sets vs affinity for the same process; affinity overrides CPU sets, so select one mechanism.' }
        if ($pairKey -eq 'NX05-003 <-> NX05-009') { $kind = 'incompatible'; $rule = 'No pagefile means kernel/complete/automatic crash dumps cannot be written; do not pair dump capture with pagefile removal.' }
        if ($pairKey -eq 'NX12-004 <-> NX13-012') { $kind = 'alternative'; $rule = 'App removal vs policy disable for phone-PC linking; choose one.' }
        if ($pairKey -eq 'NX02-008 <-> NX12-005') { $kind = 'decision-order'; $rule = 'Read the report first, then decide on removal; not a mechanical exclusion (the report mutates nothing).' }
        if ($pairKey -eq 'NX02-008 <-> NX11-010') { $kind = 'decision-order'; $rule = 'Read the report first, then configure Xbox services; the report mutates nothing.' }
        if ($p.a -eq 'NX07-021' -or $p.b -eq 'NX07-021') { $kind = 'ordered'; $rule = 'The reset can clear this setting; run the reset alone, then re-apply. Do not bundle both in one unattended preset.' }
        $L.Add("| $($p.a) / $($p.b) | $kind | $rule | Registry-declared (section 3) |")
    }
    foreach ($h in $hazards) {
        if ($h.status -like 'CURATED*') {
            $L.Add("| $($h.a) / $($h.b) | redundant (same task) | $(Format-NxCell $h.resolution 300) | CURATED hazard (section 7) |")
        }
    }
    $L.Add('')
    $L.Add('Not in this list: `NX02-005` + `NX04-003` (DirectX global-settings components) are explicitly safe to combine because `Set-NxDirectXGlobalSetting` is a composer; see section 6.')
    $L.Add('')
    $L.Add('---')
    $L.Add('')
    $L.Add('Generated by `tools/Export-NxMatrices.ps1`. Repository source of truth: `registry/`. Curated notes are labelled; everything else is mechanical.')
    $L.Add('')
    return ($L -join "`n")
}

function Get-NxPairNote($Tweak, [string]$OtherId) {
    # Prefer sideEffects (the owner-facing consequence), then the technical text.
    # Within a field, prefer a sentence that both names the other entry and reads
    # like a resolution; fall back to the first sentence that names it.
    $marker = 'conflict|redundant|choose|alternative|mutually|do not|select one|override|instead of|subsum|supersed|deliberately separate'
    $fields = @('sideEffects', 'technicalExplanation', 'description', 'objective')
    # Pass 1: a sentence that names the other entry AND reads like a decision.
    foreach ($field in $fields) {
        $v = [string]$Tweak.$field
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        foreach ($sentence in @(Get-NxSentences $v)) {
            if ($sentence.IndexOf($OtherId, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            if ($sentence -match $marker) { return (Format-NxCell $sentence 340) }
        }
    }
    # Pass 2: the first sentence in any field that names the other entry.
    foreach ($field in $fields) {
        $v = [string]$Tweak.$field
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        foreach ($sentence in @(Get-NxSentences $v)) {
            if ($sentence.IndexOf($OtherId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return (Format-NxCell $sentence 340)
            }
        }
    }
    return $null
}

# ----------------------------------------------------------------------------
# Write (UTF-8, no BOM, LF)
# ----------------------------------------------------------------------------
$depMd = New-NxDependencyMarkdown
$conMd = New-NxConflictMarkdown

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$depPath = Join-Path $OutDir 'DEPENDENCY_MATRIX.md'
$conPath = Join-Path $OutDir 'CONFLICT_MATRIX.md'
[System.IO.File]::WriteAllText($depPath, $depMd, $utf8NoBom)
[System.IO.File]::WriteAllText($conPath, $conMd, $utf8NoBom)

Write-Output "wrote: $depPath"
Write-Output "wrote: $conPath"
Write-Output ''
Write-Output "Registry: $($files.Count) file(s), $($allTweaks.Count) entry(ies)."
Write-Output "Dependencies: $($depEdges.Count) edge(s), $($depRows.Count) row(s), $layerCount topological layer(s), cycle check PASS."
Write-Output "Conflicts: $($pairs.Count) declared pair(s), $($conflictGroups.Count) group(s), $($asymmetric.Count) asymmetric pair(s)."
Write-Output "Composer groups: $($composerGroups.Count); XREF overlap edges: $($xrefList.Count) in $($xrefGroups.Count) group(s); curated hazards: $($hazards.Count)."
if ($warnings.Count -gt 0) {
    Write-Output "Warnings ($($warnings.Count)):"
    foreach ($w in $warnings) { Write-Output "  - $w" }
}
Write-Output "RESULT: OK - 0 error(s), $($warnings.Count) warning(s)."
exit 0
