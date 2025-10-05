//
//  GasEstimationUtilTests.swift
//  ios-wallet Tests
//
//  Unit tests for GasEstimationUtil centralized gas estimation logic
//

import Foundation
import Testing
import BigInt
@testable import stupid_wallet

struct GasEstimationUtilTests {
    
    // MARK: - Gas Buffer Calculation Tests
    
    @Test("Gas buffer applies 20% buffer for large estimates")
    func testGasBuffer20Percent() {
        // Given: A gas estimate of 100,000
        let estimate = BigUInt(100_000)
        
        // When: Applying gas buffer
        let result = GasEstimationUtil.applyGasBuffer(to: estimate)
        
        // Then: Should add 20% buffer (20,000)
        // Expected: 100,000 + 20,000 = 120,000
        #expect(result == BigUInt(120_000))
    }
    
    @Test("Gas buffer applies minimum 1,500 gas for small estimates")
    func testGasBufferMinimum1500() {
        // Given: A small gas estimate where 20% < 1,500
        // Use 5,000 gas: 20% = 1,000, so buffer should be 1,500
        let estimate = BigUInt(5_000)
        
        // When: Applying gas buffer
        let result = GasEstimationUtil.applyGasBuffer(to: estimate)
        
        // Then: Should enforce 21,000 minimum
        // Calculation: buffer = max(1,000, 1,500) = 1,500
        //              padded = 5,000 + 1,500 = 6,500
        //              final = max(6,500, 21,000) = 21,000
        // Note: For very small estimates, the 21,000 floor always applies
        #expect(result == BigUInt(21_000))
    }
    
    @Test("Gas buffer enforces 21,000 minimum")
    func testGasBufferMinimum21000() {
        // Given: A very small gas estimate of 10,000
        let estimate = BigUInt(10_000)
        
        // When: Applying gas buffer
        let result = GasEstimationUtil.applyGasBuffer(to: estimate)
        
        // Then: Should return at least 21,000 (10,000 + 1,500 = 11,500 < 21,000)
        #expect(result == BigUInt(21_000))
    }
    
    @Test("Gas buffer handles zero estimate")
    func testGasBufferZero() {
        // Given: Zero gas estimate
        let estimate = BigUInt(0)
        
        // When: Applying gas buffer
        let result = GasEstimationUtil.applyGasBuffer(to: estimate)
        
        // Then: Should return minimum 21,000
        #expect(result == BigUInt(21_000))
    }
    
    @Test("Gas buffer calculation for typical transaction (50,000 gas)")
    func testGasBufferTypicalTransaction() {
        // Given: Typical transaction estimate of 50,000
        let estimate = BigUInt(50_000)
        
        // When: Applying gas buffer
        let result = GasEstimationUtil.applyGasBuffer(to: estimate)
        
        // Then: Should add 20% buffer (10,000)
        // Expected: 50,000 + 10,000 = 60,000
        #expect(result == BigUInt(60_000))
    }
    
    // MARK: - EIP-7702 Overhead Calculation Tests
    
    @Test("EIP-7702 overhead for single authorization with safety margin")
    func testEIP7702OverheadSingleAuth() {
        // Given: Single authorization with safety margin
        let authCount = 1
        
        // When: Calculating overhead
        let overhead = GasEstimationUtil.calculateEIP7702Overhead(
            authorizationCount: authCount,
            includeSafetyMargin: true
        )
        
        // Then: Should be 25k + 21k + 20k = 66,000
        #expect(overhead == BigUInt(66_000))
    }
    
    @Test("EIP-7702 overhead for single authorization without safety margin")
    func testEIP7702OverheadNoSafetyMargin() {
        // Given: Single authorization without safety margin
        let authCount = 1
        
        // When: Calculating overhead
        let overhead = GasEstimationUtil.calculateEIP7702Overhead(
            authorizationCount: authCount,
            includeSafetyMargin: false
        )
        
        // Then: Should be 25k + 21k = 46,000
        #expect(overhead == BigUInt(46_000))
    }
    
