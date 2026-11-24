import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import DeckhandCore

// MARK: Test upstream server

private final class UpstreamServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequestHead, Data) -> (status: Int, headers: [HTTPHeader], body: Data)
    private var listener: Int32 = -1
    private(set) var port = 0
    private let handler: Handler
    private let tls: CertificateAuthority?
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int { lock.withLock { requests } }

    init(tls: CertificateAuthority? = nil, handler: @escaping Handler) {
        self.tls = tls
        self.handler = handler
    }

    func start() throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else { throw ChannelError("test server bind failed") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
        let descriptor = listener
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(descriptor, nil, nil)
                if client < 0 { return }
                Thread.detachNewThread { [self] in serve(SocketChannel(descriptor: client)) }
            }
        }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    private func serve(_ socket: SocketChannel) {
        var channel: any ByteChannel = socket
        if let tls {
            guard let root = try? tls.certificate(),
                  let secure = try? TLSChannel.accept(socket, fallbackName: "localhost", identity: { try tls.identity(for: $0) }, root: root)
            else { return }
            channel = secure
        }
        defer { channel.close() }
        let reader = ByteReader(channel)
        while let data = try? reader.read(through: HTTPProtocol.crlfcrlf), let head = try? HTTPProtocol.parseRequestHead(data) {
            let capture = BodyCapture(limit: 1_000_000)
            guard (try? BodyRelay.relay(HTTPProtocol.framing(forRequest: head), from: reader, to: nil, capture: capture)) != nil else { return }
            lock.withLock { requests += 1 }
            let response = handler(head, capture.data)
            var text = "HTTP/1.1 \(response.status) OK\r\n"
            for header in response.headers { text += "\(header.name): \(header.value)\r\n" }
            if response.headers.value(for: "Content-Length") == nil, response.headers.value(for: "Transfer-Encoding") == nil {
                text += "Content-Length: \(response.body.count)\r\n"
            }
            text += "\r\n"
            do { try channel.write(Data(text.utf8) + response.body) } catch { return }
        }
    }
}

// MARK: Helpers

private final class FlowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [Int: HTTPFlow] = [:]

    func record(_ flow: HTTPFlow) { lock.withLock { latest[flow.id] = flow } }
    var flows: [HTTPFlow] { lock.withLock { latest.values.sorted { $0.id < $1.id } } }

    func waitForFlows(_ count: Int, where condition: (HTTPFlow) -> Bool = { $0.state == .complete || $0.state == .failed }) async -> [HTTPFlow] {
        for _ in 0..<100 {
            let current = flows
            if current.count >= count, current.prefix(count).allSatisfy(condition) { return current }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return flows
    }
}

private struct NoAttribution: ClientAttributing {
    func client(forLocalPort port: Int) -> ClientInfo { ClientInfo(app: "TestApp", pid: 1) }
}

private func makeAuthority() throws -> CertificateAuthority {
    try CertificateAuthority(directory: NSTemporaryDirectory() + "bb-proxy-ca-\(UUID().uuidString)")
}

private func session(proxyPort: Int, delegate: URLSessionDelegate? = nil) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": proxyPort
    ]
    configuration.timeoutIntervalForRequest = 10
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
}

/// Runs the system curl through the proxy: the exact client a developer would point at it.
private func curl(proxyPort: Int, url: String, caFile: String? = nil, timeout: Int = 10) async throws -> (exit: Int32, body: String, code: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    var arguments = ["-sS", "-m", String(timeout), "-x", "http://127.0.0.1:\(proxyPort)", "-w", "\n%{http_code}", "--noproxy", ""]
    if let caFile { arguments += ["--cacert", caFile] }
    process.arguments = arguments + [url]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    let parts = text.components(separatedBy: "\n")
    return (process.terminationStatus, parts.dropLast().joined(separator: "\n"), parts.last ?? "")
}

private func startProxy(_ authority: CertificateAuthority, options: ProxyOptions = ProxyOptions(),
                         recorder: FlowRecorder) throws -> ProxyServer {
    var options = options
    options.port = 0
    let proxy = ProxyServer(authority: authority, attribution: NoAttribution(), options: options) { recorder.record($0) }
    try proxy.start()
    return proxy
}

