#Requires -Version 5.1
<#
    NX07.ps1 - NEXTRIX Network Optimization functions (category NX07, entries NX07-001..022).

    MUTATION SURFACE (declared per SECURITY_POLICY.md Section 4; every mutation is
    journaled first, verified by re-read, and restorable by Invoke-Nx07Rollback):
      - Adapter advanced properties via the DOCUMENTED cmdlets
        Get-/Set-NetAdapterAdvancedProperty (driver-exposed keywords only; the
        function never creates a vendor keyword - a missing keyword is a skip,
        never an error).
      - Adapter power management via Get-/Set-NetAdapterPowerManagement and
        Enable-/Disable-NetAdapterPowerManagement (documented cmdlet surface).
      - DNS client server addresses via Get-/Set-DnsClientServerAddress, optional
        DoH registration via Add-/Get-/Remove-DnsClientDohServerAddress.
      - TCP global parameters via `netsh int tcp show global` (read) and
        `netsh int tcp set global` (write).
      - Per-interface MTU via Get-/Set-NetIPInterface.
      - DNS client cache via Clear-DnsClientCache.
      - Winsock/TCP-IP stack reset via `netsh winsock reset` / `netsh int ip reset`
        ONLY inside the consent-gated TROUBLESHOOTING entry NX07-021.
      - Per-application QoS policies via New-/Get-/Remove-NetQosPolicy (policy
        names NEXTRIX creates only).
      - Report/backup files under a caller-chosen output folder only.
      Nothing else. No adapter is ever disabled/enabled automatically; no IPv6
      removal; no hosts-file writes; no firewall reset.

    NIC DISCIPLINE (docs/RESEARCH_RECONCILIATION.md adopt register #8):
      1. ADAPTER-INSTANCE-PARAMETERIZED: every adapter-level function accepts
         -AdapterName / -InterfaceIndex and otherwise enumerates eligible adapters
         at runtime. Nothing is hardcoded per vendor or per machine.
      2. CAPABILITY PROBING: a keyword is written only after Get-NetAdapterAdvancedProperty
         confirms the driver exposes it; numeric values are clamped to the driver's
         Ndi\Params min/max/step (or to its enumerated value list); enumerations are
         mapped by DISPLAY NAME, never by a guessed integer meaning.
      3. VIRTUAL/VPN/WAN EXCLUSION: HardwareInterface=false, Virtual=true and the
         vendor/VPN term list are excluded from tuning (reported, not touched).
      4. WI-FI EXCLUSION FROM ETHERNET TUNING: Get-NetAdapter PhysicalMediaType
         'Native 802.11' is the discriminator (mirrors the r1 *PhysicalMediaType 9/16
         rule); Ethernet-only entries refuse a Wi-Fi adapter, and the Wi-Fi entries
         refuse a non-Wi-Fi adapter.
      5. UNKNOWN BENEFIT LIST: LSO, Flow Control and checksum offloads stay ADVANCED,
         preset-excluded, and their entries state the controversy in plain text.

    NO PERFORMANCE CLAIMS: this module contains no latency/FPS/throughput claim.
    Every configuration intent is described as intent; outcomes require owner
    evidence at E2+ per TWEAK_CLASSIFICATION.md Section 4.

    PARSER HONESTY: the `netsh` parsers target the documented English output. An
    unparseable capture fails CLOSED (no capture = no mutation).

    Required core modules: NxJournal.ps1 (journal + manifest). Rollback entry point:
    Invoke-Nx07Rollback (delegated to automatically by NxRollback.ps1 for the
    non-registry target types this category journals).
#>

# ---------------------------------------------------------------------------
# A. Constants
# ---------------------------------------------------------------------------

# Network adapters class key (documented device setup class). Read-only access is
# used to probe Ndi\Params capability; NEXTRIX never writes this key directly -
# every configuration write goes through the documented NetAdapter cmdlets.
$script:Nx07NicClassKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002bE10318}'

# Virtual / VPN / WAN / debug adapters are never tuned (r4 network.bat term list +
# r4 SynToolkit PhysicalAdapter filter). Matching is case-insensitive substring on
# Name/InterfaceDescription/DriverDescription.
$script:Nx07VirtualTerms = @(
    'microsoft kernel debug', 'kernel debug', 'wan miniport', 'microsoft wi-fi direct',
    'wi-fi direct virtual', 'virtual', 'loopback', 'bluetooth', 'teredo', 'tunnel',
    'tap-', 'tap adapter', 'openvpn', 'wireguard', 'wintun', 'vmware', 'virtualbox',
    'hyper-v', 'npcap', 'ras async', 'async adapter', 'pppoe', 'ppp ', 'zerotier',
    'hamachi', 'tailscale', 'nordlynx', 'isatap', '6to4', 'ip-https', 'sstp', 'l2tp',
    'pptp', 'ikev2', 'network monitor', 'legacy'
)

# Wi-Fi / Ethernet discriminators (Get-NetAdapter PhysicalMediaType, documented
# values; r1 excludes Wi-Fi via *PhysicalMediaType 9/16 before Ethernet tuning).
$script:Nx07WifiMediaType    = 'Native 802.11'
$script:Nx07EthernetMediaType = '802.3'
$script:Nx07WanMediaType     = 'WirelessWan'

# Keyword candidate lists. The FIRST keyword the driver exposes wins; nothing is
# invented. Prefix forms ('*Keyword') are the standardized INF keywords; the
# non-prefixed forms are vendor exposures observed on real drivers (e.g. MediaTek
# exposes 'PreferredBand' / 'BWSelection5G' / 'RoamIndicateTh' / 'TxPowerLevel').
$script:Nx07WifiKeywordCandidates = @{
    RoamingAggressiveness = @('*RoamingAggressiveness', 'RoamingAggressiveness', 'RoamIndicateTh', 'RoamingLevel', 'RoamingAggressivenessLevel')
    PreferredBand         = @('*PreferredBand', 'PreferredBand', 'BandSelection')
    ChannelWidth24        = @('*ChannelWidth24', 'BWSelection24G', '*ChannelWidth', 'ChannelWidth')
    ChannelWidth5         = @('*ChannelWidth52', 'BWSelection5G', '*ChannelWidth', 'ChannelWidth')
    TransmitPower         = @('*TransmitPower', 'TxPowerLevel', 'TransmitPowerLevel', 'TransmitPower')
}

$script:Nx07ChecksumKeywords = @(
    '*IPChecksumOffloadIPv4',
    '*TCPChecksumOffloadIPv4',
    '*TCPChecksumOffloadIPv6',
    '*UDPChecksumOffloadIPv4',
    '*UDPChecksumOffloadIPv6'
)

$script:Nx07DohTemplates = @(
    @{ match = @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001'); template = 'https://cloudflare-dns.com/dns-query'; provider = 'Cloudflare' },
    @{ match = @('8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844'); template = 'https://dns.google/dns-query'; provider = 'Google' },
    @{ match = @('9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9'); template = 'https://dns.quad9.net/dns-query'; provider = 'Quad9' },
    @{ match = @('94.140.14.14', '94.140.15.15'); template = 'https://dns.adguard-dns.com/dns-query'; provider = 'AdGuard' },
    @{ match = @('208.67.222.222', '208.67.220.220'); template = 'https://doh.opendns.com/dns-query'; provider = 'OpenDNS' }
)

$script:Nx07DefaultDnsProbe = 'dns.msftncsi.com'

# ---------------------------------------------------------------------------
# B. Small shared helpers (names are NX07-scoped to avoid collisions with other
#    category modules loaded into the same session).
# ---------------------------------------------------------------------------

function Get-Nx07TruncatedText {
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$Max = 400)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return ($Text.Substring(0, $Max) + '...[truncated]')
}

function ConvertTo-Nx07ValueString {
    # Get-NetAdapterAdvancedProperty returns RegistryValue as a collection even for
    # single-valued keywords. Normalize to the exact string a driver compares.
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @()
        foreach ($v in $Value) { $parts += [string]$v }
        return ($parts -join ',')
    }
    return [string]$Value
}

function ConvertTo-Nx07NormalizedDisplay {
    # '3. Prefer 5GHz band' -> 'prefer 5ghz band' ; ordinal prefixes are display
    # decoration, never registry semantics.
    param([AllowNull()][AllowEmptyString()][string]$Display)
    if ([string]::IsNullOrWhiteSpace($Display)) { return '' }
    $s = $Display.Trim()
    $s = [regex]::Replace($s, '^\s*\d+\s*[\.\)]\s*', '')
    $s = $s.ToLowerInvariant()
    $s = [regex]::Replace($s, '\s+', ' ')
    $s = $s.Trim()
    $s = $s.TrimEnd('.', ' ')
    return $s
}

function ConvertTo-Nx07MaskedMac {
    # MAC addresses are device identifiers: keep the vendor OUI only (privacy).
    param([AllowNull()][AllowEmptyString()][string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return '' }
    $parts = $Mac -split '[-:]'
    if ($parts.Count -ge 3) { return ($parts[0..2] -join '-') + '-XX-XX-XX' }
    return 'XX'
}

function Invoke-Nx07Netsh {
    # PS 5.1: stderr lines become ErrorRecords promoted to terminating errors under
    # 'Stop' - capture under 'Continue' (same pattern as Invoke-NxPowerCfg).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$NetshArgs,
        [switch]$RequireSuccess
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = $null; $code = -1
    try {
        $raw = & netsh.exe @NetshArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -ne $raw) { foreach ($l in @($raw)) { $lines.Add([string]$l) } }
    $res = [pscustomobject]@{
        args     = ('netsh ' + ($NetshArgs -join ' '))
        exitCode = $code
        output   = ($lines -join "`n")
        ok       = ($code -eq 0)
    }
    if ($RequireSuccess -and -not $res.ok) {
        throw "netsh $($NetshArgs -join ' ') failed (exit $($res.exitCode)): $(Get-Nx07TruncatedText $res.output)"
    }
    return $res
}

function Assert-Nx07JournalReady {
    # Journal-first invariant: no mutation without an initialized, capture-Complete
    # journal (adopt register #2).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JournalRoot)
    $state = Read-NxManifest -Path $JournalRoot
    if (-not $state.present) {
        throw "journal not initialized at '$JournalRoot' - refusing to mutate (journal-first invariant; run Invoke-NxPreFlight / NX16-004 first)"
    }
    if ([string]$state.manifest.captureStatus -ne 'Complete') {
        throw "journal captureStatus is '$($state.manifest.captureStatus)' - destructive steps refuse unless capture is Complete"
    }
}

function Resolve-Nx07ReportPath {
    # Caller-chosen output folder only; never an implicit system location, never an
    # overwrite. (Same contract as NX09's resolver, kept module-local so NX07 loads
    # without NX09.)
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$OutputFolder,
        [Parameter(Mandatory)][string]$FileName
    )
    if ([string]::IsNullOrWhiteSpace($OutputFolder)) {
        throw "an output folder must be chosen (reports are never written to implicit system locations)"
    }
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $OutputFolder -PathType Container)) {
        throw "path '$OutputFolder' exists but is not a folder"
    }
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext = [IO.Path]::GetExtension($FileName)
    if ([string]::IsNullOrEmpty($ext)) { $ext = '.json' }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $full = Join-Path $OutputFolder ("$base-$stamp$ext")
    if (Test-Path -LiteralPath $full) {
        throw "report file '$full' already exists - refusing to overwrite (timestamped names make this rare)"
    }
    return [pscustomobject]@{ folder = $OutputFolder; filePath = $full }
}

# ---------------------------------------------------------------------------
# C. Adapter enumeration, classification and selection (read-only)
# ---------------------------------------------------------------------------

function Get-Nx07AllAdapters {
    [CmdletBinding()]
    param()
    try { return @(Get-NetAdapter -ErrorAction Stop) } catch { return @() }
}

function Get-Nx07AdapterByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AdapterName)
    try { return (Get-NetAdapter -Name $AdapterName -ErrorAction Stop) } catch { return $null }
}

function Test-Nx07VirtualAdapter {
    # True = never tune (virtual/VPN/WAN/debug adapters).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Adapter)
    $hay = @(
        [string]$Adapter.Name,
        [string]$Adapter.InterfaceDescription,
        [string]$Adapter.DriverDescription
    ) -join ' '
    $hay = $hay.ToLowerInvariant()
    foreach ($term in $script:Nx07VirtualTerms) {
        if ($hay.Contains($term)) { return $true }
    }
    $virtualProp = $Adapter.PSObject.Properties['Virtual']
    if ($null -ne $virtualProp -and [bool]$virtualProp.Value) { return $true }
    $hwProp = $Adapter.PSObject.Properties['HardwareInterface']
    if ($null -ne $hwProp -and -not [bool]$hwProp.Value) { return $true }
    return $false
}

function Get-Nx07AdapterClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Adapter)
    $media = [string]$Adapter.PhysicalMediaType
    $isWifi = ($media -eq $script:Nx07WifiMediaType)
    $isEthernet = ($media -eq $script:Nx07EthernetMediaType)
    $isWan = ($media -eq $script:Nx07WanMediaType)
    $isVirtual = Test-Nx07VirtualAdapter -Adapter $Adapter
    $eligible = $false; $reason = ''
    if ($isVirtual) { $reason = 'virtual/VPN/debug adapter (excluded from tuning)' }
    elseif ($isWan) { $reason = 'wireless WAN adapter (excluded from tuning)' }
    elseif (-not ($isWifi -or $isEthernet)) { $reason = "unresolved physical media type '$media' (excluded: cannot prove it is Ethernet or Wi-Fi)" }
    else { $eligible = $true }
    return [pscustomobject]@{
        adapter         = $Adapter
        name            = [string]$Adapter.Name
        interfaceIndex  = [int]$Adapter.InterfaceIndex
        interfaceGuid   = [string]$Adapter.InterfaceGuid
        interfaceDesc   = [string]$Adapter.InterfaceDescription
        pnpDeviceId     = [string]$Adapter.PnPDeviceID
        status          = [string]$Adapter.Status
        mediaType       = $media
        linkSpeed       = [string]$Adapter.LinkSpeed
        isWifi          = $isWifi
        isEthernet      = $isEthernet
        isVirtual       = $isVirtual
        eligible        = $eligible
        reason          = $reason
    }
}

function Get-Nx07AdapterSelection {
    <#
        Resolves the adapters a tweak may act on:
          - AdapterName / InterfaceIndex pin an explicit instance;
          - otherwise ALL eligible adapters are returned (runtime enumeration);
          - Require='Ethernet' drops Wi-Fi adapters (Ethernet-only tuning);
            Require='Wifi' drops everything that is not Wi-Fi.
        Ineligible adapters are reported in .notices, never acted on.
    #>
    [CmdletBinding()]
    param(
        [string]$AdapterName = '',
        [int]$InterfaceIndex = 0,
        [ValidateSet('Any', 'Ethernet', 'Wifi')][string]$Require = 'Any'
    )
    $all = @(Get-Nx07AllAdapters)
    $classes = @($all | ForEach-Object { Get-Nx07AdapterClassification -Adapter $_ })
    $notices = New-Object System.Collections.Generic.List[object]
    foreach ($c in $classes) {
        if (-not $c.eligible) { $notices.Add([pscustomobject]@{ adapter = $c.name; reason = $c.reason }) }
    }
    $selected = @($classes | Where-Object { $_.eligible })
    if ($AdapterName) {
        $selected = @($selected | Where-Object { $_.name -eq $AdapterName })
        if ($selected.Count -eq 0) {
            $known = @($classes | Where-Object { $_.name -eq $AdapterName })
            if ($known.Count -gt 0) { $notices.Add([pscustomobject]@{ adapter = $AdapterName; reason = $known[0].reason }) }
            else { $notices.Add([pscustomobject]@{ adapter = $AdapterName; reason = 'adapter alias not found on this machine' }) }
        }
    }
    if ($InterfaceIndex -gt 0) {
        $selected = @($selected | Where-Object { $_.interfaceIndex -eq $InterfaceIndex })
        if ($selected.Count -eq 0) {
            $known = @($classes | Where-Object { $_.interfaceIndex -eq $InterfaceIndex })
            if ($known.Count -gt 0) { $notices.Add([pscustomobject]@{ adapter = $known[0].name; reason = $known[0].reason }) }
            else { $notices.Add([pscustomobject]@{ adapter = "ifIndex $InterfaceIndex"; reason = 'interface index not found on this machine' }) }
        }
    }
    if ($Require -eq 'Ethernet') {
        $rejected = @($selected | Where-Object { -not $_.isEthernet })
        foreach ($r in $rejected) { $notices.Add([pscustomobject]@{ adapter = $r.name; reason = "not Ethernet (PhysicalMediaType '$($r.mediaType)') - this entry is Ethernet-only" }) }
        $selected = @($selected | Where-Object { $_.isEthernet })
    }
    if ($Require -eq 'Wifi') {
        $rejected = @($selected | Where-Object { -not $_.isWifi })
        foreach ($r in $rejected) { $notices.Add([pscustomobject]@{ adapter = $r.name; reason = "not Wi-Fi (PhysicalMediaType '$($r.mediaType)') - this entry is Wi-Fi-only" }) }
        $selected = @($selected | Where-Object { $_.isWifi })
    }
    return [pscustomobject]@{
        targets   = @($selected)
        notices   = @($notices.ToArray())
        allCount  = $classes.Count
        eligibleCount = @($classes | Where-Object { $_.eligible }).Count
    }
}

# ---------------------------------------------------------------------------
# D. Capability probing (read-only): driver-exposed keyword, enumerated values,
#    Ndi\Params numeric range.
# ---------------------------------------------------------------------------

