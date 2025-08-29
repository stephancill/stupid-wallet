import React from "react";
import Address from "@/components/Address";
import { Skeleton } from "@/components/ui/skeleton";
import { useQuery } from "@tanstack/react-query";
import { createPublicClient, http, hexToNumber } from "viem";
import * as chains from "viem/chains";
import { RequestModal } from "@/components/RequestModal";

type SignTypedDataModalProps = {
  host: string;
  address?: string;
  typedDataJSON: string;
  onApprove: () => void;
  onReject: () => void;
};

function prettyPrint(json: string): string {
  try {
    return JSON.stringify(JSON.parse(json || "{}"), null, 2);
  } catch {
    return json || "";
  }
}

export function SignTypedDataModal({
  host,
  address,
  typedDataJSON,
  onApprove,
  onReject,
}: SignTypedDataModalProps) {
  const pretty = prettyPrint(typedDataJSON);
  const [isSubmitting, setIsSubmitting] = React.useState(false);

  const parsed = React.useMemo(() => {
    try {
      return JSON.parse(typedDataJSON || "{}");
    } catch {
      return null;
    }
  }, [typedDataJSON]);

  type EIP712Types = Record<string, Array<{ name: string; type: string }>>;

  const types = (parsed?.types || {}) as EIP712Types;
  const primaryType = (parsed?.primaryType || "") as string;
  const domain = (parsed?.domain || {}) as Record<string, any>;
  const message = parsed?.message as Record<string, any> | undefined;

  const domainChainId = React.useMemo(() => {
    const cid = domain?.chainId;
    if (cid == null) return null;
    if (typeof cid === "string") {
      try {
        return cid.startsWith("0x")
          ? hexToNumber(cid as `0x${string}`)
          : Number(cid);
      } catch {
        return null;
      }
    }
    if (typeof cid === "number") return cid;
    return null;
  }, [domain]);

  const chain = React.useMemo(() => {
    if (!domainChainId) return undefined;
    return Object.values(chains).find((c: any) => c?.id === domainChainId) as
      | chains.Chain
      | undefined;
  }, [domainChainId]);

  function stringifyWithBigInt(value: unknown) {
    return JSON.stringify(
      value,
      (_, v) => (typeof v === "bigint" ? v.toString() : v),
      2
    );
  }

  const rootFields = React.useMemo(() => {
    if (!primaryType || !types)
      return [] as Array<{ name: string; type: string }>;
    return (types[primaryType] || []) as Array<{ name: string; type: string }>;
  }, [primaryType, types]);

  function baseTypeOf(type: string): { base: string; isArray: boolean } {
    if (type.endsWith("[]")) return { base: type.slice(0, -2), isArray: true };
    return { base: type, isArray: false };
  }

  function collectAddressesFromValue(
    value: any,
    typeName: string,
    acc: Set<string>
  ) {
    const { base, isArray } = baseTypeOf(typeName);
    if (isArray) {
      if (Array.isArray(value)) {
        for (const item of value) collectAddressesFromValue(item, base, acc);
      }
      return;
    }
    if (base === "address") {
      if (typeof value === "string" && value.startsWith("0x")) {
        acc.add(value.toLowerCase());
      }
      return;
    }
    // struct type
    const fields = types?.[base];
    if (fields && value && typeof value === "object") {
      for (const field of fields) {
        collectAddressesFromValue(value[field.name], field.type, acc);
      }
    }
  }

  const uniqueAddresses = React.useMemo(() => {
    const acc = new Set<string>();
    // domain.verifyingContract
    const vc = domain?.verifyingContract;
    if (typeof vc === "string" && vc.startsWith("0x")) {
      acc.add(vc.toLowerCase());
    }
    // traverse message by primaryType
    if (message && primaryType && types?.[primaryType]) {
      for (const field of types[primaryType]) {
        const val = (message as any)?.[field.name];
        collectAddressesFromValue(val, field.type, acc);
      }
    }
    return Array.from(acc);
  }, [domain, message, primaryType, types]);

  const { data: ensMap, isLoading: isEnsLoading } = useQuery({
    queryKey: ["ens-typed", uniqueAddresses],
    queryFn: async () => {
      try {
        if (!uniqueAddresses.length) return {} as Record<string, string | null>;
        const client = createPublicClient({
          chain: chains.mainnet,
          transport: http(),
        });
        const entries = await Promise.all(
          uniqueAddresses.map(async (addr) => {
            try {
              const name = await client.getEnsName({
                address: addr as `0x${string}`,
              });
              return [addr, name] as const;
            } catch {
              return [addr, null] as const;
            }
          })
        );
        const map: Record<string, string | null> = {};
        for (const [addr, name] of entries) map[addr] = name;
        return map;
      } catch {
        return {} as Record<string, string | null>;
      }
    },
    enabled: uniqueAddresses.length > 0,
  });

  const renderAddressLink = (
    address: string,
    className?: string,
    ens?: string | null
  ) => {
    return <Address address={address} className={className} mono />;
  };

  const renderArgValue = (value: any, type?: string) => {
    if (
      type === "address" &&
      typeof value === "string" &&
      value.startsWith("0x")
    ) {
      const name = ensMap?.[value.toLowerCase()] || null;
      return renderAddressLink(value, "font-mono break-all", name);
    }
    if (type === "address[]" && Array.isArray(value)) {
      return (
        <div className="space-y-1">
          {value.map((addr: any, j: number) => {
            if (typeof addr === "string" && addr.startsWith("0x")) {
              const name = ensMap?.[addr.toLowerCase()] || null;
              return (
                <div key={j}>
                  {renderAddressLink(addr, "font-mono break-all", name)}
                </div>
              );
            }
            return <span key={j}>{String(addr)}</span>;
          })}
        </div>
      );
    }
    if (typeof value === "bigint") return value.toString();
    if (typeof value === "string") {
      return value.startsWith("0x") ? (
        <span className="font-mono break-all">{value}</span>
      ) : (
        <span>{value}</span>
      );
    }
    if (Array.isArray(value) || (value && typeof value === "object")) {
      return (
        <pre className="whitespace-pre-wrap break-words">
          {stringifyWithBigInt(value)}
        </pre>
      );
    }
    return <span>{String(value)}</span>;
  };

  const handleApprove = async () => {
    try {
      setIsSubmitting(true);
      await onApprove();
    } finally {
      setIsSubmitting(false);
    }
  };

  const isAggregateLoading = isEnsLoading;
  const controlsDisabled = isSubmitting || isAggregateLoading;

  return (
    <RequestModal
      primaryButtonTitle="Sign"
      onPrimary={handleApprove}
      onReject={onReject}
      isSubmitting={isSubmitting}
      address={address}
    >
      <div aria-busy={isAggregateLoading}>
        <div className="space-y-5">
          <div className="grid grid-cols-[90px_1fr] items-start gap-x-3 gap-y-2 text-sm">
            <div className="text-muted-foreground">Site</div>
            <div className="break-all">
              <div className="font-medium text-foreground">{host}</div>
            </div>
            {primaryType ? (
              <>
                <div className="text-muted-foreground">Primary Type</div>
                <div className="break-all">
                  <div className="font-medium text-foreground">
                    {primaryType}
                  </div>
                </div>
              </>
            ) : null}
          </div>

          {parsed ? (
            <div>
              <div className="text-sm font-medium mb-2">Domain</div>
              <div className="space-y-3">
                {domain?.name ? (
                  <div>
                    <div className="text-muted-foreground text-xs uppercase tracking-wide mb-1">
                      Name
                    </div>
                    <div className="text-foreground">{domain.name}</div>
                  </div>
                ) : null}
                {domain?.version ? (
                  <div>
                    <div className="text-muted-foreground text-xs uppercase tracking-wide mb-1">
                      Version
                    </div>
                    <div className="text-foreground">{domain.version}</div>
                  </div>
                ) : null}
                {domainChainId ? (
                  <div>
                    <div className="text-muted-foreground text-xs uppercase tracking-wide mb-1">
                      Chain
                    </div>
                    <div className="text-foreground">
                      {(chain?.name || "Chain") + " (" + domainChainId + ")"}
                    </div>
                  </div>
                ) : null}
                {isEnsLoading ? (
                  <div>
                    <div className="text-muted-foreground text-xs uppercase tracking-wide mb-1">
                      Verifying Contract
                    </div>
                    <Skeleton className="h-3 w-36" />
                  </div>
                ) : domain?.verifyingContract ? (
                  <div>
                    <div className="text-muted-foreground text-xs uppercase tracking-wide mb-1">
                      Verifying Contract
                    </div>
                    <div>
                      {(() => {
                        const addr = String(domain.verifyingContract);
                        if (addr.startsWith("0x")) {
                          const name = ensMap?.[addr.toLowerCase()] || null;
                          return (
                            <Address
                              address={addr}
                              className="font-mono"
                              mono
                            />
                          );
                        }
                        return <span className="font-mono">{addr}</span>;
                      })()}
                    </div>
                  </div>
                ) : null}
              </div>
            </div>
          ) : null}

          <div>
            <div className="text-sm font-medium mb-2">Message</div>
            {!parsed ? (
              <div className="rounded-md border bg-muted/30 p-3 text-xs font-mono text-foreground break-words whitespace-pre-wrap max-h-[50vh] overflow-auto">
                {pretty}
              </div>
            ) : isEnsLoading ? (
              <Skeleton className="h-20 w-full" />
            ) : rootFields.length > 0 && message ? (
              <div
                className="w-full overflow-y-auto overflow-x-auto"
                style={{
                  WebkitOverflowScrolling: "touch",
                  touchAction: "auto",
                  overscrollBehavior: "contain",
                }}
                data-vaul-no-drag
                onTouchStartCapture={(e) => e.stopPropagation()}
                onTouchMoveCapture={(e) => e.stopPropagation()}
                onPointerDownCapture={(e) => e.stopPropagation()}
                onPointerMoveCapture={(e) => e.stopPropagation()}
              >
                <div className="divide-y divide-border rounded-md border">
                  {rootFields.map((field, i) => {
                    const label = field.name || `arg${i}`;
                    const type = field.type || "unknown";
                    const val = (message as any)?.[field.name];
                    return (
                      <div key={i} className="py-2">
                        <div className="text-[11px] uppercase tracking-wide text-muted-foreground">
                          {label}
                          <span className="ml-1 rounded bg-muted px-1 py-0.5 text-[10px] text-muted-foreground">
                            {type}
                          </span>
                        </div>
                        <div className="mt-1 text-foreground break-words">
                          {renderArgValue(val, type)}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            ) : (
              <pre className="whitespace-pre font-mono text-muted-foreground text-xs">
                {stringifyWithBigInt(message)}
              </pre>
            )}
          </div>
        </div>
      </div>
    </RequestModal>
  );
}
