import Foundation
import SQLite3

/// A private copy of a browser database plus whatever journal sidecars it had.
///
/// The live file is held open by the running browser, and a read-only connection
/// cannot recover a hot rollback journal. Copying is also cheap: the temporary
/// directory sits on the same APFS volume as `~/Library`, so `copyItem` clones.
struct FaviconSnapshot: Sendable {
    let directory: URL
    let database: URL

    init?(original: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: original.path) else { return nil }
        let directory = fm.temporaryDirectory.appending(path: "im.opentab.favicons-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }

        let name = original.lastPathComponent
        let copy = directory.appending(path: name)
        guard (try? fm.copyItem(at: original, to: copy)) != nil else {
            try? fm.removeItem(at: directory)
            return nil
        }
        let source = original.deletingLastPathComponent()
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar = source.appending(path: name + suffix)
            guard fm.fileExists(atPath: sidecar.path) else { continue }
            try? fm.copyItem(at: sidecar, to: directory.appending(path: name + suffix))
        }
        self.directory = directory
        self.database = copy
    }

    func discard() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum FaviconSQLite {
    /// Opens a snapshot taken by `FaviconSnapshot`. Read-only comes first; a
    /// copy that carries a hot journal only opens once SQLite may write the
    /// recovery back, and the copy is ours to modify.
    static func openPrivateCopy(_ url: URL) -> OpaquePointer? {
        if let db = open(url, flags: SQLITE_OPEN_READONLY) {
            if isReadable(db) { return db }
            close(db)
        }
        if let db = open(url, flags: SQLITE_OPEN_READWRITE) {
            if isReadable(db) { return db }
            close(db)
        }
        return nil
    }

    static func close(_ db: OpaquePointer?) {
        sqlite3_close_v2(db)
    }

    /// Runs `sql` with one bound text parameter, calling `row` per result row.
    /// Every failure is silent: a missing table or a corrupt page must degrade
    /// to "no icon", never to a thrown error on the panel path.
    static func query(db: OpaquePointer, sql: String, text: String, row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        // strdup with a free destructor: SQLite owns the copy for as long as the
        // statement needs it, which no bridged Swift string can promise.
        guard sqlite3_bind_text(statement, 1, strdup(text), -1, { free($0) }) == SQLITE_OK else { return }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
    }

    private static func open(_ url: URL, flags: Int32) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            close(db)
            return nil
        }
        return db
    }

    /// A truncated file, a wrong header or an unrecovered journal only surfaces
    /// on the first read, not on open.
    private static func isReadable(_ db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        return step == SQLITE_ROW || step == SQLITE_DONE
    }
}
