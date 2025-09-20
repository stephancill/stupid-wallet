//
//  ios_walletTests.swift
//  ios-walletTests
//
//  Created by Stephan on 2025/09/04.
//

import Testing
import Foundation
import CryptoSwift
import BigInt
@testable import stupid_wallet

struct ios_walletTests {
    @Test("EIP-712 digest matches viem for PermitWitnessTransferFrom (shared hasher)")
    func testEIP712DigestMatchesViem() async throws {
        let json = "{" +
        "\"types\":{\"PermitWitnessTransferFrom\":[{\"name\":\"permitted\",\"type\":\"TokenPermissions\"},{\"name\":\"spender\",\"type\":\"address\"},{\"name\":\"nonce\",\"type\":\"uint256\"},{\"name\":\"deadline\",\"type\":\"uint256\"},{\"name\":\"witness\",\"type\":\"PriorityOrder\"}],\"TokenPermissions\":[{\"name\":\"token\",\"type\":\"address\"},{\"name\":\"amount\",\"type\":\"uint256\"}],\"PriorityOrder\":[{\"name\":\"info\",\"type\":\"OrderInfo\"},{\"name\":\"cosigner\",\"type\":\"address\"},{\"name\":\"auctionStartBlock\",\"type\":\"uint256\"},{\"name\":\"baselinePriorityFeeWei\",\"type\":\"uint256\"},{\"name\":\"input\",\"type\":\"PriorityInput\"},{\"name\":\"outputs\",\"type\":\"PriorityOutput[]\"}],\"OrderInfo\":[{\"name\":\"reactor\",\"type\":\"address\"},{\"name\":\"swapper\",\"type\":\"address\"},{\"name\":\"nonce\",\"type\":\"uint256\"},{\"name\":\"deadline\",\"type\":\"uint256\"},{\"name\":\"additionalValidationContract\",\"type\":\"address\"},{\"name\":\"additionalValidationData\",\"type\":\"bytes\"}],\"PriorityInput\":[{\"name\":\"token\",\"type\":\"address\"},{\"name\":\"amount\",\"type\":\"uint256\"},{\"name\":\"mpsPerPriorityFeeWei\",\"type\":\"uint256\"}],\"PriorityOutput\":[{\"name\":\"token\",\"type\":\"address\"},{\"name\":\"amount\",\"type\":\"uint256\"},{\"name\":\"mpsPerPriorityFeeWei\",\"type\":\"uint256\"},{\"name\":\"recipient\",\"type\":\"address\"}],\"EIP712Domain\":[{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"chainId\",\"type\":\"uint256\"},{\"name\":\"verifyingContract\",\"type\":\"address\"}]}," +
        "\"domain\":{\"name\":\"Permit2\",\"chainId\":\"8453\",\"verifyingContract\":\"0x000000000022d473030f116ddee9f6b43ac78ba3\"}," +
        "\"primaryType\":\"PermitWitnessTransferFrom\",\"message\":{\"permitted\":{\"token\":\"0x833589fcd6edb6e08f4c7c32d4f71b54bda02913\",\"amount\":\"5000000\"},\"spender\":\"0x000000001ec5656dcdb24d90dfa42742738de729\",\"nonce\":\"109787182982308568557672685848908002651268666722401120803881746837175375929345\",\"deadline\":\"1758362523\",\"witness\":{\"info\":{\"reactor\":\"0x000000001ec5656dcdb24d90dfa42742738de729\",\"swapper\":\"0x8d25687829d6b85d9e0020b8c89e3ca24de20a89\",\"nonce\":\"109787182982308568557672685848908002651268666722401120803881746837175375929345\",\"deadline\":\"1758362523\",\"additionalValidationContract\":\"0x0000000000000000000000000000000000000000\",\"additionalValidationData\":\"0x\"},\"cosigner\":\"0x147d8c685f04296775f233ba9d2997c424c3e9d4\",\"auctionStartBlock\":\"35786509\",\"baselinePriorityFeeWei\":\"0\",\"input\":{\"token\":\"0x833589fcd6edb6e08f4c7c32d4f71b54bda02913\",\"amount\":\"5000000\",\"mpsPerPriorityFeeWei\":\"0\"},\"outputs\":[{\"token\":\"0xfde4c96c8593536e31f229ea8f37b2ada2699bb2\",\"amount\":\"4994951\",\"mpsPerPriorityFeeWei\":\"1\",\"recipient\":\"0x8d25687829d6b85d9e0020b8c89e3ca24de20a89\"}]}}}"

        let expected = "0x246219975cf9f81c34fc2a45dfa8969b2f25df8bd154fe3644b38a43c5305a73"

        guard let digest = try EIP712.computeDigest(typedDataJSON: json) else {
            #expect(Bool(false), "Failed to compute EIP-712 digest")
            return
        }

        let hex = "0x" + digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex.lowercased() == expected.lowercased(), "Expected viem hash")
    }
}
