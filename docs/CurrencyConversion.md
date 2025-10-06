# Currency Conversion

## Overview

This document specifies the implementation of currency conversion support for displaying ETH values alongside their USD equivalents. The system fetches real-time ETH/USD exchange rates from Chainlink's price oracle on Ethereum mainnet and provides a consistent currency display across the iOS app and web extension UI.

## Goals

1. **Real-time pricing**: Fetch current ETH/USD exchange rates from a reliable on-chain oracle
2. **Consistent display**: Show USD equivalents for all ETH values across app and extension
3. **Performance**: Cache exchange rates to minimize RPC calls (5-minute cache)
4. **Graceful degradation**: App functions normally if price fetch fails
5. **User experience**: Display USD as tooltips in web UI, inline in iOS app

## Architecture

### Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                     Chainlink Oracle                         │
│         ETH/USD Price Feed (Ethereum Mainnet)               │
│         Address: 0x986b5E1e1755e3C2440e960477f25201B0a8bbD4 │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ latestRoundData()
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    CurrencyService.swift                     │
│              • Fetches price from oracle                     │
│              • Caches for 5 minutes                          │
│              • Handles errors gracefully                     │
└─────────────────────────────────────────────────────────────┘
                           │
                           │
        ┌──────────────────┴──────────────────┐
        │                                     │
        ▼                                     ▼
┌──────────────────┐              ┌──────────────────────┐
│  iOS App Views   │              │ Safari Extension RPC  │
│  • ContentView   │              │ stupid_getBaseCurrency│
│  • BalancesView  │              └──────────────────────┘
└──────────────────┘                         │
                                             │
                                             ▼
                                  ┌──────────────────────┐
                                  │  Web UI Components   │
                                  │  • useBaseCurrency   │
                                  │  • EthValue          │
                                  │  • SendTxModal       │
                                  │  • CallDecoder       │
                                  └──────────────────────┘
