import CMTP
import Foundation
import IOKit
import IOKit.usb
import os

/// USB serials of phones the MTP monitor must leave alone (they are in use
/// over ADB). Opening MTP takes the phone from macOS's camera service and can
/// reset its USB connection, which knocks ADB offline; so phones reachable over
/// ADB are never opened over MTP, not merely hidden. Thread-safe.
final class MTPOpenPolicy: @unchecked Sendable {
    private let lock = NSLock()  // guards `blocked` and `delay`
    private var blocked: Set<String> = []
    private var delay: TimeInterval = 1.5

    /// How long to wait after a USB attach (or at start) before opening MTP.
    /// Longer when ADB is preferred, so adb can report the phone first.
    var attachDelay: TimeInterval {
        get { lock.withLock { delay } }
        set { lock.withLock { delay = newValue } }
    }

    func isBlocked(_ serial: String?) -> Bool {
        guard let serial else { return false }
        return lock.withLock { blocked.contains(serial) }
    }

    /// Returns the serials that are newly blocked and newly unblocked.
    func setBlocked(_ serials: Set<String>) -> (added: Set<String>, removed: Set<String>) {
        lock.withLock {
            defer { blocked = serials }
            return (serials.subtracting(blocked), blocked.subtracting(serials))
        }
    }
}

/// Watches USB hot-plug events via IOKit and opens MTP devices with libmtp.
final class MTPMonitor: @unchecked Sendable {
    enum DeviceState: Sendable {
        case ready(MTPBackend)
        /// Seen on USB but could not be opened (usually claimed by another app).
        case failed(usbKey: String, name: String, message: String)
    }

    private let log = Logger(subsystem: PortHoleConstants.logSubsystem, category: "mtp")
    private let policy: MTPOpenPolicy
    private let onChange: @Sendable ([DeviceState]) -> Void
    private let notifyQueue = DispatchQueue(label: "PortHole.usb-notify")
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pendingScan: DispatchWorkItem?

    // On MTPQueue.
    private var opened: [String: MTPBackend] = [:]
    private var failed: [String: (name: String, message: String)] = [:]
    /// Devices whose session died, by device ID, while they are being reopened.
    /// They stay in the emitted state (dead, so calls fail fast) so the app
    /// keeps the Finder location mounted until the replacement arrives.
    private var recovering: [String: (backend: MTPBackend, deadline: Date)] = [:]
    private static let recoveryWindow: TimeInterval = 15
    private var enabled = false

    init(policy: MTPOpenPolicy, onChange: @escaping @Sendable ([DeviceState]) -> Void) {
        self.policy = policy
        self.onChange = onChange
    }

    func start() {
        MTPQueue.queue.async { self.enabled = true }
        notifyQueue.async { self.installNotifications() }
        scheduleScan(after: policy.attachDelay)
    }

    /// Closes every device so other apps can use them.
    func stop() {
        MTPQueue.queue.async {
            self.enabled = false
            for backend in self.opened.values { backend.closeOnQueue() }
            self.opened = [:]
            self.failed = [:]
            self.recovering = [:]
            self.emit()
        }
        notifyQueue.async {
            self.iterators.forEach { IOObjectRelease($0) }
            self.iterators = []
            if let port = self.port { IONotificationPortDestroy(port) }
            self.port = nil
        }
    }

    /// Forgets failures and tries to open everything again.
    func retry() {
        MTPQueue.queue.async { self.failed = [:] }
        scheduleScan(after: 0)
    }

    /// Closes open devices the policy now blocks (the phone appeared over ADB).
    func closeBlocked() {
        MTPQueue.queue.async {
            for (key, backend) in self.opened where self.policy.isBlocked(backend.info.serial) {
                self.log.info("Releasing \(backend.info.name, privacy: .public): in use over ADB")
                backend.closeOnQueue()
                self.opened[key] = nil
            }
            self.recovering = self.recovering.filter { !self.policy.isBlocked($0.value.backend.info.serial) }
            self.emit()
        }
    }

    /// Retries after killing ptpcamerad (see `killCameraAgent`).
    func releaseFromSystemCameraService() {
        Self.killCameraAgent()
        retry()
    }

    /// macOS's ptpcamerad (Image Capture's agent) claims the MTP interface of
    /// every Android phone as soon as it attaches, which makes libmtp's claim
    /// fail. It ignores SIGTERM, so it is killed outright; the system relaunches
    /// it on demand, and it cannot take the phone back while PortHole holds it.
    private static func killCameraAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-KILL", "ptpcamerad"]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: IOKit hot-plug

