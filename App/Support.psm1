# Shareable support data is rebuilt from an allowlist. Never bundle raw logs or reports.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SupportDiagnostics.psm1') -DisableNameChecking -WarningAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot 'ContentClassifier.psm1') -DisableNameChecking -WarningAction SilentlyContinue
$script:Operations=@('Startup','Reconnect','SetupPreview','Preview','Update','Import','Analysis','PdfPreview','PdfRead','BrowseRefresh','Export','SourceAudit','Compatibility','Backup','Restore','Audit','Reclassify','ReclassifyPreview','AdoptLegacy','RetryAnalysis','Shutdown','Settings','Diagnostics','PrintDiagnostics','ReadingScheduler','OfflineUpdate')
$script:Outcomes=@('Started','Completed','Failed','Cancelled')
$script:ErrorKinds=@('None','Authentication','AccessDenied','Network','Timeout','PolicyBlocked','PackageInvalid','FileIO','Unknown')
$script:CountFields=@('Total','NewOrChanged','Unchanged','Pending','Deferred','Copied','Failed','Verified','Analyzed','Cached','Scanners','SavedReports','ReviewItems','Events','Files','AutoReadingEnabled','ReadErrors','Truncated','PrintedPass','PrintedFailure','NeedsReview','Completed','MeasurementPending','Unread','MissingRule','Unsupported','Conflicts','CurrentQueue','MeasurementCount','ReadPages','TotalPages','WaitingRead','Filed','Inferred','CacheHits','CacheMisses','QueuePlanned','QueueCompleted','PlanPasses','SnapshotPasses','LibraryPasses')
$script:Categories=@('Daily_QA','Monthly_QA','Monthly_QA/Pending_Verification','Acceptance_Tests','Needs_Review')
$script:IssueTypes=@('Connection','SourceUnavailable','SourceMissing','CopyFailed','Integrity','Audit','Recovery','Classification','MonthlyReview','DailyGap','DailyReview','CoverageUnknown','MonthlyGap','MonthlyPending','MonthlyComponents','MonthlyComponentsMissing','MonthlyChecklist','ChecklistNotSet','MonthlyChecklistNotSet','DuplicateName','MultipleSessions','Deferred')
function Get-QaSupportValue($Object,[string]$Name,$Default='') {if($null -ne $Object){if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}elseif($null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name}};return $Default}
function Get-QaSupportNumber($Value,[int]$Maximum=2147483647) {$n=0;if([int]::TryParse([string]$Value,[ref]$n) -and $n -ge 0 -and $n -le $Maximum){return $n};return 0}
function Get-QaSupportDate($Value,[switch]$Time) {
    if($Value -is [datetime]){if($Time){return $Value.ToUniversalTime().ToString('o')};return $Value.ToString('yyyy-MM-dd')}
    $s=[string]$Value;$date=[datetime]::MinValue
    if($Time){$offset=[datetimeoffset]::MinValue;if($s -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$' -and [datetimeoffset]::TryParse($s,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$offset)){return $offset.UtcDateTime.ToString('o')}}
    elseif([datetime]::TryParseExact($s,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)){return $date.ToString('yyyy-MM-dd')}
    return ''
}
function Assert-QaSupportDirectPath([string]$Path) {
    $p=[IO.Path]::GetFullPath($Path)
    while($p){if(([IO.File]::Exists($p) -or [IO.Directory]::Exists($p)) -and (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Use a direct local folder for diagnostics, without links or junctions.'};$p=[IO.Path]::GetDirectoryName($p)}
}
function ConvertTo-QaSafeSupportEvent($InputEvent) {
    $operation=[string](Get-QaSupportValue $InputEvent Operation)
    if(-not $operation){
        $legacy=[string](Get-QaSupportValue $InputEvent action)
        $map=@{Analyze='Analysis';AnalyzeBacklog='Analysis';Refresh='Update';Approve='Reclassify';Disapprove='Reclassify';Undo='Reclassify';ApplyProfile='Settings';ScannerSettings='Settings';PrepareUpdate='OfflineUpdate';InstallPreparedUpdate='OfflineUpdate';Audit='Audit';Diagnostics='Diagnostics';PrintDiagnostics='PrintDiagnostics';Settings='Settings';Reconnect='Reconnect';Export='Export';Backup='Backup';Restore='Restore';Browse='BrowseRefresh';Shutdown='Shutdown'}
        if($map.ContainsKey($legacy)){$operation=$map[$legacy]}
    }
    $operation=Get-QaDiagnosticEnum $operation $script:Operations ''
    $outcome=Get-QaDiagnosticEnum (Get-QaSupportValue $InputEvent Outcome) $script:Outcomes ''
    $time=Get-QaSupportDate (Get-QaSupportValue $InputEvent TimeUtc) -Time
    if(-not $operation -or -not $outcome -or -not $time){return $null}
    $kind=Get-QaDiagnosticEnum (Get-QaSupportValue $InputEvent ErrorKind 'None') $script:ErrorKinds
    $counts=[ordered]@{};$incoming=Get-QaSupportValue $InputEvent Counts $null
    foreach($key in $script:CountFields){$value=Get-QaSupportValue $incoming $key $null;if($null -ne $value){$counts[$key]=Get-QaSupportNumber $value}}
    $schema=Get-QaSupportDiagnosticSchema
    return [pscustomobject]@{SchemaVersion=3;TimeUtc=$time;Operation=$operation;Outcome=$outcome;DurationMs=(Get-QaSupportNumber (Get-QaSupportValue $InputEvent DurationMs 0) 604800000);ScannerNumber=(Get-QaSupportNumber (Get-QaSupportValue $InputEvent ScannerNumber 0) 20);NativeCode=(Get-QaSupportNumber (Get-QaSupportValue $InputEvent NativeCode 0) 65535);ErrorKind=$kind;Stage=(Get-QaDiagnosticEnum (Get-QaSupportValue $InputEvent Stage) $schema.Stages);Reason=(Get-QaDiagnosticEnum (Get-QaSupportValue $InputEvent Reason) $schema.EventReasons);Reader=(Get-QaDiagnosticEnum (Get-QaSupportValue $InputEvent Reader) @('Auto','Standard','Python','Legacy','Unknown'));Profile=(Get-QaDiagnosticProfile (Get-QaSupportValue $InputEvent Profile));Counts=$counts}
}
function Get-QaLegacySupportActivity {
    param($Config)
    if($null -eq $Config){return @()}
    try{
        $path=Join-Path $Config.ArchiveRoot 'Activity.csv';Assert-QaSupportDirectPath $path
        if(-not [IO.File]::Exists($path) -or (Get-Item $path).Length -gt 20971520){return @()}
        $events=New-Object 'System.Collections.Generic.List[object]'
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));$reader=New-Object IO.StreamReader($stream)
        try{$csv=$reader.ReadToEnd()}finally{$reader.Dispose()}
        foreach($row in @($csv|ConvertFrom-Csv)){
            $event=ConvertTo-QaSafeSupportEvent ([pscustomobject]@{TimeUtc=(Get-QaSupportValue $row TimeUtc);Operation=[string](Get-QaSupportValue $row Action);Outcome='Completed';ErrorKind='None';Counts=$row})
            if($null -ne $event){[void]$events.Add($event)}
        }
        return @($events.ToArray())
    }catch{return @()}
}
function Get-QaSupportEvents {
    param([string]$AppRoot,[switch]$All,$Config=$null)
    $events=New-Object 'System.Collections.Generic.List[object]';$paths=New-Object 'System.Collections.Generic.List[string]'
    $legacy=Join-Path $AppRoot 'Logs/Support-events.jsonl';if([IO.File]::Exists($legacy)){[void]$paths.Add($legacy)}
    foreach($name in @('Logs/Web/activity.jsonl.previous','Logs/Web/activity.jsonl')){$hostPath=Join-Path $AppRoot $name;if([IO.File]::Exists($hostPath)){[void]$paths.Add($hostPath)}}
    $folder=Join-Path $AppRoot 'Logs/Scrubbed'
    try{Assert-QaSupportDirectPath $folder;if([IO.Directory]::Exists($folder)){foreach($file in @(Get-ChildItem $folder -File|Where-Object Name -match '^ctqa-\d{8}(?:-\d{3})?\.jsonl$'|Sort-Object Name)){[void]$paths.Add($file.FullName)}}}catch{}
    $ordered=@($paths.ToArray());if(-not $All){[array]::Reverse($ordered)}
    foreach($path in $ordered){
        $stream=$null;$reader=$null
        try{
            Assert-QaSupportDirectPath $path;if((Get-Item -LiteralPath $path).Length -gt 2097152){continue}
            $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));$reader=New-Object IO.StreamReader($stream)
            while($null -ne ($line=$reader.ReadLine())){try{$event=ConvertTo-QaSafeSupportEvent ($line|ConvertFrom-Json);if($null -ne $event){[void]$events.Add($event)}}catch{continue}}
        }catch{}finally{if($null -ne $reader){$reader.Dispose()}elseif($null -ne $stream){$stream.Dispose()}}
        if(-not $All -and $events.Count -ge 200){break}
    }
    foreach($event in @(Get-QaLegacySupportActivity $Config)){[void]$events.Add($event)}
    $result=@($events.ToArray()|Sort-Object TimeUtc);if(-not $All){return @($result|Select-Object -Last 200)};return $result
}
function Write-QaSupportEvent {
    [CmdletBinding()]param([string]$AppRoot,[string]$Operation,[ValidateSet('Started','Completed','Failed','Cancelled')][string]$Outcome,[int]$NativeCode=0,[long]$DurationMs=0,[int]$ScannerNumber=0,[string]$ErrorKind='None',$Counts=$null,[string]$Stage='Unknown',[string]$Reason='Unknown',[string]$Reader='Unknown',[string]$Profile='Unknown')
    if($script:Operations -notcontains $Operation){throw 'Unknown support operation.'}
    $canonical=@($script:Operations|Where-Object{$_ -eq $Operation})[0]
    $safeCounts=[ordered]@{};foreach($key in $script:CountFields){if($null -ne $Counts){if($Counts -is [System.Collections.IDictionary]){if($Counts.Contains($key)){$safeCounts[$key]=Get-QaSupportNumber $Counts[$key]}}elseif($null -ne $Counts.PSObject.Properties[$key]){$safeCounts[$key]=Get-QaSupportNumber $Counts.$key}}}
    $event=ConvertTo-QaSafeSupportEvent ([pscustomobject]@{TimeUtc=[datetime]::UtcNow.ToString('o');Operation=$canonical;Outcome=$Outcome;NativeCode=$NativeCode;DurationMs=$DurationMs;ScannerNumber=$ScannerNumber;ErrorKind=$ErrorKind;Stage=$Stage;Reason=$Reason;Reader=$Reader;Profile=$Profile;Counts=[pscustomobject]$safeCounts})
    $mutex=$null;$ownsMutex=$false
    try{
        $sha=[Security.Cryptography.SHA256]::Create();try{$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($AppRoot).ToUpperInvariant())))).Replace('-','').Substring(0,24)}finally{$sha.Dispose()}
        $mutex=New-Object Threading.Mutex($false,('CTQA_ScrubLog_'+$key))
        try{$ownsMutex=$mutex.WaitOne(1000)}catch{$exception=$_.Exception;while($null -ne $exception.InnerException){$exception=$exception.InnerException};if($exception -is [Threading.AbandonedMutexException]){$ownsMutex=$true}else{throw}}
        if(-not $ownsMutex){return}
        $folder=Join-Path $AppRoot 'Logs/Scrubbed';Assert-QaSupportDirectPath $folder;[void][IO.Directory]::CreateDirectory($folder)
        $files=@(Get-ChildItem $folder -File|Where-Object Name -match '^ctqa-\d{8}(?:-\d{3})?\.jsonl$'|Sort-Object Name)
        foreach($file in $files){Assert-QaSupportDirectPath $file.FullName;$date=[datetime]::ParseExact($file.Name.Substring(5,8),'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture);if($date -lt [datetime]::UtcNow.Date.AddDays(-90)){[IO.File]::Delete($file.FullName)}}
        $files=@(Get-ChildItem $folder -File|Where-Object Name -match '^ctqa-\d{8}(?:-\d{3})?\.jsonl$'|Sort-Object Name);$total=[long]0;foreach($file in $files){$total+=$file.Length}
        foreach($file in $files){if($total -lt 52428800){break};$total-=$file.Length;[IO.File]::Delete($file.FullName)}
        $stem='ctqa-'+[datetime]::UtcNow.ToString('yyyyMMdd');$path=Join-Path $folder ($stem+'.jsonl');$sequence=0
        while([IO.File]::Exists($path) -and (Get-Item $path).Length -ge 1048576){$sequence++;if($sequence -gt 999){return};$path=Join-Path $folder ($stem+'-'+$sequence.ToString('000')+'.jsonl')}
        Assert-QaSupportDirectPath $path;[IO.File]::AppendAllText($path,($event|ConvertTo-Json -Depth 5 -Compress)+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
    }catch{}finally{if($null -ne $mutex){if($ownsMutex){$mutex.ReleaseMutex()};$mutex.Dispose()}} # Logging cannot interrupt report work.
}
function Get-QaSupportErrorKind {
    param([string]$Message,[int]$NativeCode=0)
    if($NativeCode -in @(86,1326,1244)){return 'Authentication'};if($NativeCode -eq 5){return 'AccessDenied'}
    if($NativeCode -in @(53,64,67,1219,1231)){return 'Network'}
    if($Message -match '(?i)timed? out|timeout'){return 'Timeout'}
    if($Message -match '(?i)access.*denied|unauthorized'){return 'AccessDenied'}
    if($Message -match '(?i)policy|blocked|language mode'){return 'PolicyBlocked'}
    if($Message -match '(?i)checksum|manifest|package|zip'){return 'PackageInvalid'}
    if($Message -match '(?i)file|folder|directory|disk'){return 'FileIO'}
    if($Message){return 'Unknown'};return 'None'
}

function Get-QaSupportAnalysisCounts {
    param($Config,[object[]]$Records)
    $counts=[ordered]@{NotAnalyzed=0;ReportedPass=0;ReportedFailure=0;NeedsReview=0;ReadError=0;Truncated=0;CacheUnreadable=0}
    $cache=@{}
    foreach($record in $Records){
        $hash=[string](Get-QaSupportValue $record Hash);$status='NotAnalyzed';$truncated=$false
        if($hash -cmatch '^[0-9A-Fa-f]{64}$'){
            if(-not $cache.ContainsKey($hash)){
                $path=Join-Path $Config.ArchiveRoot ('.ctqa/analysis/'+$hash+'.json')
                try{
                    Assert-QaSupportDirectPath $path
                    if([IO.File]::Exists($path)){
                        if((Get-Item -LiteralPath $path).Length -gt 1048576){throw 'Oversized cache'}
                        $saved=[IO.File]::ReadAllText($path)|ConvertFrom-Json
                        $value=[string](Get-QaSupportValue $saved Status)
                        if(@('ReportedPass','ReportedFailure','NeedsReview','ReadError') -ccontains $value -and [string](Get-QaSupportValue $saved Hash) -ceq $hash){$status=$value;$truncated=([string](Get-QaSupportValue $saved Truncated $false) -ceq 'True')}else{$status='CacheUnreadable'}
                    }
                }catch{$status='CacheUnreadable'}
                $cache[$hash]=[pscustomobject]@{Status=$status;Truncated=$truncated}
            }
            $status=$cache[$hash].Status;$truncated=$cache[$hash].Truncated
        }
        $counts[$status]++;if($truncated){$counts.Truncated++}
    }
    return $counts
}

function Get-QaSupportReport {
    [CmdletBinding()]param([string]$AppRoot,$Config,$Dashboard,[object[]]$ConnectionResults=@(),[string]$CurrentOperation='',$SupportContext=$null,[object[]]$RetainedEvents=@())
    $rows=New-Object 'System.Collections.Generic.List[object]';$i=0
    foreach($source in @($Config.Sources)){
        $i++;$id=[string]$source.Scanner;$records=@((Get-QaSupportValue $Dashboard Records @())|Where-Object{[string]$_.Scanner -ceq $id})
        $categories=[ordered]@{};foreach($category in $script:Categories){$categories[$category]=@($records|Where-Object{[string](Get-QaSupportValue $_ Category) -ceq $category}).Count};$categories['Other']=@($records|Where-Object{$script:Categories -cnotcontains [string](Get-QaSupportValue $_ Category)}).Count
        $issues=@((Get-QaSupportValue $Dashboard Attention @())|Where-Object{[string](Get-QaSupportValue $_ Scanner) -ceq $id});$counts=[ordered]@{}
        foreach($type in $script:IssueTypes){$n=@($issues|Where-Object{[string](Get-QaSupportValue $_ Type) -ceq $type}).Count;if($n){$counts[$type]=$n}}
        $other=@($issues|Where-Object{$script:IssueTypes -cnotcontains [string](Get-QaSupportValue $_ Type)}).Count;if($other){$counts['Other']=$other}
        $dates=@($records|ForEach-Object{Get-QaSupportDate (Get-QaSupportValue $_ ReportDate)}|Where-Object{$_}|Sort-Object)
        $status=@((Get-QaSupportValue $Dashboard Scanners @())|Where-Object{[string]$_.Scanner -ceq $id}|Select-Object -First 1)
        $state='Unknown';$checked='';if($status.Count){$state=[string](Get-QaSupportValue $status[0] Status);$checked=Get-QaSupportDate (Get-QaSupportValue $status[0] CheckedUtc) -Time}
        if(@('Connected','Unavailable','Partial','Issues','Unknown') -cnotcontains $state){$state='Unknown'}
        $recent=@($ConnectionResults|Where-Object{[string](Get-QaSupportValue $_ Scanner) -ceq $id}|Select-Object -Last 1);$code=0;$recentStatus='NotRecorded'
        if($recent.Count){$code=Get-QaSupportNumber (Get-QaSupportValue $recent[0] NativeCode 0) 65535;$recentStatus=[string](Get-QaSupportValue $recent[0] Status);if(@('Connected','Unavailable','CredentialsRequired','NotConfigured','Unsupported') -cnotcontains $recentStatus){$recentStatus='Unknown'}}
        $schedule=[string](Get-QaSupportValue $source DailySchedule);if(@('AllDays','Weekdays','Off') -cnotcontains $schedule){$schedule='Unknown'}
        $stored=$false;if($id -cmatch '^[A-Za-z][A-Za-z0-9_]{0,31}$'){$stored=[IO.File]::Exists((Join-Path $AppRoot ('Config/Credentials/'+$id+'.xml')))}
        $first='';$last='';if($dates.Count){$first=$dates[0];$last=$dates[-1]}
        [void]$rows.Add([pscustomobject]@{Scanner=('Scanner '+$i);ConnectionAtLastScan=$state;CheckedUtc=$checked;LatestReconnectStatus=$recentStatus;LatestNativeCode=$code;UsernameConfigured=(-not [string]::IsNullOrWhiteSpace([string](Get-QaSupportValue $source Username)));SavedSignInFilePresent=$stored;SourceUsesUnc=([string]$source.Path).StartsWith('\\');DailySchedule=$schedule;ActiveFrom=(Get-QaSupportDate (Get-QaSupportValue $source ActiveFrom));DailyExceptionCount=@(Get-QaSupportValue $source ExcludedDates @()).Count;MonthlyExpected=[bool](Get-QaSupportValue $source ExpectedMonthly $false);MonthlyChecklistItemCount=@(Get-QaSupportValue $source MonthlyChecklist @()).Count;MonthlyDueDay=(Get-QaSupportNumber (Get-QaSupportValue $source MonthlyDueDay 0) 31);SavedReports=$records.Count;Categories=$categories;PdfAnalysisCounts=(Get-QaSupportAnalysisCounts -Config $Config -Records $records);PdfAnalysisCountsSource='Historical cached observations; current per-report diagnostics are separate.';EarliestReportDate=$first;LatestReportDate=$last;ReviewItemCounts=$counts})
    }
    $mode='None';if($script:Operations -ccontains $CurrentOperation){$mode=$CurrentOperation}
    $diagnostics=@();$diagnosticSource='CachedArchive'
    if($null -ne $SupportContext -and $null -ne (Get-QaSupportValue $SupportContext Reports $null)){$diagnostics=@(ConvertTo-QaSupportDiagnosticRows -Rows @(Get-QaSupportValue $SupportContext Reports @()));$diagnosticSource='WebContext'}else{$diagnostics=@(Get-QaSupportCachedDiagnosticRows -Config $Config -Dashboard $Dashboard)}
    $work=@(ConvertTo-QaSupportWorkRows -Rows @(Get-QaSupportValue $SupportContext Work @()))
    $events=New-Object 'Collections.Generic.List[object]'
    $incomingEvents=if($PSBoundParameters.ContainsKey('RetainedEvents')){@($RetainedEvents)}else{@(Get-QaSupportEvents -AppRoot $AppRoot -All -Config $Config)}
    foreach($event in $incomingEvents){$safe=ConvertTo-QaSafeSupportEvent $event;if($null -ne $safe){[void]$events.Add($safe)}}
    $eventRows=@($events.ToArray()|Sort-Object TimeUtc)
    $settingsInput=Get-QaSupportValue $SupportContext Settings $null
    $readerMode=Get-QaDiagnosticEnum (Get-QaSupportValue $settingsInput readerMode (Get-QaSupportValue $Config PdfReaderMode 'Auto')) @('Auto','Python','Standard') 'Auto'
    $autoValue=Get-QaSupportValue $settingsInput autoAnalyze (Get-QaSupportValue $Config AutoAnalyze $false)
    $readSettings=[pscustomobject]@{ReaderMode=$readerMode;AutoAnalyze=($autoValue -is [bool] -and $autoValue);MonitorMinutes=(Get-QaSupportNumber (Get-QaSupportValue $settingsInput monitorMinutes (Get-QaSupportValue $Config MonitorMinutes 0)) 1440);ReadingBatchLimit=20;SupportRevision=(Get-QaSupportNumber (Get-QaSupportValue $settingsInput supportRevision (Get-QaContentSupportRevision)) 99);SupportedModels=@('Edge','Flash','Drive');ClassificationScope='Supported manufacturer report bodies and consistent dates; automatic inferred filing remains separate from clinical QA results.'}
    $scannerRules=New-Object 'Collections.Generic.List[object]';$ordinal=0
    foreach($source in @($Config.Sources)){$ordinal++;$basic='Auto';$extended='Auto';$additional='Auto';foreach($rule in @(Get-QaSupportValue $source ContentProfiles @())){$profile=[string](Get-QaSupportValue $rule profileId);$rawCategory=Get-QaSupportValue $rule category;$category=if($rawCategory -is [string] -and -not $rawCategory){'Auto'}else{Get-QaDiagnosticEnum $rawCategory @('Auto','Ask','Daily','Monthly','Other') 'Ask'};if($profile -ceq 'siemens-iec-basic-v1'){$basic=$category}elseif($profile -ceq 'siemens-iec-extended-v1'){$extended=$category}elseif($profile -ceq 'siemens-iec-additional-v1'){$additional=$category}};[void]$scannerRules.Add([pscustomobject]@{Scanner=('Scanner '+$ordinal);ScannerNumber=$ordinal;BasicRule=$basic;ExtendedRule=$extended;AdditionalRule=$additional})}
    return [pscustomobject]@{SchemaVersion=2;ApplicationVersion='5.4.0';CreatedUtc=[datetime]::UtcNow.ToString('o');PowerShellVersion=$PSVersionTable.PSVersion.ToString();Platform=$(if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Windows'}else{'Other'});LanguageMode=[string]$ExecutionContext.SessionState.LanguageMode;Process64Bit=[Environment]::Is64BitProcess;SetupComplete=[bool](Get-QaSupportValue $Dashboard SetupComplete $false);CurrentOperation=$mode;LookbackDays=(Get-QaSupportNumber (Get-QaSupportValue $Config LookbackDays 0) 36500);LookbackMonths=(Get-QaSupportNumber (Get-QaSupportValue $Config MonthlyLookbackMonths 0) 1200);MonitorMinutes=(Get-QaSupportNumber (Get-QaSupportValue $Config MonitorMinutes 0) 1440);ArchiveRecords=@(Get-QaSupportValue $Dashboard Records @()).Count;ReviewItems=@(Get-QaSupportValue $Dashboard Attention @()).Count;Scanners=@($rows.ToArray());RecentOperations=@($eventRows|Select-Object -Last 500);ReportDiagnostics=$diagnostics;DiagnosticCounts=(Get-QaSupportDiagnosticCounts $diagnostics);DiagnosticSource=$diagnosticSource;WorkState=$work;ReadSettings=$readSettings;ScannerRules=@($scannerRules.ToArray());EventHistory=[pscustomobject]@{RetainedEvents=$eventRows.Count;TimelineLimit=500;Scope='Retained allowlisted activity only. Worker and host events can describe nested stages of the same action; they are not unique clinical QA sessions.'};LogRetention=[pscustomobject]@{Days=90;MaximumMegabytes=50;SummaryRecentEventLimit=500;BundleIncludesAllRetainedStructuredEvents=$true};Privacy='Counts, QA archive date ranges, per-export opaque report references and approved diagnostic status/reason fields only. No PDFs, extracted report text, filenames, paths, network addresses, usernames, credentials, raw logs or workstation names are included. Scanner aliases follow the configured scanner order.'}
}
function Get-QaSupportDestination {
    param([string]$AppRoot,$Config,[string]$DestinationPath,[string]$Extension)
    if(-not [IO.Path]::IsPathRooted($DestinationPath) -or [IO.Path]::GetExtension($DestinationPath) -cne $Extension){throw 'Choose a new local diagnostic file with the requested extension.'}
    $destination=[IO.Path]::GetFullPath($DestinationPath);Assert-QaSupportDirectPath $destination
    if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){$drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($destination));if($destination.StartsWith('\\') -or $drive.DriveType -eq [IO.DriveType]::Network){throw 'Save diagnostics on approved local or USB storage.'}}
    foreach($blocked in @((Join-Path $AppRoot 'Config'),(Join-Path $AppRoot 'App'),(Join-Path $AppRoot 'Data'),(Join-Path $Config.ArchiveRoot 'Reports'),(Join-Path $Config.ArchiveRoot '.ctqa'))){
        $prefix=[IO.Path]::GetFullPath($blocked).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if($destination.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Save diagnostics outside application code, settings and report data, for example Logs/Support.'}
    }
    if([IO.File]::Exists($destination)){throw 'Choose a new filename; existing files are not overwritten.'}
    return $destination
}
function Write-QaSupportAtomicText {
    param([string]$Destination,[string]$Text)
    $temp=$Destination+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[void][IO.Directory]::CreateDirectory((Split-Path -Parent $Destination));[IO.File]::WriteAllText($temp,$Text,(New-Object Text.UTF8Encoding($true)));[IO.File]::Move($temp,$Destination)}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Export-QaSupportReport {
    [CmdletBinding()]param([string]$AppRoot,$Config,$Dashboard,[string]$DestinationPath,[object[]]$ConnectionResults=@(),[string]$CurrentOperation='',$SupportContext=$null)
    $destination=Get-QaSupportDestination $AppRoot $Config $DestinationPath '.json'
    $report=Get-QaSupportReport -AppRoot $AppRoot -Config $Config -Dashboard $Dashboard -ConnectionResults $ConnectionResults -CurrentOperation $CurrentOperation -SupportContext $SupportContext
    Write-QaSupportAtomicText $destination ($report|ConvertTo-Json -Depth 16)
    return $destination
}
function Export-QaSupportHtml {
    [CmdletBinding()]param([string]$AppRoot,$Config,$Dashboard,[string]$DestinationPath,[object[]]$ConnectionResults=@(),[string]$CurrentOperation='',$SupportContext=$null)
    $destination=Get-QaSupportDestination $AppRoot $Config $DestinationPath '.html'
    $report=Get-QaSupportReport -AppRoot $AppRoot -Config $Config -Dashboard $Dashboard -ConnectionResults $ConnectionResults -CurrentOperation $CurrentOperation -SupportContext $SupportContext
    Write-QaSupportAtomicText $destination (ConvertTo-QaSupportHtml -Report $report)
    return $destination
}
function ConvertTo-QaSupportEventCsv {
    param([object[]]$Events=@())
    $lines=New-Object 'Collections.Generic.List[string]';[void]$lines.Add('"TimeUtc","Operation","Outcome","DurationMs","ScannerNumber","NativeCode","ErrorKind","Stage","Reason","Reader","Profile","Counts"')
    foreach($event in $Events){$safe=ConvertTo-QaSafeSupportEvent $event;if($null -eq $safe){continue};$cells=@($safe.TimeUtc,$safe.Operation,$safe.Outcome,$safe.DurationMs,$safe.ScannerNumber,$safe.NativeCode,$safe.ErrorKind,$safe.Stage,$safe.Reason,$safe.Reader,$safe.Profile,($safe.Counts|ConvertTo-Json -Compress));[void]$lines.Add((@($cells|ForEach-Object{'"'+([string]$_).Replace('"','""')+'"'}) -join ','))}
    return ($lines -join "`r`n")+"`r`n"
}
function Export-QaSupportBundle {
    [CmdletBinding()]param([string]$AppRoot,$Config,$Dashboard,[string]$DestinationPath,[object[]]$ConnectionResults=@(),[string]$CurrentOperation='',$SupportContext=$null)
    $destination=Get-QaSupportDestination $AppRoot $Config $DestinationPath '.zip'
    $temp=$destination+'.'+[guid]::NewGuid().ToString('N')+'.tmp';$stream=$null;$archive=$null
    Write-QaSupportEvent -AppRoot $AppRoot -Operation Diagnostics -Outcome Started
    try{
        $events=@(Get-QaSupportEvents -AppRoot $AppRoot -All -Config $Config)
        $report=Get-QaSupportReport -AppRoot $AppRoot -Config $Config -Dashboard $Dashboard -ConnectionResults $ConnectionResults -CurrentOperation $CurrentOperation -SupportContext $SupportContext -RetainedEvents $events
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
        $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        function Add-SupportEntry([string]$Name,[string]$Text){$entry=$archive.CreateEntry($Name);$writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)));try{$writer.Write($Text)}finally{$writer.Dispose()}}
        Add-SupportEntry 'Support-Summary.json' ($report|ConvertTo-Json -Depth 16)
        Add-SupportEntry 'SupportReport.html' (ConvertTo-QaSupportHtml -Report $report)
        Add-SupportEntry 'Report-Diagnostics.csv' (ConvertTo-QaSupportReportCsv -Rows $report.ReportDiagnostics)
        $entry=$archive.CreateEntry('Report-Diagnostics.jsonl');$writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)));try{foreach($row in $report.ReportDiagnostics){$writer.WriteLine(($row|ConvertTo-Json -Depth 6 -Compress))}}finally{$writer.Dispose()}
        $entry=$archive.CreateEntry('Scrubbed-Activity.jsonl');$writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)));try{foreach($event in $events){$writer.WriteLine(($event|ConvertTo-Json -Depth 6 -Compress))}}finally{$writer.Dispose()}
        Add-SupportEntry 'Scrubbed-Activity.csv' (ConvertTo-QaSupportEventCsv -Events $events)
        Add-SupportEntry 'READ ME.txt' ('CT QA Manager Pro - detailed scrubbed support bundle'+[Environment]::NewLine+'Open SupportReport.html for the printable overview. Press Ctrl+P to print or save as PDF. HTML contains up to 500 recent events and 500 pending/actionable report details; the summary JSON and report JSONL/CSV contain all current report diagnostics. Activity JSONL/CSV contain all retained allowlisted events captured for this export.'+[Environment]::NewLine+'Report0001-style references exist only within this export. They are not stable source-file identities and do not prove PDF integrity. ScannerNumber follows configured scanner order; zero means app-wide or unknown. Worker and host lifecycle records can describe nested parts of one action, not independent QA approvals.'+[Environment]::NewLine+'Log storage normally retains 90 days within 50 MB. Old structured legacy sources are re-scrubbed only when readable and within safety limits. Retained history cannot prove that every past operation was recorded. Raw logs, raw exceptions, PDF bytes/text, filenames, report hashes/IDs, paths, usernames, passwords, network addresses and workstation names are excluded. No automatic upload occurs.'+[Environment]::NewLine+'Retained events: '+$events.Count+[Environment]::NewLine+'Current report diagnostics: '+$report.ReportDiagnostics.Count)
        $archive.Dispose();$archive=$null;$stream=$null;[IO.File]::Move($temp,$destination)
        Write-QaSupportEvent -AppRoot $AppRoot -Operation Diagnostics -Outcome Completed -Counts @{Events=$events.Count;SavedReports=$report.ReportDiagnostics.Count}
        return $destination
    }catch{Write-QaSupportEvent -AppRoot $AppRoot -Operation Diagnostics -Outcome Failed -ErrorKind (Get-QaSupportErrorKind $_.Exception.Message);throw}
    finally{if($null -ne $archive){$archive.Dispose()}elseif($null -ne $stream){$stream.Dispose()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
Export-ModuleMember -Function Get-QaSupportReport,Export-QaSupportReport,Export-QaSupportBundle,Write-QaSupportEvent,Get-QaSupportErrorKind,ConvertTo-QaSupportHtml,Export-QaSupportHtml
