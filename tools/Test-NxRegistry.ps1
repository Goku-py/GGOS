#Requires -Version 5.1
<#
    Test-NxRegistry.ps1 - registry validator (static analysis; reads JSON only).

    Enforces the schema (registry/schema.json) mechanically:
      duplicate IDs / duplicate modification targets, dependency existence and
      cycles, conflict symmetry, build ranges (ADR-003), enum conformance,
      preset-exclusion policy, never-touch services, banned registry targets,
      no direct ControlSet00x writes.

    Exit codes: 0 = valid (warnings permitted), 1 = validation failed.
#>
[CmdletBinding()]
param(
    [string]$RegistryDir,
    [string]$SchemaPath
)
# Body-computed defaults: $PSScriptRoot is empty inside param() defaults under
# Windows PowerShell 5.1 -File invocation (W1-B finding, 2026-11-23).
if (-not $RegistryDir) { $RegistryDir = Join-Path $PSScriptRoot '..\registry' }
if (-not $SchemaPath)  { $SchemaPath  = Join-Path $PSScriptRoot '..\registry\schema.json' }
$ErrorActionPreference = 'Stop'
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

$schema = Get-Content $SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
$files = @(Get-ChildItem -Path $RegistryDir -Filter 'NX*.json' -File)
if ($files.Count -eq 0) { Write-Output 'FATAL: no registry files found'; exit 1 }

$allTweaks = @()
foreach ($f in $files) {
    $cat = $null
    try { $cat = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
        $errors.Add("file $($f.Name): invalid JSON - $($_.Exception.Message)"); continue
    }
    if (-not $cat.tweaks) { $errors.Add("file $($f.Name): no tweaks array"); continue }
    foreach ($t in @($cat.tweaks)) { $allTweaks += $t }
}
Write-Output ("loaded tweaks: " + $allTweaks.Count + " from " + $files.Count + " file(s)")

# ---- 1. required fields + enums + id/category consistency -------------------
$enumChecks = @{
    risk = $schema.riskClasses; evidence = $schema.evidenceLevels; status = $schema.statuses
    kind = $schema.kinds; modificationType = $schema.modificationTypes
    privileges = $schema.privileges; restart = $schema.restartRequirements; approval = $schema.approvalModels
}
foreach ($t in $allTweaks) {
    foreach ($rf in $schema.requiredFields) {
        if (-not $t.PSObject.Properties[$rf]) { $errors.Add("$($t.id): missing required field '$rf'") }
    }
    foreach ($k in $enumChecks.Keys) {
        $v = $t.$k
        if ($v -and (@($enumChecks[$k]) -notcontains $v)) {
            $errors.Add("$($t.id): '$k' value '$v' not in schema enum")
        }
    }
    if ($t.id -notmatch $schema.idPattern) { $errors.Add("$($t.id): id does not match pattern") }
    if ($t.id -and $t.category -and ($t.id.Substring(0,4) -ne $t.category)) {
        $errors.Add("$($t.id): category '$($t.category)' does not match id prefix")
    }
    # ---- build ranges (ADR-003) ----
    if ($t.builds) {
        if ([int]$t.builds.min -lt [int]$schema.supportedBuildRange.min -or [int]$t.builds.max -gt [int]$schema.supportedBuildRange.max) {
            $errors.Add("$($t.id): build range $($t.builds.min)..$($t.builds.max) outside ADR-003 scope")
        }
        if ([int]$t.builds.min -gt [int]$t.builds.max) { $errors.Add("$($t.id): builds min > max") }
    }
    # ---- 2. preset exclusion policy (directive Section 15, mechanical) ----
    if (@('EXPERIMENTAL','TROUBLESHOOTING') -contains $t.risk -and -not $t.presetExcluded) {
        $errors.Add("$($t.id): risk '$($t.risk)' must be presetExcluded=true")
    }
    if ($t.risk -eq 'ADVANCED' -and -not $t.presetExcluded -and [string]$t.approval -ne 'ExplicitConsent') {
        $errors.Add("$($t.id): ADVANCED risk must be presetExcluded or require ExplicitConsent")
    }
    # ---- 3. status sanity ----
    if ($t.rollback -and -not $t.rollback.PSObject.Properties['reversible']) {
        $errors.Add("$($t.id): rollback.reversible missing (schema requires honest reversibility labeling)")
    }
    if (@('Defined','Implemented','SyntaxValidated','ConfigurationValidated') -contains $t.status -and -not @($t.apply.actions).Count) {
        $errors.Add("$($t.id): status '$($t.status)' requires non-empty apply.actions")
    }
}

