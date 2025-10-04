import { Skeleton } from "@/components/ui/skeleton";
import { useAvatar } from "@/hooks/use-avatar";
import { useContractABI } from "@/hooks/use-contract-abi";
import { useContractMetadata } from "@/hooks/use-contract-metadata";
import { cn } from "@/lib/utils";
import { ExternalLink } from "lucide-react";

type AddressProps = {
  address: string;
  className?: string;
  mono?: boolean;
  noLink?: boolean;
  chainId?: number;
  showContractName?: boolean;
};

function truncateMiddle(value: string, head = 6, tail = 4): string {
  if (!value) return value;
  if (value.length <= head + tail + 1) return value;
  return `${value.slice(0, head)}…${value.slice(-tail)}`;
}

export function Address({
  address,
  className,
  mono,
  noLink = false,
  chainId,
  showContractName = true,
}: AddressProps) {
  const { avatarUrl, ensName, isLoading: isLoadingENS } = useAvatar(address);

  const { data: abiData, isLoading: isLoadingABI } = useContractABI({
    address,
    chainId,
    enabled: showContractName && !!chainId,
  });

  const { data: metadata, isLoading: isLoadingMetadata } = useContractMetadata({
    address,
    chainId,
    enabled: showContractName && !!chainId,
  });

  const avatarElement = avatarUrl ? (
    <img
      src={avatarUrl}
      alt={`${ensName || address} avatar`}
      className="w-[18px] h-[18px] rounded border border-gray-200 flex-shrink-0"
    />
  ) : null;

  const isLoading =
    isLoadingENS || (showContractName && (isLoadingABI || isLoadingMetadata));

  // Show skeleton while loading ENS name, ABI, or contract metadata
  if (isLoading) {
    return (
      <div className={cn("inline-flex items-center gap-2", className)}>
        {avatarElement}
        <Skeleton className="h-4 w-24" />
      </div>
    );
  }

  // Priority: ENS name > Token symbol > Compilation target name > Contract name > Truncated address
  const truncatedAddress = truncateMiddle(address);
  let displayText = ensName || truncatedAddress;
  if (!ensName && showContractName) {
    if (metadata?.symbol) {
      displayText = metadata.symbol;
    } else if (metadata?.name) {
      displayText = metadata.name;
    } else if (abiData?.metadata?.name) {
      displayText = abiData?.metadata?.name;
    }
  }

  console.log("displayText", displayText, {
    address,
    ensName,
    showContractName,
    metadata,
    abiData,
  });

  const shouldUseMono = mono;

  const content = noLink ? (
    <span className={cn("inline-flex items-center gap-2", className)}>
      {avatarElement}
      <span
        className={cn(shouldUseMono ? "font-mono" : undefined, "break-all")}
      >
        {displayText}
      </span>
    </span>
  ) : (
    <a
      href={`https://blockscan.com/address/${address}`}
      target="_blank"
      rel="noopener noreferrer"
      className={cn("inline-flex items-center gap-2", className)}
    >
      {avatarElement}
      <span
        className={cn(shouldUseMono ? "font-mono" : undefined, "break-all")}
      >
        {displayText}
      </span>
      <ExternalLink className="h-3 w-3 opacity-60 flex-shrink-0" />
    </a>
  );

  return content;
}

export default Address;
