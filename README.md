## stupid wallet

An iOS/macOS SwiftUI wallet app bundled with a Safari Web Extension that injects an EIP-1193 provider and supports multi‑provider discovery via EIP‑6963.

### Features

- **EIP‑1193 provider**: Implements the following methods:
  - `eth_requestAccounts`
  - `eth_accounts`
  - `eth_chainId`
  - `eth_blockNumber`
  - `wallet_addEthereumChain`
  - `wallet_switchEthereumChain`
  - `personal_sign`
  - `eth_signTypedData_v4`
  - `eth_sendTransaction`
  - `wallet_connect`
    - `signInWithEthereum` capability
  - `wallet_disconnect`
  - `wallet_sendCalls`
  - `wallet_getCallsStatus`
- **EIP‑6963 discovery**: Announces provider and re‑announces on request
- **Secure key management**: Encrypts the private key using a [fork of Dawn Key Management](https://github.com/stephancill/dawn-key-management)
- **Balances**: Displays ETH balances on Ethereum, Base, Arbitrum One, and Optimism

### Activity Log

The wallet includes a comprehensive Activity Log that tracks both transactions and signatures:

- **Transactions**: Records all broadcasted transactions (`eth_sendTransaction`, `wallet_sendCalls`) with status polling
- **Signatures**: Logs message signatures (`personal_sign`, `eth_signTypedData_v4`) and SIWE authentication
- **Storage**: SQLite database in shared App Group container with schema versioning and migration support
- **UI**: Unified reverse-chronological view with detailed inspection, copy functionality, and large content handling

See `docs/ActivityLog.md` for transaction logging design and `docs/SignatureLogging.md` for signature logging specification.

## Contributing

Please read `CONTRIBUTING.md` for architecture details, development setup, style guides, and contribution workflow.
