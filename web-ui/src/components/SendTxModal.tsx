import Address from "@/components/Address";
import { Skeleton } from "@/components/ui/skeleton";
import { whatsabi } from "@shazow/whatsabi";
import { useQuery } from "@tanstack/react-query";
import { useEffect, useMemo, useState } from "react";
import { Copy } from "lucide-react";
import { Button } from "@/components/ui/button";
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
import { cn } from "@/lib/utils";

// Transaction types
interface BaseTransaction {
  to?: string;
  from?: string;
  value?: string;
  data?: string;
  input?: string;
  gas?: string;
  gasPrice?: string;
  maxFeePerGas?: string;
  maxPriorityFeePerGas?: string;
  nonce?: string;
}

interface SingleTransaction extends BaseTransaction {}

interface BatchCall extends BaseTransaction {
  id?: number;
}

interface WalletSendCallsParams {
  calls: BatchCall[];
  from?: string;
  [key: string]: any;
}

type TransactionParams =
  | [SingleTransaction] // eth_sendTransaction
  | [WalletSendCallsParams]; // wallet_sendCalls

// Type guard functions
function isWalletSendCalls(
  params: TransactionParams
): params is [WalletSendCallsParams] {
  return params.length > 0 && "calls" in params[0];
}

function isSingleTransaction(
  params: TransactionParams
): params is [SingleTransaction] {
  return params.length > 0 && !("calls" in params[0]);
}

function stringifyWithBigInt(value: unknown) {
  return JSON.stringify(
    value,
    (_, v) => (typeof v === "bigint" ? v.toString() : v),
    2
  );
}

type SendTxModalProps = {
  host: string;
  method: "eth_sendTransaction" | "wallet_sendCalls";
  params: TransactionParams;
  onApprove: () => void;
  onReject: () => void;
};

