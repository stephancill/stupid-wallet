## Activity Log and Activity View Specification

### Overview

Add an Activity Log persisted in SQLite (in the App Group container) to record outbound transactions initiated by the wallet/extension. The iOS app will display a reverse‑chronological Activity View with transaction rows and a detail screen linking to a block explorer.

### Goals

- Durable history across account switching/clearing (do not wipe the DB when clearing account key material)
- De‑duplicated app metadata storage (domain/uri/scheme)
- Record each broadcasted transaction hash with context (method, chain, from address, timestamp)
- Efficient queries for reverse‑chronological list

### Storage Location

- SQLite database file stored in the shared App Group container (`Constants.appGroupId`).
- Suggested filename: `Activity.sqlite` inside the group container root.
- On open, apply PRAGMAs:
  - `PRAGMA journal_mode=WAL;`
  - `PRAGMA foreign_keys=ON;`
  - `PRAGMA synchronous=NORMAL;`

### Schema

```sql
-- apps: unique app metadata (no duplication)
CREATE TABLE IF NOT EXISTS apps (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  domain TEXT,
  uri TEXT,
  scheme TEXT,
  UNIQUE(domain, uri, scheme)
);

-- transactions: each broadcasted transaction
CREATE TABLE IF NOT EXISTS transactions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tx_hash TEXT NOT NULL UNIQUE,
  app_id INTEGER NOT NULL,
  chain_id_hex TEXT NOT NULL,
  method TEXT,
  from_address TEXT,
  created_at INTEGER NOT NULL,   -- epoch seconds
  status TEXT NOT NULL DEFAULT 'pending',
  FOREIGN KEY(app_id) REFERENCES apps(id)
);

CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions(created_at DESC);
```

Notes:

- `apps` table de‑duplicates app/site metadata via `UNIQUE(domain, uri, scheme)`.
- `transactions.tx_hash` is unique to avoid duplicates if the same tx is logged twice.
- Do not persist chain names; derive them at runtime from `chain_id_hex` (e.g., via
  `Constants.Networks.chainName(forChainIdHex:)`).

### Swift Store (shared)

- File: `shared/ActivityStore.swift` (compiled into both the iOS app and the Safari Extension).
- Single shared interface with an internal serial dispatch queue for DB operations.
- API surface (initial):
  - `func logTransaction(txHash: String, chainIdHex: String, method: String, fromAddress: String?, app: AppMetadata) throws`
    - Upsert into `apps`; insert into `transactions` with current timestamp.
    - Ignore `tx_hash` duplicates.
  - `func fetchTransactions(limit: Int, offset: Int) throws -> [ActivityItem]`
    - Returns rows joined with `apps`, sorted by `created_at` DESC.
  - `struct AppMetadata { let domain: String?; let uri: String?; let scheme: String? }`
  - `struct ActivityItem { let txHash: String; let app: AppMetadata; let chainIdHex: String; let method: String?; let fromAddress: String?; let createdAt: Date }`

Concurrency & lifecycle:

- Open one connection per process (app, extension) and keep it for the process lifetime.
- Serialize access inside `ActivityStore` to avoid cross‑thread issues.

### Extension Integration Points

In `safari/SafariWebExtensionHandler.swift`:

- Thread `appMetadata` from `beginRequest` → `handleWalletRequest` → method handlers.
- On success:
  - `eth_sendTransaction`: after `sendRawTransaction` returns, call `ActivityStore.shared.logTransaction(...)` with `method = "eth_sendTransaction"`.
  - `wallet_sendCalls`: after returning tx hash (both EIP‑7702 and legacy branches), call `logTransaction(...)` with `method = "wallet_sendCalls"`.
- Use `Constants.Networks.getCurrentChainIdHex()` for `chainIdHex` and `getSavedAddress()` for `fromAddress`.
- If `appMetadata` is missing, persist a row with all three fields `nil` (the UNIQUE constraint will still de‑duplicate).

### iOS UI

Files:

- `ios-wallet/ActivityViewModel.swift`: loads recent activity from `ActivityStore` and exposes `@Published var items: [ActivityItem]`.
- `ios-wallet/ActivityView.swift`: reverse‑chronological list with rows.
- `ios-wallet/ActivityDetailView.swift`: shows tx details and an external link.

