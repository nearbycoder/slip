using System.Buffers;
using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Slip.Core.Discovery;
using Slip.Core.Protocol;
using Slip.Core.Util;

namespace Slip.Core.Server;

public sealed class ServerOptions
{
    /// <summary>TCP port; 0 picks a free port (see <see cref="SlipServer.Port"/>).</summary>
    public int Port { get; init; } = SlipConstants.DefaultPort;
    public bool Https { get; init; } = true;
    public IPAddress BindAddress { get; init; } = IPAddress.Any;
}

/// <summary>
/// LocalSend v2 receive server: info, register, prepare-upload, upload, cancel.
/// One session at a time; uploads are streamed to disk.
/// </summary>
public sealed class SlipServer : Observable, IAsyncDisposable
{
    private readonly ServerOptions _options;
    private readonly X509Certificate2? _certificate;
    private readonly Func<DeviceInfo> _localInfo;
    private readonly Func<string?, bool> _isSelf;
    private readonly PeerRegistry? _registry;
    private readonly object _gate = new();

    private WebApplication? _app;
    private ReceiveSession? _current;
    private CancellationTokenSource? _lifetime;
    private Task? _watchdog;

    public SlipServer(ServerOptions options, X509Certificate2? certificate, Func<DeviceInfo> localInfo,
        Func<string?, bool>? isSelf = null, PeerRegistry? registry = null)
    {
        if (options.Https && certificate is null) throw new ArgumentException("HTTPS requires a certificate", nameof(certificate));
        _options = options;
        _certificate = certificate;
        _localInfo = localInfo;
        _isSelf = isSelf ?? (_ => false);
        _registry = registry;
    }

    // ---- runtime-adjustable behaviour ----

    public string SaveDirectory { get; set; } = AppPaths.DefaultDownloadsDirectory;
    /// <summary>When set, prepare-upload requires <c>?pin=</c> to match.</summary>
    public string? Pin { get; set; }
    /// <summary>Quick Save: accept every transfer without asking.</summary>
    public bool AutoAccept { get; set; }
    public TimeSpan DecisionTimeout { get; set; } = SlipConstants.DecisionTimeout;
    /// <summary>A receiving session with no upload activity for this long is ended.</summary>
    public TimeSpan IdleTimeout { get; set; } = TimeSpan.FromMinutes(2);
    public IncomingTransferHandler? DecisionHandler { get; set; }

    // ---- observable state ----

    public int Port { get; private set; }
    public bool Https => _options.Https;
    public bool IsRunning => _app is not null;
    public ReceiveSession? CurrentSession => _current;

