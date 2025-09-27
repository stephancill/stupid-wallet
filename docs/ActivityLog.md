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

Phase 4 — Status polling for pending transactions

- In `ActivityViewModel`, implement a lightweight poller:
  - Select items with `status = pending`.
  - Poll `eth_getTransactionReceipt` using the RPC for each item’s `chainIdHex`.
  - Cadence: 5s for first minute, then 15s up to 10 minutes, then 30s. Stop per-item on terminal status.
  - Map results mirroring `wallet_getCallsStatus`: no receipt → pending; receipt `status == 1` → confirmed; `status == 0` → failed.
  - Persist `status` in DB and update the UI immediately.
- Bound concurrency (e.g., max 5 in-flight checks) to protect RPC.
- Acceptance: A newly logged tx transitions from pending to confirmed/failed when mined.

Phase 5 — Robustness and UX

- Pagination or incremental loading in the list (e.g., page size 50, load more on scroll).
- Error states: empty state, DB failure banner, explorer link fallback.
- Chain explorer URLs per network (future); for now keep `Blockscan` generic link.
- Migration scaffolding for future schema changes.
- Acceptance: Smooth scrolling, stable memory usage with large histories.

Phase 6 — Tests and CI

- Unit tests for `ActivityStore` (schema creation, upsert/insert/fetch ordering, status update).
- UI tests for navigation and row rendering (best-effort).
- Optional: lightweight integration test to simulate polling logic with mocked RPCs.
- Add a brief note in README on how to run tests.

Future work:

- Log message signatures too
