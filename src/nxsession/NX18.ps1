#Requires -Version 5.1
<#
    NX18.ps1 - NEXTRIX Game Session Manager (NX18-001 .. NX18-012).

    SEPARATE runtime subsystem (PROJECT_ARCHITECTURE section 7). This module is
    NOT loaded by src/nxcore/Import-NxCore.ps1; when it is run/dot-sourced on
    its own it dot-sources the core loader itself (see the guard below).

    MUTATION SURFACE (exact, and nothing else):
      1. Session records under -SessionRoot
         (default %ProgramData%\NEXTRIX\Sessions, files session-<guid>.json).
         These are state files of this subsystem, never Windows configuration.
      2. The shared NEXTRIX journal, ONLY through Add-NxJournalEntry and the
         already-existing engine functions:
           - NX19: New-NxCpuSetPlan / Set-NxProcessCpuSets /
                   Set-NxProcessPriority / Invoke-Nx19Rollback
                   (targetTypes processCpuSets / processPriority,
                    session-scoped, journaled by the engine). Process affinity
                    is a separate NX19 opt-in mechanism and is not used by a
                    session (a profile that requests it is rejected).
           - NX09: Set-NxActivePowerPlan / Invoke-NxPowerCfg /
                   Get-NxActivePowerScheme / Get-NxPowerSchemeList
                   (active-scheme switching, journaled by the engine;
                    the session restore step is journaled as a rollback entry)
           - NxApply: Invoke-NxRegistryTweak / Invoke-NxRollback
                   (temporary registry overlay, journaled by the engine)
    Every Windows mutation is therefore covered by the main journal and remains
    restorable through the main rollback engine (category delegation resolves
    Invoke-Nx18Rollback, defined at the end of this file).

    HARD BEHAVIOURAL BOUNDARIES (directive section 11; SECURITY_POLICY):
      - No process is ever terminated or suspended. Background management is a
        priority trim and/or CPU-set steering of EXPLICITLY allowlisted apps.
      - No service is touched (NX18-007 is a read-only plan in this build).
      - No game is ever launched. If the game is not running the start path
        attach-waits for a bounded time and then refuses.
      - Protected process classes (NX18-012) are never managed. The list is
        hard-coded and a user allowlist cannot override it.
      - Restore is verified-step only: a step that did not verify is never
        restored (FSOS-X R11 lesson), and restore is only-if-ours (XOS/FSOS-X/
        WinUtil pattern) - a divergence is reported, never clobbered.
      - A cooldown blocks rapid re-sessions (FSOS-X R8 anti-cheat lesson).
      - No performance claim is made anywhere in this module.
#>

# ---------------------------------------------------------------------------
# 0. Core loader (this module is not part of Import-NxCore, so load it here
#    when the engine is not already in scope).
# ---------------------------------------------------------------------------
if ($null -eq (Get-Command -Name 'Add-NxJournalEntry' -CommandType Function -ErrorAction SilentlyContinue)) {
    $nx18CoreLoader = Join-Path $PSScriptRoot '..\nxcore\Import-NxCore.ps1'
    if (-not (Test-Path -LiteralPath $nx18CoreLoader)) {
        throw "NX18: NxCore loader not found at '$nx18CoreLoader'. This module must sit in src\nxsession next to src\nxcore."
    }
    . $nx18CoreLoader
}

$script:Nx18SchemaVersion = 1
$script:Nx18TweakVersion = '1'
$script:Nx18DefaultCooldownSeconds = 90

$script:Nx18AntiCheatNote = ('Anti-cheat components may refuse CPU-set, affinity or priority changes on a game process. ' +
    'NEXTRIX does not attempt to bypass them: an engine refusal is reported, the step is excluded from the ' +
    'verified-step list, and only verified steps are restored at session end.')

# ---------------------------------------------------------------------------
# 1. NX18-012 protected-process policy (hard-coded; user allowlists cannot
#    override it). Classes: anti-cheat, security, recording, audio, peripherals,
#    launchers. Matching is PowerShell wildcard (-like), case-insensitive, on the
#    image base name and on the raw supplied name.
# ---------------------------------------------------------------------------
$script:Nx18ProtectedPatterns = @(
    # Anti-cheat (never steered, never re-prioritised: the exact class of process
    # that reacts badly to scheduling manipulation).
    [pscustomobject]@{ category = 'AntiCheat'; pattern = 'EasyAntiCheat*' }
    [pscustomobject]@{ category = 'AntiCheat'; pattern = 'BEService*' }
    [pscustomobject]@{ category = 'AntiCheat'; pattern = 'BEService_x64*' }
    [pscustomobject]@{ category = 'AntiCheat'; pattern = 'vgk' }
    [pscustomobject]@{ category = 'AntiCheat'; pattern = 'vgc' }
    [pscustomobject]@{ category = 'AntiCheat'; pattern = 'Ricochet*' }
    # Security stack.
    [pscustomobject]@{ category = 'Security'; pattern = 'MsMpEng' }
    [pscustomobject]@{ category = 'Security'; pattern = 'SecurityHealthService' }
    [pscustomobject]@{ category = 'Security'; pattern = 'NisSrv' }
    [pscustomobject]@{ category = 'Security'; pattern = 'MpDefenderCoreService' }
    # Recording / capture (the Streamer profile preserves capture capacity).
    [pscustomobject]@{ category = 'Recording'; pattern = 'obs64' }
    [pscustomobject]@{ category = 'Recording'; pattern = 'obs32' }
    [pscustomobject]@{ category = 'Recording'; pattern = 'Nvidia Share*' }
    [pscustomobject]@{ category = 'Recording'; pattern = 'AMD*RSServ*' }
    [pscustomobject]@{ category = 'Recording'; pattern = 'Medal*' }
    # Audio engine.
    [pscustomobject]@{ category = 'Audio'; pattern = 'audiodg' }
    [pscustomobject]@{ category = 'Audio'; pattern = 'audiosrv' }
    # Peripherals.
    [pscustomobject]@{ category = 'Peripherals'; pattern = 'iCUE' }
    [pscustomobject]@{ category = 'Peripherals'; pattern = 'G HUB*' }
    [pscustomobject]@{ category = 'Peripherals'; pattern = 'LGHUB*' }
    [pscustomobject]@{ category = 'Peripherals'; pattern = 'Razer*' }
    [pscustomobject]@{ category = 'Peripherals'; pattern = 'Logi*' }
    # Launchers / store clients (protected, never managed; mapping only).
    [pscustomobject]@{ category = 'Launcher'; pattern = 'steam' }
    [pscustomobject]@{ category = 'Launcher'; pattern = 'steamwebhelper' }
    [pscustomobject]@{ category = 'Launcher'; pattern = 'EpicGamesLauncher' }
    [pscustomobject]@{ category = 'Launcher'; pattern = 'Battle.net*' }
    [pscustomobject]@{ category = 'Launcher'; pattern = 'RiotClientServices' }
    [pscustomobject]@{ category = 'Launcher'; pattern = 'UbisoftConnect*' }
    [pscustomobject]@{ category = 'Launcher'; pattern = 'EA Desktop*' }
    [pscustomobject]@{ category = 'Launcher'; pattern = 'EADesktop*' }
    [pscustomobject]@{ category = 'Launcher'; pattern = 'Origin*' }
)

# Services the session subsystem will never suspend, even in a future build
# (mirror of SECURITY_POLICY section 1.3 for the service class; NX18-007 is
# plan-only in this build and refuses every service).
$script:Nx18NeverTouchServices = @(
    'wuauserv','BITS','UsoSvc','DoSvc','WaaSMedicSvc','TrustedInstaller',
    'Audiosrv','AudioEndpointBuilder','WinDefend','SecurityHealthService',
    'WdNisSvc','Mpssvc','BFE','Winmgmt','StateRepository','ProfSvc','UserMgr',
    'AppXSvc','ClipSVC','Schedule','VSS','swprv','WSearch'
)

# Registry value names a per-game graphics overlay may never write (the
# SECURITY_POLICY banned set, enforced again here because profiles are
# user-authored data and must be validated at the boundary).
$script:Nx18BannedRegistryValueNames = @(
    'EnableLUA','VulnerableDriverBlocklistEnable','SaveZoneInformation',
    'SmartScreenEnabled','MitigationOptions','FeatureSettingsOverride',
    'PreventDeviceEncryption','DisableAntiSpyware','DisableAntiVirus'
)

function Get-Nx18DefaultSessionRoot {
    <# Default session store: %ProgramData%\NEXTRIX\Sessions. Read-only helper. #>
    [CmdletBinding()]
    param()
    $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw 'CommonApplicationData folder is unavailable; pass -SessionRoot explicitly.'
    }
    return (Join-Path $base 'NEXTRIX\Sessions')
}

function Get-Nx18DefaultJournalRoot {
    [CmdletBinding()]
    param()
    $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw 'CommonApplicationData folder is unavailable; pass -JournalRoot explicitly.'
    }
    return (Join-Path $base 'NEXTRIX\Journal')
}

