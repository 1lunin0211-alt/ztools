param(
    [string]$InstallerPath = '',
    [string]$InstallDir = 'C:\SWToolFullWorkflowSmoke',
    [string]$SolidWorksExe = '',
    [int]$DemoSeconds = 60,
    [int[]]$CommandTypes = @(0, 1, 2, 3, 4, 5, 6, 120, 130),
    [string]$CommandTypesCsv = '',
    [switch]$NativeParityMode,
    [switch]$ForceStandaloneNoLicenseDemo,
    [switch]$StrictSolidWorksApplicationLog,
    [int]$StepTimeoutSeconds = 900,
    [switch]$KeepInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Invoke-WorkflowStep([string]$Name, [scriptblock]$Body) {
    try {
        $result = & $Body
        if ($null -ne $result -and $result.PSObject.Properties['Status'] -and [string]$result.Status -ne 'ok') {
            throw "$Name returned status '$($result.Status)': $($result.Error)"
        }

        [pscustomobject]@{
            Name = $Name
            Status = 'ok'
            Result = $result
            Error = ''
        }
    } catch {
        [pscustomobject]@{
            Name = $Name
            Status = 'fail'
            Result = $null
            Error = $_.Exception.Message
        }
    }
}

function New-SkippedWorkflowStep([string]$Name, [string]$Reason) {
    [pscustomobject]@{
        Name = $Name
        Status = 'skipped'
        Result = $null
        Error = $Reason
    }
}

function Invoke-ProcessWithTimeout([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds, [string]$Name) {
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "$Name timed out after $TimeoutSeconds seconds."
    }

    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode)."
    }

    $process
}

function Invoke-JsonPowerShellScript([string]$ScriptPath, [string[]]$Arguments, [int]$TimeoutSeconds = $StepTimeoutSeconds) {
    $powershellCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -eq $powershellCommand) {
        $powershellCommand = Get-Command powershell.exe -ErrorAction Stop
    }

    $powershell = $powershellCommand.Source
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("ztool-fullworkflow-step-" + [guid]::NewGuid().ToString('N'))
    $stdoutPath = $tempBase + '.out'
    $stderrPath = $tempBase + '.err'
    $quotedArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath)) + @($Arguments | ForEach-Object {
        if ($_ -match '^-') { [string]$_ } else { '"' + (([string]$_) -replace '"', '\"') + '"' }
    })
    $argumentLine = ($quotedArgs | ForEach-Object { [string]$_ }) -join ' '

    try {
        $process = Start-Process -FilePath $powershell -ArgumentList $argumentLine -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -WindowStyle Hidden
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            try { $process.WaitForExit(5000) } catch { }
            $partial = ''
            if (Test-Path -LiteralPath $stdoutPath) { $partial += Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $stderrPath) { $partial += "`n" + (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue) }
            $partial = $partial.Trim()
            if ($partial.Length -gt 4000) {
                $partial = $partial.Substring(0, 4000)
            }
            throw "Script timed out after $TimeoutSeconds seconds: $ScriptPath. PartialOutput=$partial"
        }

        $exitCode = $process.ExitCode
        $raw = ''
        if (Test-Path -LiteralPath $stdoutPath) { $raw += Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $stderrPath) { $raw += "`n" + (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue) }
        $raw = $raw.Trim()
        $jsonStart = $raw.IndexOf('{')
        if ($jsonStart -lt 0) {
            throw "Script produced no JSON output: $ScriptPath. ExitCode=$exitCode Output=$raw"
        }

        $json = $raw.Substring($jsonStart)
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw "Script produced no JSON output: $ScriptPath"
        }

        $result = $json | ConvertFrom-Json
        if ($exitCode -ne 0 -and $null -eq $result) {
            throw "Script failed with exit code $exitCode`: $ScriptPath"
        }

        return $result
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-NativeParityPackage([string]$PackageRoot) {
    $manifestPath = Join-Path $PackageRoot 'ztool-production-package-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return ($null -ne $manifest.AddInDllByteForByte -and [string]$manifest.AddInDllByteForByte.Status -eq 'ok')
    } catch {
        return $false
    }
}

