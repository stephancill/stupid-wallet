//
//  ActivityStoreTests.swift
//

import Foundation
import Testing
@testable import stupid_wallet

struct ActivityStoreTests {
    @Test("ActivityStore opens DB, upserts app, inserts txs, and fetches in reverse order")
    func testInsertAndFetchOrdering() async throws {
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
}


