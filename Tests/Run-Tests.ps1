# Run with Windows PowerShell 5.1. No Pester or additional modules required.
[CmdletBinding()]
param([string]$OutputPath = '', [switch]$KeepFixtures)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProductRoot = Split-Path -Parent $PSScriptRoot
$ModulePath = Join-Path $ProductRoot 'App/Archive.psm1'
Import-Module $ModulePath -Force
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('CTQA_Synthetic_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestRoot)
$script:Results = New-Object 'System.Collections.Generic.List[object]'
$script:Assertions = 0
function Assert-True([bool]$Condition,[string]$Message) {
    $script:Assertions++
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
}
function Assert-Equal($Expected,$Actual,[string]$Message) {
    Assert-True ([string]$Expected -ceq [string]$Actual) ($Message + '; expected=' + [string]$Expected + '; actual=' + [string]$Actual)
}
function Run-Test([string]$Name,[scriptblock]$Body) {
    try {
        & $Body
        $script:Results.Add([pscustomobject]@{ Name=$Name; Result='PASS'; Details='' })
        Write-Host ('PASS  ' + $Name)
    } catch {
        $script:Results.Add([pscustomobject]@{ Name=$Name; Result='FAIL'; Details=$_.Exception.Message + ' ' + $_.ScriptStackTrace })
        Write-Host ('FAIL  ' + $Name + ': ' + $_.Exception.Message)
    }
}
function New-TestConfig([string]$Name) {
    $root = Join-Path $TestRoot $Name
    [void][IO.Directory]::CreateDirectory($root)
    $cfg = Get-QaDefaultConfig -AppRoot $root
    $cfg.ArchiveRoot = Join-Path $root 'Archive'
    $cfg.LookbackDays = 3
    $cfg.MonthlyLookbackMonths = 2
    $cfg.MinimumFileAgeSeconds = 0
    foreach ($s in $cfg.Sources) {
        $s.Path = Join-Path $root $s.Scanner
        [void][IO.Directory]::CreateDirectory($s.Path)
        $s.ActiveFrom = (Get-Date).Date.AddDays(-3).ToString('yyyy-MM-dd')
    }
    return $cfg
}
function New-TestPdf([string]$Path,[int]$Size=1800,[string]$Text='Synthetic QA fixture') {
    # Valid, one-page, uncompressed PDF; size padding is a PDF comment.
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append("%PDF-1.4`n")
    $offsets = New-Object 'System.Collections.Generic.List[int]'
    $objects = @(
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
    )
    $escaped = $Text.Replace('\','\\').Replace('(','\(').Replace(')','\)')
    $stream = 'BT /F1 12 Tf 48 740 Td (' + $escaped + ") Tj ET`n"
    $objects += ('<< /Length ' + [Text.Encoding]::ASCII.GetByteCount($stream) + " >>`nstream`n" + $stream + 'endstream')
    for ($i=0;$i -lt $objects.Count;$i++) {
        $offsets.Add([Text.Encoding]::ASCII.GetByteCount($builder.ToString()))
        [void]$builder.Append(($i+1).ToString() + " 0 obj`n" + $objects[$i] + "`nendobj`n")
    }
    $padding = [math]::Max(0,$Size - $builder.Length - 300)
    if ($padding -gt 0) { [void]$builder.Append('%' + ('x' * $padding) + "`n") }
    $xref = [Text.Encoding]::ASCII.GetByteCount($builder.ToString())
    [void]$builder.Append("xref`n0 6`n0000000000 65535 f `n")
    foreach ($offset in $offsets) { [void]$builder.Append($offset.ToString('0000000000') + " 00000 n `n") }
    [void]$builder.Append("trailer`n<< /Size 6 /Root 1 0 R >>`nstartxref`n" + $xref + "`n%%EOF`n")
    [IO.File]::WriteAllText($Path,$builder.ToString(),[Text.Encoding]::ASCII)
    (Get-Item -LiteralPath $Path).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-10)
    return $Path
}
function Add-Report($Config,[string]$Scanner,[string]$Kind,[string]$Date,[string]$Time='06-00-00',[int]$Size=1800,[string]$Subfolder='') {
    $source = @($Config.Sources | Where-Object { $_.Scanner -eq $Scanner })[0]
    $dir = $source.Path
    if ($Subfolder) { $dir = Join-Path $dir $Subfolder }
    return New-TestPdf -Path (Join-Path $dir ($Kind + '_' + $Date + '_' + $Time + '.pdf')) -Size $Size
}
function Import-Fixture($Config) {
    $preview = Invoke-QaOperation -Config $Config -Mode Preview
    return Invoke-QaOperation -Config $Config -Mode Import -Plan $preview.Plan
}
$Yesterday = (Get-Date).Date.AddDays(-1).ToString('yyyy-MM-dd')
$TwoDaysAgo = (Get-Date).Date.AddDays(-2).ToString('yyyy-MM-dd')
Run-Test 'All product scripts parse; PowerShell 5.1 compatibility evidence is explicit' {
    $files = @(Get-ChildItem -LiteralPath $ProductRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') })
    Assert-True ($files.Count -ge 3) 'Application scripts present'
    foreach ($file in $files) {
        $tokens=$null; $errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        Assert-Equal 0 @($errors).Count ('Parser errors in ' + $file.Name)
        $text = [IO.File]::ReadAllText($file.FullName)
        Assert-True ($text -notmatch '(?m)^\s*#requires\s+-Version\s+[6-9]') ('No newer runtime requirement: ' + $file.Name)
    }
}
Run-Test 'Preview never copies source PDFs or creates the archive' {
    $cfg = New-TestConfig 'Preview'
    $src = Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday
    $before = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
    $preview = Invoke-QaOperation -Config $cfg -Mode Preview
    Assert-True ($null -ne $preview.Plan) 'Preview provides confirmation plan'
    Assert-True (-not [IO.Directory]::Exists($cfg.ArchiveRoot)) 'Preview leaves archive absent'
    Assert-Equal $before (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash 'Source untouched'
}
Run-Test 'Partial scanner availability preserves accessible reports and distinct sessions' {
    $cfg = New-TestConfig 'AvailabilitySessions'
    $cfg.Sources[1].Path = Join-Path $TestRoot 'UnavailableShare'
    $a = Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '06-00-00'
    $b = Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '07-00-00'
    $c = Add-Report $cfg 'MDP_Building' 'Quality_Daily' $Yesterday '08-00-00'
    $before = @($a,$b,$c | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    [void](Import-Fixture $cfg)
    $dash = Get-QaDashboard -Config $cfg
    Assert-Equal 3 $dash.TotalReports 'Three independent reports archived'
    Assert-Equal 3 @($dash.Records.DestinationPath | Select-Object -Unique).Count 'Unique destinations'
    Assert-True (@($dash.Scanners | Where-Object { $_.Scanner -eq 'CT_Flash' -and $_.Status -ne 'Connected' -and $_.Status -ne 'OK' }).Count -gt 0) 'Flash unavailable reported'
    foreach ($r in $dash.Records) {
        Assert-True ([IO.File]::Exists($r.DestinationPath)) 'Destination exists'
        Assert-Equal $r.Hash (Get-FileHash -LiteralPath $r.DestinationPath -Algorithm SHA256).Hash 'Copied hash verified'
    }
    for ($i=0;$i -lt 3;$i++) { Assert-Equal $before[$i] (Get-FileHash -LiteralPath @($a,$b,$c)[$i] -Algorithm SHA256).Hash 'Scanner source unchanged' }
}
Run-Test 'Large generic and named Constancy reports require verification' {
    $cfg = New-TestConfig 'Classification'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy' $Yesterday '06-00-00' 76000)
    [void](Add-Report $cfg 'CT_Flash' 'Quality_Constancy' $Yesterday '06-00-00' 95000)
    [void](Add-Report $cfg 'MDP_Building' 'Quality_Constancy' $Yesterday '06-00-00' 95000)
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy_MTF' $Yesterday '07-00-00' 1600)
    [void](Import-Fixture $cfg)
    $rows = @((Get-QaDashboard -Config $cfg).Records)
    Assert-Equal 4 $rows.Count 'All monthly candidates retained'
    Assert-Equal 0 @($rows | Where-Object { $_.Category -eq 'Monthly_QA' }).Count 'No automatic Monthly confirmation'
    Assert-Equal 4 @($rows | Where-Object { $_.Category -eq 'Monthly_QA/Pending_Verification' }).Count 'Candidates staged for review'
}
Run-Test 'Repeated daily update is idempotent; changed source creates a retained revision' {
    $cfg = New-TestConfig 'Incremental'
    $src = Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday
    [void](Import-Fixture $cfg)
    $first = @((Get-QaDashboard -Config $cfg).Records)[0]
    $firstHash = $first.Hash
    $firstStamp = (Get-Item -LiteralPath $first.DestinationPath).LastWriteTimeUtc.Ticks
    $update = Invoke-QaOperation -Config $cfg -Mode Update
    Assert-Equal 1 (Get-QaDashboard -Config $cfg).TotalReports 'Repeated update adds no duplicates'
    Assert-Equal 0 $update.Summary.Copied 'Repeated update copies nothing'
    Assert-Equal 1 $update.Summary.Unchanged 'Repeated update uses metadata cache for unchanged report'
    Assert-Equal 0 $update.Summary.Verified 'Repeated update does not rehash an unchanged report'
    Assert-Equal 0 $update.Summary.NewOrChanged 'Repeated update finds no new or changed report'
    Assert-Equal $firstStamp (Get-Item -LiteralPath $first.DestinationPath).LastWriteTimeUtc.Ticks 'Unchanged destination not rewritten'
    [void](New-TestPdf -Path $src -Size 2300 -Text 'Revised synthetic QA fixture')
    [void](Invoke-QaOperation -Config $cfg -Mode Update)
    $rows = @((Get-QaDashboard -Config $cfg).Records)
    Assert-Equal 2 $rows.Count 'Changed content preserves both revisions'
    Assert-Equal $firstHash (Get-FileHash -LiteralPath $first.DestinationPath -Algorithm SHA256).Hash 'Original revision remains intact'
    Assert-Equal 2 @($rows.DestinationPath | Select-Object -Unique).Count 'Revisions never overwrite'
}
Run-Test 'Unavailable archive destination yields an actionable error without source changes' {
    $cfg = New-TestConfig 'UnavailableDestination'
    $src = Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday
    $blocking = Join-Path $TestRoot 'DestinationIsAFile'
    [IO.File]::WriteAllText($blocking,'Synthetic blocking file')
    $cfg.ArchiveRoot = Join-Path $blocking 'Archive'
    $hash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
    $failed=$false
    try { $result=Import-Fixture $cfg; $failed=($result.Summary.Failed -gt 0) } catch { $failed=$true }
    Assert-True $failed 'Unavailable destination is reported'
    Assert-Equal $hash (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash 'Source intact'
}
Run-Test 'Corrupt non-PDF input is rejected; no false successful archive record' {
    $cfg = New-TestConfig 'InvalidPdf'
    $bad = Join-Path $cfg.Sources[0].Path ('Quality_Daily_' + $Yesterday + '_06-00-00.pdf')
    [IO.File]::WriteAllText($bad,'NOT A PDF - synthetic invalid input')
    (Get-Item -LiteralPath $bad).LastWriteTimeUtc=[datetime]::UtcNow.AddMinutes(-10)
    [void](Import-Fixture $cfg)
    Assert-Equal 0 (Get-QaDashboard -Config $cfg).TotalReports 'Invalid PDF not indexed'
}
Run-Test 'Daily gaps distinguish an awaiting-classification report from absent evidence' {
    $cfg = New-TestConfig 'DailyGaps'
    $cfg.Sources[1].Path = Join-Path $TestRoot 'GapSourceUnavailable'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy' $Yesterday '06-00-00' 76000)
    [void](Add-Report $cfg 'MDP_Building' 'Quality_Daily' $Yesterday)
    [void](Import-Fixture $cfg)
    $dash=Get-QaDashboard -Config $cfg
    $messages = @($dash.Attention | ForEach-Object { $_.Type + ': ' + $_.Message }) -join "`n"
    Assert-True ($messages -match '(?i)(pending|verification|review|classification)') 'Pending classification identified'
    Assert-True ($messages -match '(?i)(unavailable|inaccessible|connection|offline)') 'Unavailable scanner distinguished'
    Assert-True ($messages -match '(?i)(no .*report|no report|daily.*found|archive.*gap)') 'Archive absence identified'
    Assert-True ($messages -notmatch '(?i)(noncompliant|non-compliant|clinical failure|QA was not performed)') 'No unsupported clinical claim'
}
Run-Test 'Integrity audit detects changed destination content even with preserved size' {
    $cfg = New-TestConfig 'Integrity'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday)
    [void](Import-Fixture $cfg)
    $row=@((Get-QaDashboard -Config $cfg).Records)[0]
    $bytes=[IO.File]::ReadAllBytes($row.DestinationPath)
    $bytes[100]=[byte]($bytes[100] -bxor 1)
    [IO.File]::WriteAllBytes($row.DestinationPath,$bytes)
    $audit=Invoke-QaOperation -Config $cfg -Mode Audit
    $dash=Get-QaDashboard -Config $cfg
    $evidence=($audit | ConvertTo-Json -Depth 15) + ($dash.Attention | ConvertTo-Json -Depth 10)
    Assert-True ($evidence -match '(?i)(integrity|hash|damaged|corrupt|mismatch|verification failed)') 'Hash failure reported'
    Assert-True (($audit.Summary.Failed -gt 0) -or (@($dash.Attention | Where-Object { $_.Type -match '(?i)integrity|copy|verify|error' }).Count -gt 0)) 'Audit does not report unconditional success'
}
Run-Test 'Review requires reviewer and reason; confirmed monthly survives an unchanged update' {
    $cfg=New-TestConfig 'Review'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy' $Yesterday '06-00-00' 76000)
    [void](Import-Fixture $cfg)
    $row=@((Get-QaDashboard -Config $cfg).Records)[0]
    $invalid=@([pscustomobject]@{RecordId=$row.Id;Category='Monthly_QA';Reviewer='';Reason=''})
    $rejected=$false
    try { [void](Invoke-QaOperation -Config $cfg -Mode Reclassify -Decisions $invalid) } catch { $rejected=$true }
    if (-not $rejected) { $rejected=(@((Get-QaDashboard -Config $cfg).Records | Where-Object { $_.Category -eq 'Monthly_QA' }).Count -eq 0) }
    Assert-True $rejected 'Empty reviewer cannot confirm Monthly QA'
    $decisions=@([pscustomobject]@{RecordId=$row.Id;Category='Monthly_QA';Reviewer='Synthetic reviewer';Reason='Synthetic reviewed monthly checklist fixture'})
    $preview=Invoke-QaOperation -Config $cfg -Mode ReclassifyPreview -Decisions $decisions
    Assert-Equal 0 @((Get-QaDashboard -Config $cfg).Records | Where-Object { $_.Category -eq 'Monthly_QA' }).Count 'Classification preview does not change state'
    [void](Invoke-QaOperation -Config $cfg -Mode Reclassify -Decisions $decisions)
    $confirmed=@((Get-QaDashboard -Config $cfg).Records | Where-Object { $_.Category -eq 'Monthly_QA' })
    Assert-Equal 1 $confirmed.Count 'Reviewed decision applied'
    Assert-Equal 'Synthetic reviewer' $confirmed[0].ConfirmedBy 'Reviewer recorded'
    Assert-True (-not [IO.File]::Exists($row.DestinationPath)) 'Former pending-category copy no longer appears in Reports'
    Assert-True ([IO.File]::Exists($confirmed[0].DestinationPath)) 'Current reviewed PDF exists'
    Assert-Equal $row.Hash (Get-FileHash -LiteralPath $confirmed[0].DestinationPath -Algorithm SHA256).Hash 'Current PDF preserves reviewed hash'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath (Join-Path $cfg.ArchiveRoot 'Reports') -Recurse -Filter '*.pdf' -File).Count 'Only current category PDF appears in Reports'
    $history=@(Get-ChildItem -LiteralPath (Join-Path $cfg.ArchiveRoot '.ctqa/reclassification-history') -Recurse -Filter '*.pdf' -File)
    Assert-Equal 1 $history.Count 'Prior PDF preserved in private classification history'
    Assert-Equal $row.Hash (Get-FileHash -LiteralPath $history[0].FullName -Algorithm SHA256).Hash 'History PDF preserves the original hash'
    [void](Invoke-QaOperation -Config $cfg -Mode Update)
    Assert-Equal 1 @((Get-QaDashboard -Config $cfg).Records | Where-Object { $_.Category -eq 'Monthly_QA' }).Count 'Unchanged update preserves reviewed classification'
}
Run-Test 'Unrecognized report date never invents daily or monthly coverage' {
    $cfg=New-TestConfig 'UnknownDate'
    [void](New-TestPdf -Path (Join-Path $cfg.Sources[0].Path 'unnamed-synthetic-report.pdf'))
    [void](Import-Fixture $cfg)
    $rows=@((Get-QaDashboard -Config $cfg).Records)
    Assert-Equal 1 $rows.Count 'Unrecognized PDF safely archived'
    Assert-Equal 'Needs_Review' $rows[0].Category 'Unknown report requires review'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$rows[0].ReportDate)) 'No date inferred from filesystem time'
}
Run-Test 'Duplicate basenames in different source folders preserve report identity' {
    $cfg=New-TestConfig 'DuplicateNames'
    $a=Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '06-00-00' 1800 'SessionA'
    $b=Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '06-00-00' 2300 'SessionB'
    [void](Import-Fixture $cfg)
    $rows=@((Get-QaDashboard -Config $cfg).Records)
    Assert-Equal 2 $rows.Count 'Both same-name source reports retained'
    Assert-Equal 2 @($rows.DestinationPath | Select-Object -Unique).Count 'Distinct safe archive paths'
    Assert-Equal 2 @($rows.Hash | Select-Object -Unique).Count 'Distinct source content preserved'
}
Run-Test 'Previewed files changed before confirmation are not silently imported' {
    $cfg=New-TestConfig 'StalePreview'
    $src=Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday
    $preview=Invoke-QaOperation -Config $cfg -Mode Preview
    [void](New-TestPdf -Path $src -Size 2600 -Text 'Changed after preview')
    $failed=$false
    try { $result=Invoke-QaOperation -Config $cfg -Mode Import -Plan $preview.Plan; $failed=($result.Summary.Failed -gt 0) } catch { $failed=$true }
    Assert-Equal 0 (Get-QaDashboard -Config $cfg).TotalReports 'Unapproved changed file not copied'
    Assert-True $failed 'Changed preview file gets a clear failure'
}
Run-Test 'Files appearing after setup preview are not imported without a fresh preview' {
    $cfg=New-TestConfig 'NewAfterPreview'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday)
    $preview=Invoke-QaOperation -Config $cfg -Mode Preview
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '07-00-00')
    try { [void](Invoke-QaOperation -Config $cfg -Mode Import -Plan $preview.Plan) } catch { }
    $rows=@((Get-QaDashboard -Config $cfg).Records)
    Assert-True (@($rows | Where-Object { $_.OriginalFileName -match '07-00-00' }).Count -eq 0) 'Unpreviewed report not imported'
}
Run-Test 'Scanner source and destination overlap is rejected before archive writes' {
    $cfg=New-TestConfig 'OverlapSourceParent'
    $cfg.ArchiveRoot=$cfg.Sources[0].Path
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday)
    $rejected=$false
    try { [void](Invoke-QaOperation -Config $cfg -Mode Preview) } catch { $rejected=$true }
    Assert-True $rejected 'Archive nested in source rejected'
    Assert-True (-not [IO.Directory]::Exists((Join-Path $cfg.ArchiveRoot '.ctqa'))) 'No archive control folder written in source'
    $cfg2=New-TestConfig 'OverlapReportsChild'
    $cfg2.Sources[0].Path=Join-Path $cfg2.ArchiveRoot 'Reports/CT_Edge'
    [void][IO.Directory]::CreateDirectory($cfg2.Sources[0].Path)
    [void](Add-Report $cfg2 'CT_Edge' 'Quality_Daily' $Yesterday)
    $rejected=$false
    try { [void](Invoke-QaOperation -Config $cfg2 -Mode Preview) } catch { $rejected=$true }
    Assert-True $rejected 'Source inside destination rejected'
}
Run-Test 'Changed report content cannot inherit prior reviewed Monthly confirmation' {
    $cfg=New-TestConfig 'ChangedAfterReview'
    $src=Add-Report $cfg 'CT_Edge' 'Quality_Constancy' $Yesterday '06-00-00' 76000
    [void](Import-Fixture $cfg)
    $row=@((Get-QaDashboard -Config $cfg).Records)[0]
    $decisions=@([pscustomobject]@{RecordId=$row.Id;Category='Monthly_QA';Reviewer='Synthetic reviewer';Reason='Reviewed original synthetic file only'})
    [void](Invoke-QaOperation -Config $cfg -Mode Reclassify -Decisions $decisions)
    [void](New-TestPdf -Path $src -Size 78000 -Text 'Changed source is not reviewed')
    [void](Invoke-QaOperation -Config $cfg -Mode Update)
    $rows=@((Get-QaDashboard -Config $cfg).Records)
    Assert-Equal 2 $rows.Count 'Source revision recorded separately'
    Assert-Equal 1 @($rows | Where-Object { $_.Category -eq 'Monthly_QA' }).Count 'Only original remains confirmed'
    Assert-Equal 1 @($rows | Where-Object { $_.Category -eq 'Monthly_QA/Pending_Verification' }).Count 'Changed content requires fresh review'
}
Run-Test 'Completed month with only pending evidence is never counted as confirmed Monthly QA' {
    $cfg=New-TestConfig 'MonthlyGaps'
    $month=(Get-Date).Date.AddDays(1-(Get-Date).Day).AddMonths(-1)
    $monthDate=$month.AddDays(14).ToString('yyyy-MM-dd')
    $monthPattern=[regex]::Escape($month.ToString('yyyy-MM')) + '|' + [regex]::Escape($month.ToString('MMMM'))
    foreach ($s in $cfg.Sources) { $s.ActiveFrom=$month.AddMonths(-1).ToString('yyyy-MM-dd') }
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy' $monthDate '06-00-00' 76000)
    [void](Import-Fixture $cfg)
    $dash=Get-QaDashboard -Config $cfg
    $monthly=@($dash.Attention | Where-Object { $_.Scanner -eq 'CT_Edge' -and $_.Message -match $monthPattern -and (($_.Type -match '(?i)monthly') -or ($_.Message -match '(?i)monthly')) })
    Assert-True ($monthly.Count -gt 0) 'Pending-only completed month has monthly attention'
    Assert-Equal 0 @($dash.Records | Where-Object { $_.Category -eq 'Monthly_QA' }).Count 'Pending cannot satisfy confirmed Monthly'
    $row=@($dash.Records)[0]
    $decisions=@([pscustomobject]@{RecordId=$row.Id;Category='Monthly_QA';Reviewer='Synthetic reviewer';Reason='Reviewed monthly fixture for completed month'})
    [void](Invoke-QaOperation -Config $cfg -Mode Reclassify -Decisions $decisions)
    $dash=Get-QaDashboard -Config $cfg
    $remaining=@($dash.Attention | Where-Object { $_.Scanner -eq 'CT_Edge' -and $_.Message -match $monthPattern -and $_.Message -match '(?i)no.*monthly.*confirm|no.*confirm.*monthly' })
    Assert-Equal 0 $remaining.Count 'Confirmed archive record closes only its monthly evidence gap'
}
Run-Test 'Cancellation during a real multi-buffer transfer preserves committed reports and retries safely' {
    $cfg=New-TestConfig 'InterruptedCopy'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday)
    [void](Import-Fixture $cfg)
    $originalRow=@((Get-QaDashboard -Config $cfg).Records)[0]
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '07-00-00' 3400000)
    $module=Get-Module Archive | Select-Object -First 1
    $originalCancel=& $module { Get-Item Function:Test-QaCancel | Select-Object -ExpandProperty ScriptBlock }
    $progress=[hashtable]::Synchronized(@{Cancel=$false;Message='';Percent=0})
    # Test-only replacement in this isolated session: cancel on the second buffer,
    # after the production FileStream has already written the first buffer.
    try {
        & $module {
            $script:TestCopyBufferChecks=0
            Set-Item Function:script:Test-QaCancel -Value {
                param($Progress)
                $duringCopy=@(Get-PSCallStack | Where-Object { $_.FunctionName -eq 'Copy-QaVerified' }).Count -gt 0
                if ($duringCopy) { $script:TestCopyBufferChecks++; if ($script:TestCopyBufferChecks -ge 2) { $Progress.Cancel=$true } }
                return ([bool]$Progress.Cancel)
            }
        }
        $result=Invoke-QaOperation -Config $cfg -Mode Update -Progress $progress
        $bufferChecks=& $module { $script:TestCopyBufferChecks }
        Assert-True ($bufferChecks -ge 2) 'Cancellation actually occurred after at least one written buffer'
        Assert-True ([bool]$result.Summary.Cancelled) 'Cancellation explicitly reported'
        Assert-Equal 1 (Get-QaDashboard -Config $cfg).TotalReports 'Incomplete report not indexed'
        Assert-Equal $originalRow.Hash (Get-FileHash -LiteralPath $originalRow.DestinationPath -Algorithm SHA256).Hash 'Committed report intact'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $cfg.ArchiveRoot '.ctqa/staging') -Filter '*.partial' -File).Count 'Cancelled staging bytes cleaned safely'
    } finally {
        & $module { param($Body) Set-Item Function:script:Test-QaCancel -Value $Body } $originalCancel
    }
    [void](Invoke-QaOperation -Config $cfg -Mode Update)
    Assert-Equal 2 (Get-QaDashboard -Config $cfg).TotalReports 'Next update retries and archives complete report'
}
Run-Test 'Commit interrupted after PDF installation recovers from transaction journal without duplicates' {
    $cfg=New-TestConfig 'InterruptedCommit'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday)
    [void](Import-Fixture $cfg)
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '07-00-00')
    $module=Get-Module Archive | Select-Object -First 1
    $originalSave=& $module { Get-Item Function:Save-QaState | Select-Object -ExpandProperty ScriptBlock }
    $failed=$false
    try {
        & $module {
            Set-Item Function:script:Save-QaState -Value {
                param($State,$Paths)
                if (@($State.Records).Count -gt 0) { throw 'Synthetic interruption before state commit' }
                throw 'Synthetic test expected a destination commit before metadata save'
            }
        }
        try { [void](Invoke-QaOperation -Config $cfg -Mode Update) } catch { $failed=$true }
    } finally {
        & $module { param($Body) Set-Item Function:script:Save-QaState -Value $Body } $originalSave
    }
    Assert-True $failed 'Metadata commit interruption observed'
    Assert-Equal 2 @(Get-ChildItem -LiteralPath (Join-Path $cfg.ArchiveRoot 'Reports') -Filter '*.pdf' -Recurse -File).Count 'Complete new destination exists before metadata commit'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $cfg.ArchiveRoot '.ctqa/transactions') -Filter '*.json' -File).Count -gt 0) 'Recovery journal retained'
    [void](Invoke-QaOperation -Config $cfg -Mode Update)
    $dash=Get-QaDashboard -Config $cfg
    Assert-Equal 2 $dash.TotalReports 'Recovered report indexed exactly once alongside existing report'
    Assert-Equal 2 @(Get-ChildItem -LiteralPath (Join-Path $cfg.ArchiveRoot 'Reports') -Filter '*.pdf' -Recurse -File).Count 'No duplicate destination on recovery'
    Assert-Equal $dash.Records[0].Hash (Get-FileHash -LiteralPath $dash.Records[0].DestinationPath -Algorithm SHA256).Hash 'Recovered bytes verified'
}
Run-Test 'Tampered archive state cannot escape the Reports folder' {
    $cfg=New-TestConfig 'TamperedState'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday)
    [void](Import-Fixture $cfg)
    $statePath=Join-Path $cfg.ArchiveRoot '.ctqa/state.json'
    $state=[IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $outside=Join-Path $TestRoot 'OutsideReport.pdf'
    [void](New-TestPdf -Path $outside)
    $outsideHash=(Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash
    $state.Records[0].RelativePath='../../OutsideReport.pdf'
    $state.Records[0].DestinationPath=$outside
    [IO.File]::WriteAllText($statePath,($state | ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($true))
    $rejected=$false
    try { [void](Get-QaDashboard -Config $cfg) } catch { $rejected=$true }
    Assert-True $rejected 'Unsafe state cannot create clickable external report paths'
    Assert-Equal $outsideHash (Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash 'Outside file untouched'
}
Run-Test 'Archive metadata and report directory links cannot redirect writes into scanner sources' {
    $linkNames=@('.ctqa','Reports','.ctqa/staging','.ctqa/transactions')
    $index=0
    foreach ($name in $linkNames) {
        $index++
        $cfg=New-TestConfig ('LinkedArchive'+$index)
        $src=Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday
        $preview=Invoke-QaOperation -Config $cfg -Mode Preview
        $before=@(Get-ChildItem -LiteralPath $cfg.Sources[0].Path -Recurse -File | ForEach-Object { $_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join "`n"
        [void][IO.Directory]::CreateDirectory($cfg.ArchiveRoot)
        $link=Join-Path $cfg.ArchiveRoot $name
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($link))
        # Directory junctions do not require admin rights on Windows; symbolic
        # directory links are used for the Linux build-time adversarial fixture.
        $kind=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Junction'}else{'SymbolicLink'}
        New-Item -ItemType $kind -Path $link -Value $cfg.Sources[0].Path -ErrorAction Stop | Out-Null
        $rejected=$false
        try { [void](Invoke-QaOperation -Config $cfg -Mode Import -Plan $preview.Plan) } catch { $rejected=$true }
        Assert-True $rejected ('Unsafe archive link rejected: '+$name)
        $after=@(Get-ChildItem -LiteralPath $cfg.Sources[0].Path -Recurse -File | ForEach-Object { $_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join "`n"
        Assert-Equal $before $after ('No control file or PDF written into source through '+$name)
    }
}
Run-Test 'Legacy migration verifies old hashes, preserves originals, and distrusts old Monthly labels' {
    $cfg=New-TestConfig 'LegacyMigration'
    $legacy=Join-Path $TestRoot 'LegacyArchive'
    $oldPdf=New-TestPdf -Path (Join-Path $legacy 'Reports/CT_Edge/old-renamed-monthly.pdf') -Size 76000
    $oldHash=(Get-FileHash -LiteralPath $oldPdf -Algorithm SHA256).Hash
    $originalName='Quality_Constancy_'+$Yesterday+'_06-00-00.pdf'
    $rows=@(
        [pscustomobject]@{Scanner='CT_Edge';OriginalFileName=$originalName;SourcePath=(Join-Path $cfg.Sources[0].Path $originalName);DestinationPath=$oldPdf;SourceHash=$oldHash;Category='Monthly_QA';FirstArchived='2026-01-01T12:00:00Z'},
        [pscustomobject]@{Scanner='CT_Edge';OriginalFileName=('Quality_Daily_'+$Yesterday+'_07-00-00.pdf');SourcePath=(Join-Path $cfg.Sources[0].Path 'not-trusted.pdf');DestinationPath=$oldPdf;SourceHash=('0'*64);Category='Daily_QA';FirstArchived='2026-01-01T12:00:00Z'}
    )
    $legacyIndex=Join-Path $legacy 'QA_Master_Index_v2.csv'
    $rows | Export-Csv -LiteralPath $legacyIndex -NoTypeInformation -Encoding UTF8
    $indexHash=(Get-FileHash -LiteralPath $legacyIndex -Algorithm SHA256).Hash
    $result=Invoke-QaOperation -Config $cfg -Mode AdoptLegacy -LegacyRoot $legacy
    $dash=Get-QaDashboard -Config $cfg
    Assert-Equal 1 $dash.TotalReports 'Only hash-verified legacy file adopted'
    Assert-Equal 1 $result.Summary.Failed 'Mismatched old hash reported'
    Assert-Equal 'Monthly_QA/Pending_Verification' $dash.Records[0].Category 'Old Monthly label requires new authorized confirmation'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$dash.Records[0].ConfirmedBy)) 'No reviewer fabricated from legacy label'
    Assert-Equal $oldHash (Get-FileHash -LiteralPath $dash.Records[0].DestinationPath -Algorithm SHA256).Hash 'Migrated copy SHA-256 verified'
    Assert-Equal $oldHash (Get-FileHash -LiteralPath $oldPdf -Algorithm SHA256).Hash 'Old PDF intact'
    Assert-Equal $indexHash (Get-FileHash -LiteralPath $legacyIndex -Algorithm SHA256).Hash 'Old index intact'
    [void](Invoke-QaOperation -Config $cfg -Mode AdoptLegacy -LegacyRoot $legacy)
    Assert-Equal 1 (Get-QaDashboard -Config $cfg).TotalReports 'Repeated adoption does not duplicate indexed records'
}
Run-Test 'Concurrent update lock blocks a second writer without changing archive state' {
    $cfg=New-TestConfig 'ConcurrentWriter'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday)
    [void](Import-Fixture $cfg)
    $statePath=Join-Path $cfg.ArchiveRoot '.ctqa/state.json'
    $stateHash=(Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '07-00-00')
    $lock=[IO.File]::Open((Join-Path $cfg.ArchiveRoot '.ctqa/archive.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $rejected=$false
        try { [void](Invoke-QaOperation -Config $cfg -Mode Update) } catch { $rejected=$true }
        Assert-True $rejected 'Second writer rejected while archive lock held'
        Assert-Equal $stateHash (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash 'Committed state not changed'
        Assert-Equal 1 (Get-QaDashboard -Config $cfg).TotalReports 'Second writer copies nothing'
    } finally { $lock.Dispose() }
    [void](Invoke-QaOperation -Config $cfg -Mode Update)
    Assert-Equal 2 (Get-QaDashboard -Config $cfg).TotalReports 'Update succeeds after lock released'
}
Run-Test 'Interrupted reclassification recovers classification, reviewer evidence, and prior PDF history' {
    $cfg=New-TestConfig 'InterruptedReclassification'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy' $Yesterday '06-00-00' 76000)
    [void](Import-Fixture $cfg)
    $old=@((Get-QaDashboard -Config $cfg).Records)[0]
    $decisions=@([pscustomobject]@{RecordId=$old.Id;Category='Monthly_QA';Reviewer='Interrupted synthetic reviewer';Reason='Synthetic monthly review recovered after commit interruption'})
    $module=Get-Module Archive | Select-Object -First 1
    $originalSave=& $module { Get-Item Function:Save-QaState | Select-Object -ExpandProperty ScriptBlock }
    $failed=$false
    try {
        # Fail only the metadata commit. Production code has already installed
        # the verified new category PDF and its transaction/review journal.
        & $module {
            Set-Item Function:script:Save-QaState -Value {
                param($State,$Paths)
                throw 'Synthetic interruption after reviewed target installation and before metadata commit'
            }
        }
        try { [void](Invoke-QaOperation -Config $cfg -Mode Reclassify -Decisions $decisions) } catch { $failed=$true }
    } finally {
        & $module { param($Body) Set-Item Function:script:Save-QaState -Value $Body } $originalSave
    }
    Assert-True $failed 'Reclassification commit interruption observed'
    Assert-Equal 2 @(Get-ChildItem -LiteralPath (Join-Path $cfg.ArchiveRoot 'Reports') -Filter '*.pdf' -Recurse -File).Count 'New reviewed PDF installed while prior PDF still safe'
    Assert-Equal 'Monthly_QA/Pending_Verification' @((Get-QaDashboard -Config $cfg).Records)[0].Category 'Persisted state still points to pre-crash category'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $cfg.ArchiveRoot '.ctqa/transactions') -Filter '*.json' -File).Count -gt 0) 'Review recovery journal remains'
    [void](Invoke-QaOperation -Config $cfg -Mode Update)
    $dash=Get-QaDashboard -Config $cfg
    $current=@($dash.Records)[0]
    Assert-Equal 1 $dash.TotalReports 'Reclassification recovery keeps one report identity'
    Assert-Equal 'Monthly_QA' $current.Category 'Recovered category is confirmed Monthly'
    Assert-Equal 'Interrupted synthetic reviewer' $current.ConfirmedBy 'Reviewer identity recovered from journal'
    Assert-True ($current.ClassificationBasis -match 'Synthetic monthly review recovered after commit interruption') 'Review reason recovered'
    Assert-Equal $old.Hash (Get-FileHash -LiteralPath $current.DestinationPath -Algorithm SHA256).Hash 'Current reviewed PDF still matches original hash'
    Assert-True (-not [IO.File]::Exists($old.DestinationPath)) 'Former pending path removed from current Reports view'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath (Join-Path $cfg.ArchiveRoot 'Reports') -Filter '*.pdf' -Recurse -File).Count 'Only recovered current category appears in Reports'
    $history=@(Get-ChildItem -LiteralPath (Join-Path $cfg.ArchiveRoot '.ctqa/reclassification-history') -Recurse -Filter '*.pdf' -File)
    Assert-Equal 1 $history.Count 'Prior PDF preserved in classification history after recovery'
    Assert-Equal $old.Hash (Get-FileHash -LiteralPath $history[0].FullName -Algorithm SHA256).Hash 'History PDF verified after recovery'
    $state=[IO.File]::ReadAllText((Join-Path $cfg.ArchiveRoot '.ctqa/state.json')) | ConvertFrom-Json
    Assert-Equal 1 @($state.Reviews).Count 'Review provenance committed once'
    Assert-Equal $decisions[0].Reason $state.Reviews[0].Reason 'Exact review reason persisted'
    Assert-Equal $old.Hash $state.Reviews[0].Hash 'Review evidence stays bound to exact PDF hash'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$state.Reviews[0].HistoryRelativePath)) 'History location retained in review provenance'
}
Run-Test 'State-read ancestor reuse checks each leaf and never caches missing directories' {
    $root=Join-Path $TestRoot 'ReadStateDirectoryCache';$folder=Join-Path $root 'shared';[void][IO.Directory]::CreateDirectory($folder)
    $leaf=New-TestPdf -Path (Join-Path $folder 'leaf.pdf');$outside=Join-Path $TestRoot 'ReadStateOutside';[void][IO.Directory]::CreateDirectory($outside)
    $cache=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);$module=Get-Module Archive
    & $module {param($p,$r,$c) Assert-QaNoReparse $p $r -DirectoryCache $c} $leaf $root $cache
    Assert-True ($cache.Contains(([IO.Path]::GetFullPath($folder)+'|'+[IO.Path]::GetFullPath($root)))) 'An existing non-reparse ancestor can be reused within a state read'
    Assert-True (-not $cache.Contains(([IO.Path]::GetFullPath($leaf)+'|'+[IO.Path]::GetFullPath($root)))) 'The exact requested file leaf is never cached'
    $savedLeaf=$leaf+'.saved';[IO.File]::Move($leaf,$savedLeaf)
    $kind=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Junction'}else{'SymbolicLink'}
    try{
        New-Item -ItemType $kind -Path $leaf -Value $outside -ErrorAction Stop|Out-Null
        $rejected=$false;try{& $module {param($p,$r,$c) Assert-QaNoReparse $p $r -DirectoryCache $c} $leaf $root $cache}catch{$rejected=$true}
        Assert-True $rejected 'A newly linked leaf is rejected even when all its parent directories are cached'
    }finally{if([IO.Directory]::Exists($leaf)){[IO.Directory]::Delete($leaf)};[IO.File]::Move($savedLeaf,$leaf)}
    $missing=Join-Path $root 'not-created-yet';$missingLeaf=Join-Path $missing 'later.pdf'
    & $module {param($p,$r,$c) Assert-QaNoReparse $p $r -DirectoryCache $c} $missingLeaf $root $cache
    Assert-True (-not $cache.Contains(([IO.Path]::GetFullPath($missing)+'|'+[IO.Path]::GetFullPath($root)))) 'A missing ancestor directory never enters the reused-directory set'
    try{
        New-Item -ItemType $kind -Path $missing -Value $outside -ErrorAction Stop|Out-Null
        $rejected=$false;try{& $module {param($p,$r,$c) Assert-QaNoReparse $p $r -DirectoryCache $c} $missingLeaf $root $cache}catch{$rejected=$true}
        Assert-True $rejected 'A missing ancestor changed into a link is rejected even within the same reused set'
    }finally{if([IO.Directory]::Exists($missing)){[IO.Directory]::Delete($missing)}}
    $fresh=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    & $module {param($p,$r,$c) Assert-QaNoReparse $p $r -DirectoryCache $c} $leaf $folder $fresh
    Assert-True ($fresh.Contains(([IO.Path]::GetFullPath($folder)+'|'+[IO.Path]::GetFullPath($folder)))) 'The configured stop root itself is checked before it can be cached'
    Assert-True (-not $fresh.Contains(([IO.Path]::GetFullPath($root)+'|'+[IO.Path]::GetFullPath($folder)))) 'Directory reuse retains the original stop-root boundary'
}
Run-Test 'A new state read rejects changed parent links after an earlier successful read' {
    $cfg=New-TestConfig 'ReadStateFreshAncestors';[void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday);[void](Import-Fixture $cfg)
    $before=Get-QaDashboard -Config $cfg;$record=$before.Records[0];$hash=(Get-FileHash -LiteralPath $record.DestinationPath).Hash
    $state=Join-Path $cfg.ArchiveRoot '.ctqa/state.json';$stateHash=(Get-FileHash -LiteralPath $state).Hash
    $parent=[IO.Path]::GetDirectoryName($record.DestinationPath);$savedParent=$parent+'.kept';[IO.Directory]::Move($parent,$savedParent)
    $kind=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Junction'}else{'SymbolicLink'}
    try{
        New-Item -ItemType $kind -Path $parent -Value $savedParent -ErrorAction Stop|Out-Null
        $rejected=$false;try{[void](Get-QaDashboard -Config $cfg)}catch{$rejected=$true}
        Assert-True $rejected 'A successful prior state read cannot authorize a parent link introduced before the next call'
        Assert-Equal $stateHash (Get-FileHash -LiteralPath $state).Hash 'Rejected linked state leaves all archive metadata unchanged'
    }finally{if([IO.Directory]::Exists($parent)){[IO.Directory]::Delete($parent)};[IO.Directory]::Move($savedParent,$parent)}
    $after=Get-QaDashboard -Config $cfg
    Assert-Equal 1 $after.TotalReports 'Restoring the original direct path makes a fresh state read valid again'
    Assert-Equal $hash (Get-FileHash -LiteralPath $after.Records[0].DestinationPath).Hash 'All existing PDF bytes survive the adversarial link fixture'
}

