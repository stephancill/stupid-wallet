# Gas Estimation Exposure Plan

## Overview

Expose gas cost estimation to `SendTxModal.tsx` via a new internal RPC method `stupid_estimateTransaction`. This plan includes centralizing all gas estimation logic into a reusable utility to ensure consistency across all transaction flows.

---

## Phase 1: Centralize Gas Estimation Utility (Swift)

### Create New Utility File: `shared/GasEstimationUtil.swift`

**Purpose:** Centralize all gas estimation logic to ensure consistency across:

- Regular transactions (`eth_sendTransaction`)
- Batch calls (`wallet_sendCalls`)
- EIP-7702 authorization transactions (`AuthorizationsUtil`)
- New estimation endpoint (`stupid_estimateTransaction`)

**Key Components:**

#### 1.1 Gas Limit Estimation with Buffer

```swift
enum GasEstimationUtil {
    /// Standard buffer calculation for gas estimates
    /// Uses 20% buffer or minimum 1,500 gas, whichever is larger
    static func applyGasBuffer(to estimate: BigUInt) -> BigUInt {
        let buffer = max(estimate / BigUInt(5), BigUInt(1_500))
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
    ) async -> Result<BigUInt, Error> {
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
}
```

#### 1.2 EIP-7702 Overhead Calculation

```swift
extension GasEstimationUtil {
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
}
```

#### 1.3 Gas Price Fetching (Legacy & EIP-1559)

```swift
extension GasEstimationUtil {
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
    ) async -> Result<GasPrices, Error> {
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
    ) async -> Result<GasPrices, Error> {
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
        return await fetchGasPrices(web3: web3)
    }
}
```

#### 1.4 Total Cost Calculation

```swift
extension GasEstimationUtil {
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
```

#### 1.5 Helper Extension for String Padding

```swift
private extension String {
    func leftPadded(to length: Int) -> String {
        if count >= length { return self }
        return String(repeating: "0", count: length - count) + self
    }
}
```

---

## Phase 2: Refactor Existing Gas Estimation Code

### 2.1 Update `SafariWebExtensionHandler.swift` - `handleSendTransaction`

**Location:** Lines 657-727

**Before:**

```swift
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

// ... gas price logic (lines 694-712)

// Check if balance is sufficient for estimated transaction cost
let estimatedGasCost: BigUInt
let totalValue = weiValue
if let maxFee = BigUInt.fromHexQuantity(maxFeePerGasHex ?? ""),
   BigUInt.fromHexQuantity(maxPriorityFeePerGasHex ?? "") != nil {
    estimatedGasCost = gasLimitQty * maxFee
} else {
    let gasPrice = txToSign.gasPrice?.quantity ?? BigUInt.zero
    estimatedGasCost = gasLimitQty * gasPrice
}

let totalCost = estimatedGasCost + totalValue
```

**After:**

```swift
// Gas limit: provided or use estimation
let gasLimitQty: BigUInt
if let gasHex = gasHex, let g = BigUInt.fromHexQuantity(gasHex) {
    gasLimitQty = g
} else {
    guard let toForEstimate = toAddr else {
        return ["error": "Missing 'to' address"]
    }

    let estimateResult = await GasEstimationUtil.estimateGasLimit(
        web3: web3,
        from: fromAddr,
        to: toForEstimate,
        value: weiValue,
        data: transactionData
    )

    switch estimateResult {
    case .success(let estimate):
        gasLimitQty = estimate
    case .failure(let error):
        return ["error": "Failed to estimate gas: \(error.localizedDescription)"]
    }
}

// Fetch gas prices
let gasPricesResult = await GasEstimationUtil.getGasPrices(
    web3: web3,
    maxFeePerGasHex: maxFeePerGasHex,
    maxPriorityFeePerGasHex: maxPriorityFeePerGasHex,
    gasPriceHex: gasPriceHex
)

let gasPrices: GasEstimationUtil.GasPrices
switch gasPricesResult {
case .success(let prices):
    gasPrices = prices
case .failure(let error):
    return ["error": "Failed to get gas price: \(error.localizedDescription)"]
}

// Calculate total cost
let gasEstimate = GasEstimationUtil.calculateTotalCost(
    gasLimit: gasLimitQty,
    gasPrices: gasPrices,
    transactionValue: weiValue,
    transactionType: .eip1559
)

let totalCost = gasEstimate.totalCost
```

