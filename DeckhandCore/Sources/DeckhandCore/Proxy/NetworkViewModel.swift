import Foundation
import Observation

/// Runs the capture proxy and keeps what it sees: the flows, their filter and the setup of devices.
@MainActor
@Observable
public final class NetworkViewModel {
    public enum State: Equatable, Sendable {
        case stopped
        case running(port: Int)
        case failed(String)
    }

    public private(set) var state: State = .stopped
    public private(set) var visible: [HTTPFlow] = []
    public private(set) var totalCount = 0
    public private(set) var apps: [AppCount] = []
    public private(set) var isRoutingMac = false
    public private(set) var setupMessage: String?
    public private(set) var isWorking = false
    public private(set) var deviceState = DeviceProxyState()
    /// The devices being captured. The proxy is one for all of them; it runs while any of them is in here, and what each
    /// device sends is told apart by `matches`.
    public private(set) var captured: [String: Device] = [:]
    /// The slower network of the selected device, if any. Emulators are slowed down themselves, everything else
    /// through the proxy while it is capturing.
    public private(set) var conditions = NetworkConditions.online
    public var selectedFlowId: Int?
    public var isPaused = false

    /// Each device keeps its own filter, like the log's.
    public var filter = HTTPFilter() {
        didSet {
            guard filter != oldValue else { return }
            if let device { savedFilters[device.id] = filter; persistFilters() }
            scheduleRefilter()
        }
    }

    /// Show only what the selected device sent (simulators; Android is told apart by its adb connection).
    public var limitsToDevice = true {
        didSet { if limitsToDevice != oldValue { refilterNow() } }
    }

    /// The port in use while capturing.
    public private(set) var port = 8899
    /// The port the user asked for; nil takes 8899, or a free one when that is taken.
    public var preferredPort: Int?
    /// Listen on the local network too, for iPhones and iPads that cannot use the Mac's loopback.
    public private(set) var allowsNetworkDevices = false
    public var capacity: Int

    @ObservationIgnored private var flows: [HTTPFlow] = []
    @ObservationIgnored private var indexById: [Int: Int] = [:]
    @ObservationIgnored private var matcher = HTTPFilter().compiled()
    @ObservationIgnored private var appCounts: [String: Int] = [:]
    @ObservationIgnored private var server: ProxyServer?
    @ObservationIgnored private var authority: CertificateAuthority?
    @ObservationIgnored private var device: Device?
    /// The devices that were running when the list last changed, so that stopping one can be told from never having started.
    @ObservationIgnored private var seenRunning: Set<String> = []
    /// Devices whose capturing was started by Deckhand to slow them down: it ends when they are set back to full speed.
    @ObservationIgnored private var startedForSlowdown: Set<String> = []
    /// What the proxy applies: one setting for every device it inspects.
    private var proxyConditions = NetworkConditions.online
    /// What was set on each Android emulator itself.
    private var emulatorConditions: [String: NetworkConditions] = [:]
    @ObservationIgnored private var savedFilters: [String: HTTPFilter] = [:]
    @ObservationIgnored private var refilterTask: Task<Void, Never>?
    @ObservationIgnored private var configuredAndroid: [String: Device] = [:]
    @ObservationIgnored private var pendingFlows: [HTTPFlow] = []
    @ObservationIgnored private var flushScheduled = false

    private let runner: any ShellRunner
    private let locateSDK: @Sendable () -> AndroidSDK?
    private let makeAuthority: @Sendable () throws -> CertificateAuthority
    private let systemProxy: SystemProxy
    private let defaults: UserDefaults?
    private let debounce: Duration
    private let helperAPK: @Sendable () -> String?
    private static let filtersKey = "networkFilters"