List Row:

- Leading app label: prefer `domain`, else `uri`, else `scheme` or `Unknown App`.
- Middle: truncated tx hash like `0x1234…abcd`.
- Trailing: relative time (e.g., “5m ago”) via `RelativeDateTimeFormatter`.
- Secondary metadata: render chain name derived at runtime from `chainIdHex`.

Detail Screen:

- Show tx hash, chain name (derived from `chainIdHex`), timestamp.
- External link: `Blockscan` (temporary) — open `https://blockscan.com/tx/<hash>`.

### Status Updates and Polling

Goal: update `transactions.status` from `pending` → `confirmed` or `failed` by polling the chain for receipts, mirroring the logic used in `handleWalletGetCallsStatus` in `safari/SafariWebExtensionHandler.swift`.

- Status values:

  - `pending`: broadcast acknowledged but no receipt yet
  - `confirmed`: receipt exists and `status == 1`
  - `failed`: receipt exists and `status == 0`, or a permanent error is detected

- Mapping (same semantics as `wallet_getCallsStatus`):

  - No receipt → treat as pending (akin to status code 100 in handler)
  - Receipt with `status == 1` → confirmed (akin to 200)
  - Receipt with `status == 0` → failed (akin to 500)

- Polling strategy (app-side):

  - Only poll while the Activity View is visible, or in short bursts after a new tx is logged.
  - For visible pending items: poll `eth_getTransactionReceipt` every 5s for the first 60s, then every 15s up to 10 minutes, then back off to 30s. Stop polling an item once it becomes `confirmed` or `failed`.
  - Bound concurrency (e.g., max 5 parallel receipt checks) to avoid overloading RPCs.
  - Update the row immediately on status change and persist the new `status` in the DB.

- Data access:

  - Use the current network RPC (derived from `chainIdHex`) to query receipts.
  - Implement in `ActivityViewModel` as a lightweight poller using a `Timer`/`Task` loop.

- Extension parity:
  - The extension’s `handleWalletGetCallsStatus` uses the same underlying check (receipt lookup) and codes (100/200/500). The app should mirror its outcome mapping when updating `transactions.status`.

Navigation Entry Point:

- In `ios-wallet/ContentView.swift`, add a toolbar button (e.g., system image `"clock"`) to push `ActivityView`.
- Keep the existing Settings gear; both may appear in the top‑right.

### Persistence & Clearing

- Do not delete the Activity DB in the existing “clear wallet” flow; only clear key material and `UserDefaults` entries.
- Activity history remains unless a future explicit “Clear Activity” is added.

### Performance & Reliability

- Use WAL + `synchronous=NORMAL`.
- Keep statements prepared where practical; reuse a single connection per process.
- Failures to log should never break RPC responses; best‑effort logging.

### Edge Cases

- `wallet_sendCalls` v2 returns an object with `id`; log the tx hash string value.
- Unknown or custom chains: still log `chain_id_hex` as provided.
- If multiple txs share an app, they point to the same `apps` row via `app_id`.

### Future Enhancements (optional, later)

- Status updates (pending/mined/failed) via periodic receipt polling or `wallet_getCallsStatus` callbacks.
- Show chain icons and app favicons in rows.
- Add a “Clear Activity” action in Settings.

### Phased Implementation Plan

Phase 1 — Database and Store (shared)

- Add `shared/ActivityStore.swift` with:
  - Database open in App Group container (`Activity.sqlite`), PRAGMAs (WAL, foreign_keys, synchronous).
  - Schema creation for `apps` and `transactions` (as above).
  - APIs: `logTransaction(...)`, `fetchTransactions(limit:offset:)`.
  - Thread-safety via a serial dispatch queue; single connection per process.
- Acceptance: Unit test opening DB, upsert app metadata, insert tx, and fetch list order.

Implementation Notes (Phase 1)

- File: `shared/ActivityStore.swift` (compiled into both the iOS app and the Safari extension)
- Storage:
  - Uses SQLite via `SQLite3` C API
  - Database path: App Group container `Constants.appGroupId` at `Activity.sqlite`
  - Connection model: a single process‑lifetime connection guarded by a private serial `DispatchQueue`
  - PRAGMAs applied on open: `journal_mode=WAL`, `foreign_keys=ON`, `synchronous=NORMAL`
