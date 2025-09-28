## Consolidated Connection State between App and Extension (TDD)

### Overview

Persist and unify dApp connection state across the Safari Web Extension and the iOS app using a single source of truth in the shared App Group. This enables automatic connection for previously authorized sites and ensures disconnects and wallet clearing revoke access consistently.

### Scope

- Applies to EIP-1193/EIP-6963 integration in the Safari Web Extension and the iOS app.
- Methods involved: `eth_accounts`, `eth_requestAccounts`, `wallet_connect`, `wallet_disconnect`.
- Storage: App Group `UserDefaults` shared between app and extension.

### Goals

- Persist per-domain connection state in the App Group so extension and app share one source of truth.
- Auto-connect rules:
  - `eth_requestAccounts`: always short-circuit (no modal) if the domain is already connected.
  - `wallet_connect`: short-circuit only if no request capabilities are present AND the domain is already connected. If capabilities are present (e.g., SIWE), show modal and run full flow.
- Disconnect rules:
  - `wallet_disconnect`: removes the domain from the persisted connection set.
  - Clearing the wallet in the app also clears all persisted domain connections.

### Non-Goals

- Multi-account session management. (Single-wallet assumption.)
- UI changes in the app beyond clearing shared state.

### Data Model

- App Group `UserDefaults` key: `connectedSites`
- Type: Dictionary mapping domain → metadata

```json
{
  "example.org": {
    "address": "0xAbC...",
    "connectedAt": "2025-09-28T12:34:56Z"
  },
  "app.uniswap.org": {
    "address": "0xAbC...",
    "connectedAt": "2025-09-28T12:36:00Z"
  }
}
```

- Notes:
  - Address is optional but convenient for auditing; the app has one active wallet.
  - Domain key is the effective site hostname extracted from the request sender.

### Functional Requirements

1. Persist on connect

- After user approval for `eth_requestAccounts` or `wallet_connect`, persist the domain under `connectedSites` with the current wallet address and timestamp.

2. Auto-connect

- `eth_requestAccounts`: if the domain exists in `connectedSites`, immediately return accounts (no modal).
- `wallet_connect`: if the first param has no `capabilities` or an empty object and the domain exists in `connectedSites`, immediately return standard result (no modal). If `capabilities` are present and non-empty (e.g., SIWE), show modal and perform full flow.

3. Gate `eth_accounts`

- When the domain is not in `connectedSites`, throw an EIP‑1193 RPC error 4100 Unauthorized: `{ code: 4100, message: "Unauthorized" }`. Otherwise, return the account list.

4. Disconnect

- On `wallet_disconnect`, remove the domain from `connectedSites`.

5. Clear wallet clears connections

- When the wallet is cleared in the app (`SettingsView` → `WalletViewModel.clearWallet()`), also remove `connectedSites` from the App Group.

### Extension: Background Service Worker Changes

- Replace local/in-memory connected state with native-backed persistence via the extension native handler.

- Helpers (call native):

  - `stupid_isConnected` → returns boolean for current request domain.
  - `stupid_connectDomain` → persists domain connection (uses saved address).
  - `stupid_disconnectDomain` → removes domain connection.

- Method behavior:

  - `eth_accounts`: if not connected → throw `{ code: 4100, message: "Unauthorized" }`; if connected → forward to native and return.
  - `eth_requestAccounts`:
    - If `stupid_isConnected` → call native (`eth_accounts`/`eth_requestAccounts`) and return (no modal).
    - Else → send `{ pending: true }` to trigger modal; on approval and success, call `stupid_connectDomain`.
  - `wallet_connect`:
    - Extract `capabilities` from `params?.[0]?.capabilities`.
    - If `capabilities` present and has keys → always go pending (modal).
    - Else if `stupid_isConnected` → short-circuit: call native `wallet_connect` (or `eth_accounts`) and return.
    - Else → pending (modal); on approval and success, call `stupid_connectDomain`.
  - `wallet_disconnect`:
    - Call native `wallet_disconnect` and then `stupid_disconnectDomain` (idempotent).

