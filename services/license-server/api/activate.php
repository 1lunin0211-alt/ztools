<?php
require_once __DIR__ . '/../includes/db.php';
require_once __DIR__ . '/../includes/helpers.php';
require_once __DIR__ . '/../includes/signer.php';

setCorsHeaders();

set_exception_handler(function (Throwable $e): void {
    error_log('ZTool activate unhandled error: ' . $e->getMessage());
    jsonError('License activation failed.', 500);
});

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    jsonError('Method not allowed', 405);
}

$db = getDB();
enforceRateLimit($db, 'ztool_activate', 10, 60);

$input = getJsonInput();
$key = normalizeLicenseKey((string)($input['key'] ?? ''));
$machineId = trim((string)($input['machineId'] ?? ''));
$machineLabel = trim((string)($input['machineLabel'] ?? ''));
$machineMeta = $input['machineMeta'] ?? null;
$platform = trim((string)($input['platform'] ?? ''));
$appVersion = trim((string)($input['appVersion'] ?? ''));
$transferPassword = (string)($input['transferPassword'] ?? '');
$productId = strtolower(trim((string)($input['productId'] ?? 'ztool')));

if ($productId === '') {
    $productId = 'ztool';
}

if (!hash_equals('ztool', $productId)) {
    jsonError('Invalid product id.');
}

if ($key === '' || !isValidZToolKey($key)) {
    jsonError('Invalid license key.');
}

if ($machineId === '' || !preg_match('/^[a-f0-9]{64}$/i', $machineId)) {
    jsonError('Invalid machine id.');
}

function failActivation(PDO $db, ?array $license, string $key, string $machineId, string $reason, string $message, int $statusCode = 400): void
{
    if ($db->inTransaction()) {
        $db->rollBack();
    }

    logAction($db, $license ? (int)$license['id'] : null, $key, $machineId, 'activate', false, $reason);
    jsonError($message, $statusCode);
}

$db->beginTransaction();

$stmt = $db->prepare('SELECT * FROM license_keys WHERE license_key = ? FOR UPDATE');
$stmt->execute([$key]);
$license = $stmt->fetch();

if (!$license) {
    failActivation($db, null, $key, $machineId, 'Key not found', 'License key was not found.', 404);
}

if (!$license['is_active'] || $license['is_revoked']) {
    failActivation($db, $license, $key, $machineId, 'Key inactive or revoked', 'License key is inactive or revoked.', 403);
}

if (isLicenseExpired($license)) {
    failActivation($db, $license, $key, $machineId, 'Key expired', 'License key is expired.', 403);
}

if (!empty($license['machine_id']) && $license['machine_id'] !== $machineId) {
    failActivation($db, $license, $key, $machineId, 'Machine mismatch', 'License key is already activated on another machine.', 403);
}

$machineMetaJson = is_array($machineMeta) ? json_encode($machineMeta, JSON_UNESCAPED_SLASHES) : null;

if (empty($license['machine_id'])) {
    if ((int)$license['current_activations'] >= (int)$license['max_activations']) {
        failActivation($db, $license, $key, $machineId, 'Activation limit reached', 'Activation limit reached.', 403);
    }

    if (!isValidTransferPassword($transferPassword)) {
        failActivation($db, $license, $key, $machineId, 'Missing or invalid transfer password', 'Transfer password must be 8-64 printable characters and include letters and digits.', 400);
    }

    $passwordHash = password_hash($transferPassword, PASSWORD_BCRYPT);
    if ($passwordHash === false) {
        failActivation($db, $license, $key, $machineId, 'Password hash failed', 'License activation failed.', 500);
    }

    $stmt = $db->prepare(
        'UPDATE license_keys
         SET machine_id = ?, machine_label = ?, machine_meta = ?, platform = ?, app_version = ?,
             transfer_password_hash = ?,
             activated_at = NOW(), last_check_at = NOW(), current_activations = current_activations + 1
         WHERE id = ? AND machine_id IS NULL AND current_activations < max_activations'
    );
    $stmt->execute([$machineId, $machineLabel, $machineMetaJson, $platform, $appVersion, $passwordHash, $license['id']]);
    if ($stmt->rowCount() !== 1) {
        failActivation($db, $license, $key, $machineId, 'Concurrent activation conflict', 'Activation limit reached.', 409);
    }
} else {
    if (empty($license['transfer_password_hash'])) {
        if (!isValidTransferPassword($transferPassword)) {
            failActivation($db, $license, $key, $machineId, 'Transfer password hash missing', 'Transfer password must be set before the license can be transferred.', 400);
        }

        $passwordHash = password_hash($transferPassword, PASSWORD_BCRYPT);
        if ($passwordHash === false) {
            failActivation($db, $license, $key, $machineId, 'Password hash failed', 'License activation failed.', 500);
        }

        $stmt = $db->prepare(
            'UPDATE license_keys
             SET machine_label = ?, machine_meta = ?, platform = ?, app_version = ?,
                 transfer_password_hash = ?, last_check_at = NOW()
             WHERE id = ?'
        );
        $stmt->execute([$machineLabel, $machineMetaJson, $platform, $appVersion, $passwordHash, $license['id']]);
    } else {
        $stmt = $db->prepare(
            'UPDATE license_keys
             SET machine_label = ?, machine_meta = ?, platform = ?, app_version = ?, last_check_at = NOW()
             WHERE id = ?'
        );
        $stmt->execute([$machineLabel, $machineMetaJson, $platform, $appVersion, $license['id']]);
    }
}

$stmt = $db->prepare('SELECT * FROM license_keys WHERE id = ?');
$stmt->execute([$license['id']]);
$license = $stmt->fetch();

try {
    $signed = signLicensePayload(buildLicensePayload($license, $machineId));
} catch (Throwable $e) {
    failActivation($db, $license, $key, $machineId, 'Signing failed', 'License signing failed.', 500);
}

$db->commit();
logAction($db, (int)$license['id'], $key, $machineId, 'activate', true);

jsonResponse([
    'success' => true,
    'message' => 'License activated.',
    'license' => $signed['license'],
    'signedPayload' => $signed['signedPayload'],
    'signature' => $signed['signature'],
]);
