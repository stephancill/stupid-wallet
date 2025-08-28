import { hexToString, isHex } from "viem";
import React from "react";
import Address from "@/components/Address";
import { RequestModal } from "@/components/RequestModal";

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
  const [isSubmitting, setIsSubmitting] = React.useState(false);

  const handleApprove = async () => {
    try {
      setIsSubmitting(true);
      await onApprove();
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <RequestModal
      primaryButtonTitle="Sign"
      onPrimary={handleApprove}
      onReject={onReject}
      isSubmitting={isSubmitting}
      address={address}
    >
      <div className="space-y-3 text-sm">
        <div className="text-muted-foreground">
          Site <strong className="text-foreground">{host}</strong>
        </div>
        <div>
          <div className="text-sm font-medium mb-2">Message</div>
          <div>
            <div className="font-mono text-xs text-foreground break-words whitespace-pre-wrap">
              {isHex(messageHex) ? hexToString(messageHex) : messageHex}
            </div>
          </div>
        </div>
      </div>
    </RequestModal>
  );
}
