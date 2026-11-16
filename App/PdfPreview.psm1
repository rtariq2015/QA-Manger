# Uses the Windows PDF renderer already supplied with Windows 10/11.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
function Wait-QaWindowsOperation {
    param($Operation,[type]$ResultType)
    $method=@([System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object{$_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'})[0]
    $task=$method.MakeGenericMethod($ResultType).Invoke($null,@($Operation))
    return $task.GetAwaiter().GetResult()
}
function Get-QaPdfPreviewPage {
    [CmdletBinding()]param($Config,[string]$RecordId,[ValidateRange(0,99999)][int]$PageNumber=0,[ValidateRange(320,1800)][int]$Width=1200)
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'The in-app PDF preview requires the Windows PDF renderer. Open the saved PDF in its normal viewer instead.'}
    Import-Module (Join-Path $PSScriptRoot 'Archive.psm1')
    Import-Module (Join-Path $PSScriptRoot 'PdfReader.psm1')
    # Resolve from freshly validated archive state. A page preview does not need
    # to rebuild monthly coverage, scanner summaries or historical attention.
    $records=@(Get-QaArchiveRecords -Config $Config|Where-Object Id -ceq $RecordId)
    if($records.Count -ne 1){throw 'Select one saved report for preview.'};$record=$records[0]
    $path=[IO.Path]::GetFullPath([string]$record.DestinationPath)
    & (Get-Module PdfReader) {param($p) Assert-QaReaderDirectPath $p} $path
    $reports=[IO.Path]::GetFullPath((Join-Path $Config.ArchiveRoot 'Reports')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $path.StartsWith($reports,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne [string]$record.Hash){throw 'The saved PDF is missing or has changed. Run the integrity check before previewing it.'}
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null=[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
    $null=[Windows.Data.Pdf.PdfDocument,Windows.Data.Pdf,ContentType=WindowsRuntime]
    $null=[Windows.Storage.Streams.InMemoryRandomAccessStream,Windows.Storage.Streams,ContentType=WindowsRuntime]
    $null=[Windows.Storage.Streams.DataReader,Windows.Storage.Streams,ContentType=WindowsRuntime]
    $null=[Windows.Data.Pdf.PdfPageRenderOptions,Windows.Data.Pdf,ContentType=WindowsRuntime]
    $file=Wait-QaWindowsOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $document=Wait-QaWindowsOperation ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])
    if($PageNumber -ge $document.PageCount){throw 'That PDF page does not exist.'}
    $page=$null;$stream=$null;$reader=$null
    try{
        $page=$document.GetPage([uint32]$PageNumber)
        if($page.Size.Width -le 0 -or $page.Size.Height -le 0){throw 'The PDF page has no usable dimensions.'}
        $scale=[math]::Min($Width/$page.Size.Width,2200/$page.Size.Height)
        $options=New-Object Windows.Data.Pdf.PdfPageRenderOptions
        $options.DestinationWidth=[uint32][math]::Max(1,[math]::Round($page.Size.Width*$scale))
        $options.DestinationHeight=[uint32][math]::Max(1,[math]::Round($page.Size.Height*$scale))
        $stream=New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
        $render=$page.RenderToStreamAsync($stream,$options)
        $asAction=@([System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object{$_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'})[0]
        $renderTask=$asAction.Invoke($null,@($render));[void]$renderTask.GetAwaiter().GetResult()
        if($stream.Size -gt 16777216){throw 'This preview is too large. Open the saved PDF in its normal viewer.'}
        $reader=New-Object Windows.Storage.Streams.DataReader($stream.GetInputStreamAt(0))
        $loaded=Wait-QaWindowsOperation ($reader.LoadAsync([uint32]$stream.Size)) ([uint32])
        $bytes=New-Object byte[] ([int]$loaded);$reader.ReadBytes($bytes)
        return [pscustomobject]@{RecordId=$RecordId;Hash=[string]$record.Hash;PageNumber=$PageNumber;PageCount=[int]$document.PageCount;Width=[int]$options.DestinationWidth;Height=[int]$options.DestinationHeight;PngBase64=[Convert]::ToBase64String($bytes)}
    }finally{foreach($resource in @($reader,$stream,$page)){if($null -ne $resource -and $resource -is [IDisposable]){$resource.Dispose()}}}
}
Export-ModuleMember -Function Get-QaPdfPreviewPage
