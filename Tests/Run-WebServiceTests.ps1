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
Scenario 'Opening one verified PDF avoids dashboard work and rejects changed bytes or unsafe state' {
    $f=New-WebFixture 'PdfLookupGuards';$module=Get-Module WebService
    $sourceHash=(Get-FileHash $f.Source).Hash
    & $module {function script:Get-QaDashboard {throw 'A selected PDF lookup must not rebuild the dashboard.'}}
    try{
        $response=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Pdf';id=$f.Record.Id})
        Check ($response.path -ceq $f.Record.DestinationPath -and $response.filename -ceq $f.Record.OriginalFileName) 'Fresh core lookup returns the selected original filename and verified PDF without a dashboard call'
        $bytes=[IO.File]::ReadAllBytes($f.Record.DestinationPath);$time=(Get-Item $f.Record.DestinationPath).LastWriteTimeUtc
        try{
            $changed=[byte[]]$bytes.Clone();$changed[100]=$changed[100] -bxor 1;[IO.File]::WriteAllBytes($f.Record.DestinationPath,$changed);(Get-Item $f.Record.DestinationPath).LastWriteTimeUtc=$time
            $caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Pdf';id=$f.Record.Id})|Out-Null}catch{$caught=$_.Exception.Message -like '*missing or has changed*'}
            Check $caught 'An altered PDF is refused even when its byte count and write timestamp match the index'
        }finally{[IO.File]::WriteAllBytes($f.Record.DestinationPath,$bytes);(Get-Item $f.Record.DestinationPath).LastWriteTimeUtc=$time}
        $state=[IO.File]::ReadAllText($f.StatePath)|ConvertFrom-Json;$other=$state.Records[0]|Select-Object *;$other.Id=('B'*64);$other.SourcePath=[string]$other.SourcePath+'.other';$other.RelativePath='../outside.pdf';$state.Records=@($state.Records)+@($other)
        [IO.File]::WriteAllText($f.StatePath,($state|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true));$unsafeHash=(Get-FileHash $f.StatePath).Hash
        $caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Pdf';id=$f.Record.Id})|Out-Null}catch{$caught=$_.Exception.Message -match 'outside Reports|unsafe relative path'}
        Check $caught 'Fresh core validation rejects an unsafe unrelated record before serving the selected PDF'
        Check ((Get-FileHash $f.StatePath).Hash -ceq $unsafeHash) 'A malformed state is preserved for diagnosis'
        Check ((Get-FileHash $f.Source).Hash -ceq $sourceHash -and (Get-FileHash $f.Record.DestinationPath).Hash -ceq $f.Record.Hash) 'Source and archived PDF bytes remain unchanged'
    }finally{& $module {Remove-Item Function:Get-QaDashboard -ErrorAction SilentlyContinue}}
}
if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
    Scenario 'Native PDF preview resolves a fresh verified record without rebuilding dashboard projections' {
        $f=New-WebFixture 'PreviewLookup';Import-Module (Join-Path $ProductRoot 'App/PdfPreview.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue;$module=Get-Module PdfPreview
        $archiveModule=Get-Module Archive;$originalDashboard=& $archiveModule {(Get-Command Get-QaDashboard).ScriptBlock}
        & $archiveModule {function script:Get-QaDashboard {throw 'A rendered page must not rebuild the dashboard.'}}
        try{
            $before=(Get-FileHash $f.StatePath).Hash;$page=Get-QaPdfPreviewPage -Config $f.Config -RecordId $f.Record.Id -PageNumber 0
            Check ($page.RecordId -ceq $f.Record.Id -and $page.Hash -ceq $f.Record.Hash -and $page.PageNumber -eq 0 -and $page.PageCount -ge 1) 'Windows renders the requested exact indexed PDF and source page'
            $png=[Convert]::FromBase64String($page.PngBase64);Check ($png.Length -gt 8 -and $png[0] -eq 137 -and $png[1] -eq 80) 'Actual Windows renderer returns a PNG page'
            Check ((Get-FileHash $f.StatePath).Hash -ceq $before -and (Get-FileHash $f.Source).Hash -ceq $f.SourceHash) 'Page rendering preserves archive metadata and scanner bytes'
        }finally{& $archiveModule {param($Original) Set-Item Function:script:Get-QaDashboard $Original} $originalDashboard}
    }
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
        & $module {function script:Get-QaWebClassification {param($Record,$Entry) return [pscustomobject]@{category=(Get-QaWebCategory $Record $Entry);pending=(Test-QaReportPending $Record);decision='Pending';source='pending';reason='Synthetic v5.0.1 classification behavior';filingState='NeedsReview';filingBasis='ArchiveGrouping';inferred=$false;filingReason='Synthetic v5.0.1 classification behavior'}}}
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

# Filing-policy fixtures provide controlled cached classifier observations with
# exact fixture-byte provenance. Actual PDF extraction is covered separately.
function Set-WebFilingRule($Fixture,[string]$Profile,[AllowNull()]$Category=$null){
    $cfg=Read-QaConfig $Fixture.AppRoot;$source=@($cfg.Sources|Where-Object Scanner -ceq $Fixture.Record.Scanner)[0]
    if($null -eq $Category){$source.PSObject.Properties.Remove('ContentProfiles')}else{$source|Add-Member ContentProfiles @([pscustomobject]@{profileId=$Profile;category=[string]$Category}) -Force}
    [void](Save-QaConfig $Fixture.AppRoot $cfg)
}
function Set-WebFilingRawCategory($Fixture,[string]$Category){
    $state=Get-Content $Fixture.StatePath -Raw|ConvertFrom-Json;$row=@($state.Records|Where-Object Id -ceq $Fixture.Record.Id)[0]
    $row.Category=$Category;$row.ClassificationBasis='Synthetic prior archive grouping';$Fixture.Record.Category=$Category;$Fixture.Record.ClassificationBasis='Synthetic prior archive grouping'
    [IO.File]::WriteAllText($Fixture.StatePath,($state|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true))
}
function Set-WebFilingCache($Fixture,[string]$Profile='siemens-iec-basic-v1',[string]$Category='', [string]$Status='Recognized',[string]$DateStatus='Consensus',[bool]$Reference=$false){
    $info=Get-Item $Fixture.Record.DestinationPath;$date=[string]$Fixture.Record.ReportDate;$supportRevision=&(Get-Module WebService){Get-QaContentSupportRevision}
    $doc=[pscustomobject]@{ClassifierVersion=1;SupportRevision=$supportRevision;Status=$Status;ProfileId=$Profile;ProfileName='Synthetic supported format';Model='SOMATOM Definition Edge';CompleteRead=$true;Pages=3;ReadPages=3;DateStatus=$DateStatus;ReportDate=$date;ReportTime=[string]$Fixture.Record.ReportTime;Category=$Category;SuggestedCategory=$(if($Profile -ceq 'siemens-iec-basic-v1'){'Daily'}elseif($Profile -ceq 'siemens-iec-reference-v1'){'Other'}else{'Monthly'});ReasonCode=$(if($Status -ceq 'Recognized'){'SupportedProfile'}else{'UnknownTemplate'});Reason='Synthetic classifier fixture';IsReference=$Reference;NeedsOCR=$false;Sections=@()}
    if($DateStatus -ceq 'Conflict'){$doc.ReportDate='';$doc.ReportTime=''}
    $cache=[pscustomobject]@{ParserVersion=1;AnalysisCacheSchemaVersion=3;DocumentClassifierVersion=1;ContentSupportRevision=$supportRevision;Hash=$Fixture.Record.Hash;RecordId=$Fixture.Record.Id;VerifiedHash=$Fixture.Record.Hash;VerifiedLength=$info.Length;VerifiedWriteTicks=$info.LastWriteTimeUtc.Ticks;SavedLength=$info.Length;SavedWriteTicks=$info.LastWriteTimeUtc.Ticks;Status='NeedsReview';Truncated=$false;RequestedReaderMode='Auto';ReaderUsed='Legacy';DocumentClassification=$doc;MeasurementsDocument=[pscustomobject]@{MeasurementVersion=1;Status='NeedsReview';CompleteRead=$true;Measurements=@();Issues=@()}}
    $folder=Join-Path (Read-QaConfig $Fixture.AppRoot).ArchiveRoot '.ctqa/analysis';[void][IO.Directory]::CreateDirectory($folder);$path=Join-Path $folder ($Fixture.Record.Hash+'.json')
    [IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding $true));return $path
}
function Check-WebFilingBasis($Record){
    Check ([string]$Record.filingBasis -cin @('SavedDecision','ReviewedLegacy','Undo','Conflict','ReferenceDocument','ScannerRule','ExplicitTitle','ManualReview','BasicFormat','ExtendedFormat','ExistingGrouping','Unsupported','ReadError','FilenameGrouping','ExplicitFilename','AwaitingRead','ArchiveGrouping')) 'A filing basis is a fixed public code rather than a raw document or exception string'
}
Scenario 'Absent and legacy blank format settings automatically file complete Basic and Extended content' {
    foreach($case in @(@{Profile='siemens-iec-basic-v1';Category='Daily';Basis='BasicFormat'},@{Profile='siemens-iec-extended-v1';Category='Monthly';Basis='ExtendedFormat'})){
        foreach($mode in @('Missing','LegacyBlank')){
            $f=New-WebFixture ('AutoPolicy_'+$mode+'_'+$case.Category);if($mode -ceq 'Missing'){Set-WebFilingRule $f $case.Profile $null}else{Set-WebFilingRule $f $case.Profile ''}
            [void](Set-WebFilingCache $f $case.Profile);$before=(Get-FileHash $f.StatePath).Hash;$snapshot=Get-Web $f;$row=$snapshot.records[0]
            Check ($row.category -ceq $case.Category -and -not $row.pending -and $row.decision -ceq 'Automatic') 'A complete safe known profile files without a one-time mapping or individual approval'
            Check ($row.filingState -ceq 'Filed' -and $row.filingBasis -ceq $case.Basis -and $row.inferred) 'Default profile inference is visibly identified as inferred filing'
            Check ($snapshot.filingSummary.filed -eq 1 -and $snapshot.filingSummary.inferred -eq 1 -and $snapshot.filingSummary.waitingRead -eq 0 -and $snapshot.filingSummary.needsReview -eq 0) 'Summary counts distinguish inferred filing from waiting and exceptional review'
            Check ((Get-FileHash $f.StatePath).Hash -ceq $before -and (Get-FileHash $f.Source).Hash -ceq $f.SourceHash -and $row.clinicalComponents.Count -eq 0) 'Automatic filing preserves source bytes and clinical review state'
            Check-WebFilingBasis $row
        }
    }
}
Scenario 'Auto and Ask format policies round-trip while explicit scanner rules retain precedence' {
    $f=New-WebFixture 'PolicyRoundTrip';[void](Set-WebFilingCache $f)
    foreach($mode in @('Auto','Ask','Monthly','Other')){
        $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='ScannerSettings';scanner='CT_Edge';contentProfiles=@([pscustomobject]@{profileId='siemens-iec-basic-v1';category=$mode})});$row=$result.snapshot.records[0]
        Check (@($result.snapshot.scanners[0].contentProfiles|Where-Object{[string]$_.profileId -ceq 'siemens-iec-basic-v1' -and [string]$_.category -ceq $mode}).Count -eq 1) 'The explicit filing policy persists through the settings API'
        if($mode -ceq 'Ask'){Check ($row.pending -and $row.filingState -ceq 'NeedsReview' -and -not $row.inferred) 'Ask explicitly requests a decision after a successful read'}elseif($mode -ceq 'Auto'){Check ($row.category -ceq 'Daily' -and $row.filingState -ceq 'Filed' -and $row.inferred) 'Auto resumes the complete Basic-profile Daily convention'}else{Check ($row.category -ceq $mode -and -not $row.pending -and $row.filingBasis -ceq 'ScannerRule' -and -not $row.inferred) 'A nonempty scanner mapping overrides automatic profile inference'}
        Check-WebFilingBasis $row
    }
}
Scenario 'Additional test sets reuse an existing Daily or Monthly grouping without guessing an ungrouped procedure' {
    foreach($case in @(@{Raw='Daily_QA';Expected='Daily'},@{Raw='Monthly_QA/Pending_Verification';Expected='Monthly'},@{Raw='Needs_Review';Expected=''})){
        $f=New-WebFixture ('AdditionalPolicy_'+$case.Raw.Replace('/','_'));Set-WebFilingRawCategory $f $case.Raw;Set-WebFilingRule $f 'siemens-iec-additional-v1' 'Auto';[void](Set-WebFilingCache $f 'siemens-iec-additional-v1');$before=(Get-FileHash $f.StatePath).Hash;$row=(Get-Web $f).records[0]
        if($case.Expected){Check ($row.category -ceq $case.Expected -and -not $row.pending -and $row.filingState -ceq 'Filed' -and $row.filingBasis -ceq 'ExistingGrouping' -and $row.inferred) 'Automatic additional filing preserves the existing known archive frequency'}else{Check ($row.pending -and $row.filingState -ceq 'NeedsReview' -and -not $row.inferred) 'A complete additional test set with no existing frequency remains a real exception'}
        Check ((Get-FileHash $f.StatePath).Hash -ceq $before) 'Reusing a prior frequency never rewrites protected archive grouping'
        Check-WebFilingBasis $row
    }
}
Scenario 'Explicit document titles override inference while contradictory explicit evidence remains exceptional' {
    $f=New-WebFixture 'TitlePolicy';Set-WebFilingRule $f 'siemens-iec-basic-v1' 'Auto';[void](Set-WebFilingCache $f 'siemens-iec-basic-v1' 'Monthly');$row=(Get-Web $f).records[0]
    Check ($row.category -ceq 'Monthly' -and -not $row.pending -and $row.filingBasis -ceq 'ExplicitTitle' -and -not $row.inferred) 'A valid Monthly document title overrides the default Basic inference'
    Set-WebFilingRule $f 'siemens-iec-basic-v1' 'Ask';$row=(Get-Web $f).records[0]
    Check ($row.category -ceq 'Monthly' -and -not $row.pending -and $row.filingBasis -ceq 'ExplicitTitle') 'Ask is not needed for an otherwise safe explicit document frequency'
    Set-WebFilingRule $f 'siemens-iec-basic-v1' 'Daily';$row=(Get-Web $f).records[0]
    Check ($row.pending -and $row.filingState -ceq 'NeedsReview' -and $row.filingBasis -ceq 'Conflict' -and -not $row.inferred) 'Contradictory scanner rules and document titles are not silently accepted'
}
Scenario 'Filing counters separate waiting-to-read files from actual reader and content exceptions' {
    $f=New-WebFixture 'FilingCounters';$initial=Get-Web $f;$row=$initial.records[0]
    Check ($row.pending -and $row.filingState -ceq 'WaitingRead' -and $initial.filingSummary.waitingRead -eq 1 -and $initial.filingSummary.needsReview -eq 0) 'A missing reading queues work without describing it as a human review failure'
    $path=Set-WebFilingCache $f '' '' 'NeedsReview';$snapshot=Get-Web $f;$row=$snapshot.records[0]
    Check ($row.pending -and $row.filingState -ceq 'NeedsReview' -and $snapshot.filingSummary.waitingRead -eq 0 -and $snapshot.filingSummary.needsReview -eq 1) 'An actually attempted unsupported format is a review exception'
    $cache=Get-Content $path -Raw|ConvertFrom-Json;$cache.Status='ReadError';[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding $true));$snapshot=Get-Web $f;$row=$snapshot.records[0]
    Check ($row.filingState -ceq 'NeedsReview' -and $row.filingBasis -ceq 'ReadError' -and $snapshot.filingSummary.needsReview -eq 1) 'An actual read failure remains visible instead of reverting to an unread queue'
    [void](Set-WebFilingCache $f 'siemens-iec-basic-v1' '' 'Recognized' 'Conflict');$snapshot=Get-Web $f;$row=$snapshot.records[0]
    Check ($row.pending -and $row.filingState -ceq 'NeedsReview' -and $row.filingBasis -ceq 'Conflict' -and $snapshot.filingSummary.inferred -eq 0) 'A date conflict never contributes an inferred filed report'
    $path=Set-WebFilingCache $f;$cache=Get-Content $path -Raw|ConvertFrom-Json;$cache.VerifiedWriteTicks=[long]$cache.VerifiedWriteTicks-1;[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding $true));$snapshot=Get-Web $f
    Check ($snapshot.records[0].filingState -ceq 'WaitingRead' -and $snapshot.filingSummary.waitingRead -eq 1) 'Stale successful cache evidence waits for a new verified read'
    [IO.File]::WriteAllText($path,'{synthetic damaged cache');$snapshot=Get-Web $f
    Check ($snapshot.records[0].filingState -ceq 'NeedsReview' -and $snapshot.records[0].filingBasis -ceq 'ReadError' -and $snapshot.filingSummary.waitingRead -eq 0) 'An unreadable cache is disclosed as a real exception rather than an unattempted read'
}
Scenario 'Saved decisions and explicit Undo remain authoritative when automatic policy is enabled' {
    $f=New-WebFixture 'PolicyDecision';Set-WebFilingRule $f 'siemens-iec-basic-v1' 'Ask';[void](Set-WebFilingCache $f);$before=(Get-FileHash $f.StatePath).Hash
    [void](Decide-Web $f);Set-WebFilingRule $f 'siemens-iec-basic-v1' 'Monthly';$row=(Get-Web $f).records[0]
    Check ($row.category -ceq 'Daily' -and $row.decision -ceq 'Approved' -and $row.filingBasis -ceq 'SavedDecision' -and -not $row.inferred) 'A saved one-file decision wins over future automatic or scanner policy changes'
    Set-WebFilingRule $f 'siemens-iec-basic-v1' 'Auto';$last=(Get-Web $f).lastDecision;$undo=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Undo';id=$last.recordId;reviewId=$last.reviewId;stamp=$last.stamp});$row=$undo.snapshot.records[0]
    Check ($row.pending -and $row.filingState -ceq 'NeedsReview' -and $row.filingBasis -ceq 'Undo') 'Undo restores an intentional review state instead of immediately inferring the same decision again'
    Check ((Get-FileHash $f.StatePath).Hash -ceq $before) 'Decision precedence and Undo preserve clinical archive bytes'
}
Scenario 'Reference documents file as Other and do not count as received Daily reports' {
    $f=New-WebFixture 'ReferencePolicy';$cfg=Read-QaConfig $f.AppRoot;$source=@($cfg.Sources|Where-Object Scanner -ceq 'CT_Edge')[0];$source.DailySchedule='AllDays';$source.ActiveFrom='';$source|Add-Member ExcludedDates @() -Force;[void](Save-QaConfig $f.AppRoot $cfg)
    Set-WebFilingRawCategory $f 'Daily_QA';[void](Set-WebFilingCache $f);$control=Get-Web $f;Check ($control.today.received -eq 1) 'The fixture would count as a current Daily receipt when it contains a normal Basic report'
    $metrics=@([pscustomobject]@{Code='WaterCTNumber';Value='0.2';Unit='HU';Page=3},[pscustomobject]@{Code='SliceThickness';Value='0.6';Unit='mm';Page=3})
    $path=Set-WebFilingCache $f;$cache=Get-Content $path -Raw|ConvertFrom-Json;$cache.MeasurementsDocument.Measurements=$metrics;$cache.MeasurementsDocument.Status='Extracted';[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding $true))
    $control=Get-Web $f
    Check ($control.records[0].content.measurements.Count -eq 2 -and @($control.records[0].content.measurements|Where-Object{$_.label -ceq 'Slice thickness' -and $_.unit -ceq 'mm'}).Count -eq 1) 'The current-report positive control exposes HU and millimetre metric rows'
    $path=Set-WebFilingCache $f 'siemens-iec-reference-v1' 'Other' 'Recognized' 'Consensus' $true;$cache=Get-Content $path -Raw|ConvertFrom-Json;$cache.MeasurementsDocument.Measurements=$metrics;$cache.MeasurementsDocument.Status='Extracted';[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding $true));$snapshot=Get-Web $f;$row=$snapshot.records[0]
    Check ($row.isReference -and $row.content.measurements.Count -eq 0 -and $row.content.measurementStatus -ceq 'ReferenceExcluded') 'Reference detection suppresses even legacy cached numeric rows from current-report display'
    Check ($row.category -ceq 'Other' -and -not $row.pending -and $row.filingState -ceq 'Filed' -and $row.filingBasis -ceq 'ReferenceDocument' -and -not $row.inferred) 'An explicit supported reference is kept as Other rather than inferred as a clinical-period QA report'
    Check ($snapshot.today.received -eq 0 -and @($snapshot.records|Where-Object{$_.category -cin @('Daily','Monthly')}).Count -eq 0) 'Reference material contributes neither a Daily receipt nor a Monthly document label'
    Check ($row.clinicalComponents.Count -eq 0) 'Reference filing supplies no clinical sign-off'
    $monthly=New-WebFixture 'ReferenceMonthlyEvidence';Set-WebFilingRawCategory $monthly 'Monthly_QA'
    $state=Get-Content $monthly.StatePath -Raw|ConvertFrom-Json;$old=@($state.Records|Where-Object Id -ceq $monthly.Record.Id)[0];$old.ConfirmedBy='Synthetic prior reviewer';$old.ConfirmedAt=[datetime]::UtcNow.ToString('o');$old.ConfirmedComponents=@('MTF','Slice thickness');$old|Add-Member ReviewDecision 'Accepted' -Force
    [IO.File]::WriteAllText($monthly.StatePath,($state|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true));[void](Set-WebFilingCache $monthly 'siemens-iec-extended-v1');$control=Get-Web $monthly
    Check (@($control.months|Where-Object{$_.scanner -ceq 'CT_Edge' -and $_.status -ceq 'Complete'}).Count -eq 1) 'The positive control has actual synthetic legacy reviewed Monthly evidence'
    $before=(Get-FileHash $monthly.StatePath).Hash;[void](Set-WebFilingCache $monthly 'siemens-iec-reference-v1' 'Other' 'Recognized' 'Consensus' $true);$snapshot=Get-Web $monthly
    Check (@($snapshot.months|Where-Object{$_.scanner -ceq 'CT_Edge' -and $_.status -ceq 'Complete'}).Count -eq 0) 'A detected reference cannot satisfy current Monthly evidence even when an old file label or review exists'
    Check ($snapshot.records[0].decision -ceq 'Approved' -and $snapshot.records[0].isReference -and (Get-FileHash $monthly.StatePath).Hash -ceq $before) 'Reference exclusion preserves the old decision and entire clinical archive for audit rather than rewriting it'
}

