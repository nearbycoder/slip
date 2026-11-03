using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Slip.Core.Protocol;

/// <summary>Shared JSON options and helpers. Parsing is lenient: unknown fields are ignored,
/// missing optional fields get defaults and mistyped scalars are coerced where sensible.</summary>
public static class SlipJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
        WriteIndented = false,
    };

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Options);

    public static byte[] SerializeToUtf8<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static T? Deserialize<T>(string json) => JsonSerializer.Deserialize<T>(json, Options);

    public static T? Deserialize<T>(ReadOnlySpan<byte> utf8) => JsonSerializer.Deserialize<T>(utf8, Options);

    public static async Task<T?> DeserializeAsync<T>(Stream stream, CancellationToken ct = default) =>
        await JsonSerializer.DeserializeAsync<T>(stream, Options, ct).ConfigureAwait(false);

    /// <summary>Parses a DeviceInfo; returns null when the payload is not a JSON object or lacks a fingerprint/alias entirely.</summary>
    public static DeviceInfo? TryParseDeviceInfo(string json, int? defaultPort = null, string? defaultProtocol = null)
    {
        try
        {
            using var doc = JsonDocument.Parse(json, DocumentOptions);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            return DeviceInfoConverter.Read(doc.RootElement, defaultPort, defaultProtocol);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static string SerializeMulticast(MulticastMessage message)
    {
        var node = JsonSerializer.SerializeToNode(message.Info, Options)!.AsObject();
        node["announce"] = message.Announce;
        node["announcement"] = message.Announce; // legacy v1 key
        return node.ToJsonString(Options);
    }

    public static MulticastMessage? TryParseMulticast(ReadOnlySpan<byte> utf8)
    {
        try
        {
            var reader = new Utf8JsonReader(utf8, new JsonReaderOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip,
            });
            using var doc = JsonDocument.ParseValue(ref reader);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            var info = DeviceInfoConverter.Read(root, null, null);
            if (string.IsNullOrEmpty(info.Fingerprint)) return null;
            var announce = root.GetBool("announce") ?? root.GetBool("announcement") ?? false;
            return new MulticastMessage(info, announce);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    internal static readonly JsonDocumentOptions DocumentOptions = new()
    {
        AllowTrailingCommas = true,
        CommentHandling = JsonCommentHandling.Skip,
    };

    // ---- lenient JsonElement accessors (case-insensitive property names) ----

    internal static bool TryGet(this JsonElement obj, string name, out JsonElement value)
    {
        if (obj.ValueKind == JsonValueKind.Object)
        {
            if (obj.TryGetProperty(name, out value)) return true;
            foreach (var p in obj.EnumerateObject())
            {
                if (string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase))
                {
                    value = p.Value;
                    return true;
                }
            }
        }
        value = default;
        return false;
    }

    internal static string? GetString(this JsonElement obj, string name)
    {
        if (!obj.TryGet(name, out var v)) return null;
        return v.ValueKind switch
        {
            JsonValueKind.String => v.GetString(),
            JsonValueKind.Number => v.GetRawText(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => null,
        };
    }

    internal static long? GetLong(this JsonElement obj, string name)
    {
        if (!obj.TryGet(name, out var v)) return null;
        switch (v.ValueKind)
        {
            case JsonValueKind.Number:
                if (v.TryGetInt64(out var l)) return l;
                if (v.TryGetDouble(out var d)) return (long)d;
                return null;
            case JsonValueKind.String:
                return long.TryParse(v.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var s) ? s : null;
            default:
                return null;
        }
    }

    internal static bool? GetBool(this JsonElement obj, string name)
    {
        if (!obj.TryGet(name, out var v)) return null;
        return v.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            JsonValueKind.String => bool.TryParse(v.GetString(), out var b) ? b : null,
            JsonValueKind.Number => v.TryGetInt32(out var i) ? i != 0 : null,
            _ => null,
        };
    }

    internal static DateTimeOffset? GetDate(this JsonElement obj, string name)
    {
        var s = obj.GetString(name);
        if (string.IsNullOrWhiteSpace(s)) return null;
        if (DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AllowWhiteSpaces, out var dto))
            return dto;
        // Some senders use epoch milliseconds.
        if (long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var ms))
        {
            try { return DateTimeOffset.FromUnixTimeMilliseconds(ms); }
            catch (ArgumentOutOfRangeException) { return null; }
        }
        return null;
    }

    internal static string FormatDate(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
}