    public event EventHandler<ReceiveSession>? SessionStarted;
    public event EventHandler<ReceiveSession>? SessionEnded;
    public event EventHandler<ReceiveFile>? FileReceived;
    public event EventHandler<TextMessage>? MessageReceived;

    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_app is not null) return;

        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions
        {
            ApplicationName = "Slip",
            ContentRootPath = AppContext.BaseDirectory,
            Args = [],
        });
        builder.Logging.ClearProviders();
        builder.Logging.SetMinimumLevel(Microsoft.Extensions.Logging.LogLevel.Critical);
        builder.WebHost.UseKestrelHttpsConfiguration();
        builder.WebHost.ConfigureKestrel(k =>
        {
            k.AddServerHeader = false;
            k.Limits.MaxRequestBodySize = null;   // uploads can be any size
            k.Limits.MinRequestBodyDataRate = null;
            k.Limits.MinResponseDataRate = null;
            k.Limits.KeepAliveTimeout = TimeSpan.FromMinutes(2);
            k.Listen(_options.BindAddress, _options.Port, listen =>
            {
                listen.Protocols = HttpProtocols.Http1;
                if (_options.Https) listen.UseHttps(_certificate!);
            });
        });

        var app = builder.Build();
        MapRoutes(app);
        await app.StartAsync(ct).ConfigureAwait(false);

        var addresses = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()?.Addresses;
        var first = addresses?.FirstOrDefault();
        Port = first is not null && Uri.TryCreate(first.Replace("0.0.0.0", "localhost").Replace("[::]", "localhost"), UriKind.Absolute, out var uri)
            ? uri.Port
            : _options.Port;

        _app = app;
        _lifetime = new CancellationTokenSource();
        _watchdog = Task.Run(() => WatchdogAsync(_lifetime.Token));
        OnPropertyChanged(nameof(IsRunning));
        OnPropertyChanged(nameof(Port));
        SlipLog.Info($"Server listening on {(_options.Https ? "https" : "http")}://{_options.BindAddress}:{Port}");
    }

    public async Task StopAsync()
    {
        var app = _app;
        if (app is null) return;
        _app = null;
        _lifetime?.Cancel();
        CancelCurrentSession();
        try
        {
            using var stopTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            await app.StopAsync(stopTimeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
        await app.DisposeAsync().ConfigureAwait(false);
        if (_watchdog is not null) await _watchdog.ConfigureAwait(false);
        _lifetime?.Dispose();
        _lifetime = null;
        OnPropertyChanged(nameof(IsRunning));
    }

    public ValueTask DisposeAsync() => new(StopAsync());

    /// <summary>Receiver-side cancel of the active session (e.g. user pressed Cancel).</summary>
    public void CancelCurrentSession()
    {
        ReceiveSession? session;
        lock (_gate) session = _current;
        if (session is not null) EndSession(session, ReceiveState.Cancelled);
    }

    // ---------------------------------------------------------------------------------------------

    private void MapRoutes(WebApplication app)
    {
        var api = app.MapGroup(SlipConstants.ApiPrefix);
        api.MapGet("/info", (HttpContext ctx) => WriteJson(ctx, _localInfo()));
        api.MapPost("/register", HandleRegisterAsync);
        api.MapPost("/prepare-upload", HandlePrepareUploadAsync);
        api.MapPost("/upload", HandleUploadAsync);
        api.MapPost("/cancel", HandleCancel);
    }

    private static Task WriteJson<T>(HttpContext ctx, T value, int status = StatusCodes.Status200OK)
    {
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json; charset=utf-8";
        return ctx.Response.Body.WriteAsync(SlipJson.SerializeToUtf8(value)).AsTask();
    }

    private static string RemoteIp(HttpContext ctx) =>
        ctx.Connection.RemoteIpAddress is { } ip ? NetUtil.Normalize(ip).ToString() : "";

    private static async Task<string?> ReadBodyAsync(HttpContext ctx, int limit = 16 * 1024 * 1024)
    {
        using var ms = new MemoryStream();
        var buffer = new byte[16 * 1024];
        int n;
        while ((n = await ctx.Request.Body.ReadAsync(buffer, ctx.RequestAborted).ConfigureAwait(false)) > 0)
        {
            if (ms.Length + n > limit) return null;
            ms.Write(buffer, 0, n);
        }
        return System.Text.Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
    }

    private async Task HandleRegisterAsync(HttpContext ctx)
    {
        var body = await ReadBodyAsync(ctx, 64 * 1024).ConfigureAwait(false);
        var info = body is null ? null : SlipJson.TryParseDeviceInfo(body);
        if (info is null)
        {
            ctx.Response.StatusCode = StatusCodes.Status400BadRequest;
            return;
        }
        if (!_isSelf(info.Fingerprint) && !string.IsNullOrEmpty(info.Fingerprint))
            _registry?.Upsert(info, RemoteIp(ctx), PeerSource.Register);
        await WriteJson(ctx, _localInfo()).ConfigureAwait(false);
    }

    private async Task HandlePrepareUploadAsync(HttpContext ctx)
    {
        var pin = Pin;
        if (!string.IsNullOrEmpty(pin) && !string.Equals(ctx.Request.Query["pin"].ToString(), pin, StringComparison.Ordinal))
        {
            ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }

        PrepareUploadRequest? request;
        try
        {
            var body = await ReadBodyAsync(ctx).ConfigureAwait(false);
            request = body is null ? null : SlipJson.Deserialize<PrepareUploadRequest>(body);
        }
        catch (JsonException)
        {
            request = null;
        }
        if (request?.Files is null || request.Info is null || request.Files.Count == 0)
        {
            ctx.Response.StatusCode = StatusCodes.Status400BadRequest;
            return;
        }

        var ip = RemoteIp(ctx);
        // Ids come from the dictionary keys (the authoritative ones the sender will use for upload).
        var files = request.Files.Select(kv => kv.Value with { Id = kv.Key }).ToList();

        ReceiveSession session;
        lock (_gate)
        {
            if (_current is { IsFinished: false })
            {
                ctx.Response.StatusCode = StatusCodes.Status409Conflict;
                return;
            }
            if (request.IsTextMessage)
            {
                session = null!;
            }
            else
            {
                session = new ReceiveSession(Guid.NewGuid().ToString(), request.Info, ip, files, SaveDirectory);
                _current = session;
            }
        }

        if (request.IsTextMessage)
        {
            var text = string.Join("\n", files.Select(f => f.Preview));
            if (!_isSelf(request.Info.Fingerprint)) _registry?.Upsert(request.Info, ip, PeerSource.Register);
            MessageReceived?.Invoke(this, new TextMessage(request.Info, ip, text, DateTimeOffset.Now));
            ctx.Response.StatusCode = StatusCodes.Status204NoContent;
            return;
        }

        OnPropertyChanged(nameof(CurrentSession));
        var decision = await DecideAsync(session, ctx.RequestAborted).ConfigureAwait(false);

        if (ctx.RequestAborted.IsCancellationRequested || session.Cancellation.IsCancellationRequested)
        {
            EndSession(session, ReceiveState.Cancelled);
            if (!ctx.RequestAborted.IsCancellationRequested) ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
            return;
        }

        var acceptedIds = decision.Accepted
            ? files.Where(f => decision.FileIds is null || decision.FileIds.Contains(f.Id)).Select(f => f.Id).ToHashSet()
            : [];
        if (acceptedIds.Count == 0)
        {
            EndSession(session, ReceiveState.Declined);
            ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
            return;
        }

        var accepted = files.Where(f => acceptedIds.Contains(f.Id))
            .Select(f => new ReceiveFile(f, Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)), ReceiveFileState.Pending))
            .ToList();
        session.SetAccepted(accepted);
        session.Touch();
        session.State = ReceiveState.Receiving;
        SessionStarted?.Invoke(this, session);

        await WriteJson(ctx, new PrepareUploadResponse
        {
            SessionId = session.Id,
            Files = accepted.ToDictionary(f => f.Id, f => f.Token!),
        }).ConfigureAwait(false);
    }

    private async Task<TransferDecision> DecideAsync(ReceiveSession session, CancellationToken requestAborted)
    {
        if (AutoAccept) return TransferDecision.AcceptAll;
        var handler = DecisionHandler;
        if (handler is null) return TransferDecision.Decline;

        using var timeout = new CancellationTokenSource(DecisionTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token, requestAborted, session.Cancellation.Token);
        var request = new IncomingTransferRequest
        {
            SessionId = session.Id,
            Sender = session.Sender,
            SenderAddress = session.SenderAddress,
            Files = session.Requested,
        };
        try
        {
            return await handler(request, linked.Token).WaitAsync(linked.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            SlipLog.Info(timeout.IsCancellationRequested ? "Incoming transfer timed out" : "Incoming transfer cancelled by sender");
            return TransferDecision.Decline;
        }
        catch (Exception e)
        {
            SlipLog.Warn($"Decision handler failed: {e.Message}");
            return TransferDecision.Decline;
        }
    }

    private async Task HandleUploadAsync(HttpContext ctx)
    {
        var q = ctx.Request.Query;
        string sessionId = q["sessionId"].ToString(), fileId = q["fileId"].ToString(), token = q["token"].ToString();
        if (sessionId.Length == 0 || fileId.Length == 0 || token.Length == 0)
        {
            ctx.Response.StatusCode = StatusCodes.Status400BadRequest;
            return;
        }

        var ip = RemoteIp(ctx);
        ReceiveSession? session;
        ReceiveFile? file;
        lock (_gate)
        {
            session = _current;
            if (session is null || session.Id != sessionId || session.State != ReceiveState.Receiving ||
                session.SenderAddress != ip ||
                !session.FileMap.TryGetValue(fileId, out file) || file.Token != token)
            {
                ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
                return;
            }
            if (file.State != ReceiveFileState.Pending)
            {
                ctx.Response.StatusCode = StatusCodes.Status409Conflict;
                return;
            }
            file.State = ReceiveFileState.Receiving;
            session.ActiveUploads++;
        }

        try
        {
            ctx.Response.StatusCode = await ReceiveFileAsync(ctx, session, file).ConfigureAwait(false);
        }
        finally
        {
            bool done;
            lock (_gate)
            {
                session.ActiveUploads--;
                session.Touch();
                done = session.State == ReceiveState.Receiving && session.ActiveUploads == 0 &&
                       session.Files.All(f => f.State is ReceiveFileState.Done or ReceiveFileState.Failed or ReceiveFileState.Skipped);
            }
            if (done)
                EndSession(session, session.Files.Any(f => f.State == ReceiveFileState.Done) ? ReceiveState.Completed : ReceiveState.Failed);
        }
    }

    private async Task<int> ReceiveFileAsync(HttpContext ctx, ReceiveSession session, ReceiveFile file)
    {
        string target, partial;
        try
        {
            target = PathSanitizer.ResolveUnder(session.SaveDirectory, file.FileName);
            var dir = Path.GetDirectoryName(target)!;
            Directory.CreateDirectory(dir);
            partial = Path.Combine(dir, $".slip-partial-{Guid.NewGuid():N}");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException or NotSupportedException)
        {
            file.Error = e.Message;
            file.State = ReceiveFileState.Failed;
            return StatusCodes.Status500InternalServerError;
        }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ctx.RequestAborted, session.Cancellation.Token);
        var ct = linked.Token;
        var buffer = ArrayPool<byte>.Shared.Rent(128 * 1024);
        using var hash = file.Dto.Sha256 is not null ? IncrementalHash.CreateHash(HashAlgorithmName.SHA256) : null;
        try
        {
            await using (var fs = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.Asynchronous))
            {
                int n;
                while ((n = await ctx.Request.Body.ReadAsync(buffer.AsMemory(), ct).ConfigureAwait(false)) > 0)
                {
                    await fs.WriteAsync(buffer.AsMemory(0, n), ct).ConfigureAwait(false);
                    hash?.AppendData(buffer, 0, n);
                    file.AddBytes(n);
                    session.Touch();
                }
            }
            file.AddBytes(0, force: true);

            if (hash is not null)
            {
                var actual = Convert.ToHexStringLower(hash.GetHashAndReset());
                if (!string.Equals(actual, file.Dto.Sha256!.Trim(), StringComparison.OrdinalIgnoreCase))
                {
                    TryDelete(partial);
                    file.Error = "Checksum mismatch";
                    file.State = ReceiveFileState.Failed;
                    return StatusCodes.Status422UnprocessableEntity;
                }
            }

            var final = MoveIntoPlace(partial, target);
            ApplyTimestamps(final, file.Dto.Metadata);
            file.SavedPath = final;
            file.State = ReceiveFileState.Done;
            SlipLog.Info($"Received {Path.GetFileName(final)} ({file.BytesReceived} bytes)");
            FileReceived?.Invoke(this, file);
            return StatusCodes.Status200OK;
        }
        catch (Exception e) when (e is OperationCanceledException or IOException or Microsoft.AspNetCore.Http.BadHttpRequestException or UnauthorizedAccessException)
        {
            TryDelete(partial);
            file.Error = session.Cancellation.IsCancellationRequested ? "Cancelled" : e.Message;
            file.State = ReceiveFileState.Failed;
            return session.Cancellation.IsCancellationRequested ? StatusCodes.Status409Conflict : StatusCodes.Status500InternalServerError;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    private static string MoveIntoPlace(string partial, string target)
    {
        for (var attempt = 0; ; attempt++)
        {
            var dest = PathSanitizer.MakeUnique(target);
            try
            {
                File.Move(partial, dest, overwrite: false);
                return dest;
            }
            catch (IOException) when (attempt < 100 && (File.Exists(dest) || Directory.Exists(dest)))
            {
                // lost a race with a parallel upload of the same name: try the next suffix
            }
        }
    }

    private static void ApplyTimestamps(string path, FileMetadata? metadata)
    {
        try
        {
            if (metadata?.Modified is { } m) File.SetLastWriteTimeUtc(path, m.UtcDateTime);
            if (metadata?.Accessed is { } a) File.SetLastAccessTimeUtc(path, a.UtcDateTime);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentOutOfRangeException) { }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private IResult HandleCancel(HttpContext ctx)
    {
        var sessionId = ctx.Request.Query["sessionId"].ToString();
        var ip = RemoteIp(ctx);
        ReceiveSession? session;
        lock (_gate)
        {
            session = _current;
            // Older senders call cancel without a session id; accept it from the session's sender.
            if (session is null || (sessionId.Length > 0 ? session.Id != sessionId : session.SenderAddress != ip))
                session = null;
        }
        if (session is not null) EndSession(session, ReceiveState.Cancelled);
        return Results.Ok();
    }

    private void EndSession(ReceiveSession session, ReceiveState state)
    {
        lock (_gate)
        {
            if (session.IsFinished) return;
            session.State = state;
            session.FinishedAt = DateTimeOffset.Now;
            if (ReferenceEquals(_current, session)) _current = null;
            foreach (var f in session.Files)
            {
                if (f.State is ReceiveFileState.Pending) f.State = ReceiveFileState.Skipped;
            }
        }
        if (state is ReceiveState.Cancelled or ReceiveState.Failed)
        {
            try { session.Cancellation.Cancel(); } catch (ObjectDisposedException) { }
        }
        OnPropertyChanged(nameof(CurrentSession));
        SlipLog.Info($"Session {session.Id[..8]} from {session.Sender.Alias} ended: {state}");
        SessionEnded?.Invoke(this, session);
    }

    private async Task WatchdogAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(5));
        try
        {
            while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            {
                ReceiveSession? stale = null;
                lock (_gate)
                {
                    if (_current is { State: ReceiveState.Receiving, ActiveUploads: 0 } s &&
                        Environment.TickCount64 - Interlocked.Read(ref s.LastActivityTicks) > IdleTimeout.TotalMilliseconds)
                        stale = s;
                }
                if (stale is not null) EndSession(stale, ReceiveState.Failed);
            }
        }
        catch (OperationCanceledException) { }
    }
}
