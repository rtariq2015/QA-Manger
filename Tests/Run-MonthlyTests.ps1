# Synthetic Monthly QA evidence tests. Windows PowerShell 5.1; no Pester.
[CmdletBinding()]
param([string]$OutputPath='', [switch]$KeepFixtures)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProductRoot 'App/Archive.psm1') -Force
Import-Module (Join-Path $ProductRoot 'App/Monthly.psm1') -DisableNameChecking
$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_MonthlySynthetic_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestRoot)
$script:Results=New-Object 'System.Collections.Generic.List[object]';$script:Assertions=0
function Assert-True([bool]$Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw ('Assertion failed: '+$Message)}}
function Assert-Equal($Expected,$Actual,[string]$Message){Assert-True ([string]$Expected -ceq [string]$Actual) ($Message+'; expected='+[string]$Expected+'; actual='+[string]$Actual)}
function Run-Test([string]$Name,[scriptblock]$Body){
    try{&$Body;$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS  '+$Name)}
    catch{$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=$_.Exception.Message+' '+$_.ScriptStackTrace});Write-Host ('FAIL  '+$Name+': '+$_.Exception.Message)}
}
$tokens=$null;$parseErrors=$null
$helperAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Run-Tests.ps1'),[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count){throw 'Synthetic fixture helpers did not parse.'}
foreach($name in @('New-TestConfig','New-TestPdf','Add-Report','Import-Fixture')){
    $definition=@($helperAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($definition.Count -ne 1){throw ('Synthetic helper not found: '+$name)}
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
function Set-TestChecklist($Source,[string[]]$Components){$Source|Add-Member -NotePropertyName MonthlyChecklist -NotePropertyValue @($Components) -Force}
function Get-TestComponents($Object){if($null -eq $Object.PSObject.Properties['ConfirmedComponents']){return @()}return @($Object.ConfirmedComponents)}
function New-MonthlyFixture([string]$Name,[string[]]$Checklist=@('MTF','Slice Thickness','Low Contrast'),[int]$Count=1){
    $cfg=New-TestConfig $Name
    foreach($source in $cfg.Sources){$source.ActiveFrom='2024-01-01';Set-TestChecklist $source @()}
    Set-TestChecklist $cfg.Sources[0] $Checklist
    $kinds=@('Quality_Constancy_MTF','Quality_Constancy_Slice','Quality_Constancy_Contrast')
    $dates=@('2025-12-01','2025-12-10','2025-12-20')
    for($i=0;$i -lt $Count;$i++){[void](Add-Report $cfg 'CT_Edge' $kinds[$i] $dates[$i] '06-00-00' 95000)}
    [void](Import-Fixture $cfg)
    return [pscustomobject]@{Config=$cfg;Records=@((Get-QaDashboard -Config $cfg).Records|Sort-Object ReportDate)}
}
function Get-MonthlyRow($Config,$Records,[string]$Scanner='CT_Edge',[string]$Month='2025-12'){
    $rows=@(Get-QaMonthlyCoverage -Config $Config -Records @($Records) -Months @($Month)|Where-Object{$_.Scanner -eq $Scanner -and $_.Month -eq $Month})
    if($rows.Count -ne 1){throw ('Expected one coverage row for '+$Scanner+' '+$Month+'; found '+$rows.Count)}
    return $rows[0]
}
function Confirm-MonthlyReport($Config,$Record,[string[]]$Components){
    $decision=@([pscustomobject]@{RecordId=$Record.Id;Category='Monthly_QA';Reviewer='Synthetic monthly reviewer';Reason='Synthetic reviewed component evidence';ConfirmedComponents=@($Components)})
    [void](Invoke-QaOperation -Config $Config -Mode Reclassify -Decisions $decision)
}
function Assert-ComponentSet([string[]]$Expected,[string[]]$Actual,[string]$Message){Assert-Equal 0 @(Compare-Object @($Expected|Sort-Object) @($Actual|Sort-Object)).Count $Message}
Run-Test 'Separate reviewed PDFs contribute a component union only within the same scanner and month'{
    $f=New-MonthlyFixture 'SeparateComponentReports' -Count 3
    $row=Get-MonthlyRow $f.Config $f.Records
    Assert-Equal 'NeedsConfirmation' $row.Status 'Unreviewed PDFs remain candidates'
    Assert-Equal 3 $row.ReportCount 'All three December reports found'
    Assert-Equal 0 $row.ConfirmedReportCount 'No unreviewed PDF counted as confirmed'
    Confirm-MonthlyReport $f.Config $f.Records[0] @('MTF')
    Confirm-MonthlyReport $f.Config $f.Records[1] @('Slice Thickness')
    $records=@((Get-QaDashboard -Config $f.Config).Records)
    $row=Get-MonthlyRow $f.Config $records
    Assert-Equal 'Partial' $row.Status 'Two reviewed component reports leave a partial checklist'
    Assert-Equal 2 $row.ConfirmedReportCount 'Separate confirmed reports counted'
    Assert-ComponentSet @('MTF','Slice Thickness') @($row.ConfirmedComponents) 'Reviewed components are unioned'
    Assert-ComponentSet @('Low Contrast') @($row.MissingComponents) 'Only the unconfirmed checklist component is missing'
    Confirm-MonthlyReport $f.Config $f.Records[2] @('Low Contrast')
    $row=Get-MonthlyRow $f.Config @((Get-QaDashboard -Config $f.Config).Records)
    Assert-Equal 'Complete' $row.Status 'Reviewed component union satisfies configured checklist'
    Assert-Equal 3 $row.ConfirmedReportCount 'Three distinct reviewed reports preserved'
    Assert-Equal 0 @($row.MissingComponents).Count 'No checklist components missing'
    Assert-ComponentSet @('MTF','Slice Thickness','Low Contrast') @($row.ConfirmedComponents) 'Complete union has exact configured evidence'
}
Run-Test 'A single reviewed PDF can confirm every configured monthly component'{
    $f=New-MonthlyFixture 'AllComponentsInOnePdf'
    Confirm-MonthlyReport $f.Config $f.Records[0] @('MTF','Slice Thickness','Low Contrast')
    $row=Get-MonthlyRow $f.Config @((Get-QaDashboard -Config $f.Config).Records)
    Assert-Equal 'Complete' $row.Status 'One reviewed PDF satisfies all selected components'
    Assert-Equal 1 $row.ReportCount 'One physical report retained'
    Assert-Equal 1 $row.ConfirmedReportCount 'One confirmed report counted'
    Assert-ComponentSet @('MTF','Slice Thickness','Low Contrast') @($row.ConfirmedComponents) 'All reviewed components recorded'
}
Run-Test 'Pending filenames and text hints cannot count as confirmed component evidence'{
    $f=New-MonthlyFixture 'PendingHints' -Count 3
    $candidates=@($f.Records|ForEach-Object{$_|Select-Object *})
    foreach($r in $candidates){
        $r|Add-Member -NotePropertyName ConfirmedComponents -NotePropertyValue @('MTF','Slice Thickness','Low Contrast') -Force
        $r.ConfirmedBy='Synthetic field that must not override pending category';$r.ConfirmedAt=[datetime]::UtcNow.ToString('o')
    }
    $row=Get-MonthlyRow $f.Config $candidates
    Assert-Equal 'NeedsConfirmation' $row.Status 'Pending category still awaits confirmation'
    Assert-Equal 0 $row.ConfirmedReportCount 'Pending reports excluded even when component-like fields exist'
    Assert-Equal 0 @($row.ConfirmedComponents).Count 'No pending component evidence counted'
    Assert-ComponentSet @('MTF','Slice Thickness','Low Contrast') @($row.MissingComponents) 'Every required component still unconfirmed'
}
Run-Test 'Confirmed labels with no configured checklist never imply monthly completeness'{
    $f=New-MonthlyFixture 'ChecklistNotSet' -Checklist @()
    Confirm-MonthlyReport $f.Config $f.Records[0] @()
    $records=@((Get-QaDashboard -Config $f.Config).Records)
    $row=Get-MonthlyRow $f.Config $records
    Assert-Equal 'ChecklistNotSet' $row.Status 'Department checklist must be configured before completeness is assessed'
    Assert-Equal 1 $row.ConfirmedReportCount 'Confirmed report label remains visible without claiming checklist completeness'
    Assert-Equal 0 @($row.RequiredComponents).Count 'No approved checklist invented'
    Set-TestChecklist $f.Config.Sources[0] @('MTF','Slice Thickness')
    $legacy=$records[0]|Select-Object *;$legacy.PSObject.Properties.Remove('ConfirmedComponents')
    $row=Get-MonthlyRow $f.Config @($legacy)
    Assert-Equal 'Partial' $row.Status 'Old confirmed category without component evidence remains partial'
    Assert-Equal 0 @($row.ConfirmedComponents).Count 'No components inferred from an old Monthly label'
    Assert-ComponentSet @('MTF','Slice Thickness') @($row.MissingComponents) 'All checklist components need explicit review evidence'
}
Run-Test 'No report and pending report states remain distinct for configured checklists'{
    $f=New-MonthlyFixture 'MissingVersusPending' -Checklist @('MTF')
    $empty=Get-MonthlyRow $f.Config @()
    $pending=Get-MonthlyRow $f.Config $f.Records
    Assert-Equal 'NoConfirmedReport' $empty.Status 'Absent report has no-confirmed-report status'
    Assert-Equal 0 $empty.ReportCount 'Absent report count is zero'
    Assert-Equal 'NeedsConfirmation' $pending.Status 'Candidate report is awaiting confirmation'
    Assert-Equal 1 $pending.ReportCount 'Candidate report is present'
}
Run-Test 'Unknown components and components attached to a non-Monthly decision are rejected'{
    $f=New-MonthlyFixture 'RejectUnknownComponents' -Checklist @('MTF','Slice Thickness')
    $statePath=Join-Path $f.Config.ArchiveRoot '.ctqa/state.json';$before=(Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
    foreach($decision in @(
        [pscustomobject]@{RecordId=$f.Records[0].Id;Category='Monthly_QA';Reviewer='Synthetic reviewer';Reason='Synthetic invalid component';ConfirmedComponents=@('Unapproved Component')},
        [pscustomobject]@{RecordId=$f.Records[0].Id;Category='Daily_QA';Reviewer='Synthetic reviewer';Reason='Synthetic incompatible component';ConfirmedComponents=@('MTF')}
    )){
        $rejected=$false
        try{[void](Invoke-QaOperation -Config $f.Config -Mode Reclassify -Decisions @($decision))}catch{$rejected=$true}
        Assert-True $rejected 'Invalid component review rejected'
        Assert-Equal $before (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash 'Rejected review changes no persisted archive state'
    }
    $row=@((Get-QaDashboard -Config $f.Config).Records)[0]
    Assert-Equal 'Monthly_QA/Pending_Verification' $row.Category 'Invalid review cannot confirm Monthly category'
    Assert-Equal 0 @(Get-TestComponents $row).Count 'No component evidence committed by invalid decision'
}
Run-Test 'Component review canonicalizes configured names without inventing extra evidence'{
    $f=New-MonthlyFixture 'CanonicalComponents' -Checklist @('MTF','Slice Thickness')
    Confirm-MonthlyReport $f.Config $f.Records[0] @('mtf','SLICE THICKNESS')
    $record=@((Get-QaDashboard -Config $f.Config).Records)[0]
    Assert-ComponentSet @('MTF','Slice Thickness') @(Get-TestComponents $record) 'Stored evidence uses canonical checklist labels'
    Assert-True (@(Get-TestComponents $record) -ccontains 'MTF') 'Canonical MTF casing retained'
    Assert-True (@(Get-TestComponents $record) -ccontains 'Slice Thickness') 'Canonical component spelling retained'
    Assert-Equal 'Complete' (Get-MonthlyRow $f.Config @($record)).Status 'Canonicalized reviewed evidence satisfies checklist'
}
Run-Test 'Component evidence cannot cross scanner or calendar-month boundaries'{
    $cfg=New-TestConfig 'EvidenceBoundaries'
    foreach($source in $cfg.Sources){$source.ActiveFrom='2024-01-01';Set-TestChecklist $source @('MTF','Slice Thickness')}
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy_MTF' '2025-12-01' '06-00-00' 95000)
    [void](Add-Report $cfg 'CT_Flash' 'Quality_Constancy_Slice' '2025-12-01' '06-00-00' 95000)
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy_Slice' '2025-11-01' '06-00-00' 95000)
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy_Slice' '2024-12-01' '06-00-00' 95000)
    [void](Import-Fixture $cfg)
    $records=@((Get-QaDashboard -Config $cfg).Records)
    foreach($record in $records){$components=if($record.OriginalFileName -match 'MTF'){@('MTF')}else{@('Slice Thickness')};Confirm-MonthlyReport $cfg $record $components}
    $records=@((Get-QaDashboard -Config $cfg).Records)
    $rows=@(Get-QaMonthlyCoverage -Config $cfg -Records $records -Months @('2025-12','2025-11','2024-12'))
    $edge=@($rows|Where-Object{$_.Scanner -eq 'CT_Edge' -and $_.Month -eq '2025-12'})[0]
    $flash=@($rows|Where-Object{$_.Scanner -eq 'CT_Flash' -and $_.Month -eq '2025-12'})[0]
    Assert-Equal 'Partial' $edge.Status 'Other dates/scanners cannot complete Edge December 2025'
    Assert-ComponentSet @('Slice Thickness') @($edge.MissingComponents) 'Edge still lacks December slice evidence'
    Assert-Equal 'Partial' $flash.Status 'Edge evidence cannot complete Flash checklist'
    Assert-ComponentSet @('MTF') @($flash.MissingComponents) 'Flash still lacks MTF evidence'
    Assert-Equal 1 $edge.ConfirmedReportCount 'Only exact scanner/month confirmed report counted'
    Assert-Equal 9 $rows.Count 'Explicit three months are reported separately for three configured scanners'
}
Run-Test 'A changed source revision cannot inherit reviewed components for earlier bytes'{
    $f=New-MonthlyFixture 'ChangedRevisionComponents' -Checklist @('MTF','Slice Thickness')
    Confirm-MonthlyReport $f.Config $f.Records[0] @('MTF','Slice Thickness')
    $reviewed=@((Get-QaDashboard -Config $f.Config).Records)[0]
    [void](New-TestPdf -Path $reviewed.SourcePath -Size 97000 -Text 'Synthetic changed report bytes with no reviewed evidence')
    [void](Invoke-QaOperation -Config $f.Config -Mode Update)
    $records=@((Get-QaDashboard -Config $f.Config).Records)
    $new=@($records|Where-Object{$_.Hash -ne $reviewed.Hash})[0]
    Assert-Equal 2 $records.Count 'Both content revisions retained'
    Assert-Equal 'Monthly_QA/Pending_Verification' $new.Category 'New report bytes require new Monthly confirmation'
    Assert-Equal 0 @(Get-TestComponents $new).Count 'New content inherits no reviewed components'
    Assert-Equal 'NeedsConfirmation' (Get-MonthlyRow $f.Config @($new)).Status 'New content alone cannot satisfy checklist'
    Assert-Equal 'NeedsConfirmation' (Get-MonthlyRow $f.Config $records).Status 'Retained prior revision cannot mask the current unreviewed revision'
    $old=@($records|Where-Object{$_.Hash -eq $reviewed.Hash})[0]
    Assert-ComponentSet @('MTF','Slice Thickness') @(Get-TestComponents $old) 'Exact prior reviewed bytes retain their independent evidence'
}
Run-Test 'A corrupted archived PDF cannot acquire component confirmation'{
    $f=New-MonthlyFixture 'CorruptReviewComponents' -Checklist @('MTF')
    $bytes=[IO.File]::ReadAllBytes($f.Records[0].DestinationPath);$bytes[100]=[byte]($bytes[100] -bxor 1);[IO.File]::WriteAllBytes($f.Records[0].DestinationPath,$bytes)
    $rejected=$false
    try{Confirm-MonthlyReport $f.Config $f.Records[0] @('MTF')}catch{$rejected=$true}
    Assert-True $rejected 'Review validates exact archived PDF hash'
    $row=@((Get-QaDashboard -Config $f.Config).Records)[0]
    Assert-Equal 'Monthly_QA/Pending_Verification' $row.Category 'Corrupt bytes not confirmed'
    Assert-Equal 0 @(Get-TestComponents $row).Count 'No components committed for invalid bytes'
}
Run-Test 'Interrupted review commit recovers exact reviewed components and their audit evidence'{
    $f=New-MonthlyFixture 'RecoveredComponentReview' -Checklist @('MTF','Slice Thickness')
    $module=Get-Module Archive|Select-Object -First 1
    $original=&$module{Get-Item Function:Save-QaState|Select-Object -ExpandProperty ScriptBlock}
    $failed=$false
    try{
        &$module{Set-Item Function:script:Save-QaState -Value {param($State,$Paths) throw 'Synthetic component-review interruption before metadata commit'}}
        try{Confirm-MonthlyReport $f.Config $f.Records[0] @('MTF','Slice Thickness')}catch{$failed=$true}
    }finally{&$module{param($Body) Set-Item Function:script:Save-QaState -Value $Body} $original}
    Assert-True $failed 'Review commit interruption observed'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $f.Config.ArchiveRoot '.ctqa/transactions') -File -Filter '*.json').Count -gt 0) 'Component review recovery journal retained'
    [void](Invoke-QaOperation -Config $f.Config -Mode Update)
    $record=@((Get-QaDashboard -Config $f.Config).Records)[0]
    Assert-Equal 'Monthly_QA' $record.Category 'Reviewed Monthly category recovered'
    Assert-ComponentSet @('MTF','Slice Thickness') @(Get-TestComponents $record) 'Canonical reviewed components recovered on exact report'
    Assert-Equal 'Complete' (Get-MonthlyRow $f.Config @($record)).Status 'Recovered evidence satisfies configured checklist'
    $state=[IO.File]::ReadAllText((Join-Path $f.Config.ArchiveRoot '.ctqa/state.json'))|ConvertFrom-Json
    Assert-Equal 1 @($state.Reviews).Count 'Review provenance recovered once'
    Assert-ComponentSet @('MTF','Slice Thickness') @(Get-TestComponents $state.Reviews[0]) 'Audit review retains exact selected components'
    Assert-Equal $record.Hash $state.Reviews[0].Hash 'Recovered component evidence remains hash-bound'
}
Run-Test 'Monthly attention presents one combined missing-component item for each scanner-month'{
    $cfg=New-TestConfig 'CombinedComponentAttention'
    $month=(Get-Date).Date.AddDays(1-(Get-Date).Day).AddMonths(-1)
    foreach($source in $cfg.Sources){$source.ActiveFrom=$month.ToString('yyyy-MM-dd');Set-TestChecklist $source @()}
    Set-TestChecklist $cfg.Sources[0] @('MTF','Slice Thickness','Low Contrast')
    $kinds=@('Quality_Constancy_MTF','Quality_Constancy_Slice','Quality_Constancy_Contrast')
    for($i=0;$i -lt 3;$i++){[void](Add-Report $cfg 'CT_Edge' $kinds[$i] $month.AddDays(9*$i).ToString('yyyy-MM-dd') '06-00-00' 95000)}
    [void](Import-Fixture $cfg)
    $records=@((Get-QaDashboard -Config $cfg).Records|Sort-Object ReportDate)
    Confirm-MonthlyReport $cfg $records[0] @('MTF')
    $dashboard=Get-QaDashboard -Config $cfg
    $periodPattern=[regex]::Escape($month.ToString('yyyy-MM'))+'|'+[regex]::Escape($month.ToString('MMMM yyyy',[Globalization.CultureInfo]::InvariantCulture))
    $period=@($dashboard.Attention|Where-Object{$_.Scanner -eq 'CT_Edge' -and $_.Type -in @('MonthlyComponents','MonthlyGap','MonthlyPending') -and $_.Message -match $periodPattern})
    Assert-Equal 1 $period.Count 'No duplicate gap and component attention for same month'
    Assert-Equal 'MonthlyComponents' $period[0].Type 'Partial checklist has one component-focused attention item'
    Assert-True ($period[0].Message -match 'Slice Thickness') 'Combined item names missing slice component'
    Assert-True ($period[0].Message -match 'Low Contrast') 'Combined item names missing contrast component'
}
Run-Test 'Configured fourth scanners have independent monthly checklist coverage'{
    $cfg=New-TestConfig 'FourthScannerMonthly'
    foreach($source in $cfg.Sources){$source.ActiveFrom='2024-01-01';Set-TestChecklist $source @()}
    $path=Join-Path (Split-Path -Parent $cfg.ArchiveRoot) 'CT_Annex';[void][IO.Directory]::CreateDirectory($path)
    $annex=[pscustomobject]@{Scanner='CT_Annex';Name='Annex CT';Path=$path;DriveLetter='Z';DailySchedule='AllDays';ExpectedMonthly=$true;ActiveFrom='2024-01-01';MonthlyThresholdKB=85;MonthlyChecklist=@('MTF')}
    $cfg.Sources=@($cfg.Sources)+@($annex)
    [void](Add-Report $cfg 'CT_Annex' 'Quality_Constancy_MTF' '2025-12-01' '06-00-00' 95000)
    [void](Import-Fixture $cfg)
    $record=@((Get-QaDashboard -Config $cfg).Records)[0]
    Confirm-MonthlyReport $cfg $record @('MTF')
    $rows=@(Get-QaMonthlyCoverage -Config $cfg -Records @((Get-QaDashboard -Config $cfg).Records) -Months @('2025-12'))
    $row=@($rows|Where-Object{$_.Scanner -eq 'CT_Annex'})[0]
    Assert-Equal 4 $rows.Count 'Every configured scanner has separate monthly row'
    Assert-Equal 'Annex CT' $row.ScannerName 'Current configured scanner label retained'
    Assert-Equal 'Complete' $row.Status 'Fourth scanner checklist satisfied by its own reviewed evidence'
    Assert-Equal 3 @($rows|Where-Object{$_.Scanner -ne 'CT_Annex' -and $_.Status -eq 'ChecklistNotSet'}).Count 'Fourth scanner evidence does not populate original scanner checklists'
}
Run-Test 'Coverage calculations are read-only and reject malformed month identifiers'{
    $f=New-MonthlyFixture 'ReadOnlyCoverage'
    $before=$f.Records|ConvertTo-Json -Depth 15 -Compress
    $statePath=Join-Path $f.Config.ArchiveRoot '.ctqa/state.json';$stateHash=(Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
    [void](Get-QaMonthlyCoverage -Config $f.Config -Records $f.Records -Months @('2025-12'))
    Assert-Equal $before ($f.Records|ConvertTo-Json -Depth 15 -Compress) 'Coverage does not alter report objects'
    Assert-Equal $stateHash (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash 'Coverage does not persist archive mutations'
    $rejected=$false
    try{[void](Get-QaMonthlyCoverage -Config $f.Config -Records $f.Records -Months @('2025-13'))}catch{$rejected=$true}
    Assert-True $rejected 'Invalid calendar month rejected'
}
Run-Test 'Repairing saved bytes from an unchanged source preserves exact-hash reviewed components'{
    $f=New-MonthlyFixture 'RepairReviewedComponents' -Checklist @('MTF','Slice Thickness')
    Confirm-MonthlyReport $f.Config $f.Records[0] @('MTF')
    $reviewed=@((Get-QaDashboard -Config $f.Config).Records)[0]
    $originalPath=$reviewed.DestinationPath
    $sourceHash=(Get-FileHash -LiteralPath $reviewed.SourcePath -Algorithm SHA256).Hash
    $bytes=[IO.File]::ReadAllBytes($originalPath);$bytes[100]=[byte]($bytes[100] -bxor 1);[IO.File]::WriteAllBytes($originalPath,$bytes)
    $damagedHash=(Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
    [void](Invoke-QaOperation -Config $f.Config -Mode Update)
    $records=@((Get-QaDashboard -Config $f.Config).Records)
    $repaired=$records[0]
    Assert-Equal 1 $records.Count 'Repair preserves one report identity'
    Assert-Equal $reviewed.Id $repaired.Id 'Exact source content keeps prior identity'
    Assert-Equal $reviewed.Hash $repaired.Hash 'Repaired content has prior reviewed hash'
    Assert-Equal 'Monthly_QA' $repaired.Category 'Identical-byte repair preserves reviewed category'
    Assert-Equal $reviewed.ConfirmedBy $repaired.ConfirmedBy 'Identical-byte repair preserves reviewer'
    Assert-ComponentSet @('MTF') @(Get-TestComponents $repaired) 'Identical-byte repair preserves selected reviewed components'
    Assert-Equal $sourceHash (Get-FileHash -LiteralPath $repaired.DestinationPath -Algorithm SHA256).Hash 'Current saved copy repaired to exact source hash'
    Assert-Equal $sourceHash (Get-FileHash -LiteralPath $reviewed.SourcePath -Algorithm SHA256).Hash 'Repair leaves original scanner source bytes untouched'
    Assert-Equal $damagedHash (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash 'Previous damaged archive bytes preserved without overwrite'
    $row=Get-MonthlyRow $f.Config $records
    Assert-Equal 'Partial' $row.Status 'Repair does not fabricate additional component evidence'
    Assert-ComponentSet @('Slice Thickness') @($row.MissingComponents) 'Still-missing component remains missing after repair'
}
Run-Test 'Reclassification away from Monthly clears component evidence for monthly coverage'{
    $f=New-MonthlyFixture 'ClearMonthlyComponents' -Checklist @('MTF','Slice Thickness')
    Confirm-MonthlyReport $f.Config $f.Records[0] @('MTF','Slice Thickness')
    $decision=@([pscustomobject]@{RecordId=$f.Records[0].Id;Category='Daily_QA';Reviewer='Synthetic correcting reviewer';Reason='Synthetic correction away from Monthly';ConfirmedComponents=@()})
    [void](Invoke-QaOperation -Config $f.Config -Mode Reclassify -Decisions $decision)
    $record=@((Get-QaDashboard -Config $f.Config).Records)[0]
    Assert-Equal 'Daily_QA' $record.Category 'Correction category applied'
    Assert-Equal 0 @(Get-TestComponents $record).Count 'No Monthly components retained on a Daily record'
    $row=Get-MonthlyRow $f.Config @($record)
    Assert-Equal 'NoConfirmedReport' $row.Status 'Daily reclassification no longer provides confirmed Monthly coverage'
    Assert-Equal 0 $row.ConfirmedReportCount 'No confirmed Monthly report remains'
    Assert-ComponentSet @('MTF','Slice Thickness') @($row.MissingComponents) 'All monthly components require valid Monthly evidence again'
}
function New-ObservedMonthlyBinding($Record,[string[]]$Codes=@('MTF'),[string]$Category='Monthly',[string]$State='Filed',[bool]$Reference=$false){
    $sections=@($Codes|ForEach-Object{[pscustomobject]@{Code=$_;Page=3;BodyEvidence=$true;EvidenceCode=('NumberedBodySection.'+$_);PrintedOutcomes=@('OK')}})
    $doc=[pscustomobject]@{Status='Recognized';ProfileId='siemens-iec-additional-v1';CompleteRead=$true;DateStatus='Consensus';ReadPages=3;Sections=$sections;DocumentKind=$(if($Reference){'Reference'}else{'Current'})}
    $context=[pscustomobject]@{document=$doc;hasReferenceEvidence=$Reference;isReference=$Reference;dateSafe=$true;dateConflict=$false;typeConflict=$false;effectiveDate=[string]$Record.ReportDate;effectiveTime=[string]$Record.ReportTime;view=[pscustomobject]@{status='Recognized'}}
    return [pscustomobject]@{Record=$Record;Context=$context;Available=$true;Filing=[pscustomobject]@{category=$Category;pending=($State -cne 'Filed');filingState=$State;inferred=$true}}
}
function Get-ObservedMonthlyRow($Fixture,$Bindings,[string]$Month='2025-12',[datetime]$Today=[datetime]'2025-12-15'){
    return @((New-QaMonthlyWorkspace -Config $Fixture.Config -Month $Month -Records $Fixture.Records -Bindings @($Bindings) -Today $Today).scanners|Where-Object id -ceq 'CT_Edge')[0]
}
Run-Test 'Cached Monthly receipt and printed components remain distinct from recorded reviewed evidence'{
    $f=New-MonthlyFixture 'ObservedVersusReviewed' -Count 3;$before=(Get-FileHash (Join-Path $f.Config.ArchiveRoot '.ctqa/state.json')).Hash
    $bindings=@((New-ObservedMonthlyBinding $f.Records[0] @('MTF')),(New-ObservedMonthlyBinding $f.Records[1] @('Slice')),(New-ObservedMonthlyBinding $f.Records[2] @('LowContrast')))
    $row=Get-ObservedMonthlyRow $f $bindings
    Assert-Equal 3 $row.receipt.count 'Three filed Monthly PDFs are received'
    Assert-Equal 'AllItemsFound' $row.detected.status 'Canonical section presence covers exact configured legacy labels'
    Assert-True $row.detected.allItemsFound 'All printed checklist items found is explicit document presence'
    Assert-Equal 0 $row.reviewed.confirmedReportCount 'No clinical reviewer or evidence is fabricated by detected components'
    Assert-Equal 'NeedsConfirmation' $row.reviewed.status 'The existing recorded evidence state is retained separately'
    Assert-Equal $before (Get-FileHash (Join-Path $f.Config.ArchiveRoot '.ctqa/state.json')).Hash 'The entire projection is read-only'
}
Run-Test 'Daily reference pending and unavailable reports cannot supply Monthly receipt or detected coverage'{
    $f=New-MonthlyFixture 'ObservedBoundaries' -Count 3;$daily=New-ObservedMonthlyBinding $f.Records[0] @('MTF') 'Daily';$reference=New-ObservedMonthlyBinding $f.Records[1] @('Slice') 'Monthly' 'Filed' $true;$pending=New-ObservedMonthlyBinding $f.Records[2] @('LowContrast') 'Monthly' 'WaitingRead'
    $row=Get-ObservedMonthlyRow $f @($daily,$reference,$pending)
    Assert-Equal 0 $row.receipt.count 'Daily, Reference and awaiting-read files are not Monthly receipts'
    Assert-Equal 1 $row.receipt.waitingCount 'A genuine awaiting-read Monthly label remains visible separately'
    Assert-Equal 1 $row.excludedReferenceCount 'Reference exclusion is explicit'
    Assert-Equal 0 $row.detected.foundCount 'Those documents cannot populate the component checklist'
    $pending.Filing.pending=$false;$pending.Filing.filingState='Filed';$pending.Available=$false;$row=Get-ObservedMonthlyRow $f @($pending)
    Assert-Equal 0 $row.receipt.count 'A missing saved PDF cannot be a currently available receipt'
    Assert-Equal 1 $row.receipt.reviewCount 'An unavailable saved PDF is surfaced for attention'
}
Run-Test 'Exact checklist aliases are bounded and custom department text is never fuzzy-matched'{
    $f=New-MonthlyFixture 'ExactAliases' -Checklist @('MTF','Slice Thickness','Spatial resolution (MTF)')
    $row=Get-ObservedMonthlyRow $f @((New-ObservedMonthlyBinding $f.Records[0] @('MTF','Slice')))
    Assert-Equal 2 $row.detected.foundCount 'Only declared exact aliases match'
    Assert-Equal 'Partial' $row.detected.status 'A custom requirement stays unresolved'
    Assert-Equal 'Spatial resolution (MTF)' $row.checklist.unmatchedItems[0] 'Original custom labels remain unchanged and visible'
    Assert-True (-not $row.detected.allItemsFound) 'No fuzzy label inference can declare all items present'
    $options=@(Get-QaMonthlyComponentOptions);$slice=@($options|Where-Object code -ceq 'Slice')[0]
    Assert-True (@($slice.aliases|Where-Object{$_ -ieq 'Slice Thickness'}).Count -eq 1) 'The UI receives the same finite legacy alias mapping as the engine'
}
Run-Test 'Only actual complete current body evidence can populate the printed component checklist'{
    $f=New-MonthlyFixture 'BodyEvidenceOnly' -Checklist @('MTF');$binding=New-ObservedMonthlyBinding $f.Records[0] @('MTF')
    foreach($kind in @('FalseBody','StringBody','Toc','Truncated','Unknown','DateConflict')){
        $case=$binding|ConvertTo-Json -Depth 18|ConvertFrom-Json
        switch($kind){'FalseBody'{$case.Context.document.Sections[0].BodyEvidence=$false}'StringBody'{$case.Context.document.Sections[0].BodyEvidence='true'}'Toc'{$case.Context.document.Sections[0].Page=2}'Truncated'{$case.Context.document.CompleteRead=$false}'Unknown'{$case.Context.document.Status='NeedsReview'}'DateConflict'{$case.Context.dateConflict=$true}}
        Assert-Equal 0 (Get-ObservedMonthlyRow $f @($case)).detected.foundCount 'Unsupported, incomplete or non-body observations stay absent'
    }
    $binding.Context.document.Sections[0].PSObject.Properties.Remove('BodyEvidence')
    Assert-Equal 1 (Get-ObservedMonthlyRow $f @($binding)).detected.foundCount 'Strict literal numbered-body outcomes support a compatible older cached observation'
    $binding.Context.document.Sections[0].PrintedOutcomes=@();Assert-Equal 0 (Get-ObservedMonthlyRow $f @($binding)).detected.foundCount 'Legacy headings without printed body evidence cannot stand in for a completed read'
}
Run-Test 'Selected-month checklist history is preserved and the next editable effective month is explicit'{
    $f=New-MonthlyFixture 'ObservedRuleHistory' -Checklist @('Slice')
    $f.Config.Sources[0]|Add-Member MonthlyChecklistHistory @([pscustomobject]@{EffectiveMonth='0001-01';Components=@('MTF')},[pscustomobject]@{EffectiveMonth='2025-12';Components=@('Slice')}) -Force
    $setup=Get-QaMonthlySetup $f.Config.Sources[0] ([datetime]'2025-12-15')
    Assert-Equal '2025-12' $setup.checklistEffectiveMonth 'Latest saved version is visible for setup'
    Assert-Equal '2026-01' $setup.nextChecklistEffectiveMonth 'A changed rule cannot silently replace the latest effective version'
    $old=Get-ObservedMonthlyRow $f @() '2025-11';$current=Get-ObservedMonthlyRow $f @() '2025-12'
    Assert-Equal 'MTF' $old.checklist.items[0].label 'Historical checklist remains in its own month'
    Assert-Equal '0001-01' $old.checklist.effectiveMonth 'The actual historical baseline is disclosed'
    Assert-Equal 'Slice' $current.checklist.items[0].label 'Selected current month uses its later rule'
}
Run-Test 'Future off-schedule and pre-activation months have neutral requirements while receipts remain visible'{
    $f=New-MonthlyFixture 'ObservedApplicability' -Checklist @('MTF');$f.Config.Sources[0]|Add-Member MonthlyDueDay 10 -Force;$binding=New-ObservedMonthlyBinding $f.Records[0] @('MTF')
    $f.Config.Sources[0].ExpectedMonthly=$false;$row=Get-ObservedMonthlyRow $f @($binding)
    Assert-Equal 'NotRequired' $row.applicability 'Off-schedule scanner is explicit'
    Assert-Equal 'NotRequired' $row.due.timing 'No overdue claim is invented for a disabled requirement'
    Assert-Equal 1 $row.receipt.count 'Existing filed PDFs remain visible off schedule'
    $f.Config.Sources[0].ExpectedMonthly=$true;$f.Config.Sources[0].ActiveFrom='2026-01-01';$row=Get-ObservedMonthlyRow $f @($binding)
    Assert-Equal 'NotActive' $row.detected.status 'A selected month before activation does not become missing work'
    $f.Config.Sources[0].ActiveFrom='2024-01-01';$row=Get-ObservedMonthlyRow $f @() '2026-01'
    Assert-Equal 'Future' $row.due.timing 'A future month stays neutral'
    Assert-True (-not $row.detected.allItemsFound) 'An unassessed future month does not become clinically complete'
    $f.Config.Sources[0].ActiveFrom='2025-12-20';$row=Get-ObservedMonthlyRow $f @() '2025-12' ([datetime]'2025-12-15')
    Assert-Equal 'NotActive' $row.applicability 'A scanner activating later in the current month is not required yet'
    Assert-Equal 'NotActive' $row.due.timing 'A due day before future activation cannot create a false overdue alert'
    $row=Get-ObservedMonthlyRow $f @($binding) '2025-12' ([datetime]'2025-12-25')
    Assert-Equal 'ConfirmFirstMonthDue' $row.due.timing 'A due date before activation stays neutral even after the scanner becomes active'
    Assert-Equal 1 $row.receipt.count 'First-month due uncertainty does not hide received reports'
}
Run-Test 'Printed failures are documentary warnings and bounded lists retain truthful total receipt counts'{
    $f=New-MonthlyFixture 'ObservedPrintedWarnings' -Checklist @('MTF') -Count 3;$bindings=@($f.Records|ForEach-Object{New-ObservedMonthlyBinding $_ @('MTF')});$bindings[0].Context.document.Sections[0].PrintedOutcomes=@('NOT OK')
    $model=New-QaMonthlyWorkspace -Config $f.Config -Month '2025-12' -Records $f.Records -Bindings $bindings -Today ([datetime]'2025-12-15') -ReportLimit 1;$row=@($model.scanners|Where-Object id -ceq 'CT_Edge')[0]
    Assert-Equal 3 $row.receipt.count 'Report presence totals are computed before the output cap'
    Assert-Equal 1 $row.reports.Count 'Only the bounded report list is returned'
    Assert-True $model.limitReached 'The output cap is explicitly disclosed'
    Assert-Equal 1 $row.detected.printedWarningReportCount 'Literal printed warning does not disappear when the component is found'
    Assert-Equal 0 $row.reviewed.confirmedReportCount 'All found components and printed warnings still confer no formal sign-off'
    Assert-Equal 'CurrentConfiguration' $row.due.policy 'Due-day display never pretends to reconstruct an old approved due policy'
    foreach($bad in @('2025-13','2025-2','2025-12/../01','2025-12-01','0000-01')){$caught=$false;try{ConvertTo-QaMonthlyDate $bad|Out-Null}catch{$caught=$true};Assert-True $caught 'Only real exact calendar months are accepted'}
}

Run-Test 'Setup history cannot forward nested objects or invalid labels from an unselected future rule'{
    $f=New-MonthlyFixture 'SetupHistoryValidation' -Checklist @('MTF')
    foreach($bad in @([pscustomobject]@{Untrusted='Synthetic nested data'},'=Formula','MTF;Noise',('x'*81))){
        $f.Config.Sources[0]|Add-Member MonthlyChecklistHistory @([pscustomobject]@{EffectiveMonth='0001-01';Components=@('MTF')},[pscustomobject]@{EffectiveMonth='2099-01';Components=@($bad)}) -Force
        $caught=$false;try{Get-QaMonthlySetup $f.Config.Sources[0]|Out-Null}catch{$caught=$true};Assert-True $caught 'Future rules are projected only as validated bounded text labels'
    }
}
$failed=@($script:Results|Where-Object{$_.Result -eq 'FAIL'}).Count
$passed=$script:Results.Count-$failed
$report=[pscustomobject]@{Product='CT QA Manager Pro';Suite='Reviewed Monthly QA component coverage';TimestampUtc=[datetime]::UtcNow.ToString('o');Runtime=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1);Tests=$script:Results.Count;Assertions=$script:Assertions;Passed=$passed;Failed=$failed;Results=@($script:Results.ToArray());FixturesKept=[bool]$KeepFixtures}
if($OutputPath){$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
Write-Host ('Result: '+$passed+'/'+$script:Results.Count+' tests passed; '+$script:Assertions+' assertions; PowerShell '+$PSVersionTable.PSVersion)
if($KeepFixtures){Write-Host ('Synthetic fixtures: '+$TestRoot)}else{Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue}
if($failed -gt 0){exit 1}
