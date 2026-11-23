#Requires -Version 5.1
<#
    NX15.ps1 - NEXTRIX Visual & Interface category functions (NX15-004, NX15-005,
    NX15-009 read-only detector).

    Dependencies: dot-source AFTER the core modules (Import-NxCore order):
      NxJournal.ps1  -> Capture-NxRegistryValue, Add-NxJournalEntry
      NxVerify.ps1   -> Test-NxConfigurationState
      NxApply.ps1    -> Set-NxRegistryValue
      NxRollback.ps1 -> Restore-NxRegistryOriginal (best-effort restore on failed verify)
    This file defines functions only. Loading it performs no registry reads or writes,
    no service/CIM reads and no network access.

    Pipeline contract (NxApply.ps1, directive Section 8 - no exceptions):
      Capture-NxRegistryValue -> Add-NxJournalEntry -> mutate -> Test-NxConfigurationState
      -> Add-NxJournalEntry (result). Journal-first: no mutation without a preceding
      journal entry. Idempotent: an already-correct target journals a 'skip'
      (AlreadyApplied) and is never rewritten. Verification failures perform a
      best-effort restore of the exact recorded original, then journal 'failed'.

    Category policy:
      - Cosmetic only. No function here makes or reports a performance claim.
      - No UCPD fighting: on 24H2+ (build >= 26100) the taskbar widgets layer writes
        the documented AllowNewsAndInterests policy and NEVER attempts the
        UCPD-protected per-user TaskbarDa value (COMPATIBILITY_RESEARCH section 2).
      - Boundary: NX01-004 owns Start_IrisRecommendations; NX01-006 owns the
        Spotlight overlay/promo values; NX01-007 owns the toast master and
        lock-screen toast policy. None of those targets is written here.
      - Build detection is read-only and gates every build-conditional branch; the
        optional -BuildNumber parameter exists for test harnesses and never mutates.
#>

