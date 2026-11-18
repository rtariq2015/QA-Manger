[CmdletBinding()]param([string]$OutputPath='')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'App/Network.psm1') -Force -DisableNameChecking
$module=Get-Module Network
$checks=New-Object 'System.Collections.Generic.List[object]'
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw $Name};[void]$checks.Add([pscustomobject]@{Name=$Name;Result='PASS'})}
$scanner=[pscustomobject]@{Scanner='Synthetic';Name='Synthetic scanner';Path='\\SYNTHETIC-SCANNER\QA-Share\Reports';DriveLetter='K';Username='SyntheticUser'}
$before=$scanner|ConvertTo-Json -Compress
# An empty SecureString is only a typed synthetic input. No network call uses it.
$credential=New-Object Management.Automation.PSCredential('SyntheticUser',(New-Object Security.SecureString))
& $module {
    function script:Initialize-QaNetworkApi {$script:ApiCalls++;return $true}
    function script:Invoke-QaNativeConnection {param($RemoteName,$LocalName='',$Credential) $script:NativeCalls++;return $script:NativeCode}
    function script:Get-QaDriveAssignment {param($Letter) $script:MappingChecks++;return [pscustomobject]@{Kind='Occupied';Path='Synthetic occupied drive';Code=0}}
    function script:Test-QaNetworkAvailability {
        param($Scanner)
        $status=$script:AccessStatuses[[Math]::Min($script:AccessCalls,$script:AccessStatuses.Count-1)];$script:AccessCalls++
        return New-QaConnectionResult $Scanner $status ('Synthetic '+$status) $(if($status -eq 'Connected'){0}else{5})
    }
}
function RunCase([string[]]$Statuses,[bool]$Reuse,[object]$CredentialValue,[int]$NativeCode=0){
    & $module {
        param($source,$credential,$statuses,$reuse,$nativeCode)
        $script:AccessStatuses=$statuses;$script:AccessCalls=0;$script:NativeCalls=0;$script:ApiCalls=0;$script:MappingChecks=0;$script:NativeCode=$nativeCode
        $value=Invoke-QaReconnectCore -Scanner $source -Credential $credential -ReuseAccessible:$reuse
        return [pscustomobject]@{Value=$value;Access=$script:AccessCalls;Native=$script:NativeCalls;Api=$script:ApiCalls;Mapping=$script:MappingChecks}
    } $scanner $CredentialValue $Statuses $Reuse $NativeCode
}
$r=RunCase @('Connected') $true $credential
Check ($r.Value.Status -eq 'Connected') 'Refresh accepts currently accessible read/list access.'
Check ($r.Access -eq 1) 'Refresh verifies access once before reusing it.'
Check ($r.Native -eq 0 -and $r.Api -eq 0 -and $r.Mapping -eq 0) 'Healthy reuse avoids native authentication and mapping operations.'
$r=RunCase @('Connected') $false $credential
Check ($r.Native -eq 1 -and $r.Api -eq 1) 'Explicit supplied credentials still authenticate instead of reusing another session.'
Check ($r.Value.Status -eq 'Connected' -and $r.Access -eq 1) 'Explicit sign-in retains the post-authentication access check.'
Check ($r.Mapping -eq 1) 'Explicit sign-in retains the existing occupied-drive check.'
$r=RunCase @('Unavailable','Connected') $true $credential
Check ($r.Value.Status -eq 'Connected' -and $r.Access -eq 2) 'Unavailable access falls back to authentication then verifies access again.'
Check ($r.Native -eq 1 -and $r.Api -eq 1) 'Fallback performs the existing native authentication.'
$r=RunCase @('Unavailable') $true $credential 86
Check ($r.Native -eq 1 -and $r.Value.NativeCode -eq 86 -and $r.Value.Status -ne 'Connected') 'Rejected fallback credentials remain a failed connection with the original Windows code.'
$r=RunCase @('Connected') $false $null
Check ($r.Value.Status -eq 'Connected' -and $r.Native -eq 0) 'Existing no-credential access reuse is preserved.'
Check (($scanner|ConvertTo-Json -Compress) -ceq $before) 'The source folder, scanner settings and drive preference are unchanged.'
$network=[IO.File]::ReadAllText((Join-Path $root 'App/Network.psm1'))
$worker=[IO.File]::ReadAllText((Join-Path $root 'App/TaskWorker.ps1'))
$service=[IO.File]::ReadAllText((Join-Path $root 'App/WebService.psm1'))
Check ($network.Contains('ReuseAccessible=[bool]$ReuseAccessible}) -TimeoutSeconds 30')) 'Reuse remains inside the existing isolated 30-second reconnect deadline.'
Check ($worker.Contains('$reuseAccessible=$false;if($null -ne $request.PSObject.Properties[''ReuseAccessible''])')) 'Older worker inputs without the optional flag default to explicit reconnect behavior.'
Check ($worker.Contains('-InWorker -ReuseAccessible:$reuseAccessible')) 'The private worker forwards the optional reuse flag.'
Check ($service.Contains('[void](Reconnect-QaScanner $source $credential -ReuseAccessible)')) 'The report-refresh preconnection opts into verified access reuse.'
Check (-not $service.Contains('Reconnect-QaScanner $source $credential -ReuseAccessible;')) 'The explicit sign-in route is not accidentally replaced by the refresh call.'
foreach($name in @('App/Network.psm1','App/TaskWorker.ps1','App/WebService.psm1')){
    $tokens=$null;$parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name),[ref]$tokens,[ref]$parseErrors)
    Check ($parseErrors.Count -eq 0) ($name+' parses successfully in the executed PowerShell runtime.')
}
$hashes=[ordered]@{}
foreach($name in @('App/Network.psm1','App/TaskWorker.ps1','App/WebService.psm1')){$hashes[$name]=(Get-FileHash (Join-Path $root $name) -Algorithm SHA256).Hash.ToLowerInvariant()}
$result=[pscustomobject]@{Status='PASS';Assertions=$checks.Count;Runtime=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.Platform.ToString();SyntheticOnly=$true;Scope='Focused Linux PowerShell module-mock checks and parser validation only. Availability, native authentication and drive checks are synthetic function replacements; no live scanner/SMB, Windows DPAPI, Windows PowerShell 5.1 execution, hospital workstation or actual timeout validation.';Checks=@($checks.ToArray());TestedFiles=$hashes}
if($OutputPath){$parent=Split-Path -Parent $OutputPath;if($parent){[void][IO.Directory]::CreateDirectory($parent)};$result|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
Write-Host ('PASS focused network reuse: '+$checks.Count+' checks; '+$PSVersionTable.PSVersion+' '+[Environment]::OSVersion.Platform)
