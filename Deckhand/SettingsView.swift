import SwiftUI
import DeckhandCore

struct SettingsView: View {
    @AppStorage(Preferences.sdkPathKey) private var androidSdkPath = ""
    @AppStorage(Preferences.muteAudioKey) private var muteAudio = false
    @AppStorage(Preferences.extraArgumentsKey) private var extraArguments = ""
    @AppStorage(Preferences.captureDirectoryKey) private var captureDirectory = ""
    @AppStorage(Preferences.terminalAppKey) private var terminalId = "terminal"
    @AppStorage(Preferences.terminalCustomAppKey) private var terminalCustomName = ""
    @AppStorage(Preferences.menuBarIndicatorKey) private var menuBarIndicator = MenuBarIndicator.iconAndCount
    @AppStorage(Preferences.showPhysicalDevicesKey) private var showPhysicalDevices = true
    @AppStorage(Preferences.syncClipboardKey) private var syncClipboard = true
    @AppStorage(Preferences.logBufferKey) private var logBuffer = 50_000
    @AppStorage(Preferences.networkPortKey) private var networkPort = 0
    @State private var launchModel = LaunchAtLoginModel()
    @State private var linkHandler = LinkHandlerModel()

    var body: some View {
        TabView {
            tab("General", "gearshape") {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchModel.isEnabled },
                    set: { launchModel.set($0) }
                ))
                if let message = launchModel.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Menu bar") {
                Picker("Show running simulators and emulators", selection: $menuBarIndicator) {
                    ForEach(MenuBarIndicator.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("The icon gets radio waves while one is running. Right-click the icon for a menu with the window, Settings, About and Quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Physical devices") {
                Toggle("Show connected iPhones, iPads and Android phones", isOn: $showPhysicalDevices)
                Text("Uses adb and devicectl. Turn off to only list simulators and emulators.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Terminal") {
                Picker("Open Shell and Logs in", selection: $terminalId) {
                    ForEach(TerminalApp.presets, id: \.id) { app in
                        Text(app.isInstalled ? app.title : "\(app.title) (not installed)").tag(app.id)
                    }
                    Text("Other…").tag("custom")
                }
                if terminalId == "custom" {
                    TextField("Application name", text: $terminalCustomName, prompt: Text("Hyper"))
                }
                Text(terminalId == "custom"
                     ? "Any terminal that opens a .command file when given to `open -a`."
                     : "Used by the Shell and Logs actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Screenshots & recordings") {
                HStack {
                    TextField("Save to", text: $captureDirectory, prompt: Text("~/Desktop"))
                    Button("Choose…") {
                        FilePicker.chooseDirectory { captureDirectory = $0 }
                    }
                }
            }
            }
            tab("Android", "smartphone") {
            Section("Android") {
                TextField("SDK Path", text: $androidSdkPath,
                          prompt: Text("/Users/you/Library/Android/sdk"))
                Text("Leave empty to auto-detect from $ANDROID_HOME, $ANDROID_SDK_ROOT, or ~/Library/Android/sdk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Emulator launch") {
                Toggle("Start without sound", isOn: $muteAudio)
                Text("Adds -no-audio. Each device's menu then offers Start with Sound for a single launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Extra arguments", text: $extraArguments, prompt: Text("-gpu host -no-boot-anim"))
                Text("Passed to every emulator start, cold boot and wipe. Quote values containing spaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            }
            tab("Logs", "text.alignleft") {
                Section("Log panel") {
                    Picker("Lines kept per device", selection: $logBuffer) {
                        ForEach([5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000], id: \.self) {
                            Text($0.formatted()).tag($0)
                        }
                    }
                    Text("The oldest lines are dropped once the log is full. A larger buffer keeps more history and uses more memory (roughly 200 bytes a line); a simulator can produce well over a thousand lines a second.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            tab("Network", "network") {
                Section("Proxy") {
                    TextField("Port", value: $networkPort, format: .number.grouping(.never), prompt: Text("Automatic"))
                        .frame(maxWidth: 220)
                    Text("Leave empty or 0 for automatic: port 8899, or a free port when that one is taken. A port you choose is used as is and capturing fails if it is busy. It applies the next time capturing starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            tab("Mirror", "rectangle.on.rectangle") {
            Section("Mirror") {
                Toggle("Sync the clipboard with the mirrored device", isOn: $syncClipboard)
                Text("While a mirror is open, what you copy on the Mac is available to paste on the device and the other way round. Turn off if you copy secrets you do not want on a test device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Install links") {
                Toggle("Open expo-orbit:// links in Deckhand", isOn: Binding(
                    get: { linkHandler.isDefault },
                    set: { linkHandler.setDefault($0) }))
                Text("EAS and Expo \"Open in Orbit\" links download the build and ask which device to install it on. Turn off to give the links back to Expo Orbit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = linkHandler.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            }
        }
        .frame(width: 500, height: 430)
        .onAppear {
            launchModel.refresh()
            linkHandler.refresh()
        }
    }

    /// Each tab is its own scrolling form, so the window stays a fixed size however many options a tab has.
    private func tab<Content: View>(_ title: String, _ symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .tabItem { Label(title, systemImage: symbol) }
    }
}
