import CoreMedia
import Darwin
import Foundation

/// An installed scrcpy whose bundled server Deckhand can drive directly.
public struct ScrcpyInstall: Sendable, Equatable {
    public let serverPath: String
    public let version: String

    public init(serverPath: String, version: String) {
        self.serverPath = serverPath
        self.version = version
    }

    private static let prefixes = ["/opt/homebrew", "/usr/local"]

    /// Looks for scrcpy and its server next to each other, as Homebrew lays them out.
    public static func locate(runner: any ShellRunner,
                              exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                              environment: [String: String] = ProcessInfo.processInfo.environment) async -> ScrcpyInstall? {
        for prefix in prefixes where exists("\(prefix)/bin/scrcpy") {
            let server = environment["SCRCPY_SERVER_PATH"] ?? "\(prefix)/share/scrcpy/scrcpy-server"
            guard exists(server),
                  let output = try? await runner.run("\(prefix)/bin/scrcpy", ["--version"]),
                  let version = parseVersion(output) else { continue }
            return ScrcpyInstall(serverPath: server, version: version)
        }
        return nil
    }

    static func parseVersion(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first,
              let range = line.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return String(line[range])
    }
}

/// Reads scrcpy's video socket: device name, stream meta, then length-prefixed packets.
struct ScrcpyStreamParser {
    enum ParseError: Error, Equatable {
        case unsupportedCodec(String)
        case oversizedPacket(Int)
    }

    private enum Phase { case deviceName, streamMeta, packets }

    private var buffer = Data()
    private var phase = Phase.deviceName
    private(set) var deviceName = ""
    private(set) var width = 0
    private(set) var height = 0

    private static let deviceNameLength = 64
    private static let streamMetaLength = 16
    private static let packetHeaderLength = 12
    private static let maxPacket = 32 * 1024 * 1024

