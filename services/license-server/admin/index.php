<?php
require_once __DIR__ . '/../includes/db.php';
require_once __DIR__ . '/../includes/helpers.php';

function configureAdminSession(): void
{
    ini_set('session.use_strict_mode', '1');
    session_name('ztool_license_admin_session');

    $secure = !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off';
    if (PHP_VERSION_ID >= 70300) {
        session_set_cookie_params([
            'lifetime' => 0,
            'path' => '',
            'domain' => '',
            'secure' => $secure,
            'httponly' => true,
            'samesite' => 'Strict',
        ]);
        return;
    }

    session_set_cookie_params(0, '', '', $secure, true);
}

configureAdminSession();
session_start();

function isAdminLoggedIn(): bool
{
    return !empty($_SESSION['ztool_license_admin']);
}

function requireAdmin(): void
{
    if (!isAdminLoggedIn()) {
        header('Location: ?login=1');
        exit;
    }
}

function h(?string $value): string
{
    return htmlspecialchars((string)$value, ENT_QUOTES, 'UTF-8');
}

function csrfToken(): string
{
    if (empty($_SESSION['ztool_license_csrf']) || !is_string($_SESSION['ztool_license_csrf'])) {
        $_SESSION['ztool_license_csrf'] = bin2hex(random_bytes(32));
    }

    return $_SESSION['ztool_license_csrf'];
}

function isValidCsrfToken(): bool
{
    $posted = (string)($_POST['csrf_token'] ?? '');
    return $posted !== '' && hash_equals(csrfToken(), $posted);
}

function isAdminLoginAllowed(PDO $db): bool
{
    return !isRateLimited($db, 'ztool_admin_login', LOGIN_MAX_ATTEMPTS);
}

function recordAdminLoginFailure(PDO $db): void
{
    recordRateLimitAttempt($db, 'ztool_admin_login', LOGIN_LOCKOUT_SECONDS);
}

$db = getDB();
$error = '';
$message = '';

if (isset($_GET['logout'])) {
    $_SESSION = [];
    session_destroy();
    header('Location: ?login=1');
    exit;
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && ($_POST['action'] ?? '') === 'login') {
    $user = (string)($_POST['user'] ?? '');
    $pass = (string)($_POST['password'] ?? '');
    if (!isValidCsrfToken()) {
        $error = 'Invalid request token.';
    } elseif (!isAdminLoginAllowed($db)) {
        $error = 'Too many failed login attempts. Try again later.';
    } elseif ($user === ADMIN_USER && ADMIN_PASS_HASH !== '' && password_verify($pass, ADMIN_PASS_HASH)) {
        session_regenerate_id(true);
        $_SESSION['ztool_license_admin'] = true;
        header('Location: ./');
        exit;
    } else {
        recordAdminLoginFailure($db);
        $error = 'Invalid login.';
    }
}

if (!isAdminLoggedIn()) {
    ?>
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>ZTool License Admin</title></head>
<body>
<h1>ZTool License Admin</h1>
<?php if ($error !== ''): ?><p style="color:#a00"><?= h($error) ?></p><?php endif; ?>
<form method="post">
  <input type="hidden" name="action" value="login">
  <input type="hidden" name="csrf_token" value="<?= h(csrfToken()) ?>">
  <p><label>User<br><input name="user" autocomplete="username"></label></p>
  <p><label>Password<br><input name="password" type="password" autocomplete="current-password"></label></p>
  <button type="submit">Login</button>
</form>
</body>
</html>
<?php
    exit;
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = (string)($_POST['action'] ?? '');

    if (!isValidCsrfToken()) {
        http_response_code(400);
        $error = 'Invalid request token.';
    } elseif ($action === 'create') {
        $key = generateZToolKey();
        $stmt = $db->prepare(
            'INSERT INTO license_keys (license_key, customer_name, customer_email, organization, notes, transfer_allowed)
             VALUES (?, ?, ?, ?, ?, ?)'
        );
        $stmt->execute([
            $key,
            trim((string)($_POST['customer_name'] ?? 'Customer')),
            trim((string)($_POST['customer_email'] ?? '')),
            trim((string)($_POST['organization'] ?? '')),
            trim((string)($_POST['notes'] ?? '')),
            isset($_POST['transfer_allowed']) ? 1 : 0,
        ]);
        logAction($db, (int)$db->lastInsertId(), $key, null, 'admin_create', true);
        $message = 'Created key: ' . $key;
    } elseif ($action === 'reset') {
        $id = (int)($_POST['id'] ?? 0);
        $stmt = $db->prepare(
            'UPDATE license_keys
             SET machine_id = NULL, machine_label = NULL, machine_meta = NULL, platform = NULL,
                 app_version = NULL, transfer_password_hash = NULL, activated_at = NULL, current_activations = 0
             WHERE id = ?'
        );
        $stmt->execute([$id]);
        logAction($db, $id, null, null, 'admin_reset', true);
        $message = 'Activation reset.';
    } elseif ($action === 'revoke') {
        $id = (int)($_POST['id'] ?? 0);
        $reason = trim((string)($_POST['reason'] ?? 'revoked by admin'));
        $stmt = $db->prepare('UPDATE license_keys SET is_revoked = 1, revoked_reason = ? WHERE id = ?');
        $stmt->execute([$reason, $id]);
        logAction($db, $id, null, null, 'admin_revoke', true, $reason);
        $message = 'License revoked.';
    }
}

