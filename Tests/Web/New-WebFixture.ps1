[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$FixtureRoot,[string]$ProductRoot='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if(-not $ProductRoot){$ProductRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
$ProductRoot=[IO.Path]::GetFullPath($ProductRoot);$FixtureRoot=[IO.Path]::GetFullPath($FixtureRoot)
if([IO.Directory]::Exists($FixtureRoot)){throw 'Choose a new folder for the synthetic web fixture.'}
[void][IO.Directory]::CreateDirectory($FixtureRoot)
Copy-Item -LiteralPath (Join-Path $ProductRoot 'App') -Destination (Join-Path $FixtureRoot 'App') -Recurse
[void][IO.Directory]::CreateDirectory((Join-Path $FixtureRoot 'Config'))
Copy-Item -LiteralPath (Join-Path $ProductRoot 'Config/Settings.json') -Destination (Join-Path $FixtureRoot 'Config/Settings.json')
Copy-Item -LiteralPath (Join-Path $ProductRoot 'Start CT QA Manager.cmd') -Destination (Join-Path $FixtureRoot 'Start CT QA Manager.cmd')
Import-Module (Join-Path $FixtureRoot 'App/Archive.psm1') -Force -WarningAction SilentlyContinue
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $ProductRoot 'Tests/Run-Tests.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('New-TestPdf','Add-Report','Import-Fixture')){$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true);. ([scriptblock]::Create($definition.Extent.Text))}
function New-WebDemoPdf([string]$Path,[string]$Scanner,[string]$Kind,[int]$Size=5000){
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $builder=New-Object Text.StringBuilder;[void]$builder.Append("%PDF-1.4`n")
    $offsets=New-Object 'System.Collections.Generic.List[int]'
    $objects=@('<< /Type /Catalog /Pages 2 0 R >>','<< /Type /Pages /Kids [3 0 R] /Count 1 >>','<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>','<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    $stream="0.05 0.20 0.27 rg 0 660 612 132 re f`n0.47 0.88 0.79 rg BT /F1 10 Tf 42 750 Td (CT QA / SYNTHETIC DEMONSTRATION) Tj ET`n1 1 1 rg BT /F1 26 Tf 42 708 Td ($Kind report) Tj ET`n0.08 0.18 0.24 rg BT /F1 14 Tf 42 619 Td ($Scanner) Tj ET`n0.35 0.45 0.50 rg BT /F1 11 Tf 42 594 Td (Generated test document - not clinical evidence) Tj ET`n0.80 0.87 0.89 RG 42 565 m 570 565 l S`n0.08 0.18 0.24 rg BT /F1 12 Tf 42 531 Td (Report contents) Tj ET`n0.35 0.45 0.50 rg BT /F1 11 Tf 42 501 Td (This PDF exercises the local report viewer and file organization.) Tj ET`nBT /F1 11 Tf 42 477 Td (Its content is entirely synthetic. No patient or scanner data is used.) Tj ET`n0.93 0.97 0.96 rg 42 348 528 89 re f`n0.05 0.40 0.34 rg BT /F1 12 Tf 57 409 Td (Document type and clinical evidence are separate.) Tj ET`n0.35 0.45 0.50 rg BT /F1 10 Tf 57 384 Td (Approving this label does not establish a clinical PASS or checklist.) Tj ET`n0.80 0.87 0.89 RG 42 79 m 570 79 l S`n0.35 0.45 0.50 rg BT /F1 9 Tf 42 56 Td (SYNTHETIC QA TEST FIXTURE / PAGE 1 OF 1) Tj ET`n"
    $objects+=('<< /Length '+[Text.Encoding]::ASCII.GetByteCount($stream)+" >>`nstream`n"+$stream+'endstream')
    for($i=0;$i -lt $objects.Count;$i++){$offsets.Add([Text.Encoding]::ASCII.GetByteCount($builder.ToString()));[void]$builder.Append(($i+1).ToString()+" 0 obj`n"+$objects[$i]+"`nendobj`n")}
    $padding=[math]::Max(0,$Size-$builder.Length-300);if($padding -gt 0){[void]$builder.Append('%'+('x'*$padding)+"`n")}
    $xref=[Text.Encoding]::ASCII.GetByteCount($builder.ToString());[void]$builder.Append("xref`n0 6`n0000000000 65535 f `n")
    foreach($offset in $offsets){[void]$builder.Append($offset.ToString('0000000000')+" 00000 n `n")}
    [void]$builder.Append("trailer`n<< /Size 6 /Root 1 0 R >>`nstartxref`n"+$xref+"`n%%EOF`n")
    [IO.File]::WriteAllText($Path,$builder.ToString(),[Text.Encoding]::ASCII);(Get-Item $Path).LastWriteTimeUtc=[datetime]::UtcNow.AddMinutes(-10)
    return $Path
}
$cfg=Get-QaDefaultConfig -AppRoot $FixtureRoot;$cfg.ArchiveRoot=Join-Path $FixtureRoot 'Data';$cfg.MinimumFileAgeSeconds=0;$cfg.LookbackDays=7;$cfg.MonthlyLookbackMonths=2;$cfg|Add-Member MonitorMinutes 0 -Force;$cfg|Add-Member AutoAnalyze $false -Force;$cfg.AutoUpdateOnOpen=$false
foreach($source in $cfg.Sources){$source.Path=Join-Path (Join-Path $FixtureRoot 'Synthetic Scanners') $source.Scanner;[void][IO.Directory]::CreateDirectory($source.Path);$source.Name='Synthetic '+$source.Name;$source.ActiveFrom=(Get-Date).Date.AddDays(-2).ToString('yyyy-MM-dd');$source.MonthlyChecklist=@('MTF','Slice thickness');$source|Add-Member MonthlyDueDay 25 -Force;$source.Username='SyntheticScannerUser'}
$today=(Get-Date).ToString('yyyy-MM-dd');$yesterday=(Get-Date).AddDays(-1).ToString('yyyy-MM-dd');$previous=(Get-Date).AddMonths(-1).ToString('yyyy-MM')+'-15'
$sourceFiles=New-Object 'System.Collections.Generic.List[string]'
[void]$sourceFiles.Add((New-WebDemoPdf (Join-Path $cfg.Sources[0].Path ('QualityDaily_'+$today+'_07-15-00.pdf')) 'Synthetic CT Edge' 'Daily QA'))
[void]$sourceFiles.Add((New-WebDemoPdf (Join-Path $cfg.Sources[1].Path ('QualityDaily_'+$today+'_07-30-00.pdf')) 'Synthetic CT Flash' 'Daily QA'))
[void]$sourceFiles.Add((New-WebDemoPdf (Join-Path $cfg.Sources[2].Path ('QualityDaily_'+$yesterday+'_07-20-00.pdf')) 'Synthetic MDP Building' 'Daily QA'))
[void]$sourceFiles.Add((New-WebDemoPdf (Join-Path $cfg.Sources[0].Path ('Monthly_Constancy_'+$today+'_08-00-00.pdf')) 'Synthetic CT Edge' 'Monthly QA' 95000))
[void]$sourceFiles.Add((New-WebDemoPdf (Join-Path $cfg.Sources[1].Path ('Monthly_Constancy_'+$today+'_08-05-00.pdf')) 'Synthetic CT Flash' 'Monthly QA' 96000))
[void]$sourceFiles.Add((New-WebDemoPdf (Join-Path $cfg.Sources[0].Path ('Monthly_Constancy_'+$previous+'_08-10-00.pdf')) 'Synthetic CT Edge' 'Monthly QA' 97000))
[void](Import-Fixture $cfg)
$legacy=@((Get-QaDashboard $cfg).Records|Where-Object ReportDate -eq $previous)[0]
[void](Invoke-QaOperation $cfg -Mode Reclassify -Decisions @([pscustomobject]@{RecordId=$legacy.Id;Hash=$legacy.Hash;Category='Monthly_QA';Reviewer='Synthetic evidence reviewer';Reason='Synthetic legacy evidence preservation fixture';ConfirmedComponents=@('MTF')}))
$cfg.SetupComplete=$true
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'Config/Settings.local.json'),($cfg|ConvertTo-Json -Depth 18),(New-Object Text.UTF8Encoding $true))
$dashboard=Get-QaDashboard $cfg
$rows=@($dashboard.Records|ForEach-Object{[pscustomobject]@{Id=$_.Id;Hash=$_.Hash;Category=$_.Category;ConfirmedBy=$_.ConfirmedBy;ConfirmedAt=$_.ConfirmedAt;ConfirmedComponents=@($_.ConfirmedComponents);DestinationPath=$_.DestinationPath}})
$sources=@($sourceFiles|ForEach-Object{[pscustomobject]@{Path=$_;Hash=(Get-FileHash $_ -Algorithm SHA256).Hash}})
$metadata=[pscustomobject]@{Synthetic=$true;FixtureRoot=$FixtureRoot;ArchiveRoot=$cfg.ArchiveRoot;RecordCount=$rows.Count;Records=$rows;Sources=$sources;Month=(Get-Date).ToString('yyyy-MM')}
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'fixture-baseline.json'),($metadata|ConvertTo-Json -Depth 18),(New-Object Text.UTF8Encoding $true))
Write-Output ('Created synthetic browser fixture with '+$rows.Count+' PDFs; real scanner data and credentials are absent.')
