# Slip for Linux

Native Linux client for Slip, written in Rust with GTK 4 and libadwaita. It speaks the
[LocalSend v2 protocol](../protocol/localsend-v2.md) and follows
[`protocol/IMPLEMENTATION.md`](../protocol/IMPLEMENTATION.md), so it works with
LocalSend and with every other Slip client.

```
linux/
├── Cargo.toml              workspace
├── crates/
│   ├── slip-core/          protocol core, no GTK: models, identity, discovery, server, client
│   ├── slip-cli/           headless `slip-cli` binary (receive / send / discover)
│   └── slip-gtk/           the GTK 4 + libadwaita app (binary: `slip`)
└── data/                   .desktop, AppStream metainfo, icon, Flatpak manifest
```

## Requirements

- A recent stable Rust toolchain with cargo (developed with 1.99)
- GTK ≥ 4.12 and libadwaita ≥ 1.5 (GNOME 46 or newer: Ubuntu 24.04, Fedora 40, Debian 13, Arch)
- A C compiler and pkg-config, which `ring` and the `*-sys` crates need

`slip-core` and `slip-cli` don't need GTK.

| Distro | Install |
|---|---|
| Ubuntu / Debian | `sudo apt install build-essential pkg-config libgtk-4-dev libadwaita-1-dev` |
| Fedora | `sudo dnf install gcc pkgconf-pkg-config gtk4-devel libadwaita-devel` |
| Arch | `sudo pacman -S base-devel gtk4 libadwaita` |
| openSUSE | `sudo zypper install gcc pkgconf gtk4-devel libadwaita-devel` |

## Build and run

```sh
cd linux
cargo run -p slip-gtk              # the app (runs uninstalled)
cargo run -p slip-cli -- --help    # the CLI
cargo test --workspace             # unit + end-to-end loopback tests
cargo build --release              # target/release/{slip,slip-cli}
```

### libadwaita feature levels

The app builds against libadwaita 1.5. You can turn on newer widgets with crate
features:

```sh
cargo run -p slip-gtk --features adw_1_6   # AdwSpinner instead of GtkSpinner
```

## Install (without Flatpak)

```sh
cd linux && cargo build --release -p slip-gtk
install -Dm755 target/release/slip ~/.local/bin/slip
install -Dm644 data/io.github.nearbycoder.Slip.desktop ~/.local/share/applications/io.github.nearbycoder.Slip.desktop
install -Dm644 data/io.github.nearbycoder.Slip.metainfo.xml ~/.local/share/metainfo/io.github.nearbycoder.Slip.metainfo.xml
install -Dm644 data/icons/hicolor/scalable/apps/io.github.nearbycoder.Slip.svg \
  ~/.local/share/icons/hicolor/scalable/apps/io.github.nearbycoder.Slip.svg
```

For a system-wide install, use `/usr/local` (or `/usr`) in place of `~/.local`.

## Flatpak

Run this from the repository root, not from `linux/`:

```sh
flatpak install flathub org.gnome.Platform//47 org.gnome.Sdk//47 \
    org.freedesktop.Sdk.Extension.rust-stable//24.08
flatpak-builder --user --install --force-clean build-dir linux/data/io.github.nearbycoder.Slip.yml
flatpak run io.github.nearbycoder.Slip
```

The manifest grants `--share=network` and `--filesystem=xdg-download`. Any other save
folder is chosen through the file chooser portal. Cargo downloads crates during the
build. For Flathub, generate `cargo-sources.json` with
[flatpak-cargo-generator](https://github.com/flatpak/flatpak-builder-tools/tree/master/cargo)
from `linux/Cargo.lock` and use it in place of the network build arg.

## Firewall

Peers have to reach TCP and UDP port **53317**, or whatever port you set:

```sh
sudo firewall-cmd --add-port=53317/tcp --add-port=53317/udp --permanent && sudo firewall-cmd --reload   # Fedora
sudo ufw allow 53317                                                                                   # Ubuntu
```

## CLI

`slip-cli` is a headless client for scripting and for interop tests between cores. By
default it uses a throwaway identity. Pass `--config-dir` to keep one.

```sh
slip-cli receive --port 53317 --dir ~/Downloads --auto-accept [--http] [--pin 1234] [--once]
slip-cli send --to 192.168.1.20:53317 [--http] [--pin 1234] photo.jpg ~/Documents/folder
slip-cli send --to 192.168.1.20 --text "hello"
slip-cli discover [--timeout 5] [--scan [--scan-port 53317]]
```

Without `--auto-accept`, `receive` asks y/N on the terminal. Without `--pin`, `send`
prompts for a PIN when the receiver requires one.

## Where things live

- Settings: `$XDG_CONFIG_HOME/slip/settings.json` (`~/.config/slip/`). Override the
  directory with `SLIP_CONFIG_DIR`.
- Identity: `cert.pem`, `key.pem` (mode 0600) and `http-fingerprint` in the same directory.
- Received files: XDG Downloads by default. You can change it in Preferences.

## Architecture notes

- **Threads:** a multi-threaded tokio runtime does all networking. The GTK thread enters
  the runtime context, receives `slip_core::Event`s through an `async-channel` in
  `glib::spawn_future_local`, and awaits tokio `JoinHandle`s from the GLib main loop.
- **Server:** axum + axum-server with rustls (ring provider). Uploads stream to
  `<saveDir>/.slip-partial-*` and are then renamed into place. The server checks sha256
  when the sender provides one, applies `metadata.modified` as the mtime, and sanitises
  every path.
- **Incoming transfers:** `prepare-upload` stays open until the UI calls
  `IncomingRequest::respond` (backed by a oneshot), or answers 403 after 60 s.
- **Discovery:** socket2 with `SO_REUSEADDR` and `SO_REUSEPORT`. It joins the group on
  every IPv4 interface and announces 3 times (100 ms, 500 ms, 2 s). It answers peers via
  `POST /register` and falls back to UDP. A `/24` HTTP scan runs on refresh, and
  automatically when no peers show up.
- **Client:** reqwest with rustls, accepting self-signed certificates. It runs up to 3
  parallel streamed uploads with progress and cancel.
