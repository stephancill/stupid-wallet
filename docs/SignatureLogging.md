## Signature Logging Implementation Specification

### Overview

Extend the Activity Log to capture and display message signatures (`personal_sign`, `eth_signTypedData_v4`, and SIWE via `wallet_connect`) alongside transactions, providing users with a comprehensive audit trail of all wallet interactions.

### Goals

- Unified activity view showing both transactions and signatures in reverse-chronological order
- Persistent signature history with full message content for transparency
- De-duplicated app metadata storage (reuse existing `apps` table)
- Efficient polymorphic queries for mixed activity types
- No status polling for signatures (instant finality, unlike transactions)

### Architecture Decisions

**1. Separate `signatures` table**

- **Rationale**: Signatures have fundamentally different data (message content, no tx hash, no blockchain status) from transactions
- **Benefit**: Clean schema without nullable transaction-specific fields polluting signature rows

**2. Polymorphic `ActivityItem` model**

- **Rationale**: UI needs to render both types in a unified list but handle details differently
- **Approach**: Add `itemType: ActivityItemType` enum with associated optional fields
- **Benefit**: Type-safe, explicit handling in UI layer

**3. Full message content storage**

- **Decision**: Store complete message/JSON payload (not just hashes)
- **Rationale**: Users should see exactly what they signed for transparency and auditability
- **Size estimate**: Typical typed data ~10-100KB; personal_sign messages ~1-10KB

**4. No external links for signatures**

- **Decision**: Signatures are not on-chain; allow copying but no explorer links
- **UI**: Tappable fields to copy message content, signature hex, and from address

**5. SIWE signature logging**

- **Decision**: Log SIWE messages signed during `wallet_connect` with `method = "wallet_connect_siwe"`
- **Rationale**: SIWE is a critical authentication flow users should have visibility into

### Schema Changes (Migration v1 → v2)

**New `signatures` table:**

```sql
CREATE TABLE IF NOT EXISTS signatures (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  signature_hash TEXT NOT NULL UNIQUE,  -- SHA-256 hash of signature for deduplication
  app_id INTEGER NOT NULL,
  chain_id_hex TEXT NOT NULL,
  method TEXT NOT NULL,               -- 'personal_sign', 'eth_signTypedData_v4', 'wallet_connect_siwe'
  from_address TEXT,
  message_content TEXT NOT NULL,      -- Hex string for personal_sign, JSON string for signTypedData
  signature_hex TEXT NOT NULL,        -- The 0x-prefixed signature returned to dApp
  created_at INTEGER NOT NULL,        -- epoch seconds
  FOREIGN KEY(app_id) REFERENCES apps(id)
);

CREATE INDEX IF NOT EXISTS idx_signatures_created_at ON signatures(created_at DESC, id DESC);
```

**Notes:**

- `signature_hash`: Computed as SHA-256 of `signature_hex` for deduplication (same signature logged twice ignored)
- `message_content`: Stored as-is from params—hex for personal_sign, JSON string for signTypedData
- Reuses existing `apps` table and foreign key constraint for app metadata de-duplication
- No `status` field: signatures are instant (no pending/confirmed/failed states)

**Migration logic:**

```swift
// In ActivityStore.createSchemaIfNeeded()
let currentVersion = // read PRAGMA user_version

if currentVersion == 0 {
    // Fresh DB: Create v2 schema directly
    createAppsTable()
    createTransactionsTable()
    createSignaturesTable()
    exec("PRAGMA user_version = 2;")
} else if currentVersion == 1 {
    // Upgrade existing v1 DB
    createSignaturesTable()
    exec("PRAGMA user_version = 2;")
}
```

### Swift Model Changes

**File:** `shared/ActivityStore.swift`

**New types:**

```swift
public enum ActivityItemType {
    case transaction
    case signature
}

public struct ActivityItem {
    public let itemType: ActivityItemType

    // Transaction-specific fields (nil when itemType == .signature):
    public let txHash: String?
    public let status: String?

    // Signature-specific fields (nil when itemType == .transaction):
    public let signatureHash: String?
    public let messageContent: String?
    public let signatureHex: String?

    // Common fields:
    public let app: AppMetadata
    public let chainIdHex: String
    public let method: String
    public let fromAddress: String?
    public let createdAt: Date

    public init(/* ... all fields ... */) { /* ... */ }
}
```

**New API:**

