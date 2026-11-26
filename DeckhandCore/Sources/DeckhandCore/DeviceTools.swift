import Foundation

public struct InstalledApp: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let isSystem: Bool

    public init(id: String, name: String, isSystem: Bool) {
        self.id = id
        self.name = name
        self.isSystem = isSystem
    }
}

/// One-off actions on a running device. Nothing here runs until the user picks it.
public enum DeviceTool: Sendable, Equatable {
    case screenshot
    case startRecording
    case stopRecording
    case appearance(dark: Bool)
    /// Switches to the other of dark and light, whichever the device is in.
    case toggleAppearance
    /// One step up or down in the system text size.
    case textSize(larger: Bool)
    case openURL(String)
    /// A local `.app` / `.apk` / `.tar.gz` / `.zip`, or an http(s) URL to one.
    case install(String)
    case location(latitude: Double, longitude: Double)
    case clearLocation
    case statusBar(clean: Bool)
    case rotate
    case rotateLeft
    case animations(enabled: Bool)
    case showTaps(enabled: Bool)
    case reboot
    case shell
    /// Opens scrcpy (if installed) for a full-speed mirror in its own window.
    case scrcpy
    case logs
    case revealStorage
    /// Android: copies a file or folder to the device's Download folder.
    case pushFile(String)
    /// Simulator: copies a file or folder into the Files app ("On My iPhone").
    case copyToFiles(String)
    /// Simulator: adds a photo or video to the library.
    case addMedia(String)
    case launch(app: String)
    /// Simulator: quits the app if it runs and starts it again (needed to pick up an injected virtual camera).
    case relaunch(app: String)
    case stopApp(app: String)
    case uninstall(app: String)
    case clearData(app: String)
    case revealAppData(app: String)

    /// What a progress over the device says while this runs; nil for what is over at once.
    public var activityTitle: String? {
        func name(_ source: String) -> String {
            URL(string: source).flatMap { $0.scheme?.hasPrefix("http") == true ? $0.lastPathComponent : nil }
                ?? (source as NSString).lastPathComponent
        }
        switch self {
        case .install(let source): return "Installing \(name(source))"
        case .pushFile(let path), .copyToFiles(let path): return "Copying \(name(path))"
        case .addMedia(let path): return "Adding \(name(path))"
        default: return nil
        }
    }

    /// Physical devices lack the emulator console and most simulator-only switches.
    public func isSupported(for device: Device) -> Bool {
        guard device.isPhysical else { return isSupported(on: device.platform) }
        switch (device.platform, self) {
        case (.ios, .screenshot), (.ios, .startRecording), (.ios, .stopRecording), (.ios, .install),
             (.ios, .launch), (.ios, .uninstall): return true
        case (.ios, _): return false
        case (.android, .location), (.android, .revealStorage),
             (.android, .startRecording), (.android, .stopRecording): return false
        case (.android, _): return isSupported(on: .android)
        }
    }

    public func isSupported(on platform: Platform) -> Bool {
        switch self {
        case .clearLocation, .statusBar, .revealAppData, .addMedia, .copyToFiles, .relaunch: platform == .ios
        case .animations, .showTaps, .reboot, .clearData, .scrcpy, .pushFile: platform == .android
        default: true
        }
    }
}

/// How a simulator is held. Phones do not turn upside down, so a turn from a landscape goes back to portrait.
public enum SimulatorOrientation: String, Sendable, Equatable {
    case portrait
    case landscapeLeft = "landscape-left"
    case landscapeRight = "landscape-right"

    public func turned(clockwise: Bool) -> SimulatorOrientation {
        self == .portrait ? (clockwise ? .landscapeRight : .landscapeLeft) : .portrait
    }
}

/// What dropping a file on a device does.
public enum FileDropAction: Equatable, Sendable {
    case install
    /// Android: into the Download folder.
    case push
    /// Simulator: into the Files app.
    case copyToFiles
    case addMedia
    case unsupported(String)
}