    public init(runner: any ShellRunner = ProcessShellRunner(), capacity: Int = 5000, debounce: Duration = .milliseconds(150),
                defaults: UserDefaults? = nil, systemProxy: SystemProxy = SystemProxy(),
                makeAuthority: @escaping @Sendable () throws -> CertificateAuthority = { try CertificateAuthority() },
                helperAPK: @escaping @Sendable () -> String? = { nil },
                locateSDK: @escaping @Sendable () -> AndroidSDK?) {
        self.runner = runner
        self.capacity = capacity
        self.debounce = debounce
        self.defaults = defaults
        self.systemProxy = systemProxy
        self.makeAuthority = makeAuthority
        self.locateSDK = locateSDK
        self.helperAPK = helperAPK
        if let data = defaults?.data(forKey: Self.filtersKey),
           let saved = try? JSONDecoder().decode([String: HTTPFilter].self, from: data) {
            savedFilters = saved
        }
    }

    public var isRunning: Bool { if case .running = state { true } else { false } }

    /// Whether the proxy is taking in what `device` sends. Each device has its own, and keeps it while another is shown.
    public func isCapturing(_ device: Device) -> Bool { isRunning && captured[device.id] != nil }

    public var selectedFlow: HTTPFlow? {
        selectedFlowId.flatMap { id in indexById[id].map { flows[$0] } }
    }

    public var certificatePath: String? { authority?.certificatePath ?? (try? makeAuthority())?.certificatePath }

    // MARK: Capture

    /// Starts capturing `target` (the selected device when nil), starting the proxy too if no other device is using it.
    /// `routeMac` also points the macOS proxy at it, which is what makes simulators use it.
    public func start(routeMac: Bool, for target: Device? = nil) async {
        let target = target ?? device
        defer { refreshConditions() }
        if let target {
            captured[target.id] = target
            if target.state == .running { seenRunning.insert(target.id) }
        }
        if isRunning {
            // another device already runs the proxy: this one joins it
            do {
                if routeMac, !isRoutingMac {
                    try await systemProxy.enable(port: port)
                    isRoutingMac = true
                }
            } catch {
                setupMessage = ErrorMessage.friendly(error)
            }
            await attachAndroidHelpers(for: target)
            await refreshDeviceState()
            return
        }
        do {
            let authority = try makeAuthority()
            self.authority = authority
            let server = try startServer(authority: authority)
            self.server = server
            port = server.port
            state = .running(port: server.port)
            if routeMac {
                try await systemProxy.enable(port: server.port)
                isRoutingMac = true
            }
            await attachAndroidHelpers(for: target)
            await refreshDeviceState()
        } catch {
            server?.stop()
            server = nil
            captured = [:]
            state = .failed(String(describing: error))
        }
    }

    /// The preferred port, or when none was chosen 8899 and then any free port.
    private func startServer(authority: CertificateAuthority) throws -> ProxyServer {
        func attempt(port: Int) throws -> ProxyServer {
            var options = ProxyOptions()
            options.port = port
            options.allowsNetworkClients = allowsNetworkDevices
            options.inspects = ProxyOptions.inspectsMobile
            let server = ProxyServer(authority: authority, options: options) { [weak self] flow in
                Task { @MainActor in self?.receive(flow) }
            }
            server.conditions = proxyConditions
            try server.start()
            return server
        }
        if let preferredPort, preferredPort > 0 { return try attempt(port: preferredPort) }
        do { return try attempt(port: 8899) } catch { return try attempt(port: 0) }
    }

    /// Where an iPhone or iPad on the same network points its proxy setting.
    public var networkAddress: String? { LocalNetwork.ipv4Addresses().first }

    /// Stops capturing for every device, and the proxy with it.
    public func stop() async {
        captured = [:]
        startedForSlowdown = []
        // the proxy is what slows simulators and phones down: without it there is nothing to apply, nor on its next start
        proxyConditions = .online
        defer { refreshConditions() }
        server?.stop()
        server = nil
        if isRoutingMac || systemProxy.hasPendingBackup {
            try? await systemProxy.restore()
            isRoutingMac = false
        }
        if let authority {
            let setup = makeSetup(authority)
            await setup.detachHelpers()
            // devices that use the global proxy setting instead of the helper must not keep it
            for device in configuredAndroid.values { try? await setup.disableAndroidProxy(on: device, port: port) }
        }
        configuredAndroid = [:]
        if isRunning { state = .stopped }
    }

