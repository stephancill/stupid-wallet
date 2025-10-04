import { RPC_URLS } from "@/lib/constants";
import { whatsabi } from "@shazow/whatsabi";
import { createPublicClient, http, parseAbi } from "viem";
import * as chains from "viem/chains";

export interface ContractABIData {
  abi: any[];
  address: string;
  chainId: number;
  metadata: Awaited<ReturnType<typeof whatsabi.autoload>>["contractResult"];
}

export interface ContractMetadata {
  name?: string;
  symbol?: string;
  decimals?: number;
  isERC20?: boolean;
  isERC721?: boolean;
  isERC1155?: boolean;
}

/**
 * Loads contract ABI using whatsabi
 * @param address Contract address
 * @param chainId Chain ID
 * @returns Contract ABI data
 */
export async function loadContractABI(
  address: string,
  chainId: number
): Promise<ContractABIData> {
  // Get chain object from chainId
  const chain = Object.values(chains).find((c) => c.id === chainId);
  if (!chain) {
    throw new Error(`Unknown chain ID: ${chainId}`);
  }

  const rpcUrl = RPC_URLS[chainId];
  const client = createPublicClient({
    chain,
    transport: http(rpcUrl),
  });

  const etherscanBaseUrl = Object.values(chain?.blockExplorers || {}).find(
    (item) => item.name.includes("scan")
  )?.apiUrl;

  const loaderConfig = whatsabi.loaders.defaultsWithEnv({
    SOURCIFY_CHAIN_ID: chainId.toString(),
    ETHERSCAN_API_KEY: import.meta.env.VITE_ETHERSCAN_API_KEY,
    ETHERSCAN_BASE_URL: etherscanBaseUrl,
  });

  const result = await whatsabi.autoload(address, {
    provider: client,
    ...loaderConfig,
    loadContractResult: true,
  });

  result.contractResult;

  return {
    abi: result.abi,
    address,
    chainId,
    metadata: result.contractResult, // Include metadata for compilation target
  };
}

/**
 * Loads contract metadata (name, symbol, decimals) using multicall
 * @param address Contract address
 * @param chainId Chain ID
 * @returns Contract metadata
 */
export async function loadContractMetadata(
  address: string,
  chainId: number
): Promise<ContractMetadata> {
  // Get chain object from chainId
  const chain = Object.values(chains).find((c) => c.id === chainId);
  if (!chain) {
    throw new Error(`Unknown chain ID: ${chainId}`);
  }

  const rpcUrl = RPC_URLS[chainId];
  const client = createPublicClient({
    chain,
    transport: http(rpcUrl),
  });

  const result: ContractMetadata = {};

  // Token ABI for metadata calls
  const TOKEN_ABI = parseAbi([
    "function name() view returns (string)",
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
  ]);

  const contracts = [
    {
      address: address as `0x${string}`,
      abi: TOKEN_ABI,
      functionName: "name",
    },
    {
      address: address as `0x${string}`,
      abi: TOKEN_ABI,
      functionName: "symbol",
    },
    {
      address: address as `0x${string}`,
      abi: TOKEN_ABI,
      functionName: "decimals",
    },
  ];

  try {
    const results = await client.multicall({
      contracts,
      allowFailure: true,
    });

    const [nameResult, symbolResult, decimalsResult] = results;

    if (nameResult.status === "success" && nameResult.result) {
      result.name = String(nameResult.result);
    }
    if (symbolResult.status === "success" && symbolResult.result) {
      result.symbol = String(symbolResult.result);
    }
    if (decimalsResult.status === "success" && decimalsResult.result) {
      result.decimals = Number(decimalsResult.result);
    }
  } catch {
    // Multicall failed, metadata will remain empty
  }

  // Detect token standard based on available functions
  const hasDecimals = result.decimals !== undefined;
  if (hasDecimals) {
    result.isERC20 = true;
  }

  return result;
}
