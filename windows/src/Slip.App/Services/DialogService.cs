using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Slip.App.Helpers;
using Slip.Core.Server;
using Windows.ApplicationModel.DataTransfer;

namespace Slip.App.Services;

/// <summary>ContentDialogs. Only one ContentDialog may be open per window, so calls are serialised.
/// All methods must be called on the UI thread.</summary>
public static class DialogService
{
    private static readonly SemaphoreSlim Gate = new(1, 1);

    private static XamlRoot? Root => App.MainWindow?.Content?.XamlRoot;

    private static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog, CancellationToken ct = default)
    {
        await Gate.WaitAsync(ct);
        try
        {
            if (Root is not { } root) return ContentDialogResult.None;
            dialog.XamlRoot = root;
            dialog.Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"];
            if (App.MainWindow?.Content is FrameworkElement fe) dialog.RequestedTheme = fe.RequestedTheme;
            using var reg = ct.Register(() => UiThread.Post(dialog.Hide));
            return await dialog.ShowAsync();
        }
        finally
        {
            Gate.Release();
        }
    }

    /// <summary>Incoming transfer: shows sender + file list (all pre-selected) with Accept / Decline.</summary>
    public static async Task<TransferDecision> ShowIncomingAsync(IncomingTransferRequest request, CancellationToken ct)
    {
        var list = new ListView
        {
            SelectionMode = ListViewSelectionMode.Multiple,
            MaxHeight = 280,
            MinWidth = 380,
        };
        foreach (var f in request.Files)
        {
            list.Items.Add(new ListViewItem
            {
                Tag = f.Id,
                Content = new StackPanel
                {
                    Children =
                    {
                        new TextBlock { Text = f.FileName, TextTrimming = TextTrimming.CharacterEllipsis },
                        new TextBlock
                        {
                            Text = Format.Bytes(f.Size),
                            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                        },
                    },
                },
            });
        }
        list.SelectAll();

        var sender = request.Sender;
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock
        {
            Text = $"{sender.Alias} wants to send you {request.Files.Count} file{(request.Files.Count == 1 ? "" : "s")} ({Format.Bytes(request.TotalSize)}).",
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(new TextBlock
        {
            Text = $"{sender.DeviceModel ?? "Unknown device"} · {request.SenderAddress}",
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        });
        content.Children.Add(list);

        var dialog = new ContentDialog
        {
            Title = "Incoming transfer",
            Content = content,
            PrimaryButtonText = "Accept",
            CloseButtonText = "Decline",
            DefaultButton = ContentDialogButton.Primary,
        };
        list.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = list.SelectedItems.Count > 0;

        ContentDialogResult result;
        try { result = await ShowAsync(dialog, ct); }
        catch (OperationCanceledException) { return TransferDecision.Decline; }
        if (ct.IsCancellationRequested || result != ContentDialogResult.Primary) return TransferDecision.Decline;

        var ids = list.SelectedItems.OfType<ListViewItem>().Select(i => (string)i.Tag).ToList();
        if (ids.Count == 0) return TransferDecision.Decline;
        return ids.Count == request.Files.Count ? TransferDecision.AcceptAll : TransferDecision.AcceptOnly(ids);
    }

    /// <summary>Received text message, with a Copy button.</summary>
    public static async Task ShowMessageAsync(TextMessage message)
    {
        var dialog = new ContentDialog
        {
            Title = $"Message from {message.Sender.Alias}",
            Content = new ScrollViewer
            {
                MaxHeight = 360,
                Content = new TextBlock { Text = message.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
            },
            PrimaryButtonText = "Copy",
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowAsync(dialog) == ContentDialogResult.Primary) CopyToClipboard(message.Text);
    }

    public static void CopyToClipboard(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    /// <summary>Asks for the receiver's PIN; null if cancelled.</summary>
    public static async Task<string?> PromptPinAsync(string receiver, bool wrongPin, CancellationToken ct)
    {
        var box = new PasswordBox { PlaceholderText = "PIN" };
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock
        {
            Text = wrongPin ? $"That PIN was not accepted by {receiver}. Try again." : $"{receiver} requires a PIN.",
            TextWrapping = TextWrapping.Wrap,
        });
        panel.Children.Add(box);
        var dialog = new ContentDialog
        {
            Title = "PIN required",
            Content = panel,
            PrimaryButtonText = "Send",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        var result = await ShowAsync(dialog, ct);
        return result == ContentDialogResult.Primary && box.Password.Length > 0 ? box.Password : null;
    }

    /// <summary>Lets the user type a text message to send.</summary>
    public static async Task<string?> PromptTextAsync()
    {
        var box = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 120,
            MinWidth = 380,
            PlaceholderText = "Type a message…",
        };
        var dialog = new ContentDialog
        {
            Title = "Send text",
            Content = box,
            PrimaryButtonText = "Add",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        var result = await ShowAsync(dialog);
        return result == ContentDialogResult.Primary && !string.IsNullOrWhiteSpace(box.Text) ? box.Text : null;
    }
}
