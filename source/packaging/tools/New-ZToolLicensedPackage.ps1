param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$BinaryRoot,
    [string]$AssetsRoot,
    [string]$OutputRoot,
    [string]$LicenseBaseUrl = 'https://license.vizbuka.ru/ztool',
    [string]$PublicKeyXmlPath = '',
    [string]$PublicKeyXml = '',
    [string]$PayloadKey = 'change-me-in-config-php',
    [int]$OfflineGraceDays = 7,
    [switch]$Package,
    [switch]$Production,
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

function Get-MSBuildPath {
    $candidates = @(
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe',
        'C:\Windows\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw 'MSBuild.exe was not found.'
}

function Get-CscPath {
    $candidates = @(
        'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe',
        'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw 'csc.exe was not found.'
}

function Invoke-CompileExe(
    [string]$OutputPath,
    [string[]]$Sources,
    [string[]]$References,
    [string[]]$Defines = @()
) {
    $csc = Get-CscPath
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($OutputPath)) | Out-Null

    $args = @('/nologo', '/target:winexe', '/optimize+', "/out:$OutputPath")
    if ($Defines.Count -gt 0) {
        $args += "/define:$($Defines -join ';')"
    }
    foreach ($reference in $References) {
        $args += "/reference:$reference"
    }
    $args += $Sources

    & $csc @args
    if ($LASTEXITCODE -ne 0) {
        throw "C# compilation failed: $OutputPath"
    }
}

function ConvertTo-CSharpLiteral([string]$Value) {
    if ($null -eq $Value) {
        $Value = ''
    }

    return '@"' + ($Value -replace '"', '""') + '"'
}

function Protect-Payload([string]$InputPath, [string]$OutputPath, [string]$KeyMaterial) {
    $plain = [System.IO.File]::ReadAllBytes($InputPath)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $key = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($KeyMaterial))
    } finally {
        $sha.Dispose()
    }

    $aes = New-Object System.Security.Cryptography.RijndaelManaged
    try {
        $aes.KeySize = 256
        $aes.BlockSize = 128
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $key

        $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
        try {
            $iv = New-Object byte[] 16
            $rng.GetBytes($iv)
        } finally {
            $rng.Dispose()
        }

        $aes.IV = $iv
        $encryptor = $aes.CreateEncryptor()
        try {
            $cipher = $encryptor.TransformFinalBlock($plain, 0, $plain.Length)
        } finally {
            $encryptor.Dispose()
        }

        $stream = New-Object System.IO.MemoryStream
        try {
            $stream.Write($iv, 0, $iv.Length)
            $stream.Write($cipher, 0, $cipher.Length)
            [System.IO.File]::WriteAllBytes($OutputPath, $stream.ToArray())
        } finally {
            $stream.Dispose()
        }
    } finally {
        $aes.Dispose()
    }
}

