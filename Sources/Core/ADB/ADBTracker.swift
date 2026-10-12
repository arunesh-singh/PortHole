import Foundation
import os

/// Streams the adb server's device list (`host:track-devices-l`), restarting the
/// server and reconnecting when it goes away.
final class ADBTracker: @unchecked Sendable {
    private let log = Logger(subsystem: PortHoleConstants.logSubsystem, category: "adb")
    private let adbPath: () -> String?
    private let onChange: @Sendable ([ADBHost.DeviceRecord]) -> Void
    private let onError: @Sendable (String?) -> Void
    private let lock = NSLock()
    private var running = false
    private var socket: Socket?
    private var thread: Thread?

    /// - Parameters:
    ///   - adbPath: resolved on every (re)start so settings changes apply.
    ///   - onChange: full device list after every change, on a background thread.
    ///   - onError: a user-facing problem, or nil once tracking works again.
    init(adbPath: @escaping () -> String?,
         onChange: @escaping @Sendable ([ADBHost.DeviceRecord]) -> Void,
         onError: @escaping @Sendable (String?) -> Void) {
        self.adbPath = adbPath
        self.onChange = onChange
        self.onError = onError
    }

    func start() {
        lock.withLock {
            guard !running else { return }
            running = true
            let thread = Thread { [weak self] in self?.loop() }
            thread.name = "PortHole.ADBTracker"
            self.thread = thread
            thread.start()
        }
    }

    func stop() {
        lock.withLock {
            running = false
            socket?.shutdown()
        }
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func loop() {
        while isRunning {
            do {
                guard let adb = adbPath() else {
                    throw WireError(.deviceUnavailable, "adb not found. Install Android platform-tools (brew install android-platform-tools) or set its path in Settings.")
                }
                try ADBHost.ensureServer(adbPath: adb)
                let socket = try ADBHost.request("host:track-devices-l")
                lock.withLock { self.socket = socket }
                onError(nil)
                while isRunning {
                    onChange(ADBHost.parseDevices(try ADBHost.readLengthPrefixed(socket)))
                }
            } catch {
                guard isRunning else { break }
                log.error("adb tracking: \(error.localizedDescription, privacy: .public)")
                onError(error.localizedDescription)
                onChange([])
                Thread.sleep(forTimeInterval: 3)
            }
        }
        lock.withLock { socket = nil }
    }
}
