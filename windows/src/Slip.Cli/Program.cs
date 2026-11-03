using System.Runtime.InteropServices;
using Slip.Core;
using Slip.Core.Client;
using Slip.Core.Discovery;
using Slip.Core.Identity;
using Slip.Core.Protocol;
using Slip.Core.Server;
using Slip.Core.Util;

namespace Slip.Cli;

internal static class Program
{
    private const string Usage = """
        slip-cli — headless Slip / LocalSend v2 client

        Usage:
          slip-cli receive  [--port P] [--dir D] [--auto-accept] [--http] [--pin X] [--alias A] [--no-discovery]
          slip-cli send     --to host[:port] [--http] [--pin X] [--sha256] [--text "message"] [files or folders…]
          slip-cli discover [--port P] [--timeout S] [--scan] [--http]
          slip-cli info     --to host[:port] [--http]
          slip-cli register --to host[:port] [--http] [--port P]

        Common options:
          --data-dir D      identity/settings directory (default: <LocalAppData>/Slip/cli)
          --ephemeral       use a throw-away identity
          --multicast-port  UDP multicast port (default 53317)
          --verbose         debug logging
        """;

    public static async Task<int> Main(string[] argv)
    {
        if (argv.Length == 0 || argv[0] is "-h" or "--help" or "help")
        {
            Console.WriteLine(Usage);
            return argv.Length == 0 ? 2 : 0;
        }

        Args args;
        try { args = Args.Parse(argv); }
        catch (FormatException e)
        {
            Console.Error.WriteLine(e.Message);
            return 2;
        }

        SlipLog.MinimumLevel = args.Flag("verbose") ? LogLevel.Debug : LogLevel.Info;
        SlipLog.Message += (level, msg) => Console.Error.WriteLine($"[{level.ToString().ToLowerInvariant()}] {msg}");

        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
        PosixSignalRegistration? sigterm = null;
        try { sigterm = PosixSignalRegistration.Create(PosixSignal.SIGTERM, ctx => { ctx.Cancel = true; cts.Cancel(); }); }
        catch (PlatformNotSupportedException) { }
        using var _ = sigterm;

        try
        {
            return args.Command switch
            {
                "receive" => await ReceiveAsync(args, cts.Token),
                "send" => await SendAsync(args, cts.Token),
                "discover" => await DiscoverAsync(args, cts.Token),
                "info" => await InfoAsync(args, cts.Token),
                "register" => await RegisterAsync(args, cts.Token),
                _ => Unknown(args.Command),
            };
        }
        catch (OperationCanceledException)
        {
            return 130;
        }
        catch (Exception e) when (e is IOException or System.Net.Sockets.SocketException or FormatException or FileNotFoundException)
        {
            Console.Error.WriteLine($"error: {e.Message}");
            return 1;
        }
    }

    private static int Unknown(string command)
    {
        Console.Error.WriteLine($"Unknown command '{command}'.\n\n{Usage}");
        return 2;
    }

    // ---------------------------------------------------------------------------------------------

    private static (SlipSettings Settings, SlipIdentity Identity) LoadState(Args args)
    {
        if (args.Flag("ephemeral"))
            return (new SlipSettings(), SlipIdentity.CreateEphemeral());
        var dir = args.Option("data-dir") ?? Path.Combine(AppPaths.DataDirectory, "cli");
        var settings = new SettingsStore(Path.Combine(dir, "settings.json")).Load();
        return (settings, SlipIdentity.LoadOrCreate(dir));
    }

    private static SlipSettings ApplyCommon(Args args, SlipSettings s)
    {
        s.UseHttps = !args.Flag("http");
        if (args.Option("port") is { } port) s.Port = int.Parse(port);
        if (args.Option("alias") is { } alias) s.Alias = alias;
        if (args.Option("multicast-port") is { } mp) s.MulticastPort = int.Parse(mp);
        if (args.Option("pin") is { } pin) { s.RequirePin = true; s.Pin = pin; }
        return s;
    }

