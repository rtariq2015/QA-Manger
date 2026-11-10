[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$FixtureRoot,[string]$ProductRoot='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if(-not $ProductRoot){$ProductRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
& (Join-Path $PSScriptRoot 'New-WebFixture.ps1') -FixtureRoot $FixtureRoot -ProductRoot $ProductRoot
$FixtureRoot=[IO.Path]::GetFullPath($FixtureRoot)
Import-Module (Join-Path $FixtureRoot 'App/Archive.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
$cfg=Read-QaConfig $FixtureRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'New-WebFixture.ps1'),[ref]$null,[ref]$null)
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-WebDemoPdf'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
$templates=@{}
foreach($definition in @(@('daily','Constancy',5000),@('large','Constancy',95000),@('hint','Monthly QA',5000))){
    $file=Join-Path $FixtureRoot ('fixture-template-'+$definition[0]+'.pdf')
    [void](New-WebDemoPdf $file 'Synthetic large-library scanner' $definition[1] $definition[2])
    $templates[$definition[0]]=[pscustomobject]@{Path=$file;Hash=(Get-FileHash $file -Algorithm SHA256).Hash;Length=(Get-Item $file).Length}
}
# Populate a real archive efficiently, using the core's path/identity/classification
# rules and a single index commit. No 1,367 repeated full-library imports.
$details=& (Get-Module Archive) {
    param($Config,$Templates)
    $paths=Get-QaPaths $Config;$state=Read-QaState $paths
    $ordinary=@($state.Records|Where-Object Category -eq 'Daily_QA')[0]
    $legacy=@($state.Records|Where-Object{$_.ConfirmedBy})[0]
    $legacyReview=@($state.Reviews|Where-Object RecordId -eq $legacy.Id)[0]
    $records=New-Object 'Collections.Generic.List[object]';foreach($r in $state.Records){[void]$records.Add($r)}
    $reviews=New-Object 'Collections.Generic.List[object]';foreach($r in $state.Reviews){[void]$reviews.Add($r)}
    $expected=New-Object 'Collections.Generic.List[object]';$organization=New-Object 'Collections.Generic.List[object]';$history=New-Object 'Collections.Generic.List[object]'
    $groups=@(
        [pscustomobject]@{Kind='daily';Count=997;Filename='Quality_Constancy';Template='daily';Decision='Automatic';Category='Daily'},
        [pscustomobject]@{Kind='explicitMonthly';Count=50;Filename='Monthly_Constancy';Template='large';Decision='Automatic';Category='Monthly'},
        [pscustomobject]@{Kind='sizeOnly';Count=75;Filename='Quality_Constancy';Template='large';Decision='Pending';Category='Monthly'},
        [pscustomobject]@{Kind='textHint';Count=40;Filename='Quality_Constancy';Template='hint';Decision='Pending';Category='Monthly'},
        [pscustomobject]@{Kind='unknown';Count=100;Filename='Unlabelled';Template='daily';Decision='Pending';Category='Other'},
        [pscustomobject]@{Kind='legacyReviewed';Count=50;Filename='Monthly_Constancy';Template='large';Decision='Approved';Category='Monthly'},
        [pscustomobject]@{Kind='sidecarApproved';Count=30;Filename='Quality_Constancy';Template='large';Decision='Approved';Category='Monthly'},
        [pscustomobject]@{Kind='sidecarDisapproved';Count=19;Filename='Quality_Constancy';Template='daily';Decision='Disapproved';Category='Other'}
    )
    $n=0;$start=(Get-Date).Date.AddDays(-1).AddHours(6)
    foreach($group in $groups){for($i=0;$i -lt $group.Count;$i++){
        $n++;$source=$Config.Sources[$n % @($Config.Sources).Count];$stamp=$start.AddSeconds(31*$n);$template=$Templates[$group.Template]
        $name=$group.Filename+'_'+$stamp.ToString('yyyy-MM-dd_HH-mm-ss')+'.pdf';$sourcePath=Join-Path $source.Path $name
        [IO.File]::Copy($template.Path,$sourcePath,$false);$info=Get-Item -LiteralPath $sourcePath
        $hint=if($group.Kind -eq 'textHint'){'Monthly MTF'}else{''}
        $cls=Get-QaClassification $source $name $info.Length $hint
        $record=$(if($group.Kind -eq 'legacyReviewed'){$legacy}else{$ordinary})|Select-Object *
        $record.Scanner=$source.Scanner;$record.SourcePath=$sourcePath;$record.SourceKey=Get-QaSourceKey $source.Scanner $sourcePath
        $record.Hash=$template.Hash;$record.Id=Get-QaHashText ($record.SourceKey+'|'+$record.Hash);$record.OriginalFileName=$name
        $record.ReportDate=$cls.ReportDate;$record.ReportTime=$cls.ReportTime;$record.Length=$info.Length;$record.SourceLastWriteUtc=$info.LastWriteTimeUtc.ToString('o')
        if($group.Kind -ne 'legacyReviewed'){
            $record.Category=$cls.Category;$record.ClassificationBasis=$cls.ClassificationBasis;$record.ConfirmedBy='';$record.ConfirmedAt='';$record.ConfirmedComponents=@()
            foreach($field in @('ReviewDecision','LastReviewId')){if($null -ne $record.PSObject.Properties[$field]){$record.PSObject.Properties.Remove($field)}}
        }else{$record.LastReviewId=[guid]::NewGuid().ToString('N')}
        $record.RelativePath=Get-QaRelativeTarget $record $record.Hash;$record.DestinationPath=Join-Path $paths.Reports $record.RelativePath
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($record.DestinationPath));[IO.File]::Copy($sourcePath,$record.DestinationPath,$false)
        $record.DestinationLastWriteUtc=(Get-Item -LiteralPath $record.DestinationPath).LastWriteTimeUtc.ToString('o')
        [void]$records.Add($record)
        if($group.Kind -eq 'legacyReviewed'){
            $review=$legacyReview|Select-Object *;$review.ReviewId=$record.LastReviewId;$review.RecordId=$record.Id;$review.Hash=$record.Hash
            $review.NewPath=$record.DestinationPath;$review.NewRelativePath=$record.RelativePath;$review.PreviousPath=$record.DestinationPath;$review.PreviousRelativePath=$record.RelativePath
            [void]$reviews.Add($review)
        }
        if($group.Kind -like 'sidecar*'){
            $revision=[guid]::NewGuid().ToString('N');$now=[datetime]::UtcNow.ToString('o')
            $entry=[pscustomobject]@{id=$record.Id;hash=$record.Hash;revision=$revision;decision=$group.Decision;category=$group.Category;time=$now;actor='Synthetic organization actor';actorKind='Synthetic test actor; not a verified clinical reviewer'}
            [void]$organization.Add($entry)
            [void]$history.Add([pscustomobject]@{reviewId=$revision;recordId=$record.Id;hash=$record.Hash;action=$(if($group.Decision -eq 'Approved'){'Approve'}else{'Disapprove'});time=$now;actor=$entry.actor;actorKind=$entry.actorKind;before=$null;after=$entry;scope='File organization only'})
        }
        [void]$expected.Add([pscustomobject]@{Id=$record.Id;Kind=$group.Kind;Decision=$group.Decision;Category=$group.Category;Hash=$record.Hash;SourcePath=$record.SourcePath;DestinationPath=$record.DestinationPath;ConfirmedBy=$record.ConfirmedBy;ConfirmedAt=$record.ConfirmedAt;ConfirmedComponents=@($record.ConfirmedComponents)})
    }}
    $state.Records=@($records.ToArray());$state.Reviews=@($reviews.ToArray());Save-QaState $state $paths
    [pscustomobject]@{Expected=@($expected.ToArray());Organization=[pscustomobject]@{Version=1;Records=@($organization.ToArray());History=@($history.ToArray())}}
} $cfg $templates
[IO.File]::WriteAllText((Join-Path $cfg.ArchiveRoot '.ctqa/organization.json'),($details.Organization|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true))
$coreState=[IO.File]::ReadAllText((Join-Path $cfg.ArchiveRoot '.ctqa/state.json'))|ConvertFrom-Json
$clinical=@($coreState.Records|Select-Object Id,Hash,Category,ClassificationBasis,ConfirmedBy,ConfirmedAt,ConfirmedComponents,ReviewDecision,LastReviewId)
$metadata=[pscustomobject]@{Synthetic=$true;CoreRecords=$clinical;CoreReviews=@($coreState.Reviews);RecordCount=1367;ExpectedTotals=[pscustomobject]@{Automatic=1050;Pending=217;Approved=81;Disapproved=19};AppRoot=$FixtureRoot;ArchiveRoot=$cfg.ArchiveRoot;Expected=$details.Expected;CoreStateSHA256=(Get-FileHash (Join-Path $cfg.ArchiveRoot '.ctqa/state.json')).Hash;OrganizationSHA256=(Get-FileHash (Join-Path $cfg.ArchiveRoot '.ctqa/organization.json')).Hash}
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'large-fixture-baseline.json'),($metadata|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding $true))
foreach($template in $templates.Values){[IO.File]::Delete($template.Path)}
Write-Output 'Created 1,367 synthetic PDFs with automatic, uncertain, legacy-reviewed and saved-decision cases.'
