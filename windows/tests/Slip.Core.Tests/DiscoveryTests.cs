using System.Net;
using Slip.Core.Discovery;
using Slip.Core.Identity;
using Slip.Core.Protocol;
using Slip.Core.Server;

namespace Slip.Core.Tests;

public class PeerRegistryTests
{
    private static DeviceInfo Info(string fp, string alias = "Peer") => new() { Alias = alias, Fingerprint = fp };

    [Fact]
    public void Stale_SkipsPinned_AndRemoveIgnoresRefreshedPeers()
    {
        var now = DateTimeOffset.UtcNow;
        var registry = new PeerRegistry(() => now);
        var events = 0;
        registry.Changed += (_, _) => events++;

        registry.Upsert(Info("a"), "10.0.0.1", PeerSource.Multicast);
        registry.Upsert(Info("b"), "10.0.0.2", PeerSource.Register);
        Assert.Equal(2, registry.Snapshot().Count);

        now += TimeSpan.FromSeconds(61);
        registry.IsPinned = fp => fp == "b";
        var stale = Assert.Single(registry.Stale(TimeSpan.FromSeconds(60)));
        Assert.Equal("a", stale.Fingerprint);

        // Seen again while the probe was in flight: the old snapshot must not remove it.
        registry.Upsert(Info("a"), "10.0.0.1", PeerSource.Register);
        Assert.False(registry.Remove(stale));
        Assert.Equal(2, registry.Snapshot().Count);

        Assert.True(registry.Remove(registry.Find("a")!));
        var remaining = Assert.Single(registry.Snapshot());
        Assert.Equal("b", remaining.Fingerprint);
        Assert.Equal(4, events);
    }

    [Fact]
    public void Upsert_MulticastAddressIsStickyButHttpWins()
    {
        var now = DateTimeOffset.UtcNow;
        var registry = new PeerRegistry(() => now);
        registry.Upsert(Info("a"), "192.168.1.5", PeerSource.Multicast);
        now += TimeSpan.FromSeconds(1);
        Assert.Equal("192.168.1.5", registry.Upsert(Info("a"), "100.64.0.9", PeerSource.Multicast).Address);
        now += TimeSpan.FromSeconds(30);
        Assert.Equal("100.64.0.9", registry.Upsert(Info("a"), "100.64.0.9", PeerSource.Multicast).Address);
        Assert.Equal("192.168.1.5", registry.Upsert(Info("a"), "192.168.1.5", PeerSource.Register).Address);
    }
}

/// <summary>Stale peers are probed with POST /register before removal.</summary>
public class PeerExpiryTests
{
    private static readonly DeviceInfo Self = new() { Alias = "Us", Fingerprint = "our-fingerprint", Port = 1, Protocol = "http" };

    private static DiscoveryService Discovery(PeerRegistry registry) =>
        new(() => Self, fp => fp == Self.Fingerprint, registry,
            new DiscoveryOptions { PeerProbeTimeout = TimeSpan.FromSeconds(2), AutoScanFallback = false });

    [Fact]
    public async Task StaleReachablePeer_IsRefreshedUnderItsOriginalKey()
    {
        using var identity = SlipIdentity.CreateEphemeral();
        SlipServer server = null!;
        server = new SlipServer(new ServerOptions { Port = 0, Https = false, BindAddress = IPAddress.Loopback },
            identity.Certificate,
            () => new DeviceInfo { Alias = "Reachable", Fingerprint = identity.FingerprintFor(false), Port = server.Port, Protocol = "http" },
            identity.IsOwnFingerprint, new PeerRegistry());
        await server.StartAsync();
        await using var _ = server;

        var now = DateTimeOffset.UtcNow;
        var registry = new PeerRegistry(() => now);
        registry.Upsert(new DeviceInfo { Alias = "Old name", Fingerprint = "original-fp", Port = server.Port, Protocol = "http" },
            "127.0.0.1", PeerSource.Multicast);
        now += SlipConstants.PeerExpiry + TimeSpan.FromSeconds(1);

        await using var discovery = Discovery(registry);
        await discovery.ExpireStaleAsync();

        var peer = Assert.Single(registry.Snapshot());
        Assert.Equal("original-fp", peer.Fingerprint);
        Assert.Equal(server.Port, peer.Info.Port);
        Assert.Equal("http", peer.Info.Protocol);
        Assert.Equal("Reachable", peer.Alias);
        Assert.Equal(now, peer.LastSeen);
    }