function Find-Nx07AdapterClassKey {
    # Resolves the NIC class subkey for an adapter GUID (NetCfgInstanceId match).
    # Per-subkey fault tolerance: WAN Miniport class keys deny reads to users.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InterfaceGuid)
    if ([string]::IsNullOrWhiteSpace($InterfaceGuid)) { return $null }
    if (-not (Test-Path -LiteralPath $script:Nx07NicClassKey)) { return $null }
    $subs = @(Get-ChildItem -LiteralPath $script:Nx07NicClassKey -ErrorAction SilentlyContinue)
    foreach ($sub in $subs) {
        if ($sub.PSChildName -notmatch '^\d{4}$') { continue }
        try {
            $props = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction Stop
            if ([string]$props.NetCfgInstanceId -eq $InterfaceGuid) { return $sub.PSPath }
        } catch { continue }
    }
    return $null
}

function Get-Nx07NdiParam {
    # Read-only Ndi\Params\<Keyword> range probe: type, min, max, step, default.
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ClassKeyPath,
        [Parameter(Mandatory)][string]$RegistryKeyword
    )
    if ([string]::IsNullOrWhiteSpace($ClassKeyPath)) { return $null }
    $paramPath = Join-Path $ClassKeyPath ("Ndi\Params\" + $RegistryKeyword)
    if (-not (Test-Path -LiteralPath $paramPath)) { return $null }
    try { $v = Get-ItemProperty -LiteralPath $paramPath -ErrorAction Stop } catch { return $null }
    $min = $null; $max = $null; $step = $null; $default = $null; $type = $null; $desc = $null
    foreach ($p in $v.PSObject.Properties) {
        switch ($p.Name.ToLowerInvariant()) {
            'min' { $min = $p.Value }
            'max' { $max = $p.Value }
            'step' { $step = $p.Value }
            'default' { $default = $p.Value }
            'type' { $type = $p.Value }
            'paramdesc' { $desc = $p.Value }
        }
    }
    $asInt = {
        param($x)
        if ($null -eq $x) { return $null }
        $n = 0
        if ([int]::TryParse([string]$x, [ref]$n)) { return $n }
        return $null
    }
    return [pscustomobject]@{
        path          = $paramPath
        keyword       = $RegistryKeyword
        type          = $(if ($null -ne $type) { [string]$type } else { $null })
        paramDesc     = $(if ($null -ne $desc) { [string]$desc } else { $null })
        defaultValue  = $(if ($null -ne $default) { [string]$default } else { $null })
        min           = (& $asInt $min)
        max           = (& $asInt $max)
        step          = (& $asInt $step)
    }
}

function Get-Nx07AdvancedProperty {
    <#
        Capability + current value of ONE driver keyword on ONE adapter.
        present=$false means the driver does not expose the keyword: callers MUST
        skip (never create it).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)][string]$RegistryKeyword
    )
    $p = $null
    try {
        $p = Get-NetAdapterAdvancedProperty -Name ([string]$Adapter.Name) -RegistryKeyword $RegistryKeyword -ErrorAction Stop
    } catch { $p = $null }
    if ($null -eq $p) {
        return [pscustomobject]@{
            present = $false; registryKeyword = $RegistryKeyword; displayName = ''; registryValue = ''
            displayValue = ''; validRegistryValues = @(); validDisplayValues = @()
        }
    }
    $validReg = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($p.ValidRegistryValues)) { if ($null -ne $v) { $validReg.Add((ConvertTo-Nx07ValueString $v)) } }
    $validDisp = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($p.ValidDisplayValues)) { if ($null -ne $v) { $validDisp.Add([string]$v) } }
    return [pscustomobject]@{
        present             = $true
        registryKeyword     = [string]$p.RegistryKeyword
        displayName         = [string]$p.DisplayName
        registryValue       = (ConvertTo-Nx07ValueString $p.RegistryValue)
        displayValue        = [string]$p.DisplayValue
        validRegistryValues = @($validReg.ToArray())
        validDisplayValues  = @($validDisp.ToArray())
    }
}

function Get-Nx07FirstPresentKeyword {
    # First driver-exposed keyword from an ordered candidate list (capability-honest
    # vendor coverage), with the probe trail for the report.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)][string[]]$CandidateKeywords
    )
    $probed = New-Object System.Collections.Generic.List[string]
    foreach ($kw in $CandidateKeywords) {
        $cap = Get-Nx07AdvancedProperty -Adapter $Adapter -RegistryKeyword $kw
        $probed.Add("$kw=$(if ($cap.present) { 'present' } else { 'absent' })")
        if ($cap.present) {
            return [pscustomobject]@{ found = $true; keyword = $kw; capability = $cap; probed = $probed.ToArray() }
        }
    }
    return [pscustomobject]@{ found = $false; keyword = $null; capability = $null; probed = $probed.ToArray() }
}

# ---------------------------------------------------------------------------
# E. Value resolution (display-name mapping + driver-range clamping)
# ---------------------------------------------------------------------------

function Find-Nx07DisplayChoice {
    <#
        Maps requested friendly names onto the driver's enumerated values by
        comparing NORMALIZED DISPLAY NAMES (never guessed integers). Exact matches
        win over containment; the returned registry value comes from the parallel
        ValidRegistryValues array. Returns $null when the driver cannot express the
        request - callers then SKIP with the driver's value list in the reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Capability,
        [Parameter(Mandatory)][string[]]$Patterns
    )
    $displays = @($Capability.validDisplayValues)
    $regs = @($Capability.validRegistryValues)
    if ($displays.Count -eq 0) { return $null }
    $normDisplays = @($displays | ForEach-Object { ConvertTo-Nx07NormalizedDisplay ([string]$_) })
    $patternsNorm = @($Patterns | ForEach-Object { ConvertTo-Nx07NormalizedDisplay ([string]$_) })
    # Pass 1: exact display-name equality.
    for ($i = 0; $i -lt $normDisplays.Count; $i++) {
        foreach ($p in $patternsNorm) {
            if ($p -and $normDisplays[$i] -eq $p) {
                $reg = $null
                if ($i -lt $regs.Count) { $reg = $regs[$i] }
                if ([string]::IsNullOrEmpty($reg)) { continue }
                return [pscustomobject]@{ registryValue = $reg; displayValue = $displays[$i]; matchedPattern = $p }
            }
        }
    }
    # Pass 2: word-boundary containment (friendly names carry qualifiers such as
    # 'Enabled (recommended)' or a trailing period). A plain substring test would
    # let 'low' match 'lowest' and invert a strength request, so the pattern must
    # sit on a token boundary.
    for ($i = 0; $i -lt $normDisplays.Count; $i++) {
        foreach ($p in $patternsNorm) {
            if (-not $p) { continue }
            $escaped = [regex]::Escape($p)
            $rx = '(^|[\s\(\),;\/])' + $escaped + '($|[\s\(\),;\/])'
            if ($normDisplays[$i] -match $rx) {
                $reg = $null
                if ($i -lt $regs.Count) { $reg = $regs[$i] }
                if ([string]::IsNullOrEmpty($reg)) { continue }
                return [pscustomobject]@{ registryValue = $reg; displayValue = $displays[$i]; matchedPattern = $p }
            }
        }
    }
    return $null
}

function Get-Nx07BooleanPatterns {
    param([Parameter(Mandatory)][bool]$Desired)
    if ($Desired) { return @('enabled', 'enable', 'on') }
    return @('disabled', 'disable', 'off')
}

function Resolve-Nx07NumericValue {
    <#
        Clamps a requested numeric value to what the driver documents:
          1. the driver's enumerated numeric values (largest value <= request);
          2. otherwise Ndi\Params min/max/step;
          3. otherwise the NEXTRIX absolute sanity window [32..8192].
        Every clamp is reported; nothing is silently out of range.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Capability,
        [AllowNull()]$NdiParam,
        [Parameter(Mandatory)][int]$Requested,
        [int]$AbsoluteMin = 32,
        [int]$AbsoluteMax = 8192
    )
    $numericValid = New-Object System.Collections.Generic.List[int]
    foreach ($v in @($Capability.validRegistryValues)) {
        $n = 0
        if ([int]::TryParse([string]$v, [ref]$n)) { $numericValid.Add($n) }
    }
    if ($numericValid.Count -gt 0) {
        $sorted = @($numericValid | Sort-Object)
        $candidate = $sorted[0]
        foreach ($v in $sorted) { if ($v -le $Requested) { $candidate = $v } }
        return [pscustomobject]@{
            value = [int]$candidate; clamped = ([int]$candidate -ne $Requested)
            rangeMin = [int]$sorted[0]; rangeMax = [int]$sorted[$sorted.Count - 1]
            source = 'driver-enumerated values'
        }
    }
    $min = $AbsoluteMin; $max = $AbsoluteMax; $step = $null; $source = 'NEXTRIX sanity window'
    if ($null -ne $NdiParam) {
        if ($null -ne $NdiParam.min) { $min = [int]$NdiParam.min; $source = 'Ndi\Params range' }
        if ($null -ne $NdiParam.max) { $max = [int]$NdiParam.max; $source = 'Ndi\Params range' }
        if ($null -ne $NdiParam.step -and [int]$NdiParam.step -gt 1) { $step = [int]$NdiParam.step }
        if ($min -lt $AbsoluteMin) { $min = $AbsoluteMin }
        if ($max -gt $AbsoluteMax) { $max = $AbsoluteMax }
    }
    if ($min -gt $max) { $min = $AbsoluteMin; $max = $AbsoluteMax; $source = 'NEXTRIX sanity window (driver range unusable)' }
    $value = $Requested
    if ($value -lt $min) { $value = $min }
    if ($value -gt $max) { $value = $max }
    if ($null -ne $step) {
        $offset = $value - $min
        $steps = [math]::Floor($offset / $step)
        $value = $min + ($steps * $step)
        if ($value -lt $min) { $value = $min }
    }
    return [pscustomobject]@{
        value = [int]$value; clamped = ([int]$value -ne $Requested)
        rangeMin = [int]$min; rangeMax = [int]$max; source = $source
    }
}

# ---------------------------------------------------------------------------
# F. Journaled adapter-advanced-property write engine (shared by NX07-003..015)
# ---------------------------------------------------------------------------

function Invoke-Nx07AdvancedPropertyWrite {
    <#
        10-step pipeline for ONE adapter keyword:
        capture (value + display + adapter identity) -> journal -> set via
        Set-NetAdapterAdvancedProperty -> verify by re-read -> journal.
        On failed verification the exact original is written back and the failure
        is journaled. Idempotent: already-at-state journals a skip.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TweakId,
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)][string]$RegistryKeyword,
        [Parameter(Mandatory)][string]$DesiredRegistryValue,
        [string]$DesiredDisplayValue = '',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$RestartAdapter
    )
    if (-not $Approved) { throw "tweak ${TweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    Assert-Nx07JournalReady -JournalRoot $JournalRoot

    $cap = Get-Nx07AdvancedProperty -Adapter $Adapter -RegistryKeyword $RegistryKeyword
    if (-not $cap.present) {
        $skipOriginal = [pscustomobject]@{ targetType = 'adapterAdvancedProperty'; adapterName = [string]$Adapter.Name; interfaceIndex = [int]$Adapter.InterfaceIndex; registryKeyword = $RegistryKeyword; present = $false }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $skipOriginal -Modified $skipOriginal -Result 'PropertyNotExposed' -Verification 'NotRun' -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; adapterName = [string]$Adapter.Name; keyword = $RegistryKeyword; outcome = 'Skipped'; reason = "driver does not expose '$RegistryKeyword' (NEXTRIX never creates vendor keywords)" }
    }

    $classKey = Find-Nx07AdapterClassKey -InterfaceGuid ([string]$Adapter.InterfaceGuid)
    $identity = [pscustomobject]@{
        adapterName    = [string]$Adapter.Name
        interfaceIndex = [int]$Adapter.InterfaceIndex
        interfaceGuid  = [string]$Adapter.InterfaceGuid
        pnpDeviceId    = [string]$Adapter.PnPDeviceID
        interfaceDesc  = [string]$Adapter.InterfaceDescription
        registryKeyword = [string]$cap.registryKeyword
        displayName    = [string]$cap.displayName
        classKey       = $classKey
    }
    $original = [pscustomobject]@{
        targetType      = 'adapterAdvancedProperty'
        adapterName     = $identity.adapterName
        interfaceIndex  = $identity.interfaceIndex
        interfaceGuid   = $identity.interfaceGuid
        pnpDeviceId     = $identity.pnpDeviceId
        interfaceDesc   = $identity.interfaceDesc
        registryKeyword = $identity.registryKeyword
        displayName     = $identity.displayName
        classKey        = $identity.classKey
        registryValue   = $cap.registryValue
        displayValue    = $cap.displayValue
    }
    $modified = [pscustomobject]@{
        targetType      = 'adapterAdvancedProperty'
        adapterName     = $identity.adapterName
        interfaceIndex  = $identity.interfaceIndex
        interfaceGuid   = $identity.interfaceGuid
        pnpDeviceId     = $identity.pnpDeviceId
        interfaceDesc   = $identity.interfaceDesc
        registryKeyword = $identity.registryKeyword
        displayName     = $identity.displayName
        classKey        = $identity.classKey
        registryValue   = $DesiredRegistryValue
        displayValue    = $DesiredDisplayValue
        restartRequested = [bool]$RestartAdapter
    }

    if ($cap.registryValue -eq $DesiredRegistryValue) {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; adapterName = $identity.adapterName; keyword = $identity.registryKeyword; outcome = 'AlreadyAtState'; reason = "value is already '$DesiredRegistryValue' ($($cap.displayValue))"; original = $original; modified = $modified }
    }

    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        $setParams = @{
            Name            = $identity.adapterName
            RegistryKeyword = $identity.registryKeyword
            RegistryValue   = $DesiredRegistryValue
            ErrorAction     = 'Stop'
        }
        if (-not $RestartAdapter) { $setParams['NoRestart'] = $true }
        Set-NetAdapterAdvancedProperty @setParams

        $after = Get-Nx07AdvancedProperty -Adapter $Adapter -RegistryKeyword $identity.registryKeyword
        $verified = ($after.present -and $after.registryValue -eq $DesiredRegistryValue)
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            $restoreNote = ''
            try {
                $restoreParams = @{ Name = $identity.adapterName; RegistryKeyword = $identity.registryKeyword; RegistryValue = $cap.registryValue; ErrorAction = 'Stop'; NoRestart = $true }
                Set-NetAdapterAdvancedProperty @restoreParams
                $restoreNote = 'original value written back'
            } catch { $restoreNote = "original restore failed: $([string]$_.Exception.Message)" }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo "verification failed after write; $restoreNote" -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $TweakId; adapterName = $identity.adapterName; keyword = $identity.registryKeyword; outcome = 'Failed'; reason = "value did not verify after write; $restoreNote"; original = $original; modified = $modified; steps = @('capture', 'journal', 'apply', 'verify-failed', 'restore') }
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $TweakId; adapterName = $identity.adapterName; keyword = $identity.registryKeyword; outcome = 'Failed'; reason = [string]$_.Exception.Message; original = $original; modified = $modified }
    }
    return [pscustomobject]@{
        tweakId = $TweakId; adapterName = $identity.adapterName; keyword = $identity.registryKeyword
        outcome = 'Applied'; original = $original; modified = $modified; journalSeq = $jr.seq
        note = $(if ($RestartAdapter) { 'adapter restart requested' } else { 'takes effect when the adapter is restarted or at next reboot (NEXTRIX does not restart adapters by default)' })
    }
}

# ---------------------------------------------------------------------------
# G. Shared family driver for keyword-based entries
# ---------------------------------------------------------------------------

function Invoke-Nx07AdapterFamilyTweak {
    <#
        Drives one keyword family across the selected adapters.
          Mode='FirstPresent' - the first driver-exposed keyword from the candidate
                                list is used (vendor coverage without invention);
          Mode='AllPresent'   - every exposed keyword in the list is configured
                                (e.g. LSO v2 IPv4 + IPv6 as one entry).
        $Resolver receives ($capability, $ndiParam, $keyword) and returns
        { ok, registryValue, displayValue } or { ok=$false, reason }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TweakId,
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)]$Selection,
        [Parameter(Mandatory)][string[]]$CandidateKeywords,
        [ValidateSet('FirstPresent', 'AllPresent')][string]$Mode = 'FirstPresent',
        [Parameter(Mandatory)][scriptblock]$Resolver,
        [string]$NotExposedReason = 'driver exposes none of the probed keywords',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [switch]$Approved,
        [switch]$RestartAdapter
    )
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($Selection.targets)) {
        $adapter = $t.adapter
        $keywords = New-Object System.Collections.Generic.List[string]
        $probeTrail = New-Object System.Collections.Generic.List[string]
        if ($Mode -eq 'FirstPresent') {
            $probe = Get-Nx07FirstPresentKeyword -Adapter $adapter -CandidateKeywords $CandidateKeywords
            $probeTrail.AddRange([string[]]@($probe.probed))
            if ($probe.found) { $keywords.Add($probe.keyword) }
        } else {
            foreach ($kw in $CandidateKeywords) {
                $capProbe = Get-Nx07AdvancedProperty -Adapter $adapter -RegistryKeyword $kw
                $probeTrail.Add("$kw=$(if ($capProbe.present) { 'present' } else { 'absent' })")
                if ($capProbe.present) { $keywords.Add($kw) }
            }
        }
        if ($keywords.Count -eq 0) {
            $skipRecord = [pscustomobject]@{
                targetType = 'adapterAdvancedProperty'; adapterName = [string]$adapter.Name
                interfaceIndex = [int]$adapter.InterfaceIndex; interfaceGuid = [string]$adapter.InterfaceGuid
                probedKeywords = $probeTrail.ToArray(); present = $false
            }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $skipRecord -Modified $skipRecord -Result 'PropertyNotExposed' -Verification 'NotRun' -Profiles $Profiles | Out-Null
            $results.Add([pscustomobject]@{ tweakId = $TweakId; adapterName = [string]$adapter.Name; keyword = $null; outcome = 'Skipped'; reason = "$NotExposedReason (probed: $($probeTrail -join ', '))" })
            continue
        }
        $classKey = Find-Nx07AdapterClassKey -InterfaceGuid ([string]$adapter.InterfaceGuid)
        foreach ($kw in $keywords) {
            $cap = Get-Nx07AdvancedProperty -Adapter $adapter -RegistryKeyword $kw
            if (-not $cap.present) { continue }
            $ndi = Get-Nx07NdiParam -ClassKeyPath $classKey -RegistryKeyword $kw
            $decision = & $Resolver $cap $ndi $kw
            if ($null -eq $decision -or -not $decision.ok) {
                $reason = 'driver enumeration cannot express the requested value'
                if ($null -ne $decision -and $decision.reason) { $reason = [string]$decision.reason }
                $skipRecord = [pscustomobject]@{
                    targetType = 'adapterAdvancedProperty'; adapterName = [string]$adapter.Name
                    interfaceIndex = [int]$adapter.InterfaceIndex; interfaceGuid = [string]$adapter.InterfaceGuid
                    registryKeyword = $kw; present = $true; currentValue = $cap.registryValue
                    currentDisplay = $cap.displayValue; validDisplayValues = @($cap.validDisplayValues)
                }
                Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $skipRecord -Modified $skipRecord -Result 'ValueNotExposed' -Verification 'NotRun' -ErrorInfo $reason -Profiles $Profiles | Out-Null
                $results.Add([pscustomobject]@{ tweakId = $TweakId; adapterName = [string]$adapter.Name; keyword = $kw; outcome = 'Skipped'; reason = $reason })
                continue
            }
            $results.Add((Invoke-Nx07AdvancedPropertyWrite -TweakId $TweakId -JournalRoot $JournalRoot -Adapter $adapter -RegistryKeyword $kw -DesiredRegistryValue ([string]$decision.registryValue) -DesiredDisplayValue ([string]$decision.displayValue) -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter))
        }
    }
    $all = @($results.ToArray())
    $outcome = 'Skipped'
    if (@($all | Where-Object { $_.outcome -eq 'Failed' }).Count -gt 0) { $outcome = 'Failed' }
    elseif (@($all | Where-Object { $_.outcome -eq 'Applied' }).Count -gt 0) { $outcome = 'Applied' }
    elseif (@($all | Where-Object { $_.outcome -eq 'AlreadyAtState' }).Count -gt 0) { $outcome = 'AlreadyAtState' }
    return [pscustomobject]@{
        tweakId = $TweakId; outcome = $outcome; adapters = $all
        notices = @($Selection.notices)
        note = $(if ($RestartAdapter) { 'adapter restart requested' } else { 'properties take effect when the adapter is restarted or at next reboot; NEXTRIX does not restart adapters by default' })
    }
}

