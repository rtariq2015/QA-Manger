# Native WPF front end. Windows PowerShell 5.1; no execution-policy changes.
[CmdletBinding()]
param([switch]$ValidateLayout,[switch]$PortableLaunch,[switch]$DemoPreview,[string]$ScreenshotPath="",[ValidateSet('Dashboard','Advanced','Review','Reports','Updates','Queue')][string]$PreviewPage='Dashboard')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:AppRoot = Split-Path -Parent $PSScriptRoot
$script:Busy = $false
$script:Worker = $null
$script:Dashboard = $null
$script:PendingOnly = $false
$script:UpdatingFilters = $false
$script:FilteredReports = @()
$script:SelectedYears = @()
$script:LastExportPath = ''
$script:ReadingRecordId = ''
$script:BrowsePreviousStatus = ''
$script:BrowseOpenOnComplete = $false
$script:CurrentMode = ''
$script:PendingDecisions = @()
$script:ReconnectCredentials = @{}
$script:AfterReconnect = ''
$script:ConnectionFeedback=@{}
$script:AttemptedCredentials=@{}
$script:RememberPending=@{}
$script:ReconnectTarget=''
$script:ReviewGroups=@()
$script:ReviewQueue=$null
$script:SessionReviewer=''
$script:PreparedUpdate=$null
$script:UpdateLaunching=$false
$script:AnalysisPending=0
$script:ConsoleHandle = [intptr]::Zero
$script:StartupHandled = $false
$script:LastMonitor=[datetime]::Now
$script:LastAnalysis=[datetime]::MinValue
$script:DemoPreview=[bool]$DemoPreview

function Value-Or {
    param($Object,[string]$Name,$Default='')
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { return $Object.$Name }
    return $Default
}

function Get-CategoryLabel {
    param([string]$Category)
    $labels=@{'Daily_QA'='Daily QA';'Monthly_QA'='Monthly QA report - confirmed';'Monthly_QA/Pending_Verification'='Possible Monthly QA - needs confirmation';'Acceptance_Tests'='Acceptance tests';'Needs_Review'='Report type needs confirmation'}
    if($labels.ContainsKey($Category)){return $labels[$Category]}
    return $Category.Replace('_',' ')
}
function Add-RecordLabels {
    param($Rows)
    $scannerNames=@{'CT_Edge'='CT Edge';'CT_Flash'='CT Flash';'MDP_Building'='MDP Building'}
    if($null -ne (Get-Variable -Name Config -Scope Script -ErrorAction SilentlyContinue)){foreach($source in @($script:Config.Sources)){$scannerNames[[string]$source.Scanner]=[string]$source.Name}}
    foreach($row in @($Rows)) {
        if($null -eq $row){continue}
        $scanner=[string](Value-Or $row Scanner)
        $name=$scanner.Replace('_',' ')
        if($scannerNames.ContainsKey($scanner)){$name=$scannerNames[$scanner]}
        Add-Member -InputObject $row -NotePropertyName ScannerName -NotePropertyValue $name -Force
        Add-Member -InputObject $row -NotePropertyName CategoryLabel -NotePropertyValue $(if([string](Value-Or $row Category) -eq 'Daily_QA' -and (Test-QaReportPending $row)){'Daily QA type - needs confirmation'}else{Get-CategoryLabel ([string](Value-Or $row Category))}) -Force
        $status=Get-QaReportReviewStatus $row
        Add-Member -InputObject $row -NotePropertyName ReviewStatusLabel -NotePropertyValue $(if($status -eq 'Pending'){'Pending review'}else{$status}) -Force
        Add-Member -InputObject $row -NotePropertyName ReviewStatusColor -NotePropertyValue $(switch($status){'Pending'{'#F4C779'}'Accepted'{'#45D8AE'}'Declined'{'#9FB5CA'}default{'#8FAAC4'}}) -Force
        if($status -eq 'Declined' -and $row.Category -eq 'Needs_Review'){$row.CategoryLabel='Other report / reviewed'}
        if($null -ne $row.PSObject.Properties['Id']){Add-Member -InputObject $row -NotePropertyName ReportTitle -NotePropertyValue (Get-QaReportTitle -Record $row) -Force}
    }
}
function Add-AttentionLabels {
    param($Rows)
    $labels=@{MonthlyReview='Possible Monthly QA - needs confirmation';Classification='Report type needs confirmation';DuplicateName='Matching names preserved';MultipleSessions='Multiple testing sessions';CoverageUnknown='Coverage start date needed';DailyReview='Daily coverage awaits classification';DailyGap='Daily report not found in archive';MonthlyGap='Monthly report not confirmed';MonthlyPending='Monthly report awaiting verification';MonthlyComponentsMissing='Monthly QA checklist items still missing';MonthlyComponents='Monthly QA checklist items still missing';MonthlyChecklist='Department checklist is not set';ChecklistNotSet='Department checklist is not set';MonthlyChecklistNotSet='Department checklist is not set';Connection='Scanner connection';SourceUnavailable='Scanner unavailable';SourceMissing='Source folder not found';CopyFailed='Report could not be copied';Integrity='Archive integrity needs review';Audit='Archive integrity';Deferred='Report deferred';Recovery='Interrupted copy recovery'}
    foreach($row in @($Rows)) {
        if($null -eq $row){continue}
        $type=[string](Value-Or $row Type)
        $label=([regex]::Replace($type,'([a-z])([A-Z])','$1 $2')).Replace('_',' ')
        if($labels.ContainsKey($type)){$label=$labels[$type]}
        $accent='#D7B56B'
        if($type -in @('MultipleSessions','DuplicateName','ChecklistNotSet','MonthlyChecklistNotSet','MonthlyChecklist')){$label='Information / '+$label;$accent='#49BFB8'}
        Add-Member -InputObject $row -NotePropertyName TypeLabel -NotePropertyValue $label -Force
        Add-Member -InputObject $row -NotePropertyName AccentColor -NotePropertyValue $accent -Force
    }
}

function Show-Note {
    param([string]$Text,[string]$Title='CT QA Manager Pro',[bool]$IsError=$false)
    if($script:DemoPreview){throw ($Title+': '+$Text)}
    $icon = [System.Windows.MessageBoxImage]::Information
    if ($IsError) { $icon = [System.Windows.MessageBoxImage]::Warning }
    $owner=$script:Window;if($null -ne $script:ReviewQueue -and $script:ReviewQueue.Window.IsVisible){$owner=$script:ReviewQueue.Window}
    [void][System.Windows.MessageBox]::Show($owner,$Text,$Title,[System.Windows.MessageBoxButton]::OK,$icon)
}
function Load-Window {
    param([string]$Xaml)
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
    try { return [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
}

function Fit-Window {
    param([System.Windows.Window]$Window)
    $area=[System.Windows.SystemParameters]::WorkArea
    $maxWidth=[math]::Max(540,$area.Width-24)
    $maxHeight=[math]::Max(380,$area.Height-24)
    $requestedWidth=[double]$Window.Width
    $requestedHeight=[double]$Window.Height
    # Native layouts and scroll viewers retain readable text at high display scaling.
    $Window.MinWidth=[math]::Min([double]$Window.MinWidth,$maxWidth)
    $Window.MinHeight=[math]::Min([double]$Window.MinHeight,$maxHeight)
    $Window.Width=[math]::Min($requestedWidth,$maxWidth)
    $Window.Height=[math]::Min($requestedHeight,$maxHeight)
    $Window.MaxWidth=$area.Width
    $Window.MaxHeight=$area.Height
}

function New-Dialog {
    param([string]$Title,[string]$Content,[int]$Width=780,[int]$Height=520)
    $safeTitle = [Security.SecurityElement]::Escape($Title)
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="$safeTitle" Width="$Width" Height="$Height" MinWidth="540" MinHeight="350" WindowStartupLocation="CenterOwner" Background="#0F192B" Foreground="#EAF0FC" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True"><Grid Margin="25">$Content</Grid></Window>
"@
    $dialog = Load-Window $xaml
    $dialog.Owner = $script:Window
    Fit-Window $dialog
    # Reuse the actual production WPF styles for every dialog.
    foreach ($key in $script:Window.Resources.Keys) { $dialog.Resources[$key] = $script:Window.Resources[$key] }
    return $dialog
}
function Choose-Folder {
    param([string]$Description,[string]$Initial='')
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $picker.Description=$Description; $picker.ShowNewFolderButton=$true
        if ($Initial) { $picker.SelectedPath=$Initial }
        if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $picker.SelectedPath }
        return ''
    } finally { $picker.Dispose() }
}
function Safe-Open {
    param([string]$Path,[switch]$Folder,[switch]$Diagnostics)
    if ([string]::IsNullOrWhiteSpace($Path)) { Show-Note 'No saved report or folder is linked to this item. Review the details and scanner history.'; return }
    try {
        $base = [IO.Path]::GetFullPath((Join-Path $script:Config.ArchiveRoot 'Reports')).TrimEnd([char[]]'\/')
        if ($Diagnostics -and $Folder) { $base = [IO.Path]::GetFullPath($script:Config.ArchiveRoot).TrimEnd([char[]]'\/') }
        if($Folder){$browse=[IO.Path]::GetFullPath((Join-Path $script:Config.ArchiveRoot 'Browse Reports')).TrimEnd([char[]]'\/');$candidate=[IO.Path]::GetFullPath($Path);if($candidate -eq $browse -or $candidate.StartsWith(($browse+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)){$base=$browse}}
        $target = [IO.Path]::GetFullPath($Path)
        if ($target -ne $base -and -not $target.StartsWith(($base+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) { throw 'Only saved archive reports and application diagnostics can be opened from this control.' }
        if (-not (Test-Path -LiteralPath $target)) { Show-Note 'This saved path is not available. Run an update or integrity audit, then review the activity history.'; return }
        $ancestor=$target
        while($ancestor) {
            if(([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'This archive item uses a shortcut or linked folder. Choose an ordinary archive folder and run an integrity audit.'}
            $parent=[IO.Path]::GetDirectoryName($ancestor)
            if($parent -eq $ancestor){break}
            $ancestor=$parent
        }
        if ($Folder) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"'+$target+'"') | Out-Null }
        else {
            if ([IO.Path]::GetExtension($target) -ne '.pdf') { throw 'Choose a saved PDF report.' }
            Start-Process -FilePath $target | Out-Null
        }
    } catch { Show-Note $_.Exception.Message 'Cannot open archive item' $true }
}
function Show-Page {
    param([ValidateSet('Dashboard','Reports','Advanced','Review','Updates')][string]$Page)
    foreach ($name in @('Dashboard','Reports','Advanced','Review','Updates')) {
        $visibility=[System.Windows.Visibility]::Collapsed
        if ($name -eq $Page) { $visibility=[System.Windows.Visibility]::Visible }
        $script:Controls[$name+'View'].Visibility=$visibility
        $script:Controls[$name+'Nav'].Background=[System.Windows.Media.BrushConverter]::new().ConvertFromString($(if($name -eq $Page){'#153443'}else{'Transparent'}))
    }
    switch ($Page) {
        Dashboard { $script:Controls.PageTitle.Text='QA overview'; $script:Controls.PageSubtitle.Text='A clear view of your scanner reports and archive.' }
        Review { $script:Controls.PageTitle.Text='Archive review';$script:Controls.PageSubtitle.Text='Grouped checks with every underlying date and report still available.' }
        Updates { $script:Controls.PageTitle.Text='Program updates';$script:Controls.PageSubtitle.Text='Install an approved update ZIP from local storage.' }
        Reports { $script:Controls.PageTitle.Text='Find & export reports'; $script:Controls.PageSubtitle.Text='Choose a scanner and period, then export every matching report in one ZIP.' }
        Advanced { $script:Controls.PageTitle.Text='Connections & settings'; $script:Controls.PageSubtitle.Text='Connections, archive preferences, and maintenance tools.' }
    }
}
function Initialize-ReportFilters {
    $script:UpdatingFilters=$true
    try {
        $scanners=New-Object 'System.Collections.Generic.List[object]'
        [void]$scanners.Add([pscustomobject]@{Value='All';Label='All scanners'})
        foreach($source in @($script:Config.Sources)){[void]$scanners.Add([pscustomobject]@{Value=[string]$source.Scanner;Label=[string]$source.Name})}
        $script:Controls.ScannerFilter.ItemsSource=@($scanners.ToArray());$script:Controls.ScannerFilter.SelectedIndex=0
        $months=New-Object 'System.Collections.Generic.List[object]'
        [void]$months.Add([pscustomobject]@{Value=0;Label='All months'})
        for($m=1;$m -le 12;$m++){[void]$months.Add([pscustomobject]@{Value=$m;Label=[Globalization.CultureInfo]::InvariantCulture.DateTimeFormat.GetMonthName($m)})}
        $script:Controls.MonthFilter.ItemsSource=@($months.ToArray());$script:Controls.MonthFilter.SelectedIndex=0
        $categories=New-Object 'System.Collections.Generic.List[object]'
        [void]$categories.Add([pscustomobject]@{Value='All';Label='All QA types'})
        foreach($category in @('Daily_QA','Monthly_QA','Monthly_QA/Pending_Verification','Acceptance_Tests','Needs_Review')){[void]$categories.Add([pscustomobject]@{Value=$category;Label=(Get-CategoryLabel $category)})}
        $script:Controls.CategoryFilter.ItemsSource=@($categories.ToArray());$script:Controls.CategoryFilter.SelectedIndex=0
        $script:Controls.ReviewStatusFilter.ItemsSource=@([pscustomobject]@{Value='All';Label='All review states'},[pscustomobject]@{Value='Pending';Label='Pending review'},[pscustomobject]@{Value='Accepted';Label='Accepted'},[pscustomobject]@{Value='Declined';Label='Declined suggestions'})
        $script:Controls.ReviewStatusFilter.SelectedIndex=0
        $script:Controls.YearFilter.ItemsSource=@([pscustomobject]@{Value=0;Label='All years'});$script:Controls.YearFilter.SelectedIndex=0
    } finally {$script:UpdatingFilters=$false}
}
function Refresh-ReportYears {
    $selected=0
    if($null -ne $script:Controls.YearFilter.SelectedValue){$selected=[int]$script:Controls.YearFilter.SelectedValue}
    $script:UpdatingFilters=$true
    try {
        $years=New-Object 'System.Collections.Generic.List[object]'
        [void]$years.Add([pscustomobject]@{Value=0;Label='All years'})
        $available=@($script:Dashboard.Records | Where-Object {[string]$_.ReportDate -match '^\d{4}-\d{2}-\d{2}$'} | ForEach-Object {[int]([string]$_.ReportDate).Substring(0,4)} | Sort-Object -Unique -Descending)
        $script:SelectedYears=@($script:SelectedYears | Where-Object {$available -contains $_})
        if($script:SelectedYears.Count -gt 1){$label=($script:SelectedYears -join ' + ');if($script:SelectedYears.Count -gt 2){$label=[string]$script:SelectedYears.Count+' selected years'};[void]$years.Add([pscustomobject]@{Value=-1;Label=$label});$selected=-1}
        elseif($script:SelectedYears.Count -eq 1){$selected=[int]$script:SelectedYears[0];$script:SelectedYears=@()}
        foreach($year in $available){[void]$years.Add([pscustomobject]@{Value=[int]$year;Label=[string]$year})}
        $script:Controls.YearFilter.ItemsSource=@($years.ToArray())
        if($selected -eq -1 -or $selected -eq 0 -or $available -contains $selected){$script:Controls.YearFilter.SelectedValue=$selected}else{$script:Controls.YearFilter.SelectedIndex=0}
    } finally {$script:UpdatingFilters=$false}
}
function Choose-ReportYears {
    if($script:Busy){return}
    $available=@($script:Dashboard.Records | Where-Object {[string]$_.ReportDate -match '^\d{4}-\d{2}-\d{2}$'} | ForEach-Object {[int]([string]$_.ReportDate).Substring(0,4)} | Sort-Object -Unique -Descending)
    if($available.Count -eq 0){Show-Note 'No dated reports are saved yet. Import reports first, then choose a year.';return}
    $filter=Get-ReportFilters
    $selected=@($script:SelectedYears)
    if($selected.Count -eq 0 -and $filter.Year -gt 0){$selected=@($filter.Year)}
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock Text="Choose report years" FontSize="23" FontWeight="SemiBold"/>
<TextBlock Grid.Row="1" Text="Choose one or more years. Your month, scanner, and QA type filters apply to every checked year." Foreground="#9CB5D0" TextWrapping="Wrap" Margin="0,13,0,15"/>
<StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,12"><Button x:Name="SelectAll" Content="Check all" Padding="11,7" Margin="0,0,9,0"/><Button x:Name="Clear" Content="Uncheck all" Padding="11,7"/></StackPanel>
<ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="YearsList"/></ScrollViewer>
<StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0"><Button x:Name="AllYears" Content="Use all years" Margin="0,0,9,0"/><Button x:Name="Cancel" Content="Cancel" Margin="0,0,9,0"/><Button x:Name="Apply" Content="Apply checked years" Background="#1D6871"/></StackPanel>
'@
    $d=New-Dialog 'Select one or more report years' $content 660 500
    $checks=New-Object 'System.Collections.Generic.List[object]'
    foreach($year in $available){
        $check=New-Object System.Windows.Controls.CheckBox
        $check.Content=[string]$year;$check.Tag=[int]$year;$check.FontSize=16;$check.Margin=New-Object Windows.Thickness(9,8,9,8)
        $check.IsChecked=($selected.Count -eq 0 -or $selected -contains $year)
        [void]$checks.Add($check);[void]$d.FindName('YearsList').Children.Add($check)
    }
    $d.Tag=@{Checks=@($checks.ToArray());Action=''}
    $d.FindName('SelectAll').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender);foreach($check in $parent.Tag.Checks){$check.IsChecked=$true}})
    $d.FindName('Clear').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender);foreach($check in $parent.Tag.Checks){$check.IsChecked=$false}})
    $d.FindName('Cancel').Add_Click({param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).DialogResult=$false})
    $d.FindName('AllYears').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender);$parent.Tag.Action='All';$parent.DialogResult=$true})
    $d.FindName('Apply').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender);if(@($parent.Tag.Checks | Where-Object {$_.IsChecked -eq $true}).Count -eq 0){[void][Windows.MessageBox]::Show($parent,'Check at least one year, or choose Use all years.','Choose years');return};$parent.Tag.Action='Selected';$parent.DialogResult=$true})
    if($d.ShowDialog() -eq $true){
        $script:UpdatingFilters=$true
        try {
            if($d.Tag.Action -eq 'All'){$script:SelectedYears=@();$script:Controls.YearFilter.SelectedValue=0}
            else{
                $years=[int[]]@($d.Tag.Checks | Where-Object {$_.IsChecked -eq $true} | ForEach-Object {[int]$_.Tag})
                if($years.Count -eq 1){$script:SelectedYears=@();$script:Controls.YearFilter.SelectedValue=$years[0]}
                else{$script:SelectedYears=$years}
            }
        } finally {$script:UpdatingFilters=$false}
        Refresh-ReportYears;Refresh-Reports
    }
}

