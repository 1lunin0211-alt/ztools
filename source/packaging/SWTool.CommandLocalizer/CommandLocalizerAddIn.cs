using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Xml;
using SolidWorks.Interop.sldworks;
using SolidWorks.Interop.swconst;
using SolidWorks.Interop.swpublished;

[assembly: AssemblyTitle("SWTool Command Localizer")]
[assembly: AssemblyDescription("Localized SolidWorks CommandManager for SWTool")]
[assembly: AssemblyCompany("Lunin V.I.")]
[assembly: AssemblyProduct("SWTool")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]
[assembly: ComVisible(true)]

namespace SWTool.CommandLocalizer
{
    [ComVisible(true)]
    [Guid("9F5F2805-10D2-4A49-AB0A-2F8279B6B6D1")]
    [ProgId("SWTool.CommandLocalizer")]
    public sealed class CommandLocalizerAddIn : ISwAddin
    {
        private const int MainGroupId = 9101;
        private ISldWorks swApp;
        private int addinCookie;
        private object ztoolAddin;
        private string currentLanguage = "Russian";
        private string lastError = string.Empty;
        private Timer refreshTimer;
        private int refreshTicks;

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
                Log("ConnectToSW start");
                swApp = (ISldWorks)ThisSW;
                addinCookie = Cookie;
                swApp.SetAddinCallbackInfo2(0, this, addinCookie);
                ztoolAddin = swApp.GetAddInObject("ZTool.SwAddin");
                Log("Original add-in object: " + (ztoolAddin == null ? "null" : ztoolAddin.GetType().FullName));
                CreateCommandManager();
                StartRefreshTimer();
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
                if (refreshTimer != null)
                {
                    refreshTimer.Stop();
                    refreshTimer.Dispose();
                    refreshTimer = null;
                }

                var cmdMgr = swApp != null ? swApp.GetCommandManager(addinCookie) : null;
                if (cmdMgr != null)
                {
                    cmdMgr.RemoveCommandGroup2(MainGroupId, true);
                }
            }
            catch
            {
            }