```

## Phase 1: Backend Implementation (Swift)

### 1.1 CurrencyService

**Location**: `ios-wallet/shared/CurrencyService.swift`

**Purpose**: Centralized service for fetching and caching ETH/USD exchange rates from Chainlink oracle.

#### Implementation Details

```swift
import Foundation
import Web3
import Web3PromiseKit
import PromiseKit
import BigInt

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
        let functionSelector = Data(functionSignature.data(using: .utf8)!.sha3(.keccak256).prefix(4))

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

        // Chainlink ETH/USD feed returns price with 8 decimals
        // Convert to Double: price = answer / 10^8
        let divisor = BigInt(10).power(8)
        let price = Double(answer) / Double(divisor)

        // Validate price is reasonable (between $100 and $100,000)
        guard price > 100 && price < 100_000 else {
            throw NSError(domain: "CurrencyService", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Oracle price out of reasonable range: \(price)"])
        }

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
```

### 1.2 Safari Extension RPC Handler

**Location**: `ios-wallet/safari/SafariWebExtensionHandler.swift`

#### Add Method to Switch Statement

In `handleWalletRequest()` method, add after line 176:

```swift
case "stupid_getBaseCurrency":
  return await handleGetBaseCurrency()
```

#### Add Handler Method

Add before the closing brace of the class:

```swift
private func handleGetBaseCurrency() async -> [String: Any] {
    do {
        let rate = try await CurrencyService.shared.fetchEthUsdPrice()
        let timestamp = ISO8601DateFormatter().string(from: Date())

        return [
            "result": [
                "symbol": "USD",
                "rate": rate,
                "timestamp": timestamp
            ]
        ]
    } catch {
        logger.error("Failed to fetch currency rate: \(error.localizedDescription, privacy: .public)")
        return ["error": "Failed to fetch currency rate: \(error.localizedDescription)"]
    }
}
```

### 1.3 Implementation Notes (Phase 1)

- **Function selector (keccak256)**:

  - Hashes the UTF‑8 function signature `"latestRoundData()"` using CryptoSwift `sha3(.keccak256)`.
  - Extracts the first 4 bytes via `Array(hash.prefix(4))` and wraps in `Data` to avoid Swift's “Ambiguous use of 'prefix'” error.
  - Builds a raw `EthereumCall` for a lightweight view call without full ABI definitions.

- **Decoding and validation**:

  - Decodes the return bytes manually; reads `answer` (int256) at bytes 32–64.
  - Converts to `BigInt` then `Double`, dividing by 10^8 (Chainlink decimals).
  - Validates the resulting USD price is within $100–$100,000; otherwise throws.

- **Caching**:

  - In‑memory cache in `CurrencyService` with a 5‑minute TTL; `clearCache()` invalidates.
  - Prevents unnecessary RPC calls during a session.

- **Networking**:

  - Uses public Ethereum mainnet RPC: `https://eth.llamarpc.com` for read‑only calls.

- **Safari RPC handler**:
  - Adds `"stupid_getBaseCurrency"` to the request switch; handled as a fast method (no user confirmation).
  - `handleGetBaseCurrency()` returns `{ symbol: "USD", rate, timestamp }` on success.
  - Errors are logged using `Logger(subsystem:..., category:...)` with `privacy: .public` and returned as `{ error }` without sensitive data.

## Phase 2: Frontend Implementation (React/TypeScript)

### 2.1 Type Definitions

**Location**: `web-ui/src/lib/types.ts`

Add to existing types:

```typescript
export interface BaseCurrency {
  symbol: string;
  rate: number;
  timestamp: string;
}
```

### 2.2 React Query Hook

**Location**: `web-ui/src/hooks/use-base-currency.ts` (new file)

```typescript
import { useQuery } from "@tanstack/react-query";
import type { BaseCurrency } from "@/lib/types";

/**
 * Hook to fetch and cache base currency (USD) exchange rate for ETH
 *
 * Features:
 * - Fetches from stupid_getBaseCurrency RPC method
 * - Caches for 5 minutes to minimize RPC calls
 * - Auto-refreshes every 5 minutes
 * - Retries twice on failure
 *
 * @returns React Query result with BaseCurrency data
 */
export function useBaseCurrency() {
  return useQuery({
    queryKey: ["baseCurrency"],
    queryFn: async () => {
      const { result }: { result: BaseCurrency } =
        await browser.runtime.sendMessage({
          type: "WALLET_REQUEST",
          method: "stupid_getBaseCurrency",
          params: [],
        });
      return result;
    },
    staleTime: 5 * 60 * 1000, // 5 minutes
    refetchInterval: 5 * 60 * 1000, // Auto-refresh every 5 minutes
    retry: 2,
  });
}
```

### 2.3 EthValue Component

**Location**: `web-ui/src/components/EthValue.tsx` (new file)

**Purpose**: Reusable component that displays ETH values with USD tooltip on hover.

#### Prerequisites

Install shadcn/ui Tooltip component:

```bash
cd web-ui
bun x shadcn-ui@latest add tooltip
```

#### Implementation

```typescript
import { formatValue } from "@/lib/utils";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { useBaseCurrency } from "@/hooks/use-base-currency";

interface EthValueProps {
  /** ETH amount as string (e.g., "1.234567") */
  value: string;
  /** Whether to show "ETH" symbol after the value */
  showSymbol?: boolean;
  /** Additional CSS classes */
  className?: string;
}

/**
 * Displays an ETH value with a USD tooltip on hover
 *
 * @example
 * <EthValue value="1.234567" />
 * // Displays: 1.234567 ETH
 * // Tooltip on hover: $2,469.13
 *
 * @example
 * <EthValue value="0.05" showSymbol={false} />
 * // Displays: 0.05 (no tooltip if exchange rate unavailable)
 */
export function EthValue({
  value,
  showSymbol = true,
  className,
}: EthValueProps) {
  const { data: currency, isLoading } = useBaseCurrency();

  const ethValue = parseFloat(value);
  const usdValue =
    currency && !isNaN(ethValue) ? ethValue * currency.rate : null;
  const formattedUsd =
    usdValue !== null
      ? new Intl.NumberFormat("en-US", {
          style: "currency",
          currency: "USD",
          minimumFractionDigits: 2,
          maximumFractionDigits: 2,
        }).format(usdValue)
      : null;

  // If no currency data available, just show ETH value without tooltip
  if (!formattedUsd) {
    return (
      <span className={className}>
        {value} {showSymbol && "ETH"}
      </span>
    );
  }

  return (
    <TooltipProvider>
      <Tooltip>
        <TooltipTrigger asChild>
          <span className={className}>
            {value} {showSymbol && "ETH"}
          </span>
        </TooltipTrigger>
        <TooltipContent>
          <p className="text-xs">{formattedUsd}</p>
        </TooltipContent>
      </Tooltip>
    </TooltipProvider>
  );
}
```

## Phase 3: Web UI Updates

### 3.1 SendTxModal Component

**Location**: `web-ui/src/components/SendTxModal.tsx`

#### Add Import

Add to imports at top of file:

```typescript
import { EthValue } from "@/components/EthValue";
```

#### Update Line 305 (Value Display)

Replace:

```typescript
<div className="text-sm">{totalValueEth} ETH</div>
```

With:

```typescript
<div className="text-sm">
  <EthValue value={totalValueEth} />
</div>
```

#### Update Line 315 (Network Fee Display)

Replace:

```typescript
<>{gasEstimation.estimatedGasCostEth} ETH</>
```

With:

```typescript
<EthValue value={gasEstimation.estimatedGasCostEth} />
```

### 3.2 CallDecoder Component

**Location**: `web-ui/src/components/CallDecoder.tsx`

#### Add Import

Add to imports at top of file:

```typescript
import { EthValue } from "@/components/EthValue";
```

#### Update Line 252 (Simplified View Value Display)

Replace:

```typescript
<span className="font-medium text-sm inline-flex items-center">
  {valueEth} ETH
</span>
```

With:

```typescript
<span className="font-medium text-sm inline-flex items-center">
  <EthValue value={valueEth} />
</span>
```

#### Update Line 282 (Full View Value Display)

Replace:

```typescript
<div>{valueEth} ETH</div>
```

With:

```typescript
<div>
  <EthValue value={valueEth} />
</div>
```

## Phase 4: iOS App UI Updates

### 4.1 CurrencyViewModel

**Location**: `ios-wallet/ios-wallet/CurrencyViewModel.swift` (new file)

**Purpose**: View model for managing currency state in SwiftUI views.

```swift
import SwiftUI
import BigInt

/// View model for currency conversion display in iOS app
@MainActor
final class CurrencyViewModel: ObservableObject {
    @Published var ethUsdRate: Double?
    @Published var isLoading: Bool = false
    @Published var lastUpdated: Date?
    @Published var error: String?

    /// Refreshes the ETH/USD exchange rate from Chainlink oracle
    func refreshRate() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let rate = try await CurrencyService.shared.fetchEthUsdPrice()
            ethUsdRate = rate
            lastUpdated = Date()
        } catch {
            self.error = error.localizedDescription
            // Silent failure - just don't show USD
        }
    }

    /// Formats a wei amount as USD currency string
    /// - Parameter ethAmount: Amount in wei (1e18 wei = 1 ETH)
    /// - Returns: Formatted USD string (e.g., "$1,234.56") or nil if rate unavailable
    func formatUsd(_ ethAmount: BigUInt) -> String? {
        guard let rate = ethUsdRate else { return nil }

        let divisor = BigUInt(1_000_000_000_000_000_000)
        let ethValue = Double(ethAmount) / Double(divisor)
        let usdValue = ethValue * rate

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2

        return formatter.string(from: NSNumber(value: usdValue))
    }

    /// Clears cached rate and forces refresh on next call
    func clearCache() {
        ethUsdRate = nil
        lastUpdated = nil
        error = nil
        CurrencyService.shared.clearCache()
    }
}
```

### 4.2 ContentView Updates

**Location**: `ios-wallet/ios-wallet/ContentView.swift`

#### Add ViewModel Property

Add after line 15 (after `@State private var showSettingsSheet = false`):

```swift
@StateObject private var currencyVM = CurrencyViewModel()
```

#### Update Refresh Task

Add to the `walletView`'s refreshable block (after line 214):

```swift
.refreshable {
    await vm.refreshAllBalances()
    await vm.resolveENS()
    await currencyVM.refreshRate()  // Add this line
}
```

#### Add Initial Load Task

Add after the `.refreshable` modifier:

```swift
.task {
    await currencyVM.refreshRate()
}
```

#### Update Total Balance Display

Replace the balance menu label content (around lines 166-182) with:

```swift
label: {
    HStack(alignment: .center, spacing: 8) {
        if NetworkUtils.areIncludedBalancesLoading(balances: vm.balances) {
            ProgressView()
                .scaleEffect(1.0)
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                Text("♦ \(totalEthDisplay())")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .allowsTightening(true)

                if let usd = currencyVM.formatUsd(vm.totalBalanceIncludingOnlyEnabled()) {
                    Text(usd)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        Image(systemName: "chevron.down")
            .foregroundColor(.secondary)
    }
}
```

### 4.3 BalancesView Updates

**Location**: `ios-wallet/ios-wallet/BalancesView.swift`

#### Add ViewModel Property

Add after line 5 (after `@ObservedObject var vm: WalletViewModel`):

```swift
@StateObject private var currencyVM = CurrencyViewModel()
```

#### Add Initial Load Task

Add to the List view (after line 36, before closing brace):

```swift
.task {
    await currencyVM.refreshRate()
}
```

#### Update Refresh Task

Replace the `.refreshable` block (line 33-35) with:

```swift
.refreshable {
    await vm.refreshAllBalances()
    await currencyVM.refreshRate()
}
```

#### Update Balance Display

Replace the balance row content (lines 21-26) with:

```swift
HStack {
    Text(net.name)
    Spacer()
    VStack(alignment: .trailing, spacing: 2) {
        Text(vm.formatBalanceForDisplay(vm.balances[chainIdHex] ?? nil))
            .font(.system(.footnote, design: .monospaced))

        if let balance = vm.balances[chainIdHex],
           let bal = balance,
           let usd = currencyVM.formatUsd(bal) {
            Text(usd)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
```

## Implementation Notes

### Chainlink Oracle Details

- **Contract Address**: `0x986b5E1e1755e3C2440e960477f25201B0a8bbD4`
- **Network**: Ethereum Mainnet
- **Price Feed**: ETH/USD
- **Decimals**: 8 (price returned as int256 with 8 decimal places)
- **Method**: `latestRoundData()` returns `(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)`
- **Update Frequency**: Chainlink oracles typically update when price deviates >0.5% or every hour
- **Documentation**: https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum

### Caching Strategy

**Purpose**: Minimize RPC calls to oracle while maintaining reasonable freshness.

**Implementation**:

- Cache duration: 5 minutes
- Cache location: In-memory in `CurrencyService` (Swift) and React Query cache (Web UI)
- Cache invalidation: Automatic after 5 minutes, or manual via `clearCache()`
- Auto-refresh: React Query automatically refetches every 5 minutes in web UI

**Rationale**:

- Chainlink oracle updates when price moves >0.5% or hourly
- 5-minute cache balances freshness vs. RPC cost
- Most user sessions are short (<5 minutes per transaction)
- For longer sessions, auto-refresh keeps data current

### Error Handling

**Graceful Degradation**: If exchange rate fetch fails, app functions normally but USD values are simply not displayed.

**Error Scenarios**:

1. **RPC failure**: Network issue, RPC endpoint down

   - Swift: Returns error in RPC response
   - React: useBaseCurrency returns undefined data
   - UI: Shows only ETH values (no tooltip/USD line)

2. **Oracle response invalid**: Malformed data from oracle

   - Swift: Throws error, caught in handler
   - React: Query marked as error, data remains undefined
   - UI: Shows only ETH values

3. **Price out of range**: Oracle returns unreasonable price
   - Swift: Validates price is between $100-$100,000
   - Throws error if outside range
   - UI: Shows only ETH values

**Logging**: Swift errors logged via OSLog with public privacy level (no sensitive data).

### Performance Considerations

**RPC Call Frequency**:

- Initial load: 1 call when app/extension opens
- Subsequent: 1 call every 5 minutes if app remains open
- User-initiated refresh: Respects cache, doesn't force refresh

**Impact on UX**:

- Non-blocking: Currency fetch happens asynchronously
- Progressive enhancement: ETH values shown immediately, USD appears when available
- No loading states: App functions normally without USD data

**Network Usage**:

- Oracle call: ~300 bytes request + ~500 bytes response
- Frequency: Max 12 calls/hour if app remains open
- Cost: Negligible on modern connections

## Testing Strategy

### Unit Tests

**Swift (CurrencyService)**:

- ✓ Fetch returns valid price in reasonable range
- ✓ Cache returns same value within 5 minutes
- ✓ Cache expires after 5 minutes
- ✓ Invalid oracle response throws error
- ✓ Price out of range throws error

**TypeScript (useBaseCurrency)**:

- ✓ Hook fetches and caches data correctly
- ✓ Hook respects 5-minute stale time
- ✓ Hook auto-refetches every 5 minutes
- ✓ Hook retries twice on failure

**TypeScript (EthValue)**:

- ✓ Renders ETH value correctly
- ✓ Shows tooltip with USD when rate available
- ✓ Hides tooltip when rate unavailable
- ✓ Formats USD with 2 decimal places
- ✓ Handles zero and very small values

### Integration Tests

**Safari Extension**:

- ✓ `stupid_getBaseCurrency` RPC method works from background script
- ✓ Response includes symbol, rate, timestamp
- ✓ Error response when oracle fails
- ✓ Multiple rapid calls use cache

**Web UI**:

- ✓ SendTxModal displays USD tooltip for value
- ✓ SendTxModal displays USD tooltip for gas fee
- ✓ CallDecoder displays USD in simplified view
- ✓ CallDecoder displays USD in full view
- ✓ Tooltips appear on hover
- ✓ App works when rate unavailable

**iOS App**:

- ✓ ContentView shows USD below total balance
- ✓ BalancesView shows USD for each network
- ✓ Pull-to-refresh updates currency rate
- ✓ App works when rate unavailable
- ✓ Currency updates after 5 minutes

### Manual Testing Checklist

- [ ] Verify Chainlink oracle call on Ethereum mainnet succeeds
- [ ] Confirm price is reasonable (matches current market rate)
- [ ] Test cache: rapid calls return same value
- [ ] Test cache expiry: wait 5+ minutes, verify new fetch
- [ ] Test RPC method from extension background script
- [ ] Test web UI tooltips appear on hover
- [ ] Test iOS app shows USD inline
- [ ] Test graceful degradation: disconnect network, verify app works
- [ ] Test auto-refresh: keep app open 5+ minutes, verify rate updates
- [ ] Test pull-to-refresh updates rate immediately
- [ ] Verify no performance impact on transaction flows
- [ ] Check console for errors when rate unavailable

## Security Considerations

### Oracle Trust

**Chainlink Oracle**: Widely trusted, decentralized price feed used by major DeFi protocols.

- Multiple data sources aggregated
- On-chain verification
- Well-established track record

**Risk Mitigation**:

- Price validation: Reject values outside $100-$100,000 range
- Read-only: Only calling view function, no transactions
- No financial impact: Display-only feature, not used for transaction values

### RPC Endpoint

**Ethereum Mainnet RPC**: Uses public RPC endpoint (eth.llamarpc.com).

- Read-only calls
- No authentication required
- No sensitive data transmitted

**Considerations**:

- Rate limiting: 5-minute cache minimizes calls
- Fallback: If endpoint fails, app continues normally
- Privacy: No user data sent to RPC

### User Privacy

**No Tracking**:

- Currency rate is global data (same for all users)
- No user-specific information in requests
- No analytics or tracking

**Local Processing**:

- Conversion calculations done client-side
- No user balances sent to external services

## Future Enhancements

### Multi-Currency Support

**Potential Additions**:

- EUR, GBP, JPY, CNY, etc.
- User preference selection
- Additional Chainlink oracles for each pair

**Implementation**:

- Extend `BaseCurrency` type to include currency code
- Add user preference in Settings
- Fetch appropriate oracle based on preference

### Token Price Support

**ERC-20 Tokens**:

- Fetch prices for common ERC-20 tokens
- Display USD values for token balances
- Use Chainlink token price feeds

**Implementation Complexity**: Higher

- Need token → USD price feeds for each supported token
- Fallback to DEX prices (Uniswap) for unsupported tokens
- More complex caching strategy

### Historical Price Data

**Use Cases**:

- Show USD value at time of transaction
- Portfolio performance tracking
- Price charts

**Implementation**: Requires price history storage

- Archive prices for past transactions
- Query historical prices from oracle or external API

### Offline Support

**Enhancement**: Cache last known rate for offline display

- Store in UserDefaults/localStorage
- Show "last updated" timestamp
- Clear indicator that data may be stale

## File Summary

### New Files Created (5)

1. `ios-wallet/shared/CurrencyService.swift` - Chainlink oracle integration
2. `ios-wallet/ios-wallet/CurrencyViewModel.swift` - SwiftUI currency state management
3. `web-ui/src/hooks/use-base-currency.ts` - React Query hook
4. `web-ui/src/components/EthValue.tsx` - Reusable ETH+USD display component
5. `web-ui/src/components/ui/tooltip.tsx` - shadcn/ui Tooltip (via CLI generator)

### Files Modified (7)

1. `ios-wallet/safari/SafariWebExtensionHandler.swift`

   - Line 176: Add case for `stupid_getBaseCurrency`
   - End of class: Add `handleGetBaseCurrency()` method

2. `web-ui/src/lib/types.ts`

   - Add `BaseCurrency` interface

3. `web-ui/src/components/SendTxModal.tsx`

   - Add import for `EthValue`
   - Line 305: Replace ETH value display
   - Line 315: Replace gas fee display

4. `web-ui/src/components/CallDecoder.tsx`

   - Add import for `EthValue`
   - Line 252: Replace simplified view value display
   - Line 282: Replace full view value display

5. `ios-wallet/ios-wallet/ContentView.swift`

   - Add `@StateObject` for `CurrencyViewModel`
   - Update refresh task to include currency rate
   - Add initial load task for currency rate
   - Update total balance display to show USD

6. `ios-wallet/ios-wallet/BalancesView.swift`

   - Add `@StateObject` for `CurrencyViewModel`
   - Add initial load task for currency rate
   - Update refresh task to include currency rate
   - Update balance display to show USD per network

7. `ios-wallet/web-ui/package.json` (implied by shadcn/ui installation)
   - Dependencies updated when installing Tooltip component

## Conclusion

This implementation provides comprehensive currency conversion support across the entire stupid wallet app and extension. The design prioritizes:

1. **User Experience**: Seamless USD display without impacting core functionality
2. **Performance**: Minimal RPC overhead via intelligent caching
3. **Reliability**: Graceful degradation when exchange rate unavailable
4. **Maintainability**: Centralized service and reusable components

The system is ready for future expansion to support additional currencies and tokens as needed.
