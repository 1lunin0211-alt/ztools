<?php
require_once __DIR__ . '/../includes/helpers.php';

setCorsHeaders();

if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
    jsonError('Method not allowed', 405);
}

$keyPath = defined('PUBLIC_KEY_PATH') ? PUBLIC_KEY_PATH : (__DIR__ . '/../keys/license_public.pem');
if (!is_file($keyPath)) {
    jsonError('Public key is not configured.', 404);
}

$publicKey = openssl_pkey_get_public(file_get_contents($keyPath));
if (!$publicKey) {
    jsonError('Public key cannot be loaded.', 500);
}

$details = openssl_pkey_get_details($publicKey);
if (!is_array($details) || empty($details['rsa']['n']) || empty($details['rsa']['e'])) {
    jsonError('Public key does not contain RSA modulus/exponent.', 500);
}

$publicKeyXml =
    "<RSAKeyValue>\n" .
    "  <Modulus>" . base64_encode($details['rsa']['n']) . "</Modulus>\n" .
    "  <Exponent>" . base64_encode($details['rsa']['e']) . "</Exponent>\n" .
    "</RSAKeyValue>\n";

jsonResponse([
    'success' => true,
    'productId' => 'ztool',
    'algorithm' => 'RSA-SHA256',
    'publicKeyXml' => $publicKeyXml,
]);
