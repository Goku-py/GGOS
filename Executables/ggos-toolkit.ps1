#requires -Version 5.1
<#
GGOS Toolkit 0.1 - post-install companion app for the GGOS playbook.

WHAT THIS IS
    A single-file Windows Forms desktop app, PowerShell 5.1 compatible, zero
    external modules, zero compilation (Add-Type only loads WinForms/System).
    The playbook's toolkit task copies this script next to its siblings under
    %SystemRoot%\GGOS\ and a Start Menu shortcut launches it:
        powershell.exe -ExecutionPolicy Bypass -File "%SystemRoot%\GGOS\ggos-toolkit.ps1"
    It also runs fine straight from a repository checkout: all state reads use
    %SystemRoot%\GGOS and HKLM\SOFTWARE\GGOS, never $PSScriptRoot.

WHAT IT READS (never writes)
    %SystemRoot%\GGOS\ggos-verify.txt        PASS / DRIFT / NOTE lines (verify.ps1)
    %SystemRoot%\GGOS\skipped.txt           bounded-timeout skips (Invoke-GGCommand)
    %SystemRoot%\GGOS\rollback-manifest.txt  rollback gate audit trail (rollback.ps1)
    %SystemRoot%\GGOS\hive-backups\*.reg    per-hive exports (per-user / input tuning)
    %SystemRoot%\GGOS\ggos-security.txt     security report (playbook Security check)
    HKLM\SOFTWARE\GGOS                      Installed / AppliedVersion / LastVerify
    HKLM\SOFTWARE\GGOS\HardwarePolicy       Chassis / DriveType / RamMB / policies
    HKLM\SOFTWARE\GGOS\PreviousPowerPlan     PreviousPlanGuid (gaming-power.ps1)

WHAT IT LAUNCHES (only on explicit button clicks)
    verify.ps1        elevated (UAC): powershell.exe -NoProfile -ExecutionPolicy
                      Bypass -File "%SystemRoot%\GGOS\verify.ps1"
    shader-cache.ps1  elevated (UAC), same pattern, -Clean, after a confirmation
                      dialog; disabled with an explanation when the file is absent
    winget install    one per ticked checkbox, AS THE CURRENT USER (never elevated),
                      with output streamed into a read-only log box
    explorer.exe      opens %SystemRoot%\GGOS (view actions only)

WHAT IT NEVER DOES
    The Toolkit itself performs no writes - no files, no registry values, no
    telemetry, no network calls (winget is the only external process it runs).
    Every read and every button action is wrapped in try/catch: on a machine
    where GGOS was never installed, every dashboard row renders "not found"
    instead of crashing. Cancelling a UAC prompt is handled, not an error.
#>

$ErrorActionPreference = 'Stop'

# ============================================================================
# 0. Assemblies
# ============================================================================
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
}
catch {
    Write-Warning ('WinForms could not be loaded: ' + $_.Exception.Message)
    exit 1
}

# ============================================================================
# 1. Constants and script state
# ============================================================================
$script:ToolkitVersion = '0.1'
$script:GgosRoot       = Join-Path $env:SystemRoot 'GGOS'
$script:GgosRegRoot    = 'HKLM:\SOFTWARE\GGOS'

# Dark palette: window ~#14161A, flat controls, performance-green accent.
$script:ColBack        = [System.Drawing.Color]::FromArgb(20, 22, 26)
$script:ColPanel       = [System.Drawing.Color]::FromArgb(27, 30, 36)
$script:ColControl     = [System.Drawing.Color]::FromArgb(35, 39, 46)
$script:ColBorder      = [System.Drawing.Color]::FromArgb(58, 63, 72)
$script:ColText        = [System.Drawing.Color]::FromArgb(230, 232, 236)
$script:ColMuted       = [System.Drawing.Color]::FromArgb(152, 159, 170)
$script:ColAccent      = [System.Drawing.Color]::FromArgb(61, 214, 140)
$script:ColAccentText  = [System.Drawing.Color]::FromArgb(12, 26, 19)
$script:ColAccentHover = [System.Drawing.Color]::FromArgb(84, 224, 158)
$script:ColAmber       = [System.Drawing.Color]::FromArgb(232, 179, 61)

# Shared control references (filled in while the UI is built).
$script:MainForm     = $null
$script:TabsControl  = $null
$script:StatusLabel  = $null
$script:Tips         = $null
$script:DashHeading  = $null
$script:VerifyLabel  = $null
$script:ScriptsNote  = $null
$script:VerifyButton = $null
$script:ShaderButton  = $null
$script:ShaderNote   = $null
$script:GuidanceBox  = $null
$script:AppsLog      = $null
$script:AppsWingetNote = $null
$script:InstallButton = $null
$script:DashValues   = @{}
$script:AppChecks    = @()

# Background install plumbing (synchronized queue + state shared with the
# runspace; the WinForms timer below drains the queue on the UI thread).
$script:InstallQueue   = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$script:InstallState   = [hashtable]::Synchronized(@{})
$script:InstallState['Running'] = $false
$script:InstallShell   = $null
$script:InstallRunspace = $null
$script:InstallHandle  = $null
$script:InstallTimer   = $null

# ============================================================================
# 2. Safe readers - every read is guarded; a failure returns a fallback
# ============================================================================
function Test-GGPath {
    param([string]$Path)
    try { return (Test-Path -LiteralPath $Path) }
    catch { return $false }
}

function Get-GGRegValueSafe {
    # Returns the raw value data, or $null when the key or value is absent /
    # unreadable. Never throws.
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    }
    catch { return $null }
}

function Get-GGState {
    # Snapshot of every HKLM\SOFTWARE\GGOS stamp the playbook writes.
    $s = @{}
    $s['RootFound'] = $false
    try {
        if (Test-Path -LiteralPath $script:GgosRegRoot) { $s['RootFound'] = $true }
    }
    catch { }
    $s['Installed']        = Get-GGRegValueSafe -Path $script:GgosRegRoot -Name 'Installed'
    $s['AppliedVersion']   = Get-GGRegValueSafe -Path $script:GgosRegRoot -Name 'AppliedVersion'
    $s['LastVerify']      = Get-GGRegValueSafe -Path $script:GgosRegRoot -Name 'LastVerify'
    $hwPath = $script:GgosRegRoot + '\HardwarePolicy'
    $s['Chassis']          = Get-GGRegValueSafe -Path $hwPath -Name 'Chassis'
    $s['DriveType']        = Get-GGRegValueSafe -Path $hwPath -Name 'DriveType'
    $s['RamMB']            = Get-GGRegValueSafe -Path $hwPath -Name 'RamMB'
    $s['HibernationPolicy'] = Get-GGRegValueSafe -Path $hwPath -Name 'HibernationPolicy'
    $s['DefragPolicy']     = Get-GGRegValueSafe -Path $hwPath -Name 'DefragPolicy'
    $s['PreviousPlanGuid'] = Get-GGRegValueSafe -Path ($script:GgosRegRoot + '\PreviousPowerPlan') -Name 'PreviousPlanGuid'
    return $s
}

