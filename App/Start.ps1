# Native WPF front end. Windows PowerShell 5.1; no execution-policy changes.
[CmdletBinding()]
param([switch]$ValidateLayout,[switch]$PortableLaunch)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:AppRoot = Split-Path -Parent $PSScriptRoot
$script:Busy = $false
$script:Worker = $null
$script:Dashboard = $null
$script:PendingOnly = $false
$script:CurrentMode = ''
$script:PendingDecisions = @()
$script:ReconnectCredentials = @{}
$script:AfterReconnect = ''
$script:ConsoleHandle = [intptr]::Zero

function Value-Or {
    param($Object,[string]$Name,$Default='')
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { return $Object.$Name }
    return $Default
}

function Get-CategoryLabel {
    param([string]$Category)
    $labels=@{'Daily_QA'='Daily QA';'Monthly_QA'='Monthly QA - confirmed';'Monthly_QA/Pending_Verification'='Monthly QA - pending verification';'Acceptance_Tests'='Acceptance tests';'Needs_Review'='Needs review'}
    if($labels.ContainsKey($Category)){return $labels[$Category]}
    return $Category.Replace('_',' ')
}
function Add-RecordLabels {
    param($Rows)
    $scannerNames=@{'CT_Edge'='CT Edge';'CT_Flash'='CT Flash';'MDP_Building'='MDP Building'}
    foreach($row in @($Rows)) {
        if($null -eq $row){continue}
        $scanner=[string](Value-Or $row Scanner)
        $name=$scanner.Replace('_',' ')
        if($scannerNames.ContainsKey($scanner)){$name=$scannerNames[$scanner]}
        Add-Member -InputObject $row -NotePropertyName ScannerName -NotePropertyValue $name -Force
        Add-Member -InputObject $row -NotePropertyName CategoryLabel -NotePropertyValue (Get-CategoryLabel ([string](Value-Or $row Category))) -Force
    }
}
function Add-AttentionLabels {
    param($Rows)
    $labels=@{MonthlyReview='Monthly report awaiting verification';Classification='Report classification needs review';DuplicateName='Matching names preserved';MultipleSessions='Multiple testing sessions';CoverageUnknown='Coverage start date needed';DailyReview='Daily coverage awaits classification';DailyGap='Daily report not found in archive';MonthlyGap='Monthly report not confirmed';MonthlyPending='Monthly report awaiting verification';Connection='Scanner connection';SourceUnavailable='Scanner unavailable';SourceMissing='Source folder not found';CopyFailed='Report could not be copied';Integrity='Archive integrity needs review';Audit='Archive integrity';Deferred='Report deferred';Recovery='Interrupted copy recovery'}
    foreach($row in @($Rows)) {
        if($null -eq $row){continue}
        $type=[string](Value-Or $row Type)
        $label=([regex]::Replace($type,'([a-z])([A-Z])','$1 $2')).Replace('_',' ')
        if($labels.ContainsKey($type)){$label=$labels[$type]}
        Add-Member -InputObject $row -NotePropertyName TypeLabel -NotePropertyValue $label -Force
    }
}