if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){
    Run-Test 'Case-sensitive directory reuse cannot authorize a differently cased linked ancestor' {
        $cfg=New-TestConfig 'ReadStateCaseAliases';[void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '06-00-00');[void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '07-00-00');[void](Import-Fixture $cfg)
        $statePath=Join-Path $cfg.ArchiveRoot '.ctqa/state.json';$state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
        $reports=Join-Path $cfg.ArchiveRoot 'Reports';$direct=Join-Path $reports 'CaseAliasA';$alias=Join-Path $reports 'casealiasa';$outside=Join-Path $TestRoot 'CaseAliasOutside'
        [void][IO.Directory]::CreateDirectory($direct);[void][IO.Directory]::CreateDirectory($outside)
        [IO.File]::Copy($state.Records[0].DestinationPath,(Join-Path $direct 'one.pdf'));[IO.File]::Copy($state.Records[1].DestinationPath,(Join-Path $outside 'two.pdf'))
        $state.Records[0].RelativePath='CaseAliasA/one.pdf';$state.Records[1].RelativePath='casealiasa/two.pdf'
        [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 15),(New-Object Text.UTF8Encoding($true)))
        $before=(Get-FileHash $statePath).Hash
        try{
            New-Item -ItemType SymbolicLink -Path $alias -Value $outside -ErrorAction Stop|Out-Null
            $rejected=$false;try{[void](Get-QaDashboard -Config $cfg)}catch{$rejected=$true}
            Assert-True $rejected 'A validated differently cased directory never authorizes an unchecked linked ancestor on a case-sensitive filesystem'
            Assert-Equal $before (Get-FileHash $statePath).Hash 'Case-alias rejection preserves the complete state file'
        }finally{if([IO.Directory]::Exists($alias)){[IO.Directory]::Delete($alias)}}
    }
}

