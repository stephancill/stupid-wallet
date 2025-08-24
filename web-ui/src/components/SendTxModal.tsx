import React from "react";
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
  const to = tx.to || "(contract creation)";
  const value = tx.value || "0x0";
  const data = tx.data || tx.input || "0x";
  const gas = tx.gas || tx.gasLimit || "";
  const gasPrice = tx.maxFeePerGas || tx.gasPrice || "";

  return (
    <ModalFrame
      title="Send Transaction"
      primaryLabel="Send"
      secondaryLabel="Reject"
      onPrimary={onApprove}
      onSecondary={onReject}
    >
      <div className="meta">
        Site: <strong>{host}</strong>
      </div>
      <div className="body" style={{ padding: 0 }}>
        <div className="kv">
          <div>To</div>
          <div className="mono">{to}</div>
          <div>Value</div>
          <div className="mono">{value}</div>
          <div>Gas</div>
          <div className="mono">{gas}</div>
          <div>Gas Price/Max Fee</div>
          <div className="mono">{gasPrice}</div>
        </div>
        <div>
          <div style={{ fontWeight: 600, margin: "10px 0 6px" }}>Data</div>
          <div className="preview mono">{String(data).slice(0, 820)}</div>
        </div>
      </div>
    </ModalFrame>
  );
}
