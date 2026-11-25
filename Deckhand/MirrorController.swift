import AVFoundation
import AppKit
import DeckhandCore
import CoreMediaIO

/// Drives the optional live view of the selected device. One source runs at a time.
@MainActor
@Observable
final class MirrorController {
    enum State: Equatable {
        case idle
        case starting
        case live
        case failed(String)
    }

    enum Content {
        case none
        case video
        case image(NSImage)
        case capture(AVCaptureSession)
    }

    private(set) var state: State = .idle
    private(set) var content: Content = .none
    /// Pixel size of the picture the device sends (a simulator's native, portrait one), for sending touches.
    private(set) var frameSize: CGSize?
    /// How a simulator is held. Its stream is always the native portrait picture, which Simulator.app turns when it
    /// draws it: so does the mirror.
    private(set) var simOrientation = SimulatorOrientation.portrait
    /// Where the view finds how the simulator is held, and how it shows a turn.
    var orientationProvider: ((Device) -> SimulatorOrientation)?
    var rotationAnimator: ((_ clockwise: Bool, _ contentRotation: CGFloat?) -> Void)?
    private let frameState = FrameState()

    /// The picture as shown, which is `frameSize` turned on its side for a simulator held in landscape.
    var displaySize: CGSize? {
        guard let size = frameSize else { return nil }
        return simOrientation == .portrait || device?.platform != .ios ? size : CGSize(width: size.height, height: size.width)
    }

    /// How much the picture is turned to be upright, counterclockwise in radians.
    var contentRotation: CGFloat {
        switch simOrientation {
        case .portrait: 0
        case .landscapeRight: .pi / 2
        case .landscapeLeft: -.pi / 2
        }
    }

    /// Which way the screen turned, and whether a new frame already shows it: see `present`.
    private final class FrameState: @unchecked Sendable {
        private let lock = NSLock()
        private var landscape: Bool?
        private var pending: Bool?

        func expect(clockwise: Bool) { lock.withLock { pending = clockwise } }
        func reset() { lock.withLock { landscape = nil; pending = nil } }

        /// The direction of the turn when this frame is the first one in the other orientation.
        func flip(to isLandscape: Bool) -> Bool? {
            lock.withLock {
                defer { landscape = isLandscape }
                guard let was = landscape, was != isLandscape else { return nil }
                defer { pending = nil }
                return pending ?? true
            }
        }
    }
    private(set) var device: Device?

    nonisolated let displayLayer = AVSampleBufferDisplayLayer()

    private var android: AndroidMirrorSession?
    private var scrcpy: ScrcpySession?
    private var simInput: SimulatorInputSession?
    private var simStream: SimulatorMirrorSession?
    /// Why a simulator cannot be touched yet ("Preparing input…", or the Baguette install hint).
    private(set) var inputNotice: String?
    /// A program that would improve this mirror and is not installed: scrcpy for Android, Baguette for a simulator.
    private(set) var missingTool: OptionalTool?
    private let clipboard = ClipboardSync()
    private var generation = 0
    /// What is feeding the Android picture: "scrcpy" or "adb".
    private(set) var engine: String?
    private static var cachedScrcpy: ScrcpyInstall??
    private var pollTask: Task<Void, Never>?
    private var captureSession: AVCaptureSession?
    private var input: AndroidInput?
    private var screenSize: AndroidMirrorSession.Geometry?
    private var dragStart: (point: CGPoint, time: ContinuousClock.Instant)?

    var supportsInput: Bool {
        guard state == .live else { return false }
        return device?.platform == .android ? (scrcpy != nil || input != nil) : simInput != nil
    }

    func start(_ device: Device) {
        stop()
        if self.device?.id != device.id { frameState.reset() }
        self.device = device
        simOrientation = device.platform == .ios && !device.isPhysical ? orientationProvider?(device) ?? .portrait : .portrait
        state = .starting
        switch (device.platform, device.isPhysical) {
        case (.android, _): startAndroid(device)
        case (.ios, false): startSimulator(device)
        case (.ios, true): startIOSDevice(device)
        }
    }

