# GGOS network latency tuning (v0.6.0: applied automatically, no wizard option;
# C7, XOS semantics re-expressed - no upstream code copied).
#   - Enumerates Tcpip interface keys under
#     HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{guid}.
#   - Eligible: wired/physical adapters only. Excluded: native 802.11 WiFi
#     (*PhysicalMediaType 0x09/0x0A -> decimal 9/10, or a "802.11" media string)
#     and adapters whose description contains 'Virtual', 'VPN', 'TAP',
#     'Hyper-V', 'Loopback' or 'Bluetooth' (covers Bluetooth PAN).
#   - Before writing, the current TcpAckFrequency / TCPNoDelay / TcpDelAckTicks
#     values (or an 'ABSENT' marker) are recorded under
#     HKLM\SOFTWARE\GGOS\NetworkUndo\<interface-guid>.
#   - Then sets TcpAckFrequency=1, TCPNoDelay=1, TcpDelAckTicks=0 (REG_DWORD).
#   - Per-interface result is logged; with no eligible adapter nothing is touched
#     and the script exits 0.
#
# B2: every external process call (reg.exe) runs through Invoke-GGCommand
# (ggos-common.psm1) with a bounded timeout; on failure or timeout the item is
# logged and the script continues (never halts the playbook).

$ErrorActionPreference = 'Continue'

function Write-GGLog {
    param([string]$Message)
    Write-Output "GGOS network: $Message"
}