function Get-Nx18UtcNowMs {
    [CmdletBinding()]
    param()
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Resolve-Nx18JournalRoot {
    <#
    .SYNOPSIS
        Resolves the journal root for a session operation.
    .DESCRIPTION
        Session records are untrusted data (the session store is a file
        directory). An explicit -JournalRoot always wins; otherwise the record's
        journalRoot is honoured ONLY when it lies under
        %ProgramData%\NEXTRIX, and the default journal root is used otherwise.
        This prevents a tampered record from pointing recovery at an arbitrary
        journal while the session manager runs elevated.
    #>
    [CmdletBinding()]
    param($Record, [string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    $default = Get-Nx18DefaultJournalRoot
    $fromRecord = [string](Get-Nx18Prop -Object $Record -Name 'journalRoot' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($fromRecord)) {
        try {
            $rootParent = Split-Path -Path $default -Parent
            $full = [IO.Path]::GetFullPath($fromRecord)
            $prefix = $rootParent.TrimEnd('\') + '\'
            if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $full }
        } catch { }
    }
    return $default
}

function ConvertTo-Nx18IsoUtc {
    # Normalizes a JSON round-trip value (string or DateTime) to an ISO-8601 UTC
    # string, so re-saving a parsed record never emits PS 5.1 "/Date(...)/".
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s
}

function Get-Nx18Prop {
    # Safe property access for data read back from JSON or injected by tests.
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    if ($null -eq $p.Value) { return $Default }
    return $p.Value
}

function Set-Nx18Prop {
    # Safe property write for records read back from JSON or supplied by drills:
    # adds the property when a synthetic record does not carry it.
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)][string]$Name, $Value)
    if ($null -eq $Object) { return }
    if ($null -ne $Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Test-Nx18ProtectedProcess {
    <#
    .SYNOPSIS
        NX18-012: is this image name in a protected process class?
    .DESCRIPTION
        Pure, read-only, table-driven. Matching is wildcard, case-insensitive,
        against the image base name AND the raw supplied value. The protected
        list is hard-coded; no profile or allowlist parameter exists, so a user
        allowlist cannot override it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProcessName)
    $raw = $ProcessName.Trim()
    $base = $raw
    if ($raw -match '[\\/]') {
        try { $base = [IO.Path]::GetFileName($raw) } catch { $base = $raw }
    }
    if ($base.ToLowerInvariant().EndsWith('.exe')) { $base = $base.Substring(0, $base.Length - 4) }
    if ($base.Length -eq 0) {
        return [pscustomobject]@{ processName = $ProcessName; protected = $false; category = $null; matchedPattern = $null; reason = 'empty process name' }
    }
    foreach ($p in $script:Nx18ProtectedPatterns) {
        if ($base -like $p.pattern -or $raw -like $p.pattern) {
            return [pscustomobject]@{
                processName    = $ProcessName
                protected      = $true
                category       = $p.category
                matchedPattern = $p.pattern
                reason         = "protected class '$($p.category)' (pattern '$($p.pattern)'): never terminated, suspended, re-prioritised or CPU-steered by a session"
            }
        }
    }
    return [pscustomobject]@{ processName = $ProcessName; protected = $false; category = $null; matchedPattern = $null; reason = 'not in a protected class' }
}

function Get-Nx18ProtectedPolicy {
    <# NX18-012: the hard-coded protected policy as data (read-only). #>
    [CmdletBinding()]
    param([string]$Category)
    $items = @($script:Nx18ProtectedPatterns)
    if ($Category) { $items = @($items | Where-Object { $_.category -eq $Category }) }
    return [pscustomobject]@{
        readOnly = $true
        userOverrideAllowed = $false
        categories = @('AntiCheat','Security','Recording','Audio','Peripherals','Launcher')
        entries = $items
        note = 'Hard-coded guard (NX18-012). A session never terminates, suspends, re-prioritises or CPU-steers these processes; user allowlists cannot override this list.'
    }
}

function Get-Nx18LauncherMapping {
    <# NX18-002: launcher class mapping (detection only; launchers are protected). #>
    [CmdletBinding()]
    param()
    $entries = @(Get-Nx18ProtectedPolicy -Category 'Launcher').entries
    return [pscustomobject]@{
        readOnly = $true
        managed  = $false
        note     = 'Launcher processes are identified as ancestors and protected (NX18-012); a session never manages them. Trusted-launcher attach variants are not asserted by this build.'
        entries  = $entries
    }
}

function Resolve-Nx18GameIdentity {
    <# Normalizes -GameExe (full path or image name) to an image name, read-only. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GameExe)
    $issues = New-Object System.Collections.Generic.List[string]
    $raw = $GameExe.Trim()
    $leaf = $raw
    if ($raw.Length -eq 0) { $issues.Add('GameExe is empty.') }
    if ($raw -match '[\*\?]') { $issues.Add('GameExe contains a wildcard; an exact image name or path is required.') }
    if ($raw -match '[\\/]') {
        try { $leaf = [IO.Path]::GetFileName($raw) } catch { $issues.Add('GameExe path could not be parsed.') }
    }
    if ([string]::IsNullOrWhiteSpace($leaf)) { $issues.Add('GameExe has no file name.') }
    $image = $leaf
    if ($image.Length -gt 0 -and -not $image.ToLowerInvariant().EndsWith('.exe')) { $image = $image + '.exe' }
    $baseName = $image
    if ($baseName.ToLowerInvariant().EndsWith('.exe')) { $baseName = $baseName.Substring(0, $baseName.Length - 4) }
    if ($baseName -match '[<>:"/\\|?*]') { $issues.Add('GameExe image name contains characters Windows does not allow.') }
    if ($baseName.Length -eq 0 -or $baseName.Length -gt 260) { $issues.Add('GameExe image name length is invalid.') }
    return [pscustomobject]@{
        valid      = ($issues.Count -eq 0)
        issues     = $issues.ToArray()
        imageName  = $(if ($issues.Count -eq 0) { $image } else { $null })
        baseName   = $(if ($issues.Count -eq 0) { $baseName } else { $null })
        sourcePath = $(if ($raw -match '[\\/]') { $raw } else { $null })
    }
}

function Get-Nx18ProcessTable {
    <#
    .SYNOPSIS
        NX18-001 support: read-only process table (never enumerates-and-kills).
    .DESCRIPTION
        With -ProcessTable the caller supplies a simulated table (self-tests and
        the recovery drill); nothing on the host is read. Without it the live
        table is read with Get-CimInstance Win32_Process and falls back to
        Get-Process (parent ids then unavailable, reported honestly).
    #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$ProcessTable)
    $injected = $PSBoundParameters.ContainsKey('ProcessTable')
    if ($injected) {
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($p in @($ProcessTable)) {
            if ($null -eq $p) { continue }
            $rows.Add([pscustomobject]@{
                id          = [int](Get-Nx18Prop -Object $p -Name 'id' -Default 0)
                processName = [string](Get-Nx18Prop -Object $p -Name 'processName' -Default '')
                parentId    = $(if ($null -ne (Get-Nx18Prop -Object $p -Name 'parentId' -Default $null)) { [int](Get-Nx18Prop -Object $p -Name 'parentId') } else { $null })
                path        = (Get-Nx18Prop -Object $p -Name 'path' -Default $null)
            })
        }
        return [pscustomobject]@{ readOnly = $true; injected = $true; available = $true; parentAvailable = $true; processes = $rows.ToArray(); reason = 'simulated process table supplied by the caller' }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath -ErrorAction Stop)
        foreach ($p in $procs) {
            $rows.Add([pscustomobject]@{ id = [int]$p.ProcessId; processName = [string]$p.Name; parentId = [int]$p.ParentProcessId; path = $p.ExecutablePath })
        }
        return [pscustomobject]@{ readOnly = $true; injected = $false; available = $true; parentAvailable = $true; processes = $rows.ToArray(); reason = $null }
    } catch {
        $cimReason = [string]$_.Exception.Message
        $rows = New-Object System.Collections.Generic.List[object]
        try {
            foreach ($p in @(Get-Process -ErrorAction Stop)) {
                $rows.Add([pscustomobject]@{ id = [int]$p.Id; processName = ([string]$p.ProcessName + '.exe'); parentId = $null; path = $null })
            }
            return [pscustomobject]@{ readOnly = $true; injected = $false; available = $true; parentAvailable = $false; processes = $rows.ToArray(); reason = "parent process ids unavailable: $cimReason" }
        } catch {
            return [pscustomobject]@{ readOnly = $true; injected = $false; available = $false; parentAvailable = $false; processes = @(); reason = "process table unavailable: $($_.Exception.Message)" }
        }
    }
}

function ConvertTo-Nx18BaseName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $n = $Name.Trim()
    if ($n.ToLowerInvariant().EndsWith('.exe')) { $n = $n.Substring(0, $n.Length - 4) }
    return $n.ToLowerInvariant()
}

function Find-Nx18GameProcess {
    <#
    .SYNOPSIS
        NX18-001: detect running instances of a game image; NX18-002: map the
        launcher relationship. Detection only - no process is touched.
    .DESCRIPTION
        Returns matched processes plus the launcher ancestors found through the
        parent chain. A protected game image (a launcher or an anti-cheat name
        passed as -GameExe) is refused: a session never targets a protected
        class. If the game is not running, matched=false - the caller decides
        whether to attach-wait (a game is never launched by NEXTRIX).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GameExe,
        [AllowNull()][object[]]$ProcessTable
    )
    $id = Resolve-Nx18GameIdentity -GameExe $GameExe
    if (-not $id.valid) {
        return [pscustomobject]@{ readOnly = $true; valid = $false; matched = $false; imageName = $null; processes = @(); launchers = @(); reason = ($id.issues -join ' ') }
    }
    $guard = Test-Nx18ProtectedProcess -ProcessName $id.imageName
    if ($guard.protected) {
        return [pscustomobject]@{ readOnly = $true; valid = $false; matched = $false; imageName = $id.imageName; processes = @(); launchers = @(); protected = $true; reason = "refusing '$($id.imageName)': $($guard.reason)" }
    }
    if ($PSBoundParameters.ContainsKey('ProcessTable')) { $table = Get-Nx18ProcessTable -ProcessTable $ProcessTable }
    else { $table = Get-Nx18ProcessTable }
    if (-not $table.available) {
        return [pscustomobject]@{ readOnly = $true; valid = $false; matched = $false; imageName = $id.imageName; processes = @(); launchers = @(); reason = $table.reason }
    }
    $wanted = ConvertTo-Nx18BaseName -Name $id.imageName
    $hits = @($table.processes | Where-Object { (ConvertTo-Nx18BaseName -Name ([string]$_.processName)) -eq $wanted })
    $launchers = @()
    if ($hits.Count -gt 0 -and $table.parentAvailable) {
        $lookup = @{}
        foreach ($row in @($table.processes)) { $lookup[[int]$row.id] = $row }
        $seen = @{}
        foreach ($m in $hits) {
            $parentId = $m.parentId
            $depth = 0
            while ($null -ne $parentId -and $depth -lt 10 -and -not $seen.ContainsKey("$($m.id)|$parentId")) {
                $seen["$($m.id)|$parentId"] = $true
                if (-not $lookup.ContainsKey([int]$parentId)) { break }
                $parent = $lookup[[int]$parentId]
                $pGuard = Test-Nx18ProtectedProcess -ProcessName ([string]$parent.processName)
                if ($pGuard.protected -and $pGuard.category -eq 'Launcher') {
                    $launchers += [pscustomobject]@{ id = [int]$parent.id; processName = [string]$parent.processName; category = $pGuard.category; protected = $true }
                }
                $parentId = $parent.parentId
                $depth++
            }
        }
    }
    return [pscustomobject]@{
        readOnly      = $true
        valid         = $true
        matched       = ($hits.Count -gt 0)
        imageName     = $id.imageName
        processCount  = $hits.Count
        processes     = @($hits | ForEach-Object { [pscustomobject]@{ id = [int]$_.id; processName = [string]$_.processName } })
        launchers     = $launchers
        parentAvailable = $table.parentAvailable
        reason        = $(if ($hits.Count -gt 0) { $null } else { "no running process matches image name '$($id.imageName)'" })
    }
}

# ---------------------------------------------------------------------------
# 2. NX18-003 game session profiles (user-authored JSON)
# ---------------------------------------------------------------------------

function Test-Nx18RegistryOverrides {
    <# Validates a per-game registry overlay list (boundary validation). #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$Overrides)
    $issues = New-Object System.Collections.Generic.List[string]
    $list = @($Overrides | Where-Object { $null -ne $_ })
    if ($list.Count -gt 8) { $issues.Add('graphics.registry holds more than 8 overrides; the bounded maximum is 8.') }
    $seen = @{}
    $index = 0
    foreach ($o in $list) {
        $index++
        $label = "graphics.registry[$index]"
        $path = [string](Get-Nx18Prop -Object $o -Name 'path' -Default '')
        $name = [string](Get-Nx18Prop -Object $o -Name 'name' -Default '')
        $kind = [string](Get-Nx18Prop -Object $o -Name 'kind' -Default '')
        $hasValue = $null -ne (Get-Nx18Prop -Object $o -Name 'value' -Default $null)
        if ([string]::IsNullOrWhiteSpace($path)) { $issues.Add("$label : path is empty.") }
        elseif ($path -notmatch '^(HKCU:\\|HKLM:\\SOFTWARE\\)') { $issues.Add("$label : path must be HKCU:\... or HKLM:\SOFTWARE\... (sessions never write HKLM:\SYSTEM).") }
        if ($path -match 'ControlSet00[12]') { $issues.Add("$label : direct ControlSet001/002 paths are forbidden.") }
        if ([string]::IsNullOrWhiteSpace($name)) { $issues.Add("$label : name is empty.") }
        if (@('DWord','String') -notcontains $kind) { $issues.Add("$label : kind must be DWord or String.") }
        if (-not $hasValue) { $issues.Add("$label : value is required.") }
        if ($name -and (@($script:Nx18BannedRegistryValueNames) -contains $name)) {
            $issues.Add("$label : '$name' is on the SECURITY_POLICY banned target list and can never be written by a session.")
        }
        if ($kind -eq 'DWord' -and $hasValue) {
            $n = [int64]0
            if (-not [int64]::TryParse(([string](Get-Nx18Prop -Object $o -Name 'value')), [ref]$n) -or $n -lt 0 -or $n -gt 4294967295) {
                $issues.Add("$label : DWord value is not a 0..4294967295 integer.")
            }
        }
        $key = ("$path|$name").ToLowerInvariant()
        if ($seen.ContainsKey($key)) { $issues.Add("$label : duplicate target $path :: $name.") } else { $seen[$key] = $true }
    }
    return [pscustomobject]@{ valid = ($issues.Count -eq 0); issues = $issues.ToArray(); count = $list.Count }
}

