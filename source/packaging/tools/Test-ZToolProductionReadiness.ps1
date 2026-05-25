param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$PackageRoot = '',
    [string]$LicenseBaseUrl = 'https://license.vizbuka.ru/ztool',
    [string]$TestLicenseKey = $env:ZTOOL_TEST_KEY,
    [string]$TransferPassword = $env:ZTOOL_TRANSFER_PASSWORD
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-AssemblyPublicConstant([string]$Path, [string]$TypeName, [string]$FieldName) {
    $assembly = [System.Reflection.Assembly]::LoadFile($Path)
    $type = $assembly.GetType($TypeName, $true)
    $field = $type.GetField($FieldName, [System.Reflection.BindingFlags]'Public,Static')
    if ($null -eq $field) {
        throw "Field not found: $TypeName.$FieldName"
    }

    [string]$field.GetRawConstantValue()
}

function Get-RsaPublicKeyMaterial([string]$Xml) {
    $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
    try {
        $rsa.FromXmlString($Xml.Trim())
        $parameters = $rsa.ExportParameters($false)
        [pscustomobject]@{
            Modulus = [Convert]::ToBase64String($parameters.Modulus)
            Exponent = [Convert]::ToBase64String($parameters.Exponent)
        }
    } finally {
        $rsa.Dispose()
    }
}

function Invoke-Check([string]$Name, [scriptblock]$Body) {
    try {
        $result = & $Body
        [pscustomobject]@{
            Name = $Name
            Status = 'ok'
            Result = $result
            Error = ''
        }
    } catch {
        [pscustomobject]@{
            Name = $Name
            Status = 'fail'
            Result = $null
            Error = $_.Exception.Message
        }
    }
}

$rootFull = Resolve-FullPath $Root
$checks = New-Object System.Collections.Generic.List[object]

$checks.Add((Invoke-Check -Name 'license-server-smoke' -Body {
    $args = @{ LicenseBaseUrl = $LicenseBaseUrl }
    if (-not [string]::IsNullOrWhiteSpace($TestLicenseKey)) {
        $args.TestLicenseKey = $TestLicenseKey
    }
    if (-not [string]::IsNullOrWhiteSpace($TransferPassword)) {
        $args.TransferPassword = $TransferPassword
    }

    $result = & (Join-Path $PSScriptRoot 'Test-ZToolLicenseServer.ps1') @args | ConvertFrom-Json
    if ($result.Status -ne 'ok') {
        $messages = @($result.Errors | ForEach-Object { [string]$_ }) -join '; '
        if ([string]::IsNullOrWhiteSpace($messages)) {
            $messages = 'license server smoke returned non-ok status'
        }

        throw $messages
    }

    $result
}))

$checks.Add((Invoke-Check -Name 'runtime-production-requires-public-key' -Body {
    try {
        $output = & (Join-Path $PSScriptRoot 'Build-ZToolProductionRuntime.ps1') 2>&1
        $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
        throw "Build-ZToolProductionRuntime.ps1 succeeded without a production public key. Output: $text"
    } catch {
        $text = $_.Exception.Message
        if ($text -notmatch 'Production runtime requires') {
            throw "Unexpected failure text: $text"
        }
    }

    'blocked-without-public-key'
}))

$checks.Add((Invoke-Check -Name 'runtime-development-build' -Body {
    & (Join-Path $PSScriptRoot 'Build-ZToolProductionRuntime.ps1') -AllowDevelopmentEmptyPublicKey | ConvertFrom-Json
}))

if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
    $packageFull = Resolve-FullPath $PackageRoot
    $checks.Add((Invoke-Check -Name 'package-gate' -Body {
        & (Join-Path $PSScriptRoot 'Test-ZToolLicensedPackage.ps1') -PackageRoot $packageFull | ConvertFrom-Json
    }))

    $checks.Add((Invoke-Check -Name 'package-public-key-server-match' -Body {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        $licensePath = Join-Path $packageFull 'ZTool.License.dll'
        $embeddedXml = Get-AssemblyPublicConstant $licensePath 'ZTool.License.EmbeddedLicenseConfig' 'PublicKeyXml'
        $server = Invoke-RestMethod -Uri ($LicenseBaseUrl.TrimEnd('/') + '/api/public-key.php') -TimeoutSec 20
        if ($null -eq $server -or -not $server.success -or [string]::IsNullOrWhiteSpace([string]$server.publicKeyXml)) {
            throw 'License server did not return a public key.'
        }

        $embedded = Get-RsaPublicKeyMaterial $embeddedXml
        $remote = Get-RsaPublicKeyMaterial ([string]$server.publicKeyXml)
        if ($embedded.Modulus -ne $remote.Modulus -or $embedded.Exponent -ne $remote.Exponent) {
            throw 'ZTool.License.dll embeds a public key that does not match the live license server.'
        }

        'match'
    }))

    $checks.Add((Invoke-Check -Name 'package-no-license-runtime-smoke' -Body {
        & (Join-Path $PSScriptRoot 'Test-ZToolNoLicenseRuntime.ps1') -PackageRoot $packageFull -DemoSeconds 5 | ConvertFrom-Json
    }))

    if (-not [string]::IsNullOrWhiteSpace($TestLicenseKey) -and -not [string]::IsNullOrWhiteSpace($TransferPassword)) {
        $checks.Add((Invoke-Check -Name 'license-package-transfer-workflow' -Body {
            $smokeExe = Join-Path $rootFull 'packaging\obj\ZToolLicenseWorkflowSmoke\ZToolLicenseWorkflowSmoke.exe'
            if (-not (Test-Path -LiteralPath $smokeExe -PathType Leaf)) {
                throw "License workflow smoke executable not found: $smokeExe"
            }

            $output = & $smokeExe $packageFull $TestLicenseKey $TransferPassword 'full' 2>&1
            if ($LASTEXITCODE -ne 0) {
                $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
                throw "License workflow smoke failed with exit code $LASTEXITCODE. $text"
            }

            @($output | ForEach-Object { [string]$_ })
        }))
    }
}

$errors = @($checks | Where-Object Status -eq 'fail')

[pscustomobject]@{
    Status = if ($errors.Count -eq 0) { 'ok' } else { 'fail' }
    Root = $rootFull
    Checks = $checks
} | ConvertTo-Json -Depth 8

if ($errors.Count -gt 0) {
    exit 1
}
