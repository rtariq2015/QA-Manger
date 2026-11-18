[CmdletBinding()]param([ValidateSet('Probe','Reconnect','ReadPdf','SourceHash','Inventory','PreviewPdf')][string]$Action,[string]$InputPath,[string]$OutputPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
try {
    $request=Import-Clixml -LiteralPath $InputPath
    switch($Action) {
        'Probe' {$value=[IO.Directory]::Exists([string]$request.Path)}
        'SourceHash' {$value=(Get-FileHash -LiteralPath $request.Path -Algorithm SHA256).Hash}
        'Inventory' {
            Import-Module (Join-Path $PSScriptRoot 'Archive.psm1') -Force
            $value=& (Get-Module Archive) {param($cfg,$state) $summary=New-QaSummary;$inventory=Get-QaInventory $cfg $state $null $summary -InWorker;[pscustomobject]@{Inventory=$inventory;Summary=$summary}} $request.Config $request.State
        }
        'Reconnect' {
            Import-Module (Join-Path $PSScriptRoot 'Network.psm1') -Force
            $reuseAccessible=$false;if($null -ne $request.PSObject.Properties['ReuseAccessible']){$reuseAccessible=[bool]$request.ReuseAccessible}
            $value=Reconnect-QaScanner -Scanner $request.Scanner -Credential $request.Credential -InWorker -ReuseAccessible:$reuseAccessible
        }
        'PreviewPdf' {
            Import-Module (Join-Path $PSScriptRoot 'PdfPreview.psm1') -Force
            $value=Get-QaPdfPreviewPage -Config $request.Config -RecordId $request.RecordId -PageNumber ([int]$request.PageNumber)
        }
        'ReadPdf' {
            Import-Module (Join-Path $PSScriptRoot 'PdfReader.psm1') -Force
            $readArgs=@{Config=$request.Config;RecordId=[string]$request.RecordId}
            if($null -ne $request.PSObject.Properties['Reader']){$readArgs.Reader=[string]$request.Reader}
            $value=Read-QaReportText @readArgs
        }
    }
    [pscustomobject]@{Success=$true;Value=$value;Error=''}|Export-Clixml -LiteralPath $OutputPath -Depth 20 -Encoding UTF8
} catch {
    [pscustomobject]@{Success=$false;Value=$null;Error=$_.Exception.Message}|Export-Clixml -LiteralPath $OutputPath -Depth 4 -Encoding UTF8
    exit 1
}
