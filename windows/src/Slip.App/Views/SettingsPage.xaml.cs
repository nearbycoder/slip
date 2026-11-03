using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Slip.App.Services;
using Slip.App.ViewModels;

namespace Slip.App.Views;

public sealed partial class SettingsPage : Page
{
    public SettingsPage()
    {
        ViewModel = new SettingsViewModel(App.State, DispatcherQueue);
        InitializeComponent();
    }

    public SettingsViewModel ViewModel { get; }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        ViewModel.Reload();
    }

    private async void OnPickSaveFolder(object sender, RoutedEventArgs e)
    {
        if (await PickerService.PickFolderAsync() is { } folder) ViewModel.SaveDirectory = folder;
    }
}