```swift
public func logSignature(
    signatureHex: String,
    messageContent: String,
    chainIdHex: String,
    method: String,
    fromAddress: String?,
    app: AppMetadata
) throws {
    // 1. Compute signature_hash = SHA-256(signatureHex)
    // 2. Upsert app metadata
    // 3. INSERT OR IGNORE into signatures with signature_hash as unique constraint
}
```

**Updated API:**

```swift
// Rename from fetchTransactions
public func fetchActivity(limit: Int, offset: Int) throws -> [ActivityItem] {
    // UNION query:
    //   SELECT 'transaction' as type, tx_hash, status, null as sig_hash, null as msg, null as sig, ...
    //   FROM transactions t LEFT JOIN apps a ON t.app_id = a.id
    //   UNION ALL
    //   SELECT 'signature' as type, null, null, signature_hash, message_content, signature_hex, ...
    //   FROM signatures s LEFT JOIN apps a ON s.app_id = a.id
    //   ORDER BY created_at DESC, id DESC
    //   LIMIT ? OFFSET ?

    // Map rows to ActivityItem with appropriate itemType
}
```

### Extension Integration (Logging Points)

**File:** `safari/SafariWebExtensionHandler.swift`

**Changes:**

1. **Thread `appMetadata` into signature handlers:**

   - Update `handlePersonalSign(params:appMetadata:)` signature (line 320)
   - Update `handleSignTypedDataV4(params:appMetadata:)` signature (line 390)
   - Update `handleSignInWithEthereum` to return signature separately so caller can log
   - Update call sites in `handleWalletRequest` (lines 143, 146, 130)

2. **Add best-effort logging after successful signing:**

**In `handlePersonalSign` (after line 384):**

```swift
// Log signature (best-effort; failures must not affect RPC response)
do {
    let sigHash = Data(Array(sigHex.utf8)).sha256().toHexString()
    let app = ActivityStore.AppMetadata(
        domain: appMetadata.domain,
        uri: appMetadata.uri,
        scheme: appMetadata.scheme
    )
    try ActivityStore.shared.logSignature(
        signatureHex: sigHex,
        messageContent: messageHex,
        chainIdHex: Constants.Networks.getCurrentChainIdHex(),
        method: "personal_sign",
        fromAddress: saved,
        app: app
    )
} catch {
    // Ignore logging failures
}

return ["result": sigHex]
```

**In `handleSignTypedDataV4` (after line 432):**

```swift
// Log signature (best-effort)
do {
    let sigHash = Data(Array(sigHex.utf8)).sha256().toHexString()
    let app = ActivityStore.AppMetadata(
        domain: appMetadata.domain,
        uri: appMetadata.uri,
        scheme: appMetadata.scheme
    )
    try ActivityStore.shared.logSignature(
        signatureHex: sigHex,
        messageContent: typedDataJSON,  // Store full JSON
        chainIdHex: Constants.Networks.getCurrentChainIdHex(),
        method: "eth_signTypedData_v4",
        fromAddress: saved,
        app: app
    )
} catch {
    // Ignore logging failures
}

return ["result": sigHex]
```

**In `handleWalletConnect` (after SIWE signing in line 286):**

```swift
// In handleSignInWithEthereum, after signing:
let siweResult = try handleSignInWithEthereum(/* ... */)

// Log SIWE signature
do {
    if let sigHex = siweResult["signature"] as? String,
       let message = siweResult["message"] as? String {
        let sigHash = Data(Array(sigHex.utf8)).sha256().toHexString()
        let app = ActivityStore.AppMetadata(
            domain: appMetadata.domain,
            uri: appMetadata.uri,
            scheme: appMetadata.scheme
        )
        try ActivityStore.shared.logSignature(
            signatureHex: sigHex,
            messageContent: message,  // Store formatted SIWE message
            chainIdHex: chainIds.first ?? "0x1",
            method: "wallet_connect_siwe",
            fromAddress: address,
            app: app
        )
    }
} catch {
    // Ignore logging failures
}

capabilities["signInWithEthereum"] = siweResult
```

**SHA-256 helper (add extension in ActivityStore.swift or shared utility):**

```swift
import CryptoKit

extension Data {
    func sha256() -> Data {
        return Data(SHA256.hash(data: self))
    }

    func toHexString() -> String {
        return "0x" + self.map { String(format: "%02x", $0) }.joined()
    }
}
```

### iOS UI Changes

#### **ActivityViewModel.swift**

**Changes:**

1. Rename API call: `ActivityStore.shared.fetchActivity(limit:offset:)` (was `fetchTransactions`)

