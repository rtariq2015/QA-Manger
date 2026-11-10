# CT QA Manager Pro readable browsing copies. Native PowerShell 5.1 / .NET.
# Copies are independent PDFs. No scanner or managed archive PDF is modified.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-QaBrowseValue { param($Object,[string]$Name,$Default='')
    if($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name}
    return $Default
}
function Test-QaBrowseCancelled { param($Progress)
    return ($null -ne $Progress -and $Progress.ContainsKey('Cancel') -and [bool]$Progress.Cancel)
}
function Set-QaBrowseProgress { param($Progress,[string]$Message,[double]$Percent)
    if($null -ne $Progress){$Progress.Message=$Message;$Progress.Percent=$Percent}
}
function Test-QaBrowseWithin { param([string]$Path,[string]$Parent)
    $pathFull=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $parentFull=[IO.Path]::GetFullPath($Parent).TrimEnd('\','/')
    return ($pathFull.Equals($parentFull,[StringComparison]::OrdinalIgnoreCase) -or $pathFull.StartsWith($parentFull+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))
}
function Assert-QaBrowseNoLink { param([string]$Path)
    $current=[IO.Path]::GetFullPath($Path)
    while($current) {
        if([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            if(([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A linked file or folder was found. Choose direct local folders for browsing copies.'}
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if($parent -eq $current){break};$current=$parent
    }
}
function Close-QaBrowseHandle { param($Handle)
    if($null -ne $Handle){try{$Handle.Dispose()}catch{}}
}
function Get-QaBrowseHash { param([string]$Path)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')}finally{Close-QaBrowseHandle $stream;Close-QaBrowseHandle $sha}
}
function Get-QaBrowseTicks { param($Value)
    if($Value -is [datetime]){return $Value.ToUniversalTime().Ticks}
    if($Value -is [datetimeoffset]){return $Value.UtcDateTime.Ticks}
    $n=[long]0
    if([long]::TryParse([string]$Value,[ref]$n)){return $n}
    return [long]0
}
function Write-QaBrowseAtomic { param([string]$Path,$Object)
    Assert-QaBrowseNoLink $Path;Assert-QaBrowseNoLink ($Path+'.bak')
    $parent=[IO.Path]::GetDirectoryName($Path)
    [void][IO.Directory]::CreateDirectory($parent)
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($Object|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($true)))
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,$Path+'.bak')}else{[IO.File]::Move($temporary,$Path)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Get-QaBrowsePaths { param($Config)
    if([string]::IsNullOrWhiteSpace([string]$Config.ArchiveRoot) -or -not [IO.Path]::IsPathRooted([string]$Config.ArchiveRoot)){throw 'Choose an absolute local archive folder.'}
    $root=[IO.Path]::GetFullPath([string]$Config.ArchiveRoot)
    if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        if($root.StartsWith('\\')){throw 'The archive and browsing copies must be on a local disk or USB drive.'}
        $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($root))
        if($drive.DriveType -eq [IO.DriveType]::Network){throw 'The archive and browsing copies must be on a local disk or USB drive.'}
    }
    foreach($source in @($Config.Sources)) {
        $sourcePath=[string]$source.Path
        if(Test-QaBrowseWithin $root $sourcePath){throw 'The scanner source folders are read-only; the archive cannot be inside one.'}
        if(Test-QaBrowseWithin $sourcePath $root){throw 'Scanner sources and the archive must be separate folders.'}
        # Local synthetic and local-source folders must not alias the archive through links.
        # UNC scanner folders are never probed by a browsing refresh.
        $probeLocalSource=(-not $sourcePath.StartsWith('\\'))
        if($probeLocalSource -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $sourceDrive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($sourcePath)))
            if($sourceDrive.DriveType -eq [IO.DriveType]::Network){$probeLocalSource=$false}
        }
        if($probeLocalSource){Assert-QaBrowseNoLink $sourcePath}
    }
    $meta=Join-Path $root '.ctqa'
    return [pscustomobject]@{Root=$root;Browse=(Join-Path $root 'Browse Reports');Reports=(Join-Path $root 'Reports');Meta=$meta;State=(Join-Path $meta 'state.json');Lock=(Join-Path $meta 'archive.lock');Ledger=(Join-Path $meta 'browse.json');Transactions=(Join-Path $meta 'browse-transactions');Staging=(Join-Path $meta 'browse-staging');History=(Join-Path $meta 'browse-history')}
}
function Get-QaBrowseScanner { param([string]$Scanner,[string]$Name='')
    if(-not [string]::IsNullOrWhiteSpace($Name)){return $Name.Trim()}
    switch($Scanner){'CT_Edge'{'CT Edge'}'CT_Flash'{'CT Flash'}'MDP_Building'{'MDP Building'}default{$Scanner.Replace('_',' ')}}
}
function ConvertTo-QaBrowsePathLabel { param([string]$Text)
    $safe=($Text -replace '[<>:"/\\|?*\x00-\x1f]','-').Trim().TrimEnd('.',' ')
    if($safe.Length -gt 32){$safe=$safe.Substring(0,32).TrimEnd('.',' ')}
    if(-not $safe -or $safe -in @('.','..')){$safe='Scanner'}
    if($safe -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)'){$safe='Scanner '+$safe}
    return $safe
}
function Get-QaBrowseCategory { param([string]$Category)
    switch($Category){'Daily_QA'{'Daily QA'}'Monthly_QA'{'Monthly QA - Confirmed'}'Monthly_QA/Pending_Verification'{'Monthly QA - Pending Verification'}'Acceptance_Tests'{'Acceptance Tests'}'Needs_Review'{'Needs Review'}default{throw 'Unknown QA category in browsing record.'}}
}
function Get-QaBrowseCategoryFolder { param([string]$Category)
    switch($Category) {
        'Daily_QA' {'Daily QA'}
        'Monthly_QA' {Join-Path 'Monthly QA' 'Confirmed'}
        'Monthly_QA/Pending_Verification' {Join-Path 'Monthly QA' 'Pending Verification'}
        'Acceptance_Tests' {Join-Path 'Other Reports' 'Acceptance Tests'}
        'Needs_Review' {Join-Path 'Other Reports' 'Needs Review'}
        default {throw 'Unknown QA category in browsing record.'}
    }
}
function Get-QaBrowseBase { param($Record)
    $scanner=[string](Get-QaBrowseValue $Record 'ScannerPathLabel')
    if(-not $scanner){$scanner=ConvertTo-QaBrowsePathLabel (Get-QaBrowseScanner ([string]$Record.Scanner) ([string](Get-QaBrowseValue $Record 'ScannerName')))}
    $category=Get-QaBrowseCategory ([string]$Record.Category)
    if($Record.Category -eq 'Monthly_QA' -and (-not(Get-QaBrowseValue $Record 'ConfirmedBy') -or -not(Get-QaBrowseValue $Record 'ConfirmedAt'))){throw 'A Monthly report lacks reviewed confirmation evidence. Review its classification before creating a browsing copy.'}
    $date=[datetime]::MinValue;$valid=[datetime]::TryParseExact([string]$Record.ReportDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)
    $year=if($valid){$date.ToString('yyyy')}else{'Unknown Date'}
    $month=if($valid){$date.ToString('MM MMMM',[Globalization.CultureInfo]::InvariantCulture)}else{'Needs Review'}
    $dateText=if($valid){$date.ToString('yyyy-MM-dd')}else{'Undated'}
    $time=if([string]$Record.ReportTime -match '^\d{2}:\d{2}:\d{2}$'){([string]$Record.ReportTime).Replace(':','-')}else{'Time unknown'}
    $folder=Join-Path (Join-Path (Join-Path $scanner $year) $month) (Get-QaBrowseCategoryFolder ([string]$Record.Category))
    $original=ConvertTo-QaBrowsePathLabel ([IO.Path]::GetFileNameWithoutExtension([string]$Record.OriginalFileName))
    return [pscustomobject]@{Folder=$folder;Name=($dateText+' - '+$time+' - '+$original+' - '+$category)}
}
function Get-QaBrowseTarget { param($Record,$Existing,$Used,[string]$BrowseRoot='')
    $base=Get-QaBrowseBase $Record
    if($null -ne $Existing -and [string]$Existing.Category -eq [string]$Record.Category) {
        $prior=[string]$Existing.RelativePath
        if([IO.Path]::GetDirectoryName($prior).Equals($base.Folder,[StringComparison]::OrdinalIgnoreCase)) {
            $Used[$prior]=[string]$Record.Id;return $prior
        }
    }
    $relative=Join-Path $base.Folder ($base.Name+'.pdf');$counter=2
    if($BrowseRoot -and (Join-Path $BrowseRoot $relative).Length -gt 245){
        $base.Name=([string]$Record.ReportDate)+'_'+(([string]$Record.ReportTime).Replace(':','-'))+'_'+([string]$Record.Id).Substring(0,10)
        $relative=Join-Path $base.Folder ($base.Name+'.pdf')
    }
    while($Used.ContainsKey($relative) -and $Used[$relative] -ne [string]$Record.Id){$relative=Join-Path $base.Folder ($base.Name+' - Report '+$counter+'.pdf');$counter++}
    # A collision suffix may push an otherwise valid name over the Windows limit.
    if($BrowseRoot -and (Join-Path $BrowseRoot $relative).Length -gt 245){
        $short=([string]$Record.ReportDate)+'_'+(([string]$Record.ReportTime).Replace(':','-'))+'_'+([string]$Record.Id).Substring(0,16)+'.pdf'
        $relative=Join-Path $base.Folder $short
        if($Used.ContainsKey($relative) -and $Used[$relative] -ne [string]$Record.Id){throw 'A compact browsing name collided. Original files were preserved.'}
    }
    $Used[$relative]=[string]$Record.Id;return $relative
}
function Assert-QaBrowseRelative { param([string]$Relative,[string]$Parent)
    if(-not $Relative -or [IO.Path]::IsPathRooted($Relative)){throw 'The browsing ledger contains an unsafe relative path.'}
    $full=Join-Path $Parent $Relative
    if(-not(Test-QaBrowseWithin $full $Parent) -or [IO.Path]::GetFullPath($full).Equals([IO.Path]::GetFullPath($Parent),[StringComparison]::OrdinalIgnoreCase)){throw 'The browsing path points outside its managed folder.'}
    Assert-QaBrowseNoLink $full
    return $full
}
function Read-QaBrowseLedger { param($Paths)
    if(-not [IO.File]::Exists($Paths.Ledger)){return [pscustomobject]@{Version=1;UpdatedUtc='';Records=@();Retired=@()}}
    Assert-QaBrowseNoLink $Paths.Ledger
    try{$ledger=[IO.File]::ReadAllText($Paths.Ledger)|ConvertFrom-Json}catch{throw 'The browsing-copy ledger could not be read. It was preserved; do not remove it or reuse the folder until IT reviews it.'}
    if([int]$ledger.Version -ne 1){throw 'This browsing-copy ledger version is not supported.'}
    $ids=@{};$destinations=@{}
    foreach($record in @($ledger.Records)) {
        if([string]$record.ReportId -notmatch '^[0-9A-Fa-f]{64}$' -or [string]$record.Hash -notmatch '^[0-9A-Fa-f]{64}$' -or $ids.ContainsKey([string]$record.ReportId)){throw 'The browsing ledger contains invalid or repeated report identities.'}
        $full=Assert-QaBrowseRelative ([string]$record.RelativePath) $Paths.Browse
        if($destinations.ContainsKey($full)){throw 'Two browsing ledger records point to the same file.'}
        $ids[[string]$record.ReportId]=$true;$destinations[$full]=$true
    }
    foreach($record in @($ledger.Retired)) {
        if([string]$record.ReportId -notmatch '^[0-9A-Fa-f]{64}$' -or [string]$record.Hash -notmatch '^[0-9A-Fa-f]{64}$'){throw 'The browsing ledger contains an invalid historical report identity.'}
        [void](Assert-QaBrowseRelative ([string]$record.RelativePath) $Paths.Browse)
        $history=[string](Get-QaBrowseValue $record 'HistoryRelativePath')
        if($history){[void](Assert-QaBrowseRelative $history $Paths.History)}
    }
    return $ledger
}
function Add-QaBrowseCommitted { param($Ledger,$Record,$Previous=$null)
    if($null -ne $Previous -and $Previous.RelativePath -ne $Record.RelativePath) {
        if(@($Ledger.Retired|Where-Object{$_.ReportId -eq $Previous.ReportId -and $_.RelativePath -eq $Previous.RelativePath -and $_.Hash -eq $Previous.Hash}).Count -eq 0){
            $retired=$Previous|Select-Object *
            $retired|Add-Member -NotePropertyName HistoryRelativePath -NotePropertyValue '' -Force
            $Ledger.Retired=@($Ledger.Retired)+@($retired)
        }
    }
    $Ledger.Records=@($Ledger.Records|Where-Object{$_.ReportId -ne $Record.ReportId})+@($Record)
}
function Save-QaBrowseLedger { param($Ledger,$Paths)
    $Ledger.UpdatedUtc=[datetime]::UtcNow.ToString('o');Write-QaBrowseAtomic $Paths.Ledger $Ledger
    foreach($file in [IO.Directory]::GetFiles($Paths.Transactions,'*.json')) {
        try {
            Assert-QaBrowseNoLink $file;$tx=[IO.File]::ReadAllText($file)|ConvertFrom-Json
            $committed=@($Ledger.Records|Where-Object{$_.ReportId -eq $tx.Record.ReportId -and $_.Hash -eq $tx.Record.Hash -and $_.RelativePath -eq $tx.Record.RelativePath})
            if($committed.Count -eq 1) {
                $target=Assert-QaBrowseRelative ([string]$committed[0].RelativePath) $Paths.Browse
                if([IO.File]::Exists($target) -and (Get-QaBrowseHash $target) -eq $committed[0].Hash){[IO.File]::Delete($file)}
            }
        }catch{}
    }
}
function Restore-QaBrowseTransactions { param($Ledger,$Paths,$Issues)
    foreach($file in [IO.Directory]::GetFiles($Paths.Transactions,'*.json')) {
        try {
            Assert-QaBrowseNoLink $file;$tx=[IO.File]::ReadAllText($file)|ConvertFrom-Json;$record=$tx.Record
            if([string]$record.ReportId -notmatch '^[0-9A-Fa-f]{64}$' -or [string]$record.Hash -notmatch '^[0-9A-Fa-f]{64}$'){throw 'Invalid browsing recovery identity.'}
            $target=Assert-QaBrowseRelative ([string]$record.RelativePath) $Paths.Browse
            $stage=Join-Path $Paths.Staging ([IO.Path]::GetFileName([string]$tx.StageName));Assert-QaBrowseNoLink $stage
            if([IO.File]::Exists($target) -and [IO.File]::Exists($stage) -and @($Ledger.Records|Where-Object{$_.ReportId -eq $record.ReportId -and $_.RelativePath -eq $record.RelativePath -and $_.Hash -eq $record.Hash}).Count -eq 0){throw 'A browsing destination appeared before installation. It is not owned by this ledger and was preserved.'}
            if(-not [IO.File]::Exists($target)) {
                if(-not [IO.File]::Exists($stage) -or (Get-QaBrowseHash $stage) -ne $record.Hash){throw 'An interrupted browsing transfer is incomplete. It was not indexed.'}
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));[IO.File]::Move($stage,$target)
            }
            if((Get-QaBrowseHash $target) -ne $record.Hash){throw 'A browsing recovery target has different bytes. It was preserved.'}
            $record.DestinationWriteTicks=[string](Get-Item -LiteralPath $target).LastWriteTimeUtc.Ticks
            Add-QaBrowseCommitted $Ledger $record (Get-QaBrowseValue $tx 'Previous' $null)
        }catch{[void]$Issues.Add([pscustomobject]@{ReportId='';Message=('Interrupted browsing transfer needs attention. '+$_.Exception.Message);Path=$file})}
    }
}
function Move-QaBrowseRetired { param($Ledger,$Paths,$Issues)
    $changed=$false
    foreach($record in @($Ledger.Retired)) {
        $previous=''
        try {
            if(Get-QaBrowseValue $record 'HistoryRelativePath'){continue}
            $previous=Assert-QaBrowseRelative ([string]$record.RelativePath) $Paths.Browse
            if(@($Ledger.Records|Where-Object{$_.RelativePath -eq $record.RelativePath}).Count -gt 0){continue}
            if(-not [IO.File]::Exists($previous)){continue}
            $current=@($Ledger.Records|Where-Object{$_.ReportId -eq $record.ReportId}|Select-Object -First 1)
            if($current.Count -ne 1){continue}
            $replacement=Assert-QaBrowseRelative ([string]$current[0].RelativePath) $Paths.Browse
            if(-not [IO.File]::Exists($replacement) -or (Get-QaBrowseHash $replacement) -ne $current[0].Hash){continue}
            if((Get-QaBrowseHash $previous) -ne $record.Hash){throw 'The former browsing copy was edited. It was preserved in place.'}
            $historyRelative=Join-Path ([string]$record.ReportId).Substring(0,16) ((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.pdf')
            $history=Assert-QaBrowseRelative $historyRelative $Paths.History
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($history));[IO.File]::Move($previous,$history)
            $record.HistoryRelativePath=$historyRelative;$changed=$true
        }catch{[void]$Issues.Add([pscustomobject]@{ReportId=$record.ReportId;Message=('A former browsing copy was kept in place. '+$_.Exception.Message);Path=$previous})}
    }
    return $changed
}
function Copy-QaBrowseReport { param($Record,[string]$Relative,$Existing,$Ledger,$Paths,$Progress,$Summary)
    $source=[IO.Path]::GetFullPath([string]$Record.DestinationPath)
    if(-not(Test-QaBrowseWithin $source $Paths.Reports) -or $source.Equals([IO.Path]::GetFullPath($Paths.Reports),[StringComparison]::OrdinalIgnoreCase)){throw 'The archived report path is outside Reports.'}
    Assert-QaBrowseNoLink $source
    if(-not [IO.File]::Exists($source)){throw 'The archived PDF is missing. Run Update Reports or the integrity audit.'}
    $target=Assert-QaBrowseRelative $Relative $Paths.Browse
    if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $target.Length -gt 245){throw 'The browsing path is too long. Choose a shorter archive location.'}
    $sourceInfo=Get-Item -LiteralPath $source -ErrorAction Stop
    if($sourceInfo.Length -ne [long]$Record.Length){throw 'The archived PDF size differs from its index. Run the integrity audit.'}
    $owned=($null -ne $Existing -and [string]$Existing.RelativePath -eq $Relative -and [string]$Existing.ReportId -eq [string]$Record.Id)
    if([IO.File]::Exists($target)) {
        if(-not $owned){throw 'A file already uses this browsing name and is not owned by the browsing ledger. It was preserved.'}
        $targetInfo=Get-Item -LiteralPath $target -ErrorAction Stop
        if([string]$Existing.Hash -eq [string]$Record.Hash -and $targetInfo.Length -eq [long]$Existing.Length -and $targetInfo.LastWriteTimeUtc.Ticks -eq (Get-QaBrowseTicks $Existing.DestinationWriteTicks) -and $sourceInfo.LastWriteTimeUtc.Ticks -eq (Get-QaBrowseTicks $Existing.SourceWriteTicks)){$Summary.Unchanged++;return}
        # Metadata changed: inspect bytes before trusting or touching the user's copy.
        if((Get-QaBrowseHash $target) -ne $Existing.Hash){throw 'The browsing PDF was edited. It was preserved; choose a different file location or ask IT to review it.'}
        if($Existing.Hash -ne $Record.Hash){throw 'The browsing target belongs to a different archived version. It was preserved.'}
        if((Get-QaBrowseHash $source) -ne $Record.Hash){throw 'The archived PDF failed its indexed SHA-256 check. No browsing copy was changed.'}
        $Existing.DestinationWriteTicks=[string]$targetInfo.LastWriteTimeUtc.Ticks;$Existing.SourceWriteTicks=[string]$sourceInfo.LastWriteTimeUtc.Ticks;$Summary.Verified++;return
    }
    $token=[guid]::NewGuid().ToString('N');$stage=Join-Path $Paths.Staging ($token+'.partial');$txPath=Join-Path $Paths.Transactions ($token+'.json')
    $input=$null;$output=$null;$sha=$null
    try {
        Assert-QaBrowseNoLink $stage
        $input=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $output=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $sha=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] 1048576
        while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0) {
            if(Test-QaBrowseCancelled $Progress){throw [OperationCanceledException]::new('Browsing refresh cancelled during a transfer.')}
            $output.Write($buffer,0,$read);[void]$sha.TransformBlock($buffer,0,$read,$buffer,0)
        }
        [void]$sha.TransformFinalBlock($buffer,0,0);$hash=([BitConverter]::ToString($sha.Hash)).Replace('-','')
        $output.Flush($true);$output.Dispose();$output=$null;$input.Dispose();$input=$null;$sha.Dispose();$sha=$null
        if($hash -ne $Record.Hash -or (Get-QaBrowseHash $stage) -ne $Record.Hash){throw 'SHA-256 verification failed. The browsing copy was not installed.'}
        $fresh=Get-Item -LiteralPath $source -ErrorAction Stop
        if($fresh.Length -ne $sourceInfo.Length -or $fresh.LastWriteTimeUtc.Ticks -ne $sourceInfo.LastWriteTimeUtc.Ticks){throw 'The archived PDF changed while copying. The browsing copy was not installed.'}
        $entry=[pscustomobject]@{ReportId=[string]$Record.Id;Hash=[string]$Record.Hash;Scanner=[string]$Record.Scanner;Category=[string]$Record.Category;RelativePath=$Relative;Length=[long]$Record.Length;SourceWriteTicks=[string]$sourceInfo.LastWriteTimeUtc.Ticks;DestinationWriteTicks='';CreatedUtc=[datetime]::UtcNow.ToString('o')}
        Write-QaBrowseAtomic $txPath ([pscustomobject]@{StageName=[IO.Path]::GetFileName($stage);Record=$entry;Previous=$Existing})
        Assert-QaBrowseNoLink $target
        if([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)){throw 'A browsing destination appeared during copying. It was not overwritten.'}
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));[IO.File]::Move($stage,$target)
        $entry.DestinationWriteTicks=[string](Get-Item -LiteralPath $target).LastWriteTimeUtc.Ticks
        Add-QaBrowseCommitted $Ledger $entry $Existing;$Summary.Exported++;$Summary.Verified++
    }finally{
        Close-QaBrowseHandle $input;Close-QaBrowseHandle $output;Close-QaBrowseHandle $sha
        if([IO.File]::Exists($stage) -and -not [IO.File]::Exists($txPath)){try{[IO.File]::Delete($stage)}catch{}}
    }
}
function Invoke-QaBrowseRefresh {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Config,$Progress=$null)
    if(-not(Get-Command Get-QaDashboard -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'Archive.psm1') -ErrorAction Stop}
    $paths=Get-QaBrowsePaths $Config
    foreach($path in @($paths.Root,$paths.Browse,$paths.Reports,$paths.Meta,$paths.State,$paths.Lock,$paths.Ledger,($paths.Ledger+'.bak'),$paths.Transactions,$paths.Staging,$paths.History)){Assert-QaBrowseNoLink $path}
    if(-not [IO.File]::Exists($paths.State)){throw 'Complete First-Time Setup before creating the browsing folder.'}
    $summary=[pscustomobject]@{Total=0;Exported=0;Unchanged=0;Verified=0;Failed=0;Cancelled=$false;Description=''}
    $issues=New-Object 'System.Collections.Generic.List[object]';$lock=$null
    try {
        try{$lock=[IO.File]::Open($paths.Lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'The archive is busy or not writable. Wait for the current update or review, then refresh the browsing folder.'}
        $dashboard=Get-QaDashboard -Config $Config
        $sourceNames=@{};$pathLabels=@{}
        foreach($source in @($Config.Sources)) {
            if([string]$source.Scanner -eq 'All' -or [string]$source.Scanner -notmatch '^[A-Za-z][A-Za-z0-9_]{0,31}$'){throw 'A configured scanner has an invalid identifier.'}
            $sourceNames[[string]$source.Scanner]=[string]$source.Name
        }
        $pathRows=@($Config.Sources|ForEach-Object{[pscustomobject]@{Scanner=[string]$_.Scanner;Label=(ConvertTo-QaBrowsePathLabel (Get-QaBrowseScanner ([string]$_.Scanner) ([string]$_.Name)))}})
        foreach($item in $pathRows){$pathLabels[$item.Scanner]=$item.Label}
        # A fallback ID can itself equal another scanner's chosen display label.
        # Resolve globally until every folder label is unique. Safe configured IDs
        # are unique, so each pass fixes at least one additional source permanently.
        for($pass=0;$pass -le $pathRows.Count;$pass++) {
            $resolved=@($pathRows|ForEach-Object{[pscustomobject]@{Scanner=$_.Scanner;Label=$pathLabels[$_.Scanner]}})
            $collisions=@($resolved|Group-Object Label|Where-Object{$_.Count -gt 1})
            if($collisions.Count -eq 0){break}
            foreach($group in $collisions){foreach($item in $group.Group){$pathLabels[$item.Scanner]=$item.Scanner}}
            if($pass -eq $pathRows.Count){throw 'Scanner folder labels could not be made unique. Review the scanner names.'}
        }
        $displayRecords=New-Object 'System.Collections.Generic.List[object]'
        foreach($record in @($dashboard.Records)) {
            if(-not $sourceNames.ContainsKey([string]$record.Scanner)){throw 'The archive contains an unconfigured scanner identifier.'}
            $display=$record|Select-Object *
            $display|Add-Member -NotePropertyName ScannerName -NotePropertyValue $sourceNames[[string]$record.Scanner] -Force
            $display|Add-Member -NotePropertyName ScannerPathLabel -NotePropertyValue $pathLabels[[string]$record.Scanner] -Force
            [void]$displayRecords.Add($display)
        }
        $ledger=Read-QaBrowseLedger $paths
        foreach($dir in @($paths.Browse,$paths.Transactions,$paths.Staging,$paths.History)){[void][IO.Directory]::CreateDirectory($dir)}
        Restore-QaBrowseTransactions $ledger $paths $issues
        Save-QaBrowseLedger $ledger $paths
        if(Move-QaBrowseRetired $ledger $paths $issues){Save-QaBrowseLedger $ledger $paths}
        $records=@($displayRecords.ToArray()|Sort-Object ReportDate,ReportTime,Scanner,OriginalFileName,Id);$summary.Total=$records.Count
        $existingById=@{};$used=@{}
        foreach($entry in @($ledger.Records)){$existingById[[string]$entry.ReportId]=$entry;$used[[string]$entry.RelativePath]=[string]$entry.ReportId}
        $n=0
        foreach($record in $records) {
            if(Test-QaBrowseCancelled $Progress){$summary.Cancelled=$true;break}
            $n++;Set-QaBrowseProgress $Progress ('Refreshing readable report '+$n+' of '+$records.Count) (100*$n/[math]::Max(1,$records.Count))
            $existing=$null;if($existingById.ContainsKey([string]$record.Id)){$existing=$existingById[[string]$record.Id]}
            try {
                $relative=Get-QaBrowseTarget $record $existing $used $paths.Browse
                Copy-QaBrowseReport $record $relative $existing $ledger $paths $Progress $summary
            }catch{
                if(Test-QaBrowseCancelled $Progress){$summary.Cancelled=$true;break}
                $summary.Failed++;[void]$issues.Add([pscustomobject]@{ReportId=$record.Id;Message=([string]$record.OriginalFileName+': '+$_.Exception.Message);Path=[string]$record.DestinationPath})
            }
        }
        if(Test-QaBrowseCancelled $Progress){$summary.Cancelled=$true}
        # Commit ownership before moving any prior, ledger-owned category copies.
        Save-QaBrowseLedger $ledger $paths
        if(Move-QaBrowseRetired $ledger $paths $issues){Save-QaBrowseLedger $ledger $paths}
        $summary.Failed=[math]::Max([int]$summary.Failed,$issues.Count)
        $summary.Description=($summary.Exported.ToString()+' readable copies created; '+$summary.Unchanged+' unchanged; '+$summary.Failed+' need attention.')
        if($summary.Cancelled){$summary.Description='Browsing refresh cancelled safely. Verified copies are preserved; refresh again to continue.'}
        elseif($summary.Failed -gt 0){$summary.Description+=' '+$issues[0].Message}
        Import-Module (Join-Path $PSScriptRoot 'Navigator.psm1')
        Write-QaNavigator -Paths $paths -Ledger $ledger -Records @($displayRecords.ToArray()) -Summary $summary
        Set-QaBrowseProgress $Progress $summary.Description 100
        return [pscustomobject]@{Mode='BrowseRefresh';DestinationPath=$paths.Browse;Summary=$summary;Issues=@($issues.ToArray())}
    }finally{Close-QaBrowseHandle $lock}
}
Export-ModuleMember -Function Invoke-QaBrowseRefresh
