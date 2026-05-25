using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Management;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Drawing;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ZTool.License
{
    public static class LicenseGate
    {
        private const string ProductId = "ztool";
        private const string AppVersion = "1.1";

        public static bool IsLicensed()
        {
            try
            {
                if (DemoMode.IsActive)
                {
                    return true;
                }

                var machineId = HardwareFingerprint.GetMachineId();
                var store = new LicenseStore();
                var cache = store.Load();
                TimeSpan demoRemaining;
                if (DemoMode.IsUsableCache(cache, machineId, out demoRemaining))
                {
                    return DemoMode.Start(demoRemaining, false);
                }

                if (DemoMode.IsDemoCache(cache))
                {
                    store.Delete();
                }

                if (LicenseValidator.IsUsable(cache, machineId))
                {
                    return true;
                }

                var demoRequested = false;
                cache = ShowActivation(machineId, out demoRequested);
                if (cache != null && LicenseValidator.IsUsable(cache, machineId))
                {
                    store.Save(cache);
                    return true;
                }

                if (demoRequested)
                {
                    var demoCache = DemoMode.CreateCache(machineId);
                    store.Save(demoCache);
                    return DemoMode.StartUntil(demoCache.DemoExpiresAtUtc, true);
                }

                if (cache == null || !LicenseValidator.IsUsable(cache, machineId))
                {
                    return false;
                }

                store.Save(cache);
                return true;
            }
            catch (Exception ex)
            {
                Log.Write("License gate failed: " + ex);
                MessageBox.Show("Не удалось проверить лицензию ZTool.\r\n\r\n" + ex.Message, "ZTool", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
        }

        public static bool DeactivateInteractive()
        {
            using (var form = new PasswordForm())
            {
                if (form.ShowDialog() != DialogResult.OK)
                {
                    return false;
                }

                return DeactivateWithPassword(form.TransferPassword);
            }
        }

        public static bool DeactivateWithPassword(string transferPassword)
        {
            try
            {
                var machineId = HardwareFingerprint.GetMachineId();
                var store = new LicenseStore();
                var cache = store.Load();
                if (cache == null || string.IsNullOrWhiteSpace(cache.Key) || DemoMode.IsDemoCache(cache))
                {
                    MessageBox.Show("На этом пользователе нет сохраненной лицензии ZTool.", "ZTool", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return false;
                }

                if (string.IsNullOrWhiteSpace(transferPassword))
                {
                    using (var form = new PasswordForm())
                    {
                        if (form.ShowDialog() != DialogResult.OK)
                        {
                            return false;
                        }

                        transferPassword = form.TransferPassword;
                    }
                }

                var deactivationMachineId = string.IsNullOrWhiteSpace(cache.MachineId) ? machineId : cache.MachineId;
                if (!deactivationMachineId.Equals(machineId, StringComparison.OrdinalIgnoreCase))
                {
                    Log.Write("Using cached machine id for deactivation because current fingerprint changed.");
                }

                new LicenseClient().Deactivate(cache.Key, transferPassword, deactivationMachineId);
                store.Delete();
                MessageBox.Show("Лицензия деактивирована. Теперь ключ можно активировать на другом ПК.", "ZTool", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return true;
            }
            catch (Exception ex)
            {
                Log.Write("Deactivation failed: " + ex);
                MessageBox.Show(ex.Message, "Деактивация ZTool", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
        }

        private static LicenseCache ShowActivation(string machineId, out bool demoRequested)
        {
            demoRequested = false;
            using (var form = new ActivationForm())
            {
                while (true)
                {
                    var result = form.ShowDialog();
                    if (result == DialogResult.Ignore)
                    {
                        demoRequested = true;
                        return null;
                    }

                    if (result != DialogResult.OK)
                    {
                        return null;
                    }

                    try
                    {
                        var cache = new LicenseClient().Activate(form.LicenseKey, form.TransferPassword, machineId);
                        if (!LicenseValidator.IsUsable(cache, machineId))
                        {
                            MessageBox.Show("Сервер вернул лицензию, но локальная проверка не прошла.", "ZTool", MessageBoxButtons.OK, MessageBoxIcon.Error);
                            continue;
                        }

                        return cache;
                    }
                    catch (Exception ex)
                    {
                        Log.Write("Activation failed: " + ex);
                        MessageBox.Show(ex.Message, "Активация ZTool", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }
                }
            }
        }

        private sealed class LicenseClient
        {
            private const SecurityProtocolType Tls12 = (SecurityProtocolType)3072;
            private static bool tlsConfigured;

            private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();

            public LicenseCache Activate(string key, string transferPassword, string machineId)
            {
                var request = new Dictionary<string, object>
                {
                    { "key", key },
                    { "productId", ProductId },
                    { "transferPassword", transferPassword },
                    { "machineId", machineId },
                    { "machineLabel", Environment.MachineName },
                    { "platform", "windows" },
                    { "appVersion", AppVersion },
                    { "machineMeta", new Dictionary<string, object>
                        {
                            { "osVersion", Environment.OSVersion.VersionString },
                            { "is64BitOS", Environment.Is64BitOperatingSystem }
                        }
                    }
                };

                var response = Post(EmbeddedLicenseConfig.LicenseBaseUrl.TrimEnd('/') + "/api/activate.php", request);
                var signedPayload = GetString(response, "signedPayload");
                var signature = GetString(response, "signature");
                if (string.IsNullOrWhiteSpace(signedPayload) || string.IsNullOrWhiteSpace(signature))
                {
                    throw new InvalidOperationException("Сервер лицензирования не вернул подписанную лицензию.");
                }

                return new LicenseCache
                {
                    Key = key,
                    MachineId = machineId,
                    SignedPayload = signedPayload,
                    Signature = signature,
                    LastOnlineCheckUtc = DateTime.UtcNow
                };
            }

            public void Deactivate(string key, string transferPassword, string machineId)
            {
                var request = new Dictionary<string, object>
                {
                    { "key", key },
                    { "productId", ProductId },
                    { "transferPassword", transferPassword },
                    { "machineId", machineId }
                };

                var response = Post(EmbeddedLicenseConfig.LicenseBaseUrl.TrimEnd('/') + "/api/deactivate.php", request);
                if (!IsSuccess(response))
                {
                    throw new InvalidOperationException("Сервер лицензирования не подтвердил деактивацию.");
                }
            }

            private Dictionary<string, object> Post(string url, Dictionary<string, object> body)
            {
                EnsureTls12();
                var json = serializer.Serialize(body);
                var bytes = Encoding.UTF8.GetBytes(json);
                var request = (HttpWebRequest)WebRequest.Create(url);
                request.Method = "POST";
                request.ContentType = "application/json; charset=utf-8";
                request.Accept = "application/json";
                request.Timeout = 15000;
                request.ContentLength = bytes.Length;

                using (var stream = request.GetRequestStream())
                {
                    stream.Write(bytes, 0, bytes.Length);
                }

                try
                {
                    using (var response = (HttpWebResponse)request.GetResponse())
                    using (var stream = response.GetResponseStream())
                    using (var reader = new StreamReader(stream, Encoding.UTF8))
                    {
                        return ParseResponse(reader.ReadToEnd());
                    }
                }
                catch (WebException ex)
                {
                    throw new InvalidOperationException(ReadErrorMessage(ex), ex);
                }
            }

            private static void EnsureTls12()
            {
                if (tlsConfigured)
                {
                    return;
                }

                ServicePointManager.SecurityProtocol |= Tls12;
                ServicePointManager.Expect100Continue = false;
                tlsConfigured = true;
            }

            private Dictionary<string, object> ParseResponse(string json)
            {
                var parsed = serializer.DeserializeObject(json) as Dictionary<string, object>;
                if (parsed == null)
                {
                    throw new InvalidOperationException("Некорректный ответ сервера лицензирования.");
                }

                object success;
                if (parsed.TryGetValue("success", out success) && success is bool && !(bool)success)
                {
                    var message = GetString(parsed, "message");
                    if (string.IsNullOrWhiteSpace(message))
                    {
                        message = GetString(parsed, "error");
                    }

                    throw new InvalidOperationException(string.IsNullOrWhiteSpace(message) ? "Лицензия не принята сервером." : message);
                }

                return parsed;
            }

            private string ReadErrorMessage(WebException ex)
            {
                if (ex.Response == null)
                {
                    return "Сервер лицензирования недоступен.";
                }

                using (var stream = ex.Response.GetResponseStream())
                using (var reader = new StreamReader(stream, Encoding.UTF8))
                {
                    var text = reader.ReadToEnd();
                    var message = TryReadServerError(text);
                    return string.IsNullOrWhiteSpace(message)
                        ? (string.IsNullOrWhiteSpace(text) ? ex.Message : text)
                        : message;
                }
            }

            private string TryReadServerError(string json)
            {
                try
                {
                    var parsed = serializer.DeserializeObject(json) as Dictionary<string, object>;
                    if (parsed == null)
                    {
                        return string.Empty;
                    }

                    var message = GetString(parsed, "message");
                    return string.IsNullOrWhiteSpace(message) ? GetString(parsed, "error") : message;
                }
                catch
                {
                    return string.Empty;
                }
            }

            private static string GetString(Dictionary<string, object> data, string name)
            {
                object value;
                return data.TryGetValue(name, out value) && value != null ? Convert.ToString(value, CultureInfo.InvariantCulture) : string.Empty;
            }

            private static bool IsSuccess(Dictionary<string, object> data)
            {
                object value;
                if (!data.TryGetValue("success", out value) || value == null)
                {
                    return false;
                }

                if (value is bool)
                {
                    return (bool)value;
                }

                bool parsed;
                return bool.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), out parsed) && parsed;
            }
        }

        private sealed class LicenseCache
        {
            public string Key { get; set; }
            public string MachineId { get; set; }
            public string SignedPayload { get; set; }
            public string Signature { get; set; }
            public DateTime LastOnlineCheckUtc { get; set; }
            public bool Demo { get; set; }
            public DateTime DemoExpiresAtUtc { get; set; }
            public string DemoToken { get; set; }
        }

        private sealed class LicenseStore
        {
            private readonly string path;
            private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();

            public LicenseStore()
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SWTools");
                Directory.CreateDirectory(dir);
                path = Path.Combine(dir, "ZTool.license.json");
            }

            public LicenseCache Load()
            {
                if (!File.Exists(path))
                {
                    return null;
                }

                try
                {
                    return serializer.Deserialize<LicenseCache>(File.ReadAllText(path, Encoding.UTF8));
                }
                catch (Exception ex)
                {
                    Log.Write("License cache read failed: " + ex);
                    return null;
                }
            }

            public void Save(LicenseCache cache)
            {
                File.WriteAllText(path, serializer.Serialize(cache), Encoding.UTF8);
            }

            public void Delete()
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
        }

        private static class LicenseValidator
        {
            public static bool IsUsable(LicenseCache cache, string machineId)
            {
                if (cache == null || cache.MachineId == null || !cache.MachineId.Equals(machineId, StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }

                if (string.IsNullOrWhiteSpace(cache.SignedPayload) || string.IsNullOrWhiteSpace(cache.Signature))
                {
                    return false;
                }

                if (string.IsNullOrWhiteSpace(EmbeddedLicenseConfig.PublicKeyXml))
                {
                    Log.Write("License public key is not embedded.");
                    return false;
                }

                if (!VerifySignature(cache.SignedPayload, cache.Signature, EmbeddedLicenseConfig.PublicKeyXml))
                {
                    return false;
                }

                var payload = new JavaScriptSerializer().DeserializeObject(cache.SignedPayload) as Dictionary<string, object>;
                if (payload == null)
                {
                    return false;
                }

                if (!EqualsString(payload, "productId", ProductId) || !EqualsString(payload, "machineId", machineId))
                {
                    return false;
                }

                if (IsTruthy(payload, "revoked") || IsTruthy(payload, "isRevoked") || IsTruthy(payload, "is_revoked"))
                {
                    return false;
                }

                if (IsExplicitFalse(payload, "valid") || IsExplicitFalse(payload, "isActive") || IsExplicitFalse(payload, "is_active") || IsExplicitFalse(payload, "offlineAllowed"))
                {
                    return false;
                }

                var status = GetString(payload, "status");
                if (!string.IsNullOrWhiteSpace(status) &&
                    !string.Equals(status, "active", StringComparison.OrdinalIgnoreCase) &&
                    !string.Equals(status, "valid", StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }

                var expires = GetString(payload, "expiresAt");
                if (!string.IsNullOrWhiteSpace(expires))
                {
                    DateTime expiresAt;
                    if (DateTime.TryParse(expires, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out expiresAt) && expiresAt < DateTime.Now)
                    {
                        return false;
                    }
                }

                return true;
            }

            private static bool VerifySignature(string signedPayload, string signature, string publicKeyXml)
            {
                try
                {
                    using (var rsa = new RSACryptoServiceProvider())
                    {
                        rsa.FromXmlString(publicKeyXml);
                        return rsa.VerifyData(Encoding.UTF8.GetBytes(signedPayload), CryptoConfig.MapNameToOID("SHA256"), Convert.FromBase64String(signature));
                    }
                }
                catch (Exception ex)
                {
                    Log.Write("Signature verification failed: " + ex);
                    return false;
                }
            }

            private static bool EqualsString(Dictionary<string, object> payload, string name, string expected)
            {
                return string.Equals(GetString(payload, name), expected, StringComparison.OrdinalIgnoreCase);
            }

            private static string GetString(Dictionary<string, object> payload, string name)
            {
                object value;
                return payload.TryGetValue(name, out value) && value != null ? Convert.ToString(value, CultureInfo.InvariantCulture) : string.Empty;
            }

            private static bool IsTruthy(Dictionary<string, object> payload, string name)
            {
                bool parsed;
                return TryReadBoolean(payload, name, out parsed) && parsed;
            }

            private static bool IsExplicitFalse(Dictionary<string, object> payload, string name)
            {
                bool parsed;
                return TryReadBoolean(payload, name, out parsed) && !parsed;
            }

            private static bool TryReadBoolean(Dictionary<string, object> payload, string name, out bool value)
            {
                value = false;
                object raw;
                if (!payload.TryGetValue(name, out raw) || raw == null)
                {
                    return false;
                }

                if (raw is bool)
                {
                    value = (bool)raw;
                    return true;
                }

                var text = Convert.ToString(raw, CultureInfo.InvariantCulture);
                if (string.IsNullOrWhiteSpace(text))
                {
                    return false;
                }

                if (bool.TryParse(text, out value))
                {
                    return true;
                }

                if (text == "1")
                {
                    value = true;
                    return true;
                }

                if (text == "0")
                {
                    value = false;
                    return true;
                }

                return false;
            }
        }

        private static class HardwareFingerprint
        {
            public static string GetMachineId()
            {
                var material = ReadMachineGuid() + "|" + Environment.MachineName + "|" + ReadBiosSerial();
                using (var sha = SHA256.Create())
                {
                    var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(material));
                    var result = new StringBuilder(hash.Length * 2);
                    foreach (var b in hash)
                    {
                        result.Append(b.ToString("x2", CultureInfo.InvariantCulture));
                    }

                    return result.ToString();
                }
            }

            private static string ReadMachineGuid()
            {
                try
                {
                    using (var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography"))
                    {
                        var value = key == null ? null : key.GetValue("MachineGuid");
                        return value == null ? string.Empty : Convert.ToString(value, CultureInfo.InvariantCulture);
                    }
                }
                catch
                {
                    return string.Empty;
                }
            }

            private static string ReadBiosSerial()
            {
                try
                {
                    using (var searcher = new ManagementObjectSearcher("SELECT SerialNumber FROM Win32_BIOS"))
                    using (var results = searcher.Get())
                    {
                        foreach (ManagementObject result in results)
                        {
                            var value = result["SerialNumber"];
                            return value == null ? string.Empty : Convert.ToString(value, CultureInfo.InvariantCulture);
                        }
                    }
                }
                catch
                {
                }

                return string.Empty;
            }
        }

        private sealed class ActivationForm : Form
        {
            private readonly BorderedTextInput keyBox;
            private readonly BorderedTextInput passwordBox;
            private const string ActivationHelpFallbackUrl = "https://license.vizbuka.ru/ztool";
            private const string ActivationHelpChmFileName = "help.CHM";
            private const string ActivationHelpChmTopic = "activation.htm";

            public ActivationForm()
            {
                Text = "Активация ZTool";
                FormBorderStyle = FormBorderStyle.FixedDialog;
                MaximizeBox = false;
                MinimizeBox = false;
                StartPosition = FormStartPosition.CenterScreen;
                ClientSize = new Size(520, 285);
                Font = new Font("Segoe UI", 9F);

                var keyLabel = new Label { Left = 20, Top = 18, Width = 460, Height = 17, Text = "Ключ лицензии:" };
                keyBox = new BorderedTextInput { Left = 20, Top = 40, Width = 480, Height = 24 };
                var passwordLabel = new Label { Left = 20, Top = 76, Width = 460, Height = 17, Text = "Пароль переноса (8-64 символа, буквы и цифры):" };
                passwordBox = new BorderedTextInput { Left = 20, Top = 98, Width = 480, Height = 24 };
                passwordBox.UseSystemPasswordChar = false;
                var showPassword = new CheckBox { Left = 20, Top = 128, Width = 160, Text = "Показать пароль", Checked = true };
                showPassword.CheckedChanged += delegate { passwordBox.UseSystemPasswordChar = !showPassword.Checked; };
                var helpText = new Label
                {
                    Left = 20,
                    Top = 160,
                    Width = 340,
                    Height = 34,
                    Text = "Нет кода активации? Откройте инструкцию и получите код для этого компьютера."
                };
                var helpButton = new Button { Left = 370, Top = 156, Width = 130, Height = 30, Text = "Инструкция" };
                helpButton.Click += delegate { OpenActivationHelp(); };
                var demoHint = new Label { Left = 20, Top = 202, Width = 480, Height = 34, Text = "Без активации можно продолжить в демо-режиме. После окончания таймера ZTool закроется." };
                var demoButton = new Button { Left = 20, Top = 245, Width = 112, Text = "Демо-режим", DialogResult = DialogResult.Ignore };
                var activateButton = new Button { Left = 280, Top = 245, Width = 105, Text = "Активировать", DialogResult = DialogResult.OK };
                var cancelButton = new Button { Left = 395, Top = 245, Width = 105, Text = "Выход", DialogResult = DialogResult.Cancel };

                Controls.AddRange(new Control[] { keyLabel, keyBox, passwordLabel, passwordBox, showPassword, helpText, helpButton, demoHint, demoButton, activateButton, cancelButton });
                AcceptButton = activateButton;
                CancelButton = cancelButton;
            }

            public string LicenseKey { get { return keyBox.Text.Trim(); } }
            public string TransferPassword { get { return passwordBox.Text; } }

            private static void OpenActivationHelp()
            {
                if (TryOpenLocalActivationHelp())
                {
                    return;
                }

                var url = string.IsNullOrWhiteSpace(EmbeddedLicenseConfig.ActivationHelpUrl)
                    ? ActivationHelpFallbackUrl
                    : EmbeddedLicenseConfig.ActivationHelpUrl;

                try
                {
                    var startInfo = new System.Diagnostics.ProcessStartInfo(url);
                    startInfo.UseShellExecute = true;
                    System.Diagnostics.Process.Start(startInfo);
                }
                catch (Exception ex)
                {
                    Log.Write("Activation help open failed: " + ex);
                    MessageBox.Show("Не удалось открыть локальную справку или инструкцию автоматически.\r\n\r\n" + url, "ZTool", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
            }

            private static bool TryOpenLocalActivationHelp()
            {
                var helpPath = FindLocalHelpPath();
                if (string.IsNullOrWhiteSpace(helpPath))
                {
                    return false;
                }

                try
                {
                    var htmlHelpExe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "hh.exe");
                    var startInfo = new System.Diagnostics.ProcessStartInfo(htmlHelpExe);
                    startInfo.Arguments = "\"mk:@MSITStore:" + helpPath + "::/" + ActivationHelpChmTopic + "\"";
                    startInfo.UseShellExecute = false;
                    System.Diagnostics.Process.Start(startInfo);
                    return true;
                }
                catch (Exception ex)
                {
                    Log.Write("Local activation help open failed: " + ex);
                    return false;
                }
            }

            private static string FindLocalHelpPath()
            {
                var candidates = new List<string>();
                AddHelpCandidate(candidates, AppDomain.CurrentDomain.BaseDirectory);
                AddHelpCandidate(candidates, Path.GetDirectoryName(typeof(LicenseGate).Assembly.Location));
                AddHelpCandidate(candidates, Environment.CurrentDirectory);

                foreach (var candidate in candidates)
                {
                    if (File.Exists(candidate))
                    {
                        return candidate;
                    }
                }

                return string.Empty;
            }

            private static void AddHelpCandidate(List<string> candidates, string directory)
            {
                if (string.IsNullOrWhiteSpace(directory))
                {
                    return;
                }

                try
                {
                    var path = Path.Combine(directory, ActivationHelpChmFileName);
                    if (!candidates.Contains(path))
                    {
                        candidates.Add(path);
                    }
                }
                catch
                {
                }
            }

            private sealed class BorderedTextInput : UserControl
            {
                private readonly TextBox textBox;

                public BorderedTextInput()
                {
                    SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
                    BackColor = Color.White;
                    TabStop = false;

                    textBox = new TextBox
                    {
                        BorderStyle = BorderStyle.None,
                        Left = 4,
                        Top = 4,
                        Width = Width - 8,
                        Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right,
                        BackColor = Color.White
                    };
                    textBox.GotFocus += delegate { Invalidate(); };
                    textBox.LostFocus += delegate { Invalidate(); };
                    Controls.Add(textBox);
                }

                public override string Text
                {
                    get { return textBox.Text; }
                    set { textBox.Text = value; }
                }

                public bool UseSystemPasswordChar
                {
                    get { return textBox.UseSystemPasswordChar; }
                    set { textBox.UseSystemPasswordChar = value; }
                }

                protected override void OnClick(EventArgs e)
                {
                    base.OnClick(e);
                    textBox.Focus();
                }

                protected override void OnResize(EventArgs e)
                {
                    base.OnResize(e);
                    textBox.Left = 4;
                    textBox.Top = Math.Max(3, (Height - textBox.Height) / 2);
                    textBox.Width = Math.Max(1, Width - 8);
                    Invalidate();
                }

                protected override void OnPaint(PaintEventArgs e)
                {
                    base.OnPaint(e);
                    using (var brush = new SolidBrush(Color.FromArgb(122, 122, 122)))
                    {
                        e.Graphics.FillRectangle(brush, 0, 0, Width, 1);
                        e.Graphics.FillRectangle(brush, 0, Height - 1, Width, 1);
                        e.Graphics.FillRectangle(brush, 0, 0, 1, Height);
                        e.Graphics.FillRectangle(brush, Width - 1, 0, 1, Height);
                    }
                }
            }
        }

        private sealed class PasswordForm : Form
        {
            private readonly TextBox passwordBox;

            public PasswordForm()
            {
                Text = "Деактивация ZTool";
                FormBorderStyle = FormBorderStyle.FixedDialog;
                MaximizeBox = false;
                MinimizeBox = false;
                StartPosition = FormStartPosition.CenterScreen;
                ClientSize = new System.Drawing.Size(390, 165);

                var passwordLabel = new Label { Left = 16, Top = 16, Width = 350, Text = "Пароль переноса:" };
                passwordBox = new TextBox { Left = 16, Top = 38, Width = 355, UseSystemPasswordChar = false };
                var showPassword = new CheckBox { Left = 16, Top = 66, Width = 140, Text = "Показать пароль", Checked = true };
                showPassword.CheckedChanged += delegate { passwordBox.UseSystemPasswordChar = !showPassword.Checked; };
                var okButton = new Button { Left = 195, Top = 112, Width = 85, Text = "ОК", DialogResult = DialogResult.OK };
                var cancelButton = new Button { Left = 286, Top = 112, Width = 85, Text = "Отмена", DialogResult = DialogResult.Cancel };

                Controls.AddRange(new Control[] { passwordLabel, passwordBox, showPassword, okButton, cancelButton });
                AcceptButton = okButton;
                CancelButton = cancelButton;
            }

            public string TransferPassword { get { return passwordBox.Text; } }
        }

        private static class DemoMode
        {
            private const string DemoCacheKey = "__ZTOOL_DEMO__";
            private const string DemoTokenPurpose = "ZToolDemoModeV1";
            private const int DemoMinutes = 3;
            private const string DemoSecondsEnvironmentVariable = "ZTOOL_DEMO_SECONDS";
            private const string CountdownLabelName = "ZToolDemoCountdownLabel";
            private const string CountdownStatusLabelName = "ZToolDemoCountdownStatusLabel";
            private static int started;
            private static DateTime countdownExpiresAtUtc;
            private static System.Windows.Forms.Timer countdownTimer;
            private static readonly Dictionary<IntPtr, string> originalWindowTitles = new Dictionary<IntPtr, string>();

            public static bool IsActive
            {
                get { return Interlocked.CompareExchange(ref started, 0, 0) != 0; }
            }

            public static LicenseCache CreateCache(string machineId)
            {
                var expiresAtUtc = DateTime.UtcNow.Add(GetDuration());
                var cache = new LicenseCache
                {
                    Key = DemoCacheKey,
                    MachineId = machineId,
                    Demo = true,
                    DemoExpiresAtUtc = expiresAtUtc,
                    DemoToken = ComputeDemoToken(machineId, expiresAtUtc)
                };

                return cache;
            }

            public static bool IsDemoCache(LicenseCache cache)
            {
                return cache != null &&
                    cache.Demo &&
                    string.Equals(cache.Key, DemoCacheKey, StringComparison.Ordinal);
            }

            public static bool IsUsableCache(LicenseCache cache, string machineId, out TimeSpan remaining)
            {
                remaining = TimeSpan.Zero;
                if (!IsDemoCache(cache) ||
                    string.IsNullOrWhiteSpace(cache.MachineId) ||
                    !cache.MachineId.Equals(machineId, StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }

                var expiresAtUtc = cache.DemoExpiresAtUtc.ToUniversalTime();
                remaining = expiresAtUtc - DateTime.UtcNow;
                if (remaining <= TimeSpan.Zero)
                {
                    return false;
                }

                var expected = ComputeDemoToken(machineId, expiresAtUtc);
                return string.Equals(cache.DemoToken, expected, StringComparison.Ordinal);
            }

            public static bool StartUntil(DateTime expiresAtUtc)
            {
                return StartUntil(expiresAtUtc, true);
            }

            public static bool StartUntil(DateTime expiresAtUtc, bool showNotice)
            {
                return Start(expiresAtUtc.ToUniversalTime() - DateTime.UtcNow, showNotice);
            }

            public static bool Start(TimeSpan duration)
            {
                return Start(duration, true);
            }

            public static bool Start(TimeSpan duration, bool showNotice)
            {
                if (Interlocked.Exchange(ref started, 1) != 0)
                {
                    return true;
                }

                if (duration <= TimeSpan.Zero)
                {
                    DeleteDemoCache();
                    return false;
                }

                var expiresAtUtc = DateTime.UtcNow.Add(duration);
                Log.Write("Demo mode started. DurationSeconds=" + ((int)duration.TotalSeconds).ToString(CultureInfo.InvariantCulture));

                var thread = new Thread(delegate()
                {
                    Thread.Sleep(duration);
                    Expire();
                });

                thread.Name = "ZTool demo mode timer";
                thread.IsBackground = true;
                thread.Start();
                StartCountdownInTitle(expiresAtUtc);
                if (showNotice)
                {
                    ShowDemoNotice(duration);
                }

                return true;
            }

            private static string ComputeDemoToken(string machineId, DateTime expiresAtUtc)
            {
                var material = DemoTokenPurpose + "|" + machineId + "|" + expiresAtUtc.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture);
                using (var sha = SHA256.Create())
                {
                    var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(material));
                    var result = new StringBuilder(hash.Length * 2);
                    foreach (var b in hash)
                    {
                        result.Append(b.ToString("x2", CultureInfo.InvariantCulture));
                    }

                    return result.ToString();
                }
            }

            private static TimeSpan GetDuration()
            {
                var secondsText = Environment.GetEnvironmentVariable(DemoSecondsEnvironmentVariable);
                int seconds;
                if (!string.IsNullOrWhiteSpace(secondsText) &&
                    int.TryParse(secondsText, NumberStyles.Integer, CultureInfo.InvariantCulture, out seconds) &&
                    seconds > 0)
                {
                    return TimeSpan.FromSeconds(Math.Min(seconds, DemoMinutes * 60));
                }

                return TimeSpan.FromMinutes(DemoMinutes);
            }

            private static void Expire()
            {
                Log.Write("Demo mode expired. Closing ZTool.");
                DeleteDemoCache();
                try
                {
                    if (countdownTimer != null)
                    {
                        countdownTimer.Stop();
                        countdownTimer.Dispose();
                        countdownTimer = null;
                    }
                }
                catch (Exception ex)
                {
                    Log.Write("Demo countdown timer cleanup failed: " + ex);
                }

                Environment.Exit(0);
            }

            private static void ShowDemoNotice(TimeSpan duration)
            {
                try
                {
                    MessageBox.Show(
                        "ZTool запущен в демо-режиме.\r\n\r\nПрограмма закроется автоматически через " + FormatDuration(duration) + ".",
                        "Демо-режим ZTool",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                }
                catch (Exception ex)
                {
                    Log.Write("Demo notice failed: " + ex);
                }
            }

            private static string FormatDuration(TimeSpan duration)
            {
                if (duration.TotalMinutes >= 1)
                {
                    return ((int)Math.Ceiling(duration.TotalMinutes)).ToString(CultureInfo.InvariantCulture) + " мин.";
                }

                return Math.Max(1, (int)Math.Ceiling(duration.TotalSeconds)).ToString(CultureInfo.InvariantCulture) + " сек.";
            }

            private static void StartCountdownInTitle(DateTime expiresAtUtc)
            {
                try
                {
                    countdownExpiresAtUtc = expiresAtUtc.ToUniversalTime();
                    if (countdownTimer != null)
                    {
                        countdownTimer.Stop();
                        countdownTimer.Dispose();
                    }

                    countdownTimer = new System.Windows.Forms.Timer();
                    countdownTimer.Interval = 1000;
                    countdownTimer.Tick += delegate { UpdateCountdownInTitle(); };
                    countdownTimer.Start();
                    UpdateCountdownInTitle();
                }
                catch (Exception ex)
                {
                    Log.Write("Demo countdown title timer failed: " + ex);
                }
            }

            private static void UpdateCountdownInTitle()
            {
                try
                {
                    var remaining = countdownExpiresAtUtc - DateTime.UtcNow;
                    if (remaining <= TimeSpan.Zero)
                    {
                        return;
                    }

                    foreach (Form form in Application.OpenForms)
                    {
                        if (form == null || form.IsDisposed || !form.IsHandleCreated || string.IsNullOrWhiteSpace(form.Text))
                        {
                            continue;
                        }

                        if (!form.Text.StartsWith("ZTool", StringComparison.OrdinalIgnoreCase))
                        {
                            continue;
                        }

                        string originalTitle;
                        if (!originalWindowTitles.TryGetValue(form.Handle, out originalTitle))
                        {
                            originalTitle = StripDemoCountdown(form.Text);
                            originalWindowTitles[form.Handle] = originalTitle;
                        }

                        form.Text = originalTitle + "  Демо: " + FormatRemaining(remaining);
                        UpdateCountdownPanel(form, remaining);
                    }
                }
                catch (Exception ex)
                {
                    Log.Write("Demo countdown title update failed: " + ex);
                }
            }

            private static void UpdateCountdownPanel(Form form, TimeSpan remaining)
            {
                try
                {
                    var text = "Демо: " + FormatRemaining(remaining);
                    Label label = null;
                    foreach (Control control in form.Controls.Find(CountdownLabelName, false))
                    {
                        label = control as Label;
                        if (label != null)
                        {
                            break;
                        }
                    }

                    if (label == null)
                    {
                        label = new Label();
                        label.Name = CountdownLabelName;
                        label.AutoSize = false;
                        label.Width = 150;
                        label.Height = 24;
                        label.TextAlign = ContentAlignment.MiddleCenter;
                        label.BackColor = Color.FromArgb(255, 250, 205);
                        label.ForeColor = Color.FromArgb(128, 0, 0);
                        label.BorderStyle = BorderStyle.FixedSingle;
                        label.Font = new Font(form.Font, FontStyle.Bold);
                        label.Anchor = AnchorStyles.Top | AnchorStyles.Right;
                        form.Controls.Add(label);
                        form.Resize += delegate { PositionCountdownPanel(form, label); };
                    }

                    label.Text = text;
                    label.Visible = true;
                    PositionCountdownPanel(form, label);
                    label.BringToFront();
                    UpdateStatusStripCountdown(form, text);
                }
                catch (Exception ex)
                {
                    Log.Write("Demo countdown panel update failed: " + ex);
                }
            }

            private static void UpdateStatusStripCountdown(Form form, string text)
            {
                var status = FindStatusStrip(form);
                if (status == null)
                {
                    return;
                }

                ToolStripStatusLabel label = null;
                foreach (ToolStripItem item in status.Items)
                {
                    if (string.Equals(item.Name, CountdownStatusLabelName, StringComparison.Ordinal))
                    {
                        label = item as ToolStripStatusLabel;
                        break;
                    }
                }

                if (label == null)
                {
                    label = new ToolStripStatusLabel();
                    label.Name = CountdownStatusLabelName;
                    label.BorderSides = ToolStripStatusLabelBorderSides.All;
                    label.BackColor = Color.FromArgb(255, 250, 205);
                    label.ForeColor = Color.FromArgb(128, 0, 0);
                    label.Font = new Font(status.Font, FontStyle.Bold);
                    status.Items.Add(label);
                }

                label.Text = text;
                label.Visible = true;
            }

            private static StatusStrip FindStatusStrip(Control parent)
            {
                if (parent == null)
                {
                    return null;
                }

                foreach (Control child in parent.Controls)
                {
                    var status = child as StatusStrip;
                    if (status != null)
                    {
                        return status;
                    }

                    status = FindStatusStrip(child);
                    if (status != null)
                    {
                        return status;
                    }
                }

                return null;
            }

            private static void PositionCountdownPanel(Form form, Control control)
            {
                control.Left = Math.Max(8, form.ClientSize.Width - control.Width - 12);
                control.Top = 8;
            }

            private static string StripDemoCountdown(string title)
            {
                var marker = "  Демо: ";
                var index = title.IndexOf(marker, StringComparison.Ordinal);
                return index < 0 ? title : title.Substring(0, index);
            }

            private static string FormatRemaining(TimeSpan remaining)
            {
                if (remaining.TotalHours >= 1)
                {
                    return string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}:{2:00}", (int)remaining.TotalHours, remaining.Minutes, remaining.Seconds);
                }

                return string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}", Math.Max(0, (int)remaining.TotalMinutes), Math.Max(0, remaining.Seconds));
            }

            private static void DeleteDemoCache()
            {
                try
                {
                    var store = new LicenseStore();
                    if (IsDemoCache(store.Load()))
                    {
                        store.Delete();
                    }
                }
                catch (Exception ex)
                {
                    Log.Write("Demo cache cleanup failed: " + ex);
                }
            }

        }

        private static class Log
        {
            public static void Write(string message)
            {
                try
                {
                    var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SWTools");
                    Directory.CreateDirectory(dir);
                    File.AppendAllText(Path.Combine(dir, "ZTool.License.log"), DateTime.Now.ToString("s", CultureInfo.InvariantCulture) + " " + message + Environment.NewLine, Encoding.UTF8);
                }
                catch
                {
                }
            }
        }
    }

#if !ZTOOL_EMBEDDED_LICENSE_CONFIG
    internal static class EmbeddedLicenseConfig
    {
        public const string LicenseBaseUrl = "https://license.vizbuka.ru/ztool";
        public const string ActivationHelpUrl = "https://license.vizbuka.ru/ztool";
        public const string PublicKeyXml = "";
    }
#endif
}
