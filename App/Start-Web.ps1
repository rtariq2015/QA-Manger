# Offline HTML front end. Uses the host bundled with this portable release.
[CmdletBinding()]param([switch]$PortableLaunch,[switch]$NoBrowser)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$consoleHandle=[intptr]::Zero
try {
    $root=Split-Path -Parent $PSScriptRoot
    $hostPath=Join-Path $PSScriptRoot 'Host/CTQa.Host.exe'
    if(-not [IO.File]::Exists($hostPath)){throw 'The offline HTML host is missing. Extract the complete portable ZIP. The previous Windows interface is still available by running Start CT QA Manager.cmd classic.'}
    $arguments=@('--root',$root)
    if($NoBrowser){$arguments+=@('--no-browser')}
    $cache=Join-Path $root 'Data/RuntimeCache'
    foreach($item in @($cache,$hostPath)) {
        $ancestor=[IO.Path]::GetFullPath($item)
        while($ancestor){if(([IO.File]::Exists($ancestor) -or [IO.Directory]::Exists($ancestor)) -and (([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Use a direct portable program folder without links or junctions.'};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    }
    [void][IO.Directory]::CreateDirectory($cache)
    if($PortableLaunch -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CtQa.Web {
 public static class ConsoleWindow {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool ShowWindow(IntPtr window, int command);
 }
}
'@
            $consoleHandle=[CtQa.Web.ConsoleWindow]::GetConsoleWindow()
            if($consoleHandle -ne [intptr]::Zero){[void][CtQa.Web.ConsoleWindow]::ShowWindow($consoleHandle,0)}
        }catch{$consoleHandle=[intptr]::Zero}
    }
    $previousExtract=$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR
    try {$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR=$cache; & $hostPath @arguments}
    finally {$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR=$previousExtract}
    if($LASTEXITCODE -ne 0){throw 'The local HTML interface could not start. Close another CT QA Manager window, check folder access, or use Start CT QA Manager.cmd classic.'}
} catch {
    if($consoleHandle -ne [intptr]::Zero){try{[void][CtQa.Web.ConsoleWindow]::ShowWindow($consoleHandle,5)}catch{}}
    Write-Error $_.Exception.Message
    exit 1
}
