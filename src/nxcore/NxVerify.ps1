#Requires -Version 5.1
<#
    NxVerify.ps1 - post-apply configuration verification (read-only).

    Verification answers ONE question: does the configuration now hold the
    intended state? It NEVER claims anything about performance (directive
    Section 6: functional verification is not performance verification).
#>

function Test-NxConfigurationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$ExpectedValue   # $null means: value must be absent
    )
    $live = Capture-NxRegistryValue -Path $Path -Name $Name
    if ($null -eq $ExpectedValue) {
        if ($live.existed) {
            return [pscustomobject]@{ verified = $false; actual = $live; reason = 'value still present; expected absent' }
        }
        return [pscustomobject]@{ verified = $true; actual = $live; reason = 'value absent as expected' }
    }
    if (-not $live.existed) {
        return [pscustomobject]@{ verified = $false; actual = $live; reason = 'value missing after apply' }
    }
    if ($live.kind -ne $Kind) {
        return [pscustomobject]@{ verified = $false; actual = $live; reason = "kind is $($live.kind), expected $Kind" }
    }
    $a = ConvertTo-Json -InputObject $live.value -Depth 6 -Compress
    $b = ConvertTo-Json -InputObject $ExpectedValue -Depth 6 -Compress
    if ($a -ne $b) {
        return [pscustomobject]@{ verified = $false; actual = $live; reason = 'value differs from expected state' }
    }
    return [pscustomobject]@{ verified = $true; actual = $live; reason = 'configuration state matches intended state' }
}
