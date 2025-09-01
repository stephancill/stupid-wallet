import { useMemo } from "react";
// @ts-ignore - Module has no type declarations
import { createIcon } from "@download/blockies";
import { useENS } from "./use-ens";

export function useAvatar(address: string) {
  const { data: ensData, isLoading } = useENS(address);

  const avatarUrl = useMemo(() => {
    // If we have an ENS avatar, use it
    if (ensData?.avatar) {
      return ensData.avatar;
    }

    // Otherwise, generate blockies as a data URL
    if (!address || typeof address !== "string" || !address.startsWith("0x")) {
      return null;
    }

    try {
      const canvas = createIcon({
        seed: address.toLowerCase(),
        size: 6,
        scale: 3,
      });

      // Convert canvas to data URL
      return canvas.toDataURL();
    } catch (error) {
      console.warn("Failed to generate blockies:", error);
      return null;
    }
  }, [address, ensData?.avatar]);

  return {
    avatarUrl,
    ensName: ensData?.name,
    isLoading,
  };
}
