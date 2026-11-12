# Cached document presence and existing recorded Monthly evidence are separate.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Archive.psm1') -DisableNameChecking -WarningAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot 'ContentClassifier.psm1') -DisableNameChecking -WarningAction SilentlyContinue
function Get-QaMonthlyValue($Object,[string]$Name,$Default=$null){
    if($null -ne $Object){if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}elseif($null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name}};return $Default
}
function ConvertTo-QaMonthlyDate([string]$Month){
    $date=[datetime]::MinValue
    if($Month -cnotmatch '^[0-9]{4}-(?:0[1-9]|1[0-2])$' -or -not [datetime]::TryParseExact($Month,'yyyy-MM',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)){throw 'Choose a calendar month using yyyy-MM.'}
    return $date
}
function Get-QaMonthlyComponentOptions {
    $extra=@{Slice=@('Slice thickness');ExternalLightmarker=@('External Lightm.','External Lightm');SagittalCoronalLightmarker=@('Sag./Cor. Lightm.','Sag./Cor. Lightm');TopogramPosition=@('Topogram Pos.','Topogram Pos')}
    foreach($definition in @(Get-QaContentSectionDefinitions)){
        $aliases=New-Object 'Collections.Generic.List[string]';$seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $values=@([string]$definition.Name,[string]$definition.Code);if($extra.ContainsKey([string]$definition.Code)){$values+=@($extra[[string]$definition.Code])}
        foreach($value in $values){if($seen.Add($value)){[void]$aliases.Add($value)}}
        [pscustomobject]@{code=[string]$definition.Code;label=[string]$definition.Name;aliases=@($aliases.ToArray())}
    }
}
function ConvertTo-QaMonthlyLabels($Values){
    $module=(Get-Command Get-QaMonthlyCoverage).Module
    return @(&$module {param($InputLabels) Get-QaComponentLabels -Values $InputLabels -Context 'Monthly checklist history'} $Values)
}
function Get-QaMonthlySetup {
    param($Source,[datetime]$Today=(Get-Date))
    $history=New-Object 'Collections.Generic.List[object]';$seen=@{}
    foreach($version in @(Get-QaMonthlyValue $Source MonthlyChecklistHistory @())){
        $month=[string](Get-QaMonthlyValue $version EffectiveMonth '');[void](ConvertTo-QaMonthlyDate $month)
        if($seen.ContainsKey($month)){throw 'The saved Monthly checklist history contains a repeated effective month.'};$seen[$month]=$true
        [void]$history.Add([pscustomobject]@{effectiveMonth=$month;checklist=@(ConvertTo-QaMonthlyLabels @(Get-QaMonthlyValue $version Components @()))})
    }
    $ordered=@($history.ToArray()|Sort-Object effectiveMonth);$latest=if($ordered.Count){[string]$ordered[-1].effectiveMonth}else{''};$next=$Today.ToString('yyyy-MM')
    if($latest -and $latest -ge $next){$date=ConvertTo-QaMonthlyDate $latest;if($date.Year -eq 9999 -and $date.Month -eq 12){$next=''}else{$next=$date.AddMonths(1).ToString('yyyy-MM')}}
    return [pscustomobject]@{checklist=@(ConvertTo-QaMonthlyLabels @(Get-QaMonthlyValue $Source MonthlyChecklist @()));checklistEffectiveMonth=$latest;monthlyChecklistHistory=$ordered;nextChecklistEffectiveMonth=$next}
}
function Select-QaMonthlyCurrentRecords {
    param([object[]]$Records=@())
    $latest=@{};$times=@{}
    foreach($record in $Records){
        $key=[string](Get-QaMonthlyValue $record Scanner '')+'|'+([string](Get-QaMonthlyValue $record SourcePath (Get-QaMonthlyValue $record Id ''))).ToUpperInvariant();$value=Get-QaMonthlyValue $record FirstArchived ''; $stamp=[datetime]::MinValue;$ticks=[long]0
        if($value -is [datetime]){$ticks=$value.ToUniversalTime().Ticks}elseif([datetime]::TryParse([string]$value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$stamp)){$ticks=$stamp.ToUniversalTime().Ticks}
        if(-not $latest.ContainsKey($key) -or $ticks -ge $times[$key]){$latest[$key]=$record;$times[$key]=$ticks}
    }
    return @($latest.Values|Sort-Object Scanner,ReportDate,ReportTime,Id)
}
function Get-QaMonthlyObservedComponents {
    param($Document,$Context)
    $codes=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$warnings=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $complete=Get-QaMonthlyValue $Document CompleteRead $false
    if([bool](Get-QaMonthlyValue $Context hasReferenceEvidence $false) -or [bool](Get-QaMonthlyValue $Context isReference $false) -or [string](Get-QaMonthlyValue $Document DocumentKind '') -ceq 'Reference' -or $complete -isnot [bool] -or -not $complete -or [string](Get-QaMonthlyValue $Document Status '') -cne 'Recognized' -or [string](Get-QaMonthlyValue $Document DateStatus '') -cne 'Consensus' -or -not [bool](Get-QaMonthlyValue $Context dateSafe $false) -or [bool](Get-QaMonthlyValue $Context dateConflict $false) -or [bool](Get-QaMonthlyValue $Context typeConflict $false)){return [pscustomobject]@{eligible=$false;codes=@();warnings=@()}}
    $profile=[string](Get-QaMonthlyValue $Document ProfileId '')
    if($profile -cnotin @('siemens-iec-basic-v1','siemens-iec-extended-v1','siemens-iec-additional-v1','siemens-quality-daily-v1')){return [pscustomobject]@{eligible=$false;codes=@();warnings=@()}}
    $known=@{};foreach($option in @(Get-QaMonthlyComponentOptions)){$known[$option.code]=$true};$readPages=0;[void][int]::TryParse([string](Get-QaMonthlyValue $Document ReadPages 0),[ref]$readPages)
    foreach($section in @(Get-QaMonthlyValue $Document Sections @())){
        $code=[string](Get-QaMonthlyValue $section Code '');$page=0;[void][int]::TryParse([string](Get-QaMonthlyValue $section Page 0),[ref]$page);$evidence=[string](Get-QaMonthlyValue $section EvidenceCode '')
        if(-not $known.ContainsKey($code) -or $page -lt 2 -or $page -gt $readPages){continue}
        $outcomes=@(Get-QaMonthlyValue $section PrintedOutcomes @()|Where-Object{$_ -is [string] -and $_ -cmatch '^(OK|NOT OK|NOT EVALUATED|PASS|PASSED|FAIL|FAILED|ERROR|WARNING)$'})
        $body=Get-QaMonthlyValue $section BodyEvidence $null
        $typed=($body -is [bool] -and $body -eq $true)
        # Older recognized caches had no BodyEvidence field. Literal outcomes
        # from exact numbered body evidence remain reusable without a reread.
        $legacy=($null -eq $body -and $page -ge 3 -and $evidence -ceq ('NumberedBodySection.'+$code) -and $outcomes.Count -gt 0)
        $anchored=(($page -ge 3 -and $evidence -ceq ('NumberedBodySection.'+$code)) -or ($page -eq 2 -and $evidence -ceq ('ComponentTitle.'+$code)))
        if(-not $anchored -or -not ($typed -or $legacy)){continue}
        [void]$codes.Add($code)
        if(@($outcomes|Where-Object{$_ -cin @('NOT OK','NOT EVALUATED','FAIL','FAILED','ERROR','WARNING')}).Count){[void]$warnings.Add('PrintedFindingNeedsReview')}
    }
    return [pscustomobject]@{eligible=$true;codes=@($codes|Sort-Object);warnings=@($warnings|Sort-Object)}
}
function New-QaMonthlyWorkspace {
    param($Config,[string]$Month,[object[]]$Bindings=@(),[object[]]$Records=@(),[datetime]$Today=(Get-Date),[int]$ReportLimit=1000)
    $date=ConvertTo-QaMonthlyDate $Month;$current=$Today.ToString('yyyy-MM');$options=@(Get-QaMonthlyComponentOptions);$aliases=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($option in $options){foreach($alias in $option.aliases){$aliases[$alias]=$option.code}}
    $referenceIds=@{};foreach($binding in $Bindings){if([bool](Get-QaMonthlyValue $binding.Context hasReferenceEvidence $false) -or [bool](Get-QaMonthlyValue $binding.Context isReference $false)){$referenceIds[[string]$binding.Record.Id]=$true}}
    $coverage=@(Get-QaMonthlyCoverage -Config $Config -Records @($Records|Where-Object{-not $referenceIds.ContainsKey([string]$_.Id)}) -Months @($Month));$scanners=New-Object 'Collections.Generic.List[object]';$limitReached=$false;$remaining=$ReportLimit
    foreach($source in @($Config.Sources)){
        $setup=Get-QaMonthlySetup $source $Today;$required=@(Get-QaChecklistForMonth $source $Month);$selected=@($setup.monthlyChecklistHistory|Where-Object effectiveMonth -le $Month|Sort-Object effectiveMonth|Select-Object -Last 1);$effective=if($selected.Count){[string]$selected[0].effectiveMonth}elseif(-not $setup.monthlyChecklistHistory.Count){'0001-01'}else{''}
        $active=[datetime]::MinValue;$activeText=[string](Get-QaMonthlyValue $source ActiveFrom '');if($activeText){[void][datetime]::TryParseExact($activeText,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$active)}
        $applicability=if(-not [bool]$source.ExpectedMonthly){'NotRequired'}elseif($active -ne [datetime]::MinValue -and ($active.ToString('yyyy-MM') -gt $Month -or ($Month -ceq $current -and $active.Date -gt $Today.Date))){'NotActive'}elseif($Month -gt $current){'Future'}else{'Required'}
        $reports=New-Object 'Collections.Generic.List[object]';$received=New-Object 'Collections.Generic.List[string]';$found=@{};$eligible=0;$warningReports=0;$waiting=0;$review=0;$excluded=0
        foreach($binding in @($Bindings|Where-Object{[string]$_.Record.Scanner -ceq [string]$source.Scanner})){
            if([bool]$binding.Context.hasReferenceEvidence -or [bool]$binding.Context.isReference){$excluded++;continue}
            if([string]$binding.Filing.category -cne 'Monthly'){continue}
            $observation=Get-QaMonthlyObservedComponents $binding.Context.document $binding.Context;$isReceived=([bool]$binding.Available -and -not [bool]$binding.Filing.pending);$canDetect=($isReceived -and $observation.eligible)
            if($isReceived){[void]$received.Add([string]$binding.Record.Id)}
            if([string]$binding.Filing.filingState -ceq 'WaitingRead'){$waiting++}elseif([string]$binding.Filing.filingState -ceq 'NeedsReview' -or -not $binding.Available){$review++}
            if($canDetect){$eligible++;foreach($code in $observation.codes){if(-not $found.ContainsKey($code)){$found[$code]=New-Object 'Collections.Generic.List[string]'};[void]$found[$code].Add([string]$binding.Record.Id)};if($observation.warnings.Count){$warningReports++}}
            $warnings=@();if($canDetect){$warnings=@($observation.warnings)};if(-not $binding.Available){$warnings+=@('SavedPdfUnavailable')}
            if($remaining -gt 0){[void]$reports.Add([pscustomobject]@{id=[string]$binding.Record.Id;date=[string]$binding.Context.effectiveDate;time=[string]$binding.Context.effectiveTime;category='Monthly';filingState=[string]$binding.Filing.filingState;inferred=[bool]$binding.Filing.inferred;readStatus=[string]$binding.Context.view.status;available=[bool]$binding.Available;detectedCodes=$(if($canDetect){@($observation.codes)}else{@()});printedWarnings=$warnings});$remaining--}else{$limitReached=$true}
        }
        $visibleIds=@{};foreach($report in $reports){$visibleIds[[string]$report.id]=$true}
        $items=New-Object 'Collections.Generic.List[object]';$missing=New-Object 'Collections.Generic.List[string]';$unmatched=New-Object 'Collections.Generic.List[string]';$foundCount=0
        foreach($label in $required){$code=if($aliases.ContainsKey([string]$label)){$aliases[[string]$label]}else{''};$present=($code -and $found.ContainsKey($code));if($present){$foundCount++}else{[void]$missing.Add([string]$label)};if(-not $code){[void]$unmatched.Add([string]$label)};[void]$items.Add([pscustomobject]@{label=[string]$label;code=[string]$code;found=[bool]$present;reportIds=$(if($present){@($found[$code].ToArray()|Where-Object{$visibleIds.ContainsKey([string]$_)})}else{@()})})}
        $allFound=($applicability -ceq 'Required' -and $required.Count -gt 0 -and $foundCount -eq $required.Count)
        $detectedStatus=if($applicability -cne 'Required'){$applicability}elseif(-not $required.Count){'ChecklistNotSet'}elseif($allFound){'AllItemsFound'}elseif($foundCount){'Partial'}else{'NoneFound'}
        $due=[int](Get-QaMonthlyValue $source MonthlyDueDay 0);$dueDate=if($due){New-Object datetime $date.Year,$date.Month,([math]::Min($due,[datetime]::DaysInMonth($date.Year,$date.Month)))}else{$null};$timing=if($applicability -cne 'Required'){$applicability}elseif(-not $due){'NotConfigured'}elseif($active -ne [datetime]::MinValue -and $active.ToString('yyyy-MM') -ceq $Month -and $dueDate.Date -lt $active.Date){'ConfirmFirstMonthDue'}elseif($allFound){'ItemsFound'}elseif($Today.Date -gt $dueDate.Date){'Overdue'}elseif($Today.Date -eq $dueDate.Date){'DueToday'}else{'Upcoming'}
        $legacy=@($coverage|Where-Object Scanner -ceq $source.Scanner|Select-Object -First 1);$reviewed=if($legacy.Count){[pscustomobject]@{status=[string]$legacy[0].Status;confirmedReportCount=[int]$legacy[0].ConfirmedReportCount;requiredComponents=@($legacy[0].RequiredComponents);confirmedComponents=@($legacy[0].ConfirmedComponents);missingComponents=@($legacy[0].MissingComponents)}}else{[pscustomobject]@{status='NotRequired';confirmedReportCount=0;requiredComponents=$required;confirmedComponents=@();missingComponents=@()}}
        [void]$scanners.Add([pscustomobject]@{id=[string]$source.Scanner;name=[string]$source.Name;expectedMonthly=[bool]$source.ExpectedMonthly;applicability=$applicability;checklist=[pscustomobject]@{effectiveMonth=$effective;items=@($items.ToArray());requiredCount=$required.Count;unmatchedItems=@($unmatched.ToArray())};receipt=[pscustomobject]@{count=$received.Count;reportIds=@($received.ToArray()|Where-Object{$visibleIds.ContainsKey([string]$_)});waitingCount=$waiting;reviewCount=$review};detected=[pscustomobject]@{status=$detectedStatus;foundCount=$foundCount;requiredCount=$required.Count;allItemsFound=$allFound;missingItems=@($missing.ToArray());eligibleReportCount=$eligible;printedWarningReportCount=$warningReports};reviewed=$reviewed;due=[pscustomobject]@{day=$due;date=$(if($null -ne $dueDate){$dueDate.ToString('yyyy-MM-dd')}else{''});timing=$timing;policy='CurrentConfiguration'};reports=@($reports.ToArray());excludedReferenceCount=$excluded})
    }
    return [pscustomobject]@{schemaVersion=1;month=$Month;today=$Today.ToString('yyyy-MM-dd');reportLimit=$ReportLimit;limitReached=$limitReached;componentOptions=$options;scanners=@($scanners.ToArray())}
}
Export-ModuleMember -Function ConvertTo-QaMonthlyDate,Get-QaMonthlyComponentOptions,Get-QaMonthlySetup,Select-QaMonthlyCurrentRecords,Get-QaMonthlyObservedComponents,New-QaMonthlyWorkspace