export function SendTxModal({
  host,
  method,
  params,
  onApprove,
  onReject,
}: SendTxModalProps) {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [showCopied, setShowCopied] = useState(false);

  // Detect if this is a batch call or single transaction using type guards
  const isBatchCall = method === "wallet_sendCalls";

  // Extract transaction data with proper typing
  const transactions = useMemo(() => {
    if (isWalletSendCalls(params)) {
      // wallet_sendCalls: params[0] contains {calls: [...]}
      const batchParams = params[0];
      if (batchParams.calls && Array.isArray(batchParams.calls)) {
        return batchParams.calls.map(
          (call: BatchCall, index: number): BatchCall => ({
            ...call,
            id: index,
            from: batchParams.from || "",
          })
        );
      }
      return [] as BatchCall[];
    } else if (isSingleTransaction(params)) {
      // eth_sendTransaction: params[0] is the transaction object
      const singleTx = params[0];
      return [singleTx || ({} as SingleTransaction)] as SingleTransaction[];
    }
    return [] as BaseTransaction[];
  }, [isBatchCall, params]);

  // Calculate total value for batch calls
  const totalValue = useMemo(() => {
    return transactions.reduce((sum: bigint, tx: BaseTransaction) => {
      const value = tx.value ?? "0x0";
      return sum + (isHex(value) ? hexToBigInt(value) : 0n);
    }, 0n);
  }, [transactions]);

  const totalValueEth = useMemo(() => {
    return formatEther(totalValue);
  }, [totalValue]);

  // Primary transaction for single transaction operations
  const primaryTransaction = useMemo(
    () => transactions[0] || ({} as BaseTransaction),
    [transactions]
  );

  // Extract from address
  const from = useMemo(
    () => primaryTransaction.from || "",
    [primaryTransaction]
  );

  const [showMoreDecoded, setShowMoreDecoded] = useState(false);

  useEffect(() => {
    console.log("method:", method, "params:", params);
  }, [method, params]);

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

  const to = useMemo(
    () => primaryTransaction.to || "(contract creation)",
    [primaryTransaction]
  );

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
    enabled: Boolean(chain && to && !isBatchCall), // Only load ABI for single transactions
  });

  const dataHex: string = useMemo(() => {
    return (
      (typeof primaryTransaction.data === "string" &&
        primaryTransaction.data) ||
      (typeof primaryTransaction.input === "string" &&
        primaryTransaction.input) ||
      "0x"
    );
  }, [primaryTransaction]);

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
    return <Address address={address} className={className} mono />;
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

  const handleCopyCalldata = async () => {
    try {
      await navigator.clipboard.writeText(dataHex);
      setShowCopied(true);
      setTimeout(() => setShowCopied(false), 2000);
    } catch (error) {
      console.error("Failed to copy calldata:", error);
    }
  };

  return (
    <RequestModal
      primaryButtonTitle={isBatchCall ? "Send Batch" : "Send"}
      onPrimary={handleApprove}
      onReject={onReject}
      isSubmitting={isSubmitting}
      address={
        isBatchCall && isWalletSendCalls(params)
          ? params[0].from || ""
          : primaryTransaction.from || ""
      }
      footerChildren={
        dataHex !== "0x" &&
        !isBatchCall && (
          <div className="flex w-full justify-center">
            <Button
              variant="ghost"
              size="sm"
              className="text-xs h-8 px-2 text-muted-foreground hover:text-foreground"
              onClick={handleCopyCalldata}
              title="Copy transaction calldata"
            >
              <Copy className="h-3 w-3 mr-1" />
              {showCopied ? "Copied" : ""}
            </Button>
          </div>
        )
      }
    >
      <div aria-busy={isAggregateLoading}>
        <div className="space-y-5">
          <div className="grid grid-cols-[90px_1fr] items-start gap-x-3 gap-y-2">
            <div className="text-sm text-muted-foreground">Site</div>
            <div className="text-sm break-all">
              <div className="font-medium text-foreground">{host}</div>
            </div>
            {isBatchCall ? (
              <>
                <div className="text-sm text-muted-foreground">Batch Calls</div>
                <div className="text-sm">
                  <div className="font-medium text-foreground">
                    {transactions.length} transactions
                  </div>
                  <div className="text-xs text-muted-foreground mt-1">
                    {transactions.filter((tx: BaseTransaction) => tx.to).length}{" "}
                    contract calls,{" "}
                    {
                      transactions.filter((tx: BaseTransaction) => !tx.to)
                        .length
                    }{" "}
                    contract creations
                  </div>
                </div>
                <div className="text-sm text-muted-foreground">Total Value</div>
                <div className="text-sm">{totalValueEth} ETH</div>
              </>
            ) : (
              <>
                <div className="text-sm text-muted-foreground">To</div>
                <div className="text-sm break-all">
                  <div>
                    {typeof to === "string" && to.startsWith("0x") ? (
                      <Address address={to} />
                    ) : (
                      to
                    )}{" "}
                    {abiLoadResult?.contractResult?.name
                      ? `(${abiLoadResult.contractResult.name})`
                      : null}
                  </div>
                </div>
                <div className="text-sm text-muted-foreground">Value</div>
                <div className="text-sm">{formatEther(totalValue)} ETH</div>
              </>
            )}
            <div className="text-sm text-muted-foreground">Chain</div>
            <div className="text-sm break-all">
              <div className="text-foreground" title={chainId?.toString()}>
                {chain?.name || "Unknown Chain"}
              </div>
            </div>
          </div>

          {/* Show batch call details */}
          {isBatchCall && transactions.length > 0 && (
            <div className="space-y-3">
              <div className="text-sm font-medium text-foreground">
                Transaction Details
              </div>
              <div className="space-y-2 max-h-40 overflow-y-auto">
                {transactions.map((tx: BaseTransaction, index: number) => {
                  const txTo = tx.to || "(contract creation)";
                  const txValue = tx.value ?? "0x0";
                  const txValueEth = isHex(txValue)
                    ? formatEther(hexToBigInt(txValue))
                    : "0";
                  const txData = tx.data || tx.input || "0x";

                  return (
                    <div
                      key={(tx as BatchCall).id ?? index}
                      className="border rounded-md p-3 bg-muted/20"
                    >
                      <div className="grid grid-cols-[60px_1fr] gap-x-2 gap-y-1 text-xs">
                        <div className="text-muted-foreground">
                          #{index + 1}
                        </div>
                        <div className="font-mono break-all">
                          {typeof txTo === "string" && txTo.startsWith("0x") ? (
                            <Address address={txTo} className="text-xs" />
                          ) : (
                            txTo
                          )}
                        </div>
                        <div className="text-muted-foreground">Value:</div>
                        <div>{txValueEth} ETH</div>
                        <div className="text-muted-foreground">Data:</div>
                        <div className="font-mono break-all">
                          {txData === "0x"
                            ? "0x"
                            : `${txData.slice(0, 10)}...${txData.slice(-8)}`}
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          )}

          <div>
            {isAbiLoadLoading ? (
              <div className="space-y-3">
                <Skeleton className="h-3 w-full" />
                <Skeleton className="h-16 w-full" />
              </div>
            ) : decoded ? (
              <>
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
                <div className="space-y-2">
                  {(functionItem?.inputs?.length || 0) > 0 ? (
                    <div className="divide-y divide-border rounded-md border">
                      {(decoded.args || []).map((arg: any, i: number) => {
                        const input = (functionItem?.inputs as any)?.[i] || {};
                        const label = input?.name || `arg${i}`;
                        const type = input?.type || "unknown";
                        return (
                          <div key={i} className="py-2">
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
              </>
            ) : (
              <div>
                <pre
                  className={cn(
                    "whitespace-pre-wrap font-mono text-muted-foreground break-words",
                    !showMoreDecoded && "line-clamp-2"
                  )}
                >
                  {dataHex}
                </pre>
                <div>
                  <button
                    className="hover:underline text-blue-500"
                    onClick={() => setShowMoreDecoded(!showMoreDecoded)}
                  >
                    {showMoreDecoded ? "Show less" : "Show more"}
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </RequestModal>
  );
}
