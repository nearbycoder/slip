# Slip for Android

Native Android client for Slip, speaking LocalSend protocol v2 (see
[`../protocol/IMPLEMENTATION.md`](../protocol/IMPLEMENTATION.md)). Kotlin, Jetpack Compose, Material 3.

## Layout

| Module  | What it is |
|---------|------------|
| `:core` | Pure Kotlin/JVM library with no Android dependencies: models (kotlinx.serialization, lenient), identity (RSA-2048 + self-signed X.509 via BouncyCastle, SHA-256 fingerprint, alias generator), multicast discovery + HTTP `/24` scan, a small dependency-free HTTP/1.1 + TLS server (`MiniHttpServer`) with the receive state machine (`ReceiveController`), and an OkHttp sender (`SlipClient`, `Sender`). `SlipNode` wires it all together and exposes state as `StateFlow`s. File I/O goes through `ReceiveStorage` / `SendSource` so the app plugs in MediaStore and SAF. |
| `:cli`  | Headless JVM harness for interop testing (`receive`, `send`, `discover`, `info`, `register`). |
| `:app`  | The Android app: foreground service (`connectedDevice`, plus `dataSync` while transferring) keeping the server and discovery alive with a Wi-Fi multicast lock, Compose UI (Receive / Send / Transfers / Settings), incoming-transfer dialog and high-priority notification with Accept/Decline, Photo Picker / document / folder pickers, share target, text messages, saving to `Download/Slip` via MediaStore, DataStore settings. |

## Requirements

- JDK 17+ (Android Studio's bundled JBR works:
  `export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`)
- Android SDK with platform `android-37.2` (compileSdk 37.2, minSdk 26). Put `sdk.dir=…` in
  `android/local.properties` or set `ANDROID_HOME`.

## Build and test

```sh
cd android
./gradlew :core:test            # JVM unit + loopback tests (HTTPS and HTTP)
./gradlew :app:assembleDebug    # → app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:installDebug     # install on a connected device/emulator
```

## CLI

```sh
./gradlew :cli:installDist
CLI=cli/build/install/slip-cli/bin/slip-cli

$CLI receive --port 53330 --dir /tmp/slip-in --auto-accept     # add --http for plain HTTP, --pin 1234 to require a PIN
$CLI send --to 127.0.0.1:53330 file.bin some-folder/           # add --http, --pin, or --text "hello"
$CLI discover --seconds 5 [--scan]                             # multicast (+ optional /24 HTTP scan)
$CLI info --to 127.0.0.1:53317                                 # GET /info
$CLI register --to 127.0.0.1:53317                             # POST /register with our DeviceInfo
```

Or without installing: `./gradlew :cli:run --args="receive --port 53330 --dir /tmp/slip-in --auto-accept"`.
Identity is stored in `~/.config/slip-jvm-cli` (override with `--state DIR`); `--verbose` logs internals.

## Emulator tips

The emulator sits behind NAT, so multicast from the host does not reach it. Use port forwarding:

```sh
adb forward tcp:53334 tcp:53317          # host → app:   slip-cli send --to 127.0.0.1:53334 …
adb reverse tcp:53336 tcp:53330          # app → host:   "Send to IP address" 127.0.0.1:53336
```

## Notes

- HTTPS uses the persisted self-signed certificate; clients accept any certificate (LocalSend peers never have
  CA-issued ones). Cleartext is allowed for peers in HTTP mode (`network_security_config.xml`).
- Received files are written as pending MediaStore entries and published on commit; on Android 8–9 they go to the
  public `Download/Slip` directory (with storage permission) or the app's own Downloads directory.
