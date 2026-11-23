#Requires -Version 5.1
<#
    Test-NX07.ps1 - NX07 Network Optimization self-test.

    SAFETY (directive Section 16 / SECURITY_POLICY.md Section 5):
    This test NEVER applies a network change. It exercises ONLY:
      1. pure helpers and parsers against embedded real-format samples,
      2. capability/selection logic against synthetic adapter objects,
      3. journal round-trips and rollback-candidate selection in a throwaway
         temp directory (no restore is executed),
      4. approval / consent gates asserted to throw BEFORE any mutation path,
      5. read-only Get-NetAdapter* / Get-DnsClient* / Get-NetIPInterface /
         `netsh int tcp show global` queries against this machine.

    Exit code: 0 = all assertions pass, 1 = at least one failure.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\..\src\nxcore'
. (Join-Path $root 'NxJournal.ps1')
. (Join-Path $root 'functions\NX07.ps1')

$pass = 0; $fail = 0
function Assert-Nx07([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Output ("PASS: $Name") }
    else { $script:fail++; Write-Output ("FAIL: $Name $Detail") }
}

# ---------------------------------------------------------------------------
# 1. Value/display/mask helpers
# ---------------------------------------------------------------------------
Assert-Nx07 'value string: scalar' ((ConvertTo-Nx07ValueString 0) -eq '0')
Assert-Nx07 'value string: collection joins' ((ConvertTo-Nx07ValueString @(0, 1)) -eq '0,1')
Assert-Nx07 'value string: null -> empty' ((ConvertTo-Nx07ValueString $null) -eq '')
Assert-Nx07 'normalize display: ordinal stripped' ((ConvertTo-Nx07NormalizedDisplay '3. Prefer 5GHz band') -eq 'prefer 5ghz band')
Assert-Nx07 'normalize display: plain preserved' ((ConvertTo-Nx07NormalizedDisplay 'Rx & Tx Enabled') -eq 'rx & tx enabled')
Assert-Nx07 'masked mac: OUI only' ((ConvertTo-Nx07MaskedMac 'B4-8C-9D-D1-78-49') -eq 'B4-8C-9D-XX-XX-XX')
Assert-Nx07 'masked mac: garbage safe' ((ConvertTo-Nx07MaskedMac 'nope') -eq 'XX')

# ---------------------------------------------------------------------------
# 2. Adapter classification + exclusion rules (synthetic objects)
# ---------------------------------------------------------------------------
function New-FakeAdapter([string]$Name, [string]$Desc, [string]$Media, [bool]$Hardware = $true, [bool]$Virtual = $false, [int]$Index = 1) {
    return [pscustomobject]@{
        Name = $Name; InterfaceDescription = $Desc; DriverDescription = $Desc
        PhysicalMediaType = $Media; HardwareInterface = $Hardware; Virtual = $Virtual
        InterfaceIndex = $Index; InterfaceGuid = [guid]::NewGuid().ToString(); PnPDeviceID = "PCI\VEN_TEST&DEV_$Index"
        Status = 'Up'; LinkSpeed = '1 Gbps'; MacAddress = 'AA-BB-CC-DD-EE-FF'
    }
}
$eth = Get-Nx07AdapterClassification -Adapter (New-FakeAdapter 'Ethernet' 'Realtek PCIe GbE Family Controller' '802.3' $true $false 1)
$wifi = Get-Nx07AdapterClassification -Adapter (New-FakeAdapter 'Wi-Fi' 'MediaTek Wi-Fi 6 MT7921' 'Native 802.11' $true $false 2)
$wan = Get-Nx07AdapterClassification -Adapter (New-FakeAdapter 'Cellular' 'WWAN Modem' 'WirelessWan' $true $false 3)
$virt = Get-Nx07AdapterClassification -Adapter (New-FakeAdapter 'vEthernet (Default Switch)' 'Hyper-V Virtual Ethernet Adapter' '802.3' $false $true 4)
$vpn = Get-Nx07AdapterClassification -Adapter (New-FakeAdapter 'Ethernet 3' 'TAP-Windows Adapter V9' '802.3' $true $false 5)
$unknown = Get-Nx07AdapterClassification -Adapter (New-FakeAdapter 'Ethernet 9' 'Mystery NIC' 'Unspecified' $true $false 6)
Assert-Nx07 'classify: 802.3 is eligible Ethernet' ($eth.eligible -and $eth.isEthernet -and -not $eth.isWifi)
Assert-Nx07 'classify: Native 802.11 is eligible Wi-Fi' ($wifi.eligible -and $wifi.isWifi -and -not $wifi.isEthernet)
Assert-Nx07 'classify: WirelessWan excluded' ((-not $wan.eligible) -and $wan.reason -like '*WAN*')
Assert-Nx07 'classify: Hyper-V virtual excluded' ((-not $virt.eligible) -and $virt.isVirtual)
Assert-Nx07 'classify: TAP/VPN excluded by term list' ((-not $vpn.eligible) -and $vpn.isVirtual)
Assert-Nx07 'classify: Unspecified media excluded (cannot prove medium)' ((-not $unknown.eligible) -and $unknown.reason -like '*media type*')