function Test-Nx18Profile {
    <# Validates a user-authored session profile object. Pure. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile, [string]$Name = '')
    $issues = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $schema = Get-Nx18Prop -Object $Profile -Name 'schemaVersion' -Default 0
    if ([int]$schema -ne 1) { $issues.Add("schemaVersion must be 1 (got '$schema').") }
    $profileName = [string](Get-Nx18Prop -Object $Profile -Name 'profileName' -Default '')
    if ([string]::IsNullOrWhiteSpace($profileName)) { $issues.Add('profileName is required.') }
    elseif ($Name -and $profileName -ne $Name) { $issues.Add("profileName '$profileName' does not match the requested profile '$Name'.") }

    $game = Get-Nx18Prop -Object $Profile -Name 'game' -Default $null
    $gameExe = [string](Get-Nx18Prop -Object $game -Name 'exe' -Default '')
    if ($gameExe) {
        $gameId = Resolve-Nx18GameIdentity -GameExe $gameExe
        if (-not $gameId.valid) { $issues.Add("game.exe: $($gameId.issues -join ' ')") }
        else {
            $g = Test-Nx18ProtectedProcess -ProcessName $gameId.imageName
            if ($g.protected) { $issues.Add("game.exe '$($gameId.imageName)' is a protected class ($($g.category)); a session never targets it.") }
        }
    }

    $sched = Get-Nx18Prop -Object $Profile -Name 'scheduling' -Default $null
    $cpuProfile = [string](Get-Nx18Prop -Object $sched -Name 'cpuSetProfile' -Default '')
    if ($cpuProfile -and (@('Competitive','Balanced','Streaming','Productivity') -notcontains $cpuProfile)) {
        $issues.Add("scheduling.cpuSetProfile '$cpuProfile' is not one of Competitive, Balanced, Streaming, Productivity.")
    }
    if ([bool](Get-Nx18Prop -Object $sched -Name 'applyAffinity' -Default $false)) {
        $issues.Add('scheduling.applyAffinity is not supported: affinity stays a separate opt-in NX19 mechanism; session profiles use CPU Sets only.')
    }

    $priority = Get-Nx18Prop -Object $Profile -Name 'priority' -Default $null
    $gamePriority = [string](Get-Nx18Prop -Object $priority -Name 'gamePriorityClass' -Default '')
    if ($gamePriority -and (@('Idle','BelowNormal','Normal','AboveNormal') -notcontains $gamePriority)) {
        $issues.Add("priority.gamePriorityClass '$gamePriority' is not allowed; High and RealTime are refused by design (NX19-005) and only Idle, BelowNormal, Normal, AboveNormal are accepted.")
    }

    $power = Get-Nx18Prop -Object $Profile -Name 'power' -Default $null
    $targetPlan = [string](Get-Nx18Prop -Object $power -Name 'targetPlan' -Default '')
    if ($targetPlan -and $targetPlan.Length -gt 128) { $issues.Add('power.targetPlan exceeds 128 characters.') }

    $apps = @((Get-Nx18Prop -Object $Profile -Name 'backgroundApps' -Default @()) | Where-Object { $null -ne $_ })
    if ($apps.Count -gt 16) { $issues.Add("backgroundApps holds $($apps.Count) entries; the bounded maximum is 16.") }
    $appSeen = @{}
    $ai = 0
    foreach ($app in $apps) {
        $ai++
        $label = "backgroundApps[$ai]"
        $appName = [string](Get-Nx18Prop -Object $app -Name 'processName' -Default '')
        $appId = Resolve-Nx18GameIdentity -GameExe $appName
        if (-not $appId.valid) { $issues.Add("$label : $($appId.issues -join ' ')") }
        else {
            $guard = Test-Nx18ProtectedProcess -ProcessName $appId.imageName
            if ($guard.protected) { $issues.Add("$label : '$($appId.imageName)' is a protected class ($($guard.category)); user allowlists cannot override the protected list.") }
            $key = ConvertTo-Nx18BaseName -Name $appId.imageName
            if ($appSeen.ContainsKey($key)) { $issues.Add("$label : duplicate allowlist entry '$($appId.imageName)'.") } else { $appSeen[$key] = $true }
        }
        $appPriority = [string](Get-Nx18Prop -Object $app -Name 'priorityClass' -Default 'BelowNormal')
        if (@('Idle','BelowNormal','Normal') -notcontains $appPriority) {
            $issues.Add("$label : priorityClass '$appPriority' is not allowed for a background trim (Idle, BelowNormal, Normal).")
        }
        $mode = [string](Get-Nx18Prop -Object $app -Name 'mode' -Default 'PriorityTrim')
        if (@('PriorityTrim','BackgroundCpuSets') -notcontains $mode) { $issues.Add("$label : mode '$mode' is not PriorityTrim or BackgroundCpuSets.") }
    }

    $graphics = Get-Nx18Prop -Object $Profile -Name 'graphics' -Default $null
    $registry = @((Get-Nx18Prop -Object $graphics -Name 'registry' -Default @()) | Where-Object { $null -ne $_ })
    if ($registry.Count -gt 0) {
        $ro = Test-Nx18RegistryOverrides -Overrides $registry
        foreach ($i in @($ro.issues)) { $issues.Add($i) }
    }
    if (@($registry).Count -eq 0 -and -not $cpuProfile -and -not $gamePriority -and -not $targetPlan -and $apps.Count -eq 0) {
        $warnings.Add('profile declares no session steps; a session started with it would apply nothing.')
    }
    return [pscustomobject]@{ valid = ($issues.Count -eq 0); issues = $issues.ToArray(); warnings = $warnings.ToArray() }
}

function Read-Nx18Profile {
    <#
    .SYNOPSIS
        NX18-003: read and validate a user-authored profile JSON.
    .DESCRIPTION
        Read-only. Profiles live under -ProfileRoot (default
        <SessionRoot>\profiles) and are authored by the user; this function
        never creates, repairs or writes a profile file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfileName,
        [string]$ProfileRoot
    )
    if (-not $ProfileRoot) {
        $ProfileRoot = Join-Path (Get-Nx18DefaultSessionRoot) 'profiles'
    }
    if ([string]::IsNullOrWhiteSpace($ProfileName)) { return [pscustomobject]@{ valid = $false; found = $false; profile = $null; profileHash = $null; path = $null; reason = 'profileName is empty' } }
    if ($ProfileName.Length -gt 64 -or $ProfileName -match '[\\/]' -or $ProfileName.Contains('..')) {
        return [pscustomobject]@{ valid = $false; found = $false; profile = $null; profileHash = $null; path = $null; reason = 'profileName contains a path separator or traversal sequence' }
    }
    $path = Join-Path $ProfileRoot ($ProfileName + '.json')
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ valid = $false; found = $false; profile = $null; profileHash = $null; path = $path; reason = "profile '$ProfileName' not found; profiles are user-authored JSON under '$ProfileRoot' (the session manager never creates one)" }
    }
    $raw = ''
    try { $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 } catch {
        return [pscustomobject]@{ valid = $false; found = $true; profile = $null; profileHash = $null; path = $path; reason = "profile could not be read: $($_.Exception.Message)" }
    }
    try { $profile = $raw | ConvertFrom-Json } catch {
        return [pscustomobject]@{ valid = $false; found = $true; profile = $null; profileHash = $null; path = $path; reason = "profile is not valid JSON: $($_.Exception.Message)" }
    }
    $validation = Test-Nx18Profile -Profile $profile -Name $ProfileName
    $hash = $null
    if (Get-Command -Name 'Get-NxSha256Hex' -CommandType Function -ErrorAction SilentlyContinue) { $hash = Get-NxSha256Hex -Text $raw }
    return [pscustomobject]@{
        valid       = $validation.valid
        found       = $true
        profile     = $profile
        profileHash = $hash
        path        = $path
        issues      = $validation.issues
        warnings    = $validation.warnings
        reason      = $(if ($validation.valid) { $null } else { ($validation.issues -join ' ') })
    }
}

# ---------------------------------------------------------------------------
# 3. Plan derivation (NX18-004..009). Pure: no journal write, no mutation.
# ---------------------------------------------------------------------------

function New-Nx18SessionPlan {
    <#
    .SYNOPSIS
        Computes the per-game session plan from a validated profile.
    .DESCRIPTION
        Read-only. CPU Set IDs are derived by NX19-002 from the topology model
        (never hardcoded); if the topology or the CPU Set map is unavailable the
        step is marked Unavailable with the reason and is never applied. Power
        plan names are resolved at apply time by the NX09 engine. Nothing is
        journaled or written here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [string]$GameImageName,
        [object]$Topology = $null
    )
    $profileName = [string](Get-Nx18Prop -Object $Profile -Name 'profileName' -Default '')
    $steps = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    $notes.Add($script:Nx18AntiCheatNote)
    $stepNo = 0

    # --- CPU Sets for the game (NX18-004; IDs derived by NX19-002) -----------
    $cpuPlan = $null
    $sched = Get-Nx18Prop -Object $Profile -Name 'scheduling' -Default $null
    $cpuProfile = [string](Get-Nx18Prop -Object $sched -Name 'cpuSetProfile' -Default '')
    if ($cpuProfile) {
        $cpuPlan = New-NxCpuSetPlan -Profile $cpuProfile -Topology $Topology
        $stepNo++
        $step = [ordered]@{
            stepId = ('S{0:00}' -f $stepNo)
            tweakId = 'NX18-004'
            targetType = 'processCpuSets'
            processName = $GameImageName
            description = "Steer '$GameImageName' onto the CPU Set selection derived by NX19-002 for profile '$cpuProfile'."
            parameters = [ordered]@{ cpuSetProfile = $cpuProfile; cpuSetIds = @(); logicalProcessors = @(); mechanism = 'SetProcessDefaultCpuSets' }
            preflight = 'Unavailable'
            reason = $null
            uncertainty = @()
        }
        if ($null -eq $cpuPlan -or -not $cpuPlan.topologyAvailable) {
            $step.reason = 'CPU topology is unavailable; no CPU Set ID is fabricated and this step will not be applied.'
        } else {
            $gameRule = @($cpuPlan.rules | Where-Object { $_.class -eq 'Game' } | Select-Object -First 1)
            $step.uncertainty = @($cpuPlan.uncertainty)
            if ($gameRule.Count -eq 0 -or @($gameRule[0].logicalProcessors).Count -eq 0) {
                $step.reason = "NX19-002 derives no Game selection for profile '$cpuProfile' on this topology."
            } elseif (-not $gameRule[0].cpuSetIdsResolved) {
                $step.reason = ("CPU Set IDs are unresolved for logical processors {0}; application will be refused rather than guessing." -f (@($gameRule[0].unresolvedLogicalProcessors) -join ','))
            } else {
                $step.preflight = 'Ready'
                $step.parameters.cpuSetIds = @($gameRule[0].cpuSetIds)
                $step.parameters.logicalProcessors = @($gameRule[0].logicalProcessors)
                if (-not $cpuPlan.restrictive) { $notes.Add("NX19-002 reports the '$cpuProfile' CPU Set plan as non-restrictive on this topology (the game set covers every logical processor).") }
            }
        }
        $steps.Add([pscustomobject]$step)
    }

    # --- Game process priority (NX18-009) ------------------------------------
    $priority = Get-Nx18Prop -Object $Profile -Name 'priority' -Default $null
    $gamePriority = [string](Get-Nx18Prop -Object $priority -Name 'gamePriorityClass' -Default '')
    if ($gamePriority) {
        $stepNo++
        $steps.Add([pscustomobject][ordered]@{
            stepId = ('S{0:00}' -f $stepNo)
            tweakId = 'NX18-009'
            targetType = 'processPriority'
            processName = $GameImageName
            description = "Set the priority class of '$GameImageName' to $gamePriority (documented SetPriorityClass API; session-scoped)."
            parameters = [ordered]@{ priorityClass = $gamePriority }
            preflight = 'Ready'
            reason = $null
            uncertainty = @()
        })
    }

    # --- Allowlisted background apps (NX18-006; trim only, never terminate) --
    $apps = @((Get-Nx18Prop -Object $Profile -Name 'backgroundApps' -Default @()) | Where-Object { $null -ne $_ })
    foreach ($app in $apps) {
        $appName = [string](Get-Nx18Prop -Object $app -Name 'processName' -Default '')
        $appId = Resolve-Nx18GameIdentity -GameExe $appName
        if (-not $appId.valid) { continue }   # profile validation already rejects this
        $mode = [string](Get-Nx18Prop -Object $app -Name 'mode' -Default 'PriorityTrim')
        $appPriority = [string](Get-Nx18Prop -Object $app -Name 'priorityClass' -Default 'BelowNormal')
        $stepNo++
        $step = [ordered]@{
            stepId = ('S{0:00}' -f $stepNo)
            tweakId = 'NX18-006'
            targetType = 'processPriority'
            processName = $appId.imageName
            description = ''
            parameters = [ordered]@{ priorityClass = $appPriority; mode = $mode; cpuSetIds = @() }
            preflight = 'Ready'
            reason = $null
            uncertainty = @()
        }
        if ($mode -eq 'BackgroundCpuSets') {
            $step.targetType = 'processCpuSets'
            $step.description = "Steer allowlisted background app '$($appId.imageName)' onto the NX19-derived Background CPU Set pool."
            $bgRule = $null
            if ($null -ne $cpuPlan -and $cpuPlan.topologyAvailable) {
                $bgRule = @($cpuPlan.rules | Where-Object { $_.class -eq 'Background' } | Select-Object -First 1)
            }
            if ($bgRule.Count -eq 0 -or @($bgRule[0].logicalProcessors).Count -eq 0) {
                $step.preflight = 'Unavailable'
                $step.reason = 'The derived CPU Set plan has no Background pool on this topology; the app is not steered and is never terminated.'
            } elseif (-not $bgRule[0].cpuSetIdsResolved) {
                $step.preflight = 'Unavailable'
                $step.reason = 'Background CPU Set IDs are unresolved on this topology; no ID is fabricated.'
            } else {
                $step.parameters.cpuSetIds = @($bgRule[0].cpuSetIds)
            }
        } else {
            $step.description = "Trim allowlisted background app '$($appId.imageName)' to priority $appPriority (no termination, no suspension)."
        }
        $steps.Add([pscustomobject]$step)
    }

    # --- Temporary power plan (NX18-005) -------------------------------------
    $power = Get-Nx18Prop -Object $Profile -Name 'power' -Default $null
    $targetPlan = [string](Get-Nx18Prop -Object $power -Name 'targetPlan' -Default '')
    if ($targetPlan) {
        $stepNo++
        $steps.Add([pscustomobject][ordered]@{
            stepId = ('S{0:00}' -f $stepNo)
            tweakId = 'NX18-005'
            targetType = 'powerPlanSelection'
            processName = $null
            description = "Switch the active power plan to '$targetPlan' for the session; the NX09 engine records the active scheme and restores it only-if-ours on exit."
            parameters = [ordered]@{ targetPlan = $targetPlan }
            preflight = 'Ready'
            reason = $null
            uncertainty = @('The plan name is resolved and the switch is verified by the NX09 engine at apply time; plan availability is not asserted by the plan step.')
        })
    }

    # --- Temporary graphics registry overlay (NX18-008) ----------------------
    $graphics = Get-Nx18Prop -Object $Profile -Name 'graphics' -Default $null
    $overrides = @((Get-Nx18Prop -Object $graphics -Name 'registry' -Default @()) | Where-Object { $null -ne $_ })
    foreach ($o in $overrides) {
        $stepNo++
        $steps.Add([pscustomobject][ordered]@{
            stepId = ('S{0:00}' -f $stepNo)
            tweakId = 'NX18-008'
            targetType = 'registry'
            processName = $null
            description = ("Temporary registry overlay {0} :: {1} ({2}) for the session; removed on exit only-if-ours." -f (Get-Nx18Prop -Object $o -Name 'path'), (Get-Nx18Prop -Object $o -Name 'name'), (Get-Nx18Prop -Object $o -Name 'kind'))
            parameters = [ordered]@{ override = $o }
            preflight = 'Ready'
            reason = $null
            uncertainty = @()
        })
    }

    if ($steps.Count -eq 0) { $notes.Add('The profile resolves to zero session steps; nothing would be applied.') }
    $unavailable = @($steps | Where-Object { $_.preflight -ne 'Ready' })
    if ($unavailable.Count -gt 0) { $notes.Add("$($unavailable.Count) step(s) are Unavailable and will be skipped with their stated reason.") }
    return [pscustomobject]@{
        readOnly        = $true
        planOnly        = $true
        generatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        profileName     = $profileName
        gameImageName   = $GameImageName
        steps           = $steps.ToArray()
        stepCount       = $steps.Count
        readyCount      = @($steps | Where-Object { $_.preflight -eq 'Ready' }).Count
        unavailableCount = $unavailable.Count
        notes           = $notes.ToArray()
        antiCheatNote   = $script:Nx18AntiCheatNote
    }
}

