using System;
using System.IO;
using System.Reflection;

internal static class ZToolLicenseWorkflowSmoke
{
    private const string WrongMachineId = "0000000000000000000000000000000000000000000000000000000000000000";

    private static int Main(string[] args)
    {
        if (args.Length < 3 || args.Length > 4)
        {
            Console.Error.WriteLine("Usage: ZToolLicenseWorkflowSmoke.exe <packageRoot> <licenseKey> <transferPassword> [full|activate-store|deactivate-store]");
            return 2;
        }

        var packageRoot = Path.GetFullPath(args[0]);
        var licenseKey = args[1];
        var transferPassword = args[2];
        var mode = args.Length == 4 ? args[3] : "full";
        var licenseDll = Path.Combine(packageRoot, "ZTool.License.dll");
        var storePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "SWTools",
            "ZTool.license.json");

        var hadOriginalStore = File.Exists(storePath);
        var originalStore = hadOriginalStore ? File.ReadAllText(storePath) : null;

        AppDomain.CurrentDomain.AssemblyResolve += delegate(object sender, ResolveEventArgs eventArgs)
        {
            var name = new AssemblyName(eventArgs.Name).Name + ".dll";
            var candidate = Path.Combine(packageRoot, name);
            return File.Exists(candidate) ? Assembly.LoadFrom(candidate) : null;
        };

        try
        {
            Environment.CurrentDirectory = packageRoot;
            var assembly = Assembly.LoadFrom(licenseDll);

            var machineId = (string)InvokeStatic(
                assembly.GetType("ZTool.License.LicenseGate+HardwareFingerprint", true),
                "GetMachineId");

            var clientType = assembly.GetType("ZTool.License.LicenseGate+LicenseClient", true);
            var validatorType = assembly.GetType("ZTool.License.LicenseGate+LicenseValidator", true);
            var storeType = assembly.GetType("ZTool.License.LicenseGate+LicenseStore", true);

            var client = Activator.CreateInstance(clientType, true);
            var store = Activator.CreateInstance(storeType, true);

            if (mode == "deactivate-store")
            {
                InvokeInstance(client, "Deactivate", licenseKey, transferPassword, machineId);
                InvokeInstance(store, "Delete");
                Console.WriteLine("deactivation=ok");
                Console.WriteLine("status=ok");
                return 0;
            }

            var cache = InvokeInstance(client, "Activate", licenseKey, transferPassword, machineId);
            Assert((bool)InvokeStatic(validatorType, "IsUsable", cache, machineId), "activated payload is usable");
            Console.WriteLine("activation=ok");

            if (mode == "activate-store")
            {
                InvokeInstance(store, "Save", cache);
                var storedCache = InvokeInstance(store, "Load");
                Assert((bool)InvokeStatic(validatorType, "IsUsable", storedCache, machineId), "stored offline payload is usable");
                Console.WriteLine("offlineStore=ok");
                Console.WriteLine("status=ok");
                return 0;
            }

            Assert(!(bool)InvokeStatic(validatorType, "IsUsable", cache, WrongMachineId), "wrong machine is rejected");
            Console.WriteLine("wrongMachine=ok");

            var signatureProperty = cache.GetType().GetProperty("Signature");
            var originalSignature = (string)signatureProperty.GetValue(cache, null);
            signatureProperty.SetValue(cache, originalSignature.Substring(0, originalSignature.Length - 4) + "AAAA", null);
            Assert(!(bool)InvokeStatic(validatorType, "IsUsable", cache, machineId), "tampered signature is rejected");
            signatureProperty.SetValue(cache, originalSignature, null);
            Console.WriteLine("tamper=ok");

            InvokeInstance(store, "Save", cache);
            var loadedCache = InvokeInstance(store, "Load");
            Assert((bool)InvokeStatic(validatorType, "IsUsable", loadedCache, machineId), "stored offline payload is usable");
            Console.WriteLine("offlineStore=ok");

            InvokeInstance(client, "Deactivate", licenseKey, transferPassword, machineId);
            Console.WriteLine("deactivation=ok");

            InvokeInstance(store, "Delete");
            Console.WriteLine("status=ok");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(Unwrap(ex).ToString());
            return 1;
        }
        finally
        {
            if (mode == "full")
            {
                Directory.CreateDirectory(Path.GetDirectoryName(storePath));
                if (hadOriginalStore)
                {
                    File.WriteAllText(storePath, originalStore);
                }
                else if (File.Exists(storePath))
                {
                    File.Delete(storePath);
                }
            }
        }
    }

    private static object InvokeStatic(Type type, string methodName, params object[] args)
    {
        try
        {
            return type.GetMethod(methodName, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static)
                .Invoke(null, args);
        }
        catch (TargetInvocationException ex)
        {
            throw Unwrap(ex);
        }
    }

    private static object InvokeInstance(object target, string methodName, params object[] args)
    {
        try
        {
            return target.GetType().GetMethod(methodName, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
                .Invoke(target, args);
        }
        catch (TargetInvocationException ex)
        {
            throw Unwrap(ex);
        }
    }

    private static Exception Unwrap(Exception ex)
    {
        var tie = ex as TargetInvocationException;
        return tie != null && tie.InnerException != null ? tie.InnerException : ex;
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException("Workflow smoke failed: " + message);
        }
    }
}
