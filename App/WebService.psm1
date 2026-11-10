# Offline HTML application adapter. Organization decisions are not clinical review.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
foreach($name in @('Archive','Workspace','Review','Network','Credentials','Insights','Reports','Maintenance','Support','Updates','PdfPreview')){Import-Module (Join-Path $PSScriptRoot ($name+'.psm1')) -DisableNameChecking -WarningAction SilentlyContinue}
function Get-QaWebValue($Object,[string]$Name,$Default=$null){
    if($null -eq $Object){return $Default};if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}elseif($null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name};return $Default
}
function Assert-QaWebDirect([string]$Path){
    $p=[IO.Path]::GetFullPath($Path)
    while($p){if(([IO.File]::Exists($p) -or [IO.Directory]::Exists($p)) -and (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Use a direct local folder, not a link or junction.'};$p=[IO.Path]::GetDirectoryName($p)}
}
function Write-QaWebAtomic([string]$Path,$Object){
    Assert-QaWebDirect $Path;Assert-QaWebDirect ($Path+'.bak');[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));$temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllText($temp,($Object|ConvertTo-Json -Depth 32),(New-Object Text.UTF8Encoding $true));if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,($Path+'.bak'))}else{[IO.File]::Move($temp,$Path)}}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Get-QaWebHash([string]$Text){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','')}finally{$sha.Dispose()}}
function Assert-QaWebOrganizationEntry($Entry){
    if($null -eq $Entry){return}
    foreach($name in @('id','hash','revision','decision','category')){if($null -eq $Entry.PSObject.Properties[$name]){throw 'The file-organization history contains an incomplete entry. It was preserved.'}}
    if([string]$Entry.id -notmatch '^[a-fA-F0-9]{64}$' -or [string]$Entry.hash -notmatch '^[a-fA-F0-9]{64}$' -or [string]$Entry.revision -notmatch '^[a-fA-F0-9]{32}$' -or [string]$Entry.decision -cnotin @('','Approved','Disapproved') -or [string]$Entry.category -cnotin @('','Daily','Monthly','Other')){throw 'The file-organization history contains unsupported values. It was preserved.'}
    if($Entry.decision -and -not $Entry.category){throw 'The file-organization history has a missing document type. It was preserved.'}
}
function Get-QaWebOrganization($Config){
    $path=Join-Path $Config.ArchiveRoot '.ctqa/organization.json';Assert-QaWebDirect $path
    if(-not [IO.File]::Exists($path)){return [pscustomobject]@{Version=1;Records=@();History=@()}}
    try{$state=[IO.File]::ReadAllText($path)|ConvertFrom-Json}catch{throw 'The file-organization history could not be read. It was preserved; restore its verified backup before making further decisions.'}
    if($state.Version -ne 1 -or $null -eq $state.PSObject.Properties['Records'] -or $null -eq $state.PSObject.Properties['History']){throw 'Unsupported file-organization history. No data was changed.'}
    $seen=@{};foreach($entry in @($state.Records)){Assert-QaWebOrganizationEntry $entry;if($seen.ContainsKey([string]$entry.id)){throw 'The file-organization history contains duplicate report entries.'};$seen[[string]$entry.id]=$true}
    foreach($history in @($state.History)){if([string]$history.reviewId -notmatch '^[a-fA-F0-9]{32}$' -or [string]$history.recordId -notmatch '^[a-fA-F0-9]{64}$' -or [string]$history.action -cnotin @('Approve','Disapprove','Undo')){throw 'The file-organization action history contains unsupported values.'};Assert-QaWebOrganizationEntry $history.before;Assert-QaWebOrganizationEntry $history.after}
    return $state
}
function Get-QaWebEntry($Organization,$Record){$entries=@($Organization.Records|Where-Object{[string]$_.id -ceq [string]$Record.Id -and [string]$_.hash -ceq [string]$Record.Hash});if($entries.Count -gt 1){throw 'A report has conflicting organization records.'};if($entries.Count){return $entries[0]};return $null}
function Get-QaWebStamp($Record,$Entry){return Get-QaWebHash ((Get-QaRecordReviewStamp $Record)+'|'+[string](Get-QaWebValue $Entry revision '')+'|'+[string](Get-QaWebValue $Entry decision '')+'|'+[string](Get-QaWebValue $Entry category ''))}
function Get-QaWebCategory($Record,$Entry){
    if([string](Get-QaWebValue $Entry decision '') -in @('Approved','Disapproved')){return [string]$Entry.category}
    switch([string]$Record.Category){'Daily_QA'{return 'Daily'}'Monthly_QA'{return 'Monthly'}'Monthly_QA/Pending_Verification'{return 'Monthly'}default{return 'Other'}}
}
function Get-QaWebRecord($Dashboard,[string]$Id){if($Id -notmatch '^[0-9a-fA-F]{64}$'){throw 'Choose a saved report.'};$matches=@($Dashboard.Records|Where-Object Id -ceq $Id);if($matches.Count -ne 1){throw 'The saved report is no longer available. Refresh the report list.'};return $matches[0]}
function Assert-QaWebPdf($Config,$Record){
    $path=[IO.Path]::GetFullPath([string]$Record.DestinationPath);$root=[IO.Path]::GetFullPath((Join-Path $Config.ArchiveRoot 'Reports')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($path) -ine '.pdf'){throw 'This report is outside the verified local archive.'}
    Assert-QaWebDirect $path;if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne [string]$Record.Hash){throw 'The saved PDF is missing or has changed. Run the archive check before using this report.'};return $path
}
function Get-QaWebConnectionRows($Config){
    $path=Join-Path $Config.ArchiveRoot '.ctqa/web-connections.json';Assert-QaWebDirect $path
    if([IO.File]::Exists($path)){try{return @(([IO.File]::ReadAllText($path)|ConvertFrom-Json).Connections)}catch{}}
    return @()
}
function Get-QaWebSnapshot {
    [CmdletBinding()]param($Config)
    $dashboard=Get-QaDashboard $Config;$organization=Get-QaWebOrganization $Config;$records=New-Object 'Collections.Generic.List[object]';$connections=@(Get-QaWebConnectionRows $Config);$sources=@{}
    foreach($source in $Config.Sources){$sources[[string]$source.Scanner]=$source}
    foreach($record in @($dashboard.Records|Sort-Object ReportDate,ReportTime -Descending)){
        $entry=Get-QaWebEntry $organization $record;$decision=[string](Get-QaWebValue $entry decision '');$category=Get-QaWebCategory $record $entry;$pending=Test-QaReportPending $record;if($decision -in @('Approved','Disapproved')){$pending=$false}
        $date=[string]$record.ReportDate;$name=[string]$sources[[string]$record.Scanner].Name
        [void]$records.Add([pscustomobject]@{id=[string]$record.Id;scanner=[string]$record.Scanner;scannerName=$name;date=$date;time=[string]$record.ReportTime;title=($name+' - '+$date+' - '+$category+' QA');filename=[string]$record.OriginalFileName;category=$category;pending=[bool]$pending;decision=$(if($decision){$decision}elseif($pending){'Pending'}elseif([string](Get-QaWebValue $record ReviewDecision '') -eq 'Declined'){'Disapproved'}elseif([string](Get-QaWebValue $record ConfirmedBy '') -and [string](Get-QaWebValue $record ConfirmedAt '')){'Approved'}else{'Organized'});stamp=(Get-QaWebStamp $record $entry);reviewId=[string](Get-QaWebValue $entry revision '');printedResult='Not inferred from file classification';clinicalComponents=@(Get-QaWebValue $record ConfirmedComponents @());classificationOnly=$true})
    }
    $scanners=New-Object 'Collections.Generic.List[object]'
    foreach($source in $Config.Sources){
        $row=@($dashboard.Scanners|Where-Object Scanner -eq $source.Scanner|Select-Object -First 1);$connection=@($connections|Where-Object Scanner -eq $source.Scanner|Select-Object -Last 1)
        $status=if(Test-QaPlaceholderConnection $source){'NotConfigured'}elseif($connection.Count){[string]$connection[0].Status}elseif($row.Count){[string]$row[0].Status}else{'Unknown'}
        $message=if($status -eq 'NotConfigured'){'Apply your scanner connection profile or enter the real reports folder.'}elseif($connection.Count){[string]$connection[0].Message}elseif($row.Count){[string]$row[0].Message}else{'Use Test connection to check this scanner.'}
        [void]$scanners.Add([pscustomobject]@{id=[string]$source.Scanner;name=[string]$source.Name;path=[string]$source.Path;username=[string]$source.Username;drive=[string]$source.DriveLetter;status=$status;message=$message;code=$(if($connection.Count){[int](Get-QaWebValue $connection[0] NativeCode 0)}else{0});savedReports=@($records|Where-Object scanner -eq $source.Scanner).Count;dailySchedule=[string]$source.DailySchedule;activeFrom=[string]$source.ActiveFrom;expectedMonthly=[bool]$source.ExpectedMonthly;monthlyDueDay=[int](Get-QaWebValue $source MonthlyDueDay 0);checklist=@(Get-QaWebValue $source MonthlyChecklist @());excludedDates=@(Get-QaWebValue $source ExcludedDates @())})
    }
    $today=Get-QaTodayOverview $Config $dashboard
    # Organizationally approved Daily documents can satisfy receipt, never clinical passage.
    $received=0;$expected=0;$day=(Get-Date).ToString('yyyy-MM-dd')
    foreach($t in $today.Scanners){if($t.Required){$expected++;if(@($records|Where-Object{$_.scanner -eq $t.Scanner -and $_.date -eq $day -and $_.category -eq 'Daily' -and -not $_.pending}).Count){$received++}}}
    $headline=if(-not $expected){'No Daily QA reports scheduled today'}elseif($received -eq $expected){'All required Daily QA reports received'}else{"$received of $expected Daily QA reports received"}
    $last=$null
    foreach($history in @($organization.History|Select-Object -Last 1)){
        if($history.action -eq 'Undo'){continue};$matching=@($records|Where-Object id -ceq $history.recordId);if($matching.Count -eq 1 -and $matching[0].reviewId -ceq $history.reviewId){$last=[pscustomobject]@{recordId=$history.recordId;reviewId=$history.reviewId;stamp=$matching[0].stamp}}
    }
    return [pscustomobject]@{version='5.0.1';previewMode=$(if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'windows'}else{'browser'});workspace=[string]$Config.AppRoot;archiveRoot=[string]$Config.ArchiveRoot;libraryRoot=(Join-Path $Config.ArchiveRoot 'Report Library');setupComplete=[bool]$dashboard.SetupComplete;records=@($records.ToArray());scanners=@($scanners.ToArray());today=[pscustomobject]@{headline=$headline;received=$received;expected=$expected;date=$day};months=@(Get-QaMonthOverview $Config $dashboard|ForEach-Object{[pscustomobject]@{scanner=$_.Scanner;name=$_.Name;month=$_.Month;progress=$_.Progress;due=$_.Due;timing=$_.Timing;detail=$_.Detail;status=$_.Status}});analysis=$( $a=Get-QaAnalysisProgress $Config @($dashboard.Records);[pscustomobject]@{total=$a.Total;cached=$a.Cached;pending=$a.Pending;errors=$a.Errors});settings=[pscustomobject]@{monitorMinutes=[int](Get-QaWebValue $Config MonitorMinutes 15);autoAnalyze=[bool](Get-QaWebValue $Config AutoAnalyze $true);autoUpdateOnOpen=[bool](Get-QaWebValue $Config AutoUpdateOnOpen $true)};lastDecision=$last;attentionCount=@($dashboard.Attention).Count;onlineEnabled=$false}
}
function ConvertTo-QaWebName([string]$Name){$name=($Name -replace '[<>:"/\\|?*\x00-\x1f]','-').Trim().TrimEnd('.',' ');if(-not $name){$name='Report'};if($name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){$name='Report-'+$name};if($name.Length -gt 42){$name=$name.Substring(0,42)};return $name}
function Test-QaWebRelative([string]$Path){if(-not $Path -or $Path -match '[\\:\x00-\x1f]' -or $Path.StartsWith('/')){return $false};foreach($part in $Path.Split('/')){if($part -in @('','.','..')){return $false}};return $true}
function Get-QaWebFolderNames($Config){
    $map=@{};foreach($source in $Config.Sources){$map[[string]$source.Scanner]=ConvertTo-QaWebName ([string]$source.Name)}
    for($pass=0;$pass -le @($Config.Sources).Count;$pass++){
        $groups=@($Config.Sources|ForEach-Object{[pscustomobject]@{id=[string]$_.Scanner;folder=$map[[string]$_.Scanner]}}|Group-Object folder|Where-Object Count -gt 1)
        if(-not $groups.Count){return $map};foreach($group in $groups){foreach($row in $group.Group){$map[$row.id]=$row.id}}
    };throw 'Scanner folder names could not be made unique.'
}
function Get-QaWebRelative($Record,[string]$Category,[string]$ScannerName){
    $date=[datetime]::MinValue;$valid=[datetime]::TryParseExact([string]$Record.ReportDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)
    $year=if($valid){$date.ToString('yyyy')}else{'Unknown Date'};$month=if($valid){$date.ToString('MM - MMMM',[Globalization.CultureInfo]::InvariantCulture)}else{'Undated'};$day=if($valid){$date.ToString('yyyy-MM-dd')}else{'Undated'}
    $time=([string]$Record.ReportTime -replace '[^0-9]','');if($time.Length -gt 6){$time=$time.Substring(0,6)};if(-not $time){$time='unknown'}
    $scanner=ConvertTo-QaWebName $ScannerName;$name=ConvertTo-QaWebName ([IO.Path]::GetFileNameWithoutExtension([string]$Record.OriginalFileName))
    return ($scanner+'/'+$year+'/'+$month+'/'+$Category+'/'+$day+'_'+$time+'_'+$name+'_'+([string]$Record.Id).Substring(0,8)+'.pdf')
}
function Update-QaWebLibrary {
    param($Config,[object[]]$OnlyRecords=@())
    $dashboard=Get-QaDashboard $Config;$organization=Get-QaWebOrganization $Config;$folderNames=Get-QaWebFolderNames $Config;$library=Join-Path $Config.ArchiveRoot 'Report Library';$manifestPath=Join-Path $Config.ArchiveRoot '.ctqa/web-library.json';Assert-QaWebDirect $library;Assert-QaWebDirect $manifestPath
    $manifest=[pscustomobject]@{Version=1;Records=@()};if([IO.File]::Exists($manifestPath)){$manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json;if($manifest.Version -ne 1){throw 'The readable-library index is unsupported.'}}
    $rows=if($OnlyRecords.Count){@($dashboard.Records|Where-Object{$OnlyRecords -contains $_.Id})}else{@($dashboard.Records)};$copied=0
    foreach($record in $rows){
        $entry=Get-QaWebEntry $organization $record;$category=Get-QaWebCategory $record $entry;$source=@($Config.Sources|Where-Object Scanner -eq $record.Scanner)[0];$relative=Get-QaWebRelative $record $category $folderNames[[string]$record.Scanner];$target=Join-Path $library ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar));Assert-QaWebDirect $target
        if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $target.Length -gt 245){throw 'The readable-library path is too long. Choose a shorter local archive folder.'}
        $previous=@($manifest.Records|Where-Object id -ceq $record.Id)
        if($previous.Count -eq 1 -and $previous[0].category -eq $category -and (Test-QaWebRelative ([string]$previous[0].relative))){$relative=[string]$previous[0].relative;$target=Join-Path $library ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar));Assert-QaWebDirect $target}
        $owned=($previous.Count -eq 1 -and [string]$previous[0].relative -ceq $relative)
        if([IO.File]::Exists($target) -and -not $owned){$relative=$relative.Substring(0,$relative.Length-4)+'-copy-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.pdf';$target=Join-Path $library ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar));Assert-QaWebDirect $target}
        if([IO.File]::Exists($target)){
            if((Get-FileHash -LiteralPath $target).Hash -cne [string]$record.Hash){throw 'A readable PDF was changed or the target is occupied. It was preserved; use a new archive location or restore the readable copy.'}
        }else{
            $saved=Assert-QaWebPdf $Config $record;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));$temp=$target+'.'+[guid]::NewGuid().ToString('N')+'.partial'
            try{[IO.File]::Copy($saved,$temp,$false);if((Get-FileHash $temp).Hash -cne [string]$record.Hash){throw 'The readable-copy fingerprint did not match.'};[IO.File]::Move($temp,$target);$copied++}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
        }
        $new=[pscustomobject]@{id=[string]$record.Id;hash=[string]$record.Hash;relative=$relative;category=$category;original=[string]$record.OriginalFileName}
        $manifest.Records=@($manifest.Records|Where-Object id -cne $record.Id)+@($new);Write-QaWebAtomic $manifestPath $manifest
        foreach($old in $previous){
            if($old.relative -ceq $relative){continue};$oldRelative=[string]$old.relative
            if(-not (Test-QaWebRelative $oldRelative)){throw 'The previous readable-copy path is invalid.'}
            $oldPath=Join-Path $library ($oldRelative.Replace('/',[IO.Path]::DirectorySeparatorChar));Assert-QaWebDirect $oldPath
            if([IO.File]::Exists($oldPath) -and (Get-FileHash $oldPath).Hash -ceq [string]$old.hash){$history=Join-Path $Config.ArchiveRoot ('.ctqa/library-history/'+[guid]::NewGuid().ToString('N')+'.pdf');[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($history));[IO.File]::Move($oldPath,$history)}
        }
    }
    return [pscustomobject]@{libraryRoot=$library;copied=$copied;total=@($manifest.Records).Count}
}
function Invoke-QaWebOrganization {
    param($Config,$Request)
    $meta=Join-Path $Config.ArchiveRoot '.ctqa';Assert-QaWebDirect $meta;[void][IO.Directory]::CreateDirectory($meta);$lock=$null
    try{
        try{$lock=[IO.File]::Open((Join-Path $meta 'archive.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'An archive operation is already running. Wait for it to finish, then try again.'}
        $dashboard=Get-QaDashboard $Config;$record=Get-QaWebRecord $dashboard ([string](Get-QaWebValue $Request id ''));$organization=Get-QaWebOrganization $Config;$before=Get-QaWebEntry $organization $record
        if([string](Get-QaWebValue $Request stamp '') -cne (Get-QaWebStamp $record $before)){throw 'This report changed after it was displayed. Refresh before deciding.'}
        [void](Assert-QaWebPdf $Config $record);$action=[string]$Request.action;$category=Get-QaWebCategory $record $before;$decision=''
        if($action -eq 'Undo'){
            $history=@($organization.History|Where-Object recordId -ceq $record.Id|Select-Object -Last 1)
            if($history.Count -ne 1 -or [string](Get-QaWebValue $Request reviewId '') -cne [string]$history[0].reviewId -or [string](Get-QaWebValue $before revision '') -cne [string]$history[0].reviewId){throw 'Only the latest decision for this report can be undone.'}
            $restore=$history[0].before;$category=[string](Get-QaWebValue $restore category '');$decision=[string](Get-QaWebValue $restore decision '')
        }else{
            $pending=Test-QaReportPending $record;if([string](Get-QaWebValue $before decision '') -in @('Approved','Disapproved')){$pending=$false};if(-not $pending){throw 'This report is already organized. Refresh the pending list.'}
            if($action -eq 'Approve'){$decision='Approved'}elseif($action -eq 'Disapprove'){$decision='Disapproved';$category='Other'}else{throw 'Unsupported file decision.'}
        }
        $revision=[guid]::NewGuid().ToString('N');$actor=[Environment]::UserName
        $after=[pscustomobject]@{id=[string]$record.Id;hash=[string]$record.Hash;revision=$revision;decision=$decision;category=$category;time=[datetime]::UtcNow.ToString('o');actor=$actor;actorKind='Windows account identifier; not a verified personal QA reviewer'}
        $history=[pscustomobject]@{reviewId=$revision;recordId=[string]$record.Id;hash=[string]$record.Hash;action=$action;time=$after.time;actor=$actor;actorKind=$after.actorKind;before=$before;after=$after;scope='Document classification only; no clinical result or checklist verification'}
        $organization.Records=@($organization.Records|Where-Object id -cne $record.Id)+@($after);$organization.History=@($organization.History)+@($history)
        Write-QaWebAtomic (Join-Path $meta 'organization.json') $organization
        $warning='';try{[void](Update-QaWebLibrary $Config @([string]$record.Id))}catch{$warning='Decision saved. Readable folders need refresh: '+$_.Exception.Message}
        return [pscustomobject]@{recordId=[string]$record.Id;reviewId=$revision;stamp=(Get-QaWebStamp $record $after);warning=$warning;classificationOnly=$true}
    }finally{if($null -ne $lock){$lock.Dispose()}}
}
function New-QaWebArtifactPath($AppRoot,[string]$Folder,[string]$Prefix){$root=Join-Path $AppRoot $Folder;Assert-QaWebDirect $root;[void][IO.Directory]::CreateDirectory($root);return Join-Path $root ($Prefix+'-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.zip')}
function ConvertTo-QaWebCsv([string]$Value){if($Value -match '^[\x00-\x20]*[=+@\-\t\r]'){return ("'"+$Value)};return $Value}
function New-QaWebExport {
    param($Config,[string[]]$Ids)
    if(-not $Ids.Count){throw 'Select at least one report to export.'};if($Ids.Count -gt 20000){throw 'Export at most 20,000 reports at once.'}
    $dashboard=Get-QaDashboard $Config;$organization=Get-QaWebOrganization $Config;$folderNames=Get-QaWebFolderNames $Config;$seen=@{};$rows=@();foreach($id in $Ids){if($seen.ContainsKey($id)){continue};$seen[$id]=$true;$record=Get-QaWebRecord $dashboard $id;[void](Assert-QaWebPdf $Config $record);$rows+=@($record)}
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    $path=New-QaWebArtifactPath $Config.AppRoot 'Exports' 'CTQA-Reports';$temp=$path+'.partial';$zip=$null;$stream=$null;$summary=New-Object Text.StringBuilder;$manifest=New-Object 'Collections.Generic.List[object]';$usedPaths=@{}
    try{
        $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew);$zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        [void]$summary.Append('<!doctype html><html lang="en"><meta charset="utf-8"><title>CT QA reports</title><style>body{font:16px/1.5 Segoe UI,sans-serif;max-width:1000px;margin:35px auto}td,th{padding:12px;border-bottom:1px solid #ddd;text-align:left}a{color:#087568}</style><h1>CT QA report package</h1><p>Saved report documents. Approve/Disapprove labels organize files; they do not declare clinical PASS/FAIL or complete a Monthly checklist.</p><table><tr><th>Scanner</th><th>Date</th><th>Type</th><th>Open PDF</th></tr>')
        foreach($record in $rows){
            $entry=Get-QaWebEntry $organization $record;$category=Get-QaWebCategory $record $entry;$source=@($Config.Sources|Where-Object Scanner -eq $record.Scanner)[0];$organizationStatus=[string](Get-QaWebValue $entry decision '');if(-not $organizationStatus){$organizationStatus=if(Test-QaReportPending $record){'Pending suggestion'}else{'Previously organized'}};$typeLabel=$category+' document';if($organizationStatus -eq 'Pending suggestion'){$typeLabel+=' - pending classification'};$name=Get-QaWebRelative $record $category $folderNames[[string]$record.Scanner]
            $baseName=$name;$suffix=1;while($usedPaths.ContainsKey($name)){$suffix++;$name=$baseName.Substring(0,$baseName.Length-4)+'-Report-'+$suffix+'.pdf'};$usedPaths[$name]=$true
            $pdf=Assert-QaWebPdf $Config $record;[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$pdf,$name,[IO.Compression.CompressionLevel]::Optimal)
            $nameSafe=ConvertTo-QaWebCsv ([string]$record.OriginalFileName)
            [void]$manifest.Add([pscustomobject]@{Scanner=(ConvertTo-QaWebCsv $source.Name);ReportId=$record.Id;ReportDate=$record.ReportDate;ReportTime=$record.ReportTime;OriginalFilename=$nameSafe;DocumentType=$category;OrganizationDecision=$organizationStatus;OriginalArchiveCategory=[string]$record.Category;ExportPath=$name;SHA256=$record.Hash;ClinicalReviewer=(ConvertTo-QaWebCsv ([string](Get-QaWebValue $record ConfirmedBy '')));ClinicalReviewTime=[string](Get-QaWebValue $record ConfirmedAt '');VerifiedChecklistItems=(@(Get-QaWebValue $record ConfirmedComponents @()) -join '; ');PrintedResultStatus=[string](Get-QaWebValue (Get-QaSavedAnalysis $Config $record) Status 'Not analyzed');ClinicalQAResult='Not inferred from classification'})
            $link=($name.Split('/')|ForEach-Object{[Uri]::EscapeDataString($_)}) -join '/'
            [void]$summary.Append('<tr><td>'+[Net.WebUtility]::HtmlEncode($source.Name)+'</td><td>'+[Net.WebUtility]::HtmlEncode([string]$record.ReportDate)+'</td><td>'+[Net.WebUtility]::HtmlEncode($typeLabel)+'</td><td><a href="'+$link+'">'+[Net.WebUtility]::HtmlEncode([string]$record.OriginalFileName)+'</a></td></tr>')
        }
        [void]$summary.Append('</table><p>Every exported PDF was checked against its saved SHA-256 fingerprint.</p></html>')
        foreach($item in @(@{Name='Report Summary.html';Text=$summary.ToString()},@{Name='Report list.csv';Text=(@($manifest.ToArray())|ConvertTo-Csv -NoTypeInformation|Out-String)})){$e=$zip.CreateEntry($item.Name);$writer=New-Object IO.StreamWriter($e.Open(),(New-Object Text.UTF8Encoding $true));try{$writer.Write($item.Text)}finally{$writer.Dispose()}}
        $zip.Dispose();$zip=$null;$stream=$null
        # Read back every exported PDF to detect a source changing during compression.
        $verify=[IO.Compression.ZipFile]::OpenRead($temp);try{foreach($row in $manifest){$input=$verify.GetEntry($row.ExportPath).Open();$sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($input))).Replace('-','');if($hash -cne [string]$row.SHA256){throw 'An exported PDF changed during export. No completed package was produced.'}}finally{$sha.Dispose();$input.Dispose()}}}finally{$verify.Dispose()}
        [IO.File]::Move($temp,$path);return $path
    }finally{if($null -ne $zip){$zip.Dispose()};if($null -ne $stream){$stream.Dispose()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Invoke-QaWebRequest {
    [CmdletBinding()]param([string]$AppRoot,$Request)
    $AppRoot=[IO.Path]::GetFullPath($AppRoot);Assert-QaWebDirect $AppRoot;[void](Initialize-QaWorkspace $AppRoot);$config=Read-QaConfig $AppRoot;$action=[string](Get-QaWebValue $Request action '')
    $allowed=@('Snapshot','Refresh','Approve','Disapprove','Undo','Reconnect','Settings','ApplyProfile','Export','Analyze','Backup','Diagnostics','Pdf','Browse','PickArchive','PrepareUpdate','InstallPreparedUpdate','Audit','ScannerSettings','Restore','PreviewPdf')
    if($action -cnotin $allowed){throw 'This application action is not supported.'}
    $value=$null;$message='';$warning='';$path='';$decision=$null
    switch($action){
        'Snapshot'{return Get-QaWebSnapshot $config}
        'PreviewPdf'{return Get-QaPdfPreviewPage -Config $config -RecordId ([string](Get-QaWebValue $Request id '')) -PageNumber ([int](Get-QaWebValue $Request page 0))}
        'Pdf'{$record=Get-QaWebRecord (Get-QaDashboard $config) ([string](Get-QaWebValue $Request id ''));return [pscustomobject]@{path=(Assert-QaWebPdf $config $record);filename=[string]$record.OriginalFileName}}
        {$_ -in @('Approve','Disapprove','Undo')}{$decision=Invoke-QaWebOrganization $config $Request;$message=$(if($action -eq 'Undo'){'Previous file classification restored.'}else{$action+' saved. The PDF was kept.'});$warning=$decision.warning}
        'Refresh'{
            foreach($source in $config.Sources){if(Test-QaPlaceholderConnection $source){continue};$credential=$null;try{$credential=Get-QaSavedCredential -AppRoot $AppRoot -ScannerId $source.Scanner -ExpectedUsername $source.Username -ExpectedPath $source.Path}catch{};if($null -ne $credential){[void](Reconnect-QaScanner $source $credential)}}
            $dashboard=Get-QaDashboard $config
            if($dashboard.SetupComplete){$operation=Invoke-QaOperation $config -Mode Update}else{
                $preview=Invoke-QaOperation $config -Mode Preview
                $accessible=@($preview.Scanners|Where-Object{$_.Status -in @('Connected','Issues','Partial')})
                if(-not $accessible.Count){
                    Write-QaWebAtomic (Join-Path $config.ArchiveRoot '.ctqa/web-connections.json') ([pscustomobject]@{Version=1;Connections=@($preview.Scanners)})
                    return [pscustomobject]@{snapshot=(Get-QaWebSnapshot $config);message='No scanner reports folder is accessible yet. Open Settings and test the scanner connections.';warning='Setup has not been completed. Existing archive records were not changed.';decision=$null;result=$null;path=''}
                }
                $operation=Invoke-QaOperation $config -Mode Import -Plan $preview.Plan
            }
            Write-QaWebAtomic (Join-Path $config.ArchiveRoot '.ctqa/web-connections.json') ([pscustomobject]@{Version=1;Connections=@($operation.Scanners)})
            $message=$operation.Summary.Description;try{[void](Update-QaWebLibrary $config)}catch{$warning=$_.Exception.Message}
        }
        'Reconnect'{
            $id=[string](Get-QaWebValue $Request scanner '');$matches=@($config.Sources|Where-Object Scanner -ceq $id);if($matches.Count -ne 1){throw 'Choose a configured scanner.'};$source=$matches[0]
            $username=[string](Get-QaWebValue $Request username $source.Username);$newPath=[string](Get-QaWebValue $Request path $source.Path);if($newPath -ne $source.Path){$newPath=(Get-QaNetworkLocation $newPath).Path};$source.Username=$username;$source.Path=$newPath;[void](Save-QaConfig $AppRoot $config)
            $credential=$null;$password=[string](Get-QaWebValue $Request password '')
            if($password){$secure=ConvertTo-SecureString $password -AsPlainText -Force;$credential=New-Object Management.Automation.PSCredential($username,$secure);$password=''}else{try{$credential=Get-QaSavedCredential -AppRoot $AppRoot -ScannerId $id -ExpectedUsername $username -ExpectedPath $newPath}catch{}}
            $connection=Reconnect-QaScanner $source $credential;$rows=@(Get-QaWebConnectionRows $config|Where-Object Scanner -cne $id)+@($connection);Write-QaWebAtomic (Join-Path $config.ArchiveRoot '.ctqa/web-connections.json') ([pscustomobject]@{Version=1;Connections=$rows})
            if($connection.Status -eq 'Connected' -and $null -ne $credential -and (Get-QaWebValue $Request remember $false) -eq $true){Save-QaSavedCredential -AppRoot $AppRoot -ScannerId $id -Credential $credential -ExpectedPath $newPath|Out-Null}
            $number=1+[Array]::IndexOf([object[]]$config.Sources,$source);Write-QaSupportEvent -AppRoot $AppRoot -Operation Reconnect -Outcome $(if($connection.Status -eq 'Connected'){'Completed'}else{'Failed'}) -NativeCode ([int]$connection.NativeCode) -ScannerNumber $number -ErrorKind (Get-QaSupportErrorKind -Message $connection.Message -NativeCode ([int]$connection.NativeCode))
            $message=$connection.Message;$value=[pscustomobject]@{connection=$connection}
        }
        'Settings'{
            $root=[string](Get-QaWebValue $Request archiveRoot $config.ArchiveRoot);if(-not [IO.Path]::IsPathRooted($root)){throw 'Choose an absolute local archive folder.'};$config.ArchiveRoot=[IO.Path]::GetFullPath($root)
            if($null -ne (Get-QaWebValue $Request monitorMinutes)){$config|Add-Member MonitorMinutes ([int]$Request.monitorMinutes) -Force};if($null -ne (Get-QaWebValue $Request autoUpdateOnOpen)){if($Request.autoUpdateOnOpen -isnot [bool]){throw 'Update on opening must be on or off.'};$config|Add-Member AutoUpdateOnOpen $Request.autoUpdateOnOpen -Force};if($null -ne (Get-QaWebValue $Request autoAnalyze)){if($Request.autoAnalyze -isnot [bool]){throw 'Automatic reading must be on or off.'};$config|Add-Member AutoAnalyze $Request.autoAnalyze -Force}
            [void](Save-QaConfig $AppRoot $config);$message='Settings saved. Existing report folders were not moved or deleted.'
        }
        'ScannerSettings'{
            $id=[string](Get-QaWebValue $Request scanner '');$matches=@($config.Sources|Where-Object Scanner -ceq $id);if($matches.Count -ne 1){throw 'Choose an existing scanner before editing settings.'};$source=$matches[0]
            foreach($pair in @(@('name','Name'),@('path','Path'),@('drive','DriveLetter'),@('username','Username'),@('dailySchedule','DailySchedule'),@('activeFrom','ActiveFrom'),@('expectedMonthly','ExpectedMonthly'),@('monthlyDueDay','MonthlyDueDay'),@('checklist','MonthlyChecklist'),@('excludedDates','ExcludedDates'),@('checklistEffectiveMonth','ChecklistEffectiveMonth'))){
                $incoming=Get-QaWebValue $Request $pair[0];if($null -ne $incoming){if($pair[0] -eq 'expectedMonthly' -and $incoming -isnot [bool]){throw 'Monthly scheduling must be on or off.'};$source|Add-Member -NotePropertyName $pair[1] -NotePropertyValue $incoming -Force}
            }
            [void](Save-QaConfig $AppRoot $config);$message='Scanner settings saved. Existing archive records and prior checklist versions were preserved.'
        }
        'ApplyProfile'{
            $profile=Get-QaWebValue $Request profile;if($profile -is [string]){$profile=$profile|ConvertFrom-Json};if($null -eq $profile){throw 'Choose a scanner connection profile.'}
            foreach($item in @($profile)+@($profile.Connections)){foreach($property in $item.PSObject.Properties){if($property.Name -match '(?i)password|secret|credential'){throw 'Connection profiles cannot contain passwords. Use the secure scanner sign-in field.'}}}
            $temp=Join-Path $AppRoot ('Data/.profile-'+[guid]::NewGuid().ToString('N')+'.json');Assert-QaWebDirect $temp
            try{[IO.File]::WriteAllText($temp,($profile|ConvertTo-Json -Depth 15),(New-Object Text.UTF8Encoding $true));$applied=Set-QaConnectionProfile -AppRoot $AppRoot -ProfilePath $temp -ReplaceExisting;$message=$applied.Message}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}};$config=Read-QaConfig $AppRoot
        }
        'Export'{$path=New-QaWebExport $config ([string[]]@(Get-QaWebValue $Request ids @()));$message='Report package is ready to download.'}
        'Analyze'{$analysis=Invoke-QaAnalysis $config -Limit 20;$message=([string]$analysis.Analyzed+' PDFs analyzed; '+[string]$analysis.Cached+' cached; '+[string]$analysis.Failed+' need attention.');$value=$analysis}
        'Backup'{
            $path=New-QaWebArtifactPath $AppRoot 'Backups' 'CTQA-Full-Backup';$archivePrefix=[IO.Path]::GetFullPath($config.ArchiveRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar;$external=$false
            if($path.StartsWith($archivePrefix,[StringComparison]::OrdinalIgnoreCase)){
                if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Choose a backup destination outside the live archive using the Windows maintenance interface.'}
                Add-Type -AssemblyName System.Windows.Forms;$picker=New-Object Windows.Forms.SaveFileDialog;$picker.Filter='CT QA backup (*.zip)|*.zip';$picker.Title='Save a NEW backup outside your live archive';$picker.FileName=[IO.Path]::GetFileName($path)
                try{if($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return [pscustomobject]@{cancelled=$true;message='Backup cancelled. No existing files changed.'}};$path=$picker.FileName;$external=$true}finally{$picker.Dispose()}
            }
            $backup=New-QaBackup -AppRoot $AppRoot -Config $config -DestinationPath $path;$message='Verified backup is ready to download.'
            if($external){$message='Verified backup saved to: '+$path;$value=[pscustomobject]@{savedTo=$path};$path=''}
        }
        'Restore'{
            if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Interactive restore requires Windows. Use the native maintenance helper on the work computer.'}
            Add-Type -AssemblyName System.Windows.Forms;$picker=New-Object Windows.Forms.OpenFileDialog;$picker.Filter='CT QA backup (*.zip)|*.zip';$picker.Title='Choose the verified CT QA backup to restore'
            try{if($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return [pscustomobject]@{cancelled=$true;message='Restore cancelled. No files changed.'}};$backupPath=$picker.FileName}finally{$picker.Dispose()}
            $folder=New-Object Windows.Forms.FolderBrowserDialog;$folder.Description='Choose the PARENT folder. A new restored workspace will be created without replacing existing files.'
            try{if($folder.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return [pscustomobject]@{cancelled=$true;message='Restore cancelled. No files changed.'}};$destination=Join-Path $folder.SelectedPath ('CTQA-Restored-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))}finally{$folder.Dispose()}
            $restored=Restore-QaBackup -Path $backupPath -DestinationFolder $destination;$message=$restored.Summary.Description+' Restored folder: '+$destination;$value=[pscustomobject]@{restoredTo=$destination}
        }
        'Diagnostics'{$path=New-QaWebArtifactPath $AppRoot 'Logs/Support' 'CTQA-Support';[void](Export-QaSupportBundle -AppRoot $AppRoot -Config $config -Dashboard (Get-QaDashboard $config) -DestinationPath $path -ConnectionResults @(Get-QaWebConnectionRows $config));$message='Scrubbed support logs are ready. No report contents, usernames or passwords are included.'}
        'Audit'{$result=Invoke-QaOperation $config -Mode Audit;$message=$result.Summary.Description}
        'Browse'{[void](Update-QaWebLibrary $config);$folder=Join-Path $config.ArchiveRoot 'Report Library';if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){Start-Process -FilePath explorer.exe -ArgumentList ('"'+$folder+'"')|Out-Null};$message='Readable report folders opened.';$value=[pscustomobject]@{libraryRoot=$folder}}
        'PickArchive'{
            if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'The folder picker requires Windows. Enter a local path instead.'};Add-Type -AssemblyName System.Windows.Forms;$picker=New-Object Windows.Forms.FolderBrowserDialog;$picker.Description='Choose the existing local archive containing Reports and .ctqa. Choosing a folder does not move any files.'
            try{if($picker.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){return [pscustomobject]@{archiveRoot=$picker.SelectedPath;cancelled=$false}}else{return [pscustomobject]@{cancelled=$true}}}finally{$picker.Dispose()}
        }
        'PrepareUpdate'{
            $zip=[IO.Path]::GetFullPath([string](Get-QaWebValue $Request path (Get-QaWebValue $Request zipPath '')));$uploads=[IO.Path]::GetFullPath((Join-Path $AppRoot 'Data/.web-uploads')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if(-not $zip.StartsWith($uploads,[StringComparison]::OrdinalIgnoreCase)){throw 'Choose an update ZIP through the application upload control.'};Assert-QaWebDirect $zip
            $plan=New-QaUpdateStage -AppRoot $AppRoot -ZipPath $zip;$updateId=[guid]::NewGuid().ToString('N');$store=Join-Path $AppRoot 'Data/web-update-plan.json';Write-QaWebAtomic $store ([pscustomobject]@{Version=1;id=$updateId;stageRoot=$plan.StageRoot;sourceFolder=$plan.SourceFolder;versionName=$plan.Version})
            return [pscustomobject]@{version=$plan.Version;updateId=$updateId;files=$plan.Files;message='Update package checked. Install when ready; saved reports and settings stay in place.'}
        }
        'InstallPreparedUpdate'{
            $store=Join-Path $AppRoot 'Data/web-update-plan.json';Assert-QaWebDirect $store;if(-not [IO.File]::Exists($store)){throw 'Choose and check an update ZIP first.'};$saved=[IO.File]::ReadAllText($store)|ConvertFrom-Json
            if($saved.Version -ne 1 -or [string](Get-QaWebValue $Request updateId '') -cne [string]$saved.id){throw 'This checked update is no longer selected.'}
            $stage=[IO.Path]::GetFullPath([string]$saved.stageRoot);if(-not [IO.Path]::GetDirectoryName($stage).Equals($AppRoot.TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($stage) -notmatch '^\.pending-update-[a-f0-9]{32}$'){throw 'Invalid update staging location.'}
            $sourceFolder=Join-Path $stage 'Package';if(-not $sourceFolder.Equals([IO.Path]::GetFullPath([string]$saved.sourceFolder),[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid prepared update folder.'};$checked=Test-QaUpdateFolder $sourceFolder
            return [pscustomobject]@{installUpdate=[pscustomobject]@{sourceFolder=$sourceFolder;targetFolder=$AppRoot;stageRoot=$stage};version=$checked.Version;message='Closing the app so the checked update can install.'}
        }
    }
    $snapshot=Get-QaWebSnapshot $config
    return [pscustomobject]@{snapshot=$snapshot;message=$message;warning=$warning;decision=$decision;result=$value;path=$path}
}
Export-ModuleMember -Function Invoke-QaWebRequest,Get-QaWebSnapshot