function Invoke-Nx15JournaledRegistryWrite {
    <#
        Internal helper: the exact 10-step registry pipeline with idempotent skip.
        Every mutating NX15 function routes registry writes through here so the
        journal-first order exists in exactly one place. Name-prefixed to avoid
        colliding with the equivalent NX01 private helper.
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

    # Steps 2-6: read current state (read-only capture).
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

function Get-Nx15BuildNumber {
    <#
    .SYNOPSIS
        Read-only build-number probe used by the NX15 build-conditional branches.
    .DESCRIPTION
        Reads CurrentBuildNumber from HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion
        (read-only) and falls back to the environment OS version. Returns 0 when the
        build cannot be determined, which callers treat as "out of verified scope"
        rather than guessing a branch.
    #>
    [CmdletBinding()]
    param()
    $build = 0
    try {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuildNumber' -ErrorAction Stop
        if ($null -ne $cv.CurrentBuildNumber) {
            $parsed = 0
            if ([int]::TryParse([string]$cv.CurrentBuildNumber, [ref]$parsed)) { $build = $parsed }
        }
    } catch {
        $build = 0
    }
    if ($build -le 0) { $build = [int][System.Environment]::OSVersion.Version.Build }
    return $build
}

function Set-NxTaskbarConfiguration {
    <#
    .SYNOPSIS
        NX15-004: taskbar configuration set (journaled, idempotent, UCPD-aware).
    .DESCRIPTION
        Layers: TaskbarAl=0 (left), SearchboxTaskbarMode=0 (hidden, on the Search
        key - verified live), ShowTaskViewButton=0, and widgets.
        Widgets is build-conditional: on 24H2+ (build >= 26100) the per-user
        TaskbarDa value is UCPD-protected and is NEVER written; the documented
        AllowNewsAndInterests=0 policy (HKLM\SOFTWARE\Policies\Microsoft\Dsh) is
        written instead. On 23H2 the per-user TaskbarDa=0 value is written.
        Cosmetic only: this function makes no performance claim.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId = 'NX15-004',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [int]$BuildNumber = 0
    )
    $build = if ($BuildNumber -gt 0) { $BuildNumber } else { Get-Nx15BuildNumber }
    $layers = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]

    if ($build -lt 22631 -or $build -gt 26300) {
        return [pscustomobject]@{
            tweakId = $TweakId; build = $build; skipped = $true; layers = @()
            widgetsMechanism = 'None'; ucpdPolicyFallback = $false; allVerified = $false
            notes = @("build $build is outside the ADR-003 verified scope (22631..26300); no taskbar write attempted")
        }
    }

    $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $search   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'

    $layers.Add((Invoke-Nx15JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $advanced -Name 'TaskbarAl' -Kind DWord -Value 0 -Profiles $Profiles))
    $layers.Add((Invoke-Nx15JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $search -Name 'SearchboxTaskbarMode' -Kind DWord -Value 0 -Profiles $Profiles))
    $layers.Add((Invoke-Nx15JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $advanced -Name 'ShowTaskViewButton' -Kind DWord -Value 0 -Profiles $Profiles))

    $widgetsMechanism = 'None'
    $ucpdPolicyFallback = $false
    if ($build -ge 26100) {
        # 24H2+ : TaskbarDa is UCPD-protected (Access Denied). Use the documented policy.
        $ucpdPolicyFallback = $true
        $widgetsMechanism = 'DocumentedPolicy'
        $layers.Add((Invoke-Nx15JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Kind DWord -Value 0 -Profiles $Profiles))
        $notes.Add('24H2+: per-user TaskbarDa is UCPD-protected and was not attempted; documented AllowNewsAndInterests=0 policy applied (machine-wide, disallows the widgets experience).')
    } else {
        $widgetsMechanism = 'PerUserValue'
        $layers.Add((Invoke-Nx15JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $advanced -Name 'TaskbarDa' -Kind DWord -Value 0 -Profiles $Profiles))
        $notes.Add('23H2: per-user TaskbarDa=0 applied (no UCPD protection documented for this build family).')
    }
    $notes.Add('An Explorer restart or sign-out may be needed for all taskbar surfaces to reflect the change.')

    $allVerified = (@($layers | Where-Object { -not $_.verified }).Count -eq 0)
    return [pscustomobject]@{
        tweakId            = $TweakId
        build              = $build
        skipped            = $false
        layers             = $layers.ToArray()
        widgetsMechanism   = $widgetsMechanism
        ucpdPolicyFallback = $ucpdPolicyFallback
        allVerified        = $allVerified
        notes              = $notes.ToArray()
    }
}