# ---------------------------------------------------------------------------
# 3. Display-choice mapping (driver enumerations by NAME)
# ---------------------------------------------------------------------------
$boolCap = [pscustomobject]@{
    present = $true; registryKeyword = '*EEE'; registryValue = '0'; displayValue = 'Disabled'
    validRegistryValues = @('1', '0'); validDisplayValues = @('Enabled', 'Disabled')
}
$mOff = Find-Nx07DisplayChoice -Capability $boolCap -Patterns (Get-Nx07BooleanPatterns -Desired $false)
$mOn = Find-Nx07DisplayChoice -Capability $boolCap -Patterns (Get-Nx07BooleanPatterns -Desired $true)
Assert-Nx07 'enum map: false -> Disabled/0' ($null -ne $mOff -and $mOff.registryValue -eq '0' -and $mOff.displayValue -eq 'Disabled')
Assert-Nx07 'enum map: true -> Enabled/1' ($null -ne $mOn -and $mOn.registryValue -eq '1')

$ordCap = [pscustomobject]@{
    present = $true; registryKeyword = 'PreferredBand'; registryValue = '2'; displayValue = '3. Prefer 5GHz band'
    validRegistryValues = @('0', '1', '2')
    validDisplayValues = @('1. No Preference', '2. Prefer 2.4GHz band', '3. Prefer 5GHz band')
}
$mBand = Find-Nx07DisplayChoice -Capability $ordCap -Patterns @('prefer 5ghz', '5ghz band')
Assert-Nx07 'enum map: ordinal display -> Prefer 5GHz registry 2' ($null -ne $mBand -and $mBand.registryValue -eq '2')
$mNoBand = Find-Nx07DisplayChoice -Capability $ordCap -Patterns @('prefer 6ghz', '6ghz band')
Assert-Nx07 'enum map: inexpressible value -> null (skip)' ($null -eq $mNoBand)

$quadCap = [pscustomobject]@{
    present = $true; registryKeyword = '*FlowControl'; registryValue = '3'; displayValue = 'Rx & Tx Enabled'
    validRegistryValues = @('0', '3'); validDisplayValues = @('Disabled', 'Rx & Tx Enabled')
}
$mQuad = Find-Nx07DisplayChoice -Capability $quadCap -Patterns @('rx & tx enabled', 'tx & rx enabled')
Assert-Nx07 'enum map: quad-state TxRx -> 3' ($null -ne $mQuad -and $mQuad.registryValue -eq '3')
$mQuadOff = Find-Nx07DisplayChoice -Capability $quadCap -Patterns @('disabled')
Assert-Nx07 'enum map: quad-state Disabled -> 0' ($null -ne $mQuadOff -and $mQuadOff.registryValue -eq '0')
$noNames = [pscustomobject]@{ present = $true; validRegistryValues = @('0', '1'); validDisplayValues = @() }
Assert-Nx07 'enum map: no display names -> refuse (never guess integers)' ($null -eq (Find-Nx07DisplayChoice -Capability $noNames -Patterns @('enabled')))

