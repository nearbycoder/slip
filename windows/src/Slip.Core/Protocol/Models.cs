using System.Text.Json.Serialization;

namespace Slip.Core.Protocol;

/// <summary>LocalSend device type. Unknown values received from peers fall back to <see cref="Desktop"/>.</summary>
public enum DeviceType
{
    Mobile,
    Desktop,
    Web,
    Headless,
    Server,
}

public static class DeviceTypes
{
    public static string ToWire(this DeviceType type) => type switch
    {
        DeviceType.Mobile => "mobile",
        DeviceType.Desktop => "desktop",
        DeviceType.Web => "web",
        DeviceType.Headless => "headless",
        DeviceType.Server => "server",
        _ => "desktop",
    };

    /// <summary>Parses a wire value; null stays null, unknown values become <see cref="DeviceType.Desktop"/>.</summary>
    public static DeviceType? FromWire(string? value)
    {
        if (value is null) return null;
        return value.Trim().ToLowerInvariant() switch
        {
            "mobile" => DeviceType.Mobile,
            "desktop" => DeviceType.Desktop,
            "web" => DeviceType.Web,
            "headless" => DeviceType.Headless,
            "server" => DeviceType.Server,
            _ => DeviceType.Desktop,
        };
    }
}

/// <summary>Device description exchanged in announce, register, prepare-upload and info.</summary>
[JsonConverter(typeof(DeviceInfoConverter))]
public sealed record DeviceInfo
{
    public string Alias { get; init; } = "";
    public string Version { get; init; } = SlipConstants.ProtocolVersion;
    public string? DeviceModel { get; init; }
    public DeviceType? DeviceType { get; init; }
    public string Fingerprint { get; init; } = "";
    public int Port { get; init; } = SlipConstants.DefaultPort;
    /// <summary>"https" or "http".</summary>
    public string Protocol { get; init; } = "https";
    public bool Download { get; init; }

    public bool IsHttps => !string.Equals(Protocol, "http", StringComparison.OrdinalIgnoreCase);
}

/// <summary>A multicast discovery packet: <see cref="DeviceInfo"/> plus the announce flag.</summary>
public sealed record MulticastMessage(DeviceInfo Info, bool Announce);

[JsonConverter(typeof(FileMetadataConverter))]
public sealed record FileMetadata
{
    public DateTimeOffset? Modified { get; init; }
    public DateTimeOffset? Accessed { get; init; }
}

[JsonConverter(typeof(FileDtoConverter))]
public sealed record FileDto
{
    public string Id { get; init; } = "";
    public string FileName { get; init; } = "";
    public long Size { get; init; }
    public string FileType { get; init; } = "application/octet-stream";
    public string? Sha256 { get; init; }
    public string? Preview { get; init; }
    public FileMetadata? Metadata { get; init; }
}

public sealed record PrepareUploadRequest
{
    [JsonPropertyName("info")]
    public DeviceInfo Info { get; init; } = new();

    [JsonPropertyName("files")]
    public Dictionary<string, FileDto> Files { get; init; } = new();

    /// <summary>
    /// True when this request is a text message: every file is <c>text/*</c> with a non-null preview.
    /// </summary>
    [JsonIgnore]
    public bool IsTextMessage =>
        Files.Count > 0 &&
        Files.Values.All(f => f.FileType.StartsWith("text/", StringComparison.OrdinalIgnoreCase) && f.Preview is not null);
}

public sealed record PrepareUploadResponse
{
    [JsonPropertyName("sessionId")]
    public string SessionId { get; init; } = "";

    [JsonPropertyName("files")]
    public Dictionary<string, string> Files { get; init; } = new();
}
