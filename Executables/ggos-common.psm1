# GGOS shared PowerShell helpers (v0.2, spec B2).
# Imported by the GGOS Executables scripts:
#   Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force
# Semantics re-expressed from community playbook structure (FSOS-X hardening
# phase model, reference only) - no upstream code copied.

function Write-GGLog {
    param([string]$Message)
    Write-Output ('GGOS: ' + $Message)
}

# B2 bounded-timeout wrapper. Runs an external command inside a job with a hard
# timeout. On success returns ($true, outputLines); on timeout the job is
# stopped, the item is appended to %SystemRoot%\GGOS\skipped.txt, and
# ($false, @()) is returned. Every reg.exe / schtasks / sc / DISM / powercfg
# call in GGOS scripts must go through this wrapper.
function Invoke-GGCommand {
    param([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSeconds = 20, [string]$Description)
    $job = Start-Job -ScriptBlock { param($fp, $al) & $fp @al 2>&1 } -ArgumentList $FilePath, $ArgumentList
    if (Wait-Job $job -Timeout $TimeoutSeconds) {
        $out = @(Receive-Job $job); Remove-Job $job -Force
        return $true, $out
    }
    Stop-Job $job; Remove-Job $job -Force
    $dir = Join-Path $env:SystemRoot 'GGOS'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Add-Content -Path (Join-Path $dir 'skipped.txt') -Value ('{0} SKIPPED(timeout {1}s): {2}' -f (Get-Date -Format s), $TimeoutSeconds, $Description)
    return $false, @()
}

Export-ModuleMember -Function @('Write-GGLog', 'Invoke-GGCommand')
