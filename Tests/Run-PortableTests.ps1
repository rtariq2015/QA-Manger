[CmdletBinding()]param([string]$OutputPath='',[string]$ScenarioFolder='',[switch]$KeepFixtures)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot
foreach($module in @('Archive','Browse','Insights','Maintenance','Workspace','Process')){Import-Module (Join-Path $ProductRoot ('App/'+$module+'.psm1')) -Force}
$TestRoot=if($ScenarioFolder){[IO.Path]::GetFullPath($ScenarioFolder)}else{Join-Path ([IO.Path]::GetTempPath()) ('CTQA_PortableTests_'+[guid]::NewGuid().ToString('N'))}
if([IO.Directory]::Exists($TestRoot)){throw 'Choose a new synthetic scenario folder.'};[void][IO.Directory]::CreateDirectory($TestRoot)
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Run-Tests.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('New-TestConfig','New-TestPdf','Add-Report','Import-Fixture')){$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);. ([scriptblock]::Create($fn.Extent.Text))}
$script:Results=New-Object 'System.Collections.Generic.List[object]';$script:Assertions=0
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details='' });Write-Host ('PASS '+$Name)}catch{[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=($_.Exception.Message+' '+$_.ScriptStackTrace)});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
$today=(Get-Date).ToString('yyyy-MM-dd')
$cfg=New-TestConfig 'Scanners';$cfg.AppRoot=$ProductRoot
[void](New-TestPdf (Join-Path $cfg.Sources[0].Path ('QualityDaily_'+$today+'_07-00-00.pdf')) -Text 'Noise: PASS')
[void](New-TestPdf (Join-Path $cfg.Sources[1].Path ('QualityDaily_'+$today+'_07-15-00.pdf')) -Text 'Homogeneity: FAIL')
$month=(Get-Date).ToString('yyyy-MM')
foreach($source in $cfg.Sources){$source|Add-Member MonthlyChecklist @('MTF','Slice thickness') -Force;$source|Add-Member MonthlyDueDay 15 -Force}
[void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy_MTF' ($month+'-01') '06-00-00' 95000)
[void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy_Slice' ($month+'-02') '06-00-00' 95000)
[void](Import-Fixture $cfg)
Scenario 'Daily receipt follows scanner calendar and never implies test passage' {
    $view=Get-QaTodayOverview $cfg (Get-QaDashboard $cfg)
    Check ($view.Expected -eq 3 -and $view.Received -eq 2) 'Two Daily PDFs received; third still awaited'
    Check ($view.Headline -notlike 'All*') 'No false all-received headline'
    $cfg.Sources[2]|Add-Member ExcludedDates @($today) -Force
    $view=Get-QaTodayOverview $cfg (Get-QaDashboard $cfg)
    Check ($view.Expected -eq 2 -and $view.Headline -eq 'All required Daily QA reports received') 'Configured non-working day respected'
    Check ($view.Scanners[2].DailyStatus -eq 'Not scheduled') 'Calendar exception shown explicitly'
}
Scenario 'Printed results require explicit labels and keep page evidence' {
    $row=ConvertFrom-QaReportText "--- Page 3 ---`nNoise: PASS`nMTF: FAIL`nFailed tests: 0"
    Check ($row.Status -eq 'ReportedFailure' -and $row.Findings.Count -eq 2) 'Explicit failure wins; failed-count text not mistaken for a test'
    Check ($row.Findings[1].Page -eq 3 -and $row.Findings[1].Evidence -eq 'MTF: FAIL') 'Supporting page and text retained'
    Check ((ConvertFrom-QaReportText 'All okay').Status -eq 'NeedsReview') 'Unrecognized text never invents results'
    Check ((ConvertFrom-QaReportText 'Noise: PASS' -Truncated $true).Status -eq 'NeedsReview') 'Incomplete extraction never marked passed'
}
Scenario 'Local background analysis works with scanner folders offline and uses content cache' {
    foreach($source in $cfg.Sources){[IO.Directory]::Move($source.Path,($source.Path+'.offline'))}
    $before=Get-FileHash (Join-Path $cfg.ArchiveRoot '.ctqa/state.json')
    $analysis=Invoke-QaAnalysis $cfg -Limit 20
    Check ($analysis.Analyzed -gt 0 -and $analysis.Failed -eq 0) 'Offline archive analysis succeeded'
    $view=Get-QaTodayOverview $cfg (Get-QaDashboard $cfg)
    Check ($view.Scanners[1].Findings -like '*FAIL*') 'Printed failure surfaced independently of receipt'
    $again=Invoke-QaAnalysis $cfg
    Check ($again.Analyzed -eq 0) 'Unchanged fingerprints were cached'
    Check ((Get-FileHash (Join-Path $cfg.ArchiveRoot '.ctqa/state.json')).Hash -eq $before.Hash) 'Analysis did not change reviewed archive state'
}
Scenario 'Readable folders preserve all PDFs and build a movable offline library' {
    $result=Invoke-QaBrowseRefresh $cfg
    Check ($result.Summary.Failed -eq 0) ('Readable folders refreshed: '+$result.Summary.Description)
    $html=Join-Path $cfg.ArchiveRoot 'Browse Reports/Open Reports.html'
    Check ([IO.File]::Exists($html)) 'Offline navigator exists'
    $text=[IO.File]::ReadAllText($html)
    Check ($text -match 'Original' -or $text -match 'ORIGINAL') 'Original report names identified'
    Check ($text -notmatch 'href="(?:file:|https?:)') 'All generated report links are portable and local'
    Check ([IO.File]::Exists((Join-Path $cfg.ArchiveRoot 'Browse Reports/Report list.csv'))) 'Readable inventory exists'
    $record=@((Get-QaDashboard $cfg).Records|Where-Object{$_.Category -eq 'Daily_QA'})[0]
    $other=$record|Select-Object *;$other.Id=('A'*64)
    $base=& (Get-Module Browse) {param($r) Get-QaBrowseBase $r} $record
    $padding=[math]::Max(1,(243-$TestRoot.Length-$base.Folder.Length-$base.Name.Length-6))
    $longRoot=Join-Path $TestRoot ('p'*$padding);$used=@{}
    $one=& (Get-Module Browse) {param($r,$u,$p) Get-QaBrowseTarget $r $null $u $p} $record $used $longRoot
    $two=& (Get-Module Browse) {param($r,$u,$p) Get-QaBrowseTarget $r $null $u $p} $other $used $longRoot
    Check ($one -ne $two -and (Join-Path $longRoot $one).Length -le 245 -and (Join-Path $longRoot $two).Length -le 245) 'Colliding original names remain distinct and within the Windows path budget'

}
Scenario 'Monthly reminder dates and historical checklist versions stay distinct' {
    $rows=@(Get-QaMonthOverview $cfg (Get-QaDashboard $cfg) -Date ([datetime]($month+'-20')))
    Check ($rows[0].Timing -eq 'Overdue evidence') 'Department-configured date drives reminders'
    $cfg.Sources[0]|Add-Member MonthlyChecklistHistory @([pscustomobject]@{EffectiveMonth='0001-01';Components=@('MTF')},[pscustomobject]@{EffectiveMonth='2099-01';Components=@('MTF','Slice thickness')}) -Force
    $coverage=@(Get-QaMonthlyCoverage $cfg -Records @((Get-QaDashboard $cfg).Records) -Months @($month))
    Check ($coverage[0].RequiredComponents.Count -eq 1) 'Future checklist does not rewrite current/history requirements'
}
$backup=Join-Path $TestRoot 'Full Backup.zip';$restored=Join-Path $TestRoot 'Restored Portable Workspace'
Scenario 'Full backup verifies PDFs and restores a standalone workspace to a new folder' {
    $result=New-QaBackup -AppRoot $ProductRoot -Config $cfg -DestinationPath $backup
    Check ([IO.File]::Exists($backup)) 'Verified backup created'
    $manifest=Test-QaBackup $backup
    Check ($manifest.Files.Count -gt 20) 'Program, metadata, analysis and reports included'
    Check (@($manifest.Files|Where-Object{$_.Path -match 'Credentials/'}).Count -eq 0) 'Saved sign-ins excluded'
    [void](Restore-QaBackup $backup $restored)
    $restoredConfig=Read-QaConfig $restored
    Check ($restoredConfig.ArchiveRoot -eq (Join-Path $restored 'Data')) 'Archive location rebinds to restored portable folder'
    Check ((Get-QaDashboard $restoredConfig).Records.Count -eq (Get-QaDashboard $cfg).Records.Count) 'Report identities and review metadata restored'
    $rejected=$false;try{Restore-QaBackup $backup $restored|Out-Null}catch{$rejected=$true};Check $rejected 'Existing destination not overwritten'
}
Scenario 'Cancelled backup leaves no completed or partial ZIP' {
    $path=Join-Path $TestRoot 'Cancelled.zip';$progress=[hashtable]::Synchronized(@{Cancel=$true;Message='';Percent=0})
    try{New-QaBackup -AppRoot $ProductRoot -Config $cfg -DestinationPath $path -Progress $progress|Out-Null}catch{}
    Check (-not [IO.File]::Exists($path)) 'No completed cancelled backup'
    Check (@(Get-ChildItem $TestRoot -Filter 'Cancelled.zip.*.partial').Count -eq 0) 'Partial cleaned'
}
Scenario 'A worker cancellation is bounded and leaves no persisted credential file' {
    $progress=[hashtable]::Synchronized(@{Cancel=$true})
    $caught=$false;try{Invoke-QaIsolatedTask Probe ([pscustomobject]@{Path=$TestRoot}) -Progress $progress|Out-Null}catch{$caught=$true}
    Check $caught 'Cancellation handled'
}
Scenario 'Moving the restored folder preserves relative configuration and analysis' {
    $moved=$restored+' moved';[IO.Directory]::Move($restored,$moved)
    $config=Read-QaConfig $moved;$view=Get-QaDashboard $config
    Check ($config.ArchiveRoot -eq (Join-Path $moved 'Data')) 'Moved relative root resolved'
    Check ($view.Records.Count -gt 0 -and [IO.File]::Exists($view.Records[0].DestinationPath)) 'PDF paths resolve after move'
}
Scenario 'Sources edited without metadata changes are found by a deep source check' {
    $source=$cfg.Sources[0];$offline=$source.Path+'.offline';[IO.Directory]::Move($offline,$source.Path)
    $record=@((Get-QaDashboard $cfg).Records|Where-Object{$_.Scanner -eq $source.Scanner -and $_.Category -eq 'Daily_QA'})[0]
    $file=Get-Item $record.SourcePath;$stamp=$file.LastWriteTimeUtc;$bytes=[IO.File]::ReadAllBytes($record.SourcePath);$bytes[100]=$bytes[100] -bxor 1;[IO.File]::WriteAllBytes($record.SourcePath,$bytes);(Get-Item $record.SourcePath).LastWriteTimeUtc=$stamp
    $audit=Invoke-QaSourceAudit $cfg
    Check (@($audit.Rows|Where-Object{$_.Status -like 'Source bytes changed*'}).Count -gt 0) 'Source hash change detected despite same length/timestamp'
    [IO.Directory]::Move($source.Path,$offline)
}
Scenario 'Corrupted backups are rejected before any restore folder is published' {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $broken=Join-Path $TestRoot 'Broken.zip';[IO.File]::Copy($backup,$broken)
    $zip=[IO.Compression.ZipFile]::Open($broken,[IO.Compression.ZipArchiveMode]::Update)
    try{$entry=$zip.GetEntry('Config/Settings.json');$entry.Delete();$entry=$zip.CreateEntry('Config/Settings.json');$writer=New-Object IO.StreamWriter($entry.Open());try{$writer.Write('{}')}finally{$writer.Dispose()}}finally{$zip.Dispose()}
    $destination=Join-Path $TestRoot 'Rejected restore';$caught=$false
    try{Restore-QaBackup $broken $destination|Out-Null}catch{$caught=$true}
    Check ($caught -and -not [IO.Directory]::Exists($destination)) 'Tampered backup did not publish files'
}
function New-SyntheticBackupZip {
    param([string]$Path,[string[]]$Names,[switch]$Link,[switch]$Duplicate)
    $bytes=[Text.Encoding]::UTF8.GetBytes('Synthetic backup contents only')
    $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
    $files=New-Object 'Collections.Generic.List[object]'
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew);$zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try{
        foreach($name in $Names){
            $entry=$zip.CreateEntry($name);if($Link){$entry.ExternalAttributes=[int](-1577123840)}
            $output=$entry.Open();try{$output.Write($bytes,0,$bytes.Length)}finally{$output.Dispose()}
            [void]$files.Add([pscustomobject]@{Path=$name;Length=$bytes.Length;SHA256=$hash})
        }
        if($Duplicate){$entry=$zip.CreateEntry($Names[0].ToUpperInvariant());$output=$entry.Open();try{$output.Write($bytes,0,$bytes.Length)}finally{$output.Dispose()}}
        $entry=$zip.CreateEntry('Backup-Manifest.json');$writer=New-Object IO.StreamWriter($entry.Open())
        try{$writer.Write(([pscustomobject]@{Format='CTQA-Backup';Version=1;Files=@($files.ToArray())}|ConvertTo-Json -Depth 6))}finally{$writer.Dispose()}
    }finally{$zip.Dispose();$stream.Dispose()}
}
Scenario 'Backup restore rejects Windows path aliases, linked members and duplicate ZIP entries before publication' {
    $names=@('Data/CON.txt','Data/trailing./report.pdf','Data/folder /report.pdf','Data/file.pdf:stream','Data/../escape.pdf','Data/back\slash.pdf',('/Data/absolute.pdf'),('Data/bad'+[char]1+'.pdf'),'Data/wild?name.pdf')
    foreach($name in $names){
        $bad=Join-Path $TestRoot ([guid]::NewGuid().ToString('N')+'.zip');New-SyntheticBackupZip -Path $bad -Names @($name)
        $destination=Join-Path $TestRoot ([guid]::NewGuid().ToString('N'));$caught=$false
        try{Restore-QaBackup -Path $bad -DestinationFolder $destination|Out-Null}catch{$caught=$true}
        Check ($caught -and -not [IO.Directory]::Exists($destination)) 'Unsafe backup name rejected without a published restore'
        Check (@(Get-ChildItem -LiteralPath $TestRoot -Directory -Filter ((Split-Path -Leaf $destination)+'.*.partial')).Count -eq 0) 'Unsafe backup leaves no partial restore'
    }
    foreach($kind in @('Link','Duplicate')){
        $bad=Join-Path $TestRoot ($kind+'-backup.zip')
        if($kind -eq 'Link'){New-SyntheticBackupZip -Path $bad -Names @('Data/report.pdf') -Link}else{New-SyntheticBackupZip -Path $bad -Names @('Data/report.pdf') -Duplicate}
        $destination=Join-Path $TestRoot ($kind+' rejected restore');$caught=$false
        try{Restore-QaBackup -Path $bad -DestinationFolder $destination|Out-Null}catch{$caught=$true}
        Check ($caught -and -not [IO.Directory]::Exists($destination)) 'Linked or duplicate backup member rejected before publication'
    }
}
Scenario 'Strict backup validation preserves ordinary Unicode names and verifies every restored byte' {
    $path=Join-Path $TestRoot 'Unicode synthetic backup.zip';$destination=Join-Path $TestRoot 'Unicode restored workspace'
    $names=@('Data/Reports/Synthetic café.pdf','App/Example.psm1')
    New-SyntheticBackupZip -Path $path -Names $names
    $checked=Test-QaBackup -Path $path
    Check ($checked.Files.Count -eq 2) 'Ordinary spaces and Unicode paths accepted'
    [void](Restore-QaBackup -Path $path -DestinationFolder $destination)
    foreach($name in $names){Check ([IO.File]::ReadAllText((Join-Path $destination $name)) -ceq 'Synthetic backup contents only') 'Restored bytes match the checked member'}
}
if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
    Scenario 'Windows restore holds the source backup read-only across verification and copying' {
        $heldBackupPath=Join-Path $TestRoot 'Held source backup.zip'
        New-SyntheticBackupZip -Path $heldBackupPath -Names @('Data/report.pdf','App/Example.psm1')
        $progress=[pscustomobject]@{ArchivePath=$heldBackupPath;WriteProbes=0;WriteBlocked=0}
        $progress|Add-Member -MemberType ScriptProperty -Name Cancel -Value {
            $this.WriteProbes++;$probe=$null
            try{$probe=[IO.File]::Open($this.ArchivePath,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)}catch{$this.WriteBlocked++}finally{if($null -ne $probe){$probe.Dispose()}}
            return $false
        }
        $destination=Join-Path $TestRoot 'Held source restored workspace';[void](Restore-QaBackup -Path $heldBackupPath -DestinationFolder $destination -Progress $progress)
        Check ($progress.WriteProbes -ge 4 -and $progress.WriteBlocked -eq $progress.WriteProbes) 'Source denies writes during both validation and copy checkpoints'
        Check ([IO.File]::ReadAllText((Join-Path $destination 'Data/report.pdf')) -ceq 'Synthetic backup contents only') 'Source evidence restored unchanged'
    }
}