function Get-GGVerifyCounts {
    # Parses %SystemRoot%\GGOS\ggos-verify.txt exactly as verify.ps1 writes it:
    #   'PASS  <area>: <desc>'
    #   'DRIFT <area>: <desc> (<detail>)'
    #   'NOTE  <area>: <detail>'
    $v = @{ Found = $false; Pass = 0; Drift = 0; Note = 0; Written = $null; LedgerEmpty = $false }
    try {
        $file = Join-Path $script:GgosRoot 'ggos-verify.txt'
        if (-not (Test-GGPath $file)) { return $v }
        $v['Found'] = $true
        $lines = @(Get-Content -LiteralPath $file -ErrorAction Stop)
        foreach ($line in $lines) {
            $text = [string]$line
            if     ($text -match '^PASS\s')  { $v['Pass']++ }
            elseif ($text -match '^DRIFT\s') { $v['Drift']++ }
            elseif ($text -match '^NOTE\s')  { $v['Note']++ }
            if ($text -match 'ledger was empty or missing') { $v['LedgerEmpty'] = $true }
        }
        try {
            $v['Written'] = (Get-Item -LiteralPath $file -ErrorAction Stop).LastWriteTime
        } catch { }
    }
    catch { }
    return $v
}

function Get-GGManifestInfo {
    # Parses the most recent run out of rollback-manifest.txt. The manifest is
    # appended per playbook run (Add-Content), so the segment after the LAST
    # 'BEGIN rollback protection' line is the latest run. Line shape:
    #   <yyyy-MM-ddTHH:mm:ss> <message>
    $info = @{ Found = $false; BeginTime = $null; Sequence = $null; Verified = $null; Fallback = $false; BackupDir = $null }
    try {
        $path = Join-Path $script:GgosRoot 'rollback-manifest.txt'
        if (-not (Test-GGPath $path)) { return $info }
        $info['Found'] = $true
        $lines = @(Get-Content -LiteralPath $path -ErrorAction Stop)
        if ($lines.Count -eq 0) { return $info }
        $start = 0
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ([string]$lines[$i] -match 'BEGIN rollback protection') { $start = $i; break }
        }
        for ($i = $start; $i -lt $lines.Count; $i++) {
            $line = [string]$lines[$i]
            if ($line -notmatch '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\s+(.*)$') { continue }
            $stampText = $Matches[1]
            $msg = $Matches[2]
            if ($msg -match '^BEGIN rollback protection') {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse($stampText, [ref]$parsed)) { $info['BeginTime'] = $parsed }
            }
            elseif ($msg -match '^RESULT restore-point sequence=(\S*)\s+verified=(\S+)') {
                $info['Sequence'] = $Matches[1]
                $info['Verified'] = $Matches[2]
            }
            elseif ($msg -match '^RESULT restore-point unavailable') {
                $info['Fallback'] = $true
            }
            elseif ($msg -match '^RESULT registry-exports backupDir=(.+)$') {
                $info['BackupDir'] = $Matches[1].Trim()
            }
        }
    }
    catch { }
    return $info
}

function Get-GGHiveBackups {
    $files = @()
    try {
        $dir = Join-Path $script:GgosRoot 'hive-backups'
        if (Test-GGPath $dir) {
            $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.reg' -File -ErrorAction Stop |
                Sort-Object -Property LastWriteTime)
        }
    }
    catch { }
    return $files
}

