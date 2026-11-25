import DeckhandCore
import SwiftUI

/// What the Device menu can do to the device the window shows.
enum HubCommand {
    case home, appSwitcher, back, lock, volumeUp, volumeDown
    case screenshot, screenshotToCorner, toggleRecording
    case rotateLeft, rotateRight
    case toggleDarkMode, largerText, smallerText
    case start, startHeadless, stop
    case showMirror, showLogs, showNetwork, showTools
}

/// The window's answer to the Device menu: the device it shows, and how to carry a command out on it.
struct HubActions {
    var device: Device?
    var isRecording = false
    var perform: (HubCommand) -> Void

    /// Whether the device can take the command now.
    func isEnabled(_ command: HubCommand) -> Bool {
        guard let device else { return false }
        let running = device.state == .running
        let mirrors = running && (device.platform == .android || !device.isPhysical)
        switch command {
        case .home, .appSwitcher, .lock, .volumeUp, .volumeDown: return mirrors
        case .back: return mirrors && device.platform == .android
        case .screenshot, .screenshotToCorner: return running && DeviceTool.screenshot.isSupported(for: device)
        case .toggleRecording: return running && DeviceTool.startRecording.isSupported(for: device)
        case .rotateLeft, .rotateRight: return running && DeviceTool.rotate.isSupported(for: device)
        case .toggleDarkMode: return running && DeviceTool.toggleAppearance.isSupported(for: device)
        case .largerText, .smallerText: return running && DeviceTool.textSize(larger: true).isSupported(for: device)
        case .start, .startHeadless: return device.state == .stopped && !device.isPhysical
        case .stop: return running && !device.isPhysical
        case .showMirror, .showLogs, .showNetwork, .showTools: return true
        }
    }
}

private struct HubActionsKey: FocusedValueKey {
    typealias Value = HubActions
}

extension FocusedValues {
    var hubActions: HubActions? {
        get { self[HubActionsKey.self] }
        set { self[HubActionsKey.self] = newValue }
    }
}

/// The Device menu. Where the iOS Simulator has a shortcut for the same thing, it is the same one.
struct DeviceCommands: Commands {
    @FocusedValue(\.hubActions) private var actions

    var body: some Commands {
        CommandMenu("Device") {
            item("Home", .home, "h", [.command, .shift])
            item("App Switcher", .appSwitcher, "h", [.command, .control])
            item("Back", .back, "[", .command)
            item("Lock", .lock, "l", .command)
            Divider()
            item("Volume Up", .volumeUp, .upArrow, [.command, .option])
            item("Volume Down", .volumeDown, .downArrow, [.command, .option])
            item("Rotate Left", .rotateLeft, .leftArrow, .command)
            item("Rotate Right", .rotateRight, .rightArrow, .command)
            Divider()
            item("Toggle Dark Mode", .toggleDarkMode, "a", [.command, .shift])
            item("Larger Text", .largerText, "=", [.command, .option])
            item("Smaller Text", .smallerText, "-", [.command, .option])
            Divider()
            item("Screenshot", .screenshot, "s", .command)
            item("Screenshot with Thumbnail", .screenshotToCorner, "s", .control)
            item(actions?.isRecording == true ? "Stop Recording" : "Start Recording", .toggleRecording, "r", [.command, .option])
            Divider()
            item("Start", .startHeadless)
            item("Start with Window", .start)
            item("Stop", .stop)
        }
        CommandMenu("Panels") {
            item("Mirror", .showMirror, "1", [.command, .option])
            item("Logs", .showLogs, "2", [.command, .option])
            item("Network", .showNetwork, "3", [.command, .option])
            item("Tools", .showTools, "4", [.command, .option])
        }
    }

    private func item(_ title: String, _ command: HubCommand, _ key: KeyEquivalent? = nil,
                      _ modifiers: EventModifiers = []) -> some View {
        Button(title) { actions?.perform(command) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(!(actions?.isEnabled(command) ?? false))
    }
}

private extension View {
    @ViewBuilder
    func keyboardShortcut(_ key: KeyEquivalent?, modifiers: EventModifiers) -> some View {
        if let key { keyboardShortcut(key, modifiers: modifiers) } else { self }
    }
}
