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
    $Global:SwToolPayloadResourceTextRoot = Join-Path $PSScriptRoot '..\payload-resources'
    try {
        return Get-StringMap $SelectedLanguage
    } finally {
        Remove-Variable -Scope Global -Name SwToolPayloadResourceTextRoot -ErrorAction SilentlyContinue
    }
}

$initStringMap = Get-InitStringMap $Language

# Map CJK identifier prefixes (namespaces / type names) to ASCII so the
# resulting assembly contains no CJK metadata. Resign-ZToolInitExe.ps1 applies
# these to type names, resource names, custom attribute arguments, and ldstr
# operands that reference resource baseNames built from the old namespace.
$identifierRenames = [ordered]@{
    # ZTool初始化 (built from codepoints to avoid CJK in this script)
    ([string]::Concat('ZTool', [char]0x521D, [char]0x59CB, [char]0x5316)) = 'ZTool.Init'
    # 初始化 (standalone, used as the original assembly name)
    ([string]::Concat([char]0x521D, [char]0x59CB, [char]0x5316)) = 'ZTool.Init'
}

function Rewrite-Identifier([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    foreach ($k in $identifierRenames.Keys) {
        if ($Value.Contains($k)) {
            $Value = $Value.Replace($k, [string]$identifierRenames[$k])
        }
    }
    return $Value
}

function Has-Cjk([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    foreach ($c in $Value.ToCharArray()) {
        $cp = [int]$c
        if ($cp -ge 0x4E00 -and $cp -le 0x9FFF) { return $true }
    }
    return $false
}

try {
    $module = [dnlib.DotNet.ModuleDefMD]::Load($initExe)
    $repointed = New-Object System.Collections.Generic.List[string]
    $translatedStrings = 0
    $renamedTypes = New-Object System.Collections.Generic.List[string]
    $renamedResources = New-Object System.Collections.Generic.List[string]
    $rewrittenAttributes = New-Object System.Collections.Generic.List[string]
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

        # Rename the assembly + module identity if they contain CJK. Nothing in
        # the rest of the production binaries references this assembly by name
        # (decrypted_payload.dll, ZTool.dll and ZTool.exe all have zero CJK-named
        # AssemblyRefs), so renaming the assembly identity is safe.
        if ($null -ne $module.Assembly -and (Has-Cjk ([string]$module.Assembly.Name))) {
            $oldAsmName = [string]$module.Assembly.Name
            $newAsmName = Rewrite-Identifier $oldAsmName
            if (Has-Cjk $newAsmName) {
                $newAsmName = ($newAsmName -creplace '[\u4E00-\u9FFF]+', '_cjk_')
            }
            $module.Assembly.Name = [dnlib.DotNet.UTF8String]::new($newAsmName)
            $renamedTypes.Add("(Assembly) $oldAsmName -> $newAsmName")
        }
        if (Has-Cjk ([string]$module.Name)) {
            $oldModName = [string]$module.Name
            $newModName = Rewrite-Identifier $oldModName
            if (Has-Cjk $newModName) {
                $newModName = ($newModName -creplace '[\u4E00-\u9FFF]+', '_cjk_')
            }
            # The module name conventionally matches the on-disk file name.
            # Init.exe is always written as ZTool.Init.exe in the package, so
            # align the module name with the on-disk identity.
            if (-not $newModName.ToLowerInvariant().EndsWith('.exe') -and -not $newModName.ToLowerInvariant().EndsWith('.dll')) {
                $newModName = $newModName + '.exe'
            }
            $module.Name = [dnlib.DotNet.UTF8String]::new('ZTool.Init.exe')
            $renamedTypes.Add("(Module) $oldModName -> ZTool.Init.exe")
        }

        # Rename CJK types and namespaces. dnlib re-resolves TypeDef references by
        # token at write time, so updating Name/Namespace is sufficient — internal
        # IL references to the renamed type (castclass, newobj, ldsfld, etc.) keep
        # pointing to the same metadata token.
        foreach ($type in $module.GetTypes()) {
            $oldFull = $type.FullName
            if (Has-Cjk $oldFull) {
                $newNs = Rewrite-Identifier ([string]$type.Namespace)
                $newName = Rewrite-Identifier ([string]$type.Name)
                if (Has-Cjk $newNs -or Has-Cjk $newName) {
                    # Fall back: prefix any remaining CJK so the metadata is ASCII
                    # even if the rename table missed something.
                    $newNs = ($newNs -creplace '[\u4E00-\u9FFF]+', '_cjk_')
                    $newName = ($newName -creplace '[\u4E00-\u9FFF]+', '_cjk_')
                }
                $type.Namespace = [dnlib.DotNet.UTF8String]::new($newNs)
                $type.Name = [dnlib.DotNet.UTF8String]::new($newName)
                $renamedTypes.Add("$oldFull -> $($type.FullName)")
            }
        }

        # Rename CJK resource names. The corresponding ldstr that ResourceManager
        # uses as baseName ("ZTool初始化.Resources") is renamed by the ldstr loop
        # below via the same identifier-rename helper.
        foreach ($res in $module.Resources) {
            if (Has-Cjk $res.Name) {
                $oldName = [string]$res.Name
                $newName = Rewrite-Identifier $oldName
                if (Has-Cjk $newName) {
                    $newName = ($newName -creplace '[\u4E00-\u9FFF]+', '_cjk_')
                }
                $res.Name = [dnlib.DotNet.UTF8String]::new($newName)
                $renamedResources.Add("$oldName -> $newName")
            }
        }

        # Translate CJK in assembly-level custom attributes (AssemblyTitle etc.).
        if ($null -ne $module.Assembly) {
            foreach ($ca in $module.Assembly.CustomAttributes) {
                for ($i = 0; $i -lt $ca.ConstructorArguments.Count; $i++) {
                    $arg = $ca.ConstructorArguments[$i]
                    if ($arg.Value -is [dnlib.DotNet.UTF8String]) {
                        $s = $arg.Value.ToString()
                        if (Has-Cjk $s) {
                            $translated = $null
                            if ($initStringMap.Contains($s)) {
                                $translated = [string]$initStringMap[$s]
                            } else {
                                $translated = Rewrite-Identifier $s
                            }
                            if ($translated -ne $s) {
                                $newArg = New-Object dnlib.DotNet.CAArgument($arg.Type, [dnlib.DotNet.UTF8String]::new($translated))
                                $ca.ConstructorArguments[$i] = $newArg
                                $rewrittenAttributes.Add("$($ca.AttributeType.Name): `"$s`" -> `"$translated`"")
                            }
                        }
                    }
                }
            }
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
                    $newVal = $val
                    if ($initStringMap.Contains($newVal)) {
                        $newVal = [string]$initStringMap[$newVal]
                    }
                    # Rewrite identifier references (e.g. ResourceManager baseName).
                    $rewritten = Rewrite-Identifier $newVal
                    if ($rewritten -ne $newVal) {
                        $newVal = $rewritten
                    }
                    if ($newVal -ne $val) {
                        $inst.Operand = $newVal
                        $translatedStrings++
                    }
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
        RenamedTypes = $renamedTypes
        RenamedResources = $renamedResources
        RewrittenAttributes = $rewrittenAttributes
    } | ConvertTo-Json -Depth 4
} finally {
    Remove-Item -LiteralPath $initPatched -Force -ErrorAction SilentlyContinue
}
