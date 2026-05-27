# Ротация RSA-ключей лицензирования SWTool

Документ описывает, как ротировать пару RSA-ключей, которой подписываются
лицензионные payload'ы сервера `license.vizbuka.ru/ztool`.

## Когда применять

- Первичная установка нового продукта (RU/EN сборка SWTool).
- Подозрение на компрометацию приватного ключа.
- Любое изменение хоста сервера лицензирования.

## Последствия ротации

> **Внимание**. После замены ключевой пары **все ранее выданные офлайн-payload'ы
> становятся невалидными**. Все активные машины при следующей онлайн-проверке
> пройдут реактивацию через `/api/activate.php`. Если включён офлайн-grace
> (`OfflineGraceDays = 7`) — те, у кого свежий signedPayload, продержатся ещё
> 7 дней. Те, у кого он истёк, увидят диалог активации.
>
> Рекомендуется выполнять ротацию **в момент**, когда у тебя нет активных
> покупателей, либо предупредить их заранее и в течение grace-окна повторно
> активировать машины.

## Файлы ключей

| Файл | Где живёт | Зачем |
|---|---|---|
| `keys/license_private.pem` | **только** на сервере, `services/license-server/keys/` | Подписывает payload'ы в `signer.php` |
| `keys/license_public.pem` | сервер, `services/license-server/keys/` | Раздаётся `api/public-key.php` |
| `source/packaging/license_public.xml` | репозиторий, `.NET RSAKeyValue` XML | Встраивается build'ером в C# const `EmbeddedLicenseConfig.PublicKeyXml` |

Приватный ключ **никогда** не коммитится в репозиторий
(`services/license-server/.gitignore` это уже обеспечивает).

## Процедура ротации

### 1. Сгенерируй новую пару

На любой Linux-машине или WSL:

```bash
mkdir -p keys
openssl genrsa -out keys/license_private.pem 2048
openssl rsa -in keys/license_private.pem -pubout -out keys/license_public.pem
```

### 2. Экспортируй публичный ключ в .NET XML

С сервера (где уже стоит php):

```bash
php tools/export_public_key_xml.php keys/license_public.pem > /tmp/license_public.xml
```

Скопируй полученный `/tmp/license_public.xml` в `source/packaging/license_public.xml`
в репозитории и закоммить.

### 3. Деплой приватного ключа на сервер

```bash
# на сервере (license.vizbuka.ru):
sudo install -o www-data -g www-data -m 0600 \
    keys/license_private.pem \
    /srv/license/services/license-server/keys/license_private.pem

sudo install -o www-data -g www-data -m 0644 \
    keys/license_public.pem \
    /srv/license/services/license-server/keys/license_public.pem
```

(Подставь свой реальный путь установки.)

Убедись, что в `services/license-server/config.php` указаны те же пути:

```php
define('PRIVATE_KEY_PATH', __DIR__ . '/keys/license_private.pem');
define('PUBLIC_KEY_PATH',  __DIR__ . '/keys/license_public.pem');
```

### 4. Проверь, что сервер выдаёт новый публичный ключ

```bash
curl -sS https://license.vizbuka.ru/ztool/api/public-key.php | head
```

Должен вернуться `<RSAKeyValue>...` с новым модулем (совпадающим с
`source/packaging/license_public.xml`).

### 5. Пересобери SWTool с новым публичным ключом

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\source\packaging\tools\New-ZToolBinaryForkProductionPackage.ps1 `
  -PublicKeyXmlPath .\source\packaging\license_public.xml
```

Или через URI, если предпочитаешь брать ключ с боевого сервера:

```powershell
.\New-ZToolBinaryForkProductionPackage.ps1 `
  -PublicKeyXmlUri https://license.vizbuka.ru/ztool/api/public-key.php
```

Скрипт проверит формат XML, встроит ключ в `EmbeddedLicenseConfig.PublicKeyXml`
и соберёт `release/installer/SWTool-Setup-<version>.exe`.

### 6. Опционально: сбрось activated-флаги в БД

Если хочешь форсировать всем покупателям повторную активацию **сразу**,
не дожидаясь истечения оффлайн-grace:

```sql
UPDATE license_keys
SET activated_at = NULL, machine_id = NULL, is_active = 1
WHERE is_active = 1;
```

После этого старые offline-payload'ы перестанут совпадать с серверным
состоянием при следующей онлайн-проверке.

## Откат

Если что-то пошло не так, верни **старые** `license_private.pem` /
`license_public.pem` обратно на сервер и **старый** `license_public.xml` в
репо. Пересобери пакет. Старые активации продолжат работать.
