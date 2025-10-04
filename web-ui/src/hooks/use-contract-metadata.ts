import {
  loadContractMetadata,
  type ContractMetadata,
} from "@/lib/contract-utils";
import { useQuery } from "@tanstack/react-query";

// Re-export the type for convenience
export type { ContractMetadata };

interface UseContractMetadataOptions {
  address: string | undefined;
  chainId: number | undefined;
  enabled?: boolean;
}

/**
 * Hook to fetch contract metadata (name, symbol, decimals, etc.)
 * Uses multicall to efficiently fetch all metadata in one RPC call
 */
export function useContractMetadata({
  address,
  chainId,
  enabled = true,
}: UseContractMetadataOptions) {
  // Fetch contract metadata using the shared loadContractMetadata function
  const query = useQuery({
    queryKey: ["contract-metadata", chainId, address?.toLowerCase()],
    queryFn: (): Promise<ContractMetadata> => {
      if (!address || !chainId) {
        throw new Error("Address and chainId are required");
      }
      return loadContractMetadata(address, chainId);
    },
    enabled:
      enabled &&
      Boolean(address) &&
      Boolean(chainId) &&
      address?.startsWith("0x") &&
      address?.length === 42,
    staleTime: 30 * 60 * 1000, // 30 minutes - metadata rarely changes
    gcTime: 60 * 60 * 1000, // 1 hour
    retry: 1,
  });

  return query;
}
