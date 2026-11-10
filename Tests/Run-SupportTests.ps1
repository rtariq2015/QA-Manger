[CmdletBinding()]param([string]$OutputPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'App/Review.psm1') -Force
Import-Module (Join-Path $root 'App/Support.psm1') -Force
Import-Module (Join-Path $root 'App/Workspace.psm1') -Force
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_Support_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:Results=New-Object 'System.Collections.Generic.List[object]';$script:Assertions=0
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS '+$Name)}catch{[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=($_.Exception.Message+' '+$_.ScriptStackTrace)});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
$canary='Synthetic_PRIVATE_CANARY_93842'
$workspace=Join-Path $testRoot ('Existing App With Spaces '+$canary)
[void][IO.Directory]::CreateDirectory((Join-Path $workspace 'Config'))
Copy-Item (Join-Path $root 'Config/Settings.json') (Join-Path $workspace 'Config/Settings.json')
[void](Initialize-QaWorkspace $workspace)
Import-Module (Join-Path $root 'App/Archive.psm1') -Force
$local=Join-Path $workspace 'Config/Settings.local.json'
$seed=Get-Content $local -Raw|ConvertFrom-Json
foreach($source in $seed.Sources){$source.Path=Join-Path $testRoot ('Source '+$source.Scanner);[void][IO.Directory]::CreateDirectory($source.Path)}
$seed|ConvertTo-Json -Depth 12|Set-Content $local -Encoding UTF8
$config=Read-QaConfig -AppRoot $workspace
$config.Sources[0].Name=$canary;$config.Sources[0].Username=$canary;$config.Sources[0].Path=('\\'+$canary+'\'+$canary)
$issues=@();foreach($n in 1..384){$issues+=@([pscustomobject]@{Scanner=$config.Sources[0].Scanner;Type='DailyGap';Message=$canary;Path=$canary;Details=$canary;RecordId=$canary})}
$issues+=@([pscustomobject]@{Scanner=$config.Sources[1].Scanner;Type='MultipleSessions';Message=$canary;Path=$canary})
$hash='a'*64
$records=@([pscustomobject]@{Scanner=$config.Sources[0].Scanner;Category='Daily_QA';ReportDate='2026-11-10';Hash=$hash;OriginalFileName=$canary;SourcePath=$canary;DestinationPath=$canary;Text=$canary;ConfirmedBy=$canary},[pscustomobject]@{Scanner=$config.Sources[0].Scanner;Category=$canary;ReportDate=$canary;Hash=$canary;OriginalFileName=$canary})
$dashboard=[pscustomobject]@{SetupComplete=$true;Records=$records;Attention=$issues;Scanners=@([pscustomobject]@{Scanner=$config.Sources[0].Scanner;Status='Connected';Message=$canary;CheckedUtc=[datetime]::UtcNow.ToString('o')});LastUpdated=$canary}
$connections=@([pscustomobject]@{Scanner=$config.Sources[0].Scanner;Status='CredentialsRequired';NativeCode=1326;Message=$canary;Username=$canary;Password=$canary})
Scenario 'Hundreds of date checks are grouped without deleting or changing a review item' {
    $before=$issues|ConvertTo-Json -Depth 6
    $groups=@(Get-QaReviewGroups -Issues $issues -Sources @($config.Sources))
    Check ($groups.Count -eq 2) 'Two distinct groups'
    Check (($groups|Measure-Object Count -Sum).Sum -eq 385) 'Every underlying finding retained'
    Check ($groups[0].Count -eq 384 -and $groups[0].Category -eq 'Dates') 'Historical dates grouped by scanner and type'
    Check ($groups[0].NextStep -like '*does not prove*') 'Coverage uncertainty is explained'
    Check (($issues|ConvertTo-Json -Depth 6) -ceq $before) 'Source findings unchanged'
}
Scenario 'Information can be filtered separately and all original details remain accessible' {
    $groups=@(Get-QaReviewGroups -Issues $issues -Sources @($config.Sources))
    $dates=@(Select-QaReviewGroups $groups Dates);$info=@(Select-QaReviewGroups $groups Information)
    Check ($dates.Count -eq 1 -and $info.Count -eq 1) 'Independent filters'
    Check ($dates[0].Items.Count -eq 384 -and $info[0].Items.Count -eq 1) 'All raw details accessible'
    Check (@(Select-QaReviewGroups $groups All).Count -eq 2) 'All means all'
    Check (@(Get-QaReviewGroups -Issues @() -Sources @()).Count -eq 0) 'Empty input supported'
}
Scenario 'Shareable diagnostics exclude free text, identifiers, names, paths and secrets' {
    $report=Get-QaSupportReport -AppRoot $workspace -Config $config -Dashboard $dashboard -ConnectionResults $connections -CurrentOperation Analysis
    $text=$report|ConvertTo-Json -Depth 12
    Check (-not $text.Contains($canary)) 'Private canary absent everywhere'
    Check (-not $text.Contains($workspace) -and -not $text.Contains($hash)) 'Paths and report fingerprints omitted'
    Check ($report.ArchiveRecords -eq 2 -and $report.ReviewItems -eq 385) 'Useful aggregate counts retained'
    Check ($report.Scanners[0].Scanner -eq 'Scanner 1') 'Anonymous stable order'
    Check ($report.Scanners[0].Categories.Daily_QA -eq 1 -and $report.Scanners[0].Categories.Other -eq 1) 'Classification distribution retained'
    Check ($report.Scanners[0].LatestNativeCode -eq 1326 -and $report.Scanners[0].LatestReconnectStatus -eq 'CredentialsRequired') 'Native failure preserved without its raw message'
    Check ($report.Scanners[0].EarliestReportDate -eq '2026-11-10') 'Only valid QA date retained'
    Check ($report.LookbackMonths -eq $config.MonthlyLookbackMonths) 'Actual coverage setting retained'
}
Scenario 'Unrecognized status and settings values cannot inject sensitive text into diagnostics' {
    $copy=$config|ConvertTo-Json -Depth 12|ConvertFrom-Json;$copy.Sources[0].DailySchedule=$canary;$copy.Sources[0].ActiveFrom=$canary;$copy.Sources[0].MonthlyDueDay=$canary
    $copyDashboard=$dashboard|ConvertTo-Json -Depth 12|ConvertFrom-Json;$copyDashboard.Scanners[0].Status=$canary;$copyDashboard.Scanners[0].CheckedUtc=$canary;$copyDashboard.Attention+=@([pscustomobject]@{Scanner=$copy.Sources[0].Scanner;Type=$canary;Message=$canary})
    $report=Get-QaSupportReport -AppRoot $workspace -Config $copy -Dashboard $copyDashboard -CurrentOperation $canary
    Check (-not ($report|ConvertTo-Json -Depth 12).Contains($canary)) 'Unknown values replaced with allowed values'
    Check ($report.Scanners[0].DailySchedule -eq 'Unknown' -and $report.Scanners[0].ConnectionAtLastScan -eq 'Unknown') 'Status values constrained'
    Check ($report.Scanners[0].ReviewItemCounts.Other -eq 1) 'Unknown issue counted rather than copied'
    Check ($report.CurrentOperation -eq 'None') 'Operation constrained'
}
Scenario 'PDF analysis diagnostics retain counts without copying extracted evidence' {
    $folder=Join-Path $config.ArchiveRoot '.ctqa/analysis';[void][IO.Directory]::CreateDirectory($folder)
    [pscustomobject]@{Hash=$hash;Status='NeedsReview';Truncated=$true;Findings=@([pscustomobject]@{Evidence=$canary});ReaderMessage=$canary}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $folder ($hash+'.json')) -Encoding UTF8
    $report=Get-QaSupportReport -AppRoot $workspace -Config $config -Dashboard $dashboard
    Check ($report.Scanners[0].PdfAnalysisCounts.NeedsReview -eq 1 -and $report.Scanners[0].PdfAnalysisCounts.Truncated -eq 1) 'Analysis state and incomplete text counted'
    Check ($report.Scanners[0].PdfAnalysisCounts.NotAnalyzed -eq 1) 'Unanalyzed records counted'
    Check (-not ($report|ConvertTo-Json -Depth 12).Contains($canary)) 'Evidence text omitted'
    [IO.File]::WriteAllText((Join-Path $folder ($hash+'.json')),'malformed')
    Check ((Get-QaSupportReport $workspace $config $dashboard).Scanners[0].PdfAnalysisCounts.CacheUnreadable -eq 1) 'Malformed cache is visible without its contents'
}
Scenario 'Diagnostic exports are atomic new JSON files and protect existing application files' {
    $output=Join-Path $workspace 'Logs/Support/Shareable.json'
    Check ((Export-QaSupportReport $workspace $config $dashboard $output) -eq $output) 'Default support location accepted'
    $saved=[IO.File]::ReadAllText($output);Check (-not $saved.Contains($canary)) 'Written report also redacted'
    $caught=$false;try{Export-QaSupportReport $workspace $config $dashboard $output|Out-Null}catch{$caught=$true};Check ($caught -and [IO.File]::ReadAllText($output) -ceq $saved) 'Existing report never overwritten'
    foreach($name in @('Config/replace.json','App/replace.json','Data/replace.json','Logs/replace.txt')){$caught=$false;try{Export-QaSupportReport $workspace $config $dashboard (Join-Path $workspace $name)|Out-Null}catch{$caught=$true};Check $caught 'Code, config, data and wrong extension protected'}
    Check (@(Get-ChildItem (Join-Path $workspace 'Logs') -Recurse -Filter '*.tmp').Count -eq 0) 'No partial export left behind'
}
Scenario 'Safe operation history excludes arbitrary old log content and injected fields' {
    Write-QaSupportEvent -AppRoot $workspace -Operation Reconnect -Outcome Failed -NativeCode 1326
    $log=Join-Path $workspace 'Logs/Support-events.jsonl'
    $row=[pscustomobject]@{TimeUtc=[datetime]::UtcNow.ToString('o');Operation='Analysis';Outcome='Completed';NativeCode=0;Message=$canary;Username=$canary};[IO.File]::AppendAllText($log,($row|ConvertTo-Json -Compress)+[Environment]::NewLine)
    [IO.File]::AppendAllText($log,'not JSON '+$canary+[Environment]::NewLine)
    [IO.File]::WriteAllText((Join-Path $workspace 'Logs/old-raw.log'),$canary)
    $report=Get-QaSupportReport $workspace $config $dashboard
    Check ($report.RecentOperations.Count -eq 2) 'Known structured events retained'
    Check ($report.RecentOperations[0].NativeCode -eq 1326) 'Error code retained'
    Check (-not ($report|ConvertTo-Json -Depth 12).Contains($canary)) 'Arbitrary raw logs and fields omitted'
    $caught=$false;try{Write-QaSupportEvent -AppRoot $workspace -Operation $canary -Outcome Completed}catch{$caught=$true};Check $caught 'Only known operations accepted'
}
Scenario 'Support events rotate, expire and keep legacy raw files separate' {
    $folder=Join-Path $workspace 'Logs/Scrubbed';[void][IO.Directory]::CreateDirectory($folder)
    $legacy=Join-Path $workspace 'Logs/Support-events.jsonl';[IO.File]::WriteAllText($legacy,('x'*270000));$before=(Get-FileHash $legacy).Hash
    $old=Join-Path $folder 'ctqa-20000101.jsonl';[IO.File]::WriteAllText($old,'Synthetic expired log')
    $full=Join-Path $folder ('ctqa-'+[datetime]::UtcNow.ToString('yyyyMMdd')+'.jsonl');[IO.File]::WriteAllText($full,('x'*1050000))
    Write-QaSupportEvent -AppRoot $workspace -Operation Update -Outcome Completed
    Check (-not [IO.File]::Exists($old)) 'Expired owned event file removed'
    Check ((Get-FileHash $legacy).Hash -eq $before) 'Legacy log left unchanged'
    Check (@(Get-ChildItem $folder -Filter '*-001.jsonl').Count -eq 1) 'Full current event file rotated'
    Check ((Get-QaSupportReport $workspace $config $dashboard).RecentOperations.Count -eq 1) 'New event retained after rotation'
    Check ($dashboard.Records.Count -eq 2 -and $issues.Count -eq 385) 'Report data unchanged'
}
Scenario 'Standalone diagnostics work against an installation with an active application lock' {
    [IO.File]::WriteAllText((Join-Path $workspace 'Start CT QA Manager.cmd'),'Synthetic existing launcher')
    $before=(Get-FileHash (Join-Path $workspace 'Config/Settings.local.json')).Hash
    $lock=[IO.File]::Open((Join-Path $workspace 'Data/application.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    try {
        $output=Join-Path $workspace 'Logs/Support/Standalone.json'
        & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $root 'App/ExportDiagnostics.ps1') -AppRoot $workspace -OutputPath $output -NoOpen > (Join-Path $testRoot 'standalone.log') 2>&1
        Check ($LASTEXITCODE -eq 0 -and [IO.File]::Exists($output)) 'Export works while application lock is held'
        Check ((Get-FileHash (Join-Path $workspace 'Config/Settings.local.json')).Hash -eq $before) 'Existing settings unchanged'
        $bundle=Join-Path $workspace 'Logs/Support/Standalone.zip'
        & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $root 'App/ExportDiagnostics.ps1') -AppRoot $workspace -OutputPath $bundle -NoOpen > (Join-Path $testRoot 'bundle.log') 2>&1
        Check ($LASTEXITCODE -eq 0 -and [IO.File]::Exists($bundle)) 'Full scrubbed ZIP also exports while the application is open'

        if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
            $output=Join-Path $workspace 'Logs/Support/Launcher.json';$p=New-Object Diagnostics.Process;$p.StartInfo=New-Object Diagnostics.ProcessStartInfo
            $p.StartInfo.FileName=$env:ComSpec;$p.StartInfo.Arguments='/d /s /c ""'+(Join-Path $root 'Export CT QA Diagnostics.cmd')+'" -AppRoot "'+$workspace+'" -OutputPath "'+$output+'" -NoOpen < nul"';$p.StartInfo.UseShellExecute=$false;$p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
            try{[void]$p.Start();$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync();if(-not $p.WaitForExit(60000)){$p.Kill();throw 'Diagnostic launcher timeout'};Check ($p.ExitCode -eq 0 -and [IO.File]::Exists($output)) ('Production diagnostic CMD launched: '+$o.Result+$e.Result)}finally{$p.Dispose()}
        }
    }finally{$lock.Dispose()}
}
Scenario 'Pending verification includes provisional daily files and clears only on actual confirmation' {
    $record=[pscustomobject]@{Category='Daily_QA';ClassificationBasis='Provisional size hint';ConfirmedBy=''}
    Check (Test-QaReportPending $record) 'Daily hint remains pending in the file list'
    $record.ConfirmedBy='Synthetic authorized reviewer';Check (-not (Test-QaReportPending $record)) 'Reviewed daily type is no longer pending'
    $record.Category='Monthly_QA/Pending_Verification';Check (Test-QaReportPending $record) 'Monthly candidate remains pending'
    $record.Category='Needs_Review';Check (Test-QaReportPending $record) 'Unclassified report is pending'
}
Scenario 'A scrubbed ZIP includes all retained activity and strips injected fields from every entry' {
    $folder=Join-Path $workspace 'Logs/Scrubbed';[void][IO.Directory]::CreateDirectory($folder)
    $file=Join-Path $folder ('ctqa-'+[datetime]::UtcNow.ToString('yyyyMMdd')+'-050.jsonl')
    $lines=New-Object 'System.Collections.Generic.List[string]'
    foreach($n in 1..250){$event=[pscustomobject]@{TimeUtc=[datetime]::UtcNow.AddMilliseconds($n).ToString('o');Operation='Analysis';Outcome='Completed';NativeCode=0;DurationMs=123;ScannerNumber=1;ErrorKind='None';Message=$canary;Password=$canary;Counts=[pscustomobject]@{Analyzed=20;Cached=100;Filename=$canary}};[void]$lines.Add(($event|ConvertTo-Json -Depth 6 -Compress))}
    [IO.File]::WriteAllLines($file,[string[]]$lines.ToArray())
    $output=Join-Path $workspace 'Logs/Support/All-Scrubbed-Logs.zip'
    Check ((Export-QaSupportBundle -AppRoot $workspace -Config $config -Dashboard $dashboard -DestinationPath $output) -eq $output) 'Bundle saved'
    Add-Type -AssemblyName System.IO.Compression.FileSystem;$archive=[IO.Compression.ZipFile]::OpenRead($output)
    try{
        Check ($archive.Entries.Count -eq 3) 'Only summary, scrubbed activity and readme included'
        $activity='';foreach($entry in $archive.Entries){$reader=New-Object IO.StreamReader($entry.Open());try{$text=$reader.ReadToEnd();Check (-not $text.Contains($canary)) 'No injected private field or text in any ZIP entry';if($entry.FullName -eq 'Scrubbed-Activity.jsonl'){$activity=$text}}finally{$reader.Dispose()}}
        $events=@($activity -split '\r?\n'|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
        Check ($events.Count -gt 250) 'Full retained history included beyond the 200-event summary limit'
        $timed=@($events|Where-Object{$_.Operation -eq 'Analysis' -and $_.DurationMs -eq 123})
        Check ($timed.Count -eq 250 -and $timed[0].Counts.Analyzed -eq 20 -and $timed[0].ScannerNumber -eq 1) 'Useful timing, counts and scanner aliases retained'
        Check ($events[0].SchemaVersion -eq 2) 'Events reconstructed into the controlled schema'
    }finally{$archive.Dispose()}
    $caught=$false;try{Export-QaSupportBundle $workspace $config $dashboard $output|Out-Null}catch{$caught=$true};Check $caught 'Existing bundle is never overwritten'
    $caught=$false;try{Export-QaSupportBundle $workspace $config $dashboard (Join-Path $workspace 'Config/unsafe.zip')|Out-Null}catch{$caught=$true};Check $caught 'Bundle destination protects settings'
    Check (@(Get-ChildItem (Join-Path $workspace 'Logs/Support') -Filter '*.tmp').Count -eq 0) 'No partial bundle remains'
}
Scenario 'Earlier activity contributes only recognized dates, operations and numeric counts' {
    $path=Join-Path $config.ArchiveRoot 'Activity.csv'
    @([pscustomobject]@{TimeUtc=[datetime]::UtcNow.ToString('o');Action='Update';Copied=12;Unchanged=3;Verified=0;Failed=1;Details=$canary},[pscustomobject]@{TimeUtc=[datetime]::UtcNow.ToString('o');Action=$canary;Copied=9;Unchanged=0;Verified=0;Failed=0;Details=$canary})|Export-Csv $path -NoTypeInformation -Encoding UTF8
    $report=Get-QaSupportReport $workspace $config $dashboard
    Check (-not ($report|ConvertTo-Json -Depth 12).Contains($canary)) 'Legacy details and unknown action names excluded'
    Check (@($report.RecentOperations|Where-Object{$_.Operation -eq 'Update' -and $_.Counts.Contains('Copied') -and $_.Counts['Copied'] -eq 12}).Count -eq 1) 'Recognized legacy import counts recovered'
    $output=Join-Path $workspace 'Logs/Support/Legacy-scrubbed.zip';[void](Export-QaSupportBundle $workspace $config $dashboard $output)
    $archive=[IO.Compression.ZipFile]::OpenRead($output)
    try{$reader=New-Object IO.StreamReader($archive.GetEntry('Scrubbed-Activity.jsonl').Open());try{$text=$reader.ReadToEnd();Check (-not $text.Contains($canary) -and $text.Contains('"Copied":12')) 'Legacy counts also included safely in the full ZIP'}finally{$reader.Dispose()}}finally{$archive.Dispose()}
}
Scenario 'Error descriptions become safe categories rather than raw strings' {
    Check ((Get-QaSupportErrorKind -NativeCode 1326) -eq 'Authentication') 'Authentication code mapped'
    Check ((Get-QaSupportErrorKind -NativeCode 5) -eq 'AccessDenied') 'Access denial mapped'
    Check ((Get-QaSupportErrorKind -Message ('Timeout '+$canary)) -eq 'Timeout') 'Private description produces a fixed error category'
    Write-QaSupportEvent -AppRoot $workspace -Operation Update -Outcome Failed -DurationMs 200 -ErrorKind $canary -Counts @{Failed=1;Password=$canary}
    $text=Get-QaSupportReport $workspace $config $dashboard|ConvertTo-Json -Depth 12
    Check (-not $text.Contains($canary)) 'Unknown error kind and count fields cannot leak strings'
}

Scenario 'Concurrent program workers keep every structured event without overwriting each other' {
    $scriptPath=Join-Path $testRoot 'ConcurrentLogger.ps1'
    [IO.File]::WriteAllText($scriptPath,'param([string]$ModulePath,[string]$Folder);Import-Module $ModulePath -Force;foreach($n in 1..20){Write-QaSupportEvent -AppRoot $Folder -Operation Settings -Outcome Completed -DurationMs 234 -Counts @{Scanners=3}}')
    $processes=New-Object 'System.Collections.Generic.List[object]'
    try{
        foreach($n in 1..3){$p=New-Object Diagnostics.Process;$p.StartInfo=New-Object Diagnostics.ProcessStartInfo;$p.StartInfo.FileName=(Get-Process -Id $PID).Path;$p.StartInfo.Arguments='-NoProfile -File "'+$scriptPath+'" -ModulePath "'+(Join-Path $root 'App/Support.psm1')+'" -Folder "'+$workspace+'"';$p.StartInfo.UseShellExecute=$false;$p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true;[void]$p.Start();[void]$processes.Add([pscustomobject]@{Process=$p;Output=$p.StandardOutput.ReadToEndAsync();Error=$p.StandardError.ReadToEndAsync()})}
        foreach($job in $processes){if(-not $job.Process.WaitForExit(30000)){$job.Process.Kill();throw 'Concurrent logger timeout'};Check ($job.Process.ExitCode -eq 0) ('Worker completed: '+$job.Output.Result+$job.Error.Result)}
        $events=@(& (Get-Module Support) {param($path) Get-QaSupportEvents -AppRoot $path -All} $workspace)
        Check (@($events|Where-Object{$_.Operation -eq 'Settings' -and $_.DurationMs -eq 234}).Count -eq 60) 'All sixty concurrent events retained'
    }finally{foreach($job in $processes){$job.Process.Dispose()}}
}

Scenario 'A failed PDF read stays cached until the destination changes' {
    Import-Module (Join-Path $root 'App/Insights.psm1') -Force
    $fingerprint='b'*64;$missing=Join-Path $workspace 'Data/missing-synthetic.pdf'
    $record=[pscustomobject]@{Hash=$fingerprint;DestinationPath=$missing;DestinationLastWriteUtc=[datetime]::UtcNow.ToString('o')}
    $cache=[pscustomobject]@{ParserVersion=1;Hash=$fingerprint;Status='ReadError';Truncated=$true;Findings=@();SavedWriteTicks=[IO.File]::GetLastWriteTimeUtc($missing).Ticks;ReaderMessage=$canary}
    $cache|ConvertTo-Json -Depth 6|Set-Content (Join-Path $config.ArchiveRoot ('.ctqa/analysis/'+$fingerprint+'.json')) -Encoding UTF8
    Check ((Get-QaSavedAnalysis $config $record).Status -eq 'ReadError') 'Unchanged missing destination does not enter an automatic retry loop'
    [IO.File]::WriteAllText($missing,'%PDF-1.4 synthetic restored destination')
    Check ($null -eq (Get-QaSavedAnalysis $config $record)) 'Restored or changed destination becomes eligible for a fresh read'
}
Scenario 'Real connection-result handling avoids repeated prompts and remembers only accepted sign-ins' {
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'App/Start.ps1'),[ref]$tokens,[ref]$parseErrors)
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Finish-Connections'},$true)
    Invoke-Expression $definition.Extent.Text
    function Value-Or($Object,[string]$Name,$Default=''){if($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name};return $Default}
    $script:AppRoot=$workspace;$script:Config=$config;$id=[string]$config.Sources[0].Scanner
    $script:ConnectionFeedback=@{};$script:AttemptedCredentials=@{};$script:RememberPending=@{};$script:ReconnectTarget='';$script:AfterReconnect=''
    $script:ScannerEditors=@{};$script:ScannerEditors[$id]=@{ConnectionResult=[pscustomobject]@{Text=''}}
    $script:PromptCalls=0;$script:SaveCalls=0;$script:ReconnectCalls=0;$script:LastNote=''
    $secure=ConvertTo-SecureString 'Synthetic-Test-Only' -AsPlainText -Force;$script:FakeCredential=New-Object Management.Automation.PSCredential($config.Sources[0].Username,$secure)
    function Show-Credentials {param($Name,$Username,$ScannerId,$Failure) $script:PromptCalls++;return $script:FakeCredential}
    function Start-Work {param($Mode,$Credentials,$Plan) $script:ReconnectCalls++}
    function Show-Note {param($Text,$Title,$IsError) $script:LastNote=$Text}
    function Refresh-Dashboard {}
    function Write-QaSupportEvent {param($AppRoot,$Operation,$Outcome,$NativeCode,$DurationMs,$ScannerNumber,$ErrorKind,$Counts)}
    function Set-CredentialStatusLabel {param($Source,$Editor)}
    function Save-QaSavedCredential {param($AppRoot,$ScannerId,$ExpectedPath,$Credential) $script:SaveCalls++}
    $result=[pscustomobject]@{Connections=@([pscustomobject]@{Scanner=$id;Status='CredentialsRequired';NativeCode=1326;Message='Windows error 1326.'})}
    Finish-Connections $result
    Check ($script:PromptCalls -eq 1 -and $script:ReconnectCalls -eq 1) 'First missing credential prompts once and schedules retry'
    $script:AttemptedCredentials[$id]=$true
    Finish-Connections $result
    Check ($script:PromptCalls -eq 1 -and $script:LastNote -like '*1326*') 'Rejected retry shows its error without another automatic prompt'
    $script:RememberPending[$id]=$script:FakeCredential
    Finish-Connections $result
    Check ($script:SaveCalls -eq 0 -and $script:RememberPending.Count -eq 0) 'Rejected credential is not remembered'
    $script:RememberPending[$id]=$script:FakeCredential;$result.Connections[0].Status='Connected';$result.Connections[0].NativeCode=0;$result.Connections[0].Message='Reports folder accessible.'
    Finish-Connections $result
    Check ($script:SaveCalls -eq 1 -and $script:RememberPending.Count -eq 0) 'Accepted credential remembered only after access succeeds'
    Check ($script:ScannerEditors[$id].ConnectionResult.Text -eq 'Reports folder accessible.') 'Latest result is visible beside the scanner'
}

$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Version='4.3.0';Runtime=$PSVersionTable.PSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5);Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Synthetic review grouping, diagnostic privacy, protected destinations, safe events, standalone export and active application lock. Production diagnostic CMD runs on Windows.'}
if($OutputPath){$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
Remove-Item -LiteralPath $testRoot -Recurse -Force
if($failed){exit 1}