function Set-NxStartRecommendations {
    <#
    .SYNOPSIS
        NX15-005: Start recommendations configuration (journaled, idempotent).
    .DESCRIPTION
        Layers: Start_TrackDocs=0 and Start_TrackProgs=0 (Start_Track* family owned
        by NX15), HideRecommendedSection=1 (documented per-user policy), and on
        24H2+ DisableAccountNotifications=1 (documented policy) as the adjudicated
        resolution of Start_AccountNotifications.
        NEVER writes Start_IrisRecommendations (NX01-004) or the CDM suggestion
        values (NX01-004). Cosmetic only: no performance claim.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$JournalRoot,
        [string]$TweakId = 'NX15-005',
        [string]$TweakVersion = '1',
        [string]$Approval = 'SelectionPlusConfirmation',
        [string[]]$Profiles = @(),
        [int]$BuildNumber = 0
    )
    $build = if ($BuildNumber -gt 0) { $BuildNumber } else { Get-Nx15BuildNumber }
    $layers = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]

    if ($build -lt 22631 -or $build -gt 26300) {
        return [pscustomobject]@{
            tweakId = $TweakId; build = $build; skipped = $true; layers = @()
            accountNotificationsApplied = $false; allVerified = $false
            notes = @("build $build is outside the ADR-003 verified scope (22631..26300); no Start write attempted")
        }
    }

    $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $layers.Add((Invoke-Nx15JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $advanced -Name 'Start_TrackDocs' -Kind DWord -Value 0 -Profiles $Profiles))
    $layers.Add((Invoke-Nx15JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path $advanced -Name 'Start_TrackProgs' -Kind DWord -Value 0 -Profiles $Profiles))
    $layers.Add((Invoke-Nx15JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name 'HideRecommendedSection' -Kind DWord -Value 1 -Profiles $Profiles))

    $accountApplied = $false
    if ($build -ge 26100) {
        $layers.Add((Invoke-Nx15JournaledRegistryWrite -JournalRoot $JournalRoot -TweakId $TweakId -TweakVersion $TweakVersion -Approval $Approval -Path 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\AccountNotifications' -Name 'DisableAccountNotifications' -Kind DWord -Value 1 -Profiles $Profiles))
        $accountApplied = $true
        $notes.Add('24H2+: documented DisableAccountNotifications=1 policy applied (start account-notification surface); the undocumented Start_AccountNotifications value is never written.')
    } else {
        $notes.Add('23H2: DisableAccountNotifications policy is documented for 24H2+ only and was not written; Start_AccountNotifications remains untouched.')
    }
    $notes.Add('Start_IrisRecommendations and the CDM suggestion values belong to NX01-004 and were not touched.')
    $notes.Add('An Explorer restart or sign-out may be needed for the Recommended-section policy to apply.')

    $allVerified = (@($layers | Where-Object { -not $_.verified }).Count -eq 0)
    return [pscustomobject]@{
        tweakId                     = $TweakId
        build                       = $build
        skipped                     = $false
        layers                      = $layers.ToArray()
        accountNotificationsApplied = $accountApplied
        allVerified                 = $allVerified
        notes                       = $notes.ToArray()
    }
}

function Get-NxContextMenuState {
    <#
    .SYNOPSIS
        NX15-009 read-only context-menu state report (no mutation, no journal writes).
    .DESCRIPTION
        Reports the build classification (22H2/23H2 vs 24H2+) and the community
        classic-menu CLSID state. The classic-menu mutation is Defined, not shipped:
        enabling is key-creation semantics, the documented inverse deletes the CLSID
        key, and the v0.1 journal engine restores values rather than deleting keys it
        created; 24H2+ behaviour is also unverified. mutationSupported is always false.
    #>
    [CmdletBinding()]
    param([int]$BuildNumber = 0)
    $build = if ($BuildNumber -gt 0) { $BuildNumber } else { Get-Nx15BuildNumber }

    $buildClass = 'OutsideVerifiedFamily'
    if ($build -ge 26100) { $buildClass = '24H2PlusUnverified' }
    elseif ($build -ge 22621) { $buildClass = '22H2Or23H2' }

    $clsidPath  = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    $inprocPath = $clsidPath + '\InprocServer32'
    $clsidPresent  = Test-Path -LiteralPath $clsidPath
    $inprocPresent = Test-Path -LiteralPath $inprocPath
    $defaultValue = $null
    if ($inprocPresent) {
        try {
            $key = Get-Item -LiteralPath $inprocPath -ErrorAction Stop
            $defaultValue = $key.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } catch {
            $defaultValue = $null
        }
    }
    $classicIndicated = $clsidPresent -and $inprocPresent -and ([string]::IsNullOrEmpty([string]$defaultValue))

    $reasons = @(
        'Classic-menu enablement is key-creation semantics; the documented inverse deletes the CLSID key, which the v0.1 value-oriented journal cannot guarantee.',
        '24H2+ is the reference-divergent build; Microsoft documents the new context menu and Show more options, not a supported classic toggle.',
        'No mutation is shipped in engine v0.1 - this entry is Defined.'
    )

    return [pscustomobject]@{
        readOnly                     = $true
        tweakId                      = 'NX15-009'
        build                        = $build
        buildClass                   = $buildClass
        clsidKeyPresent              = $clsidPresent
        inprocServer32Present        = $inprocPresent
        inprocServer32DefaultValue   = $defaultValue
        classicMenuIndicatedByMethod = $classicIndicated
        mutationSupported            = $false
        status                       = 'Defined'
        reasons                      = $reasons
    }
}
