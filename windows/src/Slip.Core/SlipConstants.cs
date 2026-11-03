namespace Slip.Core;

public static class SlipConstants
{
    /// <summary>Protocol version string advertised to peers.</summary>
    public const string ProtocolVersion = "2.1";
    public const int DefaultPort = 53317;
    public const string MulticastGroup = "224.0.0.167";
    public const int MulticastPort = 53317;
    public const string ApiPrefix = "/api/localsend/v2";
    public const int MulticastTtl = 32;

    /// <summary>How long prepare-upload waits for the user's decision before answering 403.</summary>
    public static readonly TimeSpan DecisionTimeout = TimeSpan.FromSeconds(60);

    /// <summary>Peers not seen for this long are removed (unless a transfer with them is active).</summary>
    public static readonly TimeSpan PeerExpiry = TimeSpan.FromSeconds(60);

    public const int MaxParallelUploads = 3;
}
