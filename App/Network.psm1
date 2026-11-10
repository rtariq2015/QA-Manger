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

function Test-QaNetworkAvailability {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$Scanner)
    if ([string]$Scanner.Path -notmatch '^\\\\[^\\]+\\[^\\]+') {
        return (New-QaConnectionResult $Scanner 'Unavailable' 'Enter a network folder beginning with two backslashes, a server and a share.')
    }
    try {
        if ([IO.Directory]::Exists([string]$Scanner.Path)) {
            return (New-QaConnectionResult $Scanner 'Connected' 'Network folder is available. Reports use the direct network path.')
        }
    } catch {
        # Do not expose credential-related exception text to logs or the UI.
    }
    return (New-QaConnectionResult $Scanner 'Unavailable' 'Network folder is unavailable or Windows has not granted access. Reconnect or ask hospital IT to check the share.')
}

function Reconnect-QaScanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$Scanner,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$InWorker
    )
    if(-not $InWorker -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Import-Module (Join-Path $PSScriptRoot 'Process.psm1')
        try{return (Invoke-QaIsolatedTask Reconnect ([pscustomobject]@{Scanner=$Scanner;Credential=$Credential}) -TimeoutSeconds 15)}
        catch{return (New-QaConnectionResult $Scanner 'Unavailable' 'Connection timed out or was blocked. Saved reports remain available; existing sessions were left intact.')}
    }
    $path = [string]$Scanner.Path
    $letter = ([string]$Scanner.DriveLetter).Trim().TrimEnd(':').ToUpperInvariant()
    if ($path -notmatch '^\\\\[^\\]+\\[^\\]+' -or $letter -notmatch '^[A-Z]$' -or $path.IndexOf([char]0) -ge 0) {
        return (New-QaConnectionResult $Scanner 'Unavailable' 'Check the scanner network path and preferred drive letter in Advanced Settings.')
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return (New-QaConnectionResult $Scanner 'Unsupported' 'Network reconnection requires a Windows workstation.')
    }
    $access = Test-QaNetworkAvailability -Scanner $Scanner
    if ($access.Status -eq 'Connected') { return $access }
    try {
        if (-not (Initialize-QaNetworkApi)) {
            return (New-QaConnectionResult $Scanner 'Unsupported' 'Windows network services are unavailable.')
        }
    } catch {
        return (New-QaConnectionResult $Scanner 'Unsupported' 'Hospital Windows policy prevented the network connection component from loading. Ask IT to approve the application; do not bypass the policy.')
    }
    try {
        $assignment = Get-QaDriveAssignment -Letter $letter
    } catch {
        return (New-QaConnectionResult $Scanner 'Unavailable' 'Windows could not safely check the preferred drive letter. No drive mappings were changed.')
    }
    $same = $assignment.Kind -eq 'Network' -and (Get-QaNormalizedNetworkPath $assignment.Path) -eq (Get-QaNormalizedNetworkPath $path)
    if ($assignment.Kind -ne 'Free' -and -not $same) {
        return (New-QaConnectionResult $Scanner 'DriveConflict' ($letter + ': is already assigned or its status could not be safely determined. It was left unchanged. Use the direct network path, choose another free letter, or ask IT.') $assignment.Code)
    }
    $resource = New-Object CtQa.NetworkResource
    $resource.Type = 1
    $resource.RemoteName = $path.TrimEnd('\')
    # If the correct drive already exists, authenticate a temporary deviceless
    # connection instead of disconnecting and recreating that drive.
    if ($assignment.Kind -eq 'Free') { $resource.LocalName = $letter + ':' }
    $passwordPointer = [IntPtr]::Zero
    $username = $null
    $code = -1
    try {
        if ($null -ne $Credential) {
            $username = $Credential.UserName
            $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Credential.Password)
        }
        $code = [CtQa.NativeNetwork]::AddConnection([ref]$resource,$passwordPointer,$username,0)
    } catch {
        return (New-QaConnectionResult $Scanner 'Unavailable' 'Windows could not complete the network connection. No existing mapping was disconnected. Ask IT to check access.')
    } finally {
        if ($passwordPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($passwordPointer)
        }
        $passwordPointer = [IntPtr]::Zero
        $username = $null
        $Credential = $null
    }
    if ($code -eq 0) {
        $check = Test-QaNetworkAvailability -Scanner $Scanner
        if ($check.Status -eq 'Connected') {
            return (New-QaConnectionResult $Scanner 'Connected' 'Connected for this Windows session. No password was saved by CT QA Manager.')
        }
        return (New-QaConnectionResult $Scanner 'Unavailable' 'Windows accepted the connection, but the reports folder is still unavailable. Ask IT to check the folder path and read permissions.' $code)
    }
    switch ($code) {
        1219 { return (New-QaConnectionResult $Scanner 'Unavailable' 'Windows already has a connection to this server with different credentials. No sessions were disconnected. Ask IT to resolve the credential conflict.' $code) }
        5    { return (New-QaConnectionResult $Scanner 'CredentialsRequired' 'Windows denied access. Enter authorized scanner credentials or ask IT to grant read access.' $code) }
        86   { return (New-QaConnectionResult $Scanner 'CredentialsRequired' 'Windows did not accept the network credentials. Enter an authorized account; passwords are never saved by the app.' $code) }
        1326 { return (New-QaConnectionResult $Scanner 'CredentialsRequired' 'Windows did not accept the network credentials. Enter an authorized account; passwords are never saved by the app.' $code) }
        1244 { return (New-QaConnectionResult $Scanner 'CredentialsRequired' 'Windows requires an authorized network sign-in for this share.' $code) }
        85   { return (New-QaConnectionResult $Scanner 'DriveConflict' 'The preferred drive letter became occupied. Windows left it unchanged. Choose another free letter or use the direct network path.' $code) }
        1202 { return (New-QaConnectionResult $Scanner 'DriveConflict' 'Windows has remembered a different mapping for this drive letter. It was not replaced. Ask IT or choose another free letter.' $code) }
        53   { return (New-QaConnectionResult $Scanner 'Unavailable' 'The scanner network location could not be reached. Check the hospital network connection and scanner address.' $code) }
        67   { return (New-QaConnectionResult $Scanner 'Unavailable' 'Windows could not find the configured network share. Check its path with hospital IT.' $code) }
        1231 { return (New-QaConnectionResult $Scanner 'Unavailable' 'The scanner network is unreachable from this workstation. Check its hospital network connection.' $code) }
        default { return (New-QaConnectionResult $Scanner 'Unavailable' ('Windows could not connect (network error ' + $code + '). No existing mappings were disconnected. Ask IT to check access.') $code) }
    }
}

Export-ModuleMember -Function Reconnect-QaScanner,Test-QaNetworkAvailability