function New-Nx07BooleanResolver {
    param([Parameter(Mandatory)][bool]$Desired)
    return {
        param($cap, $ndi, $kw)
        $patterns = Get-Nx07BooleanPatterns -Desired $Desired
        $m = Find-Nx07DisplayChoice -Capability $cap -Patterns $patterns
        if ($null -eq $m) {
            return [pscustomobject]@{ ok = $false; reason = "driver values [$(($cap.validDisplayValues) -join ', ')] cannot express '$Desired'" }
        }
        return [pscustomobject]@{ ok = $true; registryValue = $m.registryValue; displayValue = $m.displayValue }
    }.GetNewClosure()
}

function New-Nx07QuadStateResolver {
    # Flow Control / checksum offload share the Disabled / Tx / Rx / TxRx enumeration.
    param([Parameter(Mandatory)][ValidateSet('Disabled', 'TxEnabled', 'RxEnabled', 'TxRxEnabled')][string]$Mode)
    $patterns = switch ($Mode) {
        'Disabled'  { @('disabled', 'disable', 'off') }
        'TxEnabled' { @('tx enabled', 'tx only', 'transmit enabled') }
        'RxEnabled' { @('rx enabled', 'rx only', 'receive enabled') }
        'TxRxEnabled' { @('rx & tx enabled', 'tx & rx enabled', 'rx and tx enabled', 'txrx enabled', 'both') }
    }
    return {
        param($cap, $ndi, $kw)
        $m = Find-Nx07DisplayChoice -Capability $cap -Patterns $patterns
        if ($null -eq $m) {
            return [pscustomobject]@{ ok = $false; reason = "driver values [$(($cap.validDisplayValues) -join ', ')] cannot express '$Mode'" }
        }
        return [pscustomobject]@{ ok = $true; registryValue = $m.registryValue; displayValue = $m.displayValue }
    }.GetNewClosure()
}

# ---------------------------------------------------------------------------
# H. NX07-002 - Adapter power management
# ---------------------------------------------------------------------------

function Set-Nx07AdapterPowerManagement {
    <#
        NX07-002. Per-adapter power management through the DOCUMENTED cmdlet surface
        (Get-/Set-NetAdapterPowerManagement). The device-level
        'AllowComputerToTurnOffDevice' checkbox is REPORTED but intentionally NOT
        modified: no documented NetAdapter cmdlet parameter writes it, and NEXTRIX
        does not reach for undocumented WMI writes to fake it.
        Trade-off recorded in the registry entry: disabling device sleep-on-disconnect
        can keep a link powered while unplugged (power draw) and is conditional on
        driver support - hence CONDITIONAL, never automatic.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$AdapterName = '',
        [int]$InterfaceIndex = 0,
        [ValidateSet('', 'Enabled', 'Disabled')][string]$SelectiveSuspend = '',
        [ValidateSet('', 'Enabled', 'Disabled')][string]$DeviceSleepOnDisconnect = '',
        [ValidateSet('', 'Enabled', 'Disabled')][string]$WakeOnMagicPacket = '',
        [ValidateSet('', 'Enabled', 'Disabled')][string]$WakeOnPattern = '',
        [ValidateSet('', 'Enabled', 'Disabled')][string]$D0PacketCoalescing = '',
        [ValidateSet('', 'Enabled', 'Disabled')][string]$ArpOffload = '',
        [ValidateSet('', 'Enabled', 'Disabled')][string]$NSOffload = '',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $tweakId = 'NX07-002'
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex
    if ($sel.targets.Count -eq 0) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = 'no eligible physical adapter matched'; notices = @($sel.notices) }
    }
    Assert-Nx07JournalReady -JournalRoot $JournalRoot

    $requested = [ordered]@{
        SelectiveSuspend         = $SelectiveSuspend
        DeviceSleepOnDisconnect  = $DeviceSleepOnDisconnect
        WakeOnMagicPacket        = $WakeOnMagicPacket
        WakeOnPattern            = $WakeOnPattern
        D0PacketCoalescing       = $D0PacketCoalescing
        ArpOffload               = $ArpOffload
        NSOffload                = $NSOffload
    }
    $wanted = @{}
    foreach ($k in $requested.Keys) { if ($requested[$k]) { $wanted[$k] = [string]$requested[$k] } }
    if ($wanted.Count -eq 0) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = 'no power-management property was requested'; notices = @($sel.notices) }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($sel.targets)) {
        $adapter = $t.adapter
        $live = $null
        try { $live = Get-NetAdapterPowerManagement -Name ([string]$adapter.Name) -ErrorAction Stop } catch {
            $results.Add([pscustomobject]@{ tweakId = $tweakId; adapterName = [string]$adapter.Name; outcome = 'Skipped'; reason = "Get-NetAdapterPowerManagement failed: $([string]$_.Exception.Message)" })
            continue
        }
        $propertyNames = @('AllowComputerToTurnOffDevice', 'ArpOffload', 'D0PacketCoalescing', 'DeviceSleepOnDisconnect', 'NSOffload', 'RsnRekeyOffload', 'SelectiveSuspend', 'WakeOnMagicPacket', 'WakeOnPattern')
        $originalProps = [ordered]@{}
        foreach ($pn in $propertyNames) {
            $pp = $live.PSObject.Properties[$pn]
            $originalProps[$pn] = $(if ($null -ne $pp) { [string]$pp.Value } else { 'Unavailable' })
        }
        $changes = [ordered]@{}
        $skippedProps = New-Object System.Collections.Generic.List[string]
        foreach ($k in $wanted.Keys) {
            $currentValue = [string]$originalProps[$k]
            if ($currentValue -eq 'Unsupported' -or $currentValue -eq 'Unavailable') {
                $skippedProps.Add("$k (driver reports '$currentValue')")
                continue
            }
            if ($currentValue -ne $wanted[$k]) { $changes[$k] = $wanted[$k] }
        }
        if ($changes.Count -eq 0) {
            $skipRecord = [pscustomobject]@{ targetType = 'adapterPowerManagement'; adapterName = [string]$adapter.Name; interfaceIndex = [int]$adapter.InterfaceIndex; properties = $originalProps }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $skipRecord -Modified $skipRecord -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles $Profiles | Out-Null
            $results.Add([pscustomobject]@{ tweakId = $tweakId; adapterName = [string]$adapter.Name; outcome = 'AlreadyAtState'; reason = "requested properties already at state (skipped: $($skippedProps -join '; '))" })
            continue
        }
        $modifiedProps = [ordered]@{}
        foreach ($pn in $propertyNames) { $modifiedProps[$pn] = $originalProps[$pn] }
        foreach ($k in $changes.Keys) { $modifiedProps[$k] = $changes[$k] }
        $original = [pscustomobject]@{
            targetType = 'adapterPowerManagement'; adapterName = [string]$adapter.Name
            interfaceIndex = [int]$adapter.InterfaceIndex; interfaceGuid = [string]$adapter.InterfaceGuid
            interfaceDesc = [string]$adapter.InterfaceDescription; properties = $originalProps
        }
        $modified = [pscustomobject]@{
            targetType = 'adapterPowerManagement'; adapterName = [string]$adapter.Name
            interfaceIndex = [int]$adapter.InterfaceIndex; interfaceGuid = [string]$adapter.InterfaceGuid
            interfaceDesc = [string]$adapter.InterfaceDescription; properties = $modifiedProps
            changed = @($changes.Keys)
        }
        $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
        try {
            $setParams = @{ Name = [string]$adapter.Name; ErrorAction = 'Stop'; NoRestart = $true }
            foreach ($k in $changes.Keys) { $setParams[$k] = $changes[$k] }
            Set-NetAdapterPowerManagement @setParams
            $after = Get-NetAdapterPowerManagement -Name ([string]$adapter.Name) -ErrorAction Stop
            $verified = $true
            foreach ($k in $changes.Keys) {
                $pp = $after.PSObject.Properties[$k]
                if ($null -eq $pp -or [string]$pp.Value -ne [string]$changes[$k]) { $verified = $false; break }
            }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
            if (-not $verified) {
                $restoreNote = ''
                try {
                    $restoreParams = @{ Name = [string]$adapter.Name; ErrorAction = 'Stop'; NoRestart = $true }
                    foreach ($k in $changes.Keys) { $restoreParams[$k] = [string]$originalProps[$k] }
                    Set-NetAdapterPowerManagement @restoreParams
                    $restoreNote = 'original values written back'
                } catch { $restoreNote = "original restore failed: $([string]$_.Exception.Message)" }
                Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo "power-management verify failed; $restoreNote" -Profiles $Profiles | Out-Null
                $results.Add([pscustomobject]@{ tweakId = $tweakId; adapterName = [string]$adapter.Name; outcome = 'Failed'; reason = "verification failed; $restoreNote" })
                continue
            }
        } catch {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
            $results.Add([pscustomobject]@{ tweakId = $tweakId; adapterName = [string]$adapter.Name; outcome = 'Failed'; reason = [string]$_.Exception.Message })
            continue
        }
        $results.Add([pscustomobject]@{
            tweakId = $tweakId; adapterName = [string]$adapter.Name; outcome = 'Applied'; journalSeq = $jr.seq
            changed = @($changes.Keys); skipped = @($skippedProps.ToArray())
            note = 'applies to the adapter on its next restart/reboot (NEXTRIX does not restart adapters by default)'
        })
    }
    $all = @($results.ToArray())
    $outcome = 'Skipped'
    if (@($all | Where-Object { $_.outcome -eq 'Failed' }).Count -gt 0) { $outcome = 'Failed' }
    elseif (@($all | Where-Object { $_.outcome -eq 'Applied' }).Count -gt 0) { $outcome = 'Applied' }
    elseif (@($all | Where-Object { $_.outcome -eq 'AlreadyAtState' }).Count -gt 0) { $outcome = 'AlreadyAtState' }
    return [pscustomobject]@{ tweakId = $tweakId; outcome = $outcome; adapters = $all; notices = @($sel.notices) }
}

# ---------------------------------------------------------------------------
# I. NX07-003..011 - Ethernet advanced-property families
# ---------------------------------------------------------------------------

