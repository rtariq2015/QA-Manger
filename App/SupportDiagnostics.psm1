# A shareable, cached-data-only diagnostic projection. No WebService dependency.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:DiagnosticReasons=@('Unread','CacheMissing','CacheStale','CacheUnreadable','OrganizationUnreadable','MeasurementUpgradePending','MissingFormatRule','UnknownTemplate','UncertainReportDate','DateConflict','TimeConflict','TypeConflict','UndoRestored','ReaderFailed','IncompleteRead','NoReadableText','UnsupportedProfile','NoSupportedTables','UnsupportedSelectedMetric','UnrecognizedSections','ConflictingExplicitTitles','InputLimit','MeasurementReviewNeeded','SupportedPrintedValues','SupportedProfile','PrintedObservationNeedsReview','MeasurementLimitReached','Unknown')
$script:DiagnosticStages=@('Preparing','Connecting','Scanning','Copying','Library','Analyzing','Exporting','BackingUp','Restoring','Verifying','Finishing','Paused','Queued','Idle','Unknown')
$script:DiagnosticActions=@('Startup','Reconnect','SetupPreview','Preview','Update','Import','Analysis','PdfPreview','PdfRead','BrowseRefresh','Export','SourceAudit','Compatibility','Backup','Restore','Audit','Reclassify','ReclassifyPreview','AdoptLegacy','RetryAnalysis','Shutdown','Settings','Diagnostics','PrintDiagnostics','ReadingScheduler','OfflineUpdate','Refresh','Approve','Disapprove','Undo','ApplyProfile','Analyze','AnalyzeBacklog','Browse','PickArchive','ScannerSettings','PrepareUpdate','InstallPreparedUpdate','OpenClassic')
function Get-QaDiagnosticValue($Object,[string]$Name,$Default=$null){
    if($null -ne $Object){if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}elseif($null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name}};return $Default
}
function Get-QaDiagnosticNumber($Value,[int]$Maximum=2147483647){$number=0;if([int]::TryParse([string]$Value,[ref]$number) -and $number -ge 0 -and $number -le $Maximum){return $number};return 0}
function Get-QaDiagnosticEnum($Value,[string[]]$Allowed,[string]$Default='Unknown'){
    if($Value -isnot [string]){return $Default};foreach($entry in $Allowed){if([string]::Equals($entry,$Value,[StringComparison]::OrdinalIgnoreCase)){return $entry}};return $Default
}
function Get-QaDiagnosticProfile($Value){
    if($Value -isnot [string]){return 'Unknown'}
    if($Value -ceq 'siemens-iec-basic-v1'){return 'Basic'};if($Value -ceq 'siemens-iec-extended-v1'){return 'Extended'};if($Value -ceq 'siemens-iec-additional-v1'){return 'Additional'};if($Value -ceq 'siemens-quality-daily-v1'){return 'Daily'};return Get-QaDiagnosticEnum $Value @('Basic','Extended','Additional','Daily','Unknown')
}
function Get-QaDiagnosticDate($Value){
    $date=[datetime]::MinValue
    if($Value -is [datetime]){return $Value.ToUniversalTime().ToString('o')}
    if($Value -is [string]){$offset=[datetimeoffset]::MinValue;if($Value -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$' -and [datetimeoffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$offset)){return $offset.UtcDateTime.ToString('o')}};return ''
}
function Get-QaSupportDiagnosticSchema {
    return [pscustomobject]@{Reasons=$script:DiagnosticReasons;Stages=$script:DiagnosticStages;Actions=$script:DiagnosticActions;EventReasons=@($script:DiagnosticReasons)+@('Queued','CacheReused','ReadStarted','ReadCompleted','ReadFailed','ForegroundYield','UserPaused','UserResumed','UserStopped','BatchLimitReached','QueueEmpty','WorkerTimeout','WorkerCancelled','WorkerFailed','Started','Completed','Failed','Cancelled','OperationStarted','OperationCompleted','OperationFailed')}
}
function ConvertTo-QaSupportDiagnosticRows {
    [CmdletBinding()]param([object[]]$Rows=@())
    $result=New-Object 'Collections.Generic.List[object]';$number=0
    foreach($row in $Rows){
        $number++;$scanner=Get-QaDiagnosticNumber (Get-QaDiagnosticValue $row scannerNumber 0) 20
        $filing=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $row filingStatus) @('Pending','Automatic','Approved','Disapproved','Organized','Unknown')
        if($filing -eq 'Unknown' -and (Get-QaDiagnosticValue $row pending $false) -is [bool] -and (Get-QaDiagnosticValue $row pending $false)){$filing='Pending'}
        $category=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $row category) @('Daily','Monthly','Acceptance','Other','Unknown')
        $cache=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $row textCacheStatus) @('Missing','Valid','ReadFailed','Stale','Unreadable','Unknown')
        $schema=Get-QaDiagnosticNumber (Get-QaDiagnosticValue $row cacheSchemaVersion 0) 3
        $measurementVersion=Get-QaDiagnosticNumber (Get-QaDiagnosticValue $row measurementVersion 0) 1
        $measurement=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $row measurementStatus) @('NotRead','UpgradePending','Extracted','NeedsReview','ReadError','UnsupportedProfile','NoSupportedTables','NoReadableText','Unknown')
        $content=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $row contentStatus) @('NotRead','Recognized','NeedsReview','ReadError','NeedsOCR','Unknown')
        $profile=Get-QaDiagnosticProfile (Get-QaDiagnosticValue $row profile)
        $reader=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $row reader) @('Standard','Python','Legacy','Unknown')
        $reasons=New-Object 'Collections.Generic.List[string]'
        foreach($candidate in @(Get-QaDiagnosticValue $row reasonCodes @())){$reason=Get-QaDiagnosticEnum $candidate $script:DiagnosticReasons;if(-not $reasons.Contains($reason)){[void]$reasons.Add($reason)}}
        $derived=New-Object 'Collections.Generic.List[string]'
        if($cache -eq 'Missing'){[void]$derived.Add('CacheMissing');[void]$derived.Add('Unread')}
        if($cache -eq 'Stale'){[void]$derived.Add('CacheStale')};if($cache -eq 'Unreadable'){[void]$derived.Add('CacheUnreadable')}
        if($cache -eq 'ReadFailed' -or $content -eq 'ReadError'){[void]$derived.Add('ReaderFailed')}
        if($measurement -eq 'UpgradePending'){[void]$derived.Add('MeasurementUpgradePending')}
        foreach($code in $derived){if(-not $reasons.Contains($code)){[void]$reasons.Add($code)}}
        [void]$result.Add([pscustomobject]@{Reference=('Report'+$number.ToString('0000'));Scanner=$(if($scanner){'Scanner '+$scanner}else{'Scanner unknown'});ScannerNumber=$scanner;FilingStatus=$filing;Category=$category;TextCacheStatus=$cache;CacheSchemaVersion=$schema;MeasurementVersion=$measurementVersion;MeasurementStatus=$measurement;ContentStatus=$content;Profile=$profile;Reader=$reader;ReadMilliseconds=(Get-QaDiagnosticNumber (Get-QaDiagnosticValue $row readMilliseconds 0) 3600000);ReadPages=(Get-QaDiagnosticNumber (Get-QaDiagnosticValue $row readPages 0) 100000);TotalPages=(Get-QaDiagnosticNumber (Get-QaDiagnosticValue $row totalPages 0) 100000);MeasurementCount=(Get-QaDiagnosticNumber (Get-QaDiagnosticValue $row measurementCount 0) 100);ContentSupportRevision=(Get-QaDiagnosticNumber (Get-QaDiagnosticValue $row contentSupportRevision 0) 99);Model=(Get-QaDiagnosticEnum (Get-QaDiagnosticValue $row model) @('Edge','Flash','Drive','Unknown'));SizeBand=(Get-QaDiagnosticEnum (Get-QaDiagnosticValue $row sizeBand) @('Small','Medium','Large','Unknown'));ReasonCodes=@($reasons.ToArray())})
    }
    return @($result.ToArray())
}
function Get-QaSupportCachedDiagnosticRows {
    [CmdletBinding()]param($Config,$Dashboard)
    $rows=New-Object 'Collections.Generic.List[object]';$sourceNumbers=@{};$number=0;$cache=@{}
    foreach($source in @(Get-QaDiagnosticValue $Config Sources @())){$number++;$sourceNumbers[[string](Get-QaDiagnosticValue $source Scanner '')]=$number}
    foreach($record in @(Get-QaDiagnosticValue $Dashboard Records @())){
        $scannerId=[string](Get-QaDiagnosticValue $record Scanner '');$scanner=0;if($sourceNumbers.ContainsKey($scannerId)){$scanner=$sourceNumbers[$scannerId]}
        $rawCategory=[string](Get-QaDiagnosticValue $record Category '');$category=switch($rawCategory){'Daily_QA'{'Daily'}'Monthly_QA'{'Monthly'}'Monthly_QA/Pending_Verification'{'Monthly'}'Acceptance_Tests'{'Acceptance'}'Needs_Review'{'Other'}default{'Unknown'}}
        $basis=[string](Get-QaDiagnosticValue $record ClassificationBasis '');$confirmed=[string](Get-QaDiagnosticValue $record ConfirmedBy '')
        $filing=if($rawCategory -in @('Monthly_QA/Pending_Verification','Needs_Review') -or (-not $confirmed -and $basis -like 'Provisional*')){'Pending'}else{'Organized'}
        $row=[ordered]@{scannerNumber=$scanner;filingStatus=$filing;category=$category;textCacheStatus='Missing';cacheSchemaVersion=0;measurementVersion=0;measurementStatus='NotRead';contentStatus='NotRead';profile='Unknown';reader='Unknown';reasonCodes=@()}
        $reasons=New-Object 'Collections.Generic.List[string]';$saved=$null;$hash=[string](Get-QaDiagnosticValue $record Hash '')
        if($hash -cmatch '^[0-9A-Fa-f]{64}$'){
            if(-not $cache.ContainsKey($hash)){
                $value=$null;$state='Missing';$path=Join-Path ([string](Get-QaDiagnosticValue $Config ArchiveRoot '')) ('.ctqa/analysis/'+$hash+'.json')
                try{
                    $ancestor=[IO.Path]::GetFullPath($path)
                    while($ancestor){if(([IO.File]::Exists($ancestor) -or [IO.Directory]::Exists($ancestor)) -and (([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Linked cache'};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
                    if([IO.File]::Exists($path)){if((New-Object IO.FileInfo($path)).Length -gt 1048576){throw 'Cache limit'};$value=[IO.File]::ReadAllText($path)|ConvertFrom-Json;if([string](Get-QaDiagnosticValue $value Hash '') -cne $hash){throw 'Cache identity'};$state='Present'}
                }catch{$state='Unreadable';$value=$null}
                $cache[$hash]=[pscustomobject]@{state=$state;value=$value}
            }
            $entry=$cache[$hash];$row.textCacheStatus=$entry.state;$saved=$entry.value
            $id=[string](Get-QaDiagnosticValue $record Id '');$savedId=[string](Get-QaDiagnosticValue $saved RecordId '')
            if($null -ne $saved -and $id -and $savedId -and $id -cne $savedId){$aliases=@(Get-QaDiagnosticValue $saved OtherRecords @()|Where-Object{[string](Get-QaDiagnosticValue $_ RecordId '') -ceq $id});if($aliases.Count -eq 1){$saved=$aliases[0]}else{$saved=$null;$row.textCacheStatus='Stale'}}
        }
        if($null -ne $saved){
            $row.cacheSchemaVersion=Get-QaDiagnosticNumber (Get-QaDiagnosticValue $saved AnalysisCacheSchemaVersion 0) 3
            $row.readMilliseconds=Get-QaDiagnosticNumber (Get-QaDiagnosticValue $saved ReaderElapsedMs 0) 3600000
            $row.contentSupportRevision=Get-QaDiagnosticNumber (Get-QaDiagnosticValue $saved ContentSupportRevision 0) 99
            $row.reader=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $saved ReaderUsed) @('Standard','Python','Legacy','Unknown')
            $doc=Get-QaDiagnosticValue $saved DocumentClassification $null;$measurement=Get-QaDiagnosticValue $saved MeasurementsDocument $null
            $row.model=Get-QaDiagnosticEnum (([string](Get-QaDiagnosticValue $doc Model '')) -replace '^SOMATOM(?: Definition)? ','') @('Edge','Flash','Drive','Unknown')
            $row.readPages=Get-QaDiagnosticNumber (Get-QaDiagnosticValue $doc ReadPages 0) 100000;$row.totalPages=Get-QaDiagnosticNumber (Get-QaDiagnosticValue $doc Pages 0) 100000
            $row.measurementCount=[math]::Min(100,@(Get-QaDiagnosticValue $measurement Measurements @()).Count)
            $row.measurementVersion=Get-QaDiagnosticNumber (Get-QaDiagnosticValue $measurement MeasurementVersion 0) 1
            $row.profile=Get-QaDiagnosticProfile (Get-QaDiagnosticValue $doc ProfileId)
            $row.contentStatus=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $doc Status) @('NotRead','Recognized','NeedsReview','ReadError','NeedsOCR','Unknown')
            $row.measurementStatus=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $measurement Status) @('NotRead','Extracted','NeedsReview','ReadError','Unknown')
            foreach($code in @((Get-QaDiagnosticValue $doc ReasonCode),(Get-QaDiagnosticValue $measurement ReasonCode))){if($code){$safe=Get-QaDiagnosticEnum $code $script:DiagnosticReasons;if(-not $reasons.Contains($safe)){[void]$reasons.Add($safe)}}}
            if([string](Get-QaDiagnosticValue $saved Status '') -ceq 'ReadError'){$row.textCacheStatus='ReadFailed';$row.contentStatus='ReadError';$row.measurementStatus='ReadError';[void]$reasons.Add('ReaderFailed')}
            else{
                # Inspect destination metadata only. Never reopen PDF bytes for diagnostics.
                $destination=[string](Get-QaDiagnosticValue $record DestinationPath '');$verified=$false
                if($destination){try{$info=New-Object IO.FileInfo($destination);$info.Refresh();$verified=($info.Exists -and (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -and [string](Get-QaDiagnosticValue $saved VerifiedHash '') -ceq $hash -and [long](Get-QaDiagnosticValue $saved VerifiedLength -1) -eq $info.Length -and [long](Get-QaDiagnosticValue $saved VerifiedWriteTicks 0) -eq $info.LastWriteTimeUtc.Ticks -and [string](Get-QaDiagnosticValue $saved RecordId '') -ceq [string](Get-QaDiagnosticValue $record Id ''))}catch{}}
                $row.textCacheStatus=if($verified){'Valid'}elseif($row.cacheSchemaVersion -in @(2,3)){'Stale'}else{'Unknown'}
                if($row.measurementVersion -ne 1){$row.measurementStatus='UpgradePending';[void]$reasons.Add('MeasurementUpgradePending')}
                if($null -ne $doc){
                    if((Get-QaDiagnosticValue $doc CompleteRead $false) -isnot [bool] -or -not (Get-QaDiagnosticValue $doc CompleteRead $false)){[void]$reasons.Add('IncompleteRead')}
                    $dateStatus=[string](Get-QaDiagnosticValue $doc DateStatus '');if($dateStatus -in @('Conflict','Invalid')){[void]$reasons.Add('DateConflict')}elseif($dateStatus -ne 'Consensus'){[void]$reasons.Add('UncertainReportDate')}
                    $printedDate=[string](Get-QaDiagnosticValue $doc ReportDate '');$savedDate=[string](Get-QaDiagnosticValue $record ReportDate '');$printedTime=[string](Get-QaDiagnosticValue $doc ReportTime '');$savedTime=[string](Get-QaDiagnosticValue $record ReportTime '')
                    if($printedDate -and $savedDate -and $printedDate -cne $savedDate){[void]$reasons.Add('DateConflict')};if($printedTime -and $savedTime -and $printedTime -cne $savedTime){[void]$reasons.Add('TimeConflict')}
                    if($row.contentStatus -eq 'Recognized' -and $row.profile -ne 'Unknown' -and [string](Get-QaDiagnosticValue $doc Category '') -cnotin @('Daily','Monthly')){
                        $source=@(Get-QaDiagnosticValue $Config Sources @()|Where-Object{[string](Get-QaDiagnosticValue $_ Scanner '') -ceq $scannerId}|Select-Object -First 1)
                        $mapped=$false;if($source.Count){$profileId=[string](Get-QaDiagnosticValue $doc ProfileId '');$rules=@(Get-QaDiagnosticValue $source[0] ContentProfiles @()|Where-Object{[string](Get-QaDiagnosticValue $_ profileId '') -ceq $profileId -and [string](Get-QaDiagnosticValue $_ category '') -cin @('Daily','Monthly','Other')});$mapped=($rules.Count -eq 1)}
                        if(-not $mapped){[void]$reasons.Add('MissingFormatRule')}
                    }
                }
            }
        }
        $length=0L;if([long]::TryParse([string](Get-QaDiagnosticValue $record Length ''),[ref]$length) -and $length -gt 0){$row.sizeBand=if($length -lt 1048576){'Small'}elseif($length -lt 10485760){'Medium'}else{'Large'}}
        $row.reasonCodes=@($reasons.ToArray());[void]$rows.Add([pscustomobject]$row)
    }
    return ConvertTo-QaSupportDiagnosticRows -Rows @($rows.ToArray())
}
function ConvertTo-QaSupportWorkRows {
    param([object[]]$Rows=@())
    $result=New-Object 'Collections.Generic.List[object]';$number=0
    foreach($row in $Rows){$number++;[void]$result.Add([pscustomobject]@{Reference=('Work'+$number.ToString('0000'));Action=(Get-QaDiagnosticEnum (Get-QaDiagnosticValue $row action) $script:DiagnosticActions);Status=(Get-QaDiagnosticEnum (Get-QaDiagnosticValue $row status) @('Queued','Running','Paused','Completed','Cancelled','Failed'));Stage=(Get-QaDiagnosticEnum (Get-QaDiagnosticValue $row stage) $script:DiagnosticStages);Completed=(Get-QaDiagnosticNumber (Get-QaDiagnosticValue $row completed 0));Total=(Get-QaDiagnosticNumber (Get-QaDiagnosticValue $row total 0));Failed=(Get-QaDiagnosticNumber (Get-QaDiagnosticValue $row failed 0));Background=((Get-QaDiagnosticValue $row background $false) -is [bool] -and (Get-QaDiagnosticValue $row background $false));PauseRequested=((Get-QaDiagnosticValue $row pauseRequested $false) -is [bool] -and (Get-QaDiagnosticValue $row pauseRequested $false));CancelRequested=((Get-QaDiagnosticValue $row cancelRequested $false) -is [bool] -and (Get-QaDiagnosticValue $row cancelRequested $false))})}
    return @($result.ToArray())
}
function Get-QaSupportDiagnosticCounts {
    param([object[]]$Rows=@())
    $counts=[ordered]@{Reports=$Rows.Count;PendingFiling=0;MeasurementUpgradePending=0;Unread=0;MissingFormatRule=0;UnknownTemplate=0;DateConflict=0;TimeConflict=0;TypeConflict=0;UndoRestored=0;ReaderFailed=0;IncompleteRead=0;UnsupportedSelectedMetric=0}
    foreach($row in $Rows){if($row.FilingStatus -ceq 'Pending'){$counts.PendingFiling++};foreach($code in @($row.ReasonCodes|Select-Object -Unique)){if(-not $counts.Contains($code)){$counts[$code]=0};$counts[$code]++}}
    return [pscustomobject]$counts
}
function Get-QaSupportReasonDescription([string]$Code){
    switch($Code){
        'UserPaused'{'Pause requested; the current PDF finishes before the next safe boundary takes effect.'}
        'UserResumed'{'Resume requested; reading continues when the archive slot is available.'}
        'UserStopped'{'Stop requested; the current safe checkpoint completes first.'}
        'Unread'{'PDF text has not been read into a current cache.'}
        'CacheMissing'{'No text-analysis cache is available.'}
        'CacheStale'{'Cached provenance is stale or does not match current archive metadata.'}
        'CacheUnreadable'{'The cache could not be safely decoded; its raw contents were excluded.'}
        'OrganizationUnreadable'{'File-organization history could not be read; saved decisions were preserved and their state is unknown.'}
        'MeasurementUpgradePending'{'Text was cached without the current measurements; a measurement-reading upgrade is waiting.'}
        'MissingFormatRule'{'A supported report format was recognized, but no scanner filing rule was selected.'}
        'UnknownTemplate'{'The extracted document does not match a currently supported template.'}
        'UncertainReportDate'{'The printed report date is missing or uncertain.'}
        'DateConflict'{'Printed or indexed report dates disagree.'}
        'TimeConflict'{'Printed and indexed report times disagree.'}
        'TypeConflict'{'The title, filename or saved filing rule disagree about the file type.'}
        'UndoRestored'{'Undo restored this file to the pending list; no decision was silently reapplied.'}
        'ReaderFailed'{'PDF reading failed. Automatic retries are suppressed until a change or explicit retry.'}
        'IncompleteRead'{'The whole document was not available as complete verified text.'}
        'NoReadableText'{'No readable text was available; an image-only PDF may need OCR.'}
        'UnsupportedProfile'{'The numbered document profile is unsupported for measurement extraction.'}
        'NoSupportedTables'{'No supported single-metric table was extracted.'}
        'UnsupportedSelectedMetric'{'This report has no usable values for the selected measurement; this does not by itself mean the PDF cannot open.'}
        'UnrecognizedSections'{'Numbered sections are unknown, duplicated or out of sequence.'}
        'ConflictingExplicitTitles'{'Explicit Daily and Monthly titles conflict.'}
        'InputLimit'{'A bounded parser input limit was reached.'}
        'MeasurementReviewNeeded'{'Some extracted measurement evidence needs inspection in its source PDF.'}
        'PrintedObservationNeedsReview'{'A printed observation was flagged for review; no clinical result was inferred.'}
        'MeasurementLimitReached'{'The supported measurement-row limit was reached.'}
        'Unknown'{'No further shareable reason is available.'}
        'SupportedPrintedValues'{'Supported printed measurements were extracted.'}
        'SupportedProfile'{'A supported document profile was recognized.'}
        default{'No further shareable reason is available.'}
    }
}
function ConvertTo-QaSupportReportCsv {
    [CmdletBinding()]param([object[]]$Rows=@())
    $safe=@(ConvertTo-QaSupportDiagnosticRows -Rows $Rows);$lines=New-Object 'Collections.Generic.List[string]'
    [void]$lines.Add('"Reference","Scanner","ScannerNumber","FilingStatus","Category","TextCacheStatus","CacheSchemaVersion","MeasurementVersion","MeasurementStatus","ContentStatus","Profile","Reader","ReadMilliseconds","ReadPages","TotalPages","MeasurementCount","ContentSupportRevision","Model","SizeBand","ReasonCodes"')
    foreach($row in $safe){$cells=@($row.Reference,$row.Scanner,$row.ScannerNumber,$row.FilingStatus,$row.Category,$row.TextCacheStatus,$row.CacheSchemaVersion,$row.MeasurementVersion,$row.MeasurementStatus,$row.ContentStatus,$row.Profile,$row.Reader,$row.ReadMilliseconds,$row.ReadPages,$row.TotalPages,$row.MeasurementCount,$row.ContentSupportRevision,$row.Model,$row.SizeBand,($row.ReasonCodes -join ';'));[void]$lines.Add((@($cells|ForEach-Object{'"'+([string]$_).Replace('"','""')+'"'}) -join ','))}
    return ($lines -join "`r`n")+"`r`n"
}
function ConvertTo-QaSupportHtml {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Report)
    # Public conversion is also a privacy boundary: regenerate row references and
    # constrain every displayed input even if callers bypass Get-QaSupportReport.
    $rows=@(ConvertTo-QaSupportDiagnosticRows -Rows @(Get-QaDiagnosticValue $Report ReportDiagnostics @()))
    $work=@(ConvertTo-QaSupportWorkRows -Rows @(Get-QaDiagnosticValue $Report WorkState @()))
    $events=@(Get-QaDiagnosticValue $Report RecentOperations @()|Select-Object -Last 500)
    $counts=Get-QaSupportDiagnosticCounts $rows
    $version=[string](Get-QaDiagnosticValue $Report ApplicationVersion '');if($version -cnotmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$'){$version='Unknown'}
    $created=Get-QaDiagnosticDate (Get-QaDiagnosticValue $Report CreatedUtc)
    $retained=Get-QaDiagnosticNumber (Get-QaDiagnosticValue (Get-QaDiagnosticValue $Report EventHistory) RetainedEvents $events.Count);$retained=[math]::Max($retained,$events.Count)
    $pending=@($rows|Where-Object{$_.FilingStatus -eq 'Pending' -or @($_.ReasonCodes|Where-Object{$_ -cnotin @('SupportedPrintedValues','SupportedProfile')}).Count}|Sort-Object @{Expression={if($_.FilingStatus -eq 'Pending'){0}else{1}}},Reference)
    $shown=@($pending|Select-Object -First 500)
    $html=New-Object Text.StringBuilder
    [void]$html.Append(@'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><title>CT QA Manager Pro - Diagnostic report</title><style>
:root{font-family:Segoe UI,Arial,sans-serif;color:#16302c;background:#f3f6f5}body{max-width:1180px;margin:32px auto;padding:0 24px;line-height:1.5}h1,h2,h3{line-height:1.2}h1{margin:8px 0 16px}h2{margin-top:32px}header,.panel{background:white;border:1px solid #d8e3df;border-radius:12px;padding:22px;margin:16px 0}.muted{color:#50665e}.eyebrow{font-size:12px;letter-spacing:.1em;color:#357360;text-transform:uppercase}.callout{border-left:4px solid #16866f;padding:12px 16px;background:#e9f5f0}.facts{display:flex;gap:18px;flex-wrap:wrap}.fact{background:#edf4f1;padding:12px;min-width:160px}.fact strong{display:block;font-size:25px}table{width:100%;border-collapse:collapse;font-size:12px}th,td{text-align:left;padding:9px;border-bottom:1px solid #d8e3df;vertical-align:top;overflow-wrap:anywhere}th{background:#edf4f1}code{font-size:11px}.table-wrap{overflow:auto}ul{padding-left:22px}.small{font-size:12px}.report-detail{break-inside:avoid;border-top:1px solid #d8e3df;padding:12px 0}.report-detail h3{font-size:15px;margin:0 0 6px}.report-detail p,.report-detail ul{margin:5px 0}footer{font-size:12px;margin:30px 0;color:#50665e}@media print{body{background:white;max-width:none;margin:0;padding:0;font-size:10pt}header,.panel{border-radius:0;border-color:#aaa;padding:10pt}.table-wrap{overflow:visible}th{background:#eee}thead{display:table-header-group}tr,.report-detail{break-inside:avoid}h2,h3{break-after:avoid}.print-hint{border:1px solid #aaa}footer{color:#333}a{color:inherit}}
</style></head><body><header><div class="eyebrow">Local workspace · scrubbed support evidence</div><h1>CT QA Manager Pro · Diagnostic report</h1><p class="print-hint callout"><strong>Print or save as PDF:</strong> press Ctrl+P in this browser and choose your printer or Save as PDF. No internet connection is needed.</p>
'@)
    function ConvertTo-QaDiagnosticHtmlText($Value){return [Net.WebUtility]::HtmlEncode([string]$Value)}
    [void]$html.Append('<p>Application '+(ConvertTo-QaDiagnosticHtmlText $version)+' · Exported UTC '+(ConvertTo-QaDiagnosticHtmlText $created)+'</p><p class="muted">This report describes program work and cached document evidence. It does not approve clinical QA. No PDFs, PDF text, filenames, report hashes or IDs, paths, usernames, passwords, network addresses or workstation names are included.</p></header>')
    [void]$html.Append('<section class="panel"><h2>Current snapshot</h2><div class="facts">')
    foreach($item in @(@('Reports diagnosed',$rows.Count),@('Pending filing',$counts.PendingFiling),@('Not yet read',$counts.Unread),@('Measurement upgrades',$counts.MeasurementUpgradePending),@('Missing filing rules',$counts.MissingFormatRule),@('Retained events',$retained))){[void]$html.Append('<div class="fact"><strong>'+(ConvertTo-QaDiagnosticHtmlText $item[1])+'</strong>'+(ConvertTo-QaDiagnosticHtmlText $item[0])+'</div>')}
    [void]$html.Append('</div><p class="small">Report references such as Report0001 are assigned only within this export. They are not stable across exports, do not identify a source PDF, and do not prove file integrity. Scanner numbers follow configured scanner order.</p><p class="small">Diagnostics read existing cached data and archive metadata only. They do not reread PDF contents, automatically reclassify files, or upload information.</p></section>')
    $settings=Get-QaDiagnosticValue $Report ReadSettings
    $readerMode=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $settings ReaderMode) @('Auto','Python','Standard') 'Auto'
    $auto=Get-QaDiagnosticValue $settings AutoAnalyze $false;$auto=($auto -is [bool] -and $auto)
    [void]$html.Append('<section class="panel"><h2>Reading and scanner configuration</h2><p>Reader mode: '+(ConvertTo-QaDiagnosticHtmlText $readerMode)+' · Automatic new-text reading: '+(ConvertTo-QaDiagnosticHtmlText $auto)+' · Check interval: '+(ConvertTo-QaDiagnosticHtmlText (Get-QaDiagnosticNumber (Get-QaDiagnosticValue $settings MonitorMinutes 0) 1440))+' minutes · Batch limit: 20 · Support revision: '+(ConvertTo-QaDiagnosticHtmlText (Get-QaDiagnosticNumber (Get-QaDiagnosticValue $settings SupportRevision 0) 99))+'</p><p class="small">A scanner filing rule applies only after a supported complete report format is recognized. Ask leaves the filing choice for review.</p><div class="table-wrap"><table><thead><tr><th>Scanner</th><th>Last connection / reconnect</th><th>Native code</th><th>Sign-in configuration</th><th>Saved reports / findings</th><th>Basic filing</th><th>Extended filing</th><th>Additional filing</th></tr></thead><tbody>')
    $scannerNumber=0;$rules=@(Get-QaDiagnosticValue $Report ScannerRules @())
    foreach($scanner in @(Get-QaDiagnosticValue $Report Scanners @())){
        $scannerNumber++;$state=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $scanner ConnectionAtLastScan) @('Connected','Unavailable','Partial','Issues','Unknown');$recent=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $scanner LatestReconnectStatus) @('Connected','Unavailable','CredentialsRequired','NotConfigured','Unsupported','NotRecorded','Unknown')
        $rule=@($rules|Where-Object{(Get-QaDiagnosticNumber (Get-QaDiagnosticValue $_ ScannerNumber 0) 20) -eq $scannerNumber}|Select-Object -First 1);$basic='Ask';$extended='Ask';$additional='Ask';if($rule.Count){$basic=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $rule[0] BasicRule) @('Ask','Daily','Monthly','Other') 'Ask';$extended=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $rule[0] ExtendedRule) @('Ask','Daily','Monthly','Other') 'Ask';$additional=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $rule[0] AdditionalRule) @('Ask','Daily','Monthly','Other') 'Ask'}
        $username=Get-QaDiagnosticValue $scanner UsernameConfigured $false;$stored=Get-QaDiagnosticValue $scanner SavedSignInFilePresent $false;$username=($username -is [bool] -and $username);$stored=($stored -is [bool] -and $stored)
        $issues=Get-QaDiagnosticValue $scanner ReviewItemCounts;$issueTotal=0;foreach($value in @('Connection','SourceUnavailable','SourceMissing','CopyFailed','Integrity','Audit','Recovery','Classification','MonthlyReview','DailyGap','DailyReview','CoverageUnknown','MonthlyGap','MonthlyPending','MonthlyComponents','MonthlyComponentsMissing','MonthlyChecklist','ChecklistNotSet','MonthlyChecklistNotSet','DuplicateName','MultipleSessions','Deferred','Other')){$issueTotal+=Get-QaDiagnosticNumber (Get-QaDiagnosticValue $issues $value 0)}
        [void]$html.Append('<tr><td>Scanner '+$scannerNumber+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText $state)+' / '+(ConvertTo-QaDiagnosticHtmlText $recent)+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText (Get-QaDiagnosticNumber (Get-QaDiagnosticValue $scanner LatestNativeCode 0) 65535))+'</td><td>Username set '+(ConvertTo-QaDiagnosticHtmlText $username)+' / Saved sign-in present '+(ConvertTo-QaDiagnosticHtmlText $stored)+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText (Get-QaDiagnosticNumber (Get-QaDiagnosticValue $scanner SavedReports 0)))+' / '+(ConvertTo-QaDiagnosticHtmlText $issueTotal)+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText $basic)+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText $extended)+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText $additional)+'</td></tr>')
    }
    [void]$html.Append('</tbody></table></div><p class="small">Historical cache-observation counts in the machine summary do not certify that current PDF bytes were reread. Current per-report diagnostics are the authoritative status snapshot supplied for this export.</p></section>')
    [void]$html.Append('<section class="panel"><h2>How to interpret the work</h2><ul><li>File approval, PDF text reading and measurement extraction are separate states.</li><li>A valid older text cache can still need a measurement upgrade. Reading cached text again is different from choosing its filing rule.</li><li>Standard batches normally attempt at most 20 PDFs, one at a time, and yield between documents. An explicitly started backlog queue can continue through its eligible reports. Automatic new-text batches wait at least five minutes after the previous job finishes.</li><li>Unsupported measurements can mean a missing template, incomplete text, an uncertain date, or no usable row for the selected metric. These are not the same as a PDF opening failure.</li><li>Log storage normally retains 90 days within 50 MB. This is retained history, not a promise that every past operation was recorded. Legacy structured sources are included only when readable and within their safety limits.</li></ul></section>')
    [void]$html.Append('<section class="panel"><h2>Work at export time</h2>')
    if(-not $work.Count){[void]$html.Append('<p>No shareable active-work context was supplied.</p>')}else{[void]$html.Append('<table><thead><tr><th>Work</th><th>Action / status</th><th>Stage</th><th>Progress</th><th>Controls</th></tr></thead><tbody>');foreach($job in $work){[void]$html.Append('<tr><td>'+(ConvertTo-QaDiagnosticHtmlText $job.Reference)+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText $job.Action)+' / '+(ConvertTo-QaDiagnosticHtmlText $job.Status)+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText $job.Stage)+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText $job.Completed)+' / '+(ConvertTo-QaDiagnosticHtmlText $job.Total)+' · '+(ConvertTo-QaDiagnosticHtmlText $job.Failed)+' failed</td><td>Background '+(ConvertTo-QaDiagnosticHtmlText $job.Background)+' · Pause requested '+(ConvertTo-QaDiagnosticHtmlText $job.PauseRequested)+' · Cancel requested '+(ConvertTo-QaDiagnosticHtmlText $job.CancelRequested)+'</td></tr>')};[void]$html.Append('</tbody></table>')}
    [void]$html.Append('</section><section class="panel"><h2>Pending report diagnostics</h2><p>Showing '+$shown.Count+' of '+$pending.Count+' reports with pending filing or diagnostic actions. HTML details are capped at 500; pending filing rows are listed first. The JSONL and CSV in a full support ZIP contain all '+$rows.Count+' report diagnoses.</p>')
    foreach($row in $shown){[void]$html.Append('<article class="report-detail"><h3>'+(ConvertTo-QaDiagnosticHtmlText $row.Reference)+' · '+(ConvertTo-QaDiagnosticHtmlText $row.Scanner)+'</h3><p>Filing: '+(ConvertTo-QaDiagnosticHtmlText $row.FilingStatus)+' / '+(ConvertTo-QaDiagnosticHtmlText $row.Category)+' · Text cache: '+(ConvertTo-QaDiagnosticHtmlText $row.TextCacheStatus)+' (schema '+(ConvertTo-QaDiagnosticHtmlText $row.CacheSchemaVersion)+') · Measurements: '+(ConvertTo-QaDiagnosticHtmlText $row.MeasurementStatus)+' (version '+(ConvertTo-QaDiagnosticHtmlText $row.MeasurementVersion)+')</p><p>Content: '+(ConvertTo-QaDiagnosticHtmlText $row.ContentStatus)+' · Profile: '+(ConvertTo-QaDiagnosticHtmlText $row.Profile)+' · Reader: '+(ConvertTo-QaDiagnosticHtmlText $row.Reader)+'</p><p>Pages read: '+(ConvertTo-QaDiagnosticHtmlText $row.ReadPages)+' / '+(ConvertTo-QaDiagnosticHtmlText $row.TotalPages)+' · '+(ConvertTo-QaDiagnosticHtmlText $row.MeasurementCount)+' measurements · '+(ConvertTo-QaDiagnosticHtmlText $row.ReadMilliseconds)+' ms · Model '+(ConvertTo-QaDiagnosticHtmlText $row.Model)+' · Size '+(ConvertTo-QaDiagnosticHtmlText $row.SizeBand)+' · Content support revision '+(ConvertTo-QaDiagnosticHtmlText $row.ContentSupportRevision)+'</p><ul>');if(-not $row.ReasonCodes.Count){[void]$html.Append('<li>No further shareable reason is available.</li>')};foreach($reason in $row.ReasonCodes){[void]$html.Append('<li><code>'+(ConvertTo-QaDiagnosticHtmlText $reason)+'</code> — '+(ConvertTo-QaDiagnosticHtmlText (Get-QaSupportReasonDescription $reason))+'</li>')};[void]$html.Append('</ul></article>')}
    [void]$html.Append('</section><section class="panel"><h2>Recent activity timeline</h2><p>Showing the most recent '+$events.Count+' of '+$retained+' retained structured events. The printable timeline is capped at 500. Full retained events are included in the ZIP JSONL and CSV files.</p><div class="table-wrap"><table><thead><tr><th>UTC time</th><th>Operation / outcome</th><th>Stage / reason</th><th>Reader / profile</th><th>Scanner</th><th>Duration / code</th><th>Counts</th></tr></thead><tbody>')
    $schema=Get-QaSupportDiagnosticSchema
    foreach($event in $events){
        $time=Get-QaDiagnosticDate (Get-QaDiagnosticValue $event TimeUtc);$operation=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $event Operation) $script:DiagnosticActions;$outcome=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $event Outcome) @('Started','Completed','Failed','Cancelled');$stage=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $event Stage) $script:DiagnosticStages;$reason=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $event Reason) $schema.EventReasons;$reader=Get-QaDiagnosticEnum (Get-QaDiagnosticValue $event Reader) @('Standard','Python','Legacy','Unknown');$profile=Get-QaDiagnosticProfile (Get-QaDiagnosticValue $event Profile)
        $counterLabels=New-Object 'Collections.Generic.List[string]';$incoming=Get-QaDiagnosticValue $event Counts
        foreach($key in @('Total','Copied','Failed','Analyzed','Cached','Pending','MeasurementPending','Unread','MissingRule','Unsupported','Conflicts','Scanners','SavedReports','ReviewItems','Events')){if($null -ne (Get-QaDiagnosticValue $incoming $key $null)){[void]$counterLabels.Add($key+'='+(Get-QaDiagnosticNumber (Get-QaDiagnosticValue $incoming $key 0)))}}
        $controlNote=if($reason -cin @('UserPaused','UserResumed','UserStopped')){Get-QaSupportReasonDescription $reason}else{''}
        [void]$html.Append('<tr><td>'+(ConvertTo-QaDiagnosticHtmlText $time)+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText $operation)+' / '+(ConvertTo-QaDiagnosticHtmlText $outcome)+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText $stage)+' / '+(ConvertTo-QaDiagnosticHtmlText $reason)+$(if($controlNote){'<br><span class="small">'+(ConvertTo-QaDiagnosticHtmlText $controlNote)+'</span>'}else{''})+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText $reader)+' / '+(ConvertTo-QaDiagnosticHtmlText $profile)+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText (Get-QaDiagnosticNumber (Get-QaDiagnosticValue $event ScannerNumber 0) 20))+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText (Get-QaDiagnosticNumber (Get-QaDiagnosticValue $event DurationMs 0) 604800000))+' ms / '+(ConvertTo-QaDiagnosticHtmlText (Get-QaDiagnosticNumber (Get-QaDiagnosticValue $event NativeCode 0) 65535))+'</td><td>'+(ConvertTo-QaDiagnosticHtmlText ($counterLabels -join ', '))+'</td></tr>')
    }
    [void]$html.Append('</tbody></table></div></section><footer>Built from allowlisted statuses, counts and reason codes. Unknown or unsafe input is replaced or omitted; no raw exception messages or log files are copied. Keep the complete support ZIP when sharing machine-readable diagnostics.</footer></body></html>')
    return $html.ToString()
}
Export-ModuleMember -Function Get-QaDiagnosticValue,Get-QaDiagnosticNumber,Get-QaDiagnosticEnum,Get-QaDiagnosticProfile,Get-QaDiagnosticDate,Get-QaSupportDiagnosticSchema,ConvertTo-QaSupportDiagnosticRows,Get-QaSupportCachedDiagnosticRows,ConvertTo-QaSupportWorkRows,Get-QaSupportDiagnosticCounts,ConvertTo-QaSupportReportCsv,ConvertTo-QaSupportHtml
