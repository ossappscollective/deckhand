import Foundation

public enum LogAppDiscoveryError: Error, Equatable, CustomStringConvertible {
    case unavailable(String)

    public var description: String {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}

/// Finds the apps worth filtering the log by, on demand: the app in the foreground and the ones you installed.
public struct LogAppDiscovery: Sendable {
    private let runner: any ShellRunner
    private let sdk: AndroidSDK?
    private let baguette: String?

    public init(runner: any ShellRunner, sdk: AndroidSDK?, baguette: String? = SimulatorInputSession.locate()) {
        self.runner = runner
        self.sdk = sdk
        self.baguette = baguette
    }

    /// Apps installed by the user, named as they appear in the log (packages on Android, executables on iOS).
    public func yourApps(on device: Device) async throws -> [String] {
        switch (device.platform, device.isPhysical) {
        case (.android, _):
            let adb = try adbPath()
            let output = try await runner.run(adb, ["-s", try serial(of: device), "shell", "pm", "list", "packages", "-3"])
            return EmulatorTools.parsePackages(output).sorted()
        case (.ios, false):
            let output = try await runner.run("/usr/bin/xcrun", ["simctl", "listapps", device.id])
            return Array(Set(SimctlParser.parseAppExecutables(output).filter { !$0.isSystem }.map(\.executable)))
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        case (.ios, true):
            return []
        }
    }

    /// The app in the foreground, named as it appears in the log.
    public func currentApp(on device: Device) async throws -> String {
        switch (device.platform, device.isPhysical) {
        case (.android, _):
            let adb = try adbPath()
            let output = try await runner.run(adb, ["-s", try serial(of: device), "shell", "dumpsys", "activity", "activities"])
            guard let package = Self.parseForegroundPackage(output) else {
                throw LogAppDiscoveryError.unavailable("No app is in the foreground")
            }
            return package
        case (.ios, false):
            guard let baguette else {
                throw MissingToolError(.baguette, for: "Finding the foreground app")
            }
            let json = try await runner.run(baguette, ["describe-ui", "--udid", device.id])
            let label = Self.parseRootLabel(json)
            guard let label, !label.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw LogAppDiscoveryError.unavailable("The home screen is showing: no app in the foreground")
            }
            let apps = SimctlParser.parseAppExecutables(try await runner.run("/usr/bin/xcrun", ["simctl", "listapps", device.id]))
            guard let match = apps.first(where: { $0.displayName.caseInsensitiveCompare(label) == .orderedSame }) else {
                throw LogAppDiscoveryError.unavailable("Could not match “\(label)” to an installed app")
            }
            return match.executable
        case (.ios, true):
            throw LogAppDiscoveryError.unavailable("Not available for a real iPhone or iPad")
        }
    }

    static func parseForegroundPackage(_ dumpsys: String) -> String? {
        let patterns = [#"topResumedActivity=ActivityRecord\{\S+ u\d+ ([\w.]+)/"#,
                        #"mResumedActivity: ActivityRecord\{\S+ u\d+ ([\w.]+)/"#,
                        #"ResumedActivity: ActivityRecord\{\S+ u\d+ ([\w.]+)/"#]
        for pattern in patterns {
            guard let range = dumpsys.range(of: pattern, options: .regularExpression) else { continue }
            let match = String(dumpsys[range])
            if let slash = match.lastIndex(of: "/"), let space = match[..<slash].lastIndex(of: " ") {
                return String(match[match.index(after: space)..<slash])
            }
        }
        return nil
    }

    static func parseRootLabel(_ json: String) -> String? {
        struct Root: Decodable { let label: String? }
        return (try? JSONDecoder().decode(Root.self, from: Data(json.utf8)))?.label
    }

    private func adbPath() throws -> String {
        guard let sdk else { throw LogAppDiscoveryError.unavailable("Android SDK not found — set path in Settings") }
        return sdk.adbPath
    }

    private func serial(of device: Device) throws -> String {
        guard let serial = device.serial else { throw LogAppDiscoveryError.unavailable("\(device.name) is not running") }
        return serial
    }
}