            ztoolAddin = null;
            swApp = null;
            Log("DisconnectFromSW ok");
            return true;
        }

        public void OpenCommand0() { OpenZTool(0); }
        public void OpenCommand1() { OpenZTool(1); }
        public void OpenCommand2() { OpenZTool(2); }
        public void OpenCommand3() { OpenZTool(3); }
        public void OpenCommand4() { OpenZTool(4); }
        public void OpenCommand5() { OpenZTool(5); }
        public void OpenCommand6() { OpenZTool(6); }
        public void OpenCommand120() { OpenZTool(120); }
        public void OpenCommand130() { OpenZTool(130); }

        public int EnableCommand() { return 1; }

        public string GetCurrentLanguage() { return currentLanguage; }

        public string GetLastError() { return lastError ?? string.Empty; }

        public string GetCommandLabels()
        {
            bool english = string.Equals(currentLanguage, "English", StringComparison.OrdinalIgnoreCase);
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
                        documentType.ToString() +
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

        private void StartRefreshTimer()
        {
            try
            {
                if (refreshTimer != null)
                {
                    refreshTimer.Stop();
                    refreshTimer.Dispose();
                }

                refreshTicks = 0;
                refreshTimer = new Timer();
                refreshTimer.Interval = 1000;
                refreshTimer.Tick += delegate
                {
                    refreshTicks++;
                    try
                    {
                        CreateCommandManager();
                        Log("Refresh tick " + refreshTicks + "; tabs=" + GetCommandTabReport());
                    }
                    catch (Exception ex)
                    {
                        lastError = ex.ToString();
                        Log("Refresh tick failed: " + ex);
                    }

                    if (refreshTicks >= 20 && refreshTimer != null)
                    {
                        refreshTimer.Stop();
                        refreshTimer.Dispose();
                        refreshTimer = null;
                        Log("Refresh timer stopped");
                    }
                };
                refreshTimer.Start();
                Log("Refresh timer started");
            }
            catch (Exception ex)
            {
                lastError = ex.ToString();
                Log("Refresh timer start failed: " + ex);
            }
        }

        private void CreateCommandManager()
        {
            Log("CreateCommandManager start");
            var cmdMgr = swApp.GetCommandManager(addinCookie);
            if (cmdMgr == null)
            {
                Log("CommandManager is null");
                return;
            }

            try { cmdMgr.RemoveCommandGroup2(MainGroupId, true); Log("Previous command group removed"); } catch (Exception ex) { Log("RemoveCommandGroup2 skipped: " + ex.Message); }
            RemoveLegacyTabs(cmdMgr);

            int errors = 0;
            bool ignorePrevious = true;
            string tabTitle = "SWTool";
            var group = cmdMgr.CreateCommandGroup2(
                MainGroupId,
                tabTitle,
                tabTitle,
                tabTitle,
                -1,
                ignorePrevious,
                ref errors);

            if (group == null)
            {
                Log("CreateCommandGroup2 returned null; errors=" + errors);
                return;
            }
            Log("CreateCommandGroup2 ok; errors=" + errors);

            var iconList = ResolveIconList();
            if (!string.IsNullOrEmpty(iconList))
            {
                group.IconList = iconList;
                group.MainIconList = iconList;
            }

            currentLanguage = GetConfiguredLanguage();
            bool english = string.Equals(currentLanguage, "English", StringComparison.OrdinalIgnoreCase);
            foreach (var command in Commands)
            {
                string callback = "OpenCommand" + command.Id;
                string name = english ? command.NameEn : command.NameRu;
                string tip = english ? command.TooltipEn : command.TooltipRu;
                group.AddCommandItem2(
                    name,
                    -1,
                    tip,
                    tip,
                    command.ImageIndex,
                    callback,
                    "EnableCommand",
                    command.Id,
                    (int)swCommandItemType_e.swMenuItem | (int)swCommandItemType_e.swToolbarItem);
            }

            group.HasToolbar = true;
            group.HasMenu = true;
            group.Activate();
            Log("Command group activated; labels=" + GetCommandLabels());

            foreach (int documentType in GetDocumentTypes())
            {
                AddTab(cmdMgr, documentType, group);
            }
            Log("CreateCommandManager complete");
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

        private void RemoveLegacyTabs(ICommandManager cmdMgr)
        {
            foreach (int documentType in GetDocumentTypes())
            {
                RemoveTabsByName(cmdMgr, documentType, "SWTool");
                RemoveTabsByName(cmdMgr, documentType, "ZTool");
            }
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

                bool removed = cmdMgr.RemoveCommandTab(tab);
                Log("RemoveCommandTab(" + documentType + "," + tabName + ")=" + removed);
                if (!removed)
                {
                    return;
                }
            }
        }

        private void AddTab(ICommandManager cmdMgr, int documentType, ICommandGroup group)
        {
            try
            {
                var tab = cmdMgr.AddCommandTab(documentType, "SWTool");
                if (tab == null)
                {
                    tab = cmdMgr.GetCommandTab(documentType, "SWTool");
                }

                if (tab == null)
                {
                    Log("Command tab is null for documentType=" + documentType);
                    return;
                }

                var box = tab.AddCommandTabBox();
                var ids = new int[Commands.Length];
                var textTypes = new int[Commands.Length];
                for (int i = 0; i < Commands.Length; i++)
                {
                    ids[i] = group.get_CommandID(i);
                    textTypes[i] = (int)swCommandTabButtonTextDisplay_e.swCommandTabButton_TextBelow;
                }

                box.AddCommands(ids, textTypes);
                Log("Command tab added for documentType=" + documentType);
            }
            catch (Exception ex)
            {
                lastError = ex.ToString();
                Log("AddTab failed for documentType=" + documentType + ": " + ex);
            }
        }

        private void OpenZTool(int commandId)
        {
            try
            {
                if (ztoolAddin == null && swApp != null)
                {
                    ztoolAddin = swApp.GetAddInObject("ZTool.SwAddin");
                }

                if (ztoolAddin == null)
                {
                    return;
                }

                ztoolAddin.GetType().InvokeMember(
                    "openZtool",
                    BindingFlags.InvokeMethod,
                    null,
                    ztoolAddin,
                    new object[] { commandId });
            }
            catch (Exception ex)
            {
                lastError = ex.ToString();
                Log("OpenZTool failed for commandId=" + commandId + ": " + ex);
            }
        }

        private static string ResolveIconList()
        {
            try
            {
                string baseDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                if (string.IsNullOrEmpty(baseDir))
                {
                    return string.Empty;
                }

                string[] candidates =
                {
                    Path.Combine(baseDir, "ZTool.bmp"),
                    Path.Combine(baseDir, "SWTool.bmp")
                };

                foreach (string candidate in candidates)
                {
                    if (File.Exists(candidate))
                    {
                        return candidate;
                    }
                }
            }
            catch
            {
            }

            return string.Empty;
        }

        private static string GetConfiguredLanguage()
        {
            try
            {
                string baseDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                string settings = Path.Combine(baseDir ?? string.Empty, "ZTool.settings");
                if (!File.Exists(settings))
                {
                    return "Russian";
                }

                var doc = new XmlDocument();
                doc.Load(settings);
                var node = doc.SelectSingleNode("//Language");
                if (node != null && string.Equals(node.InnerText, "English", StringComparison.OrdinalIgnoreCase))
                {
                    return "English";
                }
            }
            catch
            {
            }

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
                string path = Path.Combine(dir, "SWTool.CommandLocalizer.log");
                File.AppendAllText(
                    path,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + System.Environment.NewLine);
            }
            catch
            {
            }
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
