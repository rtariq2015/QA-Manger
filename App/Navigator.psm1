Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
function ConvertTo-QaNavigatorHtml {param($Text) return [Net.WebUtility]::HtmlEncode([string]$Text)}
function Write-QaNavigator {
    [CmdletBinding()]param($Paths,$Ledger,$Records,$Summary)
    $byId=@{};foreach($record in @($Records)){$byId[[string]$record.Id]=$record}
    $rows=New-Object Text.StringBuilder;$csv=New-Object 'System.Collections.Generic.List[object]'
    foreach($entry in @($Ledger.Records|Sort-Object RelativePath)) {
        if(-not $byId.ContainsKey([string]$entry.ReportId)){continue};$record=$byId[[string]$entry.ReportId]
        $path=Join-Path $Paths.Browse ([string]$entry.RelativePath)
        if(-not [IO.File]::Exists($path)){continue}
        $parts=([string]$entry.RelativePath).Replace('\','/').Split('/')
        if(@($parts|Where-Object{$_ -in @('..','.')}).Count){throw 'Invalid navigator link.'}
        $href=($parts|ForEach-Object{[Uri]::EscapeDataString($_)}) -join '/'
        $scanner=ConvertTo-QaNavigatorHtml $record.ScannerName;$date=ConvertTo-QaNavigatorHtml $record.ReportDate
        $original=ConvertTo-QaNavigatorHtml $record.OriginalFileName
        $labels=@{'Daily_QA'='Daily QA';'Monthly_QA'='Monthly QA / Confirmed';'Monthly_QA/Pending_Verification'='Monthly QA / Needs review';'Needs_Review'='Needs review';'Acceptance_Tests'='Acceptance tests'}
        $category=ConvertTo-QaNavigatorHtml $labels[[string]$record.Category]
        $tagClass=if($record.Category -in @('Monthly_QA/Pending_Verification','Needs_Review')){'tag pending'}else{'tag'}
        [void]$rows.Append('<tr><td>'+$scanner+'</td><td>'+$date+'</td><td><a href="'+$href+'">'+$original+'</a><small>'+ (ConvertTo-QaNavigatorHtml $record.ReportTime)+'</small></td><td><span class="'+$tagClass+'">'+$category+'</span></td></tr>')
        $name=[string]$record.OriginalFileName;if($name -match '^[=+@\-\t\r]'){$name="'"+$name}
        [void]$csv.Add([pscustomobject]@{Scanner=$record.ScannerName;Date=$record.ReportDate;Time=$record.ReportTime;OriginalFilename=$name;Category=$record.Category;RelativePath=$entry.RelativePath;SHA256=$entry.Hash})
    }
    $stamp=ConvertTo-QaNavigatorHtml ((Get-Date).ToString('yyyy-MM-dd HH:mm zzz'))
    $note=ConvertTo-QaNavigatorHtml $Summary.Description
    $count=$csv.Count
    $html=@"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:"><title>CT QA | Report library</title>
<style>*{box-sizing:border-box}body{margin:0;background:#f4f7fb;color:#122438;font:15px/1.6 'Segoe UI',Arial,sans-serif}header{background:#102a43;color:white;padding:38px max(5vw,24px)}.eyebrow{font-size:11px;letter-spacing:2px;color:#69ddc5}h1{font-size:38px;letter-spacing:-1px;margin:8px 0}header p{color:#c5d6e5;max-width:720px}main{max-width:1200px;margin:30px auto;padding:0 24px}.stats{display:flex;gap:16px;flex-wrap:wrap}.card{background:white;border:1px solid #dce5ee;border-radius:16px;padding:22px;flex:1;min-width:200px}.number{font-size:34px;font-weight:650;color:#007e70}label{display:block;font-weight:600;margin-bottom:8px}input{width:100%;padding:14px 16px;border:1px solid #bdccd9;border-radius:9px;font:inherit}table{width:100%;border-collapse:collapse;background:white}th{text-align:left;padding:16px;background:#eaf0f6;font-size:12px;color:#50687e}td{padding:18px 16px;border-bottom:1px solid #e6edf4;vertical-align:top}a{color:#006b87;text-decoration:none;font-weight:600}a:hover{text-decoration:underline}small{display:block;color:#688095}.tag{font-size:12px;background:#e6f4f0;border-radius:6px;padding:5px 8px;display:inline-block}.pending{background:#fff0d7;color:#805500}.library{border:1px solid #dce5ee;border-radius:14px;overflow:auto;margin-top:20px}.note{padding:16px 20px;border-left:4px solid #d59a38;background:#fff7e6;margin:24px 0}.toolbar{margin:28px 0 12px}footer{color:#60778a;margin:28px 0;font-size:12px}@media(max-width:650px){h1{font-size:28px}th,td{padding:12px 8px}body{font-size:13px}}@media print{header{background:white;color:#122438;padding:10px}header p{color:#445}.toolbar{display:none}.card{padding:10px}main{padding:0}}</style></head><body>
<header><div class="eyebrow">CT QA MANAGER / OFFLINE LIBRARY</div><h1>Your reports. Ready to browse.</h1><p>Find PDFs by scanner, date or report type. Open files directly, or use these same folders in Windows Explorer. Keep the entire Browse Reports folder together when copying it.</p></header>
<main><div class="stats"><div class="card"><div class="number">$count</div>readable PDFs</div><div class="card"><strong>Last refreshed</strong><div>$stamp</div><small>A saved snapshot; updates require the application.</small></div><div class="card"><strong>Works offline</strong><div>No installation or account needed</div><a href="Report%20list.csv">Download report list</a></div></div>
<div class="note">$note<br>Pending verification stays separate from confirmed Monthly reports. Report presence and printed results do not establish clinical QA completion.</div>
<div class="toolbar"><label for="search">Find a report</label><input id="search" type="search" placeholder="Try a scanner, 2026-11, Monthly, or part of a filename"><p id="count" aria-live="polite">$count reports shown</p></div>
<div class="library"><table><thead><tr><th>SCANNER</th><th>REPORT DATE</th><th>ORIGINAL REPORT / OPEN PDF</th><th>CLASSIFICATION</th></tr></thead><tbody id="reports">$rows</tbody></table></div>
<footer>Files retain their original PDF contents. Separate PDFs and revisions are preserved. This readable folder is a convenience copy; keep a verified full backup on approved separate storage.</footer></main>
<script>document.getElementById('search').addEventListener('input',function(){var q=this.value.trim().toLowerCase(),n=0;document.querySelectorAll('#reports tr').forEach(function(row){var show=row.textContent.toLowerCase().indexOf(q)!==-1;row.hidden=!show;if(show)n++;});document.getElementById('count').textContent=n+' reports shown';});</script></body></html>
"@
    foreach($name in @('Open Reports.html','Report list.csv')) {
        $target=Join-Path $Paths.Browse $name
        if([IO.File]::Exists($target) -and (([IO.File]::GetAttributes($target) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'The generated navigator uses a linked path.'}
        $temp=$target+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        $content=if($name -like '*.html'){$html}else{(@($csv.ToArray()|ConvertTo-Csv -NoTypeInformation) -join "`r`n")}
        try{[IO.File]::WriteAllText($temp,$content,(New-Object Text.UTF8Encoding($true)));if([IO.File]::Exists($target)){[IO.File]::Replace($temp,$target,($temp+'.bak'));[IO.File]::Delete($temp+'.bak')}else{[IO.File]::Move($temp,$target)}}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    }
}
Export-ModuleMember -Function Write-QaNavigator
