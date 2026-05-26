param(
    [string]$PackageRoot = '',
    [switch]$NoLoadAtStartup,
    [switch]$RemoveLegacy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-Key([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Set-DefaultRegistryValue([string]$Path, [object]$Value, [Microsoft.Win32.RegistryValueKind]$Kind) {
    $key = [Microsoft.Win32.Registry]::ClassesRoot.CreateSubKey($Path)
    try {
        $key.SetValue('', $Value, $Kind)
    } finally {
        if ($key) { $key.Dispose() }
    }
}

function Set-RegistryValue([Microsoft.Win32.RegistryKey]$Key, [string]$Name, [object]$Value, [Microsoft.Win32.RegistryValueKind]$Kind) {
    $Key.SetValue($Name, $Value, $Kind)
}

function Get-SolidWorksVersionAddInSubPaths([string]$GuidText) {
    $paths = New-Object System.Collections.Generic.List[string]
    $paths.Add("SOFTWARE\SolidWorks\AddIns\$GuidText")

    $solidWorksRoot = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\SolidWorks')
    try {
        if ($null -ne $solidWorksRoot) {
            foreach ($name in $solidWorksRoot.GetSubKeyNames()) {
                if ($name -like 'SOLIDWORKS *') {
                    $paths.Add("SOFTWARE\SolidWorks\$name\Addins\$GuidText")
                }
            }
        }
    } finally {
        if ($solidWorksRoot) { $solidWorksRoot.Dispose() }
    }

    $paths
}

function Set-SolidWorksAddInRegistration([string]$SubPath, [string]$Title, [string]$Description) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($SubPath)
    try {
        $key.SetValue('', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('Title', $Title, [Microsoft.Win32.RegistryValueKind]::String)
        $key.SetValue('Description', $Description, [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        if ($key) { $key.Dispose() }
    }
}

function Reset-SolidWorksCommandManagerCache {
    $solidWorksRoot = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\SolidWorks')
    try {
        if ($null -eq $solidWorksRoot) {
            return @()
        }

        $removed = New-Object System.Collections.Generic.List[string]
        foreach ($versionName in $solidWorksRoot.GetSubKeyNames()) {
            if ($versionName -notlike 'SOLIDWORKS *') {
                continue
            }

            $uiRootPath = "Software\SolidWorks\$versionName\User Interface"
            foreach ($relativeRoot in @('CommandManager', 'Custom API Toolbars')) {
                $rootPath = "$uiRootPath\$relativeRoot"
                $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($rootPath, $true)
                try {
                    if ($null -eq $root) {
                        continue
                    }

                    $stack = New-Object System.Collections.Generic.Stack[string]
                    $stack.Push('')
                    while ($stack.Count -gt 0) {
                        $relativePath = $stack.Pop()
                        $keyPath = if ([string]::IsNullOrEmpty($relativePath)) { $rootPath } else { "$rootPath\$relativePath" }
                        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($keyPath, $true)
                        try {
                            if ($null -eq $key) {
                                continue
                            }

                            foreach ($childName in $key.GetSubKeyNames()) {
                                $childRelative = if ([string]::IsNullOrEmpty($relativePath)) { $childName } else { "$relativePath\$childName" }
                                $stack.Push($childRelative)
                            }

                            $matches = $false
                            foreach ($valueName in $key.GetValueNames()) {
                                $value = [string]$key.GetValue($valueName, '')
                                if ($value -match 'ZTool|SWTool|SWTools') {
                                    $matches = $true
                                    break
                                }
                            }

                            if ($matches -and -not [string]::IsNullOrEmpty($relativePath)) {
                                $parentRelative = Split-Path -Parent $relativePath
                                $leaf = Split-Path -Leaf $relativePath
                                $parentPath = if ([string]::IsNullOrEmpty($parentRelative)) { $rootPath } else { "$rootPath\$parentRelative" }
                                $parent = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($parentPath, $true)
                                try {
                                    if ($null -ne $parent) {
                                        $parent.DeleteSubKeyTree($leaf, $false)
                                        $removed.Add("HKCU\$keyPath")
                                    }
                                } finally {
                                    if ($parent) { $parent.Dispose() }
                                }
                            }
                        } finally {
                            if ($key) { $key.Dispose() }
                        }
                    }
                } finally {
                    if ($root) { $root.Dispose() }
                }
            }
        }

        return @($removed)
    } finally {
        if ($solidWorksRoot) { $solidWorksRoot.Dispose() }
    }
}

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$packageRootFull = Resolve-FullPath $PackageRoot
$assemblyPath = Join-Path $packageRootFull 'ZTool.dll'
if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
    throw "ZTool.dll was not found: $assemblyPath"
}
$localizerAssemblyPath = Join-Path $packageRootFull 'SWTool.CommandLocalizer.dll'

if (-not (Test-IsAdministrator)) {
    throw 'SolidWorks add-in registration requires elevated PowerShell because HKLM/HKCR are updated.'
}

$assemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($assemblyPath)
$addInGuid = [Guid]'59959DFA-3229-4B86-852E-52ABF2BDB8C0'
$addInGuidText = $addInGuid.ToString('B').ToUpperInvariant()
$className = 'ZTool.SwAddin'
$title = 'SWTool'
$description = 'SWTool - ' + [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0LjQvdGB0YLRgNGD0LzQtdC90YLRiyDQtNC70Y8gU29saWRXb3Jrcw=='))
$codeBase = ([Uri]$assemblyPath).AbsoluteUri
$assemblyFullName = $assemblyName.FullName
$runtimeVersion = 'v4.0.30319'
$loadAtStartup = -not $NoLoadAtStartup

$clsidPath = "CLSID\$addInGuidText"
$inprocPath = "$clsidPath\InprocServer32"
$versionPath = "$inprocPath\$($assemblyName.Version)"
$progIdPath = 'ZTool.SwAddin'

Remove-Key "Registry::HKEY_CLASSES_ROOT\$clsidPath"
Remove-Key "Registry::HKEY_CLASSES_ROOT\$progIdPath"

Set-DefaultRegistryValue $clsidPath $className ([Microsoft.Win32.RegistryValueKind]::String)
Set-DefaultRegistryValue $progIdPath $className ([Microsoft.Win32.RegistryValueKind]::String)
$progIdClsid = [Microsoft.Win32.Registry]::ClassesRoot.CreateSubKey("$progIdPath\CLSID")
try {
    $progIdClsid.SetValue('', $addInGuidText, [Microsoft.Win32.RegistryValueKind]::String)
} finally {
    if ($progIdClsid) { $progIdClsid.Dispose() }
}

foreach ($path in @($inprocPath, $versionPath)) {
    $key = [Microsoft.Win32.Registry]::ClassesRoot.CreateSubKey($path)
    try {
        Set-RegistryValue $key '' 'mscoree.dll' ([Microsoft.Win32.RegistryValueKind]::String)
        Set-RegistryValue $key 'ThreadingModel' 'Both' ([Microsoft.Win32.RegistryValueKind]::String)
        Set-RegistryValue $key 'Class' $className ([Microsoft.Win32.RegistryValueKind]::String)
        Set-RegistryValue $key 'Assembly' $assemblyFullName ([Microsoft.Win32.RegistryValueKind]::String)
        Set-RegistryValue $key 'RuntimeVersion' $runtimeVersion ([Microsoft.Win32.RegistryValueKind]::String)
        Set-RegistryValue $key 'CodeBase' $codeBase ([Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        if ($key) { $key.Dispose() }
    }
}

$solidWorksAddInPaths = @(Get-SolidWorksVersionAddInSubPaths $addInGuidText)
foreach ($solidWorksAddInPath in $solidWorksAddInPaths) {
    Set-SolidWorksAddInRegistration $solidWorksAddInPath $title $description
}

$localizerAddInGuidText = ''
$localizerSolidWorksAddInPaths = @()
if (Test-Path -LiteralPath $localizerAssemblyPath -PathType Leaf) {
    $localizerAssemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($localizerAssemblyPath)
    $localizerAddInGuid = [Guid]'9F5F2805-10D2-4A49-AB0A-2F8279B6B6D1'
    $localizerAddInGuidText = $localizerAddInGuid.ToString('B').ToUpperInvariant()
    $localizerClassName = 'SWTool.CommandLocalizer.CommandLocalizerAddIn'
    $localizerProgIdPath = 'SWTool.CommandLocalizer'
    $localizerCodeBase = ([Uri]$localizerAssemblyPath).AbsoluteUri
    $localizerAssemblyFullName = $localizerAssemblyName.FullName
    $localizerClsidPath = "CLSID\$localizerAddInGuidText"
    $localizerInprocPath = "$localizerClsidPath\InprocServer32"
    $localizerVersionPath = "$localizerInprocPath\$($localizerAssemblyName.Version)"

    Set-DefaultRegistryValue $localizerClsidPath $localizerClassName ([Microsoft.Win32.RegistryValueKind]::String)
    Set-DefaultRegistryValue $localizerProgIdPath $localizerClassName ([Microsoft.Win32.RegistryValueKind]::String)
    $localizerProgIdClsid = [Microsoft.Win32.Registry]::ClassesRoot.CreateSubKey("$localizerProgIdPath\CLSID")
    try {
        $localizerProgIdClsid.SetValue('', $localizerAddInGuidText, [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        if ($localizerProgIdClsid) { $localizerProgIdClsid.Dispose() }
    }

    foreach ($path in @($localizerInprocPath, $localizerVersionPath)) {
        $key = [Microsoft.Win32.Registry]::ClassesRoot.CreateSubKey($path)
        try {
            Set-RegistryValue $key '' 'mscoree.dll' ([Microsoft.Win32.RegistryValueKind]::String)
            Set-RegistryValue $key 'ThreadingModel' 'Both' ([Microsoft.Win32.RegistryValueKind]::String)
            Set-RegistryValue $key 'Class' $localizerClassName ([Microsoft.Win32.RegistryValueKind]::String)
            Set-RegistryValue $key 'Assembly' $localizerAssemblyFullName ([Microsoft.Win32.RegistryValueKind]::String)
            Set-RegistryValue $key 'RuntimeVersion' $runtimeVersion ([Microsoft.Win32.RegistryValueKind]::String)
            Set-RegistryValue $key 'CodeBase' $localizerCodeBase ([Microsoft.Win32.RegistryValueKind]::String)
        } finally {
            if ($key) { $key.Dispose() }
        }
    }

    $localizerSolidWorksAddInPaths = @(Get-SolidWorksVersionAddInSubPaths $localizerAddInGuidText)
    foreach ($solidWorksAddInPath in $localizerSolidWorksAddInPaths) {
        Set-SolidWorksAddInRegistration $solidWorksAddInPath 'SWTool' $description
    }

    $localizerStartupPath = "Software\SolidWorks\AddInsStartup\$localizerAddInGuidText"
    $localizerStartupKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($localizerStartupPath)
    try {
        $localizerStartupKey.SetValue('', [int]$loadAtStartup, [Microsoft.Win32.RegistryValueKind]::DWord)
    } finally {
        if ($localizerStartupKey) { $localizerStartupKey.Dispose() }
    }
}
$commandManagerCacheRemoved = @(Reset-SolidWorksCommandManagerCache)

$startupPath = "Software\SolidWorks\AddInsStartup\$addInGuidText"
$startupKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($startupPath)
try {
    $startupKey.SetValue('', [int]$loadAtStartup, [Microsoft.Win32.RegistryValueKind]::DWord)
} finally {
    if ($startupKey) { $startupKey.Dispose() }
}

if ($RemoveLegacy) {
    $legacyGuid = '{F1F2349B-53CF-4F8B-9240-7F3F2F399E32}'
    $legacyPaths = @(
        "HKLM:\SOFTWARE\SolidWorks\AddIns\$legacyGuid",
        "HKCU:\Software\SolidWorks\AddInsStartup\$legacyGuid",
        "Registry::HKEY_CLASSES_ROOT\SWTools.SolidWorksAddIn",
        "Registry::HKEY_CLASSES_ROOT\CLSID\$legacyGuid",
        'Registry::HKEY_CLASSES_ROOT\ZTool.SolidWorks.AddIn.SwAddin',
        'Registry::HKEY_CLASSES_ROOT\ZToolRussianFork.SolidWorksAddIn'
    )

    $solidWorksRoot = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\SolidWorks')
    try {
        if ($null -ne $solidWorksRoot) {
            foreach ($name in $solidWorksRoot.GetSubKeyNames()) {
                if ($name -like 'SOLIDWORKS *') {
                    $legacyPaths += "HKLM:\SOFTWARE\SolidWorks\$name\Addins\$legacyGuid"
                }
            }
        }
    } finally {
        if ($solidWorksRoot) { $solidWorksRoot.Dispose() }
    }

    foreach ($path in $legacyPaths) {
        Remove-Key $path
    }
}

[pscustomobject]@{
    Status = 'registered'
    PackageRoot = $packageRootFull
    AssemblyPath = $assemblyPath
    AddInGuid = $addInGuidText
    Class = $className
    Assembly = $assemblyFullName
    CodeBase = $codeBase
    LoadAtStartup = $loadAtStartup
    SolidWorksAddInRegistryPaths = $solidWorksAddInPaths
    LocalizerAddInGuid = $localizerAddInGuidText
    LocalizerAssemblyPath = if (Test-Path -LiteralPath $localizerAssemblyPath -PathType Leaf) { $localizerAssemblyPath } else { '' }
    LocalizerSolidWorksAddInRegistryPaths = $localizerSolidWorksAddInPaths
    CommandManagerCacheRemoved = $commandManagerCacheRemoved
} | ConvertTo-Json -Depth 4