private let jsonHandler: UpstreamServer.Handler = { head, body in
    let payload = #"{"path":"\#(head.target)","method":"\#(head.method)","received":\#(body.count)}"#
    return (200, [HTTPHeader("Content-Type", "application/json"), HTTPHeader("X-Test", "yes")], Data(payload.utf8))
}

// MARK: Tests

@Test func plainHTTPIsForwardedAndRecorded() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let upstream = UpstreamServer(handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)
    defer { proxy.stop() }

    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(upstream.port)/items?page=2")!)
    request.httpMethod = "POST"
    request.httpBody = Data("hello".utf8)
    request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await session(proxyPort: proxy.port).data(for: request)

    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Test") == "yes")
    #expect(String(decoding: data, as: UTF8.self) == #"{"path":"/items?page=2","method":"POST","received":5}"#)

    let flows = await recorder.waitForFlows(1)
    let flow = try #require(flows.first)
    #expect(flow.state == .complete)
    #expect(flow.method == "POST")
    #expect(flow.scheme == "http")
    #expect(flow.host == "127.0.0.1" && flow.port == upstream.port)
    #expect(flow.path == "/items?page=2")
    #expect(flow.status == 200)
    #expect(flow.requestBody == Data("hello".utf8))
    #expect(flow.responseMimeType == "application/json")
    #expect(String(decoding: flow.responseBody, as: UTF8.self).contains("\"received\":5"))
    #expect(flow.requestHeaders.value(for: "Content-Type") == "text/plain")
    #expect(flow.client.app == "TestApp")
    #expect(flow.duration != nil)
}

@Test func httpsIsDecryptedWithTheDeckhandCertificateAndRecorded() async throws {
    let authority = try makeAuthority()
    let upstreamAuthority = try makeAuthority()
    defer {
        try? FileManager.default.removeItem(atPath: authority.directory)
        try? FileManager.default.removeItem(atPath: upstreamAuthority.directory)
    }
    let upstream = UpstreamServer(tls: upstreamAuthority, handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    var options = ProxyOptions()
    options.verifyUpstream = false   // the test server is signed by a private CA
    let proxy = try startProxy(authority, options: options, recorder: recorder)
    defer { proxy.stop() }

    let result = try await curl(proxyPort: proxy.port, url: "https://localhost:\(upstream.port)/secure", caFile: authority.certificatePath)
    #expect(result.exit == 0)
    #expect(result.code == "200")
    #expect(result.body.contains("\"path\":\"/secure\""))

    let flows = await recorder.waitForFlows(1) { $0.state == .complete && !$0.isTunnel }
    let decrypted = try #require(flows.first { $0.method == "GET" })
    #expect(decrypted.scheme == "https")
    #expect(decrypted.host == "localhost")
    #expect(decrypted.path == "/secure")
    #expect(decrypted.status == 200)
    #expect(decrypted.urlString == "https://localhost:\(upstream.port)/secure")
}

@Test func theProxyChecksTheRealServersCertificate() async throws {
    let authority = try makeAuthority()
    let upstreamAuthority = try makeAuthority()
    defer {
        try? FileManager.default.removeItem(atPath: authority.directory)
        try? FileManager.default.removeItem(atPath: upstreamAuthority.directory)
    }
    let upstream = UpstreamServer(tls: upstreamAuthority, handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)   // verifyUpstream stays on
    defer { proxy.stop() }

    let result = try await curl(proxyPort: proxy.port, url: "https://localhost:\(upstream.port)/", caFile: authority.certificatePath)
    #expect(result.code == "502")   // the proxy refused the untrusted server
    #expect(result.body.contains("not trusted"))
    let flows = await recorder.waitForFlows(1) { $0.state == .failed }
    #expect(flows.first { $0.state == .failed }?.error?.contains("not trusted") == true)
}

@Test func anAppThatDoesNotTrustTheCertificateProducesAFailedConnectionFlow() async throws {
    let authority = try makeAuthority()
    let upstreamAuthority = try makeAuthority()
    defer {
        try? FileManager.default.removeItem(atPath: authority.directory)
        try? FileManager.default.removeItem(atPath: upstreamAuthority.directory)
    }
    let upstream = UpstreamServer(tls: upstreamAuthority, handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    var options = ProxyOptions()
    options.verifyUpstream = false
    let proxy = try startProxy(authority, options: options, recorder: recorder)
    defer { proxy.stop() }

    // the default trust store does not know the Deckhand root
    let result = try await curl(proxyPort: proxy.port, url: "https://localhost:\(upstream.port)/")
    #expect(result.exit != 0)
    let flows = await recorder.waitForFlows(1) { $0.state == .failed }
    let failed = try #require(flows.first)
    #expect(failed.method == "CONNECT")
    #expect(failed.error?.contains("TLS handshake") == true)
}

@Test func keepAliveConnectionsCarryManyRequestsAndEachIsRecorded() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let upstream = UpstreamServer(handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)
    defer { proxy.stop() }
    let client = session(proxyPort: proxy.port)
    for index in 1...3 {
        _ = try await client.data(from: URL(string: "http://127.0.0.1:\(upstream.port)/n\(index)")!)
    }
    let flows = await recorder.waitForFlows(3)
    #expect(flows.map(\.path) == ["/n1", "/n2", "/n3"])
    #expect(upstream.requestCount == 3)
}

@Test func anUnreachableServerBecomesABadGatewayAndAFailedFlow() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)
    defer { proxy.stop() }
    let (data, response) = try await session(proxyPort: proxy.port).data(from: URL(string: "http://127.0.0.1:1/")!)
    #expect((response as? HTTPURLResponse)?.statusCode == 502)
    #expect(String(decoding: data, as: UTF8.self).contains("Deckhand proxy"))
    let flows = await recorder.waitForFlows(1)
    #expect(flows.first?.state == .failed)
}