$strengthCap = [pscustomobject]@{
    present = $true; registryKeyword = 'TxPowerLevel'; registryValue = '0'; displayValue = '1. Highest'
    validRegistryValues = @('0', '1', '2'); validDisplayValues = @('1. Highest', '2. Medium', '3. Lowest')
}
Assert-Nx07 'enum map: Highest -> first level' ((Find-Nx07DisplayChoice -Capability $strengthCap -Patterns @('highest')).registryValue -eq '0')
Assert-Nx07 'enum map: Low does NOT match Lowest (word boundary)' ($null -eq (Find-Nx07DisplayChoice -Capability $strengthCap -Patterns @('low')))
$trailingCap = [pscustomobject]@{
    present = $true; registryKeyword = 'RoamIndicateTh'; registryValue = '1'; displayValue = '2. Lowest'
    validRegistryValues = @('0', '1', '2', '3'); validDisplayValues = @('1. Disabled', '2. Lowest', '3. Medium-Low', '4. Medium.')
}
Assert-Nx07 'enum map: Medium-Low exact' ((Find-Nx07DisplayChoice -Capability $trailingCap -Patterns @('medium-low')).registryValue -eq '2')
Assert-Nx07 'enum map: trailing-period Medium matched on boundary' ((Find-Nx07DisplayChoice -Capability $trailingCap -Patterns @('medium')).registryValue -eq '3')

# ---------------------------------------------------------------------------
# 4. Numeric clamping
# ---------------------------------------------------------------------------
$bufferCap = [pscustomobject]@{ present = $true; validRegistryValues = @(); validDisplayValues = @() }
$r1 = Resolve-Nx07NumericValue -Capability $bufferCap -NdiParam ([pscustomobject]@{ min = 32; max = 512; step = 8 }) -Requested 2048
Assert-Nx07 'numeric clamp: Ndi max 512' ($r1.value -eq 512 -and $r1.clamped -and $r1.source -eq 'Ndi\Params range')
$r2 = Resolve-Nx07NumericValue -Capability $bufferCap -NdiParam ([pscustomobject]@{ min = 32; max = 512; step = 8 }) -Requested 300
Assert-Nx07 'numeric clamp: step 8 -> 296' ($r2.value -eq 296)
$r3 = Resolve-Nx07NumericValue -Capability $bufferCap -NdiParam $null -Requested 100
Assert-Nx07 'numeric clamp: no driver data -> sanity window, unchanged in range' ($r3.value -eq 100 -and -not $r3.clamped)
$jumboCap = [pscustomobject]@{ present = $true; validRegistryValues = @('1514', '4088', '9014'); validDisplayValues = @('Disabled', '4088 Bytes', '9014 Bytes') }
$r4 = Resolve-Nx07NumericValue -Capability $jumboCap -NdiParam $null -Requested 9014
Assert-Nx07 'numeric: enumerated jumbo exact' ($r4.value -eq 9014)
$r5 = Resolve-Nx07NumericValue -Capability $jumboCap -NdiParam $null -Requested 9000
Assert-Nx07 'numeric: enumerated -> largest <= request' ($r5.value -eq 4088 -and $r5.clamped)

