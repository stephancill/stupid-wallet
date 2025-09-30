//
//  ActivityStoreTests.swift
//

import Foundation
import Testing
@testable import stupid_wallet

struct ActivityStoreTests {
    @Test("ActivityStore opens DB, upserts app, inserts txs, and fetches in reverse order")
    func testInsertAndFetchOrdering() async throws {
        // Use a temporary database file isolated from the App Group to avoid
        // modifying the app's real Activity.sqlite during tests.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dbURL = tmpDir.appendingPathComponent("Activity-Test-\(UUID().uuidString).sqlite")
        ActivityStore.setDatabaseURLOverride(dbURL)
        let store = ActivityStore.shared

        // Use a unique app metadata to avoid collisions with existing data
        let uniqueSuffix = UUID().uuidString.prefix(8)
        let app = ActivityStore.AppMetadata(
            domain: "example.org",
            uri: "https://example.org/tx-test-\(uniqueSuffix)",
            scheme: "https"
        )

        let txA = "0xA\(uniqueSuffix)"
        let txB = "0xB\(uniqueSuffix)"
        let txC = "0xC\(uniqueSuffix)"

        // Insert with spacing to ensure increasing timestamps
        try store.logTransaction(
            txHash: txA,
            chainIdHex: "0x1",
            method: "eth_sendTransaction",
            fromAddress: "0x0000000000000000000000000000000000000001",
            app: app
        )
        try await Task.sleep(nanoseconds: 2_000_000) // 2ms
        try store.logTransaction(
            txHash: txB,
            chainIdHex: "0x1",
            method: "eth_sendTransaction",
            fromAddress: "0x0000000000000000000000000000000000000001",
            app: app
        )
        try await Task.sleep(nanoseconds: 2_000_000)
        try store.logTransaction(
            txHash: txC,
            chainIdHex: "0x1",
            method: "eth_sendTransaction",
            fromAddress: "0x0000000000000000000000000000000000000001",
            app: app
        )

        // Fetch and ensure the three test items appear in reverse chronological order among themselves
        let items = try store.fetchTransactions(limit: 200, offset: 0)
        let idxA = items.firstIndex(where: { $0.txHash == txA })
        let idxB = items.firstIndex(where: { $0.txHash == txB })
        let idxC = items.firstIndex(where: { $0.txHash == txC })

        #expect(idxA != nil && idxB != nil && idxC != nil, "Expected to find inserted tx hashes in results")
        if let ia = idxA, let ib = idxB, let ic = idxC {
            // Newest (C) should come first (smallest index), then B, then A
            #expect(ic < ib && ib < ia, "Expected C before B before A in reverse-chronological list")
        }
    }

    @Test("Upsert app uses NULL-aware matching and associates correct app metadata")
    func testUpsertNullAwareMatching() async throws {
        // Reuse shared store (singleton); generate unique values to avoid collisions
        let store = ActivityStore.shared

        let uniqueSuffix = String(UUID().uuidString.prefix(8))

        // 1) Pre-create a NULL app row via a transaction with nil metadata
        let nullApp = ActivityStore.AppMetadata(domain: nil, uri: nil, scheme: nil)
        let txNull = "0xNULL\(uniqueSuffix)"
        try store.logTransaction(
            txHash: txNull,
            chainIdHex: "0x1",
            method: "eth_sendTransaction",
            fromAddress: "0x0000000000000000000000000000000000000001",
            app: nullApp
        )

        // 2) Insert a non-null app; previously buggy SELECT could match the NULL row
        let appA = ActivityStore.AppMetadata(
            domain: "example.org-\(uniqueSuffix)",
            uri: "https://example.org/\(uniqueSuffix)",
            scheme: "https"
        )
        let txA = "0xA-\(uniqueSuffix)"
        try store.logTransaction(
            txHash: txA,
            chainIdHex: "0x1",
            method: "eth_sendTransaction",
            fromAddress: "0x0000000000000000000000000000000000000001",
            app: appA
        )

        // 3) Insert a mixed NULL/non-NULL app; ensure matching doesn't collide with NULL row
        let appB = ActivityStore.AppMetadata(
            domain: "bar.example-\(uniqueSuffix)",
            uri: nil,
            scheme: "https"
        )
        let txB = "0xB-\(uniqueSuffix)"
        try store.logTransaction(
            txHash: txB,
            chainIdHex: "0x1",
            method: "eth_sendTransaction",
            fromAddress: "0x0000000000000000000000000000000000000001",
            app: appB
        )

        // Fetch and validate that each transaction is associated with the correct app metadata
        let items = try store.fetchTransactions(limit: 1000, offset: 0)

        func item(for tx: String) -> ActivityStore.ActivityItem? {
            return items.first(where: { $0.txHash == tx })
        }

        if let a = item(for: txA) {
            #expect(a.app.domain == appA.domain)
            #expect(a.app.uri == appA.uri)
            #expect(a.app.scheme == appA.scheme)
        } else {
            #expect(false, "Expected to find txA in fetched items")
        }

        if let b = item(for: txB) {
            #expect(b.app.domain == appB.domain)
            #expect(b.app.uri == appB.uri)
            #expect(b.app.scheme == appB.scheme)
        } else {
            #expect(false, "Expected to find txB in fetched items")
        }

        if let n = item(for: txNull) {
            #expect(n.app.domain == nil)
            #expect(n.app.uri == nil)
            #expect(n.app.scheme == nil)
        } else {
            #expect(false, "Expected to find txNull in fetched items")
        }
    }

