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

        private static bool VerifyAssemblyToken(System.Reflection.Assembly assembly)
        {
            if (assembly == null) return true;
            try
            {
                var name = assembly.GetName();
                if (name.Name.Equals("mscorlib", StringComparison.OrdinalIgnoreCase) ||
                    name.Name.Equals("System", StringComparison.OrdinalIgnoreCase) ||
                    name.Name.Equals("System.Core", StringComparison.OrdinalIgnoreCase) ||
                    name.Name.Equals("System.Windows.Forms", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
                var tokenBytes = name.GetPublicKeyToken();
                if (tokenBytes == null || tokenBytes.Length != 8) return false;
                var tokenStr = string.Empty;
                foreach (var b in tokenBytes)
                {
                    tokenStr += b.ToString("x2");
                }
                return string.Equals(tokenStr, "609176c10962aecc", StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        public static bool IsLicensed()
        {
            try
            {
                var calling = System.Reflection.Assembly.GetCallingAssembly();
                var entry = System.Reflection.Assembly.GetEntryAssembly();
                if (!VerifyAssemblyToken(calling) || !VerifyAssemblyToken(entry))
                {
                    Log.Write("Untrusted assembly load blocked.");
                    return false;
                }

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

                bool needOnlineCheck = false;
                if (cache != null)
                {
                    var age = DateTime.UtcNow - cache.LastOnlineCheckUtc;
                    if (age.TotalDays > EmbeddedLicenseConfig.OfflineGraceDays)
                    {
                        needOnlineCheck = true;
                    }
                }

                if (cache != null && LicenseValidator.IsUsable(cache, machineId) && !needOnlineCheck)
                {
                    return true;
                }

                if (cache != null && LicenseValidator.IsUsable(cache, machineId) && needOnlineCheck)
                {
                    try
                    {
                        var client = new LicenseClient();
                        var newCache = client.Activate(cache.Key, string.Empty, machineId);
                        if (LicenseValidator.IsUsable(newCache, machineId))
                        {
                            cache = newCache;
                            store.Save(cache);
                            return true;
                        }
                    }
                    catch (Exception ex)
                    {
                        Log.Write("Online revalidation failed: " + ex.Message);
                        store.Delete();
                        cache = null;
                    }
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
                    var encryptedBytes = File.ReadAllBytes(path);
                    var machineId = HardwareFingerprint.GetMachineId();
                    var key = HexToBytes(machineId);
                    var decryptedJson = DecryptStringAes(encryptedBytes, key);
                    return serializer.Deserialize<LicenseCache>(decryptedJson);
                }
                catch (Exception ex)
                {
                    Log.Write("License cache read failed: " + ex);
                    return null;
                }
            }

            public void Save(LicenseCache cache)
            {
                try
                {
                    var json = serializer.Serialize(cache);
                    var machineId = HardwareFingerprint.GetMachineId();
                    var key = HexToBytes(machineId);
                    var encryptedBytes = EncryptStringAes(json, key);
                    File.WriteAllBytes(path, encryptedBytes);
                }
                catch (Exception ex)
                {
                    Log.Write("License cache save failed: " + ex);
                }
            }

            public void Delete()
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }

            private static byte[] HexToBytes(string hex)
            {
                if (string.IsNullOrEmpty(hex) || hex.Length < 64)
                {
                    return new byte[32];
                }
                var bytes = new byte[32];
                for (int i = 0; i < 32; i++)
                {
                    bytes[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
                }
                return bytes;
            }

            private static byte[] EncryptStringAes(string plainText, byte[] key)
            {
                using (var aes = new RijndaelManaged())
                {
                    aes.KeySize = 256;
                    aes.BlockSize = 128;
                    aes.Mode = CipherMode.CBC;
                    aes.Padding = PaddingMode.PKCS7;
                    aes.Key = key;
                    var iv = new byte[16];
                    Buffer.BlockCopy(key, 0, iv, 0, 16);
                    aes.IV = iv;
                    using (var encryptor = aes.CreateEncryptor())
                    {
                        var plainBytes = Encoding.UTF8.GetBytes(plainText);
                        return encryptor.TransformFinalBlock(plainBytes, 0, plainBytes.Length);
                    }
                }
            }

            private static string DecryptStringAes(byte[] cipherData, byte[] key)
            {
                using (var aes = new RijndaelManaged())
                {
                    aes.KeySize = 256;
                    aes.BlockSize = 128;
                    aes.Mode = CipherMode.CBC;
                    aes.Padding = PaddingMode.PKCS7;
                    aes.Key = key;
                    var iv = new byte[16];
                    Buffer.BlockCopy(key, 0, iv, 0, 16);
                    aes.IV = iv;
                    using (var decryptor = aes.CreateDecryptor())
                    {
                        var decryptedBytes = decryptor.TransformFinalBlock(cipherData, 0, cipherData.Length);
                        return Encoding.UTF8.GetString(decryptedBytes);
                    }
                }
            }
        }

        private static class StrongNameValidator
        {
            [System.Runtime.InteropServices.DllImport("mscoree.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
            private static extern bool StrongNameSignatureVerificationEx(string wszFilePath, bool fForceVerification, ref bool pfWasVerified);

            public static bool IsValid(string path)
            {
                try
                {
                    if (string.IsNullOrEmpty(path) || !System.IO.File.Exists(path)) return false;
                    bool wasVerified = false;
                    return StrongNameSignatureVerificationEx(path, true, ref wasVerified) && wasVerified;
                }
                catch
                {
                    return false;
                }
            }
        }

        private static class LicenseValidator
        {
            public static bool IsUsable(LicenseCache cache, string machineId)
            {
                var entryAssembly = System.Reflection.Assembly.GetEntryAssembly();
                if (entryAssembly != null && !string.IsNullOrEmpty(entryAssembly.Location))
                {
                    if (!StrongNameValidator.IsValid(entryAssembly.Location))
                    {
                        Log.Write("Entry assembly strong-name validation failed.");
                        return false;
                    }
                }
                var currentAssembly = System.Reflection.Assembly.GetExecutingAssembly();
                if (currentAssembly != null && !string.IsNullOrEmpty(currentAssembly.Location))
                {
                    if (!StrongNameValidator.IsValid(currentAssembly.Location))
                    {
                        Log.Write("License assembly strong-name validation failed.");
                        return false;
                    }
                }

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
                
                AutoScaleDimensions = new SizeF(6F, 13F);
                AutoScaleMode = AutoScaleMode.Font;
                Font = new Font("Segoe UI", 9F);

                float scale = 1.0f;
                using (var g = CreateGraphics())
                {
                    scale = g.DpiX / 96f;
                }
                
                AutoSize = true;
                AutoSizeMode = AutoSizeMode.GrowAndShrink;
                MinimumSize = new Size((int)(520 * scale), (int)(320 * scale));

                var mainLayout = new TableLayoutPanel();
                mainLayout.Dock = DockStyle.Fill;
                mainLayout.ColumnCount = 1;
                mainLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
                mainLayout.Padding = new Padding((int)(15 * scale));
                mainLayout.AutoSize = true;
                mainLayout.AutoSizeMode = AutoSizeMode.GrowAndShrink;
                
                mainLayout.RowCount = 8;
                for (int i = 0; i < 8; i++)
                {
                    mainLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                }

                var keyLabel = new Label { Text = "Ключ лицензии:", AutoSize = true, Margin = new Padding(0, 0, 0, (int)(3 * scale)) };
                keyBox = new BorderedTextInput { Dock = DockStyle.Fill, Height = (int)(24 * scale), Margin = new Padding(0, 0, 0, (int)(10 * scale)) };
                
                var passwordLabel = new Label { Text = "Пароль переноса (8-64 символа, буквы и цифры):", AutoSize = true, Margin = new Padding(0, 0, 0, (int)(3 * scale)) };
                passwordBox = new BorderedTextInput { Dock = DockStyle.Fill, Height = (int)(24 * scale), Margin = new Padding(0, 0, 0, (int)(5 * scale)) };
                passwordBox.UseSystemPasswordChar = false;
                
                var showPassword = new CheckBox { Text = "Показать пароль", AutoSize = true, Checked = true, Margin = new Padding(0, 0, 0, (int)(10 * scale)) };
                showPassword.CheckedChanged += delegate { passwordBox.UseSystemPasswordChar = !showPassword.Checked; };

                var helpPanel = new TableLayoutPanel();
                helpPanel.Dock = DockStyle.Fill;
                helpPanel.ColumnCount = 2;
                helpPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
                helpPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, (int)(130 * scale)));
                helpPanel.AutoSize = true;
                helpPanel.AutoSizeMode = AutoSizeMode.GrowAndShrink;
                helpPanel.Margin = new Padding(0, 0, 0, (int)(10 * scale));

                var helpText = new Label
                {
                    Text = "Нет кода активации? Откройте инструкцию и получите код для этого компьютера.",
                    Dock = DockStyle.Fill,
                    AutoSize = true,
                    Margin = new Padding(0, 0, (int)(10 * scale), 0)
                };
                var helpButton = new Button { Text = "Инструкция", Width = (int)(120 * scale), Height = (int)(28 * scale), Dock = DockStyle.Right };
                helpButton.Click += delegate { OpenActivationHelp(); };
                
                helpPanel.Controls.Add(helpText, 0, 0);
                helpPanel.Controls.Add(helpButton, 1, 0);

                var demoHint = new Label
                {
                    Text = "Без активации можно продолжить в демо-режиме. После окончания таймера ZTool закроется.",
                    Dock = DockStyle.Fill,
                    AutoSize = true,
                    Margin = new Padding(0, 0, 0, (int)(10 * scale))
                };

                var buttonsPanel = new TableLayoutPanel();
                buttonsPanel.Dock = DockStyle.Fill;
                buttonsPanel.ColumnCount = 4;
                buttonsPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F)); // Spacer
                buttonsPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, (int)(120 * scale))); // Demo
                buttonsPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, (int)(120 * scale))); // Activate
                buttonsPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, (int)(120 * scale))); // Cancel
                buttonsPanel.AutoSize = true;
                buttonsPanel.AutoSizeMode = AutoSizeMode.GrowAndShrink;
                buttonsPanel.Margin = new Padding(0, (int)(5 * scale), 0, 0);

                var demoButton = new Button { Text = "Демо-режим", Height = (int)(28 * scale), Dock = DockStyle.Fill, DialogResult = DialogResult.Ignore, Margin = new Padding((int)(3 * scale)) };
                var activateButton = new Button { Text = "Активировать", Height = (int)(28 * scale), Dock = DockStyle.Fill, DialogResult = DialogResult.OK, Margin = new Padding((int)(3 * scale)) };
                var cancelButton = new Button { Text = "Выход", Height = (int)(28 * scale), Dock = DockStyle.Fill, DialogResult = DialogResult.Cancel, Margin = new Padding((int)(3 * scale)) };

                buttonsPanel.Controls.Add(new Control(), 0, 0); // Spacer
                buttonsPanel.Controls.Add(demoButton, 1, 0);
                buttonsPanel.Controls.Add(activateButton, 2, 0);
                buttonsPanel.Controls.Add(cancelButton, 3, 0);

                mainLayout.Controls.Add(keyLabel);
                mainLayout.Controls.Add(keyBox);
                mainLayout.Controls.Add(passwordLabel);
                mainLayout.Controls.Add(passwordBox);
                mainLayout.Controls.Add(showPassword);
                mainLayout.Controls.Add(helpPanel);
                mainLayout.Controls.Add(demoHint);
                mainLayout.Controls.Add(buttonsPanel);

                Controls.Add(mainLayout);
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
                        Width = Math.Max(1, Width - 8),
                        Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right,
                        BackColor = Color.White
                    };
                    textBox.GotFocus += delegate { Invalidate(); };
                    textBox.LostFocus += delegate { Invalidate(); };
                    Controls.Add(textBox);

                    Height = textBox.PreferredHeight + 8;
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

                protected override void OnFontChanged(EventArgs e)
                {
                    base.OnFontChanged(e);
                    textBox.Font = Font;
                    Height = textBox.PreferredHeight + 8;
                }

                protected override void SetBoundsCore(int x, int y, int width, int height, BoundsSpecified specified)
                {
                    if ((specified & BoundsSpecified.Height) != 0)
                    {
                        int minHeight = textBox.PreferredHeight + 8;
                        height = Math.Max(height, minHeight);
                    }
                    base.SetBoundsCore(x, y, width, height, specified);
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

                AutoScaleDimensions = new SizeF(6F, 13F);
                AutoScaleMode = AutoScaleMode.Font;
                Font = new Font("Segoe UI", 9F);
                
                float scale = 1.0f;
                using (var g = CreateGraphics())
                {
                    scale = g.DpiX / 96f;
                }
                
                AutoSize = true;
                AutoSizeMode = AutoSizeMode.GrowAndShrink;
                MinimumSize = new Size((int)(390 * scale), (int)(190 * scale));

                var mainLayout = new TableLayoutPanel();
                mainLayout.Dock = DockStyle.Fill;
                mainLayout.ColumnCount = 1;
                mainLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
                mainLayout.Padding = new Padding((int)(15 * scale));
                mainLayout.AutoSize = true;
                mainLayout.AutoSizeMode = AutoSizeMode.GrowAndShrink;

                mainLayout.RowCount = 4;
                for (int i = 0; i < 4; i++)
                {
                    mainLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                }

                var passwordLabel = new Label { Text = "Пароль переноса:", AutoSize = true, Margin = new Padding(0, 0, 0, (int)(3 * scale)) };
                passwordBox = new TextBox { Dock = DockStyle.Fill, UseSystemPasswordChar = false, Margin = new Padding(0, 0, 0, (int)(5 * scale)) };
                
                var showPassword = new CheckBox { Text = "Показать пароль", AutoSize = true, Checked = true, Margin = new Padding(0, 0, 0, (int)(10 * scale)) };
                showPassword.CheckedChanged += delegate { passwordBox.UseSystemPasswordChar = !showPassword.Checked; };

                var buttonsPanel = new TableLayoutPanel();
                buttonsPanel.Dock = DockStyle.Fill;
                buttonsPanel.ColumnCount = 3;
                buttonsPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F)); // Spacer
                buttonsPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, (int)(100 * scale))); // OK
                buttonsPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, (int)(100 * scale))); // Cancel
                buttonsPanel.AutoSize = true;
                buttonsPanel.AutoSizeMode = AutoSizeMode.GrowAndShrink;
                buttonsPanel.Margin = new Padding(0, (int)(5 * scale), 0, 0);

                var okButton = new Button { Text = "ОК", Height = (int)(28 * scale), Dock = DockStyle.Fill, DialogResult = DialogResult.OK, Margin = new Padding((int)(3 * scale)) };
                var cancelButton = new Button { Text = "Отмена", Height = (int)(28 * scale), Dock = DockStyle.Fill, DialogResult = DialogResult.Cancel, Margin = new Padding((int)(3 * scale)) };

                buttonsPanel.Controls.Add(new Control(), 0, 0); // Spacer
                buttonsPanel.Controls.Add(okButton, 1, 0);
                buttonsPanel.Controls.Add(cancelButton, 2, 0);

                mainLayout.Controls.Add(passwordLabel);
                mainLayout.Controls.Add(passwordBox);
                mainLayout.Controls.Add(showPassword);
                mainLayout.Controls.Add(buttonsPanel);

                Controls.Add(mainLayout);
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
        public const int OfflineGraceDays = 7;
    }