Run-Test 'Validated archive records read no PDFs and create no workspace files' {
    $empty=New-TestConfig 'RawRecordsEmpty'
    Assert-Equal 0 @(Get-QaArchiveRecords -Config $empty).Count 'An uninitialized archive has no records'
    Assert-True (-not [IO.Directory]::Exists($empty.ArchiveRoot)) 'Reading membership never creates the archive'
    $cfg=New-TestConfig 'RawRecordsDuplicates'
    $name='Quality_Daily_'+$Yesterday+'_06-00-00.pdf'
    $a=New-TestPdf -Path (Join-Path (Join-Path $cfg.Sources[0].Path 'First') $name)
    $b=New-TestPdf -Path (Join-Path (Join-Path $cfg.Sources[0].Path 'Second') $name)
    [void](Import-Fixture $cfg)
    $before=@{};foreach($file in @(Get-ChildItem -LiteralPath $cfg.ArchiveRoot -File -Recurse -Force)){$before[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName).Hash}
    $rows=@(Get-QaArchiveRecords -Config $cfg)
    Assert-Equal 2 $rows.Count 'Legitimate same-name and equal-content reports at separate destinations remain distinct'
    Assert-Equal 1 @($rows.Hash|Select-Object -Unique).Count 'Equal hashes alone are not treated as duplicate identities'
    Assert-Equal 2 @($rows.Id|Select-Object -Unique).Count 'Independent scanner source locations retain their own identity'
    Assert-Equal 2 @($rows.DestinationPath|Select-Object -Unique).Count 'Both separately owned destinations remain available'
    $after=@(Get-ChildItem -LiteralPath $cfg.ArchiveRoot -File -Recurse -Force)
    Assert-Equal $before.Count $after.Count 'Read-only membership creates no metadata, analysis cache, or output files'
    foreach($file in $after){Assert-Equal $before[$file.FullName] (Get-FileHash -LiteralPath $file.FullName).Hash 'Every archived PDF and metadata file retains its exact bytes'}
    Assert-Equal (Get-FileHash -LiteralPath $a).Hash (Get-FileHash -LiteralPath $b).Hash 'The source originals remain equal and unmodified'
}
Run-Test 'Repeated report identities are rejected centrally before reads or mutations' {
    $cfg=New-TestConfig 'RepeatedStateIdentity'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '06-00-00');[void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '07-00-00');[void](Import-Fixture $cfg)
    $statePath=Join-Path $cfg.ArchiveRoot '.ctqa/state.json';$state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
    $state.Records[1].Id=([string]$state.Records[0].Id).ToLowerInvariant()
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 15),(New-Object Text.UTF8Encoding($true)))
    $before=(Get-FileHash -LiteralPath $statePath).Hash;$indexPath=Join-Path $cfg.ArchiveRoot 'QA_Master_Index.csv';$indexBefore=(Get-FileHash -LiteralPath $indexPath).Hash
    foreach($read in @({Get-QaArchiveRecords -Config $cfg},{Get-QaDashboard -Config $cfg},{Invoke-QaOperation -Config $cfg -Mode Audit})){
        $caught=$false;try{& $read|Out-Null}catch{$caught=$_.Exception.Message -like '*repeated report identity*'}
        Assert-True $caught 'Raw membership, dashboard, and operations reject the same ambiguous identity with actionable guidance'
        Assert-Equal $before (Get-FileHash -LiteralPath $statePath).Hash 'Rejected state remains byte-for-byte preserved for investigation'
        Assert-Equal $indexBefore (Get-FileHash -LiteralPath $indexPath).Hash 'Rejection never rewrites the CSV index'
    }
    foreach($record in $state.Records){Assert-Equal $record.Hash (Get-FileHash -LiteralPath $record.DestinationPath).Hash 'All saved PDF bytes remain preserved'}
}
Run-Test 'Distinct record IDs cannot claim one normalized archive destination' {
    $cfg=New-TestConfig 'RepeatedStateDestination'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '06-00-00');[void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday '07-00-00');[void](Import-Fixture $cfg)
    $statePath=Join-Path $cfg.ArchiveRoot '.ctqa/state.json';$state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
    $original=@($state.Records|ForEach-Object{[pscustomobject]@{Path=$_.DestinationPath;Hash=$_.Hash}})
    $first=[string]$state.Records[0].RelativePath
    $state.Records[1].RelativePath=Join-Path (Join-Path ([IO.Path]::GetDirectoryName($first)) 'unused/..') ([IO.Path]::GetFileName($first))
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 15),(New-Object Text.UTF8Encoding($true)))
    $before=(Get-FileHash -LiteralPath $statePath).Hash
    foreach($read in @({Get-QaArchiveRecords -Config $cfg},{Get-QaDashboard -Config $cfg},{Invoke-QaOperation -Config $cfg -Mode Audit})){
        $caught=$false;try{& $read|Out-Null}catch{$caught=$_.Exception.Message -like '*same saved PDF*'}
        Assert-True $caught 'Destination aliases are normalized before checking exclusive ownership'
        Assert-Equal $before (Get-FileHash -LiteralPath $statePath).Hash 'Ambiguous destination state remains unchanged'
    }
    foreach($record in $original){Assert-Equal $record.Hash (Get-FileHash -LiteralPath $record.Path).Hash 'Neither existing saved PDF is changed or removed'}
}
Run-Test 'Read-only membership rejects a newly linked metadata directory' {
    $cfg=New-TestConfig 'RawRecordsMetadataLink';[void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' $Yesterday);[void](Import-Fixture $cfg)
    $meta=Join-Path $cfg.ArchiveRoot '.ctqa';$saved=$meta+'.kept';$statePath=Join-Path $meta 'state.json';$before=(Get-FileHash -LiteralPath $statePath).Hash
    [IO.Directory]::Move($meta,$saved)
    $kind=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Junction'}else{'SymbolicLink'}
    try{
        New-Item -ItemType $kind -Path $meta -Value $saved -ErrorAction Stop|Out-Null
        $caught=$false;try{Get-QaArchiveRecords -Config $cfg|Out-Null}catch{$caught=$_.Exception.Message -like '*symbolic link or junction*'}
        Assert-True $caught 'Fresh state reading checks its own metadata path before opening linked state'
        Assert-Equal $before (Get-FileHash -LiteralPath (Join-Path $saved 'state.json')).Hash 'Linked metadata is never rewritten'
    }finally{if([IO.Directory]::Exists($meta)){[IO.Directory]::Delete($meta)};[IO.Directory]::Move($saved,$meta)}
    Assert-Equal 1 @(Get-QaArchiveRecords -Config $cfg).Count 'Restoring the direct metadata path permits fresh validated membership'
}

Run-Test 'Master CSV escapes spreadsheet formulas without changing authoritative report values' {
    $cfg=New-TestConfig 'SpreadsheetIndex'
    $names=@('=2+3.pdf','+2+3.pdf','@SUM.pdf','-2+3.pdf','ordinary-synthetic-report.pdf')
    $sources=@{};foreach($name in $names){$path=New-TestPdf -Path (Join-Path $cfg.Sources[0].Path $name);$sources[$path]=(Get-FileHash -LiteralPath $path).Hash}
    [void](Import-Fixture $cfg)
    $rows=@(Get-QaArchiveRecords -Config $cfg)
    $decisions=@($rows|ForEach-Object{[pscustomobject]@{RecordId=$_.Id;Category='Daily_QA';Reviewer=$(if($_.OriginalFileName -eq 'ordinary-synthetic-report.pdf'){'Synthetic reviewer'}else{'=1+1'});Reason='Synthetic spreadsheet projection test'}})
    [void](Invoke-QaOperation -Config $cfg -Mode Reclassify -Decisions $decisions)
    $raw=@(Get-QaArchiveRecords -Config $cfg);$csv=@(Import-Csv -LiteralPath (Join-Path $cfg.ArchiveRoot 'QA_Master_Index.csv'))
    Assert-Equal $names.Count $csv.Count 'The master CSV retains every report'
    $expectedColumns='Id,Scanner,ReportDate,ReportTime,Category,ClassificationBasis,OriginalFileName,SourcePath,Hash,Length,RelativePath,DestinationPath,FirstArchived,ConfirmedBy,ConfirmedAt,ReviewDecision,LastReviewId,ConfirmedComponents,PdfPagesHint'
    Assert-Equal $expectedColumns (($csv[0].PSObject.Properties.Name)-join ',') 'The existing CSV schema and column order are unchanged'
    foreach($record in $raw){
        $exported=@($csv|Where-Object Id -ceq $record.Id)[0]
        $formula=([string]$record.OriginalFileName -ne 'ordinary-synthetic-report.pdf')
        Assert-True ($names -ccontains [string]$record.OriginalFileName) 'Authoritative JSON keeps the exact original filename'
        Assert-Equal $(if($formula){"'"+$record.OriginalFileName}else{$record.OriginalFileName}) $exported.OriginalFileName 'Only formula-leading spreadsheet filename cells receive an apostrophe'
        Assert-Equal $(if($formula){'=1+1'}else{'Synthetic reviewer'}) $record.ConfirmedBy 'The saved reviewer identity is never escaped or otherwise changed'
        Assert-Equal $(if($formula){"'=1+1"}else{'Synthetic reviewer'}) $exported.ConfirmedBy 'Formula-leading reviewer cells are escaped only in the spreadsheet projection'
        foreach($field in @('Id','Hash','Scanner','Length','RelativePath','DestinationPath','Category','ClassificationBasis')){Assert-Equal $record.$field $exported.$field 'Ordinary identity, paths, numeric values and classification data retain their original value'}
        Assert-Equal $record.Hash (Get-FileHash -LiteralPath $record.DestinationPath).Hash 'Saved PDFs remain byte-for-byte unchanged by CSV sanitization'
    }
    foreach($path in $sources.Keys){Assert-Equal $sources[$path] (Get-FileHash -LiteralPath $path).Hash 'Scanner source originals remain unchanged'}
}

$failed=@($script:Results | Where-Object { $_.Result -eq 'FAIL' }).Count
$report=[pscustomobject]@{
    Product='CT QA Manager Pro'; TimestampUtc=[datetime]::UtcNow.ToString('o');
    Runtime=$PSVersionTable.PSVersion.ToString(); Platform=[Environment]::OSVersion.ToString();
    WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1);
    Tests=$script:Results.Count; Assertions=$script:Assertions; Failed=$failed;
    Results=@($script:Results.ToArray()); FixturesKept=[bool]$KeepFixtures
}
if ($OutputPath) { $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8 }
Write-Host ('Result: ' + ($script:Results.Count-$failed) + '/' + $script:Results.Count + ' tests passed; ' + $script:Assertions + ' assertions; PowerShell ' + $PSVersionTable.PSVersion)
if ($KeepFixtures) { Write-Host ('Synthetic fixtures: ' + $TestRoot) } else { Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($failed -gt 0) { exit 1 }
