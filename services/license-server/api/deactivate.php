<?php
require_once __DIR__ . '/../includes/db.php';
require_once __DIR__ . '/../includes/helpers.php';

setCorsHeaders();

set_exception_handler(function (Throwable $e): void {
    error_log('ZTool deactivate unhandled error: ' . $e->getMessage());
    jsonError('License deactivation failed.', 500);
});

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    jsonError('Method not allowed', 405);
}

$db = getDB();
enforceRateLimit($db, 'ztool_deactivate', 5, 60);

$input = getJsonInput();
$key = normalizeLicenseKey((string)($input['key'] ?? ''));
$machineId = trim((string)($input['machineId'] ?? ''));
$transferPassword = (string)($input['transferPassword'] ?? '');
$productId = strtolower(trim((string)($input['productId'] ?? 'ztool')));

if ($productId === '') {
    $productId = 'ztool';
}

if (!hash_equals('ztool', $productId)) {
    jsonError('Invalid product id.');
}

if ($key === '' || $machineId === '') {
    jsonError('License key and machine id are required.');
}

if (!isValidZToolKey($key) || !preg_match('/^[a-f0-9]{64}$/i', $machineId)) {
    jsonError('Invalid license key or machine id.');
}

function failDeactivation(PDO $db, ?array $license, string $key, string $machineId, string $reason, string $message, int $statusCode = 400): void
{
    if ($db->inTransaction()) {
        $db->rollBack();
    }

    logAction($db, $license ? (int)$license['id'] : null, $key, $machineId, 'deactivate', false, $reason);
    jsonError($message, $statusCode);
}

$db->beginTransaction();

$stmt = $db->prepare('SELECT * FROM license_keys WHERE license_key = ? FOR UPDATE');
$stmt->execute([$key]);
$license = $stmt->fetch();

if (!$license) {
    failDeactivation($db, null, $key, $machineId, 'Key not found', 'License key was not found.', 404);
}

if (!$license['transfer_allowed']) {
    failDeactivation($db, $license, $key, $machineId, 'Transfer denied', 'License transfer is not allowed.', 403);
}

if ($license['machine_id'] !== $machineId) {
    failDeactivation($db, $license, $key, $machineId, 'Machine mismatch', 'License can be deactivated only from the activated machine.', 403);
}

if (empty($license['transfer_password_hash'])) {
    failDeactivation($db, $license, $key, $machineId, 'Transfer password hash missing', 'Transfer password is not configured for this activation. Reset the binding in admin panel.', 403);
}

if (!isValidTransferPassword($transferPassword) || !password_verify($transferPassword, $license['transfer_password_hash'])) {
    failDeactivation($db, $license, $key, $machineId, 'Invalid transfer password', 'Invalid transfer password.', 403);
}

$stmt = $db->prepare(
    'UPDATE license_keys
     SET machine_id = NULL, machine_label = NULL, machine_meta = NULL, platform = NULL, app_version = NULL,
         transfer_password_hash = NULL, activated_at = NULL, last_check_at = NOW(),
         current_activations = GREATEST(current_activations - 1, 0)
     WHERE id = ? AND machine_id = ?'
);
$stmt->execute([$license['id'], $machineId]);
if ($stmt->rowCount() !== 1) {
    failDeactivation($db, $license, $key, $machineId, 'Concurrent deactivation conflict', 'License deactivation failed.', 409);
}

$db->commit();
logAction($db, (int)$license['id'], $key, $machineId, 'deactivate', true);

jsonResponse([
    'success' => true,
    'message' => 'License deactivated.',
]);
