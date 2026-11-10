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
    $source=Add-Report $cfg 'CT_Edge' 'Monthly_Constancy' (Get-Date).ToString('yyyy-MM-dd') '08-00-00' 95000
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
$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Version='5.0.1';Runtime=$PSVersionTable.PSVersion.ToString();Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Synthetic PDFs and local scanner folders; independent file organization, no fabricated clinical review, stale/changed-file rejection, append-only Undo, readable ownership, exports and stdin/stdout JSON worker.'}
if($OutputPath){$report|ConvertTo-Json -Depth 12|Set-Content $OutputPath -Encoding UTF8}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
if([IO.Directory]::Exists($TestRoot)){Remove-Item $TestRoot -Recurse -Force}
if($failed){exit 1}
