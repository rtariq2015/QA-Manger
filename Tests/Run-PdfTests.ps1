[CmdletBinding()]
param([string]$OutputPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProductRoot 'App/Archive.psm1') -Force
Import-Module (Join-Path $ProductRoot 'App/Reports.psm1') -Force
Import-Module (Join-Path $ProductRoot 'App/PdfReader.psm1') -Force
$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_PdfTests_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestRoot)
$tokens=$null;$errors=$null
$testAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Run-Tests.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('New-TestConfig','New-TestPdf','Add-Report','Import-Fixture')) {
 $fn=$testAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression $fn.Extent.Text
}
$script:Results=New-Object 'System.Collections.Generic.List[object]';$script:Assertions=0
function Check([bool]$Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS '+$Name)}catch{[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=$_.Exception.Message+' '+$_.ScriptStackTrace});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
function Fixture([string]$Name,[string]$Pdf='Compressed-Text.pdf') {
 $cfg=New-TestConfig $Name
 $path=Join-Path $cfg.Sources[0].Path 'Quality_Constancy_2025-12-01_06-00-00.pdf'
 [IO.File]::Copy((Join-Path (Join-Path $PSScriptRoot 'Fixtures/PdfReader') $Pdf),$path,$false)
 (Get-Item -LiteralPath $path).LastWriteTimeUtc=[datetime]::UtcNow.AddMinutes(-10)
 [void](Import-Fixture $cfg)
 $row=@((Get-QaDashboard -Config $cfg).Records)[0]
 return [pscustomobject]@{Config=$cfg;Record=$row;Source=$path}
}
Scenario 'Compressed multi-page PDF text is read locally without changing classification or bytes' {
 $fx=Fixture 'Compressed'
 $state=Join-Path $fx.Config.ArchiveRoot '.ctqa/state.json';$stateHash=(Get-FileHash -LiteralPath $state).Hash
 $srcHash=(Get-FileHash -LiteralPath $fx.Source).Hash;$savedHash=(Get-FileHash -LiteralPath $fx.Record.DestinationPath).Hash
 $result=Read-QaReportText -Config $fx.Config -RecordId $fx.Record.Id
 Check ($result.Pages -eq 3 -and $result.ReadPages -eq 3) 'All3 pages extracted'
 Check ($result.Text -match 'SYNTHETIC QA FIXTURE - Page 1' -and $result.Text -match 'SYNTHETIC QA FIXTURE - Page 3') 'First and final page text present'
 Check ($result.Indicators -contains 'Modulation transfer function (MTF)') 'MTF readable content found through compression'
 Check ($result.Indicators -contains 'Slice thickness') 'Slice thickness content found'
 Check (-not $result.Truncated -and -not $result.NeedsOCR) 'Complete text document accurately identified'
 Check ((Get-FileHash -LiteralPath $state).Hash -eq $stateHash) 'Archive state unchanged'
 Check ((Get-FileHash -LiteralPath $fx.Source).Hash -eq $srcHash) 'Scanner-source fixture untouched'
 Check ((Get-FileHash -LiteralPath $fx.Record.DestinationPath).Hash -eq $savedHash) 'Archived PDF untouched'
 Check (@((Get-QaDashboard -Config $fx.Config).Records)[0].Category -eq $fx.Record.Category) 'Text never auto-confirms or changes QA category'
}
Scenario 'Image-only PDF reports no readable text and does not invent a report type' {
 $fx=Fixture 'ImageOnly' 'Image-Only.pdf';$r=Read-QaReportText -Config $fx.Config -RecordId $fx.Record.Id
 Check $r.NeedsOCR 'No selectable text detected'
 Check ($r.Indicators.Count -eq 0) 'No test labels invented from image'
 Check ($r.Message -match 'OCR is not included') 'Limitation explained'
}
Scenario 'Encrypted PDF fails clearly and releases the archive lock' {
 $fx=Fixture 'Encrypted' 'Encrypted.pdf';$failed=$false
 try{[void](Read-QaReportText -Config $fx.Config -RecordId $fx.Record.Id)}catch{$failed=$_.Exception.Message -match '(encrypted|could not be read)'}
 Check $failed 'Encrypted document gives readable failure'
 $lock=[IO.File]::Open((Join-Path $fx.Config.ArchiveRoot '.ctqa/archive.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$lock.Dispose()
 Check $true 'Reader failure released lock'
}
Scenario 'Page and character limits explicitly identify incomplete text' {
 $fx=Fixture 'Limits';$r=Read-QaReportText -Config $fx.Config -RecordId $fx.Record.Id -MaximumPages 1
 Check ($r.Truncated -and $r.ReadPages -eq 1 -and $r.Pages -eq 3) 'Page limit identified accurately'
 Check ($r.Message -match 'incomplete') 'Partial content not presented as complete'
 $r=Read-QaReportText -Config $fx.Config -RecordId $fx.Record.Id -MaximumCharacters 500
 Check ($r.Truncated -and $r.Text.Length -le 500) 'Character limit enforced'
}
Scenario 'Oversized PDF is rejected before parsing and without changes' {
 $fx=Fixture 'Bytes';$before=(Get-FileHash -LiteralPath $fx.Record.DestinationPath).Hash;$rejected=$false
 try{[void](Read-QaReportText -Config $fx.Config -RecordId $fx.Record.Id -MaximumBytes 1024)}catch{$rejected=$_.Exception.Message -match 'size limit'}
 Check $rejected 'File size safety limit enforced'
 Check ((Get-FileHash -LiteralPath $fx.Record.DestinationPath).Hash -eq $before) 'Oversized archived file untouched'
}
Scenario 'Damaged saved PDF cannot be read as a verified report' {
 $fx=Fixture 'Corrupt';$b=[IO.File]::ReadAllBytes($fx.Record.DestinationPath);$b[100]=$b[100] -bxor 1;[IO.File]::WriteAllBytes($fx.Record.DestinationPath,$b);$rejected=$false
 try{[void](Read-QaReportText -Config $fx.Config -RecordId $fx.Record.Id)}catch{$rejected=$_.Exception.Message -match 'SHA-256'}
 Check $rejected 'Indexed hash is mandatory before text parsing'
}
Scenario 'Reader works offline using archive only and refuses an active writer' {
 $fx=Fixture 'Offline';foreach($s in $fx.Config.Sources){$s.Path=Join-Path $TestRoot ('Missing_'+$s.Scanner)}
 $r=Read-QaReportText -Config $fx.Config -RecordId $fx.Record.Id;Check ($r.ReadPages -eq 3) 'Scanner folders not needed'
 $lock=[IO.File]::Open((Join-Path $fx.Config.ArchiveRoot '.ctqa/archive.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{$rejected=$false;try{[void](Read-QaReportText -Config $fx.Config -RecordId $fx.Record.Id)}catch{$rejected=$_.Exception.Message -match 'Wait for'};Check $rejected 'Concurrent archive operation protected'}finally{$lock.Dispose()}
}
Scenario 'Cancelled reading and unknown report selections have no side effects' {
 $fx=Fixture 'Cancel';$state=Join-Path $fx.Config.ArchiveRoot '.ctqa/state.json';$before=(Get-FileHash -LiteralPath $state).Hash
 $r=Read-QaReportText -Config $fx.Config -RecordId $fx.Record.Id -Progress ([hashtable]::Synchronized(@{Cancel=$true;Message='';Percent=0}))
 Check ($r.Summary.Cancelled -and $r.Text -eq '') 'Cancellation returns no invented text'
 Check ((Get-FileHash -LiteralPath $state).Hash -eq $before) 'Cancellation leaves metadata unchanged'
 $rejected=$false;try{[void](Read-QaReportText -Config $fx.Config -RecordId ('A'*64))}catch{$rejected=$_.Exception.Message -match 'uniquely'};Check $rejected 'Unknown identity refused'
}
$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$r=[pscustomobject]@{Product='CT QA Manager Pro';Feature='Portable PDF text reader';TimestampUtc=[datetime]::UtcNow.ToString('o');Runtime=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5);Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Notes='Synthetic compressed, image-only and encrypted PDFs only. Native Windows .NET Framework/PdfPig loading and hospital PDFs still require Windows validation.'}
if($OutputPath){$r|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
Write-Host ('Result: '+($r.Tests-$failed)+'/'+$r.Tests+' scenarios, '+$r.Assertions+' assertions')
Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
if($failed){exit 1}
