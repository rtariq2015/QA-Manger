# Deterministic, offline document-profile hints. These are not clinical QA results.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-QaContentClassifierVersion { return 1 }
# Additive compatible templates have a separate rollout revision so recognized
# historical evidence remains reusable while old unsupported reads can retry once.
function Get-QaContentSupportRevision { return 4 }
function Get-QaContentSectionDefinitions {
    return @(
        [pscustomobject]@{Code='HomogeneityWater';Name='Homogeneity / Water'},
        [pscustomobject]@{Code='Noise';Name='Noise'},
        [pscustomobject]@{Code='Lightmarker';Name='Lightmarker'},
        [pscustomobject]@{Code='ExternalLightmarker';Name='External lightmarker'},
        [pscustomobject]@{Code='SagittalCoronalLightmarker';Name='Sagittal / coronal lightmarker'},
        [pscustomobject]@{Code='TopogramPosition';Name='Topogram position'},
        [pscustomobject]@{Code='Slice';Name='Slice'},
        [pscustomobject]@{Code='MTF';Name='MTF'},
        [pscustomobject]@{Code='Contrast';Name='Contrast'},
        [pscustomobject]@{Code='LowContrast';Name='Low contrast'},
        [pscustomobject]@{Code='TablePosition';Name='Table position'}
    )
}
function Get-QaContentSectionCode([string]$Label) {
    $normalized=([regex]::Replace($Label,'\s+',' ')).Trim().TrimEnd('.')
    switch -Regex ($normalized) {
        '^Homogeneity\s*/\s*Water$' {return 'HomogeneityWater'}
        '^Noise$' {return 'Noise'}
        '^Lightmarker$' {return 'Lightmarker'}
        '^External\s+Lightm\.?$' {return 'ExternalLightmarker'}
        '^Sag\.?\s*/\s*Cor\.?\s+Lightm\.?$' {return 'SagittalCoronalLightmarker'}
        '^Topogram\s+Pos\.?$' {return 'TopogramPosition'}
        '^Slice$' {return 'Slice'}
        '^MTF$' {return 'MTF'}
        '^Contrast$' {return 'Contrast'}
        '^Low\s+Contrast$' {return 'LowContrast'}
        '^Table\s+Position$' {return 'TablePosition'}
        default {return ''}
    }
}
function ConvertFrom-QaDocumentContent {
    [CmdletBinding()]param(
        [AllowEmptyString()][string]$Text='',
        [bool]$Truncated=$false,
        [bool]$NeedsOCR=$false,
        [int]$Pages=0,
        [int]$ReadPages=0
    )
    $template='siemens-iec-constancy-v1';$sections=New-Object 'Collections.Generic.List[object]';$issues=New-Object 'Collections.Generic.List[string]'
    $result=[pscustomobject]@{ClassifierVersion=1;SupportRevision=(Get-QaContentSupportRevision);TemplateVersion=$template;ProfileId='';ProfileName='';Model='';IsReference=$false;HasReferenceEvidence=$false;DocumentKind='Current';Status='NeedsReview';Category='';SuggestedCategory='';ReportDate='';ReportTime='';DateStatus='Missing';CompleteRead=$false;ReasonCode='UnknownTemplate';Reason='The document does not match a supported complete report profile.';Sections=@();DateEvidence=[pscustomobject]@{MatchedPages=0;ExpectedPages=$Pages};Issues=@();ClinicalResult='Not inferred'}
    # Text must come from the verified full-document reader. Page counts alone
    # never determine whether a document is Daily or Monthly.
    $normalized=$Text.Replace([string][char]0x00a0,' ').Replace([string][char]0x202f,' ').Replace("`r`n","`n").Replace("`r","`n")
    $pageMatches=@([regex]::Matches($normalized,'(?ms)^--- Page (?<page>\d+) ---\r?\n(?<body>.*?)(?=^--- Page \d+ ---\r?\n|\z)'))
    $seenPages=@{};$pageBodies=New-Object 'Collections.Generic.List[object]'
    foreach($match in $pageMatches){$number=[int]$match.Groups['page'].Value;if($seenPages.ContainsKey($number)){[void]$issues.Add('DuplicatePageMarker')}else{$seenPages[$number]=$true};[void]$pageBodies.Add([pscustomobject]@{Number=$number;Body=$match.Groups['body'].Value})}
    $complete=($Pages -gt 0 -and $ReadPages -eq $Pages -and $pageBodies.Count -eq $Pages -and -not $Truncated -and -not $NeedsOCR)
    for($p=1;$p -le [math]::Max(0,$Pages);$p++){if(-not $seenPages.ContainsKey($p)){$complete=$false}}
    if($seenPages.Count -ne $pageBodies.Count){$complete=$false}
    $result.CompleteRead=$complete
    if(-not $complete){[void]$issues.Add('IncompleteRead');$result.DateStatus='Incomplete'}
    if($NeedsOCR){[void]$issues.Add('NoReadableText')}

    $footerValues=@{};$matchedPages=0;$invalidFooter=$false;$footerConflict=$false
    foreach($page in $pageBodies){
        # The report footer has a timestamp and its own Page:n/total marker.
        # Handed-over dates and reference-measurement dates are never candidates.
        $footers=@([regex]::Matches($page.Body,'(?im)^[ \t]*(?<date>\d{4}-\d{2}-\d{2})[ \t]+(?<time>\d{2}:\d{2}:\d{2})[ \t\r\n|]*Page[ \t]*:[ \t]*(?<number>\d+)[ \t]*/[ \t]*(?<total>\d+)[ \t]*$'))
        if($footers.Count -ne 1){if($footers.Count -gt 1){$footerConflict=$true};continue}
        $footer=$footers[0];$stamp=[datetime]::MinValue
        if(-not [datetime]::TryParseExact(($footer.Groups['date'].Value+' '+$footer.Groups['time'].Value),'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$stamp)){$invalidFooter=$true;continue}
        if([int]$footer.Groups['number'].Value -ne $page.Number -or [int]$footer.Groups['total'].Value -ne $Pages){$footerConflict=$true;continue}
        $matchedPages++;$footerValues[$stamp.ToString('yyyy-MM-dd HH:mm:ss')]= $true
    }
    $result.DateEvidence=[pscustomobject]@{MatchedPages=$matchedPages;ExpectedPages=$Pages}
    if($invalidFooter){$result.DateStatus='Invalid';[void]$issues.Add('InvalidFooterDate')}
    elseif($footerConflict -or $footerValues.Count -gt 1){$result.DateStatus='Conflict';[void]$issues.Add('ConflictingFooterDates')}
    elseif($complete -and $matchedPages -eq $Pages -and $footerValues.Count -eq 1){$result.DateStatus='Consensus';$only=@($footerValues.Keys)[0];$result.ReportDate=$only.Substring(0,10);$result.ReportTime=$only.Substring(11,8)}
    elseif($complete){$result.DateStatus='Missing';[void]$issues.Add('MissingFooterDate')}

    # A recognized model name is only one template prerequisite. Exact numbered
    # body sections, full text and matching page footers are still required.
    $models=@{}
    foreach($modelMatch in @([regex]::Matches($normalized,'(?i)\bSOMATOM\s+Definition\s+(?<model>Edge|Flash)\b(?![A-Za-z0-9_+\-])'))){
        $model=if($modelMatch.Groups['model'].Value -ieq 'Edge'){'Edge'}else{'Flash'};$models[$model]=$true
    }
    if($normalized -match '(?i)\bSOMATOM\s+Drive\b(?![A-Za-z0-9_+\-])'){$models['Drive']=$true}
    if($models.Count -gt 1){[void]$issues.Add('ConflictingModelHeaders')}
    $supportedTemplate=($models.Count -eq 1 -and $normalized -match '(?i)\bQuality\s+(?:IEC\s+Constancy|Daily)\b')
    # A literal manufacturer Reference heading identifies historical material,
    # never current QA evidence. Ignore a clearly labelled table of contents;
    # every actual reference heading must use one exact known test label.
    $referenceHeadings=New-Object 'Collections.Generic.List[object]'
    $componentHeadings=New-Object 'Collections.Generic.List[object]'
    $referenceUnknown=$false;$referenceMixed=$false;$componentNumbered=$false;$componentDaily=$false;$componentUnknown=$false
    foreach($page in $pageBodies){
        if($page.Body -match '(?im)^[ \t]*(?:Table[ \t]+of[ \t]+contents|Contents)[ \t]*$'){continue}
        if($page.Body -match '(?im)^[ \t]*(?:\d{1,2}\.[ \t]*)?Quality[ \t]+Daily(?:[ \t]|$)'){$referenceMixed=$true;$componentDaily=$true}
        foreach($heading in @([regex]::Matches($page.Body,'(?im)^[ \t]*(?:(?<number>\d{1,2})\.[ \t]*)?Quality[ \t]+IEC[ \t]+Constancy[ \t]*(?:\r?\n[ \t]*)?(?<label>[^\r\n]+?)[ \t]*$'))){
            $label=([regex]::Replace($heading.Groups['label'].Value,'\s+',' ')).Trim()
            if($heading.Groups['number'].Success){$componentNumbered=$true}
            if($label -match '(?i)^Reference(?:[ \t]+(?<test>.+))?$'){
                $code=Get-QaContentSectionCode ([string]$Matches['test'])
                if(-not $code){$referenceUnknown=$true}
                [void]$referenceHeadings.Add([pscustomobject]@{Code=$code;Number=$(if($heading.Groups['number'].Success){[int]$heading.Groups['number'].Value}else{0});Page=$page.Number})
            }else{
                $code=Get-QaContentSectionCode $label
                if($heading.Groups['number'].Success -or $code){$referenceMixed=$true}
                if($code -and -not $heading.Groups['number'].Success){[void]$componentHeadings.Add([pscustomobject]@{Code=$code;Page=$page.Number;HeadingEnd=($heading.Index+$heading.Length)})}
                elseif($page.Number -ge 2 -and -not $code){$componentUnknown=$true}
            }
        }
    }
    # Suspected reference material must also be excluded from current receipts
    # and measurements even when an unknown label prevents profile recognition.
    $result.HasReferenceEvidence=($referenceHeadings.Count -gt 0)
    $referenceValid=($referenceHeadings.Count -gt 0 -and -not $referenceUnknown -and -not $referenceMixed)
    if($referenceValid){
        $numbered=@($referenceHeadings|Where-Object Number -gt 0)
        if($numbered.Count){
            $referenceCodes=@{};$expectedReferenceNumber=1
            if($numbered.Count -ne $referenceHeadings.Count){$referenceValid=$false}
            foreach($heading in $referenceHeadings){
                if($heading.Page -lt 3 -or $heading.Number -ne $expectedReferenceNumber -or $referenceCodes.ContainsKey($heading.Code)){$referenceValid=$false}
                $referenceCodes[$heading.Code]=$true;$expectedReferenceNumber++
            }
        }elseif($referenceHeadings.Count -ne 1 -or $referenceHeadings[0].Page -lt 2){$referenceValid=$false}
    }
    if($referenceValid -and $supportedTemplate -and $complete -and $result.DateStatus -ceq 'Consensus'){
        $model=@($models.Keys)[0];$result.Model=if($model -ceq 'Drive'){'SOMATOM Drive'}else{'SOMATOM Definition '+$model}
        $result.ProfileId='siemens-iec-reference-v1';$result.ProfileName='IEC historical reference measurements';$result.TemplateVersion='siemens-iec-reference-v1'
        $result.IsReference=$true;$result.DocumentKind='Reference';$result.Status='Recognized';$result.Category='Other';$result.SuggestedCategory='Other'
        $result.Sections=@();$result.ReasonCode='ReferenceDocument';$result.Reason='A complete supported historical reference document was identified. It is filed separately and cannot count as current QA or supply current measurement trends.'
        $result.Issues=@($issues|Select-Object -Unique)
        return $result
    }
    $bodyHeadings=New-Object 'Collections.Generic.List[object]'
    foreach($page in $pageBodies){
        if($page.Number -lt 3){continue}
        $headings=@([regex]::Matches($page.Body,'(?im)^[ \t]*(?<number>\d{1,2})\.[ \t\r\n]*Quality\s+(?<kind>IEC\s+Constancy|Daily)[ \t]*(?:\r?\n[ \t]*)?(?<label>[^\r\n]+?)[ \t]*$'))
        foreach($heading in $headings){
            $kind=if($heading.Groups['kind'].Value -match '(?i)^Daily$'){'Daily'}else{'IEC'}
            $label=([regex]::Replace($heading.Groups['label'].Value,'\s+',' ')).Trim()
            # Daily's literal manufacturer heading uses Homogeneity, while IEC
            # uses Homogeneity / Water. Do not generalize this alias to IEC.
            $code=if($kind -eq 'Daily'){switch -Regex ($label){'^Noise$'{'Noise'}'^Homogeneity$'{'HomogeneityWater'}default{''}}}else{Get-QaContentSectionCode $label}
            [void]$bodyHeadings.Add([pscustomobject]@{Number=[int]$heading.Groups['number'].Value;Page=$page.Number;Code=$code;Kind=$kind;Start=$heading.Index;HeadingEnd=($heading.Index+$heading.Length)})
        }
    }
    $seenSections=@{};$hasUnknown=$false;$badSequence=$false;$expectedNumber=1;$bodyKinds=@{}
    for($i=0;$i -lt $bodyHeadings.Count;$i++){
        $heading=$bodyHeadings[$i];$code=[string]$heading.Code;$bodyKinds[[string]$heading.Kind]=$true
        if(-not $code){$hasUnknown=$true;[void]$issues.Add('UnknownBodySection')}
        if($heading.Number -ne $expectedNumber){$badSequence=$true};$expectedNumber++
        if($seenSections.ContainsKey($code)){$badSequence=$true}else{$seenSections[$code]=$true}
        $endPage=if($i+1 -lt $bodyHeadings.Count){$bodyHeadings[$i+1].Page}else{$Pages}
        $outcomes=New-Object 'Collections.Generic.List[string]';$hasTestMarker=$false;$hasResultMarker=$false;$hasUnitMarker=$false
        foreach($page in $pageBodies){
            if($page.Number -lt $heading.Page -or $page.Number -gt $endPage){continue};$body=$page.Body
            if($i+1 -lt $bodyHeadings.Count -and $page.Number -eq $bodyHeadings[$i+1].Page){$body=$body.Substring(0,$bodyHeadings[$i+1].Start)}
            if($page.Number -eq $heading.Page){$body=$body.Substring([math]::Min($heading.HeadingEnd,$body.Length))}
            if($body -match '(?im)^[ \t]*Test[ \t]*:'){$hasTestMarker=$true}
            if($body -match '(?im)^[ \t]*(?:Result|Results)[ \t]*(?::|for[ \t]+System|$)'){$hasResultMarker=$true}
            if($body -match '(?i)(?<![A-Za-z])(?:HU|mm|cm|lp/cm)(?![A-Za-z])'){$hasUnitMarker=$true}
            # Retain only literal end-of-line status tokens from body sections.
            # Table labels and numeric measurements are not copied or interpreted.
            foreach($outcome in @([regex]::Matches($body,'(?im)(?<!\S)(?<value>NOT[ \t]+OK|OK|FAIL(?:ED)?|PASS(?:ED)?|ERROR|WARNING|NOT[ \t]+EVALUATED)[ \t]*$'))){$raw=([regex]::Replace($outcome.Groups['value'].Value,'[ \t]+',' ')).Trim().ToUpperInvariant();if(-not $outcomes.Contains($raw)){[void]$outcomes.Add($raw)}}
        }
        $outcomeStatus=if($outcomes.Count -gt 1){'Conflict'}elseif($outcomes.Count -eq 1){'Printed'}else{'Missing'}
        if($outcomeStatus -eq 'Conflict'){[void]$issues.Add('MixedPrintedOutcomes')}
        [void]$sections.Add([pscustomobject]@{Code=$code;Number=$heading.Number;Page=$heading.Page;PrintedOutcomes=@($outcomes.ToArray());OutcomeStatus=$outcomeStatus;BodyEvidence=($outcomes.Count -gt 0 -or ($hasTestMarker -and $hasResultMarker -and $hasUnitMarker));EvidenceCode=$(if($code){'NumberedBodySection.'+$code}else{'UnknownNumberedBodySection'})})
    }
    # A supported standalone IEC component has its actual unnumbered title
    # on the first body page, with Test, physical-unit and printed-outcome
    # evidence. It cannot borrow a title from a TOC or any mixed report family.
    $singleComponent=$false
    if($bodyHeadings.Count -eq 0 -and $componentHeadings.Count -eq 1 -and $componentHeadings[0].Page -eq 2 -and $referenceHeadings.Count -eq 0 -and -not $componentNumbered -and -not $componentDaily -and -not $componentUnknown){
        $component=$componentHeadings[0];$componentBody=New-Object Text.StringBuilder
        foreach($page in $pageBodies){if($page.Number -lt $component.Page){continue};$body=$page.Body;if($page.Number -eq $component.Page){$body=$body.Substring([math]::Min($component.HeadingEnd,$body.Length))};[void]$componentBody.AppendLine($body)}
        $body=$componentBody.ToString();$outcomes=New-Object 'Collections.Generic.List[string]'
        foreach($outcome in @([regex]::Matches($body,'(?im)(?<!\S)(?<value>NOT[ \t]+OK|OK|FAIL(?:ED)?|PASS(?:ED)?|ERROR|WARNING|NOT[ \t]+EVALUATED)[ \t]*$'))){$raw=([regex]::Replace($outcome.Groups['value'].Value,'[ \t]+',' ')).Trim().ToUpperInvariant();if(-not $outcomes.Contains($raw)){[void]$outcomes.Add($raw)}}
        $singleComponent=($body -match '(?im)^[ \t]*Test[ \t]*:' -and $body -match '(?i)(?<![A-Za-z])(?:HU|mm|cm|lp/cm)(?![A-Za-z])' -and $outcomes.Count -gt 0)
        if($singleComponent){
            $outcomeStatus=if($outcomes.Count -gt 1){'Conflict'}else{'Printed'}
            if($outcomeStatus -eq 'Conflict'){[void]$issues.Add('MixedPrintedOutcomes')}
            [void]$sections.Add([pscustomobject]@{Code=$component.Code;Number=1;Page=$component.Page;PrintedOutcomes=@($outcomes.ToArray());OutcomeStatus=$outcomeStatus;BodyEvidence=$true;EvidenceCode=('ComponentTitle.'+$component.Code)})
        }
    }
    $result.Sections=@($sections.ToArray())
    $basic=@('HomogeneityWater','Noise');$extended=@('Lightmarker','ExternalLightmarker','SagittalCoronalLightmarker','TopogramPosition','Slice','HomogeneityWater','Noise','MTF','Contrast','TablePosition')
    $profile='';$suggestion=''
    if($bodyKinds.Count -gt 1){$badSequence=$true;[void]$issues.Add('MixedReportKinds')}
    if($supportedTemplate -and $referenceHeadings.Count -eq 0 -and -not $hasUnknown -and -not $badSequence){
        $codes=@($sections|ForEach-Object Code)
        $evidenced=($codes.Count -gt 0 -and @($sections|Where-Object{-not $_.BodyEvidence}).Count -eq 0)
        if($bodyKinds.ContainsKey('Daily')){
            if(($codes -join '|') -ceq 'Noise|HomogeneityWater' -and $evidenced){$profile='siemens-quality-daily-v1';$suggestion='Daily'}
        }else{
            if($codes.Count -eq $basic.Count -and ($codes -join '|') -ceq ($basic -join '|')){$profile='siemens-iec-basic-v1';$suggestion='Daily'}
            elseif($codes.Count -eq $extended.Count -and ($codes -join '|') -ceq ($extended -join '|')){$profile='siemens-iec-extended-v1';$suggestion='Monthly'}
            elseif($evidenced -and ($singleComponent -or @($codes|Where-Object{$_ -cnotin @('HomogeneityWater','Noise')}).Count -gt 0)){$profile='siemens-iec-additional-v1';$suggestion='Monthly'}
        }
    }
    $result.ProfileId=$profile;$result.SuggestedCategory=$suggestion
    if($supportedTemplate){$model=@($models.Keys)[0];$result.Model=if($model -ceq 'Drive'){'SOMATOM Drive'}else{'SOMATOM Definition '+$model}}
    switch($profile){'siemens-iec-basic-v1'{$result.ProfileName='Siemens IEC basic checks'}'siemens-iec-extended-v1'{$result.ProfileName='Siemens IEC extended checks'}'siemens-iec-additional-v1'{$result.ProfileName='IEC individual / combined tests'}'siemens-quality-daily-v1'{$result.ProfileName='Siemens daily checks';$result.TemplateVersion='siemens-quality-daily-v1'}}
    if($badSequence){[void]$issues.Add('ConflictingSectionSequence')}
    # An explicit document title is distinct from a department's optional profile
    # mapping. Ordinary mentions in instructions or a table of contents do not count.
    $titleCategories=@{}
    if($pageBodies.Count){foreach($title in @([regex]::Matches($pageBodies[0].Body,'(?im)^[ \t]*(?<kind>Daily|Monthly)[ \t]+(?:QA|Quality[ \t]+(?:Assurance|Control)|IEC[ \t]+Constancy)(?:[ \t]+(?:Report|Protocol|Tests?|Check))?[ \t]*\r?$'))){$kind=$title.Groups['kind'].Value;if($kind -ieq 'Daily'){$titleCategories['Daily']=$true}else{$titleCategories['Monthly']=$true}}}
    if($profile -ceq 'siemens-quality-daily-v1'){$titleCategories['Daily']=$true}
    if($titleCategories.Count -gt 1){[void]$issues.Add('ConflictingExplicitTitles')}
    if($profile -and $complete -and $result.DateStatus -eq 'Consensus' -and $titleCategories.Count -le 1){
        $result.Status='Recognized';$result.ReasonCode='SupportedProfile';$result.Reason='A complete supported document profile and matching report-footer dates were read. File organization follows the automatic filing policy or a saved scanner override; clinical review remains separate.'
        if($profile -ceq 'siemens-quality-daily-v1'){$result.Reason='A complete supported manufacturer Daily document and matching report-footer dates were read. File classification does not imply clinical QA approval.'}
        if($titleCategories.Count -eq 1){$result.Category=@($titleCategories.Keys)[0]}
    }elseif(-not $complete){$result.ReasonCode='IncompleteRead';$result.Reason='The complete verified report text was not available; no document type or date was accepted.'}
    elseif($result.DateStatus -ne 'Consensus'){$result.ReasonCode='UncertainReportDate';$result.Reason='The printed report-footer date is missing, invalid or inconsistent; review the original PDF.'}
    elseif($titleCategories.Count -gt 1){$result.ReasonCode='ConflictingExplicitTitles';$result.Reason='Conflicting Daily and Monthly document titles need review.'}
    elseif($hasUnknown -or $badSequence){$result.ReasonCode='UnrecognizedSections';$result.Reason='The report has unknown, duplicated or conflicting numbered body sections.'}
    $result.Issues=@($issues|Select-Object -Unique)
    return $result
}
Export-ModuleMember -Function ConvertFrom-QaDocumentContent,Get-QaContentClassifierVersion,Get-QaContentSupportRevision,Get-QaContentSectionDefinitions
