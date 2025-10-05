//
//  AuthorizationsUtil.swift
//  ios-wallet
//
//  Created by Stephan Cilliers on 2025/01/14.
//

import Foundation
import Web3
import Web3PromiseKit
import PromiseKit
import BigInt
import Model
import Wallet
import CryptoSwift

enum AuthorizationsUtil {
    // EIP-7702 constants
    static let simple7702AccountAddress = "0xe6Cae83BdE06E4c305530e199D7217f42808555B"

    // EIP-7702 Authorization structure
    struct EIP7702Authorization {
        let chainId: BigUInt
        let address: String // Using string representation for now
        let nonce: BigUInt
        let r: Data
        let s: Data
        let v: UInt8
    }

    struct AuthorizationStatus {
        let chainId: BigUInt
        let chainName: String
        let hasAuthorization: Bool
        let authorizedAddress: String?
        let error: String?
    }

    /// Check if an address has an EIP-7702 authorization on a specific chain
    static func checkAuthorization(for address: String, on chainId: BigUInt) async -> AuthorizationStatus {
        let chainName = Constants.Networks.chainName(forChainId: chainId)
        let rpcURL = Constants.Networks.rpcURL(forChainId: chainId)

        do {
            let web3 = Web3(rpcURL: rpcURL)
            let addr = try EthereumAddress(hex: address, eip55: false)

            let codeResult = awaitPromise(web3.eth.getCode(address: addr, block: .latest))

            switch codeResult {
            case .success(let code):
                // Check if the code indicates an EIP-7702 authorization
                // EIP-7702 authorizations start with 0xef0100 followed by the authorized contract address
                if code.bytes.count == 23 && code.bytes.starts(with: [0xef, 0x01, 0x00]) {
                    // Extract the authorized contract address (20 bytes after the 3-byte prefix)
                    let authorizedAddressBytes = Array(code.bytes[3...22])
                    let authorizedAddress = "0x" + authorizedAddressBytes.map { String(format: "%02x", $0) }.joined()
                    return AuthorizationStatus(
                        chainId: chainId,
                        chainName: chainName,
                        hasAuthorization: true,
                        authorizedAddress: authorizedAddress,
                        error: nil
                    )
                } else {
                    return AuthorizationStatus(
                        chainId: chainId,
                        chainName: chainName,
                        hasAuthorization: false,
                        authorizedAddress: nil,
                        error: nil
                    )
                }
            case .failure(let error):
                return AuthorizationStatus(
                    chainId: chainId,
                    chainName: chainName,
                    hasAuthorization: false,
                    authorizedAddress: nil,
                    error: error.localizedDescription
                )
            }
        } catch {
            return AuthorizationStatus(
                chainId: chainId,
                chainName: chainName,
                hasAuthorization: false,
                authorizedAddress: nil,
                error: error.localizedDescription
            )
        }
    }

    /// Check authorizations for an address on all supported chains
    static func checkAllAuthorizations(for address: String) async -> [AuthorizationStatus] {
        let networks = Constants.Networks.networksList

        var results: [AuthorizationStatus] = []
        for network in networks {
            let status = await checkAuthorization(for: address, on: network.chainId)
            results.append(status)
        }

        return results.sorted { $0.chainName < $1.chainName }
    }

    /// Reset authorization by signing a new authorization to the zero address
    static func resetAuthorization(for address: String, on chainId: BigUInt) async throws -> String {
        let zeroAddress = "0x0000000000000000000000000000000000000000"
        return try await signAndSubmitAuthorization(
            fromAddress: address,
            contractAddress: zeroAddress,
            chainId: chainId
        )
    }

    /// Upgrade authorization by setting an authorization to the Simple7702Account contract
    static func upgradeAuthorization(for address: String, on chainId: BigUInt) async throws -> String {
        return try await signAndSubmitAuthorization(
            fromAddress: address,
            contractAddress: simple7702AccountAddress,
            chainId: chainId
        )
    }

