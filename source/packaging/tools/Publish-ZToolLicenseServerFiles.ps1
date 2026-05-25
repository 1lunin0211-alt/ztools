param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$EnvPath = '',
    [string]$RemoteHost = '',
    [string]$RemoteRoot = '',
    [string]$SshKeyPath = '',
    [string]$SshKnownHostsPath = '',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function ConvertTo-RemoteSingleQuoted([string]$Value) {
    "'" + ($Value -replace "'", "'\''") + "'"
}

function Invoke-External([string]$Exe, [string[]]$Arguments) {
    if ($DryRun) {
        [pscustomobject]@{
            DryRun = $true
            Command = $Exe
            Arguments = $Arguments
        }
        return
    }

    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Exe failed with exit code $LASTEXITCODE."
    }
}

function Import-EnvFile([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $envFull = Resolve-FullPath $Path
    if (-not (Test-Path -LiteralPath $envFull -PathType Leaf)) {
        throw "Env file not found: $envFull"
    }

    Get-Content -LiteralPath $envFull | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim().Trim('"')
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

Import-EnvFile $EnvPath

$defaultKnownHosts = 'D:\Development\Rheolab\scripts\deploy\known_hosts'
if ([string]::IsNullOrWhiteSpace($RemoteHost)) {
    $RemoteHost = [Environment]::GetEnvironmentVariable('LICENSE_SERVER_HOST')
}
if (-not [string]::IsNullOrWhiteSpace($RemoteHost) -and $RemoteHost -notmatch '@') {
    $remoteUser = [Environment]::GetEnvironmentVariable('LICENSE_SERVER_USER')
    if (-not [string]::IsNullOrWhiteSpace($remoteUser)) {
        $RemoteHost = "$remoteUser@$RemoteHost"
    }
}
if ([string]::IsNullOrWhiteSpace($SshKeyPath)) {
    $SshKeyPath = [Environment]::GetEnvironmentVariable('LICENSE_SERVER_KEY_PATH')
}
if ([string]::IsNullOrWhiteSpace($SshKnownHostsPath) -and (Test-Path -LiteralPath $defaultKnownHosts -PathType Leaf)) {
    $SshKnownHostsPath = $defaultKnownHosts
}
if ([string]::IsNullOrWhiteSpace($RemoteRoot)) {
    $RemoteRoot = '/var/www/license-server/ztool'
}
if ([string]::IsNullOrWhiteSpace($RemoteHost)) {
    throw 'RemoteHost is required. Pass -RemoteHost or -EnvPath with LICENSE_SERVER_HOST.'
}

$rootFull = Resolve-FullPath $Root
$serverRoot = Join-Path $rootFull '_archive\services\license-server'
if (-not (Test-Path -LiteralPath $serverRoot -PathType Container)) {
    throw "License server source not found: $serverRoot"
}

$files = @(
    'api/activate.php',
    'api/deactivate.php',
    'api/public-key.php',
    'includes/helpers.php',
    'includes/signer.php'
)

$sshArgsBase = @()
$scpArgsBase = @()
$sshArgsBase += @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'ConnectionAttempts=1')
$scpArgsBase += @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'ConnectionAttempts=1')
if (-not [string]::IsNullOrWhiteSpace($SshKeyPath)) {
    $keyFull = Resolve-FullPath $SshKeyPath
    $sshArgsBase += @('-i', $keyFull)
    $scpArgsBase += @('-i', $keyFull)
}
if (-not [string]::IsNullOrWhiteSpace($SshKnownHostsPath)) {
    $knownHostsFull = Resolve-FullPath $SshKnownHostsPath
    if (-not (Test-Path -LiteralPath $knownHostsFull -PathType Leaf)) {
        throw "Known hosts file not found: $knownHostsFull"
    }

    $sshArgsBase += @('-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=$knownHostsFull")
    $scpArgsBase += @('-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=$knownHostsFull")
}

$remoteRootTrimmed = $RemoteRoot.TrimEnd('/')
$published = New-Object System.Collections.Generic.List[object]

foreach ($relative in $files) {
    $local = Join-Path $serverRoot ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $local -PathType Leaf)) {
        throw "Local file not found: $local"
    }

    $remoteFile = $remoteRootTrimmed + '/' + $relative
    $remoteDir = [System.IO.Path]::GetDirectoryName($remoteFile).Replace('\', '/')

    Invoke-External 'ssh' ($sshArgsBase + @($RemoteHost, 'mkdir -p ' + (ConvertTo-RemoteSingleQuoted $remoteDir))) | Out-Null
    Invoke-External 'scp' ($scpArgsBase + @($local, $RemoteHost + ':' + (ConvertTo-RemoteSingleQuoted $remoteFile))) | Out-Null

    $published.Add([pscustomobject]@{
        Local = $local
        Remote = $RemoteHost + ':' + $remoteFile
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $local).Hash.ToUpperInvariant()
    })
}

[pscustomobject]@{
    Status = 'ok'
    RemoteHost = $RemoteHost
    RemoteRoot = $remoteRootTrimmed
    DryRun = [bool]$DryRun
    Files = $published
} | ConvertTo-Json -Depth 5
