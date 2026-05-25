<?php
// Usage:
// php tools/export_public_key_xml.php [path/to/license_public.pem]

$keyPath = $argv[1] ?? (__DIR__ . '/../keys/license_public.pem');
if (!is_file($keyPath)) {
    fwrite(STDERR, "Public key file not found: {$keyPath}\n");
    exit(1);
}

$publicKey = openssl_pkey_get_public(file_get_contents($keyPath));
if (!$publicKey) {
    fwrite(STDERR, "Cannot read public key: {$keyPath}\n");
    exit(1);
}

$details = openssl_pkey_get_details($publicKey);
if (!is_array($details) || empty($details['rsa']['n']) || empty($details['rsa']['e'])) {
    fwrite(STDERR, "Public key does not contain RSA modulus/exponent.\n");
    exit(1);
}

echo "<RSAKeyValue>\n";
echo "  <Modulus>" . base64_encode($details['rsa']['n']) . "</Modulus>\n";
echo "  <Exponent>" . base64_encode($details['rsa']['e']) . "</Exponent>\n";
echo "</RSAKeyValue>\n";