- Schema:
  - Matches the spec (`apps` + `transactions`) with `UNIQUE(domain, uri, scheme)` on `apps` and `UNIQUE(tx_hash)` on `transactions`
  - Indexes:
    - `CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions(created_at DESC)`
    - Additionally created for deterministic ordering and performance: `CREATE INDEX IF NOT EXISTS idx_transactions_created_id_desc ON transactions(created_at DESC, id DESC)`
- Ordering semantics:
  - `fetchTransactions(limit:offset:)` orders by `created_at DESC, id DESC` to break same‑second ties while keeping newest‑first behavior stable
- API surface:
  - `logTransaction(txHash: String, chainIdHex: String, method: String, fromAddress: String?, app: AppMetadata) throws`
    - Upserts app metadata (respects `UNIQUE(domain, uri, scheme)`; `nil` values allowed and de‑duplicated)
    - Inserts into `transactions` with `created_at = now()`; duplicate `tx_hash` are ignored (`INSERT OR IGNORE`)
  - `fetchTransactions(limit: Int, offset: Int) throws -> [ActivityItem]`
    - Joins with `apps` and returns items sorted newest‑first
- Safety and reliability:
  - All DB work is serialized; failures throw but logging is best‑effort (callers can ignore)
  - Text bindings use `SQLITE_TRANSIENT` semantics to copy Swift strings safely
- Unit test:
  - `ios-walletTests/ActivityStoreTests.swift` inserts three txs and asserts reverse‑chronological order; uses a unique suffix to avoid collisions

Phase 2 — Extension integration (logging)

- Thread `appMetadata` through `handleWalletRequest` into:
  - `handleSendTransaction` — on success log with `method = "eth_sendTransaction"`.
  - `handleWalletSendCalls` — on success log with `method = "wallet_sendCalls"`.
- Use `Constants.Networks.getCurrentChainIdHex()` and `getSavedAddress()`.
- Graceful failure: logging errors must not affect RPC responses.
- Acceptance: Manual test by sending a tx; verify row appears in DB with correct app metadata.

Implementation Notes (Phase 2)

- Files: `safari/SafariWebExtensionHandler.swift`
- Data flow: Thread `appMetadata` from `beginRequest` → `handleWalletRequest` into the concrete handlers.
- Logging points (best‑effort; failures do not affect RPC results):
  - `eth_sendTransaction`: After `web3.eth.sendRawTransaction` succeeds, call `ActivityStore.shared.logTransaction(txHash, chainIdHex: Constants.Networks.getCurrentChainIdHex(), method: "eth_sendTransaction", fromAddress: getSavedAddress(), app: appMetadata)`.
  - `wallet_sendCalls`: On success, extract tx hash from result:
    - v1: result is the tx hash string
    - v2: result is an object `{ id: <txHash> }`
      Then call `logTransaction(..., method: "wallet_sendCalls", fromAddress: fromAddress)`.
- `chainIdHex`: `Constants.Networks.getCurrentChainIdHex()`; `fromAddress`: `getSavedAddress()` (or `fromAddress` for sendCalls path).
- If `appMetadata` values are missing, `ActivityStore` upserts a row with `NULL` domain/uri/scheme and de‑duplicates via the `UNIQUE` constraint.
- Inspecting the DB on macOS (Safari on Mac):

```bash
sqlite3 "$HOME/Library/Group Containers/group.co.za.stephancill.stupid-wallet/Activity.sqlite" \
"SELECT t.tx_hash, a.domain, a.uri, a.scheme, t.chain_id_hex, t.method, t.from_address, datetime(t.created_at,'unixepoch') AS created_at, t.status FROM transactions t LEFT JOIN apps a ON a.id=t.app_id ORDER BY t.created_at DESC, t.id DESC LIMIT 50;"
```

Phase 3 — Activity UI and navigation

- Add `ios-wallet/ActivityViewModel.swift` with `@Published var items` and loading via `ActivityStore.fetchTransactions(...)`.
- Add `ios-wallet/ActivityView.swift`:
  - Reverse-chronological list; row shows app label, truncated hash, relative time, and chain name derived from `chainIdHex`.
  - Pull-to-refresh to reload items.