function Set-Nx07EnergyEfficientEthernet {
    <# NX07-003 - Energy-Efficient Ethernet (*EEE). ADVANCED, preset-excluded. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [bool]$Enabled = $false,
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    if (-not $Approved) { throw "tweak NX07-003: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Ethernet'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = 'NX07-003'; outcome = 'Skipped'; reason = 'no eligible Ethernet adapter matched (Wi-Fi and virtual adapters are excluded)'; notices = @($sel.notices) } }
    return Invoke-Nx07AdapterFamilyTweak -TweakId 'NX07-003' -JournalRoot $JournalRoot -Selection $sel `
        -CandidateKeywords @('*EEE', 'EEE') -Mode 'FirstPresent' `
        -Resolver (New-Nx07BooleanResolver -Desired $Enabled) `
        -NotExposedReason 'Energy-Efficient Ethernet keyword not exposed by this driver' `
        -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
}

function Set-Nx07InterruptModeration {
    <# NX07-004 - Interrupt moderation (*InterruptModeration). ADVANCED. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [bool]$Enabled = $false,
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    if (-not $Approved) { throw "tweak NX07-004: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Ethernet'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = 'NX07-004'; outcome = 'Skipped'; reason = 'no eligible Ethernet adapter matched'; notices = @($sel.notices) } }
    return Invoke-Nx07AdapterFamilyTweak -TweakId 'NX07-004' -JournalRoot $JournalRoot -Selection $sel `
        -CandidateKeywords @('*InterruptModeration', 'InterruptModeration') -Mode 'FirstPresent' `
        -Resolver (New-Nx07BooleanResolver -Desired $Enabled) `
        -NotExposedReason 'Interrupt Moderation keyword not exposed by this driver' `
        -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
}

function Set-Nx07ReceiveSideScaling {
    <#
        NX07-005 - RSS. Enables/disables *RSS and, when a queue limit is requested,
        writes *MaxRssProcessors clamped to [1, logical processor count] and the
        driver's documented range. Queue counts are reported from Get-NetAdapterRss
        when the driver exposes them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [bool]$Enabled = $true,
        [int]$MaxProcessors = 0,
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    $tweakId = 'NX07-005'
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Ethernet'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = 'no eligible Ethernet adapter matched'; notices = @($sel.notices) } }
    Assert-Nx07JournalReady -JournalRoot $JournalRoot
    $logicalCount = [int][Environment]::ProcessorCount
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($sel.targets)) {
        $adapter = $t.adapter
        $probe = Get-Nx07FirstPresentKeyword -Adapter $adapter -CandidateKeywords @('*RSS', 'RSS')
        if (-not $probe.found) {
            $skipRecord = [pscustomobject]@{ targetType = 'adapterAdvancedProperty'; adapterName = [string]$adapter.Name; interfaceIndex = [int]$adapter.InterfaceIndex; registryKeyword = '*RSS'; present = $false; probedKeywords = @($probe.probed) }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $skipRecord -Modified $skipRecord -Result 'PropertyNotExposed' -Verification 'NotRun' -Profiles $Profiles | Out-Null
            $results.Add([pscustomobject]@{ tweakId = $tweakId; adapterName = [string]$adapter.Name; outcome = 'Skipped'; reason = "RSS keyword not exposed (probed: $($probe.probed -join ', '))" })
            continue
        }
        $decision = & (New-Nx07BooleanResolver -Desired $Enabled) $probe.capability $null $probe.keyword
        if (-not $decision.ok) {
            $results.Add([pscustomobject]@{ tweakId = $tweakId; adapterName = [string]$adapter.Name; outcome = 'Skipped'; reason = $decision.reason })
            continue
        }
        $results.Add((Invoke-Nx07AdvancedPropertyWrite -TweakId $tweakId -JournalRoot $JournalRoot -Adapter $adapter -RegistryKeyword $probe.keyword -DesiredRegistryValue $decision.registryValue -DesiredDisplayValue $decision.displayValue -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter))
        if ($MaxProcessors -gt 0 -and $Enabled) {
            $queueProbe = Get-Nx07FirstPresentKeyword -Adapter $adapter -CandidateKeywords @('*MaxRssProcessors', 'MaxRssProcessors')
            if (-not $queueProbe.found) {
                $results.Add([pscustomobject]@{ tweakId = $tweakId; adapterName = [string]$adapter.Name; keyword = 'MaxRssProcessors'; outcome = 'Skipped'; reason = 'queue-count keyword not exposed by this driver' })
                continue
            }
            $classKey = Find-Nx07AdapterClassKey -InterfaceGuid ([string]$adapter.InterfaceGuid)
            $ndi = Get-Nx07NdiParam -ClassKeyPath $classKey -RegistryKeyword $queueProbe.keyword
            $upper = [math]::Min([int]$MaxProcessors, $logicalCount)
            $resolved = Resolve-Nx07NumericValue -Capability $queueProbe.capability -NdiParam $ndi -Requested $upper -AbsoluteMin 1 -AbsoluteMax $logicalCount
            $results.Add((Invoke-Nx07AdvancedPropertyWrite -TweakId $tweakId -JournalRoot $JournalRoot -Adapter $adapter -RegistryKeyword $queueProbe.keyword -DesiredRegistryValue ([string]$resolved.value) -DesiredDisplayValue '' -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter))
        }
        try {
            $rss = Get-NetAdapterRss -Name ([string]$adapter.Name) -ErrorAction Stop
            if ($null -ne $rss) {
                $results.Add([pscustomobject]@{ tweakId = $tweakId; adapterName = [string]$adapter.Name; outcome = 'Report'; reason = "RSS queue view: NumberOfReceiveQueues=$($rss.NumberOfReceiveQueues) MaxProcessors=$($rss.MaxProcessors) (logical processors: $logicalCount)" })
            }
        } catch { }
    }
    $all = @($results.ToArray())
    $outcome = 'Skipped'
    if (@($all | Where-Object { $_.outcome -eq 'Failed' }).Count -gt 0) { $outcome = 'Failed' }
    elseif (@($all | Where-Object { $_.outcome -eq 'Applied' }).Count -gt 0) { $outcome = 'Applied' }
    elseif (@($all | Where-Object { $_.outcome -eq 'AlreadyAtState' }).Count -gt 0) { $outcome = 'AlreadyAtState' }
    return [pscustomobject]@{ tweakId = $tweakId; outcome = $outcome; adapters = $all; notices = @($sel.notices) }
}

function Set-Nx07ReceiveSegmentCoalescing {
    <# NX07-006 - RSC (IPv4 + IPv6 present-only). ADVANCED. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [bool]$Enabled = $false,
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    if (-not $Approved) { throw "tweak NX07-006: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Ethernet'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = 'NX07-006'; outcome = 'Skipped'; reason = 'no eligible Ethernet adapter matched'; notices = @($sel.notices) } }
    return Invoke-Nx07AdapterFamilyTweak -TweakId 'NX07-006' -JournalRoot $JournalRoot -Selection $sel `
        -CandidateKeywords @('*RscIPv4', '*RscIPv6', 'RscIPv4', 'RscIPv6') -Mode 'AllPresent' `
        -Resolver (New-Nx07BooleanResolver -Desired $Enabled) `
        -NotExposedReason 'Receive Segment Coalescing keywords not exposed by this driver' `
        -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
}

function Set-Nx07LargeSendOffload {
    <#
        NX07-007 - LSO v2 (IPv4 + IPv6). ADVANCED + preset-excluded, with the
        honest note that the community disagreement about LSO is not resolved by
        any vendor benchmark NEXTRIX can cite.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [bool]$Enabled = $false,
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    if (-not $Approved) { throw "tweak NX07-007: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Ethernet'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = 'NX07-007'; outcome = 'Skipped'; reason = 'no eligible Ethernet adapter matched'; notices = @($sel.notices) } }
    return Invoke-Nx07AdapterFamilyTweak -TweakId 'NX07-007' -JournalRoot $JournalRoot -Selection $sel `
        -CandidateKeywords @('*LsoV2IPv4', '*LsoV2IPv6', 'LsoV2IPv4', 'LsoV2IPv6') -Mode 'AllPresent' `
        -Resolver (New-Nx07BooleanResolver -Desired $Enabled) `
        -NotExposedReason 'Large Send Offload v2 keywords not exposed by this driver' `
        -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
}

function Set-Nx07ChecksumOffload {
    <# NX07-008 - IPv4/IPv6 TCP/UDP checksum offloads (present-only). ADVANCED. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Disabled', 'TxEnabled', 'RxEnabled', 'TxRxEnabled')][string]$Mode = 'TxRxEnabled',
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    if (-not $Approved) { throw "tweak NX07-008: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Ethernet'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = 'NX07-008'; outcome = 'Skipped'; reason = 'no eligible Ethernet adapter matched'; notices = @($sel.notices) } }
    return Invoke-Nx07AdapterFamilyTweak -TweakId 'NX07-008' -JournalRoot $JournalRoot -Selection $sel `
        -CandidateKeywords $script:Nx07ChecksumKeywords -Mode 'AllPresent' `
        -Resolver (New-Nx07QuadStateResolver -Mode $Mode) `
        -NotExposedReason 'no checksum-offload keyword exposed by this driver' `
        -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
}

function Set-Nx07FlowControl {
    <# NX07-009 - Flow Control. Switch-dependent; ADVANCED + preset-excluded. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Disabled', 'TxEnabled', 'RxEnabled', 'TxRxEnabled')][string]$Mode = 'TxRxEnabled',
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    if (-not $Approved) { throw "tweak NX07-009: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Ethernet'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = 'NX07-009'; outcome = 'Skipped'; reason = 'no eligible Ethernet adapter matched'; notices = @($sel.notices) } }
    return Invoke-Nx07AdapterFamilyTweak -TweakId 'NX07-009' -JournalRoot $JournalRoot -Selection $sel `
        -CandidateKeywords @('*FlowControl', 'FlowControl') -Mode 'FirstPresent' `
        -Resolver (New-Nx07QuadStateResolver -Mode $Mode) `
        -NotExposedReason 'Flow Control keyword not exposed by this driver' `
        -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
}

function Set-Nx07JumboFrame {
    <#
        NX07-010 - Jumbo frames. The requested MTU must be one of the driver's
        ENUMERATED values (no arbitrary writes); the end-to-end path requirement
        (switch, router, every hop) is documented in the registry entry because
        NEXTRIX cannot verify it from the host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateRange(1500, 9216)][int]$Mtu = 9014,
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    if (-not $Approved) { throw "tweak NX07-010: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Ethernet'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = 'NX07-010'; outcome = 'Skipped'; reason = 'no eligible Ethernet adapter matched'; notices = @($sel.notices) } }
    $resolver = {
        param($cap, $ndi, $kw)
        $matchIndex = -1
        $vals = @($cap.validRegistryValues)
        for ($i = 0; $i -lt $vals.Count; $i++) {
            $n = 0
            if ([int]::TryParse([string]$vals[$i], [ref]$n) -and $n -eq $Mtu) { $matchIndex = $i; break }
        }
        if ($matchIndex -lt 0) {
            return [pscustomobject]@{ ok = $false; reason = "driver exposes [$(($cap.validRegistryValues) -join ', ')] - $Mtu is not an enumerated jumbo size for this adapter" }
        }
        $disp = ''
        if ($matchIndex -lt @($cap.validDisplayValues).Count) { $disp = [string]@($cap.validDisplayValues)[$matchIndex] }
        return [pscustomobject]@{ ok = $true; registryValue = [string]$vals[$matchIndex]; displayValue = $disp }
    }.GetNewClosure()
    return Invoke-Nx07AdapterFamilyTweak -TweakId 'NX07-010' -JournalRoot $JournalRoot -Selection $sel `
        -CandidateKeywords @('*JumboPacket', 'JumboPacket') -Mode 'FirstPresent' `
        -Resolver $resolver `
        -NotExposedReason 'Jumbo Frame keyword not exposed by this driver' `
        -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
}

function Set-Nx07AdapterBufferSize {
    <#
        NX07-011 - Receive/Transmit buffers. Values are clamped to the driver's
        documented Ndi\Params min/max/step (or its numeric value list) and to the
        NEXTRIX absolute sanity window [32..8192]; every clamp is reported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [int]$ReceiveBuffers = 0,
        [int]$TransmitBuffers = 0,
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    $tweakId = 'NX07-011'
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    if ($ReceiveBuffers -le 0 -and $TransmitBuffers -le 0) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = 'at least one of -ReceiveBuffers/-TransmitBuffers must be a positive value' }
    }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Ethernet'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = 'no eligible Ethernet adapter matched'; notices = @($sel.notices) } }
    Assert-Nx07JournalReady -JournalRoot $JournalRoot
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($sel.targets)) {
        $adapter = $t.adapter
        $classKey = Find-Nx07AdapterClassKey -InterfaceGuid ([string]$adapter.InterfaceGuid)
        $wanted = @()
        if ($ReceiveBuffers -gt 0) { $wanted += [pscustomobject]@{ requested = $ReceiveBuffers; keywords = @('*ReceiveBuffers', 'ReceiveBuffers'); label = 'Receive Buffers' } }
        if ($TransmitBuffers -gt 0) { $wanted += [pscustomobject]@{ requested = $TransmitBuffers; keywords = @('*TransmitBuffers', 'TransmitBuffers'); label = 'Transmit Buffers' } }
        foreach ($w in $wanted) {
            $probe = Get-Nx07FirstPresentKeyword -Adapter $adapter -CandidateKeywords $w.keywords
            if (-not $probe.found) {
                $skipRecord = [pscustomobject]@{ targetType = 'adapterAdvancedProperty'; adapterName = [string]$adapter.Name; interfaceIndex = [int]$adapter.InterfaceIndex; registryKeyword = $w.keywords[0]; present = $false; probedKeywords = @($probe.probed) }
                Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $skipRecord -Modified $skipRecord -Result 'PropertyNotExposed' -Verification 'NotRun' -Profiles $Profiles | Out-Null
                $results.Add([pscustomobject]@{ tweakId = $tweakId; adapterName = [string]$adapter.Name; keyword = $w.keywords[0]; outcome = 'Skipped'; reason = "$($w.label) keyword not exposed (probed: $($probe.probed -join ', '))" })
                continue
            }
            $ndi = Get-Nx07NdiParam -ClassKeyPath $classKey -RegistryKeyword $probe.keyword
            $resolved = Resolve-Nx07NumericValue -Capability $probe.capability -NdiParam $ndi -Requested $w.requested
            $write = Invoke-Nx07AdvancedPropertyWrite -TweakId $tweakId -JournalRoot $JournalRoot -Adapter $adapter -RegistryKeyword $probe.keyword -DesiredRegistryValue ([string]$resolved.value) -DesiredDisplayValue '' -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
            $clampNote = ''
            if ($resolved.clamped) { $clampNote = "clamped from $($w.requested) to $($resolved.value) ($($resolved.source) range $($resolved.rangeMin)..$($resolved.rangeMax))" }
            $write | Add-Member -NotePropertyName clampNote -NotePropertyValue $clampNote -Force
            $results.Add($write)
        }
    }
    $all = @($results.ToArray())
    $outcome = 'Skipped'
    if (@($all | Where-Object { $_.outcome -eq 'Failed' }).Count -gt 0) { $outcome = 'Failed' }
    elseif (@($all | Where-Object { $_.outcome -eq 'Applied' }).Count -gt 0) { $outcome = 'Applied' }
    elseif (@($all | Where-Object { $_.outcome -eq 'AlreadyAtState' }).Count -gt 0) { $outcome = 'AlreadyAtState' }
    return [pscustomobject]@{ tweakId = $tweakId; outcome = $outcome; adapters = $all; notices = @($sel.notices) }
}

# ---------------------------------------------------------------------------
# J. NX07-012..015 - Wi-Fi families (PhysicalMediaType 'Native 802.11' only)
# ---------------------------------------------------------------------------

function Invoke-Nx07WifiFamilyTweak {
    param(
        [Parameter(Mandatory)][string]$TweakId,
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)]$Selection,
        [Parameter(Mandatory)][string]$CandidateSet,   # key into $script:Nx07WifiKeywordCandidates
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)][string]$RequestedLabel,
        [string]$TweakVersion = '1', [string]$Approval = 'Selection', [string[]]$Profiles = @(), [switch]$Approved, [switch]$RestartAdapter
    )
    $candidates = @($script:Nx07WifiKeywordCandidates[$CandidateSet])
    $resolver = {
        param($cap, $ndi, $kw)
        $m = Find-Nx07DisplayChoice -Capability $cap -Patterns $Patterns
        if ($null -eq $m) {
            return [pscustomobject]@{ ok = $false; reason = "driver values [$(($cap.validDisplayValues) -join ', ')] cannot express '$RequestedLabel'" }
        }
        return [pscustomobject]@{ ok = $true; registryValue = $m.registryValue; displayValue = $m.displayValue }
    }.GetNewClosure()
    return Invoke-Nx07AdapterFamilyTweak -TweakId $TweakId -JournalRoot $JournalRoot -Selection $Selection `
        -CandidateKeywords $candidates -Mode 'FirstPresent' -Resolver $resolver `
        -NotExposedReason "no Wi-Fi '$RequestedLabel' keyword exposed by this driver (probed: $($candidates -join ', '))" `
        -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
}

function Set-Nx07WifiRoamingAggressiveness {
    <# NX07-012 - Roaming aggressiveness. Environment-dependent; CONDITIONAL. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Lowest', 'Low', 'MediumLow', 'Medium', 'MediumHigh', 'High', 'Highest')][string]$Aggressiveness = 'Lowest',
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    if (-not $Approved) { throw "tweak NX07-012: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Wifi'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = 'NX07-012'; outcome = 'Skipped'; reason = 'no eligible Wi-Fi adapter matched (Ethernet is not touched by this entry)'; notices = @($sel.notices) } }
    $patterns = switch ($Aggressiveness) {
        'Lowest'     { @('lowest') }
        'Low'        { @('low') }
        'MediumLow'  { @('medium-low', 'medium low') }
        'Medium'     { @('medium') }
        'MediumHigh' { @('medium-high', 'medium high') }
        'High'       { @('high') }
        'Highest'    { @('highest') }
    }
    return Invoke-Nx07WifiFamilyTweak -TweakId 'NX07-012' -JournalRoot $JournalRoot -Selection $sel -CandidateSet 'RoamingAggressiveness' -Patterns $patterns -RequestedLabel "roaming aggressiveness '$Aggressiveness'" -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
}

function Set-Nx07WifiPreferredBand {
    <# NX07-013 - Preferred band. AP capability is not host-verifiable; CONDITIONAL. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('NoPreference', 'Prefer24GHz', 'Prefer5GHz', 'Prefer6GHz')][string]$Band = 'Prefer5GHz',
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    if (-not $Approved) { throw "tweak NX07-013: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Wifi'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = 'NX07-013'; outcome = 'Skipped'; reason = 'no eligible Wi-Fi adapter matched'; notices = @($sel.notices) } }
    $patterns = switch ($Band) {
        'NoPreference' { @('no preference', 'all band', 'auto') }
        'Prefer24GHz'  { @('prefer 2.4ghz', '2.4ghz band', '2.4g only', '2.4 ghz') }
        'Prefer5GHz'   { @('prefer 5ghz', '5ghz band', '5g only', '5 ghz') }
        'Prefer6GHz'   { @('prefer 6ghz', '6ghz band', '6g only', '6 ghz') }
    }
    return Invoke-Nx07WifiFamilyTweak -TweakId 'NX07-013' -JournalRoot $JournalRoot -Selection $sel -CandidateSet 'PreferredBand' -Patterns $patterns -RequestedLabel "preferred band '$Band'" -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
}

function Set-Nx07WifiChannelWidth {
    <# NX07-014 - Channel width per band. AP/interference-dependent; ADVANCED. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('24', '5')][string]$Band = '5',
        [ValidateSet('Auto', '20', '40', '80', '160')][string]$Width = 'Auto',
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    if (-not $Approved) { throw "tweak NX07-014: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Wifi'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = 'NX07-014'; outcome = 'Skipped'; reason = 'no eligible Wi-Fi adapter matched'; notices = @($sel.notices) } }
    $patterns = switch ($Width) {
        'Auto' { @('auto') }
        '20'   { @('20mhz', '20 mhz') }
        '40'   { @('40mhz', '40 mhz') }
        '80'   { @('80mhz', '80 mhz') }
        '160'  { @('160mhz', '160 mhz') }
    }
    $candidateSet = 'ChannelWidth24'
    if ($Band -eq '5') { $candidateSet = 'ChannelWidth5' }
    return Invoke-Nx07WifiFamilyTweak -TweakId 'NX07-014' -JournalRoot $JournalRoot -Selection $sel -CandidateSet $candidateSet -Patterns $patterns -RequestedLabel "channel width '$Width' on the $Band GHz band" -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
}

function Set-Nx07WifiTransmitPower {
    <# NX07-015 - Transmit power level. Driver-exposed strengths only; CONDITIONAL. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Lowest', 'Low', 'Medium', 'High', 'Highest')][string]$Strength = 'Highest',
        [string]$AdapterName = '', [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(), [string]$TweakVersion = '1', [string]$Approval = 'Selection', [switch]$Approved,
        [switch]$RestartAdapter
    )
    if (-not $Approved) { throw "tweak NX07-015: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex -Require 'Wifi'
    if ($sel.targets.Count -eq 0) { return [pscustomobject]@{ tweakId = 'NX07-015'; outcome = 'Skipped'; reason = 'no eligible Wi-Fi adapter matched'; notices = @($sel.notices) } }
    $patterns = switch ($Strength) {
        'Lowest'  { @('lowest') }
        'Low'     { @('low') }
        'Medium'  { @('medium') }
        'High'    { @('high') }
        'Highest' { @('highest') }
    }
    return Invoke-Nx07WifiFamilyTweak -TweakId 'NX07-015' -JournalRoot $JournalRoot -Selection $sel -CandidateSet 'TransmitPower' -Patterns $patterns -RequestedLabel "transmit power '$Strength'" -TweakVersion $TweakVersion -Approval $Approval -Profiles $Profiles -Approved:$Approved -RestartAdapter:$RestartAdapter
}

# ---------------------------------------------------------------------------
# K. NX07-016 - DNS configuration (capture -> set -> verify probe -> auto-rollback)
# ---------------------------------------------------------------------------

function ConvertTo-Nx07DnsServerList {
    <#
        Parses a comma/semicolon/space separated server list and validates every
        address for the requested family. Invalid tokens are returned, never
        silently dropped (the caller refuses on any invalid token).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$AddressFamily
    )
    $valid = New-Object System.Collections.Generic.List[string]
    $invalid = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        foreach ($token in ($Text -split '[,;\s]+')) {
            $t = $token.Trim()
            if (-not $t) { continue }
            $ip = $null
            if ([System.Net.IPAddress]::TryParse($t, [ref]$ip)) {
                $family = 'IPv4'
                if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { $family = 'IPv6' }
                if ($family -eq $AddressFamily) { if (-not $valid.Contains($t)) { $valid.Add($t) } }
                else { $invalid.Add("$t (expected $AddressFamily)") }
            } else {
                $invalid.Add("$t (not an IP address)")
            }
        }
    }
    return [pscustomobject]@{ servers = @($valid.ToArray()); invalid = @($invalid.ToArray()) }
}

function Get-Nx07DnsClientState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$InterfaceIndex)
    $v4 = @(); $v6 = @(); $v4ReadOk = $false; $v6ReadOk = $false
    try {
        $r4 = Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
        $v4ReadOk = $true
        if ($null -ne $r4) { $v4 = @($r4 | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ }) }
    } catch { $v4ReadOk = $false }
    try {
        $r6 = Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv6 -ErrorAction Stop
        $v6ReadOk = $true
        if ($null -ne $r6) { $v6 = @($r6 | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ }) }
    } catch { $v6ReadOk = $false }
    $dhcp4 = 'Unknown'; $dhcp6 = 'Unknown'
    try { $i4 = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop; if ($null -ne $i4) { $dhcp4 = [string]$i4.Dhcp } } catch { }
    try { $i6 = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv6 -ErrorAction Stop; if ($null -ne $i6) { $dhcp6 = [string]$i6.Dhcp } } catch { }
    return [pscustomobject]@{
        interfaceIndex = $InterfaceIndex
        v4 = @($v4 | ForEach-Object { [string]$_ } | Sort-Object)
        v6 = @($v6 | ForEach-Object { [string]$_ } | Sort-Object)
        v4ReadOk = $v4ReadOk
        v6ReadOk = $v6ReadOk
        dhcpV4 = $dhcp4
        dhcpV6 = $dhcp6
    }
}

function Get-Nx07DefaultRouteInterfaces {
    [CmdletBinding()]
    param()
    $idx = New-Object System.Collections.Generic.List[int]
    foreach ($prefix in @('0.0.0.0/0', '::/0')) {
        try {
            foreach ($r in @(Get-NetRoute -DestinationPrefix $prefix -ErrorAction Stop)) {
                $n = [int]$r.InterfaceIndex
                if (-not $idx.Contains($n)) { $idx.Add($n) }
            }
        } catch { }
    }
    return @($idx.ToArray())
}

function Test-Nx07SameStringSet {
    param([AllowNull()]$A, [AllowNull()]$B)
    $a = @(@($A) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object)
    $b = @(@($B) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object)
    return (($a -join '|') -eq ($b -join '|'))
}

function Test-Nx07DnsResolution {
    <#
        Verification probe: resolve a stable public name THROUGH the new servers.
        Two attempts per server (a single lost query must not trigger a rollback),
        and one answering server is sufficient. No timing is measured or claimed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Servers,
        [string]$ProbeName = $script:Nx07DefaultDnsProbe,
        [int]$Attempts = 2
    )
    $results = New-Object System.Collections.Generic.List[object]
    if (@($Servers).Count -eq 0) { return [pscustomobject]@{ ok = $false; probeName = $ProbeName; results = @(); reason = 'no server to probe' } }
    foreach ($server in $Servers) {
        $ok = $false; $lastError = ''
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            try {
                $answer = Resolve-DnsName -Name $ProbeName -Server $server -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
                if (@($answer).Count -gt 0) { $ok = $true; break }
            } catch { $lastError = [string]$_.Exception.Message }
        }
        $results.Add([pscustomobject]@{ server = $server; answered = $ok; error = (Get-Nx07TruncatedText $lastError 200) })
        if ($ok) { break }
    }
    $anyOk = (@($results.ToArray() | Where-Object { $_.answered }).Count -gt 0)
    return [pscustomobject]@{
        ok = $anyOk; probeName = $ProbeName; results = @($results.ToArray())
        reason = $(if ($anyOk) { 'at least one configured resolver answered the probe' } else { 'no configured resolver answered the probe' })
    }
}

function Restore-Nx07DnsState {
    <#
        Writes a captured DNS original back for ONE interface. Set-DnsClientServerAddress
        has NO address-family parameter: one call sets the interface's complete server
        list, so IPv4 and IPv6 originals are combined. When both families were
        DHCP-provided (or the original list is empty) the restore uses
        -ResetServerAddresses to return the interface to automatic configuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$InterfaceIndex,
        [Parameter(Mandatory)]$Original
    )
    $notes = New-Object System.Collections.Generic.List[string]
    $v4 = @(@($Original.v4) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $v6 = @(@($Original.v6) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $combined = @($v4) + @($v6)
    $bothDhcp = (([string]$Original.dhcpV4 -eq 'Enabled') -and ([string]$Original.dhcpV6 -eq 'Enabled'))
    if ($bothDhcp -or $combined.Count -eq 0) {
        Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ResetServerAddresses -ErrorAction Stop
        $notes.Add('DNS reset to automatic/DHCP-provided servers')
    } else {
        Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $combined -ErrorAction Stop
        $notes.Add("DNS restored to $($combined -join ',')")
    }
    return @($notes.ToArray())
}

function Get-Nx07DohTemplate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServerAddress, [string]$ExplicitTemplate = '')
    if ($ExplicitTemplate) { return [pscustomobject]@{ template = $ExplicitTemplate; provider = 'explicit' } }
    foreach ($entry in $script:Nx07DohTemplates) {
        if (@($entry.match) -contains $ServerAddress) { return [pscustomobject]@{ template = [string]$entry.template; provider = [string]$entry.provider } }
    }
    return $null
}

function Set-Nx07DnsConfiguration {
    <#
        NX07-016. Per-interface DNS configuration with MANDATORY verify-and-
        auto-rollback (r5 Sophia pattern): after the write, Resolve-DnsName probes
        the new servers; if none answers, the captured original is restored and the
        failure is journaled as Failed-RestoredOriginal.
        No latency claim of any kind: the motivation is resolver choice/privacy.
        DoH is OPTIONAL and only through the documented DnsClient DoH cmdlets; an
        existing registration is never modified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$ServerAddresses = '',
        [string]$Ipv6ServerAddresses = '',
        [switch]$Doh,
        [string]$DohTemplate = '',
        [string]$ProbeName = $script:Nx07DefaultDnsProbe,
        [string]$AdapterName = '',
        [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $tweakId = 'NX07-016'
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    if ([string]::IsNullOrWhiteSpace($ProbeName)) { $ProbeName = $script:Nx07DefaultDnsProbe }
    if (-not [string]::IsNullOrWhiteSpace($DohTemplate) -and $DohTemplate -notmatch '^https://') {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = 'a DoH template must be an https:// URI' }
    }
    $v4Parsed = ConvertTo-Nx07DnsServerList -Text $ServerAddresses -AddressFamily IPv4
    $v6Parsed = ConvertTo-Nx07DnsServerList -Text $Ipv6ServerAddresses -AddressFamily IPv6
    if ($v4Parsed.invalid.Count -gt 0 -or $v6Parsed.invalid.Count -gt 0) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = "invalid DNS server input: $((@($v4Parsed.invalid) + @($v6Parsed.invalid)) -join '; ')" }
    }
    if ($v4Parsed.servers.Count -eq 0 -and $v6Parsed.servers.Count -eq 0) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = 'no DNS server address supplied (use -ServerAddresses and/or -Ipv6ServerAddresses)' }
    }
    if ($v4Parsed.servers.Count -gt 3 -or $v6Parsed.servers.Count -gt 3) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = 'more than 3 servers per family is refused (payload/typo guard)' }
    }

    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex
    $targets = @()
    if ($AdapterName -or $InterfaceIndex -gt 0) {
        # Explicit instance: never fall back to other adapters.
        $targets = @($sel.targets)
        if ($targets.Count -eq 0) {
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = 'the named adapter/interface is not present or not eligible - no other adapter is touched'; notices = @($sel.notices) }
        }
    } else {
        # No explicit instance: use the interfaces that actually carry a default
        # route (never every adapter on the machine).
        $routeIndexes = @(Get-Nx07DefaultRouteInterfaces)
        $allAdapters = @(Get-Nx07AllAdapters)
        $classes = @($allAdapters | ForEach-Object { Get-Nx07AdapterClassification -Adapter $_ } | Where-Object { $_.eligible -and ($routeIndexes -contains $_.interfaceIndex) })
        $targets = @($classes)
        if ($targets.Count -eq 0) {
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = 'no eligible interface carries a default route (and no adapter was named) - DNS is never changed on a guess'; notices = @($sel.notices) }
        }
    }
    Assert-Nx07JournalReady -JournalRoot $JournalRoot

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($t in $targets) {
        $adapter = $t.adapter
        $idx = [int]$t.interfaceIndex
        $original = Get-Nx07DnsClientState -InterfaceIndex $idx
        if (-not $original.v4ReadOk -and -not $original.v6ReadOk) {
            $results.Add([pscustomobject]@{ tweakId = $tweakId; interfaceIndex = $idx; adapterName = [string]$adapter.Name; outcome = 'Refused'; reason = 'DNS capture failed for both address families - no verified prior state means no mutation' })
            continue
        }
        $originalDescriptor = [pscustomobject]@{
            targetType = 'dnsClientConfig'; interfaceIndex = $idx; interfaceAlias = [string]$adapter.Name
            interfaceGuid = [string]$adapter.InterfaceGuid; v4 = @($original.v4); v6 = @($original.v6)
            v4ReadOk = [bool]$original.v4ReadOk; v6ReadOk = [bool]$original.v6ReadOk
            dhcpV4 = [string]$original.dhcpV4; dhcpV6 = [string]$original.dhcpV6
        }
        $newV4 = @($original.v4)
        $newV6 = @($original.v6)
        if ($v4Parsed.servers.Count -gt 0) { $newV4 = @($v4Parsed.servers) }
        if ($v6Parsed.servers.Count -gt 0) { $newV6 = @($v6Parsed.servers) }
        $modifiedDescriptor = [pscustomobject]@{
            targetType = 'dnsClientConfig'; interfaceIndex = $idx; interfaceAlias = [string]$adapter.Name
            interfaceGuid = [string]$adapter.InterfaceGuid; v4 = @($newV4); v6 = @($newV6)
            changedV4 = ($v4Parsed.servers.Count -gt 0); changedV6 = ($v6Parsed.servers.Count -gt 0)
            probeName = $ProbeName
        }
        $alreadySame = ((Test-Nx07SameStringSet $original.v4 $newV4) -and (Test-Nx07SameStringSet $original.v6 $newV6))
        if ($alreadySame) {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $originalDescriptor -Modified $modifiedDescriptor -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles $Profiles | Out-Null
            $results.Add([pscustomobject]@{ tweakId = $tweakId; interfaceIndex = $idx; adapterName = [string]$adapter.Name; outcome = 'AlreadyAtState'; reason = 'requested DNS servers are already configured on this interface' })
            continue
        }
        $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $originalDescriptor -Modified $modifiedDescriptor -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
        try {
            # Set-DnsClientServerAddress has no family switch: one call sets the
            # interface's complete server list, so the families are combined. An
            # untouched family is carried over explicitly (recorded in modified).
            $combined = @($newV4) + @($newV6)
            Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $combined -ErrorAction Stop
            $after = Get-Nx07DnsClientState -InterfaceIndex $idx
            $writeOk = ((Test-Nx07SameStringSet $after.v4 $newV4) -and (Test-Nx07SameStringSet $after.v6 $newV6))
            $probeServers = @()
            if ($v4Parsed.servers.Count -gt 0) { $probeServers += @($v4Parsed.servers) }
            if ($v6Parsed.servers.Count -gt 0) { $probeServers += @($v6Parsed.servers) }
            $probe = Test-Nx07DnsResolution -Servers @($probeServers) -ProbeName $ProbeName
            $verified = ($writeOk -and $probe.ok)
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $originalDescriptor -Modified $modifiedDescriptor -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $(if ($verified) { '' } else { "writeOk=$writeOk probe=$($probe.reason): $(@($probe.results | ForEach-Object { $_.server + '=' + $_.answered }) -join ', ')" }) -Profiles $Profiles | Out-Null
            if (-not $verified) {
                # MANDATORY auto-rollback (r5 Sophia verify-and-rollback).
                $restoreNote = ''
                try {
                    $notes = Restore-Nx07DnsState -InterfaceIndex $idx -Original $originalDescriptor
                    $restoreNote = ($notes -join '; ')
                } catch { $restoreNote = "auto-rollback failed: $([string]$_.Exception.Message)" }
                Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $originalDescriptor -Modified $modifiedDescriptor -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo "DNS verify failed; auto-rollback: $restoreNote" -Profiles $Profiles | Out-Null
                $results.Add([pscustomobject]@{ tweakId = $tweakId; interfaceIndex = $idx; adapterName = [string]$adapter.Name; outcome = 'Failed'; reason = "verify probe failed ($($probe.reason)); $restoreNote"; probe = $probe })
                continue
            }
        } catch {
            $restoreNote = ''
            try { $restoreNote = ((Restore-Nx07DnsState -InterfaceIndex $idx -Original $originalDescriptor) -join '; ') } catch { $restoreNote = "auto-rollback failed: $([string]$_.Exception.Message)" }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $originalDescriptor -Modified $modifiedDescriptor -Result 'Failed' -Verification 'NotRun' -ErrorInfo "$([string]$_.Exception.Message); $restoreNote" -Profiles $Profiles | Out-Null
            $results.Add([pscustomobject]@{ tweakId = $tweakId; interfaceIndex = $idx; adapterName = [string]$adapter.Name; outcome = 'Failed'; reason = "$([string]$_.Exception.Message); $restoreNote" })
            continue
        }

        # Optional DoH registration (documented cmdlets only; never modifies an
        # existing registration and never removes one it did not add).
        $dohNotes = New-Object System.Collections.Generic.List[string]
        if ($Doh) {
            foreach ($server in @($probeServers)) {
                $tpl = Get-Nx07DohTemplate -ServerAddress $server -ExplicitTemplate $DohTemplate
                if ($null -eq $tpl) { $dohNotes.Add("$server : no known DoH template (supply -DohTemplate)"); continue }
                $existing = $null
                try { $existing = Get-DnsClientDohServerAddress -ServerAddress $server -ErrorAction Stop } catch { $existing = $null }
                if ($null -ne $existing) { $dohNotes.Add("$server : DoH already registered - left untouched"); continue }
                $dohOriginal = [pscustomobject]@{ targetType = 'dohRegistration'; serverAddress = $server; preExisted = $false }
                $dohModified = [pscustomobject]@{ targetType = 'dohRegistration'; serverAddress = $server; dohTemplate = [string]$tpl.template; autoUpgrade = $true; allowFallbackToUdp = $true; provider = [string]$tpl.provider }
                $dohJr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $dohOriginal -Modified $dohModified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
                try {
                    Add-DnsClientDohServerAddress -ServerAddress $server -DohTemplate ([string]$tpl.template) -AutoUpgrade $true -AllowFallbackToUdp $true -ErrorAction Stop | Out-Null
                    $check = Get-DnsClientDohServerAddress -ServerAddress $server -ErrorAction Stop
                    $dohOk = ($null -ne $check)
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $dohOriginal -Modified $dohModified -Result $(if ($dohOk) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($dohOk) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
                    $dohNotes.Add("$server : DoH registered ($($tpl.provider)) seq $($dohJr.seq)")
                } catch {
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $dohOriginal -Modified $dohModified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
                    $dohNotes.Add("$server : DoH registration failed - $([string]$_.Exception.Message)")
                }
            }
        }

        $results.Add([pscustomobject]@{
            tweakId = $tweakId; interfaceIndex = $idx; adapterName = [string]$adapter.Name; outcome = 'Applied'
            journalSeq = $jr.seq; v4 = @($newV4); v6 = @($newV6); probe = $probe
            doh = @($dohNotes.ToArray())
            note = 'resolver choice only - no latency/throughput claim; DoH is optional'
        })
    }
    $all = @($results.ToArray())
    $outcome = 'Skipped'
    if (@($all | Where-Object { $_.outcome -eq 'Failed' }).Count -gt 0) { $outcome = 'Failed' }
    elseif (@($all | Where-Object { $_.outcome -eq 'Applied' }).Count -gt 0) { $outcome = 'Applied' }
    elseif (@($all | Where-Object { $_.outcome -eq 'AlreadyAtState' }).Count -gt 0) { $outcome = 'AlreadyAtState' }
    return [pscustomobject]@{ tweakId = $tweakId; outcome = $outcome; interfaces = $all; notices = @($sel.notices) }
}

# ---------------------------------------------------------------------------
# L. NX07-017 - TCP global parameters (netsh documented; raw prior values journaled)
# ---------------------------------------------------------------------------

function ConvertFrom-Nx07TcpGlobalText {
    <#
        Parser for the documented `netsh int tcp show global` output (English).
        Unknown lines are tolerated (netsh output grows over builds); a capture with
        no recognizable field at all fails CLOSED.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $fields = @{}
    foreach ($line in (([string]$Text) -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -match '^(?<k>[^:]+?)\s*:\s*(?<v>.+)$') {
            $k = $Matches['k'].Trim().ToLowerInvariant()
            $v = $Matches['v'].Trim()
            if (-not $fields.ContainsKey($k)) { $fields[$k] = $v }
        }
    }
    $labelMap = [ordered]@{
        autoTuningLevel    = 'receive window auto-tuning level'
        ecn                = 'ecn capability'
        rss                = 'receive-side scaling state'
        rsc                = 'receive segment coalescing state'
        congestionProvider = 'add-on congestion control provider'
        timestamps         = 'rfc 1323 timestamps'
        initialRto         = 'initial rto'
    }
    $parsed = @{}
    foreach ($key in $labelMap.Keys) {
        $label = $labelMap[$key]
        if ($fields.ContainsKey($label)) { $parsed[$key] = [string]$fields[$label] }
    }
    return [pscustomobject]@{
        parseOk   = ($fields.Count -gt 0)
        fields    = $parsed
        rawFields = $fields
        rawText   = [string]$Text
    }
}

function Get-Nx07TcpGlobalState {
    [CmdletBinding()]
    param()
    $r = Invoke-Nx07Netsh -NetshArgs @('int', 'tcp', 'show', 'global')
    $parsed = ConvertFrom-Nx07TcpGlobalText -Text $r.output
    return [pscustomobject]@{ commandOk = $r.ok; exitCode = $r.exitCode; parseOk = $parsed.parseOk; fields = $parsed.fields; rawText = $parsed.rawText; raw = $r }
}

function Set-Nx07TcpGlobalSetting {
    <#
        NX07-017. With no parameters the function is a READ-ONLY inspection that
        journals a ReportOnly entry (the catalogue calls this 'inspection/config').
        With -AutoTuningLevel / -Ecn it writes through `netsh int tcp set global`,
        journaling the raw prior `show global` output plus the parsed fields.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('', 'normal', 'restricted', 'highlyrestricted', 'disabled', 'experimental')][string]$AutoTuningLevel = '',
        [ValidateSet('', 'enabled', 'disabled', 'default')][string]$Ecn = '',
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [switch]$Approved
    )
    $tweakId = 'NX07-017'
    $state = Get-Nx07TcpGlobalState
    $report = [pscustomobject]@{
        autoTuningLevel = $(if ($state.fields.ContainsKey('autoTuningLevel')) { $state.fields['autoTuningLevel'] } else { $null })
        ecn = $(if ($state.fields.ContainsKey('ecn')) { $state.fields['ecn'] } else { $null })
        rss = $(if ($state.fields.ContainsKey('rss')) { $state.fields['rss'] } else { $null })
        rsc = $(if ($state.fields.ContainsKey('rsc')) { $state.fields['rsc'] } else { $null })
        congestionProvider = $(if ($state.fields.ContainsKey('congestionProvider')) { $state.fields['congestionProvider'] } else { $null })
        timestamps = $(if ($state.fields.ContainsKey('timestamps')) { $state.fields['timestamps'] } else { $null })
        initialRto = $(if ($state.fields.ContainsKey('initialRto')) { $state.fields['initialRto'] } else { $null })
    }
    if (-not $AutoTuningLevel -and -not $Ecn) {
        $readOnlyRecord = [pscustomobject]@{ targetType = 'tcpGlobalReport'; fields = $report; rawText = (Get-Nx07TruncatedText $state.rawText 2000); commandOk = $state.commandOk; parseOk = $state.parseOk }
        if ($JournalRoot -and (Test-Path -LiteralPath $JournalRoot)) {
            $manifestState = Read-NxManifest -Path $JournalRoot
            if ($manifestState.present) {
                Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $readOnlyRecord -Modified $readOnlyRecord -Result 'ReportOnly' -Verification $(if ($state.parseOk) { 'Inspected' } else { 'ParseFailed' }) -Profiles $Profiles | Out-Null
            }
        }
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Inspected'; parseOk = $state.parseOk; fields = $report; raw = (Get-Nx07TruncatedText $state.rawText 2000) }
    }
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    if (-not $state.parseOk) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = "netsh int tcp show global output unparseable - no capture, no mutation: $(Get-Nx07TruncatedText $state.rawText 300)" }
    }
    Assert-Nx07JournalReady -JournalRoot $JournalRoot

    $changes = [ordered]@{}
    if ($AutoTuningLevel) { $changes['autoTuningLevel'] = $AutoTuningLevel }
    if ($Ecn) { $changes['ecn'] = $Ecn }
    $already = $true
    foreach ($k in $changes.Keys) {
        $current = ''
        if ($state.fields.ContainsKey($k)) { $current = [string]$state.fields[$k] }
        if ($current.ToLowerInvariant() -ne ([string]$changes[$k]).ToLowerInvariant()) { $already = $false }
    }
    $original = [pscustomobject]@{ targetType = 'tcpGlobalState'; fields = $report; rawText = (Get-Nx07TruncatedText $state.rawText 4000) }
    $modified = [pscustomobject]@{ targetType = 'tcpGlobalState'; changes = $changes; appliedBy = 'netsh int tcp set global' }
    if ($already) {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'AlreadyAtState'; reason = 'requested TCP global values already match'; fields = $report }
    }
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        if ($changes.Contains('autoTuningLevel')) { Invoke-Nx07Netsh -NetshArgs @('int', 'tcp', 'set', 'global', ("autotuninglevel=" + [string]$changes['autoTuningLevel'])) -RequireSuccess | Out-Null }
        if ($changes.Contains('ecn')) { Invoke-Nx07Netsh -NetshArgs @('int', 'tcp', 'set', 'global', ("ecncapability=" + [string]$changes['ecn'])) -RequireSuccess | Out-Null }
        $after = Get-Nx07TcpGlobalState
        $verified = $true
        foreach ($k in $changes.Keys) {
            $now = ''
            if ($after.fields.ContainsKey($k)) { $now = [string]$after.fields[$k] }
            if ($now.ToLowerInvariant() -ne ([string]$changes[$k]).ToLowerInvariant()) { $verified = $false }
        }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            foreach ($k in $changes.Keys) {
                $origValue = [string]$report.$k
                if ($origValue) {
                    if ($k -eq 'autoTuningLevel') { Invoke-Nx07Netsh -NetshArgs @('int', 'tcp', 'set', 'global', ("autotuninglevel=" + $origValue)) | Out-Null }
                    if ($k -eq 'ecn') { Invoke-Nx07Netsh -NetshArgs @('int', 'tcp', 'set', 'global', ("ecncapability=" + $origValue)) | Out-Null }
                }
            }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo 'tcp global values did not verify after set; best-effort restore attempted' -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = 'values did not verify; best-effort restore attempted'; original = $report }
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = [string]$_.Exception.Message; original = $report }
    }
    return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Applied'; journalSeq = $jr.seq; original = $report; modified = $changes }
}

# ---------------------------------------------------------------------------
# M. NX07-018 - MTU (per interface, per address family)
# ---------------------------------------------------------------------------

function Get-Nx07InterfaceMtuValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$InterfaceIndex, [Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$AddressFamily)
    try {
        $i = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily $AddressFamily -ErrorAction Stop
        if ($null -eq $i) { return [pscustomobject]@{ found = $false; mtu = $null; mtuAvailable = $false } }
        # A disconnected/never-configured interface exposes no NlMtuBytes. That is
        # reported honestly instead of being coerced to 0.
        $mtu = $null
        if ($null -ne $i.NlMtuBytes) { $mtu = [int]$i.NlMtuBytes }
        return [pscustomobject]@{ found = $true; mtu = $mtu; mtuAvailable = ($null -ne $mtu); dhcp = [string]$i.Dhcp }
    } catch { return [pscustomobject]@{ found = $false; mtu = $null; mtuAvailable = $false } }
}

function Set-Nx07InterfaceMtu {
    <#
        NX07-018. TROUBLESHOOTING (path-MTU symptom gate), preset-excluded and
        consent-gated. Per-interface and per-family, journaled, verified, restored
        by the standard rollback path. Jumbo-frame consistency is reported (not
        changed here - NX07-010 owns the adapter keyword).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateRange(576, 9000)][int]$Mtu = 1400,
        [ValidateSet('IPv4', 'IPv6', 'Both')][string]$AddressFamily = 'IPv4',
        [string]$AdapterName = '',
        [int]$InterfaceIndex = 0,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [switch]$Approved
    )
    $tweakId = 'NX07-018'
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    $families = @('IPv4')
    if ($AddressFamily -eq 'IPv6') { $families = @('IPv6') }
    if ($AddressFamily -eq 'Both') { $families = @('IPv4', 'IPv6') }
    if ($families -contains 'IPv6' -and $Mtu -lt 1280) {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = 'IPv6 requires an MTU of at least 1280 (documented minimum)' }
    }
    $sel = Get-Nx07AdapterSelection -AdapterName $AdapterName -InterfaceIndex $InterfaceIndex
    $targets = @()
    if ($AdapterName -or $InterfaceIndex -gt 0) {
        $targets = @($sel.targets)
        if ($targets.Count -eq 0) {
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = 'the named adapter/interface is not present or not eligible - no other interface is touched'; notices = @($sel.notices) }
        }
    } else {
        $routeIndexes = @(Get-Nx07DefaultRouteInterfaces)
        $classes = @(Get-Nx07AllAdapters | ForEach-Object { Get-Nx07AdapterClassification -Adapter $_ } | Where-Object { $_.eligible -and ($routeIndexes -contains $_.interfaceIndex) })
        $targets = @($classes)
        if ($targets.Count -eq 0) {
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = 'no eligible interface carries a default route (and none was named) - MTU is never changed on a guess'; notices = @($sel.notices) }
        }
    }
    Assert-Nx07JournalReady -JournalRoot $JournalRoot
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($t in $targets) {
        foreach ($family in $families) {
            $live = Get-Nx07InterfaceMtuValue -InterfaceIndex ([int]$t.interfaceIndex) -AddressFamily $family
            if (-not $live.found) {
                $results.Add([pscustomobject]@{ tweakId = $tweakId; interfaceIndex = [int]$t.interfaceIndex; addressFamily = $family; outcome = 'Skipped'; reason = 'interface/family not present' })
                continue
            }
            if (-not $live.mtuAvailable) {
                $results.Add([pscustomobject]@{ tweakId = $tweakId; interfaceIndex = [int]$t.interfaceIndex; addressFamily = $family; outcome = 'Skipped'; reason = 'interface exposes no MTU value (disconnected or never configured) - connect/link it first' })
                continue
            }
            $original = [pscustomobject]@{ targetType = 'ipInterfaceMtu'; interfaceIndex = [int]$t.interfaceIndex; interfaceAlias = [string]$t.name; addressFamily = $family; mtu = [int]$live.mtu }
            $modified = [pscustomobject]@{ targetType = 'ipInterfaceMtu'; interfaceIndex = [int]$t.interfaceIndex; interfaceAlias = [string]$t.name; addressFamily = $family; mtu = $Mtu }
            if ([int]$live.mtu -eq $Mtu) {
                Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyAtState' -Verification 'NotRun' -Profiles $Profiles | Out-Null
                $results.Add([pscustomobject]@{ tweakId = $tweakId; interfaceIndex = [int]$t.interfaceIndex; addressFamily = $family; outcome = 'AlreadyAtState'; reason = "MTU already $Mtu" })
                continue
            }
            $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
            try {
                Set-NetIPInterface -InterfaceIndex ([int]$t.interfaceIndex) -AddressFamily $family -NlMtuBytes $Mtu -ErrorAction Stop
                $after = Get-Nx07InterfaceMtuValue -InterfaceIndex ([int]$t.interfaceIndex) -AddressFamily $family
                $verified = ($after.found -and [int]$after.mtu -eq $Mtu)
                Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -Profiles $Profiles | Out-Null
                if (-not $verified) {
                    $restoreNote = ''
                    try { Set-NetIPInterface -InterfaceIndex ([int]$t.interfaceIndex) -AddressFamily $family -NlMtuBytes ([int]$original.mtu) -ErrorAction Stop; $restoreNote = 'original MTU written back' } catch { $restoreNote = "restore failed: $([string]$_.Exception.Message)" }
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo "MTU verify failed; $restoreNote" -Profiles $Profiles | Out-Null
                    $results.Add([pscustomobject]@{ tweakId = $tweakId; interfaceIndex = [int]$t.interfaceIndex; addressFamily = $family; outcome = 'Failed'; reason = "verify failed; $restoreNote" })
                    continue
                }
            } catch {
                Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
                $results.Add([pscustomobject]@{ tweakId = $tweakId; interfaceIndex = [int]$t.interfaceIndex; addressFamily = $family; outcome = 'Failed'; reason = [string]$_.Exception.Message })
                continue
            }
            $jumboNote = ''
            if ($Mtu -gt 1500) {
                $jumbo = Get-Nx07AdvancedProperty -Adapter $t.adapter -RegistryKeyword '*JumboPacket'
                if ($jumbo.present -and $jumbo.registryValue -eq '1514') {
                    $jumboNote = 'adapter jumbo-frame keyword is still Disabled (1514): an MTU above 1500 needs a matching jumbo setting (NX07-010) and an end-to-end capable path'
                }
            }
            $results.Add([pscustomobject]@{ tweakId = $tweakId; interfaceIndex = [int]$t.interfaceIndex; addressFamily = $family; outcome = 'Applied'; journalSeq = $jr.seq; originalMtu = [int]$original.mtu; mtu = $Mtu; note = $jumboNote })
        }
    }
    $all = @($results.ToArray())
    $outcome = 'Skipped'
    if (@($all | Where-Object { $_.outcome -eq 'Failed' }).Count -gt 0) { $outcome = 'Failed' }
    elseif (@($all | Where-Object { $_.outcome -eq 'Applied' }).Count -gt 0) { $outcome = 'Applied' }
    elseif (@($all | Where-Object { $_.outcome -eq 'AlreadyAtState' }).Count -gt 0) { $outcome = 'AlreadyAtState' }
    return [pscustomobject]@{ tweakId = $tweakId; outcome = $outcome; interfaces = $all; notices = @($sel.notices) }
}

# ---------------------------------------------------------------------------
# N. NX07-001 / NX07-019 - read-only inventory and diagnostic report
# ---------------------------------------------------------------------------

function Get-Nx07AdapterInventory {
    <#
        NX07-001. Read-only adapter inventory and CAPABILITY report: which
        advanced-property keywords each driver exposes (with the driver's own
        enumerated values), power-management surface, and the exclusion decision
        for every adapter. This is the report an owner reads before selecting any
        other NX07 entry. No mutation, no journal requirement.
    #>
    [CmdletBinding()]
    param(
        [string]$AdapterName = '',
        [int]$InterfaceIndex = 0,
        [string]$OutputFolder = ''
    )
    $all = @(Get-Nx07AllAdapters)
    $classes = @($all | ForEach-Object { Get-Nx07AdapterClassification -Adapter $_ })
    if ($AdapterName) { $classes = @($classes | Where-Object { $_.name -eq $AdapterName }) }
    if ($InterfaceIndex -gt 0) { $classes = @($classes | Where-Object { $_.interfaceIndex -eq $InterfaceIndex }) }

    $adapters = New-Object System.Collections.Generic.List[object]
    foreach ($c in $classes) {
        $a = $c.adapter
        $props = @()
        try {
            foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $c.name -ErrorAction Stop)) {
                $props += [pscustomobject]@{
                    registryKeyword     = [string]$p.RegistryKeyword
                    displayName         = [string]$p.DisplayName
                    currentRegistryValue = (ConvertTo-Nx07ValueString $p.RegistryValue)
                    currentDisplayValue  = [string]$p.DisplayValue
                    validRegistryValues  = @(@($p.ValidRegistryValues) | ForEach-Object { ConvertTo-Nx07ValueString $_ })
                    validDisplayValues   = @(@($p.ValidDisplayValues) | ForEach-Object { [string]$_ })
                }
            }
        } catch { }
        $power = $null
        try {
            $pm = Get-NetAdapterPowerManagement -Name $c.name -ErrorAction Stop
            if ($null -ne $pm) {
                $power = [pscustomobject]@{
                    allowComputerToTurnOffDevice = [string]$pm.AllowComputerToTurnOffDevice
                    selectiveSuspend             = [string]$pm.SelectiveSuspend
                    deviceSleepOnDisconnect      = [string]$pm.DeviceSleepOnDisconnect
                    wakeOnMagicPacket            = [string]$pm.WakeOnMagicPacket
                    wakeOnPattern                = [string]$pm.WakeOnPattern
                    d0PacketCoalescing           = [string]$pm.D0PacketCoalescing
                    arpOffload                   = [string]$pm.ArpOffload
                    nsOffload                    = [string]$pm.NSOffload
                }
            }
        } catch { }
        $rssView = $null
        try { $r = Get-NetAdapterRss -Name $c.name -ErrorAction Stop; if ($null -ne $r) { $rssView = [pscustomobject]@{ numberOfReceiveQueues = [int]$r.NumberOfReceiveQueues; maxProcessors = [int]$r.MaxProcessors } } } catch { }
        $classKey = Find-Nx07AdapterClassKey -InterfaceGuid $c.interfaceGuid
        $adapters.Add([pscustomobject]@{
            name               = $c.name
            interfaceIndex     = $c.interfaceIndex
            interfaceGuid      = $c.interfaceGuid
            interfaceDesc      = $c.interfaceDesc
            pnpDeviceId        = $c.pnpDeviceId
            status             = $c.status
            mediaType          = $c.mediaType
            linkSpeed          = $c.linkSpeed
            maskedMac          = (ConvertTo-Nx07MaskedMac ([string]$a.MacAddress))
            driverVersion      = [string]$a.DriverVersion
            driverProvider     = [string]$a.DriverProvider
            driverDate         = [string]$a.DriverDate
            isEthernet         = $c.isEthernet
            isWifi             = $c.isWifi
            isVirtual          = $c.isVirtual
            tunable            = $c.eligible
            exclusionReason    = $c.reason
            classKeyPath       = $classKey
            advancedPropertyCount = $props.Count
            advancedProperties = @($props)
            powerManagement    = $power
            rssView            = $rssView
        })
    }
    $report = [pscustomobject]@{
        readOnly        = $true
        generatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        adapterCount    = $adapters.Count
        tunableCount    = @($adapters.ToArray() | Where-Object { $_.tunable }).Count
        note            = 'MAC addresses are masked (vendor OUI only). Virtual/VPN/WAN adapters are listed for completeness and excluded from tuning.'
        adapters        = @($adapters.ToArray())
    }
    if ($OutputFolder) {
        $path = Resolve-Nx07ReportPath -OutputFolder $OutputFolder -FileName 'NEXTRIX-NX07-adapter-inventory.json'
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path.filePath -Encoding UTF8
        $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path.filePath -Force
    }
    return $report
}

function Get-Nx07NetworkDiagnosticReport {
    <#
        NX07-019. Read-only diagnostics: adapter statistics, IP configuration,
        default routes, DNS servers, TCP global state, DNS cache entry count.
        Internal DNS names are NOT exported (only a count) - cache content is
        browsing history and stays out of reports.
        pathping is opt-in (-IncludePathPing -PathPingTarget) and can take minutes.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputFolder = '',
        [switch]$IncludePathPing,
        [string]$PathPingTarget = '',
        [string]$JournalRoot = '',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @()
    )
    $tweakId = 'NX07-019'
    $adapters = New-Object System.Collections.Generic.List[object]
    foreach ($a in @(Get-Nx07AllAdapters)) {
        $stats = $null
        try {
            $s = Get-NetAdapterStatistics -Name ([string]$a.Name) -ErrorAction Stop
            if ($null -ne $s) {
                $stats = [pscustomobject]@{
                    receivedBytes = [int64]$s.ReceivedBytes; sentBytes = [int64]$s.SentBytes
                    receivedUnicastPackets = [int64]$s.ReceivedUnicastPackets; sentUnicastPackets = [int64]$s.SentUnicastPackets
                    receivedPacketErrors = [int64]$s.ReceivedPacketErrors; outboundPacketErrors = [int64]$s.OutboundPacketErrors
                    receivedDiscardedPackets = [int64]$s.ReceivedDiscardedPackets; outboundDiscardedPackets = [int64]$s.OutboundDiscardedPackets
                }
            }
        } catch { }
        $adapters.Add([pscustomobject]@{
            name = [string]$a.Name; interfaceIndex = [int]$a.InterfaceIndex; interfaceDesc = [string]$a.InterfaceDescription
            status = [string]$a.Status; mediaType = [string]$a.PhysicalMediaType; linkSpeed = [string]$a.LinkSpeed
            maskedMac = (ConvertTo-Nx07MaskedMac ([string]$a.MacAddress)); driverVersion = [string]$a.DriverVersion
            statistics = $stats
        })
    }
    $ipConfig = @()
    try { $ipConfig = @(Get-NetIPConfiguration -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ interfaceAlias = [string]$_.InterfaceAlias; interfaceIndex = [int]$_.InterfaceIndex; ipv4 = @($_.IPv4Address.IPAddress); gateway = @($_.IPv4DefaultGateway.NextHop); dnsServers = @($_.DNSServer.ServerAddresses) } }) } catch { }
    $routes = @()
    foreach ($prefix in @('0.0.0.0/0', '::/0')) {
        try { $routes += @(Get-NetRoute -DestinationPrefix $prefix -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ destinationPrefix = [string]$_.DestinationPrefix; interfaceAlias = [string]$_.InterfaceAlias; interfaceIndex = [int]$_.InterfaceIndex; nextHop = [string]$_.NextHop; routeMetric = [int]$_.RouteMetric } }) } catch { }
    }
    $dns = @()
    try { $dns = @(Get-DnsClientServerAddress -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ interfaceAlias = [string]$_.InterfaceAlias; interfaceIndex = [int]$_.InterfaceIndex; addressFamily = [string]$_.AddressFamily; servers = @($_.ServerAddresses) } }) } catch { }
    $tcp = Get-Nx07TcpGlobalState
    $cacheCount = $null
    try { $cacheCount = @(Get-DnsClientCache -ErrorAction Stop).Count } catch { $cacheCount = $null }
    $pathpingOutput = ''
    if ($IncludePathPing) {
        if ([string]::IsNullOrWhiteSpace($PathPingTarget) -or $PathPingTarget -notmatch '^[A-Za-z0-9\.\-:]+$') {
            $pathpingOutput = 'pathping skipped: a plain hostname/IP target is required'
        } else {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $raw = & pathping.exe -n -q 10 -p 250 -w 500 $PathPingTarget 2>&1; $pathpingOutput = (Get-Nx07TruncatedText (($raw | ForEach-Object { [string]$_ }) -join "`n") 8000) }
            catch { $pathpingOutput = "pathping failed: $([string]$_.Exception.Message)" }
            finally { $ErrorActionPreference = $prev }
        }
    }
    $report = [pscustomobject]@{
        readOnly        = $true
        generatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        note            = 'Read-only baseline. No latency/throughput verdict is produced; values are raw counters for owner comparison.'
        adapters        = @($adapters.ToArray())
        ipConfiguration = $ipConfig
        defaultRoutes   = $routes
        dnsClient       = $dns
        tcpGlobal       = [pscustomobject]@{ parseOk = $tcp.parseOk; fields = $tcp.fields; raw = (Get-Nx07TruncatedText $tcp.rawText 2000) }
        dnsCacheEntryCount = $cacheCount
        pathPing        = $pathpingOutput
    }
    if ($OutputFolder) {
        $path = Resolve-Nx07ReportPath -OutputFolder $OutputFolder -FileName 'NEXTRIX-NX07-network-diagnostics.json'
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path.filePath -Encoding UTF8
        $report | Add-Member -NotePropertyName reportPath -NotePropertyValue $path.filePath -Force
    }
    if ($JournalRoot -and (Test-Path -LiteralPath $JournalRoot)) {
        $manifestState = Read-NxManifest -Path $JournalRoot
        if ($manifestState.present) {
            $record = [pscustomobject]@{ targetType = 'networkDiagnosticReport'; generatedUtc = $report.generatedUtc; reportPath = $(if ($report.PSObject.Properties['reportPath']) { $report.reportPath } else { $null }) }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $record -Modified $record -Result 'ReportOnly' -Verification 'Inspected' -Profiles $Profiles | Out-Null
        }
    }
    return $report
}