# ---------------------------------------------------------------------------
# 4. Journaled step application wrappers (engine-delegating; each is guarded)
# ---------------------------------------------------------------------------

function Set-Nx18SessionCpuSetStep {
    <# NX18-004: guard + NX19-003 application, journaled under NX18-004. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProcessName,
        [Parameter(Mandatory)][uint32[]]$CpuSetIds,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string[]]$Profiles = @()
    )
    $guard = Test-Nx18ProtectedProcess -ProcessName $ProcessName
    if ($guard.protected) {
        return [pscustomobject]@{ tweakId = 'NX18-004'; mechanism = 'CpuSet'; processName = $ProcessName; refused = $true; verified = $false; applied = $false; reason = $guard.reason; processes = @() }
    }
    return (Set-NxProcessCpuSets -ProcessName $ProcessName -CpuSetIds $CpuSetIds -JournalRoot $JournalRoot -TweakId 'NX18-004' -TweakVersion $script:Nx18TweakVersion -Approval 'SessionApproved' -Profiles $Profiles)
}

function Set-Nx18SessionGamePriority {
    <# NX18-009: guard + NX19-005 priority class, journaled under NX18-009. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProcessName,
        [Parameter(Mandatory)][ValidateSet('Idle','BelowNormal','Normal','AboveNormal')][string]$PriorityClass,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string[]]$Profiles = @()
    )
    $guard = Test-Nx18ProtectedProcess -ProcessName $ProcessName
    if ($guard.protected) {
        return [pscustomobject]@{ tweakId = 'NX18-009'; mechanism = 'PriorityClass'; processName = $ProcessName; refused = $true; verified = $false; applied = $false; reason = $guard.reason; processes = @() }
    }
    return (Set-NxProcessPriority -ProcessName $ProcessName -PriorityClass $PriorityClass -JournalRoot $JournalRoot -TweakId 'NX18-009' -TweakVersion $script:Nx18TweakVersion -Approval 'SessionApproved' -Profiles $Profiles)
}

function Set-Nx18SessionBackgroundTrim {
    <# NX18-006: guard + priority trim of an ALLOWLISTED app. Never termination. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProcessName,
        [ValidateSet('Idle','BelowNormal','Normal')][string]$PriorityClass = 'BelowNormal',
        [Parameter(Mandatory)][string]$JournalRoot,
        [string[]]$Profiles = @()
    )
    $guard = Test-Nx18ProtectedProcess -ProcessName $ProcessName
    if ($guard.protected) {
        return [pscustomobject]@{ tweakId = 'NX18-006'; mechanism = 'PriorityClass'; processName = $ProcessName; refused = $true; verified = $false; applied = $false; reason = $guard.reason; processes = @(); terminationPerformed = $false; suspensionPerformed = $false }
    }
    $r = Set-NxProcessPriority -ProcessName $ProcessName -PriorityClass $PriorityClass -JournalRoot $JournalRoot -TweakId 'NX18-006' -TweakVersion $script:Nx18TweakVersion -Approval 'SessionApproved' -Profiles $Profiles
    return [pscustomobject]@{
        tweakId = 'NX18-006'; mechanism = 'PriorityClass'; processName = $ProcessName
        refused = [bool]$r.refused; applied = [bool]$r.applied; verified = [bool]$r.verified; reason = $r.reason
        processes = @($r.processes); terminationPerformed = $false; suspensionPerformed = $false
    }
}

function Set-Nx18SessionPowerPlan {
    <# NX18-005: NX09 active-scheme switch (journaled by the NX09 engine). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetPlan,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string[]]$Profiles = @()
    )
    return (Set-NxActivePowerPlan -JournalRoot $JournalRoot -TargetPlan $TargetPlan -Approved -Profiles $Profiles -TweakVersion $script:Nx18TweakVersion -Approval 'SessionApproved')
}

function Set-Nx18SessionGraphicOverlay {
    <# NX18-008: validated temporary registry overlay, journaled by NxApply. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Overrides,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string[]]$Profiles = @()
    )
    $validation = Test-Nx18RegistryOverrides -Overrides $Overrides
    $result = [pscustomobject]@{ tweakId = 'NX18-008'; valid = $validation.valid; issues = $validation.issues; applied = $false; failed = $false; steps = @() }
    if (-not $validation.valid) { return $result }
    $steps = New-Object System.Collections.Generic.List[object]
    foreach ($o in @($Overrides)) {
        $value = Get-Nx18Prop -Object $o -Name 'value'
        $data = [string]([System.Convert]::ToString($value, [System.Globalization.CultureInfo]::InvariantCulture))
        $r = Invoke-NxRegistryTweak -Path ([string](Get-Nx18Prop -Object $o -Name 'path')) -Name ([string](Get-Nx18Prop -Object $o -Name 'name')) -Kind ([string](Get-Nx18Prop -Object $o -Name 'kind')) -Data $data -TweakId 'NX18-008' -TweakVersion $script:Nx18TweakVersion -Approval 'SessionApproved' -JournalRoot $JournalRoot -Profiles $Profiles -Approved
        $steps.Add([pscustomobject]@{ target = "$(Get-Nx18Prop -Object $o -Name 'path') :: $(Get-Nx18Prop -Object $o -Name 'name')"; applied = [bool]$r.applied; failed = [bool]$r.failed })
        if ($r.failed) { $result.failed = $true }
        if ($r.applied) { $result.applied = $true }
    }
    $result.steps = $steps.ToArray()
    return $result
}

function Get-Nx18ServiceSuspensionPlan {
    <#
    .SYNOPSIS
        NX18-007 (Defined): read-only service-suspension plan. No service is
        ever suspended by this build.
    .DESCRIPTION
        Classifies the requested service names against the never-touch classes
        (security/audio/update/core/recovery) and returns an honest plan. No
        journaled service-state engine exists yet, so every service is reported
        as not-implemented: the only mutation-free answer is a refusal.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Services = @())
    $blocked = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($Services)) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $isNeverTouch = (@($script:Nx18NeverTouchServices) | Where-Object { $_ -eq $s }).Count -gt 0
        $blocked.Add([pscustomobject]@{
            service = $s
            neverTouch = $isNeverTouch
            eligible = $false
            reason = $(if ($isNeverTouch) { 'never-touch class (security/audio/update/core/recovery): a session never suspends it' } else { 'no journaled service-state engine exists in this build; suspension is not implemented' })
        })
    }
    return [pscustomobject]@{
        tweakId = 'NX18-007'
        readOnly = $true
        implemented = $false
        servicesTouched = 0
        requested = @($Services)
        entries = $blocked.ToArray()
        reason = 'Service suspension is Defined, not shipped: it needs a journaled service-state engine with dependency checks and auto-restore. This build never touches a service.'
    }
}

# ---------------------------------------------------------------------------
# 5. Session records (own state files; schema family of the journal)
# ---------------------------------------------------------------------------

$script:Nx18StateTransitions = @{
    planned     = @('applied','restoring','interrupted','completed')
    applied     = @('monitoring','restoring','interrupted')
    monitoring  = @('restoring','interrupted')
    restoring   = @('completed','interrupted')
    completed   = @()
    interrupted = @()
}

function Test-Nx18SessionId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionId)
    $g = [guid]::Empty
    if (-not [guid]::TryParse($SessionId, [ref]$g)) { return $false }
    return ($g.ToString('D') -eq $SessionId.ToLowerInvariant())
}

function Get-Nx18SessionFilePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionId, [Parameter(Mandatory)][string]$SessionRoot)
    if (-not (Test-Nx18SessionId -SessionId $SessionId)) { throw "invalid session id '$SessionId' (a GUID is required; no paths)" }
    return (Join-Path $SessionRoot ('session-' + $SessionId.ToLowerInvariant() + '.json'))
}

function New-Nx18SessionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GameExe,
        [Parameter(Mandatory)][string]$GameImageName,
        [Parameter(Mandatory)][string]$ProfileName,
        [string]$ProfileHash,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$JournalRoot,
        [int]$CooldownSeconds = $script:Nx18DefaultCooldownSeconds,
        [object[]]$Launchers = @(),
        [long]$NowUnixMs = 0
    )
    if ($NowUnixMs -le 0) { $NowUnixMs = Get-Nx18UtcNowMs }
    $iso = [DateTimeOffset]::FromUnixTimeMilliseconds($NowUnixMs).UtcDateTime.ToString('o')
    return [pscustomobject][ordered]@{
        schemaVersion     = $script:Nx18SchemaVersion
        sessionId         = [guid]::NewGuid().ToString('D')
        gameExe           = $GameExe
        gameImageName     = $GameImageName
        profileName       = $ProfileName
        profileHash       = $ProfileHash
        state             = 'planned'
        createdAtUtc      = $iso
        createdAtUnixMs   = $NowUnixMs
        updatedAtUtc      = $iso
        updatedUnixMs     = $NowUnixMs
        heartbeatUtc      = $null
        heartbeatUnixMs   = $null
        completedAtUtc    = $null
        completedUnixMs   = $null
        completionKind    = $null
        cooldownSeconds   = $CooldownSeconds
        cooldownUntilUnixMs = $null
        recoveredAtUtc    = $null
        journalRoot       = $JournalRoot
        plan              = @($Plan.steps)
        verifiedSteps     = @()
        applyResult       = @()
        restoreResult     = $null
        launchers         = @($Launchers)
        notes             = @($Plan.notes)
        antiCheatNote     = $Plan.antiCheatNote
    }
}

function Save-Nx18SessionRecord {
    <# Atomic write of one session record. Mutation surface: SessionRoot only. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$SessionRoot)
    $id = [string](Get-Nx18Prop -Object $Record -Name 'sessionId' -Default '')
    if (-not (Test-Nx18SessionId -SessionId $id)) { throw "Save-Nx18SessionRecord: record has no valid sessionId ('$id')" }
    if (-not (Test-Path -LiteralPath $SessionRoot)) { New-Item -Path $SessionRoot -ItemType Directory -Force | Out-Null }
    $nowMs = Get-Nx18UtcNowMs
    Set-Nx18Prop -Object $Record -Name 'updatedUnixMs' -Value $nowMs
    Set-Nx18Prop -Object $Record -Name 'updatedAtUtc' -Value ([DateTimeOffset]::FromUnixTimeMilliseconds($nowMs).UtcDateTime.ToString('o'))
    foreach ($f in @('createdAtUtc','updatedAtUtc','heartbeatUtc','completedAtUtc','recoveredAtUtc')) {
        if ($Record.PSObject.Properties[$f]) { $Record.$f = ConvertTo-Nx18IsoUtc -Value $Record.$f }
    }
    $path = Get-Nx18SessionFilePath -SessionId $id -SessionRoot $SessionRoot
    $tmp = $path + '.tmp'
    $json = $Record | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

function Read-Nx18SessionRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionId, [Parameter(Mandatory)][string]$SessionRoot)
    if (-not (Test-Nx18SessionId -SessionId $SessionId)) {
        return [pscustomobject]@{ found = $false; record = $null; path = $null; reason = "invalid session id '$SessionId'" }
    }
    $path = Get-Nx18SessionFilePath -SessionId $SessionId -SessionRoot $SessionRoot
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ found = $false; record = $null; path = $path; reason = 'session record not found' }
    }
    try {
        $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{ found = $true; record = $record; path = $path; reason = $null }
    } catch {
        return [pscustomobject]@{ found = $false; record = $null; path = $path; reason = "session record could not be parsed: $($_.Exception.Message)" }
    }
}