function Get-ReportFilters {
    $scanner='All';$year=0;$month=0;$category='All'
    if($null -ne $script:Controls.ScannerFilter.SelectedValue){$scanner=[string]$script:Controls.ScannerFilter.SelectedValue}
    if($null -ne $script:Controls.YearFilter.SelectedValue){$year=[int]$script:Controls.YearFilter.SelectedValue}
    if($null -ne $script:Controls.MonthFilter.SelectedValue){$month=[int]$script:Controls.MonthFilter.SelectedValue}
    if($null -ne $script:Controls.CategoryFilter.SelectedValue){$category=[string]$script:Controls.CategoryFilter.SelectedValue}
    if($year -lt 0){$year=0}
    return [pscustomobject]@{Scanner=$scanner;Year=$year;Years=[int[]]@($script:SelectedYears);Month=$month;Category=$category;Query=$script:Controls.ReportSearch.Text.Trim()}
}
function Get-ReportFilterSummary {
    $labels=New-Object 'System.Collections.Generic.List[string]'
    foreach($control in @('ScannerFilter','YearFilter','MonthFilter','CategoryFilter','ReviewStatusFilter')){[void]$labels.Add([string](Value-Or $script:Controls[$control].SelectedItem Label 'All'))}
    if($script:PendingOnly){[void]$labels.Add('Needs confirmation only')}
    if($script:Controls.ReportSearch.Text.Trim()){[void]$labels.Add('Search: '+$script:Controls.ReportSearch.Text.Trim())}
    return ($labels -join ' / ')
}
function Clear-ReportFilters {
    $script:UpdatingFilters=$true
    try {
        foreach($control in @('ScannerFilter','YearFilter','MonthFilter','CategoryFilter','ReviewStatusFilter')){$script:Controls[$control].SelectedIndex=0}
        $script:Controls.ReportSearch.Text='';$script:PendingOnly=$false;$script:SelectedYears=@()
    } finally {$script:UpdatingFilters=$false}
    Refresh-ReportYears;Refresh-Reports
}
function Refresh-Reports {
    if($script:UpdatingFilters -or $null -eq $script:Dashboard){return}
    $filter=Get-ReportFilters
    $rows=@(Select-QaReports -Records @($script:Dashboard.Records) -Scanner $filter.Scanner -Year $filter.Year -Years $filter.Years -Month $filter.Month -Category $filter.Category -Query $filter.Query -Index $script:ReportSearchIndex)
    $state=[string]$script:Controls.ReviewStatusFilter.SelectedValue
    if($script:PendingOnly -and $state -eq 'All'){$state='Pending';$script:Controls.ReviewStatusFilter.SelectedValue='Pending'}
    if($state -and $state -ne 'All'){$rows=@($rows | Where-Object {(Get-QaReportReviewStatus $_) -eq $state})}
    $script:FilteredReports=$rows
    $script:Controls.ReportsGrid.ItemsSource=$rows
    $script:Controls.ReportCount.Text=('{0:N0} matching reports' -f $rows.Count)
    $script:Controls.FilterSummary.Text=Get-ReportFilterSummary
    $script:Controls.ExportButtonText.Text=('Export {0:N0} reports (.zip)' -f $rows.Count)
    $script:Controls.ExportReportsButton.IsEnabled=((-not $script:Busy) -and $rows.Count -gt 0)
    $script:Controls.ReviewPendingButton.Content=$(if($script:PendingOnly){'Pending verification: on'}else{'Pending verification'})
    $script:Controls.SearchPlaceholder.Visibility=$(if($filter.Query){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible})
}

function Should-RunStartupUpdate {
    param($Config,$Dashboard,[bool]$AlreadyStarted=$false)
    if($AlreadyStarted){return $false}
    if(-not [bool](Value-Or $Dashboard SetupComplete $false)){return $false}
    return [bool](Value-Or $Config AutoUpdateOnOpen $true)
}
function Invoke-StartupUpdate {
    if($script:StartupHandled){return}
    $eligible=Should-RunStartupUpdate -Config $script:Config -Dashboard $script:Dashboard -AlreadyStarted $script:StartupHandled
    $script:StartupHandled=$true
    if($eligible){
        $script:Controls.StatusText.Text='Checking for new reports...'
        $script:Controls.StepOne.Text='1. Wait for report update'
        Start-Work -Mode Update
    }
}
function Open-QaReportGuide {
    $path=Join-Path $PSScriptRoot 'Reference/Siemens_QA_Guide.html'
    if(-not [IO.File]::Exists($path)){Show-Note 'The bundled QA report guide is not available in this application folder.';return}
    try{Start-Process -FilePath $path | Out-Null}catch{Show-Note $_.Exception.Message 'QA guide could not open' $true}
}

function Show-Help {
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock Text="Three simple steps" FontSize="24" FontWeight="SemiBold"/>
<Border Grid.Row="1" Background="#152B40" CornerRadius="10" Padding="17" Margin="0,17,0,13"><StackPanel><TextBlock x:Name="HelpStepOne" Foreground="#8DE2D7" FontSize="15" FontWeight="SemiBold"/><TextBlock x:Name="HelpStepTwo" Foreground="#C5D6EA" FontSize="14" Margin="0,13,0,0"/><TextBlock x:Name="HelpStepThree" Foreground="#C5D6EA" FontSize="14" Margin="0,13,0,0"/></StackPanel></Border>
<TextBlock Grid.Row="2" Text="To find a month: choose Find / export reports, then pick the year, month, scanner, and QA type. Export includes every matching report, not just the row you click." Foreground="#A6BED8" TextWrapping="Wrap" Margin="0,0,0,13"/>
<TextBlock Grid.Row="3" Text="Most reports are organized automatically. Check only reports marked Needs confirmation. Open the PDF and confirm its type if authorized; otherwise leave it pending. For Monthly QA, one combined PDF or several partial PDFs can cover the department checklist. A Monthly report label alone does not confirm the full set. You can still update and export reports." Foreground="#A6BED8" TextWrapping="Wrap" Margin="0,0,0,13"/>
<TextBlock Grid.Row="4" Text="After first-time setup, the app can check for new reports once when it opens. Turn this off in Advanced settings. Update Reports can always be used manually. Nothing runs after the app closes. If a scanner is unavailable, use Advanced settings / Reconnect drives, or ask IT. Other accessible scanners can continue." Foreground="#819EBE" TextWrapping="Wrap" Margin="0,0,0,20"/>
<StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="QaGuide" Content="QA report guide" Margin="0,0,10,0" Visibility="Collapsed"/><Button x:Name="FindReports" Content="Find / export reports" Margin="0,0,10,0" Background="#1C6670"/><Button x:Name="Close" Content="Got it"/></StackPanel>
'@
    $d=New-Dialog 'How to use CT QA Manager Pro' $content 780 680
    if($null -ne $script:Dashboard -and [bool]$script:Dashboard.SetupComplete){
        $d.FindName('HelpStepOne').Text=$(if([bool](Value-Or $script:Config AutoUpdateOnOpen $true)){'1. Wait for the update that starts when this app opens.'}else{'1. Click Update Reports to collect new PDFs.'})
        $d.FindName('HelpStepTwo').Text='2. Check attention items that need action. Informational items can be left alone.'
        $d.FindName('HelpStepThree').Text='3. Open Reports Folder, or find and export a month of reports.'
    } else {
        $d.FindName('HelpStepOne').Text='1. Click First-Time Setup and choose the archive folder.'
        $d.FindName('HelpStepTwo').Text='2. The app checks scanners and shows a preview of the reports.'
        $d.FindName('HelpStepThree').Text='3. Click Confirm and copy reports. After that, use Update Reports.'
    }
    $d.FindName('Close').Add_Click({param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).DialogResult=$false})
    $d.FindName('FindReports').Add_Click({param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).DialogResult=$true})
    if([IO.File]::Exists((Join-Path $PSScriptRoot 'Reference/Siemens_QA_Guide.html'))){$d.FindName('QaGuide').Visibility=[Windows.Visibility]::Visible}
    $d.FindName('QaGuide').Add_Click({Open-QaReportGuide})
    if($d.ShowDialog() -eq $true){Show-Page Reports}
}

function Open-ExportFolder {
    # This route opens only the last successfully generated local export's containing folder.
    # Archive PDF opening remains separately constrained to managed indexed report paths.
    if(-not $script:LastExportPath){return}
    try {
        $target=[IO.Path]::GetFullPath($script:LastExportPath)
        if($target -notmatch '^[A-Za-z]:\\' -or [IO.Path]::GetExtension($target) -ne '.zip'){throw 'Choose a local disk or USB export folder.'}
        $drive=New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($target))
        if($drive.DriveType -notin @([IO.DriveType]::Fixed,[IO.DriveType]::Removable)){throw 'Only local disk or USB export folders can be opened here.'}
        if(-not [IO.File]::Exists($target)){throw 'The exported ZIP is no longer available at its saved location.'}
        $ancestor=$target
        while($ancestor){
            if(([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'The export path contains a linked folder. Choose an ordinary local folder.'}
            $parent=[IO.Path]::GetDirectoryName($ancestor);if($parent -eq $ancestor){break};$ancestor=$parent
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"'+$target+'"') | Out-Null
    } catch {Show-Note $_.Exception.Message 'Export folder unavailable' $true}
}
function Export-MatchingReports {
    if($script:Busy){return}
    $rows=@($script:FilteredReports)
    if($rows.Count -eq 0){Show-Note 'No reports match these filters. Change the scanner, period, or QA type and try again.';return}
    $filter=Get-ReportFilters
    $pending=@($rows | Where-Object {[string]$_.Category -eq 'Monthly_QA/Pending_Verification'}).Count
    $description=Get-ReportFilterSummary
    $message=('{0:N0} reports match your filters.' -f $rows.Count)+"`r`n`r`n"+$description+"`r`n`r`n"+('{0:N0} possible Monthly reports are awaiting verification.' -f $pending)+"`r`n`r`nEvery matching report will be included, including separate testing sessions. The selected grid row does not limit the export. Choose a local disk or USB folder next."
    if([Windows.MessageBox]::Show($script:Window,$message,'Export matching reports',[Windows.MessageBoxButton]::OKCancel,[Windows.MessageBoxImage]::Information) -ne [Windows.MessageBoxResult]::OK){return}
    $period='All_Years'
    if(@($filter.Years).Count -gt 0){$period=(@($filter.Years | Sort-Object) -join '_')}elseif($filter.Year -gt 0){$period=$filter.Year.ToString('0000')}
    if($filter.Month -gt 0){$period+='-'+$filter.Month.ToString('00')}else{$period+='_All_Months'}
    $scanner='All_Scanners';if($filter.Scanner -ne 'All'){$scanner=$filter.Scanner}
    $picker=New-Object Microsoft.Win32.SaveFileDialog
    $picker.Title=('Save ZIP containing '+$rows.Count+' matching reports')
    $picker.Filter='ZIP archive (*.zip)|*.zip';$picker.DefaultExt='.zip';$picker.AddExtension=$true
    $picker.FileName='CT_QA_'+$period+'_'+$scanner+'.zip';$picker.CheckPathExists=$true;$picker.OverwritePrompt=$false
    $picker.InitialDirectory=[Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    while($picker.ShowDialog($script:Window) -eq $true){
        $destination=[IO.Path]::GetFullPath($picker.FileName)
        if($destination -notmatch '^[A-Za-z]:\\'){Show-Note 'Choose a local disk or USB folder. Network locations are not supported for exports.' 'Choose export location' $true;continue}
        $drive=New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($destination))
        if($drive.DriveType -notin @([IO.DriveType]::Fixed,[IO.DriveType]::Removable)){Show-Note 'Choose a local disk or USB folder.' 'Choose export location' $true;continue}
        if([IO.File]::Exists($destination)){Show-Note 'A file with that name already exists. Choose a new name; existing exports are never overwritten.' 'Choose another ZIP name';continue}
        $ids=[string[]]@($rows | ForEach-Object {[string]$_.Id})
        $script:Controls.ExportResultPanel.Visibility=[Windows.Visibility]::Visible
        $script:Controls.ExportResultText.Text=('Preparing {0:N0} reports for export...' -f $ids.Count)
        $script:Controls.OpenExportFolderButton.Visibility=[Windows.Visibility]::Collapsed
        Start-Work -Mode Export -Plan ([pscustomobject]@{RecordIds=$ids;DestinationPath=$destination})
        return
    }
}
function Finish-Export {
    param($Result)
    $summary=$Result.Summary
    $script:Controls.ExportResultPanel.Visibility=[Windows.Visibility]::Visible
    $script:Controls.OpenExportFolderButton.Visibility=[Windows.Visibility]::Collapsed
    if([bool]$summary.Cancelled){$script:Controls.ExportResultText.Text='Export cancelled. No completed ZIP was created.';return}
    if([int]$summary.Failed -gt 0 -or [int]$summary.Exported -ne [int]$summary.Total){
        $script:Controls.ExportResultText.Text='Export could not finish. No completed ZIP was created. '+[string]$summary.Description
        Show-Note ([string]$summary.Description) 'Export needs attention' $true
        return
    }
    $script:LastExportPath=[string]$Result.DestinationPath
    $script:Controls.ExportResultText.Text=('Exported {0:N0} reports. {1:N0} verified. Saved as {2}' -f [int]$summary.Exported,[int]$summary.Verified,[IO.Path]::GetFileName($script:LastExportPath))
    $script:Controls.ExportResultText.ToolTip=$script:LastExportPath
    $script:Controls.OpenExportFolderButton.Visibility=[Windows.Visibility]::Visible
    $script:Controls.StatusText.Text=('Export complete: {0:N0} reports saved in the ZIP.' -f [int]$summary.Exported)
}
function Read-SelectedReportText {
    if($script:Busy){return}
    $record=$script:Controls.ReportsGrid.SelectedItem
    if($null -eq $record){Show-Note 'Select a saved report first, then click Read report text.';return}
    $script:ReadingRecordId=[string]$record.Id
    Start-Work -Mode PdfRead -Plan ([pscustomobject]@{RecordId=$script:ReadingRecordId})
}
function Show-ReportText {
    param($Result)
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock x:Name="TextTitle" FontSize="20" FontWeight="SemiBold" TextWrapping="Wrap"/>
<TextBlock x:Name="TextPages" Grid.Row="1" Foreground="#81D8CD" Margin="0,10,0,10"/>
<Border Grid.Row="2" Background="#172B41" CornerRadius="8" Padding="12" Margin="0,0,0,14"><StackPanel><TextBlock x:Name="TextIndicators" Foreground="#A5CDE1" TextWrapping="Wrap"/><TextBlock Text="Suggestions help you check the label. They do not confirm Monthly QA." Foreground="#8AA5C4" TextWrapping="Wrap" Margin="0,7,0,0"/></StackPanel></Border>
<TextBox x:Name="ExtractedText" Grid.Row="3" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" FontFamily="Segoe UI" FontSize="13" Padding="15"/>
<TextBlock x:Name="TextMessage" Grid.Row="4" Foreground="#96ACC8" TextWrapping="Wrap" Margin="0,13,0,15"/>
<StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="OpenPdf" Content="Open PDF" Margin="0,0,10,0"/><Button x:Name="Close" Content="Close" Background="#1D6871"/></StackPanel>
'@
    $d=New-Dialog 'Read report text' $content 1000 720
    $d.FindName('TextTitle').Text=[string](Value-Or $Result Title 'Saved QA report')
    $d.FindName('TextPages').Text=('Read {0:N0} of {1:N0} pages' -f [int](Value-Or $Result ReadPages 0),[int](Value-Or $Result Pages 0))
    $labels=@(Value-Or $Result Indicators @())
    $d.FindName('TextIndicators').Text=$(if($labels.Count){'Possible test labels found: '+($labels -join ', ')}else{'No specific test labels were identified in the extracted text.'})
    $d.FindName('ExtractedText').Text=[string](Value-Or $Result Text '')
    $d.FindName('TextMessage').Text=[string](Value-Or $Result Message 'The saved report label has not been changed.')
    if([bool](Value-Or $Result NeedsOCR $false)){$d.FindName('TextMessage').Text+=' This PDF may contain scanned images. Open the PDF to inspect it; image-to-text recognition is not included.'}
    if([bool](Value-Or $Result Truncated $false)){$d.FindName('TextMessage').Text+=' Only part of this report is shown. Open the PDF for the complete report.'}
    $matching=@($script:Dashboard.Records | Where-Object {[string]$_.Id -eq $script:ReadingRecordId})
    $d.Tag=$null;if($matching.Count -eq 1){$d.Tag=$matching[0]}
    $d.FindName('OpenPdf').IsEnabled=($null -ne $d.Tag)
    $d.FindName('OpenPdf').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender);if($null -ne $parent.Tag){Safe-Open ([string]$parent.Tag.DestinationPath)}})
    $d.FindName('Close').Add_Click({param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).Close()})
    $script:Controls.StatusText.Text='Report text is ready. The saved report label has not been changed.'
    [void]$d.ShowDialog()
}
function Offer-ExistingBrowseFolder {
    param([string]$Message)
    if(-not $script:BrowseOpenOnComplete){return}
    $script:BrowseOpenOnComplete=$false
    $path=Join-Path $script:Config.ArchiveRoot 'Browse Reports'
    if(-not [IO.Directory]::Exists($path)){return}
    $answer=[Windows.MessageBox]::Show($script:Window,$Message+"`r`n`r`nThe existing friendly folder may be incomplete or out of date. Open it anyway?",'Friendly folder is not fully refreshed',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)
    if($answer -eq [Windows.MessageBoxResult]::Yes){Safe-Open $path -Folder}
}

