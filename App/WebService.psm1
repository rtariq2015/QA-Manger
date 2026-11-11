# Offline HTML application adapter. Organization decisions are not clinical review.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
foreach($name in @('Archive','Workspace','Review','Network','Credentials','Insights','Reports','Maintenance','Support','Updates','PdfPreview','ContentClassifier')){Import-Module (Join-Path $PSScriptRoot ($name+'.psm1')) -DisableNameChecking -WarningAction SilentlyContinue}
function Get-QaWebValue($Object,[string]$Name,$Default=$null){
    if($null -eq $Object){return $Default};if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}elseif($null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name};return $Default
}
function Assert-QaWebDirect([string]$Path){
    $p=[IO.Path]::GetFullPath($Path)
    while($p){if(([IO.File]::Exists($p) -or [IO.Directory]::Exists($p)) -and (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Use a direct local folder, not a link or junction.'};$p=[IO.Path]::GetDirectoryName($p)}
}
function Write-QaWebAtomic([string]$Path,$Object){
    Assert-QaWebDirect $Path;Assert-QaWebDirect ($Path+'.bak');[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));$temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllText($temp,($Object|ConvertTo-Json -Depth 32),(New-Object Text.UTF8Encoding $true));if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,($Path+'.bak'))}else{[IO.File]::Move($temp,$Path)}}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Get-QaWebHash([string]$Text){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','')}finally{$sha.Dispose()}}
function Assert-QaWebOrganizationEntry($Entry){
    if($null -eq $Entry){return}
    foreach($name in @('id','hash','revision','decision','category')){if($null -eq $Entry.PSObject.Properties[$name]){throw 'The file-organization history contains an incomplete entry. It was preserved.'}}
    if([string]$Entry.id -notmatch '^[a-fA-F0-9]{64}$' -or [string]$Entry.hash -notmatch '^[a-fA-F0-9]{64}$' -or [string]$Entry.revision -notmatch '^[a-fA-F0-9]{32}$' -or [string]$Entry.decision -cnotin @('','Approved','Disapproved') -or [string]$Entry.category -cnotin @('','Daily','Monthly','Other')){throw 'The file-organization history contains unsupported values. It was preserved.'}
    if($Entry.decision -and -not $Entry.category){throw 'The file-organization history has a missing document type. It was preserved.'}
}
function Get-QaWebOrganization($Config){
    $path=Join-Path $Config.ArchiveRoot '.ctqa/organization.json';Assert-QaWebDirect $path
    if(-not [IO.File]::Exists($path)){return [pscustomobject]@{Version=1;Records=@();History=@()}}
    try{$state=[IO.File]::ReadAllText($path)|ConvertFrom-Json}catch{throw 'The file-organization history could not be read. It was preserved; restore its verified backup before making further decisions.'}
    if($state.Version -ne 1 -or $null -eq $state.PSObject.Properties['Records'] -or $null -eq $state.PSObject.Properties['History']){throw 'Unsupported file-organization history. No data was changed.'}
    $seen=@{};foreach($entry in @($state.Records)){Assert-QaWebOrganizationEntry $entry;if($seen.ContainsKey([string]$entry.id)){throw 'The file-organization history contains duplicate report entries.'};$seen[[string]$entry.id]=$true}
    foreach($history in @($state.History)){if([string]$history.reviewId -notmatch '^[a-fA-F0-9]{32}$' -or [string]$history.recordId -notmatch '^[a-fA-F0-9]{64}$' -or [string]$history.action -cnotin @('Approve','Disapprove','Undo')){throw 'The file-organization action history contains unsupported values.'};Assert-QaWebOrganizationEntry $history.before;Assert-QaWebOrganizationEntry $history.after}
    return $state
}
function Get-QaWebEntry($Organization,$Record){$entries=@($Organization.Records|Where-Object{[string]$_.id -ceq [string]$Record.Id -and [string]$_.hash -ceq [string]$Record.Hash});if($entries.Count -gt 1){throw 'A report has conflicting organization records.'};if($entries.Count){return $entries[0]};return $null}
function Get-QaWebStamp($Record,$Entry,$ContentContext=$null){$value=(Get-QaRecordReviewStamp $Record)+'|'+[string](Get-QaWebValue $Entry revision '')+'|'+[string](Get-QaWebValue $Entry decision '')+'|'+[string](Get-QaWebValue $Entry category '');$tag=[string](Get-QaWebValue $ContentContext stamp '');if($tag){$value+='|'+$tag};return Get-QaWebHash $value}
function Get-QaWebCategory($Record,$Entry){
    if([string](Get-QaWebValue $Entry decision '') -in @('Approved','Disapproved')){return [string]$Entry.category}
    switch([string]$Record.Category){'Daily_QA'{return 'Daily'}'Monthly_QA'{return 'Monthly'}'Monthly_QA/Pending_Verification'{return 'Monthly'}default{return 'Other'}}
}
function ConvertTo-QaWebContentProfiles($Values){
    $rows=New-Object 'Collections.Generic.List[object]';$seen=@{}
    foreach($item in @($Values)){
        if($null -eq $item){continue}
        $id=[string](Get-QaWebValue $item profileId '');$category=[string](Get-QaWebValue $item category '')
        if($id -cnotin @('siemens-iec-basic-v1','siemens-iec-extended-v1') -or $seen.ContainsKey($id) -or $category -cnotin @('','Daily','Monthly','Other')){throw 'Choose one supported report-format rule for each layout.'}
        $seen[$id]=$true;[void]$rows.Add([pscustomobject]@{profileId=$id;category=$category})
    }
    if($rows.Count -gt 2){throw 'Only the two supported report-format rules can be saved.'}
    return @($rows.ToArray())
}
function Get-QaWebContentContext($Config,$Record){
    $date=[string]$Record.ReportDate;$time=[string]$Record.ReportTime
    $view=[pscustomobject]@{status='NotRead';profileId='';profileName='';date='';time='';dateStatus='Missing';reason='Read this PDF to look for a supported report format.';mappedCategory='';suggestedCategory='';components=@();readPages=0;pages=0;completeRead=$false;reader=[pscustomobject]@{name='';version='';elapsedMs=0;fallback=$false};measurements=@();measurementStatus='NotRead'}
    $context=[pscustomobject]@{view=$view;profileUsable=$false;dateConflict=$false;typeConflict=$false;dateSafe=$false;effectiveDate=$date;effectiveTime=$time;mappedCategory='';explicitCategory='';suggestedCategory='';stamp=''}
    $analysis=Get-QaSavedAnalysis -Config $Config -Record $Record
    if($null -eq $analysis){return $context}
    $reader=[string](Get-QaWebValue $analysis ReaderUsed 'Legacy');if($reader -cnotin @('Python','Standard')){$reader='Legacy'}
    $readerVersion=[string](Get-QaWebValue $analysis ReaderVersion '');if($readerVersion.Length -gt 64 -or $readerVersion -notmatch '^[A-Za-z0-9 ._+/;-]*$'){$readerVersion=''}
    $readerMs=[long]0;[void][long]::TryParse([string](Get-QaWebValue $analysis ReaderElapsedMs 0),[ref]$readerMs);if($readerMs -lt 0 -or $readerMs -gt 3600000){$readerMs=0}
    $view.reader=[pscustomobject]@{name=$reader;version=$readerVersion;elapsedMs=$readerMs;fallback=([string](Get-QaWebValue $analysis ReaderFallbackReason '') -cin @('PythonUnavailable','PythonReadError','PythonNoText','StandardReadError','StandardNoText'))}
    $measured=Get-QaWebValue $analysis MeasurementsDocument $null
    if([int](Get-QaWebValue $measured MeasurementVersion 0) -eq 1){
        $view.measurementStatus=if([string](Get-QaWebValue $measured Status '') -ceq 'Extracted'){'Read'}else{'NeedsReview'}
        $measurementRows=New-Object 'Collections.Generic.List[object]'
        foreach($item in @(Get-QaWebValue $measured Measurements @()|Select-Object -First 100)){
            $code=[string](Get-QaWebValue $item Code '');if($code -cnotin @('WaterCTNumber','ImageNoise')){continue}
            $value=[string](Get-QaWebValue $item Value '');$unit=[string](Get-QaWebValue $item Unit '');$page=[int](Get-QaWebValue $item Page 0)
            $numeric='^[+-]?(?:[0-9]{1,9}(?:\.[0-9]{1,9})?|\.[0-9]{1,9})$'
            if($value -notmatch $numeric -or $unit -cne 'HU' -or $page -lt 1 -or $page -gt 1000){continue}
            $lower=[string](Get-QaWebValue $item LowerLimit '');$upper=[string](Get-QaWebValue $item UpperLimit '')
            if(($lower -and $lower -notmatch $numeric) -or ($upper -and $upper -notmatch $numeric)){$lower='';$upper=''}
            $parts=New-Object 'Collections.Generic.List[string]'
            $mode=[string](Get-QaWebValue $item Mode '');if($mode -cin @('Head','Body')){[void]$parts.Add($mode)}
            $system=[string](Get-QaWebValue $item SourceSystem '');if($system -cin @('A','B')){[void]$parts.Add(('System '+$system))}
            $slice=[string](Get-QaWebValue $item Slice '');if($slice -cmatch '^[1-9][0-9]{0,2}$'){[void]$parts.Add(('Slice '+$slice))}
            [void]$measurementRows.Add([pscustomobject]@{label=$(if($code -ceq 'WaterCTNumber'){'Water CT value'}else{'Image noise'});value=$value;unit=$unit;page=$page;lower=$lower;upper=$upper;context=($parts -join ' / ')})
        }
        $view.measurements=@($measurementRows.ToArray())
    }
    if([string](Get-QaWebValue $analysis Status '') -eq 'ReadError'){$view.status='ReadError';$view.reason='This PDF could not be read. Open the original PDF or retry reading it.';return $context}
    $doc=Get-QaWebValue $analysis DocumentClassification
    if($null -eq $doc -or [int](Get-QaWebValue $doc ClassifierVersion 0) -ne 1){return $context}
    $profile=[string](Get-QaWebValue $doc ProfileId '');$status=[string](Get-QaWebValue $doc Status 'NeedsReview')
    $view.status=if([bool](Get-QaWebValue $doc NeedsOCR $false)){'NeedsOCR'}elseif($status -ceq 'Recognized'){'Recognized'}else{'NeedsReview'}
    $view.profileId=$profile;$view.profileName=[string](Get-QaWebValue $doc ProfileName '');$view.reason=[string](Get-QaWebValue $doc Reason 'The report format needs review.')
    $view.dateStatus=[string](Get-QaWebValue $doc DateStatus 'Missing');$view.readPages=[int](Get-QaWebValue $doc ReadPages 0);$view.pages=[int](Get-QaWebValue $doc Pages 0);$view.completeRead=[bool](Get-QaWebValue $doc CompleteRead $false)
    $view.suggestedCategory=[string](Get-QaWebValue $doc SuggestedCategory '');if($view.suggestedCategory -cnotin @('Daily','Monthly','Other')){$view.suggestedCategory=''}
    $names=@{};foreach($definition in @(Get-QaContentSectionDefinitions)){$names[[string]$definition.Code]=[string]$definition.Name}
    $components=New-Object 'Collections.Generic.List[object]'
    foreach($section in @(Get-QaWebValue $doc Sections @())){
        $code=[string](Get-QaWebValue $section Code '');if(-not $names.ContainsKey($code)){continue}
        $printed=@(Get-QaWebValue $section PrintedOutcomes @()|ForEach-Object{([regex]::Replace([string]$_,'\s+',' ')).Trim().ToUpperInvariant()}|Where-Object{[string]$_ -cmatch '^(OK|NOT OK|NOT EVALUATED|PASS|PASSED|FAIL|FAILED|ERROR|WARNING|UNKNOWN)$'}|Select-Object -Unique)
        [void]$components.Add([pscustomobject]@{name=$names[$code];result=$(if($printed.Count){$printed -join ' / '}else{'No printed result recognized'});page=[int](Get-QaWebValue $section Page 0)})
    };$view.components=@($components.ToArray())
    $printedDate=[string](Get-QaWebValue $doc ReportDate '');$printedTime=[string](Get-QaWebValue $doc ReportTime '');$parsed=[datetime]::MinValue
    $validDate=($view.dateStatus -ceq 'Consensus' -and [datetime]::TryParseExact(($printedDate+' '+$printedTime),'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed) -and $parsed -le (Get-Date).AddDays(1))
    if($validDate){
        $view.date=$printedDate;$view.time=$printedTime
        $context.dateConflict=(($date -and $date -cne $printedDate) -or ($time -and $time -cne $printedTime))
        if(-not $context.dateConflict){$context.effectiveDate=$printedDate;$context.effectiveTime=$printedTime;$context.dateSafe=$true}
    }elseif($view.dateStatus -eq 'Missing' -and $date -match '^\d{4}-\d{2}-\d{2}$'){$context.dateSafe=$true}
    elseif($view.dateStatus -in @('Conflict','Invalid')){$context.dateConflict=$true}
    if($context.dateConflict){$view.status='NeedsReview';$view.dateStatus='Conflict';$view.reason='The report date conflicts with its saved date or other pages. Inspect the original PDF before filing it.'}
    $source=@($Config.Sources|Where-Object Scanner -ceq $Record.Scanner|Select-Object -First 1)
    if($source.Count){
        $rules=@(Get-QaWebValue $source[0] ContentProfiles @()|Where-Object{[string](Get-QaWebValue $_ profileId '') -ceq $profile})
        if($rules.Count -eq 1){$mapped=[string](Get-QaWebValue $rules[0] category '');if($mapped -cin @('Daily','Monthly','Other')){$context.mappedCategory=$mapped;$view.mappedCategory=$mapped}}
    }
    $context.profileUsable=($status -ceq 'Recognized' -and $view.completeRead -and $profile -cin @('siemens-iec-basic-v1','siemens-iec-extended-v1'))
    $titleCategory=[string](Get-QaWebValue $doc Category '');if($titleCategory -cin @('Daily','Monthly')){$context.explicitCategory=$titleCategory;$view.suggestedCategory=$titleCategory}
    $context.suggestedCategory=$view.suggestedCategory
    if($context.mappedCategory -and $context.explicitCategory -and $context.mappedCategory -cne $context.explicitCategory){$context.typeConflict=$true;$view.status='NeedsReview';$view.reason='The explicit report title and saved report-format rule disagree. Inspect the PDF before choosing a label.'}
    $explicit='';$name=[string]$Record.OriginalFileName
    if($name -match '(?i)^(?:.*_)?(?:DAILY|QUALITYDAILY)_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.pdf$'){$explicit='Daily'}
    elseif($name -match '(?i)(?:^|_)MONTHLY(?:_|$)'){$explicit='Monthly'}
    $contentType=if($context.mappedCategory){[string]$context.mappedCategory}else{[string]$context.explicitCategory};if($context.profileUsable -and $contentType -and $explicit -and $explicit -cne $contentType){$context.typeConflict=$true;$view.status='NeedsReview';$view.reason='The explicit filename and configured report-content type disagree. Inspect the PDF before choosing a label.'}
    if($context.profileUsable -and -not $context.mappedCategory -and -not $context.explicitCategory -and -not $context.dateConflict){$view.reason+=' Choose Daily, Monthly or Other for this report format in scanner settings, or approve this file individually.'}
    $context.stamp=Get-QaWebHash (($profile,[string]$view.status,[string]$view.dateStatus,[string]$context.effectiveDate,[string]$context.effectiveTime,[string]$context.mappedCategory,[string]$context.suggestedCategory,[string]$context.dateConflict,[string]$context.typeConflict,[string]$context.dateSafe,[string]$view.completeRead) -join '|')
    return $context
}
function Get-QaWebEffectiveRecord($Record,$Context){
    if($null -eq $Context -or ([string]$Record.ReportDate -ceq [string]$Context.effectiveDate -and [string]$Record.ReportTime -ceq [string]$Context.effectiveTime)){return $Record}
    $copy=$Record|Select-Object *;$copy.ReportDate=[string]$Context.effectiveDate;$copy.ReportTime=[string]$Context.effectiveTime;return $copy
}

function Get-QaWebEntryIndex($Organization){$index=@{};foreach($entry in @($Organization.Records)){$index[[string]$entry.id]=$entry};return $index}
function Get-QaWebIndexedEntry($Index,$Record){if($Index.ContainsKey([string]$Record.Id)){$entry=$Index[[string]$Record.Id];if([string]$entry.hash -ceq [string]$Record.Hash){return $entry}};return $null}
function Get-QaWebClassification($Record,$Entry,$ContentContext=$null){
    $category=Get-QaWebCategory $Record $Entry;$decision=[string](Get-QaWebValue $Entry decision '')
    if($decision -in @('Approved','Disapproved')){return [pscustomobject]@{category=$category;pending=$false;decision=$decision;source='user';reason='Saved file-organization decision. Clinical results are separate.'}}
    $legacyName=[string](Get-QaWebValue $Record ConfirmedBy '');$legacyTime=[string](Get-QaWebValue $Record ConfirmedAt '');$parsed=[datetime]::MinValue
    $validLegacy=($legacyName.Trim() -and [datetime]::TryParse($legacyTime,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed))
    $legacyDecision=[string](Get-QaWebValue $Record ReviewDecision '')
    if($validLegacy -and $legacyDecision -eq 'Declined'){return [pscustomobject]@{category=$category;pending=$false;decision='Disapproved';source='legacy';reason='Previously saved reviewed classification retained.'}}
    if($validLegacy -and [string]$Record.Category -in @('Daily_QA','Monthly_QA','Acceptance_Tests')){return [pscustomobject]@{category=$category;pending=$false;decision='Approved';source='legacy';reason='Previously saved reviewed classification and evidence retained.'}}
    # An undone pre-upgrade decision restores the previous pending state.
    # Its empty decision plus revision is intentional history, not a new file.
    if($null -ne $Entry -and -not $decision -and (Test-QaReportPending $Record)){$restoredCategory=$category;if($null -ne $ContentContext -and $ContentContext.profileUsable){if($ContentContext.mappedCategory){$restoredCategory=[string]$ContentContext.mappedCategory}elseif($ContentContext.suggestedCategory){$restoredCategory=[string]$ContentContext.suggestedCategory}};return [pscustomobject]@{category=$restoredCategory;pending=$true;decision='Pending';source='pending';reason='The previous pending classification was restored by Undo. Choose Approve or Disapprove after viewing the document.'}}
    if($null -ne $ContentContext -and ($ContentContext.dateConflict -or $ContentContext.typeConflict)){$conflictCategory=if($ContentContext.mappedCategory){[string]$ContentContext.mappedCategory}elseif($ContentContext.suggestedCategory){[string]$ContentContext.suggestedCategory}else{$category};return [pscustomobject]@{category=$conflictCategory;pending=$true;decision='Pending';source='content';reason=$ContentContext.view.reason}}
    if($null -ne $ContentContext -and $ContentContext.profileUsable){
        $candidate=if($ContentContext.mappedCategory){[string]$ContentContext.mappedCategory}elseif($ContentContext.suggestedCategory){[string]$ContentContext.suggestedCategory}else{$category}
        if($ContentContext.dateConflict -or $ContentContext.typeConflict -or -not $ContentContext.dateSafe){return [pscustomobject]@{category=$candidate;pending=$true;decision='Pending';source='content';reason=$ContentContext.view.reason}}
        if($ContentContext.mappedCategory -or $ContentContext.explicitCategory){return [pscustomobject]@{category=$candidate;pending=$false;decision='Automatic';source='content';reason='Organized from verified report contents and an explicit report title or this scanner''s saved report-format rule. Clinical review remains separate.'}}
        if(Test-QaReportPending $Record){return [pscustomobject]@{category=$candidate;pending=$true;decision='Pending';source='content';reason=$ContentContext.view.reason}}
    }
    $match=[regex]::Match([string]$Record.OriginalFileName,'(?i)^(?<kind>.+)_(?<date>\d{4}-\d{2}-\d{2})_(?<time>\d{2}-\d{2}-\d{2})\.pdf$');$date=[datetime]::MinValue;$valid=$false
    if($match.Success){$valid=[datetime]::TryParseExact(($match.Groups['date'].Value+' '+$match.Groups['time'].Value),'yyyy-MM-dd HH-mm-ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date);$valid=($valid -and $date -le (Get-Date).AddDays(1) -and [string]$Record.ReportDate -ceq $date.ToString('yyyy-MM-dd') -and [string]$Record.ReportTime -ceq $date.ToString('HH:mm:ss'))}
    $basis=[string](Get-QaWebValue $Record ClassificationBasis '');$kind=$match.Groups['kind'].Value
    $standardDaily=($valid -and [string]$Record.Category -eq 'Daily_QA' -and (($kind -match '(?i)(^|_)DAILY($|_)|^(ID_)?QUALITYDAILY$') -or ($kind -match '(?i)^(ID_)?QUALITY_CONSTANCY$' -and $basis -like 'Provisional Daily archive grouping from generic Constancy filename*')))
    if($standardDaily){return [pscustomobject]@{category='Daily';pending=$false;decision='Automatic';source='automatic';reason='Automatically organized as a Daily document from the standard scanner filename and saved archive grouping. This is not a clinical PASS.'}}
    if($valid -and [string]$Record.Category -in @('Monthly_QA','Monthly_QA/Pending_Verification') -and $kind -match '(?i)(^|_)MONTHLY($|_)'){return [pscustomobject]@{category='Monthly';pending=$false;decision='Automatic';source='automatic';reason='Automatically organized as a Monthly document from its explicit Monthly filename. Checklist verification and clinical results remain separate.'}}
    $pending=Test-QaReportPending $Record
    return [pscustomobject]@{category=$category;pending=[bool]$pending;decision=$(if($pending){'Pending'}else{'Organized'});source=$(if($pending){'pending'}else{'archive'});reason=$(if($pending){'The report type is uncertain. File size and generic text alone do not confirm Monthly QA.'}else{'Existing archive document grouping retained. No new clinical result inferred.'})}
}

function Get-QaWebRecord($Dashboard,[string]$Id){if($Id -notmatch '^[0-9a-fA-F]{64}$'){throw 'Choose a saved report.'};$matches=@($Dashboard.Records|Where-Object Id -ceq $Id);if($matches.Count -ne 1){throw 'The saved report is no longer available. Refresh the report list.'};return $matches[0]}
function Assert-QaWebPdf($Config,$Record){
    $path=[IO.Path]::GetFullPath([string]$Record.DestinationPath);$root=[IO.Path]::GetFullPath((Join-Path $Config.ArchiveRoot 'Reports')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($path) -ine '.pdf'){throw 'This report is outside the verified local archive.'}
    Assert-QaWebDirect $path;if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne [string]$Record.Hash){throw 'The saved PDF is missing or has changed. Run the archive check before using this report.'};return $path
}
function Get-QaWebConnectionRows($Config){
    $path=Join-Path $Config.ArchiveRoot '.ctqa/web-connections.json';Assert-QaWebDirect $path
    if([IO.File]::Exists($path)){try{return @(([IO.File]::ReadAllText($path)|ConvertFrom-Json).Connections)}catch{}}
    return @()
}
function Get-QaWebSnapshot {
    [CmdletBinding()]param($Config,$Dashboard=$null,$Organization=$null)
    if($null -eq $Dashboard){$Dashboard=Get-QaDashboard $Config};if($null -eq $Organization){$Organization=Get-QaWebOrganization $Config};$entryIndex=Get-QaWebEntryIndex $Organization;$records=New-Object 'Collections.Generic.List[object]';$connections=@(Get-QaWebConnectionRows $Config);$sources=@{}
    foreach($source in $Config.Sources){$sources[[string]$source.Scanner]=$source}
    foreach($record in @($dashboard.Records|Sort-Object ReportDate,ReportTime -Descending)){
        $entry=Get-QaWebIndexedEntry $entryIndex $record;$content=Get-QaWebContentContext $Config $record;$classification=Get-QaWebClassification $record $entry $content;$category=$classification.category;$pending=$classification.pending
        $date=[string]$content.effectiveDate;$name=[string]$sources[[string]$record.Scanner].Name
        [void]$records.Add([pscustomobject]@{id=[string]$record.Id;scanner=[string]$record.Scanner;scannerName=$name;date=$date;time=[string]$content.effectiveTime;title=($name+' - '+$date+' - '+$category+' QA');filename=[string]$record.OriginalFileName;category=$category;pending=[bool]$pending;decision=$classification.decision;organizationSource=$classification.source;organizationReason=$classification.reason;stamp=(Get-QaWebStamp $record $entry $content);content=$content.view;reviewId=[string](Get-QaWebValue $entry revision '');printedResult='Not inferred from file classification';clinicalComponents=@(Get-QaWebValue $record ConfirmedComponents @());classificationOnly=$true})
    }
    $scanners=New-Object 'Collections.Generic.List[object]'
    foreach($source in $Config.Sources){
        $row=@($dashboard.Scanners|Where-Object Scanner -eq $source.Scanner|Select-Object -First 1);$connection=@($connections|Where-Object Scanner -eq $source.Scanner|Select-Object -Last 1)
        $status=if(Test-QaPlaceholderConnection $source){'NotConfigured'}elseif($connection.Count){[string]$connection[0].Status}elseif($row.Count){[string]$row[0].Status}else{'Unknown'}
        $message=if($status -eq 'NotConfigured'){'Apply your scanner connection profile or enter the real reports folder.'}elseif($connection.Count){[string]$connection[0].Message}elseif($row.Count){[string]$row[0].Message}else{'Use Test connection to check this scanner.'}
        [void]$scanners.Add([pscustomobject]@{id=[string]$source.Scanner;name=[string]$source.Name;path=[string]$source.Path;username=[string]$source.Username;drive=[string]$source.DriveLetter;status=$status;message=$message;code=$(if($connection.Count){[int](Get-QaWebValue $connection[0] NativeCode 0)}else{0});savedReports=@($records|Where-Object scanner -eq $source.Scanner).Count;dailySchedule=[string]$source.DailySchedule;activeFrom=[string]$source.ActiveFrom;expectedMonthly=[bool]$source.ExpectedMonthly;monthlyDueDay=[int](Get-QaWebValue $source MonthlyDueDay 0);contentProfiles=@(Get-QaWebValue $source ContentProfiles @());checklist=@(Get-QaWebValue $source MonthlyChecklist @());excludedDates=@(Get-QaWebValue $source ExcludedDates @())})
    }
    $today=Get-QaTodayOverview $Config $dashboard
    # Organizationally approved Daily documents can satisfy receipt, never clinical passage.
    $received=0;$expected=0;$day=(Get-Date).ToString('yyyy-MM-dd')
    foreach($t in $today.Scanners){if($t.Required){$expected++;if(@($records|Where-Object{$_.scanner -eq $t.Scanner -and $_.date -eq $day -and $_.category -eq 'Daily' -and -not $_.pending}).Count){$received++}}}
    $headline=if(-not $expected){'No Daily QA reports scheduled today'}elseif($received -eq $expected){'All required Daily QA reports received'}else{"$received of $expected Daily QA reports received"}
    $last=$null
    foreach($history in @($organization.History|Select-Object -Last 1)){
        if($history.action -eq 'Undo'){continue};$matching=@($records|Where-Object id -ceq $history.recordId);if($matching.Count -eq 1 -and $matching[0].reviewId -ceq $history.reviewId){$last=[pscustomobject]@{recordId=$history.recordId;reviewId=$history.reviewId;stamp=$matching[0].stamp}}
    }
    return [pscustomobject]@{version='5.3.0';previewMode=$(if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'windows'}else{'browser'});workspace=[string]$Config.AppRoot;archiveRoot=[string]$Config.ArchiveRoot;libraryRoot=(Join-Path $Config.ArchiveRoot 'Report Library');setupComplete=[bool]$dashboard.SetupComplete;records=@($records.ToArray());scanners=@($scanners.ToArray());today=[pscustomobject]@{headline=$headline;received=$received;expected=$expected;date=$day};months=@(Get-QaMonthOverview $Config $dashboard|ForEach-Object{[pscustomobject]@{scanner=$_.Scanner;name=$_.Name;month=$_.Month;progress=$_.Progress;due=$_.Due;timing=$_.Timing;detail=$_.Detail;status=$_.Status}});analysis=$( $a=Get-QaAnalysisProgress $Config @($dashboard.Records);[pscustomobject]@{total=$a.Total;cached=$a.Cached;pending=$a.Pending;errors=$a.Errors});settings=[pscustomobject]@{monitorMinutes=[int](Get-QaWebValue $Config MonitorMinutes 15);autoAnalyze=[bool](Get-QaWebValue $Config AutoAnalyze $true);autoUpdateOnOpen=[bool](Get-QaWebValue $Config AutoUpdateOnOpen $true);pdfReaderMode=(Get-QaAnalysisReaderMode $Config)};pendingSummary=[pscustomobject]@{pending=@($records|Where-Object pending).Count;automatic=@($records|Where-Object decision -eq 'Automatic').Count;approved=@($records|Where-Object decision -eq 'Approved').Count;disapproved=@($records|Where-Object decision -eq 'Disapproved').Count};lastDecision=$last;attentionCount=@($dashboard.Attention).Count;onlineEnabled=$false}
}
function ConvertTo-QaWebName([string]$Name){$name=($Name -replace '[<>:"/\\|?*\x00-\x1f]','-').Trim().TrimEnd('.',' ');if(-not $name){$name='Report'};if($name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){$name='Report-'+$name};if($name.Length -gt 42){$name=$name.Substring(0,42)};return $name}
function Test-QaWebRelative([string]$Path){if(-not $Path -or $Path -match '[\\:\x00-\x1f]' -or $Path.StartsWith('/')){return $false};foreach($part in $Path.Split('/')){if($part -in @('','.','..')){return $false}};return $true}
function Get-QaWebFolderNames($Config){
    $map=@{};foreach($source in $Config.Sources){$map[[string]$source.Scanner]=ConvertTo-QaWebName ([string]$source.Name)}
    for($pass=0;$pass -le @($Config.Sources).Count;$pass++){
        $groups=@($Config.Sources|ForEach-Object{[pscustomobject]@{id=[string]$_.Scanner;folder=$map[[string]$_.Scanner]}}|Group-Object folder|Where-Object Count -gt 1)
        if(-not $groups.Count){return $map};foreach($group in $groups){foreach($row in $group.Group){$map[$row.id]=$row.id}}
    };throw 'Scanner folder names could not be made unique.'
}
function Get-QaWebRelative($Record,[string]$Category,[string]$ScannerName){
    $date=[datetime]::MinValue;$valid=[datetime]::TryParseExact([string]$Record.ReportDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)
    $year=if($valid){$date.ToString('yyyy')}else{'Unknown Date'};$month=if($valid){$date.ToString('MM - MMMM',[Globalization.CultureInfo]::InvariantCulture)}else{'Undated'};$day=if($valid){$date.ToString('yyyy-MM-dd')}else{'Undated'}
    $time=([string]$Record.ReportTime -replace '[^0-9]','');if($time.Length -gt 6){$time=$time.Substring(0,6)};if(-not $time){$time='unknown'}
    $scanner=ConvertTo-QaWebName $ScannerName;$name=ConvertTo-QaWebName ([IO.Path]::GetFileNameWithoutExtension([string]$Record.OriginalFileName))
    return ($scanner+'/'+$year+'/'+$month+'/'+$Category+'/'+$day+'_'+$time+'_'+$name+'_'+([string]$Record.Id).Substring(0,8)+'.pdf')
}
function Set-QaWebProgress($Progress,[string]$Stage,[int]$Completed=-1,[int]$Total=-1){
    if($null -eq $Progress){return};$Progress['Stage']=$Stage
    if($Completed -ge 0){$Progress['Completed']=$Completed};if($Total -ge 0){$Progress['Total']=$Total}
    if($Total -gt 0 -and $Completed -ge 0){$Progress['Percent']=[math]::Min(100,[math]::Max(0,100.0*$Completed/$Total))}
}
function Test-QaWebCancelled($Progress){return ($null -ne $Progress -and [bool](Get-QaWebValue $Progress Cancel $false))}
function Assert-QaWebDirectCached([string]$Path,$Checked){
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if($Checked.ContainsKey($current)){return}
        if(([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) -and (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Use direct library folders without links or junctions.'}
        $Checked[$current]=$true;$current=[IO.Path]::GetDirectoryName($current)
    }
}
function Get-QaWebLibraryHash([string]$Path,$Metrics){$Metrics.hashedFiles++;return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Copy-QaWebLibraryPdf([string]$Source,[string]$Target,[string]$Hash,$Progress,$Metrics){
    $temp=$Target+'.'+[guid]::NewGuid().ToString('N')+'.partial';$inputStream=$null;$outputStream=$null;$sha=$null
    try{
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Target))
        $inputStream=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$outputStream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$sha=[Security.Cryptography.SHA256]::Create();$Metrics.hashedFiles++
        $buffer=New-Object byte[] 1048576
        while(($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){if(Test-QaWebCancelled $Progress){throw [OperationCanceledException]::new('Library refresh cancelled safely.')} ;$outputStream.Write($buffer,0,$read);[void]$sha.TransformBlock($buffer,0,$read,$buffer,0)}
        [void]$sha.TransformFinalBlock($buffer,0,0);$actual=([BitConverter]::ToString($sha.Hash)).Replace('-','');$outputStream.Flush($true);$outputStream.Dispose();$outputStream=$null;$inputStream.Dispose();$inputStream=$null
        $verified=New-Object IO.FileInfo($temp);$verifiedLength=[long]$verified.Length;$verifiedTicks=[long]$verified.LastWriteTimeUtc.Ticks
        if($actual -cne $Hash -or (Get-QaWebLibraryHash $temp $Metrics) -cne $Hash){throw 'A saved PDF changed or its readable-copy fingerprint did not match. The existing files were preserved.'}
        $verified.Refresh();if(-not $verified.Exists -or $verified.Length -ne $verifiedLength -or $verified.LastWriteTimeUtc.Ticks -ne $verifiedTicks){throw 'A readable copy changed while it was being verified. Refresh or verify the archive before continuing.'}
        [IO.File]::Move($temp,$Target)
        return [pscustomobject]@{length=$verifiedLength;writeTicks=$verifiedTicks}
    }finally{if($null -ne $inputStream){$inputStream.Dispose()};if($null -ne $outputStream){$outputStream.Dispose()};if($null -ne $sha){$sha.Dispose()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Update-QaWebLibrary {
    param($Config,[object[]]$OnlyRecords=@(),$Dashboard=$null,$Organization=$null,$Progress=$null,[switch]$Verify)
    if($null -eq $Dashboard){$Dashboard=Get-QaDashboard $Config};if($null -eq $Organization){$Organization=Get-QaWebOrganization $Config}
    $entries=Get-QaWebEntryIndex $Organization;$folderNames=Get-QaWebFolderNames $Config;$sources=@{};foreach($source in $Config.Sources){$sources[[string]$source.Scanner]=$source}
    $library=Join-Path $Config.ArchiveRoot 'Report Library';$manifestPath=Join-Path $Config.ArchiveRoot '.ctqa/web-library.json';Assert-QaWebDirect $library;Assert-QaWebDirect $manifestPath;[void][IO.Directory]::CreateDirectory($library)
    $manifest=[pscustomobject]@{Version=2;Records=@()};if([IO.File]::Exists($manifestPath)){$manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json;if($manifest.Version -notin @(1,2)){throw 'The readable-library index is unsupported.'}}
    $byId=@{};$used=@{};foreach($owned in @($manifest.Records)){
        if([string]$owned.id -notmatch '^[a-fA-F0-9]{64}$' -or [string]$owned.hash -notmatch '^[a-fA-F0-9]{64}$' -or -not (Test-QaWebRelative ([string]$owned.relative)) -or $byId.ContainsKey([string]$owned.id) -or $used.ContainsKey([string]$owned.relative)){throw 'The readable-library ownership index contains invalid or conflicting entries. It was preserved.'}
        $byId[[string]$owned.id]=$owned;$used[[string]$owned.relative]=[string]$owned.id
    }
    $selected=@{};foreach($id in $OnlyRecords){$selected[[string]$id]=$true};$rows=@(if($selected.Count){$Dashboard.Records|Where-Object{$selected.ContainsKey([string]$_.Id)}}else{$Dashboard.Records})
    $metrics=[pscustomobject]@{libraryRoot=$library;copied=0;unchanged=0;total=$rows.Count;completed=0;hashedFiles=0;manifestWrites=0;retired=0;failed=0;cancelled=$false;metadataFastPath=(-not [bool]$Verify)}
    $checked=@{};$dirty=$false;$retire=New-Object 'Collections.Generic.List[object]';$reportsRoot=[IO.Path]::GetFullPath((Join-Path $Config.ArchiveRoot 'Reports')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    Set-QaWebProgress $Progress $(if($Verify){'Verifying'}else{'Library'}) 0 $rows.Count
    try{
        foreach($record in $rows){
            if(Test-QaWebCancelled $Progress){$metrics.cancelled=$true;break}
            try{
                $id=[string]$record.Id;$entry=Get-QaWebIndexedEntry $entries $record;$content=Get-QaWebContentContext $Config $record;$effective=Get-QaWebEffectiveRecord $record $content;$classification=Get-QaWebClassification $record $entry $content;$category=$classification.category;$relative=Get-QaWebRelative $effective $category $folderNames[[string]$record.Scanner];$previous=$null
                if($byId.ContainsKey($id)){$previous=$byId[$id]}
                if($null -ne $previous -and [string]$previous.category -ceq $category -and [string](Get-QaWebValue $previous filingDate ([string]$record.ReportDate)) -ceq [string]$effective.ReportDate -and [string](Get-QaWebValue $previous filingTime ([string]$record.ReportTime)) -ceq [string]$effective.ReportTime){$relative=[string]$previous.relative}
                $target=Join-Path $library ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar));$sourcePath=[IO.Path]::GetFullPath([string]$record.DestinationPath)
                if(-not $sourcePath.StartsWith($reportsRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($sourcePath) -ine '.pdf'){throw 'A report points outside the verified local archive.'}
                Assert-QaWebDirectCached $sourcePath $checked;Assert-QaWebDirectCached $target $checked
                $owned=($null -ne $previous -and [string]$previous.relative -ceq $relative)
                if(-not $owned -and ([IO.File]::Exists($target) -or $used.ContainsKey($relative))){
                    $base=$relative.Substring(0,$relative.Length-4)
                    do{$relative=$base+'-copy-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.pdf';$target=Join-Path $library ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))}while($used.ContainsKey($relative) -or [IO.File]::Exists($target))
                    Assert-QaWebDirectCached $target $checked
                }
                if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $target.Length -gt 245){throw 'The readable-library path is too long. Choose a shorter local archive folder.'}
                $sourceInfo=New-Object IO.FileInfo($sourcePath);if(-not $sourceInfo.Exists -or $sourceInfo.Length -ne [long]$record.Length){throw 'A saved PDF is missing or changed. Run the archive check before refreshing its readable copy.'}
                $targetInfo=New-Object IO.FileInfo($target);$targetExists=$targetInfo.Exists
                $cached=($owned -and $targetExists -and -not $Verify -and [string]$previous.hash -ceq [string]$record.Hash -and [string](Get-QaWebValue $previous sourcePath '') -ceq $sourcePath -and [long](Get-QaWebValue $previous sourceLength -1) -eq $sourceInfo.Length -and [long](Get-QaWebValue $previous sourceWriteTicks -1) -eq $sourceInfo.LastWriteTimeUtc.Ticks -and [long](Get-QaWebValue $previous targetLength -1) -eq $targetInfo.Length -and [long](Get-QaWebValue $previous targetWriteTicks -1) -eq $targetInfo.LastWriteTimeUtc.Ticks)
                if($cached){$metrics.unchanged++}else{
                    $sourceLength=[long]$sourceInfo.Length;$sourceTicks=[long]$sourceInfo.LastWriteTimeUtc.Ticks
                    $targetLength=if($targetExists){[long]$targetInfo.Length}else{-1};$targetTicks=if($targetExists){[long]$targetInfo.LastWriteTimeUtc.Ticks}else{-1}
                    if($targetExists){
                        if((Get-QaWebLibraryHash $sourcePath $metrics) -cne [string]$record.Hash){throw 'A saved PDF failed its indexed SHA-256 check. The readable copy was not changed.'}
                        if((Get-QaWebLibraryHash $target $metrics) -cne [string]$record.Hash){throw 'A readable PDF was edited. It was preserved; restore the readable copy or choose a new library location.'}
                        $metrics.unchanged++
                    }else{$verifiedCopy=Copy-QaWebLibraryPdf $sourcePath $target ([string]$record.Hash) $Progress $metrics;$targetLength=[long]$verifiedCopy.length;$targetTicks=[long]$verifiedCopy.writeTicks;$metrics.copied++}
                    $sourceInfo.Refresh();$targetInfo.Refresh()
                    if(-not $sourceInfo.Exists -or $sourceInfo.Length -ne $sourceLength -or $sourceInfo.LastWriteTimeUtc.Ticks -ne $sourceTicks -or -not $targetInfo.Exists -or $targetInfo.Length -ne $targetLength -or $targetInfo.LastWriteTimeUtc.Ticks -ne $targetTicks){throw 'A saved or readable PDF changed while it was being verified. No metadata cache was saved for it; run the archive check before trying again.'}
                    $new=[pscustomobject]@{id=$id;hash=[string]$record.Hash;relative=$relative;category=$category;filingDate=[string]$effective.ReportDate;filingTime=[string]$effective.ReportTime;original=[string]$record.OriginalFileName;sourcePath=$sourcePath;sourceLength=$sourceLength;sourceWriteTicks=$sourceTicks;targetLength=$targetLength;targetWriteTicks=$targetTicks}
                    $byId[$id]=$new;$used[$relative]=$id;$dirty=$true
                    if($null -ne $previous -and [string]$previous.relative -cne $relative){[void]$retire.Add($previous)}
                }
                $metrics.completed++;if($null -ne $Progress){$Progress['Copied']=$metrics.copied;$Progress['Unchanged']=$metrics.unchanged};Set-QaWebProgress $Progress $(if($Verify){'Verifying'}else{'Library'}) $metrics.completed $rows.Count
            }catch{if(Test-QaWebCancelled $Progress){$metrics.cancelled=$true;break};$metrics.failed++;if($null -ne $Progress){$Progress['Failed']=$metrics.failed};throw}
        }
    }finally{
        # Commit completed ownership once even when interrupted. A retry can then
        # reuse the completed copies instead of treating them as unowned files.
        if($dirty){Write-QaWebAtomic $manifestPath ([pscustomobject]@{Version=2;Records=@($byId.Values|Sort-Object id)});$metrics.manifestWrites++}
        foreach($old in $retire){
            $oldPath=Join-Path $library (([string]$old.relative).Replace('/',[IO.Path]::DirectorySeparatorChar));Assert-QaWebDirectCached $oldPath $checked
            if([IO.File]::Exists($oldPath) -and (Get-QaWebLibraryHash $oldPath $metrics) -ceq [string]$old.hash){$history=Join-Path $Config.ArchiveRoot ('.ctqa/library-history/'+[guid]::NewGuid().ToString('N')+'.pdf');Assert-QaWebDirectCached $history $checked;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($history));[IO.File]::Move($oldPath,$history);$metrics.retired++}
        }
    }
    return $metrics
}

function Invoke-QaWebOrganization {
    param($Config,$Request,$Progress=$null)
    $meta=Join-Path $Config.ArchiveRoot '.ctqa';Assert-QaWebDirect $meta;[void][IO.Directory]::CreateDirectory($meta);$lock=$null
    try{
        try{$lock=[IO.File]::Open((Join-Path $meta 'archive.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'An archive operation is already running. Wait for it to finish, then try again.'}
        $dashboard=Get-QaDashboard $Config;$record=Get-QaWebRecord $dashboard ([string](Get-QaWebValue $Request id ''));$organization=Get-QaWebOrganization $Config;$before=Get-QaWebEntry $organization $record;$content=Get-QaWebContentContext $Config $record
        if([string](Get-QaWebValue $Request stamp '') -cne (Get-QaWebStamp $record $before $content)){throw 'This report changed after it was displayed. Refresh before deciding.'}
        [void](Assert-QaWebPdf $Config $record);$action=[string]$Request.action;$category=Get-QaWebCategory $record $before;$decision=''
        if($action -eq 'Undo'){
            $history=@($organization.History|Where-Object recordId -ceq $record.Id|Select-Object -Last 1)
            if($history.Count -ne 1 -or [string](Get-QaWebValue $Request reviewId '') -cne [string]$history[0].reviewId -or [string](Get-QaWebValue $before revision '') -cne [string]$history[0].reviewId){throw 'Only the latest decision for this report can be undone.'}
            $restore=$history[0].before;$category=[string](Get-QaWebValue $restore category '');$decision=[string](Get-QaWebValue $restore decision '')
        }else{
            $classification=Get-QaWebClassification $record $before $content;$category=[string]$classification.category;$pending=$classification.pending;if(-not $pending){throw 'This report is already organized. Refresh the pending list.'}
            if($action -eq 'Approve'){$decision='Approved'}elseif($action -eq 'Disapprove'){$decision='Disapproved';$category='Other'}else{throw 'Unsupported file decision.'}
        }
        $revision=[guid]::NewGuid().ToString('N');$actor=[Environment]::UserName
        $after=[pscustomobject]@{id=[string]$record.Id;hash=[string]$record.Hash;revision=$revision;decision=$decision;category=$category;time=[datetime]::UtcNow.ToString('o');actor=$actor;actorKind='Windows account identifier; not a verified personal QA reviewer'}
        $history=[pscustomobject]@{reviewId=$revision;recordId=[string]$record.Id;hash=[string]$record.Hash;action=$action;time=$after.time;actor=$actor;actorKind=$after.actorKind;before=$before;after=$after;scope='Document classification only; no clinical result or checklist verification'}
        $organization.Records=@($organization.Records|Where-Object id -cne $record.Id)+@($after);$organization.History=@($organization.History)+@($history)
        if(Test-QaWebCancelled $Progress){return [pscustomobject]@{cancelled=$true;warning='';recordId=[string]$record.Id;reviewId='';stamp=(Get-QaWebStamp $record $before $content)}}
        Write-QaWebAtomic (Join-Path $meta 'organization.json') $organization
        $warning='';try{[void](Update-QaWebLibrary -Config $Config -OnlyRecords @([string]$record.Id) -Dashboard $dashboard -Organization $organization -Progress $Progress)}catch{$warning='Decision saved. Readable folders need refresh: '+$_.Exception.Message}
        return [pscustomobject]@{recordId=[string]$record.Id;reviewId=$revision;stamp=(Get-QaWebStamp $record $after $content);warning=$warning;classificationOnly=$true}
    }finally{if($null -ne $lock){$lock.Dispose()}}
}
function New-QaWebArtifactPath($AppRoot,[string]$Folder,[string]$Prefix){$root=Join-Path $AppRoot $Folder;Assert-QaWebDirect $root;[void][IO.Directory]::CreateDirectory($root);return Join-Path $root ($Prefix+'-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.zip')}
function ConvertTo-QaWebCsv([string]$Value){if($Value -match '^[\x00-\x20]*[=+@\-\t\r]'){return ("'"+$Value)};return $Value}
function New-QaWebExport {
    param($Config,[string[]]$Ids,$Progress=$null)
    if(-not $Ids.Count){throw 'Select at least one report to export.'};if($Ids.Count -gt 20000){throw 'Export at most 20,000 reports at once.'}
    $dashboard=Get-QaDashboard $Config;$organization=Get-QaWebOrganization $Config;$exportEntryIndex=Get-QaWebEntryIndex $organization;$folderNames=Get-QaWebFolderNames $Config;$seen=@{};$rows=@();foreach($id in $Ids){if(Test-QaWebCancelled $Progress){return ''};if($seen.ContainsKey($id)){continue};$seen[$id]=$true;$record=Get-QaWebRecord $dashboard $id;[void](Assert-QaWebPdf $Config $record);$rows+=@($record)}
    Set-QaWebProgress $Progress 'Exporting' 0 $rows.Count
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    $path=New-QaWebArtifactPath $Config.AppRoot 'Exports' 'CTQA-Reports';$temp=$path+'.partial';$zip=$null;$stream=$null;$summary=New-Object Text.StringBuilder;$manifest=New-Object 'Collections.Generic.List[object]';$usedPaths=@{}
    try{
        $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew);$zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        [void]$summary.Append('<!doctype html><html lang="en"><meta charset="utf-8"><title>CT QA reports</title><style>body{font:16px/1.5 Segoe UI,sans-serif;max-width:1000px;margin:35px auto}td,th{padding:12px;border-bottom:1px solid #ddd;text-align:left}a{color:#087568}</style><h1>CT QA report package</h1><p>Saved report documents. Approve/Disapprove labels organize files; they do not declare clinical PASS/FAIL or complete a Monthly checklist.</p><table><tr><th>Scanner</th><th>Date</th><th>Type</th><th>Open PDF</th></tr>')
        $exported=0
        foreach($record in $rows){
            if(Test-QaWebCancelled $Progress){return ''}
            $entry=Get-QaWebIndexedEntry $exportEntryIndex $record;$content=Get-QaWebContentContext $Config $record;$effective=Get-QaWebEffectiveRecord $record $content;$classification=Get-QaWebClassification $record $entry $content;$category=$classification.category;$source=@($Config.Sources|Where-Object Scanner -eq $record.Scanner)[0];$organizationStatus=if($classification.pending){'Pending suggestion'}else{$classification.decision};$typeLabel=$category+' document';if($organizationStatus -eq 'Pending suggestion'){$typeLabel+=' - pending classification'};$name=Get-QaWebRelative $effective $category $folderNames[[string]$record.Scanner]
            $baseName=$name;$suffix=1;while($usedPaths.ContainsKey($name)){$suffix++;$name=$baseName.Substring(0,$baseName.Length-4)+'-Report-'+$suffix+'.pdf'};$usedPaths[$name]=$true
            $pdf=Assert-QaWebPdf $Config $record;[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$pdf,$name,[IO.Compression.CompressionLevel]::Optimal);$exported++;Set-QaWebProgress $Progress 'Exporting' $exported $rows.Count
            $nameSafe=ConvertTo-QaWebCsv ([string]$record.OriginalFileName)
            [void]$manifest.Add([pscustomobject]@{Scanner=(ConvertTo-QaWebCsv $source.Name);ReportId=$record.Id;ReportDate=$effective.ReportDate;ReportTime=$effective.ReportTime;OriginalFilename=$nameSafe;DocumentType=$category;OrganizationDecision=$organizationStatus;OriginalArchiveCategory=[string]$record.Category;ExportPath=$name;SHA256=$record.Hash;ClinicalReviewer=(ConvertTo-QaWebCsv ([string](Get-QaWebValue $record ConfirmedBy '')));ClinicalReviewTime=[string](Get-QaWebValue $record ConfirmedAt '');VerifiedChecklistItems=(@(Get-QaWebValue $record ConfirmedComponents @()) -join '; ');PrintedResultStatus=[string](Get-QaWebValue (Get-QaSavedAnalysis $Config $record) Status 'Not analyzed');ClinicalQAResult='Not inferred from classification'})
            $link=($name.Split('/')|ForEach-Object{[Uri]::EscapeDataString($_)}) -join '/'
            [void]$summary.Append('<tr><td>'+[Net.WebUtility]::HtmlEncode($source.Name)+'</td><td>'+[Net.WebUtility]::HtmlEncode([string]$effective.ReportDate)+'</td><td>'+[Net.WebUtility]::HtmlEncode($typeLabel)+'</td><td><a href="'+$link+'">'+[Net.WebUtility]::HtmlEncode([string]$record.OriginalFileName)+'</a></td></tr>')
        }
        [void]$summary.Append('</table><p>Every exported PDF was checked against its saved SHA-256 fingerprint.</p></html>')
        foreach($item in @(@{Name='Report Summary.html';Text=$summary.ToString()},@{Name='Report list.csv';Text=(@($manifest.ToArray())|ConvertTo-Csv -NoTypeInformation|Out-String)})){$e=$zip.CreateEntry($item.Name);$writer=New-Object IO.StreamWriter($e.Open(),(New-Object Text.UTF8Encoding $true));try{$writer.Write($item.Text)}finally{$writer.Dispose()}}
        $zip.Dispose();$zip=$null;$stream=$null
        # Read back every exported PDF to detect a source changing during compression.
        $verify=[IO.Compression.ZipFile]::OpenRead($temp);try{foreach($row in $manifest){$input=$verify.GetEntry($row.ExportPath).Open();$sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($input))).Replace('-','');if($hash -cne [string]$row.SHA256){throw 'An exported PDF changed during export. No completed package was produced.'}}finally{$sha.Dispose();$input.Dispose()}}}finally{$verify.Dispose()}
        if(Test-QaWebCancelled $Progress){return ''};[IO.File]::Move($temp,$path);return $path
    }finally{if($null -ne $zip){$zip.Dispose()};if($null -ne $stream){$stream.Dispose()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Invoke-QaWebRequest {
    [CmdletBinding()]param([string]$AppRoot,$Request,$Progress=$null)
    $AppRoot=[IO.Path]::GetFullPath($AppRoot);Assert-QaWebDirect $AppRoot;[void](Initialize-QaWorkspace $AppRoot);$config=Read-QaConfig $AppRoot;$action=[string](Get-QaWebValue $Request action '')
    $allowed=@('Snapshot','Refresh','Approve','Disapprove','Undo','Reconnect','Settings','ApplyProfile','Export','Analyze','Backup','Diagnostics','Pdf','Browse','PickArchive','PrepareUpdate','InstallPreparedUpdate','Audit','ScannerSettings','Restore','PreviewPdf')
    if($action -cnotin $allowed){throw 'This application action is not supported.'}
    $value=$null;$message='';$warning='';$path='';$decision=$null;$snapshotDashboard=$null;$cancelled=$false
    Set-QaWebProgress $Progress 'Preparing' 0 0
    if(Test-QaWebCancelled $Progress){return [pscustomobject]@{snapshot=(Get-QaWebSnapshot $config);cancelled=$true;message='Cancelled before any changes.';path=''}}
    switch($action){
        'Snapshot'{return Get-QaWebSnapshot $config}
        'PreviewPdf'{return Get-QaPdfPreviewPage -Config $config -RecordId ([string](Get-QaWebValue $Request id '')) -PageNumber ([int](Get-QaWebValue $Request page 0))}
        'Pdf'{$record=Get-QaWebRecord (Get-QaDashboard $config) ([string](Get-QaWebValue $Request id ''));return [pscustomobject]@{path=(Assert-QaWebPdf $config $record);filename=[string]$record.OriginalFileName}}
        {$_ -in @('Approve','Disapprove','Undo')}{$decision=Invoke-QaWebOrganization $config $Request $Progress;if([bool](Get-QaWebValue $decision cancelled $false)){return [pscustomobject]@{snapshot=(Get-QaWebSnapshot $config);cancelled=$true;message='Cancelled before saving the decision.';path=''}};$message=$(if($action -eq 'Undo'){'Previous file classification restored.'}else{$action+' saved. The PDF was kept.'});$warning=$decision.warning}
        'Refresh'{
            Set-QaWebProgress $Progress 'Connecting' 0 @($config.Sources).Count
            $connectionNumber=0
            foreach($source in $config.Sources){if(Test-QaWebCancelled $Progress){break};$connectionNumber++;Set-QaWebProgress $Progress 'Connecting' $connectionNumber @($config.Sources).Count;if(Test-QaPlaceholderConnection $source){continue};$credential=$null;try{$credential=Get-QaSavedCredential -AppRoot $AppRoot -ScannerId $source.Scanner -ExpectedUsername $source.Username -ExpectedPath $source.Path}catch{};if($null -ne $credential){[void](Reconnect-QaScanner $source $credential)}}
            if(Test-QaWebCancelled $Progress){return [pscustomobject]@{snapshot=(Get-QaWebSnapshot $config);cancelled=$true;message='Connection checks cancelled. Saved reports are unchanged.';path=''}}
            $dashboard=Get-QaDashboard $config
            Set-QaWebProgress $Progress 'Scanning' 0 0
            if($dashboard.SetupComplete){$operation=Invoke-QaOperation $config -Mode Update -Progress $Progress}else{
                $preview=Invoke-QaOperation $config -Mode Preview -Progress $Progress
                if([bool]$preview.Summary.Cancelled -or (Test-QaWebCancelled $Progress)){return [pscustomobject]@{snapshot=(Get-QaWebSnapshot $config);cancelled=$true;message='Scanning cancelled. Setup has not been changed.';path=''}}
                $accessible=@($preview.Scanners|Where-Object{$_.Status -in @('Connected','Issues','Partial')})
                if(-not $accessible.Count){
                    Write-QaWebAtomic (Join-Path $config.ArchiveRoot '.ctqa/web-connections.json') ([pscustomobject]@{Version=1;Connections=@($preview.Scanners)})
                    return [pscustomobject]@{snapshot=(Get-QaWebSnapshot $config);message='No scanner reports folder is accessible yet. Open Settings and test the scanner connections.';warning='Setup has not been completed. Existing archive records were not changed.';decision=$null;result=$null;path=''}
                }
                $operation=Invoke-QaOperation $config -Mode Import -Plan $preview.Plan -Progress $Progress
            }
            Write-QaWebAtomic (Join-Path $config.ArchiveRoot '.ctqa/web-connections.json') ([pscustomobject]@{Version=1;Connections=@($operation.Scanners)})
            $snapshotDashboard=$operation;$message=$operation.Summary.Description;$cancelled=([bool]$operation.Summary.Cancelled -or (Test-QaWebCancelled $Progress))
            if(-not $cancelled){try{$library=Update-QaWebLibrary -Config $config -Dashboard $operation -Progress $Progress;$value=[pscustomobject]@{library=$library};$cancelled=[bool]$library.cancelled}catch{$warning=$_.Exception.Message}}
        }
        'Reconnect'{
            $id=[string](Get-QaWebValue $Request scanner '');$matches=@($config.Sources|Where-Object Scanner -ceq $id);if($matches.Count -ne 1){throw 'Choose a configured scanner.'};$source=$matches[0]
            $username=[string](Get-QaWebValue $Request username $source.Username);$newPath=[string](Get-QaWebValue $Request path $source.Path);if($newPath -ne $source.Path){$newPath=(Get-QaNetworkLocation $newPath).Path};$source.Username=$username;$source.Path=$newPath;[void](Save-QaConfig $AppRoot $config)
            $credential=$null;$password=[string](Get-QaWebValue $Request password '')
            if($password){$secure=ConvertTo-SecureString $password -AsPlainText -Force;$credential=New-Object Management.Automation.PSCredential($username,$secure);$password=''}else{try{$credential=Get-QaSavedCredential -AppRoot $AppRoot -ScannerId $id -ExpectedUsername $username -ExpectedPath $newPath}catch{}}
            $connection=Reconnect-QaScanner $source $credential;$rows=@(Get-QaWebConnectionRows $config|Where-Object Scanner -cne $id)+@($connection);Write-QaWebAtomic (Join-Path $config.ArchiveRoot '.ctqa/web-connections.json') ([pscustomobject]@{Version=1;Connections=$rows})
            if($connection.Status -eq 'Connected' -and $null -ne $credential -and (Get-QaWebValue $Request remember $false) -eq $true){Save-QaSavedCredential -AppRoot $AppRoot -ScannerId $id -Credential $credential -ExpectedPath $newPath|Out-Null}
            $number=1+[Array]::IndexOf([object[]]$config.Sources,$source);Write-QaSupportEvent -AppRoot $AppRoot -Operation Reconnect -Outcome $(if($connection.Status -eq 'Connected'){'Completed'}else{'Failed'}) -NativeCode ([int]$connection.NativeCode) -ScannerNumber $number -ErrorKind (Get-QaSupportErrorKind -Message $connection.Message -NativeCode ([int]$connection.NativeCode))
            $message=$connection.Message;$value=[pscustomobject]@{connection=$connection}
        }
        'Settings'{
            $root=[string](Get-QaWebValue $Request archiveRoot $config.ArchiveRoot);if(-not [IO.Path]::IsPathRooted($root)){throw 'Choose an absolute local archive folder.'};$config.ArchiveRoot=[IO.Path]::GetFullPath($root)
            if($null -ne (Get-QaWebValue $Request pdfReaderMode)){if([string]$Request.pdfReaderMode -cnotin @('Auto','Python','Standard')){throw 'Choose Automatic, Portable Python, or Standard reader.'};$config|Add-Member PdfReaderMode ([string]$Request.pdfReaderMode) -Force}
            if($null -ne (Get-QaWebValue $Request monitorMinutes)){$config|Add-Member MonitorMinutes ([int]$Request.monitorMinutes) -Force};if($null -ne (Get-QaWebValue $Request autoUpdateOnOpen)){if($Request.autoUpdateOnOpen -isnot [bool]){throw 'Update on opening must be on or off.'};$config|Add-Member AutoUpdateOnOpen $Request.autoUpdateOnOpen -Force};if($null -ne (Get-QaWebValue $Request autoAnalyze)){if($Request.autoAnalyze -isnot [bool]){throw 'Automatic reading must be on or off.'};$config|Add-Member AutoAnalyze $Request.autoAnalyze -Force}
            [void](Save-QaConfig $AppRoot $config);$message='Settings saved. Existing report folders were not moved or deleted.'
        }
        'ScannerSettings'{
            $id=[string](Get-QaWebValue $Request scanner '');$matches=@($config.Sources|Where-Object Scanner -ceq $id);if($matches.Count -ne 1){throw 'Choose an existing scanner before editing settings.'};$source=$matches[0]
            foreach($pair in @(@('name','Name'),@('path','Path'),@('drive','DriveLetter'),@('username','Username'),@('dailySchedule','DailySchedule'),@('activeFrom','ActiveFrom'),@('expectedMonthly','ExpectedMonthly'),@('monthlyDueDay','MonthlyDueDay'),@('checklist','MonthlyChecklist'),@('excludedDates','ExcludedDates'),@('checklistEffectiveMonth','ChecklistEffectiveMonth'))){
                $incoming=Get-QaWebValue $Request $pair[0];if($null -ne $incoming){if($pair[0] -eq 'expectedMonthly' -and $incoming -isnot [bool]){throw 'Monthly scheduling must be on or off.'};$source|Add-Member -NotePropertyName $pair[1] -NotePropertyValue $incoming -Force}
            }
            if(($Request -is [Collections.IDictionary] -and $Request.Contains('contentProfiles')) -or ($Request -isnot [Collections.IDictionary] -and $null -ne $Request.PSObject.Properties['contentProfiles'])){$source|Add-Member -NotePropertyName ContentProfiles -NotePropertyValue ([object[]]@(ConvertTo-QaWebContentProfiles $Request.contentProfiles)) -Force}
            [void](Save-QaConfig $AppRoot $config);$message='Scanner settings saved. Existing archive records and prior checklist versions were preserved.'
        }
        'ApplyProfile'{
            $profile=Get-QaWebValue $Request profile;if($profile -is [string]){$profile=$profile|ConvertFrom-Json};if($null -eq $profile){throw 'Choose a scanner connection profile.'}
            foreach($item in @($profile)+@($profile.Connections)){foreach($property in $item.PSObject.Properties){if($property.Name -match '(?i)password|secret|credential'){throw 'Connection profiles cannot contain passwords. Use the secure scanner sign-in field.'}}}
            $temp=Join-Path $AppRoot ('Data/.profile-'+[guid]::NewGuid().ToString('N')+'.json');Assert-QaWebDirect $temp
            try{[IO.File]::WriteAllText($temp,($profile|ConvertTo-Json -Depth 15),(New-Object Text.UTF8Encoding $true));$applied=Set-QaConnectionProfile -AppRoot $AppRoot -ProfilePath $temp -ReplaceExisting;$message=$applied.Message}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}};$config=Read-QaConfig $AppRoot
        }
        'Export'{$path=New-QaWebExport $config ([string[]]@(Get-QaWebValue $Request ids @())) $Progress;$cancelled=(-not $path -and (Test-QaWebCancelled $Progress));$message='Report package is ready to download.'}
        'Analyze'{
            $ids=@();$selectedRecord=$null;$selected=[string](Get-QaWebValue $Request id '');if($selected){$selectedRecord=Get-QaWebRecord (Get-QaDashboard $config) $selected;$ids=@($selected)}
            if($null -ne (Get-QaWebValue $Request force) -and (Get-QaWebValue $Request force) -isnot [bool]){throw 'Retry must be on or off.'};$force=[bool](Get-QaWebValue $Request force $false);if($force -and -not $selected){throw 'Choose one PDF before retrying a read.'};if($selected -and (Test-QaAnalysisSelectedRefresh $config $selectedRecord)){$force=$true};Set-QaWebProgress $Progress 'Analyzing' 0 0;if($selected){$analysis=Invoke-QaAnalysis $config -Limit 1 -RecordIds $ids -Force:$force -Progress $Progress}else{$analysis=Invoke-QaAnalysis $config -Limit 20 -Progress $Progress};$cancelled=[bool]$analysis.Summary.Cancelled
            $message=([string]$analysis.Analyzed+' PDFs analyzed; '+[string]$analysis.Cached+' cached; '+[string]$analysis.Failed+' need attention.');$value=$analysis
            if(-not $cancelled){$changed=@(Get-QaWebValue $analysis AnalyzedIds @());if($selected){$changed=@($selected)};if($changed.Count){try{[void](Update-QaWebLibrary -Config $config -OnlyRecords $changed -Progress $Progress)}catch{$warning='Contents were read. Readable folders need refresh: '+$_.Exception.Message}}}
        }
        'Backup'{
            $path=New-QaWebArtifactPath $AppRoot 'Backups' 'CTQA-Full-Backup';$archivePrefix=[IO.Path]::GetFullPath($config.ArchiveRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar;$external=$false
            if($path.StartsWith($archivePrefix,[StringComparison]::OrdinalIgnoreCase)){
                if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Choose a backup destination outside the live archive using the Windows maintenance interface.'}
                Add-Type -AssemblyName System.Windows.Forms;$picker=New-Object Windows.Forms.SaveFileDialog;$picker.Filter='CT QA backup (*.zip)|*.zip';$picker.Title='Save a NEW backup outside your live archive';$picker.FileName=[IO.Path]::GetFileName($path)
                try{if($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return [pscustomobject]@{cancelled=$true;message='Backup cancelled. No existing files changed.'}};$path=$picker.FileName;$external=$true}finally{$picker.Dispose()}
            }
            Set-QaWebProgress $Progress 'BackingUp' 0 0
            $backup=New-QaBackup -AppRoot $AppRoot -Config $config -DestinationPath $path -Progress $Progress;$message='Verified backup is ready to download.'
            if($external){$message='Verified backup saved to: '+$path;$value=[pscustomobject]@{savedTo=$path};$path=''}
        }
        'Restore'{
            if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Interactive restore requires Windows. Use the native maintenance helper on the work computer.'}
            Add-Type -AssemblyName System.Windows.Forms;$picker=New-Object Windows.Forms.OpenFileDialog;$picker.Filter='CT QA backup (*.zip)|*.zip';$picker.Title='Choose the verified CT QA backup to restore'
            try{if($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return [pscustomobject]@{cancelled=$true;message='Restore cancelled. No files changed.'}};$backupPath=$picker.FileName}finally{$picker.Dispose()}
            $folder=New-Object Windows.Forms.FolderBrowserDialog;$folder.Description='Choose the PARENT folder. A new restored workspace will be created without replacing existing files.'
            try{if($folder.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return [pscustomobject]@{cancelled=$true;message='Restore cancelled. No files changed.'}};$destination=Join-Path $folder.SelectedPath ('CTQA-Restored-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))}finally{$folder.Dispose()}
            Set-QaWebProgress $Progress 'Restoring' 0 0;$restored=Restore-QaBackup -Path $backupPath -DestinationFolder $destination -Progress $Progress;$message=$restored.Summary.Description+' Restored folder: '+$destination;$value=[pscustomobject]@{restoredTo=$destination}
        }
        'Diagnostics'{$path=New-QaWebArtifactPath $AppRoot 'Logs/Support' 'CTQA-Support';[void](Export-QaSupportBundle -AppRoot $AppRoot -Config $config -Dashboard (Get-QaDashboard $config) -DestinationPath $path -ConnectionResults @(Get-QaWebConnectionRows $config));$message='Scrubbed support logs are ready. No report contents, usernames or passwords are included.'}
        'Audit'{Set-QaWebProgress $Progress 'Verifying' 0 0;$result=Invoke-QaOperation $config -Mode Audit -Progress $Progress;$snapshotDashboard=$result;$cancelled=([bool]$result.Summary.Cancelled -or (Test-QaWebCancelled $Progress));$message=$result.Summary.Description;if(-not $cancelled){$library=Update-QaWebLibrary -Config $config -Dashboard $result -Progress $Progress -Verify;$value=[pscustomobject]@{library=$library};$cancelled=[bool]$library.cancelled}}
        'Browse'{$library=Update-QaWebLibrary -Config $config -Progress $Progress;$cancelled=[bool]$library.cancelled;$folder=Join-Path $config.ArchiveRoot 'Report Library';if(-not $cancelled -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){Start-Process -FilePath explorer.exe -ArgumentList ('"'+$folder+'"')|Out-Null};$message='Readable report folders opened.';$value=[pscustomobject]@{libraryRoot=$folder;library=$library}}
        'PickArchive'{
            if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'The folder picker requires Windows. Enter a local path instead.'};Add-Type -AssemblyName System.Windows.Forms;$picker=New-Object Windows.Forms.FolderBrowserDialog;$picker.Description='Choose the existing local archive containing Reports and .ctqa. Choosing a folder does not move any files.'
            try{if($picker.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){return [pscustomobject]@{archiveRoot=$picker.SelectedPath;cancelled=$false}}else{return [pscustomobject]@{cancelled=$true}}}finally{$picker.Dispose()}
        }
        'PrepareUpdate'{
            $zip=[IO.Path]::GetFullPath([string](Get-QaWebValue $Request path (Get-QaWebValue $Request zipPath '')));$uploads=[IO.Path]::GetFullPath((Join-Path $AppRoot 'Data/.web-uploads')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if(-not $zip.StartsWith($uploads,[StringComparison]::OrdinalIgnoreCase)){throw 'Choose an update ZIP through the application upload control.'};Assert-QaWebDirect $zip
            $plan=New-QaUpdateStage -AppRoot $AppRoot -ZipPath $zip;$updateId=[guid]::NewGuid().ToString('N');$store=Join-Path $AppRoot 'Data/web-update-plan.json';Write-QaWebAtomic $store ([pscustomobject]@{Version=1;id=$updateId;stageRoot=$plan.StageRoot;sourceFolder=$plan.SourceFolder;versionName=$plan.Version})
            return [pscustomobject]@{version=$plan.Version;updateId=$updateId;files=$plan.Files;message='Update package checked. Install when ready; saved reports and settings stay in place.'}
        }
        'InstallPreparedUpdate'{
            $store=Join-Path $AppRoot 'Data/web-update-plan.json';Assert-QaWebDirect $store;if(-not [IO.File]::Exists($store)){throw 'Choose and check an update ZIP first.'};$saved=[IO.File]::ReadAllText($store)|ConvertFrom-Json
            if($saved.Version -ne 1 -or [string](Get-QaWebValue $Request updateId '') -cne [string]$saved.id){throw 'This checked update is no longer selected.'}
            $stage=[IO.Path]::GetFullPath([string]$saved.stageRoot);if(-not [IO.Path]::GetDirectoryName($stage).Equals($AppRoot.TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($stage) -notmatch '^\.pending-update-[a-f0-9]{32}$'){throw 'Invalid update staging location.'}
            $sourceFolder=Join-Path $stage 'Package';if(-not $sourceFolder.Equals([IO.Path]::GetFullPath([string]$saved.sourceFolder),[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid prepared update folder.'};$checked=Test-QaUpdateFolder $sourceFolder
            return [pscustomobject]@{installUpdate=[pscustomobject]@{sourceFolder=$sourceFolder;targetFolder=$AppRoot;stageRoot=$stage};version=$checked.Version;message='Closing the app so the checked update can install.'}
        }
    }
    Set-QaWebProgress $Progress 'Finishing' 0 0
    $snapshot=Get-QaWebSnapshot -Config $config -Dashboard $snapshotDashboard
    if($cancelled){$message='Cancelled safely. Completed report copies and decisions remain saved; run Update reports to continue.'}
    return [pscustomobject]@{snapshot=$snapshot;message=$message;warning=$warning;decision=$decision;result=$value;path=$path;cancelled=$cancelled}
}
Export-ModuleMember -Function Invoke-QaWebRequest,Get-QaWebSnapshot
