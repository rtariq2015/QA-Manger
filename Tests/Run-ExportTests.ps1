# Synthetic export and report-filter tests. Windows PowerShell 5.1, no Pester.
[CmdletBinding()]
param([string]$OutputPath='', [switch]$KeepFixtures)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProductRoot 'App/Archive.psm1') -Force
Import-Module (Join-Path $ProductRoot 'App/Reports.psm1') -Force
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_ExportSynthetic_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestRoot)
$script:Results=New-Object 'System.Collections.Generic.List[object]'
$script:Assertions=0
function Assert-True([bool]$Condition,[string]$Message) {
    $script:Assertions++
    if(-not $Condition){throw ('Assertion failed: '+$Message)}
}
function Assert-Equal($Expected,$Actual,[string]$Message) {
    Assert-True ([string]$Expected -ceq [string]$Actual) ($Message+'; expected='+[string]$Expected+'; actual='+[string]$Actual)
}
function Run-Test([string]$Name,[scriptblock]$Body) {
    try{
        & $Body
        $script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''})
        Write-Host ('PASS  '+$Name)
    }catch{
        if($_.Exception.Message.StartsWith('[SKIP]')){
            $script:Results.Add([pscustomobject]@{Name=$Name;Result='SKIP';Details=$_.Exception.Message})
            Write-Host ('SKIP  '+$Name+': '+$_.Exception.Message)
        }else{
            $script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=$_.Exception.Message+' '+$_.ScriptStackTrace})
            Write-Host ('FAIL  '+$Name+': '+$_.Exception.Message)
        }
    }
}
# Reuse the valid-PDF and isolated configuration builders without executing the
# archive test runner. AST extraction loads only these four local test functions.
$tokens=$null;$parseErrors=$null
$helperAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Run-Tests.ps1'),[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count){throw 'The synthetic fixture helpers could not be parsed.'}
$required=@('New-TestConfig','New-TestPdf','Add-Report','Import-Fixture')
foreach($name in $required){
    $definition=@($helperAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($definition.Count -ne 1){throw ('Synthetic test helper missing: '+$name)}
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
function New-ExportFixture([string]$Name,[switch]$Rich){
    $cfg=New-TestConfig $Name
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' '2025-12-01' '06-00-00' 1800 'SessionA')
    if($Rich){
        [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' '2025-12-01' '06-00-00' 2400 'SessionB')
        [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' '2025-11-30')
        [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' '2024-12-01')
        [void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy' '2025-12-15' '08-00-00' 76000)
        [void](Add-Report $cfg 'CT_Flash' 'Quality_Daily' '2025-12-02')
        [void](Add-Report $cfg 'CT_Flash' 'Quality_Constancy' '2025-12-10' '06-00-00' 95000)
        [void](Add-Report $cfg 'MDP_Building' 'Quality_IECAcceptance' '2025-12-03' '09-00-00')
    }
    [void](Import-Fixture $cfg)
    if($Rich){
        $monthly=@((Get-QaDashboard -Config $cfg).Records|Where-Object{$_.Scanner -eq 'CT_Flash' -and $_.Category -eq 'Monthly_QA/Pending_Verification'})[0]
        $decisions=@([pscustomobject]@{RecordId=$monthly.Id;Category='Monthly_QA';Reviewer='Synthetic export reviewer';Reason='Synthetic confirmed Monthly export fixture'})
        [void](Invoke-QaOperation -Config $cfg -Mode Reclassify -Decisions $decisions)
    }
    $out=Join-Path (Join-Path $TestRoot 'ExportOutputs') $Name
    [void][IO.Directory]::CreateDirectory($out)
    return [pscustomobject]@{Config=$cfg;Records=@((Get-QaDashboard -Config $cfg).Records);Output=$out;SourceRoots=@($cfg.Sources|ForEach-Object{$_.Path})}
}
function Get-FixtureManifest([string[]]$Roots){
    $lines=New-Object 'System.Collections.Generic.List[string]'
    foreach($root in $Roots){
        if(-not [IO.Directory]::Exists($root)){$lines.Add('MISSING|'+$root);continue}
        foreach($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force|Sort-Object FullName)){
            $lines.Add($file.FullName+'|'+$file.Length+'|'+$file.LastWriteTimeUtc.Ticks+'|'+(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
        }
    }
    return ($lines.ToArray() -join "`n")
}
function Get-ZipEvidence([string]$Path){
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    $pdfs=New-Object 'System.Collections.Generic.List[object]'
    $metadata=New-Object 'System.Collections.Generic.List[string]'
    $names=New-Object 'System.Collections.Generic.List[string]'
    try{
        foreach($entry in $zip.Entries){
            $names.Add($entry.FullName)
            Assert-True ($entry.FullName -notmatch '^(?:[A-Za-z]:|[\\/])|(?:^|[\\/])\.\.(?:[\\/]|$)') ('ZIP entry is relative and safe: '+$entry.FullName)
            if($entry.FullName -match '(?i)\.pdf$'){
                $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
                try{$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')}
                finally{$sha.Dispose();$stream.Dispose()}
                $pdfs.Add([pscustomobject]@{Name=$entry.FullName;Hash=$hash;Length=$entry.Length})
            }elseif($entry.FullName -match '(?i)\.(json|csv|txt|md)$'){
                $stream=$entry.Open();$reader=New-Object IO.StreamReader($stream)
                try{$metadata.Add($reader.ReadToEnd())}finally{$reader.Dispose();$stream.Dispose()}
            }
        }
    }finally{$zip.Dispose()}
    return [pscustomobject]@{Pdfs=@($pdfs.ToArray());Names=@($names.ToArray());Metadata=($metadata.ToArray() -join "`n")}
}
function Get-ZipFileText([string]$Path,[string]$EntryName){
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try{
        $entry=$zip.GetEntry($EntryName)
        if($null -eq $entry){throw ('ZIP metadata entry missing: '+$EntryName)}
        $stream=$entry.Open();$reader=New-Object IO.StreamReader($stream)
        try{return $reader.ReadToEnd()}finally{$reader.Dispose();$stream.Dispose()}
    }finally{$zip.Dispose()}
}
function Assert-NoExportFile($Fixture,[string]$Path){
    Assert-True (-not [IO.File]::Exists($Path)) 'No finalized ZIP exists after rejected export'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $Fixture.Output -File -Force).Count 'No partial export file left behind'
}
function New-TestDirectoryLink([string]$Path,[string]$Target){
    $kind=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Junction'}else{'SymbolicLink'}
    try{New-Item -ItemType $kind -Path $Path -Value $Target -ErrorAction Stop|Out-Null}
    catch{throw ('[SKIP] This workstation could not create the synthetic '+$kind+' test fixture: '+$_.Exception.Message)}
}
$rich=New-ExportFixture 'FilterDataset' -Rich
Run-Test 'Filters preserve identities and isolate December of the chosen year'{
    $before=$rich.Records|ConvertTo-Json -Depth 12 -Compress
    $rows=@(Select-QaReports -Records $rich.Records -Year 2025 -Month 12)
    Assert-Equal 6 $rows.Count 'December 2025 includes only its six records'
    Assert-Equal 0 @($rows|Where-Object{$_.ReportDate -notmatch '^2025-12-'}).Count 'Other months and years excluded'
    $edge=@(Select-QaReports -Records $rich.Records -Scanner 'CT_Edge' -Year 2025 -Month 12)
    Assert-Equal 3 $edge.Count 'Scanner and period filters combine'
    Assert-Equal 8 @(Select-QaReports -Records $rich.Records -Scanner 'All' -Year 0 -Month 0 -Category 'All').Count 'All filters preserve every record'
    Assert-Equal $before ($rich.Records|ConvertTo-Json -Depth 12 -Compress) 'Filtering leaves source record objects unchanged'
    Assert-Equal 0 @(Compare-Object @($rows.Id|Sort-Object) @($rich.Records|Where-Object{$_.ReportDate -match '^2025-12-'}|ForEach-Object{$_.Id}|Sort-Object)).Count 'Filtered IDs remain exact archive IDs'
}
Run-Test 'Pending and confirmed Monthly filters stay distinct; human queries match visible labels'{
    $pending=@(Select-QaReports -Records $rich.Records -Year 2025 -Month 12 -Category 'Monthly_QA/Pending_Verification')
    $confirmed=@(Select-QaReports -Records $rich.Records -Year 2025 -Month 12 -Category 'Monthly_QA')
    Assert-Equal 1 $pending.Count 'One pending Monthly candidate'
    Assert-Equal 1 $confirmed.Count 'One confirmed Monthly record'
    Assert-True ($pending[0].Id -ne $confirmed[0].Id) 'Pending report cannot satisfy confirmed category'
    Assert-Equal 2 @(Select-QaReports -Records $rich.Records -Query 'CT Flash').Count 'Human scanner label searchable'
    Assert-Equal 5 @(Select-QaReports -Records $rich.Records -Query 'Daily QA').Count 'Human category label searchable'
    Assert-Equal 0 @(Select-QaReports -Records $rich.Records -Query 'no-such-synthetic-report').Count 'Unmatched query yields no records'
    $title=Get-QaReportTitle -Record $pending[0]
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$title)) 'Friendly title is present'
    Assert-True ($title -match '(?i)constancy|monthly|QA|report') 'Friendly title describes the report'
}
Run-Test 'Selected December export reads every ZIP PDF back and preserves duplicate report names'{
    $rows=@(Select-QaReports -Records $rich.Records -Year 2025 -Month 12)
    $before=Get-FixtureManifest (@($rich.Config.ArchiveRoot)+$rich.SourceRoots)
    $path=Join-Path $rich.Output 'December-2025.zip'
    $result=Invoke-QaExport -Config $rich.Config -RecordIds @($rows.Id) -DestinationPath $path
    Assert-True ([IO.File]::Exists($path)) 'ZIP finalized'
    Assert-Equal 6 $result.Summary.Exported 'Six selected reports exported'
    Assert-Equal 0 $result.Summary.Failed 'Export has no failed report'
    $zip=Get-ZipEvidence $path
    Assert-Equal 6 $zip.Pdfs.Count 'Every selected PDF appears exactly once'
    Assert-Equal 3 @($zip.Pdfs|Where-Object{$_.Name -match '/Daily QA/'}).Count 'Daily PDFs share the simple Daily QA folder'
    Assert-Equal 1 @($zip.Pdfs|Where-Object{$_.Name -match '/Monthly QA/Confirmed/'}).Count 'Reviewed Monthly PDF belongs in the confirmed Monthly folder'
    Assert-Equal 1 @($zip.Pdfs|Where-Object{$_.Name -match '/Monthly QA/Pending Verification/'}).Count 'Unverified Monthly candidate stays in the pending Monthly folder'
    Assert-Equal 1 @($zip.Pdfs|Where-Object{$_.Name -match '/Other Reports/Acceptance Tests/'}).Count 'Acceptance PDF stays under Other Reports'
    Assert-Equal $zip.Names.Count @($zip.Names|Select-Object -Unique).Count 'No colliding ZIP entry names'
    Assert-Equal 0 @(Compare-Object @($rows.Hash|Sort-Object) @($zip.Pdfs.Hash|Sort-Object)).Count 'Every ZIP PDF hash matches the selected index row'
    foreach($row in $rows){
        Assert-True ($zip.Metadata.Contains([string]$row.Id)) 'Manifest preserves report identity'
        Assert-True ($zip.Metadata.Contains([string]$row.OriginalFileName)) 'Manifest preserves original filename'
        Assert-True ($zip.Metadata.ToUpperInvariant().Contains(([string]$row.Hash).ToUpperInvariant())) 'Manifest records exact content hash'
    }
    Assert-True (-not $zip.Metadata.Contains($rich.Config.ArchiveRoot)) 'Manifest omits absolute archive paths'
    foreach($source in $rich.SourceRoots){Assert-True (-not $zip.Metadata.Contains($source)) 'Manifest omits absolute scanner paths'}
    Assert-True ($zip.Metadata -notmatch '(?i)\b(QA compliant|clinically compliant|all QA complete)\b') 'Export makes no unsupported QA completion claim'
    Assert-Equal $before (Get-FixtureManifest (@($rich.Config.ArchiveRoot)+$rich.SourceRoots)) 'Source PDFs, archive PDFs, state, index, and history unchanged'
}
Run-Test 'Multiple checked years override the legacy year filter and intersect the chosen month'{
    $rows=@(Select-QaReports -Records $rich.Records -Year 2025 -Years @(2024,2025) -Month 12)
    Assert-Equal 7 $rows.Count 'December includes chosen years only'
    Assert-Equal 1 @($rows|Where-Object{$_.ReportDate -match '^2024-12-'}).Count 'Previous chosen year included'
    Assert-Equal 6 @($rows|Where-Object{$_.ReportDate -match '^2025-12-'}).Count 'Later chosen year included'
    Assert-Equal 0 @($rows|Where-Object{$_.ReportDate -match '^2025-11-'}).Count 'Month still intersects checked years'
    Assert-Equal 1 @(Select-QaReports -Records $rich.Records -Year 2025 -Years @(2024) -Month 12).Count 'Nonempty Years explicitly overrides legacy Year'
    Assert-Equal 6 @(Select-QaReports -Records $rich.Records -Year 2025 -Years @() -Month 12).Count 'Empty checked years preserves legacy Year behavior'
    Assert-Equal 6 @(Select-QaReports -Records $rich.Records -Years @(2025,2025) -Month 12).Count 'Repeated checked years cannot duplicate reports'
    $path=Join-Path $rich.Output 'December-two-years.zip'
    $result=Invoke-QaExport -Config $rich.Config -RecordIds @($rows.Id) -DestinationPath $path
    Assert-Equal 7 $result.Summary.Exported 'Every report matching both selected years exports'
    Assert-Equal 0 @(Compare-Object @($rows.Hash|Sort-Object) @((Get-ZipEvidence $path).Pdfs.Hash|Sort-Object)).Count 'Multi-year ZIP contains exactly the filtered PDFs'
}
Run-Test 'Offline HTML summary counts selected reports and links to every ZIP PDF safely'{
    $path=Join-Path $rich.Output 'December-2025.zip'
    $zip=Get-ZipEvidence $path
    Assert-Equal 9 $zip.Names.Count 'Six PDFs plus CSV, ReadMe, and offline HTML summary'
    Assert-True ($zip.Names -contains 'QA Report Summary.html') 'Readable summary included at ZIP root'
    $html=Get-ZipFileText $path 'QA Report Summary.html'
    Assert-True ($html -match '(?is)<!doctype html>.*<html\b.*</html>') 'Summary is a standalone HTML document'
    Assert-True ($html -match '<strong>6</strong><span>Selected reports</span>') 'Summary selected-report total is exact'
    foreach($label in @('Years','Months','Scanners','QA categories')){Assert-True ($html.Contains('<h2>'+ $label +'</h2>')) ('Count table exists for '+$label)}
    Assert-True ($html -match '<td>2025</td><td class="number">6</td>') 'Year count is exact'
    Assert-True ($html -match '<td>December 2025</td><td class="number">6</td>') 'Month count is exact'
    Assert-True ($html -match '<td>CT Edge</td><td class="number">3</td>') 'Scanner count is exact'
    Assert-True ($html -match '<td>Monthly QA - Pending Verification</td><td class="number">1</td>') 'Pending count remains distinct in offline summary'
    $links=@([regex]::Matches($html,'(?i)\bhref\s*=\s*["'']([^"'']+)["'']')|ForEach-Object{[Uri]::UnescapeDataString([Net.WebUtility]::HtmlDecode($_.Groups[1].Value))})
    $pdfLinks=@($links|Where-Object{$_ -match '(?i)\.pdf$'})
    Assert-Equal 6 $pdfLinks.Count 'One PDF link per selected report'
    Assert-Equal 6 @($pdfLinks|Select-Object -Unique).Count 'Duplicate sessions have distinct PDF links'
    Assert-Equal 0 @(Compare-Object @($pdfLinks|Sort-Object) @($zip.Pdfs.Name|Sort-Object)).Count 'Every PDF link resolves to exactly one actual ZIP PDF entry'
    foreach($link in $links){
        if($link.StartsWith('#')){Assert-True ($html.Contains('id="'+$link.Substring(1)+'"')) 'Internal navigation fragment exists'}
        else{Assert-True ($zip.Names -contains $link) 'Every local summary link resolves to an included ZIP entry'}
    }
    Assert-True ($html -notmatch '(?i)<script\b|<iframe\b|<object\b|<embed\b|<base\b|<[^>]+\bon\w+\s*=') 'No scripts, embedded objects, or inline event handlers'
    Assert-True ($html -notmatch '(?i)(?:href|src)\s*=\s*["''](?:https?:|//|javascript:|data:)') 'No external resources or active links'
    Assert-True (-not $html.Contains($rich.Config.ArchiveRoot)) 'HTML omits machine archive paths'
    foreach($source in $rich.SourceRoots){Assert-True (-not $html.Contains($source)) 'HTML omits scanner source paths'}
    Assert-True ($html -match 'do not establish.*clinical QA|do not establish.*every report') 'Summary explains the limits of its counts'
}
Run-Test 'Offline HTML escapes malicious display text and URI-encodes PDF link segments'{
    $record=$rich.Records[0]|Select-Object *
    $record.OriginalFileName='<script>alert(1)</script>.pdf'
    $manifest=@([pscustomobject]@{RecordId=$record.Id;Scanner='CT <img src=x onerror=alert(1)>';ReportTitle='QA <script>alert(2)</script>';OriginalFileName=$record.OriginalFileName;ExportPath='CT Edge/2025/12 December/QA & Review/file #1.pdf';QACategory='Pending & <review>';ConfirmedComponents='';Hash=$record.Hash;ReportDate=$record.ReportDate;ReportTime=$record.ReportTime})
    $module=Get-Module Reports|Select-Object -First 1
    $html=& $module {param($Records,$Manifest) Get-QaExportHtml -Records $Records -Manifest $Manifest} @($record) $manifest
    Assert-True ($html -notmatch '(?i)<script\b|<img\b|<review\b|<[^>]+\bon\w+\s*=') 'Malicious text cannot create HTML elements or event handlers'
    Assert-True ($html.Contains('&lt;script&gt;alert(1)&lt;/script&gt;.pdf')) 'Original filename is HTML-escaped'
    Assert-True ($html.Contains('QA &lt;script&gt;alert(2)&lt;/script&gt;')) 'Report title is HTML-escaped'
    Assert-True ($html.Contains('Pending &amp; &lt;review&gt;')) 'Category text is HTML-escaped'
    $match=[regex]::Match($html,'(?i)\bhref\s*=\s*["'']([^"'']+)["'']')
    Assert-True $match.Success 'Relative PDF link exists'
    $href=[Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
    Assert-True ($href.Contains('%23') -and $href.Contains('%26') -and $href.Contains('%20')) 'Filename and folder URI components encoded'
    Assert-Equal $manifest[0].ExportPath ([Uri]::UnescapeDataString($href)) 'Encoded PDF link resolves to exact relative export path'
}
Run-Test 'Archived PDFs can be exported while all scanner source folders are unavailable'{
    $f=New-ExportFixture 'OfflineExport'
    $before=Get-FixtureManifest (@($f.Config.ArchiveRoot)+$f.SourceRoots)
    foreach($s in $f.Config.Sources){$s.Path=Join-Path $TestRoot ('Unavailable-'+$s.Scanner)}
    $path=Join-Path $f.Output 'offline.zip'
    $result=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path
    Assert-Equal 1 $result.Summary.Exported 'Existing archived report exported offline'
    Assert-Equal $f.Records[0].Hash (Get-ZipEvidence $path).Pdfs[0].Hash 'Offline export hash verified'
    Assert-Equal $before (Get-FixtureManifest (@($f.Config.ArchiveRoot)+$f.SourceRoots)) 'Offline export changes no saved archive/source bytes'
}
Run-Test 'Exported Monthly coverage uses selected PDFs rather than the full archive and preserves component evidence'{
    $cfg=New-TestConfig 'SelectedMonthlyComponentCoverage'
    $cfg.Sources[0].MonthlyChecklist=@('MTF','Slice thickness')
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy' '2025-12-05' '06-00-00' 76000)
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy' '2025-12-05' '07-00-00' 77000)
    [void](Import-Fixture $cfg)
    $rows=@((Get-QaDashboard -Config $cfg).Records|Sort-Object OriginalFileName)
    $decisions=@(
        [pscustomobject]@{RecordId=$rows[0].Id;Category='Monthly_QA';Reviewer='Synthetic component reviewer';Reason='Reviewed MTF in first PDF';ConfirmedComponents=@('MTF')},
        [pscustomobject]@{RecordId=$rows[1].Id;Category='Monthly_QA';Reviewer='Synthetic component reviewer';Reason='Reviewed slice thickness in second PDF';ConfirmedComponents=@('Slice thickness')}
    )
    [void](Invoke-QaOperation -Config $cfg -Mode Reclassify -Decisions $decisions)
    $rows=@((Get-QaDashboard -Config $cfg).Records|Sort-Object OriginalFileName)
    $coverage=@(Get-QaMonthlyCoverage -Config $cfg -Records $rows -Months @('2025-12')|Where-Object{$_.Scanner -eq 'CT_Edge'})[0]
    Assert-Equal 'Complete' $coverage.Status 'The full archive has both reviewed components across two separate PDFs'
    $before=Get-FixtureManifest (@($cfg.ArchiveRoot)+@($cfg.Sources|ForEach-Object{$_.Path}))
    $out=Join-Path $TestRoot 'SelectedMonthlyComponentExports';[void][IO.Directory]::CreateDirectory($out)
    $partialPath=Join-Path $out 'Only-MTF.zip'
    [void](Invoke-QaExport -Config $cfg -RecordIds @($rows[0].Id) -DestinationPath $partialPath)
    $partial=Get-ZipFileText $partialPath 'QA Report Summary.html'
    Assert-True ($partial.Contains('Some configured components are not represented')) 'One selected PDF remains partial despite complete evidence elsewhere in the archive'
    Assert-True (-not $partial.Contains('All configured components represented in these selected reports')) 'Unselected evidence cannot make selected coverage complete'
    Assert-True ($partial -match '</td><td>MTF</td><td>Slice thickness</td>') 'Selected coverage distinguishes confirmed MTF from the component not selected'
    $partialCsv=@((Get-ZipFileText $partialPath 'Report list.csv')|ConvertFrom-Csv)
    Assert-Equal 1 $partialCsv.Count 'Partial selection CSV has one exact report row'
    Assert-Equal 'MTF' $partialCsv[0].ConfirmedComponents 'CSV preserves the reviewed component of the selected report'
    $completePath=Join-Path $out 'Both-Components.zip'
    [void](Invoke-QaExport -Config $cfg -RecordIds @($rows.Id) -DestinationPath $completePath)
    $complete=Get-ZipFileText $completePath 'QA Report Summary.html'
    Assert-True ($complete.Contains('All configured components represented in these selected reports')) 'Selected union of both reviewed PDFs is complete for the configured checklist'
    Assert-True ($complete.Contains('not an assessment of the full archive') -and $complete.Contains('clinical compliance conclusion')) 'Summary explains selected-evidence scope rather than making a clinical compliance claim'
    $completeCsv=@((Get-ZipFileText $completePath 'Report list.csv')|ConvertFrom-Csv)
    Assert-Equal 2 $completeCsv.Count 'Each reviewed component PDF remains a separate report row'
    Assert-Equal 1 @($completeCsv|Where-Object{$_.ConfirmedComponents -eq 'MTF'}).Count 'First report component preserved separately'
    Assert-Equal 1 @($completeCsv|Where-Object{$_.ConfirmedComponents -eq 'Slice thickness'}).Count 'Second report component preserved separately'
    Assert-Equal 0 @(Compare-Object @($rows.Hash|Sort-Object) @((Get-ZipEvidence $completePath).Pdfs.Hash|Sort-Object)).Count 'Component summary export still contains exact verified PDF bytes'
    Assert-Equal $before (Get-FixtureManifest (@($cfg.ArchiveRoot)+@($cfg.Sources|ForEach-Object{$_.Path}))) 'Component exports do not modify archive, review evidence, source files, or activity history'
}
Run-Test 'An empty selection cannot produce an empty misleading ZIP'{
    $f=New-ExportFixture 'EmptySelection';$path=Join-Path $f.Output 'empty.zip';$rejected=$false
    try{$r=Invoke-QaExport -Config $f.Config -RecordIds @() -DestinationPath $path;$rejected=($r.Summary.Failed -gt 0 -or $r.Summary.Cancelled)}catch{$rejected=$true}
    Assert-True $rejected 'Empty selection rejected'
    Assert-NoExportFile $f $path
}
Run-Test 'Unknown report IDs cannot silently produce an incomplete export'{
    $f=New-ExportFixture 'UnknownId';$path=Join-Path $f.Output 'unknown.zip';$rejected=$false
    try{$r=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records[0].Id,('F'*64)) -DestinationPath $path;$rejected=($r.Summary.Failed -gt 0 -or $r.Summary.Cancelled)}catch{$rejected=$true}
    Assert-True $rejected 'Unknown selected identity rejected'
    Assert-NoExportFile $f $path
}
Run-Test 'Repeated selected IDs are refused or safely deduplicated'{
    $f=New-ExportFixture 'DuplicateIds';$path=Join-Path $f.Output 'duplicate-ids.zip'
    $result=$null;$rejected=$false
    try{$result=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records[0].Id,$f.Records[0].Id) -DestinationPath $path}catch{$rejected=$true}
    if($rejected){Assert-NoExportFile $f $path}else{
        Assert-Equal 1 $result.Summary.Exported 'Repeated ID exported once'
        Assert-Equal 1 (Get-ZipEvidence $path).Pdfs.Count 'ZIP contains one PDF for one report identity'
    }
}
Run-Test 'A corrupted archived PDF aborts export without finalizing a ZIP'{
    $f=New-ExportFixture 'CorruptSelected';$path=Join-Path $f.Output 'corrupt.zip'
    $bytes=[IO.File]::ReadAllBytes($f.Records[0].DestinationPath);$bytes[100]=[byte]($bytes[100] -bxor 1);[IO.File]::WriteAllBytes($f.Records[0].DestinationPath,$bytes)
    $before=Get-FixtureManifest (@($f.Config.ArchiveRoot)+$f.SourceRoots)
    $rejected=$false
    try{$result=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path;$rejected=($result.Summary.Failed -gt 0)}catch{$rejected=$true}
    Assert-True $rejected 'Corrupt selected report clearly rejected'
    Assert-NoExportFile $f $path
    Assert-Equal $before (Get-FixtureManifest (@($f.Config.ArchiveRoot)+$f.SourceRoots)) 'Export does not repair or alter archive/source files'
}
Run-Test 'A missing archived PDF aborts export without finalizing a ZIP'{
    $f=New-ExportFixture 'MissingSelected';$path=Join-Path $f.Output 'missing.zip'
    [IO.File]::Delete($f.Records[0].DestinationPath)
    $rejected=$false
    try{$result=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path;$rejected=($result.Summary.Failed -gt 0)}catch{$rejected=$true}
    Assert-True $rejected 'Missing selected report clearly rejected'
    Assert-NoExportFile $f $path
}
Run-Test 'Export never overwrites an existing ZIP'{
    $f=New-ExportFixture 'ExistingZip';$path=Join-Path $f.Output 'existing.zip'
    [IO.File]::WriteAllText($path,'Existing synthetic output must remain untouched')
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;$rejected=$false
    try{$r=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path;$rejected=($r.Summary.Failed -gt 0 -or $r.Summary.Cancelled)}catch{$rejected=$true}
    Assert-True $rejected 'Existing destination rejected'
    Assert-Equal $hash (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash 'Existing ZIP bytes unchanged'
}
Run-Test 'Output inside Reports, archive internals, or scanner sources is rejected before writing'{
    $f=New-ExportFixture 'ProtectedDestinations'
    [void][IO.Directory]::CreateDirectory((Join-Path $f.Config.ArchiveRoot 'Browse Reports'))
    $before=Get-FixtureManifest (@($f.Config.ArchiveRoot)+$f.SourceRoots)
    $paths=@((Join-Path $f.Config.ArchiveRoot 'Reports/bad.zip'),(Join-Path $f.Config.ArchiveRoot '.ctqa/bad.zip'),(Join-Path $f.Config.ArchiveRoot 'Browse Reports/bad.zip'),(Join-Path $f.SourceRoots[0] 'bad.zip'))
    foreach($path in $paths){
        $rejected=$false
        try{$r=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path;$rejected=($r.Summary.Failed -gt 0 -or $r.Summary.Cancelled)}catch{$rejected=$true}
        Assert-True $rejected ('Protected output path rejected: '+$path)
        Assert-True (-not [IO.File]::Exists($path)) 'Protected destination not written'
    }
    Assert-Equal $before (Get-FixtureManifest (@($f.Config.ArchiveRoot)+$f.SourceRoots)) 'Protected destination attempts change no source/archive files'
}
Run-Test 'A linked output directory cannot redirect the export to another folder'{
    $f=New-ExportFixture 'LinkedOutput'
    $target=Join-Path $TestRoot 'LinkedOutputTarget';[void][IO.Directory]::CreateDirectory($target)
    $link=Join-Path $f.Output 'redirect';New-TestDirectoryLink $link $target
    $path=Join-Path $link 'redirected.zip';$rejected=$false
    try{$r=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path;$rejected=($r.Summary.Failed -gt 0 -or $r.Summary.Cancelled)}catch{$rejected=$true}
    Assert-True $rejected 'Linked output parent rejected'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $target -Recurse -File -Force).Count 'Linked output target unchanged'
}
Run-Test 'A linked archived report folder is rejected even when its PDF hash matches'{
    $f=New-ExportFixture 'LinkedReport';$path=Join-Path $f.Output 'linked-report.zip'
    $parent=[IO.Path]::GetDirectoryName($f.Records[0].DestinationPath)
    $target=Join-Path $TestRoot 'LinkedReportTarget'
    [IO.Directory]::Move($parent,$target);New-TestDirectoryLink $parent $target
    $rejected=$false
    try{$r=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path;$rejected=($r.Summary.Failed -gt 0 -or $r.Summary.Cancelled)}catch{$rejected=$true}
    Assert-True $rejected 'Linked report parent rejected'
    Assert-NoExportFile $f $path
    Assert-Equal $f.Records[0].Hash (Get-FileHash -LiteralPath (Join-Path $target ([IO.Path]::GetFileName($f.Records[0].DestinationPath))) -Algorithm SHA256).Hash 'Linked target bytes unchanged'
}
Run-Test 'Tampered report paths cannot escape the archive during export'{
    $f=New-ExportFixture 'EscapedRecord';$path=Join-Path $f.Output 'escaped-record.zip'
    $statePath=Join-Path $f.Config.ArchiveRoot '.ctqa/state.json';$state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
    $outside=Join-Path $TestRoot 'OutsideExportRecord.pdf';[IO.File]::Copy($f.Records[0].DestinationPath,$outside)
    $state.Records[0].RelativePath='../../OutsideExportRecord.pdf';$state.Records[0].DestinationPath=$outside
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($true))
    $hash=(Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash;$rejected=$false
    try{$r=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path;$rejected=($r.Summary.Failed -gt 0 -or $r.Summary.Cancelled)}catch{$rejected=$true}
    Assert-True $rejected 'Escaped archive record rejected'
    Assert-NoExportFile $f $path
    Assert-Equal $hash (Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash 'External PDF unchanged'
}
Run-Test 'Malicious original filenames never create ZIP traversal entries'{
    $f=New-ExportFixture 'MaliciousEntryName';$path=Join-Path $f.Output 'malicious-name.zip'
    $statePath=Join-Path $f.Config.ArchiveRoot '.ctqa/state.json';$state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
    $state.Records[0].OriginalFileName='../../escape.pdf'
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($true))
    $rejected=$false
    try{$r=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path;$rejected=($r.Summary.Failed -gt 0 -or $r.Summary.Cancelled)}catch{$rejected=$true}
    if($rejected){Assert-NoExportFile $f $path}else{
        $zip=Get-ZipEvidence $path
        Assert-Equal 1 $zip.Pdfs.Count 'Sanitized export contains only the selected PDF'
        Assert-Equal 0 @($zip.Names | Where-Object { $_ -match '(?:^|[\\/])\.\.(?:[\\/]|$)' }).Count 'No traversal name generated'
    }
    Assert-True (-not [IO.File]::Exists((Join-Path $TestRoot 'escape.pdf'))) 'No escaped file written outside export'
}
Run-Test 'An active archive writer lock blocks export and leaves no finalized ZIP'{
    $f=New-ExportFixture 'WriterLock';$path=Join-Path $f.Output 'locked.zip'
    $lock=[IO.File]::Open((Join-Path $f.Config.ArchiveRoot '.ctqa/archive.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        $rejected=$false
        try{$r=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path;$rejected=($r.Summary.Failed -gt 0 -or $r.Summary.Cancelled)}catch{$rejected=$true}
        Assert-True $rejected 'Export rejected while archive writer holds lock'
        Assert-NoExportFile $f $path
    }finally{$lock.Dispose()}
    [void](Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path)
    Assert-Equal 1 (Get-ZipEvidence $path).Pdfs.Count 'Export succeeds after archive lock released'
}
Run-Test 'Cancellation after the first written export buffer removes the partial ZIP and permits a safe retry'{
    $f=New-ExportFixture 'CancelDuringExport'
    [void](Add-Report $f.Config 'CT_Edge' 'Quality_Daily' '2025-12-02' '07-00-00' 3400000)
    [void](Invoke-QaOperation -Config $f.Config -Mode Update)
    $row=@((Get-QaDashboard -Config $f.Config).Records|Where-Object{$_.OriginalFileName -match '07-00-00'})[0]
    $before=Get-FixtureManifest (@($f.Config.ArchiveRoot)+$f.SourceRoots)
    $path=Join-Path $f.Output 'cancelled.zip'
    $module=Get-Module Reports|Select-Object -First 1
    $original=& $module {Get-Item Function:Test-QaExportCancelled|Select-Object -ExpandProperty ScriptBlock}
    $progress=[hashtable]::Synchronized(@{Cancel=$false;Message='Preparing';Percent=0})
    try{
        & $module {
            $script:ExportTestBufferChecks=0
            Set-Item Function:script:Test-QaExportCancelled -Value {
                param($Progress)
                if([string]$Progress.Message -like 'Exporting*'){
                    $script:ExportTestBufferChecks++
                    if($script:ExportTestBufferChecks -ge 2){$Progress.Cancel=$true}
                }
                return [bool]$Progress.Cancel
            }
        }
        $result=Invoke-QaExport -Config $f.Config -RecordIds @($row.Id) -DestinationPath $path -Progress $progress
        $checks=& $module {$script:ExportTestBufferChecks}
        Assert-True ($checks -ge 2) 'Cancellation reached the second export buffer after the first was written'
        Assert-True ([bool]$result.Summary.Cancelled) 'Cancelled export is explicitly identified'
        Assert-Equal 0 $result.Summary.Exported 'No incomplete PDF is reported as exported'
        Assert-NoExportFile $f $path
        Assert-Equal $before (Get-FixtureManifest (@($f.Config.ArchiveRoot)+$f.SourceRoots)) 'Cancellation changes no source, archived PDF, index, state, or activity history'
    }finally{& $module {param($Body) Set-Item Function:script:Test-QaExportCancelled -Value $Body} $original}
    $result=Invoke-QaExport -Config $f.Config -RecordIds @($row.Id) -DestinationPath $path
    Assert-Equal 1 $result.Summary.Exported 'Retry exports the complete selected report'
    Assert-Equal $row.Hash (Get-ZipEvidence $path).Pdfs[0].Hash 'Retried ZIP PDF matches the index hash'
}
Run-Test 'Tampered scanner labels cannot create ZIP traversal paths'{
    $f=New-ExportFixture 'MaliciousScanner';$path=Join-Path $f.Output 'scanner-traversal.zip'
    $statePath=Join-Path $f.Config.ArchiveRoot '.ctqa/state.json';$state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
    $state.Records[0].Scanner='../../outside'
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($true))
    $rejected=$false
    try{$r=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path;$rejected=($r.Summary.Failed -gt 0)}catch{$rejected=$true}
    Assert-True $rejected 'Unrecognized and unsafe scanner identity rejected'
    Assert-NoExportFile $f $path
}
Run-Test 'A Monthly category without review evidence cannot be exported as confirmed Monthly QA'{
    $f=New-ExportFixture 'UnconfirmedMonthly';$path=Join-Path $f.Output 'unreviewed-monthly.zip'
    $statePath=Join-Path $f.Config.ArchiveRoot '.ctqa/state.json';$state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
    $state.Records[0].Category='Monthly_QA';$state.Records[0].ConfirmedBy='';$state.Records[0].ConfirmedAt=''
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($true))
    $rejected=$false
    try{$r=Invoke-QaExport -Config $f.Config -RecordIds @($f.Records.Id) -DestinationPath $path;$rejected=($r.Summary.Failed -gt 0)}catch{$rejected=$true}
    Assert-True $rejected 'No reviewed Monthly evidence means no confirmed Monthly export'
    Assert-NoExportFile $f $path
}
Run-Test 'Static UI controls, filter bindings, export selection, and worker source remain connected'{
    $uiPath=Join-Path $ProductRoot 'App/Start.ps1';$xamlPath=Join-Path $ProductRoot 'App/MainWindow.xaml'
    $ui=[IO.File]::ReadAllText($uiPath);$doc=New-Object Xml.XmlDocument;$doc.Load($xamlPath)
    $ns=New-Object Xml.XmlNamespaceManager($doc.NameTable);$ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
    $names=@($doc.SelectNodes('//*[@x:Name]',$ns)|ForEach-Object{$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')})
    foreach($name in @('ScannerFilter','YearFilter','ChooseYearsButton','MonthFilter','CategoryFilter','ReportSearch','ClearFiltersButton','ExportReportsButton','OpenExportFolderButton','ExportResultText')){
        Assert-True ($names -contains $name) ('Real XAML contains control '+$name)
        Assert-True ($ui.Contains($name)) ('PowerShell UI refers to control '+$name)
    }
    Assert-True ($ui -match 'ExportReportsButton\.Add_Click\(\{Export-MatchingReports\}\)') 'Export button event is bound'
    Assert-True ($ui -match 'OpenExportFolderButton\.Add_Click\(\{Open-ExportFolder\}\)') 'Completed export folder action is bound'
    Assert-True ($ui -match '\.Add_SelectionChanged\(\{Refresh-Reports\}\)') 'Filter selection changes refresh the reports view'
    Assert-True ($ui -match 'ChooseYearsButton\.Add_Click\(\{Choose-ReportYears\}\)') 'Multiple-year chooser button is bound'
    Assert-True ($ui -match 'New-Object System\.Windows\.Controls\.CheckBox') 'Year chooser creates actual WPF checkbox controls'
    Assert-True ($ui -match '-Years \$filter\.Years') 'Checked-year array is forwarded into the report filter API'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$tokens,[ref]$errors)
    Assert-Equal 0 @($errors).Count 'UI script parses in the current runtime'
    $exportFunction=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Export-MatchingReports'},$true))[0]
    Assert-True ($exportFunction.Extent.Text -match '\$script:FilteredReports') 'Export uses the matching rows displayed by the active filters'
    Assert-True ($exportFunction.Extent.Text -match 'RecordIds=\$ids') 'Export worker receives explicit selected identities'
    $worker=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match '^param\(\$appRoot,\$config,\$mode'},$true))
    Assert-Equal 1 $worker.Count 'Exactly one concrete worker source string found'
    $workerTokens=$null;$workerErrors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($worker[0].Value,[ref]$workerTokens,[ref]$workerErrors)
    Assert-Equal 0 @($workerErrors).Count 'Embedded background worker source parses'
    Assert-True ($worker[0].Value -match 'Invoke-QaExport' -and $worker[0].Value -match 'Invoke-QaBrowseRefresh') 'Worker dispatch includes both requested file operations'
}

$failed=@($script:Results|Where-Object{$_.Result -eq 'FAIL'}).Count
$skipped=@($script:Results|Where-Object{$_.Result -eq 'SKIP'}).Count
$passed=@($script:Results|Where-Object{$_.Result -eq 'PASS'}).Count
$report=[pscustomobject]@{Product='CT QA Manager Pro';Suite='Reports filters and ZIP export';TimestampUtc=[datetime]::UtcNow.ToString('o');Runtime=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1);Tests=$script:Results.Count;Assertions=$script:Assertions;Passed=$passed;Skipped=$skipped;Failed=$failed;Results=@($script:Results.ToArray());FixturesKept=[bool]$KeepFixtures}
if($OutputPath){$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
Write-Host ('Result: '+$passed+'/'+$script:Results.Count+' tests passed; '+$script:Assertions+' assertions; '+$skipped+' skipped; PowerShell '+$PSVersionTable.PSVersion)
if($KeepFixtures){Write-Host ('Synthetic fixtures: '+$TestRoot)}else{Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue}
if($failed -gt 0){exit 1}
