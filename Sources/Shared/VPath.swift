import Foundation

/// Device-relative virtual path ("/", "/Internal storage/DCIM/a.jpg").
/// Always absolute, never has a trailing slash (except the root itself).
struct VPath: Hashable, Sendable, CustomStringConvertible {
    let components: [String]

    static let root = VPath(components: [])

    init(components: [String]) {
        self.components = components
    }

    init(_ string: String) {
        components = string.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    var isRoot: Bool { components.isEmpty }
    var isVolumeRoot: Bool { components.count == 1 }
    var name: String { components.last ?? "" }
    var volume: String? { components.first }
    /// Components below the volume.
    var inner: [String] { Array(components.dropFirst()) }
    var parent: VPath { VPath(components: Array(components.dropLast())) }
    var string: String { "/" + components.joined(separator: "/") }
    var description: String { string }

    func appending(_ name: String) -> VPath { VPath(components: components + [name]) }

    /// True if `self` equals `other` or lies beneath it.
    func isWithin(_ other: VPath) -> Bool {
        components.count >= other.components.count
            && Array(components.prefix(other.components.count)) == other.components
    }
}
