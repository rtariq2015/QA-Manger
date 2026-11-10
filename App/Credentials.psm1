# CT QA Manager Pro - optional sign-ins protected by Windows DPAPI.
# Credentials are encrypted for the current Windows user and computer.
# Never call Export-Clixml for a credential on a non-Windows platform.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Assert-QaCredentialId {
    param([string]$ScannerId)
    if ($ScannerId -notmatch '^[A-Za-z][A-Za-z0-9_]{0,31}$' -or $ScannerId -match '^(All|CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        throw 'Choose a configured scanner connection before saving a sign-in.'
    }
}
function Test-QaCredentialWindows {
    return ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
}
function Assert-QaCredentialNoLink {
    param([string]$Path)
    $current=[IO.Path]::GetFullPath($Path)
    while ($current) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The sign-in folder uses a linked path. Extract the application to a direct local folder.'
            }
        }
        $parent=[IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current=$parent
    }
}
function Get-QaCredentialPath {
    param([string]$AppRoot,[string]$ScannerId)
    Assert-QaCredentialId $ScannerId
    if ([string]::IsNullOrWhiteSpace($AppRoot) -or -not [IO.Path]::IsPathRooted($AppRoot)) { throw 'The application folder must be a full local path.' }
    $root=[IO.Path]::GetFullPath($AppRoot)
    if (Test-QaCredentialWindows) {
        if ($root.StartsWith('\\')) { throw 'Saved sign-ins require an application folder on this workstation, not a network location.' }
        $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($root))
        if ($drive.DriveType -eq [IO.DriveType]::Network) { throw 'Saved sign-ins require a local application folder, not a mapped network drive.' }
    }
    $path=Join-Path (Join-Path (Join-Path $root 'Config') 'Credentials') ($ScannerId+'.xml')
    Assert-QaCredentialNoLink $root
    Assert-QaCredentialNoLink $path
    Assert-QaCredentialNoLink ($path+'.bak')
    return $path
}
function Assert-QaCredentialConfigured {
    param([string]$AppRoot,[string]$ScannerId)
    if (-not (Get-Command Read-QaConfig -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'Archive.psm1') -ErrorAction Stop
    }
    $config=Read-QaConfig -AppRoot $AppRoot
    if (@($config.Sources | Where-Object { $_.Scanner -eq $ScannerId }).Count -ne 1) {
        throw 'Save this scanner in Scanner Connections before saving its sign-in.'
    }
    return @($config.Sources | Where-Object { $_.Scanner -eq $ScannerId })[0]
}
function Get-QaSavedCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$AppRoot,
        [Parameter(Mandatory=$true)][string]$ScannerId,
        [AllowEmptyString()][string]$ExpectedUsername,
        [AllowEmptyString()][string]$ExpectedPath
    )
    Assert-QaCredentialId $ScannerId
    if (-not (Test-QaCredentialWindows)) { return $null }
    $path=Get-QaCredentialPath $AppRoot $ScannerId
    $source=Assert-QaCredentialConfigured $AppRoot $ScannerId
    if (-not [IO.File]::Exists($path)) { return $null }
    try {
        $saved=Import-Clixml -LiteralPath $path -ErrorAction Stop
        if ($null -eq $saved.PSObject.Properties['Version'] -or [int]$saved.Version -ne 1 -or $saved.ScannerId -ne $ScannerId) { throw 'Invalid or older saved sign-in.' }
        $currentPath=([string]$source.Path).TrimEnd('\')
        $currentUsername=[string]$source.Username
        if ($PSBoundParameters.ContainsKey('ExpectedPath') -and -not $currentPath.Equals($ExpectedPath.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { return $null }
        # A connection edit cannot silently forward a previous server's credential.
        if (-not ([string]$saved.SourcePath).TrimEnd('\').Equals($currentPath,[StringComparison]::OrdinalIgnoreCase) -or -not ([string]$saved.Username).Equals($currentUsername,[StringComparison]::OrdinalIgnoreCase)) { return $null }
        $credential=$saved.Credential
        if ($credential -isnot [Management.Automation.PSCredential] -or $credential.Password.Length -eq 0) { throw 'Invalid saved sign-in.' }
        if ($PSBoundParameters.ContainsKey('ExpectedUsername') -and -not $credential.UserName.Equals($ExpectedUsername,[StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        return $credential
    } catch {
        throw 'This saved sign-in cannot be read by the current Windows account. Enter and save the scanner username and password again on this workstation.'
    }
}
function Get-QaCredentialStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$AppRoot,
        [Parameter(Mandatory=$true)][string]$ScannerId,
        [AllowEmptyString()][string]$ExpectedUsername,
        [AllowEmptyString()][string]$ExpectedPath
    )
    Assert-QaCredentialId $ScannerId
    if (-not (Test-QaCredentialWindows)) {
        return [pscustomobject]@{Saved=$false;Stored=$false;Username='';Message='Saved sign-ins are available only on Windows. No password has been stored.'}
    }
    $stored=$false
    try {
        $path=Get-QaCredentialPath $AppRoot $ScannerId
        [void](Assert-QaCredentialConfigured $AppRoot $ScannerId)
        $stored=[IO.File]::Exists($path)
        $credentialArgs=@{AppRoot=$AppRoot;ScannerId=$ScannerId}
        if ($PSBoundParameters.ContainsKey('ExpectedUsername')) { $credentialArgs.ExpectedUsername=$ExpectedUsername }
        if ($PSBoundParameters.ContainsKey('ExpectedPath')) { $credentialArgs.ExpectedPath=$ExpectedPath }
        $credential=Get-QaSavedCredential @credentialArgs
        if ($null -eq $credential) {
            return [pscustomobject]@{Saved=$false;Stored=$stored;Username='';Message=$(if($stored){'A saved sign-in belongs to earlier connection details. Enter the current password or choose Forget saved sign-in.'}else{'No saved sign-in for this connection. Windows access or the secure prompt will be used.'})}
        }
        return [pscustomobject]@{Saved=$true;Stored=$stored;Username=$credential.UserName;Message='Sign-in encrypted for this Windows user and workstation.'}
    } catch {
        return [pscustomobject]@{Saved=$false;Stored=$stored;Username='';Message=$_.Exception.Message}
    }
}
function Save-QaSavedCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$AppRoot,
        [Parameter(Mandatory=$true)][string]$ScannerId,
        [Parameter(Mandatory=$true)][Management.Automation.PSCredential]$Credential,
        [AllowEmptyString()][string]$ExpectedPath
    )
    Assert-QaCredentialId $ScannerId
    # PowerShell on Linux serializes SecureString reversibly instead of DPAPI.
    # Refuse before making a folder, temporary file, or credential file.
    if (-not (Test-QaCredentialWindows)) { throw 'Saving a scanner sign-in requires Windows DPAPI. No credential file was written.' }
    if ([string]::IsNullOrWhiteSpace($Credential.UserName) -or $Credential.UserName.Length -gt 256 -or $Credential.UserName -match '[\x00-\x1f]' -or $Credential.Password.Length -eq 0) {
        throw 'Enter an authorized scanner username and password before saving the sign-in.'
    }
    $path=Get-QaCredentialPath $AppRoot $ScannerId
    $source=Assert-QaCredentialConfigured $AppRoot $ScannerId
    if ($PSBoundParameters.ContainsKey('ExpectedPath') -and -not ([string]$source.Path).TrimEnd('\').Equals($ExpectedPath.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'The scanner connection changed while saving. Check the address and enter the password again.' }
    if (-not $Credential.UserName.Equals([string]$source.Username,[StringComparison]::OrdinalIgnoreCase)) { throw 'The sign-in username must match the saved scanner connection. Save the connection username first.' }
    $parent=[IO.Path]::GetDirectoryName($path)
    $temp=Join-Path $parent ('.'+$ScannerId+'-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $backup=$path+'.bak'
    try {
        Assert-QaCredentialNoLink $parent
        [void][IO.Directory]::CreateDirectory($parent)
        Assert-QaCredentialNoLink $temp
        # Windows PowerShell encrypts the SecureString using the current user's DPAPI.
        $envelope=[pscustomobject]@{Version=1;ScannerId=$ScannerId;SourcePath=[string]$source.Path;Username=$Credential.UserName;Credential=$Credential}
        Export-Clixml -InputObject $envelope -LiteralPath $temp -Depth 4 -Encoding UTF8 -ErrorAction Stop
        $probe=Import-Clixml -LiteralPath $temp -ErrorAction Stop
        if ($probe.Credential -isnot [Management.Automation.PSCredential] -or $probe.Credential.UserName -ne $Credential.UserName -or $probe.Credential.Password.Length -ne $Credential.Password.Length -or [string]$probe.SourcePath -ne [string]$source.Path -or $probe.ScannerId -ne $ScannerId) {
            throw 'The encrypted sign-in could not be verified.'
        }
        Assert-QaCredentialNoLink $path
        Assert-QaCredentialNoLink $backup
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp,$path,$backup) }
        else { [IO.File]::Move($temp,$path) }
        # Old credentials are not retained as a normal backup. Only our own generated
        # encrypted replacement backup can be present after File.Replace succeeds.
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    } catch {
        throw 'The encrypted scanner sign-in could not be saved. Check that the application folder is writable and ask hospital IT if the policy blocks encrypted credentials.'
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        $probe=$null
    }
    return [pscustomobject]@{Saved=$true;Stored=$true;Username=$Credential.UserName;Message='Sign-in saved securely for this Windows user and workstation. Existing Windows connections were left unchanged.'}
}
function Remove-QaSavedCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$AppRoot,[Parameter(Mandatory=$true)][string]$ScannerId)
    Assert-QaCredentialId $ScannerId
    if (-not (Test-QaCredentialWindows)) { throw 'Changing saved sign-ins requires Windows. No credential file was changed.' }
    $path=Get-QaCredentialPath $AppRoot $ScannerId
    [void](Assert-QaCredentialConfigured $AppRoot $ScannerId)
    if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    if ([IO.File]::Exists($path+'.bak')) { [IO.File]::Delete($path+'.bak') }
    return [pscustomobject]@{Saved=$false;Stored=$false;Username='';Message='The saved sign-in was removed. Existing Windows connections were left unchanged.'}
}
Export-ModuleMember -Function Get-QaSavedCredential,Save-QaSavedCredential,Remove-QaSavedCredential,Get-QaCredentialStatus
