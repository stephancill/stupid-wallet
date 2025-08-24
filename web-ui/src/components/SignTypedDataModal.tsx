import React from "react";
import { ModalFrame } from "./ModalFrame";

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
  return (
    <ModalFrame
      title="Sign Typed Data"
      primaryLabel="Sign"
      secondaryLabel="Reject"
      onPrimary={onApprove}
      onSecondary={onReject}
    >
      <div className="meta">
        Site: <strong>{host}</strong>
      </div>
      <div className="meta">
        Address: <span className="mono">{address || "(current)"}</span>
      </div>
      <div className="meta">
        Method: <span className="mono">eth_signTypedData_v4</span>
      </div>
      <div>
        <div style={{ fontWeight: 600, marginBottom: 6 }}>
          Typed Data (EIP-712)
        </div>
        <div className="preview mono">{pretty}</div>
      </div>
    </ModalFrame>
  );
}
