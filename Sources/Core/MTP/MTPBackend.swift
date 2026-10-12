import CMTP
import Foundation

/// All libmtp calls go through this queue: libmtp keeps per-process state and
/// is not documented as thread-safe.
enum MTPQueue {
    static let queue = DispatchQueue(label: "PortHole.libmtp")
    private static let initialize: Void = {
        LIBMTP_Init()
        LIBMTP_Set_Debug(0)
    }()

    static func sync<T>(_ work: () throws -> T) rethrows -> T {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return try queue.sync {
            _ = initialize
            return try work()
        }
    }

    static func ensureInitialized() {
        dispatchPrecondition(condition: .onQueue(queue))
        _ = initialize
    }
}

/// File access over MTP. MTP addresses objects by numeric handle, so virtual
/// paths are resolved by walking folder listings, with a path→handle cache.
final class MTPBackend: DeviceBackend, @unchecked Sendable {
    /// libmtp's "list the storage root" parent handle.
    private static let listRoot: UInt32 = 0xFFFF_FFFF

    private struct Ref {
        var storage: UInt32
        /// `listRoot` for a storage root.
        var handle: UInt32
        var isDirectory: Bool
        var size: UInt64
        var mtime: Int64

        /// Parent handle for SendObjectInfo (new files/folders): the MTP spec and
        /// Android use 0xFFFFFFFF for "storage root"; 0 is an invalid handle.
        var parentForSend: UInt32 { handle }
        /// Parent handle for MoveObject, where the spec uses 0 for "storage root".
        var parentForMove: UInt32 { handle == MTPBackend.listRoot ? 0 : handle }
    }

    let info: DeviceInfo
    /// "bus-devnum", identifies the USB attachment.
    let usbKey: String

    // Everything below is touched only on MTPQueue.
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private let raw: UnsafeMutablePointer<LIBMTP_raw_device_t>
    private var storages: [(name: String, id: UInt32)] = []
    private var cache: [VPath: Ref] = [:]

    /// Opens the device. Must run on MTPQueue; takes ownership of `raw`.
    init(raw: UnsafeMutablePointer<LIBMTP_raw_device_t>, usbKey: String) throws {
        MTPQueue.ensureInitialized()
        self.raw = raw
        self.usbKey = usbKey
        guard let device = LIBMTP_Open_Raw_Device_Uncached(raw) else {
            raw.deallocate()
            throw WireError(.deviceUnavailable, "Could not open the MTP device")
        }
        self.device = device
        let serial = Self.takeString(LIBMTP_Get_Serialnumber(device)) ?? usbKey
        let model = Self.takeString(LIBMTP_Get_Modelname(device))
            ?? Self.takeString(LIBMTP_Get_Friendlyname(device))
            ?? "Android device"
        info = DeviceInfo(id: DeviceInfo.makeID(.mtp, serial), name: model, transport: .mtp, serial: serial)
        refreshStorages()
    }

    func close() {
        MTPQueue.sync { closeOnQueue() }
    }

    /// For callers already on MTPQueue (the monitor).
    func closeOnQueue() {
        guard let device else { return }
        LIBMTP_Release_Device(device)
        self.device = nil
        raw.deallocate()
    }

    // MARK: libmtp helpers (on queue)

