#Requires -Version 5.1
<#
    Invoke-NxBuild.ps1 - NEXTRIX playbook generator (registry -> AME Wizard playbook source).

    Ownership: workstream W1-B. Owns tools/Invoke-NxBuild.ps1 and the generated
    playbook/ tree. The registry is authored by other workstreams; this generator
    handles any subset of registry/NX*.json gracefully and fails loudly on
    obviously invalid input (same rule families as tools/Test-NxRegistry.ps1:
    required fields, enums, banned targets - NOT the full validator).

    Output (all deterministic, sorted, stable; regeneration overwrites cleanly):

      playbook.conf                      AME Wizard XML metadata. Fixed identity
                                         (hardcoded UUIDv4 generated once),
                                         SupportedBuilds 22631/26100/26200/26300,
                                         Requirements Internet+PluggedIn ONLY
                                         (ADR-006: never DefenderToggled/NoAntivirus/
                                         UCPDDisabled), UseKernelDriver false,
                                         Overhaul false, honest no-claims texts.
      Configuration/main.yml             entry point: pre-flight FIRST, per-category
                                         task files in wave order (NX16 first),
                                         completion status last.
      Configuration/Tasks/nxcore.yml     unconditional pre-flight (!powerShell
                                         Invoke-NxPreFlight, errorAction Halt -
                                         capture-completeness gate, ADR-006).
      Configuration/Tasks/<cat>.yml      one per registry NX*.json. Every selectable
                                         tweak is a wizard checkbox option (option
                                         name = lowercase tweak id; presetExcluded
                                         entries default UNCHECKED - mechanical).
                                         Function actions -> !powerShell of the
                                         engine function (errorAction Notify);
                                         registry actions -> journaled !powerShell
                                         (Invoke-NxRegistryTweak: capture ->
                                         journal -> apply -> verify -> journal).
      (no rollback task file)            rollback is CLI-only: Invoke-NxRollback
                                         through the bundled NxCore. The playbook
                                         platform has no uninstall (ADR-006) and
                                         the wizard deliberately has no undo page.
      Executables/nxcore-manifest.json   what packaging must bundle (with SHA256 pins):
                                         src/nxcore/**/*.ps1 plus the NX18 session
                                         subsystem (src/nxsession/NX18.ps1). The
                                         packaging tool stages them into
                                         Executables/NxCore/ + NxCoreBootstrap.ps1
                                         (flat task loader unchanged). The generator
                                         does NOT copy binaries.

    Routing rules (mechanical, with reasons):
      - apply actions whose function is Invoke-NxPreFlight are NOT user options;
        they are the mandatory pre-flight (no mutation without verified capture).
      - apply actions whose function is Invoke-NxRollback are NOT per-category
        options; rollback is a CLI-only operation and is never emitted as a
        wizard option or a playbook task.

    Safety: static text generation only. This script never executes the generated
    playbook, never downloads anything, and never mutates the host beyond writing
    text files under -OutDir.

    Exit codes: 0 = generated (or dry run) OK; 1 = input validation failed.