# ---------------------------------------------------------------------------
# 0. Shared command wrapper (B2)
# ---------------------------------------------------------------------------
# ArgumentList elements are passed as raw tokens; the wrapper is responsible for
# quoting any token that contains spaces when it builds the command line.
$ggCommonPath = Join-Path $PSScriptRoot 'ggos-common.psm1'
if (Test-Path -LiteralPath $ggCommonPath) {
    Import-Module $ggCommonPath -Force
}
if (-not (Get-Command Invoke-GGCommand -ErrorAction SilentlyContinue)) {
    # Fallback shim when the shared module is absent: run the command directly
    # (without the bounded timeout) so the tweak still applies instead of failing.
    # Matches the module contract (audit F4): returns (completed, exitCode, output).
    function Invoke-GGCommand {
        param(
            [Parameter(Mandatory = $true)][string]$FilePath,
            [string[]]$ArgumentList = @(),
            [int]$TimeoutSeconds = 20,
            [string]$Description = $FilePath
        )
        Write-GGLog "Warning: ggos-common module not found - running without timeout: $Description"
        try {
            $out = (& $FilePath @ArgumentList 2>&1) -join "`n"
            $code = $LASTEXITCODE
            return ($code -eq 0), $code, [string]$out
        }
        catch {
            return $false, $null, $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# 1. Enumerate adapters and classify them
# ---------------------------------------------------------------------------
$tcpipInterfaces = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
if (-not (Test-Path -LiteralPath $tcpipInterfaces)) {
    Write-GGLog 'Tcpip interface key not found - nothing to do.'
    exit 0
}

# Interface GUID (braces stripped, lowercase) -> adapter object.
$adapterMap = @{ }
$adapters = @()
try {
    $adapters = @(Get-NetAdapter -ErrorAction Stop |
        Select-Object Name, InterfaceGuid, InterfaceDescription, PhysicalMediaType)
}
catch {
    Write-GGLog "Warning: Get-NetAdapter failed: $($_.Exception.Message)"
}

foreach ($adapter in $adapters) {
    if ($null -eq $adapter.InterfaceGuid) { continue }
    $bare = ([string]$adapter.InterfaceGuid).Trim('{', '}').ToLowerInvariant()
    if ($bare) { $adapterMap[$bare] = $adapter }
}

# Virtual/VPN/Bluetooth exclusion keywords (InterfaceDescription contains).
$virtualKeywords = @('Virtual', 'VPN', 'TAP', 'Hyper-V', 'Loopback', 'Bluetooth')

function Test-WifiAdapter {
    param([psobject]$Adapter)
    $pm = [string]$Adapter.PhysicalMediaType
    if ($pm -match '802\.11') { return $true }   # "Native 802.11" media string
    if ($pm -match '^(9|10)$') { return $true }  # 0x09 / 0x0A (native 802.11)
    return $false
}

# ---------------------------------------------------------------------------
# 2. Apply per-interface values
# ---------------------------------------------------------------------------
$eligible = 0
foreach ($key in (Get-ChildItem $tcpipInterfaces -ErrorAction SilentlyContinue)) {
    $guid = [string]$key.PSChildName
    $bare = $guid.Trim('{', '}').ToLowerInvariant()
    if (-not $adapterMap.ContainsKey($bare)) {
        Write-GGLog "Skipping interface ${guid}: no enumerated physical adapter match."
        continue
    }
    $adapter = $adapterMap[$bare]
    if (Test-WifiAdapter $adapter) {
        Write-GGLog "Skipping interface $($adapter.Name): WiFi adapters (PhysicalMediaType $([string]$adapter.PhysicalMediaType)) are excluded."
        continue
    }
    $desc = [string]$adapter.InterfaceDescription
    $virtualHit = $null
    foreach ($kw in $virtualKeywords) {
        if ($desc -match [regex]::Escape($kw)) { $virtualHit = $kw; break }
    }
    if ($virtualHit) {
        Write-GGLog "Skipping interface $($adapter.Name): '$virtualHit' in adapter description (virtual/VPN/Bluetooth excluded)."
        continue
    }

    $eligible++
    $regKeyPath = 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $guid

    # 2a. Record undo values first (or an ABSENT marker when the value is absent).
    $undoKey = 'HKLM:\SOFTWARE\GGOS\NetworkUndo\' + $guid
    try {
        New-Item -Path $undoKey -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Write-GGLog "Warning: could not create undo key for $($adapter.Name): $($_.Exception.Message)"
    }
    foreach ($valueName in @('TcpAckFrequency', 'TCPNoDelay', 'TcpDelAckTicks')) {
        $existing = Get-ItemProperty -Path $key.PSPath -Name $valueName -ErrorAction SilentlyContinue
        try {
            if ($null -ne $existing) {
                Set-ItemProperty -Path $undoKey -Name $valueName -Value $existing.$valueName -Type DWord -Force -ErrorAction Stop
                Write-GGLog "Recorded prior ${valueName}=$($existing.$valueName) for $($adapter.Name)."
            }
            else {
                Set-ItemProperty -Path $undoKey -Name $valueName -Value 'ABSENT' -Type String -Force -ErrorAction Stop
                Write-GGLog "Recorded ${valueName}=ABSENT (not previously set) for $($adapter.Name)."
            }
        }
        catch {
            Write-GGLog "Warning: could not record undo value ${valueName} for $($adapter.Name): $($_.Exception.Message)"
        }
    }

    # 2b. Apply the tuning values (DWORD) via reg.exe through the B2 wrapper.
    $results = @()
    foreach ($pair in @(@('TcpAckFrequency', '1'), @('TCPNoDelay', '1'), @('TcpDelAckTicks', '0'))) {
        $okSet, $exitSet, $setOut = Invoke-GGCommand -FilePath reg.exe -ArgumentList @('add', $regKeyPath, '/v', $pair[0], '/t', 'REG_DWORD', '/d', $pair[1], '/f') -TimeoutSeconds 20 -Description "set $($pair[0]) on $($adapter.Name)"
        if ($okSet -and $exitSet -eq 0) { $results += "$($pair[0])=$($pair[1]) OK" }
        else { $results += "$($pair[0]) FAILED$(if ($okSet) { " (exit $exitSet)" })" }
    }
    Write-GGLog "Interface $($adapter.Name) (${guid}): " + ($results -join '; ')
}

# ---------------------------------------------------------------------------
# 3. Summary
# ---------------------------------------------------------------------------
if ($eligible -eq 0) {
    Write-GGLog 'No eligible wired/physical network interface found - no changes were made.'
    exit 0
}

Write-GGLog "Network latency tuning complete ($eligible eligible interface(s))."
exit 0
