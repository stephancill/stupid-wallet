import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/**
 * Formats ETH value string, removing trailing zeros and unnecessary decimal points
 * @param ethValue - ETH value as string (e.g., from formatEther)
 * @returns Formatted string with up to 6 decimal places, trailing zeros removed
 */
export function formatEthValue(ethValue: string): string {
  return parseFloat(ethValue)
    .toFixed(6)
    .replace(/\.?0+$/, "");
}
