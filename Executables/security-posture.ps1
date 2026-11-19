# GGOS security posture report (v0.5.0) - option security-posture. READ-ONLY.
#
# This script never modifies anything outside HKLM\SOFTWARE\GGOS (and the only
# writes there are its own report stamp). It reads the state of the security
# features GGOS promises never to weaken and reports them:
#   - Services (Get-Service, read-only): WinDefend, wscsvc,
#     SecurityHealthService must be Running; wuauserv, UsoSvc and BITS are
#     trigger-started by design, so their verdict is about the start type not
#     being Disabled (current state is still shown in the detail line).
#   - SmartScreen (read-only registry reads):
#       * documented policy surface: HKLM\Software\Policies\Microsoft\Windows\System
#         value 'EnableSmartScreen' - Group Policy "Configure Windows Defender
#         SmartScreen" (ADMX SmartScreen.admx / Policy CSP SmartScreen
#         EnableSmartScreenInShell: 0 = Disabled, 1 = Enabled) -
#         https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-smartscreen
#         (0 = ATTENTION: disabled by policy),
#       * when no policy is set, the classic user-toggle backing value
#         HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer
#         'SmartScreenEnabled' ('Off' = ATTENTION),
#       * when neither is present: OK - Windows default behavior (SmartScreen
#         on, user-controlled).
#     NOTE: 'AppHostEnableSmartScreen' (suggested in the v0.5.0 spec) is not
#     part of the current documented SmartScreen policy surface and is
#     deliberately not read.
#   - Defender real-time state via Get-MpComputerStatus (AMServiceEnabled,
#     AMRealTimeProtectionEnabled, AntivirusEnabled), only when the Defender
#     PowerShell module is available.
# Every read failure degrades to an UNKNOWN line - the report never crashes.
# Output: %SystemRoot%\GGOS\ggos-security.txt (one OK / ATTENTION / UNKNOWN
# line per item) and a summary stamp under HKLM\SOFTWARE\GGOS\SecurityPosture
# (LastRun + Ok/Attention/Unknown counts). The script always exits 0.

param()

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'ggos-common.psm1') -Force

$reg = Join-Path $env:SystemRoot 'System32\reg.exe'
$dataDir = Join-Path $env:SystemRoot 'GGOS'
$reportFile = Join-Path $dataDir 'ggos-security.txt'

$script:Report = New-Object System.Collections.Generic.List[string]
$script:OkCount = 0
$script:AttentionCount = 0
$script:UnknownCount = 0

function Add-PostureLine {
    param([string]$Status, [string]$Item, [string]$Detail)
    switch ($Status) {
        'OK' { $script:OkCount++ }
        'ATTENTION' { $script:AttentionCount++ }
        default { $script:UnknownCount++ }
    }
    $line = ('{0,-9} {1}: {2}' -f $Status, $Item, $Detail)
    $script:Report.Add($line)
    Write-GGLog ($line)
}

function Get-GGReadValue {
    # Read-only single-value registry read via the PowerShell provider (no
    # external process). Returns $null when the key or the value does not
    # exist (ItemNotFoundException / PSArgumentException); any other failure
    # is rethrown so the caller can log an UNKNOWN line.
    param([string]$KeyPath, [string]$ValueName)
    try {
        $v = Get-ItemProperty -LiteralPath $KeyPath -Name $ValueName -ErrorAction Stop
        return $v.$ValueName
    }
    catch [System.Management.Automation.ItemNotFoundException] { return $null }
    catch [System.Management.Automation.PSArgumentException] { return $null }
}