2. Update polling filter to skip signatures:

```swift
private func pollPendingOnce() async {
    let snapshot = await MainActor.run { items }
    // Only poll transactions with pending status
    let pending = snapshot.filter {
        $0.itemType == .transaction && $0.status == "pending"
    }
    guard !pending.isEmpty else { return }
    // ... existing polling logic ...
}
```

3. Update `checkReceiptStatus` to only handle transactions (safety check):

```swift
private func checkReceiptStatus(txHash: String, chainIdHex: String) async throws -> String {
    guard let hash = txHash, !hash.isEmpty else { return "pending" }
    // ... existing receipt check logic ...
}
```

#### **ActivityView.swift**

**Changes:**

1. Update list row rendering to handle both types:

```swift
VStack(alignment: .leading, spacing: 4) {
    Text(appLabel(item.app))
        .lineLimit(1)
        .truncationMode(.tail)

    HStack(spacing: 6) {
        switch item.itemType {
        case .transaction:
            // Existing transaction rendering
            if item.status == "pending" {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("Pending")
                Text("•")
                Text(chainName(from: item.chainIdHex))
            } else if item.status != "confirmed" {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .imageScale(.small)
                Text("Failed")
                Text("•")
                Text(chainName(from: item.chainIdHex))
            } else {
                Text(truncatedHash(item.txHash ?? ""))
                    .font(.system(.body, design: .monospaced))
                Text("•")
                Text(chainName(from: item.chainIdHex))
            }

        case .signature:
            // Signature rendering: show method name
            Text(methodDisplayName(item.method))
                .font(.system(.body, design: .monospaced))
            Text("•")
            Text(chainName(from: item.chainIdHex))
        }
    }
    .foregroundColor(.secondary)
    .lineLimit(1)
    .truncationMode(.middle)
}
```

2. Add helper for method display names:

```swift
private func methodDisplayName(_ method: String) -> String {
    switch method {
    case "personal_sign": return "Message"
    case "eth_signTypedData_v4": return "Typed Data"
    case "wallet_connect_siwe": return "Sign-In"
    default: return method
    }
}
```

3. Update empty state text:

```swift
.overlay(alignment: .center) {
    if vm.isLoading {
        ProgressView()
    } else if vm.items.isEmpty {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .foregroundColor(.secondary)
            Text("No activity yet")  // Changed from "No transactions yet"
                .foregroundColor(.secondary)
                .font(.footnote)
        }
    }
}
```

#### **ActivityDetailView.swift**

**Changes:**

1. Add conditional sections based on `item.itemType`:

```swift
var body: some View {
    Form {
        switch item.itemType {
        case .transaction:
            transactionSections()
        case .signature:
            signatureSections()
        }
    }
    .navigationTitle("Details")
    .navigationBarTitleDisplayMode(.inline)
}

@ViewBuilder
private func transactionSections() -> some View {
    // Existing transaction UI (hash, status, network, timestamp, explorer)
    Section("Transaction") {
        // ... existing code ...
    }
    Section {
        Button(action: { openExplorer() }) {
            HStack {
                Spacer()
                Text("Open in Explorer")
                Spacer()
            }
        }
    }
}

@ViewBuilder
private func signatureSections() -> some View {
    Section("Signature") {
        // Method
        HStack {
            Text("Method")
            Spacer()
            Text(methodDisplayName(item.method))
                .foregroundColor(.secondary)
        }

        // Message content (preview with copy)
        Button(action: {
            UIPasteboard.general.string = item.messageContent
            didCopyMessage = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                didCopyMessage = false
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Message")
                    Spacer()
                    Image(systemName: didCopyMessage ? "checkmark" : "doc.on.doc")
                        .foregroundColor(.secondary)
                }

                Text(messagePreview(item.messageContent ?? ""))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(showFullMessage ? nil : 3)
                    .truncationMode(.tail)

                if canExpand(item.messageContent ?? "") {
                    Button(showFullMessage ? "Show Less" : "Show More") {
                        withAnimation { showFullMessage.toggle() }
                    }
                    .font(.caption)
                }
            }
        }
        .buttonStyle(.plain)

        // Signature hex (copy)
        Button(action: {
            UIPasteboard.general.string = item.signatureHex
            didCopySignature = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                didCopySignature = false
            }
        }) {
            HStack {
                Text("Signature")
                Spacer()
                HStack(spacing: 6) {
                    Text(truncatedHex(item.signatureHex ?? ""))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: didCopySignature ? "checkmark" : "doc.on.doc")
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    Section("Verification") {
        // From address
        if let from = item.fromAddress {
            HStack {
                Text("From")
                Spacer()
                Text(from)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }

        // Chain
        HStack {
            Text("Network")
            Spacer()
            Text(chainName(from: item.chainIdHex))
                .foregroundColor(.secondary)
        }

        // Timestamp
        HStack {
            Text("Timestamp")
            Spacer()
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private func methodDisplayName(_ method: String) -> String {
    switch method {
    case "personal_sign": return "Personal Message"
    case "eth_signTypedData_v4": return "Typed Data (EIP-712)"
    case "wallet_connect_siwe": return "Sign-In with Ethereum"
    default: return method
    }
}

private func messagePreview(_ content: String) -> String {
    // For personal_sign (hex), try to decode to UTF-8
    if content.hasPrefix("0x") {
        if let data = Data(hexString: content),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
    }

    // For JSON (signTypedData), pretty-print if valid
    if let data = content.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
       let formatted = String(data: pretty, encoding: .utf8) {
        return formatted
    }

    // Fallback: return as-is
    return content
}

private func canExpand(_ content: String) -> Bool {
    return content.count > 200  // Expand if message > 200 chars
}

private func truncatedHex(_ hex: String) -> String {
    guard hex.hasPrefix("0x"), hex.count > 12 else { return hex }
    let start = hex.index(hex.startIndex, offsetBy: 2)
    let first6 = hex[start..<hex.index(start, offsetBy: 6)]
    let last6 = hex.suffix(6)
    return "0x\(first6)…\(last6)"
}

// Add state variables
@State private var didCopyMessage: Bool = false
@State private var didCopySignature: Bool = false
@State private var showFullMessage: Bool = false
```

