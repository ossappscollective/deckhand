import SwiftUI
import DeckhandCore

/// Virtual camera for an iOS simulator. Nothing is queried until the section opens.
struct CameraToolsView: View {
    let device: Device
    @Environment(VirtualCameraViewModel.self) private var camera

    private enum Kind: String, CaseIterable, Identifiable {
        case webcam = "Webcam", image = "Image", video = "Video"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .webcam
    @State private var webcamId: String?
    @State private var file: String?

    private var running: Bool { camera.isActive(on: device) }
    private var busyElsewhere: Bool { camera.phase != .idle && camera.activeDeviceId != device.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !camera.isLibraryAvailable {
                missingLibrary
            } else {
                picker
                Toggle("Fill instead of fit", isOn: Binding(get: { camera.flags.fill }, set: { camera.flags.fill = $0 }))
                    .toggleStyle(.checkbox).controlSize(.small)
                Toggle("Mirror", isOn: Binding(get: { camera.flags.mirror }, set: { camera.flags.mirror = $0 }))
                    .toggleStyle(.checkbox).controlSize(.small)
                controls
            }
            if let error = camera.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .onAppear {
            camera.refreshAvailability()
            camera.loadWebcams()
            if webcamId == nil { webcamId = camera.webcams.first(where: \.isDefault)?.id ?? camera.webcams.first?.id }
        }
    }

    private var missingLibrary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hint("The simulator camera uses Baguette's VirtualCamera library, which is not installed.")
            HStack {
                InstallToolButton(tool: .baguette, title: "How to install")
                ToolButton(title: "Check Again") { camera.refreshAvailability() }
            }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().disabled(running)
            switch kind {
            case .webcam:
                if camera.webcams.isEmpty {
                    Hint("No camera found on this Mac. Pick an image or a video instead.")
                } else {
                    Picker("Camera", selection: $webcamId) {
                        ForEach(camera.webcams) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .controlSize(.small).disabled(running)
                }
            case .image, .video:
                HStack {
                    ToolButton(title: file == nil ? "Choose File…" : "Change…") {
                        FilePicker.chooseFile(extensions: kind == .image ? ["png", "jpg", "jpeg", "heic", "heif", "gif"]
                                                                          : ["mov", "mp4", "m4v"]) { file = $0 }
                    }
                    .disabled(running)
                    if let file {
                        Text((file as NSString).lastPathComponent).font(.system(size: 11)).lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var source: CameraSource? {
        switch kind {
        case .webcam: webcamId.map(CameraSource.webcam)
        case .image: file.map(CameraSource.image)
        case .video: file.map(CameraSource.video)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if camera.cleanupRequired, camera.activeDeviceId == device.id {
            ToolButton(title: "Retry Stop", systemImage: "arrow.clockwise") { Task { await camera.stop() } }
        } else if running {
            HStack {
                ToolButton(title: "Stop Camera", systemImage: "stop.circle.fill") { Task { await camera.stop() } }
                if camera.phase == .streaming {
                    Text(String(format: "%.0f fps", camera.framesPerSecond)).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Hint("Relaunch the app that should see the camera: it only picks it up when it starts. Use Apps → ⋯ → Relaunch.")
        } else if busyElsewhere {
            Hint("The camera is in use on another simulator. Stop it there first.")
        } else {
            ToolButton(title: "Start Camera", systemImage: "camera.fill") {
                guard let source else { return }
                Task { await camera.start(on: device, source: source) }
            }
            .disabled(source == nil || device.state != .running)
        }
    }
}
