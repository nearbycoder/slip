using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Slip.App.Services;

/// <summary>Windows toast notifications via the Windows App SDK (works for unpackaged apps).</summary>
public static class NotificationService
{
    private static bool _registered;

    public static void Initialize()
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked += OnInvoked;
            AppNotificationManager.Default.Register();
            _registered = true;
        }
        catch (Exception)
        {
            // Notifications are best-effort (e.g. unsupported OS build or policy).
            _registered = false;
        }
    }

    public static void Shutdown()
    {
        if (!_registered) return;
        try { AppNotificationManager.Default.Unregister(); }
        catch (Exception) { }
        _registered = false;
    }

    /// <summary>Shows a toast. <paramref name="revealPath"/> adds a "Show in folder" button.</summary>
    public static void Show(string title, string body, string? revealPath = null, string? openPath = null)
    {
        if (!_registered) return;
        try
        {
            var builder = new AppNotificationBuilder()
                .AddArgument("action", "activate")
                .AddText(title)
                .AddText(body);
            if (openPath is not null)
                builder.AddButton(new AppNotificationButton("Open").AddArgument("action", "open").AddArgument("path", openPath));
            if (revealPath is not null)
                builder.AddButton(new AppNotificationButton("Show in folder").AddArgument("action", "reveal").AddArgument("path", revealPath));
            AppNotificationManager.Default.Show(builder.BuildNotification());
        }
        catch (Exception) { }
    }

    private static void OnInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args)
    {
        var action = args.Arguments.TryGetValue("action", out var a) ? a : "activate";
        var path = args.Arguments.TryGetValue("path", out var p) ? p : null;
        UiThread.Post(() =>
        {
            switch (action)
            {
                case "open" when path is not null:
                    ShellService.OpenFile(path);
                    break;
                case "reveal" when path is not null:
                    ShellService.RevealInExplorer(path);
                    break;
                default:
                    App.MainWindow?.BringToFront();
                    break;
            }
        });
    }
}
