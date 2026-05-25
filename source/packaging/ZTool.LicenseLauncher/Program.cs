using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Management;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;
using System.Xml;

namespace ZTool.LicenseLauncher
{
    internal static class Program
    {
        private const string ProductId = "ztool";

        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                var appDir = AppDomain.CurrentDomain.BaseDirectory;
                var config = LauncherConfig.Load(appDir);
                var machineId = HardwareFingerprint.GetMachineId();
                var store = new LicenseStore();

                if (HasArg(args, "--deactivate"))
                {
                    Deactivate(config, store, machineId);
                    return;
                }

                var cache = store.Load();
                bool needOnlineCheck = false;
                if (cache != null)
                {
                    var age = DateTime.UtcNow - cache.LastOnlineCheckUtc;
                    if (age.TotalDays > config.OfflineGraceDays)
                    {
                        needOnlineCheck = true;
                    }
                }

                if (!LicenseValidator.IsUsable(cache, config, machineId) || needOnlineCheck)
                {
                    if (cache != null && LicenseValidator.IsUsable(cache, config, machineId) && needOnlineCheck)
                    {
                        try
                        {
                            var client = new LicenseClient(config);
                            var newCache = client.Activate(cache.Key, string.Empty, machineId);
                            if (LicenseValidator.IsUsable(newCache, config, machineId))
                            {
                                cache = newCache;
                                store.Save(cache);
                                needOnlineCheck = false;
                            }
                        }
                        catch (Exception ex)
                        {
                            Log.Write("Online revalidation failed: " + ex.Message);
                            cache = null;
                        }
                    }

                    if (cache == null || !LicenseValidator.IsUsable(cache, config, machineId))
                    {
                        cache = ShowActivation(config, machineId);
                        if (cache == null)
                        {
                            return;
                        }

                        store.Save(cache);
                    }
                }

                var payloadKey = string.Empty;
                try
                {
                    var serializer = new JavaScriptSerializer();
                    var payload = serializer.DeserializeObject(cache.SignedPayload) as Dictionary<string, object>;
                    if (payload != null && payload.ContainsKey("payloadKey"))
                    {
                        payloadKey = Convert.ToString(payload["payloadKey"]);
                    }
                }
                catch (Exception ex)
                {
                    Log.Write("Failed to parse payload key: " + ex.Message);
                }