- Add `ios-wallet/ActivityDetailView.swift`:
  - Show tx hash, chain name (derived), timestamp, and a `Blockscan` link.
- Update `ios-wallet/ContentView.swift` toolbar:
  - Add a `NavigationLink` with `Image(systemName: "clock")` to open Activity.
- Acceptance: Navigate from the top-right button; see logged entries and open detail.

Implementation Notes (Phase 3)

- Files:
  - `ios-wallet/ActivityViewModel.swift`
    - `@Published var items: [ActivityItem]`
    - `loadLatest(limit:offset:)` fetches from `ActivityStore.shared.fetchTransactions(...)` on a background queue and publishes on main.
  - `ios-wallet/ActivityView.swift`
    - Reverse-chronological `List` of activity items.
    - Row layout:
      - First line: app label — prefers `domain`, else `uri`, else `scheme`, else “Unknown App”.
      - Second line: `{truncated hash} • {Chain name}`
        - Only the hash is monospaced; chain name uses normal font.
      - Trailing on the right: time ago (RelativeDateTimeFormatter), vertically centered, normal text size.
    - Pull-to-refresh calls `loadLatest()`.
  - `ios-wallet/ActivityDetailView.swift`
    - Sections: Transaction, Status, Network, Timestamp, and an Explorer link button.
    - Transaction row is tappable to copy the hash to clipboard and shows a trailing icon that switches from `doc.on.doc` to `checkmark` briefly after copying. Hash text is monospaced and truncates in the middle.
    - Explorer button label reads “Open in Explorer” and opens Blockscan: `https://blockscan.com/tx/<hash>`.
- Navigation:
  - `ios-wallet/ContentView.swift` toolbar includes a `NavigationLink` with system image `"clock"` to open `ActivityView` (alongside the Settings gear).
- Data model updates:
  - `ActivityStore.ActivityItem` now includes `status: String`.
  - `ActivityStore.fetchTransactions` selects `t.status` and populates the field; `ActivityDetailView` renders the value (capitalized) in the Status section.
- Out of scope for Phase 3:
  - Status polling remains in Phase 4; the UI currently reflects the persisted status without background updates.

Phase 4 — Status polling for pending transactions

- In `ActivityViewModel`, implement a lightweight poller:
  - Select items with `status = pending`.
  - Poll `eth_getTransactionReceipt` using the RPC for each item’s `chainIdHex`.
  - Cadence: 5s for first minute, then 15s up to 10 minutes, then 30s. Stop per-item on terminal status.
  - Map results mirroring `wallet_getCallsStatus`: no receipt → pending; receipt `status == 1` → confirmed; `status == 0` → failed.
  - Persist `status` in DB and update the UI immediately.
- Bound concurrency (e.g., max 5 in-flight checks) to protect RPC.
- Acceptance: A newly logged tx transitions from pending to confirmed/failed when mined.

Implementation Notes (Phase 4)

- Files:
  - `ios-wallet/ActivityViewModel.swift`
  - `shared/ActivityStore.swift`
  - `shared/JSONRPC.swift`
- Poller behavior:
  - Runs only while `ActivityView` is visible; starts on `.onAppear` and stops on `.onDisappear`.
  - Cadence/backoff: every 5s for the first 60s, then every 15s up to 10 minutes, then every 30s thereafter.
  - Bounded concurrency using a lightweight async semaphore (max 5 in-flight receipt checks).
  - Snapshot items on each iteration; query only those with `status = "pending"`.
- RPC selection:
  - For each item, derive chain id from `chainIdHex` and select RPC via `Constants.Networks.rpcURL(forChainId:)`.
  - Issue `eth_getTransactionReceipt` requests using `JSONRPC.request(rpcURL:method:params:timeout:)`.
- Status mapping (aligns with extension `wallet_getCallsStatus`):
  - No receipt → keep `pending`.
  - Receipt with `status == 1` → `confirmed`.
  - Receipt with `status == 0` → `failed`.
  - Transient errors (network/timeouts) do not flip status; remain `pending`.
- Persistence + UI updates:
  - Persist transitions using `ActivityStore.updateTransactionStatus(txHash:status:)`.
  - Immediately update the in-memory item to reflect new status in the list.