### 2.2 Update `SafariWebExtensionHandler.swift` - `handleWalletSendCalls`

**Location:** Lines 1620-1668

**Before:**

```swift
// Get gas price (simplified - using legacy gas price for now)
switch awaitPromise(web3.eth.gasPrice()) {
case .success(let gp):
    maxFeePerGas = gp
    let twoGwei = BigUInt(2_000_000_000)
    let half = gp.quantity / 2
    maxPriorityFeePerGasQty = half < twoGwei ? half : twoGwei
case .failure(let err):
    throw NSError(...)
}

// Estimate gas
var gasLimit: EthereumQuantity
let estimate = awaitPromise(web3.eth.estimateGas(...))
switch estimate {
case .success(let est):
    gasLimit = est
case .failure(let err):
    throw NSError(...)
}

// Add intrinsic overhead for EIP-7702
if needsDelegation {
    let authOverhead = BigUInt(25_000)
    let baseOverhead = BigUInt(21_000)
    let safetyMargin = BigUInt(50_000)
    let newLimit = gasLimit.quantity + authOverhead + baseOverhead + safetyMargin
    gasLimit = EthereumQuantity(quantity: newLimit)
}

let estimatedGasCost = gasLimit.quantity * maxFeePerGas.quantity
```

**After:**

```swift
// Fetch gas prices
let gasPricesResult = await GasEstimationUtil.fetchGasPrices(web3: web3)
guard case .success(let gasPrices) = gasPricesResult else {
    throw NSError(domain: "Transaction", code: 2,
                  userInfo: [NSLocalizedDescriptionKey: "Failed to get gas price"])
}

// Estimate gas
let estimateResult = await GasEstimationUtil.estimateGasLimit(
    web3: web3,
    from: fromAddr,
    to: toAddr,
    value: BigUInt.zero,
    data: txData
)

guard case .success(var gasLimit) = estimateResult else {
    throw NSError(domain: "Transaction", code: 4,
                  userInfo: [NSLocalizedDescriptionKey: "Gas estimation failed"])
}

// Add EIP-7702 overhead if needed
if needsDelegation {
    gasLimit = GasEstimationUtil.applyEIP7702Overhead(
        to: gasLimit,
        authorizationCount: 1,
        includeSafetyMargin: true
    )
}

// Calculate total cost
let gasEstimate = GasEstimationUtil.calculateTotalCost(
    gasLimit: gasLimit,
    gasPrices: gasPrices,
    transactionValue: BigUInt.zero,
    transactionType: needsDelegation ? .eip7702 : .eip1559
)

let estimatedGasCost = gasEstimate.estimatedGasCost
```

### 2.3 Update `shared/AuthorizationsUtil.swift`

**Location:** Lines 158-198

**Before:**

```swift
// Estimate gas for the authorization transaction
let estimatedGasLimit: BigUInt
do {
    let dummyTx = EthereumCall(...)

    let estimateResult = awaitPromise(web3.eth.estimateGas(call: dummyTx), timeout: 15.0)
    switch estimateResult {
    case .success(let estimated):
        let authOverhead = BigUInt(25_000 * authorizations.count)
        let baseOverhead = BigUInt(21_000)
        let safetyMargin = BigUInt(20_000)
        estimatedGasLimit = estimated.quantity + authOverhead + baseOverhead + safetyMargin
    case .failure(let error):
        throw NSError(...)
    }
}

// Get current gas prices from the network
let gasPriceResult = awaitPromise(web3.eth.gasPrice())
let maxFeePerGas: BigUInt
let maxPriorityFeePerGas: BigUInt

switch gasPriceResult {
case .success(let gasPrice):
    let networkGasPrice = gasPrice.quantity
    maxFeePerGas = min(networkGasPrice * 2, BigUInt(100_000_000_000))
    maxPriorityFeePerGas = min(networkGasPrice / 2, BigUInt(2_000_000_000))
case .failure(let error):
    throw NSError(...)
}
```

