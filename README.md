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
- **EIP‑6963 discovery**: Announces provider and re‑announces on request
- **Secure key management**: Encrypts the private key using a [fork of Dawn Key Management](https://github.com/stephancill/dawn-key-management)
- **Balances**: Displays ETH balances on Ethereum, Base, Arbitrum One, and Optimism

## Contributing

Please read `CONTRIBUTING.md` for architecture details, development setup, style guides, and contribution workflow.
