//
//  ActivityStore.swift
//  Shared between app and extension
//
//  Phase 1: SQLite-backed Activity Log storage
//

import Foundation
import SQLite3

// Swift does not expose SQLITE_TRANSIENT; define it for sqlite3_bind_text copy semantics
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class ActivityStore {
    // Optional override for database URL (used by tests)
    private static var dbURLOverride: URL? = nil

    // Allow tests to override the database location before first access to `shared`
    public static func setDatabaseURLOverride(_ url: URL?) {
        ActivityStore.dbURLOverride = url
    }
    public struct AppMetadata {
        public let domain: String?
        public let uri: String?
        public let scheme: String?
        public init(domain: String?, uri: String?, scheme: String?) {
            self.domain = domain
            self.uri = uri
            self.scheme = scheme
        }
    }

    public struct ActivityItem {
        public let txHash: String
        public let app: AppMetadata
        public let chainIdHex: String
        public let method: String?
        public let fromAddress: String?
        public let createdAt: Date
        public let status: String
    }

    public static let shared = ActivityStore()

    private let queue = DispatchQueue(label: "co.za.stephancill.stupid-wallet.activity-store")
    private var db: OpaquePointer?

    private init() {
        queue.sync {
            do {
                try openIfNeeded()
                try createSchemaIfNeeded()
            } catch {
                // Best-effort: keep running even if logging is unavailable
            }
        }
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Public API

    public func logTransaction(
        txHash: String,
        chainIdHex: String,
        method: String,
        fromAddress: String?,
        app: AppMetadata
    ) throws {
        try queue.sync {
            try openIfNeeded()

            // Upsert app
            let appId = try upsertApp(domain: app.domain, uri: app.uri, scheme: app.scheme)

            // Insert transaction (ignore duplicates on tx_hash)
            let sql = "INSERT OR IGNORE INTO transactions (tx_hash, app_id, chain_id_hex, method, from_address, created_at) VALUES (?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ActivityStoreError.sqlite(message: lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (txHash as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(appId))
            sqlite3_bind_text(stmt, 3, (chainIdHex.lowercased() as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if method.isEmpty { sqlite3_bind_null(stmt, 4) } else { sqlite3_bind_text(stmt, 4, (method as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            if let from = fromAddress, !from.isEmpty {
                sqlite3_bind_text(stmt, 5, (from as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            let now = Int64(Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 6, now)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw ActivityStoreError.sqlite(message: lastErrorMessage())
            }
        }
    }

    public func fetchTransactions(limit: Int, offset: Int) throws -> [ActivityItem] {
        return try queue.sync {
            try openIfNeeded()

            let sql = """
            SELECT t.tx_hash, t.chain_id_hex, t.method, t.from_address, t.created_at,
                   a.domain, a.uri, a.scheme,
                   t.status
              FROM transactions t
              LEFT JOIN apps a ON a.id = t.app_id
             ORDER BY t.created_at DESC, t.id DESC
             LIMIT ? OFFSET ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ActivityStoreError.sqlite(message: lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(max(0, limit)))
            sqlite3_bind_int(stmt, 2, Int32(max(0, offset)))

            var items: [ActivityItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let txHash = stringColumn(stmt, index: 0) ?? ""
                let chainIdHex = stringColumn(stmt, index: 1) ?? "0x1"
                let method = stringColumn(stmt, index: 2)
                let fromAddress = stringColumn(stmt, index: 3)
                let createdAtEpoch = sqlite3_column_int64(stmt, 4)
                let domain = stringColumn(stmt, index: 5)
                let uri = stringColumn(stmt, index: 6)
                let scheme = stringColumn(stmt, index: 7)
                let app = AppMetadata(domain: domain, uri: uri, scheme: scheme)
                let status = stringColumn(stmt, index: 8) ?? "pending"
                let item = ActivityItem(
                    txHash: txHash,
                    app: app,
                    chainIdHex: chainIdHex,
                    method: method,
                    fromAddress: fromAddress,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtEpoch)),
                    status: status
                )
                items.append(item)
            }
            return items
        }
    }

    public func updateTransactionStatus(txHash: String, status: String) throws {
        try queue.sync {
            try openIfNeeded()

            let sql = "UPDATE transactions SET status = ? WHERE tx_hash = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ActivityStoreError.sqlite(message: lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (status as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (txHash as NSString).utf8String, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw ActivityStoreError.sqlite(message: lastErrorMessage())
            }
        }
    }

    // MARK: - Private helpers

    private func openIfNeeded() throws {
        if db != nil { return }

        // Resolve database URL (test override > env var > App Group container)
        let dbURL: URL
        if let override = ActivityStore.dbURLOverride {
            dbURL = override
        } else if let envPath = ProcessInfo.processInfo.environment["STUPID_WALLET_ACTIVITY_DB"], !envPath.isEmpty {
            dbURL = URL(fileURLWithPath: envPath)
        } else {
            guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupId) else {
                throw ActivityStoreError.containerUnavailable
            }
            dbURL = containerURL.appendingPathComponent("Activity.sqlite")
        }

        var handle: OpaquePointer?
        if sqlite3_open(dbURL.path, &handle) != SQLITE_OK {
            throw ActivityStoreError.sqlite(message: lastErrorMessage(handle))
        }
        db = handle

        // Apply PRAGMAs
        _ = exec("PRAGMA journal_mode=WAL;")
        _ = exec("PRAGMA foreign_keys=ON;")
        _ = exec("PRAGMA synchronous=NORMAL;")
    }

    private func createSchemaIfNeeded() throws {
        // Migration scaffolding: use PRAGMA user_version to coordinate schema changes.
        // v1: initial schema
        // Future: bump user_version and add migrations here.
        _ = exec("PRAGMA user_version;")

        let createApps = """
        CREATE TABLE IF NOT EXISTS apps (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          domain TEXT,
          uri TEXT,
          scheme TEXT,
          UNIQUE(domain, uri, scheme)
        );
        """
        let createTx = """
        CREATE TABLE IF NOT EXISTS transactions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tx_hash TEXT NOT NULL UNIQUE,
          app_id INTEGER NOT NULL,
          chain_id_hex TEXT NOT NULL,
          method TEXT,
          from_address TEXT,
          created_at INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending',
          FOREIGN KEY(app_id) REFERENCES apps(id)
        );
        CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_transactions_created_id_desc ON transactions(created_at DESC, id DESC);
        """
        guard exec(createApps), exec(createTx) else {
            throw ActivityStoreError.schemaCreationFailed
        }

        // Set user_version to 1 if it's currently 0 (fresh DB)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                let version = sqlite3_column_int(stmt, 0)
                if version == 0 {
                    _ = exec("PRAGMA user_version = 1;")
                }
            }
        }
    }

    private func upsertApp(domain: String?, uri: String?, scheme: String?) throws -> Int64 {
        // INSERT OR IGNORE, then SELECT id
        let insertSQL = "INSERT OR IGNORE INTO apps (domain, uri, scheme) VALUES (?, ?, ?);"
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            throw ActivityStoreError.sqlite(message: lastErrorMessage())
        }
        defer { sqlite3_finalize(insertStmt) }

        bindOptionalText(insertStmt, 1, domain)
        bindOptionalText(insertStmt, 2, uri)
        bindOptionalText(insertStmt, 3, scheme)

        guard sqlite3_step(insertStmt) == SQLITE_DONE else {
            throw ActivityStoreError.sqlite(message: lastErrorMessage())
        }

        let selectSQL = """
        SELECT id FROM apps
        WHERE ((? IS NULL AND domain IS NULL) OR (? IS NOT NULL AND domain = ?))
          AND ((? IS NULL AND uri IS NULL) OR (? IS NOT NULL AND uri = ?))
          AND ((? IS NULL AND scheme IS NULL) OR (? IS NOT NULL AND scheme = ?))
        LIMIT 1;
        """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
            throw ActivityStoreError.sqlite(message: lastErrorMessage())
        }
        defer { sqlite3_finalize(selectStmt) }

        // Bind triplets per column so the predicate compares NULLs and non-NULLs correctly.
        // Empty strings are treated as NULL for consistency with inserts.
        bindNullAwareTriplet(selectStmt, 1, 2, 3, domain)
        bindNullAwareTriplet(selectStmt, 4, 5, 6, uri)
        bindNullAwareTriplet(selectStmt, 7, 8, 9, scheme)

        guard sqlite3_step(selectStmt) == SQLITE_ROW else {
            throw ActivityStoreError.sqlite(message: "Failed to fetch app id")
        }
        return sqlite3_column_int64(selectStmt, 0)
    }

    private func exec(_ sql: String) -> Bool {
        var errMsg: UnsafeMutablePointer<Int8>? = nil
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            if let e = errMsg { sqlite3_free(e) }
            return false
        }
        return true
    }

    private func stringColumn(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value = value, !value.isEmpty {
            sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindNullOrTextPair(_ stmt: OpaquePointer?, _ nullIndex: Int32, _ valueIndex: Int32, _ value: String?) {
        if let value = value, !value.isEmpty {
            sqlite3_bind_null(stmt, nullIndex)
            sqlite3_bind_text(stmt, valueIndex, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, nullIndex)
            sqlite3_bind_null(stmt, valueIndex)
        }
    }

    private func bindNullAwareTriplet(_ stmt: OpaquePointer?, _ i1: Int32, _ i2: Int32, _ i3: Int32, _ value: String?) {
        if let v = value, !v.isEmpty {
            sqlite3_bind_text(stmt, i1, (v as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, i2, (v as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, i3, (v as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, i1)
            sqlite3_bind_null(stmt, i2)
            sqlite3_bind_null(stmt, i3)
        }
    }

    private func lastErrorMessage(_ handle: OpaquePointer? = nil) -> String {
        let h = handle ?? db
        if let cStr = sqlite3_errmsg(h) { return String(cString: cStr) }
        return "Unknown sqlite error"
    }
}

public enum ActivityStoreError: Error {
    case containerUnavailable
    case sqlite(message: String)
    case schemaCreationFailed
}


