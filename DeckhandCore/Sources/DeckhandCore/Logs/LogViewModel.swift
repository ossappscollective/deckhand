import Foundation
import Observation

/// Streams a device's log and keeps the last `capacity` entries, filtered live.
@MainActor
@Observable
public final class LogViewModel {
    public enum State: Equatable, Sendable {
        case idle
        case streaming
        case failed(String)
    }

    public typealias AppCount = DeckhandCore.AppCount

    public private(set) var visible: [LogEntry] = []
    public private(set) var totalCount = 0
    public private(set) var state: State = .idle
    /// Entries that arrived while paused and are not shown yet.
    public private(set) var queuedWhilePaused = 0
    public private(set) var apps: [AppCount] = []
    /// Apps you installed on the current device, loaded when the app picker opens.
    public private(set) var yourApps: [String] = []
    public private(set) var isFindingApp = false
    public private(set) var discoveryMessage: String?
    /// The program to install when finding the app failed for lack of it.
    public private(set) var discoveryMissingTool: OptionalTool?

    /// Each device keeps its own filter, restored when you come back to it and across launches.
    public var filter = LogFilter() {
        didSet {
            guard filter != oldValue else { return }
            if let device { savedFilters[device.id] = filter; persistFilters() }
            scheduleRefilter()
        }
    }

    public var isPaused = false {
        didSet {
            guard isPaused != oldValue, !isPaused else { return }
            let queued = queue
            queue = []
            queuedWhilePaused = 0
            append(queued)
        }
    }

    /// How many lines are kept; lowering it drops the oldest lines at once.
    @ObservationIgnored public var capacity: Int {
        didSet {
            capacity = max(capacity, 100)
            guard capacity < oldValue, entries.count > capacity else { return }
            trimToCapacity()
        }
    }

    @ObservationIgnored private var entries: [LogEntry] = []
    @ObservationIgnored private var queue: [LogEntry] = []
    @ObservationIgnored private var appCounts: [String: Int] = [:]
    @ObservationIgnored private var matcher = LogFilter().compiled()
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var refilterTask: Task<Void, Never>?
    @ObservationIgnored private var device: Device?
    @ObservationIgnored private var savedFilters: [String: LogFilter] = [:]

    private let runner: any ShellRunner
    private let streamer: any ByteStreaming
    private let locateSDK: @Sendable () -> AndroidSDK?
    private let debounce: Duration
    private let defaults: UserDefaults?
    private static let filtersKey = "logFilters"
    private static let maxSavedFilters = 100

