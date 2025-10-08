import { useQuery } from "@tanstack/react-query";
import type { BaseCurrency } from "@/lib/types";

/**
 * Hook to fetch and cache base currency (USD) exchange rate for ETH
 *
 * Features:
 * - Fetches from stupid_getBaseCurrency RPC method
 * - Caches for 5 minutes to minimize RPC calls
 * - Auto-refreshes every 5 minutes
 * - Retries twice on failure
 *
 * @returns React Query result with BaseCurrency data
 */
export function useBaseCurrency() {
  return useQuery({
    queryKey: ["baseCurrency"],
    queryFn: async () => {
      console.log("[useBaseCurrency] Fetching currency rate...");
      const response = await browser.runtime.sendMessage({
        type: "WALLET_REQUEST",
        method: "stupid_getBaseCurrency",
        params: [],
      });
      console.log("[useBaseCurrency] Response:", response);

      if (response.error) {
        console.error("[useBaseCurrency] Error:", response.error);
        throw new Error(response.error);
      }

      return response.result as BaseCurrency;
    },
    staleTime: 5 * 60 * 1000, // 5 minutes
    refetchInterval: 5 * 60 * 1000, // Auto-refresh every 5 minutes
    retry: 2,
  });
}
