import AppKit
import DeckhandCore

/// The menu a right-click (or control-click) on the menu bar icon opens. A click on the icon itself still opens the popover:
/// SwiftUI's MenuBarExtra has no menu of its own, so the right-click is caught on the status item's window.
@MainActor
final class TrayMenu {
    struct Actions {
        var devices: () -> [Device]
        var openHub: (_ deviceId: String?) -> Void
        var refresh: () -> Void
        var openSettings: () -> Void
    }

    private var actions: Actions
    private var monitor: Any?

    init(actions: Actions) {
        self.actions = actions
    }

    func update(_ actions: Actions) {
        self.actions = actions
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, event.window.map(Self.isStatusItemWindow) == true else { return event }
            let wantsMenu = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard wantsMenu, let view = event.window?.contentView else { return event }
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: view)
            return nil
        }
    }

    private static func isStatusItemWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("StatusBar")
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(item("Open Deckhand", symbol: "macwindow") { [actions] in actions.openHub(nil) })

        let running = actions.devices()
        if !running.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Running"))
            for device in running {
                let title = "\(device.name) · \(device.osVersion)"
                menu.addItem(item(title, symbol: device.platform == .ios ? "iphone.gen3" : "smartphone") { [actions] in
                    actions.openHub(device.id)
                })
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Refresh Devices", symbol: "arrow.clockwise") { [actions] in actions.refresh() })
        menu.addItem(item("Settings…", symbol: "gearshape", key: ",") { [actions] in actions.openSettings() })
        menu.addItem(.separator())
        menu.addItem(item("About Deckhand", symbol: "info.circle") { Self.showAbout() })
        menu.addItem(item("Quit Deckhand", symbol: "power", key: "q") { NSApplication.shared.terminate(nil) })
        return menu
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, symbol: String, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let item = HandlerMenuItem(title: title, keyEquivalent: key, handler: handler)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(
            string: "Start, mirror, inspect and control iOS Simulators, Android Emulators and devices.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: "github.com/ossappscollective/deckhand",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .link: URL(string: "https://github.com/ossappscollective/deckhand")!]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

/// A menu item that runs a closure when chosen.
private final class HandlerMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
