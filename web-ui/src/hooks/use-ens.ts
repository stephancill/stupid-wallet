import { useQuery } from "@tanstack/react-query";
import { createPublicClient, http } from "viem";
import { mainnet } from "viem/chains";

export interface ENSData {
	name: string | null;
	avatar: string | null;
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

			const client = createPublicClient({
				chain: mainnet,
				transport: http(),
			});

			try {
				const [name, avatar] = await Promise.all([
					client.getEnsName({ address: address as `0x${string}` }),
					client
						.getEnsAvatar({ name: address as `0x${string}` })
						.catch(() => null),
				]);

				// If we got a name, try to get the avatar using the name
				const finalAvatar =
					name && !avatar
						? await client.getEnsAvatar({ name }).catch(() => null)
						: avatar;

				return {
					name,
					avatar: finalAvatar,
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
