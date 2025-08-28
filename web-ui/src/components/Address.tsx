import React from "react";
import { createIcon } from "@download/blockies";
import { ExternalLink } from "lucide-react";
import { cn } from "@/lib/utils";

type AddressProps = {
  address: string;
  className?: string;
  mono?: boolean;
  withEnsNameAbove?: string | null;
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
  withEnsNameAbove,
  noLink = false,
}: AddressProps) {
  const ref = React.useRef<HTMLSpanElement | null>(null);

  React.useEffect(() => {
    if (!address || typeof address !== "string" || !address.startsWith("0x"))
      return;
    const canvas = createIcon({
      seed: address.toLowerCase(),
      size: 6,
      scale: 3,
    });
    canvas.style.borderRadius = "4px";
    canvas.style.flex = "0 0 auto";
    const host = ref.current;
    if (host) {
      // Clear previous icon on rerenders
      while (host.firstChild) host.removeChild(host.firstChild);
      host.appendChild(canvas);
    }
    return () => {
      if (host && canvas && canvas.parentNode === host)
        host.removeChild(canvas);
    };
  }, [address]);

  const content = noLink ? (
    <span className={cn("inline-flex items-center gap-2", className)}>
      <span ref={ref} aria-hidden="true" />
      <span className={cn(mono ? "font-mono" : undefined, "break-all")}>
        {truncateMiddle(address)}
      </span>
    </span>
  ) : (
    <a
      href={`https://blockscan.com/address/${address}`}
      target="_blank"
      rel="noopener noreferrer"
      className={cn("inline-flex items-center gap-2", className)}
    >
      <span ref={ref} aria-hidden="true" />
      <span className={cn(mono ? "font-mono" : undefined, "break-all")}>
        {truncateMiddle(address)}
      </span>
      <ExternalLink className="h-3 w-3 opacity-60 flex-shrink-0" />
    </a>
  );

  if (withEnsNameAbove) {
    return (
      <div>
        <div className="text-foreground">{withEnsNameAbove}</div>
        <div
          className={cn(
            mono ? "font-mono" : undefined,
            "text-muted-foreground break-all"
          )}
        >
          {content}
        </div>
      </div>
    );
  }

  return content;
}

export default Address;
