[CmdletBinding()]param([string]$AppRoot,[string]$OutputPath,[switch]$NoOpen)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
try {
    if(-not $AppRoot){Add-Type -AssemblyName System.Windows.Forms;$picker=New-Object Windows.Forms.FolderBrowserDialog;$picker.Description='Select your CURRENT CT QA Manager folder. It may remain open. Reports and passwords are not collected.';if($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){exit 0};$AppRoot=$picker.SelectedPath}
    if(-not [IO.File]::Exists((Join-Path $AppRoot 'Start CT QA Manager.cmd'))){throw 'Select the existing program folder containing Start CT QA Manager.cmd.'}
    Import-Module (Join-Path $PSScriptRoot 'Archive.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Support.psm1') -Force
    $config=Read-QaConfig -AppRoot $AppRoot;$dashboard=Get-QaDashboard -Config $config
    if(-not $OutputPath){Add-Type -AssemblyName PresentationFramework;$dialog=New-Object Microsoft.Win32.SaveFileDialog;$dialog.Filter='Scrubbed support logs (*.zip)|*.zip';$dialog.FileName='CTQA-Support-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'.zip';$folder=Join-Path $AppRoot 'Logs/Support';[void][IO.Directory]::CreateDirectory($folder);$dialog.InitialDirectory=$folder;if(-not $dialog.ShowDialog()){exit 0};$OutputPath=$dialog.FileName}
    if([IO.Path]::GetExtension($OutputPath) -eq '.zip'){$result=Export-QaSupportBundle -AppRoot $AppRoot -Config $config -Dashboard $dashboard -DestinationPath $OutputPath}else{$result=Export-QaSupportReport -AppRoot $AppRoot -Config $config -Dashboard $dashboard -DestinationPath $OutputPath}
    Write-Output ('Shareable support report saved: '+$result)
    Write-Output 'No passwords, network addresses, usernames, PDFs, filenames, raw logs or extracted text were included.'
    if(-not $NoOpen){Start-Process explorer.exe -ArgumentList ('/select,"'+$result+'"')|Out-Null}
}catch{Write-Error ('Diagnostics export stopped. '+$_.Exception.Message);exit 1}
