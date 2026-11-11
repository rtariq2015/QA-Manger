[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$FixtureRoot,[string]$ProductRoot='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if(-not $ProductRoot){$ProductRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
& (Join-Path $PSScriptRoot 'New-WebFixture.ps1') -FixtureRoot $FixtureRoot -ProductRoot $ProductRoot
Import-Module (Join-Path $FixtureRoot 'App/Archive.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
$cfg=Read-QaConfig $FixtureRoot
$cfg.LookbackDays=730;$cfg.MonthlyLookbackMonths=36
$cfg|Add-Member PDFReaderMode 'Auto' -Force
$lines=@(
    @('SOMATOM Definition Edge','Quality IEC Constancy','SYNTHETIC TEST DOCUMENT - NO CLINICAL EVIDENCE','Handed over: 2014-03-15','Last reference measurement: 2020-02-12'),
    @('SOMATOM Definition Edge','Quality IEC Constancy','Synthetic table of contents','1. Homogeneity / Water','2. Noise'),
    @('SOMATOM Definition Edge','Quality IEC Constancy','1. Quality IEC Constancy Homogeneity / Water','Test: Typical body mode','Water Value Results for System A','Slice 1','Tolerance','-0.75 HU (-0.60)','-4.00 ... 3.40 HU','OK','2. Quality IEC Constancy Noise','Test: Typical head mode','Result','Results for System A','Slice 1','Tolerance','3.50 HU (3.40)','3.00 ... 4.00 HU','OK')
)
$objects=New-Object 'Collections.Generic.List[string]'
[void]$objects.Add('<< /Type /Catalog /Pages 2 0 R >>')
[void]$objects.Add('<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 >>')
[void]$objects.Add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
for($p=1;$p -le 3;$p++){
    [void]$objects.Add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents '+(5+2*($p-1))+' 0 R >>')
    $stream=New-Object Text.StringBuilder
    [void]$stream.Append('BT /F1 9 Tf 42 35 Td (2025-02-03 08:00:00 Page: '+$p+" / 3) Tj ET`n")
    $y=745
    foreach($line in $lines[$p-1]){
        $escaped=$line.Replace('\','\\').Replace('(','\(').Replace(')','\)')
        [void]$stream.Append('BT /F1 10 Tf 42 '+$y+' Td ('+$escaped+") Tj ET`n")
        $y-=24
    }
    [void]$objects.Add('<< /Length '+[Text.Encoding]::ASCII.GetByteCount($stream.ToString())+" >>`nstream`n"+$stream.ToString()+'endstream')
}
$pdf=New-Object Text.StringBuilder
[void]$pdf.Append("%PDF-1.4`n")
$offsets=New-Object 'Collections.Generic.List[int]'
for($i=0;$i -lt $objects.Count;$i++){
    [void]$offsets.Add([Text.Encoding]::ASCII.GetByteCount($pdf.ToString()))
    [void]$pdf.Append(($i+1).ToString()+" 0 obj`n"+$objects[$i]+"`nendobj`n")
}
$xref=[Text.Encoding]::ASCII.GetByteCount($pdf.ToString())
[void]$pdf.Append("xref`n0 "+($objects.Count+1)+"`n0000000000 65535 f `n")
foreach($offset in $offsets){[void]$pdf.Append($offset.ToString('0000000000')+" 00000 n `n")}
[void]$pdf.Append("trailer`n<< /Size "+($objects.Count+1)+" /Root 1 0 R >>`nstartxref`n"+$xref+"`n%%EOF`n")
$name='Unlabelled_Measurements.pdf'
$source=Join-Path $cfg.Sources[0].Path $name
[IO.File]::WriteAllText($source,$pdf.ToString(),[Text.Encoding]::ASCII)
(Get-Item -LiteralPath $source).LastWriteTimeUtc=[datetime]::UtcNow.AddMinutes(-10)
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'Config/Settings.local.json'),($cfg|ConvertTo-Json -Depth 18),(New-Object Text.UTF8Encoding $true))
[void](Invoke-QaOperation $cfg -Mode Update)
$dashboard=Get-QaDashboard $cfg
$selected=@($dashboard.Records|Where-Object OriginalFileName -eq $name)[0]
$preserved=@($dashboard.Records|ForEach-Object{[pscustomobject]@{source=$_.SourcePath;destination=$_.DestinationPath;hash=$_.Hash}})
$metadata=[pscustomobject]@{
    Synthetic=$true
    RecordCount=@($dashboard.Records).Count
    ArchiveRoot=$cfg.ArchiveRoot
    StateSHA256=(Get-FileHash (Join-Path $cfg.ArchiveRoot '.ctqa/state.json')).Hash
    RecordId=$selected.Id
    Source=$selected.SourcePath
    Destination=$selected.DestinationPath
    SourceHash=$selected.Hash
    ExpectedMeasurements=2
    Preserved=$preserved
}
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'python-fixture-baseline.json'),($metadata|ConvertTo-Json -Depth 18),(New-Object Text.UTF8Encoding $true))
Write-Output 'Created a synthetic three-page Siemens Basic document with printed Water/Noise values and limits.'
