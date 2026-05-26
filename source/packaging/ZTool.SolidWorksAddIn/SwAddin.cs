using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Xml;
using SolidWorks.Interop.sldworks;
using SolidWorks.Interop.swconst;
using SolidWorks.Interop.swpublished;

[assembly: AssemblyTitle("SWTool SolidWorks Add-in")]
[assembly: AssemblyDescription("SolidWorks add-in adapter for SWTool")]
[assembly: AssemblyCompany("Lunin V.I.")]
[assembly: AssemblyProduct("SWTool")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]
[assembly: ComVisible(true)]

namespace ZTool
{
    [ComVisible(true)]
    [Guid("59959DFA-3229-4B86-852E-52ABF2BDB8C0")]
    [ProgId("ZTool.SwAddin")]
    public sealed class SwAddin : ISwAddin
    {
        private const int MainGroupId = 59959;
        private ISldWorks swApp;
        private int addinCookie;
        private string currentLanguage = "Russian";
        private string lastError = string.Empty;
        private int[] commandIndexes = new int[0];

        private static readonly CommandSpec[] Commands =
        {
            new CommandSpec(0, "Rename components", "Переименование", "Rename components", "Переименование компонентов", 0),
            new CommandSpec(1, "Sync to part folder", "Синхронизация", "Sync to part folder", "Синхронизация с папкой детали", 1),
            new CommandSpec(2, "Split configurations", "Конфигурации", "Split configurations", "Разделение конфигураций", 2),
            new CommandSpec(3, "Temporary numbers", "Нумерация", "Temporary numbers", "Временная нумерация", 3),
            new CommandSpec(4, "Save selected", "Сохранить", "Save selected components", "Сохранить выбранные компоненты", 4),
            new CommandSpec(5, "References", "Ссылки", "Replace references", "Замена ссылок", 5),
            new CommandSpec(6, "Drawing names", "Чертежи", "Synchronize drawing names", "Синхронизация имён чертежей", 6),
            new CommandSpec(120, "Update", "Обновить", "Update", "Обновление", 7),
            new CommandSpec(130, "About", "О программе", "About SWTool", "О программе SWTool", 8)
        };

        public bool ConnectToSW(object ThisSW, int Cookie)
        {
            try
            {
                swApp = (ISldWorks)ThisSW;
                addinCookie = Cookie;
                swApp.SetAddinCallbackInfo2(0, this, addinCookie);
                CreateCommandManager();
                Log("ConnectToSW ok; language=" + currentLanguage);
                return true;
            }
            catch (Exception ex)
            {
                lastError = ex.ToString();
                Log("ConnectToSW failed: " + ex);
                return false;
            }
        }

        public bool DisconnectFromSW()
        {
            try
            {
                var cmdMgr = swApp != null ? swApp.GetCommandManager(addinCookie) : null;
                if (cmdMgr != null)
                {
                    foreach (int documentType in GetDocumentTypes())
                    {
                        RemoveTabsByName(cmdMgr, documentType, "SWTool");
                        RemoveTabsByName(cmdMgr, documentType, "ZTool");
                    }

                    cmdMgr.RemoveCommandGroup2(MainGroupId, true);
                }
            }
            catch (Exception ex)
            {
                Log("Disconnect cleanup failed: " + ex.Message);
            }

            swApp = null;
            return true;
        }

        public void OpenCommand0() { openZtool(0); }
        public void OpenCommand1() { openZtool(1); }
        public void OpenCommand2() { openZtool(2); }
        public void OpenCommand3() { openZtool(3); }
        public void OpenCommand4() { openZtool(4); }
        public void OpenCommand5() { openZtool(5); }
        public void OpenCommand6() { openZtool(6); }
        public void OpenCommand120() { openZtool(120); }
        public void OpenCommand130() { openZtool(130); }

        public int EnableCommand() { return 1; }

        public void openZtool(int commandId)
        {
            try
            {
                string baseDir = GetBaseDirectory();
                string exePath = Path.Combine(baseDir, "ZTool.exe");
                if (!File.Exists(exePath))
                {
                    throw new FileNotFoundException("ZTool.exe was not found.", exePath);
                }

                int swMajor = GetSolidWorksMajorVersion();
                int swProcessId = swApp != null ? swApp.GetProcessID() : 0;
                long frameHandle = GetFrameHandle();
                string arguments = string.Join(" ", new[]
                {
                    swMajor.ToString(CultureInfo.InvariantCulture),
                    swProcessId.ToString(CultureInfo.InvariantCulture),
                    commandId.ToString(CultureInfo.InvariantCulture),
                    frameHandle.ToString(CultureInfo.InvariantCulture)
                });

                var startInfo = new ProcessStartInfo
                {
                    FileName = exePath,
                    Arguments = arguments,
                    WorkingDirectory = baseDir,
                    UseShellExecute = false
                };
                Process.Start(startInfo);
                Log("openZtool commandId=" + commandId + " args=" + arguments);
            }
            catch (Exception ex)
            {
                lastError = ex.ToString();
                Log("openZtool failed: " + ex);
            }
        }

