[CmdletBinding()]param([string]$OutputPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProductRoot 'App/WebService.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
Import-Module (Join-Path $ProductRoot 'App/Archive.psm1') -DisableNameChecking -WarningAction SilentlyContinue
$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_WebTests_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($TestRoot)
$script:Results=New-Object 'Collections.Generic.List[object]';$script:Assertions=0
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS '+$Name)}catch{[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=($_.Exception.Message+' / '+$_.ScriptStackTrace)});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Run-Tests.ps1'),[ref]$null,[ref]$null)
foreach($name in @('New-TestConfig','New-TestPdf','Add-Report','Import-Fixture')){$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);. ([scriptblock]::Create($fn.Extent.Text))}
function New-WebFixture([string]$Name){
    $cfg=New-TestConfig $Name;[void][IO.Directory]::CreateDirectory((Join-Path $cfg.AppRoot 'Config'))
    Copy-Item (Join-Path $ProductRoot 'Config/Settings.json') (Join-Path $cfg.AppRoot 'Config/Settings.json')
    foreach($s in $cfg.Sources){$s.DailySchedule='Off';$s.ExpectedMonthly=$false};$cfg.Sources[0].ExpectedMonthly=$true;$cfg.Sources[0]|Add-Member MonthlyChecklist @('MTF','Slice thickness') -Force
    $cfg|ConvertTo-Json -Depth 15|Set-Content (Join-Path $cfg.AppRoot 'Config/Settings.json') -Encoding UTF8
    [void](Save-QaConfig $cfg.AppRoot $cfg)
    $source=Add-Report $cfg 'CT_Edge' 'Quality_Constancy' (Get-Date).ToString('yyyy-MM-dd') '08-00-00' 95000
    [void](Import-Fixture $cfg);$core=@((Get-QaDashboard $cfg).Records)[0]
    return [pscustomobject]@{Config=$cfg;AppRoot=$cfg.AppRoot;Record=$core;Source=$source;SourceHash=(Get-FileHash $source).Hash;StatePath=(Join-Path $cfg.ArchiveRoot '.ctqa/state.json')}
}
function Get-Web($Fixture){return Invoke-QaWebRequest $Fixture.AppRoot ([pscustomobject]@{action='Snapshot'})}
function Decide-Web($Fixture,[string]$Action='Approve'){$record=@((Get-Web $Fixture).records)[0];return Invoke-QaWebRequest $Fixture.AppRoot ([pscustomobject]@{action=$Action;id=$record.id;stamp=$record.stamp})}
Scenario 'Approve is one action without reviewer fields and leaves core clinical evidence unchanged' {
    $f=New-WebFixture 'Approve';$before=(Get-FileHash $f.StatePath).Hash;$initial=Get-Web $f
    Check ($initial.records.Count -eq 1 -and $initial.records[0].pending) 'Monthly candidate is initially pending'
    $result=Decide-Web $f
    Check ($result.snapshot.records[0].decision -eq 'Approved' -and -not $result.snapshot.records[0].pending) 'Approve clears pending without reviewer or authorization fields'
    Check ($result.snapshot.records[0].category -eq 'Monthly') 'Suggested Monthly document type retained'
    Check ((Get-FileHash $f.StatePath).Hash -eq $before) 'Authoritative clinical archive state is byte-for-byte unchanged'
    $coverage=@(Get-QaMonthlyCoverage $f.Config -Records @((Get-QaDashboard $f.Config).Records) -Months @((Get-Date).ToString('yyyy-MM'))|Where-Object Scanner -eq 'CT_Edge')[0]
    Check ($coverage.ConfirmedReportCount -eq 0) 'Classification does not fabricate reviewed Monthly evidence'
    Check ((Get-FileHash $f.Source).Hash -eq $f.SourceHash) 'Scanner original stays untouched'
    Check ([IO.Directory]::Exists($result.snapshot.libraryRoot)) 'Readable library created'
}
Scenario 'Disapprove retains the PDF under Other and stays resolved across restart and unchanged import' {
    $f=New-WebFixture 'Disapprove';$before=(Get-FileHash $f.StatePath).Hash;$result=Decide-Web $f 'Disapprove'
    Check ($result.snapshot.records[0].category -eq 'Other' -and -not $result.snapshot.records[0].pending) 'Disapprove clears suggestion and keeps Other document'
    Check ([IO.File]::Exists($f.Record.DestinationPath)) 'Verified PDF retained'
    [void](Invoke-QaOperation $f.Config -Mode Update);$again=Get-Web $f
    Check ($again.records[0].decision -eq 'Disapproved' -and -not $again.records[0].pending) 'Fresh process-style reload and unchanged scanner import do not resurrect suggestion'
    Check ((Get-FileHash $f.Source).Hash -eq $f.SourceHash) 'Source bytes unchanged'
    $copies=@(Get-ChildItem $again.libraryRoot -Filter '*.pdf' -Recurse)
    Check ($copies.Count -eq 1 -and $copies[0].FullName -match '[\\/]Other[\\/]') 'Readable Other folder exists'
}
Scenario 'Undo after reload restores pending while preserving a separate append-only action history' {
    $f=New-WebFixture 'Undo';$before=(Get-FileHash $f.StatePath).Hash;$approved=Decide-Web $f;$last=(Get-Web $f).lastDecision
    $undo=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Undo';id=$last.recordId;reviewId=$last.reviewId;stamp=$last.stamp})
    Check $undo.snapshot.records[0].pending 'Undo returns the candidate to pending'
    Check ((Get-FileHash $f.StatePath).Hash -eq $before) 'Undo does not edit clinical confirmation fields'
    $org=Get-Content (Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json') -Raw|ConvertFrom-Json
    Check ($null -eq $undo.snapshot.lastDecision) 'Undo is not incorrectly offered as another undoable approval'
    Check ($org.History.Count -eq 2 -and $org.History[1].action -eq 'Undo') 'Undo appends rather than deleting the original action'
    Check ($org.History[0].actorKind -like '*not a verified*') 'Automatic activity actor is truthfully labeled'
}
Scenario 'Stale actions and changed PDFs cannot overwrite decisions' {
    $f=New-WebFixture 'Stale';$record=(Get-Web $f).records[0];[void](Decide-Web $f)
    $path=Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json';$before=(Get-FileHash $path).Hash;$caught=$false
    try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Disapprove';id=$record.id;stamp=$record.stamp})|Out-Null}catch{$caught=$true}
    Check ($caught -and (Get-FileHash $path).Hash -eq $before) 'Old decision rejected without changing history'
    $fresh=New-WebFixture 'Changed';[IO.File]::AppendAllText($fresh.Record.DestinationPath,'edited');$caught=$false
    try{Decide-Web $fresh|Out-Null}catch{$caught=$true};Check $caught 'A saved PDF must still match its fingerprint'
    Check (-not [IO.File]::Exists((Join-Path $fresh.Config.ArchiveRoot '.ctqa/organization.json'))) 'No decision history committed for edited bytes'
}
Scenario 'Classification export includes all chosen PDFs, readable folders, CSV and HTML without inventing clinical approval' {
    $f=New-WebFixture 'Export';$result=Decide-Web $f
    $export=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Export';ids=@($f.Record.Id)})
    Check ([IO.File]::Exists($export.path)) 'ZIP was produced'
    Add-Type -AssemblyName System.IO.Compression.FileSystem;$zip=[IO.Compression.ZipFile]::OpenRead($export.path)
    try{
        Check (@($zip.Entries|Where-Object{$_.FullName -match '/Monthly/.*\.pdf$'}).Count -eq 1) 'Categorized Monthly PDF exported without a fake clinical reviewer'
        Check ($null -ne $zip.GetEntry('Report Summary.html') -and $null -ne $zip.GetEntry('Report list.csv')) 'Offline summary and full inventory included'
        $reader=New-Object IO.StreamReader($zip.GetEntry('Report list.csv').Open());try{$csv=$reader.ReadToEnd()}finally{$reader.Dispose()}
        Check ($csv -match 'ClinicalReviewer' -and $csv -match 'VerifiedChecklistItems' -and $csv -match 'Not inferred from classification') 'Formal evidence fields and scope remain explicit'
    }finally{$zip.Dispose()}
}
Scenario 'An existing unowned readable PDF is never adopted, overwritten or retired' {
    $f=New-WebFixture 'Unowned';$relative=&(Get-Module WebService){param($record) Get-QaWebRelative $record 'Monthly' 'CT Edge'} $f.Record
    $root=Join-Path $f.Config.ArchiveRoot 'Report Library';$unowned=Join-Path $root $relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($unowned));[IO.File]::Copy($f.Record.DestinationPath,$unowned)
    [void](Decide-Web $f);$hash=(Get-FileHash $unowned).Hash;$last=(Get-Web $f).lastDecision
    [void](Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Undo';id=$last.recordId;reviewId=$last.reviewId;stamp=$last.stamp}))
    Check ([IO.File]::Exists($unowned) -and (Get-FileHash $unowned).Hash -eq $hash) 'Unowned same-content file survives classification and Undo'
    $index=Get-Content (Join-Path $f.Config.ArchiveRoot '.ctqa/web-library.json') -Raw|ConvertFrom-Json
    Check ($index.Records[0].relative -cne $relative) 'Owned copy has a distinct tracked path'
}
Scenario 'Malformed organization history is preserved rather than reset' {
    $f=New-WebFixture 'Corrupt';$path=Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json';[IO.File]::WriteAllText($path,'not-json');$before=(Get-FileHash $path).Hash;$caught=$false
    try{Get-Web $f|Out-Null}catch{$caught=$true};Check ($caught -and (Get-FileHash $path).Hash -eq $before) 'Corrupt history is never silently replaced'
}
Scenario 'Tampered organization types cannot become filesystem or ZIP paths' {
    $f=New-WebFixture 'TamperedType';[void](Decide-Web $f)
    $path=Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json';$state=Get-Content $path -Raw|ConvertFrom-Json;$state.Records[0].category='../../Outside';$state|ConvertTo-Json -Depth 30|Set-Content $path -Encoding UTF8
    $before=(Get-FileHash $path).Hash;$caught=$false;try{Get-Web $f|Out-Null}catch{$caught=$true}
    Check ($caught -and (Get-FileHash $path).Hash -eq $before) 'Invalid category metadata is refused without replacing it'
    Check (-not [IO.Directory]::Exists((Join-Path $f.Config.ArchiveRoot 'Outside'))) 'No traversal directory is created'
}
Scenario 'Only selected report IDs resolve to verified local PDFs' {
    $f=New-WebFixture 'Pdf';$response=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Pdf';id=$f.Record.Id})
    Check ($response.path -eq $f.Record.DestinationPath) 'Opaque record identity resolves the verified PDF'
    $caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Pdf';id='../Config/Settings.json'})|Out-Null}catch{$caught=$true};Check $caught 'Client paths cannot be used as record identities'
    $caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='RunPowerShell';command='Get-Process'})|Out-Null}catch{$caught=$true};Check $caught 'Arbitrary shell operations are not allowed'
}
Scenario 'The JSON worker supports stdin and stdout without logging request content' {
    $f=New-WebFixture 'Worker';$info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=(Get-Process -Id $PID).Path;$info.Arguments='-NoProfile -File "'+(Join-Path $ProductRoot 'App/WebWorker.ps1')+'" -AppRoot "'+$f.AppRoot+'" -InputPath stdin -OutputPath stdout';$info.UseShellExecute=$false;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    try{$process.StandardInput.Write('{"action":"Snapshot"}');$process.StandardInput.Close();$text=$process.StandardOutput.ReadToEnd();$errors=$process.StandardError.ReadToEnd();[void]$process.WaitForExit();$response=$text|ConvertFrom-Json;if($null -eq $response -or $null -eq $response.PSObject.Properties['success']){throw ('Worker returned no JSON envelope. Exit='+$process.ExitCode+'; stdoutLength='+$text.Length+'; stderr='+$errors.Trim())};$detail=if($response.success){'success'}else{[string]$response.error.message};Check ($process.ExitCode -eq 0 -and $response.success -and $response.value.records.Count -eq 1) ('Only a valid JSON envelope appears on stdout: '+$detail);Check ([string]::IsNullOrWhiteSpace($errors)) 'No noisy module output reaches stderr'}finally{$process.Dispose()}
}
Scenario 'Scanner settings retain historical checklist rules and existing record ownership' {
    $f=New-WebFixture 'ScannerSettings';$before=(Get-FileHash $f.StatePath).Hash
    $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='ScannerSettings';scanner='CT_Edge';name='Renamed synthetic scanner';checklist=@('MTF');checklistEffectiveMonth='2099-01';monthlyDueDay=18})
    Check ($result.snapshot.scanners[0].name -eq 'Renamed synthetic scanner' -and $result.snapshot.scanners[0].monthlyDueDay -eq 18) 'Department settings are usable from the new interface'
    $saved=Read-QaConfig $f.AppRoot;$coverage=@(Get-QaMonthlyCoverage $saved -Records @((Get-QaDashboard $saved).Records) -Months @((Get-Date).ToString('yyyy-MM'))|Where-Object Scanner -eq 'CT_Edge')[0]
    Check ($coverage.RequiredComponents.Count -eq 2) 'Future checklist edit does not rewrite current-month requirements'
    Check ((Get-FileHash $f.StatePath).Hash -eq $before) 'Settings edit does not rewrite archived evidence'
}
Scenario 'Existing formal clinical checklist evidence remains in exported inventories' {
    $f=New-WebFixture 'LegacyEvidence'
    $decision=[pscustomobject]@{RecordId=$f.Record.Id;Hash=$f.Record.Hash;Category='Monthly_QA';Reviewer='Synthetic prior reviewer';Reason='Synthetic checked PDF';ConfirmedComponents=@('MTF')}
    [void](Invoke-QaOperation $f.Config -Mode Reclassify -Decisions @($decision));$before=(Get-FileHash $f.StatePath).Hash
    $snapshot=Get-Web $f;Check ($snapshot.records[0].clinicalComponents -contains 'MTF') 'Previous verified evidence remains visible'
    $export=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Export';ids=@($f.Record.Id)})
    $zip=[IO.Compression.ZipFile]::OpenRead($export.path)
    try{$reader=New-Object IO.StreamReader($zip.GetEntry('Report list.csv').Open());try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()};$row=@($text|ConvertFrom-Csv)[0];Check ($row.ClinicalReviewer -eq 'Synthetic prior reviewer' -and $row.VerifiedChecklistItems -eq 'MTF') 'CSV retains actual previously reviewed identity and checklist items'}finally{$zip.Dispose()}
    Check ((Get-FileHash $f.StatePath).Hash -eq $before) 'Export does not reclassify or change legacy evidence'
}
Scenario 'An inaccessible fresh workspace is not marked as successfully set up' {
    $cfg=New-TestConfig 'OfflineFirstRun';[void][IO.Directory]::CreateDirectory((Join-Path $cfg.AppRoot 'Config'))
    $cfg|ConvertTo-Json -Depth 15|Set-Content (Join-Path $cfg.AppRoot 'Config/Settings.json') -Encoding UTF8
    foreach($source in $cfg.Sources){[IO.Directory]::Move($source.Path,($source.Path+'.offline'))}
    $result=Invoke-QaWebRequest $cfg.AppRoot ([pscustomobject]@{action='Refresh'})
    Check (-not $result.snapshot.setupComplete -and $result.snapshot.records.Count -eq 0) 'No accessible source means setup remains incomplete'
    Check (-not [IO.File]::Exists((Join-Path $cfg.ArchiveRoot '.ctqa/state.json'))) 'Empty import is not committed as a new successful archive'
    Check ($result.warning -like '*not been completed*') 'The user receives actionable connection guidance'
}
Scenario 'The web worker records scrubbed action outcomes without retaining request secrets' {
    $f=New-WebFixture 'WorkerLogs';$record=(Get-Web $f).records[0];$canary='SyntheticNeverLogRequestSecret_73d892'
    $request=[pscustomobject]@{action='Approve';id=$record.id;stamp=$record.stamp;password=$canary}|ConvertTo-Json -Compress
    $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=(Get-Process -Id $PID).Path;$info.Arguments='-NoProfile -File "'+(Join-Path $ProductRoot 'App/WebWorker.ps1')+'" -AppRoot "'+$f.AppRoot+'" -InputPath stdin -OutputPath stdout';$info.UseShellExecute=$false;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    try{$process.StandardInput.Write($request);$process.StandardInput.Close();$output=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd();[void]$process.WaitForExit();$response=$output|ConvertFrom-Json;if($null -eq $response -or $null -eq $response.PSObject.Properties['success']){throw ('Worker returned no JSON envelope. Exit='+$process.ExitCode+'; stdoutLength='+$output.Length+'; stderr='+$stderr.Trim())};$detail=if($response.success){'success'}else{[string]$response.error.message};Check ($process.ExitCode -eq 0 -and $response.success) ('Worker saves the expected classification: '+$detail);Check (-not $output.Contains($canary) -and -not $stderr.Contains($canary)) 'Request data is not echoed to process output'}finally{$process.Dispose()}
    $bundle=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Diagnostics'});$zip=[IO.Compression.ZipFile]::OpenRead($bundle.path);$all=''
    try{foreach($entry in $zip.Entries){$reader=New-Object IO.StreamReader($entry.Open());try{$text=$reader.ReadToEnd();Check (-not $text.Contains($canary)) 'Every scrubbed ZIP entry excludes the request canary';$all+=$text}finally{$reader.Dispose()}}}finally{$zip.Dispose()}
    Check ($all -match 'Reclassify' -and $all -match 'Completed') 'Retained worker action outcomes appear in the shareable logs'
}
if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
    Scenario 'Manual scanner folder and sign-in edits survive Save and connect plus later startup' {
        $f=New-WebFixture 'ManualWindowsConnection';$before=(Get-FileHash $f.StatePath).Hash
        $profile=[pscustomobject]@{Version=1;Connections=@([pscustomobject]@{Scanner='CT_Edge';Path='\\SYNTHETIC-PROFILE\SiteData\ConstancyReports';Username='SyntheticProfileAccount'})}
        $profile|ConvertTo-Json -Depth 6|Set-Content (Join-Path $f.AppRoot 'Config/NetworkProfile.local.json') -Encoding UTF8
        $module=Get-Module WebService;$original=& $module { (Get-Command Reconnect-QaScanner).ScriptBlock }
        try{
            & $module {
                $script:ManualReconnectSeen=$null
                function script:Reconnect-QaScanner {param($Scanner,$Credential)
                    $script:ManualReconnectSeen=[pscustomobject]@{path=$Scanner.Path;username=$Credential.UserName;passwordLength=$Credential.Password.Length}
                    return [pscustomobject]@{Scanner=$Scanner.Scanner;Status='Connected';Message='Synthetic connection boundary accepted; no scanner contacted.';DriveLetter=$Scanner.DriveLetter;NativeCode=0}
                }
            }
            $requestedPath='\\SYNTHETIC-MANUAL\SiteData\ConstancyReports';$requestedName='SyntheticManualAccount';$password='SyntheticCredentialOnly_48c1'
            $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Reconnect';scanner='CT_Edge';path=$requestedPath;username=$requestedName;password=$password;remember=$false})
            $seen=& $module {$script:ManualReconnectSeen}
            Check ($seen.path -ceq $requestedPath -and $seen.username -ceq $requestedName -and $seen.passwordLength -eq $password.Length) 'Save and connect passes the newly edited folder and secure sign-in to the network boundary'
            Check ($result.snapshot.scanners[0].path -ceq $requestedPath -and $result.snapshot.scanners[0].username -ceq $requestedName) 'The returned snapshot retains the manual field values'
            $local=Join-Path $f.AppRoot 'Config/Settings.local.json';$saved=Get-Content $local -Raw|ConvertFrom-Json
            Check ($saved.Sources[0].Path -ceq $requestedPath -and $saved.Sources[0].Username -ceq $requestedName) 'Edited values are actually persisted rather than only displayed'
            Check (-not ([IO.File]::ReadAllText($local)).Contains($password)) 'The password is not written to the settings document'
            $hash=(Get-FileHash $local).Hash;$later=Get-Web $f
            Check ($later.scanners[0].path -ceq $requestedPath -and $later.scanners[0].username -ceq $requestedName -and (Get-FileHash $local).Hash -ceq $hash) 'A later startup does not replace custom values with the bundled profile'
            Check ((Get-FileHash $f.StatePath).Hash -ceq $before) 'Connection editing leaves the archived report and clinical evidence unchanged'
            Check ((Get-FileHash $f.Source).Hash -ceq $f.SourceHash) 'The original synthetic report is untouched'
        }finally{& $module {param($body) Set-Item -Path Function:script:Reconnect-QaScanner -Value $body;Remove-Variable ManualReconnectSeen -Scope Script -ErrorAction SilentlyContinue} $original}
    }
    Scenario 'The web adapter returns an actual native Windows PDF page' {
        $f=New-WebFixture 'NativeWebPreview';$page=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='PreviewPdf';id=$f.Record.Id;page=0})
        $bytes=[Convert]::FromBase64String($page.PngBase64)
        Check ($page.PageCount -eq 1 -and $page.Hash -eq $f.Record.Hash) 'Preview stays bound to the requested saved PDF'
        Check ($bytes.Length -gt 100 -and [BitConverter]::ToString($bytes,0,8) -eq '89-50-4E-47-0D-0A-1A-0A') 'A real PNG is returned through the new adapter'
        Check ((Get-Web $f).previewMode -eq 'windows') 'Windows clients select the policy-independent native preview path'
    }
}
Scenario 'Standard Daily and explicit Monthly document names are organized automatically without human approval' {
    $f=New-WebFixture 'AutomaticNames';$day=(Get-Date).ToString('yyyy-MM-dd')
    [void](Add-Report $f.Config 'CT_Edge' 'QualityDaily' $day '09-00-00' 1800)
    [void](Add-Report $f.Config 'CT_Edge' 'Quality_Constancy' $day '09-05-00' 1800)
    [void](Add-Report $f.Config 'CT_Edge' 'Monthly_Constancy' $day '09-10-00' 95000)
    $unknown=Join-Path $f.Config.Sources[0].Path 'Unclassified.pdf';[void](New-TestPdf $unknown)
    [void](Invoke-QaOperation $f.Config -Mode Update);$before=(Get-FileHash $f.StatePath).Hash;$snapshot=Get-Web $f
    $automatic=@($snapshot.records|Where-Object decision -eq 'Automatic');$pending=@($snapshot.records|Where-Object pending)
    Check ($automatic.Count -eq 3 -and $pending.Count -eq 2) 'Only size-based Monthly and unknown documents remain pending'
    Check (@($automatic|Where-Object category -eq 'Daily').Count -eq 2 -and @($automatic|Where-Object category -eq 'Monthly').Count -eq 1) 'Standard small Constancy and explicit document names use clear type grouping'
    Check (@($automatic|Where-Object{$_.organizationSource -ne 'automatic' -or $_.decision -eq 'Approved'}).Count -eq 0) 'Automatic grouping is not presented as human approval'
    Check ($snapshot.pendingSummary.automatic -eq 3 -and $snapshot.pendingSummary.pending -eq 2) 'Visible counters use the same pending rules'
    $core=Get-QaDashboard $f.Config
    Check (@($core.Records|Where-Object{$_.ConfirmedBy -or $_.ConfirmedAt -or @($_.ConfirmedComponents).Count}).Count -eq 0) 'No named reviewer, clinical result or checklist evidence was manufactured'
    Check ((Get-FileHash $f.StatePath).Hash -ceq $before -and -not [IO.File]::Exists((Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json'))) 'Automatic display classification does not rewrite historical clinical state or action history'
}
Scenario 'Saved user decisions and valid legacy reviews take precedence over automatic grouping' {
    $f=New-WebFixture 'ClassificationPrecedence';[void](Decide-Web $f 'Disapprove')
    $review=[pscustomobject]@{RecordId=$f.Record.Id;Hash=$f.Record.Hash;Category='Daily_QA';Reviewer='Synthetic historical reviewer';Reason='Existing reviewed record';ConfirmedComponents=@()}
    [void](Invoke-QaOperation $f.Config -Mode Reclassify -Decisions @($review));$before=(Get-FileHash $f.StatePath).Hash;$snapshot=Get-Web $f
    Check ($snapshot.records[0].decision -eq 'Disapproved' -and $snapshot.records[0].category -eq 'Other' -and -not $snapshot.records[0].pending) 'Explicit sidecar decisions are not silently changed by legacy or automatic rules'
    $legacy=New-WebFixture 'LegacyPrecedence';$review.RecordId=$legacy.Record.Id;$review.Hash=$legacy.Record.Hash;$review.Category='Monthly_QA';$review.ConfirmedComponents=@('MTF')
    [void](Invoke-QaOperation $legacy.Config -Mode Reclassify -Decisions @($review));$old=Get-Web $legacy
    Check ($old.records[0].decision -eq 'Approved' -and $old.records[0].organizationSource -eq 'legacy' -and -not $old.records[0].pending) 'A valid historical review remains resolved'
    Check ($old.records[0].clinicalComponents -contains 'MTF') 'Actual previously reviewed evidence is preserved'
    Check ((Get-FileHash $f.StatePath).Hash -ceq $before) 'Classification precedence performs no clinical-state migration'
}
Scenario 'Readable-library refresh batches its ledger and reuses only verified metadata matches' {
    $f=New-WebFixture 'LibraryCache';$module=Get-Module WebService;$dashboard=Get-QaDashboard $f.Config
    $cold=& $module {param($config,$dashboard) Update-QaWebLibrary -Config $config -Dashboard $dashboard} $f.Config $dashboard
    Check ($cold.copied -eq 1 -and $cold.hashedFiles -eq 2 -and $cold.manifestWrites -eq 1) 'New copies are stream-hashed, read back and committed in a single batch ledger'
    $index=Join-Path $f.Config.ArchiveRoot '.ctqa/web-library.json';$hash=(Get-FileHash $index).Hash
    $warm=& $module {param($config,$dashboard) Update-QaWebLibrary -Config $config -Dashboard $dashboard} $f.Config $dashboard
    Check ($warm.unchanged -eq 1 -and $warm.hashedFiles -eq 0 -and $warm.manifestWrites -eq 0 -and (Get-FileHash $index).Hash -ceq $hash) 'An unchanged warm refresh does not reread PDF bytes or rewrite the entire ledger'
    $state=Get-Content $index -Raw|ConvertFrom-Json;$state.Version=1;$state.Records=@($state.Records|Select-Object id,hash,relative,category,original);$state|ConvertTo-Json -Depth 10|Set-Content $index -Encoding UTF8
    $upgraded=& $module {param($config) Update-QaWebLibrary $config} $f.Config
    Check ($upgraded.hashedFiles -eq 2 -and $upgraded.manifestWrites -eq 1) 'Old readable ledgers are verified before receiving the metadata cache'
    $after=& $module {param($config) Update-QaWebLibrary $config} $f.Config
    Check ($after.hashedFiles -eq 0 -and $after.manifestWrites -eq 0) 'The next refresh uses the migrated cache'
}
Scenario 'Full verification catches edited bytes even when length and write time were restored' {
    $f=New-WebFixture 'LibraryAudit';$module=Get-Module WebService;[void](& $module {param($config) Update-QaWebLibrary $config} $f.Config)
    $file=Get-Item $f.Record.DestinationPath;$when=$file.LastWriteTimeUtc;$bytes=[IO.File]::ReadAllBytes($file.FullName);$bytes[$bytes.Length-5]=$bytes[$bytes.Length-5] -bxor 1;[IO.File]::WriteAllBytes($file.FullName,$bytes);[IO.File]::SetLastWriteTimeUtc($file.FullName,$when)
    $quick=& $module {param($config) Update-QaWebLibrary $config} $f.Config
    Check ($quick.hashedFiles -eq 0 -and $quick.metadataFastPath) 'Fast refresh is explicitly a metadata cache, not a new proof of byte integrity'
    $caught=$false;try{& $module {param($config) Update-QaWebLibrary -Config $config -Verify} $f.Config|Out-Null}catch{$caught=$true}
    Check $caught 'An explicit verify always hashes the saved PDF and rejects altered contents'
    $caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Pdf';id=$f.Record.Id})|Out-Null}catch{$caught=$true}
    Check $caught 'Opening a PDF still performs its full fingerprint check'
}
Scenario 'A cancelled library batch commits completed ownership and resumes without duplicate copies' {
    $f=New-WebFixture 'LibraryCancel';[void](Add-Report $f.Config 'CT_Edge' 'QualityDaily' (Get-Date).ToString('yyyy-MM-dd') '09-00-00' 1800);[void](Invoke-QaOperation $f.Config -Mode Update)
    $module=Get-Module WebService;$progress=[hashtable]::Synchronized(@{Cancel=$false;Stage='Preparing';Completed=0;Total=0;Percent=0;Copied=0;Unchanged=0;Failed=0});$original=& $module {(Get-Command Copy-QaWebLibraryPdf).ScriptBlock}
    try{
        & $module {param($body) $script:TestLibraryCopyOriginal=$body;function script:Copy-QaWebLibraryPdf {param($Source,$Target,$Hash,$Progress,$Metrics) & $script:TestLibraryCopyOriginal $Source $Target $Hash $Progress $Metrics;$Progress['Cancel']=$true}} $original
        $partial=& $module {param($config,$progress) Update-QaWebLibrary -Config $config -Progress $progress} $f.Config $progress
        Check ($partial.cancelled -and $partial.completed -eq 1 -and $partial.manifestWrites -eq 1) 'Completed copies receive a committed ledger even when the next item is cancelled'
    }finally{& $module {param($body) Set-Item -Path Function:script:Copy-QaWebLibraryPdf -Value $body;Remove-Variable TestLibraryCopyOriginal -Scope Script -ErrorAction SilentlyContinue} $original}
    $progress.Cancel=$false;$resumed=& $module {param($config,$progress) Update-QaWebLibrary -Config $config -Progress $progress} $f.Config $progress
    Check ($resumed.copied -eq 1 -and $resumed.unchanged -eq 1 -and $resumed.hashedFiles -eq 2) 'Resume reuses the owned completed PDF and copies only the remaining report'
    Check (@(Get-ChildItem (Join-Path $f.Config.ArchiveRoot 'Report Library') -Filter '*.pdf' -Recurse).Count -eq 2) 'Cancellation and resume did not create duplicate readable files'
}

Scenario 'Pre-upgrade approvals retain their decisions and Undo restores their original pending state' {
    $f=New-WebFixture 'UpgradeUndo';$day=(Get-Date).ToString('yyyy-MM-dd');$module=Get-Module WebService
    [void](Add-Report $f.Config 'CT_Edge' 'Quality_Constancy' $day '09-00-00' 1800)
    [void](Add-Report $f.Config 'CT_Edge' 'Monthly_Constancy' $day '09-05-00' 95000)
    [void](Invoke-QaOperation $f.Config -Mode Update);$before=(Get-FileHash $f.StatePath).Hash
    $oldRecords=@((Get-Web $f).records|Where-Object decision -eq 'Automatic');$original=& $module {(Get-Command Get-QaWebClassification).ScriptBlock}
    try{
        & $module {function script:Get-QaWebClassification {param($Record,$Entry) return [pscustomobject]@{category=(Get-QaWebCategory $Record $Entry);pending=(Test-QaReportPending $Record);decision='Pending';source='pending';reason='Synthetic v5.0.1 classification behavior'}}}
        foreach($record in $oldRecords){[void](Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';id=$record.id;stamp=$record.stamp}))}
    }finally{& $module {param($body) Set-Item Function:script:Get-QaWebClassification $body} $original}
    $upgraded=Get-Web $f
    Check (@($upgraded.records|Where-Object decision -eq 'Approved').Count -eq 2) 'Both earlier Daily and explicit Monthly approvals remain resolved after upgrading'
    foreach($old in $oldRecords){$record=@((Get-Web $f).records|Where-Object id -ceq $old.id)[0];[void](Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Undo';id=$record.id;reviewId=$record.reviewId;stamp=$record.stamp}))}
    [void](Invoke-QaOperation $f.Config -Mode Update);$restored=Get-Web $f
    Check (@($restored.records|Where-Object pending).Count -eq 3 -and @($restored.records|Where-Object decision -eq 'Automatic').Count -eq 0) 'Undo restores old pending decisions across restart and unchanged scanner import'
    [void](Add-Report $f.Config 'CT_Edge' 'QualityDaily' $day '10-00-00' 1800);[void](Invoke-QaOperation $f.Config -Mode Update)
    Check (@((Get-Web $f).records|Where-Object decision -eq 'Automatic').Count -eq 1) 'Fresh documents without a restored decision still receive automatic grouping'
    $org=Get-Content (Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json') -Raw|ConvertFrom-Json
    Check ($org.History.Count -eq 4 -and @($org.History|Where-Object action -eq 'Undo').Count -eq 2) 'Upgrade and Undo preserve append-only decisions without inventing a reviewer'
}
Scenario 'Concurrent edits cannot seed a verified source or readable-file metadata cache' {
    $module=Get-Module WebService;$original=& $module {(Get-Command Get-QaWebLibraryHash).ScriptBlock}
    foreach($which in @('source','target','staged')){
        $f=New-WebFixture ('MetadataRace_'+$which);$index=Join-Path $f.Config.ArchiveRoot '.ctqa/web-library.json'
        if($which -ne 'staged'){
            [void](& $module {param($config) Update-QaWebLibrary $config} $f.Config)
            $state=Get-Content $index -Raw|ConvertFrom-Json;$target=Join-Path (Join-Path $f.Config.ArchiveRoot 'Report Library') $state.Records[0].relative;$oldLedger=(Get-FileHash $index).Hash
        }else{$target='';$oldLedger=''}
        $mutate=if($which -eq 'source'){$f.Record.DestinationPath}elseif($which -eq 'target'){$target}else{'*.partial'}
        try{
            & $module {param($body,$path) $script:RaceHashOriginal=$body;$script:RaceMutatePath=$path;$script:RaceDone=$false
                function script:Get-QaWebLibraryHash {param($Path,$Metrics)
                    $hash=& $script:RaceHashOriginal $Path $Metrics
                    if(-not $script:RaceDone -and (($script:RaceMutatePath -eq '*.partial' -and $Path -like '*.partial') -or $Path -ceq $script:RaceMutatePath)){
                        $script:RaceDone=$true;$bytes=[IO.File]::ReadAllBytes($Path);$bytes[$bytes.Length-5]=$bytes[$bytes.Length-5] -bxor 1;[IO.File]::WriteAllBytes($Path,$bytes);[IO.File]::SetLastWriteTimeUtc($Path,[datetime]::UtcNow.AddSeconds(3))
                    };return $hash
                }
            } $original $mutate
            $caught=$false;try{& $module {param($config) Update-QaWebLibrary -Config $config -Verify} $f.Config|Out-Null}catch{$caught=$true}
            Check $caught ('A '+$which+' edit between verified read and metadata refresh is rejected')
        }finally{& $module {param($body) Set-Item Function:script:Get-QaWebLibraryHash $body;Remove-Variable RaceHashOriginal,RaceMutatePath,RaceDone -Scope Script -ErrorAction SilentlyContinue} $original}
        if($which -eq 'staged'){Check (-not [IO.File]::Exists($index)) 'A staged edit never creates a trusted readable-file ownership entry'}else{
            Check ((Get-FileHash $index).Hash -ceq $oldLedger) ('The '+$which+' race does not seed changed metadata under the earlier fingerprint')
            $caught=$false;try{& $module {param($config) Update-QaWebLibrary $config} $f.Config|Out-Null}catch{$caught=$true}
            Check $caught ('The next normal refresh verifies and rejects the '+$which+' edit instead of accepting a warm cache hit')
        }
    }
}

Scenario 'Appearance persists across fresh snapshots without changing report evidence' {
    $f=New-WebFixture 'Appearance';$before=(Get-FileHash $f.StatePath).Hash
    $saved=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Settings';theme='Dark'})
    Check ($saved.snapshot.settings.theme -ceq 'Dark' -and (Get-Web $f).settings.theme -ceq 'Dark') 'Dark appearance survives a fresh config and snapshot load'
    $saved=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Settings';theme='Light'})
    Check ($saved.snapshot.settings.theme -ceq 'Light') 'Light appearance can be restored'
    $caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Settings';theme='unsupported'})|Out-Null}catch{$caught=$true}
    Check ($caught -and (Get-Web $f).settings.theme -ceq 'Light') 'Unsupported appearance is rejected without replacing saved preference'
    Check ((Get-FileHash $f.StatePath).Hash -ceq $before) 'Appearance never edits clinical archive evidence'
}
Scenario 'Explicit empty or conflicting reading groups cannot expand into an archive-wide read' {
    $f=New-WebFixture 'BoundedReadScope';$before=(Get-FileHash $f.StatePath).Hash
    foreach($request in @([pscustomobject]@{action='Analyze';ids=@()},[pscustomobject]@{action='Analyze';ids=$null},[pscustomobject]@{action='Analyze';id=$f.Record.Id;ids=@()},[pscustomobject]@{action='Analyze';ids=@('../not-a-record')})){
        $caught=$false;try{Invoke-QaWebRequest $f.AppRoot $request|Out-Null}catch{$caught=$true};Check $caught 'Explicit invalid or conflicting scope is refused before a PDF is read'
    }
    Check ((Get-FileHash $f.StatePath).Hash -ceq $before) 'Rejected scopes leave authoritative archive bytes untouched'
    Check (-not [IO.Directory]::Exists((Join-Path $f.Config.ArchiveRoot '.ctqa/analysis'))) 'Rejected scopes create no analysis cache'
}
Scenario 'PDF reading chunk limits accept only bounded integers' {
    $f=New-WebFixture 'ReadingLimits'
    foreach($limit in @(0,21,-1,'1',$true,1.5)){
        $caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Analyze';analysisLimit=$limit})|Out-Null}catch{$caught=$true};Check $caught 'Malformed or unbounded reading chunk limit is refused before reading'
    }
}
Scenario 'Trend queries read cached metadata without creating PDF readings or rewriting the archive' {
    $f=New-WebFixture 'TrendQuery';$before=(Get-FileHash $f.StatePath).Hash
    $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Trends';scanner='CT_Edge';metric='WaterCTNumber'})
    Check ($result.schemaVersion -eq 1 -and $result.scanner -ceq 'CT_Edge' -and $result.metric -ceq 'WaterCTNumber') 'Authenticated adapter returns the selected cached trend model'
    Check ($result.points.Count -eq 0 -and $result.coverage.pendingReports -eq 1) 'Unread source stays pending instead of becoming an invented zero reading'
    Check ($result.clinicalResult -ceq 'Not inferred') 'Graph access cannot create clinical approval'
    Check ((Get-FileHash $f.StatePath).Hash -ceq $before) 'Trend queries never rewrite authoritative evidence'
    Check (-not [IO.Directory]::Exists((Join-Path $f.Config.ArchiveRoot '.ctqa/analysis'))) 'Viewing a chart starts no PDF reading work'
    foreach($request in @([pscustomobject]@{action='Trends';metric='Unknown'},[pscustomobject]@{action='Trends';slice='../1'},[pscustomobject]@{action='Trends';start='2026-02-30'},[pscustomobject]@{action='Trends';series=('a'*129)})){
        $caught=$false;try{Invoke-QaWebRequest $f.AppRoot $request|Out-Null}catch{$caught=$true};Check $caught 'Invalid chart filter is refused without reading PDFs'
    }
}

Scenario 'Diagnostic downloads remain available when a verified cache contains malformed numeric fields' {
    $f=New-WebFixture 'DiagnosticMalformedCache';$info=Get-Item $f.Record.DestinationPath;$folder=Join-Path $f.Config.ArchiveRoot '.ctqa/analysis';[void][IO.Directory]::CreateDirectory($folder)
    $row=[pscustomobject]@{ParserVersion=1;AnalysisCacheSchemaVersion=3;DocumentClassifierVersion=1;Hash=$f.Record.Hash;RecordId=$f.Record.Id;VerifiedHash=$f.Record.Hash;VerifiedLength=$info.Length;VerifiedWriteTicks=$info.LastWriteTimeUtc.Ticks;SavedLength=$info.Length;SavedWriteTicks=$info.LastWriteTimeUtc.Ticks;ContentSupportRevision='invalid-integer';Status='NeedsReview';Truncated=$false;DocumentClassification=[pscustomobject]@{ClassifierVersion=1;Status='Recognized';ProfileId='siemens-iec-basic-v1';CompleteRead=$true;ReadPages=3;Pages=3;DateStatus='Missing';ReasonCode='SupportedProfile'};MeasurementsDocument=[pscustomobject]@{MeasurementVersion='invalid-integer'}}
    $cache=Join-Path $folder ($f.Record.Hash+'.json');$row|ConvertTo-Json -Depth 12|Set-Content $cache -Encoding UTF8;$before=(Get-FileHash $cache).Hash
    foreach($action in @('Diagnostics','PrintDiagnostics')){
        $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action=$action});Check ([IO.File]::Exists($result.path)) 'Logs can be downloaded without rebuilding the broken normal snapshot'
        if($action -eq 'PrintDiagnostics'){$html=[IO.File]::ReadAllText($result.path);Check ($html -match 'CacheUnreadable' -or $html -match 'cache.*read') 'Printable diagnostics describe the unreadable cache safely'}
    }
    Check ((Get-FileHash $cache).Hash -ceq $before) 'Collecting diagnostics preserves malformed evidence for recovery'
}
Scenario 'Diagnostic exports report unreadable organization history without treating saved decisions as absent' {
    $f=New-WebFixture 'DiagnosticOrganization';$path=Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json';[IO.File]::WriteAllText($path,'malformed-private-history');$before=(Get-FileHash $path).Hash
    foreach($action in @('Diagnostics','PrintDiagnostics')){
        $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action=$action});Check ([IO.File]::Exists($result.path)) 'Both diagnostic formats remain exportable with damaged organization history'
        if($action -eq 'PrintDiagnostics'){$html=[IO.File]::ReadAllText($result.path);Check ($html -match 'OrganizationUnreadable' -or $html -match 'organization history') 'The report discloses unknown organization history instead of inventing automatic decisions';Check (-not $html.Contains('malformed-private-history')) 'Private raw corruption text is not exported'}
    }
    Check ((Get-FileHash $path).Hash -ceq $before) 'History bytes are not modified by diagnostics'
}

$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Version='5.3.1';Runtime=$PSVersionTable.PSVersion.ToString();Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Synthetic PDFs and local scanner folders; independent file organization, no fabricated clinical review, stale/changed-file rejection, append-only Undo, readable ownership, exports and stdin/stdout JSON worker.'}
if($OutputPath){$report|ConvertTo-Json -Depth 12|Set-Content $OutputPath -Encoding UTF8}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
if([IO.Directory]::Exists($TestRoot)){Remove-Item $TestRoot -Recurse -Force}
if($failed){exit 1}
