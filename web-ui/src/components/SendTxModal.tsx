import { useQuery } from "@tanstack/react-query";
import { useMemo } from "react";
import { createPublicClient, formatEther, hexToBigInt, http } from "viem";
import * as chains from "viem/chains";
import { ModalFrame } from "./ModalFrame";

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
  const to = useMemo(() => tx.to || "(contract creation)", [tx]);
  const from = useMemo(() => tx.from || "", [tx]);
  const rawValue = useMemo(() => tx.value ?? "0x0", [tx]);
  const valueEth = useMemo(() => {
    try {
      let wei: bigint = 0n;
      if (typeof rawValue === "string") {
        if (rawValue.startsWith("0x")) {
          wei = hexToBigInt(rawValue as `0x${string}`);
        } else {
          wei = BigInt(rawValue || "0");
        }
      } else if (typeof rawValue === "bigint") {
        wei = rawValue;
      } else if (typeof rawValue === "number") {
        wei = BigInt(rawValue);
      }
      return formatEther(wei);
    } catch {
      return "0";
    }
  }, [rawValue]);

  const dataHex: string = useMemo(() => {
    return (
      (typeof tx.data === "string" && tx.data) ||
      (typeof tx.input === "string" && tx.input) ||
      "0x"
    );
  }, [tx]);

  const { data: decoded, isLoading } = useQuery({
    queryKey: ["decodedTx", to?.toLowerCase?.() || to, dataHex],
    queryFn: async () => {
      if (!dataHex || dataHex === "0x") return null;
      try {
        const res = await browser.runtime.sendMessage({
          type: "DECODE_TX_DATA",
          to,
          data: dataHex,
        });
        return res?.decoded ?? res ?? null;
      } catch (_) {
        return null;
      }
    },
  });

  const decodedDisplay = useMemo(() => {
    if (decoded == null) return dataHex;
    return decoded;
  }, [decoded, dataHex]);

  const { data: names } = useQuery({
    queryKey: [
      "ensNames",
      (typeof to === "string" && to.toLowerCase()) || to,
      (typeof from === "string" && from.toLowerCase()) || from,
    ],
    queryFn: async () => {
      try {
        const chainIdHex: string = await browser.runtime.sendMessage({
          type: "WALLET_REQUEST",
          method: "eth_chainId",
          params: [],
        });
        const id = (() => {
          try {
            return Number(chainIdHex);
          } catch {
            return 1;
          }
        })();
        const chain = Object.values(chains).find((chain) => chain.id === id);

        const client = createPublicClient({
          chain: chain,
          transport: http(),
        });

        const safeGetEns = async (addr?: string | null) => {
          try {
            if (!addr || typeof addr !== "string") return null;
            if (!addr.startsWith("0x")) return null;
            return await client.getEnsName({ address: addr as `0x${string}` });
          } catch {
            return null;
          }
        };

        const [toName, fromName] = await Promise.all([
          safeGetEns(to),
          safeGetEns(from),
        ]);
        return { chainIdHex, toName, fromName } as const;
      } catch {
        return { chainIdHex: "0x1", toName: null, fromName: null } as const;
      }
    },
  });

  return (
    <ModalFrame
      title="Send Transaction"
      primaryLabel="Send"
      secondaryLabel="Reject"
      onPrimary={onApprove}
      onSecondary={onReject}
    >
      <div className="space-y-5">
        <div className="grid grid-cols-[90px_1fr] items-start gap-x-3 gap-y-2">
          <div className="text-sm text-muted-foreground">Site</div>
          <div className="text-sm break-all">
            <div className="font-medium text-foreground">{host}</div>
          </div>
          <div className="text-sm text-muted-foreground">To</div>
          <div className="text-sm break-all">
            {names?.toName ? (
              <div className="font-medium text-foreground">{names.toName}</div>
            ) : null}
            <div className="font-mono text-muted-foreground">{to}</div>
          </div>
          <div className="text-sm text-muted-foreground">Value</div>
          <div className="text-sm font-mono">{valueEth} ETH</div>
        </div>

        <div>
          <div className="text-sm font-medium mb-2">Decoded data</div>
          <div className="rounded-md border bg-muted/30 p-3 text-xs font-mono text-muted-foreground">
            {isLoading ? (
              <div className="h-16 w-full animate-pulse rounded-md bg-muted" />
            ) : (
              <pre className="whitespace-pre-wrap break-words text-foreground">
                {typeof decodedDisplay === "string"
                  ? decodedDisplay
                  : JSON.stringify(decodedDisplay, null, 2)}
              </pre>
            )}
          </div>
        </div>
      </div>
    </ModalFrame>
  );
}
