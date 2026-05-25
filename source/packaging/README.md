# ZTool production licensing layer

This folder contains owned licensing/runtime components and release gates for
the binary-only ZTool package.

## Production binary-fork package

Use this for the production fork candidate that already has aligned strong-name
identity:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\packaging\tools\New-ZToolBinaryForkProductionPackage.ps1 -PublicKeyXmlPath .\license_public.xml
```

If `api/public-key.php` is deployed on the license server, the same build can
use `-PublicKeyXmlUri https://license.vizbuka.ru/ztool/api/public-key.php`.

To publish the server-side files and export the production public key:

```powershell
.\packaging\tools\Publish-ZToolLicenseServerFiles.ps1 -RemoteHost user@host -RemoteRoot /var/www/license/ztool
.\packaging\tools\Export-ZToolLicensePublicKey.ps1 -OutputPath .\license_public.xml -RemoteHost user@host -RemoteRoot /var/www/license/ztool
```

On this workstation the existing Rheolab deploy environment can be reused:

```powershell
.\packaging\tools\Publish-ZToolLicenseServerFiles.ps1 -EnvPath D:\Development\Rheolab\scripts\deploy\.env.server
.\packaging\tools\Export-ZToolLicensePublicKey.ps1 -EnvPath D:\Development\Rheolab\scripts\deploy\.env.server -OutputPath .\license_public.xml -Force
```

The script overlays reproducible owned components:

- `ZTool.License.dll` - license runtime compiled from `packaging\ZTool.License`.
- `ZTool Updater.exe` - signed disabled-update stub.
- `ZTool License Deactivate.exe` - interactive deactivation utility.
- `Deactivate ZTool License.cmd` - command wrapper for deactivation.
- provenance manifests and `Test-ZToolLicensedPackage.ps1` gate result.

Production builds require embedded `PublicKeyXml`. Without it the build fails,
because offline signed payload verification would otherwise be non-functional.

## Server smoke

Check the deployed server endpoints:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\packaging\tools\Test-ZToolLicenseServer.ps1
```

For a real activation smoke, provide `ZTOOL_TEST_KEY` or pass
`-TestLicenseKey`.

## Legacy launcher package

The older launcher-based package is kept only as a fallback/dev artifact:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\packaging\tools\New-ZToolLicensedPackage.ps1 -Production -PublicKeyXmlPath .\license_public.xml -Package
```

For offline signature verification of license payloads, export the public key
from the deployed license server and pass it as `-PublicKeyXmlPath`.

Production packages require embedded `PublicKeyXml`; the license endpoint and
public key are compiled into the launcher, not read from user-editable
environment variables or XML config.
