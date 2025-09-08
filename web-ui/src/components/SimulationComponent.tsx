import { Skeleton } from "@/components/ui/skeleton";
import { useQuery } from "@tanstack/react-query";
import {
  createPublicClient,
  formatEther,
  hexToBigInt,
  http,
  isHex,
  SimulateCallsReturnType,
  decodeEventLog,
  decodeErrorResult,
  erc20Abi,
  erc1155Abi,
  erc721Abi,
  parseEther,
} from "viem";
import { whatsabi } from "@shazow/whatsabi";
import * as chains from "viem/chains";
import { RPC_URLS } from "@/lib/constants";
import { Address } from "@/components/Address";

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

export function SimulationComponent({
  calls,
  account,
  chain,
}: SimulationComponentProps) {
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
                // If common ABIs fail, try to fetch contract ABI with whatsabi
                const contractAddress = calls[callIndex]?.to;
                if (contractAddress) {
                  const client = createPublicClient({
                    chain,
                    transport: http(),
                  });

                  const etherscanBaseUrl = Object.values(
                    chain?.blockExplorers || {}
                  ).find((item) => item.name.includes("scan"))?.apiUrl;

                  if (etherscanBaseUrl) {
                    try {
                      const whatsabiResult = await whatsabi.autoload(
                        contractAddress,
                        {
                          provider: client,
                          ...whatsabi.loaders.defaultsWithEnv({
                            SOURCIFY_CHAIN_ID: chain?.id.toString(),
                            ETHERSCAN_API_KEY: import.meta.env
                              .VITE_ETHERSCAN_API_KEY,
                            ETHERSCAN_BASE_URL: etherscanBaseUrl,
                          }),
                        }
                      );

                      const decoded = decodeErrorResult({
                        abi: whatsabiResult.abi,
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
              return {
                callIndex,
                logIndex,
                eventName: decoded.eventName,
                args: decoded.args,
                address: log.address,
                decoded: true,
              };
            } catch {
              // If common ABIs fail, try to fetch contract ABI with whatsabi
              const client = createPublicClient({
                chain,
                transport: http(),
              });

              const etherscanBaseUrl = Object.values(
                chain?.blockExplorers || {}
              ).find((item) => item.name.includes("scan"))?.apiUrl;

              if (etherscanBaseUrl) {
                try {
                  const result = await whatsabi.autoload(log.address, {
                    provider: client,
                    ...whatsabi.loaders.defaultsWithEnv({
                      SOURCIFY_CHAIN_ID: chain?.id.toString(),
                      ETHERSCAN_API_KEY: import.meta.env.VITE_ETHERSCAN_API_KEY,
                      ETHERSCAN_BASE_URL: etherscanBaseUrl,
                    }),
                  });

                  const decoded = decodeEventLog({
                    abi: result.abi,
                    data: log.data,
                    topics: log.topics,
                  });

                  return {
                    callIndex,
                    logIndex,
                    eventName: decoded.eventName,
                    args: decoded.args,
                    address: log.address,
                    decoded: true,
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
                <Address address={error.address} />
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Events */}
      {decodedEvents && decodedEvents.length > 0 && (
        <div className="space-y-3">
          {decodedEvents.map((event, eventIndex) => (
            <div key={eventIndex} className="text-xs bg-muted p-3 rounded">
              <div className="font-medium mb-2">{event.eventName}</div>
              {event.args && (
                <div className="space-y-1">
                  {Object.entries(event.args).map(([key, value]) => (
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
                <Address address={event.address} />
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
