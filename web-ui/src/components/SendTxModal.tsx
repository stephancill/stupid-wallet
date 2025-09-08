import { CallDecoder } from "@/components/CallDecoder";
import { RequestModal } from "@/components/RequestModal";
import { SimulationComponent } from "@/components/SimulationComponent";
import { Button } from "@/components/ui/button";
import { useQuery } from "@tanstack/react-query";
import { Copy } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import {
  createPublicClient,
  formatEther,
  hexToBigInt,
  hexToNumber,
  http,
  isHex,
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
  const calls = useMemo(() => {
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
    return calls.reduce((sum: bigint, tx: BaseTransaction) => {
      const value = tx.value ?? "0x0";
      return sum + (isHex(value) ? hexToBigInt(value) : 0n);
    }, 0n);
  }, [calls]);

  const totalValueEth = useMemo(() => {
    return formatEther(totalValue);
  }, [totalValue]);

  // Primary transaction for single transaction operations
  const primaryTransaction = useMemo(
    () => calls[0] || ({} as BaseTransaction),
    [calls]
  );

  // Extract from address
  const from = useMemo(
    () => primaryTransaction.from || "",
    [primaryTransaction]
  );

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

  const dataHex: string = useMemo(() => {
    return (
      (typeof primaryTransaction.data === "string" &&
        primaryTransaction.data) ||
      (typeof primaryTransaction.input === "string" &&
        primaryTransaction.input) ||
      "0x"
    );
  }, [primaryTransaction]);

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

  const isAggregateLoading = isChainIdLoading || isNamesLoading;
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
                <div className="text-sm text-muted-foreground">Total Value</div>
                <div className="text-sm">{totalValueEth} ETH</div>
              </>
            ) : null}
            <div className="text-sm text-muted-foreground">Chain</div>
            <div className="text-sm break-all">
              <div className="text-foreground" title={chainId?.toString()}>
                {chain?.name || "Unknown Chain"}
              </div>
            </div>
          </div>

          <SimulationComponent calls={calls} account={from} chain={chain} />

          {/* Show batch call details */}
          {isBatchCall && calls.length > 0 && (
            <div className="space-y-3">
              <div className="text-sm font-medium text-foreground">
                Transaction Details ({calls.length} calls)
              </div>
              <div className="space-y-5">
                {calls.map((tx: BaseTransaction, index: number) => (
                  <div
                    key={(tx as BatchCall).id ?? index}
                    className="space-y-3"
                  >
                    <div className="text-sm font-medium text-foreground">
                      Call #{index + 1}
                    </div>
                    <CallDecoder
                      call={{
                        to: tx.to,
                        data: tx.data || tx.input,
                        value: tx.value,
                      }}
                      chain={chain}
                    />
                  </div>
                ))}
              </div>
            </div>
          )}

          {!isBatchCall && (
            <div>
              <div className="text-sm font-medium text-foreground mb-2">
                Transaction Details
              </div>
              <CallDecoder
                call={{
                  to: primaryTransaction.to,
                  data: primaryTransaction.data || primaryTransaction.input,
                  value: primaryTransaction.value,
                }}
                chain={chain}
              />
            </div>
          )}
        </div>
      </div>
    </RequestModal>
  );
}
