import Foundation
import Testing
@testable import DeckhandCore

@Test func defaultLayoutShowsTheUsualColumnsAndNeverLosesAny() {
    let layout = LogColumnLayout()
    #expect(layout.visible == [.time, .level, .app, .tag, .message])
    #expect(Set(layout.order) == Set(LogColumn.allCases))   // pid is hidden, not missing
    let sparse = LogColumnLayout(order: [.message, .time])
    #expect(Set(sparse.order) == Set(LogColumn.allCases))
    #expect(Array(sparse.order.prefix(2)) == [.message, .time])
}

@Test func columnsResizeWithinLimitsAndMessageStaysFlexible() {
    var layout = LogColumnLayout()
    #expect(layout.width(of: .time) == 84)
    layout.resize(.time, to: 5)
    #expect(layout.width(of: .time) == LogColumn.time.minimumWidth)
    layout.resize(.app, to: 5000)
    #expect(layout.width(of: .app) == 600)
    layout.resize(.message, to: 200)
    #expect(layout.width(of: .message) == 0)
}

@Test func columnsHideAndMoveButTheMessageStays() {
    var layout = LogColumnLayout()
    layout.setVisible(.tag, false)
    layout.setVisible(.pid, true)
    layout.setVisible(.message, false)
    #expect(layout.visible.contains(.message))
    #expect(!layout.visible.contains(.tag))
    #expect(layout.visible.contains(.pid))
    layout.move(.app, to: .time)
    #expect(layout.visible.first == .app)
    layout.move(.app, to: .app)   // a no-op
    #expect(layout.visible.first == .app)
}

@Test func layoutSurvivesJSONAndBadJSONIsRejected() throws {
    var layout = LogColumnLayout(timeFormat: .compact)
    layout.resize(.app, to: 200)
    layout.setVisible(.tag, false)
    layout.move(.message, to: .level)
    let restored = try #require(LogColumnLayout(json: layout.json))
    #expect(restored == layout)
    #expect(LogColumnLayout(json: "nope") == nil)
}

@Test func timeFormatsShortenTheTimestamp() {
    #expect(LogTimeFormat.milliseconds.format("16:20:01.123") == "16:20:01.123")
    #expect(LogTimeFormat.seconds.format("16:20:01.123") == "16:20:01")
    #expect(LogTimeFormat.compact.format("16:20:01.123") == "20:01.1")
    #expect(LogTimeFormat.compact.format("") == "")
}

private func entry(app: String?, pid: Int? = 1) -> LogEntry {
    LogEntry(time: "t", level: .info, pid: pid, app: app, tag: "x", message: "m")
}

@Test func anAppFilterAlsoCoversItsOtherAndroidProcesses() {
    let matcher = LogFilter(apps: ["com.example"]).compiled()
    #expect(matcher.matches(entry(app: "com.example")))
    #expect(matcher.matches(entry(app: "com.example:remote")))
    #expect(!matcher.matches(entry(app: "com.example2")))
    #expect(!matcher.matches(entry(app: "other")))
}

@Test func filtersRoundTripThroughJSON() throws {
    let filter = LogFilter(query: "x", isRegex: true, minimumLevel: .warning, apps: ["a", "b"])
    #expect(try JSONDecoder().decode(LogFilter.self, from: JSONEncoder().encode(filter)) == filter)
}

@MainActor
private func makeModel(defaults: UserDefaults?) -> LogViewModel {
    LogViewModel(streamer: SilentStreamer(), debounce: .milliseconds(5), defaults: defaults) { AndroidSDK(root: "/sdk") }
}

private struct SilentStreamer: ByteStreaming {
    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { _ in } }
}

private let simA = Device(id: "A", name: "A", platform: .ios, osVersion: "iOS", state: .running)
private let simB = Device(id: "B", name: "B", platform: .ios, osVersion: "iOS", state: .running)

@MainActor
@Test func eachDeviceKeepsItsOwnFilter() {
    let model = makeModel(defaults: nil)
    model.start(simA)
    model.filter = LogFilter(query: "alpha", apps: ["App A"])
    model.start(simB)
    #expect(model.filter == LogFilter())   // B starts clean, A's filter did not follow
    model.filter = LogFilter(minimumLevel: .error)
    model.start(simA)
    #expect(model.filter == LogFilter(query: "alpha", apps: ["App A"]))
    model.start(simB)
    #expect(model.filter == LogFilter(minimumLevel: .error))
}

@MainActor
@Test func filtersAreRestoredInANewSession() throws {
    let suite = "deckhand-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = makeModel(defaults: defaults)
    first.start(simA)
    first.filter = LogFilter(query: "saved")
    let second = makeModel(defaults: defaults)
    second.start(simA)
    #expect(second.filter.query == "saved")
}

private let dumpsys = """
  mFocusedApp=ActivityRecord{abc u0 com.other/.Old t1}
  topResumedActivity=ActivityRecord{12cb5d8 u0 com.example.app/.MainActivity t42}
"""

