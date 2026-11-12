[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$FixtureRoot,[string]$ProductRoot='',[switch]$IncludeFlash)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if(-not $ProductRoot){$ProductRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
& (Join-Path $PSScriptRoot 'New-WebFixture.ps1') -FixtureRoot $FixtureRoot -ProductRoot $ProductRoot
Import-Module (Join-Path $FixtureRoot 'App/Archive.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
$cfg=Read-QaConfig $FixtureRoot
# Historical generated PDFs are part of this scanner's active test period.
foreach($source in $cfg.Sources){$source.ActiveFrom='2025-01-01'}
function ConvertTo-ContentPdfString([string]$Value){return $Value.Replace('\','\\').Replace('(','\(').Replace(')','\)')}
function New-ContentPdf {
    param([string]$Path,[string]$Profile,[int]$Pages,[string]$Date='2025-02-03',[string]$Time='08:00:00',[switch]$Conflict,[switch]$MissingFooter,[ValidateSet('Edge','Flash')][string]$Model='Edge')
    $names=if($Profile -eq 'Basic'){@('Homogeneity / Water','Noise')}else{@('Lightmarker','External Lightm.','Sag./Cor. Lightm.','Topogram Pos.','Slice','Homogeneity / Water','Noise','MTF','Contrast','Table Position')}
    $objects=New-Object 'Collections.Generic.List[string]'
    [void]$objects.Add('<< /Type /Catalog /Pages 2 0 R >>')
    $kids=@(for($p=0;$p -lt $Pages;$p++){(4+2*$p).ToString()+' 0 R'}) -join ' '
    [void]$objects.Add('<< /Type /Pages /Kids ['+$kids+'] /Count '+$Pages+' >>')
    [void]$objects.Add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    for($p=1;$p -le $Pages;$p++){
        [void]$objects.Add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents '+(5+2*($p-1))+' 0 R >>')
        $stream=New-Object Text.StringBuilder
        # Put the footer first in content order. Real extraction must not depend
        # on the footer being the final text line on a page.
        if(-not $MissingFooter){$footerDate=if($Conflict -and $p -eq $Pages){'2025-02-04'}else{$Date};[void]$stream.Append('BT /F1 9 Tf 42 35 Td ('+$footerDate+' '+$Time+' Page: '+$p+' / '+$Pages+") Tj ET`n")}
        $lines=New-Object 'Collections.Generic.List[string]'
        [void]$lines.Add(('SOMATOM Definition '+$Model));[void]$lines.Add('Quality IEC Constancy');[void]$lines.Add('SYNTHETIC TEST DOCUMENT - NO CLINICAL EVIDENCE')
        if($p -eq 2){[void]$lines.Add('Report index - body sections begin on the following pages.')}
        for($i=0;$i -lt $names.Count;$i++){
            $sectionPage=3+[math]::Floor($i*($Pages-2)/$names.Count)
            if($sectionPage -eq $p){[void]$lines.Add((($i+1).ToString()+'. Quality IEC Constancy '+$names[$i]));[void]$lines.Add('Status: OK');[void]$lines.Add('Synthetic measurement evidence only.')}
        }
        $y=745;foreach($line in $lines){[void]$stream.Append('BT /F1 10 Tf 42 '+$y+' Td ('+(ConvertTo-ContentPdfString $line)+") Tj ET`n");$y-=27}
        [void]$objects.Add('<< /Length '+[Text.Encoding]::ASCII.GetByteCount($stream.ToString())+" >>`nstream`n"+$stream.ToString()+'endstream')
    }
    $pdf=New-Object Text.StringBuilder;[void]$pdf.Append("%PDF-1.4`n");$offsets=New-Object 'Collections.Generic.List[int]'
    for($i=0;$i -lt $objects.Count;$i++){$offsets.Add([Text.Encoding]::ASCII.GetByteCount($pdf.ToString()));[void]$pdf.Append(($i+1).ToString()+" 0 obj`n"+$objects[$i]+"`nendobj`n")}
    $xref=[Text.Encoding]::ASCII.GetByteCount($pdf.ToString());[void]$pdf.Append("xref`n0 "+($objects.Count+1)+"`n0000000000 65535 f `n")
    foreach($offset in $offsets){[void]$pdf.Append($offset.ToString('0000000000')+" 00000 n `n")}
    [void]$pdf.Append("trailer`n<< /Size "+($objects.Count+1)+" /Root 1 0 R >>`nstartxref`n"+$xref+"`n%%EOF`n")
    [IO.File]::WriteAllText($Path,$pdf.ToString(),[Text.Encoding]::ASCII);(Get-Item -LiteralPath $Path).LastWriteTimeUtc=[datetime]::UtcNow.AddMinutes(-10)
}
$definitions=@(
    [pscustomobject]@{Key='basic';Scanner=0;Name='Unlabelled_Basic.pdf';Profile='Basic';Pages=9;Date='2025-02-03';Time='08:00:00';Conflict=$false;Missing=$false},
    [pscustomobject]@{Key='extended';Scanner=0;Name='Unlabelled_Extended.pdf';Profile='Extended';Pages=6;Date='2025-02-03';Time='09:00:00';Conflict=$false;Missing=$false},
    [pscustomobject]@{Key='footerConflict';Scanner=0;Name='Unlabelled_Conflicting_Footers.pdf';Profile='Basic';Pages=8;Date='2025-02-03';Time='10:00:00';Conflict=$true;Missing=$false},
    [pscustomobject]@{Key='filenameConflict';Scanner=0;Name='Unlabelled_2025-02-05_08-00-00.pdf';Profile='Basic';Pages=5;Date='2025-02-06';Time='08:00:00';Conflict=$false;Missing=$false},
    [pscustomobject]@{Key='filenameAgrees';Scanner=0;Name='Unlabelled_2025-02-03_08-00-00.pdf';Profile='Basic';Pages=7;Date='2025-02-03';Time='08:00:00';Conflict=$false;Missing=$false},
    [pscustomobject]@{Key='otherScanner';Scanner=1;Name='Unlabelled_Other_Scanner.pdf';Profile='Basic';Pages=4;Date='2025-02-03';Time='11:00:00';Conflict=$false;Missing=$false},
    [pscustomobject]@{Key='missingDate';Scanner=0;Name='Unlabelled_No_Footers.pdf';Profile='Extended';Pages=7;Date='2025-02-03';Time='12:00:00';Conflict=$false;Missing=$true}
)
if($IncludeFlash){
    $definitions+=@(
        [pscustomobject]@{Key='flashBasic';Scanner=1;Name='Unlabelled_Flash_Basic.pdf';Profile='Basic';Model='Flash';Pages=3;Date='2025-02-03';Time='13:00:00';Conflict=$false;Missing=$false},
        [pscustomobject]@{Key='flashExtended';Scanner=1;Name='Unlabelled_Flash_Extended.pdf';Profile='Extended';Model='Flash';Pages=6;Date='2025-02-03';Time='14:00:00';Conflict=$false;Missing=$false}
    )
}
foreach($d in $definitions){$path=Join-Path $cfg.Sources[$d.Scanner].Path $d.Name;$model=if($null -ne $d.PSObject.Properties['Model']){[string]$d.Model}else{'Edge'};New-ContentPdf $path $d.Profile $d.Pages $d.Date $d.Time -Conflict:$d.Conflict -MissingFooter:$d.Missing -Model $model}
# Historic dated names remain intentionally visible to this test import.
$cfg.LookbackDays=730;$cfg.MonthlyLookbackMonths=36
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'Config/Settings.local.json'),($cfg|ConvertTo-Json -Depth 18),(New-Object Text.UTF8Encoding $true))
[void](Invoke-QaOperation $cfg -Mode Update)
$dashboard=Get-QaDashboard $cfg;$rows=New-Object 'Collections.Generic.List[object]'
foreach($d in $definitions){$record=@($dashboard.Records|Where-Object OriginalFileName -eq $d.Name)[0];[void]$rows.Add([pscustomobject]@{key=$d.Key;id=$record.Id;hash=$record.Hash;scanner=$record.Scanner;source=$record.SourcePath;destination=$record.DestinationPath;rawDate=$record.ReportDate;rawCategory=$record.Category;pages=$d.Pages;profile=$d.Profile;expectedDate=$d.Date;expectedTime=$d.Time})}
$metadata=[pscustomobject]@{Synthetic=$true;IncludesFlash=[bool]$IncludeFlash;RecordCount=@($dashboard.Records).Count;ArchiveRoot=$cfg.ArchiveRoot;StateSHA256=(Get-FileHash (Join-Path $cfg.ArchiveRoot '.ctqa/state.json')).Hash;Records=@($rows.ToArray())}
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'content-fixture-baseline.json'),($metadata|ConvertTo-Json -Depth 18),(New-Object Text.UTF8Encoding $true))
Write-Output ('Created '+$rows.Count+' synthetic content PDFs with body headings and footers; no uploaded clinical PDF was copied.')
