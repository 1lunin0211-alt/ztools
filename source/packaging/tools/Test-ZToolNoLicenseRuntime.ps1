param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,
    [int]$ActivationTimeoutSeconds = 25,
    [int]$ExitTimeoutSeconds = 20,
    [int]$DemoSeconds = 0,
    [int]$DemoReentryTimeoutSeconds = 2,
    [int]$DemoExitGraceSeconds = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class ZToolRuntimeSmokeWin32 {
    public const uint WM_CLOSE = 0x0010;
    public const uint BM_CLICK = 0x00F5;

    private delegate bool EnumWindowProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    public static string GetText(IntPtr hWnd) {
        int length = GetWindowTextLength(hWnd);
        var builder = new StringBuilder(Math.Max(length + 1, 256));
        GetWindowText(hWnd, builder, builder.Capacity);
        return builder.ToString();
    }

    public static string GetClass(IntPtr hWnd) {
        var builder = new StringBuilder(256);
        GetClassName(hWnd, builder, builder.Capacity);
        return builder.ToString();
    }

    public static IntPtr FindWindowContaining(uint processId, string titlePart) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == processId && IsWindowVisible(hWnd)) {
                string title = GetText(hWnd);
                if (!string.IsNullOrEmpty(title) && title.IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) >= 0) {
                    found = hWnd;
                    return false;
                }
            }

            return true;
        }, IntPtr.Zero);

        return found;
    }

    public static IntPtr FindChildContaining(IntPtr parent, string textPart) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, delegate(IntPtr hWnd, IntPtr lParam) {
            string text = GetText(hWnd);
            if (!string.IsNullOrEmpty(text) && text.IndexOf(textPart, StringComparison.OrdinalIgnoreCase) >= 0) {
                found = hWnd;
                return false;
            }

            return true;
        }, IntPtr.Zero);

        return found;
    }

    public static IntPtr FindChildButtonContaining(IntPtr parent, string textPart) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, delegate(IntPtr hWnd, IntPtr lParam) {
            string text = GetText(hWnd);
            string className = GetClass(hWnd);
            if (!string.IsNullOrEmpty(text) &&
                !string.IsNullOrEmpty(className) &&
                className.IndexOf("BUTTON", StringComparison.OrdinalIgnoreCase) >= 0 &&
                text.IndexOf(textPart, StringComparison.OrdinalIgnoreCase) >= 0) {
                found = hWnd;
                return false;
            }

            return true;
        }, IntPtr.Zero);

        return found;
    }


    public static string[] VisibleTitles(uint processId) {
        var titles = new List<string>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == processId && IsWindowVisible(hWnd)) {
                string title = GetText(hWnd);
                if (!string.IsNullOrWhiteSpace(title)) {
                    titles.Add(title);
                }
            }

            return true;
        }, IntPtr.Zero);

        return titles.ToArray();
    }

    public static string[] VisibleTexts(uint processId) {
        var texts = new List<string>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == processId && IsWindowVisible(hWnd)) {
                string title = GetText(hWnd);
                if (!string.IsNullOrWhiteSpace(title)) {
                    texts.Add(title);
                }

                EnumChildWindows(hWnd, delegate(IntPtr child, IntPtr childParam) {
                    string text = GetText(child);
                    if (!string.IsNullOrWhiteSpace(text)) {
                        texts.Add(text);
                    }

                    return true;
                }, IntPtr.Zero);
            }

            return true;
        }, IntPtr.Zero);

        return texts.ToArray();
    }
}
'@ -ErrorAction SilentlyContinue

function ConvertFrom-Utf8Base64([string]$Value) {
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

$activationWindowTitle = ConvertFrom-Utf8Base64 '0JDQutGC0LjQstCw0YbQuNGPIFNXVG9vbA=='
$demoButtonText = ConvertFrom-Utf8Base64 '0JTQtdC80L4='
$demoNoticeTitle = ConvertFrom-Utf8Base64 '0JTQtdC80L4t0YDQtdC20LjQvCBTV1Rvb2w='
$demoTitleMarker = ConvertFrom-Utf8Base64 '0JTQtdC80L46'
$errorWindowTitle = ConvertFrom-Utf8Base64 '0J7RiNC40LHQutCw'
$comCastErrorText = ConvertFrom-Utf8Base64 '0J3QtdCy0L7Qt9C80L7QttC90L4g0L/RgNC40LLQtdGB0YLQuCBDT00t0L7QsdGK0LXQutGC'
$runtimeErrorNeedles = @(
    $errorWindowTitle,
    $comCastErrorText,
    'RibbonLib.Interop.IUIRibbon',
    'IUIRibbon',
    'E_NOINTERFACE',
    '0x80004002'
)

function Assert-NoRuntimeErrorWindow([System.Diagnostics.Process]$Process, [string]$Stage) {
    if ($null -eq $Process -or $Process.HasExited) {
        return
    }

    $visibleText = @([ZToolRuntimeSmokeWin32]::VisibleTexts([uint32]$Process.Id))
    foreach ($needle in $runtimeErrorNeedles) {
        foreach ($text in $visibleText) {
            if (-not [string]::IsNullOrWhiteSpace($text) -and $text.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $joined = ($visibleText | Select-Object -First 20) -join ' | '
                throw "Runtime error window detected during ${Stage}: matched '$needle'. Visible text: $joined"
            }
        }
    }
}

function Wait-ForProcessExitNoRuntimeError([System.Diagnostics.Process]$Process, [int]$TimeoutMilliseconds, [string]$Stage) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Process.HasExited) {
            return $true
        }

        Assert-NoRuntimeErrorWindow $Process $Stage
        Start-Sleep -Milliseconds 250
    }

    return $Process.HasExited
}

