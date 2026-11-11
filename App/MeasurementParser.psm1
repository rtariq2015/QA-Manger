# Conservative extraction of explicitly printed single-metric IEC tables.
# Measurements remain documentary evidence, never a clinical approval.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ContentClassifier.psm1') -DisableNameChecking -WarningAction SilentlyContinue

function Get-QaMeasurementParserVersion { return 1 }

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
    return ''
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
    $result=[pscustomobject]@{MeasurementVersion=1;Status='NeedsReview';ReasonCode='NoSupportedTables';Reason='No supported single-metric water or noise table was extracted. Review the original PDF.';CompleteRead=$false;Measurements=@();Issues=@();ClinicalResult='Not inferred'}
    if($NeedsOCR){$result.ReasonCode='NoReadableText';$result.Reason='No readable text is available for measurement extraction.';return $result}
    if($Text.Length -gt 2000000){$result.ReasonCode='InputLimit';$result.Reason='The text exceeds the bounded measurement-reading limit.';return $result}
    $classification=ConvertFrom-QaDocumentContent -Text $Text -Truncated $Truncated -NeedsOCR $NeedsOCR -Pages $Pages -ReadPages $ReadPages
    $result.CompleteRead=[bool]$classification.CompleteRead
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
        if($section -eq 'Noise' -and $line -eq 'Result'){$table='';$noiseHeading=$true;continue}
        if($line -match '^Results for System (?<system>[AB])$'){
            $system=$Matches['system'].ToUpperInvariant();$table=''
            if($section -eq 'Noise' -and $noiseHeading){$table='ImageNoise'}
            $noiseHeading=$false;continue
        }
        if(-not $table){continue}
        if($line -notmatch '^Slice (?<slice>[0-9]{1,3})$'){$table='';continue}
        $slice=[int]$Matches['slice']
        if($slice -lt 1 -or $i+3 -ge $lines.Count){[void]$issues.Add('IncompleteMeasurementRow');$table='';continue}
        $tolerance=$lines[$i+1];$valueEntry=$lines[$i+2];$rangeEntry=$lines[$i+3]
        if($tolerance.Page -ne $entry.Page -or $valueEntry.Page -ne $entry.Page -or $rangeEntry.Page -ne $entry.Page -or $tolerance.Text -cne 'Tolerance'){
            [void]$issues.Add('UnsupportedMeasurementRow');$table='';continue
        }
        $valueMatch=[regex]::Match([string]$valueEntry.Text,$valuePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $rangeMatch=[regex]::Match([string]$rangeEntry.Text,$rangePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if(-not $valueMatch.Success -or -not $rangeMatch.Success){[void]$issues.Add('UnsupportedMeasurementRow');$table='';continue}
        if($i+4 -lt $lines.Count -and ([regex]::IsMatch([string]$lines[$i+4].Text,$valuePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase) -or [regex]::IsMatch([string]$lines[$i+4].Text,$rangePattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase))){
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
            [void]$rows.Add([pscustomobject]@{Code=$table;Label=$(if($table -eq 'WaterCTNumber'){'Water CT value'}else{'Image noise'});Value=$value;Unit='HU';Page=[int]$valueEntry.Page;LowerLimit=$lower;UpperLimit=$upper;Mode=$mode;SourceSystem=$system;Slice=$slice.ToString([Globalization.CultureInfo]::InvariantCulture);Status=$status;ContextSection=$section;Source='PrintedSingleMetricTable';_Key=$key})
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
        else{$result.Status='Extracted';$result.ReasonCode='SupportedPrintedValues';$result.Reason='Current water and noise values with their explicitly printed HU limits were extracted. These are printed observations, not a clinical approval.'}
    }
    return $result
}
Export-ModuleMember -Function Get-QaMeasurementParserVersion,ConvertFrom-QaMeasurementText
