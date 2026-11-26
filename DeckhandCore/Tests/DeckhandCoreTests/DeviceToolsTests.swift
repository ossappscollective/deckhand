import Foundation
import Testing
@testable import DeckhandCore

private let fixedNamer = CaptureNamer(now: { Date(timeIntervalSince1970: 0) }, prepareDirectory: { _ in })
private let timestamp: String = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date(timeIntervalSince1970: 0))
}()

private let sim = Device(id: "UDID-1", name: "iPhone 16 Pro", platform: .ios, osVersion: "iOS 18", state: .running)
private let avd = Device(id: "Pixel_8", name: "Pixel_8", platform: .android, osVersion: "API 35",
                         state: .running, serial: "emulator-5554")
private let adb = "/sdk/platform-tools/adb -s emulator-5554"

private func simulatorTools(_ runner: MockShellRunner) -> SimulatorTools {
    SimulatorTools(runner: runner, namer: fixedNamer, temporaryDirectory: "/tmp")
}

private func emulatorTools(_ runner: MockShellRunner) -> EmulatorTools {
    EmulatorTools(runner: runner, sdk: AndroidSDK(root: "/sdk"), avdHome: "/avd", namer: fixedNamer, temporaryDirectory: "/tmp")
}

@Test func simulatorScreenshotNamesFileAfterDevice() async throws {
    let runner = MockShellRunner()
    let path = try await simulatorTools(runner).screenshot(sim, directory: "/out")
    #expect(path == "/out/iPhone_16_Pro-\(timestamp).png")
    #expect(runner.commands == ["/usr/bin/xcrun simctl io UDID-1 screenshot --type=png \(path)"])
}

@Test func simulatorRecordingStartsDetachedAndStopsWithSigint() async throws {
    let runner = MockShellRunner()
    let tools = simulatorTools(runner)
    let path = try await tools.startRecording(sim, directory: "/out")
    try await tools.stopRecording(sim)
    #expect(runner.commands == [
        "detached /usr/bin/xcrun simctl io UDID-1 recordVideo --codec=h264 --force \(path)",
        "/usr/bin/pkill -INT -f simctl io UDID-1 recordVideo"])
}

@Test func simulatorSimpleCommands() async throws {
    let runner = MockShellRunner()
    let tools = simulatorTools(runner)
    try await tools.setAppearance(sim, dark: true)
    try await tools.openURL(sim, "https://example.com/?a=1&b=2")
    try await tools.setLocation(sim, latitude: 48.85, longitude: 2.35)
    try await tools.clearLocation(sim)
    try await tools.setCleanStatusBar(sim, clean: false)
    try await tools.launch(sim, app: "com.apple.Maps")
    try await tools.terminate(sim, app: "com.apple.Maps")
    try await tools.uninstall(sim, app: "com.example")
    #expect(runner.commands == [
        "/usr/bin/xcrun simctl ui UDID-1 appearance dark",
        "/usr/bin/xcrun simctl openurl UDID-1 https://example.com/?a=1&b=2",
        "/usr/bin/xcrun simctl location UDID-1 set 48.85,2.35",
        "/usr/bin/xcrun simctl location UDID-1 clear",
        "/usr/bin/xcrun simctl status_bar UDID-1 clear",
        "/usr/bin/xcrun simctl launch UDID-1 com.apple.Maps",
        "/usr/bin/xcrun simctl terminate UDID-1 com.apple.Maps",
        "/usr/bin/xcrun simctl uninstall UDID-1 com.example"])
}

private let listAppsOutput = """
{
    "com.apple.Maps" =     {
        ApplicationType = System;
        CFBundleDisplayName = Maps;
        CFBundleIdentifier = "com.apple.Maps";
    };
    "com.example.app" =     {
        ApplicationType = User;
        CFBundleName = Example;
        CFBundleIdentifier = "com.example.app";
    };
}
"""

@Test func parsesSimulatorApps() {
    let apps = SimctlParser.parseApps(listAppsOutput)
    #expect(apps.map(\.id) == ["com.example.app", "com.apple.Maps"])
    #expect(apps.map(\.name) == ["Example", "Maps"])
    #expect(apps.map(\.isSystem) == [false, true])
}

