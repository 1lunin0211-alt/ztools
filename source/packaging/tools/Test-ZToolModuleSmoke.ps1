param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot
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

function Get-EmbeddedResourceBytes([string]$Path, [string]$ResourceName) {
    Ensure-DnlibLoaded

    $module = [dnlib.DotNet.ModuleDefMD]::Load($Path)
    try {
        foreach ($resource in $module.Resources) {
            $embedded = $resource -as [dnlib.DotNet.EmbeddedResource]
            if ($null -eq $embedded -or [string]$resource.Name -ne $ResourceName) {
                continue
            }

            $reader = $embedded.CreateReader()
            return $reader.ReadBytes([int]$reader.Length)
        }
    } finally {
        $module.Dispose()
    }

    throw "Embedded resource not found: $ResourceName"
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

function Get-CscPath {
    $command = Get-Command csc.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidate = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    throw 'csc.exe was not found.'
}

$packageFull = Resolve-FullPath $PackageRoot
$ztoolExe = Join-Path $packageFull 'ZTool.exe'
if (-not (Test-Path -LiteralPath $ztoolExe -PathType Leaf)) {
    throw "ZTool.exe not found: $ztoolExe"
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ztool-module-smoke-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

try {
    Get-ChildItem -LiteralPath $packageFull -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $tempDir -Recurse -Force
    }

    $payloadBytes = ConvertFrom-ZToolPayloadResource (Get-EmbeddedResourceBytes $ztoolExe 'ZTool.9eAd0SlNKphk.png')
    $payloadPath = Join-Path $tempDir 'ZTool.Payload.exe'
    [System.IO.File]::WriteAllBytes($payloadPath, $payloadBytes)

    $harnessPath = Join-Path $tempDir 'ZToolModuleSmokeHarness.cs'
    $harnessExe = Join-Path $tempDir 'ZToolModuleSmokeHarness.exe'
    $harnessSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows.Forms;

public static class ZToolModuleSmokeHarness
{
    private static Assembly payloadAssembly;
    private static string baseDir;

    [STAThread]
    public static int Main(string[] args)
    {
        baseDir = args[0];
        string payloadPath = args[1];
        AppDomain.CurrentDomain.AssemblyResolve += ResolveAssembly;
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        payloadAssembly = Assembly.LoadFrom(payloadPath);
        Assembly addinAssembly = null;
        string addinPath = Path.Combine(baseDir, "ZTool.dll");
        if (File.Exists(addinPath))
        {
            addinAssembly = Assembly.LoadFrom(addinPath);
        }

        var formResults = new List<object>();
        int formTypes = 0;
        int instantiatedForms = 0;
        int failedForms = 0;

        foreach (var type in payloadAssembly.GetTypes().OrderBy(t => t.FullName))
        {
            if (!typeof(Form).IsAssignableFrom(type) || type.IsAbstract)
            {
                continue;
            }

            formTypes++;
            var ctor = type.GetConstructor(Type.EmptyTypes);
            if (ctor == null)
            {
                formResults.Add(new { Type = type.FullName, Status = "skipped-no-default-ctor" });
                continue;
            }

            try
            {
                using (var form = (Form)ctor.Invoke(null))
                {
                    instantiatedForms++;
                    formResults.Add(new { Type = type.FullName, Status = "ok", Text = form.Text, Controls = form.Controls.Count });
                }
            }
            catch (Exception ex)
            {
                failedForms++;
                var root = ex;
                while (root.InnerException != null) root = root.InnerException;
                formResults.Add(new { Type = type.FullName, Status = "fail", Error = root.GetType().FullName + ": " + root.Message });
            }
        }

        var swAddin = addinAssembly == null ? null : addinAssembly.GetType("ZTool.SwAddin", false);
        int swPublicMethods = 0;
        int swMenuMethods = 0;
        int swCommandMethods = 0;
        var swMethodNames = new List<string>();
        if (swAddin != null)
        {
            foreach (var method in swAddin.GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.DeclaredOnly))
            {
                swPublicMethods++;
                swMethodNames.Add(method.Name);
                if (method.Name.StartsWith("Menu", StringComparison.OrdinalIgnoreCase))
                {
                    swMenuMethods++;
                }
                if (method.Name.IndexOf("Execute", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    method.Name.IndexOf("Command", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    method.Name.StartsWith("Menu", StringComparison.OrdinalIgnoreCase))
                {
                    swCommandMethods++;
                }
            }
        }

        var resourceNames = payloadAssembly.GetManifestResourceNames();
        var embeddedDlls = resourceNames.Where(n => n.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)).OrderBy(n => n).ToArray();
        var result = new
        {
            Status = failedForms == 0 ? "ok" : "fail",
            Payload = payloadAssembly.FullName,
            FormTypes = formTypes,
            InstantiatedForms = instantiatedForms,
            FailedForms = failedForms,
            SwAddinFound = swAddin != null,
            AddinAssembly = addinAssembly == null ? "" : addinAssembly.FullName,
            SwAddinPublicMethods = swPublicMethods,
            SwAddinMenuMethods = swMenuMethods,
            SwAddinCommandLikeMethods = swCommandMethods,
            SwAddinMethodNames = swMethodNames.OrderBy(n => n).ToArray(),
            EmbeddedDlls = embeddedDlls,
            FormResults = formResults
        };

        Console.WriteLine(ToJson(result));
        return failedForms == 0 ? 0 : 2;
    }

    private static Assembly ResolveAssembly(object sender, ResolveEventArgs args)
    {
        var requested = new AssemblyName(args.Name);
        foreach (var loaded in AppDomain.CurrentDomain.GetAssemblies())
        {
            if (string.Equals(loaded.GetName().Name, requested.Name, StringComparison.OrdinalIgnoreCase))
            {
                return loaded;
            }
        }

        string diskPath = Path.Combine(baseDir, requested.Name + ".dll");
        if (File.Exists(diskPath))
        {
            return Assembly.LoadFrom(diskPath);
        }

        if (payloadAssembly != null)
        {
            foreach (var resourceName in payloadAssembly.GetManifestResourceNames())
            {
                if (!resourceName.EndsWith(requested.Name + ".dll", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                using (var stream = payloadAssembly.GetManifestResourceStream(resourceName))
                using (var ms = new MemoryStream())
                {
                    stream.CopyTo(ms);
                    return Assembly.Load(ms.ToArray());
                }
            }
        }

        return null;
    }

    private static string ToJson(object value)
    {
        var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
        serializer.MaxJsonLength = int.MaxValue;
        return serializer.Serialize(value);
    }
}
'@
    [System.IO.File]::WriteAllText($harnessPath, $harnessSource, [System.Text.Encoding]::UTF8)

    $csc = Get-CscPath
    & $csc /nologo /target:exe /out:$harnessExe /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll $harnessPath
    if ($LASTEXITCODE -ne 0) {
        throw "Module smoke harness compilation failed with exit code $LASTEXITCODE."
    }

    $output = & $harnessExe $tempDir $payloadPath
    $exitCode = $LASTEXITCODE
    $result = ($output | ForEach-Object { [string]$_ }) -join "`n" | ConvertFrom-Json
    if ($exitCode -ne 0 -and $result.Status -eq 'ok') {
        throw "Module smoke harness failed with exit code $exitCode."
    }

    $result | ConvertTo-Json -Depth 8
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
