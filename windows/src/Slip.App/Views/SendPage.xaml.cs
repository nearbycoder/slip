using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Slip.App.Services;
using Slip.App.ViewModels;
using Slip.Core.Client;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace Slip.App.Views;

public sealed partial class SendPage : Page
{
    public SendPage()
    {
        InitializeComponent();
    }

    public AppState State => App.State;

    // ---- selection tray ----

    private async void OnPickFiles(object sender, RoutedEventArgs e) => State.AddPaths(await PickerService.PickFilesAsync());

    private async void OnPickFolder(object sender, RoutedEventArgs e)
    {
        if (await PickerService.PickFolderAsync() is { } folder) State.AddPaths([folder]);
    }

    private async void OnAddText(object sender, RoutedEventArgs e)
    {
        if (await DialogService.PromptTextAsync() is { } text) State.AddText(text);
    }

    private async void OnPaste(object sender, RoutedEventArgs e)
    {
        var content = Clipboard.GetContent();
        if (content.Contains(StandardDataFormats.StorageItems))
            State.AddPaths(PathsOf(await content.GetStorageItemsAsync()));
        else if (content.Contains(StandardDataFormats.Text) && await content.GetTextAsync() is { Length: > 0 } text)
            State.AddText(text);
        else
            State.ShowStatus(InfoBarSeverity.Informational, "Clipboard is empty", "Copy some files or text first.");
    }

    private void OnRemoveSelection(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is SelectionItemViewModel item) State.Selection.Remove(item);
    }

    // ---- devices ----

    private async void OnPeerClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is PeerViewModel peer) await State.SendSelectionAsync(peer);
    }

    private void OnPeerDragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        e.AcceptedOperation = DataPackageOperation.Copy;
        if ((sender as FrameworkElement)?.DataContext is PeerViewModel peer && e.DragUIOverride is { } ui)
        {
            ui.Caption = $"Send to {peer.Alias}";
            ui.IsCaptionVisible = true;
        }
        e.Handled = true;
    }

    private async void OnPeerDrop(object sender, DragEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not PeerViewModel peer || !e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        e.Handled = true;
        var deferral = e.GetDeferral();
        List<SendItem> items;
        try
        {
            var paths = PathsOf(await e.DataView.GetStorageItemsAsync());
            items = SendItem.FromPaths(paths);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            State.ShowStatus(InfoBarSeverity.Warning, "Could not read the dropped files", ex.Message);
            return;
        }
        finally
        {
            deferral.Complete();
        }
        if (items.Count > 0) await State.SendAsync(peer, items);
    }

    private void OnPageDragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        e.AcceptedOperation = DataPackageOperation.Copy;
        if (e.DragUIOverride is { } ui)
        {
            ui.Caption = "Add to selection";
            ui.IsCaptionVisible = true;
        }
    }

    private async void OnPageDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var deferral = e.GetDeferral();
        try { State.AddPaths(PathsOf(await e.DataView.GetStorageItemsAsync())); }
        finally { deferral.Complete(); }
    }

    private static List<string> PathsOf(IReadOnlyList<IStorageItem> items) =>
        items.Select(i => i.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();

    // ---- manual address ----

    private async void OnManualConnect(object sender, RoutedEventArgs e) => await ConnectManualAsync();

    private async void OnManualAddressKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            e.Handled = true;
            await ConnectManualAsync();
        }
    }

    private async Task ConnectManualAsync()
    {
        var text = ManualAddress.Text.Trim();
        if (text.Length == 0) return;
        if (await State.AddManualPeerAsync(text)) ManualAddress.Text = "";
    }
}
