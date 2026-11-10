[CmdletBinding()]param([string]$SourceFolder,[string]$TargetFolder,[switch]$WaitForApp,[switch]$LaunchAfter,[string]$StageRoot,[ValidateRange(1,300)][int]$WaitSeconds=90)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
try {
    # Resolve this only after Windows PowerShell has entered the script body.
    if([string]::IsNullOrWhiteSpace($TargetFolder)){$TargetFolder=Split-Path -Parent $PSScriptRoot}
    if(-not $SourceFolder) {
        Add-Type -AssemblyName System.Windows.Forms
        $picker=New-Object Windows.Forms.FolderBrowserDialog;$picker.Description='Select the complete extracted NEW release folder containing App and Tests.'
        if($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){exit 0};$SourceFolder=$picker.SelectedPath
    }
    $source=[IO.Path]::GetFullPath($SourceFolder);$target=[IO.Path]::GetFullPath($TargetFolder)
    if($source.Equals($target,[StringComparison]::OrdinalIgnoreCase)){throw 'Choose a separate extracted release folder.'}
    if(-not [IO.File]::Exists((Join-Path $target 'Start CT QA Manager.cmd'))){throw 'Choose your existing CT QA Manager program folder.'}
    $session=Join-Path $target 'Data/application.lock';$guard=$null
    if([IO.File]::Exists($session)){
        $deadline=[datetime]::UtcNow.AddSeconds($WaitSeconds)
        while($null -eq $guard){
            try{$guard=[IO.File]::Open($session,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
            catch{if(-not $WaitForApp -or [datetime]::UtcNow -ge $deadline){throw 'CT QA Manager is still open. Close every instance before installing the update.'};Start-Sleep -Milliseconds 250}
        }
    }
    $manifest=Join-Path $source 'Package-SHA256SUMS.txt'
    if(-not [IO.File]::Exists($manifest)){$manifest=Join-Path $source 'Tests/Repository-SHA256SUMS.txt'}
    if(-not [IO.File]::Exists($manifest)){throw 'The new release is missing its package manifest.'}
    $hashes=@{}
    foreach($line in [IO.File]::ReadAllLines($manifest)) {if($line -match '^([0-9a-fA-F]{64})  (.+)$'){$hashes[$Matches[2].Replace('\','/')]=$Matches[1]}}
    $files=@(Get-ChildItem -LiteralPath (Join-Path $source 'App') -Recurse -File)
    $rootNames=@('Start CT QA Manager.cmd','User Guide.html')
    foreach($optional in @('Update CT QA Manager.cmd','Export CT QA Diagnostics.cmd','Package.json','Package-SHA256SUMS.txt')){if([IO.File]::Exists((Join-Path $source $optional))){$rootNames+=@($optional)}}
    if([IO.File]::Exists((Join-Path $source 'Package-SHA256SUMS.txt'))){$hashes['Package-SHA256SUMS.txt']=(Get-FileHash -LiteralPath (Join-Path $source 'Package-SHA256SUMS.txt') -Algorithm SHA256).Hash}
    foreach($name in $rootNames){$files+=@(Get-Item -LiteralPath (Join-Path $source $name))}
    foreach($file in $files) {
        $relative=$file.FullName.Substring($source.TrimEnd('\','/').Length+1).Replace('\','/')
        $ancestor=$file.FullName
        while($ancestor){if(([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Linked update paths are unsupported.'};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
        if(-not $hashes.ContainsKey($relative) -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $hashes[$relative]){throw ('Update file differs from the release manifest: '+$relative)}
    }
    $upgradeClock=[Diagnostics.Stopwatch]::StartNew()
    if([IO.File]::Exists((Join-Path $PSScriptRoot 'Support.psm1'))){Import-Module (Join-Path $PSScriptRoot 'Support.psm1') -Force;Write-QaSupportEvent -AppRoot $target -Operation OfflineUpdate -Outcome Started}
    Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1') -Force
    [void](Initialize-QaWorkspace $target)
    $stage=Join-Path $target ('.update-'+[guid]::NewGuid().ToString('N'))
    $backup=Join-Path (Join-Path $target 'Backups') ('Program-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
    [void][IO.Directory]::CreateDirectory($stage);[void][IO.Directory]::CreateDirectory($backup)
    try {
        Copy-Item -LiteralPath (Join-Path $source 'App') -Destination (Join-Path $stage 'App') -Recurse
        foreach($name in $rootNames){Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $stage $name)}
        foreach($file in $files){$relative=$file.FullName.Substring($source.TrimEnd('\','/').Length+1).Replace('\','/');if((Get-FileHash -LiteralPath (Join-Path $stage $relative) -Algorithm SHA256).Hash -ne $hashes[$relative]){throw 'A staged update checksum differs.'}}
        [IO.Directory]::Move((Join-Path $target 'App'),(Join-Path $backup 'App'))
        try {
            [IO.Directory]::Move((Join-Path $stage 'App'),(Join-Path $target 'App'))
            foreach($name in $rootNames){
                $live=Join-Path $target $name;$saved=Join-Path $backup $name
                if([IO.File]::Exists($live)){[IO.File]::Replace((Join-Path $stage $name),$live,$saved)}else{[IO.File]::Move((Join-Path $stage $name),$live)}
            }
        } catch {
            if([IO.Directory]::Exists((Join-Path $target 'App'))){Remove-Item -LiteralPath (Join-Path $target 'App') -Recurse -Force}
            [IO.Directory]::Move((Join-Path $backup 'App'),(Join-Path $target 'App'))
            foreach($name in $rootNames){$saved=Join-Path $backup $name;if([IO.File]::Exists($saved)){Copy-Item -LiteralPath $saved -Destination (Join-Path $target $name) -Force}}
            throw
        }
        Write-Output ('Program updated. Settings, credentials, data and logs were preserved. Previous App folder: '+$backup)
        Write-Output 'Open the normal launcher. To roll back, close the app and restore the previous App folder.'
        if(Get-Command Write-QaSupportEvent -ErrorAction SilentlyContinue){Write-QaSupportEvent -AppRoot $target -Operation OfflineUpdate -Outcome Completed -DurationMs $upgradeClock.ElapsedMilliseconds -Counts @{Files=$files.Count}}
        if($null -ne $guard){$guard.Dispose();$guard=$null}
        if($LaunchAfter){Start-Process -FilePath (Join-Path $target 'Start CT QA Manager.cmd') -WorkingDirectory $target|Out-Null}
        if($StageRoot){try{Import-Module (Join-Path $PSScriptRoot 'Updates.psm1') -Force;Remove-QaUpdateStage -AppRoot $target -StageRoot $StageRoot}catch{Write-Output 'The checked staging folder can be removed after the update.'}}
    }finally{if([IO.Directory]::Exists($stage)){Remove-Item -LiteralPath $stage -Recurse -Force}}
}catch{$detail='Update stopped. Close the application and check the release folder. '+$_.Exception.Message;if($LaunchAfter){try{Add-Type -AssemblyName PresentationFramework;[void][Windows.MessageBox]::Show($detail,'Update needs attention')}catch{}};Write-Error $detail;exit 1}
finally{if($null -ne (Get-Variable guard -ErrorAction SilentlyContinue) -and $null -ne $guard){$guard.Dispose()}}
