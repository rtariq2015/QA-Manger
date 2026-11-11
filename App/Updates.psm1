Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
function Assert-QaUpdateDirectPath([string]$Path) {
    $p=[IO.Path]::GetFullPath($Path)
    while($p){if(([IO.File]::Exists($p) -or [IO.Directory]::Exists($p)) -and (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Update files must use direct local folders without links or junctions.'};$p=[IO.Path]::GetDirectoryName($p)}
}
function Test-QaUpdateRelativePath([string]$Name) {
    if(-not $Name -or $Name.StartsWith('/') -or $Name -match '[\x00-\x1f<>:"|?*]'){return $false}
    foreach($part in $Name.Split('/')){if(-not $part -or $part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){return $false}}
    return $true
}
function Test-QaUpdatePayloadName([string]$Name) {
    if($Name -in @('Package.json','Package-SHA256SUMS.txt','Start CT QA Manager.cmd','Update CT QA Manager.cmd','Export CT QA Diagnostics.cmd','User Guide.html','Config/Settings.json')){return $true}
    if($Name -ceq 'App/Host/CTQa.Host.exe' -or $Name -in @('App/Web/app.js','App/Web/app.css','App/Web/trends.js')){return $true}
    # Python assets are admitted only inside the bundled reader namespace.
    # Other executable and script locations retain the existing restrictions.
    if($Name -ceq 'App/Python/read_pdf.py' -or $Name -ceq 'App/Python/vendor/pypdf/py.typed'){return $true}
    if($Name -cmatch '^App/Python/runtime/(?:python(?:w)?\.exe|python[0-9]{2,4}\.(?:zip|_pth)|python\.cat|[A-Za-z0-9_.-]+\.pyd)$'){return $true}
    if($Name -cmatch '^App/Python/vendor/pypdf/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.py$'){return $true}
    if($Name -cmatch '^App/Python/vendor/pypdf-[0-9][0-9A-Za-z.+_-]*\.dist-info/(?:METADATA|RECORD|WHEEL|LICENSE|licenses/LICENSE)$'){return $true}
    return ($Name.StartsWith('App/',[StringComparison]::Ordinal) -and $Name -match '\.(ps1|psm1|xaml|dll|json|txt|html)$')
}
function Test-QaUpdateFolder {
    [CmdletBinding()]param([string]$SourceFolder)
    $source=[IO.Path]::GetFullPath($SourceFolder).TrimEnd('\','/');Assert-QaUpdateDirectPath $source
    $metadata=Join-Path $source 'Package.json';$manifest=Join-Path $source 'Package-SHA256SUMS.txt'
    foreach($p in @($metadata,$manifest)){Assert-QaUpdateDirectPath $p;if(-not [IO.File]::Exists($p)){throw 'This ZIP is not a complete CT QA update package.'}}
    if((Get-Item $metadata).Length -gt 16384 -or (Get-Item $manifest).Length -gt 1048576){throw 'Invalid update package metadata size.'}
    $package=[IO.File]::ReadAllText($metadata)|ConvertFrom-Json
    if($package.Name -cne 'CT QA Manager Pro' -or $package.SchemaVersion -ne 1 -or [string]$package.Version -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$' -or [version]$package.Version -lt [version]'4.3.0'){throw 'Unsupported update package identity or version.'}
    $hashes=@{}
    foreach($line in [IO.File]::ReadAllLines($manifest)){
        if(-not $line.Trim()){continue}
        if($line -notmatch '^([0-9a-fA-F]{64})  (.+)$'){throw 'Invalid update checksum list.'}
        $hash=$Matches[1];$name=$Matches[2]
        if(-not (Test-QaUpdateRelativePath $name) -or -not (Test-QaUpdatePayloadName $name) -or $name -eq 'Package-SHA256SUMS.txt' -or $hashes.ContainsKey($name)){throw 'Invalid or duplicate name in the update checksum list.'}
        $hashes[$name]=$hash
    }
    foreach($required in @('Package.json','Start CT QA Manager.cmd','User Guide.html','Config/Settings.json','App/Start.ps1','App/MainWindow.xaml','App/Upgrade.ps1','App/Updates.psm1','App/Workspace.psm1')){if(-not $hashes.ContainsKey($required)){throw ('Update package is missing '+$required+'.')}}
    if([version]$package.Version -ge [version]'5.0.0'){foreach($required in @('App/Start-Web.ps1','App/WebWorker.ps1','App/WebService.psm1','App/Host/CTQa.Host.exe','App/Web/index.html','App/Web/app.css','App/Web/app.js')){if(-not $hashes.ContainsKey($required)){throw ('The offline HTML update is missing '+$required)}}}
    if([version]$package.Version -ge [version]'5.3.0'){foreach($required in @('App/Trends.psm1','App/Web/trends.js','App/MeasurementParser.psm1','App/Python/read_pdf.py','App/Python/Sources.json','App/Python/Integrity.json','App/Python/runtime/python.exe','App/Python/vendor/pypdf/__init__.py')){if(-not $hashes.ContainsKey($required)){throw ('The portable PDF reader update is missing '+$required)}}}
    if([version]$package.Version -ge [version]'5.3.1' -and -not $hashes.ContainsKey('App/SupportDiagnostics.psm1')){throw 'The diagnostic-report update is missing App/SupportDiagnostics.psm1.'}
    if([version]$package.Version -ge [version]'5.3.0'){
        $runtimePaths=@($hashes.Keys|Where-Object{$_ -cmatch '^App/Python/runtime/python[0-9]{2,4}\._pth$'})
        if($runtimePaths.Count -ne 1 -or -not $hashes.ContainsKey(($runtimePaths[0] -replace '\._pth$','.zip')) -or -not $hashes.ContainsKey(($runtimePaths[0] -replace '\._pth$','.dll'))){throw 'The portable Python standard library or import configuration is missing.'}
    }
    $files=@(Get-ChildItem -LiteralPath $source -Recurse -File);$seen=@{};$bytes=[long]0
    foreach($file in $files){
        Assert-QaUpdateDirectPath $file.FullName;$name=$file.FullName.Substring($source.Length+1).Replace('\','/')
        if($name -eq 'Package-SHA256SUMS.txt'){continue}
        if(-not (Test-QaUpdateRelativePath $name) -or -not (Test-QaUpdatePayloadName $name) -or -not $hashes.ContainsKey($name)){throw 'The update contains an unexpected or unchecked file.'}
        if((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $hashes[$name]){throw ('An update file is damaged or changed: '+$name)}
        $seen[$name]=$true;$bytes+=$file.Length
    }
    if($seen.Count -ne $hashes.Count){throw 'Some files named by the update checksum list are missing.'}
    return [pscustomobject]@{Version=[string]$package.Version;Files=$seen.Count;Bytes=$bytes;SourceFolder=$source}
}
function Remove-QaUpdateStage {
    [CmdletBinding()]param([string]$AppRoot,[string]$StageRoot)
    $root=[IO.Path]::GetFullPath($AppRoot).TrimEnd('\','/');$stage=[IO.Path]::GetFullPath($StageRoot).TrimEnd('\','/')
    if(-not [IO.Path]::GetDirectoryName($stage).Equals($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($stage) -notmatch '^\.pending-update-[0-9a-f]{32}$'){throw 'Refusing to remove a folder that is not an update stage.'}
    Assert-QaUpdateDirectPath $stage
    $marker=Join-Path $stage 'UpdateStage.marker';Assert-QaUpdateDirectPath $marker
    if(-not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne 'CT QA Manager update stage v1'){throw 'Update staging marker is missing.'}
    if([IO.Directory]::Exists($stage)){Remove-Item -LiteralPath $stage -Recurse -Force}
}
function New-QaUpdateStage {
    [CmdletBinding()]param([string]$AppRoot,[string]$ZipPath)
    $zip=[IO.Path]::GetFullPath($ZipPath);$root=[IO.Path]::GetFullPath($AppRoot);Assert-QaUpdateDirectPath $zip;Assert-QaUpdateDirectPath $root
    if([IO.Path]::GetExtension($zip) -ne '.zip' -or -not [IO.File]::Exists($zip)){throw 'Choose one downloaded update ZIP file.'}
    if((Get-Item -LiteralPath $zip).Length -gt 268435456){throw 'The update ZIP exceeds the 256 MB limit.'}
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($zip);$stage='';$success=$false
    try {
        if($archive.Entries.Count -gt 4096){throw 'The update contains too many entries.'}
        $names=@{};$entries=New-Object 'System.Collections.Generic.List[object]';$bytes=[long]0
        foreach($entry in $archive.Entries){
            $name=$entry.FullName.Replace('\','/');$directory=$name.EndsWith('/');$clean=$name.TrimEnd('/')
            if(-not (Test-QaUpdateRelativePath $clean) -or $names.ContainsKey($clean)){throw 'The ZIP contains an unsafe or duplicate path.'}
            $names[$clean]=$true
            if((([long]$entry.ExternalAttributes -shr 16) -band 61440) -eq 40960 -or (([long]$entry.ExternalAttributes -band 1024) -ne 0)){throw 'Linked update entries are unsupported.'}
            if($directory){continue}
            if($entry.Length -gt 134217728){throw 'An update file exceeds the size limit.'};$bytes+=$entry.Length
            if($bytes -gt 268435456){throw 'Expanded update exceeds the 256 MB limit.'}
            [void]$entries.Add([pscustomobject]@{Name=$name;Entry=$entry})
        }
        $metadata=@($entries.ToArray()|Where-Object{$_.Name -eq 'Package.json' -or $_.Name.EndsWith('/Package.json',[StringComparison]::Ordinal)})
        if($metadata.Count -ne 1){throw 'The ZIP must contain one CT QA update package.'}
        $prefix=$metadata[0].Name.Substring(0,$metadata[0].Name.Length-'Package.json'.Length)
        foreach($item in $entries){if(-not $item.Name.StartsWith($prefix,[StringComparison]::Ordinal)){throw 'Unexpected files outside the update package.'};$relative=$item.Name.Substring($prefix.Length);if(-not (Test-QaUpdatePayloadName $relative)){throw 'This is not a clean application update ZIP.'}}
        $stage=Join-Path $root ('.pending-update-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($stage)
        [IO.File]::WriteAllText((Join-Path $stage 'UpdateStage.marker'),'CT QA Manager update stage v1')
        $source=Join-Path $stage 'Package';[void][IO.Directory]::CreateDirectory($source)
        foreach($item in $entries){
            $relative=$item.Name.Substring($prefix.Length);$destination=Join-Path $source $relative;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            $inputStream=$item.Entry.Open();$outputStream=$null
            try{
                $outputStream=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$buffer=New-Object byte[] 32768;$written=[long]0
                while(($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){$written+=$read;if($written -gt $item.Entry.Length){throw 'ZIP file size does not match its metadata.'};$outputStream.Write($buffer,0,$read)}
                if($written -ne $item.Entry.Length){throw 'An update file is incomplete.'}
            }finally{if($null -ne $outputStream){$outputStream.Dispose()};$inputStream.Dispose()}
        }
        $plan=Test-QaUpdateFolder -SourceFolder $source
        $success=$true
        return [pscustomobject]@{Version=$plan.Version;Files=$plan.Files;Bytes=$plan.Bytes;SourceFolder=$source;StageRoot=$stage}
    }finally{$archive.Dispose();if(-not $success -and $stage){Remove-QaUpdateStage -AppRoot $root -StageRoot $stage}}
}
Export-ModuleMember -Function New-QaUpdateStage,Test-QaUpdateFolder,Remove-QaUpdateStage
