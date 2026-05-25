<?php
require_once __DIR__ . '/../includes/db.php';
require_once __DIR__ . '/../includes/helpers.php';
require_once __DIR__ . '/../includes/signer.php';

setCorsHeaders();

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

if ($key === '' || !isValidZToolKey($key)) {
    jsonError('Invalid license key.');
}

if ($machineId === '' || !preg_match('/^[a-f0-9]{64}$/i', $machineId)) {
    jsonError('Invalid machine id.');
}

$stmt = $db->prepare('SELECT * FROM license_keys WHERE license_key = ?');
$stmt->execute([$key]);
$license = $stmt->fetch();

if (!$license) {
    logAction($db, null, $key, $machineId, 'activate', false, 'Key not found');
    jsonError('License key was not found.', 404);
}

if (!$license['is_active'] || $license['is_revoked']) {
    logAction($db, (int)$license['id'], $key, $machineId, 'activate', false, 'Key inactive or revoked');
    jsonError('License key is inactive or revoked.', 403);
}

if (isLicenseExpired($license)) {
    logAction($db, (int)$license['id'], $key, $machineId, 'activate', false, 'Key expired');
    jsonError('License key is expired.', 403);
}

if (!empty($license['machine_id']) && $license['machine_id'] !== $machineId) {
    logAction($db, (int)$license['id'], $key, $machineId, 'activate', false, 'Machine mismatch');
    jsonError('License key is already activated on another machine.', 403);
}

if (empty($license['machine_id']) && (int)$license['current_activations'] >= (int)$license['max_activations']) {
    logAction($db, (int)$license['id'], $key, $machineId, 'activate', false, 'Activation limit reached');
    jsonError('Activation limit reached.', 403);
}

$machineMetaJson = is_array($machineMeta) ? json_encode($machineMeta, JSON_UNESCAPED_SLASHES) : null;

if (empty($license['machine_id'])) {
    $passwordHash = $transferPassword === '' ? null : password_hash($transferPassword, PASSWORD_BCRYPT);
    $stmt = $db->prepare(
        'UPDATE license_keys
         SET machine_id = ?, machine_label = ?, machine_meta = ?, platform = ?, app_version = ?,
             transfer_password_hash = COALESCE(transfer_password_hash, ?),
             activated_at = NOW(), last_check_at = NOW(), current_activations = current_activations + 1
         WHERE id = ?'
    );
    $stmt->execute([$machineId, $machineLabel, $machineMetaJson, $platform, $appVersion, $passwordHash, $license['id']]);
} else {
    $stmt = $db->prepare(
        'UPDATE license_keys
         SET machine_label = ?, machine_meta = ?, platform = ?, app_version = ?, last_check_at = NOW()
         WHERE id = ?'
    );
    $stmt->execute([$machineLabel, $machineMetaJson, $platform, $appVersion, $license['id']]);
}

$stmt = $db->prepare('SELECT * FROM license_keys WHERE id = ?');
$stmt->execute([$license['id']]);
$license = $stmt->fetch();

try {
    $signed = signLicensePayload(buildLicensePayload($license, $machineId));
} catch (Throwable $e) {
    logAction($db, (int)$license['id'], $key, $machineId, 'activate', false, 'Signing failed');
    jsonError('License signing failed.', 500);
}

logAction($db, (int)$license['id'], $key, $machineId, 'activate', true);

jsonResponse([
    'success' => true,
    'message' => 'License activated.',
    'license' => $signed['license'],
    'signedPayload' => $signed['signedPayload'],
    'signature' => $signed['signature'],
]);