function Open-BrowseReports {
    if($script:Busy){return}
    $path=Join-Path $script:Config.ArchiveRoot 'Browse Reports'
    $script:BrowseOpenOnComplete=$true;$script:BrowsePreviousStatus=''
    Start-Work -Mode BrowseRefresh
}
function Finish-BrowseRefresh {
    param($Result)
    $summary=$Result.Summary
    $message=[string](Value-Or $summary Description 'Friendly report folders refreshed.')
    if($script:BrowsePreviousStatus){$message=$script:BrowsePreviousStatus+' / '+$message}
    $script:Controls.StatusText.Text=$message
    $open=$script:BrowseOpenOnComplete
    $script:BrowsePreviousStatus=''
    if([int](Value-Or $summary Failed 0) -gt 0){Show-Note ($message+"`r`n`r`nThe managed archive remains saved. Some friendly folder copies could not be created.") 'Friendly folders need attention' $true;Offer-ExistingBrowseFolder $message;return}
    if([bool](Value-Or $summary Cancelled $false)){Offer-ExistingBrowseFolder $message;return}
    $script:BrowseOpenOnComplete=$false
    if($open){Safe-Open (Join-Path $script:Config.ArchiveRoot 'Browse Reports') -Folder}
}
function Initialize-DemoDashboard {
    $script:Config=Get-QaDefaultConfig -AppRoot $script:AppRoot
    foreach($source in $script:Config.Sources){$source|Add-Member MonthlyChecklist @('MTF','Slice thickness') -Force;$source|Add-Member MonthlyDueDay 25 -Force}
    $records=@();$scanners=@();$n=0
    foreach($source in $script:Config.Sources){
        $n++;$scanners+=@([pscustomobject]@{Scanner=$source.Scanner;Name=$source.Name;Status=$(if($n -eq 3){'Unavailable'}else{'Connected'});Message='Synthetic demonstration';SavedReports=42;LastSuccessfulUpdate=[datetime]::UtcNow.ToString('o');CheckedUtc=[datetime]::UtcNow.ToString('o')})
        if($n -lt 3){$records+=@([pscustomobject]@{Id=($n.ToString()*64);Scanner=$source.Scanner;ReportDate=(Get-Date).ToString('yyyy-MM-dd');ReportTime='07:15:00';Category='Daily_QA';OriginalFileName='Synthetic_Daily_QA.pdf';Hash=($n.ToString()*64);DestinationPath='';ConfirmedComponents=@();ConfirmedBy='';ConfirmedAt=''})}
    }
    $records+=@([pscustomobject]@{Id=('4'*64);Scanner='CT_Edge';ReportDate=((Get-Date).ToString('yyyy-MM')+'-01');ReportTime='08:00:00';Category='Monthly_QA';OriginalFileName='Synthetic_combined_monthly.pdf';SourcePath='Synthetic-Edge-monthly';FirstArchived=[datetime]::UtcNow.ToString('o');Hash=('4'*64);DestinationPath='';ConfirmedComponents=@('MTF','Slice thickness');ConfirmedBy='Synthetic reviewer';ConfirmedAt=[datetime]::UtcNow.ToString('o')})
    $records+=@([pscustomobject]@{Id=('5'*64);Scanner='CT_Flash';ReportDate=((Get-Date).ToString('yyyy-MM')+'-01');ReportTime='08:00:00';Category='Monthly_QA';OriginalFileName='Synthetic_MTF_component.pdf';SourcePath='Synthetic-Flash-monthly';FirstArchived=[datetime]::UtcNow.ToString('o');Hash=('5'*64);DestinationPath='';ConfirmedComponents=@('MTF');ConfirmedBy='Synthetic reviewer';ConfirmedAt=[datetime]::UtcNow.ToString('o')})
    $records+=@([pscustomobject]@{Id=('6'*64);Scanner='CT_Flash';ReportDate=((Get-Date).ToString('yyyy-MM')+'-03');ReportTime='08:10:00';Category='Monthly_QA/Pending_Verification';OriginalFileName='Synthetic_Monthly_Constancy.pdf';SourcePath='Synthetic-Flash-candidate';FirstArchived=[datetime]::UtcNow.ToString('o');Hash=('6'*64);DestinationPath='';ConfirmedComponents=@();ConfirmedBy='';ConfirmedAt=''})
    $demoIssues=@([pscustomobject]@{Scanner='MDP_Building';Type='Connection';Message='Synthetic example: the reports folder is unavailable. Saved reports remain accessible.';Path='';RecordId=''})
    foreach($source in $script:Config.Sources){foreach($day in 1..60){$demoIssues+=@([pscustomobject]@{Scanner=$source.Scanner;Type='DailyGap';Message=('Synthetic archive example: daily PDF not found for '+(Get-Date).AddDays(-$day).ToString('yyyy-MM-dd'));Path='';RecordId=''})}}
    $script:Dashboard=[pscustomobject]@{SetupComplete=$true;Records=$records;Scanners=$scanners;Attention=$demoIssues;TotalReports=$records.Count;LegacyDetected=$false;ArchiveRoot=$script:AppRoot;LastUpdated=[datetime]::UtcNow.ToString('o')}
}

function Refresh-Dashboard {
    try {
        if(-not $script:DemoPreview){$script:Dashboard=Get-QaDashboard -Config $script:Config}
        $today=Get-QaTodayOverview -Config $script:Config -Dashboard $script:Dashboard
        $script:Controls.TodayHeadline.Text=$today.Headline
        $script:Controls.TodayDate.Text=(Get-Date).ToString('dddd, MMMM d').ToUpperInvariant()
        if($script:DemoPreview){$today.Scanners[0].Findings='Recognized printed PASS results';$today.Scanners[1].Findings='Printed FAIL detected - review PDF'}
        foreach($row in $today.Scanners){
            if($row.DailyStatus -eq 'Report needs classification'){$row.DailyStatus='Saved - confirm report type'}
            if($row.Findings -eq 'Not analyzed'){$row.Findings=if($row.DailyStatus -eq 'Saved - confirm report type'){'Confirm type to show daily results'}elseif($row.DailyStatus -eq 'Awaiting report'){'No confirmed daily PDF yet'}elseif([bool](Value-Or $script:Config AutoAnalyze $true)){'Text reading queued'}else{'Automatic text reading is off'}}
            elseif($row.Findings -eq 'Needs review / text incomplete'){$row.Findings='Text read - result needs review'}
        }
        $script:Controls.TodayGrid.ItemsSource=@($today.Scanners)
        $script:Controls.MonthlyGrid.ItemsSource=@(Get-QaMonthOverview -Config $script:Config -Dashboard $script:Dashboard)
        $reading=Get-QaAnalysisProgress -Config $script:Config -Records @($script:Dashboard.Records)
        $script:AnalysisPending=$reading.Pending
        $script:Controls.ReadingProgressLabel.Text=($reading.Cached.ToString()+' of '+$reading.Total+' PDFs have cached reading results; '+$reading.Pending+' waiting, '+$reading.Errors+' need a manual retry. Up to 20 new PDFs per batch.')
        $script:Controls.ToggleReadingButton.Content=$(if([bool](Value-Or $script:Config AutoAnalyze $true)){'Pause automatic PDF reading'}else{'Enable automatic PDF reading'})
        $minutes=[int](Value-Or $script:Config MonitorMinutes 15)
        $script:Controls.BackgroundLabel.Text=$(if($minutes -gt 0){'Checks every '+$minutes+' minutes while open. Saved PDFs stay available offline.'}else{'Automatic checks paused. Saved PDFs stay available offline.'})
        try{$script:Controls.StorageLabel.Text=(Get-QaStorage $script:Config.ArchiveRoot).Label+' / Full backups should be stored on approved separate storage.'}catch{$script:Controls.StorageLabel.Text='Storage is unavailable. Check the selected archive folder.'}
        Add-RecordLabels $script:Dashboard.Records
        $script:ReportSearchIndex=New-QaSearchIndex -Records @($script:Dashboard.Records)
        Add-AttentionLabels $script:Dashboard.Attention
        $script:Controls.TotalCount.Text=('{0:N0}' -f [int]$script:Dashboard.TotalReports)
        $complete=[bool]$script:Dashboard.SetupComplete
        if ($complete) {
            $script:Controls.StepOne.Text='1. Update reports'
            $script:Controls.StepTwo.Text='2. Check attention items'
            $script:Controls.StepThree.Text='3. Open or export reports'
            $script:Controls.WelcomeTitle.Text='Your report archive is ready'
            $script:Controls.WelcomeText.Text='Click Update Reports to check for new PDFs. Most report labels are handled automatically.'
            $script:Controls.SetupButtonTitle.Text='Setup complete'
            $script:Controls.SetupButtonHint.Text='Preview another import'
            $script:Controls.SetupButton.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#162538')
            $script:Controls.SetupButton.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#2A3A50')
            $script:Controls.UpdateButton.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#2467C5')
            $script:Controls.UpdateButton.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#438CFF')
        } else {
            $script:Controls.StepOne.Text='1. Choose archive folder'
            $script:Controls.StepTwo.Text='2. Check scanners and preview'
            $script:Controls.StepThree.Text='3. Confirm the import'
            $script:Controls.WelcomeTitle.Text='Your first import starts here'
            $script:Controls.WelcomeText.Text='Connect your scanners, preview the reports, then choose what to copy.'
            $script:Controls.SetupButtonTitle.Text='First-Time Setup'
            $script:Controls.SetupButtonHint.Text='Preview and organize'
            $script:Controls.SetupButton.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#194854')
            $script:Controls.SetupButton.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#2C7F83')
            $script:Controls.UpdateButton.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#1B304D')
            $script:Controls.UpdateButton.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#2F4C70')
        }
        $cards=New-Object 'System.Collections.Generic.List[object]'
        foreach($scanner in @($script:Dashboard.Scanners)){
            $status=[string]$scanner.Status;$text='Not checked';$color='#687D99'
            switch($status){Connected{$text='Connected';$color='#42D4B6'} Unavailable{$text='Connection unavailable';$color='#E4AD65'} Partial{$text='Some folders unavailable';$color='#E4AD65'} Issues{$text='Update needs attention';$color='#E4AD65'}}
            $last=[string](Value-Or $scanner LastSuccessfulUpdate);$updated='No successful update yet'
            if($last){try{$date=[datetime]::Parse($last).ToLocalTime();$updated='Updated '+$date.ToString('MMM d, yyyy  h:mm tt')}catch{$updated='Last update recorded'}}
            if($script:ConnectionFeedback.ContainsKey([string]$scanner.Scanner)){
                $feedback=$script:ConnectionFeedback[[string]$scanner.Scanner]
                $checked=[datetime]::MinValue;try{$checked=[datetime]::Parse([string](Value-Or $scanner CheckedUtc ''))}catch{}
                if($feedback.CheckedUtc -ge $checked.ToUniversalTime()){$text=if($feedback.Status -eq 'Connected'){'Folder accessible'}else{'Connection needs checking'};$color=if($feedback.Status -eq 'Connected'){'#42D4B6'}else{'#E4AD65'};$updated='Checked '+$feedback.CheckedUtc.ToLocalTime().ToString('h:mm tt')+' / Update reports to import';}
            }
            [void]$cards.Add([pscustomobject]@{Scanner=[string]$scanner.Scanner;Name=[string]$scanner.Name;Message=[string](Value-Or $scanner Message);StatusLabel=$text;StatusColor=$color;CountLabel=('{0:N0}' -f [int](Value-Or $scanner SavedReports 0));UpdatedLabel=$updated})
        }
        $script:Controls.ScannerCards.ItemsSource=@($cards.ToArray())
        $script:ReviewGroups=@(Get-QaReviewGroups -Issues @($script:Dashboard.Attention) -Sources @($script:Config.Sources))
        Refresh-ReviewGroups
        Refresh-ReportYears
        Refresh-Reports
    } catch { Show-Note $_.Exception.Message 'Archive could not be read' $true }
}
function Refresh-ScannerFilterOptions {
    $selected='All';if($null -ne $script:Controls.ScannerFilter.SelectedValue){$selected=[string]$script:Controls.ScannerFilter.SelectedValue}
    $script:UpdatingFilters=$true
    try{
        $items=New-Object 'System.Collections.Generic.List[object]';[void]$items.Add([pscustomobject]@{Value='All';Label='All scanners'})
        foreach($source in @($script:Config.Sources)){[void]$items.Add([pscustomobject]@{Value=[string]$source.Scanner;Label=[string]$source.Name})}
        $script:Controls.ScannerFilter.ItemsSource=@($items.ToArray())
        if($selected -eq 'All' -or @($script:Config.Sources | Where-Object Scanner -eq $selected).Count){$script:Controls.ScannerFilter.SelectedValue=$selected}else{$script:Controls.ScannerFilter.SelectedIndex=0}
    }finally{$script:UpdatingFilters=$false}
}
function Set-CredentialStatusLabel {
    param($Source,$Editor)
    try{
        $status=Get-QaCredentialStatus -AppRoot $script:AppRoot -ScannerId ([string]$Source.Scanner) -ExpectedUsername ([string]$Source.Username) -ExpectedPath ([string]$Source.Path)
        if([bool]$status.Saved){
            if([string]$status.Username -ne [string]$Source.Username){$Editor.SavedStatus.Text='Saved sign-in uses a different username. Enter a new password and save to replace it.'}
            else{$Editor.SavedStatus.Text='Sign-in is saved securely for this Windows account and workstation. The password is never displayed.'}
            $Editor.Forget.IsEnabled=$true
        }else{$Editor.SavedStatus.Text=[string](Value-Or $status Message 'No password is saved.')+' Enter a new password after changing the connection address or username.';$Editor.Forget.IsEnabled=[bool](Value-Or $status Stored $false)}
    }catch{$Editor.SavedStatus.Text='Saved sign-in status is unavailable. '+$_.Exception.Message;$Editor.Forget.IsEnabled=$false}
}
function Save-EditedCredentials {
    param([string]$ScannerId='')
    $warnings=New-Object 'System.Collections.Generic.List[string]'
    foreach($source in @($script:Config.Sources)){
        if($ScannerId -and [string]$source.Scanner -ne $ScannerId){continue}
        $editor=$script:ScannerEditors[[string]$source.Scanner]
        if($editor.Password.SecurePassword.Length -gt 0){
            try{
                $secure=$editor.Password.SecurePassword.Copy()
                $credential=New-Object Management.Automation.PSCredential([string]$source.Username,$secure)
                Save-QaSavedCredential -AppRoot $script:AppRoot -ScannerId ([string]$source.Scanner) -ExpectedPath ([string]$source.Path) -Credential $credential | Out-Null
                $editor.Password.Clear()
                $editor.ConnectionResult.Text='Sign-in saved. Reconnecting checks whether Windows accepts it.'
            }catch{[void]$warnings.Add(([string]$source.Name+': '+$_.Exception.Message))}
        }
        Set-CredentialStatusLabel $source $editor
    }
    if($warnings.Count){Show-Note ('Scanner settings were saved, but some sign-ins could not be saved securely.'+"`r`n`r`n"+($warnings -join "`r`n")) 'Saved sign-in needs attention' $true}
}
function Add-Scanner {
    if($script:Busy){return}
    if(@($script:Config.Sources).Count -ge 20){Show-Note 'This portable app supports up to 20 scanners.';return}
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock Text="Add a scanner connection" FontSize="23" FontWeight="SemiBold"/>
<StackPanel Grid.Row="1" Margin="0,16,0,0"><TextBlock Text="Scanner name" Foreground="#A5BCD6" Margin="0,0,0,6"/><TextBox x:Name="Name"/></StackPanel>
<StackPanel Grid.Row="2" Margin="0,13,0,0"><TextBlock Text="Network report folder" Foreground="#A5BCD6" Margin="0,0,0,6"/><TextBox x:Name="Path"/><TextBlock Text="Example: \\CT-EDGE\Reports\ConstancyReports" Foreground="#738FAD" FontSize="10" Margin="0,6,0,0"/></StackPanel>
<Grid Grid.Row="3" Margin="0,13,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="15"/><ColumnDefinition Width="125"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Username" Foreground="#A5BCD6" Margin="0,0,0,6"/><TextBox x:Name="Username" Text="SCANNER_USERNAME"/></StackPanel><StackPanel Grid.Column="2"><TextBlock Text="Preferred drive" Foreground="#A5BCD6" Margin="0,0,0,6"/><ComboBox x:Name="Drive"/></StackPanel></Grid>
<StackPanel Grid.Row="4" Margin="0,13,0,0"><TextBlock Text="Password (optional; saved securely for this Windows account and workstation)" Foreground="#A5BCD6" Margin="0,0,0,6"/><PasswordBox x:Name="Password" Padding="10,8" Background="#182940" Foreground="White" BorderBrush="#314763"/></StackPanel>
<TextBlock Grid.Row="5" Text="The scanner is checked by Setup, Update Reports, Reconnect, or the optional update when this app opens. Existing drive mappings are preserved." Foreground="#879FBE" TextWrapping="Wrap" Margin="0,16,0,18"/>
<StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="Cancel" Content="Cancel" Margin="0,0,10,0"/><Button x:Name="Add" Content="Add scanner" Background="#1D6871"/></StackPanel>
'@
    $d=New-Dialog 'Add scanner' $content 720 585
    $letters=@('L','M','N','P','Q','R','S','T','U','V','W','X','Z','H','G','F','E','D','I','J','K','O','Y')
    $used=@($script:Config.Sources | ForEach-Object {[string]$_.DriveLetter})
    $available=@($letters | Where-Object {$used -notcontains $_})
    $d.FindName('Drive').ItemsSource=$available;$d.FindName('Drive').SelectedIndex=0
    $d.FindName('Cancel').Add_Click({param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).DialogResult=$false})
    $d.FindName('Add').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender);if(-not $parent.FindName('Name').Text.Trim() -or -not $parent.FindName('Path').Text.Trim() -or -not $parent.FindName('Username').Text.Trim()){[void][Windows.MessageBox]::Show($parent,'Enter the scanner name, network folder, and username.','Connection details needed');return};$parent.DialogResult=$true})
    if($d.ShowDialog() -ne $true){$d.FindName('Password').Clear();return}
    try{
        $name=$d.FindName('Name').Text.Trim()
        if(@($script:Config.Sources | Where-Object {$_.Name -eq $name}).Count){throw 'Choose a different scanner name so each connection is easy to recognize.'}
        $id='Scanner_'+[guid]::NewGuid().ToString('N').Substring(0,8)
        $source=[pscustomobject]@{Scanner=$id;Name=$name;Path=$d.FindName('Path').Text.Trim();DriveLetter=[string]$d.FindName('Drive').SelectedItem;Username=$d.FindName('Username').Text.Trim();DailySchedule='AllDays';ExpectedMonthly=$true;ActiveFrom='';MonthlyThresholdKB=85.0;MonthlyChecklist=@()}
        $config=$script:Config | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $config.Sources=@($config.Sources)+@($source)
        Save-QaConfig -AppRoot $script:AppRoot -Config $config | Out-Null
        $script:Config=$config
        if($d.FindName('Password').SecurePassword.Length -gt 0){
            try{$credential=New-Object Management.Automation.PSCredential($source.Username,$d.FindName('Password').SecurePassword.Copy());Save-QaSavedCredential -AppRoot $script:AppRoot -ScannerId $id -ExpectedPath ([string]$source.Path) -Credential $credential | Out-Null}
            catch{Show-Note ('The scanner was added, but its sign-in could not be saved. '+$_.Exception.Message) 'Saved sign-in needs attention' $true}
        }
        $d.FindName('Password').Clear()
        Fill-Settings;Refresh-ScannerFilterOptions;Refresh-Dashboard
        $script:Controls.StatusText.Text=$name+' added. Click Reconnect drives or Update Reports when ready.'
    }catch{$d.FindName('Password').Clear();Show-Note $_.Exception.Message 'Scanner could not be added' $true}
}

