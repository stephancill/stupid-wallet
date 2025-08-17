## Contributing to ios-wallet

Thank you for your interest in contributing! This project is an iOS Wallet app with a Safari Web Extension that injects an EIP-1193 provider and supports multi-provider discovery via EIP-6963. This document explains the architecture, how to set up your environment, and how to submit contributions.

### Architecture Overview

- **App (SwiftUI)**

  - **UI**: `ios-wallet/ContentView.swift` implements a minimal wallet UI.
  - **Key management**: Uses Dawn Key Management to encrypt and store the private key using Secure Enclave + Keychain.
  - **RPC + balances**: Uses Web3.swift (+ PromiseKit) to query balances on multiple networks.
  - **Shared storage**: Persists the selected address in an App Group `UserDefaults` for the Safari extension to read.

- **Safari Web Extension** (`safari/`)
  - **Injected provider (main world)**: `safari/Resources/inject.js`
    - EIP-1193 provider with basic methods: `eth_requestAccounts` and `eth_accounts`.
    - EIP-6963 provider discovery: announces via `eip6963:announceProvider` and responds to `eip6963:requestProvider`.
    - Communicates with the extension via `window.postMessage` to avoid restricted APIs in the main world.
  - **Content script (isolated world)**: `safari/Resources/content.js`
    - Bridge between the injected provider and the background service worker.
    - Listens for page messages and forwards them via `browser.runtime.sendMessage`.
  - **Background (service worker)**: `safari/Resources/background.js`
    - Receives wallet requests and attempts to fetch accounts from native/handler.
    - Currently returns the saved address via native handler or falls back to empty array.
  - **Native handler (Swift)**: `safari/SafariWebExtensionHandler.swift`
    - Responds to extension requests by reading the persisted address from the shared App Group.
    - Implements `eth_requestAccounts` and `eth_accounts` (mock consent flow; real consent TBD).

### Data Flow

- **DApp → Provider**: DApp calls `window.ethereum.request({ method })`.
- **EIP‑6963**: Provider announces over window events; DApps can discover this provider without clobbering `window.ethereum`.
- **Request path**:
  1. Injected provider posts a message to the window (`ios-wallet-inject`).
  2. Content script listens and forwards to background via `browser.runtime.sendMessage`.
  3. Background queries native/handler (or shared storage) and returns the result to content script.
  4. Content script posts the response back to the injected provider, which resolves the original request.

### Code Layout

- **iOS App**

  - `ios-wallet/ContentView.swift`: UI, persistence, and balance fetching.
  - `ios-wallet/ios_walletApp.swift`: App entry point.

- **Safari Extension**
  - `safari/SafariWebExtensionHandler.swift`: Native handler for web extension requests.
  - `safari/Resources/inject.js`: EIP-1193 provider + EIP-6963 discovery.
  - `safari/Resources/content.js`: Bridge between page and background.
  - `safari/Resources/background.js`: Service worker handling wallet requests.
  - `safari/Resources/manifest.json`: MV3 manifest.

### Prerequisites

- Xcode 15+
- iOS 17+ SDK
- Swift Package dependencies (resolved by Xcode):
  - Web3.swift (`Web3`, `Web3PromiseKit`)
  - PromiseKit
  - Dawn Key Management
  - BigInt

### Local Setup

- **Clone** the repo and open `ios-wallet.xcodeproj` in Xcode.
- **Enable capabilities (both app and extension targets):**
  - App Groups: create/use an App Group and set it in code (default: `group.co.za.stephancill.ios-wallet`).
  - Keychain Sharing: required by Dawn Key Management.
- **Update code constants** if you use a different App Group:
  - In `ContentView.swift`: `appGroupId`.
  - In `SafariWebExtensionHandler.swift`: `appGroupId`.

### Build and Run

- From Terminal (simulator build):

```bash
cd ios-wallet
set -o pipefail
xcodebuild -scheme ios-wallet -configuration Debug -destination 'generic/platform=iOS Simulator' build | xcpretty
```

- From Xcode:
  - Select the `ios-wallet` scheme.
  - Choose an iOS Simulator and Run.
  - To run the Safari extension, enable Safari Web Extensions in Settings (iOS Simulator) and activate the extension in Safari.

### Adding Features

- **EIP‑1193 methods**

  - Injected provider: add a `case` handler in `inject.js` → route via postMessage.
  - Content script: no change unless adding new message types.
  - Background: add a handler in `background.js` and forward to native if needed.
  - Native handler: implement the method in `SafariWebExtensionHandler.swift` and return `{ result }` or `{ error }`.

- **Balances / Networks**

  - Add network RPC URL and call `web3.eth.getBalance` in `ContentView.swift`.
  - Keep UI responsive; prefer `Task` and async/await bridging for PromiseKit results.

- **Key Management**
  - Use Dawn Wallet Key Management for any operations involving private key access.
  - Ensure any new signing flows request consent and never expose the raw private key to the page.

### Security Considerations

- Do not inject privileged APIs into the page; use postMessage bridges.
- Freeze provider detail objects when announcing via EIP-6963.
- Only implement the minimum required provider surface (currently `eth_requestAccounts`, `eth_accounts`).
- Never log sensitive data (private keys, seeds, decrypted material).

### Style Guidelines

- **Swift**

  - Prefer clear naming and explicit types on public APIs.
  - Use guard/early returns and avoid deep nesting.
  - Keep UI code simple and state-driven with `@StateObject`/`@Published`.

- **JavaScript**
  - Keep provider implementation minimal and standards-compliant.
  - Avoid global pollution; encapsulate in IIFE.
  - Use strict mode and avoid deprecated APIs (prefer `request` over `send`).

### Submitting Changes

- **Issues**: Open an issue describing the problem or proposal before large changes.
- **Branches**: Use feature branches (e.g., `feat/eip1193-sign`, `fix/accounts-timeout`).
- **Commits**: Keep commits small and descriptive. Reference issues if applicable.
- **PRs**: Provide a concise description, screenshots/logs if UI/behavior changes. Note any security implications.
- **Checks**: Ensure the app builds for iOS Simulator and the extension loads without console errors.

### Troubleshooting

- If simulator build fails due to provisioning: ensure you selected an iOS Simulator destination and not a device.
- If balances don’t load: verify RPC endpoints and network connectivity.
- If the provider doesn’t appear in a DApp: check the console logs in the page, content script, and background.

### Roadmap

- Expand EIP‑1193 support (signing, transactions).
- Implement explicit user consent flows in the native app for `eth_requestAccounts` and signing.
- Improve native↔︎extension messaging ergonomics.

Thanks again for contributing!
