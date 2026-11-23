#Requires -Version 5.1
<#
    NX01.ps1 - NEXTRIX Windows Foundation category functions (NX01-008, NX01-009 read-only
    helper, NX01-015, NX01-016).

    Dependencies: dot-source AFTER the core modules (Import-NxCore order):
      NxJournal.ps1  -> Capture-NxRegistryValue, Add-NxJournalEntry
      NxBuild.ps1    -> capability probes (not used here directly)
      NxVerify.ps1   -> Test-NxConfigurationState
      NxApply.ps1    -> Set-NxRegistryValue
      NxRollback.ps1 -> Restore-NxRegistryOriginal (best-effort restore on failed verify)
    This file defines functions only. Loading it performs no registry/CIM/service reads
    or writes and no network access.

    Pipeline contract (NxApply.ps1, directive Section 8 - no exceptions):
      Capture-NxRegistryValue -> Add-NxJournalEntry -> mutate -> Test-NxConfigurationState
      -> Add-NxJournalEntry (result). Journal-first: no mutation without a preceding
      journal entry. Idempotent: an already-correct target journals a 'skip'
      (AlreadyApplied) and is never rewritten. Verification failures perform a
      best-effort restore of the exact recorded original, then journal 'failed'.

    Safety boundaries:
      - Services are NEVER touched (never-touch list in registry/schema.json). The
        search inventory reads WSearch status read-only; service configuration is
        NX11-008's territory.
      - No ControlSet00x paths, no UCPD-protected per-user association surfaces
        (NX01-016 uses the documented DISM XML path instead).
      - PowerShell 5.1 only: DISM cmdlets are known to break from PS7/MSIX contexts
        (COMPATIBILITY_RESEARCH.md section 2).
#>

function Invoke-NxJournaledRegistryWrite {
    <#
        Internal helper: the exact 10-step registry pipeline with idempotent skip.
        Every mutating NX01 function routes registry writes through here so the
        journal-first order exists in exactly one place.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$TweakId,
        [string]$TweakVersion = '1',
        [Parameter(Mandatory)][string]$Approval,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('String','ExpandString','Binary','DWord','MultiString','QWord')][string]$Kind,
        [Parameter(Mandatory)]$Value,
        [string[]]$Profiles = @()
    )
    $target = "$Path :: $Name"

    # Steps 2-6: read current state (read-only capture; journaled unchanged below).
    $orig = Capture-NxRegistryValue -Path $Path -Name $Name
    $modified = [pscustomobject]@{ targetType = 'registry'; path = $Path; name = $Name; kind = $Kind; value = $Value }

    if (-not $PSCmdlet.ShouldProcess($target, "Set $Kind to the intended value")) {
        return [pscustomobject]@{ target = $target; changed = $false; verified = $false; journalSeq = $null; reason = 'WhatIf/Confirm: no mutation, no journal write' }
    }

    # Idempotency: desired state already present -> record a skip, never rewrite.
    if ($orig.existed -and ([string]$orig.kind -eq $Kind)) {
        $existing = ConvertTo-Json -InputObject $orig.value -Depth 6 -Compress
        $desired  = ConvertTo-Json -InputObject $Value -Depth 6 -Compress
        if ($existing -eq $desired) {
            $skipJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $orig -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
            return [pscustomobject]@{ target = $target; changed = $false; verified = $true; journalSeq = $skipJournal.seq; reason = 'already in desired state' }
        }
    }

    # Step 7: journal BEFORE any mutation (journal-first invariant).
    $applyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $orig -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        # Step 8: apply.
        Set-NxRegistryValue -Path $Path -Name $Name -Kind $Kind -Value $Value
        # Step 9: verify configuration effect (never a performance claim).
        $check = Test-NxConfigurationState -Path $Path -Name $Name -Kind $Kind -ExpectedValue $Value
        if ($check.verified) {
            # Step 10: journal the verified result.
            $verifyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $orig -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles $Profiles
            return [pscustomobject]@{ target = $target; changed = $true; verified = $true; journalSeq = $applyJournal.seq; verifySeq = $verifyJournal.seq; reason = $check.reason }
        }
        # Safe stop: best-effort restore of the exact original, then journal the failure.
        try { Restore-NxRegistryOriginal -Entry ([pscustomobject]@{ original = $orig }) | Out-Null } catch { }
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed-RestoredOriginal' -Verification 'NotRun' -ErrorInfo $check.reason -Profiles $Profiles
        return [pscustomobject]@{ target = $target; changed = $true; verified = $false; journalSeq = $applyJournal.seq; reason = $check.reason }
    } catch {
        $err = [string]$_.Exception.Message
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $orig -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles
        return [pscustomobject]@{ target = $target; changed = $false; verified = $false; journalSeq = $applyJournal.seq; reason = "mutation failed: $err" }
    }
}