    /// Stops capturing `device` only. The proxy goes on while another device uses it, and stops with the last one.
    public func stopCapture(_ device: Device) async {
        guard captured[device.id] != nil else { return }
        captured[device.id] = nil
        startedForSlowdown.remove(device.id)
        guard !captured.isEmpty else { await stop(); return }
        defer { refreshConditions() }
        if let authority {
            let setup = makeSetup(authority)
            if device.platform == .android {
                await setup.detachHelpers(serial: device.serial)
                if let configured = configuredAndroid.removeValue(forKey: device.id) {
                    try? await setup.disableAndroidProxy(on: configured, port: port)
                }
            }
        }
        // the Mac's proxy setting is only for simulators
        let simulatorsLeft = captured.values.contains { $0.platform == .ios && !$0.isPhysical }
        if device.platform == .ios, !device.isPhysical, !simulatorsLeft, isRoutingMac {
            try? await systemProxy.restore()
            isRoutingMac = false
        }
        await refreshDeviceState()
    }

    /// Called whenever the device list changes: a device's capturing ends with the device, and the proxy with the last one.
    public func deviceListChanged(_ devices: [Device]) async {
        // an emulator forgets its network settings when it stops
        let running = Set(devices.filter { $0.state == .running }.map(\.id))
        emulatorConditions = emulatorConditions.filter { running.contains($0.key) }
        conditions = device.map(conditions(for:)) ?? .online
        let stopped = captured.values.filter { seenRunning.contains($0.id) && !running.contains($0.id) }
        seenRunning = running
        guard isRunning, !stopped.isEmpty else { return }
        for device in stopped { await stopCapture(device) }
        if let selected = device, stopped.contains(where: { $0.id == selected.id }) {
            setupMessage = "\(selected.name) stopped, so capturing stopped too."
        }
    }

    /// Whether `device` is slowed down by its emulator rather than by the proxy.
    public func slowsEmulator(_ device: Device) -> Bool { device.platform == .android && !device.isPhysical }

    /// What slows `device` down now, if anything.
    public func conditions(for device: Device) -> NetworkConditions {
        if slowsEmulator(device) { return emulatorConditions[device.id] ?? .online }
        // the proxy slows down the devices it captures, and no others
        return isCapturing(device) ? proxyConditions : .online
    }

    private func refreshConditions() {
        conditions = device.map(conditions(for:)) ?? .online
    }

    /// Slows the network of `device` down, or lifts it with `.online`.
    public func setConditions(_ new: NetworkConditions, for device: Device) async {
        if slowsEmulator(device) {
            guard let sdk = locateSDK() else { setupMessage = "Android SDK not found — set path in Settings"; return }
            do {
                try await EmulatorTools(runner: runner, sdk: sdk).setNetwork(device, new)
                emulatorConditions[device.id] = new
            } catch {
                setupMessage = ErrorMessage.friendly(error)
                return
            }
        } else {
            // simulators and phones are slowed down by the proxy, so it must be capturing them: that is started here
            if new.isLimited, !isCapturing(device) {
                guard await startForSlowdown(device) else { return }
            }
            proxyConditions = new
            server?.conditions = new
            // capturing that only the slowdown asked for ends with it
            if !new.isLimited, startedForSlowdown.remove(device.id) != nil { await stopCapture(device) }
        }
        if device.id == self.device?.id { refreshConditions() }
    }

    /// Starts capturing `device` because it is to be slowed down, and says so. False when it could not be started.
    private func startForSlowdown(_ device: Device) async -> Bool {
        if device.platform == .ios, !device.isPhysical {
            await start(routeMac: true, for: device)
        } else {
            // physical devices must be pointed at the proxy
            await setUp(device)
        }
        guard isCapturing(device) else {
            setupMessage = setupMessage ?? "Could not start capturing \(device.name), which slowing it down needs."
            return false
        }
        startedForSlowdown.insert(device.id)
        if setupMessage == nil {
            setupMessage = "Capturing started for \(device.name): the slowdown goes through Deckhand's proxy. "
                + "It stops when you set the network back to No Limit."
        }
        return true
    }

    /// The selected device, for the panel.
    public var slowsEmulator: Bool { device.map(slowsEmulator) ?? false }

