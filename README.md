## iOS Wallet with Safari Web Extension

An iOS SwiftUI wallet app bundled with a Safari Web Extension that injects an EIP-1193 provider and supports multi‑provider discovery via EIP‑6963. The app manages a private key using Dawn Key Management (Secure Enclave + Keychain) and fetches balances via Web3.swift.

### Features

- **EIP‑1193 provider**: Implements `eth_requestAccounts` and `eth_accounts` for DApps
- **EIP‑6963 discovery**: Announces provider and re‑announces on request
- **Secure key management**: Encrypts the private key using Dawn Key Management
- **Balances**: Displays ETH balances on Ethereum, Base, Arbitrum One, and Optimism

## Contributing

Please read `CONTRIBUTING.md` for architecture details, development setup, style guides, and contribution workflow.