function Stop-ZToolProcesses {
    Get-Process ZTool,SLDWORKS,sldworks -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $remaining = @(Get-Process ZTool,SLDWORKS,sldworks -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            return
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
}

function Get-ApplicationErrorsSince([DateTime]$StartTime) {
    @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $StartTime } -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProviderName -in @('.NET Runtime', 'Application Error', 'Windows Error Reporting') -and
            ($_.Message -like '*ZTool*' -or ($StrictSolidWorksApplicationLog -and ($_.Message -like '*SLDWORKS*' -or $_.Message -like '*sldworks*')))
        } |
        Select-Object TimeCreated, ProviderName, Id, Message)
}

function Remove-DirectoryWithRetry([string]$Path, [int]$TimeoutSeconds = 30) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Stop-ZToolProcesses
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }

        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $InstallerPath = Join-Path $repoRoot 'release\installer\SWTool-Setup-1.1.exe'
}

$installerFull = Resolve-FullPath $InstallerPath
$installFull = Resolve-FullPath $InstallDir
if (-not (Test-Path -LiteralPath $installerFull -PathType Leaf)) {
    throw "Installer not found: $installerFull"
}
if (-not [string]::IsNullOrWhiteSpace($CommandTypesCsv)) {
    $CommandTypes = @($CommandTypesCsv.Split(',') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [int]($_.Trim()) })
}

if ([string]::IsNullOrWhiteSpace($SolidWorksExe)) {
    $candidateSolidWorksExe = 'C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\SLDWORKS.exe'
    if (Test-Path -LiteralPath $candidateSolidWorksExe -PathType Leaf) {
        $SolidWorksExe = $candidateSolidWorksExe
    }
}

$solidWorksExeFull = ''
if (-not [string]::IsNullOrWhiteSpace($SolidWorksExe)) {
    $solidWorksExeFull = Resolve-FullPath $SolidWorksExe
    if (-not (Test-Path -LiteralPath $solidWorksExeFull -PathType Leaf)) {
        throw "SolidWorks executable not found: $solidWorksExeFull"
    }
}

$startedAt = [DateTime]::Now
$steps = New-Object System.Collections.Generic.List[object]

