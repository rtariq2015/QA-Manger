# Read-only, engine-independent trends from verified cached printed measurements.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Insights.psm1') -DisableNameChecking -WarningAction SilentlyContinue

function Get-QaTrendMetricDefinition {
    [CmdletBinding()]param([ValidateSet('WaterCTNumber','ImageNoise','SliceThickness','Lightmarker','ExternalLightmarker','TopogramPosition','SagittalCoronalLightmarker')][string]$Metric='WaterCTNumber')
    switch($Metric){
        'WaterCTNumber'{return [pscustomobject]@{code='WaterCTNumber';label='Water CT number';unit='HU';axisLabel='Hounsfield units (HU)'}}
        'ImageNoise'{return [pscustomobject]@{code='ImageNoise';label='Image noise';unit='HU';axisLabel='Hounsfield units (HU)'}}
        'SliceThickness'{return [pscustomobject]@{code='SliceThickness';label='Slice thickness';unit='mm';axisLabel='Millimetres (mm)'}}
        'Lightmarker'{return [pscustomobject]@{code='Lightmarker';label='Light marker alignment';unit='mm';axisLabel='Millimetres (mm)'}}
        'ExternalLightmarker'{return [pscustomobject]@{code='ExternalLightmarker';label='External light marker';unit='mm';axisLabel='Millimetres (mm)'}}
        'TopogramPosition'{return [pscustomobject]@{code='TopogramPosition';label='Topogram position';unit='mm';axisLabel='Millimetres (mm)'}}
        'SagittalCoronalLightmarker'{return [pscustomobject]@{code='SagittalCoronalLightmarker';label='Sagittal / coronal alignment';unit='mm';axisLabel='Millimetres (mm)'}}
    }
}
function Test-QaTrendReference {param($Analysis)
    $doc=Get-QaTrendValue $Analysis DocumentClassification $null
    return ([string](Get-QaTrendValue $doc ProfileId '') -ceq 'siemens-iec-reference-v1' -or [string](Get-QaTrendValue $doc DocumentKind '') -ceq 'Reference' -or (Test-QaTrendTrue (Get-QaTrendValue $doc IsReference $false)) -or (Test-QaTrendTrue (Get-QaTrendValue $doc HasReferenceEvidence $false)))
}

