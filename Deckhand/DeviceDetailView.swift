import SwiftUI
import DeckhandCore

/// Full-panel page of the menu bar popover.
struct DeviceDetailView: View {
    let deviceId: String
    let onBack: () -> Void
    var onOpenHub: ((Device) -> Void)?

    @Environment(DeviceListViewModel.self) private var listModel

    var body: some View {
        VStack(spacing: 0) {
            if let device = listModel.device(id: deviceId) {
                HStack(spacing: 0) {
                    PanelHeader(title: device.name, subtitle: "\(device.osVersion) · \(stateLabel(device))", onBack: onBack)
                    if let onOpenHub {
                        Button { onOpenHub(device) } label: {
                            Image(systemName: "macwindow").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open in the Deckhand window")
                        .padding(.trailing, 14)
                    }
                }
                Divider()
                DeviceManageContent(device: device, onGone: onBack)
            } else {
                PanelHeader(title: "Device", onBack: onBack)
                Divider()
                Hint("This device no longer exists.").padding()
                Spacer()
            }
        }
    }

    private func stateLabel(_ device: Device) -> String {
        switch device.state {
        case .running: device.isPhysical ? "Connected" : "Running"
        case .booting: "Booting…"
        case .stopped: "Stopped"
        case .unavailable: device.statusNote ?? "Unavailable"
        }
    }
}

/// The management sections for one device, shared by the popover page and the window inspector.
struct DeviceManageContent: View {
    let device: Device
    let onGone: () -> Void

    @Environment(DeviceToolsViewModel.self) private var tools
    @State private var expanded: Set<Section> = []

    enum Section: Hashable {
        case apps, install, url, location, display, network, capture, camera, tools, device
    }

    private var usable: Bool { device.state == .running }

    private func offers(_ candidates: DeviceTool...) -> Bool {
        candidates.contains { $0.isSupported(for: device) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    if device.state == .unavailable {
                        Hint(device.statusNote ?? "This device is not available.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    } else if !usable {
                        Hint("Start the device to use these tools.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                    runningSections
                    if !device.isPhysical {
                        CardSection(title: "Device", systemImage: "iphone", isExpanded: binding(.device)) {
                            ManageDeviceView(device: device, onGone: onGone)
                        }
                    }
                }
                .padding(10)
            }
            if let message = tools.message { messageBar(message) }
        }
        .onAppear { tools.reset() }
        .onChange(of: device.id) { _, _ in
            tools.reset()
            expanded = []
        }
    }

    @ViewBuilder
    private var runningSections: some View {
        Group {
            if offers(.launch(app: "")) {
                CardSection(title: "Apps", systemImage: "square.grid.2x2", isExpanded: binding(.apps)) {
                    AppsListView(device: device)
                }
            }
            if offers(.install("")) {
                CardSection(title: "Install App", systemImage: "square.and.arrow.down", isExpanded: binding(.install)) {
                    InstallAppView(device: device)
                }
            }
            if offers(.openURL("")) {
                CardSection(title: "Open URL", systemImage: "link", isExpanded: binding(.url)) {
                    OpenURLView(device: device)
                }
            }
            if offers(.location(latitude: 0, longitude: 0)) {
                CardSection(title: "Location", systemImage: "location", isExpanded: binding(.location)) {
                    LocationView(device: device)
                }
            }
            if offers(.appearance(dark: true)) {
                CardSection(title: "Display & Developer", systemImage: "paintbrush", isExpanded: binding(.display)) {
                    DisplayToolsView(device: device)
                }
            }
            CardSection(title: "Network", systemImage: "gauge.with.dots.needle.33percent", isExpanded: binding(.network)) {
                NetworkToolsView(device: device)
            }
            if offers(.screenshot) {
                CardSection(title: "Capture", systemImage: "camera", isExpanded: binding(.capture)) {
                    CaptureToolsView(device: device)
                }
            }
            if device.platform == .ios && !device.isPhysical {
                CardSection(title: "Camera", systemImage: "video", isExpanded: binding(.camera)) {
                    CameraToolsView(device: device)
                }
            }
            if offers(.logs, .shell, .revealStorage, .scrcpy, .reboot) {
                CardSection(title: "Tools", systemImage: "terminal", isExpanded: binding(.tools)) {
                    SystemToolsView(device: device)
                }
            }
        }
        .disabled(!usable || tools.isWorking)
        .opacity(usable ? 1 : 0.5)
    }

    private func messageBar(_ message: DeviceToolsViewModel.Message) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(message.isError ? Color.red : Color.green)
            Text(message.text).font(.system(size: 11)).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let tool = message.missingTool { InstallToolButton(tool: tool, title: "How to install") }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary)
    }

