import Darwin
import Foundation

/// Result of STAT/STA2/LST2. `exists` is false for missing paths.
struct RemoteStat {
    var mode: UInt32
    var size: UInt64
    var mtime: Int64
    var exists: Bool

    var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    var isSymlink: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFLNK) }
}

/// One `sync:` session on a device (file_sync_protocol.h). Not thread-safe;
/// each operation uses its own session.
final class ADBSyncSession {
    private let socket: Socket
    private let v2: Bool
    private static let chunk = 64 * 1024

    init(serial: String, useV2: Bool) throws {
        socket = try ADBHost.request("host:transport:\(serial)")
        try ADBHost.send("sync:", on: socket)
        v2 = useV2
    }

    deinit {
        // QUIT lets adbd end the session cleanly.
        try? sendRequest("QUIT", Data())
        socket.close()
    }

    // MARK: Wire helpers

    private func sendRequest(_ id: String, _ payload: Data) throws {
        var message = Data(id.utf8)
        message.appendLE(UInt32(payload.count))
        message.append(payload)
        try socket.write(message)
    }

    private func sendRequest(_ id: String, path: String) throws {
        let bytes = Data(path.utf8)
        guard bytes.count <= 1024 else { throw WireError(.io, "Path too long for adb: \(path)") }
        try sendRequest(id, bytes)
    }

    private func readID() throws -> String {
        String(decoding: try socket.read(count: 4), as: UTF8.self)
    }

    private func readFailure() throws -> WireError {
        let length = try socket.read(count: 4).readLE(UInt32.self, at: 0)
        return Self.mapFailure(String(decoding: try socket.read(count: Int(length)), as: UTF8.self))
    }

    static func mapFailure(_ message: String) -> WireError {
        let lower = message.lowercased()
        if lower.contains("no such file") || lower.contains("does not exist") { return WireError(.notFound, message) }
        if lower.contains("permission denied") || lower.contains("read-only") { return WireError(.permissionDenied, message) }
        if lower.contains("is a directory") { return WireError(.isDirectory, message) }
        if lower.contains("no space") { return WireError(.io, message) }
        return WireError(.io, message)
    }

    // MARK: Operations

    func stat(_ path: String, followLinks: Bool = true) throws -> RemoteStat {
        if v2 {
            let id = followLinks ? "STA2" : "LST2"
            try sendRequest(id, path: path)
            let reply = try socket.read(count: 72)
            guard String(decoding: reply.prefix(4), as: UTF8.self) == id else {
                throw WireError(.io, "adb: unexpected stat reply")
            }
            let error = reply.readLE(UInt32.self, at: 4)
            if error != 0 {
                if error == UInt32(ENOENT) || error == UInt32(ENOTDIR) {
                    return RemoteStat(mode: 0, size: 0, mtime: 0, exists: false)
                }
                throw WireError(error == UInt32(EACCES) ? .permissionDenied : .io,
                                "\(path): \(String(cString: strerror(Int32(error))))")
            }
            return RemoteStat(mode: reply.readLE(UInt32.self, at: 24),
                              size: reply.readLE(UInt64.self, at: 40),
                              mtime: reply.readLE(Int64.self, at: 56),
                              exists: true)
        }
        try sendRequest("STAT", path: path)
        let reply = try socket.read(count: 16)
        let mode = reply.readLE(UInt32.self, at: 4)
        return RemoteStat(mode: mode,
                          size: UInt64(reply.readLE(UInt32.self, at: 8)),
                          mtime: Int64(reply.readLE(UInt32.self, at: 12)),
                          exists: mode != 0)
    }

    /// Directory listing excluding "." and "..". Missing directories list as empty,
    /// so callers stat first.
    func list(_ path: String) throws -> [(name: String, stat: RemoteStat)] {
        try sendRequest(v2 ? "LIS2" : "LIST", path: path)
        var result: [(String, RemoteStat)] = []
        let size = v2 ? 76 : 20
        while true {
            let dent = try socket.read(count: size)
            let id = String(decoding: dent.prefix(4), as: UTF8.self)
            if id == "DONE" { return result }
            guard id == (v2 ? "DNT2" : "DENT") else { throw WireError(.io, "adb: unexpected list reply \(id)") }
            let nameLength = dent.readLE(UInt32.self, at: size - 4)
            let name = String(decoding: try socket.read(count: Int(nameLength)), as: UTF8.self)
            if name == "." || name == ".." { continue }
            if v2 {
                if dent.readLE(UInt32.self, at: 4) != 0 { continue }
                result.append((name, RemoteStat(mode: dent.readLE(UInt32.self, at: 24),
                                                size: dent.readLE(UInt64.self, at: 40),
                                                mtime: dent.readLE(Int64.self, at: 56),
                                                exists: true)))
            } else {
                result.append((name, RemoteStat(mode: dent.readLE(UInt32.self, at: 4),
                                                size: UInt64(dent.readLE(UInt32.self, at: 8)),
                                                mtime: Int64(dent.readLE(UInt32.self, at: 12)),
                                                exists: true)))
            }
        }
    }

    func receive(_ path: String, to local: URL) throws {
        guard FileManager.default.createFile(atPath: local.path, contents: nil) else {
            throw WireError(.io, "Cannot create \(local.path)")
        }
        let handle = try FileHandle(forWritingTo: local)
        defer { try? handle.close() }
        try sendRequest("RECV", path: path)
        while true {
            let id = try readID()
            switch id {
            case "DATA":
                let length = try socket.read(count: 4).readLE(UInt32.self, at: 0)
                try handle.write(contentsOf: try socket.read(count: Int(length)))
            case "DONE":
                _ = try socket.read(count: 4)
                return
            case "FAIL":
                throw try readFailure()
            default:
                throw WireError(.io, "adb: unexpected recv reply \(id)")
            }
        }
    }

    func send(_ local: URL, to path: String, mode: UInt32 = 0o100644) throws {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        let mtime = (try? local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { UInt32($0.timeIntervalSince1970) } ?? UInt32(Date().timeIntervalSince1970)
        try sendRequest("SEND", path: "\(path),\(mode)")
        while let data = try handle.read(upToCount: Self.chunk), !data.isEmpty {
            var header = Data("DATA".utf8)
            header.appendLE(UInt32(data.count))
            try socket.write(header + data)
        }
        var done = Data("DONE".utf8)
        done.appendLE(mtime)
        try socket.write(done)
        let id = try readID()
        switch id {
        case "OKAY": _ = try socket.read(count: 4)
        case "FAIL": throw try readFailure()
        default: throw WireError(.io, "adb: unexpected send reply \(id)")
        }
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
