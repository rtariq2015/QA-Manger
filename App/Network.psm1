# CT QA Manager Pro - temporary Windows network connections.
# Windows PowerShell 5.1. This module never cancels or replaces a mapping.
Set-StrictMode -Version 2.0

function New-QaConnectionResult {
    param([object]$Scanner,[string]$Status,[string]$Message,[int]$NativeCode = 0)
    [pscustomobject]@{
        Scanner = [string]$Scanner.Scanner
        Status = $Status
        Message = $Message
        DriveLetter = [string]$Scanner.DriveLetter
        NativeCode = $NativeCode
    }
}

function Initialize-QaNetworkApi {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return $false
    }
    if ($null -eq ('CtQa.NativeNetwork' -as [type])) {
        # SecureString is marshaled into a zeroed unmanaged buffer, never a managed
        # password string or a process command line. Flags are always zero: no
        # CONNECT_UPDATE_PROFILE, CONNECT_INTERACTIVE or credential persistence.
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace CtQa {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NetworkResource {
        public int Scope;
        public int Type;
        public int DisplayType;
        public int Usage;
        public string LocalName;
        public string RemoteName;
        public string Comment;
        public string Provider;
    }
    public static class NativeNetwork {
        [DllImport("mpr.dll", EntryPoint = "WNetGetConnectionW", CharSet = CharSet.Unicode)]
        public static extern int GetConnection(string localName, StringBuilder remoteName, ref int length);
        [DllImport("mpr.dll", EntryPoint = "WNetAddConnection2W", CharSet = CharSet.Unicode)]
        public static extern int AddConnection(ref NetworkResource resource, IntPtr password, string username, int flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint GetLogicalDrives();
    }
}
'@ -ErrorAction Stop | Out-Null
    }
    return $true
}