try {
    Stop-ZToolProcesses
    Remove-Item -LiteralPath $installFull -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\SWTools\ZTool.license.json", "$env:LOCALAPPDATA\SWTools\ZTool.demo.lease" -Force -ErrorAction SilentlyContinue

    $steps.Add((Invoke-WorkflowStep 'silent-install' {
        $process = Invoke-ProcessWithTimeout $installerFull @('/S', ('/D=' + $installFull)) 180 'Installer'

        foreach ($required in @('ZTool.exe', 'ZTool.dll', 'Uninstall.exe')) {
            $path = Join-Path $installFull $required
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Installed file missing: $path"
            }
        }

        [pscustomobject]@{
            InstallDir = $installFull
            InstallerSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $installerFull).Hash
        }
    }))

    $installedNativePackage = [bool]$NativeParityMode -or (Test-NativeParityPackage $installFull)

    if ($installedNativePackage) {
        $steps.Add((Invoke-WorkflowStep 'installed-native-parity-gate' {
            $parityArgs = @(
                '-CandidateRoot', $installFull,
                '-ClickDemo',
                '-CommandTypesCsv', (($CommandTypes | ForEach-Object { [string]$_ }) -join ','),
                '-StartupTimeoutSeconds', '150',
                '-CommandTimeoutSeconds', '90'
            )
            if (-not [string]::IsNullOrWhiteSpace($solidWorksExeFull)) {
                $parityArgs += @('-SolidWorksExe', $solidWorksExeFull)
            }

            Invoke-JsonPowerShellScript (Join-Path $PSScriptRoot 'Test-SWToolRebuildParityGate.ps1') $parityArgs
        }))
    } else {
        $steps.Add((Invoke-WorkflowStep 'installed-package-gate' {
            Invoke-JsonPowerShellScript (Join-Path $PSScriptRoot 'Test-ZToolLicensedPackage.ps1') @('-PackageRoot', $installFull)
        }))
    }

    if ($installedNativePackage -and -not $ForceStandaloneNoLicenseDemo) {
        $steps.Add((New-SkippedWorkflowStep 'standalone-no-license-demo' 'NativeParityMode: standalone no-license requires an isolated Windows user/VM because the original native runtime can store activation outside the wrapper cache. Use -ForceStandaloneNoLicenseDemo only on a clean unactivated profile.'))
    } elseif ($installedNativePackage) {
        $steps.Add((Invoke-WorkflowStep 'standalone-no-license-demo' {
            Invoke-JsonPowerShellScript (Join-Path $PSScriptRoot 'Test-ZToolNoLicenseRuntime.ps1') @('-PackageRoot', $installFull, '-DemoSeconds', ([string][Math]::Min($DemoSeconds, 10)))
        }))
    } else {
        $steps.Add((Invoke-WorkflowStep 'standalone-no-license-demo' {
            Invoke-JsonPowerShellScript (Join-Path $PSScriptRoot 'Test-ZToolNoLicenseRuntime.ps1') @('-PackageRoot', $installFull, '-DemoSeconds', ([string][Math]::Min($DemoSeconds, 10)))
        }))
    }

    Stop-ZToolProcesses
    Remove-Item "$env:LOCALAPPDATA\SWTools\ZTool.license.json", "$env:LOCALAPPDATA\SWTools\ZTool.demo.lease" -Force -ErrorAction SilentlyContinue
    $oldDemoSeconds = [Environment]::GetEnvironmentVariable('ZTOOL_DEMO_SECONDS')
    [Environment]::SetEnvironmentVariable('ZTOOL_DEMO_SECONDS', [string]$DemoSeconds)
    try {
        $steps.Add((Invoke-WorkflowStep 'solidworks-install-to-demo-command-workflow' {
            $solidWorksDemoSeconds = [Math]::Max($DemoSeconds, 60)
            $solidWorksArgs = @('-PackageRoot', $installFull)
            if (-not [string]::IsNullOrWhiteSpace($solidWorksExeFull)) {
                $solidWorksArgs += @('-SolidWorksExe', $solidWorksExeFull)
            }

            $solidWorksArgs += @('-ClickDemo', '-CommandTypesCsv', (($CommandTypes | ForEach-Object { [string]$_ }) -join ','))
            [Environment]::SetEnvironmentVariable('ZTOOL_DEMO_SECONDS', [string]$solidWorksDemoSeconds)
            Invoke-JsonPowerShellScript (Join-Path $PSScriptRoot 'Test-ZToolSolidWorksSmoke.ps1') $solidWorksArgs
        }))
    } finally {
        [Environment]::SetEnvironmentVariable('ZTOOL_DEMO_SECONDS', $oldDemoSeconds)
    }

    $steps.Add((Invoke-WorkflowStep 'post-workflow-application-log' {
        $events = @(Get-ApplicationErrorsSince $startedAt)
        if ($events.Count -gt 0) {
            throw (($events | ForEach-Object { "$($_.TimeCreated) [$($_.ProviderName)] $($_.Message.Split("`n")[0])" }) -join '; ')
        }

        'no-new-ztool-solidworks-errors'
    }))
} finally {
    Stop-ZToolProcesses
    Start-Sleep -Seconds 2
    if (-not $KeepInstall -and (Test-Path -LiteralPath (Join-Path $installFull 'Uninstall.exe') -PathType Leaf)) {
        $steps.Add((Invoke-WorkflowStep 'silent-uninstall' {
            $process = Start-Process -FilePath (Join-Path $installFull 'Uninstall.exe') -ArgumentList '/S' -Wait -PassThru
            if (-not $process.WaitForExit(180000)) {
                try { $process.Kill() } catch { }
                throw 'Uninstaller timed out after 180 seconds.'
            }
            if ($process.ExitCode -ne 0) {
                throw "Uninstaller failed with exit code $($process.ExitCode)."
            }

            Remove-DirectoryWithRetry $installFull

            if (Test-Path -LiteralPath $installFull) {
                $leftovers = @(Get-ChildItem -LiteralPath $installFull -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
                throw "Install directory still exists after uninstall cleanup: $installFull. Leftovers: $($leftovers -join '; ')"
            }

            'removed'
        }))
    }
}

$failed = @($steps | Where-Object Status -eq 'fail')
[pscustomobject]@{
    Status = if ($failed.Count -eq 0) { 'ok' } else { 'fail' }
    Installer = $installerFull
    InstallDir = $installFull
    Steps = $steps
} | ConvertTo-Json -Depth 8

if ($failed.Count -gt 0) {
    exit 1
}
