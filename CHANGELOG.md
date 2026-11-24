# Changelog

All notable changes to Deckhand are documented here.

## [Unreleased]

### Added

- Network panel: capture and inspect the HTTP and HTTPS requests of iOS simulators and Android devices, with search (URL, headers, bodies, regex), method/status/app filters, headers, query parameters, request and response bodies, pretty JSON and image previews, timing, copy (URL, cURL, headers, bodies) and save response
- Built-in intercepting proxy in Swift with an on-the-fly certificate authority, and Set Up actions that trust the certificate and route the device (simulator keychain and macOS proxy, `adb reverse` and the Android proxy setting)
- Start Headless for emulators (`-no-window`) and simulators (the Simulator app stays closed), and Start and Start Headless buttons in the mirror of a stopped device
- Capturing stops by itself when the captured device stops
- Device and Panels menus with the Simulator's shortcuts (Home, App Switcher, Lock, rotate, dark mode, text size, screenshot, recording) for simulators and emulators
- Android rotation goes through the window manager (every app obeys it, and phones can rotate too) and the mirror follows the new size
- The mirror and the tools column share the window in proportion, with a draggable edge between them like Xcode's Device Hub; the window is never resized by Deckhand. The button strip keeps navigation, power, rotate and screenshot, the rest is in a **…** menu
- Rotating animates the picture; iOS simulators can be rotated too (through Baguette)
- Android rotation always locks the orientation and goes from a landscape back to portrait (a phone never turns upside down)
- Fixed: the scrcpy mirror died on the first rotation (the stream's session packet was read as video data)
- Network: slow the network down (Wi-Fi, LTE, 3G, Edge, Very Bad Network, Offline or custom): emulators through the emulator, simulators and phones through the proxy
- Network: a small Kotlin helper app (VPN) that points Android devices at the proxy; it connects when Deckhand starts capturing and disconnects when it stops, and shows its state
- Network: iPhones and iPads over Wi-Fi (the proxy listens on the network on request, `http://deckhand.proxy` serves the certificate), and a proxy port setting (automatic by default: 8899, or a free port when taken)
- Network: a host whose app rejected the Deckhand certificate is tunnelled afterwards instead of failing again
- Network: Android shows whether the certificate is trusted by every app (system store), could be (the image allows root) or cannot be (a Google Play image or production build), in the setup checklist, a dismissible banner and the helper app; the helper is updated on the device when Deckhand bundles a newer one
- Network: the Android system certificate is installed like HTTP Toolkit does, in the running apps and the zygotes, checked from the apps' point of view, and a failure is reported instead of silently falling back to the user store
- Network: the helper app has the Deckhand icon, is built in the release workflow and attached to the release, and replaces a copy signed with another key
- The log and network panels share their column, app filter and resize code
- Android: start without sound, as a global option (device menu then offers Start with Sound) and as a per-launch menu entry
- Android: extra emulator arguments applied to every start, cold boot and wipe
- Per-device tools for simulators and emulators: screenshot, screen recording, dark/light mode, open URL, install app (file, archive or URL), app list with launch/stop/uninstall, location, logs, shell, and platform extras
- Create, rename, clone (iOS) and delete simulators and Android virtual devices
- Release workflow that builds, signs, notarizes and publishes to GitHub (or uploads a build-only artifact)

- Deckhand window with a device sidebar, optional live mirror (Android via an in-app H.264 decoder, simulators via screenshots, USB iPhones via macOS capture) and a management column
- Android touch, swipe and key input from the mirror
- Physical Android and iOS devices: listing, install, apps, screenshot, logs and more
- Advanced options when creating an Android emulator (RAM, cores, storage, bezel, GPU, cameras, …) and an Edit Hardware form for existing ones
- `expo-orbit://` and `deckhand://install` links with an install confirmation
- 60 fps simulator mirror from Baguette's H.264 stream, with screenshot polling as the fallback
- Touch, keyboard and buttons for the simulator mirror through Baguette, healing Xcode 27's Device Hub input shadowing first
- Choose the terminal for Shell and Logs (Terminal, iTerm2, Ghostty, kitty, WezTerm, Alacritty, Warp or any other)
- Log panel in the Deckhand window: live logcat and simulator logs with search, regular expressions, level and app filters, pause, follow and copy, resizable or full height
- Log panel: foreground-app shortcut, a bounded app picker, per-device filters and configurable columns (reorder, resize, hide, shorter time)
- Log panel: following sticks to the end and stays put when you scroll up, multi-line selection with copy lines or messages, and a Settings → Logs buffer length
- Helper processes (log streams, mirrors, input sessions) are ended when Deckhand quits or is terminated, and the next launch reaps any a crashed run left behind
- Settings are split into General, Android and Mirror tabs so the window fits on screen
- Delete a device from its row menu, with confirmation
- scrcpy-server engine for the Android mirror (low latency, live touch and drag) with automatic fallback to `screenrecord`
- Install `.aab` and `.apks` on Android through bundletool
- The window shows a Dock icon while it is open
- Button to hide the tools panel; the window shrinks to the device screen
- Keyboard input and Cmd+C/X/A/V for the Android mirror, with automatic clipboard sync for Android (scrcpy) and simulators
- Drag and drop files and folders onto a device: install apps, add photos and videos to simulators, copy anything else to Android's Download folder or a simulator's Files app
- Virtual camera for iOS simulators (webcam, image or looping video), using Baguette's injected `VirtualCamera.dylib`, plus a Relaunch action for simulator apps

### Changed

- Renamed from BootBar to Deckhand (a fork of BootBar by Dipendra Sharma, still MIT): the app, the `DeckhandCore` package, the bundle id `com.ossappscollective.Deckhand`, the Android helper `com.deckhand.helper`, the `deckhand://` link scheme and `deckhand.proxy`. Settings and the certificate of the old name are not carried over

- Clicking a device opens its management page
- Settings are grouped into Android, emulator launch and capture sections

## [1.1] - 2026-09-16

### Added

- Menu bar panel listing iOS Simulators and Android Emulators with live state indicators
- Start, stop, cold boot, and erase/wipe actions per device
- Optimistic booting state while emulators register with adb
- Automatic simulator host quit when the last simulator stops
- Support for Xcode 27, which replaces Simulator.app with Device Hub, while keeping Xcode 26 and earlier working
- Android SDK auto-detection with manual override in Settings
- Light and dark mode panel