@Test func simulatorListAppsHidesSystemUnlessAsked() async throws {
    let runner = MockShellRunner()
    runner.responses["/usr/bin/xcrun simctl listapps UDID-1"] = .success(listAppsOutput)
    let tools = simulatorTools(runner)
    #expect(try await tools.listApps(sim, includeSystem: false).map(\.id) == ["com.example.app"])
    #expect(try await tools.listApps(sim, includeSystem: true).count == 2)
}

@Test func emulatorScreenshotPullsThenCleansUp() async throws {
    let runner = MockShellRunner()
    let path = try await emulatorTools(runner).screenshot(avd, directory: "/out")
    #expect(path == "/out/Pixel_8-\(timestamp).png")
    #expect(Array(runner.commands.prefix(2)) == [
        "\(adb) shell screencap -p /sdcard/deckhand-screenshot.png",
        "\(adb) pull /sdcard/deckhand-screenshot.png \(path)"])
}

@Test func emulatorRecordingUsesConsole() async throws {
    let runner = MockShellRunner()
    let tools = emulatorTools(runner)
    let path = try await tools.startRecording(avd, directory: "/out")
    try await tools.stopRecording(avd)
    #expect(path.hasSuffix(".webm"))
    #expect(runner.commands == ["\(adb) emu screenrecord start --time-limit 600 \(path)",
                                "\(adb) emu screenrecord stop"])
}

@Test func emulatorQuotesRemoteShellArguments() async throws {
    let runner = MockShellRunner()
    let tools = emulatorTools(runner)
    try await tools.openURL(avd, "https://example.com/?a=1&b=2")
    try await tools.launch(avd, app: "com.example")
    try await tools.clearData(avd, app: "com.example")
    #expect(runner.commands == [
        "\(adb) shell am start -a android.intent.action.VIEW -d 'https://example.com/?a=1&b=2'",
        "\(adb) shell monkey -p 'com.example' -c android.intent.category.LAUNCHER 1",
        "\(adb) shell pm clear 'com.example'"])
}

@Test func emulatorSimpleCommands() async throws {
    let runner = MockShellRunner()
    let tools = emulatorTools(runner)
    try await tools.setAppearance(avd, dark: false)
    try await tools.setLocation(avd, latitude: 48.85, longitude: 2.35)
    try await tools.setShowTaps(avd, enabled: true)
    try await tools.reboot(avd)
    try await tools.uninstall(avd, app: "com.example")
    #expect(runner.commands == [
        "\(adb) shell cmd uimode night no",
        "\(adb) emu geo fix 2.35 48.85",
        "\(adb) shell settings put system show_touches 1",
        "\(adb) reboot",
        "\(adb) uninstall com.example"])
}

@Test func emulatorAnimationsTouchAllThreeScales() async throws {
    let runner = MockShellRunner()
    try await emulatorTools(runner).setAnimations(avd, enabled: false)
    #expect(runner.commands == [
        "\(adb) shell settings put global window_animation_scale 0",
        "\(adb) shell settings put global transition_animation_scale 0",
        "\(adb) shell settings put global animator_duration_scale 0"])
}

@Test func emulatorListAppsMarksSystemPackages() async throws {
    let runner = MockShellRunner()
    runner.responses["\(adb) shell pm list packages -3"] = .success("package:com.example\r\n")
    runner.responses["\(adb) shell pm list packages"] = .success("package:com.android.settings\npackage:com.example\n")
    let tools = emulatorTools(runner)
    #expect(try await tools.listApps(avd, includeSystem: false).map(\.id) == ["com.example"])
    let all = try await tools.listApps(avd, includeSystem: true)
    #expect(all.map(\.isSystem) == [true, false])
}

@Test func emulatorToolRequiresRunningDevice() async {
    let stopped = Device(id: "Pixel_8", name: "Pixel_8", platform: .android, osVersion: "API 35", state: .stopped)
    await #expect(throws: ShellError.self) {
        try await emulatorTools(MockShellRunner()).rotate(stopped)
    }
}

@Test func installPassesApkStraightThrough() async throws {
    let runner = MockShellRunner()
    try await emulatorTools(runner).install(avd, source: "/tmp/app.apk")
    #expect(runner.commands == ["\(adb) install -r -t /tmp/app.apk"])
}

