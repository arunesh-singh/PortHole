import FileProvider
import os

private let queue = DispatchQueue(label: "PortHole.enumeration", attributes: .concurrent)

private func anchorData(_ value: Int64) -> NSFileProviderSyncAnchor {
    NSFileProviderSyncAnchor(Data(String(value).utf8))
}

/// Enumerator for containers that never have contents (the Trash).
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchorData(0))
    }
}

/// Lists one folder (the device root lists its storage volumes).
final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    private let path: VPath
    private let client: DeviceClient
    private let store: ItemStore

    init(path: VPath, client: DeviceClient, store: ItemStore) {
        self.path = path
        self.client = client
        self.store = store
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        queue.async { [path, client, store] in
            do {
                let entries = try client.list(path)
                let parent = store.identifier(for: path)
                // Keep vanished children so the working set reports their deletion.
                let rows = store.replaceChildren(of: path, with: entries, pruneMissing: false).rows
                observer.didEnumerate(rows.map { FileProviderItem(identifier: $0.identifier, parent: parent, entry: $0.entry) })
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(fileProviderError(error))
            }
        }
    }

    // On macOS the system tracks changes through the working set only.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchorData(store.anchor()))
    }
}

/// Reports changes made on the phone: re-lists every folder the system has
/// enumerated and diffs it against the stored snapshot. The app signals this
/// enumerator periodically and on Refresh.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let log = Logger(subsystem: PortHoleConstants.logSubsystem, category: "workingset")
    private let client: DeviceClient
    private let store: ItemStore

    init(client: DeviceClient, store: ItemStore) {
        self.client = client
        self.store = store
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // Items enter the system through folder enumeration; nothing to seed here.
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        queue.async { [client, store, log] in
            var updated: [NSFileProviderItem] = []
            var deleted: [NSFileProviderItemIdentifier] = []
            var gone: [VPath] = []
            for directory in store.listedDirectories() where !gone.contains(where: directory.isWithin) {
                let before = store.children(of: directory)
                let entries: [Entry]
                do {
                    entries = try client.list(directory)
                } catch let error as WireError where error.code == .notFound || error.code == .notDirectory {
                    gone.append(directory)
                    if !directory.isRoot { deleted += store.remove(directory) }
                    continue
                } catch {
                    observer.finishEnumeratingWithError(fileProviderError(error))
                    return
                }
                let parent = store.identifier(for: directory)
                let result = store.replaceChildren(of: directory, with: entries)
                deleted += result.deleted
                for row in result.rows where before[row.entry.name]?.entry != row.entry {
                    updated.append(FileProviderItem(identifier: row.identifier, parent: parent, entry: row.entry))
                }
            }
            if !updated.isEmpty || !deleted.isEmpty {
                log.info("working set: \(updated.count) updated, \(deleted.count) deleted")
            }
            if !updated.isEmpty { observer.didUpdate(updated) }
            if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
            observer.finishEnumeratingChanges(upTo: anchorData(store.advanceAnchor()), moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchorData(store.anchor()))
    }
}
