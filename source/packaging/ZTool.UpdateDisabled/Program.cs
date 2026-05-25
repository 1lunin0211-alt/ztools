using System;
using System.Windows.Forms;

namespace ZTool.UpdateDisabled
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            MessageBox.Show(
                "Обновления отключены администратором.",
                "ZTool",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
    }
}