@Test func installDownloadsUrlThenRejectsUnknownArchive() async throws {
    let runner = MockShellRunner()
    let directory = NSTemporaryDirectory() + "DeckhandTests-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let resolver = AppPackageResolver(runner: runner, fileExtension: "apk", temporaryDirectory: directory)
    await #expect(throws: ShellError.self) {
        _ = try await resolver.resolve("https://example.com/build")
    }
    #expect(runner.commands.first?.hasPrefix("/usr/bin/curl -fL --silent --show-error -o ") == true)
    #expect(runner.commands.first?.hasSuffix(" https://example.com/build") == true)
}

@Test func resolverUnpacksTarballAndFindsApp() async throws {
    let directory = NSTemporaryDirectory() + "DeckhandTests-\(UUID().uuidString)"
    let payload = "\(directory)/payload/Example.app"
    try FileManager.default.createDirectory(atPath: payload, withIntermediateDirectories: true)
    try "x".write(toFile: payload + "/Info.plist", atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let archive = "\(directory)/build.tar.gz"
    try await ProcessShellRunner().run("/usr/bin/tar", ["-czf", archive, "-C", "\(directory)/payload", "Example.app"])

    let resolver = AppPackageResolver(runner: ProcessShellRunner(), fileExtension: "app", temporaryDirectory: directory)
    let resolved = try await resolver.resolve(archive)
    #expect(resolved.hasSuffix("/unpacked/Example.app"))
    #expect(FileManager.default.fileExists(atPath: resolved + "/Info.plist"))
}

@Test func toolSupportMatchesPlatform() {
    #expect(DeviceTool.rotate.isSupported(on: .android))
    #expect(DeviceTool.rotate.isSupported(on: .ios))
    #expect(DeviceTool.statusBar(clean: true).isSupported(on: .ios))
    #expect(!DeviceTool.statusBar(clean: true).isSupported(on: .android))
    #expect(DeviceTool.screenshot.isSupported(on: .ios) && DeviceTool.screenshot.isSupported(on: .android))
}

@MainActor
private func makeToolsModel(_ runner: MockShellRunner) -> DeviceToolsViewModel {
    DeviceToolsViewModel(runner: runner, finalizeDelay: .milliseconds(1), captureDirectory: { "/nonexistent-deckhand" }) {
        AndroidSDK(root: "/sdk")
    }
}

@MainActor
@Test func toolsModelFetchesNothingUntilAsked() async {
    let runner = MockShellRunner()
    let vm = makeToolsModel(runner)
    #expect(runner.commands.isEmpty)
    #expect(vm.appsState == .idle)
    runner.responses["\(adb) shell pm list packages -3"] = .success("package:com.example\n")
    await vm.loadApps(for: avd)
    #expect(vm.appsState == .loaded)
    #expect(vm.apps.map(\.id) == ["com.example"])
    #expect(runner.commands == ["\(adb) shell pm list packages -3"])
}

@MainActor
@Test func toolsModelReportsAppListFailure() async {
    let runner = MockShellRunner()
    runner.responses["/usr/bin/xcrun simctl listapps UDID-1"] =
        .failure(ShellError(command: "simctl", exitCode: 1, stderr: "Invalid device"))
    let vm = makeToolsModel(runner)
    await vm.loadApps(for: sim)
    #expect(vm.appsError == "Invalid device")
    #expect(vm.apps.isEmpty)
}

@MainActor
@Test func toolsModelRejectsUnsupportedTool() async {
    let runner = MockShellRunner()
    let vm = makeToolsModel(runner)
    await vm.perform(.animations(enabled: false), on: sim)
    #expect(vm.message?.isError == true)
    #expect(runner.commands.isEmpty)
}

@MainActor
@Test func toolsModelTracksRecordingLifecycle() async {
    let runner = MockShellRunner()
    let vm = makeToolsModel(runner)
    await vm.perform(.startRecording, on: avd)
    #expect(vm.isRecording(avd))
    await vm.perform(.stopRecording, on: avd)
    #expect(!vm.isRecording(avd))
    #expect(vm.message?.text.hasPrefix("Saved ") == true)
}

@MainActor
@Test func toolsModelRefusesStopWithoutRecording() async {
    let runner = MockShellRunner()
    let vm = makeToolsModel(runner)
    await vm.perform(.stopRecording, on: avd)
    #expect(vm.message?.isError == true)
    #expect(runner.commands.isEmpty)
}

@MainActor
@Test func toolsModelUninstallReloadsApps() async {
    let runner = MockShellRunner()
    runner.responses["\(adb) shell pm list packages -3"] = .success("")
    let vm = makeToolsModel(runner)
    await vm.perform(.uninstall(app: "com.example"), on: avd)
    #expect(runner.commands == ["\(adb) uninstall com.example", "\(adb) shell pm list packages -3"])
}

@MainActor
@Test func toolsModelSurfacesShellErrors() async {
    let runner = MockShellRunner()
    runner.responses["/usr/bin/xcrun simctl ui UDID-1 appearance dark"] =
        .failure(ShellError(command: "simctl", exitCode: 1, stderr: "Unable to set appearance"))
    let vm = makeToolsModel(runner)
    await vm.perform(.appearance(dark: true), on: sim)
    #expect(vm.message == DeviceToolsViewModel.Message(text: "Unable to set appearance", isError: true))
    #expect(!vm.isWorking)
}

private func bundleTools(_ runner: MockShellRunner, bundletool: String? = "/bt/bundletool") -> EmulatorTools {
    EmulatorTools(runner: runner, sdk: AndroidSDK(root: "/sdk"), avdHome: "/avd", namer: fixedNamer,
                  temporaryDirectory: "/tmp", locateBundletool: { bundletool })
}

@Test func installBuildsAndInstallsAnAab() async throws {
    let runner = MockShellRunner()
    try await bundleTools(runner).install(avd, source: "/tmp/app.aab")
    #expect(runner.commands.count == 2)
    let build = runner.commands[0]
    #expect(build.hasPrefix("/bt/bundletool build-apks --bundle=/tmp/app.aab --output=/tmp/deckhand-"))
    #expect(build.hasSuffix(".apks --connected-device --device-id=emulator-5554 --adb=/sdk/platform-tools/adb --overwrite"))
    #expect(runner.commands[1].hasPrefix("/bt/bundletool install-apks --apks=/tmp/deckhand-"))
    #expect(runner.commands[1].hasSuffix(".apks --device-id=emulator-5554 --adb=/sdk/platform-tools/adb"))
}

@Test func installTakesAnExistingApksSet() async throws {
    let runner = MockShellRunner()
    try await bundleTools(runner).install(avd, source: "/tmp/app.apks")
    #expect(runner.commands == ["/bt/bundletool install-apks --apks=/tmp/app.apks --device-id=emulator-5554 --adb=/sdk/platform-tools/adb"])
}

@Test func aabWithoutBundletoolExplainsHowToInstallIt() async {
    let runner = MockShellRunner()
    do {
        try await bundleTools(runner, bundletool: nil).install(avd, source: "/tmp/app.aab")
        Issue.record("expected failure")
    } catch let error as MissingToolError {
        #expect(error.tool == .bundletool)
        #expect(error.errorDescription?.contains("brew install bundletool") == true)
    } catch {
        Issue.record("wrong error \(error)")
    }
    #expect(runner.commands.isEmpty)
}

@Test func simulatorRelaunchTerminatesTheRunningApp() async throws {
    let runner = MockShellRunner()
    try await simulatorTools(runner).relaunch(sim, app: "com.example")
    #expect(runner.commands == ["/usr/bin/xcrun simctl launch --terminate-running-process UDID-1 com.example"])
    #expect(DeviceTool.relaunch(app: "x").isSupported(for: sim))
    #expect(!DeviceTool.relaunch(app: "x").isSupported(for: avd))
}

@Test func simulatorTogglesAppearanceToTheOtherMode() async throws {
    let runner = MockShellRunner()
    runner.responses["/usr/bin/xcrun simctl ui UDID-1 appearance"] = .success("light\n")
    let dark = try await simulatorTools(runner).toggleAppearance(sim)
    #expect(dark)
    #expect(runner.commands.last == "/usr/bin/xcrun simctl ui UDID-1 appearance dark")
    runner.responses["/usr/bin/xcrun simctl ui UDID-1 appearance"] = .success("dark\n")
    #expect(try await simulatorTools(runner).toggleAppearance(sim) == false)
    #expect(runner.commands.last == "/usr/bin/xcrun simctl ui UDID-1 appearance light")
}

@Test func emulatorTogglesAppearanceAndStepsTextSize() async throws {
    let runner = MockShellRunner()
    runner.responses["\(adb) shell cmd uimode night"] = .success("Night mode: no\n")
    #expect(try await emulatorTools(runner).toggleAppearance(avd))
    #expect(runner.commands.last == "\(adb) shell cmd uimode night yes")

    runner.responses["\(adb) shell settings get system font_scale"] = .success("1.0\n")
    try await emulatorTools(runner).changeTextSize(avd, larger: true)
    #expect(runner.commands.last == "\(adb) shell settings put system font_scale 1.15")
    runner.responses["\(adb) shell settings get system font_scale"] = .success("null\n")
    try await emulatorTools(runner).changeTextSize(avd, larger: false)
    #expect(runner.commands.last == "\(adb) shell settings put system font_scale 0.85")
    runner.responses["\(adb) shell settings get system font_scale"] = .success("1.3\n")
    try await emulatorTools(runner).changeTextSize(avd, larger: true)
    #expect(runner.commands.last == "\(adb) shell settings put system font_scale 1.3")
}

@Test func simulatorStepsTextSize() async throws {
    let runner = MockShellRunner()
    try await simulatorTools(runner).changeTextSize(sim, larger: false)
    #expect(runner.commands.last == "/usr/bin/xcrun simctl ui UDID-1 content_size decrement")
}

@Test func emulatorNetworkIsSlowedThroughTheConsoleAndCutWithAirplaneMode() async throws {
    let runner = MockShellRunner()
    try await emulatorTools(runner).setNetwork(avd, NetworkConditions(name: "3G", latencyMs: 100, downKbps: 780, upKbps: 330))
    #expect(runner.commands == ["\(adb) emu network speed 330:780", "\(adb) emu network delay 100",
                                "\(adb) shell cmd connectivity airplane-mode disable"])
    try await emulatorTools(runner).setNetwork(avd, .online)
    #expect(runner.commands.suffix(3) == ["\(adb) emu network speed full", "\(adb) emu network delay none",
                                          "\(adb) shell cmd connectivity airplane-mode disable"])
    try await emulatorTools(runner).setNetwork(avd, .offlineProfile)
    #expect(runner.commands.last == "\(adb) shell cmd connectivity airplane-mode enable")
}