    /// Returns the payload of every packet completed by `data` (the SPS/PPS packet included).
    mutating func push(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var packets: [Data] = []
        while true {
            switch phase {
            case .deviceName:
                guard buffer.count >= Self.deviceNameLength else { return packets }
                let name = buffer.prefix(Self.deviceNameLength).prefix { $0 != 0 }
                deviceName = String(decoding: name, as: UTF8.self)
                buffer.removeFirst(Self.deviceNameLength)
                phase = .streamMeta
            case .streamMeta:
                guard buffer.count >= Self.streamMetaLength else { return packets }
                let bytes = [UInt8](buffer.prefix(Self.streamMetaLength))
                let codec = String(decoding: bytes[0..<4], as: UTF8.self)
                guard codec == "h264" else { throw ParseError.unsupportedCodec(codec) }
                width = Int(Self.uint32(bytes, 8))
                height = Int(Self.uint32(bytes, 12))
                buffer.removeFirst(Self.streamMetaLength)
                phase = .packets
            case .packets:
                guard buffer.count >= Self.packetHeaderLength else { return packets }
                let header = [UInt8](buffer.prefix(Self.packetHeaderLength))
                // a session packet announces the new video size, which the device sends when it rotates:
                // its 12 bytes (flag word, width, height) have no payload
                if header[0] & 0x80 != 0 {
                    width = Int(Self.uint32(header, 4))
                    height = Int(Self.uint32(header, 8))
                    buffer.removeFirst(Self.packetHeaderLength)
                    continue
                }
                let size = Int(Self.uint32(header, 8))
                guard size <= Self.maxPacket else { throw ParseError.oversizedPacket(size) }
                guard buffer.count >= Self.packetHeaderLength + size else { return packets }
                packets.append(Data(buffer.dropFirst(Self.packetHeaderLength).prefix(size)))
                buffer.removeFirst(Self.packetHeaderLength + size)
            }
        }
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Control-socket messages, in scrcpy's big-endian wire format.
enum ScrcpyControl {
    enum TouchAction: UInt8 { case down = 0, up = 1, move = 2 }

    static func key(code: Int, action: UInt8, meta: Int = 0) -> Data {
        var data = Data([0, action])
        data.append(contentsOf: bytes(Int32(code)))
        data.append(contentsOf: bytes(Int32(0)))   // repeat
        data.append(contentsOf: bytes(Int32(meta)))
        return data
    }

    static let maxTextLength = 300

    /// Typed text, UTF-8, as the device's key character map understands it.
    static func text(_ text: String) -> Data {
        let utf8 = Array(String(text.prefix(maxTextLength)).utf8)
        return Data([1]) + Data(bytes(UInt32(utf8.count))) + Data(utf8)
    }

    static let maxClipboardLength = 256 * 1024 - 14

    /// Sets the device clipboard; `paste` also presses paste once it is set.
    static func setClipboard(_ text: String, paste: Bool, sequence: UInt64 = 0) -> Data {
        var utf8 = Array(text.utf8)
        if utf8.count > maxClipboardLength { utf8 = Array(utf8.prefix(maxClipboardLength)) }
        return Data([9]) + Data(bytes(sequence)) + Data([paste ? 1 : 0]) + Data(bytes(UInt32(utf8.count))) + Data(utf8)
    }

    /// `x`/`y` are in the video frame's pixels; `width`/`height` are that frame's size.
    static func touch(_ action: TouchAction, x: Int, y: Int, width: Int, height: Int) -> Data {
        var data = Data([2, action.rawValue])
        data.append(contentsOf: bytes(UInt64.max - 1))   // generic finger
        data.append(contentsOf: bytes(Int32(x)))
        data.append(contentsOf: bytes(Int32(y)))
        data.append(contentsOf: bytes(UInt16(width)))
        data.append(contentsOf: bytes(UInt16(height)))
        data.append(contentsOf: bytes(action == .up ? UInt16(0) : UInt16(0xffff)))   // pressure
        data.append(contentsOf: bytes(Int32(0)))   // action button
        data.append(contentsOf: bytes(Int32(0)))   // buttons
        return data
    }

    private static func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
}

/// What the device sends back on the control socket.
enum ScrcpyDeviceMessage: Equatable {
    case clipboard(String)
    case clipboardAck(UInt64)
    case other
}

struct ScrcpyDeviceMessageParser {
    private var buffer = Data()

    mutating func push(_ data: Data) -> [ScrcpyDeviceMessage] {
        buffer.append(data)
        var messages: [ScrcpyDeviceMessage] = []
        while let first = buffer.first {
            let bytes = [UInt8](buffer)
            switch first {
            case 0:   // clipboard: length u32, text
                guard bytes.count >= 5 else { return messages }
                let length = Int(bytes[1..<5].reduce(0) { $0 << 8 | UInt32($1) })
                guard length <= 1 << 22 else { buffer.removeAll(); return messages }
                guard bytes.count >= 5 + length else { return messages }
                messages.append(.clipboard(String(decoding: bytes[5..<(5 + length)], as: UTF8.self)))
                buffer.removeFirst(5 + length)
            case 1:   // clipboard acknowledged: sequence u64
                guard bytes.count >= 9 else { return messages }
                messages.append(.clipboardAck(bytes[1..<9].reduce(0) { $0 << 8 | UInt64($1) }))
                buffer.removeFirst(9)
            case 2:   // HID output: id u16, size u16, data
                guard bytes.count >= 5 else { return messages }
                let size = Int(bytes[3]) << 8 | Int(bytes[4])
                guard bytes.count >= 5 + size else { return messages }
                messages.append(.other)
                buffer.removeFirst(5 + size)
            default:   // unknown framing: nothing after it can be trusted
                buffer.removeAll()
                return messages
            }
        }
        return messages
    }
}

final class TCPConnection: @unchecked Sendable {
    private var descriptor: Int32
    private let lock = NSLock()

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func connect(port: UInt16) -> TCPConnection? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return TCPConnection(descriptor: descriptor)
    }

    /// Blocks for up to `max` bytes; empty at end of stream.
    func read(max: Int) -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        let count = Darwin.read(descriptor, &buffer, max)
        return count > 0 ? Data(buffer.prefix(count)) : Data()
    }

