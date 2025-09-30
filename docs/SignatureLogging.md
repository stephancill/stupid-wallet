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

---

### Files to Modify

| File                                       | Phase | Changes                                                        |
| ------------------------------------------ | ----- | -------------------------------------------------------------- |
| `shared/ActivityStore.swift`               | 1     | Add `signatures` table, polymorphic model, migration, new APIs |
| `safari/SafariWebExtensionHandler.swift`   | 2     | Thread `appMetadata`, add logging in signature handlers        |
| `ios-wallet/ActivityViewModel.swift`       | 3     | Update API calls, filter polling by item type                  |
| `ios-wallet/ActivityView.swift`            | 3     | Conditional row rendering, method display names                |
| `ios-wallet/ActivityDetailView.swift`      | 3     | Conditional sections, message preview, copy buttons            |
| `ios-walletTests/ActivityStoreTests.swift` | 1, 4  | Test unified query, migration, deduplication                   |

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
