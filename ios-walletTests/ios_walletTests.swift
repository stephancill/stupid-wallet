//
//  ios_walletTests.swift
//  ios-walletTests
//
//  Created by Stephan on 2025/09/04.
//

import Testing
import Foundation
@testable import stupid_wallet

struct ios_walletTests {

    @Test("Valid transaction hash parses to 32-byte Data")
    func testValidTxHashParsesToData() async throws {
        let txHash = "0x6368f5c83f4f063a71cbea23d433f7e28d19b1fb3c6984916bd5d7d1bbcbf754"

        let data = Data(hexString: txHash)

        #expect(data != nil, "Expected valid tx hash to parse into Data")
        #expect(data?.count == 32, "Transaction hash should be 32 bytes")
    }

    @Test("Invalid hex strings return nil")
    func testInvalidHexStringReturnsNil() async throws {
        let invalidHex1 = "0x" // Too short
        let invalidHex2 = "0xgggg" // Invalid characters
        let invalidHex3 = "6368f5c83f4f063a71cbea23d433f7e28d19b1fb3c6984916bd5d7d1bbcbf75" // Odd length, no 0x

        #expect(Data(hexString: invalidHex1) == nil)
        #expect(Data(hexString: invalidHex2) == nil)
        #expect(Data(hexString: invalidHex3) == nil)
    }

    @Test("Hex string parsing handles different formats")
    func testHexStringFormats() async throws {
        let hexWithPrefix = "0x6368f5c83f4f063a71cbea23d433f7e28d19b1fb3c6984916bd5d7d1bbcbf754"
        let hexWithoutPrefix = "6368f5c83f4f063a71cbea23d433f7e28d19b1fb3c6984916bd5d7d1bbcbf754"

        let data1 = Data(hexString: hexWithPrefix)
        let data2 = Data(hexString: hexWithoutPrefix)

        #expect(data1 == data2, "Both formats should produce identical results")
        #expect(data1?.count == 32)
        #expect(data2?.count == 32)
    }
}