    public init(runner: any ShellRunner = ProcessShellRunner(), streamer: any ByteStreaming = ProcessByteStreamer(),
                capacity: Int = 50_000, debounce: Duration = .milliseconds(150), defaults: UserDefaults? = nil,
                locateSDK: @escaping @Sendable () -> AndroidSDK?) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.filtersKey),
           let saved = try? JSONDecoder().decode([String: LogFilter].self, from: data) {
            savedFilters = saved
        }
        self.runner = runner
        self.streamer = streamer
        self.capacity = capacity
        self.debounce = debounce
        self.locateSDK = locateSDK
    }

    // MARK: Streaming

    /// Starts streaming `device`, replacing whatever was streaming before and clearing the buffer.
    public func start(_ device: Device) {
        stop()
        clear()
        yourApps = []
        discoveryMessage = nil
        if self.device?.id != device.id {
            self.device = nil   // switching device must not write the old filter over the new device's
            filter = savedFilters[device.id] ?? LogFilter()
        }
        self.device = device
        let source: LogSource
        do {
            source = try LogSource.make(for: device, sdk: locateSDK())
        } catch {
            state = .failed(String(describing: error))
            return
        }
        state = .streaming
        let token = generation
        let runner = runner
        let streamer = streamer
        streamTask = Task.detached { [weak self] in
            var splitter = LineSplitter()
            let names = source.adbPath.flatMap { adb in
                source.serial.map { AndroidProcessNames(runner: runner, adbPath: adb, serial: $0) }
            }
            do {
                for try await chunk in streamer.stream(source.executable, source.arguments) {
                    var batch: [LogEntry] = []
                    for line in splitter.push(chunk) {
                        guard var entry = source.parse(line) else { continue }
                        if entry.app == nil, let pid = entry.pid, let names { entry.app = await names.name(for: pid) }
                        batch.append(entry)
                    }
                    if !batch.isEmpty { await self?.receive(batch, token: token) }
                }
                await self?.finish(token: token, error: nil)
            } catch {
                await self?.finish(token: token, error: ErrorMessage.friendly(error))
            }
        }
    }

    public func stop() {
        generation += 1
        streamTask?.cancel()
        streamTask = nil
        refilterTask?.cancel()
        if state == .streaming { state = .idle }
    }

    public func clear() {
        entries = []
        queue = []
        queuedWhilePaused = 0
        appCounts = [:]
        visible = []
        totalCount = 0
        apps = []
    }

    private func receive(_ batch: [LogEntry], token: Int) {
        guard token == generation else { return }
        ingest(batch)
    }

    private func finish(token: Int, error: String?) {
        guard token == generation else { return }
        state = error.map(State.failed) ?? .idle
    }

    // MARK: Apps

    /// Loads the apps you installed on the current device. Only runs when the picker opens.
    public func loadYourApps() async {
        guard let device else { return }
        let discovery = LogAppDiscovery(runner: runner, sdk: locateSDK())
        yourApps = (try? await discovery.yourApps(on: device)) ?? []
    }

    /// Filters the log to the app in the foreground on the device.
    public func filterToCurrentApp() async {
        guard let device, !isFindingApp else { return }
        isFindingApp = true
        discoveryMessage = nil
        discoveryMissingTool = nil
        defer { isFindingApp = false }
        do {
            let app = try await LogAppDiscovery(runner: runner, sdk: locateSDK()).currentApp(on: device)
            filter.apps = [app]
        } catch {
            discoveryMessage = (error as? MissingToolError)?.errorDescription ?? String(describing: error)
            discoveryMissingTool = (error as? MissingToolError)?.tool
        }
    }

    private func persistFilters() {
        guard let defaults else { return }
        if savedFilters.count > Self.maxSavedFilters {
            savedFilters = Dictionary(uniqueKeysWithValues: savedFilters.sorted { $0.key < $1.key }.suffix(Self.maxSavedFilters / 2).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(savedFilters) { defaults.set(data, forKey: Self.filtersKey) }
    }

    // MARK: Entries

    func ingest(_ batch: [LogEntry]) {
        if isPaused {
            queue.append(contentsOf: batch)
            queuedWhilePaused = queue.count
            return
        }
        append(batch)
    }

    private func append(_ batch: [LogEntry]) {
        guard !batch.isEmpty else { return }
        var numbered: [LogEntry] = []
        numbered.reserveCapacity(batch.count)
        for var entry in batch {
            entry.id = nextId
            nextId += 1
            appCounts[entry.appName, default: 0] += 1
            numbered.append(entry)
        }
        entries.append(contentsOf: numbered)
        if entries.count > capacity {
            trimToCapacity()
        } else {
            visible.append(contentsOf: numbered.filter(matcher.matches))
        }
        totalCount = entries.count
        publishApps()
    }

    /// Drops the oldest lines, plus a tenth more so trimming does not happen on every batch.
    private func trimToCapacity() {
        entries.removeFirst(min(entries.count, max(entries.count - capacity, capacity / 10)))
        rebuildCounts()
        refilterNow()
        totalCount = entries.count
        publishApps()
    }

    private func rebuildCounts() {
        appCounts = entries.reduce(into: [:]) { $0[$1.appName, default: 0] += 1 }
    }

    private func publishApps() {
        apps = appCounts.map { AppCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
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
        visible = filter.isActive ? entries.filter(matcher.matches) : entries
    }

    /// Whole lines, one per row, for copying or saving.
    public func text(of entries: [LogEntry]? = nil) -> String {
        (entries ?? visible).map(\.line).joined(separator: "\n")
    }

    /// Only the messages, one per row.
    public func messages(of entries: [LogEntry]? = nil) -> String {
        (entries ?? visible).map(\.message).joined(separator: "\n")
    }
}
