using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Slip.App.Helpers;
using Slip.App.Services;
using Slip.Core.Client;
using Slip.Core.Server;

namespace Slip.App.ViewModels;

/// <summary>
/// UI-thread mirror of a Slip.Core send or receive session. Core objects raise PropertyChanged on
/// background threads, so instead of binding to them directly the view model polls them
/// (<see cref="Refresh"/>) from a UI-thread timer while the transfer is active.
/// </summary>
public sealed partial class TransferViewModel : ObservableObject
{
    private readonly SendSession? _send;
    private readonly ReceiveSession? _receive;
    private double _progress;
    private string _statusText = "";
    private string _subtitle = "";
    private bool _isActive = true;
    private bool _isWaiting;
    private bool _hasError;

    private TransferViewModel(SendSession? send, ReceiveSession? receive)
    {
        _send = send;
        _receive = receive;
        CancelCommand = new RelayCommand(Cancel, () => IsActive);
        OpenFolderCommand = new RelayCommand(OpenFolder, () => FolderPath is not null);
        if (send is not null)
        {
            foreach (var f in send.Files) Files.Add(new TransferFileViewModel(f));
        }
        else if (receive is not null)
        {
            foreach (var f in receive.Files) Files.Add(new TransferFileViewModel(f));
        }
        Refresh();
    }

    public static TransferViewModel ForSend(SendSession session) => new(session, null);
    public static TransferViewModel ForReceive(ReceiveSession session) => new(null, session);

    public bool IsIncoming => _receive is not null;
    public ReceiveSession? ReceiveSession => _receive;
    public SendSession? SendSession => _send;

    public string Title => IsIncoming
        ? $"From {_receive!.Sender.Alias}"
        : _send!.IsTextMessage ? $"Message to {_send.TargetAlias}" : $"To {_send.TargetAlias}";

    /// <summary>Download arrow for incoming, send arrow for outgoing.</summary>
    public string Glyph => IsIncoming ? "" : "";

    public DateTimeOffset StartedAt => IsIncoming ? _receive!.StartedAt : _send!.StartedAt;

    public ObservableCollection<TransferFileViewModel> Files { get; } = [];

    public IRelayCommand CancelCommand { get; }
    public IRelayCommand OpenFolderCommand { get; }

    /// <summary>0–100.</summary>
    public double Progress { get => _progress; private set => SetProperty(ref _progress, value); }
    public string StatusText { get => _statusText; private set => SetProperty(ref _statusText, value); }
    public string Subtitle { get => _subtitle; private set => SetProperty(ref _subtitle, value); }
    public bool IsWaiting { get => _isWaiting; private set => SetProperty(ref _isWaiting, value); }
    public bool HasError { get => _hasError; private set => SetProperty(ref _hasError, value); }

    public bool IsActive
    {
        get => _isActive;
        private set
        {
            if (SetProperty(ref _isActive, value)) CancelCommand.NotifyCanExecuteChanged();
        }
    }

    public string? FolderPath
    {
        get
        {
            if (_receive is not null) return _receive.SaveDirectory;
            var local = _send?.Files.Select(f => f.Item.LocalPath).FirstOrDefault(p => p is not null);
            return local is null ? null : Path.GetDirectoryName(local);
        }
    }

    public bool CanOpenFolder => FolderPath is not null && !(_send?.IsTextMessage ?? false);

