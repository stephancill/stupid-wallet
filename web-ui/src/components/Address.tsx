import { useAvatar } from "@/hooks/use-avatar";
import { cn } from "@/lib/utils";
import { ExternalLink } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";

type AddressProps = {
  address: string;
  className?: string;
  mono?: boolean;
  noLink?: boolean;
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
}: AddressProps) {
  const { avatarUrl, ensName, isLoading } = useAvatar(address);

  const avatarElement = avatarUrl ? (
    <img
      src={avatarUrl}
      alt={`${ensName || address} avatar`}
      className="w-[18px] h-[18px] rounded border border-gray-200 flex-shrink-0"
    />
  ) : null;

  // Show skeleton while loading ENS name
  if (isLoading) {
    return (
      <div className={cn("inline-flex items-center gap-2", className)}>
        {avatarElement}
        <Skeleton className="h-4 w-24" />
      </div>
    );
  }

  const displayText = ensName || truncateMiddle(address);
  const shouldUseMono = mono && !ensName;

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
