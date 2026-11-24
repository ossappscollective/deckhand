<p align="center">
  <img src="docs/assets/icon.svg" width="112" alt="Deckhand">
</p>

<h1 align="center">Deckhand</h1>

<p align="center">
  <strong>Every simulator, emulator and test phone, on one deck.</strong><br>
  Start, mirror, inspect and control them from a native macOS app.
</p>

<p align="center">
  <a href="https://ossappscollective.github.io/deckhand/">Website</a> ·
  <a href="docs/guide.md">Guide</a> ·
  <a href="https://github.com/ossappscollective/deckhand/releases/latest">Download</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <a href="https://github.com/ossappscollective/deckhand/actions/workflows/ci.yml"><img src="https://github.com/ossappscollective/deckhand/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Swift-6-orange.svg" alt="Swift 6">
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B-blue.svg" alt="Platform macOS 26+">
  <img src="https://img.shields.io/badge/license-MIT-brightgreen.svg" alt="License MIT">
  <a href="https://github.com/ossappscollective/deckhand/releases/latest"><img src="https://img.shields.io/github/downloads/ossappscollective/deckhand/total.svg" alt="Downloads"></a>
</p>

<p align="center">
  <img src="docs/assets/hero.png" width="860" alt="Deckhand: a device list, the live mirror of an Android emulator, and the tools and network panels">
</p>

## What it is

Deckhand is a native SwiftUI app for people who build mobile apps. It lives in the menu bar for the quick things, and opens a device-hub window when you want the whole deck: the live screen of the device you pick, its tools, its logs and its network traffic, side by side. iOS Simulators, Android Emulators and physical devices sit in the same list and work the same way.

No Electron, no daemons, no telemetry. It drives `simctl`, `emulator`, `adb` and, where they exist, [scrcpy](https://github.com/Genymobile/scrcpy) and [Baguette](https://github.com/tddworks/baguette) underneath.

## Highlights

- **Mirror and control.** The live screen of any simulator, emulator or phone, with touch, keyboard, clipboard sync, drag and drop installs, and an animated rotation. The mirror and the tools share the window like Xcode's Device Hub.
- **Network inspector.** Capture the HTTP and HTTPS requests of a simulator, an Android device or an iPhone, in the spirit of Proxyman and HTTP Toolkit: search, filters, headers, bodies, timing, copy as cURL. A small Android helper app (a VPN) points the device at the proxy by itself, and Deckhand puts the certificate where apps trust it.
- **Slow networks.** Wi-Fi, LTE, 3G, Edge, a very bad network or no connection, from the Network Link Conditioner presets or your own numbers.
- **Logs.** `logcat` and `log stream` with search, levels, per-app filters and columns you can arrange.
- **Start headless.** Boot an emulator without its own window, or a simulator without opening the Simulator app, so the mirror is the only screen.
- **Shortcuts.** A Device menu with the Simulator's own keys, and the same ones on Android: Home, App Switcher, Lock, rotate, dark mode, text size, screenshot, recording.
- **Per-device tools.** Screenshots and recordings, dark mode, open a URL, install apps (`.app`, `.apk`, `.aab`, Expo and EAS builds, links), browse, launch and uninstall apps, set a location, clean status bar, a virtual camera for simulators.
- **Virtual devices.** Create, rename, clone and delete simulators and AVDs, with the advanced hardware options.
- **Light.** Native SwiftUI with no third-party dependencies. It makes no network requests of its own.

## Install

Signed and notarized builds are on the [Releases](https://github.com/ossappscollective/deckhand/releases) page.

To build it yourself:

```bash
git clone https://github.com/ossappscollective/deckhand.git
cd deckhand
DeckhandHelper/build.sh        # optional: bundles the Android helper app (JDK 17 or 21, Android SDK 36)
xcodebuild -project Deckhand.xcodeproj -scheme Deckhand -derivedDataPath build build
open build/Build/Products/Debug/Deckhand.app
```

Without the helper app, Android devices use the global proxy setting instead of the VPN. You can also open `Deckhand.xcodeproj` in Xcode and press Run.

## Requirements

- macOS 26 or later
- Xcode, for `xcrun simctl` (the iOS side)
- The Android SDK with `emulator` and `platform-tools` (the Android side)
- Optional: `brew install scrcpy` for a faster Android mirror, `brew install baguette` for touch and rotation on simulators

Each side works without the other: with no Xcode the iOS section shows a hint and Android keeps working, and the other way round.

## Using it

Click the phone icon in the menu bar, press ▶ to start a device and ■ to stop it. The **⋯** menu has Cold Boot, Wipe and the quick tools. **Open in the Deckhand window** opens the hub: pick a device in the sidebar, and use the toolbar to show the mirror, logs, network and tools. The [guide](docs/guide.md) covers every panel, the shortcuts, the network inspector and its limits.

## Architecture

All device logic lives in `DeckhandCore`, a local Swift package with unit tests (parsers and services are tested against real CLI output). The app target only holds SwiftUI views. The Android helper is a small Kotlin app in `DeckhandHelper/`.

```bash
cd DeckhandCore
swift test
```

## Contributing

Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md), and use the issue templates for bugs and feature requests.

## Acknowledgements

Deckhand began as a fork of [BootBar](https://github.com/dipendra-sharma/BootBar) by Dipendra Sharma, and keeps its MIT license. [MiniSim](https://github.com/okwasniewski/MiniSim) and [Control Room](https://github.com/twostraws/ControlRoom) explored this space first. The mirror stands on [scrcpy](https://github.com/Genymobile/scrcpy) and [Baguette](https://github.com/tddworks/baguette), and the network inspector owes its shape to [Proxyman](https://proxyman.com) and [HTTP Toolkit](https://httptoolkit.com).

## License

[MIT](LICENSE) © Dipendra Sharma and the Deckhand contributors
