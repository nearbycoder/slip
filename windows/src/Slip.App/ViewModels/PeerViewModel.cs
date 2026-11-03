using CommunityToolkit.Mvvm.ComponentModel;
using Slip.App.Helpers;
using Slip.Core.Discovery;
using Slip.Core.Util;

namespace Slip.App.ViewModels;

/// <summary>A nearby device card on the Send page.</summary>
public sealed partial class PeerViewModel : ObservableObject
{
    private Peer _peer;
    private bool _isSending;

    public PeerViewModel(Peer peer) => _peer = peer;

    public Peer Peer => _peer;
    public string Fingerprint => _peer.Fingerprint;
    public string Alias => _peer.Alias;
    public string Model => _peer.Info.DeviceModel ?? "Unknown device";
    public string AddressText => $"{NetUtil.HostPort(_peer.Address, _peer.Info.Port)} · {_peer.Info.Protocol.ToUpperInvariant()}";
    public string Glyph => Format.DeviceGlyph(_peer.Info.DeviceType);

    public bool IsSending
    {
        get => _isSending;
        set => SetProperty(ref _isSending, value);
    }

    public void Update(Peer peer)
    {
        var changed = peer.Info != _peer.Info || peer.Address != _peer.Address;
        _peer = peer;
        if (!changed) return;
        OnPropertyChanged(nameof(Alias));
        OnPropertyChanged(nameof(Model));
        OnPropertyChanged(nameof(AddressText));
        OnPropertyChanged(nameof(Glyph));
    }
}

/// <summary>An entry in the send selection tray (a file, a folder, or a text message).</summary>
public sealed partial class SelectionItemViewModel : ObservableObject
{
    public SelectionItemViewModel(string name, string detail, string glyph, IReadOnlyList<Slip.Core.Client.SendItem> items)
    {
        Name = name;
        Detail = detail;
        Glyph = glyph;
        Items = items;
    }

    public string Name { get; }
    public string Detail { get; }
    public string Glyph { get; }
    public IReadOnlyList<Slip.Core.Client.SendItem> Items { get; }
}