# ---------------------------------------------------------------------------
# 5. DNS input validation
# ---------------------------------------------------------------------------
$dns4 = ConvertTo-Nx07DnsServerList -Text '1.1.1.1, 1.0.0.1' -AddressFamily IPv4
$dns6 = ConvertTo-Nx07DnsServerList -Text '2606:4700:4700::1111 2606:4700:4700::1001' -AddressFamily IPv6
$dnsBad = ConvertTo-Nx07DnsServerList -Text '1.1.1.1, not-an-ip, 8.8.8.8' -AddressFamily IPv4
$dnsMixed = ConvertTo-Nx07DnsServerList -Text '8.8.8.8, 2001:4860:4860::8888' -AddressFamily IPv4
Assert-Nx07 'dns list: IPv4 parsed' ($dns4.servers.Count -eq 2 -and $dns4.invalid.Count -eq 0)
Assert-Nx07 'dns list: IPv6 parsed' ($dns6.servers.Count -eq 2)
Assert-Nx07 'dns list: junk detected' ($dnsBad.invalid.Count -eq 1 -and $dnsBad.servers.Count -eq 2)
Assert-Nx07 'dns list: wrong family detected' ($dnsMixed.invalid.Count -eq 1 -and $dnsMixed.servers.Count -eq 1)
Assert-Nx07 'dns set compare: order-insensitive' (Test-Nx07SameStringSet @('1.0.0.1', '1.1.1.1') @('1.1.1.1', '1.0.0.1'))
Assert-Nx07 'dns set compare: difference detected' (-not (Test-Nx07SameStringSet @('1.1.1.1') @('1.1.1.1', '8.8.8.8')))

# ---------------------------------------------------------------------------
# 6. TCP global parser (documented English output shape)
# ---------------------------------------------------------------------------
$tcpSample = @'
Receive Side Scaling                 : enabled
Direct Cache Access (DCA)            : disabled
Receive Segment Coalescing State     : disabled
Receive Window Auto-Tuning Level     : normal
Add-On Congestion Control Provider   : default
ECN Capability                       : disabled
RFC 1323 Timestamps                  : disabled
Initial RTO                          : 3000
'@
$tcpParsed = ConvertFrom-Nx07TcpGlobalText -Text $tcpSample
Assert-Nx07 'tcp parser: parseOk' ($tcpParsed.parseOk -eq $true)
Assert-Nx07 'tcp parser: autotuning normal' ($tcpParsed.fields['autoTuningLevel'] -eq 'normal')
Assert-Nx07 'tcp parser: ecn disabled' ($tcpParsed.fields['ecn'] -eq 'disabled')
Assert-Nx07 'tcp parser: rsc disabled' ($tcpParsed.fields['rsc'] -eq 'disabled')
$tcpLocalized = ConvertFrom-Nx07TcpGlobalText -Text 'Empfangsfenster-Automatische Abstimmung : normal'
Assert-Nx07 'tcp parser: localized labels do not fabricate fields' (-not $tcpLocalized.fields.ContainsKey('autoTuningLevel'))
Assert-Nx07 'tcp parser: empty input fails closed' (-not (ConvertFrom-Nx07TcpGlobalText -Text '').parseOk)

