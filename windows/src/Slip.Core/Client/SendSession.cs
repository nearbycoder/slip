using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using Slip.Core.Protocol;
using Slip.Core.Util;

namespace Slip.Core.Client;

public enum SendState
{
    Preparing,
    WaitingForAcceptance,
    Sending,
    Completed,
    Declined,
    Busy,
    TooManyRequests,
    PinRequired,
    Cancelled,
    Failed,
}

public enum SendFileState
{
    Pending,
    Sending,
    Done,
    Failed,
    Skipped,
}

/// <summary>Something to send: a file on disk (possibly inside a picked folder) or an in-memory text message.</summary>
public sealed class SendItem
{
    /// <summary>Name sent to the receiver; may contain '/' for folder sends (<c>Photos/2024/a.jpg</c>).</summary>
    public required string FileName { get; init; }
    public required long Size { get; init; }
    public string FileType { get; init; } = "application/octet-stream";
    public string? LocalPath { get; init; }
    public byte[]? Content { get; init; }
    public string? Preview { get; init; }
    public DateTimeOffset? Modified { get; init; }
    public DateTimeOffset? Accessed { get; init; }

    public bool IsText => Content is not null && Preview is not null;

    public static SendItem FromFile(string path, string? fileName = null)
    {
        var fi = new FileInfo(path);
        if (!fi.Exists) throw new FileNotFoundException("File not found", path);
        return new SendItem
        {
            FileName = fileName ?? fi.Name,
            Size = fi.Length,
            FileType = MimeTypes.FromFileName(fi.Name),
            LocalPath = fi.FullName,
            Modified = new DateTimeOffset(fi.LastWriteTimeUtc, TimeSpan.Zero),
            Accessed = new DateTimeOffset(fi.LastAccessTimeUtc, TimeSpan.Zero),
        };
    }

    /// <summary>Every file below <paramref name="directory"/>, named <c>FolderName/relative/path</c>.</summary>
    public static IEnumerable<SendItem> FromDirectory(string directory)
    {
        var root = new DirectoryInfo(directory);
        var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.System };
        foreach (var file in root.EnumerateFiles("*", options))
        {
            var relative = Path.GetRelativePath(root.FullName, file.FullName).Replace(Path.DirectorySeparatorChar, '/');
            yield return FromFile(file.FullName, $"{root.Name}/{relative}");
        }
    }

    /// <summary>Expands a mix of file and folder paths.</summary>
    public static List<SendItem> FromPaths(IEnumerable<string> paths)
    {
        var items = new List<SendItem>();
        foreach (var p in paths)
        {
            if (Directory.Exists(p)) items.AddRange(FromDirectory(p));
            else items.Add(FromFile(p));
        }
        return items;
    }

    public static SendItem FromText(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        return new SendItem
        {
            FileName = $"{Guid.NewGuid()}.txt",
            Size = bytes.Length,
            FileType = "text/plain",
            Content = bytes,
            Preview = text,
        };
    }

    internal Stream OpenRead() =>
        Content is not null
            ? new MemoryStream(Content, writable: false)
            : new FileStream(LocalPath!, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.Asynchronous | FileOptions.SequentialScan);
}

public sealed class SendFile : Observable
{
    private long _bytes;
    private long _lastNotify;
    private SendFileState _state;
    private string? _error;

    internal SendFile(string id, SendItem item)
    {
        Id = id;
        Item = item;
    }

    public string Id { get; }
    public SendItem Item { get; }
    public string FileName => Item.FileName;
    public long Size => Item.Size;
    public long BytesSent => Interlocked.Read(ref _bytes);
    public double Progress => Size <= 0 ? (State == SendFileState.Done ? 1 : 0) : Math.Clamp((double)BytesSent / Size, 0, 1);
    public SendFileState State { get => _state; internal set { if (Set(ref _state, value)) OnPropertyChanged(nameof(Progress)); } }
    public string? Error { get => _error; internal set => Set(ref _error, value); }

    internal event Action? ProgressChanged;

