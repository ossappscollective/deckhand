import Foundation
import Observation

@MainActor
@Observable
public final class DeviceToolsViewModel {
    public struct Message: Equatable, Sendable {
        public let text: String
        public let isError: Bool
        /// Set when the failure is a program the user can install.
        public let missingTool: OptionalTool?

        public init(text: String, isError: Bool, missingTool: OptionalTool? = nil) {
            self.text = text
            self.isError = isError
            self.missingTool = missingTool
        }
    }

    public enum AppsState: Equatable, Sendable {
        case idle
        case loading
        case loaded
    }

    public private(set) var apps: [InstalledApp] = []
    public private(set) var appsState: AppsState = .idle
    public private(set) var appsError: String?
    public private(set) var isWorking = false
    public private(set) var message: Message?
    /// Called after a device was rotated, so a mirror that does not follow the rotation by itself can restart.
    public var didRotate: ((Device, _ clockwise: Bool) -> Void)?
    private var orientations: [String: SimulatorOrientation] = [:]

    /// How a simulator is held, as far as Deckhand knows: it cannot be asked.
    public func orientation(of device: Device) -> SimulatorOrientation { orientations[device.id] ?? .portrait }
    public private(set) var recordings: [String: String] = [:]

    private let runner: any ShellRunner
    private let locateSDK: @Sendable () -> AndroidSDK?
    private let captureDirectory: @Sendable () -> String
    private let terminalApp: @Sendable () -> TerminalApp
    private let finalizeDelay: Duration
    private var includeSystemApps = false

    public init(runner: any ShellRunner = ProcessShellRunner(),
                finalizeDelay: Duration = .seconds(1),
                captureDirectory: @escaping @Sendable () -> String = { NSHomeDirectory() + "/Desktop" },
                terminalApp: @escaping @Sendable () -> TerminalApp = { .terminal },
                locateSDK: @escaping @Sendable () -> AndroidSDK?) {
        self.runner = runner
        self.finalizeDelay = finalizeDelay
        self.captureDirectory = captureDirectory
        self.terminalApp = terminalApp
        self.locateSDK = locateSDK
    }

    public func isRecording(_ device: Device) -> Bool {
        recordings[device.id] != nil
    }

    /// Forget everything fetched for the previously inspected device.
    public func reset() {
        apps = []
        appsState = .idle
        appsError = nil
        message = nil
        includeSystemApps = false
    }

    public func dismissMessage() {
        message = nil
    }

    /// Fetches installed apps. Called only when the user opens the Apps section.
    public func loadApps(for device: Device, includeSystem: Bool? = nil) async {
        if let includeSystem { includeSystemApps = includeSystem }
        appsState = .loading
        appsError = nil
        do {
            apps = try await listApps(device)
        } catch {
            apps = []
            appsError = Self.friendlyMessage(error)
        }
        appsState = .loaded
    }

    public func perform(_ tool: DeviceTool, on device: Device) async {
        guard tool.isSupported(for: device) else {
            message = Message(text: "Not available for \(device.platform == .ios ? "iOS" : "Android")", isError: true)
            return
        }
        isWorking = true
        message = nil
        do {
            message = try await run(tool, on: device).map { Message(text: $0, isError: false) }
            if shouldReloadApps(after: tool) { await loadApps(for: device) }
        } catch {
            message = Self.failure(error)
        }
        isWorking = false
    }