@Test func excludedHostsAreTunnelledWithoutDecryption() async throws {
    let authority = try makeAuthority()
    let upstreamAuthority = try makeAuthority()
    defer {
        try? FileManager.default.removeItem(atPath: authority.directory)
        try? FileManager.default.removeItem(atPath: upstreamAuthority.directory)
    }
    let upstream = UpstreamServer(tls: upstreamAuthority, handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    var options = ProxyOptions()
    options.bypassHosts = ["localhost"]
    let proxy = try startProxy(authority, options: options, recorder: recorder)
    defer { proxy.stop() }

    // the app talks to the real server directly, so it trusts the real server's CA
    // under the load of the whole suite one connection can be reset: a second try tells that from a real failure
    var result = try await curl(proxyPort: proxy.port, url: "https://localhost:\(upstream.port)/direct", caFile: upstreamAuthority.certificatePath)
    if result.exit != 0 {
        result = try await curl(proxyPort: proxy.port, url: "https://localhost:\(upstream.port)/direct", caFile: upstreamAuthority.certificatePath)
    }
    #expect(result.code == "200")
    #expect(result.body.contains("/direct"))
    let flows = await recorder.waitForFlows(1) { $0.isTunnel && $0.state == .complete || $0.state == .failed }
    let tunnel = try #require(flows.first)
    #expect(tunnel.isTunnel)
    #expect(tunnel.method == "CONNECT")
    #expect(tunnel.path.contains("excluded"))
}

@Test func bodiesAreCappedForDisplayButStillRelayedWhole() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let big = Data(repeating: 0x41, count: 300_000)
    let upstream = UpstreamServer { _, _ in (200, [HTTPHeader("Content-Type", "application/octet-stream")], big) }
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    var options = ProxyOptions()
    options.bodyLimit = 1000
    let proxy = try startProxy(authority, options: options, recorder: recorder)
    defer { proxy.stop() }
    let (data, _) = try await session(proxyPort: proxy.port).data(from: URL(string: "http://127.0.0.1:\(upstream.port)/big")!)
    #expect(data.count == 300_000)
    let flow = try #require(await recorder.waitForFlows(1).first)
    #expect(flow.responseBody.count == 1000)
    #expect(flow.responseBodySize == 300_000)
    #expect(flow.isResponseBodyTruncated)
}

@Test func chunkedResponsesAreDecodedForDisplayAndRelayedIntact() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let chunked = Data("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
    let upstream = UpstreamServer { _, _ in (200, [HTTPHeader("Transfer-Encoding", "chunked"), HTTPHeader("Content-Type", "text/plain")], chunked) }
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)
    defer { proxy.stop() }
    let (data, _) = try await session(proxyPort: proxy.port).data(from: URL(string: "http://127.0.0.1:\(upstream.port)/stream")!)
    #expect(String(decoding: data, as: UTF8.self) == "hello world")
    let flow = try #require(await recorder.waitForFlows(1).first)
    #expect(String(decoding: flow.responseBody, as: UTF8.self) == "hello world")
}

