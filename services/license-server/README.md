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
- `GET /api/public-key.php`
- `GET /admin/`

## Initial Setup

1. Create a MySQL database using `database.sql`.
2. Copy `config.example.php` to `config.php`.
3. Fill DB credentials and admin credentials in `config.php`.
   To rotate the admin password on a deployed copy without committing the hash:

```bash
ZTOOL_ADMIN_PASSWORD='new-password' php tools/set_admin_password.php
```

4. Generate an RSA key pair on the server:

```bash
mkdir -p keys
openssl genrsa -out keys/license_private.pem 2048
openssl rsa -in keys/license_private.pem -pubout -out keys/license_public.pem
```

5. Export the public key to .NET XML and pass it into the production package
   builder, or deploy `api/public-key.php` and let the builder fetch it:

```bash
php tools/export_public_key_xml.php
```

```powershell
.\packaging\tools\New-ZToolBinaryForkProductionPackage.ps1 -PublicKeyXmlPath .\license_public.xml
.\packaging\tools\New-ZToolBinaryForkProductionPackage.ps1 -PublicKeyXmlUri https://license.vizbuka.ru/ztool/api/public-key.php
```

The private key must never be committed.

## License Flow

1. Admin creates an activation key in `/admin/`.
2. ZTool sends the key, transfer password and hardware hash to `/api/activate.php`.
3. Server validates the transfer password, binds the key to that hardware hash and returns a signed payload.
4. ZTool stores the signed payload locally and validates it offline on launch.
5. Transfer uses `/api/deactivate.php` with the same transfer password to unbind the key from the old machine.

The transfer password is mandatory: 8-20 Latin letters/digits with at least
one letter and one digit. Empty transfer passwords are rejected by both
activation and deactivation.
