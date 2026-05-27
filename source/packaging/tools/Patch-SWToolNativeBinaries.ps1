param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$ProductName = 'SWTool',

    [ValidateSet('Russian', 'English')]
    [string]$DefaultLanguage = 'Russian',

    [switch]$PatchPayloadStrings,

    [switch]$PatchAddInStrings,

    [string]$SnkPath = ''
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
    $root = Resolve-FullPath (Join-Path $PSScriptRoot '..\..')
    $candidate = Join-Path $root '_archive\_reverse\packages\dnlib\lib\net45\dnlib.dll'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    throw "dnlib.dll not found: $candidate"
}

function Get-DefaultSnkPath {
    $root = Resolve-FullPath (Join-Path $PSScriptRoot '..\..')
    Join-Path $root '_archive\_reverse\prototype-resign\ZToolFork3.snk'
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

function Test-StrongNameSignature([string]$Path) {
    if (-not ('SWToolNativeStrongNameNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class SWToolNativeStrongNameNative {
  [DllImport("mscoree.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool StrongNameSignatureVerificationEx(string wszFilePath, bool fForceVerification,
      ref bool pfWasVerified);
}
'@
    }

    $wasVerified = $false
    $ok = [SWToolNativeStrongNameNative]::StrongNameSignatureVerificationEx($Path, $true, [ref]$wasVerified)
    [pscustomobject]@{
        Ok = $ok
        WasVerified = $wasVerified
        Win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    }
}

function Assert-StrongNameOk([string]$Path) {
    $result = Test-StrongNameSignature $Path
    if (-not $result.Ok -or -not $result.WasVerified) {
        throw "Strong-name verification failed for $Path (Win32Error=$($result.Win32Error))."
    }
}

function ConvertFrom-ZToolPayloadResource([byte[]]$EncryptedPayload) {
    $des = [System.Security.Cryptography.DES]::Create()
    $des.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $des.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $des.Key = [byte[]](0x21,0x1B,0x53,0x5B,0x11,0x12,0x2D,0x4C)
    $des.IV = [byte[]](0x35,0x27,0x13,0x26,0x63,0x16,0x2F,0x34)
    $decryptor = $des.CreateDecryptor()
    try {
        $plain = $decryptor.TransformFinalBlock($EncryptedPayload, 0, $EncryptedPayload.Length)
    } finally {
        $decryptor.Dispose()
        $des.Dispose()
    }

    $base64 = [System.Text.Encoding]::UTF8.GetString($plain).TrimStart([char]0xFEFF).Trim()
    [Convert]::FromBase64String($base64)
}

function ConvertTo-ZToolPayloadResource([byte[]]$Payload) {
    $base64 = [Convert]::ToBase64String($Payload)
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    $plain = [byte[]](@($utf8Bom.GetPreamble()) + @($utf8Bom.GetBytes($base64)))

    $des = [System.Security.Cryptography.DES]::Create()
    $des.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $des.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $des.Key = [byte[]](0x21,0x1B,0x53,0x5B,0x11,0x12,0x2D,0x4C)
    $des.IV = [byte[]](0x35,0x27,0x13,0x26,0x63,0x16,0x2F,0x34)
    $encryptor = $des.CreateEncryptor()
    try {
        $encryptor.TransformFinalBlock($plain, 0, $plain.Length)
    } finally {
        $encryptor.Dispose()
        $des.Dispose()
    }
}

function Read-EmbeddedResourceBytes([dnlib.DotNet.ModuleDefMD]$Module, [string]$ResourceName) {
    foreach ($resource in $Module.Resources) {
        $embedded = $resource -as [dnlib.DotNet.EmbeddedResource]
        if ($null -eq $embedded -or [string]$embedded.Name -ne $ResourceName) {
            continue
        }

        $reader = $embedded.CreateReader()
        return $reader.ReadBytes([int]$reader.Length)
    }

    throw "Embedded resource not found: $ResourceName"
}

function Set-EmbeddedResourceBytes([dnlib.DotNet.ModuleDefMD]$Module, [string]$ResourceName, [byte[]]$Bytes) {
    for ($i = 0; $i -lt $Module.Resources.Count; $i++) {
        $embedded = $Module.Resources[$i] -as [dnlib.DotNet.EmbeddedResource]
        if ($null -eq $embedded -or [string]$embedded.Name -ne $ResourceName) {
            continue
        }

        $Module.Resources[$i] = [dnlib.DotNet.EmbeddedResource]::new($embedded.Name, $Bytes, $embedded.Attributes)
        return
    }

    throw "Embedded resource not found while writing: $ResourceName"
}

function Assert-ModuleCctorUnchanged([dnlib.DotNet.ModuleDefMD]$Before, [dnlib.DotNet.ModuleDefMD]$After, [string]$Label) {
    $beforeType = $Before.GlobalType
    $afterType = $After.GlobalType
    $beforeCctor = $beforeType.FindStaticConstructor()
    $afterCctor = $afterType.FindStaticConstructor()
    if (($null -eq $beforeCctor) -and ($null -eq $afterCctor)) {
        return
    }
    if (($null -eq $beforeCctor) -or ($null -eq $afterCctor)) {
        throw "$Label <Module>.cctor presence changed."
    }

    $beforeText = ($beforeCctor.Body.Instructions | ForEach-Object { "$($_.OpCode)|$($_.Operand)" }) -join "`n"
    $afterText = ($afterCctor.Body.Instructions | ForEach-Object { "$($_.OpCode)|$($_.Operand)" }) -join "`n"
    if ($beforeText -ne $afterText) {
        throw "$Label <Module>.cctor changed. Native patcher refuses this because it previously caused InvalidProgramException."
    }
}

function Write-ModulePreservingMetadata(
    [dnlib.DotNet.ModuleDefMD]$Module,
    [string]$OutputPath,
    [dnlib.DotNet.StrongNameKey]$StrongNameKey = $null
) {
    $options = [dnlib.DotNet.Writer.ModuleWriterOptions]::new($Module)
    $options.Logger = [dnlib.DotNet.DummyLogger]::NoThrowInstance
    $options.MetadataOptions.Flags = $options.MetadataOptions.Flags -bor [dnlib.DotNet.Writer.MetadataFlags]::PreserveAll
    if ($null -ne $StrongNameKey) {
        $options.InitializeStrongNameSigning($Module, $StrongNameKey)
    }
    $Module.Write($OutputPath, $options)
}

function Get-AssemblyTokenHex([string]$Path) {
    $name = [System.Reflection.AssemblyName]::GetAssemblyName($Path)
    $token = $name.GetPublicKeyToken()
    if ($null -eq $token -or $token.Length -eq 0) {
        return ''
    }

    -join ($token | ForEach-Object { $_.ToString('x2') })
}

function Get-NativeStringMap([string]$Language, [string]$ProductName) {
    $map = [ordered]@{}
    $map['ZTool'] = $ProductName
    $map['ZTool 3.8.4'] = "$ProductName 1.1"
    $map['ZTool 3.8.5'] = "$ProductName 1.1"

    if ($Language -eq 'Russian') {
        $map['连接SW'] = 'Подключить SW'
        $map['保存到SW'] = 'Сохранить в SW'
        $map['关闭文档'] = 'Закрыть документ'
        $map['开始'] = 'Главная'
        $map['明细表'] = 'BOM'
        $map['打包'] = 'Пакет'
        $map['工具'] = 'Инструменты'
        $map['试用'] = 'Демо'
        $map['注册'] = 'Активировать'
        $map['取消'] = 'Отмена'
        $map['未检测到有效许可!'] = 'Лицензия не найдена.'
        $map['检测更新'] = 'Проверка обновлений'
        $map['发现新版本！'] = 'Доступна новая версия.'
        $map['下载更新'] = 'Скачать обновление'
        $map['帮助'] = 'Справка'
        $map['关于'] = 'О программе'
        $map['选项'] = 'Опции'
        $map['设置属性名称'] = 'Имена свойств'
        $map['单位'] = 'Ед. изм.'
        $map['自定义规则'] = 'Свои правила'
        $map['快速筛选'] = 'Быстрый фильтр'
        $map['显示复选框'] = 'Показать флажки'
        $map['包含符合项'] = 'Включая совпадения'
        $map['填充文件名'] = 'Заполнить имя файла'
        $map['拆分列'] = 'Разделить столбец'
        $map['查找和替换'] = 'Найти и заменить'
        $map['前后缀'] = 'Преф./суф.'
        $map['符号'] = 'Символы'
        $map['复制列'] = 'Копировать столбец'
        $map['填充列'] = 'Заполнить столбец'
        $map['对比列'] = 'Сравнить столбцы'
        $map['互换列'] = 'Поменять столбцы'
        $map['自定义排序'] = 'Своя сортировка'
        $map['标记重复项'] = 'Отметить дубли'
        $map['冻结列'] = 'Закрепить столбцы'
        $map['隐藏/显示列'] = 'Скрыть/показать столбцы'
        $map['行高：'] = 'Высота строки:'
        $map['行高'] = 'Высота строки'
    } else {
        $map['连接SW'] = 'Connect SW'
        $map['保存到SW'] = 'Save to SW'
        $map['关闭文档'] = 'Close document'
        $map['开始'] = 'Home'
        $map['明细表'] = 'BOM'
        $map['打包'] = 'Package'
        $map['工具'] = 'Tools'
        $map['试用'] = 'Demo'
        $map['注册'] = 'Activate'
        $map['取消'] = 'Cancel'
        $map['未检测到有效许可!'] = 'No valid license found.'
        $map['检测更新'] = 'Check updates'
        $map['发现新版本！'] = 'A new version is available.'
        $map['下载更新'] = 'Download update'
        $map['帮助'] = 'Help'
        $map['关于'] = 'About'
        $map['选项'] = 'Options'
        $map['设置属性名称'] = 'Property names'
        $map['单位'] = 'Units'
        $map['自定义规则'] = 'Custom rules'
        $map['快速筛选'] = 'Quick filter'
        $map['显示复选框'] = 'Show checkboxes'
        $map['包含符合项'] = 'Include matches'
        $map['填充文件名'] = 'Fill file name'
        $map['拆分列'] = 'Split column'
        $map['查找和替换'] = 'Find and replace'
        $map['前后缀'] = 'Prefix/suffix'
        $map['符号'] = 'Symbols'
        $map['复制列'] = 'Copy column'
        $map['填充列'] = 'Fill column'
        $map['对比列'] = 'Compare columns'
        $map['互换列'] = 'Swap columns'
        $map['自定义排序'] = 'Custom sort'
        $map['标记重复项'] = 'Mark duplicates'
        $map['冻结列'] = 'Freeze columns'
        $map['隐藏/显示列'] = 'Show/hide columns'
        $map['行高：'] = 'Row height:'
        $map['行高'] = 'Row height'
    }

    return $map
}

function Patch-LdstrStrings([dnlib.DotNet.ModuleDefMD]$Module, [hashtable]$Map) {
    $patched = New-Object System.Collections.Generic.List[string]
    foreach ($type in $Module.GetTypes()) {
        foreach ($method in $type.Methods) {
            if (-not $method.HasBody) {
                continue
            }

            foreach ($instruction in $method.Body.Instructions) {
                if ($instruction.OpCode -ne [dnlib.DotNet.Emit.OpCodes]::Ldstr) {
                    continue
                }

                $value = [string]$instruction.Operand
                if ($Map.Contains($value)) {
                    $newValue = [string]$Map[$value]
                    if ($value -ne $newValue) {
                        $instruction.Operand = $newValue
                        $patched.Add("$value => $newValue")
                    }
                }
            }

            $method.Body.SimplifyMacros($method.Parameters)
            $method.Body.OptimizeMacros()
        }
    }

    return @($patched | Select-Object -Unique)
}

function Test-ManagedModuleLoad([string]$Path) {
    $module = [dnlib.DotNet.ModuleDefMD]::Load($Path)
    try {
        $null = $module.Types.Count
    } finally {
        $module.Dispose()
    }
}

function Assert-NetFrameworkTypeLoad([string]$Path, [string]$TypeName) {
    $encodedPath = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Path))
    $encodedType = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($TypeName))
    $script = @"
