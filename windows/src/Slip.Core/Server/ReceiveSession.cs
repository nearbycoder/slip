using Slip.Core.Protocol;
using Slip.Core.Util;

namespace Slip.Core.Server;

public enum ReceiveState
{
    WaitingForDecision,
    Receiving,
    Completed,
    Declined,
    Cancelled,
    Failed,
}

public enum ReceiveFileState
{
    Pending,
    Receiving,
    Done,
    Failed,
    Skipped,
}

/// <summary>Incoming transfer request shown to the user (prepare-upload).</summary>
public sealed class IncomingTransferRequest
{
    public required string SessionId { get; init; }
    public required DeviceInfo Sender { get; init; }
    public required string SenderAddress { get; init; }
    public required IReadOnlyList<FileDto> Files { get; init; }
    public long TotalSize => Files.Sum(f => f.Size);
}

/// <summary>The user's answer to an <see cref="IncomingTransferRequest"/>.</summary>
public sealed record TransferDecision(bool Accepted, IReadOnlySet<string>? FileIds = null)
{
    public static TransferDecision AcceptAll { get; } = new(true);
    public static TransferDecision Decline { get; } = new(false);
    public static TransferDecision AcceptOnly(IEnumerable<string> fileIds) => new(true, fileIds.ToHashSet());
}

/// <summary>Called when a transfer arrives and Quick Save is off. Complete the task with the user's choice;
/// the token is cancelled on timeout, sender abort or server stop.</summary>
public delegate Task<TransferDecision> IncomingTransferHandler(IncomingTransferRequest request, CancellationToken cancellationToken);

public sealed record TextMessage(DeviceInfo Sender, string SenderAddress, string Text, DateTimeOffset ReceivedAt);

/// <summary>A file within a receive session. Progress notifications are throttled (~10/s).</summary>
public sealed class ReceiveFile : Observable
{
    private long _bytes;
    private long _lastNotify;
    private ReceiveFileState _state;
    private string? _savedPath;
    private string? _error;

    internal ReceiveFile(FileDto dto, string? token, ReceiveFileState state)
    {
        Dto = dto;
        Token = token;
        _state = state;
    }

    public FileDto Dto { get; }
    public string Id => Dto.Id;
    public string FileName => Dto.FileName;
    public long Size => Dto.Size;
    internal string? Token { get; }

    public long BytesReceived => Interlocked.Read(ref _bytes);
    public double Progress => Size <= 0 ? (State == ReceiveFileState.Done ? 1 : 0) : Math.Clamp((double)BytesReceived / Size, 0, 1);

    public ReceiveFileState State { get => _state; internal set { if (Set(ref _state, value)) OnPropertyChanged(nameof(Progress)); } }
    public string? SavedPath { get => _savedPath; internal set => Set(ref _savedPath, value); }
    public string? Error { get => _error; internal set => Set(ref _error, value); }

    internal event Action? ProgressChanged;

    internal void AddBytes(long count, bool force = false)
    {
        Interlocked.Add(ref _bytes, count);
        var now = Environment.TickCount64;
        if (force || now - Interlocked.Read(ref _lastNotify) >= 100)
        {
            Interlocked.Exchange(ref _lastNotify, now);
            OnPropertyChanged(nameof(BytesReceived));
            OnPropertyChanged(nameof(Progress));
            ProgressChanged?.Invoke();
        }
    }

    internal void ResetBytes()
    {
        Interlocked.Exchange(ref _bytes, 0);
        OnPropertyChanged(nameof(BytesReceived));
        OnPropertyChanged(nameof(Progress));
    }
}

/// <summary>Observable state of the (single) active receive session.</summary>
public sealed class ReceiveSession : Observable
{
    private ReceiveState _state = ReceiveState.WaitingForDecision;
    private DateTimeOffset? _finishedAt;
    private readonly long _startTicks = Environment.TickCount64;

    internal ReceiveSession(string id, DeviceInfo sender, string senderAddress, IReadOnlyList<FileDto> requested, string saveDirectory)
    {
        Id = id;
        Sender = sender;
        SenderAddress = senderAddress;
        Requested = requested;
        SaveDirectory = saveDirectory;
    }

    public string Id { get; }
    public DeviceInfo Sender { get; }
    public string SenderAddress { get; }
    public IReadOnlyList<FileDto> Requested { get; }
    public string SaveDirectory { get; }
    public DateTimeOffset StartedAt { get; } = DateTimeOffset.Now;

    /// <summary>Files accepted for this session (populated once accepted).</summary>
    public IReadOnlyList<ReceiveFile> Files { get; private set; } = [];

    public ReceiveState State { get => _state; internal set => Set(ref _state, value); }
    public DateTimeOffset? FinishedAt { get => _finishedAt; internal set => Set(ref _finishedAt, value); }

    public bool IsFinished => State is ReceiveState.Completed or ReceiveState.Declined or ReceiveState.Cancelled or ReceiveState.Failed;
    public long TotalBytes => Files.Sum(f => f.Size);
    public long BytesReceived => Files.Sum(f => f.BytesReceived);
    public double Progress => TotalBytes <= 0 ? (State == ReceiveState.Completed ? 1 : 0) : Math.Clamp((double)BytesReceived / TotalBytes, 0, 1);

    /// <summary>Average bytes/second since the session started.</summary>
    public double BytesPerSecond
    {
        get
        {
            var seconds = (Environment.TickCount64 - _startTicks) / 1000.0;
            return seconds <= 0 ? 0 : BytesReceived / seconds;
        }
    }

    internal CancellationTokenSource Cancellation { get; } = new();
    internal Dictionary<string, ReceiveFile> FileMap { get; } = new();
    internal int ActiveUploads;
    internal long LastActivityTicks = Environment.TickCount64;

    internal void SetAccepted(IEnumerable<ReceiveFile> files)
    {
        var list = files.ToList();
        foreach (var f in list)
        {
            FileMap[f.Id] = f;
            f.ProgressChanged += () =>
            {
                OnPropertyChanged(nameof(BytesReceived));
                OnPropertyChanged(nameof(Progress));
                OnPropertyChanged(nameof(BytesPerSecond));
            };
        }
        Files = list;
        OnPropertyChanged(nameof(Files));
        OnPropertyChanged(nameof(TotalBytes));
    }

    internal void Touch() => Interlocked.Exchange(ref LastActivityTicks, Environment.TickCount64);
}