function Get-QaTrendValue {param($Object,[string]$Name,$Default=$null)
    if($null -ne $Object){if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}elseif($null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name}};return $Default
}
function Test-QaTrendTrue {param($Value) return ($Value -is [bool] -and $Value -eq $true)}
function Get-QaTrendDate {param([string]$Value)
    $date=[datetime]::MinValue
    if($Value -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' -and [datetime]::TryParseExact($Value,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)){return $date.Date}
    return $null
}
function Get-QaTrendNumber {param($Value)
    if($null -eq $Value){return $null}
    $text=if($Value -is [string]){$Value}elseif($Value -is [IFormattable]){$Value.ToString($null,[Globalization.CultureInfo]::InvariantCulture)}else{''}
    if($text -cnotmatch '^[+-]?[0-9]{1,9}(?:\.[0-9]{1,9})?$'){return $null}
    $number=[decimal]0
    if([decimal]::TryParse($text,([Globalization.NumberStyles]::AllowLeadingSign -bor [Globalization.NumberStyles]::AllowDecimalPoint),[Globalization.CultureInfo]::InvariantCulture,[ref]$number)){return $number}
    return $null
}
function Get-QaTrendArchiveRecords {param($Config)
    $path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Archive.psm1'))
    $modules=@(Get-Module Archive -All|Where-Object{$_.Path -and [string]::Equals([IO.Path]::GetFullPath($_.Path),$path,[StringComparison]::OrdinalIgnoreCase)})
    if(-not $modules.Count){$modules=@(Import-Module $path -PassThru -ErrorAction Stop|Where-Object{$_.Path -and [string]::Equals([IO.Path]::GetFullPath($_.Path),$path,[StringComparison]::OrdinalIgnoreCase)})}
    if(-not $modules.Count){throw 'The archive reader is unavailable.'}
    return @(& $modules[0] {param($Cfg) Assert-QaConfig $Cfg;$state=Read-QaState (Get-QaPaths $Cfg);return @($state.Records)} $Config)
}
function Test-QaTrendAlignmentMetric {param([string]$Metric) return ($Metric -cin @('Lightmarker','ExternalLightmarker','TopogramPosition','SagittalCoronalLightmarker'))}
function Test-QaTrendMetricDocument {param($Measurement,$Document,[string]$Metric)
    if(-not (Test-QaTrendAlignmentMetric $Metric)){return $true}
    if([int](Get-QaTrendValue $Measurement MeasurementSupportRevision 0) -lt 3 -or [string](Get-QaTrendValue $Document ProfileId '') -cnotin @('siemens-iec-extended-v1','siemens-iec-additional-v1') -or [string](Get-QaTrendValue $Document Status '') -cne 'Recognized'){return $false}
    $sections=@(Get-QaTrendValue $Document Sections @()|Where-Object{[string](Get-QaTrendValue $_ Code '') -ceq $Metric -and (Test-QaTrendTrue (Get-QaTrendValue $_ BodyEvidence $false))})
    return ($sections.Count -eq 1)
}
function Test-QaTrendCapabilityPending {param($Measurement,$Document,[string]$Metric)
    $revision=[int](Get-QaTrendValue $Measurement MeasurementSupportRevision 0)
    if(Test-QaTrendAlignmentMetric $Metric){return ($revision -lt 3 -and @((Get-QaTrendValue $Document Sections @())|Where-Object{[string](Get-QaTrendValue $_ Code '') -ceq $Metric}).Count -gt 0)}
    if($Metric -ceq 'SliceThickness'){return ($revision -lt 2 -and @((Get-QaTrendValue $Document Sections @())|Where-Object{[string](Get-QaTrendValue $_ Code '') -ceq 'Slice'}).Count -gt 0)}
    return ($revision -lt 2 -and [string](Get-QaTrendValue $Document ProfileId '') -ceq 'siemens-quality-daily-v1')
}
function Get-QaTrendRowContext {param($Row,[string]$Metric)
    $mode=[string](Get-QaTrendValue $Row Mode '');$system=[string](Get-QaTrendValue $Row SourceSystem '');$slice=[string](Get-QaTrendValue $Row Slice '')
    if(Test-QaTrendAlignmentMetric $Metric){
        $context=[string](Get-QaTrendValue $Row Context '')
        if($mode -cne 'Unspecified' -or $system -cne 'NotSpecified' -or $slice -cne '' -or (($Metric -ceq 'SagittalCoronalLightmarker' -and $context -cnotin @('Sagittal','Coronal')) -or ($Metric -cne 'SagittalCoronalLightmarker' -and $context -cne 'Overall')) -or [string](Get-QaTrendValue $Row ContextSection '') -cne $Metric -or [string](Get-QaTrendValue $Row Source '') -cne 'PrintedAlignmentResult'){return $null}
        return [pscustomobject]@{mode='Unspecified';system='NotSpecified';slice=0;context=$context;suffix=('Unspecified|NotSpecified|'+$context);label=$(if($Metric -ceq 'SagittalCoronalLightmarker'){$context+' alignment'}else{'Overall alignment'})}
    }
    if($mode -cnotin @('Head','Body','Unspecified') -or $system -cnotin @('A','B') -or $slice -cnotmatch '^[1-9][0-9]{0,2}$'){return $null}
    return [pscustomobject]@{mode=$mode;system=$system;slice=[int]$slice;context='';suffix=($mode+'|'+$system+'|'+$slice);label=($mode+' / System '+$system+' / Slice '+$slice)}
}

function Get-QaTrendAliasEvidence {param($Analysis,$Record,[string]$Scanner,[string]$Metric)
    # Equal PDF hashes can have separate reader-cache provenance rows. Compare
    # their clear readings before choosing one alias, so a reader disagreement
    # cannot be hidden by deduplication or by the stable record-id tie breaker.
    if(Test-QaTrendReference $Analysis){return $null}
    $unit=(Get-QaTrendMetricDefinition $Metric).unit
    $measurement=Get-QaTrendValue $Analysis MeasurementsDocument $null;$doc=Get-QaTrendValue $Analysis DocumentClassification $null
    if([string](Get-QaTrendValue $Analysis Status '') -ceq 'ReadError' -or [int](Get-QaTrendValue $measurement MeasurementVersion 0) -ne 1 -or -not (Test-QaTrendTrue (Get-QaTrendValue $doc CompleteRead $false)) -or -not (Test-QaTrendTrue (Get-QaTrendValue $measurement CompleteRead $false)) -or [string](Get-QaTrendValue $doc DateStatus '') -cne 'Consensus' -or [string](Get-QaTrendValue $measurement Status '') -cnotin @('Extracted','NeedsReview')){return $null}
    if(-not (Test-QaTrendMetricDocument $measurement $doc $Metric)){return $null}
    $date=[string](Get-QaTrendValue $doc ReportDate '');$time=[string](Get-QaTrendValue $doc ReportTime '');$timestamp=[datetime]::MinValue
    if(-not [datetime]::TryParseExact(($date+' '+$time),'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$timestamp) -or $timestamp.Date -gt (Get-Date).Date.AddDays(1)){return $null}
    $indexed=Get-QaTrendDate ([string](Get-QaTrendValue $Record ReportDate ''))
    if(($null -ne $indexed -and $indexed -ne $timestamp.Date) -or ([string](Get-QaTrendValue $Record ReportTime '') -and [string](Get-QaTrendValue $Record ReportTime '') -cne $time)){return $null}
    $values=@{}
    foreach($row in @(Get-QaTrendValue $measurement Measurements @()|Select-Object -First 100)){
        $page=[int](Get-QaTrendValue $row Page 0);$context=Get-QaTrendRowContext $row $Metric
        if([string](Get-QaTrendValue $row Code '') -cne $Metric -or [string](Get-QaTrendValue $row Unit '') -cne $unit -or [string](Get-QaTrendValue $row Status '') -cnotin @('Printed','NeedsReview') -or $null -eq $context -or $page -lt 1 -or $page -gt [int](Get-QaTrendValue $doc ReadPages 0)){continue}
        $value=Get-QaTrendNumber (Get-QaTrendValue $row Value);if($null -eq $value){continue}
        $lower=Get-QaTrendNumber (Get-QaTrendValue $row LowerLimit);$upper=Get-QaTrendNumber (Get-QaTrendValue $row UpperLimit);if($null -eq $lower -or $null -eq $upper -or $lower -gt $upper){$lower=$null;$upper=$null}
        $key=$Scanner+'|'+$Metric+'|'+$context.suffix+'|'+$date+'|'+$time
        $signature=([string]$value)+'|'+[string]$lower+'|'+[string]$upper
        if($values.ContainsKey($key) -and $values[$key] -cne $signature){$values[$key]='Conflict'}else{$values[$key]=$signature}
    }
    return $values
}
function Get-QaTrendArchivedTicks {param($Record)
    $value=[datetimeoffset]::MinValue
    if([datetimeoffset]::TryParse([string](Get-QaTrendValue $Record FirstArchived ''),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$value)){return $value.UtcDateTime.Ticks}
    return [long]0
}
function Test-QaTrendInPeriod {param($Date,$Start,$End)
    return ($null -ne $Date -and ($null -eq $Start -or $Date -ge $Start) -and ($null -eq $End -or $Date -le $End))
}
function Get-QaTrendData {
    [CmdletBinding()]param(
        [Parameter(Mandatory=$true)]$Config,
        [string]$Scanner='',
        [ValidateSet('WaterCTNumber','ImageNoise','SliceThickness','Lightmarker','ExternalLightmarker','TopogramPosition','SagittalCoronalLightmarker')][string]$Metric='WaterCTNumber',
        [ValidateSet('','Head','Body','Unspecified')][string]$Mode='',
        [ValidateSet('','A','B','NotSpecified')][string]$SourceSystem='',
        [ValidateRange(0,999)][int]$Slice=0,
        [Alias('StartDate')][string]$StartDateISO='',
        [Alias('EndDate')][string]$EndDateISO='',
        [string]$SeriesKey='',
        [AllowEmptyCollection()][object[]]$Records=@()
    )
    $definition=Get-QaTrendMetricDefinition $Metric;$Metric=[string]$definition.code;$unit=[string]$definition.unit
    if($Mode){$Mode=if($Mode -ieq 'Head'){'Head'}elseif($Mode -ieq 'Body'){'Body'}else{'Unspecified'}}
    if($SourceSystem){$SourceSystem=if($SourceSystem -ieq 'NotSpecified'){'NotSpecified'}else{$SourceSystem.ToUpperInvariant()}}
    $start=$null;$end=$null
    if($StartDateISO){$start=Get-QaTrendDate $StartDateISO;if($null -eq $start){throw 'Choose a valid start date using yyyy-MM-dd.'}}
    if($EndDateISO){$end=Get-QaTrendDate $EndDateISO;if($null -eq $end){throw 'Choose a valid end date using yyyy-MM-dd.'}}
    if($null -ne $start -and $null -ne $end -and $start -gt $end){throw 'The start date must be on or before the end date.'}
    if($SeriesKey -and $SeriesKey -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,31}\|(?:(?:WaterCTNumber|ImageNoise|SliceThickness)\|(?:Head|Body|Unspecified)\|[AB]\|[1-9][0-9]{0,2}|(?:(?:Lightmarker|ExternalLightmarker|TopogramPosition)\|Unspecified\|NotSpecified\|Overall|SagittalCoronalLightmarker\|Unspecified\|NotSpecified\|(?:Sagittal|Coronal)))$'){throw 'Choose one available measurement series.'}
    $scanners=New-Object 'Collections.Generic.List[object]';$sourceIds=@{}
    foreach($source in @(Get-QaTrendValue $Config Sources @())){
        $id=[string](Get-QaTrendValue $source Scanner '')
        if($id -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,31}$' -or $sourceIds.ContainsKey($id)){throw 'Scanner configuration is unavailable for trends.'}
        $sourceIds[$id]=$true;[void]$scanners.Add([pscustomobject]@{id=$id;name=[string](Get-QaTrendValue $source Name $id)})
    }
    if(-not $scanners.Count){throw 'Configure a scanner before opening trends.'}
    if(-not $Scanner){$Scanner=[string]$scanners[0].id}
    if(-not @($scanners|Where-Object id -CEQ $Scanner).Count){throw 'Choose a configured scanner.'}
    if(-not $PSBoundParameters.ContainsKey('Records')){$Records=@(Get-QaTrendArchiveRecords $Config)}
    if($Records.Count -gt 100000){throw 'This archive is too large for one trend query. Use a smaller managed archive.'}
    $coverage=[ordered]@{savedReports=0;readReports=0;pendingReports=0;unsupportedReports=0;failedReports=0;conflicts=0;unknownDates=0;duplicateReports=0;supersededReports=0;reviewReports=0;dateConflicts=0;referenceReports=0}
    $sourceGroups=@{}
    foreach($record in $Records){
        if([string](Get-QaTrendValue $record Scanner '') -cne $Scanner -or [string](Get-QaTrendValue $record Id '') -notmatch '^[0-9A-Fa-f]{64}$' -or [string](Get-QaTrendValue $record Hash '') -notmatch '^[0-9A-Fa-f]{64}$'){continue}
        $path=[string](Get-QaTrendValue $record SourcePath '');$identity=if($path){$path.ToUpperInvariant()}else{[string]$record.Id}
        if(-not $sourceGroups.ContainsKey($identity)){$sourceGroups[$identity]=New-Object 'Collections.Generic.List[object]'}
        [void]$sourceGroups[$identity].Add($record)
    }
    $current=New-Object 'Collections.Generic.List[object]'
    foreach($group in @($sourceGroups.Values)){
        $latest=[long]-1;$candidates=New-Object 'Collections.Generic.List[object]'
        foreach($record in $group){$ticks=Get-QaTrendArchivedTicks $record;if($ticks -gt $latest){$latest=$ticks;$candidates.Clear();[void]$candidates.Add($record)}elseif($ticks -eq $latest){[void]$candidates.Add($record)}}
        $hashes=@($candidates|ForEach-Object{([string]$_.Hash).ToUpperInvariant()}|Select-Object -Unique)
        if($hashes.Count -gt 1){$coverage.conflicts++;$coverage.supersededReports+=[math]::Max(0,$group.Count-$candidates.Count);continue}
        $winner=@($candidates|Sort-Object Id)[0];[void]$current.Add($winner);$coverage.supersededReports+=[math]::Max(0,$group.Count-1)
    }
    # Equal-content archive aliases represent one reading. Prefer independently
    # verified current measurement evidence if one alias has not been read yet.
    $contentGroups=@{}
    foreach($record in $current){
        $rawDate=Get-QaTrendDate ([string](Get-QaTrendValue $record ReportDate ''))
        if($null -ne $rawDate -and -not (Test-QaTrendInPeriod $rawDate $start $end)){continue}
        $hash=([string]$record.Hash).ToUpperInvariant()
        $analysis=Get-QaSavedAnalysis -Config $Config -Record $record
        $measurement=Get-QaTrendValue $analysis MeasurementsDocument $null
        $score=if($null -ne $analysis -and [string](Get-QaTrendValue $analysis Status '') -ne 'ReadError' -and [int](Get-QaTrendValue $measurement MeasurementVersion 0) -eq 1){3}elseif($null -ne $analysis -and [string](Get-QaTrendValue $analysis Status '') -ne 'ReadError'){2}elseif($null -ne $analysis){1}else{0}
        if(Test-QaTrendReference $analysis){$score=-1}
        if($score -eq 3){
            $class=Get-QaTrendValue $analysis DocumentClassification $null
            if((Test-QaTrendTrue (Get-QaTrendValue $class CompleteRead $false)) -and (Test-QaTrendTrue (Get-QaTrendValue $measurement CompleteRead $false))){$score+=2}
            if([string](Get-QaTrendValue $class DateStatus '') -ceq 'Consensus'){$score+=2}
            if(@(Get-QaTrendValue $measurement Measurements @()).Count){$score++}
            $printed=Get-QaTrendDate ([string](Get-QaTrendValue $class ReportDate ''))
            if($null -ne $rawDate -and $null -ne $printed -and $rawDate -ne $printed){$score-=3}
        }
        $entry=[pscustomobject]@{record=$record;analysis=$analysis;score=$score;evidence=$null;aliasConflicts=@{}}
        if(-not $contentGroups.ContainsKey($hash)){$contentGroups[$hash]=$entry}else{
            $coverage.duplicateReports++;$prior=$contentGroups[$hash]
            if($null -eq $prior.evidence){$prior.evidence=Get-QaTrendAliasEvidence $prior.analysis $prior.record $Scanner $Metric;if($null -eq $prior.evidence){$prior.evidence=@{}}}
            $evidence=Get-QaTrendAliasEvidence $analysis $record $Scanner $Metric;if($null -eq $evidence){$evidence=@{}}
            foreach($identity in @($evidence.Keys)){if($prior.evidence.ContainsKey($identity) -and $prior.evidence[$identity] -cne $evidence[$identity]){$prior.aliasConflicts[$identity]=$true}elseif(-not $prior.evidence.ContainsKey($identity)){$prior.evidence[$identity]=$evidence[$identity]}}
            if($score -gt $prior.score -or ($score -eq $prior.score -and [string]::CompareOrdinal([string]$record.Id,[string]$prior.record.Id) -lt 0)){$entry.evidence=$prior.evidence;$entry.aliasConflicts=$prior.aliasConflicts;$contentGroups[$hash]=$entry}
        }
    }
    $pending=New-Object 'Collections.Generic.List[string]';$pointsByIdentity=@{};$dataLimitReached=$false;$metricRows=0
    $knownWarnings=@('MixedPrintedObservations','IncompleteMeasurementRow','UnsupportedMeasurementRow','MulticolumnMeasurementRow','UnsupportedNumericFormat','InvalidPrintedLimits','MeasurementLimitReached','AmbiguousDuplicateMeasurement')
    foreach($entry in @($contentGroups.Values|Sort-Object @{Expression={[string]$_.record.ReportDate}},@{Expression={[string]$_.record.Id}})){
        $record=$entry.record;$analysis=$entry.analysis;$measurement=Get-QaTrendValue $analysis MeasurementsDocument $null;$doc=Get-QaTrendValue $analysis DocumentClassification $null
        $rawDate=Get-QaTrendDate ([string](Get-QaTrendValue $record ReportDate ''));$printedDate=Get-QaTrendDate ([string](Get-QaTrendValue $doc ReportDate ''));$time=[string](Get-QaTrendValue $doc ReportTime '')
        $timestamp=[datetime]::MinValue;$dated=($null -ne $printedDate -and [string](Get-QaTrendValue $doc DateStatus '') -ceq 'Consensus' -and [datetime]::TryParseExact(([string](Get-QaTrendValue $doc ReportDate '')+' '+$time),'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$timestamp) -and $printedDate -le (Get-Date).Date.AddDays(1))
        $dateConflict=($dated -and (($null -ne $rawDate -and $rawDate -ne $printedDate) -or ([string](Get-QaTrendValue $record ReportTime '') -and [string](Get-QaTrendValue $record ReportTime '') -cne $time)))
        $date=if($dated){$printedDate}else{$rawDate}
        if($null -ne $date -and -not (Test-QaTrendInPeriod $date $start $end) -and -not $dateConflict){continue}
        $coverage.savedReports++
        if($null -eq $date){$coverage.unknownDates++}
        if($null -ne $analysis -and [string](Get-QaTrendValue $analysis Status '') -ceq 'ReadError'){$coverage.failedReports++;continue}
        if(Test-QaTrendReference $analysis){$coverage.referenceReports++;$coverage.readReports++;continue}
        if($null -eq $analysis -or [int](Get-QaTrendValue $measurement MeasurementVersion 0) -ne 1 -or (Test-QaTrendCapabilityPending $measurement $doc $Metric)){$coverage.pendingReports++;if($pending.Count -lt 100){[void]$pending.Add([string]$record.Id)};continue}
        $coverage.readReports++
        if(-not $dated -or $dateConflict -or -not (Test-QaTrendTrue (Get-QaTrendValue $doc CompleteRead $false)) -or -not (Test-QaTrendTrue (Get-QaTrendValue $measurement CompleteRead $false)) -or [string](Get-QaTrendValue $measurement Status '') -cnotin @('Extracted','NeedsReview') -or -not (Test-QaTrendMetricDocument $measurement $doc $Metric)){
            $coverage.unsupportedReports++;if($dateConflict -or [string](Get-QaTrendValue $doc DateStatus '') -cin @('Conflict','Invalid')){$coverage.dateConflicts++};continue
        }
        $reportWarnings=New-Object 'Collections.Generic.List[string]'
        if([string](Get-QaTrendValue $measurement Status '') -ceq 'NeedsReview'){[void]$reportWarnings.Add('DocumentNeedsReview')}
        if([string](Get-QaTrendValue $analysis Status '') -ceq 'ReportedFailure'){[void]$reportWarnings.Add('PrintedObservationNeedsReview')}
        foreach($issue in @(Get-QaTrendValue $measurement Issues @())){if([string]$issue -cin $knownWarnings){[void]$reportWarnings.Add([string]$issue)}}
        foreach($section in @(Get-QaTrendValue $doc Sections @())){foreach($outcome in @(Get-QaTrendValue $section PrintedOutcomes @())){if(([regex]::Replace([string]$outcome,'\s+',' ')).ToUpperInvariant() -cin @('NOT OK','FAIL','FAILED','ERROR','WARNING','NOT EVALUATED')){[void]$reportWarnings.Add('PrintedObservationNeedsReview')}}}
        $rows=New-Object 'Collections.Generic.List[object]';$seenRows=@{}
        foreach($row in @(Get-QaTrendValue $measurement Measurements @()|Select-Object -First 100)){
            if([string](Get-QaTrendValue $row Code '') -cne $Metric -or [string](Get-QaTrendValue $row Unit '') -cne $unit -or [string](Get-QaTrendValue $row Status '') -cnotin @('Printed','NeedsReview')){continue}
            $page=[int](Get-QaTrendValue $row Page 0);$context=Get-QaTrendRowContext $row $Metric
            if($null -eq $context -or $page -lt 1 -or $page -gt [int](Get-QaTrendValue $doc ReadPages 0)){continue}
            $value=Get-QaTrendNumber (Get-QaTrendValue $row Value);if($null -eq $value){continue}
            $lower=Get-QaTrendNumber (Get-QaTrendValue $row LowerLimit);$upper=Get-QaTrendNumber (Get-QaTrendValue $row UpperLimit)
            $warnings=New-Object 'Collections.Generic.List[string]';foreach($warning in $reportWarnings){[void]$warnings.Add($warning)}
            if($null -eq $lower -or $null -eq $upper -or $lower -gt $upper){$lower=$null;$upper=$null;[void]$warnings.Add('PrintedLimitsUnavailable')}
            if([string](Get-QaTrendValue $row Status '') -ceq 'NeedsReview'){[void]$warnings.Add('MeasurementNeedsReview')}
            $series=$Scanner+'|'+$Metric+'|'+$context.suffix
            if($seenRows.ContainsKey($series)){$seenRows[$series]++}else{$seenRows[$series]=1}
            [void]$rows.Add([pscustomobject]@{_series=$series;_hash=[string]$record.Hash;_mode=[string]$context.mode;_system=[string]$context.system;_slice=[int]$context.slice;_context=[string]$context.context;_label=[string]$context.label;recordId=[string]$record.Id;date=$printedDate.ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture);time=$time;value=$value;unit=$unit;lower=$lower;upper=$upper;page=$page;reviewWarning=($warnings.Count -gt 0);outsidePrintedRange=($null -ne $lower -and ($value -lt $lower -or $value -gt $upper));warnings=@($warnings|Select-Object -Unique)})
        }
        if(-not $rows.Count){$coverage.unsupportedReports++}
        if($reportWarnings.Count -or @($rows|Where-Object reviewWarning).Count){$coverage.reviewReports++}
        foreach($point in $rows){
            if($seenRows[[string]$point._series] -gt 1){$coverage.conflicts++;continue}
            $identity=[string]$point._series+'|'+[string]$point.date+'|'+[string]$point.time
            if($entry.aliasConflicts.ContainsKey($identity)){$coverage.conflicts++;continue}
            if(-not $pointsByIdentity.ContainsKey($identity)){$pointsByIdentity[$identity]=New-Object 'Collections.Generic.List[object]'}
            [void]$pointsByIdentity[$identity].Add($point);$metricRows++
            if($metricRows -ge 50000){$dataLimitReached=$true;break}
        }
        if($dataLimitReached){break}
    }
    $bySeries=@{}
    foreach($identity in @($pointsByIdentity.Keys)){
        $rows=@($pointsByIdentity[$identity].ToArray());$values=@($rows|ForEach-Object{([string]$_.value)+'|'+[string]$_.lower+'|'+[string]$_.upper}|Select-Object -Unique)
        if($values.Count -gt 1){$coverage.conflicts++;continue}
        $point=@($rows|Sort-Object recordId)[0]
        # Identical independent copies of one timestamp/value are shown once.
        if($rows.Count -gt 1){$coverage.duplicateReports+=($rows.Count-1)}
        $key=[string]$point._series
        if(-not $bySeries.ContainsKey($key)){$bySeries[$key]=New-Object 'Collections.Generic.List[object]'}
        [void]$bySeries[$key].Add($point)
    }
    $seriesRows=New-Object 'Collections.Generic.List[object]'
    foreach($key in @($bySeries.Keys|Sort-Object)){
        $first=$bySeries[$key][0]
        [void]$seriesRows.Add([pscustomobject]@{key=$key;label=[string]$first._label;metric=$Metric;unit=$unit;mode=[string]$first._mode;system=[string]$first._system;slice=[int]$first._slice;context=[string]$first._context;count=$bySeries[$key].Count})
    }
    $orderedSeries=@($seriesRows|Sort-Object mode,system,slice)
    $available=@($orderedSeries|Where-Object{(-not $Mode -or $_.mode -ceq $Mode) -and (-not $SourceSystem -or $_.system -ceq $SourceSystem) -and (-not $Slice -or $_.slice -eq $Slice)})
    $selected=''
    if($SeriesKey){if(@($available|Where-Object key -CEQ $SeriesKey).Count){$selected=$SeriesKey}}elseif($available.Count){$selected=[string]$available[0].key}
    $all=@();if($selected){$all=@($bySeries[$selected]|Sort-Object date,time,recordId)}
    $count=$all.Count;$summary=[pscustomobject]@{latest=$null;first=$null;change=$null;min=$null;max=$null;count=$count;firstDate='';latestDate='';scope=$(if($dataLimitReached){'availableData'}else{'selectedPeriod'})}
    if($count){$summary.first=$all[0].value;$summary.latest=$all[$count-1].value;$summary.change=[decimal]$summary.latest-[decimal]$summary.first;$summary.min=($all|Measure-Object value -Minimum).Minimum;$summary.max=($all|Measure-Object value -Maximum).Maximum;$summary.firstDate=[string]$all[0].date;$summary.latestDate=[string]$all[$count-1].date}
    $limited=($count -gt 5000);if($limited){$all=@($all|Select-Object -Last 5000)}
    $public=New-Object 'Collections.Generic.List[object]'
    foreach($point in $all){[void]$public.Add(($point|Select-Object recordId,date,time,value,unit,lower,upper,page,reviewWarning,outsidePrintedRange,warnings))}
    $message=if($count){'Printed measurements from the selected scanner and test context.'}elseif($coverage.pendingReports){'Read the remaining saved reports to collect supported measurements for this period.'}else{'No complete, date-consistent readings match the selected series.'}
    return [pscustomobject]@{schemaVersion=1;scanner=$Scanner;metric=$Metric;unit=$unit;metricDefinition=$definition;selection=[pscustomobject]@{scanner=$Scanner;metric=$Metric;mode=$Mode;system=$SourceSystem;slice=$Slice;startDate=$StartDateISO;endDate=$EndDateISO};scanners=@($scanners.ToArray());series=@($orderedSeries);selectedSeries=$selected;points=@($public.ToArray());summary=$summary;coverage=[pscustomobject]$coverage;pendingIds=@($pending.ToArray());pendingIdLimitReached=($coverage.pendingReports -gt $pending.Count);totalPointCount=$count;pointLimitReached=$limited;dataLimitReached=$dataLimitReached;message=$message;notes=@('Change means latest minus first reading in the selected period; it is not a calibration baseline or clinical drift diagnosis.','Readings are separated by scanner, metric and explicitly printed test context. Unprinted system/slice identities are not invented. Confirm protocol consistency before interpreting changes.','Only explicit printed limits are displayed. Outside a printed range is a documentary flag, not a clinical approval or failure.');clinicalResult='Not inferred'}
}
Export-ModuleMember -Function Get-QaTrendData,Get-QaTrendMetricDefinition