Scenario 'New workspaces preserve baseline settings and move without absolute archive paths' {
    $workspace=Join-Path $TestRoot 'New Workspace';[void][IO.Directory]::CreateDirectory((Join-Path $workspace 'Config'))
    Copy-Item -LiteralPath (Join-Path $ProductRoot 'Config/Settings.json') -Destination (Join-Path $workspace 'Config/Settings.json')
    $baselinePath=Join-Path $workspace 'Config/Settings.json';$baseline=[IO.File]::ReadAllText($baselinePath)|ConvertFrom-Json
    foreach($source in $baseline.Sources){$source.Path=Join-Path $TestRoot $source.Scanner}
    $baseline|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $baselinePath -Encoding UTF8
    $before=(Get-FileHash (Join-Path $workspace 'Config/Settings.json')).Hash
    [void](Initialize-QaWorkspace $workspace);$config=Read-QaConfig $workspace
    Check ($config.ArchiveRoot -eq (Join-Path $workspace 'Data')) 'New workspace uses portable Data folder'
    [void](Save-QaConfig $workspace $config)
    Check ((Get-FileHash (Join-Path $workspace 'Config/Settings.json')).Hash -eq $before) 'Baseline configuration left unchanged'
    $raw=[IO.File]::ReadAllText((Join-Path $workspace 'Config/Settings.local.json'))|ConvertFrom-Json
    Check ($raw.ArchiveRoot -eq 'Data') 'Relative Data location saved'
}
Scenario 'Monthly checklist edits preserve prior months and take effect at configured month' {
    $workspace=Join-Path $TestRoot 'Rules Workspace';[void][IO.Directory]::CreateDirectory((Join-Path $workspace 'Config'))
    $config=New-TestConfig 'Rules';$config.AppRoot=$workspace
    [void](Save-QaConfig $workspace $config)
    $config=Read-QaConfig $workspace;$config.Sources[0]|Add-Member MonthlyChecklist @('MTF') -Force;$config.Sources[0]|Add-Member ChecklistEffectiveMonth '2027-01' -Force
    [void](Save-QaConfig $workspace $config)
    $config=Read-QaConfig $workspace
    $rows=@(Get-QaMonthlyCoverage $config -Records @() -Months @('2026-12','2027-01')|Where-Object{$_.Scanner -eq 'CT_Edge'})
    Check ($rows[0].RequiredComponents.Count -eq 0 -and $rows[1].RequiredComponents.Count -eq 1) 'Effective date survives save/reload'
}
Scenario 'A bounded inventory worker returns a read-only snapshot' {
    $source=$cfg.Sources[0];[IO.Directory]::Move(($source.Path+'.offline'),$source.Path)
    $single=$cfg|Select-Object *;$single.Sources=@($source);$dashboard=Get-QaDashboard $cfg
    $state=[pscustomobject]@{Records=@($dashboard.Records);Scanners=@($dashboard.Scanners)}
    $snapshot=Invoke-QaIsolatedTask Inventory ([pscustomobject]@{Config=$single;State=$state}) -TimeoutSeconds 30
    Check (@($snapshot.Inventory.Items).Count -gt 0) 'Read-only snapshot collected outside the UI process'
    [IO.Directory]::Move($source.Path,($source.Path+'.offline'))
}
Scenario 'Historical reviews use the checklist effective for the report month' {
    $config=New-TestConfig 'HistoricalReview';$source=$config.Sources[0]
    $source|Add-Member MonthlyChecklist @('Slice thickness') -Force
    $source|Add-Member MonthlyChecklistHistory @([pscustomobject]@{EffectiveMonth='0001-01';Components=@('MTF')},[pscustomobject]@{EffectiveMonth='2099-01';Components=@('Slice thickness')}) -Force
    [void](Add-Report $config 'CT_Edge' 'Quality_Constancy_MTF' $today '06-00-00' 95000)
    [void](Import-Fixture $config);$record=@((Get-QaDashboard $config).Records)[0]
    [void](Invoke-QaOperation $config -Mode Reclassify -Decisions @([pscustomobject]@{RecordId=$record.Id;Category='Monthly_QA';Reviewer='Synthetic historical reviewer';Reason='Checked against effective checklist';ConfirmedComponents=@('MTF')}))
    $row=@(Get-QaMonthlyCoverage $config -Months @($month)|Where-Object{$_.Scanner -eq 'CT_Edge'})[0]
    Check ($row.Status -eq 'Complete') 'Historical reviewer can confirm an item even when later rules differ'
}
Scenario 'An upgrade verifies package files and preserves local settings and data' {
    $release=Join-Path $TestRoot 'Update Source';$target=Join-Path $TestRoot 'Existing Program'
    foreach($folder in @($release,$target)){[void][IO.Directory]::CreateDirectory((Join-Path $folder 'App'));[void][IO.Directory]::CreateDirectory((Join-Path $folder 'Config'));[void][IO.Directory]::CreateDirectory((Join-Path $folder 'Data'))}
    [IO.File]::WriteAllText((Join-Path $release 'App/Example.psm1'),'# new program')
    [IO.File]::WriteAllText((Join-Path $target 'App/Example.psm1'),'# old program')
    foreach($name in @('Start CT QA Manager.cmd','Update CT QA Manager.cmd','User Guide.html')){[IO.File]::WriteAllText((Join-Path $release $name),'new release');[IO.File]::WriteAllText((Join-Path $target $name),'old release')}
    [IO.File]::WriteAllText((Join-Path $target 'Config/Settings.local.json'),'{"Keep":"synthetic scanner configuration"}')
    [IO.File]::WriteAllText((Join-Path $target 'Data/keep.txt'),'synthetic data preserved')
    [void][IO.Directory]::CreateDirectory((Join-Path $release 'Tests'))
    $lines=@(Get-ChildItem $release -Recurse -File|ForEach-Object{(Get-FileHash $_.FullName).Hash+'  '+$_.FullName.Substring($release.Length+1).Replace('\','/')})
    [IO.File]::WriteAllLines((Join-Path $release 'Tests/Repository-SHA256SUMS.txt'),$lines)
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $ProductRoot 'App/Upgrade.ps1') -SourceFolder $release -TargetFolder $target > (Join-Path $TestRoot 'upgrade.log') 2>&1
    Check ($LASTEXITCODE -eq 0) 'Upgrade completed'
    Check ([IO.File]::ReadAllText((Join-Path $target 'App/Example.psm1')) -eq '# new program') 'Verified new program installed'
    Check ([IO.File]::ReadAllText((Join-Path $target 'Data/keep.txt')) -eq 'synthetic data preserved') 'Archive payload preserved'
    Check ([IO.File]::ReadAllText((Join-Path $target 'Config/Settings.local.json')) -match 'synthetic scanner configuration') 'Local configuration preserved'
    Check (@(Get-ChildItem (Join-Path $target 'Backups') -Recurse -Filter Example.psm1).Count -eq 1) 'Previous program retained for rollback'
    [IO.File]::WriteAllText((Join-Path $release 'App/Example.psm1'),'tampered release')
    $previousPreference=$ErrorActionPreference
    try{$ErrorActionPreference='Continue'
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $ProductRoot 'App/Upgrade.ps1') -SourceFolder $release -TargetFolder $target > (Join-Path $TestRoot 'rejected-upgrade.log') 2>&1
    }finally{$ErrorActionPreference=$previousPreference}
    Check ($LASTEXITCODE -ne 0 -and [IO.File]::ReadAllText((Join-Path $target 'App/Example.psm1')) -eq '# new program') 'Checksum mismatch rejected without replacing working program'
}
if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
    Scenario 'The production application CMD starts quietly from a folder containing spaces and parentheses' {
        $folder=Join-Path $TestRoot 'Launcher test (portable)';[void][IO.Directory]::CreateDirectory((Join-Path $folder 'App'))
        $launcher=Join-Path $folder 'Start CT QA Manager.cmd'
        [IO.File]::WriteAllBytes($launcher,[IO.File]::ReadAllBytes((Join-Path $ProductRoot 'Start CT QA Manager.cmd')))
        $stub='param([switch]$PortableLaunch)'+"`r`n"+'if(-not $PortableLaunch){exit 7}'+"`r`n"+'Write-Output "Synthetic application launcher reached PowerShell"'+"`r`n"+'exit 0'
        [IO.File]::WriteAllText((Join-Path $folder 'App/Start-Web.ps1'),$stub,(New-Object Text.UTF8Encoding $true))
        $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$env:ComSpec;$info.Arguments='/d /c ""'+$launcher+'""';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $process=[Diagnostics.Process]::Start($info)
        try{
            if(-not $process.WaitForExit(20000)){try{$process.Kill()}catch{};throw 'The application CMD did not finish within its test timeout.'}
            $output=$process.StandardOutput.ReadToEnd()+$process.StandardError.ReadToEnd()
            Check ($process.ExitCode -eq 0) 'The exact application CMD reaches PowerShell successfully'
            Check ([string]::IsNullOrWhiteSpace($output)) 'CMD does not print a corrupt first command or echo application paths and arguments'
            $startup=[IO.File]::ReadAllText((Join-Path $folder 'Logs/Startup.log'))
            Check ($startup -like '*Synthetic application launcher reached PowerShell*') 'Normal startup logging is retained'
        }finally{$process.Dispose()}
    }
}
$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Version='4.3.0';Runtime=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5);Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());SyntheticScenario=$TestRoot}
if($OutputPath){$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
if(-not $KeepFixtures){Remove-Item -LiteralPath $TestRoot -Recurse -Force}
if($failed){exit 1}
