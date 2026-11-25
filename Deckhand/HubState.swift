import AppKit
import DeckhandCore
import SwiftUI

/// Which device the Deckhand window shows; set by the popover when it hands over.
@MainActor
@Observable
final class HubRouter {
    private static let key = "hubSelection"

    /// Remembered between launches.
    var selection: String? = UserDefaults.standard.string(forKey: HubRouter.key) {
        didSet { UserDefaults.standard.set(selection, forKey: Self.key) }
    }
}

/// A build to install, arriving through an `expo-orbit://` or `deckhand://` link.
@MainActor
@Observable
final class InstallRequestCenter {
    static let shared = InstallRequestCenter()

    var pending: InstallRequest?
    /// Bumped on every link so the menu bar label can open the window.
    private(set) var openCount = 0

    func receive(_ request: InstallRequest) {
        pending = request
        openCount += 1
    }

    /// `deckhand://hub` just opens the window.
    func showWindow() {
        openCount += 1
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set when the window first opens; capturing only starts from there.
    @MainActor static var network: NetworkViewModel?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // helpers a killed or crashed earlier run left behind (log streams, mirrors) would keep running for ever
        ChildProcesses.shared.reapOrphans()
        // a plain `kill` or a stopped debug session would otherwise skip applicationWillTerminate
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Self.cleanUp()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// The camera is injected into the simulator's launchd environment, and the helpers are separate processes:
    /// neither may outlive the app.
    func applicationWillTerminate(_ notification: Notification) {
        Self.cleanUp()
    }

    private static func cleanUp() {
        VirtualCameraViewModel.disarmForQuit()
        // the Mac's proxy settings and the Android devices must not keep pointing at a proxy that is gone
        MainActor.assumeIsolated { network?.restoreAndroidForQuit() }
        NetworkViewModel.restoreSystemProxyForQuit()
        ChildProcesses.shared.terminateAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "deckhand", url.host == "hub" {
                Task { @MainActor in InstallRequestCenter.shared.showWindow() }
                continue
            }
            guard let request = InstallLink.parse(url) else { continue }
            Task { @MainActor in InstallRequestCenter.shared.receive(request) }
        }
    }
}

/// Menu bar icon. It lives as long as the app, so it is where link-triggered windows get opened.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Preferences.menuBarIndicatorKey) private var indicator = MenuBarIndicator.iconAndCount
    let center: InstallRequestCenter
    let list: DeviceListViewModel
    let router: HubRouter
    @State private var tray: TrayMenu?

    private var running: Int { indicator == .never ? 0 : list.runningDevices.count }

    var body: some View {
        HStack(spacing: 3) {
            // the glyph with waves is drawn in the same template colour as the plain one, so it follows the menu bar's tint
            Image(systemName: running > 0 ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
            if indicator == .iconAndCount, running > 0 { Text("\(running)") }
        }
        .onChange(of: center.openCount) { _, _ in showWindow() }
        .task { installTrayMenu() }
        .task(id: indicator) {
            // the popover refreshes the list only while it is open; the indicator needs it up to date all the time
            guard indicator != .never else { return }
            while !Task.isCancelled {
                await list.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "hub")
    }

    private func installTrayMenu() {
        let actions = TrayMenu.Actions(
            devices: { list.runningDevices },
            stoppedDevices: { (list.iosDevices + list.androidDevices).filter { $0.state == .stopped } },
            startInDeckhand: { device in
                Task { await list.perform(.startHeadless, on: device) }
                router.selection = device.id
                showWindow()
            },
            openHub: { deviceId in
                if let deviceId { router.selection = deviceId }
                showWindow()
            },
            refresh: { Task { await list.refresh() } },
            openSettings: {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            })
        if let tray {
            tray.update(actions)
        } else {
            let menu = TrayMenu(actions: actions)
            menu.install()
            tray = menu
        }
    }
}
