//
//  KeyManagement.swift
//  ios-wallet
//
//  Created by Build System.
//

import Foundation
import Wallet
import Model

enum KeyManagement {
    static func createWallet() throws -> EthereumWallet  {
        let privateKey = EthereumPrivateKey(rawBytes: [])
        let standardWallet = EthereumWallet(privateKey: privateKey)
        return try standardWallet.encryptWallet(accessGroup: Constants.accessGroup)
    }
    
    static func encryptPrivateKey(rawBytes: [UInt8]) throws {
        let modelPk = Model.EthereumPrivateKey(rawBytes: rawBytes)
        let wallet = Wallet.EthereumWallet(privateKey: modelPk)
        try wallet.encryptWallet(accessGroup: Constants.accessGroup)
    }
}
