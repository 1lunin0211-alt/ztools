param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [ValidateSet('Russian', 'English')]
    [string]$Language = 'Russian'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-DnlibPath {
    $root = Resolve-FullPath (Join-Path $PSScriptRoot '..\..')
    $candidate = Join-Path $root '_archive\_reverse\packages\dnlib\lib\net45\dnlib.dll'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    throw "dnlib.dll not found: $candidate"
}

function Ensure-DnlibLoaded {
    if ('dnlib.DotNet.ModuleDefMD' -as [type]) {
        return
    }

    Add-Type -Path (Get-DnlibPath)
}

function Get-CscPath {
    $candidate = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    throw "csc.exe not found: $candidate"
}

function Get-FileSha256([string]$Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Find-Bytes([byte[]]$Haystack, [byte[]]$Needle) {
    if ($Needle.Length -eq 0 -or $Needle.Length -gt $Haystack.Length) {
        return -1
    }

    for ($i = 0; $i -le $Haystack.Length - $Needle.Length; $i++) {
        $matched = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) {
                $matched = $false
                break
            }
        }

        if ($matched) {
            return $i
        }
    }

    return -1
}

function Set-BytesEverywhere([byte[]]$Bytes, [byte[]]$OldBytes, [byte[]]$NewBytes) {
    if ($NewBytes.Length -ne $OldBytes.Length) {
        throw 'Replacement byte arrays must have the same length.'
    }

    $count = 0
    $offset = 0
    while ($offset -lt $Bytes.Length) {
        $remaining = [byte[]]::new($Bytes.Length - $offset)
        [Array]::Copy($Bytes, $offset, $remaining, 0, $remaining.Length)
        $relative = Find-Bytes $remaining $OldBytes
        if ($relative -lt 0) {
            break
        }

        $absolute = $offset + $relative
        [Array]::Copy($NewBytes, 0, $Bytes, $absolute, $NewBytes.Length)
        $offset = $absolute + $OldBytes.Length
        $count++
    }

    return $count
}

function ConvertTo-FixedUtf16Bytes([string]$OldValue, [string]$NewValue) {
    if ($NewValue.Length -gt $OldValue.Length) {
        throw "Replacement '$NewValue' is longer than '$OldValue'."
    }

    $padded = $NewValue.PadRight($OldValue.Length, ' ')
    [System.Text.Encoding]::Unicode.GetBytes($padded)
}

function ConvertFrom-ZToolPayloadResource([byte[]]$EncryptedPayload) {
    $des = [System.Security.Cryptography.DES]::Create()
    $des.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $des.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $des.Key = [byte[]](0x21,0x1B,0x53,0x5B,0x11,0x12,0x2D,0x4C)
    $des.IV = [byte[]](0x35,0x27,0x13,0x26,0x63,0x16,0x2F,0x34)
    $decryptor = $des.CreateDecryptor()
    try {
        $plain = $decryptor.TransformFinalBlock($EncryptedPayload, 0, $EncryptedPayload.Length)
    } finally {
        $decryptor.Dispose()
        $des.Dispose()
    }

    $base64 = [System.Text.Encoding]::UTF8.GetString($plain).TrimStart([char]0xFEFF).Trim()
    return ,([Convert]::FromBase64String($base64))
}

function ConvertTo-ZToolPayloadResource([byte[]]$Payload) {
    $base64 = [Convert]::ToBase64String($Payload)
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    $plain = [byte[]](@($utf8Bom.GetPreamble()) + @($utf8Bom.GetBytes($base64)))

    $des = [System.Security.Cryptography.DES]::Create()
    $des.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $des.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $des.Key = [byte[]](0x21,0x1B,0x53,0x5B,0x11,0x12,0x2D,0x4C)
    $des.IV = [byte[]](0x35,0x27,0x13,0x26,0x63,0x16,0x2F,0x34)
    $encryptor = $des.CreateEncryptor()
    try {
        return ,($encryptor.TransformFinalBlock($plain, 0, $plain.Length))
    } finally {
        $encryptor.Dispose()
        $des.Dispose()
    }
}

function Read-EmbeddedResourceBytes([dnlib.DotNet.ModuleDefMD]$Module, [string]$ResourceName) {
    foreach ($resource in $Module.Resources) {
        $embedded = $resource -as [dnlib.DotNet.EmbeddedResource]
        if ($null -eq $embedded -or [string]$embedded.Name -ne $ResourceName) {
            continue
        }

        $reader = $embedded.CreateReader()
        return $reader.ReadBytes([int]$reader.Length)
    }

    throw "Embedded resource not found: $ResourceName"
}

function Get-ResourcePatchHelper {
    $helperDir = Join-Path ([System.IO.Path]::GetTempPath()) 'swtool-native-resource-patcher'
    New-Item -ItemType Directory -Force -Path $helperDir | Out-Null
    $helperSource = Join-Path $helperDir 'SwToolResourcePatchHelper.cs'
    $helperExe = Join-Path $helperDir 'SwToolResourcePatchHelper.exe'

    if (Test-Path -LiteralPath $helperExe -PathType Leaf) {
        return $helperExe
    }

    @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Resources;
using System.Text;

public static class SwToolResourcePatchHelper
{
    // Format of args[2] (the map file):
    //   record sep = 0x08 (BS), key/value sep = 0x07 (BEL)
    // Both bytes are absent from the production string set (Chinese ldstr,
    // RU/EN translations, multi-line Update_log/regexhelp blocks), so keys
    // and values may contain CR, LF, TAB, and other control chars safely.
    public static int Main(string[] args)
    {
        if (args.Length != 3)
        {
            Console.Error.WriteLine("usage: <input.resources> <output.resources> <map.tsv>");
            return 2;
        }

        var map = new Dictionary<string, string>();
        string raw = File.ReadAllText(args[2], Encoding.UTF8);
        foreach (string record in raw.Split('\u0008'))
        {
            if (string.IsNullOrEmpty(record)) continue;
            int sep = record.IndexOf('\u0007');
            if (sep <= 0) continue;
            map[record.Substring(0, sep)] = record.Substring(sep + 1);
        }

        var entries = new List<DictionaryEntry>();
        int changed = 0;
        using (ResourceReader reader = new ResourceReader(args[0]))
        {
            foreach (DictionaryEntry entry in reader)
            {
                object value = entry.Value;
                string text = value as string;
                if (text != null && map.ContainsKey(text))
                {
                    value = map[text];
                    changed++;
                }

                entries.Add(new DictionaryEntry(entry.Key, value));
            }
        }

        using (ResourceWriter writer = new ResourceWriter(args[1]))
        {
            foreach (DictionaryEntry entry in entries)
            {
                writer.AddResource((string)entry.Key, entry.Value);
            }
            writer.Generate();
        }

        Console.WriteLine(changed.ToString());
        return 0;
    }
}
'@ | Set-Content -LiteralPath $helperSource -Encoding UTF8

    & (Get-CscPath) /nologo /codepage:65001 /r:System.Drawing.dll /r:System.Windows.Forms.dll /out:$helperExe $helperSource | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $helperExe -PathType Leaf)) {
        throw 'Failed to compile resource patch helper.'
    }

    return $helperExe
}

