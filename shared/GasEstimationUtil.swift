import Foundation
import Web3
import BigInt
import PromiseKit

// MARK: - Helper Extensions and Utilities

extension BigUInt {
    /// Parse a hex quantity string (with or without "0x" prefix) to BigUInt
    static func fromHexQuantity(_ hex: String) -> BigUInt? {
        guard !hex.isEmpty else { return nil }
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return BigUInt(s, radix: 16)
    }
}

/// Bridge PromiseKit to async/await
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

// MARK: - Gas Estimation Utility

enum GasEstimationUtil {
    
    // MARK: - Gas Limit Estimation with Buffer
    
    /// Standard buffer calculation for gas estimates
    /// Uses 50% buffer or minimum 1,500 gas, whichever is larger
    static func applyGasBuffer(to estimate: BigUInt) -> BigUInt {
        let buffer = max(estimate / BigUInt(2), BigUInt(1_500))
        let padded = estimate + buffer
        return max(padded, BigUInt(21_000))
    }
    
    /// Estimate gas limit for a transaction call
    static func estimateGasLimit(
        web3: Web3,
        from: EthereumAddress,
        to: EthereumAddress,
        value: BigUInt,
        data: EthereumData?
    ) -> Swift.Result<BigUInt, Error> {
        let call = EthereumCall(
            from: from,
            to: to,
            gas: nil,
            gasPrice: nil,
            value: EthereumQuantity(quantity: value),
            data: data
        )
        
        let result = awaitPromise(web3.eth.estimateGas(call: call))
        
        switch result {
        case .success(let estimate):
            return .success(applyGasBuffer(to: estimate.quantity))
        case .failure(let error):
            return .failure(error)
        }
    }
    
    // MARK: - EIP-7702 Overhead Calculation
    
    /// Calculate additional gas overhead for EIP-7702 transactions
    static func calculateEIP7702Overhead(
        authorizationCount: Int,
        includeSafetyMargin: Bool = true
    ) -> BigUInt {
        let perAuthOverhead = BigUInt(25_000 * authorizationCount)
        let baseOverhead = BigUInt(21_000)
        let safetyMargin = includeSafetyMargin ? BigUInt(20_000) : BigUInt(0)
        return perAuthOverhead + baseOverhead + safetyMargin
    }
    
    /// Apply EIP-7702 overhead to a gas limit estimate
    static func applyEIP7702Overhead(
        to gasLimit: BigUInt,
        authorizationCount: Int,
        includeSafetyMargin: Bool = true
    ) -> BigUInt {
        return gasLimit + calculateEIP7702Overhead(
            authorizationCount: authorizationCount,
            includeSafetyMargin: includeSafetyMargin
        )
    }
    
    // MARK: - Gas Price Fetching (Legacy & EIP-1559)
    
    struct GasPrices {
        let maxFeePerGas: BigUInt
        let maxPriorityFeePerGas: BigUInt
        let isEIP1559: Bool
    }
    
    /// Fetch current gas prices from network
    /// Returns EIP-1559 style fees with reasonable defaults
    static func fetchGasPrices(
        web3: Web3,
        maxFeeCapGwei: BigUInt? = BigUInt(100) // 100 gwei default cap
    ) -> Swift.Result<GasPrices, Error> {
        let result = awaitPromise(web3.eth.gasPrice())
        
        switch result {
        case .success(let gasPrice):
            let networkGasPrice = gasPrice.quantity
            
            // maxFeePerGas: 2x network gas price (capped at maxFeeCapGwei)
            let oneGwei = BigUInt(1_000_000_000)
            let maxFeeCap = (maxFeeCapGwei ?? BigUInt(100)) * oneGwei
            let maxFeePerGas = min(networkGasPrice * 2, maxFeeCap)
            
            // maxPriorityFeePerGas: half of network price (capped at 2 gwei)
            let twoGwei = BigUInt(2_000_000_000)
            let maxPriorityFeePerGas = min(networkGasPrice / 2, twoGwei)
            
            return .success(GasPrices(
                maxFeePerGas: maxFeePerGas,
                maxPriorityFeePerGas: maxPriorityFeePerGas,
                isEIP1559: true
            ))
            
        case .failure(let error):
            return .failure(error)
        }
    }
    