**After:**

```swift
// Estimate gas with EIP-7702 overhead
let estimateResult = await GasEstimationUtil.estimateGasLimit(
    web3: web3,
    from: fromAddr,
    to: fromAddr, // Self-transaction
    value: BigUInt.zero,
    data: Data() // Empty data for estimation
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
let gasPricesResult = await GasEstimationUtil.fetchGasPrices(web3: web3)
guard case .success(let gasPrices) = gasPricesResult else {
    throw NSError(domain: "Authorization", code: 4,
                  userInfo: [NSLocalizedDescriptionKey: "Failed to get gas price"])
}
```

---

## Phase 3: Implement New RPC Method

### 3.1 Add Method Handler in `SafariWebExtensionHandler.swift`

**Location:** Add to method switch (around line 174)

```swift
case "stupid_estimateTransaction":
    let params = messageDict["params"] as? [Any]
    return await handleEstimateTransaction(params: params)
```

### 3.2 Implement Handler Function

```swift
private func handleEstimateTransaction(params: [Any]?) async -> [String: Any] {
    guard let params = params, !params.isEmpty else {
        return ["error": "Invalid params: expected transaction object or batch params"]
    }

    let firstParam = params[0]

    // Check if this is a batch call (wallet_sendCalls format)
    if let batchParams = firstParam as? [String: Any],
       let calls = batchParams["calls"] as? [[String: Any]] {
        return await estimateBatchTransaction(batchParams: batchParams, calls: calls)
    }

    // Otherwise treat as single transaction (eth_sendTransaction format)
    if let txParams = firstParam as? [String: Any] {
        return await estimateSingleTransaction(txParams: txParams)
    }

    return ["error": "Invalid params format"]
}

private func estimateSingleTransaction(txParams: [String: Any]) async -> [String: Any] {
    // Extract transaction parameters
    guard let fromHex = txParams["from"] as? String else {
        return ["error": "Missing 'from' address"]
    }

    let toHex = txParams["to"] as? String
    let valueHex = txParams["value"] as? String ?? "0x0"
    let dataHex = txParams["data"] as? String ?? txParams["input"] as? String ?? "0x"
    let gasHex = txParams["gas"] as? String
    let gasPriceHex = txParams["gasPrice"] as? String
    let maxFeePerGasHex = txParams["maxFeePerGas"] as? String
    let maxPriorityFeePerGasHex = txParams["maxPriorityFeePerGas"] as? String

    do {
        let (rpcURL, _) = Constants.Networks.currentNetwork()
        let web3 = Web3(rpcURL: rpcURL)

        let fromAddr = try EthereumAddress(hex: fromHex, eip55: false)
        let toAddr = (toHex != nil && !(toHex!).isEmpty)
            ? (try? EthereumAddress(hex: toHex!, eip55: false))
            : nil

        let weiValue = BigUInt.fromHexQuantity(valueHex) ?? BigUInt.zero

        let transactionData: EthereumData? = {
            guard dataHex != "0x", !dataHex.isEmpty else { return nil }
            guard let rawData = Data(hexString: dataHex) else { return nil }
            return try? EthereumData(rawData)
        }()

        // Gas limit: provided or estimate
        let gasLimitQty: BigUInt
        if let gasHex = gasHex, let g = BigUInt.fromHexQuantity(gasHex) {
            gasLimitQty = g
        } else {
            guard let toForEstimate = toAddr else {
                return ["error": "Missing 'to' address for gas estimation"]
            }

            let estimateResult = await GasEstimationUtil.estimateGasLimit(
                web3: web3,
                from: fromAddr,
                to: toForEstimate,
                value: weiValue,
                data: transactionData
            )

            switch estimateResult {
            case .success(let estimate):
                gasLimitQty = estimate
            case .failure(let error):
                return ["error": "Failed to estimate gas: \(error.localizedDescription)"]
            }
        }

        // Fetch gas prices
        let gasPricesResult = await GasEstimationUtil.getGasPrices(
            web3: web3,
            maxFeePerGasHex: maxFeePerGasHex,
            maxPriorityFeePerGasHex: maxPriorityFeePerGasHex,
            gasPriceHex: gasPriceHex
        )

        let gasPrices: GasEstimationUtil.GasPrices
        switch gasPricesResult {
        case .success(let prices):
            gasPrices = prices
        case .failure(let error):
            return ["error": "Failed to get gas price: \(error.localizedDescription)"]
        }

        // Calculate total cost
        let gasEstimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: gasLimitQty,
            gasPrices: gasPrices,
            transactionValue: weiValue,
            transactionType: gasPrices.isEIP1559 ? .eip1559 : .legacy
        )

        return ["result": gasEstimate.toDictionary()]

    } catch {
        return ["error": "Estimation failed: \(error.localizedDescription)"]
    }
}

private func estimateBatchTransaction(
    batchParams: [String: Any],
    calls: [[String: Any]]
) async -> [String: Any] {
    guard let fromAddress = batchParams["from"] as? String else {
        return ["error": "Missing 'from' address in batch params"]
    }

    do {
        let (rpcURL, chainIdBig) = Constants.Networks.currentNetwork()
        let web3 = Web3(rpcURL: rpcURL)

        let fromAddr = try EthereumAddress(hex: fromAddress, eip55: false)

        // For batch calls, we need to check if delegation is required
        let needsDelegation = await checkIfNeedsDelegation(
            fromAddress: fromAddress,
            chainId: chainIdBig
        )

        // Encode batch execution calldata (simplified - use first call for estimation)
        // In production, you'd want to encode all calls properly
        guard let firstCall = calls.first,
              let toHex = firstCall["to"] as? String else {
            return ["error": "Invalid batch call format"]
        }

        let toAddr = try EthereumAddress(hex: toHex, eip55: false)
        let dataHex = firstCall["data"] as? String ?? "0x"
        let txData = try EthereumData(Data(hexString: dataHex) ?? Data())

        // Estimate gas
        let estimateResult = await GasEstimationUtil.estimateGasLimit(
            web3: web3,
            from: fromAddr,
            to: toAddr,
            value: BigUInt.zero,
            data: txData
        )

        guard case .success(var gasLimit) = estimateResult else {
            return ["error": "Failed to estimate gas for batch transaction"]
        }

        // Add EIP-7702 overhead if needed
        if needsDelegation {
            gasLimit = GasEstimationUtil.applyEIP7702Overhead(
                to: gasLimit,
                authorizationCount: 1,
                includeSafetyMargin: true
            )
        }

        // Fetch gas prices
        let gasPricesResult = await GasEstimationUtil.fetchGasPrices(web3: web3)
        guard case .success(let gasPrices) = gasPricesResult else {
            return ["error": "Failed to get gas price"]
        }

        // Calculate total cost (batch calls typically don't transfer value)
        let gasEstimate = GasEstimationUtil.calculateTotalCost(
            gasLimit: gasLimit,
            gasPrices: gasPrices,
            transactionValue: BigUInt.zero,
            transactionType: needsDelegation ? .eip7702 : .eip1559
        )

        return ["result": gasEstimate.toDictionary()]

    } catch {
        return ["error": "Batch estimation failed: \(error.localizedDescription)"]
    }
}

// Helper to check if EIP-7702 delegation is needed
private func checkIfNeedsDelegation(
    fromAddress: String,
    chainId: BigUInt
) async -> Bool {
    let status = await AuthorizationsUtil.checkAuthorization(
        for: fromAddress,
        on: chainId
    )
    return !status.hasAuthorization
}
```

