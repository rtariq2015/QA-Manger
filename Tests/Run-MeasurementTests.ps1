[CmdletBinding()]param([string]$OutputPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'App/MeasurementParser.psm1') -Force -DisableNameChecking
$script:Results=New-Object 'Collections.Generic.List[object]';$script:Assertions=0
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Scenario([string]$Name,[scriptblock]$Body){
    try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS'});Write-Host ('PASS '+$Name)}
    catch{[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Detail=$_.Exception.Message});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}
}
function New-ValueRow([int]$Slice=1,[string]$Value='-0.75',[string]$Reference='-0.60',[string]$Lower='-4.00',[string]$Upper='3.40',[string]$Unit='HU'){
    return 'Slice '+$Slice+"`nTolerance`n"+$Value+' '+$Unit+' ('+$Reference+")`n"+$Lower+' ... '+$Upper+' '+$Unit
}
function New-MeasurementDocument([string]$Water='', [string]$Noise='', [switch]$Extended){
    if(-not $Water){$Water='Test: Typical body mode'+"`nWater Value Results for System A`n"+(New-ValueRow)}
    if(-not $Noise){$Noise='Test: Typical head mode'+"`nResult`nResults for System A`n"+(New-ValueRow -Value '3.50' -Reference '3.40' -Lower '3.00' -Upper '4.00')}
    $body=if($Extended){
        '1. Quality IEC Constancy Lightmarker'+"`nTest Results OK`n2. Quality IEC Constancy External Lightm.`nTest Results OK`n3. Quality IEC Constancy Sag./Cor. Lightm.`nTest Results OK`n4. Quality IEC Constancy Topogram Pos.`nTest Results OK`n5. Quality IEC Constancy Slice`nTest Results OK`n6. Quality IEC Constancy Homogeneity / Water`n"+$Water+"`nTest Results OK`n7. Quality IEC Constancy Noise`n"+$Noise+"`nTest Results OK`n8. Quality IEC Constancy MTF`nMTF 50% 1.25 lp/cm`nTest Results OK`n9. Quality IEC Constancy Contrast`nContrast 0.0002 1/HUcm`n10. Quality IEC Constancy Table Position`nTable position 1.4 mm`nTest Results OK"
    }else{'1. Quality IEC Constancy Homogeneity / Water'+"`n"+$Water+"`nTest Results OK`n2. Quality IEC Constancy Noise`n"+$Noise+"`nTest Results OK"}
    $parts=@(('SOMATOM Definition Edge'+"`nQuality IEC Constancy`nHanded over: 2016-05-20`nLast reference measurement: 2021-06-10"),'SYNTHETIC TABLE OF CONTENTS',$body)
    $text=''
    for($page=1;$page -le 3;$page++){$text+='--- Page '+$page+" ---`n"+$parts[$page-1]+"`n2025-02-03 08:15:00`nPage: "+$page+" / 3`n`n"}
    return $text
}
function Read-Measurements([string]$Text){return ConvertFrom-QaMeasurementText -Text $Text -Pages 3 -ReadPages 3}
function Metric($Result,[string]$Code){return @($Result.Measurements|Where-Object Code -eq $Code)}
function New-DailyMeasurementDocument([string]$Noise='', [string]$Water=''){
    $range='Tolerance 2.00 ... 5.00 HU'
    if(-not $Noise){
        $Noise="Test: Typical head mode`nResult`nResults for System A`n"
        for($n=1;$n -le 3;$n++){$Noise+='Slice '+$n+" 3.25 HU`n"};$Noise+=$range+"`nTest Results OK`nTest: Typical body mode`nResult`nResults for System A`n"
        for($n=1;$n -le 7;$n++){$Noise+='Slice '+$n+" 3.5 HU`n"};$Noise+=$range+"`nTest Results OK"
    }
    if(-not $Water){
        $Water="Test: Typical body mode`nWater Value Results for System A`n"
        for($n=1;$n -le 7;$n++){$Water+='Slice '+$n+" -0.25 HU`n"};$Water+="Tolerance -4.00 ... 4.00 HU`nTest Results OK`nTest: Typical head mode`nWater Value Results for System A`n"
        for($n=1;$n -le 3;$n++){$Water+='Slice '+$n+" 0.1 HU`n"};$Water+="Tolerance -4.00 ... 4.00 HU`nTest Results OK"
    }
    $parts=@("SOMATOM Definition Edge`nQuality Daily",'SYNTHETIC TABLE OF CONTENTS',("1. Quality Daily Noise`n"+$Noise+"`n2. Quality Daily Homogeneity`n"+$Water))
    $text='';for($page=1;$page -le 3;$page++){$text+='--- Page '+$page+" ---`n"+$parts[$page-1]+"`n2025-02-03 08:15:00`nPage: "+$page+" / 3`n`n"};return $text
}

