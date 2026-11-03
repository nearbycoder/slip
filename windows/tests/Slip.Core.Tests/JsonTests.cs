using System.Text;
using System.Text.Json;
using Slip.Core;
using Slip.Core.Protocol;

namespace Slip.Core.Tests;

public class JsonTests
{
    [Fact]
    public void DeviceInfo_RoundTrips()
    {
        var info = new DeviceInfo
        {
            Alias = "Nice Orange",
            DeviceModel = "Windows",
            DeviceType = DeviceType.Desktop,
            Fingerprint = "abc",
            Port = 53340,
            Protocol = "http",
            Download = true,
        };
        var json = SlipJson.Serialize(info);
        using var doc = JsonDocument.Parse(json);
        Assert.Equal("Nice Orange", doc.RootElement.GetProperty("alias").GetString());
        Assert.Equal("2.1", doc.RootElement.GetProperty("version").GetString());
        Assert.Equal("desktop", doc.RootElement.GetProperty("deviceType").GetString());
        Assert.Equal("http", doc.RootElement.GetProperty("protocol").GetString());
        Assert.Equal(53340, doc.RootElement.GetProperty("port").GetInt32());

        var back = SlipJson.Deserialize<DeviceInfo>(json);
        Assert.Equal(info, back);
    }

    [Fact]
    public void DeviceInfo_LenientDefaults()
    {
        // Minimal register response (no port/protocol/download/deviceType) plus an unknown field.
        var info = SlipJson.Deserialize<DeviceInfo>("""{"alias":"Secret Banana","version":"2.0","fingerprint":"f","somethingNew":{"x":1}}""")!;
        Assert.Equal("Secret Banana", info.Alias);
        Assert.Null(info.DeviceModel);
        Assert.Null(info.DeviceType);
        Assert.Equal(53317, info.Port);
        Assert.Equal("https", info.Protocol);
        Assert.False(info.Download);
    }

    [Fact]
    public void DeviceInfo_LenientTypesAndUnknownDeviceType()
    {
        var info = SlipJson.Deserialize<DeviceInfo>(
            """{"alias":"A","fingerprint":"f","port":"53399","protocol":"HTTP","deviceType":"toaster","deviceModel":null,"download":"true",}""")!;
        Assert.Equal(53399, info.Port);
        Assert.Equal("http", info.Protocol);
        Assert.Equal(DeviceType.Desktop, info.DeviceType); // unknown -> desktop
        Assert.True(info.Download);
    }

    [Fact]
    public void DeviceInfo_DefaultPortProtocolOverride()
    {
        var info = SlipJson.TryParseDeviceInfo("""{"alias":"A","fingerprint":"f"}""", 53345, "http")!;
        Assert.Equal(53345, info.Port);
        Assert.Equal("http", info.Protocol);
        Assert.Null(SlipJson.TryParseDeviceInfo("not json"));
        Assert.Null(SlipJson.TryParseDeviceInfo("[1,2]"));
    }

    [Fact]
    public void Multicast_WritesBothAnnounceKeys()
    {
        var json = SlipJson.SerializeMulticast(new MulticastMessage(new DeviceInfo { Alias = "A", Fingerprint = "f" }, true));
        using var doc = JsonDocument.Parse(json);
        Assert.True(doc.RootElement.GetProperty("announce").GetBoolean());
        Assert.True(doc.RootElement.GetProperty("announcement").GetBoolean());
        Assert.Equal("f", doc.RootElement.GetProperty("fingerprint").GetString());
    }

    [Theory]
    [InlineData("""{"alias":"A","fingerprint":"f","announce":true}""", true)]
    [InlineData("""{"alias":"A","fingerprint":"f","announcement":true}""", true)]
    [InlineData("""{"alias":"A","fingerprint":"f","announce":false}""", false)]
    [InlineData("""{"alias":"A","fingerprint":"f"}""", false)]
    public void Multicast_AcceptsEitherAnnounceKey(string json, bool expected)
    {
        var msg = SlipJson.TryParseMulticast(Encoding.UTF8.GetBytes(json));
        Assert.NotNull(msg);
        Assert.Equal(expected, msg.Announce);
    }

