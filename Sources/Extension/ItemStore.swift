import FileProvider
import Foundation
import SQLite3

/// Persistent identifier ↔ path map plus a snapshot of every folder the system
/// has enumerated. Identifiers survive renames and extension restarts; the
/// snapshot lets the working-set enumerator report changes made on the phone.
final class ItemStore {
    struct Row {
        var identifier: NSFileProviderItemIdentifier
        var path: VPath
        var entry: Entry
    }

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(domainID: String) throws {
        let url = PortHoleConstants.databaseURL(domainID: domainID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw WireError(.io, "Cannot open \(url.path)")
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS items(
                id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, parent TEXT NOT NULL,
                is_dir INTEGER NOT NULL, size INTEGER NOT NULL, mtime INTEGER NOT NULL, is_volume INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS items_parent ON items(parent);
            CREATE TABLE IF NOT EXISTS listed(path TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            """)
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw WireError(.io, "SQLite: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private enum Value {
        case text(String), int(Int64)
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Value] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            switch value {
            case .text(let text): sqlite3_bind_text(statement, Int32(index + 1), text, -1, Self.transient)
            case .int(let int): sqlite3_bind_int64(statement, Int32(index + 1), int)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row?(statement)
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    /// Runs `body` atomically; nested calls join the outermost transaction.
    private func transaction<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        transactionDepth += 1
        if transactionDepth == 1 { run("BEGIN IMMEDIATE") }
        do {
            let result = try body()
            transactionDepth -= 1
            if transactionDepth == 0 { run("COMMIT") }
            return result
        } catch {
            transactionDepth -= 1
            if transactionDepth == 0 { run("ROLLBACK") }
            throw error
        }
    }

    /// WHERE clause matching `path` and everything beneath it.
    private func subtree(_ path: VPath, column: String = "path") -> (String, [Value]) {
        if path.isRoot { return ("1", []) }
        let prefix = path.string + "/"
        return ("(\(column) = ? OR substr(\(column), 1, ?) = ?)",
                [.text(path.string), .int(Int64(prefix.utf8.count)), .text(prefix)])
    }

    // MARK: Identifiers

    func identifier(for path: VPath) -> NSFileProviderItemIdentifier {
        if path.isRoot { return .rootContainer }
        return transaction {
            var found: String?
            run("SELECT id FROM items WHERE path = ?", [.text(path.string)]) { found = Self.text($0, 0) }
            if let found { return NSFileProviderItemIdentifier(found) }
            let id = UUID().uuidString
            run("INSERT INTO items(id, path, parent, is_dir, size, mtime, is_volume) VALUES (?, ?, ?, 0, 0, 0, 0)",
                [.text(id), .text(path.string), .text(path.parent.string)])
            return NSFileProviderItemIdentifier(id)
        }
    }

    func path(for identifier: NSFileProviderItemIdentifier) -> VPath? {
        if identifier == .rootContainer { return .root }
        var found: VPath?
        run("SELECT path FROM items WHERE id = ?", [.text(identifier.rawValue)]) { found = VPath(Self.text($0, 0)) }
        return found
    }

    /// Records the latest metadata for `path` and returns its identifier.
    @discardableResult
    func record(_ path: VPath, _ entry: Entry) -> NSFileProviderItemIdentifier {
        let id = identifier(for: path)
        if path.isRoot { return id }
        run("UPDATE items SET is_dir = ?, size = ?, mtime = ?, is_volume = ? WHERE path = ?",
            [.int(entry.isDirectory ? 1 : 0), .int(Int64(entry.size)), .int(entry.mtime),
             .int(entry.isVolume ? 1 : 0), .text(path.string)])
        return id
    }

    // MARK: Folder snapshots

    func children(of directory: VPath) -> [String: Row] {
        var rows: [String: Row] = [:]
        run("SELECT id, path, is_dir, size, mtime, is_volume FROM items WHERE parent = ? AND path != '/'",
            [.text(directory.string)]) { statement in
            let path = VPath(Self.text(statement, 1))
            rows[path.name] = Row(identifier: NSFileProviderItemIdentifier(Self.text(statement, 0)),
                                  path: path,
                                  entry: Entry(name: path.name,
                                               isDirectory: sqlite3_column_int(statement, 2) != 0,
                                               size: UInt64(sqlite3_column_int64(statement, 3)),
                                               mtime: sqlite3_column_int64(statement, 4),
                                               isVolume: sqlite3_column_int(statement, 5) != 0))
        }
        return rows
    }

    /// Replaces the snapshot of `directory` with a fresh listing and marks it as
    /// enumerated. Returns the identifiers of vanished items and their descendants.
    @discardableResult
    func replaceChildren(of directory: VPath, with entries: [Entry],
                         pruneMissing: Bool = true) -> (rows: [Row], deleted: [NSFileProviderItemIdentifier]) {
        transaction {
            let names = Set(entries.map(\.name))
            var deleted: [NSFileProviderItemIdentifier] = []
            for (name, row) in children(of: directory) where pruneMissing && !names.contains(name) {
                deleted += remove(row.path)
            }
            let rows = entries.map { entry -> Row in
                let path = directory.appending(entry.name)
                return Row(identifier: record(path, entry), path: path, entry: entry)
            }
            markListed(directory)
            return (rows, deleted)
        }
    }

    /// Starts tracking a folder whose contents the system knows, including
    /// folders created from the Mac, so phone-side changes in it are reported.
    func markListed(_ directory: VPath) {
        run("INSERT OR IGNORE INTO listed(path) VALUES (?)", [.text(directory.string)])
    }

    func listedDirectories() -> [VPath] {
        var paths: [VPath] = []
        run("SELECT path FROM listed ORDER BY length(path)") { paths.append(VPath(Self.text($0, 0))) }
        return paths
    }

    /// Forgets `path` and its descendants; returns their identifiers.
    @discardableResult
    func remove(_ path: VPath) -> [NSFileProviderItemIdentifier] {
        transaction {
            let (clause, values) = subtree(path)
            var ids: [NSFileProviderItemIdentifier] = []
            run("SELECT id FROM items WHERE \(clause)", values) { ids.append(NSFileProviderItemIdentifier(Self.text($0, 0))) }
            run("DELETE FROM items WHERE \(clause)", values)
            run("DELETE FROM listed WHERE \(clause)", values)
            return ids
        }
    }

    /// Re-homes `from` and its descendants under `to`, keeping identifiers.
    func move(_ from: VPath, to: VPath) {
        transaction {
            remove(to)
            let (clause, values) = subtree(from)
            let oldLength = Int64(from.string.utf8.count)
            for table in ["items", "listed"] {
                run("UPDATE \(table) SET path = ? || substr(path, ?) WHERE \(clause)",
                    [.text(to.string), .int(oldLength + 1)] + values)
            }
            let (parentClause, parentValues) = subtree(from, column: "parent")
            run("UPDATE items SET parent = ? || substr(parent, ?) WHERE \(parentClause)",
                [.text(to.string), .int(oldLength + 1)] + parentValues)
            run("UPDATE items SET parent = ? WHERE path = ?", [.text(to.parent.string), .text(to.string)])
        }
    }

    // MARK: Sync anchor

    func anchor() -> Int64 {
        var value: Int64 = 0
        run("SELECT value FROM meta WHERE key = 'anchor'") { value = sqlite3_column_int64($0, 0) }
        return value
    }

    func advanceAnchor() -> Int64 {
        transaction {
            let next = anchor() + 1
            run("INSERT OR REPLACE INTO meta(key, value) VALUES ('anchor', ?)", [.int(next)])
            return next
        }
    }
}
