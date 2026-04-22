import Foundation
import SQLite3

/// Errors surfaced by `LibraryIndex`.
public enum LibraryIndexError: Error, CustomStringConvertible {
    case openFailed(String)
    case sqlFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .openFailed(let s):    return "LibraryIndex.openFailed: \(s)"
        case .sqlFailed(let s):     return "LibraryIndex.sqlFailed: \(s)"
        case .prepareFailed(let s): return "LibraryIndex.prepareFailed: \(s)"
        case .stepFailed(let s):    return "LibraryIndex.stepFailed: \(s)"
        case .notFound(let s):      return "LibraryIndex.notFound: \(s)"
        }
    }
}

/// A single capture row in the library index.
///
/// Mirrors the `captures` table. Optional fields map to SQL NULL.
public struct LibraryRecord: Sendable, Equatable {
    public let id: String               // UUIDv7 string (PRIMARY KEY)
    public let createdAt: Int64         // epoch seconds (UTC)
    public let expiresAt: Int64?        // epoch seconds; nil iff pinned
    public let pinned: Bool
    public let bundleID: String?
    public let windowTitle: String?
    public let fileURL: String?
    public let gitRoot: String?
    public let browserURL: String?
    /// Clipboard text, if any (feeds FTS column `clipboard`). Not stored as its
    /// own captures column in v0.1 — lives inside FTS only to keep the row width
    /// small. We keep it here for round-tripping inserts.
    public let clipboard: String?
    /// OCR concatenated text. Starts nil and is filled in by `updateOCR(...)`.
    public let ocrText: String?

    public init(
        id: String,
        createdAt: Int64,
        expiresAt: Int64?,
        pinned: Bool,
        bundleID: String? = nil,
        windowTitle: String? = nil,
        fileURL: String? = nil,
        gitRoot: String? = nil,
        browserURL: String? = nil,
        clipboard: String? = nil,
        ocrText: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.pinned = pinned
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.fileURL = fileURL
        self.gitRoot = gitRoot
        self.browserURL = browserURL
        self.clipboard = clipboard
        self.ocrText = ocrText
    }
}