---

## Phase 4: Background Script Integration

### 4.1 Update `safari/Resources/background.js`

**Location:** Add to method switch (around line 175)

```javascript
case "stupid_estimateTransaction": {
  // No connection check needed - estimation only
  const native = await callNative({
    method,
    params,
    siteMetadata,
  });
  if (native && "result" in native)
    return sendResponse({ result: native.result });
  if (native && native.error)
    return sendResponse({ error: native.error });
  return sendResponse({ error: "Request failed" });
}
```

---

## Phase 5: Frontend Integration

### 5.1 Update Constants (`web-ui/src/lib/constants.ts`)

```typescript
export const FAST_METHODS = [
  "eth_accounts",
  "eth_chainId",
  "net_version",
  "eth_blockNumber",
  "eth_getTransactionByHash",
  "eth_getTransactionReceipt",
  "eth_getBlockByNumber",
  "wallet_addEthereumChain",
  "wallet_switchEthereumChain",
  "wallet_disconnect",
  "wallet_getCapabilities",
  "wallet_getCallsStatus",
  "stupid_estimateTransaction", // New method
] as const;
```

### 5.2 Create Type Definitions (`web-ui/src/lib/types.ts`)

```typescript
export interface GasEstimation {
  gasLimit: string; // hex
  maxFeePerGas: string; // hex
  maxPriorityFeePerGas: string; // hex
  estimatedGasCost: string; // hex (wei)
  estimatedGasCostEth: string; // decimal string
  totalCost: string; // hex (wei) - gas + value
  totalCostEth: string; // decimal string
  type: "legacy" | "eip1559" | "eip7702";
}
```