    internal void AddBytes(long n, bool force = false)
    {
        Interlocked.Add(ref _bytes, n);
        var now = Environment.TickCount64;
        if (force || now - Interlocked.Read(ref _lastNotify) >= 100)
        {
            Interlocked.Exchange(ref _lastNotify, now);
            OnPropertyChanged(nameof(BytesSent));
            OnPropertyChanged(nameof(Progress));
            ProgressChanged?.Invoke();
        }
    }

    internal void Reset()
    {
        Interlocked.Exchange(ref _bytes, 0);
        AddBytes(0, force: true);
    }
}

/// <summary>Asks the user for the receiver's PIN. <paramref name="attempt"/> starts at 1 (2+ = previous PIN was wrong).
/// Return null to give up.</summary>
public delegate Task<string?> PinProvider(int attempt, CancellationToken cancellationToken);

/// <summary>One outgoing transfer. Create via <see cref="SlipSender.CreateSession"/>, then <see cref="RunAsync"/>.</summary>
public sealed class SendSession : Observable
{
    private readonly HttpClient _http;
    private readonly Func<DeviceInfo> _localInfo;
    private readonly bool _computeSha256;
    private readonly CancellationTokenSource _cts = new();
    private readonly long _startTicks = Environment.TickCount64;
    private SendState _state = SendState.Preparing;
    private string? _error;
    private string? _sessionId;
    private string? _pin;
    private volatile bool _cancelRequested;

    internal SendSession(HttpClient http, Func<DeviceInfo> localInfo, PeerEndpoint target, string? targetAlias,
        IReadOnlyList<SendItem> items, bool computeSha256, string? pin)
    {
        _http = http;
        _localInfo = localInfo;
        _computeSha256 = computeSha256;
        _pin = pin;
        Target = target;
        TargetAlias = targetAlias ?? target.ToString();
        Files = items.Select(i => new SendFile(Guid.NewGuid().ToString(), i)).ToList();
        foreach (var f in Files)
        {
            f.ProgressChanged += () =>
            {
                OnPropertyChanged(nameof(BytesSent));
                OnPropertyChanged(nameof(Progress));
                OnPropertyChanged(nameof(BytesPerSecond));
            };
        }
    }

    public PeerEndpoint Target { get; }
    public string TargetAlias { get; }
    public IReadOnlyList<SendFile> Files { get; }
    public DateTimeOffset StartedAt { get; } = DateTimeOffset.Now;
    public SendState State { get => _state; private set => Set(ref _state, value); }
    public string? ErrorMessage { get => _error; private set => Set(ref _error, value); }
    public string? SessionId { get => _sessionId; private set => Set(ref _sessionId, value); }
    public bool IsTextMessage => Files.Count == 1 && Files[0].Item.IsText;
    public bool IsFinished => State is SendState.Completed or SendState.Declined or SendState.Busy or SendState.TooManyRequests
        or SendState.PinRequired or SendState.Cancelled or SendState.Failed;
    public long TotalBytes => Files.Where(f => f.State != SendFileState.Skipped).Sum(f => f.Size);
    public long BytesSent => Files.Sum(f => f.BytesSent);
    public double Progress => TotalBytes <= 0 ? (State == SendState.Completed ? 1 : 0) : Math.Clamp((double)BytesSent / TotalBytes, 0, 1);

    public double BytesPerSecond
    {
        get
        {
            var seconds = (Environment.TickCount64 - _startTicks) / 1000.0;
            return seconds <= 0 ? 0 : BytesSent / seconds;
        }
    }