Scenario 'Unknown reference evidence cannot inherit generic Daily filing or cached current measurements' {
    $f=New-WebFixture 'UnknownReferenceEvidence';$cfg=Read-QaConfig $f.AppRoot;$source=@($cfg.Sources|Where-Object Scanner -ceq 'CT_Edge')[0];$source.DailySchedule='AllDays';$source.ActiveFrom='';$source|Add-Member ExcludedDates @() -Force;[void](Save-QaConfig $f.AppRoot $cfg)
    # The old generic Daily grouping could previously take the filename fallback.
    Set-WebFilingRawCategory $f 'Daily_QA';$state=Get-Content $f.StatePath -Raw|ConvertFrom-Json;$state.Records[0].ClassificationBasis='Provisional Daily archive grouping from generic Constancy filename; contents are not interpreted.';[IO.File]::WriteAllText($f.StatePath,($state|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true))
    [void](Set-WebFilingCache $f);Check ((Get-Web $f).today.received -eq 1) 'The positive control counts a normal current Basic document as Daily receipt'
    $path=Set-WebFilingCache $f '' '' 'NeedsReview';$cache=Get-Content $path -Raw|ConvertFrom-Json;$cache.DocumentClassification|Add-Member HasReferenceEvidence $true -Force;$cache.DocumentClassification.IsReference=$false;$cache.MeasurementsDocument.Measurements=@([pscustomobject]@{Code='WaterCTNumber';Value='0.4';Unit='HU';Page=3});$cache.MeasurementsDocument.Status='Extracted';[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding $true))
    $before=(Get-FileHash $f.StatePath).Hash;$snapshot=Get-Web $f;$row=$snapshot.records[0]
    Check ($row.pending -and $row.filingState -ceq 'NeedsReview' -and $row.filingBasis -ceq 'Unsupported' -and -not $row.isReference -and $row.hasReferenceEvidence) 'Unknown reference evidence remains a true exception rather than becoming an automatically filed Reference/Other document'
    Check ($snapshot.today.received -eq 0 -and $row.content.measurements.Count -eq 0 -and $row.content.measurementStatus -ceq 'ReferenceExcluded') 'Uncertain reference evidence blocks filename receipt and legacy numeric rows'
    Check ($row.category -ceq 'Daily' -and -not $row.inferred -and (Get-FileHash $f.StatePath).Hash -ceq $before) 'Its old archive grouping stays visible without changing original clinical data or pretending the type is known'
    [void](Decide-Web $f);$snapshot=Get-Web $f
    Check ($snapshot.records[0].decision -ceq 'Approved' -and $snapshot.today.received -eq 0 -and $snapshot.records[0].content.measurements.Count -eq 0) 'A saved human file decision remains authoritative while reference receipt and measurement exclusion still apply'
}

