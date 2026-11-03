using Slip.Core.Protocol;

namespace Slip.Core.Discovery;

public enum PeerSource
{
    Multicast,
    Register,
    Scan,
    Manual,
}

/// <summary>A nearby device. Keyed by fingerprint; <see cref="Address"/> is the IP we last heard it from.</summary>
public sealed record Peer(DeviceInfo Info, string Address, DateTimeOffset LastSeen, PeerSource Source)
{
    public string Fingerprint => Info.Fingerprint;
    public string Alias => Info.Alias;
}

public sealed class PeerEventArgs(Peer peer, bool isNew) : EventArgs
{
    public Peer Peer { get; } = peer;
    public bool IsNew { get; } = isNew;
}

/// <summary>Thread-safe peer list. Silent peers are found with <see cref="Stale"/> and probed before removal
/// (see <see cref="DiscoveryService.ExpireStaleAsync"/>). Events fire on the calling thread.</summary>
public sealed class PeerRegistry
{
    private readonly object _gate = new();
    private readonly Dictionary<string, Peer> _peers = new(StringComparer.OrdinalIgnoreCase);
    private readonly Func<DateTimeOffset> _clock;

    /// <summary>Returns true for fingerprints that must not expire (e.g. an active transfer).</summary>
    public Func<string, bool>? IsPinned { get; set; }

    public event EventHandler<PeerEventArgs>? PeerUpdated;
    public event EventHandler<PeerEventArgs>? PeerRemoved;
    /// <summary>Raised after any change to the list.</summary>
    public event EventHandler? Changed;

    public PeerRegistry(Func<DateTimeOffset>? clock = null) => _clock = clock ?? (() => DateTimeOffset.UtcNow);

    public static TimeSpan AddressStickiness { get; } = TimeSpan.FromSeconds(10);

    public IReadOnlyList<Peer> Snapshot()
    {
        lock (_gate) return _peers.Values.OrderBy(p => p.Alias, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    public Peer? Find(string fingerprint)
    {
        lock (_gate) return _peers.GetValueOrDefault(fingerprint);
    }

    public Peer Upsert(DeviceInfo info, string address, PeerSource source)
    {
        Peer peer;
        bool isNew;
        lock (_gate)
        {
            var now = _clock();
            isNew = !_peers.TryGetValue(info.Fingerprint, out var existing);
            // Multicast packets arrive once per interface (LAN, VPN, …). Keep an address we heard from
            // in the last few seconds instead of flapping between them; direct HTTP contact always wins.
            if (existing is not null && source == PeerSource.Multicast && existing.Address != address &&
                now - existing.LastSeen < AddressStickiness)
                address = existing.Address;
            peer = new Peer(info, address, now, source);
            _peers[info.Fingerprint] = peer;
        }
        PeerUpdated?.Invoke(this, new PeerEventArgs(peer, isNew));
        Changed?.Invoke(this, EventArgs.Empty);
        return peer;
    }

    /// <summary>Peers not seen within <paramref name="maxAge"/>, excluding pinned ones.</summary>
    public IReadOnlyList<Peer> Stale(TimeSpan maxAge)
    {
        lock (_gate)
        {
            var cutoff = _clock() - maxAge;
            return _peers.Values.Where(p => p.LastSeen < cutoff && !(IsPinned?.Invoke(p.Fingerprint) ?? false)).ToList();
        }
    }

    /// <summary>Removes <paramref name="peer"/> unless it has been seen again since that snapshot was taken.</summary>
    public bool Remove(Peer peer)
    {
        Peer? removed;
        lock (_gate)
        {
            if (!_peers.TryGetValue(peer.Fingerprint, out removed) || removed.LastSeen > peer.LastSeen) return false;
            _peers.Remove(peer.Fingerprint);
        }
        PeerRemoved?.Invoke(this, new PeerEventArgs(removed, false));
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    public void Clear()
    {
        lock (_gate) _peers.Clear();
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