@Test func clientsThatAreNotInspectedAreForwardedWithoutBeingRecorded() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let upstream = UpstreamServer(handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    var options = ProxyOptions()
    options.inspects = { $0.app == "SomeSimulatorApp" }   // the test client is "TestApp"
    let proxy = try startProxy(authority, options: options, recorder: recorder)
    defer { proxy.stop() }
    let (data, response) = try await session(proxyPort: proxy.port).data(from: URL(string: "http://127.0.0.1:\(upstream.port)/quiet")!)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("/quiet"))
    try await Task.sleep(for: .milliseconds(300))
    #expect(recorder.flows.isEmpty)
}

@Test func mobileClientsAreRecognisedByTheirDeviceOrToolchain() {
    let inspect = ProxyOptions.inspectsMobile
    #expect(inspect(ClientInfo(app: "MyApp", deviceId: "UDID")))
    #expect(inspect(ClientInfo(app: "Android (adb)")))
    #expect(inspect(ClientInfo(app: "Android emulator")))
    #expect(inspect(ClientInfo(app: "Device 192.168.1.20", remoteAddress: "192.168.1.20")))
    #expect(!inspect(ClientInfo(app: "Slack")))
    #expect(ProxyOptions().bypasses("gateway.icloud.com") && ProxyOptions().bypasses("apple.com"))
    #expect(!ProxyOptions().bypasses("example.com"))
}

@Test func simulatorDevicesAreFoundFromAProcessArgumentVector() {
    let args = ["/Library/Developer/CoreSimulator/Volumes/iOS/launchd_sim",
                "/Users/me/Library/Developer/CoreSimulator/Devices/1EB213BB-A1D3-4AF1-A605-811C95037A68/data/var/run/launchd_bootstrap.plist"]
    #expect(LsofAttribution.udid(inArguments: args) == "1EB213BB-A1D3-4AF1-A605-811C95037A68")
    #expect(LsofAttribution.udid(inArguments: ["/usr/bin/curl", "-x", "/some/Devices/1EB213BB-A1D3-4AF1-A605-811C95037A68/x"]) == nil)
    #expect(LsofAttribution.arguments(of: getpid()).first?.isEmpty == false)   // this very process, through sysctl
    #expect(LsofAttribution.simulatorUDID(ofProcess: Int(getpid())) == nil)
}

@Test func theProxyServesTheCertificateToPhonesAndIsNotRecorded() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)
    defer { proxy.stop() }
    // a phone that typed the proxy's own address, and one that went through the proxy to deckhand.proxy
    for url in ["http://127.0.0.1:\(proxy.port)/ca.crt", "http://deckhand.proxy/ca.crt"] {
        let result = try await curl(proxyPort: proxy.port, url: url)
        #expect(result.code == "200")
        #expect(result.body.hasPrefix("-----BEGIN CERTIFICATE-----"))
    }
    let page = try await curl(proxyPort: proxy.port, url: "http://deckhand.proxy/")
    #expect(page.body.contains("Download the certificate"))
    try await Task.sleep(for: .milliseconds(200))
    #expect(recorder.flows.isEmpty)
}

@Test func aPortOfZeroPicksAFreePortAndABusyOneIsReported() throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    var options = ProxyOptions()
    options.port = 0
    let first = ProxyServer(authority: authority, attribution: NoAttribution(), options: options) { _ in }
    try first.start()
    defer { first.stop() }
    #expect(first.port > 0)
    options.port = first.port
    let second = ProxyServer(authority: authority, attribution: NoAttribution(), options: options) { _ in }
    #expect(throws: ProxyError.self) { try second.start() }
}

@Test func localAddressesAreIPv4Numbers() {
    for address in LocalNetwork.ipv4Addresses() {
        #expect(address.split(separator: ".").count == 4 && !address.hasPrefix("127."))
    }
}