function Set-NxBackgroundAppsGlobal {
    <#
    .SYNOPSIS
        NX01-008: global Windows-app background-execution toggle (journaled, idempotent).
    .DESCRIPTION
        Layer 1 (always): per-user global toggle GlobalUserDisabled (0/1) under
        HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications
        (community-known value family, E0).
        Layer 2 (opt-in -IncludeDevicePolicy): documented AppPrivacy policy
        LetAppsRunInBackground = 2 (Force deny) / 0 (User in control) under
        HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy
        (AppPrivacy.admx; 0=user in control, 1=force allow, 2=force deny).
        Documented breakage record surfaced as warnings (ReviOS revert.yml: Game Bar
        KGL; Microsoft CSP: communication-app tiles/notifications and mail sync).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [ValidateSet('Disable','Enable')][string]$Mode = 'Disable',
        [switch]$IncludeDevicePolicy,
        [string]$TweakId = 'NX01-008',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @()
    )
    $layers = New-Object System.Collections.Generic.List[object]

    $userPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
    $userValue = if ($Mode -eq 'Disable') { 1 } else { 0 }
    $layers.Add((Invoke-NxJournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $userPath -Name 'GlobalUserDisabled' -Kind DWord -Value $userValue -Profiles $Profiles))

    if ($IncludeDevicePolicy) {
        $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
        $policyValue = if ($Mode -eq 'Disable') { 2 } else { 0 }
        $layers.Add((Invoke-NxJournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $policyPath -Name 'LetAppsRunInBackground' -Kind DWord -Value $policyValue -Profiles $Profiles))
    }

    $allVerified = (@($layers | Where-Object { -not $_.verified }).Count -eq 0)
    return [pscustomobject]@{
        tweakId      = $TweakId
        mode         = $Mode
        devicePolicy = $IncludeDevicePolicy.IsPresent
        layers       = $layers.ToArray()
        allVerified  = $allVerified
        warnings     = @(
            'ReviOS revert.yml records that a global background-app disable breaks Xbox Game Bar KGL updates (r2) - Streamer profile excluded, confirmation required.',
            'Microsoft CSP warning: background denial can stop tile/notification updates and background mail/voicemail sync for communication apps.',
            'Open apps must be restarted to pick up the policy (session-level restart requirement).'
        )
    }
}

function Get-NxBackgroundAppsState {
    <#
    .SYNOPSIS
        NX01-008 read-only state report (no journal writes, no mutation).
    #>
    [CmdletBinding()]
    param()
    $userPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
    return [pscustomobject]@{
        readOnly      = $true
        userToggle    = Capture-NxRegistryValue -Path $userPath -Name 'GlobalUserDisabled'
        devicePolicy  = Capture-NxRegistryValue -Path $policyPath -Name 'LetAppsRunInBackground'
        note          = 'Read-only; per-app background permissions are NX11-002 territory.'
    }
}