    @Test("EIP-7702 overhead for multiple authorizations")
    func testEIP7702OverheadMultipleAuth() {
        // Given: Three authorizations
        let authCount = 3
        
        // When: Calculating overhead
        let overhead = GasEstimationUtil.calculateEIP7702Overhead(
            authorizationCount: authCount,
            includeSafetyMargin: true
        )
        
        // Then: Should be (25k * 3) + 21k + 20k = 116,000
        #expect(overhead == BigUInt(116_000))
    }
    
    @Test("EIP-7702 overhead applied to existing gas limit")
    func testApplyEIP7702Overhead() {
        // Given: Base gas limit of 100,000 and single authorization
        let baseGas = BigUInt(100_000)
        let authCount = 1
        
        // When: Applying overhead
        let result = GasEstimationUtil.applyEIP7702Overhead(
            to: baseGas,
            authorizationCount: authCount,
            includeSafetyMargin: true
        )
        
        // Then: Should be 100,000 + 66,000 = 166,000
        #expect(result == BigUInt(166_000))
    }
    
    @Test("EIP-7702 overhead with zero authorizations")
    func testEIP7702OverheadZeroAuth() {
        // Given: Zero authorizations
        let authCount = 0
        
        // When: Calculating overhead
        let overhead = GasEstimationUtil.calculateEIP7702Overhead(
            authorizationCount: authCount,
            includeSafetyMargin: true
        )
        
        // Then: Should be 0 + 21k + 20k = 41,000
        #expect(overhead == BigUInt(41_000))
    }
    
    // MARK: - Total Cost Calculation Tests
    
    @Test("Total cost calculation for EIP-1559 transaction")
    func testTotalCostEIP1559() {
        // Given: Gas params and transaction value
        let gasLimit = BigUInt(50_000)
        let maxFeePerGas = BigUInt(50_000_000_000) // 50 gwei
        let maxPriorityFeePerGas = BigUInt(2_000_000_000) // 2 gwei
        let txValue = BigUInt(1_000_000_000_000_000_000) // 1 ETH
        
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            isEIP1559: true
        )
        
