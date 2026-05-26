param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$SolidWorksExe = '',

    [string]$ModelPath = '',

    [int]$StartupTimeoutSeconds = 90,

    [int]$CommandTimeoutSeconds = 30,

    [int[]]$CommandTypes = @(0),

    [string]$CommandTypesCsv = '',

    [switch]$ClickDemo,

    [switch]$SkipInitialActivation,

    [ValidateSet('', 'Russian', 'English')]
    [string]$AssertLanguage = '',

    [switch]$KeepExistingZToolBroker,

    [switch]$KeepSolidWorksOpen
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

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-SolidWorksExe {
    $candidates = New-Object System.Collections.Generic.List[string]

    $registryRoots = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\SolidWorks',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\SolidWorks'
    )

    foreach ($root in $registryRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'SOLIDWORKS *' } |
            ForEach-Object {
                $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($_.Name.Substring('HKEY_LOCAL_MACHINE\'.Length))
                try {
                    if ($null -eq $key) {
                        return
                    }

                    foreach ($valueName in @('InstallDir', 'Install Path')) {
                        $value = [string]$key.GetValue($valueName, '')
                        if (-not [string]::IsNullOrWhiteSpace($value)) {
                            $candidates.Add((Join-Path $value 'SLDWORKS.exe'))
                        }
                    }
                } finally {
                    if ($key) { $key.Dispose() }
                }
            }
    }

    $programFiles = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($root in $programFiles) {
        $candidates.Add((Join-Path $root 'SOLIDWORKS Corp\SOLIDWORKS\SLDWORKS.exe'))
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    return ''
}

$packageFull = Resolve-FullPath $PackageRoot
$ztoolDll = Join-Path $packageFull 'ZTool.dll'
if (-not (Test-Path -LiteralPath $ztoolDll -PathType Leaf)) {
    throw "ZTool.dll not found: $ztoolDll"
}
if (-not [string]::IsNullOrWhiteSpace($CommandTypesCsv)) {
    $CommandTypes = @($CommandTypesCsv.Split(',') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [int]($_.Trim()) })
}

if ([string]::IsNullOrWhiteSpace($SolidWorksExe)) {
    $SolidWorksExe = Find-SolidWorksExe
}

if ([string]::IsNullOrWhiteSpace($SolidWorksExe) -or -not (Test-Path -LiteralPath $SolidWorksExe -PathType Leaf)) {
    throw 'SLDWORKS.exe was not found. Pass -SolidWorksExe explicitly or install SOLIDWORKS.'
}
$solidWorksExeFull = [System.IO.Path]::GetFullPath($SolidWorksExe)

