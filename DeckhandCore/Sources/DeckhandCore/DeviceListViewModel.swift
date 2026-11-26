import Foundation
import Observation

@MainActor
@Observable
public final class DeviceListViewModel {
    public private(set) var iosDevices: [Device] = []
    public private(set) var androidDevices: [Device] = []
    public private(set) var iosError: String?
    public private(set) var androidError: String?
    public private(set) var physicalDevices: [Device] = []
    public private(set) var physicalError: String?
    public private(set) var busyDeviceIds: Set<String> = []
    private var busyActions: [String: DeviceAction] = [:]

    /// What is being done to `device` now, for a progress over its screen.
    public func busyAction(for device: Device) -> DeviceAction? { busyActions[device.id] }
    public private(set) var rowErrors: [String: String] = [:]

    /// Simulators and emulators that are up. Attached phones are always "running", so they do not count.
    public var runningDevices: [Device] { (iosDevices + androidDevices).filter { $0.state == .running } }
    public var bootingDevices: [Device] { (iosDevices + androidDevices).filter { $0.state == .booting } }

    private let simulatorService: SimulatorService
    private let runner: any ShellRunner
    private let locateSDK: @Sendable () -> AndroidSDK?
    private let launchOptions: @Sendable () -> AndroidLaunchOptions
    private let showPhysicalDevices: @Sendable () -> Bool
    private let physicalIOSInterval: Duration
    private var physicalIOSCache: (at: ContinuousClock.Instant, devices: [Device])?
    private let bootTimeout: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var bootDeadlines: [String: ContinuousClock.Instant] = [:]
    private var refreshChain: Task<Void, Never>?

    public init(runner: any ShellRunner = ProcessShellRunner(),
                bootTimeout: Duration = .seconds(60),
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                launchOptions: @escaping @Sendable () -> AndroidLaunchOptions = { AndroidLaunchOptions() },
                showPhysicalDevices: @escaping @Sendable () -> Bool = { false },
                physicalIOSInterval: Duration = .seconds(15),
                locateSDK: @escaping @Sendable () -> AndroidSDK?) {
        self.runner = runner
        self.simulatorService = SimulatorService(runner: runner)
        self.bootTimeout = bootTimeout
        self.now = now
        self.launchOptions = launchOptions
        self.showPhysicalDevices = showPhysicalDevices
        self.physicalIOSInterval = physicalIOSInterval
        self.locateSDK = locateSDK
    }

    public func device(id: String) -> Device? {
        (iosDevices + androidDevices + physicalDevices).first { $0.id == id }
    }

    public func refresh() async {
        let previous = refreshChain
        let task = Task { @MainActor in
            await previous?.value
            await self.reload()
        }
        refreshChain = task
        await task.value
        if refreshChain == task { refreshChain = nil }
    }

    private func reload() async {
        async let ios = loadIOS()
        async let android = loadAndroid()
        async let physical = loadPhysical()
        let iosResult = await ios
        let androidResult = await android
        (physicalDevices, physicalError) = await physical
        pruneBootDeadlines(presentIds: Set(iosResult.0.map(\.id)).union(androidResult.0.map(\.id)))
        (iosDevices, iosError) = (overlayBooting(iosResult.0), iosResult.1)
        (androidDevices, androidError) = (overlayBooting(androidResult.0), androidResult.1)
    }

    public func perform(_ action: DeviceAction, on device: Device) async {
        busyDeviceIds.insert(device.id)
        busyActions[device.id] = action
        rowErrors[device.id] = nil
        do {
            try await execute(action, on: device)
            if expectsBoot(action, device) {
                bootDeadlines[device.id] = now() + bootTimeout
            } else {
                bootDeadlines[device.id] = nil
            }
        } catch {
            rowErrors[device.id] = friendlyMessage(error)
        }
        // the list is up to date before the device stops being busy, so a stopped device is not shown as running for a moment
        await refresh()
        busyDeviceIds.remove(device.id)
        busyActions[device.id] = nil
    }