- Cleanup:
  - Remove `connectedDomains` Set and any `browser.storage.local` persistence; rely exclusively on native-backed storage.

### Extension: Injected Provider (`inject.js`)

- Forward the original connect method from the page:
  - In `_requestAccounts`, do not force `"wallet_connect"`; post the incoming `method` unchanged so the background can apply short‑circuit rules.
- Derive connected state from accounts only:
  - Remove mutable `isConnected` writes; optionally expose a getter `get isConnected() { return this.accounts.length > 0; }`.
- Standardize EIP‑1193 error passthrough:
  - Preserve `{ code, message, data }` when rejecting in `_requestAccounts`, `_getAccounts`, and `_handleRequest` (e.g., 4100 Unauthorized from background).
- Minimal state updates:
  - On successful connect, set `accounts` and `selectedAddress`, emit `accountsChanged`.
  - On successful `eth_accounts`, also refresh `accounts`/`selectedAddress` for consistency.
  - Do not persist any connection flags in page context; background/native is source of truth.

### Native Handler (Swift) Changes

- File: `safari/SafariWebExtensionHandler.swift`

- Add helpers using `UserDefaults(suiteName: appGroupId)`:

  - `getConnectedSites() -> [String: [String: Any]]`
  - `isDomainConnected(_ domain: String) -> Bool`
  - `connectDomain(_ domain: String, address: String?)`
  - `disconnectDomain(_ domain: String)`
  - `clearAllConnections()`

- Add native bridge methods exposed over `sendNativeMessage`:

  - `stupid_isConnected`: returns `{"result": true/false}` using `appMetadata.domain`.
  - `stupid_connectDomain`: persists `appMetadata.domain` using saved address (from `walletAddress`).
  - `stupid_disconnectDomain`: removes `appMetadata.domain`.

- Connection side-effects remain driven by background after approval to avoid ambiguity; native exposes persistence operations and continues to handle wallet RPC methods.

### App (Swift) Changes

- File: `ios-wallet/WalletViewModel.swift`

- In `clearWallet()` also remove the `connectedSites` key from App Group `UserDefaults`:

```swift
defaults.removeObject(forKey: "walletAddress")
defaults.removeObject(forKey: "connectedSites")
```

- No UI changes required in `SettingsView`; it already calls `vm.clearWallet()`.

### Security & Privacy

- Store only domain, address, and timestamp. No sensitive secrets are stored.
- Respect origin scoping: connection is specific to the domain extracted from the sender.
- Disconnect and wallet clearing must fully revoke access by removing the domain entry.

### Migration

- If previously used `browser.storage.local` for `connectedDomains`, remove that logic. Optionally, clear the old key on install.
- No migration needed for App Group store; absence of `connectedSites` implies no connections.

### Testing & Acceptance Criteria

- First-time connect (unconnected domain):

  - `eth_requestAccounts` or `wallet_connect` → modal shown; on approve, `connectedSites[domain]` is persisted; response contains account.
  - `eth_accounts` after → returns `[address]`.

- Auto-connect for `eth_requestAccounts`:

  - With `connectedSites[domain]` present → `eth_requestAccounts` resolves immediately (no modal) and returns account(s).

- Auto-connect for `wallet_connect`:

  - When `params[0].capabilities` is absent or `{}` and `connectedSites[domain]` exists → resolves immediately (no modal) with `{ accounts, chainIds }`.
  - When `params[0].capabilities` includes SIWE or other entries → modal shown; on approve, returns capabilities in result; on reject, error.

  - Gating `eth_accounts`:

    - When not connected → throws RPC error `{ code: 4100, message: "Unauthorized" }`.
    - When connected → returns `[address]`.

- Disconnect:

  - Call `wallet_disconnect` → removes `connectedSites[domain]`; subsequent `eth_accounts` throws RPC error `{ code: 4100, message: "Unauthorized" }`.

- App clears wallet:

  - `clearWallet()` removes `walletAddress` and `connectedSites`; subsequent `eth_accounts` throws RPC error `{ code: 4100, message: "Unauthorized" }`; connection modals behave as new session.

- Idempotency:
  - Re-connecting an already-connected domain does not duplicate entries; timestamps may update.

