export const UI_METHODS = [
  "eth_requestAccounts",
  "wallet_connect",
  "personal_sign",
  "eth_signTypedData_v4",
  "eth_sendTransaction",
] as const;

export const FAST_METHODS = [
  "eth_accounts",
  "eth_chainId",
  "eth_blockNumber",
  "wallet_addEthereumChain",
  "wallet_switchEthereumChain",
] as const;

// Note: supported methods are also independently declared in
// inject.js and background.js
export const SUPPORTED_METHODS = [...FAST_METHODS, UI_METHODS] as const;
