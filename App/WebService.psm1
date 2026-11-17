# Offline HTML application adapter. Organization decisions are not clinical review.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
foreach($name in @('Archive','Workspace','Review','Network','Credentials','Insights','Reports','Maintenance','Support','Updates','PdfPreview','ContentClassifier','Monthly','Trends')){Import-Module (Join-Path $PSScriptRoot ($name+'.psm1')) -DisableNameChecking -WarningAction SilentlyContinue}
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
function Test-QaWebHasProperty($Object,[string]$Name){
    if($null -eq $Object){return $false};if($Object -is [Collections.IDictionary]){return $Object.Contains($Name)};return ($null -ne $Object.PSObject.Properties[$Name])
}
function Assert-QaWebBatchHistory($History){
    $groups=@{}
    foreach($row in @($History)){
        $id=[string](Get-QaWebValue $row batchId '')
        if(-not $id){if((Test-QaWebHasProperty $row batchCount) -or (Test-QaWebHasProperty $row batchIndex) -or (Test-QaWebHasProperty $row undoOfBatchId)){throw 'The grouped file history has incomplete metadata. It was preserved.'};continue}
        $count=0;$index=0
        if($id -cnotmatch '^[a-fA-F0-9]{32}$' -or -not [int]::TryParse([string](Get-QaWebValue $row batchCount ''),[ref]$count) -or $count -lt 1 -or $count -gt 50 -or -not [int]::TryParse([string](Get-QaWebValue $row batchIndex ''),[ref]$index) -or $index -lt 0 -or $index -ge $count){throw 'The grouped file history has unsupported metadata. It was preserved.'}
        if([string]$row.hash -cne [string]$row.after.hash -or [string]$row.recordId -cne [string]$row.after.id -or [string]$row.reviewId -cne [string]$row.after.revision){throw 'The grouped file history has conflicting saved states. It was preserved.'}
        if($null -ne $row.before -and ([string]$row.before.id -cne [string]$row.recordId -or [string]$row.before.hash -cne [string]$row.hash)){throw 'The grouped file history has a prior state belonging to another report. It was preserved.'}
        if(-not $groups.ContainsKey($id)){$groups[$id]=New-Object 'Collections.Generic.List[object]'};[void]$groups[$id].Add($row)
    }
    foreach($id in @($groups.Keys)){
        $rows=@($groups[$id].ToArray());$count=[int]$rows[0].batchCount;$action=[string]$rows[0].action;$indices=@{};$records=@{};$undo=[string](Get-QaWebValue $rows[0] undoOfBatchId '')
        foreach($row in $rows){if([int]$row.batchCount -ne $count -or [string]$row.action -cne $action -or $indices.ContainsKey([int]$row.batchIndex) -or $records.ContainsKey([string]$row.recordId) -or [string](Get-QaWebValue $row undoOfBatchId '') -cne $undo){throw 'The grouped file history has conflicting members. It was preserved.'};$indices[[int]$row.batchIndex]=$true;$records[[string]$row.recordId]=$true}
        if($rows.Count -ne $count){throw 'The grouped file history is incomplete. It was preserved.'}
        if($action -ceq 'Undo'){
            if($undo -cnotmatch '^[a-fA-F0-9]{32}$' -or -not $groups.ContainsKey($undo)){throw 'The grouped Undo history has no matching original decision. It was preserved.'}
            $original=@($groups[$undo].ToArray());if($original.Count -ne $count -or [string]$original[0].action -ceq 'Undo'){throw 'The grouped Undo history conflicts with its original decision. It was preserved.'}
            foreach($row in $original){if(-not $records.ContainsKey([string]$row.recordId)){throw 'The grouped Undo history has different members. It was preserved.'}}
        }elseif($undo){throw 'The grouped file history has an invalid Undo reference. It was preserved.'}
    }
}
function Get-QaWebLatestBatch($Organization){
    $undone=@{};foreach($row in @($Organization.History)){if([string]$row.action -ceq 'Undo' -and [string](Get-QaWebValue $row undoOfBatchId '')){$undone[[string]$row.undoOfBatchId]=$true}}
    $history=@($Organization.History)
    for($i=$history.Count-1;$i -ge 0;$i--){$row=$history[$i];$id=[string](Get-QaWebValue $row batchId '');if($id -and [string]$row.action -cne 'Undo' -and -not $undone.ContainsKey($id)){return @($history|Where-Object{[string](Get-QaWebValue $_ batchId '') -ceq $id}|Sort-Object batchIndex)}}
    return @()
}
function Get-QaWebBatchStamp([string]$BatchId,[string]$Action,$Rows){
    $members=@($Rows|Sort-Object id|ForEach-Object{[string]$_.id+'|'+[string]$_.stamp})
    return Get-QaWebHash (($BatchId,$Action,[string]$members.Count,($members -join ';')) -join '|')
}
function Get-QaWebUndoBatch($Config,$Dashboard,$Organization,[object[]]$Rows=@()){
    $batch=@(Get-QaWebLatestBatch $Organization);if(-not $batch.Count){return $null}
    try{
        $entries=Get-QaWebEntryIndex $Organization;$rowIndex=@{};foreach($row in $Rows){$rowIndex[[string]$row.id]=$row};$stamps=New-Object 'Collections.Generic.List[object]'
        foreach($history in $batch){
            $record=Get-QaWebRecord $Dashboard ([string]$history.recordId);$entry=Get-QaWebIndexedEntry $entries $record;$after=$history.after
            if($null -eq $entry -or [string]$record.Hash -cne [string]$history.hash -or [string]$entry.revision -cne [string]$after.revision -or [string]$entry.hash -cne [string]$after.hash -or [string]$entry.decision -cne [string]$after.decision -or [string]$entry.category -cne [string]$after.category){return $null}
            $latest=@($Organization.History|Where-Object recordId -ceq $record.Id|Select-Object -Last 1);if($latest.Count -ne 1 -or [string]$latest[0].reviewId -cne [string]$history.reviewId){return $null}
            $stamp=if($rowIndex.ContainsKey([string]$record.Id)){[string]$rowIndex[[string]$record.Id].stamp}else{Get-QaWebStamp $record $entry (Get-QaWebContentContext $Config $record)}
            [void]$stamps.Add([pscustomobject]@{id=[string]$record.Id;stamp=$stamp})
        }
        $id=[string]$batch[0].batchId;$action=[string]$batch[0].action
        return [pscustomobject]@{batchId=$id;batchStamp=(Get-QaWebBatchStamp $id $action @($stamps.ToArray()));count=$batch.Count;action=$action}
    }catch{return $null}
}
function Get-QaWebApprovalCategory($Classification,$Content){
    if([string](Get-QaWebValue $Classification filingState '') -cne 'NeedsReview'){return ''}
    $category=[string](Get-QaWebValue $Classification category '')
    if($category -cin @('Daily','Monthly')){return $category}
    if($category -ceq 'Other' -and ([string](Get-QaWebValue $Content explicitCategory '') -ceq 'Other' -or [string](Get-QaWebValue $Content suggestedCategory '') -ceq 'Other')){return 'Other'}
    return ''
}
function Get-QaWebReviewGroup($Classification,$Content,[int]$ScannerNumber=0){
    if([string](Get-QaWebValue $Classification filingState '') -cne 'NeedsReview'){return [pscustomobject]@{key='';reason=''}}
    $basis=[string](Get-QaWebValue $Classification filingBasis '');$reason=if([bool](Get-QaWebValue $Content hasReferenceEvidence $false)){'ReferenceEvidence'}elseif($basis -cin @('ManualReview','ReadError','Conflict','Unsupported','Undo')){$basis}else{'Other'}
    $profile=switch([string](Get-QaWebValue (Get-QaWebValue $Content view $null) profileId '')){'siemens-iec-basic-v1'{'Basic'}'siemens-iec-extended-v1'{'Extended'}'siemens-iec-additional-v1'{'Additional'}'siemens-quality-daily-v1'{'Daily'}'siemens-iec-reference-v1'{'Reference'}default{'Unknown'}}
    $category=[string](Get-QaWebValue $Classification category 'Other');if($category -cnotin @('Daily','Monthly','Other')){$category='Other'}
    return [pscustomobject]@{key=(Get-QaWebHash (([string]$ScannerNumber,$profile,$reason,$category) -join '|'));reason=$reason}
}
function Invoke-QaWebBatchOrganization {
    param($Config,$Request,$Progress=$null,[ref]$OperationContext)
    if($null -ne $OperationContext){$OperationContext.Value=$null}
    $heldPdfs=New-Object 'Collections.Generic.List[object]';$clock=[Diagnostics.Stopwatch]::StartNew();$committed=$false;$selectedCount=0;$lock=$null;$action=[string](Get-QaWebValue $Request action '');$meta=Join-Path $Config.ArchiveRoot '.ctqa';Assert-QaWebDirect $meta;[void][IO.Directory]::CreateDirectory($meta)
    try{
        $undo=($action -ceq 'Undo');$hasSelections=Test-QaWebHasProperty $Request selections;$hasBatch=Test-QaWebHasProperty $Request batchId;$hasCategory=Test-QaWebHasProperty $Request category
        if((Test-QaWebHasProperty $Request id) -or (Test-QaWebHasProperty $Request stamp) -or (Test-QaWebHasProperty $Request ids) -or (Test-QaWebHasProperty $Request reviewId)){throw 'Choose either one report or a selected group, without mixing request formats.'}
        if($undo){if($hasSelections -or $hasCategory -or -not $hasBatch -or [string]$Request.batchId -cnotmatch '^[a-fA-F0-9]{32}$' -or [string](Get-QaWebValue $Request batchStamp '') -cnotmatch '^[a-fA-F0-9]{64}$'){throw 'Choose the current grouped Undo action.'}}
        elseif($action -cnotin @('Approve','Disapprove') -or -not $hasSelections -or $hasBatch -or (Test-QaWebHasProperty $Request batchStamp)){throw 'Choose a supported selected-file decision.'}
        $override='';if($hasCategory){$override=[string]$Request.category;if($action -cne 'Approve' -or $override -cnotin @('Daily','Monthly','Other')){throw 'Choose Daily, Monthly or Other only when approving selected files.'}}
        $selections=@()
        if(-not $undo){$raw=$null;if($Request -is [Collections.IDictionary]){$raw=$Request['selections']}else{$raw=$Request.selections};if($raw -is [array]){$selectedCount=[math]::Min(100000,$raw.Count)};if($raw -isnot [array] -or $raw.Count -lt 1 -or $raw.Count -gt 50){throw 'Select between 1 and 50 reports for one grouped decision.'};$selectedCount=$raw.Count;$seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach($selection in $raw){$id=[string](Get-QaWebValue $selection id '');$stamp=[string](Get-QaWebValue $selection stamp '');if($id -cnotmatch '^[a-fA-F0-9]{64}$' -or $stamp -cnotmatch '^[a-fA-F0-9]{64}$' -or -not $seen.Add($id)){throw 'Every selected report needs a unique valid identity and its displayed state.'};$selections+=@([pscustomobject]@{id=$id;stamp=$stamp})}}
        try{$lock=[IO.File]::Open((Join-Path $meta 'archive.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'An archive operation is already running. Wait for it to finish, then try again.'}
        $dashboard=Get-QaDashboard $Config;$organization=Get-QaWebOrganization $Config;$entryIndex=Get-QaWebEntryIndex $organization;$plans=New-Object 'Collections.Generic.List[object]';$undoOf=''
        if($undo){
            $summary=Get-QaWebUndoBatch $Config $dashboard $organization
            if($null -eq $summary -or [string]$summary.batchId -cne [string]$Request.batchId -or [string]$summary.batchStamp -cne [string]$Request.batchStamp){throw 'The grouped decisions changed after they were displayed. Refresh before undoing them.'}
            $undoOf=[string]$summary.batchId;$batch=@(Get-QaWebLatestBatch $organization);$selectedCount=$batch.Count
            foreach($history in $batch){$record=Get-QaWebRecord $dashboard ([string]$history.recordId);$held=$null;[void](Assert-QaWebPdf -Config $Config -Record $record -ReadHandle ([ref]$held));[void]$heldPdfs.Add($held);$before=Get-QaWebIndexedEntry $entryIndex $record;$restore=$history.before;[void]$plans.Add([pscustomobject]@{Record=$record;Before=$before;Category=[string](Get-QaWebValue $restore category '');Decision=[string](Get-QaWebValue $restore decision '')})}
        }else{
            foreach($selection in $selections){$record=Get-QaWebRecord $dashboard $selection.id;$before=Get-QaWebIndexedEntry $entryIndex $record;$content=Get-QaWebContentContext $Config $record
                if($selection.stamp -cne (Get-QaWebStamp $record $before $content)){throw 'A selected report changed after it was displayed. No grouped decisions were saved.'}
                $classification=Get-QaWebClassification $record $before $content;if([string]$classification.filingState -cne 'NeedsReview' -or -not $classification.pending){throw 'Every selected report must be a processed review exception. Waiting or already filed reports cannot be included.'}
                $held=$null;[void](Assert-QaWebPdf -Config $Config -Record $record -ReadHandle ([ref]$held));[void]$heldPdfs.Add($held);$category=if($action -ceq 'Disapprove'){'Other'}elseif($override){$override}else{Get-QaWebApprovalCategory $classification $content};if($category -cnotin @('Daily','Monthly','Other')){throw 'A selected report has no proposed file type. Choose Daily, Monthly or Other explicitly.'}
                [void]$plans.Add([pscustomobject]@{Record=$record;Before=$before;Category=$category;Decision=$(if($action -ceq 'Approve'){'Approved'}else{'Disapproved'})})
            }
        }
        foreach($held in $heldPdfs){$info=New-Object IO.FileInfo($held.Path);if(-not $info.Exists -or $info.Length -ne $held.Length -or $info.LastWriteTimeUtc.Ticks -ne $held.WriteTicks){throw 'A selected PDF changed during grouped preflight. No decisions were saved.'}}
        if(Test-QaWebCancelled $Progress){if($null -ne $OperationContext){$OperationContext.Value=[pscustomobject]@{Dashboard=$dashboard;Organization=$organization}};return [pscustomobject]@{cancelled=$true;warning='';count=0;classificationOnly=$true}}
        # All candidates have passed before any decision is changed. The history
        # remains individual and append-only, with bounded group metadata.
        $batchId=[guid]::NewGuid().ToString('N');$actor=[Environment]::UserName;$now=[datetime]::UtcNow.ToString('o');$afterRows=New-Object 'Collections.Generic.List[object]';$historyRows=New-Object 'Collections.Generic.List[object]';$ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);$index=0
        foreach($plan in $plans){$record=$plan.Record;$revision=[guid]::NewGuid().ToString('N');[void]$ids.Add([string]$record.Id)
            $after=[pscustomobject]@{id=[string]$record.Id;hash=[string]$record.Hash;revision=$revision;decision=$plan.Decision;category=$plan.Category;time=$now;actor=$actor;actorKind='Windows account identifier; not a verified personal QA reviewer'}
            $history=[pscustomobject]@{reviewId=$revision;recordId=[string]$record.Id;hash=[string]$record.Hash;action=$action;time=$now;actor=$actor;actorKind=$after.actorKind;before=$plan.Before;after=$after;scope='Document classification only; no clinical result or checklist verification';batchId=$batchId;batchCount=$plans.Count;batchIndex=$index}
            if($undo){$history|Add-Member undoOfBatchId $undoOf};[void]$afterRows.Add($after);[void]$historyRows.Add($history);$index++
        }
        $organization.Records=@($organization.Records|Where-Object{-not $ids.Contains([string]$_.id)})+@($afterRows.ToArray());$organization.History=@($organization.History)+@($historyRows.ToArray())
        Write-QaWebAtomic (Join-Path $meta 'organization.json') $organization;$committed=$true
        if($null -ne $OperationContext){$OperationContext.Value=[pscustomobject]@{Dashboard=$dashboard;Organization=$organization}}
        $counts=@{Selected=$selectedCount};if($undo){$counts.Undone=$selectedCount}else{$counts[$(if($action -ceq 'Approve'){'Approved'}else{'Disapproved'})]=$selectedCount}
        Write-QaSupportEvent -AppRoot $Config.AppRoot -Operation Reclassify -Outcome Completed -DurationMs $clock.ElapsedMilliseconds -Stage Finishing -Reason $(if($undo){'BatchUndoSaved'}else{'BatchDecisionSaved'}) -Counts $counts
        $warning='';try{[void](Update-QaWebLibrary -Config $Config -OnlyRecords @($plans|ForEach-Object{[string]$_.Record.Id}) -Dashboard $dashboard -Organization $organization -Progress $Progress)}catch{$warning='Decisions saved. Readable folders need refresh: '+$_.Exception.Message;Write-QaSupportEvent -AppRoot $Config.AppRoot -Operation Reclassify -Outcome Failed -DurationMs $clock.ElapsedMilliseconds -Stage Library -Reason ReadableCopyRefreshFailed -Counts @{Selected=$selectedCount;CopyFailed=1}}
        $result=[pscustomobject]@{batchId=$batchId;count=$selectedCount;action=$action;classificationOnly=$true;warning=$warning};if($undo){$result|Add-Member undoOfBatchId $undoOf};return $result
    }catch{if(-not $committed){Write-QaSupportEvent -AppRoot $Config.AppRoot -Operation Reclassify -Outcome Failed -DurationMs $clock.ElapsedMilliseconds -Reason BatchPreflightRejected -Counts @{Selected=$selectedCount;Rejected=$selectedCount}};throw}
    finally{foreach($held in $heldPdfs){if($null -ne $held.Stream){$held.Stream.Dispose()}};if($null -ne $lock){$lock.Dispose()}}
}

function Get-QaWebOrganization($Config){
    $path=Join-Path $Config.ArchiveRoot '.ctqa/organization.json';Assert-QaWebDirect $path
    if(-not [IO.File]::Exists($path)){return [pscustomobject]@{Version=1;Records=@();History=@()}}
    try{$state=[IO.File]::ReadAllText($path)|ConvertFrom-Json}catch{throw 'The file-organization history could not be read. It was preserved; restore its verified backup before making further decisions.'}
    if($state.Version -ne 1 -or $null -eq $state.PSObject.Properties['Records'] -or $null -eq $state.PSObject.Properties['History']){throw 'Unsupported file-organization history. No data was changed.'}
    $seen=@{};foreach($entry in @($state.Records)){Assert-QaWebOrganizationEntry $entry;if($seen.ContainsKey([string]$entry.id)){throw 'The file-organization history contains duplicate report entries.'};$seen[[string]$entry.id]=$true}
    foreach($history in @($state.History)){if([string]$history.reviewId -notmatch '^[a-fA-F0-9]{32}$' -or [string]$history.recordId -notmatch '^[a-fA-F0-9]{64}$' -or [string]$history.action -cnotin @('Approve','Disapprove','Undo')){throw 'The file-organization action history contains unsupported values.'};Assert-QaWebOrganizationEntry $history.before;Assert-QaWebOrganizationEntry $history.after}
    Assert-QaWebBatchHistory @($state.History)
    return $state
}
function Get-QaWebEntry($Organization,$Record){$entries=@($Organization.Records|Where-Object{[string]$_.id -ceq [string]$Record.Id -and [string]$_.hash -ceq [string]$Record.Hash});if($entries.Count -gt 1){throw 'A report has conflicting organization records.'};if($entries.Count){return $entries[0]};return $null}
function Get-QaWebStamp($Record,$Entry,$ContentContext=$null){$value=(Get-QaRecordReviewStamp $Record)+'|'+[string](Get-QaWebValue $Entry revision '')+'|'+[string](Get-QaWebValue $Entry decision '')+'|'+[string](Get-QaWebValue $Entry category '');$tag=[string](Get-QaWebValue $ContentContext stamp '');if($tag){$value+='|'+$tag};return Get-QaWebHash $value}
function Get-QaWebCategory($Record,$Entry){
    if([string](Get-QaWebValue $Entry decision '') -in @('Approved','Disapproved')){return [string]$Entry.category}
    switch([string]$Record.Category){'Daily_QA'{return 'Daily'}'Monthly_QA'{return 'Monthly'}'Monthly_QA/Pending_Verification'{return 'Monthly'}default{return 'Other'}}
}
function ConvertTo-QaWebContentProfiles($Values){
    $rows=New-Object 'Collections.Generic.List[object]';$seen=@{}
    foreach($item in @($Values)){
        if($null -eq $item){continue}
        $id=[string](Get-QaWebValue $item profileId '');$category=[string](Get-QaWebValue $item category '')
        if($id -cnotin @('siemens-iec-basic-v1','siemens-iec-extended-v1','siemens-iec-additional-v1') -or $seen.ContainsKey($id) -or $category -cnotin @('','Auto','Ask','Daily','Monthly','Other')){throw 'Choose one supported report-format rule for each layout.'}
        if(-not $category){$category='Auto'};$seen[$id]=$true;[void]$rows.Add([pscustomobject]@{profileId=$id;category=$category})
    }
    if($rows.Count -gt 3){throw 'Only the three supported report-format rules can be saved.'}
    return @($rows.ToArray())
}
function Get-QaWebAlignmentContext($Analysis,$Measurement,$Document,$Row,$Record,[string]$Metric){
    # Share the graph's strict eligibility rules. A legacy or malformed cache
    # must not acquire a fabricated Overall/System/Slice context in the inspector.
    return &(Get-Module Trends) {
        param($Saved,$Measured,$Doc,$Item,$ArchiveRecord,$Code)
        try{
            if((Test-QaTrendReference $Saved) -or [string](Get-QaTrendValue $Saved Status '') -ceq 'ReadError' -or -not (Test-QaTrendTrue (Get-QaTrendValue $Doc CompleteRead $false)) -or -not (Test-QaTrendTrue (Get-QaTrendValue $Measured CompleteRead $false)) -or [string](Get-QaTrendValue $Measured Status '') -cnotin @('Extracted','NeedsReview') -or -not (Test-QaTrendMetricDocument $Measured $Doc $Code)){return $null}
            $printed=Get-QaTrendDate ([string](Get-QaTrendValue $Doc ReportDate ''));$raw=Get-QaTrendDate ([string](Get-QaTrendValue $ArchiveRecord ReportDate ''));$time=[string](Get-QaTrendValue $Doc ReportTime '');$stamp=[datetime]::MinValue
            if($null -eq $printed -or [string](Get-QaTrendValue $Doc DateStatus '') -cne 'Consensus' -or -not [datetime]::TryParseExact(([string](Get-QaTrendValue $Doc ReportDate '')+' '+$time),'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$stamp) -or $printed -gt (Get-Date).Date.AddDays(1) -or ($null -ne $raw -and $raw -ne $printed) -or ([string](Get-QaTrendValue $ArchiveRecord ReportTime '') -and [string](Get-QaTrendValue $ArchiveRecord ReportTime '') -cne $time)){return $null}
            if([string](Get-QaTrendValue $Item Unit '') -cne 'mm' -or [string](Get-QaTrendValue $Item Status '') -cnotin @('Printed','NeedsReview') -or [int](Get-QaTrendValue $Item Page 0) -lt 1 -or [int](Get-QaTrendValue $Item Page 0) -gt [int](Get-QaTrendValue $Doc ReadPages 0) -or $null -eq (Get-QaTrendNumber (Get-QaTrendValue $Item Value))){return $null}
            return Get-QaTrendRowContext $Item $Code
        }catch{return $null}
    } $Analysis $Measurement $Document $Row $Record $Metric
}

function Get-QaWebContentContext($Config,$Record,$TrendCacheMetadata=$null,[ref]$AnalysisStatus){
    $date=[string]$Record.ReportDate;$time=[string]$Record.ReportTime
    $view=[pscustomobject]@{status='NotRead';profileId='';profileName='';date='';time='';dateStatus='Missing';reason='Read this PDF to look for a supported report format.';mappedCategory='';suggestedCategory='';components=@();readPages=0;pages=0;completeRead=$false;reader=[pscustomobject]@{name='';version='';elapsedMs=0;fallback=$false};measurements=@();measurementStatus='NotRead';ruleMode='Auto';isReference=$false;hasReferenceEvidence=$false;compatibilityRefreshPending=$false}
    $context=[pscustomobject]@{view=$view;profileUsable=$false;dateConflict=$false;typeConflict=$false;dateSafe=$false;effectiveDate=$date;effectiveTime=$time;mappedCategory='';explicitCategory='';suggestedCategory='';stamp='';ruleMode='Auto';isReference=$false;hasReferenceEvidence=$false;compatibilityRefreshPending=$false;cacheStatus='Missing';document=$null;trendStamp=''}
    $analysis=$null
    try{
    $analysis=Get-QaSavedAnalysis -Config $Config -Record $Record
    if($null -ne $AnalysisStatus){$AnalysisStatus.Value=Get-QaAnalysisReadStatus -Saved $analysis -UpgradeMeasurements -RefreshUnsupported}
    if($null -eq $analysis){
        # A stale version/provenance row is waiting for a current read. A corrupt
        # cache is an exception, rather than a claim that no read was attempted.
        $hash=[string](Get-QaWebValue $Record Hash '')
        if($hash -cmatch '^[0-9A-Fa-f]{64}$'){
            $cachePath=Join-Path $Config.ArchiveRoot ('.ctqa/analysis/'+$hash+'.json')
            if([IO.File]::Exists($cachePath)){
                try{Assert-QaWebDirect $cachePath;[void]([IO.File]::ReadAllText($cachePath)|ConvertFrom-Json);$context.cacheStatus='Stale'}
                catch{$context.cacheStatus='Unreadable';$view.status='ReadError';$view.reason='The saved analysis cache could not be read. Retry reading the original verified PDF.'}
            }
        }
        return $context
    }
    $context.cacheStatus='Valid'
    $doc=Get-QaWebValue $analysis DocumentClassification;$context.document=$doc
    if(-not [string](Get-QaWebValue $doc ProfileId '') -and [string](Get-QaWebValue $doc ReasonCode '') -cin @('UnknownTemplate','UnrecognizedSections')){
        $context.compatibilityRefreshPending=[bool](&(Get-Module Insights){param($saved) (Get-QaAnalysisEligibility -Saved $saved -RefreshUnsupported) -ceq 'UnsupportedUpgrade'} $analysis)
        $view.compatibilityRefreshPending=$context.compatibilityRefreshPending
    }
    $context.isReference=([bool](Get-QaWebValue $doc IsReference $false) -or [string](Get-QaWebValue $doc ProfileId '') -ceq 'siemens-iec-reference-v1');$view.isReference=$context.isReference
    $context.hasReferenceEvidence=($context.isReference -or [bool](Get-QaWebValue $doc HasReferenceEvidence $false));$view.hasReferenceEvidence=$context.hasReferenceEvidence
    $reader=[string](Get-QaWebValue $analysis ReaderUsed 'Legacy');if($reader -cnotin @('Python','Standard')){$reader='Legacy'}
    $readerVersion=[string](Get-QaWebValue $analysis ReaderVersion '');if($readerVersion.Length -gt 64 -or $readerVersion -notmatch '^[A-Za-z0-9 ._+/;-]*$'){$readerVersion=''}
    $readerMs=[long]0;[void][long]::TryParse([string](Get-QaWebValue $analysis ReaderElapsedMs 0),[ref]$readerMs);if($readerMs -lt 0 -or $readerMs -gt 3600000){$readerMs=0}
    $view.reader=[pscustomobject]@{name=$reader;version=$readerVersion;elapsedMs=$readerMs;fallback=([string](Get-QaWebValue $analysis ReaderFallbackReason '') -cin @('PythonUnavailable','PythonReadError','PythonNoText','StandardReadError','StandardNoText'))}
    $measured=Get-QaWebValue $analysis MeasurementsDocument $null
    if(-not $context.hasReferenceEvidence -and [int](Get-QaWebValue $measured MeasurementVersion 0) -eq 1){
        $view.measurementStatus=if([string](Get-QaWebValue $measured Status '') -ceq 'Extracted'){'Read'}else{'NeedsReview'}
        $measurementRows=New-Object 'Collections.Generic.List[object]'
        foreach($item in @(Get-QaWebValue $measured Measurements @()|Select-Object -First 100)){
            $code=[string](Get-QaWebValue $item Code '');if($code -cnotin @('WaterCTNumber','ImageNoise','SliceThickness','Lightmarker','ExternalLightmarker','TopogramPosition','SagittalCoronalLightmarker','TablePosition')){continue}
            $value=[string](Get-QaWebValue $item Value '');$unit=[string](Get-QaWebValue $item Unit '');$page=[int](Get-QaWebValue $item Page 0)
            $numeric='^[+-]?(?:[0-9]{1,9}(?:\.[0-9]{1,9})?|\.[0-9]{1,9})$'
            if($value -notmatch $numeric -or $unit -cne $(if($code -cin @('WaterCTNumber','ImageNoise')){'HU'}else{'mm'}) -or $page -lt 1 -or $page -gt 1000){continue}
            $lower=[string](Get-QaWebValue $item LowerLimit '');$upper=[string](Get-QaWebValue $item UpperLimit '')
            if(($lower -and $lower -notmatch $numeric) -or ($upper -and $upper -notmatch $numeric)){$lower='';$upper=''}
            $parts=New-Object 'Collections.Generic.List[string]'
            $mode=[string](Get-QaWebValue $item Mode '');if($mode -cin @('Head','Body')){[void]$parts.Add($mode)}
            $system=[string](Get-QaWebValue $item SourceSystem '');if($system -cin @('A','B')){[void]$parts.Add(('System '+$system))}
            $slice=[string](Get-QaWebValue $item Slice '');if($slice -cmatch '^[1-9][0-9]{0,2}$'){[void]$parts.Add(('Slice '+$slice))}
            if($code -cin @('Lightmarker','ExternalLightmarker','TopogramPosition','SagittalCoronalLightmarker','TablePosition')){$alignment=Get-QaWebAlignmentContext $analysis $measured $doc $item $Record $code;if($null -eq $alignment){continue};$parts.Clear();[void]$parts.Add([string]$alignment.context)}
            $metricLabel=switch($code){'WaterCTNumber'{'Water CT value'}'ImageNoise'{'Image noise'}'SliceThickness'{'Slice thickness'}'Lightmarker'{'Light marker alignment'}'ExternalLightmarker'{'External light marker'}'TopogramPosition'{'Topogram position'}'SagittalCoronalLightmarker'{'Sagittal / coronal alignment'}'TablePosition'{'Table position'}}
            [void]$measurementRows.Add([pscustomobject]@{label=$metricLabel;value=$value;unit=$unit;page=$page;lower=$lower;upper=$upper;context=($parts -join ' / ')})
        }
        $view.measurements=@($measurementRows.ToArray())
    }
    if($context.hasReferenceEvidence){$view.measurementStatus='ReferenceExcluded'}
    if([string](Get-QaWebValue $analysis Status '') -eq 'ReadError'){$context.cacheStatus='ReadError';$view.status='ReadError';$view.reason='This PDF could not be read. Open the original PDF or retry reading it.';return $context}
    if($null -eq $doc -or [int](Get-QaWebValue $doc ClassifierVersion 0) -ne 1){return $context}
    $profile=[string](Get-QaWebValue $doc ProfileId '');$status=[string](Get-QaWebValue $doc Status 'NeedsReview')
    $view.status=if([bool](Get-QaWebValue $doc NeedsOCR $false)){'NeedsOCR'}elseif($status -ceq 'Recognized'){'Recognized'}else{'NeedsReview'}
    $view.profileId=$profile;$view.profileName=[string](Get-QaWebValue $doc ProfileName '');$view.reason=[string](Get-QaWebValue $doc Reason 'The report format needs review.')
    $view.dateStatus=[string](Get-QaWebValue $doc DateStatus 'Missing');$view.readPages=[int](Get-QaWebValue $doc ReadPages 0);$view.pages=[int](Get-QaWebValue $doc Pages 0);$view.completeRead=[bool](Get-QaWebValue $doc CompleteRead $false)
    $view.suggestedCategory=[string](Get-QaWebValue $doc SuggestedCategory '');if($view.suggestedCategory -cnotin @('Daily','Monthly','Other')){$view.suggestedCategory=''}
    $names=@{};foreach($definition in @(Get-QaContentSectionDefinitions)){$names[[string]$definition.Code]=[string]$definition.Name}
    $components=New-Object 'Collections.Generic.List[object]'
    foreach($section in @(Get-QaWebValue $doc Sections @())){
        $code=[string](Get-QaWebValue $section Code '');if(-not $names.ContainsKey($code)){continue}
        $printed=@(Get-QaWebValue $section PrintedOutcomes @()|ForEach-Object{([regex]::Replace([string]$_,'\s+',' ')).Trim().ToUpperInvariant()}|Where-Object{[string]$_ -cmatch '^(OK|NOT OK|NOT EVALUATED|PASS|PASSED|FAIL|FAILED|ERROR|WARNING|UNKNOWN)$'}|Select-Object -Unique)
        [void]$components.Add([pscustomobject]@{name=$names[$code];result=$(if($printed.Count){$printed -join ' / '}else{'No printed result recognized'});page=[int](Get-QaWebValue $section Page 0)})
    };$view.components=@($components.ToArray())
    $printedDate=[string](Get-QaWebValue $doc ReportDate '');$printedTime=[string](Get-QaWebValue $doc ReportTime '');$parsed=[datetime]::MinValue
    $validDate=($view.dateStatus -ceq 'Consensus' -and [datetime]::TryParseExact(($printedDate+' '+$printedTime),'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed) -and $parsed -le (Get-Date).AddDays(1))
    if($validDate){
        $view.date=$printedDate;$view.time=$printedTime
        $context.dateConflict=(($date -and $date -cne $printedDate) -or ($time -and $time -cne $printedTime))
        if(-not $context.dateConflict){$context.effectiveDate=$printedDate;$context.effectiveTime=$printedTime;$context.dateSafe=$true}
    }elseif($view.dateStatus -eq 'Missing' -and $date -match '^\d{4}-\d{2}-\d{2}$'){$context.dateSafe=$true}
    elseif($view.dateStatus -in @('Conflict','Invalid')){$context.dateConflict=$true}
    if($context.dateConflict){$view.status='NeedsReview';$view.dateStatus='Conflict';$view.reason='The report date conflicts with its saved date or other pages. Inspect the original PDF before filing it.'}
    $source=@($Config.Sources|Where-Object Scanner -ceq $Record.Scanner|Select-Object -First 1)
    if($source.Count){
        $rules=@(Get-QaWebValue $source[0] ContentProfiles @()|Where-Object{[string](Get-QaWebValue $_ profileId '') -ceq $profile})
        if($rules.Count -eq 1){$mapped=[string](Get-QaWebValue $rules[0] category '');if($mapped -ceq 'Ask'){$context.ruleMode='Ask'}elseif($mapped -cin @('Daily','Monthly','Other') -and -not $context.isReference){$context.ruleMode='Mapped';$context.mappedCategory=$mapped;$view.mappedCategory=$mapped}}
        $view.ruleMode=$context.ruleMode
    }
    $context.profileUsable=($status -ceq 'Recognized' -and $view.completeRead -and $profile -cin @('siemens-iec-basic-v1','siemens-iec-extended-v1','siemens-iec-additional-v1','siemens-quality-daily-v1','siemens-iec-reference-v1'))
    $titleCategory=[string](Get-QaWebValue $doc Category '');if($titleCategory -cin @('Daily','Monthly') -or ($context.isReference -and $titleCategory -ceq 'Other')){$context.explicitCategory=$titleCategory;$view.suggestedCategory=$titleCategory}
    $context.suggestedCategory=$view.suggestedCategory
    if($context.mappedCategory -and $context.explicitCategory -and $context.mappedCategory -cne $context.explicitCategory){$context.typeConflict=$true;$view.status='NeedsReview';$view.reason='The explicit report title and saved report-format rule disagree. Inspect the PDF before choosing a label.'}
    $explicit='';$name=[string]$Record.OriginalFileName
    if($name -match '(?i)^(?:.*_)?(?:DAILY|QUALITYDAILY)_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.pdf$'){$explicit='Daily'}
    elseif($name -match '(?i)(?:^|_)MONTHLY(?:_|$)'){$explicit='Monthly'}
    $contentType=if($context.mappedCategory){[string]$context.mappedCategory}else{[string]$context.explicitCategory};if($context.profileUsable -and $contentType -and $explicit -and $explicit -cne $contentType){$context.typeConflict=$true;$view.status='NeedsReview';$view.reason='The explicit filename and configured report-content type disagree. Inspect the PDF before choosing a label.'}
    if($context.profileUsable -and $context.ruleMode -ceq 'Auto' -and $context.dateSafe -and -not $context.dateConflict -and -not $context.typeConflict -and -not $context.hasReferenceEvidence){$view.reason='A supported complete report layout was read. Automatic document filing is available; clinical QA review remains separate.'}
    if($context.profileUsable -and $context.ruleMode -ceq 'Ask' -and -not $context.explicitCategory -and -not $context.dateConflict){$view.reason+=' This scanner format is set to Ask. Approve this file or choose Automatic in Report formats.'}
    $context.stamp=Get-QaWebHash (($profile,[string]$view.status,[string]$view.dateStatus,[string]$context.effectiveDate,[string]$context.effectiveTime,[string]$context.mappedCategory,[string]$context.suggestedCategory,[string]$context.dateConflict,[string]$context.typeConflict,[string]$context.dateSafe,[string]$view.completeRead,[string]$context.ruleMode,[string]$context.isReference,[string]$context.hasReferenceEvidence,[string]$context.compatibilityRefreshPending) -join '|')
    return $context
    }finally{if($null -ne $TrendCacheMetadata){$context.trendStamp=Get-QaWebTrendStamp $Config $Record $context $analysis $TrendCacheMetadata}}
}
function Get-QaWebEffectiveRecord($Record,$Context){
    if($null -eq $Context -or ([string]$Record.ReportDate -ceq [string]$Context.effectiveDate -and [string]$Record.ReportTime -ceq [string]$Context.effectiveTime)){return $Record}
    $copy=$Record|Select-Object *;$copy.ReportDate=[string]$Context.effectiveDate;$copy.ReportTime=[string]$Context.effectiveTime;return $copy
}

function Get-QaWebEntryIndex($Organization){$index=@{};foreach($entry in @($Organization.Records)){$index[[string]$entry.id]=$entry};return $index}
function Get-QaWebIndexedEntry($Index,$Record){if($Index.ContainsKey([string]$Record.Id)){$entry=$Index[[string]$Record.Id];if([string]$entry.hash -ceq [string]$Record.Hash){return $entry}};return $null}
function New-QaWebFilingResult {
    param([string]$Category,[bool]$Pending,[string]$Decision,[string]$Source,[string]$Reason,[string]$Basis='ArchiveGrouping',[bool]$Inferred=$false,[string]$State='')
    if(-not $State){$State=if($Pending){'NeedsReview'}else{'Filed'}}
    return [pscustomobject]@{category=$Category;pending=$Pending;decision=$Decision;source=$Source;reason=$Reason;filingState=$State;filingBasis=$Basis;inferred=$Inferred;filingReason=$Reason}
}
function Get-QaWebClassification($Record,$Entry,$ContentContext=$null){
    $category=Get-QaWebCategory $Record $Entry;$decision=[string](Get-QaWebValue $Entry decision '')
    if($decision -in @('Approved','Disapproved')){return New-QaWebFilingResult $category $false $decision 'user' 'Saved file-organization decision. Clinical results are separate.' 'SavedDecision'}
    $legacyName=[string](Get-QaWebValue $Record ConfirmedBy '');$legacyTime=[string](Get-QaWebValue $Record ConfirmedAt '');$parsed=[datetime]::MinValue
    $validLegacy=($legacyName.Trim() -and [datetime]::TryParse($legacyTime,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed))
    $legacyDecision=[string](Get-QaWebValue $Record ReviewDecision '')
    if($validLegacy -and $legacyDecision -eq 'Declined'){return New-QaWebFilingResult $category $false 'Disapproved' 'legacy' 'Previously saved reviewed classification retained.' 'ReviewedLegacy'}
    if($validLegacy -and [string]$Record.Category -in @('Daily_QA','Monthly_QA','Acceptance_Tests')){return New-QaWebFilingResult $category $false 'Approved' 'legacy' 'Previously saved reviewed classification and evidence retained.' 'ReviewedLegacy'}
    $usable=[bool](Get-QaWebValue $ContentContext profileUsable $false);$mapped=[string](Get-QaWebValue $ContentContext mappedCategory '');$suggested=[string](Get-QaWebValue $ContentContext suggestedCategory '');$explicit=[string](Get-QaWebValue $ContentContext explicitCategory '')
    $view=Get-QaWebValue $ContentContext view $null;$profile=[string](Get-QaWebValue $view profileId '');$candidate=if($mapped){$mapped}elseif($explicit){$explicit}elseif($suggested){$suggested}else{$category}
    # Undo intentionally restores a decision request. Automatic filing never
    # learns from an approval, or overrides this explicit per-file history.
    if($null -ne $Entry -and -not $decision -and (Test-QaReportPending $Record)){return New-QaWebFilingResult $candidate $true 'Pending' 'pending' 'The previous pending classification was restored by Undo. Choose Approve or Disapprove after viewing the document.' 'Undo'}
    if([bool](Get-QaWebValue $ContentContext dateConflict $false) -or [bool](Get-QaWebValue $ContentContext typeConflict $false)){return New-QaWebFilingResult $candidate $true 'Pending' 'content' ([string](Get-QaWebValue $view reason 'The report date or type conflicts with other saved evidence.')) 'Conflict'}
    if([bool](Get-QaWebValue $ContentContext compatibilityRefreshPending $false)){return New-QaWebFilingResult $category $true 'Pending' 'pending' 'Waiting for one automatic compatibility refresh of an older saved PDF reading. No file decision is needed yet.' 'AwaitingRead' $false 'WaitingRead'}
    if([bool](Get-QaWebValue $ContentContext hasReferenceEvidence $false) -and -not [bool](Get-QaWebValue $ContentContext isReference $false)){return New-QaWebFilingResult $category $true 'Pending' 'content' 'Reference material was detected, but its complete document type remains uncertain. It cannot supply current QA evidence; the original PDF is preserved.' 'Unsupported'}
    if($usable){
        if(-not [bool](Get-QaWebValue $ContentContext dateSafe $false)){return New-QaWebFilingResult $candidate $true 'Pending' 'content' ([string](Get-QaWebValue $view reason 'The report date could not be verified.')) 'Conflict'}
        if($mapped -or $explicit){$basis=if([bool](Get-QaWebValue $ContentContext isReference $false)){'ReferenceDocument'}elseif($mapped){'ScannerRule'}else{'ExplicitTitle'};return New-QaWebFilingResult $candidate $false 'Automatic' 'content' 'Organized from verified report contents and an explicit document label or saved scanner rule. Clinical review remains separate.' $basis}
        if([string](Get-QaWebValue $ContentContext ruleMode 'Auto') -ceq 'Ask'){return New-QaWebFilingResult $candidate $true 'Pending' 'content' 'This recognized scanner format is set to Ask. Choose a file label after viewing the PDF, or change its report-format setting to Automatic.' 'ManualReview'}
        # These are reversible filing conventions, never approved QA evidence.
        # Individual/combined IEC reports occur in both archive groups; preserve
        # that grouping instead of inferring frequency from their extra tests.
        switch($profile){
            'siemens-iec-basic-v1'{return New-QaWebFilingResult 'Daily' $false 'Automatic' 'content-inferred' 'Filed as Daily from the complete basic IEC layout. This is an inferred filing convention, not clinical QA approval.' 'BasicFormat' $true}
            'siemens-iec-extended-v1'{return New-QaWebFilingResult 'Monthly' $false 'Automatic' 'content-inferred' 'Filed as Monthly from the complete extended IEC layout. This is an inferred filing convention, not verified monthly QA evidence.' 'ExtendedFormat' $true}
            'siemens-iec-additional-v1'{if($category -cin @('Daily','Monthly')){return New-QaWebFilingResult $category $false 'Automatic' 'content-inferred' 'The complete individual/combined IEC report retains its existing Daily or Monthly archive grouping. Its testing frequency is inferred, not clinically confirmed.' 'ExistingGrouping' $true}}
        }
        return New-QaWebFilingResult $candidate $true 'Pending' 'content' 'The report was read, but its Daily or Monthly filing group cannot be inferred. Its original PDF is preserved.' 'Unsupported'
    }
    $cacheStatus=[string](Get-QaWebValue $ContentContext cacheStatus 'Missing');$contentStatus=[string](Get-QaWebValue $view status 'NotRead')
    if($null -ne $ContentContext -and ($cacheStatus -cin @('ReadError','Unreadable') -or $contentStatus -cin @('ReadError','NeedsOCR'))){return New-QaWebFilingResult $category $true 'Pending' 'content' ([string](Get-QaWebValue $view reason 'The report could not be read.')) 'ReadError'}
    if($null -ne $ContentContext -and $contentStatus -cne 'NotRead'){return New-QaWebFilingResult $category $true 'Pending' 'content' ([string](Get-QaWebValue $view reason 'This report format is not yet supported.')) 'Unsupported'}
    $match=[regex]::Match([string]$Record.OriginalFileName,'(?i)^(?<kind>.+)_(?<date>\d{4}-\d{2}-\d{2})_(?<time>\d{2}-\d{2}-\d{2})\.pdf$');$date=[datetime]::MinValue;$valid=$false
    if($match.Success){$valid=[datetime]::TryParseExact(($match.Groups['date'].Value+' '+$match.Groups['time'].Value),'yyyy-MM-dd HH-mm-ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date);$valid=($valid -and $date -le (Get-Date).AddDays(1) -and [string]$Record.ReportDate -ceq $date.ToString('yyyy-MM-dd') -and [string]$Record.ReportTime -ceq $date.ToString('HH:mm:ss'))}
    $basis=[string](Get-QaWebValue $Record ClassificationBasis '');$kind=$match.Groups['kind'].Value
    $standardDaily=($valid -and [string]$Record.Category -eq 'Daily_QA' -and (($kind -match '(?i)(^|_)DAILY($|_)|^(ID_)?QUALITYDAILY$') -or ($kind -match '(?i)^(ID_)?QUALITY_CONSTANCY$' -and $basis -like 'Provisional Daily archive grouping from generic Constancy filename*')))
    if($standardDaily){$inferred=($basis -like 'Provisional*');return New-QaWebFilingResult 'Daily' $false 'Automatic' 'automatic' 'Organized as a Daily document from the standard scanner filename and saved archive grouping. This is not clinical QA approval.' 'FilenameGrouping' $inferred}
    if($valid -and [string]$Record.Category -in @('Monthly_QA','Monthly_QA/Pending_Verification') -and $kind -match '(?i)(^|_)MONTHLY($|_)'){return New-QaWebFilingResult 'Monthly' $false 'Automatic' 'automatic' 'Organized as a Monthly document from its explicit Monthly filename. Checklist verification and clinical results remain separate.' 'ExplicitFilename'}
    $pending=Test-QaReportPending $Record
    if($pending -and ($null -eq $ContentContext -or $cacheStatus -cin @('Missing','Stale'))){return New-QaWebFilingResult $category $true 'Pending' 'pending' 'Waiting for the saved PDF to be read automatically. No file decision is needed yet.' 'AwaitingRead' $false 'WaitingRead'}
    return New-QaWebFilingResult $category ([bool]$pending) $(if($pending){'Pending'}else{'Organized'}) $(if($pending){'pending'}else{'archive'}) $(if($pending){'The report type is uncertain. Its original PDF is preserved.'}else{'Existing archive document grouping retained. No new clinical result inferred.'}) 'ArchiveGrouping'
}

function Get-QaWebRecord($Dashboard,[string]$Id){if($Id -notmatch '^[0-9a-fA-F]{64}$'){throw 'Choose a saved report.'};$matches=@($Dashboard.Records|Where-Object Id -ceq $Id);if($matches.Count -ne 1){throw 'The saved report is no longer available. Refresh the report list.'};return $matches[0]}
function Assert-QaWebPdf($Config,$Record,[ref]$ReadHandle){
    $path=[IO.Path]::GetFullPath([string]$Record.DestinationPath);$root=[IO.Path]::GetFullPath((Join-Path $Config.ArchiveRoot 'Reports')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($path) -ine '.pdf'){throw 'This report is outside the verified local archive.'}
    Assert-QaWebDirect $path
    if($null -eq $ReadHandle){if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne [string]$Record.Hash){throw 'The saved PDF is missing or has changed. Run the archive check before using this report.'};return $path}
    $ReadHandle.Value=$null;$stream=$null;$sha=$null
    try{
        # FileShare.Read denies write/delete while all selected PDFs are held.
        # The exact held buffer is hashed once; no second full-file hash is used.
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);Assert-QaWebDirect $path
        $info=New-Object IO.FileInfo($path);$length=$stream.Length;$ticks=$info.LastWriteTimeUtc.Ticks;$sha=[Security.Cryptography.SHA256]::Create();$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','');$info.Refresh()
        if($hash -cne [string]$Record.Hash -or $length -ne [long]$Record.Length -or -not $info.Exists -or $info.Length -ne $length -or $info.LastWriteTimeUtc.Ticks -ne $ticks){throw 'A selected PDF changed while its exact bytes were being verified. No grouped decisions were saved.'}
        $stream.Position=0;$ReadHandle.Value=[pscustomobject]@{Stream=$stream;Path=$path;Length=$length;WriteTicks=$ticks};$stream=$null;return $path
    }finally{if($null -ne $sha){$sha.Dispose()};if($null -ne $stream){$stream.Dispose()}}
}
function Get-QaWebConnectionRows($Config){
    $path=Join-Path $Config.ArchiveRoot '.ctqa/web-connections.json';Assert-QaWebDirect $path
    if([IO.File]::Exists($path)){try{return @(([IO.File]::ReadAllText($path)|ConvertFrom-Json).Connections)}catch{}}
    return @()
}
function Get-QaWebSnapshot {
    [CmdletBinding()]param($Config,$Dashboard=$null,$Organization=$null)
    if($null -eq $Dashboard){$Dashboard=Get-QaDashboard $Config};if($null -eq $Organization){$Organization=Get-QaWebOrganization $Config};$entryIndex=Get-QaWebEntryIndex $Organization;$records=New-Object 'Collections.Generic.List[object]';$connections=@(Get-QaWebConnectionRows $Config);$sources=@{};$sourceNumbers=@{};$ordinal=0;$trendCacheMetadata=@{};$trendTokens=@{}
    foreach($source in $Config.Sources){$sources[[string]$source.Scanner]=$source;$ordinal++;$sourceNumbers[[string]$source.Scanner]=$ordinal}
    # Count the same validated analysis rows used to render this snapshot.
    # A second whole-library cache scan cannot improve this request's provenance.
    $analysisCounts=[pscustomobject]@{total=0;cached=0;pending=0;errors=0;measurementUpgradePending=0;unsupportedUpgradePending=0;backlogPending=0}
    foreach($record in @($dashboard.Records|Sort-Object ReportDate,ReportTime -Descending)){
        $entry=Get-QaWebIndexedEntry $entryIndex $record;$analysisStatus=$null;$content=Get-QaWebContentContext $Config $record $trendCacheMetadata ([ref]$analysisStatus);$trendTokens[[string]$record.Id]=$content.trendStamp;$classification=Get-QaWebClassification $record $entry $content;$category=$classification.category;$pending=$classification.pending
        $date=[string]$content.effectiveDate;$name=[string]$sources[[string]$record.Scanner].Name;$group=Get-QaWebReviewGroup $classification $content ([int]$sourceNumbers[[string]$record.Scanner])
        if($null -eq $analysisStatus){$analysisStatus=Get-QaAnalysisReadStatus -Saved $null -UpgradeMeasurements -RefreshUnsupported}
        $analysisCounts.total++;$analysisCounts.cached+=$analysisStatus.Cached;$analysisCounts.errors+=$analysisStatus.Errors
        switch([string]$analysisStatus.Reason){'New'{$analysisCounts.pending++}'MeasurementUpgrade'{$analysisCounts.measurementUpgradePending++}'UnsupportedUpgrade'{$analysisCounts.unsupportedUpgradePending++}}
        [void]$records.Add([pscustomobject]@{id=[string]$record.Id;scanner=[string]$record.Scanner;scannerName=$name;date=$date;time=[string]$content.effectiveTime;title=($name+' - '+$date+' - '+$category+' QA');filename=[string]$record.OriginalFileName;category=$category;pending=[bool]$pending;decision=$classification.decision;organizationSource=$classification.source;organizationReason=$classification.reason;filingState=$classification.filingState;filingBasis=$classification.filingBasis;inferred=[bool]$classification.inferred;filingReason=$classification.filingReason;isReference=[bool]$content.isReference;hasReferenceEvidence=[bool]$content.hasReferenceEvidence;stamp=(Get-QaWebStamp $record $entry $content);content=$content.view;reviewId=[string](Get-QaWebValue $entry revision '');printedResult='Not inferred from file classification';clinicalComponents=@(Get-QaWebValue $record ConfirmedComponents @());classificationOnly=$true;groupingKey=$group.key;groupingReason=$group.reason;approvalCategory=(Get-QaWebApprovalCategory $classification $content);approvalNeedsCategory=($classification.filingState -ceq 'NeedsReview' -and -not (Get-QaWebApprovalCategory $classification $content))})
    }
    $analysisCounts.backlogPending=$analysisCounts.pending+$analysisCounts.measurementUpgradePending+$analysisCounts.unsupportedUpgradePending
    $scanners=New-Object 'Collections.Generic.List[object]'
    foreach($source in $Config.Sources){
        $monthlySetup=Get-QaMonthlySetup $source
        $row=@($dashboard.Scanners|Where-Object Scanner -eq $source.Scanner|Select-Object -First 1);$connection=@($connections|Where-Object Scanner -eq $source.Scanner|Select-Object -Last 1)
        $status=if(Test-QaPlaceholderConnection $source){'NotConfigured'}elseif($connection.Count){[string]$connection[0].Status}elseif($row.Count){[string]$row[0].Status}else{'Unknown'}
        $message=if($status -eq 'NotConfigured'){'Apply your scanner connection profile or enter the real reports folder.'}elseif($connection.Count){[string]$connection[0].Message}elseif($row.Count){[string]$row[0].Message}else{'Use Test connection to check this scanner.'}
        [void]$scanners.Add([pscustomobject]@{id=[string]$source.Scanner;name=[string]$source.Name;path=[string]$source.Path;username=[string]$source.Username;drive=[string]$source.DriveLetter;status=$status;message=$message;code=$(if($connection.Count){[int](Get-QaWebValue $connection[0] NativeCode 0)}else{0});savedReports=@($records|Where-Object scanner -eq $source.Scanner).Count;dailySchedule=[string]$source.DailySchedule;activeFrom=[string]$source.ActiveFrom;expectedMonthly=[bool]$source.ExpectedMonthly;monthlyDueDay=[int](Get-QaWebValue $source MonthlyDueDay 0);contentProfiles=@(Get-QaWebValue $source ContentProfiles @());checklist=@(Get-QaWebValue $source MonthlyChecklist @());checklistEffectiveMonth=$monthlySetup.checklistEffectiveMonth;monthlyChecklistHistory=$monthlySetup.monthlyChecklistHistory;nextChecklistEffectiveMonth=$monthlySetup.nextChecklistEffectiveMonth;excludedDates=@(Get-QaWebValue $source ExcludedDates @())})
    }
    # Reference/baseline PDFs remain available but cannot supply current Daily
    # receipt or reviewed Monthly evidence, even after an old file decision.
    $referenceIds=@{};foreach($row in $records){if($row.isReference -or $row.hasReferenceEvidence){$referenceIds[[string]$row.id]=$true}}
    $receiptDashboard=$dashboard
    if($referenceIds.Count){$receiptDashboard=$dashboard|Select-Object *;$receiptDashboard.Records=@($dashboard.Records|Where-Object{-not $referenceIds.ContainsKey([string]$_.Id)})}
    # Only scheduling is needed here; the rows above already supply receipt.
    # Do not reread every Daily analysis to compute unused legacy findings.
    $todayDate=(Get-Date).Date
    # Organizationally approved Daily documents can satisfy receipt, never clinical passage.
    $received=0;$expected=0;$day=$todayDate.ToString('yyyy-MM-dd')
    foreach($source in $Config.Sources){if(Test-QaDailyRequired -Source $source -Date $todayDate){$expected++;if(@($records|Where-Object{$_.scanner -eq $source.Scanner -and $_.date -eq $day -and $_.category -eq 'Daily' -and -not $_.pending -and -not $_.isReference -and -not $_.hasReferenceEvidence}).Count){$received++}}}
    $headline=if(-not $expected){'No Daily QA reports scheduled today'}elseif($received -eq $expected){'All required Daily QA reports received'}else{"$received of $expected Daily QA reports received"}
    $last=$null
    foreach($history in @($organization.History|Select-Object -Last 1)){
        if($history.action -eq 'Undo' -or [string](Get-QaWebValue $history batchId '')){continue};$matching=@($records|Where-Object id -ceq $history.recordId);if($matching.Count -eq 1 -and $matching[0].reviewId -ceq $history.reviewId){$last=[pscustomobject]@{recordId=$history.recordId;reviewId=$history.reviewId;stamp=$matching[0].stamp}}
    }
    return [pscustomobject]@{version='5.7.14';previewMode=$(if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'windows'}else{'browser'});workspace=[string]$Config.AppRoot;archiveRoot=[string]$Config.ArchiveRoot;libraryRoot=(Join-Path $Config.ArchiveRoot 'Report Library');setupComplete=[bool]$dashboard.SetupComplete;records=@($records.ToArray());scanners=@($scanners.ToArray());today=[pscustomobject]@{headline=$headline;received=$received;expected=$expected;date=$day};months=@(Get-QaMonthOverview $Config $receiptDashboard|ForEach-Object{[pscustomobject]@{scanner=$_.Scanner;name=$_.Name;month=$_.Month;progress=$_.Progress;due=$_.Due;timing=$_.Timing;detail=$_.Detail;status=$_.Status}});analysis=$analysisCounts;trendsRevision=(Get-QaWebTrendsRevision $Config @($dashboard.Records) $trendTokens);settings=[pscustomobject]@{monitorMinutes=[int](Get-QaWebValue $Config MonitorMinutes 15);autoAnalyze=[bool](Get-QaWebValue $Config AutoAnalyze $true);autoUpdateOnOpen=[bool](Get-QaWebValue $Config AutoUpdateOnOpen $true);pdfReaderMode=(Get-QaAnalysisReaderMode $Config);theme=$(if([string](Get-QaWebValue $Config Theme 'Light') -ceq 'Dark'){'Dark'}else{'Light'})};filingSummary=[pscustomobject]@{waitingRead=@($records|Where-Object filingState -ceq 'WaitingRead').Count;needsReview=@($records|Where-Object filingState -ceq 'NeedsReview').Count;filed=@($records|Where-Object filingState -ceq 'Filed').Count;inferred=@($records|Where-Object inferred).Count};pendingSummary=[pscustomobject]@{pending=@($records|Where-Object pending).Count;automatic=@($records|Where-Object decision -eq 'Automatic').Count;approved=@($records|Where-Object decision -eq 'Approved').Count;disapproved=@($records|Where-Object decision -eq 'Disapproved').Count};lastDecision=$last;undoBatch=(Get-QaWebUndoBatch $Config $Dashboard $Organization @($records.ToArray()));batchReviewLimit=50;attentionCount=@($dashboard.Attention).Count;onlineEnabled=$false}
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
function Set-QaWebProgress($Progress,[string]$Stage,[int]$Completed=-1,[int]$Total=-1){
    if($null -eq $Progress){return};$Progress['Stage']=$Stage
    if($Completed -ge 0){$Progress['Completed']=$Completed};if($Total -ge 0){$Progress['Total']=$Total}
    if($Total -gt 0 -and $Completed -ge 0){$Progress['Percent']=[math]::Min(100,[math]::Max(0,100.0*$Completed/$Total))}
}
function Test-QaWebCancelled($Progress){return ($null -ne $Progress -and [bool](Get-QaWebValue $Progress Cancel $false))}
function Assert-QaWebDirectCached([string]$Path,$Checked){
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if($Checked.ContainsKey($current)){return}
        if(([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) -and (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Use direct library folders without links or junctions.'}
        $Checked[$current]=$true;$current=[IO.Path]::GetDirectoryName($current)
    }
}
function Get-QaWebLibraryHash([string]$Path,$Metrics){$Metrics.hashedFiles++;return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Copy-QaWebLibraryPdf([string]$Source,[string]$Target,[string]$Hash,$Progress,$Metrics){
    $temp=$Target+'.'+[guid]::NewGuid().ToString('N')+'.partial';$inputStream=$null;$outputStream=$null;$sha=$null
    try{
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Target))
        $inputStream=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$outputStream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$sha=[Security.Cryptography.SHA256]::Create();$Metrics.hashedFiles++
        $buffer=New-Object byte[] 1048576
        while(($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){if(Test-QaWebCancelled $Progress){throw [OperationCanceledException]::new('Library refresh cancelled safely.')} ;$outputStream.Write($buffer,0,$read);[void]$sha.TransformBlock($buffer,0,$read,$buffer,0)}
        [void]$sha.TransformFinalBlock($buffer,0,0);$actual=([BitConverter]::ToString($sha.Hash)).Replace('-','');$outputStream.Flush($true);$outputStream.Dispose();$outputStream=$null;$inputStream.Dispose();$inputStream=$null
        $verified=New-Object IO.FileInfo($temp);$verifiedLength=[long]$verified.Length;$verifiedTicks=[long]$verified.LastWriteTimeUtc.Ticks
        if($actual -cne $Hash -or (Get-QaWebLibraryHash $temp $Metrics) -cne $Hash){throw 'A saved PDF changed or its readable-copy fingerprint did not match. The existing files were preserved.'}
        $verified.Refresh();if(-not $verified.Exists -or $verified.Length -ne $verifiedLength -or $verified.LastWriteTimeUtc.Ticks -ne $verifiedTicks){throw 'A readable copy changed while it was being verified. Refresh or verify the archive before continuing.'}
        [IO.File]::Move($temp,$Target)
        return [pscustomobject]@{length=$verifiedLength;writeTicks=$verifiedTicks}
    }finally{if($null -ne $inputStream){$inputStream.Dispose()};if($null -ne $outputStream){$outputStream.Dispose()};if($null -ne $sha){$sha.Dispose()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Update-QaWebLibrary {
    param($Config,[object[]]$OnlyRecords=@(),$Dashboard=$null,$Organization=$null,$Progress=$null,[switch]$Verify)
    if($null -eq $Dashboard){$Dashboard=Get-QaDashboard $Config};if($null -eq $Organization){$Organization=Get-QaWebOrganization $Config}
    $entries=Get-QaWebEntryIndex $Organization;$folderNames=Get-QaWebFolderNames $Config;$sources=@{};foreach($source in $Config.Sources){$sources[[string]$source.Scanner]=$source}
    $library=Join-Path $Config.ArchiveRoot 'Report Library';$manifestPath=Join-Path $Config.ArchiveRoot '.ctqa/web-library.json';Assert-QaWebDirect $library;Assert-QaWebDirect $manifestPath;[void][IO.Directory]::CreateDirectory($library)
    $manifest=[pscustomobject]@{Version=2;Records=@()};if([IO.File]::Exists($manifestPath)){$manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json;if($manifest.Version -notin @(1,2)){throw 'The readable-library index is unsupported.'}}
    $byId=@{};$used=@{};foreach($owned in @($manifest.Records)){
        if([string]$owned.id -notmatch '^[a-fA-F0-9]{64}$' -or [string]$owned.hash -notmatch '^[a-fA-F0-9]{64}$' -or -not (Test-QaWebRelative ([string]$owned.relative)) -or $byId.ContainsKey([string]$owned.id) -or $used.ContainsKey([string]$owned.relative)){throw 'The readable-library ownership index contains invalid or conflicting entries. It was preserved.'}
        $byId[[string]$owned.id]=$owned;$used[[string]$owned.relative]=[string]$owned.id
    }
    $selected=@{};foreach($id in $OnlyRecords){$selected[[string]$id]=$true};$rows=@(if($selected.Count){$Dashboard.Records|Where-Object{$selected.ContainsKey([string]$_.Id)}}else{$Dashboard.Records})
    $metrics=[pscustomobject]@{libraryRoot=$library;copied=0;unchanged=0;total=$rows.Count;completed=0;hashedFiles=0;manifestWrites=0;retired=0;failed=0;cancelled=$false;metadataFastPath=(-not [bool]$Verify)}
    $checked=@{};$dirty=$false;$retire=New-Object 'Collections.Generic.List[object]';$reportsRoot=[IO.Path]::GetFullPath((Join-Path $Config.ArchiveRoot 'Reports')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    Set-QaWebProgress $Progress $(if($Verify){'Verifying'}else{'Library'}) 0 $rows.Count
    try{
        foreach($record in $rows){
            if(Test-QaWebCancelled $Progress){$metrics.cancelled=$true;break}
            try{
                $id=[string]$record.Id;$entry=Get-QaWebIndexedEntry $entries $record;$content=Get-QaWebContentContext $Config $record;$effective=Get-QaWebEffectiveRecord $record $content;$classification=Get-QaWebClassification $record $entry $content;$category=$classification.category;$relative=Get-QaWebRelative $effective $category $folderNames[[string]$record.Scanner];$previous=$null
                if($byId.ContainsKey($id)){$previous=$byId[$id]}
                if($null -ne $previous -and [string]$previous.category -ceq $category -and [string](Get-QaWebValue $previous filingDate ([string]$record.ReportDate)) -ceq [string]$effective.ReportDate -and [string](Get-QaWebValue $previous filingTime ([string]$record.ReportTime)) -ceq [string]$effective.ReportTime){$relative=[string]$previous.relative}
                $target=Join-Path $library ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar));$sourcePath=[IO.Path]::GetFullPath([string]$record.DestinationPath)
                if(-not $sourcePath.StartsWith($reportsRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($sourcePath) -ine '.pdf'){throw 'A report points outside the verified local archive.'}
                Assert-QaWebDirectCached $sourcePath $checked;Assert-QaWebDirectCached $target $checked
                $owned=($null -ne $previous -and [string]$previous.relative -ceq $relative)
                if(-not $owned -and ([IO.File]::Exists($target) -or $used.ContainsKey($relative))){
                    $base=$relative.Substring(0,$relative.Length-4)
                    do{$relative=$base+'-copy-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.pdf';$target=Join-Path $library ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))}while($used.ContainsKey($relative) -or [IO.File]::Exists($target))
                    Assert-QaWebDirectCached $target $checked
                }
                if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $target.Length -gt 245){throw 'The readable-library path is too long. Choose a shorter local archive folder.'}
                $sourceInfo=New-Object IO.FileInfo($sourcePath);if(-not $sourceInfo.Exists -or $sourceInfo.Length -ne [long]$record.Length){throw 'A saved PDF is missing or changed. Run the archive check before refreshing its readable copy.'}
                $targetInfo=New-Object IO.FileInfo($target);$targetExists=$targetInfo.Exists
                $cached=($owned -and $targetExists -and -not $Verify -and [string]$previous.hash -ceq [string]$record.Hash -and [string](Get-QaWebValue $previous sourcePath '') -ceq $sourcePath -and [long](Get-QaWebValue $previous sourceLength -1) -eq $sourceInfo.Length -and [long](Get-QaWebValue $previous sourceWriteTicks -1) -eq $sourceInfo.LastWriteTimeUtc.Ticks -and [long](Get-QaWebValue $previous targetLength -1) -eq $targetInfo.Length -and [long](Get-QaWebValue $previous targetWriteTicks -1) -eq $targetInfo.LastWriteTimeUtc.Ticks)
                if($cached){$metrics.unchanged++}else{
                    $sourceLength=[long]$sourceInfo.Length;$sourceTicks=[long]$sourceInfo.LastWriteTimeUtc.Ticks
                    $targetLength=if($targetExists){[long]$targetInfo.Length}else{-1};$targetTicks=if($targetExists){[long]$targetInfo.LastWriteTimeUtc.Ticks}else{-1}
                    if($targetExists){
                        if((Get-QaWebLibraryHash $sourcePath $metrics) -cne [string]$record.Hash){throw 'A saved PDF failed its indexed SHA-256 check. The readable copy was not changed.'}
                        if((Get-QaWebLibraryHash $target $metrics) -cne [string]$record.Hash){throw 'A readable PDF was edited. It was preserved; restore the readable copy or choose a new library location.'}
                        $metrics.unchanged++
                    }else{$verifiedCopy=Copy-QaWebLibraryPdf $sourcePath $target ([string]$record.Hash) $Progress $metrics;$targetLength=[long]$verifiedCopy.length;$targetTicks=[long]$verifiedCopy.writeTicks;$metrics.copied++}
                    $sourceInfo.Refresh();$targetInfo.Refresh()
                    if(-not $sourceInfo.Exists -or $sourceInfo.Length -ne $sourceLength -or $sourceInfo.LastWriteTimeUtc.Ticks -ne $sourceTicks -or -not $targetInfo.Exists -or $targetInfo.Length -ne $targetLength -or $targetInfo.LastWriteTimeUtc.Ticks -ne $targetTicks){throw 'A saved or readable PDF changed while it was being verified. No metadata cache was saved for it; run the archive check before trying again.'}
                    $new=[pscustomobject]@{id=$id;hash=[string]$record.Hash;relative=$relative;category=$category;filingDate=[string]$effective.ReportDate;filingTime=[string]$effective.ReportTime;original=[string]$record.OriginalFileName;sourcePath=$sourcePath;sourceLength=$sourceLength;sourceWriteTicks=$sourceTicks;targetLength=$targetLength;targetWriteTicks=$targetTicks}
                    $byId[$id]=$new;$used[$relative]=$id;$dirty=$true
                    if($null -ne $previous -and [string]$previous.relative -cne $relative){[void]$retire.Add($previous)}
                }
                $metrics.completed++;if($null -ne $Progress){$Progress['Copied']=$metrics.copied;$Progress['Unchanged']=$metrics.unchanged};Set-QaWebProgress $Progress $(if($Verify){'Verifying'}else{'Library'}) $metrics.completed $rows.Count
            }catch{if(Test-QaWebCancelled $Progress){$metrics.cancelled=$true;break};$metrics.failed++;if($null -ne $Progress){$Progress['Failed']=$metrics.failed};throw}
        }
    }finally{
        # Commit completed ownership once even when interrupted. A retry can then
        # reuse the completed copies instead of treating them as unowned files.
        if($dirty){Write-QaWebAtomic $manifestPath ([pscustomobject]@{Version=2;Records=@($byId.Values|Sort-Object id)});$metrics.manifestWrites++}
        foreach($old in $retire){
            $oldPath=Join-Path $library (([string]$old.relative).Replace('/',[IO.Path]::DirectorySeparatorChar));Assert-QaWebDirectCached $oldPath $checked
            if([IO.File]::Exists($oldPath) -and (Get-QaWebLibraryHash $oldPath $metrics) -ceq [string]$old.hash){$history=Join-Path $Config.ArchiveRoot ('.ctqa/library-history/'+[guid]::NewGuid().ToString('N')+'.pdf');Assert-QaWebDirectCached $history $checked;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($history));[IO.File]::Move($oldPath,$history);$metrics.retired++}
        }
    }
    return $metrics
}

function Invoke-QaWebOrganization {
    param($Config,$Request,$Progress=$null,[ref]$OperationContext)
    if((Test-QaWebHasProperty $Request selections) -or (Test-QaWebHasProperty $Request batchId)){$arguments=@{Config=$Config;Request=$Request;Progress=$Progress};if($null -ne $OperationContext){$arguments.OperationContext=$OperationContext};return Invoke-QaWebBatchOrganization @arguments}
    if($null -ne $OperationContext){$OperationContext.Value=$null}
    $requestedCategory='';if(Test-QaWebHasProperty $Request category){$requestedCategory=[string]$Request.category;if([string]$Request.action -cne 'Approve' -or $requestedCategory -cnotin @('Daily','Monthly','Other')){throw 'Choose Daily, Monthly or Other only when approving a file.'}}
    $meta=Join-Path $Config.ArchiveRoot '.ctqa';Assert-QaWebDirect $meta;[void][IO.Directory]::CreateDirectory($meta);$lock=$null
    try{
        try{$lock=[IO.File]::Open((Join-Path $meta 'archive.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'An archive operation is already running. Wait for it to finish, then try again.'}
        $dashboard=Get-QaDashboard $Config;$record=Get-QaWebRecord $dashboard ([string](Get-QaWebValue $Request id ''));$organization=Get-QaWebOrganization $Config;$before=Get-QaWebEntry $organization $record;$content=Get-QaWebContentContext $Config $record
        if([string](Get-QaWebValue $Request stamp '') -cne (Get-QaWebStamp $record $before $content)){throw 'This report changed after it was displayed. Refresh before deciding.'}
        [void](Assert-QaWebPdf $Config $record);$action=[string]$Request.action;$category=Get-QaWebCategory $record $before;$decision=''
        if($action -eq 'Undo'){
            $history=@($organization.History|Where-Object recordId -ceq $record.Id|Select-Object -Last 1)
            if($history.Count -and [string](Get-QaWebValue $history[0] batchId '')){throw 'Use Undo last batch to restore grouped decisions together.'}
            if($history.Count -ne 1 -or [string](Get-QaWebValue $Request reviewId '') -cne [string]$history[0].reviewId -or [string](Get-QaWebValue $before revision '') -cne [string]$history[0].reviewId){throw 'Only the latest decision for this report can be undone.'}
            $restore=$history[0].before;$category=[string](Get-QaWebValue $restore category '');$decision=[string](Get-QaWebValue $restore decision '')
        }else{
            $classification=Get-QaWebClassification $record $before $content;$category=[string]$classification.category;$pending=$classification.pending;if(-not $pending){throw 'This report is already organized. Refresh the pending list.'}
            if($action -eq 'Approve'){$decision='Approved';if($requestedCategory){$category=$requestedCategory}}elseif($action -eq 'Disapprove'){$decision='Disapproved';$category='Other'}else{throw 'Unsupported file decision.'}
        }
        $revision=[guid]::NewGuid().ToString('N');$actor=[Environment]::UserName
        $after=[pscustomobject]@{id=[string]$record.Id;hash=[string]$record.Hash;revision=$revision;decision=$decision;category=$category;time=[datetime]::UtcNow.ToString('o');actor=$actor;actorKind='Windows account identifier; not a verified personal QA reviewer'}
        $history=[pscustomobject]@{reviewId=$revision;recordId=[string]$record.Id;hash=[string]$record.Hash;action=$action;time=$after.time;actor=$actor;actorKind=$after.actorKind;before=$before;after=$after;scope='Document classification only; no clinical result or checklist verification'}
        $organization.Records=@($organization.Records|Where-Object id -cne $record.Id)+@($after);$organization.History=@($organization.History)+@($history)
        if(Test-QaWebCancelled $Progress){if($null -ne $OperationContext){$OperationContext.Value=[pscustomobject]@{Dashboard=$dashboard;Organization=$null}};return [pscustomobject]@{cancelled=$true;warning='';recordId=[string]$record.Id;reviewId='';stamp=(Get-QaWebStamp $record $before $content)}}
        Write-QaWebAtomic (Join-Path $meta 'organization.json') $organization
        # Only publish the internal reuse context after the durable decision write.
        # Readable-copy errors do not undo a committed file decision.
        if($null -ne $OperationContext){$OperationContext.Value=[pscustomobject]@{Dashboard=$dashboard;Organization=$organization}}
        $warning='';try{[void](Update-QaWebLibrary -Config $Config -OnlyRecords @([string]$record.Id) -Dashboard $dashboard -Organization $organization -Progress $Progress)}catch{$warning='Decision saved. Readable folders need refresh: '+$_.Exception.Message}
        return [pscustomobject]@{recordId=[string]$record.Id;reviewId=$revision;stamp=(Get-QaWebStamp $record $after $content);warning=$warning;classificationOnly=$true}
    }finally{if($null -ne $lock){$lock.Dispose()}}
}
function New-QaWebArtifactPath($AppRoot,[string]$Folder,[string]$Prefix,[ValidateSet('.zip','.html')][string]$Extension='.zip'){$root=Join-Path $AppRoot $Folder;Assert-QaWebDirect $root;[void][IO.Directory]::CreateDirectory($root);return Join-Path $root ($Prefix+'-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+$Extension)}
function ConvertTo-QaWebCsv([string]$Value){if($Value -match '^[\x00-\x20]*[=+@\-\t\r]'){return ("'"+$Value)};return $Value}
function New-QaWebExport {
    param($Config,[string[]]$Ids,$Progress=$null)
    if(-not $Ids.Count){throw 'Select at least one report to export.'};if($Ids.Count -gt 20000){throw 'Export at most 20,000 reports at once.'}
    $dashboard=Get-QaDashboard $Config;$organization=Get-QaWebOrganization $Config;$exportEntryIndex=Get-QaWebEntryIndex $organization;$folderNames=Get-QaWebFolderNames $Config;$seen=@{};$rows=@();foreach($id in $Ids){if(Test-QaWebCancelled $Progress){return ''};if($seen.ContainsKey($id)){continue};$seen[$id]=$true;$record=Get-QaWebRecord $dashboard $id;[void](Assert-QaWebPdf $Config $record);$rows+=@($record)}
    Set-QaWebProgress $Progress 'Exporting' 0 $rows.Count
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    $path=New-QaWebArtifactPath $Config.AppRoot 'Exports' 'CTQA-Reports';$temp=$path+'.partial';$zip=$null;$stream=$null;$summary=New-Object Text.StringBuilder;$manifest=New-Object 'Collections.Generic.List[object]';$usedPaths=@{}
    try{
        $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew);$zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        [void]$summary.Append('<!doctype html><html lang="en"><meta charset="utf-8"><title>CT QA reports</title><style>body{font:16px/1.5 Segoe UI,sans-serif;max-width:1000px;margin:35px auto}td,th{padding:12px;border-bottom:1px solid #ddd;text-align:left}a{color:#087568}</style><h1>CT QA report package</h1><p>Saved report documents. Approve/Disapprove labels organize files; they do not declare clinical PASS/FAIL or complete a Monthly checklist.</p><table><tr><th>Scanner</th><th>Date</th><th>Type</th><th>Open PDF</th></tr>')
        $exported=0
        foreach($record in $rows){
            if(Test-QaWebCancelled $Progress){return ''}
            $entry=Get-QaWebIndexedEntry $exportEntryIndex $record;$content=Get-QaWebContentContext $Config $record;$effective=Get-QaWebEffectiveRecord $record $content;$classification=Get-QaWebClassification $record $entry $content;$category=$classification.category;$source=@($Config.Sources|Where-Object Scanner -eq $record.Scanner)[0];$organizationStatus=if($classification.pending){'Pending suggestion'}else{$classification.decision};$typeLabel=$category+' document';if($organizationStatus -eq 'Pending suggestion'){$typeLabel+=' - pending classification'};$name=Get-QaWebRelative $effective $category $folderNames[[string]$record.Scanner]
            $baseName=$name;$suffix=1;while($usedPaths.ContainsKey($name)){$suffix++;$name=$baseName.Substring(0,$baseName.Length-4)+'-Report-'+$suffix+'.pdf'};$usedPaths[$name]=$true
            $pdf=Assert-QaWebPdf $Config $record;[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$pdf,$name,[IO.Compression.CompressionLevel]::Optimal);$exported++;Set-QaWebProgress $Progress 'Exporting' $exported $rows.Count
            $nameSafe=ConvertTo-QaWebCsv ([string]$record.OriginalFileName)
            [void]$manifest.Add([pscustomobject]@{Scanner=(ConvertTo-QaWebCsv $source.Name);ReportId=$record.Id;ReportDate=$effective.ReportDate;ReportTime=$effective.ReportTime;OriginalFilename=$nameSafe;DocumentType=$category;OrganizationDecision=$organizationStatus;OriginalArchiveCategory=[string]$record.Category;ExportPath=$name;SHA256=$record.Hash;ClinicalReviewer=(ConvertTo-QaWebCsv ([string](Get-QaWebValue $record ConfirmedBy '')));ClinicalReviewTime=[string](Get-QaWebValue $record ConfirmedAt '');VerifiedChecklistItems=(@(Get-QaWebValue $record ConfirmedComponents @()) -join '; ');PrintedResultStatus=[string](Get-QaWebValue (Get-QaSavedAnalysis $Config $record) Status 'Not analyzed');ClinicalQAResult='Not inferred from classification'})
            $link=($name.Split('/')|ForEach-Object{[Uri]::EscapeDataString($_)}) -join '/'
            [void]$summary.Append('<tr><td>'+[Net.WebUtility]::HtmlEncode($source.Name)+'</td><td>'+[Net.WebUtility]::HtmlEncode([string]$effective.ReportDate)+'</td><td>'+[Net.WebUtility]::HtmlEncode($typeLabel)+'</td><td><a href="'+$link+'">'+[Net.WebUtility]::HtmlEncode([string]$record.OriginalFileName)+'</a></td></tr>')
        }
        [void]$summary.Append('</table><p>Every exported PDF was checked against its saved SHA-256 fingerprint.</p></html>')
        foreach($item in @(@{Name='Report Summary.html';Text=$summary.ToString()},@{Name='Report list.csv';Text=(@($manifest.ToArray())|ConvertTo-Csv -NoTypeInformation|Out-String)})){$e=$zip.CreateEntry($item.Name);$writer=New-Object IO.StreamWriter($e.Open(),(New-Object Text.UTF8Encoding $true));try{$writer.Write($item.Text)}finally{$writer.Dispose()}}
        $zip.Dispose();$zip=$null;$stream=$null
        # Read back every exported PDF to detect a source changing during compression.
        $verify=[IO.Compression.ZipFile]::OpenRead($temp);try{foreach($row in $manifest){$input=$verify.GetEntry($row.ExportPath).Open();$sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($input))).Replace('-','');if($hash -cne [string]$row.SHA256){throw 'An exported PDF changed during export. No completed package was produced.'}}finally{$sha.Dispose();$input.Dispose()}}}finally{$verify.Dispose()}
        if(Test-QaWebCancelled $Progress){return ''};[IO.File]::Move($temp,$path);return $path
    }finally{if($null -ne $zip){$zip.Dispose()};if($null -ne $stream){$stream.Dispose()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Get-QaWebSupportContext {
    param($Config,$Dashboard,$Work=@())
    $organizationReadable=$true;$entries=@{};try{$organization=Get-QaWebOrganization $Config;$entries=Get-QaWebEntryIndex $organization}catch{$organizationReadable=$false};$rows=New-Object 'Collections.Generic.List[object]'
    foreach($record in @($Dashboard.Records)){
        $number=0
        try{
        $source=@($Config.Sources|Where-Object Scanner -ceq $record.Scanner|Select-Object -First 1);$number=if($source.Count){1+[Array]::IndexOf([object[]]$Config.Sources,$source[0])}else{0}
        $content=Get-QaWebContentContext $Config $record;$entry=Get-QaWebIndexedEntry $entries $record;$filing=if($organizationReadable){Get-QaWebClassification $record $entry $content}else{[pscustomobject]@{decision='Unknown';category='Unknown';pending=$false;filingState='NeedsReview';filingBasis='Unsupported';inferred=$false}};$saved=Get-QaSavedAnalysis $Config $record
        $reasons=New-Object 'Collections.Generic.List[string]';if(-not $organizationReadable){[void]$reasons.Add('OrganizationUnreadable')};$cacheStatus='Valid';$measurement='NotRead';$profile='Unknown';$schema=0;$measurementVersion=0;$measurementSupportRevision=0;$revision=0;$model='Unknown'
        if($null -eq $saved){$cacheStatus='Missing';[void]$reasons.Add('CacheMissing');if([string]$record.Hash -cmatch '^[0-9A-Fa-f]{64}$'){$cache=Join-Path $Config.ArchiveRoot ('.ctqa/analysis/'+[string]$record.Hash+'.json');Assert-QaWebDirect $cache;if([IO.File]::Exists($cache)){$cacheStatus='Stale';[void]$reasons.Add('CacheStale')}}}
        else{
            $schema=[int](Get-QaWebValue $saved AnalysisCacheSchemaVersion 0);$revision=[int](Get-QaWebValue $saved ContentSupportRevision 0);$doc=Get-QaWebValue $saved DocumentClassification $null;$measured=Get-QaWebValue $saved MeasurementsDocument $null;$measurementVersion=[int](Get-QaWebValue $measured MeasurementVersion 0);$measurementSupportRevision=[int](Get-QaWebValue $measured MeasurementSupportRevision 0)
            if([string](Get-QaWebValue $saved Status '') -ceq 'ReadError'){$cacheStatus='ReadFailed';$measurement='ReadError';[void]$reasons.Add('ReaderFailed')}
            elseif($measurementVersion -ne 1){$measurement='UpgradePending';[void]$reasons.Add('MeasurementUpgradePending')}
            else{$measurement=[string](Get-QaWebValue $measured Status 'Unknown');$mReason=[string](Get-QaWebValue $measured ReasonCode '');if($mReason){[void]$reasons.Add($mReason)}}
            $dReason=[string](Get-QaWebValue $doc ReasonCode '');if($dReason){[void]$reasons.Add($dReason)}
            if([string](Get-QaWebValue $doc Model '') -match '(?i)Definition Edge'){$model='Edge'}elseif([string](Get-QaWebValue $doc Model '') -match '(?i)Definition Flash'){$model='Flash'}elseif([string](Get-QaWebValue $doc Model '') -match '(?i)SOMATOM\s+Drive'){$model='Drive'}
        }
        if($content.dateConflict){[void]$reasons.Add('DateConflict');if($content.view.time -and [string]$record.ReportTime -and $content.view.time -cne [string]$record.ReportTime){[void]$reasons.Add('TimeConflict')}}
        if($content.typeConflict){[void]$reasons.Add('TypeConflict')}
        if($content.hasReferenceEvidence){$measurement='ReferenceExcluded';[void]$reasons.Add('ReferenceExcluded')}
        if($content.isReference){[void]$reasons.Add('ReferenceDocument')}
        $reviewGroup=Get-QaWebReviewGroup $filing $content $number
        if($filing.filingState -ceq 'WaitingRead'){[void]$reasons.Add('AwaitingRead')}
        if($filing.filingBasis -ceq 'ManualReview'){[void]$reasons.Add('ManualReview')}
        if($null -ne $entry -and -not [string](Get-QaWebValue $entry decision '') -and $filing.pending){[void]$reasons.Add('UndoRestored')}
        switch([string]$content.view.profileId){'siemens-iec-basic-v1'{$profile='Basic'}'siemens-iec-extended-v1'{$profile='Extended'}'siemens-iec-additional-v1'{$profile='Additional'}'siemens-quality-daily-v1'{$profile='Daily'}'siemens-iec-reference-v1'{$profile='Reference'}}
        $reader=[string]$content.view.reader.name;if(-not $reader){$reader='Unknown'}
        $length=[long](Get-QaWebValue $record Length 0);$sizeBand=if($length -le 0){'Unknown'}elseif($length -lt 1048576){'Small'}elseif($length -lt 10485760){'Medium'}else{'Large'}
        [void]$rows.Add([pscustomobject]@{scannerNumber=$number;filingStatus=[string]$filing.decision;category=[string]$filing.category;filingState=[string]$filing.filingState;filingBasis=[string]$filing.filingBasis;inferred=[bool]$filing.inferred;groupingReason=$reviewGroup.reason;textCacheStatus=$cacheStatus;cacheSchemaVersion=$schema;measurementVersion=$measurementVersion;measurementSupportRevision=$measurementSupportRevision;measurementStatus=$measurement;contentStatus=[string]$content.view.status;profile=$profile;reader=$reader;reasonCodes=@($reasons|Select-Object -Unique);readMilliseconds=[long]$content.view.reader.elapsedMs;readPages=[int]$content.view.readPages;totalPages=[int]$content.view.pages;measurementCount=@($content.view.measurements).Count;contentSupportRevision=$revision;model=$model;sizeBand=$sizeBand})
        }catch{
            [void]$rows.Add([pscustomobject]@{scannerNumber=$number;filingStatus='Unknown';category='Unknown';filingState='NeedsReview';filingBasis='ReadError';inferred=$false;groupingReason='Other';textCacheStatus='Unreadable';cacheSchemaVersion=0;measurementVersion=0;measurementSupportRevision=0;measurementStatus='Unknown';contentStatus='Unknown';profile='Unknown';reader='Unknown';reasonCodes=@('CacheUnreadable');readMilliseconds=0;readPages=0;totalPages=0;measurementCount=0;contentSupportRevision=0;model='Unknown';sizeBand='Unknown'})
        }
    }
    return [pscustomobject]@{Reports=@($rows.ToArray());Work=@($Work);Settings=[pscustomobject]@{readerMode=(Get-QaAnalysisReaderMode $Config);autoAnalyze=[bool](Get-QaWebValue $Config AutoAnalyze $true);monitorMinutes=[int](Get-QaWebValue $Config MonitorMinutes 0);readingBatchLimit=20;supportRevision=(Get-QaContentSupportRevision)}}
}
function Get-QaWebTrendStamp($Config,$Record,$Context,$Analysis,$Metadata){
    $hash=[string](Get-QaWebValue $Record Hash '');$cache='Missing'
    if($hash -cmatch '^[A-Fa-f0-9]{64}$'){
        if($Metadata.ContainsKey($hash)){$cache=[string]$Metadata[$hash]}else{
            $path=Join-Path $Config.ArchiveRoot ('.ctqa/analysis/'+$hash+'.json')
            try{Assert-QaWebDirect $path;$info=New-Object IO.FileInfo($path);$cache=([string]$info.Exists)+'|'+$(if($info.Exists){[string]$info.Length}else{'0'})+'|'+[string]$info.LastWriteTimeUtc.Ticks}catch{$cache='Unavailable'}
            $Metadata[$hash]=$cache
        }
    }
    return Get-QaWebHash (([string]$Context.cacheStatus,[string](Get-QaWebValue $Analysis Status ''),[string]$Context.stamp,$cache) -join '|')
}
function Get-QaWebTrendsRevision($Config,$Records,$Tokens){
    $parts=New-Object 'Collections.Generic.List[string]';[void]$parts.Add(('ReaderMode|'+(Get-QaAnalysisReaderMode $Config)))
    foreach($source in @($Config.Sources|Sort-Object Scanner)){[void]$parts.Add(('Scanner|'+[string]$source.Scanner+'|'+[string]$source.Name))}
    foreach($record in @($Records|Sort-Object Id)){
        $archived=Get-QaWebValue $record FirstArchived '';$parsed=[datetime]::MinValue;$ticks=[long]0
        if($archived -is [datetime]){$ticks=$archived.ToUniversalTime().Ticks}elseif([datetime]::TryParse([string]$archived,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)){$ticks=$parsed.ToUniversalTime().Ticks}
        [void]$parts.Add((([string]$record.Id,[string]$record.Hash,([string](Get-QaWebValue $record SourcePath '')).ToUpperInvariant(),[string]$ticks,[string]$record.ReportDate,[string]$record.ReportTime,[string]$Tokens[[string]$record.Id]) -join '|'))
    }
    return Get-QaWebHash ($parts -join "`n")
}
function Assert-QaWebMonthlySettings($Source,$Request){
    $values=@{}
    if(Test-QaWebHasProperty $Request expectedMonthly){$value=$Request.expectedMonthly;if($value -isnot [bool]){throw 'Monthly scheduling must be on or off.'};$values.ExpectedMonthly=$value}
    if(Test-QaWebHasProperty $Request monthlyDueDay){$value=$Request.monthlyDueDay;if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 31){throw 'Monthly due day must be an integer from 0 through 31.'};$values.MonthlyDueDay=[int]$value}
    $changed=$false
    if(Test-QaWebHasProperty $Request checklist){$value=$Request.checklist;if($value -isnot [array] -or $value.Count -gt 32 -or @($value|Where-Object{$_ -isnot [string]}).Count){throw 'The department checklist must be an array of at most 32 text labels.'};$values.MonthlyChecklist=[object[]]$value;$old=@(Get-QaWebValue $Source MonthlyChecklist @());$changed=(($old -join '|') -cne ($value -join '|'))}
    $effective='';if(Test-QaWebHasProperty $Request checklistEffectiveMonth){if($Request.checklistEffectiveMonth -isnot [string]){throw 'Checklist effective month must use yyyy-MM.'};$effective=[string]$Request.checklistEffectiveMonth;if($effective){[void](ConvertTo-QaMonthlyDate $effective);$values.ChecklistEffectiveMonth=$effective}}
    if($changed -and -not $effective){$setup=Get-QaMonthlySetup $Source;$effective=[string]$setup.nextChecklistEffectiveMonth;if(-not $effective){throw 'No later checklist effective month is available.'};$values.ChecklistEffectiveMonth=$effective}
    return $values
}
function Get-QaWebMonthlyWorkspace {
    [CmdletBinding()]param($Config,[string]$Month)
    [void](ConvertTo-QaMonthlyDate $Month)
    $records=@(Select-QaMonthlyCurrentRecords @(Get-QaWebAnalysisRecords $Config));$organization=Get-QaWebOrganization $Config;$entries=Get-QaWebEntryIndex $organization;$bindings=New-Object 'Collections.Generic.List[object]'
    $root=[IO.Path]::GetFullPath((Join-Path $Config.ArchiveRoot 'Reports')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    foreach($record in $records){
        $raw=[string]$record.ReportDate;if($raw -cmatch '^\d{4}-\d{2}-\d{2}$' -and -not $raw.StartsWith($Month+'-',[StringComparison]::Ordinal)){continue}
        $context=Get-QaWebContentContext $Config $record
        if(-not ([string]$context.effectiveDate).StartsWith($Month+'-',[StringComparison]::Ordinal)){continue}
        $entry=Get-QaWebIndexedEntry $entries $record;$filing=Get-QaWebClassification $record $entry $context;$available=$false
        if([string]$filing.category -ceq 'Monthly'){
            try{$path=[IO.Path]::GetFullPath([string]$record.DestinationPath);if($path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetExtension($path) -ieq '.pdf'){Assert-QaWebDirect $path;$info=New-Object IO.FileInfo($path);$available=($info.Exists -and $info.Length -eq [long]$record.Length)}}catch{$available=$false}
        }
        [void]$bindings.Add([pscustomobject]@{Record=$record;Context=$context;Filing=$filing;Available=$available})
    }
    return New-QaMonthlyWorkspace -Config $Config -Month $Month -Bindings @($bindings.ToArray()) -Records $records
}

function Get-QaWebAnalysisRecords {
    param($Config)
    # The archive owns core validation; cached views do not build dashboard
    # projections. PDF reading independently verifies membership and exact bytes.
    return @(Get-QaArchiveRecords -Config $Config)
}
function Get-QaWebAnalysisRevision {
    param($Config)
    $parts=New-Object 'Collections.Generic.List[string]'
    foreach($path in @((Join-Path $Config.ArchiveRoot '.ctqa/state.json'),(Join-Path $Config.ArchiveRoot '.ctqa/organization.json'),(Join-Path $Config.AppRoot 'Config/Settings.json'),(Join-Path $Config.AppRoot 'Config/Settings.local.json'))){
        Assert-QaWebDirect $path;$info=New-Object IO.FileInfo($path);$info.Refresh()
        [void]$parts.Add(([string]$info.Exists)+'|'+$(if($info.Exists){[string]$info.Length}else{'0'})+'|'+[string]$info.LastWriteTimeUtc.Ticks)
    }
    # This is only a queue invalidation hint. It never replaces PDF/hash validation.
    return Get-QaWebHash ($parts -join ';')
}
function Get-QaWebAnalysisPlan {
    param($Config,$Request,$Progress=$null)
    $scope=[string](Get-QaWebValue $Request scope 'all');if($scope -cnotin @('all','pending')){throw 'Choose pending reports or all saved reports.'}
    $upgrade=Get-QaWebValue $Request measurements $false;$refresh=Get-QaWebValue $Request refreshUnsupported $false
    if($upgrade -isnot [bool] -or $refresh -isnot [bool]){throw 'Reading options must be on or off.'}
    Set-QaWebProgress $Progress 'Planning' 0 0
    $records=@(Get-QaWebAnalysisRecords $Config)
    $hasIds=($Request -is [Collections.IDictionary] -and $Request.Contains('ids')) -or ($Request -isnot [Collections.IDictionary] -and $null -ne $Request.PSObject.Properties['ids'])
    $planArguments=@{Config=$Config;Records=$records;UpgradeMeasurements=[bool]$upgrade;RefreshUnsupported=[bool]$refresh;Limit=100000}
    if($hasIds){$ids=@(Get-QaWebValue $Request ids @());if($ids.Count -lt 1 -or $ids.Count -gt 20){throw 'Choose between one and twenty saved reports for a reading batch.'};$planArguments.RecordIds=[string[]]$ids}
    if($scope -ceq 'pending'){
        if($hasIds){throw 'Pending reading cannot be combined with another report selection.'}
        $organization=Get-QaWebOrganization $Config;$entries=Get-QaWebEntryIndex $organization
        $records=@($records|Where-Object{$content=Get-QaWebContentContext $Config $_;$entry=Get-QaWebIndexedEntry $entries $_;(Get-QaWebClassification $_ $entry $content).pending});$planArguments.Records=$records
    }
    $plan=Get-QaAnalysisWorkPlan @planArguments
    return [pscustomobject]@{plan=[pscustomobject]@{recordIds=@($plan.RecordIds);pending=[int]$plan.Pending;total=[int]$plan.Total;cached=[math]::Max(0,([int]$plan.Total-[int]$plan.Pending));revision=(Get-QaWebAnalysisRevision $Config)};snapshotDeferred=$true;cancelled=(Test-QaWebCancelled $Progress)}
}
function Invoke-QaWebRequest {
    [CmdletBinding()]param([string]$AppRoot,$Request,$Progress=$null)
    $AppRoot=[IO.Path]::GetFullPath($AppRoot);Assert-QaWebDirect $AppRoot;$action=[string](Get-QaWebValue $Request action '')
    # Monthly is a pure cached read, including on an uninitialized workspace.
    # It must not inherit bootstrap settings/folder writes or error snapshots.
    if($action -ceq 'Monthly'){[void](ConvertTo-QaMonthlyDate ([string](Get-QaWebValue $Request month '')));$config=Read-QaConfig $AppRoot;return Get-QaWebMonthlyWorkspace -Config $config -Month ([string]$Request.month)}
    [void](Initialize-QaWorkspace $AppRoot);$config=Read-QaConfig $AppRoot
    $allowed=@('Snapshot','Monthly','AnalysisPlan','Refresh','Approve','Disapprove','Undo','Reconnect','Settings','ApplyProfile','Export','Analyze','Backup','Diagnostics','Pdf','Browse','PickArchive','PrepareUpdate','InstallPreparedUpdate','Audit','ScannerSettings','Restore','PreviewPdf','Trends','PrintDiagnostics','SyncLibrary')
    if($action -cnotin $allowed){throw 'This application action is not supported.'}
    $value=$null;$message='';$warning='';$path='';$decision=$null;$snapshotDashboard=$null;$snapshotOrganization=$null;$cancelled=$false
    Set-QaWebProgress $Progress 'Preparing' 0 0
    if(Test-QaWebCancelled $Progress){return [pscustomobject]@{snapshot=(Get-QaWebSnapshot $config);cancelled=$true;message='Cancelled before any changes.';path=''}}
    switch($action){
        'Snapshot'{return Get-QaWebSnapshot $config}
        'AnalysisPlan'{return Get-QaWebAnalysisPlan -Config $config -Request $Request -Progress $Progress}
        'Trends'{
            $filters=@{};foreach($key in @('scanner','metric','mode','system','slice','start','end','series')){$text=[string](Get-QaWebValue $Request $key '');if($text.Length -gt 128){throw 'A measurement filter is too long.'};$filters[$key]=$text}
            if($filters.slice -and $filters.slice -cnotmatch '^(?:0|[1-9][0-9]{0,2})$'){throw 'Choose a valid measurement slice.'}
            $metric=if($filters.metric){$filters.metric}else{'WaterCTNumber'}
            return Get-QaTrendData -Config $config -Scanner $filters.scanner -Metric $metric -Mode $filters.mode -SourceSystem $filters.system -Slice $(if($filters.slice){[int]$filters.slice}else{0}) -StartDateISO $filters.start -EndDateISO $filters.end -SeriesKey $filters.series
        }
        'PreviewPdf'{return Get-QaPdfPreviewPage -Config $config -RecordId ([string](Get-QaWebValue $Request id '')) -PageNumber ([int](Get-QaWebValue $Request page 0))}
        'Pdf'{
            # Fresh core validation and exact PDF hashing remain mandatory. The
            # unrelated dashboard projections are unnecessary for this lookup.
            $saved=[pscustomobject]@{Records=@(Get-QaArchiveRecords -Config $config)}
            $record=Get-QaWebRecord $saved ([string](Get-QaWebValue $Request id ''))
            return [pscustomobject]@{path=(Assert-QaWebPdf $config $record);filename=[string]$record.OriginalFileName}
        }
        {$_ -in @('Approve','Disapprove','Undo')}{
            $decisionContext=$null;$decision=Invoke-QaWebOrganization -Config $config -Request $Request -Progress $Progress -OperationContext ([ref]$decisionContext)
            if($null -ne $decisionContext){$snapshotDashboard=$decisionContext.Dashboard;$snapshotOrganization=$decisionContext.Organization}
            if([bool](Get-QaWebValue $decision cancelled $false)){return [pscustomobject]@{snapshot=(Get-QaWebSnapshot -Config $config -Dashboard $snapshotDashboard -Organization $snapshotOrganization);cancelled=$true;message='Cancelled before saving the decision.';path=''}}
            $decisionCount=[int](Get-QaWebValue $decision count 0);$message=$(if($decisionCount){if($action -eq 'Undo'){'Grouped file decisions restored for '+$decisionCount+' reports.'}else{$action+' saved for '+$decisionCount+' reports. All original PDFs were kept.'}}elseif($action -eq 'Undo'){'Previous file classification restored.'}else{$action+' saved. The PDF was kept.'});$warning=$decision.warning
        }
        'Refresh'{
            Set-QaWebProgress $Progress 'Connecting' 0 @($config.Sources).Count
            $connectionNumber=0
            foreach($source in $config.Sources){if(Test-QaWebCancelled $Progress){break};$connectionNumber++;Set-QaWebProgress $Progress 'Connecting' $connectionNumber @($config.Sources).Count;if(Test-QaPlaceholderConnection $source){continue};$credential=$null;try{$credential=Get-QaSavedCredential -AppRoot $AppRoot -ScannerId $source.Scanner -ExpectedUsername $source.Username -ExpectedPath $source.Path}catch{};if($null -ne $credential){[void](Reconnect-QaScanner $source $credential)}}
            if(Test-QaWebCancelled $Progress){return [pscustomobject]@{snapshot=(Get-QaWebSnapshot $config);cancelled=$true;message='Connection checks cancelled. Saved reports are unchanged.';path=''}}
            $dashboard=Get-QaDashboard $config
            Set-QaWebProgress $Progress 'Scanning' 0 0
            if($dashboard.SetupComplete){$operation=Invoke-QaOperation $config -Mode Update -Progress $Progress}else{
                $preview=Invoke-QaOperation $config -Mode Preview -Progress $Progress
                if([bool]$preview.Summary.Cancelled -or (Test-QaWebCancelled $Progress)){return [pscustomobject]@{snapshot=(Get-QaWebSnapshot $config);cancelled=$true;message='Scanning cancelled. Setup has not been changed.';path=''}}
                $accessible=@($preview.Scanners|Where-Object{$_.Status -in @('Connected','Issues','Partial')})
                if(-not $accessible.Count){
                    Write-QaWebAtomic (Join-Path $config.ArchiveRoot '.ctqa/web-connections.json') ([pscustomobject]@{Version=1;Connections=@($preview.Scanners)})
                    return [pscustomobject]@{snapshot=(Get-QaWebSnapshot $config);message='No scanner reports folder is accessible yet. Open Settings and test the scanner connections.';warning='Setup has not been completed. Existing archive records were not changed.';decision=$null;result=$null;path=''}
                }
                $operation=Invoke-QaOperation $config -Mode Import -Plan $preview.Plan -Progress $Progress
            }
            Write-QaWebAtomic (Join-Path $config.ArchiveRoot '.ctqa/web-connections.json') ([pscustomobject]@{Version=1;Connections=@($operation.Scanners)})
            $snapshotDashboard=$operation;$message=$operation.Summary.Description;$cancelled=([bool]$operation.Summary.Cancelled -or (Test-QaWebCancelled $Progress))
            if(-not $cancelled){try{$library=Update-QaWebLibrary -Config $config -Dashboard $operation -Progress $Progress;$value=[pscustomobject]@{library=$library};$cancelled=[bool]$library.cancelled}catch{$warning=$_.Exception.Message}}
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
            if($null -ne (Get-QaWebValue $Request theme)){if([string]$Request.theme -cnotin @('Light','Dark')){throw 'Choose Light or Dark appearance.'};$config|Add-Member Theme ([string]$Request.theme) -Force}
            if($null -ne (Get-QaWebValue $Request pdfReaderMode)){if([string]$Request.pdfReaderMode -cnotin @('Auto','Python','Standard')){throw 'Choose Automatic, Portable Python, or Standard reader.'};$config|Add-Member PdfReaderMode ([string]$Request.pdfReaderMode) -Force}
            if($null -ne (Get-QaWebValue $Request monitorMinutes)){$config|Add-Member MonitorMinutes ([int]$Request.monitorMinutes) -Force};if($null -ne (Get-QaWebValue $Request autoUpdateOnOpen)){if($Request.autoUpdateOnOpen -isnot [bool]){throw 'Update on opening must be on or off.'};$config|Add-Member AutoUpdateOnOpen $Request.autoUpdateOnOpen -Force};if($null -ne (Get-QaWebValue $Request autoAnalyze)){if($Request.autoAnalyze -isnot [bool]){throw 'Automatic reading must be on or off.'};$config|Add-Member AutoAnalyze $Request.autoAnalyze -Force}
            [void](Save-QaConfig $AppRoot $config);$message='Settings saved. Existing report folders were not moved or deleted.'
        }
        'ScannerSettings'{
            $id=[string](Get-QaWebValue $Request scanner '');$matches=@($config.Sources|Where-Object Scanner -ceq $id);if($matches.Count -ne 1){throw 'Choose an existing scanner before editing settings.'};$source=$matches[0]
            $monthlyValues=Assert-QaWebMonthlySettings $source $Request
            foreach($key in $monthlyValues.Keys){$source|Add-Member -NotePropertyName $key -NotePropertyValue $monthlyValues[$key] -Force}
            foreach($pair in @(@('name','Name'),@('path','Path'),@('drive','DriveLetter'),@('username','Username'),@('dailySchedule','DailySchedule'),@('activeFrom','ActiveFrom'),@('excludedDates','ExcludedDates'))){
                $incoming=Get-QaWebValue $Request $pair[0];if($null -ne $incoming){if($pair[0] -eq 'expectedMonthly' -and $incoming -isnot [bool]){throw 'Monthly scheduling must be on or off.'};$source|Add-Member -NotePropertyName $pair[1] -NotePropertyValue $incoming -Force}
            }
            if(($Request -is [Collections.IDictionary] -and $Request.Contains('contentProfiles')) -or ($Request -isnot [Collections.IDictionary] -and $null -ne $Request.PSObject.Properties['contentProfiles'])){$source|Add-Member -NotePropertyName ContentProfiles -NotePropertyValue ([object[]]@(ConvertTo-QaWebContentProfiles $Request.contentProfiles)) -Force}
            [void](Save-QaConfig $AppRoot $config);$message='Scanner settings saved. Existing archive records and prior checklist versions were preserved.'
        }
        'ApplyProfile'{
            $profile=Get-QaWebValue $Request profile;if($profile -is [string]){$profile=$profile|ConvertFrom-Json};if($null -eq $profile){throw 'Choose a scanner connection profile.'}
            foreach($item in @($profile)+@($profile.Connections)){foreach($property in $item.PSObject.Properties){if($property.Name -match '(?i)password|secret|credential'){throw 'Connection profiles cannot contain passwords. Use the secure scanner sign-in field.'}}}
            $temp=Join-Path $AppRoot ('Data/.profile-'+[guid]::NewGuid().ToString('N')+'.json');Assert-QaWebDirect $temp
            try{[IO.File]::WriteAllText($temp,($profile|ConvertTo-Json -Depth 15),(New-Object Text.UTF8Encoding $true));$applied=Set-QaConnectionProfile -AppRoot $AppRoot -ProfilePath $temp -ReplaceExisting;$message=$applied.Message}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}};$config=Read-QaConfig $AppRoot
        }
        'Export'{$path=New-QaWebExport $config ([string[]]@(Get-QaWebValue $Request ids @())) $Progress;$cancelled=(-not $path -and (Test-QaWebCancelled $Progress));$message='Report package is ready to download.'}
        'Analyze'{
            $ids=@();$selectedRecord=$null;$selected=[string](Get-QaWebValue $Request id '');$scopeIds=Get-QaWebValue $Request ids $null
            $analysisStep=Get-QaWebValue $Request analysisStep $false;$deferSnapshot=Get-QaWebValue $Request deferSnapshot $false;$deferLibrary=Get-QaWebValue $Request deferLibrary $false
            if($analysisStep -isnot [bool] -or $deferSnapshot -isnot [bool] -or $deferLibrary -isnot [bool]){throw 'Background reading controls must be on or off.'}
            $stepRecords=$null
            if($null -ne (Get-QaWebValue $Request backlog) -and (Get-QaWebValue $Request backlog) -isnot [bool]){throw 'Automatic reading must be on or off.'};$backlog=[bool](Get-QaWebValue $Request backlog $false);$backlogScope=[string](Get-QaWebValue $Request scope 'all');if($backlogScope -cnotin @('all','pending')){throw 'Choose pending reports or all saved reports.'}
            $hasScopeIds=($Request -is [Collections.IDictionary] -and $Request.Contains('ids')) -or ($Request -isnot [Collections.IDictionary] -and $null -ne $Request.PSObject.Properties['ids'])
            $analysisLimit=20;$requestedLimit=Get-QaWebValue $Request analysisLimit $null
            if($null -ne $requestedLimit){if(($requestedLimit -isnot [int] -and $requestedLimit -isnot [long]) -or $requestedLimit -lt 1 -or $requestedLimit -gt 20){throw 'Read between one and twenty PDFs per batch.'};$analysisLimit=[int]$requestedLimit}
            if($selected -and $hasScopeIds){throw 'Choose one report or a bounded report group.'}
            if($selected){$selectedRecord=Get-QaWebRecord (Get-QaDashboard $config) $selected;$ids=@($selected)}
            elseif($hasScopeIds){$ids=@($scopeIds);if($ids.Count -lt 1 -or $ids.Count -gt 20){throw 'Choose between one and twenty saved reports for a reading batch.'};foreach($id in $ids){if($id -isnot [string] -or $id -notmatch '^[0-9A-Fa-f]{64}$'){throw 'Invalid saved report group.'}}}
            if($analysisStep){if($selected -or $analysisLimit -ne 1 -or -not $hasScopeIds -or $ids.Count -ne 1 -or $backlog){throw 'A background checkpoint must select exactly one saved report.'};$stepRecords=@(Get-QaWebAnalysisRecords $config)}elseif($deferSnapshot -or $deferLibrary){throw 'Deferred reading is restricted to a one-report background checkpoint.'}
            if($backlog -and $backlogScope -ceq 'pending'){
                if($selected -or $hasScopeIds){throw 'Automatic pending reading cannot be combined with another report selection.'}
                $pendingDashboard=Get-QaDashboard $config;$pendingOrg=Get-QaWebOrganization $config;$pendingIndex=Get-QaWebEntryIndex $pendingOrg
                $ids=@($pendingDashboard.Records|Where-Object{$c=Get-QaWebContentContext $config $_;$e=Get-QaWebIndexedEntry $pendingIndex $_;(Get-QaWebClassification $_ $e $c).pending}|ForEach-Object{[string]$_.Id})
            }
            if($null -ne (Get-QaWebValue $Request refreshUnsupported) -and (Get-QaWebValue $Request refreshUnsupported) -isnot [bool]){throw 'Format refresh must be on or off.'};$refreshUnsupported=[bool](Get-QaWebValue $Request refreshUnsupported $false)
            if($null -ne (Get-QaWebValue $Request measurements) -and (Get-QaWebValue $Request measurements) -isnot [bool]){throw 'Measurement reading must be on or off.'};$upgradeMeasurements=[bool](Get-QaWebValue $Request measurements $false)

            if($null -ne (Get-QaWebValue $Request force) -and (Get-QaWebValue $Request force) -isnot [bool]){throw 'Retry must be on or off.'};$force=[bool](Get-QaWebValue $Request force $false);if($force -and -not $selected){throw 'Choose one PDF before retrying a read.'};if($selected -and (Test-QaAnalysisSelectedRefresh $config $selectedRecord)){$force=$true};Set-QaWebProgress $Progress 'Analyzing' 0 0;if($analysisStep){$analysis=Invoke-QaAnalysis -Config $config -Records $stepRecords -Limit 1 -RecordIds $ids -UpgradeMeasurements:$upgradeMeasurements -RefreshUnsupported:$refreshUnsupported -Progress $Progress}elseif($backlog -and $backlogScope -ceq 'pending' -and -not $ids.Count){$analysis=[pscustomobject]@{Analyzed=0;Cached=0;Failed=0;Pending=0;AnalyzedIds=@();Summary=[pscustomobject]@{Cancelled=$false}}}elseif($ids.Count){$analysis=Invoke-QaAnalysis $config -Limit $(if($selected){1}else{$analysisLimit}) -RecordIds $ids -Force:$force -UpgradeMeasurements:$upgradeMeasurements -RefreshUnsupported:$refreshUnsupported -Progress $Progress}else{$analysis=Invoke-QaAnalysis $config -Limit $analysisLimit -UpgradeMeasurements:$upgradeMeasurements -RefreshUnsupported:$refreshUnsupported -Progress $Progress};$cancelled=[bool]$analysis.Summary.Cancelled
            $message=([string]$analysis.Analyzed+' PDFs analyzed; '+[string]$analysis.Cached+' cached; '+[string]$analysis.Failed+' need attention.');$value=$analysis
            if(-not $cancelled -and -not $deferLibrary){$changed=@(Get-QaWebValue $analysis AnalyzedIds @());if($selected){$changed=@($selected)};if($changed.Count){try{[void](Update-QaWebLibrary -Config $config -OnlyRecords $changed -Progress $Progress)}catch{$warning='Contents were read. Readable folders need refresh: '+$_.Exception.Message}}}
            if($deferSnapshot){return [pscustomobject]@{snapshotDeferred=$true;libraryDeferred=[bool]$deferLibrary;analysisRevision=(Get-QaWebAnalysisRevision $config);result=$analysis;cancelled=$cancelled;message=$message;warning=$warning}}
        }
        'Backup'{
            $path=New-QaWebArtifactPath $AppRoot 'Backups' 'CTQA-Full-Backup';$archivePrefix=[IO.Path]::GetFullPath($config.ArchiveRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar;$external=$false
            if($path.StartsWith($archivePrefix,[StringComparison]::OrdinalIgnoreCase)){
                if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Choose a backup destination outside the live archive using the Windows maintenance interface.'}
                Add-Type -AssemblyName System.Windows.Forms;$picker=New-Object Windows.Forms.SaveFileDialog;$picker.Filter='CT QA backup (*.zip)|*.zip';$picker.Title='Save a NEW backup outside your live archive';$picker.FileName=[IO.Path]::GetFileName($path)
                try{if($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return [pscustomobject]@{cancelled=$true;message='Backup cancelled. No existing files changed.'}};$path=$picker.FileName;$external=$true}finally{$picker.Dispose()}
            }
            Set-QaWebProgress $Progress 'BackingUp' 0 0
            $backup=New-QaBackup -AppRoot $AppRoot -Config $config -DestinationPath $path -Progress $Progress;$message='Verified backup is ready to download.'
            if($external){$message='Verified backup saved to: '+$path;$value=[pscustomobject]@{savedTo=$path};$path=''}
        }
        'Restore'{
            if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Interactive restore requires Windows. Use the native maintenance helper on the work computer.'}
            Add-Type -AssemblyName System.Windows.Forms;$picker=New-Object Windows.Forms.OpenFileDialog;$picker.Filter='CT QA backup (*.zip)|*.zip';$picker.Title='Choose the verified CT QA backup to restore'
            try{if($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return [pscustomobject]@{cancelled=$true;message='Restore cancelled. No files changed.'}};$backupPath=$picker.FileName}finally{$picker.Dispose()}
            $folder=New-Object Windows.Forms.FolderBrowserDialog;$folder.Description='Choose the PARENT folder. A new restored workspace will be created without replacing existing files.'
            try{if($folder.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return [pscustomobject]@{cancelled=$true;message='Restore cancelled. No files changed.'}};$destination=Join-Path $folder.SelectedPath ('CTQA-Restored-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))}finally{$folder.Dispose()}
            Set-QaWebProgress $Progress 'Restoring' 0 0;$restored=Restore-QaBackup -Path $backupPath -DestinationFolder $destination -Progress $Progress;$message=$restored.Summary.Description+' Restored folder: '+$destination;$value=[pscustomobject]@{restoredTo=$destination}
        }
        {$_ -in @('Diagnostics','PrintDiagnostics')}{
            $supportDashboard=Get-QaDashboard $config;$context=Get-QaWebSupportContext $config $supportDashboard @(Get-QaWebValue $Request supportWork @())
            $extension=if($action -ceq 'PrintDiagnostics'){'.html'}else{'.zip'};$path=New-QaWebArtifactPath $AppRoot 'Logs/Support' 'CTQA-Support' $extension
            if($action -ceq 'PrintDiagnostics'){[void](Export-QaSupportHtml -AppRoot $AppRoot -Config $config -Dashboard $supportDashboard -DestinationPath $path -ConnectionResults @(Get-QaWebConnectionRows $config) -SupportContext $context -CurrentOperation $action);$message='Printable diagnostic report ready. Open it and use Ctrl+P to print or save as PDF.'}
            else{[void](Export-QaSupportBundle -AppRoot $AppRoot -Config $config -Dashboard $supportDashboard -DestinationPath $path -ConnectionResults @(Get-QaWebConnectionRows $config) -SupportContext $context -CurrentOperation $action);$message='Detailed diagnostic ZIP ready, including a printable report, reading reasons and retained activity. No PDF contents or passwords are included.'}
            Set-QaWebProgress $Progress 'Finishing' 0 0;return [pscustomobject]@{path=$path;message=$message;warning='';cancelled=$false}
        }
        'Audit'{Set-QaWebProgress $Progress 'Verifying' 0 0;$result=Invoke-QaOperation $config -Mode Audit -Progress $Progress;$snapshotDashboard=$result;$cancelled=([bool]$result.Summary.Cancelled -or (Test-QaWebCancelled $Progress));$message=$result.Summary.Description;if(-not $cancelled){$library=Update-QaWebLibrary -Config $config -Dashboard $result -Progress $Progress -Verify;$value=[pscustomobject]@{library=$library};$cancelled=[bool]$library.cancelled}}
        'SyncLibrary'{
            $hasSyncIds=($Request -is [Collections.IDictionary] -and $Request.Contains('ids')) -or ($Request -isnot [Collections.IDictionary] -and $null -ne $Request.PSObject.Properties['ids']);$syncIds=@(Get-QaWebValue $Request ids @());$fullSync=Get-QaWebValue $Request fullSync (-not $hasSyncIds);if($fullSync -isnot [bool]){throw 'Folder synchronization must be on or off.'}
            if($syncIds.Count -gt 100000){throw 'The folder checkpoint is too large.'};foreach($syncId in $syncIds){if($syncId -isnot [string] -or $syncId -cnotmatch '^[0-9A-Fa-f]{64}$'){throw 'Choose valid saved reports for folder synchronization.'}}
            $snapshotDashboard=Get-QaDashboard $config;$snapshotOrganization=Get-QaWebOrganization $config
            if($fullSync -or $syncIds.Count){$library=Update-QaWebLibrary -Config $config -OnlyRecords $(if($fullSync){@()}else{$syncIds}) -Dashboard $snapshotDashboard -Organization $snapshotOrganization -Progress $Progress;$cancelled=[bool]$library.cancelled;$value=[pscustomobject]@{library=$library}}else{$value=[pscustomobject]@{library=[pscustomobject]@{copied=0;unchanged=0;manifestWrites=0;hashedFiles=0;cancelled=$false}}}
            Set-QaWebProgress $Progress 'Snapshot' 0 0
            return [pscustomobject]@{snapshot=(Get-QaWebSnapshot -Config $config -Dashboard $snapshotDashboard -Organization $snapshotOrganization);result=$value;message='Readable folders and the saved overview were refreshed.';cancelled=$cancelled}
        }
        'Browse'{
            $folder=Join-Path $config.ArchiveRoot 'Report Library';Assert-QaWebDirect $folder
            # Import, reading and file decisions maintain these saved copies.
            # Opening an existing folder does not need another archive-wide pass.
            if([IO.Directory]::Exists($folder)){
                if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){Start-Process -FilePath explorer.exe -ArgumentList ('"'+$folder+'"')|Out-Null}
                Set-QaWebProgress $Progress 'Finishing' 0 0
                return [pscustomobject]@{snapshotDeferred=$true;message='Readable report folders opened.';warning='';result=[pscustomobject]@{libraryRoot=$folder;library=$null};path='';cancelled=$false}
            }
            $library=Update-QaWebLibrary -Config $config -Progress $Progress;$cancelled=[bool]$library.cancelled
            if(-not $cancelled -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){Start-Process -FilePath explorer.exe -ArgumentList ('"'+$folder+'"')|Out-Null}
            $message='Readable report folders opened.';$value=[pscustomobject]@{libraryRoot=$folder;library=$library}
        }
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
    Set-QaWebProgress $Progress 'Finishing' 0 0
    $snapshot=Get-QaWebSnapshot -Config $config -Dashboard $snapshotDashboard -Organization $snapshotOrganization
    if($cancelled){$message='Cancelled safely. Completed report copies and decisions remain saved; run Update reports to continue.'}
    return [pscustomobject]@{snapshot=$snapshot;message=$message;warning=$warning;decision=$decision;result=$value;path=$path;cancelled=$cancelled}
}
Export-ModuleMember -Function Invoke-QaWebRequest,Get-QaWebSnapshot