    private func binding(_ section: Section) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(section) },
            set: { if $0 { expanded.insert(section) } else { expanded.remove(section) } })
    }
}

/// Fetches the app list only once the Apps section is opened.
private struct AppsListView: View {
    let device: Device
    @Environment(DeviceToolsViewModel.self) private var tools
    @State private var includeSystem = false
    @State private var filter = ""
    @State private var didRequest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).controlSize(.small)
                Toggle("System", isOn: $includeSystem)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .onChange(of: includeSystem) { _, value in
                        Task { await tools.loadApps(for: device, includeSystem: value) }
                    }
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            content
        }
        .task {
            guard !didRequest, tools.appsState == .idle else { return }
            didRequest = true
            await tools.loadApps(for: device, includeSystem: includeSystem)
        }
    }

    @ViewBuilder
    private var content: some View {
        if tools.appsState == .loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else if let error = tools.appsError {
            Text(error).font(.system(size: 11)).foregroundStyle(.red)
        } else if filtered.isEmpty {
            Hint("No apps found")
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filtered) { app in
                    AppRow(device: device, app: app)
                    Divider()
                }
            }
        }
    }

    private var filtered: [InstalledApp] {
        guard !filter.isEmpty else { return tools.apps }
        return tools.apps.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.id.localizedCaseInsensitiveContains(filter)
        }
    }

    private func reload() {
        Task { await tools.loadApps(for: device, includeSystem: includeSystem) }
    }
}

private struct AppRow: View {
    let device: Device
    let app: InstalledApp
    @Environment(DeviceToolsViewModel.self) private var tools

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if app.name != app.id {
                    Text(app.id).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button { run(.launch(app: app.id)) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.plain).foregroundStyle(.blue)
            Menu {
                if device.platform == .ios && !device.isPhysical {
                    Button("Relaunch") { run(.relaunch(app: app.id)) }
                }
                Button("Stop") { run(.stopApp(app: app.id)) }
                if device.platform == .android {
                    Button("Clear Data") { run(.clearData(app: app.id)) }
                } else {
                    Button("Show Data Folder") { run(.revealAppData(app: app.id)) }
                }
                Divider()
                Button("Uninstall", role: .destructive) { run(.uninstall(app: app.id)) }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(.vertical, 5)
    }

    private func run(_ tool: DeviceTool) {
        Task { await tools.perform(tool, on: device) }
    }
}

private struct InstallAppView: View {
    let device: Device
    @Environment(DeviceToolsViewModel.self) private var tools
    @State private var source = ""

