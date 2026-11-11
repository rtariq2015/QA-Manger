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
        Check ($archive.Entries.Count -eq 7) 'Only the seven approved readable and machine diagnostic files are included'
        $activity='';foreach($entry in $archive.Entries){$reader=New-Object IO.StreamReader($entry.Open());try{$text=$reader.ReadToEnd();Check (-not $text.Contains($canary)) 'No injected private field or text in any ZIP entry';if($entry.FullName -eq 'Scrubbed-Activity.jsonl'){$activity=$text}}finally{$reader.Dispose()}}
        $events=@($activity -split '\r?\n'|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
        Check ($events.Count -gt 250) 'Full retained history included beyond the 200-event summary limit'
        $timed=@($events|Where-Object{$_.Operation -eq 'Analysis' -and $_.DurationMs -eq 123})
        Check ($timed.Count -eq 250 -and $timed[0].Counts.Analyzed -eq 20 -and $timed[0].ScannerNumber -eq 1) 'Useful timing, counts and scanner aliases retained'
        Check ($events[0].SchemaVersion -eq 3) 'Events reconstructed into the controlled schema'
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
function New-SyntheticDiagnosticRow {
    param([string[]]$Reasons=@('Unread'),[int]$ScannerNumber=1)
    return [pscustomobject]@{scannerNumber=$ScannerNumber;filingStatus='Pending';category='Monthly';textCacheStatus='Missing';cacheSchemaVersion=0;measurementVersion=0;measurementStatus='NotRead';contentStatus='NotRead';profile='Unknown';reader='Unknown';readMilliseconds=0;readPages=0;totalPages=0;measurementCount=0;contentSupportRevision=0;model='Unknown';sizeBand='Unknown';reasonCodes=$Reasons;id=('c'*64);hash=('d'*64);filename=$canary;path=$workspace;username=$canary;text=$canary;reason=$canary;message=$canary}
}
function Read-SyntheticSupportEntry {
    param($Archive,[string]$Name)
    $entry=$Archive.GetEntry($Name);if($null -eq $entry){throw ('Missing approved support entry: '+$Name)}
    $reader=New-Object IO.StreamReader($entry.Open())
    try{return $reader.ReadToEnd()}finally{$reader.Dispose()}
}
Scenario 'Detailed report diagnoses keep independent reasons and opaque bundle references without private data' {
    $rows=New-Object 'Collections.Generic.List[object]'
    [void]$rows.Add((New-SyntheticDiagnosticRow @('Unread','CacheMissing')))
    $row=New-SyntheticDiagnosticRow @('MeasurementUpgradePending');$row.textCacheStatus='Valid';$row.cacheSchemaVersion=2;$row.measurementStatus='UpgradePending';$row.contentStatus='Recognized';$row.profile='siemens-iec-extended-v1';$row.reader='Standard';$row.readMilliseconds=345;$row.readPages=5;$row.totalPages=5;$row.measurementCount=10;$row.contentSupportRevision=2;$row.model='Edge';$row.sizeBand='Medium';[void]$rows.Add($row)
    $row=New-SyntheticDiagnosticRow @('MissingFormatRule');$row.textCacheStatus='Valid';$row.cacheSchemaVersion=3;$row.measurementVersion=1;$row.measurementStatus='Extracted';$row.contentStatus='Recognized';$row.profile='Extended';[void]$rows.Add($row)
    $row=New-SyntheticDiagnosticRow @('UnknownTemplate','UnsupportedProfile');$row.textCacheStatus='Valid';$row.cacheSchemaVersion=3;$row.measurementVersion=1;$row.measurementStatus='UnsupportedProfile';$row.contentStatus='NeedsReview';[void]$rows.Add($row)
    $row=New-SyntheticDiagnosticRow @('DateConflict','TimeConflict','TypeConflict');$row.contentStatus='NeedsReview';[void]$rows.Add($row)
    [void]$rows.Add((New-SyntheticDiagnosticRow @('UndoRestored')))
    $row=New-SyntheticDiagnosticRow @('ReaderFailed');$row.textCacheStatus='ReadFailed';$row.measurementStatus='ReadError';$row.contentStatus='ReadError';[void]$rows.Add($row)
    [void]$rows.Add((New-SyntheticDiagnosticRow @('IncompleteRead')))
    $row=New-SyntheticDiagnosticRow @('UnsupportedSelectedMetric');$row.textCacheStatus='Valid';$row.cacheSchemaVersion=3;$row.measurementVersion=1;$row.measurementStatus='Extracted';$row.contentStatus='Recognized';$row.profile='Basic';[void]$rows.Add($row)
    $context=@{Reports=@($rows.ToArray());Settings=@{readerMode='Python';autoAnalyze=$true;monitorMinutes=15;supportRevision=2;username=$canary};Work=@([pscustomobject]@{action='Analysis';status='Paused';stage='Paused';completed=18;total=20;failed=0;background=$true;pauseRequested=$true;cancelRequested=$false;id=$canary;message=$canary;path=$workspace});message=$canary}
    $report=Get-QaSupportReport -AppRoot $workspace -Config $config -Dashboard $dashboard -SupportContext $context
    Check ($report.ReportDiagnostics.Count -eq 9) 'All nine independent report observations are retained'
    Check ($report.ReportDiagnostics[0].Reference -ceq 'Report0001' -and $report.ReportDiagnostics[-1].Reference -ceq 'Report0009') 'Bundle references are generated from export order'
    Check ($report.ReportDiagnostics[0].ReasonCodes.Count -eq 2 -and $report.ReportDiagnostics[0].ReasonCodes -ccontains 'Unread' -and $report.ReportDiagnostics[0].ReasonCodes -ccontains 'CacheMissing') 'Derived missing-cache reasons stay separate fixed codes without joined array strings'
    Check (@($report.ReportDiagnostics|Where-Object{$_.Scanner -ceq 'Scanner 1' -and $_.ScannerNumber -eq 1}).Count -eq 9) 'Only configured scanner ordinals identify report sources'
    foreach($reason in @('Unread','CacheMissing','MeasurementUpgradePending','MissingFormatRule','UnknownTemplate','UnsupportedProfile','DateConflict','TimeConflict','TypeConflict','UndoRestored','ReaderFailed','IncompleteRead','UnsupportedSelectedMetric')){Check ([int]$report.DiagnosticCounts.$reason -ge 1) ('Separate diagnostic count retained: '+$reason)}
    Check ($report.ReportDiagnostics[1].Profile -ceq 'Extended') 'Known internal profile identifiers become a fixed generic profile enum'
    Check ($report.ReportDiagnostics[1].CacheSchemaVersion -eq 2 -and $report.ReportDiagnostics[1].MeasurementVersion -eq 0) 'A legacy text cache and missing measurement version remain distinct'
    Check ($report.ReportDiagnostics[1].ReadMilliseconds -eq 345 -and $report.ReportDiagnostics[1].ReadPages -eq 5 -and $report.ReportDiagnostics[1].TotalPages -eq 5 -and $report.ReportDiagnostics[1].MeasurementCount -eq 10) 'Bounded numeric read metadata remains useful without raw measurements'
    Check ($report.ReportDiagnostics[1].Model -ceq 'Edge' -and $report.ReportDiagnostics[1].SizeBand -ceq 'Medium' -and $report.ReportDiagnostics[1].ContentSupportRevision -eq 2) 'Only generic model, size band and content revision are retained'
    Check ($report.ReadSettings.ReaderMode -ceq 'Python' -and $report.ReadSettings.AutoAnalyze -eq $true -and $report.ReadSettings.MonitorMinutes -eq 15 -and $report.ReadSettings.ReadingBatchLimit -eq 20) 'Typed reading settings explain the current scheduling policy'
    $json=$report|ConvertTo-Json -Depth 20
    foreach($private in @($canary,$workspace,('c'*64),('d'*64))){Check (-not $json.Contains($private)) 'Detailed diagnostics omit identifiers, text and private caller fields'}
    $again=Get-QaSupportReport -AppRoot $workspace -Config $config -Dashboard $dashboard -SupportContext ([pscustomobject]$context)
    Check ($again.ReportDiagnostics.Count -eq 9) 'Hashtable and JSON-style contexts are both accepted'
}
Scenario 'Unknown diagnostic and event fields cannot inject text or spreadsheet formulas' {
    $row=New-SyntheticDiagnosticRow @($canary,'=HYPERLINK("https://example.invalid","private")');$row.scannerNumber=$canary;$row.filingStatus=$canary;$row.category=$canary;$row.textCacheStatus=$canary;$row.cacheSchemaVersion=$canary;$row.measurementVersion=$canary;$row.measurementStatus=$canary;$row.contentStatus=$canary;$row.profile=$canary;$row.reader=$canary;$row.readMilliseconds=$canary;$row.readPages=$canary;$row.totalPages=$canary;$row.measurementCount=$canary;$row.contentSupportRevision=$canary;$row.model=$canary;$row.sizeBand=$canary
    $report=Get-QaSupportReport -AppRoot $workspace -Config $config -Dashboard $dashboard -SupportContext @{Reports=@($row);Work=@([pscustomobject]@{action=$canary;status=$canary;stage=$canary;completed=$canary;total=$canary;failed=$canary;message=$canary})}
    $json=$report|ConvertTo-Json -Depth 20
    Check (-not $json.Contains($canary) -and -not $json.Contains('HYPERLINK') -and -not $json.Contains('example.invalid')) 'Invalid enum and counter payloads are never copied'
    Check ($report.ReportDiagnostics[0].FilingStatus -ceq 'Unknown' -and $report.ReportDiagnostics[0].ScannerNumber -eq 0) 'Unknown values use explicit safe defaults'
    Check (@($report.ReportDiagnostics[0].ReasonCodes|Where-Object{$_ -ceq 'Unknown'}).Count -eq 1) 'Unknown reasons become one fixed category'
    Write-QaSupportEvent -AppRoot $workspace -Operation Analysis -Outcome Completed -Stage Analyzing -Reason ReadCompleted -Reader Python -Profile Basic -Counts @{Analyzed=1}
    Write-QaSupportEvent -AppRoot $workspace -Operation Analysis -Outcome Failed -Stage $canary -Reason $canary -Reader $canary -Profile $canary -Counts @{Failed=1;Secret=$canary}
    $events=@(& (Get-Module Support) {param($folder) Get-QaSupportEvents -AppRoot $folder -All} $workspace)
    $json=$events|ConvertTo-Json -Depth 10
    Check (-not $json.Contains($canary)) 'Additional event fields are whitelisted before persistence and export'
    Check (@($events|Where-Object{$_.Stage -ceq 'Analyzing' -and $_.Reason -ceq 'ReadCompleted' -and $_.Reader -ceq 'Python' -and $_.Profile -ceq 'Basic'}).Count -eq 1) 'Useful fixed stage, reason, reader and profile enums survive'
}
Scenario 'Printable diagnostics cap readable sections honestly while machine files retain every report and event' {
    $rows=New-Object 'Collections.Generic.List[object]'
    foreach($n in 1..503){$row=New-SyntheticDiagnosticRow @('Unread');$row.scannerNumber=1;[void]$rows.Add($row)}
    $context=[pscustomobject]@{Reports=@($rows.ToArray());Work=@()}
    $file=Join-Path (Join-Path $workspace 'Logs/Scrubbed') ('ctqa-'+[datetime]::UtcNow.ToString('yyyyMMdd')+'-060.jsonl')
    $lines=New-Object 'Collections.Generic.List[string]'
    foreach($n in 1..507){[void]$lines.Add(([pscustomobject]@{TimeUtc=[datetime]::UtcNow.AddSeconds($n).ToString('o');Operation='Analysis';Outcome='Completed';Stage='Analyzing';Reason='ReadCompleted';Reader='Standard';Profile='Basic';DurationMs=432;ScannerNumber=1;ErrorKind='None';Message=$canary;Counts=[pscustomobject]@{Analyzed=1;Secret=$canary}}|ConvertTo-Json -Depth 6 -Compress))}
    [IO.File]::WriteAllLines($file,[string[]]$lines.ToArray())
    $output=Join-Path $workspace 'Logs/Support/Full-Detailed-Diagnostics.zip'
    [void](Export-QaSupportBundle -AppRoot $workspace -Config $config -Dashboard $dashboard -SupportContext $context -DestinationPath $output)
    $archive=[IO.Compression.ZipFile]::OpenRead($output)
    try{
        $expected=@('SupportReport.html','Support-Summary.json','Report-Diagnostics.csv','Report-Diagnostics.jsonl','Scrubbed-Activity.csv','Scrubbed-Activity.jsonl','READ ME.txt')
        Check ($archive.Entries.Count -eq $expected.Count) 'Bundle includes only the approved readable and machine files'
        foreach($entry in $archive.Entries){Check ($expected -ccontains $entry.FullName) 'No raw or unexpected file enters the ZIP';Check (-not (Read-SyntheticSupportEntry $archive $entry.FullName).Contains($canary)) 'Every ZIP entry is separately checked for private text'}
        $summary=Read-SyntheticSupportEntry $archive 'Support-Summary.json'|ConvertFrom-Json
        Check ($summary.ReportDiagnostics.Count -eq 503 -and $summary.LogRetention.SummaryRecentEventLimit -eq 500) 'Complete per-report JSON and the documented recent-event limit are retained'
        $reportJson=@((Read-SyntheticSupportEntry $archive 'Report-Diagnostics.jsonl') -split '\r?\n'|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
        $reportCsv=@((Read-SyntheticSupportEntry $archive 'Report-Diagnostics.csv')|ConvertFrom-Csv)
        Check ($reportJson.Count -eq 503 -and $reportCsv.Count -eq 503) 'JSONL and CSV both retain all 503 report diagnoses'
        Check ($reportJson[-1].Reference -ceq 'Report0503' -and $reportCsv[-1].Reference -ceq 'Report0503') 'Complete machine files preserve the same bundle-local references'
        $eventJson=@((Read-SyntheticSupportEntry $archive 'Scrubbed-Activity.jsonl') -split '\r?\n'|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
        $eventCsv=@((Read-SyntheticSupportEntry $archive 'Scrubbed-Activity.csv')|ConvertFrom-Csv)
        Check (@($eventJson|Where-Object{$_.DurationMs -eq 432}).Count -eq 507) 'JSONL retains every one of the 507 distinguishing events'
        Check (@($eventCsv|Where-Object{$_.DurationMs -eq '432'}).Count -eq 507 -and $eventCsv.Count -eq $eventJson.Count) 'CSV retains the same full retained timeline'
        $html=Read-SyntheticSupportEntry $archive 'SupportReport.html'
        Check ($html -match '(?i)@media\s+print') 'The detailed overview has a print stylesheet'
        Check ($html -notmatch '(?i)<script\b|\bon[a-z]+\s*=|(?:src|href)\s*=\s*["'']\s*(?:https?:|//)') 'Printable HTML needs no scripts, event handlers or external resources'
        Check ($html -match 'Report0500' -and $html -notmatch 'Report0501|Report0502|Report0503') 'The readable pending-details section stops at 500 rows'
        Check ($html -match '503' -and $html -match '500' -and $html -match '(?i)complete|full|remaining|limit|showing') 'The readable report limit is explicitly described'
        Check ($summary.RecentOperations.Count -eq 500) 'The summary recent timeline is capped independently of machine history'
        Check ($html -match '(?i)500' -and $html -match '(?i)retained|recent|events|timeline') 'The human timeline is labelled as a recent subset'
    }finally{$archive.Dispose()}
}
Scenario 'Standalone HTML exports protect files and sanitize even direct printable-report input' {
    $context=@{Reports=@((New-SyntheticDiagnosticRow @('MissingFormatRule')));Work=@()}
    $report=Get-QaSupportReport -AppRoot $workspace -Config $config -Dashboard $dashboard -SupportContext $context
    $output=Join-Path $workspace 'Logs/Support/Printable-Diagnostics.html'
    Check ((Export-QaSupportHtml -AppRoot $workspace -Config $config -Dashboard $dashboard -SupportContext $context -DestinationPath $output) -eq $output) 'A new printable HTML file can be exported directly'
    $original=[IO.File]::ReadAllText($output)
    Check ($original -match 'Report0001' -and -not $original.Contains($canary)) 'Standalone print output retains safe detail references only'
    $caught=$false;try{Export-QaSupportHtml -AppRoot $workspace -Config $config -Dashboard $dashboard -SupportContext $context -DestinationPath $output|Out-Null}catch{$caught=$true};Check ($caught -and [IO.File]::ReadAllText($output) -ceq $original) 'Existing HTML is never overwritten'
    foreach($name in @('Config/unsafe.html','App/unsafe.html','Data/unsafe.html','Logs/wrong.txt')){$caught=$false;try{Export-QaSupportHtml -AppRoot $workspace -Config $config -Dashboard $dashboard -SupportContext $context -DestinationPath (Join-Path $workspace $name)|Out-Null}catch{$caught=$true};Check $caught 'HTML export protects application settings, code, data and extensions'}
    $report.ApplicationVersion=$canary;$report.Platform=$canary;$report.CurrentOperation=$canary;$report.Privacy=$canary;$report.Scanners[0].Scanner=$canary;$report.ReportDiagnostics[0].Reference=$canary;$report.ReportDiagnostics[0].ReasonCodes=@($canary);$report.ReportDiagnostics[0].ReadMilliseconds=$canary;$report.ReportDiagnostics[0].Model=$canary;$report.ReportDiagnostics[0].SizeBand=$canary;$report|Add-Member PrivateText $canary
    $html=ConvertTo-QaSupportHtml -Report $report
    Check (-not $html.Contains($canary)) 'The public HTML renderer projects safe fields again instead of trusting caller text'
    Check (@(Get-ChildItem (Join-Path $workspace 'Logs/Support') -Filter '*.tmp').Count -eq 0) 'HTML and ZIP failures leave no partial export'
}
Scenario 'Classic diagnostics inspect cached versions without opening or changing PDF content' {
    $pdf=Join-Path $workspace 'Data/private-synthetic.pdf';[IO.File]::WriteAllText($pdf,('%PDF-1.4 '+$canary))
    $privateId='e'*64;$privateHash='f'*64;$info=Get-Item $pdf
    $record=[pscustomobject]@{Scanner=$config.Sources[0].Scanner;Id=$privateId;Hash=$privateHash;Length=$info.Length;ReportDate='2026-11-10';Category='Monthly_QA/Pending_Verification';DestinationPath=$pdf;SourcePath=$canary;OriginalFileName=$canary}
    $saved=[pscustomobject]@{ParserVersion=1;AnalysisCacheSchemaVersion=2;DocumentClassifierVersion=1;Hash=$privateHash;RecordId=$privateId;Status='NeedsReview';Truncated=$false;VerifiedHash=$privateHash;VerifiedLength=$info.Length;VerifiedWriteTicks=$info.LastWriteTimeUtc.Ticks;SavedWriteTicks=$info.LastWriteTimeUtc.Ticks;SavedLength=$info.Length;DocumentClassification=[pscustomobject]@{ClassifierVersion=1;Status='Recognized';ProfileId='siemens-iec-basic-v1';CompleteRead=$true;DateStatus='Consensus';ReportDate='2026-11-10';ReportTime='07:00:00';Reason=$canary};Findings=@([pscustomobject]@{Evidence=$canary});ReaderMessage=$canary}
    $cachePath=Join-Path $config.ArchiveRoot ('.ctqa/analysis/'+$privateHash+'.json');[IO.File]::WriteAllText($cachePath,($saved|ConvertTo-Json -Depth 10))
    $cacheBefore=(Get-FileHash $cachePath).Hash;$pdfBefore=[IO.File]::ReadAllBytes($pdf)
    $localDashboard=[pscustomobject]@{SetupComplete=$true;Records=@($record);Attention=@();Scanners=@()}
    $lock=[IO.File]::Open($pdf,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{$report=Get-QaSupportReport -AppRoot $workspace -Config $config -Dashboard $localDashboard;Check ($report.ReportDiagnostics.Count -eq 1) 'Classic callers get cached per-report diagnostics without browser context';Check ($report.ReportDiagnostics[0].CacheSchemaVersion -eq 2 -and $report.ReportDiagnostics[0].MeasurementVersion -eq 0) 'Classic diagnostics distinguish a legacy cache from missing measurement data'}finally{$lock.Dispose()}
    $json=$report|ConvertTo-Json -Depth 20
    foreach($private in @($canary,$pdf,$privateId,$privateHash)){Check (-not $json.Contains($private)) 'Classic cache details cannot expose report evidence or identity'}
    Check ((Get-FileHash $cachePath).Hash -ceq $cacheBefore -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($pdf)) -ceq [Convert]::ToBase64String($pdfBefore)) 'Export diagnostics leave both cache JSON and PDF bytes unchanged'
    $saved.DocumentClassification.ProfileId='';$saved.DocumentClassification.Status='NeedsReview';$saved.DocumentClassification|Add-Member HasReferenceEvidence $true
    $saved|Add-Member MeasurementsDocument ([pscustomobject]@{MeasurementVersion=1;MeasurementSupportRevision=2;Status='Extracted';Measurements=@([pscustomobject]@{Code='WaterCTNumber';Value='8';Unit='HU'})})
    [IO.File]::WriteAllText($cachePath,($saved|ConvertTo-Json -Depth 10));$referenceCacheHash=(Get-FileHash $cachePath).Hash
    $lock=[IO.File]::Open($pdf,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{$referenceReport=Get-QaSupportReport -AppRoot $workspace -Config $config -Dashboard $localDashboard}finally{$lock.Dispose()}
    Check ($referenceReport.ReportDiagnostics[0].Profile -ceq 'Unknown' -and $referenceReport.ReportDiagnostics[0].MeasurementCount -eq 0 -and $referenceReport.ReportDiagnostics[0].MeasurementStatus -ceq 'ReferenceExcluded' -and $referenceReport.ReportDiagnostics[0].ReasonCodes -ccontains 'ReferenceExcluded') 'Reference body evidence excludes legacy measurements even when its document profile remains unresolved'
    Check ((Get-FileHash $cachePath).Hash -ceq $referenceCacheHash -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($pdf)) -ceq [Convert]::ToBase64String($pdfBefore)) 'Reference diagnostic filtering neither rereads nor rewrites protected document evidence'
}
Scenario 'Additional and Daily metadata, Drive models and the third filing rule remain safely diagnosable' {
    $copy=$config|ConvertTo-Json -Depth 20|ConvertFrom-Json
    $copy.Sources[0]|Add-Member -MemberType NoteProperty -Name ContentProfiles -Value @() -Force
    $additional=New-SyntheticDiagnosticRow @('SupportedProfile');$additional.profile='siemens-iec-additional-v1';$additional.model='Drive'
    $daily=New-SyntheticDiagnosticRow @('SupportedProfile');$daily.profile='siemens-quality-daily-v1';$daily.model='Drive'
    $unknown=New-SyntheticDiagnosticRow @('UnknownTemplate');$unknown.profile=$canary;$unknown.model=$canary
    $context=@{Reports=@($additional,$daily,$unknown);Work=@()}
    $fallback=Get-QaSupportReport -AppRoot $workspace -Config $copy -Dashboard $dashboard -SupportContext $context
    $revision=& (Get-Module Support) { Get-QaContentSupportRevision }
    Check ($fallback.ReadSettings.SupportRevision -eq $revision) 'Absent context revision follows the current pure classifier revision dynamically'
    Check ($fallback.ScannerRules[0].AdditionalRule -ceq 'Auto') 'An absent Additional mapping reflects automatic filing while explicit Ask remains separate'
    Check ($fallback.ReportDiagnostics[0].Profile -ceq 'Additional' -and $fallback.ReportDiagnostics[1].Profile -ceq 'Daily') 'New internal profile identifiers become fixed generic aliases'
    Check ($fallback.ReportDiagnostics[0].Model -ceq 'Drive' -and $fallback.ReportDiagnostics[1].Model -ceq 'Drive' -and $fallback.ReadSettings.SupportedModels -ccontains 'Drive') 'Drive is retained as a generic supported-model enum'
    Check ($fallback.ReportDiagnostics[2].Profile -ceq 'Unknown' -and $fallback.ReportDiagnostics[2].Model -ceq 'Unknown') 'Private profile and model strings become Unknown'
    $copy.Sources[0].ContentProfiles=@([pscustomobject]@{profileId='siemens-iec-basic-v1';category='Daily'},[pscustomobject]@{profileId='siemens-iec-extended-v1';category='Monthly'},[pscustomobject]@{profileId='siemens-iec-additional-v1';category='Monthly';message=$canary},[pscustomobject]@{profileId=$canary;category='Monthly';message=$canary})
    $context.Settings=@{readerMode='Auto';autoAnalyze=$true;monitorMinutes=15;supportRevision=3;message=$canary}
    $explicit=Get-QaSupportReport -AppRoot $workspace -Config $copy -Dashboard $dashboard -SupportContext $context
    Check ($explicit.ReadSettings.SupportRevision -eq 3) 'A supplied revision-three support context is preserved'
    Check ($explicit.ScannerRules[0].BasicRule -ceq 'Daily' -and $explicit.ScannerRules[0].ExtendedRule -ceq 'Monthly' -and $explicit.ScannerRules[0].AdditionalRule -ceq 'Monthly') 'The Additional filing rule is independent of Basic and Extended mappings'
    $html=ConvertTo-QaSupportHtml -Report $explicit
    foreach($heading in @('Basic filing','Extended filing','Additional filing')){Check ($html.Contains('<th>'+$heading+'</th>')) ('Printable configuration labels its own column: '+$heading)}
    Check (-not ($explicit|ConvertTo-Json -Depth 20).Contains($canary) -and -not $html.Contains($canary)) 'New model, profile and rule projections cannot leak private metadata'
    $copy.Sources[0].ContentProfiles=@([pscustomobject]@{profileId='siemens-iec-basic-v1';category='Auto'},[pscustomobject]@{profileId='siemens-iec-extended-v1';category='Ask'},[pscustomobject]@{profileId='siemens-iec-additional-v1';category=''})
    $policies=Get-QaSupportReport -AppRoot $workspace -Config $copy -Dashboard $dashboard -SupportContext $context
    Check ($policies.ScannerRules[0].BasicRule -ceq 'Auto' -and $policies.ScannerRules[0].ExtendedRule -ceq 'Ask' -and $policies.ScannerRules[0].AdditionalRule -ceq 'Auto') 'Automatic, explicit Ask and legacyempty rules stay distinguishable and accurately canonicalized'
    $copy.Sources[0].ContentProfiles=@([pscustomobject]@{profileId='siemens-iec-additional-v1';category=$canary},[pscustomobject]@{profileId=$canary;category='Monthly'})
    $invalid=Get-QaSupportReport -AppRoot $workspace -Config $copy -Dashboard $dashboard -SupportContext $context
    Check ($invalid.ScannerRules[0].AdditionalRule -ceq 'Ask') 'Invalid Additional categories and unknown profile identifiers cannot create an automatic rule'
    Check (-not ($invalid|ConvertTo-Json -Depth 20).Contains($canary) -and -not (ConvertTo-QaSupportHtml -Report $invalid).Contains($canary)) 'Invalid third-rule data remains scrubbed in machine and printable output'
    Write-QaSupportEvent -AppRoot $workspace -Operation PdfRead -Outcome Completed -Stage Analyzing -Reason ReadCompleted -Reader Standard -Profile 'siemens-iec-additional-v1' -DurationMs 876
    Write-QaSupportEvent -AppRoot $workspace -Operation PdfRead -Outcome Completed -Stage Analyzing -Reason ReadCompleted -Reader Standard -Profile 'siemens-quality-daily-v1' -DurationMs 877
    $events=@(& (Get-Module Support) {param($folder) Get-QaSupportEvents -AppRoot $folder -All} $workspace)
    Check (@($events|Where-Object{$_.DurationMs -eq 876 -and $_.Profile -ceq 'Additional'}).Count -eq 1 -and @($events|Where-Object{$_.DurationMs -eq 877 -and $_.Profile -ceq 'Daily'}).Count -eq 1) 'Retained event metadata canonicalizes both new profile aliases'
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

Scenario 'Filing basis and reading state remain separate scrubbed facts across machine and print diagnostics' {
    $waiting=New-SyntheticDiagnosticRow @('AwaitingRead');$waiting|Add-Member filingBasis 'AwaitingRead';$waiting|Add-Member filingState 'WaitingRead';$waiting|Add-Member inferred $false
    $automatic=New-SyntheticDiagnosticRow @('SupportedProfile','NoSupportedTables');$automatic.filingStatus='Automatic';$automatic.textCacheStatus='Valid';$automatic.profile='Basic';$automatic|Add-Member filingBasis 'BasicFormat';$automatic|Add-Member filingState 'Filed';$automatic|Add-Member inferred $true;$automatic|Add-Member measurementSupportRevision 2
    $ask=New-SyntheticDiagnosticRow @('ManualReview');$ask|Add-Member filingBasis 'ManualReview';$ask|Add-Member filingState 'NeedsReview';$ask|Add-Member inferred $false
    $reference=New-SyntheticDiagnosticRow @('ReferenceDocument');$reference.filingStatus='Automatic';$reference.profile='siemens-iec-reference-v1';$reference.measurementStatus='Extracted';$reference.measurementCount=11;$reference|Add-Member filingBasis 'ReferenceDocument';$reference|Add-Member filingState 'Filed';$reference|Add-Member inferred $false
    $context=[pscustomobject]@{reports=@($waiting,$automatic,$ask,$reference)}
    $report=Get-QaSupportReport -AppRoot $workspace -Config $config -Dashboard $dashboard -SupportContext $context
    Check ($report.ReportDiagnostics[0].FilingState -ceq 'WaitingRead' -and $report.ReportDiagnostics[0].FilingBasis -ceq 'AwaitingRead') 'Waiting for automatic reading is distinct from a user decision'
    Check ($report.ReportDiagnostics[1].FilingState -ceq 'Filed' -and $report.ReportDiagnostics[1].FilingBasis -ceq 'BasicFormat' -and $report.ReportDiagnostics[1].Inferred -eq $true) 'Automatically inferred grouping retains its controlled basis'
    Check ($report.ReportDiagnostics[1].MeasurementSupportRevision -eq 2) 'The additive measurement capability revision survives diagnostics without changing schema1'
    Check ($report.ReportDiagnostics[2].FilingState -ceq 'NeedsReview' -and $report.ReportDiagnostics[2].FilingBasis -ceq 'ManualReview') 'An explicit Ask policy remains a separate decision state'
    Check ($report.ReportDiagnostics[3].Profile -ceq 'Reference' -and $report.ReportDiagnostics[3].MeasurementStatus -ceq 'ReferenceExcluded' -and $report.ReportDiagnostics[3].MeasurementCount -eq 0 -and $report.ReportDiagnostics[3].ReasonCodes -ccontains 'ReferenceDocument') 'Reference exclusions keep a fixed profile and reason instead of false current measurements'
    Check ($report.DiagnosticCounts.WaitingRead -eq 1 -and $report.DiagnosticCounts.NeedsReview -eq 1 -and $report.DiagnosticCounts.Filed -eq 2 -and $report.DiagnosticCounts.Inferred -eq 1) 'Reading, review, filed and inferred totals remain independently interpretable'
    $csv=@((& (Get-Module Support) {param($rows) ConvertTo-QaSupportReportCsv -Rows $rows} $report.ReportDiagnostics)|ConvertFrom-Csv)
    Check ($csv[1].FilingBasis -ceq 'BasicFormat' -and $csv[1].FilingState -ceq 'Filed' -and $csv[1].Inferred -ceq 'True' -and $csv[1].MeasurementSupportRevision -eq 2) 'CSV carries all four new controlled columns'
    $html=ConvertTo-QaSupportHtml -Report $report
    Check ($html.Contains('Filing basis: BasicFormat') -and $html.Contains('Measurement support revision 2') -and $html.Contains('ReferenceDocument')) 'The printable report explains inference and reference exclusions'
    $unresolvedReference=New-SyntheticDiagnosticRow @('ReferenceExcluded');$unresolvedReference.measurementStatus='Extracted';$unresolvedReference.measurementCount=8
    $excluded=Get-QaSupportReport -AppRoot $workspace -Config $config -Dashboard $dashboard -SupportContext ([pscustomobject]@{reports=@($unresolvedReference)})
    Check ($excluded.ReportDiagnostics[0].Profile -ceq 'Unknown' -and $excluded.ReportDiagnostics[0].MeasurementStatus -ceq 'ReferenceExcluded' -and $excluded.ReportDiagnostics[0].MeasurementCount -eq 0) 'Unknown reference-evidence context rows cannot retain stale numeric counts'
    $bad=New-SyntheticDiagnosticRow @($canary);$bad|Add-Member filingBasis $canary;$bad|Add-Member filingState $canary;$bad|Add-Member inferred $canary;$bad|Add-Member measurementSupportRevision $canary
    $clean=Get-QaSupportReport -AppRoot $workspace -Config $config -Dashboard $dashboard -SupportContext ([pscustomobject]@{reports=@($bad)})
    Check ($clean.ReportDiagnostics[0].FilingBasis -ceq 'Unknown' -and $clean.ReportDiagnostics[0].Inferred -eq $false -and $clean.ReportDiagnostics[0].MeasurementSupportRevision -eq 0) 'Untrusted basis, boolean and revision inputs reduce to safe typed defaults'
    Check (-not (($clean.ReportDiagnostics|ConvertTo-Json -Depth 10).Contains($canary))) 'New diagnostic fields never pass through private freeform strings'
}

$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Version='5.4.0';Runtime=$PSVersionTable.PSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5);Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Synthetic review grouping, strict diagnostic privacy, per-report reason categories, printable HTML limits, complete machine exports, protected destinations, cached-only classic fallback, safe events and active application lock. Production diagnostic CMD runs on Windows.'}
if($OutputPath){$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
Remove-Item -LiteralPath $testRoot -Recurse -Force
if($failed){exit 1}