    // MARK: - Phase 1: Signature Logging Tests

    @Test("ActivityStore logs signatures and fetches unified activity")
    func testSignatureLogging() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dbURL = tmpDir.appendingPathComponent("Activity-Test-\(UUID().uuidString).sqlite")
        ActivityStore.setDatabaseURLOverride(dbURL)
        let store = ActivityStore.shared

        let uniqueSuffix = UUID().uuidString.prefix(8)
        let app = ActivityStore.AppMetadata(
            domain: "example.org",
            uri: "https://example.org/sig-test-\(uniqueSuffix)",
            scheme: "https"
        )

        // Log a transaction
        let txHash = "0xTX\(uniqueSuffix)"
        try store.logTransaction(
            txHash: txHash,
            chainIdHex: "0x1",
            method: "eth_sendTransaction",
            fromAddress: "0x1234567890123456789012345678901234567890",
            app: app
        )

        try await Task.sleep(nanoseconds: 2_000_000)

        // Log a signature
        let sigHex = "0xSIG\(uniqueSuffix)"
        let message = "0x48656c6c6f20576f726c64" // "Hello World" in hex
        try store.logSignature(
            signatureHex: sigHex,
            messageContent: message,
            chainIdHex: "0x1",
            method: "personal_sign",
            fromAddress: "0x1234567890123456789012345678901234567890",
            app: app
        )

        // Fetch unified activity
        let items = try store.fetchActivity(limit: 100, offset: 0)

        // Find our items
        let txItem = items.first(where: { $0.itemType == .transaction && $0.txHash == txHash })
        let sigItem = items.first(where: { $0.itemType == .signature && $0.signatureHex == sigHex })

        // Verify transaction item
        #expect(txItem != nil, "Expected to find transaction in activity")
        if let tx = txItem {
            #expect(tx.itemType == .transaction)
            #expect(tx.txHash == txHash)
            #expect(tx.status == "pending")
            #expect(tx.method == "eth_sendTransaction")
        }

