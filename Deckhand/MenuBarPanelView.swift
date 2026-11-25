import SwiftUI
import AppKit
import Combine
import DeckhandCore

enum PanelRoute: Equatable {
    case list
    case detail(deviceId: String)
    case create(Platform)
}

struct MenuBarPanelView: View {
    @Environment(DeviceListViewModel.self) private var viewModel
    @Environment(DeviceToolsViewModel.self) private var toolsModel
    @Environment(DeviceManagementViewModel.self) private var managementModel
    @Environment(\.openWindow) private var openWindow
    @Environment(HubRouter.self) private var hubRouter
    @State private var route: PanelRoute = .list
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Preferences.menuBarIndicatorKey) private var indicator = MenuBarIndicator.iconAndCount

    private let appLaunched = NSWorkspace.shared.notificationCenter
        .publisher(for: NSWorkspace.didLaunchApplicationNotification)
    private let appTerminated = NSWorkspace.shared.notificationCenter
        .publisher(for: NSWorkspace.didTerminateApplicationNotification)

    var body: some View {
        content
        .task { await autoRefresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await viewModel.refresh() } }
        }
        .onReceive(appLaunched) { refreshIfDeviceHost($0) }
        .onReceive(appTerminated) { refreshIfDeviceHost($0) }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .list:
            VStack(spacing: 0) {
                header
                Divider()
                deviceList
                notices
                Divider()
                footer
            }
        case .detail(let deviceId):
            DeviceDetailView(deviceId: deviceId, onBack: { route = .list }, onOpenHub: { openHub(selecting: $0.id) })
        case .create(let platform):
            CreateDeviceView(platform: platform, onDone: { route = .list })
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let message = toolsModel.message {
            noticeBanner(message.text, isError: message.isError, missingTool: message.missingTool) { toolsModel.dismissMessage() }
                .task(id: message) {
                    guard !message.isError else { return }
                    try? await Task.sleep(for: .seconds(5))
                    if toolsModel.message == message { toolsModel.dismissMessage() }
                }
        }
        if let error = managementModel.error {
            noticeBanner(error, isError: true) { managementModel.dismissError() }
        }
    }

    private func noticeBanner(_ text: String, isError: Bool, missingTool: OptionalTool? = nil, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.green)
            Text(text)
                .font(.system(size: 11))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let missingTool { InstallToolButton(tool: missingTool, title: "How to install") }
            Button(action: dismiss) {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Deckhand")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            HeaderButton(symbol: "macwindow", help: "Open the Deckhand window") { openHub(selecting: nil) }
            HeaderButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await viewModel.refresh() } }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }

    private var deviceList: some View {
        ScrollView {
            VStack(spacing: 12) {
                DeviceSectionView(
                    title: "iOS Simulators",
                    devices: viewModel.iosDevices,
                    error: viewModel.iosError,
                    busyDeviceIds: viewModel.busyDeviceIds,
                    rowErrors: viewModel.rowErrors,
                    onAction: performAction,
                    onOpen: openDevice,
                    onManage: { route = .detail(deviceId: $0.id) },
                    onDelete: deleteDevice,
                    onAdd: { route = .create(.ios) },
                    onCleanUp: cleanUpUnavailableSimulators)
                DeviceSectionView(
                    title: "Android Emulators",
                    devices: viewModel.androidDevices,
                    error: viewModel.androidError,
                    busyDeviceIds: viewModel.busyDeviceIds,
                    rowErrors: viewModel.rowErrors,
                    onAction: performAction,
                    onOpen: openDevice,
                    onManage: { route = .detail(deviceId: $0.id) },
                    onDelete: deleteDevice,
                    onAdd: { route = .create(.android) })
                if !viewModel.physicalDevices.isEmpty || viewModel.physicalError != nil {
                    DeviceSectionView(
                        title: "Physical Devices",
                        devices: viewModel.physicalDevices,
                        error: viewModel.physicalError,
                        busyDeviceIds: viewModel.busyDeviceIds,
                        rowErrors: viewModel.rowErrors,
                        onAction: performAction,
                        onOpen: openDevice,
                        onManage: { route = .detail(deviceId: $0.id) },
                        onDelete: deleteDevice,
                        summary: connectedSummary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
    }

    /// Settings and Quit as the rows of a menu, with the keys a menu would show.
    private var footer: some View {
        VStack(spacing: 0) {
            MenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            MenuRow(title: "Quit Deckhand", symbol: "power", shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(6)
    }

    /// What a click (and, the other way round, a double-click) on a device does. A device that is not up is started first:
    /// without a window of its own when it is to open in Deckhand, with it when it is to open in its own.
    private func openDevice(_ device: Device, _ mode: DeviceOpenMode) {
        switch (mode, device.state) {
        case (.deckhand, .stopped) where !device.isPhysical:
            Task { await viewModel.perform(.startHeadless, on: device) }
            openHub(selecting: device.id)
        case (.window, .stopped) where !device.isPhysical:
            Task { await viewModel.perform(.start, on: device) }
        case (.window, .running) where !device.isPhysical:
            if !DeviceWindows.bringToFront(device) { openHub(selecting: device.id) }
        default:
            openHub(selecting: device.id)
        }
    }

    private func performAction(_ action: DeviceAction, on device: Device) {
        Task { await viewModel.perform(action, on: device) }
    }

    private func connectedSummary(_ devices: [Device]) -> String {
        "\(devices.count(where: { $0.state == .running })) connected"
    }

    private func openHub(selecting deviceId: String?) {
        if let deviceId { hubRouter.selection = deviceId }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "hub")
    }

    private func deleteDevice(_ device: Device) {
        Task {
            _ = await managementModel.delete(device)
            await viewModel.refresh()
        }
    }

    private func cleanUpUnavailableSimulators() {
        Task {
            _ = await managementModel.deleteUnavailableSimulators()
            await viewModel.refresh()
        }
    }

    /// With the indicator on, the menu bar icon keeps the list fresh; otherwise the open popover does.
    private func autoRefresh() async {
        await viewModel.refresh()
        guard indicator == .never else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            await viewModel.refresh()
        }
    }

    private func refreshIfDeviceHost(_ notification: Notification) {
        guard isDeviceHost(notification) else { return }
        Task { await viewModel.refresh() }
    }

    private func isDeviceHost(_ notification: Notification) -> Bool {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return false
        }
        if let bundleIdentifier = app.bundleIdentifier,
           SimulatorHost.bundleIdentifiers.contains(bundleIdentifier) { return true }
        let executable = app.executableURL?.lastPathComponent ?? app.localizedName ?? ""
        return executable.contains("qemu") || executable.contains("emulator")
    }
}