    private var extensions: [String] {
        guard device.platform == .ios else { return ["apk", "aab", "apks"] }
        return device.isPhysical ? ["ipa", "app", "gz", "zip"] : ["app", "gz", "zip"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Hint(device.platform == .ios
                 ? (device.isPhysical ? "A signed .ipa or .app, or a .tar.gz / .zip containing one."
                                      : "A .app, or a .tar.gz / .zip containing one (EAS and Expo builds work).")
                 : "An .apk, an .apks set, or an .aab (needs bundletool: brew install bundletool).")
            HStack {
                ToolButton(title: "Choose File…", systemImage: "doc") {
                    FilePicker.chooseFile(extensions: extensions) { path in
                        Task { await tools.perform(.install(path), on: device) }
                    }
                }
            }
            HStack {
                TextField("or paste a URL", text: $source)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit(install)
                ToolButton(title: "Install", action: install)
                    .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func install() {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task { await tools.perform(.install(value), on: device) }
    }
}

private struct OpenURLView: View {
    let device: Device
    @Environment(DeviceToolsViewModel.self) private var tools
    @State private var url = ""

    var body: some View {
        HStack {
            TextField("https:// or app://", text: $url)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .onSubmit(open)
            ToolButton(title: "Open", action: open)
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func open() {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task { await tools.perform(.openURL(value), on: device) }
    }
}

private struct LocationView: View {
    let device: Device
    @Environment(DeviceToolsViewModel.self) private var tools
    @State private var latitude = ""
    @State private var longitude = ""

    private var coordinate: (Double, Double)? {
        guard let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")),
              let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return (lat, lon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Latitude", text: $latitude).textFieldStyle(.roundedBorder).controlSize(.small)
                TextField("Longitude", text: $longitude).textFieldStyle(.roundedBorder).controlSize(.small)
            }
            HStack {
                ToolButton(title: "Set Location", systemImage: "location.fill") {
                    guard let (lat, lon) = coordinate else { return }
                    Task { await tools.perform(.location(latitude: lat, longitude: lon), on: device) }
                }
                .disabled(coordinate == nil)
                if device.platform == .ios {
                    ToolButton(title: "Clear") { Task { await tools.perform(.clearLocation, on: device) } }
                }
            }
        }
    }
}

private struct DisplayToolsView: View {
    let device: Device
    @Environment(DeviceToolsViewModel.self) private var tools

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Appearance") {
                ToolButton(title: "Dark", systemImage: "moon.fill") { run(.appearance(dark: true)) }
                ToolButton(title: "Light", systemImage: "sun.max.fill") { run(.appearance(dark: false)) }
            }
            if DeviceTool.statusBar(clean: true).isSupported(for: device) {
                row("Status bar") {
                    ToolButton(title: "Clean 9:41") { run(.statusBar(clean: true)) }
                    ToolButton(title: "Reset") { run(.statusBar(clean: false)) }
                }
            }
            if device.platform == .android {
                if DeviceTool.rotate.isSupported(for: device) {
                    row("Orientation") {
                        ToolButton(title: "Rotate", systemImage: "rotate.right") { run(.rotate) }
                    }
                }
                row("Animations") {
                    ToolButton(title: "Off") { run(.animations(enabled: false)) }
                    ToolButton(title: "On") { run(.animations(enabled: true)) }
                }
                row("Show taps") {
                    ToolButton(title: "On") { run(.showTaps(enabled: true)) }
                    ToolButton(title: "Off") { run(.showTaps(enabled: false)) }
                }
            }
        }
    }

    private func row(_ title: String, @ViewBuilder buttons: () -> some View) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            buttons()
            Spacer(minLength: 0)
        }
    }

    private func run(_ tool: DeviceTool) {
        Task { await tools.perform(tool, on: device) }
    }
}

/// Slows the network of the device down: the same presets as the Network panel.
private struct NetworkToolsView: View {
    let device: Device
    @Environment(NetworkViewModel.self) private var network
    @State private var latency = ""
    @State private var down = ""
    @State private var up = ""

    private var current: NetworkConditions { network.conditions(for: device) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Network").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                Picker("", selection: Binding(get: { current.name }, set: choose)) {
                    ForEach(NetworkConditions.presets) { Text($0.name).tag($0.name) }
                    if !NetworkConditions.presets.contains(where: { $0.name == current.name }) { Text(current.name).tag(current.name) }
                }
                .labelsHidden().frame(maxWidth: 190)
                Spacer(minLength: 0)
            }
            Text(current.isLimited ? current.summary : "The network runs at full speed.")
                .font(.system(size: 11)).foregroundStyle(current.isLimited ? Color.orange : Color.secondary)
            HStack(spacing: 6) {
                field("ms", $latency)
                field("kbps down", $down)
                field("kbps up", $up)
                Button("Apply") {
                    let custom = NetworkConditions(name: "Custom", latencyMs: Int(latency) ?? 0, downKbps: Int(down) ?? 0, upKbps: Int(up) ?? 0)
                    Task { await network.setConditions(custom, for: device) }
                }
                .controlSize(.small)
            }
            Text(network.slowsEmulator(device)
                 ? "The emulator slows down all of its traffic. Offline turns airplane mode on."
                 : "Applied to what goes through the proxy, so capturing must be on. Offline fails every connection.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ title: String, _ value: Binding<String>) -> some View {
        TextField(title, text: value).textFieldStyle(.roundedBorder).controlSize(.small).multilineTextAlignment(.trailing)
    }

    private func choose(_ name: String) {
        guard let preset = NetworkConditions.presets.first(where: { $0.name == name }) else { return }
        Task { await network.setConditions(preset, for: device) }
    }
}

