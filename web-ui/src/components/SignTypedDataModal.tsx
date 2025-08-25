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
          <CredenzaTitle>Sign Typed Data</CredenzaTitle>
          <CredenzaDescription className="sr-only">
            Sign Typed Data
          </CredenzaDescription>
        </CredenzaHeader>
        <div className="body">
          <div className="space-y-3 text-sm">
            <div className="text-muted-foreground">
              Site: <strong className="text-foreground">{host}</strong>
            </div>
            <div>
              Address:{" "}
              <span className="font-mono text-muted-foreground">
                {address || "(current)"}
              </span>
            </div>
            <div>
              Method:{" "}
              <span className="font-mono text-muted-foreground">
                eth_signTypedData_v4
              </span>
            </div>
            <div>
              <div className="text-sm font-medium mb-2">
                Typed Data (EIP-712)
              </div>
              <div className="rounded-md border bg-muted/30 p-3 text-xs font-mono text-foreground break-words whitespace-pre-wrap max-h-[50vh] overflow-auto">
                {pretty}
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
