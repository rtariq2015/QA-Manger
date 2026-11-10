[CmdletBinding()]param([string]$OutputPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'App/Network.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'App/Workspace.psm1') -Force
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_Network_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:Results=New-Object 'System.Collections.Generic.List[object]';$script:Assertions=0
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS '+$Name)}catch{[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=($_.Exception.Message+' '+$_.ScriptStackTrace)});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
$scanner=[pscustomobject]@{Scanner='CT_Edge';Name='Synthetic Edge';Path='\\SYNTHETIC-SCANNER\QA-Share\ConstancyReports';DriveLetter='K';Username='SyntheticScannerUser'}
Scenario 'UNC authentication targets the share root and preserves the full source folder' {
    $location=Get-QaNetworkLocation $scanner.Path
    Check ($location.ShareRoot -eq '\\SYNTHETIC-SCANNER\QA-Share') 'Correct SMB share root'
    Check ($location.Path -eq $scanner.Path) 'Full reports path preserved'
    foreach($bad in @('K:\Reports','\\server','\\server\share\..\outside',"\\server\share`nfolder")){$caught=$false;try{Get-QaNetworkLocation $bad|Out-Null}catch{$caught=$true};Check $caught 'Malformed path rejected'}
}
Scenario 'Factory placeholders are identified before network access' {
    $baseline=Get-Content (Join-Path $root 'Config/Settings.json') -Raw|ConvertFrom-Json
    $result=Test-QaNetworkAvailability $baseline.Sources[0]
    Check ($result.Status -eq 'NotConfigured') 'Examples are not reported as scanner outages'
    Check ($result.Message -like '*Example connection*') 'Actionable setup explanation'
}
$workspace=Join-Path $testRoot 'Workspace';[void][IO.Directory]::CreateDirectory((Join-Path $workspace 'Config'))
Copy-Item -LiteralPath (Join-Path $root 'Config/Settings.json') -Destination (Join-Path $workspace 'Config/Settings.json')
[void](Initialize-QaWorkspace $workspace)
$profilePath=Join-Path $workspace 'Config/NetworkProfile.local.json'
$profile=[pscustomobject]@{Version=1;Connections=@($scanner)}
$profile|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $profilePath -Encoding UTF8
Scenario 'A local profile replaces examples without changing archive or review settings' {
    $local=Join-Path $workspace 'Config/Settings.local.json'
    $before=Get-Content $local -Raw|ConvertFrom-Json
    $result=Set-QaConnectionProfile -AppRoot $workspace -ProfilePath $profilePath
    $after=Get-Content $local -Raw|ConvertFrom-Json
    Check ($result.Applied -eq 1) 'One matching scanner updated'
    Check ($after.Sources[0].Path -eq $scanner.Path -and $after.Sources[0].Username -eq $scanner.Username) 'Private connection fields applied'
    Check ($after.ArchiveRoot -eq $before.ArchiveRoot -and $after.SetupComplete -eq $before.SetupComplete) 'Archive and setup state preserved'
    Check ([IO.File]::Exists($local+'.before-network-profile.bak')) 'Prior local settings retained'
    Check ((Set-QaConnectionProfile $workspace $profilePath).Applied -eq 0) 'Repeated application makes no change'
}
Scenario 'Automatic profile loading preserves customized connections; explicit apply retains their previous root' {
    $local=Join-Path $workspace 'Config/Settings.local.json';$settings=Get-Content $local -Raw|ConvertFrom-Json
    $settings.Sources[0].Path='\\OTHER-SYNTHETIC\DifferentShare\Reports';$settings.Sources[0].Username='OtherSyntheticUser'
    $settings|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $local -Encoding UTF8
    [void](Initialize-QaWorkspace $workspace)
    $current=Get-Content $local -Raw|ConvertFrom-Json
    Check ($current.Sources[0].Path -eq '\\OTHER-SYNTHETIC\DifferentShare\Reports') 'Customized connection not overwritten automatically'
    [void](Set-QaConnectionProfile $workspace $profilePath -ReplaceExisting)
    $current=Get-Content $local -Raw|ConvertFrom-Json
    Check ($current.Sources[0].Path -eq $scanner.Path -and $current.Sources[0].PreviousPaths -contains '\\OTHER-SYNTHETIC\DifferentShare\Reports') 'Explicit change preserves source alias history'
}
Scenario 'Profiles containing a password are rejected without changing local settings' {
    $local=Join-Path $workspace 'Config/Settings.local.json';$before=(Get-FileHash $local).Hash
    $bad=[pscustomobject]@{Version=1;Connections=@([pscustomobject]@{Scanner='CT_Edge';Path=$scanner.Path;Username='SyntheticUser';Password='Synthetic forbidden field'})}
    $bad|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $profilePath -Encoding UTF8
    $caught=$false;try{Set-QaConnectionProfile $workspace $profilePath|Out-Null}catch{$caught=$true}
    Check ($caught -and (Get-FileHash $local).Hash -eq $before) 'No secret-bearing profile imported'
}
Scenario 'The repair helper updates an existing installation and retains its data and archive choice' {
    $source=Join-Path $testRoot 'NewRelease';$target=Join-Path $testRoot 'ExistingInstall'
    foreach($folder in @($source,$target)){foreach($child in @('App','Config','Data')){[void][IO.Directory]::CreateDirectory((Join-Path $folder $child))}}
    foreach($name in @('Upgrade.ps1','Workspace.psm1','Network.psm1','ApplyNetworkUpdate.ps1')){Copy-Item -LiteralPath (Join-Path $root ('App/'+$name)) -Destination (Join-Path $source ('App/'+$name))}
    foreach($name in @('Start CT QA Manager.cmd','Update CT QA Manager.cmd','User Guide.html')){Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $source $name);Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $target $name)}
    [IO.File]::WriteAllText((Join-Path $target 'App/OldProgram.txt'),'Synthetic old program')
    $settings=Get-Content (Join-Path $root 'Config/Settings.json') -Raw|ConvertFrom-Json;$settings.ArchiveRoot='Keep-This-Archive';$settings.SetupComplete=$true
    $settings|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $target 'Config/Settings.local.json') -Encoding UTF8
    [IO.File]::WriteAllText((Join-Path $target 'Data/review-evidence.txt'),'Synthetic existing evidence')
    $profile|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $source 'Config/NetworkProfile.local.json') -Encoding UTF8
    [void][IO.Directory]::CreateDirectory((Join-Path $source 'Tests'))
    $manifest=@(Get-ChildItem $source -Recurse -File|ForEach-Object{(Get-FileHash $_.FullName).Hash+'  '+$_.FullName.Substring($source.Length+1).Replace('\','/')})
    [IO.File]::WriteAllLines((Join-Path $source 'Tests/Repository-SHA256SUMS.txt'),$manifest)
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $source 'App/ApplyNetworkUpdate.ps1') -TargetFolder $target -SourceFolder $source -NoLaunch > (Join-Path $testRoot 'repair.log') 2>&1
    Check ($LASTEXITCODE -eq 0) 'Repair helper succeeded'
    $saved=Get-Content (Join-Path $target 'Config/Settings.local.json') -Raw|ConvertFrom-Json
    Check ($saved.Sources[0].Path -eq $scanner.Path) 'Private profile applied to the existing installation'
    Check ($saved.ArchiveRoot -eq 'Keep-This-Archive' -and $saved.SetupComplete) 'Archive choice and completed setup preserved'
    Check ([IO.File]::ReadAllText((Join-Path $target 'Data/review-evidence.txt')) -eq 'Synthetic existing evidence') 'Existing data retained'
    Check (@(Get-ChildItem (Join-Path $target 'Backups') -Recurse -Filter OldProgram.txt).Count -eq 1) 'Previous program retained'
}
# Test actual reconnect decisions with synthetic API boundaries: never contact a real scanner.
$module=Get-Module Network
& $module {
    $script:Calls=New-Object 'System.Collections.Generic.List[object]';$script:AuthCode=0;$script:MapCode=0;$script:AccessAfterAuth=0;$script:Occupied=$true
    function script:Initialize-QaNetworkApi {return $true}
    function script:Get-QaDriveAssignment {param($Letter) if($script:Occupied){return [pscustomobject]@{Kind='Occupied';Path='Synthetic unrelated drive'}};return [pscustomobject]@{Kind='Free';Path=''}}
    function script:Test-QaNetworkAvailability {
        param($Scanner)
        if($script:Calls.Count -eq 0){return (Get-QaNetworkFailure $Scanner 5)}
        if($script:AccessAfterAuth -gt 0){return (Get-QaNetworkFailure $Scanner $script:AccessAfterAuth)}
        return (New-QaConnectionResult $Scanner 'Connected' 'Synthetic folder access')
    }
    function script:Invoke-QaNativeConnection {
        param($RemoteName,$LocalName='',$Credential)
        [void]$script:Calls.Add([pscustomobject]@{Remote=$RemoteName;Local=$LocalName})
        if($LocalName){return $script:MapCode};return $script:AuthCode
    }
}
Scenario 'An occupied preferred drive does not block authentication or direct UNC access' {
    $result=& $module {param($s) $script:Calls.Clear();$script:AuthCode=0;$script:AccessAfterAuth=0;$script:Occupied=$true;Invoke-QaReconnectCore $s} $scanner
    $calls=@(& $module {$script:Calls.ToArray()})
    Check ($result.Status -eq 'Connected') ('Folder connected despite occupied drive: '+$result.Message)
    Check ($calls.Count -eq 1 -and $calls[0].Remote -eq '\\SYNTHETIC-SCANNER\QA-Share' -and -not $calls[0].Local) 'Only deviceless share authentication requested'
    Check ($result.Message -like '*left unchanged*') 'Existing mapping preservation visible'
}
Scenario 'A free preferred drive is optional and uses the full reports path' {
    $result=& $module {param($s) $script:Calls.Clear();$script:Occupied=$false;$script:MapCode=0;Invoke-QaReconnectCore $s} $scanner
    $calls=@(& $module {$script:Calls.ToArray()})
    Check ($result.Status -eq 'Connected' -and $calls.Count -eq 2) 'Authentication followed by optional mapping'
    Check ($calls[1].Remote -eq $scanner.Path -and $calls[1].Local -eq 'K:') 'Only the free requested letter mapped'
}
Scenario 'Mapping races cannot invalidate a readable UNC folder' {
    $result=& $module {param($s) $script:Calls.Clear();$script:Occupied=$false;$script:MapCode=85;Invoke-QaReconnectCore $s} $scanner
    Check ($result.Status -eq 'Connected' -and $result.Message -like '*error 85*') 'Drive race explained while report access remains available'
}
Scenario 'A credential conflict still reuses an already readable Windows connection' {
    $result=& $module {param($s) $script:Calls.Clear();$script:AuthCode=1219;$script:AccessAfterAuth=0;Invoke-QaReconnectCore $s} $scanner
    Check ($result.Status -eq 'Connected') 'Existing authorized access reused without disconnecting a Windows session'
}
Scenario 'Authentication, session conflicts and folder permission errors retain their Windows numbers' {
    foreach($code in @(1326,1219,53,67)) {
        $result=& $module {param($s,$c) $script:Calls.Clear();$script:AuthCode=$c;$script:AccessAfterAuth=5;Invoke-QaReconnectCore $s} $scanner $code
        Check ($result.NativeCode -eq $code -and $result.Message -like ('*'+$code+'*')) 'Windows error retained'
    }
    $result=& $module {param($s) $script:Calls.Clear();$script:AuthCode=0;$script:AccessAfterAuth=5;Invoke-QaReconnectCore $s} $scanner
    Check ($result.Status -eq 'Unavailable' -and $result.Message -like '*accepted*denied*') 'Post-authentication ACL denial does not repeatedly request a password'
}
$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Version='4.2.1';Runtime=$PSVersionTable.PSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5);Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Synthetic profiles and mocked native connection boundaries only. Hospital SMB access was not tested.'}
if($OutputPath){$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
Remove-Item -LiteralPath $testRoot -Recurse -Force
if($failed){exit 1}
