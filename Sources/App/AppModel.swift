import AppKit
import Observation
import ServiceManagement
import os

/// Settings keys shared with SettingsView's @AppStorage.
enum SettingsKey {
    static let enableADB = "enableADB"
    static let enableMTP = "enableMTP"
    static let preferADB = "preferADB"
    static let adbPath = "adbPath"
    static let refreshInterval = "refreshInterval"
    static let openFinderOnMount = "openFinderOnMount"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enableADB: true,
            enableMTP: true,
            preferADB: true,
            adbPath: "",
            refreshInterval: 30,
            openFinderOnMount: false,
        ])
    }
}

struct DeviceRow: Identifiable, Hashable {
    enum Status: Hashable {
        case mounted
        case unmounted
        case connecting
        /// Same phone is mounted over ADB.
        case duplicate
        case needsAction(String)
    }

    var id: String
    var name: String
    var transport: TransportKind
    var status: Status
    /// adb serial for network devices (used by Disconnect).
    var networkSerial: String?
    /// Failed MTP attachment (offers retry / release).
    var isMTPFailure = false
}

@MainActor
@Observable
final class AppModel {
    private let log = Logger(subsystem: PortHoleConstants.logSubsystem, category: "app")
    @ObservationIgnored let registry = DeviceRegistry()
    @ObservationIgnored private let domains = DomainController()
    @ObservationIgnored private var ipc: IPCServer?
    @ObservationIgnored private var adbTracker: ADBTracker?
    @ObservationIgnored private var mtpMonitor: MTPMonitor?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var reconcileAgain = false
    @ObservationIgnored private var shuttingDown = false

    // ADB state
    private var adbRecords: [ADBHost.DeviceRecord] = []
    private var adbBackends: [String: ADBBackend] = [:]
    private var adbConnecting: Set<String> = []
    private var adbFailures: [String: String] = [:]
    private(set) var adbProblem: String?

    // MTP state
    private var mtpStates: [MTPMonitor.DeviceState] = []

    private var userUnmounted: Set<String> = []
    private(set) var mountedIDs: Set<String> = []
    private(set) var startupError: String?
    /// Finder locations stay empty until the user enables the extension.
    private(set) var needsExtensionApproval = false
    @ObservationIgnored private var approvalPolling = false

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log.error("Login item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private var defaults: UserDefaults { .standard }

    func start() {
        SettingsKey.registerDefaults()
        do {
            let server = IPCServer(registry: registry)
            try server.start()
            ipc = server
        } catch {
            startupError = "Could not start the file service: \(error.localizedDescription)"
        }
        applySettings()
        // Give devices a moment to show up before dropping domains from the last run.
        Task {
            try? await Task.sleep(for: .seconds(6))
            await domains.removeStaleDomains()
        }
    }

    /// Called on quit: unmount everything so Finder does not show dead locations.
    func shutdown() async {
        // Stopping the transports emits "no devices"; without this flag the
        // resulting reconcile pass could re-add a domain while we remove them.
        shuttingDown = true
        adbTracker?.stop()
        mtpMonitor?.stop()
        while reconciling { try? await Task.sleep(for: .milliseconds(50)) }
        await domains.removeAll()
    }

    /// Starts/stops transports and the refresh timer to match settings.
    func applySettings() {
        if defaults.bool(forKey: SettingsKey.enableADB) {
            if adbTracker == nil {
                let tracker = ADBTracker(
                    adbPath: { Self.resolvedADBPath() },
                    onChange: { [weak self] records in Task { @MainActor in self?.handleADB(records) } },
                    onError: { [weak self] problem in Task { @MainActor in self?.adbProblem = problem } })
                adbTracker = tracker
                tracker.start()
            }
        } else if let tracker = adbTracker {
            tracker.stop()
            adbTracker = nil
            adbProblem = nil
            handleADB([])
        }

        if defaults.bool(forKey: SettingsKey.enableMTP) {
            if mtpMonitor == nil {
                let monitor = MTPMonitor { [weak self] states in Task { @MainActor in self?.handleMTP(states) } }
                mtpMonitor = monitor
                monitor.start()
            }
        } else if let monitor = mtpMonitor {
            monitor.stop()
            mtpMonitor = nil
        }

        refreshTimer?.invalidate()
        refreshTimer = nil
        let interval = defaults.integer(forKey: SettingsKey.refreshInterval)
        if interval > 0 {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
                Task { @MainActor in self?.domains.refreshAll() }
            }
        }
        reconcile()
    }

    nonisolated static func resolvedADBPath() -> String? {
        let configured = UserDefaults.standard.string(forKey: SettingsKey.adbPath) ?? ""
        return configured.isEmpty ? ADBHost.locateADB() : configured
    }

    // MARK: Device events

    private func handleADB(_ records: [ADBHost.DeviceRecord]) {
        adbRecords = records
        let ready = Set(records.filter { $0.state == "device" }.map(\.serial))
        for (serial, backend) in adbBackends where !ready.contains(serial) {
            registry.remove(backend.info.id)
            adbBackends[serial] = nil
        }
        adbFailures = adbFailures.filter { ready.contains($0.key) }
        for record in records where record.state == "device"
            && adbBackends[record.serial] == nil && !adbConnecting.contains(record.serial)
            && adbFailures[record.serial] == nil {
            connectADB(record)
        }
        reconcile()
    }

    private func connectADB(_ record: ADBHost.DeviceRecord) {
        adbConnecting.insert(record.serial)
        Task.detached {
            let result = Result { try ADBBackend(record: record) }
            await MainActor.run {
                self.adbConnecting.remove(record.serial)
                // The device may have gone away while connecting.
                guard self.adbRecords.contains(where: { $0.serial == record.serial && $0.state == "device" }) else { return }
                switch result {
                case .success(let backend):
                    self.adbBackends[record.serial] = backend
                    self.registry.add(backend)
                case .failure(let error):
                    self.adbFailures[record.serial] = error.localizedDescription
                }
                self.reconcile()
            }
        }
    }