function Get-GGRestoreGuidance {
    # Renders the read-only restore panel from actual file/registry reads.
    # Every missing artifact gets a graceful 'not found' line.
    $sb = New-Object System.Text.StringBuilder
    $manifestPath = Join-Path $script:GgosRoot 'rollback-manifest.txt'
    $m = Get-GGManifestInfo

    [void]$sb.AppendLine('Generated from this machine''s GGOS state - read-only guidance, nothing is executed by this panel.')

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('1) System Restore')
    if ($m['Found']) {
        if ($null -ne $m['BeginTime']) {
            [void]$sb.AppendLine(('    Playbook run began {0:yyyy-MM-dd HH:mm:ss} (from rollback-manifest.txt).' -f $m['BeginTime']))
            [void]$sb.AppendLine('    Press Win+R, run rstrui.exe, then pick the GGOS restore point dated just after that time.')
        }
        else {
            [void]$sb.AppendLine('    Press Win+R and run rstrui.exe, then look for a GGOS restore point.')
            [void]$sb.AppendLine('    (The run timestamp could not be parsed from the manifest.)')
        }
        if ($null -ne $m['Sequence']) {
            [void]$sb.AppendLine(('    Last run recorded: restore point sequence {0}, verified={1}.' -f $m['Sequence'], $m['Verified']))
        }
        elseif ($m['Fallback']) {
            [void]$sb.AppendLine('    Last run recorded: System Restore was UNAVAILABLE - the playbook fell back to registry exports (see 2).')
        }
        else {
            [void]$sb.AppendLine('    Last run recorded: no restore-point result line was found in the manifest.')
        }
    }
    else {
        [void]$sb.AppendLine(('    Not found - no rollback manifest at {0}.' -f $manifestPath))
        [void]$sb.AppendLine('    You can still run rstrui.exe (Win+R) and look for a GGOS restore point.')
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('2) Registry exports')
    $hiveDir = Join-Path $script:GgosRoot 'hive-backups'
    $files = Get-GGHiveBackups
    if ($files.Count -gt 0) {
        [void]$sb.AppendLine(('    Per-hive .reg backups in {0} - merge any of them by double-clicking the' -f $hiveDir))
        [void]$sb.AppendLine('    file and confirming the import prompt:')
        foreach ($f in $files) {
            try {
                [void]$sb.AppendLine(('      - {0}  ({1:N0} KB, modified {2:yyyy-MM-dd HH:mm})' -f $f.Name, ([math]::Round($f.Length / 1KB)), $f.LastWriteTime))
            }
            catch {
                [void]$sb.AppendLine(('      - {0}' -f $f.Name))
            }
        }
    }
    else {
        [void]$sb.AppendLine(('    No .reg files were found under {0} - per-user/input hive backups were not' -f $hiveDir))
        [void]$sb.AppendLine('    created, or they were removed after the run.')
    }
    if ($m['Found'] -and $null -ne $m['BackupDir']) {
        $dir = [string]$m['BackupDir']
        $exportFiles = @()
        $dirPresent = $false
        try { $dirPresent = Test-Path -LiteralPath $dir } catch { }
        if ($dirPresent) {
            try { $exportFiles = @(Get-ChildItem -LiteralPath $dir -Filter '*.reg' -File -ErrorAction Stop) } catch { }
        }
        if ($exportFiles.Count -gt 0) {
            [void]$sb.AppendLine('    Full-HKLM exports from the playbook run (present because System Restore was unavailable):')
            foreach ($f in $exportFiles) {
                try {
                    [void]$sb.AppendLine(('      - {0}  ({1:N0} KB, modified {2:yyyy-MM-dd HH:mm})' -f $f.FullName, ([math]::Round($f.Length / 1KB)), $f.LastWriteTime))
                }
                catch {
                    [void]$sb.AppendLine(('      - {0}' -f $f.FullName))
                }
            }
        }
        else {
            [void]$sb.AppendLine(('    The manifest records full-HKLM exports at {0}, but that folder or its .reg files were not found.' -f $dir))
        }
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('3) Power plan')
    $guid = Get-GGRegValueSafe -Path ($script:GgosRegRoot + '\PreviousPowerPlan') -Name 'PreviousPlanGuid'
    if ($guid) {
        [void]$sb.AppendLine('    Restore the plan that was active before GGOS by running:')
        [void]$sb.AppendLine(('        powercfg /setactive {0}' -f $guid))
        [void]$sb.AppendLine(('    Previous power plan GUID: {0} (recorded under HKLM\SOFTWARE\GGOS\PreviousPowerPlan).' -f $guid))
    }
    else {
        [void]$sb.AppendLine('    Previous power plan GUID: not recorded (no power-plan change was made -')
        [void]$sb.AppendLine('    laptop chassis, or a GGOS plan was already active when the playbook ran).')
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('4) Not covered by a restore')
    [void]$sb.AppendLine('    App removals, cleanup deletions, winget updates and per-user changes made')
    [void]$sb.AppendLine('    before the restore point are not covered.')
    [void]$sb.AppendLine('')

    return $sb.ToString()
}

function Get-GGSkippedText {
    try {
        $path = Join-Path $script:GgosRoot 'skipped.txt'
        if (-not (Test-GGPath $path)) {
            return ('No skips recorded (skipped.txt was not found under {0}).' -f $path)
        }
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$raw)) {
            return 'skipped.txt is present but empty - no command exceeded its timeout.'
        }
        return [string]$raw
    }
    catch {
        return ('skipped.txt could not be read: {0}' -f $_.Exception.Message)
    }
}

function Get-GGSecurityText {
    try {
        $path = Join-Path $script:GgosRoot 'ggos-security.txt'
        if (-not (Test-GGPath $path)) {
            return 'Not generated - run the playbook with Security check enabled.'
        }
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$raw)) {
            return 'ggos-security.txt is present but empty.'
        }
        return [string]$raw
    }
    catch {
        return ('ggos-security.txt could not be read: {0}' -f $_.Exception.Message)
    }
}

function Get-GGFoundWord {
    param([bool]$Present)
    if ($Present) { return 'found' }
    return 'MISSING'
}

# ============================================================================
# 3. WinForms control helpers (small, reusable - no 40 control blocks)
# ============================================================================
function Set-GGStatus {
    param([string]$Message)
    try {
        if ($null -ne $script:StatusLabel) { $script:StatusLabel.Text = $Message }
    }
    catch { }
}

function New-GGLabel {
    param(
        [string]$Text = '',
        [int]$X = 0, [int]$Y = 0, [int]$W = 200, [int]$H = 20,
        [object]$Color = $script:ColText,
        [double]$FontSize = 9.75,
        [switch]$Bold
    )
    $style = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
    $l = [System.Windows.Forms.Label]::new()
    $l.Text = $Text
    $l.Location = [System.Drawing.Point]::new($X, $Y)
    $l.Size = [System.Drawing.Size]::new($W, $H)
    $l.ForeColor = $Color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Font = [System.Drawing.Font]::new('Segoe UI', [single]$FontSize, $style, [System.Drawing.GraphicsUnit]::Point)
    return $l
}

function New-GGButton {
    param(
        [string]$Text = '',
        [int]$X = 0, [int]$Y = 0, [int]$W = 170, [int]$H = 34,
        [scriptblock]$OnClick = $null,
        [switch]$Accent
    )
    $b = [System.Windows.Forms.Button]::new()
    $b.Text = $Text
    $b.Location = [System.Drawing.Point]::new($X, $Y)
    $b.Size = [System.Drawing.Size]::new($W, $H)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 1
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Accent) {
        $b.BackColor = $script:ColAccent
        $b.ForeColor = $script:ColAccentText
        $b.FlatAppearance.BorderColor = $script:ColAccent
        $b.FlatAppearance.MouseOverBackColor = $script:ColAccentHover
    }
    else {
        $b.BackColor = $script:ColControl
        $b.ForeColor = $script:ColText
        $b.FlatAppearance.BorderColor = $script:ColBorder
        $b.FlatAppearance.MouseOverBackColor = $script:ColPanel
    }
    if ($null -ne $OnClick) { $b.Add_Click($OnClick) }
    return $b
}

function New-GGLogBox {
    # Read-only multiline dark text box, anchored to all four sides.
    param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$FontName = 'Consolas')
    $t = [System.Windows.Forms.TextBox]::new()
    $t.Multiline = $true
    $t.ReadOnly = $true
    $t.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $t.Location = [System.Drawing.Point]::new($X, $Y)
    $t.Size = [System.Drawing.Size]::new($W, $H)
    $t.BackColor = $script:ColPanel
    $t.ForeColor = $script:ColText
    $t.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $t.Font = [System.Drawing.Font]::new($FontName, 9.0)
    $t.WordWrap = $true
    $t.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor
        [System.Windows.Forms.AnchorStyles]::Left -bor
        [System.Windows.Forms.AnchorStyles]::Right -bor
        [System.Windows.Forms.AnchorStyles]::Bottom)
    return $t
}

function New-GGTab {
    param([string]$Text)
    $p = [System.Windows.Forms.TabPage]::new($Text)
    $p.BackColor = $script:ColBack
    $p.AutoScroll = $true
    $p.Padding = [System.Windows.Forms.Padding]::new(12, 10, 12, 12)
    return $p
}

function Add-GGSection {
    # Muted bold section title; returns the next Y.
    param($Page, [int]$Y, [string]$Title)
    $l = New-GGLabel -Text $Title -X 24 -Y $Y -W 780 -H 20 -Color $script:ColMuted -Bold -FontSize 9.0
    $Page.Controls.Add($l)
    return ($Y + 28)
}

