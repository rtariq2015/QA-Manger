[CmdletBinding()]param([string]$OutputPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'App/Updates.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_Updates_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:Results=New-Object 'System.Collections.Generic.List[object]';$script:Assertions=0
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS '+$Name)}catch{[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=($_.Exception.Message+' '+$_.ScriptStackTrace)});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
$source=Join-Path $testRoot 'New Program With Spaces';$target=Join-Path $testRoot 'Existing Program With Spaces'
foreach($folder in @($source,$target)){foreach($child in @('App','Config','Data','Logs')){[void][IO.Directory]::CreateDirectory((Join-Path $folder $child))}}
foreach($name in @('Upgrade.ps1','Updates.psm1','Workspace.psm1','Network.psm1')){Copy-Item (Join-Path $root ('App/'+$name)) (Join-Path $source ('App/'+$name))}
foreach($name in @('Start.ps1','MainWindow.xaml')){[IO.File]::WriteAllText((Join-Path $source ('App/'+$name)),'Synthetic program fixture')}
foreach($folder in @($source,$target)){foreach($name in @('Start CT QA Manager.cmd','User Guide.html')){Copy-Item (Join-Path $root $name) (Join-Path $folder $name)};Copy-Item (Join-Path $root 'Config/Settings.json') (Join-Path $folder 'Config/Settings.json')}
[IO.File]::WriteAllText((Join-Path $target 'App/PreviousProgram.txt'),'Synthetic prior version')
$settings=Get-Content (Join-Path $target 'Config/Settings.json') -Raw|ConvertFrom-Json;$settings.ArchiveRoot='Data';$settings.SetupComplete=$true
$settings|ConvertTo-Json -Depth 12|Set-Content (Join-Path $target 'Config/Settings.local.json') -Encoding UTF8
[IO.File]::WriteAllText((Join-Path $target 'Data/preserved-report.txt'),'Synthetic saved report')
function Save-Manifest {
    param([string]$Folder)
    $path=Join-Path $Folder 'Package-SHA256SUMS.txt'
    $lines=@(Get-ChildItem $Folder -Recurse -File|Where-Object{$_.FullName -ne $path}|ForEach-Object{(Get-FileHash $_.FullName).Hash+'  '+$_.FullName.Substring($Folder.Length+1).Replace('\','/')})
    [IO.File]::WriteAllLines($path,[string[]]$lines,(New-Object Text.UTF8Encoding($false)))
}
[pscustomobject]@{SchemaVersion=1;Name='CT QA Manager Pro';Version='4.3.0'}|ConvertTo-Json|Set-Content (Join-Path $source 'Package.json') -Encoding UTF8
Save-Manifest $source
$zip=Join-Path $testRoot 'Approved Update.zip';[IO.Compression.ZipFile]::CreateFromDirectory($source,$zip)
Scenario 'A clean offline ZIP is checked in isolation without changing a running installation' {
    $lock=[IO.File]::Open((Join-Path $target 'Data/application.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    try{$plan=New-QaUpdateStage -AppRoot $target -ZipPath $zip;Check ($plan.Version -eq '4.3.0' -and $plan.Files -ge 9) 'Version and complete payload checked';Check ([IO.File]::Exists((Join-Path $plan.SourceFolder 'App/Upgrade.ps1'))) 'Staged updater present';Check ([IO.File]::Exists((Join-Path $target 'App/PreviousProgram.txt'))) 'Live program untouched during preparation';Remove-QaUpdateStage $target $plan.StageRoot;Check (-not [IO.Directory]::Exists($plan.StageRoot)) 'Discarded stage removed'}finally{$lock.Dispose()}
}
Scenario 'A checked staged update preserves settings and data and keeps the previous program' {
    $plan=New-QaUpdateStage $target $zip;$before=(Get-FileHash (Join-Path $target 'Config/Settings.local.json')).Hash
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $plan.SourceFolder 'App/Upgrade.ps1') -SourceFolder $plan.SourceFolder -TargetFolder $target -StageRoot $plan.StageRoot > (Join-Path $testRoot 'install.log') 2>&1
    Check ($LASTEXITCODE -eq 0) 'Clean package updater succeeded without a Tests folder'
    Check ((Get-FileHash (Join-Path $target 'Config/Settings.local.json')).Hash -eq $before) 'Customized settings retained'
    Check ([IO.File]::ReadAllText((Join-Path $target 'Data/preserved-report.txt')) -eq 'Synthetic saved report') 'Data retained'
    Check (@(Get-ChildItem (Join-Path $target 'Backups') -Recurse -Filter PreviousProgram.txt).Count -eq 1) 'Old program retained for rollback'
    Check ([IO.File]::Exists((Join-Path $target 'Package.json')) -and -not [IO.Directory]::Exists($plan.StageRoot)) 'Installed metadata retained and temporary stage removed'
}
Scenario 'An active application prevents installation and is never forcibly terminated' {
    $plan=New-QaUpdateStage $target $zip;$before=(Get-FileHash (Join-Path $target 'App/Upgrade.ps1')).Hash
    $lock=[IO.File]::Open((Join-Path $target 'Data/application.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    try{
        $clock=[Diagnostics.Stopwatch]::StartNew()
        & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $plan.SourceFolder 'App/Upgrade.ps1') -SourceFolder $plan.SourceFolder -TargetFolder $target -WaitForApp -WaitSeconds 1 > (Join-Path $testRoot 'locked.log') 2>&1
        Check ($LASTEXITCODE -ne 0 -and $clock.Elapsed.TotalSeconds -lt 15) 'Lock wait is bounded'
        Check ((Get-FileHash (Join-Path $target 'App/Upgrade.ps1')).Hash -eq $before) 'Live files unchanged while locked'
    }finally{$lock.Dispose();Remove-QaUpdateStage $target $plan.StageRoot}
}
Scenario 'A tampered staged program cannot pass the final pre-install check' {
    $plan=New-QaUpdateStage $target $zip;[IO.File]::AppendAllText((Join-Path $plan.SourceFolder 'App/Start.ps1'),'tampered')
    $caught=$false;try{Test-QaUpdateFolder $plan.SourceFolder|Out-Null}catch{$caught=$true};Check $caught 'Post-preview modification rejected';Remove-QaUpdateStage $target $plan.StageRoot
}
function New-BadZip {
    param([string]$Path,[string]$Name,[string]$Content='synthetic',[switch]$IncludeGood,[switch]$Link)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Create);$archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try{
        if($IncludeGood){foreach($file in @(Get-ChildItem $source -Recurse -File)){$relative=$file.FullName.Substring($source.Length+1).Replace('\','/');$entry=$archive.CreateEntry($relative);$output=$entry.Open();try{$bytes=[IO.File]::ReadAllBytes($file.FullName);$output.Write($bytes,0,$bytes.Length)}finally{$output.Dispose()}}}
        $entry=$archive.CreateEntry($Name);if($Link){$entry.ExternalAttributes=[int](-1577123840)};$writer=New-Object IO.StreamWriter($entry.Open());try{$writer.Write($Content)}finally{$writer.Dispose()}
    }finally{$archive.Dispose();$stream.Dispose()}
}
Scenario 'Traversal, absolute paths, ADS names and Windows path aliases are rejected before extraction' {
    foreach($name in @('../escape.txt','/escape.txt','C:/escape.txt','App/Start.ps1:stream','App/../escape.txt','App/CON.txt','App/trailing./file.txt')){
        $bad=Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.zip');New-BadZip $bad $name
        $caught=$false;try{New-QaUpdateStage $target $bad|Out-Null}catch{$caught=$true};Check $caught 'Unsafe ZIP path rejected'
    }
    Check (-not [IO.File]::Exists((Join-Path $testRoot 'escape.txt'))) 'No traversal file written'
}
Scenario 'Duplicate paths, link entries and extra development files cannot enter a clean update' {
    foreach($kind in @('Duplicate','Link','Development')){
        $bad=Join-Path $testRoot ($kind+'.zip')
        if($kind -eq 'Duplicate'){New-BadZip $bad 'app/Start.ps1' -IncludeGood}elseif($kind -eq 'Link'){New-BadZip $bad 'App/link.txt' -IncludeGood -Link}else{New-BadZip $bad '.github/workflows/unwanted.yml' -IncludeGood}
        $caught=$false;try{New-QaUpdateStage $target $bad|Out-Null}catch{$caught=$true};Check $caught 'Unexpected entry rejected'
    }
    Check (@(Get-ChildItem $target -Directory -Filter '.pending-update-*').Count -eq 0) 'Failed checks leave no staging folders'
}
Scenario 'Malformed metadata and incomplete manifests cannot replace the installed program' {
    $copy=Join-Path $testRoot 'Bad Metadata';Copy-Item $source $copy -Recurse
    [IO.File]::WriteAllText((Join-Path $copy 'Package.json'),'{}');Save-Manifest $copy
    $caught=$false;try{Test-QaUpdateFolder $copy|Out-Null}catch{$caught=$true};Check $caught 'Wrong package identity rejected'
    Copy-Item (Join-Path $source 'Package.json') (Join-Path $copy 'Package.json') -Force
    [IO.File]::WriteAllText((Join-Path $copy 'Package-SHA256SUMS.txt'),'');$caught=$false;try{Test-QaUpdateFolder $copy|Out-Null}catch{$caught=$true};Check $caught 'Incomplete checksum list rejected'
    Check ([IO.File]::Exists((Join-Path $target 'Data/preserved-report.txt'))) 'Saved data remains present'
}
Scenario 'Staging cleanup refuses ordinary user folders and invalid markers' {
    $caught=$false;try{Remove-QaUpdateStage $target $source}catch{$caught=$true};Check ($caught -and [IO.Directory]::Exists($source)) 'Ordinary folder never removed'
    $fake=Join-Path $target ('.pending-update-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fake)
    $caught=$false;try{Remove-QaUpdateStage $target $fake}catch{$caught=$true};Check ($caught -and [IO.Directory]::Exists($fake)) 'Unmarked folder never removed';Remove-Item $fake -Recurse -Force
}
Scenario 'The helper waits for the running app to release its lock and then installs' {
    $plan=New-QaUpdateStage $target $zip
    [IO.File]::WriteAllText((Join-Path $target 'App/WaitingVersion.txt'),'Synthetic version before shutdown')
    $lock=[IO.File]::Open((Join-Path $target 'Data/application.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    $process=New-Object Diagnostics.Process;$process.StartInfo=New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName=(Get-Process -Id $PID).Path
    $process.StartInfo.Arguments='-NoProfile -File "'+(Join-Path $plan.SourceFolder 'App/Upgrade.ps1')+'" -SourceFolder "'+$plan.SourceFolder+'" -TargetFolder "'+$target+'" -WaitForApp -WaitSeconds 5'
    $process.StartInfo.UseShellExecute=$false;$process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
    try{
        [void]$process.Start();$o=$process.StandardOutput.ReadToEndAsync();$e=$process.StandardError.ReadToEndAsync()
        Start-Sleep -Milliseconds 600;$lock.Dispose();$lock=$null
        if(-not $process.WaitForExit(15000)){$process.Kill();throw 'Wait-and-install helper timeout'}
        Check ($process.ExitCode -eq 0) ('Install succeeds after app closes: '+$o.Result+$e.Result)
        Check (-not [IO.File]::Exists((Join-Path $target 'App/WaitingVersion.txt'))) 'New program installed after the lock was released'
        Check (@(Get-ChildItem (Join-Path $target 'Backups') -Recurse -Filter WaitingVersion.txt).Count -eq 1) 'Pre-update program backed up'
    }finally{if($null -ne $lock){$lock.Dispose()};$process.Dispose();Remove-QaUpdateStage $target $plan.StageRoot}
}
if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
    Scenario 'A successful Windows update starts the normal launcher after releasing the lock' {
        $restartSource=Join-Path $testRoot 'Restart Package';Copy-Item $source $restartSource -Recurse
        [IO.File]::WriteAllText((Join-Path $restartSource 'Start CT QA Manager.cmd'),"@echo off`r`necho Synthetic relaunch verified>`"%~dp0Data\restart-sentinel.txt`"`r`n")
        Save-Manifest $restartSource;$restartZip=Join-Path $testRoot 'Restart.zip';[IO.Compression.ZipFile]::CreateFromDirectory($restartSource,$restartZip)
        $plan=New-QaUpdateStage $target $restartZip
        & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $plan.SourceFolder 'App/Upgrade.ps1') -SourceFolder $plan.SourceFolder -TargetFolder $target -WaitForApp -LaunchAfter -StageRoot $plan.StageRoot > (Join-Path $testRoot 'restart.log') 2>&1
        Check ($LASTEXITCODE -eq 0) 'Windows updater exited successfully'
        $deadline=[datetime]::UtcNow.AddSeconds(5);$marker=Join-Path $target 'Data/restart-sentinel.txt'
        while(-not [IO.File]::Exists($marker) -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
        Check ([IO.File]::Exists($marker)) 'Normal launcher invoked after update'
        Check ([IO.File]::Exists((Join-Path $target 'Data/preserved-report.txt'))) 'Existing reports still present after relaunch'
    }
}

$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Version='4.3.0';Runtime=$PSVersionTable.PSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5);Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Offline package validation, isolated staging, lock waits, report and settings preservation, rollback copy, corruption, traversal, duplicate paths, link entries and cleanup safeguards. No downloaded code executed.'}
if($OutputPath){$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
Remove-Item -LiteralPath $testRoot -Recurse -Force
if($failed){exit 1}
