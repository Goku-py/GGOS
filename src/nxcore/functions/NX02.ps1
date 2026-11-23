#Requires -Version 5.1
<#
    NX02.ps1 - NEXTRIX Gaming & Esports category functions (workstream W1-D).

    Companion to registry/NX02.json (the single source of truth for entries
    NX02-001..NX02-012).

    Module contents and design contract:

    * NX02-001..007 are DECLARATIVE registry entries. Their mutation path runs
      entirely through the shared engine (src/nxcore/NxApply.ps1), which
      implements the mandatory pipeline:
      capture (Capture-NxRegistryValue) -> journal (Add-NxJournalEntry)
      -> apply (Set-NxRegistryValue) -> verify (Test-NxConfigurationState)
      -> journal result (pipeline steps 2-10). This file therefore contains
      NO mutation code.

    * NX02-008  Get-NxXboxServicesDependencyReport - READ-ONLY dependency
      report. The actual Xbox Gaming Services management change (service
      start-type changes) stays Defined until the NX11 Background & Services
      engine lands (docs/TODO.md 2.5); nothing in this module changes any
      service. The report exists so that every future change decision starts
      from an explicit, machine-readable dependency list (ReviOS revert.yml
      lesson: svchost splitting broke XboxGipSvc, r2).

    * NX02-009/010/011 are COMPOSITION entries (kind: composition, status
      Defined). Their functions (Invoke-NxPerGameDriverGraphics,
      Invoke-NxGameLaunchConfiguration, Invoke-NxGameBackgroundHandling) are
      deliberately NOT implemented here: they compose NX04-009..023,
      NX19-004/005 and NX18-006 mechanisms as those mechanisms are implemented.
      NX02 itself writes no per-game registry values (no duplicate targets).

    * NX02-012  Get-NxLauncherDetectionReport - READ-ONLY launcher detection
      (processes / services / community-known install-marker registry keys /
      per-user appx packages) feeding NX18 session detection.

    Both implemented functions are strictly read-only, so they are inherently
    idempotent: repeated invocation never mutates the host and returns the
    same detection data (modulo the generation timestamp). Per the directive
    S16 testing boundary, read-only queries are the only host interaction
    permitted on development machines; these functions comply.

    Uncertainty discipline (SynToolkit pattern, r4): a read that fails or is
    inconclusive is reported as an Uncertainty entry - never a guessed value.

    Rejected patterns intentionally absent from this module (policy):
      - No IFEO 'Debugger' hijacks (XOS systray.exe pattern, r1 - REJECT list).
      - No global FSO / FSE value writes (per-game FSO belongs to NX04-005;
        Vain's forced FSE values are a rejected pattern, r3).
      - No hardcoded per-user service suffixes (BcastDVRUserService_<suffix>
        is enumerated by wildcard, never hardcoded, r4).
      - No hardcoded game-EXE tables (Vain counter-example, r3); games are
        user-selected at apply time.
#>

# ----------------------------------------------------------------------------
# NX02-008 - Xbox Gaming Services dependency report (read-only).
# ----------------------------------------------------------------------------
function Get-NxXboxServicesDependencyReport {
    [CmdletBinding()]
    param()

    $uncertainty = New-Object System.Collections.Generic.List[string]

    # 1. Machine-level Xbox-related services (read-only enumeration).
    $services = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('XboxGipSvc', 'XboxNetApiSvc', 'GamingServices', 'GamingServicesNet')) {
        $svc = $null
        try   { $svc = Get-Service -Name $name -ErrorAction SilentlyContinue }
        catch { $uncertainty.Add("service enumeration failed for '${name}': $($_.Exception.Message)") }
        if ($null -eq $svc) {
            $services.Add([pscustomobject]@{
                name = $name; present = $false; status = 'NotDetected'; startType = $null
            })
        }
        else {
            $services.Add([pscustomobject]@{
                name = $name; present = $true; status = ([string]$svc.Status); startType = ([string]$svc.StartType)
            })
        }
    }

    # 2. Per-user Game Bar capture/broadcast service family. The per-user
    #    suffix varies per profile and is NEVER hardcoded (rejected pattern,
    #    r4): enumerate by wildcard.
    $bcastInstances = @()
    try {
        $bcastInstances = @((Get-Service -Name 'BcastDVRUserService_*' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name } | Sort-Object))
    }
    catch {
        $uncertainty.Add("BcastDVRUserService_* enumeration failed: $($_.Exception.Message)")
    }
    $broadcastFamily = [pscustomobject]@{
        pattern    = 'BcastDVRUserService_*'
        count      = $bcastInstances.Count
        instances  = $bcastInstances
        note       = 'Per-user Game Bar capture/broadcast service family; present only for profiles that have initialized Game Bar capture.'
    }

    # 3. Machine-side Gaming Services install marker (read-only).
    $gamingServicesKeyPresent = $false
    try   { $gamingServicesKeyPresent = Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\GamingServices' }
    catch { $uncertainty.Add("GamingServices key probe failed: $($_.Exception.Message)") }
    if (-not $gamingServicesKeyPresent) {
        $uncertainty.Add('HKLM:\SOFTWARE\Microsoft\GamingServices not present (Gaming Services store app not installed, or not initialized on this machine).')
    }

    # 4. Per-user appx packages (current user only; -AllUsers would require
    #    elevation - stated as a limitation, not silently ignored).
    $packages = New-Object System.Collections.Generic.List[object]
    foreach ($pkg in @('Microsoft.GamingServices', 'Microsoft.GamingApp', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxApp')) {
        $found = $null
        try   { $found = Get-AppxPackage -Name $pkg -ErrorAction SilentlyContinue | Select-Object -First 1 }
        catch { $uncertainty.Add("appx enumeration failed for '${pkg}': $($_.Exception.Message)") }
        $packages.Add([pscustomobject]@{
            name    = $pkg
            present = ($null -ne $found)
            version = $(if ($found) { [string]$found.Version } else { $null })
        })
    }

    # 5. Running Game Bar related processes (read-only sample).
    $runningProcesses = @()
    try {
        $runningProcesses = @((Get-Process -Name 'GameBar', 'GameBarPresenceWriter', 'bcastdvr' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name } | Sort-Object -Unique))
    }
    catch {
        $uncertainty.Add("Game Bar process sampling failed: $($_.Exception.Message)")
    }

    # 6. Informational consumer map: what breaks if these services/apps are
    #    removed or disabled. This is the core deliverable of the report: it
    #    must be read BEFORE any change decision is made.
    $dependents = @(
        [pscustomobject]@{
            consumer        = 'Xbox Game Bar capture and broadcast'
            dependsOn       = 'BcastDVRUserService_* (per-user family) plus the per-user GameDVR values owned by NX02-003/NX02-004/NX02-007'
            impactIfRemoved = 'Win+Alt+R recording and broadcasting stop working for profiles that use Game Bar capture'
        },
        [pscustomobject]@{
            consumer        = 'Game Pass install and play'
            dependsOn       = 'GamingServices + GamingServicesNet services, the Microsoft.GamingServices store app and the Xbox app (Microsoft.GamingApp)'
            impactIfRemoved = 'Game Pass titles can no longer be installed, updated or launched through the Xbox app'
        },
        [pscustomobject]@{
            consumer        = 'Xbox sign-in on Windows'
            dependsOn       = 'Microsoft.XboxIdentityProvider package and the Xbox app'
            impactIfRemoved = 'Xbox identity flows fail for games and apps that authenticate through the Xbox identity provider'
        },
        [pscustomobject]@{
            consumer        = 'Xbox accessory / game-input device handling'
            dependsOn       = 'XboxGipSvc (Xbox game-input protocol service)'
            impactIfRemoved = 'Xbox accessory management functionality that routes through this service is lost (ReviOS ledger: XboxGipSvc fallout, r2)'
        },
        [pscustomobject]@{
            consumer        = 'Xbox Live networking'
            dependsOn       = 'XboxNetApiSvc (Xbox Live Networking Service)'
            impactIfRemoved = 'Xbox Live multiplayer/relay flows that use the networking service degrade or fail'
        }
    )

    return [pscustomobject]@{
        tweakId                 = 'NX02-008'
        readOnly                = $true
        generatedUtc            = (Get-Date).ToUniversalTime().ToString('o')
        machineServices         = $services
        broadcastUserServiceFamily = $broadcastFamily
        gamingServicesKeyPresent   = $gamingServicesKeyPresent
        packages                = $packages
        runningProcesses        = $runningProcesses
        dependents              = $dependents
        crossCategory           = @(
            'CONFLICT declared against NX12-005 (Xbox app removal, Wave 3): Game Pass users must not remove the Xbox app; removal and Xbox service management must be resolved together, never independently.',
            'The Xbox Gaming Services management change (service start-type changes) remains Defined and ships with the NX11 Background & Services engine (docs/TODO.md 2.5). This report is the mandatory pre-change artifact for that future entry.'
        )
        uncertainty             = @($uncertainty)
    }
}