### 5.3 Update SendTxModal (`web-ui/src/components/SendTxModal.tsx`)

**Add React Query Hook:**

```typescript
import { GasEstimation } from "@/lib/types";

// Add after chainId query (around line 160)
const {
  data: gasEstimation,
  isLoading: isGasLoading,
  isError: isGasError,
} = useQuery({
  queryKey: ["gasEstimation", method, stringifyWithBigInt(params)],
  queryFn: async () => {
    const { result }: { result: GasEstimation } =
      await browser.runtime.sendMessage({
        type: "WALLET_REQUEST",
        method: "stupid_estimateTransaction",
        params: params,
      });
    return result;
  },
  enabled: !!chainId, // Only run after chainId is loaded
  retry: 1,
  staleTime: 10000, // 10 seconds
});
```

**Update Loading State:**

```typescript
const isAggregateLoading = isChainIdLoading || isNamesLoading || isGasLoading;
```

**Add Gas Display to UI (after line 284):**

```tsx
{/* Gas Estimation Section */}
<div className="text-sm text-muted-foreground">Estimated Gas</div>
<div className="text-sm">
  {isGasLoading ? (
    <span className="text-muted-foreground">Estimating...</span>
  ) : isGasError || !gasEstimation ? (
    <span className="text-muted-foreground">Unable to estimate</span>
  ) : (
    <>
      {gasEstimation.estimatedGasCostEth} ETH
      <span className="text-muted-foreground text-xs ml-1">
        ({gasEstimation.type})
      </span>
    </>
  )}
</div>

<div className="text-sm text-muted-foreground">Total Cost</div>
<div className="text-sm font-medium">
  {isGasLoading ? (
    <span className="text-muted-foreground">Calculating...</span>
  ) : isGasError || !gasEstimation ? (
    <span className="text-muted-foreground">
      {totalValueEth} ETH + gas
    </span>
  ) : (
    <>
      {gasEstimation.totalCostEth} ETH
      {gasEstimation.type === "eip7702" && (
        <span className="text-xs text-muted-foreground ml-1">
          (includes delegation)
        </span>
      )}
    </>
  )}
</div>
```

---

## Phase 6: Testing Checklist

### Unit Tests (Utility)

