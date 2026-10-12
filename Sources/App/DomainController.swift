import AppKit
import FileProvider
import os

/// One File Provider domain per mounted device; the domain identifier is DeviceInfo.id.
@MainActor
final class DomainController {
    private let log = Logger(subsystem: PortHoleConstants.logSubsystem, category: "domains")
    private(set) var mounted: [String: DeviceInfo] = [:]

    /// Adds domains for `desired` devices and removes every other domain.
    func sync(desired: [DeviceInfo]) async {
        let wanted = Dictionary(desired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in mounted.keys where wanted[id] == nil {
            await remove(id)
        }
        for (id, info) in wanted where mounted[id] == nil {
            await add(info)
        }
    }

    private func add(_ info: DeviceInfo) async {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        // A domain that survived (e.g. the app was killed) keeps its identifier
        // database; a brand-new domain must not inherit stale identifiers.
        if !domains.contains(where: { $0.identifier.rawValue == info.id }) {
            PortHoleConstants.resetDomainState(domainID: info.id)
        }
        let taken = Set(domains.filter { $0.identifier.rawValue != info.id }.map(\.displayName))
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(info.id),
                                          displayName: Self.uniqueName(for: info, taken: taken))
        do {
            try await NSFileProviderManager.add(domain)
            mounted[info.id] = info
            log.info("Mounted \(info.id, privacy: .public)")
        } catch {
            log.error("Adding domain \(info.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func remove(_ id: String) async {
        mounted[id] = nil
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id), displayName: id)
        do {
            _ = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
            PortHoleConstants.resetDomainState(domainID: id)
            log.info("Unmounted \(id, privacy: .public)")
        } catch {
            log.error("Removing domain \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes domains left over from a previous run that are not mounted now.
    func removeStaleDomains() async {
        guard let domains = try? await NSFileProviderManager.domains() else { return }
        for domain in domains where mounted[domain.identifier.rawValue] == nil {
            _ = try? await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
            PortHoleConstants.resetDomainState(domainID: domain.identifier.rawValue)
        }
    }

    /// Unmounts everything on quit. Removes each domain individually:
    /// `removeAllDomains()` reports success but leaves domains in place
    /// (observed on macOS 26/27), while per-domain removal works.
    func removeAll() async {
        mounted = [:]
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        for domain in domains {
            do {
                _ = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
            } catch {
                log.error("Removing \(domain.identifier.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            PortHoleConstants.resetDomainState(domainID: domain.identifier.rawValue)
        }
        log.info("Removed \(domains.count) domain(s)")
    }

    func openInFinder(_ id: String) async {
        guard let manager = manager(id) else { return }
        // The domain's folder appears shortly after it is added.
        for _ in 0..<20 {
            if let url = try? await manager.getUserVisibleURL(for: .rootContainer) {
                NSWorkspace.shared.open(url)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        log.error("No user-visible URL for \(id, privacy: .public)")
    }

    /// Asks the extension to re-check device contents for changes made on the phone.
    func refresh(_ id: String) {
        manager(id)?.signalEnumerator(for: .workingSet) { _ in }
    }

    func refreshAll() {
        mounted.keys.forEach(refresh)
    }

    private func manager(_ id: String) -> NSFileProviderManager? {
        guard mounted[id] != nil else { return nil }
        return NSFileProviderManager(for: NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id),
                                                               displayName: id))
    }

    /// Finder folders are named after the display name, so it must be unique:
    /// the same phone over ADB and MTP, or two phones of the same model.
    static func uniqueName(for info: DeviceInfo, taken: Set<String>) -> String {
        let candidates = [
            info.name,
            "\(info.name) (\(info.transport.rawValue.uppercased()))",
            "\(info.name) (\(info.transport.rawValue.uppercased()) \(info.serial.suffix(4)))",
        ]
        return candidates.first { !taken.contains($0) } ?? "\(info.name) (\(info.id))"
    }

    /// macOS 15+ requires the user to enable File Provider extensions in
    /// System Settings; until then mounted domains stay empty.
    func needsUserApproval() async -> Bool {
        guard #available(macOS 15.0, *), !mounted.isEmpty,
              let domains = try? await NSFileProviderManager.domains() else { return false }
        return domains.contains { !$0.userEnabled }
    }

    static func openExtensionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fileprovider-nonui")!
        NSWorkspace.shared.open(url)
    }
}
