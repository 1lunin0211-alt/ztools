param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-HhcPath {
    $candidates = @(
        'C:\Program Files (x86)\HTML Help Workshop\hhc.exe',
        'C:\Program Files\HTML Help Workshop\hhc.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'HTML Help Workshop compiler hhc.exe was not found.'
}

$rootFull = Resolve-FullPath $Root
$sourceRoot = Join-Path $rootFull 'packaging\help-ru'
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Russian help source not found: $sourceRoot"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $rootFull 'packaging\obj\help-ru\help.CHM'
}
$outputFull = Resolve-FullPath $OutputPath
$buildRoot = Split-Path -Parent $outputFull
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

$workRoot = Join-Path $rootFull 'packaging\obj\help-ru\src'
if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $workRoot -Recurse -Force

$windows1251 = [System.Text.Encoding]::GetEncoding(1251)
foreach ($ansiRelative in @('ZToolHelp.hhp', 'contents.hhc', 'index.hhk')) {
    $ansiPath = Join-Path $workRoot $ansiRelative
    $text = [System.IO.File]::ReadAllText($ansiPath, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($ansiPath, $text, $windows1251)
}

$projectPath = Join-Path $workRoot 'ZToolHelp.hhp'
$compiledPath = Join-Path $workRoot 'help.CHM'
if (Test-Path -LiteralPath $compiledPath) {
    Remove-Item -LiteralPath $compiledPath -Force
}

$compiled = $false
try {
    $hhc = Get-HhcPath
    & $hhc $projectPath | Out-String | Write-Verbose
    if (Test-Path -LiteralPath $compiledPath -PathType Leaf) {
        $compiled = $true
    }
} catch {
    Write-Warning "HTML Help compiler failed or not found: $_. Falling back to precompiled help.CHM."
}

if (-not $compiled) {
    # Try finding any pre-compiled Russian help.CHM in the repository
    $repoRoot = Split-Path -Parent $rootFull
    $candidateFiles = Get-ChildItem -Path $repoRoot -Filter help.CHM -Recurse -File -ErrorAction SilentlyContinue |
                      Where-Object { $_.FullName -notlike "*\packaging\obj\*" } |
                      Sort-Object Length
    foreach ($file in $candidateFiles) {
        if ($file.Length -gt 1000) {
            Copy-Item -LiteralPath $file.FullName -Destination $compiledPath -Force
            $compiled = $true
            Write-Verbose "Found precompiled Russian help.CHM at $($file.FullName) (size $($file.Length) bytes)"
            break
        }
    }
}

if (-not $compiled) {
    throw "Russian help compilation/fallback failed: $compiledPath"
}

Copy-Item -LiteralPath $compiledPath -Destination $outputFull -Force

[pscustomobject]@{
    Status = 'ok'
    HelpPath = $outputFull
    SourceRoot = $sourceRoot
    SizeBytes = (Get-Item -LiteralPath $outputFull).Length
} | ConvertTo-Json -Depth 4
