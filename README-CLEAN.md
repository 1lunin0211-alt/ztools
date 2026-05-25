# ZTool Clean Project Snapshot

Эта папка отделяет актуальные рабочие данные проекта от архивов, промежуточных сборок и временных файлов.

## Структура

- `source/packaging` - актуальный код лицензирования, упаковки, установщика, русской справки и production build scripts.
- `source/README.md` - основная документация проекта.
- `reference/ZTool-original` - оригинальная поставка ZTool как референс для сравнения поведения, ресурсов и интеграции.
- `release/_ztool-fork-production-*` - один актуальный production package.
- `release/installer/ZTool-Setup-1.1.exe` - актуальный установщик версии 1.1.
- `docs/clean-project-manifest.json` - машинный манифест, что было включено и что исключено.

## Исключено

- `_archive`
- старые `_release/_archive-*`
- временные скриншоты и extracted help
- `.git`, `.devin`, `.vscode`
- `bin`, `obj`, `.pdb`, `.log`