# ---------------------------------------------------------------------------
# O. NX07-020 - DNS cache management (symptom-gated; operation journaled)
# ---------------------------------------------------------------------------

function Clear-Nx07DnsCache {
    <#
        NX07-020. TROUBLESHOOTING: clears the DNS client cache with
        Clear-DnsClientCache. The operation is journaled (with entry counts) but is
        intentionally NOT revertible: a cleared cache repopulates on demand and
        'restoring' it is neither possible nor desirable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [switch]$Approved
    )
    $tweakId = 'NX07-020'
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    Assert-Nx07JournalReady -JournalRoot $JournalRoot
    $before = $null
    try { $before = @(Get-DnsClientCache -ErrorAction Stop).Count } catch { $before = $null }
    $original = [pscustomobject]@{ targetType = 'dnsCacheClear'; entryCountBefore = $before }
    $modified = [pscustomobject]@{ targetType = 'dnsCacheClear'; entryCountExpectedAfter = 0 }
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        Clear-DnsClientCache -ErrorAction Stop
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = [string]$_.Exception.Message }
    }
    $after = $null
    try { $after = @(Get-DnsClientCache -ErrorAction Stop).Count } catch { $after = $null }
    $empty = ($null -ne $after -and $after -eq 0)
    Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result 'Success' -Verification $(if ($empty) { 'Verified' } else { 'Partial' }) -ErrorInfo $(if ($empty) { '' } else { "cache reports $after entries after the flush (concurrent resolution repopulates entries)" }) -Profiles $Profiles | Out-Null
    return [pscustomobject]@{
        tweakId = $tweakId; outcome = 'Applied'; journalSeq = $jr.seq
        entryCountBefore = $before; entryCountAfter = $after; cacheEmpty = $empty
        note = 'operation only - a flushed cache repopulates by design; no restore is possible or needed'
    }
}

