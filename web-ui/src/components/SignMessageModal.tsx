import { hexToString, isHex } from "viem";
import { ModalFrame } from "./ModalFrame";

type SignMessageModalProps = {
  host: string;
  address?: string;
  messageHex: string;
  onApprove: () => void;
  onReject: () => void;
};

export function SignMessageModal({
  host,
  address,
  messageHex,
  onApprove,
  onReject,
}: SignMessageModalProps) {
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
        <div className="preview mono">
          {isHex(messageHex) ? hexToString(messageHex) : messageHex}
        </div>
      </div>
    </ModalFrame>
  );
}