        public string GetCurrentLanguage() { return currentLanguage; }

        public string GetLastError() { return lastError ?? string.Empty; }

        public string GetCommandLabels()
        {
            bool english = IsEnglish();
            var labels = new List<string>();
            foreach (var command in Commands)
            {
                labels.Add(english ? command.NameEn : command.NameRu);
            }

            return string.Join("|", labels.ToArray());
        }

        public string GetCommandTabReport()
        {
            try
            {
                var cmdMgr = swApp != null ? swApp.GetCommandManager(addinCookie) : null;
                if (cmdMgr == null)
                {
                    return "CommandManager=null";
                }

                var parts = new List<string>();
                foreach (int documentType in GetDocumentTypes())
                {
                    parts.Add(
                        documentType.ToString(CultureInfo.InvariantCulture) +
                        ":SWTool=" + (cmdMgr.GetCommandTab(documentType, "SWTool") != null ? "1" : "0") +
                        ",ZTool=" + (cmdMgr.GetCommandTab(documentType, "ZTool") != null ? "1" : "0"));
                }

                return string.Join("|", parts.ToArray());
            }
            catch (Exception ex)
            {
                lastError = ex.ToString();
                return "error:" + ex.Message;
            }
        }

        private void CreateCommandManager()
        {
            currentLanguage = GetConfiguredLanguage();
            var cmdMgr = swApp.GetCommandManager(addinCookie);
            if (cmdMgr == null)
            {
                throw new InvalidOperationException("SolidWorks CommandManager is not available.");
            }

            foreach (int documentType in GetDocumentTypes())
            {
                RemoveTabsByName(cmdMgr, documentType, "ZTool");
                RemoveTabsByName(cmdMgr, documentType, "SWTool");
            }

            try { cmdMgr.RemoveCommandGroup2(MainGroupId, true); } catch { }

            int errors = 0;
            var group = cmdMgr.CreateCommandGroup2(
                MainGroupId,
                "SWTool",
                "SWTool",
                "SWTool",
                -1,
                true,
                ref errors);

            if (group == null)
            {
                throw new InvalidOperationException("CreateCommandGroup2 returned null; errors=" + errors);
            }
            Log("CreateCommandGroup2 ok; errors=" + errors);

            group.ShowInDocumentType =
                (int)swDocTemplateTypes_e.swDocTemplateTypePART |
                (int)swDocTemplateTypes_e.swDocTemplateTypeASSEMBLY |
                (int)swDocTemplateTypes_e.swDocTemplateTypeDRAWING;

            string iconList = ResolveIconList();
            if (!string.IsNullOrEmpty(iconList))
            {
                group.IconList = iconList;
                group.MainIconList = iconList;
                group.SmallIconList = iconList;
                group.LargeIconList = iconList;
                group.SmallMainIcon = iconList;
                group.LargeMainIcon = iconList;
            }

            bool english = IsEnglish();
            commandIndexes = new int[Commands.Length];
            for (int i = 0; i < Commands.Length; i++)
            {
                var command = Commands[i];
                string callback = "OpenCommand" + command.Id.ToString(CultureInfo.InvariantCulture);
                string name = english ? command.NameEn : command.NameRu;
                string tip = english ? command.TooltipEn : command.TooltipRu;
                int commandIndex = group.AddCommandItem2(
                    name,
                    -1,
                    tip,
                    tip,
                    command.ImageIndex,
                    callback,
                    "EnableCommand",
                    command.Id,
                    (int)swCommandItemType_e.swMenuItem | (int)swCommandItemType_e.swToolbarItem);
                commandIndexes[i] = commandIndex;
                Log("AddCommandItem2 commandId=" + command.Id + " index=" + commandIndex + " name=" + name);
            }

            group.HasToolbar = true;
            group.HasMenu = true;
            group.Activate();
            Log("Command group activated; toolbarId=" + group.ToolbarId);

            foreach (int documentType in GetDocumentTypes())
            {
                AddTab(cmdMgr, documentType, group);
            }

            Log("CreateCommandManager ok; labels=" + GetCommandLabels() + "; tabs=" + GetCommandTabReport());
        }

