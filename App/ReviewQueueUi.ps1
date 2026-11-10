# Sourced by Start.ps1. The queue uses the existing archive worker and audit engine.
function Update-QuickQueueControls {
    if($null -eq $script:ReviewQueue){return};$q=$script:ReviewQueue;$c=$q.Controls
    $ready=(-not $script:Busy -and $null -ne $q.Record -and $q.Viewed -and $c.QueueAuthorized.IsChecked -eq $true -and $c.QueueReviewer.Text.Trim())
    $c.QueueAccept.IsEnabled=($ready -and [string]$c.QueueType.SelectedValue -in @('Monthly_QA','Daily_QA','Acceptance_Tests'))
    $c.QueueDecline.IsEnabled=[bool]$ready
    $c.QueueSkip.IsEnabled=(-not $script:Busy)
    $c.QueueUndo.IsEnabled=(-not $script:Busy -and $null -ne $q.Undo -and $c.QueueAuthorized.IsChecked -eq $true -and [bool]$c.QueueReviewer.Text.Trim())
    $c.PreviousPage.IsEnabled=(-not $script:Busy -and $q.PageNumber -gt 0)
    $c.NextPage.IsEnabled=(-not $script:Busy -and $q.PageNumber+1 -lt $q.PageCount)
    $c.QueueType.IsEnabled=(-not $script:Busy);$c.QueueSelectAll.IsEnabled=[bool]$ready
    $c.QueueOpenPdf.IsEnabled=($null -ne $q.Record -and -not $script:Busy)
    $c.QueueChecklistPanel.Visibility=$(if([string]$c.QueueType.SelectedValue -eq 'Monthly_QA'){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed})
    $c.QueueAccept.Content=$(switch([string]$c.QueueType.SelectedValue){'Monthly_QA'{'Accept Monthly report'}'Daily_QA'{'Accept Daily report'}'Acceptance_Tests'{'Accept acceptance test'}default{'Choose a report type'}})
    if($q.Demo){$c.QueueAccept.IsEnabled=$false;$c.QueueDecline.IsEnabled=$false;$c.QueueUndo.IsEnabled=$false}
}
function Update-QuickQueueZoom {
    if($null -eq $script:ReviewQueue){return};$q=$script:ReviewQueue
    $width=[math]::Max(240,$q.Controls.PreviewScroll.ActualWidth-20)
    switch([string]$q.Controls.PreviewZoom.SelectedItem){'100%'{$width=1200}'150%'{$width=1800}}
    $q.Controls.QueuePageImage.Width=$width
}
function Get-QuickQueuePending {
    param([switch]$IncludeSkipped)
    $q=$script:ReviewQueue;$byId=@{};foreach($record in @($script:Dashboard.Records)){$byId[[string]$record.Id]=$record}
    foreach($id in $q.Scope){if($byId.ContainsKey($id) -and (Test-QaReportPending $byId[$id]) -and ($IncludeSkipped -or -not $q.Skipped.ContainsKey($id))){$byId[$id]}}
}
function Set-QuickQueueImage {
    param([string]$Base64)
    $bytes=[Convert]::FromBase64String($Base64);$memory=New-Object IO.MemoryStream(,$bytes)
    try{$image=New-Object Windows.Media.Imaging.BitmapImage;$image.BeginInit();$image.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad;$image.StreamSource=$memory;$image.EndInit();$image.Freeze();$script:ReviewQueue.Controls.QueuePageImage.Source=$image}finally{$memory.Dispose()}
    $script:ReviewQueue.Controls.PreviewMessagePanel.Visibility=[Windows.Visibility]::Collapsed
    Update-QuickQueueZoom
}
function Start-QuickQueuePreview {
    $q=$script:ReviewQueue;if($null -eq $q.Record -or $q.Demo){return}
    $q.Controls.PreviewMessage.Text='Loading the saved PDF...';$q.Controls.PreviewMessagePanel.Visibility=[Windows.Visibility]::Visible
    $q.Waiting='PdfPreview';Start-Work -Mode PdfPreview -Plan ([pscustomobject]@{RecordId=[string]$q.Record.Id;PageNumber=$q.PageNumber})
}
function Show-QuickQueueRecord {
    param([string]$PreferredId='')
    $q=$script:ReviewQueue;$c=$q.Controls;$pending=@(Get-QuickQueuePending)
    $allPending=@(Get-QuickQueuePending -IncludeSkipped)
    $c.QueueProgress.Text=($allPending.Count.ToString()+' pending in this view / Accepted '+$q.Accepted+' / Declined '+$q.Declined+' / Skipped '+$q.Skipped.Count)
    $c.PageStatus.Text='';$q.Record=$null;if($PreferredId){$matches=@($pending|Where-Object Id -eq $PreferredId);if($matches.Count){$q.Record=$matches[0]}}
    if($null -eq $q.Record -and $pending.Count){$q.Record=$pending[0]}
    $q.Viewed=$false;$q.PageNumber=0;$q.PageCount=0;$q.Checks=@();$c.QueuePageImage.Source=$null;$c.QueueComponents.Children.Clear()
    $c.PreviewMessagePanel.Visibility=[Windows.Visibility]::Visible
    if($null -eq $q.Record){
        $c.QueueReportTitle.Text='No unreviewed PDFs remain in this session.';$c.QueueStatus.Text='Review session complete'
        $c.PreviewMessage.Text=$(if($allPending.Count){'Only skipped reports remain pending. Choose Review skipped PDFs to return to them.'}else{'Every report in this selected queue has a recorded decision.'})
        $c.QueueSkip.Content=$(if($allPending.Count){'Review skipped PDFs'}else{'No reports left'})
        Update-QuickQueueControls;return
    }
    $c.QueueSkip.Content='Skip for now / next PDF';$c.QueueReportTitle.Text=Get-QaReportTitle $q.Record;$c.QueueStatus.Text='Pending verification'
    $c.PageStatus.Text='Loading page 1...'
    $c.QueueWhyPending.Text='Why this is pending: '+[string](Value-Or $q.Record ClassificationBasis 'The suggested report type still needs your confirmation.')
    $type=if($q.Record.Category -eq 'Monthly_QA/Pending_Verification'){'Monthly_QA'}elseif($q.Record.Category -eq 'Daily_QA'){'Daily_QA'}else{''}
    $c.QueueType.SelectedValue=$type
    $source=@($script:Config.Sources|Where-Object Scanner -eq $q.Record.Scanner)[0]
    $month=if([string]$q.Record.ReportDate -match '^\d{4}-\d{2}'){$q.Record.ReportDate.Substring(0,7)}else{(Get-Date).ToString('yyyy-MM')}
    $required=@(Get-QaChecklistForMonth $source $month)
    foreach($item in $required){$check=New-Object Windows.Controls.CheckBox;$text=New-Object Windows.Controls.TextBlock;$text.Text=$item;$text.TextWrapping=[Windows.TextWrapping]::Wrap;$check.Content=$text;$check.Tag=$item;$check.IsChecked=$false;$check.Margin=New-Object Windows.Thickness(0,5,0,5);[void]$c.QueueComponents.Children.Add($check);$q.Checks+=@($check)}
    $c.QueueChecklistNote.Text=$(if($required.Count){'Check only the items you have verified in this PDF. Separate reports can cover different items.'}else{'No department checklist is configured for this month. Accepting the PDF type will not mark the monthly checklist complete.'})
    $c.QueueSelectAll.Visibility=$(if($required.Count){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed})
    Update-QuickQueueControls
    if($q.Demo){
        $path=Join-Path $script:AppRoot 'artifacts/windows/synthetic-pdf-preview.png'
        if([IO.File]::Exists($path)){Set-QuickQueueImage ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)));$c.PageStatus.Text='Page 1 of 1 / synthetic'}else{$c.PreviewMessage.Text='Synthetic PDF preview is generated by the native Windows test.'}
        $c.QueueMessage.Text='Synthetic demonstration only. No live reports, credentials or review decisions are used.'
    }else{Start-QuickQueuePreview}
}
function Submit-QuickQueueDecision {
    param([ValidateSet('Accept','Decline')][string]$Action,[string]$Category='')
    $q=$script:ReviewQueue;if($null -eq $q -or $script:Busy -or $q.Demo -or $null -eq $q.Record){return}
    try{
        if(-not $Category){$Category=[string]$q.Controls.QueueType.SelectedValue}
        $components=@();if($Action -eq 'Accept' -and $Category -eq 'Monthly_QA'){$components=@($q.Checks|Where-Object IsChecked -eq $true|ForEach-Object{[string]$_.Tag})}
        $decision=New-QaQuickReviewDecision -Record $q.Record -Action $Action -Category $Category -Reviewer $q.Controls.QueueReviewer.Text -Viewed $q.Viewed -Authorized ($q.Controls.QueueAuthorized.IsChecked -eq $true) -Components $components
        $q.PendingAction=$Action;$q.TargetId=[string]$q.Record.Id;$q.Waiting='Reclassify';$q.Controls.QueueMessage.Text='Saving this decision and its history...'
        Start-Work -Mode Reclassify -Decisions @($decision)
    }catch{$q.Controls.QueueMessage.Text=$_.Exception.Message;Update-QuickQueueControls}
}
function Open-QuickQueueDeclineMenu {
    $q=$script:ReviewQueue;if($null -eq $q -or -not $q.Controls.QueueDecline.IsEnabled){return}
    $menu=New-Object Windows.Controls.ContextMenu
    foreach($choice in @(@{Label='Not Monthly - save as Daily QA';Value='Daily_QA'},@{Label='Not Monthly - acceptance test';Value='Acceptance_Tests'},@{Label='Not Monthly - keep as another reviewed report';Value='Needs_Review'})){
        $item=New-Object Windows.Controls.MenuItem;$item.Header=$choice.Label;$item.Tag=$choice.Value
        $item.Add_Click({param($sender,$args) Submit-QuickQueueDecision -Action Decline -Category ([string]$sender.Tag)})
        [void]$menu.Items.Add($item)
    }
    $menu.PlacementTarget=$q.Controls.QueueDecline;$menu.IsOpen=$true
}
function Undo-QuickQueueDecision {
    $q=$script:ReviewQueue;if($script:Busy -or $null -eq $q.Undo -or $q.Demo){return}
    try{
        $current=@($script:Dashboard.Records|Where-Object Id -eq $q.Undo.RecordId)[0]
        $decision=New-QaUndoReviewDecision -Record $current -ReviewId $q.Undo.ReviewId -Reviewer $q.Controls.QueueReviewer.Text
        $q.TargetId=[string]$current.Id;$q.PendingAction='Undo';$q.Waiting='Reclassify';$q.Controls.QueueMessage.Text='Restoring the previous decision state...'
        Start-Work -Mode Reclassify -Decisions @($decision)
    }catch{$q.Controls.QueueMessage.Text=$_.Exception.Message}
}
function Complete-QuickQueueWork {
    param([string]$Mode,$Result,[string]$ErrorText,[bool]$Cancelled)
    $q=$script:ReviewQueue
    if($null -eq $q -or -not $q.Window.IsVisible -or $q.Waiting -ne $Mode){return $false}
    $q.Waiting=''
    if($Mode -eq 'PdfPreview'){
        if(-not $ErrorText -and -not $Cancelled){
            try{
                if([string]$Result.RecordId -cne [string]$q.Record.Id -or [string]$Result.Hash -cne [string]$q.Record.Hash){throw 'The report changed while previewing. Reload the review list.'}
                Set-QuickQueueImage ([string]$Result.PngBase64);$q.PageCount=[int]$Result.PageCount;$q.Viewed=$true
                $q.Controls.PageStatus.Text=('Page '+($q.PageNumber+1)+' of '+$q.PageCount)
                $q.Controls.QueueMessage.Text='Inspect the PDF. Accept its type, decline the suggestion, or skip for later.'
            }catch{$ErrorText=$_.Exception.Message}
        }
        if($ErrorText){$q.Controls.PreviewMessage.Text='Built-in preview unavailable. Use Open PDF viewer, inspect the saved file, then make your decision.';$q.Controls.PreviewMessagePanel.Visibility=[Windows.Visibility]::Visible;$q.Controls.QueueMessage.Text=$ErrorText}
        if($Cancelled){$q.Controls.QueueMessage.Text='Preview stopped. No review decision was changed.'}
        Update-QuickQueueControls
        if($q.CloseWhenIdle){$q.Window.Close()}
        return $true
    }
    if($Mode -eq 'Reclassify'){
        Refresh-Dashboard
        if($ErrorText -or $Cancelled){$q.Controls.QueueMessage.Text=$(if($ErrorText){$ErrorText}else{'Decision was not saved.'});Update-QuickQueueControls;if($q.CloseWhenIdle){$q.Window.Close()};return $true}
        $changed=@($script:Dashboard.Records|Where-Object Id -eq $q.TargetId)[0]
        $q.BrowseDirty=$true
        if($q.PendingAction -eq 'Undo'){if($q.Undo.Action -eq 'Accept'){$q.Accepted=[math]::Max(0,$q.Accepted-1)}else{$q.Declined=[math]::Max(0,$q.Declined-1)};$q.Undo=$null;$q.Skipped.Remove([string]$changed.Id);Show-QuickQueueRecord -PreferredId ([string]$changed.Id);$q.Controls.QueueMessage.Text='Undo saved. The previous pending state was restored; both audit entries remain.'}
        else{
            $q.Undo=[pscustomobject]@{RecordId=[string]$changed.Id;ReviewId=[string]$changed.LastReviewId;Action=$q.PendingAction}
            if($q.PendingAction -eq 'Accept'){$q.Accepted++}else{$q.Declined++}
            Show-QuickQueueRecord
            $q.Controls.QueueMessage.Text=$(if($q.PendingAction -eq 'Accept'){'Accepted and removed from pending.'}else{'Suggestion declined; PDF kept and removed from pending.'})+' Undo last decision is available.'
        }
        Update-QuickQueueControls;if($q.CloseWhenIdle){$q.Window.Close()};return $true
    }
    return $false
}
function Open-QuickReviewQueue {
    param([switch]$DemoSnapshot)
    if($script:Busy){Show-Note 'Wait for the current operation or cancel it safely before reviewing.';return}
    $records=@($script:FilteredReports|Where-Object{Test-QaReportPending $_})
    if($DemoSnapshot){$records=@($script:Dashboard.Records|Where-Object{Test-QaReportPending $_})}
    if($records.Count -eq 0){Show-Note 'No pending PDFs match this view. Choose Pending review and adjust the scanner, period or QA type.';return}
    $window=Load-Window ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ReviewQueueWindow.xaml')))
    foreach($key in $script:Window.Resources.Keys){$window.Resources[$key]=$script:Window.Resources[$key]}
    $window.Owner=$script:Window;$window.Icon=$script:Window.Icon;Fit-Window $window
    $controls=@{};foreach($node in ([xml][IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ReviewQueueWindow.xaml'))).SelectNodes('//*[@*[local-name()="Name"]]')){$name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');if($name){$controls[$name]=$window.FindName($name)}}
    $q=[pscustomobject]@{Window=$window;Controls=$controls;Scope=[string[]]@($records|ForEach-Object{[string]$_.Id});Skipped=@{};Record=$null;Viewed=$false;PageNumber=0;PageCount=0;Checks=@();Undo=$null;Accepted=0;Declined=0;Waiting='';PendingAction='';TargetId='';CloseWhenIdle=$false;BrowseDirty=$false;Demo=[bool]$DemoSnapshot}
    $script:ReviewQueue=$q
    $controls.QueueReviewer.Text=$script:SessionReviewer
    foreach($item in @([pscustomobject]@{Value='';Label='Choose report type'},[pscustomobject]@{Value='Monthly_QA';Label='Monthly QA report'},[pscustomobject]@{Value='Daily_QA';Label='Daily QA report'},[pscustomobject]@{Value='Acceptance_Tests';Label='Acceptance test'})){[void]$controls.QueueType.Items.Add($item)}
    foreach($zoom in @('Fit','100%','150%')){[void]$controls.PreviewZoom.Items.Add($zoom)};$controls.PreviewZoom.SelectedIndex=0
    $controls.QueueReviewer.Add_TextChanged({Update-QuickQueueControls});$controls.QueueAuthorized.Add_Click({Update-QuickQueueControls});$controls.QueueType.Add_SelectionChanged({Update-QuickQueueControls})
    $controls.QueueAccept.Add_Click({Submit-QuickQueueDecision -Action Accept});$controls.QueueDecline.Add_Click({Open-QuickQueueDeclineMenu});$controls.QueueUndo.Add_Click({Undo-QuickQueueDecision})
    $controls.QueueSelectAll.Add_Click({foreach($check in $script:ReviewQueue.Checks){$check.IsChecked=$true}})
    $controls.QueueSkip.Add_Click({$queue=$script:ReviewQueue;if($null -ne $queue.Record){$queue.Skipped[[string]$queue.Record.Id]=$true}else{$queue.Skipped=@{}};Show-QuickQueueRecord})
    $controls.QueueOpenPdf.Add_Click({$queue=$script:ReviewQueue;try{$path=[string]$queue.Record.DestinationPath;if(-not [IO.File]::Exists($path)){throw 'Saved PDF is missing.'};Start-Process -FilePath $path|Out-Null;$queue.Viewed=$true;$queue.Controls.QueueMessage.Text='PDF opened in the normal viewer. Inspect it before accepting or declining.';Update-QuickQueueControls}catch{$queue.Controls.QueueMessage.Text=$_.Exception.Message}})
    $controls.PreviousPage.Add_Click({$script:ReviewQueue.PageNumber--;Start-QuickQueuePreview});$controls.NextPage.Add_Click({$script:ReviewQueue.PageNumber++;Start-QuickQueuePreview})
    $controls.PreviewZoom.Add_SelectionChanged({Update-QuickQueueZoom});$controls.PreviewScroll.Add_SizeChanged({Update-QuickQueueZoom})
    $controls.QueueClose.Add_Click({$script:ReviewQueue.Window.Close()})
    $window.Add_PreviewKeyDown({param($sender,$args) if($args.KeyboardDevice.Modifiers -eq [Windows.Input.ModifierKeys]::Control){if($args.Key -eq [Windows.Input.Key]::Enter -and $script:ReviewQueue.Controls.QueueAccept.IsEnabled){Submit-QuickQueueDecision -Action Accept;$args.Handled=$true}elseif($args.Key -eq [Windows.Input.Key]::D){Open-QuickQueueDeclineMenu;$args.Handled=$true}}})
    $window.Add_Closing({param($sender,$args) $queue=$script:ReviewQueue;if($script:Busy -and $queue.Waiting){$args.Cancel=$true;$queue.CloseWhenIdle=$true;if($queue.Waiting -eq 'PdfPreview'){$script:Worker.Shared.Cancel=$true};$queue.Controls.QueueMessage.Text='Finishing the current safe step before closing...'}})
    if($DemoSnapshot){$controls.QueueReviewer.Text='Synthetic reviewer';Show-QuickQueueRecord;return $window}
    $window.Add_ContentRendered({if($null -eq $script:ReviewQueue.Record){Show-QuickQueueRecord}})
    [void]$window.ShowDialog();$script:SessionReviewer=$controls.QueueReviewer.Text.Trim();$dirty=$q.BrowseDirty;$controls.QueuePageImage.Source=$null;$script:ReviewQueue=$null
    if($dirty -and -not $script:Busy){$script:BrowsePreviousStatus='Review decisions saved. Refreshing readable report folders...';$script:BrowseOpenOnComplete=$false;Start-Work -Mode BrowseRefresh}
}

function Show-ReportDecisionHistory {
    if($script:Busy){return};$record=$script:Controls.ReportsGrid.SelectedItem
    if($null -eq $record){Show-Note 'Select a report to see its decision history.';return}
    $history=@((Value-Or $script:Dashboard Reviews @())|Where-Object RecordId -eq $record.Id)
    $content=@'
<Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock Text="Report decision history" FontSize="23" FontWeight="SemiBold"/>
<TextBox x:Name="History" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Margin="0,15,0,15"/>
<StackPanel Grid.Row="2"><TextBlock Text="To undo the latest decision, enter your reviewer name / approved ID." TextWrapping="Wrap" Foreground="#A6C5D5"/><TextBox x:Name="Reviewer" Margin="0,8,0,8"/><CheckBox x:Name="Authorized" Content="I am authorized to undo this report decision."/></StackPanel>
<StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0"><Button x:Name="Undo" Content="Undo latest decision" Margin="0,0,10,0"/><Button x:Name="Close" Content="Close"/></StackPanel>
'@
    $d=New-Dialog 'Report decision history' $content 760 620
    $lines=New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add((Get-QaReportTitle $record));[void]$lines.Add('')
    foreach($entry in $history){[void]$lines.Add(([string]$entry.TimeUtc+' / '+[string](Value-Or $entry ReviewAction 'Classify')+' / '+[string]$entry.Reviewer));[void]$lines.Add(([string]$entry.From+' -> '+[string]$entry.To));[void]$lines.Add([string]$entry.Reason);[void]$lines.Add('')}
    if(-not $history.Count){[void]$lines.Add('No saved decision history for this report.')}
    $d.FindName('History').Text=$lines -join "`r`n";$d.FindName('Reviewer').Text=$script:SessionReviewer
    $latest=$null;if($history.Count){$latest=$history[-1]}
    $canUndo=($null -ne $latest -and [string](Value-Or $latest ReviewId) -eq [string](Value-Or $record LastReviewId) -and $null -ne (Value-Or $latest PreviousReviewSnapshot $null))
    $d.FindName('Undo').IsEnabled=$canUndo;$d.Tag=@{Record=$record;Latest=$latest;Decision=$null}
    $d.FindName('Close').Add_Click({param($sender,$args) [Windows.Window]::GetWindow($sender).Close()})
    $d.FindName('Undo').Add_Click({param($sender,$args) $parent=[Windows.Window]::GetWindow($sender)
        if($parent.FindName('Authorized').IsChecked -ne $true -or -not $parent.FindName('Reviewer').Text.Trim()){[void][Windows.MessageBox]::Show($parent,'Enter your name and confirm authorization before undoing.','Reviewer needed');return}
        try{$parent.Tag.Decision=New-QaUndoReviewDecision -Record $parent.Tag.Record -ReviewId $parent.Tag.Latest.ReviewId -Reviewer $parent.FindName('Reviewer').Text;$parent.DialogResult=$true}catch{[void][Windows.MessageBox]::Show($parent,$_.Exception.Message,'Cannot undo')}
    })
    if($d.ShowDialog() -eq $true){$script:SessionReviewer=$d.FindName('Reviewer').Text.Trim();Start-Work -Mode Reclassify -Decisions @($d.Tag.Decision)}
}