function Fill-Settings {
    $script:Controls.ArchivePath.Text=[string]$script:Config.ArchiveRoot
    $script:Controls.DailyLookback.Text=[string]$script:Config.LookbackDays
    $script:Controls.MonthlyLookback.Text=[string]$script:Config.MonthlyLookbackMonths
    $script:Controls.MinimumAge.Text=[string]$script:Config.MinimumFileAgeSeconds
    $script:Controls.AutoUpdateOnOpen.IsChecked=[bool](Value-Or $script:Config AutoUpdateOnOpen $true)
    $script:Controls.MonitorMinutes.Text=[string](Value-Or $script:Config MonitorMinutes 15)
    $script:Controls.AutoAnalyze.IsChecked=[bool](Value-Or $script:Config AutoAnalyze $true)
    $script:Controls.ScannerSettingsPanel.Children.Clear()
    $script:ScannerEditors=@{}
    $selectedConnection=[string]$script:Controls.ConnectionScannerSelector.SelectedValue
    $script:Controls.ConnectionScannerSelector.ItemsSource=@($script:Config.Sources|ForEach-Object{[pscustomobject]@{Value=[string]$_.Scanner;Label=[string]$_.Name}})
    if($selectedConnection -and @($script:Config.Sources|Where-Object Scanner -eq $selectedConnection).Count){$script:Controls.ConnectionScannerSelector.SelectedValue=$selectedConnection}else{$script:Controls.ConnectionScannerSelector.SelectedIndex=0}
    foreach ($source in @($script:Config.Sources)) {
        $name=[Security.SecurityElement]::Escape([string]$source.Name)
        $row=Load-Window @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" BorderBrush="#2B3C55" BorderThickness="0,1,0,0" Padding="0,5,0,15"><StackPanel><Grid Margin="0,12,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Display name" Foreground="#91A9C7" Margin="0,0,0,6"/><TextBox x:Name="DisplayName"/></StackPanel><StackPanel Grid.Column="2"><TextBlock Text="Username" Foreground="#91A9C7" Margin="0,0,0,6"/><TextBox x:Name="Username"/></StackPanel></Grid><TextBlock Text="Network report folder (server/IP, share, and folder)" Foreground="#91A9C7" Margin="0,12,0,6"/><TextBox x:Name="SourcePath"/><TextBlock Text="Example: \\CT-EDGE\Reports\ConstancyReports" Foreground="#6F8AA9" FontSize="10" Margin="0,6,0,0"/><Grid Margin="0,12,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Password (blank keeps the saved sign-in)" Foreground="#91A9C7" Margin="0,0,0,6"/><PasswordBox x:Name="Password" Padding="10,8" Background="#182940" Foreground="White" BorderBrush="#314763"/></StackPanel><Button x:Name="Forget" Grid.Column="1" Content="Forget saved sign-in" Margin="12,19,0,0" Padding="12,9"/></Grid><TextBlock x:Name="SavedStatus" Foreground="#90BFC4" FontSize="12" Margin="0,9,0,0"/><WrapPanel Margin="0,12,0,8"><Button x:Name="SaveConnect" Content="Save sign-in &amp; reconnect this scanner" Background="#1C6670" Padding="12,9"/></WrapPanel><TextBlock x:Name="ConnectionResult" Foreground="#A8C6D4" FontSize="12" Margin="0,0,0,9"/><Expander Header="QA schedule, checklist &amp; classification" x:Name="QaOptions" IsExpanded="False" Foreground="#AFC7DA"><StackPanel><WrapPanel Margin="0,12,0,0"><StackPanel Width="115" Margin="0,0,14,0"><TextBlock Text="Preferred drive" Foreground="#91A9C7" Margin="0,0,0,6"/><TextBox x:Name="Drive" MaxLength="1"/></StackPanel><StackPanel Width="140" Margin="0,0,14,0"><TextBlock Text="Monthly hint (KB)" Foreground="#91A9C7" Margin="0,0,0,6"/><TextBox x:Name="Threshold"/></StackPanel><StackPanel Width="145" Margin="0,0,14,0"><TextBlock Text="Expected Daily QA" Foreground="#91A9C7" Margin="0,0,0,6"/><ComboBox x:Name="Schedule"/></StackPanel><StackPanel Width="155"><TextBlock Text="Active from (yyyy-MM-dd)" Foreground="#91A9C7" Margin="0,0,0,6"/><TextBox x:Name="ActiveFrom"/></StackPanel></WrapPanel><CheckBox x:Name="MonthlyExpected" Content="Include this scanner in Monthly QA coverage review" Margin="0,12,0,0"/><TextBlock Text="Required Monthly QA items (department checklist)" Foreground="#91A9C7" Margin="0,12,0,6"/><TextBox x:Name="MonthlyChecklist" TextWrapping="Wrap" AcceptsReturn="False" MinHeight="38"/><WrapPanel Margin="0,12,0,0"><StackPanel Width="155" Margin="0,0,14,0"><TextBlock Text="Checklist effective (yyyy-MM)"/><TextBox x:Name="ChecklistEffectiveMonth"/></StackPanel><StackPanel Width="155" Margin="0,0,14,0"><TextBlock Text="Monthly due day (0 = not set)"/><TextBox x:Name="MonthlyDueDay"/></StackPanel><StackPanel Width="260"><TextBlock Text="Daily exceptions (yyyy-MM-dd; ...)"/><TextBox x:Name="ExcludedDates"/></StackPanel></WrapPanel><TextBlock Text="Separate approved item names with semicolons. Example only: Light marker; MTF; Slice thickness. Leave blank if no department checklist is set; monthly completeness will not be assessed." Foreground="#729CB8" TextWrapping="Wrap" FontSize="10" Margin="0,7,0,0"/></StackPanel></Expander></StackPanel></Border>
"@
        $ed=@{}
        foreach ($n in @('DisplayName','Username','SourcePath','Password','SavedStatus','Forget','Drive','Threshold','Schedule','ActiveFrom','MonthlyExpected','MonthlyChecklist','ChecklistEffectiveMonth','MonthlyDueDay','ExcludedDates','SaveConnect','ConnectionResult','QaOptions')) { $ed[$n]=$row.FindName($n) }
        $ed.DisplayName.Text=[string]$source.Name;$ed.Username.Text=[string](Value-Or $source Username 'SCANNER_USERNAME')
        $ed.SourcePath.Text=[string]$source.Path; $ed.Drive.Text=[string]$source.DriveLetter
        $ed.Threshold.Text=[string]$source.MonthlyThresholdKB; $ed.ActiveFrom.Text=[string]$source.ActiveFrom
        foreach($schedule in @('AllDays','Weekdays','Off')) { [void]$ed.Schedule.Items.Add($schedule) }
        $ed.Schedule.SelectedItem=[string]$source.DailySchedule
        $ed.MonthlyExpected.IsChecked=[bool]$source.ExpectedMonthly
        $ed.MonthlyChecklist.Text=(@(Value-Or $source MonthlyChecklist @()) -join '; ')
        $ed.ChecklistEffectiveMonth.Text=(Get-Date).ToString('yyyy-MM')
        $ed.MonthlyDueDay.Text=[string](Value-Or $source MonthlyDueDay 0)
        $ed.ExcludedDates.Text=(@(Value-Or $source ExcludedDates @()) -join '; ')
        $ed.Row=$row
        $script:ScannerEditors[[string]$source.Scanner]=$ed
        $ed.Forget.Tag=[string]$source.Scanner
        $ed.Forget.Add_Click({param($sender,$eventArgs) try{Remove-QaSavedCredential -AppRoot $script:AppRoot -ScannerId ([string]$sender.Tag) | Out-Null;$editor=$script:ScannerEditors[[string]$sender.Tag];$editor.Password.Clear();$editor.SavedStatus.Text='Saved sign-in removed. Existing Windows connections are not disconnected.';$sender.IsEnabled=$false}catch{Show-Note $_.Exception.Message 'Saved sign-in could not be removed' $true}})
        $ed.SaveConnect.Tag=[string]$source.Scanner
        $ed.SaveConnect.Add_Click({param($sender,$eventArgs) if(Save-Settings -CredentialScannerId ([string]$sender.Tag)){Start-Work -Mode Reconnect -Plan ([pscustomobject]@{ScannerId=[string]$sender.Tag})}})
        if($script:ConnectionFeedback.ContainsKey([string]$source.Scanner)){$ed.ConnectionResult.Text=$script:ConnectionFeedback[[string]$source.Scanner].Message}
        Set-CredentialStatusLabel $source $ed
        [void]$script:Controls.ScannerSettingsPanel.Children.Add($row)
    }
    Show-ConnectionEditor
}
function Save-Settings {
    param([string]$CredentialScannerId='')
    try {
        # Work on a detached copy so failed validation cannot change the active configuration.
        $cfg=$script:Config | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $path=$script:Controls.ArchivePath.Text.Trim()
        if (-not [IO.Path]::IsPathRooted($path)) { throw 'Choose a full archive destination path.' }
        $old=[string]$cfg.ArchiveRoot
        if ([IO.Path]::GetFullPath($old) -ne [IO.Path]::GetFullPath($path)) {
            $answer=[Windows.MessageBox]::Show($script:Window,'Switch to this archive location? Existing files will remain where they are. Use the reuse tool to safely import an older archive.','Change archive location',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question)
            if($answer -ne [Windows.MessageBoxResult]::Yes) { return $false }
        }
        $cfg.ArchiveRoot=$path
        $cfg.LookbackDays=[int]$script:Controls.DailyLookback.Text
        $cfg.MonthlyLookbackMonths=[int]$script:Controls.MonthlyLookback.Text
        $cfg.MinimumFileAgeSeconds=[int]$script:Controls.MinimumAge.Text
        $cfg.AutoUpdateOnOpen=[bool]$script:Controls.AutoUpdateOnOpen.IsChecked
        $interval=[int]$script:Controls.MonitorMinutes.Text
        if($interval -ne 0 -and ($interval -lt 5 -or $interval -gt 240)){throw 'Choose 0 to pause checks, or 5 through 240 minutes.'}
        $cfg|Add-Member MonitorMinutes $interval -Force
        $cfg|Add-Member AutoAnalyze ([bool]$script:Controls.AutoAnalyze.IsChecked) -Force
        if ($cfg.LookbackDays -lt 1 -or $cfg.LookbackDays -gt 730) { throw 'Daily lookback must be from 1 to 730 days.' }
        if ($cfg.MonthlyLookbackMonths -lt 1 -or $cfg.MonthlyLookbackMonths -gt 36) { throw 'Monthly lookback must be from 1 to 36 months.' }
        if ($cfg.MinimumFileAgeSeconds -lt 0 -or $cfg.MinimumFileAgeSeconds -gt 3600) { throw 'Minimum PDF age must be from 0 to 3600 seconds.' }
        foreach ($source in @($cfg.Sources)) {
            $ed=$script:ScannerEditors[[string]$source.Scanner]
            $source.Name=$ed.DisplayName.Text.Trim();$source.Username=$ed.Username.Text.Trim()
            if(-not $source.Name -or -not $source.Username){throw 'Enter a display name and username for every scanner.'}
            $source.Path=$ed.SourcePath.Text.Trim(); $source.DriveLetter=$ed.Drive.Text.Trim().ToUpperInvariant()
            if($source.Path -notmatch '^\\\\[^\\]+\\[^\\]+') { throw ('Enter a valid UNC folder for '+$source.Name) }
            if($source.DriveLetter -notmatch '^[D-Z]$') { throw ('Choose one drive letter D through Z for '+$source.Name) }
            $source.MonthlyThresholdKB=[double]$ed.Threshold.Text
            if ($source.MonthlyThresholdKB -lt 1 -or $source.MonthlyThresholdKB -gt 10000) { throw 'Monthly candidate threshold must be from 1 to 10000 KB.' }
            $source.DailySchedule=[string]$ed.Schedule.SelectedItem
            $source.ExpectedMonthly=[bool]$ed.MonthlyExpected.IsChecked
            $checklist=[string[]]@($ed.MonthlyChecklist.Text.Split(';') | ForEach-Object {$_.Trim()} | Where-Object {$_})
            if($checklist.Count -gt 32){throw 'A Monthly QA checklist can contain up to 32 approved item names.'}
            if(@($checklist | Group-Object | Where-Object {$_.Count -gt 1}).Count){throw ('Use each Monthly QA checklist item once for '+$source.Name+'.')}
            $source.MonthlyChecklist=$checklist
            $due=[int]$ed.MonthlyDueDay.Text;if($due -lt 0 -or $due -gt 31){throw 'Monthly due day must be 0 through 31.'}
            $source|Add-Member MonthlyDueDay $due -Force
            $source|Add-Member ChecklistEffectiveMonth ($ed.ChecklistEffectiveMonth.Text.Trim()) -Force
            $exceptions=@($ed.ExcludedDates.Text.Split(';')|ForEach-Object{$_.Trim()}|Where-Object{$_})
            foreach($exception in $exceptions){$date=[datetime]::MinValue;if(-not [datetime]::TryParseExact($exception,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)){throw 'Daily exceptions must use yyyy-MM-dd, separated by semicolons.'}}
            $source|Add-Member ExcludedDates ([object[]]$exceptions) -Force
            $source.ActiveFrom=$ed.ActiveFrom.Text.Trim()
            if ($source.ActiveFrom) {
                $parsed=[datetime]::MinValue
                if(-not [datetime]::TryParseExact($source.ActiveFrom,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)) { throw 'Active-from dates must use yyyy-MM-dd, for example 2024-01-01.' }
            }
        }
        if (@($cfg.Sources | Group-Object DriveLetter | Where-Object Count -gt 1).Count) { throw 'Use a different preferred drive letter for each scanner.' }
        Save-QaConfig -AppRoot $script:AppRoot -Config $cfg | Out-Null
        $script:Config=$cfg
        Write-QaSupportEvent -AppRoot $script:AppRoot -Operation Settings -Outcome Completed -Counts @{Scanners=@($script:Config.Sources).Count}
        Save-EditedCredentials -ScannerId $CredentialScannerId;Refresh-ScannerFilterOptions
        Refresh-Dashboard
        $script:Controls.StatusText.Text='Advanced settings saved.'
        return $true
    } catch { Show-Note $_.Exception.Message 'Check settings' $true; return $false }
}
function Set-Busy {
    param([bool]$Busy)
    $script:Busy=$Busy
    foreach ($name in @('SetupButton','UpdateButton','SaveSettingsButton','ReconnectButton','AuditButton','ReclassifyButton','ReviewReportButton','ReviewHistoryButton','QuickReviewButton','AdoptLegacyButton','BrowseArchiveButton','ExportReportsButton','ReviewPendingButton','ClearFiltersButton','ReadReportTextButton','BrowseReportsButton','OpenFolderButton','AnalyzeButton','BackupButton','RestoreButton','CompatibilityButton','RetryAnalysisButton','SourceAuditButton','ImportConnectionsButton','ManageConnectionsButton','CoverageSettingsButton','MonthlySettingsButton','ChooseUpdateButton','InstallUpdateButton')) { $script:Controls[$name].IsEnabled=(-not $Busy) }
    $script:Controls.AdvancedView.IsEnabled=(-not $Busy)
    # Searching an immutable saved snapshot remains available during network checks.
    $script:Controls.ReportFilters.IsEnabled=$true
    if(-not $Busy){$script:Controls.InstallUpdateButton.IsEnabled=($null -ne $script:PreparedUpdate)}
    if(-not $Busy){$script:Controls.ExportReportsButton.IsEnabled=(@($script:FilteredReports).Count -gt 0)}
    $script:Controls.CancelButton.Visibility=$(if($Busy){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed})
    $script:Controls.WorkProgress.Visibility=$(if($Busy){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed})
    Update-QuickQueueControls
    if($Busy -and $script:CurrentMode -eq 'Update'){$script:Controls.StepOne.Text='1. Wait for report update'}
}
function Start-Work {
    param([string]$Mode,$Plan=$null,$Decisions=@(),[string]$LegacyRoot='',$Credentials=@{})
    if ($script:Busy) { return }
    if($Mode -eq 'Reconnect'){
        if($Credentials.Count -eq 0){$script:AttemptedCredentials=@{};$script:RememberPending=@{};$script:ReconnectTarget=[string](Value-Or $Plan ScannerId '')}
        foreach($key in $Credentials.Keys){$script:AttemptedCredentials[[string]$key]=$true}
    }
    $script:CurrentMode=$Mode
    $script:OperationClock=[Diagnostics.Stopwatch]::StartNew()
    if(-not $script:DemoPreview){Write-QaSupportEvent -AppRoot $script:AppRoot -Operation $Mode -Outcome Started}
    $shared=[hashtable]::Synchronized(@{Message='Preparing your request...'; Percent=0; Cancel=$false; Done=$false; Error=''; Result=$null})
    $runspace=[RunspaceFactory]::CreateRunspace(); $runspace.ApartmentState='MTA'; $runspace.ThreadOptions='ReuseThread'; $runspace.Open()
    $ps=[PowerShell]::Create(); $ps.Runspace=$runspace
    $workerCode=@'
param($appRoot,$config,$mode,$progress,$plan,$decisions,$legacyRoot,$credentials)
$ErrorActionPreference='Stop'
try {
 $connectionWarnings=New-Object 'System.Collections.Generic.List[string]'
 Import-Module (Join-Path $appRoot 'App\Archive.psm1') -Force -ErrorAction Stop
 if ($mode -in @('Backup','Restore','Compatibility')) {
  Import-Module (Join-Path $appRoot 'App\Maintenance.psm1') -Force
  if($mode -eq 'Backup'){$progress.Result=New-QaBackup -AppRoot $appRoot -Config $config -DestinationPath $plan.DestinationPath -Progress $progress}
  elseif($mode -eq 'Restore'){$progress.Result=Restore-QaBackup -Path $plan.Path -DestinationFolder $plan.DestinationFolder -Progress $progress}
  else{$rows=@(Get-QaCompatibility -AppRoot $appRoot -Config $config);$progress.Result=[pscustomobject]@{Rows=$rows;Summary=[pscustomobject]@{Description='Computer compatibility check finished.';Cancelled=$false}}}
 } elseif($mode -eq 'SourceAudit') {
  Import-Module (Join-Path $appRoot 'App\Insights.psm1') -Force
  $progress.Result=Invoke-QaSourceAudit -Config $config -Progress $progress
 } elseif($mode -eq 'Analysis') {
  Import-Module (Join-Path $appRoot 'App\Insights.psm1') -Force
  $progress.Result=Invoke-QaAnalysis -Config $config -Progress $progress
 } elseif ($mode -eq 'PdfPreview') {
  Import-Module (Join-Path $appRoot 'App\Process.psm1') -Force
  $progress.Result=Invoke-QaIsolatedTask PreviewPdf ([pscustomobject]@{Config=$config;RecordId=[string]$plan.RecordId;PageNumber=[int]$plan.PageNumber}) -TimeoutSeconds 30 -Progress $progress
 } elseif ($mode -eq 'PdfRead') {
  Import-Module (Join-Path $appRoot 'App\PdfReader.psm1') -Force -ErrorAction Stop
  Import-Module (Join-Path $appRoot 'App\Process.psm1') -Force
  $progress.Result=Invoke-QaIsolatedTask ReadPdf ([pscustomobject]@{Config=$config;RecordId=[string]$plan.RecordId}) -TimeoutSeconds 60 -Progress $progress
 } elseif ($mode -eq 'Export') {
  Import-Module (Join-Path $appRoot 'App\Reports.psm1') -Force -ErrorAction Stop
  $progress.Result=Invoke-QaExport -Config $config -RecordIds ([string[]]$plan.RecordIds) -DestinationPath ([string]$plan.DestinationPath) -Progress $progress
 } elseif ($mode -eq 'BrowseRefresh') {
  Import-Module (Join-Path $appRoot 'App\Browse.psm1') -Force -ErrorAction Stop
  $progress.Result=Invoke-QaBrowseRefresh -Config $config -Progress $progress
 } elseif ($mode -eq 'SetupPreview') {
  $legacyIndex=Join-Path $config.ArchiveRoot 'QA_Master_Index_v2.csv'
  $statePath=Join-Path $config.ArchiveRoot '.ctqa\state.json'
  if((Test-Path -LiteralPath $legacyIndex -PathType Leaf) -and -not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
   $progress.Result=[pscustomobject]@{LegacyRoot=$config.ArchiveRoot;LegacyCount=@(Import-Csv -LiteralPath $legacyIndex).Count}
  } else { $progress.Result=Invoke-QaOperation -Config $config -Mode Preview -Progress $progress }
  if($null -ne $plan -and $null -ne $plan.PSObject.Properties['Connections']){Add-Member -InputObject $progress.Result -NotePropertyName ConnectionResults -NotePropertyValue @($plan.Connections) -Force}
 } elseif ($mode -eq 'Reconnect') {
  Import-Module (Join-Path $appRoot 'App\Network.psm1') -Force -ErrorAction Stop
  Import-Module (Join-Path $appRoot 'App\Credentials.psm1') -Force -ErrorAction Stop
  $results=New-Object 'System.Collections.Generic.List[object]'
  $i=0
  $connectionSources=@($config.Sources)
  if($null -ne $plan -and $null -ne $plan.PSObject.Properties['ScannerId'] -and $plan.ScannerId){$connectionSources=@($config.Sources|Where-Object Scanner -eq $plan.ScannerId)}
  foreach($scanner in $connectionSources) {
   if ($progress.Cancel) { break }
   $progress.Message='Checking connection to '+$scanner.Name+'...'
   $cred=$null
   if($credentials.ContainsKey([string]$scanner.Scanner)) { $cred=$credentials[[string]$scanner.Scanner] }
   else{
    try{$cred=Get-QaSavedCredential -AppRoot $appRoot -ScannerId ([string]$scanner.Scanner) -ExpectedUsername ([string]$scanner.Username) -ExpectedPath ([string]$scanner.Path)}
    catch{[void]$connectionWarnings.Add(([string]$scanner.Name+' - Saved sign-in could not be read. Enter the password again in Advanced settings.'));$cred=$null}
   }
   $connectionClock=[Diagnostics.Stopwatch]::StartNew();$connectionResult=Reconnect-QaScanner -Scanner $scanner -Credential $cred
   $connectionResult|Add-Member DurationMs ([long]$connectionClock.ElapsedMilliseconds) -Force
   [void]$results.Add($connectionResult)
   $i++; $progress.Percent=[int](100*$i/[math]::Max(1,$connectionSources.Count))
  }
  $progress.Result=[pscustomobject]@{Connections=@($results.ToArray());ConnectionWarnings=@($connectionWarnings.ToArray())}
 } else {
  if($mode -eq 'Update'){
   Import-Module (Join-Path $appRoot 'App\Network.psm1') -Force -ErrorAction Stop
   Import-Module (Join-Path $appRoot 'App\Credentials.psm1') -Force -ErrorAction Stop
   foreach($scanner in @($config.Sources)){
    if($progress.Cancel){break}
    $progress.Message='Checking access to '+$scanner.Name+'...'
    $saved=$null
    try{$saved=Get-QaSavedCredential -AppRoot $appRoot -ScannerId ([string]$scanner.Scanner) -ExpectedUsername ([string]$scanner.Username) -ExpectedPath ([string]$scanner.Path)}
    catch{[void]$connectionWarnings.Add(([string]$scanner.Name+' - Saved sign-in could not be read. Enter the password again in Advanced settings.'))}
    if($null -ne $saved){try{$null=Reconnect-QaScanner -Scanner $scanner -Credential $saved}catch{[void]$connectionWarnings.Add(([string]$scanner.Name+' - Saved sign-in could not be used. Check the connection in Advanced settings.'))}}
   }
  }
  $arguments=@{Config=$config; Mode=$mode; Progress=$progress}
  if($null -ne $plan) { $arguments.Plan=$plan }
  if(@($decisions).Count) { $arguments.Decisions=$decisions }
  if($legacyRoot) { $arguments.LegacyRoot=$legacyRoot }
  $progress.Result=Invoke-QaOperation @arguments
  if($connectionWarnings.Count){Add-Member -InputObject $progress.Result -NotePropertyName ConnectionWarnings -NotePropertyValue @($connectionWarnings.ToArray()) -Force}
 }
} catch { $progress.Error=$_.Exception.Message }
finally { $progress.Done=$true }
'@
    [void]$ps.AddScript($workerCode).AddArgument($script:AppRoot).AddArgument($script:Config).AddArgument($Mode).AddArgument($shared).AddArgument($Plan).AddArgument($Decisions).AddArgument($LegacyRoot).AddArgument($Credentials)
    try {
        $handle=$ps.BeginInvoke()
        $script:Worker=[pscustomobject]@{PowerShell=$ps; Runspace=$runspace; Handle=$handle; Shared=$shared}
        Set-Busy $true; $script:Controls.StatusText.Text=$shared.Message
    } catch { $ps.Dispose(); $runspace.Dispose(); throw }
}
function Summary-Text {
    param($Summary)
    if ($null -eq $Summary) { return 'Operation complete. Review the attention center for details.' }
    $pairs=New-Object 'System.Collections.Generic.List[string]'
    foreach($field in @('Total','NewOrChanged','Unchanged','Pending','Deferred','Copied','Verified','Failed')) {
        if($null -ne $Summary.PSObject.Properties[$field] -and ([int]$Summary.$field -gt 0 -or $field -eq 'Total')) {
            $label=@{Total='found';NewOrChanged='new or changed';Unchanged='unchanged';Pending='pending review';Deferred='deferred';Copied='copied';Verified='verified';Failed='could not be completed'}[$field]
            [void]$pairs.Add(('{0:N0} {1}' -f [int]$Summary.$field,$label))
        }
    }
    return ($pairs -join '   /   ')
}
function Show-Preview {
    param($Result,[string]$ApplyMode='Import')
    $plan=Value-Or $Result Plan $null
    if($null -eq $plan) { Show-Note 'The preview did not return a usable copy plan. No import was started.' 'Preview unavailable' $true; return }
    $text=Summary-Text (Value-Or $plan Summary)
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock x:Name="PreviewTitle" Text="Review your import" FontSize="23" FontWeight="SemiBold"/><TextBlock x:Name="PreviewSummary" Grid.Row="1" Foreground="#A9BDD5" Margin="0,10,0,17"/><TextBlock x:Name="PreviewConnections" Grid.Row="2" Foreground="#E1B870" TextWrapping="Wrap" Margin="0,0,0,14"/><DataGrid x:Name="PreviewGrid" Grid.Row="3"><DataGrid.Columns><DataGridTextColumn Header="Scanner" Binding="{Binding ScannerName}" Width="100"/><DataGridTextColumn Header="Original filename" Binding="{Binding OriginalFileName}" Width="*"/><DataGridTextColumn Header="Report type" Binding="{Binding CategoryLabel}" Width="190"/><DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="130"/></DataGrid.Columns></DataGrid><TextBlock x:Name="PreviewNotice" Grid.Row="4" Text="Only accessible scanners are included. Pending candidates are not confirmed Monthly QA. Originals are never changed. Each new copy is checked with SHA-256 before it enters the index." Foreground="#8EA7C4" TextWrapping="Wrap" Margin="0,15,0,15"/><StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="Reconnect" Content="Reconnect scanners" Margin="0,0,10,0"/><Button x:Name="Dismiss" Content="Back" Margin="0,0,10,0"/><Button x:Name="Apply" Content="Confirm and copy reports" Background="#1D6871" BorderBrush="#33ACAC"/></StackPanel>
'@
    $dialog=New-Dialog 'Preview before making changes' $content 1000 630
    $dialog.FindName('PreviewSummary').Text=$text
    $warnings=New-Object 'System.Collections.Generic.List[string]'
    foreach($scanner in @(Value-Or $Result Scanners @())) {
        if([string]$scanner.Status -notin @('Connected','OK')) {
            [void]$warnings.Add(([string](Value-Or $scanner Name (Value-Or $scanner Scanner))+': '+[string](Value-Or $scanner Message 'Connection unavailable. Existing archive records remain available.')))
        }
    }
    foreach($connection in @(Value-Or $Result ConnectionResults @())){if($connection.Status -ne 'Connected'){[void]$warnings.Add(([string]$connection.Scanner+': '+[string]$connection.Message))}}
    $dialog.FindName('PreviewConnections').Text=(@($warnings|Select-Object -Unique) -join "`r`n")
    $dialog.FindName('Reconnect').Visibility=$(if($warnings.Count -and $ApplyMode -eq 'Import'){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed})
    $dialog.FindName('Reconnect').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender);$parent.Tag='Reconnect';$parent.DialogResult=$false})
    Add-RecordLabels $plan.Items
    $dialog.FindName('PreviewGrid').ItemsSource=@($plan.Items)
    if ($ApplyMode -eq 'Reclassify') {
        foreach($item in @($plan.Items)){$components=@(Value-Or $item ConfirmedComponents @());$label=$(if($components.Count){$components -join '; '}else{'No items selected (report label only)'});Add-Member -InputObject $item -NotePropertyName ConfirmedComponentsLabel -NotePropertyValue $label -Force}
        $column=New-Object System.Windows.Controls.DataGridTextColumn
        $column.Header='Confirmed checklist items';$column.Binding=New-Object System.Windows.Data.Binding('ConfirmedComponentsLabel');$column.Width=220
        [void]$dialog.FindName('PreviewGrid').Columns.Add($column)
        $dialog.FindName('PreviewTitle').Text='Check the report label change'
        $dialog.FindName('PreviewNotice').Text='Confirm only after checking these PDFs against your department checklist. Every decision retains the reviewer, reason, report hash, and explicitly selected items in the master index and retained review history. A Monthly report label alone does not confirm a complete Monthly QA set.'
        $dialog.FindName('Apply').Content='Confirm report type'
    }
    # Event closures hold only this dialog; no worker execution is attached to dispatcher objects.
    $dialog.FindName('Dismiss').Add_Click({ param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).DialogResult=$false })
    if($ApplyMode -eq 'Import' -and @($plan.Items).Count -eq 0){$dialog.FindName('Apply').IsEnabled=$false;$dialog.FindName('PreviewNotice').Text='No reports were found. Check the connection details above, apply your local profile in Advanced settings, or reconnect scanners before confirming an import.'}
    $dialog.FindName('Apply').Add_Click({ param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).DialogResult=$true })
    if($dialog.ShowDialog() -eq $true) {
        if($ApplyMode -eq 'Reclassify') { Start-Work -Mode Reclassify -Decisions $script:PendingDecisions }
        else { Start-Work -Mode Import -Plan $plan }
    } elseif([string]$dialog.Tag -eq 'Reconnect') {
        $script:AfterReconnect='SetupPreview'
        Start-Work -Mode Reconnect
    } else { $script:Controls.StatusText.Text='Preview closed. No changes were applied.' }
}
function Show-Credentials {
    param([string]$Name,[string]$Username='SCANNER_USERNAME',[string]$ScannerId='',[string]$Failure='')
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><TextBlock x:Name="CredentialTitle" FontSize="21" FontWeight="SemiBold"/><TextBlock Grid.Row="1" Text="Use the approved scanner account. A password is required when Windows has no existing access. Choose Remember to save it only after this connection succeeds." TextWrapping="Wrap" Foreground="#9CB3CE" Margin="0,12,0,18"/><StackPanel Grid.Row="2"><TextBlock Text="Username (or DOMAIN\username)" Foreground="#9CB3CE" Margin="0,0,0,7"/><TextBox x:Name="Username" Text="SCANNER_USERNAME"/></StackPanel><StackPanel Grid.Row="3" Margin="0,14,0,0"><TextBlock Text="Password" Foreground="#9CB3CE" Margin="0,0,0,7"/><PasswordBox x:Name="Password" Padding="10,8" Background="#182940" Foreground="White" BorderBrush="#314763"/></StackPanel><StackPanel Grid.Row="4" Margin="0,10,0,15"><CheckBox x:Name="Remember" Content="Remember this sign-in on this PC"/><TextBlock x:Name="Failure" Foreground="#E1BE83" TextWrapping="Wrap" Margin="0,7,0,0"/></StackPanel><StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="Skip" Content="Skip scanner" Margin="0,0,10,0"/><Button x:Name="Connect" Content="Reconnect" Background="#1D6871"/></StackPanel>
'@
    $d=New-Dialog 'Secure scanner connection' $content 620 520
    $d.FindName('CredentialTitle').Text='Connect to '+$Name
    $d.FindName('Username').Text=$Username
    $d.FindName('Failure').Text=$Failure
    $d.FindName('Skip').Add_Click({param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).DialogResult=$false})
    $d.FindName('Connect').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender); if($parent.FindName('Username').Text.Trim() -and $parent.FindName('Password').SecurePassword.Length -gt 0){$parent.DialogResult=$true}})
    if($d.ShowDialog() -eq $true) {
        $secure=$d.FindName('Password').SecurePassword.Copy()
        $cred=New-Object System.Management.Automation.PSCredential($d.FindName('Username').Text.Trim(),$secure)
        $d.FindName('Password').Clear()
        if($ScannerId -and $d.FindName('Remember').IsChecked){$script:RememberPending[$ScannerId]=$cred}
        return $cred
    }
    $d.FindName('Password').Clear()
    return $null
}
function Finish-Connections {
    param($Result)
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $needed=@{}
    foreach($connection in @(Value-Or $Result Connections @())) {
        $sourceName=[string]$connection.Scanner
        $sourceMatch=@($script:Config.Sources | Where-Object Scanner -eq $connection.Scanner)
        if($sourceMatch.Count){$sourceName=[string]$sourceMatch[0].Name}
        $feedback=[pscustomobject]@{Scanner=[string]$connection.Scanner;Status=[string]$connection.Status;Message=[string]$connection.Message;NativeCode=[int](Value-Or $connection NativeCode 0);CheckedUtc=[datetime]::UtcNow}
        $script:ConnectionFeedback[[string]$connection.Scanner]=$feedback
        if($script:ScannerEditors.ContainsKey([string]$connection.Scanner)){$script:ScannerEditors[[string]$connection.Scanner].ConnectionResult.Text=[string]$connection.Message}
        Write-QaSupportEvent -AppRoot $script:AppRoot -Operation Reconnect -Outcome $(if($connection.Status -eq 'Connected'){'Completed'}else{'Failed'}) -NativeCode $feedback.NativeCode -DurationMs ([long](Value-Or $connection DurationMs 0)) -ScannerNumber (1+[Array]::IndexOf([object[]]$script:Config.Sources,$sourceMatch[0])) -ErrorKind $(if($connection.Status -eq 'Connected'){'None'}else{Get-QaSupportErrorKind -Message ([string]$connection.Message) -NativeCode $feedback.NativeCode})
        if($script:RememberPending.ContainsKey([string]$connection.Scanner)){
            $pending=$script:RememberPending[[string]$connection.Scanner]
            if($connection.Status -eq 'Connected' -and $sourceMatch.Count){try{[void](Save-QaSavedCredential -AppRoot $script:AppRoot -ScannerId ([string]$connection.Scanner) -ExpectedPath ([string]$sourceMatch[0].Path) -Credential $pending);Set-CredentialStatusLabel $sourceMatch[0] $script:ScannerEditors[[string]$connection.Scanner]}catch{[void]$lines.Add('The connection succeeded, but the sign-in was not remembered. Check the saved username in Advanced settings.')}}
            $script:RememberPending.Remove([string]$connection.Scanner)
        }
        [void]$lines.Add(($sourceName+': '+[string]$connection.Message))
        if([string]$connection.Status -eq 'CredentialsRequired' -and -not $script:AttemptedCredentials.ContainsKey([string]$connection.Scanner)) {
            $source=@($script:Config.Sources | Where-Object Scanner -eq $connection.Scanner)[0]
            $credential=Show-Credentials -Name ([string]$source.Name) -Username ([string](Value-Or $source Username 'SCANNER_USERNAME')) -ScannerId ([string]$source.Scanner) -Failure ([string]$connection.Message)
            if($null -ne $credential) { $needed[[string]$connection.Scanner]=$credential }
        }
    }
    if($needed.Count) { Start-Work -Mode Reconnect -Credentials $needed -Plan ([pscustomobject]@{ScannerId=$script:ReconnectTarget}); return }
    Refresh-Dashboard
    if($script:AfterReconnect) {
        $next=$script:AfterReconnect; $script:AfterReconnect=''
        $script:Controls.StatusText.Text='Connections checked. Preparing the report preview...'
        Start-Work -Mode $next -Plan ([pscustomobject]@{Connections=@(Value-Or $Result Connections @())})
        return
    }
    Show-Note (($lines -join "`r`n`r`n")+"`r`n`r`nUse Update Reports to refresh scanner status and import accessible reports.") 'Scanner connections'
}
function Review-SelectedReport {
    $record=$script:Controls.ReportsGrid.SelectedItem
    if($null -eq $record){Show-Note 'Select a saved report first.';return}
    $source=@($script:Config.Sources | Where-Object {[string]$_.Scanner -eq [string]$record.Scanner})
    if($source.Count -ne 1){Show-Note 'This report does not have a unique scanner connection in settings.' 'Scanner settings need attention' $true;return}
    $reviewMonth=if([string]$record.ReportDate -match '^\d{4}-\d{2}-\d{2}$'){([string]$record.ReportDate).Substring(0,7)}else{(Get-Date).ToString('yyyy-MM')}
    $required=[string[]]@(Get-QaChecklistForMonth $source[0] $reviewMonth)
    $previous=[string[]]@(Value-Or $record ConfirmedComponents @())
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock Text="Choose the correct report type" FontSize="23" FontWeight="SemiBold"/>
<ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,15,0,15"><StackPanel>
 <TextBlock x:Name="ReportName" Foreground="#9CB5D0" TextWrapping="Wrap" Margin="0,0,0,15"/>
 <StackPanel><TextBlock Text="Report type" Margin="0,0,0,7"/><ComboBox x:Name="Category"/></StackPanel>
 <Border Background="#152B40" BorderBrush="#29445B" BorderThickness="1" CornerRadius="9" Padding="14" Margin="0,15,0,0"><StackPanel>
  <TextBlock Text="Which required items are confirmed in this PDF?" FontWeight="SemiBold"/>
  <TextBlock Text="One combined report can cover every item, or several reports can cover different items. Check only items verified in this PDF against your department checklist." Foreground="#9BB7D0" FontSize="11" TextWrapping="Wrap" Margin="0,7,0,10"/>
  <TextBlock x:Name="ChecklistNote" Foreground="#DCC087" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,9"/>
  <StackPanel x:Name="ChecklistControls"><ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="160"><StackPanel x:Name="ComponentList"/></ScrollViewer><Button x:Name="SelectAllComponents" Content="Select all listed items" Padding="10,6" HorizontalAlignment="Left" Margin="0,8,0,0"/></StackPanel>
  <TextBlock x:Name="ChecklistModeNote" Foreground="#789AB9" FontSize="10" TextWrapping="Wrap" Margin="0,10,0,0"/>
 </StackPanel></Border>
 <StackPanel Margin="0,15,0,0"><TextBlock Text="Your name or approved reviewer ID" Margin="0,0,0,7"/><TextBox x:Name="Reviewer"/></StackPanel>
 <StackPanel Margin="0,13,0,0"><TextBlock Text="Reason / tests checked" Margin="0,0,0,7"/><TextBox x:Name="Reason" TextWrapping="Wrap" MinHeight="60" AcceptsReturn="True"/></StackPanel>
 <CheckBox x:Name="Authorized" Content="I am authorized to confirm this report type and have checked this PDF and any selected items." Margin="0,16,0,5"/>
</StackPanel></ScrollViewer>
<StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="Open" Content="Open PDF" Margin="0,0,10,0"/><Button x:Name="Cancel" Content="Cancel" Margin="0,0,10,0"/><Button x:Name="Preview" Content="Preview label change" Background="#1D6871"/></StackPanel>
'@
    $d=New-Dialog 'Choose the correct report type' $content 790 780
    $d.FindName('ReportName').Text=[string]$record.OriginalFileName+"`r`nCurrent: "+(Get-CategoryLabel ([string]$record.Category))+"`r`nBasis: "+[string]$record.ClassificationBasis
    $d.FindName('Category').DisplayMemberPath='Label';$d.FindName('Category').SelectedValuePath='Value'
    foreach($c in @('Daily_QA','Monthly_QA','Monthly_QA/Pending_Verification','Acceptance_Tests','Needs_Review')){[void]$d.FindName('Category').Items.Add([pscustomobject]@{Value=$c;Label=(Get-CategoryLabel $c)})}
    $d.FindName('Category').SelectedValue=[string]$record.Category
    $checks=New-Object 'System.Collections.Generic.List[object]'
    foreach($component in $required){
        $check=New-Object System.Windows.Controls.CheckBox
        $label=New-Object System.Windows.Controls.TextBlock;$label.Text=$component;$label.TextWrapping=[Windows.TextWrapping]::Wrap
        $check.Content=$label;$check.Tag=$component;$check.IsChecked=($previous -contains $component)
        $check.Margin=New-Object Windows.Thickness(0,5,0,5)
        [void]$checks.Add($check);[void]$d.FindName('ComponentList').Children.Add($check)
    }
    $d.Tag=@{Record=$record;Checks=@($checks.ToArray());HasChecklist=($required.Count -gt 0)}
    if($required.Count -eq 0){
        $d.FindName('ChecklistNote').Text='No department checklist is set. This labels the PDF; it does not confirm a complete Monthly QA set.'
        $d.FindName('SelectAllComponents').Visibility=[Windows.Visibility]::Collapsed
    }else{$d.FindName('ChecklistNote').Text='A month is complete only when all required items are confirmed across its saved Monthly QA reports.'}
    $monthly=([string]$record.Category -eq 'Monthly_QA')
    $d.FindName('ChecklistControls').IsEnabled=$monthly
    $d.FindName('ChecklistModeNote').Text=$(if($monthly){'Only your explicit selections are saved. PDF text suggestions do not select items.'}else{'Choose a confirmed Monthly QA report type to record checklist items.'})
    $d.FindName('Category').Add_SelectionChanged({param($sender,$eventArgs)
        $parent=[Windows.Window]::GetWindow($sender)
        $monthly=([string]$sender.SelectedValue -eq 'Monthly_QA')
        $parent.FindName('ChecklistControls').IsEnabled=$monthly
        $parent.FindName('ChecklistModeNote').Text=$(if($monthly){'Only your explicit selections are saved. PDF text suggestions do not select items.'}else{'Checklist items are recorded only for a confirmed Monthly QA report.'})
    })
    $d.FindName('SelectAllComponents').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender);foreach($check in $parent.Tag.Checks){$check.IsChecked=$true}})
    $d.FindName('Open').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender);Safe-Open ([string]$parent.Tag.Record.DestinationPath)})
    $d.FindName('Cancel').Add_Click({param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).DialogResult=$false})
    $d.FindName('Preview').Add_Click({param($sender,$eventArgs)
        $parent=[Windows.Window]::GetWindow($sender)
        if($parent.FindName('Authorized').IsChecked -eq $true -and $parent.FindName('Reviewer').Text.Trim() -and $parent.FindName('Reason').Text.Trim()){$parent.DialogResult=$true}
        else{[void][Windows.MessageBox]::Show($parent,'Enter your reviewer name and reason, and confirm that you are authorized and have checked this PDF and any selected items.','Confirmation information needed')}
    })
    if($d.ShowDialog() -eq $true){
        $category=[string]$d.FindName('Category').SelectedValue
        $components=[string[]]@()
        if($category -eq 'Monthly_QA'){$components=[string[]]@($checks.ToArray() | Where-Object {$_.IsChecked -eq $true} | ForEach-Object {[string]$_.Tag})}
        $script:PendingDecisions=@([pscustomobject]@{RecordId=[string]$record.Id;Hash=[string]$record.Hash;Category=$category;ConfirmedComponents=$components;Reviewer=$d.FindName('Reviewer').Text.Trim();Reason=$d.FindName('Reason').Text.Trim()})
        Start-Work -Mode ReclassifyPreview -Decisions $script:PendingDecisions
    }
}
function Show-ConnectionEditor {
    $selected=[string]$script:Controls.ConnectionScannerSelector.SelectedValue
    if($null -eq (Get-Variable ScannerEditors -Scope Script -ErrorAction SilentlyContinue)){return}
    foreach($id in $script:ScannerEditors.Keys){$script:ScannerEditors[$id].Row.Visibility=$(if($id -eq $selected){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed})}
}
function Show-QaSettings {
    param([string]$ScannerId='')
    Show-Page Advanced
    if($ScannerId){$script:Controls.ConnectionScannerSelector.SelectedValue=$ScannerId}
    foreach($id in $script:ScannerEditors.Keys){if(-not $ScannerId -or $id -eq $ScannerId){$script:ScannerEditors[$id].QaOptions.IsExpanded=$true}}
    $script:Controls.AdvancedView.ScrollToTop()
}
function Show-SelectedReportHelp {
    $record=$script:Controls.ReportsGrid.SelectedItem
    if($null -eq $record){$script:Controls.SelectedReportHelp.Text='Select a saved report. Choose Review pending PDFs for View, Accept or Decline. Use Edit report details for corrections and history.';return}
    $category=[string](Value-Or $record Category)
    $pending=Test-QaReportPending $record
    $script:Controls.SelectedReportHelp.Text=$(if($pending){'Saved PDF - pending verification. Choose Review pending PDFs. Inspect the PDF, then Accept or Decline; only confirm checklist items supported by the PDF.'}else{'Saved PDF - '+(Get-CategoryLabel $category)+'. Open it to inspect the evidence, or Edit report details to correct its label. Text reading and reviewed confirmation are separate.'})
}
function Review-TodayReports {
    $selected=$script:Controls.TodayGrid.SelectedItem
    Clear-ReportFilters;Show-Page Reports
    if($null -ne $selected){$script:Controls.ScannerFilter.SelectedValue=[string]$selected.Scanner}
    $script:Controls.ReportSearch.Text=(Get-Date).ToString('yyyy-MM-dd')
    Refresh-Reports
}
function Toggle-PdfReading {
    try {
        $enabled=-not [bool](Value-Or $script:Config AutoAnalyze $true)
        $copy=$script:Config|ConvertTo-Json -Depth 20|ConvertFrom-Json;$copy|Add-Member AutoAnalyze $enabled -Force
        Save-QaConfig -AppRoot $script:AppRoot -Config $copy|Out-Null;$script:Config=Read-QaConfig -AppRoot $script:AppRoot
        $script:Controls.AutoAnalyze.IsChecked=$enabled
        if(-not $enabled -and $script:Busy -and $script:CurrentMode -eq 'Analysis'){$script:Worker.Shared.Cancel=$true}
        Write-QaSupportEvent -AppRoot $script:AppRoot -Operation Settings -Outcome Completed -Counts @{AutoReadingEnabled=[int]$enabled}
        Refresh-Dashboard
        $script:Controls.StatusText.Text=$(if($enabled){'Automatic text reading enabled. New or changed PDFs are read in small batches while open.'}else{'Automatic text reading paused. Saved reports and cached results remain available.'})
    }catch{Show-Note $_.Exception.Message 'PDF reading setting could not be saved' $true}
}
function Choose-UpdatePackage {
    if($script:Busy){Show-Note 'Wait for the current report operation, or cancel it safely before choosing an update.';return}
    $dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Filter='CT QA update (*.zip)|*.zip'
    if($dialog.ShowDialog($script:Window)){Prepare-UpdatePackage $dialog.FileName}
}
function Prepare-UpdatePackage {
    param([string]$Path)
    if($script:Busy){Show-Note 'Wait for the report operation to finish before checking an update.';return}
    try {
        $script:Controls.InstallUpdateButton.IsEnabled=$false
        if($null -ne $script:PreparedUpdate){Remove-QaUpdateStage -AppRoot $script:AppRoot -StageRoot $script:PreparedUpdate.StageRoot;$script:PreparedUpdate=$null}
        $script:Controls.UpdatePackagePath.Text='Checking the selected ZIP...'
        $plan=New-QaUpdateStage -AppRoot $script:AppRoot -ZipPath $Path
        $script:PreparedUpdate=$plan
        Write-QaSupportEvent -AppRoot $script:AppRoot -Operation OfflineUpdate -Outcome Completed -Counts @{Files=$plan.Files}
        $script:Controls.UpdatePackagePath.Text=$Path
        $script:Controls.UpdatePackageSummary.Text=('Current: 5.7.3 / Selected: '+$plan.Version+' / '+$plan.Files+' checked program files. Reports and saved settings stay in place.')
        $script:Controls.InstallUpdateButton.IsEnabled=$true
    }catch{$script:Controls.UpdatePackagePath.Text='The package could not be checked.';$script:Controls.UpdatePackageSummary.Text=$_.Exception.Message;Show-Note $_.Exception.Message 'Update file needs attention' $true}
}
function Install-PreparedUpdate {
    if($script:Busy -or $null -eq $script:PreparedUpdate){return}
    try {
        $plan=$script:PreparedUpdate
        [void](Test-QaUpdateFolder -SourceFolder $plan.SourceFolder)
        if([Windows.MessageBox]::Show($script:Window,('Install version '+$plan.Version+' and restart? The app will close. Your archive and settings will be preserved, and the previous program will be kept in Backups.'),'Install update',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question) -ne [Windows.MessageBoxResult]::Yes){return}
        $arguments='-NoLogo -NoProfile -STA -File "'+(Join-Path $plan.SourceFolder 'App/Upgrade.ps1')+'" -SourceFolder "'+$plan.SourceFolder+'" -TargetFolder "'+$script:AppRoot+'" -WaitForApp -LaunchAfter -StageRoot "'+$plan.StageRoot+'"'
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WorkingDirectory $script:AppRoot|Out-Null
        Write-QaSupportEvent -AppRoot $script:AppRoot -Operation OfflineUpdate -Outcome Started -Counts @{Files=$plan.Files}
        $script:UpdateLaunching=$true
        $script:Window.Close()
    }catch{Show-Note $_.Exception.Message 'Update could not start' $true}
}