    [Fact]
    public async Task StaleUnreachablePeer_IsRemoved_PinnedAndFreshAreKept()
    {
        int closedPort;
        using (var listener = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0))
        {
            listener.Start();
            closedPort = ((IPEndPoint)listener.LocalEndpoint).Port;
        }

        var now = DateTimeOffset.UtcNow;
        var registry = new PeerRegistry(() => now) { IsPinned = fp => fp == "busy" };
        DeviceInfo Dead(string fp) => new() { Alias = fp, Fingerprint = fp, Port = closedPort, Protocol = "http" };
        registry.Upsert(Dead("gone"), "127.0.0.1", PeerSource.Multicast);
        registry.Upsert(Dead("busy"), "127.0.0.1", PeerSource.Multicast);
        now += SlipConstants.PeerExpiry + TimeSpan.FromSeconds(1);
        registry.Upsert(Dead("fresh"), "127.0.0.1", PeerSource.Multicast);

        await using var discovery = Discovery(registry);
        await discovery.ExpireStaleAsync();

        Assert.Equal(["busy", "fresh"], registry.Snapshot().Select(p => p.Fingerprint).Order());
    }
}

public class MulticastTests
{
    /// <summary>Two discovery services on one host see each other over multicast loopback and the
    /// announce is answered via POST /register. Skipped on CI runners, which often lack multicast.</summary>
    [Fact]
    public async Task TwoNodes_DiscoverEachOther()
    {
        if (Environment.GetEnvironmentVariable("CI") is not null) return;

        const int multicastPort = 53348;
        await using var a = await StartNode("Node A", multicastPort);
        await using var b = await StartNode("Node B", multicastPort);

        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(8);
        while (DateTime.UtcNow < deadline &&
               (a.Registry.Find(b.Fingerprint) is null || b.Registry.Find(a.Fingerprint) is null))
            await Task.Delay(100);

        var bSeenByA = a.Registry.Find(b.Fingerprint);
        var aSeenByB = b.Registry.Find(a.Fingerprint);
        Assert.NotNull(bSeenByA);
        Assert.NotNull(aSeenByB);
        Assert.Equal(b.Server.Port, bSeenByA.Info.Port);
        Assert.Equal("Node A", aSeenByB.Alias);
        // Neither node lists itself.
        Assert.Null(a.Registry.Find(a.Fingerprint));
    }

    private static async Task<TestNode> StartNode(string alias, int multicastPort)
    {
        var identity = SlipIdentity.CreateEphemeral();
        var registry = new PeerRegistry();
        SlipServer server = null!;
        DeviceInfo Local() => new()
        {
            Alias = alias,
            DeviceType = DeviceType.Headless,
            Fingerprint = identity.CertificateFingerprint,
            Port = server.Port,
        };
        server = new SlipServer(new ServerOptions { Port = 0, Https = true, BindAddress = IPAddress.Any },
            identity.Certificate, Local, identity.IsOwnFingerprint, registry);
        await server.StartAsync();
        var discovery = new DiscoveryService(Local, identity.IsOwnFingerprint, registry,
            new DiscoveryOptions { MulticastPort = multicastPort, AutoScanFallback = false });
        discovery.Start();
        return new TestNode(identity, registry, server, discovery);
    }

    private sealed record TestNode(SlipIdentity Identity, PeerRegistry Registry, SlipServer Server, DiscoveryService Discovery) : IAsyncDisposable
    {
        public string Fingerprint => Identity.CertificateFingerprint;

        public async ValueTask DisposeAsync()
        {
            await Discovery.DisposeAsync();
            await Server.DisposeAsync();
            Identity.Dispose();
        }
    }
}
