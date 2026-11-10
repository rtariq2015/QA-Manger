# CT QA Manager Pro archive engine. Windows PowerShell 5.1, no external modules.
# Only reads scanner sources. Archive transactions never overwrite existing PDFs.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:QaCategories = @('Daily_QA','Monthly_QA','Monthly_QA/Pending_Verification','Acceptance_Tests','Needs_Review')

function Get-QaValue {
    param($Object,[string]$Name,$Default='')
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Set-QaValue { param($Object,[string]$Name,$Value)
    if ($Object -is [System.Collections.IDictionary]) { $Object[$Name]=$Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}
function Get-QaComponentLabels {
    param($Values,[string]$Context='Monthly checklist')
    $labels=New-Object 'System.Collections.Generic.List[string]';$seen=@{}
    foreach($value in @($Values)) {
        if($null -eq $value){continue}
        if($value -isnot [string]){throw ($Context+' must contain text labels only.')}
        $label=([string]$value).Trim()
        if([string]::IsNullOrWhiteSpace($label) -or $label.Length -gt 80 -or $label -match '[\x00-\x1f;]' -or $label -match '^[=+@]'){throw ($Context+' labels must be 1 through 80 characters, without control characters or semicolons.')}
        if($seen.ContainsKey($label)){throw ($Context+' contains a repeated item: '+$label)}
        $seen[$label]=$true;[void]$labels.Add($label)
        if($labels.Count -gt 32){throw ($Context+' may contain at most 32 items.')}
    }
    return @($labels.ToArray())
}
function Get-QaHashText { param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','') }
    finally { $sha.Dispose() }
}
function Get-QaFileHash { param([string]$Path)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') }
    finally { $stream.Dispose(); $sha.Dispose() }
}
function Get-QaTimestampTicks { param($Value)
    # PowerShell JSON readers differ: Windows 5.1 may retain ISO strings while
    # newer runtimes deserialize them as DateTime. Compare UTC ticks, never a
    # culture-dependent string cast of a deserialized timestamp.
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().Ticks }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.Ticks }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return [long]0 }
    $parsed=[datetime]::MinValue
    if ([datetime]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)) { return $parsed.ToUniversalTime().Ticks }
    return [long]0
}
function Get-QaSourceKey { param([string]$Scanner,[string]$SourcePath)
    return Get-QaHashText ($Scanner+'|'+$SourcePath.ToUpperInvariant())
}
function Write-QaAtomicText { param([string]$Path,[string]$Text)
    Assert-QaNoReparse $Path
    Assert-QaNoReparse ($Path+'.bak')
    $parent=[IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $encoding=New-Object Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($temp,$Text,$encoding)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,$Path+'.bak') }
        else { [IO.File]::Move($temp,$Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Get-QaDefaultConfig {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$AppRoot)
    [pscustomobject]@{
        Version=4; AppRoot=[IO.Path]::GetFullPath($AppRoot); ArchiveRoot=[IO.Path]::GetFullPath($AppRoot)
        LookbackDays=60; MonthlyLookbackMonths=12; MinimumFileAgeSeconds=120; SetupComplete=$false; AutoUpdateOnOpen=$true
        Sources=@(
            [pscustomobject]@{Scanner='CT_Edge';Name='CT Edge';Path='\\CT-EDGE\Reports\ConstancyReports';DriveLetter='K';DailySchedule='AllDays';ExpectedMonthly=$true;ActiveFrom='';MonthlyThresholdKB=70;Username='SCANNER_USERNAME';PreviousPaths=@();MonthlyChecklist=@()},
            [pscustomobject]@{Scanner='CT_Flash';Name='CT Flash';Path='\\CT-FLASH\Reports\ConstancyReports';DriveLetter='J';DailySchedule='AllDays';ExpectedMonthly=$true;ActiveFrom='';MonthlyThresholdKB=85;Username='SCANNER_USERNAME';PreviousPaths=@();MonthlyChecklist=@()},
            [pscustomobject]@{Scanner='MDP_Building';Name='MDP Building';Path='\\MDP-SCANNER\Reports\ConstancyReports';DriveLetter='Y';DailySchedule='AllDays';ExpectedMonthly=$true;ActiveFrom='';MonthlyThresholdKB=85;Username='SCANNER_USERNAME';PreviousPaths=@();MonthlyChecklist=@()}
        )
    }
}
function Assert-QaConfig { param($Config)
    if ([string]::IsNullOrWhiteSpace([string]$Config.ArchiveRoot) -or -not [IO.Path]::IsPathRooted([string]$Config.ArchiveRoot)) { throw 'Choose an absolute archive folder path.' }
    # A mapped scanner drive can alias a UNC source despite different path text.
    # Restrict managed archives to local disks so no archive write can land on a scanner share.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $archiveFull=[IO.Path]::GetFullPath([string]$Config.ArchiveRoot)
        if ($archiveFull.StartsWith('\\')) { throw 'Choose a local archive folder on this workstation, not a network share or mapped scanner drive.' }
        $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($archiveFull))
        if ($drive.DriveType -eq [IO.DriveType]::Network) { throw 'Choose a local archive folder. Network and mapped scanner drives are read-only sources.' }
    }
    $interval=[int](Get-QaValue $Config 'MonitorMinutes' 15)
    if($interval -ne 0 -and ($interval -lt 5 -or $interval -gt 240)){throw 'Check interval must be 0, or 5 through 240 minutes.'}
    if($null -ne $Config.PSObject.Properties['AutoUpdateOnOpen'] -and $Config.AutoUpdateOnOpen -isnot [bool]){throw 'Update on opening must be enabled or disabled.'}
    if (@($Config.Sources).Count -lt 1 -or @($Config.Sources).Count -gt 20) { throw 'Configure between 1 and 20 scanner connections.' }
    $ids=@{};$names=@{};$letters=@{};$sourcePaths=@{}
    foreach($s in $Config.Sources) {
        if ([string]$s.Scanner -notmatch '^[A-Za-z][A-Za-z0-9_]{0,31}$' -or [string]$s.Scanner -match '^(All|CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$' -or $ids.ContainsKey([string]$s.Scanner)) { throw 'Scanner identifiers must be unique, safe letters, numbers or underscores; existing identifiers cannot be changed.' }
        $ids[[string]$s.Scanner]=$true
        [void]@(Get-QaComponentLabels (Get-QaValue $s 'MonthlyChecklist' $null) ('Monthly checklist for '+$s.Name))
        $displayName=([string]$s.Name).Trim()
        if ([string]::IsNullOrWhiteSpace($displayName) -or $displayName.Length -gt 64 -or $displayName -match '[\x00-\x1f]' -or $names.ContainsKey($displayName)) { throw 'Give each scanner a different display name of 1 through 64 characters.' }
        $names[$displayName]=$true
        $due=[int](Get-QaValue $s 'MonthlyDueDay' 0);if($due -lt 0 -or $due -gt 31){throw 'Monthly due day must be 0 through 31.'}
        foreach($exception in @(Get-QaValue $s 'ExcludedDates' @())){$day=[datetime]::MinValue;if(-not [datetime]::TryParseExact([string]$exception,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$day)){throw 'Daily exceptions must use yyyy-MM-dd.'}}
        $username=[string](Get-QaValue $s 'Username' 'SCANNER_USERNAME')
        if ($username.Length -gt 256 -or $username -match '[\x00-\x1f]') { throw 'The scanner username contains unsupported characters or is too long.' }
        if ([string]::IsNullOrWhiteSpace([string]$s.Path) -or -not [IO.Path]::IsPathRooted([string]$s.Path)) { throw ('Choose an absolute source folder for '+$s.Name+'.') }
        if ($s.DailySchedule -notin @('AllDays','Weekdays','Off')) { throw ('Invalid daily schedule for '+$s.Name+'.') }
        if ([double]$s.MonthlyThresholdKB -lt 1 -or [double]$s.MonthlyThresholdKB -gt 10000) { throw 'Monthly candidate thresholds must be between 1 and 10000 KB.' }
        if ([string]$s.DriveLetter -notmatch '^[D-Z]$' -or $letters.ContainsKey([string]$s.DriveLetter)) { throw 'Choose a different preferred drive letter D through Z for each scanner.' }
        $letters[[string]$s.DriveLetter]=$true
        if ($s.ActiveFrom) { $date=[datetime]::MinValue; if (-not [datetime]::TryParseExact([string]$s.ActiveFrom,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)) { throw 'Active from dates must use yyyy-MM-dd.' } }
        $source=[IO.Path]::GetFullPath([string]$s.Path).TrimEnd('\','/')
        if ($sourcePaths.ContainsKey($source)) { throw 'Each scanner must use a different reports folder. This network folder is already configured.' }
        $sourcePaths[$source]=$true
        $previousRoots=@{};$previousCount=0
        foreach ($previous in @(Get-QaValue $s 'PreviousPaths' $null)) {
            if ($null -eq $previous) { continue }
            $previousCount++
            if ($previousCount -gt 50 -or [string]::IsNullOrWhiteSpace([string]$previous) -or -not [IO.Path]::IsPathRooted([string]$previous)) { throw 'Previous scanner folders must be full paths; keep at most 50 previous addresses for a scanner.' }
            $previousRoot=[IO.Path]::GetFullPath([string]$previous).TrimEnd('\','/')
            if ($previousRoots.ContainsKey($previousRoot)) { throw 'A previous scanner folder is repeated in settings.' }
            $previousRoots[$previousRoot]=$true
        }
        $archive=[IO.Path]::GetFullPath([string]$Config.ArchiveRoot).TrimEnd('\','/')
        if ($archive.Equals($source,[StringComparison]::OrdinalIgnoreCase) -or $archive.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $source.StartsWith($archive+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Scanner sources and the archive must be separate folders; neither may contain the other.' }
    }
    if ([int]$Config.LookbackDays -lt 1 -or [int]$Config.LookbackDays -gt 730) { throw 'Daily review window must be 1 through 730 days.' }
    if ([int]$Config.MonthlyLookbackMonths -lt 1 -or [int]$Config.MonthlyLookbackMonths -gt 36) { throw 'Monthly review window must be 1 through 36 months.' }
    if ([int]$Config.MinimumFileAgeSeconds -lt 0 -or [int]$Config.MinimumFileAgeSeconds -gt 3600) { throw 'File settling time must be 0 through 3600 seconds.' }
}
function Read-QaConfig {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$AppRoot)
    $path=Join-Path (Join-Path $AppRoot 'Config') 'Settings.json'
    $local=Join-Path (Join-Path $AppRoot 'Config') 'Settings.local.json';if([IO.File]::Exists($local)){$path=$local}
    if ([IO.File]::Exists($path)) { $c=[IO.File]::ReadAllText($path) | ConvertFrom-Json; Set-QaValue $c 'AppRoot' ([IO.Path]::GetFullPath($AppRoot)); if ([string]::IsNullOrWhiteSpace([string]$c.ArchiveRoot) -or [string]$c.ArchiveRoot -eq '.') { $c.ArchiveRoot=[IO.Path]::GetFullPath($AppRoot) } }
    else { $c=Get-QaDefaultConfig -AppRoot $AppRoot }
    if(-not [IO.Path]::IsPathRooted([string]$c.ArchiveRoot)) {
        $resolved=[IO.Path]::GetFullPath((Join-Path $AppRoot ([string]$c.ArchiveRoot)))
        if(-not $resolved.StartsWith(([IO.Path]::GetFullPath($AppRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)){throw 'A relative archive path must stay within the application folder.'}
        $c.ArchiveRoot=$resolved
    }
    foreach ($source in @($c.Sources)) { if ($null -eq $source.PSObject.Properties['Username']) { Set-QaValue $source 'Username' 'SCANNER_USERNAME' };if ($null -eq $source.PSObject.Properties['PreviousPaths']) { Set-QaValue $source 'PreviousPaths' ([object[]]@()) };if ($null -eq $source.PSObject.Properties['MonthlyChecklist']) { Set-QaValue $source 'MonthlyChecklist' ([object[]]@()) } }
    if($null -eq $c.PSObject.Properties['AutoUpdateOnOpen']){Set-QaValue $c 'AutoUpdateOnOpen' $true}
    Assert-QaConfig $c
    return $c
}
function Save-QaConfig {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$AppRoot,[Parameter(Mandatory=$true)]$Config)
    foreach ($source in @($Config.Sources)) { if ($null -eq $source.PSObject.Properties['Username']) { Set-QaValue $source 'Username' 'SCANNER_USERNAME' };if ($null -eq $source.PSObject.Properties['PreviousPaths']) { Set-QaValue $source 'PreviousPaths' ([object[]]@()) };if ($null -eq $source.PSObject.Properties['MonthlyChecklist']) { Set-QaValue $source 'MonthlyChecklist' ([object[]]@()) } }
    if($null -eq $Config.PSObject.Properties['AutoUpdateOnOpen']){Set-QaValue $Config 'AutoUpdateOnOpen' $true}
    Assert-QaConfig $Config
    $settingsPath=Join-Path (Join-Path $AppRoot 'Config') 'Settings.json'
    $local=Join-Path (Join-Path $AppRoot 'Config') 'Settings.local.json';if([IO.File]::Exists($local)){$settingsPath=$local}
    Assert-QaNoReparse $settingsPath
    $oldSources=@()
    if ([IO.File]::Exists($settingsPath)) {
        try { $previousSettings=[IO.File]::ReadAllText($settingsPath)|ConvertFrom-Json;$oldSources=@($previousSettings.Sources) }
        catch { throw 'The existing connection settings could not be read. They were not replaced; ask IT to check Settings.json.' }
    }
    foreach ($source in @($Config.Sources)) {
        $known=@{};$retained=New-Object 'System.Collections.Generic.List[string]'
        $currentRoot=[IO.Path]::GetFullPath([string]$source.Path).TrimEnd('\','/')
        foreach($root in @(Get-QaPreviousRoots $source)) { if(-not $root.Equals($currentRoot,[StringComparison]::OrdinalIgnoreCase) -and -not $known.ContainsKey($root)){$known[$root]=$true;[void]$retained.Add($root)} }
        $old=@($oldSources|Where-Object { $_.Scanner -ceq $source.Scanner }|Select-Object -First 1)
        if($old.Count -eq 1) {
            if(-not [IO.Path]::IsPathRooted([string]$old[0].Path)){throw 'A previous scanner address in settings is not a full path. No settings were replaced.'}
            $roots=@(Get-QaPreviousRoots $old[0])+@([IO.Path]::GetFullPath([string]$old[0].Path).TrimEnd('\','/'))
            foreach($root in $roots) { if(-not $root.Equals($currentRoot,[StringComparison]::OrdinalIgnoreCase) -and -not $known.ContainsKey($root)){$known[$root]=$true;[void]$retained.Add($root)} }
        }
        Set-QaValue $source 'PreviousPaths' ([object[]]$retained.ToArray())
        if($old.Count -eq 1) {
            $oldItems=@(Get-QaComponentLabels (Get-QaValue $old[0] 'MonthlyChecklist' $null))
            $newItems=@(Get-QaComponentLabels (Get-QaValue $source 'MonthlyChecklist' $null))
            $versions=@(Get-QaValue $old[0] 'MonthlyChecklistHistory' @())
            if(($oldItems -join '|') -cne ($newItems -join '|')) {
                $effective=[string](Get-QaValue $source 'ChecklistEffectiveMonth' (Get-Date).ToString('yyyy-MM'))
                $d=[datetime]::MinValue
                if(-not [datetime]::TryParseExact($effective,'yyyy-MM',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$d)){throw 'Checklist effective month must use yyyy-MM.'}
                if(-not $versions.Count){$versions=@([pscustomobject]@{EffectiveMonth='0001-01';Components=[object[]]$oldItems})}
                if(@($versions|Where-Object{$_.EffectiveMonth -ge $effective}).Count){throw 'Choose a checklist effective month after the previous version. Existing historical rules are preserved.'}
                $versions+=@([pscustomobject]@{EffectiveMonth=$effective;Components=[object[]]$newItems})
            }
            if($versions.Count){Set-QaValue $source 'MonthlyChecklistHistory' ([object[]]$versions)}
        }
    }
    Assert-QaConfig $Config
    # Validate saved report ownership before replacing settings. Removing or changing
    # an existing scanner ID must not leave the archive unusable on the next launch.
    $candidatePaths=Get-QaPaths $Config
    Assert-QaNoReparse $candidatePaths.State
    [void](Read-QaState $candidatePaths)
    Set-QaValue $Config 'AppRoot' ([IO.Path]::GetFullPath($AppRoot))
    $saved=$Config|Select-Object * -ExcludeProperty AppRoot
    if ([IO.Path]::GetFullPath([string]$Config.ArchiveRoot).TrimEnd('\','/').Equals([IO.Path]::GetFullPath($AppRoot).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)) { $saved.ArchiveRoot='.' }
    $prefix=[IO.Path]::GetFullPath($AppRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(([string]$Config.ArchiveRoot).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$saved.ArchiveRoot=([string]$Config.ArchiveRoot).Substring($prefix.Length)}
    Write-QaAtomicText $settingsPath ($saved | ConvertTo-Json -Depth 16)
    return $Config
}
function Get-QaPaths { param($Config)
    $root=[IO.Path]::GetFullPath([string]$Config.ArchiveRoot)
    $meta=Join-Path $root '.ctqa'
    return [pscustomobject]@{Root=$root;Reports=(Join-Path $root 'Reports');Meta=$meta;State=(Join-Path $meta 'state.json');Transactions=(Join-Path $meta 'transactions');Staging=(Join-Path $meta 'staging');Index=(Join-Path $root 'QA_Master_Index.csv');History=(Join-Path $root 'Activity.csv');ScannerIds=@($Config.Sources | ForEach-Object { [string]$_.Scanner })}
}
function Test-QaChildPath { param([string]$Path,[string]$Parent)
    $full=[IO.Path]::GetFullPath($Path)
    $prefix=[IO.Path]::GetFullPath($Parent).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    return $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
}
function Assert-QaNoReparse { param([string]$Path,[string]$StopAt='')
    $current=[IO.Path]::GetFullPath($Path)
    while ($current) {
        if ([IO.Directory]::Exists($current) -or [IO.File]::Exists($current)) {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'A symbolic link or junction was found in an archive path. Choose a direct folder.' }
        }
        if ($StopAt -and $current.Equals([IO.Path]::GetFullPath($StopAt),[StringComparison]::OrdinalIgnoreCase)) { break }
        $parent=[IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }; $current=$parent
    }
}
function New-QaState { return [pscustomobject]@{Version=4;SetupComplete=$false;UpdatedUtc='';Records=@();Scanners=@();Issues=@();Reviews=@()} }
function Read-QaState { param($Paths)
    if (-not [IO.File]::Exists($Paths.State)) { return New-QaState }
    try { $state=[IO.File]::ReadAllText($Paths.State) | ConvertFrom-Json }
    catch { throw 'The archive state could not be read. It has not been replaced. Keep the archive and contact IT; a previous state is in .ctqa/state.json.bak.' }
    if ([int]$state.Version -ne 4) { throw 'This archive uses an unsupported state version. No archive data was changed.' }
    foreach($record in @($state.Records)) {
        if ([string]$record.Hash -notmatch '^[0-9A-Fa-f]{64}$' -or [string]$record.Id -notmatch '^[0-9A-Fa-f]{64}$' -or -not $record.SourcePath -or [string]$record.Scanner -notmatch '^[A-Za-z][A-Za-z0-9_]{0,31}$' -or @($Paths.ScannerIds) -cnotcontains [string]$record.Scanner -or $record.Category -notin $script:QaCategories) { throw 'The archive state contains an incomplete report record; no updates were made.' }
        $relative=[string]$record.RelativePath
        if (-not $relative -or [IO.Path]::IsPathRooted($relative)) { throw 'An archive record has an unsafe relative path.' }
        $dst=Join-Path $Paths.Reports $relative
        if (-not (Test-QaChildPath $dst $Paths.Reports)) { throw 'An archive record points outside Reports; no updates were made.' }
        Assert-QaNoReparse $dst $Paths.Root
        Set-QaValue $record 'DestinationPath' $dst
        Set-QaValue $record 'ConfirmedComponents' ([object[]]@(Get-QaComponentLabels (Get-QaValue $record 'ConfirmedComponents' $null) 'Reviewed report items'))
    }
    return $state
}
function Save-QaState { param($State,$Paths)
    $State.UpdatedUtc=[datetime]::UtcNow.ToString('o')
    Write-QaAtomicText $Paths.State ($State | ConvertTo-Json -Depth 12)
    $csv=if(@($State.Records).Count -gt 0) { @($State.Records) | Select-Object Id,Scanner,ReportDate,ReportTime,Category,ClassificationBasis,OriginalFileName,SourcePath,Hash,Length,RelativePath,DestinationPath,FirstArchived,ConfirmedBy,ConfirmedAt,@{Name='ConfirmedComponents';Expression={@(Get-QaValue $_ 'ConfirmedComponents' $null) -join '; '}},PdfPagesHint | ConvertTo-Csv -NoTypeInformation } else { @('"Id","Scanner","ReportDate","ReportTime","Category","ClassificationBasis","OriginalFileName","SourcePath","Hash","Length","RelativePath","DestinationPath","FirstArchived","ConfirmedBy","ConfirmedAt","ConfirmedComponents","PdfPagesHint"') }
    Write-QaAtomicText $Paths.Index ($csv -join "`r`n")
    if ([IO.Directory]::Exists($Paths.Transactions)) {
        foreach($f in [IO.Directory]::GetFiles($Paths.Transactions,'*.json')) {
            try { $tx=[IO.File]::ReadAllText($f)|ConvertFrom-Json; $committed=@($State.Records | Where-Object {$_.Id -eq $tx.Record.Id -and $_.Hash -eq $tx.Record.Hash -and $_.RelativePath -eq $tx.Record.RelativePath})
                if ($committed.Count -eq 1 -and [IO.File]::Exists($committed[0].DestinationPath) -and (Get-QaFileHash $committed[0].DestinationPath) -eq $committed[0].Hash) { [IO.File]::Delete($f) } } catch {}
        }
    }
}
function Add-QaHistory { param($Paths,[string]$Mode,$Summary,[string]$Message)
    $row=[pscustomobject]@{TimeUtc=[datetime]::UtcNow.ToString('o');Action=$Mode;Copied=[int]$Summary.Copied;Unchanged=[int]$Summary.Unchanged;Verified=[int]$Summary.Verified;Failed=[int]$Summary.Failed;Details=$Message}
    if ([IO.File]::Exists($Paths.History)) { $row | Export-Csv -LiteralPath $Paths.History -Append -NoTypeInformation -Encoding UTF8 }
    else { $row | Export-Csv -LiteralPath $Paths.History -NoTypeInformation -Encoding UTF8 }
}
function Set-QaProgress { param($Progress,[string]$Message,[double]$Percent=-1)
    if ($null -ne $Progress) { $Progress.Message=$Message; $Progress.Percent=$Percent }
}
function Test-QaCancel { param($Progress)
    return ($null -ne $Progress -and [bool](Get-QaValue $Progress 'Cancel' $false))
}
function New-QaSummary { return [pscustomobject]@{Total=0;NewOrChanged=0;Unchanged=0;Pending=0;Deferred=0;Copied=0;Failed=0;Verified=0;Cancelled=$false;Description=''} }
function Get-QaConfigFingerprint { param($Config)
    return Get-QaHashText (($Config | Select-Object ArchiveRoot,LookbackDays,MonthlyLookbackMonths,MinimumFileAgeSeconds,Sources | ConvertTo-Json -Depth 8 -Compress))
}
function Get-QaClassification { param($Source,[string]$Name,[long]$Length,[string]$PdfHint='')
    $date='';$time='';$category='Needs_Review';$basis='Filename not recognized; review this report.'
    $m=[regex]::Match($Name,'(?i)^(?<kind>.+)_(?<date>\d{4}-\d{2}-\d{2})_(?<time>\d{2}-\d{2}-\d{2})\.pdf$')
    if ($m.Success) {
        $parsed=[datetime]::MinValue
        if ([datetime]::TryParseExact(($m.Groups['date'].Value+' '+$m.Groups['time'].Value),'yyyy-MM-dd HH-mm-ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed) -and $parsed -le (Get-Date).AddDays(1)) {
            $date=$parsed.ToString('yyyy-MM-dd');$time=$parsed.ToString('HH:mm:ss');$kind=$m.Groups['kind'].Value
            if ($kind -match '(?i)(^|_)DAILY($|_)|^(ID_)?QUALITYDAILY$') { $category='Daily_QA';$basis='Explicit Daily filename; PDF test results are not interpreted.' }
            elseif ($kind -match '(?i)(IEC|DHHS)?ACCEPTANCE') { $category='Acceptance_Tests';$basis='Acceptance filename; PDF test results are not interpreted.' }
            elseif ($kind -match '(?i)(^|_)MONTHLY($|_)|CONSTANCY_.+') { $category='Monthly_QA/Pending_Verification';$basis='Filename suggests extended or Monthly testing; authorized review required.' }
            elseif ($kind -match '(?i)^(ID_)?QUALITY_CONSTANCY$') {
                if ($Length -ge ([double]$Source.MonthlyThresholdKB*1024)) { $category='Monthly_QA/Pending_Verification';$basis=('Generic Constancy PDF is at least '+$Source.MonthlyThresholdKB+' KB; size is a candidate indicator only.') }
                else { $category='Daily_QA';$basis='Provisional Daily archive grouping from generic Constancy filename; contents are not interpreted.' }
            }
        } else { $basis='Filename date is invalid or in the future; review required.' }
    }
    if ($PdfHint -match '(?i)Monthly|MTF|Slice\s*Thickness|Light\s*Marker|Low\s*Contrast' -and $category -ne 'Acceptance_Tests') { $category='Monthly_QA/Pending_Verification';$basis='Readable PDF text suggests extended tests; this is a candidate, not confirmed Monthly QA.' }
    return [pscustomobject]@{ReportDate=$date;ReportTime=$time;Category=$category;ClassificationBasis=$basis}
}
function Get-QaPdfInfo { param([string]$Path)
    # Bounded byte inspection only: no external executable, COM, scripts or PDF rendering.
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 12) { throw 'The file is too short to be a complete PDF.' }
        $head=New-Object byte[] 5; [void]$stream.Read($head,0,5)
        if ([Text.Encoding]::ASCII.GetString($head) -ne '%PDF-') { throw 'The file does not begin with a PDF header.' }
        $tailLength=[int][math]::Min(4096,$stream.Length);[void]$stream.Seek(-$tailLength,[IO.SeekOrigin]::End)
        $tail=New-Object byte[] $tailLength;[void]$stream.Read($tail,0,$tailLength)
        if ([Text.Encoding]::ASCII.GetString($tail) -notmatch '%%EOF') { throw 'The PDF has no closing marker; it may still be transferring or be incomplete.' }
        [void]$stream.Seek(0,[IO.SeekOrigin]::Begin)
        $length=[int][math]::Min(2097152,$stream.Length);$buffer=New-Object byte[] $length;[void]$stream.Read($buffer,0,$length)
        $text=[Text.Encoding]::GetEncoding(28591).GetString($buffer)
        $pages=[regex]::Matches($text,'/Type\s*/Page\b').Count
        return [pscustomobject]@{Hint=$text;Pages=$pages}
    } finally { $stream.Dispose() }
}
function Get-QaRelativeTarget { param($Entry,[string]$Hash)
    $date=[string]$Entry.ReportDate
    $year=if($date){$date.Substring(0,4)}else{'Unknown Date'}
    $month=if($date){$date.Substring(5,2)}else{'Needs Review'}
    $parts=@([string]$Entry.Scanner,$year,$month)
    switch([string]$Entry.Category) {
        'Daily_QA' {$parts+='Daily QA'}
        'Monthly_QA' {$parts+='Monthly QA';$parts+='Confirmed'}
        'Monthly_QA/Pending_Verification' {$parts+='Monthly QA';$parts+='Pending Verification'}
        'Acceptance_Tests' {$parts+='Acceptance Tests'}
        default {$parts+='Needs Review'}
    }
    $identity=(Get-QaSourceKey $Entry.Scanner $Entry.SourcePath).Substring(0,8)+'-'+$Hash.Substring(0,12)
    $parts+=$identity
    $name=[IO.Path]::GetFileName([string]$Entry.OriginalFileName)
    if ($name -ne $Entry.OriginalFileName -or $name -match '[<>:"/\\|?*]' -or $name.EndsWith('.') -or $name.EndsWith(' ')) { throw 'The report filename is not safe for a Windows archive.' }
    $relative=$parts[0]
    for($i=1;$i -lt $parts.Count;$i++) { $relative=Join-Path $relative $parts[$i] }
    # Keep managed paths compact for Windows PowerShell 5.1. Original filenames stay in the index and readable view.
    $stamp=if($Entry.ReportDate){[string]$Entry.ReportDate}else{'Undated'}
    $time=([string]$Entry.ReportTime).Replace(':','-');if(-not $time){$time='Time-unknown'}
    return Join-Path $relative ($stamp+'_'+$time+'.pdf')
}
function New-QaIssue { param([string]$Scanner,[string]$Type,[string]$Message,[string]$Path='',[string]$RecordId='')
    return [pscustomobject]@{Id=(Get-QaHashText ($Scanner+'|'+$Type+'|'+$Message+'|'+$RecordId));Scanner=$Scanner;Type=$Type;Message=$Message;Path=$Path;RecordId=$RecordId}
}
function Get-QaInventory { param($Config,$State,$Progress,$Summary,[switch]$InWorker)
    $items=New-Object 'System.Collections.Generic.List[object]';$statuses=New-Object 'System.Collections.Generic.List[object]';$issues=New-Object 'System.Collections.Generic.List[object]'
    $cache=@{}
    foreach($r in @($State.Records)) { $key=Get-QaSourceKey $r.Scanner $r.SourcePath; $cache[$key]=$r }
    $sourceNo=0
    foreach($s in $Config.Sources) {
        if (Test-QaCancel $Progress) { $Summary.Cancelled=$true; break }
        $sourceNo++;Set-QaProgress $Progress ('Connecting to '+$s.Name+'...') (30*($sourceNo-1)/[math]::Max(1,@($Config.Sources).Count))
        $old=@($State.Scanners | Where-Object {$_.Scanner -eq $s.Scanner} | Select-Object -First 1)
        $last=if($old.Count){[string]$old[0].LastSuccessfulUpdate}else{''}
        $status=[pscustomobject]@{Scanner=$s.Scanner;Name=$s.Name;Status='Connected';Message='Scanner folder is accessible.';Count=@($State.Records|Where-Object{$_.Scanner -eq $s.Scanner}).Count;SavedReports=@($State.Records|Where-Object{$_.Scanner -eq $s.Scanner}).Count;LastSuccessfulUpdate=$last;CheckedUtc=[datetime]::UtcNow.ToString('o')}
        if(-not $InWorker -and ([string]$s.Path).StartsWith('\\')) {
            Import-Module (Join-Path $PSScriptRoot 'Process.psm1')
            try {
                $single=$Config|Select-Object *;$single.Sources=@($s)
                $snapshot=Invoke-QaIsolatedTask Inventory ([pscustomobject]@{Config=$single;State=$State}) -TimeoutSeconds 60 -Progress $Progress
                foreach($item in @($snapshot.Inventory.Items)){[void]$items.Add($item)}
                foreach($row in @($snapshot.Inventory.Scanners)){[void]$statuses.Add($row)}
                foreach($issue in @($snapshot.Inventory.Issues)){[void]$issues.Add($issue)}
                foreach($field in @('Total','Unchanged','NewOrChanged','Deferred','Pending')){$Summary.$field+=[int]$snapshot.Summary.$field}
            } catch {
                $status.Status='Unavailable';$status.Message=$_.Exception.Message
                [void]$statuses.Add($status);[void]$issues.Add((New-QaIssue $s.Scanner 'Connection' ($s.Name+' - Scanner scan timed out, was cancelled, or is unavailable.') $s.Path))
                if(Test-QaCancel $Progress){$Summary.Cancelled=$true}
            }
            continue
        }
        try {
            if(-not $InWorker -and ([string]$s.Path).StartsWith('\\')) {
                Import-Module (Join-Path $PSScriptRoot 'Process.psm1')
                if(-not (Invoke-QaIsolatedTask Probe ([pscustomobject]@{Path=$s.Path}) -TimeoutSeconds 10 -Progress $Progress)){throw 'Scanner folder is unavailable or access is denied.'}
            }
            if(([string]$s.Path).StartsWith('\\')) {
                Import-Module (Join-Path $PSScriptRoot 'Network.psm1') -DisableNameChecking
                $access=Test-QaNetworkAvailability $s
                if($access.Status -ne 'Connected'){throw [IO.IOException]::new([string]$access.Message)}
            }
            Assert-QaNoReparse ([string]$s.Path)
            if (-not [IO.Directory]::Exists([string]$s.Path)) { throw 'The scanner folder is missing, offline, or access is denied.' }
            $queue=New-Object 'System.Collections.Generic.Queue[string]';$queue.Enqueue([string]$s.Path)
            $localErrors=0
            while($queue.Count -gt 0) {
                if (Test-QaCancel $Progress) { $Summary.Cancelled=$true;break }
                $dir=$queue.Dequeue()
                try {
                    foreach($sub in [IO.Directory]::GetDirectories($dir)) {
                        if (([IO.File]::GetAttributes($sub) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $localErrors++;[void]$issues.Add((New-QaIssue $s.Scanner 'SourceFolder' ($s.Name+' - A linked source folder was skipped.') $sub));continue }
                        $queue.Enqueue($sub)
                    }
                    foreach($file in [IO.Directory]::GetFiles($dir,'*.pdf')) {
                        if (([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                        $info=Get-Item -LiteralPath $file -ErrorAction Stop
                        $cls=Get-QaClassification $s $info.Name $info.Length
                        $entry=[pscustomobject]@{Scanner=$s.Scanner;OriginalFileName=$info.Name;SourcePath=$info.FullName;Length=[long]$info.Length;SourceLastWriteUtc=$info.LastWriteTimeUtc.ToString('o');SourceWriteTicks=$info.LastWriteTimeUtc.Ticks;ReportDate=$cls.ReportDate;ReportTime=$cls.ReportTime;Category=$cls.Category;ClassificationBasis=$cls.ClassificationBasis;Action='Copy or verify';CachedRecordId=''}
                        $Summary.Total++
                        $key=Get-QaSourceKey $entry.Scanner $entry.SourcePath
                        if ($cache.ContainsKey($key)) {
                            $r=$cache[$key]
                            if ([long]$r.Length -eq $entry.Length -and (Get-QaTimestampTicks $r.SourceLastWriteUtc) -eq [long]$entry.SourceWriteTicks) {
                                try {
                                    Assert-QaNoReparse $r.DestinationPath
                                    $dst=Get-Item -LiteralPath $r.DestinationPath -ErrorAction Stop
                                    if (-not $dst.PSIsContainer -and [long]$dst.Length -eq [long]$r.Length -and $dst.LastWriteTimeUtc.Ticks -eq (Get-QaTimestampTicks (Get-QaValue $r 'DestinationLastWriteUtc'))) {
                                        $entry.Action='Unchanged';$entry.CachedRecordId=$r.Id;$entry.Category=$r.Category;$entry.ClassificationBasis=$r.ClassificationBasis;$Summary.Unchanged++
                                    }
                                } catch {}
                            }
                        }
                        if ($entry.Action -ne 'Unchanged' -and ([datetime]::UtcNow-$info.LastWriteTimeUtc).TotalSeconds -lt [int]$Config.MinimumFileAgeSeconds) { $entry.Action='Deferred';$Summary.Deferred++;[void]$issues.Add((New-QaIssue $s.Scanner 'Deferred' ($s.Name+' - A report is still settling. Update again shortly.') $entry.SourcePath)) }
                        elseif($entry.Action -ne 'Unchanged') {
                            $Summary.NewOrChanged++
                            try {
                                $pdf=Get-QaPdfInfo $entry.SourcePath
                                $analyzed=Get-QaClassification $s $entry.OriginalFileName $entry.Length $pdf.Hint
                                $entry.Category=$analyzed.Category;$entry.ClassificationBasis=$analyzed.ClassificationBasis
                            } catch {
                                $entry.Action='Invalid';$entry.Category='Needs_Review';$entry.ClassificationBasis=$_.Exception.Message
                                [void]$issues.Add((New-QaIssue $s.Scanner 'InvalidPDF' ($s.Name+' - This report could not be verified during preview: '+$entry.OriginalFileName+'. '+$_.Exception.Message) $entry.SourcePath))
                            }
                        }
                        if ($entry.Category -eq 'Monthly_QA/Pending_Verification') { $Summary.Pending++ }
                        [void]$items.Add($entry)
                    }
                } catch { $localErrors++;[void]$issues.Add((New-QaIssue $s.Scanner 'SourceFolder' ($s.Name+' - A source folder could not be fully read. '+$_.Exception.Message) $dir)) }
            }
            if ($localErrors -gt 0) { $status.Status='Partial';$status.Message='Some source folders could not be read.' }
        } catch { $status.Status='Unavailable';$status.Message=$_.Exception.Message;[void]$issues.Add((New-QaIssue $s.Scanner 'Connection' ($s.Name+' - '+$_.Exception.Message+' Archive coverage cannot establish whether source reports are missing.') $s.Path)) }
        [void]$statuses.Add($status)
    }
    foreach($s in $Config.Sources) {
        if (@($statuses|Where-Object{$_.Scanner -eq $s.Scanner}).Count -eq 0) {
            $previous=@($State.Scanners|Where-Object{$_.Scanner -eq $s.Scanner}|Select-Object -First 1)
            $last=if($previous.Count){[string]$previous[0].LastSuccessfulUpdate}else{''}
            $count=@($State.Records|Where-Object{$_.Scanner -eq $s.Scanner}).Count
            [void]$statuses.Add([pscustomobject]@{Scanner=$s.Scanner;Name=$s.Name;Status='Unknown';Message='Not checked because this run was cancelled.';Count=$count;SavedReports=$count;LastSuccessfulUpdate=$last;CheckedUtc=''})
        }
    }
    return [pscustomobject]@{Items=@($items.ToArray());Scanners=@($statuses.ToArray());Issues=@($issues.ToArray())}
}
function Add-QaRecord { param($State,$Record)
    if (@($State.Records|Where-Object{$_.Id -eq $Record.Id}).Count -eq 0) { $State.Records=@($State.Records)+@($Record) }
}
function Restore-QaTransactions { param($State,$Paths,$Issues)
    if (-not [IO.Directory]::Exists($Paths.Transactions)) { return }
    foreach($file in [IO.Directory]::GetFiles($Paths.Transactions,'*.json')) {
        try {
            Assert-QaNoReparse $file
            $tx=[IO.File]::ReadAllText($file)|ConvertFrom-Json;$r=$tx.Record
            if ($r.Hash -notmatch '^[0-9A-Fa-f]{64}$' -or [IO.Path]::IsPathRooted([string]$r.RelativePath)) { throw 'Unsafe recovery record.' }
            $target=Join-Path $Paths.Reports $r.RelativePath
            if (-not(Test-QaChildPath $target $Paths.Reports)) { throw 'Recovery destination is outside Reports.' }
            Assert-QaNoReparse $target $Paths.Root
            if (-not [IO.File]::Exists($target)) {
                $stage=Join-Path $Paths.Staging ([IO.Path]::GetFileName([string]$tx.StageName))
                Assert-QaNoReparse $stage
                if (-not [IO.File]::Exists($stage) -or (Get-QaFileHash $stage) -ne $r.Hash) { throw 'Incomplete recovery file retained for investigation; the source will be retried.' }
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));[IO.File]::Move($stage,$target)
            }
            if ((Get-QaFileHash $target) -ne $r.Hash) { throw 'Recovery destination hash differs; no data was overwritten.' }
            Set-QaValue $r 'ConfirmedComponents' ([object[]]@(Get-QaComponentLabels (Get-QaValue $r 'ConfirmedComponents' $null) 'Recovered review items'))
            $r.DestinationPath=$target;Set-QaValue $r 'DestinationLastWriteUtc' ((Get-Item -LiteralPath $target).LastWriteTimeUtc.ToString('o'))
            # The journal has a verified target and is the durable record of this transaction.
            # Replace the same identity as well (repairs and reviewed category changes).
            $State.Records=@($State.Records|Where-Object{$_.Id -ne $r.Id})+@($r)
            $review=Get-QaValue $tx 'Review' $null
            if($null -ne $review -and $review.RecordId -eq $r.Id -and $review.Hash -eq $r.Hash -and @($State.Reviews|Where-Object{$_.RecordId -eq $review.RecordId -and $_.TimeUtc -eq $review.TimeUtc}).Count -eq 0){$State.Reviews=@($State.Reviews)+@($review)}
        } catch { [void]$Issues.Add((New-QaIssue '' 'Recovery' ('Interrupted transfer needs attention. '+$_.Exception.Message) $file)) }
    }
}
function Get-QaPreviousRoots { param($Source)
    $roots=New-Object 'System.Collections.Generic.List[string]'
    foreach($value in @(Get-QaValue $Source 'PreviousPaths' $null)) {
        if ($null -eq $value) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$value) -or -not [IO.Path]::IsPathRooted([string]$value)) { throw 'Previous scanner folders must be absolute paths.' }
        [void]$roots.Add([IO.Path]::GetFullPath([string]$value).TrimEnd('\','/'))
    }
    return @($roots.ToArray())
}
function Find-QaPreviousSourceRecord { param($Entry,$Source,$State,[string]$Hash)
    # A connection edit can change the UNC root without changing the scanner or PDF.
    # Match only an explicitly retained root plus the exact relative file path and hash.
    # Previous network locations are never scanned or opened here.
    $currentRoot=[IO.Path]::GetFullPath([string]$Source.Path).TrimEnd('\','/')
    $currentPath=[IO.Path]::GetFullPath([string]$Entry.SourcePath)
    $prefix=$currentRoot+[IO.Path]::DirectorySeparatorChar
    if (-not $currentPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { return $null }
    $relative=$currentPath.Substring($prefix.Length)
    $oldPaths=@{}
    foreach($root in @(Get-QaPreviousRoots $Source)) {
        $oldPaths[[IO.Path]::GetFullPath((Join-Path $root $relative))]=$true
    }
    $matches=@($State.Records | Where-Object {
        $_.Scanner -ceq $Entry.Scanner -and $_.Hash -eq $Hash -and $oldPaths.ContainsKey([IO.Path]::GetFullPath([string]$_.SourcePath))
    })
    if ($matches.Count -gt 1) { throw 'More than one saved report matches this previous network location. No reports were merged; ask the archive administrator to review these records.' }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Copy-QaVerified { param($Entry,$Source,$State,$Paths,$Progress,$Summary)
    $before=Get-Item -LiteralPath $Entry.SourcePath -ErrorAction Stop
    if ($before.Length -ne $Entry.Length -or $before.LastWriteTimeUtc.ToString('o') -ne $Entry.SourceLastWriteUtc) { throw 'The source changed after the scan. Run Update Reports again.' }
    $pdf=Get-QaPdfInfo $Entry.SourcePath
    $class=Get-QaClassification $Source $Entry.OriginalFileName $Entry.Length $pdf.Hint
    $Entry.Category=$class.Category;$Entry.ClassificationBasis=$class.ClassificationBasis
    $token=[guid]::NewGuid().ToString('N');$stage=Join-Path $Paths.Staging ($token+'.partial');$input=$null;$output=$null;$hash=$null
    try {
        $input=[IO.File]::Open($Entry.SourcePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Paths.Root))
        if($drive.AvailableFreeSpace -lt (2*[long]$Entry.Length+104857600)){throw 'Not enough free storage for this PDF and its readable copy.'}
        $output=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $sha=[Security.Cryptography.SHA256]::Create()
        try {
            $buffer=New-Object byte[] 1048576
            while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0) {
                if (Test-QaCancel $Progress) { throw [OperationCanceledException]::new('Update cancelled. Completed reports are preserved; this partial transfer will be retried.') }
                $output.Write($buffer,0,$read);[void]$sha.TransformBlock($buffer,0,$read,$buffer,0)
            }
            [void]$sha.TransformFinalBlock($buffer,0,0);$hash=([BitConverter]::ToString($sha.Hash)).Replace('-','');$output.Flush($true)
        } finally { $sha.Dispose();$input.Dispose();$input=$null;$output.Dispose();$output=$null }
        $after=Get-Item -LiteralPath $Entry.SourcePath -ErrorAction Stop
        if ($after.Length -ne $Entry.Length -or $after.LastWriteTimeUtc.ToString('o') -ne $Entry.SourceLastWriteUtc) { throw 'The source changed during transfer. Nothing from this transfer was indexed.' }
        if ((Get-QaFileHash $stage) -ne $hash) { throw 'SHA-256 verification failed. The saved report was not committed.' }
        $id=Get-QaHashText ((Get-QaSourceKey $Entry.Scanner $Entry.SourcePath)+'|'+$hash)
        $existing=@($State.Records|Where-Object{$_.Id -eq $id}|Select-Object -First 1)
        if ($existing.Count -eq 0) {
            # A previously reassociated record keeps its immutable Id. A metadata-only
            # touch must therefore also find that exact current source path and hash.
            $sameSource=@($State.Records|Where-Object{ $_.Scanner -ceq $Entry.Scanner -and $_.Hash -eq $hash -and ([string]$_.SourcePath).Equals([string]$Entry.SourcePath,[StringComparison]::OrdinalIgnoreCase) })
            if($sameSource.Count -gt 1){throw 'Multiple archive identities match this source and hash. No records were merged.'}
            if($sameSource.Count -eq 1){$existing=$sameSource;$id=[string]$sameSource[0].Id}
            else{
                $prior=Find-QaPreviousSourceRecord $Entry $Source $State $hash
                if($null -ne $prior){$existing=@($prior);$id=[string]$prior.Id}
            }
        }
        if ($existing.Count -gt 0) {
            $r=$existing[0]
            $Entry.Category=$r.Category;$Entry.ClassificationBasis=$r.ClassificationBasis
            Assert-QaNoReparse $r.DestinationPath
            if ([IO.File]::Exists($r.DestinationPath) -and (Get-QaFileHash $r.DestinationPath) -eq $hash) {
                if(-not ([string]$r.SourcePath).Equals([string]$Entry.SourcePath,[StringComparison]::OrdinalIgnoreCase)) {
                    $history=New-Object 'System.Collections.Generic.List[string]'
                    foreach($priorPath in @(Get-QaValue $r 'SourceAliases' $null)){if($null -ne $priorPath -and -not $history.Contains([string]$priorPath)){[void]$history.Add([string]$priorPath)}}
                    if(-not $history.Contains([string]$r.SourcePath)){[void]$history.Add([string]$r.SourcePath)}
                    Set-QaValue $r 'SourceAliases' ([object[]]$history.ToArray())
                    $r.SourcePath=[string]$Entry.SourcePath;Set-QaValue $r 'SourceKey' (Get-QaSourceKey $Entry.Scanner $Entry.SourcePath)
                }
                $r.SourceLastWriteUtc=$Entry.SourceLastWriteUtc;Set-QaValue $r 'DestinationLastWriteUtc' ((Get-Item -LiteralPath $r.DestinationPath).LastWriteTimeUtc.ToString('o'));$Summary.Verified++;[IO.File]::Delete($stage);return
            }
            # Same identity can be repaired into a new verified location without overwriting damaged bytes.
            $relative=Get-QaRelativeTarget $Entry $hash
            $relative=Join-Path ([IO.Path]::GetDirectoryName($relative)) ('Recovered_'+$token.Substring(0,8)+'.pdf')
        } else { $relative=Get-QaRelativeTarget $Entry $hash }
        $target=Join-Path $Paths.Reports $relative
        if ($target.Length -gt 245 -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { throw 'The archive path is too long for Windows PowerShell 5.1. Choose a shorter archive folder.' }
        Assert-QaNoReparse $target $Paths.Root
        if ([IO.File]::Exists($target)) {
            if ((Get-QaFileHash $target) -ne $hash) { throw 'A destination collision has different bytes. It was preserved; no overwrite was attempted.' }
        }
        $record=[pscustomobject]@{Id=$id;Scanner=$Entry.Scanner;ReportDate=$Entry.ReportDate;ReportTime=$Entry.ReportTime;OriginalFileName=$Entry.OriginalFileName;SourcePath=$Entry.SourcePath;SourceKey=(Get-QaSourceKey $Entry.Scanner $Entry.SourcePath);Hash=$hash;Length=[long]$Entry.Length;SourceLastWriteUtc=$Entry.SourceLastWriteUtc;RelativePath=$relative;DestinationPath=$target;DestinationLastWriteUtc='';Category=$Entry.Category;ClassificationBasis=$Entry.ClassificationBasis;FirstArchived=[datetime]::UtcNow.ToString('o');ConfirmedBy='';ConfirmedAt='';ConfirmedComponents=@();PdfPagesHint=[int]$pdf.Pages}
        if ($existing.Count -gt 0) {
            $old=$existing[0];$record.Category=$old.Category;$record.ClassificationBasis=$old.ClassificationBasis;$record.ConfirmedBy=$old.ConfirmedBy;$record.ConfirmedAt=$old.ConfirmedAt;$record.FirstArchived=$old.FirstArchived;Set-QaValue $record 'ConfirmedComponents' ([object[]]@(Get-QaComponentLabels (Get-QaValue $old 'ConfirmedComponents' $null) 'Reviewed report items'))
            $aliasHistory=New-Object 'System.Collections.Generic.List[string]'
            foreach($priorPath in @(Get-QaValue $old 'SourceAliases' $null)){if($null -ne $priorPath -and -not $aliasHistory.Contains([string]$priorPath)){[void]$aliasHistory.Add([string]$priorPath)}}
            if(-not ([string]$old.SourcePath).Equals([string]$Entry.SourcePath,[StringComparison]::OrdinalIgnoreCase) -and -not $aliasHistory.Contains([string]$old.SourcePath)){[void]$aliasHistory.Add([string]$old.SourcePath)}
            if($aliasHistory.Count -gt 0){Set-QaValue $record 'SourceAliases' ([object[]]$aliasHistory.ToArray())}
        }
        $tx=[pscustomobject]@{StageName=[IO.Path]::GetFileName($stage);Record=$record}
        Write-QaAtomicText (Join-Path $Paths.Transactions ($token+'.json')) ($tx|ConvertTo-Json -Depth 8)
        if (-not [IO.File]::Exists($target)) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));[IO.File]::Move($stage,$target);$Summary.Copied++ }
        else { [IO.File]::Delete($stage);$Summary.Verified++ }
        $record.DestinationLastWriteUtc=(Get-Item -LiteralPath $target).LastWriteTimeUtc.ToString('o')
        if ($existing.Count -gt 0) {
            # Keep review of the exact same bytes when repairing a damaged saved copy.
            $old=$existing[0];$record.Category=$old.Category;$record.ClassificationBasis=$old.ClassificationBasis;$record.ConfirmedBy=$old.ConfirmedBy;$record.ConfirmedAt=$old.ConfirmedAt;$record.FirstArchived=$old.FirstArchived;Set-QaValue $record 'ConfirmedComponents' ([object[]]@(Get-QaComponentLabels (Get-QaValue $old 'ConfirmedComponents' $null) 'Reviewed report items'))
            $State.Records=@($State.Records|Where-Object{$_.Id -ne $id})+@($record)
        } else { Add-QaRecord $State $record }
    } finally {
        if ($null -ne $input) {$input.Dispose()};if($null -ne $output){$output.Dispose()}
        # Uncommitted partials are harmless and removed only from our private staging folder.
        if ([IO.File]::Exists($stage) -and -not [IO.File]::Exists((Join-Path $Paths.Transactions ($token+'.json')))) { [IO.File]::Delete($stage) }
    }
}
function Get-QaChecklistForMonth {
    [CmdletBinding()]param($Source,[string]$Month)
    $history=@(Get-QaValue $Source 'MonthlyChecklistHistory' @())
    if(-not $history.Count){return @(Get-QaComponentLabels (Get-QaValue $Source 'MonthlyChecklist' $null))}
    $version=@($history|Where-Object{$_.EffectiveMonth -le $Month}|Sort-Object EffectiveMonth -Descending|Select-Object -First 1)
    if($version.Count){return @(Get-QaComponentLabels $version[0].Components)}
    return @()
}
function Get-QaMonthlyCoverage {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Config,[AllowEmptyCollection()][object[]]$Records=@(),[string[]]$Months=@())
    Assert-QaConfig $Config
    if(-not $PSBoundParameters.ContainsKey('Records')){$paths=Get-QaPaths $Config;$Records=@((Read-QaState $paths).Records)}
    $explicit=$PSBoundParameters.ContainsKey('Months')
    $selectedMonths=New-Object 'System.Collections.Generic.List[string]';$seenMonths=@{}
    if($explicit) {
        foreach($value in @($Months)) {
            $monthDate=[datetime]::MinValue
            if(-not [datetime]::TryParseExact([string]$value,'yyyy-MM',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$monthDate)){throw 'Coverage months must use yyyy-MM.'}
            if(-not $seenMonths.ContainsKey([string]$value)){$seenMonths[[string]$value]=$true;[void]$selectedMonths.Add([string]$value)}
        }
    }
    $result=New-Object 'System.Collections.Generic.List[object]'
    $thisMonth=(Get-Date).Date.AddDays(1-(Get-Date).Day)
    foreach($source in @($Config.Sources)) {
        if(-not [bool]$source.ExpectedMonthly){continue}
        $rows=@($Records|Where-Object{$null -ne $_ -and $_.Scanner -ceq $source.Scanner})
        $latest=@{}
        foreach($record in $rows){
            $sourceKey=[string](Get-QaValue $record 'SourcePath' (Get-QaValue $record 'Id' ''))
            if(-not $latest.ContainsKey($sourceKey) -or (Get-QaTimestampTicks (Get-QaValue $record 'FirstArchived' '')) -ge (Get-QaTimestampTicks (Get-QaValue $latest[$sourceKey] 'FirstArchived' ''))){$latest[$sourceKey]=$record}
        }
        $rows=@($latest.Values)
        $required=@(Get-QaComponentLabels (Get-QaValue $source 'MonthlyChecklist' $null))
        $monthsToCheck=@($selectedMonths.ToArray())
        if(-not $explicit) {
            $dated=@($rows|Where-Object{[string]$_.ReportDate -match '^\d{4}-\d{2}-\d{2}$'}|Sort-Object ReportDate)
            $active=[datetime]::MinValue
            if($source.ActiveFrom){$active=[datetime]::ParseExact([string]$source.ActiveFrom,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)}
            if($dated.Count -eq 0 -and $active -eq [datetime]::MinValue){continue}
            $firstMonth=$thisMonth.AddMonths(-[int]$Config.MonthlyLookbackMonths)
            if($active -ne [datetime]::MinValue){$activeMonth=$active.AddDays(1-$active.Day);if($firstMonth -lt $activeMonth){$firstMonth=$activeMonth}}
            elseif($dated.Count -gt 0){$first=[datetime]::ParseExact([string]$dated[0].ReportDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture);$first=$first.AddDays(1-$first.Day);if($firstMonth -lt $first){$firstMonth=$first}}
            $monthsToCheck=@();for($month=$firstMonth;$month -lt $thisMonth;$month=$month.AddMonths(1)){$monthsToCheck+=@($month.ToString('yyyy-MM'))}
        }
        foreach($month in $monthsToCheck) {
            $required=@(Get-QaChecklistForMonth $source $month)
            $monthRows=@($rows|Where-Object{[string]$_.ReportDate -match '^\d{4}-\d{2}-\d{2}$' -and ([string]$_.ReportDate).StartsWith($month+'-',[StringComparison]::Ordinal)})
            $confirmed=@($monthRows|Where-Object{$_.Category -eq 'Monthly_QA' -and (Get-QaValue $_ 'ConfirmedBy') -and (Get-QaValue $_ 'ConfirmedAt') -and [string](Get-QaValue $_ 'Hash') -match '^[0-9A-Fa-f]{64}$'})
            $pending=@($monthRows|Where-Object{$_.Category -eq 'Monthly_QA/Pending_Verification'})
            $coveredSet=@{}
            foreach($record in $confirmed){foreach($item in @(Get-QaComponentLabels (Get-QaValue $record 'ConfirmedComponents' $null) 'Reviewed report items')){$coveredSet[$item]=$true}}
            $covered=@($required|Where-Object{$coveredSet.ContainsKey($_)})
            $missing=@($required|Where-Object{-not $coveredSet.ContainsKey($_)})
            if($required.Count -eq 0){$status='ChecklistNotSet'}
            elseif($confirmed.Count -eq 0){$status=if($pending.Count -gt 0){'NeedsConfirmation'}else{'NoConfirmedReport'}}
            elseif($missing.Count -gt 0){$status='Partial'}else{$status='Complete'}
            [void]$result.Add([pscustomobject]@{Scanner=[string]$source.Scanner;ScannerName=[string]$source.Name;Month=[string]$month;Status=$status;ReportCount=$monthRows.Count;ConfirmedReportCount=$confirmed.Count;RequiredComponents=[object[]]$required;ConfirmedComponents=[object[]]$covered;MissingComponents=[object[]]$missing})
        }
    }
    return @($result.ToArray()|Sort-Object Scanner,Month)
}
function Get-QaAttention { param($Config,$State,$Paths)
    $attention=New-Object 'System.Collections.Generic.List[object]'
    foreach($issue in @($State.Issues)) { [void]$attention.Add($issue) }
    $coverageByMonth=@{}
    foreach($coverage in @(Get-QaMonthlyCoverage -Config $Config -Records @($State.Records))){$coverageByMonth[$coverage.Scanner+'|'+$coverage.Month]=$coverage}
    foreach($s in $Config.Sources) {
        $status=@($State.Scanners|Where-Object{$_.Scanner -eq $s.Scanner}|Select-Object -First 1)
        $rows=@($State.Records|Where-Object{$_.Scanner -eq $s.Scanner})
        foreach($r in $rows) {
            if ($r.Category -eq 'Monthly_QA/Pending_Verification') { [void]$attention.Add((New-QaIssue $s.Scanner 'MonthlyReview' ($s.Name+' - Possible Monthly report requires verification: '+$r.OriginalFileName) $r.DestinationPath $r.Id)) }
            elseif($r.Category -eq 'Needs_Review' -or ([string](Get-QaValue $r 'ClassificationBasis' '') -like 'Provisional*' -and -not [string](Get-QaValue $r 'ConfirmedBy' ''))) { [void]$attention.Add((New-QaIssue $s.Scanner 'Classification' ($s.Name+' - Review this report classification: '+$r.OriginalFileName) $r.DestinationPath $r.Id)) }
        }
        foreach($group in @($rows|Group-Object OriginalFileName|Where-Object{$_.Count -gt 1})) {
            [void]$attention.Add((New-QaIssue $s.Scanner 'DuplicateName' ($s.Name+' - '+$group.Count+' preserved records share the filename '+$group.Name+'. They may be distinct source files or revisions.') (Join-Path $Paths.Reports $s.Scanner)))
        }
        foreach($group in @($rows|Where-Object{$_.ReportDate}|Group-Object ReportDate|Where-Object{$_.Count -gt 1})) {
            [void]$attention.Add((New-QaIssue $s.Scanner 'MultipleSessions' ($s.Name+' - '+$group.Count+' reports are preserved for '+$group.Name+'. Multiple sessions can be legitimate.') (Join-Path (Join-Path (Join-Path $Paths.Reports $s.Scanner) $group.Name.Substring(0,4)) $group.Name.Substring(5,2))))
        }
        if ($status.Count -eq 0 -or $status[0].Status -notin @('Connected','Issues')) { continue }
        $dated=@($rows|Where-Object{$_.ReportDate -match '^\d{4}-\d{2}-\d{2}$'}|Sort-Object ReportDate)
        $active=[datetime]::MinValue
        if ($s.ActiveFrom) { $active=[datetime]::ParseExact([string]$s.ActiveFrom,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture) }
        if ($dated.Count -eq 0 -and $active -eq [datetime]::MinValue) {
            [void]$attention.Add((New-QaIssue $s.Scanner 'CoverageUnknown' ($s.Name+' - No dated archive records establish a review start date. Set Active from in Advanced Settings if known.') (Join-Path $Paths.Reports $s.Scanner)));continue
        }
        $start=(Get-Date).Date.AddDays(-[int]$Config.LookbackDays)
        if ($dated.Count -gt 0) { $first=[datetime]::ParseExact($dated[0].ReportDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture);if($active -eq [datetime]::MinValue -and $start -lt $first){$start=$first} }
        if ($active -gt $start) {$start=$active}
        $daily=@{};$pending=@{};$monthly=@{}
        foreach($r in $dated) {
            if ($r.Category -eq 'Daily_QA') {if([string](Get-QaValue $r 'ClassificationBasis' '') -like 'Provisional*' -and -not [string](Get-QaValue $r 'ConfirmedBy' '')){$pending[$r.ReportDate]=$r}else{$daily[$r.ReportDate]=$true}}
            if ($r.Category -eq 'Monthly_QA/Pending_Verification') {$pending[$r.ReportDate]=$r}
            if ($r.Category -eq 'Monthly_QA' -and $r.ConfirmedBy -and $r.ConfirmedAt) {$monthly[$r.ReportDate.Substring(0,7)]=$true}
        }
        if ($s.DailySchedule -ne 'Off') {
            for($day=$start;$day -lt (Get-Date).Date;$day=$day.AddDays(1)) {
                if ($s.DailySchedule -eq 'Weekdays' -and $day.DayOfWeek -in @('Saturday','Sunday')){continue}
                $key=$day.ToString('yyyy-MM-dd')
                if(@(Get-QaValue $s 'ExcludedDates' @()) -contains $key){continue}
                if (-not $daily.ContainsKey($key)) {
                    if ($pending.ContainsKey($key)) { [void]$attention.Add((New-QaIssue $s.Scanner 'DailyReview' ($s.Name+' - Daily archive coverage for '+$key+' awaits report classification.') $pending[$key].DestinationPath $pending[$key].Id)) }
                    else { [void]$attention.Add((New-QaIssue $s.Scanner 'DailyGap' ($s.Name+' - No Daily QA archive report found for '+$key+'. Check the local schedule and scanner records.') (Join-Path (Join-Path (Join-Path $Paths.Reports $s.Scanner) $day.ToString('yyyy')) $day.ToString('MM')))) }
                }
            }
        }
        if ([bool]$s.ExpectedMonthly) {
            $required=@(Get-QaComponentLabels (Get-QaValue $s 'MonthlyChecklist' $null))
            if($required.Count -eq 0){[void]$attention.Add((New-QaIssue $s.Scanner 'MonthlyChecklist' ($s.Name+' - Monthly checklist not configured. Report presence can be checked, but completeness is not assessed.') (Join-Path $Paths.Reports $s.Scanner)))}
            foreach($coverage in @($coverageByMonth.Values|Where-Object{$_.Scanner -ceq $s.Scanner}|Sort-Object Month)) {
                $month=[datetime]::ParseExact($coverage.Month,'yyyy-MM',[Globalization.CultureInfo]::InvariantCulture)
                $folder=Join-Path (Join-Path (Join-Path $Paths.Reports $s.Scanner) $month.ToString('yyyy')) $month.ToString('MM')
                if($coverage.ConfirmedReportCount -eq 0) {
                    $hasCandidate=@($dated|Where-Object{$_.Category -eq 'Monthly_QA/Pending_Verification' -and ([string]$_.ReportDate).StartsWith($coverage.Month+'-')}).Count -gt 0
                    $message=$s.Name+' - No Monthly QA report confirmed for '+$month.ToString('MMMM yyyy',[Globalization.CultureInfo]::InvariantCulture)+'.'
                    $type='MonthlyGap';if($hasCandidate){$message+=' A possible Monthly report is awaiting verification.';$type='MonthlyPending'}
                    [void]$attention.Add((New-QaIssue $s.Scanner $type $message $folder))
                } elseif($coverage.Status -eq 'Partial') {
                    $message=$s.Name+' - '+$month.ToString('MMMM yyyy',[Globalization.CultureInfo]::InvariantCulture)+': '+$coverage.ConfirmedComponents.Count+' of '+$coverage.RequiredComponents.Count+' required items confirmed. Still needs confirmation: '+($coverage.MissingComponents -join '; ')+'. These may be in a combined report or separate PDFs.'
                    $issue=New-QaIssue $s.Scanner 'MonthlyComponents' $message $folder
                    Set-QaValue $issue 'Month' $coverage.Month;Set-QaValue $issue 'MissingComponents' ([object[]]@($coverage.MissingComponents));Set-QaValue $issue 'ConfirmedComponents' ([object[]]@($coverage.ConfirmedComponents))
                    [void]$attention.Add($issue)
                }
            }
        }
    }
    return @($attention.ToArray()|Sort-Object Type,Scanner,Message -Unique)
}
function Get-QaDashboard {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Config)
    Assert-QaConfig $Config;$paths=Get-QaPaths $Config;$state=Read-QaState $paths
    $scanners=New-Object 'System.Collections.Generic.List[object]'
    foreach($record in @($state.Records)) {
        $source=@($Config.Sources | Where-Object { $_.Scanner -eq $record.Scanner })[0]
        Set-QaValue $record 'ScannerName' ([string]$source.Name)
    }
    foreach($s in $Config.Sources) {
        $old=@($state.Scanners|Where-Object{$_.Scanner -eq $s.Scanner}|Select-Object -First 1)
        $count=@($state.Records|Where-Object{$_.Scanner -eq $s.Scanner}).Count
        if($old.Count){$row=$old[0];$row.Name=$s.Name;$row.Count=$count;$row.SavedReports=$count;[void]$scanners.Add($row)}
        else{[void]$scanners.Add([pscustomobject]@{Scanner=$s.Scanner;Name=$s.Name;Status='Unknown';Message='Connection has not been checked. Run Setup or Update Reports.';Count=$count;SavedReports=$count;LastSuccessfulUpdate='';CheckedUtc=''})}
    }
    $legacy=([IO.File]::Exists((Join-Path $paths.Root 'QA_Master_Index_v2.csv')) -and -not [IO.File]::Exists($paths.State))
    return [pscustomobject]@{Records=@($state.Records);MonthlyCoverage=@(Get-QaMonthlyCoverage -Config $Config -Records @($state.Records));Attention=@(Get-QaAttention $Config $state $paths);Scanners=@($scanners.ToArray());SetupComplete=[bool]$state.SetupComplete;TotalReports=@($state.Records).Count;LegacyDetected=$legacy;ArchiveRoot=$paths.Root;IndexPath=$paths.Index;HistoryPath=$paths.History;LastUpdated=$state.UpdatedUtc}
}
function Get-QaReviewPlan { param($Config,$State,$Decisions)
    $items=New-Object 'System.Collections.Generic.List[object]';$seen=@{}
    foreach($d in @($Decisions)) {
        $id=[string](Get-QaValue $d 'RecordId')
        if(-not $id -or $seen.ContainsKey($id)){throw 'Choose each report once for reclassification.'};$seen[$id]=$true
        $found=@($State.Records|Where-Object{$_.Id -eq $id})
        if($found.Count -ne 1){throw 'The selected report no longer exists uniquely in the archive index.'}
        $r=$found[0];$category=[string]$d.Category
        if($category -notin $script:QaCategories){throw 'Choose a supported QA category.'}
        if([string]::IsNullOrWhiteSpace([string]$d.Reviewer) -or [string]::IsNullOrWhiteSpace([string]$d.Reason)){throw 'Enter the authorized reviewer name and reason before confirming a classification.'}
        if(-not [IO.File]::Exists($r.DestinationPath) -or (Get-QaFileHash $r.DestinationPath) -ne $r.Hash){throw 'The saved PDF is missing or has changed. Run the integrity audit before reviewing it.'}
        $declaredHash=[string](Get-QaValue $d 'Hash')
        if($declaredHash -and $declaredHash -ne $r.Hash){throw 'The review refers to a different report hash. Reopen the report and review the current saved bytes.'}
        $source=@($Config.Sources|Where-Object{$_.Scanner -ceq $r.Scanner})[0]
        $reviewMonth=if([string]$r.ReportDate -match '^\d{4}-\d{2}-\d{2}$'){([string]$r.ReportDate).Substring(0,7)}else{(Get-Date).ToString('yyyy-MM')}
        $required=@(Get-QaChecklistForMonth $source $reviewMonth)
        $declared=@(Get-QaComponentLabels (Get-QaValue $d 'ConfirmedComponents' $null) 'Confirmed report items')
        if($category -ne 'Monthly_QA' -and $declared.Count -gt 0){throw 'Monthly checklist items can be confirmed only for a reviewed Monthly QA report.'}
        $canonical=New-Object 'System.Collections.Generic.List[string]'
        foreach($component in $declared) {
            $match=@($required|Where-Object{$_ -ieq $component})
            if($match.Count -ne 1){throw ('The confirmed item is not in this scanner''s department checklist: '+$component)}
            [void]$canonical.Add([string]$match[0])
        }
        [void]$items.Add([pscustomobject]@{RecordId=$id;Scanner=$r.Scanner;OriginalFileName=$r.OriginalFileName;OldCategory=$r.Category;Category=$category;Reviewer=[string]$d.Reviewer;Reason=[string]$d.Reason;Hash=$r.Hash;SourcePath=$r.SourcePath;ConfirmedComponents=[object[]]$canonical.ToArray()})
    }
    if($items.Count -eq 0){throw 'Select at least one report to review.'}
    $summary=New-QaSummary;$summary.Total=$items.Count;$summary.Description=($items.Count.ToString()+' classification decision(s) ready for review.')
    return [pscustomobject]@{Items=@($items.ToArray());Summary=$summary;CreatedUtc=[datetime]::UtcNow.ToString('o');ConfigFingerprint=(Get-QaConfigFingerprint $Config)}
}
function Invoke-QaReview { param($Config,$State,$Paths,$Decisions,$Summary)
    $plan=Get-QaReviewPlan $Config $State $Decisions
    foreach($item in $plan.Items) {
        $old=@($State.Records|Where-Object{$_.Id -eq $item.RecordId})[0]
        $r=$old|Select-Object *;$r.Category=$item.Category;$r.ClassificationBasis='Authorized review: '+$item.Reason;$r.ConfirmedBy=$item.Reviewer;$r.ConfirmedAt=[datetime]::UtcNow.ToString('o')
        Set-QaValue $r 'ConfirmedComponents' ([object[]]@($item.ConfirmedComponents))
        $r.RelativePath=Get-QaRelativeTarget $r $r.Hash;$r.DestinationPath=Join-Path $Paths.Reports $r.RelativePath
        $review=[pscustomobject]@{RecordId=$r.Id;Hash=$r.Hash;From=$old.Category;To=$r.Category;Reviewer=$item.Reviewer;Reason=$item.Reason;TimeUtc=$r.ConfirmedAt;PreviousPath=$old.DestinationPath;NewPath=$r.DestinationPath;PreviousRelativePath=$old.RelativePath;NewRelativePath=$r.RelativePath;HistoryRelativePath='';ConfirmedComponents=[object[]]@($r.ConfirmedComponents)}
        Assert-QaNoReparse $r.DestinationPath $Paths.Root
        if(-not $r.DestinationPath.Equals($old.DestinationPath,[StringComparison]::OrdinalIgnoreCase)) {
            $token=[guid]::NewGuid().ToString('N');$stage=Join-Path $Paths.Staging ($token+'.partial')
            # The verified local PDF is staged before commit. Source scanner is never contacted.
            [IO.File]::Copy($old.DestinationPath,$stage,$false)
            if((Get-QaFileHash $stage) -ne $r.Hash){throw 'The saved report changed during reclassification. No classification was committed.'}
            Write-QaAtomicText (Join-Path $Paths.Transactions ($token+'.json')) (([pscustomobject]@{StageName=[IO.Path]::GetFileName($stage);Record=$r;PreviousRelativePath=$old.RelativePath;Review=$review})|ConvertTo-Json -Depth 8)
            if([IO.File]::Exists($r.DestinationPath)) {if((Get-QaFileHash $r.DestinationPath) -ne $r.Hash){throw 'The classification destination contains different bytes. Nothing was overwritten.'};[IO.File]::Delete($stage)}
            else{[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($r.DestinationPath));[IO.File]::Move($stage,$r.DestinationPath)}
            # The previous copy is kept until state commit; cleanup below only removes our exact verified duplicate.
            $r.DestinationLastWriteUtc=(Get-Item -LiteralPath $r.DestinationPath).LastWriteTimeUtc.ToString('o')
        }
        $State.Records=@($State.Records|Where-Object{$_.Id -ne $r.Id})+@($r)
        
        $State.Reviews=@($State.Reviews)+@($review);$Summary.Verified++
        Save-QaState $State $Paths
        # Preserve old bytes as a review history copy rather than deleting or overwriting PDF data.
    }
    $Summary.Total=$plan.Items.Count;$Summary.Description='Classification decisions saved. Former category copies are preserved in the private review history; the index points to the reviewed report.'
}
function Move-QaReviewedHistory { param($State,$Paths)
    $issues=New-Object 'System.Collections.Generic.List[object]'
    foreach($review in @($State.Reviews)) {
        $previous=''
        $relative=[string](Get-QaValue $review 'PreviousRelativePath')
        if(-not $relative){continue}
        try {
            if([IO.Path]::IsPathRooted($relative)){throw 'The previous review path is not relative.'}
            $previous=Join-Path $Paths.Reports $relative
            if(-not(Test-QaChildPath $previous $Paths.Reports)){throw 'The previous review path is outside Reports.'}
            # Never move a PDF that is the current destination of any indexed record.
            if(@($State.Records|Where-Object{$_.DestinationPath.Equals($previous,[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0){continue}
            if(-not [IO.File]::Exists($previous)){continue}
            Assert-QaNoReparse $previous $Paths.Root
            if((Get-QaFileHash $previous) -ne $review.Hash){throw 'The former category copy differs from the reviewed hash; it was preserved in place.'}
            $name='Review_'+([datetime]::Parse([string]$review.TimeUtc).ToUniversalTime().ToString('yyyyMMddHHmmssfff'))+'_'+([string]$review.Hash).Substring(0,12)+'.pdf'
            $historyRelative=Join-Path (Join-Path 'reclassification-history' ([string]$review.RecordId).Substring(0,16)) $name
            $history=Join-Path $Paths.Meta $historyRelative
            if(-not(Test-QaChildPath $history $Paths.Meta)){throw 'The review history path is unsafe.'}
            Assert-QaNoReparse $history
            if([IO.File]::Exists($history)) {
                # A prior successful move may already be retained. Keep another equal copy
                # with a unique name rather than ever deleting or overwriting PDF bytes.
                $historyRelative=Join-Path ([IO.Path]::GetDirectoryName($historyRelative)) ([guid]::NewGuid().ToString('N')+'_'+[IO.Path]::GetFileName($previous))
                $history=Join-Path $Paths.Meta $historyRelative;Assert-QaNoReparse $history
            }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($history))
            [IO.File]::Move($previous,$history)
            Set-QaValue $review 'HistoryRelativePath' $historyRelative
        } catch {
            [void]$issues.Add((New-QaIssue '' 'ReviewHistory' ('A prior category copy was kept in place. '+$_.Exception.Message) $previous))
        }
    }
    return @($issues.ToArray())
}
function Invoke-QaLegacyAdoption { param($Config,$State,$Paths,[string]$LegacyRoot,$Progress,$Summary,$Issues)
    $legacy=[IO.Path]::GetFullPath($LegacyRoot);$index=Join-Path $legacy 'QA_Master_Index_v2.csv';$reports=Join-Path $legacy 'Reports'
    if(-not [IO.File]::Exists($index)){throw 'The selected folder does not contain QA_Master_Index_v2.csv.'}
    $rows=@(Import-Csv -LiteralPath $index);$Summary.Total=$rows.Count;$n=0
    foreach($row in $rows) {
        $n++;if(Test-QaCancel $Progress){$Summary.Cancelled=$true;break}
        Set-QaProgress $Progress ('Verifying existing archive '+$n+' of '+$rows.Count) (100*$n/[math]::Max(1,$rows.Count))
        try {
            $scanner=@($Config.Sources|Where-Object{$_.Scanner -eq $row.Scanner}|Select-Object -First 1)
            if($scanner.Count -ne 1){throw 'The old record has an unknown scanner.'}
            $row.Scanner=[string]$scanner[0].Scanner
            $source=[string]$row.DestinationPath
            if(-not (Test-QaChildPath $source $reports)){throw 'The old index path is outside its Reports folder; it was not trusted.'}
            Assert-QaNoReparse $source $reports
            if(-not [IO.File]::Exists($source)){throw 'The old archived PDF is missing.'}
            $hash=Get-QaFileHash $source
            if($row.SourceHash -notmatch '^[0-9a-fA-F]{64}$' -or $hash -ne $row.SourceHash){throw 'The old archived PDF does not match its indexed SHA-256.'}
            $info=Get-Item -LiteralPath $source;$class=Get-QaClassification $scanner[0] $row.OriginalFileName $info.Length
            $id=Get-QaHashText ((Get-QaSourceKey $row.Scanner $row.SourcePath)+'|'+$hash)
            if(@($State.Records|Where-Object{$_.Id -eq $id}).Count -gt 0){$Summary.Unchanged++;continue}
            $entry=[pscustomobject]@{Scanner=$row.Scanner;OriginalFileName=$row.OriginalFileName;SourcePath=$row.SourcePath;ReportDate=$class.ReportDate;ReportTime=$class.ReportTime;Category=$class.Category}
            if($row.Category -eq 'Monthly_QA'){$entry.Category='Monthly_QA/Pending_Verification';$class.ClassificationBasis='Previously classified Monthly in the old index; current hash verified, authorized confirmation required.'}
            $relative=Get-QaRelativeTarget $entry $hash;$target=Join-Path $Paths.Reports $relative;Assert-QaNoReparse $target $Paths.Root
            if([IO.File]::Exists($target)){if((Get-QaFileHash $target) -ne $hash){throw 'Legacy destination collision; existing data was preserved.'}}
            else{
                $token=[guid]::NewGuid().ToString('N');$stage=Join-Path $Paths.Staging ($token+'.partial');[IO.File]::Copy($source,$stage,$false)
                if((Get-QaFileHash $stage) -ne $hash){throw 'Legacy transfer hash mismatch.'}
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));[IO.File]::Move($stage,$target);$Summary.Copied++
            }
            $pdf=Get-QaPdfInfo $target
            $record=[pscustomobject]@{Id=$id;Scanner=$row.Scanner;ReportDate=$class.ReportDate;ReportTime=$class.ReportTime;OriginalFileName=$row.OriginalFileName;SourcePath=$row.SourcePath;SourceKey=(Get-QaSourceKey $row.Scanner $row.SourcePath);Hash=$hash;Length=[long]$info.Length;SourceLastWriteUtc='';RelativePath=$relative;DestinationPath=$target;DestinationLastWriteUtc=(Get-Item -LiteralPath $target).LastWriteTimeUtc.ToString('o');Category=$entry.Category;ClassificationBasis=$class.ClassificationBasis;FirstArchived=[string]$row.FirstArchived;ConfirmedBy='';ConfirmedAt='';ConfirmedComponents=@();PdfPagesHint=$pdf.Pages}
            Add-QaRecord $State $record;$Summary.Verified++
            Save-QaState $State $Paths
        } catch{$Summary.Failed++;[void]$Issues.Add((New-QaIssue ([string]$row.Scanner) 'Migration' ('Existing archive record could not be adopted: '+$_.Exception.Message) ([string]$row.DestinationPath)))}
    }
    $State.SetupComplete=(@($State.Records).Count -gt 0);$Summary.Description='Existing archive checked against its old hashes and safely adopted. Old folders and PDFs were preserved.'
}
function Invoke-QaOperation {
    [CmdletBinding()]param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][ValidateSet('Preview','Import','Update','Audit','ReclassifyPreview','Reclassify','AdoptLegacy')][string]$Mode,
        $Progress=$null,$Plan=$null,[object[]]$Decisions=@(),[string]$LegacyRoot=''
    )
    Assert-QaConfig $Config;$paths=Get-QaPaths $Config;$summary=New-QaSummary;$lock=$null
    # Reading an archive never creates it; a preview has no persistent side effects.
    $state=Read-QaState $paths
    if($Mode -eq 'ReclassifyPreview'){$review=Get-QaReviewPlan $Config $state $Decisions;return [pscustomobject]@{Mode=$Mode;Plan=$review;Summary=$review.Summary;Scanners=@($state.Scanners);Attention=@(Get-QaAttention $Config $state $paths)}}
    if($Mode -eq 'Preview') {
        $inventory=Get-QaInventory $Config $state $Progress $summary
        $plan=[pscustomobject]@{Items=@($inventory.Items);Summary=$summary;Scanners=@($inventory.Scanners);Issues=@($inventory.Issues);CreatedUtc=[datetime]::UtcNow.ToString('o');ConfigFingerprint=(Get-QaConfigFingerprint $Config)}
        $state.Scanners=@($inventory.Scanners);$state.Issues=@($inventory.Issues)
        $summary.Description=($summary.NewOrChanged.ToString()+' reports to copy or verify; '+$summary.Unchanged+' unchanged; '+$summary.Pending+' possible Monthly reports require review.')
        return [pscustomobject]@{Mode=$Mode;Plan=$plan;Summary=$summary;Scanners=@($state.Scanners);Attention=@(Get-QaAttention $Config $state $paths)}
    }
    if($Mode -eq 'Import') {
        if($null -eq $Plan -or -not (Get-QaValue $Plan 'CreatedUtc')){throw 'Run First-Time Setup to preview the report list before importing.'}
        if($Plan.ConfigFingerprint -ne (Get-QaConfigFingerprint $Config)){throw 'Settings changed after preview. Run the setup preview again.'}
        if([bool]$Plan.Summary.Cancelled){throw 'The preview was cancelled. Run it again before importing.'}
        foreach($item in @($Plan.Items)) {
            if($item.Action -eq 'Deferred'){continue}
            try{$info=Get-Item -LiteralPath $item.SourcePath -ErrorAction Stop}catch{throw 'A previewed report is no longer available. Run setup preview again.'}
            if($info.Length -ne $item.Length -or $info.LastWriteTimeUtc.ToString('o') -ne $item.SourceLastWriteUtc){throw 'A source report changed after preview. Run setup preview again before copying.'}
        }
    }
    try {
        foreach($managed in @($paths.Root,$paths.Meta,$paths.State,$paths.Transactions,$paths.Staging,$paths.Reports,$paths.Index,$paths.History,(Join-Path $paths.Meta 'archive.lock'))) { Assert-QaNoReparse $managed }
        [void][IO.Directory]::CreateDirectory($paths.Meta)
        try{$lock=[IO.File]::Open((Join-Path $paths.Meta 'archive.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'This archive is already open in another update, or the destination is not writable. Close the other update or choose an accessible archive folder.'}
        # Reload under lock so a preview never overwrites state committed by another process.
        $state=Read-QaState $paths
        [void][IO.Directory]::CreateDirectory($paths.Transactions);[void][IO.Directory]::CreateDirectory($paths.Staging);[void][IO.Directory]::CreateDirectory($paths.Reports)
        $issues=New-Object 'System.Collections.Generic.List[object]'
        Restore-QaTransactions $state $paths $issues
        foreach($historyIssue in @(Move-QaReviewedHistory $state $paths)){[void]$issues.Add($historyIssue)}
        if($Mode -eq 'Audit') {
            $rows=@($state.Records);$summary.Total=$rows.Count;$n=0
            foreach($r in $rows) {
                $n++;if(Test-QaCancel $Progress){$summary.Cancelled=$true;break};Set-QaProgress $Progress ('Checking saved report '+$n+' of '+$rows.Count) (100*$n/[math]::Max(1,$rows.Count))
                try{Assert-QaNoReparse $r.DestinationPath $paths.Root;if(-not [IO.File]::Exists($r.DestinationPath)){throw 'The saved PDF is missing.'};if((Get-QaFileHash $r.DestinationPath) -ne $r.Hash){throw 'The saved PDF differs from its verified SHA-256.'};$summary.Verified++}
                catch{$summary.Failed++;[void]$issues.Add((New-QaIssue $r.Scanner 'Integrity' ($r.Scanner+' - '+$r.OriginalFileName+': '+$_.Exception.Message) $r.DestinationPath $r.Id))}
            }
            $summary.Description='Saved PDFs were checked against their indexed SHA-256 hashes. Scanner access is not required.'
            # Preserve connection and transfer issues when an audit is run.
            foreach($issue in @($state.Issues|Where-Object{$_.Type -ne 'Integrity'})){[void]$issues.Add($issue)}
        } elseif($Mode -eq 'Reclassify') {
            Invoke-QaReview $Config $state $paths $Decisions $summary
            foreach($historyIssue in @(Move-QaReviewedHistory $state $paths)){[void]$issues.Add($historyIssue)}
            foreach($issue in @($state.Issues)){[void]$issues.Add($issue)}
        } elseif($Mode -eq 'AdoptLegacy') {
            if(-not $LegacyRoot){throw 'Choose the existing archive folder to safely adopt it.'}
            Invoke-QaLegacyAdoption $Config $state $paths $LegacyRoot $Progress $summary $issues
        } else {
            if($Mode -eq 'Update' -and -not $state.SetupComplete){throw 'Complete First-Time Setup before updating this archive.'}
            if($Mode -eq 'Import') {
                $inventory=[pscustomobject]@{Items=@($Plan.Items);Scanners=@($Plan.Scanners);Issues=@($Plan.Issues)}
                $summary.Total=[int]$Plan.Summary.Total;$summary.NewOrChanged=[int]$Plan.Summary.NewOrChanged;$summary.Unchanged=[int]$Plan.Summary.Unchanged;$summary.Pending=[int]$Plan.Summary.Pending;$summary.Deferred=[int]$Plan.Summary.Deferred
            } else {$inventory=Get-QaInventory $Config $state $Progress $summary}
            foreach($issue in @($inventory.Issues)){[void]$issues.Add($issue)}
            $state.Scanners=@($inventory.Scanners);$scannerFailed=@{};$n=0
            foreach($item in @($inventory.Items)) {
                if(Test-QaCancel $Progress){$summary.Cancelled=$true;break};$n++
                Set-QaProgress $Progress ('Organizing '+$item.OriginalFileName) (30+70*$n/[math]::Max(1,@($inventory.Items).Count))
                if($item.Action -in @('Unchanged','Deferred')){continue}
                $source=@($Config.Sources|Where-Object{$_.Scanner -eq $item.Scanner})[0]
                try{Copy-QaVerified $item $source $state $paths $Progress $summary}
                catch{
                    if(Test-QaCancel $Progress){$summary.Cancelled=$true;break}
                    $summary.Failed++;$scannerFailed[$item.Scanner]=$true
                    [void]$issues.Add((New-QaIssue $item.Scanner 'Transfer' ($source.Name+' - Could not copy or verify '+$item.OriginalFileName+'. '+$_.Exception.Message) $item.SourcePath))
                }
            }
            foreach($s in $state.Scanners) {
                $s.Count=@($state.Records|Where-Object{$_.Scanner -eq $s.Scanner}).Count;$s.SavedReports=$s.Count
                if($s.Status -eq 'Connected' -and -not $scannerFailed.ContainsKey($s.Scanner) -and -not $summary.Cancelled -and @($inventory.Items|Where-Object{$_.Scanner -eq $s.Scanner -and $_.Action -eq 'Deferred'}).Count -eq 0){$s.LastSuccessfulUpdate=[datetime]::UtcNow.ToString('o');$s.Message='Update completed successfully.'}
                elseif($s.Status -eq 'Connected'){$s.Status='Issues';$s.Message='Connected; some reports need attention or were deferred.'}
            }
            if($Mode -eq 'Import' -and -not $summary.Cancelled -and @($state.Scanners|Where-Object{$_.Status -in @('Connected','Issues','Partial')}).Count -gt 0){$state.SetupComplete=$true}
            $summary.Description=($summary.Copied.ToString()+' copied; '+$summary.Unchanged+' unchanged; '+$summary.Verified+' existing verified; '+$summary.Failed+' need attention.')
        }
        $state.Issues=@($issues.ToArray());Save-QaState $state $paths
        Add-QaHistory $paths $Mode $summary $summary.Description
        if($summary.Cancelled){$summary.Description='Cancelled safely. Completed, verified reports are preserved. Run Update Reports to continue.'}
        Set-QaProgress $Progress $summary.Description 100
        return [pscustomobject]@{Mode=$Mode;Summary=$summary;Scanners=@($state.Scanners);Attention=@(Get-QaAttention $Config $state $paths);Records=@($state.Records);MonthlyCoverage=@(Get-QaMonthlyCoverage -Config $Config -Records @($state.Records));SetupComplete=[bool]$state.SetupComplete}
    } finally { if($null -ne $lock){$lock.Dispose()} }
}
Export-ModuleMember -Function Get-QaDefaultConfig,Read-QaConfig,Save-QaConfig,Get-QaDashboard,Invoke-QaOperation,Get-QaMonthlyCoverage,Get-QaChecklistForMonth
