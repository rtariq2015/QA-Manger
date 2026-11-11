Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Archive.psm1')
Import-Module (Join-Path $PSScriptRoot 'Support.psm1')
Import-Module (Join-Path $PSScriptRoot 'ContentClassifier.psm1')
Import-Module (Join-Path $PSScriptRoot 'MeasurementParser.psm1')
Import-Module (Join-Path $PSScriptRoot 'Process.psm1')

function Get-QaInsightValue {param($Object,[string]$Name,$Default=$null)
    if($null -ne $Object){if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}elseif($null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name}};return $Default
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
function Get-QaDocumentClassificationVersion { return (Get-QaContentClassifierVersion) }
function Get-QaAnalysisReaderMode {
    param($Config)
    $mode=[string](Get-QaInsightValue $Config PdfReaderMode 'Auto')
    if($mode -cnotin @('Auto','Python','Standard')){return 'Auto'}
    return $mode
}
function Get-QaAnalysisVersionValue($Value) {
    $number=0
    if([int]::TryParse([string]$Value,[ref]$number) -and $number -ge 0 -and $number -le 1000000){return $number}
    return 0
}
function Get-QaAnalysisEligibility {
    param($Saved,[switch]$UpgradeMeasurements,[switch]$RefreshUnsupported)
    if($null -eq $Saved){return 'New'}
    if([string](Get-QaInsightValue $Saved Status '') -eq 'ReadError'){return ''}
    $doc=Get-QaInsightValue $Saved DocumentClassification $null
    # Format support changes are incremental. A previously unknown template may
    # be retried once, while already recognized formats keep their valid cache.
    # Do not repeatedly retry read errors, bad dates, incomplete text, or OCR.
    if($RefreshUnsupported -and (Get-QaAnalysisVersionValue (Get-QaInsightValue $Saved ContentSupportRevision 0)) -lt (Get-QaContentSupportRevision) -and [string](Get-QaInsightValue $doc ReasonCode '') -cin @('UnknownTemplate','UnrecognizedSections') -and -not [string](Get-QaInsightValue $doc ProfileId '')){return 'UnsupportedUpgrade'}
    $reference=([string](Get-QaInsightValue $doc ProfileId '') -ceq 'siemens-iec-reference-v1' -or (Get-QaInsightValue $doc IsReference $false) -eq $true -or (Get-QaInsightValue $doc HasReferenceEvidence $false) -eq $true)
    if($UpgradeMeasurements -and -not $reference){
        $measurements=Get-QaInsightValue $Saved MeasurementsDocument $null
        if((Get-QaAnalysisVersionValue (Get-QaInsightValue $measurements MeasurementVersion 0)) -ne (Get-QaMeasurementParserVersion)){return 'MeasurementUpgrade'}
        # Capability upgrades are selective: existing complete HU evidence stays
        # reusable. New Daily/slice tables receive one bounded extraction attempt.
        $supportedNewTable=([string](Get-QaInsightValue $doc ProfileId '') -ceq 'siemens-quality-daily-v1' -or @((Get-QaInsightValue $doc Sections @())|Where-Object{[string](Get-QaInsightValue $_ Code '') -ceq 'Slice'}).Count -gt 0)
        if($supportedNewTable -and (Get-QaAnalysisVersionValue (Get-QaInsightValue $measurements MeasurementSupportRevision 0)) -lt (Get-QaMeasurementSupportRevision)){return 'MeasurementUpgrade'}
    }
    return ''
}
function Select-QaAnalysisRecords {
    param([object[]]$Records=@(),[AllowEmptyCollection()][string[]]$RecordIds=@())
    if(-not $PSBoundParameters.ContainsKey('RecordIds')){return @($Records)}
    if(-not $RecordIds.Count){throw 'Choose at least one saved report to analyze.'}
    $selected=New-Object 'Collections.Generic.List[object]';$ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $byId=@{}
    foreach($record in $Records){$id=[string](Get-QaInsightValue $record Id '');if($byId.ContainsKey($id)){$byId[$id]=$null}else{$byId[$id]=$record}}
    foreach($id in $RecordIds){
        if($id -notmatch '^[0-9A-Fa-f]{64}$'){throw 'Invalid saved report identity.'}
        if(-not $ids.Add($id)){continue}
        if(-not $byId.ContainsKey($id) -or $null -eq $byId[$id]){throw 'The selected report must exist uniquely in the archive.'}
        [void]$selected.Add($byId[$id])
    }
    return @($selected.ToArray())
}
function Get-QaAnalysisWorkPlan {
    [CmdletBinding()]param($Config,[AllowEmptyCollection()][object[]]$Records=@(),[AllowEmptyCollection()][string[]]$RecordIds=@(),[switch]$UpgradeMeasurements,[switch]$RefreshUnsupported,[ValidateRange(1,100000)][int]$Limit=20)
    if(-not $PSBoundParameters.ContainsKey('Records')){$Records=@((Get-QaDashboard -Config $Config).Records)}
    $ordered=@($Records|Sort-Object ReportDate -Descending)
    if($PSBoundParameters.ContainsKey('RecordIds')){$ordered=@(Select-QaAnalysisRecords -Records $ordered -RecordIds $RecordIds)}
    $next=New-Object 'Collections.Generic.List[string]';$cached=0;$errors=0;$new=0;$measurements=0;$unsupported=0
    foreach($record in $ordered){
        $saved=Get-QaSavedAnalysis $Config $record
        if($null -ne $saved){$cached++;if([string](Get-QaInsightValue $saved Status '') -eq 'ReadError'){$errors++}}
        $reason=Get-QaAnalysisEligibility -Saved $saved -UpgradeMeasurements:$UpgradeMeasurements -RefreshUnsupported:$RefreshUnsupported
        switch($reason){'New'{$new++}'MeasurementUpgrade'{$measurements++}'UnsupportedUpgrade'{$unsupported++}}
        if($reason -and $next.Count -lt $Limit){[void]$next.Add([string]$record.Id)}
    }
    return [pscustomobject]@{Total=$ordered.Count;Saved=$cached;Cached=$cached;Errors=$errors;NewPending=$new;MeasurementUpgradePending=$measurements;UnsupportedUpgradePending=$unsupported;Pending=($new+$measurements+$unsupported);RecordIds=@($next.ToArray())}
}
function Test-QaAnalysisSelectedRefresh {
    param($Config,$Record)
    $saved=Get-QaSavedAnalysis $Config $Record
    if($null -eq $saved){return $false}
    return ([string](Get-QaInsightValue $saved RequestedReaderMode '') -cne (Get-QaAnalysisReaderMode $Config) -or (Get-QaAnalysisEligibility -Saved $saved -UpgradeMeasurements -RefreshUnsupported) -cin @('MeasurementUpgrade','UnsupportedUpgrade'))
}
function Get-QaAnalysisMetadata {
    param([string]$Path)
    $info=New-Object IO.FileInfo($Path);$info.Refresh()
    if($info.Exists -and (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Linked saved PDFs cannot provide analysis provenance.'}
    return [pscustomobject]@{Length=$(if($info.Exists){[long]$info.Length}else{[long]-1});WriteTicks=[IO.File]::GetLastWriteTimeUtc($Path).Ticks;Exists=[bool]$info.Exists}
}
function Get-QaSavedAnalysis {
    param($Config,$Record)
    $hash=[string](Get-QaInsightValue $Record Hash '');if($hash -notmatch '^[0-9A-Fa-f]{64}$'){return $null}
    $path=Join-Path (Join-Path $Config.ArchiveRoot '.ctqa/analysis') ($hash+'.json')
    if([IO.File]::Exists($path)) {
        try {
            $ancestor=[IO.Path]::GetFullPath($path)
            while($ancestor){if(([IO.File]::Exists($ancestor) -or [IO.Directory]::Exists($ancestor)) -and (([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){return $null};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
            $saved=[IO.File]::ReadAllText($path)|ConvertFrom-Json
            $id=[string](Get-QaInsightValue $Record Id '');$row=$saved
            # Equal-content PDFs can occupy several archive destinations. Retain a
            # separate captured provenance row for each, instead of ping-ponging
            # one timestamp between them on every background pass.
            $savedId=[string](Get-QaInsightValue $saved RecordId '')
            if($savedId -and $savedId -ne $id){
                $matches=@(Get-QaInsightValue $saved OtherRecords @()|Where-Object{[string](Get-QaInsightValue $_ RecordId '') -eq $id})
                if($matches.Count -ne 1){return $null};$row=$matches[0]
            }
            if([int](Get-QaInsightValue $row ParserVersion 0) -ne 1 -or [string](Get-QaInsightValue $row Hash '') -ne $hash){return $null}
            $metadata=Get-QaAnalysisMetadata ([string]$Record.DestinationPath)
            # Legacy failed reads are deliberately retained until their file
            # changes or the user explicitly retries. Version rollout must not
            # turn an unreadable PDF into a repeated background task.
            if([string](Get-QaInsightValue $row Status '') -eq 'ReadError'){
                $ticks=Get-QaInsightValue $row SavedWriteTicks $null
                $length=Get-QaInsightValue $row SavedLength $null
                if($null -ne $ticks -and [long]$ticks -eq $metadata.WriteTicks -and ($null -eq $length -or [long]$length -eq $metadata.Length)){return $row}
                return $null
            }
            $version=Get-QaDocumentClassificationVersion
            $classification=Get-QaInsightValue $row DocumentClassification $null
            if([int](Get-QaInsightValue $row AnalysisCacheSchemaVersion 0) -notin @(2,3) -or [int](Get-QaInsightValue $row DocumentClassifierVersion 0) -ne $version -or $null -eq $classification -or [int](Get-QaInsightValue $classification ClassifierVersion 0) -ne $version){return $null}
            if([string](Get-QaInsightValue $row VerifiedHash '') -ne $hash -or [string](Get-QaInsightValue $row RecordId '') -ne $id){return $null}
            $length=[long](Get-QaInsightValue $row VerifiedLength -1);$ticks=[long](Get-QaInsightValue $row VerifiedWriteTicks 0)
            if(-not $metadata.Exists -or $length -ne [long](Get-QaInsightValue $Record Length -2) -or $length -ne $metadata.Length -or $ticks -le 0 -or $ticks -ne $metadata.WriteTicks){return $null}
            return $row
        }catch{}
    }
    return $null
}
function Set-QaAnalysisWorkProgress {
    param($Progress,[int]$Completed,[int]$Total)
    if($null -eq $Progress){return}
    $values=@{Stage='Analyzing';Completed=$Completed;Total=$Total;Percent=$(if($Total -gt 0){100.0*$Completed/$Total}else{-1});Message=('Reading saved PDF text: '+$Completed+' of '+$Total+' in this batch.')}
    foreach($key in $values.Keys){if($Progress -is [Collections.IDictionary]){$Progress[$key]=$values[$key]}else{$Progress|Add-Member -NotePropertyName $key -NotePropertyValue $values[$key] -Force}}
}
function Invoke-QaAnalysis {
    [CmdletBinding()]param($Config,$Progress=$null,[int]$Limit=20,[string[]]$RecordIds=@(),[switch]$Force,[switch]$UpgradeMeasurements,[switch]$RefreshUnsupported,[AllowEmptyCollection()][object[]]$Records=@())
    if(-not $PSBoundParameters.ContainsKey('Records')){$Records=@((Get-QaDashboard -Config $Config).Records)}
    $done=0;$skipped=0;$failed=0;$cancelled=$false;$requestedReader=Get-QaAnalysisReaderMode $Config
    $root=Join-Path $Config.ArchiveRoot '.ctqa/analysis'
    $records=@($Records|Sort-Object ReportDate -Descending)
    if($PSBoundParameters.ContainsKey('RecordIds')){$records=@(Select-QaAnalysisRecords -Records $records -RecordIds $RecordIds)}
    $analyzedIds=New-Object 'Collections.Generic.List[string]'
    # Determine this bounded batch once, without reopening already cached PDF text.
    $candidates=New-Object 'Collections.Generic.List[object]'
    Set-QaAnalysisWorkProgress $Progress 0 0
    foreach($record in $records){
        if([bool](Get-QaInsightValue $Progress Cancel $false)){$cancelled=$true;break}
        $saved=Get-QaSavedAnalysis $Config $record
        $reason=Get-QaAnalysisEligibility -Saved $saved -UpgradeMeasurements:$UpgradeMeasurements -RefreshUnsupported:$RefreshUnsupported
        if(-not $Force -and -not $reason){$skipped++;continue}
        if($candidates.Count -lt [math]::Max(0,$Limit)){[void]$candidates.Add($record)}
    }
    # Content classification is derived evidence. It never writes a clinical
    # review, changes the archive category, or supplies a Monthly checklist.
    foreach($record in $candidates) {
        if([bool](Get-QaInsightValue $Progress Cancel $false)){$cancelled=$true;break}
        Set-QaAnalysisWorkProgress $Progress ($done+$failed) $candidates.Count
        $readClock=[Diagnostics.Stopwatch]::StartNew();$source=@($Config.Sources|Where-Object Scanner -eq $record.Scanner|Select-Object -First 1);$number=0;if($source.Count){$number=1+[Array]::IndexOf([object[]]$Config.Sources,$source[0])}
        $eventReader='Unknown';$eventProfile='Unknown';$eventReason='ReadCompleted'
        Write-QaSupportEvent -AppRoot $Config.AppRoot -Operation PdfRead -Outcome Started -ScannerNumber $number -Stage Analyzing -Reason ReadStarted -Reader Unknown -Profile Unknown
        try {
            $before=Get-QaAnalysisMetadata ([string]$record.DestinationPath)
            $read=Invoke-QaIsolatedTask -Action ReadPdf -InputObject ([pscustomobject]@{Config=$Config;RecordId=$record.Id;Reader=$requestedReader}) -TimeoutSeconds 90 -Progress $Progress
            $observedReader=[string](Get-QaInsightValue $read ReaderUsed '');if($observedReader -cin @('Standard','Python','Legacy')){$eventReader=$observedReader}
            if([bool](Get-QaInsightValue (Get-QaInsightValue $read Summary $null) Cancelled $false) -or [bool](Get-QaInsightValue $Progress Cancel $false)){
                $cancelled=$true;Write-QaSupportEvent -AppRoot $Config.AppRoot -Operation PdfRead -Outcome Cancelled -ScannerNumber $number -DurationMs $readClock.ElapsedMilliseconds -Stage Analyzing -Reason WorkerCancelled -Reader $eventReader -Profile $eventProfile;break
            }
            $after=Get-QaAnalysisMetadata ([string]$record.DestinationPath)
            $verifiedHash=[string](Get-QaInsightValue $read VerifiedHash '');$verifiedLength=[long](Get-QaInsightValue $read VerifiedLength -1);$verifiedTicks=[long](Get-QaInsightValue $read VerifiedWriteTicks 0)
            if($verifiedHash -notmatch '^[0-9A-Fa-f]{64}$' -or $verifiedHash -ne [string]$record.Hash -or $verifiedLength -ne [long]$record.Length -or -not $before.Exists -or -not $after.Exists -or $verifiedLength -ne $before.Length -or $verifiedLength -ne $after.Length -or $verifiedTicks -le 0 -or $verifiedTicks -ne $before.WriteTicks -or $verifiedTicks -ne $after.WriteTicks){throw 'The saved PDF changed or the reader did not return matching verified provenance. Run an integrity audit before retrying.'}
            $row=ConvertFrom-QaReportText -Text ([string]$read.Text) -Truncated ([bool]$read.Truncated)
            $classification=ConvertFrom-QaDocumentContent -Text ([string]$read.Text) -Truncated ([bool]$read.Truncated) -NeedsOCR ([bool]$read.NeedsOCR) -Pages ([int]$read.Pages) -ReadPages ([int]$read.ReadPages)
            $classification|Add-Member -NotePropertyName Pages -NotePropertyValue ([int]$read.Pages) -Force;$classification|Add-Member -NotePropertyName ReadPages -NotePropertyValue ([int]$read.ReadPages) -Force;$classification|Add-Member -NotePropertyName NeedsOCR -NotePropertyValue ([bool]$read.NeedsOCR) -Force
            $measurements=ConvertFrom-QaMeasurementText -Text ([string]$read.Text) -Truncated ([bool]$read.Truncated) -NeedsOCR ([bool]$read.NeedsOCR) -Pages ([int]$read.Pages) -ReadPages ([int]$read.ReadPages)
            $eventProfile=switch([string]$classification.ProfileId){'siemens-iec-basic-v1'{'Basic'}'siemens-iec-extended-v1'{'Extended'}'siemens-iec-additional-v1'{'Additional'}'siemens-quality-daily-v1'{'Daily'}'siemens-iec-reference-v1'{'Reference'}default{'Unknown'}}
            $documentReason=[string]$classification.ReasonCode;$measurementReason=[string]$measurements.ReasonCode
            if($documentReason -ceq 'SupportedProfile' -and $measurementReason -cin @('NoReadableText','InputLimit','UnsupportedProfile','NoSupportedTables','MeasurementReviewNeeded','SupportedPrintedValues')){$eventReason=$measurementReason}elseif($documentReason -cin @('SupportedProfile','UnknownTemplate','IncompleteRead','UncertainReportDate','ConflictingExplicitTitles','UnrecognizedSections','ReferenceDocument')){$eventReason=$documentReason}
            $row|Add-Member MeasurementsDocument $measurements
            $row|Add-Member ContentSupportRevision (Get-QaContentSupportRevision)
            $readerUsed=[string](Get-QaInsightValue $read ReaderUsed 'Legacy');if($readerUsed -cnotin @('Python','Standard')){$readerUsed='Legacy'}
            $row|Add-Member ReaderUsed $readerUsed;$row|Add-Member ReaderVersion ([string](Get-QaInsightValue $read ReaderVersion ''));$row|Add-Member ReaderElapsedMs ([long]$readClock.ElapsedMilliseconds);$row|Add-Member RequestedReaderMode $requestedReader
            $row|Add-Member ReaderFallbackReason ([string](Get-QaInsightValue $read FallbackReason ''))
            $row|Add-Member Hash ([string]$record.Hash);$row|Add-Member RecordId ([string]$record.Id);$row|Add-Member ReadUtc ([datetime]::UtcNow.ToString('o'))
            $row|Add-Member AnalysisCacheSchemaVersion 3;$row|Add-Member DocumentClassifierVersion (Get-QaDocumentClassificationVersion);$row|Add-Member DocumentClassification $classification
            $row|Add-Member VerifiedHash $verifiedHash;$row|Add-Member VerifiedLength $verifiedLength;$row|Add-Member VerifiedWriteTicks $verifiedTicks
            $row|Add-Member ReaderMessage ([string]$read.Message)
            $row|Add-Member SavedWriteTicks $verifiedTicks;$row|Add-Member SavedLength $verifiedLength
            if([bool](Get-QaInsightValue $Progress Cancel $false)){$cancelled=$true;Write-QaSupportEvent -AppRoot $Config.AppRoot -Operation PdfRead -Outcome Cancelled -ScannerNumber $number -DurationMs $readClock.ElapsedMilliseconds -Stage Analyzing -Reason WorkerCancelled -Reader $eventReader -Profile $eventProfile;break}
            Write-QaAnalysisFile -Root $root -Hash $record.Hash -Value $row
            $done++;[void]$analyzedIds.Add([string]$record.Id)
            Write-QaSupportEvent -AppRoot $Config.AppRoot -Operation PdfRead -Outcome Completed -ScannerNumber $number -DurationMs $readClock.ElapsedMilliseconds -Stage Analyzing -Reason $eventReason -Reader $eventReader -Profile $eventProfile -Counts @{Analyzed=1;Truncated=[int][bool]$row.Truncated;PrintedPass=[int]($row.Status -eq 'ReportedPass');PrintedFailure=[int]($row.Status -eq 'ReportedFailure');NeedsReview=[int]($row.Status -eq 'NeedsReview')}
        } catch {
            if([bool](Get-QaInsightValue $Progress Cancel $false) -or $_.Exception -is [OperationCanceledException]){$cancelled=$true;Write-QaSupportEvent -AppRoot $Config.AppRoot -Operation PdfRead -Outcome Cancelled -ScannerNumber $number -DurationMs $readClock.ElapsedMilliseconds -Stage Analyzing -Reason WorkerCancelled -Reader $eventReader -Profile $eventProfile;break}
            Write-QaSupportEvent -AppRoot $Config.AppRoot -Operation PdfRead -Outcome Failed -ScannerNumber $number -DurationMs $readClock.ElapsedMilliseconds -Stage Analyzing -Reason ReadFailed -Reader $eventReader -Profile $eventProfile -ErrorKind (Get-QaSupportErrorKind $_.Exception.Message) -Counts @{ReadErrors=1}
            $failed++
            # Failure observations are not successful read provenance. They only
            # prevent repeated background retries until a file changes.
            $observed=Get-QaAnalysisMetadata ([string]$record.DestinationPath)
            $row=[pscustomobject]@{AnalysisCacheSchemaVersion=3;ContentSupportRevision=(Get-QaContentSupportRevision);RequestedReaderMode=$requestedReader;ParserVersion=1;Hash=[string]$record.Hash;RecordId=[string]$record.Id;Status='ReadError';Truncated=$true;Findings=@();ReadUtc=[datetime]::UtcNow.ToString('o');ReaderMessage='The saved PDF could not be read and verified. Check the PDF, reader components, and archive integrity before retrying.';SavedWriteTicks=$observed.WriteTicks;SavedLength=$observed.Length}
            Write-QaAnalysisFile -Root $root -Hash $record.Hash -Value $row
        }
    }
    Set-QaAnalysisWorkProgress $Progress ($done+$failed) $candidates.Count
    if([bool](Get-QaInsightValue $Progress Cancel $false)){$cancelled=$true}
    return [pscustomobject]@{Mode='Analysis';Summary=[pscustomobject]@{Description=($done.ToString()+' PDFs analyzed; '+$skipped+' cached; '+$failed+' need review. No reviewed labels changed.');Cancelled=$cancelled};Analyzed=$done;AnalyzedIds=@($analyzedIds.ToArray());Failed=$failed;Cached=$skipped;Pending=[math]::Max(0,($records.Count-$done-$failed-$skipped))}
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
        # Preserve independently verified destinations sharing the same bytes.
        # Each stored row is flat: no recursive history or duplicated PDF text.
        $others=New-Object 'Collections.Generic.List[object]'
        if([IO.File]::Exists($path)){
            try{
                $previous=[IO.File]::ReadAllText($path)|ConvertFrom-Json
                foreach($entry in @($previous)+@(Get-QaInsightValue $previous OtherRecords @())){
                    $entryId=[string](Get-QaInsightValue $entry RecordId '')
                    if($entryId -match '^[0-9A-Fa-f]{64}$' -and $entryId -ne [string]$Value.RecordId -and [string](Get-QaInsightValue $entry Hash '') -eq $Hash){[void]$others.Add(($entry|Select-Object * -ExcludeProperty OtherRecords))}
                }
            }catch{}
        }
        $Value|Add-Member -NotePropertyName OtherRecords -NotePropertyValue @($others.ToArray()) -Force
        [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($true)))
        if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,($temp+'.bak'));[IO.File]::Delete($temp+'.bak')}else{[IO.File]::Move($temp,$path)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Get-QaAnalysisProgress {
    [CmdletBinding()]param($Config,[object[]]$Records=@())
    $plan=Get-QaAnalysisWorkPlan -Config $Config -Records $Records -UpgradeMeasurements -RefreshUnsupported
    return [pscustomobject]@{Total=$plan.Total;Cached=$plan.Cached;Pending=$plan.NewPending;Errors=$plan.Errors;Saved=$plan.Saved;NewPending=$plan.NewPending;MeasurementUpgradePending=$plan.MeasurementUpgradePending;UnsupportedUpgradePending=$plan.UnsupportedUpgradePending;BacklogPending=$plan.Pending}
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
Export-ModuleMember -Function Get-QaAnalysisWorkPlan,Get-QaAnalysisReaderMode,Test-QaAnalysisSelectedRefresh,Get-QaDocumentClassificationVersion,ConvertFrom-QaReportText,Get-QaSavedAnalysis,Invoke-QaAnalysis,Get-QaTodayOverview,Get-QaAnalysisProgress,Get-QaMonthOverview,Invoke-QaSourceAudit