public enum FileDrop {
    private static let media: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp",
                                             "mov", "mp4", "m4v"]

    public static func action(for path: String, on device: Device) -> FileDropAction {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        let archive = name.hasSuffix(".tar.gz") || ext == "tgz" || ext == "zip"
        switch device.platform {
        case .android:
            return ["apk", "aab", "apks"].contains(ext) ? .install : .push
        case .ios where device.isPhysical:
            return ext == "ipa" || ext == "app" || archive ? .install : .unsupported("Only .ipa and .app files can be dropped on an iPhone or iPad")
        case .ios:
            if ext == "app" || ext == "ipa" || archive { return .install }
            return media.contains(ext) ? .addMedia : .copyToFiles
        }
    }
}

struct CaptureNamer: Sendable {
    let now: @Sendable () -> Date
    let prepareDirectory: @Sendable (String) -> Void

    static let live = CaptureNamer(now: Date.init) {
        try? FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: true)
    }

    func path(in directory: String, device: Device, fileExtension: String) -> String {
        prepareDirectory(directory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeName = device.name.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        return "\(directory)/\(safeName)-\(formatter.string(from: now())).\(fileExtension)"
    }
}

enum TerminalLauncher {
    /// Runs `commandLine` in a new window of `terminal` through an executable `.command` file, which needs no
    /// Automation permission.
    static func open(_ commandLine: String, in terminal: TerminalApp = .terminal, runner: any ShellRunner,
                     directory: String = NSTemporaryDirectory()) async throws {
        let path = "\(directory)/deckhand-\(UUID().uuidString).command"
        let script = "#!/bin/zsh\nclear\nrm -f \"$0\"\n\(commandLine)\n"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        try await runner.run("/usr/bin/open", terminal.openArguments(script: path))
    }

    static func quote(_ value: String) -> String { RemoteShell.quote(value) }
}

/// Turns a user-supplied source (path or URL) into something `simctl install` / `adb install` accepts.
struct AppPackageResolver: Sendable {
    let runner: any ShellRunner
    let fileExtension: String
    /// Extensions usable as they are; anything else is treated as an archive to unpack.
    let acceptedExtensions: Set<String>
    let temporaryDirectory: String

    init(runner: any ShellRunner, fileExtension: String, acceptedExtensions: Set<String>? = nil,
         temporaryDirectory: String = NSTemporaryDirectory()) {
        self.runner = runner
        self.fileExtension = fileExtension
        self.acceptedExtensions = acceptedExtensions ?? [fileExtension]
        self.temporaryDirectory = temporaryDirectory
    }

    func resolve(_ source: String) async throws -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let workDirectory = "\(temporaryDirectory)/Deckhand-\(UUID().uuidString)"
        let local: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            try FileManager.default.createDirectory(atPath: workDirectory, withIntermediateDirectories: true)
            let name = URL(string: trimmed)?.lastPathComponent ?? ""
            local = "\(workDirectory)/\(name.isEmpty || name == "/" ? "download" : name)"
            try await runner.run("/usr/bin/curl", ["-fL", "--silent", "--show-error", "-o", local, trimmed])
        } else {
            local = (trimmed as NSString).expandingTildeInPath
        }
        if acceptedExtensions.contains(URL(fileURLWithPath: local).pathExtension.lowercased()) { return local }
        return try await extract(local, into: workDirectory)
    }

    private func extract(_ archive: String, into workDirectory: String) async throws -> String {
        try FileManager.default.createDirectory(atPath: workDirectory, withIntermediateDirectories: true)
        let unpacked = "\(workDirectory)/unpacked"
        try FileManager.default.createDirectory(atPath: unpacked, withIntermediateDirectories: true)
        switch Self.archiveKind(archive) {
        case .gzip: try await runner.run("/usr/bin/tar", ["-xzf", archive, "-C", unpacked])
        case .zip: try await runner.run("/usr/bin/unzip", ["-q", archive, "-d", unpacked])
        case .unknown:
            throw ShellError(command: "install", exitCode: 1,
                             stderr: "Expected a .\(fileExtension) file or a .tar.gz / .zip containing one")
        }
        guard let found = Self.firstMatch(in: unpacked, fileExtension: fileExtension) else {
            throw ShellError(command: "install", exitCode: 1, stderr: "No .\(fileExtension) found in the archive")
        }
        return found
    }

    enum ArchiveKind { case gzip, zip, unknown }

    static func archiveKind(_ path: String) -> ArchiveKind {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { try? handle.close() }
        let magic = [UInt8](handle.readData(ofLength: 2))
        if magic == [0x1f, 0x8b] { return .gzip }
        if magic == [0x50, 0x4b] { return .zip }
        return .unknown
    }

    static func firstMatch(in directory: String, fileExtension: String) -> String? {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return nil }
        for case let relative as String in enumerator where relative.hasSuffix(".\(fileExtension)") {
            if fileExtension == "app" { enumerator.skipDescendants() }
            return "\(directory)/\(relative)"
        }
        return nil
    }
}