    func write(_ data: Data) {
        lock.withLock {
            guard descriptor >= 0 else { return }
            data.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let count = Darwin.write(descriptor, raw.baseAddress! + sent, raw.count - sent)
                    if count <= 0 { return }
                    sent += count
                }
            }
        }
    }

    func close() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    static func freePort() -> UInt16? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return named == 0 ? UInt16(bigEndian: address.sin_port) : nil
    }
}

/// Low-latency mirror and input for an Android device through scrcpy's server, without scrcpy's own window.
public final class ScrcpySession: @unchecked Sendable {
    private let runner: any ShellRunner
    private let streamer: any ByteStreaming
    private let sdk: AndroidSDK
    private let serial: String
    private let install: ScrcpyInstall
    private let maxSize: Int
    private let bitRate: Int
    private let lock = NSLock()
    private var setupTask: Task<Void, Never>?
    private var serverTask: Task<Void, Never>?
    private var video: TCPConnection?
    private var control: TCPConnection?
    private var forwardedPort: UInt16?
    private var frameWidth = 0
    private var frameHeight = 0
    private var stopped = false

    private static let remoteServer = "/data/local/tmp/deckhand-scrcpy-server.jar"

    public init(streamer: any ByteStreaming = ProcessByteStreamer(), runner: any ShellRunner = ProcessShellRunner(),
                sdk: AndroidSDK, serial: String, install: ScrcpyInstall, maxSize: Int = 1600, bitRate: Int = 12_000_000) {
        self.streamer = streamer
        self.runner = runner
        self.sdk = sdk
        self.serial = serial
        self.install = install
        self.maxSize = maxSize
        self.bitRate = bitRate
    }

    /// `onEnd` gets a message when the session could not start or died; nil after a clean `stop()`.
    public func start(onFrame: @escaping @Sendable (VideoFrame) -> Void,
                      onEnd: @escaping @Sendable (String?) -> Void,
                      onClipboard: (@Sendable (String) -> Void)? = nil) {
        lock.withLock {
            stopped = false
            setupTask = Task { [self] in
                do {
                    try await launchServer()
                    let thread = Thread { [self] in readLoop(onFrame: onFrame, onEnd: onEnd, onClipboard: onClipboard) }
                    thread.name = "deckhand.scrcpy.video"
                    thread.start()
                } catch {
                    if !Task.isCancelled { onEnd(ErrorMessage.friendly(error)) }
                }
            }
        }
    }

    public func stop() {
        let (port, tasks, sockets): (UInt16?, [Task<Void, Never>?], [TCPConnection?]) = lock.withLock {
            stopped = true
            defer { forwardedPort = nil }
            return (forwardedPort, [setupTask, serverTask], [video, control])
        }
        tasks.forEach { $0?.cancel() }
        sockets.forEach { $0?.close() }
        if let port {
            Task { _ = try? await runner.run(sdk.adbPath, ["-s", serial, "forward", "--remove", "tcp:\(port)"]) }
        }
    }

    // MARK: Input

    public func touch(_ action: TouchAction, x: Double, y: Double) {
        let (control, width, height) = lock.withLock { (self.control, self.frameWidth, self.frameHeight) }
        guard let control, width > 0, height > 0 else { return }
        let message = ScrcpyControl.touch(
            ScrcpyControl.TouchAction(rawValue: action.rawValue) ?? .move,
            x: min(max(Int(x * Double(width)), 0), width - 1), y: min(max(Int(y * Double(height)), 0), height - 1),
            width: width, height: height)
        control.write(message)
    }

    public enum TouchAction: UInt8, Sendable { case down = 0, up = 1, move = 2 }

    public func press(_ key: AndroidInput.Key) {
        press(keyCode: key.rawValue)
    }

    /// An Android keycode (`KEYCODE_*`), optionally with meta state such as Ctrl (0x1000).
    public func press(keyCode: Int, meta: Int = 0) {
        guard let control = lock.withLock({ control }) else { return }
        control.write(ScrcpyControl.key(code: keyCode, action: 0, meta: meta))
        control.write(ScrcpyControl.key(code: keyCode, action: 1, meta: meta))
    }

