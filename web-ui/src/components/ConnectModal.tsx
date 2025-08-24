import React from "react";
import { ModalFrame } from "./ModalFrame";

type ConnectModalProps = {
  host: string;
  onApprove: () => void;
  onReject: () => void;
};

export function ConnectModal({ host, onApprove, onReject }: ConnectModalProps) {
  return (
    <ModalFrame
      title="Connect Wallet"
      primaryLabel="Connect"
      secondaryLabel="Reject"
      onPrimary={onApprove}
      onSecondary={onReject}
    >
      <div>This site wants to connect to your wallet.</div>
      <div style={{ marginTop: 8, fontSize: 12, color: "#555" }}>
        Site: <strong>{host}</strong>
      </div>
    </ModalFrame>
  );
}
