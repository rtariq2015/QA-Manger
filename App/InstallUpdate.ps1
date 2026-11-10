[CmdletBinding()]param([string]$TargetFolder,[switch]$NoLaunch)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
try {
    $source=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $PSScriptRoot 'Updates.psm1') -Force
    [void](Test-QaUpdateFolder -SourceFolder $source)
    if(-not $TargetFolder){Add-Type -AssemblyName System.Windows.Forms;$picker=New-Object Windows.Forms.FolderBrowserDialog;$picker.Description='Select your EXISTING CT QA Manager folder. Close the app before continuing. Your reports, settings and sign-ins will be preserved.';if($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){exit 0};$TargetFolder=$picker.SelectedPath}
    & (Join-Path $PSScriptRoot 'Upgrade.ps1') -SourceFolder $source -TargetFolder $TargetFolder -WaitForApp -LaunchAfter:(-not $NoLaunch)
}catch{Write-Error ('Update stopped. '+$_.Exception.Message);exit 1}
