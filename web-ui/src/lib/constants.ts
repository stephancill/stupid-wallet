import { arbitrum, base, mainnet, optimism, polygon } from "viem/chains";

export const UI_METHODS = [
  "eth_requestAccounts",
  "wallet_connect",
  "personal_sign",
  "eth_signTypedData_v4",
  "eth_sendTransaction",
  "wallet_sendCalls",
] as const;

export const FAST_METHODS = [
  "eth_accounts",
  "eth_chainId",
  "eth_blockNumber",
  "eth_getTransactionByHash",
  "wallet_addEthereumChain",
  "wallet_switchEthereumChain",
  "wallet_disconnect",
] as const;

// Note: supported methods are also independently declared in
// inject.js and background.js
export const SUPPORTED_METHODS = [...FAST_METHODS, ...UI_METHODS] as const;

const FIRST_PARTY_CHAINS = [
  mainnet.id,
  base.id,
  arbitrum.id,
  optimism.id,
  polygon.id,
];

export const RPC_URLS = FIRST_PARTY_CHAINS.reduce((acc, chainId) => {
  acc[chainId] = import.meta.env[`VITE_RPC_URL_${chainId}`];
  return acc;
}, {} as Record<number, string | undefined>);