    /// <summary>Runs the transfer to completion. Never throws for protocol outcomes: inspect <see cref="State"/>.</summary>
    public async Task<SendState> RunAsync(PinProvider? pinProvider = null, CancellationToken cancellationToken = default)
    {
        using var reg = cancellationToken.Register(() => _ = CancelAsync());
        var ct = _cts.Token;
        try
        {
            var files = new Dictionary<string, FileDto>();
            foreach (var f in Files)
            {
                string? sha = null;
                if (_computeSha256 && !f.Item.IsText)
                {
                    await using var s = f.Item.OpenRead();
                    sha = Convert.ToHexStringLower(await SHA256.HashDataAsync(s, ct).ConfigureAwait(false));
                }
                files[f.Id] = new FileDto
                {
                    Id = f.Id,
                    FileName = f.Item.FileName,
                    Size = f.Item.Size,
                    FileType = f.Item.FileType,
                    Sha256 = sha,
                    Preview = f.Item.Preview,
                    Metadata = f.Item.Modified is null && f.Item.Accessed is null
                        ? null
                        : new FileMetadata { Modified = f.Item.Modified, Accessed = f.Item.Accessed },
                };
            }
            var request = new PrepareUploadRequest { Info = _localInfo(), Files = files };

            PrepareUploadResponse? accepted = null;
            for (var attempt = 1; ; attempt++)
            {
                State = SendState.WaitingForAcceptance;
                var query = _pin is null ? null : "pin=" + Uri.EscapeDataString(_pin);
                using var response = await _http.PostAsync(Target.Url("prepare-upload", query), SlipHttp.JsonContent(request), ct).ConfigureAwait(false);
                var status = (int)response.StatusCode;
                switch (status)
                {
                    case 200:
                        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
                        accepted = SlipJson.Deserialize<PrepareUploadResponse>(body);
                        if (accepted is null || string.IsNullOrEmpty(accepted.SessionId))
                            return Fail("Receiver sent an invalid response");
                        break;
                    case 204:
                        foreach (var f in Files) { f.AddBytes(f.Size - f.BytesSent, force: true); f.State = SendFileState.Done; }
                        State = SendState.Completed;
                        return State;
                    case 401:
                        var pin = pinProvider is null ? null : await pinProvider(attempt, ct).ConfigureAwait(false);
                        if (string.IsNullOrEmpty(pin))
                        {
                            ErrorMessage = attempt == 1 && _pin is null ? "PIN required" : "Invalid PIN";
                            State = SendState.PinRequired;
                            return State;
                        }
                        _pin = pin;
                        continue;
                    case 403:
                        ErrorMessage = "Declined by receiver";
                        State = SendState.Declined;
                        return State;
                    case 409:
                        ErrorMessage = "Receiver is busy";
                        State = SendState.Busy;
                        return State;
                    case 429:
                        ErrorMessage = "Too many requests";
                        State = SendState.TooManyRequests;
                        return State;
                    default:
                        return Fail($"Receiver error (HTTP {status})");
                }
                break;
            }

            SessionId = accepted.SessionId;
            State = SendState.Sending;
            foreach (var f in Files.Where(f => !accepted.Files.ContainsKey(f.Id))) f.State = SendFileState.Skipped;
            OnPropertyChanged(nameof(TotalBytes));

            using var gate = new SemaphoreSlim(SlipConstants.MaxParallelUploads);
            var uploads = Files.Where(f => accepted.Files.ContainsKey(f.Id)).Select(async f =>
            {
                await gate.WaitAsync(ct).ConfigureAwait(false);
                try { await UploadAsync(f, accepted.SessionId, accepted.Files[f.Id], ct).ConfigureAwait(false); }
                finally { gate.Release(); }
            }).ToList();
            try { await Task.WhenAll(uploads).ConfigureAwait(false); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { }

            if (_cancelRequested || ct.IsCancellationRequested) { State = SendState.Cancelled; return State; }
            var failed = Files.Count(f => f.State == SendFileState.Failed);
            if (failed > 0) return Fail(failed == 1 ? Files.First(f => f.State == SendFileState.Failed).Error ?? "Upload failed" : $"{failed} files failed");
            State = SendState.Completed;
            return State;
        }
        catch (Exception e) when (_cancelRequested && e is OperationCanceledException or HttpRequestException or IOException)
        {
            State = SendState.Cancelled;
            return State;
        }
        catch (Exception e) when (e is HttpRequestException or IOException or UnauthorizedAccessException or TaskCanceledException)
        {
            return Fail(e.InnerException?.Message ?? e.Message);
        }
    }

    private SendState Fail(string message)
    {
        ErrorMessage = message;
        State = SendState.Failed;
        return State;
    }

    private async Task UploadAsync(SendFile file, string sessionId, string token, CancellationToken ct)
    {
        file.State = SendFileState.Sending;
        try
        {
            var query = $"sessionId={Uri.EscapeDataString(sessionId)}&fileId={Uri.EscapeDataString(file.Id)}&token={Uri.EscapeDataString(token)}";
            using var content = new ProgressStreamContent(file);
            using var response = await _http.PostAsync(Target.Url("upload", query), content, ct).ConfigureAwait(false);
            if (response.IsSuccessStatusCode)
            {
                file.AddBytes(0, force: true);
                file.State = SendFileState.Done;
            }
            else
            {
                file.Error = (int)response.StatusCode switch
                {
                    422 => "Checksum mismatch",
                    403 => "Rejected by receiver",
                    409 => "Session no longer active",
                    var s => $"HTTP {s}",
                };
                file.State = SendFileState.Failed;
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            file.Error = "Cancelled";
            file.State = SendFileState.Failed;
            throw;
        }
        catch (Exception e) when (e is HttpRequestException or IOException or UnauthorizedAccessException)
        {
            file.Error = e.InnerException?.Message ?? e.Message;
            file.State = SendFileState.Failed;
        }
    }

    /// <summary>Cancels the transfer and tells the receiver (POST /cancel).</summary>
    public async Task CancelAsync()
    {
        if (IsFinished || _cancelRequested) return;
        _cancelRequested = true;
        var id = SessionId;
        if (id is not null)
        {
            // Tell the receiver first so it records a cancel (not a failed upload), then abort our requests.
            try
            {
                using var client = SlipHttp.CreateDiscoveryClient(TimeSpan.FromSeconds(2));
                using var _ = await client.PostAsync(Target.Url("cancel", "sessionId=" + Uri.EscapeDataString(id)), null).ConfigureAwait(false);
            }
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException) { }
        }
        try { _cts.Cancel(); } catch (ObjectDisposedException) { }
    }

    /// <summary>Streams a file from disk with byte progress.</summary>
    private sealed class ProgressStreamContent : HttpContent
    {
        private readonly SendFile _file;

        public ProgressStreamContent(SendFile file)
        {
            _file = file;
            Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
            Headers.ContentLength = file.Size;
        }

        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
            SerializeToStreamAsync(stream, context, CancellationToken.None);

        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken ct)
        {
            _file.Reset();
            await using var source = _file.Item.OpenRead();
            var buffer = new byte[128 * 1024];
            int n;
            while ((n = await source.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
            {
                await stream.WriteAsync(buffer.AsMemory(0, n), ct).ConfigureAwait(false);
                _file.AddBytes(n);
            }
        }

        protected override bool TryComputeLength(out long length)
        {
            length = _file.Size;
            return true;
        }
    }
}

/// <summary>Creates outgoing sessions using a shared HttpClient that accepts self-signed certificates.</summary>
public sealed class SlipSender : IDisposable
{
    private readonly HttpClient _http = SlipHttp.CreateTransferClient();
    private readonly Func<DeviceInfo> _localInfo;

    public SlipSender(Func<DeviceInfo> localInfo) => _localInfo = localInfo;

    /// <summary>Compute and send sha256 for each file (receivers verify it). Costs a full read of each file.</summary>
    public bool ComputeSha256 { get; set; }

    public SendSession CreateSession(PeerEndpoint target, IReadOnlyList<SendItem> items, string? targetAlias = null, string? pin = null)
    {
        if (items.Count == 0) throw new ArgumentException("Nothing to send", nameof(items));
        return new SendSession(_http, _localInfo, target, targetAlias, items, ComputeSha256, pin);
    }

    public void Dispose() => _http.Dispose();
}