function Add-GGInfoRow {
    # Caption/value pair; the value label is registered under $Key so the
    # dashboard refresh can update it in place. Returns the next Y.
    param($Page, [int]$Y, [string]$Key, [string]$Caption, [string]$Value)
    $cap = New-GGLabel -Text $Caption -X 24 -Y $Y -W 220 -H 20 -Color $script:ColMuted
    $val = New-GGLabel -Text $Value -X 250 -Y $Y -W 580 -H 20 -Color $script:ColMuted
    $Page.Controls.Add($cap)
    $Page.Controls.Add($val)
    if (-not [string]::IsNullOrEmpty($Key)) { $script:DashValues[$Key] = $val }
    return ($Y + 26)
}

function Show-GGTextDialog {
    # Small dark read-only viewer used for skipped.txt and the security report.
    param([string]$Title, [string]$Body)
    try {
        $dlg = [System.Windows.Forms.Form]::new()
        $dlg.Text = $Title
        $dlg.Size = [System.Drawing.Size]::new(760, 520)
        $dlg.MinimumSize = [System.Drawing.Size]::new(520, 320)
        $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $dlg.BackColor = $script:ColBack
        $dlg.ShowInTaskbar = $false
        $box = New-GGLogBox -X 12 -Y 12 -W 724 -H 420 -FontName 'Consolas'
        $box.Text = [string]$Body
        $btn = New-GGButton -Text 'Close' -X 648 -Y 444 -W 88 -H 30
        $btn.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor
            [System.Windows.Forms.AnchorStyles]::Right)
        $btn.Add_Click({ param($sender2, $e2) try { $sender2.FindForm().Close() } catch { } })
        $dlg.Controls.Add($box)
        $dlg.Controls.Add($btn)
        [void]$dlg.ShowDialog($script:MainForm)
        $dlg.Dispose()
    }
    catch {
        Set-GGStatus ('The viewer could not be opened: {0}' -f $_.Exception.Message)
    }
}

# ============================================================================
# 4. Action helpers
# ============================================================================
function Start-GGElevatedScript {
    # The ONLY self-elevation path in the Toolkit: launches a sibling script in
    # a new elevated PowerShell window (UAC). A cancelled UAC prompt lands in
    # the catch below - reported in the status strip, never a crash.
    param([string]$ScriptPath, [string[]]$ExtraArgs = @(), [string]$What = 'script', [string]$SuccessStatus = $null)
    if (-not (Test-GGPath $ScriptPath)) {
        Set-GGStatus ('{0} was not launched - not found at {1}.' -f $What, $ScriptPath)
        return $false
    }
    try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptPath + '"'))
        if ($ExtraArgs.Count -gt 0) { $argList += $ExtraArgs }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -WorkingDirectory $script:GgosRoot | Out-Null
        if ([string]::IsNullOrEmpty($SuccessStatus)) {
            Set-GGStatus ('{0} launched in an elevated PowerShell window.' -f $What)
        }
        else {
            Set-GGStatus $SuccessStatus
        }
        return $true
    }
    catch {
        Set-GGStatus ('{0} was not launched - the elevation prompt was cancelled or elevation is unavailable.' -f $What)
        return $false
    }
}

function Enable-GGInstallControls {
    param([bool]$Enabled)
    try {
        if ($null -ne $script:InstallButton) { $script:InstallButton.Enabled = $Enabled }
        foreach ($cb in @($script:AppChecks)) { try { $cb.Enabled = $Enabled } catch { } }
    }
    catch { }
}

# ============================================================================
# 5. Form, tab control, pages
# ============================================================================
$form = [System.Windows.Forms.Form]::new()
$form.Text = 'GGOS Toolkit'
$form.BackColor = $script:ColBack
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9.75)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MinimumSize = [System.Drawing.Size]::new(860, 560)
$form.Size = [System.Drawing.Size]::new(980, 660)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScaleDimensions = [System.Drawing.SizeF]::new([single]96.0, [single]96.0)
$script:MainForm = $form
$script:Tips = [System.Windows.Forms.ToolTip]::new()
$script:Tips.ShowAlways = $true

