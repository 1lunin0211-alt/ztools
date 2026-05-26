param(
    [string]$PackageRoot = '',
    [string]$OutputDir = '',
    [string]$AppVersion = '1.1',
    [string]$Publisher = ([char[]] @(0x041B, 0x0443, 0x043D, 0x0438, 0x043D, 0x0020, 0x0412, 0x002E, 0x0418, 0x002E) -join ''),
    [string]$NsisPath = '',
    [switch]$SkipPackageGate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-AppVersionQuad([string]$Version) {
    $parts = @($Version.Split('.') | ForEach-Object {
        if ($_ -notmatch '^\d+$') {
            throw "AppVersion must contain only numeric dot-separated parts for installer version info: $Version"
        }

        [int]$_
    })

    if ($parts.Count -lt 1 -or $parts.Count -gt 4) {
        throw "AppVersion must contain 1 to 4 numeric parts: $Version"
    }

    while ($parts.Count -lt 4) {
        $parts += 0
    }

    ($parts | ForEach-Object { [string]$_ }) -join '.'
}

function Get-NsisPath([string]$ExplicitPath) {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $full = Resolve-FullPath $ExplicitPath
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "makensis.exe not found: $full"
        }

        return $full
    }

    $command = Get-Command makensis.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = @(
        'C:\Program Files (x86)\NSIS\makensis.exe',
        'C:\Program Files\NSIS\makensis.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'makensis.exe was not found. Install NSIS or pass -NsisPath.'
}

function New-IcoFromBitmap([string]$BitmapPath, [string]$IconPath) {
    Add-Type -AssemblyName System.Drawing

    $source = [System.Drawing.Image]::FromFile($BitmapPath)
    try {
        $size = 32
        $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.Clear([System.Drawing.Color]::Transparent)
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.DrawImage($source, 0, 0, $size, $size)
            } finally {
                $graphics.Dispose()
            }

            $pngStream = [System.IO.MemoryStream]::new()
            try {
                $bitmap.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
                $png = $pngStream.ToArray()
            } finally {
                $pngStream.Dispose()
            }

            $iconDir = Split-Path -Parent $IconPath
            if (-not (Test-Path -LiteralPath $iconDir -PathType Container)) {
                New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
            }

            $file = [System.IO.File]::Open($IconPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
            try {
                $writer = [System.IO.BinaryWriter]::new($file)
                try {
                    $writer.Write([UInt16]0)
                    $writer.Write([UInt16]1)
                    $writer.Write([UInt16]1)
                    $writer.Write([byte]$size)
                    $writer.Write([byte]$size)
                    $writer.Write([byte]0)
                    $writer.Write([byte]0)
                    $writer.Write([UInt16]1)
                    $writer.Write([UInt16]32)
                    $writer.Write([UInt32]$png.Length)
                    $writer.Write([UInt32]22)
                    $writer.Write($png)
                } finally {
                    $writer.Dispose()
                }
            } finally {
                $file.Dispose()
            }
        } finally {
            $bitmap.Dispose()
        }
    } finally {
        $source.Dispose()
    }
}

function ConvertTo-NsisQuotedString([string]$Value) {
    if ($null -eq $Value) {
        $Value = ''
    }

    '"' + ($Value -replace '\$', '$$' -replace '"', '$\"') + '"'
}

$sourceRoot = Resolve-FullPath (Join-Path $PSScriptRoot '..\..')
$repoRoot = Split-Path -Parent $sourceRoot

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $releaseDir = Join-Path $repoRoot 'release'
    if (Test-Path -LiteralPath $releaseDir -PathType Container) {
        $latestDir = Get-ChildItem -LiteralPath $releaseDir -Filter '_ztool-fork-production-*' -Directory |
                     Sort-Object CreationTime -Descending |
                     Select-Object -First 1
        if ($null -ne $latestDir) {
            $PackageRoot = $latestDir.FullName
        }
    }
    if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
        $PackageRoot = Join-Path $repoRoot 'release\_ztool-fork-production-placeholder'
    }
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot 'release\installer'
}

$packageRootFull = Resolve-FullPath $PackageRoot
$outputDirFull = Resolve-FullPath $OutputDir
$installerScript = Join-Path $sourceRoot 'packaging\installer\ZToolInstaller.nsi'

if (-not (Test-Path -LiteralPath $packageRootFull -PathType Container)) {
    throw "PackageRoot not found: $packageRootFull"
}
if (-not (Test-Path -LiteralPath (Join-Path $packageRootFull 'ZTool.exe') -PathType Leaf)) {
    throw "ZTool.exe not found in PackageRoot: $packageRootFull"
}
if (-not (Test-Path -LiteralPath $installerScript -PathType Leaf)) {
    throw "Installer script not found: $installerScript"
}

if (-not $SkipPackageGate) {
    $gateScript = Join-Path $PSScriptRoot 'Test-ZToolLicensedPackage.ps1'
    $gateJson = (& $gateScript -PackageRoot $packageRootFull | ForEach-Object { [string]$_ }) -join "`n"
    $gate = $gateJson | ConvertFrom-Json
    if ($gate.Status -ne 'ok') {
        throw "Package gate failed for $packageRootFull"
    }
}

New-Item -ItemType Directory -Force -Path $outputDirFull | Out-Null

$nsis = Get-NsisPath $NsisPath
$versionQuad = Get-AppVersionQuad $AppVersion
$installerPath = Join-Path $outputDirFull "SWTool-Setup-$AppVersion.exe"
$installerIcon = Join-Path $sourceRoot 'packaging\obj\installer\ZTool.ico'
$installerConfig = Join-Path $sourceRoot 'packaging\obj\installer\ZToolInstaller.config.nsh'
New-IcoFromBitmap -BitmapPath (Join-Path $packageRootFull 'ZTool.bmp') -IconPath $installerIcon
$configText = @(
    "!define APP_PUBLISHER $(ConvertTo-NsisQuotedString $Publisher)"
) -join "`r`n"
[System.IO.File]::WriteAllText($installerConfig, $configText + "`r`n", [System.Text.UTF8Encoding]::new($true))

$arguments = @(
    '/V3',
    "/DSOURCE_DIR=$packageRootFull",
    "/DOUTPUT_DIR=$outputDirFull",
    "/DINSTALLER_ICON=$installerIcon",
    "/DINSTALLER_CONFIG=$installerConfig",
    "/DAPP_VERSION=$AppVersion",
    "/DAPP_VERSION_QUAD=$versionQuad",
    $installerScript
)

& $nsis @arguments
if ($LASTEXITCODE -ne 0) {
    throw "makensis.exe failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Installer was not created: $installerPath"
}

$versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($installerPath)
[pscustomobject]@{
    Status = 'ok'
    Installer = $installerPath
    PackageRoot = $packageRootFull
    AppVersion = $AppVersion
    AppVersionQuad = $versionQuad
    Publisher = $Publisher
    SizeBytes = (Get-Item -LiteralPath $installerPath).Length
    FileVersion = $versionInfo.FileVersion
    ProductVersion = $versionInfo.ProductVersion
    CompanyName = $versionInfo.CompanyName
} | ConvertTo-Json -Depth 4