function Get-Nx18SessionRecords {
    <# Scans the session store. Read-only; never repairs or deletes a record. #>
    [CmdletBinding()]
    param([string]$SessionRoot)
    if (-not $SessionRoot) { $SessionRoot = Get-Nx18DefaultSessionRoot }
    $records = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $SessionRoot)) {
        return [pscustomobject]@{ sessionRoot = $SessionRoot; records = @(); unreadable = @(); present = $false }
    }
    $files = @(Get-ChildItem -LiteralPath $SessionRoot -Filter 'session-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $files) {
        try {
            $r = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $records.Add($r)
        } catch {
            $errors.Add([pscustomobject]@{ path = $f.FullName; reason = [string]$_.Exception.Message })
        }
    }
    return [pscustomobject]@{ sessionRoot = $SessionRoot; records = $records.ToArray(); unreadable = $errors.ToArray(); present = $true }
}

function Test-Nx18SessionTerminal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    $state = [string](Get-Nx18Prop -Object $Record -Name 'state' -Default '')
    return (@('completed','interrupted') -contains $state)
}

function Set-Nx18SessionState {
    <#
    .SYNOPSIS
        Validates and applies one session state transition, then persists it.
    .DESCRIPTION
        State machine: planned -> applied -> monitoring -> restoring ->
        completed, with interrupted reachable from planned/applied/monitoring/
        restoring. Terminal states are final. Illegal transitions throw; they
        are never silently coerced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][ValidateSet('planned','applied','monitoring','restoring','completed','interrupted')][string]$NewState,
        [Parameter(Mandatory)][string]$SessionRoot,
        [string]$CompletionKind,
        [string]$Reason
    )
    $current = [string](Get-Nx18Prop -Object $Record -Name 'state' -Default 'planned')
    if (-not $script:Nx18StateTransitions.ContainsKey($current)) { throw "session '$($Record.sessionId)': unknown current state '$current'" }
    if ($current -ne $NewState) {
        if (@($script:Nx18StateTransitions[$current]) -notcontains $NewState) {
            throw "session '$($Record.sessionId)': illegal state transition '$current' -> '$NewState'"
        }
        Set-Nx18Prop -Object $Record -Name 'state' -Value $NewState
    }
    $nowMs = Get-Nx18UtcNowMs
    if (@('completed','interrupted') -contains $NewState) {
        Set-Nx18Prop -Object $Record -Name 'completedUnixMs' -Value $nowMs
        Set-Nx18Prop -Object $Record -Name 'completedAtUtc' -Value ([DateTimeOffset]::FromUnixTimeMilliseconds($nowMs).UtcDateTime.ToString('o'))
        if ($CompletionKind) { Set-Nx18Prop -Object $Record -Name 'completionKind' -Value $CompletionKind }
        elseif (-not (Get-Nx18Prop -Object $Record -Name 'completionKind' -Default $null)) {
            Set-Nx18Prop -Object $Record -Name 'completionKind' -Value $(if ($NewState -eq 'completed') { 'Normal' } else { 'Interrupted' })
        }
        $cooldown = [int](Get-Nx18Prop -Object $Record -Name 'cooldownSeconds' -Default $script:Nx18DefaultCooldownSeconds)
        Set-Nx18Prop -Object $Record -Name 'cooldownUntilUnixMs' -Value ($nowMs + ([int64]$cooldown * 1000))
    }
    if ($Reason) {
        $note = "state -> $NewState : $Reason"
        $existingNotes = @((Get-Nx18Prop -Object $Record -Name 'notes' -Default @()) | Where-Object { $null -ne $_ })
        Set-Nx18Prop -Object $Record -Name 'notes' -Value (@($existingNotes) + $note)
    }
    return (Save-Nx18SessionRecord -Record $Record -SessionRoot $SessionRoot)
}

function Test-Nx18Cooldown {
    <#
    .SYNOPSIS
        Rapid re-session guard (FSOS-X R8: repeated rapid starts triggered
        anti-cheat false positives, so the start button carries a cooldown).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionRoot,
        [int]$CooldownSeconds = $script:Nx18DefaultCooldownSeconds,
        [long]$NowUnixMs = 0,
        [string]$IgnoreSessionId
    )
    if ($NowUnixMs -le 0) { $NowUnixMs = Get-Nx18UtcNowMs }
    $scan = Get-Nx18SessionRecords -SessionRoot $SessionRoot
    $records = @($scan.records)
    if ($IgnoreSessionId) { $records = @($records | Where-Object { [string](Get-Nx18Prop -Object $_ -Name 'sessionId' -Default '') -ne $IgnoreSessionId }) }
    if ($records.Count -eq 0) {
        return [pscustomobject]@{ allowed = $true; reason = 'NoSessionHistory'; remainingSeconds = 0; activeSessionId = $null; lastSessionId = $null }
    }
    $active = @($records | Where-Object { -not (Test-Nx18SessionTerminal -Record $_) })
    if ($active.Count -gt 0) {
        return [pscustomobject]@{
            allowed = $false; reason = 'ActiveSession'; remainingSeconds = 0
            activeSessionId = [string](Get-Nx18Prop -Object $active[0] -Name 'sessionId' -Default '')
            lastSessionId = [string](Get-Nx18Prop -Object $active[0] -Name 'sessionId' -Default '')
        }
    }
    $latest = @($records | Sort-Object -Property @{ Expression = { [int64](Get-Nx18Prop -Object $_ -Name 'updatedUnixMs' -Default 0) } } -Descending)[0]
    $until = [int64](Get-Nx18Prop -Object $latest -Name 'cooldownUntilUnixMs' -Default 0)
    if ($until -le 0) {
        $updated = [int64](Get-Nx18Prop -Object $latest -Name 'updatedUnixMs' -Default 0)
        $until = $updated + ([int64]$CooldownSeconds * 1000)
    }
    $remainingMs = $until - $NowUnixMs
    if ($remainingMs -gt 0) {
        return [pscustomobject]@{
            allowed = $false; reason = 'Cooldown'
            remainingSeconds = [int][Math]::Ceiling($remainingMs / 1000.0)
            activeSessionId = $null
            lastSessionId = [string](Get-Nx18Prop -Object $latest -Name 'sessionId' -Default '')
        }
    }
    return [pscustomobject]@{ allowed = $true; reason = 'CooldownElapsed'; remainingSeconds = 0; activeSessionId = $null; lastSessionId = [string](Get-Nx18Prop -Object $latest -Name 'sessionId' -Default '') }
}

# ---------------------------------------------------------------------------
# 6. Monitoring (heartbeat + exit detection; injectable probe for drills)
# ---------------------------------------------------------------------------

function Wait-Nx18SessionGameExit {
    <#
    .SYNOPSIS
        Polls for game exit, stamping a heartbeat on every cycle.
    .DESCRIPTION
        Read-only toward the host. -ProcessProbe is a drill hook: it receives
        the cycle number and returns $true while the simulated game is alive.
        -MaxSeconds (0 = unbounded) bounds the loop for drills.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$SessionRoot,
        [int]$PollSeconds = 2,
        [int]$MaxSeconds = 0,
        [object[]]$ProcessTable,
        [scriptblock]$ProcessProbe
    )
    $started = Get-Nx18UtcNowMs
    $cycles = 0
    if ($PSBoundParameters.ContainsKey('ProcessTable') -and $null -eq $ProcessProbe -and $MaxSeconds -le 0) {
        throw 'Wait-Nx18SessionGameExit: a static simulated process table would never report an exit; supply -MaxSeconds (drill) or use the live path.'
    }
    while ($true) {
        $cycles++
        $alive = $false
        if ($null -ne $ProcessProbe) {
            $alive = [bool](& $ProcessProbe $cycles)
        } elseif ($PSBoundParameters.ContainsKey('ProcessTable')) {
            $det = Find-Nx18GameProcess -GameExe ([string]$Record.gameExe) -ProcessTable $ProcessTable
            $alive = [bool]$det.matched
        } else {
            $det = Find-Nx18GameProcess -GameExe ([string]$Record.gameExe)
            $alive = [bool]$det.matched
        }
        if (-not $alive) {
            return [pscustomobject]@{ exited = $true; timedOut = $false; cycles = $cycles; reason = 'game process ended' }
        }
        $nowMs = Get-Nx18UtcNowMs
        Set-Nx18Prop -Object $Record -Name 'heartbeatUnixMs' -Value $nowMs
        Set-Nx18Prop -Object $Record -Name 'heartbeatUtc' -Value ([DateTimeOffset]::FromUnixTimeMilliseconds($nowMs).UtcDateTime.ToString('o'))
        $null = Save-Nx18SessionRecord -Record $Record -SessionRoot $SessionRoot
        if ($MaxSeconds -gt 0 -and ((Get-Nx18UtcNowMs - $started) -ge ([int64]$MaxSeconds * 1000))) {
            return [pscustomobject]@{ exited = $false; timedOut = $true; cycles = $cycles; reason = "monitor bound of ${MaxSeconds}s reached while the game was still running" }
        }
        if ($PollSeconds -gt 0) { Start-Sleep -Seconds $PollSeconds }
    }
}

# ---------------------------------------------------------------------------
# 7. Verified-step restore (reverse order; only-if-ours; journaled)
# ---------------------------------------------------------------------------

function Restore-Nx18PowerPlanStep {
    <#
    .SYNOPSIS
        Restores one session power step precisely.
    .DESCRIPTION
        The session owns ONE active-scheme change. Replaying the NX09 category
        rollback would also walk unrelated NX09-001 applies, so the session
        restore is scoped to its own recorded original/modified GUIDs: switch
        back only when the active scheme is still the session's target (only-if-
        ours), verify by re-read, and journal the restore as a rollback entry
        (never as a new apply entry, so the main journal keeps a clean history).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step, [Parameter(Mandatory)][string]$JournalRoot)
    $result = [pscustomobject]@{
        stepId = [string](Get-Nx18Prop -Object $Step -Name 'stepId' -Default '')
        tweakId = 'NX18-005'; targetType = 'powerPlanSelection'
        restored = @(); diverged = @(); failed = @(); irreversible = @(); verified = $false; reason = $null
    }
    $originalGuid = [string](Get-Nx18Prop -Object $Step -Name 'originalSchemeGuid' -Default '')
    $modifiedGuid = [string](Get-Nx18Prop -Object $Step -Name 'modifiedSchemeGuid' -Default '')
    if (-not $originalGuid -or -not $modifiedGuid) {
        $result.failed = @([pscustomobject]@{ reason = 'session power step carries no scheme GUIDs - refusing to guess' })
        return $result
    }
    $original = [pscustomobject]@{ targetType = 'powerPlanSelection'; schemeGuid = $originalGuid; schemeName = (Get-Nx18Prop -Object $Step -Name 'originalSchemeName' -Default $null) }
    $modified = [pscustomobject]@{ targetType = 'powerPlanSelection'; schemeGuid = $modifiedGuid; schemeName = (Get-Nx18Prop -Object $Step -Name 'modifiedSchemeName' -Default $null) }
    $active = Get-NxActivePowerScheme
    if (-not $active.parseOk) {
        $result.failed = @([pscustomobject]@{ reason = 'powercfg /getactivescheme unparseable - nothing switched' })
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX18-005' -TweakVersion $script:Nx18TweakVersion -Operation 'failed' -Approval 'SessionRestore' -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo 'active scheme unparseable'
        return $result
    }
    if ($active.guid -ne $modifiedGuid) {
        $result.diverged = @([pscustomobject]@{ target = 'active scheme'; reason = "active scheme is '$($active.guid)' but the session recorded '$modifiedGuid' - left untouched for the owner" })
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX18-005' -TweakVersion $script:Nx18TweakVersion -Operation 'rollback' -Approval 'SessionRestore' -Original $original -Modified $modified -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'only-if-ours: active scheme differs from recorded session target'
        return $result
    }
    $list = Get-NxPowerSchemeList
    if (-not $list.parseOk -or (@($list.schemes | Where-Object { $_.guid -eq $originalGuid })).Count -eq 0) {
        $result.diverged = @([pscustomobject]@{ target = 'active scheme'; reason = "original plan '$originalGuid' is not present (or the list is unreadable) - not guessed, nothing switched" })
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX18-005' -TweakVersion $script:Nx18TweakVersion -Operation 'rollback' -Approval 'SessionRestore' -Original $original -Modified $modified -Result 'Diverged' -Verification 'NotRun' -ErrorInfo 'original scheme missing'
        return $result
    }
    try {
        Invoke-NxPowerCfg -PowerCfgArgs @('/setactive', $originalGuid) -RequireSuccess | Out-Null
        $after = Get-NxActivePowerScheme
        $verified = ($after.parseOk -and $after.guid -eq $originalGuid)
        $result.verified = $verified
        if ($verified) { $result.restored = @([pscustomobject]@{ action = 'switched active scheme'; detail = $originalGuid; verified = $true }) }
        else { $result.failed = @([pscustomobject]@{ reason = 'restored scheme did not verify' }) }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX18-005' -TweakVersion $script:Nx18TweakVersion -Operation 'rollback' -Approval 'SessionRestore' -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $(if ($verified) { 'Verified' } else { 'NotVerified' })
    } catch {
        $result.failed = @([pscustomobject]@{ reason = [string]$_.Exception.Message })
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId 'NX18-005' -TweakVersion $script:Nx18TweakVersion -Operation 'failed' -Approval 'SessionRestore' -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo ([string]$_.Exception.Message)
    }
    return $result
}

