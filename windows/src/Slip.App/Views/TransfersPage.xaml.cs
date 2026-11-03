using Microsoft.UI.Xaml.Controls;
using Slip.App.ViewModels;

namespace Slip.App.Views;

public sealed partial class TransfersPage : Page
{
    public TransfersPage()
    {
        InitializeComponent();
    }

    public AppState State => App.State;
}
