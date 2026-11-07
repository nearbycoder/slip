# Slip for macOS and iOS

Native SwiftUI apps for macOS 14+ and iOS 17+. They speak the
[LocalSend v2 protocol](../protocol/localsend-v2.md) and follow
[`protocol/IMPLEMENTATION.md`](../protocol/IMPLEMENTATION.md), so they work with LocalSend and
with every other Slip client.

```
apple/
├── project.yml            XcodeGen spec → Slip.xcodeproj (macOS + iOS app targets)
├── App/
│   ├── Shared/            SwiftUI views used by both apps
│   ├── macOS/             App entry, sidebar window, menu bar extra, asset catalog
│   └── iOS/               App entry, tab bar, asset catalog
└── SlipKit/               Swift package, no UI code (macOS 14+ / iOS 17+)
    ├── Sources/SlipKit/   models, identity, discovery, server, client, @Observable controller
    ├── Sources/SlipCLI/   `slip-cli` headless harness
    └── Tests/SlipKitTests unit tests and loopback end-to-end tests
```

## SlipKit

| Area | Implementation |
|---|---|
| Models | `DeviceInfo`, `MulticastPacket` (writes both `announce` and `announcement`), `FileDto`, `PrepareUploadRequest/Response`. Parsing is lenient: missing fields get defaults, unknown fields are ignored, an unknown `deviceType` becomes `desktop`, and numbers sent as strings are accepted. |
| Identity | P-256 key plus a self-signed X.509 certificate (CN=Slip, valid for 20 years), built with swift-certificates. Stored in `Application Support/Slip/identity.json`. The HTTPS fingerprint is the lowercase SHA-256 of the certificate DER. In HTTP mode it is a stored random 32-character hex string. |
| Server | SwiftNIO and swift-nio-ssl, with the certificate held in memory, so it works on both iOS and macOS. Routes: `info`, `register`, `prepare-upload` (PIN check; the request is held open until the user decides, with a 60 s timeout that returns 403; 409 when busy; 204 for text messages), `upload` (streamed to `.slip-partial-*` and then renamed atomically; checks session, token and IP; verifies sha256 and returns 422 on mismatch; sanitised paths with ` (n)` suffixes; applies mtime), and `cancel`. `v1` routes return 404. |
| Discovery | UDP `224.0.0.167:53317` with SO_REUSEADDR and SO_REUSEPORT, joined on every IPv4 interface, TTL 32, loopback on. The announcement goes out 3 times (at 100 ms, 500 ms and 2 s). Announcements are answered with `POST /register`, falling back to a multicast reply with `announce:false`. HTTP fallback scans each /24 (at most 50 at once, 1 s timeout). Peers expire after 60 s. |
| Client | `URLSession` with a delegate that accepts self-signed certificates, used only for these endpoints. `SlipSender` streams up to 3 uploads in parallel from disk, reports progress, sends `cancel` when its task is cancelled, and handles 204, 401 (PIN), 403, 409 and 429. Folders are sent as relative paths (`Album/2024/a.jpg`). |
| UI state | `SlipController` (`@MainActor @Observable`) owns the server, discovery and sends. It exposes peers, the pending request (accept or decline), transfers with per-file progress, messages and the PIN prompt. Settings are saved as JSON in `UserDefaults`. |

### Build and test

```sh
cd apple/SlipKit
swift build
swift test        # 26 tests: JSON, sanitising, alias, fingerprint, loopback HTTPS/HTTP end-to-end
```

### slip-cli

```sh
BIN=$(swift build --show-bin-path)/slip-cli
$BIN receive --port 53320 --dir ~/Downloads/slip --auto-accept [--http] [--pin 1234]
$BIN send --to 192.168.1.20:53317 [--http] [--pin 1234] [--text "hi"] [--sha256] file.jpg Folder/
$BIN discover [--port 53320] [--timeout 5] [--scan --scan-port 53317]
$BIN info --to 127.0.0.1:53317
$BIN register --to 127.0.0.1:53317 --port 53320
```

Without `--auto-accept`, `receive` asks `accept? [y/N]` on stdin. The CLI keeps its identity in
`cli-identity.json`, separate from the app's, so the CLI and the app can see each other on one Mac.

## Apps

