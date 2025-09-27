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
}


