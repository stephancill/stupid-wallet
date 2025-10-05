import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/**
 * Formats value string, removing trailing zeros and unnecessary decimal points
 * @param value - value as string (e.g., from formatUnits)
 * @returns Formatted string with up to 6 decimal places, trailing zeros removed
 */
export function formatValue(value: string): string {
  return parseFloat(value)
    .toFixed(6)
    .replace(/\.?0+$/, "");
}