function Refresh-ReviewGroups {
    $category=[string]$script:Controls.AttentionFilter.SelectedValue;if(-not $category){$category='All'}
    $visible=@(Select-QaReviewGroups -Groups $script:ReviewGroups -Category $category)
    $script:Controls.AttentionList.ItemsSource=$visible
    $total=0;foreach($group in $script:ReviewGroups){$total+=$group.Count}
    $script:Controls.AttentionCount.Text=('{0:N0} items / {1} groups; showing {2}' -f $total,$script:ReviewGroups.Count,$visible.Count)
    $script:Controls.AttentionEmpty.Visibility=$(if($visible.Count){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible})
    $script:Controls.AttentionEmpty.Text='No review groups in this category. Other categories remain available above.'
    $script:Controls.AttentionScope.Text=('Daily checks cover up to '+$script:Config.LookbackDays+' prior days through yesterday, using each scanner schedule and active-from date. Monthly checks use completed months. Open a group to see every item and its next step.')
}
function Open-ReviewGroup {
    if($script:Busy){Show-Note 'A report operation is running. Wait for it to finish, or use Cancel safely before reviewing items.';return}
    $group=$script:Controls.AttentionList.SelectedItem
    if($null -eq $group){Show-Note 'Select a review group first.';return}
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock x:Name="Title" FontSize="21" FontWeight="SemiBold"/>
<TextBlock x:Name="NextStep" Grid.Row="1" Foreground="#AFC8D8" Margin="0,13,0,16"/>
<ListBox x:Name="Items" Grid.Row="2" ScrollViewer.VerticalScrollBarVisibility="Auto"><ListBox.ItemTemplate><DataTemplate><Border Background="#1B2D45" CornerRadius="8" Padding="12"><TextBlock Text="{Binding Message}" TextWrapping="Wrap"/></Border></DataTemplate></ListBox.ItemTemplate></ListBox>
<WrapPanel Grid.Row="3" HorizontalAlignment="Right" Margin="0,15,0,0"><Button x:Name="Settings" Content="Check scanner settings" Margin="0,0,9,7"/><Button x:Name="Open" Content="Review selected item" Margin="0,0,9,7"/><Button x:Name="Close" Content="Close" Margin="0,0,0,7"/></WrapPanel>
'@
    $d=New-Dialog 'Archive review details' $content 860 600
    $d.FindName('Title').Text=$group.Message;$d.FindName('NextStep').Text=$group.NextStep
    $d.FindName('Items').ItemsSource=@($group.Items)
    $d.FindName('Open').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender);$selected=$parent.FindName('Items').SelectedItem;if($null -ne $selected){$parent.Tag=$selected;$parent.DialogResult=$true}})
    $d.FindName('Settings').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender);$parent.Tag='Settings';$parent.DialogResult=$true})
    $d.FindName('Close').Add_Click({param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).DialogResult=$false})
    if($d.ShowDialog() -eq $true){if($d.Tag -is [string]){Show-QaSettings -ScannerId ([string]$group.Scanner)}else{Open-AttentionItem -Item $d.Tag}}
}
function Save-SupportReport {
    try {
        $folder=Join-Path $script:AppRoot 'Logs/Support';[void][IO.Directory]::CreateDirectory($folder)
        $dialog=New-Object Microsoft.Win32.SaveFileDialog;$dialog.Filter='Scrubbed support logs (*.zip)|*.zip';$dialog.FileName='CTQA-Support-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'.zip';$dialog.InitialDirectory=$folder
        if(-not $dialog.ShowDialog($script:Window)){return}
        $mode='';if($script:Busy){$mode=$script:CurrentMode}
        $path=Export-QaSupportBundle -AppRoot $script:AppRoot -Config $script:Config -Dashboard $script:Dashboard -DestinationPath $dialog.FileName -ConnectionResults @($script:ConnectionFeedback.Values) -CurrentOperation $mode
        Show-Note ('Support report saved to:'+"`r`n"+$path+"`r`n`r`n"+'You can share this ZIP for troubleshooting. It includes the summary and ALL retained scrubbed activity: operation timings, results, counts and error numbers. Logs normally cover up to 90 days with a 50 MB limit. Nothing is uploaded automatically. No passwords, usernames, network addresses, filenames, PDF contents or raw logs are included. Scanner 1, 2, 3 follow your configured scanner order.') 'Scrubbed support logs'
    }catch{Show-Note $_.Exception.Message 'Support report could not be saved' $true}
}

