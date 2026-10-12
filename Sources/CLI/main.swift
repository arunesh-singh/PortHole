import Foundation

// porthole: exercises the device backends directly, without the app or Finder.
//
//   porthole devices
//   porthole <device> ls|stat|mkdir|rm <path>
//   porthole <device> pull <path> <local>
//   porthole <device> push <local> <path>
//   porthole <device> mv <from> <to>
//
// <device> is "adb" (first adb device), "adb:<serial>", or "mtp" (first MTP device).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("porthole: \(message)\n".utf8))
    exit(1)
}

func adbPath() -> String {
    if let path = ProcessInfo.processInfo.environment["ADB"] ?? ADBHost.locateADB() { return path }
    fail("adb not found (set ADB=/path/to/adb)")
}

func adbRecords() throws -> [ADBHost.DeviceRecord] {
    try ADBHost.ensureServer(adbPath: adbPath())
    return try ADBHost.devices()
}

/// Opens MTP devices once and waits for the first scan.
func mtpStates() -> [MTPMonitor.DeviceState] {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: [MTPMonitor.DeviceState] = []
    let monitor = MTPMonitor(policy: MTPOpenPolicy()) { states in
        result = states
        semaphore.signal()
    }
    monitor.start()
    _ = semaphore.wait(timeout: .now() + 20)
    return result
}

func openBackend(_ spec: String) throws -> DeviceBackend {
    if spec == "mtp" {
        for state in mtpStates() {
            switch state {
            case .ready(let backend): return backend
            case .failed(_, let name, let message): fail("\(name): \(message)")
            }
        }
        fail("no MTP device found")
    }
    let records = try adbRecords().filter { $0.state == "device" }
    if spec == "adb" {
        guard let first = records.first else { fail("no authorized adb device") }
        return try ADBBackend(record: first)
    }
    guard spec.hasPrefix("adb:") else { fail("unknown device \(spec)") }
    let serial = String(spec.dropFirst(4))
    guard let record = records.first(where: { $0.serial == serial }) else { fail("adb device \(serial) not found") }
    return try ADBBackend(record: record)
}

func describe(_ entry: Entry) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(entry.mtime))
    let kind = entry.isVolume ? "vol" : entry.isDirectory ? "dir" : "file"
    return String(format: "%-4@ %12llu  %@  %@", kind as NSString, entry.size,
                  ISO8601DateFormatter().string(from: date) as NSString, entry.name as NSString)
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    guard let first = args.first else { fail("usage: porthole devices | <device> <command> …") }
    if first == "devices" {
        for record in (try? adbRecords()) ?? [] {
            print("adb:\(record.serial)\t\(record.state)\t\(record.model ?? "")")
        }
        for state in mtpStates() {
            switch state {
            case .ready(let backend): print("mtp\tready\t\(backend.info.name) (serial \(backend.info.serial))")
            case .failed(_, let name, let message): print("mtp\tfailed\t\(name): \(message)")
            }
        }
        exit(0)
    }
    guard args.count >= 3 else { fail("missing arguments") }
    let backend = try openBackend(first)
    defer { backend.close() }
    let path = VPath(args[2])
    switch args[1] {
    case "ls":
        for entry in try backend.list(path) { print(describe(entry)) }
    case "stat":
        print(describe(try backend.stat(path)))
    case "pull":
        guard args.count == 4 else { fail("pull <path> <local>") }
        try backend.download(path, to: URL(fileURLWithPath: args[3]))
    case "push":
        guard args.count == 4 else { fail("push <local> <path>") }
        print(describe(try backend.upload(from: URL(fileURLWithPath: args[2]), to: VPath(args[3]))))
    case "mkdir":
        print(describe(try backend.makeDirectory(path)))
    case "rm":
        try backend.delete(path)
    case "mv":
        guard args.count == 4 else { fail("mv <from> <to>") }
        print(describe(try backend.move(path, to: VPath(args[3]))))
    default:
        fail("unknown command \(args[1])")
    }
} catch {
    fail(error.localizedDescription)
}
