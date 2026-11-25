import SwiftUI
import DeckhandCore

@main
struct DeckhandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel: DeviceListViewModel
    @State private var toolsModel = DeviceToolsViewModel(
        captureDirectory: { Preferences.captureDirectory },
        terminalApp: { Preferences.terminalApp },
        locateSDK: { Preferences.locateSDK() })
    @State private var managementModel = DeviceManagementViewModel { Preferences.locateSDK() }
    @State private var cameraModel = VirtualCameraViewModel()
    @State private var hubRouter = HubRouter()
    @State private var networkModel = NetworkViewModel(
        defaults: .standard,
        helperAPK: { Bundle.main.path(forResource: "DeckhandHelper", ofType: "apk") },
        locateSDK: { Preferences.locateSDK() })
    @State private var installCenter = InstallRequestCenter.shared

    init() {
        Preferences.registerDefaults()
        // a run that crashed while capturing leaves the macOS proxy pointing at a proxy that is gone
        NetworkViewModel.restoreSystemProxyForQuit()
        _viewModel = State(initialValue: DeviceListViewModel(
            launchOptions: { Preferences.androidLaunchOptions },
            showPhysicalDevices: { Preferences.showPhysicalDevices },
            locateSDK: { Preferences.locateSDK() }))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView()
                .environment(viewModel)
                .environment(toolsModel)
                .environment(managementModel)
                .environment(cameraModel)
                .environment(hubRouter)
                .environment(networkModel)
                .frame(width: 340, height: 560)
        } label: {
            MenuBarLabel(center: installCenter, list: viewModel, router: hubRouter)
        }
        .menuBarExtraStyle(.window)

        Window("Deckhand", id: "hub") {
            HubView()
                .onAppear { AppDelegate.network = networkModel }
                .environment(viewModel)
                .environment(toolsModel)
                .environment(managementModel)
                .environment(cameraModel)
                .environment(hubRouter)
                .environment(installCenter)
                .environment(networkModel)
        }
        .defaultSize(width: 1180, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .commands { DeviceCommands() }

        Settings {
            SettingsView()
        }
    }
}