# ---------------------------------------------------------------------------
# P. NX07-021 - Network stack reset (TROUBLESHOOTING, consent-gated, irreversible)
# ---------------------------------------------------------------------------

$script:Nx07StackResetConsequences = @(
    'All network adapters are re-enumerated; the network briefly disconnects.',
    'Static IP addresses, custom DNS servers and custom MTUs may be reset by the TCP/IP reset (the pre-state report captures them, but NEXTRIX does not re-apply them automatically).',
    'Winsock catalog entries installed by third-party LSP/AV products are removed; those products may need repair or reinstall.',
    'A reboot is required before the reset is fully in effect.',
    'VPN client adapters and virtual switches may disappear until their product is restarted/reinstalled.',
    'This operation is NOT journal-reversible: the journal records the pre-state and the command list for the owner.'
)

function Get-Nx07NetworkPreState {
    [CmdletBinding()]
    param()
    $adapters = @(Get-Nx07AllAdapters | ForEach-Object {
        [pscustomobject]@{
            name = [string]$_.Name; interfaceIndex = [int]$_.InterfaceIndex; interfaceDesc = [string]$_.InterfaceDescription
            status = [string]$_.Status; mediaType = [string]$_.PhysicalMediaType
            maskedMac = (ConvertTo-Nx07MaskedMac ([string]$_.MacAddress))
        }
    })
    $ipConfigRaw = ''
    try { $ip = & ipconfig.exe /all 2>&1; $ipConfigRaw = (Get-Nx07TruncatedText ((@($ip) | ForEach-Object { [string]$_ }) -join "`n") 6000) } catch { $ipConfigRaw = "ipconfig failed: $([string]$_.Exception.Message)" }
    $dns = @()
    try { $dns = @(Get-DnsClientServerAddress -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ interfaceIndex = [int]$_.InterfaceIndex; interfaceAlias = [string]$_.InterfaceAlias; addressFamily = [string]$_.AddressFamily; servers = @($_.ServerAddresses) } }) } catch { }
    $mtu = @()
    foreach ($family in @('IPv4', 'IPv6')) {
        try { $mtu += @(Get-NetIPInterface -AddressFamily $family -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ interfaceIndex = [int]$_.InterfaceIndex; interfaceAlias = [string]$_.InterfaceAlias; addressFamily = $family; mtu = [int]$_.NlMtuBytes; dhcp = [string]$_.Dhcp } }) } catch { }
    }
    $routes = @()
    try { $routes = @(Get-NetRoute -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ destinationPrefix = [string]$_.DestinationPrefix; interfaceAlias = [string]$_.InterfaceAlias; nextHop = [string]$_.NextHop; routeMetric = [int]$_.RouteMetric } }) } catch { }
    $tcp = Get-Nx07TcpGlobalState
    $winsockCount = $null; $winsockSample = ''
    try {
        $raw = Invoke-Nx07Netsh -NetshArgs @('winsock', 'show', 'catalog')
        $winsockCount = ([regex]::Matches($raw.output, '(?m)^\s*Entry Type:')).Count
        $winsockSample = (Get-Nx07TruncatedText $raw.output 4000)
    } catch { }
    return [pscustomobject]@{
        capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
        adapters = $adapters
        ipConfigRaw = $ipConfigRaw
        dnsClient = $dns
        ipInterfaces = $mtu
        routes = $routes
        tcpGlobal = [pscustomobject]@{ parseOk = $tcp.parseOk; fields = $tcp.fields; raw = (Get-Nx07TruncatedText $tcp.rawText 2000) }
        winsockCatalogEntryCount = $winsockCount
        winsockCatalogSample = $winsockSample
    }
}

