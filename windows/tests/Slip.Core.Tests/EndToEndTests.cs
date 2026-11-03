using System.Net;
using System.Security.Cryptography;
using System.Text;
using Slip.Core.Client;
using Slip.Core.Discovery;
using Slip.Core.Identity;
using Slip.Core.Protocol;
using Slip.Core.Server;

namespace Slip.Core.Tests;

/// <summary>Loopback tests: a real Kestrel server on a random port and the real sender client.</summary>
public sealed class EndToEndTests : IAsyncLifetime
{
    private static readonly Lazy<SlipIdentity> ServerIdentity = new(SlipIdentity.CreateEphemeral);
    private readonly string _root = Path.Combine(Path.GetTempPath(), "slip-e2e-" + Guid.NewGuid().ToString("N"));
    private readonly List<IAsyncDisposable> _disposables = [];

    private string SaveDir => Path.Combine(_root, "inbox");
    private string SourceDir => Path.Combine(_root, "outbox");

    public Task InitializeAsync()
    {
        Directory.CreateDirectory(SaveDir);
        Directory.CreateDirectory(SourceDir);
        return Task.CompletedTask;
    }

    public async Task DisposeAsync()
    {
        foreach (var d in _disposables) await d.DisposeAsync();
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    private static readonly DeviceInfo SenderInfo = new()
    {
        Alias = "Test Sender",
        DeviceModel = "Tests",
        DeviceType = DeviceType.Headless,
        Fingerprint = "sender-fingerprint",
        Port = 53349,
    };

    private async Task<(SlipServer Server, PeerRegistry Registry)> StartServerAsync(bool https, Action<SlipServer>? configure = null)
    {
        var identity = ServerIdentity.Value;
        var registry = new PeerRegistry();
        SlipServer server = null!;
        server = new SlipServer(
            new ServerOptions { Port = 0, Https = https, BindAddress = IPAddress.Loopback },
            identity.Certificate,
            () => new DeviceInfo
            {
                Alias = "Test Receiver",
                DeviceModel = "Tests",
                DeviceType = DeviceType.Desktop,
                Fingerprint = identity.FingerprintFor(https),
                Port = server.Port,
                Protocol = https ? "https" : "http",
            },
            identity.IsOwnFingerprint,
            registry)
        {
            SaveDirectory = SaveDir,
            AutoAccept = true,
        };
        configure?.Invoke(server);
        await server.StartAsync();
        _disposables.Add(server);
        Assert.True(server.Port > 0);
        return (server, registry);
    }

    private static PeerEndpoint Endpoint(SlipServer server) => new("127.0.0.1", server.Port, server.Https);

    private SlipSender NewSender(bool sha = false)
    {
        var sender = new SlipSender(() => SenderInfo) { ComputeSha256 = sha };
        _disposables.Add(new AsyncDisposableAdapter(sender));
        return sender;
    }

    private string WriteSource(string relative, int size)
    {
        var path = Path.Combine(SourceDir, relative);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, RandomNumberGenerator.GetBytes(size));
        return path;
    }

    private static Task<ReceiveSession> NextSessionEnd(SlipServer server)
    {
        var tcs = new TaskCompletionSource<ReceiveSession>(TaskCreationOptions.RunContinuationsAsynchronously);
        server.SessionEnded += (_, s) => tcs.TrySetResult(s);
        return tcs.Task;
    }