function Open-AttentionItem {
    param($Item=$null)
    if($script:Busy){return}
    if($null -eq $Item){$item=$script:Controls.AttentionList.SelectedItem}else{$item=$Item}
    if($null -eq $item){return}
    $recordId=[string](Value-Or $item RecordId)
    if($recordId) {
        Clear-ReportFilters; Show-Page Reports; Refresh-Reports
        $found=@($script:Dashboard.Records | Where-Object Id -eq $recordId)
        if($found.Count){$script:Controls.ReportsGrid.SelectedItem=$found[0];$script:Controls.ReportsGrid.ScrollIntoView($found[0]);return}
    }
    $path=[string](Value-Or $item Path)
    $message=[string]$item.Message+"`r`n`r`n"+[string](Value-Or $item Details 'Review the saved archive and scanner history. Missing archive records do not prove QA was not performed.')
    $missing=@(Value-Or $item MissingComponents @())
    if($missing.Count){$message+="`r`n`r`nItems still needed for this month: "+($missing -join '; ')+'. One combined PDF or several partial PDFs can supply these items.'}
    if([string](Value-Or $item Type) -match 'Connection|Unavailable|Source'){$message+="`r`n`r`nTo reconnect, open Advanced settings and choose Reconnect drives, or ask IT. Other accessible scanners can continue."}
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><TextBlock Text="Archive finding" FontSize="23" FontWeight="SemiBold"/><TextBox x:Name="Details" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Margin="0,16,0,18"/><StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="Open" Content="Open related folder / PDF" Margin="0,0,10,0"/><Button x:Name="Close" Content="Close"/></StackPanel>
'@
    $d=New-Dialog 'QA attention details' $content 700 440
    $d.Tag=$path; $d.FindName('Details').Text=$message
    $d.FindName('Open').IsEnabled=([bool]$path)
    $d.FindName('Open').Add_Click({param($sender,$eventArgs) $parent=[Windows.Window]::GetWindow($sender);$p=[string]$parent.Tag;if([IO.Path]::GetExtension($p) -eq '.pdf'){Safe-Open $p}else{Safe-Open $p -Folder}})
    $d.FindName('Close').Add_Click({param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).Close()})
    [void]$d.ShowDialog()
}

