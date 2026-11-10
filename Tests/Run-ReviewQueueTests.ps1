[CmdletBinding()]param([string]$OutputPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProductRoot 'App/Archive.psm1') -Force
Import-Module (Join-Path $ProductRoot 'App/Review.psm1') -Force
Import-Module (Join-Path $ProductRoot 'App/Process.psm1') -Force
$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_ReviewQueue_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($TestRoot)
$script:Results=New-Object 'System.Collections.Generic.List[object]';$script:Assertions=0;$script:NativePreviewActuallyRun=$false
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS '+$Name)}catch{[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=($_.Exception.Message+' '+$_.ScriptStackTrace)});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Run-Tests.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('New-TestConfig','New-TestPdf','Add-Report','Import-Fixture')){$definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);. ([scriptblock]::Create($definition.Extent.Text))}
function New-QueueFixture([string]$Name){
    $cfg=New-TestConfig $Name;foreach($source in $cfg.Sources){$source.DailySchedule='Off';$source.ExpectedMonthly=$false}
    $cfg.Sources[0].ExpectedMonthly=$true;$cfg.Sources[0]|Add-Member MonthlyChecklist @('MTF','Slice thickness') -Force
    $path=Add-Report $cfg 'CT_Edge' 'Monthly_Constancy' (Get-Date).ToString('yyyy-MM-dd') '08-00-00' 95000
    [void](Import-Fixture $cfg);$record=@((Get-QaDashboard $cfg).Records)[0]
    return [pscustomobject]@{Config=$cfg;Record=$record;SourcePath=$path;SourceHash=(Get-FileHash $path).Hash}
}
function Decide($Fixture,[string]$Action='Accept',[string]$Category='Monthly_QA',[string[]]$Components=@()){
    $record=@((Get-QaDashboard $Fixture.Config).Records|Where-Object Id -eq $Fixture.Record.Id)[0]
    $decision=New-QaQuickReviewDecision -Record $record -Action $Action -Category $Category -Reviewer 'Synthetic reviewer' -Viewed $true -Authorized $true -Components $Components
    [void](Invoke-QaOperation -Config $Fixture.Config -Mode Reclassify -Decisions @($decision))
    return @((Get-QaDashboard $Fixture.Config).Records|Where-Object Id -eq $Fixture.Record.Id)[0]
}
Scenario 'The production dispatcher handler preserves event arguments and reports the original error' {
    $startAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $ProductRoot 'App/Start.ps1'),[ref]$null,[ref]$null)
    $call=$startAst.Find({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_UnhandledException'},$true)
    $body=$call.Arguments[0].ScriptBlock.Extent.Text;$handler=[scriptblock]::Create($body.Substring(1,$body.Length-2))
    $script:OriginalEventMessage='';function Show-Note {param($Text,$Title,$IsError) $script:OriginalEventMessage=$Text}
    $event=[pscustomobject]@{Handled=$false;Exception=(New-Object InvalidOperationException 'Synthetic action error')}
    & $handler $null $event
    Check $event.Handled 'The supplied event, not the automatic arguments array, is marked handled'
    Check ($script:OriginalEventMessage -eq 'Synthetic action error') 'The original error survives the handler rather than becoming a missing Handled-property failure'
}
Scenario 'Quick decisions require PDF review, reviewer identity and authorization' {
    $f=New-QueueFixture 'Authorization'
    foreach($case in @(@{Viewed=$false;Authorized=$true;Reviewer='Synthetic'},@{Viewed=$true;Authorized=$false;Reviewer='Synthetic'},@{Viewed=$true;Authorized=$true;Reviewer=''})){
        $caught=$false;try{New-QaQuickReviewDecision -Record $f.Record -Action Accept -Category Monthly_QA @case|Out-Null}catch{$caught=$true};Check $caught 'Missing review attestation rejected'
    }
    Check (Test-QaReportPending $f.Record) 'Report stays pending'
}
Scenario 'Accept removes a candidate from pending and records only selected checklist evidence' {
    $f=New-QueueFixture 'Accept';$record=Decide $f -Components @('MTF')
    Check (-not (Test-QaReportPending $record) -and (Get-QaReportReviewStatus $record) -eq 'Accepted') 'Accepted report clears pending'
    Check ($record.Category -eq 'Monthly_QA' -and $record.ConfirmedBy -eq 'Synthetic reviewer') 'Actual confirmed type and reviewer saved'
    $coverage=@(Get-QaMonthlyCoverage $f.Config -Records @($record) -Months @((Get-Date).ToString('yyyy-MM'))|Where-Object Scanner -eq 'CT_Edge')[0]
    Check ($coverage.Status -eq 'Partial' -and $coverage.MissingComponents -contains 'Slice thickness') 'Accepting a label does not invent complete QA evidence'
    Check ((Get-FileHash $f.SourcePath).Hash -eq $f.SourceHash) 'Scanner original unchanged'
    Check ([IO.File]::Exists($record.DestinationPath) -and $record.LastReviewId) 'Saved PDF and audit decision preserved'
}
Scenario 'Decline clears the Monthly suggestion while preserving a reviewed other PDF' {
    $f=New-QueueFixture 'Decline';$record=Decide $f -Action Decline -Category Needs_Review
    Check ((Get-QaReportReviewStatus $record) -eq 'Declined' -and -not (Test-QaReportPending $record)) 'Declined suggestion clears pending'
    Check ($record.Category -eq 'Needs_Review' -and [IO.File]::Exists($record.DestinationPath)) 'Other report is preserved'
    Check (@((Get-QaDashboard $f.Config).Attention|Where-Object{$_.RecordId -eq $record.Id -and $_.Type -in @('Classification','MonthlyReview')}).Count -eq 0) 'Resolved classification does not reappear as a review finding'
    $coverage=@(Get-QaMonthlyCoverage $f.Config -Records @($record) -Months @((Get-Date).ToString('yyyy-MM'))|Where-Object Scanner -eq 'CT_Edge')[0]
    Check ($coverage.ConfirmedReportCount -eq 0) 'Decline cannot count as Monthly QA'
    Check ((Get-FileHash $f.SourcePath).Hash -eq $f.SourceHash) 'Scanner original retained unchanged'
}
Scenario 'Decline can identify a Daily report without accepting it as Monthly' {
    $f=New-QueueFixture 'DeclineAsDaily';$record=Decide $f -Action Decline -Category Daily_QA
    Check ($record.Category -eq 'Daily_QA' -and $record.ReviewDecision -eq 'Declined') 'Correct Daily type and rejected suggestion retained'
    Check (-not (Test-QaReportPending $record)) 'Corrected type clears pending'
    $caught=$false;$fresh=New-QueueFixture 'InvalidDecline'
    try{[void](Decide $fresh -Action Decline -Category Monthly_QA)}catch{$caught=$true};Check $caught 'Decline cannot confirm Monthly'
}
Scenario 'Undo restores the previous pending state and keeps both audit entries' {
    $f=New-QueueFixture 'UndoAccept';$before=$f.Record;$record=Decide $f -Components @('MTF','Slice thickness')
    $undo=New-QaUndoReviewDecision -Record $record -ReviewId $record.LastReviewId -Reviewer 'Synthetic reviewer'
    [void](Invoke-QaOperation $f.Config -Mode Reclassify -Decisions @($undo));$after=@((Get-QaDashboard $f.Config).Records)[0]
    Check (Test-QaReportPending $after) 'Undo puts report back in pending'
    Check ($after.Category -eq $before.Category -and [string]$after.ConfirmedBy -eq [string]$before.ConfirmedBy -and $after.ClassificationBasis -eq $before.ClassificationBasis) 'Original classification and review fields restored'
    Check (@($after.ConfirmedComponents).Count -eq 0) 'No old checklist acceptance remains'
    $state=Get-Content (Join-Path $f.Config.ArchiveRoot '.ctqa/state.json') -Raw|ConvertFrom-Json
    Check ($state.Reviews.Count -eq 2 -and $state.Reviews[-1].ReviewAction -eq 'Undo') 'Undo adds history rather than deleting the earlier decision'
    Check ([IO.File]::Exists($after.DestinationPath) -and (Get-FileHash $f.SourcePath).Hash -eq $f.SourceHash) 'PDF bytes remain preserved'
}
Scenario 'Undo also restores a declined candidate and rejects an unrelated old decision' {
    $f=New-QueueFixture 'UndoDecline';$record=Decide $f -Action Decline -Category Needs_Review
    $wrong=New-QaUndoReviewDecision $record ('0'*32) 'Synthetic reviewer';$caught=$false;try{Invoke-QaOperation $f.Config -Mode Reclassify -Decisions @($wrong)|Out-Null}catch{$caught=$true};Check $caught 'Wrong undo target rejected'
    $undo=New-QaUndoReviewDecision $record $record.LastReviewId 'Synthetic reviewer';[void](Invoke-QaOperation $f.Config -Mode Reclassify -Decisions @($undo))
    Check (Test-QaReportPending @((Get-QaDashboard $f.Config).Records)[0]) 'Decline undo restores pending'
}
Scenario 'A stale decision cannot overwrite another review of the same PDF' {
    $f=New-QueueFixture 'Stale'
    $old=New-QaQuickReviewDecision $f.Record Accept Monthly_QA 'Synthetic reviewer' $true $true
    [void](Decide $f -Action Decline -Category Needs_Review)
    $statePath=Join-Path $f.Config.ArchiveRoot '.ctqa/state.json';$before=(Get-FileHash $statePath).Hash
    $caught=$false;try{Invoke-QaOperation $f.Config -Mode Reclassify -Decisions @($old)|Out-Null}catch{$caught=$true};Check $caught 'Stale action rejected'
    Check ((Get-FileHash $statePath).Hash -eq $before) 'Rejected action leaves the index unchanged'
}
Scenario 'A changed saved PDF cannot be accepted or silently reclassified' {
    $f=New-QueueFixture 'ChangedPdf';[IO.File]::AppendAllText($f.Record.DestinationPath,'changed')
    $caught=$false;try{Decide $f|Out-Null}catch{$caught=$true};Check $caught 'Changed PDF rejected'
    Check (Test-QaReportPending @((Get-QaDashboard $f.Config).Records)[0]) 'Decision stays pending after failure'
}
Scenario 'A normal scanner update preserves the declined decision for unchanged source bytes' {
    $f=New-QueueFixture 'PersistentDecline';$record=Decide $f -Action Decline -Category Needs_Review
    [void](Invoke-QaOperation $f.Config -Mode Update);$after=@((Get-QaDashboard $f.Config).Records)[0]
    Check ($after.Id -eq $record.Id -and (Get-QaReportReviewStatus $after) -eq 'Declined') 'Unchanged report is not added back to pending'
    Check ((Get-FileHash $f.SourcePath).Hash -eq $f.SourceHash) 'Source PDF unchanged'
}

Scenario 'Declined PDFs export and browse as reviewed reports instead of unresolved suggestions' {
    Import-Module (Join-Path $ProductRoot 'App/Reports.psm1') -Force
    Import-Module (Join-Path $ProductRoot 'App/Browse.psm1') -Force
    $f=New-QueueFixture 'ReviewedExport';$record=Decide $f -Action Decline -Category Needs_Review
    $browse=Invoke-QaBrowseRefresh -Config $f.Config
    Check ($browse.Summary.Failed -eq 0) 'Readable copy refresh succeeds'
    $browseRoot=Join-Path $f.Config.ArchiveRoot 'Browse Reports'
    $copied=@(Get-ChildItem $browseRoot -Filter '*.pdf' -Recurse|Where-Object{$_.FullName -match 'Other Reports[\\/]Reviewed'})
    Check ($copied.Count -eq 1 -and (Get-FileHash $copied[0].FullName).Hash -eq $record.Hash) 'Declined-other PDF uses Reviewed folder and retains identical bytes'
    Check ((Get-QaReportTitle $record) -like '*Other report - reviewed') 'Display title no longer asks to review resolved item'
    $html=[IO.File]::ReadAllText((Join-Path $browseRoot 'Open Reports.html'))
    Check ($html -like '*Other report / reviewed*') 'Offline library reflects completed review'
    $zip=Join-Path $TestRoot 'Reviewed-export.zip'
    $export=Invoke-QaExport -Config $f.Config -RecordIds @($record.Id) -DestinationPath $zip
    Check ($export.Summary.Failed -eq 0 -and [IO.File]::Exists($zip)) 'Report remains exportable after decline'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($zip)
    try{Check (@($archive.Entries|Where-Object{$_.FullName -match 'Other Reports/Reviewed/.*\.pdf$'}).Count -eq 1) 'Export folder clearly says Reviewed'}finally{$archive.Dispose()}
}
Scenario 'Undo invalidates old pending actions even when the category returns to its original value' {
    $f=New-QueueFixture 'StaleAfterUndo';$old=New-QaQuickReviewDecision $f.Record Accept Monthly_QA 'Synthetic reviewer' $true $true
    $record=Decide $f
    $undo=New-QaUndoReviewDecision $record $record.LastReviewId 'Synthetic reviewer'
    [void](Invoke-QaOperation $f.Config -Mode Reclassify -Decisions @($undo))
    $caught=$false;try{Invoke-QaOperation $f.Config -Mode Reclassify -Decisions @($old)|Out-Null}catch{$caught=$true}
    Check $caught 'An old button action cannot overwrite newer audited actions'
    $dashboard=Get-QaDashboard $f.Config
    Check ($dashboard.Reviews.Count -eq 2 -and (Test-QaReportPending $dashboard.Records[0])) 'History survives a fresh reload and stale action leaves pending state intact'
}

if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
    Scenario 'The Windows PDF renderer produces an in-memory page without installing components' {
        $f=New-QueueFixture 'NativePreview'
        $page=Invoke-QaIsolatedTask -Action PreviewPdf -InputObject ([pscustomobject]@{Config=$f.Config;RecordId=$f.Record.Id;PageNumber=0}) -TimeoutSeconds 30
        $bytes=[Convert]::FromBase64String($page.PngBase64)
        Check ($page.PageCount -eq 1 -and $page.PageNumber -eq 0) 'Native page count and selected page returned'
        Check ($bytes.Length -gt 100 -and [BitConverter]::ToString($bytes,0,8) -eq '89-50-4E-47-0D-0A-1A-0A') 'Actual PNG returned'
        Check ($page.Hash -eq $f.Record.Hash) 'Preview bound to the saved PDF fingerprint'
        if($OutputPath){[IO.File]::WriteAllBytes((Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))) 'synthetic-pdf-preview.png'),$bytes)}
        $script:NativePreviewActuallyRun=$true
    }
    Scenario 'Native workspace clicks persist Accept, Undo, Decline and Skip with immediate queue updates' {
        $f=New-QueueFixture 'NativeWorkspace';$configPath=Join-Path $TestRoot 'workspace-config.xml';$uiResult=Join-Path $TestRoot 'workspace-result.json'
        $f.Config|Export-Clixml -LiteralPath $configPath -Depth 18 -Encoding UTF8
        & (Get-Process -Id $PID).Path -NoProfile -STA -File (Join-Path $PSScriptRoot 'Test-ReviewWorkspace.ps1') -ConfigPath $configPath -OutputPath $uiResult
        $exit=$LASTEXITCODE;Check ([IO.File]::Exists($uiResult)) 'Native click test produces a result'
        $result=Get-Content $uiResult -Raw|ConvertFrom-Json
        Check ($exit -eq 0) ('Native click test process completes: '+$result.Error)
        Check $result.Passed ('Real review workspace actions: '+$result.Error)
        $script:Assertions+=[int]$result.Assertions
    }

}
$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{Version='4.4.1';Runtime=$PSVersionTable.PSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5);NativePdfPreviewActuallyRun=$script:NativePreviewActuallyRun;Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Scope='Synthetic saved PDFs: accept, decline, exact undo snapshots, stale decisions, source preservation, unchanged rescans and native Windows PDF page rendering.'}
if($OutputPath){$report|ConvertTo-Json -Depth 12|Set-Content $OutputPath -Encoding UTF8}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
Remove-Item $TestRoot -Recurse -Force
if($failed){exit 1}