@Test func helperAppIsDrivenThroughItsActivity() {
    let watch = DeviceProxySetup.helperArguments("watch")
    #expect(watch.starts(with: ["shell", "am", "start", "-n", "com.deckhand.helper/.MainActivity"]))
    #expect(watch.contains("watch") && watch.contains("8899") && watch.contains("quiet"))
    #expect(DeviceProxySetup.helperArguments("stop").contains("stop"))
}

@Test func thePingPageAnswersTheHelper() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let proxy = try startProxy(authority, recorder: FlowRecorder())
    defer { proxy.stop() }
    let result = try await curl(proxyPort: proxy.port, url: "http://deckhand.proxy/ping")
    #expect(result.code == "200" && result.body == "Deckhand")
}

@Test func aHostWhoseClientRejectedTheCertificateIsThenTunnelled() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let upstream = UpstreamServer(handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)
    defer { proxy.stop() }
    // curl without the Deckhand certificate rejects it, as an app that ignores the user certificate store does
    let first = try await curl(proxyPort: proxy.port, url: "https://localhost:\(upstream.port)/x")
    #expect(first.exit != 0)
    try await Task.sleep(for: .milliseconds(400))
    #expect(recorder.flows.contains { $0.state == .failed })
    // the next attempt is not decrypted: it reaches the server (which does not speak TLS here, so it still fails) and is shown as a tunnel
    _ = try? await curl(proxyPort: proxy.port, url: "https://localhost:\(upstream.port)/x", timeout: 1)
    try await Task.sleep(for: .milliseconds(400))
    #expect(recorder.flows.contains { $0.isTunnel && $0.path.contains("does not trust") })
    proxy.forgetPassedThroughHosts()
}

// MARK: Android trust

private func trustSetup(_ runner: MockShellRunner) throws -> (DeviceProxySetup, CertificateAuthority, Device) {
    let authority = try makeAuthority()
    let setup = DeviceProxySetup(runner: runner, sdk: AndroidSDK(root: "/sdk"), authority: authority)
    let device = Device(id: "emu", name: "Emu", platform: .android, osVersion: "16", state: .running, serial: "emulator-5554")
    return (setup, authority, device)
}

@Test func androidTrustIsSystemWhenTheCertificateIsInTheSystemStore() async throws {
    let runner = MockShellRunner()
    let (setup, authority, device) = try trustSetup(runner)
    let pem = try #require(FileManager.default.contents(atPath: authority.certificatePath))
    let digest = SHA256.hash(data: pem).map { String(format: "%02x", $0) }.joined()
    runner.responses["/sdk/platform-tools/adb -s emulator-5554 shell getprop ro.build.version.sdk"] = .success("36")
    // the name of the certificate in the store is its subject hash
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = ["x509", "-inform", "PEM", "-subject_hash_old", "-noout", "-in", authority.certificatePath]
    let out = Pipe(); process.standardOutput = out
    try process.run(); process.waitUntilExit()
    let name = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    runner.responses["/sdk/platform-tools/adb -s emulator-5554 shell sha256sum /system/etc/security/cacerts/\(name).0"] = .success("\(digest)  /system/etc/security/cacerts/\(name).0")
    #expect(await setup.androidTrust(on: device) == .system)
}

@Test func androidTrustIsRootableOnADebuggableBuildAndLockedOnAProductionOne() async throws {
    for (debuggable, expected) in [("1", AndroidTrust.rootable), ("0", .locked)] {
        let runner = MockShellRunner()
        let (setup, _, device) = try trustSetup(runner)
        runner.responses["/sdk/platform-tools/adb -s emulator-5554 shell getprop ro.build.version.sdk"] = .success("36")
        runner.responses["/sdk/platform-tools/adb -s emulator-5554 shell getprop ro.debuggable"] = .success(debuggable + "\n")
        #expect(await setup.androidTrust(on: device) == expected)
    }
}

@Test func androidTrustIsUnknownWithoutADevice() async throws {
    let runner = MockShellRunner()
    let (setup, _, device) = try trustSetup(runner)
    runner.responses["/sdk/platform-tools/adb -s emulator-5554 shell getprop ro.build.version.sdk"] = .failure(ShellError(command: "adb", exitCode: 1, stderr: "offline"))
    #expect(await setup.androidTrust(on: device) == nil)
}

