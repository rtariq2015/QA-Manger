Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Archive.psm1')

function Get-QaInsightValue {param($Object,[string]$Name,$Default=$null)
    if($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name};return $Default
}
function ConvertFrom-QaReportText {
    [CmdletBinding()]param([string]$Text,[bool]$Truncated=$false)
    $findings=New-Object 'System.Collections.Generic.List[object]';$page=0
    foreach($line in ($Text -split '\r?\n')) {
        if($line -match '^--- Page (\d+) ---'){$page=[int]$Matches[1];continue}
        # Only explicit, labelled results are recognized. No invented numeric tolerances.
        $match=[regex]::Match($line,'(?i)^\s*(?<test>(?:water(?:\s+CT\s+value)?|CT\s+value|homogeneity|noise|MTF|modulation transfer function|slice thickness|low contrast|light\s*marker|table position|topogram position|CTDI(?:-Air)?)[^:=|]{0,80})\s*[:=|]\s*(?<result>PASS(?:ED)?|FAIL(?:ED)?|NOT\s+EVALUATED)\b')
        if($match.Success){[void]$findings.Add([pscustomobject]@{Test=$match.Groups['test'].Value.Trim();Result=$match.Groups['result'].Value.ToUpperInvariant();Page=$page;Evidence=$line.Trim()})}
    }
    $status='NeedsReview'
    if(@($findings|Where-Object{$_.Result -match '^FAIL'}).Count){$status='ReportedFailure'}
    elseif(-not $Truncated -and @($findings|Where-Object{$_.Result -match '^PASS'}).Count -gt 0 -and @($findings|Where-Object{$_.Result -notmatch '^PASS'}).Count -eq 0){$status='ReportedPass'}
    return [pscustomobject]@{ParserVersion=1;Status=$status;Truncated=$Truncated;Findings=@($findings.ToArray());Note='Extracted printed results only. Completeness, test limits and clinical suitability require the approved report and checklist.'}
}
function Get-QaSavedAnalysis {
    param($Config,$Record)
    $path=Join-Path (Join-Path $Config.ArchiveRoot '.ctqa/analysis') ($Record.Hash+'.json')
    if([IO.File]::Exists($path)) {
        try {
            $row=[IO.File]::ReadAllText($path)|ConvertFrom-Json
            $expected=Get-QaInsightValue $Record 'DestinationLastWriteUtc' ''
            $valid=$true
            if($expected){$stamp=if($expected -is [datetime]){$expected}else{[datetime]::Parse([string]$expected,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)};$valid=([IO.File]::GetLastWriteTimeUtc($Record.DestinationPath).Ticks -eq $stamp.ToUniversalTime().Ticks)}
            if($row.ParserVersion -eq 1 -and $row.Hash -eq $Record.Hash -and $valid){return $row}
        }catch{}
    }
    return $null
}
function Invoke-QaAnalysis {
    [CmdletBinding()]param($Config,$Progress=$null,[int]$Limit=20)
    Import-Module (Join-Path $PSScriptRoot 'Process.psm1')
    $dashboard=Get-QaDashboard -Config $Config;$done=0;$skipped=0;$failed=0
    $root=Join-Path $Config.ArchiveRoot '.ctqa/analysis'
    # Hash-based analysis is derived data; saving it never changes reviewed labels.
    foreach($record in @($dashboard.Records|Sort-Object ReportDate -Descending)) {
        if($null -ne $Progress -and $Progress.Cancel){break}
        if($null -ne (Get-QaSavedAnalysis $Config $record)){$skipped++;continue}
        if(($done+$failed) -ge $Limit){break}
        if($null -ne $Progress){$Progress.Message='Reading saved PDF '+($done+$failed+1)+' of up to '+$Limit+' locally...'}
        try {
            $read=Invoke-QaIsolatedTask -Action ReadPdf -InputObject ([pscustomobject]@{Config=$Config;RecordId=$record.Id}) -TimeoutSeconds 60 -Progress $Progress
            $row=ConvertFrom-QaReportText -Text $read.Text -Truncated ([bool]$read.Truncated)
            $row|Add-Member Hash ([string]$record.Hash);$row|Add-Member ReadUtc ([datetime]::UtcNow.ToString('o'))
            $row|Add-Member ReaderMessage ([string]$read.Message)
            $row|Add-Member SavedWriteTicks ([IO.File]::GetLastWriteTimeUtc($record.DestinationPath).Ticks) -Force
            Write-QaAnalysisFile -Root $root -Hash $record.Hash -Value $row
            $done++
        } catch {
            if($null -ne $Progress -and $Progress.Cancel){break}
            $failed++
            # Retain failures visibly; users can explicitly retry after fixing components.
            $row=[pscustomobject]@{ParserVersion=1;Hash=$record.Hash;Status='ReadError';Truncated=$true;Findings=@();ReadUtc=[datetime]::UtcNow.ToString('o');ReaderMessage=$_.Exception.Message}
            $row|Add-Member SavedWriteTicks ([IO.File]::GetLastWriteTimeUtc($record.DestinationPath).Ticks) -Force
            Write-QaAnalysisFile -Root $root -Hash $record.Hash -Value $row
        }
    }
    $cancelled=($null -ne $Progress -and [bool]$Progress.Cancel)
    return [pscustomobject]@{Mode='Analysis';Summary=[pscustomobject]@{Description=($done.ToString()+' PDFs analyzed; '+$skipped+' cached; '+$failed+' need review. No reviewed labels changed.');Cancelled=$cancelled};Analyzed=$done;Failed=$failed}
}
function Write-QaAnalysisFile {
    param([string]$Root,[string]$Hash,$Value)
    if($Hash -notmatch '^[0-9A-Fa-f]{64}$'){throw 'Invalid analysis fingerprint.'}
    foreach($p in @($Root,(Join-Path $Root ($Hash+'.json')))) {
        $q=[IO.Path]::GetFullPath($p)
        while($q){if(([IO.Directory]::Exists($q) -or [IO.File]::Exists($q)) -and (([IO.File]::GetAttributes($q) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Linked analysis paths are unsupported.'};$q=[IO.Path]::GetDirectoryName($q)}
    }
    [void][IO.Directory]::CreateDirectory($Root);$path=Join-Path $Root ($Hash+'.json');$temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($true)))
        if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,($temp+'.bak'));[IO.File]::Delete($temp+'.bak')}else{[IO.File]::Move($temp,$path)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Get-QaAnalysisProgress {
    [CmdletBinding()]param($Config,[object[]]$Records=@())
    $cached=0;$errors=0
    foreach($record in $Records){$row=Get-QaSavedAnalysis -Config $Config -Record $record;if($null -ne $row){$cached++;if($row.Status -eq 'ReadError'){$errors++}}}
    return [pscustomobject]@{Total=$Records.Count;Cached=$cached;Pending=($Records.Count-$cached);Errors=$errors}
}
function Get-QaTodayOverview {
    [CmdletBinding()]param($Config,$Dashboard,[datetime]$Date=(Get-Date))
    $day=$Date.Date;$key=$day.ToString('yyyy-MM-dd');$rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($source in $Config.Sources) {
        $required=($source.DailySchedule -eq 'AllDays' -or ($source.DailySchedule -eq 'Weekdays' -and $day.DayOfWeek -notin @('Saturday','Sunday')))
        if($source.ActiveFrom -and $key -lt [string]$source.ActiveFrom){$required=$false}
        if(@(Get-QaInsightValue $source 'ExcludedDates' @()) -contains $key){$required=$false}
        $records=@($Dashboard.Records|Where-Object{$_.Scanner -eq $source.Scanner -and $_.ReportDate -eq $key -and $_.Category -eq 'Daily_QA'})
        $provisional=@($records|Where-Object{[string](Get-QaInsightValue $_ 'ClassificationBasis' '') -like 'Provisional*' -and -not (Get-QaInsightValue $_ 'ConfirmedBy' '')})
        $records=@($records|Where-Object{[string](Get-QaInsightValue $_ 'ClassificationBasis' '') -notlike 'Provisional*' -or (Get-QaInsightValue $_ 'ConfirmedBy' '')})
        $status=if(-not $required){'Not scheduled'}elseif($records.Count){'Report received'}elseif($provisional.Count){'Report needs classification'}else{'Awaiting report'}
        $analyses=@($records|ForEach-Object{Get-QaSavedAnalysis $Config $_}|Where-Object{$null -ne $_})
        $finding='Not analyzed'
        if(@($analyses|Where-Object{$_.Status -eq 'ReportedFailure'}).Count){$finding='Printed FAIL detected - review PDF'}
        elseif(@($analyses|Where-Object{$_.Status -eq 'ReportedPass'}).Count){$finding='Recognized printed PASS results'}
        elseif($analyses.Count){$finding='Needs review / text incomplete'}
        $scanner=@($Dashboard.Scanners|Where-Object{$_.Scanner -eq $source.Scanner}|Select-Object -First 1)
        $checked=if($scanner.Count){[string](Get-QaInsightValue $scanner[0] 'CheckedUtc' '')}else{''}
        [void]$rows.Add([pscustomobject]@{Scanner=$source.Scanner;Name=$source.Name;Required=$required;Received=($records.Count -gt 0);DailyStatus=$status;Findings=$finding;CheckedUtc=$checked;ReportIds=@($records|ForEach-Object{$_.Id})})
    }
    $expected=@($rows|Where-Object Required).Count;$received=@($rows|Where-Object{$_.Required -and $_.Received}).Count
    $headline=if($expected -eq 0){'No Daily QA reports scheduled today'}elseif($received -eq $expected){'All required Daily QA reports received'}else{($received.ToString()+' of '+$expected+' Daily QA reports received')}
    return [pscustomobject]@{Date=$key;Headline=$headline;Expected=$expected;Received=$received;Scanners=@($rows.ToArray())}
}
function Get-QaMonthOverview {
    [CmdletBinding()]param($Config,$Dashboard,[datetime]$Date=(Get-Date))
    $month=$Date.ToString('yyyy-MM');$coverage=@(Get-QaMonthlyCoverage -Config $Config -Records @($Dashboard.Records) -Months @($month))
    foreach($row in $coverage) {
        $source=@($Config.Sources|Where-Object{$_.Scanner -eq $row.Scanner})[0]
        $due=[int](Get-QaInsightValue $source 'MonthlyDueDay' 0);$dueText='Set department due date';$timing='Not configured'
        if($due -gt 0){$dueDate=New-Object datetime $Date.Year,$Date.Month,([math]::Min($due,[datetime]::DaysInMonth($Date.Year,$Date.Month)));$dueText=$dueDate.ToString('MMM d');$timing=if($row.Status -eq 'Complete'){'Reviewed evidence complete'}elseif($Date.Date -gt $dueDate){'Overdue evidence'}elseif($Date.Date -eq $dueDate){'Due today'}else{'Upcoming'}}
        $detail=if($row.Status -eq 'ChecklistNotSet'){'Set the department checklist in scanner settings'}elseif($row.Status -eq 'Complete'){'All configured items have reviewed evidence'}else{('Still needed: '+($row.MissingComponents -join '; '))}
        [pscustomobject]@{Scanner=$row.Scanner;Name=$row.ScannerName;Month=$month;Progress=$(if($row.Status -eq 'ChecklistNotSet'){'Not set'}elseif($row.Status -eq 'NotRequired'){'Not required'}else{$row.ConfirmedComponents.Count.ToString()+' / '+$row.RequiredComponents.Count+' items'});Due=$dueText;Timing=$timing;Detail=$detail;Status=$row.Status}
    }
}
function Invoke-QaSourceAudit {
    [CmdletBinding()]param($Config,$Progress=$null)
    Import-Module (Join-Path $PSScriptRoot 'Process.psm1')
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $records=@((Get-QaDashboard $Config).Records|Sort-Object FirstArchived -Descending|Group-Object Scanner,SourcePath|ForEach-Object{$_.Group[0]})
    foreach($record in $records) {
        if($null -ne $Progress -and $Progress.Cancel){break}
        if($null -ne $Progress){$Progress.Message='Verifying scanner source '+$record.OriginalFileName}
        try {
            $hash=Invoke-QaIsolatedTask SourceHash ([pscustomobject]@{Path=$record.SourcePath}) -TimeoutSeconds 45 -Progress $Progress
            $status=if($hash -eq $record.Hash){'Matches latest saved revision'}else{'Source bytes changed - run Update Reports'}
        } catch {$status='Unavailable, timed out, or access denied'}
        [void]$rows.Add([pscustomobject]@{Scanner=$record.Scanner;Report=$record.OriginalFileName;Status=$status})
    }
    return [pscustomobject]@{Mode='SourceAudit';Rows=@($rows.ToArray());Summary=[pscustomobject]@{Description='Scanner source fingerprints checked read-only. Archive labels were not changed.';Cancelled=($null -ne $Progress -and [bool]$Progress.Cancel)}}
}
Export-ModuleMember -Function ConvertFrom-QaReportText,Get-QaSavedAnalysis,Invoke-QaAnalysis,Get-QaTodayOverview,Get-QaAnalysisProgress,Get-QaMonthOverview,Invoke-QaSourceAudit