function Get-NxSearchCrawlScopeInventory {
    <#
    .SYNOPSIS
        NX01-009 read-only inventory of Windows Search indexing scope surfaces.
    .DESCRIPTION
        Read-only helper only. Reports: WSearch service status (status read-only;
        service CONFIGURATION is NX11-008's territory and is never touched here),
        documented Search.admx policy values, and the community-known
        CrawlScopeManager rule mirror (captured generically - the mirror is NOT a
        documented write path and is never written by NEXTRIX).
        Never journals, never mutates.
    #>
    [CmdletBinding()]
    param()
    $out = [ordered]@{
        readOnly           = $true
        service            = $null
        policyValues       = @()
        scopeRuleMirrorPath = 'HKLM:\SOFTWARE\Microsoft\Windows Search\CrawlScopeManager\Windows\SystemIndex\WorkingSet\Rules'
        scopeRuleMirrorReadable = $false
        rules              = @()
        uncertainty        = @()
    }

    try {
        $svc = Get-Service -Name 'WSearch' -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            $out.service = [pscustomobject]@{ name = 'WSearch'; status = [string]$svc.Status; startType = [string]$svc.StartType; note = 'status is read-only here; service configuration is NX11-008 territory' }
        } else {
            $out.uncertainty += 'WSearch service not found (read-only check)'
        }
    } catch {
        $out.uncertainty += "service status read failed: $($_.Exception.Message)"
    }

    # Documented narrow Search.admx policy values (names verified in local Search.admx, 2026-11-23).
    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
    foreach ($n in @('DisableRemovableDriveIndexing','AllowFindMyFiles','PreventIndexingLowDiskSpaceMB','AllowIndexingEncryptedStoresOrItems')) {
        $cap = Capture-NxRegistryValue -Path $policyPath -Name $n
        $out.policyValues += [pscustomobject]@{ name = $n; existed = $cap.existed; kind = $cap.kind; value = $cap.value }
    }

    # Community-known rule mirror - read-only, values captured generically (names not documented).
    if (Test-Path -LiteralPath $out.scopeRuleMirrorPath) {
        try {
            $out.scopeRuleMirrorReadable = $true
            $ruleKeys = @(Get-ChildItem -Path $out.scopeRuleMirrorPath -ErrorAction SilentlyContinue)
            $rules = New-Object System.Collections.Generic.List[object]
            foreach ($rk in $ruleKeys) {
                $props = @{}
                try {
                    $item = Get-ItemProperty -Path $rk.PSPath -ErrorAction Stop
                    foreach ($p in $item.PSObject.Properties) {
                        if ($p.Name -notlike 'PS*') { $props[$p.Name] = $p.Value }
                    }
                } catch {
                    $out.uncertainty += "rule '$($rk.PSChildName)' unreadable: $($_.Exception.Message)"
                }
                $rules.Add([pscustomobject]@{ ruleKey = $rk.PSChildName; values = $props })
            }
            $out.rules = $rules.ToArray()
        } catch {
            $out.uncertainty += "scope rule mirror read failed: $($_.Exception.Message)"
        }
    } else {
        $out.uncertainty += 'scope rule mirror key absent on this machine (read-only check)'
    }

    return [pscustomobject]$out
}

function Get-NxOptionalFeatureInventory {
    <#
    .SYNOPSIS
        NX01-015 read-only optional-feature inventory (DISM cmdlets, Windows PowerShell 5.1).
    .DESCRIPTION
        Read-only. Requires an elevated session for Get-WindowsOptionalFeature -Online.
        Error information is captured, never fabricated (uncertainty is explicit).
    #>
    [CmdletBinding()]
    param()
    $out = [ordered]@{ readOnly = $true; readSucceeded = $false; features = @(); error = $null }
    try {
        Import-Module Dism -ErrorAction Stop
        $features = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Select-Object -Property FeatureName, State)
        $out.features = $features
        $out.readSucceeded = $true
    } catch {
        $out.error = [string]$_.Exception.Message
    }
    return [pscustomobject]$out
}

