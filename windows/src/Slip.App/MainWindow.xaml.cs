using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Slip.App.ViewModels;
using Slip.App.Views;
using Slip.Core;
using Windows.Graphics;

namespace Slip.App;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Slip.ico"));
        AppWindow.Resize(new SizeInt32(1100, 760));

        ApplyTheme(State.Settings.Theme);
        NavView.SelectedItem = NavView.MenuItems[0];
        ContentFrame.Navigate(typeof(ReceivePage));

        Closed += OnClosed;
    }

    public AppState State => App.State;

    public void ApplyTheme(AppTheme theme)
    {
        if (Content is FrameworkElement root)
        {
            root.RequestedTheme = theme switch
            {
                AppTheme.Light => ElementTheme.Light,
                AppTheme.Dark => ElementTheme.Dark,
                _ => ElementTheme.Default,
            };
        }
    }

    /// <summary>Restores and focuses the window (incoming transfer / toast click).</summary>
    public void BringToFront()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter)
            presenter.Restore();
        Activate();
        SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
    }

    public void NavigateTo(string tag)
    {
        var item = NavView.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(i => (string)i.Tag == tag);
        if (item is not null) NavView.SelectedItem = item;
    }

    private void OnNavigationSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var page = args.IsSettingsSelected
            ? typeof(SettingsPage)
            : ((args.SelectedItem as NavigationViewItem)?.Tag as string) switch
            {
                "send" => typeof(SendPage),
                "transfers" => typeof(TransfersPage),
                _ => typeof(ReceivePage),
            };
        if (ContentFrame.CurrentSourcePageType != page) ContentFrame.Navigate(page);
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        Services.NotificationService.Shutdown();
        // Stop the server and discovery so the ports are released before the process exits.
        Task.Run(App.State.ShutdownAsync).Wait(TimeSpan.FromSeconds(3));
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
}