    // ---------------------------------------------------------------------------------------------

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Transfer_FilesAndFolder_BytesMatch(bool https)
    {
        var (server, _) = await StartServerAsync(https);
        var ended = NextSessionEnd(server);
        var big = WriteSource("big.bin", 3 * 1024 * 1024 + 17);
        var small = WriteSource("small.txt", 10);
        WriteSource(Path.Combine("Album", "2024", "a.jpg"), 2000);
        WriteSource(Path.Combine("Album", "b.jpg"), 3000);
        var mtime = new DateTime(2023, 5, 6, 7, 8, 9, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(small, mtime);

        var items = SendItem.FromPaths([big, small, Path.Combine(SourceDir, "Album")]);
        var session = NewSender(sha: true).CreateSession(Endpoint(server), items);
        var state = await session.RunAsync().WaitAsync(TimeSpan.FromSeconds(30));

        Assert.Equal(SendState.Completed, state);
        Assert.All(session.Files, f => Assert.Equal(SendFileState.Done, f.State));
        Assert.Equal(session.TotalBytes, session.BytesSent);

        var received = await ended.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(ReceiveState.Completed, received.State);
        Assert.Equal(SenderInfo.Alias, received.Sender.Alias);

        Assert.Equal(File.ReadAllBytes(big), File.ReadAllBytes(Path.Combine(SaveDir, "big.bin")));
        Assert.Equal(File.ReadAllBytes(small), File.ReadAllBytes(Path.Combine(SaveDir, "small.txt")));
        Assert.Equal(File.ReadAllBytes(Path.Combine(SourceDir, "Album", "2024", "a.jpg")),
            File.ReadAllBytes(Path.Combine(SaveDir, "Album", "2024", "a.jpg")));
        Assert.True(File.Exists(Path.Combine(SaveDir, "Album", "b.jpg")));
        Assert.Equal(mtime, File.GetLastWriteTimeUtc(Path.Combine(SaveDir, "small.txt")), TimeSpan.FromSeconds(2));
        Assert.Empty(Directory.GetFiles(SaveDir, ".slip-partial-*", SearchOption.AllDirectories));

        // Sending the same file again must not overwrite: "big (1).bin".
        var again = NewSender().CreateSession(Endpoint(server), [SendItem.FromFile(big)]);
        Assert.Equal(SendState.Completed, await again.RunAsync().WaitAsync(TimeSpan.FromSeconds(30)));
        Assert.True(File.Exists(Path.Combine(SaveDir, "big (1).bin")));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Pin_Returns401_ThenRetryWithPinSucceeds(bool https)
    {
        var (server, _) = await StartServerAsync(https, s => s.Pin = "4321");
        var file = WriteSource("p.bin", 1000);

        // No PIN provider -> 401 surfaces as PinRequired.
        var noPin = NewSender().CreateSession(Endpoint(server), [SendItem.FromFile(file)]);
        Assert.Equal(SendState.PinRequired, await noPin.RunAsync());

        // Raw check of the status code.
        using var http = SlipHttp.CreateTransferClient();
        var body = SlipHttp.JsonContent(new PrepareUploadRequest
        {
            Info = SenderInfo,
            Files = { ["x"] = new FileDto { Id = "x", FileName = "x.bin", Size = 1 } },
        });
        using (var r = await http.PostAsync(Endpoint(server).Url("prepare-upload", "pin=0000"), body))
            Assert.Equal(HttpStatusCode.Unauthorized, r.StatusCode);

        // Wrong PIN first, then the right one.
        var attempts = new List<int>();
        var session = NewSender().CreateSession(Endpoint(server), [SendItem.FromFile(file)]);
        var state = await session.RunAsync((attempt, _) =>
        {
            attempts.Add(attempt);
            return Task.FromResult<string?>(attempt == 1 ? "0000" : "4321");
        });
        Assert.Equal(SendState.Completed, state);
        Assert.Equal([1, 2], attempts);
        Assert.Equal(File.ReadAllBytes(file), File.ReadAllBytes(Path.Combine(SaveDir, "p.bin")));
    }

    [Fact]
    public async Task Decline_Returns403()
    {
        IncomingTransferRequest? seen = null;
        var (server, _) = await StartServerAsync(true, s =>
        {
            s.AutoAccept = false;
            s.DecisionHandler = (req, _) => { seen = req; return Task.FromResult(TransferDecision.Decline); };
        });
        var ended = NextSessionEnd(server);
        var session = NewSender().CreateSession(Endpoint(server), [SendItem.FromFile(WriteSource("d.bin", 10))]);
        Assert.Equal(SendState.Declined, await session.RunAsync());
        Assert.NotNull(seen);
        Assert.Equal("d.bin", Assert.Single(seen.Files).FileName);
        Assert.Equal("127.0.0.1", seen.SenderAddress);
        Assert.Equal(ReceiveState.Declined, (await ended.WaitAsync(TimeSpan.FromSeconds(5))).State);
        Assert.False(File.Exists(Path.Combine(SaveDir, "d.bin")));
    }

    [Fact]
    public async Task DecisionTimeout_Returns403()
    {
        var (server, _) = await StartServerAsync(false, s =>
        {
            s.AutoAccept = false;
            s.DecisionTimeout = TimeSpan.FromMilliseconds(300);
            s.DecisionHandler = (_, ct) => Task.Delay(Timeout.Infinite, ct).ContinueWith(_ => TransferDecision.AcceptAll);
        });
        var session = NewSender().CreateSession(Endpoint(server), [SendItem.FromFile(WriteSource("t.bin", 10))]);
        Assert.Equal(SendState.Declined, await session.RunAsync().WaitAsync(TimeSpan.FromSeconds(10)));
    }

    [Fact]
    public async Task SecondTransferWhileWaiting_Returns409()
    {
        var release = new TaskCompletionSource<TransferDecision>(TaskCreationOptions.RunContinuationsAsynchronously);
        var asked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var (server, _) = await StartServerAsync(true, s =>
        {
            s.AutoAccept = false;
            s.DecisionHandler = (_, _) => { asked.TrySetResult(); return release.Task; };
        });
        var file = WriteSource("busy.bin", 50_000);

        var first = NewSender().CreateSession(Endpoint(server), [SendItem.FromFile(file)]);
        var firstRun = first.RunAsync();
        await asked.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(ReceiveState.WaitingForDecision, server.CurrentSession?.State);

        var second = NewSender().CreateSession(Endpoint(server), [SendItem.FromFile(file)]);
        Assert.Equal(SendState.Busy, await second.RunAsync());

        release.SetResult(TransferDecision.AcceptAll);
        Assert.Equal(SendState.Completed, await firstRun.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(File.ReadAllBytes(file), File.ReadAllBytes(Path.Combine(SaveDir, "busy.bin")));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task TextMessage_Returns204(bool https)
    {
        var (server, _) = await StartServerAsync(https, s => s.AutoAccept = false);
        var got = new TaskCompletionSource<TextMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        server.MessageReceived += (_, m) => got.TrySetResult(m);

        var session = NewSender().CreateSession(Endpoint(server), [SendItem.FromText("Hello from Slip ✓")]);
        Assert.True(session.IsTextMessage);
        Assert.Equal(SendState.Completed, await session.RunAsync());

        var message = await got.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("Hello from Slip ✓", message.Text);
        Assert.Equal(SenderInfo.Alias, message.Sender.Alias);
        Assert.Null(server.CurrentSession);
        Assert.Empty(Directory.GetFiles(SaveDir));

        // Raw status code.
        using var http = SlipHttp.CreateTransferClient();
        var req = new PrepareUploadRequest
        {
            Info = SenderInfo,
            Files = { ["m"] = new FileDto { Id = "m", FileName = "m.txt", FileType = "text/plain", Size = 2, Preview = "hi" } },
        };
        using var r = await http.PostAsync(Endpoint(server).Url("prepare-upload"), SlipHttp.JsonContent(req));
        Assert.Equal(HttpStatusCode.NoContent, r.StatusCode);
    }

    [Fact]
    public async Task PartialAccept_SkipsDeselectedFiles()
    {
        var (server, _) = await StartServerAsync(true, s =>
        {
            s.AutoAccept = false;
            s.DecisionHandler = (req, _) =>
                Task.FromResult(TransferDecision.AcceptOnly(req.Files.Where(f => f.FileName == "keep.bin").Select(f => f.Id)));
        });
        var session = NewSender().CreateSession(Endpoint(server),
            [SendItem.FromFile(WriteSource("keep.bin", 100)), SendItem.FromFile(WriteSource("drop.bin", 100))]);
        Assert.Equal(SendState.Completed, await session.RunAsync());
        Assert.Equal(SendFileState.Skipped, session.Files.Single(f => f.FileName == "drop.bin").State);
        Assert.True(File.Exists(Path.Combine(SaveDir, "keep.bin")));
        Assert.False(File.Exists(Path.Combine(SaveDir, "drop.bin")));
    }

    [Fact]
    public async Task RawProtocol_ValidationChecksumAndCancel()
    {
        var (server, _) = await StartServerAsync(false);
        var ep = Endpoint(server);
        using var http = SlipHttp.CreateTransferClient();
        var data = Encoding.UTF8.GetBytes("payload bytes");

        // Malformed body -> 400; v1 routes -> 404.
        using (var r = await http.PostAsync(ep.Url("prepare-upload"), new StringContent("{nope")))
            Assert.Equal(HttpStatusCode.BadRequest, r.StatusCode);
        using (var r = await http.PostAsync(new Uri($"http://127.0.0.1:{server.Port}/api/localsend/v1/send-request"), new StringContent("{}")))
            Assert.Equal(HttpStatusCode.NotFound, r.StatusCode);

        var req = new PrepareUploadRequest
        {
            Info = SenderInfo,
            Files =
            {
                ["good"] = new FileDto { Id = "good", FileName = "good.txt", Size = data.Length, Sha256 = Convert.ToHexStringLower(SHA256.HashData(data)) },
                ["bad"] = new FileDto { Id = "bad", FileName = "bad.txt", Size = data.Length, Sha256 = new string('0', 64) },
                ["later"] = new FileDto { Id = "later", FileName = "later.txt", Size = data.Length },
            },
        };
        PrepareUploadResponse resp;
        using (var r = await http.PostAsync(ep.Url("prepare-upload"), SlipHttp.JsonContent(req)))
        {
            Assert.Equal(HttpStatusCode.OK, r.StatusCode);
            resp = SlipJson.Deserialize<PrepareUploadResponse>(await r.Content.ReadAsStringAsync())!;
        }
        Assert.Equal(3, resp.Files.Count);

        // While this session is active, another prepare-upload is 409.
        using (var r = await http.PostAsync(ep.Url("prepare-upload"), SlipHttp.JsonContent(req)))
            Assert.Equal(HttpStatusCode.Conflict, r.StatusCode);

        async Task<HttpStatusCode> Upload(string? query)
        {
            using var r = await http.PostAsync(ep.Url("upload", query), new ByteArrayContent(data));
            return r.StatusCode;
        }

        Assert.Equal(HttpStatusCode.BadRequest, await Upload($"sessionId={resp.SessionId}&fileId=good"));
        Assert.Equal(HttpStatusCode.Forbidden, await Upload($"sessionId={resp.SessionId}&fileId=good&token=wrong"));
        Assert.Equal(HttpStatusCode.Forbidden, await Upload($"sessionId=other&fileId=good&token={resp.Files["good"]}"));
        Assert.Equal(HttpStatusCode.OK, await Upload($"sessionId={resp.SessionId}&fileId=good&token={resp.Files["good"]}"));
        Assert.Equal(HttpStatusCode.Conflict, await Upload($"sessionId={resp.SessionId}&fileId=good&token={resp.Files["good"]}"));
        Assert.Equal((HttpStatusCode)422, await Upload($"sessionId={resp.SessionId}&fileId=bad&token={resp.Files["bad"]}"));

        Assert.Equal(data, File.ReadAllBytes(Path.Combine(SaveDir, "good.txt")));
        Assert.False(File.Exists(Path.Combine(SaveDir, "bad.txt")));
        Assert.Empty(Directory.GetFiles(SaveDir, ".slip-partial-*"));

        // Cancel ends the session; further uploads are rejected and a new session can start.
        var ended = NextSessionEnd(server);
        using (var r = await http.PostAsync(ep.Url("cancel", $"sessionId={resp.SessionId}"), null))
            Assert.Equal(HttpStatusCode.OK, r.StatusCode);
        Assert.Equal(ReceiveState.Cancelled, (await ended.WaitAsync(TimeSpan.FromSeconds(5))).State);
        Assert.Equal(HttpStatusCode.Forbidden, await Upload($"sessionId={resp.SessionId}&fileId=later&token={resp.Files["later"]}"));
        Assert.Null(server.CurrentSession);
        using (var r = await http.PostAsync(ep.Url("prepare-upload"), SlipHttp.JsonContent(req)))
            Assert.Equal(HttpStatusCode.OK, r.StatusCode);
    }

    [Fact]
    public async Task SenderCancel_RemovesPartialAndEndsSession()
    {
        var (server, _) = await StartServerAsync(true);
        var ended = NextSessionEnd(server);
        var big = WriteSource("huge.bin", 64 * 1024 * 1024);
        var session = NewSender().CreateSession(Endpoint(server), [SendItem.FromFile(big)]);
        var run = session.RunAsync();
        while (session.BytesSent < 1024 * 1024 && !session.IsFinished) await Task.Delay(5);
        await session.CancelAsync();
        Assert.Equal(SendState.Cancelled, await run.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(ReceiveState.Cancelled, (await ended.WaitAsync(TimeSpan.FromSeconds(10))).State);
        // The upload task deletes its partial once it observes the cancellation.
        for (var i = 0; i < 100 && Directory.GetFiles(SaveDir, ".slip-partial-*").Length > 0; i++) await Task.Delay(50);
        Assert.Empty(Directory.GetFiles(SaveDir, ".slip-partial-*"));
        Assert.False(File.Exists(Path.Combine(SaveDir, "huge.bin")));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task InfoAndRegister(bool https)
    {
        var (server, registry) = await StartServerAsync(https);
        using var http = SlipHttp.CreateDiscoveryClient();
        var info = await SlipHttp.InfoAsync(http, Endpoint(server));
        Assert.NotNull(info);
        Assert.Equal("Test Receiver", info.Alias);
        Assert.Equal(server.Port, info.Port);
        if (https) Assert.Equal(ServerIdentity.Value.CertificateFingerprint, info.Fingerprint);

        var registered = await SlipHttp.RegisterAsync(http, Endpoint(server), SenderInfo);
        Assert.Equal("Test Receiver", registered?.Alias);
        var peer = Assert.Single(registry.Snapshot());
        Assert.Equal("sender-fingerprint", peer.Fingerprint);
        Assert.Equal("127.0.0.1", peer.Address);
        Assert.Equal(PeerSource.Register, peer.Source);

        // Our own fingerprint is ignored.
        await SlipHttp.RegisterAsync(http, Endpoint(server), SenderInfo with { Fingerprint = ServerIdentity.Value.CertificateFingerprint });
        Assert.Single(registry.Snapshot());
    }

    private sealed class AsyncDisposableAdapter(IDisposable inner) : IAsyncDisposable
    {
        public ValueTask DisposeAsync()
        {
            inner.Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
