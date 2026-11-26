# Deckhand guide

Everything Deckhand does, in detail. The [README](../README.md) has the short version.

## Install with Homebrew

```bash
brew tap ossappscollective/deckhand https://github.com/ossappscollective/deckhand
brew install --cask deckhand
```

The cask is `Casks/deckhand.rb` in this repository, and the release workflow rewrites it with the new version and checksum after each release. Upgrade with `brew upgrade --cask deckhand`.

## Requirements

- macOS 26 or later
- Xcode (for `xcrun simctl` — iOS section)
- Android SDK with `emulator` and `platform-tools` (Android section)

> [!IMPORTANT]
> Each platform section degrades independently. No Xcode? The iOS section shows a hint while Android keeps working — and vice versa. Neither toolchain is required for the app to launch.

## Usage

1. Click the phone icon in the menu bar
2. Press ▶ to boot a device, ■ to stop it
3. The ⋯ menu holds **Cold Boot** and **Erase / Wipe Data**
4. The panel auto-refreshes every 5 seconds while open
5. Set a custom Android SDK path via **Settings** in the footer

### Device tools

Click a device to open its page, or open its **⋯** menu for the quick actions (start without/with sound, cold boot, wipe, screenshot, recording, appearance) or **Manage…** for the rest. Nothing is queried when a menu opens: the installed-app list is fetched only when you expand **Apps**, and the new-device form loads its options only when it opens.

| Tool | iOS | Android |
| --- | --- | --- |
| Screenshot / record | `simctl io` | `screencap` / emulator console `screenrecord` |
| Dark / light | `simctl ui appearance` | `cmd uimode night` |
| Open URL | `simctl openurl` | `am start -a VIEW` |
| Install | `simctl install` | `adb install -r`; `.aab` / `.apks` through `bundletool` (`brew install bundletool`) |
| Apps | `simctl listapps`, launch, terminate, uninstall, show data folder | `pm list packages`, launch, force-stop, uninstall, clear data |
| Location | `simctl location` | `emu geo fix` |
| Extras | clean 9:41 status bar | rotate, animations, show taps, reboot, shell |
| Logs | `log stream` in a terminal | `logcat` in a terminal |

Shell and Logs open in the terminal chosen in Settings → Terminal: Terminal, iTerm2, Ghostty, kitty, WezTerm, Alacritty, Warp, or any other app that opens a `.command` file.

Install accepts a local file or an `http(s)` URL; archives (`.tar.gz`, `.zip`) are unpacked and the `.app` inside is installed. Screenshots and recordings go to the folder set in Settings (default: Desktop).

### Deckhand window

The window icon in the panel header (or **Open in the Deckhand window** on a device page) opens the hub. Select a device in the sidebar; the middle column shows its live screen and the right column holds the same tools as the panel. The **Mirror** toolbar button hides the middle column; the **Tools** button hides the right one. The two columns share the window: resizing it scales both, and the edge between them can be dragged. Showing or hiding a panel (the sidebar, the mirror, the tools column or the log panel) resizes the window to the width where the picture keeps its size, with the height and the top-left corner staying. With the sidebar and the tools column both hidden and a portrait picture, dragging a corner keeps the picture's shape; dragging an edge, a landscape picture or a window with panels resizes freely. The picture keeps its shape, with bars where the column is not the same shape. The button strip under the picture keeps navigation, power, rotate and screenshot; the engine, the device's own window and recording are in its **…** menu.

| Device | Mirror | Input |
| --- | --- | --- |
| Android emulator / phone | scrcpy's server when scrcpy is installed (low latency, live touch and drag); otherwise the H.264 stream of `screenrecord`. The pane shows which engine is active | click, drag and swipe, Back / Home / Overview / volume / power buttons |
| iOS Simulator | Baguette's H.264 stream at up to 60 fps (screenshot polling when Baguette is not installed) | click, drag, swipe, keyboard, Home / App Switcher / Lock buttons, through Baguette (`brew install baguette`) |
| iPhone / iPad | macOS capture of the USB-connected device (needs camera permission and a cable) | none |

`brew install scrcpy` switches the window to scrcpy's server automatically (Deckhand talks to it directly, no scrcpy window opens). **Tools → scrcpy** still opens scrcpy's own window. While the window is open Deckhand also shows in the Dock.

**Start headless.** In the Deckhand window, **Start** boots the device without a window of its own, because the mirror is the screen: an emulator runs with `-no-window`, and a simulator is booted without opening the Simulator app. **Start with Window** (in the mirror, the sidebar menu and the Device menu) opens the Simulator app or the emulator's own window as well. In the popover, a device's **…** menu has **Start in Deckhand** (headless, and the Deckhand window opens on it), **Start in Background** (headless, nothing opens) and **Start with Simulator/Emulator Window**. Capturing in the Network panel stops by itself when its device stops.

