[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$FixtureRoot,[string]$OutputPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$baseline=[IO.File]::ReadAllText((Join-Path $FixtureRoot 'large-fixture-baseline.json'))|ConvertFrom-Json
if(-not $baseline.Synthetic){throw 'Only the synthetic large-library fixture may be tested.'}
$ProductRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ProductRoot 'App/WebService.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
Import-Module (Join-Path $ProductRoot 'App/Archive.psm1') -DisableNameChecking -WarningAction SilentlyContinue
$cfg=Read-QaConfig $FixtureRoot;$module=Get-Module WebService
$script:Results=New-Object 'Collections.Generic.List[object]';$script:Assertions=0;$script:Measurements=[ordered]@{}
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{name=$Name;result='PASS'});Write-Host ('PASS '+$Name)}catch{[void]$script:Results.Add([pscustomobject]@{name=$Name;result='FAIL';details=($_.Exception.Message+' / '+$_.ScriptStackTrace)});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
function Library($Progress=$null,[switch]$Verify){&$module {param($c,$p,$v) Update-QaWebLibrary $c -Progress $p -Verify:$v} $cfg $Progress ([bool]$Verify)}
$snapshot=$null;$cold=$null
Scenario 'A realistic 1,367-report archive resolves known documents while retaining uncertain candidates and prior decisions' {
    $clock=[Diagnostics.Stopwatch]::StartNew();$script:snapshot=Get-QaWebSnapshot $cfg;$clock.Stop();$script:Measurements.snapshotMs=$clock.ElapsedMilliseconds
    Check ($snapshot.records.Count -eq 1367) 'All independently indexed PDF sessions are retained'
    foreach($decision in @('Automatic','Pending','Approved','Disapproved')){Check (@($snapshot.records|Where-Object decision -eq $decision).Count -eq $baseline.ExpectedTotals.$decision) ('The '+$decision+' population is exact')}
    $index=@{};foreach($record in $snapshot.records){$index[$record.id]=$record}
    foreach($expected in $baseline.Expected){$record=$index[$expected.Id];Check ($record.decision -eq $expected.Decision -and $record.category -eq $expected.Category) ('Document classification remains correct for '+$expected.Kind);Check ($record.pending -eq ($expected.Decision -eq 'Pending')) 'Pending status follows the actual need for a decision';Check (($record.clinicalComponents -join '|') -eq ($expected.ConfirmedComponents -join '|')) 'Classification neither creates nor deletes clinical checklist evidence';Check ($record.printedResult -eq 'Not inferred from file classification') 'Document organization never fabricates a printed clinical PASS'}
    Check ((Get-FileHash (Join-Path $cfg.ArchiveRoot '.ctqa/state.json')).Hash -eq $baseline.CoreStateSHA256) 'Reading and automatic organization do not rewrite authoritative clinical records'
    Check ((Get-FileHash (Join-Path $cfg.ArchiveRoot '.ctqa/organization.json')).Hash -eq $baseline.OrganizationSHA256) 'Saved Approve and Disapprove history is unchanged'
}
Scenario 'A cold readable-library batch writes one ownership ledger for all 1,367 verified PDFs' {
    $clock=[Diagnostics.Stopwatch]::StartNew();$script:cold=Library;$clock.Stop();$script:Measurements.coldMs=$clock.ElapsedMilliseconds;$script:Measurements.cold=$cold
    Check ($cold.copied -eq 1367 -and $cold.failed -eq 0) 'Every real source PDF receives a readable local copy'
    Check ($cold.manifestWrites -eq 1) 'Ownership is committed once for the entire batch, rather than once per PDF'
    Check ($cold.hashedFiles -eq 2734) 'Each new copy is verified by source stream SHA-256 and staged readback'
    Check (@(Get-ChildItem -LiteralPath $cold.libraryRoot -Recurse -Filter '*.pdf').Count -eq 1367) 'Readable-library files cover the complete archive'
}
Scenario 'An unchanged warm library uses metadata without rereading every PDF hash or rewriting its full ledger' {
    $manifest=Join-Path $cfg.ArchiveRoot '.ctqa/web-library.json';$hash=(Get-FileHash $manifest).Hash;$ticks=(Get-Item $manifest).LastWriteTimeUtc.Ticks
    $clock=[Diagnostics.Stopwatch]::StartNew();$warm=Library;$clock.Stop();$script:Measurements.warmMs=$clock.ElapsedMilliseconds;$script:Measurements.warm=$warm
    Check ($warm.unchanged -eq 1367 -and $warm.copied -eq 0) 'All unchanged files are reused without duplicate copies'
    Check ($warm.hashedFiles -eq 0) 'Normal warm refresh performs zero source or target PDF hash reads'
    Check ($warm.manifestWrites -eq 0) 'Normal warm refresh performs zero ownership ledger writes'
    Check ((Get-FileHash $manifest).Hash -eq $hash -and (Get-Item $manifest).LastWriteTimeUtc.Ticks -eq $ticks) 'The ledger bytes and write timestamp remain unchanged'
}
Scenario 'An explicit integrity audit bypasses the fast cache and detects edits even with restored size and timestamp' {
    $manifest=[IO.File]::ReadAllText((Join-Path $cfg.ArchiveRoot '.ctqa/web-library.json'))|ConvertFrom-Json
    $owned=$manifest.Records[0];$target=Join-Path $cfg.ArchiveRoot ('Report Library/'+$owned.relative);$bytes=[IO.File]::ReadAllBytes($target);$ticks=(Get-Item $target).LastWriteTimeUtc
    try{$changed=[byte[]]$bytes.Clone();$changed[30]=$changed[30] -bxor 1;[IO.File]::WriteAllBytes($target,$changed);(Get-Item $target).LastWriteTimeUtc=$ticks
        $caught=$false;try{Library -Verify|Out-Null}catch{$caught=$_.Exception.Message -like '*readable PDF was edited*'}
        Check $caught 'An explicit audit detects a same-length, same-mtime modification'
        Check ((Get-FileHash $target).Hash -ne $owned.hash) 'The modified readable PDF is preserved rather than overwritten'
    }finally{[IO.File]::WriteAllBytes($target,$bytes);(Get-Item $target).LastWriteTimeUtc=$ticks}
    Check ((Get-FileHash (Join-Path $cfg.ArchiveRoot '.ctqa/state.json')).Hash -eq $baseline.CoreStateSHA256) 'Cache and audit leave original clinical state unchanged'
    Check ((Get-FileHash (Join-Path $cfg.ArchiveRoot '.ctqa/organization.json')).Hash -eq $baseline.OrganizationSHA256) 'Saved file decisions and audit history stay unchanged'
}
$failed=@($script:Results|Where-Object result -eq 'FAIL').Count
$summary=[pscustomobject]@{version='5.1.0';syntheticOnly=$true;records=1367;tests=$script:Results.Count;assertions=$script:Assertions;failed=$failed;measurements=$script:Measurements;results=@($script:Results.ToArray());scope='Actual PowerShell adapter and 1,367 synthetic source/archive PDFs. Durations are diagnostic; cache correctness uses hash-read and ledger-write counters, not hardware-dependent time thresholds.'}
if($OutputPath){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath)));[IO.File]::WriteAllText($OutputPath,($summary|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $false))}
Write-Host ('Result: '+($summary.tests-$failed)+'/'+$summary.tests+' scenarios; '+$summary.assertions+' assertions.')
if($failed){exit 1}