function Set-NxOptionalFeatureState {
    <#
    .SYNOPSIS
        NX01-015 selective per-feature enable/disable (journaled, idempotent).
    .DESCRIPTION
        Pipeline: capture current state via Get-WindowsOptionalFeature -> journal
        'feature' descriptor -> Enable/Disable-WindowsOptionalFeature -Online -NoRestart
        -> re-read state -> journal verified result.
        Honest rollback label: engine v0.1 does not auto-restore 'feature' targets -
        rollback is the documented inverse re-invocation; the original state is journaled.
        Restart-pending states (EnablePending/DisablePending) are reported, never hidden.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$FeatureName,
        [Parameter(Mandatory)][ValidateSet('Enabled','Disabled')][string]$State,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId = 'NX01-015',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @()
    )
    Import-Module Dism -ErrorAction Stop

    try {
        $before = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
    } catch {
        throw "optional feature '$FeatureName' could not be read (DISM): $($_.Exception.Message)"
    }
    if ($null -eq $before) { throw "optional feature '$FeatureName' not found (DISM returned no object)" }
    $beforeState = [string]$before.State

    if (-not $PSCmdlet.ShouldProcess($FeatureName, "Set optional feature state to $State")) {
        return [pscustomobject]@{ featureName = $FeatureName; changed = $false; verified = $false; journalSeq = $null; reason = 'WhatIf/Confirm: no mutation, no journal write'; originalState = $beforeState }
    }

    $original = [pscustomobject]@{ targetType = 'feature'; featureName = $FeatureName; existed = $true; state = $beforeState }
    $modified = [pscustomobject]@{ targetType = 'feature'; featureName = $FeatureName; state = $State }

    # Idempotency: already in desired state -> journal skip, never rewrite.
    if ($beforeState -eq $State) {
        $skipJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        return [pscustomobject]@{ featureName = $FeatureName; changed = $false; verified = $true; journalSeq = $skipJournal.seq; reason = 'already in desired state'; originalState = $beforeState }
    }

    $applyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles
    try {
        $result = $null
        if ($State -eq 'Enabled') {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction Stop
        } else {
            $result = Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction Stop
        }

        $restartNeeded = $null
        if ($null -ne $result -and $null -ne $result.PSObject.Properties['RestartNeeded']) {
            $restartNeeded = [bool]$result.RestartNeeded
        }

        $after = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
        $afterState = [string]$after.State
        $pendingState = if ($State -eq 'Enabled') { 'EnablePending' } else { 'DisablePending' }
        $verified = ($afterState -eq $State) -or ($afterState -eq $pendingState)
        $verifyLabel = if ($afterState -eq $pendingState) { 'Verified-RestartPending' } elseif ($verified) { 'Verified' } else { 'NotVerified' }
        $detail = "state now '$afterState' (requested '$State'); restartNeeded=$restartNeeded"

        $verifyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result $(if ($verified) { 'Success' } else { 'FailedVerification' }) -Verification $verifyLabel -ErrorInfo $(if ($verified) { '' } else { $detail }) -Profiles $Profiles
        return [pscustomobject]@{ featureName = $FeatureName; changed = $true; verified = $verified; journalSeq = $applyJournal.seq; verifySeq = $verifyJournal.seq; reason = $detail; originalState = $beforeState; newState = $afterState; restartNeeded = $restartNeeded }
    } catch {
        $err = [string]$_.Exception.Message
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles
        return [pscustomobject]@{ featureName = $FeatureName; changed = $false; verified = $false; journalSeq = $applyJournal.seq; reason = "mutation failed: $err"; originalState = $beforeState }
    }
}