function New-AlignmentDocument([string]$Label='Lightmarker',[string]$Table='', [switch]$Standalone,[string]$ExtraSections=''){
    if(-not $Table){$Table="Result [mm]`n0.43`nTolerance`n-1.75 ... 1.75"}
    $title=if($Standalone){'Quality IEC Constancy '+$Label}else{'1. Quality IEC Constancy '+$Label}
    $body=$title+"`nTest: Synthetic alignment check`n"+$Table+"`nTest Results OK"+$ExtraSections
    $parts=if($Standalone){@("SOMATOM Definition Flash`nQuality IEC Constancy`nSYNTHETIC ALIGNMENT EXAMPLE",$body)}else{@("SOMATOM Definition Flash`nQuality IEC Constancy`nSYNTHETIC ALIGNMENT EXAMPLE",'Table of contents',$body)}
    $text='';for($page=1;$page -le $parts.Count;$page++){$text+='--- Page '+$page+" ---`n"+$parts[$page-1]+"`n2025-04-09 09:25:00`nPage: "+$page+' / '+$parts.Count+"`n`n"};return $text
}

$script:Basic=New-MeasurementDocument

Scenario 'The two explicit HU tables yield current measurements, printed limits and fixed provenance' {
    $r=Read-Measurements $script:Basic;$water=@(Metric $r WaterCTNumber);$noise=@(Metric $r ImageNoise)
    Check ((Get-QaMeasurementParserVersion) -eq 1 -and $r.MeasurementVersion -eq 1) 'Measurement parser versions are explicit.'
    Check ($r.Status -eq 'Extracted' -and $r.CompleteRead -and $r.Issues.Count -eq 0) 'Complete supported input has no measurement-reading issues.'
    Check ($r.Measurements.Count -eq 2 -and $water.Count -eq 1 -and $noise.Count -eq 1) 'Each supported single-metric table contributes exactly one measurement.'
    Check ($water[0].Value -ceq '-0.75' -and $water[0].LowerLimit -ceq '-4' -and $water[0].UpperLimit -ceq '3.4') 'Current water value and explicit limits retain their distinct roles.'
    Check ($noise[0].Value -ceq '3.5' -and $noise[0].LowerLimit -ceq '3' -and $noise[0].UpperLimit -ceq '4') 'Current noise value and printed limits are extracted.'
    Check ($water[0].Mode -eq 'Body' -and $noise[0].Mode -eq 'Head' -and $water[0].SourceSystem -eq 'A' -and $water[0].Slice -ceq '1') 'Head/body, system and slice context is fixed and scoped.'
    Check ($water[0].Page -eq 3 -and $noise[0].Page -eq 3 -and $water[0].Unit -ceq 'HU' -and $water[0].Status -eq 'Printed') 'Printed value page, unit and documentary status are retained.'
    Check ($r.ClinicalResult -eq 'Not inferred' -and -not $water[0].PSObject.Properties['Evidence']) 'No clinical decision or raw evidence text is manufactured.'
}
Scenario 'Decimal-comma, nonbreaking spaces and Unicode minus are normalized independently of locale' {
    $water='Test: Typical body mode'+"`nWater Value Results for System B`n"+(New-ValueRow -Value '-0,25' -Reference '-0,10' -Lower '-4,00' -Upper '3,50')
    $text=(New-MeasurementDocument -Water $water).Replace('-0,25',([string][char]0x2212+'0,25')).Replace(' HU',([string][char]0x00a0+'HU'))
    $old=[Threading.Thread]::CurrentThread.CurrentCulture
    try{[Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('de-DE');$r=Read-Measurements $text}
    finally{[Threading.Thread]::CurrentThread.CurrentCulture=$old}
    $w=@(Metric $r WaterCTNumber)[0]
    Check ($r.Status -eq 'Extracted' -and $w.Value -ceq '-0.25') 'Decimal commas and a Unicode minus produce a normalized invariant value.'
    Check ($w.LowerLimit -ceq '-4' -and $w.UpperLimit -ceq '3.5' -and $w.SourceSystem -eq 'B') 'Printed bounds and supported source-system context are retained.'
}
Scenario 'Each test mode and source system keeps its own slice rows' {
    $water='Test: Typical body mode'+"`nWater Value Results for System A`n"+(New-ValueRow -Slice 1)+"`n"+(New-ValueRow -Slice 2 -Value '-0.40')+"`nTest: Typical head mode`nWater Value Results for System B`n"+(New-ValueRow -Slice 1 -Value '0.10')
    $r=Read-Measurements (New-MeasurementDocument -Water $water);$w=@(Metric $r WaterCTNumber)
    Check ($r.Status -eq 'Extracted' -and $w.Count -eq 3) 'Separate test modes and systems do not silently overwrite matching slice numbers.'
    Check (@($w|Where-Object{$_.Mode -eq 'Body' -and $_.SourceSystem -eq 'A'}).Count -eq 2) 'Both body slices are present.'
    Check (@($w|Where-Object{$_.Mode -eq 'Head' -and $_.SourceSystem -eq 'B' -and $_.Value -ceq '0.1'}).Count -eq 1) 'Head mode starts a separate system and slice context.'
}
Scenario 'Reference values, scan parameters, multicolumn tables and other test sections are not current HU measurements' {
    $water='Test: Typical body mode'+"`nWindow width 600 HU`nWindow center 12 HU`nVoltage 140 kV`nWater Value Results for System A`n"+(New-ValueRow)+"`nResults for System A`nSystem A`nCenter Diff.3 Diff.6 Diff.9 Diff.12`n"+(New-ValueRow -Value '8.25')+"`n1.4 HU (1.2)`n0.0 ... 2.0 HU"
    $r=Read-Measurements (New-MeasurementDocument -Water $water -Extended)
    Check ($r.Status -eq 'Extracted' -and $r.Measurements.Count -eq 2) 'Known single-metric summaries are read while other tables and sections are skipped.'
    Check (@($r.Measurements|Where-Object{$_.Value -in @('-0.6','3.4','600','12','140','8.25','1.4')}).Count -eq 0) 'Parenthesized references and unbound parameter/table values cannot become current measurements.'
    Check (@($r.Measurements|Where-Object{$_.Code -notin @('WaterCTNumber','ImageNoise')}).Count -eq 0) 'Only the fixed metric allowlist is returned.'
}
Scenario 'Missing or unsupported row structure is visible for review without inventing limits' {
    $water='Test: Typical body mode'+"`nWater Value Results for System A`nSlice 1`nTolerance`n0.75 HU (0.60)`nNo printed limits"
    $r=Read-Measurements (New-MeasurementDocument -Water $water)
    Check ($r.Status -eq 'NeedsReview' -and $r.Issues -contains 'UnsupportedMeasurementRow') 'An unsupported table row is an explicit reading issue.'
    Check (@(Metric $r WaterCTNumber).Count -eq 0 -and @(Metric $r ImageNoise).Count -eq 1) 'The unsupported row is skipped while a separately valid metric remains available.'
    Check ($r.ClinicalResult -eq 'Not inferred') 'Missing limits never manufacture an assessment.'
}
Scenario 'Conflicting duplicate identity is omitted instead of selecting a convenient current value' {
    $water='Test: Typical body mode'+"`nWater Value Results for System A`n"+(New-ValueRow)+"`nWater Value Results for System A`n"+(New-ValueRow -Value '0.90')
    $r=Read-Measurements (New-MeasurementDocument -Water $water)
    Check ($r.Status -eq 'NeedsReview' -and $r.Issues -contains 'AmbiguousDuplicateMeasurement') 'Repeated metric, mode, system and slice identity is flagged.'
    Check (@(Metric $r WaterCTNumber).Count -eq 0 -and @(Metric $r ImageNoise).Count -eq 1) 'Both conflicting duplicates are withheld, preserving a separately valid metric.'
}
Scenario 'Reversed printed bounds retain only the unambiguous value and require review' {
    $water='Test: Typical body mode'+"`nWater Value Results for System A`n"+(New-ValueRow -Value '0.90' -Lower '3.00' -Upper '-3.00')
    $r=Read-Measurements (New-MeasurementDocument -Water $water);$w=@(Metric $r WaterCTNumber)[0]
    Check ($r.Status -eq 'NeedsReview' -and $r.Issues -contains 'InvalidPrintedLimits') 'Conflicting printed bounds cannot be treated as a valid range.'
    Check ($w.Value -ceq '0.9' -and $null -eq $w.LowerLimit -and $null -eq $w.UpperLimit -and $w.Status -eq 'NeedsReview') 'The literal current value remains distinct from unusable bounds.'
}
Scenario 'Mixed printed outcomes stay separate from numeric reading and cannot turn into clinical PASS' {
    $water='Test: Typical body mode'+"`nWater Value Results for System A`n"+(New-ValueRow)+"`nTest Results NOT OK"
    $r=Read-Measurements (New-MeasurementDocument -Water $water)
    Check ($r.Measurements.Count -eq 2 -and $r.Status -eq 'NeedsReview' -and $r.Issues -contains 'MixedPrintedObservations') 'Mixed OK/NOT OK evidence requires review while clear printed values remain readable.'
    Check ($r.ClinicalResult -eq 'Not inferred' -and @($r.Measurements|Where-Object Status -match 'PASS|FAIL').Count -eq 0) 'No printed outcome or numerical value creates a clinical approval.'
}
Scenario 'Incomplete and OCR-only input cannot claim a complete successful measurement read' {
    $r=ConvertFrom-QaMeasurementText -Text $script:Basic -Pages 3 -ReadPages 2 -Truncated $true
    Check (-not $r.CompleteRead -and $r.Status -eq 'NeedsReview' -and $r.Issues -contains 'IncompleteRead') 'Declared truncation remains explicit.'
    Check ($r.Measurements.Count -eq 2 -and @($r.Measurements|Where-Object Status -ne NeedsReview).Count -eq 0) 'Clear rows in incomplete text remain marked for review.'
    $ocr=ConvertFrom-QaMeasurementText -Text $script:Basic -Pages 3 -ReadPages 3 -NeedsOCR $true
    Check ($ocr.Measurements.Count -eq 0 -and $ocr.Status -eq 'NeedsReview' -and $ocr.ReasonCode -eq 'NoReadableText') 'OCR-only input cannot supply reliable measurement rows.'
}
Scenario 'Conflicting report dates flag the numeric evidence without accepting a clinical result' {
    $text=$script:Basic.Replace('2025-02-03 08:15:00'+"`nPage: 2",'2025-02-04 08:15:00'+"`nPage: 2")
    $r=Read-Measurements $text
    Check ($r.Status -eq 'NeedsReview' -and $r.Issues -contains 'UncertainReportDate' -and $r.Measurements.Count -eq 2) 'Conflicting footer evidence remains visible as a review issue.'
    Check ($r.ClinicalResult -eq 'Not inferred') 'A footer conflict never creates a clinical judgment.'
}
Scenario 'Unknown templates, extra sections and unbound text cannot supply measurements' {
    foreach($text in @($script:Basic.Replace('SOMATOM Definition Edge','UNKNOWN SCANNER'),$script:Basic.Replace('2. Quality IEC Constancy Noise','2. Quality IEC Constancy Unknown Test'),'Water CT value: 0.75 HU')){
        $r=Read-Measurements $text
        Check ($r.Measurements.Count -eq 0 -and $r.Status -eq 'NeedsReview') 'Only a supported numbered report profile is eligible.'
    }
}
Scenario 'Measurement count is bounded and clipping remains visible' {
    $water='Test: Typical body mode'+"`nWater Value Results for System A`n"
    for($n=1;$n -le 105;$n++){$water+=(New-ValueRow -Slice $n)+"`n"}
    $r=Read-Measurements (New-MeasurementDocument -Water $water)
    Check ($r.Measurements.Count -eq 100 -and $r.Status -eq 'NeedsReview' -and $r.Issues -contains 'MeasurementLimitReached') 'The fixed output bound does not masquerade as a complete measurement set.'
}
Scenario 'Ambiguous thousands grouping and mismatched units are rejected' {
    foreach($row in @((New-ValueRow -Value '1,234'),(New-ValueRow -Unit 'mGy'))){
        $water='Test: Typical body mode'+"`nWater Value Results for System A`n"+$row
        $r=Read-Measurements (New-MeasurementDocument -Water $water)
        Check ($r.Status -eq 'NeedsReview' -and @(Metric $r WaterCTNumber).Count -eq 0) 'Ambiguous numeric or unit binding does not create a measurement.'
    }
}
Scenario 'Wrapped numbered headings and split mode labels keep fixed document context' {
    $text=$script:Basic.Replace('1. Quality IEC Constancy Homogeneity / Water',"1.`nQuality IEC Constancy`nHomogeneity / Water").Replace('Test: Typical body mode',"Test:`nTypical body mode")
    $r=Read-Measurements $text;$w=@(Metric $r WaterCTNumber)
    Check ($r.Status -eq 'Extracted' -and $w.Count -eq 1 -and $w[0].Mode -eq 'Body') 'Equivalent explicit wrapped headings and mode labels remain readable.'
}

Scenario 'Manufacturer Daily inline tables supply separate head and body readings with one printed range per table' {
    foreach($model in @('SOMATOM Definition Edge','SOMATOM Definition Flash','SOMATOM Drive')){
        $text=(New-DailyMeasurementDocument).Replace('SOMATOM Definition Edge',$model);$r=Read-Measurements $text
        Check ($r.MeasurementVersion -eq 1 -and $r.MeasurementSupportRevision -eq 3 -and (Get-QaMeasurementSupportRevision) -eq 3) 'The additive support revision does not invalidate existing schema-one HU measurements.'
        Check ($r.Status -eq 'Extracted' -and $r.Measurements.Count -eq 20) 'The four exact single-system Daily tables provide twenty current readings.'
        Check (@(Metric $r WaterCTNumber).Count -eq 10 -and @(Metric $r ImageNoise).Count -eq 10) 'Water and noise remain different fixed metrics.'
        Check (@($r.Measurements|Where-Object{$_.Mode -eq 'Head'}).Count -eq 6 -and @($r.Measurements|Where-Object{$_.Mode -eq 'Body'}).Count -eq 14) 'Head and body slices remain separate, without context averaging.'
        Check (@($r.Measurements|Where-Object{$_.SourceSystem -cne 'A' -or $_.Source -cne 'PrintedDailyInlineTable' -or $_.Page -ne 3}).Count -eq 0) 'Each accepted Daily row retains an exact source-system and printed page.'
        $n=@($r.Measurements|Where-Object{$_.Code -eq 'ImageNoise' -and $_.Mode -eq 'Head'})[0]
        Check ($n.Value -ceq '3.25' -and $n.LowerLimit -ceq '2' -and $n.UpperLimit -ceq '5' -and $r.ClinicalResult -eq 'Not inferred') 'The trailing table range is bound explicitly without a clinical judgment.'
    }
}
Scenario 'Dual-source Daily columns and unsupported acquisition names cannot merge with single-system body readings' {
    $text=New-DailyMeasurementDocument
    $dual="`nTest: Typical body mode for systems A and B`nResult`nResults for System A Results for System B`nSlice 1 90.1 HU 91.2 HU`nTolerance 80 ... 100 HU 80 ... 100 HU`nTest Results OK"
    $text=$text.Replace('2. Quality Daily Homogeneity',$dual+"`n2. Quality Daily Homogeneity")
    $r=Read-Measurements $text
    Check ($r.Measurements.Count -eq 20 -and @($r.Measurements|Where-Object Value -in @('90.1','91.2')).Count -eq 0) 'A separate dual-source test does not become a duplicate or a convenient body-A reading.'
    $bad="Test: Typical body mode`nResult`nResults for System A Results for System B`nSlice 1 90.1 HU 91.2 HU`nTolerance 80 ... 100 HU 80 ... 100 HU`nTest Results OK"
    $r=Read-Measurements (New-DailyMeasurementDocument -Noise $bad)
    Check (@(Metric $r ImageNoise).Count -eq 0 -and @(Metric $r WaterCTNumber).Count -eq 10) 'Multi-column numeric rows are excluded while an independent exact table remains usable.'
}
Scenario 'Daily inline rows require their own complete unit-matched range and preserve malformed evidence as an issue' {
    $bad="Test: Typical head mode`nResult`nResults for System A`nSlice 1 3.5 HU`nTolerance 2 ... 5 mm`nTest Results OK"
    $r=Read-Measurements (New-DailyMeasurementDocument -Noise $bad)
    Check ($r.Status -eq 'NeedsReview' -and $r.Issues -contains 'UnsupportedMeasurementRow' -and @(Metric $r ImageNoise).Count -eq 0) 'A mismatched trailing range cannot bind to a Daily numeric value.'
    $bad=$bad.Replace('Tolerance 2 ... 5 mm','Tolerance 5 ... 2 HU');$r=Read-Measurements (New-DailyMeasurementDocument -Noise $bad);$n=@(Metric $r ImageNoise)[0]
    Check ($r.Issues -contains 'InvalidPrintedLimits' -and $n.Value -ceq '3.5' -and $null -eq $n.LowerLimit -and $null -eq $n.UpperLimit) 'An explicit current value can remain warned while reversed limits stay absent.'
    $ambiguous=$bad.Replace('Tolerance 5 ... 2 HU',"Tolerance 2 ... 5 HU`nTolerance 1 ... 6 HU");$r=Read-Measurements (New-DailyMeasurementDocument -Noise $ambiguous)
    Check (@(Metric $r ImageNoise).Count -eq 0 -and $r.Issues -contains 'MulticolumnMeasurementRow') 'A second unbound range cannot be ignored to select a convenient Daily table limit.'
}
Scenario 'Repeated Daily table context is withheld and incomplete Daily reads remain warned' {
    $repeat="Test: Typical head mode`nResult`nResults for System A`nSlice 1 3.25 HU`nTolerance 2 ... 5 HU`nResult`nResults for System A`nSlice 1 3.75 HU`nTolerance 2 ... 5 HU`nTest Results OK"
    $r=Read-Measurements (New-DailyMeasurementDocument -Noise $repeat)
    Check ($r.Issues -contains 'AmbiguousDuplicateMeasurement' -and @(Metric $r ImageNoise).Count -eq 0) 'Repeated mode/system/slice rows cannot choose an arbitrary value.'
    $r=ConvertFrom-QaMeasurementText -Text (New-DailyMeasurementDocument) -Pages 3 -ReadPages 2 -Truncated $true
    Check (-not $r.CompleteRead -and $r.Measurements.Count -eq 20 -and @($r.Measurements|Where-Object Status -ne NeedsReview).Count -eq 0) 'Incomplete Daily evidence never becomes a verified normal measurement.'
}
Scenario 'Slice-thickness results use current millimetres and skip acquisition parameters and parenthesized references' {
    $text=New-MeasurementDocument -Extended
    $slice="5. Quality IEC Constancy Slice`nSlice thickness parameter 999 mm`nTest: Typical body mode`nResult`nSystem A`n"+(New-ValueRow -Value '6.25' -Reference '6.10' -Lower '5.50' -Upper '7.50' -Unit 'mm')+"`nTest Results OK"
    $text=$text.Replace("5. Quality IEC Constancy Slice`nTest Results OK",$slice)
    $r=Read-Measurements $text;$m=@(Metric $r SliceThickness)
    Check ($r.Status -eq 'Extracted' -and $m.Count -eq 1 -and $r.Measurements.Count -eq 3) 'The exact slice-result table adds one distinct fixed metric.'
    Check ($m[0].Value -ceq '6.25' -and $m[0].LowerLimit -ceq '5.5' -and $m[0].UpperLimit -ceq '7.5' -and $m[0].Unit -ceq 'mm' -and $m[0].Label -ceq 'Slice thickness') 'Only the printed current mm value and its own mm bounds are extracted.'
    Check ($m[0].Mode -ceq 'Body' -and $m[0].SourceSystem -ceq 'A' -and $m[0].Slice -ceq '1' -and $m[0].Page -eq 3) 'Slice-thickness points preserve their own mode, system, slice and page.'
    $wrong=Read-Measurements ($text.Replace('6.25 mm (6.10)','6.25 HU (6.10)'))
    Check (@(Metric $wrong SliceThickness).Count -eq 0 -and $wrong.Issues -contains 'UnsupportedMeasurementRow') 'A water-unit token cannot enter the millimetre metric.'
    $unknown=Read-Measurements ($text.Replace('Test: Typical body mode','Test: Another acquisition mode'))
    Check (@(Metric $unknown SliceThickness).Count -eq 0) 'An unsupported acquisition does not merge into the simple body series.'
}
Scenario 'Historical reference documents cannot supply current measurements even when they contain readable-looking values' {
    $text=$script:Basic.Replace('1. Quality IEC Constancy Homogeneity / Water','1. Quality IEC Constancy Reference Homogeneity / Water').Replace('2. Quality IEC Constancy Noise','2. Quality IEC Constancy Reference Noise')
    $r=Read-Measurements $text
    Check ($r.Measurements.Count -eq 0 -and $r.ReasonCode -ceq 'ReferenceDocument' -and $r.MeasurementSupportRevision -eq 3) 'Recognized historical-reference text is explicitly excluded before numeric parsing.'
    Check ($r.CompleteRead -and $r.ClinicalResult -eq 'Not inferred') 'Reading a reference document neither converts its numbers into current points nor creates clinical approval.'
    $mixed=$script:Basic.Replace('1. Quality IEC Constancy Homogeneity / Water','1. Quality IEC Constancy Reference Unknown Historical Test');$unknown=Read-Measurements $mixed
    Check ($unknown.Measurements.Count -eq 0 -and $unknown.ReasonCode -ceq 'ReferenceDocument') 'An unknown or mixed actual Reference heading is excluded independently of strict reference-profile recognition.'
}

Scenario 'Monthly scalar alignment tables retain printed units and avoid invented acquisition identities' {
    foreach($pair in @(@('Lightmarker','Lightmarker'),@('External Lightm.','ExternalLightmarker'),@('Topogram Pos.','TopogramPosition'))){
        $r=Read-Measurements (New-AlignmentDocument -Label $pair[0]);$rows=@(Metric $r $pair[1])
        Check ($r.Status -ceq 'Extracted' -and $r.MeasurementVersion -eq 1 -and $r.MeasurementSupportRevision -eq 3 -and $rows.Count -eq 1) 'A complete supported current scalar section supplies one capability-three reading.'
        $m=$rows[0];Check ($m.Value -ceq '0.43' -and $m.LowerLimit -ceq '-1.75' -and $m.UpperLimit -ceq '1.75' -and $m.Unit -ceq 'mm' -and $m.Page -eq 3) 'The explicit Result unit binds only its adjacent current scalar and range on their source page.'
        Check ($m.Mode -ceq 'Unspecified' -and $m.SourceSystem -ceq 'NotSpecified' -and $m.Slice -ceq '' -and $m.Context -ceq 'Overall' -and $m.ContextSection -ceq $pair[1] -and $m.Source -ceq 'PrintedAlignmentResult') 'Missing system and slice identities are preserved as absent, with a fixed section context.'
        Check ($r.ClinicalResult -ceq 'Not inferred' -and $m.Status -ceq 'Printed') 'A printed numeric reading does not manufacture a clinical decision.'
    }
}
Scenario 'Standalone page-two component titles and wrapped numbered titles use classified body evidence' {
    foreach($pair in @(@('Lightmarker','Lightmarker'),@('External Lightm.','ExternalLightmarker'),@('Topogram Pos.','TopogramPosition'))){
        $text=New-AlignmentDocument -Label $pair[0] -Standalone;$r=ConvertFrom-QaMeasurementText -Text $text -Pages 2 -ReadPages 2
        Check ($r.Status -ceq 'Extracted' -and $r.Measurements.Count -eq 1 -and $r.Measurements[0].Code -ceq $pair[1] -and $r.Measurements[0].Page -eq 2) 'Only a recognized standalone component can authorize its page-two scalar table.'
    }
    $text=(New-AlignmentDocument).Replace('1. Quality IEC Constancy Lightmarker',"1.`nQuality IEC Constancy`nLightmarker")
    $r=Read-Measurements $text;Check ($r.Measurements.Count -eq 1 -and $r.Measurements[0].Code -ceq 'Lightmarker') 'Equivalent split ordinal and label preserve the same exact classified body section.'
}
Scenario 'Generic page headers do not consume the following real numbered alignment heading' {
    foreach($title in @('1. Quality IEC Constancy Lightmarker',"1.`nQuality IEC Constancy Lightmarker","1.`nQuality IEC Constancy`nLightmarker")){
        $body="SOMATOM Definition Flash`nQuality IEC Constancy`n"+$title
        $text=(New-AlignmentDocument).Replace('1. Quality IEC Constancy Lightmarker',$body)
        $r=Read-Measurements $text;$rows=@(Metric $r Lightmarker)
        Check ($r.Status -ceq 'Extracted' -and $rows.Count -eq 1 -and $rows[0].Value -ceq '0.43' -and $rows[0].Page -eq 3) 'A generic manufacturer page header leaves the first full or wrapped body heading available for exact classified authorization.'
    }
}
Scenario 'Separate monthly sections stay distinct and nearby historical comparisons are not current values' {
    $extra="`n2. Quality IEC Constancy External Lightm.`nTest: Synthetic external alignment`nResult [mm]`n-0.31`nTolerance`n-2.25 ... 2.25`nTest Results OK`n3. Quality IEC Constancy Topogram Pos.`nTest: Synthetic topogram check`nResult [mm]`n0.62`nTolerance`n-2.5 ... 2.5`nTest Results OK"
    $table="Reference comparison [mm]`n98.2`nScan position 200 mm`nResult [mm]`n0.43`nTolerance`n-1.75 ... 1.75"
    $r=Read-Measurements (New-AlignmentDocument -Table $table -ExtraSections $extra)
    Check ($r.Status -ceq 'Extracted' -and $r.Measurements.Count -eq 3 -and @(Metric $r Lightmarker).Count -eq 1 -and @(Metric $r ExternalLightmarker).Count -eq 1 -and @(Metric $r TopogramPosition).Count -eq 1) 'Each classified scalar section has its own metric identity.'
    Check (@($r.Measurements|Where-Object Value -in @('98.2','200')).Count -eq 0 -and @(Metric $r ExternalLightmarker)[0].Value -ceq '-0.31') 'A comparison value or scan-position parameter cannot replace the current Result scalar.'
}
Scenario 'Scalar alignment rejects malformed, detached, ambiguous and mismatched-unit tables' {
    foreach($table in @("Result [mm]`n0.43 0.44`nTolerance`n-1.75 ... 1.75", "Result [mm]`n0.43`n0.44`nTolerance`n-1.75 ... 1.75", "Result [mm]`n0.43`nTolerance`n-1.75 ... 1.75 cm", "Result [cm]`n0.43`nTolerance`n-1.75 ... 1.75", "Result [mm]`n0.43 mm`nTolerance`n-1.75 ... 1.75", "Result [mm]`n1,234`nTolerance`n-1.75 ... 1.75", "Result [mm]`n0.43`nTolerance`n-1.75 ... 1.75`n0.99")){
        $r=Read-Measurements (New-AlignmentDocument -Table $table)
        Check ($r.Measurements.Count -eq 0 -and $r.Status -ceq 'NeedsReview') 'An ambiguous scalar layout never selects a convenient value or guesses its unit.'
    }
    $table="Result [mm]`n0.43`nTolerance`n-1.75 ... 1.75`nResult [mm]`n0.44`nTolerance`n-1.75 ... 1.75"
    $r=Read-Measurements (New-AlignmentDocument -Table $table)
    Check ($r.Measurements.Count -eq 0 -and $r.Issues -contains 'AmbiguousDuplicateMeasurement') 'Two Result tables in one scalar section are withheld rather than merged.'
}
Scenario 'Scalar alignment tables cannot borrow across page boundaries or override incomplete date evidence' {
    $text=(New-AlignmentDocument).Replace(' / 3',' / 4').Replace('Page: 3 / 4','Page: 4 / 4')
    $text=$text.Replace("0.43`nTolerance", "0.43`n2025-04-09 09:25:00`nPage: 3 / 4`n`n--- Page 4 ---`nTolerance")
    $r=ConvertFrom-QaMeasurementText -Text $text -Pages 4 -ReadPages 4
    Check ($r.CompleteRead -and $r.Measurements.Count -eq 0 -and $r.Issues -contains 'UnsupportedMeasurementRow' -and $r.Issues -notcontains 'UncertainReportDate') 'A complete date-consistent report still cannot borrow scalar Result and Tolerance cells across a page boundary.'
    $text=New-AlignmentDocument;$partial=ConvertFrom-QaMeasurementText -Text $text -Pages 3 -ReadPages 2 -Truncated $true
    Check ($partial.Measurements.Count -eq 0 -and -not $partial.CompleteRead) 'New scalar metrics require a complete read instead of presenting partial body values.'
    $text=$text.Replace('2025-04-09 09:25:00'+"`nPage: 2",'2025-04-10 09:25:00'+"`nPage: 2")
    $conflict=Read-Measurements $text
    Check ($conflict.Measurements.Count -eq 0 -and $conflict.Issues -contains 'UncertainReportDate') 'Conflicting footer dates cannot authorize new current alignment values.'
}
Scenario 'Alignment requires actual body evidence rather than a plausible table of contents or empty Extended section' {
    $fake="1. Quality IEC Constancy Lightmarker`nTest: TOC only`nResult [mm]`n91.7`nTolerance`n-99 ... 99`nTest Results OK"
    $text=(New-AlignmentDocument).Replace('Table of contents',"Table of contents`n"+$fake);$r=Read-Measurements $text
    Check ($r.Measurements.Count -eq 1 -and $r.Measurements[0].Value -ceq '0.43' -and $r.Measurements[0].Page -eq 3) 'A page-two contents table cannot override the separate classified body-page Result.'
    $bare="1. Quality IEC Constancy Lightmarker`nTest: Synthetic alignment`nResult [mm]`n0.43`nTolerance`n-1.75 ... 1.75"
    $text=(New-MeasurementDocument -Extended).Replace("1. Quality IEC Constancy Lightmarker`nTest Results OK",$bare);$r=Read-Measurements $text
    Check (@(Metric $r Lightmarker).Count -eq 0 -and @(Metric $r WaterCTNumber).Count -eq 1) 'A section without classified body evidence cannot borrow the other Extended sections to authorize an alignment reading.'
}
Scenario 'Alignment normalization retains current values but uncertain bounds remain explicit' {
    $table="Result [mm]`n+0,43`nTolerance`n-1,75 ... 1,75";$r=Read-Measurements (New-AlignmentDocument -Table $table)
    Check ($r.Measurements.Count -eq 1 -and $r.Measurements[0].Value -ceq '0.43' -and $r.Measurements[0].LowerLimit -ceq '-1.75') 'Supported decimal commas and leading signs normalize invariantly.'
    $bad=Read-Measurements (New-AlignmentDocument -Table "Result [mm]`n0.43`nTolerance`n1.75 ... -1.75")
    Check ($bad.Measurements.Count -eq 1 -and $bad.Measurements[0].Status -ceq 'NeedsReview' -and $null -eq $bad.Measurements[0].LowerLimit -and $null -eq $bad.Measurements[0].UpperLimit -and $bad.Issues -contains 'InvalidPrintedLimits') 'Reversed explicit limits remain absent without hiding the separately clear current value.'
}
Scenario 'Historical and suspected reference alignment bodies never supply current measurements' {
    foreach($label in @('Reference Lightmarker','Reference Unlisted Test')){
        $text=New-AlignmentDocument -Label $label;$r=Read-Measurements $text
        Check ($r.Measurements.Count -eq 0 -and $r.ReasonCode -ceq 'ReferenceDocument') 'A known or suspected Reference heading excludes scalar evidence before extraction.'
    }
    $unknown=Read-Measurements ((New-AlignmentDocument).Replace('SOMATOM Definition Flash','SYNTHETIC UNKNOWN MODEL'))
    Check ($unknown.Measurements.Count -eq 0 -and $unknown.ReasonCode -ceq 'UnsupportedProfile') 'An unknown manufacturer body cannot authorize an otherwise plausible scalar row.'
}

Scenario 'Explicit sagittal and coronal header columns retain their separate printed axis values' {
    $table="Result`nSagittal Light Marker Coronal Light Marker`nResult`nTolerance`n0.27 mm`n-1.65 ... 1.65 mm`n-0.38 mm`n-1.45 ... 1.45 mm"
    foreach($standalone in @($false,$true)){
        $text=New-AlignmentDocument -Label 'Sag./Cor. Lightm.' -Table $table -Standalone:$standalone;$pages=if($standalone){2}else{3};$r=ConvertFrom-QaMeasurementText -Text $text -Pages $pages -ReadPages $pages
        $axes=@(Metric $r SagittalCoronalLightmarker)
        Check ($r.Status -ceq 'Extracted' -and $axes.Count -eq 2) 'The exact explicitly labelled two-column block supplies both complete axis pairs.'
        $s=@($axes|Where-Object Context -CEQ 'Sagittal')[0];$c=@($axes|Where-Object Context -CEQ 'Coronal')[0]
        Check ($s.Value -ceq '0.27' -and $s.LowerLimit -ceq '-1.65' -and $s.UpperLimit -ceq '1.65' -and $c.Value -ceq '-0.38' -and $c.LowerLimit -ceq '-1.45' -and $c.UpperLimit -ceq '1.45') 'Distinct scalar/range column pairs remain bound to their printed sagittal and coronal headers.'
        Check (@($axes|Where-Object{$_.Mode -cne 'Unspecified' -or $_.SourceSystem -cne 'NotSpecified' -or $_.Slice -cne '' -or $_.Page -ne $pages -or $_.Unit -cne 'mm'}).Count -eq 0) 'Axes do not manufacture head/body, system or slice identities.'
    }
}
Scenario 'Axis alignment rejects reordered headers, missing pairs and extra numeric columns' {
    $table="Result`nSagittal Light Marker Coronal Light Marker`nResult`nTolerance`n0.27 mm`n-1.65 ... 1.65 mm`n-0.38 mm`n-1.45 ... 1.45 mm"
    foreach($bad in @($table.Replace('Sagittal Light Marker Coronal Light Marker','Coronal Light Marker Sagittal Light Marker'),$table.Replace("0.27 mm`n",''),$table.Replace('0.27 mm','0.27 mm 0.28 mm'),$table.Replace('-0.38 mm','-0.38 cm'),($table+"`n0.55 mm"),($table+"`n"+$table))){
        $r=Read-Measurements (New-AlignmentDocument -Label 'Sag./Cor. Lightm.' -Table $bad)
        Check ($r.Measurements.Count -eq 0 -and $r.Status -ceq 'NeedsReview') 'A malformed or ambiguous axis layout cannot guess column roles from its title.'
    }
}

$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Product='CT QA Manager Pro';Feature='Printed measurement extraction';MeasurementVersion=1;MeasurementSupportRevision=3;Runtime=$PSVersionTable.PSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5 -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT);SyntheticOnly=$true;Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Synthetic IEC water/noise/slice-thickness tables, manufacturer Daily inline single-system HU tables and bounded Monthly alignment tables. Explicit current HU values and printed bounds are kept separate from parenthesized references, scan parameters, other tables and clinical approval. Unknown, incomplete, conflicting, ambiguous and clipped evidence remains marked for review.'}
if($OutputPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($report|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding $true))}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
if($failed){exit 1}
exit 0
