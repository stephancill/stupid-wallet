//
//  SafariWebExtensionHandler.swift
//  testapp Extension
//
//  Created by Stephan on 2025/08/19.
//

import SafariServices
import os.log
import Web3
import Wallet
import CryptoSwift
import Model

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let appGroupId = "group.co.za.stephancill.ios-wallet"
    private let logger = Logger(subsystem: "co.za.stephancill.ios-wallet", category: "SafariWebExtensionHandler")

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem

        let profile: UUID?
        if #available(iOS 17.0, macOS 14.0, *) {
            profile = request?.userInfo?[SFExtensionProfileKey] as? UUID
        } else {
            profile = request?.userInfo?["profile"] as? UUID
        }

        let message: Any?
        if #available(iOS 15.0, macOS 11.0, *) {
            message = request?.userInfo?[SFExtensionMessageKey]
        } else {
            message = request?.userInfo?["message"]
        }

        os_log(.default, "Received message from browser.runtime.sendNativeMessage: %@ (profile: %@)", String(describing: message), profile?.uuidString ?? "none")

        let response = NSExtensionItem()
        let responseMessage = handleWalletRequest(message)
        
        if #available(iOS 15.0, macOS 11.0, *) {
            response.userInfo = [ SFExtensionMessageKey: responseMessage ]
        } else {
            response.userInfo = [ "message": responseMessage ]
        }

        context.completeRequest(returningItems: [ response ], completionHandler: nil)
    }

    private func handleWalletRequest(_ message: Any?) -> [String: Any] {
        guard let messageDict = message as? [String: Any],
              let method = messageDict["method"] as? String else {
            logger.error("Invalid message format")
            return ["error": "Invalid message format"]
        }

        logger.info("Handling wallet request: \(method)")

        switch method {
        case "eth_requestAccounts":
            return handleRequestAccounts()
        case "eth_accounts":
            return handleAccounts()
        case "personal_sign":
            let params = messageDict["params"] as? [Any]
            return handlePersonalSign(params: params)
        default:
            logger.warning("Unsupported method: \(method)")
            return ["error": "Method \(method) not supported"]
        }
    }

    private func handleRequestAccounts() -> [String: Any] {
        let address = getSavedAddress()
        if let address = address {
            logger.info("Returning address for eth_requestAccounts: \(address)")
            return ["result": [address]]
        } else {
            logger.info("No address found, returning empty array")
            return ["result": []]
        }
    }

    private func handleAccounts() -> [String: Any] {
        let address = getSavedAddress()
        if let address = address {
            logger.info("Returning address for eth_accounts: \(address)")
            return ["result": [address]]
        } else {
            logger.info("No address found, returning empty array")
            return ["result": []]
        }
    }

    private func handlePersonalSign(params: [Any]?) -> [String: Any] {
        guard let params = params, params.count >= 2 else {
            return ["error": "Invalid personal_sign params"]
        }
        // Support both [data, address] and [address, data]
        let p0 = params[0]
        let p1 = params[1]
        let messageHex: String
        let addressHex: String
        if let s0 = p0 as? String, s0.hasPrefix("0x"), let s1 = p1 as? String {
            messageHex = s0; addressHex = s1
        } else if let s1 = p1 as? String, s1.hasPrefix("0x"), let s0 = p0 as? String {
            messageHex = s1; addressHex = s0
        } else if let s0 = p0 as? String, let s1 = p1 as? String {
            messageHex = s0; addressHex = s1
        } else {
            return ["error": "Invalid personal_sign params"]
        }

        guard let saved = getSavedAddress(), saved.caseInsensitiveCompare(addressHex) == .orderedSame else {
            return ["error": "Unknown address"]
        }

        guard let messageData = Data(hexString: messageHex) else {
            return ["error": "Message must be 0x-hex"]
        }

        do {
            // EIP-191 personal_sign digest: keccak256("\u{19}Ethereum Signed Message:\n" + len + message)
            let prefix = "\u{19}Ethereum Signed Message:\n\(messageData.count)"
            var prefixed = Array(prefix.utf8)
            prefixed.append(contentsOf: [UInt8](messageData))
            let digest: [UInt8] = prefixed.sha3(.keccak256)

            // Initialize account and sign digest
            let ethAddress = try Model.EthereumAddress(hex: saved)
            let account = EthereumAccount(address: ethAddress)
            let signature = try account.signDigest(digest, accessGroup: Constants.accessGroup)
            let canonical = toCanonicalSignature((v: signature.v, r: signature.r, s: signature.s))
            let sigHex = "0x" + canonical.map { String(format: "%02x", $0) }.joined()
            return ["result": sigHex]
        } catch {
            logger.error("Signing failed: \(String(describing: error))")
            return ["error": "Signing failed"]
        }
    }

    private func getSavedAddress() -> String? {
        let defaults = UserDefaults(suiteName: appGroupId)
        if defaults == nil {
            logger.error("Failed to open UserDefaults for app group: \(self.appGroupId)")
            return nil
        }
        let address = defaults?.string(forKey: "walletAddress")
        if let address = address, !address.isEmpty {
            logger.info("Loaded address from app group store")
            return address
        } else {
            logger.info("No address stored under key 'walletAddress'")
            return nil
        }
    }
}

// Helpers
private func toCanonicalSignature(_ signature: (v: UInt, r: [UInt8], s: [UInt8])) -> Data {
    // Ensure r, s are 32-byte each
    let rData = Data(signature.r)
    let sData = Data(signature.s)
    let r32 = rData.count == 32 ? rData : Data(count: 32 - rData.count) + rData
    let s32 = sData.count == 32 ? sData : Data(count: 32 - sData.count) + sData
    
    // Normalize v to 27/28 (Ethereum canonical)
    let vCanonical: UInt8
    if signature.v == 0 || signature.v == 27 {
        vCanonical = 27
    } else if signature.v == 1 || signature.v == 28 {
        vCanonical = 28
    } else {
        #if DEBUG
        print("⚠️ Unexpected v value \(signature.v); using lower-byte \(signature.v & 0xFF)")
        #endif
        vCanonical = UInt8(signature.v & 0xFF)
    }
    
    var data = Data()
    data.append(r32)
    data.append(s32)
    data.append(vCanonical)
    return data
}

private extension Data {
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard next <= hex.endIndex else { self = data; return }
            let bytes = hex[index..<next]
            if let b = UInt8(bytes, radix: 16) { data.append(b) } else { return nil }
            index = next
        }
        self = data
    }
}