internal sealed class DeviceInfoConverter : JsonConverter<DeviceInfo>
{
    public override DeviceInfo Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        if (doc.RootElement.ValueKind != JsonValueKind.Object)
            throw new JsonException("DeviceInfo must be a JSON object");
        return Read(doc.RootElement, null, null);
    }

    internal static DeviceInfo Read(JsonElement e, int? defaultPort, string? defaultProtocol)
    {
        var port = e.GetLong("port");
        var protocol = e.GetString("protocol")?.Trim().ToLowerInvariant();
        if (protocol is not ("http" or "https")) protocol = null;
        return new DeviceInfo
        {
            Alias = e.GetString("alias") ?? "Unknown",
            Version = e.GetString("version") ?? "1.0",
            DeviceModel = e.GetString("deviceModel"),
            DeviceType = DeviceTypes.FromWire(e.GetString("deviceType")),
            Fingerprint = e.GetString("fingerprint") ?? "",
            Port = port is > 0 and <= 65535 ? (int)port.Value : defaultPort ?? SlipConstants.DefaultPort,
            Protocol = protocol ?? defaultProtocol ?? "https",
            Download = e.GetBool("download") ?? false,
        };
    }

    public override void Write(Utf8JsonWriter w, DeviceInfo value, JsonSerializerOptions options)
    {
        w.WriteStartObject();
        w.WriteString("alias", value.Alias);
        w.WriteString("version", value.Version);
        if (value.DeviceModel is null) w.WriteNull("deviceModel"); else w.WriteString("deviceModel", value.DeviceModel);
        if (value.DeviceType is null) w.WriteNull("deviceType"); else w.WriteString("deviceType", value.DeviceType.Value.ToWire());
        w.WriteString("fingerprint", value.Fingerprint);
        w.WriteNumber("port", value.Port);
        w.WriteString("protocol", value.IsHttps ? "https" : "http");
        w.WriteBoolean("download", value.Download);
        w.WriteEndObject();
    }
}

internal sealed class FileMetadataConverter : JsonConverter<FileMetadata>
{
    public override FileMetadata? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        return Read(doc.RootElement);
    }

    internal static FileMetadata? Read(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        return new FileMetadata { Modified = e.GetDate("modified"), Accessed = e.GetDate("accessed") };
    }

    public override void Write(Utf8JsonWriter w, FileMetadata value, JsonSerializerOptions options)
    {
        w.WriteStartObject();
        if (value.Modified is { } m) w.WriteString("modified", SlipJson.FormatDate(m)); else w.WriteNull("modified");
        if (value.Accessed is { } a) w.WriteString("accessed", SlipJson.FormatDate(a)); else w.WriteNull("accessed");
        w.WriteEndObject();
    }
}

internal sealed class FileDtoConverter : JsonConverter<FileDto>
{
    public override FileDto Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var e = doc.RootElement;
        if (e.ValueKind != JsonValueKind.Object) throw new JsonException("FileDto must be a JSON object");
        var sha = e.GetString("sha256");
        return new FileDto
        {
            Id = e.GetString("id") ?? "",
            FileName = e.GetString("fileName") ?? "",
            Size = Math.Max(0, e.GetLong("size") ?? 0),
            FileType = e.GetString("fileType") is { Length: > 0 } t ? t : "application/octet-stream",
            Sha256 = string.IsNullOrWhiteSpace(sha) ? null : sha,
            Preview = e.GetString("preview"),
            Metadata = e.TryGet("metadata", out var md) ? FileMetadataConverter.Read(md) : null,
        };
    }

    public override void Write(Utf8JsonWriter w, FileDto value, JsonSerializerOptions options)
    {
        w.WriteStartObject();
        w.WriteString("id", value.Id);
        w.WriteString("fileName", value.FileName);
        w.WriteNumber("size", value.Size);
        w.WriteString("fileType", value.FileType);
        if (value.Sha256 is null) w.WriteNull("sha256"); else w.WriteString("sha256", value.Sha256);
        if (value.Preview is null) w.WriteNull("preview"); else w.WriteString("preview", value.Preview);
        if (value.Metadata is null)
        {
            w.WriteNull("metadata");
        }
        else
        {
            w.WritePropertyName("metadata");
            JsonSerializer.Serialize(w, value.Metadata, options);
        }
        w.WriteEndObject();
    }
}
