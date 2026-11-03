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

/// <summary>Thread-safe peer list with expiry. Events fire on the calling thread.</summary>
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

    public void ExpireStale(TimeSpan maxAge)
    {
        List<Peer> removed;
        lock (_gate)
        {
            var cutoff = _clock() - maxAge;
            removed = _peers.Values.Where(p => p.LastSeen < cutoff && !(IsPinned?.Invoke(p.Fingerprint) ?? false)).ToList();
            foreach (var p in removed) _peers.Remove(p.Fingerprint);
        }
        foreach (var p in removed) PeerRemoved?.Invoke(this, new PeerEventArgs(p, false));
        if (removed.Count > 0) Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Clear()
    {
        lock (_gate) _peers.Clear();
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
