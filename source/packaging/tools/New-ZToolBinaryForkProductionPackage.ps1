param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$SourceRoot = '',
    [string]$OutputRoot = '',
    [string]$LicenseBaseUrl = 'https://license.vizbuka.ru/ztool',
    [string]$ActivationHelpUrl = '',
    [string]$PublicKeyXmlPath = '',
    [string]$PublicKeyXmlUri = '',
    [string]$PublicKeyXml = '',
    [string]$SnkPath = '',
    [int]$OfflineGraceDays = 7,
    [switch]$Force,
    [switch]$SkipGate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
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
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Set-ZToolSettingsSolidWorksDefaults([string]$PackageRoot) {
    $settingsPath = Join-Path $PackageRoot 'ZTool.settings'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        throw "ZTool.settings not found: $settingsPath"
    }

    $document = [xml](Get-Content -LiteralPath $settingsPath -Raw)
    if ($null -eq $document.CConfigDO -or $null -eq $document.CConfigDO.SWver) {
        throw "ZTool.settings does not contain CConfigDO/SWver: $settingsPath"
    }

    $document.CConfigDO.SWver = '0'
    if ($null -ne $document.CConfigDO.GetDataOption) {
        $document.CConfigDO.GetDataOption = '0'
    }

    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $settings.Indent = $true
    $settings.NewLineChars = "`r`n"

    $writer = [System.Xml.XmlWriter]::Create($settingsPath, $settings)
    try {
        $document.Save($writer)
    } finally {
        $writer.Dispose()
    }
}

$rootFull = Resolve-FullPath $Root
$repoRoot = Split-Path -Parent $rootFull
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $defaultSourceRoot = Join-Path $rootFull '_localized-full-20260511-091044'
    if (Test-Path -LiteralPath $defaultSourceRoot -PathType Container) {
        $SourceRoot = $defaultSourceRoot
    } else {
        $SourceRoot = Join-Path $rootFull '_archive\legacy-localized-builds\_localized-full-20260511-091044'
    }
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputRoot = Join-Path $repoRoot "release\_ztool-fork-production-$stamp"
}

$sourceRootFull = Resolve-FullPath $SourceRoot
$outputRootFull = Resolve-FullPath $OutputRoot

if (-not (Test-Path -LiteralPath $sourceRootFull -PathType Container)) {
    throw "SourceRoot not found: $sourceRootFull"
}

if (Test-Path -LiteralPath $outputRootFull) {
    if (-not $Force) {
        throw "OutputRoot already exists: $outputRootFull. Pass -Force to replace it."
    }

    Assert-UnderRoot $outputRootFull $repoRoot
    Remove-Item -LiteralPath $outputRootFull -Recurse -Force
}

$runtimeRoot = Join-Path $rootFull '_archive\_reverse\build\ZTool.ProductionRuntime\Release'
$buildRuntime = Join-Path $PSScriptRoot 'Build-ZToolProductionRuntime.ps1'
$runtimeArgs = @{
    Root = $rootFull
    OutputRoot = $runtimeRoot
    LicenseBaseUrl = $LicenseBaseUrl
    OfflineGraceDays = $OfflineGraceDays
}
if (-not [string]::IsNullOrWhiteSpace($ActivationHelpUrl)) {
    $runtimeArgs.ActivationHelpUrl = $ActivationHelpUrl
}
if (-not [string]::IsNullOrWhiteSpace($PublicKeyXmlPath)) {
    $runtimeArgs.PublicKeyXmlPath = $PublicKeyXmlPath
}
if (-not [string]::IsNullOrWhiteSpace($PublicKeyXmlUri)) {
    $runtimeArgs.PublicKeyXmlUri = $PublicKeyXmlUri
}
if (-not [string]::IsNullOrWhiteSpace($PublicKeyXml)) {
    $runtimeArgs.PublicKeyXml = $PublicKeyXml
}
if (-not [string]::IsNullOrWhiteSpace($SnkPath)) {
    $runtimeArgs.SnkPath = $SnkPath
}

$runtimeJson = & $buildRuntime @runtimeArgs
$runtime = ($runtimeJson | ForEach-Object { [string]$_ }) -join "`n" | ConvertFrom-Json

Copy-DirectoryContents -Source $sourceRootFull -Destination $outputRootFull
Set-ZToolSettingsSolidWorksDefaults $outputRootFull

$buildRussianHelp = Join-Path $PSScriptRoot 'Build-ZToolRussianHelp.ps1'
$russianHelpResult = (& $buildRussianHelp -Root $rootFull -OutputPath (Join-Path $outputRootFull 'help.CHM') | ForEach-Object { [string]$_ }) -join "`n" | ConvertFrom-Json