function Wait-ForWindow([System.Diagnostics.Process]$Process, [string]$TitlePart, [int]$TimeoutSeconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Process.HasExited) {
            return [IntPtr]::Zero
        }

        Assert-NoRuntimeErrorWindow $Process "waiting for window '$TitlePart'"
        $window = [ZToolRuntimeSmokeWin32]::FindWindowContaining([uint32]$Process.Id, $TitlePart)
        if ($window -ne [IntPtr]::Zero) {
            return $window
        }

        Start-Sleep -Milliseconds 250
    }

    return [IntPtr]::Zero
}

function Wait-ForTitleMatch([System.Diagnostics.Process]$Process, [scriptblock]$Predicate, [int]$TimeoutSeconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Process.HasExited) {
            return ''
        }

        Assert-NoRuntimeErrorWindow $Process 'waiting for title match'
        foreach ($title in [ZToolRuntimeSmokeWin32]::VisibleTitles([uint32]$Process.Id)) {
            if (& $Predicate $title) {
                return $title
            }
        }

        Start-Sleep -Milliseconds 250
    }

    return ''
}

function Stop-TestProcess([System.Diagnostics.Process]$Process) {
    if ($null -ne $Process -and -not $Process.HasExited) {
        try {
            $Process.Kill()
            $Process.WaitForExit(5000) | Out-Null
        } catch {
        }
    }
}

function Remove-LicenseCache([string]$LicensePath) {
    if (Test-Path -LiteralPath $LicensePath -PathType Leaf) {
        Remove-Item -LiteralPath $LicensePath -Force
    }
}

function Remove-DemoLease([string]$LeasePath) {
    if (Test-Path -LiteralPath $LeasePath -PathType Leaf) {
        Remove-Item -LiteralPath $LeasePath -Force
    }
}

$packageFull = Resolve-FullPath $PackageRoot
$exePath = Join-Path $packageFull 'ZTool.exe'
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "ZTool.exe not found: $exePath"
}

$licenseDir = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'SWTools'
$licensePath = Join-Path $licenseDir 'ZTool.license.json'
$demoLeasePath = Join-Path $licenseDir 'ZTool.demo.lease'
$backupPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ztool-license-cache-backup-" + [guid]::NewGuid().ToString('N') + ".json")
$hadLicenseCache = Test-Path -LiteralPath $licensePath -PathType Leaf
$oldDemoOverride = [Environment]::GetEnvironmentVariable('ZTOOL_DEMO_SECONDS')
$checks = New-Object System.Collections.Generic.List[object]