@Test func androidRotatesAQuarterTurnThroughTheWindowManager() async throws {
    let window = "\(adb) shell dumpsys display | grep -m1 -o 'mCurrentOrientation=[0-9]'"
    let runner = MockShellRunner()
    runner.responses[window] = .success("mCurrentOrientation=0\n")
    try await emulatorTools(runner).rotate(avd)
    #expect(runner.commands.last == "\(adb) shell cmd window user-rotation lock 3")   // clockwise
    try await emulatorTools(runner).rotate(avd, clockwise: false)
    #expect(runner.commands.last == "\(adb) shell cmd window user-rotation lock 1")

    runner.responses[window] = .success("mCurrentOrientation=1\n")   // back to portrait stays locked
    try await emulatorTools(runner).rotate(avd)
    #expect(runner.commands.last == "\(adb) shell cmd window user-rotation lock 0")
}

@Test func androidRotationFallsBackToSettingsOnOldVersions() async throws {
    let runner = MockShellRunner()
    runner.responses["\(adb) shell dumpsys display | grep -m1 -o 'mCurrentOrientation=[0-9]'"] = .success("mCurrentOrientation=0\n")
    runner.responses["\(adb) shell cmd window user-rotation lock 3"] = .failure(ShellError(command: "cmd", exitCode: 255, stderr: "Can't find service: window"))
    try await emulatorTools(runner).rotate(avd)
    #expect(runner.commands.suffix(2) == ["\(adb) shell settings put system accelerometer_rotation 0",
                                          "\(adb) shell settings put system user_rotation 3"])
}

