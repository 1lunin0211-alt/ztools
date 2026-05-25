using System;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

[assembly: AssemblyTitle("ZTool License Deactivate")]
[assembly: AssemblyDescription("Interactive deactivation utility for ZTool")]
[assembly: AssemblyConfiguration("")]
[assembly: AssemblyCompany("Лунин В.И.")]
[assembly: AssemblyProduct("ZTool License Deactivate")]
[assembly: AssemblyCopyright("Copyright (c) Лунин В.И.")]
[assembly: AssemblyTrademark("")]
[assembly: AssemblyCulture("")]
[assembly: ComVisible(false)]
[assembly: Guid("1d0a6b86-4577-4e8e-95e7-82ee0c615314")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

namespace ZTool.LicenseDeactivate
{
    internal static class Program
    {
        [STAThread]
        private static int Main()
        {
            try
            {
                Application.EnableVisualStyles();
                return ZTool.License.LicenseGate.DeactivateInteractive() ? 0 : 1;
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Не удалось выполнить деактивацию ZTool.\r\n\r\n" + ex.Message,
                    "Деактивация ZTool",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 2;
            }
        }
    }
}
