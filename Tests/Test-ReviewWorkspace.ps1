[CmdletBinding()]param([string]$ConfigPath,[string]$OutputPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$ProductRoot=Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
foreach($name in @('Archive','Review','Reports','Process','Browse')){Import-Module (Join-Path $ProductRoot ('App/'+$name+'.psm1')) -Force}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $ProductRoot 'App/Start.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Value-Or','Get-CategoryLabel','Load-Window','Fit-Window','Add-RecordLabels')){$definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);. ([scriptblock]::Create($definition.Extent.Text))}
$script:AppRoot=$ProductRoot;$script:Config=Import-Clixml $ConfigPath;$script:Busy=$false;$script:ReviewQueue=$null;$script:SessionReviewer='';$script:DemoPreview=$false;$script:Assertions=0;$script:Stage=0;$script:Failure=''
function Check($Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Refresh-Dashboard {$script:Dashboard=Get-QaDashboard $script:Config;Add-RecordLabels $script:Dashboard.Records;$script:FilteredReports=@($script:Dashboard.Records)}
function Show-Note {param($Text,$Title) throw ($Title+': '+$Text)}
function Start-Work {
 param([string]$Mode,$Plan=$null,$Decisions=@())
 $script:Busy=$true;Update-QuickQueueControls;$result=$null;$errorText=''
 try{
  if($Mode -eq 'PdfPreview'){$result=Invoke-QaIsolatedTask PreviewPdf ([pscustomobject]@{Config=$script:Config;RecordId=$Plan.RecordId;PageNumber=$Plan.PageNumber}) -TimeoutSeconds 30}
  elseif($Mode -eq 'Reclassify'){$result=Invoke-QaOperation $script:Config -Mode Reclassify -Decisions $Decisions}
  elseif($Mode -eq 'BrowseRefresh'){$result=Invoke-QaBrowseRefresh $script:Config}
  else{throw 'Unexpected review worker mode'}
 }catch{$errorText=$_.Exception.Message}finally{$script:Busy=$false}
 if($Mode -ne 'BrowseRefresh'){[void](Complete-QuickQueueWork -Mode $Mode -Result $result -ErrorText $errorText -Cancelled $false)}
 if($errorText){throw $errorText}
}
# Source the production workspace. Helpers above replace only its host scheduler and dashboard refresh.
. (Join-Path $ProductRoot 'App/ReviewQueueUi.ps1')
Refresh-Dashboard;$script:InitialRecord=$script:Dashboard.Records[0]
$script:Window=Load-Window ([IO.File]::ReadAllText((Join-Path $ProductRoot 'App/MainWindow.xaml')))
$script:Window.Show();$script:Window.Dispatcher.Invoke([Action]{$script:Window.UpdateLayout()},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
$script:Clock=[Diagnostics.Stopwatch]::StartNew();$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[timespan]::FromMilliseconds(200)
$timer.Add_Tick({
 try{
  if($script:Clock.Elapsed.TotalSeconds -gt 60){throw 'The real review workspace did not finish in 60 seconds.'}
  $q=$script:ReviewQueue;if($null -eq $q -or -not $q.Window.IsVisible -or $script:Busy){return}
  switch($script:Stage){
   0 {
    Check ($q.Viewed -and $null -ne $q.Controls.QueuePageImage.Source) 'The actual workspace displays the rendered PDF'
    Check (-not $q.Controls.QueueAccept.IsEnabled) 'Accept stays disabled until the reviewer authorizes the session'
    $q.Controls.QueueReviewer.Text='Synthetic UI reviewer';$q.Controls.QueueAuthorized.IsChecked=$true;Update-QuickQueueControls
    Check $q.Controls.QueueAccept.IsEnabled 'Viewing plus reviewer authorization enables Accept'
    $q.Controls.QueueSkip.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Check ((Test-QaReportPending $script:Dashboard.Records[0]) -and $null -eq $q.Record) 'Skip clears the current session item without changing pending status'
    $q.Controls.QueueSkip.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Check ($null -ne $q.Record -and $q.Viewed) 'Review skipped returns to the PDF with a real preview'
    $script:Stage=1
   }
   1 {
    $q.Checks[0].IsChecked=$true
    $q.Controls.QueueAccept.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Check ($null -eq $q.Record -and -not (Test-QaReportPending $script:Dashboard.Records[0])) 'Clicking Accept advances immediately and removes the item from pending'
    Check ($script:Dashboard.Records[0].ConfirmedComponents.Count -eq 1) 'Only the checked monthly component was saved'
    Check $q.Controls.QueueUndo.IsEnabled 'Undo becomes available after a decision'
    $script:Stage=2
   }
   2 {
    $q.Controls.QueueUndo.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Check ($null -ne $q.Record -and $q.Viewed -and (Test-QaReportPending $script:Dashboard.Records[0])) 'Clicking Undo restores the pending report and PDF preview'
    Submit-QuickQueueDecision -Action Decline -Category Needs_Review
    Check ($null -eq $q.Record -and (Get-QaReportReviewStatus $script:Dashboard.Records[0]) -eq 'Declined') 'Decline clears pending while recording reviewed-other status'
    Check ([IO.File]::Exists($script:Dashboard.Records[0].DestinationPath)) 'The PDF survives Accept, Undo and Decline'
    Check ($script:Dashboard.Reviews.Count -eq 3) 'All three decisions remain in persistent history'
    $script:Stage=3;$q.Window.Close()
   }
  }
 }catch{$script:Failure=$_.Exception.Message+' / '+$_.ScriptStackTrace;$timer.Stop();if($null -ne $script:ReviewQueue){$script:ReviewQueue.Window.Close()}}
})
try{$timer.Start();Open-QuickReviewQueue}catch{$script:Failure=$_.Exception.Message+' / '+$_.ScriptStackTrace}finally{$timer.Stop();$script:Window.Close()}
[pscustomobject]@{Passed=($script:Stage -eq 3 -and -not $script:Failure);Assertions=$script:Assertions;Error=$script:Failure}|ConvertTo-Json -Depth 5|Set-Content $OutputPath -Encoding UTF8
if($script:Failure -or $script:Stage -ne 3){exit 1}
