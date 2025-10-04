import { Address } from "@/components/Address";
import { Skeleton } from "@/components/ui/skeleton";
import { RPC_URLS } from "@/lib/constants";
import {
  loadContractABI,
  loadContractMetadata,
  type ContractMetadata,
} from "@/lib/contract-utils";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import {
  createPublicClient,
  decodeErrorResult,
  decodeEventLog,
  erc1155Abi,
  erc20Abi,
  erc721Abi,
  formatUnits,
  hexToBigInt,
  http,
  isHex,
  SimulateCallsReturnType,
} from "viem";
import * as chains from "viem/chains";

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

interface SimulationComponentProps {
  calls: BaseTransaction[];
  account: string;
  chain: chains.Chain | undefined;
}

/**
 * Helper function to fetch contract ABI using React Query's cache
 * This can be called imperatively inside queryFn while still leveraging caching
 */
async function fetchContractABI(
  queryClient: any,
  address: string,
  chainId: number
): Promise<any[]> {
  const queryKey = ["contract-abi", chainId, address.toLowerCase()];

  // Try to get from cache first, or fetch if not available
  const data = await queryClient.fetchQuery({
    queryKey,
    queryFn: () => loadContractABI(address, chainId),
    staleTime: 30 * 60 * 1000, // 30 minutes
  });

  return data.abi;
}

/**
 * Helper function to fetch contract metadata using React Query's cache
 * This can be called imperatively inside queryFn while still leveraging caching
 */
async function fetchContractMetadata(
  queryClient: any,
  address: string,
  chainId: number
): Promise<ContractMetadata> {
  const queryKey = ["contract-metadata", chainId, address.toLowerCase()];

  // Try to get from cache first, or fetch if not available
  const metadata = await queryClient.fetchQuery({
    queryKey,
    queryFn: () => loadContractMetadata(address, chainId),
    staleTime: 30 * 60 * 1000, // 30 minutes
    gcTime: 60 * 60 * 1000, // 1 hour
    retry: 1,
  });

  return metadata;
}

