import Foundation
import Testing
@testable import DeckhandCore

private func entry(_ message: String, level: LogLevel = .info, app: String? = "com.example", tag: String = "Tag", pid: Int? = 1) -> LogEntry {
    LogEntry(time: "12:00:00.000", level: level, pid: pid, app: app, tag: tag, message: message)
}

@Test func parsesAThreadtimeLogcatLine() throws {
    let parsed = try #require(LogParser.parseLogcat("11-24 16:20:01.123  1234  5678 E AndroidRuntime: FATAL EXCEPTION: main"))
    #expect(parsed.time == "16:20:01.123")
    #expect(parsed.pid == 1234)
    #expect(parsed.level == .error)
    #expect(parsed.tag == "AndroidRuntime")
    #expect(parsed.message == "FATAL EXCEPTION: main")
    #expect(parsed.app == nil)
}

@Test func logcatTagsMayContainSpacesAndMessagesColons() throws {
    let parsed = try #require(LogParser.parseLogcat("11-24 16:20:01.123  10  11 D My Tag : key: value"))
    #expect(parsed.tag == "My Tag")
    #expect(parsed.message == "key: value")
    #expect(try #require(LogParser.parseLogcat("11-24 16:20:01.123  10  11 W Tag:")).message == "")
}

@Test func logcatBufferMarkersBecomeInfoAndGarbageIsSkipped() throws {
    let marker = try #require(LogParser.parseLogcat("--------- beginning of main"))
    #expect(marker.level == .info && marker.tag == "logcat" && marker.message == "beginning of main")
    #expect(LogParser.parseLogcat("not a log line") == nil)
}

@Test func parsesAnAppleNdjsonEvent() throws {
    let line = #"{"eventMessage":"hello","messageType":"Error","subsystem":"com.example","category":"net","processImagePath":"/x/My.app/My","processID":42,"timestamp":"2026-11-24 16:20:00.123456+0100"}"#
    let parsed = try #require(LogParser.parseApple(line))
    #expect(parsed.time == "16:20:00.123")
    #expect(parsed.level == .error)
    #expect(parsed.app == "My")
    #expect(parsed.pid == 42)
    #expect(parsed.tag == "com.example:net")
    #expect(parsed.message == "hello")
    #expect(LogParser.parseApple("Filtering the log data using \"...\"") == nil)
    #expect(LogParser.parseApple("{broken") == nil)
}

@Test func appleLevelsMap() {
    #expect(LogParser.appleLevel("Debug") == .debug)
    #expect(LogParser.appleLevel("Fault") == .fault)
    #expect(LogParser.appleLevel("Default") == .info)
    #expect(LogParser.appleLevel(nil) == .info)
}

@Test func lineSplitterHoldsPartialLinesAndStripsCarriageReturns() {
    var splitter = LineSplitter()
    #expect(splitter.push(Data("one\r\ntw".utf8)) == ["one"])
    #expect(splitter.push(Data("o\nthree".utf8)) == ["two"])
    #expect(splitter.push(Data("\n".utf8)) == ["three"])
}

@Test func filterMatchesTextLevelAndApps() {
    let matcher = LogFilter(query: "NETWORK", minimumLevel: .warning, apps: ["com.example"]).compiled()
    #expect(matcher.matches(entry("network down", level: .error)))
    #expect(!matcher.matches(entry("network down", level: .info)))
    #expect(!matcher.matches(entry("network down", level: .error, app: "other")))
    #expect(!matcher.matches(entry("disk full", level: .error)))
    #expect(LogFilter(query: "net").compiled().matches(entry("x", tag: "Network")))   // tag and app match too
    #expect(LogFilter(apps: ["pid 7"]).compiled().matches(entry("x", app: nil, pid: 7)))
}

