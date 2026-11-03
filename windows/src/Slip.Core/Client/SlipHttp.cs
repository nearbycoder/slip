using System.Net;
using System.Net.Http.Headers;
using System.Net.Security;
using System.Text;
using Slip.Core.Discovery;
using Slip.Core.Protocol;

namespace Slip.Core.Client;

/// <summary>Endpoint of a peer's HTTP(S) server.</summary>
public sealed record PeerEndpoint(string Host, int Port, bool Https)
{
    public string Scheme => Https ? "https" : "http";

    public Uri Url(string route, string? query = null)
    {
        var host = Host.Contains(':') && !Host.StartsWith('[') ? $"[{Host}]" : Host;
        var q = string.IsNullOrEmpty(query) ? "" : "?" + query;
        return new Uri($"{Scheme}://{host}:{Port}{SlipConstants.ApiPrefix}/{route}{q}");
    }

    /// <summary>Parses "host:port", "[v6]:port" or "host" (default port).</summary>
    public static PeerEndpoint Parse(string text, bool https)
    {
        text = text.Trim();
        if (text.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) { https = false; text = text[7..]; }
        else if (text.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) { https = true; text = text[8..]; }
        text = text.TrimEnd('/');

        if (text.StartsWith('['))
        {
            var close = text.IndexOf(']');
            if (close < 0) throw new FormatException($"Invalid address '{text}'");
            var host6 = text[1..close];
            var rest = text[(close + 1)..];
            var port6 = rest.StartsWith(':') ? int.Parse(rest[1..]) : SlipConstants.DefaultPort;
            return new PeerEndpoint(host6, port6, https);
        }

        var colon = text.LastIndexOf(':');
        if (colon > 0 && text.IndexOf(':') == colon && int.TryParse(text[(colon + 1)..], out var port))
            return new PeerEndpoint(text[..colon], port, https);
        return new PeerEndpoint(text, SlipConstants.DefaultPort, https);
    }

    public static PeerEndpoint From(Peer peer) => new(peer.Address, peer.Info.Port, peer.Info.IsHttps);

    public override string ToString() => $"{Scheme}://{(Host.Contains(':') ? $"[{Host}]" : Host)}:{Port}";
}

/// <summary>HttpClient factory. LocalSend peers use self-signed certificates, so chain and
/// hostname validation are disabled for these clients (and only these).</summary>
public static class SlipHttp
{
    public static SocketsHttpHandler CreateHandler(TimeSpan connectTimeout) => new()
    {
        ConnectTimeout = connectTimeout,
        PooledConnectionLifetime = TimeSpan.FromMinutes(2),
        AutomaticDecompression = DecompressionMethods.None,
        UseProxy = false,
        SslOptions = new SslClientAuthenticationOptions
        {
            RemoteCertificateValidationCallback = static (_, _, _, _) => true,
        },
    };

    /// <summary>Client with no overall timeout (callers pass cancellation tokens): prepare-upload may be held
    /// open while the receiver decides, and uploads can take arbitrarily long.</summary>
    public static HttpClient CreateTransferClient() =>
        new(CreateHandler(TimeSpan.FromSeconds(5)), disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };

    /// <summary>Client for quick discovery calls (register / info / scan).</summary>
    public static HttpClient CreateDiscoveryClient(TimeSpan? timeout = null) =>
        new(CreateHandler(timeout ?? TimeSpan.FromSeconds(2)), disposeHandler: true) { Timeout = timeout ?? TimeSpan.FromSeconds(3) };

    public static StringContent JsonContent<T>(T value) =>
        new(SlipJson.Serialize(value), Encoding.UTF8, new MediaTypeHeaderValue("application/json"));

    /// <summary>POST /register to a peer; returns its DeviceInfo, or null on any failure.</summary>
    public static async Task<DeviceInfo?> RegisterAsync(HttpClient client, PeerEndpoint target, DeviceInfo self, CancellationToken ct = default)
    {
        try
        {
            using var response = await client.PostAsync(target.Url("register"), JsonContent(self), ct).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return null;
            var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            // The register response may omit port/protocol: they are the ones we just used.
            return SlipJson.TryParseDeviceInfo(body, target.Port, target.Scheme);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or OperationCanceledException or IOException)
        {
            return null;
        }
    }

    /// <summary>GET /info from a peer.</summary>
    public static async Task<DeviceInfo?> InfoAsync(HttpClient client, PeerEndpoint target, CancellationToken ct = default)
    {
        try
        {
            var body = await client.GetStringAsync(target.Url("info"), ct).ConfigureAwait(false);
            return SlipJson.TryParseDeviceInfo(body, target.Port, target.Scheme);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or OperationCanceledException or IOException)
        {
            return null;
        }
    }
}
