import SwiftUI
import DeckhandCore

struct DeviceSectionView: View {
    let title: String
    let devices: [Device]
    let error: String?
    let busyDeviceIds: Set<String>
    let rowErrors: [String: String]
    let onAction: (DeviceAction, Device) -> Void
    let onOpen: (Device, DeviceOpenMode) -> Void
    let onManage: (Device) -> Void
    let onDelete: (Device) -> Void
    var onAdd: (() -> Void)?
    var onCleanUp: (() -> Void)?
    var summary: (([Device]) -> String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader
            if let error {
                errorLabel(error)
            } else if devices.isEmpty {
                emptyLabel
            } else {
                ForEach(devices) { device in
                    DeviceRowView(
                        device: device,
                        isBusy: busyDeviceIds.contains(device.id),
                        error: rowErrors[device.id],
                        onAction: { onAction($0, device) },
                        onOpen: { onOpen(device, $0) },
                        onManage: { onManage(device) },
                        onDelete: { onDelete(device) })
                }
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(runningSummary)
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New device")
            }
            if let onCleanUp {
                Menu {
                    Button("Delete Unavailable Simulators", role: .destructive, action: onCleanUp)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private var runningSummary: String {
        if let summary { return summary(devices) }
        return "\(devices.count(where: { $0.state == .running })) of \(devices.count) running"
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }

    private var emptyLabel: some View {
        Text("No devices found")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }
}