@Test func regexFilterAndInvalidPatterns() {
    let regex = LogFilter(query: #"^\d+ items$"#, isRegex: true).compiled()
    #expect(regex.matches(entry("42 items")))
    #expect(!regex.matches(entry("many items")))
    let broken = LogFilter(query: "(", isRegex: true)
    #expect(!broken.isValid)
    #expect(broken.compiled().matches(entry("anything")))   // an invalid pattern hides nothing
    #expect(!LogFilter().isActive)
    #expect(LogFilter(minimumLevel: .error).isActive)
}

@Test func sourceCommandsPerPlatform() throws {
    let sdk = AndroidSDK(root: "/sdk")
    let android = Device(id: "Pixel", name: "Pixel", platform: .android, osVersion: "API 36", state: .running, serial: "emulator-5554")
    let source = try LogSource.make(for: android, sdk: sdk)
    #expect(source.executable == "/sdk/platform-tools/adb")
    #expect(source.arguments == ["-s", "emulator-5554", "logcat", "-v", "threadtime", "-T", "500"])
    let sim = Device(id: "UDID", name: "iPhone", platform: .ios, osVersion: "iOS 27", state: .running)
    #expect(try LogSource.make(for: sim, sdk: nil).arguments == ["simctl", "spawn", "UDID", "log", "stream", "--style", "ndjson", "--level", "debug"])
    let phone = Device(id: "P", name: "P", platform: .ios, osVersion: "iOS", state: .running, isPhysical: true)
    #expect(throws: LogSourceError.self) { try LogSource.make(for: phone, sdk: nil) }
    #expect(throws: LogSourceError.self) { try LogSource.make(for: android, sdk: nil) }
}

@Test func processNamesParseAndRefreshAtMostOnceInTheInterval() async {
    #expect(AndroidProcessNames.parse("  PID NAME\n 1 init\n 2345 com.example.app\n") == [1: "init", 2345: "com.example.app"])
    let runner = MockShellRunner()
    runner.responses["/sdk/platform-tools/adb -s S shell ps -A -o PID,NAME"] = .success("PID NAME\n10 com.a\n")
    let names = AndroidProcessNames(runner: runner, adbPath: "/sdk/platform-tools/adb", serial: "S")
    #expect(await names.name(for: 10) == "com.a")
    #expect(await names.name(for: 99) == nil)
    #expect(await names.name(for: 98) == nil)
    #expect(runner.commands.count == 1)   // the unknown pids did not trigger another listing
}

@MainActor
private func makeModel(capacity: Int = 100, streamer: any ByteStreaming = IdleStreamer()) -> LogViewModel {
    LogViewModel(streamer: streamer, capacity: capacity, debounce: .milliseconds(10)) { AndroidSDK(root: "/sdk") }
}

private struct IdleStreamer: ByteStreaming {
    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { _ in }
    }
}

@MainActor
@Test func ingestNumbersEntriesCountsAppsAndAppliesTheFilterToNewOnes() async throws {
    let model = makeModel()
    model.ingest([entry("a", app: "com.a"), entry("b", app: "com.b"), entry("c", app: "com.a")])
    #expect(model.visible.map(\.id) == [1, 2, 3])
    #expect(model.apps == [.init(name: "com.a", count: 2), .init(name: "com.b", count: 1)])

    model.filter = LogFilter(apps: ["com.b"])
    // the filter applies after its debounce: wait for it rather than for a fixed time, which a slow machine overruns
    for _ in 0..<150 where model.visible.map(\.message) != ["b"] { try await Task.sleep(for: .milliseconds(20)) }
    #expect(model.visible.map(\.message) == ["b"])
    model.ingest([entry("d", app: "com.b"), entry("e", app: "com.a")])
    #expect(model.visible.map(\.message) == ["b", "d"])
    #expect(model.totalCount == 5)
}

@MainActor
@Test func pausingQueuesEntriesUntilResumed() {
    let model = makeModel()
    model.ingest([entry("a")])
    model.isPaused = true
    model.ingest([entry("b"), entry("c")])
    #expect(model.visible.count == 1)
    #expect(model.queuedWhilePaused == 2)
    model.isPaused = false
    #expect(model.visible.map(\.message) == ["a", "b", "c"])
    #expect(model.queuedWhilePaused == 0)
}

@MainActor
@Test func theBufferDropsTheOldestEntriesPastCapacity() {
    let model = makeModel(capacity: 10)
    model.ingest((1...10).map { entry("m\($0)") })
    model.ingest([entry("m11")])
    #expect(model.totalCount <= 10)
    #expect(model.visible.last?.message == "m11")
    #expect(model.visible.first?.message != "m1")
    #expect(model.visible.count == model.totalCount)
}

private struct LinesStreamer: ByteStreaming {
    let lines: [String]
    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data((lines.joined(separator: "\n") + "\n").utf8))
            continuation.finish()
        }
    }
}