- [ ] Gas buffer calculation (20% or 1,500 gas minimum)
- [ ] EIP-7702 overhead calculation (25k per auth + 21k base + 20k safety)
- [ ] Gas price fetching (network call with caps)
- [ ] Total cost calculation (gas + value)
- [ ] Wei formatting to ETH string

### Integration Tests (RPC Method)

- [ ] Single legacy transaction (no gas params provided)
- [ ] Single EIP-1559 transaction (maxFeePerGas/maxPriorityFeePerGas)
- [ ] Single transaction with provided gas limit
- [ ] Batch calls without delegation
- [ ] Batch calls requiring EIP-7702 delegation
- [ ] Estimation with missing 'to' address (should fail)
- [ ] Estimation with invalid data (should fail gracefully)

### UI Tests (SendTxModal)

- [ ] Loading state displays while estimating
- [ ] Gas cost displays correctly for legacy tx
- [ ] Gas cost displays correctly for EIP-1559 tx
- [ ] Gas cost displays with EIP-7702 indicator for batch
- [ ] Error state displays when estimation fails
- [ ] Total cost includes transaction value + gas
- [ ] UI remains responsive during estimation
- [ ] Estimation updates when params change

### Refactoring Tests (Existing Flows)

- [ ] `eth_sendTransaction` still works (single tx)
- [ ] `wallet_sendCalls` still works (batch)
- [ ] Authorization transactions still work (EIP-7702)
- [ ] Gas costs match previous behavior
- [ ] All transaction types submit successfully

---

## Phase 7: Documentation Updates

### Update CONTRIBUTING.md

Add section under "Adding Features > EIP-1193 methods":

```markdown
**For Gas Estimation:**

All gas estimation should use the centralized `GasEstimationUtil`:

- `estimateGasLimit()` - Get gas limit with standard 20% buffer
- `fetchGasPrices()` - Get current network gas prices (EIP-1559 style)
- `applyEIP7702Overhead()` - Add overhead for authorization transactions
- `calculateTotalCost()` - Calculate total transaction cost (gas + value)

Never duplicate gas estimation logic. All transaction flows should use these utilities.
```

### Create New Doc (This File)

Save as `docs/GasEstimationExposure.md` for implementation reference.

---

## Benefits of This Approach

1. **Centralized Logic:** All gas estimation in one utility, easy to maintain
2. **Consistency:** Same buffers and calculations across all flows
3. **Reusability:** New features can use the utility immediately
4. **Testability:** Utility can be unit tested independently
5. **Type Safety:** Swift type system ensures correct usage
6. **Follows Patterns:** Uses `stupid_*` prefix for internal methods
7. **Fast Method:** No user interaction, immediate response
8. **Transparency:** Users see costs before approval
9. **Supports All Types:** Legacy, EIP-1559, and EIP-7702 transactions

---

## Migration Path

1. **Phase 1:** Create `GasEstimationUtil.swift` (new code, no risk)
2. **Phase 2:** Refactor existing methods one at a time (test after each)
3. **Phase 3-5:** Add new RPC method (additive, no breaking changes)
4. **Phase 6:** Comprehensive testing of all flows
5. **Phase 7:** Documentation updates

Each phase can be completed and tested independently.

---

## Estimated Implementation Time

- Phase 1 (Utility): 2-3 hours
- Phase 2 (Refactoring): 2-3 hours
- Phase 3 (New RPC): 1-2 hours
- Phase 4 (Background): 15 minutes
- Phase 5 (Frontend): 1-2 hours
- Phase 6 (Testing): 2-3 hours
- Phase 7 (Docs): 30 minutes

**Total: 9-14 hours**

---

## Future Enhancements

1. **Gas Price Oracles:** Integrate external gas price APIs for better estimates
2. **Gas Estimation Cache:** Cache recent estimates per chain
3. **Simulation API:** Use simulation services for more accurate estimates
4. **Multi-Call Aggregation:** Better batch call estimation using actual encoded data
5. **User Preferences:** Allow users to set gas price preferences (slow/fast/custom)