if ([string]::IsNullOrWhiteSpace($ModelPath)) {
    $candidateModel = Join-Path $packageFull 'Тестовые модели\0614-A00.SLDASM'
    if (Test-Path -LiteralPath $candidateModel -PathType Leaf) {
        $ModelPath = $candidateModel
    } else {
        $candidateModel = Get-ChildItem -LiteralPath $packageFull -Recurse -Filter '0614-A00.SLDASM' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $candidateModel) {
            $ModelPath = $candidateModel.FullName
        }
    }
}
$modelPathFull = ''
if (-not [string]::IsNullOrWhiteSpace($ModelPath)) {
    $modelPathFull = Resolve-FullPath $ModelPath
    if (-not (Test-Path -LiteralPath $modelPathFull -PathType Leaf)) {
        throw "ModelPath not found: $modelPathFull"
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'This smoke test must run elevated because it registers the SolidWorks add-in under HKLM/HKCR.'
}

$registerScript = Join-Path $packageFull 'Register ZTool SolidWorks AddIn.ps1'
if (-not (Test-Path -LiteralPath $registerScript -PathType Leaf)) {
    $registerScript = Join-Path $PSScriptRoot 'Register-ZToolBinaryForkSolidWorksAddIn.ps1'
}
if (-not (Test-Path -LiteralPath $registerScript -PathType Leaf)) {
    throw 'ZTool SolidWorks add-in registration script was not found.'
}

$registration = & $registerScript -PackageRoot $packageFull -RemoveLegacy | ConvertFrom-Json

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ztool-solidworks-smoke-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

try {
    $harnessPath = Join-Path $tempDir 'ZToolSolidWorksSmokeHarness.cs'
    $harnessExe = Join-Path $tempDir 'ZToolSolidWorksSmokeHarness.exe'
$harnessSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Text.RegularExpressions;
using System.Windows.Automation;

public static class ZToolSolidWorksSmokeHarness
{
    private const int WM_CLOSE = 0x0010;
    private const int BM_CLICK = 0x00F5;

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder className, int count);

    [STAThread]
    public static int Main(string[] args)
    {
        string swExe = args[0];
        string addinPath = args[1];
        string modelPath = args[2];
        string[] commandText = args[3].Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
        var commandTypes = new List<int>();
        foreach (string item in commandText) commandTypes.Add(int.Parse(item));
        int startupTimeoutSeconds = int.Parse(args[4]);
        int commandTimeoutSeconds = int.Parse(args[5]);
        bool clickDemo = string.Equals(args[6], "true", StringComparison.OrdinalIgnoreCase);
        bool skipInitialActivation = string.Equals(args[7], "true", StringComparison.OrdinalIgnoreCase);
        string localizerPath = args[8];
        string assertLanguage = args[9];
        bool keepExistingZToolBroker = string.Equals(args[10], "true", StringComparison.OrdinalIgnoreCase);
        bool keepSolidWorksOpen = string.Equals(args[11], "true", StringComparison.OrdinalIgnoreCase);

        var result = new Dictionary<string, object>();
        var steps = new List<object>();
        bool startedByHarness = false;
        Process swProcess = null;
        object swApp = null;

        try
        {
            swApp = TryGetActiveSolidWorks();
            if (swApp == null)
            {
                if (IsSolidWorksProcessRunning())
                {
                    swApp = WaitForSolidWorks(startupTimeoutSeconds);
                    steps.Add(new { Name = "attach-solidworks", Status = "ok", Detail = "attached-to-running-process" });
                }
            }

            if (swApp == null)
            {
                swProcess = Process.Start(swExe);
                startedByHarness = true;
                steps.Add(new { Name = "start-solidworks", Status = "ok", Detail = swProcess == null ? "" : swProcess.Id.ToString() });
                swApp = WaitForSolidWorks(startupTimeoutSeconds);
            }
            else
            {
                steps.Add(new { Name = "attach-solidworks", Status = "ok" });
            }

            SetProperty(swApp, "Visible", true);
            string revision = Convert.ToString(Invoke(swApp, "RevisionNumber"));
            object processIdValue = Invoke(swApp, "GetProcessID");
            int processId = Convert.ToInt32(processIdValue);
            string executablePath = Convert.ToString(Invoke(swApp, "GetExecutablePath"));
            steps.Add(new { Name = "solidworks-version", Status = "ok", Detail = revision });

            object loadResult = Invoke(swApp, "LoadAddIn", addinPath);
            steps.Add(new { Name = "load-addin", Status = "ok", Detail = Convert.ToString(loadResult) });

            object addinObject = Invoke(swApp, "GetAddInObject", "ZTool.SwAddin");
            if (addinObject == null)
            {
                throw new InvalidOperationException("GetAddInObject returned null.");
            }
            steps.Add(new { Name = "get-addin-object", Status = "ok", Detail = addinObject.GetType().FullName });

            string addinLanguage = "";
            string addinLabels = "";
            string addinTabReport = "";
            string addinLastError = "";
            bool hasDiagnosticMethods = TryInvokeString(addinObject, "GetCurrentLanguage", out addinLanguage) &&
                TryInvokeString(addinObject, "GetCommandLabels", out addinLabels) &&
                TryInvokeString(addinObject, "GetCommandTabReport", out addinTabReport) &&
                TryInvokeString(addinObject, "GetLastError", out addinLastError);

            if (hasDiagnosticMethods)
            {
                steps.Add(new { Name = "command-manager-state", Status = "ok", Detail = addinLanguage + ": " + addinLabels });
                steps.Add(new { Name = "command-manager-tabs", Status = "ok", Detail = addinTabReport });
            }
            else
            {
                steps.Add(new { Name = "command-manager-diagnostics", Status = "skipped", Detail = "native-original-addin" });
            }

            if (hasDiagnosticMethods && !string.IsNullOrWhiteSpace(addinLastError))
            {
                throw new InvalidOperationException("ZTool.SwAddin reported an error: " + addinLastError);
            }

            if (hasDiagnosticMethods &&
                (addinTabReport.IndexOf("SWTool=0", StringComparison.Ordinal) >= 0 ||
                addinTabReport.IndexOf("ZTool=1", StringComparison.Ordinal) >= 0)
               )
            {
                throw new InvalidOperationException("CommandManager tab state is invalid: " + addinTabReport);
            }

            if (hasDiagnosticMethods && !string.IsNullOrWhiteSpace(assertLanguage))
            {
                if (!string.Equals(addinLanguage, assertLanguage, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException("Expected add-in language " + assertLanguage + " but got " + addinLanguage + ".");
                }

                if (string.Equals(assertLanguage, "Russian", StringComparison.OrdinalIgnoreCase))
                {
                    if (addinLabels.IndexOf("Переименование", StringComparison.Ordinal) < 0 ||
                        addinLabels.IndexOf("О программе", StringComparison.Ordinal) < 0)
                    {
                        throw new InvalidOperationException("Russian CommandManager labels are missing: " + addinLabels);
                    }
                }
                else if (string.Equals(assertLanguage, "English", StringComparison.OrdinalIgnoreCase))
                {
                    if (addinLabels.IndexOf("Rename components", StringComparison.Ordinal) < 0 ||
                        addinLabels.IndexOf("About", StringComparison.Ordinal) < 0 ||
                        addinLabels.IndexOf("Переименование", StringComparison.Ordinal) >= 0)
                    {
                        throw new InvalidOperationException("English CommandManager labels are invalid: " + addinLabels);
                    }
                }
            }

            object activeDoc;
            string documentStep;
            if (!string.IsNullOrWhiteSpace(modelPath))
            {
                int errors = 0;
                int warnings = 0;
                object opened = OpenDoc6(swApp, modelPath, GetSolidWorksDocumentType(modelPath), 1, "", ref errors, ref warnings);
                if (opened == null)
                {
                    throw new InvalidOperationException("OpenDoc6 returned null for " + modelPath + "; errors=" + errors + "; warnings=" + warnings);
                }
                documentStep = "open-test-model";
            }
            else
            {
                object newPart = Invoke(swApp, "NewPart");
                if (newPart == null)
                {
                    throw new InvalidOperationException("NewPart returned null.");
                }
                documentStep = "new-part";
            }

            activeDoc = Invoke(swApp, "ActiveDoc");
            if (activeDoc == null)
            {
                throw new InvalidOperationException("ActiveDoc returned null after opening a test document.");
            }
            steps.Add(new { Name = documentStep, Status = "ok", Detail = modelPath });

            if (!keepExistingZToolBroker)
            {
                CloseExistingZToolWindows();
            }
            DateTime commandStartedUtc = DateTime.UtcNow;
            Invoke(addinObject, "openZtool", commandTypes[0]);
            string activationTitle = "";
            string preopenedRuntimeTitle = "";
            if (!skipInitialActivation)
            {
                int firstWindowTimeout = Math.Max(15, commandTimeoutSeconds);
                DateTime waitUntil = DateTime.UtcNow.AddSeconds(firstWindowTimeout);
                while (DateTime.UtcNow < waitUntil)
                {
                    activationTitle = WaitForZToolActivationWindow(commandStartedUtc, 1);
                    if (!string.IsNullOrEmpty(activationTitle))
                    {
                        break;
                    }

                    preopenedRuntimeTitle = WaitForAnyZToolRuntimeWindow(commandStartedUtc, 1);
                    if (!string.IsNullOrWhiteSpace(preopenedRuntimeTitle))
                    {
                        break;
                    }
                }

                if (string.IsNullOrEmpty(activationTitle) && string.IsNullOrWhiteSpace(preopenedRuntimeTitle))
                {
                    throw new InvalidOperationException("openZtool(0) did not create a visible ZTool activation/runtime window.");
                }
            }
            steps.Add(new { Name = "open-ztool-command", Status = "ok", Detail = string.IsNullOrWhiteSpace(preopenedRuntimeTitle) ? activationTitle : preopenedRuntimeTitle });
            AssertNoFrameworkExceptionDialog();

            string demoTitle = "";
            string runtimeTitle = "";
            if (clickDemo)
            {
                if (!string.IsNullOrWhiteSpace(preopenedRuntimeTitle))
                {
                    runtimeTitle = preopenedRuntimeTitle;
                    steps.Add(new { Name = "click-demo-in-solidworks-command", Status = "skipped", Detail = "runtime already licensed; activation/demo dialog was not shown" });
                }
                else
                {
                    if (!ClickZToolButtonContaining("Демо"))
                    {
                        throw new InvalidOperationException("Demo button was not found on the ZTool activation window.");
                    }

                    CloseVisibleTopLevelWindowContaining("Демо-режим", 5000);

                    AssertNoFrameworkExceptionDialog();
                    steps.Add(new { Name = "click-demo-in-solidworks-command", Status = "ok" });

                    demoTitle = WaitForZToolTitleContaining("Демо:", Math.Max(15, commandTimeoutSeconds));
                    if (string.IsNullOrEmpty(demoTitle))
                    {
                        throw new InvalidOperationException("Demo timer title did not appear after starting demo mode from SolidWorks.");
                    }

                    AssertNoFrameworkExceptionDialog();
                    steps.Add(new { Name = "solidworks-demo-countdown-title", Status = "ok", Detail = demoTitle });

                    runtimeTitle = demoTitle;
                }
            }
            else
            {
                runtimeTitle = preopenedRuntimeTitle;
                if (string.IsNullOrWhiteSpace(runtimeTitle))
                {
                    runtimeTitle = WaitForAnyZToolRuntimeWindow(commandStartedUtc, Math.Max(15, commandTimeoutSeconds));
                }
                if (string.IsNullOrWhiteSpace(runtimeTitle))
                {
                    throw new InvalidOperationException("openZtool(0) did not create a visible ZTool runtime window.");
                }

                steps.Add(new { Name = "ztool-runtime-title", Status = "ok", Detail = runtimeTitle });
            }

            if (InvokeFirstZToolAutomationElementByName(new string[] { "试用", "Демо-режим", "Демо" }, 3))
            {
                steps.Add(new { Name = "click-native-trial-if-present", Status = "ok" });
            }

            if (string.Equals(assertLanguage, "Russian", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(assertLanguage, "English", StringComparison.OrdinalIgnoreCase))
            {
                AssertNoMajorChineseUiLabels(assertLanguage);
                steps.Add(new { Name = "localized-runtime-ui", Status = "ok", Detail = assertLanguage });
            }

            if (!InvokeFirstZToolAutomationElementByName(new string[] { "Подключить SW", "Connect SW", "SW", "连接SW" }, Math.Max(10, commandTimeoutSeconds / 2)) &&
                !InvokeFirstZToolToolbarButton(Math.Max(10, commandTimeoutSeconds / 2)))
            {
                throw new InvalidOperationException("ZTool runtime opened, but the native 'Подключить SW' command could not be invoked. UI snapshot: " + GetZToolUiSnapshot());
            }

            steps.Add(new { Name = "click-connect-solidworks", Status = "ok" });

            string importDetail = WaitForImportedAssemblyRows(Math.Max(20, commandTimeoutSeconds));
            if (string.IsNullOrWhiteSpace(importDetail))
            {
                throw new InvalidOperationException("ZTool runtime opened, but active assembly import was not proven. UI snapshot: " + GetZToolUiSnapshot());
            }

            steps.Add(new { Name = "active-assembly-import", Status = "ok", Detail = importDetail });

            for (int i = 1; i < commandTypes.Count; i++)
            {
                Invoke(addinObject, "openZtool", commandTypes[i]);
                string repeatedActivationTitle = WaitForZToolActivationWindow(DateTime.UtcNow, 4);
                if (!string.IsNullOrEmpty(repeatedActivationTitle))
                {
                    throw new InvalidOperationException("Activation window appeared again during active demo timer for command " + commandTypes[i] + ": " + repeatedActivationTitle);
                }

                AssertNoFrameworkExceptionDialog();
                steps.Add(new { Name = "solidworks-command-" + commandTypes[i].ToString(), Status = "ok" });
            }

            if (!keepSolidWorksOpen)
            {
                CloseExistingZToolWindows();
            }

            if (!keepSolidWorksOpen)
            {
                Invoke(swApp, "CloseAllDocuments", true);
                steps.Add(new { Name = "close-documents", Status = "ok" });
            }
            else
            {
                steps.Add(new { Name = "keep-documents-open", Status = "ok" });
            }

            result["Status"] = "ok";
            result["SolidWorksRevision"] = revision;
            result["SolidWorksProcessId"] = processId;
            result["SolidWorksExecutablePath"] = executablePath;
            result["ModelPath"] = modelPath;
            result["StartedSolidWorks"] = startedByHarness;
            result["LoadAddInResult"] = Convert.ToString(loadResult);
            result["ActivationWindowTitle"] = activationTitle;
            result["DemoWindowTitle"] = demoTitle;
            result["Steps"] = steps;
            Console.WriteLine(ToJson(result));
            return 0;
        }
        catch (Exception ex)
        {
            Exception root = ex;
            while (root.InnerException != null) root = root.InnerException;
            result["Status"] = "fail";
            result["Error"] = root.GetType().FullName + ": " + root.Message;
            result["Steps"] = steps;
            Console.WriteLine(ToJson(result));
            return 2;
        }
        finally
        {
            if (!keepSolidWorksOpen)
            {
                CloseExistingZToolWindows();
            }
            if (!keepSolidWorksOpen && swApp != null)
            {
                try { Invoke(swApp, "CloseAllDocuments", true); } catch { }
                if (startedByHarness)
                {
                    try { Invoke(swApp, "ExitApp"); } catch { }
                }
            }
        }
    }

    private static object TryGetActiveSolidWorks()
    {
        try
        {
            return Marshal.GetActiveObject("SldWorks.Application");
        }
        catch
        {
            return null;
        }
    }

    private static bool IsSolidWorksProcessRunning()
    {
        return Process.GetProcessesByName("SLDWORKS").Length > 0 ||
            Process.GetProcessesByName("sldworks").Length > 0;
    }

    private static object WaitForSolidWorks(int timeoutSeconds)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        Exception last = null;
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                object app = Marshal.GetActiveObject("SldWorks.Application");
                if (app != null)
                {
                    return app;
                }
            }
            catch (Exception ex)
            {
                last = ex;
            }
            Thread.Sleep(1000);
        }

        throw new TimeoutException("SOLIDWORKS COM server did not become available. Last error: " + (last == null ? "" : last.Message));
    }

    private static object Invoke(object target, string member, params object[] args)
    {
        return target.GetType().InvokeMember(
            member,
            BindingFlags.InvokeMethod,
            null,
            target,
            args);
    }

    private static bool TryInvokeString(object target, string member, out string value)
    {
        value = "";
        try
        {
            value = Convert.ToString(Invoke(target, member));
            return true;
        }
        catch (MissingMethodException)
        {
            return false;
        }
        catch (COMException ex)
        {
            const int DISP_E_UNKNOWNNAME = unchecked((int)0x80020006);
            if (ex.ErrorCode == DISP_E_UNKNOWNNAME)
            {
                return false;
            }

            throw;
        }
    }

    private static object OpenDoc6(object swApp, string path, int type, int options, string config, ref int errors, ref int warnings)
    {
        object[] args = new object[] { path, type, options, config, errors, warnings };
        var modifiers = new ParameterModifier(6);
        modifiers[4] = true;
        modifiers[5] = true;
        object result = swApp.GetType().InvokeMember(
            "OpenDoc6",
            BindingFlags.InvokeMethod,
            null,
            swApp,
            args,
            new ParameterModifier[] { modifiers },
            null,
            null);
        errors = Convert.ToInt32(args[4]);
        warnings = Convert.ToInt32(args[5]);
        return result;
    }

    private static int GetSolidWorksDocumentType(string path)
    {
        string ext = Path.GetExtension(path).ToUpperInvariant();
        if (ext == ".SLDPRT") return 1;
        if (ext == ".SLDASM") return 2;
        if (ext == ".SLDDRW") return 3;
        return 1;
    }

    private static void SetProperty(object target, string member, object value)
    {
        target.GetType().InvokeMember(
            member,
            BindingFlags.SetProperty,
            null,
            target,
            new object[] { value });
    }

    private static string WaitForZToolActivationWindow(DateTime startedUtc, int timeoutSeconds)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            foreach (Process process in Process.GetProcessesByName("ZTool"))
            {
                try
                {
                    process.Refresh();
                    if (process.StartTime.ToUniversalTime() < startedUtc.AddSeconds(-2))
                    {
                        continue;
                    }

                    string title = process.MainWindowTitle;
                    if (string.Equals(title, "Активация SWTool", StringComparison.Ordinal))
                    {
                        return title;
                    }
                }
                catch
                {
                }
            }
            Thread.Sleep(500);
        }

        return "";
    }

    private static bool WaitForNoZToolProcesses(int timeoutMs)
    {
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            bool any = false;
            foreach (Process process in Process.GetProcessesByName("ZTool"))
            {
                try
                {
                    process.Refresh();
                    if (!process.HasExited)
                    {
                        any = true;
                    }
                }
                catch
                {
                }
            }

            if (!any)
            {
                return true;
            }

            AssertNoFrameworkExceptionDialog();
            Thread.Sleep(500);
        }

        return false;
    }

    private static string WaitForZToolTitleContaining(string marker, int timeoutSeconds)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            AssertNoFrameworkExceptionDialog();
            foreach (Process process in Process.GetProcessesByName("ZTool"))
            {
                try
                {
                    process.Refresh();
                    string title = process.MainWindowTitle;
                    if (!string.IsNullOrWhiteSpace(title) &&
                        title.IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        return title;
                    }
                }
                catch
                {
                }
            }
            Thread.Sleep(500);
        }

        return "";
    }

    private static string WaitForAnyZToolRuntimeWindow(DateTime startedUtc, int timeoutSeconds)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            foreach (Process process in Process.GetProcessesByName("ZTool"))
            {
                try
                {
                    process.Refresh();
                    if (process.StartTime.ToUniversalTime() < startedUtc.AddSeconds(-2))
                    {
                        continue;
                    }

                    string title = process.MainWindowTitle;
                    if (!string.IsNullOrWhiteSpace(title) &&
                        !string.Equals(title, "Активация SWTool", StringComparison.Ordinal))
                    {
                        return title;
                    }
                }
                catch
                {
                }
            }

            Thread.Sleep(500);
        }

        return "";
    }

    private static string WaitForImportedAssemblyRows(int timeoutSeconds)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            AssertNoFrameworkExceptionDialog();
            string snapshot = GetZToolUiSnapshot();
            if (snapshot.IndexOf("正在获取数据", StringComparison.Ordinal) >= 0 ||
                snapshot.IndexOf("получение данных", StringComparison.OrdinalIgnoreCase) >= 0 ||
                snapshot.IndexOf("getting data", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                Thread.Sleep(500);
                continue;
            }

            if (snapshot.IndexOf("0614-A00", StringComparison.OrdinalIgnoreCase) >= 0 ||
                snapshot.IndexOf("PArt-", StringComparison.OrdinalIgnoreCase) >= 0 ||
                snapshot.IndexOf(".SLDASM", StringComparison.OrdinalIgnoreCase) >= 0 ||
                snapshot.IndexOf(".SLDPRT", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return "assembly-data-visible";
            }

            Match totalMatch = Regex.Match(snapshot, @"всего\s+([1-9][0-9]*)\s+элем", RegexOptions.IgnoreCase);
            if (totalMatch.Success)
            {
                return totalMatch.Value;
            }

            Match rowMatch = Regex.Match(snapshot, @"\b([1-9][0-9]*)\s+(?:rows|items)\b", RegexOptions.IgnoreCase);
            if (rowMatch.Success)
            {
                return rowMatch.Value;
            }

            Match dataGridRowMatch = Regex.Match(snapshot, @"Строка\s+([1-9][0-9]*)", RegexOptions.IgnoreCase);
            if (dataGridRowMatch.Success)
            {
                return dataGridRowMatch.Value;
            }

            Thread.Sleep(500);
        }

        return "";
    }

    private static string GetZToolUiSnapshot()
    {
        var parts = new List<string>();
        foreach (Process process in Process.GetProcessesByName("ZTool"))
        {
            try
            {
                process.Refresh();
                if (process.MainWindowHandle == IntPtr.Zero)
                {
                    continue;
                }

                parts.Add("title=" + process.MainWindowTitle);
                AutomationElement root = AutomationElement.FromHandle(process.MainWindowHandle);
                if (root == null)
                {
                    continue;
                }

                AutomationElementCollection descendants = root.FindAll(
                    TreeScope.Descendants,
                    Condition.TrueCondition);
                int max = Math.Min(descendants.Count, 300);
                for (int i = 0; i < max; i++)
                {
                    AutomationElement element = descendants[i];
                    string name = SafeAutomationString(delegate { return element.Current.Name; });
                    string className = SafeAutomationString(delegate { return element.Current.ClassName; });
                    string controlType = SafeAutomationString(delegate { return element.Current.ControlType.ProgrammaticName; });
                    if (!string.IsNullOrWhiteSpace(name) || !string.IsNullOrWhiteSpace(className))
                    {
                        parts.Add(controlType + "|" + className + "|" + name);
                    }
                }
            }
            catch
            {
            }
        }

        string snapshot = string.Join(" ; ", parts.ToArray());
        if (snapshot.Length > 4000)
        {
            snapshot = snapshot.Substring(0, 4000);
        }

        return snapshot;
    }

    private static void AssertNoMajorChineseUiLabels(string language)
    {
        string snapshot = GetZToolUiSnapshot();
        string[] majorLabels = new string[]
        {
            "开始", "明细表", "打包", "工具", "连接SW", "保存到SW", "关闭文档",
            "显示复选框", "包含符合项", "快速筛选", "填充文件名", "拆分列",
            "查找和替换", "前后缀", "符号", "选项"
        };

        var found = new List<string>();
        foreach (string label in majorLabels)
        {
            if (snapshot.IndexOf(label, StringComparison.Ordinal) >= 0)
            {
                found.Add(label);
            }
        }

        if (found.Count > 0)
        {
            throw new InvalidOperationException(
                "Expected " + language + " runtime UI, but major Chinese labels are still visible: " +
                string.Join(", ", found.ToArray()) + ". UI snapshot: " + snapshot);
        }
    }

    private delegate string StringGetter();

    private static string SafeAutomationString(StringGetter getter)
    {
        try
        {
            return getter() ?? "";
        }
        catch
        {
            return "";
        }
    }

    private static bool ClickZToolButtonContaining(string marker)
    {
        foreach (Process process in Process.GetProcessesByName("ZTool"))
        {
            try
            {
                process.Refresh();
                if (process.MainWindowHandle == IntPtr.Zero)
                {
                    continue;
                }

                IntPtr found = FindChildWindowContaining(process.MainWindowHandle, marker);
                if (found != IntPtr.Zero)
                {
                    SendMessage(found, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
                    return true;
                }
            }
            catch
            {
            }
        }

        return false;
    }

    private static bool InvokeFirstZToolAutomationElementByName(string[] names, int timeoutSeconds)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            foreach (string name in names)
            {
                if (InvokeZToolAutomationElementByName(name, 1))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static bool InvokeZToolAutomationElementByName(string name, int timeoutSeconds)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            foreach (Process process in Process.GetProcessesByName("ZTool"))
            {
                try
                {
                    process.Refresh();
                    if (process.MainWindowHandle == IntPtr.Zero)
                    {
                        continue;
                    }

                    AutomationElement root = AutomationElement.FromHandle(process.MainWindowHandle);
                    if (root == null)
                    {
                        continue;
                    }

                    AutomationElementCollection matches = root.FindAll(
                        TreeScope.Descendants,
                        Condition.TrueCondition);

                    for (int i = 0; i < matches.Count; i++)
                    {
                        AutomationElement element = matches[i];
                        string elementName = SafeAutomationString(delegate { return element.Current.Name; });
                        if (!string.Equals(elementName.Trim(), name.Trim(), StringComparison.OrdinalIgnoreCase))
                        {
                            continue;
                        }

                        object pattern;
                        if (element.TryGetCurrentPattern(InvokePattern.Pattern, out pattern))
                        {
                            ((InvokePattern)pattern).Invoke();
                            return true;
                        }
                    }
                }
                catch
                {
                }
            }

            Thread.Sleep(500);
        }

        return false;
    }

    private static bool InvokeFirstZToolToolbarButton(int timeoutSeconds)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            foreach (Process process in Process.GetProcessesByName("ZTool"))
            {
                try
                {
                    process.Refresh();
                    if (process.MainWindowHandle == IntPtr.Zero)
                    {
                        continue;
                    }

                    AutomationElement root = AutomationElement.FromHandle(process.MainWindowHandle);
                    if (root == null)
                    {
                        continue;
                    }

                    AutomationElementCollection toolbars = root.FindAll(
                        TreeScope.Descendants,
                        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ToolBar));

                    for (int toolbarIndex = 0; toolbarIndex < toolbars.Count; toolbarIndex++)
                    {
                        AutomationElement toolbar = toolbars[toolbarIndex];
                        string toolbarName = SafeAutomationString(delegate { return toolbar.Current.Name; });
                        string toolbarClass = SafeAutomationString(delegate { return toolbar.Current.ClassName; });
                        if (toolbarName.IndexOf("ToolStrip", StringComparison.OrdinalIgnoreCase) < 0 &&
                            toolbarClass.IndexOf("WindowsForms10", StringComparison.OrdinalIgnoreCase) < 0)
                        {
                            continue;
                        }

                        AutomationElementCollection buttons = toolbar.FindAll(
                            TreeScope.Descendants,
                            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
                        if (buttons.Count == 0)
                        {
                            continue;
                        }

                        object pattern;
                        if (buttons[0].TryGetCurrentPattern(InvokePattern.Pattern, out pattern))
                        {
                            ((InvokePattern)pattern).Invoke();
                            return true;
                        }
                    }
                }
                catch
                {
                }
            }

            Thread.Sleep(500);
        }

        return false;
    }

    private static IntPtr FindChildWindowContaining(IntPtr parent, string marker)
    {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, delegate(IntPtr hWnd, IntPtr lParam)
        {
            string text = GetText(hWnd);
            string className = GetClass(hWnd);
            if (!string.IsNullOrWhiteSpace(text) &&
                className.StartsWith("WindowsForms10.BUTTON.", StringComparison.OrdinalIgnoreCase) &&
                text.IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0)
            {
                found = hWnd;
                return false;
            }

            return true;
        }, IntPtr.Zero);

        return found;
    }

    private static string GetClass(IntPtr hWnd)
    {
        var className = new System.Text.StringBuilder(256);
        GetClassName(hWnd, className, className.Capacity);
        return className.ToString();
    }

    private static void AssertNoFrameworkExceptionDialog()
    {
        string title = FindVisibleTopLevelTitleContaining(".NET Framework");
        if (!string.IsNullOrWhiteSpace(title))
        {
            throw new InvalidOperationException("Unexpected .NET exception dialog is visible: " + title);
        }
    }

    private static string FindVisibleTopLevelTitleContaining(string marker)
    {
        string found = "";
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd))
            {
                return true;
            }

            string title = GetText(hWnd);
            if (!string.IsNullOrWhiteSpace(title) &&
                title.IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0)
            {
                found = title;
                return false;
            }

            return true;
        }, IntPtr.Zero);

        return found;
    }

    private static bool CloseVisibleTopLevelWindowContaining(string marker, int timeoutMs)
    {
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            IntPtr found = IntPtr.Zero;
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                if (!IsWindowVisible(hWnd))
                {
                    return true;
                }

                string title = GetText(hWnd);
                if (!string.IsNullOrWhiteSpace(title) &&
                    title.IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    found = hWnd;
                    return false;
                }

                return true;
            }, IntPtr.Zero);

            if (found != IntPtr.Zero)
            {
                SendMessage(found, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                return true;
            }

            Thread.Sleep(250);
        }

        return false;
    }

    private static string[] GetVisibleTopLevelTitles()
    {
        var titles = new List<string>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (IsWindowVisible(hWnd))
            {
                string title = GetText(hWnd);
                if (!string.IsNullOrWhiteSpace(title))
                {
                    titles.Add(title);
                }
            }

            return true;
        }, IntPtr.Zero);

        return titles.ToArray();
    }

    private static string GetText(IntPtr hWnd)
    {
        var text = new System.Text.StringBuilder(512);
        GetWindowText(hWnd, text, text.Capacity);
        return text.ToString();
    }

    private static void CloseExistingZToolWindows()
    {
        foreach (Process process in Process.GetProcessesByName("ZTool"))
        {
            try
            {
                process.Refresh();
                if (process.MainWindowHandle != IntPtr.Zero)
                {
                    SendMessage(process.MainWindowHandle, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                    if (!process.WaitForExit(5000))
                    {
                        process.Kill();
                    }
                }
                else if (!process.HasExited)
                {
                    process.Kill();
                }
            }
            catch
            {
            }
        }
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
    $uiAutomationClient = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\WPF\UIAutomationClient.dll'
    $uiAutomationTypes = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\WPF\UIAutomationTypes.dll'
    if (-not (Test-Path -LiteralPath $uiAutomationClient -PathType Leaf)) {
        $uiAutomationClient = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\WPF\UIAutomationClient.dll'
    }
    if (-not (Test-Path -LiteralPath $uiAutomationTypes -PathType Leaf)) {
        $uiAutomationTypes = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\WPF\UIAutomationTypes.dll'
    }
    & $csc /nologo /codepage:65001 /target:exe /out:$harnessExe /reference:System.Web.Extensions.dll /reference:$uiAutomationClient /reference:$uiAutomationTypes $harnessPath
    if ($LASTEXITCODE -ne 0) {
        throw "SolidWorks smoke harness compilation failed with exit code $LASTEXITCODE."
    }

    $clickDemoArg = if ($ClickDemo) { 'true' } else { 'false' }
    $skipInitialActivationArg = if ($SkipInitialActivation) { 'true' } else { 'false' }
    $keepExistingZToolBrokerArg = if ($KeepExistingZToolBroker) { 'true' } else { 'false' }
    $keepOpen = if ($KeepSolidWorksOpen) { 'true' } else { 'false' }
    $commandTypesArg = ($CommandTypes | ForEach-Object { [string]$_ }) -join ','
    $output = & $harnessExe $solidWorksExeFull $ztoolDll $modelPathFull $commandTypesArg $StartupTimeoutSeconds $CommandTimeoutSeconds $clickDemoArg $skipInitialActivationArg '' $AssertLanguage $keepExistingZToolBrokerArg $keepOpen
    $exitCode = $LASTEXITCODE
    $result = ($output | ForEach-Object { [string]$_ }) -join "`n" | ConvertFrom-Json
    $result | Add-Member -NotePropertyName PackageRoot -NotePropertyValue $packageFull
    $result | Add-Member -NotePropertyName SolidWorksExe -NotePropertyValue $solidWorksExeFull
    $result | Add-Member -NotePropertyName Registration -NotePropertyValue $registration

    if ($exitCode -ne 0) {
        $result | ConvertTo-Json -Depth 8
        exit $exitCode
    }

    $result | ConvertTo-Json -Depth 8
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