- UI indicators in `ActivityView` rows:
  - While `pending`: show a small inline spinner and "Pending" label after the chain name.
  - When not `pending` and not `confirmed`: show a red warning icon and "Failed" label.
  - `confirmed` shows no extra indicator beyond the timestamp and chain name.
  - Detail screen reflects the current persisted status in the "Status" section.
- Reliability: best-effort; polling should never crash the UI or block user interaction. Errors are swallowed and retried on the next tick.

Phase 5 — Robustness and UX

- Pagination or incremental loading in the list (e.g., page size 50, load more on scroll).
- Error states: empty state, DB failure banner, explorer link fallback.
- Chain explorer URLs per network (future); for now keep `Blockscan` generic link.
- Migration scaffolding for future schema changes.
- Acceptance: Smooth scrolling, stable memory usage with large histories.

Implementation Notes (Phase 5)

- Files:

  - `ios-wallet/ActivityViewModel.swift`
    - Adds pagination state: `pageSize = 50`, `isLoadingMore`, `errorMessage`, and internal `canLoadMore` guard.
    - New APIs:
      - `loadInitial()` clears state and fetches the first page.
      - `loadMoreIfNeeded(currentItem:)` triggers fetching next page when user nears the end.
      - Private `fetchNextPage()` performs an offset query and appends results.
    - `loadLatest(limit:offset:)` updated to set `canLoadMore` based on page size and to clear `errorMessage` on new loads.
  - `ios-wallet/ActivityView.swift`
    - Incremental loading: calls `vm.loadMoreIfNeeded(currentItem:)` in each row's `.onAppear`.
    - Bottom loader: shows a small `ProgressView` using `.safeAreaInset(edge: .bottom)` while `vm.isLoadingMore` is true.
    - Error banner: lightweight top overlay displaying `vm.errorMessage` when pagination fails.
    - Pull-to-refresh now calls `vm.loadInitial()` to reload from the first page.
  - `ios-wallet/ActivityDetailView.swift`
    - Explorer fallback: if opening Blockscan fails, falls back to opening an Etherscan URL for the same hash.
  - `shared/ActivityStore.swift`
    - Migration scaffolding via `PRAGMA user_version`:
      - On first open for a fresh DB (`user_version == 0`), sets `user_version = 1`.
      - Future schema changes should bump `user_version` and add conditional migration steps here.

- UX details:

  - Page size is 50; `canLoadMore` disables further fetches when a page returns fewer than 50 rows.
  - Empty state remains a centered tray icon + caption when there are no items and not loading.
  - Error conditions during pagination are non-fatal; an inline banner appears and subsequent scrolls can retry.

- Acceptance:
  - Scrolling to the end loads additional pages until history is exhausted without stutter.
  - Error banner appears on transient failures and disappears on subsequent successful load.
  - "Open in Explorer" works; if Blockscan cannot open, Etherscan fallback opens instead.
  - Fresh databases report `PRAGMA user_version = 1` post-open.

Phase 6 — Tests and CI

- Unit tests for `ActivityStore` (schema creation, upsert/insert/fetch ordering, status update).
- UI tests for navigation and row rendering (best-effort).
- Optional: lightweight integration test to simulate polling logic with mocked RPCs.
- Add a brief note in README on how to run tests.

---

### Signature Logging (Implemented)

**Status**: ✅ Complete (Phases 1-4)

The Activity Log has been extended to capture message signatures alongside transactions. See `docs/SignatureLogging.md` for the complete specification and implementation notes.

**Summary**:

- **Schema v2**: Added `signatures` table with full message content, signature hex, and SHA-256 deduplication
- **Polymorphic model**: `ActivityItem` supports both transaction and signature types
- **Logged methods**:
  - `personal_sign` (EIP-191 personal messages)
  - `eth_signTypedData_v4` (EIP-712 typed data)
  - `wallet_connect_siwe` (Sign-In with Ethereum)
- **UI enhancements**:
  - Unified activity list showing both transactions and signatures
  - Structured message display with domain/message sections for typed data
  - Large content handling (10KB+ messages with scrollable views)
  - Robust error handling for malformed hex/JSON
- **Migration**: Atomic v1→v2 upgrades with rollback on failure
- **Debugging**: `getDatabaseInfo()` API for inspecting schema version and counts

All signature methods log activity with the same app metadata and chain context as transactions.
