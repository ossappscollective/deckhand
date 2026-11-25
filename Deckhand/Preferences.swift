import Foundation
import DeckhandCore

nonisolated enum Preferences {
    static let sdkPathKey = "androidSdkPath"
    static let muteAudioKey = "androidMuteAudio"
    static let extraArgumentsKey = "androidExtraArguments"
    static let captureDirectoryKey = "captureDirectory"
    static let showPhysicalDevicesKey = "showPhysicalDevices"
    static let syncClipboardKey = "syncClipboard"
    static let logBufferKey = "logBufferLines"
    static let networkPortKey = "networkPort"
    static let terminalAppKey = "terminalApp"
    static let terminalCustomAppKey = "terminalCustomApp"
    static let menuBarIndicatorKey = "menuBarIndicator"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [showPhysicalDevicesKey: true, syncClipboardKey: true, logBufferKey: 50_000])
    }

    static var showPhysicalDevices: Bool { UserDefaults.standard.bool(forKey: showPhysicalDevicesKey) }

    static var syncClipboard: Bool { UserDefaults.standard.bool(forKey: syncClipboardKey) }

    static var androidLaunchOptions: AndroidLaunchOptions {
        let defaults = UserDefaults.standard
        return AndroidLaunchOptions(muteAudio: defaults.bool(forKey: muteAudioKey),
                                    extraArguments: defaults.string(forKey: extraArgumentsKey) ?? "")
    }

    static var captureDirectory: String {
        let stored = UserDefaults.standard.string(forKey: captureDirectoryKey) ?? ""
        return stored.isEmpty ? NSHomeDirectory() + "/Desktop" : (stored as NSString).expandingTildeInPath
    }

    static var terminalApp: TerminalApp {
        let defaults = UserDefaults.standard
        return TerminalApp(id: defaults.string(forKey: terminalAppKey) ?? "terminal",
                           customName: defaults.string(forKey: terminalCustomAppKey) ?? "")
    }

    static func locateSDK() -> AndroidSDK? {
        SDKLocator(override: UserDefaults.standard.string(forKey: sdkPathKey)).locate()
    }
}

/// What the menu bar icon says about running simulators and emulators.
enum MenuBarIndicator: String, CaseIterable {
    case iconAndCount
    case icon
    case never

    var title: String {
        switch self {
        case .iconAndCount: "Icon and number"
        case .icon: "Icon only"
        case .never: "Never"
        }
    }
}
