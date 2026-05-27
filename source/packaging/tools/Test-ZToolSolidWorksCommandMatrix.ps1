param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$SolidWorksExe = '',

    [string]$ModelPath = '',

    [int[]]$CommandTypes = @(0, 1, 2, 3, 4, 5, 6, 120, 130),

    [int]$DemoSeconds = 60,

    [int]$PerCommandTimeoutSeconds = 90,

    [switch]$ClickDemo,

    [switch]$SkipInitialActivation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Stop-TestProcesses {
    Get-Process ZTool,SLDWORKS,sldworks -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Get-ZToolSolidWorksApplicationErrors([DateTime]$StartTime) {
    @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $StartTime } -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProviderName -in @('.NET Runtime', 'Application Error', 'Windows Error Reporting') -and
            ($_.Message -like '*ZTool*' -or $_.Message -like '*SLDWORKS*' -or $_.Message -like '*sldworks*')
        } |
        Select-Object TimeCreated, ProviderName, Id, Message)
}

$packageFull = Resolve-FullPath $PackageRoot
if (-not (Test-Path -LiteralPath (Join-Path $packageFull 'ZTool.dll') -PathType Leaf)) {
    throw "PackageRoot does not contain ZTool.dll: $packageFull"
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($commandType in $CommandTypes) {
    Stop-TestProcesses
    Remove-Item "$env:LOCALAPPDATA\SWTools\ZTool.license.json", "$env:LOCALAPPDATA\SWTools\ZTool.demo.lease" -Force -ErrorAction SilentlyContinue

    $startedAt = [DateTime]::Now
    $oldDemoSeconds = [Environment]::GetEnvironmentVariable('ZTOOL_DEMO_SECONDS')
    [Environment]::SetEnvironmentVariable('ZTOOL_DEMO_SECONDS', [string]$DemoSeconds)
    $job = $null
    try {
        $script = Join-Path $PSScriptRoot 'Test-ZToolSolidWorksSmoke.ps1'
        $job = Start-Job -ScriptBlock {
            param(
                $ScriptPath,
                $PackageRootValue,
                $CommandTypeValue,
                $SolidWorksExeValue,
                $ModelPathValue,
                $ClickDemoValue,
                $SkipInitialActivationValue,
                $TimeoutValue
            )

            $args = @{
                PackageRoot = $PackageRootValue
                CommandTypes = @(0, $CommandTypeValue)
                StartupTimeoutSeconds = 150
                CommandTimeoutSeconds = $TimeoutValue
            }
            if (-not [string]::IsNullOrWhiteSpace($SolidWorksExeValue)) {
                $args.SolidWorksExe = $SolidWorksExeValue
            }
            if (-not [string]::IsNullOrWhiteSpace($ModelPathValue)) {
                $args.ModelPath = $ModelPathValue
            }
            if ($ClickDemoValue) {
                $args.ClickDemo = $true
            }
            if ($SkipInitialActivationValue) {
                $args.SkipInitialActivation = $true
            }

            & $ScriptPath @args
        } -ArgumentList $script, $packageFull, $commandType, $SolidWorksExe, $ModelPath, ([bool]$ClickDemo), ([bool]$SkipInitialActivation), $PerCommandTimeoutSeconds

        $completed = Wait-Job -Job $job -Timeout $PerCommandTimeoutSeconds
        if ($null -eq $completed) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            $raw = "Timed out after $PerCommandTimeoutSeconds seconds."
            $status = 'timeout'
            $smoke = $null
        } else {
            $rawOutput = Receive-Job -Job $job -ErrorAction SilentlyContinue
            $raw = ($rawOutput | ForEach-Object { [string]$_ }) -join "`n"
            try {
                $smoke = $raw | ConvertFrom-Json
                $status = [string]$smoke.Status
            } catch {
                $smoke = $null
                $status = 'parse-fail'
            }
        }

        $events = @(Get-ZToolSolidWorksApplicationErrors $startedAt)
        if ($events.Count -gt 0 -and $status -eq 'ok') {
            $status = 'fail'
        }

        $results.Add([pscustomobject]@{
            CommandType = $commandType
            Status = $status
            Smoke = $smoke
            ApplicationErrors = @($events | ForEach-Object {
                [pscustomobject]@{
                    TimeCreated = $_.TimeCreated
                    ProviderName = $_.ProviderName
                    Id = $_.Id
                    FirstLine = ($_.Message -split "`r?`n")[0]
                }
            })
            Raw = if ($status -in @('parse-fail', 'timeout')) { $raw } else { '' }
        })
    } finally {
        if ($job) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }

        [Environment]::SetEnvironmentVariable('ZTOOL_DEMO_SECONDS', $oldDemoSeconds)
        Stop-TestProcesses
        Start-Sleep -Seconds 2
    }
}

$failed = @($results | Where-Object { $_.Status -ne 'ok' })
[pscustomobject]@{
    Status = if ($failed.Count -eq 0) { 'ok' } else { 'fail' }
    PackageRoot = $packageFull
    Results = $results
} | ConvertTo-Json -Depth 10

if ($failed.Count -gt 0) {
    exit 1
}