private struct CaptureToolsView: View {
    let device: Device
    @Environment(DeviceToolsViewModel.self) private var tools

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ToolButton(title: "Screenshot", systemImage: "camera") { run(.screenshot) }
                if DeviceTool.startRecording.isSupported(for: device) {
                    if tools.isRecording(device) {
                        ToolButton(title: "Stop Recording", systemImage: "stop.circle.fill") { run(.stopRecording) }
                    } else {
                        ToolButton(title: "Record", systemImage: "record.circle") { run(.startRecording) }
                    }
                }
            }
            Hint("Saved to \(Preferences.captureDirectory). Change it in Settings.")
        }
    }

    private func run(_ tool: DeviceTool) {
        Task { await tools.perform(tool, on: device) }
    }
}

private struct SystemToolsView: View {
    let device: Device
    @Environment(DeviceToolsViewModel.self) private var tools

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if DeviceTool.logs.isSupported(for: device) {
                    ToolButton(title: "Logs", systemImage: "text.alignleft") { run(.logs) }
                }
                if device.platform == .android {
                    ToolButton(title: "Shell", systemImage: "apple.terminal") { run(.shell) }
                }
                if DeviceTool.revealStorage.isSupported(for: device) {
                    ToolButton(title: "Show in Finder", systemImage: "folder") { run(.revealStorage) }
                }
            }
            if device.platform == .android {
                HStack {
                    ToolButton(title: "scrcpy", systemImage: "rectangle.on.rectangle") { run(.scrcpy) }
                    ToolButton(title: "Reboot", systemImage: "arrow.triangle.2.circlepath") { run(.reboot) }
                }
            }
        }
    }

    private func run(_ tool: DeviceTool) {
        Task { await tools.perform(tool, on: device) }
    }
}

private struct ManageDeviceView: View {
    let device: Device
    let onGone: () -> Void
    @Environment(DeviceListViewModel.self) private var listModel
    @Environment(DeviceManagementViewModel.self) private var management
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var hardware: AvdHardwareOptions?

    private var stopped: Bool { device.state == .stopped }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !stopped { Hint("Stop the device to rename, clone or delete it.") }
            HStack {
                TextField("New name", text: $newName).textFieldStyle(.roundedBorder).controlSize(.small)
                ToolButton(title: "Rename") { apply { await management.rename(device, to: newName) } }
                if device.platform == .ios {
                    ToolButton(title: "Clone") { applyStaying { await management.clone(device, name: newName) } }
                }
            }
            .disabled(!stopped || newName.trimmingCharacters(in: .whitespaces).isEmpty)
            if device.platform == .android {
                hardwareEditor
            }
            if let error = management.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            if confirmingDelete {
                HStack {
                    Text("Delete \(device.name)?").font(.system(size: 11))
                    ToolButton(title: "Delete", role: .destructive) { apply { await management.delete(device) } }
                    ToolButton(title: "Cancel") { confirmingDelete = false }
                }
            } else {
                ToolButton(title: "Delete…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    .disabled(!stopped)
            }
        }
        .disabled(management.isWorking)
        .onAppear { management.dismissError() }
    }

    @ViewBuilder
    private var hardwareEditor: some View {
        if hardware != nil {
            Divider()
            AvdOptionsForm(options: Binding(get: { hardware ?? AvdHardwareOptions() }, set: { hardware = $0 }))
            HStack {
                ToolButton(title: "Save Hardware") {
                    guard let options = hardware else { return }
                    Task {
                        if await management.updateHardware(of: device, to: options) { hardware = nil }
                    }
                }
                ToolButton(title: "Cancel") { hardware = nil }
            }
            Divider()
        } else {
            ToolButton(title: "Edit Hardware…", systemImage: "cpu") {
                hardware = management.hardwareOptions(of: device) ?? AvdHardwareOptions()
            }
            .disabled(!stopped)
        }
    }

    private func apply(_ work: @escaping () async -> Bool) {
        Task {
            if await work() {
                await listModel.refresh()
                onGone()
            }
        }
    }

    private func applyStaying(_ work: @escaping () async -> Bool) {
        Task {
            if await work() {
                newName = ""
                await listModel.refresh()
            }
        }
    }
}
