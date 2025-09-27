//
//  SafariWebExtensionHandler.swift
//  testapp Extension
//
//  Created by Stephan on 2025/08/19.
//

import SafariServices
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

    // EIP-7702 constants
    private let simple7702AccountAddress = "0xe6Cae83BdE06E4c305530e199D7217f42808555B"



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

        let response = NSExtensionItem()

        Task {
            let responseMessage = await handleWalletRequest(message, appMetadata: appMetadata)

            if #available(iOS 15.0, macOS 11.0, *) {
                response.userInfo = [ SFExtensionMessageKey: responseMessage ]
            } else {
                response.userInfo = [ "message": responseMessage ]
            }

            context.completeRequest(returningItems: [ response ], completionHandler: nil)
        }
    }

    private func extractAppMetadata(from request: NSExtensionItem?, message: Any?) -> AppMetadata {
        // First try to get site metadata from the message (passed from background script)
        if let messageDict = message as? [String: Any],
           let siteMetadata = messageDict["siteMetadata"] as? [String: Any] {
            if let domain = siteMetadata["domain"] as? String,
               let url = siteMetadata["url"] as? String,
               let scheme = siteMetadata["scheme"] as? String {
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
        return AppMetadata(domain: nil, uri: nil, scheme: nil)
    }

    private func handleWalletRequest(_ message: Any?, appMetadata: AppMetadata) async -> [String: Any] {
        guard let messageDict = message as? [String: Any],
              let method = messageDict["method"] as? String else {
            return ["error": "Invalid message format"]
        }

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
        case "eth_getTransactionByHash":
            let params = messageDict["params"] as? [Any]
            return handleGetTransactionByHash(params: params)
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
            return await handleWalletSendCalls(params: params)
        case "wallet_getCapabilities":
            let params = messageDict["params"] as? [Any]
            return handleWalletGetCapabilities(params: params)
        case "wallet_getCallsStatus":
            let params = messageDict["params"] as? [Any]
            return handleWalletGetCallsStatus(params: params)
        default:
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

    private func handleGetTransactionByHash(params: [Any]?) -> [String: Any] {
        guard let params = params, params.count >= 1 else {
            return ["error": "Invalid eth_getTransactionByHash params"]
        }
        guard let txHashHex = params[0] as? String else {
            return ["error": "Invalid transaction hash"]
        }
        
        let (rpcURL, _) = Constants.Networks.currentNetwork()
        let web3 = Web3(rpcURL: rpcURL)
        
        // Convert hex string to EthereumData
        guard let txHashData = Data(hexString: txHashHex) else {
            return ["error": "Invalid transaction hash format"]
        }
        
        let txHash = EthereumData([UInt8](txHashData))
        
        switch awaitPromise(web3.eth.getTransactionByHash(blockHash: txHash)) {
        case .success(let transaction):
            // Return the raw RPC response directly
            if let tx = transaction {
                return ["result": tx]
            } else {
                return ["result": nil]
            }
        case .failure(let error):
            return ["error": "Failed to get transaction: \(error.localizedDescription)"]
        }
    }

    private func handleRequestAccounts() -> [String: Any] {
        let address = getSavedAddress()
        if let address = address {
            return ["result": [address]]
        } else {
            return ["result": []]
        }
    }

    private func handleWalletConnect(params: [Any]?, appMetadata: AppMetadata) -> [String: Any] {
        let address = getSavedAddress()
        guard let address = address else {
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
                    return ["error": "SIWE signing failed"]
                }
            }
        }

        account["capabilities"] = capabilities

        return ["result": [
            "accounts": [account],
            "chainIds": supportedChainIds
        ]]
    }

    private func handleWalletDisconnect() -> [String: Any] {
        // According to spec: revoke access to user account info and capabilities
        // In this implementation, we don't maintain persistent sessions beyond stored address
        // So we just return success - the app can clear its local state
        return ["result": true]
    }

    private func handleAccounts() -> [String: Any] {
        let address = getSavedAddress()
        if let address = address {
            return ["result": [address]]
        } else {
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

            var canonical = Data()
            canonical.append(r32)
            canonical.append(s32)
            canonical.append(vCanonical)
            let sigHex = "0x" + canonical.map { String(format: "%02x", $0) }.joined()
            return ["result": sigHex]
        } catch {
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

            var canonical = Data()
            canonical.append(r32)
            canonical.append(s32)
            canonical.append(vCanonical)
            let sigHex = "0x" + canonical.map { String(format: "%02x", $0) }.joined()
            return ["result": sigHex]
        } catch {
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

        let transactionData: EthereumData? = {
            guard dataHex != "0x" else { return nil }
            guard let rawData = Data(hexString: dataHex) else {
                return nil
            }
            return try? EthereumData(rawData)
        }()
        if dataHex != "0x" && transactionData == nil {
            return ["error": "Invalid transaction data"]
        }

        do {
            let (rpcURL, chainIdBig) = Constants.Networks.currentNetwork()
            let web3 = Web3(rpcURL: rpcURL)

            let fromAddr = try EthereumAddress(hex: fromHex, eip55: false)
            let toAddr = (toHex != nil && !(toHex!).isEmpty) ? (try? EthereumAddress(hex: toHex!, eip55: false)) : nil

            // Check balance before proceeding with transaction
            let networkName = Constants.Networks.chainName(forChainId: chainIdBig)

            let currentBalance: BigUInt
            switch awaitPromise(web3.eth.getBalance(address: fromAddr, block: .latest)) {
            case .success(let balance):
                currentBalance = balance.quantity
                if currentBalance == 0 {
                    return ["error": "Insufficient balance on \(networkName). Your account has 0 ETH. Please ensure you have funds on this network before sending transactions."]
                }
            case .failure(let error):
                return ["error": "Failed to check account balance: \(error.localizedDescription)"]
            }

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
        let gasLimitQty: BigUInt
        if let gasHex = gasHex, let g = BigUInt.fromHexQuantity(gasHex) {
            gasLimitQty = g
        } else {
            guard let toForEstimate = toAddr else {
                return ["error": "Missing 'to' address"]
            }
            let call = EthereumCall(
                from: fromAddr,
                to: toForEstimate,
                gas: nil,
                gasPrice: nil,
                value: EthereumQuantity(quantity: weiValue),
                data: transactionData
            )

            switch awaitPromise(web3.eth.estimateGas(call: call)) {
            case .success(let estimate):
                let base = estimate.quantity
                let buffer = max(base / BigUInt(5), BigUInt(1_500))
                let padded = base + buffer
                gasLimitQty = max(padded, BigUInt(21_000))
            case .failure(let error):
                return ["error": "Failed to estimate gas: \(error.localizedDescription)"]
            }
        }

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

            // Check if balance is sufficient for estimated transaction cost
            let estimatedGasCost: BigUInt
            let totalValue = weiValue  // Value being sent in the transaction
            if let maxFee = BigUInt.fromHexQuantity(maxFeePerGasHex ?? ""), let maxPrio = BigUInt.fromHexQuantity(maxPriorityFeePerGasHex ?? "") {
                // EIP-1559: use maxFeePerGas
                estimatedGasCost = gasLimitQty * maxFee
            } else {
                // Legacy: use gasPrice
                let gasPrice = txToSign.gasPrice?.quantity ?? BigUInt.zero
                estimatedGasCost = gasLimitQty * gasPrice
            }

            let totalCost = estimatedGasCost + totalValue

            if currentBalance < totalCost {
                let shortfall = totalCost - currentBalance
                let divisor = BigUInt(1_000_000_000_000_000_000)
                let formatWei = { (wei: BigUInt) -> String in
                    let integer = wei / divisor
                    let remainder = wei % divisor
                    let remainderStr = String(remainder).leftPadded(to: 18)
                    let decimals = String(remainderStr.prefix(6))
                    return "\(integer).\(decimals) ETH"
                }
                return ["error": "Insufficient balance on \(networkName). Required: \(formatWei(totalCost)), Available: \(formatWei(currentBalance)), Shortfall: \(formatWei(shortfall))"]
            }

            // Data
            if let calldata = transactionData {
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
                txToSign.data = calldata
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
                return ["error": "Failed to sign transaction: \(error.localizedDescription)"]
            }

            // Send
            switch awaitPromise(web3.eth.sendRawTransaction(transaction: signedTx)) {
            case .success(let txHash):
                return ["result": txHash.hex()]
            case .failure(let e):
                return ["error": "Failed to send transaction: \(e.localizedDescription)"]
            }
        } catch {
            return ["error": "eth_sendTransaction failed"]
        }
    }

    private func getSavedAddress() -> String? {
        let defaults = UserDefaults(suiteName: appGroupId)
        if defaults == nil {
            return nil
        }
        let address = defaults?.string(forKey: "walletAddress")
        if let address = address, !address.isEmpty {
            return address
        } else {
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

    private func handleWalletSendCalls(params: [Any]?) async -> [String: Any] {
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

            // Check balance before proceeding with expensive operations
            let networkName = Constants.Networks.chainName(forChainId: chainIdBig)

            let currentBalance: BigUInt
            switch awaitPromise(web3.eth.getBalance(address: fromAddr, block: .latest)) {
            case .success(let balance):
                currentBalance = balance.quantity
                if currentBalance == 0 {
                    return ["error": "Insufficient balance on \(networkName). Your account has 0 ETH. Please ensure you have funds on this network before sending transactions."]
                }
            case .failure(let error):
                return ["error": "Failed to check account balance: \(error.localizedDescription)"]
            }

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
            var authorizationList: [AuthorizationsUtil.EIP7702Authorization] = []
            var batchCalls: [[String: Any]] = []

            // Check if user's wallet needs delegation to Simple7702Account
            var needsDelegation = false
            switch awaitPromise(web3.eth.getCode(address: fromAddr, block: .latest)) {
            case .success(let code):
                if code.bytes.isEmpty {
                    // Empty code - needs delegation
                    needsDelegation = true
                } else if code.bytes.count == 23 && code.bytes.starts(with: [0xef, 0x01, 0x00]) {
                    // Check if already delegated to Simple7702Account
                    let delegatedAddress = Array(code.bytes[3...]) // Skip 0xef0100 prefix
                    let expectedAddress = simple7702Addr.rawAddress
                    if delegatedAddress != expectedAddress {
                        // Delegated to wrong address - needs re-delegation
                        needsDelegation = true
                    } else {
                        // Already properly delegated
                    }
                } else {
                    // Has code but not a delegation indicator - needs delegation to replace
                    needsDelegation = true
                }
            case .failure:
                return ["error": "Failed to check code for user's wallet"]
            }

            // Compute transaction nonce once (pending) and reuse across auth and tx
            let txNonceEQ: EthereumQuantity
            switch awaitPromise(web3.eth.getTransactionCount(address: fromAddr, block: .pending)) {
            case .success(let n):
                txNonceEQ = n
            case .failure:
                return ["error": "Failed to get nonce"]
            }

            if needsDelegation {
                // For delegation, we need to create a transaction that will be submitted
                // The authorization will be handled by the AuthorizationsUtil.signAndSubmitAuthorization function
                // We don't need to add to authorizationList here as it's handled separately
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

            // Authorization summary
            // if authorizationList.isEmpty {
            //     No authorization needed - user's wallet already properly delegated to Simple7702Account
            // } else {
            //     1 authorization created to delegate user's wallet to Simple7702Account
            // }

            // Create executeBatch transaction
            let result = try await createExecuteBatchTransaction(
                calls: batchCalls,
                authorizations: authorizationList,
                fromAddress: fromAddress,
                chainIdBig: chainIdBig,
                version: version,
                currentBalance: currentBalance,
                txNonce: txNonceEQ
            )

            return result

        } catch {
            return ["error": "Failed to process batch calls: \(error.localizedDescription)"]
        }
    }

    private func handleWalletGetCapabilities(params: [Any]?) -> [String: Any] {
        // Check if user has authorized a connection (has wallet address)
        guard let walletAddress = getSavedAddress() else {
            return ["error": ["code": 4100, "message": "Unauthorized"]]
        }

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

        return ["result": capabilities]
    }

    private func handleWalletGetCallsStatus(params: [Any]?) -> [String: Any] {
        guard let params = params, params.count >= 1,
              let callBundleId = params[0] as? String else {
            return ["error": "Invalid wallet_getCallsStatus params - missing call bundle ID"]
        }

        // The callBundleId should be the transaction hash from wallet_sendCalls
        let (rpcURL, chainIdBig) = Constants.Networks.currentNetwork()
        let web3 = Web3(rpcURL: rpcURL)

        do {
            // Convert hex string to bytes for EthereumData
            guard let txHashData = Data(hexString: callBundleId) else {
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
                    "version": "2.0.0",
                    "chainId": Constants.Networks.getCurrentChainIdHex(),
                    "id": callBundleId,
                    "status": status,
                    "atomic": true, // Our EIP-7702 implementation is atomic
                    "receipts": [receiptDict]
                ]

                return ["result": result]

            case .failure(let error):
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
                throw NSError(domain: "SIWE", code: 3, userInfo: [NSLocalizedDescriptionKey: "Explicitly provided chain ID is not supported: \(explicitChainId)"])
            }
            chainId = explicitChainId
        } else if let firstSupportedChainId = chainIds.first {
            chainId = firstSupportedChainId
        } else {
            chainId = "0x1" // Ethereum mainnet as fallback
        }

        // Validate that the chosen chain ID is supported
        guard isChainSupported(chainId) else {
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

        var canonical = Data()
        canonical.append(r32)
        canonical.append(s32)
        canonical.append(vCanonical)
        let sigHex = "0x" + canonical.map { String(format: "%02x", $0) }.joined()

        return sigHex
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




    private func createExecuteBatchTransaction(calls: [[String: Any]], authorizations: [AuthorizationsUtil.EIP7702Authorization], fromAddress: String, chainIdBig: BigUInt, version: Int, currentBalance: BigUInt, txNonce: EthereumQuantity) async throws -> [String: Any] {
        let (rpcURL, currentChainId) = Constants.Networks.currentNetwork()
        let web3 = Web3(rpcURL: rpcURL)

        // Create fromAddr from the fromAddress parameter
        let fromAddr = try EthereumAddress(hex: fromAddress, eip55: false)


        // Manually ABI-encode executeBatch((address,uint256,bytes)[] calls)
        // selector (0x34fcd5be) + head (0x20) + array region (length, offsets, tuples, bytes)
        var data = Data()
        guard let selectorData = Data(hexString: "0x34fcd5be") else {
            throw NSError(domain: "Transaction", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to parse ABI selector"])
        }
        data.append(contentsOf: selectorData)

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

        // Use provided transaction nonce computed earlier to avoid race conditions
        let nonce: EthereumQuantity = txNonce

        // Get EIP-1559 fee data
        let maxFeePerGas: EthereumQuantity
        let maxPriorityFeePerGas: EthereumQuantity

        // Get gas price (simplified - using legacy gas price for now)
        switch awaitPromise(web3.eth.gasPrice()) {
        case .success(let gp):
            // Use EIP-1559 style fees if available; otherwise default to legacy gasPrice
            maxFeePerGas = gp
            maxPriorityFeePerGas = gp
        case .failure(let err):
            throw NSError(domain: "Transaction", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to get gas price"])
        }

        // Create transaction data
        let txData = try EthereumData(data)
        // Estimate gas (use default if estimation fails, for debugging)
        var gasLimit: EthereumQuantity
        let estimate = awaitPromise(web3.eth.estimateGas(call: EthereumCall(from: fromAddr, to: toAddr, gas: nil, gasPrice: nil, value: EthereumQuantity(quantity: BigUInt.zero), data: txData)))
        switch estimate {
        case .success(let est):
            gasLimit = est
        case .failure(let err):
            throw NSError(domain: "Transaction", code: 4, userInfo: [NSLocalizedDescriptionKey: "Gas estimation failed: \(err.localizedDescription)"])
        }

        // Add intrinsic overhead for EIP-7702 (base tx cost + per-authorization cost)
        if !authorizations.isEmpty {
            let authOverhead = BigUInt(25_000 * authorizations.count)
            let baseOverhead = BigUInt(21_000)
            let safetyMargin = BigUInt(50_000)
            let newLimit = gasLimit.quantity + authOverhead + baseOverhead + safetyMargin
            gasLimit = EthereumQuantity(quantity: newLimit)
        }

        // Check if balance is sufficient for estimated transaction cost
        let estimatedGasCost = gasLimit.quantity * maxFeePerGas.quantity

        if currentBalance < estimatedGasCost {
            let shortfall = estimatedGasCost - currentBalance
            let divisor = BigUInt(1_000_000_000_000_000_000)
            let formatWei = { (wei: BigUInt) -> String in
                let integer = wei / divisor
                let remainder = wei % divisor
                let remainderStr = String(remainder).leftPadded(to: 18)
                let decimals = String(remainderStr.prefix(6))
                return "\(integer).\(decimals) ETH"
            }
            return ["error": "Insufficient balance on chainId \(chainIdBig). Required: \(formatWei(estimatedGasCost)), Available: \(formatWei(currentBalance)), Shortfall: \(formatWei(shortfall))"]
        }

        // Check if we need EIP-7702 transaction format
        if !authorizations.isEmpty {
            // Use AuthorizationsUtil to sign and submit the authorization transaction
            let txHash = try await AuthorizationsUtil.signAndSubmitAuthorization(
                fromAddress: fromAddress,
                contractAddress: "0xe6Cae83BdE06E4c305530e199D7217f42808555B",
                chainId: chainIdBig
            )

            if version == 2 {
                return ["result": ["id": txHash]]
            } else {
                return ["result": txHash]
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


        // Send transaction
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

private extension String {
    func leftPadded(to length: Int, with pad: Character = "0") -> String {
        if count >= length { return self }
        return String(repeating: String(pad), count: length - count) + self
    }
}


