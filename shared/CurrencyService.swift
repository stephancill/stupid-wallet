import Foundation
import Web3
import Web3PromiseKit
import PromiseKit
import BigInt
import CryptoSwift

/// Service for fetching cryptocurrency exchange rates from Chainlink oracles
final class CurrencyService {
    static let shared = CurrencyService()

    // Chainlink ETH/USD Price Feed on Ethereum Mainnet
    // https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1&search=usdc#ethereum-mainnet
    private let ethUsdOracleAddress = "0x986b5E1e1755e3C2440e960477f25201B0a8bbD4"
    private let mainnetRpcUrl = "https://eth.llamarpc.com"

    // Cache
    private var cachedRate: Double?
    private var cacheTimestamp: Date?
    private let cacheDuration: TimeInterval = 5 * 60 // 5 minutes

    private init() {}

    /// Fetches the current ETH/USD exchange rate from Chainlink oracle
    /// - Returns: Current ETH price in USD
    /// - Throws: Error if oracle call fails
    func fetchEthUsdPrice() async throws -> Double {
        // Check cache first
        if let cached = cachedRate,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheDuration {
            return cached
        }

        let web3 = Web3(rpcURL: mainnetRpcUrl)
        let oracleAddress = try EthereumAddress(hex: ethUsdOracleAddress, eip55: false)

        // ABI for latestRoundData() function
        // function latestRoundData() external view returns (
        //   uint80 roundId,
        //   int256 answer,
        //   uint256 startedAt,
        //   uint256 updatedAt,
        //   uint80 answeredInRound
        // )
        let functionSignature = "latestRoundData()"
        let signatureData = functionSignature.data(using: .utf8)!
        let hashData = signatureData.sha3(.keccak256)
        let functionSelector = Data(Array(hashData.prefix(4)))

        let call = EthereumCall(
            from: nil,
            to: oracleAddress,
            gas: nil,
            gasPrice: nil,
            value: nil,
            data: try EthereumData(functionSelector)
        )

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EthereumData, Error>) in
            web3.eth.call(call: call, block: .latest) { response in
                switch response.status {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }

        // Decode the result
        // Returns: (uint80, int256, uint256, uint256, uint80)
        // We need the second value (answer) which is at bytes 32-64
        let bytes = result.bytes
        guard bytes.count >= 64 else {
            throw NSError(domain: "CurrencyService", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid oracle response"])
        }

        // Extract answer (int256) from bytes 32-64
        let answerBytes = Array(bytes[32..<64])
        let answer = BigInt(Data(answerBytes))

        // Chainlink ETH/USD feed result needs to be divided by 1e(18-6) = 1e12
        // Convert to Double: price = answer / 10^11
        let divisor = BigInt(10).power(11)
        let price = Double(answer) / Double(divisor)

        // Update cache
        cachedRate = price
        cacheTimestamp = Date()

        return price
    }

    /// Clears the cached exchange rate, forcing a fresh fetch on next call
    func clearCache() {
        cachedRate = nil
        cacheTimestamp = nil
    }
}