function Invoke-Nx07NetworkStackReset {
    <#
        NX07-021. Last-resort TROUBLESHOOTING reset. Requires BOTH -Approved and
        -AcknowledgeConsequences. Captures a full pre-state report, journals the
        command list, runs the three documented resets, and labels the operation
        IRREVERSIBLE (the journal keeps the pre-state for the owner).
        Deliberately NOT included: `netsh advfirewall reset` (destroys user rules),
        IPv6 removal, adapter deletion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [switch]$AcknowledgeConsequences,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [switch]$Approved
    )
    $tweakId = 'NX07-021'
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    if (-not $AcknowledgeConsequences) {
        throw ("tweak ${tweakId}: -AcknowledgeConsequences is required. Consequences:`n - " + ($script:Nx07StackResetConsequences -join "`n - "))
    }
    Assert-Nx07JournalReady -JournalRoot $JournalRoot
    $preState = Get-Nx07NetworkPreState
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $logV4 = Join-Path $JournalRoot ("stack-reset-ipv4-$stamp.log")
    $logV6 = Join-Path $JournalRoot ("stack-reset-ipv6-$stamp.log")
    $commands = @(
        'netsh winsock reset',
        ("netsh int ip reset `"$logV4`""),
        ("netsh int ipv6 reset `"$logV6`"")
    )
    $original = [pscustomobject]@{ targetType = 'networkStackReset'; preState = $preState; consequenceText = $script:Nx07StackResetConsequences }
    $modified = [pscustomobject]@{ targetType = 'networkStackReset'; commands = $commands; rebootRequired = $true; reversible = $false }
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    $outcomes = New-Object System.Collections.Generic.List[object]
    $failed = $false
    try {
        $r1 = Invoke-Nx07Netsh -NetshArgs @('winsock', 'reset')
        $outcomes.Add([pscustomobject]@{ command = 'netsh winsock reset'; exitCode = $r1.exitCode; output = (Get-Nx07TruncatedText $r1.output 400) })
        if (-not $r1.ok) { $failed = $true }
        $r2 = Invoke-Nx07Netsh -NetshArgs @('int', 'ip', 'reset', $logV4)
        $outcomes.Add([pscustomobject]@{ command = 'netsh int ip reset'; exitCode = $r2.exitCode; output = (Get-Nx07TruncatedText $r2.output 400); logFile = $logV4 })
        if (-not $r2.ok) { $failed = $true }
        $r3 = Invoke-Nx07Netsh -NetshArgs @('int', 'ipv6', 'reset', $logV6)
        $outcomes.Add([pscustomobject]@{ command = 'netsh int ipv6 reset'; exitCode = $r3.exitCode; output = (Get-Nx07TruncatedText $r3.output 400); logFile = $logV6 })
        if (-not $r3.ok) { $failed = $true }
    } catch {
        $failed = $true
        $outcomes.Add([pscustomobject]@{ command = 'reset sequence'; exitCode = -1; output = [string]$_.Exception.Message })
    }
    $resultText = 'Success-Irreversible'
    $verification = 'RebootRequired'
    if ($failed) { $resultText = 'Failed-Irreversible'; $verification = 'NotVerified' }
    Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $resultText -Verification $verification -ErrorInfo $(if ($failed) { 'one or more reset commands reported failure; the stack may be partially reset - reboot and review the captured pre-state' } else { '' }) -Profiles $Profiles | Out-Null
    return [pscustomobject]@{
        tweakId = $tweakId; outcome = $(if ($failed) { 'Failed' } else { 'Applied-Gated' })
        journalSeq = $jr.seq; commands = $outcomes; rebootRequired = $true; reversible = $false
        preState = $preState; consequenceText = $script:Nx07StackResetConsequences
        note = 'IRREVERSIBLE by design: the journal stores the pre-state and reset logs, not an automatic restore'
    }
}

# ---------------------------------------------------------------------------
# Q. NX07-022 - Per-game QoS/DSCP profile (opt-in; router-dependent, honest scope)
# ---------------------------------------------------------------------------

function Get-Nx07QosPolicyField {
    param($Policy, [string[]]$Names)
    if ($null -eq $Policy) { return $null }
    foreach ($n in $Names) {
        $p = $Policy.PSObject.Properties[$n]
        if ($null -ne $p -and $null -ne $p.Value) { return [string]$p.Value }
    }
    return $null
}

function Set-Nx07GameQosProfile {
    <#
        NX07-022. Creates ONE per-application QoS policy with a DSCP marking
        (default 46, opt-in). Documented cmdlets only (New-/Get-/Remove-NetQosPolicy),
        persistent local PolicyStore = the computer name.
        Honest scope: DSCP markings are only honored end-to-end when the router/AP
        and path honor them; Windows may also override markings. No latency claim.
        An existing policy with the same name is NEVER overwritten (it may be the
        owner's); rollback removes only the exact policy this function created.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$AppPath,
        [ValidateRange(0, 63)][int]$Dscp = 46,
        [string]$PolicyName = '',
        [ValidateRange(0, 255)][int]$Precedence = 127,
        [string[]]$Profiles = @(),
        [string]$TweakVersion = '1',
        [string]$Approval = 'ExplicitConsent',
        [switch]$Approved
    )
    $tweakId = 'NX07-022'
    if (-not $Approved) { throw "tweak ${tweakId}: real application requires -Approved (nothing applies without explicit approval evidence)" }
    if ([string]::IsNullOrWhiteSpace($AppPath)) { return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = 'a full path to the target game .exe is required (this entry is per-application by design)' } }
    if (-not (Test-Path -LiteralPath $AppPath -PathType Leaf)) { return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = "app path '$AppPath' does not exist or is not a file" } }
    if ([IO.Path]::GetExtension($AppPath).ToLowerInvariant() -ne '.exe') { return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = "app path '$AppPath' is not an .exe" } }
    if ($PolicyName -and $PolicyName -notmatch '^[A-Za-z0-9\-_\. ]{1,60}$') {
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Refused'; reason = "policy name '$PolicyName' must be 1-60 characters of letters, digits, space, dot, dash or underscore" }
    }
    $fullAppPath = (Resolve-Path -LiteralPath $AppPath).Path
    $policyStore = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($PolicyName)) {
        $base = [IO.Path]::GetFileNameWithoutExtension($fullAppPath)
        $safe = [regex]::Replace($base, '[^A-Za-z0-9\-_\.]', '-')
        $PolicyName = "NEXTRIX-QoS-$safe"
    }
    Assert-Nx07JournalReady -JournalRoot $JournalRoot

    $existing = $null
    try { $existing = Get-NetQosPolicy -Name $PolicyName -PolicyStore $policyStore -ErrorAction Stop } catch { $existing = $null }
    if ($null -ne $existing) {
        $skipOriginal = [pscustomobject]@{ targetType = 'qosPolicy'; policyName = $PolicyName; policyStore = $policyStore; existed = $true }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $skipOriginal -Modified $skipOriginal -Result 'PolicyExistsNotOurs' -Verification 'NotRun' -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Skipped'; reason = "a QoS policy named '$PolicyName' already exists - refusing to overwrite or claim it"; policyName = $PolicyName }
    }

    $original = [pscustomobject]@{ targetType = 'qosPolicy'; policyName = $PolicyName; policyStore = $policyStore; existed = $false }
    $modified = [pscustomobject]@{ targetType = 'qosPolicy'; policyName = $PolicyName; policyStore = $policyStore; appPath = $fullAppPath; dscp = $Dscp; precedence = $Precedence; networkProfile = 'All' }
    $jr = Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        New-NetQosPolicy -Name $PolicyName -AppPathNameMatchCondition $fullAppPath -DSCPAction ([sbyte]$Dscp) -PolicyStore $policyStore -NetworkProfile All -Precedence $Precedence -ErrorAction Stop | Out-Null
        $created = Get-NetQosPolicy -Name $PolicyName -PolicyStore $policyStore -ErrorAction Stop
        $liveApp = Get-Nx07QosPolicyField -Policy $created -Names @('AppPathName', 'ApplicationName', 'AppPathNameMatchCondition')
        $liveDscp = Get-Nx07QosPolicyField -Policy $created -Names @('DSCPValue', 'DscpValue', 'DSCPAction')
        $verified = ($null -ne $created)
        if ($verified -and $liveDscp) { $verified = ([string]$liveDscp -eq [string]$Dscp) }
        if ($verified -and $liveApp) { $verified = ([string]$liveApp -eq $fullAppPath) }
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $(if ($verified) { '' } else { "created policy fields did not verify (app='$liveApp', dscp='$liveDscp')" }) -Profiles $Profiles | Out-Null
        if (-not $verified) {
            try { Remove-NetQosPolicy -Name $PolicyName -PolicyStore $policyStore -Confirm:$false -ErrorAction Stop | Out-Null } catch { }
            Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo 'created policy did not verify; attempted removal' -Profiles $Profiles | Out-Null
            return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = "policy created but did not verify (app='$liveApp', dscp='$liveDscp'); removal attempted" }
        }
    } catch {
        Add-NxJournalEntry -Path $JournalRoot -TweakId $tweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles $Profiles | Out-Null
        return [pscustomobject]@{ tweakId = $tweakId; outcome = 'Failed'; reason = [string]$_.Exception.Message }
    }
    return [pscustomobject]@{
        tweakId = $tweakId; outcome = 'Applied'; journalSeq = $jr.seq; policyName = $PolicyName; policyStore = $policyStore
        appPath = $fullAppPath; dscp = $Dscp
        note = 'DSCP marking is only effective end-to-end when the router/AP honors it; no latency claim is made or implied'
    }
}