function Show-Note {
    param([string]$Text,[string]$Title='CT QA Manager Pro',[bool]$IsError=$false)
    $icon = [System.Windows.MessageBoxImage]::Information
    if ($IsError) { $icon = [System.Windows.MessageBoxImage]::Warning }
    [void][System.Windows.MessageBox]::Show($script:Window,$Text,$Title,[System.Windows.MessageBoxButton]::OK,$icon)
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
    # A down-only Viewbox keeps all controls reachable at high DPI on small screens.
    # Primary pages retain their normal inner scrolling at the design resolution.
    if($null -ne $Window.Content) {
        $content=$Window.Content
        $Window.Content=$null
        $content.Width=$requestedWidth-16
        $content.Height=$requestedHeight-42
        $box=New-Object System.Windows.Controls.Viewbox
        $box.Stretch=[System.Windows.Media.Stretch]::Uniform
        $box.StretchDirection=[System.Windows.Controls.StretchDirection]::DownOnly
        $box.HorizontalAlignment=[System.Windows.HorizontalAlignment]::Stretch
        $box.VerticalAlignment=[System.Windows.VerticalAlignment]::Stretch
        $box.Child=$content
        $Window.Content=$box
    }
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
    param([ValidateSet('Dashboard','Reports','Advanced')][string]$Page)
    foreach ($name in @('Dashboard','Reports','Advanced')) {
        $visibility=[System.Windows.Visibility]::Collapsed
        if ($name -eq $Page) { $visibility=[System.Windows.Visibility]::Visible }
        $script:Controls[$name+'View'].Visibility=$visibility
        $script:Controls[$name+'Nav'].Background=[System.Windows.Media.BrushConverter]::new().ConvertFromString($(if($name -eq $Page){'#153443'}else{'Transparent'}))
    }
    switch ($Page) {
        Dashboard { $script:Controls.PageTitle.Text='QA overview'; $script:Controls.PageSubtitle.Text='A clear view of your scanner reports and archive.' }
        Reports { $script:Controls.PageTitle.Text='Report library'; $script:Controls.PageSubtitle.Text='Search saved PDFs, open reports, and review classifications.' }
        Advanced { $script:Controls.PageTitle.Text='Advanced settings'; $script:Controls.PageSubtitle.Text='Connections, archive preferences, and maintenance tools.' }
    }
}
function Refresh-Reports {
    if ($null -eq $script:Dashboard) { return }
    $query=$script:Controls.ReportSearch.Text.Trim()
    $rows=@($script:Dashboard.Records | Where-Object {
        $match = (-not $script:PendingOnly) -or ([string]$_.Category -like '*Pending*') -or ([string]$_.Category -eq 'Needs_Review')
        if ($query) { $hay=([string]$_.Scanner+' '+[string]$_.OriginalFileName+' '+[string]$_.ReportDate+' '+[string]$_.Category+' '+[string](Value-Or $_ CategoryLabel)+' '+[string](Value-Or $_ ScannerName)); $match=$match -and ($hay.IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -ge 0) }
        $match
    } | Sort-Object ReportDate -Descending)
    $script:Controls.ReportsGrid.ItemsSource=$rows
    $script:Controls.ReportCount.Text=('{0:N0} reports shown' -f $rows.Count)
    $script:Controls.ReviewPendingButton.Content=$(if($script:PendingOnly){'Show all reports'}else{'Show pending reviews'})
}
function Refresh-Dashboard {
    try {
        $script:Dashboard=Get-QaDashboard -Config $script:Config
        Add-RecordLabels $script:Dashboard.Records
        Add-AttentionLabels $script:Dashboard.Attention
        $script:Controls.TotalCount.Text=('{0:N0}' -f [int]$script:Dashboard.TotalReports)
        $complete=[bool]$script:Dashboard.SetupComplete
        if ($complete) {
            $script:Controls.WelcomeTitle.Text='Your report archive is ready'
            $script:Controls.WelcomeText.Text='Click Update Reports to collect new PDFs. Your saved archive is always one click away.'
            $script:Controls.SetupButtonTitle.Text='Setup complete'
            $script:Controls.SetupButtonHint.Text='Preview another import'
            $script:Controls.SetupButton.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#162538')
            $script:Controls.SetupButton.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#2A3A50')
        }
        $prefix=@{CT_Edge='Edge'; CT_Flash='Flash'; MDP_Building='Mdp'}
        foreach ($scanner in @($script:Dashboard.Scanners)) {
            $key=[string]$scanner.Scanner
            if (-not $prefix.ContainsKey($key)) { continue }
            $p=$prefix[$key]; $status=[string]$scanner.Status
            $text='Not checked'; $color='#687D99'
            switch ($status) {
                Connected { $text='Connected'; $color='#42D4B6' }
                Unavailable { $text='Connection unavailable'; $color='#E4AD65' }
                Partial { $text='Some folders unavailable'; $color='#E4AD65' }
                Issues { $text='Update needs attention'; $color='#E4AD65' }
            }
            $script:Controls[$p+'Status'].Text=$text
            $script:Controls[$p+'Status'].ToolTip=[string](Value-Or $scanner Message)
            $script:Controls[$p+'Dot'].Fill=[Windows.Media.BrushConverter]::new().ConvertFromString($color)
            $script:Controls[$p+'Count'].Text=('{0:N0}' -f [int](Value-Or $scanner SavedReports 0))
            $last=[string](Value-Or $scanner LastSuccessfulUpdate)
            $script:Controls[$p+'Updated'].Text='No successful update yet'
            if ($last) {
                try { $date=[datetime]::Parse($last).ToLocalTime(); $script:Controls[$p+'Updated'].Text=('Updated '+$date.ToString('MMM d, yyyy  h:mm tt')) } catch { $script:Controls[$p+'Updated'].Text='Last update recorded' }
            }
        }
        $attention=@($script:Dashboard.Attention)
        $script:Controls.AttentionList.ItemsSource=$attention
        $script:Controls.AttentionEmpty.Visibility=$(if($attention.Count){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible})
        $script:Controls.AttentionEmpty.Text=$(if($complete){'No attention items in the current review period.'}else{'Run First-Time Setup to see report coverage and items needing review.'})
        $script:Controls.AttentionCount.Text=('{0:N0} items to review' -f $attention.Count)
        Refresh-Reports
    } catch { Show-Note $_.Exception.Message 'Archive could not be read' $true }
}
function Fill-Settings {
    $script:Controls.ArchivePath.Text=[string]$script:Config.ArchiveRoot
    $script:Controls.DailyLookback.Text=[string]$script:Config.LookbackDays
    $script:Controls.MonthlyLookback.Text=[string]$script:Config.MonthlyLookbackMonths
    $script:Controls.MinimumAge.Text=[string]$script:Config.MinimumFileAgeSeconds
    $script:Controls.ScannerSettingsPanel.Children.Clear()
    $script:ScannerEditors=@{}
    foreach ($source in @($script:Config.Sources)) {
        $name=[Security.SecurityElement]::Escape([string]$source.Name)
        $row=Load-Window @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" BorderBrush="#2B3C55" BorderThickness="0,1,0,0" Padding="0,15,0,15"><StackPanel><TextBlock Text="$name" FontWeight="SemiBold" FontSize="14"/><TextBlock Text="Network report folder" Foreground="#91A9C7" Margin="0,10,0,6"/><TextBox x:Name="SourcePath"/><WrapPanel Margin="0,10,0,0"><StackPanel Width="115" Margin="0,0,14,0"><TextBlock Text="Preferred drive" Foreground="#91A9C7" Margin="0,0,0,6"/><TextBox x:Name="Drive" MaxLength="1"/></StackPanel><StackPanel Width="140" Margin="0,0,14,0"><TextBlock Text="Monthly hint (KB)" Foreground="#91A9C7" Margin="0,0,0,6"/><TextBox x:Name="Threshold"/></StackPanel><StackPanel Width="145" Margin="0,0,14,0"><TextBlock Text="Expected Daily QA" Foreground="#91A9C7" Margin="0,0,0,6"/><ComboBox x:Name="Schedule"/></StackPanel><StackPanel Width="155"><TextBlock Text="Active from (yyyy-MM-dd)" Foreground="#91A9C7" Margin="0,0,0,6"/><TextBox x:Name="ActiveFrom"/></StackPanel></WrapPanel><CheckBox x:Name="MonthlyExpected" Content="Include this scanner in Monthly QA coverage review" Margin="0,12,0,0"/></StackPanel></Border>
"@
        $ed=@{}
        foreach ($n in @('SourcePath','Drive','Threshold','Schedule','ActiveFrom','MonthlyExpected')) { $ed[$n]=$row.FindName($n) }
        $ed.SourcePath.Text=[string]$source.Path; $ed.Drive.Text=[string]$source.DriveLetter
        $ed.Threshold.Text=[string]$source.MonthlyThresholdKB; $ed.ActiveFrom.Text=[string]$source.ActiveFrom
        foreach($schedule in @('AllDays','Weekdays','Off')) { [void]$ed.Schedule.Items.Add($schedule) }
        $ed.Schedule.SelectedItem=[string]$source.DailySchedule
        $ed.MonthlyExpected.IsChecked=[bool]$source.ExpectedMonthly
        $script:ScannerEditors[[string]$source.Scanner]=$ed
        [void]$script:Controls.ScannerSettingsPanel.Children.Add($row)
    }
}
function Save-Settings {
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
        if ($cfg.LookbackDays -lt 1 -or $cfg.LookbackDays -gt 730) { throw 'Daily lookback must be from 1 to 730 days.' }
        if ($cfg.MonthlyLookbackMonths -lt 1 -or $cfg.MonthlyLookbackMonths -gt 24) { throw 'Monthly lookback must be from 1 to 24 months.' }
        if ($cfg.MinimumFileAgeSeconds -lt 0 -or $cfg.MinimumFileAgeSeconds -gt 3600) { throw 'Minimum PDF age must be from 0 to 3600 seconds.' }
        foreach ($source in @($cfg.Sources)) {
            $ed=$script:ScannerEditors[[string]$source.Scanner]
            $source.Path=$ed.SourcePath.Text.Trim(); $source.DriveLetter=$ed.Drive.Text.Trim().ToUpperInvariant()
            if($source.Path -notmatch '^\\\\[^\\]+\\[^\\]+') { throw ('Enter a valid UNC folder for '+$source.Name) }
            if($source.DriveLetter -notmatch '^[D-Z]$') { throw ('Choose one drive letter D through Z for '+$source.Name) }
            $source.MonthlyThresholdKB=[double]$ed.Threshold.Text
            if ($source.MonthlyThresholdKB -lt 1 -or $source.MonthlyThresholdKB -gt 10000) { throw 'Monthly candidate threshold must be from 1 to 10000 KB.' }
            $source.DailySchedule=[string]$ed.Schedule.SelectedItem
            $source.ExpectedMonthly=[bool]$ed.MonthlyExpected.IsChecked
            $source.ActiveFrom=$ed.ActiveFrom.Text.Trim()
            if ($source.ActiveFrom) {
                $parsed=[datetime]::MinValue
                if(-not [datetime]::TryParseExact($source.ActiveFrom,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)) { throw 'Active-from dates must use yyyy-MM-dd, for example 2024-01-01.' }
            }
        }
        if (@($cfg.Sources | Group-Object DriveLetter | Where-Object Count -gt 1).Count) { throw 'Use a different preferred drive letter for each scanner.' }
        Save-QaConfig -AppRoot $script:AppRoot -Config $cfg | Out-Null
        $script:Config=$cfg
        Refresh-Dashboard
        $script:Controls.StatusText.Text='Advanced settings saved.'
        return $true
    } catch { Show-Note $_.Exception.Message 'Check settings' $true; return $false }
}
function Set-Busy {
    param([bool]$Busy)
    $script:Busy=$Busy
    foreach ($name in @('SetupButton','UpdateButton','SaveSettingsButton','ReconnectButton','AuditButton','ReclassifyButton','ReviewReportButton','AdoptLegacyButton','BrowseArchiveButton')) { $script:Controls[$name].IsEnabled=(-not $Busy) }
    $script:Controls.AdvancedView.IsEnabled=(-not $Busy)
    $script:Controls.CancelButton.Visibility=$(if($Busy){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed})
    $script:Controls.WorkProgress.Visibility=$(if($Busy){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed})
}
function Start-Work {
    param([string]$Mode,$Plan=$null,$Decisions=@(),[string]$LegacyRoot='',$Credentials=@{})
    if ($script:Busy) { return }
    $script:CurrentMode=$Mode
    $shared=[hashtable]::Synchronized(@{Message='Preparing your request...'; Percent=0; Cancel=$false; Done=$false; Error=''; Result=$null})
    $runspace=[RunspaceFactory]::CreateRunspace(); $runspace.ApartmentState='MTA'; $runspace.ThreadOptions='ReuseThread'; $runspace.Open()
    $ps=[PowerShell]::Create(); $ps.Runspace=$runspace
    $workerCode=@'
param($appRoot,$config,$mode,$progress,$plan,$decisions,$legacyRoot,$credentials)
$ErrorActionPreference='Stop'
try {
 Import-Module (Join-Path $appRoot 'App\Archive.psm1') -Force -ErrorAction Stop
 if ($mode -eq 'SetupPreview') {
  $legacyIndex=Join-Path $config.ArchiveRoot 'QA_Master_Index_v2.csv'
  $statePath=Join-Path $config.ArchiveRoot '.ctqa\state.json'
  if((Test-Path -LiteralPath $legacyIndex -PathType Leaf) -and -not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
   $progress.Result=[pscustomobject]@{LegacyRoot=$config.ArchiveRoot;LegacyCount=@(Import-Csv -LiteralPath $legacyIndex).Count}
  } else { $progress.Result=Invoke-QaOperation -Config $config -Mode Preview -Progress $progress }
 } elseif ($mode -eq 'Reconnect') {
  Import-Module (Join-Path $appRoot 'App\Network.psm1') -Force -ErrorAction Stop
  $results=New-Object 'System.Collections.Generic.List[object]'
  $i=0
  foreach($scanner in @($config.Sources)) {
   if ($progress.Cancel) { break }
   $progress.Message='Checking connection to '+$scanner.Name+'...'
   $cred=$null
   if($credentials.ContainsKey([string]$scanner.Scanner)) { $cred=$credentials[[string]$scanner.Scanner] }
   [void]$results.Add((Reconnect-QaScanner -Scanner $scanner -Credential $cred))
   $i++; $progress.Percent=[int](100*$i/@($config.Sources).Count)
  }
  $progress.Result=[pscustomobject]@{Connections=@($results.ToArray())}
 } else {
  $arguments=@{Config=$config; Mode=$mode; Progress=$progress}
  if($null -ne $plan) { $arguments.Plan=$plan }
  if(@($decisions).Count) { $arguments.Decisions=$decisions }
  if($legacyRoot) { $arguments.LegacyRoot=$legacyRoot }
  $progress.Result=Invoke-QaOperation @arguments
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
<TextBlock x:Name="PreviewTitle" Text="Review your import" FontSize="23" FontWeight="SemiBold"/><TextBlock x:Name="PreviewSummary" Grid.Row="1" Foreground="#A9BDD5" Margin="0,10,0,17"/><TextBlock x:Name="PreviewConnections" Grid.Row="2" Foreground="#E1B870" TextWrapping="Wrap" Margin="0,0,0,14"/><DataGrid x:Name="PreviewGrid" Grid.Row="3"><DataGrid.Columns><DataGridTextColumn Header="Scanner" Binding="{Binding ScannerName}" Width="100"/><DataGridTextColumn Header="Original filename" Binding="{Binding OriginalFileName}" Width="*"/><DataGridTextColumn Header="Classification" Binding="{Binding CategoryLabel}" Width="190"/><DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="130"/></DataGrid.Columns></DataGrid><TextBlock x:Name="PreviewNotice" Grid.Row="4" Text="Only accessible scanners are included. Pending candidates are not confirmed Monthly QA. Originals are never changed. Each new copy is checked with SHA-256 before it enters the index." Foreground="#8EA7C4" TextWrapping="Wrap" Margin="0,15,0,15"/><StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="Reconnect" Content="Reconnect scanners" Margin="0,0,10,0"/><Button x:Name="Dismiss" Content="Back" Margin="0,0,10,0"/><Button x:Name="Apply" Content="Confirm and copy reports" Background="#1D6871" BorderBrush="#33ACAC"/></StackPanel>
'@
    $dialog=New-Dialog 'Preview before making changes' $content 1000 630
    $dialog.FindName('PreviewSummary').Text=$text
    $warnings=New-Object 'System.Collections.Generic.List[string]'
    foreach($scanner in @(Value-Or $Result Scanners @())) {
        if([string]$scanner.Status -notin @('Connected','OK')) {
            [void]$warnings.Add(([string](Value-Or $scanner Name (Value-Or $scanner Scanner))+': '+[string](Value-Or $scanner Message 'Connection unavailable. Existing archive records remain available.')))
        }
    }
    $dialog.FindName('PreviewConnections').Text=($warnings -join "`r`n")
    $dialog.FindName('Reconnect').Visibility=$(if($warnings.Count -and $ApplyMode -eq 'Import'){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed})
    $dialog.FindName('Reconnect').Add_Click({param($sender,$args) $parent=[Windows.Window]::GetWindow($sender);$parent.Tag='Reconnect';$parent.DialogResult=$false})
    Add-RecordLabels $plan.Items
    $dialog.FindName('PreviewGrid').ItemsSource=@($plan.Items)
    if ($ApplyMode -eq 'Reclassify') {
        $dialog.FindName('PreviewTitle').Text='Review classification changes'
        $dialog.FindName('PreviewNotice').Text='Confirm only after checking these PDFs against your department checklist. Every decision retains the reviewer, reason, and report hash in the master index and retained review history.'
        $dialog.FindName('Apply').Content='Confirm reviewed classifications'
    }
    # Event closures hold only this dialog; no worker execution is attached to dispatcher objects.
    $dialog.FindName('Dismiss').Add_Click({ param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).DialogResult=$false })
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
    param([string]$Name)
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><TextBlock x:Name="CredentialTitle" FontSize="21" FontWeight="SemiBold"/><TextBlock Grid.Row="1" Text="Use your approved scanner account. The password stays in memory for this reconnect request and is never saved." TextWrapping="Wrap" Foreground="#9CB3CE" Margin="0,12,0,18"/><StackPanel Grid.Row="2"><TextBlock Text="Username (or DOMAIN\username)" Foreground="#9CB3CE" Margin="0,0,0,7"/><TextBox x:Name="Username" Text="SCANNER_USERNAME"/></StackPanel><StackPanel Grid.Row="3" Margin="0,14,0,0"><TextBlock Text="Password" Foreground="#9CB3CE" Margin="0,0,0,7"/><PasswordBox x:Name="Password" Padding="10,8" Background="#182940" Foreground="White" BorderBrush="#314763"/></StackPanel><TextBlock Grid.Row="4" Text="Ask IT if another account is already connected to this server. The app will never close that connection automatically." TextWrapping="Wrap" Foreground="#869FBF" Margin="0,15,0,15"/><StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="Skip" Content="Skip scanner" Margin="0,0,10,0"/><Button x:Name="Connect" Content="Reconnect" Background="#1D6871"/></StackPanel>
'@
    $d=New-Dialog 'Secure scanner connection' $content 580 440
    $d.FindName('CredentialTitle').Text='Connect to '+$Name
    $d.FindName('Skip').Add_Click({param($sender,$args) [Windows.Window]::GetWindow($sender).DialogResult=$false})
    $d.FindName('Connect').Add_Click({param($sender,$args) $parent=[Windows.Window]::GetWindow($sender); if($parent.FindName('Username').Text.Trim() -and $parent.FindName('Password').SecurePassword.Length -gt 0){$parent.DialogResult=$true}})
    if($d.ShowDialog() -eq $true) {
        $secure=$d.FindName('Password').SecurePassword.Copy()
        $cred=New-Object System.Management.Automation.PSCredential($d.FindName('Username').Text.Trim(),$secure)
        $d.FindName('Password').Clear()
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
        [void]$lines.Add(($sourceName+': '+[string]$connection.Message))
        if([string]$connection.Status -eq 'CredentialsRequired') {
            $source=@($script:Config.Sources | Where-Object Scanner -eq $connection.Scanner)[0]
            $credential=Show-Credentials ([string]$source.Name)
            if($null -ne $credential) { $needed[[string]$connection.Scanner]=$credential }
        }
    }
    if($needed.Count) { Start-Work -Mode Reconnect -Credentials $needed; return }
    if($script:AfterReconnect) {
        $next=$script:AfterReconnect; $script:AfterReconnect=''
        $script:Controls.StatusText.Text='Connections checked. Preparing the report preview...'
        Start-Work -Mode $next
        return
    }
    Show-Note (($lines -join "`r`n`r`n")+"`r`n`r`nUse Update Reports to refresh scanner status and import accessible reports.") 'Scanner connections'
}
function Review-SelectedReport {
    $record=$script:Controls.ReportsGrid.SelectedItem
    if($null -eq $record) { Show-Note 'Select a saved report first.'; return }
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><TextBlock Text="Confirm a report classification" FontSize="23" FontWeight="SemiBold"/><TextBlock x:Name="ReportName" Grid.Row="1" Foreground="#9CB5D0" TextWrapping="Wrap" Margin="0,12,0,15"/><StackPanel Grid.Row="2"><TextBlock Text="Classification" Margin="0,0,0,7"/><ComboBox x:Name="Category"/></StackPanel><StackPanel Grid.Row="3" Margin="0,13,0,0"><TextBlock Text="Your name or approved reviewer ID" Margin="0,0,0,7"/><TextBox x:Name="Reviewer"/></StackPanel><StackPanel Grid.Row="4" Margin="0,13,0,0"><TextBlock Text="Reason / tests reviewed" Margin="0,0,0,7"/><TextBox x:Name="Reason" TextWrapping="Wrap" MinHeight="60" AcceptsReturn="True"/></StackPanel><CheckBox x:Name="Authorized" Grid.Row="5" Content="I am authorized to review QA reports and have checked this PDF." Margin="0,17,0,16"/><StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="Open" Content="Open PDF" Margin="0,0,10,0"/><Button x:Name="Cancel" Content="Cancel" Margin="0,0,10,0"/><Button x:Name="Preview" Content="Preview decision" Background="#1D6871"/></StackPanel>
'@
    $d=New-Dialog 'Review classification' $content 700 580
    $d.Tag=$record
    $d.FindName('ReportName').Text=[string]$record.OriginalFileName+"`r`nCurrent: "+(Get-CategoryLabel ([string]$record.Category))+"`r`nBasis: "+[string]$record.ClassificationBasis
    $d.FindName('Category').DisplayMemberPath='Label'
    $d.FindName('Category').SelectedValuePath='Value'
    foreach($c in @('Daily_QA','Monthly_QA','Monthly_QA/Pending_Verification','Acceptance_Tests','Needs_Review')) {[void]$d.FindName('Category').Items.Add([pscustomobject]@{Value=$c;Label=(Get-CategoryLabel $c)})}
    $d.FindName('Category').SelectedValue=[string]$record.Category
    $d.FindName('Open').Add_Click({param($sender,$args) $parent=[Windows.Window]::GetWindow($sender); Safe-Open ([string]$parent.Tag.DestinationPath)})
    $d.FindName('Cancel').Add_Click({param($sender,$args) [Windows.Window]::GetWindow($sender).DialogResult=$false})
    $d.FindName('Preview').Add_Click({param($sender,$args) $parent=[Windows.Window]::GetWindow($sender); if($parent.FindName('Authorized').IsChecked -eq $true -and $parent.FindName('Reviewer').Text.Trim() -and $parent.FindName('Reason').Text.Trim()){ $parent.DialogResult=$true }else{[void][Windows.MessageBox]::Show($parent,'Enter your reviewer name and reason, and confirm that you are authorized and have checked the PDF.','Review information required')}})
    if($d.ShowDialog() -eq $true) {
        $script:PendingDecisions=@([pscustomobject]@{RecordId=[string]$record.Id;Hash=[string]$record.Hash;Category=[string]$d.FindName('Category').SelectedValue;Reviewer=$d.FindName('Reviewer').Text.Trim();Reason=$d.FindName('Reason').Text.Trim()})
        Start-Work -Mode ReclassifyPreview -Decisions $script:PendingDecisions
    }
}
function Open-AttentionItem {
    $item=$script:Controls.AttentionList.SelectedItem
    if($null -eq $item){return}
    $recordId=[string](Value-Or $item RecordId)
    if($recordId) {
        $script:PendingOnly=$false; $script:Controls.ReportSearch.Text=''; Show-Page Reports; Refresh-Reports
        $found=@($script:Dashboard.Records | Where-Object Id -eq $recordId)
        if($found.Count){$script:Controls.ReportsGrid.SelectedItem=$found[0];$script:Controls.ReportsGrid.ScrollIntoView($found[0]);return}
    }
    $path=[string](Value-Or $item Path)
    $message=[string]$item.Message+"`r`n`r`n"+[string](Value-Or $item Details 'Review the saved archive and scanner history. Missing archive records do not prove QA was not performed.')
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><TextBlock Text="Archive finding" FontSize="23" FontWeight="SemiBold"/><TextBox x:Name="Details" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Margin="0,16,0,18"/><StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="Open" Content="Open related folder / PDF" Margin="0,0,10,0"/><Button x:Name="Close" Content="Close"/></StackPanel>
'@
    $d=New-Dialog 'QA attention details' $content 700 440
    $d.Tag=$path; $d.FindName('Details').Text=$message
    $d.FindName('Open').IsEnabled=([bool]$path)
    $d.FindName('Open').Add_Click({param($sender,$args) $parent=[Windows.Window]::GetWindow($sender);$p=[string]$parent.Tag;if([IO.Path]::GetExtension($p) -eq '.pdf'){Safe-Open $p}else{Safe-Open $p -Folder}})
    $d.FindName('Close').Add_Click({param($sender,$args) [Windows.Window]::GetWindow($sender).Close()})
    [void]$d.ShowDialog()
}

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
    Fit-Window $script:Window
    $script:Config=Read-QaConfig -AppRoot $script:AppRoot
    Fill-Settings; Refresh-Dashboard
    $script:Controls.DashboardNav.Add_Click({Show-Page Dashboard})
    $script:Controls.ReportsNav.Add_Click({Show-Page Reports})
    $script:Controls.AdvancedNav.Add_Click({Show-Page Advanced})
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
    $script:Controls.OpenFolderButton.Add_Click({Safe-Open (Join-Path $script:Config.ArchiveRoot 'Reports') -Folder})
    $script:Controls.ReportSearch.Add_TextChanged({Refresh-Reports})
    $script:Controls.ReviewPendingButton.Add_Click({$script:PendingOnly=(-not $script:PendingOnly);Refresh-Reports})
    $script:Controls.OpenReportButton.Add_Click({if($null -ne $script:Controls.ReportsGrid.SelectedItem){Safe-Open ([string]$script:Controls.ReportsGrid.SelectedItem.DestinationPath)}else{Show-Note 'Select a saved report first.'}})
    $script:Controls.ReportsGrid.Add_MouseDoubleClick({if($null -ne $script:Controls.ReportsGrid.SelectedItem){Safe-Open ([string]$script:Controls.ReportsGrid.SelectedItem.DestinationPath)}})
    $script:Controls.ReviewReportButton.Add_Click({Review-SelectedReport})
    $script:Controls.AttentionList.Add_SelectionChanged({if($null -ne $script:Controls.AttentionList.SelectedItem){Open-AttentionItem}})
    $script:Controls.AttentionList.Add_PreviewKeyDown({param($sender,$args) if($args.Key -eq [Windows.Input.Key]::Enter){Open-AttentionItem;$args.Handled=$true}})
    $script:Controls.SaveSettingsButton.Add_Click({[void](Save-Settings)})
    $script:Controls.BrowseArchiveButton.Add_Click({$p=Choose-Folder 'Choose the archive parent location' $script:Controls.ArchivePath.Text;if($p){$script:Controls.ArchivePath.Text=$p}})
    $script:Controls.ReconnectButton.Add_Click({if(Save-Settings){Start-Work -Mode Reconnect}})
    $script:Controls.OpenLogsButton.Add_Click({Safe-Open ([string]$script:Config.ArchiveRoot) -Folder -Diagnostics})
    $script:Controls.AuditButton.Add_Click({Start-Work -Mode Audit})
    $script:Controls.ReclassifyButton.Add_Click({$script:PendingOnly=$true;Show-Page Reports;Refresh-Reports;Show-Note 'Select a report and click Review classification. Open the PDF first, then enter your name and the reason for your decision.'})
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
        if($cancelled -and -not $errorText){$script:AfterReconnect='';$script:Controls.StatusText.Text='Operation cancelled safely. Completed copies remain saved.';Refresh-Dashboard;return}
        if($errorText){$script:Controls.StatusText.Text='The operation needs attention. No source reports were changed.';Show-Note $errorText 'Operation could not finish' $true;Refresh-Dashboard;return}
        $script:Controls.StatusText.Text=Summary-Text (Value-Or $result Summary $null)
        Refresh-Dashboard
        if($mode -eq 'SetupPreview' -and [string](Value-Or $result LegacyRoot)) {
            $message=('An existing archive was found here with {0:N0} index records. Reuse it safely? Existing PDFs and the old index will remain unchanged. The app verifies saved PDFs and builds its new searchable index. Legacy Monthly QA labels will require fresh verification.' -f [int]$result.LegacyCount)
            $answer=[Windows.MessageBox]::Show($script:Window,$message,'Existing archive found',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question)
            if($answer -eq [Windows.MessageBoxResult]::Yes){Start-Work -Mode AdoptLegacy -LegacyRoot ([string]$result.LegacyRoot)}else{Show-Page Advanced;Show-Note 'Choose another archive destination, or use Reuse existing v2/v3 archive when ready. No files were changed.'}
        }
        elseif($mode -eq 'Preview' -or $mode -eq 'SetupPreview'){Show-Preview $result}
        elseif($mode -eq 'ReclassifyPreview'){Show-Preview $result 'Reclassify'}
        elseif($mode -eq 'Reconnect'){Finish-Connections $result}
        elseif($mode -eq 'Import' -or $mode -eq 'AdoptLegacy'){ $script:Config=Read-QaConfig -AppRoot $script:AppRoot;Refresh-Dashboard }
    })
    $script:Window.Add_Closing({param($sender,$args) if($script:Busy){$args.Cancel=$true;$script:Worker.Shared.Cancel=$true;$script:Controls.StatusText.Text='Finishing the current safe checkpoint. Close again when the operation has stopped.';Show-Note 'A report operation is still running. Cancellation has been requested. Please leave this window open until the current safe checkpoint finishes.' 'Finishing safely'}})
    $script:Window.Add_Closed({$script:Timer.Stop()})
    $script:Window.Add_PreviewKeyDown({param($sender,$args) if($args.Key -eq [Windows.Input.Key]::F1){Show-Page Advanced;$args.Handled=$true}})
    $script:Window.Dispatcher.Add_UnhandledException({param($sender,$args) $args.Handled=$true;Show-Note $args.Exception.Message 'Application action needs attention' $true})
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
    $script:Timer.Start()
    [void]$script:Window.ShowDialog()
} catch {
    if($script:ConsoleHandle -ne [intptr]::Zero){try{[void][CtQa.NativeWindow]::ShowWindow($script:ConsoleHandle,5)}catch{}}
    $message='CT QA Manager Pro could not start.'+"`r`n`r`n"+$_.Exception.Message+"`r`n`r`nExtract the complete application folder. If scripts are blocked, ask hospital IT to approve the package; do not change execution policy."
    try { [void][Windows.MessageBox]::Show($message,'CT QA Manager Pro',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error) } catch { Write-Error $message }
    exit 1
}
