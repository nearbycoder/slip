using System.Net;
using Slip.Core.Client;
using Slip.Core.Discovery;
using Slip.Core.Identity;
using Slip.Core.Protocol;
using Slip.Core.Server;
using Slip.Core.Util;

namespace Slip.Core;

/// <summary>
/// One running Slip device: identity + settings + discovery + receive server + sender.
/// This is what UI front-ends and the CLI talk to.
/// </summary>
public sealed class SlipNode : Observable, IAsyncDisposable
{
    private readonly object _gate = new();
    private SlipSettings _settings;
    private SlipServer? _server;
    private DiscoveryService? _discovery;
    private readonly List<SendSession> _activeSends = [];

    public SlipNode(SlipSettings settings, SlipIdentity identity, string deviceModel = "Windows", DeviceType deviceType = DeviceType.Desktop)
    {
        _settings = settings.Clone();
        Identity = identity;
        DeviceModel = deviceModel;
        DeviceType = deviceType;
        Peers = new PeerRegistry { IsPinned = IsBusyWith };
        Sender = new SlipSender(() => LocalInfo);
    }

    public SlipIdentity Identity { get; }
    public string DeviceModel { get; }
    public DeviceType DeviceType { get; }
    public PeerRegistry Peers { get; }
    public SlipSender Sender { get; }
    public SlipServer? Server => _server;
    public DiscoveryService? Discovery => _discovery;
    public SlipSettings Settings => _settings.Clone();

    /// <summary>Enable multicast discovery when starting (the CLI's send command turns this off).</summary>
    public bool EnableDiscovery { get; init; } = true;
    /// <summary>Bind address for the HTTP(S) server (tests use loopback).</summary>
    public IPAddress BindAddress { get; init; } = IPAddress.Any;

    public IncomingTransferHandler? DecisionHandler
    {
        get => _decisionHandler;
        set { _decisionHandler = value; if (_server is not null) _server.DecisionHandler = value; }
    }
    private IncomingTransferHandler? _decisionHandler;

    public event EventHandler<ReceiveSession>? ReceiveStarted;
    public event EventHandler<ReceiveSession>? ReceiveEnded;
    public event EventHandler<TextMessage>? MessageReceived;

    /// <summary>Our DeviceInfo as currently advertised.</summary>
    public DeviceInfo LocalInfo
    {
        get
        {
            var s = _settings;
            return new DeviceInfo
            {
                Alias = s.Alias,
                Version = SlipConstants.ProtocolVersion,
                DeviceModel = DeviceModel,
                DeviceType = DeviceType,
                Fingerprint = Identity.FingerprintFor(s.UseHttps),
                Port = _server is { Port: > 0 } srv ? srv.Port : s.Port,
                Protocol = s.UseHttps ? "https" : "http",
                Download = false,
            };
        }
    }

    public bool IsSelf(string? fingerprint) => Identity.IsOwnFingerprint(fingerprint);

    private bool IsBusyWith(string fingerprint)
    {
        if (_server?.CurrentSession?.Sender.Fingerprint is { } fp && string.Equals(fp, fingerprint, StringComparison.OrdinalIgnoreCase))
            return true;
        lock (_gate)
            return _activeSends.Any(s => Peers.Find(fingerprint) is { } peer && peer.Address == s.Target.Host);
    }

    public async Task StartAsync(CancellationToken ct = default)
    {
        var s = _settings;
        var server = new SlipServer(
            new ServerOptions { Port = s.Port, Https = s.UseHttps, BindAddress = BindAddress },
            Identity.Certificate, () => LocalInfo, IsSelf, Peers)
        {
            SaveDirectory = s.SaveDirectory,
            Pin = s.EffectivePin,
            AutoAccept = s.AutoAccept,
            DecisionHandler = _decisionHandler,
        };
        server.SessionStarted += (_, e) => ReceiveStarted?.Invoke(this, e);
        server.SessionEnded += (_, e) => ReceiveEnded?.Invoke(this, e);
        server.MessageReceived += (_, e) => MessageReceived?.Invoke(this, e);
        await server.StartAsync(ct).ConfigureAwait(false);
        _server = server;

        if (EnableDiscovery)
        {
            var discovery = new DiscoveryService(() => LocalInfo, IsSelf, Peers, new DiscoveryOptions
            {
                MulticastGroup = s.MulticastGroup,
                MulticastPort = s.MulticastPort,
                ScanPort = s.Port,
                ScanHttps = s.UseHttps,
            })
            { Discoverable = s.Discoverable };
            try
            {
                discovery.Start();
                _discovery = discovery;
            }
            catch (Exception e) when (e is System.Net.Sockets.SocketException or IOException)
            {
                SlipLog.Warn($"Multicast discovery unavailable: {e.Message}");
                await discovery.DisposeAsync().ConfigureAwait(false);
            }
        }
        OnPropertyChanged(nameof(Server));
        OnPropertyChanged(nameof(Discovery));
        OnPropertyChanged(nameof(LocalInfo));
    }

