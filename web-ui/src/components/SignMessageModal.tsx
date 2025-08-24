import React from "react";
import { ModalFrame } from "./ModalFrame";

type SignMessageModalProps = {
  host: string;
  address?: string;
  messageHex: string;
  onApprove: () => void;
  onReject: () => void;
};

function tryDecodeHexToUtf8(messageHex: string): string | null {
  try {
    if (messageHex && messageHex.startsWith("0x")) {
      const bytes = new Uint8Array((messageHex.length - 2) / 2);
      for (let i = 2, j = 0; i < messageHex.length; i += 2, j++) {
        bytes[j] = parseInt(messageHex.slice(i, i + 2), 16);
      }
      const text = new TextDecoder().decode(bytes);
      return text;
    }
  } catch {}
  return null;
}

export function SignMessageModal({
  host,
  address,
  messageHex,
  onApprove,
  onReject,
}: SignMessageModalProps) {
  const decoded = tryDecodeHexToUtf8(messageHex);
  const preview = decoded ?? messageHex;

  return (
    <ModalFrame
      title="Sign Message"
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
        Method: <span className="mono">personal_sign</span>
      </div>
      <div>
        <div style={{ fontWeight: 600, marginBottom: 6 }}>Message</div>
        <div className="preview mono">{preview}</div>
      </div>
    </ModalFrame>
  );
}
