import CryptoKit
import Foundation

/// How far an Android device trusts Deckhand's certificate. Apps that target Android 7 or later ignore the user
/// store, so only `system` decrypts them all.
public enum AndroidTrust: Equatable, Sendable {
    /// The certificate is in the system store: every app trusts it (until the device restarts).
    case system
    /// Not there yet, but the device lets adb become root, so Set Up can put it there.
    case rootable
    /// A production build (a Google Play image, a phone): adb cannot become root, so only the user store is left.
    case locked
}

/// What was done on a device to make its traffic visible, so the panel can show a checklist.
public struct DeviceProxyState: Equatable, Sendable {
    public var certificateInstalled = false
    public var proxyConfigured = false
    /// Android only: whether apps in general trust the certificate; nil when unknown.
    public var androidTrust: AndroidTrust?
    /// What the user still has to do by hand, when something could not be automated.
    public var note: String?

    public init(certificateInstalled: Bool = false, proxyConfigured: Bool = false,
                androidTrust: AndroidTrust? = nil, note: String? = nil) {
        self.certificateInstalled = certificateInstalled
        self.proxyConfigured = proxyConfigured
        self.androidTrust = androidTrust
        self.note = note
    }
}

public enum DeviceProxySetupError: Error, CustomStringConvertible {
    case unsupported(String)

    public var description: String {
        switch self {
        case .unsupported(let reason): reason
        }
    }
}

/// The steps that make a device send its traffic through Deckhand: trusting the Deckhand certificate and pointing the
/// device at the proxy. Simulators follow the macOS proxy (see `SystemProxy`); Android needs its own setting.
public struct DeviceProxySetup: Sendable {
    private let runner: any ShellRunner
    private let sdk: AndroidSDK?
    private let authority: CertificateAuthority
    private let statePath: String
    /// The small VPN app that points an Android device at the proxy; without it the global proxy setting is used.
    private let helperAPK: String?
    public static let helperPackage = "com.deckhand.helper"
    /// `versionCode` of the bundled helper: a device with an older one gets the new build.
    public static let helperVersion = 3

    public init(runner: any ShellRunner = ProcessShellRunner(), sdk: AndroidSDK?, authority: CertificateAuthority,
                helperAPK: String? = nil,
                statePath: String = NSHomeDirectory() + "/Library/Application Support/Deckhand/Proxy/installed-certificates.json") {
        self.helperAPK = helperAPK
        self.runner = runner
        self.sdk = sdk
        self.authority = authority
        self.statePath = statePath
    }

    // MARK: Certificate

    /// Identifies this root, so a regenerated one counts as not installed.
    public func fingerprint() throws -> String {
        let pem = try authority.certificatePEM()
        let base64 = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64) else { throw DeviceProxySetupError.unsupported("unreadable certificate") }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public func isCertificateInstalled(on device: Device) -> Bool {
        guard let fingerprint = try? fingerprint() else { return false }
        return loadState()[device.id] == fingerprint
    }

    /// Makes the device trust Deckhand's certificate. Returns a note when part of it has to be finished by hand.
    @discardableResult
    public func installCertificate(on device: Device) async throws -> String? {
        let note: String?
        switch (device.platform, device.isPhysical) {
        case (.ios, false):
            _ = try await runner.run("/usr/bin/xcrun", ["simctl", "keychain", device.id, "add-root-cert", authority.certificatePath])
            note = nil
        case (.android, _):
            note = try await installAndroidCertificate(device)
        case (.ios, true):
            throw DeviceProxySetupError.unsupported("An iPhone or iPad needs the certificate installed by hand: AirDrop \(authority.certificatePath) to it, install the profile, then trust it in Settings → General → About → Certificate Trust Settings.")
        }
        if note == nil { markInstalled(device) }
        return note
    }

    private func markInstalled(_ device: Device) {
        guard let fingerprint = try? fingerprint() else { return }
        var state = loadState()
        state[device.id] = fingerprint
        try? FileManager.default.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    private func loadState() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: statePath) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    // MARK: Android

    private func adb(_ device: Device, _ arguments: [String]) async throws -> String {
        guard let sdk, let serial = device.serial else { throw DeviceProxySetupError.unsupported("Android SDK not found — set path in Settings") }
        return try await runner.run(sdk.adbPath, ["-s", serial] + arguments)
    }

    private func installAndroidCertificate(_ device: Device) async throws -> String? {
        let hash = try await subjectHash()
        let remote = "/data/local/tmp/\(hash).0"
        // a rootable image (an emulator without Play Store) can trust the certificate for every app;
        // when it is rootable but the install fails, that is an error to show, not a reason to fall back
        if try await installAsSystemCertificate(device, hash: hash, remote: remote) { return nil }

        _ = try await adb(device, ["push", authority.certificatePath, "/sdcard/Download/Deckhand-CA.crt"])
        _ = try? await adb(device, ["shell", "am", "start", "-a", "android.settings.SECURITY_SETTINGS"])
        return "This device cannot be rooted (a Google Play image or a production build), so Deckhand-CA.crt can only go in the user store: install it in Settings → Security → Encryption & credentials → Install a certificate → CA certificate. Browsers will be decrypted, but most apps ignore the user store and fail with \"Trust anchor for certification path not found\". To decrypt every app, use an emulator with an AOSP or Google APIs image (not Google Play): Set Up then trusts the certificate system-wide. For your own app, add <debug-overrides><trust-anchors><certificates src=\"user\"/></trust-anchors></debug-overrides> to its network security config. Stop Routing gives the other apps their network back."
    }

