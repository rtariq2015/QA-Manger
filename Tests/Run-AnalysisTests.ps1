# Synthetic analysis cache/provenance regressions. Windows PowerShell 5.1 compatible.
[CmdletBinding()]
param([string]$OutputPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProductRoot 'App/Archive.psm1') -Force
Import-Module (Join-Path $ProductRoot 'App/Insights.psm1') -Force
$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_AnalysisTests_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestRoot)
$tokens=$null;$errors=$null
$testAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Run-Tests.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('New-TestConfig','New-TestPdf','Add-Report','Import-Fixture')) {
    $fn=$testAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Invoke-Expression $fn.Extent.Text
}
$script:Results=New-Object 'Collections.Generic.List[object]';$script:Assertions=0
function Check([bool]$Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Scenario([string]$Name,[scriptblock]$Body){try{&$Body;[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS '+$Name)}catch{[void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=$_.Exception.Message+' '+$_.ScriptStackTrace});Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}finally{Remove-ReadMock}}
function Fixture([string]$Name,[int]$Count=1,[switch]$SameBytes){
    $cfg=New-TestConfig $Name
    foreach($n in 1..$Count){[void](New-TestPdf -Path (Join-Path $cfg.Sources[0].Path ('Quality_Constancy_2025-12-'+$n.ToString('00')+'_06-00-00.pdf')) -Text $(if($SameBytes){'Synthetic identical QA fixture'}else{'Synthetic QA fixture '+$n}))}
    [void](Import-Fixture $cfg)
    return [pscustomobject]@{Config=$cfg;Records=@((Get-QaDashboard $cfg).Records|Sort-Object ReportDate)}
}
function CachePath($Fx,$Record){return Join-Path $Fx.Config.ArchiveRoot ('.ctqa/analysis/'+$Record.Hash+'.json')}
function Install-ReadMock($Fx,[string]$Text="--- Page 1 ---`nSynthetic unknown report`nNoise: PASS"){
    $control=[pscustomobject]@{Requests=(New-Object 'Collections.Generic.List[string]');Reads=@{};Cancel=$false;Mutate=$false;Throw=$false}
    foreach($record in $Fx.Records){$info=Get-Item -LiteralPath $record.DestinationPath;$control.Reads[$record.Id]=[pscustomobject]@{VerifiedHash=$record.Hash;VerifiedLength=$info.Length;VerifiedWriteTicks=$info.LastWriteTimeUtc.Ticks;Text=$Text;Pages=1;ReadPages=1;Truncated=$false;NeedsOCR=$false;Message='Synthetic verified read.';Summary=[pscustomobject]@{Cancelled=$false}}}
    & (Get-Module Insights) {
        param($Control,$Records)
        $script:AnalysisTestControl=$Control;$script:AnalysisTestRecords=$Records
        function script:Invoke-QaIsolatedTask {
            param($Action,$InputObject,$TimeoutSeconds,$Progress)
            [void]$script:AnalysisTestControl.Requests.Add([string]$InputObject.RecordId)
            if($script:AnalysisTestControl.Throw){throw 'Synthetic untrusted reader detail: PRIVATE-ERROR-CANARY'}
            $read=$script:AnalysisTestControl.Reads[$InputObject.RecordId]
            if($script:AnalysisTestControl.Cancel){$read.Summary.Cancelled=$true;if($null -ne $Progress){$Progress.Cancel=$true}}
            if($script:AnalysisTestControl.Mutate){$record=@($script:AnalysisTestRecords|Where-Object Id -eq $InputObject.RecordId)[0];[IO.File]::SetLastWriteTimeUtc($record.DestinationPath,[datetime]::UtcNow.AddMinutes(2))}
            return $read
        }
    } $control $Fx.Records
    return $control
}
function Remove-ReadMock {
    & (Get-Module Insights) {if(Test-Path Function:Invoke-QaIsolatedTask){Remove-Item Function:Invoke-QaIsolatedTask -ErrorAction SilentlyContinue};Remove-Variable AnalysisTestControl,AnalysisTestRecords -Scope Script -ErrorAction SilentlyContinue}
}
Scenario 'A real verified PDF is classified once and reused without changing review state' {
    $fx=Fixture 'RealReader';$record=$fx.Records[0];$state=Join-Path $fx.Config.ArchiveRoot '.ctqa/state.json';$before=(Get-FileHash $state).Hash
    $first=Invoke-QaAnalysis $fx.Config -RecordIds @($record.Id)
    Check ($first.Analyzed -eq 1 -and $first.Failed -eq 0 -and $first.AnalyzedIds[0] -eq $record.Id) 'The real local reader reports the selected analyzed identity'
    $saved=Get-QaSavedAnalysis $fx.Config $record
    Check ($null -ne $saved -and $saved.DocumentClassifierVersion -eq (Get-QaDocumentClassificationVersion) -and $saved.VerifiedHash -eq $record.Hash -and $saved.VerifiedLength -eq $record.Length) 'Versioned classification has exact parsed-byte provenance'
    Check ($saved.DocumentClassification.Status -eq 'NeedsReview' -and $saved.DocumentClassification.Category -eq '') 'Unknown content does not invent a daily/monthly approval'
    $cache=CachePath $fx $record;$cacheHash=(Get-FileHash $cache).Hash;$again=Invoke-QaAnalysis $fx.Config
    Check ($again.Analyzed -eq 0 -and $again.Cached -eq 1 -and (Get-FileHash $cache).Hash -eq $cacheHash) 'Background repeat does not reread or rewrite unknown content'
    Check ((Get-FileHash $state).Hash -eq $before) 'Analysis leaves clinical reviews and archive state byte-for-byte unchanged'
}
Scenario 'Legacy successful cache receives one bounded classifier upgrade' {
    $fx=Fixture 'Legacy';$record=$fx.Records[0];$control=Install-ReadMock $fx
    $path=CachePath $fx $record;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [pscustomobject]@{ParserVersion=1;Hash=$record.Hash;Status='ReportedPass';Findings=@([pscustomobject]@{Test='Old test';Result='PASS';Page=1;Evidence='Old parser result'});SavedWriteTicks=(Get-Item $record.DestinationPath).LastWriteTimeUtc.Ticks}|ConvertTo-Json -Depth 8|Set-Content $path -Encoding UTF8
    Check ($null -eq (Get-QaSavedAnalysis $fx.Config $record)) 'Legacy success is not falsely presented as a new content classification'
    $first=Invoke-QaAnalysis $fx.Config -Limit 1;$second=Invoke-QaAnalysis $fx.Config -Limit 1
    Check ($first.Analyzed -eq 1 -and $second.Analyzed -eq 0 -and $control.Requests.Count -eq 1) 'Missing classifier is reread once then cached'
    $saved=Get-QaSavedAnalysis $fx.Config $record
    Check ($saved.ParserVersion -eq 1 -and $saved.Findings[0].Test -eq 'Noise' -and $saved.Findings[0].Evidence -eq 'Noise: PASS') 'Existing printed-result parser semantics are preserved'
    $saved.DocumentClassifierVersion=0;$saved|ConvertTo-Json -Depth 12|Set-Content $path -Encoding UTF8
    Check ($null -eq (Get-QaSavedAnalysis $fx.Config $record)) 'A stale classifier version is rejected'
    [void](Invoke-QaAnalysis $fx.Config);[void](Invoke-QaAnalysis $fx.Config)
    Check ($control.Requests.Count -eq 2) 'A version change triggers only one additional read'
}
Scenario 'Legacy failed reads stay cached until manual force or file change' {
    $fx=Fixture 'LegacyFailure';$record=$fx.Records[0];$control=Install-ReadMock $fx;$path=CachePath $fx $record;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [pscustomobject]@{ParserVersion=1;Hash=$record.Hash;Status='ReadError';Truncated=$true;Findings=@();SavedWriteTicks=(Get-Item $record.DestinationPath).LastWriteTimeUtc.Ticks}|ConvertTo-Json -Depth 6|Set-Content $path -Encoding UTF8
    $cached=Invoke-QaAnalysis $fx.Config
    Check ($cached.Cached -eq 1 -and $control.Requests.Count -eq 0) 'Classifier upgrade does not loop on a legacy read error'
    $retry=Invoke-QaAnalysis $fx.Config -RecordIds @($record.Id) -Force
    Check ($retry.Analyzed -eq 1 -and $control.Requests.Count -eq 1) 'Explicit force retries exactly the selected read error'
}
Scenario 'Selected analysis never reads newer unselected reports or invalid identities' {
    $fx=Fixture 'Selected' 3;$control=Install-ReadMock $fx;$oldest=$fx.Records[0]
    $result=Invoke-QaAnalysis $fx.Config -RecordIds @($oldest.Id,$oldest.Id) -Limit 20
    Check ($result.Analyzed -eq 1 -and $result.AnalyzedIds.Count -eq 1 -and $control.Requests.Count -eq 1 -and $control.Requests[0] -eq $oldest.Id) 'Only the selected identity is read even when twenty newer candidates are allowed'
    Check ($null -eq (Get-QaSavedAnalysis $fx.Config $fx.Records[2])) 'Unselected reports remain unread'
    foreach($bad in @('not-an-id',('F'*64))){$rejected=$false;try{[void](Invoke-QaAnalysis $fx.Config -RecordIds @($fx.Records[1].Id,$bad))}catch{$rejected=$true};Check $rejected 'Malformed and unknown selections are rejected before the batch starts'}
    Check ($control.Requests.Count -eq 1) 'A partially valid selection cannot start partial reads'
}
Scenario 'Stored provenance invalidates changed bytes, lengths, timestamps, and classifier contents' {
    $fx=Fixture 'Invalidation';$record=$fx.Records[0];$control=Install-ReadMock $fx;[void](Invoke-QaAnalysis $fx.Config)
    $path=CachePath $fx $record;$original=[IO.File]::ReadAllText($path);$pdfBytes=[IO.File]::ReadAllBytes($record.DestinationPath);$ticks=(Get-Item $record.DestinationPath).LastWriteTimeUtc.Ticks
    [IO.File]::SetLastWriteTimeUtc($record.DestinationPath,[datetime]::UtcNow.AddMinutes(1));Check ($null -eq (Get-QaSavedAnalysis $fx.Config $record)) 'Changed destination timestamp invalidates the cache'
    [IO.File]::SetLastWriteTimeUtc($record.DestinationPath,(New-Object datetime($ticks,[DateTimeKind]::Utc)))
    [IO.File]::AppendAllText($record.DestinationPath,"`n% changed bytes`n");[IO.File]::SetLastWriteTimeUtc($record.DestinationPath,(New-Object datetime($ticks,[DateTimeKind]::Utc)))
    Check ($null -eq (Get-QaSavedAnalysis $fx.Config $record)) 'Changed length invalidates even when the old mtime is restored'
    [IO.File]::WriteAllBytes($record.DestinationPath,$pdfBytes);[IO.File]::SetLastWriteTimeUtc($record.DestinationPath,(New-Object datetime($ticks,[DateTimeKind]::Utc)))
    Check ($null -ne (Get-QaSavedAnalysis $fx.Config $record)) 'Restored exact original metadata reuses the original successful cache'
    $bad=$original|ConvertFrom-Json;$bad.DocumentClassification.ClassifierVersion=0;$bad|ConvertTo-Json -Depth 12|Set-Content $path -Encoding UTF8
    Check ($null -eq (Get-QaSavedAnalysis $fx.Config $record)) 'Nested classifier version is mandatory'
    $bad=$original|ConvertFrom-Json;$bad.VerifiedHash='0'*64;$bad|ConvertTo-Json -Depth 12|Set-Content $path -Encoding UTF8
    Check ($null -eq (Get-QaSavedAnalysis $fx.Config $record)) 'Stored verified fingerprint must match the indexed content fingerprint'
}
Scenario 'Reader provenance mismatches and post-read mutation cannot create successful classification' {
    foreach($kind in @('Hash','Length','Ticks','Mutate')){
        $fx=Fixture ('Mismatch'+$kind);$record=$fx.Records[0];$control=Install-ReadMock $fx
        switch($kind){'Hash'{$control.Reads[$record.Id].VerifiedHash='0'*64};'Length'{$control.Reads[$record.Id].VerifiedLength++};'Ticks'{$control.Reads[$record.Id].VerifiedWriteTicks++};'Mutate'{$control.Mutate=$true}}
        $result=Invoke-QaAnalysis $fx.Config;$saved=Get-QaSavedAnalysis $fx.Config $record
        Check ($result.Analyzed -eq 0 -and $result.Failed -eq 1 -and $saved.Status -eq 'ReadError' -and $null -eq $saved.PSObject.Properties['DocumentClassification']) ('Rejected '+$kind+' provenance has no successful classification')
        [void](Invoke-QaAnalysis $fx.Config);Check ($control.Requests.Count -eq 1) ('Unchanged '+$kind+' failure does not enter an automatic retry loop')
        Remove-ReadMock
    }
}
Scenario 'Cancellation neither writes partial classification nor replaces a prior cache' {
    $fx=Fixture 'Cancel';$record=$fx.Records[0];$control=Install-ReadMock $fx;$control.Cancel=$true
    $result=Invoke-QaAnalysis $fx.Config -RecordIds @($record.Id)
    Check ($result.Summary.Cancelled -and $result.Analyzed -eq 0 -and $result.Failed -eq 0 -and $result.AnalyzedIds.Count -eq 0 -and -not [IO.File]::Exists((CachePath $fx $record))) 'Cancelled reader output is not classified or cached'
    $control.Cancel=$false;$control.Reads[$record.Id].Summary.Cancelled=$false;[void](Invoke-QaAnalysis $fx.Config);$before=(Get-FileHash (CachePath $fx $record)).Hash
    $control.Cancel=$true;$result=Invoke-QaAnalysis $fx.Config -RecordIds @($record.Id) -Force
    Check ($result.Summary.Cancelled -and (Get-FileHash (CachePath $fx $record)).Hash -eq $before) 'Cancelled explicit retry preserves the previously committed analysis'
}
Scenario 'Unknown image and truncated reads are cached once without auto approval' {
    foreach($kind in @('Unknown','Image','Truncated')){
        $fx=Fixture ('Incomplete'+$kind);$record=$fx.Records[0];$control=Install-ReadMock $fx
        if($kind -eq 'Image'){$control.Reads[$record.Id].Text='';$control.Reads[$record.Id].NeedsOCR=$true}
        if($kind -eq 'Truncated'){$control.Reads[$record.Id].Truncated=$true;$control.Reads[$record.Id].Pages=3}
        $first=Invoke-QaAnalysis $fx.Config;$second=Invoke-QaAnalysis $fx.Config;$saved=Get-QaSavedAnalysis $fx.Config $record
        Check ($first.Analyzed -eq 1 -and $second.Cached -eq 1 -and $control.Requests.Count -eq 1) ($kind+' content is not reparsed repeatedly')
        Check ($saved.DocumentClassification.Status -eq 'NeedsReview' -and $saved.DocumentClassification.Category -eq '') ($kind+' content never supplies an automatic approval')
        Remove-ReadMock
    }
}
Scenario 'Equal-content destinations retain separate valid metadata without cache ping-pong' {
    $fx=Fixture 'DuplicateHashes' 3 -SameBytes;$control=Install-ReadMock $fx
    Check (@($fx.Records.Hash|Select-Object -Unique).Count -eq 1) 'Fixture has identical bytes at independent archive destinations'
    $first=Invoke-QaAnalysis $fx.Config;$second=Invoke-QaAnalysis $fx.Config
    Check ($first.Analyzed -eq 3 -and $second.Analyzed -eq 0 -and $second.Cached -eq 3 -and $control.Requests.Count -eq 3) 'Each destination is verified once and then reuses its own metadata'
    foreach($record in $fx.Records){$saved=Get-QaSavedAnalysis $fx.Config $record;Check ($null -ne $saved -and $saved.RecordId -eq $record.Id) 'The correct per-record provenance is returned'}
}
Scenario 'Cache stores bounded evidence fields without the full PDF text or private reader error' {
    $fx=Fixture 'Privacy';$record=$fx.Records[0];$canary='SYNTHETIC-PRIVATE-FREE-TEXT-CANARY'
    $control=Install-ReadMock $fx ("--- Page 1 ---`n"+$canary+"`nNoise: PASS`nSerial Number: SYNTHETIC-SERIAL-CANARY")
    [void](Invoke-QaAnalysis $fx.Config);$json=[IO.File]::ReadAllText((CachePath $fx $record));$saved=$json|ConvertFrom-Json
    Check (-not $json.Contains($canary) -and -not $json.Contains('SYNTHETIC-SERIAL-CANARY') -and $null -eq $saved.PSObject.Properties['Text']) 'Complete source text and private identifiers are not persisted'
    Check ($saved.Findings[0].Evidence -eq 'Noise: PASS' -and $saved.DocumentClassification.ClinicalResult -eq 'Not inferred') 'Printed evidence is preserved separately from clinical interpretation'
    $control.Throw=$true;[void](Invoke-QaAnalysis $fx.Config -RecordIds @($record.Id) -Force);$errorJson=[IO.File]::ReadAllText((CachePath $fx $record))
    Check (-not $errorJson.Contains('PRIVATE-ERROR-CANARY')) 'Unexpected reader errors cannot add raw private details to the cache'
}
Scenario 'Linked analysis directories cannot supply trusted document classifications' {
    $fx=Fixture 'LinkedAnalysis';$record=$fx.Records[0];$control=Install-ReadMock $fx
    [void](Invoke-QaAnalysis $fx.Config -RecordIds @($record.Id));$path=CachePath $fx $record;$folder=Split-Path -Parent $path
    $outside=Join-Path $fx.Config.AppRoot 'ExternalAnalysis';Move-Item -LiteralPath $folder -Destination $outside
    $outsideFile=Join-Path $outside ($record.Hash+'.json');$before=(Get-FileHash $outsideFile).Hash
    try{
        $kind=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Junction'}else{'SymbolicLink'}
        [void](New-Item -ItemType $kind -Path $folder -Target $outside -ErrorAction Stop)
        Check ($null -eq (Get-QaSavedAnalysis $fx.Config $record)) 'A valid-looking JSON below a linked cache directory is not trusted'
        Check ((Get-FileHash $outsideFile).Hash -ceq $before) 'Reading an untrusted cache does not change its external target'
    }finally{if([IO.Directory]::Exists($folder)){[IO.Directory]::Delete($folder)}}
    Check ((Get-FileHash $outsideFile).Hash -ceq $before) 'Removing the fixture link preserves its external data'
}
function Write-TestAnalysisCache($Fx,$Record,$Value){[IO.File]::WriteAllText((CachePath $Fx $Record),($Value|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding($true)))}
function Set-TestUnknownTemplate($Value){
    $Value.PSObject.Properties.Remove('ContentSupportRevision')
    $Value.DocumentClassification.PSObject.Properties.Remove('SupportRevision');$Value.DocumentClassification.Model=''
    $Value.DocumentClassification.Status='NeedsReview';$Value.DocumentClassification.ProfileId='';$Value.DocumentClassification.ReasonCode='UnknownTemplate'
    return $Value
}
Scenario 'A metadata-only work plan distinguishes unread files, measurement upgrades, format upgrades and cached errors' {
    $fx=Fixture 'BacklogPlan' 6;$control=Install-ReadMock $fx
    [void](Invoke-QaAnalysis $fx.Config -RecordIds @($fx.Records[1..5].Id))
    foreach($n in @(1,4)){$row=Get-QaSavedAnalysis $fx.Config $fx.Records[$n];$row.DocumentClassification.Status='Recognized';$row.DocumentClassification.ProfileId='siemens-iec-basic-v1';$row.DocumentClassification.ReasonCode='SupportedProfile';$row.ContentSupportRevision=1;if($n -eq 1){$row.PSObject.Properties.Remove('MeasurementsDocument')};Write-TestAnalysisCache $fx $fx.Records[$n] $row}
    $row=Set-TestUnknownTemplate (Get-QaSavedAnalysis $fx.Config $fx.Records[2]);Write-TestAnalysisCache $fx $fx.Records[2] $row
    $row=Get-QaSavedAnalysis $fx.Config $fx.Records[3];$row.Status='ReadError';Write-TestAnalysisCache $fx $fx.Records[3] $row
    $row=Get-QaSavedAnalysis $fx.Config $fx.Records[5];$row.ContentSupportRevision=1;$row.DocumentClassification.ReasonCode='IncompleteRead';Write-TestAnalysisCache $fx $fx.Records[5] $row
    $state=Join-Path $fx.Config.ArchiveRoot '.ctqa/state.json';$before=(Get-FileHash $state).Hash;$cacheBefore=@{};foreach($r in $fx.Records[1..5]){$cacheBefore[$r.Id]=(Get-FileHash (CachePath $fx $r)).Hash}
    $module=Get-Module Insights
    try{
        & $module {function script:Get-QaDashboard {param($Config) throw 'Work plan unexpectedly rebuilt the dashboard.'}}
        $plan=Get-QaAnalysisWorkPlan -Config $fx.Config -Records $fx.Records -UpgradeMeasurements -RefreshUnsupported -Limit 2
        $ordinary=Get-QaAnalysisWorkPlan -Config $fx.Config -Records $fx.Records
        $progress=Get-QaAnalysisProgress -Config $fx.Config -Records $fx.Records
    }finally{& $module {Remove-Item Function:Get-QaDashboard -ErrorAction SilentlyContinue}}
    Check ($plan.Total -eq 6 -and $plan.Cached -eq 5 -and $plan.Errors -eq 1) 'Valid existing caches and a failed read remain distinct from missing work'
    Check ($plan.NewPending -eq 1 -and $plan.MeasurementUpgradePending -eq 1 -and $plan.UnsupportedUpgradePending -eq 1 -and $plan.Pending -eq 3) 'Three eligible causes are disjoint and explicitly counted'
    Check ($plan.RecordIds.Count -eq 2 -and $plan.RecordIds[0] -ceq $fx.Records[2].Id -and $plan.RecordIds[1] -ceq $fx.Records[1].Id) 'A bounded newest-first queue contains only eligible identities'
    Check ($ordinary.Pending -eq 1 -and $ordinary.RecordIds.Count -eq 1 -and $ordinary.RecordIds[0] -ceq $fx.Records[0].Id) 'Ordinary background work does not force a historical upgrade'
    Check ($progress.Pending -eq 1 -and $progress.BacklogPending -eq 3 -and $progress.MeasurementUpgradePending -eq 1 -and $progress.UnsupportedUpgradePending -eq 1) 'Progress exposes backlog without changing the conservative automatic count'
    Check ($control.Requests.Count -eq 5 -and (Get-FileHash $state).Hash -ceq $before) 'Planning parses no PDF and changes no clinical archive state'
    foreach($r in $fx.Records[1..5]){Check ((Get-FileHash (CachePath $fx $r)).Hash -ceq $cacheBefore[$r.Id]) 'Metadata planning never rewrites an existing reading'}
}
Scenario 'An older unknown Flash template is refreshed once and then reused with the same protected PDF provenance' {
    $fx=Fixture 'FlashRevision';$record=$fx.Records[0];$parts=New-Object 'Collections.Generic.List[string]'
    foreach($page in 1..3){$body="--- Page $page ---`nSOMATOM Definition Flash`nQuality IEC Constancy`n";if($page -eq 3){$body+="1. Quality IEC Constancy Homogeneity / Water`nStatus: OK`n2. Quality IEC Constancy Noise`nStatus: OK`n"};$body+="2025-12-01 06:00:00 Page: $page / 3";[void]$parts.Add($body)}
    $control=Install-ReadMock $fx ($parts -join "`n");$control.Reads[$record.Id].Pages=3;$control.Reads[$record.Id].ReadPages=3;$control.Reads[$record.Id]|Add-Member ReaderUsed 'Standard' -Force
    $state=Join-Path $fx.Config.ArchiveRoot '.ctqa/state.json';$before=(Get-FileHash $state).Hash
    [void](Invoke-QaAnalysis $fx.Config);$old=Set-TestUnknownTemplate (Get-QaSavedAnalysis $fx.Config $record);Write-TestAnalysisCache $fx $record $old
    Check (Test-QaAnalysisSelectedRefresh $fx.Config $record) 'Selecting an old unsupported report offers a current-format refresh'
    $normal=Invoke-QaAnalysis $fx.Config;Check ($normal.Cached -eq 1 -and $control.Requests.Count -eq 1) 'Existing background behavior still reuses a valid old cache'
    $first=Invoke-QaAnalysis $fx.Config -RefreshUnsupported;$saved=Get-QaSavedAnalysis $fx.Config $record;$cacheHash=(Get-FileHash (CachePath $fx $record)).Hash
    Check ($first.Analyzed -eq 1 -and $saved.ContentSupportRevision -eq 3 -and $saved.DocumentClassification.Status -ceq 'Recognized' -and $saved.DocumentClassification.Model -ceq 'SOMATOM Definition Flash') 'One opt-in refresh recognizes the compatible complete Flash IEC body'
    Check ($saved.DocumentClassification.Category -ceq '' -and $saved.DocumentClassification.ClinicalResult -ceq 'Not inferred') 'Recognition does not assign department frequency or clinical approval'
    $second=Invoke-QaAnalysis $fx.Config -UpgradeMeasurements -RefreshUnsupported
    Check ($second.Cached -eq 1 -and $second.Analyzed -eq 0 -and $control.Requests.Count -eq 2 -and (Get-FileHash (CachePath $fx $record)).Hash -ceq $cacheHash) 'A completed current revision is reused without another read or write'
    Check ($saved.VerifiedHash -ceq $record.Hash -and (Get-FileHash $record.DestinationPath).Hash -ceq $record.Hash -and (Get-FileHash $state).Hash -ceq $before) 'Derived support refresh preserves exact PDF bytes and core review state'
    $events=@(Get-ChildItem (Join-Path $fx.Config.AppRoot 'Logs/Scrubbed') -Filter '*.jsonl'|ForEach-Object{Get-Content $_.FullName|ForEach-Object{$_|ConvertFrom-Json}});$completed=@($events|Where-Object{$_.Operation -ceq 'PdfRead' -and $_.Outcome -ceq 'Completed'})
    Check ($completed.Count -eq 2 -and $completed[-1].Stage -ceq 'Analyzing' -and $completed[-1].Reason -ceq 'NoSupportedTables' -and $completed[-1].Reader -ceq 'Standard' -and $completed[-1].Profile -ceq 'Basic') 'The detailed event retains controlled reason, reader, profile and stage codes without adding events for cached skips'
}
Scenario 'Explicit measurement backlog upgrades an older successful cache once without reprocessing current or failed readings' {
    $fx=Fixture 'MeasurementBacklog' 3;$control=Install-ReadMock $fx;[void](Invoke-QaAnalysis $fx.Config)
    $old=$fx.Records[0];$row=Get-QaSavedAnalysis $fx.Config $old;$row.PSObject.Properties.Remove('MeasurementsDocument');Write-TestAnalysisCache $fx $old $row
    $failed=$fx.Records[2];$row=Get-QaSavedAnalysis $fx.Config $failed;$row.Status='readerror';$row.PSObject.Properties.Remove('MeasurementsDocument');Write-TestAnalysisCache $fx $failed $row
    $plan=Get-QaAnalysisWorkPlan -Config $fx.Config -Records $fx.Records -UpgradeMeasurements -RefreshUnsupported
    Check ($plan.Pending -eq 1 -and $plan.MeasurementUpgradePending -eq 1 -and $plan.Errors -eq 1 -and $plan.RecordIds[0] -ceq $old.Id) 'Only the eligible successful old reading is queued'
    $first=Invoke-QaAnalysis $fx.Config -UpgradeMeasurements -RefreshUnsupported -Limit 1;$second=Invoke-QaAnalysis $fx.Config -UpgradeMeasurements -RefreshUnsupported
    Check ($first.Analyzed -eq 1 -and $first.Pending -eq 0 -and $second.Analyzed -eq 0 -and $control.Requests.Count -eq 4) 'A historical measurement cache upgrades exactly once'
    Check ((Get-QaSavedAnalysis $fx.Config $failed).Status -ceq 'readerror') 'A noncanonical-case legacy read error is preserved without entering the historical upgrade loop'
}
Scenario 'Equal-content destinations retain independent one-time format support revisions' {
    $fx=Fixture 'SupportAlias' 3 -SameBytes;$control=Install-ReadMock $fx;[void](Invoke-QaAnalysis $fx.Config)
    $path=CachePath $fx $fx.Records[0];$combined=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    [void](Set-TestUnknownTemplate $combined);foreach($entry in $combined.OtherRecords){[void](Set-TestUnknownTemplate $entry)}
    $combined.OtherRecords[0].DocumentClassification.ReasonCode='UnrecognizedSections';Write-TestAnalysisCache $fx $fx.Records[0] $combined
    $plan=Get-QaAnalysisWorkPlan -Config $fx.Config -Records $fx.Records -RefreshUnsupported
    Check ($plan.UnsupportedUpgradePending -eq 3 -and $plan.RecordIds.Count -eq 3) 'Equal byte hashes retain independently eligible UnknownTemplate and UnrecognizedSections provenance rows'
    $first=Invoke-QaAnalysis $fx.Config -Limit 1 -RefreshUnsupported;$remaining=Get-QaAnalysisWorkPlan -Config $fx.Config -Records $fx.Records -RefreshUnsupported
    Check ($first.Analyzed -eq 1 -and $remaining.Pending -eq 2) 'Saving one destination revision does not mark untouched aliases as upgraded'
    $second=Invoke-QaAnalysis $fx.Config -RefreshUnsupported;$warm=Invoke-QaAnalysis $fx.Config -RefreshUnsupported
    Check ($second.Analyzed -eq 2 -and $warm.Analyzed -eq 0 -and $warm.Cached -eq 3 -and $control.Requests.Count -eq 6) 'Every alias upgrades once and then stays warm without cache ping-pong'
}

$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$result=[pscustomobject]@{Product='CT QA Manager Pro';Feature='Versioned content analysis cache';TimestampUtc=[datetime]::UtcNow.ToString('o');Runtime=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5);Tests=$script:Results.Count;Assertions=$script:Assertions;Failed=$failed;Results=@($script:Results.ToArray());Notes='Synthetic PDFs and controlled reader responses only. The first scenario invokes the real isolated verified PDF reader.'}
if($OutputPath){$result|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
Write-Host ('Result: '+($result.Tests-$failed)+'/'+$result.Tests+' scenarios, '+$result.Assertions+' assertions')
Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
if($failed){exit 1}
