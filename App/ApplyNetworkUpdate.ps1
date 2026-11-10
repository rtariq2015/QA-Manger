[CmdletBinding()]param([string]$TargetFolder,[string]$SourceFolder=(Split-Path -Parent $PSScriptRoot),[switch]$NoLaunch)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
try {
    if(-not $TargetFolder) {
        Add-Type -AssemblyName System.Windows.Forms
        $picker=New-Object Windows.Forms.FolderBrowserDialog
        $picker.Description='Choose your EXISTING CT QA Manager folder containing Start CT QA Manager.cmd. Close the application first.'
        if($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){exit 0}
        $TargetFolder=$picker.SelectedPath
    }
    $source=[IO.Path]::GetFullPath($SourceFolder).TrimEnd('\','/')
    $target=[IO.Path]::GetFullPath($TargetFolder).TrimEnd('\','/')
    if(-not [IO.File]::Exists((Join-Path $target 'Start CT QA Manager.cmd'))){throw 'Select the actual application folder, not its parent folder.'}
    $profile=Join-Path $source 'Config/NetworkProfile.local.json'
    if(-not [IO.File]::Exists($profile)){throw 'This package has no private connection profile. Enter your scanner paths in Advanced settings.'}
    if(-not $source.Equals($target,[StringComparison]::OrdinalIgnoreCase)) {
        & (Join-Path $source 'App/Upgrade.ps1') -SourceFolder $source -TargetFolder $target
    } else {
        $lock=Join-Path $target 'Data/application.lock'
        if([IO.File]::Exists($lock)){$guard=[IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$guard.Dispose()}
    }
    Import-Module (Join-Path $target 'App/Workspace.psm1') -Force
    [void](Initialize-QaWorkspace $target)
    $result=Set-QaConnectionProfile -AppRoot $target -ProfilePath $profile -ReplaceExisting
    Write-Output $result.Message
    Write-Output 'Existing reports, archive location, reviewer evidence and unrelated drive mappings were preserved.'
    Write-Output 'Use First-Time Setup or Reconnect scanners. Enter passwords only in the secure prompt if Windows access is unavailable.'
    if(-not $NoLaunch){Start-Process -FilePath (Join-Path $target 'Start CT QA Manager.cmd') -WorkingDirectory $target|Out-Null}
} catch {Write-Error ('Network update stopped. Close CT QA Manager and check the selected folder. '+$_.Exception.Message);exit 1}