# ---- 4. unique IDs + duplicate modification targets -------------------------
$byId = @{}
foreach ($t in $allTweaks) {
    if ($byId.ContainsKey($t.id)) { $errors.Add("duplicate tweak id: $($t.id)") } else { $byId[$t.id] = $t }
}
$targetMap = @{}
foreach ($t in $allTweaks) {
    foreach ($a in @($t.apply.actions)) {
        if ($a.type -eq 'registry') {
            $key = "registry|$($a.path)|$($a.name)".ToLower()
            if ($targetMap.ContainsKey($key) -and $targetMap[$key] -ne $t.id) {
                $errors.Add("duplicate modification target $key used by $($targetMap[$key]) AND $($t.id) (anti-tweak-inflation gate)")
            } else { $targetMap[$key] = $t.id }
        }
        if ($a.type -eq 'service') {
            $key = "service|$($a.name)".ToLower()
            if ($targetMap.ContainsKey($key) -and $targetMap[$key] -ne $t.id) {
                $errors.Add("duplicate service target $key used by $($targetMap[$key]) AND $($t.id)")
            } else { $targetMap[$key] = $t.id }
            # ---- never-touch list (hard error) ----
            if (@($schema.neverTouchServices) -contains $a.name) {
                $errors.Add("$($t.id): action targets never-touch service '$($a.name)'")
            }
            if ($a.path -match 'ControlSet00[12]') {
                $errors.Add("$($t.id): direct ControlSet001/002 write forbidden (use CurrentControlSet)")
            }
        }
        # ---- banned registry targets ----
        if ($a.type -eq 'registry') {
            foreach ($b in @($schema.bannedRegistryTargets)) {
                if ($a.path.ToLower() -eq ([string]$b.path).ToLower() -and $a.name -eq $b.name) {
                    $consentOk = ((@('ADVANCED','TROUBLESHOOTING') -contains $t.risk) -and [string]$t.approval -eq 'ExplicitConsent')
                    $badValues = @($b.badValues)
                    if ($badValues -contains 'ANY_WITHOUT_EXPLICIT_CONSENT') {
                        if (-not $consentOk) { $errors.Add("$($t.id): banned target $($b.path) :: $($b.name) - $($b.reason)") }
                    } else {
                        if (@($badValues) -contains $a.data -and -not $consentOk) {
                            $errors.Add("$($t.id): banned value $($a.data) for $($b.path) :: $($b.name) - $($b.reason)")
                        }
                    }
                }
            }
            if ($a.path -match 'ControlSet00[12]') {
                $errors.Add("$($t.id): direct ControlSet001/002 write forbidden (use CurrentControlSet)")
            }
        }
    }
}

# ---- 5. dependency existence + cycle detection --------------------------------
foreach ($t in $allTweaks) {
    foreach ($d in @($t.dependencies)) {
        if (-not $byId.ContainsKey($d)) { $errors.Add("$($t.id): dependency '$d' does not exist") }
    }
}
$visited = @{}; $stack = @{}
function Find-NxCycle([string]$id) {
    if ($stack.ContainsKey($id)) { $script:errors.Add("dependency cycle involving '$id'"); return }
    if ($visited.ContainsKey($id)) { return }
    $stack[$id] = $true
    if ($byId.ContainsKey($id)) {
        foreach ($d in @($byId[$id].dependencies)) { Find-NxCycle $d }
    }
    $stack.Remove($id) | Out-Null
    $visited[$id] = $true
}
foreach ($t in $allTweaks) { Find-NxCycle $t.id }

# ---- 6. conflict symmetry (warning-level) -------------------------------------
foreach ($t in $allTweaks) {
    foreach ($c in @($t.conflicts)) {
        if ($byId.ContainsKey($c) -and @($byId[$c].conflicts) -notcontains $t.id) {
            $warnings.Add("conflict asymmetry: $($t.id) declares '$c' but not vice versa")
        }
    }
}

# ---- report --------------------------------------------------------------------
if ($warnings.Count -gt 0) { Write-Output 'WARNINGS:'; $warnings | ForEach-Object { Write-Output "  - $_" } }
if ($errors.Count -gt 0) {
    Write-Output 'ERRORS:'; $errors | ForEach-Object { Write-Output "  - $_" }
    Write-Output ("RESULT: FAILED - " + $errors.Count + " error(s), " + $warnings.Count + " warning(s)")
    exit 1
}
Write-Output ("RESULT: PASSED - 0 errors, " + $warnings.Count + " warning(s), " + $allTweaks.Count + " tweak(s) validated")
exit 0
