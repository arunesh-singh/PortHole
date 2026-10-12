import FileProvider
import os

/// Replicated File Provider for one Android device. Device access is proxied
/// through the PortHole app, which owns USB and adb.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let log = Logger(subsystem: PortHoleConstants.logSubsystem, category: "extension")
    private let domain: NSFileProviderDomain
    private let client: DeviceClient
    private let store: ItemStore?
    private let storeError: Error?
    private let queue = DispatchQueue(label: "PortHole.extension", attributes: .concurrent)

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        client = DeviceClient(deviceID: domain.identifier.rawValue)
        do {
            store = try ItemStore(domainID: domain.identifier.rawValue)
            storeError = nil
        } catch {
            store = nil
            storeError = error
        }
        super.init()
    }

    func invalidate() {}

    // MARK: Helpers

    /// AppleDouble/Finder metadata files stay on the Mac.
    private static func isExcluded(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == ".localized"
    }

    private func requireStore() throws -> ItemStore {
        guard let store else { throw storeError ?? WireError(.io, "Item store unavailable") }
        return store
    }

    private func requirePath(_ identifier: NSFileProviderItemIdentifier, _ store: ItemStore) throws -> VPath {
        if identifier == .trashContainer {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
                          userInfo: [NSLocalizedDescriptionKey: "The phone has no Trash"])
        }
        guard let path = store.path(for: identifier) else { throw NSFileProviderError(.noSuchItem) }
        return path
    }

    private func makeItem(_ path: VPath, _ entry: Entry, _ store: ItemStore) -> FileProviderItem {
        if path.isRoot { return .root(displayName: domain.displayName) }
        let identifier = store.record(path, entry)
        return FileProviderItem(identifier: identifier, parent: store.identifier(for: path.parent), entry: entry)
    }

    /// Runs `work` off the calling thread and returns an indeterminate progress.
    private func perform(_ work: @escaping (Progress) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        queue.async {
            work(progress)
            progress.completedUnitCount = 1
        }
        return progress
    }

    // MARK: NSFileProviderReplicatedExtension

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        perform { [self] _ in
            do {
                let store = try requireStore()
                if identifier == .rootContainer {
                    return completionHandler(FileProviderItem.root(displayName: domain.displayName), nil)
                }
                let path = try requirePath(identifier, store)
                completionHandler(makeItem(path, try client.stat(path), store), nil)
            } catch {
                completionHandler(nil, fileProviderError(error))
            }
        }
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        perform { [self] _ in
            do {
                let store = try requireStore()
                let path = try requirePath(itemIdentifier, store)
                let entry = try client.stat(path)
                let url = try client.download(path)
                completionHandler(url, makeItem(path, entry, store), nil)
            } catch {
                log.error("fetch failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, fileProviderError(error))
            }
        }
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        perform { [self] _ in
            do {
                let store = try requireStore()
                if Self.isExcluded(itemTemplate.filename) {
                    throw NSFileProviderError(.excludedFromSync)
                }
                let parent = try requirePath(itemTemplate.parentItemIdentifier, store)
                let path = parent.appending(itemTemplate.filename)
                let type = itemTemplate.contentType ?? .data
                if type.conforms(to: .symbolicLink) || type.conforms(to: .aliasFile) {
                    throw WireError(.unsupported, "Links can't be copied to the phone")
                }

                let existing: Entry?
                do { existing = try client.stat(path) } catch let error as WireError where error.code == .notFound { existing = nil }

                let entry: Entry
                if let existing, options.contains(.mayAlreadyExist), existing.isDirectory == (type == .folder) {
                    entry = existing
                } else if existing != nil {
                    throw NSFileProviderError(.filenameCollision)
                } else if type == .folder {
                    entry = try client.makeDirectory(path)
                    store.markListed(path)
                } else {
                    guard let url else { throw WireError(.io, "No contents for \(path.name)") }
                    entry = try client.upload(url, to: path)
                }
                completionHandler(makeItem(path, entry, store), [], false, nil)
            } catch {
                completionHandler(nil, [], false, fileProviderError(error))
            }
        }
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        perform { [self] _ in
            do {
                let store = try requireStore()
                var path = try requirePath(item.itemIdentifier, store)
                var entry: Entry?

                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let target = try requirePath(item.parentItemIdentifier, store).appending(item.filename)
                    if target != path {
                        entry = try client.move(path, to: target)
                        store.move(path, to: target)
                        path = target
                    }
                }
                if changedFields.contains(.contents), let newContents {
                    entry = try client.upload(newContents, to: path)
                }
                // Dates and other metadata are not writable on the device.
                completionHandler(makeItem(path, try entry ?? client.stat(path), store), [], false, nil)
            } catch {
                completionHandler(nil, [], false, fileProviderError(error))
            }
        }
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        perform { [self] _ in
            do {
                let store = try requireStore()
                guard let path = store.path(for: identifier) else { return completionHandler(nil) }
                do {
                    let entry = try client.stat(path)
                    if entry.isDirectory, !options.contains(.recursive), try !client.list(path).isEmpty {
                        throw NSFileProviderError(.directoryNotEmpty)
                    }
                    try client.delete(path)
                } catch let error as WireError where error.code == .notFound {
                    // Already gone on the device.
                }
                store.remove(path)
                completionHandler(nil)
            } catch {
                completionHandler(fileProviderError(error))
            }
        }
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let store = try requireStore()
        if containerItemIdentifier == .workingSet {
            return WorkingSetEnumerator(client: client, store: store)
        }
        if containerItemIdentifier == .trashContainer {
            // The phone has no Trash; Finder deletes immediately.
            return EmptyEnumerator()
        }
        guard let path = store.path(for: containerItemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
        return FolderEnumerator(path: path, client: client, store: store)
    }
}