@MainActor
@Test func startStreamsParsesAndResolvesAndroidPackages() async throws {
    let runner = MockShellRunner()
    runner.responses["/sdk/platform-tools/adb -s emulator-5554 shell ps -A -o PID,NAME"] = .success("PID NAME\n1234 com.example.app\n")
    let streamer = LinesStreamer(lines: [
        "--------- beginning of main",
        "11-24 16:20:01.123  1234  5678 I MyTag: hello",
        "garbage",
        "11-24 16:20:02.000  1234  5678 E MyTag: boom"])
    let model = LogViewModel(runner: runner, streamer: streamer, debounce: .milliseconds(10)) { AndroidSDK(root: "/sdk") }
    let device = Device(id: "Pixel", name: "Pixel", platform: .android, osVersion: "API 36", state: .running, serial: "emulator-5554")
    model.start(device)
    for _ in 0..<40 where model.totalCount < 3 { try await Task.sleep(for: .milliseconds(25)) }
    #expect(model.visible.map(\.message) == ["beginning of main", "hello", "boom"])
    #expect(model.visible.last?.app == "com.example.app")
    #expect(model.apps.first?.name == "com.example.app")
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.state == .idle)   // the stream ended
}

@MainActor
@Test func startReportsADeviceThatHasNoLog() {
    let model = makeModel()
    model.start(Device(id: "P", name: "P", platform: .ios, osVersion: "iOS", state: .running, isPhysical: true))
    if case .failed(let message) = model.state { #expect(message.contains("Console.app")) } else { Issue.record("expected failure") }
}

@MainActor
@Test func startClearsThePreviousDevicesEntries() {
    let model = makeModel()
    model.ingest([entry("old")])
    model.start(Device(id: "U", name: "iPhone", platform: .ios, osVersion: "iOS", state: .running))
    #expect(model.visible.isEmpty)
    #expect(model.totalCount == 0)
    model.stop()
    #expect(model.state == .idle)
}

@MainActor
@Test func copyTextKeepsLinesAndMessagesApartWithLineBreaks() {
    let model = makeModel()
    let first = LogEntry(time: "12:00:00.000", level: .warning, pid: 1, app: "App", tag: "T", message: "one")
    let second = LogEntry(time: "12:00:01.000", level: .error, pid: 1, app: "App", tag: "T", message: "two")
    #expect(model.text(of: [first, second]) == "12:00:00.000 W App T: one\n12:00:01.000 E App T: two")
    #expect(model.messages(of: [first, second]) == "one\ntwo")
    #expect(model.messages(of: []) == "")
}

@MainActor
@Test func loweringTheCapacityTrimsAtOnceAndNeverGoesBelowAFloor() {
    let model = makeModel(capacity: 1000)
    model.ingest((1...500).map { entry("m\($0)") })
    model.capacity = 200
    #expect(model.totalCount <= 200)
    #expect(model.visible.last?.message == "m500")
    model.capacity = 1
    #expect(model.capacity == 100)
}

private final class StreamProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var ended = 0
    func begin() { lock.withLock { started += 1 } }
    func end() { lock.withLock { ended += 1 } }
    var counts: (started: Int, ended: Int) { lock.withLock { (started, ended) } }
}

private struct ProbedStreamer: ByteStreaming {
    let probe: StreamProbe
    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<Data, Error> {
        probe.begin()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [probe] _ in probe.end() }
        }
    }
}

@MainActor
@Test func stoppingTheLogEndsTheUnderlyingProcessAndStartingNothingListensBefore() async throws {
    let probe = StreamProbe()
    let model = LogViewModel(streamer: ProbedStreamer(probe: probe)) { AndroidSDK(root: "/sdk") }
    #expect(probe.counts.started == 0)   // creating the model listens to nothing

    let sim = Device(id: "U", name: "iPhone", platform: .ios, osVersion: "iOS", state: .running)
    model.start(sim)
    try await Task.sleep(for: .milliseconds(100))
    #expect(probe.counts == (1, 0))

    model.stop()
    try await Task.sleep(for: .milliseconds(150))
    #expect(probe.counts == (1, 1))   // the stream, and so the logging process, is gone
    #expect(model.state == .idle)

    model.start(sim)   // switching device restarts rather than stacking streams
    model.start(Device(id: "V", name: "iPad", platform: .ios, osVersion: "iOS", state: .running))
    try await Task.sleep(for: .milliseconds(150))
    model.stop()
    try await Task.sleep(for: .milliseconds(150))
    #expect(probe.counts.started == 3 && probe.counts.ended == 3)   // every stream that started has been ended
}