function Restore-Nx18VerifiedStep {
    <#
    .SYNOPSIS
        Restores one verified session step through the owning engine.
    .DESCRIPTION
        Only callers holding a step from the record's verifiedSteps list may
        call this: an unverified step must never be restored. Engines enforce
        only-if-ours themselves; a divergence is reported, never clobbered.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step, [Parameter(Mandatory)][string]$JournalRoot)
    $tweakId = [string](Get-Nx18Prop -Object $Step -Name 'tweakId' -Default '')
    $mechanism = [string](Get-Nx18Prop -Object $Step -Name 'mechanism' -Default '')
    $targetType = [string](Get-Nx18Prop -Object $Step -Name 'targetType' -Default '')
    $stepId = [string](Get-Nx18Prop -Object $Step -Name 'stepId' -Default '')
    try {
        if ($mechanism -eq 'powerPlanSelection' -or $targetType -eq 'powerPlanSelection') {
            $r = Restore-Nx18PowerPlanStep -Step $Step -JournalRoot $JournalRoot
            $r | Add-Member -NotePropertyName stepId -NotePropertyValue $stepId -Force
            return $r
        }
        if ($tweakId -eq 'NX18-008') {
            $r = Invoke-NxRollback -JournalRoot $JournalRoot -TweakId 'NX18-008'
            return [pscustomobject]@{
                stepId = $stepId; tweakId = $tweakId; targetType = $targetType
                restored = @($r.restored); diverged = @($r.diverged); failed = @($r.failed); irreversible = @($r.irreversible)
                verified = ((@($r.failed).Count -eq 0) -and (@($r.diverged).Count -eq 0)); reason = $null
            }
        }
        if (@('NX18-004','NX18-006','NX18-009') -contains $tweakId) {
            $r = Invoke-Nx19Rollback -JournalRoot $JournalRoot -TweakId $tweakId
            return [pscustomobject]@{
                stepId = $stepId; tweakId = $tweakId; targetType = $targetType
                restored = @($r.restored); diverged = @($r.diverged); failed = @($r.failed); irreversible = @($r.irreversible)
                verified = ((@($r.failed).Count -eq 0) -and (@($r.irreversible).Count -eq 0)); reason = $null
            }
        }
        return [pscustomobject]@{ stepId = $stepId; tweakId = $tweakId; targetType = $targetType; restored = @(); diverged = @(); failed = @([pscustomobject]@{ reason = "no restore engine for tweak '$tweakId' / targetType '$targetType'" }); irreversible = @(); verified = $false; reason = 'unmapped step' }
    } catch {
        return [pscustomobject]@{ stepId = $stepId; tweakId = $tweakId; targetType = $targetType; restored = @(); diverged = @(); failed = @([pscustomobject]@{ reason = [string]$_.Exception.Message }); irreversible = @(); verified = $false; reason = [string]$_.Exception.Message }
    }
}

function Invoke-Nx18SessionRestore {
    <#
    .SYNOPSIS
        Restores the record's verified steps in reverse order and finalizes the
        record. Unverified steps are never touched.
    .DESCRIPTION
        A restore failure leaves the record 'interrupted' (not 'completed') so
        Invoke-NxSessionRecovery can retry; divergences are user-owned and do
        not keep the session open.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$SessionRoot,
        [Parameter(Mandatory)][string]$JournalRoot,
        [scriptblock]$RestoreHandler,
        [string]$CompletionKind = 'Normal'
    )
    if (-not (Test-Nx18SessionTerminal -Record $Record)) {
        $null = Set-Nx18SessionState -Record $Record -NewState 'restoring' -SessionRoot $SessionRoot
    }
    $steps = @($Record.verifiedSteps)
    [array]::Reverse($steps)
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($step in $steps) {
        if ($null -eq $step) { continue }
        if ($null -ne $RestoreHandler) {
            try { $r = & $RestoreHandler $step }
            catch { $r = [pscustomobject]@{ stepId = [string](Get-Nx18Prop -Object $step -Name 'stepId' -Default ''); tweakId = [string](Get-Nx18Prop -Object $step -Name 'tweakId' -Default ''); restored = @(); diverged = @(); failed = @([pscustomobject]@{ reason = [string]$_.Exception.Message }); irreversible = @(); verified = $false; reason = [string]$_.Exception.Message } }
        } else {
            $r = Restore-Nx18VerifiedStep -Step $step -JournalRoot $JournalRoot
        }
        if ($null -eq $r) { $r = [pscustomobject]@{ stepId = ''; tweakId = ''; restored = @(); diverged = @(); failed = @([pscustomobject]@{ reason = 'restore handler returned nothing' }); irreversible = @(); verified = $false } }
        $results.Add($r)
    }
    $allRestored = @($results | ForEach-Object { @($_.restored) })
    $allDiverged = @($results | ForEach-Object { @($_.diverged) })
    $allFailed = @($results | ForEach-Object { @($_.failed) })
    $allIrreversible = @($results | ForEach-Object { @($_.irreversible) })
    $summary = [pscustomobject]@{
        restoredCount = $allRestored.Count
        divergedCount = $allDiverged.Count
        failedCount = $allFailed.Count
        irreversibleCount = $allIrreversible.Count
        steps = $results.ToArray()
        restoreComplete = ($allFailed.Count -eq 0)
        report = 'Only verified steps were restored, in reverse order. Diverged targets are left for the owner; failed steps leave the session interrupted for recovery.'
    }
    Set-Nx18Prop -Object $Record -Name 'restoreResult' -Value $summary
    $finalState = $(if ($allFailed.Count -eq 0) { 'completed' } else { 'interrupted' })
    $kind = $(if ($allFailed.Count -gt 0) { 'RestoreIncomplete' } else { $CompletionKind })
    $null = Set-Nx18SessionState -Record $Record -NewState $finalState -SessionRoot $SessionRoot -CompletionKind $kind
    return $summary
}

# ---------------------------------------------------------------------------
# 8. NX18-011 manual control: start / stop / status
# ---------------------------------------------------------------------------

function Get-Nx18StepOutcome {
    # Internally normalizes an engine summary into one apply-result row.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step, $EngineResult)
    $row = [ordered]@{
        stepId = [string](Get-Nx18Prop -Object $Step -Name 'stepId' -Default '')
        tweakId = [string](Get-Nx18Prop -Object $Step -Name 'tweakId' -Default '')
        targetType = [string](Get-Nx18Prop -Object $Step -Name 'targetType' -Default '')
        processName = (Get-Nx18Prop -Object $Step -Name 'processName' -Default $null)
        status = 'Failed'; verified = $false; journalSeq = $null; detail = $null
        mechanism = $null
        originalSchemeGuid = $null; originalSchemeName = $null; modifiedSchemeGuid = $null; modifiedSchemeName = $null
    }
    if ($null -eq $EngineResult) { $row.detail = 'engine returned no result'; return [pscustomobject]$row }
    $refused = [bool](Get-Nx18Prop -Object $EngineResult -Name 'refused' -Default $false)
    $verified = [bool](Get-Nx18Prop -Object $EngineResult -Name 'verified' -Default $false)
    $reason = [string](Get-Nx18Prop -Object $EngineResult -Name 'reason' -Default '')
    $seq = $null
    foreach ($p in @((Get-Nx18Prop -Object $EngineResult -Name 'processes' -Default @()))) {
        $candidate = Get-Nx18Prop -Object $p -Name 'journalSeq' -Default $null
        if ($null -ne $candidate) { $seq = $candidate; break }
    }
    if ($row.targetType -eq 'powerPlanSelection') {
        $row.mechanism = 'powerPlanSelection'
        $outcome = [string](Get-Nx18Prop -Object $EngineResult -Name 'outcome' -Default '')
        $orig = Get-Nx18Prop -Object $EngineResult -Name 'original' -Default $null
        $mod = Get-Nx18Prop -Object $EngineResult -Name 'modified' -Default $null
        $row.originalSchemeGuid = [string](Get-Nx18Prop -Object $orig -Name 'schemeGuid' -Default '')
        $row.originalSchemeName = [string](Get-Nx18Prop -Object $orig -Name 'schemeName' -Default '')
        $row.modifiedSchemeGuid = [string](Get-Nx18Prop -Object $mod -Name 'schemeGuid' -Default '')
        $row.modifiedSchemeName = [string](Get-Nx18Prop -Object $mod -Name 'schemeName' -Default '')
        $row.journalSeq = Get-Nx18Prop -Object $EngineResult -Name 'journalSeq' -Default $null
        if ($outcome -eq 'Applied') { $row.status = 'Verified'; $row.verified = $true }
        elseif ($outcome -eq 'AlreadyAtState') { $row.status = 'NotNeeded'; $row.verified = $false; $row.detail = 'active plan was already the session target' }
        elseif ($outcome -eq 'Skipped') { $row.status = 'Unavailable'; $row.detail = [string](Get-Nx18Prop -Object $EngineResult -Name 'reason' -Default '') }
        else { $row.detail = $(if ($reason) { $reason } else { $outcome }) }
        return [pscustomobject]$row
    }
    if ($row.targetType -eq 'registry') {
        $applied = [bool](Get-Nx18Prop -Object $EngineResult -Name 'applied' -Default $false)
        $failed = [bool](Get-Nx18Prop -Object $EngineResult -Name 'failed' -Default $false)
        if ($applied -and -not $failed) { $row.status = 'Verified'; $row.verified = $true }
        else { $row.detail = (@(Get-Nx18Prop -Object $EngineResult -Name 'issues' -Default @()) -join '; ') }
        return [pscustomobject]$row
    }
    # Process-scoped engines (NX19 summaries).
    $row.journalSeq = $seq
    if ($refused) { $row.status = 'Refused'; $row.detail = $reason }
    elseif ($verified) { $row.status = 'Verified'; $row.verified = $true }
    else {
        $row.status = 'Failed'
        if (-not $reason) { $reason = (@((Get-Nx18Prop -Object $EngineResult -Name 'processes' -Default @()) | ForEach-Object { [string](Get-Nx18Prop -Object $_ -Name 'reason' -Default '') } | Where-Object { $_ }) -join '; ') }
        $row.detail = $reason
    }
    return [pscustomobject]$row
}

function Invoke-Nx18PlanStep {
    # Dispatches one ready plan step to its journaled engine wrapper.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step, [Parameter(Mandatory)][string]$JournalRoot, [string[]]$Profiles = @())
    $guardName = [string](Get-Nx18Prop -Object $Step -Name 'processName' -Default '')
    if ($guardName) {
        $g = Test-Nx18ProtectedProcess -ProcessName $guardName
        if ($g.protected) {
            throw "protected process '$guardName' ($($g.category)) reached the apply dispatcher - refusing (NX18-012)"
        }
    }
    $targetType = [string](Get-Nx18Prop -Object $Step -Name 'targetType' -Default '')
    $tweakId = [string](Get-Nx18Prop -Object $Step -Name 'tweakId' -Default '')
    $params = Get-Nx18Prop -Object $Step -Name 'parameters' -Default $null
    switch ($targetType) {
        'processCpuSets' {
            $ids = @((Get-Nx18Prop -Object $params -Name 'cpuSetIds' -Default @()) | ForEach-Object { [uint32]$_ })
            if ($ids.Count -eq 0) { throw "step $($Step.stepId): no CPU Set IDs in the plan" }
            if ($tweakId -eq 'NX18-006') {
                # Background steering: allowlisted app, derived Background pool.
                $g = Test-Nx18ProtectedProcess -ProcessName ([string]$Step.processName)
                if ($g.protected) { throw $g.reason }
                return (Set-NxProcessCpuSets -ProcessName ([string]$Step.processName) -CpuSetIds $ids -JournalRoot $JournalRoot -TweakId 'NX18-006' -TweakVersion $script:Nx18TweakVersion -Approval 'SessionApproved' -Profiles $Profiles)
            }
            return (Set-Nx18SessionCpuSetStep -ProcessName ([string]$Step.processName) -CpuSetIds $ids -JournalRoot $JournalRoot -Profiles $Profiles)
        }
        'processPriority' {
            $priority = [string](Get-Nx18Prop -Object $params -Name 'priorityClass' -Default '')
            if ($tweakId -eq 'NX18-006') {
                return (Set-Nx18SessionBackgroundTrim -ProcessName ([string]$Step.processName) -PriorityClass $priority -JournalRoot $JournalRoot -Profiles $Profiles)
            }
            return (Set-Nx18SessionGamePriority -ProcessName ([string]$Step.processName) -PriorityClass $priority -JournalRoot $JournalRoot -Profiles $Profiles)
        }
        'powerPlanSelection' {
            return (Set-Nx18SessionPowerPlan -TargetPlan ([string](Get-Nx18Prop -Object $params -Name 'targetPlan' -Default '')) -JournalRoot $JournalRoot -Profiles $Profiles)
        }
        'registry' {
            $override = Get-Nx18Prop -Object $params -Name 'override' -Default $null
            return (Set-Nx18SessionGraphicOverlay -Overrides @($override) -JournalRoot $JournalRoot -Profiles $Profiles)
        }
        default { throw "step $($Step.stepId): unknown target type '$targetType'" }
    }
}

