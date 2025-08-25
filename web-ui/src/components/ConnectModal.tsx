import React from "react";
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

type ConnectModalProps = {
  host: string;
  onApprove: () => void;
  onReject: () => void;
};

export function ConnectModal({ host, onApprove, onReject }: ConnectModalProps) {
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
      <CredenzaContent className="sm:max-w-lg bg-card text-card-foreground">
        <CredenzaHeader>
          <CredenzaTitle>Connect Wallet</CredenzaTitle>
          <CredenzaDescription className="sr-only">
            Connect Wallet
          </CredenzaDescription>
        </CredenzaHeader>
        <div className="body">
          <div className="text-sm">
            This site wants to connect to your wallet.
          </div>
          <div className="mt-2 text-xs text-muted-foreground">
            Site: <strong className="text-foreground">{host}</strong>
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
                "Connect"
              )}
            </Button>
          </div>
        </CredenzaFooter>
      </CredenzaContent>
    </Credenza>
  );
}