$licenses = $db->query('SELECT * FROM license_keys ORDER BY id DESC LIMIT 200')->fetchAll();
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ZTool License Admin</title>
  <style>
    body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#202124}
    table{border-collapse:collapse;width:100%;margin-top:20px}
    th,td{border:1px solid #ddd;padding:6px 8px;font-size:13px;vertical-align:top}
    th{background:#f3f4f6;text-align:left}
    input,textarea{width:320px;max-width:100%}
    .ok{color:#096}
    .bad{color:#a00}
    .row-actions form{display:inline}
  </style>
</head>
<body>
<p style="float:right"><a href="?logout=1">Logout</a></p>
<h1>ZTool License Admin</h1>
<?php if ($message !== ''): ?><p class="ok"><?= h($message) ?></p><?php endif; ?>
<?php if ($error !== ''): ?><p class="bad"><?= h($error) ?></p><?php endif; ?>

<h2>Create Key</h2>
<form method="post">
  <input type="hidden" name="action" value="create">
  <input type="hidden" name="csrf_token" value="<?= h(csrfToken()) ?>">
  <p><label>Customer<br><input name="customer_name" required></label></p>
  <p><label>Email<br><input name="customer_email"></label></p>
  <p><label>Organization<br><input name="organization"></label></p>
  <p><label>Notes<br><textarea name="notes" rows="3"></textarea></label></p>
  <p><label><input type="checkbox" name="transfer_allowed" checked style="width:auto"> Transfer allowed</label></p>
  <button type="submit">Create activation key</button>
</form>

<h2>Keys</h2>
<table>
  <thead>
    <tr>
      <th>ID</th><th>Key</th><th>Customer</th><th>Status</th><th>Machine</th><th>Dates</th><th>Actions</th>
    </tr>
  </thead>
  <tbody>
  <?php foreach ($licenses as $license): ?>
    <tr>
      <td><?= (int)$license['id'] ?></td>
      <td><code><?= h($license['license_key']) ?></code></td>
      <td><?= h($license['customer_name']) ?><br><?= h($license['customer_email']) ?><br><?= h($license['organization']) ?></td>
      <td>
        <?= $license['is_revoked'] ? '<span class="bad">revoked</span>' : '<span class="ok">active</span>' ?><br>
        activations: <?= (int)$license['current_activations'] ?> / <?= (int)$license['max_activations'] ?><br>
        transfer: <?= $license['transfer_allowed'] ? 'yes' : 'no' ?>
      </td>
      <td>
        <?= h($license['machine_label']) ?><br>
        <code><?= h($license['machine_id']) ?></code>
      </td>
      <td>
        created: <?= h($license['created_at']) ?><br>
        activated: <?= h($license['activated_at']) ?><br>
        last check: <?= h($license['last_check_at']) ?>
      </td>
      <td class="row-actions">
        <form method="post">
          <input type="hidden" name="action" value="reset">
          <input type="hidden" name="csrf_token" value="<?= h(csrfToken()) ?>">
          <input type="hidden" name="id" value="<?= (int)$license['id'] ?>">
          <button type="submit">Reset binding</button>
        </form>
        <form method="post">
          <input type="hidden" name="action" value="revoke">
          <input type="hidden" name="csrf_token" value="<?= h(csrfToken()) ?>">
          <input type="hidden" name="id" value="<?= (int)$license['id'] ?>">
          <input type="hidden" name="reason" value="revoked by admin">
          <button type="submit">Revoke</button>
        </form>
      </td>
    </tr>
  <?php endforeach; ?>
  </tbody>
</table>
</body>
</html>