@Test func theInjectionScriptBindsTheCertificateWhereAppsReadIt() throws {
    let script = DeviceProxySetup.injectionScript(hash: "abcd1234", remote: "/data/local/tmp/abcd1234.0")
    #expect(script.contains("cp /data/local/tmp/abcd1234.0 $STORE/abcd1234.0"))
    // new apps inherit the zygote's mounts, running apps need their own
    #expect(script.contains("nsenter --mount=/proc/$Z/ns/mnt") && script.contains("nsenter --mount=/proc/$P/ns/mnt"))
    #expect(script.contains("test -f $APEX/abcd1234.0"))
    #expect(script.hasSuffix("echo \(DeviceProxySetup.certificateMarker)"))
    if let path = ProcessInfo.processInfo.environment["DECKHAND_DUMP_SCRIPT"] { try script.write(toFile: path, atomically: true, encoding: .utf8) }
}

@Test func androidTrustIgnoresASystemStoreThatAppsDoNotSee() async throws {
    let runner = MockShellRunner()
    let (setup, authority, device) = try trustSetup(runner)
    let pem = try #require(FileManager.default.contents(atPath: authority.certificatePath))
    let digest = SHA256.hash(data: pem).map { String(format: "%02x", $0) }.joined()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = ["x509", "-inform", "PEM", "-subject_hash_old", "-noout", "-in", authority.certificatePath]
    let out = Pipe(); process.standardOutput = out
    try process.run(); process.waitUntilExit()
    let name = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let adb = "/sdk/platform-tools/adb -s emulator-5554 shell "
    runner.responses[adb + "getprop ro.build.version.sdk"] = .success("36")
    runner.responses[adb + "sha256sum /system/etc/security/cacerts/\(name).0"] = .success("\(digest)  x")
    // Android 14 and later read the APEX copy, which does not have it
    runner.responses[adb + "[ -d /apex/com.android.conscrypt/cacerts ] && [ ! -f /apex/com.android.conscrypt/cacerts/\(name).0 ] && echo MISSING"] = .success("MISSING\n")
    runner.responses[adb + "getprop ro.debuggable"] = .success("1\n")
    #expect(await setup.androidTrust(on: device) == .rootable)
}

@Test func theBundledHelperVersionMatchesItsGradleVersionCode() throws {
    let gradle = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("DeckhandHelper/app/build.gradle.kts")
    let text = try String(contentsOf: gradle, encoding: .utf8)
    let line = try #require(text.split(separator: "\n").first { $0.contains("versionCode") })
    #expect(line.contains("= \(DeviceProxySetup.helperVersion)"))
}

// MARK: Capture follows the device

@MainActor
@Test func capturingStopsWhenTheCapturedDeviceStops() async throws {
    let runner = MockShellRunner()
    let model = NetworkViewModel(runner: runner, makeAuthority: { try makeAuthority() }, locateSDK: { nil })
    let running = Device(id: "sim", name: "Sim", platform: .ios, osVersion: "26", state: .running)
    await model.select(running)
    await model.start(routeMac: false)
    #expect(model.isRunning)
    await model.deviceListChanged([running])
    #expect(model.isRunning)
    await model.deviceListChanged([running.withState(.stopped)])
    #expect(!model.isRunning)
    #expect(model.setupMessage?.contains("stopped") == true)
}

@MainActor
@Test func capturingWithADeviceThatNeverStartedIsLeftAlone() async throws {
    let model = NetworkViewModel(runner: MockShellRunner(), makeAuthority: { try makeAuthority() }, locateSDK: { nil })
    let stopped = Device(id: "sim", name: "Sim", platform: .ios, osVersion: "26", state: .stopped)
    await model.select(stopped)
    await model.start(routeMac: false)
    await model.deviceListChanged([stopped])
    #expect(model.isRunning)
    await model.stop()
}

// MARK: Network conditions

private let bigHandler: UpstreamServer.Handler = { _, _ in
    (200, [HTTPHeader("Content-Type", "application/octet-stream")], Data(repeating: 7, count: 16 * 1024))
}

private func seconds(_ work: () async throws -> Void) async rethrows -> TimeInterval {
    let start = Date()
    try await work()
    return Date().timeIntervalSince(start)
}

