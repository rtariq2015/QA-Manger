# CT QA Manager Pro: searchable report views and verified portable ZIP exports.
# Native Windows PowerShell 5.1 / .NET Framework. Archive and scanner PDFs are read-only.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-QaReportValue { param($Object,[string]$Name,$Default='')
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Get-QaScannerLabel { param([string]$Scanner,[string]$Name='')
    if(-not [string]::IsNullOrWhiteSpace($Name)){return $Name.Trim()}
    switch($Scanner) { 'CT_Edge' {'CT Edge'} 'CT_Flash' {'CT Flash'} 'MDP_Building' {'MDP Building'} default {$Scanner.Replace('_',' ')} }
}
function ConvertTo-QaPathLabel { param([string]$Text)
    $safe=($Text -replace '[<>:"/\\|?*\x00-\x1f]','-').Trim().TrimEnd('.',' ')
    if($safe.Length -gt 32){$safe=$safe.Substring(0,32).TrimEnd('.',' ')}
    if(-not $safe -or $safe -in @('.','..')){$safe='Scanner'}
    if($safe -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)'){$safe='Scanner '+$safe}
    return $safe
}
function Get-QaCategoryLabel { param([string]$Category)
    switch($Category) {
        'Daily_QA' {'Daily QA'}
        'Monthly_QA' {'Monthly QA - Confirmed'}
        'Monthly_QA/Pending_Verification' {'Monthly QA - Pending Verification'}
        'Acceptance_Tests' {'Acceptance Tests'}
        default {'Needs Review'}
    }
}
function Get-QaCategoryFolder { param([string]$Category)
    switch($Category) {
        'Daily_QA' {'Daily QA'}
        'Monthly_QA' {'Monthly QA/Confirmed'}
        'Monthly_QA/Pending_Verification' {'Monthly QA/Pending Verification'}
        'Acceptance_Tests' {'Other Reports/Acceptance Tests'}
        default {'Other Reports/Needs Review'}
    }
}
function Get-QaReportDate { param($Record)
    $date=[datetime]::MinValue
    $value=Get-QaReportValue $Record 'ReportDate'
    if ($value -is [datetime]) { return $value.Date }
    if ([datetime]::TryParseExact([string]$value,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)) { return $date }
    return $null
}
function Get-QaReportTitle {
    [CmdletBinding()]param([Parameter(Mandatory=$true)]$Record)
    $scanner=Get-QaScannerLabel ([string]$Record.Scanner) ([string](Get-QaReportValue $Record 'ScannerName'))
    $category=Get-QaCategoryLabel ([string]$Record.Category)
    $date=Get-QaReportDate $Record
    $dateText=if($null -ne $date){$date.ToString('MMM dd, yyyy',[Globalization.CultureInfo]::InvariantCulture)}else{'Undated report'}
    $time=[string](Get-QaReportValue $Record 'ReportTime')
    if($time -match '^\d{2}:\d{2}'){$dateText+=' at '+$time.Substring(0,5)}
    return $scanner+' - '+$dateText+' - '+$category
}
function Select-QaReports {
    [CmdletBinding()]param(
        [AllowEmptyCollection()][object[]]$Records=@(),[string]$Scanner='All',
        [ValidateRange(0,9999)][int]$Year=0,[ValidateRange(0,12)][int]$Month=0,
        [string]$Category='All',[string]$Query='',
        [AllowEmptyCollection()][ValidateRange(1,9999)][int[]]$Years=@(),$Index=$null
    )
    if($null -eq $Index){Import-Module (Join-Path $PSScriptRoot 'Search.psm1');$Index=New-QaSearchIndex -Records $Records}
    return $Index.Find($Scanner,$Year,$Month,$Category,$Query,$Years)
}
function Test-QaExportCancelled { param($Progress)
    return ($null -ne $Progress -and $Progress.ContainsKey('Cancel') -and [bool]$Progress.Cancel)
}
function Set-QaExportProgress { param($Progress,[string]$Message,[double]$Percent)
    if($null -ne $Progress){$Progress.Message=$Message;$Progress.Percent=$Percent}
}
function Assert-QaExportNoLink { param([string]$Path)
    $current=[IO.Path]::GetFullPath($Path)
    while($current) {
        if([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            if(([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A linked folder or file is not allowed for report exports. Choose a direct local folder.'}
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if($parent -eq $current){break};$current=$parent
    }
}
function Test-QaExportWithin { param([string]$Path,[string]$Parent)
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $root=[IO.Path]::GetFullPath($Parent).TrimEnd('\','/')
    return ($full.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))
}
function Assert-QaExportDestination { param($Config,[string]$DestinationPath)
    if([string]::IsNullOrWhiteSpace($DestinationPath) -or -not [IO.Path]::IsPathRooted($DestinationPath)){throw 'Choose an absolute path for the exported ZIP file.'}
    $full=[IO.Path]::GetFullPath($DestinationPath)
    if([IO.Path]::GetExtension($full) -ne '.zip'){throw 'Save the report export with a .zip filename.'}
    $name=[IO.Path]::GetFileName($full)
    if($name -match '[<>:"/\\|?*]' -or $name -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\.' -or $name.EndsWith(' ') -or $name.EndsWith('.')){throw 'Choose a valid Windows ZIP filename.'}
    if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        if($full.StartsWith('\\')){throw 'Save exports to a local disk or USB drive, not a network share or mapped scanner drive.'}
        $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))
        if($drive.DriveType -eq [IO.DriveType]::Network){throw 'Save exports to a local disk or USB drive, not a network or mapped scanner drive.'}
        if($full.Length -gt 245){throw 'The export path is too long for Windows PowerShell 5.1. Choose a shorter folder or filename.'}
    }
    foreach($protected in @((Join-Path $Config.ArchiveRoot 'Reports'),(Join-Path $Config.ArchiveRoot '.ctqa'),(Join-Path $Config.ArchiveRoot 'Browse Reports'))) {
        if(Test-QaExportWithin $full $protected){throw 'Save the ZIP outside the managed Reports, Browse Reports and .ctqa folders.'}
    }
    foreach($source in @($Config.Sources)) {
        if(Test-QaExportWithin $full ([string]$source.Path)){throw 'The scanner source folders are read-only. Choose another export location.'}
    }
    Assert-QaExportNoLink $full
    $parent=[IO.Path]::GetDirectoryName($full)
    if(-not [IO.Directory]::Exists($parent)){throw 'The export folder is unavailable. Choose an existing local folder.'}
    if([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)){throw 'That export filename already exists. Choose a new name; existing files are never overwritten.'}
    return $full
}
function Assert-QaZipEntryName { param([string]$Name)
    if([string]::IsNullOrWhiteSpace($Name) -or $Name.StartsWith('/') -or $Name.Contains('\') -or $Name.Contains(':') -or @($Name.Split('/')|Where-Object{$_ -in @('','..','.')}).Count -gt 0){throw 'An unsafe ZIP entry name was rejected.'}
}
function Get-QaZipEntryPath { param($Record,$Used)
    $scanner=[string](Get-QaReportValue $Record 'ScannerPathLabel')
    if(-not $scanner){$scanner=ConvertTo-QaPathLabel (Get-QaScannerLabel ([string]$Record.Scanner) ([string](Get-QaReportValue $Record 'ScannerName')))}
    $category=Get-QaCategoryLabel ([string]$Record.Category)
    $date=Get-QaReportDate $Record
    $year=if($null -ne $date){$date.ToString('yyyy')}else{'Unknown Date'}
    $month=if($null -ne $date){$date.ToString('MM MMMM',[Globalization.CultureInfo]::InvariantCulture)}else{'Needs Review'}
    $dateText=if($null -ne $date){$date.ToString('yyyy-MM-dd')}else{'Undated'}
    $time=[string](Get-QaReportValue $Record 'ReportTime')
    $timeText=if($time -match '^\d{2}:\d{2}:\d{2}$'){$time.Replace(':','-')}else{'Time unknown'}
    $base=$scanner+' - '+$dateText+' - '+$timeText+' - '+$category
    $folder=$scanner+'/'+$year+'/'+$month+'/'+(Get-QaCategoryFolder ([string]$Record.Category))+'/'
    $path=$folder+$base+'.pdf'
    if($Used.ContainsKey($path)) {
        # Separate legitimate sessions and revisions without exposing archive hash folders.
        $counter=2
        do{$path=$folder+$base+' - Report '+$counter+'.pdf';$counter++}while($Used.ContainsKey($path))
    }
    Assert-QaZipEntryName $path
    $Used[$path]=$true
    return $path
}
function ConvertTo-QaCsvSafeText { param([string]$Text)
    if($Text -match '^[=+@\-\t\r\n]'){return "'"+$Text}
    return $Text
}
function Close-QaExportResources { param([object[]]$Resources)
    foreach($resource in $Resources){if($null -ne $resource){try{$resource.Dispose()}catch{}}}
}
function Write-QaZipText { param($Archive,[string]$Name,[string]$Text)
    $entry=$Archive.CreateEntry($Name,[IO.Compression.CompressionLevel]::Optimal)
    $stream=$entry.Open()
    try{$encoding=New-Object Text.UTF8Encoding($true);$preamble=$encoding.GetPreamble();$stream.Write($preamble,0,$preamble.Length);$bytes=$encoding.GetBytes($Text);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
}
function ConvertTo-QaHtml { param([string]$Text)
    return [Net.WebUtility]::HtmlEncode($Text)
}
function Get-QaCountTableHtml { param([string]$Label,[object[]]$Rows)
    $html=New-Object Text.StringBuilder
    [void]$html.Append('<section class="count-panel"><h2>'+(ConvertTo-QaHtml $Label)+'</h2><table><thead><tr><th scope="col">'+(ConvertTo-QaHtml $Label)+'</th><th scope="col" class="number">Reports</th></tr></thead><tbody>')
    foreach($row in @($Rows)){[void]$html.Append('<tr><td>'+(ConvertTo-QaHtml ([string]$row.Name))+'</td><td class="number">'+[int]$row.Count+'</td></tr>')}
    [void]$html.Append('</tbody></table></section>')
    return $html.ToString()
}
function ConvertTo-QaComponentText { param([object[]]$Values=@())
    $labels=@($Values|ForEach-Object{([string]$_).Trim()}|Where-Object{$_}|Select-Object -Unique)
    return $labels -join '; '
}
function Get-QaReportComponentText { param($Record)
    if([string]$Record.Category -ne 'Monthly_QA' -or -not(Get-QaReportValue $Record 'ConfirmedBy') -or -not(Get-QaReportValue $Record 'ConfirmedAt')){return ''}
    return ConvertTo-QaComponentText @(Get-QaReportValue $Record 'ConfirmedComponents' @())
}
function Get-QaSelectedCoverageRows { param($Config,[object[]]$Records)
    $months=@{};$pairs=@{}
    foreach($record in $Records) {
        $date=Get-QaReportDate $record
        if($null -ne $date){$month=$date.ToString('yyyy-MM');$months[$month]=$true;$pairs[[string]$record.Scanner+'|'+$month]=$true}
    }
    if($months.Count -eq 0){return @()}
    if(-not(Get-Command Get-QaMonthlyCoverage -ErrorAction SilentlyContinue)){throw 'The Monthly coverage helper is missing. Extract the whole updated application folder before exporting.'}
    $rows=@(Get-QaMonthlyCoverage -Config $Config -Records $Records -Months @($months.Keys|Sort-Object))
    return @($rows|Where-Object{$pairs.ContainsKey([string]$_.Scanner+'|'+[string]$_.Month)}|Sort-Object Month,Scanner)
}
function Get-QaSelectedCoverageHtml { param([object[]]$CoverageRows=@())
    $html=New-Object Text.StringBuilder
    [void]$html.Append('<section class="report-table"><h2>Monthly components represented in this export</h2><p class="muted">This view uses only the selected reports in this ZIP and the current department checklist. It is not an assessment of the full archive, a missing-test finding, or a clinical compliance conclusion.</p>')
    if($CoverageRows.Count -eq 0){[void]$html.Append('<p>No configured Monthly coverage profile is represented by the selected dated reports.</p></section>');return $html.ToString()}
    [void]$html.Append('<table><thead><tr><th scope="col">Scanner / month</th><th scope="col">Selected report coverage</th><th scope="col">Department checklist</th><th scope="col">Confirmed components</th><th scope="col">Not represented in these selected reports</th></tr></thead><tbody>')
    foreach($row in $CoverageRows) {
        $status=switch([string]$row.Status){
            'Complete' {'All configured components represented in these selected reports'}
            'Partial' {'Some configured components are not represented'}
            'ChecklistNotSet' {'Department checklist not set'}
            'NeedsConfirmation' {'Selected reports need confirmation'}
            'NoConfirmedReport' {'No confirmed Monthly report selected'}
            default {'Coverage needs review'}
        }
        $required=ConvertTo-QaComponentText @(Get-QaReportValue $row 'RequiredComponents' @())
        $confirmed=ConvertTo-QaComponentText @(Get-QaReportValue $row 'ConfirmedComponents' @())
        $missing=ConvertTo-QaComponentText @(Get-QaReportValue $row 'MissingComponents' @())
        if(-not $required){$required='Not configured'};if(-not $confirmed){$confirmed='None recorded'};if(-not $missing){$missing=$(if([string]$row.Status -eq 'ChecklistNotSet'){'Checklist not set'}else{'None'})}
        $scanner=Get-QaScannerLabel ([string]$row.Scanner) ([string](Get-QaReportValue $row 'ScannerName'))
        [void]$html.Append('<tr><td>'+(ConvertTo-QaHtml ($scanner+' / '+[string]$row.Month))+'</td><td>'+(ConvertTo-QaHtml $status)+'</td><td>'+(ConvertTo-QaHtml $required)+'</td><td>'+(ConvertTo-QaHtml $confirmed)+'</td><td>'+(ConvertTo-QaHtml $missing)+'</td></tr>')
    }
    [void]$html.Append('</tbody></table></section>');return $html.ToString()
}
function Get-QaExportHtml { param([object[]]$Records,[object[]]$Manifest,[object[]]$CoverageRows=@())
    $periods=New-Object 'System.Collections.Generic.List[object]'
    foreach($record in $Records) {
        $date=Get-QaReportDate $record
        [void]$periods.Add([pscustomobject]@{Year=$(if($null -ne $date){$date.ToString('yyyy')}else{'Unknown date'});Month=$(if($null -ne $date){$date.ToString('yyyy-MM')}else{'Unknown date'})})
    }
    $years=@($periods.ToArray()|Group-Object Year|Sort-Object Name)
    $months=New-Object 'System.Collections.Generic.List[object]'
    foreach($group in @($periods.ToArray()|Group-Object Month|Sort-Object Name)) {
        $label=[string]$group.Name
        if($label -match '^\d{4}-\d{2}$'){$label=[datetime]::ParseExact($label,'yyyy-MM',[Globalization.CultureInfo]::InvariantCulture).ToString('MMMM yyyy',[Globalization.CultureInfo]::InvariantCulture)}
        [void]$months.Add([pscustomobject]@{Name=$label;Count=$group.Count})
    }
    $scanners=@($Manifest|Group-Object Scanner|Sort-Object Name)
    $categories=@($Manifest|Group-Object QACategory|Sort-Object Name)
    $confirmed=@($Records|Where-Object{$_.Category -eq 'Monthly_QA'}).Count
    $pending=@($Records|Where-Object{$_.Category -eq 'Monthly_QA/Pending_Verification'}).Count
    $html=New-Object Text.StringBuilder
    [void]$html.Append(@'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>CT QA Report Summary</title>
<style>
:root { color-scheme: light; } * { box-sizing: border-box; } body { margin: 0; background: #f1f5f9; color: #172b43; font: 15px/1.55 "Segoe UI", Arial, sans-serif; } main { max-width: 1180px; margin: 30px auto; padding: 0 24px 40px; } header { padding: 30px; border-radius: 16px; color: #f0f7ff; background: #10243a; } .eyebrow { color: #81d4d3; text-transform: uppercase; font-size: 12px; font-weight: 600; letter-spacing: 2px; } h1 { margin: 9px 0 7px; font-size: 31px; } header p { margin: 4px 0; color: #bbd0e3; } .metrics { display: flex; flex-wrap: wrap; gap: 14px; margin: 20px 0; } .metric { flex: 1 1 190px; background: white; padding: 20px; border: 1px solid #dbe5ee; border-radius: 12px; } .metric strong { display: block; font-size: 28px; color: #155a69; } .metric span { color: #516b83; } .notice { margin: 20px 0; padding: 17px 20px; border: 1px solid #e0c68b; border-radius: 12px; background: #fff9eb; color: #684f20; } .counts { display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start; } .count-panel { flex: 1 1 250px; } section { background: white; border: 1px solid #dbe5ee; border-radius: 12px; margin: 0 0 18px; padding: 20px; } h2 { margin: 0 0 14px; font-size: 19px; } table { border-collapse: collapse; width: 100%; } th { text-align: left; color: #516b83; font-size: 12px; text-transform: uppercase; letter-spacing: .6px; background: #f5f8fb; } th, td { padding: 10px 12px; border-bottom: 1px solid #e4ebf2; vertical-align: top; } .number { text-align: right; } a { color: #12667d; text-decoration: none; font-weight: 600; } a:hover { text-decoration: underline; } .muted { color: #667d93; font-size: 12px; word-break: break-word; } .pending { color: #8a5b12; } .report-table { overflow-x: auto; } .footer { color: #667d93; font-size: 12px; } @media print { body { background: white; } main { margin: 0; padding: 0; } header { color: #172b43; background: white; border-bottom: 2px solid #155a69; padding: 10px 0; } header p { color: #516b83; } .metrics { gap: 7px; } .metric { padding: 10px; } section { break-inside: avoid; } .report-table section { break-inside: auto; } a { color: #172b43; } }
</style></head><body><main><header><div class="eyebrow">CT QA Manager Pro</div><h1>QA Report Summary</h1><p>Selected archive reports, ready to browse and share on a USB drive.</p>
'@)
    [void]$html.Append('<p>Created '+(ConvertTo-QaHtml ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))+'</p></header>')
    [void]$html.Append('<div class="metrics"><div class="metric"><strong>'+ $Records.Count+'</strong><span>Selected reports</span></div><div class="metric"><strong>'+$scanners.Count+'</strong><span>Scanners represented</span></div><div class="metric"><strong>'+$confirmed+'</strong><span>Confirmed Monthly reports</span></div><div class="metric"><strong>'+$pending+'</strong><span>Possible Monthly reports</span></div></div>')
    [void]$html.Append('<div class="notice"><strong>How to use this folder:</strong> Extract the entire ZIP first, then open this summary and click a PDF below. Keep the summary and report folders together.<br><strong>Scope:</strong> These counts describe only the selected saved archive reports. They do not establish that every report for a month or year is present or that clinical QA was completed. A missing PDF does not establish clinical noncompliance. <strong>Monthly QA - Pending Verification</strong> reports still need authorized confirmation.</div>')
    [void]$html.Append('<div class="counts">')
    [void]$html.Append((Get-QaCountTableHtml 'Years' $years))
    [void]$html.Append((Get-QaCountTableHtml 'Months' $months.ToArray()))
    [void]$html.Append((Get-QaCountTableHtml 'Scanners' $scanners))
    [void]$html.Append('</div>')
    [void]$html.Append((Get-QaCountTableHtml 'QA categories' $categories))
    [void]$html.Append((Get-QaSelectedCoverageHtml -CoverageRows $CoverageRows))
    [void]$html.Append('<section class="report-table"><h2>All selected PDFs</h2><table><thead><tr><th scope="col">Scanner</th><th scope="col">Report date</th><th scope="col">Classification</th><th scope="col">Confirmed components</th><th scope="col">Open PDF</th></tr></thead><tbody>')
    $rawById=@{};foreach($record in $Records){$rawById[[string]$record.Id]=$record}
    foreach($row in $Manifest) {
        $segments=@(([string]$row.ExportPath).Split('/')|ForEach-Object{[Uri]::EscapeDataString($_)})
        $uri=ConvertTo-QaHtml ($segments -join '/')
        $raw=$rawById[[string]$row.RecordId]
        $dateLabel=([string](Get-QaReportValue $raw 'ReportDate')+' '+[string](Get-QaReportValue $raw 'ReportTime')).Trim()
        if(-not $dateLabel){$dateLabel='Unknown date'}
        $class=if($raw.Category -eq 'Monthly_QA/Pending_Verification'){' class="pending"'}else{''}
        $componentText=Get-QaReportComponentText $raw
        if(-not $componentText){$componentText=$(if($raw.Category -eq 'Monthly_QA'){'None recorded'}else{'Not confirmed for this report'})}
        [void]$html.Append('<tr><td>'+(ConvertTo-QaHtml ([string]$row.Scanner))+'</td><td>'+(ConvertTo-QaHtml $dateLabel)+'</td><td'+$class+'>'+(ConvertTo-QaHtml ([string]$row.QACategory))+'</td><td>'+(ConvertTo-QaHtml $componentText)+'</td><td><a href="'+$uri+'">'+(ConvertTo-QaHtml ([string]$row.ReportTitle))+'</a><div class="muted">Original filename: '+(ConvertTo-QaHtml ([string]$raw.OriginalFileName))+'</div></td></tr>')
    }
    [void]$html.Append('</tbody></table></section><p class="footer">Every included PDF was verified against its indexed SHA-256 hash during export and read back from the ZIP. Report list.csv contains the full report identities and hashes. This page works offline and requires no application installation.</p></main></body></html>')
    return $html.ToString()
}
function Invoke-QaExport {
    [CmdletBinding()]param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$RecordIds,
        [Parameter(Mandatory=$true)][string]$DestinationPath,$Progress=$null
    )
    $destination=Assert-QaExportDestination $Config $DestinationPath
    $ids=@($RecordIds|Where-Object{-not [string]::IsNullOrWhiteSpace($_)}|Select-Object -Unique)
    if($ids.Count -eq 0){throw 'No reports match the current selection. Change the filters before exporting.'}
    foreach($id in $ids){if($id -notmatch '^[0-9A-Fa-f]{64}$'){throw 'The report selection is invalid. Refresh the report list and try again.'}}
    if(-not(Get-Command Get-QaDashboard -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'Archive.psm1') -ErrorAction Stop}
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archiveRoot=[IO.Path]::GetFullPath([string]$Config.ArchiveRoot)
    $reportsRoot=Join-Path $archiveRoot 'Reports';$meta=Join-Path $archiveRoot '.ctqa';$lockPath=Join-Path $meta 'archive.lock'
    foreach($path in @($archiveRoot,$reportsRoot,$meta,$lockPath,(Join-Path $meta 'state.json'))){Assert-QaExportNoLink $path}
    if(-not [IO.File]::Exists((Join-Path $meta 'state.json'))){throw 'Complete First-Time Setup before exporting reports.'}
    $summary=[pscustomobject]@{Total=$ids.Count;Exported=0;Verified=0;Failed=0;Cancelled=$false;Description=''}
    $result=[pscustomobject]@{Mode='Export';DestinationPath=$destination;Summary=$summary}
    $lock=$null;$fileStream=$null;$zip=$null;$stage='';$installed=$false
    try {
        try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'The archive is busy or unavailable. Wait for the current update or review to finish, then export again.'}
        # Fresh state under the same archive lock used by import/update/reclassification.
        $dashboard=Get-QaDashboard -Config $Config
        $byId=@{}
        foreach($r in @($dashboard.Records)) {
            if($byId.ContainsKey([string]$r.Id)){throw 'The archive index contains a repeated report identity. Run diagnostics before exporting.'}
            $byId[[string]$r.Id]=$r
        }
        $sourceNames=@{}
        foreach($source in @($Config.Sources)){
            if([string]$source.Scanner -eq 'All' -or [string]$source.Scanner -notmatch '^[A-Za-z][A-Za-z0-9_]{0,31}$'){throw 'A configured scanner has an invalid identifier.'}
            $sourceNames[[string]$source.Scanner]=[string]$source.Name
        }
        $pathLabels=@{}
        $pathRows=@($Config.Sources|ForEach-Object{[pscustomobject]@{Scanner=[string]$_.Scanner;Label=(ConvertTo-QaPathLabel (Get-QaScannerLabel ([string]$_.Scanner) ([string]$_.Name)))}})
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
        $selected=New-Object 'System.Collections.Generic.List[object]'
        foreach($id in $ids) {
            if(-not $byId.ContainsKey($id)){throw 'A selected report changed or was removed from the index. Refresh the report list before exporting.'}
            $record=$byId[$id]
            if(-not $sourceNames.ContainsKey([string]$record.Scanner) -or [string]$record.Scanner -notmatch '^[A-Za-z][A-Za-z0-9_]{0,31}$'){throw 'A selected report has an invalid or unconfigured scanner identifier.'}
            if([string]$record.Category -notin @('Daily_QA','Monthly_QA','Monthly_QA/Pending_Verification','Acceptance_Tests','Needs_Review')){throw 'A selected report has an invalid QA category.'}
            if($record.Category -eq 'Monthly_QA' -and ([string]::IsNullOrWhiteSpace([string](Get-QaReportValue $record 'ConfirmedBy')) -or [string]::IsNullOrWhiteSpace([string](Get-QaReportValue $record 'ConfirmedAt')))){throw 'A selected Monthly report has no recorded authorized confirmation. Review its classification before exporting.'}
            $displayRecord=$record|Select-Object *
            $displayRecord|Add-Member -NotePropertyName ScannerName -NotePropertyValue $sourceNames[[string]$record.Scanner] -Force
            $displayRecord|Add-Member -NotePropertyName ScannerPathLabel -NotePropertyValue $pathLabels[[string]$record.Scanner] -Force
            [void]$selected.Add($displayRecord)
        }
        $records=@(Select-QaReports -Records $selected.ToArray())
        $coverageRows=@(Get-QaSelectedCoverageRows -Config $Config -Records $records)
        if(Test-QaExportCancelled $Progress){throw [OperationCanceledException]::new('Export cancelled before writing the ZIP.')}
        # Recheck after waiting for the archive lock. No overwrite is ever allowed.
        [void](Assert-QaExportDestination $Config $destination)
        $stage=Join-Path ([IO.Path]::GetDirectoryName($destination)) ('.ctqa-export-'+[guid]::NewGuid().ToString('N')+'.partial')
        Assert-QaExportNoLink $stage
        $fileStream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $zip=New-Object IO.Compression.ZipArchive($fileStream,[IO.Compression.ZipArchiveMode]::Create,$true)
        $manifest=New-Object 'System.Collections.Generic.List[object]';$used=@{};$n=0
        foreach($r in $records) {
            if(Test-QaExportCancelled $Progress){throw [OperationCanceledException]::new('Export cancelled. No ZIP was created.')}
            $n++;Set-QaExportProgress $Progress ('Exporting '+(Get-QaReportTitle $r)) (60*$n/[math]::Max(1,$records.Count))
            $path=[IO.Path]::GetFullPath([string]$r.DestinationPath)
            if(-not(Test-QaExportWithin $path $reportsRoot) -or $path.Equals([IO.Path]::GetFullPath($reportsRoot),[StringComparison]::OrdinalIgnoreCase)){throw 'A selected report points outside the managed archive.'}
            Assert-QaExportNoLink $path
            if(-not [IO.File]::Exists($path)){throw ('The saved PDF is missing: '+$r.OriginalFileName+'. Run the integrity audit or update the archive before exporting.')}
            if([string]$r.Hash -notmatch '^[0-9A-Fa-f]{64}$'){throw 'A selected report has no valid indexed SHA-256 hash.'}
            $entryPath=Get-QaZipEntryPath $r $used
            $entry=$zip.CreateEntry($entryPath,[IO.Compression.CompressionLevel]::Optimal)
            $input=$null;$output=$null;$sha=$null
            try {
                $input=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                if($input.Length -ne [long]$r.Length){throw ('The saved PDF size has changed: '+$r.OriginalFileName+'. No ZIP was created.')}
                $output=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] 1048576
                while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0) {
                    if(Test-QaExportCancelled $Progress){throw [OperationCanceledException]::new('Export cancelled during a report transfer. No ZIP was created.')}
                    $output.Write($buffer,0,$read);[void]$sha.TransformBlock($buffer,0,$read,$buffer,0)
                }
                [void]$sha.TransformFinalBlock($buffer,0,0)
                $hash=([BitConverter]::ToString($sha.Hash)).Replace('-','')
                if($hash -ne $r.Hash){throw ('SHA-256 did not match for '+$r.OriginalFileName+'. Run the integrity audit before exporting.')}
            } finally {Close-QaExportResources -Resources @($output,$input,$sha)}
            [void]$manifest.Add([pscustomobject]@{RecordId=[string]$r.Id;Scanner=(Get-QaScannerLabel ([string]$r.Scanner) ([string](Get-QaReportValue $r 'ScannerName')));ReportTitle=(Get-QaReportTitle $r);OriginalFileName=[string]$r.OriginalFileName;ExportPath=$entryPath;QACategory=(Get-QaCategoryLabel ([string]$r.Category));Hash=[string]$r.Hash;ReportDate=[string]$r.ReportDate;ReportTime=[string]$r.ReportTime;ConfirmedComponents=(Get-QaReportComponentText $r)})
        }
        $csvRows=@($manifest.ToArray()|ForEach-Object{
            $cells=[ordered]@{}
            foreach($property in $_.PSObject.Properties){$cells[$property.Name]=ConvertTo-QaCsvSafeText ([string]$property.Value)}
            [pscustomobject]$cells
        })
        $csv=@($csvRows|ConvertTo-Csv -NoTypeInformation)-join "`r`n"
        Write-QaZipText $zip 'Report list.csv' $csv
        Write-QaZipText $zip 'QA Report Summary.html' (Get-QaExportHtml -Records $records -Manifest $manifest.ToArray() -CoverageRows $coverageRows)
        $readme=@(
            'CT QA Manager Pro - selected report export',
            ('Created: '+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')),
            ('Reports selected and exported: '+$records.Count),
            '',
            'Unzip the entire ZIP, then open QA Report Summary.html to browse and open the PDFs offline.',
            'Keep the summary and report folders together on your computer or USB drive.',
            'This ZIP contains only the saved archive reports selected by the user.',
            'It is not proof that every report for a month is present or that clinical QA was completed.',
            'Missing PDFs and unavailable scanner connections do not establish clinical noncompliance.',
            'Monthly QA - Pending Verification means the report has not been confirmed as Monthly QA.',
            'Report list.csv preserves report identities, original filenames, categories, dates, confirmed components and SHA-256 hashes.',
            'The Monthly component summary uses only selected reports and the current department checklist.',
            'It does not assess the whole archive or establish clinical compliance.',
            'A leading apostrophe in a text cell prevents spreadsheet formulas from running.',
            'Each included PDF was checked against its archive hash while writing and after reading the ZIP.',
            'The scanner originals and saved archive PDFs were not modified.'
        )-join "`r`n"
        Write-QaZipText $zip 'ReadMe.txt' $readme
        $zip.Dispose();$zip=$null;$fileStream.Flush($true);$fileStream.Dispose();$fileStream=$null
        if(Test-QaExportCancelled $Progress){throw [OperationCanceledException]::new('Export cancelled. No ZIP was created.')}
        # Read every compressed PDF back from the completed staging ZIP before publication.
        $fileStream=[IO.File]::Open($stage,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $zip=New-Object IO.Compression.ZipArchive($fileStream,[IO.Compression.ZipArchiveMode]::Read,$true)
        $n=0
        foreach($row in $manifest) {
            if(Test-QaExportCancelled $Progress){throw [OperationCanceledException]::new('Export cancelled during ZIP verification. No ZIP was created.')}
            $n++;Set-QaExportProgress $Progress ('Verifying exported report '+$n+' of '+$records.Count) (60+40*$n/[math]::Max(1,$records.Count))
            $entry=$zip.GetEntry($row.ExportPath)
            if($null -eq $entry){throw 'A report entry is missing from the staged ZIP.'}
            $input=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
            try {
                $buffer=New-Object byte[] 1048576
                while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0) {
                    if(Test-QaExportCancelled $Progress){throw [OperationCanceledException]::new('Export cancelled during ZIP verification. No ZIP was created.')}
                    [void]$sha.TransformBlock($buffer,0,$read,$buffer,0)
                }
                [void]$sha.TransformFinalBlock($buffer,0,0);$hash=([BitConverter]::ToString($sha.Hash)).Replace('-','')
                if($hash -ne $row.Hash){throw 'An exported PDF failed readback verification. No ZIP was created.'}
            } finally{Close-QaExportResources -Resources @($input,$sha)}
            $summary.Verified++
        }
        if($zip.Entries.Count -ne ($records.Count+3)){throw 'The staged ZIP contains an unexpected report count.'}
        $zip.Dispose();$zip=$null;$fileStream.Dispose();$fileStream=$null
        if(Test-QaExportCancelled $Progress){throw [OperationCanceledException]::new('Export cancelled before completion. No ZIP was created.')}
        [void](Assert-QaExportDestination $Config $destination)
        Assert-QaExportNoLink $stage
        [IO.File]::Move($stage,$destination);$installed=$true;$summary.Exported=$records.Count
        $summary.Description=($summary.Exported.ToString()+' selected reports exported and verified. The ZIP includes an offline summary and report list.')
        Set-QaExportProgress $Progress $summary.Description 100
    } catch {
        $summary.Exported=0
        if((Test-QaExportCancelled $Progress) -or $_.Exception -is [OperationCanceledException] -or $_.Exception.InnerException -is [OperationCanceledException]){$summary.Cancelled=$true;$summary.Description='Export cancelled safely. No ZIP was created.'}
        else{$summary.Failed=1;$summary.Description='Export not created. '+$_.Exception.Message}
        Set-QaExportProgress $Progress $summary.Description 0
    } finally {
        Close-QaExportResources -Resources @($zip,$fileStream)
        try { if(-not $installed -and $stage -and [IO.File]::Exists($stage)){Assert-QaExportNoLink $stage;[IO.File]::Delete($stage)} }
        catch { $summary.Description+=' A temporary partial file could not be removed; it is not a completed ZIP.' }
        finally { Close-QaExportResources -Resources @($lock) }
    }
    return $result
}
Export-ModuleMember -Function Select-QaReports,Get-QaReportTitle,Invoke-QaExport
