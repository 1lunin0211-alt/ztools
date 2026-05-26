param(
    [string]$OriginalRoot = '',

    [Parameter(Mandatory = $true)]
    [string]$CandidateRoot,

    [string]$SolidWorksExe = '',

    [string]$ModelPath = '',

    [int[]]$CommandTypes = @(0, 1, 2, 3, 4, 5, 6, 120, 130),

    [string]$CommandTypesCsv = '',

    [int]$StartupTimeoutSeconds = 150,

    [int]$CommandTimeoutSeconds = 90,

    [switch]$ClickDemo,

    [switch]$SkipInitialActivation,

    [switch]$StaticOnly,

    [switch]$PreserveOriginalSettings,

    [switch]$AllowChangedAddInDll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

if (-not [string]::IsNullOrWhiteSpace($CommandTypesCsv)) {
    $CommandTypes = @($CommandTypesCsv.Split(',') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [int]($_.Trim()) })
}

function Get-FileSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found: $Path"
    }

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function New-CheckResult([string]$Name, [string]$Status, [object]$Result = $null, [string]$Error = '') {
    [pscustomobject]@{
        Name = $Name
        Status = $Status
        Result = $Result
        Error = $Error
    }
}

function Invoke-Check([string]$Name, [scriptblock]$Body) {
    try {
        New-CheckResult -Name $Name -Status 'ok' -Result (& $Body)
    } catch {
        New-CheckResult -Name $Name -Status 'fail' -Error $_.Exception.Message
    }
}

function Stop-ZToolWorkflowProcesses {
    Get-Process ZTool,SLDWORKS,sldworks -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = @(Get-Process ZTool,SLDWORKS,sldworks -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            break
        }

        Start-Sleep -Seconds 1
    }

    Start-Sleep -Seconds 5
}

function New-NormalizedOriginalRuntimeRoot([string]$SourceRoot) {
    if ($PreserveOriginalSettings) {
        return $SourceRoot
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("swtool-original-baseline-" + [guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $SourceRoot -Destination $tempRoot -Recurse -Force

    $settingsPath = Join-Path $tempRoot 'ZTool.settings'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $text = [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8)
        $text = [regex]::Replace(
            $text,
            '<checkupdata>\s*true\s*</checkupdata>',
            '<checkupdata>false</checkupdata>',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        [System.IO.File]::WriteAllText($settingsPath, $text, [System.Text.Encoding]::UTF8)
    }

    return $tempRoot
}

function Invoke-JsonPowerShellScript([string]$ScriptPath, [string[]]$Arguments, [int]$TimeoutSeconds) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $pwsh) {
        $psi.FileName = $pwsh.Source
    } else {
        $psi.FileName = 'powershell.exe'
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $allArguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        ('"{0}"' -f $ScriptPath)
    ) + $Arguments
    $psi.Arguments = ($allArguments | ForEach-Object { [string]$_ }) -join ' '

    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        try { $process.WaitForExit(5000) } catch { }
        $stdout = ''
        $stderr = ''
        try { $stdout = $process.StandardOutput.ReadToEnd() } catch { }
        try { $stderr = $process.StandardError.ReadToEnd() } catch { }
        $partial = ($stdout + "`n" + $stderr).Trim()
        if ($partial.Length -gt 4000) {
            $partial = $partial.Substring(0, 4000)
        }
        throw "Timed out after $TimeoutSeconds seconds: $ScriptPath. PartialOutput=$partial"
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $raw = ($stdout + "`n" + $stderr).Trim()
    $jsonStart = $raw.IndexOf('{')
    if ($jsonStart -lt 0) {
        throw "Script did not return JSON. ExitCode=$($process.ExitCode). Output=$raw"
    }

    $jsonText = $raw.Substring($jsonStart)
    try {
        $json = $jsonText | ConvertFrom-Json
    } catch {
        throw "Failed to parse JSON from $ScriptPath. ExitCode=$($process.ExitCode). Output=$raw"
    }

    if ($process.ExitCode -ne 0) {
        $message = if ($json.Error) { [string]$json.Error } else { "ExitCode=$($process.ExitCode)" }
        throw $message
    }

    $json
}

function Convert-ToArgument([string]$Name, [string]$Value) {
    @($Name, ('"{0}"' -f ($Value -replace '"', '\"')))
}

function Invoke-SolidWorksSmoke([string]$PackageRoot, [string]$Label) {
    Stop-ZToolWorkflowProcesses

    $script = Join-Path $PSScriptRoot 'Test-ZToolSolidWorksSmoke.ps1'
    $args = New-Object System.Collections.Generic.List[string]
    $args.AddRange([string[]](Convert-ToArgument '-PackageRoot' $PackageRoot))
    $args.AddRange([string[]]@('-CommandTypesCsv', ('"{0}"' -f (($CommandTypes | ForEach-Object { [string]$_ }) -join ','))))
    $args.AddRange([string[]]@('-StartupTimeoutSeconds', [string]$StartupTimeoutSeconds))
    $args.AddRange([string[]]@('-CommandTimeoutSeconds', [string]$CommandTimeoutSeconds))

    if (-not [string]::IsNullOrWhiteSpace($SolidWorksExe)) {
        $args.AddRange([string[]](Convert-ToArgument '-SolidWorksExe' (Resolve-FullPath $SolidWorksExe)))
    }
    if (-not [string]::IsNullOrWhiteSpace($ModelPath)) {
        $args.AddRange([string[]](Convert-ToArgument '-ModelPath' (Resolve-FullPath $ModelPath)))
    }
    if ($ClickDemo) {
        $args.Add('-ClickDemo')
    }
    if ($SkipInitialActivation) {
        $args.Add('-SkipInitialActivation')
    }

    $timeout = $StartupTimeoutSeconds + ($CommandTimeoutSeconds * [Math]::Max(1, $CommandTypes.Count)) + 90
    $result = Invoke-JsonPowerShellScript -ScriptPath $script -Arguments $args.ToArray() -TimeoutSeconds $timeout
    if ([string]$result.Status -ne 'ok') {
        throw "$Label SolidWorks smoke failed: $($result.Error)"
    }

    $importStep = @($result.Steps | Where-Object { [string]$_.Name -eq 'active-assembly-import' } | Select-Object -First 1)
    if ($importStep.Count -eq 0 -or [string]$importStep[0].Status -ne 'ok') {
        throw "$Label did not prove active assembly import."
    }

    [pscustomobject]@{
        Status = [string]$result.Status
        SolidWorksRevision = [string]$result.SolidWorksRevision
        ActivationWindowTitle = [string]$result.ActivationWindowTitle
        DemoWindowTitle = [string]$result.DemoWindowTitle
        ImportDetail = [string]$importStep[0].Detail
        StepNames = @($result.Steps | ForEach-Object { [string]$_.Name })
    }
}

if ([string]::IsNullOrWhiteSpace($OriginalRoot)) {
    $OriginalRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path 'reference\ZTool-original'
}

$originalFull = Resolve-FullPath $OriginalRoot
$candidateFull = Resolve-FullPath $CandidateRoot
$checks = New-Object System.Collections.Generic.List[object]

$checks.Add((Invoke-Check -Name 'package-roots-exist' -Body {
    foreach ($root in @($originalFull, $candidateFull)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            throw "Package root not found: $root"
        }
        foreach ($file in @('ZTool.exe', 'ZTool.dll', 'ZTool.settings')) {
            $path = Join-Path $root $file
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required file missing: $path"
            }
        }
    }

    [pscustomobject]@{
        OriginalRoot = $originalFull
        CandidateRoot = $candidateFull
    }
}))

