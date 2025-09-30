//
//  ActivityStore.swift
//  Shared between app and extension
//
//  Phase 1: SQLite-backed Activity Log storage
//

import Foundation
import SQLite3
import CryptoKit

// Swift does not expose SQLITE_TRANSIENT; define it for sqlite3_bind_text copy semantics
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Data Extensions

extension Data {
    func sha256() -> Data {
        return Data(SHA256.hash(data: self))
    }

    func toHexString() -> String {
        return "0x" + self.map { String(format: "%02x", $0) }.joined()
    }
}

public final class ActivityStore {
    // Optional override for database URL (used by tests)
    private static var dbURLOverride: URL? = nil

    // Allow tests to override the database location before first access to `shared`
    public static func setDatabaseURLOverride(_ url: URL?) {
        ActivityStore.dbURLOverride = url
    }
    public enum ActivityItemType {
        case transaction
        case signature
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
        public let itemType: ActivityItemType

        // Transaction-specific fields (nil when itemType == .signature):
        public let txHash: String?
        public let status: String?

        // Signature-specific fields (nil when itemType == .transaction):
        public let signatureHash: String?
        public let messageContent: String?
        public let signatureHex: String?

        // Common fields:
        public let app: AppMetadata
        public let chainIdHex: String
        public let method: String?
        public let fromAddress: String?
        public let createdAt: Date

