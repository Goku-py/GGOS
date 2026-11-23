#Requires -Version 5.1
<#
    Test-NxAll.ps1 - bounded self-test runner.

    Runs every suite with a per-suite timeout so a hung WMI/DISM/TPM call can
    never stall a release gate. Timed-out children are killed and reported.
    Suites run under Windows PowerShell 5.1 (the target runtime; PS7's DISM/Appx
    surface is the known-broken path on some hosts).
    Exit 0 = all suites PASS; exit 1 = any FAIL/TIMEOUT.
#>
[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 150,
    [int]$DismSuiteTimeoutSeconds = 240
)
$selftestDir = Join-Path $PSScriptRoot 'selftests'
$journalTest = Join-Path $PSScriptRoot 'Test-NxJournal.ps1'
$results = New-Object System.Collections.Generic.List[object]

function Invoke-NxBounded([string]$Name, [string]$Path, [int]$Timeout) {
    $outF = Join-Path $env:TEMP ("nx-suite-" + [guid]::NewGuid().ToString('N') + ".out")
    $errF = $outF + '.err'
    $p = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Path) -WindowStyle Hidden -PassThru -RedirectStandardOutput $outF -RedirectStandardError $errF
    Wait-Process -Id $p.Id -Timeout $Timeout -ErrorAction SilentlyContinue
    if (-not $p.HasExited) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $results.Add([pscustomobject]@{ suite = $Name; outcome = 'TIMEOUT'; detail = "killed after ${Timeout}s" })
    } else {
        $text = ((Get-Content $outF -ErrorAction SilentlyContinue) -join "`n")
        $line = (($text -split "`n") | Where-Object { $_ -match 'RESULT|passed|pass=' } | Select-Object -Last 1)
        $ok = $false
        if ($text -match 'pass=\d+ fail=0' -or $text -match '\d+ passed, 0 failed' -or $text -match 'PASS=\d+ FAIL=0') { $ok = $true }
        $results.Add([pscustomobject]@{ suite = $Name; outcome = $(if ($ok) { 'PASS' } else { 'FAIL' }); detail = $(if ($line) { $line.Trim() } else { 'no result line' }) })
    }
    Remove-Item $outF, $errF -Force -ErrorAction SilentlyContinue
}

Invoke-NxBounded 'Test-NxJournal' $journalTest $TimeoutSeconds
foreach ($f in (Get-ChildItem $selftestDir -Filter 'Test-*.ps1' | Sort-Object Name)) {
    $timeout = $TimeoutSeconds
    if ($f.BaseName -eq 'Test-NX12') { $timeout = $DismSuiteTimeoutSeconds }
    Invoke-NxBounded $f.BaseName $f.FullName $timeout
}
$results | Format-Table -AutoSize | Out-String -Width 200
$failed = @($results | Where-Object { $_.outcome -ne 'PASS' })
Write-Output ("BOUNDED RUN RESULT: " + ($results.Count - $failed.Count) + " PASS, " + $failed.Count + " FAIL/TIMEOUT")
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