Scenario 'Older unsupported format reads await one compatibility refresh while current exceptions and failures remain actionable' {
    $f=New-WebFixture 'CompatibilityRefreshState';$path=Set-WebFilingCache $f '' '' 'NeedsReview';$current=&(Get-Module WebService){Get-QaContentSupportRevision}
    foreach($reason in @('UnknownTemplate','UnrecognizedSections')){
        $cache=Get-Content $path -Raw|ConvertFrom-Json;$cache.ContentSupportRevision=$current-1;$cache.DocumentClassification.SupportRevision=$current-1;$cache.DocumentClassification.ReasonCode=$reason;[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding $true));$snapshot=Get-Web $f;$row=$snapshot.records[0]
        Check ($row.content.compatibilityRefreshPending -and $row.filingState -ceq 'WaitingRead' -and $row.filingBasis -ceq 'AwaitingRead' -and $snapshot.filingSummary.needsReview -eq 0) 'An older unsupported layout is queued for its one compatibility refresh instead of requesting a premature human decision'
        $cache.ContentSupportRevision=$current;$cache.DocumentClassification.SupportRevision=$current;[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding $true));$row=(Get-Web $f).records[0]
        Check (-not $row.content.compatibilityRefreshPending -and $row.filingState -ceq 'NeedsReview') 'An unknown result after the current support revision remains a genuine exception'
    }
    $cache.ContentSupportRevision=$current-1;$cache.DocumentClassification.SupportRevision=$current-1;$cache.Status='ReadError';[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding $true));$row=(Get-Web $f).records[0]
    Check (-not $row.content.compatibilityRefreshPending -and $row.filingState -ceq 'NeedsReview' -and $row.filingBasis -ceq 'ReadError') 'A cached read failure never becomes a compatibility waiting loop'
    $path=Set-WebFilingCache $f;$cache=Get-Content $path -Raw|ConvertFrom-Json;$cache.ContentSupportRevision=$current-1;$cache.DocumentClassification.Reason='Profile-to-Daily/Monthly mapping requires department confirmation.';$cache.MeasurementsDocument.PSObject.Properties.Remove('MeasurementVersion');[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding $true));$row=(Get-Web $f).records[0]
    Check ($row.filingState -ceq 'Filed' -and -not $row.content.compatibilityRefreshPending -and $row.content.reason -notmatch '(?i)requires.*confirmation|choose.*scanner settings') 'A valid recognized Auto cache uses current neutral wording despite old mandatory-mapping text and an unrelated measurement upgrade'
    $path=Set-WebFilingCache $f 'siemens-iec-basic-v1' '' 'Recognized' 'Conflict';$row=(Get-Web $f).records[0]
    Check ($row.filingState -ceq 'NeedsReview' -and $row.content.reason -match '(?i)conflict') 'Current conflict explanations remain visible rather than being replaced by neutral filing guidance'
}

function New-WebReadingFixture([string]$Name){
    $cfg=New-TestConfig $Name;[void][IO.Directory]::CreateDirectory((Join-Path $cfg.AppRoot 'Config'))
    foreach($source in $cfg.Sources){$source.DailySchedule='Off';$source.ExpectedMonthly=$false}
    $cfg|ConvertTo-Json -Depth 15|Set-Content (Join-Path $cfg.AppRoot 'Config/Settings.json') -Encoding UTF8
    [void](Save-QaConfig $cfg.AppRoot $cfg)
    $path=Join-Path $cfg.Sources[0].Path ('Quality_Constancy_'+(Get-Date).ToString('yyyy-MM-dd')+'_08-00-00.pdf')
    [IO.File]::Copy((Join-Path $PSScriptRoot 'Fixtures/PdfReader/Compressed-Text.pdf'),$path)
    (Get-Item $path).LastWriteTimeUtc=[datetime]::UtcNow.AddMinutes(-10)
    [void](Import-Fixture $cfg);$record=@((Get-QaDashboard $cfg).Records)[0]
    return [pscustomobject]@{Config=$cfg;AppRoot=$cfg.AppRoot;Record=$record;Source=$path;StatePath=(Join-Path $cfg.ArchiveRoot '.ctqa/state.json')}
}
Scenario 'Trusted reading plans reject malformed scopes and controls without touching PDF bytes' {
    $f=New-WebReadingFixture 'ReadingPlan';$before=(Get-FileHash $f.StatePath).Hash;$sourceHash=(Get-FileHash $f.Source).Hash
    $guard=[IO.File]::Open($f.Record.DestinationPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try{$plan=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='AnalysisPlan';scope='all';measurements=$true;refreshUnsupported=$true})}finally{$guard.Dispose()}
    Check ($plan.snapshotDeferred -and $plan.plan.pending -eq 1 -and $plan.plan.recordIds[0] -ceq $f.Record.Id) 'A locked PDF still yields a metadata-only trusted plan with its exact identity'
    Check ($null -eq $plan.PSObject.Properties['snapshot'] -and $plan.plan.revision -cmatch '^[0-9A-Fa-f]{64}$') 'Planning returns an invalidation hint rather than a full overview'
    foreach($request in @([pscustomobject]@{action='AnalysisPlan';scope='../all'},[pscustomobject]@{action='AnalysisPlan';measurements='yes'},[pscustomobject]@{action='AnalysisPlan';refreshUnsupported=1},[pscustomobject]@{action='AnalysisPlan';ids=@()},[pscustomobject]@{action='AnalysisPlan';ids=$null},[pscustomobject]@{action='AnalysisPlan';ids=@('../outside')},[pscustomobject]@{action='AnalysisPlan';ids=@(('f'*64))},[pscustomobject]@{action='AnalysisPlan';scope='pending';ids=@($f.Record.Id)},[pscustomobject]@{action='AnalysisPlan';ids=@(1..21|ForEach-Object{$f.Record.Id})})){
        $rejected=$false;try{Invoke-QaWebRequest $f.AppRoot $request|Out-Null}catch{$rejected=$true};Check $rejected 'Malformed or contradictory plans do not expand into an unrestricted read'
    }
    Check ((Get-FileHash $f.StatePath).Hash -ceq $before -and (Get-FileHash $f.Source).Hash -ceq $sourceHash) 'Planning and rejected controls preserve core state and source bytes'
}
Scenario 'A compact one-PDF checkpoint defers dashboards and folders until an explicit checked synchronization' {
    $f=New-WebReadingFixture 'CompactStep';$before=(Get-FileHash $f.StatePath).Hash;$sourceHash=(Get-FileHash $f.Source).Hash
    foreach($request in @([pscustomobject]@{action='Analyze';analysisStep='true';ids=@($f.Record.Id)},[pscustomobject]@{action='Analyze';deferSnapshot=$true;ids=@($f.Record.Id)},[pscustomobject]@{action='Analyze';analysisStep=$true;analysisLimit=2;ids=@($f.Record.Id)},[pscustomobject]@{action='Analyze';analysisStep=$true;analysisLimit=1;id=$f.Record.Id},[pscustomobject]@{action='Analyze';analysisStep=$true;analysisLimit=1;ids=@($f.Record.Id);backlog=$true},[pscustomobject]@{action='Analyze';analysisStep=$true;analysisLimit=1;ids=@($f.Record.Id);deferLibrary='yes'})){
        $rejected=$false;try{Invoke-QaWebRequest $f.AppRoot $request|Out-Null}catch{$rejected=$true};Check $rejected 'Only the single-record internal step may defer expensive work'
    }
    $library=Join-Path $f.Config.ArchiveRoot '.ctqa/web-library.json';$step=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Analyze';ids=@($f.Record.Id);analysisStep=$true;analysisLimit=1;deferSnapshot=$true;deferLibrary=$true;measurements=$true;refreshUnsupported=$true})
    Check ($step.result.Analyzed -eq 1 -and $step.result.Failed -eq 0 -and $step.result.AnalyzedIds[0] -ceq $f.Record.Id) 'The actual compressed synthetic PDF is read and committed exactly once'
    Check ($step.snapshotDeferred -and $step.libraryDeferred -and $null -eq $step.PSObject.Properties['snapshot']) 'The step returns truthful deferral markers without a full overview'
    Check (-not [IO.File]::Exists($library)) 'Deferred text reading does not prematurely publish a readable-copy ledger'
    $cachePath=Join-Path $f.Config.ArchiveRoot ('.ctqa/analysis/'+$f.Record.Hash+'.json');$cache=Get-Content $cachePath -Raw|ConvertFrom-Json
    Check ($cache.VerifiedHash -ceq $f.Record.Hash -and $cache.VerifiedLength -eq (Get-Item $f.Record.DestinationPath).Length) 'Exact parsed-buffer provenance is preserved in the compact path'
    $cacheBefore=(Get-FileHash $cachePath).Hash;$sync=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='SyncLibrary';ids=@($f.Record.Id);fullSync=$false})
    Check ($sync.snapshot.records.Count -eq 1 -and $sync.result.library.total -eq 1 -and $sync.result.library.failed -eq 0) 'A checkpoint synchronizes only the changed record and returns a fresh overview'
    $ledgerBefore=(Get-FileHash $library).Hash;$metadata=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='SyncLibrary';ids=@();fullSync=$false})
    Check ($metadata.snapshot.records.Count -eq 1 -and $metadata.result.library.manifestWrites -eq 0 -and (Get-FileHash $library).Hash -ceq $ledgerBefore) 'An empty explicit checkpoint refreshes metadata without rewriting the readable ledger'
    $legacy=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='SyncLibrary'})
    Check ($legacy.result.library.total -eq 1 -and $legacy.result.library.unchanged -eq 1) 'The legacy no-selection synchronization still covers the whole library'
    Check ((Get-FileHash $cachePath).Hash -ceq $cacheBefore -and (Get-FileHash $f.StatePath).Hash -ceq $before -and (Get-FileHash $f.Source).Hash -ceq $sourceHash) 'Synchronization does not reread or rewrite cached evidence, clinical state or source PDFs'
}
Scenario 'A queued ID cannot bypass fresh archive membership or exact PDF-byte verification' {
    $f=New-WebReadingFixture 'QueuedMembership';$plan=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='AnalysisPlan';measurements=$true;refreshUnsupported=$true});$id=$plan.plan.recordIds[0]
    $original=[IO.File]::ReadAllBytes($f.StatePath)
    try{
        $state=Get-Content $f.StatePath -Raw|ConvertFrom-Json;$state.Records=@();[IO.File]::WriteAllText($f.StatePath,($state|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true));$changed=(Get-FileHash $f.StatePath).Hash
        $rejected=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Analyze';ids=@($id);analysisStep=$true;analysisLimit=1;deferSnapshot=$true;deferLibrary=$true})|Out-Null}catch{$rejected=$true}
        Check ($rejected -and (Get-FileHash $f.StatePath).Hash -ceq $changed) 'An ID removed after planning is rejected without restoring or changing the current state'
    }finally{[IO.File]::WriteAllBytes($f.StatePath,$original)}
    $bytes=[IO.File]::ReadAllBytes($f.Record.DestinationPath);$time=(Get-Item $f.Record.DestinationPath).LastWriteTimeUtc
    try{
        $edited=[byte[]]$bytes.Clone();$edited[$edited.Length-2]=$edited[$edited.Length-2] -bxor 1;[IO.File]::WriteAllBytes($f.Record.DestinationPath,$edited);(Get-Item $f.Record.DestinationPath).LastWriteTimeUtc=$time
        $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Analyze';ids=@($id);analysisStep=$true;analysisLimit=1;deferSnapshot=$true;deferLibrary=$true;measurements=$true})
        Check ($result.result.Analyzed -eq 0 -and $result.result.Failed -eq 1) 'Same-length same-timestamp edits still fail exact parsed-buffer hashing'
        $cache=Get-Content (Join-Path $f.Config.ArchiveRoot ('.ctqa/analysis/'+$f.Record.Hash+'.json')) -Raw|ConvertFrom-Json
        Check ($cache.Status -ceq 'ReadError' -and $null -eq $cache.PSObject.Properties['VerifiedHash']) 'A failed queued read cannot acquire successful verified provenance'
    }finally{[IO.File]::WriteAllBytes($f.Record.DestinationPath,$bytes);(Get-Item $f.Record.DestinationPath).LastWriteTimeUtc=$time}
}