    /// A rotation was asked for. The adb stream (`screenrecord`) keeps recording at the size it started with, so it
    /// needs a new stream; scrcpy announces the new size itself, and a simulator's stream never changes size.
    func rotated(_ rotated: Device, clockwise: Bool) {
        guard device?.id == rotated.id else { return }
        if rotated.platform == .ios, !rotated.isPhysical {
            simOrientation = orientationProvider?(rotated) ?? .portrait
            rotationAnimator?(clockwise, contentRotation)
            return
        }
        frameState.expect(clockwise: clockwise)
        guard engine == "adb" else { return }
        let token = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.generation == token else { return }
            self.stop()
            self.start(rotated)
        }
    }

    /// Shows a frame. The first one in the other orientation is shown in the same turn of the main thread as the
    /// start of the turning animation, or the new picture would show for a moment before it starts to turn.
    nonisolated private func present(_ frame: VideoFrame) {
        let layer = displayLayer
        if layer.status == .failed { layer.flush() }
        if let clockwise = frameState.flip(to: frame.width > frame.height), !Thread.isMainThread {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { self.rotationAnimator?(clockwise, nil) }
                layer.enqueue(frame.sampleBuffer)
            }
        } else {
            layer.enqueue(frame.sampleBuffer)
        }
        Task { @MainActor [weak self] in self?.didReceive(width: frame.width, height: frame.height) }
    }

    func stop() {
        generation += 1
        android?.stop()
        android = nil
        scrcpy?.stop()
        scrcpy = nil
        simInput?.stop()
        simInput = nil
        simStream?.stop()
        simStream = nil
        inputNotice = nil
        missingTool = nil
        clipboard.stop()
        engine = nil
        screenSize = nil
        dragStart = nil
        pollTask?.cancel()
        pollTask = nil
        captureSession?.stopRunning()
        captureSession = nil
        input = nil
        displayLayer.flushAndRemoveImage()
        content = .none
        frameSize = nil
        state = .idle
    }

    // MARK: Android

    private func startAndroid(_ device: Device) {
        guard let sdk = Preferences.locateSDK(), let serial = device.serial else {
            state = .failed("Android SDK not found — set path in Settings")
            return
        }
        content = .video
        let token = generation
        Task { [weak self] in
            let install = await Self.scrcpyInstall()
            guard let self, self.generation == token else { return }
            if let install {
                self.startScrcpy(sdk: sdk, serial: serial, install: install, token: token)
            } else {
                self.missingTool = .scrcpy
                self.startScreenrecord(sdk: sdk, serial: serial)
            }
        }
    }

    private static func scrcpyInstall() async -> ScrcpyInstall? {
        if let cached = cachedScrcpy, let found = cached { return found }
        // only a hit is remembered, so installing scrcpy takes effect when the mirror next starts
        return await ScrcpyInstall.locate(runner: ProcessShellRunner()).map { found in
            cachedScrcpy = .some(found)
            return found
        }
    }

    private func startScrcpy(sdk: AndroidSDK, serial: String, install: ScrcpyInstall, token: Int) {
        let session = ScrcpySession(sdk: sdk, serial: serial, install: install)
        scrcpy = session
        engine = "scrcpy"
        let layer = displayLayer
        let syncs = Preferences.syncClipboard
        if syncs { clipboard.startAndroid(session) }
        session.start(onFrame: { [weak self] frame in
            self?.present(frame)
        }, onEnd: { [weak self] message in
            Task { @MainActor in
                guard let self, self.scrcpy === session, self.generation == token else { return }
                self.clipboard.stop()
                session.stop()
                self.scrcpy = nil
                if self.state == .live {
                    self.state = .failed(message ?? "The stream ended")
                } else {
                    // scrcpy could not start (version mismatch, device refused): use the adb stream instead
                    self.startScreenrecord(sdk: sdk, serial: serial)
                }
            }
        }, onClipboard: { [weak self] text in
            guard syncs else { return }
            Task { @MainActor in self?.clipboard.receive(fromDevice: text) }
        })
    }

    private func startScreenrecord(sdk: AndroidSDK, serial: String) {
        let session = AndroidMirrorSession(sdk: sdk, serial: serial)
        android = session
        input = AndroidInput(sdk: sdk, serial: serial)
        engine = "adb"
        let layer = displayLayer
        session.start(onFrame: { [weak self] frame in
            self?.present(frame)
        }, onEnd: { [weak self] message in
            Task { @MainActor in
                guard let self, self.android === session else { return }
                self.state = .failed(message ?? "The stream ended")
            }
        })
        Task { [weak self] in
            let size = await session.screenSize()
            if self?.android === session { self?.screenSize = size }
        }
    }

    private func didReceive(width: Int, height: Int) {
        if state != .live { state = .live }
        let size = CGSize(width: width, height: height)
        if frameSize != size { frameSize = size }
    }

    // MARK: Simulator

    private func startSimulator(_ device: Device) {
        if Preferences.syncClipboard { clipboard.startSimulator(device) }
        startSimulatorInput(device)
        if let executable = SimulatorInputSession.locate() {
            startSimulatorStream(device, executable: executable)
        } else {
            startSimulatorPolling(device)
        }
    }

    /// Baguette's H.264 stream: up to 60 fps instead of a screenshot every few hundred milliseconds.
    private func startSimulatorStream(_ device: Device, executable: String) {
        let session = SimulatorMirrorSession(executable: executable, udid: device.id)
        simStream = session
        engine = "baguette"
        content = .video
        let layer = displayLayer
        let token = generation
        session.start(onFrame: { [weak self] frame in
            self?.present(frame)
        }, onEnd: { [weak self] message in
            Task { @MainActor in
                guard let self, self.simStream === session, self.generation == token else { return }
                session.stop()
                self.simStream = nil
                if self.state == .live {
                    self.state = .failed(message ?? "The stream ended")
                } else {
                    self.startSimulatorPolling(device)   // Baguette could not stream: fall back to screenshots
                }
            }
        })
    }

    private func startSimulatorPolling(_ device: Device) {
        engine = "screenshots"
        let tools = SimulatorTools(runner: ProcessShellRunner())
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    let data = try await tools.captureFrame(device)
                    if let image = NSImage(data: data) {
                        self?.show(image: image)
                        failures = 0
                    }
                } catch {
                    failures += 1
                    if failures >= 3 {
                        self?.state = .failed(ErrorMessage.friendly(error))
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Touch and keys go through Baguette; without it the simulator stays view-only.
    private func startSimulatorInput(_ device: Device) {
        guard let executable = SimulatorInputSession.locate() else {
            inputNotice = "View only. For touch and keyboard: \(OptionalTool.baguette.installCommand)"
            missingTool = .baguette
            return
        }
        inputNotice = "Preparing input…"
        let session = SimulatorInputSession(executable: executable, udid: device.id)
        let token = generation
        Task { [weak self] in
            do {
                try await session.start()
                guard let self, self.generation == token else { session.stop(); return }
                self.simInput = session
                self.inputNotice = nil
            } catch {
                session.stop()
                guard let self, self.generation == token else { return }
                self.inputNotice = "Input unavailable: \(ErrorMessage.friendly(error))"
            }
        }
    }

    func press(_ button: SimulatorInputSession.Button) {
        simInput?.press(button)
    }

    private func show(image: NSImage) {
        content = .image(image)
        frameSize = image.size
        state = .live
    }

    // MARK: Physical iOS

    private func startIOSDevice(_ device: Device) {
        // macOS exposes the screen of a USB-connected iOS device as a capture device once this is switched on
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)

        pollTask = Task { [weak self] in
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                self?.state = .failed("Allow camera access for Deckhand in System Settings → Privacy & Security")
                return
            }
            for _ in 0..<10 {
                if Task.isCancelled { return }
                if let capture = Self.captureDevice(for: device) {
                    self?.attach(capture)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self?.state = .failed("Connect the device with a USB cable and unlock it to mirror its screen")
        }
    }

    private nonisolated static func captureDevice(for device: Device) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
        return discovery.devices.first { $0.uniqueID == device.id }
    }

    private func attach(_ capture: AVCaptureDevice) {
        do {
            let session = AVCaptureSession()
            session.addInput(try AVCaptureDeviceInput(device: capture))
            captureSession = session
            content = .capture(session)
            state = .live
            Task.detached { session.startRunning() }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Input (Android)

    func press(_ key: AndroidInput.Key) {
        if let scrcpy {
            scrcpy.press(key)
        } else if let input {
            Task { try? await input.press(key) }
        }
    }

    /// Handles a key typed while the mirror has focus. Returns false when the key is not for the device.
    func handleKey(_ event: NSEvent) -> Bool {
        guard supportsInput else { return false }
        if let simInput { return handleSimulatorKey(event, simInput) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": return pasteFromMac()
            case "c": press(keyCode: AndroidKeyMap.copy)
            case "x": press(keyCode: AndroidKeyMap.cut)
            case "a": press(keyCode: AndroidKeyMap.keyA, meta: AndroidKeyMap.metaCtrl)
            default: return false
            }
            return true
        }
        if let code = AndroidKeyMap.special[event.keyCode] {
            press(keyCode: code)
            return true
        }
        guard !flags.contains(.control), let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ $0.value >= 32 && !(0xF700...0xF8FF).contains($0.value) && $0.value != 127 })
        else { return false }
        type(characters)
        return true
    }

    private func handleSimulatorKey(_ event: NSEvent, _ input: SimulatorInputSession) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch character {
            case "v":
                guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
                clipboard.noteSent(text)
                input.paste(text)
            case "c":
                input.copy()
            default:
                guard let code = SimulatorKeyMap.shortcutCode(for: character) else { return false }
                input.key(code: code, modifiers: ["command"])
            }
            return true
        }
        if let code = SimulatorKeyMap.special[event.keyCode] {
            input.key(code: code)
            return true
        }
        guard !flags.contains(.control), let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ $0.value >= 32 && !(0xF700...0xF8FF).contains($0.value) && $0.value != 127 })
        else { return false }
        if SimulatorKeyMap.isTypable(characters) {
            input.type(characters)
        } else {
            clipboard.noteSent(characters)
            input.paste(characters)   // `type` is US-ASCII only
        }
        return true
    }

    private func press(keyCode: Int, meta: Int = 0) {
        if let scrcpy {
            scrcpy.press(keyCode: keyCode, meta: meta)
        } else if let input {
            Task { try? await input.press(keyCode: keyCode) }
        }
    }

    private func type(_ text: String) {
        if let scrcpy {
            scrcpy.type(text)
        } else if let input {
            Task { try? await input.type(text) }
        }
    }

    /// Cmd+V: puts the Mac clipboard on the device and pastes it (scrcpy only).
    private func pasteFromMac() -> Bool {
        guard let scrcpy, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
        clipboard.noteSent(text)
        scrcpy.setClipboard(text, paste: true)
        return true
    }

    enum PointerPhase { case down, move, up }

    /// Points are normalised to the picture: (0, 0) top left, (1, 1) bottom right.
    func pointer(_ phase: PointerPhase, at point: CGPoint) {
        if let simInput, let size = frameSize {
            let mapped: SimulatorInputSession.Phase = switch phase {
            case .down: .down
            case .move: .move
            case .up: .up
            }
            // the point is in the picture as shown; the simulator wants it in its own, portrait one
            let native: CGPoint = switch simOrientation {
            case .portrait: point
            case .landscapeRight: CGPoint(x: 1 - point.y, y: point.x)
            case .landscapeLeft: CGPoint(x: point.y, y: 1 - point.x)
            }
            simInput.touch(mapped, x: native.x * size.width, y: native.y * size.height, width: size.width, height: size.height)
            return
        }
        if let scrcpy {
            let action: ScrcpySession.TouchAction = switch phase {
            case .down: .down
            case .move: .move
            case .up: .up
            }
            scrcpy.touch(action, x: point.x, y: point.y)
            return
        }
        switch phase {
        case .down:
            dragStart = (point, ContinuousClock.now)
        case .move:
            break
        case .up:
            guard let start = dragStart else { return }
            dragStart = nil
            finishGesture(from: start.point, to: point, duration: ContinuousClock.now - start.time)
        }
    }

    private func finishGesture(from start: CGPoint, to end: CGPoint, duration: Duration) {
        guard let input, let target = deviceSize() else { return }
        func map(_ point: CGPoint) -> (x: Int, y: Int) {
            (Int((point.x * target.width).rounded()), Int((point.y * target.height).rounded()))
        }
        let moved = hypot((end.x - start.x) * target.width, (end.y - start.y) * target.height)
        Task {
            if moved < 12 && duration < .milliseconds(450) {
                try? await input.tap(x: map(end).x, y: map(end).y)
            } else {
                try? await input.swipe(from: map(start), to: map(end), duration: max(duration, .milliseconds(80)))
            }
        }
    }

    /// Screen size in the orientation currently shown.
    private func deviceSize() -> CGSize? {
        guard let screen = screenSize else { return frameSize }
        guard let frame = frameSize else { return CGSize(width: screen.width, height: screen.height) }
        let landscape = frame.width > frame.height
        let shortSide = Double(min(screen.width, screen.height))
        let longSide = Double(max(screen.width, screen.height))
        return landscape ? CGSize(width: longSide, height: shortSide) : CGSize(width: shortSide, height: longSide)
    }
}