# ---- TabControl with dark owner-drawn headers ----
$tabs = [System.Windows.Forms.TabControl]::new()
$tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
$tabs.DrawMode = [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed
$tabs.Padding = [System.Drawing.Point]::new(12, 6)
$tabs.Font = $form.Font
$tabs.BackColor = $script:ColPanel
$script:TabsControl = $tabs
$tabs.Add_DrawItem({
    param($sender, $e)
    try {
        $selected = ([int]($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
        $bg = $script:ColPanel
        $fg = $script:ColMuted
        if ($selected) { $bg = $script:ColBack; $fg = $script:ColText }
        $brush = [System.Drawing.SolidBrush]::new($bg)
        try {
            $e.Graphics.FillRectangle($brush, $e.Bounds)
            $textBrush = [System.Drawing.SolidBrush]::new($fg)
            try {
                $sf = [System.Drawing.StringFormat]::new()
                try {
                    $sf.Alignment = [System.Drawing.StringAlignment]::Center
                    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
                    $rect = [System.Drawing.RectangleF]::new([single]$e.Bounds.X, [single]$e.Bounds.Y, [single]$e.Bounds.Width, [single]$e.Bounds.Height)
                    $e.Graphics.DrawString($sender.TabPages[$e.Index].Text, $sender.Font, $textBrush, $rect, $sf)
                }
                finally { $sf.Dispose() }
            }
            finally { $textBrush.Dispose() }
            if ($selected) {
                $pen = [System.Drawing.Pen]::new($script:ColAccent, [single]2.0)
                try { $e.Graphics.DrawLine($pen, $e.Bounds.X, $e.Bounds.Bottom - 1, $e.Bounds.Right - 1, $e.Bounds.Bottom - 1) }
                finally { $pen.Dispose() }
            }
        }
        finally { $brush.Dispose() }
    }
    catch { }
})
$tabs.Add_SelectedIndexChanged({
    try {
        if ($script:TabsControl.SelectedIndex -eq 1) { Update-GGMaintenance }
    }
    catch { }
})

# ============================================================================
# 5a. Tab 1 - Dashboard
# ============================================================================
$pageDash = New-GGTab 'Dashboard'

$script:DashHeading = New-GGLabel -Text 'Reading GGOS state...' -X 24 -Y 16 -W 780 -H 24 -Color $script:ColAccent -Bold -FontSize 11.5
$pageDash.Controls.Add($script:DashHeading)

$y = 48
$y = Add-GGSection -Page $pageDash -Y $y -Title 'Install state'
$y = Add-GGInfoRow -Page $pageDash -Y $y -Key 'Installed' -Caption 'Installed' -Value 'not found'
$y = Add-GGInfoRow -Page $pageDash -Y $y -Key 'AppliedVersion' -Caption 'Applied version' -Value 'not found'
$y = Add-GGInfoRow -Page $pageDash -Y $y -Key 'LastVerify' -Caption 'Last verification' -Value 'not found'

$y = $y + 8
$y = Add-GGSection -Page $pageDash -Y $y -Title 'Hardware policy'
$y = Add-GGInfoRow -Page $pageDash -Y $y -Key 'Chassis' -Caption 'Chassis' -Value 'not found'
$y = Add-GGInfoRow -Page $pageDash -Y $y -Key 'DriveType' -Caption 'System drive type' -Value 'not found'
$y = Add-GGInfoRow -Page $pageDash -Y $y -Key 'RamMB' -Caption 'Installed RAM' -Value 'not found'
$y = Add-GGInfoRow -Page $pageDash -Y $y -Key 'HibernationPolicy' -Caption 'Hibernation policy' -Value 'not found'
$y = Add-GGInfoRow -Page $pageDash -Y $y -Key 'DefragPolicy' -Caption 'Defrag policy' -Value 'not found'

$y = $y + 8
$y = Add-GGSection -Page $pageDash -Y $y -Title 'Power plan'
$y = Add-GGInfoRow -Page $pageDash -Y $y -Key 'PreviousPlanGuid' -Caption 'Previous power plan GUID' -Value 'not found'

$y = $y + 8
$y = Add-GGSection -Page $pageDash -Y $y -Title 'Verification'
$script:VerifyLabel = New-GGLabel -Text 'not found' -X 24 -Y $y -W 780 -H 22 -Color $script:ColMuted -Bold
$pageDash.Controls.Add($script:VerifyLabel)
$y = $y + 34

$btnVerify = New-GGButton -Text 'Re-run verification' -X 24 -Y $y -W 210 -H 34 -Accent -OnClick {
    try {
        $path = Join-Path $script:GgosRoot 'verify.ps1'
        if (-not (Test-GGPath $path)) {
            Set-GGStatus 'verify.ps1 was not found - nothing was launched.'
            return
        }
        $null = Start-GGElevatedScript -ScriptPath $path -ExtraArgs @() -What 'Verification' `
            -SuccessStatus 'Verification launched elevated - click Refresh after the window closes to load the new report.'
    }
    catch { Set-GGStatus ('Unexpected error: {0}' -f $_.Exception.Message) }
}
$script:VerifyButton = $btnVerify
$script:Tips.SetToolTip($btnVerify, ('Disabled because verify.ps1 was not found under {0}. Re-run the playbook with the Toolkit option to install it.' -f $script:GgosRoot))
$pageDash.Controls.Add($btnVerify)

# Small secondary refresh so a re-run verification actually shows up in the UI
# without closing and reopening the app (re-reads all state; writes nothing).
$btnRefresh = New-GGButton -Text 'Refresh' -X 244 -Y $y -W 100 -H 34 -OnClick {
    try {
        Update-GGDashboard
        Update-GGMaintenance
        Set-GGStatus 'Refreshed - GGOS state was re-read from this machine.'
    }
    catch { Set-GGStatus ('Refresh failed: {0}' -f $_.Exception.Message) }
}
$pageDash.Controls.Add($btnRefresh)

$btnFolder = New-GGButton -Text 'Open GGOS folder' -X 354 -Y $y -W 180 -H 34 -OnClick {
    try {
        if (-not (Test-GGPath $script:GgosRoot)) {
            Set-GGStatus ('The GGOS folder does not exist: {0}' -f $script:GgosRoot)
            return
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList $script:GgosRoot | Out-Null
        Set-GGStatus ('Opened {0} in File Explorer.' -f $script:GgosRoot)
    }
    catch { Set-GGStatus ('Could not open the folder: {0}' -f $_.Exception.Message) }
}
$pageDash.Controls.Add($btnFolder)
$y = $y + 44

$btnSkipped = New-GGButton -Text 'View skipped.txt' -X 24 -Y $y -W 160 -H 34 -OnClick {
    try { Show-GGTextDialog -Title 'GGOS Toolkit - skipped.txt' -Body (Get-GGSkippedText) }
    catch { Set-GGStatus ('Unexpected error: {0}' -f $_.Exception.Message) }
}
$pageDash.Controls.Add($btnSkipped)

$btnSecurity = New-GGButton -Text 'View security report' -X 194 -Y $y -W 180 -H 34 -OnClick {
    try { Show-GGTextDialog -Title 'GGOS Toolkit - security report' -Body (Get-GGSecurityText) }
    catch { Set-GGStatus ('Unexpected error: {0}' -f $_.Exception.Message) }
}
$pageDash.Controls.Add($btnSecurity)
$y = $y + 44

$script:ScriptsNote = New-GGLabel -Text 'Sibling scripts: checking...' -X 24 -Y $y -W 780 -H 18 -Color $script:ColMuted -FontSize 8.75
$pageDash.Controls.Add($script:ScriptsNote)

# ============================================================================
# 5b. Tab 2 - Maintenance
# ============================================================================
$pageMaint = New-GGTab 'Maintenance'

$y = 16
$y = Add-GGSection -Page $pageMaint -Y $y -Title 'Maintenance'

$btnShader = New-GGButton -Text 'Clean GPU shader caches' -X 24 -Y $y -W 240 -H 34 -Accent -OnClick {
    try {
        $path = Join-Path $script:GgosRoot 'shader-cache.ps1'
        if (-not (Test-GGPath $path)) {
            Set-GGStatus 'shader-cache.ps1 was not found - nothing was launched.'
            return
        }
        $answer = [System.Windows.Forms.MessageBox]::Show($script:MainForm,
            'Deletes only documented shader cache files under your user profile. Continue?',
            'GGOS Toolkit - clean shader caches',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Set-GGStatus 'Cancelled - nothing was changed.'
            return
        }
        $null = Start-GGElevatedScript -ScriptPath $path -ExtraArgs @('-Clean') -What 'Shader cache clean' `
            -SuccessStatus 'Shader cache clean launched in an elevated PowerShell window.'
    }
    catch { Set-GGStatus ('Unexpected error: {0}' -f $_.Exception.Message) }
}
$script:ShaderButton = $btnShader
$script:Tips.SetToolTip($btnShader, ('Disabled because shader-cache.ps1 was not found under {0}. Re-run the playbook with the Toolkit option to install it.' -f $script:GgosRoot))
$pageMaint.Controls.Add($btnShader)

$shaderDesc = New-GGLabel -Text ('Runs the playbook''s shader-cache.ps1 with -Clean in an elevated PowerShell window (UAC prompt). Only documented shader cache files under your user profile are deleted.') -X 280 -Y $y -W 540 -H 36 -Color $script:ColMuted -FontSize 8.75
$pageMaint.Controls.Add($shaderDesc)
$y = $y + 44

$script:ShaderNote = New-GGLabel -Text 'shader-cache.ps1: checking...' -X 24 -Y $y -W 780 -H 18 -Color $script:ColMuted -FontSize 8.75
$pageMaint.Controls.Add($script:ShaderNote)
$y = $y + 30

$y = Add-GGSection -Page $pageMaint -Y $y -Title 'Restore guidance (read-only)'

$script:GuidanceBox = New-GGLogBox -X 24 -Y $y -W 780 -H 300 -FontName 'Consolas'
$pageMaint.Controls.Add($script:GuidanceBox)

# ============================================================================
# 5c. Tab 3 - Apps
# ============================================================================
$pageApps = New-GGTab 'Apps'

$y = 16
$y = Add-GGSection -Page $pageApps -Y $y -Title 'App installs (winget, current user)'

# Pinned winget IDs - installed one per ticked checkbox, AS THE CURRENT USER.
$appDefs = @(
    @{ Name = 'Firefox';   Id = 'Mozilla.Firefox' },
    @{ Name = 'Brave';     Id = 'Brave.Brave' },
    @{ Name = '7-Zip';     Id = '7zip.7zip' },
    @{ Name = 'PowerToys'; Id = 'Microsoft.PowerToys' },
    @{ Name = 'Steam';     Id = 'Valve.Steam' },
    @{ Name = 'Discord';   Id = 'Discord.Discord' },
    @{ Name = 'VLC';       Id = 'VideoLAN.VLC' }
)
$y = $y + 2
foreach ($app in $appDefs) {
    $cb = [System.Windows.Forms.CheckBox]::new()
    $cb.Text = ('{0}  ({1})' -f $app.Name, $app.Id)
    $cb.Tag = [string]$app.Id
    $cb.Location = [System.Drawing.Point]::new(28, $y)
    $cb.Size = [System.Drawing.Size]::new(360, 24)
    $cb.ForeColor = $script:ColText
    $cb.BackColor = $script:ColBack
    $cb.Font = $form.Font
    $pageApps.Controls.Add($cb)
    $script:AppChecks += $cb
    $y = $y + 29
}
$y = $y + 8

$btnInstall = New-GGButton -Text 'Install selected' -X 24 -Y $y -W 180 -H 34 -Accent -OnClick { Invoke-GGAppInstall }
$script:InstallButton = $btnInstall
$pageApps.Controls.Add($btnInstall)

$appsNote = New-GGLabel -Text 'Apps install for the current user only, via winget.' -X 220 -Y ($y + 7) -W 560 -H 20 -Color $script:ColMuted
$pageApps.Controls.Add($appsNote)
$y = $y + 44

$script:AppsWingetNote = New-GGLabel -Text 'Checking winget availability...' -X 24 -Y $y -W 780 -H 18 -Color $script:ColMuted -FontSize 8.75
$pageApps.Controls.Add($script:AppsWingetNote)
$y = $y + 26

$script:AppsLog = New-GGLogBox -X 24 -Y $y -W 780 -H 230
$script:AppsLog.AppendText('winget output will appear here after you press Install selected.' + "`r`n")
$pageApps.Controls.Add($script:AppsLog)

# ============================================================================
# 5d. Tab 4 - About
# ============================================================================
$pageAbout = New-GGTab 'About'

$aboutHead = New-GGLabel -Text ('GGOS Toolkit {0}' -f $script:ToolkitVersion) -X 24 -Y 24 -W 780 -H 30 -Color $script:ColAccent -Bold -FontSize 14
$pageAbout.Controls.Add($aboutHead)

$about1 = New-GGLabel -Text 'Part of the GGOS playbook (github.com/Goku-py/GGOS).' -X 24 -Y 70 -W 780 -H 20
$pageAbout.Controls.Add($about1)

$about2 = New-GGLabel -Text 'Ideas studied from CTT WinUtil (MIT) and community playbooks; no code copied.' -X 24 -Y 98 -W 780 -H 20 -Color $script:ColMuted
$pageAbout.Controls.Add($about2)

$about3 = New-GGLabel -Text ('The Toolkit only changes your system through the actions you explicitly trigger on this window.') -X 24 -Y 132 -W 780 -H 20 -Bold
$pageAbout.Controls.Add($about3)

$about4 = New-GGLabel -Text ('The Toolkit itself writes no files and no registry values - it reads GGOS state, and only your clicks launch the sibling scripts (verify.ps1, shader-cache.ps1) or winget.') -X 24 -Y 166 -W 780 -H 36 -Color $script:ColMuted
$pageAbout.Controls.Add($about4)

$about5 = New-GGLabel -Text ('State folder: {0}  -  Registry stamps: HKLM\SOFTWARE\GGOS' -f $script:GgosRoot) -X 24 -Y 214 -W 780 -H 20 -Color $script:ColMuted -FontSize 8.75
$pageAbout.Controls.Add($about5)

# ============================================================================
# 5e. Status strip + assembly of the window
# ============================================================================
$strip = [System.Windows.Forms.StatusStrip]::new()
$strip.BackColor = $script:ColPanel
$strip.SizingGrip = $false
$strip.Dock = [System.Windows.Forms.DockStyle]::Bottom
$lblVersion = [System.Windows.Forms.ToolStripStatusLabel]::new()
$lblVersion.Text = ('GGOS Toolkit {0}' -f $script:ToolkitVersion)
$lblVersion.ForeColor = $script:ColMuted
$script:StatusLabel = [System.Windows.Forms.ToolStripStatusLabel]::new()
$script:StatusLabel.Text = 'Ready.'
$script:StatusLabel.ForeColor = $script:ColText
$script:StatusLabel.Spring = $true
$script:StatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$strip.Items.AddRange(@($lblVersion, $script:StatusLabel))

$tabs.TabPages.AddRange(@($pageDash, $pageMaint, $pageApps, $pageAbout))

# Fill control first, then the docked strip (docking is computed in reverse
# z-order, so the Fill tab control yields the strip's space correctly).
$form.Controls.Add($tabs)
$form.Controls.Add($strip)

$form.Add_FormClosing({
    param($sender, $e)
    try {
        if ($script:InstallState['Running']) {
            $answer = [System.Windows.Forms.MessageBox]::Show($script:MainForm,
                'An app install is still running in the background. Close the Toolkit anyway?',
                'GGOS Toolkit',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true }
        }
    }
    catch { }
})

# ============================================================================
# 6. Background winget install (runspace + UI-thread drain timer)
# ============================================================================
$script:WingetScriptText = @'
param($Ids, $Queue, $State)
$ErrorActionPreference = 'Continue'
try {
    foreach ($id in $Ids) {
        $Queue.Enqueue('--- winget install --exact --id ' + $id + ' --silent --accept-package-agreements --accept-source-agreements ---')
        try {
            $output = @(& winget.exe install --exact --id $id --silent --accept-package-agreements --accept-source-agreements 2>&1)
            $code = $LASTEXITCODE
            foreach ($line in $output) {
                if ($null -ne $line) { $Queue.Enqueue([string]$line) }
            }
            if ($code -eq 0) {
                $Queue.Enqueue('OK: ' + $id + ' installed (winget exit code 0).')
            }
            else {
                $Queue.Enqueue('FAILED: ' + $id + ' (winget exit code ' + $code + ').')
            }
        }
        catch {
            $Queue.Enqueue('ERROR: ' + $id + ' could not be run: ' + $_.Exception.Message)
        }
        $Queue.Enqueue('')
    }
}
finally {
    # Always release the UI flag so the timer stops and controls re-enable.
    $State['Running'] = $false
}
'@

function Invoke-GGAppInstall {
    # Runs every ticked app's winget install AS THE CURRENT USER (no elevation,
    # same as the playbook's winget task) on a background runspace; the timer
    # moves its output into the read-only log box on the UI thread.
    try {
        if ($script:InstallState['Running']) {
            Set-GGStatus 'An install run is already in progress.'
            return
        }
        $ids = @()
        foreach ($cb in @($script:AppChecks)) {
            try { if ($cb.Checked) { $ids += [string]$cb.Tag } } catch { }
        }
        if ($ids.Count -eq 0) {
            Set-GGStatus 'Select at least one app first.'
            return
        }
        if ($null -eq (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            $script:AppsLog.AppendText('winget not available on this system.' + "`r`n")
            Set-GGStatus 'winget not available on this system.'
            return
        }

        $shell = [System.Management.Automation.PowerShell]::new()
        $runspace = $null
        try {
            $null = $shell.AddScript($script:WingetScriptText)
            $null = $shell.AddArgument([string[]]$ids)
            $null = $shell.AddArgument($script:InstallQueue)
            $null = $shell.AddArgument($script:InstallState)
            $runspace = [runspacefactory]::CreateRunspace()
            try { $runspace.ApartmentState = [System.Threading.ApartmentState]::STA } catch { }
            $runspace.Open()
            $shell.Runspace = $runspace
            $script:InstallShell = $shell
            $script:InstallRunspace = $runspace
            $script:InstallState['Running'] = $true
            $script:InstallHandle = $shell.BeginInvoke()
            Enable-GGInstallControls $false
            $script:AppsLog.AppendText(('--- Installing {0} app(s) as the current user: {1}' -f $ids.Count, ($ids -join ', ')) + "`r`n")
            $script:InstallTimer.Start()
            Set-GGStatus ('Installing {0} app(s) via winget...' -f $ids.Count)
        }
        catch {
            $script:InstallState['Running'] = $false
            try { if ($null -ne $runspace) { $runspace.Dispose() } } catch { }
            try { $shell.Dispose() } catch { }
            Enable-GGInstallControls $true
            Set-GGStatus ('The install run could not be started: {0}' -f $_.Exception.Message)
        }
    }
    catch {
        Enable-GGInstallControls $true
        Set-GGStatus ('Unexpected error: {0}' -f $_.Exception.Message)
    }
}

$script:InstallTimer = [System.Windows.Forms.Timer]::new()
$script:InstallTimer.Interval = 400
$script:InstallTimer.Add_Tick({
    try {
        while ($script:InstallQueue.Count -gt 0) {
            $line = [string]$script:InstallQueue.Dequeue()
            $script:AppsLog.AppendText($line + "`r`n")
        }
        if (-not $script:InstallState['Running'] -and $script:InstallQueue.Count -eq 0) {
            $script:InstallTimer.Stop()
            try {
                if ($null -ne $script:InstallShell) {
                    $null = $script:InstallShell.EndInvoke($script:InstallHandle)
                    $script:InstallShell.Dispose()
                }
                if ($null -ne $script:InstallRunspace) { $script:InstallRunspace.Dispose() }
            }
            catch { }
            $script:InstallShell = $null
            $script:InstallRunspace = $null
            $script:InstallHandle = $null
            Enable-GGInstallControls $true
            $script:AppsLog.AppendText('--- Install run finished.' + "`r`n")
            Set-GGStatus 'App install run finished - see the log above.'
        }
    }
    catch { }
})

# ============================================================================
# 7. Dashboard / maintenance refresh
# ============================================================================
function Set-GGRowValue {
    param([string]$Key, [string]$Value, [object]$Color = $script:ColText)
    try {
        $l = $script:DashValues[$Key]
        if ($null -ne $l) { $l.Text = $Value; $l.ForeColor = $Color }
    }
    catch { }
}

function Update-GGDashboard {
    try {
        $s = Get-GGState

        if ($s['RootFound']) {
            $script:DashHeading.Text = 'GGOS state on this machine'
            $script:DashHeading.ForeColor = $script:ColAccent
        }
        else {
            $script:DashHeading.Text = 'GGOS not detected - the playbook has not been run on this machine (or its state was removed)'
            $script:DashHeading.ForeColor = $script:ColAmber
        }

        # ---- Install state ----
        $installed = $s['Installed']
        if ($null -ne $installed) {
            try {
                if ([int]$installed -eq 1) {
                    Set-GGRowValue 'Installed' 'Yes (HKLM\SOFTWARE\GGOS Installed = 1)' $script:ColText
                }
                else {
                    Set-GGRowValue 'Installed' ('No (Installed = {0})' -f $installed) $script:ColMuted
                }
            }
            catch { Set-GGRowValue 'Installed' 'not found' $script:ColMuted }
        }
        else { Set-GGRowValue 'Installed' 'not found' $script:ColMuted }

        if ($null -ne $s['AppliedVersion']) {
            Set-GGRowValue 'AppliedVersion' ([string]$s['AppliedVersion']) $script:ColText
        }
        else { Set-GGRowValue 'AppliedVersion' 'not found' $script:ColMuted }

        if ($null -ne $s['LastVerify']) {
            Set-GGRowValue 'LastVerify' ([string]$s['LastVerify']) $script:ColText
        }
        else { Set-GGRowValue 'LastVerify' 'not found' $script:ColMuted }

        # ---- Hardware policy ----
        if ($null -ne $s['Chassis']) { Set-GGRowValue 'Chassis' ([string]$s['Chassis']) $script:ColText }
        else { Set-GGRowValue 'Chassis' 'not found' $script:ColMuted }

        if ($null -ne $s['DriveType']) { Set-GGRowValue 'DriveType' ([string]$s['DriveType']) $script:ColText }
        else { Set-GGRowValue 'DriveType' 'not found' $script:ColMuted }

        $ram = $null
        try { if ($null -ne $s['RamMB']) { $ram = [int]$s['RamMB'] } } catch { }
        if ($null -ne $ram -and $ram -gt 0) {
            Set-GGRowValue 'RamMB' ('{0} MB (~{1:N1} GB)' -f $ram, ($ram / 1024)) $script:ColText
        }
        else { Set-GGRowValue 'RamMB' 'not recorded' $script:ColMuted }

        if ($null -ne $s['HibernationPolicy']) { Set-GGRowValue 'HibernationPolicy' ([string]$s['HibernationPolicy']) $script:ColText }
        else { Set-GGRowValue 'HibernationPolicy' 'not found' $script:ColMuted }

        if ($null -ne $s['DefragPolicy']) { Set-GGRowValue 'DefragPolicy' ([string]$s['DefragPolicy']) $script:ColText }
        else { Set-GGRowValue 'DefragPolicy' 'not found' $script:ColMuted }

        # ---- Power plan ----
        if ($null -ne $s['PreviousPlanGuid']) {
            Set-GGRowValue 'PreviousPlanGuid' ([string]$s['PreviousPlanGuid']) $script:ColText
        }
        else { Set-GGRowValue 'PreviousPlanGuid' 'not recorded' $script:ColMuted }

        # ---- Verification summary (DRIFT highlighted amber) ----
        $v = Get-GGVerifyCounts
        if ($v['Found'] -and $v['LedgerEmpty'] -and (($v['Pass'] + $v['Drift'] + $v['Note']) -eq 0)) {
            $script:VerifyLabel.Text = 'Verification: nothing verified - the option ledger was empty at verify time.'
            $script:VerifyLabel.ForeColor = $script:ColMuted
        }
        elseif ($v['Found'] -and (($v['Pass'] + $v['Drift'] + $v['Note']) -gt 0)) {
            $text = ('Verification: {0} PASS · {1} DRIFT · {2} NOTE' -f $v['Pass'], $v['Drift'], $v['Note'])
            if ($null -ne $v['Written']) {
                $text = $text + ('  (report written {0:yyyy-MM-dd HH:mm})' -f $v['Written'])
            }
            $script:VerifyLabel.Text = $text
            if ($v['Drift'] -gt 0) { $script:VerifyLabel.ForeColor = $script:ColAmber }
            else { $script:VerifyLabel.ForeColor = $script:ColAccent }
        }
        elseif ($v['Found']) {
            $script:VerifyLabel.Text = 'Verification: report exists but contains no PASS/DRIFT/NOTE lines.'
            $script:VerifyLabel.ForeColor = $script:ColMuted
        }
        else {
            $script:VerifyLabel.Text = 'Verification: report not found - re-run verification (or run the playbook) to generate it.'
            $script:VerifyLabel.ForeColor = $script:ColMuted
        }

        # ---- Sibling script availability (buttons + explanatory text) ----
        $verifyPresent = Test-GGPath (Join-Path $script:GgosRoot 'verify.ps1')
        $commonPresent = Test-GGPath (Join-Path $script:GgosRoot 'ggos-common.psm1')
        $shaderPresent = Test-GGPath (Join-Path $script:GgosRoot 'shader-cache.ps1')
        try { $script:VerifyButton.Enabled = $verifyPresent } catch { }
        $anyMissing = (-not $verifyPresent) -or (-not $commonPresent) -or (-not $shaderPresent)
        $script:ScriptsNote.Text = ('Sibling scripts under {0}: verify.ps1 {1} | ggos-common.psm1 {2} | shader-cache.ps1 {3}' -f `
            $script:GgosRoot, (Get-GGFoundWord $verifyPresent), (Get-GGFoundWord $commonPresent), (Get-GGFoundWord $shaderPresent))
        if ($anyMissing) { $script:ScriptsNote.ForeColor = $script:ColAmber }
        else { $script:ScriptsNote.ForeColor = $script:ColMuted }
    }
    catch {
        try { Set-GGStatus ('A dashboard read failed: {0}' -f $_.Exception.Message) } catch { }
    }
}

function Update-GGMaintenance {
    try {
        $shaderPath = Join-Path $script:GgosRoot 'shader-cache.ps1'
        $present = Test-GGPath $shaderPath
        try { $script:ShaderButton.Enabled = $present } catch { }
        if ($present) {
            $script:ShaderNote.Text = ('shader-cache.ps1 found under {0} - the button above is enabled.' -f $script:GgosRoot)
            $script:ShaderNote.ForeColor = $script:ColMuted
        }
        else {
            $script:ShaderNote.Text = ('shader-cache.ps1 was not found under {0} - the button is disabled. Re-run the playbook with the Toolkit option enabled (or copy shader-cache.ps1 there) to enable shader cache cleaning.' -f $script:GgosRoot)
            $script:ShaderNote.ForeColor = $script:ColAmber
        }
        $script:GuidanceBox.Text = Get-GGRestoreGuidance
    }
    catch {
        try { $script:GuidanceBox.Text = ('Restore guidance could not be generated: {0}' -f $_.Exception.Message) } catch { }
    }
}

function Update-GGAppsAvailability {
    try {
        $wingetOk = $false
        try { $wingetOk = ($null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue)) } catch { }
        if ($wingetOk) {
            $script:AppsWingetNote.Text = 'winget is available on this system.'
            $script:AppsWingetNote.ForeColor = $script:ColMuted
        }
        else {
            $script:AppsWingetNote.Text = 'winget not available on this system - app installs will not work here.'
            $script:AppsWingetNote.ForeColor = $script:ColAmber
        }
    }
    catch { }
}

# ============================================================================
# 8. Show
# ============================================================================
Update-GGDashboard
Update-GGMaintenance
Update-GGAppsAvailability

try {
    [void]$script:MainForm.ShowDialog()
}
catch {
    try {
        [System.Windows.Forms.MessageBox]::Show(('The Toolkit hit an unexpected error: {0}' -f $_.Exception.Message),
            'GGOS Toolkit', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
    catch { }
}
finally {
    try { $script:MainForm.Dispose() } catch { }
}

exit 0
