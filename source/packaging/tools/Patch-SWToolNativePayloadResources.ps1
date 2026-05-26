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
    public static int Main(string[] args)
    {
        if (args.Length != 3)
        {
            Console.Error.WriteLine("usage: <input.resources> <output.resources> <map.tsv>");
            return 2;
        }

        var map = new Dictionary<string, string>();
        foreach (string line in File.ReadAllLines(args[2], Encoding.UTF8))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            int tab = line.IndexOf('\t');
            if (tab <= 0) continue;
            map[line.Substring(0, tab)] = line.Substring(tab + 1);
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
    $map = [ordered]@{}
    if ($SelectedLanguage -eq 'Russian') {
        $map['路径'] = 'Путь'
        $map['开始'] = 'Главная'
        $map['明细表'] = 'Спецификация'
        $map['打包'] = 'Пакет'
        $map['工具'] = 'Инструменты'
        $map['连接SW'] = 'Подключить SW'
        $map['保存到SW'] = 'Сохранить в SW'
        $map['关闭文档'] = 'Закрыть документ'
        $map['显示复选框'] = 'Показать флажки'
        $map['包含符合项'] = 'Включать совпадения'
        $map['快速筛选'] = 'Быстрый фильтр'
        $map['填充文件名'] = 'Заполнить имена'
        $map['拆分列'] = 'Разделить столбец'
        $map['查找和替换'] = 'Найти и заменить'
        $map['前后缀'] = 'Префикс/суффикс'
        $map['符号'] = 'Символы'
        $map['语言'] = 'Язык'
        $map['中文'] = 'Китайский'
        $map['英文'] = 'Английский'
        $map['俄文'] = 'Русский'
        $map['Russian'] = 'Русский'
        $map['English'] = 'Английский'
        $map['保存时间'] = 'Сохранено'
        $map['数量'] = 'Кол-во'
        $map['磁盘文件名'] = 'Файл'
        $map['统计数量'] = 'Кол-во'
        $map['BOM报表'] = 'BOM'
        $map['BOM零件号'] = 'BOM N'
        $map['创建时间'] = 'Создан'
        $map['单重_Kg'] = 'Кг/шт'
        $map['单重(Kg)'] = 'Кг/шт'
        $map['压缩零部件（&S）(支持多选)'] = 'Погасить'
        $map['只显示该节点及其子项'] = 'Узел+дети'
        $map['只显示该节点的子项'] = 'Дети узла'
        $map['只显示该节点的顶层子项'] = 'Верх. дети'
        $map['在solidworks中选中'] = 'Выбрать в SW'
        $map['在使用为子装配体时子零部件的显示'] = 'Показ деталей'
        $map['复选框'] = 'Флажок'
        $map['外形尺寸'] = 'Габариты'
        $map['层级'] = 'Уровень'
        $map['展开所有'] = 'Развернуть'
        $map['属性表达式'] = 'Выражение'
        $map['工程图'] = 'Чертеж'
        $map['序号'] = 'N'
        $map['折叠所有'] = 'Свернуть'
        $map['提升'] = 'Поднять'
        $map['摘要_主题'] = 'Тема'
        $map['摘要_作者'] = 'Автор'
        $map['摘要_关键字'] = 'Ключи'
        $map['摘要_备注'] = 'Заметки'
        $map['摘要_标题'] = 'Заголовок'
        $map['文档类型'] = 'Тип'
        $map['显示'] = 'Показать'
        $map['材质'] = 'Материал'
        $map['缩略图'] = 'Эскиз'
        $map['解除压缩（&U）(支持多选)'] = 'Вернуть'
        $map['配置'] = 'Конфиг.'
        $map['隐藏'] = 'Скрыть'
        $map['保存到文件夹'] = 'Сохр. в папку'
        $map['不包括在材料明细表中（&E）(支持多选)'] = 'Исключить из BOM'
        $map['包含在材料明细表中（&I）(支持多选)'] = 'Включить в BOM'
        $map['在solidworks中打开'] = 'Открыть в SW'
        $map['确定'] = 'OK'
        $map['取消'] = 'Отм.'
        $map['选项'] = 'Опции'
        $map['设置'] = 'Настройки'
        $map['关于'] = 'О программе'
        $map['退出'] = 'Выход'
        $map['打开'] = 'Открыть'
        $map['保存'] = 'Сохранить'
        $map['刷新'] = 'Обновить'
        $map['导入'] = 'Импорт'
        $map['导出'] = 'Экспорт'
        $map['打印'] = 'Печать'
        $map['替换'] = 'Заменить'
        $map['查找'] = 'Найти'
        $map['实时筛选'] = 'Фильтр'
        $map['上移'] = 'Вверх'
        $map['下移'] = 'Вниз'
        $map['默认设置'] = 'Сброс'
        $map['添加文件'] = 'Добав.'
        $map['打开插件根目录'] = 'Папка'
        $map['打开默认目录'] = 'Каталог'
        $map['打开日志文件路径'] = 'Журнал'
        $map['SolidWorks版本：'] = 'SW:'
        $map['API接口测速'] = 'API тест'
        $map['Windows默认'] = 'Windows'
        $map['下拉列表：'] = 'Список:'
        $map['使用材质颜色'] = 'Цвет матер.'
        $map['其它'] = 'Прочее'
        $map['列标题：'] = 'Колонка:'
        $map['创建桌面快捷方式'] = 'Ярлык'
        $map['初始化表格'] = 'Сброс таблицы'
        $map['双击图标在SOLIDWORKS中打开零部件或工程图'] = 'Двойной щелчок открывает в SW'
        $map['启动时检查更新'] = 'Проверять обнов.'
        $map['在左侧选中属性列，在右侧添加该列的下拉 数据，每行一个。'] = 'Слева колонка, справа список.'
        $map['宏列表'] = 'Макросы'
        $map['将此材质库添加到solidworks'] = 'Добавить в SW'
        $map['展开材质列表到同一级'] = 'Развернуть материалы'
        $map['常规'] = 'Общие'
        $map['所选行高亮显示：'] = 'Цвет строки:'
        $map['批量工具开启文件预览'] = 'Предпросмотр'
        $map['批量工具操作时隐藏SolidWorks界面'] = 'Скрывать SW'
        $map['批量缩略图方案：'] = 'Эскизы:'
        $map['插入缩略图时将其保存到:'] = 'Сохр. эскиз в:'
        $map['搜索已添加到solidworks的材质库'] = 'Искать матер. SW'
        $map['浏览材质库'] = 'Материалы'
        $map['移除选中'] = 'Удалить'
        $map['缩略图快捷键：'] = 'Горячая клав.:'
        $map['自定义下拉'] = 'Свои списки'
        $map['自定义材质文件：'] = 'Файл матер.:'
        $map['读取每一个配置的属性（仅对零件有效）'] = 'Читать все конфиги'
        $map['重新连接SW后清除筛选'] = 'Очищать фильтр'
        $map['重置缩略图位置'] = 'Сброс эскиза'
        $map['零部件目录'] = 'Папка деталей'
        $map['高清模式'] = 'HD режим'
        $map['默认目录'] = 'Каталог'
    } else {
        $map['路径'] = 'Path'
        $map['开始'] = 'Home'
        $map['明细表'] = 'BOM'
        $map['打包'] = 'Pack'
        $map['工具'] = 'Tools'
        $map['连接SW'] = 'Connect SW'
        $map['保存到SW'] = 'Save to SW'
        $map['关闭文档'] = 'Close document'
        $map['显示复选框'] = 'Show checkboxes'
        $map['包含符合项'] = 'Include matches'
        $map['快速筛选'] = 'Quick filter'
        $map['填充文件名'] = 'Fill filenames'
        $map['拆分列'] = 'Split column'
        $map['查找和替换'] = 'Find and replace'
        $map['前后缀'] = 'Prefix/suffix'
        $map['符号'] = 'Symbols'
        $map['语言'] = 'Language'
        $map['中文'] = 'Chinese'
        $map['英文'] = 'English'
        $map['俄文'] = 'Russian'
        $map['Russian'] = 'Russian'
        $map['English'] = 'English'
        $map['保存时间'] = 'Saved'
        $map['数量'] = 'Qty'
        $map['磁盘文件名'] = 'File'
        $map['统计数量'] = 'Count'
        $map['BOM报表'] = 'BOM'
        $map['BOM零件号'] = 'BOM No.'
        $map['创建时间'] = 'Created'
        $map['单重_Kg'] = 'Kg/pc'
        $map['单重(Kg)'] = 'Kg/pc'
        $map['压缩零部件（&S）(支持多选)'] = 'Suppress'
        $map['只显示该节点及其子项'] = 'Node+children'
        $map['只显示该节点的子项'] = 'Children'
        $map['只显示该节点的顶层子项'] = 'Top children'
        $map['在solidworks中选中'] = 'Select in SW'
        $map['在使用为子装配体时子零部件的显示'] = 'Child display'
        $map['复选框'] = 'Checkbox'
        $map['外形尺寸'] = 'Size'
        $map['层级'] = 'Level'
        $map['展开所有'] = 'Expand all'
        $map['属性表达式'] = 'Expression'
        $map['工程图'] = 'Drawing'
        $map['序号'] = 'No.'
        $map['折叠所有'] = 'Collapse all'
        $map['提升'] = 'Promote'
        $map['摘要_主题'] = 'Subject'
        $map['摘要_作者'] = 'Author'
        $map['摘要_关键字'] = 'Keywords'
        $map['摘要_备注'] = 'Comments'
        $map['摘要_标题'] = 'Title'
        $map['文档类型'] = 'Doc type'
        $map['显示'] = 'Show'
        $map['材质'] = 'Material'
        $map['缩略图'] = 'Preview'
        $map['解除压缩（&U）(支持多选)'] = 'Unsuppress'
        $map['配置'] = 'Config'
        $map['隐藏'] = 'Hide'
        $map['保存到文件夹'] = 'Save to folder'
        $map['不包括在材料明细表中（&E）(支持多选)'] = 'Exclude from BOM'
        $map['包含在材料明细表中（&I）(支持多选)'] = 'Include in BOM'
        $map['在solidworks中打开'] = 'Open in SW'
        $map['确定'] = 'OK'
        $map['取消'] = 'Cancel'
        $map['选项'] = 'Options'
        $map['设置'] = 'Settings'
        $map['关于'] = 'About'
        $map['退出'] = 'Exit'
        $map['打开'] = 'Open'
        $map['保存'] = 'Save'
        $map['刷新'] = 'Refresh'
        $map['导入'] = 'Import'
        $map['导出'] = 'Export'
        $map['打印'] = 'Print'
        $map['替换'] = 'Replace'
        $map['查找'] = 'Find'
        $map['实时筛选'] = 'Live filter'
        $map['上移'] = 'Up'
        $map['下移'] = 'Down'
        $map['默认设置'] = 'Defaults'
        $map['添加文件'] = 'Add file'
        $map['打开插件根目录'] = 'Plugin folder'
        $map['打开默认目录'] = 'Open folder'
        $map['打开日志文件路径'] = 'Log folder'
        $map['SolidWorks版本：'] = 'SW version:'
        $map['API接口测速'] = 'API test'
        $map['Windows默认'] = 'Windows'
        $map['下拉列表：'] = 'List:'
        $map['使用材质颜色'] = 'Material color'
        $map['其它'] = 'Other'
        $map['列标题：'] = 'Column:'
        $map['创建桌面快捷方式'] = 'Desktop shortcut'
        $map['初始化表格'] = 'Reset table'
        $map['双击图标在SOLIDWORKS中打开零部件或工程图'] = 'Double-click opens in SW'
        $map['启动时检查更新'] = 'Check updates'
        $map['在左侧选中属性列，在右侧添加该列的下拉 数据，每行一个。'] = 'Pick a column, then add list values.'
        $map['宏列表'] = 'Macros'
        $map['将此材质库添加到solidworks'] = 'Add to SW'
        $map['展开材质列表到同一级'] = 'Expand materials'
        $map['常规'] = 'General'
        $map['所选行高亮显示：'] = 'Row highlight:'
        $map['批量工具开启文件预览'] = 'Enable preview'
        $map['批量工具操作时隐藏SolidWorks界面'] = 'Hide SW during batch'
        $map['批量缩略图方案：'] = 'Preview mode:'
        $map['插入缩略图时将其保存到:'] = 'Save preview to:'
        $map['搜索已添加到solidworks的材质库'] = 'Search SW materials'
        $map['浏览材质库'] = 'Browse materials'
        $map['移除选中'] = 'Remove selected'
        $map['缩略图快捷键：'] = 'Preview hotkey:'
        $map['自定义下拉'] = 'Custom lists'
        $map['自定义材质文件：'] = 'Material file:'
        $map['读取每一个配置的属性（仅对零件有效）'] = 'Read all configs'
        $map['重新连接SW后清除筛选'] = 'Clear filter on reconnect'
        $map['重置缩略图位置'] = 'Reset preview position'
        $map['零部件目录'] = 'Component folder'
        $map['高清模式'] = 'HD mode'
        $map['默认目录'] = 'Default folder'
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

$resourcesToPatch = @(
    'ZTool.Frmmain.resources',
    'ZTool.FrmOptions.resources'
)

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
foreach ($entry in (Get-ManagedStringMap $Language).GetEnumerator()) {
    $oldValue = [string]$entry.Key
    $newValue = [string]$entry.Value
    $oldBytes = [System.Text.Encoding]::Unicode.GetBytes($oldValue)
    $newBytes = ConvertTo-FixedUtf16Bytes $oldValue $newValue
    $count = Set-BytesEverywhere $payloadBytes $oldBytes $newBytes
    if ($count -gt 0) {
        $managedStringPatches.Add([pscustomobject]@{
            Old = $oldValue
            New = $newValue
            Count = $count
        })
    }
}

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