    private static async Task<int> ReceiveAsync(Args args, CancellationToken ct)
    {
        var (settings, identity) = LoadState(args);
        ApplyCommon(args, settings);
        settings.SaveDirectory = Path.GetFullPath(args.Option("dir") ?? settings.SaveDirectory);
        settings.AutoAccept = args.Flag("auto-accept");
        Directory.CreateDirectory(settings.SaveDirectory);

        await using var node = new SlipNode(settings, identity, DeviceModelName(), DeviceType.Headless)
        {
            EnableDiscovery = !args.Flag("no-discovery"),
        };
        node.DecisionHandler = ConsoleDecisionAsync;
        node.ReceiveStarted += (_, s) =>
        {
            Console.WriteLine($"<- {s.Sender.Alias} ({s.SenderAddress}) is sending {s.Files.Count} file(s), {FormatBytes(s.TotalBytes)}");
            foreach (var f in s.Files)
            {
                f.PropertyChanged += (_, e) =>
                {
                    if (e.PropertyName == nameof(ReceiveFile.State) && f.State is ReceiveFileState.Done)
                        Console.WriteLine($"   saved {f.SavedPath} ({FormatBytes(f.BytesReceived)})");
                    else if (e.PropertyName == nameof(ReceiveFile.State) && f.State is ReceiveFileState.Failed)
                        Console.WriteLine($"   failed {f.FileName}: {f.Error}");
                };
            }
        };
        node.ReceiveEnded += (_, s) => Console.WriteLine($"   session {s.State.ToString().ToLowerInvariant()}");
        node.MessageReceived += (_, m) => Console.WriteLine($"<- message from {m.Sender.Alias} ({m.SenderAddress}):\n{m.Text}");
        node.Peers.PeerUpdated += (_, e) =>
        {
            if (e.IsNew) Console.WriteLine($"   peer {e.Peer.Alias} @ {e.Peer.Address}:{e.Peer.Info.Port} ({e.Peer.Info.Protocol}, via {e.Peer.Source.ToString().ToLowerInvariant()})");
        };

        await node.StartAsync(ct);
        var info = node.LocalInfo;
        Console.WriteLine($"Receiving as \"{info.Alias}\" on {info.Protocol}://0.0.0.0:{node.Server!.Port} -> {settings.SaveDirectory}");
        Console.WriteLine($"Fingerprint {info.Fingerprint}{(settings.AutoAccept ? "  (auto-accept)" : "")}{(settings.EffectivePin is not null ? "  (PIN required)" : "")}");
        Console.WriteLine("Press Ctrl+C to stop.");

        try { await Task.Delay(Timeout.Infinite, ct); }
        catch (OperationCanceledException) { }
        Console.WriteLine("Stopping.");
        return 0;
    }

    private static async Task<TransferDecision> ConsoleDecisionAsync(IncomingTransferRequest request, CancellationToken ct)
    {
        Console.WriteLine($"<- {request.Sender.Alias} ({request.SenderAddress}) wants to send {request.Files.Count} file(s), {FormatBytes(request.TotalSize)}:");
        foreach (var f in request.Files) Console.WriteLine($"     {f.FileName}  {FormatBytes(f.Size)}");
        if (Console.IsInputRedirected)
        {
            Console.WriteLine("   (stdin is not interactive; declining — use --auto-accept)");
            return TransferDecision.Decline;
        }
        Console.Write("   Accept? [y/N] ");
        var line = await Task.Run(Console.ReadLine, ct).WaitAsync(ct);
        return line?.Trim().ToLowerInvariant() is "y" or "yes" ? TransferDecision.AcceptAll : TransferDecision.Decline;
    }