try {
    if ($hadLicenseCache) {
        Copy-Item -LiteralPath $licensePath -Destination $backupPath -Force
    }

    New-Item -ItemType Directory -Force -Path $licenseDir | Out-Null
    Remove-LicenseCache $licensePath
    Remove-DemoLease $demoLeasePath
    [Environment]::SetEnvironmentVariable('ZTOOL_DEMO_SECONDS', $null)

    $process = Start-Process -FilePath $exePath -WorkingDirectory $packageFull -PassThru
    try {
        $activation = Wait-ForWindow $process $activationWindowTitle $ActivationTimeoutSeconds
        if ($activation -eq [IntPtr]::Zero) {
            throw 'Activation window did not appear in the no-license close test.'
        }

        [ZToolRuntimeSmokeWin32]::PostMessage($activation, [ZToolRuntimeSmokeWin32]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        if (-not (Wait-ForProcessExitNoRuntimeError $process ($ExitTimeoutSeconds * 1000) 'closing activation window')) {
            $titles = [ZToolRuntimeSmokeWin32]::VisibleTitles([uint32]$process.Id) -join '; '
            throw "ZTool did not exit after closing activation window. Visible windows: $titles"
        }

        $checks.Add([pscustomobject]@{
            Name = 'close-activation-without-license'
            Status = 'ok'
            Detail = 'process-exited'
        })
    } finally {
        Stop-TestProcess $process
    }

    Remove-LicenseCache $licensePath
    if ($DemoSeconds -gt 0) {
        [Environment]::SetEnvironmentVariable('ZTOOL_DEMO_SECONDS', [string]$DemoSeconds)
    } else {
        [Environment]::SetEnvironmentVariable('ZTOOL_DEMO_SECONDS', $null)
    }

    $process = Start-Process -FilePath $exePath -WorkingDirectory $packageFull -PassThru
    try {
        $activation = Wait-ForWindow $process $activationWindowTitle $ActivationTimeoutSeconds
        if ($activation -eq [IntPtr]::Zero) {
            throw 'Activation window did not appear in the demo test.'
        }

        $demoButton = [ZToolRuntimeSmokeWin32]::FindChildButtonContaining($activation, $demoButtonText)
        if ($demoButton -eq [IntPtr]::Zero) {
            throw 'Demo button was not found on the activation window.'
        }

        [ZToolRuntimeSmokeWin32]::SendMessage($demoButton, [ZToolRuntimeSmokeWin32]::BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null

        $notice = Wait-ForWindow $process $demoNoticeTitle $ActivationTimeoutSeconds
        if ($notice -ne [IntPtr]::Zero) {
            [ZToolRuntimeSmokeWin32]::PostMessage($notice, [ZToolRuntimeSmokeWin32]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        }

        $mainTitle = Wait-ForTitleMatch $process {
            param($Title)
            ($Title.StartsWith('SWTool', [System.StringComparison]::OrdinalIgnoreCase) -or
                $Title.StartsWith('ZTool', [System.StringComparison]::OrdinalIgnoreCase)) -and
                $Title.IndexOf($demoTitleMarker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        } $ActivationTimeoutSeconds
        if ([string]::IsNullOrWhiteSpace($mainTitle)) {
            $titles = [ZToolRuntimeSmokeWin32]::VisibleTitles([uint32]$process.Id) -join '; '
            throw "Demo mode did not reach a SWTool main window with countdown. Visible windows: $titles"
        }

        Start-Sleep -Milliseconds 500
        $extraDemoPanels = @([ZToolRuntimeSmokeWin32]::VisibleTitles([uint32]$process.Id) | Where-Object {
            [string]$_ -eq $demoNoticeTitle
        })
        if ($extraDemoPanels.Count -gt 0) {
            throw 'Demo mode opened an extra floating countdown panel.'
        }

        $secondProcess = Start-Process -FilePath $exePath -WorkingDirectory $packageFull -PassThru
        try {
            $secondActivation = Wait-ForWindow $secondProcess $activationWindowTitle $DemoReentryTimeoutSeconds
            if ($secondActivation -ne [IntPtr]::Zero) {
                throw 'Activation window appeared while the current demo timer was still active.'
            }

            $checks.Add([pscustomobject]@{
                Name = 'no-activation-during-active-demo'
                Status = 'ok'
                Detail = 'second-launch-did-not-show-activation'
            })
        } finally {
            Stop-TestProcess $secondProcess
        }

        $timeoutMs = if ($DemoSeconds -gt 0) {
            ($DemoSeconds + $DemoExitGraceSeconds) * 1000
        } else {
            (180 + $DemoExitGraceSeconds) * 1000
        }

        if (-not (Wait-ForProcessExitNoRuntimeError $process $timeoutMs 'demo countdown expiry')) {
            $titles = [ZToolRuntimeSmokeWin32]::VisibleTitles([uint32]$process.Id) -join '; '
            throw "Demo process did not exit after its timer. Visible windows: $titles"
        }

        $checks.Add([pscustomobject]@{
            Name = 'demo-mode-countdown-and-expiry'
            Status = 'ok'
            Detail = $mainTitle
        })
    } finally {
        Stop-TestProcess $process
    }

    if (Test-Path -LiteralPath $licensePath -PathType Leaf) {
        $content = Get-Content -LiteralPath $licensePath -Raw
        if ($content.Contains('__ZTOOL_DEMO__')) {
            throw 'Demo cache was not removed after demo expiry.'
        }
    }

    if (Test-Path -LiteralPath $demoLeasePath -PathType Leaf) {
        throw 'Demo lease was not removed after demo expiry.'
    }

    [pscustomobject]@{
        Status = 'ok'
        PackageRoot = $packageFull
        DemoSeconds = $DemoSeconds
        Checks = $checks
    } | ConvertTo-Json -Depth 6
} finally {
    [Environment]::SetEnvironmentVariable('ZTOOL_DEMO_SECONDS', $oldDemoOverride)
    Remove-LicenseCache $licensePath
    Remove-DemoLease $demoLeasePath
    if ($hadLicenseCache -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        New-Item -ItemType Directory -Force -Path $licenseDir | Out-Null
        Copy-Item -LiteralPath $backupPath -Destination $licensePath -Force
    }
    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
}