function Get-StringMap([string]$SelectedLanguage) {
    # Use case-sensitive ordered dictionary so '在Solidworks中打开' and '在solidworks中打开'
    # remain distinct keys (the payload contains both casings).
    $map = New-Object System.Collections.Specialized.OrderedDictionary([System.StringComparer]::Ordinal)
    if ($SelectedLanguage -eq 'Russian') {
        $map["`t统计数量"] = "`tКоличество"
        $map[" (属性值)"] = " (значение свойства)"
        $map[" (属性表达式)"] = " (выражение свойства)"
        $map[" (表达式)"] = " (выражение)"
        $map[" 不存在"] = " не существует"
        $map[" 不存在，请重新设置"] = " не существует, задайте заново"
        $map[" 与 "] = " и "
        $map[" 个"] = " шт."
        $map[" 保存选项"] = " Параметры сохранения"
        $map[" 失败！"] = " — ошибка!"
        $map[" 已存在！"] = " уже существует!"
        $map[" 已存在，是否自动递增流水号？"] = " уже существует. Автоматически увеличить порядковый номер?"
        $map[" 打开失败！"] = " — не удалось открыть!"
        $map[" 批量转换格式"] = " Пакетная конвертация формата"
        $map[" 文件不存在！"] = " файл не существует!"
        $map[" 条记录中找到 "] = " записей, найдено "
        $map[" 的行磁盘文件名重复，填写失败！"] = " строк имеют повторяющееся имя файла на диске, заполнение не выполнено!"
        $map[" 秒"] = " с"
        $map[" 秒， 共 "] = " с, всего "
        $map[" 秒，共 "] = " с, всего "
        $map[" 行"] = " строк"
        $map[" 路径不存在！"] = " путь не существует!"
        $map[" 页"] = " стр."
        $map[" 页被合并"] = " стр. объединено"
        $map[" 项"] = " элем."
        $map[" 项因文件名重复，替换失败"] = " элементов имеют повторяющиеся имена, замена не выполнена"
        $map[" 项被找到"] = " элементов найдено"
        $map[" 项，填写 "] = " элементов, заполнить "
        $map["`" 不存在,是否创建?"] = "`" не существует, создать?"
        $map["`" 更新参考关系失败！"] = "`" обновление ссылок не выполнено!"
        $map["`" 目录下没有找到后缀名为 `".slddrt`" 的图纸格式文件"] = "`" — в каталоге не найдено файлов формата чертежа (*.slddrt)"
        $map["`" 目录不存在！"] = "`" каталог не существует!"
        $map["`"ZTool Updater.exe`" 缺失！无法启动更新程序！"] = "`"ZTool Updater.exe`" отсутствует! Запуск обновления невозможен!"
        $map["`"ZToolARM.dll`"丢失"] = "`"ZToolARM.dll`" отсутствует"
        $map["`"为重复的属性名称"] = "`" — повторяющееся имя свойства"
        $map["`"列中清除筛选"] = "`" — снять фильтр в столбце"
        $map["`"找不到"] = "`" не найдено"
        # Note: $НЧ$ / $ИмяД$ / <конф> / <файл_> / $Рев are length-equal byte
        # patches in ZTool.dll's Constant.Value blob (see Get-ZToolDllCjkPatches in
        # Disable-ZToolEmbeddedUpdates.ps1). Payload composites MUST use the same
        # short tokens so payload-side template parsing matches ZTool.dll constants.
        $map["`$图号`$ `$名称`$ `$类型`$"] = "`$НЧ`$ `$Имя`$ `$Тип`$"
        $map["`$图号`$-`$零件名称`$-{001}"] = "`$НЧ`$-`$ИмяД`$-{001}"
        $map["`$图号`$"] = "`$НЧ`$"
        $map["`$零件名称`$"] = "`$ИмяД`$"
        $map["`$版本`$"] = "`$Рев"
        $map["<磁盘文件名>"] = "<файл_>"
        $map["`$类型`$-<文件名称>-<当前日期>"] = "`$Тип`$-<ИмяФайла>-<ТекущаяДата>"
        $map["(全选)"] = "(выделить всё)"
        $map[") (不包含在明"] = ") (не включено в спецификацию"
        $map[") (在明细表中"] = ") (в спецификации"
        $map["-当映射名称为空时或与列标题相同时，该列不启用映射；`r`n-应保证映射名称与Excel模板中的自定义名称相等；`r`n-列标题映射主要用于解决Excel模板的自定义名称语法问题，以及列标题重`r`n复导致导出bom数据错乱的问题；"] = "- если имя сопоставления пусто или совпадает с заголовком столбца, сопоставление для этого столбца отключено;`r`n- имя сопоставления должно совпадать с пользовательским именем в Excel-шаблоне;`r`n- сопоставление заголовков столбцов решает проблемы синтаксиса пользовательских имён в Excel-шаблонах и ошибок экспорта BOM при повторяющихся заголовках;"
        $map["/进阶操作/BOM表模板制作和导出.htm"] = "/advanced/bom-template-and-export.htm"
        $map["/进阶操作/缩略"] = "/advanced/thumbnail"
        $map["<主题>"] = "<Тема>"
        $map["<作者>"] = "<Автор>"
        $map["<关键字>"] = "<КлючевыеСлова>"
        $map["<备注>"] = "<Заметки>"
        $map["<当前日期>"] = "<ТекущаяДата>"
        $map["<文件名称>"] = "<ИмяФайла>"
        $map["<文件夹名称>"] = "<ИмяПапки>"
        $map["<文件类型>"] = "<ТипФайла>"
        $map["<有无工程图>"] = "<ЕстьЧертёж>"
        $map["<材质>"] = "<Материал>"
        $map["<标题>"] = "<Заголовок>"
        $map["<模型文件名称>"] = "<ИмяМоделиФайла>"
        $map["<模型文件夹名称>"] = "<ПапкаМодели>"
        $map["<统计数量>"] = "<Количество>"
        $map["<配置名称>"] = "<конф>"
        $map["A4横"] = "A4 альбомная"
        $map["A4竖"] = "A4 книжная"
        $map["Application UnhandledException:{0};`n`r堆栈信息:{1}"] = "Application UnhandledException:{0};`n`rСтек:{1}"
        $map["AutoCAD标准样式"] = "Стандарт AutoCAD"
        $map["BOM报表"] = "Отчёт BOM"
        $map["BOM报表 【"] = "Отчёт BOM 【"
        $map["BOM方案"] = "Схема BOM"
        $map["BOM模板:"] = "Шаблон BOM:"
        $map["BOM模板文件夹："] = "Папка шаблонов BOM:"
        $map["BOM模板文件（*.xls;*.xlsx）|*.xls;*.xlsx"] = "Шаблон BOM (*.xls;*.xlsx)|*.xls;*.xlsx"
        $map["BOM类型"] = "Тип BOM"
        $map["BOM表模板"] = "Шаблон BOM"
        $map["CGS(厘米、克、秒)"] = "СГС (см, г, с)"
        $map["DXF/DWG输出选项"] = "Параметры экспорта DXF/DWG"
        $map["Excel 工作簿（*"] = "Книга Excel (*"
        $map["Excel 工作簿（*xlsx）|*.xlsx|Excel 97-2003工作簿（*xls）|*.xls"] = "Книга Excel (*.xlsx)|*.xlsx|Книга Excel 97-2003 (*.xls)|*.xls"
        $map["Excel 文件（*.xls;*.xlsx）|*.xls;*.xlsx"] = "Файл Excel (*.xls;*.xlsx)|*.xls;*.xlsx"
        $map["ID001-轴承座-001"] = "ID001-Корпус-001"
        $map["ID010-轴承座-010"] = "ID010-Корпус-010"
        $map["IPS(英寸、磅、秒)"] = "IPS (дюйм, фунт, с)"
        $map["JPG/PNG输出选项"] = "Параметры экспорта JPG/PNG"
        $map["MMGS(毫米、克、秒)"] = "ММГС (мм, г, с)"
        $map["MMKS(毫米、千克、秒)"] = "ММКС (мм, кг, с)"
        $map["PDF文件(*.pdf)|*.p"] = "Файл PDF (*.pdf)|*.p"
        $map["PDF水印"] = "Водяной знак PDF"
        $map["PDF输出选项"] = "Параметры экспорта PDF"
        $map["PowerShell 执行失败 (ExitCode: "] = "PowerShell завершился с ошибкой (ExitCode: "
        $map["Q Q群: 823539419"] = ""
        $map["QQ群"] = ""
        $map["QQ群:"] = ""
        $map["RGB全色"] = "RGB полноцветный"
        $map["SOLIDWORKS文件(*.SLDPRT;*.SLDASM)|"] = "Файлы SOLIDWORKS (*.SLDPRT;*.SLDASM)|"
        $map["SW-上次保存的日期(Last Saved Date)"] = "SW-Дата последнего сохранения (Last Saved Date)"
        $map["SW-上次保存者(Last Saved By)"] = "SW-Кто сохранил последним (Last Saved By)"
        $map["SW-主题(Subject)"] = "SW-Тема (Subject)"
        $map["SW-体积"] = "SW-Объём"
        $map["SW-作者(Author)"] = "SW-Автор (Author)"
        $map["SW-关键词(Keywords)"] = "SW-Ключевые слова (Keywords)"
        $map["SW-密度"] = "SW-Плотность"
        $map["SW-文件名称(File Name)"] = "SW-Имя файла (File Name)"
        $map["SW-文件夹名称(Folder Name)"] = "SW-Имя папки (Folder Name)"
        $map["SW-材质"] = "SW-Материал"
        $map["SW-标题 (Title)"] = "SW-Заголовок (Title)"
        $map["SW-生成的日期(Created Date)"] = "SW-Дата создания (Created Date)"
        $map["SW-表面积"] = "SW-Площадь поверхности"
        $map["SW-评述(Comments)"] = "SW-Заметки (Comments)"
        $map["SW-质量"] = "SW-Масса"
        $map["SW-配置名称(Configuration Name)"] = "SW-Имя конфигурации (Configuration Name)"
        $map["SW属性"] = "Свойства SW"
        $map["SW模板"] = "Шаблон SW"
        $map["SolidWorks中没有打开文件,请先打开文件"] = "В SolidWorks нет открытых файлов — откройте файл"
        $map["SolidWorks当前活动的文档可能未保存，请先保存"] = "Активный документ SolidWorks может быть не сохранён — сохраните"
        $map["SolidWorks自定义样式"] = "Пользовательский стиль SolidWorks"
        $map["SolidWorks高效辅助工具`n批量重命名、编辑属性、打印、转图、生成bom等"] = "Помощник SolidWorks`nПакетное переименование, редактирование свойств, печать, конвертация, BOM и др."
        $map["SpeedPak配置"] = "Конфигурация SpeedPak"
        $map["ZTool检测更新"] = "Проверка обновлений"
        $map["\BOM表模板"] = "\Шаблоны BOM"
        $map["\BOM表模板\bom模板.xlsx"] = "\Шаблоны BOM\шаблон-bom.xlsx"
        $map["bom数据（*txt）|*.txt"] = "Данные BOM (*.txt)|*.txt"
        $map["help.chm文件没找到"] = "Файл help.chm не найден"
        $map["oShellLink.Description =`"SolidWorks高效辅助工具`" "] = "oShellLink.Description =`"Помощник SolidWorks`" "
        $map["pdf文件（*.pdf）|*.pdf"] = "PDF (*.pdf)|*.pdf"
        $map["solidworks启动失败"] = "Не удалось запустить SolidWorks"
        $map["solidworks宏文件（*.swb;*.swp）|*.swb;*.swp"] = "Макросы SolidWorks (*.swb;*.swp)|*.swb;*.swp"
        $map["一生何求"] = ""
        $map["上移"] = "Вверх"
        $map["下一步"] = "Далее"
        $map["下横线 `"_`""] = "Подчёркивание `"_`""
        $map["下移"] = "Вниз"
        $map["下载失败："] = "Ошибка загрузки:"
        $map["下载完毕！是否立即安装更新？`n注：安装前会关闭主程序和SolidWorks进程，请注意保存数据！"] = "Загрузка завершена. Установить обновление сейчас?`nВнимание: перед установкой будут закрыты программа и процесс SolidWorks — сохраните данные!"
        $map["下载更新"] = "Загрузить обновление"
        $map["不做处理"] = "Без обработки"
        $map["不包含"] = "Не содержит"
        $map["不包括在材料明细表中（&E）"] = "Не включать в BOM (&E)"
        $map["不处理"] = "Не обрабатывать"
        $map["不存在,是否创建？"] = "Не существует, создать?"
        $map["不存在！"] = "Не существует!"
        $map["不支持Win32s."] = "Win32s не поддерживается."
        $map["不支持Win9x."] = "Win9x не поддерживается."
        $map["不支持WinCE."] = "WinCE не поддерживается."
        $map["不支持当前活动文档"] = "Активный документ не поддерживается"
        $map["不是有效的宏文件"] = "Не является валидным макросом"
        $map["不知道的操作系统."] = "Неизвестная ОС."
        $map["不符合同步条件"] = "Не соответствует условиям синхронизации"
        $map["不等于"] = "Не равно"
        $map["与"] = "и"
        $map["与原文件夹相同"] = "Совпадает с исходной папкой"
        $map["与服务器通信异常"] = "Ошибка связи с сервером"
        $map["与装配体相同"] = "Совпадает со сборкой"
        $map["个同名文件"] = " файлов с тем же именем"
        $map["个文件"] = " файлов"
        $map["个文件，勾选了"] = " файлов, отмечено"
        $map["中文字符"] = "Китайские символы"
        $map["主页:"] = "Сайт:"
        $map["二维码"] = "QR-код"
        $map["互换列"] = "Поменять столбцы"
        $map["亲！确定清空列表吗？"] = "Очистить список?"
        $map["仅输出激活的图纸"] = "Выводить только активные листы"
        $map["仅输出第一页"] = "Выводить только первую страницу"
        $map["仅限于AutoCAD标准"] = "Только для стандарта AutoCAD"
        $map["仅限单列操作"] = "Только для одного столбца"
        $map["仅限有工程图的项"] = "Только элементы с чертежами"
        $map["仅限零件"] = "Только детали"
        $map["仅限顶层"] = "Только верхний уровень"
        $map["今天。。。"] = "Сегодня..."
        $map["从`""] = "Из `""
        $map["从solidworks中已打开的零部件中获取"] = "Получить из открытых в SolidWorks компонентов"
        $map["从solidworks属性模板中获取"] = "Получить из шаблона свойств SolidWorks"
        $map["从主界面导入"] = "Импорт из главного окна"
        $map["从文件中获取"] = "Получить из файла"
        $map["从文件夹中获取"] = "Получить из папки"
        $map["从第"] = "С позиции"
        $map["从第10位开始向后取10位"] = "С 10-й позиции взять 10 символов"
        $map["从第10位开始向后取至结尾"] = "С 10-й позиции до конца"
        $map["从第10位开始向后最少取10位，最大取20位"] = "С 10-й позиции минимум 10, максимум 20 символов"
        $map["以免数据丢失`r`n是否在关闭文件前先保存？"] = "Чтобы избежать потери данных,`r`nсохранить файлы перед закрытием?"
        $map["以彩色输出"] = "Цветной вывод"
        $map["任务停止"] = "Задача остановлена"
        $map["任务取消"] = "Задача отменена"
        $map["任务完成"] = "Задача выполнена"
        $map["任务正在停止"] = "Задача останавливается"
        $map["使用指定的打印机线粗(文件、打印、线粗)"] = "Использовать толщины линий принтера (Файл, Печать, Толщина линий)"
        $map["使用材质颜色"] = "Цвет материала"
        $map["使用说明"] = "Инструкция"
        $map["保存全部"] = "Сохранить всё"
        $map["保存到SW"] = "Сохранить в SW"
        $map["保存到SW过程出错：`n"] = "Ошибка при сохранении в SW:`n"
        $map["保存到新文件夹"] = "Сохранить в новую папку"
        $map["保存到："] = "Сохранить в:"
        $map["保存合并后的PDF文件"] = "Сохранить объединённый PDF"
        $map["保存完毕，建议重新获取数据！"] = "Сохранение завершено. Рекомендуется обновить данные!"
        $map["保存完毕，耗时"] = "Сохранение завершено, время:"
        $map["保留值为空的属性"] = "Сохранять свойства с пустыми значениями"
        $map["信息"] = "Информация"
        $map["修改"] = "Изменить"
        $map["修改项"] = "Изменённые"
        $map["倍率："] = "Масштаб:"
        $map["值"] = "Значение"
        $map["停止"] = "Стоп"
        $map["停止任务"] = "Остановить задачу"
        $map["兆牛顿"] = "МН"
        $map["先以此排序"] = "Сортировать сначала по"
        $map["克"] = "г"
        $map["全部"] = "Все"
        $map["全部取消"] = "Снять все"
        $map["全部展开"] = "Развернуть все"
        $map["全部替换"] = "Заменить все"
        $map["全部选择"] = "Выделить все"
        $map["公斤"] = "кг"
        $map["共"] = "всего"
        $map["共 "] = "всего "
        $map["关于"] = "О программе"
        $map["关联填写"] = "Связанное заполнение"
        $map["关闭文件中......"] = "Закрытие файлов..."
        $map["其他"] = "Другое"
        $map["其它"] = "Прочее"
        $map["其它            "] = "Прочее            "
        $map["其它位置"] = "Другое расположение"
        $map["再以此排序"] = "Затем по"
        $map["冰雨。。。"] = "Зимний дождь..."
        $map["准备读取SW数据时出错：`n"] = "Ошибка при подготовке к чтению данных SW:`n"
        $map["分"] = "мин"
        $map["分割"] = "Разделить"
        $map["分割规则"] = "Правило разделения"
        $map["分割规则："] = "Правило разделения:"
        $map["分升"] = "дл"
        $map["分号 `";`""] = "Точка с запятой `";`""
        $map["分离的工程图(slddrw)"] = "Отдельные чертежи (slddrw)"
        $map["分类"] = "Категория"
        $map["分辨率和比例"] = "Разрешение и масштаб"
        $map["列名称"] = "Имя столбца"
        $map["列数据对比"] = "Сравнение столбцов"
        $map["列查找"] = "Поиск в столбце"
        $map["列标题"] = "Заголовок столбца"
        $map["列标题映射"] = "Сопоставление заголовков"
        $map["列表"] = "Список"
        $map["列表ToolStripMenuItem"] = "СписокToolStripMenuItem"
        $map["列表ToolStripMenuItem1"] = "СписокToolStripMenuItem1"
        $map["列表中没有文件"] = "Список файлов пуст"
        $map["创建工程图"] = "Создать чертёж"
        $map["创建工程图出错：`n"] = "Ошибка создания чертежа:`n"
        $map["创建工程图（支持多选）"] = "Создать чертёж (мультивыбор)"
        $map["创建快捷方式失败！"] = "Не удалось создать ярлык!"
        $map["创建快捷方式失败：`r`n"] = "Не удалось создать ярлык:`r`n"
        $map["创建快捷方式失败：`r`n目标程序不存在！"] = "Не удалось создать ярлык:`r`nЦелевая программа не существует!"
        $map["创建规则"] = "Создать правило"
        $map["初始化"] = "Инициализация"
        $map["删除"] = "Удалить"
        $map["删除列"] = "Удалить столбец"
        $map["删除工程图（支持多选）"] = "Удалить чертёж (мультивыбор)"
        $map["删除悬空注解和尺寸"] = "Удалить висячие аннотации и размеры"
        $map["删除材质"] = "Удалить материал"
        $map["删除选中"] = "Удалить выбранное"
        $map["刷新数据"] = "Обновить данные"
        $map["刷新缩略图？"] = "Обновить эскизы?"
        $map["前缀："] = "Префикс:"
        $map["剩余"] = "Осталось"
        $map["力"] = "Сила"
        $map["力量"] = "Сила"
        $map["加载solidworks中已打开的工程图"] = "Загрузить открытые в SolidWorks чертежи"
        $map["加载solidworks中已打开的所有文件"] = "Загрузить все открытые в SolidWorks файлы"
        $map["加载solidworks中已打开的装配体"] = "Загрузить открытые сборки SolidWorks"
        $map["加载solidworks中已打开的零件"] = "Загрузить открытые детали SolidWorks"
        $map["加载solidworks中已打开零件的工程图"] = "Загрузить чертежи открытых деталей SolidWorks"
        $map["加载solidworks中激活的装配体"] = "Загрузить активную сборку SolidWorks"
        $map["加载solidworks当前项"] = "Загрузить текущий элемент SolidWorks"
        $map["加载solidworks当前项及其工程图"] = "Загрузить текущий элемент и его чертёж"
        $map["加载主界面数据"] = "Загрузить данные главного окна"
        $map["加载完成,耗时 "] = "Загрузка завершена, время "
        $map["加载当前装配体中已选中项的工程图"] = "Загрузить чертежи выбранных элементов текущей сборки"
        $map["加载当前装配体中所有零件的工程图"] = "Загрузить чертежи всех деталей текущей сборки"
        $map["加载当前装配体中有工程图的零件"] = "Загрузить детали текущей сборки, имеющие чертежи"
        $map["加载当前装配体中的所有零件"] = "Загрузить все детали текущей сборки"
        $map["加载当前装配体中的所有零件及其工程图"] = "Загрузить все детали текущей сборки и их чертежи"
        $map["加载当前装配体中选中的项"] = "Загрузить выбранные элементы текущей сборки"
        $map["加载当前装配体中选中的项及其工程图"] = "Загрузить выбранные элементы и их чертежи"
        $map["加载当前装配体中选中的项的工程图"] = "Загрузить чертежи выбранных элементов"
        $map["加载指定装配体中所有零件的工程图"] = "Загрузить чертежи всех деталей указанной сборки"
        $map["加载指定装配体中的所有零件"] = "Загрузить все детали указанной сборки"
        $map["加载指定装配体中的所有零件及其工程图"] = "Загрузить все детали указанной сборки и их чертежи"
        $map["加载指定装配体中的有工程图的零件"] = "Загрузить детали указанной сборки, имеющие чертежи"
        $map["加载数据中，请稍后..."] = "Загрузка данных, подождите..."
        $map["加载数据出错：`n"] = "Ошибка загрузки данных:`n"
        $map["加载装配体中选中的项"] = "Загрузить выбранные элементы сборки"
        $map["加载装配体中选中的项的工程图"] = "Загрузить чертежи выбранных элементов сборки"
        $map["包含"] = "Включить"
        $map["包含3D零部件"] = "Включать 3D-компоненты"
        $map["包含其它同名文件（多个项目用分号隔开，如：.pdf;.dwg）"] = "Включать одноимённые файлы (несколько через `";`": .pdf;.dwg)"
        $map["包含在材料明细表中（&I）"] = "Включить в BOM (&I)"
        $map["包含子文件夹"] = "Включая подпапки"
        $map["包含子目录"] = "Включая подкаталоги"
        $map["包含工程图"] = "Включать чертежи"
        $map["包含最顶层"] = "Включая верхний уровень"
        $map["包含符合项"] = "Включать совпадения"
        $map["包含虚拟零件（此选项会将虚拟零件保存到外部）"] = "Включать виртуальные детали (будут сохранены отдельно)"
        $map["匹配"] = "Совпадение"
        $map["匹配 "] = "Совпадение "
        $map["匹配规则"] = "Правило совпадения"
        $map["区分大小写"] = "Учитывать регистр"
        $map["千克-力"] = "кгс"
        $map["千分英寸"] = "мил"
        $map["千分英寸^3"] = "мил^3"
        $map["千牛顿"] = "кН"
        $map["千瓦"] = "кВт"
        $map["千瓦-小时"] = "кВт·ч"
        $map["升"] = "л"
        $map["升序"] = "По возрастанию"
        $map["华文行楷"] = "Курсив"
        $map["单位"] = "Единицы"
        $map["单位体积"] = "Удельный объём"
        $map["单位系统"] = "Система единиц"
        $map["单级BOM"] = "Одноуровневая BOM"
        $map["压缩零部件（&S"] = "Погасить компоненты (&S"
        $map["厘升"] = "сл"
        $map["厘米"] = "см"
        $map["厘米^3"] = "см^3"
        $map["原位置（新建属性在自定义）"] = "Исходная позиция (новые свойства — пользовательские)"
        $map["原位置（新建属性在配置）"] = "Исходная позиция (новые свойства — в конфигурации)"
        $map["原图大小"] = "Оригинальный размер"
        $map["原文件夹名称："] = "Исходное имя папки:"
        $map["原点:"] = "Начало координат:"
        $map["原配置名"] = "Исходное имя конфигурации"
        $map["去设置"] = "К настройкам"
        $map["参考文件"] = "Файл ссылки"
        $map["参考类型"] = "Тип ссылки"
        $map["参考路径 "] = "Путь ссылки "
        $map["双击输入当前装配体目录"] = "Двойной щелчок — указать каталог текущей сборки"
        $map["双击选择需要连接的Solidworks进程"] = "Двойной щелчок — выбрать процесс SolidWorks для подключения"
        $map["双尺寸长度"] = "Двойной размер"
        $map["反向选择"] = "Инвертировать выделение"
        $map["发布日期："] = "Дата выпуска:"
        $map["发现新版本！`r`n"] = "Доступна новая версия!`r`n"
        $map["取()内字符"] = "Извлечь символы из ()"
        $map["取_或空格到结尾"] = "От _ или пробела до конца"
        $map["取中文字符"] = "Извлечь китайские символы"
        $map["取前10位"] = "Первые 10 символов"
        $map["取后10位"] = "Последние 10 символов"
        $map["取开头到_|(（[【空格或结尾之间的字符"] = "От начала до _|(（[【пробела или конца"
        $map["取消"] = "Отмена"
        $map["取类似V1.1的字符"] = "Извлечь шаблон V1.1"
        $map["取结尾处类似V1.1的字符"] = "Извлечь шаблон V1.1 в конце"
        $map["只保存修改项"] = "Сохранять только изменённые"
        $map["只保存失败项"] = "Сохранять только неуспешные"
        $map["只对从主界面导入的工程图和选中项的工程图有效"] = "Действует только для чертежей, импортированных из главного окна и выбранных"
        $map["只导出一个配置时不附带配置名"] = "Не добавлять имя конфигурации при экспорте одной конфигурации"
        $map["只打印"] = "Только печать"
        $map["只能选择一项"] = "Можно выбрать только один элемент"
        $map["右上"] = "Сверху справа"
        $map["右上角"] = "Верхний правый угол"
        $map["右下"] = "Снизу справа"
        $map["右下角"] = "Нижний правый угол"
        $map["合并PDF"] = "Объединить PDF"
        $map["合并PDF-"] = "Объединить PDF —"
        $map["合并和拆分PDF"] = "Объединить и разделить PDF"
        $map["合并完成"] = "Объединение завершено"
        $map["同步完成"] = "Синхронизация завершена"
        $map["同步工程图名称"] = "Синхронизация имён чертежей"
        $map["名称"] = "Имя"
        $map["名称`""] = "Имя `""
        $map["名称已存在，序号："] = "Имя уже существует, номер:"
        $map["名称重复"] = "Имя повторяется"
        $map["名称："] = "Имя:"
        $map["后缀："] = "Суффикс:"
        $map["否"] = "Нет"
        $map["启动Excel失败！"] = "Не удалось запустить Excel!"
        $map["启用筛选"] = "Включить фильтр"
        $map["启用规则"] = "Включить правило"
        $map["回收站"] = "Корзина"
        $map["图像类型："] = "Тип изображения:"
        $map["图号"] = "Номер"
        $map["图号`n0"] = "Номер`n0"
        $map["图片"] = "Изображение"
        $map["图片位置"] = "Положение изображения"
        $map["图片文件"] = "Файл изображения"
        $map["图片文件（*.bmp;*.jpg;*.png）|*.bmp;*.jpg;*.png"] = "Изображения (*.bmp;*.jpg;*.png)|*.bmp;*.jpg;*.png"
        $map["图片路径："] = "Путь к изображению:"
        $map["图纸区域原点"] = "Начало области чертежа"
        $map["图纸大小"] = "Размер листа"
        $map["图纸格式"] = "Формат чертежа"
        $map["图纸格式所在文件夹："] = "Папка форматов чертежа:"
        $map["图纸格式路径不存在，请重新设置"] = "Путь к формату чертежа не существует — задайте заново"
        $map["在 "] = "В "
        $map["在Solidworks中打开"] = "Открыть в SolidWorks"
        $map["在solidworks中打开"] = "Открыть в SolidWorks"
        $map["在solidworks中打开ToolStripMenuItem"] = "ОткрытьВSolidWorksToolStripMenuItem"
        $map["在solidworks中选中"] = "Выбрать в SolidWorks"
        $map["在使用为子装配体时子零部件的显示"] = "Отображение компонентов при использовании как подсборки"
        $map["在文件夹中打开"] = "Открыть в папке"
        $map["在文件夹中打开ToolStripMenuItem"] = "ОткрытьВПапкеToolStripMenuItem"
        $map["在文件夹中显示"] = "Показать в папке"
        $map["在文件夹中显示 (&F）"] = "Показать в папке (&F)"
        $map["在材料明细表中使用时所显示的零件号："] = "Номер детали при использовании в BOM:"
        $map["在线激活"] = "Онлайн-активация"
        $map["埃"] = "Å"
        $map["埃^3"] = "Å^3"
        $map["基本单位"] = "Базовая единица"
        $map["填充内容："] = "Содержимое заполнения:"
        $map["填充列"] = "Заполнить столбец"
        $map["填充文件名"] = "Заполнить имя файла"
        $map["填充方案"] = "Схема заполнения"
        $map["增量："] = "Шаг:"
        $map["备份-"] = "Резерв-"
        $map["备份完成，耗时"] = "Резервное копирование завершено, время"
        $map["备份已取消"] = "Резервное копирование отменено"
        $map["备注"] = "Заметки"
        $map["复制"] = "Копировать"
        $map["复制列"] = "Копировать столбец"
        $map["复制列："] = "Копировать столбец:"
        $map["复制备份"] = "Копировать резерв"
        $map["复制失败！请检查源文件是否存在。"] = "Ошибка копирования! Проверьте существование исходного файла."
        $map["复制属性值"] = "Копировать значение свойства"
        $map["复制工程图"] = "Копировать чертёж"
        $map["复制工程图出错：`n"] = "Ошибка копирования чертежа:`n"
        $map["复制文件..."] = "Копирование файлов..."
        $map["复制表格"] = "Копировать таблицу"
        $map["多个条件可用`"&`"或者`"|`"分割`n&：并且`n|：或者"] = "Несколько условий через `"&`" или `"|`"`n&: И`n|: ИЛИ"
        $map["多图纸工程图："] = "Многолистовой чертёж:"
        $map["多级BOM"] = "Многоуровневая BOM"
        $map["大图标"] = "Крупные значки"
        $map["天意。。。"] = "Судьба..."
        $map["字体"] = "Шрифт"
        $map["字体："] = "Шрифт:"
        $map["安装更新"] = "Установить обновление"
        $map["宋体"] = "SimSun"
        $map["宏文件 "] = "Файл макроса "
        $map["宏程序"] = "Макрос"
        $map["宽度："] = "Ширина:"
        $map["密码格式不正确，请输入8-20位包含大小写字母和数字的密码"] = "Неверный формат пароля. Введите 8-20 символов с заглавными, строчными буквами и цифрами"
        $map["密码错误"] = "Неверный пароль"
        $map["密耳"] = "мил"
        $map["密耳^3"] = "мил^3"
        $map["对满足自定义规则的项进行填充"] = "Заполнить элементы по пользовательским правилам"
        $map["对选中的项执行solidworks宏程序"] = "Выполнить макрос SolidWorks для выбранных элементов"
        $map["导入..."] = "Импорт..."
        $map["导出BOM出错：`n"] = "Ошибка экспорта BOM:`n"
        $map["导出到excel"] = "Экспорт в Excel"
        $map["导出到txt"] = "Экспорт в TXT"
        $map["导出到txt出错：`n"] = "Ошибка экспорта в TXT:`n"
        $map["导出成功"] = "Экспорт выполнен"
        $map["导出成功！是否打开？"] = "Экспорт выполнен. Открыть?"
        $map["导出时标记没有工程图的项"] = "Отмечать при экспорте элементы без чертежей"
        $map["导出汇总BOM"] = "Экспорт сводной BOM"
        $map["导出缩进式BOM"] = "Экспорт BOM с отступами"
        $map["导出零件汇总BOM"] = "Экспорт сводной BOM деталей"
        $map["导出顶层BOM"] = "Экспорт BOM верхнего уровня"
        $map["将第"] = "Из позиции"
        $map["小图标"] = "Мелкие значки"
        $map["小图标ToolStripMenuItem"] = "МелкиеЗначкиToolStripMenuItem"
        $map["小数"] = "Дробное"
        $map["尔格"] = "эрг"
        $map["层级"] = "Уровень"
        $map["层级`tpathname`tcfgname`tExcludeFromBOM`tIsEnvelope`tIsVirtual`tSelectName"] = "Уровень`tpathname`tcfgname`tExcludeFromBOM`tIsEnvelope`tIsVirtual`tSelectName"
        $map["层级数量"] = "Количество уровней"
        $map["屏幕捕获"] = "Снимок экрана"
        $map["属性"] = "Свойство"
        $map["属性保存设置"] = "Настройки сохранения свойств"
        $map["属性名称"] = "Имя свойства"
        $map["属性模板(*.prtprp;*.asmprp)|"] = "Шаблон свойств (*.prtprp;*.asmprp)|"
        $map["属性表达式"] = "Выражение свойства"
        $map["属性表达式/评估的值"] = "Выражение свойства / вычисленное значение"
        $map["嵌入字体"] = "Встраивать шрифты"
        $map["工具箱.png"] = "toolbox.png"
        $map["工程图(*.SLDDRW)|*."] = "Чертёж (*.SLDDRW)|*."
        $map["工程图已存在，是否打开？"] = "Чертёж уже существует. Открыть?"
        $map["工程图已存在，是否覆盖？"] = "Чертёж уже существует. Перезаписать?"
        $map["工程图颜色"] = "Цвет чертежа"
        $map["工程图（.SLDDRW）"] = "Чертёж (.SLDDRW)"
        $map["左上"] = "Сверху слева"
        $map["左上角"] = "Верхний левый угол"
        $map["左下"] = "Снизу слева"
        $map["左下角"] = "Нижний левый угол"
        $map["已存在同名工程图"] = "Чертёж с таким именем уже существует"
        $map["已成功复制 "] = "Успешно скопировано "
        $map["已选择 "] = "Выбрано "
        $map["帮助"] = "Справка"
        $map["平铺ToolStripMenuItem"] = "РядомToolStripMenuItem"
        $map["并从以下位置删除"] = "И удалить из следующих позиций"
        $map["并从以下位置删除多余的属性"] = "И удалить лишние свойства из следующих позиций"
        $map["序号"] = "N"
        $map["序号 "] = "N "
        $map["应用"] = "Применить"
        $map["应用程序"] = "Приложение"
        $map["应用程序线程错误:{0}"] = "Ошибка потока приложения: {0}"
        $map["度"] = "градус"
        $map["度/分"] = "градус/мин"
        $map["度/分秒"] = "градус/мин/сек"
        $map["开发者:"] = "Разработчик:"
        $map["开头不是"] = "Не начинается с"
        $map["开头是"] = "Начинается с"
        $map["开始"] = "Главная"
        $map["开始行："] = "Начальная строка:"
        $map["异常信息：检测到dnSpy非法启动"] = "Обнаружен недопустимый запуск dnSpy"
        $map["异常消息：{0}"] = "Сообщение исключения: {0}"
        $map["异常类型：{0}`r`n异常消息：{1}`r`n异常信息：{2}"] = "Тип исключения: {0}`r`nСообщение: {1}`r`nИнформация: {2}"
        $map["异常类型：{0}`r`n异常消息：{1}`r`n异常信息：{2}`r`n"] = "Тип исключения: {0}`r`nСообщение: {1}`r`nИнформация: {2}`r`n"
        $map["弧度"] = "радиан"
        $map["当前SolidWorks版本调用失败！"] = "Ошибка вызова текущей версии SolidWorks!"
        $map["当前任务中断，可尝试按`"下一步`" ➜ `"开始`"继续任务"] = "Текущая задача прервана. Нажмите `"Далее`" ➜ `"Главная`", чтобы продолжить"
        $map["当前共"] = "Текущий общий"
        $map["当前启动程序集的公钥令牌不符"] = "Несовпадение public key token запущенной сборки"
        $map["当前已是最新版本！"] = "Установлена последняя версия!"
        $map["当前日期"] = "Текущая дата"
        $map["当前模型不存在或所在目录无权访问"] = "Текущая модель не существует или нет прав на каталог"
        $map["当前模型已经存在工程图！"] = "У текущей модели уже есть чертёж!"
        $map["当前没有打开文档"] = "Нет открытых документов"
        $map["当前配置"] = "Текущая конфигурация"
        $map["当前项不可使用"] = "Текущий элемент недоступен"
        $map["当电脑不能上网时，可以用手机扫描左侧二维`r`n码将信息发给作者获取离线授权文件。"] = "Если компьютер без интернета, отсканируйте QR-код слева телефоном`r`nи отправьте данные разработчику для получения офлайн-лицензии."
        $map["待拆分的列："] = "Столбец для разделения:"
        $map["待读取的文件列表"] = "Список файлов для чтения"
        $map["微升"] = "мкл"
        $map["微秒"] = "мкс"
        $map["微米"] = "мкм"
        $map["微米^3"] = "мкм^3"
        $map["微软雅黑"] = "Microsoft YaHei"
        $map["忘情水。。。"] = "Воды забвения..."
        $map["快捷方式创建成功！"] = "Ярлык создан!"
        $map["总数量"] = "Общее количество"
        $map["恢复为材质颜色"] = "Восстановить цвет материала"
        $map["悬空注解"] = "Висячие аннотации"
        $map["成功"] = "Успех"
        $map["或"] = "или"
        $map["所有文件（*.*）|*.*"] = "Все файлы (*.*)|*.*"
        $map["所有配置"] = "Все конфигурации"
        $map["才能启用"] = "Для включения требуется"
        $map["打包到文件夹"] = "Упаковать в папку"
        $map["打印"] = "Печать"
        $map["打印份数："] = "Число копий:"
        $map["打印到文件"] = "Печать в файл"
        $map["打印捕获"] = "Снимок печати"
        $map["打印日期："] = "Дата печати:"
        $map["打印机"] = "Принтер"
        $map["打印纸张大小"] = "Размер бумаги"
        $map["打印设置"] = "Настройки печати"
        $map["打印首选项(&E)..."] = "Параметры печати (&E)..."
        $map["打开"] = "Открыть"
        $map["打开 "] = "Открыть "
        $map["打开pdf"] = "Открыть PDF"
        $map["打开上一次转图文件夹"] = "Открыть папку последней конвертации"
        $map["打开工程图"] = "Открыть чертёж"
        $map["打开工程图 (&D）"] = "Открыть чертёж (&D)"
        $map["打开帮助文件"] = "Открыть справку"
        $map["打开帮助文件出错：`n"] = "Ошибка открытия справки:`n"
        $map["打开当前Excel数据源"] = "Открыть текущий источник Excel"
        $map["打开当前Excel模板"] = "Открыть текущий шаблон Excel"
        $map["打开当前目录"] = "Открыть текущий каталог"
        $map["打开装配体"] = "Открыть сборку"
        $map["打开装配体 (&W）"] = "Открыть сборку (&W)"
        $map["打开零件"] = "Открыть деталь"
        $map["打开零件 (&W）"] = "Открыть деталь (&W)"
        $map["打开零部件"] = "Открыть компонент"
        $map["执行宏操作..."] = "Выполнение макроса..."
        $map["执行宏（支持多选）"] = "Выполнить макрос (мультивыбор)"
        $map["批量复制 (&C）"] = "Пакетное копирование (&C)"
        $map["批量打印"] = "Пакетная печать"
        $map["批量粘贴 (&V）"] = "Пакетная вставка (&V)"
        $map["找不同"] = "Найти отличия"
        $map["找相同"] = "Найти совпадения"
        $map["报表类型"] = "Тип отчёта"
        $map["拆分 "] = "Разделить "
        $map["拆分PDF"] = "Разделить PDF"
        $map["拆分列"] = "Разделить столбец"
        $map["拆分后保存到文件夹"] = "Сохранять в папку после разделения"
        $map["拆分后填写到："] = "Заполнить после разделения в:"
        $map["拆分完成"] = "Разделение завершено"
        $map["拆分操作"] = "Операция разделения"
        $map["拆分方式"] = "Способ разделения"
        $map["拖动行表头可排序，选中行表头，按del键可以删除整行。"] = "Перетащите заголовок строки для сортировки. Выделите заголовок и нажмите Del для удаления строки."
        $map["按1：1输出"] = "Вывод 1:1"
        $map["按上次保存"] = "Как при последнем сохранении"
        $map["按勾选"] = "По отмеченным"
        $map["按工程图中第一个视图的比例输出（所有视图比例都不等于`r`n图纸比例时才生效）"] = "Вывод по масштабу первого вида чертежа (только если масштабы всех видов`r`nне равны масштабу листа)"
        $map["按搜索规则"] = "По правилу поиска"
        $map["按模板导出"] = "Экспорт по шаблону"
        $map["按筛选"] = "По фильтру"
        $map["按规则"] = "По правилу"
        $map["按配置打印"] = "По конфигурации"
        $map["按配置执行（只对从主界面导入的项、选中项及工程图有效）"] = "По конфигурации (только для импортированных, выбранных и чертежей)"
        $map["按颜色筛选"] = "Фильтр по цвету"
        $map["换行符"] = "Перевод строки"
        $map["授权保护密码(在샌㭯빓溋왿ś౸泿摒衑䍣๧왔ś챸自动清除):"] = "Пароль защиты лицензии:"
        $map["排除符合项"] = "Исключать совпадения"
        $map["推荐使用的分隔符：短横`"-`"、下横线`"_`"和空格。`r`n当引用属性值为空时可自动消隐分隔符。"] = "Рекомендуемые разделители: `"-`", `"_`" и пробел.`r`nПри пустом значении свойства разделитель скрывается автоматически."
        $map["提升"] = "Поднять"
        $map["提示"] = "Подсказка"
        $map["提示："] = "Подсказка:"
        $map["插件未启动"] = "Плагин не запущен"
        $map["插件未启动！"] = "Плагин не запущен!"
        $map["插入..."] = "Вставить..."
        $map["插入缩略图"] = "Вставить эскиз"
        $map["插入链接...."] = "Вставить ссылку..."
        $map["搜索"] = "Поиск"
        $map["撤销"] = "Отмена действия"
        $map["操作"] = "Действие"
        $map["支持系统版本"] = "Поддерживаемая версия ОС"
        $map["支持系统版本：Win7及以上"] = "Поддерживаемые ОС: Windows 7 и выше"
        $map["数字"] = "Число"
        $map["数据填写到"] = "Заполнить данные в"
        $map["数据源"] = "Источник данных"
        $map["数据源不存在，请先设置数据源文件"] = "Источник данных не существует — задайте файл источника"
        $map["数量"] = "Кол-во"
        $map["文件"] = "Файл"
        $map["文件(*.*|*.*"] = "Файл (*.*)|*.*"
        $map["文件列表"] = "Список файлов"
        $map["文件列表(可直接将文件或文件夹拖拽进列表中)"] = "Список файлов (можно перетащить файлы или папки)"
        $map["文件名"] = "Имя файла"
        $map["文件名规则："] = "Правило имени файла:"
        $map["文件名重复"] = "Имя файла повторяется"
        $map["文件夹"] = "Папка"
        $map["文件打印机"] = "Принтер в файл"
        $map["文件类型"] = "Тип файла"
        $map["文字"] = "Текст"
        $map["文本"] = "Текст"
        $map["文本位置"] = "Положение текста"
        $map["文本文件（*txt）|*.txt"] = "Текстовый файл (*.txt)|*.txt"
        $map["文档名称"] = "Имя документа"
        $map["斜线`"\`""] = "Слэш `"\`""
        $map["新参考文件路径"] = "Новый путь файла ссылки"
        $map["新图纸格式"] = "Новый формат чертежа"
        $map["新文件夹名称："] = "Имя новой папки:"
        $map["新配置名"] = "Имя новой конфигурации"
        $map["无"] = "(нет)"
        $map["无可以模板"] = "Нет доступных шаблонов"
        $map["无效数据源！"] = "Недопустимый источник данных!"
        $map["无效模板"] = "Недопустимый шаблон"
        $map["无效注册码"] = "Недопустимый ключ лицензии"
        $map["无效注册码，请联系作者购买注册码"] = "Недопустимый ключ лицензии. Свяжитесь с разработчиком для покупки."
        $map["无法打开当前模型！"] = "Не удалось открыть текущую модель!"
        $map["无需同步"] = "Синхронизация не требуется"
        $map["无需转出"] = "Перенос не требуется"
        $map["日期"] = "Дата"
        $map["时"] = "ч"
        $map["时间"] = "Время"
        $map["明细表选项"] = "Параметры спецификации"
        $map["映射名称"] = "Имя сопоставления"
        $map["是"] = "Да"
        $map["是否立即安装更新？`n注：安装前会关闭主程序和SolidWorks进程，请注意保存！"] = "Установить обновление сейчас?`nВнимание: перед установкой будут закрыты программа и SolidWorks — сохраните данные!"
        $map["是或否"] = "Да или нет"
        $map["显示"] = "Показать"
        $map["显示/隐藏缩略图"] = "Показать/скрыть эскиз"
        $map["更新&保存"] = "Обновить и сохранить"
        $map["更新其它参考关系"] = "Обновить прочие ссылки"
        $map["更新内容：`r`n"] = "Что нового:`r`n"
        $map["更新参考关系"] = "Обновить ссылки"
        $map["更新参考关系..."] = "Обновление ссылок..."
        $map["更新参考关系失败！"] = "Не удалось обновить ссылки!"
        $map["更新日志"] = "Журнал изменений"
        $map["更新零部件单位"] = "Обновить единицы компонентов"
        $map["替换"] = "Заменить"
        $map["替换`"图纸格式`""] = "Заменить `"Формат чертежа`""
        $map["替换`"绘图标准`""] = "Заменить `"Стандарт оформления`""
        $map["替换为"] = "Заменить на"
        $map["替换为："] = "Заменить на:"
        $map["替换列表"] = "Список замен"
        $map["替换参考中..."] = "Замена ссылок..."
        $map["替换参考文件"] = "Заменить файл ссылки"
        $map["替换完成"] = "Замена выполнена"
        $map["最近使用"] = "Недавние"
        $map["有"] = "Есть"
        $map["有 "] = "Есть "
        $map["有效期至：永久使用`r`n"] = "Срок действия: бессрочно`r`n"
        $map["有无工程图"] = "Наличие чертежа"
        $map["未打开工程图"] = "Чертёж не открыт"
        $map["未找到字符`""] = "Символ не найден `""
        $map["未找到工程图"] = "Чертёж не найден"
        $map["未找到符合的项"] = "Совпадений не найдено"
        $map["未授权功能"] = "Функция недоступна без лицензии"
        $map["未检测到有效许可!"] = "Не обнаружена действующая лицензия!"
        $map["未激活的配置"] = "Неактивные конфигурации"
        $map["机器码：`r`n"] = "Код машины:`r`n"
        $map["材料"] = "Материал"
        $map["材质库文件不存在！请重新添加材质库。"] = "Файл библиотеки материалов не найден! Добавьте библиотеку заново."
        $map["材质数据库文件（*.sldmat）|*.sldmat"] = "База материалов (*.sldmat)|*.sldmat"
        $map["来生缘。。。"] = "Судьба следующей жизни..."
        $map["查找下一个"] = "Найти далее"
        $map["查找全部"] = "Найти все"
        $map["查找内容："] = "Что искать:"
        $map["查找和替换"] = "Найти и заменить"
        $map["查找填充"] = "Найти и заполнить"
        $map["查找填写"] = "Найти и заполнить"
        $map["查找范围："] = "Где искать:"
        $map["标签"] = "Метка"
        $map["标签："] = "Метка:"
        $map["标记没有工程图的项"] = "Отмечать элементы без чертежей"
        $map["标记相关节点"] = "Отметить связанные узлы"
        $map["标记相关节点（支持多选）"] = "Отметить связанные узлы (мультивыбор)"
        $map["楷体"] = "KaiTi"
        $map["正则表达式"] = "Регулярное выражение"
        $map["正则表达式语法"] = "Синтаксис регулярных выражений"
        $map["正在从磁盘打开文件"] = "Открытие файлов с диска"
        $map["正在保存文件"] = "Сохранение файлов"
        $map["正在创建工程图..."] = "Создание чертежей..."
        $map["正在同步工程图名称..."] = "Синхронизация имён чертежей..."
        $map["正在启动excel...."] = "Запуск Excel..."
        $map["正在导出数据...."] = "Экспорт данных..."
        $map["正在导出明细表...."] = "Экспорт спецификации..."
        $map["正在导出缩进式明"] = "Экспорт BOM с отступами"
        $map["正在打开excel...."] = "Открытие Excel..."
        $map["正在打开模板文件...."] = "Открытие шаблона..."
        $map["正在插入缩略图"] = "Вставка эскизов"
        $map["正在生成缩略图."] = "Создание эскизов."
        $map["正在解析模板文件...."] = "Разбор шаблона..."
        $map["正在解析零部件..."] = "Разбор компонентов..."
        $map["此文件夹"] = "Эта папка"
        $map["此注册码没有转出权限"] = "У этой лицензии нет права на перенос"
        $map["此电脑没有转出权限"] = "У этого компьютера нет права на перенос"
        $map["比例："] = "Масштаб:"
        $map["毫克"] = "мг"
        $map["毫升"] = "мл"
        $map["毫牛顿"] = "мН"
        $map["毫秒"] = "мс"
        $map["毫米"] = "мм"
        $map["毫米^3"] = "мм^3"
        $map["汇总"] = "Сводно"
        $map["没发现可下载的资源！"] = "Доступных для загрузки ресурсов не найдено!"
        $map["没有可备份的数据"] = "Нет данных для резервного копирования"
        $map["没有可导出的数据"] = "Нет данных для экспорта"
        $map["没有可打印的项"] = "Нет элементов для печати"
        $map["没有启动solidworks，是否现在启动？"] = "SolidWorks не запущен. Запустить сейчас?"
        $map["没有工程图，是否创建？"] = "Чертежа нет. Создать?"
        $map["没有找到匹配项！"] = "Совпадений не найдено!"
        $map["没有找到更新包！"] = "Пакет обновлений не найден!"
        $map["没有注册类，ProgID：`""] = "Класс не зарегистрирован, ProgID: `""
        $map["没有读取到有效数据"] = "Допустимые данные не прочитаны"
        $map["没有选择任何节点"] = "Не выбран ни один узел"
        $map["没有需处理的文件"] = "Нет файлов для обработки"
        $map["没有需处理的文件！"] = "Нет файлов для обработки!"
        $map["没有需要转换的项"] = "Нет элементов для конвертации"
        $map["波浪线 `"~`""] = "Тильда `"~`""
        $map["注册"] = "Регистрация"
        $map["注册信息"] = "Регистрационная информация"
        $map["注册信息保存错误"] = "Ошибка сохранения регистрации"
        $map["注册信息错误"] = "Ошибка регистрационных данных"
        $map["注册失败"] = "Регистрация не выполнена"
        $map["注册成功"] = "Регистрация выполнена"
        $map["注册申请失败"] = "Запрос регистрации не выполнен"
        $map["注册码已被其它电脑使用"] = "Лицензия уже используется другим компьютером"
        $map["注册码已过期"] = "Срок действия лицензии истёк"
        $map["注册码："] = "Ключ лицензии:"
        $map["派生配置"] = "Производная конфигурация"
        $map["浏览"] = "Обзор"
        $map["浏览.."] = "Обзор.."
        $map["浏览..."] = "Обзор..."
        $map["浏览Excel数据源"] = "Обзор источника Excel"
        $map["浏览Excel模板"] = "Обзор шаблона Excel"
        $map["消息"] = "Сообщение"
        $map["淘宝:"] = "Магазин:"
        $map["添加"] = "Добавить"
        $map["添加..."] = "Добавить..."
        $map["添加solidworks中已打开的零部件"] = "Добавить открытые в SolidWorks компоненты"
        $map["添加列"] = "Добавить столбец"
        $map["添加前后缀"] = "Добавить префикс/суффикс"
        $map["添加前缀:"] = "Добавить префикс:"
        $map["添加后缀:"] = "Добавить суффикс:"
        $map["添加文件"] = "Добавить файлы"
        $map["添加文件夹"] = "Добавить папку"
        $map["添加文件夹(包含子文件夹)"] = "Добавить папку (с подпапками)"
        $map["添加文件夹（包含子文件夹）"] = "Добавить папку (с подпапками)"
        $map["添加材质库..."] = "Добавить библиотеку материалов..."
        $map["添加目录"] = "Добавить каталог"
        $map["添加项"] = "Добавить элемент"
        $map["清空"] = "Очистить"
        $map["清空列表吗？"] = "Очистить список?"
        $map["清除"] = "Очистить"
        $map["清除内容"] = "Очистить содержимое"
        $map["清除筛选"] = "Снять фильтр"
        $map["清除颜色"] = "Сбросить цвет"
        $map["源工程图不存在或所在目录无权访问"] = "Исходный чертёж не существует или нет прав на каталог"
        $map["激活并保存此零部件..."] = "Активировать и сохранить компонент..."
        $map["激活并保存此零部件（支持多选）"] = "Активировать и сохранить компонент (мультивыбор)"
        $map["灰度级"] = "Оттенки серого"
        $map["点 `".`""] = "Точка `".`""
        $map["点此设置路径"] = "Нажмите для настройки пути"
        $map["焊件<按加工>"] = "Сварная конструкция <по обработке>"
        $map["焊件<按焊接>"] = "Сварная конструкция <по сварке>"
        $map["焦耳"] = "Дж"
        $map["版 本 :{0}"] = "Версия: {0}"
        $map["版本"] = "Версия"
        $map["版本`n2"] = "Версия`n2"
        $map["版本："] = "Версия:"
        $map["牛顿"] = "Н"
        $map["特别提醒！！！"] = "Внимание!!!"
        $map["状态"] = "Статус"
        $map["瓦"] = "Вт"
        $map["用户指定的名称"] = "Имя, заданное пользователем"
        $map["百宝箱"] = "Помощник"
        $map["盎司-力"] = "унция-сила"
        $map["目录不存在"] = "Каталог не существует"
        $map["目标程序不存在！"] = "Целевая программа не существует!"
        $map["直接导出"] = "Прямой экспорт"
        $map["短横线 `"-`""] = "Дефис `"-`""
        $map["确定"] = "OK"
        $map["确定(&O)"] = "OK (&O)"
        $map["确定清空列表吗？"] = "Очистить список?"
        $map["确认"] = "Подтвердить"
        $map["确认修改"] = "Подтвердить изменения"
        $map["磅"] = "фунт"
        $map["磅-力"] = "фунт-сила"
        $map["示例："] = "Пример:"
        $map["秒"] = "с"
        $map["秒，共"] = "с, всего"
        $map["移除选中"] = "Удалить выбранное"
        $map["空格"] = "Пробел"
        $map["空格或下横线"] = "Пробел или подчёркивание"
        $map["符号"] = "Символы"
        $map["笨小孩。。。"] = "Глупыш..."
        $map["第一列："] = "Первый столбец:"
        $map["第二列："] = "Второй столбец:"
        $map["等于"] = "Равно"
        $map["筛选"] = "Фильтр"
        $map["筛选（反向）"] = "Фильтр (инверсия)"
        $map["米"] = "м"
        $map["米^3"] = "м^3"
        $map["类型"] = "Тип"
        $map["粘贴"] = "Вставить"
        $map["粘贴到列："] = "Вставить в столбец:"
        $map["粘贴工程图"] = "Вставить чертёж"
        $map["纳秒"] = "нс"
        $map["纳米"] = "нм"
        $map["纳米^3"] = "нм^3"
        $map["纸张设置和打印范围"] = "Параметры бумаги и диапазон печати"
        $map["线条样式："] = "Стиль линии:"
        $map["结尾不是"] = "Не заканчивается на"
        $map["结尾是"] = "Заканчивается на"
        $map["结果："] = "Результат:"
        $map["绘图标准"] = "Стандарт оформления"
        $map["绘图标准文件`""] = "Файл стандарта оформления `""
        $map["绘图标准文件（*.sldstd）|*.sldstd"] = "Стандарт оформления (*.sldstd)|*.sldstd"
        $map["绘图标准（工程图）："] = "Стандарт (чертёж):"
        $map["绘图标准（装配体）："] = "Стандарт (сборка):"
        $map["绘图标准（零件）："] = "Стандарт (деталь):"
        $map["统一保存到文件夹"] = "Сохранить в общую папку"
        $map["继续任务"] = "Продолжить задачу"
        $map["缓存数据量："] = "Кэшировано:"
        $map["编辑"] = "Редактировать"
        $map["编辑规则"] = "Редактировать правило"
        $map["缩略图"] = "Эскиз"
        $map["缩略图大小："] = "Размер эскиза:"
        $map["缩进"] = "Отступ"
        $map["网站下载：www.z-tool.cn"] = ""
        $map["网络异常"] = "Ошибка сети"
        $map["网络设置"] = "Настройки сети"
        $map["能量"] = "Энергия"
        $map["自动"] = "Автоматически"
        $map["自动列宽"] = "Авторазмер столбца"
        $map["自定义"] = "Пользовательский"
        $map["自定义和所有配置"] = "Пользовательские и все конфигурации"
        $map["自定义填充"] = "Пользовательское заполнение"
        $map["自定义属性"] = "Пользовательские свойства"
        $map["自定义排序"] = "Пользовательская сортировка"
        $map["自定义菜单..."] = "Пользовательское меню..."
        $map["自定义规则"] = "Пользовательское правило"
        $map["英寸"] = "дюйм"
        $map["英寸^3"] = "дюйм^3"
        $map["英尺"] = "фут"
        $map["英尺^3"] = "фут^3"
        $map["英尺和英寸"] = "футы и дюймы"
        $map["行"] = "Строка"
        $map["表格列"] = "Столбец таблицы"
        $map["表面处理"] = "Обработка поверхности"
        $map["装配体"] = "Сборка"
        $map["装配体(*.SLDASM)|*."] = "Сборка (*.SLDASM)|*."
        $map["装配体（.SLDASM）"] = "Сборка (.SLDASM)"
        $map["覆盖同名文件"] = "Перезаписывать одноимённые файлы"
        $map["覆盖同名文件（需谨慎）"] = "Перезаписывать одноимённые файлы (осторожно)"
        $map["规则列表"] = "Список правил"
        $map["规则名称"] = "Имя правила"
        $map["规则填充"] = "Заполнение по правилам"
        $map["视图"] = "Вид"
        $map["角度"] = "Угол"
        $map["角度:"] = "Угол:"
        $map["解除压缩（&U）"] = "Вернуть (&U)"
        $map["设定颜色"] = "Задать цвет"
        $map["设置失败！"] = "Не удалось применить настройки!"
        $map["设置属性名称"] = "Задать имя свойства"
        $map["设置的SolidWorks版本不正确，请重新设置"] = "Указана неверная версия SolidWorks — задайте заново"
        $map["设计"] = "Проектирование"
        $map["设计日期"] = "Дата проектирования"
        $map["评估的值   "] = "Вычисленное значение   "
        $map["试用"] = "Триал"
        $map["试用中...剩余"] = "Триал... осталось"
        $map["试用时间到！软件将在10秒后自动关闭！"] = "Время триала закончилось! Программа закроется через 10 секунд!"
        $map["试用版不支持！"] = "Триал не поддерживает!"
        $map["询问"] = "Запрос"
        $map["该设备不具备注册条件！"] = "Этот компьютер не подходит для регистрации!"
        $map["详细列表"] = "Подробный список"
        $map["说明"] = "Описание"
        $map["说明：`r`n{ }内的为增量起始值;`r`n`$属性名称`$---引用属性值`r`n%属性名称%---引用属性表达式`r`n<列标题>---引用其它列的值`r`n"] = "Описание:`r`n{ } — начальное значение шага;`r`n`$ИмяСвойства`$ — значение свойства`r`n%ИмяСвойства% — выражение свойства`r`n<ЗаголовокСтолбца> — значение другого столбца`r`n"
        $map["说明：`r`n{ }内的为流水号初始值;`r`n`$列标题`$---引用属性列评估的值`r`n%列标题%---引用属性列表达式`r`n<列标题>---引用其它列的值`r`n"] = "Описание:`r`n{ } — начальное значение номера;`r`n`$ЗаголовокСтолбца`$ — вычисленное значение столбца`r`n%ЗаголовокСтолбца% — выражение столбца`r`n<ЗаголовокСтолбца> — значение другого столбца`r`n"
        $map["请先在solidworks选项中设置默认工程图模板"] = "Сначала задайте шаблон чертежа в параметрах SolidWorks"
        $map["请先打开solidworks"] = "Сначала запустите SolidWorks"
        $map["请先添加列"] = "Сначала добавьте столбец"
        $map["请先设置Bom模板"] = "Сначала задайте шаблон BOM"
        $map["请先设置参考路径"] = "Сначала задайте путь ссылки"
        $map["请先设置图纸格式所在文件夹"] = "Сначала задайте папку форматов чертежа"
        $map["请先设置重命名后旧文件的移动路径"] = "Сначала задайте путь перемещения старых файлов"
        $map["请关闭solidworks中打开的所有文件!`n`n自动关闭solidworks中打开的所有文件？"] = "Закройте все открытые в SolidWorks файлы!`n`nЗакрыть автоматически?"
        $map["请关闭solidworks中打开的所有文件，以免造成读取错误!`n`n自动关闭solidworks中打开的所有文件？"] = "Закройте все открытые в SolidWorks файлы во избежание ошибок чтения!`n`nЗакрыть автоматически?"
        $map["请勾选需要打印的项"] = "Отметьте элементы для печати"
        $map["请确认是否删除？"] = "Подтвердите удаление"
        $map["请设置图纸格式"] = "Задайте формат чертежа"
        $map["请设置绘图标准"] = "Задайте стандарт оформления"
        $map["请设置输出格式"] = "Задайте формат вывода"
        $map["请设置输出路径"] = "Задайте путь вывода"
        $map["请输入8-20位包含大小写字母和数字的密码"] = "Введите 8-20 символов: заглавные, строчные и цифры"
        $map["请输入注册码"] = "Введите ключ лицензии"
        $map["请选择"] = "Выберите"
        $map["请选择两个不同的列"] = "Выберите два разных столбца"
        $map["请选择需要打印的图纸类型"] = "Выберите тип листов для печати"
        $map["读取SW数据出错：`n"] = "Ошибка чтения данных SW:`n"
        $map["读取规则"] = "Правило чтения"
        $map["调整比例以套合"] = "Подгонять масштаб"
        $map["质量"] = "Масса"
        $map["质量/截面属性"] = "Масса/сечение"
        $map["路径"] = "Путь"
        $map["路径 `""] = "Путь `""
        $map["路径不存在,是否创建?"] = "Путь не существует, создать?"
        $map["路径格式不合法"] = "Недопустимый формат пути"
        $map["路径："] = "Путь:"
        $map["跳过只读文件"] = "Пропускать файлы только для чтения"
        $map["跳过只读项"] = "Пропускать элементы только для чтения"
        $map["跳过未修改的项"] = "Пропускать неизменённые"
        $map["跳过没有失败的项"] = "Пропускать успешные"
        $map["跳过被筛选的项"] = "Пропускать отфильтрованные"
        $map["转出授权"] = "Перенести лицензию"
        $map["转出授权失败"] = "Перенос лицензии не выполнен"
        $map["转出授权成功"] = "Лицензия перенесена"
        $map["转换2D工程图为"] = "Конвертация 2D-чертежа в"
        $map["转换3D模型为"] = "Конвертация 3D-модели в"
        $map["输入方案名称"] = "Введите имя схемы"
        $map["输入规则名称"] = "Введите имя правила"
        $map["输出属性值"] = "Выводить значения свойств"
        $map["输出属性表达式"] = "Выводить выражения свойств"
        $map["输出所有图纸到一个文件"] = "Все листы в один файл"
        $map["输出所有图纸到单个文件"] = "Все листы в один файл"
        $map["输出所有工程图图纸到纸张空间"] = "Все листы чертежа в пространство листа"
        $map["输出文件名设置"] = "Настройки имени выходного файла"
        $map["输出文件夹"] = "Папка вывода"
        $map["输出格式"] = "Формат вывода"
        $map["输出路径"] = "Путь вывода"
        $map["输出选项"] = "Параметры вывода"
        $map["达因"] = "дин"
        $map["过滤规则"] = "Правило фильтра"
        $map["运动单位"] = "Единицы движения"
        $map["运行时隐藏SolidWorks界面"] = "Скрывать интерфейс SolidWorks во время работы"
        $map["连接solidworks失败"] = "Не удалось подключиться к SolidWorks"
        $map["连接solidworks总时间"] = "Общее время подключения к SolidWorks"
        $map["连接上次文档"] = "Подключить последний документ"
        $map["连接完成，耗时 "] = "Подключение завершено, время "
        $map["连接当前文档"] = "Подключить текущий документ"
        $map["连接服务器中..."] = "Подключение к серверу..."
        $map["连接服务器出错"] = "Ошибка подключения к серверу"
        $map["连接服务器失败！"] = "Не удалось подключиться к серверу!"
        $map["连接服务器超时"] = "Превышено время подключения к серверу"
        $map["连接超时"] = "Превышено время ожидания"
        $map["适用于缩略图不显"] = "Если эскиз не отображается"
        $map["选择列："] = "Выберите столбец:"
        $map["选择可用材质库..."] = "Выберите доступную библиотеку материалов..."
        $map["选择需填充的列："] = "Выберите столбец для заполнения:"
        $map["选择需要加载的文件类型"] = "Выберите типы файлов для загрузки"
        $map["选项"] = "Опции"
        $map["透明度:"] = "Прозрачность:"
        $map["配置BOM方案"] = "Настроить схему BOM"
        $map["配置名称"] = "Имя конфигурации"
        $map["配置文件(*.settings)"] = "Конфигурация (*.settings)"
        $map["配置文件（*settings）|*.settings"] = "Конфигурация (*.settings)|*.settings"
        $map["重命名"] = "Переименовать"
        $map["重命名后旧文件移动到"] = "Перемещать старые файлы после переименования в"
        $map["重命名设置"] = "Настройки переименования"
        $map["重新开始"] = "Начать заново"
        $map["重新获取数据？"] = "Перечитать данные?"
        $map["重置文件名"] = "Сбросить имя файла"
        $map["重置文件夹"] = "Сбросить папку"
        $map["重置颜色"] = "Сбросить цвет"
        $map["重量"] = "Вес"
        $map["钣金展开配置"] = "Конфигурация развёртки листового металла"
        $map["链接到父配置"] = "Ссылка на родительскую конфигурацию"
        $map["锁定纵横比（原始比例4：3）"] = "Сохранять пропорции (исходные 4:3)"
        $map["错误"] = "Ошибка"
        $map["长度"] = "Длина"
        $map["降序"] = "По убыванию"
        $map["随机颜色"] = "Случайный цвет"
        $map["随行显示"] = "В строку"
        $map["隐藏"] = "Скрыть"
        $map["隐藏悬空注解和尺寸"] = "Скрыть висячие аннотации и размеры"
        $map["隐藏行（支持多选） (&H）"] = "Скрыть строки (мультивыбор) (&H)"
        $map["零件"] = "Деталь"
        $map["零件(*.SLDPRT)|*.S"] = "Деталь (*.SLDPRT)|*.S"
        $map["零件名称"] = "Имя детали"
        $map["零件名称`n1"] = "Имя детали`n1"
        $map["零件配置"] = "Конфигурация детали"
        $map["零件（.SLDPRT）"] = "Деталь (.SLDPRT)"
        $map["零部件汇总"] = "Сводка компонентов"
        $map["需先打开"] = "Сначала откройте"
        $map["需更新的文件夹："] = "Папки для обновления:"
        $map["页面自动旋转方向"] = "Автоповорот страницы"
        $map["页面设置"] = "Параметры страницы"
        $map["顶级BOM"] = "BOM верхнего уровня"
        $map["项"] = "элем."
        $map["项。"] = "элементов."
        $map["项保存失败"] = "элементов не сохранено"
        $map["颜色/灰度级"] = "Цвет/оттенки серого"
        $map["马力"] = "л.с."
        $map["高品质"] = "Высокое качество"
        $map["高度："] = "Высота:"
        $map["黑白"] = "Чёрно-белое"
        $map["黑白（双层）"] = "Чёрно-белое (двухслойное)"
        $map["默认"] = "По умолчанию"
        $map["默认导出汇总BOM"] = "По умолчанию экспортировать сводную BOM"
        $map["（x64） 注册$([char]0x1e)$([char]0x1c)"] = "(x64) Регистрация"
        $map["（x86） 注册$([char]0x1e)$([char]0x1c)"] = "(x86) Регистрация"
        # Strings extracted from payload .resources files (Frmmain/FrmOptions/Resources)
        $map["API接口测速"] = "Тест скорости API"
        $map["BOM零件号"] = "Номер детали в BOM"
        $map["SolidWorks版本："] = "Версия SolidWorks:"
        $map["Windows默认"] = "Windows по умолчанию"
        $map["下拉列表："] = "Выпадающий список:"
        $map["保存到文件夹"] = "Сохранить в папку"
        $map["保存时间"] = "Время сохранения"
        $map["列标题："] = "Заголовок столбца:"
        $map["创建时间"] = "Время создания"
        $map["创建桌面快捷方式"] = "Ярлык на рабочем столе"
        $map["初始化表格"] = "Инициализировать таблицу"
        $map["单重(Kg)"] = "Масса (кг)"
        $map["单重_Kg"] = "Масса_кг"
        $map["双击图标在SOLIDWORKS中打开零部件或工程图"] = "Двойной щелчок: открыть деталь/чертёж в SOLIDWORKS"
        $map["启动时检查更新"] = "Проверять обновления при запуске"
        $map["在左侧选中属性列，在右侧添加该列的下拉 数据，每行一个。"] = "Выберите столбец свойств слева, добавьте варианты в выпадающий список справа (по одному на строку)."
        $map["复选框"] = "Флажок"
        $map["外形尺寸"] = "Габариты"
        $map["宏列表"] = "Список макросов"
        $map["实时筛选"] = "Фильтр в реальном времени"
        $map["将此材质库添加到solidworks"] = "Добавить эту библиотеку материалов в SolidWorks"
        $map["展开所有"] = "Развернуть всё"
        $map["折叠所有"] = "Свернуть всё"
        $map["展开材质列表到同一级"] = "Развернуть список материалов до одного уровня"
        $map["工程图"] = "Чертёж"
        $map["常规"] = "Общие"
        $map["所选行高亮显示："] = "Подсветка выбранных строк:"
        $map["打开插件根目录"] = "Открыть папку плагина"
        $map["打开日志文件路径"] = "Открыть путь к файлу журнала"
        $map["打开默认目录"] = "Открыть папку по умолчанию"
        $map["批量工具开启文件预览"] = "Включить предпросмотр файлов в пакетных инструментах"
        $map["批量工具操作时隐藏SolidWorks界面"] = "Скрывать окно SolidWorks при пакетной обработке"
        $map["批量缩略图方案："] = "Схема пакетных эскизов:"
        $map["插入缩略图时将其保存到:"] = "При вставке эскиза сохранять в:"
        $map["搜索已添加到solidworks的材质库"] = "Искать в добавленных в SolidWorks библиотеках материалов"
        $map["摘要_主题"] = "Сводка_тема"
        $map["摘要_作者"] = "Сводка_автор"
        $map["摘要_关键字"] = "Сводка_ключ. слова"
        $map["摘要_备注"] = "Сводка_комментарии"
        $map["摘要_标题"] = "Сводка_заголовок"
        $map["文档类型"] = "Тип документа"
        $map["材质"] = "Материал"
        $map["浏览材质库"] = "Обзор библиотеки материалов"
        $map["磁盘文件名"] = "Имя файла на диске"
        $map["统计数量"] = "Количество"
        $map["缩略图快捷键："] = "Горячие клавиши эскизов:"
        $map["自定义下拉"] = "Свой выпадающий список"
        $map["自定义材质文件："] = "Свой файл материалов:"
        $map["读取每一个配置的属性（仅对零件有效）"] = "Читать свойства каждой конфигурации (только для деталей)"
        $map["配置"] = "Конфигурация"
        $map["重新连接SW后清除筛选"] = "Сбрасывать фильтр при переподключении SW"
        $map["重置缩略图位置"] = "Сбросить положение эскизов"
        $map["零部件目录"] = "Папка компонентов"
        $map["高清模式"] = "Режим высокой чёткости"
        $map["默认目录"] = "Папка по умолчанию"
        $map["默认设置"] = "Настройки по умолчанию"
        $map["不包括在材料明细表中（&E）(支持多选)"] = "Не включать в спецификацию (&E) (поддерживается множественный выбор)"
        $map["包含在材料明细表中（&I）(支持多选)"] = "Включать в спецификацию (&I) (поддерживается множественный выбор)"
        $map["压缩零部件（&S）(支持多选)"] = "Погасить компонент (&S) (поддерживается множественный выбор)"
        $map["解除压缩（&U）(支持多选)"] = "Снять погашение (&U) (поддерживается множественный выбор)"
        $map["只显示该节点及其子项"] = "Показывать только этот узел и его потомков"
        $map["只显示该节点的子项"] = "Показывать только потомков этого узла"
        $map["只显示该节点的顶层子项"] = "Показывать только верхний уровень потомков этого узла"
        $map["隐藏该节点 （支持多选）"] = "Скрыть этот узел (поддерживается множественный выбор)"
        $map["隐藏该节点的子项（支持多选）"] = "Скрыть потомков этого узла (поддерживается множественный выбор)"
        # Additional payload ldstr strings discovered in re-audit (uncovered after PR #4)
        $map["试用版最多支持10个文件"] = "Демо-версия поддерживает не более 10 файлов"
        $map["PDF文件(*.pdf)|*.pdf"] = "PDF-файл (*.pdf)|*.pdf"
        $map["3D模型排除以下配置"] = "Исключить следующие конфигурации из 3D-модели"
        $map["3D转换文件名自定义："] = "Имя файла при конвертации 3D:"
        $map["2D转换文件名自定义："] = "Имя файла при конвертации 2D:"
        $map["工程图转换PDF后为其添加图片水印"] = "Добавить графический водяной знак после конвертации чертежа в PDF"
        $map["工程图转换PDF后为其添加文本水印"] = "Добавить текстовый водяной знак после конвертации чертежа в PDF"
        $map["工程图(*.SLDDRW)|*.SLDDRW"] = "Чертёж (*.SLDDRW)|*.SLDDRW"
        $map["工程图(*.SLDDRW)|*.SLDDRW|零件(*.SLDPRT)|*.SLDPRT|装配体(*.SLDASM)|*.SLDASM|SOLIDWORKS文件(*.SLDPRT;*.SLDASM;*.SLDDRW)|*.SLDPRT;*.SLDASM;*.SLDDRW"] = "Чертёж (*.SLDDRW)|*.SLDDRW|Деталь (*.SLDPRT)|*.SLDPRT|Сборка (*.SLDASM)|*.SLDASM|Файлы SOLIDWORKS (*.SLDPRT;*.SLDASM;*.SLDDRW)|*.SLDPRT;*.SLDASM;*.SLDDRW"
        $map["装配体(*.SLDASM)|*.SLDASM"] = "Сборка (*.SLDASM)|*.SLDASM"
        $map["零件(*.SLDPRT)|*.SLDPRT|装配体(*.SLDASM)|*.SLDASM"] = "Деталь (*.SLDPRT)|*.SLDPRT|Сборка (*.SLDASM)|*.SLDASM"
        $map["零件(*.SLDPRT)|*.SLDPRT|装配体(*.SLDASM)|*.SLDASM|SOLIDWORKS文件(*.SLDPRT;*.SLDASM)|*.SLDPRT;*.SLDASM"] = "Деталь (*.SLDPRT)|*.SLDPRT|Сборка (*.SLDASM)|*.SLDASM|Файлы SOLIDWORKS (*.SLDPRT;*.SLDASM)|*.SLDPRT;*.SLDASM"
        $map["SOLIDWORKS文件(*.SLDPRT;*.SLDASM)|*.SLDPRT;*.SLDASM|SOLIDWORKS零件(*.SLDPRT)|*.SLDPRT|SOLIDWORKS装配体(*.SLDASM)|*.SLDASM"] = "Файлы SOLIDWORKS (*.SLDPRT;*.SLDASM)|*.SLDPRT;*.SLDASM|Деталь SOLIDWORKS (*.SLDPRT)|*.SLDPRT|Сборка SOLIDWORKS (*.SLDASM)|*.SLDASM"
        $map["配置文件(*.settings)|*.settings"] = "Файл настроек (*.settings)|*.settings"
        $map["属性模板(*.prtprp;*.asmprp)|*.prtprp;*.asmprp"] = "Шаблон свойств (*.prtprp;*.asmprp)|*.prtprp;*.asmprp"
        $map["修改ToolStripMenuItem"] = "Изменить пункт меню"
        $map["替换后的零部件移动到"] = "Переместить заменённый компонент в"
        $map["请设置替换后原文件移动路径"] = "Укажите путь для перемещения исходного файла после замены"
        $map["替换图纸格式和绘图标准"] = "Заменить формат чертежа и стандарт"
        $map["`"已存在，请换一个名称"] = "`" уже существует, выберите другое имя"
        $map["选中行表头，按del键可以删除整行；`r`n多个值之间可以用英文分号分隔；"] = "Выделите заголовок строки и нажмите Del, чтобы удалить всю строку;`r`nнесколько значений можно разделять английской точкой с запятой;"
        $map["压缩零部件（&S）"] = "Свернуть компонент (&S)"
        $map["适用于缩略图不显示或其它需要保存的零部件"] = "Применимо к компонентам с неотображаемой миниатюрой или требующим сохранения"
        $map["没找到工程图模板！"] = "Шаблон чертежа не найден!"
        $map[") (在明细表中解散)"] = ") (разобрать в спецификации)"
        $map[") (在明细表中隐藏子项)"] = ") (скрыть потомков в спецификации)"
        $map[") (不包含在明细表中)"] = ") (исключить из спецификации)"
        $map["正在生成缩略图...."] = "Создаются миниатюры...."
        $map["正在导出缩进式明细表...."] = "Экспорт ступенчатой спецификации...."
        $map["/进阶操作/缩略图显示及操作.htm"] = "/Расширенные операции/Отображение и работа с миниатюрами.htm"
        $map["授权保护密码(在激活时可设置密码，转出授权后密码自动清除):"] = "Пароль защиты лицензии (задаётся при активации, очищается автоматически после переноса):"
        $map["修改属性后自动保存"] = "Автосохранение после изменения свойств"
        $map["/基本操作/保存数据到SolidWorks.htm"] = "/Базовые операции/Сохранение данных в SolidWorks.htm"
        $map["MKS(米、千克、秒)"] = "MKS (метр, килограмм, секунда)"
        $map["双击行自动填写到主界面，按del键可以删除选中行。"] = "Двойной щелчок по строке переносит её в главное окно; Del удаляет выделенную строку."
        $map["未找到SolidWorks"] = "SolidWorks не найден"
        $map["授权电脑数量已达上限"] = "Достигнут лимит количества компьютеров для лицензии"
        $map["注：更新保存以及3D模型转jpg、png、3D PDF、igs、step和stl格式`r`n时无效"] = "Примечание: не применяется при сохранении обновлений и при конвертации 3D-модели в jpg, png, 3D PDF, igs, step или stl."
        # ZTool.Init.exe (initialization helper) strings
        $map["ZTool初始化"] = "Инициализация ZTool"
        $map["加载成功"] = "Загружено успешно"
        $map["卸载成功"] = "Выгружено успешно"
        $map["加载到SolidWorks菜单"] = "Загрузить в меню SolidWorks"
        $map["从SolidWorks菜单卸载"] = "Выгрузить из меню SolidWorks"
        $map["加载成功,请重启SolidWorks！"] = "Загружено успешно, перезапустите SolidWorks!"
        $map["卸载成功,下次启动SolidWorks时将不再加载"] = "Выгружено успешно; при следующем запуске SolidWorks загружаться не будет"
        $map["嵌入SolidWorks菜单"] = "Интеграция с меню SolidWorks"
        # ResourceManager base name used by ZTool.Init.exe (matches renamed resource ZTool.Init.Resources.resources)
        $map["ZTool初始化.Resources"] = "ZTool.Init.Resources"
    } else {
        $map["`t统计数量"] = "`tQuantity"
        $map[" (属性值)"] = " (Property Value)"
        $map[" (属性表达式)"] = " (Property Expression)"
        $map[" (表达式)"] = " (Expression)"
        $map[" 不存在"] = " does not exist"
        $map[" 不存在，请重新设置"] = " does not exist, please set again"
        $map[" 与 "] = " and "
        $map[" 个"] = " items"
        $map[" 保存选项"] = " Save Options"
        $map[" 失败！"] = " failed!"
        $map[" 已存在！"] = " already exists!"
        $map[" 已存在，是否自动递增流水号？"] = " already exists. Auto-increment serial number?"
        $map[" 打开失败！"] = " failed to open!"
        $map[" 批量转换格式"] = " Batch Convert Format"
        $map[" 文件不存在！"] = " file does not exist!"
        $map[" 条记录中找到 "] = " records, found "
        $map[" 的行磁盘文件名重复，填写失败！"] = " rows have duplicate disk filenames; fill failed!"
        $map[" 秒"] = " sec"
        $map[" 秒， 共 "] = " sec, total "
        $map[" 秒，共 "] = " sec, total "
        $map[" 行"] = " rows"
        $map[" 路径不存在！"] = " path does not exist!"
        $map[" 页"] = " pages"
        $map[" 页被合并"] = " pages merged"
        $map[" 项"] = " items"
        $map[" 项因文件名重复，替换失败"] = " items have duplicate names; replace failed"
        $map[" 项被找到"] = " items found"
        $map[" 项，填写 "] = " items, fill "
        $map["`" 不存在,是否创建?"] = "`" does not exist. Create?"
        $map["`" 更新参考关系失败！"] = "`" Update references failed!"
        $map["`" 目录下没有找到后缀名为 `".slddrt`" 的图纸格式文件"] = "`" — no drawing format files (*.slddrt) found in directory"
        $map["`" 目录不存在！"] = "`" directory does not exist!"
        $map["`"ZTool Updater.exe`" 缺失！无法启动更新程序！"] = "`"ZTool Updater.exe`" missing! Cannot launch updater!"
        $map["`"ZToolARM.dll`"丢失"] = "`"ZToolARM.dll`" missing"
        $map["`"为重复的属性名称"] = "`" — duplicate property name"
        $map["`"列中清除筛选"] = "`" — clear filter on column"
        $map["`"找不到"] = "`" not found"
        # Note: $DN$ / $NAME$ / <conf> / <file_> / $Rev are length-equal byte
        # patches in ZTool.dll's Constant.Value blob (see Get-ZToolDllCjkPatches in
        # Disable-ZToolEmbeddedUpdates.ps1). Payload composites MUST use the same
        # short tokens so payload-side template parsing matches ZTool.dll constants.
        $map["`$图号`$ `$名称`$ `$类型`$"] = "`$DN`$ `$Name`$ `$Type`$"
        $map["`$图号`$-`$零件名称`$-{001}"] = "`$DN`$-`$NAME`$-{001}"
        $map["`$图号`$"] = "`$DN`$"
        $map["`$零件名称`$"] = "`$NAME`$"
        $map["`$版本`$"] = "`$Rev"
        $map["<磁盘文件名>"] = "<file_>"
        $map["`$类型`$-<文件名称>-<当前日期>"] = "`$Type`$-<FileName>-<CurrentDate>"
        $map["(全选)"] = "(Select All)"
        $map[") (不包含在明"] = ") (Excluded from BOM"
        $map[") (在明细表中"] = ") (In BOM"
        $map["-当映射名称为空时或与列标题相同时，该列不启用映射；`r`n-应保证映射名称与Excel模板中的自定义名称相等；`r`n-列标题映射主要用于解决Excel模板的自定义名称语法问题，以及列标题重`r`n复导致导出bom数据错乱的问题；"] = "- If the mapping name is empty or matches the column header, mapping is disabled for that column;`r`n- The mapping name must equal the custom name in the Excel template;`r`n- Column header mapping resolves Excel template custom-name syntax issues and BOM export errors caused by duplicate headers;"
        $map["/进阶操作/BOM表模板制作和导出.htm"] = "/advanced/bom-template-and-export.htm"
        $map["/进阶操作/缩略"] = "/advanced/thumbnail"
        $map["<主题>"] = "<Subject>"
        $map["<作者>"] = "<Author>"
        $map["<关键字>"] = "<Keywords>"
        $map["<备注>"] = "<Comments>"
        $map["<当前日期>"] = "<CurrentDate>"
        $map["<文件名称>"] = "<FileName>"
        $map["<文件夹名称>"] = "<FolderName>"
        $map["<文件类型>"] = "<FileType>"
        $map["<有无工程图>"] = "<HasDrawing>"
        $map["<材质>"] = "<Material>"
        $map["<标题>"] = "<Title>"
        $map["<模型文件名称>"] = "<ModelFileName>"
        $map["<模型文件夹名称>"] = "<ModelFolderName>"
        $map["<统计数量>"] = "<Quantity>"
        $map["<配置名称>"] = "<conf>"
        $map["A4横"] = "A4 Landscape"
        $map["A4竖"] = "A4 Portrait"
        $map["Application UnhandledException:{0};`n`r堆栈信息:{1}"] = "Application UnhandledException:{0};`n`rStack:{1}"
        $map["AutoCAD标准样式"] = "AutoCAD Standard Style"
        $map["BOM报表"] = "BOM Report"
        $map["BOM报表 【"] = "BOM Report 【"
        $map["BOM方案"] = "BOM Scheme"
        $map["BOM模板:"] = "BOM Template:"
        $map["BOM模板文件夹："] = "BOM Templates Folder:"
        $map["BOM模板文件（*.xls;*.xlsx）|*.xls;*.xlsx"] = "BOM Template (*.xls;*.xlsx)|*.xls;*.xlsx"
        $map["BOM类型"] = "BOM Type"
        $map["BOM表模板"] = "BOM Template"
        $map["CGS(厘米、克、秒)"] = "CGS (cm, g, s)"
        $map["DXF/DWG输出选项"] = "DXF/DWG Export Options"
        $map["Excel 工作簿（*"] = "Excel Workbook (*"
        $map["Excel 工作簿（*xlsx）|*.xlsx|Excel 97-2003工作簿（*xls）|*.xls"] = "Excel Workbook (*.xlsx)|*.xlsx|Excel 97-2003 Workbook (*.xls)|*.xls"
        $map["Excel 文件（*.xls;*.xlsx）|*.xls;*.xlsx"] = "Excel File (*.xls;*.xlsx)|*.xls;*.xlsx"
        $map["ID001-轴承座-001"] = "ID001-Bearing-001"
        $map["ID010-轴承座-010"] = "ID010-Bearing-010"
        $map["IPS(英寸、磅、秒)"] = "IPS (inch, lb, s)"
        $map["JPG/PNG输出选项"] = "JPG/PNG Export Options"
        $map["MMGS(毫米、克、秒)"] = "MMGS (mm, g, s)"
        $map["MMKS(毫米、千克、秒)"] = "MMKS (mm, kg, s)"
        $map["PDF文件(*.pdf)|*.p"] = "PDF File (*.pdf)|*.p"
        $map["PDF水印"] = "PDF Watermark"
        $map["PDF输出选项"] = "PDF Export Options"
        $map["PowerShell 执行失败 (ExitCode: "] = "PowerShell execution failed (ExitCode: "
        $map["Q Q群: 823539419"] = ""
        $map["QQ群"] = ""
        $map["QQ群:"] = ""
        $map["RGB全色"] = "RGB Full Color"
        $map["SOLIDWORKS文件(*.SLDPRT;*.SLDASM)|"] = "SOLIDWORKS Files (*.SLDPRT;*.SLDASM)|"
        $map["SW-上次保存的日期(Last Saved Date)"] = "SW-Last Saved Date"
        $map["SW-上次保存者(Last Saved By)"] = "SW-Last Saved By"
        $map["SW-主题(Subject)"] = "SW-Subject"
        $map["SW-体积"] = "SW-Volume"
        $map["SW-作者(Author)"] = "SW-Author"
        $map["SW-关键词(Keywords)"] = "SW-Keywords"
        $map["SW-密度"] = "SW-Density"
        $map["SW-文件名称(File Name)"] = "SW-File Name"
        $map["SW-文件夹名称(Folder Name)"] = "SW-Folder Name"
        $map["SW-材质"] = "SW-Material"
        $map["SW-标题 (Title)"] = "SW-Title"
        $map["SW-生成的日期(Created Date)"] = "SW-Created Date"
        $map["SW-表面积"] = "SW-Surface Area"
        $map["SW-评述(Comments)"] = "SW-Comments"
        $map["SW-质量"] = "SW-Mass"
        $map["SW-配置名称(Configuration Name)"] = "SW-Configuration Name"
        $map["SW属性"] = "SW Properties"
        $map["SW模板"] = "SW Template"
        $map["SolidWorks中没有打开文件,请先打开文件"] = "No files open in SolidWorks. Please open a file first."
        $map["SolidWorks当前活动的文档可能未保存，请先保存"] = "Current active SolidWorks document may not be saved. Please save first."
        $map["SolidWorks自定义样式"] = "SolidWorks Custom Style"
        $map["SolidWorks高效辅助工具`n批量重命名、编辑属性、打印、转图、生成bom等"] = "SolidWorks Productivity Helper`nBatch rename, edit properties, print, convert, BOM, etc."
        $map["SpeedPak配置"] = "SpeedPak Configuration"
        $map["ZTool检测更新"] = "Check for Updates"
        $map["\BOM表模板"] = "\BOM Templates"
        $map["\BOM表模板\bom模板.xlsx"] = "\BOM Templates\bom-template.xlsx"
        $map["bom数据（*txt）|*.txt"] = "BOM Data (*.txt)|*.txt"
        $map["help.chm文件没找到"] = "help.chm file not found"
        $map["oShellLink.Description =`"SolidWorks高效辅助工具`" "] = "oShellLink.Description =`"SolidWorks Productivity Helper`" "
        $map["pdf文件（*.pdf）|*.pdf"] = "PDF (*.pdf)|*.pdf"
        $map["solidworks启动失败"] = "Failed to start SolidWorks"
        $map["solidworks宏文件（*.swb;*.swp）|*.swb;*.swp"] = "SolidWorks Macros (*.swb;*.swp)|*.swb;*.swp"
        $map["一生何求"] = ""
        $map["上移"] = "Move Up"
        $map["下一步"] = "Next"
        $map["下横线 `"_`""] = "Underscore `"_`""
        $map["下移"] = "Move Down"
        $map["下载失败："] = "Download failed:"
        $map["下载完毕！是否立即安装更新？`n注：安装前会关闭主程序和SolidWorks进程，请注意保存数据！"] = "Download complete. Install update now?`nNote: program and SolidWorks process will be closed before install — save your data!"
        $map["下载更新"] = "Download Update"
        $map["不做处理"] = "No action"
        $map["不包含"] = "Does not contain"
        $map["不包括在材料明细表中（&E）"] = "Exclude from BOM (&E)"
        $map["不处理"] = "Do not process"
        $map["不存在,是否创建？"] = "Does not exist. Create?"
        $map["不存在！"] = "Does not exist!"
        $map["不支持Win32s."] = "Win32s not supported."
        $map["不支持Win9x."] = "Win9x not supported."
        $map["不支持WinCE."] = "WinCE not supported."
        $map["不支持当前活动文档"] = "Active document not supported"
        $map["不是有效的宏文件"] = "Not a valid macro file"
        $map["不知道的操作系统."] = "Unknown OS."
        $map["不符合同步条件"] = "Does not meet sync conditions"
        $map["不等于"] = "Not equal"
        $map["与"] = "and"
        $map["与原文件夹相同"] = "Same as source folder"
        $map["与服务器通信异常"] = "Server communication error"
        $map["与装配体相同"] = "Same as assembly"
        $map["个同名文件"] = " files with same name"
        $map["个文件"] = " files"
        $map["个文件，勾选了"] = " files, checked"
        $map["中文字符"] = "Chinese characters"
        $map["主页:"] = "Site:"
        $map["二维码"] = "QR Code"
        $map["互换列"] = "Swap Columns"
        $map["亲！确定清空列表吗？"] = "Clear the list?"
        $map["仅输出激活的图纸"] = "Only output active sheets"
        $map["仅输出第一页"] = "Only output first page"
        $map["仅限于AutoCAD标准"] = "AutoCAD standard only"
        $map["仅限单列操作"] = "Single-column only"
        $map["仅限有工程图的项"] = "Only items with drawings"
        $map["仅限零件"] = "Parts only"
        $map["仅限顶层"] = "Top level only"
        $map["今天。。。"] = "Today..."
        $map["从`""] = "From `""
        $map["从solidworks中已打开的零部件中获取"] = "Get from components open in SolidWorks"
        $map["从solidworks属性模板中获取"] = "Get from SolidWorks property template"
        $map["从主界面导入"] = "Import from main window"
        $map["从文件中获取"] = "Get from file"
        $map["从文件夹中获取"] = "Get from folder"
        $map["从第"] = "From position"
        $map["从第10位开始向后取10位"] = "From position 10, take 10 chars"
        $map["从第10位开始向后取至结尾"] = "From position 10 to end"
        $map["从第10位开始向后最少取10位，最大取20位"] = "From position 10, min 10, max 20 chars"
        $map["以免数据丢失`r`n是否在关闭文件前先保存？"] = "To prevent data loss,`r`nsave files before closing?"
        $map["以彩色输出"] = "Color output"
        $map["任务停止"] = "Task stopped"
        $map["任务取消"] = "Task cancelled"
        $map["任务完成"] = "Task complete"
        $map["任务正在停止"] = "Task is stopping"
        $map["使用指定的打印机线粗(文件、打印、线粗)"] = "Use printer line weights (File, Print, Line Weight)"
        $map["使用材质颜色"] = "Use material color"
        $map["使用说明"] = "Instructions"
        $map["保存全部"] = "Save All"
        $map["保存到SW"] = "Save to SW"
        $map["保存到SW过程出错：`n"] = "Error saving to SW:`n"
        $map["保存到新文件夹"] = "Save to new folder"
        $map["保存到："] = "Save to:"
        $map["保存合并后的PDF文件"] = "Save merged PDF"
        $map["保存完毕，建议重新获取数据！"] = "Saved. Recommended to reload data!"
        $map["保存完毕，耗时"] = "Saved, elapsed"
        $map["保留值为空的属性"] = "Keep properties with empty values"
        $map["信息"] = "Information"
        $map["修改"] = "Modify"
        $map["修改项"] = "Modified items"
        $map["倍率："] = "Scale:"
        $map["值"] = "Value"
        $map["停止"] = "Stop"
        $map["停止任务"] = "Stop Task"
        $map["兆牛顿"] = "MN"
        $map["先以此排序"] = "Sort first by"
        $map["克"] = "g"
        $map["全部"] = "All"
        $map["全部取消"] = "Deselect All"
        $map["全部展开"] = "Expand All"
        $map["全部替换"] = "Replace All"
        $map["全部选择"] = "Select All"
        $map["公斤"] = "kg"
        $map["共"] = "total"
        $map["共 "] = "total "
        $map["关于"] = "About"
        $map["关联填写"] = "Linked fill"
        $map["关闭文件中......"] = "Closing files..."
        $map["其他"] = "Other"
        $map["其它"] = "Other"
        $map["其它            "] = "Other            "
        $map["其它位置"] = "Other location"
        $map["再以此排序"] = "Then sort by"
        $map["冰雨。。。"] = "Ice Rain..."
        $map["准备读取SW数据时出错：`n"] = "Error preparing to read SW data:`n"
        $map["分"] = "min"
        $map["分割"] = "Split"
        $map["分割规则"] = "Split Rule"
        $map["分割规则："] = "Split Rule:"
        $map["分升"] = "dl"
        $map["分号 `";`""] = "Semicolon `";`""
        $map["分离的工程图(slddrw)"] = "Detached Drawings (slddrw)"
        $map["分类"] = "Category"
        $map["分辨率和比例"] = "Resolution and Scale"
        $map["列名称"] = "Column Name"
        $map["列数据对比"] = "Column Comparison"
        $map["列查找"] = "Column Search"
        $map["列标题"] = "Column Header"
        $map["列标题映射"] = "Column Header Mapping"
        $map["列表"] = "List"
        $map["列表ToolStripMenuItem"] = "ListToolStripMenuItem"
        $map["列表ToolStripMenuItem1"] = "ListToolStripMenuItem1"
        $map["列表中没有文件"] = "List is empty"
        $map["创建工程图"] = "Create Drawing"
        $map["创建工程图出错：`n"] = "Error creating drawing:`n"
        $map["创建工程图（支持多选）"] = "Create Drawing (multi-select)"
        $map["创建快捷方式失败！"] = "Failed to create shortcut!"
        $map["创建快捷方式失败：`r`n"] = "Failed to create shortcut:`r`n"
        $map["创建快捷方式失败：`r`n目标程序不存在！"] = "Failed to create shortcut:`r`nTarget program does not exist!"
        $map["创建规则"] = "Create Rule"
        $map["初始化"] = "Initialize"
        $map["删除"] = "Delete"
        $map["删除列"] = "Delete Column"
        $map["删除工程图（支持多选）"] = "Delete Drawing (multi-select)"
        $map["删除悬空注解和尺寸"] = "Delete dangling notes and dimensions"
        $map["删除材质"] = "Delete Material"
        $map["删除选中"] = "Delete Selected"
        $map["刷新数据"] = "Refresh Data"
        $map["刷新缩略图？"] = "Refresh thumbnails?"
        $map["前缀："] = "Prefix:"
        $map["剩余"] = "Remaining"
        $map["力"] = "Force"
        $map["力量"] = "Force"
        $map["加载solidworks中已打开的工程图"] = "Load drawings open in SolidWorks"
        $map["加载solidworks中已打开的所有文件"] = "Load all files open in SolidWorks"
        $map["加载solidworks中已打开的装配体"] = "Load assemblies open in SolidWorks"
        $map["加载solidworks中已打开的零件"] = "Load parts open in SolidWorks"
        $map["加载solidworks中已打开零件的工程图"] = "Load drawings of parts open in SolidWorks"
        $map["加载solidworks中激活的装配体"] = "Load active SolidWorks assembly"
        $map["加载solidworks当前项"] = "Load current SolidWorks item"
        $map["加载solidworks当前项及其工程图"] = "Load current item and its drawing"
        $map["加载主界面数据"] = "Load main window data"
        $map["加载完成,耗时 "] = "Load complete, elapsed "
        $map["加载当前装配体中已选中项的工程图"] = "Load drawings of selected items in current assembly"
        $map["加载当前装配体中所有零件的工程图"] = "Load drawings of all parts in current assembly"
        $map["加载当前装配体中有工程图的零件"] = "Load parts in current assembly that have drawings"
        $map["加载当前装配体中的所有零件"] = "Load all parts in current assembly"
        $map["加载当前装配体中的所有零件及其工程图"] = "Load all parts in current assembly and their drawings"
        $map["加载当前装配体中选中的项"] = "Load selected items in current assembly"
        $map["加载当前装配体中选中的项及其工程图"] = "Load selected items and their drawings"
        $map["加载当前装配体中选中的项的工程图"] = "Load drawings of selected items"
        $map["加载指定装配体中所有零件的工程图"] = "Load drawings of all parts in specified assembly"
        $map["加载指定装配体中的所有零件"] = "Load all parts in specified assembly"
        $map["加载指定装配体中的所有零件及其工程图"] = "Load all parts in specified assembly and their drawings"
        $map["加载指定装配体中的有工程图的零件"] = "Load parts in specified assembly that have drawings"
        $map["加载数据中，请稍后..."] = "Loading data, please wait..."
        $map["加载数据出错：`n"] = "Error loading data:`n"
        $map["加载装配体中选中的项"] = "Load selected items in assembly"
        $map["加载装配体中选中的项的工程图"] = "Load drawings of selected items in assembly"
        $map["包含"] = "Include"
        $map["包含3D零部件"] = "Include 3D components"
        $map["包含其它同名文件（多个项目用分号隔开，如：.pdf;.dwg）"] = "Include files with same name (multiple separated by `";`": .pdf;.dwg)"
        $map["包含在材料明细表中（&I）"] = "Include in BOM (&I)"
        $map["包含子文件夹"] = "Include subfolders"
        $map["包含子目录"] = "Include subdirectories"
        $map["包含工程图"] = "Include drawings"
        $map["包含最顶层"] = "Include top level"
        $map["包含符合项"] = "Include matches"
        $map["包含虚拟零件（此选项会将虚拟零件保存到外部）"] = "Include virtual parts (will be saved externally)"
        $map["匹配"] = "Match"
        $map["匹配 "] = "Match "
        $map["匹配规则"] = "Match Rule"
        $map["区分大小写"] = "Case sensitive"
        $map["千克-力"] = "kgf"
        $map["千分英寸"] = "mil"
        $map["千分英寸^3"] = "mil^3"
        $map["千牛顿"] = "kN"
        $map["千瓦"] = "kW"
        $map["千瓦-小时"] = "kWh"
        $map["升"] = "L"
        $map["升序"] = "Ascending"
        $map["华文行楷"] = "Italic"
        $map["单位"] = "Units"
        $map["单位体积"] = "Unit Volume"
        $map["单位系统"] = "Unit System"
        $map["单级BOM"] = "Single-Level BOM"
        $map["压缩零部件（&S"] = "Suppress Components (&S"
        $map["厘升"] = "cl"
        $map["厘米"] = "cm"
        $map["厘米^3"] = "cm^3"
        $map["原位置（新建属性在自定义）"] = "Original location (new props in Custom)"
        $map["原位置（新建属性在配置）"] = "Original location (new props in Config)"
        $map["原图大小"] = "Original size"
        $map["原文件夹名称："] = "Original folder name:"
        $map["原点:"] = "Origin:"
        $map["原配置名"] = "Original config name"
        $map["去设置"] = "Go to settings"
        $map["参考文件"] = "Reference file"
        $map["参考类型"] = "Reference type"
        $map["参考路径 "] = "Reference path "
        $map["双击输入当前装配体目录"] = "Double-click to enter current assembly directory"
        $map["双击选择需要连接的Solidworks进程"] = "Double-click to select SolidWorks process to connect"
        $map["双尺寸长度"] = "Dual-dim length"
        $map["反向选择"] = "Invert Selection"
        $map["发布日期："] = "Release date:"
        $map["发现新版本！`r`n"] = "New version available!`r`n"
        $map["取()内字符"] = "Extract chars in ()"
        $map["取_或空格到结尾"] = "From _ or space to end"
        $map["取中文字符"] = "Extract Chinese chars"
        $map["取前10位"] = "First 10 chars"
        $map["取后10位"] = "Last 10 chars"
        $map["取开头到_|(（[【空格或结尾之间的字符"] = "From start to _|(（[【space or end"
        $map["取消"] = "Cancel"
        $map["取类似V1.1的字符"] = "Extract V1.1 pattern"
        $map["取结尾处类似V1.1的字符"] = "Extract V1.1 pattern at end"
        $map["只保存修改项"] = "Save only modified"
        $map["只保存失败项"] = "Save only failed"
        $map["只对从主界面导入的工程图和选中项的工程图有效"] = "Only effective for drawings imported from main window and selected"
        $map["只导出一个配置时不附带配置名"] = "Skip config name when exporting single config"
        $map["只打印"] = "Print only"
        $map["只能选择一项"] = "Only one item can be selected"
        $map["右上"] = "Top Right"
        $map["右上角"] = "Upper-Right Corner"
        $map["右下"] = "Bottom Right"
        $map["右下角"] = "Lower-Right Corner"
        $map["合并PDF"] = "Merge PDF"
        $map["合并PDF-"] = "Merge PDF —"
        $map["合并和拆分PDF"] = "Merge and Split PDF"
        $map["合并完成"] = "Merge complete"
        $map["同步完成"] = "Sync complete"
        $map["同步工程图名称"] = "Sync Drawing Names"
        $map["名称"] = "Name"
        $map["名称`""] = "Name `""
        $map["名称已存在，序号："] = "Name exists, number:"
        $map["名称重复"] = "Duplicate name"
        $map["名称："] = "Name:"
        $map["后缀："] = "Suffix:"
        $map["否"] = "No"
        $map["启动Excel失败！"] = "Failed to start Excel!"
        $map["启用筛选"] = "Enable filter"
        $map["启用规则"] = "Enable rule"
        $map["回收站"] = "Recycle Bin"
        $map["图像类型："] = "Image type:"
        $map["图号"] = "Number"
        $map["图号`n0"] = "Number`n0"
        $map["图片"] = "Image"
        $map["图片位置"] = "Image position"
        $map["图片文件"] = "Image file"
        $map["图片文件（*.bmp;*.jpg;*.png）|*.bmp;*.jpg;*.png"] = "Images (*.bmp;*.jpg;*.png)|*.bmp;*.jpg;*.png"
        $map["图片路径："] = "Image path:"
        $map["图纸区域原点"] = "Sheet area origin"
        $map["图纸大小"] = "Sheet size"
        $map["图纸格式"] = "Sheet format"
        $map["图纸格式所在文件夹："] = "Sheet formats folder:"
        $map["图纸格式路径不存在，请重新设置"] = "Sheet format path does not exist — set again"
        $map["在 "] = "In "
        $map["在Solidworks中打开"] = "Open in SolidWorks"
        $map["在solidworks中打开"] = "Open in SolidWorks"
        $map["在solidworks中打开ToolStripMenuItem"] = "OpenInSolidWorksToolStripMenuItem"
        $map["在solidworks中选中"] = "Select in SolidWorks"
        $map["在使用为子装配体时子零部件的显示"] = "Component display when used as sub-assembly"
        $map["在文件夹中打开"] = "Open in folder"
        $map["在文件夹中打开ToolStripMenuItem"] = "OpenInFolderToolStripMenuItem"
        $map["在文件夹中显示"] = "Show in folder"
        $map["在文件夹中显示 (&F）"] = "Show in folder (&F)"
        $map["在材料明细表中使用时所显示的零件号："] = "Part number shown in BOM:"
        $map["在线激活"] = "Online Activation"
        $map["埃"] = "Å"
        $map["埃^3"] = "Å^3"
        $map["基本单位"] = "Base Unit"
        $map["填充内容："] = "Fill content:"
        $map["填充列"] = "Fill Column"
        $map["填充文件名"] = "Fill File Name"
        $map["填充方案"] = "Fill Scheme"
        $map["增量："] = "Step:"
        $map["备份-"] = "Backup-"
        $map["备份完成，耗时"] = "Backup complete, elapsed"
        $map["备份已取消"] = "Backup cancelled"
        $map["备注"] = "Comments"
        $map["复制"] = "Copy"
        $map["复制列"] = "Copy Column"
        $map["复制列："] = "Copy column:"
        $map["复制备份"] = "Copy backup"
        $map["复制失败！请检查源文件是否存在。"] = "Copy failed! Check that source file exists."
        $map["复制属性值"] = "Copy property value"
        $map["复制工程图"] = "Copy Drawing"
        $map["复制工程图出错：`n"] = "Error copying drawing:`n"
        $map["复制文件..."] = "Copying files..."
        $map["复制表格"] = "Copy table"
        $map["多个条件可用`"&`"或者`"|`"分割`n&：并且`n|：或者"] = "Multiple conditions separated by `"&`" or `"|`"`n&: AND`n|: OR"
        $map["多图纸工程图："] = "Multi-sheet drawing:"
        $map["多级BOM"] = "Multi-Level BOM"
        $map["大图标"] = "Large Icons"
        $map["天意。。。"] = "Destiny..."
        $map["字体"] = "Font"
        $map["字体："] = "Font:"
        $map["安装更新"] = "Install Update"
        $map["宋体"] = "SimSun"
        $map["宏文件 "] = "Macro file "
        $map["宏程序"] = "Macro"
        $map["宽度："] = "Width:"
        $map["密码格式不正确，请输入8-20位包含大小写字母和数字的密码"] = "Invalid password format. Enter 8-20 chars with uppercase, lowercase and digits"
        $map["密码错误"] = "Wrong password"
        $map["密耳"] = "mil"
        $map["密耳^3"] = "mil^3"
        $map["对满足自定义规则的项进行填充"] = "Fill items matching custom rules"
        $map["对选中的项执行solidworks宏程序"] = "Run SolidWorks macro on selected items"
        $map["导入..."] = "Import..."
        $map["导出BOM出错：`n"] = "Error exporting BOM:`n"
        $map["导出到excel"] = "Export to Excel"
        $map["导出到txt"] = "Export to TXT"
        $map["导出到txt出错：`n"] = "Error exporting to TXT:`n"
        $map["导出成功"] = "Export successful"
        $map["导出成功！是否打开？"] = "Export successful. Open?"
        $map["导出时标记没有工程图的项"] = "Mark items without drawings on export"
        $map["导出汇总BOM"] = "Export summary BOM"
        $map["导出缩进式BOM"] = "Export indented BOM"
        $map["导出零件汇总BOM"] = "Export parts summary BOM"
        $map["导出顶层BOM"] = "Export top-level BOM"
        $map["将第"] = "From position"
        $map["小图标"] = "Small Icons"
        $map["小图标ToolStripMenuItem"] = "SmallIconsToolStripMenuItem"
        $map["小数"] = "Decimal"
        $map["尔格"] = "erg"
        $map["层级"] = "Level"
        $map["层级`tpathname`tcfgname`tExcludeFromBOM`tIsEnvelope`tIsVirtual`tSelectName"] = "Level`tpathname`tcfgname`tExcludeFromBOM`tIsEnvelope`tIsVirtual`tSelectName"
        $map["层级数量"] = "Level Count"
        $map["屏幕捕获"] = "Screen Capture"
        $map["属性"] = "Property"
        $map["属性保存设置"] = "Property save settings"
        $map["属性名称"] = "Property name"
        $map["属性模板(*.prtprp;*.asmprp)|"] = "Property template (*.prtprp;*.asmprp)|"
        $map["属性表达式"] = "Property expression"
        $map["属性表达式/评估的值"] = "Property expression / evaluated value"
        $map["嵌入字体"] = "Embed Fonts"
        $map["工具箱.png"] = "toolbox.png"
        $map["工程图(*.SLDDRW)|*."] = "Drawing (*.SLDDRW)|*."
        $map["工程图已存在，是否打开？"] = "Drawing already exists. Open?"
        $map["工程图已存在，是否覆盖？"] = "Drawing already exists. Overwrite?"
        $map["工程图颜色"] = "Drawing color"
        $map["工程图（.SLDDRW）"] = "Drawing (.SLDDRW)"
        $map["左上"] = "Top Left"
        $map["左上角"] = "Upper-Left Corner"
        $map["左下"] = "Bottom Left"
        $map["左下角"] = "Lower-Left Corner"
        $map["已存在同名工程图"] = "Drawing with same name exists"
        $map["已成功复制 "] = "Successfully copied "
        $map["已选择 "] = "Selected "
        $map["帮助"] = "Help"
        $map["平铺ToolStripMenuItem"] = "TileToolStripMenuItem"
        $map["并从以下位置删除"] = "And remove from the following positions"
        $map["并从以下位置删除多余的属性"] = "And remove extra properties from the following positions"
        $map["序号"] = "No."
        $map["序号 "] = "No. "
        $map["应用"] = "Apply"
        $map["应用程序"] = "Application"
        $map["应用程序线程错误:{0}"] = "Application thread error: {0}"
        $map["度"] = "deg"
        $map["度/分"] = "deg/min"
        $map["度/分秒"] = "deg/min/sec"
        $map["开发者:"] = "Developer:"
        $map["开头不是"] = "Does not start with"
        $map["开头是"] = "Starts with"
        $map["开始"] = "Home"
        $map["开始行："] = "Start row:"
        $map["异常信息：检测到dnSpy非法启动"] = "Illegal dnSpy launch detected"
        $map["异常消息：{0}"] = "Exception message: {0}"
        $map["异常类型：{0}`r`n异常消息：{1}`r`n异常信息：{2}"] = "Exception type: {0}`r`nMessage: {1}`r`nInfo: {2}"
        $map["异常类型：{0}`r`n异常消息：{1}`r`n异常信息：{2}`r`n"] = "Exception type: {0}`r`nMessage: {1}`r`nInfo: {2}`r`n"
        $map["弧度"] = "rad"
        $map["当前SolidWorks版本调用失败！"] = "Current SolidWorks version call failed!"
        $map["当前任务中断，可尝试按`"下一步`" ➜ `"开始`"继续任务"] = "Current task interrupted. Press `"Next`" ➜ `"Home`" to continue."
        $map["当前共"] = "Current total"
        $map["当前启动程序集的公钥令牌不符"] = "Public key token of starting assembly does not match"
        $map["当前已是最新版本！"] = "Already on the latest version!"
        $map["当前日期"] = "Current date"
        $map["当前模型不存在或所在目录无权访问"] = "Current model does not exist or no access to directory"
        $map["当前模型已经存在工程图！"] = "Current model already has a drawing!"
        $map["当前没有打开文档"] = "No open documents"
        $map["当前配置"] = "Current config"
        $map["当前项不可使用"] = "Current item unavailable"
        $map["当电脑不能上网时，可以用手机扫描左侧二维`r`n码将信息发给作者获取离线授权文件。"] = "If the computer is offline, scan the QR code on the left with your phone`r`nand send info to the developer to obtain an offline license file."
        $map["待拆分的列："] = "Column to split:"
        $map["待读取的文件列表"] = "List of files to read"
        $map["微升"] = "µL"
        $map["微秒"] = "µs"
        $map["微米"] = "µm"
        $map["微米^3"] = "µm^3"
        $map["微软雅黑"] = "Microsoft YaHei"
        $map["忘情水。。。"] = "Water of Oblivion..."
        $map["快捷方式创建成功！"] = "Shortcut created!"
        $map["总数量"] = "Total Qty"
        $map["恢复为材质颜色"] = "Restore material color"
        $map["悬空注解"] = "Dangling notes"
        $map["成功"] = "Success"
        $map["或"] = "or"
        $map["所有文件（*.*）|*.*"] = "All Files (*.*)|*.*"
        $map["所有配置"] = "All Configs"
        $map["才能启用"] = "Required for enabling"
        $map["打包到文件夹"] = "Pack to folder"
        $map["打印"] = "Print"
        $map["打印份数："] = "Copies:"
        $map["打印到文件"] = "Print to File"
        $map["打印捕获"] = "Print Capture"
        $map["打印日期："] = "Print date:"
        $map["打印机"] = "Printer"
        $map["打印纸张大小"] = "Paper size"
        $map["打印设置"] = "Print Settings"
        $map["打印首选项(&E)..."] = "Print Preferences (&E)..."
        $map["打开"] = "Open"
        $map["打开 "] = "Open "
        $map["打开pdf"] = "Open PDF"
        $map["打开上一次转图文件夹"] = "Open last conversion folder"
        $map["打开工程图"] = "Open Drawing"
        $map["打开工程图 (&D）"] = "Open Drawing (&D)"
        $map["打开帮助文件"] = "Open Help"
        $map["打开帮助文件出错：`n"] = "Error opening Help:`n"
        $map["打开当前Excel数据源"] = "Open current Excel source"
        $map["打开当前Excel模板"] = "Open current Excel template"
        $map["打开当前目录"] = "Open current directory"
        $map["打开装配体"] = "Open Assembly"
        $map["打开装配体 (&W）"] = "Open Assembly (&W)"
        $map["打开零件"] = "Open Part"
        $map["打开零件 (&W）"] = "Open Part (&W)"
        $map["打开零部件"] = "Open Component"
        $map["执行宏操作..."] = "Running macro..."
        $map["执行宏（支持多选）"] = "Run macro (multi-select)"
        $map["批量复制 (&C）"] = "Batch Copy (&C)"
        $map["批量打印"] = "Batch Print"
        $map["批量粘贴 (&V）"] = "Batch Paste (&V)"
        $map["找不同"] = "Find Differences"
        $map["找相同"] = "Find Matches"
        $map["报表类型"] = "Report type"
        $map["拆分 "] = "Split "
        $map["拆分PDF"] = "Split PDF"
        $map["拆分列"] = "Split Column"
        $map["拆分后保存到文件夹"] = "Save to folder after split"
        $map["拆分后填写到："] = "Fill after split into:"
        $map["拆分完成"] = "Split complete"
        $map["拆分操作"] = "Split operation"
        $map["拆分方式"] = "Split method"
        $map["拖动行表头可排序，选中行表头，按del键可以删除整行。"] = "Drag row header to sort. Select header and press Del to delete row."
        $map["按1：1输出"] = "Output 1:1"
        $map["按上次保存"] = "Last saved"
        $map["按勾选"] = "By checked"
        $map["按工程图中第一个视图的比例输出（所有视图比例都不等于`r`n图纸比例时才生效）"] = "Output by scale of first view (only if no view matches sheet scale)"
        $map["按搜索规则"] = "By search rule"
        $map["按模板导出"] = "Export by template"
        $map["按筛选"] = "By filter"
        $map["按规则"] = "By rule"
        $map["按配置打印"] = "By config"
        $map["按配置执行（只对从主界面导入的项、选中项及工程图有效）"] = "By config (only for imported/selected/drawings)"
        $map["按颜色筛选"] = "Filter by color"
        $map["换行符"] = "Line break"
        $map["授权保护密码(在샌㭯빓溋왿ś౸泿摒衑䍣๧왔ś챸自动清除):"] = "License protection password:"
        $map["排除符合项"] = "Exclude matches"
        $map["推荐使用的分隔符：短横`"-`"、下横线`"_`"和空格。`r`n当引用属性值为空时可自动消隐分隔符。"] = "Recommended separators: `"-`", `"_`" and space.`r`nWhen referenced property value is empty, separator is hidden automatically."
        $map["提升"] = "Promote"
        $map["提示"] = "Hint"
        $map["提示："] = "Hint:"
        $map["插件未启动"] = "Plugin not started"
        $map["插件未启动！"] = "Plugin not started!"
        $map["插入..."] = "Insert..."
        $map["插入缩略图"] = "Insert thumbnail"
        $map["插入链接...."] = "Insert link..."
        $map["搜索"] = "Search"
        $map["撤销"] = "Undo"
        $map["操作"] = "Action"
        $map["支持系统版本"] = "Supported OS"
        $map["支持系统版本：Win7及以上"] = "Supported OS: Windows 7 and above"
        $map["数字"] = "Number"
        $map["数据填写到"] = "Fill data into"
        $map["数据源"] = "Data source"
        $map["数据源不存在，请先设置数据源文件"] = "Data source does not exist — set the source file"
        $map["数量"] = "Qty"
        $map["文件"] = "File"
        $map["文件(*.*|*.*"] = "Files (*.*)|*.*"
        $map["文件列表"] = "File list"
        $map["文件列表(可直接将文件或文件夹拖拽进列表中)"] = "File list (drag files or folders here)"
        $map["文件名"] = "File name"
        $map["文件名规则："] = "File name rule:"
        $map["文件名重复"] = "File name duplicate"
        $map["文件夹"] = "Folder"
        $map["文件打印机"] = "File printer"
        $map["文件类型"] = "File type"
        $map["文字"] = "Text"
        $map["文本"] = "Text"
        $map["文本位置"] = "Text position"
        $map["文本文件（*txt）|*.txt"] = "Text file (*.txt)|*.txt"
        $map["文档名称"] = "Document name"
        $map["斜线`"\`""] = "Backslash `"\`""
        $map["新参考文件路径"] = "New reference file path"
        $map["新图纸格式"] = "New sheet format"
        $map["新文件夹名称："] = "New folder name:"
        $map["新配置名"] = "New config name"
        $map["无"] = "(none)"
        $map["无可以模板"] = "No available template"
        $map["无效数据源！"] = "Invalid data source!"
        $map["无效模板"] = "Invalid template"
        $map["无效注册码"] = "Invalid license key"
        $map["无效注册码，请联系作者购买注册码"] = "Invalid license key. Contact the developer to purchase a key."
        $map["无法打开当前模型！"] = "Cannot open current model!"
        $map["无需同步"] = "Sync not needed"
        $map["无需转出"] = "Transfer not needed"
        $map["日期"] = "Date"
        $map["时"] = "h"
        $map["时间"] = "Time"
        $map["明细表选项"] = "BOM Options"
        $map["映射名称"] = "Mapping name"
        $map["是"] = "Yes"
        $map["是否立即安装更新？`n注：安装前会关闭主程序和SolidWorks进程，请注意保存！"] = "Install update now?`nNote: program and SolidWorks process will be closed first — save your data!"
        $map["是或否"] = "Yes or No"
        $map["显示"] = "Show"
        $map["显示/隐藏缩略图"] = "Show/Hide thumbnail"
        $map["更新&保存"] = "Update & Save"
        $map["更新其它参考关系"] = "Update other references"
        $map["更新内容：`r`n"] = "What's new:`r`n"
        $map["更新参考关系"] = "Update references"
        $map["更新参考关系..."] = "Updating references..."
        $map["更新参考关系失败！"] = "Update references failed!"
        $map["更新日志"] = "Changelog"
        $map["更新零部件单位"] = "Update component units"
        $map["替换"] = "Replace"
        $map["替换`"图纸格式`""] = "Replace `"Sheet Format`""
        $map["替换`"绘图标准`""] = "Replace `"Drawing Standard`""
        $map["替换为"] = "Replace with"
        $map["替换为："] = "Replace with:"
        $map["替换列表"] = "Replace list"
        $map["替换参考中..."] = "Replacing references..."
        $map["替换参考文件"] = "Replace reference file"
        $map["替换完成"] = "Replace complete"
        $map["最近使用"] = "Recent"
        $map["有"] = "Has"
        $map["有 "] = "Has "
        $map["有效期至：永久使用`r`n"] = "Valid until: perpetual`r`n"
        $map["有无工程图"] = "Has drawing"
        $map["未打开工程图"] = "Drawing not open"
        $map["未找到字符`""] = "Character not found `""
        $map["未找到工程图"] = "Drawing not found"
        $map["未找到符合的项"] = "No matching items"
        $map["未授权功能"] = "Feature requires license"
        $map["未检测到有效许可!"] = "No valid license detected!"
        $map["未激活的配置"] = "Inactive configs"
        $map["机器码：`r`n"] = "Machine code:`r`n"
        $map["材料"] = "Material"
        $map["材质库文件不存在！请重新添加材质库。"] = "Material library file not found! Add the library again."
        $map["材质数据库文件（*.sldmat）|*.sldmat"] = "Material database (*.sldmat)|*.sldmat"
        $map["来生缘。。。"] = "Next Life Bond..."
        $map["查找下一个"] = "Find Next"
        $map["查找全部"] = "Find All"
        $map["查找内容："] = "Find what:"
        $map["查找和替换"] = "Find and Replace"
        $map["查找填充"] = "Find and Fill"
        $map["查找填写"] = "Find and Fill"
        $map["查找范围："] = "Search scope:"
        $map["标签"] = "Tag"
        $map["标签："] = "Tag:"
        $map["标记没有工程图的项"] = "Mark items without drawings"
        $map["标记相关节点"] = "Mark related nodes"
        $map["标记相关节点（支持多选）"] = "Mark related nodes (multi-select)"
        $map["楷体"] = "KaiTi"
        $map["正则表达式"] = "Regex"
        $map["正则表达式语法"] = "Regex syntax"
        $map["正在从磁盘打开文件"] = "Opening files from disk"
        $map["正在保存文件"] = "Saving files"
        $map["正在创建工程图..."] = "Creating drawings..."
        $map["正在同步工程图名称..."] = "Syncing drawing names..."
        $map["正在启动excel...."] = "Starting Excel..."
        $map["正在导出数据...."] = "Exporting data..."
        $map["正在导出明细表...."] = "Exporting BOM..."
        $map["正在导出缩进式明"] = "Exporting indented BOM"
        $map["正在打开excel...."] = "Opening Excel..."
        $map["正在打开模板文件...."] = "Opening template..."
        $map["正在插入缩略图"] = "Inserting thumbnails"
        $map["正在生成缩略图."] = "Generating thumbnails."
        $map["正在解析模板文件...."] = "Parsing template..."
        $map["正在解析零部件..."] = "Parsing components..."
        $map["此文件夹"] = "This folder"
        $map["此注册码没有转出权限"] = "This license has no transfer rights"
        $map["此电脑没有转出权限"] = "This computer has no transfer rights"
        $map["比例："] = "Scale:"
        $map["毫克"] = "mg"
        $map["毫升"] = "ml"
        $map["毫牛顿"] = "mN"
        $map["毫秒"] = "ms"
        $map["毫米"] = "mm"
        $map["毫米^3"] = "mm^3"
        $map["汇总"] = "Summary"
        $map["没发现可下载的资源！"] = "No downloadable resources found!"
        $map["没有可备份的数据"] = "No data to back up"
        $map["没有可导出的数据"] = "No data to export"
        $map["没有可打印的项"] = "No items to print"
        $map["没有启动solidworks，是否现在启动？"] = "SolidWorks is not running. Start now?"
        $map["没有工程图，是否创建？"] = "No drawing. Create?"
        $map["没有找到匹配项！"] = "No matches found!"
        $map["没有找到更新包！"] = "Update package not found!"
        $map["没有注册类，ProgID：`""] = "Class not registered, ProgID: `""
        $map["没有读取到有效数据"] = "No valid data read"
        $map["没有选择任何节点"] = "No node selected"
        $map["没有需处理的文件"] = "No files to process"
        $map["没有需处理的文件！"] = "No files to process!"
        $map["没有需要转换的项"] = "No items to convert"
        $map["波浪线 `"~`""] = "Tilde `"~`""
        $map["注册"] = "Register"
        $map["注册信息"] = "Registration info"
        $map["注册信息保存错误"] = "Error saving registration"
        $map["注册信息错误"] = "Registration data error"
        $map["注册失败"] = "Registration failed"
        $map["注册成功"] = "Registration successful"
        $map["注册申请失败"] = "Registration request failed"
        $map["注册码已被其它电脑使用"] = "License already used by another computer"
        $map["注册码已过期"] = "License key expired"
        $map["注册码："] = "License key:"
        $map["派生配置"] = "Derived config"
        $map["浏览"] = "Browse"
        $map["浏览.."] = "Browse.."
        $map["浏览..."] = "Browse..."
        $map["浏览Excel数据源"] = "Browse Excel source"
        $map["浏览Excel模板"] = "Browse Excel template"
        $map["消息"] = "Message"
        $map["淘宝:"] = "Shop:"
        $map["添加"] = "Add"
        $map["添加..."] = "Add..."
        $map["添加solidworks中已打开的零部件"] = "Add components open in SolidWorks"
        $map["添加列"] = "Add Column"
        $map["添加前后缀"] = "Add Prefix/Suffix"
        $map["添加前缀:"] = "Add prefix:"
        $map["添加后缀:"] = "Add suffix:"
        $map["添加文件"] = "Add Files"
        $map["添加文件夹"] = "Add Folder"
        $map["添加文件夹(包含子文件夹)"] = "Add Folder (with subfolders)"
        $map["添加文件夹（包含子文件夹）"] = "Add Folder (with subfolders)"
        $map["添加材质库..."] = "Add material library..."
        $map["添加目录"] = "Add directory"
        $map["添加项"] = "Add item"
        $map["清空"] = "Clear"
        $map["清空列表吗？"] = "Clear the list?"
        $map["清除"] = "Clear"
        $map["清除内容"] = "Clear content"
        $map["清除筛选"] = "Clear filter"
        $map["清除颜色"] = "Clear color"
        $map["源工程图不存在或所在目录无权访问"] = "Source drawing does not exist or no access to directory"
        $map["激活并保存此零部件..."] = "Activate and save this component..."
        $map["激活并保存此零部件（支持多选）"] = "Activate and save component (multi-select)"
        $map["灰度级"] = "Grayscale"
        $map["点 `".`""] = "Period `".`""
        $map["点此设置路径"] = "Click to set path"
        $map["焊件<按加工>"] = "Weldment <by machining>"
        $map["焊件<按焊接>"] = "Weldment <by welding>"
        $map["焦耳"] = "J"
        $map["版 本 :{0}"] = "Version: {0}"
        $map["版本"] = "Version"
        $map["版本`n2"] = "Version`n2"
        $map["版本："] = "Version:"
        $map["牛顿"] = "N"
        $map["特别提醒！！！"] = "Warning!!!"
        $map["状态"] = "Status"
        $map["瓦"] = "W"
        $map["用户指定的名称"] = "User-specified name"
        $map["百宝箱"] = "Toolbox"
        $map["盎司-力"] = "oz-force"
        $map["目录不存在"] = "Directory does not exist"
        $map["目标程序不存在！"] = "Target program does not exist!"
        $map["直接导出"] = "Direct export"
        $map["短横线 `"-`""] = "Hyphen `"-`""
        $map["确定"] = "OK"
        $map["确定(&O)"] = "OK (&O)"
        $map["确定清空列表吗？"] = "Clear the list?"
        $map["确认"] = "Confirm"
        $map["确认修改"] = "Confirm changes"
        $map["磅"] = "lb"
        $map["磅-力"] = "lbf"
        $map["示例："] = "Example:"
        $map["秒"] = "sec"
        $map["秒，共"] = "sec, total"
        $map["移除选中"] = "Remove selected"
        $map["空格"] = "Space"
        $map["空格或下横线"] = "Space or underscore"
        $map["符号"] = "Symbol"
        $map["笨小孩。。。"] = "Silly Kid..."
        $map["第一列："] = "First column:"
        $map["第二列："] = "Second column:"
        $map["等于"] = "Equals"
        $map["筛选"] = "Filter"
        $map["筛选（反向）"] = "Filter (inverse)"
        $map["米"] = "m"
        $map["米^3"] = "m^3"
        $map["类型"] = "Type"
        $map["粘贴"] = "Paste"
        $map["粘贴到列："] = "Paste to column:"
        $map["粘贴工程图"] = "Paste drawing"
        $map["纳秒"] = "ns"
        $map["纳米"] = "nm"
        $map["纳米^3"] = "nm^3"
        $map["纸张设置和打印范围"] = "Paper setup and print range"
        $map["线条样式："] = "Line style:"
        $map["结尾不是"] = "Does not end with"
        $map["结尾是"] = "Ends with"
        $map["结果："] = "Result:"
        $map["绘图标准"] = "Drawing standard"
        $map["绘图标准文件`""] = "Drawing standard file `""
        $map["绘图标准文件（*.sldstd）|*.sldstd"] = "Drawing standard (*.sldstd)|*.sldstd"
        $map["绘图标准（工程图）："] = "Standard (drawing):"
        $map["绘图标准（装配体）："] = "Standard (assembly):"
        $map["绘图标准（零件）："] = "Standard (part):"
        $map["统一保存到文件夹"] = "Save to common folder"
        $map["继续任务"] = "Continue task"
        $map["缓存数据量："] = "Cached:"
        $map["编辑"] = "Edit"
        $map["编辑规则"] = "Edit rule"
        $map["缩略图"] = "Thumbnail"
        $map["缩略图大小："] = "Thumbnail size:"
        $map["缩进"] = "Indent"
        $map["网站下载：www.z-tool.cn"] = ""
        $map["网络异常"] = "Network error"
        $map["网络设置"] = "Network settings"
        $map["能量"] = "Energy"
        $map["自动"] = "Auto"
        $map["自动列宽"] = "Auto column width"
        $map["自定义"] = "Custom"
        $map["自定义和所有配置"] = "Custom and all configs"
        $map["自定义填充"] = "Custom fill"
        $map["自定义属性"] = "Custom properties"
        $map["自定义排序"] = "Custom sort"
        $map["自定义菜单..."] = "Custom menu..."
        $map["自定义规则"] = "Custom rule"
        $map["英寸"] = "in"
        $map["英寸^3"] = "in^3"
        $map["英尺"] = "ft"
        $map["英尺^3"] = "ft^3"
        $map["英尺和英寸"] = "feet and inches"
        $map["行"] = "Row"
        $map["表格列"] = "Table column"
        $map["表面处理"] = "Surface finish"
        $map["装配体"] = "Assembly"
        $map["装配体(*.SLDASM)|*."] = "Assembly (*.SLDASM)|*."
        $map["装配体（.SLDASM）"] = "Assembly (.SLDASM)"
        $map["覆盖同名文件"] = "Overwrite files with same name"
        $map["覆盖同名文件（需谨慎）"] = "Overwrite files with same name (caution)"
        $map["规则列表"] = "Rules list"
        $map["规则名称"] = "Rule name"
        $map["规则填充"] = "Rule-based fill"
        $map["视图"] = "View"
        $map["角度"] = "Angle"
        $map["角度:"] = "Angle:"
        $map["解除压缩（&U）"] = "Unsuppress (&U)"
        $map["设定颜色"] = "Set color"
        $map["设置失败！"] = "Failed to apply settings!"
        $map["设置属性名称"] = "Set property name"
        $map["设置的SolidWorks版本不正确，请重新设置"] = "Incorrect SolidWorks version configured — set again"
        $map["设计"] = "Design"
        $map["设计日期"] = "Design date"
        $map["评估的值   "] = "Evaluated value   "
        $map["试用"] = "Trial"
        $map["试用中...剩余"] = "Trial... remaining"
        $map["试用时间到！软件将在10秒后自动关闭！"] = "Trial time is over! Software will close in 10 seconds!"
        $map["试用版不支持！"] = "Trial does not support!"
        $map["询问"] = "Query"
        $map["该设备不具备注册条件！"] = "This device cannot be registered!"
        $map["详细列表"] = "Detail list"
        $map["说明"] = "Description"
        $map["说明：`r`n{ }内的为增量起始值;`r`n`$属性名称`$---引用属性值`r`n%属性名称%---引用属性表达式`r`n<列标题>---引用其它列的值`r`n"] = "Description:`r`n{ } — increment start value;`r`n`$PropertyName`$ — property value`r`n%PropertyName% — property expression`r`n<ColumnHeader> — other column's value`r`n"
        $map["说明：`r`n{ }内的为流水号初始值;`r`n`$列标题`$---引用属性列评估的值`r`n%列标题%---引用属性列表达式`r`n<列标题>---引用其它列的值`r`n"] = "Description:`r`n{ } — serial number start;`r`n`$ColumnHeader`$ — evaluated column value`r`n%ColumnHeader% — column expression`r`n<ColumnHeader> — other column's value`r`n"
        $map["请先在solidworks选项中设置默认工程图模板"] = "First set the default drawing template in SolidWorks options"
        $map["请先打开solidworks"] = "First start SolidWorks"
        $map["请先添加列"] = "First add a column"
        $map["请先设置Bom模板"] = "First set BOM template"
        $map["请先设置参考路径"] = "First set reference path"
        $map["请先设置图纸格式所在文件夹"] = "First set sheet formats folder"
        $map["请先设置重命名后旧文件的移动路径"] = "First set move path for old files after rename"
        $map["请关闭solidworks中打开的所有文件!`n`n自动关闭solidworks中打开的所有文件？"] = "Close all files open in SolidWorks!`n`nClose automatically?"
        $map["请关闭solidworks中打开的所有文件，以免造成读取错误!`n`n自动关闭solidworks中打开的所有文件？"] = "Close all files open in SolidWorks to avoid read errors!`n`nClose automatically?"
        $map["请勾选需要打印的项"] = "Check items to print"
        $map["请确认是否删除？"] = "Confirm deletion"
        $map["请设置图纸格式"] = "Set sheet format"
        $map["请设置绘图标准"] = "Set drawing standard"
        $map["请设置输出格式"] = "Set output format"
        $map["请设置输出路径"] = "Set output path"
        $map["请输入8-20位包含大小写字母和数字的密码"] = "Enter 8-20 chars: uppercase, lowercase, and digits"
        $map["请输入注册码"] = "Enter license key"
        $map["请选择"] = "Please select"
        $map["请选择两个不同的列"] = "Select two different columns"
        $map["请选择需要打印的图纸类型"] = "Select sheet types to print"
        $map["读取SW数据出错：`n"] = "Error reading SW data:`n"
        $map["读取规则"] = "Read rule"
        $map["调整比例以套合"] = "Fit to scale"
        $map["质量"] = "Mass"
        $map["质量/截面属性"] = "Mass / Section Properties"
        $map["路径"] = "Path"
        $map["路径 `""] = "Path `""
        $map["路径不存在,是否创建?"] = "Path does not exist. Create?"
        $map["路径格式不合法"] = "Invalid path format"
        $map["路径："] = "Path:"
        $map["跳过只读文件"] = "Skip read-only files"
        $map["跳过只读项"] = "Skip read-only items"
        $map["跳过未修改的项"] = "Skip unchanged items"
        $map["跳过没有失败的项"] = "Skip successful items"
        $map["跳过被筛选的项"] = "Skip filtered items"
        $map["转出授权"] = "Transfer license"
        $map["转出授权失败"] = "License transfer failed"
        $map["转出授权成功"] = "License transferred"
        $map["转换2D工程图为"] = "Convert 2D drawing to"
        $map["转换3D模型为"] = "Convert 3D model to"
        $map["输入方案名称"] = "Enter scheme name"
        $map["输入规则名称"] = "Enter rule name"
        $map["输出属性值"] = "Output property values"
        $map["输出属性表达式"] = "Output property expressions"
        $map["输出所有图纸到一个文件"] = "All sheets to one file"
        $map["输出所有图纸到单个文件"] = "All sheets to single file"
        $map["输出所有工程图图纸到纸张空间"] = "All drawing sheets to paper space"
        $map["输出文件名设置"] = "Output filename settings"
        $map["输出文件夹"] = "Output folder"
        $map["输出格式"] = "Output format"
        $map["输出路径"] = "Output path"
        $map["输出选项"] = "Output options"
        $map["达因"] = "dyne"
        $map["过滤规则"] = "Filter rule"
        $map["运动单位"] = "Motion units"
        $map["运行时隐藏SolidWorks界面"] = "Hide SolidWorks UI during run"
        $map["连接solidworks失败"] = "Failed to connect to SolidWorks"
        $map["连接solidworks总时间"] = "Total connect time to SolidWorks"
        $map["连接上次文档"] = "Connect last document"
        $map["连接完成，耗时 "] = "Connect complete, elapsed "
        $map["连接当前文档"] = "Connect current document"
        $map["连接服务器中..."] = "Connecting to server..."
        $map["连接服务器出错"] = "Server connection error"
        $map["连接服务器失败！"] = "Failed to connect to server!"
        $map["连接服务器超时"] = "Server connection timed out"
        $map["连接超时"] = "Connection timed out"
        $map["适用于缩略图不显"] = "For when thumbnails do not show"
        $map["选择列："] = "Select column:"
        $map["选择可用材质库..."] = "Select available material library..."
        $map["选择需填充的列："] = "Select column to fill:"
        $map["选择需要加载的文件类型"] = "Select file types to load"
        $map["选项"] = "Options"
        $map["透明度:"] = "Transparency:"
        $map["配置BOM方案"] = "Configure BOM scheme"
        $map["配置名称"] = "Config name"
        $map["配置文件(*.settings)"] = "Config file (*.settings)"
        $map["配置文件（*settings）|*.settings"] = "Config file (*.settings)|*.settings"
        $map["重命名"] = "Rename"
        $map["重命名后旧文件移动到"] = "Move old files after rename to"
        $map["重命名设置"] = "Rename settings"
        $map["重新开始"] = "Restart"
        $map["重新获取数据？"] = "Reload data?"
        $map["重置文件名"] = "Reset filename"
        $map["重置文件夹"] = "Reset folder"
        $map["重置颜色"] = "Reset color"
        $map["重量"] = "Weight"
        $map["钣金展开配置"] = "Sheet-metal flat pattern config"
        $map["链接到父配置"] = "Link to parent config"
        $map["锁定纵横比（原始比例4：3）"] = "Lock aspect ratio (original 4:3)"
        $map["错误"] = "Error"
        $map["长度"] = "Length"
        $map["降序"] = "Descending"
        $map["随机颜色"] = "Random color"
        $map["随行显示"] = "Inline"
        $map["隐藏"] = "Hide"
        $map["隐藏悬空注解和尺寸"] = "Hide dangling notes and dimensions"
        $map["隐藏行（支持多选） (&H）"] = "Hide rows (multi-select) (&H)"
        $map["零件"] = "Part"
        $map["零件(*.SLDPRT)|*.S"] = "Part (*.SLDPRT)|*.S"
        $map["零件名称"] = "Part name"
        $map["零件名称`n1"] = "Part name`n1"
        $map["零件配置"] = "Part config"
        $map["零件（.SLDPRT）"] = "Part (.SLDPRT)"
        $map["零部件汇总"] = "Components summary"
        $map["需先打开"] = "First open"
        $map["需更新的文件夹："] = "Folders to update:"
        $map["页面自动旋转方向"] = "Auto-rotate page"
        $map["页面设置"] = "Page setup"
        $map["顶级BOM"] = "Top-level BOM"
        $map["项"] = "items"
        $map["项。"] = "items."
        $map["项保存失败"] = "items failed to save"
        $map["颜色/灰度级"] = "Color/Grayscale"
        $map["马力"] = "hp"
        $map["高品质"] = "High quality"
        $map["高度："] = "Height:"
        $map["黑白"] = "Black & White"
        $map["黑白（双层）"] = "Black & White (two-layer)"
        $map["默认"] = "Default"
        $map["默认导出汇总BOM"] = "Export summary BOM by default"
        $map["（x64） 注册$([char]0x1e)$([char]0x1c)"] = "(x64) Register"
        $map["（x86） 注册$([char]0x1e)$([char]0x1c)"] = "(x86) Register"
        # Strings extracted from payload .resources files (Frmmain/FrmOptions/Resources)
        $map["API接口测速"] = "API speed test"
        $map["BOM零件号"] = "BOM part number"
        $map["SolidWorks版本："] = "SolidWorks version:"
        $map["Windows默认"] = "Windows default"
        $map["下拉列表："] = "Dropdown list:"
        $map["保存到文件夹"] = "Save to folder"
        $map["保存时间"] = "Saved at"
        $map["列标题："] = "Column header:"
        $map["创建时间"] = "Created at"
        $map["创建桌面快捷方式"] = "Create desktop shortcut"
        $map["初始化表格"] = "Initialize table"
        $map["单重(Kg)"] = "Weight (kg)"
        $map["单重_Kg"] = "Weight_kg"
        $map["双击图标在SOLIDWORKS中打开零部件或工程图"] = "Double-click icon: open part/drawing in SOLIDWORKS"
        $map["启动时检查更新"] = "Check for updates on startup"
        $map["在左侧选中属性列，在右侧添加该列的下拉 数据，每行一个。"] = "Select a property column on the left, add dropdown values on the right (one per line)."
        $map["复选框"] = "Checkbox"
        $map["外形尺寸"] = "Bounding size"
        $map["宏列表"] = "Macros list"
        $map["实时筛选"] = "Real-time filter"
        $map["将此材质库添加到solidworks"] = "Add this material library to SolidWorks"
        $map["展开所有"] = "Expand all"
        $map["折叠所有"] = "Collapse all"
        $map["展开材质列表到同一级"] = "Expand material list to same level"
        $map["工程图"] = "Drawing"
        $map["常规"] = "General"
        $map["所选行高亮显示："] = "Selected row highlight:"
        $map["打开插件根目录"] = "Open plugin root folder"
        $map["打开日志文件路径"] = "Open log file path"
        $map["打开默认目录"] = "Open default folder"
        $map["批量工具开启文件预览"] = "Enable file preview in batch tools"
        $map["批量工具操作时隐藏SolidWorks界面"] = "Hide SolidWorks window during batch operations"
        $map["批量缩略图方案："] = "Batch thumbnail scheme:"
        $map["插入缩略图时将其保存到:"] = "When inserting thumbnail, save to:"
        $map["搜索已添加到solidworks的材质库"] = "Search material libraries already added to SolidWorks"
        $map["摘要_主题"] = "Summary_Subject"
        $map["摘要_作者"] = "Summary_Author"
        $map["摘要_关键字"] = "Summary_Keywords"
        $map["摘要_备注"] = "Summary_Comments"
        $map["摘要_标题"] = "Summary_Title"
        $map["文档类型"] = "Document type"
        $map["材质"] = "Material"
        $map["浏览材质库"] = "Browse material library"
        $map["磁盘文件名"] = "Disk file name"
        $map["统计数量"] = "Quantity"
        $map["缩略图快捷键："] = "Thumbnail shortcuts:"
        $map["自定义下拉"] = "Custom dropdown"
        $map["自定义材质文件："] = "Custom material file:"
        $map["读取每一个配置的属性（仅对零件有效）"] = "Read properties of every configuration (parts only)"
        $map["配置"] = "Configuration"
        $map["重新连接SW后清除筛选"] = "Clear filter on SW reconnect"
        $map["重置缩略图位置"] = "Reset thumbnail positions"
        $map["零部件目录"] = "Components folder"
        $map["高清模式"] = "HD mode"
        $map["默认目录"] = "Default folder"
        $map["默认设置"] = "Default settings"
        $map["不包括在材料明细表中（&E）(支持多选)"] = "Exclude from BOM (&E) (multi-select supported)"
        $map["包含在材料明细表中（&I）(支持多选)"] = "Include in BOM (&I) (multi-select supported)"
        $map["压缩零部件（&S）(支持多选)"] = "Suppress component (&S) (multi-select supported)"
        $map["解除压缩（&U）(支持多选)"] = "Unsuppress (&U) (multi-select supported)"
        $map["只显示该节点及其子项"] = "Show only this node and its descendants"
        $map["只显示该节点的子项"] = "Show only this node's children"
        $map["只显示该节点的顶层子项"] = "Show only top-level children of this node"
        $map["隐藏该节点 （支持多选）"] = "Hide this node (multi-select supported)"
        $map["隐藏该节点的子项（支持多选）"] = "Hide this node's children (multi-select supported)"
        # Additional payload ldstr strings discovered in re-audit (uncovered after PR #4)
        $map["试用版最多支持10个文件"] = "Trial version supports up to 10 files"
        $map["PDF文件(*.pdf)|*.pdf"] = "PDF file (*.pdf)|*.pdf"
        $map["3D模型排除以下配置"] = "Exclude these configs from 3D model"
        $map["3D转换文件名自定义："] = "Custom file name for 3D conversion:"
        $map["2D转换文件名自定义："] = "Custom file name for 2D conversion:"
        $map["工程图转换PDF后为其添加图片水印"] = "Add image watermark after drawing-to-PDF conversion"
        $map["工程图转换PDF后为其添加文本水印"] = "Add text watermark after drawing-to-PDF conversion"
        $map["工程图(*.SLDDRW)|*.SLDDRW"] = "Drawing (*.SLDDRW)|*.SLDDRW"
        $map["工程图(*.SLDDRW)|*.SLDDRW|零件(*.SLDPRT)|*.SLDPRT|装配体(*.SLDASM)|*.SLDASM|SOLIDWORKS文件(*.SLDPRT;*.SLDASM;*.SLDDRW)|*.SLDPRT;*.SLDASM;*.SLDDRW"] = "Drawing (*.SLDDRW)|*.SLDDRW|Part (*.SLDPRT)|*.SLDPRT|Assembly (*.SLDASM)|*.SLDASM|SOLIDWORKS files (*.SLDPRT;*.SLDASM;*.SLDDRW)|*.SLDPRT;*.SLDASM;*.SLDDRW"
        $map["装配体(*.SLDASM)|*.SLDASM"] = "Assembly (*.SLDASM)|*.SLDASM"
        $map["零件(*.SLDPRT)|*.SLDPRT|装配体(*.SLDASM)|*.SLDASM"] = "Part (*.SLDPRT)|*.SLDPRT|Assembly (*.SLDASM)|*.SLDASM"
        $map["零件(*.SLDPRT)|*.SLDPRT|装配体(*.SLDASM)|*.SLDASM|SOLIDWORKS文件(*.SLDPRT;*.SLDASM)|*.SLDPRT;*.SLDASM"] = "Part (*.SLDPRT)|*.SLDPRT|Assembly (*.SLDASM)|*.SLDASM|SOLIDWORKS files (*.SLDPRT;*.SLDASM)|*.SLDPRT;*.SLDASM"
        $map["SOLIDWORKS文件(*.SLDPRT;*.SLDASM)|*.SLDPRT;*.SLDASM|SOLIDWORKS零件(*.SLDPRT)|*.SLDPRT|SOLIDWORKS装配体(*.SLDASM)|*.SLDASM"] = "SOLIDWORKS files (*.SLDPRT;*.SLDASM)|*.SLDPRT;*.SLDASM|SOLIDWORKS part (*.SLDPRT)|*.SLDPRT|SOLIDWORKS assembly (*.SLDASM)|*.SLDASM"
        $map["配置文件(*.settings)|*.settings"] = "Settings file (*.settings)|*.settings"
        $map["属性模板(*.prtprp;*.asmprp)|*.prtprp;*.asmprp"] = "Property template (*.prtprp;*.asmprp)|*.prtprp;*.asmprp"
        $map["修改ToolStripMenuItem"] = "Edit menu item"
        $map["替换后的零部件移动到"] = "Move replaced component to"
        $map["请设置替换后原文件移动路径"] = "Set the path to move the original file after replacement"
        $map["替换图纸格式和绘图标准"] = "Replace drawing format and drafting standard"
        $map["`"已存在，请换一个名称"] = "`" already exists, please choose another name"
        $map["选中行表头，按del键可以删除整行；`r`n多个值之间可以用英文分号分隔；"] = "Select a row header and press Del to delete the entire row;`r`nmultiple values may be separated by an English semicolon;"
        $map["压缩零部件（&S）"] = "Suppress component (&S)"
        $map["适用于缩略图不显示或其它需要保存的零部件"] = "Applies to components whose thumbnail is missing or that need to be saved"
        $map["没找到工程图模板！"] = "Drawing template not found!"
        $map[") (在明细表中解散)"] = ") (dissolved in BOM)"
        $map[") (在明细表中隐藏子项)"] = ") (hide children in BOM)"
        $map[") (不包含在明细表中)"] = ") (excluded from BOM)"
        $map["正在生成缩略图...."] = "Generating thumbnails...."
        $map["正在导出缩进式明细表...."] = "Exporting indented BOM...."
        $map["/进阶操作/缩略图显示及操作.htm"] = "/Advanced operations/Thumbnail display and operations.htm"
        $map["授权保护密码(在激活时可设置密码，转出授权后密码自动清除):"] = "Licence protection password (set on activation, cleared automatically after transfer):"
        $map["修改属性后自动保存"] = "Auto-save after editing properties"
        $map["/基本操作/保存数据到SolidWorks.htm"] = "/Basic operations/Save data to SolidWorks.htm"
        $map["MKS(米、千克、秒)"] = "MKS (metre, kilogram, second)"
        $map["双击行自动填写到主界面，按del键可以删除选中行。"] = "Double-click a row to copy it to the main window; press Del to remove the selected row."
        $map["未找到SolidWorks"] = "SolidWorks not found"
        $map["授权电脑数量已达上限"] = "Maximum number of licensed computers reached"
        $map["注：更新保存以及3D模型转jpg、png、3D PDF、igs、step和stl格式`r`n时无效"] = "Note: not applied when saving updates or when converting 3D models to jpg, png, 3D PDF, igs, step or stl."
        # ZTool.Init.exe (initialization helper) strings
        $map["ZTool初始化"] = "ZTool Initialization"
        $map["加载成功"] = "Loaded successfully"
        $map["卸载成功"] = "Unloaded successfully"
        $map["加载到SolidWorks菜单"] = "Load to SolidWorks menu"
        $map["从SolidWorks菜单卸载"] = "Unload from SolidWorks menu"
        $map["加载成功,请重启SolidWorks！"] = "Loaded successfully, please restart SolidWorks!"
        $map["卸载成功,下次启动SolidWorks时将不再加载"] = "Unloaded successfully; will not load on next SolidWorks start"
        $map["嵌入SolidWorks菜单"] = "Integrate with SolidWorks menu"
        # ResourceManager base name used by ZTool.Init.exe (matches renamed resource ZTool.Init.Resources.resources)
        $map["ZTool初始化.Resources"] = "ZTool.Init.Resources"
    }

    # Long multi-line payload .resources strings (Update_log, regexhelp) live in
    # companion files under source/packaging/payload-resources/ so PowerShell
    # quoting doesn't have to handle 6+ KB of Chinese text. The companion files
    # preserve CRLF line endings, which the original .resources blob also uses.
    # Resolve the payload-resources companion-file directory. Callers that
    # load Get-StringMap via Invoke-Expression (Patch-PayloadResources in
    # Disable-ZToolEmbeddedUpdates.ps1, Get-InitStringMap in
    # Resign-ZToolInitExe.ps1) can set $Global:SwToolPayloadResourceTextRoot
    # before invoking, since $PSScriptRoot/$PSCommandPath are not populated
    # in that scope.
    $payloadResourceTextRoot = ''
    if ($null -ne $Global:SwToolPayloadResourceTextRoot -and -not [string]::IsNullOrWhiteSpace([string]$Global:SwToolPayloadResourceTextRoot)) {
        $payloadResourceTextRoot = [string]$Global:SwToolPayloadResourceTextRoot
    } else {
        $thisScriptPath = $PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($thisScriptPath)) {
            $thisScriptPath = $PSCommandPath
            if (-not [string]::IsNullOrWhiteSpace($thisScriptPath)) {
                $thisScriptPath = Split-Path -Parent $thisScriptPath
            }
        }
        if ([string]::IsNullOrWhiteSpace($thisScriptPath)) {
            $thisScriptPath = Join-Path (Get-Location) 'source\packaging\tools'
            if (-not (Test-Path -LiteralPath $thisScriptPath -PathType Container)) {
                $thisScriptPath = ''
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($thisScriptPath)) {
            $payloadResourceTextRoot = Join-Path $thisScriptPath '..\payload-resources'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($payloadResourceTextRoot) -and (Test-Path -LiteralPath $payloadResourceTextRoot -PathType Container)) {
        $langSuffix = if ($SelectedLanguage -eq 'Russian') { 'ru' } else { 'en' }
        $pairs = @(
            @{ Cn = 'Update_log.cn.txt'; Tr = "Update_log.$langSuffix.txt" },
            @{ Cn = 'regexhelp.cn.txt';  Tr = "regexhelp.$langSuffix.txt"  }
        )
        foreach ($pair in $pairs) {
            $cnPath = Join-Path $payloadResourceTextRoot $pair.Cn
            $trPath = Join-Path $payloadResourceTextRoot $pair.Tr
            if ((Test-Path -LiteralPath $cnPath -PathType Leaf) -and (Test-Path -LiteralPath $trPath -PathType Leaf)) {
                $cnText = [System.IO.File]::ReadAllText($cnPath, [System.Text.Encoding]::UTF8)
                $trText = [System.IO.File]::ReadAllText($trPath, [System.Text.Encoding]::UTF8)
                if (-not [string]::IsNullOrEmpty($cnText)) {
                    $map[$cnText] = $trText
                }
            }
        }
    }

    return $map
}

function Get-ManagedStringMap([string]$SelectedLanguage) {
    $map = [ordered]@{}
    if ($SelectedLanguage -eq 'Russian') {
        $map['3.8.4'] = '1.1'
        $map['开始'] = 'Гл'
        $map['明细表'] = 'BOM'
        $map['打包'] = 'Пк'
        $map['工具'] = 'Ин'
        $map['连接SW'] = 'SW'
        $map['保存到SW'] = 'Сохр.'
        $map['关闭文档'] = 'Закр'
        $map['显示复选框'] = 'Флаж'
        $map['包含符合项'] = 'Совп.'
        $map['快速筛选'] = 'Фил.'
        $map['填充文件名'] = 'Имена'
        $map['拆分列'] = 'Дел'
        $map['查找和替换'] = 'Найти'
        $map['前后缀'] = '+/-'
        $map['符号'] = 'См'
        $map['选项'] = 'Оп'
        $map['设置属性名称'] = 'Свойст'
        $map['单位'] = 'Ед'
        $map['自定义规则'] = 'Прав.'
        $map['隐藏/显示列'] = 'Кол.'
        $map['冻结列'] = 'Фик'
        $map['行高：'] = 'В:'
        $map['复制列'] = 'Коп'
        $map['填充列'] = 'Зап'
        $map['对比列'] = 'Ср.'
        $map['互换列'] = 'Обм'
        $map['自定义排序'] = 'Сорт.'
        $map['标记重复项'] = 'Дубли'
        $map['帮助'] = 'С?'
        $map['关于'] = 'О'
        $map['试用版不支持！'] = 'Нет дем'
        $map['试用版最多支持10个文件'] = 'Демо 10 шт'
        $map['试用中...剩余'] = 'Демо:'
        $map['试用时间到！软件将在10秒后自动关闭！'] = 'Демо истекло'
        $map['连接上次文档'] = 'Пред.'
        $map['连接当前文档'] = 'Текущ'
        $map['正在获取数据'] = 'Чтение'
        $map['连接完成，耗时 '] = 'Готово'
        $map['连接solidworks总时间'] = 'Время SW'
        $map['连接solidworks失败'] = 'SW ошибка'
        $map['注册码：'] = 'Код:'
        $map['注册信息'] = 'Лиц.'
        $map['请输入注册码'] = 'Код?'
        $map['无效注册码，请联系作者购买注册码'] = 'Неверный код'
        $map['该设备不具备注册条件！'] = 'Нет рег.'
        $map['试用'] = 'Дм'
        $map['注册'] = 'Кд'
        $map['双击选择需要连接的Solidworks进程'] = '2 щелчка: SW'
        $map['没有注册类，ProgID："'] = 'Нет ProgID:"'
        $map['连接超时'] = 'Тайм'
        $map['设置的SolidWorks版本不正确，请重新设置'] = 'Неверная версия SW'
        $map['当前SolidWorks版本调用失败！'] = 'Ошибка версии SW'
        $map['"ZToolARM.dll"丢失'] = 'Нет ZToolARM'
        $map['连接服务器超时'] = 'Таймаут'
        $map['连接服务器出错'] = 'Ошибка'
        $map['无效注册码'] = 'Код?'
        $map['注册失败'] = 'Сбой'
        $map['注册码已被其它电脑使用'] = 'Код занят'
        $map['注册码已过期'] = 'Истек'
        $map['注册信息错误'] = 'Код??'
        $map['注册申请失败'] = 'Сбой!'
        $map['注册信息保存错误'] = 'Не сохр'
        $map['注册成功'] = 'ОК'
        $map['此注册码没有转出权限'] = 'Нет перен'
        $map['ZTool检测更新'] = 'Обновл.'
        $map['连接服务器中...'] = 'Подкл...'
        $map['连接服务器失败！'] = 'Сервер'
        $map['当前已是最新版本！'] = 'Актуально'
        $map['发现新版本！' + "`r`n"] = 'Есть!' + "`r`n"
    } else {
        $map['3.8.4'] = '1.1'
        $map['开始'] = 'Go'
        $map['明细表'] = 'BOM'
        $map['打包'] = 'Pk'
        $map['工具'] = 'Tl'
        $map['连接SW'] = 'SW'
        $map['保存到SW'] = 'Save'
        $map['关闭文档'] = 'Clos'
        $map['显示复选框'] = 'Check'
        $map['包含符合项'] = 'Match'
        $map['快速筛选'] = 'Filt'
        $map['填充文件名'] = 'Names'
        $map['拆分列'] = 'Cut'
        $map['查找和替换'] = 'Find'
        $map['前后缀'] = '+/-'
        $map['符号'] = 'Sy'
        $map['选项'] = 'Op'
        $map['设置属性名称'] = 'Props'
        $map['单位'] = 'Un'
        $map['自定义规则'] = 'Rules'
        $map['隐藏/显示列'] = 'Cols'
        $map['冻结列'] = 'Fix'
        $map['行高：'] = 'H:'
        $map['复制列'] = 'Cpy'
        $map['填充列'] = 'Fil'
        $map['对比列'] = 'Cmp'
        $map['互换列'] = 'Swp'
        $map['自定义排序'] = 'Sort'
        $map['标记重复项'] = 'Dupes'
        $map['帮助'] = 'Hp'
        $map['关于'] = 'Ab'
        $map['试用版不支持！'] = 'No demo'
        $map['试用版最多支持10个文件'] = 'Demo:10'
        $map['试用中...剩余'] = 'Demo:'
        $map['试用时间到！软件将在10秒后自动关闭！'] = 'Demo expired'
        $map['连接上次文档'] = 'Prev'
        $map['连接当前文档'] = 'Active'
        $map['正在获取数据'] = 'Load..'
        $map['连接完成，耗时 '] = 'Done'
        $map['连接solidworks总时间'] = 'SW time'
        $map['连接solidworks失败'] = 'SW failed'
        $map['注册码：'] = 'Key:'
        $map['注册信息'] = 'Lic.'
        $map['请输入注册码'] = 'Key?'
        $map['无效注册码，请联系作者购买注册码'] = 'Invalid key'
        $map['该设备不具备注册条件！'] = 'Not elig.'
        $map['试用'] = 'Go'
        $map['注册'] = 'OK'
        $map['双击选择需要连接的Solidworks进程'] = 'Double-click SW'
        $map['没有注册类，ProgID："'] = 'No ProgID:"'
        $map['连接超时'] = 'Wait'
        $map['设置的SolidWorks版本不正确，请重新设置'] = 'Invalid SW version'
        $map['当前SolidWorks版本调用失败！'] = 'SW version failed'
        $map['"ZToolARM.dll"丢失'] = 'No ZToolARM'
        $map['连接服务器超时'] = 'Timeout'
        $map['连接服务器出错'] = 'Error'
        $map['无效注册码'] = 'Bad'
        $map['注册失败'] = 'Fail'
        $map['注册码已被其它电脑使用'] = 'Key used'
        $map['注册码已过期'] = 'Expiry'
        $map['注册信息错误'] = 'Key?'
        $map['注册申请失败'] = 'ReqErr'
        $map['注册信息保存错误'] = 'Save err'
        $map['注册成功'] = 'Done'
        $map['此注册码没有转出权限'] = 'No trans'
        $map['ZTool检测更新'] = 'Updates'
        $map['连接服务器中...'] = 'Connect.'
        $map['连接服务器失败！'] = 'SrvFail'
        $map['当前已是最新版本！'] = 'Current'
        $map['发现新版本！' + "`r`n"] = 'Update' + "`r`n"
    }

    return $map
}

function Test-NativeRuntimeStarts([string]$ExePath) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ExePath
    $psi.WorkingDirectory = [System.IO.Path]::GetDirectoryName($ExePath)
    $psi.Arguments = '33 0 0 0'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        if ($process.WaitForExit(5000)) {
            if ($process.ExitCode -ne 0) {
                $stderr = $process.StandardError.ReadToEnd()
                $stdout = $process.StandardOutput.ReadToEnd()
                throw "Native runtime start failed with exit code $($process.ExitCode). $stderr $stdout"
            }
        } else {
            try { $process.Kill() } catch {}
        }
    } finally {
        $process.Dispose()
        Get-Process ZTool -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

Ensure-DnlibLoaded

$packageFull = Resolve-FullPath $PackageRoot
$exePath = Join-Path $packageFull 'ZTool.exe'
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "ZTool.exe not found: $exePath"
}

$beforeHash = Get-FileSha256 $exePath
$payloadResourceName = 'ZTool.9eAd0SlNKphk.png'
$exeModule = [dnlib.DotNet.ModuleDefMD]::Load($exePath)
try {
    $encryptedPayload = Read-EmbeddedResourceBytes $exeModule $payloadResourceName
} finally {
    $exeModule.Dispose()
}

$payloadBytes = ConvertFrom-ZToolPayloadResource $encryptedPayload
$payloadTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("swtool-native-payload-" + [guid]::NewGuid().ToString('N') + '.dll')
[System.IO.File]::WriteAllBytes($payloadTemp, $payloadBytes)

# This script's in-place patch path requires the encrypted-payload byte length
# to stay constant (Find-Bytes + Array.Copy pad-to-old). Embedded .resources
# blobs cannot be safely patched here when Chinese -> RU/EN changes the byte
# length, so this list is intentionally empty. The authoritative resource
# patcher is Patch-PayloadResources in Disable-ZToolEmbeddedUpdates.ps1, which
# uses dnlib's EmbeddedResource replacement and handles arbitrary sizes.
$resourcesToPatch = @()

$map = Get-StringMap $Language
$mapPath = Join-Path ([System.IO.Path]::GetTempPath()) ("swtool-resource-map-" + [guid]::NewGuid().ToString('N') + '.tsv')
($map.GetEnumerator() | ForEach-Object { "$($_.Key)`t$($_.Value)" }) |
    Set-Content -LiteralPath $mapPath -Encoding UTF8

$helper = Get-ResourcePatchHelper
$patches = New-Object System.Collections.Generic.List[object]

try {
    $payloadModule = [dnlib.DotNet.ModuleDefMD]::Load($payloadTemp)
    try {
        foreach ($resourceName in $resourcesToPatch) {
            $oldResource = Read-EmbeddedResourceBytes $payloadModule $resourceName
            $oldResourcePath = Join-Path ([System.IO.Path]::GetTempPath()) ("swtool-old-" + [guid]::NewGuid().ToString('N') + '.resources')
            $newResourcePath = Join-Path ([System.IO.Path]::GetTempPath()) ("swtool-new-" + [guid]::NewGuid().ToString('N') + '.resources')
            [System.IO.File]::WriteAllBytes($oldResourcePath, $oldResource)
            try {
                $changedText = (& $helper $oldResourcePath $newResourcePath $mapPath | ForEach-Object { [string]$_ }) -join "`n"
                if ($LASTEXITCODE -ne 0) {
                    throw "Resource helper failed for $resourceName"
                }

                $newResource = [System.IO.File]::ReadAllBytes($newResourcePath)
                if ($newResource.Length -gt $oldResource.Length) {
                    throw "$resourceName grew from $($oldResource.Length) to $($newResource.Length); refusing to shift native payload metadata."
                }

                $padded = [byte[]]::new($oldResource.Length)
                [Array]::Copy($newResource, $padded, $newResource.Length)
                $offset = Find-Bytes $payloadBytes $oldResource
                if ($offset -lt 0) {
                    throw "$resourceName blob was not found in decrypted payload."
                }

                [Array]::Copy($padded, 0, $payloadBytes, $offset, $padded.Length)
                $patches.Add([pscustomobject]@{
                    Resource = $resourceName
                    OriginalLength = $oldResource.Length
                    NewLength = $newResource.Length
                    Offset = $offset
                    ChangedStrings = [int]$changedText.Trim()
                })
            } finally {
                Remove-Item -LiteralPath $oldResourcePath, $newResourcePath -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        $payloadModule.Dispose()
    }
} finally {
    Remove-Item -LiteralPath $payloadTemp, $mapPath -Force -ErrorAction SilentlyContinue
}

$managedStringPatches = New-Object System.Collections.Generic.List[object]
# Commented out to prevent shortened binary translations since we do full IL translations instead.
# foreach ($entry in (Get-ManagedStringMap $Language).GetEnumerator()) {
#     $oldValue = [string]$entry.Key
#     $newValue = [string]$entry.Value
#     $oldBytes = [System.Text.Encoding]::Unicode.GetBytes($oldValue)
#     $newBytes = ConvertTo-FixedUtf16Bytes $oldValue $newValue
#     $count = Set-BytesEverywhere $payloadBytes $oldBytes $newBytes
#     if ($count -gt 0) {
#         $managedStringPatches.Add([pscustomobject]@{
#             Old = $oldValue
#             New = $newValue
#             Count = $count
#         })
#     }
# }

$newEncryptedPayload = ConvertTo-ZToolPayloadResource $payloadBytes
if ($newEncryptedPayload.Length -ne $encryptedPayload.Length) {
    throw "Encrypted payload length changed from $($encryptedPayload.Length) to $($newEncryptedPayload.Length)."
}

$exeBytes = [System.IO.File]::ReadAllBytes($exePath)
$payloadOffset = Find-Bytes $exeBytes $encryptedPayload
if ($payloadOffset -lt 0) {
    throw 'Encrypted payload blob was not found in ZTool.exe.'
}

[Array]::Copy($newEncryptedPayload, 0, $exeBytes, $payloadOffset, $newEncryptedPayload.Length)

$outerStringPatches = New-Object System.Collections.Generic.List[object]
$outerVersionUtf16 = Set-BytesEverywhere `
    $exeBytes `
    ([System.Text.Encoding]::Unicode.GetBytes('3.8.4')) `
    ([System.Text.Encoding]::Unicode.GetBytes('1.1  '))
if ($outerVersionUtf16 -gt 0) {
    $outerStringPatches.Add([pscustomobject]@{
        Old = '3.8.4'
        New = '1.1'
        Encoding = 'UTF-16'
        Count = $outerVersionUtf16
    })
}
$outerVersionUtf8 = Set-BytesEverywhere `
    $exeBytes `
    ([System.Text.Encoding]::UTF8.GetBytes('3.8.4')) `
    ([System.Text.Encoding]::UTF8.GetBytes('1.1  '))
if ($outerVersionUtf8 -gt 0) {
    $outerStringPatches.Add([pscustomobject]@{
        Old = '3.8.4'
        New = '1.1'
        Encoding = 'UTF-8'
        Count = $outerVersionUtf8
    })
}
[System.IO.File]::WriteAllBytes($exePath, $exeBytes)

Test-NativeRuntimeStarts $exePath

[pscustomobject]@{
    Status = 'ok'
    PackageRoot = $packageFull
    Language = $Language
    BeforeHash = $beforeHash
    AfterHash = Get-FileSha256 $exePath
    PayloadResource = $payloadResourceName
    EncryptedPayloadOffset = $payloadOffset
    Patches = $patches
    ManagedStringPatches = $managedStringPatches
    OuterStringPatches = $outerStringPatches
} | ConvertTo-Json -Depth 5
