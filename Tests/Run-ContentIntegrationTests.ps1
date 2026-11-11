[CmdletBinding()]param([string]$OutputPath='',[string]$FixtureRoot='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot;$ownFixture=(-not $FixtureRoot)
if($ownFixture){$FixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_ContentTests_'+[guid]::NewGuid().ToString('N'));&(Join-Path $PSScriptRoot 'Web/New-ContentFixture.ps1') -FixtureRoot $FixtureRoot -ProductRoot $ProductRoot}
$baseline=[IO.File]::ReadAllText((Join-Path $FixtureRoot 'content-fixture-baseline.json'))|ConvertFrom-Json
if(-not $baseline.Synthetic){throw 'Content integration tests require the synthetic fixture.'}
Import-Module (Join-Path $ProductRoot 'App/WebService.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
Import-Module (Join-Path $ProductRoot 'App/Archive.psm1') -DisableNameChecking -WarningAction SilentlyContinue
# Two additional real PDFs isolate conflicts that must take precedence over a
# filename shortcut or a saved profile rule. Import is fixture setup only;
# the clinical-state immutability baseline is captured after this import.
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Web/New-ContentFixture.ps1'),[ref]$null,[ref]$null)
foreach($name in @('ConvertTo-ContentPdfString','New-ContentPdf')){$fn=$fixtureAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);. ([scriptblock]::Create($fn.Extent.Text))}
$cfg=Read-QaConfig $FixtureRoot
$monthlyName='Monthly_Constancy_2025-02-03_10-00-00.pdf';$dailyTitleName='Unlabelled_Explicit_Daily_Title.pdf'
New-ContentPdf -Path (Join-Path $cfg.Sources[0].Path $monthlyName) -Profile Basic -Pages 5 -Date '2025-02-03' -Time '10:00:00' -Conflict
$definition=$fixtureAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-ContentPdf'},$true).Extent.Text
$definition=$definition.Replace("'SYNTHETIC TEST DOCUMENT - NO CLINICAL EVIDENCE'","'Daily QA'")
. ([scriptblock]::Create($definition))
New-ContentPdf -Path (Join-Path $cfg.Sources[0].Path $dailyTitleName) -Profile Basic -Pages 5 -Date '2025-02-03' -Time '13:00:00'
[void](Invoke-QaOperation $cfg -Mode Update);$dashboard=Get-QaDashboard $cfg
foreach($pair in @(@('monthlyFilenameConflict',$monthlyName),@('explicitDailyTitle',$dailyTitleName))){$r=@($dashboard.Records|Where-Object OriginalFileName -ceq $pair[1])[0];$baseline.Records+=@([pscustomobject]@{key=$pair[0];id=$r.Id;hash=$r.Hash;scanner=$r.Scanner;source=$r.SourcePath;destination=$r.DestinationPath;rawDate=$r.ReportDate;rawCategory=$r.Category;pages=5;profile='Basic';expectedDate='2025-02-03';expectedTime=$r.ReportTime})}
$baseline.StateSHA256=(Get-FileHash (Join-Path $baseline.ArchiveRoot '.ctqa/state.json')).Hash;$baseline.RecordCount=@($dashboard.Records).Count
$script:Results=New-Object 'Collections.Generic.List[object]';$script:Assertions=0;$script:ReadIds=New-Object 'Collections.Generic.List[string]'
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS'});Write-Host ('PASS '+$Name)}catch{[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=($_.Exception.Message+' / '+$_.ScriptStackTrace)});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
function Request($Value){Invoke-QaWebRequest -AppRoot $FixtureRoot -Request ([pscustomobject]$Value)}
function Snapshot {Request @{action='Snapshot'}}
function Original([string]$Key){@($baseline.Records|Where-Object key -eq $Key)[0]}
function Record([string]$Key){$original=Original $Key;@((Snapshot).records|Where-Object id -ceq $original.id)[0]}
function Read-One([string]$Key){$original=Original $Key;$r=Request @{action='Analyze';id=$original.id};[void]$script:ReadIds.Add($original.id);return $r}
function Map-Profiles([string]$Basic='',[string]$Extended=''){Request @{action='ScannerSettings';scanner='CT_Edge';contentProfiles=@([pscustomobject]@{profileId='siemens-iec-basic-v1';category=$Basic},[pscustomobject]@{profileId='siemens-iec-extended-v1';category=$Extended})}}
function Mapping([string]$Scanner,[string]$Profile){$row=@((Snapshot).scanners|Where-Object id -eq $Scanner)[0];$mapped=@($row.contentProfiles|Where-Object profileId -eq $Profile);if($mapped.Count){return [string]$mapped[0].category};return ''}
function Preserve {
    Check ((Get-FileHash (Join-Path $baseline.ArchiveRoot '.ctqa/state.json')).Hash -ceq $baseline.StateSHA256) 'Derived labels, dates and printed outcomes leave the entire clinical archive state byte-for-byte unchanged'
    foreach($original in $baseline.Records){Check ((Get-FileHash $original.source).Hash -ceq $original.hash) 'The synthetic scanner original remains unchanged';Check ((Get-FileHash $original.destination).Hash -ceq $original.hash) 'The original archived PDF remains unchanged'}
}
Scenario 'Read one PDF extracts real body headings, footer dates and raw OK evidence while mappings default to Ask' {
    $before=@((Snapshot).records|Where-Object{$_.content.status -eq 'NotRead'}).Count;$beforeRead=Record 'basic'
    $result=Read-One 'basic';$row=Record 'basic'
    Check ($result.result.Analyzed -eq 1 -and @($result.result.AnalyzedIds).Count -eq 1 -and $result.result.AnalyzedIds[0] -ceq (Original 'basic').id) 'Selected analysis reads only the requested indexed PDF'
    Check ($row.content.status -eq 'Recognized' -and $row.content.profileId -eq 'siemens-iec-basic-v1') 'The two numbered body sections identify the Basic document profile'
    Check ($row.content.pages -eq 9 -and $row.content.readPages -eq 9 -and $row.content.completeRead) 'A nine-page Basic document is fully read; page count does not determine its profile'
    Check ($row.pending -and $row.content.mappedCategory -eq '') 'A recognized profile still asks before a department mapping is saved'
    Check ($row.date -eq '2025-02-03' -and $row.time -eq '08:00:00' -and $row.content.dateStatus -eq 'Consensus') 'Consistent repeated report footers supply a derived date when the raw filename has none'
    Check (@($row.content.components).Count -eq 2 -and @($row.content.components|Where-Object result -ceq 'OK').Count -eq 2) 'Printed OK remains raw OK for both sections'
    Check (@($row.content.components|Where-Object{$_.page -ge 3}).Count -eq 2 -and @($row.clinicalComponents).Count -eq 0) 'Body-page evidence is retained without fabricating a reviewed checklist'
    Check (@((Snapshot).records|Where-Object{$_.content.status -eq 'NotRead'}).Count -eq ($before-1)) 'Other unread documents were not analyzed by a selected read'
    $staleRejected=$false;try{Request @{action='Approve';id=$beforeRead.id;stamp=$beforeRead.stamp}|Out-Null}catch{$staleRejected=$true}
    Check ($staleRejected -and (Record 'basic').pending) 'A stale approval from before reading the report cannot silently accept a newly derived document label'
    Preserve
}
Scenario 'An Extended profile is identified by all ten body sections even when its PDF is shorter than Basic' {
    [void](Read-One 'extended');$row=Record 'extended'
    Check ($row.content.status -eq 'Recognized' -and $row.content.profileId -eq 'siemens-iec-extended-v1') 'All ten numbered body sections identify Extended'
    Check ($row.content.pages -eq 6 -and $row.content.readPages -eq 6) 'The Extended fixture has six pages rather than a hardcoded expected page count'
    Check (@($row.content.components).Count -eq 10 -and @($row.content.components|Where-Object result -ceq 'OK').Count -eq 10) 'Every Extended section retains its printed token and page evidence'
    Check ($row.pending -and $row.content.suggestedCategory -eq 'Monthly') 'The suggested Monthly label is offered for one-file approval without learning a site-wide rule'
    Preserve
}
Scenario 'Conflicting or missing footer dates remain unresolved and a disagreeing filename keeps its original date' {
    foreach($key in @('footerConflict','filenameConflict','filenameAgrees','missingDate','otherScanner')){[void](Read-One $key)}
    $conflict=Record 'footerConflict';Check ($conflict.content.status -eq 'NeedsReview' -and $conflict.content.dateStatus -eq 'Conflict' -and -not $conflict.date) 'Different printed page-footer dates do not create an accepted report date'
    $filename=Record 'filenameConflict';Check ($filename.date -eq '2025-02-05' -and $filename.content.status -eq 'NeedsReview') 'Conflicting body and filename dates cannot silently replace the indexed filename date'
    $agrees=Record 'filenameAgrees';Check ($agrees.date -eq '2025-02-03' -and $agrees.content.status -eq 'Recognized') 'Matching body and filename dates are retained consistently'
    $missing=Record 'missingDate';Check ($missing.content.status -eq 'NeedsReview' -and $missing.content.dateStatus -eq 'Missing' -and -not $missing.date) 'A supported section set without report footers does not invent a date'
    Preserve
}
Scenario 'Approve accepts one content suggestion without teaching all files and saved decisions override later profile mappings' {
    $row=Record 'basic';$approved=Request @{action='Approve';id=$row.id;stamp=$row.stamp};$after=Record 'basic'
    Check ($after.decision -eq 'Approved' -and $after.category -eq 'Daily' -and -not $after.pending) 'Approve accepts the selected Basic document suggestion'
    Check ((Mapping 'CT_Edge' 'siemens-iec-basic-v1') -eq '') 'Approving a file does not save a scanner mapping'
    Check ((Record 'filenameAgrees').pending) 'Another recognized Basic file remains pending after one-file approval'
    [void](Map-Profiles 'Other' 'Monthly');$after=Record 'basic'
    Check ($after.category -eq 'Daily' -and $after.decision -eq 'Approved') 'A saved human file decision wins over a later different profile mapping'
    Check ((Record 'extended').category -eq 'Monthly' -and -not (Record 'extended').pending) 'An explicitly saved Extended mapping organizes future matching content'
    Check ((Record 'otherScanner').pending -and (Mapping 'CT_Flash' 'siemens-iec-basic-v1') -eq '') 'Mappings are scoped to the selected scanner'
    $settingsPath=Join-Path $FixtureRoot 'Config/Settings.local.json';$before=(Get-FileHash $settingsPath).Hash;$rejected=$false
    try{Request @{action='ScannerSettings';scanner='CT_Edge';contentProfiles=@([pscustomobject]@{profileId='unknown-profile';category='Daily'})}|Out-Null}catch{$rejected=$true}
    Check ($rejected -and (Get-FileHash $settingsPath).Hash -ceq $before) 'Unsupported profile identifiers are rejected without overwriting saved scanner settings'
    [void](Map-Profiles 'Daily' 'Monthly')
    Preserve
}
Scenario 'Derived dates and mapped categories drive readable folders and exported ZIP paths without rewriting core fields' {
    $cfg=Read-QaConfig $FixtureRoot;$library=&(Get-Module WebService){param($c) Update-QaWebLibrary $c} $cfg
    Check ($library.failed -eq 0) 'Readable folders were generated from the current derived view'
    $manifest=[IO.File]::ReadAllText((Join-Path $cfg.ArchiveRoot '.ctqa/web-library.json'))|ConvertFrom-Json
    foreach($key in @('basic','extended')){$original=Original $key;$entry=@($manifest.Records|Where-Object id -ceq $original.id)[0];$expected=if($key -eq 'basic'){'Daily'}else{'Monthly'};Check ($entry.relative -match ('/2025/02 - February/'+$expected+'/')) 'The readable folder uses the accepted footer year/month and document mapping';Check ((Get-FileHash (Join-Path $library.libraryRoot $entry.relative)).Hash -ceq $original.hash) 'The readable file retains the original content fingerprint'}
    $export=Request @{action='Export';ids=@((Original 'basic').id,(Original 'extended').id)}
    Add-Type -AssemblyName System.IO.Compression.FileSystem;$zip=[IO.Compression.ZipFile]::OpenRead($export.path)
    try{$pdfs=@($zip.Entries|Where-Object FullName -match '\.pdf$');Check ($pdfs.Count -eq 2) 'The export contains exactly the chosen content-derived documents';Check (@($pdfs|Where-Object FullName -match '/2025/02 - February/(Daily|Monthly)/').Count -eq 2) 'ZIP paths use the accepted footer date rather than Unknown Date';$summaryReader=New-Object IO.StreamReader($zip.GetEntry('Report Summary.html').Open());try{$html=$summaryReader.ReadToEnd()}finally{$summaryReader.Dispose()};Check ([regex]::Matches($html,'<td>2025-02-03</td>').Count -eq 2) 'The HTML summary date cells agree with the derived folder dates';$csvReader=New-Object IO.StreamReader($zip.GetEntry('Report list.csv').Open());try{$csv=@($csvReader.ReadToEnd()|ConvertFrom-Csv)}finally{$csvReader.Dispose()};Check (@($csv|Where-Object ReportDate -ceq '2025-02-03').Count -eq 2) 'The CSV inventory uses the same accepted content date';foreach($entry in $pdfs){$stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create();try{$fingerprint=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','');Check (@($baseline.Records|Where-Object hash -ceq $fingerprint).Count -gt 0) 'Every exported PDF retains an original verified fingerprint'}finally{$stream.Dispose();$sha.Dispose()}}}finally{$zip.Dispose()}
    Preserve
}
Scenario 'Undo restores pending despite a mapping and Disapprove remains authoritative on cached reanalysis' {
    $last=(Snapshot).lastDecision;$undo=Request @{action='Undo';id=$last.recordId;reviewId=$last.reviewId;stamp=$last.stamp}
    Check ((Record 'basic').pending) 'Undo explicitly restores pending even when a recognized profile has a mapping'
    Check ((Record 'basic').category -eq 'Daily') 'Undo retains the visible content-derived Daily suggestion instead of reverting to raw Other'
    $restored=Record 'basic';[void](Request @{action='Approve';id=$restored.id;stamp=$restored.stamp});Check ((Record 'basic').category -eq 'Daily' -and (Record 'basic').decision -eq 'Approved') 'Reapproving the restored suggestion files it as Daily again'
    $again=(Snapshot).lastDecision;[void](Request @{action='Undo';id=$again.recordId;reviewId=$again.reviewId;stamp=$again.stamp})
    $row=Record 'basic';[void](Request @{action='Disapprove';id=$row.id;stamp=$row.stamp});[void](Read-One 'basic');$after=Record 'basic'
    Check ($after.decision -eq 'Disapproved' -and $after.category -eq 'Other' -and -not $after.pending) 'A cached content read does not override Disapprove'
    Check ($after.date -eq '2025-02-03') 'Document decisions preserve the independently accepted date'
    Preserve
}
Scenario 'Warm selected reads reuse the current classifier cache and stale legacy entries trigger one bounded upgrade read' {
    $original=Original 'extended';$cache=Join-Path $baseline.ArchiveRoot ('.ctqa/analysis/'+$original.hash+'.json');$before=(Get-FileHash $cache).Hash
    $warm=Read-One 'extended';Check ($warm.result.Analyzed -eq 0 -and $warm.result.Cached -ge 1) 'An unchanged selected PDF is not parsed again';Check ((Get-FileHash $cache).Hash -ceq $before) 'The warm read leaves the stored content evidence unchanged'
    $row=[IO.File]::ReadAllText($cache)|ConvertFrom-Json;$row.PSObject.Properties.Remove('DocumentClassification');[IO.File]::WriteAllText($cache,($row|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true))
    $upgrade=Read-One 'extended';Check ($upgrade.result.Analyzed -eq 1 -and @($upgrade.result.AnalyzedIds).Count -eq 1) 'Only the requested stale classifier entry is reread once';Check ((Record 'extended').content.status -eq 'Recognized') 'The upgraded entry contains recognized current content evidence'
    $again=Read-One 'extended';Check ($again.result.Analyzed -eq 0) 'The upgraded cache is reused on subsequent reads'
    [void](Map-Profiles '' '');Check ((Mapping 'CT_Edge' 'siemens-iec-extended-v1') -eq '' -and (Record 'extended').pending) 'Choosing Ask clears a previously automatic scanner mapping'
    [void](Map-Profiles 'Daily' 'Monthly')
    Preserve
}
Scenario 'Changed archived bytes cannot reuse content evidence or create a successful new analysis' {
    $original=Original 'extended';$bytes=[IO.File]::ReadAllBytes($original.destination);$stamp=(Get-Item $original.destination).LastWriteTimeUtc
    try{$changed=[byte[]]$bytes.Clone();$changed[30]=$changed[30] -bxor 1;[IO.File]::WriteAllBytes($original.destination,$changed);(Get-Item $original.destination).LastWriteTimeUtc=$stamp.AddSeconds(1)
        Check ((Record 'extended').content.status -ne 'Recognized') 'A changed destination invalidates its saved content evidence'
        $result=Read-One 'extended';Check ($result.result.Failed -eq 1) 'The indexed SHA-256 mismatch prevents successful content analysis';Check ((Record 'extended').content.status -eq 'ReadError') 'The failed verified read remains visible'
    }finally{[IO.File]::WriteAllBytes($original.destination,$bytes);(Get-Item $original.destination).LastWriteTimeUtc=$stamp}
    Preserve
}
Scenario 'Conflicting footer dates cannot bypass review through an explicit Monthly filename and matching profile rule' {
    [void](Map-Profiles 'Monthly' 'Monthly');[void](Read-One 'monthlyFilenameConflict');$row=Record 'monthlyFilenameConflict'
    Check ($row.content.profileId -eq 'siemens-iec-basic-v1' -and $row.content.dateStatus -eq 'Conflict') 'The complete numbered Basic profile retains the actual conflicting page-footer evidence'
    Check ($row.pending -and $row.content.status -eq 'NeedsReview') 'An explicit Monthly filename cannot auto-organize a document whose footer dates conflict'
    Check ($row.date -eq '2025-02-03') 'The original indexed filename date remains intact while the conflicting report stays pending'
    Preserve
}
Scenario 'An explicit Daily document title conflicts with a saved Monthly profile rule even when the filename is generic' {
    [void](Map-Profiles '' '');[void](Read-One 'explicitDailyTitle');$initial=Record 'explicitDailyTitle'
    Check ($initial.category -eq 'Daily' -and -not $initial.pending -and $initial.content.mappedCategory -eq '') 'A verified explicit Daily title can file its own document without teaching a profile mapping'
    [void](Map-Profiles 'Monthly' 'Monthly');$row=Record 'explicitDailyTitle'
    Check ($row.pending -and $row.content.status -eq 'NeedsReview') 'A saved Monthly mapping cannot silently override the printed Daily title'
    Check ($row.content.reason -match 'conflict|disagree') 'The content inspector explains the disagreement between the printed title and configured rule'
    Preserve
}
Scenario 'A compatible Flash PDF upgrades a prior unknown-template cache and follows one saved scanner filing rule' {
    $cfg=Read-QaConfig $FixtureRoot
    $flashDefinition=$fixtureAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-ContentPdf'},$true).Extent.Text.Replace('SOMATOM Definition Edge','SOMATOM Definition Flash')
    . ([scriptblock]::Create($flashDefinition))
    $name='Unlabelled_Compatible_Flash_IEC.pdf';New-ContentPdf -Path (Join-Path $cfg.Sources[1].Path $name) -Profile Basic -Pages 3 -Date '2025-02-03' -Time '14:00:00' -Model 'Flash'
    [void](Invoke-QaOperation $cfg -Mode Update);$raw=@((Get-QaDashboard $cfg).Records|Where-Object OriginalFileName -ceq $name)[0]
    $baseline.Records+=@([pscustomobject]@{key='compatibleFlash';id=$raw.Id;hash=$raw.Hash;scanner=$raw.Scanner;source=$raw.SourcePath;destination=$raw.DestinationPath;rawDate=$raw.ReportDate;rawCategory=$raw.Category;pages=3;profile='Basic';expectedDate='2025-02-03';expectedTime='14:00:00'})
    $baseline.StateSHA256=(Get-FileHash (Join-Path $baseline.ArchiveRoot '.ctqa/state.json')).Hash
    [void](Request @{action='Analyze';id=$raw.Id});$initial=Record 'compatibleFlash'
    Check ($initial.content.status -ceq 'Recognized' -and $initial.content.profileId -ceq 'siemens-iec-basic-v1' -and $initial.pending) 'The real PDF reader recognizes the complete Flash body but does not invent a department filing convention'
    $cached=&(Get-Module WebService){param($c,$r) Get-QaSavedAnalysis $c $r} $cfg $raw
    Check ($cached.DocumentClassification.Model -ceq 'SOMATOM Definition Flash') 'The generated real PDF actually contains the Flash model header'
    $cached.PSObject.Properties.Remove('ContentSupportRevision');$cached.DocumentClassification.PSObject.Properties.Remove('SupportRevision');$cached.DocumentClassification.Model='';$cached.DocumentClassification.Status='NeedsReview';$cached.DocumentClassification.ProfileId='';$cached.DocumentClassification.ReasonCode='UnknownTemplate'
    $cachePath=Join-Path $cfg.ArchiveRoot ('.ctqa/analysis/'+$raw.Hash+'.json');[IO.File]::WriteAllText($cachePath,($cached|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding $true))
    $plan=&(Get-Module WebService){param($c,$id) Get-QaAnalysisWorkPlan -Config $c -RecordIds @($id) -RefreshUnsupported} $cfg $raw.Id
    Check ($plan.Pending -eq 1 -and $plan.UnsupportedUpgradePending -eq 1) 'The earlier unsupported cache is eligible for one explicit format-support upgrade'
    $refreshed=&(Get-Module WebService){param($c,$id) Invoke-QaAnalysis -Config $c -RecordIds @($id) -RefreshUnsupported} $cfg $raw.Id
    Check ($refreshed.Analyzed -eq 1 -and (Record 'compatibleFlash').content.status -ceq 'Recognized') 'A verified selected support refresh replaces the old unsupported result'
    [void](Request @{action='ScannerSettings';scanner=$raw.Scanner;contentProfiles=@([pscustomobject]@{profileId='siemens-iec-basic-v1';category='Daily'},[pscustomobject]@{profileId='siemens-iec-extended-v1';category='Monthly'})})
    $filed=Record 'compatibleFlash'
    Check ($filed.category -ceq 'Daily' -and $filed.decision -ceq 'Automatic' -and -not $filed.pending) 'One explicit per-scanner rule files matching Flash content without an individual approval'
    Check ($filed.clinicalComponents.Count -eq 0 -and $filed.printedResult -ceq 'Not inferred from file classification') 'Automatic filing supplies no formal clinical checklist or PASS'
    $before=(Get-FileHash $cachePath).Hash;$warm=&(Get-Module WebService){param($c,$id) Invoke-QaAnalysis -Config $c -RecordIds @($id) -UpgradeMeasurements -RefreshUnsupported} (Read-QaConfig $FixtureRoot) $raw.Id
    Check ($warm.Analyzed -eq 0 -and $warm.Cached -eq 1 -and (Get-FileHash $cachePath).Hash -ceq $before) 'The completed support revision and measurement pass are reused without another parse or cache write'
    Preserve
}

Scenario 'Real Drive Additional and manufacturer Daily PDFs retain separate filing rules and protected original evidence' {
    $cfg=Read-QaConfig $FixtureRoot;$scanner=[string]$cfg.Sources[2].Scanner
    $originalDefinition=$fixtureAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-ContentPdf'},$true).Extent.Text
    $originalHeader=@'
[void]$lines.Add(('SOMATOM Definition '+$Model))
'@
    $driveHeader=@'
[void]$lines.Add('SOMATOM Drive')
'@
    $driveDefinition=$originalDefinition.Replace($originalHeader.Trim(),$driveHeader.Trim())
    Check ($driveDefinition -cne $originalDefinition) 'The disposable real-PDF fixture explicitly emits the Drive model header'
    $additionalDefinition=$driveDefinition.Replace("@('Lightmarker','External Lightm.','Sag./Cor. Lightm.','Topogram Pos.','Slice','Homogeneity / Water','Noise','MTF','Contrast','Table Position')","@('Lightmarker','Slice','MTF','Contrast','Low Contrast')")
    . ([scriptblock]::Create($additionalDefinition))
    $additionalName='Synthetic_Unlabelled_Drive_Additional.pdf';New-ContentPdf -Path (Join-Path $cfg.Sources[2].Path $additionalName) -Profile Extended -Pages 5 -Date '2025-02-03' -Time '16:00:00'
    $dailyDefinition=$driveDefinition.Replace("@('Homogeneity / Water','Noise')","@('Noise','Homogeneity')").Replace('Quality IEC Constancy','Quality Daily')
    . ([scriptblock]::Create($dailyDefinition))
    $dailyName='Synthetic_Unlabelled_Drive_Document.pdf';New-ContentPdf -Path (Join-Path $cfg.Sources[2].Path $dailyName) -Profile Basic -Pages 4 -Date '2025-02-03' -Time '17:00:00'
    [void](Invoke-QaOperation $cfg -Mode Update);$imported=Get-QaDashboard $cfg
    foreach($spec in @(@{Key='driveAdditional';Name=$additionalName;Pages=5;Time='16:00:00'},@{Key='driveDaily';Name=$dailyName;Pages=4;Time='17:00:00'})){
        $raw=@($imported.Records|Where-Object OriginalFileName -ceq $spec.Name)[0]
        $baseline.Records+=@([pscustomobject]@{key=$spec.Key;id=$raw.Id;hash=$raw.Hash;scanner=$raw.Scanner;source=$raw.SourcePath;destination=$raw.DestinationPath;rawDate=$raw.ReportDate;rawCategory=$raw.Category;pages=$spec.Pages;profile=$spec.Key;expectedDate='2025-02-03';expectedTime=$spec.Time})
    }
    $baseline.StateSHA256=(Get-FileHash (Join-Path $baseline.ArchiveRoot '.ctqa/state.json')).Hash;$baseline.RecordCount=@($imported.Records).Count
    [void](Request @{action='ScannerSettings';scanner=$scanner;contentProfiles=@([pscustomobject]@{profileId='siemens-iec-basic-v1';category=''},[pscustomobject]@{profileId='siemens-iec-extended-v1';category=''},[pscustomobject]@{profileId='siemens-iec-additional-v1';category=''})})
    [void](Read-One 'driveAdditional');[void](Read-One 'driveDaily');$additional=Record 'driveAdditional';$daily=Record 'driveDaily'
    Check ($additional.content.status -ceq 'Recognized' -and $additional.content.profileId -ceq 'siemens-iec-additional-v1' -and $additional.content.components.Count -eq 5) 'The actual reader identifies all five known numbered Drive additional test bodies'
    Check ($additional.pending -and $additional.content.mappedCategory -ceq '' -and $additional.content.suggestedCategory -ceq 'Monthly') 'Additional IEC checks remain Ask until a department filing rule is explicitly configured'
    Check (@($additional.content.components|Where-Object name -ceq 'Low contrast').Count -eq 1) 'The reader and facade retain Low contrast as its own supported section'
    Check ($daily.content.status -ceq 'Recognized' -and $daily.content.profileId -ceq 'siemens-quality-daily-v1' -and $daily.category -ceq 'Daily' -and $daily.decision -ceq 'Automatic' -and -not $daily.pending) 'The exact manufacturer Quality Daily body files automatically without a department profile mapping'
    Check ($daily.content.mappedCategory -ceq '' -and $daily.content.dateStatus -ceq 'Consensus' -and $daily.date -ceq '2025-02-03') 'Explicit Daily classification still requires a complete matching footer date'
    foreach($key in @('driveAdditional','driveDaily')){
        $raw=@($imported.Records|Where-Object Id -ceq (Original $key).id)[0];$cached=&(Get-Module WebService){param($c,$r) Get-QaSavedAnalysis $c $r} $cfg $raw
        Check ($cached.DocumentClassification.Model -ceq 'SOMATOM Drive') 'Both actual synthetic PDFs carry the exact Drive header through the real reader'
    }
    [void](Request @{action='ScannerSettings';scanner=$scanner;contentProfiles=@([pscustomobject]@{profileId='siemens-iec-basic-v1';category=''},[pscustomobject]@{profileId='siemens-iec-extended-v1';category=''},[pscustomobject]@{profileId='siemens-iec-additional-v1';category='Monthly'})})
    $additional=Record 'driveAdditional';$daily=Record 'driveDaily'
    Check ($additional.category -ceq 'Monthly' -and $additional.decision -ceq 'Automatic' -and -not $additional.pending) 'One explicit third-format rule files the already-read Additional PDF without individual approval or rereading'
    Check ($daily.category -ceq 'Daily' -and -not $daily.pending -and (Mapping $scanner 'siemens-iec-additional-v1') -ceq 'Monthly') 'The additional rule remains separate from the explicit Daily document family'
    foreach($row in @($additional,$daily)){Check ($row.clinicalComponents.Count -eq 0 -and $row.printedResult -ceq 'Not inferred from file classification') 'Document filing adds no clinical checklist sign-off or overall QA outcome'}
    $export=Request @{action='Export';ids=@((Original 'driveAdditional').id,(Original 'driveDaily').id)}
    Add-Type -AssemblyName System.IO.Compression.FileSystem;$archive=[IO.Compression.ZipFile]::OpenRead($export.path)
    try{
        $pdfs=@($archive.Entries|Where-Object FullName -match '\.pdf$')
        Check ($pdfs.Count -eq 2 -and @($pdfs|Where-Object FullName -match '/Daily/').Count -eq 1 -and @($pdfs|Where-Object FullName -match '/Monthly/').Count -eq 1) 'Both real PDFs export in their independent derived Daily and Monthly folders'
        foreach($entry in $pdfs){$stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','');Check ($hash -cin @((Original 'driveAdditional').hash,(Original 'driveDaily').hash)) 'Exported PDFs retain one of the two exact original byte fingerprints'}finally{$sha.Dispose();$stream.Dispose()}}
    }finally{$archive.Dispose()}
    Preserve
}

$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$summary=[pscustomobject]@{Product='CT QA Manager Pro';Feature='Offline content classification integration';Runtime=$PSVersionTable.PSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5);SyntheticOnly=$true;Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Actual PDF reader, isolated analysis worker, content classifier, per-scanner settings, durable file decisions, readable library and ZIP export. Generated PDFs only; page count is deliberately decoupled from body profile. Core clinical state and original files are preserved.'}
if($OutputPath){[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath)));[IO.File]::WriteAllText($OutputPath,($summary|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $false))}
Write-Host ('Result: '+($summary.Tests-$failed)+'/'+$summary.Tests+' scenarios; '+$summary.Assertions+' assertions.')
if($ownFixture){Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}
if($failed){exit 1}
