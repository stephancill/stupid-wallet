import { useBaseCurrency } from "@/hooks/use-base-currency";
import { cn } from "@/lib/utils";
import { useState } from "react";

interface EthValueProps {
  /** ETH amount as string (e.g., "1.234567") */
  value: string;
  /** Whether to show "ETH" symbol after the value */
  showSymbol?: boolean;
  /** Additional CSS classes */
  className?: string;
}

/**
 * Displays an ETH value that can be clicked to toggle USD display
 *
 * @example
 * <EthValue value="1.234567" />
 * // Displays: 1.234567 ETH (with dashed underline)
 * // Click to toggle: $2,469.13
 *
 * @example
 * <EthValue value="0.05" showSymbol={false} />
 * // Displays: 0.05 (no toggle if exchange rate unavailable)
 */
export function EthValue({
  value,
  showSymbol = true,
  className,
}: EthValueProps) {
  const { data: currency } = useBaseCurrency();
  const [showUsd, setShowUsd] = useState(false);

  const ethValue = parseFloat(value);
  const usdValue =
    currency && !isNaN(ethValue) ? ethValue * currency.rate : null;
  const formattedUsd =
    usdValue !== null
      ? new Intl.NumberFormat("en-US", {
          style: "currency",
          currency: currency?.symbol,
          minimumFractionDigits: 2,
          maximumFractionDigits: 2,
        }).format(usdValue)
      : null;

  // If no currency data available, just show ETH value without toggle
  if (!formattedUsd) {
    return (
      <span className={className}>
        {value} {showSymbol && "ETH"}
      </span>
    );
  }

  return (
    <button
      type="button"
      onClick={() => setShowUsd(!showUsd)}
      className={cn(
        "border-none bg-transparent p-0 cursor-pointer underline decoration-dashed decoration-muted-foreground/40 hover:decoration-muted-foreground/60 transition-colors",
        className
      )}
      title="Click to toggle currency"
    >
      {showUsd ? formattedUsd : `${value} ${showSymbol ? "ETH" : ""}`}
    </button>
  );
}