    public func setConditions(_ new: NetworkConditions) async {
        guard let device else { return }
        await setConditions(new, for: device)
    }

    public func dismissSetupMessage() {
        setupMessage = nil
    }

    public func clear() {
        flows = []
        indexById = [:]
        appCounts = [:]
        visible = []
        totalCount = 0
        apps = []
        selectedFlowId = nil
    }

    /// Restores the macOS proxy a crashed run left switched on. Call once at launch.
    public func recoverSystemProxy() async {
        if systemProxy.hasPendingBackup { try? await systemProxy.restore() }
    }

    /// For quitting: the macOS proxy must not stay pointed at a proxy that is gone.
    public nonisolated static func restoreSystemProxyForQuit() {
        SystemProxy().restoreNow()
    }

    /// Lets the helper app on `device` (on every connected device when nil) reach the proxy; it connects its VPN when it sees it.
    private func attachAndroidHelpers(for device: Device? = nil) async {
        guard let authority else { return }
        if let device {
            guard device.platform == .android else { return }
            await makeSetup(authority).attachHelpers(port: port, serial: device.serial)
        } else {
            await makeSetup(authority).attachHelpers(port: port)
        }
    }

    private func makeSetup(_ authority: CertificateAuthority) -> DeviceProxySetup {
        DeviceProxySetup(runner: runner, sdk: locateSDK(), authority: authority, helperAPK: helperAPK())
    }

    /// For quitting: Android devices keep the proxy setting after the app is gone, which would cut their network.
    public func restoreAndroidForQuit() {
        guard let sdk = locateSDK() else { return }
        func adb(_ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sdk.adbPath)
            process.arguments = arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        // the helpers drop their VPN once the proxy is gone, but not before their next check
        if helperAPK() != nil {
            let serials = adb(["devices"]).split(whereSeparator: \.isNewline).dropFirst().compactMap { line -> String? in
                let parts = line.split(whereSeparator: \.isWhitespace)
                return parts.count >= 2 && parts[1] == "device" ? String(parts[0]) : nil
            }
            for serial in serials where adb(["-s", serial, "shell", "pm", "path", DeviceProxySetup.helperPackage]).contains("package:") {
                _ = adb(["-s", serial] + DeviceProxySetup.helperArguments("stop"))
                _ = adb(["-s", serial, "reverse", "--remove", "tcp:\(DeviceProxySetup.devicePort)"])
            }
        }
        for device in configuredAndroid.values {
            guard let serial = device.serial else { continue }
            _ = adb(["-s", serial, "shell", "settings", "put", "global", "http_proxy", ":0"])
        }
        configuredAndroid = [:]
    }

    // MARK: Device

    public func select(_ device: Device) async {
        if self.device?.id != device.id {
            self.device = nil
            filter = savedFilters[device.id] ?? HTTPFilter()
        }
        self.device = device
        if device.state == .running { seenRunning.insert(device.id) }
        conditions = self.conditions(for: device)
        setupMessage = nil
        await refreshDeviceState()
        refilterNow()
    }

    public func refreshDeviceState() async {
        guard let device, let authority else { deviceState = DeviceProxyState(); return }
        let setup = makeSetup(authority)
        var state = DeviceProxyState(certificateInstalled: setup.isCertificateInstalled(on: device))
        switch (device.platform, device.isPhysical) {
        case (.ios, false): state.proxyConfigured = isRoutingMac
        case (.android, _):
            state.proxyConfigured = await setup.isAndroidProxyEnabled(on: device, port: port)
            // the system store is what counts for most apps, and it is emptied by a restart: ask the device, not the record
            state.androidTrust = await setup.androidTrust(on: device)
            state.certificateInstalled = state.androidTrust == .system
            // a certificate in the user store cannot be seen from here, but decrypted traffic proves it works
            state = merging(state, evidence: trafficEvidence())
        case (.ios, true): state = merging(state, evidence: trafficEvidence())
        }
        deviceState = state
    }