# ---------------------------------------------------------------------------
# R. NX07 rollback path (only-if-ours, reverse order, per-step journaled)
#    Invoked automatically by NxRollback.ps1 for this category's non-registry
#    target types, and directly for a manual NX07 rollback.
# ---------------------------------------------------------------------------

function Get-Nx07RollbackCandidates {
    # PURE selection logic (no mutation): verified NX07 mutations only.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$JournalEntries)
    $restorableTypes = @('adapterAdvancedProperty', 'adapterPowerManagement', 'dnsClientConfig', 'dohRegistration', 'tcpGlobalState', 'ipInterfaceMtu', 'qosPolicy', 'networkStackReset', 'dnsCacheClear')
    return @($JournalEntries | Where-Object {
        $_.tweakId -like 'NX07-*' -and
        $_.operation -eq 'verify' -and
        (@('Success', 'Success-Irreversible') -contains [string]$_.result) -and
        ($restorableTypes -contains [string]$_.original.targetType)
    })
}

function Invoke-Nx07Rollback {
    <#
        NX07's own reverse replay. Same semantics as NxRollback: integrity-gated,
        reverse journal order, only-if-ours (a value the owner changed after apply
        is reported diverged and NEVER clobbered), every step journaled + verified.
        networkStackReset and dnsCacheClear are reported as not-restorable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId,
        [switch]$AllNx07
    )
    if (-not $TweakId -and -not $AllNx07) {
        throw 'Invoke-Nx07Rollback: specify -TweakId or -AllNx07 (no implicit full-category rollback)'
    }
    $journal = Read-NxJournal -Path $JournalRoot
    if ($journal.integrityErrors.Count -gt 0) {
        return [pscustomobject]@{ aborted = $true; integrityErrors = $journal.integrityErrors; restored = @(); diverged = @(); failed = @(); irreversible = @() }
    }
    $candidates = @(Get-Nx07RollbackCandidates -JournalEntries $journal.entries)
    if ($TweakId) { $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId }) }
    [array]::Reverse($candidates)
    $restored = New-Object System.Collections.Generic.List[object]
    $diverged = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]
    $irreversible = New-Object System.Collections.Generic.List[object]

    foreach ($e in $candidates) {
        $orig = $e.original; $mod = $e.modified
        $type = [string]$orig.targetType
        try {
            if ($type -eq 'adapterAdvancedProperty') {
                $adapter = Get-Nx07AdapterByName -AdapterName ([string]$orig.adapterName)
                if ($null -eq $adapter) {
                    $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = [string]$orig.adapterName; reason = 'adapter no longer present - nothing restored' })
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'adapter missing' -Profiles @($e.profiles) | Out-Null
                    continue
                }
                $cap = Get-Nx07AdvancedProperty -Adapter $adapter -RegistryKeyword ([string]$orig.registryKeyword)
                if (-not $cap.present) {
                    $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "$($orig.adapterName) :: $($orig.registryKeyword)"; reason = 'keyword no longer exposed by the driver - nothing restored' })
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'keyword no longer present' -Profiles @($e.profiles) | Out-Null
                    continue
                }
                if ($cap.registryValue -ne [string]$mod.registryValue) {
                    $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "$($orig.adapterName) :: $($orig.registryKeyword)"; reason = "live '$($cap.registryValue)' differs from NEXTRIX-recorded '$($mod.registryValue)' - left untouched" })
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: live value differs from recorded modified value' -Profiles @($e.profiles) | Out-Null
                    continue
                }
                $setParams = @{ Name = [string]$orig.adapterName; RegistryKeyword = [string]$orig.registryKeyword; RegistryValue = [string]$orig.registryValue; ErrorAction = 'Stop'; NoRestart = $true }
                Set-NetAdapterAdvancedProperty @setParams
                $after = Get-Nx07AdvancedProperty -Adapter $adapter -RegistryKeyword ([string]$orig.registryKeyword)
                $ok = ($after.present -and $after.registryValue -eq [string]$orig.registryValue)
                Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles) | Out-Null
                $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored advanced property'; detail = "$($orig.adapterName) :: $($orig.registryKeyword) -> $($orig.registryValue)"; verified = $ok })
            }
            elseif ($type -eq 'adapterPowerManagement') {
                $live = $null
                try { $live = Get-NetAdapterPowerManagement -Name ([string]$orig.adapterName) -ErrorAction Stop } catch { $live = $null }
                if ($null -eq $live) {
                    $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = [string]$orig.adapterName; reason = 'adapter/power-management surface no longer readable - nothing restored' })
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'power-management surface missing' -Profiles @($e.profiles) | Out-Null
                    continue
                }
                $ours = New-Object System.Collections.Generic.List[string]
                $theirs = New-Object System.Collections.Generic.List[string]
                foreach ($k in @(@($mod.changed) | Where-Object { $_ })) {
                    $pp = $live.PSObject.Properties[$k]
                    $liveValue = $(if ($null -ne $pp) { [string]$pp.Value } else { 'Unavailable' })
                    if ($liveValue -eq [string]$mod.properties.$k) { $ours.Add([string]$k) } else { $theirs.Add("$k (live '$liveValue' vs ours '$($mod.properties.$k)')") }
                }
                if ($ours.Count -eq 0) {
                    $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = [string]$orig.adapterName; reason = "no changed property still matches NEXTRIX state: $($theirs -join '; ')" })
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo ($theirs -join '; ') -Profiles @($e.profiles) | Out-Null
                    continue
                }
                $setParams = @{ Name = [string]$orig.adapterName; ErrorAction = 'Stop'; NoRestart = $true }
                foreach ($k in $ours) { $setParams[[string]$k] = [string]$orig.properties.$k }
                Set-NetAdapterPowerManagement @setParams
                $after = Get-NetAdapterPowerManagement -Name ([string]$orig.adapterName) -ErrorAction Stop
                $ok = $true
                foreach ($k in $ours) { $pp = $after.PSObject.Properties[$k]; if ($null -eq $pp -or [string]$pp.Value -ne [string]$orig.properties.$k) { $ok = $false } }
                Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $(if ($theirs.Count -gt 0) { 'diverged properties left untouched: ' + ($theirs -join '; ') } else { '' }) -Profiles @($e.profiles) | Out-Null
                $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored power management'; detail = "$($orig.adapterName): $($ours -join ', ')"; verified = $ok })
                if ($theirs.Count -gt 0) { $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = [string]$orig.adapterName; reason = ($theirs -join '; ') }) }
            }
            elseif ($type -eq 'dnsClientConfig') {
                $live = Get-Nx07DnsClientState -InterfaceIndex ([int]$orig.interfaceIndex)
                $oursNow = ((Test-Nx07SameStringSet $live.v4 $mod.v4) -and (Test-Nx07SameStringSet $live.v6 $mod.v6))
                if (-not $oursNow) {
                    $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "ifIndex $($orig.interfaceIndex) DNS"; reason = "live DNS ($($live.v4 -join ',') / $($live.v6 -join ',')) differs from NEXTRIX-recorded ($(@($mod.v4) -join ',') / $(@($mod.v6) -join ',')) - left untouched" })
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: live DNS differs' -Profiles @($e.profiles) | Out-Null
                    continue
                }
                $notes = Restore-Nx07DnsState -InterfaceIndex ([int]$orig.interfaceIndex) -Original $orig
                $after = Get-Nx07DnsClientState -InterfaceIndex ([int]$orig.interfaceIndex)
                $bothDhcp = (([string]$orig.dhcpV4 -eq 'Enabled') -and ([string]$orig.dhcpV6 -eq 'Enabled'))
                $origCombined = @(@($orig.v4) + @($orig.v6)) | Where-Object { $_ }
                if ($bothDhcp -or @($origCombined).Count -eq 0) {
                    # Automatic-configuration restore: the reset is the verified action;
                    # DHCP may hand back the same list a moment later.
                    $ok = $true
                } else {
                    $ok = ((Test-Nx07SameStringSet $after.v4 $orig.v4) -and (Test-Nx07SameStringSet $after.v6 $orig.v6))
                }
                Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles) | Out-Null
                $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored DNS'; detail = "ifIndex $($orig.interfaceIndex): $($notes -join '; ')"; verified = $ok })
            }
            elseif ($type -eq 'dohRegistration') {
                if ([bool]$orig.preExisted) { continue }
                $existing = $null
                try { $existing = Get-DnsClientDohServerAddress -ServerAddress ([string]$orig.serverAddress) -ErrorAction Stop } catch { $existing = $null }
                if ($null -eq $existing) {
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Success' -Verification 'Verified' -ErrorInfo 'DoH registration already absent' -Profiles @($e.profiles) | Out-Null
                    $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'DoH registration already absent'; detail = [string]$orig.serverAddress; verified = $true })
                    continue
                }
                Remove-DnsClientDohServerAddress -ServerAddress ([string]$orig.serverAddress) -Confirm:$false -ErrorAction Stop | Out-Null
                $gone = $null
                try { $gone = Get-DnsClientDohServerAddress -ServerAddress ([string]$orig.serverAddress) -ErrorAction Stop } catch { $gone = $null }
                $ok = ($null -eq $gone)
                Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles) | Out-Null
                $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'removed NEXTRIX DoH registration'; detail = [string]$orig.serverAddress; verified = $ok })
            }
            elseif ($type -eq 'tcpGlobalState') {
                $live = Get-Nx07TcpGlobalState
                $restoreKeys = New-Object System.Collections.Generic.List[string]
                $skewed = New-Object System.Collections.Generic.List[string]
                foreach ($k in @($mod.changes.PSObject.Properties.Name)) {
                    $liveValue = ''
                    if ($live.fields.ContainsKey($k)) { $liveValue = [string]$live.fields[$k] }
                    $modValue = [string]$mod.changes.$k
                    if ($liveValue.ToLowerInvariant() -eq $modValue.ToLowerInvariant()) { $restoreKeys.Add([string]$k) }
                    else { $skewed.Add("$k (live '$liveValue' vs ours '$modValue')") }
                }
                foreach ($k in $restoreKeys) {
                    $origValue = [string]$orig.fields.$k
                    if (-not $origValue) { continue }
                    if ($k -eq 'autoTuningLevel') { Invoke-Nx07Netsh -NetshArgs @('int', 'tcp', 'set', 'global', ("autotuninglevel=" + $origValue)) -RequireSuccess | Out-Null }
                    if ($k -eq 'ecn') { Invoke-Nx07Netsh -NetshArgs @('int', 'tcp', 'set', 'global', ("ecncapability=" + $origValue)) -RequireSuccess | Out-Null }
                }
                $after = Get-Nx07TcpGlobalState
                $ok = $true
                foreach ($k in $restoreKeys) {
                    $origValue = [string]$orig.fields.$k
                    if (-not $origValue) { continue }
                    $now = ''
                    if ($after.fields.ContainsKey($k)) { $now = [string]$after.fields[$k] }
                    if ($now.ToLowerInvariant() -ne $origValue.ToLowerInvariant()) { $ok = $false }
                }
                Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -ErrorInfo $(if ($skewed.Count -gt 0) { 'diverged parameters left untouched: ' + ($skewed -join '; ') } else { '' }) -Profiles @($e.profiles) | Out-Null
                $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored TCP global parameters'; detail = ($restoreKeys -join ', '); verified = $ok })
                if ($skewed.Count -gt 0) { $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = 'tcp global'; reason = ($skewed -join '; ') }) }
            }
            elseif ($type -eq 'ipInterfaceMtu') {
                $live = Get-Nx07InterfaceMtuValue -InterfaceIndex ([int]$orig.interfaceIndex) -AddressFamily ([string]$orig.addressFamily)
                if (-not $live.found) {
                    $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "ifIndex $($orig.interfaceIndex) $($orig.addressFamily)"; reason = 'interface/family no longer present - nothing restored' })
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'interface/family missing' -Profiles @($e.profiles) | Out-Null
                    continue
                }
                if (-not $live.mtuAvailable) {
                    $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "ifIndex $($orig.interfaceIndex) $($orig.addressFamily)"; reason = 'interface exposes no MTU value (disconnected) - nothing restored' })
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'no MTU value readable' -Profiles @($e.profiles) | Out-Null
                    continue
                }
                if ([int]$live.mtu -ne [int]$mod.mtu) {
                    $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = "ifIndex $($orig.interfaceIndex) $($orig.addressFamily)"; reason = "live MTU $($live.mtu) differs from NEXTRIX-recorded $($mod.mtu) - left untouched" })
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: live MTU differs' -Profiles @($e.profiles) | Out-Null
                    continue
                }
                Set-NetIPInterface -InterfaceIndex ([int]$orig.interfaceIndex) -AddressFamily ([string]$orig.addressFamily) -NlMtuBytes ([int]$orig.mtu) -ErrorAction Stop
                $after = Get-Nx07InterfaceMtuValue -InterfaceIndex ([int]$orig.interfaceIndex) -AddressFamily ([string]$orig.addressFamily)
                $ok = ($after.found -and [int]$after.mtu -eq [int]$orig.mtu)
                Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles) | Out-Null
                $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'restored MTU'; detail = "ifIndex $($orig.interfaceIndex) $($orig.addressFamily) -> $($orig.mtu)"; verified = $ok })
            }
            elseif ($type -eq 'qosPolicy') {
                $live = $null
                try { $live = Get-NetQosPolicy -Name ([string]$mod.policyName) -PolicyStore ([string]$mod.policyStore) -ErrorAction Stop } catch { $live = $null }
                if ($null -eq $live) {
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Success' -Verification 'Verified' -ErrorInfo 'policy already absent' -Profiles @($e.profiles) | Out-Null
                    $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'QoS policy already absent'; detail = [string]$mod.policyName; verified = $true })
                    continue
                }
                $liveApp = Get-Nx07QosPolicyField -Policy $live -Names @('AppPathName', 'ApplicationName', 'AppPathNameMatchCondition')
                $liveDscp = Get-Nx07QosPolicyField -Policy $live -Names @('DSCPValue', 'DscpValue', 'DSCPAction')
                $ours = ($null -eq $liveApp -or [string]$liveApp -eq [string]$mod.appPath) -and ($null -eq $liveDscp -or [string]$liveDscp -eq [string]$mod.dscp)
                if (-not $ours) {
                    $diverged.Add([pscustomobject]@{ tweakId = $e.tweakId; target = [string]$mod.policyName; reason = "policy changed after apply (app='$liveApp', dscp='$liveDscp') - left untouched" })
                    Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: policy fields differ' -Profiles @($e.profiles) | Out-Null
                    continue
                }
                Remove-NetQosPolicy -Name ([string]$mod.policyName) -PolicyStore ([string]$mod.policyStore) -Confirm:$false -ErrorAction Stop | Out-Null
                $gone = $null
                try { $gone = Get-NetQosPolicy -Name ([string]$mod.policyName) -PolicyStore ([string]$mod.policyStore) -ErrorAction Stop } catch { $gone = $null }
                $ok = ($null -eq $gone)
                Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result $(if ($ok) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($ok) { 'Verified' } else { 'NotVerified' }) -Profiles @($e.profiles) | Out-Null
                $restored.Add([pscustomobject]@{ tweakId = $e.tweakId; action = 'removed NEXTRIX QoS policy'; detail = [string]$mod.policyName; verified = $ok })
            }
            elseif ($type -eq 'networkStackReset' -or $type -eq 'dnsCacheClear') {
                $irreversible.Add([pscustomobject]@{ tweakId = $e.tweakId; target = $type; reason = 'operation is not journal-reversible by design; the pre-state is recorded in the journal entry' })
                Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'rollback' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Skipped-Irreversible' -Verification 'NotRun' -ErrorInfo 'operation labeled irreversible at apply time' -Profiles @($e.profiles) | Out-Null
            }
            else {
                $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = "target type '$type' has no NX07 rollback handler" })
            }
        } catch {
            Add-NxJournalEntry -Path $JournalRoot -TweakId $e.tweakId -TweakVersion $e.tweakVersion -Operation 'failed' -Approval 'RollbackRun' -Original $orig -Modified $mod -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message) -Profiles @($e.profiles) | Out-Null
            $failed.Add([pscustomobject]@{ tweakId = $e.tweakId; reason = [string]$_.Exception.Message })
        }
    }
    return [pscustomobject]@{
        aborted = $false; integrityErrors = @()
        restored = @($restored.ToArray()); diverged = @($diverged.ToArray())
        failed = @($failed.ToArray()); irreversible = @($irreversible.ToArray())
    }
}



