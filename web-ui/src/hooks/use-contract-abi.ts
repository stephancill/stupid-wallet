import type { ContractABIData } from "@/lib/contract-utils";
import { loadContractABI } from "@/lib/contract-utils";
import { useQuery } from "@tanstack/react-query";

interface UseContractABIOptions {
  address: string | undefined;
  chainId: number | undefined;
  enabled?: boolean;
}

/**
 * Hook to fetch and cache contract ABI using whatsabi
 * Uses React Query to prevent duplicate requests across components
 */
export function useContractABI({
  address,
  chainId,
  enabled = true,
}: UseContractABIOptions) {
  const query = useQuery({
    queryKey: ["contract-abi", chainId, address?.toLowerCase()],
    queryFn: async (): Promise<ContractABIData> => {
      if (!address || !chainId) {
        throw new Error("Address and chainId are required");
      }

      return loadContractABI(address, chainId);
    },
    enabled:
      enabled &&
      Boolean(address) &&
      Boolean(chainId) &&
      address?.startsWith("0x") &&
      address?.length === 42,
    staleTime: 30 * 60 * 1000, // 30 minutes - ABIs rarely change
    gcTime: 60 * 60 * 1000, // 1 hour
    retry: 1, // Retry once on failure
  });

  return {
    abi: query.data?.abi,
    data: query.data,
    isLoading: query.isLoading,
    isError: query.isError,
    error: query.error,
  };
}
