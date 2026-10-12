import Foundation

struct DeviceInfo: Hashable, Sendable {
    /// Stable identifier, also used as the File Provider domain identifier
    /// ("adb-<serial>" / "mtp-<serial>"); restricted to [A-Za-z0-9._-].
    var id: String
    var name: String
    var transport: TransportKind
    /// Hardware serial, used to recognise the same phone over ADB and MTP.
    var serial: String

    static func makeID(_ transport: TransportKind, _ serial: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(serial.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return "\(transport.rawValue)-\(cleaned)"
    }
}

/// File operations on one connected device, addressed by virtual path.
/// Implementations are safe to call from any thread.
protocol DeviceBackend: AnyObject, Sendable {
    var info: DeviceInfo { get }

    func list(_ path: VPath) throws -> [Entry]
    func stat(_ path: VPath) throws -> Entry
    func download(_ path: VPath, to local: URL) throws
    /// Writes `local` to `path`, replacing an existing file.
    func upload(from local: URL, to path: VPath) throws -> Entry
    func makeDirectory(_ path: VPath) throws -> Entry
    /// Deletes a file or a directory tree.
    func delete(_ path: VPath) throws
    func move(_ from: VPath, to: VPath) throws -> Entry
    func close()
}

extension DeviceBackend {
    func rootEntry() -> Entry {
        Entry(name: info.name, isDirectory: true, size: 0, mtime: 0, isVolume: true)
    }

    /// Validation shared by all backends before a mutating operation.
    func requireMutable(_ path: VPath) throws {
        if path.isRoot || path.isVolumeRoot {
            throw WireError(.readOnly, "Storage volumes cannot be modified")
        }
    }

    /// Fails with `.exists` when something is already at `path`.
    func requireAbsent(_ path: VPath) throws {
        do {
            _ = try stat(path)
            throw WireError(.exists, "\(path.name) already exists")
        } catch let error as WireError where error.code == .notFound {
            return
        }
    }

    /// Copy-then-delete move for transports without a native move.
    func moveByCopying(_ from: VPath, to: VPath) throws -> Entry {
        try copyTree(from, to: to)
        try delete(from)
        return try stat(to)
    }

    private func copyTree(_ from: VPath, to: VPath) throws {
        let source = try stat(from)
        if source.isDirectory {
            _ = try makeDirectory(to)
            for child in try list(from) {
                try copyTree(from.appending(child.name), to: to.appending(child.name))
            }
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try download(from, to: temp)
        _ = try upload(from: temp, to: to)
    }
}
