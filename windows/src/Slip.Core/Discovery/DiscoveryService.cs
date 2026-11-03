using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using Slip.Core.Client;
using Slip.Core.Protocol;
using Slip.Core.Util;

namespace Slip.Core.Discovery;

public sealed class DiscoveryOptions
{
    public string MulticastGroup { get; init; } = SlipConstants.MulticastGroup;
    public int MulticastPort { get; init; } = SlipConstants.MulticastPort;
    /// <summary>Run an HTTP /24 scan if no peers were found a few seconds after start.</summary>
    public bool AutoScanFallback { get; init; } = true;
    public TimeSpan AutoScanDelay { get; init; } = TimeSpan.FromSeconds(4);
    /// <summary>Port probed by the HTTP scan (normally our own configured port).</summary>
    public int ScanPort { get; init; } = SlipConstants.DefaultPort;
    public bool ScanHttps { get; init; } = true;
    /// <summary>Peers silent for this long are probed with /register and removed if that fails.</summary>
    public TimeSpan PeerExpiry { get; init; } = SlipConstants.PeerExpiry;
    public TimeSpan PeerProbeTimeout { get; init; } = SlipConstants.PeerProbeTimeout;
}

/// <summary>
/// Multicast UDP discovery (announce ×3, answer announcements via /register with a UDP fallback)
/// plus the legacy HTTP subnet scan.
/// </summary>
public sealed class DiscoveryService : IAsyncDisposable
{
    private readonly Func<DeviceInfo> _localInfo;
    private readonly Func<string?, bool> _isSelf;
    private readonly PeerRegistry _registry;
    private readonly DiscoveryOptions _options;
    private readonly HttpClient _http;
    private readonly HttpClient _probeHttp;
    private readonly IPAddress _group;
    private readonly object _sendGate = new();
    private readonly HashSet<IPAddress> _joined = [];

    private Socket? _socket;
    private CancellationTokenSource? _cts;
    private Task? _receiveLoop;
    private Task? _expiryLoop;
    private int _scanRunning;

    /// <summary>When false we neither announce nor answer announcements (but still listen).</summary>
    public bool Discoverable { get; set; } = true;

    public bool IsRunning => _socket is not null;
    public bool IsScanning => Volatile.Read(ref _scanRunning) == 1;

    public event EventHandler? ScanningChanged;

    public DiscoveryService(Func<DeviceInfo> localInfo, Func<string?, bool> isSelf, PeerRegistry registry, DiscoveryOptions? options = null)
    {
        _localInfo = localInfo;
        _isSelf = isSelf;
        _registry = registry;
        _options = options ?? new DiscoveryOptions();
        _group = IPAddress.Parse(_options.MulticastGroup);
        _http = SlipHttp.CreateDiscoveryClient(TimeSpan.FromSeconds(2));
        _probeHttp = SlipHttp.CreateDiscoveryClient(_options.PeerProbeTimeout);
    }

    public void Start()
    {
        if (_socket is not null) return;
        _cts = new CancellationTokenSource();

        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        try
        {
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            TrySetReusePort(socket);
            socket.Bind(new IPEndPoint(IPAddress.Any, _options.MulticastPort));
            socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, SlipConstants.MulticastTtl);
            socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastLoopback, true);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
        _socket = socket;
        JoinGroups();

        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        _receiveLoop = Task.Run(() => ReceiveLoopAsync(_cts.Token));
        _expiryLoop = Task.Run(() => ExpiryLoopAsync(_cts.Token));
        SlipLog.Info($"Multicast listening on {_options.MulticastGroup}:{_options.MulticastPort}");

