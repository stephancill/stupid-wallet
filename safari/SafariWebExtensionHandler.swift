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
        case "eth_chainId":
            return handleChainId()
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
                txToSign.transactionType = .eip1559
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
}

// Helpers
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
