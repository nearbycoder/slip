# Slip for Windows

Native Windows client for Slip — C# / WinUI 3 (Windows App SDK), fully compatible with
[LocalSend](https://localsend.org) (protocol v2). Behaviour follows
[`protocol/IMPLEMENTATION.md`](../protocol/IMPLEMENTATION.md).

```
windows/
├── Slip.sln
├── src/
│   ├── Slip.Core/          cross-platform library (no UI): protocol, identity, discovery, server, sender
│   ├── Slip.Cli/           headless harness: slip-cli receive | send | discover | info | register
│   └── Slip.App/           WinUI 3 desktop app (Windows only)
└── tests/
    └── Slip.Core.Tests/    xUnit: JSON, paths, identity, end-to-end loopback over HTTPS and HTTP
```

## Requirements

- [.NET 10 SDK](https://dotnet.microsoft.com/download) (Core, CLI and tests build on Windows, macOS and Linux).
- For **Slip.App**: Windows 10 1809 (build 17763) or later. Visual Studio 2022/2026 with the
  *Windows application development* (WinUI) workload is optional — the `dotnet` CLI is enough.

## Core, CLI and tests (any OS)

```sh
cd windows
dotnet build src/Slip.Cli
dotnet test  tests/Slip.Core.Tests
```

> `dotnet build Slip.sln` also tries to build Slip.App, which needs Windows (the XAML compiler
> and MakePri are Windows tools). On macOS/Linux build the projects individually as above.

### CLI

```sh
# receive into ./inbox on port 53340, accepting everything
dotnet run --project src/Slip.Cli -- receive --port 53340 --dir ./inbox --auto-accept

# send files / folders / text (add --http for an HTTP-only receiver, --pin 1234 if it needs a PIN)
dotnet run --project src/Slip.Cli -- send --to 192.168.1.20:53317 photo.jpg ./Album
dotnet run --project src/Slip.Cli -- send --to 192.168.1.20:53317 --text "hello"

# list devices found via multicast within 5 s (also runs a server so peers can /register back)
dotnet run --project src/Slip.Cli -- discover --port 53341 [--scan] [--timeout 5]

# debugging
dotnet run --project src/Slip.Cli -- info --to 127.0.0.1:53317
dotnet run --project src/Slip.Cli -- register --to 127.0.0.1:53317 --port 53341
```

Common options: `--http`, `--alias`, `--pin`, `--data-dir` (identity + settings; default
`<LocalAppData>/Slip/cli`), `--ephemeral`, `--multicast-port`, `--verbose`, `--no-discovery`
(receive only). `--port` must differ from any other Slip/LocalSend instance on the same host; the
UDP multicast port (53317) is shared via `SO_REUSEADDR`/`SO_REUSEPORT`.

## Slip.App (Windows)

```powershell
cd windows
dotnet build src\Slip.App -c Debug -p:Platform=x64          # or -p:Platform=ARM64
dotnet run   --project src\Slip.App -p:Platform=x64

# unpackaged, self-contained build that runs on any Windows 10 1809+ PC (no runtime installs):
dotnet publish src\Slip.App -c Release -p:Platform=x64 -r win-x64 --self-contained true -o artifacts\Slip-x64
artifacts\Slip-x64\Slip.exe
```

The app is **unpackaged** (`WindowsPackageType=None`) and **self-contained**
(`WindowsAppSDKSelfContained=true`), so the published folder can be zipped and run anywhere.
CI (`.github/workflows/windows.yml`) builds and publishes x64 and arm64 and uploads them as artifacts.

Features: Mica backdrop and Fluent controls; NavigationView with **Receive** (alias, IPs, port,
discoverable and Quick Save toggles, live progress), **Send** (files / folder / text / paste tray,
nearby-device cards — click to send the selection or drag files onto a card — manual IP entry,
refresh + subnet scan), **Transfers** (per-file progress, speed, cancel, open file, show in
Explorer) and **Settings**. Incoming transfers show a ContentDialog with the file list (deselect
files to skip them) and Accept/Decline; text messages show with a Copy button. Toast
notifications via the Windows App SDK `AppNotificationManager`.

Data lives in `%LOCALAPPDATA%\Slip\`: `settings.json` (alias, port, HTTPS, save folder, Quick Save,
PIN, discoverable, theme), `identity.pfx` (self-signed RSA-2048 certificate, CN=Slip; its SHA-256
is the device fingerprint) and `identity.json` (the HTTP-mode fingerprint). Received files go to
`%USERPROFILE%\Downloads` by default.

## Windows Firewall

Slip must accept inbound connections on the local network:

- **TCP 53317** (or your configured port) — the HTTPS/HTTP receive server.
- **UDP 53317** — multicast discovery (group `224.0.0.167`).

On first launch Windows Defender Firewall asks whether to allow Slip — tick **Private networks**
and click *Allow*. If you dismissed the prompt, or your network is marked *Public*, other devices
will not see this PC and sends to it will time out. To fix it from an elevated PowerShell:

```powershell
New-NetFirewallRule -DisplayName "Slip" -Direction Inbound -Action Allow -Profile Private `
  -Program "C:\path\to\Slip.exe"
# or by port:
New-NetFirewallRule -DisplayName "Slip TCP" -Direction Inbound -Action Allow -Profile Private -Protocol TCP -LocalPort 53317
New-NetFirewallRule -DisplayName "Slip UDP" -Direction Inbound -Action Allow -Profile Private -Protocol UDP -LocalPort 53317
```

(The same applies to `slip-cli.exe` / `dotnet.exe` when using the CLI.) If LocalSend is also
installed and running, it already holds TCP 53317 — change Slip's port in Settings.

## Implementation notes

- **Server**: Kestrel (ASP.NET Core minimal APIs) with the in-memory certificate. Routes:
  `info`, `register`, `prepare-upload` (PIN → 401, busy → 409, text-only → 204, request held open
  for up to 60 s while the user decides, decline/timeout → 403), `upload` (400/403/409/422;
  streamed to `.slip-partial-*` then atomically renamed; SHA-256 verified when provided; `metadata.modified`
  applied), `cancel`. v1 routes → 404.
- **Paths**: sender-supplied names are sanitised (leading `/`, `.`/`..` segments dropped, `\` and
  `<>:"|?*`/control characters replaced, Windows reserved names such as `CON` prefixed, trailing
  dots/spaces trimmed) and collisions become `name (1).ext`.
- **Discovery**: UDP socket with `SO_REUSEADDR` (+`SO_REUSEPORT` on Unix) bound to 53317, joined to
  `224.0.0.167` on every IPv4 interface, TTL 32, loopback on; announces ×3 (100 ms / 500 ms / 2 s)
  on start, on network change and on refresh; answers announcements with `POST /register` and falls
  back to a UDP `announce:false`. HTTP /24 scan (≤50 concurrent, 1 s timeout) on refresh or when no
  peers are seen after 4 s. Peers expire after 60 s unless a transfer with them is active.
- **Sender**: `HttpClient` that accepts self-signed certificates, ≤3 parallel streamed uploads with
  byte progress, PIN retry, cancel (`POST /cancel`), optional SHA-256.

## Known gaps

- Minimise-to-tray is not implemented (the window minimises to the taskbar).
- The reverse "download API" (`prepare-download` / browser download) is not implemented.
- Optional certificate pinning (`sha256(peer cert) == fingerprint`) is not enforced.
- Toast activation when the app is *not* running only launches the app (no deep action).
