import Address from "@/components/Address";
import { EthValue } from "@/components/EthValue";
import { Skeleton } from "@/components/ui/skeleton";
import { useContractABI } from "@/hooks/use-contract-abi";
import { useContractMetadata } from "@/hooks/use-contract-metadata";
import { formatValue } from "@/lib/utils";
import { useQuery } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import {
  createPublicClient,
  decodeFunctionData,
  formatEther,
  hexToBigInt,
  http,
  isHex,
} from "viem";
import * as chains from "viem/chains";
import { SquareFunction } from "lucide-react";

interface Call {
  to?: string;
  data?: string;
  value?: string;
}

interface CallDecoderProps {
  call: Call;
  chainId?: number;
  isExpanded?: boolean;
}

function stringifyWithBigInt(value: unknown) {
  return JSON.stringify(
    value,
    (_, v) => (typeof v === "bigint" ? v.toString() : v),
    2
  );
}

export function CallDecoder({
  call,
  chainId,
  isExpanded: externalIsExpanded,
}: CallDecoderProps) {
  const [internalIsExpanded, setInternalIsExpanded] = useState(false);

  // Use external expanded state if provided, otherwise use internal state
  const isExpanded =
    externalIsExpanded !== undefined ? externalIsExpanded : internalIsExpanded;

  const to = call.to || "(contract creation)";
  const dataHex = call.data || "0x";
  const valueEth =
    call.value && isHex(call.value)
      ? formatValue(formatEther(hexToBigInt(call.value)))
      : "0";

  const isValidAddress =
    to &&
    to !== "(contract creation)" &&
    to.startsWith("0x") &&
    to.length === 42;

  // Use shared contract ABI hook
  const {
    abi,
    isLoading: isAbiLoadLoading,
    isError: isAbiLoadError,
  } = useContractABI({
    address: isValidAddress ? to : undefined,
    chainId,
    enabled: Boolean(chainId && isValidAddress),
  });

  // Use shared contract metadata hook to get contract name
  const { data: metadata } = useContractMetadata({
    address: isValidAddress ? to : undefined,
    chainId,
    enabled: Boolean(chainId && isValidAddress),
  });

  const decoded = useMemo(() => {
    if (!dataHex || dataHex === "0x") return null;
    if (!abi) return null;
    try {
      return decodeFunctionData({
        abi,
        data: dataHex as `0x${string}`,
      });
    } catch {
      return null;
    }
  }, [abi, dataHex]);

  const functionItem = useMemo(() => {
    try {
      if (!decoded || !abi) return null;
      const abiArray = (abi || []) as Array<any>;
      const candidates = abiArray.filter(
        (item) =>
          item?.type === "function" && item?.name === decoded.functionName
      );
      if (candidates.length === 0) return null;
      const exact = candidates.find(
        (item) => (item?.inputs?.length || 0) === (decoded.args?.length || 0)
      );
      return exact || candidates[0];
    } catch {
      return null;
    }
  }, [decoded, abi]);

  const addressArgItems = useMemo(() => {
    try {
      if (!functionItem?.inputs || !decoded?.args)
        return [] as Array<{ key: string; address: string }>;
      const items: Array<{ key: string; address: string }> = [];
      functionItem.inputs.forEach((inp: any, i: number) => {
        const type = inp?.type as string | undefined;
        const argVal = (decoded as any)?.args?.[i];
        if (!type) return;
        if (type === "address") {
          if (typeof argVal === "string" && argVal.startsWith("0x")) {
            items.push({ key: `${i}`, address: argVal.toLowerCase() });
          }
        } else if (type === "address[]" && Array.isArray(argVal)) {
          argVal.forEach((addr: any, j: number) => {
            if (typeof addr === "string" && addr.startsWith("0x")) {
              items.push({ key: `${i}.${j}`, address: addr.toLowerCase() });
            }
          });
        }
      });
      return items;
    } catch {
      return [] as Array<{ key: string; address: string }>;
    }
  }, [functionItem, decoded]);

  const uniqueArgAddresses = useMemo(() => {
    return Array.from(new Set(addressArgItems.map((i) => i.address)));
  }, [addressArgItems]);

  const { data: argEnsMap } = useQuery({
    queryKey: ["ensArgNames", uniqueArgAddresses],
    queryFn: async () => {
      try {
        const mainnetClient = createPublicClient({
          chain: chains.mainnet,
          transport: http(),
        });
        const entries = await Promise.all(
          uniqueArgAddresses.map(async (addr) => {
            try {
              const name = await mainnetClient.getEnsName({
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
    enabled: uniqueArgAddresses.length > 0,
  });

  const renderAddressLink = (
    address: string,
    className?: string,
    ens?: string | null
  ) => {
    return (
      <Address address={address} chainId={chainId} className={className} mono />
    );
  };

  const renderArgValue = (value: any, type?: string) => {
    if (
      type === "address" &&
      typeof value === "string" &&
      value.startsWith("0x")
    ) {
      const name = argEnsMap?.[value.toLowerCase()] || null;
      return renderAddressLink(value, "font-mono break-all", name);
    }
    if (type === "address[]" && Array.isArray(value)) {
      return (
        <div className="space-y-1">
          {value.map((addr: any, j: number) => {
            if (typeof addr === "string" && addr.startsWith("0x")) {
              const name = argEnsMap?.[addr.toLowerCase()] || null;
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

  // Simplified view component
  const SimplifiedView = () => (
    <div className="text-xs bg-muted p-3 rounded">
      <div className="space-y-1">
        <div className="flex items-center gap-2 flex-wrap">
          <div className="flex items-center gap-2 min-w-0">
            <span className="text-sm inline-flex items-center">
              {typeof to === "string" && to.startsWith("0x") ? (
                <Address address={to} chainId={chainId} showContractName />
              ) : (
                <span className="font-mono">{to}</span>
              )}
            </span>
            {metadata?.name && (
              <span className="text-xs text-muted-foreground inline-flex items-center">
                ({metadata.name})
              </span>
            )}
          </div>
          {valueEth !== "0" && (
            <>
              <span className="text-muted-foreground inline-flex items-center">
                •
              </span>
              <span className="font-medium text-sm inline-flex items-center">
                <EthValue value={valueEth} />
              </span>
            </>
          )}
        </div>
        {decoded && (
          <div className="font-medium text-sm text-foreground flex items-baseline gap-1.5">
            <SquareFunction className="w-3.5 h-3.5 text-muted-foreground flex-shrink-0 inline-block align-text-bottom" />
            {decoded.functionName}
          </div>
        )}
      </div>
    </div>
  );

  // Full view component (existing content)
  const FullView = () => (
    <div className="space-y-2 bg-muted p-3 rounded">
      {/* Call summary */}
      <div className="grid grid-cols-[60px_1fr] gap-x-2 gap-y-1 text-sm">
        <div className="text-muted-foreground">To</div>
        <div className="font-mono break-all">
          {typeof to === "string" && to.startsWith("0x") ? (
            <Address address={to} chainId={chainId} showContractName />
          ) : (
            to
          )}{" "}
          {metadata?.name ? `(${metadata.name})` : null}
        </div>
        <div className="text-muted-foreground">Value</div>
        <div>
          <EthValue value={valueEth} />
        </div>
        <div className="text-muted-foreground">Data</div>
      </div>

      {/* Decoded function call */}
      <div>
        {isAbiLoadLoading ? (
          <div className="space-y-2">
            <Skeleton className="h-3 w-full" />
            <Skeleton className="h-12 w-full" />
          </div>
        ) : decoded ? (
          <>
            <div className="text-sm flex items-baseline gap-1.5">
              <SquareFunction className="w-3.5 h-3.5 text-muted-foreground flex-shrink-0 inline-block align-text-bottom" />
              <span className="font-medium text-foreground">
                {decoded.functionName}
              </span>
              <span className="text-muted-foreground">
                {"("}
                {(functionItem?.inputs || [])
                  .map((inp: any, i: number) =>
                    [inp?.type || "unknown", inp?.name || `arg${i}`].join(" ")
                  )
                  .join(", ")}
                {")"}
              </span>
            </div>
            <div className="bg-muted rounded-md">
              {(functionItem?.inputs?.length || 0) > 0 && (
                <div className="divide-y divide-border rounded-md border gap-2">
                  {(decoded.args || []).map((arg: any, i: number) => {
                    const input = (functionItem?.inputs as any)?.[i] || {};
                    const label = input?.name || `arg${i}`;
                    const type = input?.type || "unknown";
                    return (
                      <div key={i}>
                        <div className="text-[11px] uppercase tracking-wide text-muted-foreground">
                          {label}
                          <span className="ml-1 rounded bg-muted px-1 py-0.5 text-[10px] text-muted-foreground">
                            {type}
                          </span>
                        </div>
                        <div className="mt-1 text-xs text-foreground break-words">
                          {renderArgValue(arg, type)}
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
            </div>
          </>
        ) : dataHex !== "0x" ? (
          <div>
            <pre className="whitespace-pre-wrap font-mono break-words text-xs py-2 border rounded max-h-32 bg-muted">
              {dataHex}
            </pre>
          </div>
        ) : null}
      </div>
    </div>
  );

  return isExpanded ? <FullView /> : <SimplifiedView />;
}
