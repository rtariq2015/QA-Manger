# Synthetic configurable-scanner and protected-credential tests. No real credentials.
[CmdletBinding()]
param([string]$OutputPath='', [switch]$KeepFixtures)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProductRoot 'App/Archive.psm1') -Force
Import-Module (Join-Path $ProductRoot 'App/Reports.psm1') -Force
$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_ConnectionsSynthetic_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestRoot)
$script:Results=New-Object 'System.Collections.Generic.List[object]'
$script:Assertions=0
function Assert-True([bool]$Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw ('Assertion failed: '+$Message)}}
function Assert-Equal($Expected,$Actual,[string]$Message){Assert-True ([string]$Expected -ceq [string]$Actual) ($Message+'; expected='+[string]$Expected+'; actual='+[string]$Actual)}
function Run-Test([string]$Name,[scriptblock]$Body){
    try{& $Body;$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''});Write-Host ('PASS  '+$Name)}
    catch{
        $result=if($_.Exception.Message.StartsWith('[SKIP]')){'SKIP'}else{'FAIL'}
        $script:Results.Add([pscustomobject]@{Name=$Name;Result=$result;Details=$_.Exception.Message+' '+$_.ScriptStackTrace});Write-Host ($result+'  '+$Name+': '+$_.Exception.Message)
    }
}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Run-Tests.ps1'),[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'Fixture helpers could not be parsed.'}
foreach($name in @('New-TestConfig','New-TestPdf','Add-Report','Import-Fixture')){
    $definition=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($definition.Count -ne 1){throw ('Missing fixture helper: '+$name)}
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
function New-AdditionalScanner($Config,[string]$Id='CT_Annex',[string]$Name='Annex CT',[string]$Letter='Z'){
    $source=$Config.Sources[0]|Select-Object *
    $source.Scanner=$Id;$source.Name=$Name;$source.DriveLetter=$Letter;$source.Path=Join-Path $Config.AppRoot $Id;$source.MonthlyThresholdKB=85
    [void][IO.Directory]::CreateDirectory($source.Path)
    return $source
}
function Assert-ConfigRejected($Config,[string]$Message){
    $rejected=$false
    try{[void](Invoke-QaOperation -Config $Config -Mode Preview)}catch{$rejected=$true}
    Assert-True $rejected $Message
    Assert-True (-not [IO.Directory]::Exists($Config.ArchiveRoot)) 'Invalid configuration writes no archive directory'
}
Run-Test 'Adding a fourth configured scanner imports and updates it without changing existing scanner reports'{
    $cfg=New-TestConfig 'FourthScanner'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' '2025-12-01')
    [void](Add-Report $cfg 'CT_Flash' 'Quality_Daily' '2025-12-02')
    [void](Add-Report $cfg 'MDP_Building' 'Quality_Daily' '2025-12-03')
    [void](Import-Fixture $cfg)
    $old=@((Get-QaDashboard -Config $cfg).Records)
    $timestamps=@{};foreach($row in $old){$timestamps[$row.Id]=(Get-Item -LiteralPath $row.DestinationPath).LastWriteTimeUtc.Ticks}
    $annex=New-AdditionalScanner $cfg
    $cfg.Sources=@($cfg.Sources)+@($annex)
    [void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
    $roundtrip=Read-QaConfig -AppRoot $cfg.AppRoot
    Assert-Equal 4 @($roundtrip.Sources).Count 'Fourth scanner persists in editable settings'
    Assert-Equal 'Annex CT' @($roundtrip.Sources|Where-Object{$_.Scanner -eq 'CT_Annex'})[0].Name 'Configured scanner display name persists'
    $src=Add-Report $cfg 'CT_Annex' 'Quality_Constancy' '2025-12-04' '06-00-00' 95000
    $sourceHash=(Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
    $update=Invoke-QaOperation -Config $cfg -Mode Update
    Assert-Equal 1 $update.Summary.Copied 'Only the new scanner report is copied'
    Assert-Equal 3 $update.Summary.Unchanged 'Existing three scanner reports use metadata cache'
    $dash=Get-QaDashboard -Config $cfg
    Assert-Equal 4 $dash.TotalReports 'All four scanner reports retained'
    Assert-Equal 4 @($dash.Scanners).Count 'Dashboard includes four configured scanner statuses'
    $status=@($dash.Scanners|Where-Object{$_.Scanner -eq 'CT_Annex'})[0]
    Assert-Equal 'Annex CT' $status.Name 'Dashboard uses configured scanner name'
    Assert-Equal 1 $status.SavedReports 'Fourth scanner saved count correct'
    foreach($row in $old){
        $kept=@($dash.Records|Where-Object{$_.Id -eq $row.Id})
        Assert-Equal 1 $kept.Count 'Original report identity preserved'
        Assert-Equal $row.DestinationPath $kept[0].DestinationPath 'Original archive path preserved'
        Assert-Equal $row.Hash (Get-FileHash -LiteralPath $row.DestinationPath -Algorithm SHA256).Hash 'Original archive bytes unchanged'
        Assert-Equal $timestamps[$row.Id] (Get-Item -LiteralPath $row.DestinationPath).LastWriteTimeUtc.Ticks 'Original PDF not rewritten'
    }
    $annexRows=@($dash.Records|Where-Object{$_.Scanner -eq 'CT_Annex'})
    Assert-Equal 1 $annexRows.Count 'Fourth scanner indexed once'
    Assert-Equal 'Monthly_QA/Pending_Verification' $annexRows[0].Category 'Configured fourth scanner threshold stages a candidate without confirming Monthly'
    Assert-Equal $sourceHash (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash 'Fourth scanner original remains untouched'
    $index=@(Import-Csv -LiteralPath (Join-Path $cfg.ArchiveRoot 'QA_Master_Index.csv'))
    Assert-Equal 1 @($index|Where-Object{$_.Scanner -eq 'CT_Annex'}).Count 'Searchable index includes fourth scanner'
    $repeat=Invoke-QaOperation -Config $cfg -Mode Update
    Assert-Equal 4 $repeat.Summary.Unchanged 'Repeated update skips all four unchanged reports'
    Assert-Equal 0 $repeat.Summary.Verified 'Repeated update performs no unnecessary full-file verification'
    Assert-Equal 0 $repeat.Summary.Copied 'Repeated update copies nothing'
    $filtered=@(Select-QaReports -Records $dash.Records -Scanner 'CT_Annex' -Years @(2025) -Month 12)
    Assert-Equal 1 $filtered.Count 'Report filtering accepts the configured fourth scanner ID'
    Assert-Equal $annexRows[0].Id $filtered[0].Id 'Filter keeps exact fourth scanner report identity'
    Assert-Equal 1 @(Select-QaReports -Records $dash.Records -Query 'Annex CT').Count 'Configured fourth scanner display name is searchable'
    Assert-True ((Get-QaReportTitle -Record $filtered[0]) -match 'Annex CT') 'Friendly report title uses the configured display name'
    $output=Join-Path $TestRoot 'FourthScanner.zip'
    $export=Invoke-QaExport -Config $cfg -RecordIds @($filtered.Id) -DestinationPath $output
    Assert-Equal 1 $export.Summary.Exported 'Fourth scanner selected report exports'
    Assert-Equal 0 $export.Summary.Failed 'Configured scanner export is accepted'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($output)
    try{
        $pdfs=@($zip.Entries|Where-Object{$_.FullName -match '(?i)\.pdf$'})
        Assert-Equal 1 $pdfs.Count 'ZIP contains exactly the fourth scanner selected PDF'
        Assert-True ($pdfs[0].FullName.StartsWith('Annex CT/')) 'ZIP uses the configured scanner display name'
        $stream=$pdfs[0].Open();$sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')}finally{$sha.Dispose();$stream.Dispose()}
        Assert-Equal $sourceHash $hash 'Fourth scanner ZIP bytes match index and original source hash'
        foreach($metadataName in @('Report list.csv','QA Report Summary.html')){
            $entry=$zip.GetEntry($metadataName)
            Assert-True ($null -ne $entry) ('Fourth scanner export includes '+$metadataName)
            $stream=$entry.Open();$reader=New-Object IO.StreamReader($stream)
            try{$text=$reader.ReadToEnd()}finally{$reader.Dispose();$stream.Dispose()}
            Assert-True ($text.Contains('Annex CT')) 'Configured scanner display name preserved in exported metadata'
        }
    }finally{$zip.Dispose()}
}
Run-Test 'A single configured scanner can complete setup and a cached update'{
    $cfg=New-TestConfig 'SingleScanner';$cfg.Sources=@($cfg.Sources[0])
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' '2025-12-01')
    [void](Import-Fixture $cfg)
    $dash=Get-QaDashboard -Config $cfg
    Assert-Equal 1 @($dash.Scanners).Count 'Single scanner dashboard is supported'
    Assert-Equal 1 $dash.TotalReports 'Single scanner report archived'
    $update=Invoke-QaOperation -Config $cfg -Mode Update
    Assert-Equal 1 $update.Summary.Unchanged 'Single scanner cached update supported'
}
Run-Test 'Twenty configured scanners are accepted; zero or twenty-one are rejected before writes'{
    $cfg=New-TestConfig 'MaximumSources';$sources=New-Object 'System.Collections.Generic.List[object]'
    for($i=1;$i -le 20;$i++){$sources.Add((New-AdditionalScanner $cfg ('Room'+$i.ToString('00')) ('CT Room '+$i.ToString('00')) ([string][char](67+$i))))}
    $cfg.Sources=@($sources.ToArray())
    $preview=Invoke-QaOperation -Config $cfg -Mode Preview
    Assert-Equal 20 @($preview.Scanners).Count 'Maximum twenty scanner sources accepted'
    Assert-True (-not [IO.Directory]::Exists($cfg.ArchiveRoot)) 'Maximum scanner preview remains read-only'
    $cfg.Sources=@($sources.ToArray())+@(New-AdditionalScanner $cfg 'Room21' 'CT Room 21' 'X')
    Assert-ConfigRejected $cfg 'Twenty-one sources rejected'
    $cfg.Sources=@()
    Assert-ConfigRejected $cfg 'Zero sources rejected'
}
Run-Test 'Unsafe or colliding scanner identities, names, and drive letters are rejected before writes'{
    foreach($case in @('DuplicateId','UnsafeId','ReservedId','DuplicateName','DuplicateDrive','DuplicatePath')){
        $cfg=New-TestConfig ('InvalidSource'+$case)
        switch($case){
            DuplicateId {$cfg.Sources[1].Scanner=$cfg.Sources[0].Scanner}
            UnsafeId {$cfg.Sources[1].Scanner='../../outside'}
            ReservedId {$cfg.Sources[1].Scanner='CON'}
            DuplicateName {$cfg.Sources[1].Name=$cfg.Sources[0].Name}
            DuplicateDrive {$cfg.Sources[1].DriveLetter=$cfg.Sources[0].DriveLetter}
            DuplicatePath {$cfg.Sources[1].Path=$cfg.Sources[0].Path}
        }
        Assert-ConfigRejected $cfg ($case+' rejected')
    }
}
Run-Test 'An archived scanner identity absent from configuration is not silently trusted'{
    $cfg=New-TestConfig 'UnconfiguredIdentity'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' '2025-12-01')
    [void](Import-Fixture $cfg)
    $statePath=Join-Path $cfg.ArchiveRoot '.ctqa/state.json'
    $state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json;$state.Records[0].Scanner='CT_Ghost'
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($true))
    $rejected=$false
    try{[void](Get-QaDashboard -Config $cfg)}catch{$rejected=$true}
    Assert-True $rejected 'Unknown archived scanner rejected even though its ID syntax is safe'
}
Run-Test 'Connection edits cannot remove report identities; a display-name edit preserves the archive'{
    $cfg=New-TestConfig 'ProtectedConnectionEdits'
    [void](Add-Report $cfg 'CT_Edge' 'Quality_Daily' '2025-12-01')
    [void](Import-Fixture $cfg)
    [void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
    $before=@((Get-QaDashboard -Config $cfg).Records)[0]
    $settingsPath=Join-Path $cfg.AppRoot 'Config/Settings.json'
    $statePath=Join-Path $cfg.ArchiveRoot '.ctqa/state.json'
    $settingsHash=(Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
    $stateHash=(Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
    $candidate=$cfg|ConvertTo-Json -Depth 12|ConvertFrom-Json
    $candidate.Sources=@($candidate.Sources|Where-Object{$_.Scanner -ne 'CT_Edge'})
    $rejected=$false
    try{[void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $candidate)}catch{$rejected=$true}
    Assert-True $rejected 'Removing a scanner with archived reports is rejected before settings persistence'
    Assert-Equal $settingsHash (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash 'Rejected edit preserves prior settings'
    Assert-Equal $stateHash (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash 'Rejected edit preserves archive state'
    $candidate=$cfg|ConvertTo-Json -Depth 12|ConvertFrom-Json
    $candidate.Sources[0].Scanner='CT_Renamed'
    $rejected=$false
    try{[void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $candidate)}catch{$rejected=$true}
    Assert-True $rejected 'Changing an archived scanner identity cannot orphan its records'
    Assert-Equal $settingsHash (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash 'Rejected identity edit preserves settings'
    $cfg.Sources[0].Name='Main Building CT'
    [void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
    $after=@((Get-QaDashboard -Config $cfg).Records)[0]
    Assert-Equal $before.Id $after.Id 'Display-name edit keeps report identity'
    Assert-Equal $before.DestinationPath $after.DestinationPath 'Display-name edit does not move internal archive PDFs'
    Assert-Equal $before.Hash (Get-FileHash -LiteralPath $after.DestinationPath -Algorithm SHA256).Hash 'Display-name edit preserves original PDF bytes'
    Assert-Equal 'Main Building CT' $after.ScannerName 'Dashboard uses the edited configured display name'
}
Import-Module (Join-Path $ProductRoot 'App/Credentials.psm1') -Force
Run-Test 'Saved sign-ins use Windows protection or refuse before creating any file on other platforms'{
    $secret=[guid]::NewGuid().ToString('N')
    $secure=ConvertTo-SecureString -String $secret -AsPlainText -Force
    $credential=New-Object Management.Automation.PSCredential('SyntheticCredentialTester',$secure)
    try{
        if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){
            $root=Join-Path $TestRoot 'CredentialMustNeverBeCreated'
            $rejected=$false
            try{[void](Save-QaSavedCredential -AppRoot $root -ScannerId 'CT_Edge' -Credential $credential)}catch{$rejected=$true}
            Assert-True $rejected 'Non-Windows save rejected instead of using reversible credential serialization'
            Assert-True (-not [IO.Directory]::Exists($root)) 'No application folder, credential folder, temporary file, or credential file created'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $TestRoot -Filter '*.xml' -Recurse -File -Force).Count 'No credential XML written anywhere in synthetic fixtures'
        }else{
            $cfg=New-TestConfig 'WindowsProtectedCredential'
            $cfg.Sources[0].Username=$credential.UserName
            [void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
            $result=Save-QaSavedCredential -AppRoot $cfg.AppRoot -ScannerId 'CT_Edge' -Credential $credential
            Assert-True ([bool]$result.Saved) 'Windows protected credential saved'
            Assert-True ([bool]$result.Stored) 'Windows encrypted credential is reported as stored'
            $path=Join-Path $cfg.AppRoot 'Config/Credentials/CT_Edge.xml'
            Assert-True ([IO.File]::Exists($path)) 'Encrypted credential envelope exists'
            Assert-True (-not [IO.File]::ReadAllText($path).Contains($secret)) 'Credential envelope contains no plaintext synthetic password'
            $loaded=Get-QaSavedCredential -AppRoot $cfg.AppRoot -ScannerId 'CT_Edge' -ExpectedUsername $credential.UserName
            Assert-True ($loaded -is [Management.Automation.PSCredential]) 'Credential loads for same Windows user and connection'
            Assert-Equal $credential.Password.Length $loaded.Password.Length 'Protected SecureString length round-trips'
            Assert-True ($null -eq (Get-QaSavedCredential -AppRoot $cfg.AppRoot -ScannerId 'CT_Edge' -ExpectedUsername 'DifferentSyntheticUser')) 'Expected username mismatch cannot reuse saved credential'
            $differentExpectedPath=Join-Path $TestRoot 'DifferentExpectedConnectionPath'
            Assert-True ($null -eq (Get-QaSavedCredential -AppRoot $cfg.AppRoot -ScannerId 'CT_Edge' -ExpectedUsername $credential.UserName -ExpectedPath $differentExpectedPath)) 'Expected source path mismatch cannot reuse saved credential'
            $credentialFileHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $saveRejected=$false
            try{[void](Save-QaSavedCredential -AppRoot $cfg.AppRoot -ScannerId 'CT_Edge' -Credential $credential -ExpectedPath $differentExpectedPath)}catch{$saveRejected=$true}
            Assert-True $saveRejected 'Expected source snapshot mismatch rejects a credential save'
            Assert-Equal $credentialFileHash (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash 'Rejected mismatched-source save preserves the existing encrypted credential'
            $oldPath=$cfg.Sources[0].Path
            $cfg.Sources[0].Path=Join-Path $TestRoot 'DifferentSyntheticServerFolder';[void][IO.Directory]::CreateDirectory($cfg.Sources[0].Path)
            [void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
            Assert-True ($null -eq (Get-QaSavedCredential -AppRoot $cfg.AppRoot -ScannerId 'CT_Edge')) 'Edited source path cannot receive a previous connection credential'
            $mismatchedStatus=Get-QaCredentialStatus -AppRoot $cfg.AppRoot -ScannerId 'CT_Edge'
            Assert-True (-not [bool]$mismatchedStatus.Saved -and [bool]$mismatchedStatus.Stored) 'Unusable encrypted sign-in remains identifiable for explicit removal'
            $cfg.Sources[0].Path=$oldPath;$cfg.Sources[0].Username='DifferentSyntheticUser'
            [void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
            Assert-True ($null -eq (Get-QaSavedCredential -AppRoot $cfg.AppRoot -ScannerId 'CT_Edge')) 'Edited username cannot silently reuse previous credential'
            $cfg.Sources[0].Username=$credential.UserName;[void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
            [void](Remove-QaSavedCredential -AppRoot $cfg.AppRoot -ScannerId 'CT_Edge')
            Assert-True (-not [IO.File]::Exists($path)) 'Explicit remove deletes only the configured encrypted sign-in'
        }
    }finally{$secure.Dispose();$credential=$null;$secret=$null}
}
Run-Test 'Credential status and reads do not create files; non-Windows remove refuses without changes'{
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){
        $root=Join-Path $TestRoot 'ReadOnlyCredentialStatus'
        $status=Get-QaCredentialStatus -AppRoot $root -ScannerId 'CT_Edge' -ExpectedUsername 'SyntheticCredentialTester'
        Assert-True (-not [bool]$status.Saved) 'Non-Windows status never falsely reports a protected saved sign-in'
        Assert-True (-not [bool]$status.Stored) 'Non-Windows status does not claim protected credential storage'
        Assert-True ($null -eq (Get-QaSavedCredential -AppRoot $root -ScannerId 'CT_Edge')) 'Non-Windows read returns no credential'
        Assert-True (-not [IO.Directory]::Exists($root)) 'Reading credential status creates no folders'
        $rejected=$false
        try{[void](Remove-QaSavedCredential -AppRoot $root -ScannerId 'CT_Edge')}catch{$rejected=$true}
        Assert-True $rejected 'Non-Windows remove explicitly refuses unsupported protected storage'
        Assert-True (-not [IO.Directory]::Exists($root)) 'Non-Windows remove creates no files or folders'
        $existing=Join-Path $TestRoot 'ExistingSyntheticCredential';$path=Join-Path $existing 'Config/Credentials/CT_Edge.xml'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));[IO.File]::WriteAllText($path,'Synthetic sentinel, not a real credential')
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        try{[void](Remove-QaSavedCredential -AppRoot $existing -ScannerId 'CT_Edge')}catch{}
        Assert-Equal $hash (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash 'Unsupported remove preserves any existing file'
    }else{
        $cfg=New-TestConfig 'WindowsEmptyCredentialStatus';[void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
        $status=Get-QaCredentialStatus -AppRoot $cfg.AppRoot -ScannerId 'CT_Edge'
        Assert-True (-not [bool]$status.Saved) 'Empty Windows credential store reports no saved sign-in'
        Assert-True ($null -eq (Get-QaSavedCredential -AppRoot $cfg.AppRoot -ScannerId 'CT_Edge')) 'Missing Windows credential returns null'
        Assert-True (-not [IO.Directory]::Exists((Join-Path $cfg.AppRoot 'Config/Credentials'))) 'Read-only status does not create a credential directory'
    }
}
Run-Test 'Credential IDs cannot traverse paths or use Windows reserved connection identities'{
    $root=Join-Path $TestRoot 'InvalidCredentialIds'
    $secure=ConvertTo-SecureString -String ([guid]::NewGuid().ToString('N')) -AsPlainText -Force
    $credential=New-Object Management.Automation.PSCredential('SyntheticCredentialTester',$secure)
    try{
        foreach($id in @('../../outside','bad/id','CON','All','LPT1')){
            $rejected=$false
            try{[void](Get-QaCredentialStatus -AppRoot $root -ScannerId $id)}catch{$rejected=$true}
            Assert-True $rejected ('Unsafe status identity rejected: '+$id)
            $rejected=$false
            try{[void](Save-QaSavedCredential -AppRoot $root -ScannerId $id -Credential $credential)}catch{$rejected=$true}
            Assert-True $rejected ('Unsafe save identity rejected: '+$id)
        }
        Assert-True (-not [IO.Directory]::Exists($root)) 'Invalid identities create no credential or temporary folders'
    }finally{$secure.Dispose();$credential=$null}
}

Run-Test 'Actual background worker isolates one unreadable sign-in and continues every configured scanner'{
    $uiPath=Join-Path $ProductRoot 'App/Start.ps1';$tokens=$null;$errors=$null
    $uiAst=[Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$tokens,[ref]$errors)
    $assignments=@($uiAst.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$workerCode'},$true))
    Assert-Equal 1 $assignments.Count 'Actual embedded background worker is identifiable'
    $worker=$assignments[0].Right.Expression.Value
    $fixture=Join-Path $TestRoot 'WorkerCredentialIsolation';$app=Join-Path $fixture 'App';[void][IO.Directory]::CreateDirectory($app)
    $archiveMock=@'
function Invoke-QaOperation {param($Config,$Mode,$Progress,$Plan,$Decisions,$LegacyRoot) return [pscustomobject]@{Mode=$Mode;Summary=[pscustomobject]@{Total=@($Config.Sources).Count;Copied=@($Config.Sources).Count;Failed=0;Cancelled=$false};Scanners=@($Config.Sources|ForEach-Object{[pscustomobject]@{Scanner=$_.Scanner;Status='Connected'}})}}
Export-ModuleMember Invoke-QaOperation
'@
    $credentialsMock=@'
function Get-QaSavedCredential {param($AppRoot,$ScannerId,$ExpectedUsername,$ExpectedPath) if($ScannerId -eq 'CT_Edge'){throw 'Synthetic DPAPI error detail that must not appear in the supervisor warning'};return $null}
Export-ModuleMember Get-QaSavedCredential
'@
    $networkMock=@'
function Reconnect-QaScanner {param($Scanner,$Credential) return [pscustomobject]@{Scanner=$Scanner.Scanner;Status='Connected';Message='Synthetic existing Windows access'}}
Export-ModuleMember Reconnect-QaScanner
'@
    $encoding=New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText((Join-Path $app 'Archive.psm1'),$archiveMock,$encoding)
    [IO.File]::WriteAllText((Join-Path $app 'Credentials.psm1'),$credentialsMock,$encoding)
    [IO.File]::WriteAllText((Join-Path $app 'Network.psm1'),$networkMock,$encoding)
    $cfg=Get-QaDefaultConfig -AppRoot $fixture
    $annex=$cfg.Sources[0]|Select-Object *;$annex.Scanner='CT_Annex';$annex.Name='Annex CT';$annex.Path='SyntheticAnnex';$annex.DriveLetter='Z'
    $cfg.Sources=@($cfg.Sources)+@($annex)
    foreach($mode in @('Update','Reconnect')){
        $shared=[hashtable]::Synchronized(@{Message='';Percent=0;Cancel=$false;Done=$false;Error='';Result=$null})
        $ps=[PowerShell]::Create()
        try{
            [void]$ps.AddScript($worker).AddArgument($fixture).AddArgument($cfg).AddArgument($mode).AddArgument($shared).AddArgument($null).AddArgument(@()).AddArgument('').AddArgument(@{})
            $handle=$ps.BeginInvoke();$completed=$handle.AsyncWaitHandle.WaitOne(15000)
            Assert-True $completed 'Actual worker completes within the synthetic test timeout'
            [void]$ps.EndInvoke($handle)
            Assert-True ([string]::IsNullOrWhiteSpace([string]$shared.Error)) 'One credential read failure does not abort the worker'
            Assert-True ([bool]$shared.Done) 'Worker reports completion'
            Assert-Equal 1 @($shared.Result.ConnectionWarnings).Count 'Credential failure remains visible as one plain-language warning'
            Assert-True ((@($shared.Result.ConnectionWarnings)-join ' ') -notmatch 'Synthetic DPAPI error detail') 'Detailed credential exception text is not exposed in supervisor warnings'
            if($mode -eq 'Update'){
                Assert-Equal 4 $shared.Result.Summary.Copied 'All four synthetic scanner updates continue'
                Assert-Equal 4 @($shared.Result.Scanners).Count 'Fourth scanner retained through actual update wrapper'
            }else{
                Assert-Equal 4 @($shared.Result.Connections).Count 'Reconnect continues across all four configured scanners'
                Assert-Equal 1 @($shared.Result.Connections|Where-Object{$_.Scanner -eq 'CT_Annex'}).Count 'Fourth scanner not lost during reconnect wrapper dispatch'
            }
        }finally{$ps.Dispose()}
    }
}
Run-Test 'A saved scanner path change rebinds the same relative file and hash without duplicating reviewed reports'{
    $cfg=New-TestConfig 'KnownSourceAlias'
    [void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
    $oldRoot=[string]$cfg.Sources[0].Path
    $src=Add-Report $cfg 'CT_Edge' 'Quality_Constancy' '2025-12-01' '06-00-00' 76000 'OriginalSession'
    [void](Import-Fixture $cfg)
    $pending=@((Get-QaDashboard -Config $cfg).Records)[0]
    $decisions=@([pscustomobject]@{RecordId=$pending.Id;Category='Monthly_QA';Reviewer='Synthetic alias reviewer';Reason='Verified original file before a configured network-root change'})
    [void](Invoke-QaOperation -Config $cfg -Mode Reclassify -Decisions $decisions)
    $old=@((Get-QaDashboard -Config $cfg).Records)[0]
    $destinationStamp=(Get-Item -LiteralPath $old.DestinationPath).LastWriteTimeUtc.Ticks
    $newRoot=Join-Path $cfg.AppRoot 'EdgeNewNetworkRoot'
    $newSource=Join-Path (Join-Path $newRoot 'OriginalSession') $old.OriginalFileName
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($newSource));[IO.File]::Copy($src,$newSource)
    $cfg.Sources[0].Path=$newRoot
    [void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
    $cfg=Read-QaConfig -AppRoot $cfg.AppRoot
    Assert-True (@($cfg.Sources[0].PreviousPaths) -contains $oldRoot) 'Old root recorded only through an explicit saved connection edit'
    # Simulate the previous IP/share no longer being reachable. The engine must
    # compare aliases as identity evidence, never enumerate the old root again.
    $offlineOldRoot=$oldRoot+'_OfflineFixture';[IO.Directory]::Move($oldRoot,$offlineOldRoot)
    $oldSourceHash=(Get-FileHash -LiteralPath (Join-Path (Join-Path $offlineOldRoot 'OriginalSession') $old.OriginalFileName) -Algorithm SHA256).Hash
    $update=Invoke-QaOperation -Config $cfg -Mode Update
    $rows=@((Get-QaDashboard -Config $cfg).Records)
    Assert-Equal 1 $rows.Count 'Same report is not duplicated after the saved source-root change'
    Assert-Equal 0 $update.Summary.Copied 'No second archive PDF copied for an identical known-alias report'
    Assert-Equal $old.Id $rows[0].Id 'Original report identity remains stable'
    Assert-Equal $old.DestinationPath $rows[0].DestinationPath 'Existing archive PDF path stays stable'
    Assert-Equal $destinationStamp (Get-Item -LiteralPath $rows[0].DestinationPath).LastWriteTimeUtc.Ticks 'Existing archive PDF not rewritten'
    Assert-Equal 'Monthly_QA' $rows[0].Category 'Exact reviewed content retains its classification'
    Assert-Equal $old.ConfirmedBy $rows[0].ConfirmedBy 'Reviewer preserved'
    Assert-Equal $old.ConfirmedAt $rows[0].ConfirmedAt 'Review timestamp preserved'
    Assert-Equal $old.FirstArchived $rows[0].FirstArchived 'Original archive timestamp preserved'
    Assert-Equal ([IO.Path]::GetFullPath($newSource)) $rows[0].SourcePath 'Source metadata rebinds to the newly saved network root'
    Assert-Equal $old.Hash (Get-FileHash -LiteralPath $rows[0].DestinationPath -Algorithm SHA256).Hash 'Reviewed archive content remains exact'
    $repeat=Invoke-QaOperation -Config $cfg -Mode Update
    Assert-Equal 1 $repeat.Summary.Unchanged 'Next update fast-skips the rebound source metadata'
    Assert-Equal 0 $repeat.Summary.Verified 'Next update avoids a repeated full hash'
    Assert-Equal 0 $repeat.Summary.Copied 'Next update copies nothing'
    # Force the slow metadata path after rebind. The content is unchanged but
    # the new source-root-derived hash ID would differ from the preserved ID.
    (Get-Item -LiteralPath $newSource).LastWriteTimeUtc=[datetime]::UtcNow.AddMinutes(-3)
    $touched=Invoke-QaOperation -Config $cfg -Mode Update
    $afterTouch=@((Get-QaDashboard -Config $cfg).Records)
    Assert-Equal 1 $afterTouch.Count 'Metadata-only source touch after rebind cannot duplicate the preserved report'
    Assert-Equal 0 $touched.Summary.Copied 'Metadata-only touch does not copy another archive PDF'
    Assert-True ($touched.Summary.Verified -ge 1) 'Touched source content is verified before reusing its identity'
    Assert-Equal $old.Id $afterTouch[0].Id 'Metadata-only slow path preserves the original report identity'
    Assert-Equal $old.ConfirmedBy $afterTouch[0].ConfirmedBy 'Metadata-only slow path preserves reviewed evidence'
    Assert-Equal $old.DestinationPath $afterTouch[0].DestinationPath 'Metadata-only slow path preserves the archive path'
    $damagedPath=$afterTouch[0].DestinationPath
    $damaged=[IO.File]::ReadAllBytes($damagedPath);$damaged[100]=[byte]($damaged[100] -bxor 1);[IO.File]::WriteAllBytes($damagedPath,$damaged)
    $damagedHash=(Get-FileHash -LiteralPath $damagedPath -Algorithm SHA256).Hash
    [void](Invoke-QaOperation -Config $cfg -Mode Update)
    $repaired=@((Get-QaDashboard -Config $cfg).Records)
    Assert-Equal 1 $repaired.Count 'Repair after a source rebind keeps one report identity'
    Assert-Equal $old.Id $repaired[0].Id 'Repair preserves the pre-rebind identity'
    Assert-Equal $old.ConfirmedBy $repaired[0].ConfirmedBy 'Repair preserves exact-content review provenance'
    Assert-True (@($repaired[0].SourceAliases) -contains [string]$old.SourcePath) 'Repair retains the original source alias history'
    Assert-Equal $old.Hash (Get-FileHash -LiteralPath $repaired[0].DestinationPath -Algorithm SHA256).Hash 'Repaired current PDF is verified against the original indexed hash'
    Assert-True ($repaired[0].DestinationPath -ne $damagedPath) 'Repair uses a new path instead of overwriting damaged bytes'
    Assert-Equal $damagedHash (Get-FileHash -LiteralPath $damagedPath -Algorithm SHA256).Hash 'Damaged historical bytes remain preserved for investigation'
    [void](New-TestPdf -Path $newSource -Size 79000 -Text 'Changed bytes after the known-alias rebind')
    [void](Invoke-QaOperation -Config $cfg -Mode Update)
    $rows=@((Get-QaDashboard -Config $cfg).Records)
    Assert-Equal 2 $rows.Count 'Changed bytes create a distinct retained revision'
    Assert-Equal 1 @($rows|Where-Object{$_.Category -eq 'Monthly_QA'}).Count 'Only the previously reviewed bytes remain confirmed Monthly'
    Assert-Equal 1 @($rows|Where-Object{$_.Category -eq 'Monthly_QA/Pending_Verification'}).Count 'New bytes await a new review'
    Assert-Equal $oldSourceHash (Get-FileHash -LiteralPath (Join-Path (Join-Path $offlineOldRoot 'OriginalSession') $old.OriginalFileName) -Algorithm SHA256).Hash 'Old offline source bytes were never changed'
}
Run-Test 'A known root alias never merges identical basenames from different relative source folders'{
    $cfg=New-TestConfig 'AliasDifferentRelativeFolder';[void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
    $src=Add-Report $cfg 'CT_Edge' 'Quality_Daily' '2025-12-01' '06-00-00' 1800 'SessionA'
    [void](Import-Fixture $cfg)
    $old=@((Get-QaDashboard -Config $cfg).Records)[0]
    $newRoot=Join-Path $cfg.AppRoot 'DifferentRelativeNewRoot'
    $newSource=Join-Path (Join-Path $newRoot 'SessionB') $old.OriginalFileName
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($newSource));[IO.File]::Copy($src,$newSource)
    $cfg.Sources[0].Path=$newRoot;[void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
    $cfg=Read-QaConfig -AppRoot $cfg.AppRoot
    [void](Invoke-QaOperation -Config $cfg -Mode Update)
    $rows=@((Get-QaDashboard -Config $cfg).Records)
    Assert-Equal 2 $rows.Count 'Different relative folders remain distinct report identities despite matching basename and bytes'
    Assert-Equal 2 @($rows.Id|Select-Object -Unique).Count 'No identity collision or basename-only merge'
    Assert-Equal 2 @($rows.DestinationPath|Select-Object -Unique).Count 'Both legitimate archive copies are preserved'
    Assert-Equal 1 @($rows|Where-Object{$_.Id -eq $old.Id}).Count 'Original report identity remains present'
    Assert-Equal $old.Hash (Get-FileHash -LiteralPath $old.DestinationPath -Algorithm SHA256).Hash 'Original archive bytes unchanged'
}
Run-Test 'Ambiguous prior-root matches never merge two legitimate archived report identities'{
    $cfg=New-TestConfig 'AmbiguousSourceAlias'
    $parent=[string]$cfg.Sources[0].Path
    $a=Add-Report $cfg 'CT_Edge' 'Quality_Daily' '2025-12-01' '06-00-00' 1800 'A'
    $b=Join-Path (Join-Path $parent 'B') ([IO.Path]::GetFileName($a))
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($b));[IO.File]::Copy($a,$b)
    [void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg);[void](Import-Fixture $cfg)
    $old=@((Get-QaDashboard -Config $cfg).Records)
    Assert-Equal 2 $old.Count 'Two different relative source sessions are separately archived before repointing'
    # These saved edits legitimately establish both narrower roots as historical
    # aliases, without fabricating PreviousPaths or changing any archive record.
    foreach($root in @([IO.Path]::GetDirectoryName($a),[IO.Path]::GetDirectoryName($b))){
        $cfg.Sources[0].Path=$root;[void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg);$cfg=Read-QaConfig -AppRoot $cfg.AppRoot
    }
    $currentRoot=Join-Path $cfg.AppRoot 'AmbiguousCurrentRoot';[void][IO.Directory]::CreateDirectory($currentRoot)
    $current=Join-Path $currentRoot ([IO.Path]::GetFileName($a));[IO.File]::Copy($a,$current)
    $cfg.Sources[0].Path=$currentRoot;[void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg);$cfg=Read-QaConfig -AppRoot $cfg.AppRoot
    Assert-True (@($cfg.Sources[0].PreviousPaths) -contains [IO.Path]::GetDirectoryName($a)) 'First prior root established by a saved edit'
    Assert-True (@($cfg.Sources[0].PreviousPaths) -contains [IO.Path]::GetDirectoryName($b)) 'Second prior root established by a saved edit'
    $result=Invoke-QaOperation -Config $cfg -Mode Update
    $rows=@((Get-QaDashboard -Config $cfg).Records)
    Assert-True ($rows.Count -eq 3 -or ($rows.Count -eq 2 -and $result.Summary.Failed -gt 0)) 'Ambiguous match is preserved as a new identity or explicitly refused; no arbitrary merge'
    foreach($before in $old){
        $kept=@($rows|Where-Object{$_.Id -eq $before.Id})
        Assert-Equal 1 $kept.Count 'Every original identity remains present'
        Assert-Equal $before.SourcePath $kept[0].SourcePath 'Ambiguity cannot silently rebind an arbitrary old source identity'
        Assert-Equal $before.Hash (Get-FileHash -LiteralPath $before.DestinationPath -Algorithm SHA256).Hash 'Every original archive copy remains intact'
    }
}
Run-Test 'Update-on-open defaults on, honors a persisted opt-out, and normalizes older settings read-only'{
    $cfg=New-TestConfig 'StartupUpdatePreference'
    Assert-True ([bool]$cfg.AutoUpdateOnOpen) 'New configuration enables a one-time update when an established archive opens'
    $cfg.AutoUpdateOnOpen=$false
    [void](Save-QaConfig -AppRoot $cfg.AppRoot -Config $cfg)
    $saved=Read-QaConfig -AppRoot $cfg.AppRoot
    Assert-True (-not [bool]$saved.AutoUpdateOnOpen) 'Explicit opt-out persists across settings reload'
    $path=Join-Path $cfg.AppRoot 'Config/Settings.json'
    $older=$saved|Select-Object * -ExcludeProperty AutoUpdateOnOpen
    [IO.File]::WriteAllText($path,($older|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $normalized=Read-QaConfig -AppRoot $cfg.AppRoot
    Assert-True ([bool]$normalized.AutoUpdateOnOpen) 'Older configuration without the preference receives the enabled default'
    Assert-Equal $hash (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash 'Reading older settings does not silently rewrite the settings file'
}
Run-Test 'Actual startup-update decision and callback run once only for an opted-in established archive'{
    $uiPath=Join-Path $ProductRoot 'App/Start.ps1';$tokens=$null;$errors=$null
    $uiAst=[Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$tokens,[ref]$errors)
    foreach($name in @('Value-Or','Should-RunStartupUpdate','Invoke-StartupUpdate')){
        $definition=@($uiAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
        Assert-Equal 1 $definition.Count ('Actual UI function exists: '+$name)
        . ([scriptblock]::Create($definition[0].Extent.Text))
    }
    $ready=[pscustomobject]@{SetupComplete=$true};$newArchive=[pscustomobject]@{SetupComplete=$false}
    Assert-True (Should-RunStartupUpdate -Config ([pscustomobject]@{AutoUpdateOnOpen=$true}) -Dashboard $ready -AlreadyStarted $false) 'Enabled established archive is eligible'
    Assert-True (Should-RunStartupUpdate -Config ([pscustomobject]@{}) -Dashboard $ready -AlreadyStarted $false) 'Missing old preference follows the enabled default'
    Assert-True (-not (Should-RunStartupUpdate -Config ([pscustomobject]@{AutoUpdateOnOpen=$false}) -Dashboard $ready -AlreadyStarted $false)) 'Explicit opt-out is ineligible'
    Assert-True (-not (Should-RunStartupUpdate -Config ([pscustomobject]@{AutoUpdateOnOpen=$true}) -Dashboard $newArchive -AlreadyStarted $false)) 'Unconfirmed first-time setup cannot auto-copy'
    Assert-True (-not (Should-RunStartupUpdate -Config ([pscustomobject]@{AutoUpdateOnOpen=$true}) -Dashboard $ready -AlreadyStarted $true)) 'Handled startup cannot repeat'
    function Start-Work {param([string]$Mode) $script:StartupModes.Add($Mode)}
    foreach($case in @('Enabled','OptOut','NewSetup')){
        $script:StartupHandled=$false;$script:StartupModes=New-Object 'System.Collections.Generic.List[string]'
        $script:Config=[pscustomobject]@{AutoUpdateOnOpen=($case -ne 'OptOut')}
        $script:Dashboard=if($case -eq 'NewSetup'){$newArchive}else{$ready}
        $script:Controls=@{StatusText=[pscustomobject]@{Text=''};StepOne=[pscustomobject]@{Text=''}}
        Invoke-StartupUpdate;Invoke-StartupUpdate
        $expected=if($case -eq 'Enabled'){1}else{0}
        Assert-Equal $expected $script:StartupModes.Count ('Actual callback worker calls: '+$case)
        if($expected -eq 1){Assert-Equal 'Update' $script:StartupModes[0] 'Startup requests the ordinary Update workflow'}
        Assert-True ([bool]$script:StartupHandled) 'Startup event handled once even when no update should run'
    }
    $ui=[IO.File]::ReadAllText($uiPath)
    Assert-True ($ui -match '\.Add_ContentRendered\(\{Invoke-StartupUpdate\}\)') 'Actual callback is bound after the WPF window first renders'
}
$failed=@($script:Results|Where-Object{$_.Result -eq 'FAIL'}).Count;$skipped=@($script:Results|Where-Object{$_.Result -eq 'SKIP'}).Count;$passed=@($script:Results|Where-Object{$_.Result -eq 'PASS'}).Count
$report=[pscustomobject]@{Product='CT QA Manager Pro';Suite='Configurable connections and protected credentials';TimestampUtc=[datetime]::UtcNow.ToString('o');Runtime=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.ToString();WindowsPowerShell51ActuallyRun=($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1);WindowsDPAPIActuallyRun=([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT);Tests=$script:Results.Count;Assertions=$script:Assertions;Passed=$passed;Skipped=$skipped;Failed=$failed;Results=@($script:Results.ToArray());FixturesKept=[bool]$KeepFixtures}
if($OutputPath){$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
Write-Host ('Result: '+$passed+'/'+$script:Results.Count+' tests passed; '+$script:Assertions+' assertions; '+$skipped+' skipped; PowerShell '+$PSVersionTable.PSVersion)
if($KeepFixtures){Write-Host ('Synthetic fixtures: '+$TestRoot)}else{Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue}
if($failed -gt 0){exit 1}