    /// Reads whether the system store of the device has this certificate, without changing anything. Apps that
    /// ignore the user store need it there.
    public func androidTrust(on device: Device) async -> AndroidTrust? {
        guard let hash = try? await subjectHash(),
              let pem = FileManager.default.contents(atPath: authority.certificatePath),
              (try? await adb(device, ["shell", "getprop", "ro.build.version.sdk"])) != nil else { return nil }
        let local = SHA256.hash(data: pem).map { String(format: "%02x", $0) }.joined()
        let installed = (try? await adb(device, ["shell", "sha256sum", "/system/etc/security/cacerts/\(hash).0"])) ?? ""
        // Android 14 and later read the APEX copy: a system store that apps do not see does not count
        let missing = (try? await adb(device, ["shell", "[ -d /apex/com.android.conscrypt/cacerts ] && [ ! -f /apex/com.android.conscrypt/cacerts/\(hash).0 ] && echo MISSING"])) ?? ""
        if installed.contains(local), !missing.contains("MISSING") { return .system }
        let debuggable = (try? await adb(device, ["shell", "getprop", "ro.debuggable"])) ?? ""
        return debuggable.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? .rootable : .locked
    }

    private func subjectHash() async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["x509", "-inform", "PEM", "-subject_hash_old", "-noout", "-in", authority.certificatePath]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let hash = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !hash.isEmpty else { throw DeviceProxySetupError.unsupported("could not hash the certificate") }
        return hash
    }

    static let certificateMarker = "DECKHAND_CERT_OK"

    /// Trusts the certificate system-wide by overlaying the CA directories with a copy that includes it
    /// (the approach HTTP Toolkit uses). Needs `adb root`; the overlay lasts until the device restarts.
    /// Returns false when the device cannot be rooted. The certificate must then be visible to apps: on Android 14
    /// and later they read the APEX copy, which is bound into the zygotes (new apps) and the running apps.
    private func installAsSystemCertificate(_ device: Device, hash: String, remote: String) async throws -> Bool {
        guard let sdk, let serial = device.serial else { return false }
        let rootResult = (try? await runner.run(sdk.adbPath, ["-s", serial, "root"])) ?? ""
        guard !rootResult.contains("cannot run as root") else { return false }
        try await waitForRoot(device)
        _ = try await adb(device, ["push", authority.certificatePath, remote])
        let output = try await adb(device, ["shell", Self.injectionScript(hash: hash, remote: remote)])
        guard output.contains(Self.certificateMarker) else {
            throw DeviceProxySetupError.unsupported("The certificate could not be installed on the device: \(output.suffix(300))")
        }
        return true
    }

    /// adbd restarts as root, and the connection is gone for a moment.
    private func waitForRoot(_ device: Device) async throws {
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            if let id = try? await adb(device, ["shell", "id"]), id.contains("uid=0") { return }
        }
        throw DeviceProxySetupError.unsupported("The device did not come back as root")
    }

    static func injectionScript(hash: String, remote: String) -> String {
        """
        set -e
        APEX=/apex/com.android.conscrypt/cacerts
        STORE=/system/etc/security/cacerts
        unmount_all() { for i in $(seq 1 100); do grep -q " $1 " /proc/self/mountinfo || return 0; umount -l "$1" 2>/dev/null || return 0; done; }
        unmount_all $APEX
        unmount_all $STORE
        rm -rf /data/local/tmp/bb-ca
        mkdir -p -m 700 /data/local/tmp/bb-ca
        if [ -d $APEX ]; then cp $APEX/* /data/local/tmp/bb-ca/; else cp $STORE/* /data/local/tmp/bb-ca/; fi
        mount -t tmpfs tmpfs $STORE
        cp /data/local/tmp/bb-ca/* $STORE/
        cp \(remote) $STORE/\(hash).0
        chown root:root $STORE/*
        chmod 644 $STORE/*
        chcon u:object_r:system_file:s0 $STORE $STORE/*
        if [ -d $APEX ]; then
          REBIND="for i in 1 2 3 4 5; do umount -l $APEX 2>/dev/null || break; done; /bin/mount --bind $STORE $APEX"
          /bin/sh -c "$REBIND"
          Z_PIDS="$(pidof zygote || true) $(pidof zygote64 || true)"
          for Z in $Z_PIDS; do nsenter --mount=/proc/$Z/ns/mnt -- /bin/sh -c "$REBIND"; done
          APP_PIDS=$(echo $Z_PIDS | xargs -n1 ps -o PID -P | grep -v PID || true)
          for P in $APP_PIDS; do nsenter --mount=/proc/$P/ns/mnt -- /bin/sh -c "$REBIND" & done
          wait
          for Z in $Z_PIDS; do nsenter --mount=/proc/$Z/ns/mnt -- test -f $APEX/\(hash).0; done
        fi
        rm -rf /data/local/tmp/bb-ca \(remote)
        echo \(certificateMarker)
        """
    }

    /// Where the device reaches the proxy, whatever port Deckhand picked: `adb reverse` maps this port to it.
    public static let devicePort = 8899

    public func enableAndroidProxy(on device: Device, port: Int) async throws {
        _ = try await adb(device, ["reverse", "tcp:\(Self.devicePort)", "tcp:\(port)"])
        if let helperAPK {
            try await installHelperIfNeeded(device, apk: helperAPK)
            // lets the VPN start without the system's confirmation dialog
            _ = try? await adb(device, ["shell", "appops", "set", Self.helperPackage, "ACTIVATE_VPN", "allow"])
            // the helper now follows Deckhand: it connects its VPN while the proxy answers and drops it when it stops
            _ = try await adb(device, Self.helperArguments("watch"))
        } else {
            _ = try await adb(device, ["shell", "settings", "put", "global", "http_proxy", "127.0.0.1:\(Self.devicePort)"])
        }
    }

    /// The user's choice to stop: the helper stops watching too.
    public func disableAndroidProxy(on device: Device, port: Int) async throws {
        if helperAPK != nil { _ = try? await adb(device, Self.helperArguments("unwatch")) }
        _ = try await adb(device, ["shell", "settings", "put", "global", "http_proxy", ":0"])
        _ = try? await adb(device, ["reverse", "--remove", "tcp:\(Self.devicePort)"])
    }

    public func isAndroidProxyEnabled(on device: Device, port: Int) async -> Bool {
        let value = (try? await adb(device, ["shell", "settings", "get", "global", "http_proxy"])) ?? ""
        if value.trimmingCharacters(in: .whitespacesAndNewlines) == "127.0.0.1:\(Self.devicePort)" { return true }
        guard helperAPK != nil else { return false }
        let connectivity = (try? await adb(device, ["shell", "dumpsys", "connectivity"])) ?? ""
        return connectivity.contains("CONNECTED extra: VPN:\(Self.helperPackage)")
    }

    /// Serials of the connected Android devices that have the helper installed.
    public func helperDevices() async -> [String] {
        guard helperAPK != nil, let sdk,
              let list = try? await runner.run(sdk.adbPath, ["devices"]) else { return [] }
        let serials = list.split(whereSeparator: \.isNewline).dropFirst().compactMap { line -> String? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count >= 2 && parts[1] == "device" ? String(parts[0]) : nil
        }
        var withHelper: [String] = []
        for serial in serials {
            let installed = (try? await runner.run(sdk.adbPath, ["-s", serial, "shell", "pm", "path", Self.helperPackage])) ?? ""
            if installed.contains("package:") { withHelper.append(serial) }
        }
        return withHelper
    }

    /// Capturing started: the helpers can reach the proxy again, and connect their VPN by themselves.
    public func attachHelpers(port: Int) async {
        guard let sdk else { return }
        for serial in await helperDevices() {
            _ = try? await runner.run(sdk.adbPath, ["-s", serial, "reverse", "tcp:\(Self.devicePort)", "tcp:\(port)"])
        }
    }

    /// Capturing stopped: the helpers lose the proxy, and drop their VPN at once rather than after their next check.
    public func detachHelpers() async {
        guard let sdk else { return }
        for serial in await helperDevices() {
            _ = try? await runner.run(sdk.adbPath, ["-s", serial] + Self.helperArguments("stop"))
            _ = try? await runner.run(sdk.adbPath, ["-s", serial, "reverse", "--remove", "tcp:\(Self.devicePort)"])
        }
    }

    /// Arguments that give the helper app a command: `watch`, `unwatch`, `start` or `stop`.
    public static func helperArguments(_ command: String) -> [String] {
        ["shell", "am", "start", "-n", "\(helperPackage)/.MainActivity", "--es", "command", command,
         "--es", "host", "127.0.0.1", "--ei", "port", String(devicePort), "--ez", "quiet", "true"]
    }

    private func installHelperIfNeeded(_ device: Device, apk: String) async throws {
        let installed = (try? await adb(device, ["shell", "dumpsys", "package", Self.helperPackage])) ?? ""
        if let range = installed.range(of: #"versionCode=(\d+)"#, options: .regularExpression),
           let version = Int(installed[range].dropFirst("versionCode=".count)), version >= Self.helperVersion { return }
        do {
            _ = try await adb(device, ["install", "-r", "-g", apk])
        } catch {
            // an APK signed with another key (a build from another machine) cannot replace the installed one
            _ = try? await adb(device, ["uninstall", Self.helperPackage])
            _ = try await adb(device, ["install", "-g", apk])
        }
    }
}