    /// Fetch gas prices with override from transaction params
    static func getGasPrices(
        web3: Web3,
        maxFeePerGasHex: String?,
        maxPriorityFeePerGasHex: String?,
        gasPriceHex: String?
    ) -> Swift.Result<GasPrices, Error> {
        // If EIP-1559 params provided, use them
        if let maxFee = BigUInt.fromHexQuantity(maxFeePerGasHex ?? ""),
           let maxPrio = BigUInt.fromHexQuantity(maxPriorityFeePerGasHex ?? "") {
            return .success(GasPrices(
                maxFeePerGas: maxFee,
                maxPriorityFeePerGas: maxPrio,
                isEIP1559: true
            ))
        }
        
        // If legacy gasPrice provided, use it
        if let gasPrice = BigUInt.fromHexQuantity(gasPriceHex ?? "") {
            return .success(GasPrices(
                maxFeePerGas: gasPrice,
                maxPriorityFeePerGas: BigUInt(0),
                isEIP1559: false
            ))
        }
        
        // Otherwise fetch from network
        return fetchGasPrices(web3: web3)
    }
    
    // MARK: - Total Cost Calculation
    
    struct GasEstimate {
        let gasLimit: BigUInt
        let maxFeePerGas: BigUInt
        let maxPriorityFeePerGas: BigUInt
        let estimatedGasCost: BigUInt
        let totalCost: BigUInt // gas + value
        let type: TransactionType
        
        enum TransactionType: String {
            case legacy
            case eip1559
            case eip7702
        }
        
        /// Format wei to ETH string with 6 decimal precision
        func formatWei(_ wei: BigUInt) -> String {
            let divisor = BigUInt(1_000_000_000_000_000_000)
            let integer = wei / divisor
            let remainder = wei % divisor
            let remainderStr = String(remainder).leftPadded(to: 18)
            let decimals = String(remainderStr.prefix(6))
            return "\(integer).\(decimals)"
        }
        
        /// Convert to JSON-serializable dictionary
        func toDictionary() -> [String: Any] {
            return [
                "gasLimit": "0x" + String(gasLimit, radix: 16),
                "maxFeePerGas": "0x" + String(maxFeePerGas, radix: 16),
                "maxPriorityFeePerGas": "0x" + String(maxPriorityFeePerGas, radix: 16),
                "estimatedGasCost": "0x" + String(estimatedGasCost, radix: 16),
                "estimatedGasCostEth": formatWei(estimatedGasCost),
                "totalCost": "0x" + String(totalCost, radix: 16),
                "totalCostEth": formatWei(totalCost),
                "type": type.rawValue
            ]
        }
    }
    
    /// Calculate total transaction cost (gas + value)
    static func calculateTotalCost(
        gasLimit: BigUInt,
        gasPrices: GasPrices,
        transactionValue: BigUInt,
        transactionType: GasEstimate.TransactionType = .eip1559
    ) -> GasEstimate {
        let estimatedGasCost = gasLimit * gasPrices.maxFeePerGas
        let totalCost = estimatedGasCost + transactionValue
        
        return GasEstimate(
            gasLimit: gasLimit,
            maxFeePerGas: gasPrices.maxFeePerGas,
            maxPriorityFeePerGas: gasPrices.maxPriorityFeePerGas,
            estimatedGasCost: estimatedGasCost,
            totalCost: totalCost,
            type: transactionType
        )
    }
}

// MARK: - Helper Extension for String Padding

private extension String {
    func leftPadded(to length: Int) -> String {
        if count >= length { return self }
        return String(repeating: "0", count: length - count) + self
    }
}

