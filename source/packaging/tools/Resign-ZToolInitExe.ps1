param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,
    [string]$SnkPath = '',
    [string]$ZToolPublicKeyToken = '',
    [ValidateSet('Russian', 'English')]
    [string]$Language = 'Russian'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-DnlibPath {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $candidates = @(
        (Join-Path $repoRoot '_archive\_reverse\packages\dnlib\lib\net45\dnlib.dll'),
        (Join-Path $repoRoot '_archive\_reverse\packages\dnlib\lib\netstandard2.0\dnlib.dll')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'dnlib.dll was not found.'
}

function Ensure-DnlibLoaded {
    if ('dnlib.DotNet.ModuleDefMD' -as [type]) {
        return
    }

    Add-Type -Path (Get-DnlibPath)
}

function Get-FileSha256([string]$Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Get-SnkPublicKeyTokenHex([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $pair = [System.Reflection.StrongNameKeyPair]::new($bytes)
    $pubKey = $pair.PublicKey
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($pubKey)
    } finally {
        $sha1.Dispose()
    }

    $tokenBytes = New-Object byte[] 8
    [Array]::Copy($hash, $hash.Length - 8, $tokenBytes, 0, 8)
    [Array]::Reverse($tokenBytes)
    return (([BitConverter]::ToString($tokenBytes)) -replace '-', '').ToLowerInvariant()
}

$packageRootFull = Resolve-FullPath $PackageRoot
if (-not (Test-Path -LiteralPath $packageRootFull -PathType Container)) {
    throw "PackageRoot not found: $packageRootFull"
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ([string]::IsNullOrWhiteSpace($SnkPath)) {
    $SnkPath = Join-Path $repoRoot '_archive\_reverse\prototype-resign\ZToolFork3.snk'
}
$snkFull = Resolve-FullPath $SnkPath
if (-not (Test-Path -LiteralPath $snkFull -PathType Leaf)) {
    throw "SNK not found: $snkFull"
}

Ensure-DnlibLoaded

$ztoolExe = Join-Path $packageRootFull 'ZTool.exe'
if (-not (Test-Path -LiteralPath $ztoolExe -PathType Leaf)) {
    throw "ZTool.exe not found: $ztoolExe"
}

if ([string]::IsNullOrWhiteSpace($ZToolPublicKeyToken)) {
    $ztoolAssemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($ztoolExe)
    $ztoolTokenBytes = $ztoolAssemblyName.GetPublicKeyToken()
    if ($null -eq $ztoolTokenBytes -or $ztoolTokenBytes.Length -eq 0) {
        $ZToolPublicKeyToken = Get-SnkPublicKeyTokenHex $snkFull
    } else {
        $ZToolPublicKeyToken = -join ($ztoolTokenBytes | ForEach-Object { $_.ToString('x2') })
    }
}

$initExe = Join-Path $packageRootFull 'ZTool.Init.exe'
if (-not (Test-Path -LiteralPath $initExe -PathType Leaf)) {
    throw "ZTool.Init.exe not found: $initExe"
}

$strongNameKey = [dnlib.DotNet.StrongNameKey]::new($snkFull)
$initPatched = Join-Path ([System.IO.Path]::GetTempPath()) ("ztool-init-resigned-" + [guid]::NewGuid().ToString('N') + ".exe")

# Load Get-StringMap for ldstr translation (same dictionary used by
# Disable-ZToolEmbeddedUpdates.ps1::Patch-ChineseLdstrTranslations for the
# decrypted payload).
function Get-InitStringMap([string]$SelectedLanguage) {
    $patchScript = Join-Path $PSScriptRoot 'Patch-SWToolNativePayloadResources.ps1'
    if (-not (Test-Path -LiteralPath $patchScript -PathType Leaf)) {
        throw "Patch-SWToolNativePayloadResources.ps1 not found next to this script."
    }
    $scriptContent = Get-Content -LiteralPath $patchScript -Raw -Encoding UTF8
    $startIndex = $scriptContent.IndexOf("function Get-StringMap")
    $endIndex = $scriptContent.IndexOf("function Test-NativeRuntimeStarts")
    if ($startIndex -lt 0 -or $endIndex -le $startIndex) {
        throw "Could not extract Get-StringMap from Patch-SWToolNativePayloadResources.ps1."
    }
    Invoke-Expression $scriptContent.Substring($startIndex, $endIndex - $startIndex)
    return Get-StringMap $SelectedLanguage
}

$initStringMap = Get-InitStringMap $Language

try {
    $module = [dnlib.DotNet.ModuleDefMD]::Load($initExe)
    $repointed = New-Object System.Collections.Generic.List[string]
    $translatedStrings = 0
    try {
        $expectedTokenBytes = New-Object byte[] 8
        for ($i = 0; $i -lt 8; $i++) {
            $expectedTokenBytes[$i] = [Convert]::ToByte($ZToolPublicKeyToken.Substring($i * 2, 2), 16)
        }
        $expectedToken = [dnlib.DotNet.PublicKeyToken]::new($expectedTokenBytes)
        $expectedTokenLower = $ZToolPublicKeyToken.ToLowerInvariant()

        foreach ($assemblyRef in $module.GetAssemblyRefs()) {
            if ([string]$assemblyRef.Name -ne 'ZTool') {
                continue
            }

            $current = [string]$assemblyRef.PublicKeyOrToken
            if ($null -eq $current) {
                $current = ''
            }

            $currentLower = $current.ToLowerInvariant()
            if ($currentLower -eq $expectedTokenLower -and -not $assemblyRef.HasPublicKey) {
                $repointed.Add('already-token-style')
                continue
            }

            $assemblyRef.PublicKeyOrToken = $expectedToken
            $assemblyRef.HasPublicKey = $false
            $repointed.Add(($current + ' -> ' + $expectedTokenLower))
        }

        foreach ($type in $module.GetTypes()) {
            foreach ($method in $type.Methods) {
                if (-not $method.HasBody) { continue }
                $instructions = $method.Body.Instructions
                for ($i = 0; $i -lt $instructions.Count; $i++) {
                    $inst = $instructions[$i]
                    if ($inst.OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Ldstr) { continue }
                    $val = $inst.Operand -as [string]
                    if ($null -eq $val) { continue }
                    if (-not $initStringMap.Contains($val)) { continue }
                    $inst.Operand = [string]$initStringMap[$val]
                    $translatedStrings++
                }
            }
        }

        $options = [dnlib.DotNet.Writer.ModuleWriterOptions]::new($module)
        $options.Logger = [dnlib.DotNet.DummyLogger]::NoThrowInstance
        $options.MetadataOptions.Flags = $options.MetadataOptions.Flags -bor [dnlib.DotNet.Writer.MetadataFlags]::PreserveAll
        $options.InitializeStrongNameSigning($module, $strongNameKey)
        $module.Write($initPatched, $options)
    } finally {
        $module.Dispose()
    }

    Copy-Item -LiteralPath $initPatched -Destination $initExe -Force

    [pscustomobject]@{
        Status = 'ok'
        InitExe = $initExe
        Sha256 = Get-FileSha256 $initExe
        Repointed = $repointed
        ExpectedPublicKeyToken = $ZToolPublicKeyToken
        Language = $Language
        TranslatedLdstrCount = $translatedStrings
    } | ConvertTo-Json -Depth 4
} finally {
    Remove-Item -LiteralPath $initPatched -Force -ErrorAction SilentlyContinue
}
