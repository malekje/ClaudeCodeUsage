using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

// Starts claude-usage.ps1 (next to this exe) in a hidden PowerShell, so the widget opens like a normal program.
static class Launcher
{
    const string ScriptName = "claude-usage.ps1";

    [STAThread]
    static void Main(string[] args)
    {
        string folder = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(folder, ScriptName);
        if (!File.Exists(script))
        {
            MessageBox.Show(ScriptName + " must stay in the same folder as this program.", "Claude Usage");
            return;
        }
        var start = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\" " + string.Join(" ", args));
        start.WorkingDirectory = folder;
        start.CreateNoWindow = true;
        start.UseShellExecute = false;
        Process.Start(start);
    }
}
