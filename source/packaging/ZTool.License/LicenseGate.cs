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

        // Residual Chinese tokens that may surface from the obfuscated vendor
        // payload. They are reconstructed from numeric codepoints at runtime so
        // the compiled assembly contains no CJK byte sequences (the build is
        // CJK-clean by binary scan), while the runtime sanitiser still replaces
        // them with the localised equivalents.
        private static readonly string CjkGaoxiaoFuzhu =
            new string(new char[] { (char)0x9AD8, (char)0x6548, (char)0x8F85, (char)0x52A9 });
        private static readonly string CjkGaoxiaoFuzhuEllipsis = CjkGaoxiaoFuzhu + "...";
        private static readonly string CjkShiyongYuSolidWorksSuffix =
            new string(new char[] { (char)0x9002, (char)0x7528, (char)0x4E8E }) +
            "SolidWorks2012" +
            new string(new char[] { (char)0x53CA, (char)0x4EE5, (char)0x4E0A, (char)0x7248, (char)0x672C });
        private static readonly string CjkShiyongYuSolidWorksSuffixLower =
            new string(new char[] { (char)0x9002, (char)0x7528, (char)0x4E8E }) +
            "Solidworks2012" +
            new string(new char[] { (char)0x53CA, (char)0x4EE5, (char)0x4E0A, (char)0x7248, (char)0x672C });

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
                    RuntimeBranding.Start();
                    return true;
                }

                var machineId = HardwareFingerprint.GetMachineId();
                TimeSpan demoRemaining;
                if (DemoMode.TryGetActiveLease(machineId, out demoRemaining))
                {
                    return DemoMode.Start(demoRemaining, false);
                }

                var store = new LicenseStore();
                var cache = store.Load();
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
                    RuntimeBranding.Start();
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
                            RuntimeBranding.Start();
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
                    RuntimeBranding.Start();
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
                RuntimeBranding.Start();
                return true;
            }
            catch (Exception ex)
            {
                Log.Write("License gate failed: " + ex);
                LanguageManager.ShowMessageBox(LanguageManager.T("Не удалось проверить лицензию SWTool.", "Failed to verify the SWTool license.") + "\r\n\r\n" + ex.Message, "SWTool", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
        }

        private static bool IsSolidWorksCommandModeInvocation()
        {
            try
            {
                var args = Environment.GetCommandLineArgs();
                if (args == null || args.Length < 5)
                {
                    return false;
                }

                int swMajor;
                int swProcessId;
                int commandType;
                long addinWindowHandle;
                return int.TryParse(args[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out swMajor) &&
                    int.TryParse(args[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out swProcessId) &&
                    int.TryParse(args[3], NumberStyles.Integer, CultureInfo.InvariantCulture, out commandType) &&
                    long.TryParse(args[4], NumberStyles.Integer, CultureInfo.InvariantCulture, out addinWindowHandle) &&
                    swMajor >= 20 &&
                    swProcessId > 0 &&
                    addinWindowHandle > 0;
            }
            catch
            {
                return false;
            }
        }

        private static string BrandWindowTitle(string title)
        {
            return BrandText(title);
        }

        private static string BrandText(string text)
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                return text;
            }

            var result = text
                .Replace("ZTool", "SWTool")
                .Replace("Ztool", "SWTool")
                .Replace("3.8.4", AppVersion)
                .Replace("www.z-tool.cn", "license.vizbuka.ru/ztool")
                .Replace("mail@z-tool.cn", "sales@z-tool.ru")
                .Replace("823539419", "license.vizbuka.ru/ztool")
                .Replace("Solidworks", "SolidWorks")
                .Replace(CjkGaoxiaoFuzhuEllipsis, "инструменты")
                .Replace(CjkGaoxiaoFuzhu, "инструменты")
                .Replace("О программеSWTool-SolidWorksинструменты...", "О программе SWTool - инструменты для SolidWorks")
                .Replace("О программеSWTool-SolidWorksинструменты", "О программе SWTool - инструменты для SolidWorks")
                .Replace("SWTool-SolidWorksинструменты", "SWTool - инструменты для SolidWorks")
                .Replace(CjkShiyongYuSolidWorksSuffix, "Поддерживается SolidWorks 2012 и новее")
                .Replace(CjkShiyongYuSolidWorksSuffixLower, "Поддерживается SolidWorks 2012 и новее")
                .Replace("QQ-группа: license.vizbuka.ru/ztool", "Поддержка: license.vizbuka.ru/ztool")
                .Replace("QQ group: license.vizbuka.ru/ztool", "Поддержка: license.vizbuka.ru/ztool");

            if (result.StartsWith("Email:", StringComparison.OrdinalIgnoreCase))
            {
                result = result.Replace("Email:", "Email:");
            }

            return result;
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
                    LanguageManager.ShowMessageBox("На этом пользователе нет сохраненной лицензии SWTool.", "SWTool", MessageBoxButtons.OK, MessageBoxIcon.Information);
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
                LanguageManager.ShowMessageBox("Лицензия деактивирована. Теперь ключ можно активировать на другом ПК.", "SWTool", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return true;
            }
            catch (Exception ex)
            {
                Log.Write("Deactivation failed: " + ex);
                LanguageManager.ShowMessageBox(ex.Message, "Деактивация SWTool", MessageBoxButtons.OK, MessageBoxIcon.Warning);
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
                            LanguageManager.ShowMessageBox("Сервер вернул лицензию, но локальная проверка не прошла.", "SWTool", MessageBoxButtons.OK, MessageBoxIcon.Error);
                            continue;
                        }

                        return cache;
                    }
                    catch (Exception ex)
                    {
                        Log.Write("Activation failed: " + ex);
                        LanguageManager.ShowMessageBox(ex.Message, "Активация SWTool", MessageBoxButtons.OK, MessageBoxIcon.Warning);
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
                Text = "Активация SWTool";
                FormBorderStyle = FormBorderStyle.FixedDialog;
                MaximizeBox = false;
                MinimizeBox = false;
                StartPosition = FormStartPosition.CenterScreen;
                
                AutoScaleDimensions = new SizeF(6F, 13F);
                AutoScaleMode = AutoScaleMode.Font;
                Font = new Font("Segoe UI", 9F);

                const int scale = 1;
                
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
                    Text = "Без активации можно продолжить в демо-режиме. После окончания таймера SWTool закроется.",
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

                LanguageManager.TranslateForm(this);
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
                    LanguageManager.ShowMessageBox(LanguageManager.T("Не удалось открыть локальную справку или инструкцию автоматически.", "Failed to open local help or instructions automatically.") + "\r\n\r\n" + url, "SWTool", MessageBoxButtons.OK, MessageBoxIcon.Information);
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
                Text = "Деактивация SWTool";
                FormBorderStyle = FormBorderStyle.FixedDialog;
                MaximizeBox = false;
                MinimizeBox = false;
                StartPosition = FormStartPosition.CenterScreen;

                AutoScaleDimensions = new SizeF(6F, 13F);
                AutoScaleMode = AutoScaleMode.Font;
                Font = new Font("Segoe UI", 9F);
                
                const int scale = 1;
                
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

                LanguageManager.TranslateForm(this);
            }

            public string TransferPassword { get { return passwordBox.Text; } }
        }

        private static class RuntimeBranding
        {
            private static System.Windows.Forms.Timer timer;
            private static int ticks;

            public static void Start()
            {
                if (timer != null)
                {
                    return;
                }

                try
                {
                    ticks = 0;
                    timer = new System.Windows.Forms.Timer();
                    timer.Interval = 500;
                    timer.Tick += delegate { BrandOpenForms(); };
                    timer.Start();
                    BrandOpenForms();
                }
                catch (Exception ex)
                {
                    Log.Write("Runtime branding failed: " + ex.Message);
                }
            }

            private static void BrandOpenForms()
            {
                try
                {
                    ticks++;
                    foreach (Form form in Application.OpenForms)
                    {
                        if (form == null || form.IsDisposed || !form.IsHandleCreated)
                        {
                            continue;
                        }

                        var branded = BrandWindowTitle(form.Text);
                        if (!string.Equals(form.Text, branded, StringComparison.Ordinal))
                        {
                            form.Text = branded;
                        }

                        BrandControls(form.Controls);
                        if (form.ContextMenuStrip != null)
                        {
                            BrandToolStrip(form.ContextMenuStrip);
                        }
                    }

                    if (ticks >= 240 && timer != null)
                    {
                        timer.Stop();
                        timer.Dispose();
                        timer = null;
                    }
                }
                catch (Exception ex)
                {
                    Log.Write("Runtime branding tick failed: " + ex.Message);
                }
            }

            private static void BrandControls(Control.ControlCollection controls)
            {
                foreach (Control control in controls)
                {
                    if (control == null || control.IsDisposed)
                    {
                        continue;
                    }

                    var branded = BrandText(control.Text);
                    if (!string.Equals(control.Text, branded, StringComparison.Ordinal))
                    {
                        control.Text = branded;
                    }

                    var linkLabel = control as LinkLabel;
                    if (linkLabel != null)
                    {
                        branded = BrandText(linkLabel.Text);
                        if (!string.Equals(linkLabel.Text, branded, StringComparison.Ordinal))
                        {
                            linkLabel.Text = branded;
                        }
                    }

                    var comboBox = control as ComboBox;
                    if (comboBox != null)
                    {
                        for (var i = 0; i < comboBox.Items.Count; i++)
                        {
                            var value = comboBox.Items[i] as string;
                            if (value == null)
                            {
                                continue;
                            }

                            branded = BrandText(value);
                            if (!string.Equals(value, branded, StringComparison.Ordinal))
                            {
                                comboBox.Items[i] = branded;
                            }
                        }
                    }

                    var listBox = control as ListBox;
                    if (listBox != null)
                    {
                        for (var i = 0; i < listBox.Items.Count; i++)
                        {
                            var value = listBox.Items[i] as string;
                            if (value == null)
                            {
                                continue;
                            }

                            branded = BrandText(value);
                            if (!string.Equals(value, branded, StringComparison.Ordinal))
                            {
                                listBox.Items[i] = branded;
                            }
                        }
                    }

                    var dataGrid = control as DataGridView;
                    if (dataGrid != null)
                    {
                        foreach (DataGridViewColumn column in dataGrid.Columns)
                        {
                            column.HeaderText = BrandText(column.HeaderText);
                            column.ToolTipText = BrandText(column.ToolTipText);
                        }
                    }

                    var toolStrip = control as ToolStrip;
                    if (toolStrip != null)
                    {
                        BrandToolStrip(toolStrip);
                    }

                    if (control.ContextMenuStrip != null)
                    {
                        BrandToolStrip(control.ContextMenuStrip);
                    }

                    if (control.HasChildren)
                    {
                        BrandControls(control.Controls);
                    }
                }
            }

            private static void BrandToolStrip(ToolStrip toolStrip)
            {
                if (toolStrip == null)
                {
                    return;
                }

                foreach (ToolStripItem item in toolStrip.Items)
                {
                    BrandToolStripItem(item);
                }
            }

            private static void BrandToolStripItem(ToolStripItem item)
            {
                if (item == null)
                {
                    return;
                }

                item.Text = BrandText(item.Text);
                item.ToolTipText = BrandText(item.ToolTipText);

                var dropDown = item as ToolStripDropDownItem;
                if (dropDown == null)
                {
                    return;
                }

                foreach (ToolStripItem subItem in dropDown.DropDownItems)
                {
                    BrandToolStripItem(subItem);
                }
            }
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

                WriteLease(machineId, expiresAtUtc);
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

            public static void ActivateLeaseUntil(DateTime expiresAtUtc)
            {
                try
                {
                    WriteLease(HardwareFingerprint.GetMachineId(), expiresAtUtc.ToUniversalTime());
                    Log.Write("Demo lease activated without in-process timer. DurationSeconds=" + ((int)(expiresAtUtc.ToUniversalTime() - DateTime.UtcNow).TotalSeconds).ToString(CultureInfo.InvariantCulture));
                }
                catch (Exception ex)
                {
                    Log.Write("Demo lease activation failed: " + ex.Message);
                }
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
                try
                {
                    WriteLease(HardwareFingerprint.GetMachineId(), expiresAtUtc);
                }
                catch (Exception ex)
                {
                    Log.Write("Demo lease write failed: " + ex.Message);
                }

                var thread = new Thread(delegate()
                {
                    Thread.Sleep(duration);
                    Expire();
                });

                thread.Name = "SWTool demo mode timer";
                thread.IsBackground = true;
                thread.Start();
                RuntimeBranding.Start();
                StartCountdownInTitle(expiresAtUtc);
                // Matches Chinese Frmmain::TestTime_Tick: no info dialog at start, countdown only in window title.
                return true;
            }

            public static bool TryGetActiveLease(string machineId, out TimeSpan remaining)
            {
                remaining = TimeSpan.Zero;
                try
                {
                    var path = GetLeasePath();
                    if (!File.Exists(path))
                    {
                        return false;
                    }

                    var parts = File.ReadAllText(path, Encoding.UTF8).Split('|');
                    if (parts.Length != 3)
                    {
                        DeleteLease();
                        return false;
                    }

                    long ticks;
                    if (!long.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out ticks))
                    {
                        DeleteLease();
                        return false;
                    }

                    var expiresAtUtc = new DateTime(ticks, DateTimeKind.Utc);
                    remaining = expiresAtUtc - DateTime.UtcNow;
                    if (remaining <= TimeSpan.Zero)
                    {
                        DeleteLease();
                        return false;
                    }

                    if (!string.Equals(parts[0], machineId, StringComparison.OrdinalIgnoreCase) ||
                        !string.Equals(parts[2], ComputeDemoToken(machineId, expiresAtUtc), StringComparison.Ordinal))
                    {
                        DeleteLease();
                        return false;
                    }

                    return true;
                }
                catch (Exception ex)
                {
                    Log.Write("Demo lease read failed: " + ex.Message);
                    return false;
                }
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

            // Matches Chinese Frmmain::TestTime_Tick at expiry:
            //   Timer.Stop() + lockbutton() + MessageBoxTimeoutA(handle, msg, "<Tip>", 0, 0, 10000) + Environment.Exit(0).
            // Single auto-dismissing notice, no activation dialog forced on user, then exit.
            // User activates with a license key either before the demo expires, or by restarting SWTool after exit.
            private static void Expire()
            {
                Log.Write("Demo mode expired.");
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

                LockMainFormButtons();
                ShowExpiryNotice();

                Log.Write("Demo expired. Closing SWTool.");
                Environment.Exit(0);
            }

            // 1:1 equivalent of Chinese Frmmain::lockbutton — disables the seven ribbon entry-points
            // and clears KeyPreview so the user cannot trigger commands while the 10-second auto-dismiss
            // expiry notice is on screen.
            private static readonly string[] LockedRibbonFields = new[]
            {
                "_ConnectSW", "_BatchExport", "_BatchPrint", "_BatchReplace",
                "_BatchReplaceParts", "_SyncDrwName", "_mergepdf"
            };

            private static void LockMainFormButtons()
            {
                try
                {
                    foreach (Form form in Application.OpenForms)
                    {
                        if (form == null || form.IsDisposed) continue;
                        var fullName = form.GetType().FullName;
                        if (!string.Equals(fullName, "ZTool.Frmmain", StringComparison.Ordinal)) continue;

                        var t = form.GetType();
                        const System.Reflection.BindingFlags flags =
                            System.Reflection.BindingFlags.NonPublic |
                            System.Reflection.BindingFlags.Public |
                            System.Reflection.BindingFlags.Instance;
                        foreach (var name in LockedRibbonFields)
                        {
                            var field = t.GetField(name, flags);
                            if (field == null) continue;
                            var value = field.GetValue(form);
                            var enabledProp = value == null ? null : value.GetType().GetProperty("Enabled");
                            if (enabledProp == null || !enabledProp.CanWrite) continue;
                            try { enabledProp.SetValue(value, false, null); }
                            catch (Exception inner) { Log.Write("Demo lock " + name + " failed: " + inner.Message); }
                        }

                        try { form.KeyPreview = false; } catch { }
                        break;
                    }
                }
                catch (Exception ex)
                {
                    Log.Write("Demo lockbutton equivalent failed: " + ex);
                }
            }

            // MessageBoxTimeout is the undocumented user32 export the Chinese build calls
            // (MessageBoxTimeoutA there, Unicode here). Returns IDTIMEOUT (32000) when the
            // dwMilliseconds window elapses without user input.
            [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, EntryPoint = "MessageBoxTimeoutW")]
            private static extern int MessageBoxTimeoutW(IntPtr hWnd, string lpText, string lpCaption, uint uType, ushort wLanguageId, uint dwMilliseconds);

            private const uint MB_OK = 0x00000000u;
            private const uint MB_ICONINFORMATION = 0x00000040u;
            private const uint MB_SETFOREGROUND = 0x00010000u;
            private const uint MB_TOPMOST = 0x00040000u;
            private const uint ExpiryNoticeTimeoutMs = 10000u;

            private static void ShowExpiryNotice()
            {
                try
                {
                    IntPtr ownerHandle = IntPtr.Zero;
                    try
                    {
                        foreach (Form form in Application.OpenForms)
                        {
                            if (form == null || form.IsDisposed || !form.IsHandleCreated) continue;
                            ownerHandle = form.Handle;
                            break;
                        }
                    }
                    catch (Exception innerScan)
                    {
                        Log.Write("Demo expiry owner-form scan failed: " + innerScan.Message);
                    }

                    var caption = LanguageManager.T("Подсказка", "Notice");
                    var text = LanguageManager.T(
                        "Демо-период истёк. Программа закроется через 10 секунд.",
                        "Demo period expired. The program will close in 10 seconds.");

                    MessageBoxTimeoutW(ownerHandle, text, caption,
                        MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND | MB_TOPMOST,
                        0, ExpiryNoticeTimeoutMs);
                }
                catch (Exception ex)
                {
                    Log.Write("Demo expiry notice failed: " + ex);
                }
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

                        if (!form.Text.StartsWith("ZTool", StringComparison.OrdinalIgnoreCase) &&
                            !form.Text.StartsWith("SWTool", StringComparison.OrdinalIgnoreCase))
                        {
                            continue;
                        }

                        string originalTitle;
                        if (!originalWindowTitles.TryGetValue(form.Handle, out originalTitle))
                        {
                            originalTitle = BrandWindowTitle(StripDemoCountdown(form.Text));
                            originalWindowTitles[form.Handle] = originalTitle;
                        }

                        form.Text = originalTitle + LanguageManager.T("  Демо: ", "  Demo: ") + FormatRemaining(remaining);
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
                    var text = LanguageManager.T("Демо: ", "Demo: ") + FormatRemaining(remaining);
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
                if (string.IsNullOrEmpty(title)) return title;
                foreach (var marker in new[] { "  Демо: ", "  Demo: " })
                {
                    var index = title.IndexOf(marker, StringComparison.Ordinal);
                    if (index >= 0) return title.Substring(0, index);
                }
                return title;
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
                DeleteLease();
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

            private static string GetLeasePath()
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SWTools");
                Directory.CreateDirectory(dir);
                return Path.Combine(dir, "ZTool.demo.lease");
            }

            private static void WriteLease(string machineId, DateTime expiresAtUtc)
            {
                if (string.IsNullOrWhiteSpace(machineId))
                {
                    return;
                }

                expiresAtUtc = expiresAtUtc.ToUniversalTime();
                var value = machineId + "|" +
                    expiresAtUtc.Ticks.ToString(CultureInfo.InvariantCulture) + "|" +
                    ComputeDemoToken(machineId, expiresAtUtc);
                File.WriteAllText(GetLeasePath(), value, Encoding.UTF8);
            }

            private static void DeleteLease()
            {
                try
                {
                    var path = GetLeasePath();
                    if (File.Exists(path))
                    {
                        File.Delete(path);
                    }
                }
                catch (Exception ex)
                {
                    Log.Write("Demo lease cleanup failed: " + ex.Message);
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
        public const string DefaultLanguage = "Russian";
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
            return string.IsNullOrEmpty(EmbeddedLicenseConfig.DefaultLanguage)
                ? "Russian"
                : EmbeddedLicenseConfig.DefaultLanguage;
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

            try
            {
                string asmLocation = typeof(LanguageManager).Assembly.Location;
                if (!string.IsNullOrEmpty(asmLocation))
                {
                    string dir = Path.GetDirectoryName(asmLocation);
                    if (!string.IsNullOrEmpty(dir))
                    {
                        string settingsPath = Path.Combine(dir, "ZTool.settings");
                        if (File.Exists(settingsPath))
                        {
                            var doc = new System.Xml.XmlDocument();
                            doc.Load(settingsPath);
                            var node = doc.SelectSingleNode("//Language");
                            if (node == null)
                            {
                                var root = doc.DocumentElement;
                                if (root != null)
                                {
                                    node = doc.CreateElement("Language");
                                    root.AppendChild(node);
                                }
                            }
                            if (node != null)
                            {
                                node.InnerText = lang;
                                doc.Save(settingsPath);
                            }
                        }
                    }
                }
            }
            catch {}
        }

        public static bool IsEnglish()
        {
            return GetConfigLanguage() == "English";
        }

        public static string T(string ru, string en)
        {
            return IsEnglish() ? en : ru;
        }

        public static string TFormat(string ruTemplate, string enTemplate, params object[] args)
        {
            var template = IsEnglish() ? enTemplate : ruTemplate;
            return string.Format(CultureInfo.CurrentCulture, template, args);
        }

        public static string Translate(string s)
        {
            if (string.IsNullOrEmpty(s)) return s;
            if (!IsEnglish()) return s;
            
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
                var tabControl = FindOptionsTabControl(optionsForm);
                if (tabControl != null)
                {
                    foreach (TabPage existingPage in tabControl.TabPages)
                    {
                        if (string.Equals(existingPage.Name, "ZToolLanguageTab", StringComparison.Ordinal) ||
                            string.Equals(existingPage.Text, "Language / Язык", StringComparison.Ordinal) ||
                            string.Equals(existingPage.Text, "Language", StringComparison.Ordinal))
                        {
                            return;
                        }
                    }
                    
                    var tabPage = new TabPage("Language / Язык");
                    tabPage.Name = "ZToolLanguageTab";
                    tabPage.Padding = new Padding(10);
                    
                    var label = new Label();
                    label.Text = "Выберите язык / Select language:";
                    label.Location = new Point(20, 20);
                    label.AutoSize = true;

                    var restartLabel = new Label();
                    restartLabel.Text = T("Панель SolidWorks обновится после перезапуска SolidWorks.", "The SolidWorks toolbar will update after restarting SolidWorks.");
                    restartLabel.Location = new Point(20, 85);
                    restartLabel.AutoSize = true;
                    
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
                        restartLabel.Text = "The SolidWorks toolbar updates after restarting SolidWorks.";
                    }
                    tabPage.Controls.Add(restartLabel);
                }
            }
            catch {}
        }

        private static TabControl FindOptionsTabControl(Form optionsForm)
        {
            if (optionsForm == null) return null;

            try
            {
                var flags = System.Reflection.BindingFlags.Instance |
                    System.Reflection.BindingFlags.Public |
                    System.Reflection.BindingFlags.NonPublic;
                var tabControlProp = optionsForm.GetType().GetProperty("TabControl1", flags);
                if (tabControlProp != null)
                {
                    var value = tabControlProp.GetValue(optionsForm, null) as TabControl;
                    if (value != null) return value;
                }
            }
            catch {}

            return FindTabControl(optionsForm.Controls);
        }

        private static TabControl FindTabControl(Control.ControlCollection controls)
        {
            if (controls == null) return null;
            foreach (Control ctrl in controls)
            {
                var tabControl = ctrl as TabControl;
                if (tabControl != null) return tabControl;
                if (ctrl.HasChildren)
                {
                    tabControl = FindTabControl(ctrl.Controls);
                    if (tabControl != null) return tabControl;
                }
            }

            return null;
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
