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

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$packageRootFull = Resolve-FullPath $PackageRoot
$assemblyPath = Join-Path $packageRootFull 'ZTool.dll'
if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
    throw "ZTool.dll was not found: $assemblyPath"
}

if (-not (Test-IsAdministrator)) {
    throw 'SolidWorks add-in registration requires elevated PowerShell because HKLM/HKCR are updated.'
}

$assemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($assemblyPath)
$addInGuid = [Guid]'59959DFA-3229-4B86-852E-52ABF2BDB8C0'
$addInGuidText = $addInGuid.ToString('B').ToUpperInvariant()
$className = 'ZTool.SwAddin'
$title = 'ZTool'
$description = 'ZTool - SolidWorks tools'
$codeBase = ([Uri]$assemblyPath).AbsoluteUri
$assemblyFullName = $assemblyName.FullName
$runtimeVersion = 'v4.0.30319'
$loadAtStartup = -not $NoLoadAtStartup

$clsidPath = "CLSID\$addInGuidText"
$inprocPath = "$clsidPath\InprocServer32"
$versionPath = "$inprocPath\$($assemblyName.Version)"
$progIdPath = 'ZTool.SwAddin'

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
} | ConvertTo-Json -Depth 4