$checks.Add((Invoke-Check -Name 'binary-hashes' -Body {
    $originalExe = Join-Path $originalFull 'ZTool.exe'
    $candidateExe = Join-Path $candidateFull 'ZTool.exe'
    $originalDll = Join-Path $originalFull 'ZTool.dll'
    $candidateDll = Join-Path $candidateFull 'ZTool.dll'

    $originalDllHash = Get-FileSha256 $originalDll
    $candidateDllHash = Get-FileSha256 $candidateDll
    if (-not $AllowChangedAddInDll -and $originalDllHash -ne $candidateDllHash) {
        throw "Candidate ZTool.dll is not byte-for-byte equal to original. Original=$originalDllHash Candidate=$candidateDllHash"
    }

    [pscustomobject]@{
        OriginalExeSha256 = Get-FileSha256 $originalExe
        CandidateExeSha256 = Get-FileSha256 $candidateExe
        OriginalDllSha256 = $originalDllHash
        CandidateDllSha256 = $candidateDllHash
        AddInDllByteForByte = ($originalDllHash -eq $candidateDllHash)
    }
}))

if (-not $StaticOnly) {
    $baseline = $null
    $candidate = $null
    $baselineRuntimeRoot = $null

    try {
        $baselineRuntimeRoot = New-NormalizedOriginalRuntimeRoot $originalFull

        $checks.Add((Invoke-Check -Name 'original-solidworks-baseline' -Body {
            $script:baseline = Invoke-SolidWorksSmoke -PackageRoot $baselineRuntimeRoot -Label 'original'
            $script:baseline
        }))

        $checks.Add((Invoke-Check -Name 'candidate-solidworks-parity' -Body {
            $script:candidate = Invoke-SolidWorksSmoke -PackageRoot $candidateFull -Label 'candidate'
            $script:candidate
        }))

        $checks.Add((Invoke-Check -Name 'parity-comparison' -Body {
            if ($null -eq $script:baseline) {
                throw 'Original baseline did not complete; environment is not valid for parity judgement.'
            }
            if ($null -eq $script:candidate) {
                throw 'Candidate smoke did not complete.'
            }

            $requiredSteps = @(
                'load-addin',
                'get-addin-object',
                'open-test-model',
                'open-ztool-command',
                'click-connect-solidworks',
                'active-assembly-import'
            )
            foreach ($step in $requiredSteps) {
                if (@($script:baseline.StepNames | Where-Object { $_ -eq $step }).Count -gt 0 -and
                    @($script:candidate.StepNames | Where-Object { $_ -eq $step }).Count -eq 0) {
                    throw "Candidate missed baseline step: $step"
                }
            }

            [pscustomobject]@{
                OriginalImportDetail = $script:baseline.ImportDetail
                CandidateImportDetail = $script:candidate.ImportDetail
                OriginalSolidWorksRevision = $script:baseline.SolidWorksRevision
                CandidateSolidWorksRevision = $script:candidate.SolidWorksRevision
                CommandTypes = $CommandTypes
                OriginalRuntimeRoot = $baselineRuntimeRoot
            }
        }))
    } finally {
        if (-not $PreserveOriginalSettings -and
            -not [string]::IsNullOrWhiteSpace($baselineRuntimeRoot) -and
            (Test-Path -LiteralPath $baselineRuntimeRoot -PathType Container)) {
            Remove-Item -LiteralPath $baselineRuntimeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$failed = @($checks | Where-Object { $_.Status -ne 'ok' })
$summary = [pscustomobject]@{
    Status = if ($failed.Count -eq 0) { 'ok' } else { 'fail' }
    OriginalRoot = $originalFull
    CandidateRoot = $candidateFull
    StaticOnly = [bool]$StaticOnly
    Checks = $checks
}

$summary | ConvertTo-Json -Depth 10
if ($failed.Count -gt 0) {
    exit 1
}
