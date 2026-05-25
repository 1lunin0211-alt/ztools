param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$OutputRoot = '',
    [string]$LicenseBaseUrl = 'https://license.vizbuka.ru/ztool',
    [string]$ActivationHelpUrl = '',
    [string]$PublicKeyXmlPath = '',
    [string]$PublicKeyXmlUri = '',
    [string]$PublicKeyXml = '',
    [string]$SnkPath = '',
    [int]$OfflineGraceDays = 7,
    [switch]$AllowDevelopmentEmptyPublicKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-CscPath {
    $candidates = @(
        'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe',
        'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'csc.exe was not found.'
}

function ConvertTo-CSharpLiteral([string]$Value) {
    if ($null -eq $Value) {
        $Value = ''
    }

    return '@"' + ($Value -replace '"', '""') + '"'
}

function Get-FileSha256([string]$Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
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
        throw 'Public key XML must be raw RSAKeyValue XML, not a JSON wrapper.'
    }

    try {
        $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
        try {
            $rsa.FromXmlString($trimmed)
        } finally {
            $rsa.Dispose()
        }
    } catch {
        throw "Public key XML is not loadable by RSACryptoServiceProvider.FromXmlString: $($_.Exception.Message)"
    }

    $trimmed
}

function Get-RelativePath([string]$BasePath, [string]$TargetPath) {
    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseFull += [System.IO.Path]::DirectorySeparatorChar
    }

    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
    $baseUri = [Uri]$baseFull
    $targetUri = [Uri]$targetFull
    [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
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
        throw "Strong-name verification failed: $Path (Win32Error=$($result.Win32Error))"
    }
}

function Protect-LicenseAssembly([string]$DllPath, [string]$SnkPath) {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $dnlibPath = Join-Path $repoRoot '_archive\_reverse\packages\dnlib\lib\net45\dnlib.dll'
    if (-not (Test-Path -LiteralPath $dnlibPath -PathType Leaf)) {
        throw "dnlib.dll not found at $dnlibPath"
    }
    Add-Type -Path $dnlibPath -ErrorAction SilentlyContinue

    $bytes = [System.IO.File]::ReadAllBytes($DllPath)
    $module = [dnlib.DotNet.ModuleDefMD]::Load($bytes)
    $strongNameKey = [dnlib.DotNet.StrongNameKey]::new($SnkPath)
    
    $decryptorType = $module.Find('ZTool.License.Decryptor', $true)
    if ($null -eq $decryptorType) {
        throw "Decryptor type not found in ZTool.License."
    }
    $decMethod = $null
    foreach ($m in $decryptorType.Methods) {
        if ($m.Name -eq 'Dec') {
            $decMethod = $m
            break
        }
    }
    if ($null -eq $decMethod) {
        throw "Decryptor::Dec method not found."
    }

    foreach ($type in $module.GetTypes()) {
        if ($type.FullName -eq 'ZTool.License.Decryptor' -or $type.FullName.StartsWith('<Module>', [System.StringComparison]::Ordinal)) {
            continue
        }
        foreach ($method in $type.Methods) {
            if (-not $method.HasBody) { continue }
            
            $method.Body.SimplifyMacros($method.Parameters)
            
            $instrs = $method.Body.Instructions
            $i = 0
            $modified = $false
            while ($i -lt $instrs.Count) {
                $inst = $instrs[$i]
                if ($inst.OpCode -eq [dnlib.DotNet.Emit.OpCodes]::Ldstr) {
                    $plain = [string]$inst.Operand
                    if (-not [string]::IsNullOrEmpty($plain)) {
                        $chars = [char[]]$plain
                        for ($j = 0; $j -lt $chars.Length; $j++) {
                            $chars[$j] = [char]([int]$chars[$j] -bxor 0x5A)
                        }
                        $encrypted = [string]::new($chars)
                        $inst.Operand = $encrypted
                        
                        $callDec = [dnlib.DotNet.Emit.OpCodes]::Call.ToInstruction($decMethod)
                        $instrs.Insert($i + 1, $callDec)
                        $i++
                        $modified = $true
                    }
                }
                $i++
            }
            
            if ($modified) {
                $method.Body.OptimizeMacros()
            }
        }
    }

    $typesToPreserve = @(
        'ZTool.License.LicenseGate',
        'ZTool.License.LicenseCache',
        'ZTool.License.EmbeddedLicenseConfig',
        'ZTool.License.Decryptor'
    )

    $typeCounter = 1
    $methodCounter = 1
    $fieldCounter = 1
    foreach ($type in $module.GetTypes()) {
        if ($type.FullName.StartsWith('<Module>', [System.StringComparison]::Ordinal)) {
            continue
        }
        
        $shouldPreserve = $false
        foreach ($p in $typesToPreserve) {
            if ($type.FullName -eq $p -or 
                $type.FullName.StartsWith($p + "+", [System.StringComparison]::Ordinal) -or
                $type.FullName.StartsWith($p + "/", [System.StringComparison]::Ordinal)) {
                $shouldPreserve = $true
                break
            }
        }

        if ($shouldPreserve) {
            foreach ($field in $type.Fields) {
                if (-not $field.IsPublic) {
                    if ($field.Name -eq 'DemoMinutes' -or $field.Name -eq 'DemoSecondsEnvironmentVariable') {
                        continue
                    }
                    $field.Name = "f_" + $fieldCounter++
                }
            }
            foreach ($method in $type.Methods) {
                if (-not $method.IsPublic -and -not $method.IsConstructor -and -not $method.IsSpecialName) {
                    $method.Name = "m_" + $methodCounter++
                }
            }
            continue
        }

        if (-not $type.IsPublic) {
            $type.Name = "t_" + $typeCounter++
        }

        foreach ($method in $type.Methods) {
            if (-not $method.IsConstructor -and -not $method.IsSpecialName) {
                $method.Name = "m_" + $methodCounter++
            }
        }

        foreach ($field in $type.Fields) {
            $field.Name = "f_" + $fieldCounter++
        }
    }

    $options = [dnlib.DotNet.Writer.ModuleWriterOptions]::new($module)
    $options.Logger = [dnlib.DotNet.DummyLogger]::NoThrowInstance
    $options.InitializeStrongNameSigning($module, $strongNameKey)
    $module.Write($DllPath, $options)
    $module.Dispose()
}