```sh
brew install xcodegen      # if needed
cd apple
xcodegen                   # writes Slip.xcodeproj (git-ignored)
open Slip.xcodeproj        # schemes: Slip-macOS, Slip-iOS

# Command-line builds without signing (what CI runs):
xcodebuild -project Slip.xcodeproj -scheme Slip-macOS -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Slip.xcodeproj -scheme Slip-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

To run on a device, or to get a sandboxed macOS build, set your team under
*Signing & Capabilities* for each target.

Launch arguments for development (not saved): `-SlipPort 53322 -SlipQuickSave YES -SlipAlias "Test"`.
They let you run several instances on one machine.

### Releasing the Mac app

Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, then run
`scripts/release-mac.sh publish`. It runs the SlipKit tests, archives a universal (Apple silicon +
Intel) build, signs it with Developer ID, notarizes and staples it, and packages
`Slip-<version>.dmg`, `Slip.dmg` (the same file, for the stable latest-download link the site
uses), `Slip-<version>.zip` and `SHA256SUMS.txt` into `build/mac-release/dist`. With `publish` it
also tags `v<version>` and creates the GitHub release. Signing uses the Apple account signed in to
Xcode, so it runs locally rather than in CI.

The DMG opens to a custom installer window (branded background, Slip and an Applications shortcut
side by side, the Slip volume icon), built with [dmgbuild](https://github.com/dmgbuild/dmgbuild),
which the script installs into `build/.venv`. The layout lives in `Resources/dmg/settings.py`; the
background is drawn by `swift scripts/make-dmg-background.swift` (add `--preview light|dark` to
check it with mock icons and labels).

### macOS

- A window with a sidebar (Receive, Send, Transfers, Settings), plus nearby devices that accept dropped files.
- Send tab: an `NSOpenPanel` for files and folders, text, paste (files, image or text), and drag and drop onto the tray or onto a device. You can also enter an IP address by hand.
- Incoming transfers open a sheet with a file list you can toggle, the total size, and Accept or Decline. The window comes forward and a user notification is posted.
- Transfers tab: progress, speed, open, and Show in Finder.
- A menu bar extra, which you can turn off: status, Send Files To, Quick Save toggle, Open, and Quit. While it is on, Slip keeps receiving after the window closes.
- Sandbox entitlements: `network.client`, `network.server`, `files.user-selected.read-write` and `files.downloads.read-write`. A custom save folder is kept as a security-scoped bookmark.
- macOS 15+ asks for Local Network access the first time the app runs. Multicast discovery does not work until you allow it.

### iOS

- A `TabView` with Receive, Send, Transfers and Settings.
- Send tab: `PhotosPicker` (photos and videos are exported to temporary files, not loaded into memory), `fileImporter` for files or a folder, text, and paste.
- Files are saved to the app's Documents folder. `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` make them appear under *Files › On My iPhone › Slip*. Received files can be previewed with Quick Look and shared.
- `NSLocalNetworkUsageDescription`, `NSBonjourServices` and `NSAllowsLocalNetworking` are set.
- "Open in… Slip" from other apps adds the file to the send tray.
- **Multicast entitlement:** since iOS 14, Apple has to approve `com.apple.developer.networking.multicast`
  for your team ([request form](https://developer.apple.com/contact/request/networking-multicast)) before
  it can be signed into a profile, so the default `App/iOS/Slip.entitlements` leaves it out and device
  builds work out of the box. Once approved, build with
  `CODE_SIGN_ENTITLEMENTS=App/iOS/Slip-Multicast.entitlements`. Without it, multicast send and receive
  fail quietly, and discovery still works through the **HTTP /24 scan fallback**. The scan runs
  automatically when no peers have appeared after about 4 s, and again whenever you tap Refresh.
  LocalSend peers that see our `/register` calls also add us to their lists.
- iOS suspends apps in the background, so Slip only receives while it is in the foreground. It asks
  for extra background time to finish transfers already in progress, and restarts its sockets when it
  becomes active again.

## Known limitations

- The download API (LocalSend §5, `prepare-download` and the browser download page) is not
  implemented, and we advertise `download: false`.
- No Share Extension yet.
- Certificate pinning (`sha256(peer cert) == fingerprint`) is not enforced. Self-signed peers are
  accepted, as the spec requires.
- The private key is stored in a file in Application Support (mode 0600), not in the Keychain.
