[CmdletBinding()]param([string]$OutputPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProductRoot 'App/Trends.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_TrendTests_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestRoot)
$script:Results=New-Object 'Collections.Generic.List[object]';$script:Assertions=0
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw ('CHECK: '+$Message)}}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS '+$Name)}catch{$detail=if($_.Exception.Message.StartsWith('CHECK: ')){$_.Exception.Message.Substring(7)}else{$_.Exception.GetType().Name};[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=$detail});Write-Host ('FAIL '+$Name+': '+$detail);Write-Host ('Synthetic test location: '+$_.InvocationInfo.ScriptLineNumber);Write-Host $_.Exception.Message;Write-Host $_.ScriptStackTrace}}
function Fixture([string]$Name){
    $root=Join-Path $TestRoot $Name;[void][IO.Directory]::CreateDirectory((Join-Path $root 'Reports'));[void][IO.Directory]::CreateDirectory((Join-Path $root '.ctqa/analysis'))
    return [pscustomobject]@{Config=[pscustomobject]@{ArchiveRoot=$root;Sources=@([pscustomobject]@{Scanner='CT_Edge';Name='Synthetic CT Edge'},[pscustomobject]@{Scanner='CT_Flash';Name='Synthetic CT Flash'})};Records=(New-Object 'Collections.Generic.List[object]')}
}
function New-Record($Fx,[string]$Name,[string]$Date='2025-02-01',[string]$Time='07:00:00',[string]$Scanner='CT_Edge',[string]$Source='', [string]$Archived='2025-03-01T00:00:00Z',[string]$SameContent=''){
    if(-not $Source){$Source=Join-Path $Fx.Config.ArchiveRoot ('Sources/'+$Name+'.pdf')}
    $destination=Join-Path $Fx.Config.ArchiveRoot ('Reports/'+$Name+'.pdf')
    $content=if($SameContent){$SameContent}else{'%PDF-1.4 synthetic trend fixture '+$Name}
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Source));[IO.File]::WriteAllText($Source,$content,[Text.Encoding]::ASCII);[IO.File]::WriteAllText($destination,$content,[Text.Encoding]::ASCII)
    $hash=(Get-FileHash $destination -Algorithm SHA256).Hash;$sha=[Security.Cryptography.SHA256]::Create();try{$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Name+'|'+$Scanner)))).Replace('-','')}finally{$sha.Dispose()}
    $row=[pscustomobject]@{Id=$id;Scanner=$Scanner;ReportDate=$Date;ReportTime=$Time;SourcePath=$Source;DestinationPath=$destination;Hash=$hash;Length=(Get-Item $destination).Length;FirstArchived=$Archived;Category='Daily_QA';ConfirmedBy='';ConfirmedAt='';ConfirmedComponents=@()}
    [void]$Fx.Records.Add($row);return $row
}
function New-Measurement([string]$Code='WaterCTNumber',[string]$Value='0.25',[string]$Mode='Body',[string]$System='A',[string]$Slice='1',[string]$Lower='-4',[string]$Upper='4',[int]$Page=3,[string]$Status='Printed'){
    return [pscustomobject]@{Code=$Code;Value=$Value;Unit='HU';Page=$Page;LowerLimit=$Lower;UpperLimit=$Upper;Mode=$Mode;SourceSystem=$System;Slice=$Slice;Status=$Status}
}
function Save-Analysis($Fx,$Record,[object[]]$Measurements=@(),[string]$Date='', [string]$Time='', [string]$DateStatus='Consensus',[string]$MeasurementStatus='Extracted',[object[]]$Issues=@(),[bool]$Complete=$true,[string]$Outcome='OK',[int]$MeasurementVersion=1,[string]$Status='NeedsReview'){
    if(-not $Date){$Date=if($Record.ReportDate){$Record.ReportDate}else{'2025-02-01'}}
    if(-not $Time){$Time=if($Record.ReportTime){$Record.ReportTime}else{'07:00:00'}}
    $info=Get-Item $Record.DestinationPath
    $row=[pscustomobject]@{ParserVersion=1;AnalysisCacheSchemaVersion=3;DocumentClassifierVersion=1;RecordId=$Record.Id;Hash=$Record.Hash;VerifiedHash=$Record.Hash;VerifiedLength=$info.Length;VerifiedWriteTicks=$info.LastWriteTimeUtc.Ticks;SavedLength=$info.Length;SavedWriteTicks=$info.LastWriteTimeUtc.Ticks;Status=$Status;DocumentClassification=[pscustomobject]@{ClassifierVersion=1;Status='Recognized';DateStatus=$DateStatus;ReportDate=$Date;ReportTime=$Time;CompleteRead=$Complete;ReadPages=3;Pages=3;Sections=@([pscustomobject]@{PrintedOutcomes=@($Outcome)})};MeasurementsDocument=[pscustomobject]@{MeasurementVersion=$MeasurementVersion;CompleteRead=$Complete;Status=$MeasurementStatus;Issues=@($Issues);Measurements=@($Measurements)}}
    $path=Join-Path $Fx.Config.ArchiveRoot ('.ctqa/analysis/'+$Record.Hash+'.json')
    if([IO.File]::Exists($path)){
        $existing=[IO.File]::ReadAllText($path)|ConvertFrom-Json
        if([string]$existing.RecordId -ne [string]$Record.Id){$others=@();if($null -ne $existing.PSObject.Properties['OtherRecords']){$others=@($existing.OtherRecords|Where-Object RecordId -ne $Record.Id)};$existing|Add-Member OtherRecords (@($others)+@($row)) -Force;$row=$existing}
    }
    [IO.File]::WriteAllText($path,($row|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true));return $path
}
function Read-Trend($Fx,[hashtable]$Parameters=@{}){return Get-QaTrendData -Config $Fx.Config -Records @($Fx.Records.ToArray()) @Parameters}
function Snapshot($Fx){$result=@{};foreach($p in @(Get-ChildItem -LiteralPath $Fx.Config.ArchiveRoot -File -Recurse)){$result[$p.FullName]=(Get-FileHash $p.FullName).Hash};return ,$result}
try {
    Scenario 'Chronological printed readings and explicit ranges remain documentary and input files are unchanged' {
        $fx=Fixture 'Basic';$r2=New-Record $fx 'Later' '2025-02-03';$r1=New-Record $fx 'Earlier' '2025-02-01'
        [void](Save-Analysis $fx $r2 @((New-Measurement -Value '0.75')));[void](Save-Analysis $fx $r1 @((New-Measurement -Value '-0.25')))
        $before=Snapshot $fx;$result=Read-Trend $fx
        Check ($result.points.Count -eq 2 -and $result.points[0].date -eq '2025-02-01' -and $result.points[1].date -eq '2025-02-03') 'Readings are sorted by the printed timestamp.'
        Check ($result.summary.first -eq -0.25 -and $result.summary.latest -eq 0.75 -and $result.summary.change -eq 1 -and $result.summary.min -eq -0.25 -and $result.summary.max -eq 0.75) 'The full selected-series numeric summary is exact.'
        Check ($result.points[0].lower -eq -4 -and $result.points[0].upper -eq 4 -and $result.points[0].page -eq 3 -and $result.clinicalResult -eq 'Not inferred') 'Printed limits and page evidence do not create a clinical decision.'
        $after=Snapshot $fx;Check ($after.Count -eq $before.Count) 'The read-only query adds no files.';foreach($key in $before.Keys){Check ($before[$key] -eq $after[$key]) 'Reports, source bytes and cache files stay unchanged.'}
    }
    Scenario 'Different scanners, head/body modes, systems, slices and metrics are separate series' {
        $fx=Fixture 'Grouping';$one=New-Record $fx 'One';$two=New-Record $fx 'OtherScanner' '2025-02-01' '07:00:00' 'CT_Flash'
        [void](Save-Analysis $fx $one @((New-Measurement -Mode Head),(New-Measurement -Mode Body),(New-Measurement -System B),(New-Measurement -Slice 2),(New-Measurement -Code ImageNoise -Value 3.5)))
        [void](Save-Analysis $fx $two @((New-Measurement -Value 9)))
        $result=Read-Trend $fx
        Check ($result.series.Count -eq 4 -and $result.points.Count -eq 1 -and $result.scanner -eq 'CT_Edge') 'The default selects one context, not a mixture of four series or scanners.'
        $head=Read-Trend $fx @{Mode='Head';SourceSystem='A';Slice=1};Check ($head.points.Count -eq 1 -and $head.selectedSeries -eq 'CT_Edge|WaterCTNumber|Head|A|1') 'An explicit head/system/slice context selects exactly its series.'
        $noise=Read-Trend $fx @{Metric='ImageNoise'};Check ($noise.series.Count -eq 1 -and $noise.points[0].value -eq 3.5) 'Noise does not share the water-value series.'
        $other=Read-Trend $fx @{Scanner='CT_Flash'};Check ($other.points.Count -eq 1 -and $other.points[0].value -eq 9) 'The selected scanner has its own values.'
    }
    Scenario 'Printed failures and values outside printed limits stay visible with review warnings' {
        $fx=Fixture 'Outliers';$r=New-Record $fx 'Outside'
        [void](Save-Analysis $fx $r @((New-Measurement -Value 6)) -MeasurementStatus NeedsReview -Issues @('MixedPrintedObservations') -Outcome FAIL)
        $result=Read-Trend $fx
        Check ($result.points.Count -eq 1 -and $result.points[0].value -eq 6 -and $result.points[0].outsidePrintedRange) 'An out-of-range current value is retained rather than hidden.'
        Check ($result.points[0].reviewWarning -and $result.points[0].warnings -contains 'PrintedObservationNeedsReview' -and $result.coverage.reviewReports -eq 1) 'The document warning is retained without inventing a clinical failure.'
        $explicit=New-Record $fx 'ExplicitPrintedFail' '2025-02-02';[void](Save-Analysis $fx $explicit @((New-Measurement -Value 7)) -Status ReportedFailure -Outcome '')
        $again=Read-Trend $fx;Check ($again.points.Count -eq 2 -and $again.coverage.reviewReports -eq 2 -and @($again.points|Where-Object { $_.warnings -contains 'PrintedObservationNeedsReview' }).Count -eq 2) 'A clear current reading remains warned when another printed-results extractor identifies a report failure.'
    }
    Scenario 'Missing or invalid printed bounds do not invent limits or discard the current numeric value' {
        $fx=Fixture 'Limits';$r=New-Record $fx 'NoLimits';[void](Save-Analysis $fx $r @((New-Measurement -Lower '' -Upper '' -Status NeedsReview)) -MeasurementStatus NeedsReview -Issues @('InvalidPrintedLimits'))
        $result=Read-Trend $fx
        Check ($result.points.Count -eq 1 -and $null -eq $result.points[0].lower -and $null -eq $result.points[0].upper) 'The current value remains while uncertain bounds stay absent.'
        Check ($result.points[0].reviewWarning -and -not $result.points[0].outsidePrintedRange) 'No outside-range conclusion is produced without two valid printed bounds.'
    }
    Scenario 'Uncertain dates and incomplete reads never enter the chart as normal points' {
        $fx=Fixture 'DateSafety';$conflict=New-Record $fx 'DateConflict';$incomplete=New-Record $fx 'Incomplete' '2025-02-02';$mixed=New-Record $fx 'MixedDates' '2025-02-03'
        [void](Save-Analysis $fx $conflict @((New-Measurement)) -Date '2025-02-04');[void](Save-Analysis $fx $incomplete @((New-Measurement)) -Complete $false);[void](Save-Analysis $fx $mixed @((New-Measurement)) -DateStatus Conflict)
        $result=Read-Trend $fx
        Check ($result.points.Count -eq 0 -and $result.coverage.unsupportedReports -eq 3 -and $result.coverage.dateConflicts -eq 2) 'Conflicting indexed/footer dates, mixed footers and partial reads are withheld.'
    }
    Scenario 'Verified footer dates can supply missing indexed dates and period boundaries are inclusive' {
        $fx=Fixture 'DateFilter';$r=New-Record $fx 'Undated' '' '';[void](Save-Analysis $fx $r @((New-Measurement)) -Date '2025-02-03' -Time '08:10:00')
        $result=Read-Trend $fx @{StartDate='2025-02-03';EndDate='2025-02-03'}
        Check ($result.points.Count -eq 1 -and $result.points[0].date -eq '2025-02-03' -and $result.points[0].time -eq '08:10:00') 'A consistent footer date supplies the missing indexed date in the exact one-day interval.'
        $empty=Read-Trend $fx @{StartDate='2025-02-04'};Check ($empty.points.Count -eq 0 -and $empty.coverage.savedReports -eq 0) 'A valid footer outside the selected period is excluded.'
    }
    Scenario 'Only the newest revision of a source is charted and an ambiguous revision timestamp is withheld' {
        $fx=Fixture 'Revisions';$source=Join-Path $fx.Config.ArchiveRoot 'Sources/Revised.pdf';$old=New-Record $fx 'Old' '2025-02-01' '07:00:00' 'CT_Edge' $source '2025-03-01T00:00:00Z';$new=New-Record $fx 'New' '2025-02-02' '07:00:00' 'CT_Edge' $source '2025-03-02T00:00:00Z'
        [void](Save-Analysis $fx $old @((New-Measurement -Value 1)));[void](Save-Analysis $fx $new @((New-Measurement -Value 2)))
        $result=Read-Trend $fx;Check ($result.points.Count -eq 1 -and $result.points[0].value -eq 2 -and $result.coverage.supersededReports -eq 1) 'The newest archived revision wins before charting.'
        $new.FirstArchived=$old.FirstArchived;$ambiguous=Read-Trend $fx;Check ($ambiguous.points.Count -eq 0 -and $ambiguous.coverage.conflicts -ge 1) 'Equal revision timestamps with different bytes do not select an arbitrary value.'
    }
    Scenario 'Content aliases and identical timestamp values are deduplicated without averaging conflicts' {
        $fx=Fixture 'Duplicates';$r1=New-Record $fx 'Copy1' -SameContent 'SYNTHETIC_IDENTICAL_CONTENT';$r2=New-Record $fx 'Copy2' -SameContent 'SYNTHETIC_IDENTICAL_CONTENT'
        [void](Save-Analysis $fx $r1 @((New-Measurement -Value 1)));[void](Save-Analysis $fx $r2 @((New-Measurement -Value 1)))
        $same=Read-Trend $fx;Check ($same.points.Count -eq 1 -and $same.coverage.duplicateReports -eq 1) 'Identical PDF aliases count as one reading.'
        $r3=New-Record $fx 'DifferentValues';[void](Save-Analysis $fx $r3 @((New-Measurement -Value 3)))
        $conflict=Read-Trend $fx;Check ($conflict.points.Count -eq 0 -and $conflict.coverage.conflicts -eq 1) 'Different readings at the same scanner/context/timestamp are flagged and withheld rather than averaged.'
    }
    Scenario 'Disagreeing reader caches for identical PDF aliases cannot select an arbitrary reading' {
        $fx=Fixture 'AliasReaderDisagreement';$one=New-Record $fx 'AliasReaderOne' -SameContent 'SAME_SYNTHETIC_PDF_FOR_DIFFERENT_READER_CACHES';$two=New-Record $fx 'AliasReaderTwo' -SameContent 'SAME_SYNTHETIC_PDF_FOR_DIFFERENT_READER_CACHES'
        [void](Save-Analysis $fx $one @((New-Measurement -Value 1),(New-Measurement -Mode Head -Value 2)));[void](Save-Analysis $fx $two @((New-Measurement -Value 7),(New-Measurement -Mode Head -Value 2)))
        $result=Read-Trend $fx
        Check ($result.series.Count -eq 1 -and $result.series[0].mode -eq 'Head' -and $result.points.Count -eq 1 -and $result.points[0].value -eq 2 -and $result.coverage.conflicts -eq 1) 'Conflicting current values for the same PDF/context/time are withheld, while the agreeing separate context remains available.'
    }
    Scenario 'Pending coverage includes old measurement caches and unknown dates without retrying failed reads' {
        $fx=Fixture 'Coverage';$unread=New-Record $fx 'Unread';$old=New-Record $fx 'OldCache' '2025-02-02';$failed=New-Record $fx 'Failed' '2025-02-03';$unknown=New-Record $fx 'UnknownDate' '' ''; $unsupported=New-Record $fx 'Unsupported' '2025-02-04'
        [void](Save-Analysis $fx $old @() -MeasurementVersion 0);[void](Save-Analysis $fx $failed @() -Status ReadError);[void](Save-Analysis $fx $unsupported @() -MeasurementStatus NeedsReview)
        $result=Read-Trend $fx
        Check ($result.coverage.pendingReports -eq 3 -and $result.pendingIds.Count -eq 3 -and $result.pendingIds -notcontains $failed.Id) 'Unread and legacy measurement reports are pending; a cached failed read is not repeatedly retried.'
        Check ($result.coverage.failedReports -eq 1 -and $result.coverage.unknownDates -eq 1 -and $result.coverage.unsupportedReports -eq 1) 'Failed, undated and read-but-unsupported reports have separate visible coverage counts.'
        Check ($result.pendingIds -contains $unknown.Id -and $result.pendingIds -contains $unread.Id) 'Reading unknown-date saved reports can discover their printed date.'
    }
    Scenario 'Changed saved-file metadata invalidates trend evidence and requires a new verified read' {
        $fx=Fixture 'Provenance';$r=New-Record $fx 'Changed';[void](Save-Analysis $fx $r @((New-Measurement)))
        $before=Read-Trend $fx;Check ($before.points.Count -eq 1) 'The original verified cache is usable.'
        [IO.File]::AppendAllText($r.DestinationPath,'synthetic change');$after=Read-Trend $fx
        Check ($after.points.Count -eq 0 -and $after.coverage.pendingReports -eq 1 -and $after.pendingIds -contains $r.Id) 'Changed bytes/length cannot reuse the old cache for trend points.'
    }
    Scenario 'Queries reject unsupported inputs and public results exclude private record fields' {
        $fx=Fixture 'Privacy';$r=New-Record $fx 'PRIVATE_FILENAME_CANARY_F931';$r|Add-Member Reviewer 'PRIVATE_PERSON_CANARY_483A';[void](Save-Analysis $fx $r @((New-Measurement)))
        foreach($parameters in @(@{Scanner='Unknown'},@{StartDate='not-a-date'},@{StartDate='2025-03-01';EndDate='2025-02-01'},@{SeriesKey='../private'},@{Metric='CTDI'})){$rejected=$false;try{Read-Trend $fx $parameters|Out-Null}catch{$rejected=$true};Check $rejected 'Malformed or unconfigured trend requests are rejected.'}
        $json=Read-Trend $fx|ConvertTo-Json -Depth 20
        Check (-not $json.Contains($fx.Config.ArchiveRoot) -and -not $json.Contains('PRIVATE_FILENAME_CANARY') -and -not $json.Contains('PRIVATE_PERSON_CANARY') -and -not $json.Contains('SourcePath') -and -not $json.Contains('DestinationPath')) 'Only fixed metric data and approved scanner aliases reach the response.'
    }
    Scenario 'Unknown completeness flags cannot become verified chart evidence' {
        $fx=Fixture 'TypedCompleteness';$r=New-Record $fx 'Typed';$path=Save-Analysis $fx $r @((New-Measurement));$row=[IO.File]::ReadAllText($path)|ConvertFrom-Json;$row.MeasurementsDocument.CompleteRead='false';[IO.File]::WriteAllText($path,($row|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true))
        $result=Read-Trend $fx;Check ($result.points.Count -eq 0 -and $result.coverage.unsupportedReports -eq 1) 'A string rather than a true Boolean completeness flag is not treated as complete evidence.'
    }
    Scenario 'Pending read identities are capped while the complete pending count stays visible' {
        $fx=Fixture 'PendingCap'
        for($n=1;$n -le 105;$n++){
            $id=$n.ToString('X64');[void]$fx.Records.Add([pscustomobject]@{Id=$id;Hash=$id;Scanner='CT_Edge';SourcePath=('SYNTHETIC_SOURCE_'+$n);DestinationPath='Unused';ReportDate='';ReportTime='';FirstArchived='2025-03-01T00:00:00Z'})
        }
        $result=Read-Trend $fx
        Check ($result.coverage.pendingReports -eq 105 -and $result.pendingIds.Count -eq 100 -and $result.pendingIdLimitReached) 'A bounded read request still reports all remaining pending records.'
    }
    Scenario 'Plot point limits preserve full-period summary statistics and disclose truncation' {
        $fx=Fixture 'PointCap';$analyses=@{};$start=[datetime]'2010-01-01'
        for($n=0;$n -lt 5002;$n++){
            $id=($n+1).ToString('X64');$date=$start.AddDays($n).ToString('yyyy-MM-dd');[void]$fx.Records.Add([pscustomobject]@{Id=$id;Hash=$id;Scanner='CT_Edge';SourcePath=('SYNTHETIC_POINT_SOURCE_'+$n);DestinationPath='Unused';ReportDate=$date;ReportTime='07:00:00';FirstArchived='2025-03-01T00:00:00Z'})
            $analyses[$id]=[pscustomobject]@{Status='NeedsReview';DocumentClassification=[pscustomobject]@{DateStatus='Consensus';ReportDate=$date;ReportTime='07:00:00';CompleteRead=$true;ReadPages=3;Sections=@()};MeasurementsDocument=[pscustomobject]@{MeasurementVersion=1;CompleteRead=$true;Status='Extracted';Issues=@();Measurements=@((New-Measurement -Value $n.ToString() -Lower '-10000' -Upper '10000'))}}
        }
        $module=Get-Module Trends
        & $module {param($Values) $script:TrendTestAnalyses=$Values;function script:Get-QaSavedAnalysis {param($Config,$Record) return $script:TrendTestAnalyses[[string]$Record.Id]}} $analyses
        try{
            $result=Read-Trend $fx
            Check ($result.points.Count -eq 5000 -and $result.totalPointCount -eq 5002 -and $result.pointLimitReached) 'Only the most recent five thousand plotted points are returned, with the total disclosed.'
            Check ($result.summary.count -eq 5002 -and $result.summary.first -eq 0 -and $result.summary.latest -eq 5001 -and $result.summary.change -eq 5001 -and $result.summary.scope -eq 'selectedPeriod') 'The summary still covers the entire selected period rather than the clipped plotting subset.'
            Check ($result.points[0].value -eq 2 -and $result.summary.firstDate -eq '2010-01-01') 'Plot clipping does not relabel the first retained point as the period baseline.'
        }finally{& $module {param($InsightsPath) Remove-Item Function:Get-QaSavedAnalysis -ErrorAction SilentlyContinue;Remove-Variable TrendTestAnalyses -Scope Script -ErrorAction SilentlyContinue;Import-Module $InsightsPath -DisableNameChecking -WarningAction SilentlyContinue} (Join-Path $ProductRoot 'App/Insights.psm1')}
    }
    Scenario 'The production query reads managed archive state without rebuilding dashboard attention' {
        Import-Module (Join-Path $ProductRoot 'App/Archive.psm1') -DisableNameChecking -WarningAction SilentlyContinue
        $root=Join-Path $TestRoot 'ManagedArchive';[void][IO.Directory]::CreateDirectory($root);$config=Get-QaDefaultConfig -AppRoot $root;$config.ArchiveRoot=Join-Path $root 'Data';$config.MinimumFileAgeSeconds=0
        foreach($source in $config.Sources){$source.Path=Join-Path $root ('Source/'+$source.Scanner);[void][IO.Directory]::CreateDirectory($source.Path)}
        $preview=Invoke-QaOperation -Config $config -Mode Preview;[void](Invoke-QaOperation -Config $config -Mode Import -Plan $preview.Plan)
        $before=@{};foreach($file in @(Get-ChildItem $config.ArchiveRoot -File -Recurse)){$before[$file.FullName]=(Get-FileHash $file.FullName).Hash}
        $result=Get-QaTrendData -Config $config
        Check ($result.points.Count -eq 0 -and $result.coverage.savedReports -eq 0 -and $result.scanners.Count -eq 3) 'The real validated managed state can produce a truthful empty trend view.'
        foreach($file in @(Get-ChildItem $config.ArchiveRoot -File -Recurse)){Check ($before.ContainsKey($file.FullName) -and $before[$file.FullName] -eq (Get-FileHash $file.FullName).Hash) 'The read-only production path preserves the actual state and index files.'}
    }
}finally{if([IO.Directory]::Exists($TestRoot)){Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue}}
$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Product='CT QA Manager Pro';Feature='Conservative cached measurement trends';Runtime=$PSVersionTable.PSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5 -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT);SyntheticOnly=$true;Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Synthetic owned PDF bytes and independently verified analysis-cache provenance. Current-source revisions, separate measurement contexts, printed outliers/review flags, date conflicts, alias deduplication, pending/error coverage, strict query values and public-data privacy are exercised. No scanner network, real clinical report or clinical pass/fail inference is used.'}
if($OutputPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($report|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding $true))}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
if($failed){exit 1}
exit 0