    public async Task StopAsync()
    {
        var discovery = _discovery;
        _discovery = null;
        if (discovery is not null) await discovery.DisposeAsync().ConfigureAwait(false);
        var server = _server;
        _server = null;
        if (server is not null) await server.DisposeAsync().ConfigureAwait(false);
        OnPropertyChanged(nameof(Server));
        OnPropertyChanged(nameof(Discovery));
    }

    /// <summary>Applies new settings. Changes to port/protocol/multicast restart the network services.</summary>
    public async Task ApplySettingsAsync(SlipSettings settings)
    {
        var old = _settings;
        _settings = settings.Clone();
        var restart = old.Port != settings.Port || old.UseHttps != settings.UseHttps ||
                      old.MulticastGroup != settings.MulticastGroup || old.MulticastPort != settings.MulticastPort;
        if (_server is not null && restart)
        {
            await StopAsync().ConfigureAwait(false);
            await StartAsync().ConfigureAwait(false);
        }
        else
        {
            if (_server is { } server)
            {
                server.SaveDirectory = settings.SaveDirectory;
                server.Pin = settings.EffectivePin;
                server.AutoAccept = settings.AutoAccept;
            }
            if (_discovery is { } d)
            {
                var wasDiscoverable = d.Discoverable;
                d.Discoverable = settings.Discoverable;
                if (old.Alias != settings.Alias || (!wasDiscoverable && settings.Discoverable)) _ = d.AnnounceAsync();
            }
        }
        OnPropertyChanged(nameof(Settings));
        OnPropertyChanged(nameof(LocalInfo));
    }

    public Task RefreshPeersAsync(bool scan = true, CancellationToken ct = default) =>
        _discovery?.RefreshAsync(scan, ct) ?? Task.CompletedTask;

    /// <summary>Starts sending <paramref name="items"/> to <paramref name="target"/>; observe the returned session.</summary>
    public SendSession CreateSend(PeerEndpoint target, IReadOnlyList<SendItem> items, string? targetAlias = null, string? pin = null)
    {
        var session = Sender.CreateSession(target, items, targetAlias, pin);
        lock (_gate) _activeSends.Add(session);
        session.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(SendSession.State) && session.IsFinished)
                lock (_gate) _activeSends.Remove(session);
        };
        return session;
    }

    public SendSession CreateSend(Peer peer, IReadOnlyList<SendItem> items, string? pin = null) =>
        CreateSend(PeerEndpoint.From(peer), items, peer.Alias, pin);

    /// <summary>Probes a manually entered address (tries /register, then /info).</summary>
    public async Task<Peer?> ConnectManualAsync(PeerEndpoint endpoint, CancellationToken ct = default)
    {
        using var client = SlipHttp.CreateDiscoveryClient(TimeSpan.FromSeconds(3));
        var info = await SlipHttp.RegisterAsync(client, endpoint, LocalInfo, ct).ConfigureAwait(false)
                   ?? await SlipHttp.InfoAsync(client, endpoint, ct).ConfigureAwait(false);
        if (info is null) return null;
        if (string.IsNullOrEmpty(info.Fingerprint)) info = info with { Fingerprint = endpoint.ToString() };
        // Trust the address/port/protocol we actually reached.
        info = info with { Port = endpoint.Port, Protocol = endpoint.Scheme };
        return Peers.Upsert(info, endpoint.Host, PeerSource.Manual);
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        Sender.Dispose();
    }
}