    private static async Task<int> SendAsync(Args args, CancellationToken ct)
    {
        var to = args.Option("to") ?? throw new FormatException("send requires --to host[:port]");
        var (settings, identity) = LoadState(args);
        ApplyCommon(args, settings);
        var target = PeerEndpoint.Parse(to, https: !args.Flag("http"));

        var items = new List<SendItem>();
        if (args.Option("text") is { } text) items.Add(SendItem.FromText(text));
        items.AddRange(SendItem.FromPaths(args.Positional));
        if (items.Count == 0) throw new FormatException("Nothing to send: pass files/folders or --text");

        await using var node = new SlipNode(settings, identity, DeviceModelName(), DeviceType.Headless) { EnableDiscovery = false };
        node.Sender.ComputeSha256 = args.Flag("sha256");
        var session = node.CreateSend(target, items, pin: args.Option("pin"));

        Console.WriteLine($"-> {target}: {items.Count} item(s), {FormatBytes(items.Sum(i => i.Size))}");
        var lastState = session.State;
        session.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(SendSession.State) || session.State == lastState) return;
            lastState = session.State;
            if (session.State == SendState.WaitingForAcceptance) Console.WriteLine("   waiting for the receiver to accept…");
            if (session.State == SendState.Sending) Console.WriteLine($"   accepted (session {session.SessionId})");
        };

        using var progress = new Timer(_ =>
        {
            if (session.State == SendState.Sending)
                Console.WriteLine($"   {session.Progress:P0}  {FormatBytes(session.BytesSent)}/{FormatBytes(session.TotalBytes)}  {FormatBytes((long)session.BytesPerSecond)}/s");
        }, null, 1000, 1000);

        var state = await session.RunAsync(PromptPinAsync, ct);
        foreach (var f in session.Files.Where(f => f.State == SendFileState.Failed))
            Console.WriteLine($"   failed {f.FileName}: {f.Error}");
        Console.WriteLine(state == SendState.Completed
            ? $"   done: {FormatBytes(session.BytesSent)} in {(DateTimeOffset.Now - session.StartedAt).TotalSeconds:F1}s"
            : $"   {state.ToString().ToLowerInvariant()}: {session.ErrorMessage}");
        return state == SendState.Completed ? 0 : 1;
    }

    private static Task<string?> PromptPinAsync(int attempt, CancellationToken ct)
    {
        if (Console.IsInputRedirected) return Task.FromResult<string?>(null);
        Console.Write(attempt == 1 ? "   Receiver requires a PIN: " : "   Wrong PIN, try again: ");
        return Task.Run(Console.ReadLine, ct);
    }

    private static async Task<int> DiscoverAsync(Args args, CancellationToken ct)
    {
        var (settings, identity) = LoadState(args);
        ApplyCommon(args, settings);
        var timeout = TimeSpan.FromSeconds(double.Parse(args.Option("timeout") ?? "5", System.Globalization.CultureInfo.InvariantCulture));

        await using var node = new SlipNode(settings, identity, DeviceModelName(), DeviceType.Headless);
        node.Peers.PeerUpdated += (_, e) =>
        {
            if (e.IsNew) Console.Error.WriteLine($"   found {e.Peer.Alias} @ {e.Peer.Address} via {e.Peer.Source.ToString().ToLowerInvariant()}");
        };
        await node.StartAsync(ct);
        Console.Error.WriteLine($"Discovering for {timeout.TotalSeconds:0.#}s as \"{node.LocalInfo.Alias}\" (server {node.LocalInfo.Protocol}:{node.Server!.Port}, multicast {settings.MulticastGroup}:{settings.MulticastPort})…");
        if (args.Flag("scan")) _ = node.Discovery?.ScanAsync(ct);

        try { await Task.Delay(timeout, ct); }
        catch (OperationCanceledException) { }

        var peers = node.Peers.Snapshot();
        if (peers.Count == 0)
        {
            Console.WriteLine("No peers found.");
            return 1;
        }
        Console.WriteLine($"{"ALIAS",-24} {"ADDRESS",-22} {"PROTO",-6} {"MODEL",-12} {"TYPE",-9} {"VIA",-9} FINGERPRINT");
        foreach (var p in peers)
        {
            Console.WriteLine($"{Trunc(p.Alias, 24),-24} {NetUtil.HostPort(p.Address, p.Info.Port),-22} {p.Info.Protocol,-6} {Trunc(p.Info.DeviceModel ?? "-", 12),-12} {(p.Info.DeviceType?.ToWire() ?? "-"),-9} {p.Source.ToString().ToLowerInvariant(),-9} {Trunc(p.Fingerprint, 16)}");
        }
        return 0;
    }

    private static async Task<int> InfoAsync(Args args, CancellationToken ct)
    {
        var target = PeerEndpoint.Parse(args.Option("to") ?? throw new FormatException("info requires --to"), !args.Flag("http"));
        using var client = SlipHttp.CreateDiscoveryClient(TimeSpan.FromSeconds(5));
        var info = await SlipHttp.InfoAsync(client, target, ct);
        if (info is null) { Console.Error.WriteLine($"No response from {target}"); return 1; }
        Console.WriteLine(SlipJson.Serialize(info));
        return 0;
    }

    private static async Task<int> RegisterAsync(Args args, CancellationToken ct)
    {
        var target = PeerEndpoint.Parse(args.Option("to") ?? throw new FormatException("register requires --to"), !args.Flag("http"));
        var (settings, identity) = LoadState(args);
        ApplyCommon(args, settings);
        await using var node = new SlipNode(settings, identity, DeviceModelName(), DeviceType.Headless) { EnableDiscovery = false };
        using var client = SlipHttp.CreateDiscoveryClient(TimeSpan.FromSeconds(5));
        Console.Error.WriteLine($"POST {target.Url("register")} as {SlipJson.Serialize(node.LocalInfo)}");
        var info = await SlipHttp.RegisterAsync(client, target, node.LocalInfo, ct);
        if (info is null) { Console.Error.WriteLine($"Register failed at {target}"); return 1; }
        Console.WriteLine(SlipJson.Serialize(info));
        return 0;
    }

    // ---------------------------------------------------------------------------------------------

    private static string DeviceModelName() =>
        OperatingSystem.IsWindows() ? "Windows" : OperatingSystem.IsMacOS() ? "macOS" : OperatingSystem.IsLinux() ? "Linux" : "Slip CLI";

    private static string Trunc(string s, int max) => s.Length <= max ? s : s[..(max - 1)] + "…";

    internal static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double value = bytes;
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1) { value /= 1024; unit++; }
        return unit == 0 ? $"{bytes} B" : $"{value:0.0} {units[unit]}";
    }
}

