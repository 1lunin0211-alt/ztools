# ZTool License Server

Independent PHP/MySQL activation server for ZTool.

This is intentionally separate from RheoLab licensing. It can be deployed on
the same VPS and domain, for example under:

```text
https://license.vizbuka.ru/ztool
```

## Endpoints

- `POST /api/activate.php`
- `POST /api/deactivate.php`
- `GET /admin/`

## Initial Setup

1. Create a MySQL database using `database.sql`.
2. Copy `config.example.php` to `config.php`.
3. Fill DB credentials and admin credentials in `config.php`.
4. Generate an RSA key pair on the server:

```bash
mkdir -p keys
openssl genrsa -out keys/license_private.pem 2048
openssl rsa -in keys/license_private.pem -pubout -out keys/license_public.pem
```

5. Export the public key to .NET XML and paste it into
   `ZToolLicenseConfig.PublicKeyXml` before building ZTool for release:

```bash
php tools/export_public_key_xml.php
```

The private key must never be committed.

## License Flow

1. Admin creates an activation key in `/admin/`.
2. ZTool sends the key and hardware hash to `/api/activate.php`.
3. Server binds the key to that hardware hash and returns a signed payload.
4. ZTool stores the signed payload locally and validates it offline on launch.
5. Transfer uses `/api/deactivate.php` to unbind the key from the old machine.
