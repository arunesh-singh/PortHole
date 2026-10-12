import Darwin
import Foundation

/// Values shared by the app, the File Provider extension and the CLI.
enum PortHoleConstants {
    static let logSubsystem = "com.arunesh.porthole"

    /// `~/Library/Application Support/PortHole`, shared by the (unsandboxed) app
    /// and the (sandboxed) extension. The extension reaches it through a
    /// home-relative temporary-exception entitlement. App-group containers are
    /// avoided on purpose: macOS only lets a sandboxed extension into one when
    /// the build is team-signed, which would break ad-hoc/self-built copies.
    static let supportDirectory: URL = {
        // Inside the sandbox, NSHomeDirectory() points into the container;
        // the exception entitlement is relative to the real home directory.
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/PortHole", isDirectory: true)
    }()

    /// Where the app publishes its loopback port and access token (mode 0600).
    static var endpointURL: URL { supportDirectory.appendingPathComponent("ipc.json") }

    /// Scratch directory for file contents in flight between app and extension.
    static var transfersURL: URL { supportDirectory.appendingPathComponent("Transfers", isDirectory: true) }

    /// Per-domain identifier/snapshot database, owned by the extension.
    static func databaseURL(domainID: String) -> URL {
        supportDirectory.appendingPathComponent("Domains/\(domainID).sqlite")
    }

    /// Drops a domain's database; the app calls this before (re)creating a domain
    /// so identifiers never outlive the system's copy of the domain.
    static func resetDomainState(domainID: String) {
        let base = databaseURL(domainID: domainID).path
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: base + suffix) }
    }
}

/// How the extension reaches the app. The sandbox forbids connecting to unix
/// sockets outside the extension's container, so IPC uses loopback TCP; the
/// token (readable only by the user) keeps other local users out.
struct IPCEndpoint: Codable, Sendable {
    var port: UInt16
    var token: String
}

/// Every request carries the endpoint token.
struct IPCEnvelope: Codable, Sendable {
    var token: String
    var request: IPCRequest
}

/// A file or directory on the device. Paths are virtual: "/" is the device root,
/// whose children are the device's storage volumes ("Internal storage", SD cards).
struct Entry: Codable, Hashable, Sendable {
    var name: String
    var isDirectory: Bool
    var size: UInt64
    /// Modification time, seconds since 1970.
    var mtime: Int64
    /// Volume roots (and "/") cannot be renamed, moved or deleted.
    var isVolume: Bool = false
}

enum TransportKind: String, Codable, Sendable {
    case adb, mtp
}

struct WireError: Error, Codable, Sendable, LocalizedError {
    enum Code: String, Codable, Sendable {
        case notFound, exists, notDirectory, isDirectory, notEmpty
        case readOnly, permissionDenied, deviceUnavailable, unsupported, io
    }

    var code: Code
    var message: String

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    var errorDescription: String? { message }
}

enum IPCRequest: Codable, Sendable {
    case list(device: String, path: String)
    case stat(device: String, path: String)
    /// Device file → local file at `destination` (inside the group container).
    case download(device: String, path: String, destination: String)
    /// Local file at `source` → device file at `path`, replacing any existing file.
    case upload(device: String, source: String, path: String)
    case makeDirectory(device: String, path: String)
    case delete(device: String, path: String)
    case move(device: String, from: String, to: String)
}

enum IPCResponse: Codable, Sendable {
    case entries([Entry])
    case entry(Entry)
    case ok
    case failure(WireError)
}
