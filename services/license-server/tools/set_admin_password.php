<?php
// Updates ADMIN_PASS_HASH in config.php without committing the hash.

if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit;
}

$configPath = $argv[1] ?? (__DIR__ . '/../config.php');
$password = getenv('ZTOOL_ADMIN_PASSWORD');

if ($password === false || $password === '') {
    fwrite(STDERR, "Set ZTOOL_ADMIN_PASSWORD before running this tool.\n");
    fwrite(STDERR, "Usage: ZTOOL_ADMIN_PASSWORD='new-password' php tools/set_admin_password.php [config.php]\n");
    exit(1);
}

if (!is_file($configPath)) {
    fwrite(STDERR, "Config file was not found: {$configPath}\n");
    exit(1);
}

$config = file_get_contents($configPath);
if ($config === false) {
    fwrite(STDERR, "Config file could not be read: {$configPath}\n");
    exit(1);
}

$hash = password_hash($password, PASSWORD_BCRYPT);
$pattern = "/define\\(\\s*'ADMIN_PASS_HASH'\\s*,\\s*'[^']*'\\s*\\)\\s*;/";
$updated = preg_replace_callback(
    $pattern,
    static function () use ($hash): string {
        return "define('ADMIN_PASS_HASH', '" . $hash . "');";
    },
    $config,
    1,
    $count
);

if ($updated === null || $count !== 1) {
    fwrite(STDERR, "ADMIN_PASS_HASH define was not found or could not be updated.\n");
    exit(1);
}

$tempPath = $configPath . '.tmp';
if (file_put_contents($tempPath, $updated, LOCK_EX) === false) {
    fwrite(STDERR, "Temporary config file could not be written: {$tempPath}\n");
    exit(1);
}

if (!rename($tempPath, $configPath)) {
    @unlink($tempPath);
    fwrite(STDERR, "Config file could not be replaced: {$configPath}\n");
    exit(1);
}

echo "Updated ADMIN_PASS_HASH in {$configPath}\n";
