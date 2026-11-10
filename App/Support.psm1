# Shareable support data is rebuilt from an allowlist. Never bundle raw logs or reports.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:Operations=@('Startup','Reconnect','SetupPreview','Preview','Update','Import','Analysis','PdfRead','BrowseRefresh','Export','SourceAudit','Compatibility','Backup','Restore','Audit','Reclassify','ReclassifyPreview','AdoptLegacy','RetryAnalysis')
$script:Outcomes=@('Completed','Failed','Cancelled')
$script:Categories=@('Daily_QA','Monthly_QA','Monthly_QA/Pending_Verification','Acceptance_Tests','Needs_Review')
$script:IssueTypes=@('Connection','SourceUnavailable','SourceMissing','CopyFailed','Integrity','Audit','Recovery','Classification','MonthlyReview','DailyGap','DailyReview','CoverageUnknown','MonthlyGap','MonthlyPending','MonthlyComponents','MonthlyComponentsMissing','MonthlyChecklist','ChecklistNotSet','MonthlyChecklistNotSet','DuplicateName','MultipleSessions','Deferred')
function Get-QaSupportValue($Object,[string]$Name,$Default='') {if($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name};return $Default}
function Get-QaSupportNumber($Value,[int]$Maximum=2147483647) {$n=0;if([int]::TryParse([string]$Value,[ref]$n) -and $n -ge 0 -and $n -le $Maximum){return $n};return 0}
function Get-QaSupportDate($Value,[switch]$Time) {
    if($Value -is [datetime]){if($Time){return $Value.ToUniversalTime().ToString('o')};return $Value.ToString('yyyy-MM-dd')}
    $s=[string]$Value;$date=[datetime]::MinValue
    if($Time){if([datetime]::TryParseExact($s,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$date)){return $date.ToUniversalTime().ToString('o')}}
    elseif([datetime]::TryParseExact($s,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)){return $date.ToString('yyyy-MM-dd')}
    return ''
}
function Assert-QaSupportDirectPath([string]$Path) {
    $p=[IO.Path]::GetFullPath($Path)
    while($p){if(([IO.File]::Exists($p) -or [IO.Directory]::Exists($p)) -and (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Use a direct local folder for diagnostics, without links or junctions.'};$p=[IO.Path]::GetDirectoryName($p)}
}
function Get-QaSupportEvents {
    param([string]$AppRoot)
    $path=Join-Path $AppRoot 'Logs/Support-events.jsonl'
    $events=New-Object 'System.Collections.Generic.List[object]'
    try {
        Assert-QaSupportDirectPath $path
        if(-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 1048576){return @()}
        foreach($line in @([IO.File]::ReadAllLines($path)|Select-Object -Last 200)){
            try {
                $e=$line|ConvertFrom-Json;$operation=[string](Get-QaSupportValue $e Operation);$outcome=[string](Get-QaSupportValue $e Outcome);$time=Get-QaSupportDate (Get-QaSupportValue $e TimeUtc) -Time
                if($script:Operations -notcontains $operation -or $script:Outcomes -notcontains $outcome -or -not $time){continue}
                [void]$events.Add([pscustomobject]@{TimeUtc=$time;Operation=$operation;Outcome=$outcome;NativeCode=(Get-QaSupportNumber (Get-QaSupportValue $e NativeCode 0) 65535)})
            }catch{continue}
        }
    }catch{return @()}
    return @($events.ToArray())
}
function Write-QaSupportEvent {
    [CmdletBinding()]param([string]$AppRoot,[ValidateSet('Startup','Reconnect','SetupPreview','Preview','Update','Import','Analysis','PdfRead','BrowseRefresh','Export','SourceAudit','Compatibility','Backup','Restore','Audit','Reclassify','ReclassifyPreview','AdoptLegacy','RetryAnalysis')][string]$Operation,[ValidateSet('Completed','Failed','Cancelled')][string]$Outcome,[int]$NativeCode=0)
    try {
        $path=Join-Path $AppRoot 'Logs/Support-events.jsonl';Assert-QaSupportDirectPath $path
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        if([IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length -gt 262144){$keep=@(Get-QaSupportEvents $AppRoot|Select-Object -Last 100|ForEach-Object{$_|ConvertTo-Json -Compress});[IO.File]::WriteAllLines($path,[string[]]$keep,(New-Object Text.UTF8Encoding($false)))}
        $event=[pscustomobject]@{TimeUtc=[datetime]::UtcNow.ToString('o');Operation=$Operation;Outcome=$Outcome;NativeCode=(Get-QaSupportNumber $NativeCode 65535)}
        [IO.File]::AppendAllText($path,($event|ConvertTo-Json -Compress)+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
    }catch{} # Support logging must not interrupt a report operation.
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
    [CmdletBinding()]param([string]$AppRoot,$Config,$Dashboard,[object[]]$ConnectionResults=@(),[string]$CurrentOperation='')
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
        [void]$rows.Add([pscustomobject]@{Scanner=('Scanner '+$i);ConnectionAtLastScan=$state;CheckedUtc=$checked;LatestReconnectStatus=$recentStatus;LatestNativeCode=$code;UsernameConfigured=(-not [string]::IsNullOrWhiteSpace([string](Get-QaSupportValue $source Username)));SavedSignInFilePresent=$stored;SourceUsesUnc=([string]$source.Path).StartsWith('\\');DailySchedule=$schedule;ActiveFrom=(Get-QaSupportDate (Get-QaSupportValue $source ActiveFrom));DailyExceptionCount=@(Get-QaSupportValue $source ExcludedDates @()).Count;MonthlyExpected=[bool](Get-QaSupportValue $source ExpectedMonthly $false);MonthlyChecklistItemCount=@(Get-QaSupportValue $source MonthlyChecklist @()).Count;MonthlyDueDay=(Get-QaSupportNumber (Get-QaSupportValue $source MonthlyDueDay 0) 31);SavedReports=$records.Count;Categories=$categories;PdfAnalysisCounts=(Get-QaSupportAnalysisCounts -Config $Config -Records $records);EarliestReportDate=$first;LatestReportDate=$last;ReviewItemCounts=$counts})
    }
    $mode='None';if($script:Operations -ccontains $CurrentOperation){$mode=$CurrentOperation}
    return [pscustomobject]@{SchemaVersion=1;ApplicationVersion='4.3.0';CreatedUtc=[datetime]::UtcNow.ToString('o');PowerShellVersion=$PSVersionTable.PSVersion.ToString();Platform=$(if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Windows'}else{'Other'});LanguageMode=[string]$ExecutionContext.SessionState.LanguageMode;Process64Bit=[Environment]::Is64BitProcess;SetupComplete=[bool](Get-QaSupportValue $Dashboard SetupComplete $false);CurrentOperation=$mode;LookbackDays=(Get-QaSupportNumber (Get-QaSupportValue $Config LookbackDays 0) 36500);LookbackMonths=(Get-QaSupportNumber (Get-QaSupportValue $Config MonthlyLookbackMonths 0) 1200);MonitorMinutes=(Get-QaSupportNumber (Get-QaSupportValue $Config MonitorMinutes 0) 1440);ArchiveRecords=@(Get-QaSupportValue $Dashboard Records @()).Count;ReviewItems=@(Get-QaSupportValue $Dashboard Attention @()).Count;Scanners=@($rows.ToArray());RecentOperations=@(Get-QaSupportEvents $AppRoot);Privacy='Counts, QA archive date ranges and approved status fields only. No PDFs, extracted report text, filenames, paths, network addresses, usernames, credentials, raw logs or workstation names are included. Scanner aliases follow the configured scanner order.'}
}
function Export-QaSupportReport {
    [CmdletBinding()]param([string]$AppRoot,$Config,$Dashboard,[string]$DestinationPath,[object[]]$ConnectionResults=@(),[string]$CurrentOperation='')
    if(-not [IO.Path]::IsPathRooted($DestinationPath) -or [IO.Path]::GetExtension($DestinationPath) -ne '.json'){throw 'Choose a new local JSON filename for the support report.'}
    $destination=[IO.Path]::GetFullPath($DestinationPath);Assert-QaSupportDirectPath $destination
    if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){$drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($destination));if($destination.StartsWith('\\') -or $drive.DriveType -eq [IO.DriveType]::Network){throw 'Save diagnostics on approved local or USB storage.'}}
    foreach($blocked in @((Join-Path $AppRoot 'Config'),(Join-Path $AppRoot 'App'),(Join-Path $AppRoot 'Data'),(Join-Path $Config.ArchiveRoot 'Reports'),(Join-Path $Config.ArchiveRoot '.ctqa'))){
        if(-not $blocked){continue};$root=[IO.Path]::GetFullPath($blocked).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if($destination.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Save diagnostics outside application code, settings and report data, for example Logs/Support.'}
    }
    if([IO.File]::Exists($destination)){throw 'Choose a new filename; existing files are not overwritten.'}
    $report=Get-QaSupportReport -AppRoot $AppRoot -Config $Config -Dashboard $Dashboard -ConnectionResults $ConnectionResults -CurrentOperation $CurrentOperation
    $temp=$destination+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination));[IO.File]::WriteAllText($temp,($report|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($true)));[IO.File]::Move($temp,$destination)}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    return $destination
}
Export-ModuleMember -Function Get-QaSupportReport,Export-QaSupportReport,Write-QaSupportEvent