public struct SimulatorTools: Sendable {
    /// Where `openLogs` runs.
    public var terminal: TerminalApp = .terminal
    private let runner: any ShellRunner
    private let namer: CaptureNamer
    private let temporaryDirectory: String
    private let xcrun = "/usr/bin/xcrun"
    private let locateBaguette: @Sendable () -> String?

    public init(runner: any ShellRunner) {
        self.init(runner: runner, namer: .live, temporaryDirectory: NSTemporaryDirectory())
    }

    init(runner: any ShellRunner, namer: CaptureNamer, temporaryDirectory: String,
         locateBaguette: @escaping @Sendable () -> String? = { SimulatorInputSession.locate() }) {
        self.runner = runner
        self.namer = namer
        self.temporaryDirectory = temporaryDirectory
        self.locateBaguette = locateBaguette
    }

    /// Turns the simulator's screen. Apple offers no command for it (Simulator.app does it through a private
    /// interface), so this goes through Baguette.
    public func setOrientation(_ device: Device, _ orientation: SimulatorOrientation) async throws {
        guard let baguette = locateBaguette() else {
            throw MissingToolError(.baguette, for: "Rotating a simulator")
        }
        try await runner.run(baguette, ["orientation", "--udid", device.id, orientation.rawValue])
    }

    public func screenshot(_ device: Device, directory: String) async throws -> String {
        let path = namer.path(in: directory, device: device, fileExtension: "png")
        try await simctl(["io", device.id, "screenshot", "--type=png", path])
        return path
    }

    public func startRecording(_ device: Device, directory: String) async throws -> String {
        let path = namer.path(in: directory, device: device, fileExtension: "mov")
        try await runner.launchDetached(xcrun, ["simctl", "io", device.id, "recordVideo", "--codec=h264", "--force", path],
                                        failureWindow: .seconds(1))
        return path
    }

    public func stopRecording(_ device: Device) async throws {
        try await runner.run("/usr/bin/pkill", ["-INT", "-f", "simctl io \(device.id) recordVideo"])
    }

    public func setAppearance(_ device: Device, dark: Bool) async throws {
        try await simctl(["ui", device.id, "appearance", dark ? "dark" : "light"])
    }