function Assert-UnderRoot([string]$Candidate, [string]$AllowedRoot) {
    $candidateFull = Resolve-FullPath $Candidate
    $rootFull = (Resolve-FullPath $AllowedRoot).TrimEnd('\') + '\'
    if (-not $candidateFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify path outside root: $candidateFull"
    }
}

function Copy-DirectoryContents([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Directory not found: $Source"
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-FileSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Test-StrongNameSignature([string]$Path) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ZToolStrongNameNative {
  [DllImport("mscoree.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool StrongNameSignatureVerificationEx(string wszFilePath, bool fForceVerification, ref bool pfWasVerified);
}
'@ -ErrorAction SilentlyContinue

    $wasVerified = $false
    $ok = [ZToolStrongNameNative]::StrongNameSignatureVerificationEx($Path, $true, [ref]$wasVerified)
    [pscustomobject]@{
        Path = $Path
        Ok = [bool]$ok
        WasVerified = [bool]$wasVerified
        Win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    }
}

function Assert-StrongNameOk([string]$Path) {
    $result = Test-StrongNameSignature $Path
    if (-not $result.Ok -or -not $result.WasVerified) {
        throw "Strong-name verification failed for $Path (Win32Error=$($result.Win32Error)). Use original signed binaries as BinaryRoot."
    }
}

$rootFull = Resolve-FullPath $Root
if ([string]::IsNullOrWhiteSpace($BinaryRoot)) {
    $BinaryRoot = Join-Path $rootFull '_archive\_vendor\ZTool-original'
}
if ([string]::IsNullOrWhiteSpace($AssetsRoot)) {
    $AssetsRoot = Join-Path $rootFull '_localized-full-20260511-091044'
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputRoot = Join-Path $rootFull "_licensed-ztool-$stamp"
}

$binaryRootFull = Resolve-FullPath $BinaryRoot
$assetsRootFull = Resolve-FullPath $AssetsRoot
$outputRootFull = Resolve-FullPath $OutputRoot

if (-not (Test-Path -LiteralPath $binaryRootFull -PathType Container)) {
    throw "BinaryRoot not found: $binaryRootFull"
}
if (-not (Test-Path -LiteralPath $assetsRootFull -PathType Container)) {
    throw "AssetsRoot not found: $assetsRootFull"
}

if (Test-Path -LiteralPath $outputRootFull) {
    if (-not $Force) {
        throw "OutputRoot already exists: $outputRootFull. Pass -Force to replace it."
    }

    Assert-UnderRoot $outputRootFull $rootFull
    Remove-Item -LiteralPath $outputRootFull -Recurse -Force
}

$launcherOutput = Join-Path $rootFull 'packaging\ZTool.LicenseLauncher\bin\Release\ZTool.LicenseLauncher.exe'
$updaterOutput = Join-Path $rootFull 'packaging\ZTool.UpdateDisabled\bin\Release\ZTool.UpdateDisabled.exe'

if (-not [string]::IsNullOrWhiteSpace($PublicKeyXmlPath)) {
    $PublicKeyXml = Get-Content -LiteralPath (Resolve-FullPath $PublicKeyXmlPath) -Raw
}
if ($Production -and [string]::IsNullOrWhiteSpace($PublicKeyXml)) {
    throw 'Production package requires -PublicKeyXmlPath or -PublicKeyXml.'
}

$payloadKey = if (-not [string]::IsNullOrWhiteSpace($PayloadKey)) { $PayloadKey } else { [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N') }
$generatedConfig = Join-Path $rootFull 'packaging\ZTool.LicenseLauncher\obj\LicenseBuildConfig.generated.cs'
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($generatedConfig)) | Out-Null
@"
namespace ZTool.LicenseLauncher
{
    internal static class EmbeddedLicenseConfig
    {
        public const string LicenseBaseUrl = $(ConvertTo-CSharpLiteral $LicenseBaseUrl.TrimEnd('/'));
        public const string PublicKeyXml = $(ConvertTo-CSharpLiteral $PublicKeyXml);
        public const string PayloadKey = $(ConvertTo-CSharpLiteral $payloadKey);
    }
}
"@ | Set-Content -LiteralPath $generatedConfig -Encoding UTF8

Invoke-CompileExe `
    -OutputPath $launcherOutput `
    -Sources @(
        (Join-Path $rootFull 'packaging\ZTool.LicenseLauncher\Program.cs'),
        (Join-Path $rootFull 'packaging\ZTool.LicenseLauncher\Properties\AssemblyInfo.cs'),
        $generatedConfig
    ) `
    -References @('System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Management.dll', 'System.Web.Extensions.dll', 'System.Windows.Forms.dll') `
    -Defines @('ZTOOL_EMBEDDED_LICENSE_CONFIG')

Remove-Item -LiteralPath $generatedConfig -Force -ErrorAction SilentlyContinue

Invoke-CompileExe `
    -OutputPath $updaterOutput `
    -Sources @(
        (Join-Path $rootFull 'packaging\ZTool.UpdateDisabled\Program.cs'),
        (Join-Path $rootFull 'packaging\ZTool.UpdateDisabled\Properties\AssemblyInfo.cs')
    ) `
    -References @('System.dll', 'System.Windows.Forms.dll')

Copy-DirectoryContents -Source $binaryRootFull -Destination $outputRootFull

Get-ChildItem -LiteralPath $assetsRootFull -Directory | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $outputRootFull -Recurse -Force
}

$assetFiles = @('ZTool.settings', 'ZTool-test.settings', 'backup-20230512.settings')
foreach ($assetFile in $assetFiles) {
    $source = Join-Path $assetsRootFull $assetFile
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $outputRootFull $assetFile) -Force
    }
}

$originalExe = Join-Path $outputRootFull 'ZTool.exe'
$coreExe = Join-Path $outputRootFull 'ZTool.Core.exe'
$corePayload = Join-Path $outputRootFull 'ZTool.Core.payload'
$addinDll = Join-Path $outputRootFull 'ZTool.dll'
$asciiInit = Join-Path $outputRootFull 'ZTool.Init.exe'

$initAssemblyName = [string]::Concat([char]0x521D, [char]0x59CB, [char]0x5316)
$originalInit = Get-ChildItem -LiteralPath $outputRootFull -File -Filter '*.exe' |
    Where-Object {
        try {
            [System.Reflection.AssemblyName]::GetAssemblyName($_.FullName).Name -eq $initAssemblyName
        } catch {
            $false
        }
    } |
    Select-Object -First 1

Assert-StrongNameOk $originalExe
Assert-StrongNameOk $addinDll
if ($null -ne $originalInit) {
    Assert-StrongNameOk $originalInit.FullName
}

$coreOriginalHash = Get-FileSha256 $originalExe
Protect-Payload -InputPath $originalExe -OutputPath $corePayload -KeyMaterial $payloadKey
Remove-Item -LiteralPath $originalExe -Force
if (Test-Path -LiteralPath $coreExe -PathType Leaf) {
    Remove-Item -LiteralPath $coreExe -Force
}
Copy-Item -LiteralPath $launcherOutput -Destination $originalExe -Force

$updaterPath = Join-Path $outputRootFull 'ZTool Updater.exe'
if (Test-Path -LiteralPath $updaterPath -PathType Leaf) {
    Remove-Item -LiteralPath $updaterPath -Force
}
Copy-Item -LiteralPath $updaterOutput -Destination $updaterPath -Force

if (($null -ne $originalInit) -and -not (Test-Path -LiteralPath $asciiInit -PathType Leaf)) {
    Copy-Item -LiteralPath $originalInit.FullName -Destination $asciiInit -Force
    Assert-StrongNameOk $asciiInit
}

$config = @"
<?xml version="1.0" encoding="utf-8"?>
<ZToolLicenseLauncher>
  <CoreExecutable>ZTool.Core.exe</CoreExecutable>
  <CorePayload>ZTool.Core.payload</CorePayload>
  <AppVersion>1.1</AppVersion>
  <OfflineGraceDays>$OfflineGraceDays</OfflineGraceDays>
</ZToolLicenseLauncher>
"@
$config | Set-Content -LiteralPath (Join-Path $outputRootFull 'ZTool.LicenseLauncher.config') -Encoding UTF8

@'
@echo off
"%~dp0ZTool.exe" --deactivate
pause
'@ | Set-Content -LiteralPath (Join-Path $outputRootFull 'Deactivate ZTool License.cmd') -Encoding ASCII

$manifest = [pscustomobject]@{
    CreatedAt = (Get-Date).ToString('o')
    BinaryRoot = $binaryRootFull
    AssetsRoot = $assetsRootFull
    LicenseBaseUrl = $LicenseBaseUrl.TrimEnd('/')
    CorePayload = 'ZTool.Core.payload'
    Production = [bool]$Production
    Updates = 'disabled by ZTool Updater.exe stub'
    Files = [ordered]@{
        Launcher = Get-FileSha256 (Join-Path $outputRootFull 'ZTool.exe')
        CoreOriginal = $coreOriginalHash
        CorePayload = Get-FileSha256 (Join-Path $outputRootFull 'ZTool.Core.payload')
        AddIn = Get-FileSha256 (Join-Path $outputRootFull 'ZTool.dll')
        Init = Get-FileSha256 (Join-Path $outputRootFull 'ZTool.Init.exe')
        UpdateStub = Get-FileSha256 (Join-Path $outputRootFull 'ZTool Updater.exe')
    }
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRootFull 'licensed-package-manifest.json') -Encoding UTF8

$zipPath = $null
if ($Package) {
    $zipPath = "$outputRootFull.zip"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $outputRootFull '*') -DestinationPath $zipPath -Force
}

[pscustomobject]@{
    Status = 'ok'
    OutputRoot = $outputRootFull
    PackagePath = $zipPath
    Launcher = Join-Path $outputRootFull 'ZTool.exe'
    CorePayload = Join-Path $outputRootFull 'ZTool.Core.payload'
    UpdateStub = Join-Path $outputRootFull 'ZTool Updater.exe'
}