    /// Does what the device needs: trust the certificate, and for Android point it at the proxy.
    public func setUp(_ device: Device) async {
        guard !isWorking else { return }
        isWorking = true
        setupMessage = nil
        defer { isWorking = false }
        if device.platform == .ios, device.isPhysical {
            await setUpPhone(device)
            await refreshDeviceState()
            return
        }
        // starts the proxy, or adds the device to the one that runs
        await start(routeMac: device.platform == .ios, for: device)
        guard isRunning, let authority else { return }
        let setup = makeSetup(authority)
        // a certificate that has just been installed may now be trusted by the apps that rejected it
        server?.forgetPassedThroughHosts()
        do {
            do {
                if try await needsCertificate(device, setup) { setupMessage = try await setup.installCertificate(on: device) }
            } catch {
                // the proxy setting is still worth applying: plain HTTP works without the certificate
                setupMessage = ErrorMessage.friendly(error)
            }
            if device.platform == .android {
                try await setup.enableAndroidProxy(on: device, port: port)
                // only devices on the global proxy setting need undoing when capturing stops; the helper does it itself
                if helperAPK() == nil { configuredAndroid[device.id] = device }
            } else if !isRoutingMac {
                try await systemProxy.enable(port: port)
                isRoutingMac = true
            }
        } catch {
            setupMessage = ErrorMessage.friendly(error)
        }
        await refreshDeviceState()
    }

    private func needsCertificate(_ device: Device, _ setup: DeviceProxySetup) async throws -> Bool {
        guard device.platform == .android else { return !setup.isCertificateInstalled(on: device) }
        // the system store is read from the device; a user-store certificate only shows by decrypted traffic,
        // and is all a device that cannot be rooted can get
        switch await setup.androidTrust(on: device) {
        case .system: return false
        case .rootable: return true
        case .locked, nil: return !trafficEvidence().decrypted
        }
    }

    /// Phones go over the network: listen there, and say what to do on the phone.
    private func setUpPhone(_ phone: Device) async {
        if !isRunning || !allowsNetworkDevices {
            // listening on the network means a new proxy: the others go on capturing through it
            let others = captured.filter { $0.key != phone.id }
            await stop()
            allowsNetworkDevices = true
            await start(routeMac: false, for: phone)
            for (id, device) in others where isRunning { captured[id] = device }
        } else {
            captured[phone.id] = phone
        }
        guard isRunning else { return }
        let address = networkAddress.map { "\($0) port \(port)" } ?? "this Mac's address, port \(port)"
        setupMessage = "On the phone, on the same Wi-Fi: Settings › Wi-Fi › ⓘ › Configure Proxy › Manual, server and port: \(address). "
            + "Then open http://deckhand.proxy in Safari, download the certificate, install it in Settings › Profile Downloaded, "
            + "and turn it on in Settings › General › About › Certificate Trust Settings."
    }

    public func installCertificate(on device: Device) async {
        if device.platform == .ios, device.isPhysical {
            await setUp(device)
            return
        }
        guard let authority = authority ?? (try? makeAuthority()) else { return }
        self.authority = authority
        isWorking = true
        defer { isWorking = false }
        server?.forgetPassedThroughHosts()
        do {
            setupMessage = try await makeSetup(authority).installCertificate(on: device)
        } catch {
            setupMessage = ErrorMessage.friendly(error)
        }
        await refreshDeviceState()
    }

    public func stopRouting(_ device: Device) async {
        if device.platform == .ios, device.isPhysical {
            allowsNetworkDevices = false
            if isRunning {
                let others = captured.filter { $0.key != device.id }
                await stop()
                if let first = others.values.first {
                    await start(routeMac: others.values.contains { $0.platform == .ios && !$0.isPhysical }, for: first)
                    for (id, other) in others where isRunning { captured[id] = other }
                }
            }
            setupMessage = nil
            await refreshDeviceState()
            return
        }
        if device.platform == .android, let authority {
            try? await makeSetup(authority).disableAndroidProxy(on: device, port: port)
            configuredAndroid[device.id] = nil
        } else if isRoutingMac {
            try? await systemProxy.restore()
            isRoutingMac = false
        }
        await refreshDeviceState()
    }

    // MARK: Flows