#>
[CmdletBinding()]
param(
    [string]$RegistryDir,
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$OutDir,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Defaults resolved in the script body: $PSScriptRoot is not available inside
# param() default expressions on Windows PowerShell 5.1.
if ([string]::IsNullOrWhiteSpace($RegistryDir)) { $RegistryDir = Join-Path $PSScriptRoot '..\registry' }
if ([string]::IsNullOrWhiteSpace($OutDir))     { $OutDir = Join-Path $PSScriptRoot '..\playbook' }

# ----------------------------------------------------------------------------
# Fixed identity and policy constants
# ----------------------------------------------------------------------------
$NxName              = 'NEXTRIX'
# UUIDv4 generated once (2026-11-23) and hardcoded. AME deserializes UniqueId as a
# GUID, so it must be a real UUIDv4; change deliberately, never per-run.
$NxUniqueId         = '8550805b-2928-46a0-8daf-2e1732b55421'
$NxSupportedBuilds  = @('22631', '26100', '26200', '26300')   # 23H2/24H2/25H2/26H2 (ADR-003)
$NxBuildDefaultMin  = 22631
$NxBuildDefaultMax  = 26300
$NxWaveFirst        = 'NX16'           # recovery substrate first (wave order)
$NxPreflightFn      = 'Invoke-NxPreFlight'
$NxRollbackFn       = 'Invoke-NxRollback'
$NxGitUrl           = 'https://github.com/Goku-py/NEXTRIX'    # placeholder update channel (ADR-007)
$NxJournalDirArg    = '(Join-Path $env:ProgramData ''NEXTRIX\Journal'')'
# NxCore loader preamble: dot-source every bundled module from the playbook
# Executables dir (exeDir: true). The foreach STATEMENT form runs in the current
# scope, so function definitions persist. Verified on Windows PowerShell 5.1.
$NxLoaderLine       = 'foreach ($m in (Get-ChildItem -LiteralPath . -Filter ''Nx*.ps1'' -File | Sort-Object -Property Name)) { . $m.FullName }'
# Canonical rollback scope names, retained for CLI documentation and reporting
# only: rollback is not an install-time surface (no wizard page, no task file).
$NxRollbackScopes   = @(
    @{ key = 'tweakid';  option = 'nx-rollback-tweakid';  param = 'tweakId'; fallback = '<tweak>'; label = 'Undo ONE tweak' },
    @{ key = 'category'; option = 'nx-rollback-category'; param = 'category'; fallback = '<NXcc>';  label = 'Undo ONE category' },
    @{ key = 'profile';  option = 'nx-rollback-profile';  param = 'profile';  fallback = '<Pn>';    label = 'Undo ONE profile' },
    @{ key = 'all';      option = 'nx-rollback-all';      param = 'all';      fallback = $true;      label = 'Undo ALL journaled NEXTRIX changes' }
)
# Registry action kinds that can be routed through Invoke-NxRegistryTweak
# (src/nxcore/NxApply.ps1). Binary/MultiString have no lossless command-line
# encoding and are refused by design: such entries must ship as dedicated
# functions. Key = lowercase, value = canonical RegistryValueKind name.
$NxJournaledKinds    = @{
    dword = 'DWord'; qword = 'QWord'; string = 'String'; expandstring = 'ExpandString'
}

$errors   = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

# ----------------------------------------------------------------------------
# Small helpers (PowerShell 5.1 compatible)
# ----------------------------------------------------------------------------
function Test-NxProp($Object, [string]$Name) {
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function ConvertTo-NxXmlText([string]$Text) {
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function ConvertTo-NxXmlAttr([string]$Text) {
    $t = ConvertTo-NxXmlText $Text
    return $t.Replace('"', '&quot;').Replace("'", '&apos;')
}

function ConvertTo-NxYq([string]$Text) {
    # single-quoted YAML scalar with '' escaping; safe for any content.
    if ($null -eq $Text) { return "''" }
    return "'" + $Text.Replace("'", "''") + "'"
}

function Get-NxAmeBuildsGate($Builds) {
    # Registry builds {min,max,excluded} -> AME per-action builds gate entries.
    # Emits ONLY where tighter than the playbook-wide default (non-default rule).
    $gate = @()
    if ($null -eq $Builds) { return $gate }
    $min = $script:NxBuildDefaultMin
    $max = $script:NxBuildDefaultMax
    if (Test-NxProp $Builds 'min') { $min = [int]$Builds.min }
    if (Test-NxProp $Builds 'max') { $max = [int]$Builds.max }
    if ($min -gt $script:NxBuildDefaultMin) { $gate += (">=" + $min) }
    if ($max -lt $script:NxBuildDefaultMax) { $gate += ("!>" + $max) }
    if (Test-NxProp $Builds 'excluded') {
        foreach ($e in @($Builds.excluded | Sort-Object)) { $gate += ("!" + $e) }
    }
    # Unary comma: an empty gate array must reach the caller as an array (not $null).
    return ,$gate
}

function ConvertTo-NxYamlFlowStrings($Items) {
    $parts = @()
    foreach ($i in @($Items)) { $parts += (ConvertTo-NxYq ([string]$i)) }
    return ('[' + ($parts -join ', ') + ']')
}

# ----------------------------------------------------------------------------
# Engine inventory: AST-parse every runtime module to learn each function's
# parameter names, switch parameters and journal-root contract.
# Sources: src/nxcore/**/*.ps1 (core + category functions) and the NX18 session
# subsystem at src/nxsession/NX18.ps1 (it lives outside src/nxcore; KNOWN_ISSUES 16).
# The task loader stays FLAT by decision (Executables/*.ps1, no recursion): the
# Phase-6 packaging tool (tools/New-NxPackage.ps1) stages the engine into
# Executables/NxCore/ and emits Executables/NxCoreBootstrap.ps1, which the flat
# loader picks up and which loads the NxCore tree (NX18 included) in order.
# ----------------------------------------------------------------------------
function Get-NxEngineFileList([string]$RepoRoot) {
    # Returns engine sources as @{ full = <absolute path>; source = <repo-relative path> }.
    $list = @()
    $coreRoot = Join-Path $RepoRoot 'src\nxcore'
    if (Test-Path -LiteralPath $coreRoot) {
        $root = $coreRoot.TrimEnd('\')
        foreach ($f in @(Get-ChildItem -LiteralPath $coreRoot -Filter '*.ps1' -File -Recurse | Sort-Object -Property FullName)) {
            $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
            $list += @{ full = $f.FullName; source = ('src/nxcore/' + $rel) }
        }
    }
    $sessionModule = Join-Path (Join-Path $RepoRoot 'src\nxsession') 'NX18.ps1'
    if (Test-Path -LiteralPath $sessionModule) {
        $list += @{ full = $sessionModule; source = 'src/nxsession/NX18.ps1' }
    }
    # Unary comma: an empty list must reach the caller as an array (not $null).
    return ,$list
}

function Get-NxCoreInventory($EngineFiles) {
    $inv = @{}
    foreach ($ef in @($EngineFiles)) {
        $rel = [string]$ef.source
        $tokens = $null; $parseErrors = $null
        $ast = $null
        try {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile([string]$ef.full, [ref]$tokens, [ref]$parseErrors)
        } catch {
            $script:warnings.Add("${rel}: could not parse module (skipped for function inventory): $($_.Exception.Message)")
            continue
        }
        if ($parseErrors -and @($parseErrors).Count -gt 0) {
            $script:warnings.Add("${rel}: parse error (skipped for function inventory): $($(@($parseErrors)[0]).Message)")
            continue
        }
        $defs = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($fn in $defs) {
            $params = @{}
            if ($null -ne $fn.Body.ParamBlock) {
                foreach ($p in $fn.Body.ParamBlock.Parameters) {
                    $isSwitch = $false
                    foreach ($attr in $p.Attributes) {
                        if ($attr -is [System.Management.Automation.Language.TypeConstraintAst] -and $attr.TypeName.Name -eq 'switch') { $isSwitch = $true }
                    }
                    $declared = $p.Name.VariablePath.UserPath
                    $params[$declared.ToLowerInvariant()] = @{ isSwitch = $isSwitch; declaredName = $declared }
                }
            }
            $inv[$fn.Name] = @{ source = $rel; params = $params }
        }
    }
    return $inv
}

function Format-NxArgument([string]$PsName, $Value) {
    if ($Value -is [bool]) {
        # colon-attached form is valid for switch AND typed bool parameters
        if ($Value) { return ("-$PsName" + ':$true') }
        return ("-$PsName" + ':$false')
    }
    if ($Value -is [array]) {
        # PowerShell array argument: -Profiles 'P1','P2','P3'
        $parts = @()
        foreach ($v in $Value) {
            if ($v -is [bool]) { if ($v) { $parts += '$true' } else { $parts += '$false' } }
            elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) { $parts += [string]$v }
            else { $parts += (ConvertTo-NxYq ([string]$v)) }
        }
        return ("-$PsName " + ($parts -join ','))
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return ("-$PsName " + [string]$Value) }
    return ("-$PsName " + (ConvertTo-NxYq ([string]$Value)))
}

function Get-NxParameterArguments([string]$FunctionName, $Parameters, $Inventory, [string]$ApprovalModel) {
    # Translates a registry action's declared parameters into PowerShell call
    # arguments. Two engine-wide contracts are supplied here, neither of which is
    # a per-tweak parameter:
    #   1. Journal location: whenever the function declares JournalRoot/JournalPath,
    #      the NEXTRIX journal root is passed (journal-first invariant, ADR-006).
    #   2. Approval evidence: for user-selected tweaks the wizard checkbox IS the
    #      explicit approval event. Mutating engine functions refuse to apply
    #      without -Approved, and the journal records the registry's declared
    #      approval model via -Approval (mirrors Invoke-NxApply semantics).
    $known = $Inventory.ContainsKey($FunctionName)
    $fnParams = @{}
    if ($known) { $fnParams = $Inventory[$FunctionName].params }

    $outArgs = @()
    $passesJournal = $false
    $passesApproved = $false
    $passesApproval = $false
    if ($null -ne $Parameters) {
        foreach ($prop in $Parameters.PSObject.Properties) {
            $rawName = [string]$prop.Name
            $psName = $rawName.Substring(0, 1).ToUpperInvariant() + $rawName.Substring(1)
            $lower = $rawName.ToLowerInvariant()
            if ($lower -eq 'journalroot' -or $lower -eq 'journalpath') { $passesJournal = $true }
            if ($lower -eq 'approved') { $passesApproved = $true }
            if ($lower -eq 'approval') { $passesApproval = $true }
            $val = $prop.Value
            if (($val -is [bool]) -and $fnParams.ContainsKey($lower) -and $fnParams[$lower].isSwitch) {
                if ($val) { $outArgs += ("-$psName") }       # bare switch
                # a switch declared false is simply omitted
                continue
            }
            if ($known -and -not $fnParams.ContainsKey($lower)) {
                $script:warnings.Add("${FunctionName}: registry parameter '$rawName' is not declared by the function in src/nxcore (signature drift; concurrent authoring?) - emitted verbatim")
            }
            $outArgs += (Format-NxArgument $psName $val)
        }
    }
    if ($known -and -not $passesJournal) {
        $journalName = $null
        foreach ($cand in @('journalroot', 'journalpath')) {
            if ($fnParams.ContainsKey($cand)) { $journalName = $fnParams[$cand].declaredName; break }
        }
        if ($null -ne $journalName) {
            $outArgs += ("-$journalName " + $script:NxJournalDirArg)
        }
    }
    if ($known -and -not [string]::IsNullOrWhiteSpace($ApprovalModel)) {
        if ($fnParams.ContainsKey('approved') -and $fnParams['approved'].isSwitch -and -not $passesApproved) {
            $outArgs += '-Approved'
        }
        if ($fnParams.ContainsKey('approval') -and -not $passesApproval) {
            $approvalName = $fnParams['approval'].declaredName
            $outArgs += ("-$approvalName " + (ConvertTo-NxYq $ApprovalModel))
        }
    }
    return ($outArgs -join ' ')
}

# ----------------------------------------------------------------------------
# Ordering helpers
# ----------------------------------------------------------------------------
function Get-NxWaveKey([string]$Category) {
    if ($Category -eq $script:NxWaveFirst) { return '0-' + $Category }
    if ($Category -match '^NX(\d{2})$') { return '1-' + $Matches[1] }
    return '2-' + $Category   # unknown-shape category names sort last, deterministically
}

function Get-NxStableDependencyOrder($Tweaks) {
    # Stable topological order within one category: repeatedly pick the first
    # tweak (in original file order) whose same-file dependencies are all
    # emitted. Cross-category dependencies are the wave order's concern.
    $ordered = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Tweaks) { $pending.Add($t) }
    $guard = 0
    while ($pending.Count -gt 0) {
        $picked = -1
        for ($i = 0; $i -lt $pending.Count; $i++) {
            $t = $pending[$i]
            $depsOk = $true
            foreach ($d in @($t.dependencies)) {
                if ([string]::IsNullOrWhiteSpace([string]$d)) { continue }
                $emitted = $false
                foreach ($o in $ordered) { if ([string]$o.id -eq [string]$d) { $emitted = $true; break } }
                if (-not $emitted) {
                    # same-file dependency not yet emitted -> blocks this tweak
                    $inPending = $false
                    for ($j = 0; $j -lt $pending.Count; $j++) {
                        if ([string]$pending[$j].id -eq [string]$d) { $inPending = $true; break }
                    }
                    if ($inPending) { $depsOk = $false; break }
                }
            }
            if ($depsOk) { $picked = $i; break }
        }
        if ($picked -lt 0) {
            $script:warnings.Add("category $($Tweaks[0].category): dependency order unsatisfiable within the file (cycle or forward-only reference); remaining tweak(s) emitted in registry file order")
            foreach ($t in $pending) { $ordered.Add($t) }
            break
        }
        $ordered.Add($pending[$picked])
        $pending.RemoveAt($picked)
        $guard++
        if ($guard -gt 10000) { break }
    }
    # NOTE: Windows PowerShell 5.1 throws "Argument types do not match" for
    # @($list) over a generic List[object] holding PSCustomObjects; ToArray() is
    # the safe conversion.
    return $ordered.ToArray()
}

# ----------------------------------------------------------------------------
# Resolve inputs
# ----------------------------------------------------------------------------
$repoRoot = (Split-Path $PSScriptRoot -Parent)
if (-not [System.IO.Path]::IsPathRooted($RegistryDir)) { $RegistryDir = Join-Path (Get-Location).Path $RegistryDir }
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path (Get-Location).Path $OutDir }
$nxCoreDir = Join-Path $repoRoot 'src\nxcore'
# Engine sources for inventory + manifest hash pins: src/nxcore/**/*.ps1 plus
# the NX18 session subsystem (outside src/nxcore; staged to NxCore/ by packaging).
$engineFiles = Get-NxEngineFileList $repoRoot

if ($Version -notmatch '^\d+(\.\d+){0,2}$') {
    Write-Output "FATAL: -Version '$Version' is not a plain version number (AME accepts 1 / 0.1 / 0.0.1)."
    exit 1
}
$fullOutPath = [System.IO.Path]::GetFullPath($OutDir)
if ($fullOutPath.TrimEnd('\') -match '^[A-Za-z]:$') {
    Write-Output "FATAL: -OutDir refuses a drive root ('$fullOutPath')."
    exit 1
}

$schemaPath = Join-Path $RegistryDir 'schema.json'
if (-not (Test-Path -LiteralPath $RegistryDir)) { Write-Output "FATAL: registry directory not found: $RegistryDir"; exit 1 }
if (-not (Test-Path -LiteralPath $schemaPath))   { Write-Output "FATAL: schema.json not found in $RegistryDir"; exit 1 }

try { $schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Write-Output "FATAL: schema.json is not valid JSON: $($_.Exception.Message)"; exit 1 }

$regFiles = @(Get-ChildItem -LiteralPath $RegistryDir -Filter 'NX*.json' -File | Sort-Object -Property Name)
if ($regFiles.Count -eq 0) { Write-Output "FATAL: no registry/NX*.json files found in $RegistryDir"; exit 1 }

# ----------------------------------------------------------------------------
# Load + validate (fail-loud subset; the full validator is Test-NxRegistry.ps1)
# ----------------------------------------------------------------------------
$enumChecks = @{
    risk = $schema.riskClasses; evidence = $schema.evidenceLevels; status = $schema.statuses
    kind = $schema.kinds; modificationType = $schema.modificationTypes
    privileges = $schema.privileges; restart = $schema.restartRequirements; approval = $schema.approvalModels
}

$categories = @()
foreach ($f in $regFiles) {
    $cat = $null
    try { $cat = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $errors.Add("file $($f.Name): invalid JSON - $($_.Exception.Message)"); continue }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    if (-not (Test-NxProp $cat 'category')) { $errors.Add("file $($f.Name): missing 'category' field"); continue }
    if ([string]$cat.category -ne $stem) {
        $errors.Add("file $($f.Name): category '$($cat.category)' does not match file stem '$stem'")
    }
    if (-not (Test-NxProp $cat 'categoryName')) { $errors.Add("file $($f.Name): missing 'categoryName' field") }
    if ((Test-NxProp $cat 'schemaVersion') -and ($cat.schemaVersion -ne $schema.schemaVersion)) {
        $warnings.Add("file $($f.Name): schemaVersion $($cat.schemaVersion) differs from schema.json $($schema.schemaVersion) (forward-compat note)")
    }
    if (-not (Test-NxProp $cat 'tweaks')) { $errors.Add("file $($f.Name): no tweaks array"); continue }
    $tweaks = @($cat.tweaks)
    if ($tweaks.Count -eq 0) { $errors.Add("file $($f.Name): tweaks array is empty"); continue }

    $categories += @{
        name = $stem; file = $f.Name; path = $f.FullName
        categoryName = [string]$cat.categoryName
        tweaks = $tweaks
        sortKey = Get-NxWaveKey $stem
    }
}

# de-duplicated id -> category map (for cross-file checks)
$idToCategory = @{}
$allTweaks = @()
foreach ($c in $categories) {
    foreach ($t in $c.tweaks) { $allTweaks += $t }
}
foreach ($t in $allTweaks) {
    if (Test-NxProp $t 'id') { $idToCategory[[string]$t.id] = $t.category }
}

foreach ($c in $categories) {
    foreach ($t in $c.tweaks) {
        $tid = ''
        if (Test-NxProp $t 'id') { $tid = [string]$t.id } else { $tid = '<no-id>' }

        # required fields
        foreach ($rf in $schema.requiredFields) {
            if (-not (Test-NxProp $t $rf)) { $errors.Add("${tid}: missing required field '$rf'") }
        }
        # enums
        foreach ($k in $enumChecks.Keys) {
            $v = $null
            if (Test-NxProp $t $k) { $v = $t.$k }
            if ($v -and (@($enumChecks[$k]) -notcontains $v)) {
                $errors.Add("${tid}: '$k' value '$v' not in schema enum")
            }
        }
        # id pattern + category consistency
        if ($tid -ne '<no-id>') {
            if ($tid -notmatch $schema.idPattern) { $errors.Add("${tid}: id does not match pattern") }
            if ((Test-NxProp $t 'category') -and ($tid.Length -ge 4) -and ($tid.Substring(0, 4) -ne [string]$t.category)) {
                $errors.Add("${tid}: category '$($t.category)' does not match id prefix")
            }
        }
        # build ranges (ADR-003)
        if ((Test-NxProp $t 'builds') -and ($null -ne $t.builds)) {
            if ([int]$t.builds.min -lt [int]$schema.supportedBuildRange.min -or [int]$t.builds.max -gt [int]$schema.supportedBuildRange.max) {
                $errors.Add("${tid}: build range $($t.builds.min)..$($t.builds.max) outside ADR-003 scope")
            }
            if ([int]$t.builds.min -gt [int]$t.builds.max) { $errors.Add("${tid}: builds min > max") }
        }
        # preset-exclusion policy (mechanical)
        if ((Test-NxProp $t 'presetExcluded')) {
            if (@('EXPERIMENTAL', 'TROUBLESHOOTING') -contains $t.risk -and -not $t.presetExcluded) {
                $errors.Add("${tid}: risk '$($t.risk)' must be presetExcluded=true")
            }
            if ($t.risk -eq 'ADVANCED' -and -not $t.presetExcluded -and [string]$t.approval -ne 'ExplicitConsent') {
                $errors.Add("${tid}: ADVANCED risk must be presetExcluded or require ExplicitConsent")
            }
        }
        # status sanity
        if (@('Defined', 'Implemented', 'SyntaxValidated', 'ConfigurationValidated') -contains $t.status) {
            $actions = @()
            if ((Test-NxProp $t 'apply') -and ($null -ne $t.apply) -and (Test-NxProp $t.apply 'actions')) { $actions = @($t.apply.actions) }
            if ($actions.Count -eq 0) { $errors.Add("${tid}: status '$($t.status)' requires non-empty apply.actions") }
        }

        # per-action checks + translatable shape
        $actions = @()
        if ((Test-NxProp $t 'apply') -and ($null -ne $t.apply) -and (Test-NxProp $t.apply 'actions')) { $actions = @($t.apply.actions) }
        foreach ($a in $actions) {
            $hasFunction = (Test-NxProp $a 'function')
            $atype = ''
            if (Test-NxProp $a 'type') { $atype = [string]$a.type }

            if ($hasFunction) {
                if ([string]::IsNullOrWhiteSpace([string]$a.function)) {
                    $errors.Add("${tid}: action has empty function name")
                }
                continue
            }
            if ($atype -eq 'registry') {
                foreach ($req in @('path', 'name', 'kind', 'data')) {
                    if (-not (Test-NxProp $a $req)) { $errors.Add("${tid}: registry action missing '$req'") }
                }
                if (-not (Test-NxProp $a 'kind')) { continue }
                $kindKey = ([string]$a.kind).ToLowerInvariant()
                if (-not $NxJournaledKinds.ContainsKey($kindKey)) {
                    $errors.Add("${tid}: registry action kind '$($a.kind)' is REFUSED - Invoke-NxRegistryTweak routes only String/ExpandString/DWord/QWord; Binary/MultiString entries must ship as dedicated functions (no lossless command-line encoding)")
                }
                foreach ($field in @('path', 'name', 'data')) {
                    if ((Test-NxProp $a $field) -and ([string]$a.$field -match "[\r\n]")) {
                        $errors.Add("${tid}: registry action ${field} contains line breaks - the command-line routing cannot encode it; ship a dedicated function")
                    }
                }
                if ((Test-NxProp $a 'path') -and ([string]$a.path -match 'ControlSet00[12]')) {
                    $errors.Add("${tid}: direct ControlSet001/002 write forbidden (use CurrentControlSet)")
                }
                # banned registry targets (same consent semantics as the validator)
                $consentOk = ((@('ADVANCED', 'TROUBLESHOOTING') -contains $t.risk) -and ([string]$t.approval -eq 'ExplicitConsent'))
                foreach ($b in @($schema.bannedRegistryTargets)) {
                    if (([string]$a.path).ToLower() -eq ([string]$b.path).ToLower() -and [string]$a.name -eq [string]$b.name) {
                        $badValues = @($b.badValues)
                        if ($badValues -contains 'ANY_WITHOUT_EXPLICIT_CONSENT') {
                            if (-not $consentOk) { $errors.Add("${tid}: banned target $($b.path) :: $($b.name) - $($b.reason)") }
                        } else {
                            if ($badValues -contains $a.data -and -not $consentOk) {
                                $errors.Add("${tid}: banned value $($a.data) for $($b.path) :: $($b.name) - $($b.reason)")
                            }
                        }
                    }
                }
                continue
            }
            # service actions must name a service (function-less service actions are
            # untranslatable: journal-first requires the NxCore engine path).
            if ($atype -eq 'service') {
                if (Test-NxProp $a 'name') {
                    if (@($schema.neverTouchServices) -contains $a.name) {
                        $errors.Add("${tid}: action targets never-touch service '$($a.name)'")
                    }
                    if ((Test-NxProp $a 'path') -and ([string]$a.path -match 'ControlSet00[12]')) {
                        $errors.Add("${tid}: direct ControlSet001/002 write forbidden (use CurrentControlSet)")
                    }
                } else {
                    $errors.Add("${tid}: service action without a 'function' or 'name' is untranslatable")
                }
                continue
            }
            $errors.Add("${tid}: untranslatable action (type '$atype', no function) - the generator refuses to emit unknown shapes")
        }
    }
}

# duplicate ids anywhere
$seenIds = @{}
foreach ($t in $allTweaks) {
    $tid = [string]$t.id
    if ($seenIds.ContainsKey($tid)) { $errors.Add("duplicate tweak id: $tid") } else { $seenIds[$tid] = $true }
}

if ($errors.Count -gt 0) {
    Write-Output 'REGISTRY VALIDATION FAILED (generator refuses to emit from invalid input):'
    foreach ($e in $errors) { Write-Output "  ERROR: $e" }
    if ($warnings.Count -gt 0) { foreach ($w in $warnings) { Write-Output "  WARNING: $w" } }
    Write-Output ("RESULT: FAILED - " + $errors.Count + " error(s), " + $warnings.Count + " warning(s)")
    exit 1
}

# ----------------------------------------------------------------------------
# Build the emission model (wave order, routing, action graph)
# ----------------------------------------------------------------------------
# wave order: NX16 (recovery substrate) first, then ascending category number.
# Hashtables do not expose their keys as PSObject properties, so Sort-Object must
# use a scriptblock expression, not -Property sortKey.
$categories = @($categories | Sort-Object -Property @{ Expression = { [string]$_.sortKey + '|' + [string]$_.name } })

# cross-category dependency ordering warnings (wave order may not satisfy them)
$waveIndex = @{}
for ($i = 0; $i -lt $categories.Count; $i++) { $waveIndex[$categories[$i].name] = $i }
foreach ($t in $allTweaks) {
    foreach ($d in @($t.dependencies)) {
        if ([string]::IsNullOrWhiteSpace([string]$d)) { continue }
        if ($idToCategory.ContainsKey([string]$d)) {
            $depCat = $idToCategory[[string]$d]
            if ($waveIndex.ContainsKey($depCat) -and $waveIndex.ContainsKey([string]$t.category)) {
                if ([int]$waveIndex[$depCat] -gt [int]$waveIndex[[string]$t.category]) {
                    $warnings.Add("$($t.id): cross-category dependency '$d' (category $depCat) is emitted AFTER this tweak's category in wave order - re-run ordering is a coordinator decision")
                }
            }
        }
    }
}

$inventory = Get-NxCoreInventory $engineFiles
$expectedFunctions = @{
    $NxPreflightFn = $true
    $NxRollbackFn = $true
}

$model = @{
    version     = $Version
    categories  = @()
    preflight   = $null
    rollback    = @()
}

# ---------------------------------------------------------------- UI model
# The AME wizard is a selection surface, not a tweak browser. NEXTRIX exposes
# quality-of-life choices (how Windows should look, behave and protect privacy),
# not the technical tweak names; every choice maps to journaled tweaks underneath.
# presetExcluded (advanced/troubleshooting) stays CLI-only with explicit consent.
# AME rules enforced below: CheckboxPage Description 50-85 chars, short Option Text,
# max 4 options per page, hard 4-page budget.
$UiCategoryDefault = @{
    'NX01' = 'q-start';     'NX02' = 'q-game-mode'; 'NX03' = 'q-power';      'NX04' = 'q-graphics'
    'NX05' = 'q-power';     'NX06' = 'q-explorer';  'NX07' = 'q-network';    'NX08' = 'q-input'
    'NX09' = 'q-power';     'NX10' = 'q-health';    'NX11' = 'q-background'; 'NX12' = 'q-debloat'
    'NX13' = 'q-privacy';   'NX14' = 'q-health';    'NX15' = 'q-start';      'NX16' = 'q-health'
    'NX17' = 'q-health';    'NX18' = 'q-game-mode'; 'NX19' = 'q-power';      'NX20' = 'q-health'
}
# Visual QoL is where people differ most: split NX15 into Animations, Explorer
# and Start/notifications instead of one opaque visual bundle.
$UiIdOverrides = @{
    'NX15-001' = 'q-visual'; 'NX15-002' = 'q-visual'; 'NX15-003' = 'q-visual'; 'NX15-014' = 'q-visual'
    'NX15-006' = 'q-explorer'; 'NX15-007' = 'q-explorer'; 'NX15-008' = 'q-explorer'
    'NX15-009' = 'q-explorer'; 'NX15-010' = 'q-explorer'
}
# QoL choices. Each is its own UI group, so every emitted action has exactly one gate.
$UiBundles = [ordered]@{
    'q-start'      = 'Cleaner Start & notifications'
    'q-explorer'   = 'Files, Explorer & storage'
    'q-visual'     = 'Animations & transparency'
    'q-health'     = 'Healthy Windows & reports'
    'q-privacy'    = 'Less tracking & personalized ads'
    'q-background' = 'Fewer startup & background apps'
    'q-debloat'    = 'Remove apps I don''t use'
    'q-network'    = 'Stable network & DNS'
    'q-game-mode'  = 'Game Mode, no recording'
    'q-graphics'   = 'Graphics & display smoothness'
    'q-input'      = 'Mouse & keyboard feel'
    'q-power'      = 'Performance or battery'
}
$UiBundleGroups = @{}
foreach ($q in $UiBundles.Keys) { $UiBundleGroups[$q] = @($q) }
$UiGroupBundle = @{}
foreach ($q in $UiBundleGroups.Keys) {
    foreach ($g in @($UiBundleGroups[$q])) {
        if ($UiGroupBundle.ContainsKey($g)) { throw "UI: group '$g' mapped to two choices" }
        $UiGroupBundle[$g] = $q
    }
}
$UiDefaultChecked = @{ 'q-health' = $true }
# First page: form factor radio. Desktop and Laptop are mutually exclusive, so a
# radio page is used (checkboxes cannot enforce a single choice). Hardware-specific
# tweak ids are re-gated from their QoL choice to the matching form-factor option.
$UiFormFactorOptions = @(
    @{ name = 'ff-desktop'; text = 'Desktop PC' }
    @{ name = 'ff-laptop';  text = 'Laptop' }
)
$UiFormFactorDefault = 'ff-desktop'
$UiFormFactorDescription = 'Pick Desktop or Laptop so the right power and thermal tweaks apply.'
$UiFormFactorTopLine = 'Desktop: Ultimate Performance. Laptop: battery, lid, Wi-Fi and thermal tweaks.'
$UiFormFactor = @{
    'NX04-008' = 'ff-laptop'   # hybrid graphics routing (laptop)
    'NX06-012' = 'ff-laptop'   # storage D3 in Modern Standby (laptop)
    'NX07-002' = 'ff-laptop'   # adapter power management (laptop)
    'NX07-012' = 'ff-laptop'   # Wi-Fi roaming aggressiveness (laptop)
    'NX07-015' = 'ff-laptop'   # Wi-Fi transmit power (laptop)
    'NX08-006' = 'ff-laptop'   # Bluetooth power policy (laptop)
    'NX09-004' = 'ff-laptop'   # PCIe ASPM AC/DC policy (laptop)
    'NX09-005' = 'ff-laptop'   # USB selective suspend AC/DC (laptop)
    'NX09-010' = 'ff-laptop'   # lid-close behavior (laptop)
    'NX09-011' = 'ff-laptop'   # OEM battery conservation report (laptop)
    'NX09-015' = 'ff-laptop'   # battery report (laptop)
    'NX10-007' = 'ff-laptop'   # AC/DC thermal report (laptop)
    'NX09-002' = 'ff-desktop'  # Ultimate Performance provisioning (desktop)
}
# Three QoL pages plus the form-factor page = four wizard pages (the hard budget).
# AME rules: CheckboxPage Description 50-85 chars, max 4 options/page; RadioPage
# here has exactly two options.
$UiPages = @(
    @{ desc = 'Everyday: cleaner Start, files/storage, visuals and Windows health.'; bundles = @('q-start','q-explorer','q-visual','q-health') }
    @{ desc = 'Privacy, apps and network: less tracking, fewer background apps, DNS.'; bundles = @('q-privacy','q-background','q-debloat','q-network') }
    @{ desc = 'Gaming and input: Game Mode, graphics, mouse/keyboard and power.'; bundles = @('q-game-mode','q-graphics','q-input','q-power') }
)

foreach ($c in $categories) {
    $ordered = Get-NxStableDependencyOrder $c.tweaks
    $preflightTweaks = @()
    $rollbackTweaks = @()
    $selectable = @()

    foreach ($t in $ordered) {
        $actions = @()
        if ((Test-NxProp $t 'apply') -and ($null -ne $t.apply) -and (Test-NxProp $t.apply 'actions')) { $actions = @($t.apply.actions) }
        $hasPreflight = $false; $hasRollback = $false
        foreach ($a in $actions) {
            if ((Test-NxProp $a 'function')) {
                if ([string]$a.function -eq $NxPreflightFn) { $hasPreflight = $true }
                if ([string]$a.function -eq $NxRollbackFn) { $hasRollback = $true }
            }
        }
        if ($hasPreflight -and $hasRollback) {
            $errors.Add("$($t.id): declares BOTH pre-flight and rollback functions - ambiguous routing, refusing")
            continue
        }
        if ($hasPreflight) { $preflightTweaks += $t; continue }
        if ($hasRollback) { $rollbackTweaks += $t; continue }

        # selectable: every action becomes an emission item
        $items = @()
        foreach ($a in $actions) {
            if (Test-NxProp $a 'function') {
                $fn = [string]$a.function
                $expectedFunctions[$fn] = $true
                $params = $null
                if (Test-NxProp $a 'parameters') { $params = $a.parameters }
                $args = Get-NxParameterArguments $fn $params $inventory ([string]$t.approval)
                $call = $fn
                if (-not [string]::IsNullOrWhiteSpace($args)) { $call = "$fn $args" }
                $items += @{
                    kind = 'powerShell'; command = $call
                    builds = (Get-NxAmeBuildsGate $t.builds)
                }
                if (-not $inventory.ContainsKey($fn)) {
                    $warnings.Add("$($t.id): function '$fn' not found in src/nxcore at generate time - if the tweak is wizard-included it is emitted by name; otherwise it is tooling-only (manifest lists it as expected)")
                }
                continue
            }
            if ([string]$a.type -eq 'registry') {
                # Journal-first routing (ADR-006 remediation): every registry-type
                # action becomes a journaled NxCore write - capture -> journal ->
                # apply -> verify -> journal with safe-stop + exact-original restore.
                # Binary/MultiString were refused during validation.
                $kindCanon = $NxJournaledKinds[([string]$a.kind).ToLowerInvariant()]
                $regParams = [pscustomobject]@{
                    Path         = [string]$a.path
                    Name         = [string]$a.name
                    Kind         = $kindCanon
                    Data         = [string]$a.data
                    TweakId      = [string]$t.id
                    TweakVersion = [string]$t.version
                    Approval     = [string]$t.approval
                }
                if ($null -ne $t.profiles -and @($t.profiles).Count -gt 0) {
                    $regParams | Add-Member -NotePropertyName Profiles -NotePropertyValue @($t.profiles)
                }
                $args = Get-NxParameterArguments 'Invoke-NxRegistryTweak' $regParams $inventory ([string]$t.approval)
                $call = 'Invoke-NxRegistryTweak'
                if (-not [string]::IsNullOrWhiteSpace($args)) { $call = "$call $args" }
                $expectedFunctions['Invoke-NxRegistryTweak'] = $true
                $items += @{
                    kind = 'powerShell'; command = $call
                    builds = (Get-NxAmeBuildsGate $t.builds)
                }
                if (-not $inventory.ContainsKey('Invoke-NxRegistryTweak')) {
                    $warnings.Add("${tid}: function 'Invoke-NxRegistryTweak' not found in src/nxcore at generate time - journaled registry writes were emitted by name; manifest lists it as expected")
                }
                continue
            }
            # unreachable: validation refused untranslatable shapes already
        }
        if ($items.Count -eq 0 -and $actions.Count -gt 0) {
            $warnings.Add("$($t.id): no translatable actions emitted (shape refused earlier or empty)")
        }
        if ($items.Count -eq 0 -and $actions.Count -eq 0) {
            $warnings.Add("$($t.id): option emitted with zero actions (status '$($t.status)' - registry authors must add apply.actions before release)")
        }
        $catCode = [System.IO.Path]::GetFileNameWithoutExtension([string]$c.file)
        $groupId = 'g-session'
        if ($UiIdOverrides.ContainsKey([string]$t.id)) { $groupId = [string]$UiIdOverrides[[string]$t.id] }
        elseif ($UiCategoryDefault.ContainsKey($catCode)) { $groupId = [string]$UiCategoryDefault[$catCode] }
        $wizardInclude = $true; $excludeReason = ''
        if ([bool]$t.presetExcluded) {
            $wizardInclude = $false
            $excludeReason = 'presetExcluded: tooling-only (individually selectable via the NXCore CLI with explicit consent)'
        } else {
            foreach ($it in $items) {
                if ($it.kind -eq 'powerShell') {
                    $fnName = ([string]$it.command).Split(' ')[0]
                    if (-not $inventory.ContainsKey($fnName)) { $wizardInclude = $false; $excludeReason = "pending engine function '$fnName'" }
                }
            }
        }
        $bundleOption = $groupId
        if ($UiGroupBundle.ContainsKey($groupId)) { $bundleOption = [string]$UiGroupBundle[$groupId] }
        # Hardware-specific tweaks follow the Desktop/Laptop radio instead of the
        # QoL choice so a laptop never receives desktop-only settings and vice versa.
        if ($UiFormFactor.ContainsKey([string]$t.id)) { $bundleOption = [string]$UiFormFactor[[string]$t.id] }
        $selectable += @{
            tweak = $t
            option = ([string]$t.id).ToLowerInvariant()
            group = $groupId
            groupOption = $bundleOption
            wizardInclude = $wizardInclude
            wizardExcludeReason = $excludeReason
            checked = (-not [bool]$t.presetExcluded)
            items = $items
        }
    }

    $model.categories += @{
        name = $c.name; file = $c.file; categoryName = $c.categoryName
        tweaks = $ordered
        preflightRouted = $preflightTweaks
        rollbackRouted = $rollbackTweaks
        selectable = $selectable
    }
}

if ($errors.Count -gt 0) {
    # only routing ambiguities can land here
    Write-Output 'EMISSION MODEL FAILED:'
    foreach ($e in $errors) { Write-Output "  ERROR: $e" }
    Write-Output ("RESULT: FAILED - " + $errors.Count + " error(s)")
    exit 1
}

# ---- pre-flight resolution (structural; registry declarations enrich it) ----
$preflightTweak = $null; $preflightParams = $null
foreach ($cat in $model.categories) {
    if ($cat.preflightRouted.Count -gt 0) {
        $preflightTweak = $cat.preflightRouted[0]
        if ($cat.preflightRouted.Count -gt 1) {
            $warnings.Add("multiple pre-flight declarations found ($(@($cat.preflightRouted | ForEach-Object { $_.id }) -join ', ')); the FIRST is used for the unconditional invocation")
        }
        break
    }
}
if ($null -ne $preflightTweak) {
    $a = @($preflightTweak.apply.actions | Where-Object { [string]$_.function -eq $NxPreflightFn })[0]
    if (Test-NxProp $a 'parameters') { $preflightParams = $a.parameters }
} else {
    $warnings.Add("no registry tweak declares $NxPreflightFn - the structural pre-flight invocation was emitted anyway (mission-mandated; wire the engine function in src/nxcore)")
}
$pfArgs = Get-NxParameterArguments $NxPreflightFn $preflightParams $inventory $null
$pfCall = $NxPreflightFn
if (-not [string]::IsNullOrWhiteSpace($pfArgs)) { $pfCall = "$NxPreflightFn $pfArgs" }
if (-not $inventory.ContainsKey($NxPreflightFn)) {
    $warnings.Add("$NxPreflightFn not found in src/nxcore at generate time - emitted by name; manifest lists it as expected")
}
$model.preflight = @{ tweakId = ($(if ($null -ne $preflightTweak) { [string]$preflightTweak.id } else { $null })); call = $pfCall }

# ---- rollback scopes resolution ----
$rollbackDeclared = @{}
foreach ($cat in $model.categories) {
    foreach ($t in $cat.rollbackRouted) {
        $rollbackDeclared[[string]$t.id] = $t
    }
}
if ($rollbackDeclared.Count -eq 0) {
    $warnings.Add("no registry tweaks declare $NxRollbackFn scopes - the four structural rollback invocations were emitted anyway (mission-mandated undo surface)")
}
$rollbackScopes = @()
foreach ($scope in $NxRollbackScopes) {
    $tweak = $null
    foreach ($id in @($rollbackDeclared.Keys | Sort-Object)) {
        $t = $rollbackDeclared[$id]
        foreach ($a in @($t.apply.actions)) {
            if ((Test-NxProp $a 'function') -and [string]$a.function -eq $NxRollbackFn -and (Test-NxProp $a 'parameters')) {
                foreach ($prop in $a.parameters.PSObject.Properties) {
                    if ($prop.Name.ToLowerInvariant() -eq $scope.param) { $tweak = $t; break }
                }
            }
            if ($null -ne $tweak) { break }
        }
        if ($null -ne $tweak) { break }
    }
    $call = $null; $label = $scope.label; $regId = $null
    if ($null -ne $tweak) {
        $regId = [string]$tweak.id
        $a = @($tweak.apply.actions | Where-Object { [string]$_.function -eq $NxRollbackFn })[0]
        $params = $null
        if (Test-NxProp $a 'parameters') { $params = $a.parameters }
        $scoped = @{}
        if ($null -ne $params) {
            foreach ($prop in $params.PSObject.Properties) {
                if ($prop.Name.ToLowerInvariant() -eq $scope.param) { $scoped[$prop.Name] = $prop.Value }
            }
        }
        $scopedObj = [pscustomobject]$scoped
        $args = Get-NxParameterArguments $NxRollbackFn $scopedObj $inventory $null
        $call = $NxRollbackFn
        if (-not [string]::IsNullOrWhiteSpace($args)) { $call = "$NxRollbackFn $args" }
        $label = [string]$tweak.name
    } else {
        # structural fallback with the canonical placeholder
        $fallbackArg = Format-NxArgument ($scope.param.Substring(0, 1).ToUpperInvariant() + $scope.param.Substring(1)) $scope.fallback
        $call = "$NxRollbackFn $fallbackArg"
        if (-not ($call -match '-JournalRoot')) {
            $call = "$NxRollbackFn -JournalRoot " + $NxJournalDirArg + ' ' + $fallbackArg
        }
        $warnings.Add("rollback scope '$($scope.key)' is not declared in the registry - structural fallback emitted ($call)")
    }
    if (-not ($call -match '-JournalRoot')) {
        # NxRollback.ps1 declares -JournalRoot mandatory; keep the undo surface
        # functional even when the inventory could not confirm the signature.
        $call = $call + ' -JournalRoot ' + $NxJournalDirArg
    }
    $rollbackScopes += @{ key = $scope.key; option = $scope.option; call = $call; label = $label; registryId = $regId }
}
$model.rollback = $rollbackScopes

# ----------------------------------------------------------------------------
# Renderers
# ----------------------------------------------------------------------------
function New-NxLineList {
    # Unary comma: an empty List would otherwise be pipeline-unrolled to $null.
    $list = New-Object System.Collections.Generic.List[string]
    return ,$list
}

function Get-NxCategorySummaryLine($Model) {
    $parts = @()
    foreach ($cat in $Model.categories) {
        $n = @($cat.selectable).Count + @($cat.preflightRouted).Count + @($cat.rollbackRouted).Count
        $parts += ("$($cat.name) $($cat.categoryName) ($n tweak" + $(if ($n -eq 1) { '' } else { 's' }) + ')')
    }
    return ($parts -join '; ')
}

function New-NxPlaybookConf($Model) {
    $L = New-NxLineList
    $L.Add('<?xml version="1.0" encoding="utf-8"?>')
    $L.Add('<!--')
    $L.Add('  NEXTRIX playbook.conf. GENERATED FILE, do not edit by hand.')
    $L.Add("  Generator: tools/Invoke-NxBuild.ps1 (playbook version $($Model.version)).")
    $L.Add('  Source of truth: the NEXTRIX tweak registry (registry/NX*.json).')
    $L.Add('  Rollback authority: NxJournal/NxRollback (ADR-006). The playbook platform')
    $L.Add('  provides no uninstall; NEXTRIX carries its own journal-based rollback.')
    $L.Add('  No performance claims are made anywhere in this playbook.')
    $L.Add('-->')
    $L.Add('<Playbook>')
    $L.Add("    <Name>$NxName</Name>")
    $L.Add("    <Username>$NxName</Username>")
    $L.Add('    <Title>' + (ConvertTo-NxXmlText ("NEXTRIX v" + $Model.version)) + '</Title>')
    $L.Add('    <ShortDescription>' + (ConvertTo-NxXmlText 'Selective, journaled Windows 11 configuration with NEXTRIX-owned rollback.') + '</ShortDescription>')
    $L.Add('    <Description><![CDATA[')
    $L.Add('NEXTRIX is a journaled Windows 11 quality-of-life playbook. Pick Desktop or Laptop,')
    $L.Add('then the everyday, privacy and gaming choices you want. Only selected tweaks run;')
    $L.Add('every change is journaled by NxCore and can be undone from the command line.')
    $L.Add('No performance claims - validate on your own hardware.]]>')
    $L.Add('    </Description>')
    $L.Add('    <Details>' + (ConvertTo-NxXmlText ('Windows 11 23H2-26H2 (22631, 26100, 26200, 26300). Requirements: Internet, PluggedIn. Journal at %ProgramData%\NEXTRIX\Journal. Wizard: AME Beta v0.8.4.')) + '</Details>')
    $L.Add('    <ProgressText><![CDATA[')
    $L.Add('Applying the tweaks you selected. The pre-flight journal, reports, restore point and')
    $L.Add('backups run first; every change is journaled for rollback.]]>')
    $L.Add('    </ProgressText>')
    $L.Add("    <Version>$($Model.version)</Version>")
    $L.Add('    <SupportedBuilds>')
    $L.Add('        <!-- 23H2 -->')
    $L.Add('        <string>22631</string>')
    $L.Add('        <!-- 24H2 -->')
    $L.Add('        <string>26100</string>')
    $L.Add('        <!-- 25H2 -->')
    $L.Add('        <string>26200</string>')
    $L.Add('        <!-- 26H2 -->')
    $L.Add('        <string>26300</string>')
    $L.Add('    </SupportedBuilds>')
    $L.Add('    <UpgradableFrom>any</UpgradableFrom>')
    $L.Add('    <Requirements>')
    $L.Add('        <Requirement>Internet</Requirement>')
    $L.Add('        <Requirement>PluggedIn</Requirement>')
    $L.Add('    </Requirements>')
    $L.Add('    <AllowUnsupportedUpgrades>false</AllowUnsupportedUpgrades>')
    $L.Add("    <UniqueId>$NxUniqueId</UniqueId>")
    $L.Add('    <Overhaul>false</Overhaul>')
    $L.Add('    <UseKernelDriver>false</UseKernelDriver>')
    $L.Add('    <!-- Placeholder update channel (ADR-007 remote). Confirm repo visibility,')
    $L.Add('         release tag = playbook Version and exactly one .apbx per release before')
    $L.Add('         first public release. -->')
    $L.Add("    <Git>$NxGitUrl</Git>")
    $L.Add('    <FeaturePages>')

    # Page 1: form factor (RadioPage - exactly one of Desktop / Laptop).
    $pageNo = 0
    $ffDesc = [string]$UiFormFactorDescription
    if ($ffDesc.Length -lt 50 -or $ffDesc.Length -gt 85) { throw "UI radio page description length $($ffDesc.Length) outside AME 50-85: '$ffDesc'" }
    if (@($UiFormFactorOptions).Count -gt 2) { throw 'UI: form-factor RadioPage must not exceed 2 options' }
    $pageNo++
    $L.Add('        <RadioPage DefaultOption="' + (ConvertTo-NxXmlAttr $UiFormFactorDefault) + '" Description="' + (ConvertTo-NxXmlAttr $ffDesc) + '">')
    $L.Add('            <TopLine Text="' + (ConvertTo-NxXmlAttr $UiFormFactorTopLine) + '"/>')
    $L.Add('            <Options>')
    foreach ($o in $UiFormFactorOptions) {
        $L.Add('                <RadioOption>')
        $L.Add('                    <Text>' + (ConvertTo-NxXmlText $o.text) + '</Text>')
        $L.Add('                    <Name>' + (ConvertTo-NxXmlText $o.name) + '</Name>')
        $L.Add('                </RadioOption>')
    }
    $L.Add('            </Options>')
    $L.Add('        </RadioPage>')

    # QoL choice pages (see $UiBundles/$UiPages). AME rules enforced:
    # CheckboxPage Description 50-85 chars, short option Text, max 4 options/page,
    # and a hard 4-page budget (1 form-factor page + 3 selection pages).
    $includedBundles = @()
    foreach ($page in $UiPages) {
        $pageNo++
        $desc = [string]$page.desc
        if ($desc.Length -lt 50 -or $desc.Length -gt 85) { throw "UI page description length $($desc.Length) outside AME 50-85: '$desc'" }
        $opts = @()
        foreach ($b in @($page.bundles)) {
            $count = 0
            foreach ($cat in $Model.categories) {
                foreach ($g in @($UiBundleGroups[[string]$b])) {
                    $count += @($cat.selectable | Where-Object { $_.wizardInclude -and $_.group -eq $g }).Count
                }
            }
            if ($count -eq 0) { continue }
            $bText = [string]$UiBundles[[string]$b]
            if ([string]::IsNullOrWhiteSpace($bText)) { throw "UI choice '$b' has no display text" }
            if ($bText.Length -gt 40) { throw "UI option text over 40 chars: '$bText'" }
            $opts += @{ name = [string]$b; text = $bText; checked = [bool]$UiDefaultChecked[[string]$b] }
            $includedBundles += [string]$b
        }
        if ($opts.Count -eq 0) { continue }
        if ($opts.Count -gt 4) { throw "UI page exceeds 4 options (AME engine limit): '$desc'" }
        $L.Add('        <CheckboxPage IsRequired="true" Description="' + (ConvertTo-NxXmlAttr $desc) + '">')
        $L.Add('            <Options>')
        foreach ($o in $opts) {
            $checkedAttr = 'false'
            if ($o.checked) { $checkedAttr = 'true' }
            $L.Add('                <CheckboxOption IsChecked="' + $checkedAttr + '">')
            $L.Add('                    <Text>' + (ConvertTo-NxXmlText $o.text) + '</Text>')
            $L.Add('                    <Name>' + (ConvertTo-NxXmlText $o.name) + '</Name>')
            $L.Add('                </CheckboxOption>')
        }
        $L.Add('            </Options>')
        $L.Add('        </CheckboxPage>')
    }
    $allowedUiOptions = @($includedBundles) + @($UiFormFactorOptions | ForEach-Object { [string]$_.name })
    foreach ($cat in $Model.categories) {
        foreach ($e in @($cat.selectable | Where-Object { $_.wizardInclude })) {
            if ($allowedUiOptions -notcontains [string]$e.groupOption) { throw "UI: $($e.tweak.id) mapped to option '$($e.groupOption)' which is on no page" }
        }
    }
    if ($pageNo -gt 4) { throw "UI page count $pageNo exceeds the 4-page budget" }

    # Rollback is intentionally NOT a wizard page: undoing applied changes is a
    # CLI action (Invoke-NxRollback through the bundled NxCore), not something a
    # user ticks during install. The playbook platform has no uninstall (ADR-006).

    $L.Add('    </FeaturePages>')
    $L.Add('</Playbook>')
    return ($L -join "`r`n") + "`r`n"
}

function New-NxMainYml($Model) {
    $L = New-NxLineList
    $L.Add('# NEXTRIX main.yml. GENERATED FILE, do not edit by hand.')
    $L.Add("# Generated by tools/Invoke-NxBuild.ps1 (playbook version $($Model.version)).")
    $L.Add('# Runtime contract (ADR-006): NxJournal/NxRollback is the sole rollback authority;')
    $L.Add('# this playbook is apply-and-select only - the platform provides no uninstall.')
    $L.Add('# Order: (1) MANDATORY NxCore pre-flight, (2) per-category task files in wave')
    $L.Add('# order (NX16 first: the recovery substrate). Rollback is deliberately NOT a')
    $L.Add('# playbook action: undoing changes is a CLI operation (Invoke-NxRollback).')
    $L.Add('# Bundled NxCore modules are declared in')
    $L.Add('# Executables/nxcore-manifest.json and copied into Executables/ at packaging')
    $L.Add('# time (the generator does not copy binaries).')
    $L.Add('---')
    $L.Add("title: 'NEXTRIX root playbook file'")
    $L.Add('description: >')
    $L.Add('  Pre-flight capture first (journal, hardware/build reports, restore point, targeted')
    $L.Add('  backups), then the selected per-category tweaks in wave order. Nothing runs')
    $L.Add('  without an explicitly selected option except the mandatory pre-flight.')
    $L.Add('actions:')
    $L.Add('  # 1) MANDATORY pre-flight: capture completeness before any mutation.')
    $pfId = 'structural'
    if ($null -ne $Model.preflight.tweakId) { $pfId = $Model.preflight.tweakId }
    $L.Add("  #    ($pfId -> Tasks/nxcore.yml, errorAction Halt on failure)")
    $L.Add("  - !status: {status: 'NEXTRIX pre-flight: journal, reports, backups'}")
    $L.Add("  - !task: {path: 'Tasks/nxcore.yml'}")
    $L.Add('')
    $wavePos = 0
    foreach ($cat in $Model.categories) {
        $wavePos++
        $nSel = @($cat.selectable).Count
        $nPf = @($cat.preflightRouted).Count
        $nRb = @($cat.rollbackRouted).Count
        $L.Add("  # 2.$wavePos) Category $($cat.name) ($($cat.categoryName)) - wave position $wavePos")
        $L.Add("  #    $nSel selectable option(s), $nPf routed to the pre-flight, $nRb CLI-only rollback entries (not applied).")
        $L.Add('  - !task: {path: ' + (ConvertTo-NxYq ("Tasks/$($cat.name.ToLowerInvariant()).yml")) + '}')
        $L.Add('')
    }
    $L.Add('  - !status: {status: ' + (ConvertTo-NxYq 'NEXTRIX complete - journal: %ProgramData%\NEXTRIX\Journal') + '}')
    return ($L -join "`r`n") + "`r`n"
}

function New-NxPreflightYml($Model) {
    $L = New-NxLineList
    $pfId = 'NX16-004 (declared in the registry)'
    if ($null -eq $Model.preflight.tweakId) { $pfId = 'NOT declared in the registry at generate time (structural emission)' }
    $L.Add('# NEXTRIX pre-flight task file. GENERATED FILE, do not edit by hand.')
    $L.Add("# Registry source: $pfId.")
    $L.Add('# The capture ritual is MANDATORY (no mutation without verified prior state):')
    $L.Add('# journal initialization, hardware/build reports, restore point and targeted')
    $L.Add('# backups. It runs unconditionally BEFORE every category task file and is NOT')
    $L.Add('# a user option. Failure policy: Halt (capture-completeness gate, ADR-006).')
    $L.Add('# Bundled NxCore modules (src/nxcore/*.ps1, see ../Executables/nxcore-manifest.json)')
    $L.Add('# must be present in the playbook Executables/ directory at packaging time; the')
    $L.Add('# generator does not copy binaries. Each !powerShell action is a fresh process,')
    $L.Add('# so the invocation loads NxCore from its working directory first.')
    $L.Add('---')
    $L.Add("title: 'NEXTRIX NxCore pre-flight (mandatory capture ritual)'")
    $L.Add('description: >')
    $L.Add('  Journal initialization, hardware and build reports, System Restore point and')
    $L.Add('  targeted backups, executed before any mutation. A failure halts the playbook.')
    $L.Add('actions:')
    $L.Add("  - !status: {status: 'NxCore pre-flight: journal, reports, backups'}")
    $L.Add('  - !powerShell:')
    $L.Add('    command: |')
    $L.Add("      $NxLoaderLine")
    $L.Add("      $($Model.preflight.call)")
    $L.Add('    exeDir: true')
    $L.Add('    wait: true')
    $L.Add('    runas: currentUserElevated')
    $L.Add('    errorAction: Halt')
    $L.Add('    weight: 5')
    return ($L -join "`r`n") + "`r`n"
}

function New-NxCategoryYml($Model, $Cat) {
    $L = New-NxLineList
    $nSel = @($Cat.selectable).Count
    $nPf = @($Cat.preflightRouted).Count
    $nRb = @($Cat.rollbackRouted).Count
    $L.Add('# NEXTRIX category task file. GENERATED FILE, do not edit by hand.')
    $L.Add("# Source: registry/$($Cat.file) ($($Cat.categoryName)). Playbook version $($Model.version).")
    $L.Add('# Every action is option-gated (option name = QoL choice or form factor):')
    $L.Add('# unselected choices and the other form factor never run. Advanced/troubleshooting')
    $L.Add('# entries are CLI-only and absent.')
    if ($nPf -gt 0 -or $nRb -gt 0) {
        $routed = @()
        if ($nPf -gt 0) { $routed += (@($Cat.preflightRouted | ForEach-Object { "$($_.id) -> Tasks/nxcore.yml (unconditional pre-flight)" }) -join ', ') }
        if ($nRb -gt 0) { $routed += (@($Cat.rollbackRouted | ForEach-Object { "$($_.id) -> CLI-only rollback (not an install action)" }) -join ', ') }
        $L.Add('# Routed out of this file: ' + ($routed -join '; '))
    }
    $L.Add('---')
    $L.Add('title: ' + (ConvertTo-NxYq ("NEXTRIX $($Cat.name) - $($Cat.categoryName)")))
    $L.Add('description: >')
    $L.Add("  Generated from registry/$($Cat.file): $nSel selectable tweak option(s)")
    if ($nPf -gt 0) { $L.Add("  and $nPf tweak(s) routed to the mandatory pre-flight") }
    if ($nRb -gt 0) { $L.Add("  and $nRb CLI-only rollback entries (rollback is never an install action)") }
    $L.Add('  (option names are QoL choices or the Desktop/Laptop form factor). Function')
    $L.Add('  actions run the journaled NxCore engine; registry actions run the journaled')
    $L.Add('  Invoke-NxRegistryTweak pipeline (capture -> journal -> apply -> verify), never a raw engine write.')
    $L.Add('actions:')
    foreach ($entry in $Cat.selectable) {
        $t = $entry.tweak
        if (-not $entry.wizardInclude) { continue }   # tooling-only: presetExcluded or pending engine function
        $option = $entry.groupOption
        $presetMark = ''
        $L.Add('')
        $L.Add('  # ' + (ConvertTo-NxYq ("$($t.id) $($t.name)")) + $presetMark)
        foreach ($item in $entry.items) {
            if ($item.kind -eq 'powerShell') {
                if ($item.command -like 'Invoke-NxRegistryTweak*') {
                    $L.Add('  # Journaled write (ADR-006): Invoke-NxRegistryTweak captures the exact original,')
                    $L.Add('  # journals BEFORE mutating, verifies, and restores the original on failure.')
                }
                $L.Add('  - !powerShell:')
                $L.Add('    command: |')
                $L.Add("      $NxLoaderLine")
                $L.Add("      $($item.command)")
                $L.Add('    exeDir: true')
                $L.Add('    wait: true')
                $L.Add('    runas: currentUserElevated')
                $L.Add('    errorAction: Notify')
                if (@($item.builds).Count -gt 0) { $L.Add('    builds: ' + (ConvertTo-NxYamlFlowStrings $item.builds)) }
                $L.Add('    option: ' + (ConvertTo-NxYq $option))
                $L.Add('    weight: 2')
            }
        }
    }
    return ($L -join "`r`n") + "`r`n"
}

function New-NxManifestJson($Model, $Inventory, $EngineFiles, $RegFiles) {
    $filesArr = @()
    foreach ($ef in @($EngineFiles | Sort-Object -Property source)) {
        $hash = ''
        try { $hash = (Get-FileHash -LiteralPath $ef.full -Algorithm SHA256).Hash.ToLowerInvariant() } catch { $hash = 'unavailable' }
        $bytes = 0
        try { $bytes = (Get-Item -LiteralPath $ef.full).Length } catch { }
        $filesArr += [pscustomobject]@{ source = $ef.source; sha256 = $hash; bytes = $bytes; stageTo = 'Executables/NxCore/' }
    }
    $regArr = @()
    foreach ($f in $RegFiles) {
        $hash = ''
        try { $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } catch { $hash = 'unavailable' }
        $regArr += [pscustomobject]@{ source = "registry/$($f.Name)"; sha256 = $hash; bytes = $f.Length }
    }
    $expectedArr = @()
    # expected functions: every function the action graph references, plus the
    # structural pre-flight and rollback; each with generate-time presence.
    $allExpected = @($expectedFunctions.Keys)
    foreach ($fn in ($allExpected | Sort-Object -Unique)) {
        $present = $Inventory.ContainsKey($fn)
        $src = $null; $jr = $false; $params = @()
        if ($present) {
            $src = [string]$Inventory[$fn].source
            $jr = $Inventory[$fn].params.ContainsKey('journalroot')
            $params = @($Inventory[$fn].params.Keys | Sort-Object)
        }
        $expectedArr += [pscustomobject]@{
            function = $fn
            status = $(if ($present) { 'present' } else { 'absent' })
            source = $src
            journalRootRequired = $jr
            parameters = $params
        }
    }
    $manifest = [pscustomobject]@{
        manifestVersion = 1
        generatedBy = 'tools/Invoke-NxBuild.ps1'
        nextrixVersion = $Model.version
        playbookUniqueId = $NxUniqueId
        destination = 'Executables/NxCore/'
        instruction = 'Packaging: tools/New-NxPackage.ps1 stages every file listed below (flat, filename preserved) into Executables/NxCore/ and writes Executables/NxCoreBootstrap.ps1 at the Executables root. The generated tasks keep the FLAT loader contract: each !powerShell action dot-sources every Nx*.ps1 in Executables/ (exeDir: true), so the bootstrap is the only file the loader sees; it loads the NxCore/ tree in dependency order, including src/nxsession/NX18.ps1 (the session subsystem, outside src/nxcore). The generator does NOT copy binaries (ADR-006: hash-pinned artifacts, zero floating downloads at install time).'
        files = $filesArr
        registryInputs = $regArr
        expectedFunctions = $expectedArr
    }
    return ($manifest | ConvertTo-Json -Depth 6)
}

# ----------------------------------------------------------------------------
# Render everything (DryRun prints the graph; real runs write files)
# ----------------------------------------------------------------------------
$renderedFiles = @()
$renderedFiles += @{ path = 'playbook.conf'; content = (New-NxPlaybookConf $model) }
$renderedFiles += @{ path = 'Configuration\main.yml'; content = (New-NxMainYml $model) }
$renderedFiles += @{ path = 'Configuration\Tasks\nxcore.yml'; content = (New-NxPreflightYml $model) }
foreach ($cat in $model.categories) {
    $renderedFiles += @{ path = "Configuration\Tasks\$($cat.name.ToLowerInvariant()).yml"; content = (New-NxCategoryYml $model $cat) }
}
$renderedFiles += @{ path = 'Executables\nxcore-manifest.json'; content = ((New-NxManifestJson $model $inventory $engineFiles $regFiles) + "`r`n") }

# ---- dry run: print the resolved action graph, write nothing ----
if ($DryRun) {
    Write-Output '=== NEXTRIX playbook generator: DRY RUN (no files written) ==='
    Write-Output "Registry:    $RegistryDir ($($regFiles.Count) file(s), $($allTweaks.Count) tweak(s))"
    Write-Output "Engine:      $($engineFiles.Count) module(s) (src/nxcore/** + src/nxsession/NX18.ps1); $($inventory.Count) inventoried function(s)"
    Write-Output "Version:     $Version"
    Write-Output "Output:      $OutDir (NOT written in dry run)"
    Write-Output ''
    Write-Output 'Preflight order (main.yml !task sequence):'
    $pos = 1
    Write-Output ("  $pos. Configuration/Tasks/nxcore.yml - unconditional pre-flight: $($model.preflight.call) [errorAction: Halt]")
    $pos++
    foreach ($cat in $model.categories) {
        $nSel = @($cat.selectable).Count
        $nRb = @($cat.rollbackRouted).Count
        $nT = @($cat.tweaks).Count
        Write-Output ("  $pos. Configuration/Tasks/$($cat.name.ToLowerInvariant()).yml - $($cat.name) $($cat.categoryName) [$nT tweak(s): $nSel option(s)]")
        $pos++
    }
    Write-Output ''
    foreach ($cat in $model.categories) {
        Write-Output "Category $($cat.name) - $($cat.categoryName) (registry/$($cat.file)):"
        $nSel = @($cat.selectable).Count
        $nPf = @($cat.preflightRouted).Count
        $nRb = @($cat.rollbackRouted).Count
        Write-Output "  tweaks: $(@($cat.tweaks).Count) total; $nSel selectable; $nPf routed to pre-flight; $nRb routed to rollback"
        $psCount = 0; $regCount = 0
        foreach ($entry in $cat.selectable) {
            foreach ($item in $entry.items) {
                if ($item.kind -eq 'powerShell') { $psCount++ }
                if ($item.command -like 'Invoke-NxRegistryTweak*') { $regCount++ }
            }
        }
        Write-Output "  actions: $psCount !powerShell ($regCount journaled registry writes via Invoke-NxRegistryTweak), 0 !registryValue, $(1 + $nSel) !status"
        $optParts = @()
        foreach ($entry in $cat.selectable) {
            $mark = 'preset'
            if (-not $entry.checked) { $mark = 'presetExcluded->UNCHECKED' }
            $optParts += "$($entry.option) [$mark]"
        }
        Write-Output ("  options: " + ($optParts -join ', '))
        Write-Output '  action graph:'
        foreach ($entry in $cat.selectable) {
            foreach ($item in $entry.items) {
                Write-Output "    $($entry.option) -> !powerShell $($item.command)"
            }
        }
        Write-Output ''
    }
    Write-Output "Rollback (CLI-only; deliberately not a wizard page):"
    foreach ($scope in $model.rollback) {
        $src = 'structural'
        if ($null -ne $scope.registryId) { $src = $scope.registryId }
        Write-Output "  $($scope.option) [$src] -> $($scope.call)"
    }
    Write-Output ''
    Write-Output 'Files that would be written:'
    foreach ($rf in $renderedFiles) { Write-Output "  $OutDir\$($rf.path)" }
    if ($warnings.Count -gt 0) {
        Write-Output ''
        Write-Output "Warnings ($($warnings.Count)):"
        foreach ($w in $warnings) { Write-Output "  - $w" }
    }
    Write-Output ''
    Write-Output "DRY RUN OK: 0 error(s), $($warnings.Count) warning(s). No files written."
    exit 0
}

# ---- real run: clean generated artifacts, then write (idempotent) ----
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$tasksDir = Join-Path $OutDir 'Configuration\Tasks'
if (Test-Path -LiteralPath $tasksDir) {
    Get-ChildItem -LiteralPath $tasksDir -Filter '*.yml' -File -ErrorAction SilentlyContinue | Remove-Item -Force
}
foreach ($stale in @(
        (Join-Path $OutDir 'playbook.conf'),
        (Join-Path $OutDir 'Configuration\main.yml'),
        (Join-Path $OutDir 'Executables\nxcore-manifest.json')
    )) {
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($rf in $renderedFiles) {
    $target = Join-Path $OutDir $rf.path
    $targetDir = Split-Path $target -Parent
    if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($target, [string]$rf.content, $utf8NoBom)
    Write-Output "wrote: $target"
}

Write-Output ''
Write-Output "Playbook '$NxName' v$Version generated from $($regFiles.Count) registry file(s), $($allTweaks.Count) tweak(s)."
Write-Output ("Options: " + (@($model.categories | ForEach-Object { "$($_.name)=$(@($_.selectable).Count)" }) -join ', ') + "; rollback: CLI-only (no wizard undo page).")
$journaledWrites = 0
foreach ($cat in $model.categories) { foreach ($e in $cat.selectable) { foreach ($i in $e.items) { if ($i.command -like 'Invoke-NxRegistryTweak*') { $journaledWrites++ } } } }
Write-Output "Journaled registry writes: $journaledWrites (Invoke-NxRegistryTweak; no raw !registryValue actions)."
if ($warnings.Count -gt 0) {
    Write-Output "Warnings ($($warnings.Count)):"
    foreach ($w in $warnings) { Write-Output "  - $w" }
}
Write-Output "RESULT: OK - $($renderedFiles.Count) file(s) written, $($errors.Count) error(s), $($warnings.Count) warning(s)."
exit 0