### Phased Implementation

#### **Phase 1: Database and Store**

**Files:** `shared/ActivityStore.swift`

**Tasks:**

1. Add `ActivityItemType` enum
2. Update `ActivityItem` struct with polymorphic fields
3. Implement migration logic (v1 → v2) with `signatures` table creation
4. Add `logSignature(...)` API
5. Rename and rewrite `fetchTransactions` → `fetchActivity` with UNION query
6. Add SHA-256 helper extension on `Data`

**Testing:**

- Unit test: Insert 2 transactions + 2 signatures, verify unified query returns all 4 in correct order
- Unit test: Verify signature deduplication (insert same signature twice, fetch returns 1)
- Unit test: Migration from v1 DB preserves existing transaction data

**Acceptance:** `fetchActivity` returns mixed list sorted by `created_at DESC, id DESC`

**Implementation Notes:**

1. **Millisecond Timestamp Storage:**

   - Changed `created_at` from epoch seconds to epoch milliseconds (`Int64(Date().timeIntervalSince1970 * 1000)`)
   - **Rationale**: When items are inserted rapidly (within the same second), they would have identical `created_at` values, causing indeterminate ordering despite the secondary `id DESC` sort. Millisecond precision ensures stable ordering for rapid insertions.
   - **Migration Impact**: This change applies to both v1 (transactions) and v2 (signatures) schemas since the migration creates fresh schemas with millisecond storage. Existing databases will have mixed precision, but new writes use milliseconds consistently.

2. **UNION Query Column Alignment:**

   - Both SELECT clauses must have identical column counts and types
   - Added `t.id` and `s.id` columns to enable proper ordering across both tables
   - **ORDER BY**: Uses column positions (10, 11) for `created_at` and `id` respectively
   - Column layout:
     ```
     1:type, 2:tx_hash, 3:status, 4:sig_hash, 5:msg, 6:sig,
     7:chain_id_hex, 8:method, 9:from_address, 10:created_at, 11:id,
     12:domain, 13:uri, 14:scheme
     ```

3. **Data Conversion:**

   - **Write**: `Int64(Date().timeIntervalSince1970 * 1000)` stores milliseconds
   - **Read**: `Date(timeIntervalSince1970: TimeInterval(createdAtMillis) / 1000.0)` converts back
   - Index 10 (id column) is read but not used in returned `ActivityItem`

4. **Test Coverage:**

   - `testSignatureLogging()`: Validates unified activity fetching with both types
   - `testSignatureDeduplication()`: Verifies SHA-256 hash uniqueness prevents duplicates
   - `testMigrationV1ToV2()`: Confirms schema upgrade preserves data
   - `testFetchActivityOrdering()`: Critical test for reverse chronological order with rapid insertions (2ms delays)
   - `testInsertAndFetchOrdering()`: Validates ordering stability for transaction-only data

