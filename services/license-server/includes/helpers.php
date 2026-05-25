<?php
require_once __DIR__ . '/../config.php';

function setCorsHeaders(): void
{
    $origin = $_SERVER['HTTP_ORIGIN'] ?? '';
    if ($origin !== '' && in_array($origin, ALLOWED_ORIGINS, true)) {
        header('Access-Control-Allow-Origin: ' . $origin);
    }

    header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
    header('Access-Control-Allow-Headers: Content-Type, Authorization');
    header('Access-Control-Max-Age: 86400');
    header('X-Frame-Options: DENY');
    header('X-Content-Type-Options: nosniff');
    header('Referrer-Policy: no-referrer');

    if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
        http_response_code(204);
        exit;
    }
}

function jsonResponse(array $data, int $statusCode = 200): void
{
    http_response_code($statusCode);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_SLASHES);
    exit;
}

function jsonError(string $message, int $statusCode = 400): void
{
    jsonResponse(['success' => false, 'error' => $message], $statusCode);
}

function getJsonInput(): array
{
    $body = file_get_contents('php://input');
    $data = json_decode($body, true);
    return is_array($data) ? $data : [];
}

function normalizeLicenseKey(string $key): string
{
    return strtoupper(trim($key));
}

function isValidZToolKey(string $key): bool
{
    return preg_match('/^[A-Z0-9]{8}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{9}$/', $key) === 1;
}

function generateZToolKey(): string
{
    $groups = [8, 5, 5, 5, 9];
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    $parts = [];

    foreach ($groups as $length) {
        $value = '';
        for ($i = 0; $i < $length; $i++) {
            $value .= $alphabet[random_int(0, strlen($alphabet) - 1)];
        }
        $parts[] = $value;
    }

    return implode('-', $parts);
}

function isLicenseExpired(array $license): bool
{
    $expires = trim((string)($license['expires_at'] ?? ''));
    if ($expires === '') {
        return false;
    }

    $timestamp = strtotime($expires);
    return $timestamp !== false && $timestamp < time();
}

function clientIp(): string
{
    return $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
}

function logAction(PDO $db, ?int $licenseId, ?string $licenseKey, ?string $machineId, string $action, bool $success, ?string $error = null): void
{
    $stmt = $db->prepare(
        'INSERT INTO activation_log (license_id, license_key, machine_id, action, success, error_message, ip_address, user_agent)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
    );
    $stmt->execute([
        $licenseId,
        $licenseKey,
        $machineId,
        $action,
        $success ? 1 : 0,
        $error,
        clientIp(),
        $_SERVER['HTTP_USER_AGENT'] ?? null,
    ]);
}

function enforceRateLimit(PDO $db, string $scope, int $maxAttempts, int $windowSeconds): void
{
    $key = $scope . ':' . clientIp();
    $db->prepare('DELETE FROM rate_limits WHERE expires_at < NOW()')->execute();

    $stmt = $db->prepare('SELECT COUNT(*) FROM rate_limits WHERE rate_key = ?');
    $stmt->execute([$key]);
    $count = (int)$stmt->fetchColumn();
    if ($count >= $maxAttempts) {
        jsonError('Too many attempts. Try again later.', 429);
    }

    $stmt = $db->prepare('INSERT INTO rate_limits (rate_key, expires_at) VALUES (?, DATE_ADD(NOW(), INTERVAL ? SECOND))');
    $stmt->execute([$key, $windowSeconds]);
}
