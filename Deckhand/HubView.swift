import SwiftUI
import DeckhandCore

/// Device-hub style window: devices on the left, an optional live mirror in the middle, management on the right.
struct HubView: View {
    @Environment(DeviceListViewModel.self) private var list
    @Environment(DeviceToolsViewModel.self) private var tools
    @Environment(DeviceManagementViewModel.self) private var management
    @Environment(HubRouter.self) private var router
    @Environment(InstallRequestCenter.self) private var installs
    @AppStorage("hubShowsMirror") private var showMirror = true
    @AppStorage("hubShowsInspector") private var showInspector = true
    @AppStorage("hubLogMode") private var logModeRaw = PanelMode.hidden.rawValue
    @AppStorage("hubLogHeight") private var logHeight = 280.0
    @AppStorage("hubPanelKind") private var panelKindRaw = PanelKind.logs.rawValue
    @AppStorage(Preferences.logBufferKey) private var logBuffer = 50_000
    @AppStorage(Preferences.networkPortKey) private var networkPort = 0
    @State private var logs = LogViewModel(defaults: .standard) { Preferences.locateSDK() }
    @Environment(NetworkViewModel.self) private var network
    @State private var dropTargeted = false
    /// How much of the window the tools column takes, as a share: resizing the window scales both columns.
    @AppStorage("hubInspectorFraction") private var inspectorFraction = 0.38
    @State private var dragStartWidth: CGFloat?
    @State private var creating: Platform?
    @State private var mirror = MirrorController()
    @State private var deleting: Device?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var windowFit = WindowFit()

    var body: some View {
        @Bindable var router = router
        content(router: $router.selection)
            .frame(minHeight: 360)
    }

