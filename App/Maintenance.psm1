Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Archive.psm1')

function Assert-QaMaintenanceDirect {param([string]$Path)
    $p=[IO.Path]::GetFullPath($Path)
    while($p){if(([IO.Directory]::Exists($p) -or [IO.File]::Exists($p)) -and (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Choose a direct folder without links or junctions.'};$p=[IO.Path]::GetDirectoryName($p)}
}
function Get-QaStorage {param([string]$Path,[long]$RequiredBytes=0)
    $full=[IO.Path]::GetFullPath($Path);$drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))
    if($drive.DriveType -eq [IO.DriveType]::Network){throw 'Choose approved local-disk or USB storage, not a mapped network destination.'}
    return [pscustomobject]@{AvailableBytes=$drive.AvailableFreeSpace;RequiredBytes=$RequiredBytes;Enough=($drive.AvailableFreeSpace -gt ($RequiredBytes+104857600));Label=('{0:N1} GB free' -f ($drive.AvailableFreeSpace/1GB))}
}
function Get-QaCompatibility {
    [CmdletBinding()]param([string]$AppRoot,$Config)
    $rows=New-Object 'System.Collections.Generic.List[object]'
    [void]$rows.Add([pscustomobject]@{Check='Windows workstation';Status=$(if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Available'}else{'Development host only'});Detail=[Environment]::OSVersion.ToString()})
    [void]$rows.Add([pscustomobject]@{Check='PowerShell language';Status=[string]$ExecutionContext.SessionState.LanguageMode;Detail='FullLanguage is needed for WPF and native network components. Follow IT policy.'})
    [void]$rows.Add([pscustomobject]@{Check='Script policy';Status=[string](Get-ExecutionPolicy);Detail='This application never changes execution policy.'})
    foreach($path in @($AppRoot,$Config.ArchiveRoot)) {
        try {
            Assert-QaMaintenanceDirect $path
            if(-not [IO.Directory]::Exists($path)){throw 'Folder does not exist; choose a writable local folder.'}
            $probe=Join-Path $path ('.ctqa-write-'+[guid]::NewGuid().ToString('N')+'.tmp')
            try{$stream=[IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$stream.Dispose()}finally{if([IO.File]::Exists($probe)){[IO.File]::Delete($probe)}}
            [void]$rows.Add([pscustomobject]@{Check='Folder access';Status='Writable';Detail=$path})
        }catch{[void]$rows.Add([pscustomobject]@{Check='Folder access';Status='Needs attention';Detail=$_.Exception.Message})}
    }
    $release=0
    if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){try{$release=[int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release).Release}catch{}}
    [void]$rows.Add([pscustomobject]@{Check='Optional PDF reader';Status=$(if($release -ge 461808){'Framework available'}else{'Requires workstation check'});Detail='.NET Framework 4.7.2+, bundled DLL approval, and a readable text PDF are required.'})
    Import-Module (Join-Path $PSScriptRoot 'Process.psm1')
    foreach($source in $Config.Sources) {
        try{$available=Invoke-QaIsolatedTask Probe ([pscustomobject]@{Path=$source.Path}) -TimeoutSeconds 8;$status=if($available){'Accessible'}else{'Unavailable or access denied'}}catch{$status='Timed out or blocked'}
        [void]$rows.Add([pscustomobject]@{Check=[string]$source.Name;Status=$status;Detail='Read-only folder availability check; no credentials were requested.'})
    }
    return @($rows.ToArray())
}
function Add-QaBackupFile {param($Zip,[string]$Path,[string]$Name,$Manifest)
    Assert-QaMaintenanceDirect $Path
    $entry=$Zip.CreateEntry($Name,[IO.Compression.CompressionLevel]::Optimal);$input=$null;$output=$null;$sha=[Security.Cryptography.SHA256]::Create();$length=0L
    try {
        $input=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$output=$entry.Open();$buffer=New-Object byte[] 1048576
        while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0){$output.Write($buffer,0,$read);[void]$sha.TransformBlock($buffer,0,$read,$buffer,0);$length+=$read}
        [void]$sha.TransformFinalBlock($buffer,0,0)
        [void]$Manifest.Add([pscustomobject]@{Path=$Name;Length=$length;SHA256=([BitConverter]::ToString($sha.Hash)).Replace('-','')})
    }finally{if($null -ne $input){$input.Dispose()};if($null -ne $output){$output.Dispose()};$sha.Dispose()}
}
function New-QaBackup {
    [CmdletBinding()]param([string]$AppRoot,$Config,[string]$DestinationPath,$Progress=$null)
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    $destination=[IO.Path]::GetFullPath($DestinationPath);Assert-QaMaintenanceDirect $destination
    if([IO.File]::Exists($destination)){throw 'Choose a new backup filename. Existing backups are never overwritten.'}
    $root=[IO.Path]::GetFullPath($Config.ArchiveRoot).TrimEnd('\','/');$prefix=$root+[IO.Path]::DirectorySeparatorChar
    if($destination.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Save backups outside the live archive, preferably on approved separate storage.'}
    $lockPath=Join-Path $root '.ctqa/archive.lock';Assert-QaMaintenanceDirect $lockPath
    $lock=$null;$zip=$null;$stream=$null;$stage=$destination+'.'+[guid]::NewGuid().ToString('N')+'.partial'
    $scratch=Join-Path ([IO.Path]::GetTempPath()) ('CTQA_Backup_'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($scratch)
    try {
        $lock=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $dashboard=Get-QaDashboard $Config
        foreach($r in $dashboard.Records){Assert-QaMaintenanceDirect $r.DestinationPath;if((Get-FileHash -LiteralPath $r.DestinationPath -Algorithm SHA256).Hash -ne $r.Hash){throw 'An archived PDF failed verification. Run the integrity audit before backing up.'}}
        $files=New-Object 'System.Collections.Generic.List[object]'
        foreach($folder in @('Reports','.ctqa','Browse Reports','Report Library')) {
            $base=Join-Path $root $folder
            if([IO.Directory]::Exists($base)) {
                Assert-QaMaintenanceDirect $base
                foreach($file in Get-ChildItem -LiteralPath $base -File -Recurse){
                    Assert-QaMaintenanceDirect $file.FullName
                    if($file.Name -eq 'archive.lock' -or $file.Extension -eq '.tmp'){continue}
                    $rel=$file.FullName.Substring($prefix.Length).Replace('\','/')
                    [void]$files.Add([pscustomobject]@{Path=$file.FullName;Name=('Data/'+$rel)})
                }
            }
        }
        foreach($name in @('QA_Master_Index.csv','Activity.csv')){if([IO.File]::Exists((Join-Path $root $name))){[void]$files.Add([pscustomobject]@{Path=(Join-Path $root $name);Name=('Data/'+$name)})}}
        $program=Join-Path $AppRoot 'App'
        foreach($file in Get-ChildItem -LiteralPath $program -File -Recurse){Assert-QaMaintenanceDirect $file.FullName;[void]$files.Add([pscustomobject]@{Path=$file.FullName;Name=('App/'+$file.FullName.Substring($program.TrimEnd('\','/').Length+1).Replace('\','/'))})}
        foreach($name in @('Start CT QA Manager.cmd','User Guide.html')){[void]$files.Add([pscustomobject]@{Path=(Join-Path $AppRoot $name);Name=$name})}
        $saved=$Config|Select-Object * -ExcludeProperty AppRoot;$saved.ArchiveRoot='Data'
        $settings=Join-Path $scratch 'Settings.json';[IO.File]::WriteAllText($settings,($saved|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($true)))
        foreach($name in @('Config/Settings.local.json','Config/Settings.json')){[void]$files.Add([pscustomobject]@{Path=$settings;Name=$name})}
        $bytes=0L;foreach($file in $files){$bytes+=(Get-Item -LiteralPath $file.Path).Length}
        if(-not (Get-QaStorage $destination $bytes).Enough){throw 'Not enough free space for a verified backup.'}
        $manifest=New-Object 'System.Collections.Generic.List[object]'
        $stream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
        $n=0
        foreach($file in $files){if($null -ne $Progress -and $Progress.Cancel){throw [OperationCanceledException]::new('Backup cancelled.')};$n++;if($null -ne $Progress){$Progress.Message='Backing up '+$n+' of '+$files.Count;$Progress.Percent=80*$n/$files.Count};Add-QaBackupFile $zip $file.Path $file.Name $manifest}
        $entry=$zip.CreateEntry('Backup-Manifest.json');$writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($true)))
        try{$writer.Write(([pscustomobject]@{Format='CTQA-Backup';Version=1;CreatedUtc=[datetime]::UtcNow.ToString('o');CredentialsIncluded=$false;Files=@($manifest.ToArray())}|ConvertTo-Json -Depth 8))}finally{$writer.Dispose()}
        $zip.Dispose();$zip=$null;$stream.Dispose();$stream=$null
        # Read back every entry and validate its fingerprint before publishing the ZIP.
        Test-QaBackup -Path $stage -Progress $Progress|Out-Null
        if($null -ne $Progress -and $Progress.Cancel){throw [OperationCanceledException]::new('Backup cancelled.')}
        [IO.File]::Move($stage,$destination)
        return [pscustomobject]@{Mode='Backup';DestinationPath=$destination;Summary=[pscustomobject]@{Description='Full backup created and verified. Saved sign-ins are excluded; re-enter them after moving computers.';Cancelled=$false}}
    }finally{if($null -ne $zip){$zip.Dispose()};if($null -ne $stream){$stream.Dispose()};if($null -ne $lock){$lock.Dispose()};if([IO.File]::Exists($stage)){[IO.File]::Delete($stage)};Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue}
}
function Test-QaBackupEntryName {
    param([string]$Name)
    if(-not $Name -or $Name.StartsWith('/') -or $Name -match '[\\\x00-\x1f<>:"|?*]'){return $false}
    foreach($part in $Name.Split('/')){
        if(-not $part -or $part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){return $false}
    }
    return $true
}
function Read-QaBackupArchive {
    param($Zip,$Progress=$null)
    # Inspect ZIP names and attributes before reading contents, and reject
    # duplicate or Windows-aliased members explicitly as well as in the manifest.
    $entries=@{}
    foreach($entry in $Zip.Entries){
        $name=[string]$entry.FullName
        if(-not (Test-QaBackupEntryName $name) -or $entries.ContainsKey($name)){throw 'Unsafe or duplicate backup ZIP entry.'}
        if((([long]$entry.ExternalAttributes -shr 16) -band 61440) -eq 40960 -or (([long]$entry.ExternalAttributes -band 1024) -ne 0)){throw 'Linked backup entries are unsupported.'}
        $entries[$name]=$entry
    }
    $entry=$Zip.GetEntry('Backup-Manifest.json');if($null -eq $entry -or $entry.Length -gt 16777216){throw 'Backup manifest is missing or too large.'}
    $reader=New-Object IO.StreamReader($entry.Open());try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
    if($manifest.Format -ne 'CTQA-Backup' -or $manifest.Version -ne 1){throw 'Unsupported backup format.'}
    $seen=@{};$total=0L
    foreach($file in @($manifest.Files)) {
        $name=[string]$file.Path
        if(-not (Test-QaBackupEntryName $name) -or $name -notmatch '^(App/|Config/Settings(?:\.local)?\.json$|Data/|Start CT QA Manager\.cmd$|User Guide\.html$)' -or $seen.ContainsKey($name) -or $file.SHA256 -notmatch '^[0-9A-Fa-f]{64}$' -or [long]$file.Length -lt 0){throw 'Unsafe or duplicate backup entry.'}
        $seen[$name]=$true;$entry=$null;if($entries.ContainsKey($name)){$entry=$entries[$name]}
        if($null -eq $entry -or $entry.FullName -cne $name -or $entry.Length -ne [long]$file.Length){throw 'Backup size or file list differs from its manifest.'}
        if($null -ne $Progress -and $Progress.Cancel){throw [OperationCanceledException]::new('Backup verification cancelled.')}
        $input=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=([BitConverter]::ToString($sha.ComputeHash($input))).Replace('-','')}finally{$input.Dispose();$sha.Dispose()}
        if($hash -ne $file.SHA256){throw 'Backup checksum mismatch.'};$total+=[long]$file.Length
    }
    if($Zip.Entries.Count -ne ($seen.Count+1)){throw 'Backup contains unexpected entries.'}
    return [pscustomobject]@{Files=@($manifest.Files);TotalBytes=$total}
}
function Test-QaBackup {
    [CmdletBinding()]param([string]$Path,$Progress=$null)
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    Assert-QaMaintenanceDirect $Path;$zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try {return (Read-QaBackupArchive -Zip $zip -Progress $Progress)}finally{$zip.Dispose()}
}
function Restore-QaBackup {
    [CmdletBinding()]param([string]$Path,[string]$DestinationFolder,$Progress=$null)
    $destination=[IO.Path]::GetFullPath($DestinationFolder);Assert-QaMaintenanceDirect $destination
    if([IO.Directory]::Exists($destination) -or [IO.File]::Exists($destination)){throw 'Restore requires a new folder. Existing files are never replaced.'}
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    Assert-QaMaintenanceDirect $Path;$zip=[IO.Compression.ZipFile]::OpenRead($Path);$stage=''
    try {
        # Keep one read-only archive open from validation through copying. On Windows
        # its read sharing also prevents source replacement while restore is active.
        $checked=Read-QaBackupArchive -Zip $zip -Progress $Progress
        if(-not (Get-QaStorage $destination $checked.TotalBytes).Enough){throw 'Not enough storage to restore this backup.'}
        $stage=$destination+'.'+[guid]::NewGuid().ToString('N')+'.partial';[void][IO.Directory]::CreateDirectory($stage)
        foreach($file in $checked.Files){
            if($null -ne $Progress -and $Progress.Cancel){throw [OperationCanceledException]::new('Restore cancelled.')}
            $target=[IO.Path]::GetFullPath((Join-Path $stage $file.Path))
            if(-not $target.StartsWith(($stage+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe restore path.'}
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $input=$zip.GetEntry($file.Path).Open();$output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$input.CopyTo($output);$output.Flush($true)}finally{$input.Dispose();$output.Dispose()}
            if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.SHA256){throw 'Restored file checksum mismatch.'}
        }
        [IO.Directory]::Move($stage,$destination)
        return [pscustomobject]@{Mode='Restore';DestinationPath=$destination;Summary=[pscustomobject]@{Description='Backup restored to a separate portable folder. Open its launcher; re-enter saved sign-ins as needed.';Cancelled=$false}}
    }finally{$zip.Dispose();if($stage -and [IO.Directory]::Exists($stage)){Remove-Item -LiteralPath $stage -Recurse -Force}}
}
Export-ModuleMember -Function Get-QaStorage,Get-QaCompatibility,New-QaBackup,Test-QaBackup,Restore-QaBackup
