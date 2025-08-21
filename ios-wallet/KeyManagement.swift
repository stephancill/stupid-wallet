//
//  KeyManagement.swift
//  ios-wallet
//
//  Created by Build System.
//

import Foundation
import Security
import BigInt
import Wallet
import Model

enum KeyManagement {
    static func createWallet() throws -> EthereumWallet  {
        let privateKeyBytes = try generateValidSecp256k1PrivateKey()
        let privateKey = Model.EthereumPrivateKey(rawBytes: privateKeyBytes)
        let standardWallet = Wallet.EthereumWallet(privateKey: privateKey)
        return try standardWallet.encryptWallet(accessGroup: Constants.accessGroup)
    }
    
    static func encryptPrivateKey(rawBytes: [UInt8]) throws {
        let modelPk = Model.EthereumPrivateKey(rawBytes: rawBytes)
        let wallet = Wallet.EthereumWallet(privateKey: modelPk)
        try wallet.encryptWallet(accessGroup: Constants.accessGroup)
    }

    // MARK: - Private helpers

    /// Generates a cryptographically secure secp256k1 private key in the range [1, n-1]
    /// using SecRandomCopyBytes and rejects values outside the valid range.
    private static func generateValidSecp256k1PrivateKey() throws -> [UInt8] {
        // secp256k1 curve order n
        let orderHex = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141"
        guard let curveOrder = BigUInt(orderHex, radix: 16) else {
            throw NSError(domain: "KeyManagement", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to compute curve order"])
        }

        while true {
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            if status != errSecSuccess { continue }

            // Interpret as big-endian integer
            let candidate = BigUInt(Data(bytes))
            if candidate == 0 { continue }
            if candidate >= curveOrder { continue }
            return bytes
        }
    }
}
