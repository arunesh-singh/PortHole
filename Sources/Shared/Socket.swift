import Darwin
import Foundation

struct SocketError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    static func errno(_ what: String) -> SocketError {
        SocketError("\(what): \(String(cString: strerror(Darwin.errno)))")
    }
    var errorDescription: String? { message }
}

/// Minimal blocking TCP socket, used for app↔extension IPC on loopback and for
/// talking to the local adb server. Every call blocks; callers run it off the
/// main thread.
final class Socket {
    let fd: Int32
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    /// Shuts down both directions, unblocking any thread stuck in read().
    func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }

    static func connectTCP(host: String = "127.0.0.1", port: UInt16) throws -> Socket {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.errno("socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let err = SocketError.errno("connect \(host):\(port)")
            Darwin.close(fd)
            throw err
        }
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        return Socket(fd: fd)
    }

    func setReadTimeout(seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { try write(raw: $0) }
    }

    func write(raw buf: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < buf.count {
            let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.errno("write")
            }
            offset += n
        }
    }

    /// Reads exactly `count` bytes into `buf`; throws on EOF.
    func read(into buf: UnsafeMutableRawBufferPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.read(fd, buf.baseAddress! + offset, count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.errno("read")
            }
            if n == 0 { throw SocketError("connection closed") }
            offset += n
        }
    }

    func read(count: Int) throws -> Data {
        var data = Data(count: count)
        if count > 0 {
            try data.withUnsafeMutableBytes { try read(into: $0, count: count) }
        }
        return data
    }

    /// Reads until EOF.
    func readToEnd() throws -> Data {
        var result = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.errno("read")
            }
            if n == 0 { return result }
            result.append(buf, count: n)
        }
    }

    // MARK: Length-prefixed JSON frames (app ↔ extension)

    func sendFrame<T: Encodable>(_ value: T) throws {
        let body = try JSONEncoder().encode(value)
        var header = UInt32(body.count).bigEndian
        try withUnsafeBytes(of: &header) { try write(raw: $0) }
        try write(body)
    }

    func receiveFrame<T: Decodable>(_ type: T.Type) throws -> T {
        let header = try read(count: 4)
        let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length <= 64 * 1024 * 1024 else { throw SocketError("frame too large: \(length)") }
        return try JSONDecoder().decode(T.self, from: try read(count: Int(length)))
    }
}