        public init(
            itemType: ActivityItemType,
            txHash: String? = nil,
            status: String? = nil,
            signatureHash: String? = nil,
            messageContent: String? = nil,
            signatureHex: String? = nil,
            app: AppMetadata,
            chainIdHex: String,
            method: String?,
            fromAddress: String?,
            createdAt: Date
        ) {
            self.itemType = itemType
            self.txHash = txHash
            self.status = status
            self.signatureHash = signatureHash
            self.messageContent = messageContent
            self.signatureHex = signatureHex
            self.app = app
            self.chainIdHex = chainIdHex
            self.method = method
            self.fromAddress = fromAddress
            self.createdAt = createdAt
        }
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
            let now = Int64(Date().timeIntervalSince1970) // Store as epoch seconds
            sqlite3_bind_int64(stmt, 6, now)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw ActivityStoreError.sqlite(message: lastErrorMessage())
            }
        }
    }

    public func logSignature(
        signatureHex: String,
        messageContent: String,
        chainIdHex: String,
        method: String,
        fromAddress: String?,
        app: AppMetadata
    ) throws {
        try queue.sync {
            try openIfNeeded()

            // 1. Compute signature_hash = SHA-256(signatureHex)
            guard let sigData = signatureHex.data(using: .utf8) else {
                throw ActivityStoreError.sqlite(message: "Invalid signature hex encoding")
            }
            let signatureHash = sigData.sha256().toHexString()

            // 2. Upsert app metadata
            let appId = try upsertApp(domain: app.domain, uri: app.uri, scheme: app.scheme)

            // 3. INSERT OR IGNORE into signatures with signature_hash as unique constraint
            let sql = "INSERT OR IGNORE INTO signatures (signature_hash, app_id, chain_id_hex, method, from_address, message_content, signature_hex, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ActivityStoreError.sqlite(message: lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (signatureHash as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(appId))
            sqlite3_bind_text(stmt, 3, (chainIdHex.lowercased() as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, (method as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let from = fromAddress, !from.isEmpty {
                sqlite3_bind_text(stmt, 5, (from as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_text(stmt, 6, (messageContent as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, (signatureHex as NSString).utf8String, -1, SQLITE_TRANSIENT)
            let now = Int64(Date().timeIntervalSince1970) // Store as epoch seconds
            sqlite3_bind_int64(stmt, 8, now)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw ActivityStoreError.sqlite(message: lastErrorMessage())
            }
        }
    }

    public func fetchActivity(limit: Int, offset: Int) throws -> [ActivityItem] {
        return try queue.sync {
            try openIfNeeded()

            let sql = """
            SELECT 'transaction' as type,
                   t.tx_hash, t.status, null as sig_hash, null as msg, null as sig,
                   t.chain_id_hex, t.method, t.from_address, t.created_at, t.id,
                   a.domain, a.uri, a.scheme
              FROM transactions t
              LEFT JOIN apps a ON a.id = t.app_id
            
            UNION ALL
            
            SELECT 'signature' as type,
                   null, null, s.signature_hash, s.message_content, s.signature_hex,
                   s.chain_id_hex, s.method, s.from_address, s.created_at, s.id,
                   a.domain, a.uri, a.scheme
              FROM signatures s
              LEFT JOIN apps a ON a.id = s.app_id
            
             ORDER BY 10 DESC, 11 DESC
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
                let typeStr = stringColumn(stmt, index: 0) ?? "transaction"
                let itemType: ActivityItemType = (typeStr == "signature") ? .signature : .transaction
                
                let txHash = stringColumn(stmt, index: 1)
                let status = stringColumn(stmt, index: 2)
                let signatureHash = stringColumn(stmt, index: 3)
                let messageContent = stringColumn(stmt, index: 4)
                let signatureHex = stringColumn(stmt, index: 5)
                
                let chainIdHex = stringColumn(stmt, index: 6) ?? "0x1"
                let method = stringColumn(stmt, index: 7)
                let fromAddress = stringColumn(stmt, index: 8)
                let createdAtSeconds = sqlite3_column_int64(stmt, 9)
                // index 10 is the id (used for sorting, not returned)
                let domain = stringColumn(stmt, index: 11)
                let uri = stringColumn(stmt, index: 12)
                let scheme = stringColumn(stmt, index: 13)
                
                let app = AppMetadata(domain: domain, uri: uri, scheme: scheme)
                let item = ActivityItem(
                    itemType: itemType,
                    txHash: txHash,
                    status: status,
                    signatureHash: signatureHash,
                    messageContent: messageContent,
                    signatureHex: signatureHex,
                    app: app,
                    chainIdHex: chainIdHex,
                    method: method,
                    fromAddress: fromAddress,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtSeconds))
                )
                items.append(item)
            }
            return items
        }
    }
    
    // Deprecated: Use fetchActivity instead
    @available(*, deprecated, renamed: "fetchActivity")
    public func fetchTransactions(limit: Int, offset: Int) throws -> [ActivityItem] {
        return try fetchActivity(limit: limit, offset: offset)
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
    
    /// Database inspection helper for debugging
    /// Returns diagnostic information about the activity database
    public struct DatabaseInfo {
        public let schemaVersion: Int
        public let transactionCount: Int
        public let signatureCount: Int
        public let appCount: Int
        public let databasePath: String?
        
        public var description: String {
            """
            ActivityStore Database Info:
              Schema version: \(schemaVersion)
              Transactions: \(transactionCount)
              Signatures: \(signatureCount)
              Apps: \(appCount)
              Path: \(databasePath ?? "unknown")
            """
        }
    }
    
    public func getDatabaseInfo() throws -> DatabaseInfo {
        return try queue.sync {
            try openIfNeeded()
            
            var version: Int32 = 0
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    version = sqlite3_column_int(stmt, 0)
                }
            }
            
            let txCount = countRows(table: "transactions") ?? 0
            let sigCount = countRows(table: "signatures") ?? 0
            let appCount = countRows(table: "apps") ?? 0
            
            // Get database path
            var dbPath: String? = nil
            if let pathCString = sqlite3_db_filename(db, "main") {
                dbPath = String(cString: pathCString)
            }
            
            return DatabaseInfo(
                schemaVersion: Int(version),
                transactionCount: txCount,
                signatureCount: sigCount,
                appCount: appCount,
                databasePath: dbPath
            )
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
        // v1: initial schema (apps + transactions)
        // v2: adds signatures table
        
        // Get current schema version
        var currentVersion: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                currentVersion = sqlite3_column_int(stmt, 0)
            }
        }

        if currentVersion == 0 {
            // Fresh DB: Create v2 schema directly
            try createAppsTable()
            try createTransactionsTable()
            try createSignaturesTable()
            guard exec("PRAGMA user_version = 2;") else {
                throw ActivityStoreError.schemaCreationFailed
            }
        } else if currentVersion == 1 {
            // Upgrade existing v1 DB to v2
            // Verify existing data integrity before migration
            if let rowCount = countRows(table: "transactions"), rowCount > 0 {
                // Log migration attempt (best effort)
                print("[ActivityStore] Migrating database v1→v2 with \(rowCount) existing transactions")
            }
            
            do {
                // Begin transaction for atomic migration
                guard exec("BEGIN TRANSACTION;") else {
                    throw ActivityStoreError.schemaCreationFailed
                }
                
                try createSignaturesTable()
                
                // Verify the new table was created successfully
                guard tableExists("signatures") else {
                    _ = exec("ROLLBACK;")
                    throw ActivityStoreError.schemaCreationFailed
                }
                
                guard exec("PRAGMA user_version = 2;") else {
                    _ = exec("ROLLBACK;")
                    throw ActivityStoreError.schemaCreationFailed
                }
                
                guard exec("COMMIT;") else {
                    _ = exec("ROLLBACK;")
                    throw ActivityStoreError.schemaCreationFailed
                }
                
                print("[ActivityStore] Migration v1→v2 completed successfully")
            } catch {
                // Rollback on failure
                _ = exec("ROLLBACK;")
                _ = exec("DROP TABLE IF EXISTS signatures;")
                _ = exec("PRAGMA user_version = 1;")
                print("[ActivityStore] Migration failed, rolled back to v1: \(error)")
                throw ActivityStoreError.migrationFailed
            }
        } else if currentVersion > 2 {
            // Future-proofing: warn if schema version is newer than expected
            print("[ActivityStore] Warning: database schema version \(currentVersion) is newer than expected (2)")
        }
        // If currentVersion == 2, schema is already up to date
    }

    private func createAppsTable() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS apps (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          domain TEXT,
          uri TEXT,
          scheme TEXT,
          UNIQUE(domain, uri, scheme)
        );
        """
        guard exec(sql) else {
            throw ActivityStoreError.schemaCreationFailed
        }
    }

    private func createTransactionsTable() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS transactions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tx_hash TEXT NOT NULL UNIQUE,
          app_id INTEGER NOT NULL,
          chain_id_hex TEXT NOT NULL,
          method TEXT,
          from_address TEXT,
          created_at INTEGER NOT NULL,  -- epoch seconds
          status TEXT NOT NULL DEFAULT 'pending',
          FOREIGN KEY(app_id) REFERENCES apps(id)
        );
        CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_transactions_created_id_desc ON transactions(created_at DESC, id DESC);
        """
        guard exec(sql) else {
            throw ActivityStoreError.schemaCreationFailed
        }
    }

    private func createSignaturesTable() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS signatures (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          signature_hash TEXT NOT NULL UNIQUE,
          app_id INTEGER NOT NULL,
          chain_id_hex TEXT NOT NULL,
          method TEXT NOT NULL,
          from_address TEXT,
          message_content TEXT NOT NULL,
          signature_hex TEXT NOT NULL,
          created_at INTEGER NOT NULL,  -- epoch seconds
          FOREIGN KEY(app_id) REFERENCES apps(id)
        );
        CREATE INDEX IF NOT EXISTS idx_signatures_created_at ON signatures(created_at DESC, id DESC);
        """
        guard exec(sql) else {
            throw ActivityStoreError.schemaCreationFailed
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
    
    private func tableExists(_ tableName: String) -> Bool {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (tableName as NSString).utf8String, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }
    
    private func countRows(table: String) -> Int? {
        // Note: table name is not parameterizable in SQLite, so we validate it first
        guard table.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil else {
            return nil // Reject non-alphanumeric table names for safety
        }
        
        let sql = "SELECT COUNT(*) FROM \(table);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        return Int(sqlite3_column_int(stmt, 0))
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
    case migrationFailed
}


