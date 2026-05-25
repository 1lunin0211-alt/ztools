param(
    [string]$LicenseBaseUrl = 'https://license.vizbuka.ru/ztool',
    [string]$TestLicenseKey = $env:ZTOOL_TEST_KEY,
    [string]$TransferPassword = $env:ZTOOL_TRANSFER_PASSWORD
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-LicenseRequest([string]$Name, [string]$Uri, [string]$Method = 'GET', [object]$Body = $null) {
    $request = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.Method = $Method
        $request.Accept = 'application/json'
        $request.Timeout = 20000
        $request.ReadWriteTimeout = 20000
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 8
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $request.ContentType = 'application/json'
            $request.ContentLength = $bytes.Length
            $stream = $request.GetRequestStream()
            try {
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $stream.Dispose()
            }
        }

        $response = $request.GetResponse()
        try {
            $statusCode = [int]$response.StatusCode
            $contentType = [string]$response.Headers['Content-Type']
            $reader = [System.IO.StreamReader]::new($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            try {
                $content = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
        } finally {
            $response.Dispose()
        }

        [pscustomobject]@{
            Name = $Name
            Status = 'ok'
            StatusCode = $statusCode
            ContentType = $contentType
            Content = [string]$content
        }
    } catch {
        $caught = $_.Exception
        $webException = $null
        while ($null -ne $caught) {
            $webException = $caught -as [System.Net.WebException]
            if ($null -ne $webException) {
                break
            }

            $caught = $caught.InnerException
        }

        if ($null -ne $webException -and $null -ne $webException.Response) {
            $response = [System.Net.HttpWebResponse]$webException.Response
            try {
                $statusCode = [int]$response.StatusCode
                $contentType = [string]$response.Headers['Content-Type']
                $reader = [System.IO.StreamReader]::new($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
                try {
                    $content = $reader.ReadToEnd()
                } finally {
                    $reader.Dispose()
                }
            } finally {
                $response.Dispose()
            }

            return [pscustomobject]@{
                Name = $Name
                Status = 'ok'
                StatusCode = $statusCode
                ContentType = $contentType
                Content = [string]$content
            }
        }

        [pscustomobject]@{
            Name = $Name
            Status = 'error'
            StatusCode = 0
            ContentType = ''
            Content = $_.Exception.Message
        }
    }
}

function New-SmokeMachineId {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('codex-smoke:' + $env:COMPUTERNAME)
        ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

$base = $LicenseBaseUrl.TrimEnd('/')
$results = New-Object System.Collections.Generic.List[object]
$missingWellFormedKey = 'ABCDEFGH-ABCDE-ABCDE-ABCDE-ABCDEFGHJ'
$smokeTransferPassword = if ([string]::IsNullOrWhiteSpace($TransferPassword)) { 'TestPass123' } else { $TransferPassword }

$results.Add((Invoke-LicenseRequest -Name 'public-key-export' -Uri "$base/tools/export_public_key_xml.php"))
$results.Add((Invoke-LicenseRequest -Name 'public-key-api' -Uri "$base/api/public-key.php"))
$results.Add((Invoke-LicenseRequest -Name 'activate-get' -Uri "$base/api/activate.php"))

$invalidActivation = Invoke-LicenseRequest -Name 'activate-invalid-key' -Uri "$base/api/activate.php" -Method POST -Body @{
    key = 'TEST-NO-SUCH-KEY'
    productId = 'ztool'
    transferPassword = $smokeTransferPassword
    machineId = New-SmokeMachineId
    machineLabel = 'Codex smoke'
    platform = 'windows'
    appVersion = 'smoke'
    machineMeta = @{ smoke = $true }
}
$results.Add($invalidActivation)

$invalidDeactivation = Invoke-LicenseRequest -Name 'deactivate-invalid-key' -Uri "$base/api/deactivate.php" -Method POST -Body @{
    key = $missingWellFormedKey
    productId = 'ztool'
    transferPassword = $smokeTransferPassword
    machineId = New-SmokeMachineId
}
$results.Add($invalidDeactivation)

if (-not [string]::IsNullOrWhiteSpace($TestLicenseKey)) {
    if ([string]::IsNullOrWhiteSpace($TransferPassword)) {
        $results.Add([pscustomobject]@{
            Name = 'activate-real-test-key'
            Status = 'error'
            StatusCode = 0
            ContentType = ''
            Content = 'TransferPassword or ZTOOL_TRANSFER_PASSWORD is required for a real test key.'
        })
    } else {
        $realSmokeMachineId = New-SmokeMachineId
        $realActivation = Invoke-LicenseRequest -Name 'activate-real-test-key' -Uri "$base/api/activate.php" -Method POST -Body @{
            key = $TestLicenseKey
            productId = 'ztool'
            transferPassword = $TransferPassword
            machineId = $realSmokeMachineId
            machineLabel = 'Codex smoke'
            platform = 'windows'
            appVersion = 'smoke'
            machineMeta = @{ smoke = $true }
        }
        $results.Add($realActivation)

        if ($realActivation.StatusCode -eq 200) {
            $realDeactivation = Invoke-LicenseRequest -Name 'deactivate-real-test-key' -Uri "$base/api/deactivate.php" -Method POST -Body @{
                key = $TestLicenseKey
                productId = 'ztool'
                transferPassword = $TransferPassword
                machineId = $realSmokeMachineId
            }
            $results.Add($realDeactivation)
        }
    }
}

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

$activateGet = $results | Where-Object Name -eq 'activate-get' | Select-Object -First 1
if ($activateGet.StatusCode -ne 405 -or $activateGet.Content -notmatch 'Method not allowed') {
    $errors.Add('activate.php GET should return 405 JSON Method not allowed.')
}

$activateInvalid = $results | Where-Object Name -eq 'activate-invalid-key' | Select-Object -First 1
if ($activateInvalid.StatusCode -ne 400 -or $activateInvalid.Content -notmatch 'Invalid license key') {
    $errors.Add('activate.php invalid-key smoke did not return expected JSON business error.')
}

$deactivateInvalid = $results | Where-Object Name -eq 'deactivate-invalid-key' | Select-Object -First 1
if ($deactivateInvalid.StatusCode -ne 404 -or $deactivateInvalid.Content -notmatch 'License key was not found') {
    $errors.Add('deactivate.php invalid-key smoke did not return expected JSON business error.')
}

$publicKey = $results | Where-Object Name -eq 'public-key-export' | Select-Object -First 1
$publicKeyApi = $results | Where-Object Name -eq 'public-key-api' | Select-Object -First 1
if ($publicKeyApi.StatusCode -eq 200 -and $publicKeyApi.Content -match '<RSAKeyValue>') {
    $publicKeyStatus = 'api-available'
} elseif ($publicKey.StatusCode -eq 200 -and $publicKey.Content -match '<RSAKeyValue>') {
    $publicKeyStatus = 'available'
} elseif ($publicKey.StatusCode -eq 403) {
    $publicKeyStatus = 'forbidden'
    $warnings.Add('Public key export is forbidden; pass an exported license_public.xml to production build or deploy api/public-key.php.')
} else {
    $publicKeyStatus = 'missing-or-unexpected'
    $warnings.Add('Public key export is neither available nor intentionally forbidden.')
}

$realActivation = $results | Where-Object Name -eq 'activate-real-test-key' | Select-Object -First 1
if ($null -ne $realActivation) {
    if ($realActivation.StatusCode -ne 200 -or $realActivation.Content -notmatch 'signedPayload' -or $realActivation.Content -notmatch 'signature') {
        $errors.Add('activate.php real test key did not return a signed license payload.')
    }

    $realActivation.Content = '[redacted-real-test-activation]'
}

$realDeactivation = $results | Where-Object Name -eq 'deactivate-real-test-key' | Select-Object -First 1
if ($null -ne $realDeactivation) {
    if ($realDeactivation.StatusCode -ne 200 -or $realDeactivation.Content -notmatch '"success"\s*:\s*true') {
        $errors.Add('deactivate.php real test key did not release the smoke activation.')
    }

    $realDeactivation.Content = '[redacted-real-test-deactivation]'
}

[pscustomobject]@{
    Status = if ($errors.Count -eq 0) { 'ok' } else { 'fail' }
    LicenseBaseUrl = $base
    PublicKeyExport = $publicKeyStatus
    Results = $results
    Warnings = $warnings
    Errors = $errors
} | ConvertTo-Json -Depth 6

if ($errors.Count -gt 0) {
    exit 1
}
