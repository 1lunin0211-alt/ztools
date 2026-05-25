param(
    [switch]$RemoveLegacy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-SolidWorksVersionAddInPaths([string]$GuidText) {
    $paths = New-Object System.Collections.Generic.List[string]
    $paths.Add("HKLM:\SOFTWARE\SolidWorks\AddIns\$GuidText")

    $solidWorksRoot = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\SolidWorks')
    try {
        if ($null -ne $solidWorksRoot) {
            foreach ($name in $solidWorksRoot.GetSubKeyNames()) {
                if ($name -like 'SOLIDWORKS *') {
                    $paths.Add("HKLM:\SOFTWARE\SolidWorks\$name\Addins\$GuidText")
                }
            }
        }
    } finally {
        if ($solidWorksRoot) { $solidWorksRoot.Dispose() }
    }

    $paths
}

if (-not (Test-IsAdministrator)) {
    throw 'SolidWorks add-in unregistration requires elevated PowerShell because HKLM/HKCR are updated.'
}

$addInGuid = '{59959DFA-3229-4B86-852E-52ABF2BDB8C0}'
$paths = @(Get-SolidWorksVersionAddInPaths $addInGuid)
$paths += @(
    "HKCU:\Software\SolidWorks\AddInsStartup\$addInGuid",
    "Registry::HKEY_CLASSES_ROOT\ZTool.SwAddin",
    "Registry::HKEY_CLASSES_ROOT\CLSID\$addInGuid"
)

if ($RemoveLegacy) {
    $legacyGuid = '{F1F2349B-53CF-4F8B-9240-7F3F2F399E32}'
    $paths += @(Get-SolidWorksVersionAddInPaths $legacyGuid)
    $paths += @(
        "HKCU:\Software\SolidWorks\AddInsStartup\$legacyGuid",
        "Registry::HKEY_CLASSES_ROOT\SWTools.SolidWorksAddIn",
        "Registry::HKEY_CLASSES_ROOT\CLSID\$legacyGuid",
        'Registry::HKEY_CLASSES_ROOT\ZTool.SolidWorks.AddIn.SwAddin',
        'Registry::HKEY_CLASSES_ROOT\ZToolRussianFork.SolidWorksAddIn'
    )
}

foreach ($path in $paths) {
    Remove-Key $path
}

[pscustomobject]@{
    Status = 'unregistered'
    AddInGuid = $addInGuid
    RemovedPaths = $paths
} | ConvertTo-Json -Depth 4
