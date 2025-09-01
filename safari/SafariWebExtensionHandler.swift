//
//  SafariWebExtensionHandler.swift
//  testapp Extension
//
//  Created by Stephan on 2025/08/19.
//

import SafariServices
import os.log
import Web3
import Web3PromiseKit
import PromiseKit
import BigInt
import Wallet
import CryptoSwift
import Model
import Web3ContractABI

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let appGroupId = Constants.appGroupId
    private let logger = Logger(subsystem: "co.za.stephancill.stupid-wallet", category: "SafariWebExtensionHandler")

    // EIP-7702 constants
    private let simple7702AccountAddress = "0xe6Cae83BdE06E4c305530e199D7217f42808555B"

    // EIP-7702 Authorization structure
    struct EIP7702Authorization {
        let chainId: BigUInt
        let address: String // Using string representation for now
        let nonce: BigUInt
        let r: Data
        let s: Data
        let v: UInt8
    }

    struct AppMetadata {
        let domain: String?
        let uri: String?
        let scheme: String?
    }

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

        // Extract app metadata from request context and message
        let appMetadata = extractAppMetadata(from: request, message: message)

        os_log(.default, "Received message from browser.runtime.sendNativeMessage: %@ (profile: %@, domain: %@)", String(describing: message), profile?.uuidString ?? "none", appMetadata.domain ?? "unknown")

        let response = NSExtensionItem()
        let responseMessage = handleWalletRequest(message, appMetadata: appMetadata)
        
        if #available(iOS 15.0, macOS 11.0, *) {
            response.userInfo = [ SFExtensionMessageKey: responseMessage ]
        } else {
            response.userInfo = [ "message": responseMessage ]
        }

        context.completeRequest(returningItems: [ response ], completionHandler: nil)
    }

    private func extractAppMetadata(from request: NSExtensionItem?, message: Any?) -> AppMetadata {
        // First try to get site metadata from the message (passed from background script)
        if let messageDict = message as? [String: Any],
           let siteMetadata = messageDict["siteMetadata"] as? [String: Any] {
            if let domain = siteMetadata["domain"] as? String,
               let url = siteMetadata["url"] as? String,
               let scheme = siteMetadata["scheme"] as? String {
                logger.info("Extracted site metadata from message: domain=\(domain), url=\(url)")
                return AppMetadata(
                    domain: domain,
                    uri: url,
                    scheme: scheme
                )
            }
        }

        // Fallback: Try to extract URL from the request context
        // Safari extensions may provide URL information through various means

        // Check for URL in attachments
        if let attachments = request?.attachments {
            for attachment in attachments {
                if attachment.hasItemConformingToTypeIdentifier("public.url"),
                   let urlData = attachment.loadItem(forTypeIdentifier: "public.url") as? URL {
                    logger.info("Extracted site metadata from attachments: domain=\(urlData.host ?? "nil"), url=\(urlData.absoluteString)")
                    return AppMetadata(
                        domain: urlData.host,
                        uri: urlData.absoluteString,
                        scheme: urlData.scheme
                    )
                }
            }
        }

        // Check for URL in userInfo
        if let userInfo = request?.userInfo {
            if let urlString = userInfo["url"] as? String,
               let url = URL(string: urlString) {
                logger.info("Extracted site metadata from userInfo: domain=\(url.host ?? "nil"), url=\(url.absoluteString)")
                return AppMetadata(
                    domain: url.host,
                    uri: url.absoluteString,
                    scheme: url.scheme
                )
            }
        }

        // Try to get URL from NSExtensionContext if available
        if request?.userInfo?["NSExtensionContext"] as? NSExtensionContext != nil {
            // This is a fallback - in practice, Safari might not provide this
            // But it's worth trying for future compatibility
        }

        // Final fallback to unknown
        logger.info("No site metadata found, falling back to unknown domain")
        return AppMetadata(domain: nil, uri: nil, scheme: nil)
    }

    private func handleWalletRequest(_ message: Any?, appMetadata: AppMetadata) -> [String: Any] {
        guard let messageDict = message as? [String: Any],
              let method = messageDict["method"] as? String else {
            logger.error("Invalid message format")
            return ["error": "Invalid message format"]
        }

        logger.info("Handling wallet request: \(method)")

        switch method {
        case "eth_requestAccounts":
            return handleRequestAccounts()
        case "wallet_connect":
            let params = messageDict["params"] as? [Any]
            return handleWalletConnect(params: params, appMetadata: appMetadata)
        case "wallet_disconnect":
            return handleWalletDisconnect()
        case "eth_accounts":
            return handleAccounts()
        case "eth_chainId":
            return handleChainId()
        case "eth_blockNumber":
            return handleBlockNumber()
        case "personal_sign":
            let params = messageDict["params"] as? [Any]
            return handlePersonalSign(params: params)
        case "eth_signTypedData_v4":
            let params = messageDict["params"] as? [Any]
            return handleSignTypedDataV4(params: params)
        case "eth_sendTransaction":
            let params = messageDict["params"] as? [Any]
            return handleSendTransaction(params: params)
        case "wallet_addEthereumChain":
            let params = messageDict["params"] as? [Any]
            return handleAddEthereumChain(params: params)
        case "wallet_switchEthereumChain":
            let params = messageDict["params"] as? [Any]
            return handleSwitchEthereumChain(params: params)
        case "wallet_sendCalls":
            let params = messageDict["params"] as? [Any]
            return handleWalletSendCalls(params: params)
        case "wallet_getCapabilities":
            let params = messageDict["params"] as? [Any]
            return handleWalletGetCapabilities(params: params)
        case "wallet_getCallsStatus":
            let params = messageDict["params"] as? [Any]
            return handleWalletGetCallsStatus(params: params)
        default:
            logger.warning("Unsupported method: \(method)")
            return ["error": "Method \(method) not supported"]
        }
    }

    private func handleAddEthereumChain(params: [Any]?) -> [String: Any] {
        guard let obj = (params?.first as? [String: Any]) else {
            return ["error": "Invalid wallet_addEthereumChain params"]
        }
        guard let chainIdHex = obj["chainId"] as? String, !chainIdHex.isEmpty else {
            return ["error": "Missing chainId"]
        }
        // Persist chain metadata and optional rpcUrls override
        let defaults = UserDefaults(suiteName: appGroupId)
        var chains = defaults?.dictionary(forKey: "customChains") as? [String: [String: Any]] ?? [:]
        chains[chainIdHex.lowercased()] = obj
        defaults?.set(chains, forKey: "customChains")
        // If not current, do not switch automatically
        return ["result": true]
    }

    private func handleSwitchEthereumChain(params: [Any]?) -> [String: Any] {
        guard let obj = (params?.first as? [String: Any]), let chainIdHex = obj["chainId"] as? String else {
            return ["error": "Invalid wallet_switchEthereumChain params"]
        }
        Constants.Networks.setCurrentChainIdHex(chainIdHex)
        return ["result": chainIdHex.lowercased()]
    }

    private func handleChainId() -> [String: Any] {
        return ["result": Constants.Networks.getCurrentChainIdHex()]
    }

    private func handleBlockNumber() -> [String: Any] {
        let (rpcURL, _) = Constants.Networks.currentNetwork()
        let web3 = Web3(rpcURL: rpcURL)
        switch awaitPromise(web3.eth.blockNumber()) {
        case .success(let num):
            return ["result": num.hex()]
        case .failure:
            return ["error": "Failed to get block number"]
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

    private func handleWalletConnect(params: [Any]?, appMetadata: AppMetadata) -> [String: Any] {
        let address = getSavedAddress()
        guard let address = address else {
            logger.info("No address found, returning empty array")
            return ["result": []]
        }

        // Parse request parameters
        var requestCapabilities: [String: Any]? = nil
        var requestedChainIds: [String]? = nil

        if let dict = params?.first as? [String: Any] {
            requestCapabilities = dict["capabilities"] as? [String: Any]
            requestedChainIds = dict["chainIds"] as? [String]
            // Version is parsed but not used in current implementation
        }

        // Validate chain IDs if provided
        var supportedChainIds: [String] = []
        if let requested = requestedChainIds {
            for chainIdHex in requested {
                if isChainSupported(chainIdHex) {
                    supportedChainIds.append(chainIdHex.lowercased())
                }
            }
            if supportedChainIds.isEmpty {
                return ["error": "5710 Unsupported Chain"]
            }
        } else {
            // If no chainIds requested, use current chain
            supportedChainIds = [Constants.Networks.getCurrentChainIdHex()]
        }

        // Process capabilities
        var account: [String: Any] = ["address": address]
        var capabilities: [String: Any] = [:]

        if let reqCaps = requestCapabilities {
            if let siweParams = reqCaps["signInWithEthereum"] as? [String: Any] {
                do {
                    let siweResult = try handleSignInWithEthereum(params: siweParams, address: address, chainIds: supportedChainIds, appMetadata: appMetadata)
                    capabilities["signInWithEthereum"] = siweResult
                } catch {
                    logger.error("SIWE signing failed: \(error)")
                    return ["error": "SIWE signing failed"]
                }
            }
        }

        account["capabilities"] = capabilities

        logger.info("Returning wallet_connect response for address: \(address)")
        return ["result": [
            "accounts": [account],
            "chainIds": supportedChainIds
        ]]
    }

    private func handleWalletDisconnect() -> [String: Any] {
        // According to spec: revoke access to user account info and capabilities
        // In this implementation, we don't maintain persistent sessions beyond stored address
        // So we just return success - the app can clear its local state
        logger.info("Handling wallet_disconnect - no persistent session to revoke")
        return ["result": true]
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

    private func handleSignTypedDataV4(params: [Any]?) -> [String: Any] {
        guard let params = params, params.count >= 2 else {
            return ["error": "Invalid eth_signTypedData_v4 params"]
        }
        let addressParam = params[0]
        let typedDataParam = params[1]
        guard let addressHex = addressParam as? String, let typedDataJSON = typedDataParam as? String else {
            return ["error": "Invalid eth_signTypedData_v4 params"]
        }
        guard let saved = getSavedAddress(), saved.caseInsensitiveCompare(addressHex) == .orderedSame else {
            return ["error": "Unknown address"]
        }

        do {
            guard let digest = try EIP712.computeDigest(typedDataJSON: typedDataJSON) else {
                return ["error": "Failed to compute EIP-712 digest"]
            }
            let account = EthereumAccount(address: try Model.EthereumAddress(hex: saved))
            let signature = try account.signDigest([UInt8](digest), accessGroup: Constants.accessGroup)
            let canonical = toCanonicalSignature((v: signature.v, r: signature.r, s: signature.s))
            let sigHex = "0x" + canonical.map { String(format: "%02x", $0) }.joined()
            return ["result": sigHex]
        } catch {
            logger.error("EIP-712 signing failed: \(String(describing: error))")
            return ["error": "Signing failed"]
        }
    }

    private func handleSendTransaction(params: [Any]?) -> [String: Any] {
        guard let params = params, params.count >= 1 else {
            return ["error": "Invalid eth_sendTransaction params"]
        }
        guard let tx = params[0] as? [String: Any] else {
            return ["error": "Invalid transaction object"]
        }

        guard let fromHex = (tx["from"] as? String) ?? getSavedAddress() else {
            return ["error": "Missing from address"]
        }
        guard let saved = getSavedAddress(), saved.caseInsensitiveCompare(fromHex) == .orderedSame else {
            return ["error": "Unknown address"]
        }

        let toHex = tx["to"] as? String
        let valueHex = (tx["value"] as? String) ?? "0x0"
        let dataHex = (tx["data"] as? String) ?? (tx["input"] as? String) ?? "0x"
        let gasHex = tx["gas"] as? String ?? tx["gasLimit"] as? String
        let gasPriceHex = tx["gasPrice"] as? String
        let nonceHex = tx["nonce"] as? String
        let maxFeePerGasHex = tx["maxFeePerGas"] as? String
        let maxPriorityFeePerGasHex = tx["maxPriorityFeePerGas"] as? String

        do {
            let (rpcURL, chainIdBig) = Constants.Networks.currentNetwork()
            let web3 = Web3(rpcURL: rpcURL)

            let fromAddr = try EthereumAddress(hex: fromHex, eip55: false)
            let toAddr = (toHex != nil && !(toHex!).isEmpty) ? (try? EthereumAddress(hex: toHex!, eip55: false)) : nil

            // Nonce
            let nonce: EthereumQuantity
            if let nonceHex = nonceHex, let n = BigUInt.fromHexQuantity(nonceHex) {
                nonce = EthereumQuantity(quantity: n)
            } else {
                switch awaitPromise(web3.eth.getTransactionCount(address: fromAddr, block: .latest)) {
                case .success(let n): nonce = n
                case .failure:
                    return ["error": "Failed to get nonce"]
                }
            }

            // Value
            let weiValue = BigUInt.fromHexQuantity(valueHex) ?? BigUInt.zero

            // Gas limit: provided or sane default
            let gasLimitQty: BigUInt = {
                if let gasHex = gasHex, let g = BigUInt.fromHexQuantity(gasHex) { return g }
                return (dataHex == "0x") ? BigUInt(21000) : BigUInt(100000)
            }()

            // Build base tx
            var txToSign = try EthereumTransaction(
                nonce: nonce,
                gasPrice: nil,
                gasLimit: EthereumQuantity(gasLimitQty),
                to: toAddr,
                value: EthereumQuantity(quantity: weiValue)
            )

            // Fees: prefer EIP-1559
            if let maxFee = BigUInt.fromHexQuantity(maxFeePerGasHex ?? ""), let maxPrio = BigUInt.fromHexQuantity(maxPriorityFeePerGasHex ?? "") {
                txToSign.transactionType = EthereumTransaction.TransactionType.eip1559
                txToSign.maxFeePerGas = EthereumQuantity(quantity: maxFee)
                txToSign.maxPriorityFeePerGas = EthereumQuantity(quantity: maxPrio)
            } else {
                let legacyGasPrice: EthereumQuantity
                if let gasPriceHex = gasPriceHex, let gp = BigUInt.fromHexQuantity(gasPriceHex) {
                    legacyGasPrice = EthereumQuantity(quantity: gp)
                } else {
                    switch awaitPromise(web3.eth.gasPrice()) {
                    case .success(let gp): legacyGasPrice = gp
                    case .failure: return ["error": "Failed to get gas price"]
                    }
                }
                txToSign.gasPrice = legacyGasPrice
            }

            // Data
            if dataHex != "0x", let raw = Data(hexString: dataHex) {
                // Require 'to' for data txs to avoid accidental contract creation
                if toAddr == nil {
                    return ["error": "Missing 'to' for transaction with data"]
                }
                // Optional: Ensure target has code
                switch awaitPromise(web3.eth.getCode(address: toAddr!, block: .latest)) {
                case .success(let code):
                    if code.bytes.isEmpty {
                        return ["error": "Target address has no contract code"]
                    }
                case .failure:
                    break
                }
                txToSign.data = try EthereumData(raw)
            }
            
            // Sign (non-exportable key) by hashing the tx message and using account.signDigest
            let signedTx: EthereumSignedTransaction
            do {
                let msg = try computeTransactionMessageToSign(tx: txToSign, chainId: EthereumQuantity(quantity: chainIdBig))
                let digest = Data(msg).sha3(.keccak256)
                let account = EthereumAccount(address: try Model.EthereumAddress(hex: saved))
                let sig = try account.signDigest([UInt8](digest), accessGroup: Constants.accessGroup)

                // Normalize v per tx type
                let recId: BigUInt = {
                    if sig.v == 27 || sig.v == 28 { return BigUInt(sig.v - 27) }
                    return BigUInt(sig.v)
                }()
                let vFinal: EthereumQuantity = {
                    switch txToSign.transactionType {
                    case .legacy:
                        if chainIdBig == 0 { return EthereumQuantity(quantity: recId + 27) }
                        return EthereumQuantity(quantity: recId + 35 + (chainIdBig * 2))
                    case .eip1559:
                        return EthereumQuantity(quantity: recId)
                    }
                }()

                let rQ = EthereumQuantity(quantity: BigUInt(sig.r))
                let sQ = EthereumQuantity(quantity: BigUInt(sig.s))

                let signed = EthereumSignedTransaction(
                    nonce: txToSign.nonce!,
                    gasPrice: txToSign.gasPrice ?? EthereumQuantity(quantity: 0),
                    maxFeePerGas: txToSign.maxFeePerGas,
                    maxPriorityFeePerGas: txToSign.maxPriorityFeePerGas,
                    gasLimit: txToSign.gasLimit!,
                    to: txToSign.to,
                    value: txToSign.value ?? EthereumQuantity(quantity: 0),
                    data: txToSign.data,
                    v: vFinal,
                    r: rQ,
                    s: sQ,
                    chainId: EthereumQuantity(quantity: chainIdBig),
                    accessList: txToSign.accessList,
                    transactionType: txToSign.transactionType
                )
                signedTx = signed
            } catch {
                logger.error("Signing error: \(String(describing: error))")
                return ["error": "Failed to sign transaction: \(error.localizedDescription)"]
            }

            // Send
            switch awaitPromise(web3.eth.sendRawTransaction(transaction: signedTx)) {
            case .success(let txHash):
                return ["result": txHash.hex()]
            case .failure(let e):
                logger.error("Broadcast failed: \(String(describing: e))")
                return ["error": "Failed to send transaction: \(e.localizedDescription)"]
            }
        } catch {
            return ["error": "eth_sendTransaction failed"]
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

    private func isChainSupported(_ chainIdHex: String) -> Bool {
        let cleanHex = chainIdHex.lowercased()
        let clean = cleanHex.hasPrefix("0x") ? String(cleanHex.dropFirst(2)) : cleanHex
        guard let chainId = BigUInt(clean, radix: 16) else { return false }

        // Check if it's in default networks
        if Constants.Networks.defaultNetworksByChainId[chainId] != nil {
            return true
        }

        // Check if it's in custom networks
        let customNetworks = Constants.Networks.loadCustomNetworks()
        return customNetworks[chainId] != nil
    }

    private func handleWalletSendCalls(params: [Any]?) -> [String: Any] {
        guard let params = params, let callsObj = params.first as? [String: Any] else {
            return ["error": "Invalid wallet_sendCalls params"]
        }

        guard let calls = callsObj["calls"] as? [[String: Any]] else {
            return ["error": "Missing calls array"]
        }

        // Extract version for response format (EIP-5792)
        let version = callsObj["version"] as? Int ?? 1

        guard let fromAddress = getSavedAddress() else {
            return ["error": "No wallet address available"]
        }

        // Create addresses we'll need
        let fromAddr = try! EthereumAddress(hex: fromAddress, eip55: false)

        do {
            let (rpcURL, chainIdBig) = Constants.Networks.currentNetwork()
            let web3 = Web3(rpcURL: rpcURL)

            let simple7702Addr = try EthereumAddress(hex: self.simple7702AccountAddress, eip55: false)

            // Check if Simple7702Account is deployed on this chain
            switch awaitPromise(web3.eth.getCode(address: simple7702Addr, block: .latest)) {
            case .success(let code):
                if code.bytes.isEmpty {
                    return ["error": "Simple7702Account not deployed on this chain"]
                }
            case .failure:
                return ["error": "Failed to check Simple7702Account deployment"]
            }

            // Parse calls and check which need authorization
            var authorizationList: [EIP7702Authorization] = []
            var batchCalls: [[String: Any]] = []

            // Check if user's wallet needs delegation to Simple7702Account
            var needsDelegation = false
            switch awaitPromise(web3.eth.getCode(address: fromAddr, block: .latest)) {
            case .success(let code):
                if code.bytes.isEmpty {
                    // Empty code - needs delegation
                    needsDelegation = true
                    logger.info("Need delegation for user's wallet - empty code")
                } else if code.bytes.count == 23 && code.bytes.starts(with: [0xef, 0x01, 0x00]) {
                    // Check if already delegated to Simple7702Account
                    let delegatedAddress = Array(code.bytes[3...]) // Skip 0xef0100 prefix
                    let expectedAddress = simple7702Addr.rawAddress
                    if delegatedAddress != expectedAddress {
                        // Delegated to wrong address - needs re-delegation
                        needsDelegation = true
                        logger.info("Need delegation for user's wallet - delegated to wrong address")
                    } else {
                        // Already properly delegated
                        logger.info("Skipping delegation for user's wallet - already properly delegated")
                    }
                } else {
                    // Has code but not a delegation indicator - needs delegation to replace
                    needsDelegation = true
                    logger.info("Need delegation for user's wallet - has non-delegation code")
                }
            case .failure:
                return ["error": "Failed to check code for user's wallet"]
            }

            if needsDelegation {
                // Sign authorization to delegate user's wallet to Simple7702Account
                logger.info("Creating authorization to delegate user's wallet to Simple7702Account")
                let authorization = try signEIP7702Authorization(
                    contractAddress: self.simple7702AccountAddress,
                    chainId: chainIdBig,
                    fromAddress: fromAddress
                )
                authorizationList.append(authorization)
            }

            // Process batch calls (no authorization needed for target contracts)
            for call in calls {
                guard let targetHex = call["to"] as? String else {
                    return ["error": "Missing 'to' field in call"]
                }

                // Add to batch calls
                let valueHex = call["value"] as? String ?? "0x0"
                let dataHex = call["data"] as? String ?? "0x"
                batchCalls.append([
                    "target": targetHex,
                    "value": valueHex,
                    "data": dataHex
                ])
            }

            // Log authorization summary
            if authorizationList.isEmpty {
                logger.info("Authorization summary: No authorization needed - user's wallet already properly delegated to Simple7702Account")
            } else {
                logger.info("Authorization summary: 1 authorization created to delegate user's wallet to Simple7702Account")
            }

            // Create executeBatch transaction
            let result = try createExecuteBatchTransaction(
                calls: batchCalls,
                authorizations: authorizationList,
                fromAddress: fromAddress,
                chainIdBig: chainIdBig,
                version: version
            )

            return result

        } catch {
            logger.error("wallet_sendCalls failed: \(String(describing: error))")
            return ["error": "Failed to process batch calls: \(error.localizedDescription)"]
        }
    }

    private func handleWalletGetCapabilities(params: [Any]?) -> [String: Any] {
        // Check if user has authorized a connection (has wallet address)
        guard let walletAddress = getSavedAddress() else {
            logger.info("wallet_getCapabilities: No wallet address found - user not authorized")
            return ["error": ["code": 4100, "message": "Unauthorized"]]
        }

        logger.info("wallet_getCapabilities: Processing request for address \(walletAddress)")

        // Parse parameters: [address, optional chainIds array]
        var requestedAddress: String? = nil
        var requestedChainIds: [String]? = nil

        if let params = params, params.count >= 1 {
            requestedAddress = params[0] as? String
            if params.count >= 2 {
                requestedChainIds = params[1] as? [String]
            }
        }

        // Validate the requested address matches the authorized address
        if let requested = requestedAddress, requested.caseInsensitiveCompare(walletAddress) != .orderedSame {
            logger.warning("wallet_getCapabilities: Requested address \(requested) does not match authorized address \(walletAddress)")
            return ["error": ["code": 4100, "message": "Unauthorized"]]
        }

        // Determine which chain IDs to return capabilities for
        var chainIdsToQuery: [String] = []
        if let requested = requestedChainIds {
            // Filter to only supported chains
            for chainIdHex in requested {
                if isChainSupported(chainIdHex) {
                    chainIdsToQuery.append(chainIdHex.lowercased())
                }
            }
            // If none of the requested chains are supported, return error
            if chainIdsToQuery.isEmpty {
                return ["error": "No supported chains found in request"]
            }
        } else {
            // If no chain IDs specified, return capabilities for current chain
            chainIdsToQuery = [Constants.Networks.getCurrentChainIdHex()]
        }

        // Build capabilities response
        var capabilities: [String: [String: [String: Any]]] = [:]

        // Add capabilities for each requested chain
        for chainIdHex in chainIdsToQuery {
            var chainCapabilities: [String: [String: Any]] = [:]

            // Add atomic capability (since wallet_sendCalls is supported)
            chainCapabilities["atomic"] = [
                "supported": true
            ]

            capabilities[chainIdHex] = chainCapabilities
        }

        // Add cross-chain capabilities (0x0 represents capabilities across all chains)
        var globalCapabilities: [String: [String: Any]] = [:]
        globalCapabilities["atomic"] = [
            "supported": true
        ]
        capabilities["0x0"] = globalCapabilities

        logger.info("wallet_getCapabilities: Returning capabilities for chains: \(chainIdsToQuery)")
        return ["result": capabilities]
    }

    private func handleWalletGetCallsStatus(params: [Any]?) -> [String: Any] {
        guard let params = params, params.count >= 1,
              let callBundleId = params[0] as? String else {
            return ["error": "Invalid wallet_getCallsStatus params - missing call bundle ID"]
        }

        logger.info("wallet_getCallsStatus: Processing request for call bundle ID: \(callBundleId)")

        // The callBundleId should be the transaction hash from wallet_sendCalls
        let (rpcURL, chainIdBig) = Constants.Networks.currentNetwork()
        let web3 = Web3(rpcURL: rpcURL)

        do {
            // Convert hex string to bytes for EthereumData
            guard let txHashData = Data(hexString: callBundleId) else {
                logger.error("Invalid transaction hash format: \(callBundleId)")
                return ["error": "Invalid transaction hash format"]
            }

            // Get transaction receipt
            let receiptPromise = web3.eth.getTransactionReceipt(transactionHash: EthereumData([UInt8](txHashData)))
            let receiptResult = awaitPromise(receiptPromise)

            switch receiptResult {
            case .success(let receipt):
                guard let receipt = receipt else {
                    // Transaction not found or not mined yet
                    return ["result": [
                        "version": "2.0.0",
                        "chainId": Constants.Networks.getCurrentChainIdHex(),
                        "id": callBundleId,
                        "status": 100, // Batch has been received but not completed onchain
                        "atomic": true
                    ]]
                }

                // Get transaction details for additional info
                let txPromise = web3.eth.getTransactionByHash(blockHash: EthereumData([UInt8](txHashData)))
                let txResult = awaitPromise(txPromise)

                var transactionHash: String
                var blockHash: String
                var blockNumber: String
                var gasUsed: String
                var logs: [[String: Any]] = []
                var status: Int

                switch txResult {
                case .success(let tx):
                    transactionHash = tx!.hash.hex()
                    blockHash = receipt.blockHash.hex()
                    blockNumber = receipt.blockNumber.hex()
                    gasUsed = receipt.gasUsed.hex()

                    // Format logs
                    for log in receipt.logs {
                        var logDict: [String: Any] = [
                            "address": log.address.hex(eip55: true),
                            "topics": log.topics.map { $0.hex() },
                            "data": log.data.hex()
                        ]
                        if let logIndex = log.logIndex {
                            logDict["logIndex"] = logIndex.hex()
                        }
                        if let transactionIndex = log.transactionIndex {
                            logDict["transactionIndex"] = transactionIndex.hex()
                        }
                        if let transactionHash = log.transactionHash {
                            logDict["transactionHash"] = transactionHash.hex()
                        }
                        if let blockHash = log.blockHash {
                            logDict["blockHash"] = blockHash.hex()
                        }
                        if let blockNumber = log.blockNumber {
                            logDict["blockNumber"] = blockNumber.hex()
                        }
                        logs.append(logDict)
                    }

                    // Determine status code based on receipt status
                    // receipt.status is EthereumQuantity? (1 for success, 0 for failure)
                    if let statusValue = receipt.status, statusValue.quantity == 1 {
                        status = 200 // Batch has been included onchain without reverts
                    } else {
                        status = 500 // Batch reverted completely
                    }

                case .failure:
                    // Transaction found but couldn't get details
                    transactionHash = callBundleId
                    blockHash = receipt.blockHash.hex()
                    blockNumber = receipt.blockNumber.hex()
                    gasUsed = receipt.gasUsed.hex()
                    // receipt.status is EthereumQuantity? (1 for success, 0 for failure)
                    status = (receipt.status?.quantity == 1) ? 200 : 500
                }

                // Build receipt object
                var receiptDict: [String: Any] = [
                    "logs": logs,
                    "status": (receipt.status?.quantity == 1) ? "0x1" : "0x0",
                    "blockHash": blockHash,
                    "blockNumber": blockNumber,
                    "gasUsed": gasUsed,
                    "transactionHash": transactionHash
                ]

                // Add optional capability-specific metadata if needed
                // For now, we'll keep it simple

                let result: [String: Any] = [
                    "version": "1.0",
                    "chainId": Constants.Networks.getCurrentChainIdHex(),
                    "id": callBundleId,
                    "status": status,
                    "atomic": true, // Our EIP-7702 implementation is atomic
                    "receipts": [receiptDict]
                ]

                logger.info("wallet_getCallsStatus: Returning status \(status) for call bundle \(callBundleId)")
                return ["result": result]

            case .failure(let error):
                logger.error("Failed to get transaction receipt for \(callBundleId): \(error.localizedDescription)")

                // Return pending status if transaction not found
                return ["result": [
                    "version": "2.0.0",
                    "chainId": Constants.Networks.getCurrentChainIdHex(),
                    "id": callBundleId,
                    "status": 100, // Batch has been received but not completed onchain
                    "atomic": true
                ]]
            }
        } catch {
            logger.error("wallet_getCallsStatus failed: \(error.localizedDescription)")
            return ["error": "Failed to get calls status: \(error.localizedDescription)"]
        }
    }

    private func handleSignInWithEthereum(params: [String: Any], address: String, chainIds: [String], appMetadata: AppMetadata) throws -> [String: Any] {
        // Extract SIWE parameters with defaults from app metadata
        let nonce = params["nonce"] as? String ?? ""

        // Determine chain ID according to wallet_connect spec:
        // "chainId is optional. If not provided, the Wallet MUST fill this field with one of the
        //  chain IDs requested on the wallet_connect request (or any chain ID the account supports
        //  if no chain IDs were requested)."
        //
        // Implementation priority:
        // 1. Use explicitly provided chainId if present
        // 2. Use first chain ID from wallet_connect request if available
        // 3. Fall back to 0x1 (Ethereum mainnet)
        var chainId: String
        if let explicitChainId = params["chainId"] as? String {
            // Validate explicit chainId is supported
            guard isChainSupported(explicitChainId) else {
                logger.error("SIWE: Explicitly provided chainId is not supported: \(explicitChainId)")
                throw NSError(domain: "SIWE", code: 3, userInfo: [NSLocalizedDescriptionKey: "Explicitly provided chain ID is not supported: \(explicitChainId)"])
            }
            chainId = explicitChainId
            logger.info("SIWE: Using explicitly provided chainId: \(chainId)")
        } else if let firstSupportedChainId = chainIds.first {
            chainId = firstSupportedChainId
            logger.info("SIWE: Using first chainId from wallet_connect request: \(chainId), available chains: \(chainIds)")
        } else {
            chainId = "0x1" // Ethereum mainnet as fallback
            logger.info("SIWE: No chainIds available, falling back to Ethereum mainnet: \(chainId)")
        }

        // Validate that the chosen chain ID is supported
        guard isChainSupported(chainId) else {
            logger.error("SIWE: Unsupported chain ID selected: \(chainId)")
            throw NSError(domain: "SIWE", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported chain ID for SIWE: \(chainId)"])
        }
        // Use app metadata domain/URI as primary, fall back to params or defaults
        let domain = params["domain"] as? String ?? appMetadata.domain ?? "unknown-domain"
        let uri = params["uri"] as? String ?? appMetadata.uri ?? "https://\(domain)"
        let version = params["version"] as? String ?? "1"
        let issuedAt = params["issuedAt"] as? String ?? ISO8601DateFormatter().string(from: Date())
        let expirationTime = params["expirationTime"] as? String
        let notBefore = params["notBefore"] as? String
        let requestId = params["requestId"] as? String
        let resources = params["resources"] as? [String] ?? []
        let statement = params["statement"] as? String
        // Use app metadata scheme as primary, fall back to params
        // Generate SIWE message
        var message = "\(domain) wants you to sign in with your Ethereum account:\n\(address)\n\n"

        if let statement = statement {
            message += "\(statement)\n\n"
        }

        message += "URI: \(uri)\n"
        message += "Version: \(version)\n"
        message += "Chain ID: \(chainId)\n"
        message += "Nonce: \(nonce)\n"
        message += "Issued At: \(issuedAt)\n"

        if let expirationTime = expirationTime {
            message += "Expiration Time: \(expirationTime)\n"
        }

        if let notBefore = notBefore {
            message += "Not Before: \(notBefore)\n"
        }

        if let requestId = requestId {
            message += "Request ID: \(requestId)\n"
        }

        if !resources.isEmpty {
            message += "Resources:\n"
            for resource in resources {
                message += "- \(resource)\n"
            }
        }

        // Remove trailing newline
        let finalMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        // Sign the message using EIP-191 personal_sign
        let signature = try signSIWEMessage(finalMessage, address: address)

        return [
            "message": finalMessage,
            "signature": signature
        ]
    }

    private func signSIWEMessage(_ message: String, address: String) throws -> String {
        guard let messageData = message.data(using: .utf8) else {
            throw NSError(domain: "SIWE", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode message"])
        }

        // EIP-191 personal_sign digest: keccak256("\u{19}Ethereum Signed Message:\n" + len + message)
        let prefix = "\u{19}Ethereum Signed Message:\n\(messageData.count)"
        var prefixed = Array(prefix.utf8)
        prefixed.append(contentsOf: [UInt8](messageData))
        let digest: [UInt8] = prefixed.sha3(.keccak256)

        // Initialize account and sign digest
        let ethAddress = try Model.EthereumAddress(hex: address)
        let account = EthereumAccount(address: ethAddress)
        let signature = try account.signDigest(digest, accessGroup: Constants.accessGroup)
        let canonical = toCanonicalSignature((v: signature.v, r: signature.r, s: signature.s))
        let sigHex = "0x" + canonical.map { String(format: "%02x", $0) }.joined()

        return sigHex
    }


}

// Helpers
private let fileLogger = Logger(subsystem: "co.za.stephancill.stupid-wallet", category: "SafariWebExtensionHandler")
// Minimal EIP-712 encoder for v4 (typedData JSON)
enum EIP712 {
    struct TypeDef { let name: String; let type: String }

    static func computeDigest(typedDataJSON: String) throws -> Data? {
        guard let jsonData = typedDataJSON.data(using: .utf8) else { return nil }
        let obj = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
        guard let dict = obj,
              let types = dict["types"] as? [String: Any],
              let primaryType = dict["primaryType"] as? String,
              let domain = dict["domain"],
              let message = dict["message"]
        else { return nil }

        var typeMap: [String: [TypeDef]] = [:]
        for (k, v) in types {
            guard let arr = v as? [[String: Any]] else { continue }
            typeMap[k] = arr.compactMap { item in
                guard let n = item["name"] as? String, let t = item["type"] as? String else { return nil }
                return TypeDef(name: n, type: t)
            }
        }

        let domainHash = try hashStruct(typeName: "EIP712Domain", value: domain, types: typeMap)
        let messageHash = try hashStruct(typeName: primaryType, value: message, types: typeMap)

        var prefix: [UInt8] = [0x19, 0x01]
        prefix.append(contentsOf: [UInt8](domainHash))
        prefix.append(contentsOf: [UInt8](messageHash))
        let digest = prefix.sha3(.keccak256)
        return Data(digest)
    }

    private static func encodeType(_ primaryType: String, types: [String: [TypeDef]]) -> String {
        func collectDependencies(of type: String, into set: inout Set<String>) {
            guard let fields = types[type] else { return }
            for f in fields {
                let base = baseType(of: f.type)
                if types[base] != nil && base != type {
                    if !set.contains(base) {
                        set.insert(base)
                        collectDependencies(of: base, into: &set)
                    }
                }
            }
        }
        var deps: Set<String> = []
        collectDependencies(of: primaryType, into: &deps)
        let ordered = [primaryType] + Array(deps).sorted()
        return ordered.compactMap { typeName in
            guard let fields = types[typeName] else { return nil }
            let inner = fields.map { "\($0.type) \($0.name)" }.joined(separator: ",")
            return "\(typeName)(\(inner))"
        }.joined()
    }

    private static func typeHash(_ type: String, types: [String: [TypeDef]]) -> Data {
        let enc = encodeType(type, types: types)
        return Data([UInt8](enc.utf8)).sha3(.keccak256)
    }

    private static func hashStruct(typeName: String, value: Any, types: [String: [TypeDef]]) throws -> Data {
        let tHash = typeHash(typeName, types: types)
        let fields: [TypeDef]
        if let f = types[typeName] {
            fields = f
        } else if typeName == "EIP712Domain" {
            fields = [
                TypeDef(name: "name", type: "string"),
                TypeDef(name: "version", type: "string"),
                TypeDef(name: "chainId", type: "uint256"),
                TypeDef(name: "verifyingContract", type: "address"),
                TypeDef(name: "salt", type: "bytes32"),
            ]
        } else {
            return Data([UInt8](tHash))
        }
        var enc: [UInt8] = []
        enc.append(contentsOf: [UInt8](tHash))
        let valDict = value as? [String: Any] ?? [:]
        for field in fields {
            let v = valDict[field.name]
            let hashed = try encodeValue(fieldType: field.type, value: v, types: types)
            enc.append(contentsOf: [UInt8](hashed))
        }
        return Data(enc).sha3(.keccak256)
    }

    private static func encodeValue(fieldType: String, value: Any?, types: [String: [TypeDef]]) throws -> Data {
        if let (base, isArray) = parseArray(fieldType), isArray {
            let arr = value as? [Any] ?? []
            var out: [UInt8] = []
            for el in arr {
                let h = try encodeValue(fieldType: base, value: el, types: types)
                out.append(contentsOf: [UInt8](h))
            }
            return Data(out).sha3(.keccak256)
        }
        let base = baseType(of: fieldType)
        if let _ = types[base] {
            return try hashStruct(typeName: base, value: value ?? [:], types: types)
        }
        switch base.lowercased() {
        case "address":
            if let s = value as? String, let addr = try? EthereumAddress(hex: s, eip55: false) {
                return Data(addr.rawAddress).leftPadded(to: 32)
            }
            return Data(count: 32)
        case let t where t.hasPrefix("uint"):
            if let b = try? parseBigUInt(value) { return b.serialize().leftPadded(to: 32) }
            return Data(count: 32)
        case let t where t.hasPrefix("int"):
            if let b = try? parseBigInt(value) { return twosComplement32Bytes(b) }
            return Data(count: 32)
        case "bool":
            let v = (value as? Bool) == true ? 1 : 0
            var data = Data(count: 31)
            data.append(UInt8(v))
            return data
        case "bytes":
            if let s = value as? String, let d = Data(hexString: s) { return d.sha3(.keccak256) }
            if let d = value as? Data { return d.sha3(.keccak256) }
            return Data(count: 32)
        case let t where t.hasPrefix("bytes"):
            let lenStr = String(t.dropFirst("bytes".count))
            if let len = Int(lenStr), len >= 1 && len <= 32 {
                if let s = value as? String, let d = Data(hexString: s) { return d.rightPadded(to: 32) }
                if let d = value as? Data { return d.rightPadded(to: 32) }
            }
            return Data(count: 32)
        case "string":
            if let s = value as? String { return Data(s.utf8).sha3(.keccak256) }
            return Data(count: 32)
        default:
            return Data(count: 32)
        }
    }

    private static func parseArray(_ type: String) -> (String, Bool)? {
        if let range = type.range(of: "[") { return (String(type[..<range.lowerBound]), true) }
        return (type, false)
    }

    private static func baseType(of type: String) -> String {
        return String(type.split(separator: "[").first ?? Substring(type))
    }

    private static func parseBigUInt(_ value: Any?) throws -> BigUInt {
        if let n = value as? BigUInt { return n }
        if let i = value as? Int { return BigUInt(i) }
        if let s = value as? String {
            if s.hasPrefix("0x"), let n = BigUInt(s.dropFirst(2), radix: 16) { return n }
            if let n = BigUInt(s, radix: 10) { return n }
        }
        return BigUInt.zero
    }

    private static func parseBigInt(_ value: Any?) throws -> BigInt {
        if let n = value as? BigInt { return n }
        if let i = value as? Int { return BigInt(i) }
        if let s = value as? String {
            if s.hasPrefix("0x"), let n = BigInt(s.dropFirst(2), radix: 16) { return n }
            if let n = BigInt(s, radix: 10) { return n }
        }
        return BigInt.zero
    }

    private static func twosComplement32Bytes(_ value: BigInt) -> Data {
        let two256 = BigInt(1) << 256
        var normalized = value % two256
        if normalized < 0 { normalized += two256 }
        let mag = BigUInt(normalized)
        return mag.serialize().leftPadded(to: 32)
    }
}

private func computeTransactionMessageToSign(tx: EthereumTransaction, chainId: EthereumQuantity) throws -> Bytes {
    // Replicate Web3.swift's messageToSign logic via RLP
    let encoder = RLPEncoder()
    func encQuantity(_ q: EthereumQuantity) -> RLPItem { RLPItem.bigUInt(q.quantity) }
    func encData(_ d: EthereumData) -> RLPItem { RLPItem.bytes(d.bytes) }
    switch tx.transactionType {
    case .legacy:
        guard let nonce = tx.nonce, let gasPrice = tx.gasPrice, let gasLimit = tx.gasLimit, let value = tx.value else {
            throw EthereumSignedTransaction.Error.transactionInvalid
        }
        let list: [RLPItem] = [
            encQuantity(nonce),
            encQuantity(gasPrice),
            encQuantity(gasLimit),
            (tx.to != nil ? RLPItem.bytes(tx.to!.rawAddress) : RLPItem.bytes([])),
            encQuantity(value),
            encData(tx.data),
            encQuantity(chainId),
            RLPItem.bigUInt(BigUInt(0)),
            RLPItem.bigUInt(BigUInt(0)),
        ]
        return try encoder.encode(RLPItem.array(list))
    case .eip1559:
        guard let nonce = tx.nonce,
              let maxFeePerGas = tx.maxFeePerGas,
              let maxPriorityFeePerGas = tx.maxPriorityFeePerGas,
              let gasLimit = tx.gasLimit,
              let value = tx.value else {
            throw EthereumSignedTransaction.Error.transactionInvalid
        }
        // Build accessList encoding: [[address, [storageKeys...]], ...]
        var accessListItems: [RLPItem] = []
        for (address, storageKeys) in tx.accessList {
            let addrItem = RLPItem.bytes(address.rawAddress)
            let keysItems = storageKeys.map { RLPItem.bytes($0.bytes) }
            accessListItems.append(RLPItem.array([addrItem, RLPItem.array(keysItems)]))
        }
        let list: [RLPItem] = [
            encQuantity(chainId),
            encQuantity(nonce),
            encQuantity(maxPriorityFeePerGas),
            encQuantity(maxFeePerGas),
            encQuantity(gasLimit),
            (tx.to != nil ? RLPItem.bytes(tx.to!.rawAddress) : RLPItem.bytes([])),
            encQuantity(value),
            encData(tx.data),
            RLPItem.array(accessListItems)
        ]
        var raw = try encoder.encode(RLPItem.array(list))
        raw.insert(0x02, at: 0)
        return raw
    }
}

private extension Data {
    func leftPadded(to length: Int) -> Data { if count >= length { return self }; return Data(repeating: 0, count: length - count) + self }
    func rightPadded(to length: Int) -> Data { if count >= length { return self }; return self + Data(repeating: 0, count: length - count) }
}

private extension BigUInt {
    static func fromHexQuantity(_ hex: String) -> BigUInt? {
        guard !hex.isEmpty else { return nil }
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return BigUInt(s, radix: 16)
    }
}

private func awaitPromise<T>(_ promise: Promise<T>) -> Swift.Result<T, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Swift.Result<T, Error>!
    promise.done { value in
        result = .success(value)
        semaphore.signal()
    }.catch { error in
        result = .failure(error)
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 30)
    return result
}
    private func signEIP7702Authorization(contractAddress: String, chainId: BigUInt, fromAddress: String) throws -> SafariWebExtensionHandler.EIP7702Authorization {
        // Get nonce for authorization
        let (rpcURL, _) = Constants.Networks.currentNetwork()
        let web3 = Web3(rpcURL: rpcURL)
        let fromAddr = try EthereumAddress(hex: fromAddress, eip55: false)

        var nonce: BigUInt
        switch awaitPromise(web3.eth.getTransactionCount(address: fromAddr, block: .pending)) {
        case .success(let n):
            // EIP-7702: sender nonce is incremented before processing authorizations.
            // For self-executed EIP-7702 (authority == sender), authorization.nonce MUST equal sender's incremented nonce.
            nonce = n.quantity.magnitude + 1
        case .failure:
            throw NSError(domain: "EIP7702", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get nonce"])
        }

        // Create authorization hash: keccak256('0x05' || rlp([chain_id, address, nonce]))
        let addr = try EthereumAddress(hex: contractAddress, eip55: false)
        let addressData = Data(addr.rawAddress) // 20-byte address, no padding per spec

        // RLP encode [chain_id, address, nonce]
        let encoder = RLPEncoder()
        let rlpData = try encoder.encode(RLPItem.array([
            RLPItem.bigUInt(chainId),              // chain_id
            RLPItem.bytes([UInt8](addressData)),  // 20-byte address
            RLPItem.bigUInt(nonce)                // nonce
        ]))

        // Add 0x05 prefix
        var authData = Data([0x05])
        authData.append(contentsOf: rlpData)

        // Hash it
        let authHash = authData.sha3(.keccak256)

        // Sign the hash (EIP-2 low-s normalized by underlying signer)
        let ethAddress = try Model.EthereumAddress(hex: fromAddress)
        let account = EthereumAccount(address: ethAddress)
        let signature = try account.signDigest([UInt8](authHash), accessGroup: Constants.accessGroup)
        _ = toCanonicalSignature((v: signature.v, r: signature.r, s: signature.s))

        // Create authorization object
        return SafariWebExtensionHandler.EIP7702Authorization(
            chainId: chainId,
            address: contractAddress,
            nonce: nonce,
            r: Data(signature.r),
            s: Data(signature.s),
            v: UInt8(signature.v == 27 ? 0 : 1)
        )
    }

    private func serializeEIP7702Transaction(
        nonce: EthereumQuantity,
        maxPriorityFeePerGas: EthereumQuantity,
        maxFeePerGas: EthereumQuantity,
        gasLimit: EthereumQuantity,
        to: String?,
        value: EthereumQuantity,
        data: Data,
        accessList: [(String, [Data])],
        authorizations: [SafariWebExtensionHandler.EIP7702Authorization],
        chainId: BigUInt,
        fromAddress: String
    ) throws -> Data {
        let encoder = RLPEncoder()

        // Encode authorization list (order: chain_id, address, nonce, y_parity, r, s)
        var authListItems: [RLPItem] = []
        for auth in authorizations {
            let addrData = Data(hexString: auth.address.hasPrefix("0x") ? String(auth.address.dropFirst(2)) : auth.address) ?? Data()
            let authItem = RLPItem.array([
                RLPItem.bigUInt(auth.chainId),                    // chain_id
                RLPItem.bytes([UInt8](addrData)),                // address (20 bytes)
                RLPItem.bigUInt(auth.nonce),                      // nonce (uint64)
                RLPItem.bigUInt(try BigUInt(auth.v)),                 // y_parity (uint8)
                RLPItem.bigUInt(BigUInt([UInt8](auth.r))),        // r (bytes32 as integer)
                RLPItem.bigUInt(BigUInt([UInt8](auth.s)))         // s (bytes32 as integer)
            ])
            authListItems.append(authItem)
        }
        let authorizationList = RLPItem.array(authListItems)

        // Encode access list
        var accessListItems: [RLPItem] = []
        for (address, storageKeys) in accessList {
            let addrData = Data(hexString: address.hasPrefix("0x") ? String(address.dropFirst(2)) : address) ?? Data()
            let keysItems = storageKeys.map { RLPItem.bytes([UInt8]($0)) }
            let entryItem = RLPItem.array([
                RLPItem.bytes([UInt8](addrData)),
                RLPItem.array(keysItems)
            ])
            accessListItems.append(entryItem)
        }
        let accessListRLP = RLPItem.array(accessListItems)

        // Build the transaction payload WITHOUT signature for signing
        let txPayloadArray: [RLPItem] = [
            RLPItem.bigUInt(chainId),                           // chain_id
            RLPItem.bigUInt(nonce.quantity),                    // nonce
            RLPItem.bigUInt(maxPriorityFeePerGas.quantity),    // max_priority_fee_per_gas
            RLPItem.bigUInt(maxFeePerGas.quantity),            // max_fee_per_gas
            RLPItem.bigUInt(gasLimit.quantity),                // gas_limit
            (to != nil ? RLPItem.bytes([UInt8](Data(hexString: to!.hasPrefix("0x") ? String(to!.dropFirst(2)) : to!) ?? Data())) : RLPItem.bytes([])), // to
            RLPItem.bigUInt(value.quantity),                    // value
            RLPItem.bytes([UInt8](data)),                      // data
            accessListRLP,                                      // access_list
            authorizationList                                   // authorization_list
        ]

        // Encode the transaction payload for signing
        let encodedPayload = try encoder.encode(RLPItem.array(txPayloadArray))

        // EIP-7702 signing: keccak256(SET_CODE_TX_TYPE || TransactionPayload)
        var signingData = Data([0x04]) // SET_CODE_TX_TYPE
        signingData.append(contentsOf: encodedPayload)
        let digest = signingData.sha3(.keccak256)
        fileLogger.info("EIP-7702 signing digest: \(digest.hex())")

        // Sign the digest
        let ethAddress = try Model.EthereumAddress(hex: fromAddress)
        let account = EthereumAccount(address: ethAddress)
        let signature = try account.signDigest([UInt8](digest), accessGroup: Constants.accessGroup)

        // Normalize signature components for EIP-7702
        let yParity = signature.v == 27 ? BigUInt(0) : BigUInt(1)
        let r = BigUInt(signature.r)
        let s = BigUInt(signature.s)
        fileLogger.info("EIP-7702 signature - yParity: \(yParity), r: \(r.serialize().hex()), s: \(s.serialize().hex())")

        // Build the final transaction array WITH signature
        let txArrayWithSig: [RLPItem] = [
            RLPItem.bigUInt(chainId),                           // chain_id
            RLPItem.bigUInt(nonce.quantity),                    // nonce
            RLPItem.bigUInt(maxPriorityFeePerGas.quantity),    // max_priority_fee_per_gas
            RLPItem.bigUInt(maxFeePerGas.quantity),            // max_fee_per_gas
            RLPItem.bigUInt(gasLimit.quantity),                // gas_limit
            (to != nil ? RLPItem.bytes([UInt8](Data(hexString: to!.hasPrefix("0x") ? String(to!.dropFirst(2)) : to!) ?? Data())) : RLPItem.bytes([])), // to
            RLPItem.bigUInt(value.quantity),                    // value
            RLPItem.bytes([UInt8](data)),                      // data
            accessListRLP,                                      // access_list
            authorizationList,                                  // authorization_list
            RLPItem.bigUInt(yParity),                            // signature_y_parity (uint8)
            RLPItem.bigUInt(r),                                  // signature_r (bytes32 as integer)
            RLPItem.bigUInt(s)                                   // signature_s (bytes32 as integer)
        ]

        // Encode the transaction with signature
        let encodedTx = try encoder.encode(RLPItem.array(txArrayWithSig))

        // Add transaction type prefix (0x04 for EIP-7702)
        var finalTx = Data([0x04])
        finalTx.append(contentsOf: encodedTx)

        return finalTx
    }

    private func createExecuteBatchTransaction(calls: [[String: Any]], authorizations: [SafariWebExtensionHandler.EIP7702Authorization], fromAddress: String, chainIdBig: BigUInt, version: Int) throws -> [String: Any] {
        let (rpcURL, currentChainId) = Constants.Networks.currentNetwork()
        fileLogger.info("EIP-7702 using RPC: \(rpcURL, privacy: .public) chainId: \(currentChainId, privacy: .public)")
        let web3 = Web3(rpcURL: rpcURL)

        // Create fromAddr from the fromAddress parameter
        let fromAddr = try EthereumAddress(hex: fromAddress, eip55: false)


        // Manually ABI-encode executeBatch((address,uint256,bytes)[] calls)
        // selector (0x34fcd5be) + head (0x20) + array region (length, offsets, tuples, bytes)
        var data = Data()
        data.append(contentsOf: Data(hexString: "0x34fcd5be")!)

        // Head: single dynamic argument at offset 0x20
        data.append(contentsOf: BigUInt(32).serialize().leftPadded(to: 32))

        // Build array region
        var arrayRegion = Data()
        let callsLength = calls.count
        arrayRegion.append(contentsOf: BigUInt(callsLength).serialize().leftPadded(to: 32))

        // Precompute tuple encodings to compute offsets and accumulate total value
        struct EncodedCall { let tupleHead: Data; let dynamicBytes: Data }
        var encodedCalls: [EncodedCall] = []
        encodedCalls.reserveCapacity(callsLength)

        for call in calls {
            let targetHex = call["target"] as! String
            let valueHex = call["value"] as? String ?? "0x0"
            let dataHex = call["data"] as? String ?? "0x"

            let target = try EthereumAddress(hex: targetHex, eip55: false)
            let value = BigUInt.fromHexQuantity(valueHex) ?? BigUInt.zero
            let callBytes = Data(hexString: dataHex) ?? Data()

            // dynamic bytes payload: length + data + padding
            var dyn = Data()
            dyn.append(contentsOf: BigUInt(callBytes.count).serialize().leftPadded(to: 32))
            dyn.append(callBytes)
            let rem = dyn.count % 32
            if rem != 0 { dyn.append(Data(repeating: 0, count: 32 - rem)) }

            // tuple head: address, value, bytes_offset (0x60)
            var head = Data()
            head.append(Data(target.rawAddress).leftPadded(to: 32))
            head.append(value.serialize().leftPadded(to: 32))
            head.append(BigUInt(0x60).serialize().leftPadded(to: 32))

            encodedCalls.append(EncodedCall(tupleHead: head, dynamicBytes: dyn))
        }

        // Offsets to each tuple within array region (relative to start of array payload AFTER length)
        let firstTupleOffset = BigUInt(32 * callsLength)
        var running = firstTupleOffset
        for enc in encodedCalls {
            arrayRegion.append(contentsOf: running.serialize().leftPadded(to: 32))
            let tupleSize = enc.tupleHead.count + enc.dynamicBytes.count
            running += BigUInt(tupleSize)
        }

        // Append all tuples (head + dynamic bytes)
        for enc in encodedCalls {
            arrayRegion.append(enc.tupleHead)
            arrayRegion.append(enc.dynamicBytes)
        }

        // Final calldata = selector + head + arrayRegion
        data.append(arrayRegion)

        let toAddr = fromAddr // EIP-7702: Send transaction to user's wallet, which gets temporarily delegated to Simple7702Account

        // Get nonce
        let nonce: EthereumQuantity
        switch awaitPromise(web3.eth.getTransactionCount(address: fromAddr, block: .pending)) {
        case .success(let n):
            nonce = n
        case .failure:
            throw NSError(domain: "Transaction", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get nonce"])
        }

        // Get EIP-1559 fee data
        let maxFeePerGas: EthereumQuantity
        let maxPriorityFeePerGas: EthereumQuantity

        // Get gas price (simplified - using legacy gas price for now)
        switch awaitPromise(web3.eth.gasPrice()) {
        case .success(let gp):
            // Use EIP-1559 style fees if available; otherwise default to legacy gasPrice
            maxFeePerGas = gp
            maxPriorityFeePerGas = gp
            fileLogger.info("EIP-7702 gas price (wei): \(gp.quantity, privacy: .public)")
        case .failure(let err):
            fileLogger.error("EIP-7702 failed to get gas price: \(err.localizedDescription, privacy: .public)")
            throw NSError(domain: "Transaction", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to get gas price"])
        }

        // Create transaction data
        let txData = try EthereumData(data)
        fileLogger.info("EIP-7702 tx data: \(txData.hex(), privacy: .public)")

        // Estimate gas (use default if estimation fails, for debugging)
        var gasLimit: EthereumQuantity
        let estimate = awaitPromise(web3.eth.estimateGas(call: EthereumCall(from: fromAddr, to: toAddr, gas: nil, gasPrice: nil, value: EthereumQuantity(quantity: BigUInt.zero), data: txData)))
        switch estimate {
        case .success(let est):
            gasLimit = est
            fileLogger.info("EIP-7702 gas estimate: \(est.quantity, privacy: .public)")
        case .failure(let err):
            fileLogger.error("EIP-7702 gas estimate failed: \(err.localizedDescription, privacy: .public)")
            throw NSError(domain: "Transaction", code: 4, userInfo: [NSLocalizedDescriptionKey: "Gas estimation failed: \(err.localizedDescription)"])
        }

        // Add intrinsic overhead for EIP-7702 (base tx cost + per-authorization cost)
        if !authorizations.isEmpty {
            let authOverhead = BigUInt(25_000 * authorizations.count)
            let baseOverhead = BigUInt(21_000)
            let safetyMargin = BigUInt(50_000)
            let newLimit = gasLimit.quantity + authOverhead + baseOverhead + safetyMargin
            fileLogger.info("EIP-7702 adjusted gas limit with overhead: \(newLimit, privacy: .public) (was \(gasLimit.quantity, privacy: .public))")
            gasLimit = EthereumQuantity(quantity: newLimit)
        }

        // Check if we need EIP-7702 transaction format
        if !authorizations.isEmpty {
            // Create and submit EIP-7702 transaction with authorization list
            let rawTx = try serializeEIP7702Transaction(
                nonce: nonce,
                maxPriorityFeePerGas: maxPriorityFeePerGas,
                maxFeePerGas: maxFeePerGas,
                gasLimit: gasLimit,
                to: toAddr.hex(eip55: true),
                value: EthereumQuantity(quantity: BigUInt.zero),
                data: Data(txData.bytes),
                accessList: [],
                authorizations: authorizations,
                chainId: chainIdBig,
                fromAddress: fromAddress
            )

            // Submit the EIP-7702 transaction
            let rawTxHex = "0x" + rawTx.hex()
            fileLogger.info("EIP-7702 raw transaction hex: \(rawTxHex, privacy: .public)")
            fileLogger.info("EIP-7702 transaction length: \(rawTx.count, privacy: .public) bytes")
            fileLogger.info("EIP-7702 first byte (type): 0x\(String(format: "%02x", rawTx.first ?? 0), privacy: .public)")
            // logger.info("Submitting EIP-7702 transaction with \(authorizations.count) authorizations")

            // Try to submit the EIP-7702 transaction
            if let url = URL(string: rpcURL) {
                switch awaitPromise(submitEIP7702Transaction(rpcURL: url, rawTxHex: rawTxHex)) {
                case .success(let txHash):
                    fileLogger.info("EIP-7702 transaction submitted successfully: \(txHash)")
                    // logger.info("EIP-7702 transaction submitted successfully: \(txHash)")
                    if version == 2 {
                        return ["result": ["id": txHash]]
                    } else {
                        return ["result": txHash]
                    }
                case .failure(let eip7702Error):
                    fileLogger.error("EIP-7702 transaction failed: \(eip7702Error.localizedDescription)")
                    if let nsError = eip7702Error as? NSError {
                        fileLogger.error("EIP-7702 error domain: \(nsError.domain), code: \(nsError.code)")
                    } else {
                        fileLogger.warning("EIP-7702 error is not an NSError")
                    }
                    throw eip7702Error
                }
            } else {
                fileLogger.warning("Invalid RPC URL")
                throw NSError(domain: "EIP7702", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid RPC URL"])
            }
        }

        // Create legacy transaction (fallback or when no authorizations needed)
        let tx = EthereumTransaction(
            nonce: nonce,
            gasPrice: maxFeePerGas,
            gasLimit: gasLimit,
            to: toAddr,
            value: EthereumQuantity(quantity: BigUInt.zero),
            data: txData
        )

        // Sign transaction
        let msg = try computeTransactionMessageToSign(tx: tx, chainId: EthereumQuantity(quantity: chainIdBig))
        let digest = Data(msg).sha3(.keccak256)
        let account = EthereumAccount(address: try Model.EthereumAddress(hex: fromAddress))
        let sig = try account.signDigest([UInt8](digest), accessGroup: Constants.accessGroup)

        let recId: BigUInt = {
            if sig.v == 27 || sig.v == 28 { return BigUInt(sig.v - 27) }
            return BigUInt(sig.v)
        }()

        let vFinal: EthereumQuantity = {
            if chainIdBig == 0 { return EthereumQuantity(quantity: recId + 27) }
            return EthereumQuantity(quantity: recId + 35 + (chainIdBig * 2))
        }()

        let signedTx = EthereumSignedTransaction(
            nonce: tx.nonce!,
            gasPrice: tx.gasPrice!,
            gasLimit: tx.gasLimit!,
            to: tx.to,
            value: tx.value ?? EthereumQuantity(quantity: 0),
            data: tx.data,
            v: vFinal,
            r: EthereumQuantity(quantity: BigUInt(sig.r)),
            s: EthereumQuantity(quantity: BigUInt(sig.s)),
            chainId: EthereumQuantity(quantity: chainIdBig),
            accessList: tx.accessList,
            transactionType: .legacy
        )

        // Log authorization information if present
        if !authorizations.isEmpty {
            // logger.info("Transaction would benefit from EIP-7702 with \(authorizations.count) authorizations")
            for auth in authorizations {
                // logger.info("Authorization for \(auth.address) on chain \(auth.chainId)")
                fileLogger.info("Authorization for \(auth.address, privacy: .public) on chain \(auth.chainId, privacy: .public)")
            }
        }

        // Send transaction
        fileLogger.info("Sending legacy transaction (fallback)")
        switch awaitPromise(web3.eth.sendRawTransaction(transaction: signedTx)) {
        case .success(let txHash):
            if version == 2 {
                return ["result": ["id": txHash.hex()]]
            } else {
                return ["result": txHash.hex()]
            }
        case .failure(let e):
            throw NSError(domain: "Transaction", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to send transaction: \(e.localizedDescription)"])
        }
    }

    private func submitEIP7702Transaction(rpcURL: URL, rawTxHex: String) -> Promise<String> {
        return Promise<String> { seal in
            var request = URLRequest(url: rpcURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let requestBody: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "eth_sendRawTransaction",
                "params": [rawTxHex]
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])

                let task = URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error = error {
                        seal.reject(error)
                        return
                    }

                    guard let data = data else {
                        seal.reject(NSError(domain: "EIP7702", code: 1, userInfo: [NSLocalizedDescriptionKey: "No data received"]))
                        return
                    }

                    do {
                        let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
                        fileLogger.info("EIP-7702 RPC response: \(responseString, privacy: .public)")

                        if let jsonResponse = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                           let result = jsonResponse["result"] as? String {
                            seal.fulfill(result)
                        } else if let errorResponse = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                                  let error = errorResponse["error"] as? [String: Any],
                                  let message = error["message"] as? String {
                            fileLogger.error("EIP-7702 RPC error: \(message, privacy: .public)")
                            seal.reject(NSError(domain: "EIP7702", code: 2, userInfo: [NSLocalizedDescriptionKey: message]))
                        } else {
                            fileLogger.warning("EIP-7702 invalid RPC response format")
                            seal.reject(NSError(domain: "EIP7702", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid RPC response"]))
                        }
                    } catch {
                        fileLogger.error("EIP-7702 JSON parsing error: \(error.localizedDescription, privacy: .public)")
                        seal.reject(error)
                    }
                }
                task.resume()
            } catch {
                seal.reject(error)
            }
        }
    }

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

    func hex() -> String {
        return self.map { String(format: "%02x", $0) }.joined()
    }


}
