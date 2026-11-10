Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
function Get-QaReviewValue($Object,[string]$Name,$Default='') {
    if($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]){return $Object.$Name};return $Default
}
function Get-QaReviewKind([string]$Type) {
    switch -Regex ($Type) {
        '^(Connection|SourceUnavailable|SourceMissing|CopyFailed|Integrity|Audit|Recovery)$' {return [pscustomobject]@{Category='Files';Priority=0;Label='Connection or file check';NextStep='Check the connection result and update reports. For a file error, keep the original and inspect the related saved copy.'}}
        '^(Classification|MonthlyReview)$' {return [pscustomobject]@{Category='Reports';Priority=1;Label='Reports need a label or confirmation';NextStep='Open the selected saved PDF, check its contents, then confirm its report type only if you are authorized.'}}
        '^(DailyGap|DailyReview|CoverageUnknown)$' {return [pscustomobject]@{Category='Dates';Priority=2;Label='Daily archive coverage to check';NextStep='Update reports, then check pending report labels for these dates. Verify the actual daily schedule, active-from date and approved exceptions in scanner settings. A missing saved PDF does not prove QA was not performed.'}}
        '^(MonthlyGap|MonthlyPending|MonthlyComponents|MonthlyComponentsMissing|MonthlyChecklist|ChecklistNotSet|MonthlyChecklistNotSet)$' {return [pscustomobject]@{Category='Monthly';Priority=3;Label='Monthly evidence or checklist to check';NextStep='Set the department-approved checklist and due day in scanner settings. Review the monthly PDFs and confirm only the items they actually document. One PDF or several PDFs may supply the evidence.'}}
        '^(DuplicateName|MultipleSessions)$' {return [pscustomobject]@{Category='Information';Priority=5;Label='Preserved reports: information';NextStep='Multiple reports or matching filenames can be legitimate. Copies remain preserved; compare them only if needed. No deletion is required.'}}
        default {return [pscustomobject]@{Category='Other';Priority=4;Label='Archive item to review';NextStep='Open the details and inspect the related archive item. A review item is not a clinical QA failure.'}}
    }
}
function Get-QaReviewGroups {
    [CmdletBinding()]param([object[]]$Issues=@(),[object[]]$Sources=@())
    $names=@{};foreach($s in $Sources){$names[[string]$s.Scanner]=[string]$s.Name}
    $buckets=@{}
    foreach($issue in $Issues){
        if($null -eq $issue){continue}
        $scanner=[string](Get-QaReviewValue $issue Scanner);$type=[string](Get-QaReviewValue $issue Type);$key=$scanner+'|'+$type
        if(-not $buckets.ContainsKey($key)){$buckets[$key]=New-Object 'System.Collections.Generic.List[object]'}
        [void]$buckets[$key].Add($issue)
    }
    $groups=New-Object 'System.Collections.Generic.List[object]'
    foreach($key in $buckets.Keys){
        $items=@($buckets[$key].ToArray());$first=$items[0];$scanner=[string](Get-QaReviewValue $first Scanner);$kind=Get-QaReviewKind ([string](Get-QaReviewValue $first Type))
        $name='Archive';if($names.ContainsKey($scanner)){$name=$names[$scanner]}elseif($scanner){$name=$scanner.Replace('_',' ')}
        [void]$groups.Add([pscustomobject]@{Key=$key;Scanner=$scanner;Category=$kind.Category;Priority=$kind.Priority;Count=$items.Count;Message=($name+' - '+$items.Count+' '+$kind.Label.ToLowerInvariant());TypeLabel=$kind.NextStep;NextStep=$kind.NextStep;Items=[object[]]$items})
    }
    return @($groups.ToArray()|Sort-Object Priority,Scanner,Key)
}
function Select-QaReviewGroups {
    [CmdletBinding()]param([object[]]$Groups=@(),[ValidateSet('All','Files','Reports','Dates','Monthly','Information')][string]$Category='All')
    if($Category -eq 'All'){return @($Groups)}
    return @($Groups|Where-Object Category -eq $Category)
}
function Test-QaReportPending {
    [CmdletBinding()]param($Record)
    $category=[string](Get-QaReviewValue $Record Category)
    return ($category -in @('Needs_Review','Monthly_QA/Pending_Verification') -or ([string](Get-QaReviewValue $Record ClassificationBasis) -like 'Provisional*' -and -not [string](Get-QaReviewValue $Record ConfirmedBy)))
}
Export-ModuleMember -Function Get-QaReviewGroups,Select-QaReviewGroups,Test-QaReportPending