    [Fact]
    public void Multicast_RejectsGarbage()
    {
        Assert.Null(SlipJson.TryParseMulticast(Encoding.UTF8.GetBytes("hello")));
        Assert.Null(SlipJson.TryParseMulticast(Encoding.UTF8.GetBytes("""{"alias":"no fingerprint"}""")));
    }

    [Fact]
    public void FileDto_RoundTripsWithMetadata()
    {
        var dto = new FileDto
        {
            Id = "1",
            FileName = "a.png",
            Size = 123,
            FileType = "image/png",
            Metadata = new FileMetadata { Modified = new DateTimeOffset(2024, 1, 1, 12, 0, 0, TimeSpan.Zero) },
        };
        var json = SlipJson.Serialize(dto);
        using var doc = JsonDocument.Parse(json);
        Assert.Equal(JsonValueKind.Null, doc.RootElement.GetProperty("sha256").ValueKind);
        Assert.Equal(JsonValueKind.Null, doc.RootElement.GetProperty("preview").ValueKind);
        Assert.StartsWith("2024-01-01T12:00:00", doc.RootElement.GetProperty("metadata").GetProperty("modified").GetString());
        Assert.Equal(dto, SlipJson.Deserialize<FileDto>(json));
    }

    [Fact]
    public void PrepareUpload_ParsesLocalSendShape()
    {
        const string json = """
            {
              "info": {"alias":"Nice Orange","version":"2.0","deviceModel":"Samsung","deviceType":"mobile","fingerprint":"x","port":53317,"protocol":"https","download":true},
              "files": {
                "a": {"id":"a","fileName":"my image.png","size":324242,"fileType":"image/jpeg","sha256":"","preview":null,
                      "metadata":{"modified":"2021-01-01T12:34:56Z","accessed":null}},
                "b": {"id":"b","fileName":"x.txt","size":"5","fileType":null,"extra":42}
              }
            }
            """;
        var req = SlipJson.Deserialize<PrepareUploadRequest>(json)!;
        Assert.Equal(DeviceType.Mobile, req.Info.DeviceType);
        Assert.Equal(2, req.Files.Count);
        Assert.Null(req.Files["a"].Sha256); // empty string treated as absent
        Assert.Equal(new DateTimeOffset(2021, 1, 1, 12, 34, 56, TimeSpan.Zero), req.Files["a"].Metadata!.Modified);
        Assert.Null(req.Files["a"].Metadata!.Accessed);
        Assert.Equal(5, req.Files["b"].Size);
        Assert.Equal("application/octet-stream", req.Files["b"].FileType);
        Assert.False(req.IsTextMessage);
    }

    [Fact]
    public void PrepareUpload_DetectsTextMessage()
    {
        var req = new PrepareUploadRequest
        {
            Files = { ["t"] = new FileDto { Id = "t", FileName = "t.txt", FileType = "text/plain", Size = 2, Preview = "hi" } },
        };
        Assert.True(req.IsTextMessage);
        var noPreview = new PrepareUploadRequest
        {
            Files = { ["t"] = new FileDto { Id = "t", FileName = "t.txt", FileType = "text/plain", Size = 2 } },
        };
        Assert.False(noPreview.IsTextMessage);
    }

    [Fact]
    public void PrepareUploadResponse_RoundTrips()
    {
        var resp = new PrepareUploadResponse { SessionId = "s", Files = { ["a"] = "tok" } };
        var json = SlipJson.Serialize(resp);
        Assert.Equal("""{"sessionId":"s","files":{"a":"tok"}}""", json);
        var back = SlipJson.Deserialize<PrepareUploadResponse>(json)!;
        Assert.Equal("tok", back.Files["a"]);
    }

    [Fact]
    public void Settings_RoundTripThroughStore()
    {
        var dir = Path.Combine(Path.GetTempPath(), "slip-settings-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new SettingsStore(Path.Combine(dir, "settings.json"));
            var s = store.Load();
            Assert.False(string.IsNullOrWhiteSpace(s.Alias));
            s.Port = 53341;
            s.Theme = AppTheme.Dark;
            s.RequirePin = true;
            s.Pin = "1234";
            store.Save(s);
            var back = new SettingsStore(store.FilePath).Load();
            Assert.Equal(53341, back.Port);
            Assert.Equal(AppTheme.Dark, back.Theme);
            Assert.Equal("1234", back.EffectivePin);
            Assert.Equal(s.Alias, back.Alias);
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }
}
