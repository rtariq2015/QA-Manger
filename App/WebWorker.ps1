# JSON adapter called by the local application host. No arbitrary command execution.
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$AppRoot,[Parameter(Mandatory=$true)][string]$InputPath,[Parameter(Mandatory=$true)][string]$OutputPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue';$ProgressPreference='SilentlyContinue';$InformationPreference='SilentlyContinue'
$operation='';$clock=[Diagnostics.Stopwatch]::StartNew()
try{
    $text=if($InputPath -eq '-'){
        # Read the redirected pipe directly. Resetting Console.InputEncoding on
        # Windows PowerShell 5.1 can invalidate its cached text input reader.
        $inputStream=[Console]::OpenStandardInput();$reader=New-Object IO.StreamReader($inputStream,(New-Object Text.UTF8Encoding($false,$true)),$true,4096)
        try{$reader.ReadToEnd()}finally{$reader.Dispose()}
    }else{[IO.File]::ReadAllText($InputPath)}
    if($text.Length -gt 2097152){throw 'The application request is too large.'};try{$request=$text|ConvertFrom-Json}catch{throw 'The application request could not be read. Try the action again.'}
    Import-Module (Join-Path $PSScriptRoot 'WebService.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot 'Support.psm1') -Global -DisableNameChecking -WarningAction SilentlyContinue
    $maps=@{Refresh='Update';Approve='Reclassify';Disapprove='Reclassify';Undo='Reclassify';Reconnect='Reconnect';Settings='Settings';ApplyProfile='Settings';ScannerSettings='Settings';Export='Export';Analyze='Analysis';Backup='Backup';Restore='Restore';Diagnostics='Diagnostics';Audit='Audit';Browse='BrowseRefresh';PrepareUpdate='OfflineUpdate';InstallPreparedUpdate='OfflineUpdate'}
    if($null -ne $request.PSObject.Properties['action'] -and $maps.ContainsKey([string]$request.action)){$operation=$maps[[string]$request.action];Write-QaSupportEvent -AppRoot $AppRoot -Operation $operation -Outcome Started}
    $value=Invoke-QaWebRequest -AppRoot $AppRoot -Request $request
    $response=[pscustomobject]@{success=$true;value=$value}
    if($operation){Write-QaSupportEvent -AppRoot $AppRoot -Operation $operation -Outcome Completed -DurationMs $clock.ElapsedMilliseconds}
}catch{
    $message=$_.Exception.Message;$kind='Operation';$code=0
    if($operation){try{Write-QaSupportEvent -AppRoot $AppRoot -Operation $operation -Outcome Failed -DurationMs $clock.ElapsedMilliseconds -ErrorKind (Get-QaSupportErrorKind $message)}catch{}}
    if($message -match 'Windows error (\d+)'){$code=[int]$Matches[1]}
    if($message -match 'changed|stale|already organized|no longer'){$kind='Conflict'}elseif($message -match 'unsupported|Choose|Select|Enter|requires|Invalid'){$kind='Input'}elseif($message -match 'already running|already open'){$kind='Busy'}
    $response=[pscustomobject]@{success=$false;error=[pscustomobject]@{message=$message;kind=$kind;code=$code}}
}
if($OutputPath -eq '-'){
    $bytes=(New-Object Text.UTF8Encoding $false).GetBytes(($response|ConvertTo-Json -Depth 40 -Compress));$outputStream=[Console]::OpenStandardOutput()
    try{$outputStream.Write($bytes,0,$bytes.Length);$outputStream.Flush()}finally{$outputStream.Dispose()}
}else{
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath));[void][IO.Directory]::CreateDirectory($parent)
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($response|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding $true))
}
if(-not $response.success){exit 1}