        // When: Calculating total cost
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: gasLimit,
            gasPrices: gasPrices,
            transactionValue: txValue,
            transactionType: .eip1559
        )
        
        // Then: Verify calculated values
        let expectedGasCost = gasLimit * maxFeePerGas // 50,000 * 50 gwei = 2,500,000 gwei
        let expectedTotalCost = expectedGasCost + txValue
        
        #expect(estimate.gasLimit == gasLimit)
        #expect(estimate.maxFeePerGas == maxFeePerGas)
        #expect(estimate.maxPriorityFeePerGas == maxPriorityFeePerGas)
        #expect(estimate.estimatedGasCost == expectedGasCost)
        #expect(estimate.totalCost == expectedTotalCost)
        #expect(estimate.type == .eip1559)
    }
    
    @Test("Total cost calculation for legacy transaction")
    func testTotalCostLegacy() {
        // Given: Legacy gas params
        let gasLimit = BigUInt(21_000)
        let gasPrice = BigUInt(20_000_000_000) // 20 gwei
        let txValue = BigUInt(500_000_000_000_000_000) // 0.5 ETH
        
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: gasPrice,
            maxPriorityFeePerGas: BigUInt(0),
            isEIP1559: false
        )
        
        // When: Calculating total cost
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: gasLimit,
            gasPrices: gasPrices,
            transactionValue: txValue,
            transactionType: .legacy
        )
        
        // Then: Verify calculated values
        let expectedGasCost = gasLimit * gasPrice
        let expectedTotalCost = expectedGasCost + txValue
        
        #expect(estimate.estimatedGasCost == expectedGasCost)
        #expect(estimate.totalCost == expectedTotalCost)
        #expect(estimate.type == .legacy)
        #expect(estimate.maxPriorityFeePerGas == BigUInt(0))
    }
    
    @Test("Total cost calculation with zero transaction value")
    func testTotalCostZeroValue() {
        // Given: Zero value transaction (e.g., contract call)
        let gasLimit = BigUInt(100_000)
        let maxFeePerGas = BigUInt(30_000_000_000) // 30 gwei
        let txValue = BigUInt(0)
        
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: BigUInt(1_000_000_000),
            isEIP1559: true
        )
        
        // When: Calculating total cost
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: gasLimit,
            gasPrices: gasPrices,
            transactionValue: txValue,
            transactionType: .eip1559
        )
        
        // Then: Total cost should equal gas cost
        #expect(estimate.totalCost == estimate.estimatedGasCost)
        #expect(estimate.totalCost == gasLimit * maxFeePerGas)
    }
    
    @Test("Total cost calculation for EIP-7702 transaction")
    func testTotalCostEIP7702() {
        // Given: EIP-7702 transaction with delegation overhead
        let baseGasLimit = BigUInt(50_000)
        let gasLimitWithOverhead = GasEstimationUtil.applyEIP7702Overhead(
            to: baseGasLimit,
            authorizationCount: 1,
            includeSafetyMargin: true
        )
        let maxFeePerGas = BigUInt(40_000_000_000) // 40 gwei
        let txValue = BigUInt(0)
        
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: BigUInt(2_000_000_000),
            isEIP1559: true
        )
        
        // When: Calculating total cost
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: gasLimitWithOverhead,
            gasPrices: gasPrices,
            transactionValue: txValue,
            transactionType: .eip7702
        )
        
        // Then: Verify EIP-7702 type and includes overhead
        #expect(estimate.type == .eip7702)
        #expect(estimate.gasLimit == gasLimitWithOverhead)
        #expect(estimate.gasLimit > baseGasLimit) // Should be higher due to overhead
    }
    
    // MARK: - Wei Formatting Tests
    
    @Test("Format 1 ETH to string")
    func testFormatOneETH() {
        // Given: 1 ETH in wei
        let oneETH = BigUInt("1000000000000000000")
        
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: BigUInt(1),
            maxPriorityFeePerGas: BigUInt(0),
            isEIP1559: true
        )
        
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: BigUInt(1),
            gasPrices: gasPrices,
            transactionValue: oneETH,
            transactionType: .eip1559
        )
        
        // When: Formatting total cost
        let formatted = estimate.formatWei(oneETH)
        
        // Then: Should be "1.000000"
        #expect(formatted == "1.000000")
    }
    
    @Test("Format fractional ETH to string")
    func testFormatFractionalETH() {
        // Given: 0.123456 ETH in wei
        let fractionalETH = BigUInt("123456000000000000")
        
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: BigUInt(1),
            maxPriorityFeePerGas: BigUInt(0),
            isEIP1559: true
        )
        
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: BigUInt(1),
            gasPrices: gasPrices,
            transactionValue: BigUInt(0),
            transactionType: .eip1559
        )
        
        // When: Formatting
        let formatted = estimate.formatWei(fractionalETH)
        
        // Then: Should be "0.123456"
        #expect(formatted == "0.123456")
    }
    
    @Test("Format gas cost to ETH string")
    func testFormatGasCost() {
        // Given: Gas cost of 50,000 gas at 50 gwei = 0.0025 ETH
        let gasLimit = BigUInt(50_000)
        let maxFeePerGas = BigUInt(50_000_000_000) // 50 gwei
        
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: BigUInt(2_000_000_000),
            isEIP1559: true
        )
        
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: gasLimit,
            gasPrices: gasPrices,
            transactionValue: BigUInt(0),
            transactionType: .eip1559
        )
        
        // When: Formatting gas cost
        let formatted = estimate.formatWei(estimate.estimatedGasCost)
        
        // Then: Should be "0.002500"
        #expect(formatted == "0.002500")
    }
    
    @Test("Format zero wei")
    func testFormatZeroWei() {
        // Given: Zero wei
        let zero = BigUInt(0)
        
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: BigUInt(1),
            maxPriorityFeePerGas: BigUInt(0),
            isEIP1559: true
        )
        
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: BigUInt(1),
            gasPrices: gasPrices,
            transactionValue: BigUInt(0),
            transactionType: .eip1559
        )
        
        // When: Formatting
        let formatted = estimate.formatWei(zero)
        
        // Then: Should be "0.000000"
        #expect(formatted == "0.000000")
    }
    
    @Test("Format very small amount (1 wei)")
    func testFormatOneWei() {
        // Given: 1 wei
        let oneWei = BigUInt(1)
        
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: BigUInt(1),
            maxPriorityFeePerGas: BigUInt(0),
            isEIP1559: true
        )
        
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: BigUInt(1),
            gasPrices: gasPrices,
            transactionValue: BigUInt(0),
            transactionType: .eip1559
        )
        
        // When: Formatting
        let formatted = estimate.formatWei(oneWei)
        
        // Then: Should be "0.000000" (rounds down to 6 decimals)
        #expect(formatted == "0.000000")
    }
    
    @Test("Format large amount (100 ETH)")
    func testFormatLargeAmount() {
        // Given: 100 ETH
        let largeAmount = BigUInt("100000000000000000000")
        
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: BigUInt(1),
            maxPriorityFeePerGas: BigUInt(0),
            isEIP1559: true
        )
        
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: BigUInt(1),
            gasPrices: gasPrices,
            transactionValue: BigUInt(0),
            transactionType: .eip1559
        )
        
        // When: Formatting
        let formatted = estimate.formatWei(largeAmount)
        
        // Then: Should be "100.000000"
        #expect(formatted == "100.000000")
    }
    
    // MARK: - Dictionary Conversion Tests
    
    @Test("GasEstimate converts to dictionary correctly")
    func testToDictionary() {
        // Given: Gas estimate values
        let gasLimit = BigUInt(50_000)
        let maxFeePerGas = BigUInt(50_000_000_000) // 50 gwei
        let maxPriorityFeePerGas = BigUInt(2_000_000_000) // 2 gwei
        let txValue = BigUInt(1_000_000_000_000_000_000) // 1 ETH
        
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            isEIP1559: true
        )
        
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: gasLimit,
            gasPrices: gasPrices,
            transactionValue: txValue,
            transactionType: .eip1559
        )
        
        // When: Converting to dictionary
        let dict = estimate.toDictionary()
        
        // Then: Verify all keys exist and have correct types
        #expect(dict["gasLimit"] as? String == "0xc350") // 50,000 in hex
        #expect(dict["maxFeePerGas"] as? String == "0xba43b7400") // 50 gwei in hex
        #expect(dict["maxPriorityFeePerGas"] as? String == "0x77359400") // 2 gwei in hex
        #expect(dict["estimatedGasCost"] != nil)
        #expect(dict["estimatedGasCostEth"] != nil)
        #expect(dict["totalCost"] != nil)
        #expect(dict["totalCostEth"] != nil)
        #expect(dict["type"] as? String == "eip1559")
    }
    
    @Test("Dictionary includes formatted ETH values")
    func testDictionaryFormattedValues() {
        // Given: Simple gas calculation
        let gasLimit = BigUInt(21_000)
        let maxFeePerGas = BigUInt(20_000_000_000) // 20 gwei
        let txValue = BigUInt(0)
        
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: BigUInt(1_000_000_000),
            isEIP1559: true
        )
        
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: gasLimit,
            gasPrices: gasPrices,
            transactionValue: txValue,
            transactionType: .legacy
        )
        
        // When: Converting to dictionary
        let dict = estimate.toDictionary()
        
        // Then: Verify formatted values are present
        let gasCostEth = dict["estimatedGasCostEth"] as? String
        let totalCostEth = dict["totalCostEth"] as? String
        
        #expect(gasCostEth != nil)
        #expect(totalCostEth != nil)
        #expect(gasCostEth == "0.000420") // 21,000 * 20 gwei = 0.00042 ETH
    }
    
    // MARK: - BigUInt Helper Extension Tests
    
    @Test("BigUInt.fromHexQuantity parses hex with 0x prefix")
    func testHexQuantityWith0x() {
        // Given: Hex string with 0x prefix
        let hex = "0x1234"
        
        // When: Parsing
        let result = BigUInt.fromHexQuantity(hex)
        
        // Then: Should parse correctly
        #expect(result == BigUInt(4660)) // 0x1234 = 4660
    }
    
    @Test("BigUInt.fromHexQuantity parses hex without 0x prefix")
    func testHexQuantityWithout0x() {
        // Given: Hex string without 0x prefix
        let hex = "1234"
        
        // When: Parsing
        let result = BigUInt.fromHexQuantity(hex)
        
        // Then: Should parse correctly
        #expect(result == BigUInt(4660))
    }
    
    @Test("BigUInt.fromHexQuantity handles empty string")
    func testHexQuantityEmpty() {
        // Given: Empty string
        let hex = ""
        
        // When: Parsing
        let result = BigUInt.fromHexQuantity(hex)
        
        // Then: Should return nil
        #expect(result == nil)
    }
    
    @Test("BigUInt.fromHexQuantity handles large values")
    func testHexQuantityLargeValue() {
        // Given: Large hex value (1 ETH in wei)
        let hex = "0xde0b6b3a7640000" // 1 ETH = 10^18 wei
        
        // When: Parsing
        let result = BigUInt.fromHexQuantity(hex)
        
        // Then: Should parse correctly
        #expect(result == BigUInt("1000000000000000000"))
    }
    
    @Test("BigUInt.fromHexQuantity handles invalid hex")
    func testHexQuantityInvalid() {
        // Given: Invalid hex string
        let hex = "0xGHIJ"
        
        // When: Parsing
        let result = BigUInt.fromHexQuantity(hex)
        
        // Then: Should return nil
        #expect(result == nil)
    }
    
    // MARK: - Integration Tests (Combined Operations)
    
    @Test("Complete flow: estimate buffer + EIP-7702 overhead + total cost")
    func testCompleteEIP7702Flow() {
        // Given: Base gas estimate with EIP-7702 transaction
        let baseEstimate = BigUInt(80_000)
        
        // When: Applying buffer
        let bufferedGas = GasEstimationUtil.applyGasBuffer(to: baseEstimate)
        
        // When: Applying EIP-7702 overhead
        let finalGasLimit = GasEstimationUtil.applyEIP7702Overhead(
            to: bufferedGas,
            authorizationCount: 1,
            includeSafetyMargin: true
        )
        
        // When: Calculating total cost
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: BigUInt(30_000_000_000), // 30 gwei
            maxPriorityFeePerGas: BigUInt(2_000_000_000), // 2 gwei
            isEIP1559: true
        )
        
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: finalGasLimit,
            gasPrices: gasPrices,
            transactionValue: BigUInt(0),
            transactionType: .eip7702
        )
        
        // Then: Verify complete calculation
        // Buffer: 80,000 + 16,000 (20%) = 96,000
        // EIP-7702: 96,000 + 66,000 = 162,000
        #expect(bufferedGas == BigUInt(96_000))
        #expect(finalGasLimit == BigUInt(162_000))
        #expect(estimate.type == .eip7702)
        #expect(estimate.gasLimit == finalGasLimit)
    }
    
    @Test("Complete flow: buffer + cost calculation for regular transaction")
    func testCompleteRegularFlow() {
        // Given: Regular transaction estimate
        let baseEstimate = BigUInt(45_000)
        
        // When: Applying buffer
        let finalGasLimit = GasEstimationUtil.applyGasBuffer(to: baseEstimate)
        
        // When: Calculating total cost
        let gasPrices = GasEstimationUtil.GasPrices(
            maxFeePerGas: BigUInt(25_000_000_000), // 25 gwei
            maxPriorityFeePerGas: BigUInt(1_500_000_000), // 1.5 gwei
            isEIP1559: true
        )
        
        let txValue = BigUInt(500_000_000_000_000_000) // 0.5 ETH
        
        let estimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: finalGasLimit,
            gasPrices: gasPrices,
            transactionValue: txValue,
            transactionType: .eip1559
        )
        
        // Then: Verify complete calculation
        // Buffer: 45,000 + 9,000 (20%) = 54,000
        #expect(finalGasLimit == BigUInt(54_000))
        #expect(estimate.gasLimit == BigUInt(54_000))
        #expect(estimate.type == .eip1559)
        
        // Verify dictionary conversion works
        let dict = estimate.toDictionary()
        #expect(dict["type"] as? String == "eip1559")
        #expect(dict["totalCostEth"] != nil)
    }
}