@Test func androidRotationFromLandscapeGoesBackToPortraitNotUpsideDown() async throws {
    let orientation = "\(adb) shell dumpsys display | grep -m1 -o 'mCurrentOrientation=[0-9]'"
    let runner = MockShellRunner()
    runner.responses[orientation] = .success("mCurrentOrientation=3\n")
    try await emulatorTools(runner).rotate(avd)                       // clockwise from 3 would be upside down
    #expect(runner.commands.last == "\(adb) shell cmd window user-rotation lock 0")
    runner.responses[orientation] = .success("mCurrentOrientation=1\n")
    try await emulatorTools(runner).rotate(avd, clockwise: false)     // counterclockwise from 1 would be too
    #expect(runner.commands.last == "\(adb) shell cmd window user-rotation lock 0")
    try await emulatorTools(runner).rotate(avd)                       // clockwise from 1 is portrait
    #expect(runner.commands.last == "\(adb) shell cmd window user-rotation lock 0")
    runner.responses[orientation] = .success("mCurrentOrientation=0\n")
    try await emulatorTools(runner).rotate(avd, clockwise: false)
    #expect(runner.commands.last == "\(adb) shell cmd window user-rotation lock 1")
}

@Test func simulatorRotatesThroughBaguetteAndNeverUpsideDown() async throws {
    let runner = MockShellRunner()
    let tools = SimulatorTools(runner: runner, namer: fixedNamer, temporaryDirectory: "/tmp", locateBaguette: { "/bin/baguette" })
    try await tools.setOrientation(sim, .landscapeRight)
    #expect(runner.commands == ["/bin/baguette orientation --udid UDID-1 landscape-right"])
    #expect(SimulatorOrientation.portrait.turned(clockwise: true) == .landscapeRight)
    #expect(SimulatorOrientation.portrait.turned(clockwise: false) == .landscapeLeft)
    #expect(SimulatorOrientation.landscapeRight.turned(clockwise: true) == .portrait)
    #expect(SimulatorOrientation.landscapeLeft.turned(clockwise: false) == .portrait)
}