    /// Returns whether the simulator is dark afterwards.
    public func toggleAppearance(_ device: Device) async throws -> Bool {
        let current = try await simctl(["ui", device.id, "appearance"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dark = current != "dark"
        try await setAppearance(device, dark: dark)
        return dark
    }

    public func changeTextSize(_ device: Device, larger: Bool) async throws {
        try await simctl(["ui", device.id, "content_size", larger ? "increment" : "decrement"])
    }

    /// One JPEG frame of the screen, for the polling mirror.
    public func captureFrame(_ device: Device) async throws -> Data {
        let path = "\(temporaryDirectory)/deckhand-frame-\(device.id).jpg"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await simctl(["io", device.id, "screenshot", "--type=jpeg", path])
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func openURL(_ device: Device, _ url: String) async throws {
        try await simctl(["openurl", device.id, url])
    }

    /// Copies a file or folder to where the Files app lists "On My iPhone", and returns that folder.
    @discardableResult
    public func copyToFiles(_ device: Device, path: String) async throws -> String {
        let apps = try await simctl(["listapps", device.id])
        guard let storage = SimctlParser.fileProviderStorage(listApps: apps) else {
            throw ShellError(command: "simctl", exitCode: 1,
                             stderr: "The Files app storage was not found. Open the Files app on the simulator once and try again.")
        }
        try await runner.run("/bin/mkdir", ["-p", storage])
        try await runner.run("/bin/cp", ["-R", path, storage + "/"])
        return storage
    }

    public func addMedia(_ device: Device, path: String) async throws {
        try await simctl(["addmedia", device.id, path])
    }

    public func pasteboard(_ device: Device) async throws -> String {
        try await simctl(["pbpaste", device.id])
    }

    /// Copies the Mac clipboard onto the simulator.
    public func pushHostPasteboard(_ device: Device) async throws {
        try await simctl(["pbsync", "host", device.id])
    }

    /// Copies the simulator clipboard onto the Mac.
    public func pullPasteboard(_ device: Device) async throws {
        try await simctl(["pbsync", device.id, "host"])
    }

    public func install(_ device: Device, source: String) async throws {
        let app = try await AppPackageResolver(runner: runner, fileExtension: "app",
                                               temporaryDirectory: temporaryDirectory).resolve(source)
        try await simctl(["install", device.id, app])
    }

    public func listApps(_ device: Device, includeSystem: Bool) async throws -> [InstalledApp] {
        let apps = SimctlParser.parseApps(try await simctl(["listapps", device.id]))
        return includeSystem ? apps : apps.filter { !$0.isSystem }
    }

    public func launch(_ device: Device, app: String) async throws {
        try await simctl(["launch", device.id, app])
    }

    public func relaunch(_ device: Device, app: String) async throws {
        try await simctl(["launch", "--terminate-running-process", device.id, app])
    }

    public func terminate(_ device: Device, app: String) async throws {
        try await simctl(["terminate", device.id, app])
    }

    public func uninstall(_ device: Device, app: String) async throws {
        try await simctl(["uninstall", device.id, app])
    }

    public func revealAppData(_ device: Device, app: String) async throws {
        let path = try await simctl(["get_app_container", device.id, app, "data"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await runner.run("/usr/bin/open", [path])
    }

    public func setLocation(_ device: Device, latitude: Double, longitude: Double) async throws {
        try await simctl(["location", device.id, "set", "\(latitude),\(longitude)"])
    }

    public func clearLocation(_ device: Device) async throws {
        try await simctl(["location", device.id, "clear"])
    }

    public func setCleanStatusBar(_ device: Device, clean: Bool) async throws {
        if clean {
            try await simctl(["status_bar", device.id, "override", "--time", "9:41", "--batteryState", "charged",
                              "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3"])
        } else {
            try await simctl(["status_bar", device.id, "clear"])
        }
    }

    public func openLogs(_ device: Device) async throws {
        try await TerminalLauncher.open("xcrun simctl spawn \(device.id) log stream --level debug", in: terminal, runner: runner)
    }

    public func revealStorage(_ device: Device) async throws {
        try await runner.run("/usr/bin/open", ["\(NSHomeDirectory())/Library/Developer/CoreSimulator/Devices/\(device.id)"])
    }

    @discardableResult
    private func simctl(_ arguments: [String]) async throws -> String {
        try await runner.run(xcrun, ["simctl"] + arguments)
    }
}

public struct EmulatorTools: Sendable {
    /// Where `openShell` and `openLogs` run.
    public var terminal: TerminalApp = .terminal
    private let runner: any ShellRunner
    private let sdk: AndroidSDK
    private let avdHome: String
    private let namer: CaptureNamer
    private let temporaryDirectory: String
    private let locateBundletool: @Sendable () -> String?

    public init(runner: any ShellRunner, sdk: AndroidSDK, avdHome: String = NSHomeDirectory() + "/.android/avd") {
        self.init(runner: runner, sdk: sdk, avdHome: avdHome, namer: .live, temporaryDirectory: NSTemporaryDirectory())
    }

    init(runner: any ShellRunner, sdk: AndroidSDK, avdHome: String, namer: CaptureNamer, temporaryDirectory: String,
         locateBundletool: @escaping @Sendable () -> String? = EmulatorTools.defaultBundletool) {
        self.runner = runner
        self.sdk = sdk
        self.avdHome = avdHome
        self.namer = namer
        self.temporaryDirectory = temporaryDirectory
        self.locateBundletool = locateBundletool
    }

    static let defaultBundletool: @Sendable () -> String? = {
        (["/opt/homebrew/bin/bundletool", "/usr/local/bin/bundletool"] + [ProcessInfo.processInfo.environment["BUNDLETOOL_PATH"]].compactMap { $0 })
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static let remoteScreenshot = "/sdcard/deckhand-screenshot.png"

    public func screenshot(_ device: Device, directory: String) async throws -> String {
        let path = namer.path(in: directory, device: device, fileExtension: "png")
        try await adb(device, ["shell", "screencap", "-p", Self.remoteScreenshot])
        defer { Task { _ = try? await adb(device, ["shell", "rm", Self.remoteScreenshot]) } }
        try await adb(device, ["pull", Self.remoteScreenshot, path])
        return path
    }

    public func startRecording(_ device: Device, directory: String) async throws -> String {
        let path = namer.path(in: directory, device: device, fileExtension: "webm")
        try await adb(device, ["emu", "screenrecord", "start", "--time-limit", "600", path])
        return path
    }

    public func stopRecording(_ device: Device) async throws {
        try await adb(device, ["emu", "screenrecord", "stop"])
    }

    public func setAppearance(_ device: Device, dark: Bool) async throws {
        try await adb(device, ["shell", "cmd", "uimode", "night", dark ? "yes" : "no"])
    }

    /// Returns whether the device is dark afterwards.
    public func toggleAppearance(_ device: Device) async throws -> Bool {
        let current = try await adb(device, ["shell", "cmd", "uimode", "night"])
        let dark = !current.lowercased().contains("yes")
        try await setAppearance(device, dark: dark)
        return dark
    }

    static let fontScales: [Double] = [0.85, 1.0, 1.15, 1.3]

    /// Steps `font_scale` through the sizes Android's own setting offers.
    public func changeTextSize(_ device: Device, larger: Bool) async throws {
        let current = Double(try await adb(device, ["shell", "settings", "get", "system", "font_scale"])
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1.0
        let index = Self.fontScales.enumerated().min { abs($0.element - current) < abs($1.element - current) }?.offset ?? 1
        let next = Self.fontScales[min(max(index + (larger ? 1 : -1), 0), Self.fontScales.count - 1)]
        try await adb(device, ["shell", "settings", "put", "system", "font_scale", String(next)])
    }

    public func openURL(_ device: Device, _ url: String) async throws {
        try await adb(device, ["shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", RemoteShell.quote(url)])
    }

    /// Installs an `.apk`, an `.apks` set, or an `.aab` (turned into device-specific APKs with bundletool).
    public func install(_ device: Device, source: String) async throws {
        let path = try await AppPackageResolver(runner: runner, fileExtension: "apk",
                                                acceptedExtensions: ["apk", "aab", "apks"],
                                                temporaryDirectory: temporaryDirectory).resolve(source)
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "aab":
            let apks = "\(temporaryDirectory)/deckhand-\(UUID().uuidString).apks"
            defer { try? FileManager.default.removeItem(atPath: apks) }
            try await bundletool(["build-apks", "--bundle=\(path)", "--output=\(apks)", "--connected-device",
                                  "--device-id=\(try serial(of: device))", "--adb=\(sdk.adbPath)", "--overwrite"])
            try await installApks(device, apks)
        case "apks":
            try await installApks(device, path)
        default:
            try await adb(device, ["install", "-r", "-t", path])
        }
    }

    private func installApks(_ device: Device, _ apks: String) async throws {
        try await bundletool(["install-apks", "--apks=\(apks)", "--device-id=\(try serial(of: device))",
                              "--adb=\(sdk.adbPath)"])
    }

    @discardableResult
    private func bundletool(_ arguments: [String]) async throws -> String {
        guard let tool = locateBundletool() else {
            throw MissingToolError(.bundletool, for: "Installing an .aab")
        }
        return try await runner.run(tool, arguments)
    }

    public func listApps(_ device: Device, includeSystem: Bool) async throws -> [InstalledApp] {
        let user = Set(Self.parsePackages(try await adb(device, ["shell", "pm", "list", "packages", "-3"])))
        let all = includeSystem
            ? Self.parsePackages(try await adb(device, ["shell", "pm", "list", "packages"]))
            : Array(user)
        return all.map { InstalledApp(id: $0, name: $0, isSystem: !user.contains($0)) }
            .sorted { $0.id < $1.id }
    }

    public func launch(_ device: Device, app: String) async throws {
        try await adb(device, ["shell", "monkey", "-p", RemoteShell.quote(app), "-c",
                               "android.intent.category.LAUNCHER", "1"])
    }

    /// Copies a file into the Download folder and returns where it landed.
    @discardableResult
    public func pushFile(_ device: Device, path: String) async throws -> String {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let destination = "/sdcard/Download/" + (path as NSString).lastPathComponent
        // adb puts a pushed folder inside an existing destination folder, so it gets the parent
        try await adb(device, ["push", path, isDirectory.boolValue ? "/sdcard/Download/" : destination])
        _ = try? await adb(device, ["shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                                    "-d", RemoteShell.quote("file://" + destination)])
        return destination
    }

    public func forceStop(_ device: Device, app: String) async throws {
        try await adb(device, ["shell", "am", "force-stop", RemoteShell.quote(app)])
    }

    public func uninstall(_ device: Device, app: String) async throws {
        try await adb(device, ["uninstall", app])
    }

    public func clearData(_ device: Device, app: String) async throws {
        try await adb(device, ["shell", "pm", "clear", RemoteShell.quote(app)])
    }

    public func setLocation(_ device: Device, latitude: Double, longitude: Double) async throws {
        try await adb(device, ["emu", "geo", "fix", "\(longitude)", "\(latitude)"])
    }

    /// Turns the screen a quarter turn through the window manager, which every app obeys. (The emulator's own
    /// `rotate` only moves its virtual sensor: nothing happens on a home screen that does not follow it, or when
    /// auto-rotate is off, and it does not exist on a phone.) The rotation stays locked: releasing it in portrait
    /// would hand the screen back to the sensor, and an emulator whose sensor was turned springs back to landscape.
    public func rotate(_ device: Device, clockwise: Bool = true) async throws {
        var next = (try await currentRotation(device) + (clockwise ? 3 : 1)) % 4
        // a phone does not turn upside down (only a tablet does): from a landscape the next turn is back to portrait
        if next == 2 { next = 0 }
        do {
            try await adb(device, ["shell", "cmd", "window", "user-rotation", "lock", String(next)])
        } catch {
            // Android 10 and earlier have no such command
            try await adb(device, ["shell", "settings", "put", "system", "accelerometer_rotation", "0"])
            try await adb(device, ["shell", "settings", "put", "system", "user_rotation", String(next)])
        }
    }

    /// 0 portrait, 1 turned counterclockwise, 2 upside down, 3 turned clockwise.
    func currentRotation(_ device: Device) async throws -> Int {
        // the display manager's view of the screen, which follows what apps really show (`mRotation` in the window
        // dump does not: its first match is not the default display)
        let display = (try? await adb(device, ["shell", "dumpsys display | grep -m1 -o 'mCurrentOrientation=[0-9]'"])) ?? ""
        if let digit = display.split(separator: "=").last.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) { return digit }
        let setting = (try? await adb(device, ["shell", "settings", "get", "system", "user_rotation"])) ?? ""
        return Int(setting.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Slows the emulator's own network down (all of its traffic, not only what uses a proxy), or cuts it with
    /// airplane mode. The emulator console takes `<up>:<down>` in kbps and `<min>:<max>` in milliseconds.
    public func setNetwork(_ device: Device, _ conditions: NetworkConditions) async throws {
        let speed = conditions.downKbps > 0 || conditions.upKbps > 0
            ? "\(conditions.upKbps > 0 ? conditions.upKbps : 1_000_000):\(conditions.downKbps > 0 ? conditions.downKbps : 1_000_000)"
            : "full"
        try await adb(device, ["emu", "network", "speed", speed])
        try await adb(device, ["emu", "network", "delay", conditions.latencyMs > 0 ? "\(conditions.latencyMs)" : "none"])
        try await adb(device, ["shell", "cmd", "connectivity", "airplane-mode", conditions.offline ? "enable" : "disable"])
    }

    public func setAnimations(_ device: Device, enabled: Bool) async throws {
        for key in ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"] {
            try await adb(device, ["shell", "settings", "put", "global", key, enabled ? "1" : "0"])
        }
    }

    public func setShowTaps(_ device: Device, enabled: Bool) async throws {
        try await adb(device, ["shell", "settings", "put", "system", "show_touches", enabled ? "1" : "0"])
    }

    public func reboot(_ device: Device) async throws {
        try await adb(device, ["reboot"])
    }

    static let scrcpyCandidates = ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]

    public func openScrcpy(_ device: Device, exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) async throws {
        guard let scrcpy = Self.scrcpyCandidates.first(where: exists) else {
            throw MissingToolError(.scrcpy, for: "Opening a scrcpy window")
        }
        try await runner.launchDetached(scrcpy, ["-s", try serial(of: device), "--window-title", device.name],
                                        failureWindow: .seconds(2))
    }

    public func openShell(_ device: Device) async throws {
        try await TerminalLauncher.open("\(TerminalLauncher.quote(sdk.adbPath)) -s \(try serial(of: device)) shell",
                                        in: terminal, runner: runner)
    }

    public func openLogs(_ device: Device) async throws {
        try await TerminalLauncher.open("\(TerminalLauncher.quote(sdk.adbPath)) -s \(try serial(of: device)) logcat",
                                        in: terminal, runner: runner)
    }

    public func revealStorage(_ device: Device) async throws {
        try await runner.run("/usr/bin/open", ["\(avdHome)/\(device.name).avd"])
    }

    static func parsePackages(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("package:") }
            .map { String($0.dropFirst("package:".count)) }
    }

    private func serial(of device: Device) throws -> String {
        guard let serial = device.serial else {
            throw ShellError(command: "adb", exitCode: 1, stderr: "\(device.name) is not running")
        }
        return serial
    }

    @discardableResult
    private func adb(_ device: Device, _ arguments: [String]) async throws -> String {
        try await runner.run(sdk.adbPath, ["-s", try serial(of: device)] + arguments)
    }
}

/// iPhones and iPads over USB or Wi-Fi, driven by `devicectl`.
public struct PhysicalIOSTools: Sendable {
    private let runner: any ShellRunner
    private let namer: CaptureNamer
    private let temporaryDirectory: String
    private let xcrun = "/usr/bin/xcrun"

    public init(runner: any ShellRunner) {
        self.init(runner: runner, namer: .live, temporaryDirectory: NSTemporaryDirectory())
    }

    init(runner: any ShellRunner, namer: CaptureNamer, temporaryDirectory: String) {
        self.runner = runner
        self.namer = namer
        self.temporaryDirectory = temporaryDirectory
    }

    public func screenshot(_ device: Device, directory: String) async throws -> String {
        let path = namer.path(in: directory, device: device, fileExtension: "png")
        try await devicectl(["capture", "screenshot", "--device", device.id, "--destination", path])
        return path
    }

    public func startRecording(_ device: Device, directory: String) async throws -> String {
        let path = namer.path(in: directory, device: device, fileExtension: "mov")
        try await runner.launchDetached(xcrun, ["devicectl", "device", "capture", "screen-record",
                                                "--device", device.id, "--destination", path],
                                        failureWindow: .seconds(2))
        return path
    }

    public func stopRecording(_ device: Device) async throws {
        try await runner.run("/usr/bin/pkill", ["-INT", "-f", "capture screen-record --device \(device.id)"])
    }

    public func install(_ device: Device, source: String) async throws {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if trimmed.lowercased().hasSuffix(".ipa"), !trimmed.hasPrefix("http") {
            path = (trimmed as NSString).expandingTildeInPath
        } else {
            path = try await AppPackageResolver(runner: runner, fileExtension: "app",
                                                temporaryDirectory: temporaryDirectory).resolve(trimmed)
        }
        try await devicectl(["install", "app", "--device", device.id, path])
    }

    public func listApps(_ device: Device, includeSystem: Bool) async throws -> [InstalledApp] {
        var arguments = ["info", "apps", "--device", device.id, "-j", "-", "--omit-deprecated-fields-in-json"]
        if includeSystem { arguments.append("--include-all-apps") }
        return try DeviceCtlParser.parseApps(json: try await devicectl(arguments))
    }

    public func launch(_ device: Device, app: String) async throws {
        try await devicectl(["process", "launch", "--device", device.id, "--terminate-existing", app])
    }

    public func uninstall(_ device: Device, app: String) async throws {
        try await devicectl(["uninstall", "app", "--device", device.id, app])
    }

    @discardableResult
    private func devicectl(_ arguments: [String]) async throws -> String {
        try await runner.run(xcrun, ["devicectl", "device"] + arguments)
    }
}
