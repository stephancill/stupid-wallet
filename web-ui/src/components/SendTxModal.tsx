import Address from "@/components/Address";
import { Skeleton } from "@/components/ui/skeleton";
import { whatsabi } from "@shazow/whatsabi";
import { useQuery } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import {
  createPublicClient,
  decodeFunctionData,
  formatEther,
  hexToBigInt,
  hexToNumber,
  http,
  isHex,
} from "viem";
import * as chains from "viem/chains";
import { RequestModal } from "@/components/RequestModal";

function stringifyWithBigInt(value: unknown) {
  return JSON.stringify(
    value,
    (_, v) => (typeof v === "bigint" ? v.toString() : v),
    2
  );
}

type SendTxModalProps = {
  host: string;
  tx: Record<string, any>;
  onApprove: () => void;
  onReject: () => void;
};

export function SendTxModal({
  host,
  tx,
  onApprove,
  onReject,
}: SendTxModalProps) {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const to = useMemo(() => tx.to || "(contract creation)", [tx]);
  const from = useMemo(() => tx.from || "", [tx]);
  const rawValue = useMemo(() => tx.value ?? "0x0", [tx]);
  const valueEth = useMemo(() => {
    return isHex(rawValue) ? formatEther(hexToBigInt(rawValue)) : "0";
  }, [rawValue]);

  const {
    data: chainId,
    isLoading: isChainIdLoading,
    isError: isChainIdError,
  } = useQuery({
    queryKey: ["chainId"],
    queryFn: async () => {
      const { result: chainIdHex }: { result: `0x${string}` } =
        await browser.runtime.sendMessage({
          type: "WALLET_REQUEST",
          method: "eth_chainId",
          params: [],
        });

      return hexToNumber(chainIdHex);
    },
    throwOnError: true,
  });

  const chain = useMemo(() => {
    return Object.values(chains).find(
      (chain) => chain.id === chainId
    ) as chains.Chain;
  }, [chainId]);

  const {
    data: abiLoadResult,
    isLoading: isAbiLoadLoading,
    isError: isAbiLoadError,
  } = useQuery({
    queryKey: ["contractAbi", to?.toLowerCase?.() || to, chain?.id],
    queryFn: async () => {
      try {
        const client = createPublicClient({
          chain: chain,
          transport: http(),
        });

        const etherscanBaseUrl = Object.values(
          chain?.blockExplorers || {}
        ).find((item) => item.name.includes("scan"))?.apiUrl;

        if (!etherscanBaseUrl) {
          throw new Error("Block explorer base URL not found");
        }

        const result = await whatsabi.autoload(to, {
          provider: client,
          ...whatsabi.loaders.defaultsWithEnv({
            SOURCIFY_CHAIN_ID: chain?.id.toString(),
            ETHERSCAN_API_KEY: process.env.ETHERSCAN_API_KEY,
            ETHERSCAN_BASE_URL: etherscanBaseUrl,
          }),
        });

        return result;
      } catch (_) {
        return null;
      }
    },
    enabled: Boolean(chain && to),
  });

  const dataHex: string = useMemo(() => {
    return (
      (typeof tx.data === "string" && tx.data) ||
      (typeof tx.input === "string" && tx.input) ||
      "0x"
    );
  }, [tx]);

  const decoded = useMemo(() => {
    if (!dataHex || dataHex === "0x") return null;
    if (!abiLoadResult) return null;
    return decodeFunctionData({
      abi: abiLoadResult.abi,
      data: dataHex as `0x${string}`,
    });
  }, [abiLoadResult, dataHex]);

  const functionItem = useMemo(() => {
    try {
      if (!decoded || !abiLoadResult?.abi) return null;
      const abi = (abiLoadResult.abi || []) as Array<any>;
      const candidates = abi.filter(
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
  }, [decoded, abiLoadResult]);

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
      <Address
        address={address}
        className={className}
        mono
        withEnsNameAbove={ens || undefined}
      />
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

  const { data: names, isLoading: isNamesLoading } = useQuery({
    queryKey: [
      "ensNames",
      (typeof to === "string" && to.toLowerCase()) || to,
      (typeof from === "string" && from.toLowerCase()) || from,
    ],
    queryFn: async () => {
      try {
        const mainnetClient = createPublicClient({
          chain: chains.mainnet,
          transport: http(),
        });

        const safeGetEns = async (addr?: string | null) => {
          try {
            if (!addr || typeof addr !== "string") return null;
            if (!addr.startsWith("0x")) return null;
            return await mainnetClient.getEnsName({
              address: addr as `0x${string}`,
            });
          } catch {
            return null;
          }
        };

        const [toName, fromName] = await Promise.all([
          safeGetEns(to),
          safeGetEns(from),
        ]);
        return { toName, fromName } as const;
      } catch {
        return { toName: null, fromName: null } as const;
      }
    },
  });

  const isAggregateLoading =
    isChainIdLoading || isAbiLoadLoading || isNamesLoading;
  const controlsDisabled = isSubmitting || isAggregateLoading;

  const handleApprove = async () => {
    try {
      setIsSubmitting(true);
      await onApprove();
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <RequestModal
      primaryButtonTitle="Send"
      onPrimary={handleApprove}
      onReject={onReject}
      isSubmitting={isSubmitting}
    >
      <div aria-busy={isAggregateLoading}>
        <div className="space-y-5">
          <div className="grid grid-cols-[90px_1fr] items-start gap-x-3 gap-y-2">
            <div className="text-sm text-muted-foreground">Site</div>
            <div className="text-sm break-all">
              <div className="font-medium text-foreground">{host}</div>
            </div>
            <div className="text-sm text-muted-foreground">To</div>
            <div className="text-sm break-all">
              {names?.toName ? (
                <div className="font-medium text-foreground">
                  {names.toName}
                </div>
              ) : isNamesLoading ? (
                <Skeleton className="h-3 w-24" />
              ) : null}
              <div className="font-mono text-muted-foreground">
                {typeof to === "string" && to.startsWith("0x") ? (
                  <Address
                    address={to}
                    mono
                    withEnsNameAbove={names?.toName || undefined}
                  />
                ) : (
                  to
                )}
              </div>
            </div>
            {isAbiLoadLoading ? (
              <>
                <div className="text-sm text-muted-foreground">Contract</div>
                <div className="text-sm break-all">
                  <Skeleton className="h-3 w-24" />
                </div>
              </>
            ) : abiLoadResult?.contractResult?.name ? (
              <>
                <div className="text-sm text-muted-foreground">Contract</div>
                <div className="text-sm break-all">
                  <div className="font-medium text-foreground">
                    {abiLoadResult.contractResult.name}
                  </div>
                </div>
              </>
            ) : null}
            <div className="text-sm text-muted-foreground">Value</div>
            <div className="text-sm font-mono">{valueEth} ETH</div>
            <div className="text-sm text-muted-foreground">Chain</div>
            <div className="text-sm break-all">
              <div className="font-medium text-foreground">
                {chain?.name || "Unknown Chain"} ({chainId || "Unknown"})
              </div>
            </div>
          </div>

          <div>
            {isAbiLoadLoading ? (
              <Skeleton className="h-2 w-full" />
            ) : decoded ? (
              <div className="space-y-2">
                <div className="text-sm">
                  <span className="font-medium text-foreground">
                    {decoded.functionName}
                  </span>
                  <span className="text-muted-foreground">
                    {"("}
                    {(functionItem?.inputs || [])
                      .map((inp: any, i: number) =>
                        [inp?.type || "unknown", inp?.name || `arg${i}`].join(
                          " "
                        )
                      )
                      .join(", ")}
                    {")"}
                  </span>
                </div>
              </div>
            ) : null}
            {isAbiLoadLoading ? (
              <Skeleton className="h-16 w-full" />
            ) : decoded ? (
              <div className="space-y-2">
                {(functionItem?.inputs?.length || 0) > 0 ? (
                  <div className="divide-y divide-border rounded-md border">
                    {(decoded.args || []).map((arg: any, i: number) => {
                      const input = (functionItem?.inputs as any)?.[i] || {};
                      const label = input?.name || `arg${i}`;
                      const type = input?.type || "unknown";
                      return (
                        <div key={i} className="p-2">
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
                ) : (
                  <pre className="whitespace-pre font-mono text-muted-foreground text-[10px]">
                    {stringifyWithBigInt(decoded)}
                  </pre>
                )}
              </div>
            ) : (
              <pre className="whitespace-pre font-mono text-muted-foreground text-[10px]">
                {dataHex}
              </pre>
            )}
          </div>
        </div>
      </div>
    </RequestModal>
  );
}