    /// Handles files dropped on a device: installs apps, adds media, copies everything else.
    public func drop(_ paths: [String], on device: Device) async {
        guard !paths.isEmpty else { return }
        isWorking = true
        message = nil
        var done = 0
        var failures: [String] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let tool: DeviceTool
            switch FileDrop.action(for: path, on: device) {
            case .install: tool = .install(path)
            case .push: tool = .pushFile(path)
            case .copyToFiles: tool = .copyToFiles(path)
            case .addMedia: tool = .addMedia(path)
            case .unsupported(let reason):
                failures.append("\(name): \(reason)")
                continue
            }
            do {
                _ = try await run(tool, on: device)
                done += 1
            } catch {
                failures.append("\(name): \(Self.friendlyMessage(error))")
            }
        }
        if appsState == .loaded, done > 0 { await loadApps(for: device) }
        if let failure = failures.first {
            message = Message(text: failures.count > 1 ? "\(failure) (+\(failures.count - 1) more)" : failure, isError: true)
        } else {
            message = Message(text: done == 1 ? "Dropped 1 file" : "Dropped \(done) files", isError: false)
        }
        isWorking = false
    }

    private func shouldReloadApps(after tool: DeviceTool) -> Bool {
        switch tool {
        case .uninstall: true
        case .install: appsState == .loaded
        default: false
        }
    }

    private func run(_ tool: DeviceTool, on device: Device) async throws -> String? {
        switch (device.platform, device.isPhysical) {
        case (.ios, true): try await runPhysicalIOS(tool, on: device)
        case (.ios, false): try await runIOS(tool, on: device)
        case (.android, _): try await runAndroid(tool, on: device)
        }
    }

    private func listApps(_ device: Device) async throws -> [InstalledApp] {
        switch (device.platform, device.isPhysical) {
        case (.ios, true): try await PhysicalIOSTools(runner: runner).listApps(device, includeSystem: includeSystemApps)
        case (.ios, false): try await SimulatorTools(runner: runner).listApps(device, includeSystem: includeSystemApps)
        case (.android, _): try await emulatorTools().listApps(device, includeSystem: includeSystemApps)
        }
    }

    private func runIOS(_ tool: DeviceTool, on device: Device) async throws -> String? {
        var tools = SimulatorTools(runner: runner)
        tools.terminal = terminalApp()
        switch tool {
        case .screenshot: return try await finishCapture(try await tools.screenshot(device, directory: captureDirectory()))
        case .startRecording: return try await beginRecording(device, path: try await tools.startRecording(device, directory: captureDirectory()))
        case .stopRecording: return try await endRecording(device) { try await tools.stopRecording(device) }
        case .appearance(let dark): try await tools.setAppearance(device, dark: dark); return dark ? "Dark mode on" : "Light mode on"
        case .toggleAppearance: return try await tools.toggleAppearance(device) ? "Dark mode on" : "Light mode on"
        case .textSize(let larger): try await tools.changeTextSize(device, larger: larger); return larger ? "Larger text" : "Smaller text"
        case .openURL(let url): try await tools.openURL(device, url); return "Opened URL"
        case .addMedia(let path): try await tools.addMedia(device, path: path); return "Added \((path as NSString).lastPathComponent)"
        case .copyToFiles(let path):
            try await tools.copyToFiles(device, path: path)
            return "Copied \((path as NSString).lastPathComponent) to Files › On My iPhone"
        case .install(let source): try await tools.install(device, source: source); return "Installed app"
        case .location(let latitude, let longitude): try await tools.setLocation(device, latitude: latitude, longitude: longitude); return "Location set"
        case .clearLocation: try await tools.clearLocation(device); return "Location cleared"
        case .statusBar(let clean): try await tools.setCleanStatusBar(device, clean: clean); return clean ? "Status bar set to 9:41" : "Status bar restored"
        case .rotate, .rotateLeft:
            // the simulator cannot be asked how it is held: assume what was last set here
            let clockwise = tool == .rotate
            let next = (orientations[device.id] ?? .portrait).turned(clockwise: clockwise)
            try await tools.setOrientation(device, next)
            orientations[device.id] = next
            didRotate?(device, clockwise)
            return nil
        case .shell, .scrcpy, .animations, .showTaps, .reboot, .clearData, .pushFile, .relaunch: return nil
        case .logs: try await tools.openLogs(device); return nil
        case .revealStorage: try await tools.revealStorage(device); return nil
        case .launch(let app): try await tools.launch(device, app: app); return nil
        case .relaunch(let app): try await tools.relaunch(device, app: app); return "Relaunched \(app)"
        case .stopApp(let app): try await tools.terminate(device, app: app); return nil
        case .uninstall(let app): try await tools.uninstall(device, app: app); return "Uninstalled \(app)"
        case .revealAppData(let app): try await tools.revealAppData(device, app: app); return nil
        }
    }

    private func runPhysicalIOS(_ tool: DeviceTool, on device: Device) async throws -> String? {
        let tools = PhysicalIOSTools(runner: runner)
        switch tool {
        case .screenshot: return try await finishCapture(try await tools.screenshot(device, directory: captureDirectory()))
        case .startRecording: return try await beginRecording(device, path: try await tools.startRecording(device, directory: captureDirectory()))
        case .stopRecording: return try await endRecording(device) { try await tools.stopRecording(device) }
        case .install(let source): try await tools.install(device, source: source); return "Installed app"
        case .launch(let app): try await tools.launch(device, app: app); return nil
        case .uninstall(let app): try await tools.uninstall(device, app: app); return "Uninstalled \(app)"
        default: return nil
        }
    }

    private func runAndroid(_ tool: DeviceTool, on device: Device) async throws -> String? {
        let tools = try emulatorTools()
        switch tool {
        case .screenshot: return try await finishCapture(try await tools.screenshot(device, directory: captureDirectory()))
        case .startRecording: return try await beginRecording(device, path: try await tools.startRecording(device, directory: captureDirectory()))
        case .stopRecording: return try await endRecording(device) { try await tools.stopRecording(device) }
        case .appearance(let dark): try await tools.setAppearance(device, dark: dark); return dark ? "Dark mode on" : "Light mode on"
        case .toggleAppearance: return try await tools.toggleAppearance(device) ? "Dark mode on" : "Light mode on"
        case .textSize(let larger): try await tools.changeTextSize(device, larger: larger); return larger ? "Larger text" : "Smaller text"
        case .openURL(let url): try await tools.openURL(device, url); return "Opened URL"
        case .install(let source): try await tools.install(device, source: source); return "Installed app"
        case .location(let latitude, let longitude): try await tools.setLocation(device, latitude: latitude, longitude: longitude); return "Location set"
        case .rotate: try await tools.rotate(device); didRotate?(device, true); return nil
        case .rotateLeft: try await tools.rotate(device, clockwise: false); didRotate?(device, false); return nil
        case .animations(let enabled): try await tools.setAnimations(device, enabled: enabled); return enabled ? "Animations on" : "Animations off"
        case .showTaps(let enabled): try await tools.setShowTaps(device, enabled: enabled); return enabled ? "Showing taps" : "Taps hidden"
        case .reboot: try await tools.reboot(device); return "Rebooting"
        case .shell: try await tools.openShell(device); return nil
        case .scrcpy: try await tools.openScrcpy(device); return nil
        case .logs: try await tools.openLogs(device); return nil
        case .revealStorage: try await tools.revealStorage(device); return nil
        case .launch(let app): try await tools.launch(device, app: app); return nil
        case .stopApp(let app): try await tools.forceStop(device, app: app); return nil
        case .uninstall(let app): try await tools.uninstall(device, app: app); return "Uninstalled \(app)"
        case .clearData(let app): try await tools.clearData(device, app: app); return "Cleared data of \(app)"
        case .pushFile(let path):
            let destination = try await tools.pushFile(device, path: path)
            return "Copied to \(destination)"
        case .clearLocation, .statusBar, .revealAppData, .addMedia, .copyToFiles, .relaunch: return nil
        }
    }

    private func finishCapture(_ path: String) async throws -> String {
        try await reveal(path)
        return "Saved \((path as NSString).lastPathComponent)"
    }

    private func beginRecording(_ device: Device, path: String) async throws -> String {
        recordings[device.id] = path
        return "Recording…"
    }

    private func endRecording(_ device: Device, stop: () async throws -> Void) async throws -> String {
        guard let path = recordings[device.id] else {
            throw ShellError(command: "record", exitCode: 1, stderr: "\(device.name) is not being recorded")
        }
        try await stop()
        recordings[device.id] = nil
        try? await Task.sleep(for: finalizeDelay)
        try await reveal(path)
        return "Saved \((path as NSString).lastPathComponent)"
    }

    private func reveal(_ path: String) async throws {
        _ = try? await runner.run("/usr/bin/open", ["-R", path])
    }

    private func emulatorTools() throws -> EmulatorTools {
        guard let sdk = locateSDK() else {
            throw ShellError(command: "android", exitCode: 1, stderr: "Android SDK not found — set path in Settings")
        }
        var tools = EmulatorTools(runner: runner, sdk: sdk)
        tools.terminal = terminalApp()
        return tools
    }

    static func friendlyMessage(_ error: Error) -> String { ErrorMessage.friendly(error) }

    static func failure(_ error: Error) -> Message {
        Message(text: friendlyMessage(error), isError: true, missingTool: (error as? MissingToolError)?.tool)
    }
}
