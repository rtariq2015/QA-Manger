[CmdletBinding()]param([string]$OutputPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProductRoot 'App/ContentClassifier.psm1') -Force -DisableNameChecking
$script:Results=New-Object 'Collections.Generic.List[object]';$script:Assertions=0
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS '+$Name)}catch{[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=($_.Exception.Message+' / '+$_.ScriptStackTrace)});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
$basic=@('Homogeneity / Water','Noise')
$extended=@('Lightmarker','External Lightm.','Sag./Cor. Lightm.','Topogram Pos.','Slice','Homogeneity / Water','Noise','MTF','Contrast','Table Position')
function New-ContentText([string[]]$Labels,[int]$Pages=7,[string]$Title='Quality IEC Constancy',[int]$MissingFooter=0,[int]$ConflictFooter=0,[string]$Stamp='2026-11-10 08:00:00',[switch]$TocOnly,[switch]$MixedOutcomes,[string]$Model='SOMATOM Definition Edge'){
    $builder=New-Object Text.StringBuilder
    for($page=1;$page -le $Pages;$page++){
        [void]$builder.Append("--- Page $page ---`n")
        if($page -eq 1){[void]$builder.Append("$Title`n$Model`nHanded over: 2018-02-03`nLast IEC Constancy Reference measurement: 2019-04-05`n")}
        if($page -eq 2){[void]$builder.Append("Table of contents`n");for($i=0;$i -lt $Labels.Count;$i++){[void]$builder.Append(($i+1).ToString()+'. Quality IEC Constancy '+$Labels[$i]+"`n")}}
        if(-not $TocOnly){for($i=0;$i -lt $Labels.Count;$i++){$bodyPage=3+[int][math]::Floor($i*[math]::Max(1,$Pages-2)/$Labels.Count);if($bodyPage -eq $page){[void]$builder.Append(($i+1).ToString()+'. Quality IEC Constancy '+$Labels[$i]+"`nOK`n");if($MixedOutcomes -and $i -eq 0){[void]$builder.Append("NOT OK`n")}}}}
        if($page -ne $MissingFooter){$footerStamp=if($page -eq $ConflictFooter){'2026-11-09 07:30:00'}else{$Stamp};[void]$builder.Append($footerStamp+' Page: '+$page+'/'+$Pages+"`n")}
    };return $builder.ToString()
}
function Read-Content([string]$Text,[int]$Pages=7){return ConvertFrom-QaDocumentContent -Text $Text -Pages $Pages -ReadPages $Pages}
Scenario 'Complete basic Siemens body sections produce a suggested profile without assigning department policy' {
    $text=New-ContentText $basic -Pages 9;$row=Read-Content $text 9
    Check ($row.Status -eq 'Recognized' -and $row.ProfileId -eq 'siemens-iec-basic-v1') 'The exact basic body-section profile is recognized'
    Check ($row.Category -ceq '' -and $row.SuggestedCategory -eq 'Daily') 'The report itself did not claim Daily; a department mapping is still needed'
    Check ($row.Sections.Count -eq 2 -and $row.Sections[0].Code -eq 'HomogeneityWater' -and $row.Sections[1].Code -eq 'Noise') 'Table-of-contents rows are excluded from actual body evidence'
    Check ($row.DateStatus -eq 'Consensus' -and $row.ReportDate -eq '2026-11-10' -and $row.ReportTime -eq '08:00:00') 'Matching report-footer dates are used instead of cover/reference dates'
    Check ($row.DateEvidence.MatchedPages -eq 9 -and $row.CompleteRead) 'All declared pages contribute matching footer evidence'
    Check ($row.Model -eq 'SOMATOM Definition Edge' -and $row.ClinicalResult -eq 'Not inferred') 'Only the generic model is retained and no clinical result is inferred'
}
Scenario 'The complete extended body profile is recognized independent of usual PDF size or page count' {
    $row=Read-Content (New-ContentText $extended -Pages 6) 6
    Check ($row.Status -eq 'Recognized' -and $row.ProfileId -eq 'siemens-iec-extended-v1' -and $row.SuggestedCategory -eq 'Monthly') 'All ten extended sections produce the supported profile even on six pages'
    Check ($row.Category -ceq '' -and $row.Sections.Count -eq 10) 'The complete extended profile does not declare a Monthly procedure without policy'
    Check (@($row.Sections|Where-Object OutcomeStatus -eq 'Printed').Count -eq 10 -and @($row.Sections|Where-Object{$_.PrintedOutcomes[0] -cne 'OK'}).Count -eq 0) 'Printed OK observations are retained as observations, not converted into overall PASS'
}
Scenario 'Compatible Flash IEC body profiles retain the same layout identity without assigning department policy' {
    foreach($case in @(@{Labels=$basic;Pages=9;Profile='siemens-iec-basic-v1';Suggestion='Daily';Sections=2},@{Labels=$extended;Pages=6;Profile='siemens-iec-extended-v1';Suggestion='Monthly';Sections=10})){
        $text=New-ContentText -Labels $case.Labels -Pages $case.Pages -Model 'SOMATOM Definition Flash';$row=Read-Content $text $case.Pages
        Check ($row.Status -ceq 'Recognized' -and $row.ProfileId -ceq $case.Profile) 'The compatible Flash model uses the exact same supported body profile'
        Check ($row.Model -ceq 'SOMATOM Definition Flash' -and $row.Sections.Count -eq $case.Sections) 'The actual printed supported model and complete section count are retained'
        Check ($row.Category -ceq '' -and $row.SuggestedCategory -ceq $case.Suggestion -and $row.ClinicalResult -ceq 'Not inferred') 'A Flash header never supplies a department rule or clinical approval'
        Check ($row.CompleteRead -and $row.DateStatus -ceq 'Consensus' -and $row.DateEvidence.MatchedPages -eq $case.Pages) 'All Flash pages still require the matching printed report footer'
    }
}
Scenario 'A Flash header does not bypass incomplete, non-IEC, table-of-contents or conflicting-date safeguards' {
    $text=New-ContentText -Labels $basic -Model 'SOMATOM Definition Flash'
    foreach($row in @((Read-Content (New-ContentText -Labels $basic -Model 'SOMATOM Definition Flash' -TocOnly)),(Read-Content ($text.Replace('Quality IEC Constancy','Other synthetic procedure'))),(ConvertFrom-QaDocumentContent -Text $text -Pages 7 -ReadPages 7 -Truncated $true),(ConvertFrom-QaDocumentContent -Text $text -Pages 7 -ReadPages 6))){
        Check ($row.Status -ceq 'NeedsReview' -and $row.Category -ceq '' -and $row.ClinicalResult -ceq 'Not inferred') 'An unsupported or incomplete Flash document remains unresolved'
    }
    $conflict=Read-Content (New-ContentText -Labels $basic -Model 'SOMATOM Definition Flash' -ConflictFooter 5)
    Check ($conflict.Status -ceq 'NeedsReview' -and $conflict.DateStatus -ceq 'Conflict' -and $conflict.ReportDate -ceq '') 'A supported Flash name cannot resolve contradictory report dates'
    foreach($model in @('SOMATOM Definition AS','SOMATOM Definition Flash2','SOMATOM Definition Flash-Pro','SOMATOM Definition Flashes')){
        $unknown=Read-Content (New-ContentText -Labels $basic -Model $model)
        Check ($unknown.Status -ceq 'NeedsReview' -and $unknown.ProfileId -ceq '' -and $unknown.Model -ceq '') 'Other or similarly spelled models are not guessed from the supported name'
    }
}
Scenario 'Conflicting supported model names do not select an arbitrary model or profile' {
    $row=Read-Content (New-ContentText -Labels $basic -Model "SOMATOM Definition Edge`nSOMATOM Definition Flash")
    Check ($row.Status -ceq 'NeedsReview' -and $row.ProfileId -ceq '' -and $row.Model -ceq '') 'Mixed model evidence withholds the model-specific template'
    Check ($row.Issues -contains 'ConflictingModelHeaders' -and $row.ClinicalResult -ceq 'Not inferred') 'A fixed conflict code explains the withheld evidence without copying header text'
}
Scenario 'Explicit cover titles are distinguished from profile suggestions and ordinary text mentions' {
    $daily=Read-Content (New-ContentText $basic -Title 'Daily Quality Assurance Report')
    $monthly=Read-Content (New-ContentText $extended -Title 'Monthly QA Report')
    Check ($daily.Category -eq 'Daily' -and $monthly.Category -eq 'Monthly') 'Literal supported document titles can identify their stated type'
    $windows=Read-Content ((New-ContentText $basic -Title 'Daily QA').Replace("`n","`r`n"))
    Check ($windows.Status -eq 'Recognized' -and $windows.Category -eq 'Daily') 'Literal titles support CRLF lines emitted at PDF page boundaries'
    $mention=Read-Content ((New-ContentText $basic).Replace('Handed over:','This report may be reviewed daily or monthly. Handed over:'))
    Check ($mention.Category -ceq '') 'Unstructured mentions of Daily or Monthly do not classify a report'
    $both=Read-Content (New-ContentText $basic -Title "Daily QA Report`nMonthly QA Report")
    Check ($both.Status -eq 'NeedsReview' -and $both.Category -ceq '' -and $both.Issues -contains 'ConflictingExplicitTitles') 'Contradictory document titles remain unresolved'
}
Scenario 'A table of contents cannot stand in for actual completed body sections' {
    $row=Read-Content (New-ContentText $extended -TocOnly)
    Check ($row.Status -eq 'NeedsReview' -and $row.ProfileId -ceq '' -and $row.Sections.Count -eq 0) 'TOC-only test names do not become a recognized report'
    $noise=Read-Content (New-ContentText @('MTF') -TocOnly)
    Check ($noise.Status -eq 'NeedsReview' -and $noise.ProfileId -ceq '') 'One familiar test name in a table of contents does not imply a completed Monthly document'
}
Scenario 'Unknown, duplicated, missing or reordered sections require manual review' {
    foreach($labels in @(@('Homogeneity / Water','Noise','Unsupported phantom test'),@('Homogeneity / Water','Noise','Noise'),@('Noise','Homogeneity / Water'),@('Homogeneity / Water'))){
        $row=Read-Content (New-ContentText $labels)
        Check ($row.Status -eq 'NeedsReview' -and $row.ProfileId -ceq '' -and $row.Category -ceq '') 'An unsupported section set does not become a confident profile'
    }
    $sequence=Read-Content ((New-ContentText $basic).Replace('2. Quality IEC Constancy Noise','3. Quality IEC Constancy Noise'))
    Check ($sequence.Status -eq 'NeedsReview' -and $sequence.Issues -contains 'ConflictingSectionSequence') 'Incorrect body numbering is not silently accepted'
}
Scenario 'Incomplete text, OCR needs and missing page markers never become accepted content' {
    $text=New-ContentText $basic
    foreach($row in @((ConvertFrom-QaDocumentContent $text -Pages 7 -ReadPages 6),(ConvertFrom-QaDocumentContent $text -Pages 7 -ReadPages 7 -Truncated $true),(ConvertFrom-QaDocumentContent $text -Pages 7 -ReadPages 7 -NeedsOCR $true),(Read-Content ($text.Replace('--- Page 4 ---','--- Missing 4 ---'))))){
        Check ($row.Status -eq 'NeedsReview' -and -not $row.CompleteRead -and $row.Category -ceq '' -and $row.ReportDate -ceq '') 'Partial or unreadable reports retain no accepted content type/date'
    }
    $empty=ConvertFrom-QaDocumentContent -Text '' -Pages 0 -ReadPages 0 -NeedsOCR $true
    Check ($empty.Status -eq 'NeedsReview' -and $empty.DateStatus -eq 'Incomplete') 'An image-only or empty report explains its incomplete evidence'
}
Scenario 'Missing, conflicting, invalid and misnumbered footer evidence cannot supply a report date' {
    $missing=Read-Content (New-ContentText $basic -MissingFooter 4)
    Check ($missing.Status -eq 'NeedsReview' -and $missing.DateStatus -eq 'Missing' -and $missing.ReportDate -ceq '') 'One missing page footer prevents a date consensus'
    $conflict=Read-Content (New-ContentText $basic -ConflictFooter 5)
    Check ($conflict.Status -eq 'NeedsReview' -and $conflict.DateStatus -eq 'Conflict' -and $conflict.ReportDate -ceq '') 'Differing printed timestamps remain unresolved'
    $invalid=Read-Content (New-ContentText $basic -Stamp '2026-02-30 08:00:00')
    Check ($invalid.DateStatus -eq 'Invalid' -and $invalid.ReportDate -ceq '') 'Invalid calendar dates are rejected'
    $numbered=Read-Content ((New-ContentText $basic).Replace('Page: 4/7','Page: 5/7'))
    Check ($numbered.DateStatus -eq 'Conflict' -and $numbered.ReportDate -ceq '') 'Footer page numbers must match the parsed page'
    $onlyCover=Read-Content ([regex]::Replace((New-ContentText $basic),'(?m)^2026-11-10 08:00:00 Page:.*\n',''))
    Check ($onlyCover.DateStatus -eq 'Missing' -and $onlyCover.ReportDate -ceq '') 'Handed-over and reference dates are never used as report dates'
}
Scenario 'Reader whitespace variations are accepted without relaxing structural evidence' {
    $text=(New-ContentText $basic).Replace('Quality IEC Constancy Homogeneity / Water',"Quality IEC Constancy`nHomogeneity / Water").Replace('2026-11-10 08:00:00 Page:',"2026-11-10 08:00:00`nPage:")
    $row=Read-Content $text
    Check ($row.Status -eq 'Recognized' -and $row.DateStatus -eq 'Consensus' -and $row.Sections.Count -eq 2) 'Wrapped headings and split footer lines retain matching evidence'
    $early=[regex]::Replace((New-ContentText $basic),'(?ms)(^--- Page \d+ ---\n)(.*?)(^2026-11-10 08:00:00 Page: \d+/7\n)','$1$3$2')
    $row=Read-Content $early
    Check ($row.Status -eq 'Recognized' -and $row.DateStatus -eq 'Consensus') 'Footer text can occur before body headings in PDF extraction order'
    $row=Read-Content ($text.Replace('SOMATOM Definition Edge','Unsupported synthetic scanner'))
    Check ($row.Status -eq 'NeedsReview' -and $row.ProfileId -ceq '' -and $row.Model -ceq '') 'Known section words from an unsupported template remain uncertain'
}
Scenario 'Mixed printed outcomes stay literal and separate from document organization' {
    $row=Read-Content (New-ContentText $basic -MixedOutcomes)
    Check ($row.Status -eq 'Recognized' -and $row.ProfileId -eq 'siemens-iec-basic-v1') 'Mixed printed observations do not change the document template'
    Check ($row.Sections[0].OutcomeStatus -eq 'Conflict' -and $row.Sections[0].PrintedOutcomes -contains 'OK' -and $row.Sections[0].PrintedOutcomes -contains 'NOT OK') 'Both raw observations and their conflict are visible'
    Check ($row.ClinicalResult -eq 'Not inferred' -and $row.Issues -contains 'MixedPrintedOutcomes') 'No overall clinical PASS is invented from mixed results'
    $table=Read-Content ((New-ContentText $basic).Replace("`nOK`n","`nSynthetic evaluation OK`n"))
    Check (@($table.Sections|Where-Object{$_.PrintedOutcomes -contains 'OK'}).Count -eq 2) 'Terminal printed status tokens are recognized without retaining table labels or measurements'
    $spacing=Read-Content ((New-ContentText $basic -MixedOutcomes).Replace('NOT OK','not   ok'))
    Check ($spacing.Sections[0].PrintedOutcomes -contains 'NOT OK' -and $spacing.Sections[0].PrintedOutcomes -contains 'OK' -and $spacing.Sections[0].OutcomeStatus -eq 'Conflict') 'Case and spacing variations retain the negative observation beside OK'
    $alerts=Read-Content ((New-ContentText $basic).Replace("`nOK`n","`nwarning`nERROR`n"))
    Check ($alerts.Sections[0].PrintedOutcomes -contains 'WARNING' -and $alerts.Sections[0].PrintedOutcomes -contains 'ERROR') 'Literal warning and error observations remain visible as fixed tokens'
    $json=$row|ConvertTo-Json -Depth 12
    Check ($json -notmatch 'ConfirmedBy|ConfirmedAt|ConfirmedComponents|ClinicalReviewer' -and $json -notmatch 'Handed over|Reference measurement') 'Derived evidence contains no reviewer claims or copied private header text'
}
function New-DailyContentText([string]$Model='SOMATOM Definition Edge',[string[]]$Labels=@('Noise','Homogeneity'),[int]$Pages=4,[string]$Title='Quality Daily'){
    return (New-ContentText -Labels $Labels -Pages $Pages -Title $Title -Model $Model).Replace('Quality IEC Constancy','Quality Daily')
}
Scenario 'The supported SOMATOM Drive model retains exact Basic and Extended IEC profiles' {
    foreach($case in @(@{Labels=$basic;Profile='siemens-iec-basic-v1';Count=2},@{Labels=$extended;Profile='siemens-iec-extended-v1';Count=10})){
        $row=Read-Content (New-ContentText -Labels $case.Labels -Model 'SOMATOM Drive')
        Check ($row.Status -ceq 'Recognized' -and $row.ProfileId -ceq $case.Profile -and $row.Model -ceq 'SOMATOM Drive') 'An exact supported Drive model and complete IEC body are recognized'
        Check ($row.Category -ceq '' -and $row.Sections.Count -eq $case.Count -and $row.ClinicalResult -ceq 'Not inferred') 'Drive does not establish Daily or Monthly department policy or clinical approval'
    }
    foreach($model in @('SOMATOM Drive2','SOMATOM Drive-Pro','SOMATOM Definition Drive','SOMATOM FutureModel')){
        $row=Read-Content (New-ContentText -Labels $basic -Model $model)
        Check ($row.Status -ceq 'NeedsReview' -and $row.ProfileId -ceq '' -and $row.Model -ceq '') 'Similarly spelled or future model names are not treated as supported Drive templates'
    }
}
Scenario 'Numbered individual and combined additional IEC tests form a distinct policy-neutral profile' {
    $sets=@(@('Lightmarker','Topogram Pos.','Slice','MTF','Contrast'),@('MTF'),@('External Lightm.','Sag./Cor. Lightm.','Topogram Pos.','Slice','Homogeneity / Water','Noise','MTF','Contrast','Table Position'),@('Low Contrast'))
    foreach($labels in $sets){
        $row=Read-Content (New-ContentText -Labels $labels -Model 'SOMATOM Definition Flash')
        Check ($row.Status -ceq 'Recognized' -and $row.ProfileId -ceq 'siemens-iec-additional-v1' -and $row.Sections.Count -eq $labels.Count) 'Complete consecutively numbered known additional test sections are recognized independently of their count'
        Check ($row.Category -ceq '' -and $row.SuggestedCategory -ceq 'Monthly' -and $row.ClinicalResult -ceq 'Not inferred') 'Additional tests suggest a filing type while preserving the requirement for a saved department rule'
        Check ($row.CompleteRead -and $row.DateStatus -ceq 'Consensus' -and @($row.Sections|Where-Object OutcomeStatus -eq 'Printed').Count -eq $labels.Count) 'Every actual body section supplies supported printed evidence and matching page footer dates'
    }
    $contrast=Read-Content (New-ContentText -Labels @('Contrast','Low Contrast'))
    Check (($contrast.Sections.Code -join '|') -ceq 'Contrast|LowContrast') 'Low contrast has its own fixed section identity and cannot replace ordinary Contrast'
}
Scenario 'Additional IEC recognition withholds reference material, absent evidence and invalid section structure' {
    foreach($text in @((New-ContentText -Labels @('MTF Reference')),(New-ContentText -Labels @('MTF reference measurement')),(New-ContentText -Labels @('MTF') -TocOnly),((New-ContentText -Labels @('MTF')).Replace("`nOK`n","`n")),((New-ContentText -Labels @('MTF')).Replace('1. Quality IEC Constancy MTF','Quality IEC Constancy MTF')),((New-ContentText -Labels @('MTF')).Replace('1. Quality IEC Constancy MTF','2. Quality IEC Constancy MTF')),(New-ContentText -Labels @('MTF','MTF')),(New-ContentText -Labels @('MTF','Unknown additional test')))){
        $row=Read-Content $text
        Check ($row.Status -ceq 'NeedsReview' -and $row.ProfileId -ceq '' -and $row.Category -ceq '') 'A label or reference is insufficient without unique consecutive known test sections and actual body evidence'
    }
}
Scenario 'Exact manufacturer Quality Daily body sections identify Daily documents on each supported model' {
    foreach($model in @('SOMATOM Definition Edge','SOMATOM Definition Flash','SOMATOM Drive')){
        $row=Read-Content (New-DailyContentText -Model $model) 4
        Check ($row.Status -ceq 'Recognized' -and $row.ProfileId -ceq 'siemens-quality-daily-v1' -and $row.Model -ceq $model) 'The exact supported model and manufacturer Daily body template are recognized'
        Check ($row.Category -ceq 'Daily' -and $row.SuggestedCategory -ceq 'Daily' -and $row.ProfileName -ceq 'Siemens daily checks') 'Quality Daily is an explicit document label rather than an IEC frequency guess'
        Check (($row.Sections.Code -join '|') -ceq 'Noise|HomogeneityWater' -and $row.DateStatus -ceq 'Consensus' -and $row.CompleteRead) 'The complete Daily section order and footer evidence remain required'
        Check ($row.ClinicalResult -ceq 'Not inferred') 'A Daily document label never declares the scanner passed clinical QA'
    }
}
Scenario 'Daily names, table-of-contents text and mixed section families cannot substitute for the full Daily template' {
    $daily=New-DailyContentText
    $cases=@((New-DailyContentText -Labels @('Homogeneity','Noise')),(New-DailyContentText -Labels @('Noise')),(New-DailyContentText -Labels @('Noise','Homogeneity','MTF')),(New-DailyContentText -Labels @('Noise','Homogeneity Reference')),(New-DailyContentText -Model 'SOMATOM FutureModel'),($daily.Replace("`nOK`n","`n")),($daily.Replace('2. Quality Daily Homogeneity','2. Quality IEC Constancy Homogeneity / Water')),((New-ContentText -Labels @('Noise','Homogeneity') -Pages 4 -TocOnly).Replace('Quality IEC Constancy','Quality Daily')))
    foreach($text in $cases){
        $row=Read-Content $text 4
        Check ($row.Status -ceq 'NeedsReview' -and $row.ProfileId -ceq '' -and $row.Category -ceq '') 'Unknown, incomplete, reference-only, reordered or mixed Daily body evidence remains unresolved'
    }
}
Scenario 'Daily document classification preserves incomplete reads, footer conflicts and printed failures' {
    $daily=New-DailyContentText
    foreach($row in @((ConvertFrom-QaDocumentContent -Text $daily -Pages 4 -ReadPages 3),(ConvertFrom-QaDocumentContent -Text $daily -Pages 4 -ReadPages 4 -Truncated $true),(ConvertFrom-QaDocumentContent -Text $daily -Pages 4 -ReadPages 4 -NeedsOCR $true),(Read-Content ($daily.Replace('2026-11-10 08:00:00 Page: 4/4','2026-11-09 08:00:00 Page: 4/4')) 4))){
        Check ($row.Status -ceq 'NeedsReview' -and $row.Category -ceq '' -and $row.ClinicalResult -ceq 'Not inferred') 'Incomplete or conflicting Daily evidence is never accepted as a completed Daily document'
    }
    $failure=Read-Content ($daily.Replace("`nOK`n","`nFAIL`n")) 4
    Check ($failure.Status -ceq 'Recognized' -and $failure.Category -ceq 'Daily' -and @($failure.Sections|Where-Object{$_.PrintedOutcomes -contains 'FAIL'}).Count -eq 2) 'Printed failures retain the truthful Daily document type and remain available as source observations'
    Check ($failure.ClinicalResult -ceq 'Not inferred') 'No overall clinical interpretation is manufactured from the Daily label or failure tokens'
    $contradiction=Read-Content (New-DailyContentText -Title 'Monthly QA Report') 4
    Check ($contradiction.Status -ceq 'NeedsReview' -and $contradiction.Category -ceq '') 'An explicit Monthly cover title cannot silently coexist with the manufacturer Daily body label'
}
Scenario 'Classifier metadata and evidence codes are fixed and support safe display allowlists' {
    $definitions=@(Get-QaContentSectionDefinitions);$row=Read-Content (New-ContentText $extended)
    Check ((Get-QaContentClassifierVersion) -eq 1 -and $row.ClassifierVersion -eq 1 -and $row.TemplateVersion -eq 'siemens-iec-constancy-v1') 'The cache can bind classification to an explicit classifier/template version'
    Check ((Get-QaContentSupportRevision) -eq 3 -and $row.SupportRevision -eq 3) 'Additive support has its own retry revision without invalidating recognized classifier-version-one caches'
    Check ($definitions.Count -eq 11 -and @($definitions|Select-Object -ExpandProperty Code -Unique).Count -eq 11) 'Supported section codes have eleven fixed display definitions including distinct low contrast'
    foreach($section in $row.Sections){Check (@($definitions|Where-Object Code -ceq $section.Code).Count -eq 1 -and $section.EvidenceCode -ceq ('NumberedBodySection.'+$section.Code)) 'Evidence uses a fixed section code, never raw report text'}
}
$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Version='5.3.1';Runtime=$PSVersionTable.PSVersion.ToString();Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Synthetic Edge, compatible Flash and Drive model text only. Covers exact Basic and Extended IEC profiles, bounded individual/combined additional test sets and the explicit Quality Daily body family. Exact numbered Siemens IEC body-section profiles and repeated report footer consensus. Profile suggestions are separate from department mappings and clinical QA evidence.'}
if($OutputPath){$report|ConvertTo-Json -Depth 12|Set-Content $OutputPath -Encoding UTF8}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
if($failed){exit 1}
