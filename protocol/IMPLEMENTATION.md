# Slip implementation guide

Slip speaks the [LocalSend protocol v2](https://github.com/localsend/protocol) so every
Slip client interoperates with every LocalSend client (and with each other). Each platform
is built natively — no shared cross-platform UI runtime:

| Platform | Directory  | Language / UI                         | Core library            |
|----------|------------|---------------------------------------|-------------------------|
| macOS    | `apple/`   | Swift, SwiftUI (AppKit where needed)  | `SlipKit` Swift package |
| iOS      | `apple/`   | Swift, SwiftUI                        | `SlipKit` Swift package |
| Android  | `android/` | Kotlin, Jetpack Compose (Material 3)  | `:core` Gradle module   |
| Windows  | `windows/` | C#, WinUI 3 (Windows App SDK)         | `Slip.Core` (.NET 8)    |
| Linux    | `linux/`   | Rust, GTK 4 + libadwaita              | `slip-core` crate       |

Each core library is UI-free and testable headless on any OS. This file is the single
source of truth for behaviour that must match across clients. The upstream spec is
mirrored at [`localsend-v2.md`](./localsend-v2.md).

## Constants

- Protocol version string we advertise: `"2.1"` (what current LocalSend apps send).
- Port: `53317` (TCP for HTTP(S), UDP for multicast). Configurable.
- Multicast group: `224.0.0.167`, port `53317`. Configurable.
- API prefix: `/api/localsend/v2`.
- Default protocol: `https`. Optional `http` mode in settings.
- `deviceModel`: e.g. `"macOS"`, `"iPhone"`, `"Pixel 8"`, `"Windows"`, `"Linux"`.
- `deviceType`: `desktop` on macOS/Windows/Linux, `mobile` on iOS/Android. Unknown values
  received from peers fall back to `desktop`.

## Identity

- On first launch generate and persist:
  - an RSA-2048 (or ECDSA P-256) private key and a **self-signed X.509 certificate**
    (CN = `Slip`, validity ≥ 10 years). It is reused across launches.
  - an alias: `"<Adjective> <Fruit>"`, picked randomly from the lists in
    [`aliases.json`](./aliases.json). User can rename it in settings.
- `fingerprint` in HTTPS mode = lowercase hex **SHA-256 of the certificate DER**.
  In HTTP mode = a persisted random 32-char hex string.
- Ignore discovery packets / register calls whose fingerprint equals our own.

## JSON shapes

`DeviceInfo` (sent in announce, register, prepare-upload `info`, info):

```json
{
  "alias": "Nice Orange",
  "version": "2.1",
  "deviceModel": "macOS",
  "deviceType": "desktop",
  "fingerprint": "…",
  "port": 53317,
  "protocol": "https",
  "download": false
}
```

Multicast packets add `"announce": true|false` **and** the legacy duplicate
`"announcement": true|false` (LocalSend v1 peers read that key). When parsing, treat
missing optional fields leniently: `deviceModel`/`deviceType` nullable, `port` defaults to
53317, `protocol` defaults to `https`, `download` defaults to `false`, and accept either
`announce` or `announcement`.

`FileDto`:

```json
{ "id": "…", "fileName": "a.png", "size": 123, "fileType": "image/png",
  "sha256": null, "preview": null,
  "metadata": { "modified": "2024-01-01T12:00:00Z", "accessed": null } }
```

Unknown JSON fields must be ignored everywhere.

## Discovery

1. **Multicast listener**: bind UDP `0.0.0.0:53317` with `SO_REUSEADDR` (+`SO_REUSEPORT`
   where available), join `224.0.0.167` on every non-loopback IPv4 interface, and send
   with multicast TTL 32 and loopback enabled (so several clients on one host see each
   other; self-packets are filtered by fingerprint).
2. **Announce**: on startup, on network change, and when the user hits refresh, send our
   `DeviceInfo` + `announce: true` to the group **three times** at ~100 ms, ~500 ms and
   ~2000 ms (packets get dropped).
3. **On receiving** a packet from a peer (fingerprint ≠ ours): add/update the peer using
   the packet's source IP as its address. If `announce` is true, answer it:
   `POST {peer.protocol}://{ip}:{peer.port}/api/localsend/v2/register` with our
   `DeviceInfo`; if that request fails, send a multicast packet with `announce: false`.
4. **`POST /register` handler**: add/update the caller (source IP of the TCP connection)
   and respond `200` with our `DeviceInfo` (without `port`/`protocol` is allowed, but
   include them — it's harmless).
5. **HTTP scan fallback** (refresh button / when no peers after a few seconds): for each
   local IPv4 interface with a /24 (or smaller) subnet, `POST /register` to every host
   address in parallel (≤ 50 concurrent, ~1 s timeout each) on the configured port.
6. **Keep the list fresh.** Peers (LocalSend especially) only announce at startup, so while
   running, re-send our announcement (`announce: true`, a single packet is enough) every
   ~30 s; peers answer with `POST /register`, which refreshes them.
7. Peers not seen for ~60 s are **probed** with a direct `POST /register` (~2 s timeout) and
   removed only if that fails. Never expire a peer with an active transfer.
   Peers are keyed by fingerprint; keep the original fingerprint when refreshing from a probe.

HTTPS clients **must accept self-signed certificates** (disable chain/hostname
validation for these LocalSend endpoints only). Optionally pin `sha256(peer cert) ==
fingerprint` once known.

## Receiving (server side)

The HTTP(S) server listens on `0.0.0.0:<port>` and serves:

| Route | Behaviour |
|---|---|
| `GET  /api/localsend/v2/info` | `200` + our `DeviceInfo`. Optional `?fingerprint=` is ignored. |
| `POST /api/localsend/v2/register` | see discovery |
| `POST /api/localsend/v2/prepare-upload[?pin=]` | see below |
| `POST /api/localsend/v2/upload?sessionId&fileId&token` | raw body = file bytes |
| `POST /api/localsend/v2/cancel?sessionId` | cancel session, `200` |
| `POST /api/localsend/v1/*`… | not supported → `404` |

`prepare-upload`:

- If a PIN is configured and `?pin` is missing/wrong → `401`.
- If another session is active (awaiting decision or transferring) → `409`.
- Otherwise show the incoming-transfer UI (sender alias, device type, file list, total
  size) and **hold the HTTP request open** until the user decides (timeout ~60 s →
  `403`). With **auto-accept** ("Quick Save") enabled, accept immediately.
- Declined → `403`.
- **Text messages**: if every file has `fileType` starting with `text/` and a non-null
  `preview`, it's a message. Show the text (with Copy) and respond `204` — no upload follows.
- Accepted → `200 {"sessionId": uuid, "files": {fileId: token}}` with one random token per
  accepted file (the user may deselect files; omit those).
- Record the sender's IP; `upload` calls from a different IP → `403`.

`upload`:

- Missing params → `400`; unknown session/file or bad token or IP mismatch → `403`.
- Stream the body to `<saveDir>/<.slip-partial-*>` then atomically rename to the final name.
  Never buffer whole files in memory. Report progress to the UI.
- `fileName` may contain `/` (folder sends): create subdirectories, but **sanitize**:
  strip leading `/`, drop `..`/`.` segments, replace `\` and characters illegal on the
  host FS. If the target exists, append ` (1)`, ` (2)`, … before the extension.
- If `sha256` was provided, verify → `422` on mismatch (delete the partial file).
- Apply `metadata.modified` as the file's mtime when present.
- When every accepted file is done (or failed), the session ends.

`cancel`: remove partial files, end session, update UI.

Default save directory: the user's Downloads folder (`~/Downloads`, Android public
`Download/Slip` via MediaStore, iOS app Documents — visible in the Files app).

## Sending (client side)

1. User picks a peer and one or more files/folders, or types a text message.
2. `POST prepare-upload` with `info` (our `DeviceInfo`) and `files` (random UUID ids).
   For folders, send each file with `fileName` = relative path including the folder name
   (`Photos/2024/a.jpg`). For text: one file, `fileName` = `<uuid>.txt`,
   `fileType` = `text/plain`, `size` = UTF-8 byte length, `preview` = the text.
3. Response handling: `200` → upload; `204` → done; `401` → prompt for PIN and retry
   with `?pin=`; `403` → "Declined"; `409` → "Receiver is busy"; `429` → "Too many
   requests"; other → error.
4. Upload accepted files (only ids present in the response) with up to 3 in parallel,
   streaming from disk, `Content-Type: application/octet-stream`, with byte progress.
5. User cancel → `POST cancel?sessionId=`.
6. Peer's protocol/port come from discovery; never assume HTTPS.

## Settings (all clients)

Alias · port · HTTPS on/off · save directory (desktop) · Quick Save / auto-accept ·
require PIN (+ value) · discoverable on/off · theme (system / light / dark).

## UI shape (adapt to each platform's idioms)

- **Receive** tab: big "ready to receive" card showing alias, IP(s), port, and the
  discoverable toggle.
- **Send** tab: selection tray (files, folder, text, paste) + list of nearby devices with
  device-type icon, alias and model; tap a device to send. Manual "send to IP" entry.
- **Transfers/History**: progress per file, overall speed, open file / reveal in folder.
- **Settings**.

Brand: name **Slip**, primary green `#16a34a`, icon `assets/icon.svg`.

## Interop testing

Every core library ships a headless CLI/test harness so cores can be tested against each
other and against the official LocalSend app on one machine:

- `slip-cli receive --port <p> --dir <d> --auto-accept`
- `slip-cli send --to <ip:port> [--http] <files…>`
- `slip-cli discover` (prints peers seen within ~5 s)

Ports other than 53317 must work so several cores can run on one host.
