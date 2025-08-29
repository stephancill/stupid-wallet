## Contributing to stupid wallet

Thank you for your interest in contributing! This project is a stupid wallet app with a Safari Web Extension that injects an EIP-1193 provider and supports multi-provider discovery via EIP-6963. This document explains the architecture, how to set up your environment, and how to submit contributions.

### Architecture Overview

- **App (SwiftUI)**

  - **UI**: `ios-wallet/ContentView.swift` implements a minimal wallet UI.
  - **Key management**: Uses Dawn Key Management to encrypt and store the private key using Secure Enclave + Keychain.
  - **RPC + balances**: Uses Web3.swift (+ PromiseKit) to query balances on multiple networks.
  - **Shared storage**: Persists values in an App Group `UserDefaults` for the Safari extension to read:
    - `walletAddress` (checksummed address)
    - `chainId` (current chain as hex, e.g. `0x1`)
    - `customChains` (dictionary keyed by hex chainId containing chain metadata and optional `rpcUrls`)

- **Safari Web Extension** (`safari/`)
  - **Injected provider (main world)**: `safari/Resources/inject.js`
    - EIP-1193 provider with supported methods:
      - `eth_requestAccounts`, `eth_accounts`
      - `eth_chainId`, `eth_blockNumber`
      - `wallet_addEthereumChain`, `wallet_switchEthereumChain`
      - `personal_sign`, `eth_signTypedData_v4`
      - `eth_sendTransaction`
    - Emits `accountsChanged` and `chainChanged` where applicable.
    - EIP-6963 provider discovery: announces via `eip6963:announceProvider` and responds to `eip6963:requestProvider`.
    - Communicates with the extension via `window.postMessage` to avoid restricted APIs in the main world.
  - **Content script (isolated world)**: built bundle at `safari/Resources/dist/content.iife.js`
    - Source lives in `web-ui/src/main.tsx` and is bundled via Vite.
    - Bridges between the injected provider and the background service worker using `web-ui/src/bridge.ts` for fast methods and `web-ui/src/App.tsx` for UI flows.
    - Presents in-page modals using React + shadcn/ui (Credenza) mounted within a Shadow DOM for consented flows:
      - Connect (`eth_requestAccounts`)
      - Message signing (`personal_sign`)
      - Typed data signing (`eth_signTypedData_v4`)
      - Transaction sending (`eth_sendTransaction`)
  - **Background (service worker)**: `safari/Resources/background.js`
    - Receives wallet requests, routes to native handler, or responds immediately when trivial.
    - Implements a pending → confirm handshake for consented flows (connect, sign, typed data, send tx).
    - Supports routing for the methods listed above and falls back to safe defaults when native is unavailable.
  - **Native handler (Swift)**: `safari/SafariWebExtensionHandler.swift`
    - Implements:
      - Accounts and network: `eth_requestAccounts`, `eth_accounts`, `eth_chainId`, `eth_blockNumber`.
      - Chains: `wallet_addEthereumChain` (persists metadata under `customChains`), `wallet_switchEthereumChain` (updates `chainId`).
      - Signing: `personal_sign` (EIP-191), `eth_signTypedData_v4` (EIP-712) — uses Dawn Key Management to sign digests without exporting keys.
      - Transactions: `eth_sendTransaction` — builds legacy or EIP-1559 transactions, signs, and broadcasts via Web3.swift.

### Data Flow

- **DApp → Provider**: DApp calls `window.ethereum.request({ method })`.
- **EIP‑6963**: Provider announces over window events; DApps can discover this provider without clobbering `window.ethereum`.
- **Request path**:
  1. Injected provider posts a message to the window (`stupid-wallet-inject`).
  2. Content script relays to background via `browser.runtime.sendMessage`.
  3. Background queries native/handler (or shared storage) and returns the result; for consented flows it first replies `{ pending: true }`.
  4. On `{ pending: true }`, the content script displays a modal and then sends a `WALLET_CONFIRM` to background; background finalizes by calling native and returns `{ result }` or `{ error }`.
  5. Content script posts the final response back to the injected provider, which resolves the original request.

### Code Layout

- **iOS App**

  - `ios-wallet/ContentView.swift`: UI, persistence, and balance fetching.
  - `ios-wallet/ios_walletApp.swift`: App entry point.

- **Safari Extension**

  - `safari/SafariWebExtensionHandler.swift`: Native handler for web extension requests.
  - `safari/Resources/inject.js`: EIP-1193 provider + EIP-6963 discovery.
  - `safari/Resources/dist/content.iife.js`: Built content script bundle (do not edit).
  - `safari/Resources/background.js`: Service worker handling wallet requests.
  - `safari/Resources/manifest.json`: MV3 manifest.

- **Web UI (React/Vite)**
  - `web-ui/src/main.tsx`: TypeScript content script entry point and Shadow DOM initialization.
  - `web-ui/src/bridge.ts`: Lightweight bridge for fast EIP-1193 methods (accounts, chainId, blockNumber, chain switching).
  - `web-ui/src/App.tsx`: React app component orchestrating modal flows and pending → confirm handshakes.
  - `web-ui/src/shadowHost.ts`: Creates Shadow DOM host, injects Tailwind CSS, and manages portal routing.
  - `web-ui/src/components/RequestModal.tsx`: Shared modal wrapper using shadcn/ui Credenza (responsive Dialog/Drawer).
  - `web-ui/src/components/Providers.tsx`: React context providers (React Query client).
  - `web-ui/src/components/*Modal.tsx`: Individual modal components for each wallet flow (Connect, SignMessage, SignTypedData, SendTx).
  - `web-ui/src/components/ui/*`: Generated shadcn/ui components (button, dialog, drawer, credenza, skeleton, scroll-box).
  - `web-ui/src/playground.tsx`: Development playground for testing modal components independently.
  - `web-ui/src/index.css` and `web-ui/src/shadow.css`: Tailwind v4 styles and design tokens (inlined into shadow root).
  - Output directory is `safari/Resources/dist/` with file `content.iife.js`.