function Invoke-Csc([string[]]$Arguments) {
    $csc = Get-CscPath
    & $csc @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "C# compilation failed with exit code $LASTEXITCODE."
    }
}

$rootFull = Resolve-FullPath $Root
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    if ($AllowDevelopmentEmptyPublicKey -and
        [string]::IsNullOrWhiteSpace($PublicKeyXml) -and
        [string]::IsNullOrWhiteSpace($PublicKeyXmlPath) -and
        [string]::IsNullOrWhiteSpace($PublicKeyXmlUri) -and
        [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('ZTOOL_LICENSE_PUBLIC_KEY_XML'))) {
        $OutputRoot = Join-Path $rootFull '_archive\_reverse\build\ZTool.ProductionRuntime.Dev\Release'
    } else {
        $OutputRoot = Join-Path $rootFull '_archive\_reverse\build\ZTool.ProductionRuntime\Release'
    }
}
$outputRootFull = Resolve-FullPath $OutputRoot

if ([string]::IsNullOrWhiteSpace($SnkPath)) {
    $SnkPath = Join-Path $rootFull '_archive\_reverse\prototype-resign\ZToolFork3.snk'
}
$snkFull = Resolve-FullPath $SnkPath
if (-not (Test-Path -LiteralPath $snkFull -PathType Leaf)) {
    throw "SNK not found: $snkFull"
}

if (-not [string]::IsNullOrWhiteSpace($PublicKeyXmlPath)) {
    $PublicKeyXml = Get-Content -LiteralPath (Resolve-FullPath $PublicKeyXmlPath) -Raw
}
if ([string]::IsNullOrWhiteSpace($PublicKeyXml) -and -not [string]::IsNullOrWhiteSpace($PublicKeyXmlUri)) {
    $response = Invoke-WebRequest -Uri $PublicKeyXmlUri -UseBasicParsing -TimeoutSec 20
    $content = [string]$response.Content
    $PublicKeyXml = Normalize-PublicKeyXml $content
}
if ([string]::IsNullOrWhiteSpace($PublicKeyXml)) {
    $PublicKeyXml = [Environment]::GetEnvironmentVariable('ZTOOL_LICENSE_PUBLIC_KEY_XML')
}

if (-not $AllowDevelopmentEmptyPublicKey) {
    if ([string]::IsNullOrWhiteSpace($PublicKeyXml)) {
        throw 'Production runtime requires -PublicKeyXmlPath, -PublicKeyXml, or ZTOOL_LICENSE_PUBLIC_KEY_XML.'
    }
    $PublicKeyXml = Assert-RsaPublicKeyXml $PublicKeyXml
}

New-Item -ItemType Directory -Force -Path $outputRootFull | Out-Null

$objRoot = Join-Path $rootFull 'packaging\obj\ZTool.ProductionRuntime'
New-Item -ItemType Directory -Force -Path $objRoot | Out-Null

$generatedConfig = Join-Path $objRoot 'LicenseBuildConfig.generated.cs'
$activationHelpUrlResolved = if ([string]::IsNullOrWhiteSpace($ActivationHelpUrl)) {
    $LicenseBaseUrl.TrimEnd('/')
} else {
    $ActivationHelpUrl
}
@"
namespace ZTool.License
{
    internal static class EmbeddedLicenseConfig
    {
        public const string LicenseBaseUrl = $(ConvertTo-CSharpLiteral $LicenseBaseUrl.TrimEnd('/'));
        public const string ActivationHelpUrl = $(ConvertTo-CSharpLiteral $activationHelpUrlResolved);
        public const string PublicKeyXml = $(ConvertTo-CSharpLiteral $PublicKeyXml);
        public const int OfflineGraceDays = $($OfflineGraceDays);
    }
}
"@ | Set-Content -LiteralPath $generatedConfig -Encoding UTF8