    /// Sign and submit an EIP-7702 authorization
    static func signAndSubmitAuthorization(fromAddress: String, contractAddress: String, chainId: BigUInt) async throws -> String {
        let rpcURL = Constants.Networks.rpcURL(forChainId: chainId)
        let web3 = Web3(rpcURL: rpcURL)

        // Get the current nonce for the address
        let fromAddr = try EthereumAddress(hex: fromAddress, eip55: false)
        let nonceResult = awaitPromise(web3.eth.getTransactionCount(address: fromAddr, block: .pending))

        let txNonce: BigUInt
        switch nonceResult {
        case .success(let nonce):
            txNonce = nonce.quantity
        case .failure(let error):
            throw NSError(domain: "Authorization", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get nonce: \(error.localizedDescription)"])
        }

        // Sign the authorization
        // For EIP-7702, when the transaction is submitted from the same account,
        // the authorization nonce must be incremented by 1
        let authorizationNonce = txNonce + 1
        let authorization = try signEIP7702Authorization(
            contractAddress: contractAddress,
            chainId: chainId,
            fromAddress: fromAddress,
            txNonce: authorizationNonce
        )

        // Create a minimal transaction to carry the authorization
        let authorizations = [authorization]

        // Estimate gas with EIP-7702 overhead
        let estimateResult = GasEstimationUtil.estimateGasLimit(
            web3: web3,
            from: fromAddr,
            to: fromAddr, // Self-transaction
            value: BigUInt.zero,
            data: try EthereumData(Data()) // Empty data for estimation
        )

        guard case .success(let baseEstimate) = estimateResult else {
            throw NSError(domain: "Authorization", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to estimate gas"])
        }

        let estimatedGasLimit = GasEstimationUtil.applyEIP7702Overhead(
            to: baseEstimate,
            authorizationCount: authorizations.count,
            includeSafetyMargin: true
        )

        // Fetch gas prices
        let gasPricesResult = GasEstimationUtil.fetchGasPrices(web3: web3)
        guard case .success(let gasPrices) = gasPricesResult else {
            throw NSError(domain: "Authorization", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to get gas price"])
        }

        let maxFeePerGas = gasPrices.maxFeePerGas
        let maxPriorityFeePerGas = gasPrices.maxPriorityFeePerGas

        let rawTx = try serializeEIP7702Transaction(
            nonce: EthereumQuantity(quantity: txNonce),
            maxPriorityFeePerGas: EthereumQuantity(quantity: maxPriorityFeePerGas),
            maxFeePerGas: EthereumQuantity(quantity: maxFeePerGas),
            gasLimit: EthereumQuantity(quantity: estimatedGasLimit),
            to: fromAddress, // Self-transaction
            value: EthereumQuantity(quantity: BigUInt.zero),
            data: Data(),
            accessList: [],
            authorizations: authorizations,
            chainId: chainId,
            fromAddress: fromAddress
        )

        // Submit the transaction
        let rawTxHex = "0x" + rawTx.hex()
        let url = URL(string: rpcURL)!

        return try await submitEIP7702Transaction(rpcURL: url, rawTxHex: rawTxHex)
    }

    /// Sign and submit a full EIP-7702 transaction that includes calldata to execute,
    /// embedding the authorization in the same transaction (type 0x04).
    /// - Parameters:
    ///   - fromAddress: Externally owned account address
    ///   - contractAddress: The contract to delegate to (e.g. Simple7702Account)
    ///   - chainId: Chain ID
    ///   - txNonce: The outer transaction nonce
    ///   - gasLimit: Gas limit for the outer transaction
    ///   - maxFeePerGas: Max fee per gas (EIP-1559 style or legacy-equivalent)
    ///   - maxPriorityFeePerGas: Max priority fee per gas (tip)
    ///   - data: Calldata to execute in the delegated context (e.g. executeBatch selector+args)
    /// - Returns: Transaction hash as hex string
    static func signAndSubmitAuthorizationWithCalldata(
        fromAddress: String,
        contractAddress: String,
        chainId: BigUInt,
        txNonce: BigUInt,
        gasLimit: BigUInt,
        maxFeePerGas: BigUInt,
        maxPriorityFeePerGas: BigUInt,
        data: Data
    ) async throws -> String {
        // Per EIP-7702: when the tx is submitted by the same account, the authorization nonce
        // should be incremented by 1 relative to the outer tx nonce.
        let authorization = try signEIP7702Authorization(
            contractAddress: contractAddress,
            chainId: chainId,
            fromAddress: fromAddress,
            txNonce: txNonce + 1
        )

        let rawTx = try serializeEIP7702Transaction(
            nonce: EthereumQuantity(quantity: txNonce),
            maxPriorityFeePerGas: EthereumQuantity(quantity: maxPriorityFeePerGas),
            maxFeePerGas: EthereumQuantity(quantity: maxFeePerGas),
            gasLimit: EthereumQuantity(quantity: gasLimit),
            to: fromAddress, // Self-transaction
            value: EthereumQuantity(quantity: BigUInt.zero),
            data: data,
            accessList: [],
            authorizations: [authorization],
            chainId: chainId,
            fromAddress: fromAddress
        )

        let rawTxHex = "0x" + rawTx.hex()
        let url = URL(string: Constants.Networks.rpcURL(forChainId: chainId))!
        return try await submitEIP7702Transaction(rpcURL: url, rawTxHex: rawTxHex)
    }

    // MARK: - Private Helper Functions

    private static func signEIP7702Authorization(contractAddress: String, chainId: BigUInt, fromAddress: String, txNonce: BigUInt) throws -> EIP7702Authorization {
        // Create authorization hash: keccak256('0x05' || rlp([chain_id, address, nonce]))
        let addr = try EthereumAddress(hex: contractAddress, eip55: false)
        let addressData = Data(addr.rawAddress) // 20-byte address, no padding per spec

        // RLP encode [chain_id, address, nonce]
        let encoder = RLPEncoder()
        let rlpData = try encoder.encode(RLPItem.array([
            RLPItem.bigUInt(chainId),              // chain_id
            RLPItem.bytes([UInt8](addressData)),  // 20-byte address
            RLPItem.bigUInt(txNonce)               // nonce
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
        // Normalize v to y_parity (0/1) regardless of library returning 27/28 or 0/1
        let authYParity: UInt8 = {
            if signature.v == 27 || signature.v == 28 { return UInt8(signature.v - 27) }
            if signature.v == 0 || signature.v == 1 { return UInt8(signature.v) }
            return UInt8(signature.v & 1)
        }()

        // Create authorization object
        return EIP7702Authorization(
            chainId: chainId,
            address: contractAddress,
            nonce: txNonce,
            r: Data(signature.r),
            s: Data(signature.s),
            v: authYParity
        )
    }

    private static func serializeEIP7702Transaction(
        nonce: EthereumQuantity,
        maxPriorityFeePerGas: EthereumQuantity,
        maxFeePerGas: EthereumQuantity,
        gasLimit: EthereumQuantity,
        to: String?,
        value: EthereumQuantity,
        data: Data,
        accessList: [(String, [Data])],
        authorizations: [EIP7702Authorization],
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

        // Sign the digest
        let ethAddress = try Model.EthereumAddress(hex: fromAddress)
        let account = EthereumAccount(address: ethAddress)
        let signature = try account.signDigest([UInt8](digest), accessGroup: Constants.accessGroup)

        // Normalize signature v to y_parity (0/1) for EIP-7702 outer tx
        let yParity: BigUInt = {
            if signature.v == 27 || signature.v == 28 { return BigUInt(signature.v - 27) }
            if signature.v == 0 || signature.v == 1 { return BigUInt(signature.v) }
            return BigUInt(signature.v & 1)
        }()
        let r = BigUInt(signature.r)
        let s = BigUInt(signature.s)

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

    private static func submitEIP7702Transaction(rpcURL: URL, rawTxHex: String) async throws -> String {
        return try await JSONRPC.request(rpcURL: rpcURL, method: "eth_sendRawTransaction", params: [rawTxHex])
    }


    /// Get transaction receipt using direct RPC call
    static func getTransactionReceipt(txHash: String, rpcURL: URL, timeout: TimeInterval = 30.0) async throws -> [String: Any]? {
        let result: Any = try await JSONRPC.request(rpcURL: rpcURL, method: "eth_getTransactionReceipt", params: [txHash], timeout: timeout)

        // Handle null result (transaction not found yet)
        if let resultDict = result as? [String: Any] {
            return resultDict
        } else if result is NSNull {
            return nil
        } else {
            throw NSError(domain: "RPC", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unexpected response type for eth_getTransactionReceipt"])
        }
    }
}

// Helper function to await PromiseKit promises
private func awaitPromise<T>(_ promise: Promise<T>, timeout: TimeInterval = 30.0) -> Swift.Result<T, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Swift.Result<T, Error>?
    promise.done { value in
        result = .success(value)
        semaphore.signal()
    }.catch { error in
        result = .failure(error)
        semaphore.signal()
    }

    let timeoutResult = semaphore.wait(timeout: .now() + timeout)

    // Check if semaphore timed out
    if timeoutResult == .timedOut {
        return .failure(NSError(domain: "Authorization", code: 8, userInfo: [NSLocalizedDescriptionKey: "Promise timeout after \(timeout) seconds"]))
    }

    // If semaphore was signaled but result is still nil, something went wrong
    guard let finalResult = result else {
        return .failure(NSError(domain: "Authorization", code: 9, userInfo: [NSLocalizedDescriptionKey: "Promise completed but result is nil"]))
    }

    return finalResult
}

// Extension to support left/right padding for Data
private extension Data {
    func leftPadded(to length: Int) -> Data {
        if count >= length { return self }
        return Data(repeating: 0, count: length - count) + self
    }

    func rightPadded(to length: Int) -> Data {
        if count >= length { return self }
        return self + Data(repeating: 0, count: length - count)
    }

    func hex() -> String {
        return self.map { String(format: "%02x", $0) }.joined()
    }
}

// Extension to support hex string initialization
extension Data {
    init?(hexString: String) {
        let hex: String
        if hexString.hasPrefix("0x") {
            hex = String(hexString.dropFirst(2))
        } else {
            hex = hexString
        }

        // Validate hex string length and characters
        guard !hex.isEmpty else { return nil }
        guard hex.count % 2 == 0 else { return nil }
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }

        var data = Data(capacity: hex.count / 2)

        for i in stride(from: 0, to: hex.count, by: 2) {
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 2)
            let byteString = String(hex[start..<end])

            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
        }

        self = data
    }
}