@Test func simulatorRotationNeedsBaguette() async throws {
    let tools = SimulatorTools(runner: MockShellRunner(), namer: fixedNamer, temporaryDirectory: "/tmp", locateBaguette: { nil })
    await #expect(throws: MissingToolError(.baguette, for: "Rotating a simulator")) { try await tools.setOrientation(sim, .landscapeLeft) }
}

@MainActor
@Test func aMissingToolReachesTheMessageWithItsProject() {
    let message = DeviceToolsViewModel.failure(MissingToolError(.baguette, for: "Rotating a simulator"))
    #expect(message.isError)
    #expect(message.missingTool == .baguette)
    #expect(message.text.contains("brew install baguette"))
    #expect(OptionalTool.baguette.homepage.absoluteString == "https://github.com/tddworks/baguette")
    #expect(DeviceToolsViewModel.failure(ShellError(command: "x", exitCode: 1, stderr: "boom")).missingTool == nil)
}

@MainActor
@Test func aCornerScreenshotIsHandedOverInsteadOfRevealed() async {
    let runner = MockShellRunner()
    let tools = makeToolsModel(runner)
    var captured: [String] = []
    tools.onScreenshotCaptured = { captured.append($0) }

    await tools.screenshotToCorner(sim)
    #expect(captured.count == 1)
    #expect(captured.first?.hasSuffix(".png") == true)
    // a thumbnail's file goes to the temporary folder, not to the capture folder
    #expect(captured.first?.contains("Deckhand Screenshots") == true)
    #expect(!runner.commands.contains { $0.hasPrefix("/usr/bin/open -R") })

    // the next plain screenshot is revealed as before
    await tools.perform(.screenshot, on: sim)
    #expect(captured.count == 1)
    #expect(runner.commands.contains { $0.hasPrefix("/usr/bin/open -R") })
}

@Test func theScreenshotCacheRemovesOnlyOldFiles() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("cache-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = URL(fileURLWithPath: ScreenshotCache.directory(in: base))
    let old = folder.appendingPathComponent("old.png")
    let fresh = folder.appendingPathComponent("fresh.png")
    try Data("x".utf8).write(to: old)
    try Data("x".utf8).write(to: fresh)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ScreenshotCache.keepsFor - 60)],
                                          ofItemAtPath: old.path)
    _ = ScreenshotCache.directory(in: base)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
}


@Test func longActionsNameWhatTheyDo() {
    #expect(DeviceTool.install("/tmp/Build/app.apk").activityTitle == "Installing app.apk")
    #expect(DeviceTool.install("https://example.com/builds/app.tar.gz").activityTitle == "Installing app.tar.gz")
    #expect(DeviceTool.pushFile("/tmp/report.pdf").activityTitle == "Copying report.pdf")
    #expect(DeviceTool.addMedia("/tmp/photo.png").activityTitle == "Adding photo.png")
    #expect(DeviceTool.screenshot.activityTitle == nil)
}
