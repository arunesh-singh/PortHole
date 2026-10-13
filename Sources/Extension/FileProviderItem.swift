import FileProvider
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    private let entry: Entry

    init(identifier: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier, entry: Entry) {
        itemIdentifier = identifier
        parentItemIdentifier = parent
        filename = entry.name
        self.entry = entry
    }

    static func root(displayName: String) -> FileProviderItem {
        FileProviderItem(identifier: .rootContainer, parent: .rootContainer,
                         entry: Entry(name: displayName, isDirectory: true, size: 0, mtime: 0, isVolume: true))
    }

    var contentType: UTType {
        if entry.isDirectory { return .folder }
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty ? .data : UTType(filenameExtension: ext, conformingTo: .data) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        if itemIdentifier == .rootContainer { return [.allowsReading, .allowsContentEnumerating] }
        if entry.isVolume { return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems] }
        let mutable: NSFileProviderItemCapabilities = [.allowsRenaming, .allowsReparenting, .allowsDeleting]
        return entry.isDirectory
            ? mutable.union([.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems])
            : mutable.union([.allowsReading, .allowsWriting])
    }

    /// Download on read, and let macOS (and PortHole's cache limit) evict the
    /// local copy: the phone always has the original. Without an explicit
    /// policy, eviction failed with NSFileProviderError.nonEvictable and
    /// copying a camera roll filled the internal disk.
    var contentPolicy: NSFileProviderContentPolicy { .downloadLazily }

    var itemVersion: NSFileProviderItemVersion {
        let content = entry.isDirectory ? "dir" : "\(entry.size):\(entry.mtime)"
        return NSFileProviderItemVersion(contentVersion: Data(content.utf8),
                                         metadataVersion: Data("\(filename):\(content):\(entry.mtime)".utf8))
    }

    var documentSize: NSNumber? { entry.isDirectory ? nil : NSNumber(value: entry.size) }

    var contentModificationDate: Date? {
        entry.mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(entry.mtime)) : nil
    }

    var creationDate: Date? { contentModificationDate }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        entry.isDirectory ? [.userReadable, .userWritable, .userExecutable] : [.userReadable, .userWritable]
    }
}