        _ = AnnounceAsync();
        if (_options.AutoScanFallback) _ = AutoScanAsync(_cts.Token);
    }

    private async Task AutoScanAsync(CancellationToken ct)
    {
        try
        {
            await Task.Delay(_options.AutoScanDelay, ct).ConfigureAwait(false);
            if (_registry.Snapshot().Count == 0) await ScanAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
    }

    private static void TrySetReusePort(Socket socket)
    {
        // .NET already sets SO_REUSEPORT alongside SO_REUSEADDR on most Unix builds; be explicit anyway.
        try
        {
            if (OperatingSystem.IsMacOS() || OperatingSystem.IsIOS() || OperatingSystem.IsFreeBSD())
                socket.SetRawSocketOption(0xffff /* SOL_SOCKET */, 0x0200 /* SO_REUSEPORT */, BitConverter.GetBytes(1));
            else if (OperatingSystem.IsLinux() || OperatingSystem.IsAndroid())
                socket.SetRawSocketOption(1 /* SOL_SOCKET */, 15 /* SO_REUSEPORT */, BitConverter.GetBytes(1));
        }
        catch (SocketException) { }
    }

    private void JoinGroups()
    {
        var socket = _socket;
        if (socket is null) return;
        var interfaces = NetUtil.GetIPv4Interfaces().Where(i => i.SupportsMulticast).ToList();
        lock (_sendGate)
        {
            foreach (var iface in interfaces)
            {
                if (_joined.Contains(iface.Address)) continue;
                try
                {
                    socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.AddMembership, new MulticastOption(_group, iface.Address));
                    _joined.Add(iface.Address);
                    SlipLog.Debug($"Joined {_group} on {iface.Name} ({iface.Address})");
                }
                catch (SocketException e)
                {
                    SlipLog.Debug($"Join {_group} on {iface.Address} failed: {e.SocketErrorCode}");
                }
            }
            if (_joined.Count == 0)
            {
                try
                {
                    socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.AddMembership, new MulticastOption(_group, IPAddress.Any));
                    _joined.Add(IPAddress.Any);
                }
                catch (SocketException e)
                {
                    SlipLog.Warn($"Could not join multicast group: {e.SocketErrorCode}");
                }
            }
        }
    }

    private void OnNetworkChanged(object? sender, EventArgs e)
    {
        SlipLog.Debug("Network change detected; rejoining multicast and announcing");
        JoinGroups();
        _ = AnnounceAsync();
    }

    /// <summary>Sends our announcement three times (~100 ms, ~500 ms, ~2000 ms).</summary>
    public async Task AnnounceAsync()
    {
        var ct = _cts?.Token ?? CancellationToken.None;
        try
        {
            var start = Environment.TickCount64;
            foreach (var at in (int[])[100, 500, 2000])
            {
                var wait = at - (int)(Environment.TickCount64 - start);
                if (wait > 0) await Task.Delay(wait, ct).ConfigureAwait(false);
                if (!Discoverable) return;
                SendMulticast(announce: true);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
    }

    private void SendMulticast(bool announce)
    {
        var socket = _socket;
        if (socket is null) return;
        var payload = Encoding.UTF8.GetBytes(SlipJson.SerializeMulticast(new MulticastMessage(_localInfo(), announce)));
        var target = new IPEndPoint(_group, _options.MulticastPort);
        var interfaces = NetUtil.GetIPv4Interfaces().Where(i => i.SupportsMulticast).ToList();

        lock (_sendGate)
        {
            var sent = false;
            foreach (var iface in interfaces)
            {
                try
                {
                    socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, iface.Address.GetAddressBytes());
                    socket.SendTo(payload, target);
                    sent = true;
                }
                catch (SocketException e)
                {
                    SlipLog.Debug($"Multicast send via {iface.Address} failed: {e.SocketErrorCode}");
                }
            }
            if (!sent)
            {
                try { socket.SendTo(payload, target); }
                catch (SocketException e) { SlipLog.Debug($"Multicast send failed: {e.SocketErrorCode}"); }
            }
        }
    }

    private async Task ReceiveLoopAsync(CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        while (!ct.IsCancellationRequested && _socket is { } socket)
        {
            SocketReceiveFromResult result;
            try
            {
                result = await socket.ReceiveFromAsync(buffer, SocketFlags.None, new IPEndPoint(IPAddress.Any, 0), ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (SocketException e)
            {
                SlipLog.Debug($"Multicast receive error: {e.SocketErrorCode}");
                await Task.Delay(200, CancellationToken.None).ConfigureAwait(false);
                continue;
            }

            var message = SlipJson.TryParseMulticast(buffer.AsSpan(0, result.ReceivedBytes));
            if (message is null || _isSelf(message.Info.Fingerprint)) continue;
            var ip = NetUtil.Normalize(((IPEndPoint)result.RemoteEndPoint).Address).ToString();
            var peer = _registry.Upsert(message.Info, ip, PeerSource.Multicast);
            SlipLog.Debug($"Multicast from {peer.Alias} @ {ip} (announce={message.Announce})");
            if (message.Announce && Discoverable) _ = RespondAsync(peer, ct);
        }
    }

    private async Task RespondAsync(Peer peer, CancellationToken ct)
    {
        var info = await SlipHttp.RegisterAsync(_http, PeerEndpoint.From(peer), _localInfo(), ct).ConfigureAwait(false);
        if (info is null)
        {
            SlipLog.Debug($"Register at {peer.Address}:{peer.Info.Port} failed; answering via multicast");
            SendMulticast(announce: false);
        }
    }

    private async Task ExpiryLoopAsync(CancellationToken ct)
    {
        var tick = TimeSpan.FromSeconds(10);
        using var timer = new PeriodicTimer(tick);
        var sinceAnnounce = TimeSpan.Zero;
        try
        {
            while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            {
                // Peers only announce at startup, so ask again periodically; their /register replies refresh them.
                sinceAnnounce += tick;
                if (sinceAnnounce >= SlipConstants.ReannounceInterval)
                {
                    sinceAnnounce = TimeSpan.Zero;
                    if (Discoverable) SendMulticast(announce: true);
                }
                await ExpireStaleAsync(ct).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>Probes peers not seen within <see cref="DiscoveryOptions.PeerExpiry"/> with POST /register
    /// (concurrently) and removes only those that don't answer. Answering peers are refreshed under their
    /// original fingerprint, port and protocol. Pinned peers (active transfers) are never touched.</summary>
    public async Task ExpireStaleAsync(CancellationToken ct = default)
    {
        var stale = _registry.Stale(_options.PeerExpiry);
        if (stale.Count == 0) return;
        var self = _localInfo();
        await Task.WhenAll(stale.Select(async peer =>
        {
            var reply = await SlipHttp.RegisterAsync(_probeHttp, PeerEndpoint.From(peer), self, ct).ConfigureAwait(false);
            if (ct.IsCancellationRequested) return;
            if (reply is not null)
            {
                _registry.Upsert(reply with { Fingerprint = peer.Fingerprint, Port = peer.Info.Port, Protocol = peer.Info.Protocol },
                    peer.Address, peer.Source);
            }
            else if (_registry.Remove(peer))
            {
                SlipLog.Debug($"Peer {peer.Alias} @ {peer.Address} is gone");
            }
        })).ConfigureAwait(false);
    }

    /// <summary>Legacy HTTP discovery: POST /register to every host of each local /24 (≤50 concurrent, ~1 s timeout).</summary>
    public async Task ScanAsync(CancellationToken ct = default)
    {
        if (Interlocked.Exchange(ref _scanRunning, 1) == 1) return;
        ScanningChanged?.Invoke(this, EventArgs.Empty);
        try
        {
            var self = _localInfo();
            var targets = NetUtil.ScanTargets(NetUtil.GetIPv4Interfaces()).ToList();
            SlipLog.Debug($"HTTP scan of {targets.Count} hosts on port {_options.ScanPort}");
            using var client = SlipHttp.CreateDiscoveryClient(TimeSpan.FromSeconds(1));
            await Parallel.ForEachAsync(targets, new ParallelOptions { MaxDegreeOfParallelism = 50, CancellationToken = ct },
                async (ip, token) =>
                {
                    var endpoint = new PeerEndpoint(ip.ToString(), _options.ScanPort, _options.ScanHttps);
                    var info = await SlipHttp.RegisterAsync(client, endpoint, self, token).ConfigureAwait(false);
                    if (info is not null && !_isSelf(info.Fingerprint) && !string.IsNullOrEmpty(info.Fingerprint))
                        _registry.Upsert(info, ip.ToString(), PeerSource.Scan);
                }).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
        finally
        {
            Volatile.Write(ref _scanRunning, 0);
            ScanningChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>Announce again and, if requested, run the HTTP scan too (refresh button).</summary>
    public async Task RefreshAsync(bool scan, CancellationToken ct = default)
    {
        JoinGroups();
        var announce = AnnounceAsync();
        if (scan) await ScanAsync(ct).ConfigureAwait(false);
        await announce.ConfigureAwait(false);
    }

    public async Task StopAsync()
    {
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        var cts = _cts;
        _cts = null;
        cts?.Cancel();
        var socket = _socket;
        _socket = null;
        socket?.Dispose();
        lock (_sendGate) _joined.Clear();
        try
        {
            if (_receiveLoop is not null) await _receiveLoop.ConfigureAwait(false);
            if (_expiryLoop is not null) await _expiryLoop.ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
        cts?.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _http.Dispose();
        _probeHttp.Dispose();
    }
}
