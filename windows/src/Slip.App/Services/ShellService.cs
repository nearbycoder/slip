using System.Diagnostics;

namespace Slip.App.Services;

/// <summary>Open files / reveal them in File Explorer.</summary>
public static class ShellService
{
    public static void OpenFile(string path) => Start(new ProcessStartInfo(path) { UseShellExecute = true });

    public static void RevealInExplorer(string path)
    {
        if (File.Exists(path)) Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        else OpenFolder(Path.GetDirectoryName(path) ?? path);
    }

    public static void OpenFolder(string directory)
    {
        if (Directory.Exists(directory)) Start(new ProcessStartInfo("explorer.exe", $"\"{directory}\"") { UseShellExecute = true });
    }

    private static void Start(ProcessStartInfo info)
    {
        try { Process.Start(info)?.Dispose(); }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or FileNotFoundException) { }
    }
}
