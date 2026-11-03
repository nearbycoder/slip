using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Slip.App.ViewModels;

namespace Slip.App.Views;

public sealed partial class ReceivePage : Page
{
    public ReceivePage()
    {
        InitializeComponent();
    }

    public AppState State => App.State;

    private void OnViewTransfers(object sender, RoutedEventArgs e) => App.MainWindow?.NavigateTo("transfers");
}