export function SimulationComponent({
  calls,
  account,
  chain,
}: SimulationComponentProps) {
  const queryClient = useQueryClient();
  const simulationQuery = useQuery({
    queryKey: [
      "simulateCalls",
      JSON.stringify(calls, (_, v) =>
        typeof v === "bigint" ? v.toString() : v
      ),
      account,
      chain?.id,
    ],
    queryFn: async (): Promise<SimulateCallsReturnType> => {
      if (!chain || !account) throw new Error("Chain or account not available");

      const rpcUrl = RPC_URLS[chain.id];

      if (!rpcUrl) throw new Error("Simulation not available for this chain");

      const publicClient = createPublicClient({
        chain,
        transport: http(rpcUrl),
      });

      const simulationCalls = calls
        .filter(
          (call) => call.to && call.to.startsWith("0x") && call.to.length === 42
        )
        .map((call) => {
          const data = call.data || call.input || "0x";
          return {
            to: call.to,
            value:
              call.value && isHex(call.value) ? hexToBigInt(call.value) : 0n,
            data: isHex(data) ? data : "0x",
          } as any;
        });

      if (simulationCalls.length === 0) {
        throw new Error("No valid calls to simulate");
      }

      console.log("simulationCalls", simulationCalls);

      const result = await publicClient.simulateCalls({
        account: account as `0x${string}`,
        calls: simulationCalls as any,
        validation: false,
      });

      console.log("result", result);

      return result;
    },
    enabled: !!chain && !!account && calls.length > 0,
    retry: false,
  });

  // Log decoding query that depends on simulation results
  const decodedLogsQuery = useQuery({
    queryKey: [
      "decodeSimulationLogs",
      JSON.stringify(simulationQuery.data?.results, (_, v) =>
        typeof v === "bigint" ? v.toString() : v
      ),
    ],
    queryFn: async () => {
      const simulationResults = simulationQuery.data?.results;
      if (!simulationResults || !chain) return { events: [], errors: [] };

      const allLogs: Array<{
        log: any;
        callIndex: number;
        logIndex: number;
      }> = [];

      const failedCalls: Array<{
        callIndex: number;
        result: any;
      }> = [];

      // Collect all logs from all calls and track failed calls
      simulationResults.forEach((result, callIndex) => {
        if (result.status === "failure") {
          failedCalls.push({ callIndex, result });
        }
        if (result.logs) {
          result.logs.forEach((log, logIndex) => {
            allLogs.push({ log, callIndex, logIndex });
          });
        }
      });

      const decodedErrors = await Promise.all(
        failedCalls.map(async ({ callIndex, result }) => {
          try {
            // Try to decode error data if present
            if (result.data && result.data !== "0x") {
              // First try with common ABIs
              const commonAbi = [...erc20Abi, ...erc721Abi, ...erc1155Abi];

              try {
                const decoded = decodeErrorResult({
                  abi: commonAbi,
                  data: result.data,
                });
                return {
                  callIndex,
                  errorName: decoded.errorName,
                  args: decoded.args,
                  decoded: true,
                  address: calls[callIndex]?.to || "unknown",
                };
              } catch {
                // If common ABIs fail, try to fetch contract ABI with whatsabi (cached)
                const contractAddress = calls[callIndex]?.to;
                if (contractAddress && chain) {
                  try {
                    const abi = await fetchContractABI(
                      queryClient,
                      contractAddress,
                      chain.id
                    );

                    const decoded = decodeErrorResult({
                      abi,
                      data: result.data,
                    });

                    return {
                      callIndex,
                      errorName: decoded.errorName,
                      args: decoded.args,
                      decoded: true,
                      address: contractAddress,
                    };
                  } catch {
                    // Contract ABI loading/decoding failed
                  }
                }
              }

              // Try to decode as standard Error(string) - common Solidity pattern
              if (result.data && result.data.startsWith("0x08c379a")) {
                try {
                  // For standard Error(string), we can use viem's decodeErrorResult with a generic ABI
                  const errorAbi = [
                    {
                      type: "error",
                      name: "Error",
                      inputs: [{ type: "string", name: "message" }],
                    },
                  ] as const;

                  const decoded = decodeErrorResult({
                    abi: errorAbi,
                    data: result.data,
                  });

                  return {
                    callIndex,
                    errorName: decoded.errorName,
                    args: {
                      ...decoded.args,
                      gasUsed: result.gasUsed,
                    },
                    decoded: true,
                    address: calls[callIndex]?.to || "unknown",
                  };
                } catch {
                  // Standard error decoding failed, continue to fallback
                }
              }

              // Fallback: return raw error data
              return {
                callIndex,
                errorName: "Unknown Error",
                args: {
                  rawData: result.data,
                  gasUsed: result.gasUsed,
                },
                decoded: false,
                address: calls[callIndex]?.to || "unknown",
              };
            }

            // No error data, but call failed
            return {
              callIndex,
              errorName: "Call Failed",
              args: {
                gasUsed: result.gasUsed,
                reason: "Unknown failure reason",
              },
              decoded: false,
              address: calls[callIndex]?.to || "unknown",
            };
          } catch (error) {
            return {
              callIndex,
              errorName: "Failed to decode error",
              args: {
                error: error instanceof Error ? error.message : String(error),
                rawData: result.data,
                gasUsed: result.gasUsed,
              },
              decoded: false,
              address: calls[callIndex]?.to || "unknown",
            };
          }
        })
      );

      if (allLogs.length === 0 && decodedErrors.length === 0)
        return { events: [], errors: [] };

      // Try to decode with common ABIs first
      const commonAbi = [...erc20Abi, ...erc721Abi, ...erc1155Abi];
      const decodedEvents = await Promise.all(
        allLogs.map(async ({ log, callIndex, logIndex }) => {
          try {
            // Try common ABIs first
            try {
              const decoded = decodeEventLog({
                abi: commonAbi,
                data: log.data,
                topics: log.topics,
              });

              // For Transfer events from ERC-20 tokens, fetch metadata to get decimals
              let metadata: ContractMetadata | undefined;
              if (
                decoded.eventName === "Transfer" &&
                chain &&
                // ERC-20 Transfer has 3 topics (signature + from + to), ERC-721 also has 3
                // We'll try to fetch metadata for all Transfer events
                log.topics.length === 3
              ) {
                try {
                  metadata = await fetchContractMetadata(
                    queryClient,
                    log.address,
                    chain.id
                  );
                } catch {
                  // Metadata fetch failed, continue without it
                }
              }

              return {
                callIndex,
                logIndex,
                eventName: decoded.eventName,
                args: decoded.args,
                address: log.address,
                decoded: true,
                metadata,
              };
            } catch {
              // If common ABIs fail, try to fetch contract ABI with whatsabi (cached)
              if (chain) {
                try {
                  const abi = await fetchContractABI(
                    queryClient,
                    log.address,
                    chain.id
                  );

                  const decoded = decodeEventLog({
                    abi,
                    data: log.data,
                    topics: log.topics,
                  }) as { eventName: string; args: any };

                  // For Transfer events, try to fetch metadata
                  let metadata: ContractMetadata | undefined;
                  if (decoded.eventName === "Transfer") {
                    try {
                      metadata = await fetchContractMetadata(
                        queryClient,
                        log.address,
                        chain.id
                      );
                    } catch {
                      // Metadata fetch failed, continue without it
                    }
                  }

                  return {
                    callIndex,
                    logIndex,
                    eventName: decoded.eventName,
                    args: decoded.args,
                    address: log.address,
                    decoded: true,
                    metadata,
                  };
                } catch {
                  // Contract ABI loading/decoding failed
                }
              }
            }

            // Fallback: return raw log data
            return {
              callIndex,
              logIndex,
              eventName: "Unknown Event",
              args: {
                topics: log.topics,
                data: log.data,
              },
              address: log.address,
              decoded: false,
            };
          } catch (error) {
            return {
              callIndex,
              logIndex,
              eventName: "Failed to decode",
              args: {
                error: error instanceof Error ? error.message : String(error),
              },
              address: log.address,
              decoded: false,
            };
          }
        })
      );

      return { events: decodedEvents, errors: decodedErrors };
    },
    enabled: !!simulationQuery.data?.results && !!chain,
    retry: false,
  });

  const { events: decodedEvents = [], errors: decodedErrors = [] } =
    decodedLogsQuery.data || {};

  const [showOtherEvents, setShowOtherEvents] = useState(false);

  // Separate events into user-relevant transfers/approvals and other events
  const { userTransfers, otherEvents } = useMemo(() => {
    const userAddr = account?.toLowerCase();
    const transfers: Array<{
      event: (typeof decodedEvents)[0];
      isIncoming?: boolean;
    }> = [];
    const others: typeof decodedEvents = [];

    decodedEvents.forEach((event) => {
      // Check if this is a transfer event involving the user
      const isTransfer =
        event.eventName === "Transfer" ||
        event.eventName === "TransferSingle" ||
        event.eventName === "TransferBatch";

      // Check if this is an approval event involving the user
      const isApproval =
        event.eventName === "Approval" || event.eventName === "ApprovalForAll";

      if (isTransfer && event.args) {
        const args = event.args as any;
        const from =
          typeof args.from === "string" ? args.from.toLowerCase() : null;
        const to = typeof args.to === "string" ? args.to.toLowerCase() : null;

        if (from === userAddr || to === userAddr) {
          transfers.push({
            event,
            isIncoming: to === userAddr,
          });
          return;
        }
      }

      if (isApproval && event.args) {
        const args = event.args as any;
        const owner =
          typeof args.owner === "string" ? args.owner.toLowerCase() : null;

        if (owner === userAddr) {
          transfers.push({
            event,
            isIncoming: undefined, // Approvals don't have a direction
          });
          return;
        }
      }

      others.push(event);
    });

    return { userTransfers: transfers, otherEvents: others };
  }, [decodedEvents, account]);

  if (simulationQuery.isLoading || decodedLogsQuery.isLoading) {
    return (
      <div className="space-y-4">
        <div className="text-sm font-medium text-foreground">Simulation</div>

        {/* Skeleton */}
        <div className="space-y-3">
          <div className="text-xs bg-muted p-3 rounded">
            <Skeleton className="h-4 w-24 mb-3" />
            <Skeleton className="h-3 w-full mb-2" />
            <Skeleton className="h-3 w-3/4 mb-2" />
            <Skeleton className="h-3 w-1/2" />
            <div className="mt-3 pt-2 border-t">
              <Skeleton className="h-3 w-20" />
            </div>
          </div>
        </div>
      </div>
    );
  }

  if (simulationQuery.isError) {
    return null;
  }

  const renderArgValue = (
    key: string,
    value: any,
    isIncoming?: boolean,
    metadata?: ContractMetadata
  ) => {
    // Special handling for transfer value/amount fields
    const isValueField =
      key === "value" || key === "amount" || key === "tokenId" || key === "id";
    if (isValueField && typeof value === "bigint") {
      // Format ERC-20 values with decimals if available
      if (
        (key === "value" || key === "amount") &&
        metadata?.decimals !== undefined &&
        metadata.isERC20
      ) {
        const formatted = formatUnits(value, metadata.decimals);

        // Apply highlighting only if direction is known
        if (isIncoming !== undefined) {
          const prefix = isIncoming ? "+" : "-";
          const colorClass = isIncoming ? "text-green-600" : "text-red-600";
          return (
            <span className={`font-mono font-semibold ${colorClass}`}>
              {prefix}
              {formatted} {metadata.symbol || ""}
            </span>
          );
        }

        // No highlighting for non-user transfers, but still format
        return (
          <span className="font-mono">
            {formatted} {metadata.symbol || ""}
          </span>
        );
      }

      // For tokenId or id (NFTs), show raw value
      if (isIncoming !== undefined) {
        const prefix = isIncoming ? "+" : "-";
        const colorClass = isIncoming ? "text-green-600" : "text-red-600";
        return (
          <span className={`font-mono font-semibold ${colorClass}`}>
            {prefix}
            {value.toString()}
          </span>
        );
      }

      // No highlighting for non-user transfers
      return <span className="font-mono">{value.toString()}</span>;
    }

    // Render address using Address component
    if (
      typeof value === "string" &&
      value.startsWith("0x") &&
      value.length === 42
    ) {
      return <Address address={value} chainId={chain?.id} />;
    }
    // Render bigint as string
    if (typeof value === "bigint") {
      return <span className="font-mono">{value.toString()}</span>;
    }
    // Render hex strings with mono font
    if (typeof value === "string" && value.startsWith("0x")) {
      return <span className="font-mono break-all">{value}</span>;
    }
    // Default string rendering
    if (typeof value === "string") {
      return <span>{value}</span>;
    }
    // Render arrays and objects
    if (Array.isArray(value) || (value && typeof value === "object")) {
      return (
        <pre className="whitespace-pre-wrap break-words text-xs">
          {JSON.stringify(
            value,
            (_, v) => (typeof v === "bigint" ? v.toString() : v),
            2
          )}
        </pre>
      );
    }
    return <span>{String(value)}</span>;
  };

  const renderEvent = (
    event: any,
    eventIndex: number,
    isIncoming?: boolean
  ) => (
    <div key={eventIndex} className={`text-xs p-3 rounded bg-muted`}>
      <div className="font-medium mb-2">{event.eventName}</div>
      {event.args && (
        <div className="space-y-1">
          {Object.entries(event.args).map(([key, value]) => (
            <div key={key} className="flex justify-between items-start">
              <span className="text-muted-foreground text-xs">{key}:</span>
              <span className="text-xs ml-2 flex-1 break-all">
                {renderArgValue(key, value, isIncoming, event.metadata)}
              </span>
            </div>
          ))}
        </div>
      )}
      <div className="text-muted-foreground text-xs mt-2 pt-2 border-t">
        <Address address={event.address} chainId={chain?.id} showContractName />
      </div>
    </div>
  );

  return (
    <div className="space-y-4">
      <div className="text-sm font-medium text-foreground">Simulation</div>

      {/* Errors */}
      {decodedErrors && decodedErrors.length > 0 && (
        <div className="space-y-3">
          {decodedErrors.map((error, errorIndex) => (
            <div
              key={errorIndex}
              className="text-xs bg-destructive/10 border border-destructive/20 p-3 rounded"
            >
              <div className="font-medium mb-2 text-destructive">
                {error.errorName}
              </div>
              {error.args && (
                <div className="space-y-1">
                  {Object.entries(error.args).map(([key, value]) => (
                    <div key={key} className="flex justify-between items-start">
                      <span className="text-muted-foreground text-xs">
                        {key}:
                      </span>
                      <span className="font-mono text-xs ml-2 flex-1 break-all">
                        {typeof value === "bigint"
                          ? value.toString()
                          : typeof value === "string" &&
                            value.startsWith("0x") &&
                            value.length === 42
                          ? `${value.slice(0, 6)}...${value.slice(-4)}`
                          : String(value)}
                      </span>
                    </div>
                  ))}
                </div>
              )}
              <div className="text-muted-foreground text-xs mt-2 pt-2 border-t">
                <Address
                  address={error.address}
                  chainId={chain?.id}
                  showContractName
                />
              </div>
            </div>
          ))}
        </div>
      )}

      {/* User Transfers (highlighted) */}
      {userTransfers.length > 0 && (
        <div>
          {userTransfers.map(({ event, isIncoming }, eventIndex) =>
            renderEvent(event, eventIndex, isIncoming)
          )}
        </div>
      )}

      {/* Other Events - show directly if no user transfers, otherwise below the fold */}
      {otherEvents.length > 0 && userTransfers.length === 0 && (
        <div>
          {otherEvents.map((event, eventIndex) =>
            renderEvent(event, eventIndex, undefined)
          )}
        </div>
      )}

      {/* Other Events (below the fold when there are user transfers) */}
      {otherEvents.length > 0 && userTransfers.length > 0 && (
        <div className="space-y-2">
          <button
            onClick={() => setShowOtherEvents(!showOtherEvents)}
            className="text-xs text-muted-foreground hover:text-foreground transition-colors flex items-center gap-1"
          >
            <span>
              {showOtherEvents ? "Hide" : "Show"} other events (
              {otherEvents.length})
            </span>
            <svg
              className={`w-3 h-3 transition-transform ${
                showOtherEvents ? "rotate-180" : ""
              }`}
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M19 9l-7 7-7-7"
              />
            </svg>
          </button>
          {showOtherEvents && (
            <div className="space-y-3">
              {otherEvents.map((event, eventIndex) =>
                renderEvent(event, eventIndex, undefined)
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