/// <summary>Minimal argument parser: command, --flags, --options value, positionals.</summary>
internal sealed class Args
{
    private static readonly HashSet<string> Flags = ["http", "auto-accept", "verbose", "sha256", "scan", "ephemeral", "no-discovery"];

    private readonly Dictionary<string, string> _options = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _flags = new(StringComparer.OrdinalIgnoreCase);

    public string Command { get; private init; } = "";
    public List<string> Positional { get; } = [];

    public bool Flag(string name) => _flags.Contains(name);
    public string? Option(string name) => _options.GetValueOrDefault(name);

    public static Args Parse(string[] argv)
    {
        var args = new Args { Command = argv[0].ToLowerInvariant() };
        for (var i = 1; i < argv.Length; i++)
        {
            var a = argv[i];
            if (a == "--")
            {
                args.Positional.AddRange(argv[(i + 1)..]);
                break;
            }
            if (a.StartsWith("--"))
            {
                var name = a[2..];
                string? value = null;
                var eq = name.IndexOf('=');
                if (eq >= 0) { value = name[(eq + 1)..]; name = name[..eq]; }
                if (Flags.Contains(name)) { args._flags.Add(name); continue; }
                value ??= i + 1 < argv.Length ? argv[++i] : throw new FormatException($"Option --{name} needs a value");
                args._options[name] = value;
            }
            else
            {
                args.Positional.Add(a);
            }
        }
        return args;
    }
}
