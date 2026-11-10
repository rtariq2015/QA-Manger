Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Initialize-QaWorkspace {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$AppRoot)
    $root=[IO.Path]::GetFullPath($AppRoot)
    $config=Join-Path $root 'Config';$local=Join-Path $config 'Settings.local.json'
    if(-not [IO.File]::Exists($local)) {
        $baseline=Join-Path $config 'Settings.json'
        $settings=[IO.File]::ReadAllText($baseline)|ConvertFrom-Json
        # Preserve a legacy in-place archive. New installations keep all data below Data.
        if([string]$settings.ArchiveRoot -eq '.' -and -not [IO.File]::Exists((Join-Path $root '.ctqa/state.json'))) {$settings.ArchiveRoot='Data'}
        $temp=$local+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try {
            [IO.File]::WriteAllText($temp,($settings|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding($true)))
            [IO.File]::Move($temp,$local)
        } finally {if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    }
    foreach($folder in @('Data','Logs','Backups')) {[void][IO.Directory]::CreateDirectory((Join-Path $root $folder))}
    return $local
}

Export-ModuleMember -Function Initialize-QaWorkspace