    private func loadPhysical() async -> ([Device], String?) {
        guard showPhysicalDevices() else { return ([], nil) }
        let service = PhysicalDeviceService(runner: runner)
        var devices: [Device] = []
        var errors: [String] = []

        if let sdk = locateSDK() {
            do { devices += try await service.listAndroid(sdk: sdk) } catch { errors.append(friendlyMessage(error)) }
        }
        if let cache = physicalIOSCache, now() < cache.at + physicalIOSInterval {
            devices += cache.devices
        } else {
            do {
                let ios = try await service.listIOS()
                physicalIOSCache = (now(), ios)
                devices += ios
            } catch {
                errors.append(friendlyMessage(error))
                devices += physicalIOSCache?.devices ?? []
            }
        }
        return (devices, errors.first)
    }

    private func loadIOS() async -> ([Device], String?) {
        do {
            return (try await simulatorService.listDevices(), nil)
        } catch {
            return (iosDevices, friendlyMessage(error))
        }
    }

    private func loadAndroid() async -> ([Device], String?) {
        guard let service = emulatorService() else {
            return ([], "Android SDK not found — set path in Settings")
        }
        do {
            return (try await service.listDevices(), nil)
        } catch {
            return (androidDevices, friendlyMessage(error))
        }
    }

    private func execute(_ action: DeviceAction, on device: Device) async throws {
        guard !device.isPhysical else {
            throw ShellError(command: "device", exitCode: 1, stderr: "Physical devices can't be started or stopped from here")
        }
        switch device.platform {
        case .ios: try await executeIOS(action, on: device)
        case .android: try await executeAndroid(action, on: device)
        }
    }

    private func executeIOS(_ action: DeviceAction, on device: Device) async throws {
        switch action {
        case .start, .startWithAlternateAudio: try await simulatorService.boot(device.id)
        case .startHeadless: try await simulatorService.boot(device.id, showsWindow: false)
        case .stop: try await simulatorService.shutdown(device.id)
        case .coldBoot: try await simulatorService.coldBoot(device)
        case .erase: try await simulatorService.erase(device)
        }
    }

    private func executeAndroid(_ action: DeviceAction, on device: Device) async throws {
        guard let service = emulatorService() else {
            throw ShellError(command: "android", exitCode: 1, stderr: "Android SDK not found")
        }
        switch action {
        case .start: try await service.start(device.name)
        case .startWithAlternateAudio: try await service.start(device.name, muteAudio: !launchOptions().muteAudio)
        case .startHeadless: try await service.start(device.name, extraArguments: ["-no-window"])
        case .stop: try await service.stop(serial: try serial(of: device))
        case .coldBoot: try await service.coldBoot(device)
        case .erase: try await service.wipe(device)
        }
    }

    private func serial(of device: Device) throws -> String {
        guard let serial = device.serial else {
            throw ShellError(command: "adb emu kill", exitCode: 1,
                             stderr: "\(device.name) is not running")
        }
        return serial
    }

    private func expectsBoot(_ action: DeviceAction, _ device: Device) -> Bool {
        switch action {
        case .start, .startWithAlternateAudio, .startHeadless, .coldBoot: true
        case .erase: device.platform == .android
        case .stop: false
        }
    }

    private func pruneBootDeadlines(presentIds: Set<String>) {
        let currentTime = now()
        bootDeadlines = bootDeadlines.filter { id, deadline in
            presentIds.contains(id) && currentTime < deadline
        }
    }

    private func overlayBooting(_ devices: [Device]) -> [Device] {
        devices.map { device in
            guard bootDeadlines[device.id] != nil else { return device }
            guard device.state == .stopped else {
                bootDeadlines[device.id] = nil
                return device
            }
            return device.withState(.booting)
        }
    }

    private func emulatorService() -> EmulatorService? {
        locateSDK().map { EmulatorService(runner: runner, sdk: $0, launchOptions: launchOptions()) }
    }

    private func friendlyMessage(_ error: Error) -> String {
        guard let shellError = error as? ShellError else { return error.localizedDescription }
        return shellError.stderr.isEmpty ? "Command failed (exit \(shellError.exitCode))" : shellError.stderr
    }
}