### Rollout

- Ship extension changes and app changes together. The background only calls native bridge methods available in the updated native handler.

### Implementation Plan (Phased)

#### Phase 0: Preparation

- Define shared constants for the App Group keys if needed (e.g., `connectedSites`).
- Align on domain extraction semantics (hostname from `sender.tab.url`/`sender.url`/`sender.frameUrl`).
- Verify App Group access in both app and extension targets.

##### Implementation Notes (Phase 0)

- Shared keys consolidated under `shared/Constants.swift` in `Constants.Storage`:
  - `walletAddressKey` = `"walletAddress"`
  - `chainIdKey` = `"chainId"`
  - `customChainsKey` = `"customChains"`
  - `connectedSitesKey` = `"connectedSites"`
- Background domain extraction verified in `safari/Resources/background.js` using sender fallbacks:
  - Prefers `sender.tab.url`, then `sender.url`, then `sender.frameUrl`
  - Derives `domain`, `url`, `scheme`, and `origin` from the URL
- Entitlements verified:
  - App (`ios-wallet/ios-wallet.entitlements`) and Extension (`safari/safari.entitlements`) include App Group `group.co.za.stephancill.stupid-wallet`
  - Keychain Sharing groups present and aligned with `Constants.accessGroup`
  - `Constants.appGroupId` matches the App Group identifier
- No functional changes were introduced in Phase 0; this phase is preparatory only.

#### Phase 1: Native Handler Persistence API

- File: `safari/SafariWebExtensionHandler.swift`
  - Add helpers using `UserDefaults(suiteName: appGroupId)`:
    - `getConnectedSites() -> [String: [String: Any]]`
    - `isDomainConnected(_ domain: String) -> Bool`
    - `connectDomain(_ domain: String, address: String?)`
    - `disconnectDomain(_ domain: String)`
    - `clearAllConnections()`
  - Extend the message switch to support:
    - `stupid_isConnected` → returns `{"result": Bool}` for current `appMetadata.domain`.
    - `stupid_connectDomain` → persists `appMetadata.domain` with saved address and timestamp.
    - `stupid_disconnectDomain` → removes `appMetadata.domain`.
  - Keep existing RPC handlers unchanged for now; persistence is driven by background after approval.

##### Implementation Notes (Phase 1)

- Persistence uses App Group `UserDefaults` under key `Constants.Storage.connectedSitesKey` ("connectedSites").
- Domains are normalized to lowercase hostnames; each entry stores:
  - `address` (optional): current saved wallet address from `walletAddress`.
  - `connectedAt`: ISO‑8601 timestamp at time of persistence.
- Bridge methods rely on `appMetadata.domain` extracted from the request:
  - `stupid_isConnected` → returns `{ "result": Boolean }`.
  - `stupid_connectDomain` → persists current domain and returns `{ "result": true }`.
  - `stupid_disconnectDomain` → removes current domain and returns `{ "result": true }`.
- Idempotency:
  - Re‑connecting overwrites the entry (updates `connectedAt`), disconnecting a non‑existent domain is a no‑op.
- No behavior changes to existing wallet RPC handlers; background remains responsible for short‑circuit rules in Phase 2.

Acceptance:

- Manual call via background to each `stupid_*` method returns expected results and updates `UserDefaults`. (Deferred to Phase 2)

#### Phase 2: Background Migration and Short-Circuit Rules

- File: `safari/Resources/background.js`
  - Remove `connectedDomains` Set and all `browser.storage.local` logic (`loadConnectionState`, `saveConnectionState`, startup listeners).
  - Add async helpers that call native:
    - `isDomainConnected(siteMetadata)` → `stupid_isConnected`.
    - `persistConnect(siteMetadata)` → `stupid_connectDomain`.
    - `persistDisconnect(siteMetadata)` → `stupid_disconnectDomain`.
  - Update handlers:
    - `eth_accounts`: if `!await isDomainConnected` → throw `{ code: 4100, message: "Unauthorized" }`; else call native and return.
    - `eth_requestAccounts`:
      - If `await isDomainConnected` → short-circuit (no modal): call native (`eth_accounts` or `eth_requestAccounts`) and return.
      - Else → `{ pending: true }`; on approval+success, `await persistConnect`.
    - `wallet_connect`:
      - Inspect `const caps = params?.[0]?.capabilities`.
      - If `caps` present and non-empty → `{ pending: true }` (always modal).
      - Else if `await isDomainConnected` → short-circuit (no modal): call native `wallet_connect` (or `eth_accounts`) and return.
      - Else → `{ pending: true }`; on approval+success, `await persistConnect`.
    - `wallet_disconnect`: call native and `await persistDisconnect` (idempotent).