        private void AddTab(ICommandManager cmdMgr, int documentType, ICommandGroup group)
        {
            var tab = cmdMgr.AddCommandTab(documentType, "SWTool");
            if (tab == null)
            {
                tab = cmdMgr.GetCommandTab(documentType, "SWTool");
            }

            if (tab == null)
            {
                throw new InvalidOperationException("Command tab was not created for documentType=" + documentType);
            }

            var box = tab.AddCommandTabBox();
            var ids = new int[Commands.Length];
            var textTypes = new int[Commands.Length];
            for (int i = 0; i < Commands.Length; i++)
            {
                int commandIndex = commandIndexes != null && i < commandIndexes.Length ? commandIndexes[i] : i;
                ids[i] = group.get_CommandID(commandIndex);
                textTypes[i] = (int)swCommandTabButtonTextDisplay_e.swCommandTabButton_TextBelow;
            }

            bool added = box.AddCommands(ids, textTypes);
            Log(
                "AddCommands documentType=" + documentType +
                " added=" + added +
                " ids=" + string.Join(",", Array.ConvertAll(ids, x => x.ToString(CultureInfo.InvariantCulture))));

            object existingIds;
            object existingTextTypes;
            int buttonCount = box.GetCommands(out existingIds, out existingTextTypes);
            Log("CommandTabBox documentType=" + documentType + " buttonCount=" + buttonCount);

            if (!added)
            {
                throw new InvalidOperationException("Command tab commands were not added for documentType=" + documentType);
            }

            tab.Visible = true;
            tab.Active = true;
            Log(
                "CommandTab documentType=" + documentType +
                " visible=" + tab.Visible +
                " active=" + tab.Active +
                " boxes=" + tab.GetCommandTabBoxCount());
        }

        private static int[] GetDocumentTypes()
        {
            return new[]
            {
                (int)swDocumentTypes_e.swDocPART,
                (int)swDocumentTypes_e.swDocASSEMBLY,
                (int)swDocumentTypes_e.swDocDRAWING
            };
        }

        private void RemoveTabsByName(ICommandManager cmdMgr, int documentType, string tabName)
        {
            for (int attempt = 0; attempt < 20; attempt++)
            {
                var tab = cmdMgr.GetCommandTab(documentType, tabName);
                if (tab == null)
                {
                    return;
                }

                if (!cmdMgr.RemoveCommandTab(tab))
                {
                    return;
                }
            }
        }

        private int GetSolidWorksMajorVersion()
        {
            try
            {
                string revision = swApp != null ? swApp.RevisionNumber() : string.Empty;
                if (!string.IsNullOrWhiteSpace(revision))
                {
                    string[] parts = revision.Split('.');
                    int major;
                    if (parts.Length > 0 && int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out major))
                    {
                        return major;
                    }
                }
            }
            catch { }

            return 0;
        }

        private long GetFrameHandle()
        {
            try
            {
                var frame = swApp != null ? swApp.Frame() as IFrame : null;
                if (frame != null)
                {
                    return frame.GetHWndx64();
                }
            }
            catch { }

            return 0;
        }

        private static string GetBaseDirectory()
        {
            string location = Assembly.GetExecutingAssembly().Location;
            string dir = Path.GetDirectoryName(location);
            return string.IsNullOrEmpty(dir) ? AppDomain.CurrentDomain.BaseDirectory : dir;
        }

        private static string ResolveIconList()
        {
            string candidate = Path.Combine(GetBaseDirectory(), "ZTool.bmp");
            return File.Exists(candidate) ? candidate : string.Empty;
        }

        private static bool IsEnglish()
        {
            return string.Equals(GetConfiguredLanguage(), "English", StringComparison.OrdinalIgnoreCase);
        }

        private static string GetConfiguredLanguage()
        {
            try
            {
                string settings = Path.Combine(GetBaseDirectory(), "ZTool.settings");
                if (File.Exists(settings))
                {
                    var doc = new XmlDocument();
                    doc.Load(settings);
                    var node = doc.SelectSingleNode("//Language");
                    if (node != null && string.Equals(node.InnerText, "English", StringComparison.OrdinalIgnoreCase))
                    {
                        return "English";
                    }
                }
            }
            catch { }

            return "Russian";
        }

        private static void Log(string message)
        {
            try
            {
                string dir = Path.Combine(
                    System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData),
                    "SWTools");
                Directory.CreateDirectory(dir);
                File.AppendAllText(
                    Path.Combine(dir, "SWTool.SolidWorksAddIn.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture) + " " + message + System.Environment.NewLine);
            }
            catch { }
        }

        private sealed class CommandSpec
        {
            public readonly int Id;
            public readonly string NameEn;
            public readonly string NameRu;
            public readonly string TooltipEn;
            public readonly string TooltipRu;
            public readonly int ImageIndex;

            public CommandSpec(int id, string nameEn, string nameRu, string tooltipEn, string tooltipRu, int imageIndex)
            {
                Id = id;
                NameEn = nameEn;
                NameRu = nameRu;
                TooltipEn = tooltipEn;
                TooltipRu = tooltipRu;
                ImageIndex = imageIndex;
            }
        }
    }
}
