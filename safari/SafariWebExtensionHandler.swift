//
//  SafariWebExtensionHandler.swift
//  safari
//
//  Created by Stephan on 2025/08/17.
//

import SafariServices
import os.log

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    
    private let logger = Logger(subsystem: "co.za.stephancill.ios-wallet", category: "SafariExtension")
    private let appGroupId = "group.co.za.stephancill.ios-wallet" // Must match App Group capability
    
    // Connection state in-memory for demo purposes
    private var isConnected = false
    
    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let userInfo = item.userInfo as? [String: Any] else {
            logger.error("Invalid request format")
            completeRequest(context: context, error: "Invalid request format")
            return
        }
        
        logger.info("Received request: \(userInfo)")
        
        // Handle different types of requests
        if let action = userInfo["action"] as? String {
            handleLegacyAction(action: action, context: context)
        } else if let method = userInfo["method"] as? String {
            handleEthereumMethod(method: method, params: userInfo["params"], context: context)
        } else {
            completeRequest(context: context, error: "No action or method specified")
        }
    }
    
    private func handleLegacyAction(action: String, context: NSExtensionContext) {
        let response = NSExtensionItem()
        
        switch action {
        case "getAddress":
            response.userInfo = ["result": getSavedAddress() ?? ""]
        default:
            response.userInfo = ["error": "Unsupported action: \(action)"]
        }
        
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
    
    private func handleEthereumMethod(method: String, params: Any?, context: NSExtensionContext) {
        logger.info("Handling Ethereum method: \(method)")
        
        switch method {
        case "eth_requestAccounts":
            handleRequestAccounts(context: context)
            
        case "eth_accounts":
            handleGetAccounts(context: context)
            
        case "eth_chainId":
            completeRequest(context: context, result: "0x1") // Ethereum mainnet
            
        default:
            completeRequest(context: context, error: "Method \(method) not implemented")
        }
    }
    
    private func handleRequestAccounts(context: NSExtensionContext) {
        // In a real implementation, this would:
        // 1. Check if the user has already authorized this website
        // 2. If not, show a permission dialog in the main app
        // 3. Return the accounts the user has authorized
        
        // For now, we'll simulate user approval
        logger.info("Requesting accounts - simulating user approval")
        
        // TODO: Implement proper user consent flow
        // This should communicate with the main iOS app to:
        // - Show a permission dialog
        // - Get user approval
        // - Return the appropriate accounts
        
        isConnected = true
        if let address = getSavedAddress(), !address.isEmpty {
            completeRequest(context: context, result: [address])
        } else {
            completeRequest(context: context, result: [])
        }
    }
    
    private func handleGetAccounts(context: NSExtensionContext) {
        // Return accounts only if user has previously connected
        if let address = getSavedAddress(), isConnected {
            logger.info("Returning accounts: \(address)")
            completeRequest(context: context, result: [address])
        } else {
            completeRequest(context: context, result: [])
        }
    }

    private func getSavedAddress() -> String? {
        let defaults = UserDefaults(suiteName: appGroupId)
        let address = defaults?.string(forKey: "walletAddress")
        return address
    }
    
    private func completeRequest(context: NSExtensionContext, result: Any) {
        let response = NSExtensionItem()
        response.userInfo = ["result": result]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
    
    private func completeRequest(context: NSExtensionContext, error: String) {
        let response = NSExtensionItem()
        response.userInfo = ["error": error]
        context.completeRequest(returningItems: [response], completionHandler: nil)
        logger.error("Request completed with error: \(error)")
    }
}