**Device and Panels menus.** They work on the selected device whether it is a simulator or an emulator, and use the Simulator's shortcuts where it has one:

| Shortcut | Action |
| --- | --- |
| ⇧⌘H | Home |
| ⌃⌘H | App Switcher |
| ⌘[ | Back (Android) |
| ⌘L | Lock / power |
| ⌥⌘↑ / ⌥⌘↓ | Volume up / down |
| ⌘← / ⌘→ | Rotate left / right (Android; simulators need Baguette) |
| ⇧⌘A | Toggle dark mode |
| ⌥⌘= / ⌥⌘- | Larger / smaller text |
| ⌘S | Screenshot (saved, and shown in the Finder) |
| ⌃S | Screenshot with Thumbnail: a thumbnail slides in at the bottom right of the screen like macOS's own screenshot tool. The picture is not saved to the capture folder; its file is in a temporary folder (kept 3 days). Drag it into any app or folder, click it to open the file, swipe it to the right or wait a few seconds to send it away, right-click for Save (to the capture folder), Show in Finder, Copy and Move to Trash |
| ⌥⌘R | Start / stop recording |
| ⌥⌘1 … 4 | Show the mirror, logs, network, tools |

### Logs

The **Logs** toolbar button opens the selected device's log at the bottom of the right panel: `adb logcat` for Android emulators and phones, `log stream` for simulators (a real iPhone has no log stream Apple exposes outside Console.app). Drag the bar above it to resize, or use the expand button to give the log the whole right panel and hide the tools.

- Search by text or regular expression (matches message, tag and app) and filter by minimum level.
- **Apps:** the target button shows only the app in the foreground (`dumpsys` on Android, the accessibility root through Baguette on simulators). The Apps button opens a bounded, alphabetical picker with your own apps first and everything seen in the log below; Android apps include their other processes. Right-click a line to show or hide its app.
- **Per device:** each device remembers its own filter, also across launches.
- **Columns:** drag a header to reorder, drag its right edge to resize, right-click the header to hide columns (including PID, hidden by default), pick a shorter time format or reset.
- **Only while open:** nothing is read from the device until the panel is open, and closing it (or hiding the right panel, closing the window or stopping the device) ends the `logcat` / `log stream` process.
- **Following:** a newly opened panel starts at the end and follows it; at the end of the list new lines keep it there; scroll up and the view stays exactly where you are. The arrow button jumps back and follows again.
- **Selecting and copying:** click a line, Shift-click to extend, Command-click to toggle, Command-A for all. Cmd+C or the context menu copies the selected lines with line breaks; *Copy Messages* copies only the messages, also one per line. The copy button in the header copies everything visible.
- Pause keeps collecting without scrolling. The buffer holds 50,000 lines by default; Settings → Logs changes it (5,000 to 500,000).

### Network

The **Network** toolbar button (or the Logs/Network switch in the panel header) shows the HTTP and HTTPS requests of the selected simulator or Android device, in the spirit of Proxyman and HTTP Toolkit.

- Capture belongs to each device: **Capture** and **Stop** act on the selected device only, and switching device keeps the others capturing. Devices that are capturing have a red record button in the sidebar; click it to stop that device. The proxy runs while any device captures and stops (and puts the Mac's proxy settings back) with the last one. The log, in contrast, only streams the device that is shown.
- **Capture** starts Deckhand's own proxy (port 8899, or a free port when that one is taken; Settings → Network sets a fixed one). **Set Up** does what the device needs: it trusts Deckhand's certificate (`simctl keychain add-root-cert` on a simulator; the system store on a rootable Android emulator, otherwise the user store plus a pointer to the security settings) and points the device at the proxy (the macOS web proxy for simulators; `adb reverse` and the global proxy setting for Android).
- While capturing, other apps on the Mac are passed through untouched and are not recorded. Apple hosts are tunnelled, not decrypted. The macOS proxy settings are put back when you stop, quit, or relaunch after a crash.
- Click a request for Headers, Request, Response (Preview or Raw: pretty JSON, images, text, hex) and Timing. Right-click for Copy URL, Copy as cURL, headers and bodies, and Save Response.

- **Android helper app:** Set Up installs a tiny Kotlin app (`DeckhandHelper/`, about 70 KB, package `com.deckhand.helper`) and turns on its automatic mode over `adb` (Deckhand pre-approves the VPN with `appops`, so no dialog). From then on it follows Deckhand by itself: while Deckhand is capturing, `adb reverse` lets the helper reach the proxy and it connects its VPN; when capturing stops the VPN is taken down again. Its screen shows Waiting for Deckhand, Connecting, Connected, Allow the VPN or Off. The VPN carries no traffic itself: it gives the device a network whose HTTP proxy is Deckhand, so apps that respect the system proxy use it. Stop Routing turns the helper off. Without the bundled APK the global proxy setting is used instead. The APK is not in git: releases build it in the workflow, and `DeckhandHelper/build.sh` (JDK 17 or 21, Android SDK 36) builds it for a local run and puts it at `Deckhand/DeckhandHelper.apk`. It is signed with a debug key; Deckhand reinstalls it when the key on the device differs. Bump `versionCode` in `DeckhandHelper/app/build.gradle.kts` and `DeviceProxySetup.helperVersion` together when the app changes: devices with an older one get the new build.
- **iPhone and iPad** (USB or not, on the same Wi-Fi as the Mac): Set Up makes the proxy listen on the local network and shows what to do on the phone: Wi-Fi › Configure Proxy › Manual with the Mac's address and port, then open `http://deckhand.proxy` in Safari to download the certificate, install it, and trust it in Settings › General › About › Certificate Trust Settings. Anyone on that Wi-Fi can use the proxy while it listens there; Stop Routing closes it. The same page works for the Android browser.

When an app rejects the Deckhand certificate, that host is passed through untouched from then on (shown as a tunnel), so the app keeps working after its first failed request; installing the certificate again lifts this.

On Android, apps that target Android 7 or later ignore the user certificate store, so only the system store decrypts them all. That needs an emulator image that allows `adb root` (AOSP or Google APIs, not Google Play). Deckhand reads the device's state and says so in the setup popover, in a banner above the list ("System trust disabled" with a Trust System-Wide button when the image allows root), and in the helper app. The system certificate lasts until the device restarts. Set Up also puts it in the apps that are already running, and checks that new apps see it.

Limits: HTTP/1.1 only (HTTP/2 and gRPC apps may fail), WebSocket frames are not shown, apps that pin certificates cannot be decrypted, Android apps only trust the user store if they opt in.

### Slow network

The **Network** menu of the Network panel slows the selected device down, with the Network Link Conditioner presets (Wi-Fi, LTE, 3G, Edge, Very Bad Network, Offline) or a custom latency, download and upload speed. An Android emulator is slowed by the emulator itself (`adb emu network speed` and `delay`, airplane mode for Offline), so all its traffic is affected and it works without capturing. Simulators and phones are slowed through the proxy: every request pays the latency, the transfer is limited to the speed, and Offline fails each connection (recorded as a failed request). That needs capturing, so choosing a speed starts it for that device (the sidebar shows the red record button) and a message says so; choosing No Limit ends it again, unless you started the capturing yourself, and stopping the capture ends the slowdown. Only traffic that goes through the macOS proxy is slowed: apps that ignore the system proxy or use raw sockets are not. The menu shows the active preset in orange. The **Network** section of the tools panel has the same presets and custom values, for a device whose Network panel is closed.

### Keyboard, clipboard and drag & drop

- **Keyboard** (Android): click the picture and type. Text, Return, Delete, Tab, arrows and Esc (Back) go to the device; Cmd+C / X / A / V copy, cut, select all and paste. With the adb fallback engine only typing and special keys work.
- **Clipboard**: while a mirror is open the Mac and the device clipboards are kept in sync (scrcpy engine for Android, `simctl pbsync` for simulators). Settings → Mirror turns it off.
- **Drag & drop** files or folders on the window. Android: `.apk` / `.aab` / `.apks` install, everything else (folders included) is copied to `Download`. Simulators: `.app` / `.tar.gz` / `.zip` install, photos and videos go to the Photos library, everything else (folders included) lands in Files › On My iPhone. iPhones and iPads: `.ipa` / `.app` install; Apple gives no way to copy arbitrary files to a real device.
- Simulators: touch, swipe, typing (non-ASCII is pasted) and Cmd+C / V / A / X work through [Baguette](https://github.com/tddworks/baguette)'s `baguette input`, which uses the private SimulatorKit input surface Apple does not expose. Without Baguette the picture is view-only. On Xcode 27 the first connection runs `baguette heal` (restarts SpringBoard) so Device Hub does not swallow the touches. **Open Simulator** jumps to the real host app.

### Virtual camera for iOS simulators

A simulator has no camera. **Camera** (simulator page) feeds a Mac webcam, a still image or a looping video to the camera of any app launched afterwards, so scanners, photo capture and viewfinders can be tested.

1. `brew install baguette` once. Deckhand uses [Baguette](https://github.com/tddworks/baguette)'s `VirtualCamera.dylib` (it fakes the camera inside the app); Deckhand supplies the frames and arms it in the simulator.
2. Pick a source and press **Start Camera**.
3. **Relaunch the app** (Apps → ⋯ → **Relaunch**): the library is only loaded when an app starts.
4. **Stop Camera** removes it again, and so does quitting Deckhand. Only one camera can run at a time on the Mac, and Deckhand and Baguette cannot both run one.

Limits (they come from the library): no audio, and no barcode metadata objects are synthesised, so apps that scan through `AVCaptureMetadataOutput` see the picture but detect nothing.

### Physical devices

Shown in their own section (Settings → Physical devices turns it off). Android phones need USB debugging enabled and authorised; iPhones and iPads must be paired in Xcode. Real devices have no start/stop, no emulator console and no simulator switches, so only the tools that make sense are offered: install, apps, screenshot, logs, shell, reboot (Android), recording (iOS).

### Install links

`expo-orbit:///download?url=https://…` and `deckhand://install?url=https://…` open the window with a confirmation sheet listing the running devices that can take the build (`.apk`, `.apks` or `.aab` for Android, `.tar.gz` for simulators, `.ipa` for iPhones). Nothing is downloaded until you press **Download & Install**. `deckhand://hub` just opens the window. Expo Orbit registers the same `expo-orbit` scheme; choose who gets the links in Settings → Install links.

### Android hardware options

When creating an emulator, **Advanced options** sets memory, CPU cores, internal storage, SD card, VM heap, screen density, graphics mode, device frame (bezel), hardware keyboard, cold-boot behaviour, cameras and orientation. They are written to the AVD's `config.ini`. The same form is under **Manage → Device → Edit Hardware…** for stopped emulators.

### Launch options (Android)

In **Settings → Emulator launch**:

- **Start without sound** adds `-no-audio` to every start, cold boot and wipe. The device menu then offers **Start with Sound** for a single launch; with the option off it offers **Start without Sound**.
- **Extra arguments** are appended to every launch, e.g. `-gpu host -no-boot-anim`.

### Virtual devices

The **+** button in each section creates a device. iOS uses the installed runtimes and device types; Android uses the system images already installed in your SDK together with `avdmanager` (found under `cmdline-tools`, run with Android Studio's bundled Java when `JAVA_HOME` is not set). Rename, clone and delete live under **Manage… → Device** and require the device to be stopped.

| Action | iOS | Android |
| --- | --- | --- |
| Start | `simctl boot` + opens the simulator host app | `emulator -avd` |
| Stop | `simctl shutdown` | `adb emu kill` |
| Cold Boot | shutdown → boot | restart with `-no-snapshot-load` |
| Erase / Wipe | `simctl erase` | restart with `-wipe-data` |

## Architecture

All device logic lives in `DeckhandCore`, a local Swift package with full unit test coverage (parsers and services tested against real CLI output fixtures). The app target contains only SwiftUI views.

```bash
cd DeckhandCore
swift test
```

## Menu bar icon

Click it for the device popover. Right-click (or control-click) it for a menu: **Open Deckhand**, the running simulators and emulators (choose one to open the window on it), **Refresh Devices**, **Settings…**, **About Deckhand** and **Quit Deckhand**.

The icon shows when something is running: the phone gets radio waves, and the number of running simulators and emulators appears beside it. It follows the menu bar's own tint, so it looks right on any wallpaper. **Settings → General → Menu bar** switches the number off or turns the indicator off. With the indicator on, Deckhand checks the device list every 5 seconds in the background even when the popover is closed; with it off, only while the popover is open.

### The popover

It follows the system's own menus: a round badge per device, filled green while it is running, controls under the pointer, and Settings and Quit as menu rows. **Click** a device to open it, **double-click** to open it the other way. By default a click opens it in the Deckhand window (a stopped device is started headless first) and a double-click in the Simulator app or the emulator's own window (a stopped device is started with it). **Settings → General → Menu bar → Clicking a device in the popover opens** swaps the two. Everything else a device can do is in its **…** menu, including **Manage…**.

## Missing optional tools

scrcpy, Baguette and bundletool are open source programs that Deckhand uses when they are installed. When you ask for something that needs one that is missing, a **How to install** (or **Install …**) button opens a popover with what the tool gives you, a link to its project and the `brew install` command to copy. Android still mirrors without scrcpy, through adb, and a simulator is view-only without Baguette.

## FAQ

**No iOS simulators listed?** Make sure Xcode is installed and `xcrun simctl list devices` works in a terminal.

**No Android emulators listed?** Deckhand looks for the SDK at `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`. Set the path manually in Settings if yours lives elsewhere.

**A device stays "Booting…" for a while?** Android emulators take 30-60 s to register with `adb` after launch. The dot turns green as soon as the device reports in.

**Does it phone home?** No. Deckhand makes no network requests of its own; the only download is the one you trigger with *Install App → URL*.