@Test func latencyIsAddedToEachRequest() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let upstream = UpstreamServer(handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let proxy = try startProxy(authority, recorder: FlowRecorder())
    defer { proxy.stop() }
    let url = "http://127.0.0.1:\(upstream.port)/x"

    let normal = try await seconds { _ = try await curl(proxyPort: proxy.port, url: url) }
    proxy.conditions = NetworkConditions(name: "slow", latencyMs: 600)
    let slow = try await seconds { _ = try await curl(proxyPort: proxy.port, url: url) }
    #expect(slow - normal > 0.5)
}

@Test func downloadSpeedIsLimitedAndLiftedAgain() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let upstream = UpstreamServer(handler: bigHandler)
    try upstream.start()
    defer { upstream.stop() }
    let proxy = try startProxy(authority, recorder: FlowRecorder())
    defer { proxy.stop() }
    let url = "http://127.0.0.1:\(upstream.port)/big"

    // 16 KB at 160 kbps is about 0.8 s
    proxy.conditions = NetworkConditions(name: "slow", downKbps: 160)
    let slow = try await seconds { _ = try await curl(proxyPort: proxy.port, url: url) }
    #expect(slow > 0.7)
    proxy.conditions = .online
    let fast = try await seconds { _ = try await curl(proxyPort: proxy.port, url: url) }
    #expect(slow - fast > 0.4)   // relative: an absolute limit depends on the machine
}

@Test func offlineFailsConnectionsAndIsRecorded() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let upstream = UpstreamServer(handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)
    defer { proxy.stop() }
    proxy.conditions = .offlineProfile

    let result = try await curl(proxyPort: proxy.port, url: "http://127.0.0.1:\(upstream.port)/x")
    #expect(result.exit != 0)
    #expect(recorder.flows.contains { $0.state == .failed && $0.error?.contains("Offline") == true })
}

@Test func conditionsPresetsDescribeThemselves() {
    #expect(NetworkConditions.presets.first == .online)
    #expect(NetworkConditions.presets.last?.offline == true)
    let threeG = NetworkConditions.presets.first { $0.name == "3G" }
    #expect(threeG?.summary == "780 kbps down, 330 kbps up, 100 ms")
    #expect(NetworkConditions(name: "x", downKbps: 40_000).summary == "40 Mbps down, unlimited up")
    #expect(!NetworkConditions.online.isLimited)
}

@MainActor
@Test func conditionsGoToTheProxyForSimulatorsAndToTheEmulatorForAndroid() async throws {
    let runner = MockShellRunner()
    let model = NetworkViewModel(runner: runner, makeAuthority: { try makeAuthority() }, locateSDK: { AndroidSDK(root: "/sdk") })
    let sim = Device(id: "sim", name: "Sim", platform: .ios, osVersion: "26", state: .running)
    let avd = Device(id: "avd", name: "Pixel", platform: .android, osVersion: "API 36", state: .running, serial: "emulator-5554")
    let threeG = NetworkConditions.presets.first { $0.name == "3G" }!

    await model.select(sim)
    await model.setConditions(threeG)
    #expect(model.conditions == threeG)
    #expect(runner.commands.isEmpty)       // nothing on a device: the proxy applies it

    await model.select(avd)
    #expect(model.conditions == .online)   // the emulator has its own setting
    await model.setConditions(threeG)
    #expect(runner.commands.contains("/sdk/platform-tools/adb -s emulator-5554 emu network speed 330:780"))
    await model.select(sim)
    #expect(model.conditions == threeG)
    // the emulator forgets its network settings when it stops
    await model.select(avd)
    await model.deviceListChanged([avd.withState(.stopped)])
    #expect(model.conditions == .online)
}

@MainActor
@Test func conditionsCanBeSetForADeviceThatIsNotSelected() async throws {
    let runner = MockShellRunner()
    let model = NetworkViewModel(runner: runner, makeAuthority: { try makeAuthority() }, locateSDK: { AndroidSDK(root: "/sdk") })
    let avd = Device(id: "avd", name: "Pixel", platform: .android, osVersion: "API 36", state: .running, serial: "emulator-5554")
    let edge = NetworkConditions.presets.first { $0.name == "Edge" }!
    #expect(model.conditions(for: avd) == .online)
    await model.setConditions(edge, for: avd)
    #expect(model.conditions(for: avd) == edge)
    #expect(model.conditions == .online)        // nothing selected: the panel shows nothing
}