    func receive(_ flow: HTTPFlow) {
        // a simulator that is not being captured may still use the Mac's proxy setting: what it sends is not wanted
        if isRunning, let id = flow.client.deviceId, captured[id] == nil { return }
        pendingFlows.append(flow)
        guard !flushScheduled else { return }
        flushScheduled = true
        // flows update several times each, so changes are applied in batches
        Task { [debounce] in
            try? await Task.sleep(for: min(debounce, .milliseconds(80)))
            flushPending()
        }
    }

    func flushPending() {
        flushScheduled = false
        let batch = pendingFlows
        pendingFlows = []
        guard !isPaused || !batch.isEmpty else { return }
        for flow in batch { apply(flow) }
        if flows.count > capacity {
            let drop = flows.count - capacity + capacity / 10
            flows.removeFirst(drop)
            indexById = Dictionary(uniqueKeysWithValues: flows.enumerated().map { ($1.id, $0) })
            appCounts = flows.reduce(into: [:]) { $0[$1.appName, default: 0] += 1 }
            refilterNow()
        }
        if device != nil, !(deviceState.proxyConfigured && deviceState.certificateInstalled) {
            let before = deviceState
            deviceState = merging(deviceState, evidence: trafficEvidence())
            // the manual steps worked: their instructions are no longer needed
            if deviceState != before, deviceState.proxyConfigured, deviceState.certificateInstalled { setupMessage = nil }
        }
        totalCount = flows.count
        apps = appCounts.map { AppCount(name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
    }

    private func apply(_ flow: HTTPFlow) {
        if let index = indexById[flow.id] {
            flows[index] = flow
            if let position = visible.firstIndex(where: { $0.id == flow.id }) {
                if matches(flow) { visible[position] = flow } else { visible.remove(at: position) }
            } else if matches(flow) {
                insertVisible(flow)
            }
        } else {
            indexById[flow.id] = flows.count
            flows.append(flow)
            appCounts[flow.appName, default: 0] += 1
            if matches(flow) { visible.append(flow) }
        }
    }

    private func insertVisible(_ flow: HTTPFlow) {
        let position = visible.firstIndex { $0.id > flow.id } ?? visible.endIndex
        visible.insert(flow, at: position)
    }

    /// What the traffic seen so far says about the selected device, for setups that cannot be checked directly:
    /// phones and the user certificate store of Android.
    private func trafficEvidence() -> (seen: Bool, decrypted: Bool) {
        guard let device else { return (false, false) }
        let isDevice: (HTTPFlow) -> Bool
        switch (device.platform, device.isPhysical) {
        case (.ios, true): isDevice = { $0.client.remoteAddress != nil }
        case (.android, _): isDevice = { $0.client.app == "Android (adb)" || $0.client.app == "Android emulator" }
        default: return (false, false)
        }
        let mine = flows.filter(isDevice)
        return (!mine.isEmpty, mine.contains { $0.isHTTPS && !$0.isTunnel && $0.status != nil })
    }

    private func merging(_ state: DeviceProxyState, evidence: (seen: Bool, decrypted: Bool)) -> DeviceProxyState {
        var state = state
        state.proxyConfigured = state.proxyConfigured || evidence.seen
        state.certificateInstalled = state.certificateInstalled || evidence.decrypted
        return state
    }

    private func matches(_ flow: HTTPFlow) -> Bool {
        if limitsToDevice, let device, device.platform == .ios, device.isPhysical {
            guard flow.client.remoteAddress != nil else { return false }
        }
        if limitsToDevice, let device, device.platform == .ios, !device.isPhysical {
            guard flow.client.deviceId == device.id else { return false }
        }
        if limitsToDevice, let device, device.platform == .android {
            guard flow.client.app == "Android (adb)" || flow.client.app == "Android emulator" else { return false }
        }
        return matcher.matches(flow)
    }

    private func scheduleRefilter() {
        refilterTask?.cancel()
        refilterTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            refilterNow()
        }
    }

    private func refilterNow() {
        matcher = filter.compiled()
        visible = flows.filter(matches)
    }

    private func persistFilters() {
        guard let defaults, let data = try? JSONEncoder().encode(savedFilters) else { return }
        defaults.set(data, forKey: Self.filtersKey)
    }
}
