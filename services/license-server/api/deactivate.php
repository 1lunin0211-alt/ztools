<?php
require_once __DIR__ . '/../includes/db.php';
require_once __DIR__ . '/../includes/helpers.php';

setCorsHeaders();

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    jsonError('Method not allowed', 405);
}

$db = getDB();
enforceRateLimit($db, 'ztool_deactivate', 5, 60);

$input = getJsonInput();
$key = normalizeLicenseKey((string)($input['key'] ?? ''));
$machineId = trim((string)($input['machineId'] ?? ''));
$transferPassword = (string)($input['transferPassword'] ?? '');

if ($key === '' || $machineId === '') {
    jsonError('License key and machine id are required.');
}

$stmt = $db->prepare('SELECT * FROM license_keys WHERE license_key = ?');
$stmt->execute([$key]);
$license = $stmt->fetch();

if (!$license) {
    logAction($db, null, $key, $machineId, 'deactivate', false, 'Key not found');
    jsonError('License key was not found.', 404);
}

if (!$license['transfer_allowed']) {
    logAction($db, (int)$license['id'], $key, $machineId, 'deactivate', false, 'Transfer denied');
    jsonError('License transfer is not allowed.', 403);
}

if ($license['machine_id'] !== $machineId) {
    logAction($db, (int)$license['id'], $key, $machineId, 'deactivate', false, 'Machine mismatch');
    jsonError('License can be deactivated only from the activated machine.', 403);
}

if (!empty($license['transfer_password_hash']) && !password_verify($transferPassword, $license['transfer_password_hash'])) {
    logAction($db, (int)$license['id'], $key, $machineId, 'deactivate', false, 'Invalid transfer password');
    jsonError('Invalid transfer password.', 403);
}

$stmt = $db->prepare(
    'UPDATE license_keys
     SET machine_id = NULL, machine_label = NULL, machine_meta = NULL, platform = NULL, app_version = NULL,
         activated_at = NULL, last_check_at = NOW(), current_activations = GREATEST(current_activations - 1, 0)
     WHERE id = ?'
);
$stmt->execute([$license['id']]);

logAction($db, (int)$license['id'], $key, $machineId, 'deactivate', true);

jsonResponse([
    'success' => true,
    'message' => 'License deactivated.',
]);