    private func handleMTP(_ states: [MTPMonitor.DeviceState]) {
        let old = Set(readyMTP.map(\.info.id))
        mtpStates = states
        let current = readyMTP
        for id in old.subtracting(current.map(\.info.id)) { registry.remove(id) }
        current.forEach(registry.add)
        reconcile()
    }

    private var readyMTP: [MTPBackend] {
        mtpStates.compactMap { if case .ready(let backend) = $0 { backend } else { nil } }
    }

    private var adbHardwareSerials: Set<String> {
        Set(adbBackends.values.map(\.info.serial))
    }

    private func isDuplicate(_ backend: MTPBackend) -> Bool {
        defaults.bool(forKey: SettingsKey.preferADB) && adbHardwareSerials.contains(backend.info.serial)
    }

    // MARK: Mounting

    private var desiredMounts: [DeviceInfo] {
        let adb = adbBackends.values.map(\.info)
        let mtp = readyMTP.filter { !isDuplicate($0) }.map(\.info)
        return (adb + mtp).filter { !userUnmounted.contains($0.id) }
    }

    /// Brings File Provider domains in line with connected devices. Serialized:
    /// calls during a running pass trigger one more pass.
    private func reconcile() {
        guard !shuttingDown else { return }
        guard !reconciling else {
            reconcileAgain = true
            return
        }
        reconciling = true
        Task {
            repeat {
                reconcileAgain = false
                let before = Set(domains.mounted.keys)
                await domains.sync(desired: desiredMounts)
                mountedIDs = Set(domains.mounted.keys)
                if defaults.bool(forKey: SettingsKey.openFinderOnMount) {
                    for id in mountedIDs.subtracting(before) { await domains.openInFinder(id) }
                }
            } while reconcileAgain
            reconciling = false
            await checkExtensionApproval()
        }
    }

    /// Re-checks every few seconds while approval is pending so the banner clears
    /// as soon as the user flips the switch in System Settings.
    private func checkExtensionApproval() async {
        needsExtensionApproval = await domains.needsUserApproval()
        guard needsExtensionApproval, !approvalPolling else { return }
        approvalPolling = true
        while needsExtensionApproval {
            try? await Task.sleep(for: .seconds(3))
            needsExtensionApproval = await domains.needsUserApproval()
        }
        approvalPolling = false
        domains.refreshAll()
    }

    func openExtensionSettings() {
        DomainController.openExtensionSettings()
    }

    // MARK: UI

    var rows: [DeviceRow] {
        var rows: [DeviceRow] = []
        for record in adbRecords {
            let id = DeviceInfo.makeID(.adb, record.serial)
            let backend = adbBackends[record.serial]
            let status: DeviceRow.Status
            switch record.state {
            case "device":
                if let failure = adbFailures[record.serial] {
                    status = .needsAction(failure)
                } else if backend == nil {
                    status = .connecting
                } else {
                    status = mountedIDs.contains(id) ? .mounted : userUnmounted.contains(id) ? .unmounted : .connecting
                }
            case "unauthorized":
                status = .needsAction("Unlock the phone and allow USB debugging for this Mac.")
            case "authorizing", "connecting":
                status = .connecting
            default:
                status = .needsAction("Device is \(record.state).")
            }
            rows.append(DeviceRow(id: id,
                                  name: backend?.info.name ?? record.model ?? record.serial,
                                  transport: .adb,
                                  status: status,
                                  networkSerial: record.isNetwork ? record.serial : nil))
        }
        for state in mtpStates {
            switch state {
            case .ready(let backend):
                let id = backend.info.id
                let status: DeviceRow.Status = isDuplicate(backend) ? .duplicate
                    : mountedIDs.contains(id) ? .mounted
                    : userUnmounted.contains(id) ? .unmounted : .connecting
                rows.append(DeviceRow(id: id, name: backend.info.name, transport: .mtp, status: status))
            case let .failed(usbKey, name, message):
                rows.append(DeviceRow(id: "mtp-failed-\(usbKey)", name: name, transport: .mtp,
                                      status: .needsAction(message), isMTPFailure: true))
            }
        }
        return rows.sorted { ($0.name, $0.transport.rawValue) < ($1.name, $1.transport.rawValue) }
    }

    func open(_ id: String) {
        Task { await domains.openInFinder(id) }
    }

    func refresh(_ id: String) {
        domains.refresh(id)
    }

    func setMounted(_ id: String, _ mounted: Bool) {
        if mounted { userUnmounted.remove(id) } else { userUnmounted.insert(id) }
        reconcile()
    }

    func retry(_ row: DeviceRow) {
        if row.isMTPFailure {
            mtpMonitor?.retry()
        } else {
            adbFailures = adbFailures.filter { DeviceInfo.makeID(.adb, $0.key) != row.id }
            handleADB(adbRecords)
        }
    }

    func releaseFromCameraService() {
        let monitor = mtpMonitor
        Task.detached { monitor?.releaseFromSystemCameraService() }
    }

    // MARK: Wireless debugging

    func connectWiFi(_ address: String) async -> Result<String, Error> {
        await Task.detached { Result { try ADBHost.connect(address) } }.value
    }

    func pairWiFi(_ address: String, code: String) async -> Result<String, Error> {
        await Task.detached { Result { try ADBHost.pair(address, code: code) } }.value
    }

    func disconnectWiFi(_ serial: String) {
        Task.detached { _ = try? ADBHost.disconnect(serial) }
    }
}
