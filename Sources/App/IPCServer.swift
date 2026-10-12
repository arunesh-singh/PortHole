import Darwin
import Foundation
import os

/// Connected device backends, keyed by DeviceInfo.id. Read by IPC threads.
final class DeviceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var backends: [String: DeviceBackend] = [:]

    func add(_ backend: DeviceBackend) { lock.withLock { backends[backend.info.id] = backend } }
    func remove(_ id: String) { lock.withLock { backends[id] = nil } }
    func backend(_ id: String) -> DeviceBackend? { lock.withLock { backends[id] } }
}

/// Serves file operations to the File Provider extension over loopback TCP.
/// The port and a per-launch token are published in `ipc.json` (mode 0600);
/// requests without the token are dropped. One request/response per connection.
final class IPCServer: @unchecked Sendable {
    private let log = Logger(subsystem: PortHoleConstants.logSubsystem, category: "ipc")
    private let registry: DeviceRegistry
    private var listener: Int32 = -1
    private var token = ""
    private let workers = DispatchQueue(label: "PortHole.ipc", attributes: .concurrent)

    init(registry: DeviceRegistry) {
        self.registry = registry
    }

    func start() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: PortHoleConstants.supportDirectory, withIntermediateDirectories: true)
        chmod(PortHoleConstants.supportDirectory.path, 0o700)
        try? fileManager.removeItem(at: PortHoleConstants.transfersURL)
        try fileManager.createDirectory(at: PortHoleConstants.transfersURL, withIntermediateDirectories: true)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.errno("socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 64) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else {
            let error = SocketError.errno("bind 127.0.0.1")
            close(fd)
            throw error
        }
        listener = fd

        var generator = SystemRandomNumberGenerator()
        token = (0..<4).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
        let endpoint = IPCEndpoint(port: UInt16(bigEndian: addr.sin_port), token: token)
        let url = PortHoleConstants.endpointURL
        try JSONEncoder().encode(endpoint).write(to: url, options: .atomic)
        chmod(url.path, 0o600)

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "PortHole.IPCServer"
        thread.start()
        log.info("IPC listening on 127.0.0.1:\(endpoint.port)")
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                log.error("accept failed: \(String(cString: strerror(errno)), privacy: .public)")
                return
            }
            let socket = Socket(fd: client)
            workers.async { self.serve(socket) }
        }
    }

    private func serve(_ socket: Socket) {
        defer { socket.close() }
        do {
            socket.setReadTimeout(seconds: 30)
            let envelope = try socket.receiveFrame(IPCEnvelope.self)
            guard Self.constantTimeEqual(envelope.token, token) else {
                log.error("IPC request with a bad token rejected")
                return
            }
            try socket.sendFrame(handle(envelope.request))
        } catch {
            log.error("IPC connection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func handle(_ request: IPCRequest) -> IPCResponse {
        func backend(_ id: String) throws -> DeviceBackend {
            guard let backend = registry.backend(id) else {
                throw WireError(.deviceUnavailable, "The device is not connected")
            }
            return backend
        }
        do {
            switch request {
            case let .list(device, path):
                return .entries(try backend(device).list(VPath(path)))
            case let .stat(device, path):
                return .entry(try backend(device).stat(VPath(path)))
            case let .download(device, path, destination):
                try backend(device).download(VPath(path), to: URL(fileURLWithPath: destination))
                return .ok
            case let .upload(device, source, path):
                return .entry(try backend(device).upload(from: URL(fileURLWithPath: source), to: VPath(path)))
            case let .makeDirectory(device, path):
                return .entry(try backend(device).makeDirectory(VPath(path)))
            case let .delete(device, path):
                try backend(device).delete(VPath(path))
                return .ok
            case let .move(device, from, to):
                return .entry(try backend(device).move(VPath(from), to: VPath(to)))
            }
        } catch let error as WireError {
            return .failure(error)
        } catch {
            return .failure(WireError(.io, error.localizedDescription))
        }
    }
}