`$ErrorActionPreference = 'Stop'
`$path = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedPath'))
`$typeName = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedType'))
`$assembly = [Reflection.Assembly]::LoadFrom(`$path)
`$type = `$assembly.GetType(`$typeName, `$true)
if (`$null -eq `$type) { throw "Type not found: `$typeName" }
"@
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $script 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ".NET Framework type-load validation failed for $Path ($TypeName): $($output -join ' ')"
    }
}

function Test-NativeRuntimeStarts([string]$ExePath) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ExePath
    $psi.WorkingDirectory = [System.IO.Path]::GetDirectoryName($ExePath)
    $psi.Arguments = '33 0 0 0'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        if ($process.WaitForExit(5000)) {
            $stderr = $process.StandardError.ReadToEnd()
            $stdout = $process.StandardOutput.ReadToEnd()
            if ($process.ExitCode -ne 0) {
                throw "Native runtime start failed with exit code $($process.ExitCode). $stderr $stdout"
            }
        } else {
            try {
                $process.Kill()
            } catch {
            }
        }
    } finally {
        $process.Dispose()
        Get-Process ZTool -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

$packageFull = Resolve-FullPath $PackageRoot
if (-not (Test-Path -LiteralPath $packageFull -PathType Container)) {
    throw "PackageRoot not found: $packageFull"
}

Ensure-DnlibLoaded

$snkFull = ''
$strongNameKey = $null
if ($PatchAddInStrings -or $PatchPayloadStrings) {
    if ([string]::IsNullOrWhiteSpace($SnkPath)) {
        $SnkPath = Get-DefaultSnkPath
    }
    $snkFull = Resolve-FullPath $SnkPath
    if (-not (Test-Path -LiteralPath $snkFull -PathType Leaf)) {
        throw "SNK not found: $snkFull"
    }
    $strongNameKey = [dnlib.DotNet.StrongNameKey]::new($snkFull)
}

$exePath = Join-Path $packageFull 'ZTool.exe'
$dllPath = Join-Path $packageFull 'ZTool.dll'
$settingsPath = Join-Path $packageFull 'ZTool.settings'
foreach ($path in @($exePath, $dllPath, $settingsPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required native package file not found: $path"
    }
}

$beforeHashes = [ordered]@{
    'ZTool.exe' = Get-FileSha256 $exePath
    'ZTool.dll' = Get-FileSha256 $dllPath
    'ZTool.settings' = Get-FileSha256 $settingsPath
}

[xml]$settingsDoc = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
if ($null -eq $settingsDoc.CConfigDO) {
    throw "Invalid ZTool.settings: missing CConfigDO"
}
if ($null -ne $settingsDoc.CConfigDO.SWver) {
    $settingsDoc.CConfigDO.SWver = '0'
}
if ($null -ne $settingsDoc.CConfigDO.GetDataOption) {
    $settingsDoc.CConfigDO.GetDataOption = '0'
}
if ($null -ne $settingsDoc.CConfigDO.checkupdata) {
    $settingsDoc.CConfigDO.checkupdata = 'false'
}
$languageNode = $settingsDoc.SelectSingleNode('/CConfigDO/Language')
if ($null -eq $languageNode) {
    $languageNode = $settingsDoc.CreateElement('Language')
    [void]$settingsDoc.CConfigDO.AppendChild($languageNode)
}
$languageNode.InnerText = $DefaultLanguage
$writerSettings = [System.Xml.XmlWriterSettings]::new()
$writerSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
$writerSettings.Indent = $true
$writerSettings.NewLineChars = "`r`n"
$writer = [System.Xml.XmlWriter]::Create($settingsPath, $writerSettings)
try {
    $settingsDoc.Save($writer)
} finally {
    $writer.Dispose()
}

$resourceName = 'ZTool.9eAd0SlNKphk.png'
$stringMap = Get-NativeStringMap $DefaultLanguage $ProductName
$payloadStringPatches = @()
$addinStringPatches = @()

if ($PatchPayloadStrings) {
    $outerBefore = [dnlib.DotNet.ModuleDefMD]::Load($exePath)
    $payloadTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("swtool-native-payload-" + [guid]::NewGuid().ToString('N') + ".dll")
    $payloadPatched = Join-Path ([System.IO.Path]::GetTempPath()) ("swtool-native-payload-patched-" + [guid]::NewGuid().ToString('N') + ".dll")
    $exePatched = Join-Path ([System.IO.Path]::GetTempPath()) ("swtool-native-exe-" + [guid]::NewGuid().ToString('N') + ".exe")
    $copyPatchedExe = $false
    try {
        $payloadBytes = ConvertFrom-ZToolPayloadResource (Read-EmbeddedResourceBytes $outerBefore $resourceName)
        [System.IO.File]::WriteAllBytes($payloadTemp, $payloadBytes)
        $payloadBefore = [dnlib.DotNet.ModuleDefMD]::Load($payloadTemp)
        $payloadModule = [dnlib.DotNet.ModuleDefMD]::Load($payloadTemp)
        try {
            $payloadStringPatches = @(Patch-LdstrStrings $payloadModule $stringMap)
            Assert-ModuleCctorUnchanged $payloadBefore $payloadModule 'payload'
            Write-ModulePreservingMetadata $payloadModule $payloadPatched
        } finally {
            $payloadModule.Dispose()
            $payloadBefore.Dispose()
        }

        Test-ManagedModuleLoad $payloadPatched
        Set-EmbeddedResourceBytes $outerBefore $resourceName (ConvertTo-ZToolPayloadResource ([System.IO.File]::ReadAllBytes($payloadPatched)))
        $outerAfterTemp = [dnlib.DotNet.ModuleDefMD]::Load($exePath)
        try {
            Assert-ModuleCctorUnchanged $outerAfterTemp $outerBefore 'outer'
        } finally {
            $outerAfterTemp.Dispose()
        }
        Write-ModulePreservingMetadata $outerBefore $exePatched
        Test-ManagedModuleLoad $exePatched
        $copyPatchedExe = $true
    } finally {
        $outerBefore.Dispose()
        if ($copyPatchedExe) {
            Copy-Item -LiteralPath $exePatched -Destination $exePath -Force
            Test-NativeRuntimeStarts $exePath
        }
        Remove-Item -LiteralPath $payloadTemp, $payloadPatched, $exePatched -Force -ErrorAction SilentlyContinue
    }
}

if ($PatchAddInStrings) {
    $addinTokenBefore = Get-AssemblyTokenHex $dllPath
    $addinBefore = [dnlib.DotNet.ModuleDefMD]::Load($dllPath)
    $addinModule = [dnlib.DotNet.ModuleDefMD]::Load($dllPath)
    $dllPatched = Join-Path ([System.IO.Path]::GetTempPath()) ("swtool-native-addin-" + [guid]::NewGuid().ToString('N') + ".dll")
    $copyPatchedDll = $false
    try {
        $addinStringPatches = @(Patch-LdstrStrings $addinModule $stringMap)
        Assert-ModuleCctorUnchanged $addinBefore $addinModule 'addin'
        Write-ModulePreservingMetadata $addinModule $dllPatched $strongNameKey
        Test-ManagedModuleLoad $dllPatched
        Assert-StrongNameOk $dllPatched
        Assert-NetFrameworkTypeLoad $dllPatched 'ZTool.SwAddin'
        $copyPatchedDll = $true
    } finally {
        $addinModule.Dispose()
        $addinBefore.Dispose()
        if ($copyPatchedDll) {
            Copy-Item -LiteralPath $dllPatched -Destination $dllPath -Force
        }
        Remove-Item -LiteralPath $dllPatched -Force -ErrorAction SilentlyContinue
    }
    $addinTokenAfter = Get-AssemblyTokenHex $dllPath
} else {
    $addinTokenBefore = Get-AssemblyTokenHex $dllPath
    $addinTokenAfter = $addinTokenBefore
}

$afterHashes = [ordered]@{
    'ZTool.exe' = Get-FileSha256 $exePath
    'ZTool.dll' = Get-FileSha256 $dllPath
    'ZTool.settings' = Get-FileSha256 $settingsPath
}

$result = [pscustomobject]@{
    Status = 'ok'
    PackageRoot = $packageFull
    ProductName = $ProductName
    DefaultLanguage = $DefaultLanguage
    PatchPayloadStrings = [bool]$PatchPayloadStrings
    PatchAddInStrings = [bool]$PatchAddInStrings
    SnkPath = $snkFull
    AddInPublicKeyTokenBefore = $addinTokenBefore
    AddInPublicKeyTokenAfter = $addinTokenAfter
    BeforeHashes = $beforeHashes
    AfterHashes = $afterHashes
    Patched = @(
        'ZTool.settings: SWver=0'
        'ZTool.settings: GetDataOption=0'
        'ZTool.settings: checkupdata=false'
        "ZTool.settings: Language=$DefaultLanguage"
    ) + @($payloadStringPatches | ForEach-Object { "payload ldstr: $_" }) +
        @($addinStringPatches | ForEach-Object { "addin ldstr: $_" })
}

$result | ConvertTo-Json -Depth 6