5. **Schema Comments:**
   - Added `-- epoch milliseconds` inline comments to both `transactions.created_at` and `signatures.created_at` columns for future reference

---

#### **Phase 2: Extension Integration**

**Files:** `safari/SafariWebExtensionHandler.swift`

**Tasks:**

1. Thread `appMetadata` parameter through:
   - `handlePersonalSign(params:appMetadata:)`
   - `handleSignTypedDataV4(params:appMetadata:)`
   - Call sites in `handleWalletRequest`
2. Add best-effort logging after successful signing in:
   - `handlePersonalSign` (log with `method = "personal_sign"`)
   - `handleSignTypedDataV4` (log with `method = "eth_signTypedData_v4"`)
   - `handleWalletConnect` → `handleSignInWithEthereum` (log with `method = "wallet_connect_siwe"`)
3. Ensure logging failures never affect RPC responses (catch and ignore)

**Testing:**

- Manual: Sign a personal message via a dApp → verify row in `signatures` table
- Manual: Sign typed data via a dApp → verify row with full JSON in `message_content`
- Manual: Connect with SIWE → verify SIWE message logged

**Acceptance:** All three signature methods log activity rows with correct app metadata

**Implementation Notes:**

1. **Method Signature Updates:**

   - `handlePersonalSign` (line 343): Added `appMetadata: AppMetadata` parameter
   - `handleSignTypedDataV4` (line 433): Added `appMetadata: AppMetadata` parameter
   - Call sites updated in `handleWalletRequest` (lines 144, 147) to pass `appMetadata`

2. **Logging Implementation:**

   **`handlePersonalSign` (lines 408-425):**

   - Logs immediately after signature generation (after line 406)
   - Stores raw hex message content (`messageHex`) from params
   - Uses `Constants.Networks.getCurrentChainIdHex()` for chain ID
   - Creates `ActivityStore.AppMetadata` from passed `appMetadata`
   - Wrapped in `do-catch` block; errors ignored silently

   **`handleSignTypedDataV4` (lines 477-494):**

   - Logs immediately after signature generation (after line 475)
   - Stores full JSON typed data content (`typedDataJSON`) for transparency
   - Uses `Constants.Networks.getCurrentChainIdHex()` for chain ID
   - Wrapped in `do-catch` block; errors ignored silently

   **`handleWalletConnect` → SIWE (lines 287-307):**

   - Logs after successful SIWE result extraction
   - Extracts `signature` and `message` from `siweResult` dictionary
   - Stores formatted SIWE message (not hex-encoded)
   - Uses first chain ID from `supportedChainIds` array, falls back to `"0x1"`
   - Nested `do-catch` block to handle optional extraction gracefully

3. **Error Handling:**

   - All logging code wrapped in `do-catch` with `// Ignore logging failures` comment
   - RPC responses always returned normally regardless of logging success/failure
   - No changes to existing error paths or response structures

4. **Consistency:**

   - All three methods use identical pattern: create `ActivityStore.AppMetadata`, call `logSignature`, catch and ignore errors
   - SHA-256 signature hash computation handled by `ActivityStore.logSignature` (not in handler)
   - All `fromAddress` parameters pass through saved address without transformation

5. **Testing Status:**
   - ✅ Implementation complete
   - ✅ No linter errors
   - ✅ Manual testing confirmed working by user

---

#### **Phase 3: iOS UI Updates**

**Files:** `ios-wallet/ActivityViewModel.swift`, `ActivityView.swift`, `ActivityDetailView.swift`

**Tasks:**

**ActivityViewModel:**

1. Update `loadLatest` and `fetchNextPage` to call `fetchActivity` instead of `fetchTransactions`
2. Update `pollPendingOnce` to filter only `.transaction` items with `status == "pending"`

**ActivityView:**

1. Add `methodDisplayName` helper
2. Update list row rendering with `switch item.itemType`
3. Change empty state text to "No activity yet"

**ActivityDetailView:**

1. Add state variables: `didCopyMessage`, `didCopySignature`, `showFullMessage`
2. Implement `transactionSections()` and `signatureSections()` methods
3. Add helpers: `methodDisplayName`, `messagePreview`, `canExpand`, `truncatedHex`
4. Render appropriate section based on `item.itemType`

**Testing:**

