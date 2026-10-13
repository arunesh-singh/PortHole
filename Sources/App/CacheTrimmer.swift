import FileProvider
import os

/// Keeps the local copies of phone files small.
///
/// Finder can only read a phone file after File Provider downloads it into
/// ~/Library/CloudStorage on the Mac's internal disk, and macOS keeps those
/// copies around. Copying a whole camera folder to another drive would
/// otherwise fill the internal disk. This evicts copies (turning them back into
/// placeholders; the phone is untouched), least recently used first, until the
/// cache fits `limitBytes`, or everything when the disk is nearly full. Files
/// that are open (e.g. mid-copy) refuse eviction with EBUSY and are retried on
/// the next pass.
@MainActor
final class CacheTrimmer {
    private let log = Logger(subsystem: PortHoleConstants.logSubsystem, category: "cache")
    private var running = false
    private var again = false
    /// Size on disk and first-seen time of each downloaded file, per domain and
    /// item. The materialized-set items carry no size, so each new file's local
    /// copy is measured once; first-seen order approximates least recently used.
    private var known: [String: [NSFileProviderItemIdentifier: (bytes: Int64, seen: Date)]] = [:]
    /// Below this much free space on the internal disk, evict everything evictable.
    private static let lowDiskBytes: Int64 = 5 * 1024 * 1024 * 1024

    func trim(domains: [NSFileProviderDomain], limitBytes: Int64) {
        guard !running else {
            again = true
            return
        }
        running = true
        Task {
            repeat {
                again = false
                for domain in domains {
                    guard let manager = NSFileProviderManager(for: domain) else { continue }
                    await trim(manager, name: domain.identifier.rawValue, limitBytes: effectiveLimit(limitBytes))
                }
            } while again
            running = false
        }
    }

    private func effectiveLimit(_ limit: Int64) -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        return free < Self.lowDiskBytes ? 0 : limit
    }

    private func trim(_ manager: NSFileProviderManager, name: String, limitBytes: Int64) async {
        let files: [NSFileProviderItem]
        do {
            files = try await Self.materializedItems(manager).filter { $0.contentType?.conforms(to: .folder) != true }
        } catch {
            log.error("Listing cached files of \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        var sizes = (known[name] ?? [:]).filter { entry in files.contains { $0.itemIdentifier == entry.key } }
        let now = Date()
        for item in files where sizes[item.itemIdentifier] == nil {
            sizes[item.itemIdentifier] = (await Self.localSize(manager, item.itemIdentifier), now)
        }
        known[name] = sizes
        var total = sizes.values.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > limitBytes else { return }

        var evicted = 0, busy = 0
        for (identifier, entry) in sizes.sorted(by: { $0.value.seen < $1.value.seen }) where total > limitBytes {
            do {
                try await manager.evictItem(identifier: identifier)
                total -= entry.bytes
                sizes[identifier] = nil
                evicted += 1
            } catch {
                busy += 1
                // EBUSY (open, e.g. still being copied) is expected and retried
                // next pass; anything else means files can't be evicted at all.
                let nsError = error as NSError
                if !(nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EBUSY)) {
                    log.error("Cache \(name, privacy: .public): evicting failed: \(nsError.domain, privacy: .public) \(nsError.code) \(nsError.localizedDescription, privacy: .public)")
                }
            }
        }
        known[name] = sizes
        log.info("Cache \(name, privacy: .public): evicted \(evicted), busy \(busy), now \(total / 1_048_576) MB (limit \(limitBytes / 1_048_576) MB)")
    }

    /// Bytes the item's local copy occupies on disk (0 if it can't be found).
    private static func localSize(_ manager: NSFileProviderManager, _ identifier: NSFileProviderItemIdentifier) async -> Int64 {
        guard let url = try? await manager.getUserVisibleURL(for: identifier),
              let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else {
            return 0
        }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    /// All materialized items of a domain (the system tracks this set).
    private static func materializedItems(_ manager: NSFileProviderManager) async throws -> [NSFileProviderItem] {
        let enumerator = manager.enumeratorForMaterializedItems()
        defer { enumerator.invalidate() }
        var items: [NSFileProviderItem] = []
        var page: NSFileProviderPage? = NSFileProviderPage(Data())
        while let current = page {
            let collector = Collector()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                collector.completion = { continuation.resume(with: $0) }
                enumerator.enumerateItems(for: collector, startingAt: current)
            }
            items += collector.items
            page = collector.nextPage
        }
        return items
    }
}

private final class Collector: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    // Written by the enumerator's callbacks, read after `completion` fires.
    var items: [NSFileProviderItem] = []
    var nextPage: NSFileProviderPage?
    var completion: ((Result<Void, Error>) -> Void)?

    func didEnumerate(_ updatedItems: [NSFileProviderItem]) { items += updatedItems }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        self.nextPage = nextPage
        completion?(.success(()))
        completion = nil
    }

    func finishEnumeratingWithError(_ error: Error) {
        completion?(.failure(error))
        completion = nil
    }
}
