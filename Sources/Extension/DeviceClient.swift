import FileProvider
import Foundation
import os

private let log = Logger(subsystem: PortHoleConstants.logSubsystem, category: "client")

/// The extension's view of one device, proxied through the app over IPC.
/// Calls block; the extension runs them on a background queue.
struct DeviceClient {
    let deviceID: String

    private func call(_ request: IPCRequest) throws -> IPCResponse {
        let socket: Socket
        let endpoint: IPCEndpoint
        do {
            endpoint = try JSONDecoder().decode(IPCEndpoint.self, from: Data(contentsOf: PortHoleConstants.endpointURL))
            socket = try Socket.connectTCP(port: endpoint.port)
        } catch {
            log.error("Cannot reach PortHole: \(error.localizedDescription, privacy: .public)")
            throw WireError(.deviceUnavailable, "PortHole is not running")
        }
        defer { socket.close() }
        try socket.sendFrame(IPCEnvelope(token: endpoint.token, request: request))
        let response = try socket.receiveFrame(IPCResponse.self)
        if case .failure(let error) = response { throw error }
        return response
    }

    private func entry(_ request: IPCRequest) throws -> Entry {
        guard case .entry(let entry) = try call(request) else { throw WireError(.io, "Unexpected reply") }
        return entry
    }

    func list(_ path: VPath) throws -> [Entry] {
        guard case .entries(let entries) = try call(.list(device: deviceID, path: path.string)) else {
            throw WireError(.io, "Unexpected reply")
        }
        return entries
    }

    func stat(_ path: VPath) throws -> Entry {
        try entry(.stat(device: deviceID, path: path.string))
    }

    /// Downloads into the shared Transfers directory and returns the file's URL.
    func download(_ path: VPath) throws -> URL {
        let destination = try Self.transferURL(for: path.name)
        _ = try call(.download(device: deviceID, path: path.string, destination: destination.path))
        return destination
    }

    /// Clones `contents` into the shared Transfers directory (the app cannot read
    /// the extension's sandbox) and uploads it.
    func upload(_ contents: URL, to path: VPath) throws -> Entry {
        let staged = try Self.transferURL(for: path.name)
        try FileManager.default.copyItem(at: contents, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        return try entry(.upload(device: deviceID, source: staged.path, path: path.string))
    }

    func makeDirectory(_ path: VPath) throws -> Entry {
        try entry(.makeDirectory(device: deviceID, path: path.string))
    }

    func delete(_ path: VPath) throws {
        _ = try call(.delete(device: deviceID, path: path.string))
    }

    func move(_ from: VPath, to: VPath) throws -> Entry {
        try entry(.move(device: deviceID, from: from.string, to: to.string))
    }

    private static func transferURL(for name: String) throws -> URL {
        let directory = PortHoleConstants.transfersURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}

/// Maps transport errors to the errors the File Provider framework understands.
func fileProviderError(_ error: Error) -> Error {
    guard let wire = error as? WireError else {
        if error is SocketError { return NSFileProviderError(.serverUnreachable) }
        return error
    }
    let info = [NSLocalizedDescriptionKey: wire.message]
    switch wire.code {
    case .notFound: return NSFileProviderError(.noSuchItem)
    case .exists: return NSFileProviderError(.filenameCollision)
    case .notEmpty: return NSFileProviderError(.directoryNotEmpty)
    case .deviceUnavailable: return NSFileProviderError(.serverUnreachable)
    case .readOnly, .permissionDenied:
        return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: info)
    case .unsupported:
        return NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: info)
    case .notDirectory, .isDirectory, .io:
        return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: info)
    }
}