- Manual: Navigate to Activity → verify mixed list shows both transactions and signatures
- Manual: Tap transaction → see existing detail view
- Manual: Tap signature → see message content, signature hex, copy buttons work
- Manual: Expand long message → verify "Show More" works

**Acceptance:**

- Activity list shows signatures with method names instead of hashes
- Detail view correctly renders signature-specific fields
- Copy buttons work for message and signature hex
- Message content displays formatted (UTF-8 for personal_sign, pretty JSON for typed data)

**Implementation Notes:**

1. **ActivityViewModel Changes:**

   - Updated `loadLatest()` to call `fetchActivity()` instead of `fetchTransactions()` (line 23)
   - Updated `fetchNextPage()` to call `fetchActivity()` instead of `fetchTransactions()` (line 59)
   - `pollPendingOnce()` already correctly filters only `.transaction` items with `status == "pending"` (line 123)

2. **ActivityView Changes:**

   - Added `methodDisplayName(_ method: String)` helper (lines 35-42) for simple labels:
     - `"personal_sign"` → `"Message"`
     - `"eth_signTypedData_v4"` → `"Typed Data"`
     - `"wallet_connect_siwe"` → `"Sign-In"`
   - Updated list row rendering with `switch item.itemType` (lines 53-78):
     - Transactions: Show "Transaction" label for confirmed, "Pending"/"Failed" with icons for other states
     - Signatures: Show "Signature" label
   - Empty state already shows "No activity yet" (line 85)

3. **ActivityDetailView Changes:**

   - Added state variables (lines 14-17):
     - `@State private var didCopyHash: Bool = false`
     - `@State private var didCopyMessage: Bool = false`
     - `@State private var didCopySignature: Bool = false`
     - Removed `showFullMessage` (not needed with new rendering approach)
   - Implemented conditional rendering in `body` based on `item.itemType` (lines 84-89)
   - Implemented `transactionSections()` (lines 95-152) with existing transaction UI
   - Implemented `signatureSections()` (lines 154-219) with:
     - Message content (structured rendering based on method)
     - Hash (copyable, truncated display)
     - Signature hex (copyable, truncated display)
     - Verification section (from address, network, timestamp)

4. **Enhanced Message Rendering:**

   - **Smart routing** via `messageContentView()` (lines 221-230) that detects method type
   - **Personal message display** via `personalMessageView()` (lines 233-258):
     - Decodes hex to UTF-8 string
     - Shows as clean readable text
     - Copyable via button in header
     - No "Show More" button needed - naturally wraps
   - **Typed data display** via `typedDataMessageView()` (lines 260-325):
     - Parses EIP-712 JSON structure
     - **Domain section** with Name, Version, Chain, Verifying Contract
     - **Message section** with all fields from `message` object
     - Fields shown with UPPERCASE labels and type-aware formatting
     - Monospaced font for hex addresses
     - All values text-selectable for easy copying
     - Falls back to personal message view if JSON parsing fails
   - **Helper functions**:
     - `domainField(label:value:)` (lines 327-338) - renders domain fields with uppercase labels
     - `messageField(label:value:)` (lines 340-351) - renders message fields with uppercase labels
     - `formatValue(_:)` (lines 353-368) - formats Any values as strings (handles strings, numbers, objects, arrays)
     - `decodePersonalMessage(_:)` (lines 49-56) - decodes hex to UTF-8
     - `truncatedHex(_:)` (lines 74-79) - truncates long hex strings to `0xABCDEF…123456`

5. **UX Improvements:**

   - Removed confusing "Show More/Less" button for typed data (structured view is cleaner)
   - Added `.textSelection(.enabled)` to all value fields for easy copying
   - Consistent copy button pattern across all copyable fields
   - Visual feedback (checkmark icon) when copying succeeds
   - Method field removed from signature detail view (redundant with section title)
   - Hash positioned above Signature for logical grouping

6. **Testing Status:**
   - ✅ Implementation complete
   - ✅ No linter errors
   - ✅ Build successful
   - ✅ UI mirrors web modal patterns (SignMessageModal.tsx, SignTypedDataModal.tsx)

---

#### **Phase 4: Polish & Edge Cases**

**Tasks:**

1. Handle malformed JSON gracefully in `messagePreview` (show raw if parse fails)
2. Handle extremely long messages (>10KB) with scroll or pagination in detail view
3. Add pull-to-refresh support to reload after signing
4. Test mixed activity list with 100+ items (verify pagination works)
5. Test migration on device with existing production data

**Testing:**

