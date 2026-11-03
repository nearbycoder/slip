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
    public void Upsert_ExpireAndPin()
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
        registry.ExpireStale(TimeSpan.FromSeconds(60));
        var remaining = Assert.Single(registry.Snapshot());
        Assert.Equal("b", remaining.Fingerprint);
        Assert.Equal(3, events);
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
