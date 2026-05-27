param(
    [string]$LicenseBaseUrl = 'https://license.vizbuka.ru/ztool',
    [string]$OutputPath = (Join-Path (Get-Location) 'license_public.xml'),
    [string]$EnvPath = '',
    [string]$RemoteHost = '',
    [string]$RemoteRoot = '',
    [string]$SshKeyPath = '',
    [string]$SshKnownHostsPath = '',
    [switch]$Force
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

function Normalize-PublicKeyXml([string]$Content) {
    $trimmed = $Content.Trim()
    if ($trimmed.StartsWith('<RSAKeyValue', [System.StringComparison]::Ordinal)) {
        return $trimmed
    }

    $json = $trimmed | ConvertFrom-Json
    return ([string]$json.publicKeyXml).Trim()
}

function Assert-RsaPublicKeyXml([string]$Xml) {
    $trimmed = $Xml.Trim()
    if (-not $trimmed.StartsWith('<RSAKeyValue', [System.StringComparison]::Ordinal) -or
        -not $trimmed.EndsWith('</RSAKeyValue>', [System.StringComparison]::Ordinal)) {
        throw 'Exported public key must be raw RSAKeyValue XML, not a JSON wrapper.'
    }

    try {
        $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
        try {
            $rsa.FromXmlString($trimmed)
        } finally {
            $rsa.Dispose()
        }
    } catch {
        throw "Exported public key is not loadable RSA XML: $($_.Exception.Message)"
    }

    $trimmed
}

function Get-PublicKeyXmlFromHttp([string]$BaseUrl) {
    $uri = $BaseUrl.TrimEnd('/') + '/api/public-key.php'
    $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 20 -SkipHttpErrorCheck
    if ([int]$response.StatusCode -ne 200) {
        throw "HTTP public key endpoint returned $($response.StatusCode)."
    }

    Normalize-PublicKeyXml ([string]$response.Content)
}

function Get-PublicKeyXmlFromSsh([string]$HostName, [string]$RootPath, [string]$KeyPath) {
    if ([string]::IsNullOrWhiteSpace($HostName) -or [string]::IsNullOrWhiteSpace($RootPath)) {
        throw 'RemoteHost and RemoteRoot are required for SSH fallback.'
    }

    $sshArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
        $sshArgs += @('-i', (Resolve-FullPath $KeyPath))
    }
    $sshArgs += @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'ConnectionAttempts=1')
    if (-not [string]::IsNullOrWhiteSpace($SshKnownHostsPath)) {
        $knownHostsFull = Resolve-FullPath $SshKnownHostsPath
        if (-not (Test-Path -LiteralPath $knownHostsFull -PathType Leaf)) {
            throw "Known hosts file not found: $knownHostsFull"
        }

        $sshArgs += @('-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=$knownHostsFull")
    }

    $command = 'cd ' + (ConvertTo-RemoteSingleQuoted $RootPath.TrimEnd('/')) + ' && php tools/export_public_key_xml.php'
    $output = & ssh @sshArgs $HostName $command
    if ($LASTEXITCODE -ne 0) {
        throw "ssh export failed with exit code $LASTEXITCODE."
    }

    ($output | ForEach-Object { [string]$_ }) -join "`n"
}

$outFull = Resolve-FullPath $OutputPath
if ((Test-Path -LiteralPath $outFull -PathType Leaf) -and -not $Force) {
    throw "Output file already exists: $outFull. Pass -Force to replace it."
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

$source = 'http'
try {
    $xml = Get-PublicKeyXmlFromHttp $LicenseBaseUrl
} catch {
    if ([string]::IsNullOrWhiteSpace($RemoteHost) -or [string]::IsNullOrWhiteSpace($RemoteRoot)) {
        throw "Cannot fetch public key from HTTP endpoint and no SSH fallback was provided. HTTP error: $($_.Exception.Message)"
    }

    $source = 'ssh'
    $xml = Get-PublicKeyXmlFromSsh $RemoteHost $RemoteRoot $SshKeyPath
}

$xml = Assert-RsaPublicKeyXml $xml

New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($outFull)) | Out-Null
Set-Content -LiteralPath $outFull -Value $xml -Encoding UTF8

[pscustomobject]@{
    Status = 'ok'
    Source = $source
    OutputPath = $outFull
    Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $outFull).Hash.ToUpperInvariant()
} | ConvertTo-Json -Depth 4