@Test func foregroundPackageComesFromDumpsys() {
    #expect(LogAppDiscovery.parseForegroundPackage(dumpsys) == "com.example.app")
    #expect(LogAppDiscovery.parseForegroundPackage("  mResumedActivity: ActivityRecord{1 u10 com.work.app/com.work.Main t3}") == "com.work.app")
    #expect(LogAppDiscovery.parseForegroundPackage("nothing here") == nil)
    #expect(LogAppDiscovery.parseRootLabel(#"{"label":"Réglages","role":"AXApplication"}"#) == "Réglages")
}

private let listApps = """
{
    "com.apple.Preferences" =     {
        ApplicationType = System;
        CFBundleDisplayName = "Réglages";
        CFBundleExecutable = Preferences;
    };
    "com.example.app" =     {
        ApplicationType = User;
        CFBundleDisplayName = "My App";
        CFBundleExecutable = MyApp;
    };
}
"""

@Test func simulatorExecutablesCarryTheNameLogsUse() {
    let apps = SimctlParser.parseAppExecutables(listApps)
    #expect(apps.map(\.executable) == ["MyApp", "Preferences"])
    #expect(apps.first { $0.executable == "MyApp" }?.isSystem == false)
}

@Test func yourAppsAreThirdPartyPackagesOrUserExecutables() async throws {
    let runner = MockShellRunner()
    runner.responses["/sdk/platform-tools/adb -s emulator-5554 shell pm list packages -3"] = .success("package:com.b\npackage:com.a\n")
    runner.responses["/usr/bin/xcrun simctl listapps U"] = .success(listApps)
    let discovery = LogAppDiscovery(runner: runner, sdk: AndroidSDK(root: "/sdk"), baguette: nil)
    let android = Device(id: "P", name: "P", platform: .android, osVersion: "API", state: .running, serial: "emulator-5554")
    #expect(try await discovery.yourApps(on: android) == ["com.a", "com.b"])
    let sim = Device(id: "U", name: "U", platform: .ios, osVersion: "iOS", state: .running)
    #expect(try await discovery.yourApps(on: sim) == ["MyApp"])
}

@Test func currentAppOnAndroidUsesDumpsysAndOnSimulatorsTheAccessibilityRoot() async throws {
    let runner = MockShellRunner()
    runner.responses["/sdk/platform-tools/adb -s emulator-5554 shell dumpsys activity activities"] = .success(dumpsys)
    runner.responses["/opt/homebrew/bin/baguette describe-ui --udid U"] = .success(#"{"label":"my app","role":"AXApplication"}"#)
    runner.responses["/usr/bin/xcrun simctl listapps U"] = .success(listApps)
    let discovery = LogAppDiscovery(runner: runner, sdk: AndroidSDK(root: "/sdk"), baguette: "/opt/homebrew/bin/baguette")
    let android = Device(id: "P", name: "P", platform: .android, osVersion: "API", state: .running, serial: "emulator-5554")
    #expect(try await discovery.currentApp(on: android) == "com.example.app")
    let sim = Device(id: "U", name: "U", platform: .ios, osVersion: "iOS", state: .running)
    #expect(try await discovery.currentApp(on: sim) == "MyApp")
}

@Test func currentAppExplainsWhyItCannotAnswer() async {
    let runner = MockShellRunner()
    let sim = Device(id: "U", name: "U", platform: .ios, osVersion: "iOS", state: .running)
    await #expect(throws: MissingToolError(.baguette, for: "Finding the foreground app")) {
        _ = try await LogAppDiscovery(runner: runner, sdk: nil, baguette: nil).currentApp(on: sim)
    }
    runner.responses["/b describe-ui --udid U"] = .success(#"{"label":" "}"#)
    do {
        _ = try await LogAppDiscovery(runner: runner, sdk: nil, baguette: "/b").currentApp(on: sim)
        Issue.record("expected failure")
    } catch {
        #expect(String(describing: error).contains("home screen"))
    }
}

@MainActor
@Test func filterToCurrentAppSetsTheFilterOrReportsWhy() async {
    let runner = MockShellRunner()
    runner.responses["/sdk/platform-tools/adb -s emulator-5554 shell dumpsys activity activities"] = .success(dumpsys)
    let model = LogViewModel(runner: runner, streamer: SilentStreamer()) { AndroidSDK(root: "/sdk") }
    let android = Device(id: "P", name: "P", platform: .android, osVersion: "API", state: .running, serial: "emulator-5554")
    model.start(android)
    await model.filterToCurrentApp()
    #expect(model.filter.apps == ["com.example.app"])
    #expect(model.discoveryMessage == nil)

    model.start(Device(id: "P2", name: "P2", platform: .android, osVersion: "API", state: .running, serial: "emulator-9999"))
    await model.filterToCurrentApp()
    #expect(model.discoveryMessage == "No app is in the foreground")
}