function Start-NxSession {
    <#
    .SYNOPSIS
        NX18-011: start a monitored game session.
    .DESCRIPTION
        Detection -> profile match -> plan -> approval -> journaled apply ->
        monitor (2 s poll + heartbeat) -> verified-step restore on exit.
        -Plan prints the plan and writes NOTHING (no session record, no journal
        entry, no directory). A real run requires -Approved, a running game and
        an initialized journal. The game is never launched by NEXTRIX.
    .PARAMETER ProcessTable
        Drill hook: a simulated process table. When supplied, detection is a
        single evaluation against it (no polling of the host).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GameExe,
        [Parameter(Mandatory)][string]$ProfileName,
        [switch]$Plan,
        [switch]$Approved,
        [string]$SessionRoot,
        [string]$ProfileRoot,
        [string]$JournalRoot,
        [object]$Topology = $null,
        [AllowNull()][object[]]$ProcessTable,
        [int]$WaitSeconds = 15,
        [int]$PollSeconds = 2,
        [int]$MaxMonitorSeconds = 0,
        [int]$CooldownSeconds = $script:Nx18DefaultCooldownSeconds
    )
    if (-not $SessionRoot) { $SessionRoot = Get-Nx18DefaultSessionRoot }
    if (-not $JournalRoot) { $JournalRoot = Get-Nx18DefaultJournalRoot }
    if (-not $ProfileRoot) { $ProfileRoot = Join-Path $SessionRoot 'profiles' }

    $id = Resolve-Nx18GameIdentity -GameExe $GameExe
    if (-not $id.valid) { throw "invalid -GameExe '$GameExe': $($id.issues -join ' ')" }
    $guard = Test-Nx18ProtectedProcess -ProcessName $id.imageName
    if ($guard.protected) {
        throw "tweak NX18-011: refusing a session for '$($id.imageName)': $($guard.reason)"
    }
    $profileRead = Read-Nx18Profile -ProfileName $ProfileName -ProfileRoot $ProfileRoot
    if (-not $profileRead.valid) { throw "tweak NX18-003: profile '$ProfileName' is not usable: $($profileRead.reason)" }
    $profile = $profileRead.profile

    $sessionPlan = New-Nx18SessionPlan -Profile $profile -GameImageName $id.imageName -Topology $Topology
    $injected = $PSBoundParameters.ContainsKey('ProcessTable')
    if ($injected) { $detection = Find-Nx18GameProcess -GameExe $id.imageName -ProcessTable $ProcessTable }
    else { $detection = Find-Nx18GameProcess -GameExe $id.imageName }

    if (-not $Plan -and -not $injected -and -not $detection.matched -and $WaitSeconds -gt 0) {
        # Attach-wait: the game must already be starting; NEXTRIX never launches it.
        $deadline = (Get-Nx18UtcNowMs) + ([int64]$WaitSeconds * 1000)
        while ((Get-Nx18UtcNowMs) -lt $deadline -and -not $detection.matched) {
            Start-Sleep -Seconds 1
            $detection = Find-Nx18GameProcess -GameExe $id.imageName
        }
    }
    $cooldown = Test-Nx18Cooldown -SessionRoot $SessionRoot -CooldownSeconds $CooldownSeconds

    if ($Plan) {
        Write-Output ("NEXTRIX session plan (read-only) - game '$($id.imageName)', profile '$ProfileName'")
        Write-Output ("Detected running: {0} (launchers mapped: {1})" -f $detection.matched, @($detection.launchers).Count)
        Write-Output ("Cooldown: allowed={0} reason={1}" -f $cooldown.allowed, $cooldown.reason)
        foreach ($s in @($sessionPlan.steps)) {
            Write-Output ("  [{0}] {1} {2} :: {3}" -f $s.preflight, $s.stepId, $s.tweakId, $s.description)
            if ($s.reason) { Write-Output ("       reason: $($s.reason)") }
        }
        foreach ($n in @($sessionPlan.notes)) { Write-Output ("  note: $n") }
        Write-Output 'Plan mode wrote nothing (no session record, no journal entry, no directory).'
        return [pscustomobject]@{
            plan = $true; wrote = $false; sessionId = $null
            gameImageName = $id.imageName; profileName = $ProfileName
            detected = [bool]$detection.matched
            launchers = @($detection.launchers)
            cooldown = $cooldown
            sessionPlan = $sessionPlan
        }
    }

    if (-not $Approved) { throw 'tweak NX18-011: a real session requires -Approved (nothing applies without explicit approval evidence)' }
    if (-not $detection.matched) {
        throw ("tweak NX18-011: game process '$($id.imageName)' is not running; NEXTRIX never launches a game. " +
               "Start it and rerun (attach-wait ${WaitSeconds}s elapsed).")
    }
    if (-not $cooldown.allowed) {
        $hint = ''
        if ($cooldown.reason -eq 'ActiveSession') { $hint = ' Another session record is still non-terminal; run Invoke-NxSessionRecovery (or Stop-NxSession) first.' }
        throw ("tweak NX18-010: session cooldown active ($($cooldown.reason)); " +
               "$($cooldown.remainingSeconds)s remaining. Rapid re-sessions are blocked to avoid anti-cheat false positives (FSOS-X R8).$hint")
    }
    $manifest = Read-NxManifest -Path $JournalRoot
    if (-not $manifest.present) {
        throw "tweak NX18-010: journal is not initialized at '$JournalRoot'; run the NX16 pre-flight first (journal-first invariant)."
    }

    $record = New-Nx18SessionRecord -GameExe $GameExe -GameImageName $id.imageName -ProfileName $ProfileName `
        -ProfileHash $profileRead.profileHash -Plan $sessionPlan -JournalRoot $JournalRoot `
        -CooldownSeconds $CooldownSeconds -Launchers @($detection.launchers)
    $null = Save-Nx18SessionRecord -Record $record -SessionRoot $SessionRoot

    $applyRows = New-Object System.Collections.Generic.List[object]
    $verified = New-Object System.Collections.Generic.List[object]
    $stopApplying = $false
    foreach ($step in @($sessionPlan.steps)) {
        if ($stopApplying) {
            $applyRows.Add([pscustomobject]@{ stepId = $step.stepId; tweakId = $step.tweakId; targetType = $step.targetType; processName = $step.processName; status = 'Skipped-AfterFailure'; verified = $false; journalSeq = $null; detail = 'safe stop: an earlier step failed' })
            continue
        }
        if ($step.preflight -ne 'Ready') {
            $applyRows.Add([pscustomobject]@{ stepId = $step.stepId; tweakId = $step.tweakId; targetType = $step.targetType; processName = $step.processName; status = 'Unavailable'; verified = $false; journalSeq = $null; detail = $step.reason })
            continue
        }
        try {
            $engine = Invoke-Nx18PlanStep -Step $step -JournalRoot $JournalRoot -Profiles @()
            $row = Get-Nx18StepOutcome -Step $step -EngineResult $engine
            $applyRows.Add($row)
            if ($row.verified) {
                $verified.Add([pscustomobject]@{
                    stepId = $row.stepId; tweakId = $row.tweakId; targetType = $row.targetType
                    processName = $row.processName; mechanism = $row.mechanism; journalSeq = $row.journalSeq
                    originalSchemeGuid = $row.originalSchemeGuid; originalSchemeName = $row.originalSchemeName
                    modifiedSchemeGuid = $row.modifiedSchemeGuid; modifiedSchemeName = $row.modifiedSchemeName
                    verifiedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                })
            } elseif ($row.status -eq 'NotNeeded') {
                # The target already held the desired state: nothing to restore,
                # and this is not a failure - keep applying the remaining steps.
            } else {
                $stopApplying = $true
            }
        } catch {
            $applyRows.Add([pscustomobject]@{ stepId = $step.stepId; tweakId = $step.tweakId; targetType = $step.targetType; processName = $step.processName; status = 'Failed'; verified = $false; journalSeq = $null; detail = [string]$_.Exception.Message })
            $stopApplying = $true
        }
    }
    $record.applyResult = $applyRows.ToArray()
    $record.verifiedSteps = $verified.ToArray()
    $null = Set-Nx18SessionState -Record $record -NewState 'applied' -SessionRoot $SessionRoot

    if ($verified.Count -eq 0) {
        # Nothing verified: never enter monitoring with an empty restore set.
        $restore = Invoke-Nx18SessionRestore -Record $record -SessionRoot $SessionRoot -JournalRoot $JournalRoot -CompletionKind 'Normal'
        $report = [pscustomobject]@{
            sessionId = $record.sessionId; state = $record.state; completionKind = $record.completionKind
            plan = $sessionPlan; applied = @($applyRows); verifiedSteps = @(); restore = $restore
            monitored = $false; reason = 'no step verified; the session completed without monitoring'
        }
        Write-Output ("NEXTRIX session {0}: no step verified; nothing to monitor or restore." -f $record.sessionId)
        return $report
    }

    $null = Set-Nx18SessionState -Record $record -NewState 'monitoring' -SessionRoot $SessionRoot
    $monitorArgs = @{ Record = $record; SessionRoot = $SessionRoot; PollSeconds = $PollSeconds; MaxSeconds = $MaxMonitorSeconds }
    if ($injected) { $monitorArgs['ProcessTable'] = $ProcessTable }
    $wait = Wait-Nx18SessionGameExit @monitorArgs
    $restoreSummary = Invoke-Nx18SessionRestore -Record $record -SessionRoot $SessionRoot -JournalRoot $JournalRoot -CompletionKind 'Normal'
    Write-Output ("NEXTRIX session {0} ended ({1}). Verified steps: {2}. Restore: restored={3} diverged={4} failed={5}." -f `
        $record.sessionId, $wait.reason, $verified.Count, $restoreSummary.restoredCount, $restoreSummary.divergedCount, $restoreSummary.failedCount)
    return [pscustomobject]@{
        sessionId = $record.sessionId; state = $record.state; completionKind = $record.completionKind
        plan = $sessionPlan; applied = @($applyRows); verifiedSteps = $verified.ToArray()
        monitor = $wait; restore = $restoreSummary; monitored = $true
    }
}

function Stop-NxSession {
    <#
    .SYNOPSIS
        NX18-011: end a session manually; restores only verified steps.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$SessionRoot,
        [string]$JournalRoot,
        [scriptblock]$RestoreHandler
    )
    if (-not $SessionRoot) { $SessionRoot = Get-Nx18DefaultSessionRoot }
    $read = Read-Nx18SessionRecord -SessionId $SessionId -SessionRoot $SessionRoot
    if (-not $read.found) { throw "tweak NX18-011: session '$SessionId' was not found ($($read.reason))" }
    $record = $read.record
    if (Test-Nx18SessionTerminal -Record $record) {
        return [pscustomobject]@{ sessionId = $SessionId; state = $record.state; alreadyTerminal = $true; completionKind = $record.completionKind; restore = $null; restored = 0; reason = 'session is already terminal; nothing restored' }
    }
    $JournalRoot = Resolve-Nx18JournalRoot -Record $record -Explicit $JournalRoot
    $journal = Read-NxJournal -Path $JournalRoot
    if ($journal.integrityErrors.Count -gt 0) {
        return [pscustomobject]@{ sessionId = $SessionId; state = $record.state; aborted = $true; integrityErrors = @($journal.integrityErrors); restore = $null; restored = 0; reason = 'journal integrity errors - refusing to restore' }
    }
    $restore = Invoke-Nx18SessionRestore -Record $record -SessionRoot $SessionRoot -JournalRoot $JournalRoot -RestoreHandler $RestoreHandler -CompletionKind 'ManualStop'
    return [pscustomobject]@{ sessionId = $SessionId; state = $record.state; alreadyTerminal = $false; completionKind = $record.completionKind; restore = $restore; restored = $restore.restoredCount }
}

function Get-NxSessionStatus {
    <#
    .SYNOPSIS
        NX18-011: status display for one session or every stored session.
    #>
    [CmdletBinding()]
    param([string]$SessionId, [string]$SessionRoot)
    if (-not $SessionRoot) { $SessionRoot = Get-Nx18DefaultSessionRoot }
    if ($SessionId) {
        $read = Read-Nx18SessionRecord -SessionId $SessionId -SessionRoot $SessionRoot
        if (-not $read.found) { return [pscustomobject]@{ found = $false; sessionId = $SessionId; reason = $read.reason } }
        $record = $read.record
        $nowMs = Get-Nx18UtcNowMs
        $hb = [int64](Get-Nx18Prop -Object $record -Name 'heartbeatUnixMs' -Default 0)
        $age = $null
        if ($hb -gt 0) { $age = [int][Math]::Floor(($nowMs - $hb) / 1000) }
        $state = [string](Get-Nx18Prop -Object $record -Name 'state' -Default '')
        return [pscustomobject]@{
            found = $true; sessionId = $SessionId; state = $state
            terminal = (Test-Nx18SessionTerminal -Record $record)
            heartbeatAgeSeconds = $age
            stale = (($state -eq 'monitoring') -and ($null -ne $age) -and ($age -gt 30))
            verifiedStepCount = @((Get-Nx18Prop -Object $record -Name 'verifiedSteps' -Default @())).Count
            completionKind = (Get-Nx18Prop -Object $record -Name 'completionKind' -Default $null)
            gameImageName = (Get-Nx18Prop -Object $record -Name 'gameImageName' -Default $null)
            profileName = (Get-Nx18Prop -Object $record -Name 'profileName' -Default $null)
            record = $record
        }
    }
    $scan = Get-Nx18SessionRecords -SessionRoot $SessionRoot
    return [pscustomobject]@{
        found = $true; sessionRoot = $SessionRoot
        active = @($scan.records | Where-Object { -not (Test-Nx18SessionTerminal -Record $_) })
        terminal = @($scan.records | Where-Object { Test-Nx18SessionTerminal -Record $_ })
        unreadable = @($scan.unreadable)
        total = @($scan.records).Count
    }
}

# ---------------------------------------------------------------------------
# 9. NX18-010 crash / interruption recovery
# ---------------------------------------------------------------------------

function Invoke-NxSessionRecovery {
    <#
    .SYNOPSIS
        NX18-010: replay the restore of outstanding verified steps for
        non-terminal session records (boot-time / manual recovery check).
    .DESCRIPTION
        Read-only until every journal it needs has been integrity-checked: if
        any journal reports integrity errors the whole recovery is refused with
        no record touched. Only steps in a record's verifiedSteps list are
        restored (a step that failed to apply is never restored). Restore is
        delegated to the owning engines, so only-if-ours holds.
        -RestoreHandler is a drill hook for self-tests; production uses the
        engine dispatch in Restore-Nx18VerifiedStep.
    #>
    [CmdletBinding()]
    param(
        [string]$SessionRoot,
        [string]$JournalRoot,
        [scriptblock]$RestoreHandler,
        [switch]$WhatIf
    )
    if (-not $SessionRoot) { $SessionRoot = Get-Nx18DefaultSessionRoot }
    $scan = Get-Nx18SessionRecords -SessionRoot $SessionRoot
    $targets = @($scan.records | Where-Object { -not (Test-Nx18SessionTerminal -Record $_) })
    if ($targets.Count -eq 0) {
        return [pscustomobject]@{ aborted = $false; recovered = 0; refused = 0; records = @(); unreadable = @($scan.unreadable); integrityErrors = @(); reason = 'no non-terminal session records' }
    }

    # Phase 1: verify every journal before touching a record.
    $journalChecks = @{}
    $integrity = New-Object System.Collections.Generic.List[string]
    $unavailable = @{}
    foreach ($r in $targets) {
        $jr = Resolve-Nx18JournalRoot -Record $r -Explicit $JournalRoot
        $key = $jr.ToLowerInvariant()
        if (-not $journalChecks.ContainsKey($key)) {
            $manifest = Read-NxManifest -Path $jr
            if (-not $manifest.present) {
                $journalChecks[$key] = [pscustomobject]@{ present = $false; errors = @() }
                $unavailable[[string]$r.sessionId] = "journal not initialized at '$jr'"
            } else {
                $journal = Read-NxJournal -Path $jr
                $journalChecks[$key] = [pscustomobject]@{ present = $true; errors = @($journal.integrityErrors) }
                foreach ($e in @($journal.integrityErrors)) { $integrity.Add("$jr : $e") }
            }
        } elseif (-not $journalChecks[$key].present) {
            $unavailable[[string]$r.sessionId] = "journal not initialized at '$jr'"
        }
    }
    if ($integrity.Count -gt 0) {
        return [pscustomobject]@{
            aborted = $true; recovered = 0; refused = $targets.Count; records = @()
            unreadable = @($scan.unreadable)
            integrityErrors = $integrity.ToArray()
            reason = 'journal integrity errors - recovery refused without touching any session record (no partial restore)'
        }
    }

    # Phase 2: restore, per record, verified steps only.
    $outcomes = New-Object System.Collections.Generic.List[object]
    $recovered = 0
    $refused = 0
    foreach ($r in $targets) {
        $sid = [string]$r.sessionId
        $jr = Resolve-Nx18JournalRoot -Record $r -Explicit $JournalRoot
        if ($unavailable.ContainsKey($sid)) {
            $refused++
            $outcomes.Add([pscustomobject]@{ sessionId = $sid; outcome = 'Refused'; reason = $unavailable[$sid]; restored = 0; failed = 0 })
            continue
        }
        if ($WhatIf) {
            $outcomes.Add([pscustomobject]@{ sessionId = $sid; outcome = 'WouldRecover'; reason = $null; verifiedSteps = @((Get-Nx18Prop -Object $r -Name 'verifiedSteps' -Default @())).Count; restored = 0; failed = 0 })
            continue
        }
        $steps = @((Get-Nx18Prop -Object $r -Name 'verifiedSteps' -Default @()) | Where-Object { $null -ne $_ })
        $restoreSummary = $null
        if ($steps.Count -gt 0) {
            $restoreSummary = Invoke-Nx18SessionRestore -Record $r -SessionRoot $SessionRoot -JournalRoot $jr -RestoreHandler $RestoreHandler -CompletionKind 'Recovered'
        } else {
            # A planned session with no verified step: nothing to restore, close it honestly.
            $null = Set-Nx18SessionState -Record $r -NewState 'restoring' -SessionRoot $SessionRoot -Reason 'recovery: no verified steps'
            $null = Set-Nx18SessionState -Record $r -NewState 'completed' -SessionRoot $SessionRoot -CompletionKind 'Recovered'
        }
        Set-Nx18Prop -Object $r -Name 'recoveredAtUtc' -Value ((Get-Date).ToUniversalTime().ToString('o'))
        $null = Save-Nx18SessionRecord -Record $r -SessionRoot $SessionRoot
        if ([string]$r.state -eq 'completed') { $recovered++ } else { $refused++ }
        $outcomes.Add([pscustomobject]@{
            sessionId = $sid
            outcome = [string]$r.state
            reason = $(if ($restoreSummary) { $restoreSummary.report } else { 'no outstanding verified steps' })
            restored = $(if ($restoreSummary) { $restoreSummary.restoredCount } else { 0 })
            failed = $(if ($restoreSummary) { $restoreSummary.failedCount } else { 0 })
        })
    }
    return [pscustomobject]@{
        aborted = $false
        recovered = $recovered
        refused = $refused
        records = $outcomes.ToArray()
        unreadable = @($scan.unreadable)
        integrityErrors = @()
        reason = 'verified-step recovery replay complete'
    }
}

# ---------------------------------------------------------------------------
# 10. Category rollback engine for the main journal (delegation target).
#     The shared Invoke-NxRollback resolves 'Invoke-Nx18Rollback' for NX18-*
#     entries. Session-scoped process steps are restored through NX19; the
#     registry overlay through the main engine; a session's power switch is
#     journaled under NX09-001 and is handled by the NX09 engine.
# ---------------------------------------------------------------------------
function Invoke-Nx18Rollback {
    <#
    .SYNOPSIS
        Restores journaled NX18 entries (session leftovers after a crash).
    .DESCRIPTION
        Only-if-ours is enforced by the delegated engines. A process that has
        already ended needs no restore and is reported irreversible-by-design.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JournalRoot, [string]$TweakId)
    $journal = Read-NxJournal -Path $JournalRoot
    if ($journal.integrityErrors.Count -gt 0) {
        return [pscustomobject]@{ aborted = $true; integrityErrors = @($journal.integrityErrors); restored = @(); diverged = @(); failed = @(); irreversible = @() }
    }
    $candidates = @($journal.entries | Where-Object { $_.operation -eq 'apply' -and [string]$_.tweakId -like 'NX18-*' })
    if ($TweakId) { $candidates = @($candidates | Where-Object { $_.tweakId -eq $TweakId }) }
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{ aborted = $false; restored = @(); diverged = @(); failed = @(); irreversible = @(); integrityErrors = @() }
    }
    $restored = New-Object System.Collections.Generic.List[object]
    $diverged = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]
    $irreversible = New-Object System.Collections.Generic.List[object]
    $tweakIds = @($candidates | ForEach-Object { [string]$_.tweakId } | Sort-Object -Unique)
    foreach ($tid in $tweakIds) {
        try {
            if (@('NX18-004','NX18-006','NX18-009') -contains $tid) {
                $r = Invoke-Nx19Rollback -JournalRoot $JournalRoot -TweakId $tid
                foreach ($x in @($r.restored)) { $restored.Add($x) }
                foreach ($x in @($r.diverged)) { $diverged.Add($x) }
                foreach ($x in @($r.failed)) { $failed.Add($x) }
                foreach ($x in @($r.irreversible)) { $irreversible.Add($x) }
            } elseif ($tid -eq 'NX18-008') {
                $r = Invoke-NxRollback -JournalRoot $JournalRoot -TweakId 'NX18-008'
                foreach ($x in @($r.restored)) { $restored.Add($x) }
                foreach ($x in @($r.diverged)) { $diverged.Add($x) }
                foreach ($x in @($r.failed)) { $failed.Add($x) }
            } else {
                $failed.Add([pscustomobject]@{ tweakId = $tid; reason = "no NX18 rollback mapping for '$tid'" })
            }
        } catch {
            $failed.Add([pscustomobject]@{ tweakId = $tid; reason = [string]$_.Exception.Message })
        }
    }
    return [pscustomobject]@{ aborted = $false; restored = $restored.ToArray(); diverged = $diverged.ToArray(); failed = $failed.ToArray(); irreversible = $irreversible.ToArray(); integrityErrors = @() }
}

function Get-Nx18Capability {
    <#
    .SYNOPSIS
        Read-only capability probe used by the NX18 registry entries' apply
        action. NX18 is a runtime subsystem: the playbook installs/probes the
        capability; a session is started only by the user via Start-NxSession.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet(
        'NX18-001','NX18-002','NX18-003','NX18-004','NX18-005','NX18-006',
        'NX18-007','NX18-008','NX18-009','NX18-010','NX18-011','NX18-012')][string]$Capability)
    $map = @{
        'NX18-001' = 'Detect running game processes by image name (detection only; never launches a game).'
        'NX18-002' = 'Map launcher ancestors from the process parent chain (launchers are protected, never managed).'
        'NX18-003' = 'Read and validate user-authored session profile JSON under <SessionRoot>\profiles.'
        'NX18-004' = 'Apply NX19-derived CPU Sets to the game process (topology-derived IDs; journaled; session-scoped).'
        'NX18-005' = 'Switch the active power plan for the session through the NX09 engine (journaled; restore-on-exit).'
        'NX18-006' = 'Priority-trim or CPU-set-steer explicitly allowlisted background apps (no termination, no suspension).'
        'NX18-007' = 'Service suspension is Defined only: this build never touches a service (journaled service engine not shipped).'
        'NX18-008' = 'Apply a validated temporary per-game registry overlay through the journaled NxApply pipeline.'
        'NX18-009' = 'Set the game process priority class through the NX19 documented-API path (Idle..AboveNormal only).'
        'NX18-010' = 'Recover interrupted sessions from their records, restoring verified steps only; refuses on journal integrity errors.'
        'NX18-011' = 'Manual session control: Start-NxSession / Stop-NxSession / Get-NxSessionStatus.'
        'NX18-012' = 'Hard-coded protected-process guard (anti-cheat, security, recording, audio, peripherals, launchers).'
    }
    $implemented = ($Capability -ne 'NX18-007')
    return [pscustomobject]@{
        capability = $Capability
        readOnly = $true
        implemented = $implemented
        summary = $map[$Capability]
        note = $(if ($implemented) { 'Runtime capability present. Sessions are started only by the user through Start-NxSession; the playbook never starts one.' } else { 'Defined only. No Windows mutation is shipped for this capability in this build.' })
    }
}
