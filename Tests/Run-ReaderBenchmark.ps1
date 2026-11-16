[CmdletBinding()]param([string]$OutputPath='',[ValidateRange(2,10)][int]$Repetitions=3,[string]$FixtureRoot='',[switch]$KeepFixtures)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'The reader comparison requires native Windows and the packaged Python runtime.'}
$ProductRoot=Split-Path -Parent $PSScriptRoot
if(-not $FixtureRoot){$FixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA Reader benchmark '+[guid]::NewGuid().ToString('N'))}
& (Join-Path $PSScriptRoot 'Web/New-ContentFixture.ps1') -FixtureRoot $FixtureRoot -ProductRoot $ProductRoot
Import-Module (Join-Path $FixtureRoot 'App/Archive.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
Import-Module (Join-Path $FixtureRoot 'App/Process.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
Import-Module (Join-Path $FixtureRoot 'App/ContentClassifier.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
$Config=Read-QaConfig $FixtureRoot;$Config|Add-Member PdfReaderMode 'Auto' -Force
$baseline=[IO.File]::ReadAllText((Join-Path $FixtureRoot 'content-fixture-baseline.json'))|ConvertFrom-Json
$selected=@($baseline.Records|Where-Object{$_.key -in @('basic','extended')})
$statePath=Join-Path $Config.ArchiveRoot '.ctqa/state.json';$stateHash=(Get-FileHash $statePath).Hash
$script:Results=New-Object 'Collections.Generic.List[object]';$script:Assertions=0;$script:Samples=New-Object 'Collections.Generic.List[object]';$script:CacheMetrics=$null
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw ('CHECK: '+$Message)}}
function Get-SafeTestFailure($Failure){
    # Public fixture diagnostics identify code and line only. Reader exception
    # messages, source paths and document data are deliberately excluded.
    $kind=[string]$Failure.Exception.GetType().Name
    if($kind -notmatch '^[A-Za-z0-9_]+$'){$kind='Exception'}
    $symbol=[string]$Failure.FullyQualifiedErrorId
    if($symbol -notmatch '^[A-Za-z0-9_.+,`-]{1,200}$'){$symbol='Unclassified'}
    $line=0;if($null -ne $Failure.InvocationInfo){$line=[math]::Max(0,[int]$Failure.InvocationInfo.ScriptLineNumber)}
    $detail=$kind+' [Code='+$symbol+'; TestLine='+$line+']'
    $stages=@('Availability','BundleCheck','JobType','StartInfo','Start','JobAttach','ReadPipes','WriteHeader','SendBody','Wait','CloseInput','ReadResponse','DecodeResponse','Schema','Fingerprint','TextSchema','Return')
    $diagnostics=New-Object 'Collections.Generic.List[string]';$current=$Failure.Exception
    for($depth=0;$depth -lt 8 -and $null -ne $current;$depth++){
        if($null -ne $current.Data){
            $stage=[string]$current.Data['PythonStage'];$cause=[string]$current.Data['PythonCauseCode']
            $values=New-Object 'Collections.Generic.List[string]'
            if($stages -ccontains $stage){[void]$values.Add('PythonStage='+$stage)}
            if($cause -cmatch '^[A-Za-z0-9_.+,`-]{1,200}$'){[void]$values.Add('PythonCause='+$cause)}
            $exit=[long]0
            if($current.Data.Contains('PythonExitCode') -and [long]::TryParse([string]$current.Data['PythonExitCode'],[ref]$exit) -and $exit -ge [int]::MinValue -and $exit -le [int]::MaxValue){[void]$values.Add('PythonExit='+$exit)}
            if($values.Count){$item='['+($values -join '; ')+']';if(-not $diagnostics.Contains($item)){[void]$diagnostics.Add($item)}}
        }
        $current=$current.InnerException
    }
    if($diagnostics.Count){$detail+=' '+($diagnostics -join ' ')}
    if($Failure.Exception.Message.StartsWith('CHECK: ')){$detail=$Failure.Exception.Message.Substring(7)+' '+$detail}
    return $detail
}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS '+$Name)}catch{$detail=Get-SafeTestFailure $_;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=$detail});Write-Host ('FAIL '+$Name+': '+$detail)}}
function Median([double[]]$Values){$rows=@($Values|Sort-Object);if(-not $rows.Count){return [double]0};$middle=[int][math]::Floor($rows.Count/2);if(($rows.Count%2) -eq 1){return [double]$rows[$middle]};return ([double]$rows[$middle-1]+[double]$rows[$middle])/2.0}
function Distribution([double[]]$Values){return [pscustomobject]@{Samples=$Values.Count;Minimum=[math]::Round([double](($Values|Measure-Object -Minimum).Minimum),3);Median=[math]::Round((Median $Values),3);Maximum=[math]::Round([double](($Values|Measure-Object -Maximum).Maximum),3)}}
try {
    Scenario 'Cold isolated readers receive identical PDFs and produce the same complete profile/date evidence' {
        # Alternate engine order to avoid always assigning the first process or
        # filesystem-cache position to one implementation. Every call starts a
        # fresh real PowerShell worker; parsing is never mocked or timed alone.
        for($iteration=1;$iteration -le $Repetitions;$iteration++){
            $engines=if(($iteration%2) -eq 1){@('Standard','Python')}else{@('Python','Standard')}
            foreach($original in $selected){foreach($engine in $engines){
                $clock=[Diagnostics.Stopwatch]::StartNew()
                $read=Invoke-QaIsolatedTask -Action ReadPdf -InputObject ([pscustomobject]@{Config=$Config;RecordId=$original.id;Reader=$engine}) -TimeoutSeconds 90
                $clock.Stop()
                $content=ConvertFrom-QaDocumentContent -Text $read.Text -Truncated $read.Truncated -NeedsOCR $read.NeedsOCR -Pages $read.Pages -ReadPages $read.ReadPages
                $expected=if($original.key -eq 'basic'){'siemens-iec-basic-v1'}else{'siemens-iec-extended-v1'};$count=if($original.key -eq 'basic'){2}else{10}
                Check ($read.ReaderUsed -ceq $engine) 'Each explicit request executes the requested reader instead of a fallback.'
                Check ($read.VerifiedHash -ceq $original.hash -and $read.VerifiedLength -eq (Get-Item $original.destination).Length) 'Every timing sample is bound to the same original PDF bytes.'
                Check ($read.Pages -eq $original.pages -and $read.ReadPages -eq $original.pages -and -not $read.Truncated -and -not $read.NeedsOCR) 'Only complete text reads qualify for this comparison.'
                Check ($content.ProfileId -ceq $expected -and $content.DateStatus -ceq 'Consensus' -and $content.ReportDate -ceq $original.expectedDate -and $content.ReportTime -ceq $original.expectedTime) 'Both readers retain the expected complete body profile and printed report timestamp.'
                Check (@($content.Sections).Count -eq $count -and @($content.Sections|Where-Object{$_.PrintedOutcomes -contains 'OK'}).Count -eq $count) 'All raw section observations are available before comparing speed.'
                [void]$script:Samples.Add([pscustomobject]@{Engine=$engine;ReaderVersion=[string]$read.ReaderVersion;Profile=[string]$original.profile;Pages=[int]$read.Pages;Iteration=$iteration;WholeIsolatedReadMilliseconds=[math]::Round($clock.Elapsed.TotalMilliseconds,3);ReaderMilliseconds=[math]::Round([double]$read.ReadMilliseconds,3);CompleteRead=$true;ClassificationAgreed=$true})
            }}
        }
        Check ($script:Samples.Count -eq (4*$Repetitions)) 'The comparison contains the complete balanced sample population.'
    }
    Scenario 'A warm analysis pass reuses both saved results without reading either PDF again' {
        Import-Module (Join-Path $FixtureRoot 'App/Insights.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
        $ids=@($selected|ForEach-Object id);$clock=[Diagnostics.Stopwatch]::StartNew();$cold=Invoke-QaAnalysis -Config $Config -RecordIds $ids -Force;$clock.Stop();$coldMs=$clock.Elapsed.TotalMilliseconds
        Check ($cold.Analyzed -eq 2 -and $cold.Failed -eq 0) 'The initial bounded batch actually reads both requested documents.'
        $folder=Join-Path $Config.ArchiveRoot '.ctqa/analysis';$before=@{};foreach($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File)){$before[$file.Name]=(Get-FileHash $file.FullName).Hash}
        $clock.Restart();$warm=Invoke-QaAnalysis -Config $Config -RecordIds $ids;$clock.Stop();$warmMs=$clock.Elapsed.TotalMilliseconds
        Check ($warm.Analyzed -eq 0 -and $warm.Cached -eq 2 -and $warm.Failed -eq 0) 'The repeated batch performs zero new PDF parses and reuses both cached entries.'
        foreach($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File)){Check ($before.ContainsKey($file.Name) -and $before[$file.Name] -ceq (Get-FileHash $file.FullName).Hash) 'The warm pass leaves cached evidence byte-for-byte unchanged.'}
        $script:CacheMetrics=[pscustomobject]@{ColdAnalyzed=[int]$cold.Analyzed;ColdMilliseconds=[math]::Round($coldMs,3);WarmAnalyzed=[int]$warm.Analyzed;WarmCached=[int]$warm.Cached;WarmMilliseconds=[math]::Round($warmMs,3);WarmCacheWrites=0}
    }
    Scenario 'Reader comparison and analysis leave source PDFs and core clinical archive state unchanged' {
        Check ((Get-FileHash $statePath).Hash -ceq $stateHash) 'The complete protected clinical state is unchanged.'
        foreach($original in $baseline.Records){Check ((Get-FileHash $original.source).Hash -ceq $original.hash) 'A source PDF remains unchanged.';Check ((Get-FileHash $original.destination).Hash -ceq $original.hash) 'An archived PDF remains unchanged.'}
    }
}finally{if(-not $KeepFixtures){try{Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}catch{}}}
$stats=New-Object 'Collections.Generic.List[object]'
foreach($engine in @('Standard','Python')){$rows=@($script:Samples|Where-Object Engine -ceq $engine);if($rows.Count){[void]$stats.Add([pscustomobject]@{Engine=$engine;ReaderVersion=$rows[0].ReaderVersion;WholeIsolatedReadMilliseconds=(Distribution @($rows|ForEach-Object WholeIsolatedReadMilliseconds));ReaderMilliseconds=(Distribution @($rows|ForEach-Object ReaderMilliseconds))})}}
$standard=@($stats|Where-Object Engine -ceq 'Standard');$python=@($stats|Where-Object Engine -ceq 'Python');$recommended='Unresolved';$ratio=[double]0
if($standard.Count -eq 1 -and $python.Count -eq 1 -and $python[0].WholeIsolatedReadMilliseconds.Median -gt 0){$ratio=[math]::Round(($standard[0].WholeIsolatedReadMilliseconds.Median/$python[0].WholeIsolatedReadMilliseconds.Median),3);$recommended=if($ratio -gt 1){'Python'}else{'Standard'}}
$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Product='CT QA Manager Pro';Version='5.7.1';Feature='Reader comparison';Runtime=$PSVersionTable.PSVersion.ToString();NativeWindowsActuallyRun=$true;SyntheticOnly=$true;RepetitionsPerProfilePerReader=$Repetitions;Profiles=@('Basic:9pages','Extended:6pages');ColdReadSamples=$script:Samples.Count;Stats=@($stats.ToArray());Samples=@($script:Samples.ToArray());StandardMedianDividedByPythonMedian=$ratio;FasterReaderForThisFixture=$recommended;CachedAnalysis=$script:CacheMetrics;MemoryMeasured=$false;PerformanceThresholdAsserted=$false;Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Actual cold ReadPdf PowerShell workers with the same generated local PDF bytes, complete body profiles, footer dates and component observations. Whole-wall timing includes worker startup, validation, transport and reader work. Lower-level timing is reported separately. Alternate engine ordering mitigates consistent first-position bias. No artificial speed threshold is asserted; these local generated files do not establish hospital network speed or performance for every real report. Warm reuse is checked by actual parse and cache-write counts; no hospital PDF or network is used.'}
if($OutputPath){$full=[IO.Path]::GetFullPath($OutputPath);[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full));[IO.File]::WriteAllText($full,($report|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true))}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions; faster reader for this fixture: '+$recommended)
if($failed){exit 1}