##### Implementation Notes (Phase 2)

- Background no longer maintains an in-memory `connectedDomains` Set or persists it in `browser.storage.local`. All connection state queries and mutations go through native (`sendNativeMessage`).
- Helpers:
  - `isDomainConnected(siteMetadata)` → calls native `stupid_isConnected` and returns a boolean; if native is unavailable, default to `false` (modal flows will still work).
  - `persistConnect(siteMetadata)` → calls native `stupid_connectDomain` after successful approval of `eth_requestAccounts`/`wallet_connect`; idempotent and updates `connectedAt`.
  - `persistDisconnect(siteMetadata)` → calls native `stupid_disconnectDomain` after `wallet_disconnect`; idempotent and safe if no existing entry.
- Gating `eth_accounts` strictly:
  - When not connected, return an EIP‑1193 RPC error `{ code: 4100, message: "Unauthorized" }` (do not return `[]`). When connected, forward to native and return its result.
- Short-circuit rules:
  - `eth_requestAccounts`: if `isDomainConnected` is true → call native and return immediately (no modal). Otherwise, return `{ pending: true }` and persist on approval.
  - `wallet_connect`: compute `const caps = params?.[0]?.capabilities`. If `caps` is present and has keys → always `{ pending: true }`. Else if `isDomainConnected` is true → call native and return (no modal). Otherwise, `{ pending: true }` and persist on approval.
- Special helper for previews: `stupid_getWalletAddress` may call native `eth_accounts` without connection gating to render pre-connect UI; it does not mutate connection state.
- Error propagation: pass native `{ result }` or `{ error: { code, message, data? } }` through unchanged to the injected provider to preserve EIP‑1193 semantics (e.g., 4100 Unauthorized).
- Startup listeners: remove `onInstalled`/`onStartup` logic that loaded/saved connection state; background now relies solely on native persistence.
- Compatibility: If the native app is older and lacks `stupid_*` methods, treat the site as not connected (show modal). Do not hard-fail.

Acceptance:

- Console traces show short-circuiting paths per rules; no usage of local storage for connections.

#### Phase 2.1: Injected Provider Simplification (`safari/Resources/inject.js`)

- Forward original connect method from page to background:
  - In the provider's connect path (`_requestAccounts`), do not force `"wallet_connect"`; forward the incoming `method` unchanged.
- Derive connected state from accounts:
  - Remove manual writes to `isConnected`; optionally provide a getter `get isConnected() { return this.accounts.length > 0; }`.
- Preserve EIP‑1193 error objects end-to-end:
  - When background returns `{ error: { code, message, data } }`, reject with an Error carrying the same fields in `_requestAccounts`, `_getAccounts`, and `_handleRequest`.
  - This enables 4100 Unauthorized to propagate correctly to dApps for `eth_accounts` when not connected.
- Keep provider state minimal:
  - On successful connect, set `accounts` and `selectedAddress`, and emit `accountsChanged`.
  - On `eth_accounts` success, also refresh `accounts`/`selectedAddress` for consistency.

##### Implementation Notes (Phase 2.1)

- Provider connection state is derived, not stored:
  - Removed mutable writes to `isConnected`.
  - Added a getter: `get isConnected() { return this.accounts.length > 0; }`.
- Connect path forwards original method:
  - `_requestAccounts` posts the incoming `method` unchanged (no forced `"wallet_connect"`).
