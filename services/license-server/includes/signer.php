<?php

function buildLicensePayload(array $license, string $machineId): array
{
    $isActive = !empty($license['is_active']);
    $isRevoked = !empty($license['is_revoked']);
    $isExpired = isLicenseExpired($license);
    $isMachineMatch = empty($license['machine_id']) || hash_equals((string)$license['machine_id'], $machineId);
    $valid = $isActive && !$isRevoked && !$isExpired && $isMachineMatch;

    return [
        'productId' => 'ztool',
        'licenseId' => (int)$license['id'],
        'key' => $license['license_key'],
        'status' => $valid ? 'active' : 'invalid',
        'valid' => $valid,
        'isActive' => $isActive,
        'isRevoked' => $isRevoked,
        'licenseType' => $license['license_type'] ?? 'ztool_perpetual',
        'customerName' => $license['customer_name'] ?? '',
        'organization' => $license['organization'] ?? null,
        'email' => $license['customer_email'] ?? null,
        'issuedAt' => $license['created_at'] ?? null,
        'activatedAt' => $license['activated_at'] ?: date('Y-m-d H:i:s'),
        'expiresAt' => $license['expires_at'] ?? null,
        'serverTime' => gmdate('c'),
        'machineId' => $machineId,
        'hardwareBound' => true,
        'permanent' => empty($license['expires_at']),
        'offlineAllowed' => true,
        'transferAllowed' => !empty($license['transfer_allowed']),
        'seats' => (int)($license['max_activations'] ?? 1),
        'payloadKey' => defined('PAYLOAD_KEY') ? PAYLOAD_KEY : 'change-me-in-config-php',
    ];
}

function loadPrivateKey()
{
    if (!defined('PRIVATE_KEY_PATH') || !file_exists(PRIVATE_KEY_PATH)) {
        throw new RuntimeException('Private key is not configured.');
    }

    $privateKey = openssl_pkey_get_private(file_get_contents(PRIVATE_KEY_PATH));
    if (!$privateKey) {
        throw new RuntimeException('Private key cannot be loaded.');
    }

    return $privateKey;
}

function signLicensePayload(array $payload): array
{
    $json = json_encode($payload, JSON_UNESCAPED_SLASHES);
    $signature = '';
    $ok = openssl_sign($json, $signature, loadPrivateKey(), OPENSSL_ALGO_SHA256);
    if (!$ok) {
        throw new RuntimeException('License signing failed.');
    }

    return [
        'license' => $payload,
        'signedPayload' => $json,
        'signature' => base64_encode($signature),
    ];
}