Scenario 'Durable file decisions reuse one validated dashboard and organization while refreshing only their selected readable PDF' {
    $f=New-WebFixture 'DecisionSnapshotReuse';$day=(Get-Date).ToString('yyyy-MM-dd');[void](Add-Report $f.Config 'CT_Edge' 'Quality_Constancy' $day '09-00-00' 96000);[void](Invoke-QaOperation $f.Config -Mode Update)
    Set-WebFilingRule $f 'siemens-iec-basic-v1' 'Ask';[void](Set-WebFilingCache $f);$first=Get-Web $f;$before=(Get-FileHash $f.StatePath).Hash;$pdfBefore=(Get-FileHash $f.Record.DestinationPath).Hash
    $failure=New-WebFixture 'DecisionCopyWarning';Set-WebFilingRule $failure 'siemens-iec-basic-v1' 'Ask';[void](Set-WebFilingCache $failure);$failureInitial=Get-Web $failure;$failureBefore=(Get-FileHash $failure.StatePath).Hash
    $module=Get-Module WebService
    $originals=&$module {[pscustomobject]@{Dashboard=(Get-Command Get-QaDashboard).ScriptBlock;Organization=(Get-Command Get-QaWebOrganization).ScriptBlock;Library=(Get-Command Update-QaWebLibrary).ScriptBlock;Copy=(Get-Command Copy-QaWebLibraryPdf).ScriptBlock}}
    $probe=[pscustomobject]@{DashboardCalls=0;OrganizationCalls=0;LibraryCalls=(New-Object 'Collections.Generic.List[object]');CopyFails=$false}
    try{
        &$module {
            param($Probe,$Originals)
            $script:DecisionSnapshotProbe=$Probe;$script:DecisionSnapshotOriginals=$Originals
            function script:Get-QaDashboard {param($Config);$script:DecisionSnapshotProbe.DashboardCalls++;return &$script:DecisionSnapshotOriginals.Dashboard $Config}
            function script:Get-QaWebOrganization {param($Config);$script:DecisionSnapshotProbe.OrganizationCalls++;return &$script:DecisionSnapshotOriginals.Organization $Config}
            function script:Update-QaWebLibrary {
                param($Config,[string[]]$OnlyRecords=@(),$Dashboard=$null,$Organization=$null,$Progress=$null,[switch]$Verify)
                [void]$script:DecisionSnapshotProbe.LibraryCalls.Add([pscustomobject]@{Ids=@($OnlyRecords);HasDashboard=($null -ne $Dashboard);HasOrganization=($null -ne $Organization)})
                return &$script:DecisionSnapshotOriginals.Library @PSBoundParameters
            }
            function script:Copy-QaWebLibraryPdf {param($Source,$Target,$Hash,$Progress,$Metrics);if($script:DecisionSnapshotProbe.CopyFails){throw 'Synthetic readable-copy failure'};return &$script:DecisionSnapshotOriginals.Copy @PSBoundParameters}
        } $probe $originals
        $snapshot=$first
        foreach($action in @('Approve','Undo','Disapprove')){
            $record=@($snapshot.records|Where-Object id -ceq $f.Record.Id)[0];$request=[pscustomobject]@{action=$action;id=$record.id;stamp=$record.stamp;reviewId=$record.reviewId}
            $probe.DashboardCalls=0;$probe.OrganizationCalls=0;$probe.LibraryCalls.Clear()
            $result=Invoke-QaWebRequest $f.AppRoot $request;$snapshot=$result.snapshot;$row=@($snapshot.records|Where-Object id -ceq $f.Record.Id)[0]
            Check ($probe.DashboardCalls -eq 1 -and $probe.OrganizationCalls -eq 1) 'The whole actual decision request loads and validates the dashboard and organization once, including its full returned snapshot'
            Check ($probe.LibraryCalls.Count -eq 1 -and $probe.LibraryCalls[0].Ids.Count -eq 1 -and $probe.LibraryCalls[0].Ids[0] -ceq $f.Record.Id -and $probe.LibraryCalls[0].HasDashboard -and $probe.LibraryCalls[0].HasOrganization) 'Only the selected report is refreshed with the same validated dashboard and committed organization'
            Check ($snapshot.records.Count -eq 2 -and $snapshot.filingSummary.filed+$snapshot.filingSummary.waitingRead+$snapshot.filingSummary.needsReview -eq 2) 'The returned snapshot still contains accurate full-library counts and both selected and unselected reports'
            $expected=if($action -ceq 'Approve'){'Approved'}elseif($action -ceq 'Disapprove'){'Disapproved'}else{'Pending'}
            Check ($row.decision -ceq $expected -and (($action -ceq 'Undo') -eq [bool]$row.pending)) 'The complete returned snapshot reflects the durable decision or restored pending state'
            $fields=@($result.decision.PSObject.Properties.Name|Sort-Object)
            Check (($fields -join '|') -ceq 'classificationOnly|recordId|reviewId|stamp|warning') 'The public decision shape contains no internal dashboard, organization or reuse context'
            Check ((Get-FileHash $f.StatePath).Hash -ceq $before -and (Get-FileHash $f.Record.DestinationPath).Hash -ceq $pdfBefore -and (Get-FileHash $f.Source).Hash -ceq $f.SourceHash) 'Snapshot reuse and selected library updates preserve all clinical core and original PDF bytes'
        }
        $history=Get-Content (Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json') -Raw|ConvertFrom-Json
        Check ($history.History.Count -eq 3 -and $history.History[1].action -ceq 'Undo') 'Reuse retains the full append-only durable decision history'
        $record=$failureInitial.records[0];$probe.DashboardCalls=0;$probe.OrganizationCalls=0;$probe.LibraryCalls.Clear();$probe.CopyFails=$true
        $result=Invoke-QaWebRequest $failure.AppRoot ([pscustomobject]@{action='Approve';id=$record.id;stamp=$record.stamp})
        $saved=Get-Content (Join-Path $failure.Config.ArchiveRoot '.ctqa/organization.json') -Raw|ConvertFrom-Json
        Check ($probe.DashboardCalls -eq 1 -and $probe.OrganizationCalls -eq 1 -and $probe.LibraryCalls.Count -eq 1 -and $probe.LibraryCalls[0].Ids.Count -eq 1) 'A readable-copy failure does not trigger a second full dashboard or organization scan'
        Check ($result.warning -match '^Decision saved\.' -and $result.decision.warning -ceq $result.warning -and $saved.Records[0].decision -ceq 'Approved' -and $result.snapshot.records[0].decision -ceq 'Approved') 'The already durable approval is returned accurately with an actionable readable-copy warning'
        Check ((Get-FileHash $failure.StatePath).Hash -ceq $failureBefore -and (Get-FileHash $failure.Source).Hash -ceq $failure.SourceHash) 'A failed readable copy neither rewrites core clinical state nor alters the scanner original'
    }finally{
        &$module {param($Originals);Set-Item Function:script:Get-QaDashboard $Originals.Dashboard;Set-Item Function:script:Get-QaWebOrganization $Originals.Organization;Set-Item Function:script:Update-QaWebLibrary $Originals.Library;Set-Item Function:script:Copy-QaWebLibraryPdf $Originals.Copy;Remove-Variable DecisionSnapshotProbe,DecisionSnapshotOriginals -Scope Script -ErrorAction SilentlyContinue} $originals
    }
}

function New-WebBatchFixture([string]$Name,[int]$Count=3){
    $f=New-WebFixture $Name;$day=(Get-Date).ToString('yyyy-MM-dd')
    for($i=1;$i -lt $Count;$i++){[void](Add-Report $f.Config 'CT_Edge' 'Quality_Constancy' $day ((Get-Date).Date.AddHours(8).AddMinutes($i).ToString('HH-mm-ss')) (95000+$i*31))}
    [void](Invoke-QaOperation $f.Config -Mode Update);Set-WebFilingRule $f 'siemens-iec-basic-v1' 'Ask';$cfg=Read-QaConfig $f.AppRoot;$records=@((Get-QaDashboard $cfg).Records|Sort-Object ReportTime)
    foreach($record in $records){$item=[pscustomobject]@{Record=$record;AppRoot=$f.AppRoot};[void](Set-WebFilingCache $item)}
    $f|Add-Member Records $records;$f|Add-Member BeforeCore ((Get-FileHash $f.StatePath).Hash);return $f
}
function Batch-Selections($Snapshot,[int]$Count=2){return @($Snapshot.records|Where-Object filingState -ceq 'NeedsReview'|Sort-Object time|Select-Object -First $Count|ForEach-Object{[pscustomobject]@{id=$_.id;stamp=$_.stamp}})}
function Check-BatchProtected($Fixture){
    Check ((Get-FileHash $Fixture.StatePath).Hash -ceq $Fixture.BeforeCore) 'Grouped file organization never rewrites the protected clinical archive'
    foreach($record in $Fixture.Records){Check ((Get-FileHash $record.SourcePath).Hash -ceq $record.Hash -and (Get-FileHash $record.DestinationPath).Hash -ceq $record.Hash) 'Every scanner original and archived PDF retains its exact bytes'}
}
Scenario 'Selected grouped approvals persist one durable batch and restore together after a fresh snapshot' {
    $f=New-WebBatchFixture 'BatchApprove';$initial=Get-Web $f;$selected=@(Batch-Selections $initial);$settings=Join-Path $f.AppRoot 'Config/Settings.local.json';$beforeSettings=(Get-FileHash $settings).Hash
    Check ($initial.batchReviewLimit -eq 50 -and @($initial.records|Where-Object{$_.groupingKey -cmatch '^[A-Fa-f0-9]{64}$' -and $_.groupingReason -ceq 'ManualReview'}).Count -eq 3) 'Only actual review exceptions expose stable bounded grouping metadata'
    $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';selections=$selected;category='Monthly'})
    Check ($result.decision.count -eq 2 -and $result.decision.action -ceq 'Approve' -and $result.decision.classificationOnly) 'The explicit selected-file action reports a committed batch rather than clinical approval'
    Check (@($result.snapshot.records|Where-Object{$_.decision -ceq 'Approved' -and $_.category -ceq 'Monthly'}).Count -eq 2 -and $result.snapshot.filingSummary.needsReview -eq 1) 'Only the selected records leave Review and full counters reflect the durable write'
    Check ($null -eq $result.snapshot.lastDecision -and $result.snapshot.undoBatch.count -eq 2) 'Batch members do not leak into the single-file Undo control'
    $restart=Get-Web $f;$undo=$restart.undoBatch
    Check ($undo.batchId -ceq $result.decision.batchId -and $undo.batchStamp -ceq $result.snapshot.undoBatch.batchStamp) 'A fresh process-style reload recovers the same durable group Undo state'
    $member=@($restart.records|Where-Object decision -ceq 'Approved')[0];$orgPath=Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json';$before=(Get-FileHash $orgPath).Hash;$caught=$false
    try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Undo';id=$member.id;stamp=$member.stamp;reviewId=$member.reviewId})|Out-Null}catch{$caught=$true}
    Check ($caught -and (Get-FileHash $orgPath).Hash -ceq $before) 'An individual Undo cannot partially reverse an atomic grouped action'
    $restored=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Undo';batchId=$undo.batchId;batchStamp=$undo.batchStamp})
    Check ($restored.decision.count -eq 2 -and $restored.decision.undoOfBatchId -ceq $undo.batchId -and $restored.snapshot.filingSummary.needsReview -eq 3 -and $null -eq $restored.snapshot.undoBatch) 'Batch Undo restores every selected previous state together and is not offered again'
    $org=Get-Content $orgPath -Raw|ConvertFrom-Json
    Check ($org.Version -eq 1 -and $org.History.Count -eq 4 -and @($org.History|Where-Object action -ceq 'Undo').Count -eq 2 -and @($org.History|Where-Object batchId -ceq $undo.batchId).Count -eq 2) 'Backward-compatible history retains every individual decision and its bounded batch metadata'
    Check ((Get-FileHash $settings).Hash -ceq $beforeSettings) 'Neither a group nor its Undo teaches a hidden scanner rule'
    Check-BatchProtected $f
}
Scenario 'Grouped Disapprove retains all selected PDFs under Other and explicit batch categories are validated' {
    $f=New-WebBatchFixture 'BatchDisapprove';$snapshot=Get-Web $f;$selected=@(Batch-Selections $snapshot)
    foreach($category in @('Daily','Monthly','Other','',$null)){
        $request=[pscustomobject]@{action='Disapprove';selections=$selected;category=$category};$caught=$false;try{Invoke-QaWebRequest $f.AppRoot $request|Out-Null}catch{$caught=$true}
        Check ($caught -and -not [IO.File]::Exists((Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json'))) 'Disapprove rejects a category override before saving any member'
    }
    foreach($category in @('Monthly_QA','../../Outside')){$caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';selections=$selected;category=$category})|Out-Null}catch{$caught=$true};Check $caught 'Unsupported explicit approval categories cannot become folder paths'}
    $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Disapprove';selections=$selected})
    Check (@($result.snapshot.records|Where-Object{$_.decision -ceq 'Disapproved' -and $_.category -ceq 'Other'}).Count -eq 2 -and $result.snapshot.undoBatch.action -ceq 'Disapprove') 'Disapprove files only the selected documents as Other with durable grouped Undo'
    Check (@(Get-ChildItem $result.snapshot.libraryRoot -Filter '*.pdf' -Recurse).Count -eq 2) 'Original PDFs remain available as selected readable copies'
    Check-BatchProtected $f
}
Scenario 'Grouped selection preflight rejects stale duplicate unknown waiting and oversized selections atomically' {
    foreach($kind in @('Stale','Duplicate','Unknown','Waiting','Oversized','Ambiguous')){
        $f=New-WebBatchFixture ('BatchReject_'+$kind);$snapshot=Get-Web $f;$selected=@(Batch-Selections $snapshot);$request=[pscustomobject]@{action='Approve';selections=$selected}
        switch($kind){
            'Stale'{$selected[1].stamp='0'*64}
            'Duplicate'{$request.selections=@($selected[0],$selected[0])}
            'Unknown'{$selected[1].id='F'*64}
            'Waiting'{$target=@($f.Records|Where-Object Id -ceq $selected[1].id)[0];[IO.File]::Delete((Join-Path $f.Config.ArchiveRoot ('.ctqa/analysis/'+$target.Hash+'.json')));$fresh=Get-Web $f;$waiting=@($fresh.records|Where-Object id -ceq $target.Id)[0];Check ($waiting.filingState -ceq 'WaitingRead') 'The negative control is genuinely awaiting a read';$request.selections=@($selected[0],[pscustomobject]@{id=$waiting.id;stamp=$waiting.stamp})}
            'Oversized'{$request.selections=@(1..51|ForEach-Object{[pscustomobject]@{id=$_.ToString('X64');stamp=('A'*64)}})}
            'Ambiguous'{$request|Add-Member id $selected[0].id}
        }
        $caught=$false;try{Invoke-QaWebRequest $f.AppRoot $request|Out-Null}catch{$caught=$true}
        Check ($caught -and -not [IO.File]::Exists((Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json'))) 'Any invalid member aborts the entire group before a durable decision write'
        Check (-not [IO.File]::Exists((Join-Path $f.Config.ArchiveRoot '.ctqa/web-library.json'))) 'Preflight rejection cannot create a partial readable-library decision'
        Check-BatchProtected $f
    }
}
Scenario 'Exact selected-byte checks prevent partial grouped decisions and partial grouped Undo' {
    $f=New-WebBatchFixture 'BatchHashGuard';$snapshot=Get-Web $f;$selected=@(Batch-Selections $snapshot);$target=@($f.Records|Where-Object Id -ceq $selected[1].id)[0];$bytes=[IO.File]::ReadAllBytes($target.DestinationPath);$stamp=(Get-Item $target.DestinationPath).LastWriteTimeUtc
    try{
        $edited=[byte[]]$bytes.Clone();$edited[$edited.Length-2]=$edited[$edited.Length-2] -bxor 1;[IO.File]::WriteAllBytes($target.DestinationPath,$edited);(Get-Item $target.DestinationPath).LastWriteTimeUtc=$stamp
        $caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';selections=$selected})|Out-Null}catch{$caught=$true}
        Check ($caught -and -not [IO.File]::Exists((Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json'))) 'A same-length same-timestamp edit in the final selected PDF prevents every approval'
    }finally{[IO.File]::WriteAllBytes($target.DestinationPath,$bytes);(Get-Item $target.DestinationPath).LastWriteTimeUtc=$stamp}
    $approved=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';selections=$selected});$undo=$approved.snapshot.undoBatch;$orgPath=Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json';$before=(Get-FileHash $orgPath).Hash
    try{
        [IO.File]::WriteAllBytes($target.DestinationPath,$edited);(Get-Item $target.DestinationPath).LastWriteTimeUtc=$stamp
        $caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Undo';batchId=$undo.batchId;batchStamp=$undo.batchStamp})|Out-Null}catch{$caught=$true}
        Check ($caught -and (Get-FileHash $orgPath).Hash -ceq $before) 'One changed member prevents all grouped Undo writes'
    }finally{[IO.File]::WriteAllBytes($target.DestinationPath,$bytes);(Get-Item $target.DestinationPath).LastWriteTimeUtc=$stamp}
    $org=Get-Content $orgPath -Raw|ConvertFrom-Json;$org.Records[0].revision=[guid]::NewGuid().ToString('N');[IO.File]::WriteAllText($orgPath,($org|ConvertTo-Json -Depth 32),(New-Object Text.UTF8Encoding $true));$before=(Get-FileHash $orgPath).Hash
    $caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Undo';batchId=$undo.batchId;batchStamp=$undo.batchStamp})|Out-Null}catch{$caught=$true}
    Check ($caught -and (Get-FileHash $orgPath).Hash -ceq $before -and $null -eq (Get-Web $f).undoBatch) 'A changed individual after-state invalidates the whole durable group rather than restoring a partial selection'
    Check-BatchProtected $f
}
Scenario 'Batch processing keeps one dashboard pass one selected-library update and durable copy-failure warnings' {
    $f=New-WebBatchFixture 'BatchOnePass';$selected=@(Batch-Selections (Get-Web $f));$module=Get-Module WebService
    $originals=&$module {[pscustomobject]@{Dashboard=(Get-Command Get-QaDashboard).ScriptBlock;Organization=(Get-Command Get-QaWebOrganization).ScriptBlock;Library=(Get-Command Update-QaWebLibrary).ScriptBlock;Copy=(Get-Command Copy-QaWebLibraryPdf).ScriptBlock}}
    $probe=[pscustomobject]@{Dashboards=0;Organizations=0;Libraries=0;Selected=0}
    try{
        &$module {param($Probe,$Originals);$script:BatchProbe=$Probe;$script:BatchOriginals=$Originals
            function script:Get-QaDashboard {param($Config);$script:BatchProbe.Dashboards++;return &$script:BatchOriginals.Dashboard $Config}
            function script:Get-QaWebOrganization {param($Config);$script:BatchProbe.Organizations++;return &$script:BatchOriginals.Organization $Config}
            function script:Update-QaWebLibrary {param($Config,[string[]]$OnlyRecords=@(),$Dashboard=$null,$Organization=$null,$Progress=$null,[switch]$Verify);$script:BatchProbe.Libraries++;$script:BatchProbe.Selected=$OnlyRecords.Count;return &$script:BatchOriginals.Library @PSBoundParameters}
            function script:Copy-QaWebLibraryPdf {param($Source,$Target,$Hash,$Progress,$Metrics);throw 'Synthetic grouped readable-copy failure'}
        } $probe $originals
        $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';selections=$selected;category='Daily'})
        Check ($probe.Dashboards -eq 1 -and $probe.Organizations -eq 1 -and $probe.Libraries -eq 1 -and $probe.Selected -eq 2) 'A batch validates its dashboard and organization once and refreshes one selected-only library operation'
        Check ($result.decision.count -eq 2 -and $result.warning -match '^Decisions saved\.' -and @($result.snapshot.records|Where-Object decision -ceq 'Approved').Count -eq 2 -and $result.snapshot.undoBatch.count -eq 2) 'A readable-copy failure preserves all committed decisions and their group Undo with an honest warning'
    }finally{&$module {param($Originals);Set-Item Function:script:Get-QaDashboard $Originals.Dashboard;Set-Item Function:script:Get-QaWebOrganization $Originals.Organization;Set-Item Function:script:Update-QaWebLibrary $Originals.Library;Set-Item Function:script:Copy-QaWebLibraryPdf $Originals.Copy;Remove-Variable BatchProbe,BatchOriginals -Scope Script -ErrorAction SilentlyContinue} $originals}
    $org=Get-Content (Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json') -Raw|ConvertFrom-Json
    Check ($org.History.Count -eq 2 -and @($org.Records|Where-Object decision -ceq 'Approved').Count -eq 2) 'Only durable individual history determines the visible successful batch'
    Check-BatchProtected $f
}

Scenario 'Approval targets are explicit while legacy single requests remain compatible' {
    $f=New-WebBatchFixture 'SingleTarget' 1;$snapshot=Get-Web $f;$row=$snapshot.records[0]
    Check ($row.approvalCategory -ceq 'Daily' -and -not $row.approvalNeedsCategory) 'A proposed current file target is supplied separately from the generic action name'
    $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';id=$row.id;stamp=$row.stamp;category='Monthly'})
    Check ($result.snapshot.records[0].category -ceq 'Monthly' -and $result.snapshot.records[0].decision -ceq 'Approved') 'A user explicitly choosing Monthly can override the per-file suggestion without teaching a scanner rule'
    $f=New-WebBatchFixture 'UnknownTarget' 1;Set-WebFilingRawCategory $f 'Needs_Review';$f.BeforeCore=(Get-FileHash $f.StatePath).Hash;$path=Set-WebFilingCache $f '' '' 'NeedsReview';$cache=Get-Content $path -Raw|ConvertFrom-Json;$cache.DocumentClassification.SuggestedCategory='';[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding $true));$snapshot=Get-Web $f;$row=$snapshot.records[0]
    Check ($row.category -ceq 'Other' -and $row.approvalCategory -ceq '' -and $row.approvalNeedsCategory) 'A genuinely unsupported Other grouping is not misrepresented as a meaningful proposed classification'
    $selected=@([pscustomobject]@{id=$row.id;stamp=$row.stamp});$caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';selections=$selected})|Out-Null}catch{$caught=$true}
    Check ($caught -and -not [IO.File]::Exists((Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json'))) 'New grouped approval requires an explicit target when no selected file proposal is meaningful'
    $caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Disapprove';id=$row.id;stamp=$row.stamp;category='Daily'})|Out-Null}catch{$caught=$true};Check $caught 'Single Disapprove also refuses a misleading category override'
    $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';selections=$selected;category='Other'})
    Check ($result.snapshot.records[0].decision -ceq 'Approved' -and $result.snapshot.records[0].category -ceq 'Other') 'An explicitly chosen Other target is accepted and retained'
    $legacy=New-WebBatchFixture 'LegacyOtherTarget' 1;Set-WebFilingRawCategory $legacy 'Needs_Review';$legacy.BeforeCore=(Get-FileHash $legacy.StatePath).Hash;$path=Set-WebFilingCache $legacy '' '' 'NeedsReview';$row=(Get-Web $legacy).records[0]
    $result=Invoke-QaWebRequest $legacy.AppRoot ([pscustomobject]@{action='Approve';id=$row.id;stamp=$row.stamp})
    Check ($result.snapshot.records[0].category -ceq 'Other' -and $result.snapshot.records[0].decision -ceq 'Approved') 'Existing single omitted-category requests retain their prior file-organization behavior'
    Check-BatchProtected $f;Check-BatchProtected $legacy
}
Scenario 'Batch read handles prevent an early selected PDF changing before later validation and commit' {
    $f=New-WebBatchFixture 'HeldBatchPdfs';$selected=@(Batch-Selections (Get-Web $f));$module=Get-Module WebService;$original=&$module {(Get-Command Assert-QaWebPdf).ScriptBlock};$copy=&$module {(Get-Command Copy-QaWebLibraryPdf).ScriptBlock}
    $target=@($f.Records|Where-Object Id -ceq $selected[0].id)[0];$bytes=[IO.File]::ReadAllBytes($target.DestinationPath);$time=(Get-Item $target.DestinationPath).LastWriteTimeUtc
    $probe=[pscustomobject]@{Handles=(New-Object 'Collections.Generic.List[object]');Blocked=$false;Changed=$false;HeldDuringCopy=$false;WriteTime=$time}
    try{
        &$module {param($Probe,$Original,$Copy);$script:HeldProbe=$Probe;$script:HeldAssert=$Original;$script:HeldCopy=$Copy
            function script:Assert-QaWebPdf {
                param($Config,$Record,[ref]$ReadHandle)
                $result=&$script:HeldAssert @PSBoundParameters
                if($null -ne $ReadHandle){[void]$script:HeldProbe.Handles.Add($ReadHandle.Value)
                    if($script:HeldProbe.Handles.Count -eq 1){$writer=$null;try{$writer=[IO.File]::Open($result,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$writer.Position=$writer.Length-2;$writer.WriteByte(37);$writer.Dispose();$writer=$null;[IO.File]::SetLastWriteTimeUtc($result,$script:HeldProbe.WriteTime.AddSeconds(5));$script:HeldProbe.Changed=$true}catch [IO.IOException]{$script:HeldProbe.Blocked=$true}finally{if($null -ne $writer){$writer.Dispose()}}}
                };return $result
            }
            function script:Copy-QaWebLibraryPdf {param($Source,$Target,$Hash,$Progress,$Metrics);$script:HeldProbe.HeldDuringCopy=(@($script:HeldProbe.Handles|Where-Object{$_.Stream.CanRead}).Count -eq 2);return &$script:HeldCopy @PSBoundParameters}
        } $probe $original $copy
        $caught=$false;try{$result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';selections=$selected})}catch{$caught=$true}
        if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){Check ($probe.Blocked -and -not $probe.Changed -and -not $caught -and $result.decision.count -eq 2 -and $probe.HeldDuringCopy) 'Windows denies write/delete access after the first exact validation and retains both read handles through commit and readable copies'}else{Check (($probe.Blocked -and -not $caught) -or ($probe.Changed -and $caught -and -not [IO.File]::Exists((Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json')))) 'The development platform either enforces read sharing or rejects the changed pre-commit metadata without any decisions'}
        Check ($probe.Handles.Count -eq 2 -and @($probe.Handles|Where-Object{$_.Stream.CanRead}).Count -eq 0) 'Every selected verification handle is disposed after success or atomic rejection'
    }finally{&$module {param($Original,$Copy);Set-Item Function:script:Assert-QaWebPdf $Original;Set-Item Function:script:Copy-QaWebLibraryPdf $Copy;Remove-Variable HeldProbe,HeldAssert,HeldCopy -Scope Script -ErrorAction SilentlyContinue} $original $copy;[IO.File]::WriteAllBytes($target.DestinationPath,$bytes);(Get-Item $target.DestinationPath).LastWriteTimeUtc=$time}
    Check-BatchProtected $f
}
Scenario 'Batch Undo rejects changed displayed state and corrupt grouped history without rewriting them' {
    $f=New-WebBatchFixture 'BatchUndoStamp';$selected=@(Batch-Selections (Get-Web $f));$result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';selections=$selected});$undo=$result.snapshot.undoBatch;$path=Join-Path $f.Config.ArchiveRoot '.ctqa/organization.json';$before=(Get-FileHash $path).Hash
    $caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Undo';batchId=$undo.batchId;batchStamp=('0'*64)})|Out-Null}catch{$caught=$true}
    Check ($caught -and (Get-FileHash $path).Hash -ceq $before) 'A stale displayed group stamp cannot restore any subset'
    $original=[IO.File]::ReadAllBytes($path);$org=Get-Content $path -Raw|ConvertFrom-Json;$org.History[0].before=$org.History[1].after;[IO.File]::WriteAllText($path,($org|ConvertTo-Json -Depth 32),(New-Object Text.UTF8Encoding $true));$before=(Get-FileHash $path).Hash;$caught=$false;try{Get-Web $f|Out-Null}catch{$caught=$true}
    Check ($caught -and (Get-FileHash $path).Hash -ceq $before) 'A prior classification belonging to a different member cannot be accepted as a restorable batch state'
    [IO.File]::WriteAllBytes($path,$original)
    $org=Get-Content $path -Raw|ConvertFrom-Json;$org.History=@($org.History|Select-Object -First 1);[IO.File]::WriteAllText($path,($org|ConvertTo-Json -Depth 32),(New-Object Text.UTF8Encoding $true));$before=(Get-FileHash $path).Hash;$caught=$false;try{Get-Web $f|Out-Null}catch{$caught=$true}
    Check ($caught -and (Get-FileHash $path).Hash -ceq $before) 'Missing persisted batch members are reported as corrupt history rather than silently treated as ordinary single decisions'
    Check-BatchProtected $f
}

Scenario 'The fifty-file boundary remains selected-only and grouped Undo survives unrelated single history' {
    $f=New-WebBatchFixture 'BatchLimitBoundary' 51;$initial=Get-Web $f;$selected=@(Batch-Selections $initial 50);$result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';selections=$selected})
    Check ($result.decision.count -eq 50 -and @($result.snapshot.records|Where-Object decision -ceq 'Approved').Count -eq 50 -and $result.snapshot.filingSummary.needsReview -eq 1 -and $result.snapshot.undoBatch.count -eq 50) 'Exactly fifty selected exceptions can be filed while the fifty-first remains untouched'
    $last=@($result.snapshot.records|Where-Object filingState -ceq 'NeedsReview')[0];$single=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Disapprove';id=$last.id;stamp=$last.stamp})
    Check ($single.snapshot.lastDecision.recordId -ceq $last.id -and $single.snapshot.undoBatch.batchId -ceq $result.decision.batchId) 'Unrelated single-file history retains both the correct single Undo and the still-valid group Undo'
    $undo=$single.snapshot.undoBatch;$restored=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Undo';batchId=$undo.batchId;batchStamp=$undo.batchStamp})
    Check ($restored.decision.count -eq 50 -and $restored.snapshot.filingSummary.needsReview -eq 50 -and @($restored.snapshot.records|Where-Object{$_.id -ceq $last.id -and $_.decision -ceq 'Disapproved'}).Count -eq 1) 'Grouped Undo restores all fifty members without reversing the unrelated saved decision'
    Check-BatchProtected $f
}

Scenario 'Omitted batch overrides preserve each selected Daily or Monthly proposal independently' {
    $f=New-WebBatchFixture 'MixedApprovalTargets';$cfg=Read-QaConfig $f.AppRoot;$source=@($cfg.Sources|Where-Object Scanner -ceq 'CT_Edge')[0];$source|Add-Member ContentProfiles @([pscustomobject]@{profileId='siemens-iec-basic-v1';category='Ask'},[pscustomobject]@{profileId='siemens-iec-extended-v1';category='Ask'}) -Force;[void](Save-QaConfig $f.AppRoot $cfg)
    $other=[pscustomobject]@{Record=$f.Records[1];AppRoot=$f.AppRoot};[void](Set-WebFilingCache $other 'siemens-iec-extended-v1');$snapshot=Get-Web $f;$ids=@($f.Records[0].Id,$f.Records[1].Id);$selected=@($snapshot.records|Where-Object{$ids -contains $_.id}|ForEach-Object{[pscustomobject]@{id=$_.id;stamp=$_.stamp}})
    Check (@($snapshot.records|Where-Object{$ids -contains $_.id -and $_.approvalCategory -ceq 'Daily'}).Count -eq 1 -and @($snapshot.records|Where-Object{$ids -contains $_.id -and $_.approvalCategory -ceq 'Monthly'}).Count -eq 1) 'The displayed selection contains one distinct Daily and one distinct Monthly proposal'
    $result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Approve';selections=$selected})
    Check (@($result.snapshot.records|Where-Object{$_.id -ceq $f.Records[0].Id -and $_.decision -ceq 'Approved' -and $_.category -ceq 'Daily'}).Count -eq 1 -and @($result.snapshot.records|Where-Object{$_.id -ceq $f.Records[1].Id -and $_.decision -ceq 'Approved' -and $_.category -ceq 'Monthly'}).Count -eq 1) 'Without an explicit group override, each selected report is filed under its own visible proposal'
    Check ($result.snapshot.filingSummary.needsReview -eq 1) 'The unselected third report remains in Review'
    Check-BatchProtected $f
}

Scenario 'Alignment inspector rows share current graph capability body and explicit-context eligibility' {
    $f=New-WebBatchFixture 'InspectorAlignmentGuard' 1;$path=Set-WebFilingCache $f 'siemens-iec-extended-v1';$cache=Get-Content $path -Raw|ConvertFrom-Json
    $cache.MeasurementsDocument|Add-Member MeasurementSupportRevision 3 -Force;$cache.MeasurementsDocument.Status='Extracted';$cache.DocumentClassification.Sections=@('Lightmarker','ExternalLightmarker','TopogramPosition','SagittalCoronalLightmarker'|ForEach-Object{[pscustomobject]@{Code=$_;BodyEvidence=$true;Page=3;PrintedOutcomes=@('OK')}})
    $rows=New-Object 'Collections.Generic.List[object]'
    foreach($code in @('Lightmarker','ExternalLightmarker','TopogramPosition','SagittalCoronalLightmarker')){foreach($context in $(if($code -ceq 'SagittalCoronalLightmarker'){@('Sagittal','Coronal')}else{@('Overall')})){[void]$rows.Add([pscustomobject]@{Code=$code;Value='0.3';Unit='mm';Page=3;Mode='Unspecified';SourceSystem='NotSpecified';Slice='';Context=$context;ContextSection=$code;Source='PrintedAlignmentResult';Status='Printed'})}}
    [void]$rows.Add([pscustomobject]@{Code='WaterCTNumber';Value='0.2';Unit='HU';Page=3});$cache.MeasurementsDocument.Measurements=@($rows.ToArray());$valid=$cache|ConvertTo-Json -Depth 20;[IO.File]::WriteAllText($path,$valid,(New-Object Text.UTF8Encoding $true));$snapshot=Get-Web $f
    Check ($snapshot.records[0].content.measurements.Count -eq 6 -and @($snapshot.records[0].content.measurements|Where-Object{$_.context -cin @('Overall','Sagittal','Coronal')}).Count -eq 5) 'The positive control exposes all five validated scalar/axis readings and an unchanged legacy HU row'
    foreach($kind in @('OldCapability','WrongProfile','DocumentStatus','StringBodyEvidence','WrongSection','WrongSource','InventedSystem','InventedSlice','WrongMode','ArbitraryContext','MissingAxis','IncompleteMeasurement','DateConflict','WrongPage','WrongRowStatus')){
        $bad=$valid|ConvertFrom-Json
        switch($kind){
            'OldCapability'{$bad.MeasurementsDocument.MeasurementSupportRevision=2}
            'WrongProfile'{$bad.DocumentClassification.ProfileId='siemens-iec-basic-v1'}
            'DocumentStatus'{$bad.DocumentClassification.Status='NeedsReview'}
            'StringBodyEvidence'{foreach($section in $bad.DocumentClassification.Sections){$section.BodyEvidence='true'}}
            'WrongSection'{foreach($row in $bad.MeasurementsDocument.Measurements){if($row.Code -cne 'WaterCTNumber'){$row.ContextSection='Noise'}}}
            'WrongSource'{foreach($row in $bad.MeasurementsDocument.Measurements){if($row.Code -cne 'WaterCTNumber'){$row.Source='PrintedSingleMetricTable'}}}
            'InventedSystem'{foreach($row in $bad.MeasurementsDocument.Measurements){if($row.Code -cne 'WaterCTNumber'){$row.SourceSystem='A'}}}
            'InventedSlice'{foreach($row in $bad.MeasurementsDocument.Measurements){if($row.Code -cne 'WaterCTNumber'){$row.Slice='1'}}}
            'WrongMode'{foreach($row in $bad.MeasurementsDocument.Measurements){if($row.Code -cne 'WaterCTNumber'){$row.Mode='Head'}}}
            'ArbitraryContext'{foreach($row in $bad.MeasurementsDocument.Measurements){if($row.Code -cne 'WaterCTNumber'){$row.Context='Unverified'}}}
            'MissingAxis'{foreach($row in $bad.MeasurementsDocument.Measurements){if($row.Code -ceq 'SagittalCoronalLightmarker'){$row.Context='Overall'}elseif($row.Code -cne 'WaterCTNumber'){$row.Context='Sagittal'}}}
            'IncompleteMeasurement'{$bad.MeasurementsDocument.CompleteRead=$false}
            'DateConflict'{$bad.DocumentClassification.ReportTime='01:02:03'}
            'WrongPage'{foreach($row in $bad.MeasurementsDocument.Measurements){if($row.Code -cne 'WaterCTNumber'){$row.Page=4}}}
            'WrongRowStatus'{foreach($row in $bad.MeasurementsDocument.Measurements){if($row.Code -cne 'WaterCTNumber'){$row.Status='Invented'}}}
        }
        [IO.File]::WriteAllText($path,($bad|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true));$projection=(Get-Web $f).records[0].content.measurements
        Check ($projection.Count -eq 1 -and $projection[0].label -ceq 'Water CT value') 'Rejected new alignment evidence cannot appear in the inspector while the preexisting HU compatibility path remains unchanged'
    }
    [IO.File]::WriteAllText($path,$valid,(New-Object Text.UTF8Encoding $true));Check-BatchProtected $f
}

Scenario 'Monthly reads use cached scoped data without full snapshots PDF work or archive writes' {
    $f=New-WebBatchFixture 'MonthlyReadOnlyApi' 4;$cfg=Read-QaConfig $f.AppRoot;$source=@($cfg.Sources|Where-Object Scanner -ceq 'CT_Edge')[0];$source.ContentProfiles=@([pscustomobject]@{profileId='siemens-iec-basic-v1';category='Auto'});[void](Save-QaConfig $f.AppRoot $cfg)
    $item=[pscustomobject]@{Record=$f.Records[0];AppRoot=$f.AppRoot};$path=Set-WebFilingCache $item 'siemens-iec-extended-v1';$cache=Get-Content $path -Raw|ConvertFrom-Json;$cache.DocumentClassification.Sections=@('MTF','Slice'|ForEach-Object{[pscustomobject]@{Code=$_;Page=3;BodyEvidence=$true;EvidenceCode=('NumberedBodySection.'+$_);PrintedOutcomes=@('OK')}});[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true))
    $item=[pscustomobject]@{Record=$f.Records[2];AppRoot=$f.AppRoot};[void](Set-WebFilingCache $item '' '' 'NeedsReview');$item=[pscustomobject]@{Record=$f.Records[3];AppRoot=$f.AppRoot};[void](Set-WebFilingCache $item 'siemens-iec-reference-v1' 'Other' 'Recognized' 'Consensus' $true)
    $files=@(Get-ChildItem $f.AppRoot -Recurse -File|ForEach-Object{[pscustomobject]@{Path=$_.FullName;Hash=(Get-FileHash $_.FullName).Hash}});$module=Get-Module WebService;$names=@('Get-QaDashboard','Get-QaWebSnapshot','Invoke-QaOperation','Update-QaWebLibrary','Write-QaWebAtomic','Write-QaSupportEvent','Assert-QaWebPdf');$originals=@{}
    try{
        foreach($name in $names){$originals[$name]=&$module {param($n)(Get-Command $n).ScriptBlock} $name;&$module {param($n)Set-Item ('Function:script:'+$n) {throw 'Monthly attempted a forbidden write, full snapshot, dashboard or PDF operation.'}} $name}
        $month=(Get-Date).ToString('yyyy-MM');$model=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Monthly';month=$month});$row=@($model.scanners|Where-Object id -ceq 'CT_Edge')[0]
        Check ($model.schemaVersion -eq 1 -and $model.month -ceq $month -and $null -eq $model.PSObject.Properties['snapshot']) 'The endpoint returns its bounded read model directly'
        Check ($row.receipt.count -eq 1 -and $row.receipt.reviewCount -eq 1 -and $row.excludedReferenceCount -eq 1) 'Monthly receipt excludes Daily and Reference files while processed Monthly exceptions remain separate'
        Check ($row.detected.allItemsFound -and $row.detected.foundCount -eq 2 -and $row.reviewed.confirmedReportCount -eq 0) 'Observed printed components never fabricate recorded clinical evidence'
        $json=$model|ConvertTo-Json -Depth 20 -Compress;Check (-not $json.Contains($f.Config.ArchiveRoot) -and $json -notmatch '"(?:SourcePath|DestinationPath|Username|Password|Text)"') 'The local model projects bounded report IDs and controlled metadata instead of raw cached/config/path objects'
        foreach($bad in @('2026-13','2026-1','2026-11-01','../2026-11','0000-01')){$caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Monthly';month=$bad})|Out-Null}catch{$caught=$true};Check $caught 'The backend independently requires one exact real calendar month'}
    }finally{foreach($name in $names){&$module {param($n,$body)Set-Item ('Function:script:'+$n) $body} $name $originals[$name]}}
    Check (@(Get-ChildItem $f.AppRoot -Recurse -File).Count -eq $files.Count) 'Read-only Monthly requests create no new archive, library or activity files'
    foreach($file in $files){Check ((Get-FileHash $file.Path).Hash -ceq $file.Hash) 'Every preexisting settings, cache, archive and original PDF byte remains unchanged'}
}
Scenario 'Monthly setup validates bounded values preserves network settings and versions changed checklists' {
    $f=New-WebFixture 'MonthlySetupApi';[void](Get-Web $f);$before=Read-QaConfig $f.AppRoot;$original=$before.Sources[0];$settings=Join-Path $f.AppRoot 'Config/Settings.local.json';$core=(Get-FileHash $f.StatePath).Hash
    foreach($payload in @(@{expectedMonthly='true'},@{monthlyDueDay=1.5},@{monthlyDueDay=$true},@{monthlyDueDay=32},@{checklist='MTF'},@{checklist=@([pscustomobject]@{Label='MTF'})},@{checklist=@('=Formula')},@{checklistEffectiveMonth='2026-13'})){
        $request=@{action='ScannerSettings';scanner='CT_Edge'};foreach($key in $payload.Keys){$request[$key]=$payload[$key]};$saved=(Get-FileHash $settings).Hash;$caught=$false;try{Invoke-QaWebRequest $f.AppRoot ([pscustomobject]$request)|Out-Null}catch{$caught=$true};Check ($caught -and (Get-FileHash $settings).Hash -ceq $saved) 'Malformed Monthly setup cannot silently coerce values or replace configuration'
    }
    $oldSnapshot=Get-Web $f;$effective=$oldSnapshot.scanners[0].nextChecklistEffectiveMonth;$result=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='ScannerSettings';scanner='CT_Edge';expectedMonthly=$true;monthlyDueDay=22;checklist=@('MTF');checklistEffectiveMonth=''})
    $saved=Read-QaConfig $f.AppRoot;$source=$saved.Sources[0]
    Check ($result.snapshot.scanners[0].checklistEffectiveMonth -ceq $effective -and $result.snapshot.scanners[0].monthlyChecklistHistory.Count -ge 2) 'A blank legacy effective field uses the explicit next allowed version rather than overwriting history'
    Check ($source.Path -ceq $original.Path -and $source.Username -ceq $original.Username -and $source.DriveLetter -ceq $original.DriveLetter -and $source.Name -ceq $original.Name) 'Monthly-only setup does not change scanner connections or identity'
    Check ($source.MonthlyDueDay -eq 22 -and @($source.MonthlyChecklist).Count -eq 1 -and $source.MonthlyChecklist[0] -ceq 'MTF') 'A bounded one-item checklist remains an array and due day persists'
    Check ((Get-FileHash $f.StatePath).Hash -ceq $core -and (Get-FileHash $f.Source).Hash -ceq $f.SourceHash) 'Setup changes no protected clinical or original PDF data'
}
Scenario 'Opaque trend revisions ignore identical reordered theme and connection snapshots but follow cached data changes' {
    $f=New-WebBatchFixture 'TrendsRevisionApi';$a=Get-Web $f;$b=Get-Web $f
    Check ($a.trendsRevision -cmatch '^[A-Fa-f0-9]{64}$' -and $a.trendsRevision -ceq $b.trendsRevision) 'Identical snapshots have a stable opaque graph revision'
    $cfg=Read-QaConfig $f.AppRoot;$dashboard=Get-QaDashboard $cfg;$reverse=$dashboard|Select-Object *;$reverse.Records=@($dashboard.Records|Sort-Object Id -Descending);$other=&(Get-Module WebService){param($c,$d)Get-QaWebSnapshot -Config $c -Dashboard $d} $cfg $reverse
    Check ($a.trendsRevision -ceq $other.trendsRevision) 'Record enumeration order does not dirty trend requests'
    $theme=Invoke-QaWebRequest $f.AppRoot ([pscustomobject]@{action='Settings';theme='Dark'});Check ($theme.snapshot.trendsRevision -ceq $a.trendsRevision) 'Theme and UI settings do not invent a graph data change'
    $connections=Join-Path $f.Config.ArchiveRoot '.ctqa/web-connections.json';[IO.File]::WriteAllText($connections,'{"Connections":[]}',(New-Object Text.UTF8Encoding $true));Check ((Get-Web $f).trendsRevision -ceq $a.trendsRevision) 'Connection status files do not invalidate cached measurement queries'
    $path=Join-Path $f.Config.ArchiveRoot ('.ctqa/analysis/'+$f.Records[0].Hash+'.json');$cache=Get-Content $path -Raw|ConvertFrom-Json;$cache.MeasurementsDocument.Measurements=@([pscustomobject]@{Code='WaterCTNumber';Value='0.2';Unit='HU';Page=3});[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true));$c=Get-Web $f
    $cache.MeasurementsDocument.Measurements[0].Value='0.3';[IO.File]::WriteAllText($path,($cache|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true));[IO.File]::SetLastWriteTimeUtc($path,[datetime]::UtcNow.AddSeconds(2));$d=Get-Web $f
    Check ($c.trendsRevision -cne $d.trendsRevision -and $c.records.Count -eq $d.records.Count) 'A same-count same-width printed value update changes the cache/provenance fingerprint'
    [IO.File]::SetLastWriteTimeUtc($f.Records[0].DestinationPath,[datetime]::UtcNow.AddSeconds(3));$e=Get-Web $f;Check ($e.trendsRevision -cne $d.trendsRevision) 'A cache becoming stale against the saved PDF changes graph eligibility'
}
Scenario 'Table-position inspector rows require the complete capability-four eight-context table' {
    $f=New-WebFixture 'TablePositionFacade';$path=Set-WebFilingCache $f 'siemens-iec-additional-v1';$cache=Get-Content $path -Raw|ConvertFrom-Json;$cache.MeasurementsDocument|Add-Member MeasurementSupportRevision 4 -Force;$cache.MeasurementsDocument.Status='Extracted';$cache.DocumentClassification.Sections=@([pscustomobject]@{Code='TablePosition';BodyEvidence=$true;Page=3;EvidenceCode='NumberedBodySection.TablePosition';PrintedOutcomes=@('OK')})
    $rows=@(foreach($method in @('Continuous','Stepwise')){foreach($position in 1..4){[pscustomobject]@{Code='TablePosition';Value='0.2';Unit='mm';Page=3;LowerLimit='-1';UpperLimit='1';Mode='Unspecified';SourceSystem='NotSpecified';Slice='';Context=($method+'Position'+$position);ContextSection='TablePosition';Source='PrintedTablePositionResult';Status='Printed'}}})
    $cache.MeasurementsDocument.Measurements=$rows;$valid=$cache|ConvertTo-Json -Depth 20;[IO.File]::WriteAllText($path,$valid,(New-Object Text.UTF8Encoding $true));$projection=(Get-Web $f).records[0].content.measurements
    Check ($projection.Count -eq 8 -and @($projection|Where-Object{$_.label -ceq 'Table position' -and $_.context -cmatch '^(Continuous|Stepwise)Position[1-4]$'}).Count -eq 8) 'All eight verified method/position readings appear without invented acquisition identities'
    foreach($kind in @('OldCapability','MissingRow','DuplicateContext','WrongSource','InventedSystem','MixedPages','WrongProfile','MissingLimits')){
        $bad=$valid|ConvertFrom-Json;switch($kind){'OldCapability'{$bad.MeasurementsDocument.MeasurementSupportRevision=3}'MissingRow'{$bad.MeasurementsDocument.Measurements=@($bad.MeasurementsDocument.Measurements|Select-Object -First 7)}'DuplicateContext'{$bad.MeasurementsDocument.Measurements[7].Context='ContinuousPosition1'}'WrongSource'{$bad.MeasurementsDocument.Measurements[0].Source='PrintedAlignmentResult'}'InventedSystem'{$bad.MeasurementsDocument.Measurements[0].SourceSystem='A'}'MixedPages'{$bad.MeasurementsDocument.Measurements[0].Page=2}'WrongProfile'{$bad.DocumentClassification.ProfileId='siemens-iec-basic-v1'}'MissingLimits'{$bad.MeasurementsDocument.Measurements[0].LowerLimit=''}}
        [IO.File]::WriteAllText($path,($bad|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true));Check ((Get-Web $f).records[0].content.measurements.Count -eq 0) 'An incomplete, legacy or malformed table is withheld as a whole rather than partially projected'
    }
}

$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Version='5.4.0';Runtime=$PSVersionTable.PSVersion.ToString();Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Synthetic PDFs, local scanner folders and controlled cached classifier observations with matching fixture-byte provenance; actual extraction is covered separately. Hands-off filing policy, inferred-label disclosure, waiting/review counters, independent file organization, no fabricated clinical review, stale/changed-file rejection, append-only Undo, readable ownership, exports and stdin/stdout JSON worker.'}
if($OutputPath){$report|ConvertTo-Json -Depth 12|Set-Content $OutputPath -Encoding UTF8}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
if([IO.Directory]::Exists($TestRoot)){Remove-Item $TestRoot -Recurse -Force}
if($failed){exit 1}