### Prerequisites

- Xcode 15+
- iOS 17+ SDK
- Swift Package dependencies (resolved by Xcode):
  - Web3.swift (`Web3`, `Web3PromiseKit`)
  - PromiseKit
  - Dawn Key Management
- Bun (for web-ui tooling) — `curl -fsSL https://bun.sh/install | bash`
- Node.js 18+ (Bun provides faster builds and better TypeScript support for the web-ui)

### Local Setup

- **Clone** the repo and open `ios-wallet.xcodeproj` in Xcode.
- **Enable capabilities (both app and extension targets):**
  - App Groups: create/use an App Group and set it in code (default: `group.co.za.stephancill.stupid-wallet`).
  - Keychain Sharing: required by Dawn Key Management.
- **Update code constants** if you use a different App Group:

  - In `ContentView.swift`: `appGroupId`.
  - In `SafariWebExtensionHandler.swift`: `appGroupId`.
  - In `shared/Constants.swift`: `Constants.accessGroup` — set to your Keychain Access Group and make sure the same group is present in both `ios-wallet/ios-wallet.entitlements` and `safari/safari.entitlements` under Keychain Sharing.

- **Web UI setup (Vite + Tailwind v4 + shadcn/ui):**

  ```bash
  cd web-ui
  bun install
  # dev playground for testing modal components (optional)
  bun run dev
  # build the content script bundle to safari/Resources/dist/content.iife.js
  bun run build
  ```

  **Development workflow:**

  - The dev server runs on port 5173 and provides a playground at `index.html` for testing modal components independently
  - Use `web-ui/src/playground.tsx` to interactively test Connect, Sign Message, Sign Typed Data, and Send Transaction modals
  - The playground mounts modals in Shadow DOM just like the production extension
  - Build output is automatically placed in `safari/Resources/dist/content.iife.js`
  - Xcode build process includes a Run Script phase that runs `bun run build` automatically
  - Files under `safari/Resources/**` are bundled into the Safari extension
  - UI components follow shadcn/ui conventions (configured in `components.json` with "new-york" style and CSS variables)

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
  - The web UI is built automatically by an Xcode Run Script phase. If needed, you can still run `bun run build` manually.

### Adding Features

- **EIP‑1193 methods**

  - Injected provider: add a `case` handler in `inject.js` → route via postMessage.
  - Content script: if the method requires user consent, implement a modal in `web-ui/src/components/*` and wire the pending → confirm flow in `web-ui/src/App.tsx`.
  - Background: add a handler in `background.js` and forward to native if needed; for consented flows, send `{ pending: true }` first and handle `WALLET_CONFIRM`.
  - Native handler: implement the method in `SafariWebExtensionHandler.swift` and return `{ result }` or `{ error }`.
  - Update docs of supported methods below as needed.

- **Balances / Networks**

  - Add network RPC URL and call `web3.eth.getBalance` in `ContentView.swift`.
  - Keep UI responsive; prefer `Task` and async/await bridging for PromiseKit results.

- **Key Management**

  - Use Dawn Wallet Key Management for any operations involving private key access.
  - Ensure any new signing flows request consent and never expose the raw private key to the page.

- **Web UI / Modals**
  - Modals are React components using shadcn/ui Credenza (responsive Dialog/Drawer) and render inside a Shadow DOM.
  - Edit `web-ui/src/components/RequestModal.tsx` (shared wrapper) and specific modal components; ensure to keep `onOpenChange` rejecting on dismiss.
  - Use `web-ui/src/playground.tsx` for development and testing of modal components.
  - Shadow DOM styling is isolated; Tailwind v4 tokens are provided via CSS variables injected in `shadowHost.ts`.

### Security Considerations

- Do not inject privileged APIs into the page; use postMessage bridges.
- Freeze provider detail objects when announcing via EIP-6963.
- Supported today: `eth_requestAccounts`, `eth_accounts`, `eth_chainId`, `eth_blockNumber`, `wallet_addEthereumChain`, `wallet_switchEthereumChain`, `personal_sign`, `eth_signTypedData_v4`, `eth_sendTransaction`. Prefer keeping the surface minimal and consented.
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
- If modals render unstyled: make sure you rebuilt `web-ui` and that the Shadow DOM variables are injected (see `shadowHost.ts`).
- If you see `ReferenceError: process` from third‑party code in the content script, the Vite config defines `process.env`/`global` shims; ensure you’re using the repo’s `web-ui/vite.config.ts`.
- If Xcode shows script sandbox denials when building the web‑ui: either disable `ENABLE_USER_SCRIPT_SANDBOXING` for the `safari` target, or add proper Input/Output file lists to the Run Script phase.

### Roadmap

- Expand EIP‑1193 support (signing, transactions).
- Implement explicit user consent flows in the native app for `eth_requestAccounts` and signing.
- Improve native↔︎extension messaging ergonomics.

Thanks again for contributing!
