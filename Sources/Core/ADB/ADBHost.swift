import Foundation

/// Client for the adb server's smart-socket protocol (tcp:5037).
/// Spec: platform/packages/modules/adb/SERVICES.TXT and protocol.txt.
enum ADBHost {
    static let port: UInt16 = 5037

    struct DeviceRecord: Hashable, Sendable {
        var serial: String
        /// "device", "unauthorized", "offline", "authorizing", "connecting", …
        var state: String
        var properties: [String: String]

        var model: String? { properties["model"]?.replacingOccurrences(of: "_", with: " ") }
        var isNetwork: Bool { serial.contains(":") || serial.contains("._adb-tls-") }
    }

    /// Opens a connection and sends one host request, consuming the OKAY/FAIL status.
    static func request(_ service: String) throws -> Socket {
        let socket = try Socket.connectTCP(port: port)
        try send(service, on: socket)
        return socket
    }

    static func send(_ service: String, on socket: Socket) throws {
        let payload = Data(service.utf8)
        try socket.write(Data(String(format: "%04x", payload.count).utf8) + payload)
        try readStatus(socket)
    }

    static func readStatus(_ socket: Socket) throws {
        let status = String(decoding: try socket.read(count: 4), as: UTF8.self)
        switch status {
        case "OKAY": return
        case "FAIL": throw WireError(.deviceUnavailable, (try? readLengthPrefixed(socket)) ?? "adb: request failed")
        default: throw WireError(.io, "adb: unexpected status \(status)")
        }
    }

    static func readLengthPrefixed(_ socket: Socket) throws -> String {
        let hex = String(decoding: try socket.read(count: 4), as: UTF8.self)
        guard let length = Int(hex, radix: 16) else { throw WireError(.io, "adb: bad length \(hex)") }
        return String(decoding: try socket.read(count: length), as: UTF8.self)
    }

    /// One-shot host query returning a length-prefixed string (e.g. host:version).
    static func query(_ service: String) throws -> String {
        let socket = try request(service)
        defer { socket.close() }
        socket.setReadTimeout(seconds: 30)
        return try readLengthPrefixed(socket)
    }

    static func isServerRunning() -> Bool {
        (try? query("host:version")) != nil
    }

    /// Starts the adb server with the given binary if none is listening.
    static func ensureServer(adbPath: String) throws {
        if isServerRunning() { return }
        guard FileManager.default.isExecutableFile(atPath: adbPath) else {
            throw WireError(.deviceUnavailable, "adb not found at \(adbPath)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["start-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard isServerRunning() else { throw WireError(.deviceUnavailable, "adb server failed to start") }
    }

    /// Common install locations, first existing wins.
    static func locateADB() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/Applications/Android Studio.app/Contents/platform-tools/adb",
        ]
        if let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            let path = "\(sdk)/platform-tools/adb"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Parses `host:devices-l` / `host:track-devices-l` output.
    static func parseDevices(_ text: String) -> [DeviceRecord] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { return nil }
            var props: [String: String] = [:]
            for field in fields.dropFirst(2) {
                if let colon = field.firstIndex(of: ":") {
                    props[String(field[..<colon])] = String(field[field.index(after: colon)...])
                }
            }
            return DeviceRecord(serial: fields[0], state: fields[1], properties: props)
        }
    }

    static func devices() throws -> [DeviceRecord] {
        parseDevices(try query("host:devices-l"))
    }

    // MARK: Wireless debugging

    /// `adb connect host:port`. Returns adb's human-readable result.
    static func connect(_ address: String) throws -> String {
        let message = try query("host:connect:\(address)")
        if message.hasPrefix("failed") || message.hasPrefix("cannot") {
            throw WireError(.deviceUnavailable, message)
        }
        return message
    }

    static func disconnect(_ address: String) throws -> String {
        try query("host:disconnect:\(address)")
    }

    /// Android 11+ wireless-debugging pairing (`adb pair host:port code`).
    static func pair(_ address: String, code: String) throws -> String {
        let message = try query("host:pair:\(code):\(address)")
        if !message.lowercased().contains("successfully") {
            throw WireError(.deviceUnavailable, message)
        }
        return message
    }
}
