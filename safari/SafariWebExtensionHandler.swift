//
//  SafariWebExtensionHandler.swift
//  testapp Extension
//
//  Created by Stephan on 2025/08/19.
//

import SafariServices
import os.log

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