                using (var runtime = CoreRuntime.Prepare(config, appDir, payloadKey))
                {
                    var process = LaunchCore(appDir, runtime.ExecutablePath, args);
                    runtime.WaitAndCleanup(process);
                }
            }
            catch (Exception ex)
            {
                Log.Write("Fatal launcher error: " + ex);
                MessageBox.Show(
                    "Не удалось запустить ZTool.\r\n\r\n" + ex.Message,
                    "ZTool",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }

        private static bool HasArg(string[] args, string value)
        {
            foreach (var arg in args)
            {
                if (string.Equals(arg, value, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }

        private static LicenseCache ShowActivation(LauncherConfig config, string machineId)
        {
            using (var form = new ActivationForm())
            {
                while (form.ShowDialog() == DialogResult.OK)
                {
                    try
                    {
                        var client = new LicenseClient(config);
                        var cache = client.Activate(form.LicenseKey, form.TransferPassword, machineId);

                        if (!LicenseValidator.IsUsable(cache, config, machineId))
                        {
                            MessageBox.Show(
                                "Сервер вернул лицензию, но локальная проверка не прошла.",
                                "ZTool",
                                MessageBoxButtons.OK,
                                MessageBoxIcon.Error);
                            continue;
                        }

                        return cache;
                    }
                    catch (Exception ex)
                    {
                        Log.Write("Activation failed: " + ex);
                        MessageBox.Show(
                            ex.Message,
                            "Активация ZTool",
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Warning);
                    }
                }
            }

            return null;
        }

        private static void Deactivate(LauncherConfig config, LicenseStore store, string machineId)
        {
            var cache = store.Load();
            if (cache == null || string.IsNullOrWhiteSpace(cache.Key))
            {
                MessageBox.Show("На этом пользователе нет сохраненной лицензии ZTool.", "ZTool", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            using (var form = new PasswordForm())
            {
                if (form.ShowDialog() != DialogResult.OK)
                {
                    return;
                }

                try
                {
                    var client = new LicenseClient(config);
                    client.Deactivate(cache.Key, form.TransferPassword, machineId);
                    store.Delete();
                    MessageBox.Show("Лицензия деактивирована. Теперь ключ можно активировать на другом ПК.", "ZTool", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                catch (Exception ex)
                {
                    Log.Write("Deactivation failed: " + ex);
                    MessageBox.Show(ex.Message, "Деактивация ZTool", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
        }

        private static Process LaunchCore(string appDir, string corePath, string[] args)
        {
            if (!File.Exists(corePath))
            {
                throw new FileNotFoundException("Не найден основной исполняемый файл ZTool.", corePath);
            }

            var psi = new ProcessStartInfo
            {
                FileName = corePath,
                WorkingDirectory = appDir,
                UseShellExecute = true,
                Arguments = JoinArguments(args)
            };
            return Process.Start(psi);
        }

        private static string JoinArguments(string[] args)
        {
            if (args == null || args.Length == 0)
            {
                return string.Empty;
            }

            var result = new StringBuilder();
            foreach (var arg in args)
            {
                if (string.Equals(arg, "--deactivate", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                if (result.Length > 0)
                {
                    result.Append(' ');
                }

                result.Append('"').Append(arg.Replace("\"", "\\\"")).Append('"');
            }

            return result.ToString();
        }
    }

    internal sealed class LauncherConfig
    {
        public string LicenseBaseUrl = EmbeddedLicenseConfig.LicenseBaseUrl.TrimEnd('/');
        public string CoreExecutable = "ZTool.Core.exe";
        public string CorePayload = "ZTool.Core.payload";
        public string PublicKeyXml = EmbeddedLicenseConfig.PublicKeyXml;
        public string AppVersion = "3.8.4";
        public int OfflineGraceDays = 7;

        public static LauncherConfig Load(string appDir)
        {
            var config = new LauncherConfig();
            var path = Path.Combine(appDir, "ZTool.LicenseLauncher.config");
            if (!File.Exists(path))
            {
                return config;
            }

            var doc = new XmlDocument();
            doc.Load(path);
            config.CoreExecutable = Read(doc, "CoreExecutable", config.CoreExecutable);
            config.CorePayload = Read(doc, "CorePayload", config.CorePayload);
            config.AppVersion = Read(doc, "AppVersion", config.AppVersion);

            int days;
            if (int.TryParse(Read(doc, "OfflineGraceDays", config.OfflineGraceDays.ToString(CultureInfo.InvariantCulture)), NumberStyles.Integer, CultureInfo.InvariantCulture, out days))
            {
                config.OfflineGraceDays = Math.Max(0, days);
            }

            return config;
        }

        private static string Read(XmlDocument doc, string name, string fallback)
        {
            var node = doc.SelectSingleNode("/ZToolLicenseLauncher/" + name);
            return node == null ? fallback : node.InnerText;
        }
    }

    internal sealed class CoreRuntime : IDisposable
    {
        private readonly string temporaryPath;

        private CoreRuntime(string executablePath, string temporaryPath)
        {
            ExecutablePath = executablePath;
            this.temporaryPath = temporaryPath;
        }

        public string ExecutablePath { get; private set; }

        public static CoreRuntime Prepare(LauncherConfig config, string appDir, string payloadKey)
        {
            var payloadPath = Path.Combine(appDir, config.CorePayload);
            if (!File.Exists(payloadPath))
            {
                return new CoreRuntime(Path.Combine(appDir, config.CoreExecutable), null);
            }

            var runtimePath = Path.Combine(appDir, "ZTool.Core." + Guid.NewGuid().ToString("N") + ".exe");
            var encrypted = File.ReadAllBytes(payloadPath);
            var decrypted = PayloadProtector.Decrypt(encrypted, payloadKey);
            File.WriteAllBytes(runtimePath, decrypted);
            File.SetAttributes(runtimePath, FileAttributes.Hidden);
            return new CoreRuntime(runtimePath, runtimePath);
        }

        public void WaitAndCleanup(Process process)
        {
            try
            {
                if (process != null)
                {
                    process.WaitForExit();
                }
            }
            catch (Exception ex)
            {
                Log.Write("Core wait failed: " + ex);
            }
            finally
            {
                Cleanup();
            }
        }

        public void Dispose()
        {
            Cleanup();
        }

        private void Cleanup()
        {
            if (string.IsNullOrWhiteSpace(temporaryPath))
            {
                return;
            }

            for (var i = 0; i < 20; i++)
            {
                try
                {
                    if (File.Exists(temporaryPath))
                    {
                        File.SetAttributes(temporaryPath, FileAttributes.Normal);
                        File.Delete(temporaryPath);
                    }

                    return;
                }
                catch
                {
                    System.Threading.Thread.Sleep(250);
                }
            }
        }
    }

    internal static class PayloadProtector
    {
        public static byte[] Decrypt(byte[] encrypted, string payloadKey)
        {
            if (encrypted == null || encrypted.Length <= 16)
            {
                throw new InvalidDataException("ZTool payload is invalid.");
            }

            var iv = new byte[16];
            Buffer.BlockCopy(encrypted, 0, iv, 0, iv.Length);
            var cipher = new byte[encrypted.Length - iv.Length];
            Buffer.BlockCopy(encrypted, iv.Length, cipher, 0, cipher.Length);

            using (var aes = new RijndaelManaged())
            {
                aes.KeySize = 256;
                aes.BlockSize = 128;
                aes.Mode = CipherMode.CBC;
                aes.Padding = PaddingMode.PKCS7;
                aes.Key = DeriveKey(payloadKey);
                aes.IV = iv;

                using (var decryptor = aes.CreateDecryptor())
                {
                    return decryptor.TransformFinalBlock(cipher, 0, cipher.Length);
                }
            }
        }

        private static byte[] DeriveKey(string payloadKey)
        {
            if (string.IsNullOrEmpty(payloadKey))
            {
                throw new InvalidOperationException("Ключ расшифровки payload отсутствует.");
            }
            using (var sha = SHA256.Create())
            {
                return sha.ComputeHash(Encoding.UTF8.GetBytes(payloadKey));
            }
        }
    }

    internal sealed class LicenseClient
    {
        private const SecurityProtocolType Tls12 = (SecurityProtocolType)3072;
        private static bool tlsConfigured;

        private readonly LauncherConfig config;
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();

        public LicenseClient(LauncherConfig config)
        {
            this.config = config;
        }

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
                { "appVersion", config.AppVersion },
                { "machineMeta", new Dictionary<string, object>
                    {
                        { "osVersion", Environment.OSVersion.VersionString },
                        { "is64BitOS", Environment.Is64BitOperatingSystem }
                    }
                }
            };

            var response = Post(config.LicenseBaseUrl + "/api/activate.php", request);
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

            Post(config.LicenseBaseUrl + "/api/deactivate.php", request);
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
                var message = ex.Message;
                if (ex.Response != null)
                {
                    using (var stream = ex.Response.GetResponseStream())
                    using (var reader = new StreamReader(stream, Encoding.UTF8))
                    {
                        var text = reader.ReadToEnd();
                        var serverMessage = TryReadServerError(text);
                        message = string.IsNullOrWhiteSpace(serverMessage) ? text : serverMessage;
                    }
                }

                throw new InvalidOperationException(string.IsNullOrWhiteSpace(message) ? "Сервер лицензирования недоступен." : message, ex);
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
    }

    internal sealed class LicenseCache
    {
        public string Key { get; set; }
        public string MachineId { get; set; }
        public string SignedPayload { get; set; }
        public string Signature { get; set; }
        public DateTime LastOnlineCheckUtc { get; set; }
    }

    internal sealed class LicenseStore
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

    internal static class LicenseValidator
    {
        public static bool IsUsable(LicenseCache cache, LauncherConfig config, string machineId)
        {
            if (cache == null || cache.MachineId == null || !cache.MachineId.Equals(machineId, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            if (string.IsNullOrWhiteSpace(cache.SignedPayload) || string.IsNullOrWhiteSpace(cache.Signature))
            {
                return false;
            }

            if (string.IsNullOrWhiteSpace(config.PublicKeyXml))
            {
                Log.Write("License public key is not embedded.");
                return false;
            }

            if (!VerifySignature(cache.SignedPayload, cache.Signature, config.PublicKeyXml))
            {
                return false;
            }

            var serializer = new JavaScriptSerializer();
            var payload = serializer.DeserializeObject(cache.SignedPayload) as Dictionary<string, object>;
            if (payload == null)
            {
                return false;
            }

            if (!EqualsString(payload, "productId", ProgramProductId) || !EqualsString(payload, "machineId", machineId))
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

            object expiresAt;
            if (payload.TryGetValue("expiresAt", out expiresAt) && expiresAt != null)
            {
                var text = Convert.ToString(expiresAt, CultureInfo.InvariantCulture);
                if (!string.IsNullOrWhiteSpace(text))
                {
                    DateTime expires;
                    if (DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out expires) && expires < DateTime.Now)
                    {
                        return false;
                    }
                }
            }

            return true;
        }

        private const string ProgramProductId = "ztool";

        private static bool EqualsString(Dictionary<string, object> payload, string name, string expected)
        {
            object value;
            return payload.TryGetValue(name, out value) && value != null && string.Equals(Convert.ToString(value, CultureInfo.InvariantCulture), expected, StringComparison.OrdinalIgnoreCase);
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

            if (raw is int || raw is long || raw is short || raw is byte)
            {
                value = Convert.ToInt64(raw, CultureInfo.InvariantCulture) != 0;
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

            if (string.Equals(text, "1", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(text, "yes", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(text, "y", StringComparison.OrdinalIgnoreCase))
            {
                value = true;
                return true;
            }

            if (string.Equals(text, "0", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(text, "no", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(text, "n", StringComparison.OrdinalIgnoreCase))
            {
                value = false;
                return true;
            }

            return false;
        }

        private static bool VerifySignature(string signedPayload, string signature, string publicKeyXml)
        {
            try
            {
                using (var rsa = new RSACryptoServiceProvider())
                {
                    rsa.FromXmlString(publicKeyXml);
                    return rsa.VerifyData(
                        Encoding.UTF8.GetBytes(signedPayload),
                        CryptoConfig.MapNameToOID("SHA256"),
                        Convert.FromBase64String(signature));
                }
            }
            catch (Exception ex)
            {
                Log.Write("Signature verification failed: " + ex);
                return false;
            }
        }
    }

    internal static class HardwareFingerprint
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

    internal sealed class ActivationForm : Form
    {
        private readonly TextBox keyBox;
        private readonly TextBox passwordBox;

        public ActivationForm()
        {
            Text = "Активация ZTool";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new System.Drawing.Size(430, 190);

            var keyLabel = new Label { Left = 16, Top = 18, Width = 390, Text = "Ключ лицензии:" };
            keyBox = new TextBox { Left = 16, Top = 40, Width = 395 };

            var passwordLabel = new Label { Left = 16, Top = 74, Width = 390, Text = "Пароль переноса (8-64 символа, буквы и цифры):" };
            passwordBox = new TextBox { Left = 16, Top = 96, Width = 395, UseSystemPasswordChar = false };

            var showPassword = new CheckBox { Left = 16, Top = 124, Width = 140, Text = "Показать пароль", Checked = true };
            showPassword.CheckedChanged += delegate { passwordBox.UseSystemPasswordChar = !showPassword.Checked; };

            var activateButton = new Button { Left = 235, Top = 148, Width = 85, Text = "Активировать", DialogResult = DialogResult.OK };
            var cancelButton = new Button { Left = 326, Top = 148, Width = 85, Text = "Отмена", DialogResult = DialogResult.Cancel };

            Controls.AddRange(new Control[] { keyLabel, keyBox, passwordLabel, passwordBox, showPassword, activateButton, cancelButton });
            AcceptButton = activateButton;
            CancelButton = cancelButton;
        }

        public string LicenseKey
        {
            get { return keyBox.Text.Trim(); }
        }

        public string TransferPassword
        {
            get { return passwordBox.Text; }
        }
    }

    internal sealed class PasswordForm : Form
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

        public string TransferPassword
        {
            get { return passwordBox.Text; }
        }
    }

    internal static class Log
    {
        public static void Write(string message)
        {
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SWTools");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "ZTool.LicenseLauncher.log"), DateTime.Now.ToString("s", CultureInfo.InvariantCulture) + " " + message + Environment.NewLine, Encoding.UTF8);
            }
            catch
            {
            }
        }
    }

#if !ZTOOL_EMBEDDED_LICENSE_CONFIG
    internal static class EmbeddedLicenseConfig
    {
        public const string LicenseBaseUrl = "https://license.vizbuka.ru/ztool";
        public const string PublicKeyXml = "";
        public const string PayloadKey = "development-payload-key";
    }
#endif
}