    private func installNotifications() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, notifyQueue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<MTPMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MTPMonitor.drain(iterator)
            // Phones re-enumerate a moment after attach and when the USB mode changes.
            monitor.scheduleScan(after: monitor.policy.attachDelay)
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let matching = IOServiceMatching("IOUSBHostDevice")
            if IOServiceAddMatchingNotification(port, type, matching, callback, refcon, &iterator) == KERN_SUCCESS {
                Self.drain(iterator)
                iterators.append(iterator)
            }
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    private func scheduleScan(after delay: TimeInterval) {
        notifyQueue.async {
            self.pendingScan?.cancel()
            let work = DispatchWorkItem { MTPQueue.queue.async { self.scan() } }
            self.pendingScan = work
            self.notifyQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: Scanning (on MTPQueue)

    private func scan() {
        MTPQueue.ensureInitialized()
        guard enabled else { return }
        var rawList: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let status = LIBMTP_Detect_Raw_Devices(&rawList, &count)
        defer { free(rawList) }

        var present: [String: LIBMTP_raw_device_t] = [:]
        if status == LIBMTP_ERROR_NONE, let rawList {
            for index in 0..<Int(count) {
                let raw = rawList[index]
                present["\(raw.bus_location)-\(raw.devnum)"] = raw
            }
        }

        for (key, backend) in opened where present[key] == nil {
            log.info("MTP device detached: \(backend.info.name, privacy: .public)")
            backend.closeOnQueue()
            opened[key] = nil
        }
        failed = failed.filter { present[$0.key] != nil }
        let now = Date()
        for (id, entry) in recovering where entry.deadline < now {
            log.error("Could not reopen \(id, privacy: .public) after its session was lost")
            recovering[id] = nil
        }

        let fresh = present.filter { key, raw in
            opened[key] == nil && failed[key] == nil
                && !policy.isBlocked(MTPBackend.usbSerial(bus: raw.bus_location, address: raw.devnum))
        }
        // Open immediately after freeing the phone, before ptpcamerad relaunches.
        if !fresh.isEmpty { Self.killCameraAgent() }
        for (key, raw) in fresh {
            let copy = UnsafeMutablePointer<LIBMTP_raw_device_t>.allocate(capacity: 1)
            copy.initialize(to: raw)
            do {
                let backend = try MTPBackend(raw: copy, usbKey: key)
                backend.onSessionLost = { [weak self] lost in self?.sessionLost(lost) }
                log.info("MTP device opened: \(backend.info.name, privacy: .public)")
                opened[key] = backend
                recovering[backend.info.id] = nil
            } catch {
                let vendor = raw.device_entry.vendor.map { String(cString: $0) }
                let product = raw.device_entry.product.map { String(cString: $0) }
                let name = [vendor, product].compactMap { $0 }.joined(separator: " ")
                failed[key] = (name.isEmpty ? "Android device" : name,
                               "Couldn't open the phone over MTP. Unlock it, choose “File transfer”, and quit apps that may hold it (Android File Transfer, OpenMTP).")
            }
        }
        emit()
    }

    /// An operation found the MTP session dead. Typical cause: opening a photo
    /// in Preview makes ptpcamerad try the phone, fail because we hold it, and
    /// reset its USB connection. Close the dead handle and reopen the device.
    private func sessionLost(_ backend: MTPBackend) {
        guard enabled, opened[backend.usbKey] === backend else { return }
        log.error("MTP session lost for \(backend.info.name, privacy: .public); reopening")
        opened[backend.usbKey] = nil
        backend.closeOnQueue()
        recovering[backend.info.id] = (backend, Date().addingTimeInterval(Self.recoveryWindow))
        // The phone may re-enumerate after the reset; try soon, and once more
        // after the window to drop it if it never came back.
        scheduleScan(after: 1.5)
        notifyQueue.asyncAfter(deadline: .now() + Self.recoveryWindow + 1) { [weak self] in
            MTPQueue.queue.async { self?.scan() }
        }
    }

    private func emit() {
        let states: [DeviceState] = opened.values.map { .ready($0) }
            + recovering.values.map { .ready($0.backend) }
            + failed.map { .failed(usbKey: $0.key, name: $0.value.name, message: $0.value.message) }
        onChange(states)
    }
}
