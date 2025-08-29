import { useQuery } from "@tanstack/react-query";

export interface ENSData {
  name: string | null;
  avatar: string | null;
}

interface ENSApiResponse {
  address: string;
  ens?: string;
  ens_primary?: string;
  avatar?: string;
  avatar_url?: string;
  error?: boolean;
  status?: number;
  message?: string;
}

export function useENS(address?: string | null): {
  data: ENSData | undefined;
  isLoading: boolean;
  error: Error | null;
} {
  const { data, isLoading, error } = useQuery({
    queryKey: ["ens", address?.toLowerCase()],
    queryFn: async (): Promise<ENSData> => {
      if (!address || !address.startsWith("0x")) {
        return { name: null, avatar: null };
      }

      try {
        const response = await fetch(
          `https://api.ensdata.net/${address.toLowerCase()}`
        );

        if (!response.ok) {
          return { name: null, avatar: null };
        }

        const ensData: ENSApiResponse = await response.json();

        // Check if the response indicates an error or no ENS
        if (ensData.error || (!ensData.ens && !ensData.ens_primary)) {
          return { name: null, avatar: null };
        }

        // Use ens_primary if available, otherwise fall back to ens
        const name = ensData.ens_primary || ensData.ens || null;

        // Use avatar_url if available, otherwise fall back to avatar
        const avatar = ensData.avatar_url || ensData.avatar || null;

        return {
          name,
          avatar,
        };
      } catch {
        return { name: null, avatar: null };
      }
    },
    enabled: Boolean(address?.startsWith("0x")),
    staleTime: 5 * 60 * 1000, // 5 minutes
    gcTime: 10 * 60 * 1000, // 10 minutes
  });

  return {
    data,
    isLoading,
    error: error as Error | null,
  };
}