# ---------------------------------------------------------------------------
# 1. Services (read-only Get-Service)
# ---------------------------------------------------------------------------
$serviceChecks = @(
    @{ Name = 'WinDefend';             Verdict = 'running'; Desc = 'Microsoft Defender Antivirus service (WinDefend)' },
    @{ Name = 'SecurityHealthService'; Verdict = 'running'; Desc = 'Windows Security service (SecurityHealthService)' },
    @{ Name = 'wscsvc';                Verdict = 'running'; Desc = 'Security Center service (wscsvc)' },
    @{ Name = 'wuauserv';             Verdict = 'enabled'; Desc = 'Windows Update service (wuauserv)' },
    @{ Name = 'UsoSvc';               Verdict = 'enabled'; Desc = 'Update Session Orchestrator (UsoSvc)' },
    @{ Name = 'BITS';                 Verdict = 'enabled'; Desc = 'Background Intelligent Transfer Service (BITS)' }
)
foreach ($s in $serviceChecks) {
    try {
        $svc = Get-Service -Name $s.Name -ErrorAction Stop
        if ($s.Verdict -eq 'running') {
            if ($svc.Status -eq 'Running') { Add-PostureLine 'OK' $s.Desc ('Running (start type ' + $svc.StartType + ')') }
            else { Add-PostureLine 'ATTENTION' $s.Desc ('service is ' + $svc.Status + ' - expected Running (start type ' + $svc.StartType + ')') }
        }
        else {
            if ($svc.StartType -eq 'Disabled') { Add-PostureLine 'ATTENTION' $s.Desc ('start type is Disabled - Windows Update delivery was weakened by a tweak or third-party tool') }
            else { Add-PostureLine 'OK' $s.Desc ('start type ' + $svc.StartType + ' (currently ' + $svc.Status + ')') }
        }
    }
    catch {
        Add-PostureLine 'UNKNOWN' $s.Desc ('service state could not be read: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# 2. SmartScreen (read-only registry reads; sources in the header)
# ---------------------------------------------------------------------------
try {
    $policyValue = Get-GGReadValue -KeyPath 'HKLM:\Software\Policies\Microsoft\Windows\System' -ValueName 'EnableSmartScreen'
    if ($null -ne $policyValue) {
        if ([int]$policyValue -eq 0) { Add-PostureLine 'ATTENTION' 'SmartScreen (policy)' 'EnableSmartScreen = 0 - SmartScreen disabled by policy' }
        else { Add-PostureLine 'OK' 'SmartScreen (policy)' ('enabled by policy (EnableSmartScreen = ' + $policyValue + ')') }
    }
    else {
        $toggleValue = Get-GGReadValue -KeyPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -ValueName 'SmartScreenEnabled'
        if ($null -ne $toggleValue) {
            if ([string]$toggleValue -eq 'Off') { Add-PostureLine 'ATTENTION' 'SmartScreen (user toggle)' 'SmartScreenEnabled = Off - SmartScreen turned off for this PC' }
            else { Add-PostureLine 'OK' 'SmartScreen (user toggle)' ('SmartScreenEnabled = ' + $toggleValue) }
        }
        else {
            Add-PostureLine 'OK' 'SmartScreen' 'no policy or user override present (Windows default: SmartScreen on)'
        }
    }
}
catch {
    Add-PostureLine 'UNKNOWN' 'SmartScreen' ('state could not be read: ' + $_.Exception.Message)
}

# ---------------------------------------------------------------------------
# 3. Defender real-time protection (Get-MpComputerStatus, read-only)
# ---------------------------------------------------------------------------
$mpStatus = $null
try {
    $mpStatus = Get-MpComputerStatus -ErrorAction Stop
}
catch {
    Add-PostureLine 'UNKNOWN' 'Defender (Get-MpComputerStatus)' ('real-time protection state could not be read: ' + $_.Exception.Message)
}
if ($null -ne $mpStatus) {
    $mpItems = @(
        @{ Property = 'AMServiceEnabled';           Desc = 'Defender antimalware service' },
        @{ Property = 'AMRealTimeProtectionEnabled'; Desc = 'Defender real-time protection' },
        @{ Property = 'AntivirusEnabled';           Desc = 'Defender antivirus' }
    )
    foreach ($i in $mpItems) {
        try {
            $val = $mpStatus.PSObject.Properties[$i.Property].Value
            if ($val -is [bool] -and $val) { Add-PostureLine 'OK' $i.Desc ($i.Property + ' = True') }
            elseif ($val -is [bool]) { Add-PostureLine 'ATTENTION' $i.Desc ($i.Property + ' = False - real-time protection is off') }
            else { Add-PostureLine 'UNKNOWN' $i.Desc ($i.Property + ' could not be read (unexpected type)') }
        }
        catch {
            Add-PostureLine 'UNKNOWN' $i.Desc ('state could not be read: ' + $_.Exception.Message)
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Report file + summary stamp (the only writes this script performs)
# ---------------------------------------------------------------------------
try {
    New-Item -ItemType Directory -Path $dataDir -Force -ErrorAction Stop | Out-Null
    $header = @(
        ('GGOS security posture report - ' + (Get-Date -Format s)),
        'Read-only check: no security settings were changed by GGOS.',
        ''
    )
    Set-Content -LiteralPath $reportFile -Value ($header + $script:Report) -ErrorAction Stop
    Write-GGLog ('Security posture report written to ' + $reportFile)
}
catch {
    Write-GGLog ('Warning: the security report could not be written: ' + $_.Exception.Message)
}

$stampOk = $true
foreach ($stamp in @(
    @{ Name = 'LastRun';  Type = 'REG_SZ';     Data = (Get-Date -Format s);                 Desc = 'SecurityPosture LastRun stamp' },
    @{ Name = 'Ok';       Type = 'REG_DWORD'; Data = [string]$script:OkCount;               Desc = 'SecurityPosture Ok count stamp' },
    @{ Name = 'Attention';Type = 'REG_DWORD'; Data = [string]$script:AttentionCount;        Desc = 'SecurityPosture Attention count stamp' },
    @{ Name = 'Unknown';  Type = 'REG_DWORD'; Data = [string]$script:UnknownCount;          Desc = 'SecurityPosture Unknown count stamp' }
)) {
    $ok, $exit, $out = Invoke-GGCommand -FilePath $reg -ArgumentList @('add', 'HKLM\SOFTWARE\GGOS\SecurityPosture', '/v', $stamp.Name, '/t', $stamp.Type, '/d', $stamp.Data, '/f') -TimeoutSeconds 20 -Description $stamp.Desc
    if (-not (Test-GGRegSuccess $ok $exit $out)) { $stampOk = $false; Write-GGLog ('Warning: ' + $stamp.Desc + ' could not be written.') }
}

$summary = ('{0} OK / {1} ATTENTION / {2} UNKNOWN' -f $script:OkCount, $script:AttentionCount, $script:UnknownCount)
if ($stampOk) { Write-GGLog ('HKLM\SOFTWARE\GGOS\SecurityPosture stamped (LastRun + counts): ' + $summary) }
Write-GGLog ('Security posture summary: ' + $summary)

# Always exit 0 - the report must never fail the playbook run.
exit 0
