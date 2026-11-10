# Synthetic Browse Reports tests. Windows PowerShell 5.1, no third-party test tools.
[CmdletBinding()]
param([string]$OutputPath='', [switch]$KeepFixtures)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProductRoot 'App/Archive.psm1') -Force
Import-Module (Join-Path $ProductRoot 'App/Browse.psm1') -Force
$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_BrowseSynthetic_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestRoot)
$script:Results=New-Object 'System.Collections.Generic.List[object]'
$script:Assertions=0
function Assert-True([bool]$Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw ('Assertion failed: '+$Message)}}
function Assert-Equal($Expected,$Actual,[string]$Message){Assert-True ([string]$Expected -ceq [string]$Actual) ($Message+'; expected='+[string]$Expected+'; actual='+[string]$Actual)}
function Run-Test([string]$Name,[scriptblock]$Body){
    try{&$Body;$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS  '+$Name)}
    catch{
        $kind=if($_.Exception.Message.StartsWith('[SKIP]')){'SKIP'}else{'FAIL'}
        $script:Results.Add([pscustomobject]@{Name=$Name;Result=$kind;Details=$_.Exception.Message+' '+$_.ScriptStackTrace})
        Write-Host ($kind+'  '+$Name+': '+$_.Exception.Message)
    }
}
$tokens=$null;$parseErrors=$null
$helperAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Run-Tests.ps1'),[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count){throw 'Synthetic fixture helpers did not parse.'}
foreach($name in @('New-TestConfig','New-TestPdf','Add-Report','Import-Fixture')){
    $definition=@($helperAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($definition.Count -ne 1){throw ('Synthetic helper not found: '+$name)}
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
function New-BrowseFixture([string]$Name,[switch]$Rich,[switch]$Pending){
    $cfg=New-TestConfig $Name
    if($Pending){[void](Add-Report $cfg 'CT_Edge' 'Quality_Constancy' '2025-12-15' '08-00-00' 76000)}
    else{[void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' '2025-12-01' '06-00-00' 1800 'SessionA')}
    if($Rich){
        [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' '2025-12-01' '06-00-00' 2400 'SessionB')
        [void](Add-Report $cfg 'CT_Flash' 'Quality_Constancy' '2025-12-15' '08-00-00' 95000)
    }
    [void](Import-Fixture $cfg)
    return [pscustomobject]@{Config=$cfg;Records=@((Get-QaDashboard -Config $cfg).Records);Sources=@($cfg.Sources|ForEach-Object{$_.Path});Browse=(Join-Path $cfg.ArchiveRoot 'Browse Reports')}
}
function Get-ProtectedManifest($Fixture){
    $root=$Fixture.Config.ArchiveRoot
    $paths=@($Fixture.Sources)+@((Join-Path $root 'Reports'),(Join-Path $root '.ctqa/state.json'),(Join-Path $root 'QA_Master_Index.csv'),(Join-Path $root 'Activity.csv'),(Join-Path $root '.ctqa/reclassification-history'))
    $lines=New-Object 'System.Collections.Generic.List[string]'
    foreach($path in $paths){
        $files=@()
        if([IO.File]::Exists($path)){$files=@(Get-Item -LiteralPath $path)}
        elseif([IO.Directory]::Exists($path)){$files=@(Get-ChildItem -LiteralPath $path -Recurse -File -Force|Sort-Object FullName)}
        else{$lines.Add('MISSING|'+$path)}
        foreach($file in $files){$lines.Add($file.FullName+'|'+$file.Length+'|'+$file.LastWriteTimeUtc.Ticks+'|'+(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)}
    }
    return ($lines.ToArray() -join "`n")
}
function Get-BrowsePdfs($Fixture){if([IO.Directory]::Exists($Fixture.Browse)){return @(Get-ChildItem -LiteralPath $Fixture.Browse -Recurse -File -Filter '*.pdf')}return @()}
function New-BrowseTestLink([string]$Path,[string]$Target){
    $kind=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Junction'}else{'SymbolicLink'}
    try{New-Item -ItemType $kind -Path $Path -Value $Target -ErrorAction Stop|Out-Null}
    catch{throw ('[SKIP] Cannot create synthetic '+$kind+' fixture on this workstation: '+$_.Exception.Message)}
}
Run-Test 'Browse Reports creates readable scanner, year, month, and QA folders with independent PDF copies'{
    $f=New-BrowseFixture 'ReadableMirror' -Rich
    $before=Get-ProtectedManifest $f
    $result=Invoke-QaBrowseRefresh -Config $f.Config
    Assert-Equal $f.Browse $result.DestinationPath 'Browse output has predictable name'
    Assert-Equal 3 $result.Summary.Exported 'All archived reports mirrored'
    Assert-Equal 0 $result.Summary.Failed 'No mirror failure'
    $pdfs=@(Get-BrowsePdfs $f)
    Assert-Equal 3 $pdfs.Count 'Distinct sessions retain distinct friendly copies'
    Assert-Equal 3 @($pdfs.FullName|Select-Object -Unique).Count 'No friendly name collision'
    $hashes=@($pdfs|ForEach-Object{(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}|Sort-Object)
    Assert-Equal 0 @(Compare-Object @($f.Records.Hash|Sort-Object) $hashes).Count 'Mirror bytes match archive index hashes'
    foreach($pdf in $pdfs){
        Assert-True ($pdf.FullName -match 'CT (Edge|Flash)[\\/]2025[\\/]12[^\\/]*December[\\/]') 'Scanner/year/month path is readable'
        Assert-True ($pdf.Name -match '2025-12-(01|15)') 'Friendly filename retains report date'
        Assert-True ($pdf.FullName -notmatch '[\\/][A-Fa-f0-9]{8}-[A-Fa-f0-9]{12}[\\/]') 'Browse folders avoid opaque identity directories'
    }
    Assert-True (@($pdfs|Where-Object{$_.FullName -match '(?i)Pending'}).Count -eq 1) 'Unverified Monthly copy is visibly pending'
    Assert-Equal 1 @($pdfs|Where-Object{$_.FullName -match '[\\/]Monthly QA[\\/]Pending Verification[\\/]'}).Count 'Pending Monthly reports share the Monthly QA primary folder'
    Assert-Equal 2 @($pdfs|Where-Object{$_.FullName -match '[\\/]Daily QA[\\/]'}).Count 'Daily reports have the simple Daily QA folder'
    Assert-Equal $before (Get-ProtectedManifest $f) 'Sources, archive PDFs, state, index, and archive history unchanged'
}
Run-Test 'Repeated mirror refresh skips unchanged copies without rewriting them'{
    $f=New-BrowseFixture 'IdempotentMirror' -Rich
    [void](Invoke-QaBrowseRefresh -Config $f.Config)
    $before=@(Get-BrowsePdfs $f|ForEach-Object{$_.FullName+'|'+$_.LastWriteTimeUtc.Ticks+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}) -join "`n"
    $result=Invoke-QaBrowseRefresh -Config $f.Config
    Assert-Equal 0 $result.Summary.Exported 'No repeated copy'
    Assert-Equal 3 $result.Summary.Unchanged 'All existing mirror copies unchanged'
    Assert-Equal 0 $result.Summary.Failed 'No failed unchanged copy'
    $after=@(Get-BrowsePdfs $f|ForEach-Object{$_.FullName+'|'+$_.LastWriteTimeUtc.Ticks+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}) -join "`n"
    Assert-Equal $before $after 'Refresh leaves unchanged mirror files intact'
}
Run-Test 'Editing a browse copy cannot change the archive; edited bytes are never silently replaced'{
    $f=New-BrowseFixture 'EditedMirror'
    [void](Invoke-QaBrowseRefresh -Config $f.Config)
    $copy=@(Get-BrowsePdfs $f)[0]
    $bytes=[IO.File]::ReadAllBytes($copy.FullName);$bytes[100]=[byte]($bytes[100] -bxor 1);[IO.File]::WriteAllBytes($copy.FullName,$bytes)
    $edited=(Get-FileHash -LiteralPath $copy.FullName -Algorithm SHA256).Hash
    Assert-True ($edited -ne $f.Records[0].Hash) 'Mirror edit changed only its independent bytes'
    Assert-Equal $f.Records[0].Hash (Get-FileHash -LiteralPath $f.Records[0].DestinationPath -Algorithm SHA256).Hash 'Archive did not share a hard link'
    $before=Get-ProtectedManifest $f
    $result=Invoke-QaBrowseRefresh -Config $f.Config
    Assert-Equal $edited (Get-FileHash -LiteralPath $copy.FullName -Algorithm SHA256).Hash 'Edited copy preserved'
    Assert-True ($result.Summary.Failed -gt 0) 'Edited copy conflict reported'
    Assert-Equal $before (Get-ProtectedManifest $f) 'Archive/source protected files still unchanged'
}
Run-Test 'Unowned notes and PDFs in Browse Reports survive refresh unchanged'{
    $f=New-BrowseFixture 'UnownedFiles'
    [void][IO.Directory]::CreateDirectory($f.Browse)
    $note=Join-Path $f.Browse 'Supervisor notes.txt';[IO.File]::WriteAllText($note,'Synthetic personal note')
    $pdf=New-TestPdf -Path (Join-Path $f.Browse 'Supervisor extra report.pdf') -Text 'Synthetic unowned report'
    $noteHash=(Get-FileHash -LiteralPath $note -Algorithm SHA256).Hash;$pdfHash=(Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash
    [void](Invoke-QaBrowseRefresh -Config $f.Config)
    [void](Invoke-QaBrowseRefresh -Config $f.Config)
    Assert-Equal $noteHash (Get-FileHash -LiteralPath $note -Algorithm SHA256).Hash 'Unowned note unchanged'
    Assert-Equal $pdfHash (Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash 'Unowned PDF unchanged'
    Assert-Equal 2 @(Get-BrowsePdfs $f).Count 'Owned mirror plus unowned PDF retained'
}
Run-Test 'Reclassification retires only the owned prior category copy into private browse history'{
    $f=New-BrowseFixture 'ReclassifiedMirror' -Pending
    [void](Invoke-QaBrowseRefresh -Config $f.Config)
    $oldCopy=@(Get-BrowsePdfs $f)[0]
    $unowned=New-TestPdf -Path (Join-Path $oldCopy.DirectoryName 'Unrelated supervisor PDF.pdf')
    $unownedHash=(Get-FileHash -LiteralPath $unowned -Algorithm SHA256).Hash
    $decisions=@([pscustomobject]@{RecordId=$f.Records[0].Id;Category='Monthly_QA';Reviewer='Synthetic browse reviewer';Reason='Synthetic authorized monthly reclassification'})
    [void](Invoke-QaOperation -Config $f.Config -Mode Reclassify -Decisions $decisions)
    $before=Get-ProtectedManifest $f
    $result=Invoke-QaBrowseRefresh -Config $f.Config
    Assert-Equal 0 $result.Summary.Failed 'Clean reclassification mirror refresh succeeds'
    Assert-True (-not [IO.File]::Exists($oldCopy.FullName)) 'Prior owned pending copy retired from browse view'
    Assert-Equal $unownedHash (Get-FileHash -LiteralPath $unowned -Algorithm SHA256).Hash 'Unrelated neighboring PDF kept'
    $current=@(Get-BrowsePdfs $f|Where-Object{$_.FullName -ne $unowned})
    Assert-Equal 1 $current.Count 'One current mirrored category remains'
    Assert-True ($current[0].FullName -match '(?i)Monthly' -and $current[0].FullName -notmatch '(?i)Pending') 'Current category is visibly confirmed Monthly'
    Assert-True ($current[0].FullName -match '[\\/]Monthly QA[\\/]Confirmed[\\/]') 'Reviewed reports stay under the same Monthly QA primary folder'
    Assert-Equal $f.Records[0].Hash (Get-FileHash -LiteralPath $current[0].FullName -Algorithm SHA256).Hash 'Current mirror still matches indexed bytes'
    $history=@(Get-ChildItem -LiteralPath (Join-Path $f.Config.ArchiveRoot '.ctqa/browse-history') -Recurse -File -Filter '*.pdf')
    Assert-Equal 1 $history.Count 'Prior owned copy preserved in private browse history'
    Assert-Equal $f.Records[0].Hash (Get-FileHash -LiteralPath $history[0].FullName -Algorithm SHA256).Hash 'Retired browse copy hash preserved'
    Assert-Equal $before (Get-ProtectedManifest $f) 'Browse refresh does not change current archive/index/source/history'
}
Run-Test 'An edited prior category browse copy survives reclassification as a reported conflict'{
    $f=New-BrowseFixture 'EditedReclassification' -Pending
    [void](Invoke-QaBrowseRefresh -Config $f.Config)
    $oldCopy=@(Get-BrowsePdfs $f)[0]
    $bytes=[IO.File]::ReadAllBytes($oldCopy.FullName);$bytes[100]=[byte]($bytes[100] -bxor 1);[IO.File]::WriteAllBytes($oldCopy.FullName,$bytes)
    $editedHash=(Get-FileHash -LiteralPath $oldCopy.FullName -Algorithm SHA256).Hash
    $decisions=@([pscustomobject]@{RecordId=$f.Records[0].Id;Category='Monthly_QA';Reviewer='Synthetic browse reviewer';Reason='Synthetic review with edited user mirror'})
    [void](Invoke-QaOperation -Config $f.Config -Mode Reclassify -Decisions $decisions)
    $result=Invoke-QaBrowseRefresh -Config $f.Config
    Assert-Equal $editedHash (Get-FileHash -LiteralPath $oldCopy.FullName -Algorithm SHA256).Hash 'Edited prior browse copy preserved'
    Assert-True ($result.Summary.Failed -gt 0) 'Preserved edited prior copy conflict reported'
    Assert-Equal $f.Records[0].Hash (Get-FileHash -LiteralPath @((Get-QaDashboard -Config $f.Config).Records)[0].DestinationPath -Algorithm SHA256).Hash 'Reviewed archive untouched'
}
Run-Test 'Offline scanner sources do not block a verified local browse refresh'{
    $f=New-BrowseFixture 'OfflineBrowse'
    $before=Get-ProtectedManifest $f
    foreach($s in $f.Config.Sources){$s.Path=Join-Path $TestRoot ('UnavailableBrowse-'+$s.Scanner)}
    $result=Invoke-QaBrowseRefresh -Config $f.Config
    Assert-Equal 1 $result.Summary.Exported 'Archived report mirrored while scanners unavailable'
    Assert-Equal $f.Records[0].Hash (Get-FileHash -LiteralPath @(Get-BrowsePdfs $f)[0].FullName -Algorithm SHA256).Hash 'Offline mirror hash verified'
    Assert-Equal $before (Get-ProtectedManifest $f) 'Offline refresh changes no source/archive bytes'
}
Run-Test 'Archive writer lock blocks a conflicting browse refresh'{
    $f=New-BrowseFixture 'BrowseLock'
    $before=Get-ProtectedManifest $f
    $lock=[IO.File]::Open((Join-Path $f.Config.ArchiveRoot '.ctqa/archive.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        $rejected=$false
        try{[void](Invoke-QaBrowseRefresh -Config $f.Config)}catch{$rejected=$true}
        Assert-True $rejected 'Active archive writer blocks mirror operation'
        Assert-Equal 0 @(Get-BrowsePdfs $f).Count 'No browse PDF published by conflicting writer'
    }finally{$lock.Dispose()}
    Assert-Equal $before (Get-ProtectedManifest $f) 'Conflicting refresh changes no protected archive/source files'
    [void](Invoke-QaBrowseRefresh -Config $f.Config)
    Assert-Equal 1 @(Get-BrowsePdfs $f).Count 'Refresh succeeds after writer unlocks'
}
Run-Test 'Browse output and private staging links cannot redirect writes into scanner folders'{
    $n=0
    foreach($relative in @('Browse Reports','.ctqa/browse-staging','.ctqa/browse-transactions')){
        $n++;$f=New-BrowseFixture ('LinkedBrowse'+$n)
        $before=Get-ProtectedManifest $f
        $link=Join-Path $f.Config.ArchiveRoot $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($link))
        New-BrowseTestLink $link $f.Sources[0]
        $rejected=$false
        try{[void](Invoke-QaBrowseRefresh -Config $f.Config)}catch{$rejected=$true}
        Assert-True $rejected ('Linked browse path rejected: '+$relative)
        Assert-Equal $before (Get-ProtectedManifest $f) 'No source/archive write via redirected browse path'
    }
}
Run-Test 'Cancellation during a real multi-buffer browse transfer leaves no half PDF and retries safely'{
    $f=New-BrowseFixture 'CancelledBrowse'
    [void](Invoke-QaBrowseRefresh -Config $f.Config)
    $oldCopy=@(Get-BrowsePdfs $f)[0]
    $oldCopyHash=(Get-FileHash -LiteralPath $oldCopy.FullName -Algorithm SHA256).Hash
    [void](Add-Report $f.Config 'CT_Edge' 'Quality_Daily' '2025-12-02' '07-00-00' 3400000)
    [void](Invoke-QaOperation -Config $f.Config -Mode Update)
    $before=Get-ProtectedManifest $f
    $module=Get-Module Browse|Select-Object -First 1
    $original=&$module{Get-Item Function:Test-QaBrowseCancelled|Select-Object -ExpandProperty ScriptBlock}
    $progress=[hashtable]::Synchronized(@{Cancel=$false;Message='';Percent=0})
    try{
        &$module{
            $script:TestBrowseBufferChecks=0
            Set-Item Function:script:Test-QaBrowseCancelled -Value {
                param($Progress)
                if(@(Get-PSCallStack|Where-Object{$_.FunctionName -eq 'Copy-QaBrowseReport'}).Count -gt 0){
                    $script:TestBrowseBufferChecks++
                    if($script:TestBrowseBufferChecks -ge 2){$Progress.Cancel=$true}
                }
                return ($null -ne $Progress -and [bool]$Progress.Cancel)
            }
        }
        $result=Invoke-QaBrowseRefresh -Config $f.Config -Progress $progress
        $checks=&$module{$script:TestBrowseBufferChecks}
        Assert-True ($checks -ge 2) 'Cancellation reached second buffer after one written buffer'
        Assert-True ([bool]$result.Summary.Cancelled) 'Cancellation explicitly reported'
        Assert-Equal 1 @(Get-BrowsePdfs $f).Count 'Incomplete new PDF not published'
        Assert-Equal $oldCopyHash (Get-FileHash -LiteralPath $oldCopy.FullName -Algorithm SHA256).Hash 'Completed prior mirror remains intact'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $f.Config.ArchiveRoot '.ctqa/browse-staging') -File -Force).Count 'Cancelled staging bytes cleaned'
    }finally{&$module{param($Body) Set-Item Function:script:Test-QaBrowseCancelled -Value $Body} $original}
    Assert-Equal $before (Get-ProtectedManifest $f) 'Cancellation leaves scanner/archive protected bytes unchanged'
    [void](Invoke-QaBrowseRefresh -Config $f.Config)
    Assert-Equal 2 @(Get-BrowsePdfs $f).Count 'Next refresh safely completes missing mirror copy'
}
Run-Test 'Installed browse PDF recovers from interruption before ledger commit without duplicate copies'{
    $f=New-BrowseFixture 'InterruptedBrowseCommit'
    [void](Invoke-QaBrowseRefresh -Config $f.Config)
    [void](Add-Report $f.Config 'CT_Edge' 'Quality_Daily' '2025-12-02' '07-00-00' 2500)
    [void](Invoke-QaOperation -Config $f.Config -Mode Update)
    $before=Get-ProtectedManifest $f
    $module=Get-Module Browse|Select-Object -First 1
    $original=&$module{Get-Item Function:Save-QaBrowseLedger|Select-Object -ExpandProperty ScriptBlock}
    $failed=$false
    try{
        &$module{
            param($Body)
            $script:TestOriginalBrowseSave=$Body
            Set-Item Function:script:Save-QaBrowseLedger -Value {
                param($Ledger,$Paths)
                if(@($Ledger.Records).Count -gt 1){throw 'Synthetic interruption after browse target installation before ledger commit'}
                &$script:TestOriginalBrowseSave $Ledger $Paths
            }
        } $original
        try{[void](Invoke-QaBrowseRefresh -Config $f.Config)}catch{$failed=$true}
    }finally{&$module{param($Body) Set-Item Function:script:Save-QaBrowseLedger -Value $Body} $original}
    Assert-True $failed 'Ledger commit interruption observed'
    Assert-Equal 2 @(Get-BrowsePdfs $f).Count 'Both complete mirror PDFs installed before metadata commit'
    $ledgerPath=Join-Path $f.Config.ArchiveRoot '.ctqa/browse.json'
    $ledger=[IO.File]::ReadAllText($ledgerPath)|ConvertFrom-Json
    Assert-Equal 1 @($ledger.Records).Count 'Persisted ledger still has only previously committed report'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $f.Config.ArchiveRoot '.ctqa/browse-transactions') -File -Filter '*.json').Count -gt 0) 'Recovery transaction retained'
    [void](Invoke-QaBrowseRefresh -Config $f.Config)
    $ledger=[IO.File]::ReadAllText($ledgerPath)|ConvertFrom-Json
    Assert-Equal 2 @($ledger.Records).Count 'Recovery commits each report once'
    Assert-Equal 2 @(Get-BrowsePdfs $f).Count 'Recovery creates no duplicate PDF'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $f.Config.ArchiveRoot '.ctqa/browse-transactions') -File -Filter '*.json').Count 'Committed recovery transaction cleared'
    $archive=@((Get-QaDashboard -Config $f.Config).Records)
    $hashes=@(Get-BrowsePdfs $f|ForEach-Object{(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}|Sort-Object)
    Assert-Equal 0 @(Compare-Object @($archive.Hash|Sort-Object) $hashes).Count 'Recovered mirror PDFs have exact indexed hashes'
    Assert-Equal $before (Get-ProtectedManifest $f) 'Interrupted commit and recovery change no source/archive protected files'
}
Run-Test 'Tampered browse ledger cannot redirect a managed path outside Browse Reports'{
    $f=New-BrowseFixture 'EscapedBrowseLedger'
    [void](Invoke-QaBrowseRefresh -Config $f.Config)
    $ledgerPath=Join-Path $f.Config.ArchiveRoot '.ctqa/browse.json'
    $ledger=[IO.File]::ReadAllText($ledgerPath)|ConvertFrom-Json
    $ledger.Records[0].RelativePath='../../CT_Edge/escaped-report.pdf'
    [IO.File]::WriteAllText($ledgerPath,($ledger|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
    $before=Get-ProtectedManifest $f;$rejected=$false
    try{[void](Invoke-QaBrowseRefresh -Config $f.Config)}catch{$rejected=$true}
    Assert-True $rejected 'Unsafe ledger path rejected'
    Assert-Equal $before (Get-ProtectedManifest $f) 'Unsafe ledger cannot change scanner/archive protected files'
    Assert-Equal 1 @(Get-BrowsePdfs $f).Count 'Existing safe mirror copy preserved'
}
Run-Test 'Corrupt archived content is never published as a verified browse PDF'{
    $f=New-BrowseFixture 'CorruptArchiveForBrowse'
    $bytes=[IO.File]::ReadAllBytes($f.Records[0].DestinationPath);$bytes[100]=[byte]($bytes[100] -bxor 1);[IO.File]::WriteAllBytes($f.Records[0].DestinationPath,$bytes)
    $before=Get-ProtectedManifest $f
    $result=Invoke-QaBrowseRefresh -Config $f.Config
    Assert-True ($result.Summary.Failed -gt 0) 'Archive hash failure clearly reported'
    Assert-Equal 0 @(Get-BrowsePdfs $f).Count 'Corrupt archive PDF not published'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $f.Config.ArchiveRoot '.ctqa/browse-staging') -File -Force).Count 'Rejected corrupt staging bytes cleaned'
    Assert-Equal $before (Get-ProtectedManifest $f) 'Browse operation leaves damaged archive and source bytes untouched for diagnosis'
}
Run-Test 'A fourth configured scanner gains a readable mirror while the original three remain intact'{
    $cfg=New-TestConfig 'FourthScannerBrowse'
    foreach($source in $cfg.Sources){[void](Add-Report $cfg $source.Scanner 'Quality_Daily' '2025-12-01' '06-00-00' 1800)}
    [void](Import-Fixture $cfg)
    $f=[pscustomobject]@{Config=$cfg;Records=@((Get-QaDashboard -Config $cfg).Records);Sources=@($cfg.Sources|ForEach-Object{$_.Path});Browse=(Join-Path $cfg.ArchiveRoot 'Browse Reports')}
    [void](Invoke-QaBrowseRefresh -Config $cfg)
    $originalIds=@($f.Records.Id)
    $originalCopies=@(Get-BrowsePdfs $f|ForEach-Object{[pscustomobject]@{Path=$_.FullName;Ticks=$_.LastWriteTimeUtc.Ticks;Hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
    Assert-Equal 3 $originalCopies.Count 'Original scanner mirrors exist before adding another scanner'
    $annexPath=Join-Path (Split-Path -Parent $cfg.ArchiveRoot) 'CT_Annex'
    [void][IO.Directory]::CreateDirectory($annexPath)
    $annex=[pscustomobject]@{Scanner='CT_Annex';Name='Annex CT';Path=$annexPath;DriveLetter='Z';DailySchedule='AllDays';ExpectedMonthly=$true;ActiveFrom='2025-01-01';MonthlyThresholdKB=85}
    $cfg.Sources=@($cfg.Sources)+@($annex)
    [void](Add-Report $cfg 'CT_Annex' 'Quality_Daily' '2025-12-01' '06-00-00' 1800)
    [void](Invoke-QaOperation -Config $cfg -Mode Update)
    $f.Sources=@($cfg.Sources|ForEach-Object{$_.Path})
    $f.Records=@((Get-QaDashboard -Config $cfg).Records)
    Assert-Equal 4 $f.Records.Count 'All configured scanners have one indexed report'
    foreach($id in $originalIds){Assert-True (@($f.Records|Where-Object{$_.Id -eq $id}).Count -eq 1) 'Original scanner report identity preserved'}
    Assert-Equal 1 @($f.Records|Where-Object{$_.Scanner -eq 'CT_Annex'}).Count 'Fourth scanner safely indexed'
    $before=Get-ProtectedManifest $f
    $result=Invoke-QaBrowseRefresh -Config $cfg
    Assert-Equal 1 $result.Summary.Exported 'Only the new scanner requires a new mirror copy'
    Assert-Equal 3 $result.Summary.Unchanged 'Original scanner mirror copies skip unchanged'
    Assert-Equal 0 $result.Summary.Failed 'Fourth configured scanner refresh succeeds'
    $pdfs=@(Get-BrowsePdfs $f)
    Assert-Equal 4 $pdfs.Count 'Same-basename reports from four scanners stay separate'
    Assert-Equal 4 @($pdfs.FullName|Select-Object -Unique).Count 'All scanner mirror paths are distinct'
    Assert-Equal 1 @($pdfs|Where-Object{$_.FullName -match '[\\/]Annex CT[\\/]2025[\\/]12[^\\/]*December[\\/]'}).Count 'Fourth scanner uses its readable configured name'
    foreach($copy in $originalCopies){
        Assert-True ([IO.File]::Exists($copy.Path)) 'Original scanner mirror path preserved'
        Assert-Equal $copy.Hash (Get-FileHash -LiteralPath $copy.Path -Algorithm SHA256).Hash 'Original scanner mirror bytes preserved'
        Assert-Equal $copy.Ticks (Get-Item -LiteralPath $copy.Path).LastWriteTimeUtc.Ticks 'Original scanner mirror not rewritten'
    }
    Assert-Equal $before (Get-ProtectedManifest $f) 'Fourth scanner mirror does not modify scanner sources or archive/index/state'
}
Run-Test 'Duplicate configured scanner display names are rejected before creating conflicting mirror folders'{
    $f=New-BrowseFixture 'DuplicateScannerNames' -Rich
    $f.Config.Sources[1].Name=$f.Config.Sources[0].Name
    $before=Get-ProtectedManifest $f;$rejected=$false
    try{[void](Invoke-QaBrowseRefresh -Config $f.Config)}catch{$rejected=$true}
    Assert-True $rejected 'Duplicate scanner display names rejected'
    Assert-Equal 0 @(Get-BrowsePdfs $f).Count 'No ambiguous scanner mirror created'
    Assert-Equal $before (Get-ProtectedManifest $f) 'Rejected scanner name collision changes no source/archive files'
}
Run-Test 'An archive row for an unconfigured scanner cannot acquire a fallback mirror folder'{
    $f=New-BrowseFixture 'UnconfiguredScannerBrowse'
    $statePath=Join-Path $f.Config.ArchiveRoot '.ctqa/state.json'
    $state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
    $state.Records[0].Scanner='CT_Ghost'
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($true))
    $before=Get-ProtectedManifest $f;$rejected=$false
    try{$result=Invoke-QaBrowseRefresh -Config $f.Config;$rejected=($result.Summary.Failed -gt 0)}catch{$rejected=$true}
    Assert-True $rejected 'Unconfigured scanner row rejected'
    Assert-Equal 0 @(Get-BrowsePdfs $f).Count 'Unknown scanner report not mirrored through a generic fallback'
    Assert-Equal $before (Get-ProtectedManifest $f) 'Rejected unknown scanner changes no source/archive files'
}
Run-Test 'Distinct display names that sanitize identically still produce separate safe scanner folders'{
    $cfg=New-TestConfig 'SanitizedScannerNames'
    $cfg.Sources[0].Name='Scanner/A'
    $cfg.Sources[1].Name='Scanner:A'
    $cfg.Sources[2].Name='CT_Edge'
    foreach($source in $cfg.Sources){[void](Add-Report $cfg $source.Scanner 'Quality_Daily' '2025-12-01' '06-00-00' 1800)}
    [void](Import-Fixture $cfg)
    $f=[pscustomobject]@{Config=$cfg;Records=@((Get-QaDashboard -Config $cfg).Records);Sources=@($cfg.Sources|ForEach-Object{$_.Path});Browse=(Join-Path $cfg.ArchiveRoot 'Browse Reports')}
    $before=Get-ProtectedManifest $f
    $result=Invoke-QaBrowseRefresh -Config $cfg
    Assert-Equal 3 $result.Summary.Exported 'Every configured scanner receives a mirror despite sanitized name collision'
    Assert-Equal 0 $result.Summary.Failed 'Sanitized display name collision is safely resolved'
    $pdfs=@(Get-BrowsePdfs $f)
    Assert-Equal 3 $pdfs.Count 'Three same-basename PDFs retained'
    $folders=New-Object 'System.Collections.Generic.List[string]'
    foreach($pdf in $pdfs){
        $relative=$pdf.FullName.Substring($f.Browse.Length).TrimStart('\','/')
        $folder=($relative -split '[\\/]')[0]
        $folders.Add($folder)
        Assert-True ($folder -notmatch '[<>:"/\\|?*\x00-\x1f]') 'Scanner folder is safe for Windows'
    }
    Assert-Equal 3 @($folders.ToArray()|Select-Object -Unique).Count 'Sanitized names cannot merge different scanner folders'
    $hashes=@($pdfs|ForEach-Object{(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}|Sort-Object)
    Assert-Equal 0 @(Compare-Object @($f.Records.Hash|Sort-Object) $hashes).Count 'Every mirrored PDF matches its archived record'
    Assert-Equal $before (Get-ProtectedManifest $f) 'Display name sanitization changes no source/archive protected files'
}
$failed=@($script:Results|Where-Object{$_.Result -eq 'FAIL'}).Count
$skipped=@($script:Results|Where-Object{$_.Result -eq 'SKIP'}).Count
$passed=@($script:Results|Where-Object{$_.Result -eq 'PASS'}).Count
$report=[pscustomobject]@{Product='CT QA Manager Pro';Suite='Readable Browse Reports mirror';TimestampUtc=[datetime]::UtcNow.ToString('o');Runtime=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1);Tests=$script:Results.Count;Assertions=$script:Assertions;Passed=$passed;Skipped=$skipped;Failed=$failed;Results=@($script:Results.ToArray());FixturesKept=[bool]$KeepFixtures}
if($OutputPath){$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
Write-Host ('Result: '+$passed+'/'+$script:Results.Count+' tests passed; '+$script:Assertions+' assertions; '+$skipped+' skipped; PowerShell '+$PSVersionTable.PSVersion)
if($KeepFixtures){Write-Host ('Synthetic fixtures: '+$TestRoot)}else{Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue}
if($failed -gt 0){exit 1}