- Error propagation preserves EIP‑1193 shape end‑to‑end:
  - Introduced `_toError(payloadError)` to convert `{ code, message, data }` into an `Error` while preserving `.code` and `.data`.
  - Used in `_requestAccounts`, `_getAccounts`, and `_handleRequest` so `{ code: 4100, message: "Unauthorized" }` surfaces properly.
- Accounts normalization and state updates:
  - After successful connect (`eth_requestAccounts` or `wallet_connect`), normalize `response.result` to an array of addresses:
    - Accepts either `string[]` or `{ accounts: (string | { address: string })[] }`.
  - Set `this.accounts` and `this.selectedAddress = this.accounts[0] ?? null`, then emit `accountsChanged`.
  - On `eth_accounts`, expect a `string[]`, update `accounts`/`selectedAddress` for consistency.
- Logging hygiene:
  - Replaced `"wallet_connect response"` with a neutral `"connect response"` log message.
- No client‑side persistence of connection flags; background/native remains the source of truth.

Acceptance:

- Manual verifications in a test dApp:
  - Calling `eth_requestAccounts` when already connected resolves immediately without a modal; provider updates `accounts` and emits `accountsChanged`.
  - Calling `wallet_connect` without capabilities when already connected resolves immediately; with capabilities (e.g., SIWE) shows modal.
  - Calling `eth_accounts` when not connected results in a rejected promise with `{ code: 4100, message: "Unauthorized" }`.
  - Provider no longer logs misleading "wallet_connect response" for `eth_requestAccounts`; logs are neutral.

#### Phase 3: App Clearing Behavior

- File: `ios-wallet/WalletViewModel.swift`
  - In `clearWallet()`, also `removeObject(forKey: "connectedSites")` under the App Group.

Acceptance:

- After clearing, subsequent dApp calls behave as unconnected across all domains.

##### Implementation Notes (Phase 3)

- Storage keys live under `shared/Constants.swift` in `Constants.Storage`:
  - `walletAddressKey` = `"walletAddress"`
  - `connectedSitesKey` = `"connectedSites"`
- The app should clear both keys from the App Group store when the user clears their wallet:
  - `UserDefaults(suiteName: appGroupId)?.removeObject(forKey: walletAddressKey)`
  - `UserDefaults(suiteName: appGroupId)?.removeObject(forKey: connectedSitesKey)`
- Idempotency: removing keys that do not exist is a no‑op.
- Side‑effects after clearing:
  - The extension will treat all domains as not connected; `eth_accounts` must return an EIP‑1193 error `{ code: 4100, message: "Unauthorized" }` until the user reconnects.
  - `eth_requestAccounts`/`wallet_connect` will trigger the modal flow again and, upon approval, will repopulate `connectedSites` for that domain via background → native.
- UI: No additional UI beyond the existing `SettingsView` action is required.

#### Phase 4: Documentation and Developer Guidance

- Update `CONTRIBUTING.md` with:
  - Storage key and semantics (`connectedSites`).
  - Auto-connect rules for `eth_requestAccounts` and `wallet_connect` with capabilities.
  - Clearing connections on `wallet_disconnect` and app wallet clear.

Acceptance:

- Docs reflect current behavior and integration points.

#### Phase 5: QA Matrix and Manual Verification

- Scenarios:
  - First-time connect (modal), then auto-connect for `eth_requestAccounts`.
  - `wallet_connect` short-circuits without capabilities; with SIWE capability it shows modal.
  - `eth_accounts` gated by connection presence.
  - `wallet_disconnect` revokes; `eth_accounts` returns `[]` post-disconnect.
  - App `clearWallet()` revokes all domains; subsequent calls behave as new session.
  - Iframe/embedded contexts: domain extraction yields correct hostname.
  - Multi-tab: connection shared across tabs for same domain.

Acceptance:

- All acceptance criteria from the Testing section pass on Simulator.

#### Phase 6: Rollout and Compatibility

- Ship app and extension updates together.
- Graceful degradation: if `stupid_*` native methods are unavailable (older app), the background should default to showing modals (treat as not connected) and avoid persisting connection state.

Acceptance:

- No hard failures when native bridge methods are missing; users can still connect via modal.