#endif

    internal static class Decryptor
    {
        public static string Dec(string str)
        {
            if (str == null) return null;
            char[] chars = new char[str.Length];
            for (int i = 0; i < str.Length; i++)
            {
                chars[i] = (char)(str[i] ^ 0x5A);
            }
            return new string(chars);
        }
    }

    public static class LanguageManager
    {
        private static object GetConfig()
        {
            try
            {
                Type mngType = Type.GetType("ZTool.CConfigMng, ZTool");
                if (mngType == null)
                {
                    mngType = Type.GetType("ZTool.CConfigMng, ZTool.Core");
                }
                if (mngType == null)
                {
                    foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
                    {
                        foreach (var t in assembly.GetTypes())
                        {
                            if (t.FullName == "ZTool.CConfigMng")
                            {
                                mngType = t;
                                break;
                            }
                        }
                        if (mngType != null) break;
                    }
                }
                                  
                if (mngType != null)
                {
                    var configProp = mngType.GetProperty("Config");
                    if (configProp != null)
                    {
                        return configProp.GetValue(null, null);
                    }
                }
            }
            catch {}
            return null;
        }

        public static string GetConfigLanguage()
        {
            try
            {
                var config = GetConfig();
                if (config != null)
                {
                    var field = config.GetType().GetField("Language");
                    if (field != null)
                    {
                        var val = field.GetValue(config) as string;
                        if (!string.IsNullOrEmpty(val)) return val;
                    }
                }
            }
            catch {}
            return "Russian";
        }

        public static void SetConfigLanguage(string lang)
        {
            try
            {
                var config = GetConfig();
                if (config != null)
                {
                    var field = config.GetType().GetField("Language");
                    if (field != null)
                    {
                        field.SetValue(config, lang);
                    }
                }
            }
            catch {}
        }

        public static string Translate(string s)
        {
            if (string.IsNullOrEmpty(s)) return s;
            if (GetConfigLanguage() != "English") return s;
            
            string key = s.Trim();
            string translated;
            if (LanguageDictionary.RuToEn.TryGetValue(key, out translated))
            {
                var sb = new StringBuilder();
                int leadingSpaces = 0;
                while (leadingSpaces < s.Length && char.IsWhiteSpace(s[leadingSpaces]))
                {
                    sb.Append(s[leadingSpaces]);
                    leadingSpaces++;
                }
                sb.Append(translated);
                int trailingIdx = s.Length - 1;
                var trailingSb = new StringBuilder();
                while (trailingIdx >= leadingSpaces && char.IsWhiteSpace(s[trailingIdx]))
                {
                    trailingSb.Insert(0, s[trailingIdx]);
                    trailingIdx--;
                }
                sb.Append(trailingSb.ToString());
                return sb.ToString();
            }
            return s;
        }

        public static void TranslateForm(Form form)
        {
            if (GetConfigLanguage() != "English") return;
            try
            {
                form.Text = Translate(form.Text);
                TranslateControls(form.Controls);
                if (form.ContextMenuStrip != null)
                {
                    TranslateToolStrip(form.ContextMenuStrip);
                }
            }
            catch {}
        }

        private static void TranslateControls(Control.ControlCollection controls)
        {
            if (controls == null) return;
            foreach (Control ctrl in controls)
            {
                try
                {
                    ctrl.Text = Translate(ctrl.Text);
                    
                    ComboBox cb = ctrl as ComboBox;
                    if (cb != null)
                    {
                        for (int i = 0; i < cb.Items.Count; i++)
                        {
                            string s = cb.Items[i] as string;
                            if (s != null)
                            {
                                cb.Items[i] = Translate(s);
                            }
                        }
                    }
                    else
                    {
                        ListBox lb = ctrl as ListBox;
                        if (lb != null)
                        {
                            for (int i = 0; i < lb.Items.Count; i++)
                            {
                                string s = lb.Items[i] as string;
                                if (s != null)
                                {
                                    lb.Items[i] = Translate(s);
                                }
                            }
                        }
                        else
                        {
                            DataGridView dgv = ctrl as DataGridView;
                            if (dgv != null)
                            {
                                foreach (DataGridViewColumn col in dgv.Columns)
                                {
                                    col.HeaderText = Translate(col.HeaderText);
                                    col.ToolTipText = Translate(col.ToolTipText);
                                }
                            }
                            else
                            {
                                ToolStrip ts = ctrl as ToolStrip;
                                if (ts != null)
                                {
                                    TranslateToolStrip(ts);
                                }
                            }
                        }
                    }
                    
                    if (ctrl.ContextMenuStrip != null)
                    {
                        TranslateToolStrip(ctrl.ContextMenuStrip);
                    }
                    
                    if (ctrl.HasChildren)
                    {
                        TranslateControls(ctrl.Controls);
                    }
                }
                catch {}
            }
        }

        private static void TranslateToolStrip(ToolStrip ts)
        {
            if (ts == null) return;
            foreach (ToolStripItem item in ts.Items)
            {
                TranslateToolStripItem(item);
            }
        }

        private static void TranslateToolStripItem(ToolStripItem item)
        {
            if (item == null) return;
            try
            {
                item.Text = Translate(item.Text);
                item.ToolTipText = Translate(item.ToolTipText);
                
                ToolStripDropDownItem dropDown = item as ToolStripDropDownItem;
                if (dropDown != null)
                {
                    foreach (ToolStripItem subItem in dropDown.DropDownItems)
                    {
                        TranslateToolStripItem(subItem);
                    }
                }
            }
            catch {}
        }

        public static void AddLanguageSelector(Form optionsForm)
        {
            try
            {
                var tabControlProp = optionsForm.GetType().GetProperty("TabControl1");
                if (tabControlProp != null)
                {
                    var tabControl = (TabControl)tabControlProp.GetValue(optionsForm, null);
                    
                    var tabPage = new TabPage("Language / Язык");
                    tabPage.Padding = new Padding(10);
                    
                    var label = new Label();
                    label.Text = "Выберите язык / Select language:";
                    label.Location = new Point(20, 20);
                    label.AutoSize = true;
                    
                    var comboBox = new ComboBox();
                    comboBox.DropDownStyle = ComboBoxStyle.DropDownList;
                    comboBox.Items.Add("Русский");
                    comboBox.Items.Add("English");
                    comboBox.Location = new Point(20, 50);
                    comboBox.Width = 200;
                    
                    string currentLang = GetConfigLanguage();
                    if (currentLang == "English")
                    {
                        comboBox.SelectedIndex = 1;
                    }
                    else
                    {
                        comboBox.SelectedIndex = 0;
                    }
                    
                    comboBox.SelectedIndexChanged += (sender, args) =>
                    {
                        string selected = comboBox.SelectedIndex == 1 ? "English" : "Russian";
                        SetConfigLanguage(selected);
                    };
                    
                    tabPage.Controls.Add(label);
                    tabPage.Controls.Add(comboBox);
                    tabControl.TabPages.Add(tabPage);
                    
                    if (GetConfigLanguage() == "English")
                    {
                        tabPage.Text = "Language";
                        label.Text = "Select language:";
                    }
                }
            }
            catch {}
        }

        public static DialogResult ShowMessageBox(string text)
        {
            return MessageBox.Show(Translate(text));
        }

        public static DialogResult ShowMessageBox(string text, string caption)
        {
            return MessageBox.Show(Translate(text), Translate(caption));
        }

        public static DialogResult ShowMessageBox(string text, string caption, MessageBoxButtons buttons)
        {
            return MessageBox.Show(Translate(text), Translate(caption), buttons);
        }

        public static DialogResult ShowMessageBox(string text, string caption, MessageBoxButtons buttons, MessageBoxIcon icon)
        {
            return MessageBox.Show(Translate(text), Translate(caption), buttons, icon);
        }

        public static DialogResult ShowMessageBox(string text, string caption, MessageBoxButtons buttons, MessageBoxIcon icon, MessageBoxDefaultButton defaultButton)
        {
            return MessageBox.Show(Translate(text), Translate(caption), buttons, icon, defaultButton);
        }

        public static DialogResult ShowMessageBox(IWin32Window owner, string text)
        {
            return MessageBox.Show(owner, Translate(text));
        }

        public static DialogResult ShowMessageBox(IWin32Window owner, string text, string caption)
        {
            return MessageBox.Show(owner, Translate(text), Translate(caption));
        }

        public static DialogResult ShowMessageBox(IWin32Window owner, string text, string caption, MessageBoxButtons buttons)
        {
            return MessageBox.Show(owner, Translate(text), Translate(caption), buttons);
        }

        public static DialogResult ShowMessageBox(IWin32Window owner, string text, string caption, MessageBoxButtons buttons, MessageBoxIcon icon)
        {
            return MessageBox.Show(owner, Translate(text), Translate(caption), buttons, icon);
        }

        public static DialogResult ShowMessageBox(IWin32Window owner, string text, string caption, MessageBoxButtons buttons, MessageBoxIcon icon, MessageBoxDefaultButton defaultButton)
        {
            return MessageBox.Show(owner, Translate(text), Translate(caption), buttons, icon, defaultButton);
        }
    }
}