function Invoke-NxDefaultAppAssociations {
    <#
    .SYNOPSIS
        NX01-016 documented DISM default-app-association import with pre-change export
        (journaled original-state artifact, verified result).
    .DESCRIPTION
        Flow: (1) DISM pre-change export to the timestamped backup set (SHA256-journaled);
        (2) DISM import of the owner-chosen XML; (3) verification via DISM exit code plus
        a post-import re-export and an informational set-diff count.
        Idempotency: byte-identical pre-change export == chosen XML -> journal skip
        (AlreadyApplied), overridable with -Force.
        UCPD note: the DISM XML path configures DEFAULTS (profile creation/system level)
        and never writes the UCPD-protected per-user UserChoice keys.
        Rollback honesty: re-import the journaled pre-change export (documented inverse);
        engine v0.1 does not auto-restore 'appAssociations' targets.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$XmlPath,
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$BackupDir,
        [string]$TweakId = 'NX01-016',
        [string]$TweakVersion = '1',
        [string]$Approval = 'Selection',
        [string[]]$Profiles = @(),
        [switch]$Force
    )
    if (-not (Test-Path -LiteralPath $XmlPath)) { throw "associations XML not found: $XmlPath" }
    $dism = Join-Path $env:SystemRoot 'System32\Dism.exe'
    if (-not (Test-Path -LiteralPath $dism)) { throw "DISM executable not found: $dism" }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    if (-not $BackupDir) { $BackupDir = Join-Path $env:ProgramData 'NEXTRIX\Backups\DefaultAppAssociations' }
    $runDir = Join-Path $BackupDir $timestamp
    if (-not (Test-Path -LiteralPath $runDir)) { New-Item -Path $runDir -ItemType Directory -Force | Out-Null }

    # Step 1: documented pre-change export (original-state artifact; additive, no system mutation).
    $preExport = Join-Path $runDir 'associations-pre-import.xml'
    $null = & $dism /Online "/Export-DefaultAppAssociations:$preExport" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $preExport)) {
        throw "DISM export failed (exit code $LASTEXITCODE); no mutation performed"
    }
    $preHash = (Get-FileHash -LiteralPath $preExport -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $XmlPath -Algorithm SHA256).Hash

    $original = [pscustomobject]@{ targetType = 'appAssociations'; preChangeExport = $preExport; preChangeSha256 = $preHash; importedSource = $XmlPath; importedSha256 = $targetHash; existed = $true }
    $modified = [pscustomobject]@{ targetType = 'appAssociations'; importedSource = $XmlPath; importedSha256 = $targetHash }

    if (-not $PSCmdlet.ShouldProcess($XmlPath, 'Import default application associations (DISM)')) {
        return [pscustomobject]@{ changed = $false; verified = $false; journalSeq = $null; reason = 'WhatIf/Confirm: no mutation, no journal write'; preChangeExport = $preExport }
    }

    # Idempotency: byte-identical export and source -> nothing to do.
    if (($preHash -eq $targetHash) -and (-not $Force)) {
        $skipJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'skip' -Approval $Approval -Original $original -Modified $modified -Result 'AlreadyApplied' -Verification 'NotRun' -Profiles $Profiles
        return [pscustomobject]@{ changed = $false; verified = $true; journalSeq = $skipJournal.seq; reason = 'current associations export is byte-identical to the chosen XML'; preChangeExport = $preExport }
    }

    $applyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'apply' -Approval $Approval -Original $original -Modified $modified -Result 'InProgress' -Verification 'NotRun' -Profiles $Profiles

    try {
        # Step 2: documented import (defaults consumed at profile creation / system level).
        $null = & $dism /Online "/Import-DefaultAppAssociations:$XmlPath" 2>&1
        $importCode = $LASTEXITCODE
        if ($importCode -ne 0) {
            $failReason = "DISM import failed (exit code $importCode)"
            $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $failReason -Profiles $Profiles
            return [pscustomobject]@{ changed = $false; verified = $false; journalSeq = $applyJournal.seq; reason = $failReason; preChangeExport = $preExport }
        }

        # Step 3: verification - DISM exit code is the documented success signal; the
        # re-export and set-diff are informational (association XML ordering/format noise
        # means byte equality is not required and is never claimed).
        $postExport = Join-Path $runDir 'associations-post-import.xml'
        $null = & $dism /Online "/Export-DefaultAppAssociations:$postExport" 2>&1
        $postCode = $LASTEXITCODE
        $diffCount = $null
        if ($postCode -eq 0 -and (Test-Path -LiteralPath $postExport)) {
            try {
                $preXml = [xml](Get-Content -LiteralPath $preExport -Raw -Encoding UTF8)
                $postXml = [xml](Get-Content -LiteralPath $postExport -Raw -Encoding UTF8)
                $pairsOf = {
                    param($doc)
                    $map = @{}
                    foreach ($a in @($doc.SelectNodes('//Association'))) {
                        $id = "$($a.Identifier)|$($a.ProgId)"
                        $map[$id] = $true
                    }
                    return $map
                }
                $preMap = & $pairsOf $preXml
                $postMap = & $pairsOf $postXml
                $onlyPre = @($preMap.Keys | Where-Object { -not $postMap.ContainsKey($_) })
                $onlyPost = @($postMap.Keys | Where-Object { -not $preMap.ContainsKey($_) })
                $diffCount = $onlyPre.Count + $onlyPost.Count
            } catch {
                $diffCount = $null  # informational only; never blocks the verified verdict
            }
        }
        $verifyJournal = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'verify' -Approval $Approval -Original $original -Modified $modified -Result 'Success' -Verification 'Verified' -Profiles $Profiles
        return [pscustomobject]@{
            changed         = $true
            verified        = $true
            journalSeq      = $applyJournal.seq
            verifySeq       = $verifyJournal.seq
            reason          = "DISM import exit code 0; re-export exit code $postCode; association diff count=$diffCount (informational)"
            preChangeExport = $preExport
            postExport      = $postExport
            diffCount       = $diffCount
        }
    } catch {
        $err = [string]$_.Exception.Message
        $null = Add-NxJournalEntry -Path $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Operation 'failed' -Approval $Approval -Original $original -Modified $modified -Result 'Failed' -Verification 'NotRun' -ErrorInfo $err -Profiles $Profiles
        return [pscustomobject]@{ changed = $false; verified = $false; journalSeq = $applyJournal.seq; reason = "mutation failed: $err"; preChangeExport = $preExport }
    }
}
