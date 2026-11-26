import AppKit
import DeckhandCore
import SwiftUI

/// What a device needs before its traffic shows up: the proxy running, the certificate trusted, the device pointed at the proxy.
struct DeviceSetupView: View {
    let device: Device
    let model: NetworkViewModel
    @Binding var routesMac: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up \(device.name)").font(.headline)
            step("Proxy is running", done: model.isCapturing(device),
                 detail: model.isCapturing(device) ? "Listening on 127.0.0.1:\(model.port)" : "Press Capture, or Set Up below")
            step("Certificate is trusted", done: certificateDone, warning: certificateWarning, detail: certificateDetail)
            step(proxyTitle, done: model.deviceState.proxyConfigured, detail: proxyDetail)
            if let message = model.setupMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let note = model.deviceState.note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button { Task { await model.setUp(device) } } label: {
                    Label("Set Up", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent).disabled(model.isWorking || unsupported)
                Button("Install Certificate") { Task { await model.installCertificate(on: device) } }
                    .disabled(model.isWorking || unsupported)
                Button("Stop Routing") { Task { await model.stopRouting(device) } }
                    .disabled(model.isWorking || !(model.isRoutingMac || model.deviceState.proxyConfigured || (isPhone && model.allowsNetworkDevices)))
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            Divider()
            if device.platform == .ios && !device.isPhysical {
                Toggle("Route this Mac's traffic through the proxy while capturing", isOn: $routesMac)
                    .font(.system(size: 11)).toggleStyle(.checkbox)
                Text("Simulators use the Mac's proxy settings. Other apps are passed through untouched and are not recorded. The settings are put back when capturing stops or Deckhand quits.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if isPhone {
                Text("Set Up makes the proxy listen on the local network, so anyone on this Wi-Fi can use it while capturing. Stop Routing closes it again.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Reveal Certificate") {
                    if let path = model.certificatePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                Button("Copy Certificate Path") {
                    if let path = model.certificatePath {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 380)
        .task { await model.refreshDeviceState() }
    }

    private var isPhone: Bool { device.platform == .ios && device.isPhysical }

    private var unsupported: Bool { device.state != .running }

    private var proxyTitle: String {
        if isPhone { return "Phone sends its traffic to this Mac" }
        return device.platform == .android ? "Device uses the proxy" : "Mac routes traffic to the proxy"
    }

    private var proxyDetail: String {
        if isPhone {
            let address = model.networkAddress.map { "\($0):\(model.port)" } ?? "this Mac's address, port \(model.port)"
            return "Wi-Fi › Configure Proxy › Manual: \(address)"
        }
        if device.state != .running { return "Start the device first" }
        return device.platform == .android ? "adb reverse and the global proxy setting" : "macOS Wi-Fi and Ethernet web proxy"
    }

    private var certificateDetail: String {
        if isPhone { return "Open http://deckhand.proxy in Safari, install the profile and trust it in Certificate Trust Settings" }
        if device.state != .running { return "Start the device first" }
        guard device.platform == .android else { return "Added to the simulator's keychain" }
        switch model.deviceState.androidTrust {
        case .system: return "In the system store: every app trusts it, until the device restarts"
        case .rootable: return "Not in the system store yet. This device allows root, so Set Up installs it for every app"
        case .locked:
            return "System trust disabled: this device cannot be rooted (a Google Play image or a production build). "
                + "Only apps that trust user certificates, such as browsers and debug builds, are decrypted. "
                + "Use a Google APIs or AOSP emulator image to decrypt every app"
        case nil: return "System store on a rootable emulator, otherwise the user store"
        }
    }

    /// Android apps ignore the user store, so a certificate only there is not a full success.
    private var certificateDone: Bool {
        device.platform == .android ? model.deviceState.androidTrust == .system : model.deviceState.certificateInstalled
    }

    private var certificateWarning: Bool {
        device.platform == .android && model.deviceState.androidTrust == .locked
    }

    private func step(_ title: String, done: Bool, warning: Bool = false, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(warning ? Color.orange : done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
