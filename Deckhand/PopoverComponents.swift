import AppKit
import DeckhandCore
import SwiftUI

/// A row that looks and behaves like an item of a menu: highlighted under the pointer, with its key on the right.
struct MenuRow: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small icon button of the popover's header, with a hover background.
struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .background(hovering ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The windows a simulator or an emulator opens by itself.
enum DeviceWindows {
    /// Brings the Simulator app or the emulator to the front; false when there is no window to show (a device started
    /// without one).
    @MainActor
    static func bringToFront(_ device: Device) -> Bool {
        switch device.platform {
        case .ios:
            for identifier in SimulatorHost.bundleIdentifiers {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    return true
                }
            }
            return false
        case .android:
            // the emulator is a qemu process with its own window; one started with -no-window shows no window
            let emulator = NSWorkspace.shared.runningApplications.first {
                let name = $0.executableURL?.lastPathComponent ?? $0.localizedName ?? ""
                return name.contains("qemu") || name.contains("emulator")
            }
            return emulator?.activate() ?? false
        }
    }
}
