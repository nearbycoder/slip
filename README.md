<p align="center"><img src="assets/icon.svg" width="112" height="112" alt="Slip"></p>

<h1 align="center">Slip</h1>

Send files and text to nearby devices over your local network — natively on every platform,
and fully compatible with [LocalSend](https://localsend.org).

**Website:** https://nearbycoder.github.io/slip/

| Platform | Directory  | Stack                          |
|----------|------------|--------------------------------|
| macOS    | `apple/`   | Swift · SwiftUI                |
| iOS      | `apple/`   | Swift · SwiftUI                |
| Android  | `android/` | Kotlin · Jetpack Compose       |
| Windows  | `windows/` | C# · WinUI 3 (Windows App SDK) |
| Linux    | `linux/`   | Rust · GTK 4 · libadwaita      |

Every client implements the [LocalSend protocol v2](protocol/localsend-v2.md). Behaviour that
must match across clients is documented in [`protocol/IMPLEMENTATION.md`](protocol/IMPLEMENTATION.md).

The GitHub Pages site lives in [`site/`](site/) and deploys automatically from `main`.

Brand assets live in [`assets/`](assets/): `icon.svg` (app icon), `icon-full-bleed.svg` (for platforms that mask
corners themselves) and `mark.svg` (monochrome glyph). Run `assets/build-icons.sh` after changing them to
regenerate every platform's icon files.

## License

MIT
