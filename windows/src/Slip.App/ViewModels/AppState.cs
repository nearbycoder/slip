using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using Slip.App.Helpers;
using Slip.App.Services;
using Slip.Core;
using Slip.Core.Client;
using Slip.Core.Discovery;
using Slip.Core.Identity;
using Slip.Core.Protocol;
using Slip.Core.Server;
using Slip.Core.Util;

namespace Slip.App.ViewModels;

/// <summary>
/// Application-wide state: owns the <see cref="SlipNode"/>, mirrors peers and transfers into
/// UI-thread collections, and implements send / receive flows.
/// </summary>
public sealed partial class AppState : ObservableObject
{
    private readonly DispatcherQueueTimer _ticker;
    private readonly SettingsStore _store;
    private SlipSettings _settings;
    private SlipNode? _node;
    private TransferViewModel? _activeReceive;
    private bool _isScanning;
    private bool _isStatusOpen;
    private string _statusTitle = "";
    private string _statusMessage = "";
    private InfoBarSeverity _statusSeverity = InfoBarSeverity.Informational;
    private string _addressesText = "";

    public AppState(DispatcherQueue dispatcher)
    {
        _store = new SettingsStore(Path.Combine(AppPaths.DataDirectory, "settings.json"));
        _settings = _store.Load();
        Identity = SlipIdentity.LoadOrCreate(AppPaths.DataDirectory);

        Peers.CollectionChanged += (_, _) => OnPropertyChanged(nameof(HasPeers));
        Selection.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(HasSelection));
            OnPropertyChanged(nameof(SelectionSummary));
        };
        Transfers.CollectionChanged += (_, _) => OnPropertyChanged(nameof(HasTransfers));

        RefreshCommand = new AsyncRelayCommand(RefreshAsync);
        ClearSelectionCommand = new RelayCommand(Selection.Clear);
        ClearFinishedCommand = new RelayCommand(() =>
        {
            foreach (var t in Transfers.Where(t => !t.IsActive).ToList()) Transfers.Remove(t);
        });

        _ticker = dispatcher.CreateTimer();
        _ticker.Interval = TimeSpan.FromMilliseconds(250);
        _ticker.Tick += (_, _) =>
        {
            foreach (var t in Transfers) if (t.IsActive) t.Refresh();
        };
        _ticker.Start();
    }

    public SlipIdentity Identity { get; }
    public SlipNode? Node => _node;
    public SlipSettings Settings => _settings.Clone();

    public ObservableCollection<PeerViewModel> Peers { get; } = [];
    public ObservableCollection<TransferViewModel> Transfers { get; } = [];
    public ObservableCollection<SelectionItemViewModel> Selection { get; } = [];

    public IAsyncRelayCommand RefreshCommand { get; }
    public IRelayCommand ClearSelectionCommand { get; }
    public IRelayCommand ClearFinishedCommand { get; }

    // ---- Receive card ----

    public string Alias => _settings.Alias;
    public string Fingerprint => Identity.FingerprintFor(_settings.UseHttps);
    public string AddressesText { get => _addressesText; private set => SetProperty(ref _addressesText, value); }
    public string PortText => $"Port {_node?.Server?.Port ?? _settings.Port} · {(_settings.UseHttps ? "HTTPS (encrypted)" : "HTTP (unencrypted)")}";
    public bool IsServerRunning => _node?.Server?.IsRunning ?? false;

    public string ReceiveHeadline => !IsServerRunning
        ? "Not ready — the receive server is not running"
        : _settings.Discoverable ? "Ready to receive" : "Hidden from nearby devices";

    public bool IsDiscoverable
    {
        get => _settings.Discoverable;
        set
        {
            if (_settings.Discoverable == value) return;
            var s = Settings;
            s.Discoverable = value;
            _ = ApplySettingsAsync(s);
        }
    }

    public bool QuickSave
    {
        get => _settings.AutoAccept;
        set
        {
            if (_settings.AutoAccept == value) return;
            var s = Settings;
            s.AutoAccept = value;
            _ = ApplySettingsAsync(s);
        }
    }

    public TransferViewModel? ActiveReceive
    {
        get => _activeReceive;
        private set
        {
            if (SetProperty(ref _activeReceive, value)) OnPropertyChanged(nameof(HasActiveReceive));
        }
    }

    public bool HasActiveReceive => _activeReceive is not null;

    // ---- Send page ----

    public bool HasPeers => Peers.Count > 0;
    public bool HasSelection => Selection.Count > 0;
    public bool HasTransfers => Transfers.Count > 0;
    public bool IsScanning { get => _isScanning; private set => SetProperty(ref _isScanning, value); }

    public string SelectionSummary
    {
        get
        {
            if (Selection.Count == 0) return "Pick files, a folder or a message, then choose a device below. You can also drop files onto a device.";
            var items = Selection.SelectMany(s => s.Items).ToList();
            return $"{items.Count} item{(items.Count == 1 ? "" : "s")} · {Format.Bytes(items.Sum(i => i.Size))} — choose a device below";
        }
    }

    // ---- status bar ----

    public bool IsStatusOpen { get => _isStatusOpen; set => SetProperty(ref _isStatusOpen, value); }
    public string StatusTitle { get => _statusTitle; private set => SetProperty(ref _statusTitle, value); }
    public string StatusMessage { get => _statusMessage; private set => SetProperty(ref _statusMessage, value); }
    public InfoBarSeverity StatusSeverity { get => _statusSeverity; private set => SetProperty(ref _statusSeverity, value); }

    public void ShowStatus(InfoBarSeverity severity, string title, string message)
    {
        StatusSeverity = severity;
        StatusTitle = title;
        StatusMessage = message;
        IsStatusOpen = true;
    }

    // ---------------------------------------------------------------------------------------------

    public async Task StartAsync()
    {
        UpdateAddresses();
        System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged += (_, _) => UiThread.Post(UpdateAddresses);
        await StartNodeAsync();
    }

    private async Task StartNodeAsync()
    {
        var node = new SlipNode(_settings, Identity, "Windows", DeviceType.Desktop);
        node.DecisionHandler = DecideAsync;
        node.Peers.Changed += (_, _) => UiThread.Post(SyncPeers);
        node.ReceiveStarted += (_, session) => UiThread.Post(() => OnReceiveStarted(session));
        node.ReceiveEnded += (_, session) => UiThread.Post(() => OnReceiveEnded(session));
        node.MessageReceived += (_, message) => UiThread.Post(() => OnMessage(message));
        try
        {
            await node.StartAsync();
            _node = node;
            if (node.Discovery is { } d) d.ScanningChanged += (_, _) => UiThread.Post(() => IsScanning = d.IsScanning);
            else ShowStatus(InfoBarSeverity.Warning, "Discovery unavailable",
                "Multicast discovery could not start. Use Refresh to scan the network, or send to an IP address.");
        }
        catch (Exception e)
        {
            await node.DisposeAsync();
            _node = null;
            ShowStatus(InfoBarSeverity.Error, "Could not start receiving",
                $"Port {_settings.Port} may be in use by another app (is LocalSend running?). Change the port in Settings. ({e.Message})");
        }
        RaiseReceiveCard();
        SyncPeers();
    }

    private void RaiseReceiveCard()
    {
        OnPropertyChanged(nameof(Alias));
        OnPropertyChanged(nameof(Fingerprint));
        OnPropertyChanged(nameof(PortText));
        OnPropertyChanged(nameof(IsServerRunning));
        OnPropertyChanged(nameof(ReceiveHeadline));
        OnPropertyChanged(nameof(IsDiscoverable));
        OnPropertyChanged(nameof(QuickSave));
        OnPropertyChanged(nameof(Settings));
    }

    private void UpdateAddresses()
    {
        var ips = NetUtil.GetIPv4Interfaces().Select(i => i.Address.ToString()).Distinct().ToList();
        AddressesText = ips.Count == 0 ? "No network connection" : string.Join("  ·  ", ips);
    }

    /// <summary>Persists and applies settings (restarting the server if the port/protocol changed).</summary>
    public async Task ApplySettingsAsync(SlipSettings settings)
    {
        var old = _settings;
        _settings = settings.Clone();
        try { _store.Save(_settings); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            ShowStatus(InfoBarSeverity.Warning, "Settings not saved", e.Message);
        }

        if (_node is null)
        {
            await StartNodeAsync();
        }
        else
        {
            var restart = old.Port != settings.Port || old.UseHttps != settings.UseHttps;
            try
            {
                await _node.ApplySettingsAsync(_settings);
            }
            catch (Exception e)
            {
                ShowStatus(InfoBarSeverity.Error, "Could not restart receiving", $"Port {settings.Port}: {e.Message}");
                await _node.DisposeAsync();
                _node = null;
            }
            if (restart && _node?.Discovery is { } d) d.ScanningChanged += (_, _) => UiThread.Post(() => IsScanning = d.IsScanning);
        }
        RaiseReceiveCard();
    }

    // ---- peers ----

    private void SyncPeers()
    {
        var snapshot = _node?.Peers.Snapshot() ?? [];
        var byFp = snapshot.ToDictionary(p => p.Fingerprint, StringComparer.OrdinalIgnoreCase);
        for (var i = Peers.Count - 1; i >= 0; i--)
        {
            if (!byFp.ContainsKey(Peers[i].Fingerprint)) Peers.RemoveAt(i);
        }
        foreach (var peer in snapshot)
        {
            var existing = Peers.FirstOrDefault(p => string.Equals(p.Fingerprint, peer.Fingerprint, StringComparison.OrdinalIgnoreCase));
            if (existing is not null) existing.Update(peer);
            else Peers.Add(new PeerViewModel(peer));
        }
    }

    private async Task RefreshAsync()
    {
        if (_node is null) return;
        IsScanning = true;
        try { await Task.Run(() => _node.RefreshPeersAsync(scan: true)); }
        finally { IsScanning = _node?.Discovery?.IsScanning ?? false; }
    }

    public async Task<bool> AddManualPeerAsync(string address)
    {
        if (_node is null || string.IsNullOrWhiteSpace(address)) return false;
        PeerEndpoint endpoint;
        try { endpoint = PeerEndpoint.Parse(address, _settings.UseHttps); }
        catch (FormatException)
        {
            ShowStatus(InfoBarSeverity.Warning, "Invalid address", "Use an IP address, optionally with a port, e.g. 192.168.1.20:53317.");
            return false;
        }
        var node = _node;
        var peer = await Task.Run(async () =>
            await node.ConnectManualAsync(endpoint)
            ?? await node.ConnectManualAsync(endpoint with { Https = !endpoint.Https }));
        if (peer is null)
        {
            ShowStatus(InfoBarSeverity.Warning, "Device not found", $"No Slip or LocalSend device answered at {address}.");
            return false;
        }
        SyncPeers();
        return true;
    }

    // ---- selection ----

    public void AddPaths(IEnumerable<string> paths)
    {
        foreach (var path in paths)
        {
            try
            {
                if (Directory.Exists(path))
                {
                    var items = SendItem.FromDirectory(path).ToList();
                    Selection.Add(new SelectionItemViewModel(Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar)),
                        $"Folder · {items.Count} files · {Format.Bytes(items.Sum(i => i.Size))}", "", items));
                }
                else if (File.Exists(path))
                {
                    var item = SendItem.FromFile(path);
                    Selection.Add(new SelectionItemViewModel(item.FileName, Format.Bytes(item.Size), "", [item]));
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                ShowStatus(InfoBarSeverity.Warning, "Could not add", $"{path}: {e.Message}");
            }
        }
    }

    public void AddText(string text)
    {
        var preview = text.Length > 60 ? text[..60] + "…" : text;
        Selection.Add(new SelectionItemViewModel(preview.ReplaceLineEndings(" "), "Text message", "", [SendItem.FromText(text)]));
    }

    // ---- sending ----

    public Task SendSelectionAsync(PeerViewModel peer)
    {
        if (Selection.Count == 0)
        {
            ShowStatus(InfoBarSeverity.Informational, "Nothing selected", "Pick files, a folder or a text message first — or drop files onto the device.");
            return Task.CompletedTask;
        }
        // Text messages go as their own request (receivers treat a text-only request as a message).
        var texts = Selection.SelectMany(s => s.Items).Where(i => i.IsText).ToList();
        var files = Selection.SelectMany(s => s.Items).Where(i => !i.IsText).ToList();
        Selection.Clear();
        var tasks = new List<Task>();
        if (files.Count > 0) tasks.Add(SendAsync(peer, files));
        tasks.AddRange(texts.Select(t => SendAsync(peer, [t])));
        return Task.WhenAll(tasks);
    }

    public async Task SendAsync(PeerViewModel peer, IReadOnlyList<SendItem> items)
    {
        if (_node is null || items.Count == 0) return;
        var session = _node.CreateSend(peer.Peer, items);
        var vm = TransferViewModel.ForSend(session);
        Transfers.Insert(0, vm);
        peer.IsSending = true;
        SendState state;
        try
        {
            state = await Task.Run(() => session.RunAsync((attempt, ct) =>
                UiThread.RunAsync(() => DialogService.PromptPinAsync(peer.Alias, attempt > 1, ct))));
        }
        finally
        {
            peer.IsSending = false;
            vm.Refresh();
        }

        switch (state)
        {
            case SendState.Completed:
                break;
            case SendState.Cancelled:
                break;
            case SendState.Declined:
                ShowStatus(InfoBarSeverity.Warning, "Declined", $"{peer.Alias} declined the transfer.");
                break;
            case SendState.Busy:
                ShowStatus(InfoBarSeverity.Warning, "Receiver is busy", $"{peer.Alias} is already in another transfer. Try again shortly.");
                break;
            case SendState.TooManyRequests:
                ShowStatus(InfoBarSeverity.Warning, "Too many requests", $"{peer.Alias} is rate limiting. Try again shortly.");
                break;
            case SendState.PinRequired:
                ShowStatus(InfoBarSeverity.Warning, "PIN required", $"{peer.Alias} requires a PIN.");
                break;
            default:
                ShowStatus(InfoBarSeverity.Error, "Transfer failed", session.ErrorMessage ?? "Unknown error");
                break;
        }
    }

    // ---- receiving ----

    private Task<TransferDecision> DecideAsync(IncomingTransferRequest request, CancellationToken ct)
    {
        var count = request.Files.Count;
        NotificationService.Show($"{request.Sender.Alias} wants to send you {count} file{(count == 1 ? "" : "s")}",
            $"{Format.Bytes(request.TotalSize)} — open Slip to accept or decline.");
        return UiThread.RunAsync(async () =>
        {
            App.MainWindow?.BringToFront();
            return await DialogService.ShowIncomingAsync(request, ct);
        });
    }

    private void OnReceiveStarted(ReceiveSession session)
    {
        var vm = TransferViewModel.ForReceive(session);
        Transfers.Insert(0, vm);
        ActiveReceive = vm;
    }

    private void OnReceiveEnded(ReceiveSession session)
    {
        var vm = Transfers.FirstOrDefault(t => ReferenceEquals(t.ReceiveSession, session));
        vm?.Refresh();
        if (ReferenceEquals(ActiveReceive?.ReceiveSession, session)) ActiveReceive = null;
        if (session.State != ReceiveState.Completed) return;

        var saved = session.Files.Where(f => f.SavedPath is not null).ToList();
        if (saved.Count == 0) return;
        var title = saved.Count == 1 ? $"Received {Path.GetFileName(saved[0].SavedPath)}" : $"Received {saved.Count} files";
        NotificationService.Show(title, $"From {session.Sender.Alias} · {Format.Bytes(saved.Sum(f => f.Size))}",
            revealPath: saved[0].SavedPath, openPath: saved.Count == 1 ? saved[0].SavedPath : null);
    }

    private void OnMessage(TextMessage message)
    {
        NotificationService.Show($"Message from {message.Sender.Alias}", message.Text.Length > 200 ? message.Text[..200] + "…" : message.Text);
        _ = DialogService.ShowMessageAsync(message);
    }

    public async Task ShutdownAsync()
    {
        _ticker.Stop();
        var node = _node;
        _node = null;
        if (node is not null) await node.DisposeAsync();
    }
}
