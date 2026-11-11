# JSON adapter called by the local application host. No arbitrary command execution.
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$AppRoot,[Parameter(Mandatory=$true)][string]$InputPath,[Parameter(Mandatory=$true)][string]$OutputPath,[string]$ProgressPath="",[string]$CancelPath="",[switch]$IsolatedPdfRead)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue';$ProgressPreference='SilentlyContinue';$InformationPreference='SilentlyContinue'
$operation='';$clock=[Diagnostics.Stopwatch]::StartNew()
$shared=$null;$watchPowerShell=$null;$watchRunspace=$null;$watchHandle=$null
function Start-QaWebProgressMonitor {
    param([string]$Root,[string]$Destination,[string]$Cancellation)
    if(-not $Destination -and -not $Cancellation){return $null}
    $base=[IO.Path]::GetFullPath((Join-Path $Root 'Data/.web-jobs')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    foreach($path in @($Destination,$Cancellation)) {
        if(-not $path -or -not [IO.Path]::GetFullPath($path).StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'The progress channel does not belong to this program.'}
        $ancestor=[IO.Path]::GetFullPath($path)
        while($ancestor){if(([IO.File]::Exists($ancestor) -or [IO.Directory]::Exists($ancestor)) -and (([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Use direct files for local progress.'};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    }
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Destination)) -cne [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Cancellation))){throw 'The local progress channel is invalid.'}
    return [hashtable]::Synchronized(@{Stage='Preparing';Completed=0;Total=0;Percent=-1;Copied=0;Unchanged=0;Failed=0;Cancel=[IO.File]::Exists($Cancellation);Done=$false;Message='';BackgroundRead=$false;ReaderProcessIsolated=$false})
}

try{
    $text=if($InputPath -in @('-','stdin')){
        # Read the redirected pipe directly. Resetting Console.InputEncoding on
        # Windows PowerShell 5.1 can invalidate its cached text input reader.
        $inputStream=[Console]::OpenStandardInput();$reader=New-Object IO.StreamReader($inputStream,(New-Object Text.UTF8Encoding($false,$true)),$true,4096)
        try{$reader.ReadToEnd()}finally{$reader.Dispose()}
    }else{[IO.File]::ReadAllText($InputPath)}
    if($text.Length -gt 2097152){throw 'The application request is too large.'};try{$request=$text|ConvertFrom-Json}catch{throw 'The application request could not be read. Try the action again.'}
    Import-Module (Join-Path $PSScriptRoot 'WebService.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot 'Support.psm1') -Global -DisableNameChecking -WarningAction SilentlyContinue
    $maps=@{Refresh='Update';Approve='Reclassify';Disapprove='Reclassify';Undo='Reclassify';Reconnect='Reconnect';Settings='Settings';ApplyProfile='Settings';ScannerSettings='Settings';Export='Export';Analyze='Analysis';Backup='Backup';Restore='Restore';Diagnostics='Diagnostics';PrintDiagnostics='PrintDiagnostics';Audit='Audit';Browse='BrowseRefresh';SyncLibrary='BrowseRefresh';PrepareUpdate='OfflineUpdate';InstallPreparedUpdate='OfflineUpdate'}
    if($null -ne $request.PSObject.Properties['action'] -and $maps.ContainsKey([string]$request.action)){$operation=$maps[[string]$request.action];Write-QaSupportEvent -AppRoot $AppRoot -Operation $operation -Outcome Started}
    $shared=Start-QaWebProgressMonitor -Root $AppRoot -Destination $ProgressPath -Cancellation $CancelPath
    if($null -ne $shared){
        $selected=if($null -ne $request.PSObject.Properties['id']){[string]$request.id}else{''}
        # Only the Host command line can enable this optimization. Request JSON
        # cannot grant it; the current helper is already isolated to one PDF.
        if($IsolatedPdfRead){
            $single=($selected -cmatch '^[0-9A-Fa-f]{64}$')
            if(-not $single -and $null -ne $request.PSObject.Properties['ids'] -and $null -ne $request.PSObject.Properties['analysisStep'] -and $request.analysisStep -is [bool] -and $request.analysisStep){$ids=@($request.ids);$single=($ids.Count -eq 1 -and $ids[0] -is [string] -and [string]$ids[0] -cmatch '^[0-9A-Fa-f]{64}$')}
            if([string]$request.action -cne 'Analyze' -or -not $single){throw 'The isolated PDF helper must select exactly one saved report.'}
            $shared.ReaderProcessIsolated=$true
        }
        $shared.BackgroundRead=($null -ne $request.PSObject.Properties['action'] -and [string]$request.action -ceq 'Analyze' -and -not $selected)
        if($shared.BackgroundRead){try{[Diagnostics.Process]::GetCurrentProcess().PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal}catch{}}
        $watchCode=@'
param($Progress,$Path,$Cancellation)
$ErrorActionPreference='Stop'
$stages=@('Preparing','Connecting','Scanning','Copying','Library','Analyzing','Exporting','BackingUp','Restoring','Verifying','Finishing','Planning','Snapshot','Parsing','Cache')
function Get-Count([string]$Name){$n=0L;if([long]::TryParse([string]$Progress[$Name],[ref]$n) -and $n -ge 0 -and $n -le 100000000){return $n};return 0L}
try{
    while($true){
        if([IO.File]::Exists($Cancellation)){$Progress.Cancel=$true}
        $stage=[string]$Progress.Stage;if($stages -cnotcontains $stage){$stage='Preparing'}
        $percent=-1.0;$candidate=0.0;if([double]::TryParse([string]$Progress.Percent,[ref]$candidate) -and -not [double]::IsNaN($candidate) -and -not [double]::IsInfinity($candidate)){$percent=[math]::Max(-1,[math]::Min(100,$candidate))}
        $payload=[ordered]@{stage=$stage;completed=(Get-Count 'Completed');total=(Get-Count 'Total');percent=$percent;copied=(Get-Count 'Copied');unchanged=(Get-Count 'Unchanged');failed=(Get-Count 'Failed');cancelRequested=[bool]$Progress.Cancel}
        # Deliberately omit Message and every caller string: they can contain filenames or network paths.
        $temp=$Path+'.tmp'
        try{[IO.File]::WriteAllText($temp,($payload|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding $false));if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,($Path+'.previous'))}else{[IO.File]::Move($temp,$Path)}}catch{}finally{if([IO.File]::Exists($temp)){try{[IO.File]::Delete($temp)}catch{}}}
        if($Progress.Done){break}
        Start-Sleep -Milliseconds 150
    }
}finally{}
'@
        $watchRunspace=[RunspaceFactory]::CreateRunspace();$watchRunspace.Open();$watchPowerShell=[PowerShell]::Create();$watchPowerShell.Runspace=$watchRunspace
        [void]$watchPowerShell.AddScript($watchCode).AddArgument($shared).AddArgument($ProgressPath).AddArgument($CancelPath);$watchHandle=$watchPowerShell.BeginInvoke()
    }
    $value=Invoke-QaWebRequest -AppRoot $AppRoot -Request $request -Progress $shared
    $response=[pscustomobject]@{success=$true;value=$value}
    $wasCancelled=($null -ne $value -and $null -ne $value.PSObject.Properties['cancelled'] -and [bool]$value.cancelled)
    if($operation){
        $counts=@{};$detail=if($null -ne $value -and $null -ne $value.PSObject.Properties['result']){$value.result}else{$null}
        foreach($name in @('Analyzed','Cached','Failed','Pending')){if($null -ne $detail -and $null -ne $detail.PSObject.Properties[$name]){$counts[$name]=[int]$detail.$name}}
        Write-QaSupportEvent -AppRoot $AppRoot -Operation $operation -Outcome $(if($wasCancelled){'Cancelled'}else{'Completed'}) -DurationMs $clock.ElapsedMilliseconds -Counts $counts -Stage Finishing -Reason $(if($wasCancelled){'WorkerCancelled'}elseif($operation -ceq 'Analysis'){'ReadCompleted'}else{'OperationCompleted'})
    }
}catch{
    $message=$_.Exception.Message;$kind='Operation';$code=0
    if($message -match 'Windows error (\d+)'){$code=[int]$Matches[1]}
    if($message -match 'changed|stale|already organized|no longer'){$kind='Conflict'}elseif($message -match 'unsupported|Choose|Select|Enter|requires|Invalid'){$kind='Input'}elseif($message -match 'already running|already open'){$kind='Busy'}
    $cancelledException=$false;$cause=$_.Exception
    while($null -ne $cause){if($cause -is [OperationCanceledException]){$cancelledException=$true;break};$cause=$cause.InnerException}
    $cooperativeCancel=($null -ne $shared -and $shared.Cancel -and $cancelledException)
    if($operation){try{Write-QaSupportEvent -AppRoot $AppRoot -Operation $operation -Outcome $(if($cooperativeCancel){'Cancelled'}else{'Failed'}) -DurationMs $clock.ElapsedMilliseconds -ErrorKind $(if($cooperativeCancel){'None'}else{Get-QaSupportErrorKind $message})}catch{}}
    if($cooperativeCancel){
        $saved=$null;try{Import-Module (Join-Path $PSScriptRoot 'Archive.psm1') -DisableNameChecking -WarningAction SilentlyContinue;$saved=Get-QaWebSnapshot (Read-QaConfig $AppRoot)}catch{}
        $response=[pscustomobject]@{success=$true;value=[pscustomobject]@{cancelled=$true;message='Stopped safely. Completed verified reports remain saved.';snapshot=$saved}}
    }else{$response=[pscustomobject]@{success=$false;error=[pscustomobject]@{message=$message;kind=$kind;code=$code}}}
}finally{
    if($null -ne $shared){$shared.Done=$true}
    if($null -ne $watchPowerShell){try{if(-not $watchHandle.AsyncWaitHandle.WaitOne(3000)){$watchPowerShell.Stop()};[void]$watchPowerShell.EndInvoke($watchHandle)}catch{}finally{$watchPowerShell.Dispose();$watchRunspace.Dispose()}}
}
if($OutputPath -in @('-','stdout')){
    $bytes=(New-Object Text.UTF8Encoding $false).GetBytes(($response|ConvertTo-Json -Depth 40 -Compress));$outputStream=[Console]::OpenStandardOutput()
    try{$outputStream.Write($bytes,0,$bytes.Length);$outputStream.Flush()}finally{$outputStream.Dispose()}
}else{
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath));[void][IO.Directory]::CreateDirectory($parent)
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($response|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding $true))
}
if(-not $response.success){exit 1}
