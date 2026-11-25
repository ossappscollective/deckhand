import SwiftUI
import DeckhandCore

/// One device in the popover, laid out like the rows of the system's own Wi-Fi and Bluetooth menus: an icon, two lines and
/// controls that appear under the pointer. A click opens it, a double-click opens it the other way (see `DeviceOpenMode`).
struct DeviceRowView: View {
    @Environment(DeviceToolsViewModel.self) private var toolsModel
    @AppStorage(Preferences.muteAudioKey) private var muteAudio = false
    @AppStorage(Preferences.deviceClickKey) private var click = DeviceOpenMode.deckhand

    let device: Device
    let isBusy: Bool
    let error: String?
    let onAction: (DeviceAction) -> Void
    let onOpen: (DeviceOpenMode) -> Void
    let onManage: () -> Void
    let onDelete: () -> Void
    @State private var confirmingDelete = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                icon
                deviceInfo
                Spacer(minLength: 8)
                trailing
            }
            if confirmingDelete {
                HStack(spacing: 8) {
                    Text("Delete \(device.name)?").font(.callout)
                    Spacer()
                    Button("Cancel") { confirmingDelete = false }
                    Button("Delete", role: .destructive) {
                        confirmingDelete = false
                        onDelete()
                    }
                }
                .controlSize(.small)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onOpen(click.other) }
        .onTapGesture { onOpen(click) }
        .help(helpText)
    }

    private var helpText: String {
        "Click: \(click == .deckhand ? "Deckhand window" : "own window"). Double-click: \(click == .deckhand ? "own window" : "Deckhand window")"
    }

    /// A round badge like Control Center's: filled while the device is up.
    private var icon: some View {
        ZStack {
            Circle().fill(badgeFill)
            if device.state == .booting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(device.state == .running ? Color.white : Color.secondary)
            }
        }
        .frame(width: 30, height: 30)
    }

    private var symbol: String {
        let name = device.name.lowercased()
        if device.platform == .ios { return name.contains("ipad") ? "ipad" : "iphone.gen3" }
        return name.contains("tablet") ? "ipad.landscape" : "smartphone"
    }

    private var badgeFill: Color {
        switch device.state {
        case .running: Color.green
        case .booting: Color.orange.opacity(0.25)
        case .stopped: Color.primary.opacity(0.10)
        case .unavailable: Color.red.opacity(0.25)
        }
    }

    private var deviceInfo: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var subtitle: String {
        "\(device.osVersion) · \(stateLabel)"
    }

    private var stateLabel: String {
        switch device.state {
        case .running: device.isPhysical ? "Connected" : "Running"
        case .booting: "Booting…"
        case .stopped: "Stopped"
        case .unavailable: device.statusNote ?? "Unavailable"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: 2) {
                if !device.isPhysical { primaryActionButton }
                actionMenu
            }
            // under the pointer, or when the keyboard is on them; the space stays, so the rows do not shift
            .opacity(hovering ? 1 : 0)
        }
    }

    private var primaryActionButton: some View {
        Button {
            onAction(device.state == .running ? .stop : .start)
        } label: {
            Image(systemName: device.state == .running ? "stop.fill" : "play.fill")
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(device.state == .running ? Color.red : Color.primary)
        .disabled(device.state == .booting)
        .help(device.state == .running ? "Stop" : "Start with its own window")
    }

    private var actionMenu: some View {
        Menu {
            if !device.isPhysical && device.state == .stopped {
                Button("Start in Deckhand") { onOpen(.deckhand) }
                Button("Start in Background") { onAction(.startHeadless) }
                Button("Start with \(device.platform == .ios ? "Simulator" : "Emulator") Window") { onAction(.start) }
            }
            if !device.isPhysical && device.platform == .android && device.state == .stopped {
                Button(muteAudio ? "Start with Sound" : "Start without Sound") {
                    onAction(.startWithAlternateAudio)
                }
            }
            if !device.isPhysical {
                Button("Cold Boot") { onAction(.coldBoot) }
                Button(device.platform == .ios ? "Erase" : "Wipe Data", role: .destructive) {
                    onAction(.erase)
                }
            }
            if device.state == .running {
                if !device.isPhysical { Divider() }
                if DeviceTool.screenshot.isSupported(for: device) {
                    Button("Screenshot") { runTool(.screenshot) }
                }
                if DeviceTool.startRecording.isSupported(for: device) {
                    if toolsModel.isRecording(device) {
                        Button("Stop Recording") { runTool(.stopRecording) }
                    } else {
                        Button("Start Recording") { runTool(.startRecording) }
                    }
                }
                if DeviceTool.appearance(dark: true).isSupported(for: device) {
                    Menu("Appearance") {
                        Button("Dark") { runTool(.appearance(dark: true)) }
                        Button("Light") { runTool(.appearance(dark: false)) }
                    }
                }
            }
            Divider()
            Button("Manage…", action: onManage)
            if !device.isPhysical {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .disabled(device.state != .stopped)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func runTool(_ tool: DeviceTool) {
        Task { await toolsModel.perform(tool, on: device) }
    }
}
