Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Invoke-QaIsolatedTask {
    [CmdletBinding()]param([string]$Action,$InputObject,[int]$TimeoutSeconds=30,$Progress=$null)
    $base=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_Worker_'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($base)
    $inputPath=Join-Path $base 'input.xml';$outputPath=Join-Path $base 'output.xml';$process=$null
    try {
        # Windows encrypts SecureStrings with current-user DPAPI; no password arguments.
        if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -and $null -ne $InputObject.PSObject.Properties['Credential'] -and $null -ne $InputObject.Credential){throw 'Credential workers require Windows DPAPI.'}
        $InputObject|Export-Clixml -LiteralPath $inputPath -Depth 18 -Encoding UTF8
        $worker=Join-Path $PSScriptRoot 'TaskWorker.ps1'
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=(Get-Process -Id $PID).Path
        $info.Arguments='-NoLogo -NoProfile -File "'+$worker+'" -Action '+$Action+' -InputPath "'+$inputPath+'" -OutputPath "'+$outputPath+'"'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $process=[Diagnostics.Process]::Start($info);$timer=[Diagnostics.Stopwatch]::StartNew()
        $backgroundRead=($null -ne $Progress -and $Progress -is [Collections.IDictionary] -and $Progress.Contains('BackgroundRead') -and [bool]$Progress['BackgroundRead'])
        if($backgroundRead){try{$process.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal}catch{}}
        while(-not $process.WaitForExit(100)) {
            if(($null -ne $Progress -and $Progress.Cancel) -or $timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                try{$process.Kill();[void]$process.WaitForExit(3000)}catch{}
                if($null -ne $Progress -and $Progress.Cancel){throw [OperationCanceledException]::new('Cancelled while waiting for scanner or PDF reader.')}
                throw ('The '+$Action+' operation exceeded '+$TimeoutSeconds+' seconds. Saved reports remain available.')
            }
        }
        if(-not [IO.File]::Exists($outputPath)){throw 'The worker was blocked or could not finish. Check workstation policy.'}
        $result=Import-Clixml -LiteralPath $outputPath
        if(-not $result.Success){throw [string]$result.Error}
        return $result.Value
    } finally {
        if($null -ne $process){if(-not $process.HasExited){try{$process.Kill()}catch{}};$process.Dispose()}
        if([IO.Directory]::Exists($base)){Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue}
    }
}
Export-ModuleMember -Function Invoke-QaIsolatedTask
