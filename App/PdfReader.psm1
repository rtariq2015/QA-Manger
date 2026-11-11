# CT QA Manager Pro - optional, local-only PDF text reading.
# PdfPig 0.1.16 is distributed beside this module with its licenses.
# Reading text NEVER confirms or changes a QA classification.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Assert-QaReaderDirectPath {
    param([string]$Path)
    $current=[IO.Path]::GetFullPath($Path)
    while($current) {
        if([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            if(([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A linked file or folder cannot be used to read an archived report.'}
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if($parent -eq $current){break};$current=$parent
    }
}
function Assert-QaReaderStableMetadata {
    param([string]$Path,[long]$Length,[long]$WriteTicks)
    Assert-QaReaderDirectPath $Path
    $info=New-Object IO.FileInfo($Path);$info.Refresh()
    if(-not $info.Exists -or $info.Length -ne $Length -or $info.LastWriteTimeUtc.Ticks -ne $WriteTicks){throw 'The saved PDF changed while it was being read. Read the current report again before using its extracted text.'}
}
function Initialize-QaPdfReader {
    if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $release=0
        try{$release=[int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release}catch{}
        if($release -lt 461808){throw 'Reading PDF text needs the .NET Framework 4.7.2 or newer supplied on current Windows workstations. Ask IT to check it. The other archive features remain available.'}
    }
    $lib=Join-Path (Join-Path $PSScriptRoot 'Lib') 'PdfPig'
    $manifestPath=Join-Path $lib 'Integrity.json'
    Assert-QaReaderDirectPath $manifestPath
    if(-not [IO.File]::Exists($manifestPath)){throw 'PDF reader components are missing. Extract the complete application folder again.'}
    $manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json
    $expected=@{}
    foreach($item in @($manifest.Files)) {
        if([string]$item.Name -notmatch '^[A-Za-z0-9.]+\.dll$' -or [string]$item.SHA256 -notmatch '^[0-9A-Fa-f]{64}$'){throw 'The PDF reader component list is invalid.'}
        $expected[[string]$item.Name]=[string]$item.SHA256
    }
    $order=@('System.Runtime.CompilerServices.Unsafe','System.Buffers','System.Numerics.Vectors','System.Memory','Microsoft.Bcl.HashCode','UglyToad.PdfPig.Core','UglyToad.PdfPig.Tokens','UglyToad.PdfPig.Tokenization','UglyToad.PdfPig.Fonts','UglyToad.PdfPig','UglyToad.PdfPig.DocumentLayoutAnalysis','UglyToad.PdfPig.Package')
    foreach($name in $order) {
        $filename=$name+'.dll';$path=Join-Path $lib $filename
        Assert-QaReaderDirectPath $path
        if(-not $expected.ContainsKey($filename) -or -not [IO.File]::Exists($path)){throw 'A PDF reader component is missing. Extract the complete application folder again.'}
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expected[$filename]){throw 'A PDF reader component differs from its packaged checksum. Ask IT to check the application files.'}
        $wanted=[Reflection.AssemblyName]::GetAssemblyName($path)
        $loaded=@([AppDomain]::CurrentDomain.GetAssemblies()|Where-Object{$_.GetName().Name -eq $wanted.Name -and $_.GetName().Version -ge $wanted.Version})
        if($loaded.Count -eq 0) {
            try{[void][Reflection.Assembly]::LoadFrom($path)}catch{throw 'Windows could not load the portable PDF reader. Ask IT to check its approval and the .NET Framework. No report was changed.'}
        }
    }
}
function Test-QaReaderCancel {
    param($Progress)
    return ($null -ne $Progress -and $Progress.ContainsKey('Cancel') -and [bool]$Progress.Cancel)
}
function Set-QaReaderProgress {
    param($Progress,[string]$Message,[double]$Percent)
    if($null -ne $Progress){$Progress.Message=$Message;$Progress.Percent=$Percent}
}
function Get-QaTextIndicators {
    param([string]$Text)
    $patterns=@(
        @('Modulation transfer function (MTF)','(?i)\bMTF\b|modulation\s+transfer'),
        @('Slice thickness','(?i)slice\s*thickness'),
        @('Low-contrast testing','(?i)low[\s-]*contrast'),
        @('Light marker / positioning','(?i)light[\s-]*marker'),
        @('Spatial resolution','(?i)spatial\s+resolution'),
        @('Uniformity','(?i)\buniformity\b'),
        @('Water homogeneity / HU','(?i)homogeneity|water\s+CT\s+value|\bHU\b'),
        @('Table positioning','(?i)table[\s_-]*(position|travel)'),
        @('Topogram positioning','(?i)topogram[\s_-]*(position|pos)'),
        @('CTDI / air dose-test wording','(?i)\bCTDI\b|CTDI[\s_-]*Air'),
        @('Constancy test wording','(?i)\bconstancy\b|Quality[_\s]*Constancy'),
        @('Reference / baseline wording','(?i)\breference\b|\bbaseline\b|\bNORMAL\b'),
        @('CT number / Hounsfield units','(?i)CT\s*number|Hounsfield'),
        @('Image noise','(?i)\bnoise\b'),
        @('Daily QA wording','(?i)\bdaily\b'),
        @('Monthly QA wording','(?i)\bmonthly\b')
    )
    $found=New-Object 'System.Collections.Generic.List[string]'
    foreach($pattern in $patterns){if($Text -match $pattern[1]){[void]$found.Add([string]$pattern[0])}}
    return @($found.ToArray())
}
function Initialize-QaPythonJobType {
    if('CtQaPortablePythonJob' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public sealed class CtQaPortablePythonJob : IDisposable {
    private IntPtr handle;
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimit {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimit {
        public BasicLimit BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimit information, uint length);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr value);
    private CtQaPortablePythonJob(IntPtr value){ handle=value; }
    public static CtQaPortablePythonJob Attach(IntPtr process) {
        IntPtr value=CreateJobObjectW(IntPtr.Zero,null);
        if(value==IntPtr.Zero) throw new InvalidOperationException("PythonContainmentUnavailable");
        try {
            ExtendedLimit limits=new ExtendedLimit();
            limits.BasicLimitInformation.LimitFlags=0x00002000;
            if(!SetInformationJobObject(value,9,ref limits,(uint)Marshal.SizeOf(typeof(ExtendedLimit))) || !AssignProcessToJobObject(value,process)) throw new InvalidOperationException("PythonContainmentUnavailable");
            return new CtQaPortablePythonJob(value);
        } catch { CloseHandle(value); throw; }
    }
    public void Dispose(){ IntPtr value=handle;handle=IntPtr.Zero;if(value!=IntPtr.Zero) CloseHandle(value); }
}
'@ -ErrorAction Stop
}
function Test-QaPythonReaderAvailable {
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){return $false}
    $bundle=Join-Path $PSScriptRoot 'Python'
    return ([IO.File]::Exists((Join-Path $bundle 'runtime/python.exe')) -and [IO.File]::Exists((Join-Path $bundle 'read_pdf.py')) -and [IO.File]::Exists((Join-Path $bundle 'Integrity.json')))
}
function Assert-QaPythonReaderBundle {
    $bundle=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Python'))
    $manifestPath=Join-Path $bundle 'Integrity.json'
    Assert-QaReaderDirectPath $manifestPath
    if(-not [IO.File]::Exists($manifestPath)){throw 'The portable Python reader is incomplete. Extract the full program package again.'}
    try{$manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json}catch{throw 'The portable Python reader component list is invalid.'}
    if([int]$manifest.SchemaVersion -ne 1 -or [string]$manifest.PythonVersion -cne '3.14.10' -or [string]$manifest.PypdfVersion -cne '7.0.1'){throw 'The portable Python reader component list is invalid.'}
    $expected=@{}
    foreach($entry in @($manifest.Files)) {
        $name=[string]$entry.Name;$hash=[string]$entry.SHA256
        if($name -notmatch '^(?:runtime|vendor)/[A-Za-z0-9_.+() /-]+$|^(?:read_pdf\.py|Sources\.json)$' -or $name.Contains('..') -or $name.EndsWith('/') -or $hash -notmatch '^[0-9A-Fa-f]{64}$' -or $expected.ContainsKey($name)){throw 'The portable Python reader component list is invalid.'}
        $path=Join-Path $bundle $name
        Assert-QaReaderDirectPath $path
        if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $hash){throw 'A portable Python reader component differs from its packaged checksum. Extract the full program package again.'}
        $expected[$name]=$true
    }
    foreach($required in @('read_pdf.py','Sources.json','runtime/python.exe','runtime/python314.zip','runtime/python314._pth','vendor/pypdf/__init__.py')){if(-not $expected.ContainsKey($required)){throw 'The portable Python reader is incomplete. Extract the full program package again.'}}
    $actual=0
    $directories=New-Object 'Collections.Generic.Stack[string]'
    $directories.Push($bundle)
    while($directories.Count) {
        foreach($item in @(Get-ChildItem -LiteralPath ($directories.Pop()) -Force)) {
            # Check directory links before walking them, including unexpected
            # components which were not named in the verified manifest.
            Assert-QaReaderDirectPath $item.FullName
            if($item.PSIsContainer){$directories.Push($item.FullName);continue}
            $relative=$item.FullName.Substring($bundle.TrimEnd('\','/').Length+1).Replace('\','/')
            if($relative -ceq 'Integrity.json'){continue}
            if(-not $expected.ContainsKey($relative)){throw 'The portable Python reader contains an unexpected component. Extract the full program package again.'}
            $actual++
        }
    }
    if($actual -ne $expected.Count){throw 'The portable Python reader is incomplete. Extract the full program package again.'}
    return $bundle
}
function Invoke-QaPythonPdfText {
    param([byte[]]$Bytes,[string]$ExpectedHash,$Progress,[int]$MaximumPages,[int]$MaximumCharacters,[int]$MaximumSeconds)
    $process=$null;$job=$null;$sendTask=$null;$stdoutTask=$null;$stderrTask=$null
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        if(Test-QaReaderCancel $Progress){throw [OperationCanceledException]::new('Reading cancelled.')}
        if(-not (Test-QaPythonReaderAvailable)){throw 'The portable Python reader is unavailable on this computer. Choose Automatic or Standard reading.'}
        $bundle=Assert-QaPythonReaderBundle
        Initialize-QaPythonJobType
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=Join-Path $bundle 'runtime/python.exe'
        $info.Arguments='-I -B -S "'+(Join-Path $bundle 'read_pdf.py')+'"'
        $info.WorkingDirectory=$bundle
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
        $info.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
        $process=New-Object Diagnostics.Process
        $process.StartInfo=$info
        if(-not $process.Start()){throw 'The portable Python reader could not start. Choose Automatic or Standard reading.'}
        # The owning PowerShell process holds the only job handle. Forced task
        # cancellation therefore terminates the Python child as well.
        $job=[CtQaPortablePythonJob]::Attach($process.Handle)
        $stdoutTask=$process.StandardOutput.ReadToEndAsync()
        $stderrTask=$process.StandardError.ReadToEndAsync()
        $header=[Text.Encoding]::UTF8.GetBytes((@{schemaVersion=1;length=$Bytes.Length;maximumPages=$MaximumPages;maximumCharacters=$MaximumCharacters;maximumSeconds=$MaximumSeconds}|ConvertTo-Json -Compress))
        $prefix=[BitConverter]::GetBytes([int]$header.Length)
        $process.StandardInput.BaseStream.Write($prefix,0,$prefix.Length)
        $process.StandardInput.BaseStream.Write($header,0,$header.Length)
        $sendTask=$process.StandardInput.BaseStream.WriteAsync($Bytes,0,$Bytes.Length)
        $inputClosed=$false
        while(-not $process.WaitForExit(50)) {
            if(Test-QaReaderCancel $Progress){throw [OperationCanceledException]::new('Reading cancelled.')}
            if($timer.Elapsed.TotalSeconds -gt ($MaximumSeconds+5)){throw 'The portable Python reader exceeded its time limit. Try Automatic or Standard reading.'}
            if(-not $inputClosed -and $sendTask.IsCompleted){[void]$sendTask.GetAwaiter().GetResult();$process.StandardInput.Close();$inputClosed=$true}
            Set-QaReaderProgress $Progress 'Reading this PDF with the portable reader...' 45
        }
        if(Test-QaReaderCancel $Progress){throw [OperationCanceledException]::new('Reading cancelled.')}
        if(-not $inputClosed){[void]$sendTask.GetAwaiter().GetResult();$process.StandardInput.Close()}
        # Library diagnostics and exception text are never propagated. Only the
        # versioned successful response schema is accepted as report evidence.
        $raw=$stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($raw) -or $raw.Length -gt (12*$MaximumCharacters+65536)){throw 'The portable Python reader could not read this PDF. It may be encrypted, damaged or unsupported.'}
        try{$result=$raw|ConvertFrom-Json}catch{throw 'The portable Python reader returned an invalid response. Try Automatic or Standard reading.'}
        if([int]$result.schemaVersion -ne 1 -or $result.success -isnot [bool] -or -not $result.success){throw 'The portable Python reader could not read this PDF. It may be encrypted, damaged or unsupported.'}
        if([string]$result.hash -cne $ExpectedHash -or [long]$result.length -ne $Bytes.Length){throw 'The portable Python reader returned a different PDF fingerprint. No extracted result was accepted.'}
        if($result.text -isnot [string] -or $result.text.Length -gt $MaximumCharacters -or $result.truncated -isnot [bool] -or $result.needsOCR -isnot [bool] -or [int]$result.pages -lt 1 -or [int]$result.pages -gt 100000 -or [int]$result.readPages -lt 0 -or [int]$result.readPages -gt [math]::Min([int]$result.pages,$MaximumPages) -or [string]$result.engine -cne 'Python' -or [string]$result.readerVersion -cne 'Python 3.14.10 / pypdf 7.0.1'){throw 'The portable Python reader returned an invalid response. No extracted result was accepted.'}
        return [pscustomobject]@{Text=[string]$result.text;Pages=[int]$result.pages;ReadPages=[int]$result.readPages;Truncated=[bool]$result.truncated;NeedsOCR=[bool]$result.needsOCR;ReaderUsed='Python';ReaderVersion=[string]$result.readerVersion}
    } catch [OperationCanceledException] {throw}
    catch {throw 'The portable Python reader could not read this PDF or was blocked. Choose Automatic or Standard reading. Encrypted or damaged files may be unsupported.'}
    finally {
        if($null -ne $process){try{if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(3000)}}catch{}}
        if($null -ne $job){try{$job.Dispose()}catch{}}
        if($null -ne $process){$process.Dispose()}
    }
}
function Invoke-QaStandardPdfText {
    param([byte[]]$Bytes,$Progress,[int]$MaximumPages,[int]$MaximumCharacters,[int]$MaximumSeconds)
    $document=$null
    try {
        Initialize-QaPdfReader
        if(Test-QaReaderCancel $Progress){throw [OperationCanceledException]::new('Reading cancelled.')}
        $timer=[Diagnostics.Stopwatch]::StartNew()
        try{$document=[UglyToad.PdfPig.PdfDocument]::Open([byte[]]$Bytes,$null)}catch{throw 'Text could not be read from this PDF. It may be encrypted, damaged, or use an unsupported feature. Open it in your approved PDF viewer.'}
        $pages=[int]$document.NumberOfPages;$readPages=0;$truncated=($pages -gt $MaximumPages)
        $builder=New-Object Text.StringBuilder
        for($pageNumber=1;$pageNumber -le [math]::Min($pages,$MaximumPages);$pageNumber++) {
            if(Test-QaReaderCancel $Progress){throw [OperationCanceledException]::new('Reading cancelled.')}
            if($timer.Elapsed.TotalSeconds -gt $MaximumSeconds){$truncated=$true;break}
            Set-QaReaderProgress $Progress ('Reading page '+$pageNumber+' of '+$pages+'...') (10+90*$pageNumber/[math]::Max(1,$pages))
            try{$page=$document.GetPage($pageNumber);$text=[UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor.ContentOrderTextExtractor]::GetText($page,$true)}catch{throw ('Page '+$pageNumber+' could not be read. Open the original PDF in your approved viewer.')}
            $remaining=$MaximumCharacters-$builder.Length
            if($remaining -le 50){$truncated=$true;break}
            $heading="--- Page $pageNumber ---`r`n"
            [void]$builder.Append($heading)
            $remaining=$MaximumCharacters-$builder.Length
            if($text.Length -gt $remaining){[void]$builder.Append($text.Substring(0,$remaining));$truncated=$true;$readPages++;break}
            [void]$builder.Append($text);[void]$builder.Append("`r`n`r`n");$readPages++
        }
        $fullText=$builder.ToString()
        if($fullText.Length -gt $MaximumCharacters){$fullText=$fullText.Substring(0,$MaximumCharacters);$truncated=$true}
        $visibleText=([regex]::Replace($fullText,'--- Page \d+ ---','')).Trim()
        return [pscustomobject]@{Text=$fullText;Pages=$pages;ReadPages=$readPages;Truncated=$truncated;NeedsOCR=[string]::IsNullOrWhiteSpace($visibleText);ReaderUsed='Standard';ReaderVersion='PdfPig 0.1.16'}
    } finally {if($null -ne $document){try{$document.Dispose()}catch{}}}
}

function Read-QaReportText {
    [CmdletBinding()]param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$RecordId,
        $Progress=$null,
        [ValidateRange(1,1000)][int]$MaximumPages=250,
        [ValidateRange(500,2000000)][int]$MaximumCharacters=1000000,
        [ValidateRange(1024,104857600)][long]$MaximumBytes=52428800,
        [ValidateRange(5,120)][int]$MaximumSeconds=45,
        [ValidateSet('Auto','Python','Standard')][string]$Reader='Auto'
    )
    if(-not $PSBoundParameters.ContainsKey('Reader')) {
        $configured=''
        if($Config -is [Collections.IDictionary]){if($Config.Contains('PDFReaderMode')){$configured=[string]$Config.PDFReaderMode}}
        elseif($null -ne $Config.PSObject.Properties['PDFReaderMode']){$configured=[string]$Config.PDFReaderMode}
        if($configured){if($configured -cnotin @('Auto','Python','Standard')){throw 'Choose Automatic, Python or Standard PDF reading.'};$Reader=$configured}
    }
    if($Reader -ieq 'Auto'){$Reader='Auto'}elseif($Reader -ieq 'Python'){$Reader='Python'}else{$Reader='Standard'}
    if($RecordId -notmatch '^[0-9A-Fa-f]{64}$'){throw 'Select one saved report from the report list first.'}
    $archiveModule=Get-Module Archive
    if($null -eq $archiveModule){Import-Module (Join-Path $PSScriptRoot 'Archive.psm1') -ErrorAction Stop;$archiveModule=Get-Module Archive}
    $root=[IO.Path]::GetFullPath([string]$Config.ArchiveRoot)
    $meta=Join-Path $root '.ctqa';$reports=Join-Path $root 'Reports'
    $lockPath=Join-Path $meta 'archive.lock'
    foreach($p in @($root,$meta,$reports,$lockPath,(Join-Path $meta 'state.json'))){Assert-QaReaderDirectPath $p}
    $lock=$null;$inputStream=$null;$document=$null;$bytes=$null
    $summary=[pscustomobject]@{Description='';Cancelled=$false}
    try {
        if(Test-QaReaderCancel $Progress){throw [OperationCanceledException]::new('Reading cancelled.')}
        try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'Wait for the current archive update or report export to finish, then read the report again.'}
        # Keep the complete archive/config/path validation under the reader lock,
        # without rebuilding every scanner's coverage and attention list per PDF.
        $matches=@(& $archiveModule {
            param($ReaderConfig,$SelectedId)
            Assert-QaConfig $ReaderConfig
            $state=Read-QaState (Get-QaPaths $ReaderConfig)
            $selected=@($state.Records|Where-Object{$_.Id -eq $SelectedId})
            if($selected.Count -eq 1){
                $source=@($ReaderConfig.Sources|Where-Object{$_.Scanner -ceq $selected[0].Scanner})[0]
                Set-QaValue $selected[0] 'ScannerName' ([string]$source.Name)
            }
            return $selected
        } $Config $RecordId)
        if($matches.Count -ne 1){throw 'The selected report is no longer uniquely available. Refresh the report list.'}
        $record=$matches[0];$path=[IO.Path]::GetFullPath([string]$record.DestinationPath)
        $prefix=[IO.Path]::GetFullPath($reports).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Only saved PDFs inside the managed archive can be read.'}
        Assert-QaReaderDirectPath $path
        if(-not [IO.File]::Exists($path)){throw 'The saved PDF is missing. Run Update Reports or the integrity audit.'}
        if([string]$record.Hash -notmatch '^[0-9A-Fa-f]{64}$'){throw 'The saved report has no verified hash. Run the integrity audit.'}
        Set-QaReaderProgress $Progress 'Checking this saved PDF before reading it...' 5
        $verifiedInfo=New-Object IO.FileInfo($path);$verifiedInfo.Refresh()
        $verifiedLength=[long]$verifiedInfo.Length;$verifiedWriteTicks=[long]$verifiedInfo.LastWriteTimeUtc.Ticks
        $inputStream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($inputStream.Length -ne $verifiedLength){throw 'The saved PDF changed before reading started. Read the current report again.'}
        if($inputStream.Length -gt $MaximumBytes){throw 'This PDF exceeds the safe text-reading size limit. Open the original PDF in your approved viewer.'}
        if($inputStream.Length -ne [long]$record.Length){throw 'The saved PDF size has changed. Run the integrity audit before reading it.'}
        # Hash the exact bounded buffer that will be parsed; never reopen the file after hashing.
        $bytes=New-Object byte[] ([int]$inputStream.Length)
        $offset=0
        while($offset -lt $bytes.Length) {
            if(Test-QaReaderCancel $Progress){throw [OperationCanceledException]::new('Reading cancelled.')}
            $read=$inputStream.Read($bytes,$offset,[int][math]::Min(1048576,$bytes.Length-$offset))
            if($read -le 0){throw 'The saved PDF ended before all bytes could be read.'};$offset+=$read
        }
        $inputStream.Dispose();$inputStream=$null
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
        if($hash -ne $record.Hash){throw 'The saved PDF differs from its verified SHA-256. Run the integrity audit before reading it.'}
        Assert-QaReaderStableMetadata $path $verifiedLength $verifiedWriteTicks
        $engineTimer=[Diagnostics.Stopwatch]::StartNew()
        $extracted=$null;$fallbackReason='';$pythonFailure=''
        if($Reader -in @('Auto','Python')) {
            if(Test-QaPythonReaderAvailable) {
                try{$extracted=Invoke-QaPythonPdfText -Bytes $bytes -ExpectedHash $hash -Progress $Progress -MaximumPages $MaximumPages -MaximumCharacters $MaximumCharacters -MaximumSeconds $MaximumSeconds}
                catch [OperationCanceledException] {throw}
                catch{if($Reader -ceq 'Python'){throw};$fallbackReason='PythonReadError';$pythonFailure='The portable reader could not finish within the reading limit. Try Standard reading for this PDF.'}
            }else{
                if($Reader -ceq 'Python'){throw 'The portable Python reader is unavailable on this computer. Choose Automatic or Standard reading.'}
                $fallbackReason='PythonUnavailable'
            }
        }
        if($null -ne $extracted -and $Reader -ceq 'Auto' -and $extracted.NeedsOCR -and -not $extracted.Truncated) {
            $remaining=[int][math]::Floor($MaximumSeconds-$engineTimer.Elapsed.TotalSeconds)
            if($remaining -ge 5){
                try{
                    $alternate=Invoke-QaStandardPdfText -Bytes $bytes -Progress $Progress -MaximumPages $MaximumPages -MaximumCharacters $MaximumCharacters -MaximumSeconds $remaining
                    if(-not $alternate.NeedsOCR){$extracted=$alternate;$fallbackReason='PythonNoText'}
                }catch [OperationCanceledException]{throw}catch{}
            }
        }
        if($null -eq $extracted) {
            $remaining=[int][math]::Floor($MaximumSeconds-$engineTimer.Elapsed.TotalSeconds)
            if($remaining -lt 5 -and $pythonFailure){throw $pythonFailure}
            $budget=[math]::Max(5,[math]::Min($MaximumSeconds,$remaining))
            $extracted=Invoke-QaStandardPdfText -Bytes $bytes -Progress $Progress -MaximumPages $MaximumPages -MaximumCharacters $MaximumCharacters -MaximumSeconds $budget
        }
        $pages=[int]$extracted.Pages;$readPages=[int]$extracted.ReadPages;$truncated=[bool]$extracted.Truncated
        $fullText=[string]$extracted.Text
        $visibleText=([regex]::Replace($fullText,'--- Page \d+ ---','')).Trim()
        $needsOcr=[string]::IsNullOrWhiteSpace($visibleText)
        $message='Text is read locally. Found test names are hints only; no QA label or result has been changed.'
        if($needsOcr){$message='No readable text was found. The PDF may be scanned or blank. Open the original PDF; OCR is not included.'}
        if($truncated){$message+=' A size, page, or time limit was reached; the text shown is incomplete. Open the original PDF for the complete document.'}
        $title=[string]$record.OriginalFileName
        if(Get-Command Get-QaReportTitle -ErrorAction SilentlyContinue){$title=Get-QaReportTitle -Record $record}
        $summary.Description=('Read '+$readPages+' of '+$pages+' pages. '+$message)
        Assert-QaReaderStableMetadata $path $verifiedLength $verifiedWriteTicks
        Set-QaReaderProgress $Progress $summary.Description 100
        return [pscustomobject]@{Mode='PdfRead';RecordId=$RecordId;VerifiedHash=$hash;VerifiedLength=$verifiedLength;VerifiedWriteTicks=$verifiedWriteTicks;ReaderUsed=[string]$extracted.ReaderUsed;ReaderVersion=[string]$extracted.ReaderVersion;ReadMilliseconds=[math]::Round($engineTimer.Elapsed.TotalMilliseconds,3);FallbackReason=$fallbackReason;Title=$title;Text=$fullText;Pages=$pages;ReadPages=$readPages;Indicators=@(Get-QaTextIndicators $visibleText);Message=$message;Truncated=$truncated;NeedsOCR=$needsOcr;Summary=$summary}
    } catch [OperationCanceledException] {
        $summary.Cancelled=$true;$summary.Description='Reading cancelled. No reports were changed.'
        return [pscustomobject]@{Mode='PdfRead';RecordId=$RecordId;VerifiedHash='';VerifiedLength=[long]0;VerifiedWriteTicks=[long]0;ReaderUsed='';ReaderVersion='';ReadMilliseconds=0;FallbackReason='';Title='';Text='';Pages=0;ReadPages=0;Indicators=@();Message=$summary.Description;Truncated=$false;NeedsOCR=$false;Summary=$summary}
    } finally {
        if($null -ne $document){try{$document.Dispose()}catch{}}
        if($null -ne $inputStream){try{$inputStream.Dispose()}catch{}}
        if($null -ne $lock){try{$lock.Dispose()}catch{}}
        $bytes=$null
    }
}
Export-ModuleMember -Function Read-QaReportText