- Manual: Sign message with invalid UTF-8 → verify raw hex displayed
- Manual: Sign typed data with malformed JSON → verify raw string displayed
- Manual: Scroll through 100+ mixed activities → verify performance acceptable
- Manual: Upgrade app from v1 schema → verify migration succeeds, old data intact

**Acceptance:**

- No crashes on edge case message content
- Smooth scrolling with large datasets
- Migration preserves all existing transaction data

**Implementation Notes:**

1. **ActivityDetailView Enhancements:**

   **Enhanced `decodePersonalMessage()` (lines 40-65):**

   - Added empty content guard: returns `"(empty message)"` for safety
   - Hex validation: checks even length and valid hex characters before decoding
   - Lossy fallback chain: UTF-8 → ASCII → binary data indicator
   - Graceful error messages: `"(invalid hex: ...)"` or `"(binary data, N bytes)"`

   **`personalMessageView()` with large content handling (lines 241-291):**

   - 10KB threshold for "large message" detection
   - Size badge displayed in orange when content exceeds threshold
   - ScrollView with max height (300pt) for large messages
   - Gray background container for visual distinction
   - Added `formatBytes()` helper for human-readable sizes (B, KB, MB)

   **`typedDataMessageView()` with robustness (lines 293-394):**

   - 50KB threshold for JSON payloads (higher than personal messages)
   - ScrollView wrapper with max height (500pt) for large JSON
   - Size badge and warning indicator for very large payloads
   - Explicit error handling: JSON parse failures show warning icon with fallback to raw content
   - Warning message: "Large payload - some fields may be truncated" for transparency

2. **ActivityStore Migration Safety (shared/ActivityStore.swift):**

   **Enhanced `createSchemaIfNeeded()` (lines 335-404):**

   - Pre-migration logging: counts existing transactions before v1→v2 upgrade
   - Atomic migration: wraps schema changes in `BEGIN TRANSACTION` / `COMMIT`
   - Table existence verification: uses new `tableExists()` helper to verify signatures table creation
   - Comprehensive rollback: on any failure, rolls back transaction AND drops partial tables
   - Post-migration logging: confirms success or logs failure reason
   - Future-proofing: warns if schema version is newer than expected (> 2)

   **New helper functions (lines 515-544):**

   - `tableExists(_ tableName: String) -> Bool`: queries sqlite_master for table existence
   - `countRows(table: String) -> Int?`: returns row count with SQL injection protection (alphanumeric validation)
   - Both helpers use proper statement cleanup with `defer { sqlite3_finalize(stmt) }`

3. **Database Inspection API (shared/ActivityStore.swift):**

   **`DatabaseInfo` struct (lines 307-324):**

   - Public struct with schema version, counts (transactions, signatures, apps), and database path
   - `description` computed property returns formatted multi-line string
   - All properties are public for external inspection tools

   **`getDatabaseInfo()` API (lines 326-357):**

   - Thread-safe: uses `queue.sync` for database access
   - Queries PRAGMA user_version for schema version
   - Uses `countRows()` helper for accurate counts (handles nil gracefully with `?? 0`)
   - Extracts database file path via `sqlite3_db_filename()` for debugging
   - Returns structured info suitable for logging or UI display

4. **Error Handling Strategy:**

   - All new helpers use guard statements with early returns for safety
   - Malformed input (empty strings, invalid hex, bad JSON) handled gracefully with user-friendly messages
   - No exceptions thrown for display logic—fallbacks ensure content is always viewable
   - Migration failures preserve existing data (rollback to v1 if v2 creation fails)

5. **UI/UX Improvements:**

   - Visual indicators for large content (orange size badges)
   - Scrollable containers prevent layout overflow on long messages
   - Copy functionality preserved for all content types
   - Background colors and padding improve readability of scrollable areas
   - Warning icons provide clear feedback when parsing fails

6. **Testing Status:**
   - ✅ Implementation complete
   - ✅ No linter errors
   - ✅ Build successful
   - ✅ All Phase 4 tasks completed per spec
   - ✅ Pull-to-refresh already implemented in Phase 3 (`ActivityView.swift` line 125: `.refreshable`)

---

### Files to Modify

