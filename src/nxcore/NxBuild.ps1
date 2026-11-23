#Requires -Version 5.1
<#
    NxBuild.ps1 - Windows build / edition / capability detection (read-only).

    Per directive Section 10: build numbers are context, capability detection is
    the primary gate. Read failures produce explicit Failed/Uncertain sentinels,
    never guessed values (SynToolkit uncertainty pattern, r4).
#>

function Get-NxBuildReport {
    [CmdletBinding()]
    param()
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $report = [ordered]@{
        readSucceeded  = $true
        productName    = $null
        editionId      = $null
        displayVersion = $null
        build          = 0
        ubr            = 0
        buildLabEx     = $null
        architecture   = $env:PROCESSOR_ARCHITECTURE
        marketing      = 'Unclassified'
        inSupportedScope = $false
        insiderChannel = $false
        uncertainty    = @()
    }
    try {
        $v = Get-ItemProperty -Path $cv -ErrorAction Stop
        $report.productName    = [string]$v.ProductName
        $report.editionId      = [string]$v.EditionID
        $report.displayVersion = [string]$v.DisplayVersion
        $report.build          = [int]$v.CurrentBuildNumber
        $report.ubr            = [int]$v.UBR
        $report.buildLabEx     = [string]$v.BuildLabEx
    } catch {
        $report.readSucceeded = $false
        $report.uncertainty += 'CurrentVersion registry read failed'
        return [pscustomobject]$report
    }
    $known = @{ 22631 = '23H2'; 26100 = '24H2'; 26200 = '25H2'; 26300 = '26H2' }
    if ($known.ContainsKey($report.build)) { $report.marketing = $known[$report.build] }
    else { $report.uncertainty += "build $($report.build) not in NEXTRIX marketing map" }
    # ADR-003 scope: Windows 11 23H2..26H2 (26300). Insider builds are experimental.
    $report.inSupportedScope = ($report.build -ge 22631 -and $report.build -le 26300)
    $lab = "$($report.buildLabEx) $($report.displayVersion)"
    if ($lab -match '(?i)insider\.|\.dev\.|\.beta\.') { $report.insiderChannel = $true }
    return [pscustomobject]$report
}

# Capability probe: does the required registry path / value / kind exist?
function Test-NxRegistryCapability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ValueName,
        [ValidateSet('String','ExpandString','Binary','DWord','MultiString','QWord')][string]$ExpectedKind
    )
    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{ supported = $false; reason = "key missing: $Path" }
    }
    if (-not $PSBoundParameters.ContainsKey('ValueName')) {
        return [pscustomobject]@{ supported = $true; reason = 'key exists' }
    }
    $key = Get-Item -Path $Path -ErrorAction SilentlyContinue
    if ($null -eq $key) { return [pscustomobject]@{ supported = $false; reason = "key unreadable: $Path" } }
    $raw = $key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($null -eq $raw) {
        # Missing value is NOT unsupported when the tweak creates it (RemoveEntry semantics);
        # capability = the key family exists. Kind check only applies to existing values.
        return [pscustomobject]@{ supported = $true; reason = 'key exists; value absent (tweak would create it)' }
    }
    $kind = $key.GetValueKind($ValueName).ToString()
    if ($ExpectedKind -and $kind -ne $ExpectedKind) {
        return [pscustomobject]@{ supported = $false; reason = "value '$ValueName' exists as $kind, expected $ExpectedKind (never overwrite wrong-kind values)" }
    }
    return [pscustomobject]@{ supported = $true; reason = "value present as $kind" }
}

# Capability probe: does the required service exist?
function Test-NxServiceCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        return [pscustomobject]@{ supported = $false; reason = "service missing: $Name" }
    }
    return [pscustomobject]@{
        supported = $true
        reason    = "service present ($($svc.Status)/$($svc.StartType))"
        name      = $Name
        startType = [string]$svc.StartType
        status    = [string]$svc.Status
    }
}
