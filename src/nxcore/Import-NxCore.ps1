# NEXTRIX NxCore loader - DOT-SOURCE THIS FILE at your own script scope:
#
#   . (Join-Path $PSScriptRoot 'src\nxcore\Import-NxCore.ps1')
#
# It must be dot-sourced, not called: a function cannot persist dot-sourced
# function definitions to its caller's scope (documented PowerShell behaviour).
# The generated AME playbook uses its own inline dot-source loader and does not
# depend on this file.

$nxcoreRoot = $PSScriptRoot
foreach ($nxModule in 'NxJournal.ps1','NxBuild.ps1','NxHardware.ps1','NxCompat.ps1','NxVerify.ps1','NxRollback.ps1','NxApply.ps1') {
    . (Join-Path $nxcoreRoot $nxModule)
}
# Category engine functions load after the core modules they depend on.
$nxFnDir = Join-Path $nxcoreRoot 'functions'
if (Test-Path $nxFnDir) {
    foreach ($nxFnFile in (Get-ChildItem -Path $nxFnDir -Filter '*.ps1' -File | Sort-Object Name)) {
        . $nxFnFile.FullName
    }
}