# ----------------------------------------------------------------------------
# NX02-012 - Game launcher detection report (read-only).
# ----------------------------------------------------------------------------
function Get-NxLauncherDetectionReport {
    [CmdletBinding()]
    param()

    # Descriptor table: community-known process names, service names and
    # install-marker registry keys per launcher. Provenance is recorded per
    # marker: 'well-known' (long-established install marker) or
    # 'community-reported' (widely used but not vendor-documented). A wrong
    # marker can only cause a NotDetected result - process and service
    # checks carry the verdict, and every unreadable read is an Uncertainty.
    # This table is DETECTION data only; no mutation ever keys off it
    # directly (games are user-selected at apply time, NX02-009..011).
    $descriptorTable = @(
        [pscustomobject]@{
            name = 'Steam'
            processes = @('steam', 'steamwebhelper')
            services  = @('Steam Client Service')
            markers   = @(
                @{ path = 'HKCU:\Software\Valve\Steam';                  value = 'SteamPath';   provenance = 'well-known' },
                @{ path = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam';       value = 'InstallPath'; provenance = 'well-known' }
            )
        }
        [pscustomobject]@{
            name = 'Epic Games Launcher'
            processes = @('EpicGamesLauncher')
            services  = @()
            markers   = @(
                @{ path = 'HKCU:\Software\Epic Games\EpicGamesLauncher'; value = 'AppPath';     provenance = 'community-reported' }
            )
        }
        [pscustomobject]@{
            name = 'Xbox app / Gaming Services (Game Pass)'
            processes = @()
            services  = @('GamingServices', 'GamingServicesNet')
            markers   = @()
        }
        [pscustomobject]@{
            name = 'EA app'
            processes = @('EADesktop', 'EALauncher')
            services  = @('EABackgroundService')
            markers   = @()
        }
        [pscustomobject]@{
            name = 'Battle.net'
            processes = @('Battle.net')
            services  = @()
            markers   = @(
                @{ path = 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment'; value = 'InstallPath'; provenance = 'well-known' }
            )
        }
        [pscustomobject]@{
            name = 'GOG Galaxy'
            processes = @('GalaxyClient')
            services  = @()
            markers   = @(
                @{ path = 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\GalaxyClient'; value = 'clientPath'; provenance = 'community-reported' }
            )
        }
        [pscustomobject]@{
            name = 'Ubisoft Connect'
            processes = @('UbisoftConnect', 'upc')
            services  = @('Ubisoft Game Launcher')
            markers   = @(
                @{ path = 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher'; value = 'InstallDir'; provenance = 'well-known' }
            )
        }
        [pscustomobject]@{
            name = 'Riot Client'
            processes = @('RiotClientServices', 'RiotClientUx')
            services  = @()
            markers   = @()
        }
    )

    $launchers = New-Object System.Collections.Generic.List[object]
    $uncertainty = New-Object System.Collections.Generic.List[string]

    foreach ($l in $descriptorTable) {
        $entryUncertainty = @()

        # Process check (running now).
        $processHit = $false
        $processNamesFound = @()
        if (@($l.processes).Count -gt 0) {
            try {
                $found = @(Get-Process -Name @($l.processes) -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.Name } | Sort-Object -Unique)
                $processNamesFound = $found
                $processHit        = ($found.Count -gt 0)
            }
            catch {
                $processHit = $false
                $entryUncertainty += "process enumeration failed: $($_.Exception.Message)"
            }
        }

        # Service check (installed, any state).
        $serviceHit = $false
        $serviceState = 'NotChecked'
        if (@($l.services).Count -gt 0) {
            $serviceState = 'NotDetected'
            foreach ($s in @($l.services)) {
                $svc = $null
                try   { $svc = Get-Service -Name $s -ErrorAction SilentlyContinue }
                catch { $entryUncertainty += "service enumeration failed for '${s}': $($_.Exception.Message)" }
                if ($null -ne $svc) { $serviceHit = $true; $serviceState = ([string]$svc.Status); break }
            }
        }

        # Registry install-marker check (read-only).
        $markerResults = @()
        foreach ($m in @($l.markers)) {
            $state = 'NotDetected'
            if (Test-Path -Path $m.path) {
                $raw = $null
                try   { $raw = (Get-ItemProperty -Path $m.path -Name $m.value -ErrorAction SilentlyContinue).($m.value) }
                catch { $entryUncertainty += "marker read failed at $($m.path): $($_.Exception.Message)" }
                if ($null -ne $raw) { $state = 'Detected' }
                else                { $state = 'KeyPresentValueMissing' }
            }
            $markerResults += [pscustomobject]@{
                path = $m.path; value = $m.value; state = $state; provenance = $m.provenance
            }
        }

        # Appx check for the Xbox app family (current user only).
        $appxPresent = $null
        if ($l.name -eq 'Xbox app / Gaming Services (Game Pass)') {
            $gamingApp = $null
            try   { $gamingApp = Get-AppxPackage -Name 'Microsoft.GamingApp' -ErrorAction SilentlyContinue | Select-Object -First 1 }
            catch { $entryUncertainty += "appx enumeration failed: $($_.Exception.Message)" }
            $appxPresent = ($null -ne $gamingApp)
        }

        # Overall verdict: any positive signal means Detected; any failed
        # read means the verdict carries an Uncertainty mark (never guessed).
        $signalDetected = ($processHit -or $serviceHit -or $appxPresent -or
            (@($markerResults | Where-Object { $_.state -eq 'Detected' }).Count -gt 0))
        $verdict = 'NotDetected'
        if ($signalDetected -and $entryUncertainty.Count -eq 0) { $verdict = 'Detected' }
        elseif ($signalDetected)                                 { $verdict = 'DetectedWithUncertainty' }
        elseif ($entryUncertainty.Count -gt 0)                   { $verdict = 'Uncertain' }

        foreach ($u in $entryUncertainty) { $uncertainty.Add("$($l.name): $u") }

        $launchers.Add([pscustomobject]@{
            name            = $l.name
            verdict         = $verdict
            processRunning  = $processHit
            processesFound  = $processNamesFound
            serviceState    = $serviceState
            appxPackagePresent = $appxPresent
            registryMarkers = @($markerResults)
            uncertainty     = @($entryUncertainty)
        })
    }

    $detected = @(($launchers | Where-Object { $_.verdict -like 'Detected*' } | ForEach-Object { $_.name }))

    return [pscustomobject]@{
        tweakId      = 'NX02-012'
        readOnly     = $true
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        launchers    = $launchers.ToArray()
        summary      = [pscustomobject]@{
            detectedLaunchers = $detected
            detectionMethods  = 'running processes, registered services, community-known registry install markers (provenance-tagged), per-user appx packages'
        }
        consumers    = @(
            'Feeds NX18 session detection: launcher-chain waits (FSOS-X pattern, r1) and the NX18-012 protected-process guard (launchers are always protected).',
            'Detection data only - this report never mutates anything; games/launchers are user-selected at apply time (no hardcoded game tables, Vain counter-example r3).'
        )
        uncertainty  = @($uncertainty)
    }
}
