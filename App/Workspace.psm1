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
    $profile=Join-Path $config 'NetworkProfile.local.json'
    if([IO.File]::Exists($profile)){[void](Set-QaConnectionProfile -AppRoot $root -ProfilePath $profile)}
    return $local
}

function Set-QaConnectionProfile {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$AppRoot,[Parameter(Mandatory=$true)][string]$ProfilePath,[switch]$ReplaceExisting)
    Import-Module (Join-Path $PSScriptRoot 'Network.psm1') -DisableNameChecking
    $local=Join-Path (Join-Path $AppRoot 'Config') 'Settings.local.json'
    if(-not [IO.File]::Exists($local)){throw 'Open the application once to create its local settings before importing a profile.'}
    foreach($path in @($local,$ProfilePath)) {
        $ancestor=[IO.Path]::GetFullPath($path)
        while($ancestor){if(([IO.Directory]::Exists($ancestor) -or [IO.File]::Exists($ancestor)) -and (([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Connection profiles and settings must use direct files, without links or junctions.'};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    }
    if((Get-Item -LiteralPath $ProfilePath).Length -gt 65536){throw 'The connection profile is too large.'}
    $profile=[IO.File]::ReadAllText($ProfilePath)|ConvertFrom-Json
    if($profile.Version -ne 1 -or @($profile.Connections).Count -lt 1 -or @($profile.Connections).Count -gt 20){throw 'Unsupported connection profile.'}
    $settings=[IO.File]::ReadAllText($local)|ConvertFrom-Json
    $seen=@{};$applied=0;$matched=0;$skipped=New-Object 'System.Collections.Generic.List[string]'
    foreach($property in $profile.PSObject.Properties){if($property.Name -match '(?i)password|secret|credential'){throw 'Profiles must not contain passwords or credential files. Use the secure sign-in prompt.'}}
    foreach($connection in @($profile.Connections)) {
        foreach($property in $connection.PSObject.Properties){if($property.Name -match '(?i)password|secret|credential'){throw 'Profiles must not contain passwords. Enter them only in the secure sign-in prompt.'}}
        $id=[string]$connection.Scanner
        if($id -notmatch '^[A-Za-z][A-Za-z0-9_]{0,31}$' -or $seen.ContainsKey($id)){throw 'Profile scanner identifiers must be unique.'};$seen[$id]=$true
        $location=Get-QaNetworkLocation ([string]$connection.Path)
        $username=[string]$connection.Username
        if(-not $username.Trim() -or $username.Length -gt 256 -or $username -match '[\x00-\x1f]'){throw 'Enter a valid scanner username in the profile.'}
        $sources=@($settings.Sources|Where-Object{$_.Scanner -ceq $id})
        if($sources.Count -ne 1){[void]$skipped.Add($id);continue};$source=$sources[0]
        $same=([string]$source.Path).TrimEnd('\').Equals($location.Path,[StringComparison]::OrdinalIgnoreCase)
        if(-not $ReplaceExisting -and -not $same -and -not (Test-QaPlaceholderConnection $source)){[void]$skipped.Add($id);continue}
        $matched++
        $oldPath=[string]$source.Path
        $oldUsername=if($null -ne $source.PSObject.Properties['Username']){[string]$source.Username}else{''}
        if($same -and $oldUsername -ceq $username){continue}
        if(-not $same) {
            $previous=@();if($null -ne $source.PSObject.Properties['PreviousPaths']){$previous=@($source.PreviousPaths)}
            if(-not (Test-QaPlaceholderConnection $source) -and $previous -notcontains $oldPath){$previous+=@($oldPath)}
            $source|Add-Member -NotePropertyName PreviousPaths -NotePropertyValue ([object[]]$previous) -Force
        }
        $source.Path=$location.Path;$source|Add-Member -NotePropertyName Username -NotePropertyValue $username -Force
        $applied++
    }
    $paths=@{};foreach($source in $settings.Sources){$key=([string]$source.Path).TrimEnd('\');if($paths.ContainsKey($key)){throw 'The profile would assign two scanners to the same reports folder.'};$paths[$key]=$true}
    if($applied -gt 0) {
        $temp=$local+'.'+[guid]::NewGuid().ToString('N')+'.tmp';$backup=$local+'.before-network-profile.bak'
        if([IO.File]::Exists($backup) -and (([IO.File]::GetAttributes($backup) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'The settings backup uses a linked path.'}
        try{[IO.File]::WriteAllText($temp,($settings|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($true)));[IO.File]::Replace($temp,$local,$backup)}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    }
    return [pscustomobject]@{Applied=$applied;Matched=$matched;Skipped=@($skipped.ToArray());Message=($applied.ToString()+' connection settings updated locally. Archives and saved review history were preserved. Enter sign-ins securely on this workstation if needed.')}
}
Export-ModuleMember -Function Initialize-QaWorkspace,Set-QaConnectionProfile
