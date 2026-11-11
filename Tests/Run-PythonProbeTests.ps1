[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackagePath,
    [string]$OutputPath='',
    [switch]$KeepFixtures
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'This test requires native Windows; Linux parsing is not runtime evidence.'}
$ProductRoot=Split-Path -Parent $PSScriptRoot
$PackagePath=[IO.Path]::GetFullPath($PackagePath)
if(-not [IO.File]::Exists($PackagePath)){throw 'The built portable Python test ZIP is required.'}
$public=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDocuments)
if(-not $public){$public=Join-Path $env:SystemDrive 'Users/Public/Documents'}
$TestRoot=Join-Path $public ('CTQA PythonProbeTests '+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestRoot)
$Outside=Join-Path $TestRoot 'Outside working folder'
$Poison=Join-Path $TestRoot 'Poison imports'
foreach($folder in @($Outside,$Poison)){[void][IO.Directory]::CreateDirectory($folder)}
$shadow='raise RuntimeError("SHADOW_IMPORT_CANARY_MUST_NOT_RUN")'+[Environment]::NewLine
foreach($folder in @($Outside,$Poison)){
    [IO.File]::WriteAllText((Join-Path $folder 'pypdf.py'),$shadow,[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $folder 'sitecustomize.py'),$shadow,[Text.Encoding]::ASCII)
}
$script:Results=New-Object 'Collections.Generic.List[object]'
$script:Assertions=0
$script:NonAdministratorActuallyRun=$false
$script:ApplicationNetworkGuardActuallyRun=$false
$script:StandardAccountCreated=$false
$script:StandardAccountCleanupSucceeded=$false
$script:AccountName=''
$script:AccountSid=''
$script:SecurePassword=$null
$script:Cold=$null
$script:MovedRun=$null
$script:OptionalPath=''
$script:OptionalHash=''
$script:OriginalBundleFiles=@{}
$packageHash=(Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash
$mainBefore=@{}
foreach($name in @('Config/Settings.json','App/WebService.psm1','App/Web/index.html')){
    $path=Join-Path $ProductRoot $name
    if([IO.File]::Exists($path)){$mainBefore[$name]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
}
function Check($Condition,[string]$Message){
    $script:Assertions++
    if(-not $Condition){throw ('CHECK: '+$Message)}
}
function Scenario([string]$Name,[scriptblock]$Body){
    try{
        &$Body
        [void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='PASS';Details=''})
        Write-Host ('PASS '+$Name)
    }catch{
        $detail=if($_.Exception.Message.StartsWith('CHECK: ')){$_.Exception.Message.Substring(7)}else{$_.Exception.GetType().Name}
        [void]$script:Results.Add([pscustomobject]@{Name=$Name;Result='FAIL';Details=$detail})
        Write-Host ('FAIL '+$Name+': '+$detail)
    }
}
function Read-Result([string]$Folder){
    $path=Join-Path $Folder 'Results/ProbeResult.json'
    if(-not [IO.File]::Exists($path)){throw 'CHECK: The probe did not create its machine-readable result.'}
    return ([IO.File]::ReadAllText($path)|ConvertFrom-Json)
}
function Invoke-Probe([string]$Folder,[string[]]$ExtraArguments=@()){
    foreach($name in @('ProbeResult.json','ProbeResult.html')){
        $old=Join-Path $Folder ('Results/'+$name)
        if([IO.File]::Exists($old)){[IO.File]::Delete($old)}
    }
    $launcher=Join-Path $Folder 'Run Python Test.cmd'
    $line='"'+$launcher+'" --no-open'
    foreach($argument in $ExtraArguments){
        if($argument -match '["&|<>^%!]'){throw 'Controlled test arguments contain unsupported command characters.'}
        $line+=' "'+$argument+'"'
    }
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Join-Path $env:SystemRoot 'System32/cmd.exe'
    $psi.Arguments='/d /s /c "'+$line+'"'
    $psi.WorkingDirectory=$Outside
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $psi.EnvironmentVariables['PATH']=Join-Path $env:SystemRoot 'System32'
    $psi.EnvironmentVariables['PYTHONHOME']=Join-Path $TestRoot 'Missing Python home'
    $psi.EnvironmentVariables['PYTHONPATH']=$Poison
    $temp=Join-Path $Folder 'Results/Temporary'
    [void][IO.Directory]::CreateDirectory($temp)
    $psi.EnvironmentVariables['TEMP']=$temp
    $psi.EnvironmentVariables['TMP']=$temp
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$psi
    try{
        if(-not $process.Start()){throw 'The controlled command process did not start.'}
        $stdoutTask=$process.StandardOutput.ReadToEndAsync()
        $stderrTask=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(120000)){try{$process.Kill()}catch{};throw 'The portable probe exceeded the bounded test timeout.'}
        $stdout=$stdoutTask.GetAwaiter().GetResult()
        $stderr=$stderrTask.GetAwaiter().GetResult()
        $exit=$process.ExitCode
    }finally{$process.Dispose()}
    return [pscustomobject]@{ExitCode=$exit;Stdout=$stdout;Stderr=$stderr;Summary=(Read-Result $Folder)}
}
function Snapshot-Bundle([string]$Folder){
    $rows=@{}
    foreach($file in @(Get-ChildItem -LiteralPath $Folder -File -Recurse)){
        $relative=$file.FullName.Substring($Folder.TrimEnd('\').Length+1).Replace('\','/')
        if($relative.StartsWith('Results/')){continue}
        $rows[$relative]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $rows
}
function Check-PrivateOutput($Run,[string]$Folder,[string[]]$Canaries){
    $parts=New-Object 'Collections.Generic.List[string]'
    [void]$parts.Add([string]$Run.Stdout)
    [void]$parts.Add([string]$Run.Stderr)
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $Folder 'Results') -File -Recurse)){
        if($file.Extension -in @('.json','.html','.txt','.log')){[void]$parts.Add([IO.File]::ReadAllText($file.FullName))}
    }
    $all=$parts -join [Environment]::NewLine
    foreach($canary in $Canaries){Check (-not $all.Contains($canary)) 'Private canaries are absent from persisted results and process output.'}
    Check ($all -notmatch '(?i)Traceback \(most recent call last\)') 'Python tracebacks are not exposed in the user-facing results.'
}
function New-PrivateCanaryPdf([string]$Path){
    $nl=[char]10
    $stream='BT /F1 12 Tf 40 720 Td (PRIVATE_TEXT_CANARY_73AD82E5) Tj 0 -24 Td (Synthetic optional document only) Tj ET'+$nl
    $objects=@(
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
        ('<< /Length '+[Text.Encoding]::ASCII.GetByteCount($stream)+' >>'+$nl+'stream'+$nl+$stream+'endstream')
    )
    $pdf=New-Object Text.StringBuilder
    [void]$pdf.Append('%PDF-1.4'+$nl)
    $offsets=New-Object 'Collections.Generic.List[int]'
    for($i=0;$i -lt $objects.Count;$i++){
        [void]$offsets.Add([Text.Encoding]::ASCII.GetByteCount($pdf.ToString()))
        [void]$pdf.Append(($i+1).ToString()+' 0 obj'+$nl+$objects[$i]+$nl+'endobj'+$nl)
    }
    $xref=[Text.Encoding]::ASCII.GetByteCount($pdf.ToString())
    [void]$pdf.Append('xref'+$nl+'0 '+($objects.Count+1)+$nl+'0000000000 65535 f '+$nl)
    foreach($offset in $offsets){[void]$pdf.Append($offset.ToString('0000000000')+' 00000 n '+$nl)}
    [void]$pdf.Append('trailer'+$nl+'<< /Size '+($objects.Count+1)+' /Root 1 0 R >>'+$nl+'startxref'+$nl+$xref+$nl+'%%EOF'+$nl)
    [IO.File]::WriteAllText($Path,$pdf.ToString(),[Text.Encoding]::ASCII)
}
$Bundle=Join-Path $TestRoot 'CT_QA_Python_Portable_Test'
$Moved=Join-Path $TestRoot 'Moved portable folder é with spaces'
try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($PackagePath,$TestRoot)
    Scenario 'The package contains a complete interpreter and verified local dependencies' {
        Check ([IO.File]::Exists((Join-Path $Bundle 'runtime/python.exe'))) 'The Python executable is bundled.'
        Check ([IO.File]::Exists((Join-Path $Bundle 'Run Python Test.cmd'))) 'The package has its own CMD launcher.'
        $metadata=[IO.File]::ReadAllText((Join-Path $Bundle 'Package.json'))|ConvertFrom-Json
        Check ($metadata.version -eq '1.0.0') 'The separate compatibility test version is explicit.'
        $manifest=[IO.File]::ReadAllLines((Join-Path $Bundle 'Package-SHA256SUMS.txt'))
        Check ($manifest.Count -gt 10) 'The dependency manifest covers the packaged runtime and reader.'
        foreach($line in $manifest){
            if($line -notmatch '^([0-9a-fA-F]{64})  ([A-Za-z0-9 _./+()-]+)$'){throw 'CHECK: The package manifest has a valid allowlisted structure.'}
            $hash=$matches[1];$relative=$matches[2]
            Check (-not $relative.Contains('..') -and -not [IO.Path]::IsPathRooted($relative)) 'Manifest entries stay inside the portable folder.'
            $file=Join-Path $Bundle $relative
            Check ([IO.File]::Exists($file) -and (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $hash) 'Each dependency matches its packaged SHA-256.'
        }
        $script:OriginalBundleFiles=Snapshot-Bundle $Bundle
    }
    Scenario 'The real CMD launcher works without system Python or inherited Python configuration' {
        $script:Cold=Invoke-Probe $Bundle
        Check ($script:Cold.ExitCode -eq 0) 'The actual portable launcher exits successfully.'
        $r=$script:Cold.Summary
        Check ($r.totals.failed -eq 0 -and $r.totals.passed -ge 5) 'The probe completes its actual local checks.'
        Check ($r.runtime.embeddedExeInBundle -and $r.runtime.pypdfInBundle) 'The interpreter and PDF library are both loaded from the bundle.'
        Check ($r.runtime.isolated -and $r.runtime.noSite -and $r.runtime.noUserSite -and $r.runtime.dontWriteBytecode) 'The embedded process ignores external Python configuration and bytecode writes.'
        $metadata=[IO.File]::ReadAllText((Join-Path $Bundle 'Package.json'))|ConvertFrom-Json
        Check ($r.runtime.version -eq $metadata.pythonVersion -and $r.runtime.pypdfVersion -eq $metadata.pypdfVersion) 'The actual interpreter and reader versions match the package.'
        Check (($script:Cold.Stdout+$script:Cold.Stderr) -notlike '*SHADOW_IMPORT_CANARY*') 'Poisoned import folders and working-directory shadow modules were ignored.'
        $network=@($r.checks|Where-Object id -eq 'NetworkAuditGuard')
        Check ($network.Count -eq 1 -and $network[0].status -eq 'PASS') 'The application-level network audit guard was actually exercised.'
        $script:ApplicationNetworkGuardActuallyRun=$true
    }
    Scenario 'Both generated QA layouts are fully read with their report dates and printed observations' {
        $r=$script:Cold.Summary
        $basic=@($r.fixtures|Where-Object profile -eq 'Basic')
        $extended=@($r.fixtures|Where-Object profile -eq 'Extended')
        Check ($basic.Count -eq 1 -and $extended.Count -eq 1) 'Both distinct test layouts were identified.'
        Check ($basic[0].pages -eq 3 -and $basic[0].readPages -eq 3 -and $basic[0].sectionCount -eq 2 -and $basic[0].printedObservationCount -eq 2) 'All Basic pages and both section observations were read.'
        Check ($extended[0].pages -eq 5 -and $extended[0].readPages -eq 5 -and $extended[0].sectionCount -eq 10 -and $extended[0].printedObservationCount -eq 10) 'All Extended pages and ten section observations were read.'
        Check ($basic[0].date -eq '2026-01-06' -and $extended[0].date -eq '2026-01-01') 'The report dates were distinguished from historical reference dates.'
        Check ($basic[0].dateStatus -eq 'Consensus' -and $extended[0].dateStatus -eq 'Consensus') 'Repeated report footers supplied consistent date evidence.'
    }
    Scenario 'Moving the whole folder preserves operation at a Unicode path containing spaces' {
        [IO.Directory]::Move($Bundle,$Moved)
        $script:MovedRun=Invoke-Probe $Moved
        Check ($script:MovedRun.ExitCode -eq 0 -and $script:MovedRun.Summary.totals.failed -eq 0) 'The moved package launches and completes the same checks.'
        Check ($script:MovedRun.Summary.runtime.embeddedExeInBundle -and $script:MovedRun.Summary.runtime.pypdfInBundle) 'Relocation preserves bundled interpreter and library resolution.'
        Check ([IO.File]::Exists((Join-Path $Moved 'Results/ProbeResult.json'))) 'The moved folder receives its own result without installation.'
    }
    Scenario 'A selected local PDF is read without recording its identity or extracted private text' {
        $script:OptionalPath=Join-Path $TestRoot 'PRIVATE_FILENAME_CANARY_0F24 local report.pdf'
        New-PrivateCanaryPdf $script:OptionalPath
        $script:OptionalHash=(Get-FileHash -LiteralPath $script:OptionalPath -Algorithm SHA256).Hash
        $run=Invoke-Probe $Moved @('--pdf',$script:OptionalPath)
        Check ($run.ExitCode -eq 0 -and $run.Summary.totals.failed -eq 0) 'The optional document does not replace the portability checks.'
        Check ($run.Summary.optionalPdf.selected -and $run.Summary.optionalPdf.readable -and $run.Summary.optionalPdf.pages -eq 1 -and $run.Summary.optionalPdf.readPages -eq 1) 'The actual selected PDF was opened and read.'
        Check-PrivateOutput $run $Moved @('PRIVATE_FILENAME_CANARY_0F24','PRIVATE_TEXT_CANARY_73AD82E5',$script:OptionalPath,$TestRoot)
        Check ((Get-FileHash -LiteralPath $script:OptionalPath -Algorithm SHA256).Hash -eq $script:OptionalHash) 'The selected original PDF remains byte-for-byte unchanged.'
    }
    Scenario 'An unreadable selected PDF returns a separate scrubbed result without breaking the runtime test' {
        $path=Join-Path $TestRoot 'PRIVATE_INVALID_FILENAME_CANARY_F324.pdf'
        [IO.File]::WriteAllText($path,'PRIVATE_INVALID_TEXT_CANARY_B37C',[Text.Encoding]::ASCII)
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $run=Invoke-Probe $Moved @('--pdf',$path)
        Check ($run.ExitCode -eq 0 -and $run.Summary.totals.failed -eq 0) 'Unsupported input remains separate from a successful Python compatibility test.'
        Check ($run.Summary.optionalPdf.selected -and -not $run.Summary.optionalPdf.readable -and $run.Summary.optionalPdf.status -eq 'ReadError') 'The unreadable optional input receives an explicit read-error status.'
        Check-PrivateOutput $run $Moved @('PRIVATE_INVALID_FILENAME_CANARY_F324','PRIVATE_INVALID_TEXT_CANARY_B37C',$path,$TestRoot)
        Check ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $hash) 'The unreadable selected input is preserved.'
    }
    Scenario 'An altered packaged PDF dependency is rejected before PDF analysis' {
        $tampered=Join-Path $TestRoot 'Tampered separate package'
        Copy-Item -LiteralPath $Moved -Destination $tampered -Recurse
        $candidate=@(Get-ChildItem -LiteralPath (Join-Path $tampered 'vendor') -Filter '__init__.py' -File -Recurse|Where-Object{$_.FullName -match '[\\/]pypdf[\\/]__init__\.py$'})
        Check ($candidate.Count -eq 1) 'A real packaged reader dependency is selected for the isolated tamper test.'
        [IO.File]::AppendAllText($candidate[0].FullName,([Environment]::NewLine+'# Synthetic tamper sentinel'),[Text.Encoding]::ASCII)
        $run=Invoke-Probe $tampered @('--pdf',$script:OptionalPath)
        $integrity=@($run.Summary.checks|Where-Object id -eq 'ManifestIntegrity')
        Check ($run.ExitCode -ne 0 -and $integrity.Count -eq 1 -and $integrity[0].status -eq 'FAIL') 'Modified dependency bytes fail the bundle integrity check.'
        Check ($run.Summary.totals.failed -ge 1) 'The reported compatibility outcome reflects the integrity failure.'
        Check ($run.Summary.optionalPdf.selected -and $run.Summary.optionalPdf.status -eq 'DependencyUnavailable') 'A selected PDF behind a failed dependency receives a separate safe unavailable status.'
        Check-PrivateOutput $run $tampered @('PRIVATE_FILENAME_CANARY_0F24','PRIVATE_TEXT_CANARY_73AD82E5',$script:OptionalPath,$TestRoot)
    }
    Scenario 'The bundled Python and reader also run under an actual non-administrator token' {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        $principal=New-Object Security.Principal.WindowsPrincipal($identity)
        $parentAdmin=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if(-not $parentAdmin){
            $run=Invoke-Probe $Moved
            Check ($run.ExitCode -eq 0 -and $run.Summary.runtime.adminTokenDetected -is [bool] -and $run.Summary.runtime.adminTokenDetected -eq $false) 'A naturally standard current user completes the portable test.'
            $script:NonAdministratorActuallyRun=$true
        }else{
            $script:AccountName='ctqap'+[guid]::NewGuid().ToString('N').Substring(0,12)
            $secret=([guid]::NewGuid().ToString('N')+'aA!3')
            $script:SecurePassword=ConvertTo-SecureString $secret -AsPlainText -Force
            $secret=$null
            $account=New-LocalUser -Name $script:AccountName -Password $script:SecurePassword -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Description 'Ephemeral CT QA portable Python CI validation'
            $script:AccountSid=$account.SID.Value
            $script:StandardAccountCreated=$true
            $users=Get-LocalGroup -SID 'S-1-5-32-545'
            if(-not @(Get-LocalGroupMember -Group $users|Where-Object{$_.SID.Value -eq $script:AccountSid}).Count){Add-LocalGroupMember -Group $users -Member $account}
            $acl=Get-Acl -LiteralPath $TestRoot
            $rule=New-Object Security.AccessControl.FileSystemAccessRule($account.SID,'Modify','ContainerInherit,ObjectInherit','None','Allow')
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $TestRoot -AclObject $acl
            $standard=Join-Path $TestRoot 'Standard user portable probe'
            Copy-Item -LiteralPath $Moved -Destination $standard -Recurse
            foreach($name in @('ProbeResult.json','ProbeResult.html')){
                $old=Join-Path $standard ('Results/'+$name)
                if([IO.File]::Exists($old)){[IO.File]::Delete($old)}
            }
            $wrapper=Join-Path $TestRoot 'Run standard user test.cmd'
            $lines=@(
                '@echo off',
                'setlocal DisableDelayedExpansion',
                'set "PATH=%SystemRoot%\System32"',
                'set "PYTHONHOME=%~dp0Missing Python home"',
                'set "PYTHONPATH=%~dp0Poison imports"',
                'set "TEMP=%~dp0Standard user portable probe\Results\Temporary"',
                'set "TMP=%TEMP%"',
                'cd /d "%~dp0Outside working folder"',
                'call "%~dp0Standard user portable probe\Run Python Test.cmd" --no-open',
                'exit /b %errorlevel%'
            )
            [IO.File]::WriteAllText($wrapper,($lines -join [Environment]::NewLine)+[Environment]::NewLine,[Text.Encoding]::ASCII)
            $credential=New-Object Management.Automation.PSCredential(('.\'+$script:AccountName),$script:SecurePassword)
            $stdout=Join-Path $TestRoot 'Standard-user-stdout.txt'
            $stderr=Join-Path $TestRoot 'Standard-user-stderr.txt'
            $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/cmd.exe') -ArgumentList ('/d /s /c ""'+$wrapper+'""') -Credential $credential -WorkingDirectory $Outside -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
            try{
                [void]$process.Handle
                if(-not $process.WaitForExit(120000)){try{$process.Kill()}catch{};throw 'CHECK: The standard-user exercise exceeded its bounded timeout.'}
                $exit=$process.ExitCode
            }finally{$process.Dispose()}
            Check ($exit -eq 0) 'The separate standard-account process exits successfully.'
            $result=Read-Result $standard
            Check ($result.totals.failed -eq 0 -and $result.runtime.adminTokenDetected -is [bool] -and $result.runtime.adminTokenDetected -eq $false) 'The actual child token is non-administrator and all runtime checks pass.'
            Check ($result.runtime.embeddedExeInBundle -and $result.runtime.pypdfInBundle -and $result.runtime.isolated -and $result.runtime.noSite) 'The standard user loads the bundled runtime and dependencies with isolation.'
            $script:NonAdministratorActuallyRun=$true
        }
    }
    Scenario 'The probe preserves all inputs and the main application files' {
        $after=Snapshot-Bundle $Moved
        Check ($after.Count -eq $script:OriginalBundleFiles.Count) 'No non-result package files were added or removed.'
        foreach($name in $script:OriginalBundleFiles.Keys){Check ($after.ContainsKey($name) -and $after[$name] -eq $script:OriginalBundleFiles[$name]) 'All original package and fixture bytes remain unchanged.'}
        Check ((Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash -eq $packageHash) 'The downloaded test ZIP was not modified.'
        Check ((Get-FileHash -LiteralPath $script:OptionalPath -Algorithm SHA256).Hash -eq $script:OptionalHash) 'The selected optional input remains unchanged after all runs.'
        foreach($name in $mainBefore.Keys){Check ((Get-FileHash -LiteralPath (Join-Path $ProductRoot $name) -Algorithm SHA256).Hash -eq $mainBefore[$name]) 'The existing application and configuration files remain unchanged.'}
    }
}finally{
    if($script:StandardAccountCreated){
        try{
            Remove-LocalUser -Name $script:AccountName
            $profile=Get-CimInstance Win32_UserProfile -Filter ("SID='"+$script:AccountSid+"'") -ErrorAction SilentlyContinue
            if($null -ne $profile -and -not $profile.Loaded){$profile|Remove-CimInstance -ErrorAction Stop}
            $script:StandardAccountCleanupSucceeded=$true
        }catch{
            [void]$script:Results.Add([pscustomobject]@{Name='Ephemeral standard account cleanup';Result='FAIL';Details=$_.Exception.GetType().Name})
        }
    }else{$script:StandardAccountCleanupSucceeded=$true}
    if($null -ne $script:SecurePassword){$script:SecurePassword.Dispose();$script:SecurePassword=$null}
    if(-not $KeepFixtures){try{Remove-Item -LiteralPath $TestRoot -Recurse -Force}catch{
        [void]$script:Results.Add([pscustomobject]@{Name='Synthetic fixture cleanup';Result='FAIL';Details=$_.Exception.GetType().Name})
    }}
}
$failed=@($script:Results|Where-Object Result -eq 'FAIL').Count
$report=[pscustomobject]@{
    Product='CT QA portable Python compatibility test'
    ProbeVersion='1.0.0'
    Runtime=$PSVersionTable.PSVersion.ToString()
    NativeWindowsActuallyRun=$true
    BundledPythonActuallyRun=($null -ne $script:Cold -and $script:Cold.ExitCode -eq 0)
    NonAdministratorActuallyRun=$script:NonAdministratorActuallyRun
    StandardAccountCreatedByTestInfrastructure=$script:StandardAccountCreated
    StandardAccountCleanupSucceeded=$script:StandardAccountCleanupSucceeded
    SystemPythonExcludedFromPath=$true
    PythonEnvironmentPoisoned=$true
    ApplicationNetworkGuardActuallyRun=$script:ApplicationNetworkGuardActuallyRun
    OperatingSystemNetworkBlockedActuallyTested=$false
    WorkstationPolicyActuallyTested=$false
    HospitalNetworkContacted=$false
    SyntheticOnly=$true
    Tests=$script:Results.Count
    Assertions=$script:Assertions
    Failed=$failed
    Results=@($script:Results.ToArray())
    Scope='Fresh generated Windows fixtures and the actual bundled interpreter launched through CMD. PATH excludes installed Python; PYTHONHOME/PYTHONPATH and shadow modules are poisoned. A separate ephemeral standard account is created only by elevated CI infrastructure, with no UAC or execution-policy change, and the child reports its actual unelevated token. Network denial is an application audit hook, not a claim of OS firewall isolation. Optional PDF canaries are checked against persisted output; no real reports, passwords or hospital access are used. Hosted execution does not establish a work computer application policy.'
}
if($null -ne $script:Cold){$report|Add-Member ActualPythonVersion $script:Cold.Summary.runtime.version;$report|Add-Member ActualPypdfVersion $script:Cold.Summary.runtime.pypdfVersion}
if($OutputPath){
    $full=[IO.Path]::GetFullPath($OutputPath)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
    [IO.File]::WriteAllText($full,($report|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding $true))
}
Write-Host ('Result: '+($report.Tests-$failed)+'/'+$report.Tests+' scenarios; '+$report.Assertions+' assertions.')
if($failed){exit 1}
exit 0