    public void Refresh()
    {
        foreach (var f in Files) f.Refresh();

        if (_receive is { } r)
        {
            IsActive = !r.IsFinished;
            IsWaiting = r.State == ReceiveState.WaitingForDecision;
            HasError = r.State is ReceiveState.Failed || r.Files.Any(f => f.State == ReceiveFileState.Failed);
            Progress = r.Progress * 100;
            StatusText = r.State switch
            {
                ReceiveState.WaitingForDecision => "Waiting for your decision…",
                ReceiveState.Receiving => $"Receiving · {Format.Bytes(r.BytesReceived)} of {Format.Bytes(r.TotalBytes)} · {Format.Speed(r.BytesPerSecond)}",
                ReceiveState.Completed when HasError => "Completed with errors",
                ReceiveState.Completed => $"Received {Format.Bytes(r.TotalBytes)}",
                ReceiveState.Declined => "Declined",
                ReceiveState.Cancelled => "Cancelled",
                _ => "Failed",
            };
            Subtitle = $"{r.Sender.DeviceModel ?? "Unknown device"} · {r.SenderAddress} · {r.StartedAt.LocalDateTime:t}";
        }
        else if (_send is { } s)
        {
            IsActive = !s.IsFinished;
            IsWaiting = s.State is SendState.Preparing or SendState.WaitingForAcceptance;
            HasError = s.State is SendState.Failed or SendState.Declined or SendState.Busy or SendState.TooManyRequests or SendState.PinRequired;
            Progress = s.Progress * 100;
            StatusText = s.State switch
            {
                SendState.Preparing => "Preparing…",
                SendState.WaitingForAcceptance => "Waiting for the receiver to accept…",
                SendState.Sending => $"Sending · {Format.Bytes(s.BytesSent)} of {Format.Bytes(s.TotalBytes)} · {Format.Speed(s.BytesPerSecond)}",
                SendState.Completed => s.IsTextMessage ? "Delivered" : $"Sent {Format.Bytes(s.TotalBytes)}",
                SendState.Cancelled => "Cancelled",
                _ => s.ErrorMessage ?? s.State.ToString(),
            };
            Subtitle = $"{s.Target} · {s.StartedAt.LocalDateTime:t}";
        }
    }

    private void Cancel()
    {
        if (_send is not null) _ = Task.Run(_send.CancelAsync);
        else if (_receive is not null && ReferenceEquals(App.State.Node?.Server?.CurrentSession, _receive))
            App.State.Node.Server.CancelCurrentSession();
    }

    private void OpenFolder()
    {
        if (FolderPath is { } dir) ShellService.OpenFolder(dir);
    }
}

public sealed partial class TransferFileViewModel : ObservableObject
{
    private readonly SendFile? _send;
    private readonly ReceiveFile? _receive;
    private double _progress;
    private string _statusText = "";
    private string? _path;

    public TransferFileViewModel(SendFile file)
    {
        _send = file;
        _path = file.Item.LocalPath;
        OpenCommand = new RelayCommand(Open, () => CanOpen);
        RevealCommand = new RelayCommand(Reveal, () => CanOpen);
        Refresh();
    }

    public TransferFileViewModel(ReceiveFile file)
    {
        _receive = file;
        OpenCommand = new RelayCommand(Open, () => CanOpen);
        RevealCommand = new RelayCommand(Reveal, () => CanOpen);
        Refresh();
    }

    public string FileName => _send?.FileName ?? _receive!.FileName;
    public string SizeText => Format.Bytes(_send?.Size ?? _receive!.Size);
    public IRelayCommand OpenCommand { get; }
    public IRelayCommand RevealCommand { get; }

    public double Progress { get => _progress; private set => SetProperty(ref _progress, value); }
    public string StatusText { get => _statusText; private set => SetProperty(ref _statusText, value); }

    public bool CanOpen => _path is not null && File.Exists(_path);

    public void Refresh()
    {
        if (_receive is { } r)
        {
            Progress = r.Progress * 100;
            if (r.SavedPath is not null && _path != r.SavedPath)
            {
                _path = r.SavedPath;
                OnPropertyChanged(nameof(CanOpen));
                OpenCommand.NotifyCanExecuteChanged();
                RevealCommand.NotifyCanExecuteChanged();
            }
            StatusText = r.State switch
            {
                ReceiveFileState.Pending => $"{SizeText} · waiting",
                ReceiveFileState.Receiving => $"{Format.Bytes(r.BytesReceived)} of {SizeText}",
                ReceiveFileState.Done => $"{SizeText} · saved to {Path.GetDirectoryName(r.SavedPath)}",
                ReceiveFileState.Skipped => $"{SizeText} · skipped",
                _ => $"{SizeText} · {r.Error ?? "failed"}",
            };
        }
        else if (_send is { } s)
        {
            Progress = s.Progress * 100;
            StatusText = s.State switch
            {
                SendFileState.Pending => SizeText,
                SendFileState.Sending => $"{Format.Bytes(s.BytesSent)} of {SizeText}",
                SendFileState.Done => $"{SizeText} · sent",
                SendFileState.Skipped => $"{SizeText} · skipped by receiver",
                _ => $"{SizeText} · {s.Error ?? "failed"}",
            };
        }
    }

    private void Open()
    {
        if (_path is not null) ShellService.OpenFile(_path);
    }

    private void Reveal()
    {
        if (_path is not null) ShellService.RevealInExplorer(_path);
    }
}
