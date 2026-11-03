using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Slip.App.Services;
using Slip.App.ViewModels;

namespace Slip.App;

public partial class App : Application
{
    public static AppState State { get; private set; } = null!;
    public static MainWindow? MainWindow { get; private set; }

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            // Keep the app alive for non-fatal UI exceptions; surface them in the status bar.
            e.Handled = true;
            State?.ShowStatus(Microsoft.UI.Xaml.Controls.InfoBarSeverity.Error, "Unexpected error", e.Message);
        };
    }

    protected override async void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        UiThread.Initialize(dispatcher);
        NotificationService.Initialize();

        State = new AppState(dispatcher);
        MainWindow = new MainWindow();
        MainWindow.Activate();
        await State.StartAsync();
    }
}
