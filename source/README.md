# ZTool Fork Workspace

Это рабочая среда русского owned fork ZTool для SolidWorks. Оригинальных
исходников нет, поэтому recovered source, новые модули, сборка, русификация,
проверки и упаковка хранятся как воспроизводимый reverse-engineering pipeline.

Новый разработчик начинает с `_reverse\docs\onboarding.md` и
`_reverse\docs\autonomous_development.md`: там есть карта директорий, первый
запуск, QA-gates, правила уборки артефактов и рабочий цикл для продолжения
разработки.

Для полного переноса функционала оригинального ZTool используйте
`_reverse\docs\full_functionality_port_plan_20260505.md` и backlog
`_reverse\docs\functionality_port_backlog.csv`. Эти файлы являются текущим
источником правды по неперенесенным функциям, заглушкам и обязательным
проверкам перед production.

Проверка каждой кнопки и пункта меню ведется в
`_reverse\docs\button_function_parity_matrix.csv`: для каждой команды там
фиксируются original handler, current route, статус и обязательные проверки
route/behavior parity.

## Структура проекта

- `src\` - основной код приложения, SolidWorks add-in, workflow и smoke-проекты.
- `services\license-server\` - независимый сервер лицензирования ZTool.
- `_reverse\` - инструменты восстановления, сборки, QA, документация, reports и build-артефакты.
- `_vendor\ZTool-original\` - локальная оригинальная поставка ZTool; не коммитится.
- `_archive\localized-builds\` - старые `_localized*` и `_localized-full-*` снимки.
- `_archive\test-runs\` - сохраненные неудачные/диагностические прогоны тестов.

## Быстрый старт

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Bootstrap-DevEnv.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Initialize-ZToolVendor.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Invoke-ZToolForkPipeline.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Build-ZToolApp.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Build-ZToolSolidWorksAddIn.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolSolidWorksAddIn.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolClassicParity.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolGridFilterRuntime.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolRibbonStateRuntime.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolMainGridEditRuntime.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolFastFilterRuntime.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolMarkRepeatRuntime.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolFilterRulesRuntime.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolPropertyFillRuntime.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolFileListRuntime.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolCopySolidWorksFileRuntime.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolWorkflowPlans.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Publish-OwnedTemplateAssets.ps1 -Clean -Package
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Publish-ZToolApp.ps1 -Clean -Package -IncludeTemplateAssets
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Build-RecoveredArtifacts.ps1 -Clean
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-RestoredCopyBaseline.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolCoreP0Parity.ps1 -FailOnIssues -FailOnBlocked
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolStandalonePayloadP0.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolStandalonePayloadP1.ps1 -FailOnIssues -FailOnBlocked
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolProductionArtifacts.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolButtonFunctionParity.ps1 -ReleaseGate -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ZToolFullProductionRelease.ps1 -FailOnIssues -FailOnBlocked
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Export-DecompiledSources.ps1 -Clean
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Export-RecoveredResources.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-ForkWorkspace.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Test-OwnedTemplateAssets.ps1 -FailOnIssues
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Invoke-ZToolProductionAcceptance.ps1
```

Экспериментальная сборка полной поставки с нашими rebuilt-бинарями:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Invoke-ZToolForkPipeline.ps1 -UseRebuiltArtifacts -SkipBootstrap
```

Оригинальная поставка ZTool хранится локально в `_vendor\ZTool-original` и не
коммитится. `Initialize-ZToolVendor.ps1` переносит ее из корня один раз; если
поставка уже там, скрипт работает идемпотентно. Для нестандартного расположения
передавайте `-SourceRoot` в build/export/pipeline команды.

Основной production-контур сейчас - owned app release и GUI installer:
`_reverse\build\ztool-app-release-*`, ZIP `ZTool_App_owned_*.zip` и
пользовательский `ZTool_Setup_*.exe` в `_reverse\packages`. Legacy
patch-based сборки `_archive\localized-builds\_localized-full-*` остаются reference/compatibility
контуром и источником проверяемых recovered artifacts.

Чистую legacy production-папку можно опубликовать командой:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Publish-ZToolProduction.ps1
```

