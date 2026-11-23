#Requires -Version 5.1
<#
    NxCompat.ps1 - tweak eligibility resolver (never mutates; read-only evaluation).

    Eligibility order per PROFILE_MATRIX.md: hardware gate -> build/capability
    gate -> dependency/known-conflict check -> risk policy. A tweak that is not
    eligible is SKIPPED with a machine-readable reason - never silently applied,
    never an error that halts the run (graceful skip per directive Section 10).
#>

function Get-NxTweakEligibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Tweak,          # registry entry object
        [Parameter(Mandatory)]$HardwareReport, # Get-NxHardwareReport result
        [Parameter(Mandatory)]$BuildReport      # Get-NxBuildReport result
    )
    $reasons   = @()
    $warnings  = @()
    $supported = $true

    # 1. Build gate (ADR-003 scope: 22631..26300; Insider = experimental).
    if ($BuildReport.readSucceeded -ne $true) {
        $supported = $false; $reasons += 'build report unavailable (read failed)'
    } else {
        $minB = 22631; $maxB = 26300
        if ($Tweak.builds.min) { $minB = [int]$Tweak.builds.min }
        if ($Tweak.builds.max) { $maxB = [int]$Tweak.builds.max }
        if ($BuildReport.build -lt $minB) { $supported = $false; $reasons += "build $($BuildReport.build) below tweak minimum $minB" }
        if ($BuildReport.build -gt $maxB) { $supported = $false; $reasons += "build $($BuildReport.build) above tweak maximum $maxB" }
        if ($BuildReport.insiderChannel) { $warnings += 'Insider channel: experimental per directive Section 10' }
        if ($BuildReport.build -eq 26100) { $warnings += '24H2 (26100) is the reference-divergent build: extra capability checks apply (COMPATIBILITY_RESEARCH)' }
    }

    # 2. Hardware gates - vendor-specific tweaks can never apply to other vendors.
    $req = $Tweak.requiredHardware
    if ($req -and $req.gpuVendor) {
        $present = @($HardwareReport.gpu.vendorsPresent)
        foreach ($v in @($req.gpuVendor)) {
            if ($present -notcontains $v) { $supported = $false; $reasons += "required GPU vendor '$v' not present (detected: $($present -join ', '))" }
        }
    }
    if ($req -and $req.excludedGpuVendor) {
        $present = @($HardwareReport.gpu.vendorsPresent)
        foreach ($v in @($req.excludedGpuVendor)) {
            if ($present -contains $v) { $supported = $false; $reasons += "excluded GPU vendor '$v' is present" }
        }
    }
    if ($req -and $req.chassis) {
        if ([string]$req.chassis -ne [string]$HardwareReport.chassis.chassisClass) {
            $supported = $false
            $reasons += "requires chassis '$($req.chassis)', detected '$($HardwareReport.chassis.chassisClass)'"
        }
    }
    if ($req -and $req.minRamGb) {
        if (-not $HardwareReport.memory.totalGb) {
            $warnings += 'RAM total unavailable - threshold check skipped with Uncertain mark'
        } elseif ($HardwareReport.memory.totalGb -lt [double]$req.minRamGb) {
            $supported = $false
            $reasons += "requires >= $($req.minRamGb) GB RAM, detected $($HardwareReport.memory.totalGb) GB"
        }
    }
    if ($req -and $req.requiresSsd -and -not $HardwareReport.storage.hasSsd) {
        $supported = $false; $reasons += 'requires an SSD, none detected (or storage class unreadable)'
    }

    # 3. Capability gates for declared actions (existence probes, read-only).
    foreach ($a in @($Tweak.apply.actions)) {
        if ($a.type -eq 'service') {
            $cap = Test-NxServiceCapability -Name $a.name
            if (-not $cap.supported) {
                if ($a.onMissingService -eq 'SkipGracefully') { $warnings += "service '$($a.name)' missing - action will skip gracefully" }
                else { $supported = $false; $reasons += $cap.reason }
            }
        }
        if ($a.type -eq 'registry' -and $a.capabilityPath) {
            $cap = Test-NxRegistryCapability -Path $a.capabilityPath -ValueName $a.capabilityValue
            if (-not $cap.supported) { $supported = $false; $reasons += $cap.reason }
        }
    }

    return [pscustomobject]@{
        tweakId   = $Tweak.id
        eligible  = $supported
        reasons   = $reasons
        warnings  = $warnings
        riskClass = $Tweak.risk
    }
}