function Get-QaNormalizedNetworkPath {
    param([string]$Path)
    return $Path.TrimEnd('\').ToUpperInvariant()
}

function Get-QaDriveAssignment {
    param([string]$Letter)
    $localName = $Letter + ':'
    $capacity = 1024
    $buffer = New-Object System.Text.StringBuilder $capacity
    $code = [CtQa.NativeNetwork]::GetConnection($localName,$buffer,[ref]$capacity)
    if ($code -eq 234) {
        $buffer = New-Object System.Text.StringBuilder $capacity
        $code = [CtQa.NativeNetwork]::GetConnection($localName,$buffer,[ref]$capacity)
    }
    if (($code -eq 0 -or $code -eq 1201) -and $buffer.Length -gt 0) {
        return [pscustomobject]@{ Kind='Network'; Path=$buffer.ToString(); Code=$code }
    }
    if ($code -ne 2250 -and $code -ne 1200) {
        # Unknown assignment state is treated as occupied rather than risking it.
        return [pscustomobject]@{ Kind='Unknown'; Path=''; Code=$code }
    }
    $drive = Get-PSDrive -Name $Letter -ErrorAction SilentlyContinue
    if ($null -ne $drive) {
        $root = [string]$drive.Root
        if ($null -ne $drive.PSObject.Properties['DisplayRoot'] -and $drive.DisplayRoot) {
            $root = [string]$drive.DisplayRoot
        }
        return [pscustomobject]@{ Kind='Occupied'; Path=$root; Code=$code }
    }
    $mask = [CtQa.NativeNetwork]::GetLogicalDrives()
    if ($mask -eq 0) {
        return [pscustomobject]@{ Kind='Unknown'; Path=''; Code=[Runtime.InteropServices.Marshal]::GetLastWin32Error() }
    }
    $bit = [uint32]1 -shl ([int][char]$Letter - [int][char]'A')
    if (($mask -band $bit) -ne 0) {
        return [pscustomobject]@{ Kind='Occupied'; Path=''; Code=$code }
    }
    return [pscustomobject]@{ Kind='Free'; Path=''; Code=$code }
}

function Get-QaNetworkLocation {
    [CmdletBinding()]param([string]$Path)
    $value=$Path.Trim().TrimEnd('\')
    if(-not $value.StartsWith('\\') -or [regex]::IsMatch($value,'[\x00-\x1f]')){throw 'Enter a UNC reports folder: \\SERVER\Share\Folder.'}
    $parts=$value.Substring(2).Split([char]'\')
    if($parts.Count -lt 2 -or -not $parts[0] -or -not $parts[1]){throw 'Enter both the server and share name.'}
    foreach($part in $parts){if(-not $part -or $part -in @('.','..') -or $part.IndexOfAny([char[]]'/:*?"<>|') -ge 0){throw 'The network folder contains unsupported path characters.'}}
    return [pscustomobject]@{Path=$value;Host=$parts[0];ShareRoot=('\\'+$parts[0]+'\'+$parts[1])}
}
function Test-QaPlaceholderConnection {
    param($Scanner)
    try{$location=Get-QaNetworkLocation ([string]$Scanner.Path)}catch{return $false}
    return ($location.Host -in @('CT-EDGE','CT-FLASH','MDP-SCANNER') -and $location.ShareRoot.EndsWith('\Reports',[StringComparison]::OrdinalIgnoreCase))
}
function Get-QaNetworkFailure {
    param($Scanner,[int]$Code,[switch]$AfterAuthentication)
    $message=switch($Code) {
        3 {'The reports subfolder was not found. Check the full folder path in Advanced settings.'}
        5 {'Windows denied access. Enter the authorized scanner sign-in, or ask IT to grant read/list access to the reports folder.'}
        53 {'The server could not be reached. Check this workstation network connection and the server address.'}
        67 {'The network share was not found. Check the share name and reports subfolder.'}
        86 {'Windows did not accept the scanner username or password.'}
        1326 {'Windows did not accept the scanner username or password.'}
        1219 {'Windows already has a session to this server using different credentials. No session was disconnected; ask IT to resolve the conflict.'}
        1244 {'Windows requires an authorized scanner sign-in.'}
        1231 {'The scanner network is unreachable from this workstation.'}
        64 {'The network connection was interrupted. Try again when the scanner is available.'}
        default {'The reports folder is unavailable. Check the saved path, workstation network access, and folder permissions.'}
    }
    $status=if(-not $AfterAuthentication -and $Code -in @(5,86,1326,1244)){'CredentialsRequired'}else{'Unavailable'}
    if($AfterAuthentication -and $Code -eq 5){$message='Windows accepted the server connection, but denied access to the reports folder. Ask IT to check folder read/list permissions.'}
    if($Code -gt 0){$message+=' Windows error '+$Code+'.'}
    return (New-QaConnectionResult $Scanner $status $message $Code)
}
function Test-QaNetworkAvailability {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][object]$Scanner)
    if(Test-QaPlaceholderConnection $Scanner){return (New-QaConnectionResult $Scanner 'NotConfigured' 'Example connection settings are still selected. Apply your local connection profile or enter the real scanner folder in Advanced settings.')}
    try{$location=Get-QaNetworkLocation ([string]$Scanner.Path)}catch{return (New-QaConnectionResult $Scanner 'NotConfigured' $_.Exception.Message)}
    $iterator=$null
    try {
        # Enumerating one entry checks read/list access, including an empty reports folder.
        # Directory.Exists alone hides permission errors by returning false.
        $iterator=[IO.Directory]::EnumerateFileSystemEntries($location.Path).GetEnumerator()
        [void]$iterator.MoveNext()
        return (New-QaConnectionResult $Scanner 'Connected' 'Reports folder is accessible using the direct UNC path. Existing Windows connections were left unchanged.')
    } catch {
        $exception=$_.Exception
        while($null -ne $exception.InnerException){$exception=$exception.InnerException}
        $code=[int]($exception.HResult -band 65535)
        if($exception -is [UnauthorizedAccessException]){$code=5}
        return (Get-QaNetworkFailure $Scanner $code)
    } finally {if($iterator -is [IDisposable]){$iterator.Dispose()}}
}
function Invoke-QaNativeConnection {
    param([string]$RemoteName,[string]$LocalName='',[System.Management.Automation.PSCredential]$Credential)
    $resource=New-Object CtQa.NetworkResource;$resource.Type=1;$resource.RemoteName=$RemoteName
    if($LocalName){$resource.LocalName=$LocalName}
    $passwordPointer=[IntPtr]::Zero;$username=$null
    try {
        if($null -ne $Credential){$username=$Credential.UserName;$passwordPointer=[Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Credential.Password)}
        return [CtQa.NativeNetwork]::AddConnection([ref]$resource,$passwordPointer,$username,0)
    } finally {
        if($passwordPointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($passwordPointer)}
        $passwordPointer=[IntPtr]::Zero;$username=$null;$Credential=$null
    }
}
function Reconnect-QaScanner {
    [CmdletBinding()]param(
        [Parameter(Mandatory=$true)][object]$Scanner,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$InWorker,
        [switch]$ReuseAccessible
    )
    if(Test-QaPlaceholderConnection $Scanner){return (New-QaConnectionResult $Scanner 'NotConfigured' 'Example connection settings are still selected. Apply your local connection profile or enter the real scanner folder in Advanced settings.')}
    try{$location=Get-QaNetworkLocation ([string]$Scanner.Path)}catch{return (New-QaConnectionResult $Scanner 'NotConfigured' $_.Exception.Message)}
    $letter=([string]$Scanner.DriveLetter).Trim().TrimEnd(':').ToUpperInvariant()
    if($letter -notmatch '^[A-Z]$'){return (New-QaConnectionResult $Scanner 'NotConfigured' 'Check the preferred drive letter in Advanced settings.')}
    if(-not $InWorker -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Import-Module (Join-Path $PSScriptRoot 'Process.psm1')
        try{return (Invoke-QaIsolatedTask Reconnect ([pscustomobject]@{Scanner=$Scanner;Credential=$Credential;ReuseAccessible=[bool]$ReuseAccessible}) -TimeoutSeconds 30)}
        catch{return (New-QaConnectionResult $Scanner 'Unavailable' 'Connection attempt timed out or the helper was blocked by workstation policy. Check the server address, network access, and IT policy. Saved reports remain available.')}
    }
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){return (New-QaConnectionResult $Scanner 'Unsupported' 'Network reconnection requires Windows.')}
    return (Invoke-QaReconnectCore -Scanner $Scanner -Credential $Credential -ReuseAccessible:$ReuseAccessible)
}
function Invoke-QaReconnectCore {
    param($Scanner,[System.Management.Automation.PSCredential]$Credential,[switch]$ReuseAccessible)
    $location=Get-QaNetworkLocation ([string]$Scanner.Path)
    $letter=([string]$Scanner.DriveLetter).Trim().TrimEnd(':').ToUpperInvariant()
    # Refresh can reuse currently verified read/list access. Explicit sign-in still
    # authenticates the supplied credentials, even if another session is accessible.
    if($ReuseAccessible -or $null -eq $Credential){$access=Test-QaNetworkAvailability $Scanner;if($access.Status -eq 'Connected' -or $access.Status -eq 'NotConfigured'){return $access}}
    try{if(-not (Initialize-QaNetworkApi)){throw 'Native network services unavailable.'}}catch{return (New-QaConnectionResult $Scanner 'Unsupported' 'Workstation policy prevented the Windows network component from loading. Ask IT to approve the application.')}
    try {
        # Authenticate to the SMB share root first. The scanner source still points
        # to the complete reports folder; no file or archive path is changed here.
        $code=Invoke-QaNativeConnection -RemoteName $location.ShareRoot -Credential $Credential
        if($code -ne 0){
            if($code -eq 1219){$existing=Test-QaNetworkAvailability $Scanner;if($existing.Status -eq 'Connected'){return $existing}}
            return (Get-QaNetworkFailure $Scanner $code)
        }
        $check=Test-QaNetworkAvailability $Scanner
        if($check.Status -ne 'Connected'){return (Get-QaNetworkFailure $Scanner ([int]$check.NativeCode) -AfterAuthentication)}
        $mappingNote='Reports use the direct UNC path.'
        try {
            $assignment=Get-QaDriveAssignment $letter
            if($assignment.Kind -eq 'Free') {
                $mapCode=Invoke-QaNativeConnection -RemoteName $location.Path -LocalName ($letter+':') -Credential $Credential
                $mappingNote=if($mapCode -eq 0){$letter+': connected for this Windows session.'}else{'The folder is accessible directly; the optional drive mapping was not created (Windows error '+$mapCode+').'}
            } else {$mappingNote=$letter+': was left unchanged; reports use the direct UNC path.'}
        }catch{$mappingNote='The folder is accessible directly. Drive mappings were left unchanged.'}
        return (New-QaConnectionResult $Scanner 'Connected' ('Reports folder is accessible. '+$mappingNote))
    }catch{return (New-QaConnectionResult $Scanner 'Unavailable' 'Windows could not complete the scanner connection. Existing mappings were left unchanged. Ask IT to check access.')}
}
Export-ModuleMember -Function Reconnect-QaScanner,Test-QaNetworkAvailability,Get-QaNetworkLocation,Test-QaPlaceholderConnection