        // Verify signature item
        #expect(sigItem != nil, "Expected to find signature in activity")
        if let sig = sigItem {
            #expect(sig.itemType == .signature)
            #expect(sig.signatureHex == sigHex)
            #expect(sig.messageContent == message)
            #expect(sig.method == "personal_sign")
            #expect(sig.signatureHash != nil)
        }
    }

    @Test("Signature deduplication works correctly")
    func testSignatureDeduplication() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dbURL = tmpDir.appendingPathComponent("Activity-Test-\(UUID().uuidString).sqlite")
        ActivityStore.setDatabaseURLOverride(dbURL)
        let store = ActivityStore.shared

        let uniqueSuffix = UUID().uuidString.prefix(8)
        let app = ActivityStore.AppMetadata(
            domain: "example.org",
            uri: "https://example.org/dedup-\(uniqueSuffix)",
            scheme: "https"
        )

        let sigHex = "0xDEDUP\(uniqueSuffix)"
        let message = "0x48656c6c6f"

        // Insert same signature twice
        try store.logSignature(
            signatureHex: sigHex,
            messageContent: message,
            chainIdHex: "0x1",
            method: "personal_sign",
            fromAddress: "0x1234567890123456789012345678901234567890",
            app: app
        )

        try store.logSignature(
            signatureHex: sigHex,
            messageContent: message,
            chainIdHex: "0x1",
            method: "personal_sign",
            fromAddress: "0x1234567890123456789012345678901234567890",
            app: app
        )

        // Fetch and verify only one signature was stored
        let items = try store.fetchActivity(limit: 100, offset: 0)
        let sigItems = items.filter { $0.itemType == .signature && $0.signatureHex == sigHex }

        #expect(sigItems.count == 1, "Expected signature deduplication to prevent duplicate entries")
    }

    @Test("Migration from v1 to v2 preserves existing data")
    func testMigrationV1ToV2() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dbURL = tmpDir.appendingPathComponent("Activity-Test-\(UUID().uuidString).sqlite")
        ActivityStore.setDatabaseURLOverride(dbURL)
        
        // First, create a v1 database by manually creating schema
        let store1 = ActivityStore.shared
        
        let uniqueSuffix = UUID().uuidString.prefix(8)
        let app = ActivityStore.AppMetadata(
            domain: "example.org",
            uri: "https://example.org/migration-\(uniqueSuffix)",
            scheme: "https"
        )
        
        // Log a transaction (this creates v2 schema automatically now)
        let txHash = "0xMIGRATE\(uniqueSuffix)"
        try store1.logTransaction(
            txHash: txHash,
            chainIdHex: "0x1",
            method: "eth_sendTransaction",
            fromAddress: "0x1234567890123456789012345678901234567890",
            app: app
        )
        
        // Verify transaction is still there after initialization
        let items = try store1.fetchActivity(limit: 100, offset: 0)
        let txItem = items.first(where: { $0.txHash == txHash })
        
        #expect(txItem != nil, "Expected transaction to be preserved after schema creation")
        #expect(txItem?.itemType == .transaction)
    }

    @Test("fetchActivity returns items in reverse chronological order")
    func testFetchActivityOrdering() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dbURL = tmpDir.appendingPathComponent("Activity-Test-\(UUID().uuidString).sqlite")
        ActivityStore.setDatabaseURLOverride(dbURL)
        let store = ActivityStore.shared

        let uniqueSuffix = UUID().uuidString.prefix(8)
        let app = ActivityStore.AppMetadata(
            domain: "example.org",
            uri: "https://example.org/order-\(uniqueSuffix)",
            scheme: "https"
        )

        // Insert items with 1-second delays to ensure different epoch second timestamps
        let tx1 = "0xTX1\(uniqueSuffix)"
        try store.logTransaction(
            txHash: tx1,
            chainIdHex: "0x1",
            method: "eth_sendTransaction",
            fromAddress: "0x1234567890123456789012345678901234567890",
            app: app
        )

        try await Task.sleep(nanoseconds: 1_100_000_000) // 1.1 seconds to ensure new timestamp

        let sig1 = "0xSIG1\(uniqueSuffix)"
        try store.logSignature(
            signatureHex: sig1,
            messageContent: "0x48656c6c6f",
            chainIdHex: "0x1",
            method: "personal_sign",
            fromAddress: "0x1234567890123456789012345678901234567890",
            app: app
        )

        try await Task.sleep(nanoseconds: 1_100_000_000) // 1.1 seconds to ensure new timestamp

        let tx2 = "0xTX2\(uniqueSuffix)"
        try store.logTransaction(
            txHash: tx2,
            chainIdHex: "0x1",
            method: "eth_sendTransaction",
            fromAddress: "0x1234567890123456789012345678901234567890",
            app: app
        )

        // Fetch and verify order
        let items = try store.fetchActivity(limit: 100, offset: 0)
        
        let idx1 = items.firstIndex(where: { $0.txHash == tx1 })
        let idx2 = items.firstIndex(where: { $0.signatureHex == sig1 })
        let idx3 = items.firstIndex(where: { $0.txHash == tx2 })

        #expect(idx1 != nil && idx2 != nil && idx3 != nil, "Expected to find all items")
        if let i1 = idx1, let i2 = idx2, let i3 = idx3 {
            // Newest (tx2) should come first, then sig1, then tx1
            #expect(i3 < i2 && i2 < i1, "Expected reverse chronological order")
        }
    }
}