/// SQLite + FTS5 backed library index for Shotfuse captures.
///
/// Honors SPEC §5 Invariant 9: SQLite+FTS5 is load-bearing — Spotlight is not
/// a dependency. Default DB path is `~/.shotfuse/index.db`; tests inject a
/// temp-dir path via `init(databaseURL:)`.
///
/// ## Schema
///
/// ```sql
/// CREATE TABLE captures(
///   id TEXT PRIMARY KEY,
///   created_at INTEGER NOT NULL,
///   expires_at INTEGER,
///   pinned INTEGER NOT NULL,
///   bundle_id TEXT,
///   window_title TEXT,
///   file_url TEXT,
///   git_root TEXT,
///   browser_url TEXT
/// );
///
/// CREATE VIRTUAL TABLE captures_fts USING fts5(
///   window_title, file_url, clipboard, ocr_text, bundle_id,
///   content=''            -- external-content-less; we write rowids explicitly
/// );
///
/// CREATE TABLE fts_rowid_map(
///   id TEXT PRIMARY KEY REFERENCES captures(id) ON DELETE CASCADE,
///   rowid INTEGER NOT NULL UNIQUE
/// );
/// ```
///
/// ## Concurrency
///
/// `LibraryIndex` is an `actor` — all SQLite access is serialized through the
/// actor's mailbox. This keeps the handle single-threaded without resorting
/// to SQLite's shared-cache mode, and keeps us Swift-6 concurrency-clean.
public actor LibraryIndex {

    // MARK: - Default locations

    /// Default on-disk location: `~/.shotfuse/index.db`. Expanded via
    /// `FileManager.homeDirectoryForCurrentUser` — never hardcoded.
    public static func defaultDatabaseURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".shotfuse", isDirectory: true)
            .appendingPathComponent("index.db")
    }

    // MARK: - State

    private let databaseURL: URL
    /// Opaque SQLite handle. `OpaquePointer?` is the canonical Swift mapping
    /// for `sqlite3 *`.
    private var db: OpaquePointer?

    // MARK: - Lifecycle

    /// Opens (and migrates, if necessary) the SQLite DB at `databaseURL`.
    ///
    /// - Parameter databaseURL: Override the on-disk location. Defaults to
    ///   `defaultDatabaseURL()`. Parent directory is created if missing.
    public init(databaseURL: URL? = nil) throws {
        let url = databaseURL ?? Self.defaultDatabaseURL()
        self.databaseURL = url

        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        // SQLITE_OPEN_FULLMUTEX is overkill (actor already serializes), but
        // cheap insurance against accidental misuse. NOMUTEX would also work.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h = handle { sqlite3_close_v2(h) }
            throw LibraryIndexError.openFailed("\(url.path): rc=\(rc) \(msg)")
        }
        self.db = h

        // Pragmas tuned for low-latency single-process use.
        try Self.exec(h, "PRAGMA journal_mode = WAL;")
        try Self.exec(h, "PRAGMA synchronous = NORMAL;")
        try Self.exec(h, "PRAGMA foreign_keys = ON;")
        try Self.exec(h, "PRAGMA temp_store = MEMORY;")

        try Self.migrate(h)
    }

    // No `deinit` — Swift 6's nonisolated deinit can't touch the
    // actor-isolated `db: OpaquePointer?` safely. Callers should invoke
    // `close()` explicitly. SQLite would also clean up when the process
    // exits; leaking a handle in-process is an acceptable safety net.

    /// Explicit teardown hook. Call before removing the DB file from tests,
    /// or on app shutdown in production.
    public func close() {
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    // MARK: - Migrations

    /// Current schema version. Bumped whenever the persistent layout changes
    /// in a way existing DBs need to migrate through.
    ///
    /// v1 — original (window_title, file_url, clipboard, ocr_text).
    /// v2 — add `bundle_id` as the 5th FTS5 column. FTS5 does not support
    ///      `ALTER TABLE ... ADD COLUMN` on a virtual table, so the migration
    ///      drops and recreates `captures_fts` then rebuilds the inverted
    ///      index from the `captures` + `fts_rowid_map` tables.
    private static let schemaVersion: Int = 2

    private static func migrate(_ db: OpaquePointer) throws {
        try exec(db, """
            CREATE TABLE IF NOT EXISTS captures (
                id           TEXT PRIMARY KEY,
                created_at   INTEGER NOT NULL,
                expires_at   INTEGER,
                pinned       INTEGER NOT NULL DEFAULT 0,
                bundle_id    TEXT,
                window_title TEXT,
                file_url     TEXT,
                git_root     TEXT,
                browser_url  TEXT
            );
            """)

        try exec(db, """
            CREATE INDEX IF NOT EXISTS captures_created_at_idx
              ON captures(created_at);
            """)

        try exec(db, """
            CREATE INDEX IF NOT EXISTS captures_expires_at_idx
              ON captures(expires_at);
            """)

        try exec(db, """
            CREATE TABLE IF NOT EXISTS fts_rowid_map (
                id     TEXT PRIMARY KEY REFERENCES captures(id) ON DELETE CASCADE,
                rowid  INTEGER NOT NULL UNIQUE
            );
            """)

        // Apply schema-version-aware FTS5 migration. The FTS5 virtual table
        // does not tolerate ALTER TABLE, so we version the schema via
        // `PRAGMA user_version` and rebuild the inverted index from the
        // authoritative `captures` table when the column set changes.
        let current = try readUserVersion(db)
        if current < schemaVersion {
            try migrateFTS(db, from: current, to: schemaVersion)
            try exec(db, "PRAGMA user_version = \(schemaVersion);")
        } else {
            // First-ever boot (empty DB, user_version == 0 by default) OR
            // forward-migrated already — ensure the v2 FTS table exists.
            try ensureFTSv2(db)
            if current == 0 {
                try exec(db, "PRAGMA user_version = \(schemaVersion);")
            }
        }
    }

    /// Creates `captures_fts` (v2 column set) if it doesn't exist.
    private static func ensureFTSv2(_ db: OpaquePointer) throws {
        try exec(db, """
            CREATE VIRTUAL TABLE IF NOT EXISTS captures_fts
              USING fts5(
                window_title,
                file_url,
                clipboard,
                ocr_text,
                bundle_id,
                tokenize = 'unicode61 remove_diacritics 2'
              );
            """)
    }

    /// Rebuilds `captures_fts` in-place for a schema-version bump. Drops the
    /// virtual table, recreates it at the target version, and re-ingests
    /// every row in `captures` via the existing `fts_rowid_map` mapping so
    /// previously-issued rowids remain stable. `clipboard` and `ocr_text`
    /// columns are lost (we never persisted them outside FTS) — re-OCR / new
    /// captures repopulate them on catch-up.
    private static func migrateFTS(
        _ db: OpaquePointer,
        from: Int,
        to: Int
    ) throws {
        // Drop the stale FTS table. Use IF EXISTS so fresh DBs stay happy.
        try exec(db, "DROP TABLE IF EXISTS captures_fts;")
        try ensureFTSv2(db)

        // Re-insert one FTS row per captures row, preserving (rowid, id)
        // pairs from fts_rowid_map. We walk captures + fts_rowid_map inside
        // a single transaction so the virtual table's internal structures
        // stay consistent.
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            // Purge any stale mappings whose captures row is gone.
            try exec(db, """
                DELETE FROM fts_rowid_map
                  WHERE id NOT IN (SELECT id FROM captures);
                """)

            // Rebuild FTS from captures. rowid is chosen explicitly so the
            // existing fts_rowid_map entries continue pointing at the right
            // row. For captures without a mapping (should not happen in
            // practice; defensive), we allocate a fresh rowid and insert a
            // new mapping.
            let selectSQL = """
                SELECT c.id, c.bundle_id, c.window_title, c.file_url,
                       m.rowid
                  FROM captures c
                  LEFT JOIN fts_rowid_map m ON m.id = c.id
                  ORDER BY c.created_at ASC;
                """

            var rows: [(id: String, bundleID: String?, windowTitle: String?, fileURL: String?, rowid: Int64?)] = []
            try prepareAndRun(db, selectSQL, bind: { _ in }) { stmt in
                let id = columnText(stmt, 0) ?? ""
                let bid = columnText(stmt, 1)
                let wt  = columnText(stmt, 2)
                let fu  = columnText(stmt, 3)
                let rid: Int64? = (sqlite3_column_type(stmt, 4) == SQLITE_NULL)
                    ? nil
                    : sqlite3_column_int64(stmt, 4)
                rows.append((id, bid, wt, fu, rid))
            }

            for row in rows {
                if let rid = row.rowid {
                    try prepareAndStep(db, """
                        INSERT INTO captures_fts
                          (rowid, window_title, file_url, clipboard, ocr_text, bundle_id)
                          VALUES (?, ?, ?, NULL, NULL, ?);
                        """) { stmt in
                        sqlite3_bind_int64(stmt, 1, rid)
                        bindOptionalText(stmt, 2, row.windowTitle)
                        bindOptionalText(stmt, 3, row.fileURL)
                        bindOptionalText(stmt, 4, row.bundleID)
                    }
                } else {
                    // No mapping — allocate a fresh rowid. Should not occur
                    // in healthy DBs; guards against future divergence.
                    try prepareAndStep(db, """
                        INSERT INTO captures_fts
                          (window_title, file_url, clipboard, ocr_text, bundle_id)
                          VALUES (?, ?, NULL, NULL, ?);
                        """) { stmt in
                        bindOptionalText(stmt, 1, row.windowTitle)
                        bindOptionalText(stmt, 2, row.fileURL)
                        bindOptionalText(stmt, 3, row.bundleID)
                    }
                    let newRowid = sqlite3_last_insert_rowid(db)
                    try prepareAndStep(db, """
                        INSERT INTO fts_rowid_map (id, rowid)
                          VALUES (?, ?);
                        """) { stmt in
                        bindText(stmt, 1, row.id)
                        sqlite3_bind_int64(stmt, 2, newRowid)
                    }
                }
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// Reads SQLite's `PRAGMA user_version` — the persistent schema counter.
    private static func readUserVersion(_ db: OpaquePointer) throws -> Int {
        var version: Int = 0
        try prepareAndRun(db, "PRAGMA user_version;", bind: { _ in }) { stmt in
            version = Int(sqlite3_column_int64(stmt, 0))
        }
        return version
    }

    // MARK: - Public API

    /// Inserts a capture row and its FTS projection. OCR text may be added
    /// later via `updateOCR(for:ocrText:)`.
    ///
    /// - Throws: `LibraryIndexError.stepFailed` on conflict or I/O error.
    public func insert(_ record: LibraryRecord) throws {
        guard let db else { throw LibraryIndexError.openFailed("db closed") }

        try Self.exec(db, "BEGIN IMMEDIATE;")
        do {
            // 1. captures row
            let sql = """
                INSERT INTO captures
                  (id, created_at, expires_at, pinned,
                   bundle_id, window_title, file_url, git_root, browser_url)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            try Self.prepareAndStep(db, sql) { stmt in
                Self.bindText(stmt, 1, record.id)
                sqlite3_bind_int64(stmt, 2, record.createdAt)
                if let e = record.expiresAt {
                    sqlite3_bind_int64(stmt, 3, e)
                } else {
                    sqlite3_bind_null(stmt, 3)
                }
                sqlite3_bind_int(stmt, 4, record.pinned ? 1 : 0)
                Self.bindOptionalText(stmt, 5, record.bundleID)
                Self.bindOptionalText(stmt, 6, record.windowTitle)
                Self.bindOptionalText(stmt, 7, record.fileURL)
                Self.bindOptionalText(stmt, 8, record.gitRoot)
                Self.bindOptionalText(stmt, 9, record.browserURL)
            }

            // 2. FTS row
            let ftsSQL = """
                INSERT INTO captures_fts
                  (window_title, file_url, clipboard, ocr_text, bundle_id)
                VALUES (?, ?, ?, ?, ?);
                """
            try Self.prepareAndStep(db, ftsSQL) { stmt in
                Self.bindOptionalText(stmt, 1, record.windowTitle)
                Self.bindOptionalText(stmt, 2, record.fileURL)
                Self.bindOptionalText(stmt, 3, record.clipboard)
                Self.bindOptionalText(stmt, 4, record.ocrText)
                Self.bindOptionalText(stmt, 5, record.bundleID)
            }
            let rowid = sqlite3_last_insert_rowid(db)

            // 3. id → rowid mapping
            try Self.prepareAndStep(
                db,
                "INSERT INTO fts_rowid_map (id, rowid) VALUES (?, ?);"
            ) { stmt in
                Self.bindText(stmt, 1, record.id)
                sqlite3_bind_int64(stmt, 2, rowid)
            }

            try Self.exec(db, "COMMIT;")
        } catch {
            try? Self.exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// Updates the OCR column for an existing row, rebuilding its FTS entry.
    ///
    /// Contract: leaves every OTHER row intact. Previously-inserted rows (OCR
    /// or not) remain retrievable by their original FTS terms.
    ///
    /// Regular (non-contentless) FTS5 tables support `UPDATE` natively —
    /// FTS5 rebuilds the inverted index for the affected row under the hood.
    public func updateOCR(for id: String, ocrText: String) throws {
        guard let db else { throw LibraryIndexError.openFailed("db closed") }

        try Self.exec(db, "BEGIN IMMEDIATE;")
        do {
            let rowid = try Self.lookupRowid(db, id: id)
            guard let rowid else {
                try Self.exec(db, "ROLLBACK;")
                throw LibraryIndexError.notFound("no capture with id \(id)")
            }

            try Self.prepareAndStep(
                db,
                "UPDATE captures_fts SET ocr_text = ? WHERE rowid = ?;"
            ) { stmt in
                Self.bindText(stmt, 1, ocrText)
                sqlite3_bind_int64(stmt, 2, rowid)
            }

            try Self.exec(db, "COMMIT;")
        } catch {
            try? Self.exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// Runs an FTS5 MATCH query and returns matching capture IDs (most recent first).
    public func searchIDs(_ query: String, limit: Int = 50) throws -> [String] {
        guard let db else { throw LibraryIndexError.openFailed("db closed") }

        var ids: [String] = []
        let sql = """
            SELECT c.id
              FROM captures_fts f
              JOIN fts_rowid_map m ON m.rowid = f.rowid
              JOIN captures     c ON c.id    = m.id
              WHERE captures_fts MATCH ?
              ORDER BY c.created_at DESC
              LIMIT ?;
            """
        try Self.prepareAndRun(db, sql) { stmt in
            Self.bindText(stmt, 1, query)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        } onRow: { stmt in
            if let id = Self.columnText(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Fetches a record by primary key, if present.
    public func fetch(id: String) throws -> LibraryRecord? {
        guard let db else { throw LibraryIndexError.openFailed("db closed") }

        var captured: LibraryRecord?

        // Pull the captures row first.
        let sql = """
            SELECT id, created_at, expires_at, pinned,
                   bundle_id, window_title, file_url, git_root, browser_url
              FROM captures
              WHERE id = ?;
            """
        var rowidForFTS: Int64?
        try Self.prepareAndRun(db, sql) { stmt in
            Self.bindText(stmt, 1, id)
        } onRow: { stmt in
            let rid = Self.columnText(stmt, 0) ?? ""
            let createdAt = sqlite3_column_int64(stmt, 1)
            let expiresAt: Int64? = (sqlite3_column_type(stmt, 2) == SQLITE_NULL)
                ? nil
                : sqlite3_column_int64(stmt, 2)
            let pinned = sqlite3_column_int(stmt, 3) != 0
            let bundleID    = Self.columnText(stmt, 4)
            let windowTitle = Self.columnText(stmt, 5)
            let fileURL     = Self.columnText(stmt, 6)
            let gitRoot     = Self.columnText(stmt, 7)
            let browserURL  = Self.columnText(stmt, 8)

            captured = LibraryRecord(
                id: rid,
                createdAt: createdAt,
                expiresAt: expiresAt,
                pinned: pinned,
                bundleID: bundleID,
                windowTitle: windowTitle,
                fileURL: fileURL,
                gitRoot: gitRoot,
                browserURL: browserURL,
                clipboard: nil,
                ocrText: nil
            )
        }

        guard var rec = captured else { return nil }

        // Pull FTS-side columns (clipboard, ocr_text) so the returned record
        // round-trips the enrichment state.
        rowidForFTS = try Self.lookupRowid(db, id: id)
        if let rowid = rowidForFTS {
            try Self.prepareAndRun(
                db,
                "SELECT clipboard, ocr_text FROM captures_fts WHERE rowid = ?;"
            ) { stmt in
                sqlite3_bind_int64(stmt, 1, rowid)
            } onRow: { stmt in
                let clipboard = Self.columnText(stmt, 0)
                let ocrText   = Self.columnText(stmt, 1)
                rec = LibraryRecord(
                    id: rec.id,
                    createdAt: rec.createdAt,
                    expiresAt: rec.expiresAt,
                    pinned: rec.pinned,
                    bundleID: rec.bundleID,
                    windowTitle: rec.windowTitle,
                    fileURL: rec.fileURL,
                    gitRoot: rec.gitRoot,
                    browserURL: rec.browserURL,
                    clipboard: clipboard,
                    ocrText: ocrText
                )
            }
        }
        return rec
    }

    /// Deletes a row and its FTS projection. Silently no-ops if absent.
    public func delete(id: String) throws {
        guard let db else { throw LibraryIndexError.openFailed("db closed") }

        try Self.exec(db, "BEGIN IMMEDIATE;")
        do {
            let rowid = try Self.lookupRowid(db, id: id)
            if let rowid {
                // Regular FTS5 tables support DELETE by rowid natively; FTS5
                // prunes the inverted index entry on commit.
                try Self.prepareAndStep(
                    db,
                    "DELETE FROM captures_fts WHERE rowid = ?;"
                ) { stmt in
                    sqlite3_bind_int64(stmt, 1, rowid)
                }
            }
            // captures row (ON DELETE CASCADE drops fts_rowid_map).
            try Self.prepareAndStep(
                db,
                "DELETE FROM captures WHERE id = ?;"
            ) { stmt in
                Self.bindText(stmt, 1, id)
            }
            try Self.exec(db, "COMMIT;")
        } catch {
            try? Self.exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// Count of rows — handy for tests.
    public func count() throws -> Int {
        guard let db else { throw LibraryIndexError.openFailed("db closed") }
        var n: Int = 0
        try Self.prepareAndRun(db, "SELECT COUNT(*) FROM captures;") { _ in
        } onRow: { stmt in
            n = Int(sqlite3_column_int64(stmt, 0))
        }
        return n
    }

    // MARK: - Low-level SQLite helpers

    /// SQLite requires its bound text pointers to remain valid until the step
    /// completes. `SQLITE_TRANSIENT` tells SQLite to copy the buffer itself
    /// so we don't have to pin Swift strings across the C boundary.
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let err { sqlite3_free(err) }
            throw LibraryIndexError.sqlFailed("\(sql.prefix(120)) — rc=\(rc) \(msg)")
        }
    }

    private static func prepare(
        _ db: OpaquePointer,
        _ sql: String
    ) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw LibraryIndexError.prepareFailed("\(sql.prefix(120)) — rc=\(rc) \(msg)")
        }
        return s
    }

    /// Prepare → bind via closure → step once (expects SQLITE_DONE) → finalize.
    private static func prepareAndStep(
        _ db: OpaquePointer,
        _ sql: String,
        bind: (OpaquePointer) -> Void
    ) throws {
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw LibraryIndexError.stepFailed("\(sql.prefix(120)) — rc=\(rc) \(msg)")
        }
    }

    /// Prepare → bind → step repeatedly, calling `onRow` per SQLITE_ROW.
    private static func prepareAndRun(
        _ db: OpaquePointer,
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        onRow: (OpaquePointer) -> Void
    ) throws {
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                onRow(stmt)
            } else if rc == SQLITE_DONE {
                break
            } else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw LibraryIndexError.stepFailed("\(sql.prefix(120)) — rc=\(rc) \(msg)")
            }
        }
    }

    private static func lookupRowid(_ db: OpaquePointer, id: String) throws -> Int64? {
        var result: Int64?
        try prepareAndRun(
            db,
            "SELECT rowid FROM fts_rowid_map WHERE id = ?;"
        ) { stmt in
            bindText(stmt, 1, id)
        } onRow: { stmt in
            result = sqlite3_column_int64(stmt, 0)
        }
        return result
    }

    private static func bindText(_ stmt: OpaquePointer, _ col: Int32, _ value: String) {
        _ = sqlite3_bind_text(stmt, col, value, -1, SQLITE_TRANSIENT)
    }

    private static func bindOptionalText(_ stmt: OpaquePointer, _ col: Int32, _ value: String?) {
        if let v = value {
            _ = sqlite3_bind_text(stmt, col, v, -1, SQLITE_TRANSIENT)
        } else {
            _ = sqlite3_bind_null(stmt, col)
        }
    }

    private static func columnText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, col) else {
            return nil
        }
        return String(cString: cString)
    }
}