    private func content(router selection: Binding<String?>) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar(selection: selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New iOS Simulator…") { creating = .ios }
                    Button("New Android Emulator…") { creating = .android }
                } label: {
                    Label("New Device", systemImage: "plus")
                }
            }
            ToolbarItem {
                Toggle(isOn: $showMirror) {
                    Label("Mirror", systemImage: "rectangle.on.rectangle")
                }
                .toggleStyle(.button)
                .help("Show the live screen of the selected device")
            }
            ToolbarItem {
                Toggle(isOn: Binding(get: { logMode != .hidden && showInspector && panelKind == .logs },
                                     set: { togglePanel(.logs, on: $0) })) {
                    Label("Logs", systemImage: "text.alignleft")
                }
                .toggleStyle(.button)
                .help("Show the log of the selected device")
            }
            ToolbarItem {
                Toggle(isOn: Binding(get: { logMode != .hidden && showInspector && panelKind == .network },
                                     set: { togglePanel(.network, on: $0) })) {
                    Label("Network", systemImage: "network")
                }
                .toggleStyle(.button)
                .help("Show the HTTP and HTTPS requests of the selected device")
            }
            ToolbarItem {
                Toggle(isOn: $showInspector) {
                    Label("Tools", systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                .help("Show or hide the tools panel.")
            }
        }
        .task {
            while !Task.isCancelled {
                await list.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .focusedSceneValue(\.hubActions, HubActions(device: selected, isRecording: selected.map { tools.isRecording($0) } ?? false,
                                                   perform: { perform($0) }))
        .onChange(of: router.selection) { _, _ in creating = nil }
        .background(WindowAccessor { windowFit.attach($0) })
        // a panel shown or hidden: the window takes the width at the same time, so the picture keeps its size
        .onChange(of: panelLayout) { _, _ in fitWindowToPicture() }
        .animation(Self.panelAnimation, value: animatedLayout)
        .onChange(of: aspectLock, initial: true) { _, lock in
            windowFit.keepsShape = lock
            windowFit.barHeight = selected.map { $0.platform == .android || !$0.isPhysical } == true ? Self.barHeight : 0
        }
        .onAppear {
            tools.didRotate = { mirror.rotated($0, clockwise: $1) }
            tools.onScreenshotCaptured = { ScreenshotThumbnail.shared.show(path: $0) }
            mirror.orientationProvider = { tools.orientation(of: $0) }
        }
        .onChange(of: list.iosDevices + list.androidDevices + list.physicalDevices) { _, devices in
            Task { await network.deviceListChanged(devices) }
        }
        .onChange(of: logBuffer, initial: true) { _, lines in logs.capacity = lines }
        .onChange(of: networkPort, initial: true) { _, port in network.preferredPort = port > 0 ? port : nil }
                // the app is a menu bar agent; while this window is open it also gets a Dock icon
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
            logs.stop()
        }
        .sheet(item: Binding(get: { installs.pending.map(PendingInstall.init) }, set: { if $0 == nil { installs.pending = nil } })) {
            InstallRequestSheet(request: $0.request) { installs.pending = nil }
        }
        .confirmationDialog(deleting.map { "Delete \($0.name)?" } ?? "", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { device in
            Button("Delete", role: .destructive) { delete(device) }
        } message: { _ in
            Text("This removes the device and its data. It cannot be undone.")
        }
    }

    private var selected: Device? { router.selection.flatMap { list.device(id: $0) } }

    // MARK: Sidebar

    private func sidebar(selection: Binding<String?>) -> some View {
        List(selection: selection) {
            deviceSection("iOS Simulators", list.iosDevices, error: list.iosError)
            deviceSection("Android Emulators", list.androidDevices, error: list.androidError)
            if !list.physicalDevices.isEmpty || list.physicalError != nil {
                deviceSection("Physical Devices", list.physicalDevices, error: list.physicalError)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func deviceSection(_ title: String, _ devices: [Device], error: String?) -> some View {
        Section(title) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                SidebarRow(device: device, isBusy: list.busyDeviceIds.contains(device.id))
                    .tag(device.id)
                    .contextMenu { contextMenu(for: device) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for device: Device) -> some View {
        if !device.isPhysical {
            if device.state == .running {
                Button("Stop") { Task { await list.perform(.stop, on: device) } }
            } else if device.state == .stopped {
                Button("Start") { Task { await list.perform(.startHeadless, on: device) } }
                Button("Start with \(device.platform == .ios ? "Simulator" : "Emulator") Window") { Task { await list.perform(.start, on: device) } }
                if device.platform == .android {
                    Button("Start without/with Sound") { Task { await list.perform(.startWithAlternateAudio, on: device) } }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { deleting = device }
                .disabled(device.state != .stopped)
        }
    }

    private func delete(_ device: Device) {
        Task {
            if await management.delete(device) {
                if router.selection == device.id { router.selection = nil }
                await list.refresh()
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let platform = creating {
            CreateDeviceView(platform: platform, onDone: { creating = nil })
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
        } else if let device = selected {
            GeometryReader { geometry in
                let split = splitWidths(total: geometry.size.width)
                HStack(spacing: 0) {
                    if showMirror {
                        MirrorPane(device: device, controller: mirror)
                            .frame(width: split.mirror)
                        if showInspector { splitHandle(total: geometry.size.width, inspector: split.inspector).transition(.opacity) }
                    }
                    if showInspector || !showMirror {
                        VStack(spacing: 0) {
                            if logMode != .full {
                                header(device)
                                Divider()
                                DeviceManageContent(device: device, onGone: { router.selection = nil })
                            }
                            if logMode != .hidden {
                                if logMode == .split {
                                    PanelResizeHandle(height: $logHeight, available: geometry.size.height)
                                }
                                Group {
                                    if panelKind == .network {
                                        NetworkPanelView(device: device, model: network, kind: kindBinding, isFull: logMode == .full,
                                                         onToggleFull: { logModeRaw = (logMode == .full ? PanelMode.split : .full).rawValue },
                                                         onClose: { logModeRaw = PanelMode.hidden.rawValue })
                                    } else {
                                        LogPanelView(device: device, model: logs, kind: kindBinding, isFull: logMode == .full,
                                                     onToggleFull: { logModeRaw = (logMode == .full ? PanelMode.split : .full).rawValue },
                                                     onClose: { logModeRaw = PanelMode.hidden.rawValue })
                                    }
                                }
                                    .frame(height: logMode == .split ? min(logHeight, max(geometry.size.height - 160, 120)) : nil)
                                    .frame(maxHeight: logMode == .full ? .infinity : nil)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .frame(width: split.inspector)
                        .background(.background.secondary)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            }
            // narrower than this, the picture or the tools column would be pushed out of the window
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { windowFit.measured(detail: $0, sidebarVisible: columnVisibility != .detailOnly) }
            .frame(minWidth: (showMirror ? Self.mirrorMin : 0) + (showInspector || !showMirror ? inspectorMin : 0))
            .task(id: LogKey(deviceId: device.id, running: device.state == .running,
                             visible: logMode != .hidden && panelKind == .logs && (showInspector || !showMirror))) {
                if device.state == .running, logMode != .hidden, panelKind == .logs, showInspector || !showMirror {
                    logs.start(device)
                } else {
                    logs.stop()
                }
            }
            .overlay(alignment: .bottom) { toast(showsAlways: !(showInspector || !showMirror)) }
            .overlay(alignment: .topTrailing) {
                if tools.isWorking {
                    ProgressView().controlSize(.small).padding(8)
                        .background(.regularMaterial, in: Capsule()).padding(10)
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3).padding(4)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard device.state == .running else { return false }
                let paths = urls.filter(\.isFileURL).map(\.path)
                guard !paths.isEmpty else { return false }
                Task { await tools.drop(paths, on: device) }
                return true
            } isTargeted: { dropTargeted = $0 }
        } else {
            ContentUnavailableView("Select a device", systemImage: "iphone.gen3",
                                   description: Text("Pick a simulator, emulator or connected device on the left."))
        }
    }

    /// Result of the last action, for when the tools panel that normally shows it is hidden.
    @ViewBuilder
    private func toast(showsAlways: Bool) -> some View {
        if showsAlways, let message = tools.message {
            HStack(spacing: 8) {
                Text(message.text)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .foregroundStyle(message.isError ? Color.red : Color.primary)
                if let tool = message.missingTool { InstallToolButton(tool: tool, title: "How to install") }
            }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 52)
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(message.missingTool != nil ? 30 : message.isError ? 8 : 4))
                    if tools.message == message { tools.dismissMessage() }
                }
        }
    }

    /// What decides how wide the window should be: which panels are showing.
    private struct PanelLayout: Equatable {
        let mirror: Bool
        let inspector: Bool
        let sidebar: Bool
        let logs: Bool
    }

    private var panelLayout: PanelLayout {
        PanelLayout(mirror: showMirror, inspector: showInspector, sidebar: columnVisibility != .detailOnly, logs: logMode != .hidden)
    }

    /// What the panels' own animation follows (the sidebar has the system's).
    private struct AnimatedLayout: Equatable {
        let mirror: Bool
        let inspector: Bool
        let logs: String
    }

    private var animatedLayout: AnimatedLayout {
        AnimatedLayout(mirror: showMirror, inspector: showInspector, logs: logModeRaw)
    }

    static let panelAnimation = Animation.easeInOut(duration: 0.28)

    /// Whether a drag of a corner of the window keeps the picture's shape: only a portrait picture is in the window.
    private var aspectLock: Bool {
        guard showMirror, !showInspector, columnVisibility == .detailOnly, creating == nil,
              let device = selected, device.state == .running, mirror.state == .live,
              let size = mirror.displaySize else { return false }
        return size.height > size.width
    }

    /// Gives the window the width at which the picture, with the height it has now, has no bars beside it.
    private func fitWindowToPicture() {
        guard showMirror, creating == nil, let device = selected, device.state == .running, mirror.state == .live,
              let size = mirror.displaySize, size.width > 0, size.height > 0 else { return }
        let detail = windowFit.detailSize
        let bar = device.platform == .android || !device.isPhysical ? Self.barHeight : 0
        let pictureHeight = detail.height - bar
        guard pictureHeight > 0 else { return }
        // the tools column is a share of the width (but never narrower than its content), see splitWidths
        let target = WindowSizing.detailWidth(pictureHeight: pictureHeight, aspect: size.width / size.height,
                                              showsInspector: showInspector, inspectorFraction: CGFloat(inspectorFraction),
                                              inspectorMinimum: inspectorMin)
        let sidebar = columnVisibility == .detailOnly ? 0 : windowFit.sidebarWidth
        windowFit.setWidth(sidebar + target, duration: 0.28)
    }

    private var logMode: PanelMode { PanelMode(rawValue: logModeRaw) ?? .hidden }

    private struct LogKey: Equatable {
        let deviceId: String
        let running: Bool
        let visible: Bool
    }

    private var panelKind: PanelKind { PanelKind(rawValue: panelKindRaw) ?? .logs }

    private var kindBinding: Binding<PanelKind> {
        Binding(get: { panelKind }, set: { panelKindRaw = $0.rawValue })
    }

    /// The Device and Panels menus. Keys go to the mirror's input rather than to the simulator or emulator window.
    private func perform(_ command: HubCommand) {
        guard let device = selected else { return }
        let ios = device.platform == .ios
        func run(_ tool: DeviceTool) { Task { await tools.perform(tool, on: device) } }
        func panel(_ kind: PanelKind) { togglePanel(kind, on: !(logMode != .hidden && showInspector && panelKind == kind)) }
        switch command {
        case .home: if ios { mirror.press(SimulatorInputSession.Button.home) } else { mirror.press(AndroidInput.Key.home) }
        case .appSwitcher: if ios { mirror.press(SimulatorInputSession.Button.appSwitcher) } else { mirror.press(AndroidInput.Key.appSwitch) }
        case .back: mirror.press(AndroidInput.Key.back)
        case .lock: if ios { mirror.press(SimulatorInputSession.Button.lock) } else { mirror.press(AndroidInput.Key.power) }
        case .volumeUp: if ios { mirror.press(SimulatorInputSession.Button.volumeUp) } else { mirror.press(AndroidInput.Key.volumeUp) }
        case .volumeDown: if ios { mirror.press(SimulatorInputSession.Button.volumeDown) } else { mirror.press(AndroidInput.Key.volumeDown) }
        case .screenshot: run(.screenshot)
        case .screenshotToCorner: Task { await tools.screenshotToCorner(device) }
        case .toggleRecording: run(tools.isRecording(device) ? .stopRecording : .startRecording)
        case .rotateLeft: run(.rotateLeft)
        case .rotateRight: run(.rotate)
        case .toggleDarkMode: run(.toggleAppearance)
        case .largerText: run(.textSize(larger: true))
        case .smallerText: run(.textSize(larger: false))
        case .start: Task { await list.perform(.start, on: device) }
        case .startHeadless: Task { await list.perform(.startHeadless, on: device) }
        case .stop: Task { await list.perform(.stop, on: device) }
        case .showMirror: showMirror.toggle()
        case .showLogs: panel(.logs)
        case .showNetwork: panel(.network)
        case .showTools: showInspector.toggle()
        }
    }

    private func togglePanel(_ kind: PanelKind, on: Bool) {
        if on {
            showInspector = true
            panelKindRaw = kind.rawValue
            logModeRaw = (logMode == .hidden ? PanelMode.split : logMode).rawValue
        } else if panelKind == kind {
            logModeRaw = PanelMode.hidden.rawValue
        }
    }

    /// What the tools column needs: its cards fit in 340, but the logs and network tables need room for their columns.
    private var inspectorMin: CGFloat { logMode != .hidden && (showInspector || !showMirror) ? 640 : 340 }
    /// Height of the button strip under the picture; it is part of the column but not of the picture.
    static let barHeight: CGFloat = 36

    /// The mirror takes what the tools column leaves; the column is a share of the window that never gets narrower
    /// than its content needs.
    private func splitWidths(total: CGFloat) -> (mirror: CGFloat, inspector: CGFloat) {
        guard showMirror else { return (0, total) }
        guard showInspector else { return (total, 0) }
        let inspector = min(max(total * inspectorFraction, inspectorMin), max(total - Self.mirrorMin, inspectorMin))
        return (total - inspector, inspector)
    }

    private static let mirrorMin: CGFloat = 220

    /// The edge between the mirror and the tools column: drag it to give one more room.
    private func splitHandle(total: CGFloat, inspector: CGFloat) -> some View {
        Divider()
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStartWidth ?? inspector
                            dragStartWidth = start
                            let width = min(max(start - value.translation.width, inspectorMin), max(total - Self.mirrorMin, inspectorMin))
                            inspectorFraction = Double(width / total)
                        }
                        .onEnded { _ in dragStartWidth = nil })
            }
    }

    private func header(_ device: Device) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(of: device)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("\(device.osVersion) · \(label(of: device))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !device.isPhysical, device.state == .running || device.state == .stopped {
                Button(device.state == .running ? "Stop" : "Start") {
                    // the mirror in this window is the screen, so the device needs no window of its own
                    Task { await list.perform(device.state == .running ? .stop : .startHeadless, on: device) }
                }
                .controlSize(.small)
                .disabled(list.busyDeviceIds.contains(device.id))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func label(of device: Device) -> String {
        switch device.state {
        case .running: device.isPhysical ? "Connected" : "Running"
        case .booting: "Booting…"
        case .stopped: "Stopped"
        case .unavailable: device.statusNote ?? "Unavailable"
        }
    }

    private func color(of device: Device) -> Color {
        SidebarRow.color(for: device.state)
    }
}

private struct PendingInstall: Identifiable {
    let request: InstallRequest
    var id: URL { request.url }
}

private struct SidebarRow: View {
    let device: Device
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Self.color(for: device.state)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text(device.osVersion).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if isBusy {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
    }

    static func color(for state: DeviceState) -> Color {
        switch state {
        case .running: .green
        case .booting: .orange
        case .stopped: Color(nsColor: .tertiaryLabelColor)
        case .unavailable: .red
        }
    }
}

// MARK: Mirror

private struct MirrorPane: View {
    let device: Device
    let controller: MirrorController
    @Environment(DeviceToolsViewModel.self) private var tools
    @Environment(DeviceListViewModel.self) private var list
    @State private var toolHelp: OptionalTool?

    private var key: String { "\(device.id)|\(device.state)" }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                MirrorView(controller: controller)
                overlay
            }
            if device.platform == .android || !device.isPhysical { buttonBar }
        }
        .task(id: key) {
            controller.stop()
            if device.state == .running { controller.start(device) }
        }
        .onDisappear { controller.stop() }
    }

    @ViewBuilder
    private var overlay: some View {
        switch controller.state {
        case .idle:
            if device.state == .running {
                EmptyView()
            } else if device.state == .booting || list.busyDeviceIds.contains(device.id) {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Starting \(device.name)…").foregroundStyle(.white.opacity(0.6))
                }
            } else if device.isPhysical {
                Text("Connect and unlock the device to mirror it").foregroundStyle(.white.opacity(0.6))
            } else {
                VStack(spacing: 10) {
                    Text("Start the device to mirror it").foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 8) {
                        Button { Task { await list.perform(.startHeadless, on: device) } } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .help(device.platform == .ios
                              ? "Boots the simulator without opening the Simulator app: this mirror is its only screen"
                              : "Starts the emulator without its own window: this mirror is its only screen")
                        Button { Task { await list.perform(.start, on: device) } } label: {
                            Label("Start with Window", systemImage: "macwindow")
                        }
                        .buttonStyle(.bordered)
                        .help(device.platform == .ios
                              ? "Opens the Simulator app as well"
                              : "Starts the emulator with its own window as well")
                    }
                    .controlSize(.small).disabled(device.state == .unavailable)
                }
            }
        case .starting:
            ProgressView().controlSize(.small).tint(.white)
        case .live:
            EmptyView()
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
                Button("Retry") { controller.start(device) }.controlSize(.small)
            }
            .padding()
        }
    }

    /// The strip under the picture: navigation, power and rotation stay; what is only occasionally needed is in the menu.
    private var buttonBar: some View {
        ViewThatFits(in: .horizontal) {
            buttons(volume: true)
            buttons(volume: false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: HubView.barHeight)
        .background(.bar)
        .disabled(controller.state != .live && device.platform == .android)
    }

    private func buttons(volume: Bool) -> some View {
        HStack(spacing: 14) {
            if device.platform == .android {
                key(.back, "chevron.left", "Back")
                key(.home, "circle", "Home")
                key(.appSwitch, "square", "Overview")
                if volume {
                    Divider().frame(height: 16)
                    key(.volumeDown, "speaker.wave.1", "Volume down")
                    key(.volumeUp, "speaker.wave.3", "Volume up")
                }
                key(.power, "power", "Power")
            } else if controller.supportsInput {
                simulatorKey(.home, "circle", "Home")
                simulatorKey(.appSwitcher, "square.on.square", "App Switcher")
                simulatorKey(.lock, "power", "Lock")
                if volume {
                    Divider().frame(height: 16)
                    simulatorKey(.volumeDown, "speaker.wave.1", "Volume down")
                    simulatorKey(.volumeUp, "speaker.wave.3", "Volume up")
                }
            } else if let tool = controller.missingTool {
                if volume { Text("View only.").font(.system(size: 11)) }
                InstallToolButton(tool: tool, title: "Touch and keys: install \(tool.displayName)")
            } else if let notice = controller.inputNotice, volume {
                Text(notice).font(.system(size: 11))
            }
            Divider().frame(height: 16)
            if DeviceTool.rotate.isSupported(for: device) {
                Button { Task { await tools.perform(.rotate, on: device) } } label: { Image(systemName: "rotate.right") }
                    .help("Rotate")
            }
            Button { Task { await tools.perform(.screenshot, on: device) } } label: { Image(systemName: "camera") }
                .help("Screenshot")
            moreMenu
        }
        .fixedSize()
    }

    /// What is not needed all the time: which engine draws the picture, the device's own window, a recording.
    private var moreMenu: some View {
        Menu {
            if let engine = controller.engine {
                Text("Mirror engine: \(engine)")
            }
            if device.platform == .android {
                if let tool = controller.missingTool {
                    Button("Faster mirror: install \(tool.displayName)…") { toolHelp = tool }
                }
                if DeviceTool.scrcpy.isSupported(for: device) {
                    Button("Open scrcpy Window") { Task { await tools.perform(.scrcpy, on: device) } }
                }
                Button("Volume Down") { controller.press(AndroidInput.Key.volumeDown) }
                Button("Volume Up") { controller.press(AndroidInput.Key.volumeUp) }
            } else {
                Button("Open Simulator") { openSimulatorApp() }
                if let notice = controller.inputNotice { Text(notice) }
                Button("Volume Down") { controller.press(SimulatorInputSession.Button.volumeDown) }
                    .disabled(!controller.supportsInput)
                Button("Volume Up") { controller.press(SimulatorInputSession.Button.volumeUp) }
                    .disabled(!controller.supportsInput)
            }
            if DeviceTool.startRecording.isSupported(for: device) {
                Divider()
                if tools.isRecording(device) {
                    Button("Stop Recording") { Task { await tools.perform(.stopRecording, on: device) } }
                } else {
                    Button("Start Recording") { Task { await tools.perform(.startRecording, on: device) } }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More")
        .popover(item: $toolHelp, arrowEdge: .top) { MissingToolPopover(tool: $0) }
    }

    private func simulatorKey(_ button: SimulatorInputSession.Button, _ symbol: String, _ help: String) -> some View {
        Button { controller.press(button) } label: { Image(systemName: symbol) }.help(help)
    }

    private func openSimulatorApp() {
        for identifier in SimulatorHost.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    private func key(_ key: AndroidInput.Key, _ symbol: String, _ help: String) -> some View {
        Button { controller.press(key) } label: { Image(systemName: symbol) }.help(help)
    }
}

// MARK: Install links

private struct InstallRequestSheet: View {
    let request: InstallRequest
    let onClose: () -> Void

    @Environment(DeviceListViewModel.self) private var list
    @Environment(DeviceToolsViewModel.self) private var tools
    @State private var targetId: String?
    @State private var started = false

    private var targets: [Device] {
        (list.iosDevices + list.androidDevices + list.physicalDevices).filter { device in
            guard device.state == .running else { return false }
            if let platform = request.platform, device.platform != platform { return false }
            let path = request.url.path.lowercased()
            if device.platform == .ios {
                if path.hasSuffix(".ipa") { return device.isPhysical }
                if path.hasSuffix(".tar.gz") || path.hasSuffix(".tgz") { return !device.isPhysical }
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install a build?").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.url.host ?? "").font(.system(size: 13, weight: .medium))
                Text(request.url.absoluteString).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
            }
            Text("A link asked Deckhand to download this file and install it. Only continue if you trust its source.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if targets.isEmpty {
                Hint("No running device can take this build. Start a simulator, emulator or connect a device.")
            } else {
                Picker("Install on", selection: Binding(get: { selectedTarget?.id }, set: { targetId = $0 })) {
                    ForEach(targets) { Text("\($0.name) · \($0.osVersion)").tag(Optional($0.id)) }
                }
            }
            if let message = tools.message, started {
                Text(message.text).font(.system(size: 11)).foregroundStyle(message.isError ? Color.red : Color.green)
            }
            HStack {
                Spacer()
                Button(started && !tools.isWorking ? "Done" : "Cancel", action: onClose)
                Button("Download & Install", action: install)
                    .buttonStyle(.borderedProminent)
                    .disabled(tools.isWorking || selectedTarget == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { targetId = targets.first?.id }
    }

    private var selectedTarget: Device? {
        targets.first { $0.id == targetId } ?? targets.first
    }

    private func install() {
        guard let device = selectedTarget else { return }
        started = true
        Task { await tools.perform(.install(request.url.absoluteString), on: device) }
    }
}