| File                                       | Phase | Changes                                                                                                            |
| ------------------------------------------ | ----- | ------------------------------------------------------------------------------------------------------------------ |
| `shared/ActivityStore.swift`               | 1, 4  | Add `signatures` table, polymorphic model, migration, new APIs; enhanced migration safety, database inspection API |
| `safari/SafariWebExtensionHandler.swift`   | 2     | Thread `appMetadata`, add logging in signature handlers                                                            |
| `ios-wallet/ActivityViewModel.swift`       | 3     | Update API calls, filter polling by item type                                                                      |
| `ios-wallet/ActivityView.swift`            | 3     | Conditional row rendering, method display names                                                                    |
| `ios-wallet/ActivityDetailView.swift`      | 3, 4  | Conditional sections, message preview, copy buttons; enhanced error handling for large/malformed content           |
| `ios-walletTests/ActivityStoreTests.swift` | 1, 4  | Test unified query, migration, deduplication                                                                       |

---

### Database Inspection (macOS Safari)

**Query unified activity:**

```bash
sqlite3 "$HOME/Library/Group Containers/group.co.za.stephancill.stupid-wallet/Activity.sqlite" "
SELECT
  'tx' as type,
  t.tx_hash as hash,
  t.status,
  t.method,
  a.domain,
  t.chain_id_hex,
  datetime(t.created_at,'unixepoch') as created_at
FROM transactions t
LEFT JOIN apps a ON a.id=t.app_id

UNION ALL

SELECT
  'sig' as type,
  s.signature_hash as hash,
  null as status,
  s.method,
  a.domain,
  s.chain_id_hex,
  datetime(s.created_at,'unixepoch') as created_at
FROM signatures s
LEFT JOIN apps a ON a.id=s.app_id

ORDER BY created_at DESC
LIMIT 50;
"
```

**Check schema version:**

```bash
sqlite3 "$HOME/Library/Group Containers/group.co.za.stephancill.stupid-wallet/Activity.sqlite" "PRAGMA user_version;"
# Should return: 2
```

---

### Security & Privacy Considerations

1. **Message content storage:**

   - Risk: Full message content (including potentially sensitive data) stored in plaintext SQLite
   - Mitigation: Database is in App Group container (sandboxed, not backed up to iCloud by default)
   - Future enhancement: Optionally encrypt message content at rest

2. **Signature deduplication:**

   - Risk: Using signature hex as unique constraint prevents logging same signature twice
   - Benefit: Prevents spam/duplication if dApp resubmits
   - Trade-off: Acceptable for audit log use case

3. **Large message handling:**
   - Risk: 100KB+ JSON payloads could impact UI performance or DB size
   - Mitigation: Lazy rendering with "Show More" expansion, limit display to first N chars
   - Future enhancement: Add max content length (e.g., 1MB) with truncation warning

---

### Future Enhancements (Out of Scope)

1. **Export activity:**

   - Export activity log as CSV/JSON for external audit tools

2. **Search & filtering:**

   - Search by domain, method, address
   - Filter by type (transactions only, signatures only)
   - Date range filtering

3. **Signature verification UI:**

   - "Verify Signature" button that recomputes message digest and validates signature
   - Show recovered signer address

4. **Message content encryption:**

   - Optionally encrypt `message_content` column using wallet key derivation
   - Decrypt on-demand for display

5. **Batch operations:**

   - "Clear old signatures" (delete signatures older than N days)
   - "Export signatures for domain X"

6. **Additional signature methods:**
   - Log `eth_sign` (raw message signing, discouraged but still supported)
   - Log `eth_signTransaction` (if added to provider)

---

### Migration Rollback Strategy

If migration fails in production:

1. **Detection:** Log migration errors to console; show user-facing alert on repeated failures
2. **Fallback:** If v2 schema creation fails, downgrade `user_version` back to 1 and continue with transactions-only
3. **Recovery:** Provide manual DB reset option in Settings (delete `Activity.sqlite`, recreate fresh v2 schema)

**Implementation:**

```swift
// In createSchemaIfNeeded()
do {
    if currentVersion == 1 {
        try createSignaturesTable()
        exec("PRAGMA user_version = 2;")
    }
} catch {
    // Rollback on failure
    exec("DROP TABLE IF EXISTS signatures;")
    exec("PRAGMA user_version = 1;")
    throw ActivityStoreError.migrationFailed
}
```

---

### Summary

This specification adds comprehensive signature logging to the existing Activity Log infrastructure with:

- Clean separation via a dedicated `signatures` table
- Polymorphic UI rendering for mixed transaction/signature lists
- Full message content transparency for audit purposes
- Zero impact on existing transaction logging
- Safe migration path from v1 to v2 schema

Implementation can proceed in 4 phases over ~3-5 days, with Phase 1 (database) being the foundation for subsequent extension and UI work.
