import Foundation

/// File access over adb: the sync protocol for listing and transfer, shell
/// commands for mkdir/rm/mv. Each call opens its own adb connection, so calls
/// may run concurrently.
final class ADBBackend: DeviceBackend, @unchecked Sendable {
    let info: DeviceInfo
    let adbSerial: String
    private let useV2: Bool
    private let lock = NSLock()
    private var volumes: [(name: String, path: String)] = []

    init(record: ADBHost.DeviceRecord) throws {
        adbSerial = record.serial
        let features = Set(try ADBHost.query("host-serial:\(record.serial):features").split(separator: ",").map(String.init))
        useV2 = features.contains("stat_v2") && features.contains("ls_v2")

        let props = try Self.shell(serial: record.serial,
                                   "getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.serialno")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let model = props.count > 1 && !props[1].isEmpty ? props[1] : (record.model ?? record.serial)
        let hardwareSerial = props.count > 2 && !props[2].isEmpty ? props[2] : record.serial
        info = DeviceInfo(id: DeviceInfo.makeID(.adb, record.serial),
                          name: model,
                          transport: .adb,
                          serial: hardwareSerial)
        volumes = discoverVolumes()
    }

    func close() {}

    // MARK: Shell

    static func shell(serial: String, _ command: String) throws -> String {
        let socket = try ADBHost.request("host:transport:\(serial)")
        defer { socket.close() }
        try ADBHost.send("shell:\(command)", on: socket)
        return String(decoding: try socket.readToEnd(), as: UTF8.self)
    }

    /// Runs `command`, throwing with its output when the exit status is non-zero.
    @discardableResult
    private func run(_ command: String) throws -> String {
        let marker = "__PORTHOLE_RC="
        let output = try Self.shell(serial: adbSerial, "\(command) 2>&1; echo \(marker)$?")
        guard let range = output.range(of: marker, options: .backwards) else {
            throw WireError(.io, "adb shell: no exit status")
        }
        let text = String(output[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == "0" else { throw ADBSyncSession.mapFailure(text.isEmpty ? "\(command) failed" : text) }
        return text
    }

    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func session() throws -> ADBSyncSession {
        try ADBSyncSession(serial: adbSerial, useV2: useV2)
    }

    // MARK: Volumes

    private func discoverVolumes() -> [(name: String, path: String)] {
        var found = [(name: "Internal storage", path: "/sdcard")]
        if let entries = try? session().list("/storage") {
            for entry in entries.sorted(by: { $0.name < $1.name })
            where entry.stat.isDirectory && !["emulated", "self"].contains(entry.name) {
                found.append((name: "SD card (\(entry.name))", path: "/storage/\(entry.name)"))
            }
        }
        return found
    }

    private func devicePath(_ path: VPath) throws -> String {
        guard let volume = path.volume else { return "/" }
        let base = lock.withLock { volumes.first { $0.name == volume }?.path }
        guard let base else { throw WireError(.notFound, "No volume named \(volume)") }
        return path.inner.isEmpty ? base : base + "/" + path.inner.joined(separator: "/")
    }

    private func entry(name: String, _ stat: RemoteStat) -> Entry {
        Entry(name: name,
              isDirectory: stat.isDirectory,
              size: stat.isDirectory ? 0 : stat.size,
              mtime: stat.mtime)
    }

    // MARK: DeviceBackend

    func list(_ path: VPath) throws -> [Entry] {
        if path.isRoot {
            let discovered = discoverVolumes()
            lock.withLock { volumes = discovered }
            return discovered.map { Entry(name: $0.name, isDirectory: true, size: 0, mtime: 0, isVolume: true) }
        }
        let remote = try devicePath(path)
        let sync = try session()
        let dir = try sync.stat(remote)
        guard dir.exists else { throw WireError(.notFound, "\(path) not found") }
        guard dir.isDirectory else { throw WireError(.notDirectory, "\(path) is not a folder") }
        let listing = try sync.list(remote)
        return try listing.compactMap { item in
            guard item.stat.isSymlink else { return entry(name: item.name, item.stat) }
            let target = try sync.stat(remote + "/" + item.name)
            return target.exists ? entry(name: item.name, target) : nil
        }
    }

    func stat(_ path: VPath) throws -> Entry {
        if path.isRoot { return rootEntry() }
        let remote = try devicePath(path)
        if path.isVolumeRoot { return Entry(name: path.name, isDirectory: true, size: 0, mtime: 0, isVolume: true) }
        let result = try session().stat(remote)
        guard result.exists else { throw WireError(.notFound, "\(path) not found") }
        return entry(name: path.name, result)
    }

    func download(_ path: VPath, to local: URL) throws {
        let entry = try stat(path)
        guard !entry.isDirectory else { throw WireError(.isDirectory, "\(path) is a folder") }
        try session().receive(try devicePath(path), to: local)
    }

    func upload(from local: URL, to path: VPath) throws -> Entry {
        try requireMutable(path)
        let parent = try stat(path.parent)
        guard parent.isDirectory else { throw WireError(.notDirectory, "\(path.parent) is not a folder") }
        if let existing = try? stat(path), existing.isDirectory {
            throw WireError(.isDirectory, "\(path) is a folder")
        }
        try session().send(local, to: try devicePath(path))
        return try stat(path)
    }

    func makeDirectory(_ path: VPath) throws -> Entry {
        try requireMutable(path)
        try requireAbsent(path)
        try run("mkdir -- \(Self.quote(try devicePath(path)))")
        return try stat(path)
    }

    func delete(_ path: VPath) throws {
        try requireMutable(path)
        _ = try stat(path)
        try run("rm -rf -- \(Self.quote(try devicePath(path)))")
    }

    func move(_ from: VPath, to: VPath) throws -> Entry {
        try requireMutable(from)
        try requireMutable(to)
        _ = try stat(from)
        try requireAbsent(to)
        try run("mv -- \(Self.quote(try devicePath(from))) \(Self.quote(try devicePath(to)))")
        return try stat(to)
    }
}
