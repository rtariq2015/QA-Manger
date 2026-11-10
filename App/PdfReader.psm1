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
function Read-QaReportText {
    [CmdletBinding()]param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$RecordId,
        $Progress=$null,
        [ValidateRange(1,1000)][int]$MaximumPages=250,
        [ValidateRange(500,2000000)][int]$MaximumCharacters=1000000,
        [ValidateRange(1024,104857600)][long]$MaximumBytes=52428800,
        [ValidateRange(5,120)][int]$MaximumSeconds=45
    )
    if($RecordId -notmatch '^[0-9A-Fa-f]{64}$'){throw 'Select one saved report from the report list first.'}
    if(-not(Get-Command Get-QaDashboard -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'Archive.psm1') -ErrorAction Stop}
    $root=[IO.Path]::GetFullPath([string]$Config.ArchiveRoot)
    $meta=Join-Path $root '.ctqa';$reports=Join-Path $root 'Reports'
    $lockPath=Join-Path $meta 'archive.lock'
    foreach($p in @($root,$meta,$reports,$lockPath,(Join-Path $meta 'state.json'))){Assert-QaReaderDirectPath $p}
    $lock=$null;$inputStream=$null;$document=$null;$bytes=$null
    $summary=[pscustomobject]@{Description='';Cancelled=$false}
    try {
        if(Test-QaReaderCancel $Progress){throw [OperationCanceledException]::new('Reading cancelled.')}
        try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'Wait for the current archive update or report export to finish, then read the report again.'}
        $dashboard=Get-QaDashboard -Config $Config
        $matches=@($dashboard.Records|Where-Object{$_.Id -eq $RecordId})
        if($matches.Count -ne 1){throw 'The selected report is no longer uniquely available. Refresh the report list.'}
        $record=$matches[0];$path=[IO.Path]::GetFullPath([string]$record.DestinationPath)
        $prefix=[IO.Path]::GetFullPath($reports).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Only saved PDFs inside the managed archive can be read.'}
        Assert-QaReaderDirectPath $path
        if(-not [IO.File]::Exists($path)){throw 'The saved PDF is missing. Run Update Reports or the integrity audit.'}
        if([string]$record.Hash -notmatch '^[0-9A-Fa-f]{64}$'){throw 'The saved report has no verified hash. Run the integrity audit.'}
        Set-QaReaderProgress $Progress 'Checking this saved PDF before reading it...' 5
        $inputStream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
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
        Initialize-QaPdfReader
        if(Test-QaReaderCancel $Progress){throw [OperationCanceledException]::new('Reading cancelled.')}
        $timer=[Diagnostics.Stopwatch]::StartNew()
        try{$document=[UglyToad.PdfPig.PdfDocument]::Open([byte[]]$bytes,$null)}catch{throw 'Text could not be read from this PDF. It may be encrypted, damaged, or use an unsupported feature. Open it in your approved PDF viewer.'}
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
        $needsOcr=[string]::IsNullOrWhiteSpace($visibleText)
        $message='Text is read locally. Found test names are hints only; no QA label or result has been changed.'
        if($needsOcr){$message='No readable text was found. The PDF may be scanned or blank. Open the original PDF; OCR is not included.'}
        if($truncated){$message+=' A size, page, or time limit was reached; the text shown is incomplete. Open the original PDF for the complete document.'}
        $title=[string]$record.OriginalFileName
        if(Get-Command Get-QaReportTitle -ErrorAction SilentlyContinue){$title=Get-QaReportTitle -Record $record}
        $summary.Description=('Read '+$readPages+' of '+$pages+' pages. '+$message)
        Set-QaReaderProgress $Progress $summary.Description 100
        return [pscustomobject]@{Mode='PdfRead';RecordId=$RecordId;Title=$title;Text=$fullText;Pages=$pages;ReadPages=$readPages;Indicators=@(Get-QaTextIndicators $visibleText);Message=$message;Truncated=$truncated;NeedsOCR=$needsOcr;Summary=$summary}
    } catch [OperationCanceledException] {
        $summary.Cancelled=$true;$summary.Description='Reading cancelled. No reports were changed.'
        return [pscustomobject]@{Mode='PdfRead';RecordId=$RecordId;Title='';Text='';Pages=0;ReadPages=0;Indicators=@();Message=$summary.Description;Truncated=$false;NeedsOCR=$false;Summary=$summary}
    } finally {
        if($null -ne $document){try{$document.Dispose()}catch{}}
        if($null -ne $inputStream){try{$inputStream.Dispose()}catch{}}
        if($null -ne $lock){try{$lock.Dispose()}catch{}}
        $bytes=$null
    }
}
Export-ModuleMember -Function Read-QaReportText
