# Conservative extraction of explicitly printed single-metric IEC tables.
# Measurements remain documentary evidence, never a clinical approval.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ContentClassifier.psm1') -DisableNameChecking -WarningAction SilentlyContinue

function Get-QaMeasurementParserVersion { return 1 }
function Get-QaMeasurementSupportRevision { return 2 }

function ConvertTo-QaMeasurementNumber {
    param([string]$Value)
    $parsed=[decimal]0
    $style=[Globalization.NumberStyles]::AllowLeadingSign -bor [Globalization.NumberStyles]::AllowDecimalPoint
    if(-not [decimal]::TryParse($Value.Replace(',','.'),$style,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)){return $null}
    return $parsed.ToString('0.######',[Globalization.CultureInfo]::InvariantCulture)
}

function Get-QaMeasurementSection {
    param([string]$Label)
    $label=([regex]::Replace($Label,'\s+',' ')).Trim()
    if($label -match '^Homogeneity\s*/\s*Water$'){return 'HomogeneityWater'}
    if($label -match '^Noise$'){return 'Noise'}
    if($label -match '^Slice$'){return 'Slice'}
    return ''
}

# Manufacturer Daily reports use inline single-system rows followed by one
# explicitly printed range for that table. Dual-system columns and nonstandard
# acquisition names are excluded rather than merged into the simple Body series.
function Add-QaDailyMeasurementRows {
    param($Lines,$Rows,$Counts,$Issues,[string]$Number)
    $valuePattern='^Slice[ \t]+(?<slice>[1-9][0-9]{0,2})[ \t]+(?<value>'+$Number+')[ \t]+HU(?:[ \t]*\([ \t]*'+$Number+'[ \t]*\))?$'
    $rangePattern='^Tolerance[ \t]+(?<lower>'+$Number+')[ \t]*(?:\.{3}|'+[char]0x2026+')[ \t]*(?<upper>'+$Number+')[ \t]+HU$'
    $section='';$mode='';$pendingSection=$false;$pendingMode=$false;$noiseHeading=$false
    for($i=0;$i -lt $Lines.Count;$i++){
        $entry=$Lines[$i];$line=[string]$entry.Text
        if($entry.Page -lt 3){continue}
        if($line -match '^[0-9]{1,2}\.$' -and $i+1 -lt $Lines.Count -and $Lines[$i+1].Page -eq $entry.Page -and $Lines[$i+1].Text -match '^Quality[ \t]+Daily(?:[ \t]+.*)?$'){$line+=' '+$Lines[$i+1].Text;$i++}
        $heading=[regex]::Match($line,'(?i)^[0-9]{1,2}\.[ \t]*Quality[ \t]+Daily(?:[ \t]+(?<label>.*))?$')
        if($heading.Success){$section='';$mode='';$noiseHeading=$false;$pendingMode=$false;$label=$heading.Groups['label'].Value.Trim();$pendingSection=(-not $label);if($label -ceq 'Noise'){$section='Noise'}elseif($label -ceq 'Homogeneity'){$section='HomogeneityWater'};continue}
        if($pendingSection){if($line -ceq 'Noise'){$section='Noise'}elseif($line -ceq 'Homogeneity'){$section='HomogeneityWater'};$pendingSection=$false;continue}
        if(-not $section){continue}
        if($pendingMode){if($line -match '^(?:Typical[ \t]+)?(?<mode>head|body)[ \t]+mode$'){$mode=if($Matches['mode'] -ieq 'head'){'Head'}else{'Body'}};$pendingMode=$false}
        if($line -match '^Test[ \t]*:'){$mode='';$noiseHeading=$false;if($line -match '^Test[ \t]*:[ \t]*(?:Typical[ \t]+)?(?<mode>head|body)[ \t]+mode$'){$mode=if($Matches['mode'] -ieq 'head'){'Head'}else{'Body'}}elseif($line -match '^Test[ \t]*:[ \t]*$'){$pendingMode=$true};continue}
        if(-not $mode){continue}
        if($section -ceq 'Noise' -and $line -ceq 'Result'){$noiseHeading=$true;continue}
        $code=''
        if($section -ceq 'Noise' -and $noiseHeading -and $line -ceq 'Results for System A'){$code='ImageNoise'}
        elseif($section -ceq 'HomogeneityWater' -and $line -ceq 'Water Value Results for System A'){$code='WaterCTNumber'}
        if(-not $code){continue};$noiseHeading=$false
        $block=New-Object 'Collections.Generic.List[object]';$range=$null;$j=$i+1
        for(;$j -lt $Lines.Count;$j++){
            if($Lines[$j].Page -ne $entry.Page){break}
            $row=[regex]::Match([string]$Lines[$j].Text,$valuePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if($row.Success){[void]$block.Add([pscustomobject]@{Slice=$row.Groups['slice'].Value;Value=$row.Groups['value'].Value;Page=[int]$Lines[$j].Page});continue}
            $candidate=[regex]::Match([string]$Lines[$j].Text,$rangePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if($candidate.Success){$range=$candidate};break
        }
        if(-not $block.Count){continue}
        if($null -eq $range){[void]$Issues.Add('UnsupportedMeasurementRow');continue}
        if($j+1 -lt $Lines.Count -and $Lines[$j+1].Page -eq $entry.Page -and ([regex]::IsMatch([string]$Lines[$j+1].Text,$rangePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase) -or [regex]::IsMatch([string]$Lines[$j+1].Text,$valuePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase))){[void]$Issues.Add('MulticolumnMeasurementRow');continue}
        $lower=ConvertTo-QaMeasurementNumber $range.Groups['lower'].Value;$upper=ConvertTo-QaMeasurementNumber $range.Groups['upper'].Value
        if($null -eq $lower -or $null -eq $upper){[void]$Issues.Add('UnsupportedNumericFormat');continue}
        $status='Printed';if([decimal]::Parse($lower,[Globalization.CultureInfo]::InvariantCulture) -gt [decimal]::Parse($upper,[Globalization.CultureInfo]::InvariantCulture)){$lower=$null;$upper=$null;$status='NeedsReview';[void]$Issues.Add('InvalidPrintedLimits')}
        foreach($valueRow in $block){
            $value=ConvertTo-QaMeasurementNumber $valueRow.Value;if($null -eq $value){[void]$Issues.Add('UnsupportedNumericFormat');continue}
            $key=$code+'|'+$mode+'|A|'+$valueRow.Slice;if($Counts.ContainsKey($key)){$Counts[$key]++}else{$Counts[$key]=1}
            if($Rows.Count -lt 100){[void]$Rows.Add([pscustomobject]@{Code=$code;Label=$(if($code -ceq 'WaterCTNumber'){'Water CT value'}else{'Image noise'});Value=$value;Unit='HU';Page=$valueRow.Page;LowerLimit=$lower;UpperLimit=$upper;Mode=$mode;SourceSystem='A';Slice=$valueRow.Slice;Status=$status;ContextSection=$section;Source='PrintedDailyInlineTable';_Key=$key})}else{[void]$Issues.Add('MeasurementLimitReached')}
        }
        $i=$j
    }
}

function ConvertFrom-QaMeasurementText {
    [CmdletBinding()]param(
        [AllowEmptyString()][string]$Text='',
        [bool]$Truncated=$false,
        [bool]$NeedsOCR=$false,
        [int]$Pages=0,
        [int]$ReadPages=0
    )
    $rows=New-Object 'Collections.Generic.List[object]'
    $issues=New-Object 'Collections.Generic.List[string]'
    $result=[pscustomobject]@{MeasurementVersion=1;MeasurementSupportRevision=(Get-QaMeasurementSupportRevision);Status='NeedsReview';ReasonCode='NoSupportedTables';Reason='No supported water, noise or slice-thickness table was extracted. Review the original PDF.';CompleteRead=$false;Measurements=@();Issues=@();ClinicalResult='Not inferred'}
    if($NeedsOCR){$result.ReasonCode='NoReadableText';$result.Reason='No readable text is available for measurement extraction.';return $result}
    if($Text.Length -gt 2000000){$result.ReasonCode='InputLimit';$result.Reason='The text exceeds the bounded measurement-reading limit.';return $result}
    $classification=ConvertFrom-QaDocumentContent -Text $Text -Truncated $Truncated -NeedsOCR $NeedsOCR -Pages $Pages -ReadPages $ReadPages
    $result.CompleteRead=[bool]$classification.CompleteRead
    if($classification.ProfileId -ceq 'siemens-iec-reference-v1' -or ($null -ne $classification.PSObject.Properties['IsReference'] -and $classification.IsReference -is [bool] -and $classification.IsReference) -or ($null -ne $classification.PSObject.Properties['HasReferenceEvidence'] -and $classification.HasReferenceEvidence -is [bool] -and $classification.HasReferenceEvidence) -or ($null -ne $classification.PSObject.Properties['DocumentKind'] -and [string]$classification.DocumentKind -ceq 'Reference')){$result.ReasonCode='ReferenceDocument';$result.Reason='Historical reference documents are excluded from current printed-measurement trends.';return $result}
    if(-not $classification.ProfileId){$result.ReasonCode='UnsupportedProfile';$result.Reason='The document does not have a supported numbered IEC report profile.';return $result}
    if(-not $classification.CompleteRead){[void]$issues.Add('IncompleteRead')}
    if($classification.DateStatus -ne 'Consensus'){[void]$issues.Add('UncertainReportDate')}
    if(@($classification.Sections|Where-Object OutcomeStatus -eq 'Conflict').Count){[void]$issues.Add('MixedPrintedObservations')}

    $normalized=$Text.Replace([string][char]0x00a0,' ').Replace([string][char]0x202f,' ').Replace([string][char]0x2212,'-').Replace("`r`n","`n").Replace("`r","`n")
    $lines=New-Object 'Collections.Generic.List[object]';$page=0
    foreach($line in ($normalized -split "`n")){
        if($line -match '^--- Page ([0-9]+) ---$'){$page=[int]$Matches[1];continue}
        $trimmed=$line.Trim()
        if($trimmed){[void]$lines.Add([pscustomobject]@{Text=$trimmed;Page=$page})}
        if($lines.Count -gt 50000){$result.ReasonCode='InputLimit';$result.Reason='The text exceeds the bounded measurement-reading limit.';return $result}
    }
    # Commas are supported only with one or two decimal digits. A value such as
    # 1,234 is ambiguous between a decimal and a thousands grouping and is skipped.
    $number='[+-]?[0-9]{1,6}(?:\.[0-9]{1,6}|,[0-9]{1,2})?'
    $valuePattern='^(?<value>'+$number+')[ \t]+HU(?:[ \t]*\([ \t]*'+$number+'[ \t]*\))?$'
    $rangePattern='^(?<lower>'+$number+')[ \t]*(?:\.{3}|'+[char]0x2026+')[ \t]*(?<upper>'+$number+')[ \t]+HU$'
    $section='';$mode='Unspecified';$system='';$table='';$pendingSection=$false;$pendingMode=$false;$noiseHeading=$false
    $counts=@{}
    if($classification.ProfileId -ceq 'siemens-quality-daily-v1'){Add-QaDailyMeasurementRows -Lines $lines -Rows $rows -Counts $counts -Issues $issues -Number $number}
    for($i=0;$i -lt $lines.Count;$i++){
        $entry=$lines[$i];$line=[string]$entry.Text
        if($entry.Page -lt 3){continue}
        if($line -match '^[0-9]{1,2}\.$' -and $i+1 -lt $lines.Count -and $lines[$i+1].Page -eq $entry.Page -and $lines[$i+1].Text -match '^Quality[ \t]+IEC[ \t]+Constancy(?:[ \t]+.*)?$'){$line+=' '+$lines[$i+1].Text;$i++}
        $heading=[regex]::Match($line,'(?i)^[0-9]{1,2}\.[ \t]*Quality[ \t]+IEC[ \t]+Constancy(?:[ \t]+(?<label>.*))?$')
        if($heading.Success){
            $section='';$mode='Unspecified';$system='';$table='';$noiseHeading=$false;$pendingMode=$false
            $label=$heading.Groups['label'].Value.Trim();$pendingSection=(-not $label)
            if($label){$section=Get-QaMeasurementSection $label}
            continue
        }
        if($pendingSection){$section=Get-QaMeasurementSection $line;$pendingSection=$false;continue}
        if(-not $section){continue}
        if($pendingMode){
            if($line -match '^(?:Typical[ \t]+)?(?<mode>head|body)[ \t]+mode$'){$mode=if($Matches['mode'] -ieq 'head'){'Head'}else{'Body'}}
            $pendingMode=$false
        }
        if($line -match '^Test[ \t]*:'){
            $mode='Unspecified';$table='';$system='';$noiseHeading=$false
            if($line -match '^Test[ \t]*:[ \t]*(?:Typical[ \t]+)?(?<mode>head|body)[ \t]+mode$'){$mode=if($Matches['mode'] -ieq 'head'){'Head'}else{'Body'}}
            elseif($line -match '^Test[ \t]*:[ \t]*$'){$pendingMode=$true}
            continue
        }
        if($section -eq 'HomogeneityWater' -and $line -match '^Water Value Results for System (?<system>[AB])$'){$system=$Matches['system'].ToUpperInvariant();$table='WaterCTNumber';continue}
        if($section -eq 'Slice' -and $line -eq 'Result' -and $mode -cin @('Head','Body')){$table='SliceThickness';$system='';continue}
        if($table -ceq 'SliceThickness' -and $line -cmatch '^System (?<system>[AB])$'){$system=$Matches['system'];continue}
        if($section -eq 'Noise' -and $line -eq 'Result'){$table='';$noiseHeading=$true;continue}
        if($line -match '^Results for System (?<system>[AB])$'){
            $system=$Matches['system'].ToUpperInvariant();$table=''
            if($section -eq 'Noise' -and $noiseHeading){$table='ImageNoise'}
            $noiseHeading=$false;continue
        }
        if(-not $table){continue}
        if($table -ceq 'SliceThickness' -and -not $system){$table='';continue}
        if($line -notmatch '^Slice (?<slice>[0-9]{1,3})$'){$table='';continue}
        $slice=[int]$Matches['slice']
        if($slice -lt 1 -or $i+3 -ge $lines.Count){[void]$issues.Add('IncompleteMeasurementRow');$table='';continue}
        $tolerance=$lines[$i+1];$valueEntry=$lines[$i+2];$rangeEntry=$lines[$i+3]
        if($tolerance.Page -ne $entry.Page -or $valueEntry.Page -ne $entry.Page -or $rangeEntry.Page -ne $entry.Page -or $tolerance.Text -cne 'Tolerance'){
            [void]$issues.Add('UnsupportedMeasurementRow');$table='';continue
        }
        $unit=if($table -ceq 'SliceThickness'){'mm'}else{'HU'}
        $selectedValuePattern=$valuePattern.Replace('HU',$unit);$selectedRangePattern=$rangePattern.Replace('HU',$unit)
        $valueMatch=[regex]::Match([string]$valueEntry.Text,$selectedValuePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $rangeMatch=[regex]::Match([string]$rangeEntry.Text,$selectedRangePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if(-not $valueMatch.Success -or -not $rangeMatch.Success){[void]$issues.Add('UnsupportedMeasurementRow');$table='';continue}
        if($i+4 -lt $lines.Count -and ([regex]::IsMatch([string]$lines[$i+4].Text,$selectedValuePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase) -or [regex]::IsMatch([string]$lines[$i+4].Text,$selectedRangePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase))){
            [void]$issues.Add('MulticolumnMeasurementRow');$table='';continue
        }
        $value=ConvertTo-QaMeasurementNumber $valueMatch.Groups['value'].Value
        $lower=ConvertTo-QaMeasurementNumber $rangeMatch.Groups['lower'].Value
        $upper=ConvertTo-QaMeasurementNumber $rangeMatch.Groups['upper'].Value
        if($null -eq $value -or $null -eq $lower -or $null -eq $upper){[void]$issues.Add('UnsupportedNumericFormat');$table='';continue}
        $status='Printed'
        if([decimal]::Parse($lower,[Globalization.CultureInfo]::InvariantCulture) -gt [decimal]::Parse($upper,[Globalization.CultureInfo]::InvariantCulture)){$lower=$null;$upper=$null;$status='NeedsReview';[void]$issues.Add('InvalidPrintedLimits')}
        $key=$table+'|'+$mode+'|'+$system+'|'+$slice
        if($counts.ContainsKey($key)){$counts[$key]++}else{$counts[$key]=1}
        if($rows.Count -lt 100){
            [void]$rows.Add([pscustomobject]@{Code=$table;Label=$(if($table -ceq 'WaterCTNumber'){'Water CT value'}elseif($table -ceq 'SliceThickness'){'Slice thickness'}else{'Image noise'});Value=$value;Unit=$unit;Page=[int]$valueEntry.Page;LowerLimit=$lower;UpperLimit=$upper;Mode=$mode;SourceSystem=$system;Slice=$slice.ToString([Globalization.CultureInfo]::InvariantCulture);Status=$status;ContextSection=$section;Source='PrintedSingleMetricTable';_Key=$key})
        }else{[void]$issues.Add('MeasurementLimitReached')}
        $i+=3
    }
    $final=New-Object 'Collections.Generic.List[object]'
    foreach($row in $rows){
        if($counts[[string]$row._Key] -gt 1){[void]$issues.Add('AmbiguousDuplicateMeasurement');continue}
        if(-not $classification.CompleteRead){$row.Status='NeedsReview'}
        $row.PSObject.Properties.Remove('_Key')
        [void]$final.Add($row)
    }
    $result.Measurements=@($final.ToArray());$result.Issues=@($issues|Select-Object -Unique)
    if($final.Count -gt 0){
        if($result.Issues.Count){$result.Status='NeedsReview';$result.ReasonCode='MeasurementReviewNeeded';$result.Reason='Printed values were extracted, but incomplete, conflicting or unsupported evidence needs review in the original PDF.'}
        else{$result.Status='Extracted';$result.ReasonCode='SupportedPrintedValues';$result.Reason='Supported current water, noise and slice-thickness values with their explicitly printed unit-matched limits were extracted. These are printed observations, not a clinical approval.'}
    }
    return $result
}
Export-ModuleMember -Function Get-QaMeasurementParserVersion,Get-QaMeasurementSupportRevision,ConvertFrom-QaMeasurementText