Copy-Item -LiteralPath $runtime.LicenseDll -Destination (Join-Path $outputRootFull 'ZTool.License.dll') -Force
Copy-Item -LiteralPath $runtime.UpdateDisabledExe -Destination (Join-Path $outputRootFull 'ZTool Updater.exe') -Force
Copy-Item -LiteralPath $runtime.DeactivateExe -Destination (Join-Path $outputRootFull 'ZTool License Deactivate.exe') -Force
Copy-Item -LiteralPath $runtime.Manifest -Destination (Join-Path $outputRootFull 'ZTool.ProductionRuntime.provenance.json') -Force
Copy-Item -LiteralPath "$($runtime.LicenseDll).provenance.json" -Destination (Join-Path $outputRootFull 'ZTool.License.dll.provenance.json') -Force

$disableUpdates = Join-Path $PSScriptRoot 'Disable-ZToolEmbeddedUpdates.ps1'
$disableUpdateArgs = @{
    PackageRoot = $outputRootFull
}
if (-not [string]::IsNullOrWhiteSpace($SnkPath)) {
    $disableUpdateArgs.SnkPath = $SnkPath
}
$disableUpdateResult = & $disableUpdates @disableUpdateArgs

$resignInit = Join-Path $PSScriptRoot 'Resign-ZToolInitExe.ps1'
$resignInitArgs = @{
    PackageRoot = $outputRootFull
}
if (-not [string]::IsNullOrWhiteSpace($SnkPath)) {
    $resignInitArgs.SnkPath = $SnkPath
}
$resignInitResult = & $resignInit @resignInitArgs

$deactivateCmd = Join-Path $outputRootFull 'Deactivate ZTool License.cmd'
@'
@echo off
setlocal
"%~dp0ZTool License Deactivate.exe"
exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath $deactivateCmd -Encoding ASCII

$registerScript = Join-Path $PSScriptRoot 'Register-ZToolBinaryForkSolidWorksAddIn.ps1'
$unregisterScript = Join-Path $PSScriptRoot 'Unregister-ZToolBinaryForkSolidWorksAddIn.ps1'
Copy-Item -LiteralPath $registerScript -Destination (Join-Path $outputRootFull 'Register ZTool SolidWorks AddIn.ps1') -Force
Copy-Item -LiteralPath $unregisterScript -Destination (Join-Path $outputRootFull 'Unregister ZTool SolidWorks AddIn.ps1') -Force

@'
@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Register ZTool SolidWorks AddIn.ps1" -RemoveLegacy
exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath (Join-Path $outputRootFull 'Register ZTool SolidWorks AddIn.cmd') -Encoding ASCII

@'
@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Unregister ZTool SolidWorks AddIn.ps1" -RemoveLegacy
exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath (Join-Path $outputRootFull 'Unregister ZTool SolidWorks AddIn.cmd') -Encoding ASCII

$gateResult = $null
if (-not $SkipGate) {
    $gate = Join-Path $PSScriptRoot 'Test-ZToolLicensedPackage.ps1'
    $gateResult = (& $gate -PackageRoot $outputRootFull | ForEach-Object { [string]$_ }) -join "`n" | ConvertFrom-Json
    if ($gateResult.Status -ne 'ok') {
        throw "Package gate failed for $outputRootFull"
    }
}

$files = @(
    'ZTool.exe',
    'ZTool.dll',
    'ZTool.Init.exe',
    'ZTool.License.dll',
    'ZTool Updater.exe',
    'ZTool License Deactivate.exe',
    'Deactivate ZTool License.cmd',
    'Register ZTool SolidWorks AddIn.ps1',
    'Register ZTool SolidWorks AddIn.cmd',
    'Unregister ZTool SolidWorks AddIn.ps1',
    'Unregister ZTool SolidWorks AddIn.cmd'
)

$manifestFiles = [ordered]@{}
foreach ($file in $files) {
    $path = Join-Path $outputRootFull $file
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $manifestFiles[$file] = Get-FileSha256 $path
    }
}

$manifest = [pscustomobject]@{
    CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    SourceRoot = $sourceRootFull
    OutputRoot = $outputRootFull
    LicenseBaseUrl = $LicenseBaseUrl.TrimEnd('/')
    ActivationHelpUrl = if ([string]::IsNullOrWhiteSpace($ActivationHelpUrl)) { $LicenseBaseUrl.TrimEnd('/') } else { $ActivationHelpUrl }
    RussianHelp = $russianHelpResult
    RuntimeManifest = 'ZTool.ProductionRuntime.provenance.json'
    UpdatePatch = $disableUpdateResult
    Files = $manifestFiles
    Gate = $gateResult
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputRootFull 'ztool-production-package-manifest.json') -Encoding UTF8

[pscustomobject]@{
    Status = 'ok'
    OutputRoot = $outputRootFull
    Runtime = $runtime
    Gate = $gateResult
} | ConvertTo-Json -Depth 6
