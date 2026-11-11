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

$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Product='CT QA Manager Pro';Feature='Printed measurement extraction';MeasurementVersion=1;Runtime=$PSVersionTable.PSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5 -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT);SyntheticOnly=$true;Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Synthetic IEC single-metric water/noise tables only. Explicit current HU values and printed bounds are kept separate from parenthesized references, scan parameters, other tables and clinical approval. Unknown, incomplete, conflicting, ambiguous and clipped evidence remains marked for review.'}
if($OutputPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($report|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding $true))}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
if($failed){exit 1}
exit 0
