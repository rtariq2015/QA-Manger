[CmdletBinding()]param([string]$OutputPath='',[string]$FixtureRoot='',[switch]$KeepFixtures)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'The production bundled-reader suite must run on Windows; Linux parsing is not runtime evidence.'}
$ProductRoot=Split-Path -Parent $PSScriptRoot
if(-not $FixtureRoot){$FixtureRoot=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDocuments)) ('CTQA Python reader '+[guid]::NewGuid().ToString('N'))}
$FixtureRoot=[IO.Path]::GetFullPath($FixtureRoot)
& (Join-Path $PSScriptRoot 'Web/New-ContentFixture.ps1') -FixtureRoot $FixtureRoot -ProductRoot $ProductRoot
Import-Module (Join-Path $FixtureRoot 'App/Archive.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
Import-Module (Join-Path $FixtureRoot 'App/PdfReader.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
Import-Module (Join-Path $FixtureRoot 'App/Process.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
Import-Module (Join-Path $FixtureRoot 'App/ContentClassifier.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
$Config=Read-QaConfig $FixtureRoot
$Config|Add-Member PdfReaderMode 'Python' -Force
# Add one real text PDF containing strict single-metric rows. It exercises
# parsing after both actual PDF engines rather than only text-parser fixtures.
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Web/New-ContentFixture.ps1'),[ref]$null,[ref]$null)
foreach($name in @('ConvertTo-ContentPdfString','New-ContentPdf')){$function=$fixtureAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true);. ([scriptblock]::Create($function.Extent.Text))}
$function=$fixtureAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-ContentPdf'},$true)
$definition=$function.Extent.Text
$plain="[void]`$lines.Add('Status: OK');[void]`$lines.Add('Synthetic measurement evidence only.')"
$values=@'
$metricLines=if($i -eq 0){@('Test: Typical body mode','Water Value Results for System A','Slice 1','Tolerance','-0.75 HU (-0.60)','-4.00 ... 3.40 HU','Test Results OK')}else{@('Test: Typical head mode','Result','Results for System A','Slice 1','Tolerance','3.50 HU (3.40)','3.00 ... 4.00 HU','Test Results OK')};foreach($metricLine in $metricLines){[void]$lines.Add($metricLine)}
'@
if(-not $definition.Contains($plain)){throw 'The synthetic PDF helper no longer contains its measurement insertion point.'}
. ([scriptblock]::Create($definition.Replace($plain,$values)))
New-ContentPdf -Path (Join-Path $Config.Sources[0].Path 'Unlabelled_Reader_Measurements.pdf') -Profile Basic -Pages 3 -Date '2025-02-03' -Time '12:00:00'
foreach($pair in @(@('image','Image-Only.pdf'),@('encrypted','Encrypted.pdf'))){
    $destination=Join-Path $Config.Sources[0].Path ('Unlabelled_Reader_'+$pair[0]+'.pdf')
    [IO.File]::Copy((Join-Path $PSScriptRoot ('Fixtures/PdfReader/'+$pair[1])),$destination)
    [IO.File]::SetLastWriteTimeUtc($destination,[datetime]::UtcNow.AddMinutes(-10))
}
[void](Invoke-QaOperation $Config -Mode Update)
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'Config/Settings.local.json'),($Config|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true))
$baseline=[IO.File]::ReadAllText((Join-Path $FixtureRoot 'content-fixture-baseline.json'))|ConvertFrom-Json
$script:Records=@{}
foreach($record in $baseline.Records){$script:Records[$record.key]=$record}
$dashboard=Get-QaDashboard $Config
foreach($key in @('image','encrypted','measurements')){$r=@($dashboard.Records|Where-Object OriginalFileName -eq ('Unlabelled_Reader_'+$key+'.pdf'))[0];$script:Records[$key]=[pscustomobject]@{id=$r.Id;hash=$r.Hash;source=$r.SourcePath;destination=$r.DestinationPath;pages=0}}
$StatePath=Join-Path $Config.ArchiveRoot '.ctqa/state.json';$StateHash=(Get-FileHash $StatePath).Hash
$script:Originals=@($dashboard.Records|ForEach-Object{[pscustomobject]@{Source=$_.SourcePath;Destination=$_.DestinationPath;Hash=$_.Hash}})
$script:Results=New-Object 'Collections.Generic.List[object]';$script:Assertions=0
$script:LiveCancellationActuallyRun=$false;$script:StandardAccountName='';$script:StandardAccountSid='';$script:SecurePassword=$null;$script:StandardAccountCreated=$false;$script:NonAdministratorActuallyRun=$false;$script:StandardAccountCleanupSucceeded=$false
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
    if($Failure.Exception.Message.StartsWith('CHECK: ')){$detail=$Failure.Exception.Message.Substring(7)+' '+$detail}
    return $detail
}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS '+$Name)}catch{$detail=Get-SafeTestFailure $_;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=$detail});Write-Host ('FAIL '+$Name+': '+$detail)}}
function Original([string]$Key){return $script:Records[$Key]}
function Read-One([string]$Key,[string]$Reader='Python',[hashtable]$Limits=@{}){return Read-QaReportText -Config $Config -RecordId (Original $Key).id -Reader $Reader @Limits}
function Read-Isolated([string]$Key,[string]$Reader='Python'){return Invoke-QaIsolatedTask -Action ReadPdf -InputObject ([pscustomobject]@{Config=$Config;RecordId=(Original $Key).id;Reader=$Reader}) -TimeoutSeconds 90}
function Classify($Read){return ConvertFrom-QaDocumentContent -Text $Read.Text -Truncated $Read.Truncated -NeedsOCR $Read.NeedsOCR -Pages $Read.Pages -ReadPages $Read.ReadPages}
function Preserve {
    Check ((Get-FileHash $StatePath).Hash -ceq $StateHash) 'The complete clinical state remains byte-for-byte unchanged.'
    foreach($row in $script:Originals){Check ((Get-FileHash $row.Source).Hash -ceq $row.Hash) 'Each synthetic scanner original is preserved.';Check ((Get-FileHash $row.Destination).Hash -ceq $row.Hash) 'Each archived original is preserved.'}
}
function Save-Mode([string]$Mode){$Config|Add-Member PdfReaderMode $Mode -Force;[IO.File]::WriteAllText((Join-Path $FixtureRoot 'Config/Settings.local.json'),($Config|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true))}
function Cache-Hashes {
    $rows=@{};$folder=Join-Path $Config.ArchiveRoot '.ctqa/analysis'
    if([IO.Directory]::Exists($folder)){foreach($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File)){$rows[$file.Name]=(Get-FileHash $file.FullName).Hash}}
    return ,$rows
}
try {
    Scenario 'Bundled Python reads both supported layouts with exact original-byte provenance' {
        foreach($key in @('basic','extended')){
            $o=Original $key;$before=Get-Item -LiteralPath $o.destination;$read=Read-One $key
            Check ($read.ReaderUsed -ceq 'Python' -and -not [string]::IsNullOrWhiteSpace([string]$read.ReaderVersion)) 'The actual bundled Python reader and version are identified.'
            Check ($read.Pages -eq $o.pages -and $read.ReadPages -eq $o.pages -and -not $read.Truncated -and -not $read.NeedsOCR) 'All pages are read as complete selectable text.'
            Check ($read.VerifiedHash -ceq $o.hash -and $read.VerifiedLength -eq $before.Length -and $read.VerifiedWriteTicks -eq $before.LastWriteTimeUtc.Ticks) 'Provenance matches the exact indexed bytes and pre-read metadata.'
            Check ([double]$read.ReadMilliseconds -ge 0 -and [string]::IsNullOrEmpty([string]$read.FallbackReason)) 'Successful explicit Python reading has factual timing and no invented fallback.'
            $content=Classify $read;$profile=if($key -eq 'basic'){'siemens-iec-basic-v1'}else{'siemens-iec-extended-v1'};$count=if($key -eq 'basic'){2}else{10}
            Check ($content.ProfileId -ceq $profile -and $content.DateStatus -ceq 'Consensus' -and $content.ReportDate -eq $o.expectedDate) 'The shared classifier recognizes body sections and the repeated report-footer date.'
            Check (@($content.Sections).Count -eq $count -and @($content.Sections|Where-Object{$_.PrintedOutcomes -contains 'OK'}).Count -eq $count) 'Raw printed OK observations and component count are retained.'
            Check ($content.ClinicalResult -ceq 'Not inferred') 'Document extraction does not create clinical approval.'
        }
        Preserve
    }
    Scenario 'Python and the standard reader agree on profiles, dates, pages and verified fingerprints' {
        foreach($key in @('basic','extended')){
            $python=Read-Isolated $key 'Python';$standard=Read-Isolated $key 'Standard';$p=Classify $python;$s=Classify $standard
            Check ($python.ReaderUsed -ceq 'Python' -and $standard.ReaderUsed -ceq 'Standard') 'Explicit engine requests execute the requested reader in separate real workers.'
            Check ($python.VerifiedHash -ceq $standard.VerifiedHash -and $python.VerifiedLength -eq $standard.VerifiedLength -and $python.VerifiedWriteTicks -eq $standard.VerifiedWriteTicks) 'Both engines bind their output to the same archived original.'
            Check ($p.ProfileId -ceq $s.ProfileId -and $p.ReportDate -ceq $s.ReportDate -and $p.ReportTime -ceq $s.ReportTime) 'Both engines retain the same recognized document identity and footer timestamp.'
            Check ($python.Pages -eq $standard.Pages -and $python.ReadPages -eq $standard.ReadPages -and @($p.Sections).Count -eq @($s.Sections).Count) 'The complete page and component populations agree.'
        }
        Preserve
    }
    Scenario 'Both actual readers preserve printed water/noise measurements and their explicit limits' {
        Import-Module (Join-Path $FixtureRoot 'App/MeasurementParser.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
        foreach($engine in @('Python','Standard')){
            $read=Read-Isolated 'measurements' $engine
            $document=ConvertFrom-QaMeasurementText -Text $read.Text -Truncated $read.Truncated -NeedsOCR $read.NeedsOCR -Pages $read.Pages -ReadPages $read.ReadPages
            Check ($document.Status -ceq 'Extracted' -and @($document.Measurements).Count -eq 2 -and $document.ClinicalResult -ceq 'Not inferred') 'A real three-page PDF yields exactly two printed metrics without a clinical assessment.'
            $water=@($document.Measurements|Where-Object Code -ceq 'WaterCTNumber');$noise=@($document.Measurements|Where-Object Code -ceq 'ImageNoise')
            Check ($water.Count -eq 1 -and $water[0].Value -ceq '-0.75' -and $water[0].LowerLimit -ceq '-4' -and $water[0].UpperLimit -ceq '3.4') 'The water value and its printed lower/upper HU limits remain exact.'
            Check ($noise.Count -eq 1 -and $noise[0].Value -ceq '3.5' -and $noise[0].LowerLimit -ceq '3' -and $noise[0].UpperLimit -ceq '4') 'The noise value and its printed lower/upper HU limits remain exact.'
            Check ($water[0].Mode -ceq 'Body' -and $noise[0].Mode -ceq 'Head' -and $water[0].Page -eq 3 -and $noise[0].Page -eq 3) 'Page references and head/body context survive actual PDF extraction.'
            Check ($water[0].Status -ceq 'Printed' -and $noise[0].Status -ceq 'Printed' -and $water[0].SourceSystem -ceq 'A' -and $noise[0].SourceSystem -ceq 'A') 'Measurements retain raw documentary status and the printed source system.'
        }
        Preserve
    }
    Scenario 'Page, character and byte bounds remain explicit with the Python reader' {
        $limited=Read-One 'basic' 'Python' @{MaximumPages=1}
        Check ($limited.Truncated -and $limited.Pages -eq 9 -and $limited.ReadPages -eq 1) 'A one-page request is visibly incomplete rather than a successful full read.'
        $content=Classify $limited;Check (-not $content.CompleteRead) 'Partial text cannot supply a complete document profile.'
        $limited=Read-One 'basic' 'Python' @{MaximumCharacters=500}
        Check ($limited.Truncated -and $limited.Text.Length -le 500) 'The exact maximum text length is honored.'
        $errorText='';try{Read-One 'basic' 'Python' @{MaximumBytes=1024}|Out-Null}catch{$errorText=$_.Exception.Message}
        Check (-not [string]::IsNullOrWhiteSpace($errorText) -and -not $errorText.Contains($FixtureRoot)) 'Oversized input is rejected before parsing with a safe fixed explanation.'
        Preserve
    }
    Scenario 'Image-only and encrypted inputs remain separate from successful text extraction' {
        $image=Read-One 'image';Check ($image.NeedsOCR -and -not $image.Truncated -and $image.Pages -gt 0 -and $image.ReadPages -eq $image.Pages) 'All image-only pages are inspected and explicitly require OCR.'
        Check (@($image.Indicators).Count -eq 0) 'The reader invents no test names from images.'
        $errorText='';try{Read-One 'encrypted'|Out-Null}catch{$errorText=$_.Exception.Message}
        Check (-not [string]::IsNullOrWhiteSpace($errorText) -and -not $errorText.Contains($FixtureRoot) -and -not $errorText.Contains((Original 'encrypted').source)) 'Encrypted input fails without logging private paths.'
        $lock=[IO.File]::Open((Join-Path $Config.ArchiveRoot '.ctqa/archive.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$lock.Dispose();Check $true 'A failed Python read releases the archive lock.'
        Preserve
    }
    Scenario 'An altered archived PDF is rejected before either reader can acquire new provenance' {
        $o=Original 'basic';$bytes=[IO.File]::ReadAllBytes($o.destination);$ticks=[IO.File]::GetLastWriteTimeUtc($o.destination)
        try {
            $changed=[byte[]]$bytes.Clone();$changed[100]=$changed[100] -bxor 1;[IO.File]::WriteAllBytes($o.destination,$changed);[IO.File]::SetLastWriteTimeUtc($o.destination,$ticks)
            foreach($reader in @('Python','Auto')){$rejected=$false;try{Read-One 'basic' $reader|Out-Null}catch{$rejected=$_.Exception.Message -match 'SHA-256'};Check $rejected 'A matching length and restored timestamp cannot bypass the indexed hash check.'}
        }finally{[IO.File]::WriteAllBytes($o.destination,$bytes);[IO.File]::SetLastWriteTimeUtc($o.destination,$ticks)}
        Preserve
    }
    Scenario 'An invalid Python dependency is rejected explicitly and automatic fallback preserves provenance' {
        $dependency=Join-Path $FixtureRoot 'App/Python/vendor/pypdf/__init__.py';$bytes=[IO.File]::ReadAllBytes($dependency);$stamp=[IO.File]::GetLastWriteTimeUtc($dependency)
        try {
            [IO.File]::AppendAllText($dependency,"`r`n# Synthetic disposable integrity mutation",[Text.Encoding]::ASCII)
            $errorText='';try{Read-Isolated 'basic' 'Python'|Out-Null}catch{$errorText=$_.Exception.Message}
            Check (-not [string]::IsNullOrWhiteSpace($errorText) -and -not $errorText.Contains($FixtureRoot)) 'A modified reader dependency cannot execute as a successful explicit Python read.'
            $fallback=Read-Isolated 'basic' 'Auto'
            Check ($fallback.ReaderUsed -ceq 'Standard' -and $fallback.FallbackReason -in @('PythonUnavailable','PythonReadError')) 'Automatic mode uses the verified standard reader when Python cannot be used.'
            Check ($fallback.VerifiedHash -ceq (Original 'basic').hash -and $fallback.ReadPages -eq 9) 'Fallback remains a full read of the original verified bytes.'
        }finally{[IO.File]::WriteAllBytes($dependency,$bytes);[IO.File]::SetLastWriteTimeUtc($dependency,$stamp)}
        Preserve
    }
    Scenario 'A missing Python runtime allows automatic standard reading and a clear explicit-reader error' {
        $runtime=Join-Path $FixtureRoot 'App/Python/runtime';$held=$runtime+'.disabled-for-synthetic-test';[IO.Directory]::Move($runtime,$held)
        try {
            $read=Read-Isolated 'extended' 'Auto'
            Check ($read.ReaderUsed -ceq 'Standard' -and $read.FallbackReason -ceq 'PythonUnavailable' -and $read.ReadPages -eq 6) 'Automatic mode remains usable without an available Python executable.'
            Check ($read.VerifiedHash -ceq (Original 'extended').hash) 'Fallback keeps the same fingerprint provenance.'
            $failed=$false;try{Read-Isolated 'extended' 'Python'|Out-Null}catch{$failed=$true};Check $failed 'An explicit unavailable reader request is never silently mislabeled as Python.'
        }finally{[IO.Directory]::Move($held,$runtime)}
        Preserve
    }
    Scenario 'Cancelled reads expose no text or successful provenance and do not create analysis evidence' {
        $before=Cache-Hashes;$progress=[hashtable]::Synchronized(@{Cancel=$true;Message='';Percent=0})
        $read=Read-QaReportText -Config $Config -RecordId (Original 'basic').id -Reader Python -Progress $progress
        Check ($read.Summary.Cancelled -and $read.Text -eq '' -and $read.VerifiedHash -eq '' -and $read.VerifiedLength -eq 0) 'A pre-cancelled request does not publish text or verified-read evidence.'
        $after=Cache-Hashes;Check ($before.Count -eq $after.Count) 'Cancellation adds no analysis cache rows.'
        foreach($name in $before.Keys){Check ($before[$name] -ceq $after[$name]) 'Existing analysis cache bytes remain unchanged.'}
        Preserve
    }
    Scenario 'Current caches are reused across fresh modules and older evidence upgrades only on a selected read' {
        Import-Module (Join-Path $FixtureRoot 'App/Insights.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
        Save-Mode 'Python'
        $ids=@((Original 'basic').id,(Original 'extended').id)
        $first=Invoke-QaAnalysis -Config $Config -RecordIds $ids -Force
        Check ($first.Analyzed -eq 2 -and $first.Failed -eq 0) 'The first explicit Python batch reads the two requested real PDFs.'
        foreach($key in @('basic','extended')){$record=@((Get-QaDashboard $Config).Records|Where-Object Id -eq (Original $key).id)[0];$r=Get-QaSavedAnalysis $Config $record;Check ($null -ne $r -and $r.AnalysisCacheSchemaVersion -eq 3 -and $r.ReaderUsed -ceq 'Python' -and $r.RequestedReaderMode -ceq 'Python') 'New evidence records its cache schema and actual requested/used reader.';Check ($null -ne $r.MeasurementsDocument -and [double]$r.ReaderElapsedMs -ge 0) 'Derived measurements and factual isolated wall time are stored.'}
        $before=Cache-Hashes
        Import-Module (Join-Path $FixtureRoot 'App/Insights.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
        $warm=Invoke-QaAnalysis -Config $Config -RecordIds $ids
        Check ($warm.Analyzed -eq 0 -and $warm.Cached -eq 2 -and $warm.Failed -eq 0) 'A fresh module reuses both unchanged cached documents without reparsing.'
        $after=Cache-Hashes;foreach($name in $before.Keys){Check ($before[$name] -ceq $after[$name]) 'Warm reads do not rewrite analysis files.'}
        $basic=Original 'basic';$cache=Join-Path $Config.ArchiveRoot ('.ctqa/analysis/'+$basic.hash+'.json');$old=[IO.File]::ReadAllText($cache)|ConvertFrom-Json
        $old.AnalysisCacheSchemaVersion=2
        foreach($name in @('MeasurementsDocument','ReaderUsed','ReaderVersion','ReaderElapsedMs','RequestedReaderMode')){$old.PSObject.Properties.Remove($name)}
        [IO.File]::WriteAllText($cache,($old|ConvertTo-Json -Depth 25),(New-Object Text.UTF8Encoding $true));$oldHash=(Get-FileHash $cache).Hash
        $background=Invoke-QaAnalysis -Config $Config -RecordIds @($basic.id)
        Check ($background.Analyzed -eq 0 -and $background.Cached -eq 1 -and (Get-FileHash $cache).Hash -ceq $oldHash) 'A background pass preserves valid version5.2 evidence instead of bulk-reading the archive again.'
        Import-Module (Join-Path $FixtureRoot 'App/WebService.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
        $selected=Invoke-QaWebRequest -AppRoot $FixtureRoot -Request ([pscustomobject]@{action='Analyze';id=$basic.id})
        Check ($selected.result.Analyzed -eq 1 -and $selected.result.Failed -eq 0) 'An explicitly selected older document receives one bounded evidence upgrade.'
        $upgraded=[IO.File]::ReadAllText($cache)|ConvertFrom-Json
        Check ($upgraded.AnalysisCacheSchemaVersion -eq 3 -and $upgraded.ReaderUsed -ceq 'Python' -and $null -ne $upgraded.MeasurementsDocument) 'The selected upgrade carries current reader and measurement evidence.'
        $basicHash=(Get-FileHash $cache).Hash
        Save-Mode 'Standard';$extended=Original 'extended'
        $changed=Invoke-QaWebRequest -AppRoot $FixtureRoot -Request ([pscustomobject]@{action='Analyze';id=$extended.id})
        Check ($changed.result.Analyzed -eq 1 -and $changed.result.Failed -eq 0) 'Changing the reading mode rereads only the explicitly selected report.'
        $extendedCache=Join-Path $Config.ArchiveRoot ('.ctqa/analysis/'+$extended.hash+'.json');$changedRow=[IO.File]::ReadAllText($extendedCache)|ConvertFrom-Json
        Check ($changedRow.ReaderUsed -ceq 'Standard' -and $changedRow.RequestedReaderMode -ceq 'Standard') 'The selected report records the actual new standard reader.'
        Check ((Get-FileHash $cache).Hash -ceq $basicHash) 'An unrelated prior Python evidence row is not rewritten when another report changes mode.'
        $again=Invoke-QaWebRequest -AppRoot $FixtureRoot -Request ([pscustomobject]@{action='Analyze';id=$extended.id})
        Check ($again.result.Analyzed -eq 0 -and $again.result.Cached -ge 1) 'The selected current-mode evidence is reused on its next read.'
        Save-Mode 'Python'
        Preserve
    }
    Scenario 'Cancelling after Python starts terminates its real child process and preserves all cached evidence' {
        $worker=Join-Path $FixtureRoot 'App/Python/read_pdf.py';$manifestPath=Join-Path $FixtureRoot 'App/Python/Integrity.json'
        $workerBytes=[IO.File]::ReadAllBytes($worker);$manifestBytes=[IO.File]::ReadAllBytes($manifestPath)
        $workerStamp=[IO.File]::GetLastWriteTimeUtc($worker);$manifestStamp=[IO.File]::GetLastWriteTimeUtc($manifestPath)
        $ps=$null;$async=$null;$progress=[hashtable]::Synchronized(@{Cancel=$false;Message='';Percent=0});$childIds=@();$before=Cache-Hashes
        try {
            # This deterministic barrier changes only the disposable fixture's
            # copied worker. Production bytes and user files are never altered.
            $text=[Text.Encoding]::UTF8.GetString($workerBytes);$marker='from __future__ import annotations'
            Check ($text.Contains($marker)) 'The copied worker has a stable location for a synthetic cancellation barrier.'
            $text=$text.Replace($marker,$marker+"`nimport time as _ctqa_synthetic_barrier`n_ctqa_synthetic_barrier.sleep(30)")
            [IO.File]::WriteAllText($worker,$text,(New-Object Text.UTF8Encoding $false))
            $manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json;$entry=@($manifest.Files|Where-Object Name -ceq 'read_pdf.py')
            Check ($entry.Count -eq 1) 'Only the copied worker checksum is changed for the deterministic barrier.'
            $entry[0].SHA256=(Get-FileHash $worker).Hash
            [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true))
            $code={param($Module,$Cfg,$Record,$Shared) Import-Module $Module -Force -DisableNameChecking -WarningAction SilentlyContinue;Invoke-QaAnalysis -Config $Cfg -RecordIds @($Record) -Force -Progress $Shared}
            $ps=[powershell]::Create();[void]$ps.AddScript($code.ToString()).AddArgument((Join-Path $FixtureRoot 'App/Insights.psm1')).AddArgument($Config).AddArgument((Original 'otherScanner').id).AddArgument($progress)
            $async=$ps.BeginInvoke();$executable=[IO.Path]::GetFullPath((Join-Path $FixtureRoot 'App/Python/runtime/python.exe'));$clock=[Diagnostics.Stopwatch]::StartNew()
            while($clock.Elapsed.TotalSeconds -lt 20 -and -not $async.IsCompleted){$children=@(Get-Process -Name python -ErrorAction SilentlyContinue|Where-Object{$_.Path -ieq $executable});if($children.Count){$childIds=@($children|ForEach-Object Id);break};Start-Sleep -Milliseconds 100}
            Check ($childIds.Count -gt 0 -and -not $async.IsCompleted) 'The real bundled Python child starts and remains inside the deterministic barrier.'
            $progress.Cancel=$true;$stop=[Diagnostics.Stopwatch]::StartNew()
            while(-not $async.IsCompleted -and $stop.Elapsed.TotalSeconds -lt 12){Start-Sleep -Milliseconds 100}
            Check $async.IsCompleted 'Cancellation completes within a bounded checkpoint after the Python process starts.'
            $results=@($ps.EndInvoke($async));$result=@($results|Where-Object{$null -ne $_.PSObject.Properties['Summary']})
            Check ($result.Count -eq 1 -and $result[0].Summary.Cancelled -and $result[0].Analyzed -eq 0) 'The real analysis operation reports cancellation without accepting a partial PDF.'
            foreach($id in $childIds){$wait=[Diagnostics.Stopwatch]::StartNew();do{$alive=Get-Process -Id $id -ErrorAction SilentlyContinue;if($null -ne $alive){Start-Sleep -Milliseconds 100}}while($null -ne $alive -and $wait.Elapsed.TotalSeconds -lt 5);Check ($null -eq $alive) 'Killing the outer task also terminates its contained Python child.'}
            $after=Cache-Hashes;Check ($after.Count -eq $before.Count) 'A cancelled live read creates no new analysis rows.'
            foreach($name in $before.Keys){Check ($after.ContainsKey($name) -and $after[$name] -ceq $before[$name]) 'Existing cached evidence remains byte-for-byte unchanged after live cancellation.'}
            $script:LiveCancellationActuallyRun=$true
        } finally {
            $progress.Cancel=$true
            if($null -ne $ps){if($null -ne $async -and -not $async.IsCompleted){try{$ps.Stop()}catch{}};$ps.Dispose()}
            foreach($id in $childIds){$alive=Get-Process -Id $id -ErrorAction SilentlyContinue;if($null -ne $alive){try{$alive.Kill();[void]$alive.WaitForExit(3000)}catch{}}}
            [IO.File]::WriteAllBytes($worker,$workerBytes);[IO.File]::SetLastWriteTimeUtc($worker,$workerStamp)
            [IO.File]::WriteAllBytes($manifestPath,$manifestBytes);[IO.File]::SetLastWriteTimeUtc($manifestPath,$manifestStamp)
        }
        Preserve
    }
    Scenario 'The complete production archive-to-Python reader runs under an actual non-administrator token' {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=New-Object Security.Principal.WindowsPrincipal($identity)
        if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
            $read=Read-Isolated 'basic' 'Python';Check ($read.ReaderUsed -ceq 'Python' -and $read.ReadPages -eq 9) 'An already-standard user executes the production reader successfully.'
            $script:NonAdministratorActuallyRun=$true
        }else{
            $script:StandardAccountName='ctqar'+[guid]::NewGuid().ToString('N').Substring(0,12)
            $secret=[guid]::NewGuid().ToString('N')+'aA!3';$script:SecurePassword=ConvertTo-SecureString $secret -AsPlainText -Force;$secret=$null
            $account=New-LocalUser -Name $script:StandardAccountName -Password $script:SecurePassword -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Description 'Ephemeral CT QA production reader validation'
            $script:StandardAccountSid=$account.SID.Value;$script:StandardAccountCreated=$true
            $users=Get-LocalGroup -SID 'S-1-5-32-545';if(-not @(Get-LocalGroupMember -Group $users|Where-Object{$_.SID.Value -ceq $script:StandardAccountSid}).Count){Add-LocalGroupMember -Group $users -Member $account}
            $acl=Get-Acl -LiteralPath $FixtureRoot;$rule=New-Object Security.AccessControl.FileSystemAccessRule($account.SID,'Modify','ContainerInherit,ObjectInherit','None','Allow');$acl.AddAccessRule($rule);Set-Acl -LiteralPath $FixtureRoot -AclObject $acl
            $code=@'
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
try {
    $root=Split-Path -Parent $MyInvocation.MyCommand.Path
    Import-Module (Join-Path $root 'App/Archive.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
    Import-Module (Join-Path $root 'App/PdfReader.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
    $config=Read-QaConfig $root
    $record=@((Get-QaDashboard $config).Records|Where-Object OriginalFileName -ceq 'Unlabelled_Basic.pdf')[0]
    $read=Read-QaReportText -Config $config -RecordId $record.Id -Reader Python
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $admin=[bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $result=[pscustomobject]@{Passed=($read.ReaderUsed -ceq 'Python' -and $read.ReadPages -eq 9 -and $read.VerifiedHash -ceq $record.Hash -and $admin -ceq $false);Admin=$admin;ReaderUsed=$read.ReaderUsed;ReadPages=$read.ReadPages}
    [IO.File]::WriteAllText((Join-Path $root 'StandardReaderResult.json'),($result|ConvertTo-Json),(New-Object Text.UTF8Encoding $true))
    if(-not $result.Passed){exit 1}
}catch{Write-Output 'The standard-user production reader check failed.';exit 1}
'@
            $child=Join-Path $FixtureRoot 'Run standard reader.ps1';[IO.File]::WriteAllText($child,$code,(New-Object Text.UTF8Encoding $true))
            $temporary=Join-Path $FixtureRoot 'Standard temporary files';[void][IO.Directory]::CreateDirectory($temporary)
            $wrapper=Join-Path $FixtureRoot 'Run standard reader.cmd'
            $lines=@('@echo off','setlocal DisableDelayedExpansion','set "PATH=%SystemRoot%\System32"','set "PYTHONHOME=%~dp0Missing Python home"','set "PYTHONPATH=%~dp0Missing external imports"','set "TEMP=%~dp0Standard temporary files"','set "TMP=%TEMP%"','"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -File "%~dp0Run standard reader.ps1"','exit /b %errorlevel%')
            [IO.File]::WriteAllText($wrapper,($lines -join [Environment]::NewLine)+[Environment]::NewLine,[Text.Encoding]::ASCII)
            $credential=New-Object Management.Automation.PSCredential(('.\'+$script:StandardAccountName),$script:SecurePassword)
            $stdout=Join-Path $FixtureRoot 'StandardReader-stdout.txt';$stderr=Join-Path $FixtureRoot 'StandardReader-stderr.txt'
            $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/cmd.exe') -ArgumentList ('/d /s /c ""'+$wrapper+'""') -Credential $credential -WorkingDirectory $FixtureRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
            try{[void]$process.Handle;if(-not $process.WaitForExit(120000)){try{$process.Kill()}catch{};throw 'CHECK: The standard-user reader completed within its bounded timeout.'};$exit=$process.ExitCode}finally{$process.Dispose()}
            Check ($exit -eq 0) 'The actual separate standard-account process exits successfully.'
            $result=[IO.File]::ReadAllText((Join-Path $FixtureRoot 'StandardReaderResult.json'))|ConvertFrom-Json
            Check ($result.Passed -and $result.Admin -is [bool] -and $result.Admin -ceq $false -and $result.ReaderUsed -ceq 'Python' -and $result.ReadPages -eq 9) 'The complete production reader succeeds with a known unelevated token.'
            $script:NonAdministratorActuallyRun=$true
        }
        Preserve
    }
} finally {
    if($script:StandardAccountCreated){try{Remove-LocalUser -Name $script:StandardAccountName;$profile=Get-CimInstance Win32_UserProfile -Filter ("SID='"+$script:StandardAccountSid+"'") -ErrorAction SilentlyContinue;if($null -ne $profile -and -not $profile.Loaded){$profile|Remove-CimInstance -ErrorAction Stop};$script:StandardAccountCleanupSucceeded=$true}catch{[void]$script:Results.Add([pscustomobject]@{Name='Ephemeral reader account cleanup';Result='FAIL';Details=$_.Exception.GetType().Name})}}else{$script:StandardAccountCleanupSucceeded=$true}
    if($null -ne $script:SecurePassword){$script:SecurePassword.Dispose();$script:SecurePassword=$null}
    if(-not $KeepFixtures){try{Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}catch{}}
}
$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Product='CT QA Manager Pro';Version='5.3.0';Feature='Production portable Python reader';Runtime=$PSVersionTable.PSVersion.ToString();NativeWindowsActuallyRun=$true;NonAdministratorActuallyRun=$script:NonAdministratorActuallyRun;LiveCancellationActuallyRun=$script:LiveCancellationActuallyRun;StandardAccountCleanupSucceeded=$script:StandardAccountCleanupSucceeded;SyntheticOnly=$true;Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Actual production PDF reader against generated text, image-only and encrypted PDFs. Both engines retain indexed-byte provenance; limits, changed bytes, dependency integrity, fallback and cache preservation are explicit. No hospital network, real PDF or work-computer policy is exercised by this public suite.'}
if($OutputPath){$full=[IO.Path]::GetFullPath($OutputPath);[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full));[IO.File]::WriteAllText($full,($report|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true))}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
if($failed){exit 1}
