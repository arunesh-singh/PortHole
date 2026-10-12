import CMTP
import Foundation
import IOKit
import IOKit.usb
import os

/// Watches USB hot-plug events via IOKit and opens MTP devices with libmtp.
final class MTPMonitor: @unchecked Sendable {
    enum DeviceState: Sendable {
        case ready(MTPBackend)
        /// Seen on USB but could not be opened (usually claimed by another app).
        case failed(usbKey: String, name: String, message: String)
    }

    private let log = Logger(subsystem: PortHoleConstants.logSubsystem, category: "mtp")
    private let onChange: @Sendable ([DeviceState]) -> Void
    private let notifyQueue = DispatchQueue(label: "PortHole.usb-notify")
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pendingScan: DispatchWorkItem?

    // On MTPQueue.
    private var opened: [String: MTPBackend] = [:]
    private var failed: [String: (name: String, message: String)] = [:]
    private var enabled = false

    init(onChange: @escaping @Sendable ([DeviceState]) -> Void) {
        self.onChange = onChange
    }

    func start() {
        MTPQueue.queue.async { self.enabled = true }
        notifyQueue.async { self.installNotifications() }
        scheduleScan(after: 0)
    }

    /// Closes every device so other apps can use them.
    func stop() {
        MTPQueue.queue.async {
            self.enabled = false
            for backend in self.opened.values { backend.closeOnQueue() }
            self.opened = [:]
            self.failed = [:]
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
            monitor.scheduleScan(after: 1.5)
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

        let fresh = present.filter { opened[$0.key] == nil && failed[$0.key] == nil }
        // Open immediately after freeing the phone, before ptpcamerad relaunches.
        if !fresh.isEmpty { Self.killCameraAgent() }
        for (key, raw) in fresh {
            let copy = UnsafeMutablePointer<LIBMTP_raw_device_t>.allocate(capacity: 1)
            copy.initialize(to: raw)
            do {
                let backend = try MTPBackend(raw: copy, usbKey: key)
                log.info("MTP device opened: \(backend.info.name, privacy: .public)")
                opened[key] = backend
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

    private func emit() {
        let states: [DeviceState] = opened.values.map { .ready($0) }
            + failed.map { .failed(usbKey: $0.key, name: $0.value.name, message: $0.value.message) }
        onChange(states)
    }
}