. (Join-Path $PSScriptRoot 'ReviewQueueUi.ps1')

try {
    if($env:OS -ne 'Windows_NT') { throw 'CT QA Manager Pro requires Windows and Windows PowerShell 5.1 with WPF.' }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
    if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start the application using the supplied launcher so WPF runs in STA mode.' }
    $script:Window=Load-Window ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MainWindow.xaml')))
    $script:Controls=@{}
    foreach($element in ([xml][IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MainWindow.xaml'))).SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if($name){$script:Controls[$name]=$script:Window.FindName($name)}
    }
    if($ValidateLayout) { Write-Output ('WPF layout loaded: '+$script:Controls.Count+' named controls.'); exit 0 }
    Import-Module (Join-Path $PSScriptRoot 'Archive.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Reports.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Search.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Credentials.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Insights.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Maintenance.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Review.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Support.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Updates.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1') -Force
    Fit-Window $script:Window
    if(-not $script:DemoPreview){[void](Initialize-QaWorkspace $script:AppRoot)}
    $script:Config=Read-QaConfig -AppRoot $script:AppRoot
    if($script:DemoPreview){Initialize-DemoDashboard}
    if(-not $script:DemoPreview){$script:ProgramLock=[IO.File]::Open((Join-Path $script:AppRoot 'Data/application.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)}
    $script:Controls.AttentionFilter.ItemsSource=@([pscustomobject]@{Value='All';Label='All review groups'},[pscustomobject]@{Value='Files';Label='Connection & file checks'},[pscustomobject]@{Value='Reports';Label='Report labels & confirmation'},[pscustomobject]@{Value='Dates';Label='Daily archive dates'},[pscustomobject]@{Value='Monthly';Label='Monthly evidence & checklist'},[pscustomobject]@{Value='Information';Label='Preserved reports: information'})
    $script:Controls.AttentionFilter.SelectedValue='All'
    Initialize-ReportFilters; Fill-Settings; Refresh-Dashboard
    if(-not $script:DemoPreview){Write-QaSupportEvent -AppRoot $script:AppRoot -Operation Startup -Outcome Completed}
    $script:Controls.ConnectionScannerSelector.Add_SelectionChanged({Show-ConnectionEditor})
    $script:Controls.AttentionFilter.Add_SelectionChanged({Refresh-ReviewGroups})
    $script:Controls.OpenReviewGroupButton.Add_Click({Open-ReviewGroup})
    $script:Controls.ManageConnectionsButton.Add_Click({Show-Page Advanced;$script:Controls.AdvancedView.ScrollToTop()})
    foreach($button in @('CoverageSettingsButton','MonthlySettingsButton')){$script:Controls[$button].Add_Click({Show-QaSettings})}
    foreach($button in @('ExportDiagnosticsButton','ExportDiagnosticsAdvancedButton')){$script:Controls[$button].Add_Click({Save-SupportReport})}
    if($script:Dashboard.SetupComplete){$script:Controls.StatusText.Text=$(if([bool](Value-Or $script:Config AutoUpdateOnOpen $true)){'Opening your archive. An update will begin after this window appears.'}else{'Saved information. Click Update Reports to check for new PDFs.'})}
    $script:Controls.ReviewNav.Add_Click({Show-Page Review})
    $script:Controls.UpdatesNav.Add_Click({Show-Page Updates})
    $script:Controls.ReviewTodayButton.Add_Click({Review-TodayReports})
    $script:Controls.ToggleReadingButton.Add_Click({Toggle-PdfReading})
    $script:Controls.ReportsGrid.Add_SelectionChanged({Show-SelectedReportHelp})
    $script:Controls.ChooseUpdateButton.Add_Click({Choose-UpdatePackage})
    $script:Controls.InstallUpdateButton.Add_Click({Install-PreparedUpdate})
    $script:Controls.UpdateDropZone.Add_DragOver({param($sender,$eventArgs) $eventArgs.Effects=[Windows.DragDropEffects]::None;if($eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)){$eventArgs.Effects=[Windows.DragDropEffects]::Copy};$eventArgs.Handled=$true})
    $script:Controls.UpdateDropZone.Add_Drop({param($sender,$eventArgs) if($eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)){$files=@($eventArgs.Data.GetData([Windows.DataFormats]::FileDrop));if($files.Count -eq 1){Prepare-UpdatePackage ([string]$files[0])}else{Show-Note 'Drop one update ZIP at a time.'}};$eventArgs.Handled=$true})
    $script:Controls.SourceAuditButton.Add_Click({Start-Work -Mode SourceAudit})
    $script:Controls.AnalyzeButton.Add_Click({$script:LastAnalysis=[datetime]::Now;Start-Work -Mode Analysis})
    $script:Controls.CompatibilityButton.Add_Click({Start-Work -Mode Compatibility})
    $script:Controls.BackupButton.Add_Click({
        $dialog=New-Object Microsoft.Win32.SaveFileDialog;$dialog.Filter='CT QA backup (*.zip)|*.zip';$dialog.FileName='CTQA-Full-Backup-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'.zip'
        $dialog.InitialDirectory=Join-Path $script:AppRoot 'Backups'
        if($dialog.ShowDialog($script:Window)) {Start-Work -Mode Backup -Plan ([pscustomobject]@{DestinationPath=$dialog.FileName})}
    })
    $script:Controls.RestoreButton.Add_Click({
        $dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Filter='CT QA backup (*.zip)|*.zip'
        if($dialog.ShowDialog($script:Window)){$parent=Choose-Folder 'Choose a parent folder for a NEW restored workspace. Existing data stays unchanged.';if($parent){Start-Work -Mode Restore -Plan ([pscustomobject]@{Path=$dialog.FileName;DestinationFolder=(Join-Path $parent ('CTQA-Restored-'+(Get-Date).ToString('yyyyMMdd-HHmmss')))})}}
    })
    $script:Controls.RetryAnalysisButton.Add_Click({
        if($script:Busy){return};$folder=Join-Path $script:Config.ArchiveRoot '.ctqa/analysis'
        if([IO.Directory]::Exists($folder)){foreach($file in Get-ChildItem -LiteralPath $folder -Filter '*.json'){try{$row=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json;if($row.Status -eq 'ReadError'){[IO.File]::Delete($file.FullName)}}catch{}}}
        Start-Work -Mode Analysis
    })
    $script:Controls.OpenNavigatorButton.Add_Click({
        $path=Join-Path $script:Config.ArchiveRoot 'Browse Reports/Open Reports.html'
        if([IO.File]::Exists($path)){try{Start-Process -FilePath $path|Out-Null}catch{Show-Note $_.Exception.Message}}else{Show-Note 'Update or refresh the report folders once to create the offline library.'}
    })
    $script:Controls.OpenTodayButton.Add_Click({$row=$script:Controls.TodayGrid.SelectedItem;if($null -ne $row -and @($row.ReportIds).Count){$record=@($script:Dashboard.Records|Where-Object{$_.Id -eq $row.ReportIds[0]})[0];Safe-Open $record.DestinationPath}else{Show-Note 'Select a scanner with a saved Daily QA report for today.'}})
    $script:Controls.DashboardNav.Add_Click({Show-Page Dashboard})
    $script:Controls.ReportsNav.Add_Click({Show-Page Reports})
    $script:Controls.AdvancedNav.Add_Click({Show-Page Advanced})
    $script:Controls.HelpButton.Add_Click({Show-Help})
    $script:Controls.SetupButton.Add_Click({
        if($script:Busy){return}
        $selected=Choose-Folder 'Choose the archive location. A Reports folder will be created inside it.' ([string]$script:Config.ArchiveRoot)
        if(-not $selected){return}
        $old=[string]$script:Config.ArchiveRoot
        if([IO.Path]::GetFullPath($selected) -ne [IO.Path]::GetFullPath($old)) {
            $script:Controls.ArchivePath.Text=$selected
            if(-not (Save-Settings)){return}
        }
        $script:AfterReconnect='SetupPreview'
        Start-Work -Mode Reconnect
    })
    $script:Controls.UpdateButton.Add_Click({if(-not $script:Dashboard.SetupComplete){Start-Work -Mode SetupPreview}else{Start-Work -Mode Update}})
    $script:Controls.OpenFolderButton.Add_Click({Open-BrowseReports})
    $script:SearchTimer=New-Object Windows.Threading.DispatcherTimer
    $script:SearchTimer.Interval=[timespan]::FromMilliseconds(300)
    $script:SearchTimer.Add_Tick({$script:SearchTimer.Stop();Refresh-Reports})
    $script:Controls.ReportSearch.Add_TextChanged({$script:SearchTimer.Stop();$script:SearchTimer.Start()})
    foreach($filterControl in @('ScannerFilter','MonthFilter','CategoryFilter')){$script:Controls[$filterControl].Add_SelectionChanged({Refresh-Reports})}
    $script:Controls.YearFilter.Add_SelectionChanged({if(-not $script:UpdatingFilters){if($script:Controls.YearFilter.SelectedValue -ne -1){$script:SelectedYears=@();Refresh-ReportYears};Refresh-Reports}})
    $script:Controls.ChooseYearsButton.Add_Click({Choose-ReportYears})
    $script:Controls.ClearFiltersButton.Add_Click({Clear-ReportFilters})
    $script:Controls.ExportReportsButton.Add_Click({Export-MatchingReports})
    $script:Controls.OpenExportFolderButton.Add_Click({Open-ExportFolder})
    $script:Controls.BrowseReportsButton.Add_Click({Open-BrowseReports})
    $script:Controls.ReadReportTextButton.Add_Click({Read-SelectedReportText})
    if([IO.File]::Exists((Join-Path $PSScriptRoot 'PdfReader.psm1'))){$script:Controls.ReadReportTextButton.Visibility=[Windows.Visibility]::Visible}
    $script:Controls.ReviewStatusFilter.Add_SelectionChanged({if($script:UpdatingFilters){return};$script:PendingOnly=($script:Controls.ReviewStatusFilter.SelectedValue -eq 'Pending');if($script:Controls.ReviewStatusFilter.SelectedValue -in @('Accepted','Declined')){$script:Controls.CategoryFilter.SelectedValue='All'};Refresh-Reports})
    $script:Controls.ReviewPendingButton.Add_Click({$script:Controls.ReviewStatusFilter.SelectedValue=$(if($script:PendingOnly){'All'}else{'Pending'})})
    $script:Controls.QuickReviewButton.Add_Click({Open-QuickReviewQueue})
    $script:Controls.OpenReportButton.Add_Click({if($null -ne $script:Controls.ReportsGrid.SelectedItem){Safe-Open ([string]$script:Controls.ReportsGrid.SelectedItem.DestinationPath)}else{Show-Note 'Select a saved report first.'}})
    $script:Controls.ReportsGrid.Add_MouseDoubleClick({if($null -ne $script:Controls.ReportsGrid.SelectedItem){Safe-Open ([string]$script:Controls.ReportsGrid.SelectedItem.DestinationPath)}})
    $script:Controls.ReviewReportButton.Add_Click({Review-SelectedReport})
    $script:Controls.ReviewHistoryButton.Add_Click({Show-ReportDecisionHistory})
    $script:Controls.AttentionList.Add_MouseDoubleClick({Open-ReviewGroup})
    $script:Controls.AttentionList.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -eq [Windows.Input.Key]::Enter){Open-ReviewGroup;$eventArgs.Handled=$true}})
    $script:Controls.SaveSettingsButton.Add_Click({[void](Save-Settings)})
    $script:Controls.BrowseArchiveButton.Add_Click({$p=Choose-Folder 'Choose the archive parent location' $script:Controls.ArchivePath.Text;if($p){$script:Controls.ArchivePath.Text=$p}})
    $script:Controls.ImportConnectionsButton.Add_Click({
        if($script:Busy){return}
        $dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Filter='Local network profile (*.json)|*.json';$dialog.InitialDirectory=Join-Path $script:AppRoot 'Config'
        if($dialog.ShowDialog($script:Window)) {
            $answer=[Windows.MessageBox]::Show($script:Window,'Apply the scanner paths and usernames from this local profile? Existing report data and review history will be preserved. Passwords must be entered securely on this workstation.','Apply connection profile',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question)
            if($answer -eq [Windows.MessageBoxResult]::Yes){try{$result=Set-QaConnectionProfile -AppRoot $script:AppRoot -ProfilePath $dialog.FileName -ReplaceExisting;$script:Config=Read-QaConfig $script:AppRoot;Fill-Settings;Refresh-Dashboard;Show-Note $result.Message 'Connections updated'}catch{Show-Note $_.Exception.Message 'Connection profile could not be applied' $true}}
        }
    })
    $script:Controls.ReconnectButton.Add_Click({if(Save-Settings){Start-Work -Mode Reconnect}})
    $script:Controls.AddScannerButton.Add_Click({Add-Scanner})
    $script:Controls.OpenLogsButton.Add_Click({Start-Process -FilePath 'explorer.exe' -ArgumentList ('"'+(Join-Path $script:AppRoot 'Logs')+'"')|Out-Null})
    $script:Controls.AuditButton.Add_Click({Start-Work -Mode Audit})
    $script:Controls.ReclassifyButton.Add_Click({Clear-ReportFilters;$script:PendingOnly=$true;Show-Page Reports;Refresh-Reports;Show-Note 'Most reports are organized automatically. Check only reports marked Needs confirmation. Open the PDF and choose its correct type if you are authorized; otherwise leave it pending.'})
    $script:Controls.AdoptLegacyButton.Add_Click({
        $legacy=Choose-Folder 'Select the older archive folder containing QA_Master_Index_v2.csv. Originals and old archive files will stay unchanged.'
        if(-not $legacy){return}
        $answer=[Windows.MessageBox]::Show($script:Window,'Reuse this existing archive? Reports will be verified and copied safely into the selected destination when needed. Legacy monthly labels will require fresh verification. The older archive will remain unchanged.','Reuse existing archive',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question)
        if($answer -eq [Windows.MessageBoxResult]::Yes){Start-Work -Mode AdoptLegacy -LegacyRoot $legacy}
    })
    $script:Controls.CancelButton.Add_Click({if($null -ne $script:Worker){$script:Worker.Shared.Cancel=$true;$script:Controls.StatusText.Text='Cancel requested. Finishing the current safe checkpoint...';$script:Controls.CancelButton.IsEnabled=$false}})
    $script:Timer=New-Object Windows.Threading.DispatcherTimer
    $script:Timer.Interval=[timespan]::FromMilliseconds(180)
    $script:Timer.Add_Tick({
        if($null -eq $script:Worker){return}
        $worker=$script:Worker
        $script:Controls.StatusText.Text=[string]$worker.Shared.Message
        $percent=0.0
        if([double]::TryParse([string]$worker.Shared.Percent,[ref]$percent)){$script:Controls.WorkProgress.Value=[math]::Max(0,[math]::Min(100,$percent))}
        $script:Controls.WorkProgress.IsIndeterminate=($percent -le 0)
        if(-not $worker.Handle.IsCompleted){return}
        $errorText=[string]$worker.Shared.Error; $result=$worker.Shared.Result; $mode=$script:CurrentMode; $cancelled=[bool]$worker.Shared.Cancel
        try { [void]$worker.PowerShell.EndInvoke($worker.Handle); if(-not $errorText -and $worker.PowerShell.HadErrors){$errorText=($worker.PowerShell.Streams.Error | Out-String)} } catch {$errorText=$_.Exception.Message}
        finally {$worker.PowerShell.Dispose();$worker.Runspace.Dispose();$script:Worker=$null;Set-Busy $false;$script:Controls.CancelButton.IsEnabled=$true}
        $completedSummary=Value-Or $result Summary $null
        if($null -ne $completedSummary -and $null -ne $completedSummary.PSObject.Properties['Cancelled']){$cancelled=[bool]$completedSummary.Cancelled}
        if(-not $script:DemoPreview){
            $counts=@{};foreach($key in @('Total','NewOrChanged','Unchanged','Pending','Deferred','Copied','Failed','Verified')){if($null -ne $completedSummary -and $null -ne $completedSummary.PSObject.Properties[$key]){$counts[$key]=$completedSummary.$key}}
            foreach($key in @('Analyzed','Failed','Cached','Pending')){if($null -ne $result -and $null -ne $result.PSObject.Properties[$key]){$counts[$key]=$result.$key}}
            Write-QaSupportEvent -AppRoot $script:AppRoot -Operation $mode -Outcome $(if($errorText){'Failed'}elseif($cancelled){'Cancelled'}else{'Completed'}) -DurationMs $script:OperationClock.ElapsedMilliseconds -ErrorKind (Get-QaSupportErrorKind $errorText) -Counts $counts
        }
        if(Complete-QuickQueueWork -Mode $mode -Result $result -ErrorText $errorText -Cancelled $cancelled){return}
        if($mode -eq 'Reconnect' -and ($cancelled -or $errorText)){$script:RememberPending=@{}}
        if($cancelled -and -not $errorText){
            $script:AfterReconnect=''
            if($mode -eq 'Export'){$script:Controls.ExportResultPanel.Visibility=[Windows.Visibility]::Visible;$script:Controls.ExportResultText.Text='Export cancelled. No completed ZIP was created.';$script:Controls.OpenExportFolderButton.Visibility=[Windows.Visibility]::Collapsed}
            if($mode -eq 'BrowseRefresh'){$script:Controls.StatusText.Text=($script:BrowsePreviousStatus+' / Friendly folders refresh cancelled. Saved archive reports remain available.').TrimStart([char[]]' /');$script:BrowsePreviousStatus='';Offer-ExistingBrowseFolder $script:Controls.StatusText.Text}
            elseif($mode -eq 'Export'){$script:Controls.StatusText.Text='Export cancelled. No completed ZIP was created.'}
            elseif($mode -eq 'PdfRead'){$script:Controls.StatusText.Text='Reading stopped. Saved report labels have not been changed.'}
            else{$script:Controls.StatusText.Text='Operation cancelled safely. Completed archive copies remain saved.'}
            Refresh-Dashboard;return
        }
        if($errorText){
            if($mode -eq 'Export'){$script:Controls.ExportResultPanel.Visibility=[Windows.Visibility]::Visible;$script:Controls.ExportResultText.Text='Export could not finish. No completed ZIP was created.';$script:Controls.OpenExportFolderButton.Visibility=[Windows.Visibility]::Collapsed}
            if($mode -eq 'BrowseRefresh'){$script:Controls.StatusText.Text=($script:BrowsePreviousStatus+' / Friendly folders could not finish. The managed archive remains saved.').TrimStart([char[]]' /');$script:BrowsePreviousStatus='';Show-Note $errorText 'Friendly folders need attention' $true;Offer-ExistingBrowseFolder $errorText}
            else{$script:Controls.StatusText.Text='The operation needs attention. No source reports were changed.';Show-Note $errorText 'Operation could not finish' $true}
            Refresh-Dashboard;return
        }
        $script:Controls.StatusText.Text=Summary-Text (Value-Or $result Summary $null)
        $connectionWarnings=@(Value-Or $result ConnectionWarnings @())
        if($connectionWarnings.Count){$script:Controls.StatusText.Text+=' / '+$connectionWarnings.Count+' saved sign-in(s) need attention.';Show-Note (($connectionWarnings -join "`r`n`r`n")+"`r`n`r`nExisting Windows access and other scanners can continue.") 'Saved sign-ins need attention' $true}
        Refresh-Dashboard
        if($mode -eq 'SourceAudit'){Show-Note (($result.Rows|ForEach-Object{$_.Scanner+' / '+$_.Report+': '+$_.Status}) -join "`r`n") 'Source verification'}
        elseif($mode -eq 'Compatibility'){Show-Note (($result.Rows|ForEach-Object{$_.Check+': '+$_.Status+"`r`n"+$_.Detail}) -join "`r`n`r`n") 'This computer'}
        elseif($mode -in @('Backup','Restore')){Show-Note ($result.Summary.Description+"`r`n`r`n"+$result.DestinationPath) 'Archive protection'}
        elseif($mode -eq 'PdfRead'){Show-ReportText $result}
        elseif($mode -eq 'Export'){Finish-Export $result}
        elseif($mode -eq 'BrowseRefresh'){Finish-BrowseRefresh $result}
        elseif($mode -eq 'SetupPreview' -and [string](Value-Or $result LegacyRoot)) {
            $message=('An existing archive was found here with {0:N0} index records. Reuse it safely? Existing PDFs and the old index will remain unchanged. The app verifies saved PDFs and builds its new searchable index. Legacy Monthly QA labels will require fresh confirmation.' -f [int]$result.LegacyCount)
            $answer=[Windows.MessageBox]::Show($script:Window,$message,'Existing archive found',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question)
            if($answer -eq [Windows.MessageBoxResult]::Yes){Start-Work -Mode AdoptLegacy -LegacyRoot ([string]$result.LegacyRoot)}else{Show-Page Advanced;Show-Note 'Choose another archive destination, or use Reuse existing v2/v3 archive when ready. No files were changed.'}
        }
        elseif($mode -eq 'Preview' -or $mode -eq 'SetupPreview'){Show-Preview $result}
        elseif($mode -eq 'ReclassifyPreview'){Show-Preview $result 'Reclassify'}
        elseif($mode -eq 'Reconnect'){Finish-Connections $result}
        elseif($mode -in @('Update','Import','AdoptLegacy','Reclassify')){
            if($mode -in @('Import','AdoptLegacy')){$script:Config=Read-QaConfig -AppRoot $script:AppRoot;Refresh-Dashboard}
            $script:BrowsePreviousStatus=$script:Controls.StatusText.Text
            $scannerIssues=@((Value-Or $result Scanners @()) | Where-Object {[string]$_.Status -in @('Unavailable','Partial','Issues')}).Count
            if($scannerIssues){$script:BrowsePreviousStatus+=' / '+$scannerIssues+' scanner connection(s) need attention.'}
            $script:BrowseOpenOnComplete=$false
            Start-Work -Mode BrowseRefresh
        }
    })
    $script:Window.Add_Closing({param($sender,$eventArgs) if($script:Busy){$eventArgs.Cancel=$true;$script:Worker.Shared.Cancel=$true;$script:Controls.StatusText.Text='Finishing the current safe checkpoint. Close again when the operation has stopped.';Show-Note 'A report operation is still running. Cancellation has been requested. Please leave this window open until the current safe checkpoint finishes.' 'Finishing safely'}})
    $script:MonitorTimer=New-Object Windows.Threading.DispatcherTimer
    $script:MonitorTimer.Interval=[timespan]::FromSeconds(60)
    $script:MonitorTimer.Add_Tick({
        if($script:Busy -or $null -ne $script:ReviewQueue -or -not $script:Dashboard.SetupComplete){return}
        $minutes=[int](Value-Or $script:Config MonitorMinutes 15)
        if($minutes -gt 0 -and ([datetime]::Now-$script:LastMonitor).TotalMinutes -ge $minutes){$script:LastMonitor=[datetime]::Now;Start-Work -Mode Update;return}
        if([bool](Value-Or $script:Config AutoAnalyze $true) -and $script:AnalysisPending -gt 0 -and ([datetime]::Now-$script:LastAnalysis).TotalMinutes -ge 5){$script:LastAnalysis=[datetime]::Now;Start-Work -Mode Analysis}
    })
    $script:Window.Add_Closed({if(-not $script:DemoPreview){Write-QaSupportEvent -AppRoot $script:AppRoot -Operation Shutdown -Outcome Completed};if($null -ne $script:PreparedUpdate -and -not $script:UpdateLaunching){try{Remove-QaUpdateStage -AppRoot $script:AppRoot -StageRoot $script:PreparedUpdate.StageRoot}catch{}};$script:Timer.Stop();$script:MonitorTimer.Stop();$script:SearchTimer.Stop();if(-not $script:DemoPreview){$script:ProgramLock.Dispose()}})
    $script:Window.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -eq [Windows.Input.Key]::F1){Show-Help;$eventArgs.Handled=$true}})
    $script:Window.Dispatcher.Add_UnhandledException({param($sender,$eventArgs) $eventArgs.Handled=$true;Show-Note $eventArgs.Exception.Message 'Application action needs attention' $true})
    if($PortableLaunch) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CtQa {
 public static class NativeWindow {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool ShowWindow(IntPtr window, int command);
 }
}
'@
            $script:ConsoleHandle=[CtQa.NativeWindow]::GetConsoleWindow()
            $script:Window.Add_ContentRendered({if($script:ConsoleHandle -ne [intptr]::Zero){[void][CtQa.NativeWindow]::ShowWindow($script:ConsoleHandle,0)}})
        } catch { $script:ConsoleHandle=[intptr]::Zero }
    }
    if(-not $script:DemoPreview){$script:Window.Add_ContentRendered({Invoke-StartupUpdate});$script:MonitorTimer.Start()}
    if($ScreenshotPath){
        if(-not $script:DemoPreview){throw 'Screenshots require DemoPreview to avoid capturing workplace data.'}
        $script:Window.Title='CT QA Manager Pro - SYNTHETIC DEMONSTRATION'
        $script:Controls.TodayDate.Text+=' / SYNTHETIC DEMONSTRATION'
        $script:Controls.WelcomeText.Text='Synthetic sample data. No real scanner reports or credentials are shown.'
        $script:Window.MaxHeight=2200;$script:Window.Height=1650;$script:Window.MaxWidth=1600;$script:Window.Width=1280
        if($PreviewPage -notin @('Dashboard','Queue')){Show-Page $PreviewPage}
        $script:Window.Show()
        # Pump the dispatcher so hosted Windows applies size changes and paints controls before capture.
        $script:Window.Dispatcher.Invoke([Action]{$script:Window.UpdateLayout()},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
        if($PreviewPage -eq 'Review'){$script:Controls.ReviewView.ScrollToTop();$script:Window.Dispatcher.Invoke([Action]{$script:Window.UpdateLayout()},[Windows.Threading.DispatcherPriority]::ApplicationIdle)}
        $capture=$script:Window
        if($PreviewPage -eq 'Queue'){$capture=Open-QuickReviewQueue -DemoSnapshot;$capture.Show();$capture.Dispatcher.Invoke([Action]{$capture.UpdateLayout();Update-QuickQueueZoom;$capture.UpdateLayout()},[Windows.Threading.DispatcherPriority]::ApplicationIdle)}
        $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$capture.ActualWidth),([int]$capture.ActualHeight),96,96,([Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($capture);$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream=[IO.File]::Create([IO.Path]::GetFullPath($ScreenshotPath));try{$encoder.Save($stream)}finally{$stream.Dispose()}
        if($PreviewPage -eq 'Queue'){$capture.Close();$script:ReviewQueue=$null}
        $script:Window.Close();exit 0
    }
    $script:Timer.Start()
    [void]$script:Window.ShowDialog()
} catch {
    if(-not $script:DemoPreview){try{Import-Module (Join-Path $PSScriptRoot 'Support.psm1') -Force;Write-QaSupportEvent -AppRoot $script:AppRoot -Operation Startup -Outcome Failed -ErrorKind (Get-QaSupportErrorKind $_.Exception.Message)}catch{}}
    if($script:ConsoleHandle -ne [intptr]::Zero){try{[void][CtQa.NativeWindow]::ShowWindow($script:ConsoleHandle,5)}catch{}}
    if($ValidateLayout -or $DemoPreview){Write-Error ($_.Exception.Message+' / '+$_.ScriptStackTrace);exit 1}
    $message='CT QA Manager Pro could not start.'+"`r`n`r`n"+$_.Exception.Message+"`r`n`r`nExtract the complete application folder. If scripts are blocked, ask hospital IT to approve the package; do not change execution policy."
    try { [void][Windows.MessageBox]::Show($message,'CT QA Manager Pro',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error) } catch { Write-Error $message }
    exit 1
}
