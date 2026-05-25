<?php
// Copy this file to config.php and fill production values.

define('DEBUG', false);

define('DB_HOST', 'localhost');
define('DB_NAME', 'ztool_license');
define('DB_USER', '');
define('DB_PASS', '');
define('DB_CHARSET', 'utf8mb4');

define('PRIVATE_KEY_PATH', __DIR__ . '/keys/license_private.pem');
define('PUBLIC_KEY_PATH', __DIR__ . '/keys/license_public.pem');

define('ADMIN_USER', 'admin');
// Generate: php -r "echo password_hash('change-me', PASSWORD_BCRYPT), PHP_EOL;"
// Or rotate config.php with: ZTOOL_ADMIN_PASSWORD='new-password' php tools/set_admin_password.php
define('ADMIN_PASS_HASH', '');

define('LOGIN_MAX_ATTEMPTS', 5);
define('LOGIN_LOCKOUT_SECONDS', 900);

define('ALLOWED_ORIGINS', []);

error_reporting(DEBUG ? E_ALL : 0);
ini_set('display_errors', DEBUG ? '1' : '0');
date_default_timezone_set('Asia/Qyzylorda');