Убрать generated-артефакты и вернуть рабочую папку в компактный вид:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\_reverse\tools\Clean-ZToolWorkspace.ps1
```

## Основные файлы

- `_reverse\tools\Build-ZToolRussian.ps1` - сборка русской версии.
- `_reverse\tools\Build-ZToolTemplates.ps1` - сборка owned слоя шаблонов и BOM manifest.
- `_reverse\tools\Build-ZToolSettings.ps1` - сборка versioned settings/profile слоя.
- `_reverse\tools\Test-ZToolSettings.ps1` - gate профиля настроек: embedded RU profile, validation, roundtrip и legacy `ZTool.settings` snapshot.
- `_reverse\tools\Build-ZToolSolidWorksAddIn.ps1` - сборка собственного SolidWorks add-in shell.
- `_reverse\tools\Test-ZToolSolidWorksAddIn.ps1` - build-only gate add-in: COM-visible shell, command surface `ZTool`/999/17 commands без updater, callbacks, command IDs и dry-run registration.
- `_reverse\tools\Register-ZToolSolidWorksAddIn.ps1` - регистрация owned add-in в SolidWorks через RegAsm/HKLM/HKCU; требует elevated PowerShell, имеет `-DryRun`.
- `_reverse\tools\Unregister-ZToolSolidWorksAddIn.ps1` - чистое удаление owned add-in registration; требует elevated PowerShell, имеет `-DryRun`.
- `_reverse\tools\Build-ZToolWorkflows.ps1` - сборка owned planning-layer для P1 workflow.
- `_reverse\tools\Build-ZToolWorkflowsCli.ps1` - сборка build-only CLI runner для fixture workflow plans.
- `_reverse\tools\Test-ZToolWorkflowPlans.ps1` - gate планировщиков `Rename`, `Split Config`, `Preview`.
- `_reverse\tools\Publish-OwnedTemplateAssets.ps1` - публикация русифицированных шаблонов/BOM/settings из ignored vendor-входа в нормализованную структуру.
- `_reverse\tools\Test-OwnedTemplateAssets.ps1` - gate manifest/templates: normalized paths, required assets, CJK/mojibake, encodings и release-policy parity.
- `_reverse\tools\Build-ZToolBom.ps1` - сборка owned BOM domain library и CLI normalizer.
- `_reverse\tools\Export-OwnedBomFixture.ps1` - deterministic XLSX export из domain-normalized fixture через owned BOM template.
- `_reverse\tools\Test-OwnedBomFixture.ps1` - gate BOM export: domain validation, canonical CSV, SHA256 determinism, headers, row count и отсутствие CJK в workbook XML.
- `_reverse\tools\Test-ZToolFeatureInventory.ps1` - gate паритетного inventory: обязательные workflow, add-in command IDs, статусы и source file references.
- `_reverse\tools\Test-ZToolProductionParityGate.ps1` - строгий P0/P1 production gate: все tracked P0/P1 функции должны быть `parity-verified`/`production-verified`, а known gaps закрыты.
- `_reverse\tools\Test-ZToolCoreP0Parity.ps1` - агрегирующий P0 core gate: restored baseline, templates/localization, SolidWorks COM smoke, add-in load, installer.
- `_reverse\tools\Test-ZToolStandalonePayloadP0.ps1` - standalone P0 payload gate: main grid, BOM, export/options, property fill.
- `_reverse\tools\Test-ZToolStandalonePayloadP1.ps1` - standalone P1 payload gate: output convert, print, drawing format, reference replacement, drawing sync, filter/mapping, file copy, preview.
- `_reverse\tools\Test-ZToolProductionArtifacts.ps1` - production artifacts gate: owned app release, ZIP, GUI installer, installer/uninstaller scenario and required compatibility names.
- `_reverse\tools\Test-ZToolFullProductionRelease.ps1` - полный последовательный release gate для CAD-машины: P0/P1 parity, production artifacts, inventory and production parity gate.
- `_reverse\tools\Build-ZToolSolidWorks.ps1` - сборка SolidWorks COM/adapter слоя.
- `_reverse\tools\Build-ZToolSolidWorksSmoke.ps1` - сборка .NET Framework runner для runtime-проверки owned SolidWorks adapter.
- `_reverse\tools\Test-SolidWorksContracts.ps1` - build-only gate для document property contracts и fake-сценария.
- `_reverse\tools\Invoke-OwnedSolidWorksDocumentSmokeTest.ps1` - runtime-smoke owned adapter: attach/launch SolidWorks, открыть документ, собрать BOM, создать disposable part, проверить custom properties.
- `_reverse\tools\Build-ZToolApp.ps1` - сборка собственного приложения `src\ZTool.App`.
- `_reverse\tools\Test-ZToolClassicParity.ps1` - gate classic `Frmmain`-паритета: command IDs 1000-1072, `DGV1`, `TV1`, `treecmsp1`, status strip и дефолтный запуск.
- `_reverse\tools\Test-ZToolGridFilterRuntime.ps1` - runtime gate main grid filter: `GetFilterStatus`, checklist values, `ColFilter`, `ClearFilter`, visible rows и `Color.Tomato` header state.
- `_reverse\tools\Test-ZToolRibbonStateRuntime.ps1` - runtime gate main ribbon state: data acquisition modes, `breakcfg`/`mergecfg`, exclude toggles, and original `Encheckbox` checkbox-column behavior.
- `_reverse\tools\Test-ZToolMainGridEditRuntime.ps1` - runtime gate main table editing: per-column read-only contract, modified-row marker, `DarkOrange` changed-cell color, duplicate filename revert, and `Modifieditem` fast filter.
- `_reverse\tools\Test-ZToolFastFilterRuntime.ps1` - runtime gate fast filters: parent menu contract, disabled `Нет`, custom rules as `15000+`, selected rows, readonly files, failed rows, virtual paths, bend/weldment markers, excluded BOM rows, and `Ruletype` include/exclude mode.
- `_reverse\tools\Test-ZToolMarkRepeatRuntime.ps1` - runtime gate `Markrepeat`: duplicate-cell `OrangeRed` highlight and `unMarkrepeat` cleanup.
- `_reverse\tools\Test-ZToolFilterRulesRuntime.ps1` - runtime gate `FrmFilterrules`: открытие диалога фильтра, сохранение rule name/type и condition field/operator/value.
- `_reverse\tools\Test-ZToolPropertyFillRuntime.ps1` - runtime gate `FrmFilling`: non-modal singleton route, `fill1`, `Undo_Button`, `fill2` по правилам и related-data double-click перенос.
- `_reverse\tools\Test-ZToolFileListRuntime.ps1` - runtime gate `FrmFileList`: список файлов, `Button4/Подтвердить`, передача путей в `DGV1` и синхронизация `TV1`.
- `_reverse\tools\Test-ZToolCopySolidWorksFileRuntime.ps1` - runtime gate `frm_copyswfile`: original control names, preview/copy plan, 3D/drawing/other-file copy and summary output.
- `_reverse\tools\Publish-ZToolApp.ps1` - упаковка собственного приложения без vendor-бинарей; включает owned add-in DLL в `AddIns` и содержит BOM preview/export workflow.
- `_reverse\tools\Test-ZToolAppRelease.ps1` - gate для owned app kit и его zip-пакета.
- `_reverse\tools\Build-ZToolUserInstaller.ps1` - сборка single-file GUI installer `ZTool_Setup_*.exe` через NSIS.
- `_reverse\tools\Build-RecoveredArtifacts.ps1` - сборка recovered/fork артефактов `ZTool.exe`, `ZTool.dll`, `初始化.exe`; updater не входит в production-сборку.
- `_reverse\tools\Publish-RebuiltArtifacts.ps1` - упаковка rebuilt artifact kit с manifest и zip.
- `_reverse\tools\Test-RestoredCopyBaseline.ps1` - единый gate восстановленной копии: rebuild, rebuilt kit, overlay release, runtime readiness и acceptance subset.
- `_reverse\tools\Export-RecoveredBuildResources.ps1` - bootstrap embedded resources для recovered-source сборки.
- `_reverse\tools\Test-RebuiltArtifacts.ps1` - gate для rebuilt artifacts: наличие файлов, embedded resources и runtime-зависимостей.
- `_reverse\tools\Initialize-ZToolVendor.ps1` - перенос оригинальной поставки в ignored `_vendor\ZTool-original`.
- `_reverse\tools\Finalize-UnpackedZTool.ps1` - распаковка и очистка `ZTool.dll`.
- `_reverse\tools\Patch-ZToolExePayload.ps1` - распаковка, перевод и обратная упаковка embedded payload внутри `ZTool.exe`.
- `_reverse\tools\Export-ZToolPayloadStrings.ps1` - каталог строк основного payload для перевода.
- `_reverse\tools\Verify-ZToolBuild.ps1` - контроль остаточных китайских строк.
- `_reverse\tools\Test-ZToolRelease.ps1` - release-gate: проверка пакета, имен файлов, обязательных артефактов и SHA256 manifest.
- `_reverse\tools\Test-ZToolLocalizationQuality.ps1` - QA словаря, placeholders, mojibake и длинных UI-строк.
- `_reverse\tools\Test-ZToolRuntimeReadiness.ps1` - проверка готовности машины к smoke-test в SolidWorks.
- `_reverse\tools\Ensure-SolidWorksCom.ps1` - диагностика и явная регистрация SolidWorks COM на машине с установленным SolidWorks.
- `_reverse\tools\Invoke-ZToolSolidWorksSmokeTest.ps1` - COM smoke-test: запуск SolidWorks и открытие тестовой модели.
- `_reverse\tools\Invoke-ZToolProductionAcceptance.ps1` - единый acceptance-отчет релиз-кандидата: статический gate, локализация, runtime readiness и COM smoke-test.
- `_reverse\tools\Clean-ZToolWorkspace.ps1` - безопасная очистка воспроизводимых артефактов без удаления оригинальной поставки.
- `_reverse\tools\Publish-ZToolProduction.ps1` - публикация проверенной сборки в `_production\ZTool_ru`.
- `_reverse\tools\Ensure-ZToolReverseToolchain.ps1` - локальные decompiler/build зависимости без глобального `dotnet`.
- `_reverse\tools\Export-DecompiledSources.ps1` - экспорт восстановленного C# в `_reverse\decompiled`.
- `_reverse\tools\extract_managed_resources.py` - извлечение embedded managed resources для recovered builds.
- `_reverse\tools\Export-RecoveredResources.ps1` - индекс и строковый экспорт WinForms `.resources`.
- `_reverse\tools\Test-RecoveredResourceTranslations.ps1` - контроль покрытия resource-строк переводом.
- `_reverse\tools\Update-ForkWorkspaceSolution.ps1` - генерация единого solution для форка и recovered source.
- `_reverse\tools\Test-ForkWorkspace.ps1` - полный build-gate dev workspace.
- `_reverse\tools\Test-DecompiledSourceBuild.ps1` - проверка сборочного статуса декомпилированных проектов.
- `_reverse\tools\Build-ForkExtensions.ps1` - сборка чистого проекта для нового функционала.
- `ZTool.ForkWorkspace.sln` - Visual Studio solution для нового кода форка и восстановленных проектов.
- `src\ZTool.ForkExtensions` - место для нового кода форка; production-сборка кладет DLL в `Extensions`.
- `src\ZTool.SolidWorks` - SolidWorks COM/adapter слой для собственного приложения: session, document properties и live BOM collector.
- `src\ZTool.SolidWorks.Smoke` - .NET Framework runtime-runner для owned SolidWorks smoke gates.
- `src\ZTool.SolidWorks.AddIn` - собственный COM-visible SolidWorks add-in shell с original command group `ZTool`.
- `src\ZTool.Workflows` - build-only planning layer для `ReName`, `SplitConfig`, `preview`.
- `src\ZTool.Workflows.Cli` - fixture runner, который сериализует workflow plans в JSON для gates.
- `src\ZTool.Bom` - owned BOM domain model: rows, options, validation и canonical CSV без зависимости от SolidWorks/Excel.
- `src\ZTool.Bom.Cli` - build-only adapter, который нормализует BOM fixture и пишет JSON report для gates.
- `src\ZTool.Settings` - versioned RU profile, settings validator и legacy `ZTool.settings` migration snapshot.
- `src\ZTool.Templates` - owned manifest и validator для шаблонов BOM/SolidWorks без китайских или mojibake runtime-путей.
- `src\ZTool.App` - самостоятельное приложение русского форка без patch/substitution runtime; дефолтный экран `ClassicMainForm` повторяет original `Frmmain`.
- `src\ZTool.Init` - чистый инициализатор/launcher русского форка.
- `WorkspaceDiagnostics.Inspect(...)` в `ZTool.ForkExtensions` - общий диагностический API для `ZTool.App` и release gates.
- `_reverse\tools\patch_bom_template.py` - перевод внутренней структуры `bom_template.xlsx`.
- `_reverse\config\release_assets.psd1` - карта исключений, переименований и обязательных production-артефактов.
- `_reverse\config\vendor_assets.psd1` - карта файлов и папок оригинальной поставки для `_vendor\ZTool-original`.
- `_reverse\translations\zh_ru_seed.csv` - основной словарь перевода.
- `_reverse\reports\reverse_plan.md` - технический отчет по реверсу.
- `_reverse\docs\feature_inventory.csv` - tracked inventory workflow оригинального ZTool с приоритетами и статусом паритета.

Документация по процессу: `_reverse\docs`, начинать с `_reverse\docs\onboarding.md` и `_reverse\docs\autonomous_development.md`, отдельно см. `_reverse\docs\classic_frmmain_parity.md`, `_reverse\docs\bom_domain_model.md`, `_reverse\docs\live_bom_collector.md`, `_reverse\docs\bom_ui_export.md`, `_reverse\docs\settings_profile.md`, `_reverse\docs\solidworks_addin_shell.md`, `_reverse\docs\workflow_plans.md`, `_reverse\docs\restored_copy_baseline.md`, `_reverse\docs\full_parity_sprint_plan.md`, `_reverse\docs\owned_app_implementation_plan.md`, `_reverse\docs\own_application.md`, `_reverse\docs\source_recovery.md` и `_reverse\docs\rebuilt_artifacts.md`.
Текущий recovered-source scaffold в `_reverse\decompiled` проходит Release-сборку для всех пяти декомпилированных проектов; корневой `ZTool.ForkWorkspace.sln` объединяет их с `src\ZTool.ForkExtensions`.
