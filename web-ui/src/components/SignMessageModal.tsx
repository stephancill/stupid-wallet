import { hexToString, isHex } from "viem";
import React from "react";
import Address from "@/components/Address";
import { Button } from "@/components/ui/button";
import { Loader2 } from "lucide-react";
import {
  Credenza,
  CredenzaContent,
  CredenzaDescription,
  CredenzaFooter,
  CredenzaHeader,
  CredenzaTitle,
} from "@/components/ui/credenza";

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

  const handlePrimaryClick = async () => {
    try {
      setIsSubmitting(true);
      await onApprove();
    } catch (_) {
      setIsSubmitting(false);
    }
  };

  return (
    <Credenza
      open
      onOpenChange={(isOpen) => {
        if (!isOpen && !isSubmitting) onReject();
      }}
    >
      <CredenzaContent className="sm:max-w-lg bg-card text-card-foreground max-h-[85vh] flex flex-col overflow-hidden">
        <CredenzaHeader>
          <CredenzaTitle>Sign Message</CredenzaTitle>
          <CredenzaDescription className="sr-only">
            Sign Message
          </CredenzaDescription>
        </CredenzaHeader>
        <div className="body flex-1 overflow-y-auto min-h-0">
          <div className="space-y-3 text-sm px-2 pb-2">
            <div className="text-muted-foreground">
              Site: <strong className="text-foreground">{host}</strong>
            </div>
            <div>
              Address:{" "}
              <span className="font-mono text-muted-foreground">
                {address && address.startsWith("0x") ? (
                  <Address address={address} mono />
                ) : (
                  address || "(current)"
                )}
              </span>
            </div>
            <div>
              Method:{" "}
              <span className="font-mono text-muted-foreground">
                personal_sign
              </span>
            </div>
            <div>
              <div className="text-sm font-medium mb-2">Message</div>
              <div
                className="h-[200px] rounded-md border bg-muted/30 p-3 overflow-y-auto"
                style={{ WebkitOverflowScrolling: "touch" }}
              >
                <div className="font-mono text-xs text-foreground break-words whitespace-pre-wrap">
                  {isHex(messageHex) ? hexToString(messageHex) : messageHex}
                </div>
              </div>
            </div>
          </div>
        </div>
        <CredenzaFooter>
          <div className="flex w-full justify-end gap-2">
            <Button
              variant="secondary"
              onClick={onReject}
              disabled={isSubmitting}
            >
              Reject
            </Button>
            <Button
              onClick={handlePrimaryClick}
              disabled={isSubmitting}
              aria-busy={isSubmitting}
            >
              {isSubmitting ? (
                <span className="inline-flex items-center">
                  <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                </span>
              ) : (
                "Sign"
              )}
            </Button>
          </div>
        </CredenzaFooter>
      </CredenzaContent>
    </Credenza>
  );
}