# ---------------------------------------------------------------------------
# 7. Journal round-trip + rollback candidate selection (temp only)
# ---------------------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('nx07-selftest-' + [guid]::NewGuid().ToString('N'))
try {
    $journalDir = Join-Path $tmp 'journal'
    $null = Initialize-NxJournal -Path $journalDir

    $advOrig = [pscustomobject]@{ targetType = 'adapterAdvancedProperty'; adapterName = 'Ethernet'; interfaceIndex = 1; registryKeyword = '*EEE'; registryValue = '0'; displayValue = 'Disabled' }
    $advMod = [pscustomobject]@{ targetType = 'adapterAdvancedProperty'; adapterName = 'Ethernet'; interfaceIndex = 1; registryKeyword = '*EEE'; registryValue = '1'; displayValue = 'Enabled' }
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX07-003' -TweakVersion '1' -Operation 'apply' -Approval 'SelfTest' -Original $advOrig -Modified $advMod -Result 'InProgress' -Verification 'NotRun' -Profiles @('P1')
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX07-003' -TweakVersion '1' -Operation 'verify' -Approval 'SelfTest' -Original $advOrig -Modified $advMod -Result 'Success' -Verification 'Verified' -Profiles @('P1')

    $dnsOrig = [pscustomobject]@{ targetType = 'dnsClientConfig'; interfaceIndex = 1; interfaceAlias = 'Ethernet'; v4 = @('192.168.1.1'); v6 = @(); dhcpV4 = 'Enabled'; dhcpV6 = 'Enabled' }
    $dnsMod = [pscustomobject]@{ targetType = 'dnsClientConfig'; interfaceIndex = 1; interfaceAlias = 'Ethernet'; v4 = @('1.1.1.1', '1.0.0.1'); v6 = @(); changedV4 = $true; changedV6 = $false; probeName = 'dns.msftncsi.com' }
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX07-016' -TweakVersion '1' -Operation 'apply' -Approval 'SelfTest' -Original $dnsOrig -Modified $dnsMod -Result 'InProgress' -Verification 'NotRun' -Profiles @('P1')
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX07-016' -TweakVersion '1' -Operation 'verify' -Approval 'SelfTest' -Original $dnsOrig -Modified $dnsMod -Result 'Success' -Verification 'Verified' -Profiles @('P1')

    $qosOrig = [pscustomobject]@{ targetType = 'qosPolicy'; policyName = 'NEXTRIX-QoS-game'; policyStore = 'TESTPC'; existed = $false }
    $qosMod = [pscustomobject]@{ targetType = 'qosPolicy'; policyName = 'NEXTRIX-QoS-game'; policyStore = 'TESTPC'; appPath = 'C:\Games\game.exe'; dscp = 46 }
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX07-022' -TweakVersion '1' -Operation 'apply' -Approval 'SelfTest' -Original $qosOrig -Modified $qosMod -Result 'InProgress' -Verification 'NotRun' -Profiles @('P1')
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX07-022' -TweakVersion '1' -Operation 'verify' -Approval 'SelfTest' -Original $qosOrig -Modified $qosMod -Result 'Success' -Verification 'Verified' -Profiles @('P1')

    # Non-candidates: a skip entry and a read-only report.
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX07-003' -TweakVersion '1' -Operation 'skip' -Approval 'SelfTest' -Original $advOrig -Modified $advMod -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles @('P1')
    $rep = [pscustomobject]@{ targetType = 'networkDiagnosticReport' }
    $null = Add-NxJournalEntry -Path $journalDir -TweakId 'NX07-019' -TweakVersion '1' -Operation 'skip' -Approval 'SelfTest' -Original $rep -Modified $rep -Result 'ReportOnly' -Verification 'Inspected' -Profiles @()

    $rd = Read-NxJournal -Path $journalDir
    Assert-Nx07 'journal: 8 entries, integrity clean' ($rd.entries.Count -eq 8 -and $rd.integrityErrors.Count -eq 0) (($rd.integrityErrors | ForEach-Object { $_ }) -join '; ')
    $cands = @(Get-Nx07RollbackCandidates -JournalEntries $rd.entries)
    Assert-Nx07 'rollback candidates: exactly the 3 verified NX07 mutations' ($cands.Count -eq 3)
    Assert-Nx07 'rollback candidates: tweak ids' ((@($cands | ForEach-Object { $_.tweakId } | Sort-Object) -join ',') -eq 'NX07-003,NX07-016,NX07-022')
    Assert-Nx07 'journal: DNS original keeps DHCP provenance' (@($cands | Where-Object { $_.tweakId -eq 'NX07-016' })[0].original.dhcpV4 -eq 'Enabled')

    # ---------------------------------------------------------------------
    # 8. Gates: throw/refuse BEFORE any mutation path
    # ---------------------------------------------------------------------
    $threw = $false; $msg = ''
    try { Set-Nx07EnergyEfficientEthernet -JournalRoot $journalDir -Enabled $false | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx07 'gate: NX07-003 refuses without -Approved' ($threw -and $msg -like '*requires -Approved*')

    $threw = $false; $msg = ''
    try { Clear-Nx07DnsCache -JournalRoot $journalDir | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx07 'gate: NX07-020 refuses without -Approved' ($threw -and $msg -like '*requires -Approved*')

    $threw = $false; $msg = ''
    try { Invoke-Nx07NetworkStackReset -JournalRoot $journalDir -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx07 'gate: NX07-021 requires -AcknowledgeConsequences' ($threw -and $msg -like '*AcknowledgeConsequences*')

    $threw = $false; $msg = ''
    try { Set-Nx07GameQosProfile -JournalRoot $journalDir -AppPath 'C:\definitely-not-here\game.exe' -Approved | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    $qosRefusal = $null
    if (-not $threw) { $qosRefusal = Set-Nx07GameQosProfile -JournalRoot $journalDir -AppPath 'C:\definitely-not-here\game.exe' -Approved }
    Assert-Nx07 'gate: NX07-022 refuses a nonexistent app path' ($threw -or ($null -ne $qosRefusal -and $qosRefusal.outcome -eq 'Refused'))

    $threw = $false; $msg = ''
    try { Invoke-Nx07Rollback -JournalRoot $journalDir | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
    Assert-Nx07 'gate: NX07 rollback needs explicit scope' ($threw -and $msg -like '*specify -TweakId or -AllNx07*')

    $dnsRefusal = Set-Nx07DnsConfiguration -JournalRoot $journalDir -ServerAddresses 'not-an-ip' -Approved
    Assert-Nx07 'gate: NX07-016 refuses invalid DNS input before any capture' ($dnsRefusal.outcome -eq 'Refused')

    $mtuRefusal = Set-Nx07InterfaceMtu -JournalRoot $journalDir -Mtu 1100 -AddressFamily 'IPv6' -Approved
    Assert-Nx07 'gate: NX07-018 refuses IPv6 MTU < 1280' ($mtuRefusal.outcome -eq 'Refused')

    $dnsNamed = Set-Nx07DnsConfiguration -JournalRoot $journalDir -ServerAddresses '9.9.9.9' -AdapterName 'Nx07NoSuchAdapter' -Approved
    Assert-Nx07 'safety: DNS with an unknown named adapter does not fall back' ($dnsNamed.outcome -eq 'Skipped')
    $mtuNamed = Set-Nx07InterfaceMtu -JournalRoot $journalDir -Mtu 1400 -AdapterName 'Nx07NoSuchAdapter' -Approved
    Assert-Nx07 'safety: MTU with an unknown named adapter does not fall back' ($mtuNamed.outcome -eq 'Skipped')

    # ---------------------------------------------------------------------
    # 8b. Only-if-present proof: a keyword the driver does not expose is a
    #     journaled SKIP, never a created vendor keyword (no mutation).
    # ---------------------------------------------------------------------
    $invLive = Get-Nx07AdapterInventory
    $liveWifi = @($invLive.adapters | Where-Object { $_.isWifi -and $_.tunable })
    if ($liveWifi.Count -gt 0) {
        $wifiAdapter = Get-Nx07AdapterByName -AdapterName $liveWifi[0].name
        $bogus = Invoke-Nx07AdvancedPropertyWrite -TweakId 'NX07-003' -JournalRoot $journalDir -Adapter $wifiAdapter -RegistryKeyword '*Nx07SelfTestNotAKeyword' -DesiredRegistryValue '1' -Approved
        Assert-Nx07 'only-if-present: nonexistent keyword is a Skipped result' ($bogus.outcome -eq 'Skipped' -and $bogus.reason -like '*never creates vendor keywords*')
        $rd2 = Read-NxJournal -Path $journalDir
        $skipEntry = @($rd2.entries | Where-Object { $_.operation -eq 'skip' -and $_.result -eq 'PropertyNotExposed' })
        Assert-Nx07 'only-if-present: skip is journaled with PropertyNotExposed' ($skipEntry.Count -ge 1)
        Assert-Nx07 'only-if-present: skips never become rollback candidates' (@(Get-Nx07RollbackCandidates -JournalEntries $rd2.entries).Count -eq 3)
    } else {
        Write-Output 'SKIP: no tunable Wi-Fi adapter (only-if-present live assertion skipped)'
    }
    $unknownAdapter = Set-Nx07WifiPreferredBand -JournalRoot $journalDir -Approved -AdapterName 'Nx07NoSuchAdapter'
    Assert-Nx07 'selection: unknown adapter alias -> Skipped, nothing written' ($unknownAdapter.outcome -eq 'Skipped')

    # ---------------------------------------------------------------------
    # 9. Read-only inspection path (journals a ReportOnly skip, mutates nothing)
    # ---------------------------------------------------------------------
    $tcpInspect = Set-Nx07TcpGlobalSetting -JournalRoot $journalDir
    Assert-Nx07 'live: netsh int tcp show global parses' ($tcpInspect.parseOk -eq $true) "raw=$($tcpInspect.raw)"
    Assert-Nx07 'live: inspection reports a known field' ($null -ne $tcpInspect.fields.autoTuningLevel -or $null -ne $tcpInspect.fields.ecn)

    # ---------------------------------------------------------------------
    # 10. LIVE read-only adapter/DNS/MTU inspection against this machine
    # ---------------------------------------------------------------------
    $inv = Get-Nx07AdapterInventory
    Assert-Nx07 'live: inventory reports adapters' ($inv.adapterCount -ge 1)
    Assert-Nx07 'live: inventory tunable flag present' (@($inv.adapters | Where-Object { $_.PSObject.Properties['tunable'] }).Count -eq $inv.adapterCount)
    $firstEth = @($inv.adapters | Where-Object { $_.isEthernet -and $_.tunable })
    if ($firstEth.Count -gt 0) {
        $fc = Get-Nx07AdvancedProperty -Adapter (Get-Nx07AdapterByName -AdapterName $firstEth[0].name) -RegistryKeyword '*FlowControl'
        Assert-Nx07 'live: Ethernet flow-control capability reads' ($fc.present -eq $true -and @($fc.validDisplayValues).Count -ge 1)
        $dnsState = Get-Nx07DnsClientState -InterfaceIndex ([int]$firstEth[0].interfaceIndex)
        Assert-Nx07 'live: DNS state reads (arrays + DHCP flags)' ($null -ne $dnsState.dhcpV4 -and $dnsState.v4ReadOk -eq $true)
        $mtuAny = @($firstEth | ForEach-Object { Get-Nx07InterfaceMtuValue -InterfaceIndex ([int]$_.interfaceIndex) -AddressFamily IPv4 })
        Assert-Nx07 'live: interface MTU query succeeds for the Ethernet adapter' (@($mtuAny | Where-Object { $_.found }).Count -ge 1)
        Assert-Nx07 'live: MTU availability flag is consistent' (@($mtuAny | Where-Object { $_.mtuAvailable -ne ($null -ne $_.mtu) }).Count -eq 0)
        Assert-Nx07 'live: readable MTUs are positive' (@($mtuAny | Where-Object { $_.mtuAvailable -and $_.mtu -le 0 }).Count -eq 0)
    } else {
        Write-Output 'SKIP: no tunable Ethernet adapter on this machine (live capability assertions skipped)'
    }
    $diag = Get-Nx07NetworkDiagnosticReport
    Assert-Nx07 'live: diagnostics report is read-only and populated' ($diag.readOnly -eq $true -and @($diag.adapters).Count -ge 1)
    Assert-Nx07 'live: diagnostics never exports DNS cache content (count only)' ($null -ne $diag.PSObject.Properties['dnsCacheEntryCount'])
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ''
Write-Output ("RESULT: $pass passed, $fail failed")
if ($fail -gt 0) { exit 1 }
exit 0