    private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { free(pointer) }
        let value = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func requireDevice() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let device else { throw WireError(.deviceUnavailable, "\(info.name) is disconnected") }
        return device
    }

    /// Drains libmtp's error stack into an error.
    private func failure(_ what: String, code: WireError.Code = .io) -> WireError {
        var messages: [String] = []
        if let device {
            var node = LIBMTP_Get_Errorstack(device)
            while let current = node {
                if let text = current.pointee.error_text { messages.append(String(cString: text)) }
                node = current.pointee.next
            }
            LIBMTP_Clear_Errorstack(device)
        }
        let detail = messages.last.map { ": \($0)" } ?? ""
        let lower = detail.lowercased()
        if lower.contains("storage full") || lower.contains("no space") { return WireError(.io, "Device storage is full") }
        if lower.contains("no device") || lower.contains("usb") && lower.contains("error") {
            return WireError(.deviceUnavailable, "\(what)\(detail)")
        }
        return WireError(code, "\(what)\(detail)")
    }

    private func refreshStorages() {
        guard let device else { return }
        storages = []
        guard LIBMTP_Get_Storage(device, 0) == 0 else {
            LIBMTP_Clear_Errorstack(device)
            return
        }
        var node = device.pointee.storage
        while let storage = node {
            var name = [storage.pointee.StorageDescription, storage.pointee.VolumeIdentifier]
                .compactMap { $0.map { String(cString: $0) } }
                .first { !$0.isEmpty } ?? "Storage"
            name = name.replacingOccurrences(of: "/", with: "-")
            var unique = name
            var counter = 2
            while storages.contains(where: { $0.name == unique }) {
                unique = "\(name) \(counter)"
                counter += 1
            }
            storages.append((unique, storage.pointee.id))
            node = storage.pointee.next
        }
    }

    /// Fresh listing of one folder; refreshes the cache for its children.
    private func children(of path: VPath, _ folder: Ref) throws -> [(name: String, ref: Ref)] {
        let device = try requireDevice()
        LIBMTP_Clear_Errorstack(device)
        var result: [(String, Ref)] = []
        var node = LIBMTP_Get_Files_And_Folders(device, folder.storage, folder.handle)
        if node == nil, LIBMTP_Get_Errorstack(device) != nil {
            throw failure("Listing \(path) failed")
        }
        while let file = node {
            let name = file.pointee.filename.map { String(cString: $0) } ?? "\(file.pointee.item_id)"
            let isDirectory = file.pointee.filetype == LIBMTP_FILETYPE_FOLDER
            result.append((name, Ref(storage: file.pointee.storage_id,
                                     handle: file.pointee.item_id,
                                     isDirectory: isDirectory,
                                     size: isDirectory ? 0 : file.pointee.filesize,
                                     mtime: Int64(file.pointee.modificationdate))))
            node = file.pointee.next
            LIBMTP_destroy_file_t(file)
        }
        cache = cache.filter { $0.key.parent != path }
        for (name, ref) in result { cache[path.appending(name)] = ref }
        return result
    }

    private func resolve(_ path: VPath) throws -> Ref {
        guard let volume = path.volume else { throw WireError(.isDirectory, "Device root has no handle") }
        if path.isVolumeRoot {
            if storages.isEmpty { refreshStorages() }
            guard let storage = storages.first(where: { $0.name == volume }) else {
                throw WireError(.notFound, "No storage named \(volume)")
            }
            return Ref(storage: storage.id, handle: Self.listRoot, isDirectory: true, size: 0, mtime: 0)
        }
        if let hit = cache[path] { return hit }
        return try lookupFresh(path)
    }

    /// Resolves via a fresh listing of the parent, ignoring a cached entry for `path`.
    private func lookupFresh(_ path: VPath) throws -> Ref {
        let parent = try resolve(path.parent)
        guard parent.isDirectory else { throw WireError(.notDirectory, "\(path.parent) is not a folder") }
        let listing: [(name: String, ref: Ref)]
        do {
            listing = try children(of: path.parent, parent)
        } catch let error as WireError where error.code != .deviceUnavailable && cache[path.parent] != nil {
            // The parent's cached handle may be stale; resolve it again once.
            invalidate(path.parent)
            listing = try children(of: path.parent, try resolve(path.parent))
        }
        guard let match = listing.first(where: { $0.name == path.name }) else {
            throw WireError(.notFound, "\(path) not found")
        }
        return match.ref
    }

    private func invalidate(_ path: VPath) {
        cache = cache.filter { !$0.key.isWithin(path) }
    }

    private func metadata(_ handle: UInt32, name: String) throws -> Ref {
        let device = try requireDevice()
        guard let file = LIBMTP_Get_Filemetadata(device, handle) else { throw failure("Reading \(name) failed") }
        defer { LIBMTP_destroy_file_t(file) }
        let isDirectory = file.pointee.filetype == LIBMTP_FILETYPE_FOLDER
        return Ref(storage: file.pointee.storage_id, handle: handle, isDirectory: isDirectory,
                   size: isDirectory ? 0 : file.pointee.filesize, mtime: Int64(file.pointee.modificationdate))
    }

    private func entry(_ name: String, _ ref: Ref) -> Entry {
        Entry(name: name, isDirectory: ref.isDirectory, size: ref.size, mtime: ref.mtime)
    }

    private func rename(_ ref: Ref, at path: VPath, to name: String) throws {
        let device = try requireDevice()
        guard let file = LIBMTP_Get_Filemetadata(device, ref.handle) else { throw failure("Reading \(path) failed") }
        defer { LIBMTP_destroy_file_t(file) }
        guard LIBMTP_Set_File_Name(device, file, name) == 0 else { throw failure("Renaming \(path) failed") }
    }

    // MARK: DeviceBackend

    func list(_ path: VPath) throws -> [Entry] {
        try MTPQueue.sync {
            _ = try requireDevice()
            if path.isRoot {
                refreshStorages()
                return storages.map { Entry(name: $0.name, isDirectory: true, size: 0, mtime: 0, isVolume: true) }
            }
            var folder = try resolve(path)
            guard folder.isDirectory else { throw WireError(.notDirectory, "\(path) is not a folder") }
            let listing: [(name: String, ref: Ref)]
            do {
                listing = try children(of: path, folder)
            } catch let error as WireError where error.code != .deviceUnavailable && !path.isVolumeRoot {
                invalidate(path)
                folder = try lookupFresh(path)
                listing = try children(of: path, folder)
            }
            return listing.map { entry($0.name, $0.ref) }
        }
    }

    func stat(_ path: VPath) throws -> Entry {
        if path.isRoot { return rootEntry() }
        return try MTPQueue.sync {
            _ = try requireDevice()
            if path.isVolumeRoot {
                _ = try resolve(path)
                return Entry(name: path.name, isDirectory: true, size: 0, mtime: 0, isVolume: true)
            }
            return entry(path.name, try lookupFresh(path))
        }
    }

    func download(_ path: VPath, to local: URL) throws {
        try MTPQueue.sync {
            let device = try requireDevice()
            let ref = try lookupFresh(path)
            guard !ref.isDirectory else { throw WireError(.isDirectory, "\(path) is a folder") }
            guard LIBMTP_Get_File_To_File(device, ref.handle, local.path, nil, nil) == 0 else {
                throw failure("Downloading \(path) failed")
            }
        }
    }

    func upload(from local: URL, to path: VPath) throws -> Entry {
        try requireMutable(path)
        let size = try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? UInt64 ?? 0
        return try MTPQueue.sync {
            let device = try requireDevice()
            let parent = try resolve(path.parent)
            guard parent.isDirectory else { throw WireError(.notDirectory, "\(path.parent) is not a folder") }
            // MTP cannot overwrite in place: delete the old object first.
            if let existing = try children(of: path.parent, parent).first(where: { $0.name == path.name }) {
                guard !existing.ref.isDirectory else { throw WireError(.isDirectory, "\(path) is a folder") }
                guard LIBMTP_Delete_Object(device, existing.ref.handle) == 0 else {
                    throw failure("Replacing \(path) failed")
                }
                invalidate(path)
            }
            guard let file = LIBMTP_new_file_t() else { throw WireError(.io, "Out of memory") }
            defer { LIBMTP_destroy_file_t(file) }
            file.pointee.filename = strdup(path.name)
            file.pointee.filesize = size
            file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
            file.pointee.parent_id = parent.parentForSend
            file.pointee.storage_id = parent.storage
            guard LIBMTP_Send_File_From_File(device, local.path, file, nil, nil) == 0 else {
                throw failure("Uploading \(path) failed")
            }
            let ref = try metadata(file.pointee.item_id, name: path.name)
            cache[path] = ref
            return entry(path.name, ref)
        }
    }

    func makeDirectory(_ path: VPath) throws -> Entry {
        try requireMutable(path)
        return try MTPQueue.sync {
            let device = try requireDevice()
            let parent = try resolve(path.parent)
            guard parent.isDirectory else { throw WireError(.notDirectory, "\(path.parent) is not a folder") }
            if try children(of: path.parent, parent).contains(where: { $0.name == path.name }) {
                throw WireError(.exists, "\(path.name) already exists")
            }
            let name = strdup(path.name)
            defer { free(name) }
            let handle = LIBMTP_Create_Folder(device, name, parent.parentForSend, parent.storage)
            guard handle != 0 else { throw failure("Creating \(path) failed") }
            let ref = try metadata(handle, name: path.name)
            cache[path] = ref
            return entry(path.name, ref)
        }
    }

    func delete(_ path: VPath) throws {
        try requireMutable(path)
        try MTPQueue.sync {
            let device = try requireDevice()
            let ref = try lookupFresh(path)
            guard LIBMTP_Delete_Object(device, ref.handle) == 0 else { throw failure("Deleting \(path) failed") }
            invalidate(path)
        }
    }

    func move(_ from: VPath, to: VPath) throws -> Entry {
        try requireMutable(from)
        try requireMutable(to)
        let movedNatively: Bool = try MTPQueue.sync {
            let device = try requireDevice()
            let source = try lookupFresh(from)
            let parent = try resolve(to.parent)
            guard parent.isDirectory else { throw WireError(.notDirectory, "\(to.parent) is not a folder") }
            if try children(of: to.parent, parent).contains(where: { $0.name == to.name }) {
                throw WireError(.exists, "\(to.name) already exists")
            }
            if from.parent != to.parent {
                guard LIBMTP_Move_Object(device, source.handle, parent.storage, parent.parentForMove) == 0 else {
                    LIBMTP_Clear_Errorstack(device)
                    return false
                }
            }
            if from.name != to.name {
                try rename(source, at: from, to: to.name)
            }
            invalidate(from)
            invalidate(to)
            return true
        }
        // Devices without MoveObject (or cross-storage moves) fall back to copy + delete.
        return movedNatively ? try stat(to) : try moveByCopying(from, to: to)
    }
}