    public func type(_ text: String) {
        guard !text.isEmpty, let control = lock.withLock({ control }) else { return }
        var remaining = Substring(text)
        while !remaining.isEmpty {
            let chunk = remaining.prefix(ScrcpyControl.maxTextLength)
            control.write(ScrcpyControl.text(String(chunk)))
            remaining = remaining.dropFirst(chunk.count)
        }
    }

    public func setClipboard(_ text: String, paste: Bool = false) {
        lock.withLock { control }?.write(ScrcpyControl.setClipboard(text, paste: paste))
    }

    // MARK: Setup

    private func launchServer() async throws {
        guard let port = TCPConnection.freePort() else {
            throw ShellError(command: "scrcpy", exitCode: 1, stderr: "No free local port")
        }
        let scid = String(UInt32.random(in: 1...0x7fff_ffff), radix: 16)
        try await runner.run(sdk.adbPath, ["-s", serial, "push", install.serverPath, Self.remoteServer])
        try await runner.run(sdk.adbPath, ["-s", serial, "forward", "tcp:\(port)", "localabstract:scrcpy_\(scid)"])
        let command = "CLASSPATH=\(Self.remoteServer) app_process / com.genymobile.scrcpy.Server \(install.version) "
            + "scid=\(scid) log_level=warn audio=false control=true max_size=\(maxSize) video_bit_rate=\(bitRate) "
            + "max_fps=60 tunnel_forward=true cleanup=false clipboard_autosync=true"
        let stream = streamer.stream(sdk.adbPath, ["-s", serial, "shell", command])
        lock.withLock {
            forwardedPort = port
            serverTask = Task { do { for try await _ in stream {} } catch {} }
        }
    }

    private func connectSockets(port: UInt16) -> (TCPConnection, TCPConnection)? {
        // the forward accepts connections before the server listens; only a dummy byte proves it is ready
        for _ in 0..<50 {
            if lock.withLock({ stopped }) { return nil }
            if let video = TCPConnection.connect(port: port) {
                if video.read(max: 1).count == 1, let control = TCPConnection.connect(port: port) {
                    return (video, control)
                }
                video.close()
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private func readLoop(onFrame: @escaping @Sendable (VideoFrame) -> Void,
                          onEnd: @escaping @Sendable (String?) -> Void,
                          onClipboard: (@Sendable (String) -> Void)?) {
        guard let port = lock.withLock({ forwardedPort }), let (video, control) = connectSockets(port: port) else {
            if !lock.withLock({ stopped }) { onEnd("scrcpy did not start on the device") }
            return
        }
        lock.withLock {
            self.video = video
            self.control = control
        }
        let deviceMessages = Thread {
            var parser = ScrcpyDeviceMessageParser()
            while true {
                let chunk = control.read(max: 64 * 1024)
                if chunk.isEmpty { return }
                for case .clipboard(let text) in parser.push(chunk) { onClipboard?(text) }
            }
        }
        deviceMessages.name = "deckhand.scrcpy.device"
        deviceMessages.start()

        var parser = ScrcpyStreamParser()
        var builder = H264FrameBuilder()
        var produced = false
        do {
            while true {
                let chunk = video.read(max: 256 * 1024)
                if chunk.isEmpty { break }
                for packet in try parser.push(chunk) {
                    var split = AnnexBParser()
                    // a packet is complete, so its last unit needs no following start code
                    let units = split.push(packet) + (split.flush().map { [$0] } ?? [])
                    for unit in units {
                        guard let frame = builder.push(unit) else { continue }
                        produced = true
                        lock.withLock {
                            frameWidth = frame.width
                            frameHeight = frame.height
                        }
                        onFrame(frame)
                    }
                }
            }
        } catch {
            onEnd("Unsupported scrcpy stream: \(error)")
            return
        }
        if lock.withLock({ stopped }) { return }
        onEnd(produced ? "The device stopped streaming its screen" : "scrcpy did not deliver any picture")
    }
}
