# Reproducible selected-PDF lookup benchmark. Uses generated metadata and one
# verified synthetic PDF; no scanner network access or private reports are used.
[CmdletBinding()]param([string]$ProductRoot='',[Parameter(Mandatory=$true)][string]$OutputPath,[ValidateRange(1,20000)][int[]]$RecordCounts=@(1367,20000),[ValidateRange(1,10)][int]$Iterations=3)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if(-not $ProductRoot){$ProductRoot=Split-Path -Parent $PSScriptRoot}
Import-Module (Join-Path $ProductRoot 'App/WebService.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
Import-Module (Join-Path $ProductRoot 'App/Archive.psm1') -DisableNameChecking -WarningAction SilentlyContinue
$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_SelectedLookup_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($TestRoot)
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $ProductRoot 'Tests/Run-Tests.ps1'),[ref]$null,[ref]$null)
foreach($name in @('New-TestConfig','New-TestPdf','Add-Report','Import-Fixture')){$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);. ([scriptblock]::Create($fn.Extent.Text))}
$results=New-Object 'Collections.Generic.List[object]'
try{
 foreach($count in $RecordCounts){
  $cfg=New-TestConfig ('Records'+$count);$cfg.LookbackDays=3;$cfg.MonthlyLookbackMonths=2
  foreach($source in $cfg.Sources){$source.DailySchedule='Off';$source.ExpectedMonthly=$false}
  [void][IO.Directory]::CreateDirectory((Join-Path $cfg.AppRoot 'Config'));[IO.File]::WriteAllText((Join-Path $cfg.AppRoot 'Config/Settings.json'),($cfg|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true));[void](Save-QaConfig $cfg.AppRoot $cfg)
  $src=Add-Report $cfg 'CT_Edge' 'Quality_Daily' (Get-Date).ToString('yyyy-MM-dd') '07-00-00';[void](Import-Fixture $cfg)
  $statePath=Join-Path $cfg.ArchiveRoot '.ctqa/state.json';$state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json;$selected=$state.Records[0];$rows=New-Object 'Collections.Generic.List[object]';[void]$rows.Add($selected)
  for($i=1;$i -lt $count;$i++){
   $r=$selected|Select-Object *;$r.Id=$i.ToString('X64');if($r.Id -ceq $selected.Id){throw 'Synthetic identity collision.'};$r.RelativePath='Synthetic/'+$i.ToString('D5')+'.pdf';$r.SourcePath=Join-Path $cfg.Sources[0].Path ('Synthetic-'+$i.ToString('D5')+'.pdf');$r.OriginalFileName='Synthetic-'+$i.ToString('D5')+'.pdf';[void]$rows.Add($r)
  }
  $state.Records=@($rows.ToArray());[IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 20 -Compress),(New-Object Text.UTF8Encoding $true));$before=(Get-FileHash $statePath).Hash;$sourceHash=(Get-FileHash $src).Hash;$pdfHash=(Get-FileHash $selected.DestinationPath).Hash
  # A large synthetic metadata library and one real verified PDF. Unselected
  # indexed PDF paths deliberately need not exist for read-only state validation.
  $request=[pscustomobject]@{action='Pdf';id=[string]$selected.Id};$warmup=Invoke-QaWebRequest $cfg.AppRoot $request
  if($warmup.path -cne $selected.DestinationPath){throw 'Selected PDF did not resolve.'}
  $times=New-Object 'Collections.Generic.List[double]'
  for($iteration=0;$iteration -lt $Iterations;$iteration++){$clock=[Diagnostics.Stopwatch]::StartNew();$value=Invoke-QaWebRequest $cfg.AppRoot $request;$clock.Stop();if($value.path -cne $selected.DestinationPath){throw 'Selected PDF did not resolve.'};[void]$times.Add([math]::Round($clock.Elapsed.TotalMilliseconds,3))}
  if((Get-FileHash $statePath).Hash -cne $before -or (Get-FileHash $src).Hash -cne $sourceHash -or (Get-FileHash $selected.DestinationPath).Hash -cne $pdfHash){throw 'Read-only benchmark modified protected data.'}
  $sorted=@($times.ToArray()|Sort-Object);$median=$sorted[[int][math]::Floor($sorted.Count/2)];[void]$results.Add([pscustomobject]@{records=$count;samplesMs=@($times.ToArray());medianMs=$median;protectedBytesUnchanged=$true});Write-Host ('Measured '+$count+' records: '+$median+' ms')
 }
 $report=[pscustomobject]@{syntheticOnly=$true;scope='Actual Invoke-QaWebRequest Pdf resolves one real verified synthetic PDF in a synthetic metadata index. Same-process warm-up then measured iterations; no native rendering, PDF extraction, whole-library physical I/O or hospital throughput claim.';platform=[Environment]::OSVersion.Platform.ToString();powershell=$PSVersionTable.PSVersion.ToString();iterations=$Iterations;results=@($results.ToArray());passed=$true}
 [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($report|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding $false))
}finally{Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue}