$licenseDll = Join-Path $outputRootFull 'ZTool.License.dll'
$licenseArgs = @(
    '/nologo',
    '/target:library',
    '/optimize+',
    '/debug:pdbonly',
    "/keyfile:$snkFull",
    "/out:$licenseDll",
    '/define:ZTOOL_EMBEDDED_LICENSE_CONFIG',
    '/reference:System.dll',
    '/reference:System.Core.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Management.dll',
    '/reference:System.Web.Extensions.dll',
    '/reference:System.Windows.Forms.dll',
    (Join-Path $rootFull 'packaging\ZTool.License\LicenseGate.cs'),
    (Join-Path $rootFull 'packaging\ZTool.License\Properties\AssemblyInfo.cs'),
    $generatedConfig
)
Invoke-Csc $licenseArgs
Protect-LicenseAssembly $licenseDll $snkFull
Assert-StrongNameOk $licenseDll

$deactivateExe = Join-Path $outputRootFull 'ZTool License Deactivate.exe'
$deactivateArgs = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/debug:pdbonly',
    "/keyfile:$snkFull",
    "/out:$deactivateExe",
    '/reference:System.dll',
    '/reference:System.Windows.Forms.dll',
    "/reference:$licenseDll",
    (Join-Path $rootFull 'packaging\ZTool.LicenseDeactivate\Program.cs')
)
Invoke-Csc $deactivateArgs
Assert-StrongNameOk $deactivateExe

$updateStub = Join-Path $outputRootFull 'ZTool.UpdateDisabled.exe'
$updateArgs = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/debug:pdbonly',
    "/keyfile:$snkFull",
    "/out:$updateStub",
    '/reference:System.dll',
    '/reference:System.Windows.Forms.dll',
    (Join-Path $rootFull 'packaging\ZTool.UpdateDisabled\Program.cs'),
    (Join-Path $rootFull 'packaging\ZTool.UpdateDisabled\Properties\AssemblyInfo.cs')
)
Invoke-Csc $updateArgs
Assert-StrongNameOk $updateStub

$publicKeyFingerprint = if ([string]::IsNullOrWhiteSpace($PublicKeyXml)) {
    ''
} else {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PublicKeyXml)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToUpperInvariant()
    } finally {
        $sha.Dispose()
    }
}

$manifest = [pscustomobject]@{
    CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Production = -not [string]::IsNullOrWhiteSpace($PublicKeyXml)
    LicenseBaseUrl = $LicenseBaseUrl.TrimEnd('/')
    ActivationHelpUrl = $activationHelpUrlResolved
    PublicKeySha256 = $publicKeyFingerprint
    SourcePath = Get-RelativePath $outputRootFull (Join-Path $rootFull 'packaging\ZTool.License\LicenseGate.cs')
    SnkPath = $snkFull
    Artifacts = [pscustomobject]@{
        LicenseDll = [pscustomobject]@{
            Path = 'ZTool.License.dll'
            Sha256 = Get-FileSha256 $licenseDll
        }
        DeactivateExe = [pscustomobject]@{
            Path = 'ZTool License Deactivate.exe'
            Sha256 = Get-FileSha256 $deactivateExe
        }
        UpdateDisabledExe = [pscustomobject]@{
            Path = 'ZTool.UpdateDisabled.exe'
            Sha256 = Get-FileSha256 $updateStub
        }
    }
}

$runtimeManifest = Join-Path $outputRootFull 'ZTool.ProductionRuntime.provenance.json'
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $runtimeManifest -Encoding UTF8

$licenseProvenance = [pscustomobject]@{
    CreatedAtUtc = $manifest.CreatedAtUtc
    Production = $manifest.Production
    Sha256 = $manifest.Artifacts.LicenseDll.Sha256
    SourcePath = Get-RelativePath (Split-Path -Parent $licenseDll) (Join-Path $rootFull 'packaging\ZTool.License\LicenseGate.cs')
    LicenseBaseUrl = $LicenseBaseUrl.TrimEnd('/')
    ActivationHelpUrl = $activationHelpUrlResolved
    PublicKeySha256 = $publicKeyFingerprint
}
$licenseProvenance | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$licenseDll.provenance.json" -Encoding UTF8

Remove-Item -LiteralPath $generatedConfig -Force -ErrorAction SilentlyContinue

[pscustomobject]@{
    Status = 'ok'
    OutputRoot = $outputRootFull
    LicenseDll = $licenseDll
    DeactivateExe = $deactivateExe
    UpdateDisabledExe = $updateStub
    Manifest = $runtimeManifest
    Production = $manifest.Production
    PublicKeySha256 = $publicKeyFingerprint
} | ConvertTo-Json -Depth 4
