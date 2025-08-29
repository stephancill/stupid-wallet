import React from "react";
import { Button } from "@/components/ui/button";
import { Loader2 } from "lucide-react";
import {
  Credenza,
  CredenzaBody,
  CredenzaContent,
  CredenzaDescription,
  CredenzaFooter,
  CredenzaHeader,
  CredenzaTitle,
} from "@/components/ui/credenza";
import Address from "@/components/Address";

type RequestModalProps = {
  children: React.ReactNode;
  primaryButtonTitle?: string;
  onPrimary: () => void;
  rejectButtonTitle?: string;
  onReject: () => void;
  isSubmitting?: boolean;
  isOpen?: boolean;
  onOpenChange?: (open: boolean) => void;
  footerChildren?: React.ReactNode;
  address?: string;
};

export function RequestModal({
  children,
  primaryButtonTitle = "Confirm",
  onPrimary,
  rejectButtonTitle = "Reject",
  onReject,
  isSubmitting = false,
  isOpen = true,
  onOpenChange,
  footerChildren,
  address,
}: RequestModalProps) {
  const handlePrimaryClick = async () => {
    try {
      await onPrimary();
    } catch (error) {
      // Error handling is done by the parent component
    }
  };

  const handleOpenChange = (open: boolean) => {
    if (!open && !isSubmitting) {
      onReject();
    }
    onOpenChange?.(open);
  };

  return (
    <Credenza open={isOpen} onOpenChange={handleOpenChange}>
      <CredenzaContent className="sm:max-w-lg bg-card text-card-foreground max-h-[85vh] flex flex-col overflow-hidden">
        <CredenzaHeader>
          <CredenzaTitle>stupid wallet ↑</CredenzaTitle>
          <CredenzaDescription className="sr-only">
            Wallet Request
          </CredenzaDescription>
        </CredenzaHeader>
        <CredenzaBody className="flex-1 overflow-y-auto min-h-0">
          <div className="px-2 pb-2 max-h-[60vh] overflow-y-auto">
            {children}
          </div>
        </CredenzaBody>
        <CredenzaFooter>
          <div className="flex w-full items-center justify-between">
            <div className="flex items-center">
              {address && (
                <Address
                  address={address}
                  className="inline-flex items-center text-xs"
                  mono
                  noLink
                />
              )}
            </div>
            <div className="flex items-center gap-2">
              {footerChildren}
              <Button
                variant="secondary"
                onClick={onReject}
                disabled={isSubmitting}
              >
                {rejectButtonTitle}
              </Button>
              <Button
                onClick={handlePrimaryClick}
                disabled={isSubmitting}
                aria-busy={isSubmitting}
              >
                {isSubmitting ? (
                  <span className="inline-flex items-center">
                    <Loader2 className="h-4 w-4 animate-spin" />
                  </span>
                ) : (
                  primaryButtonTitle
                )}
              </Button>
            </div>
          </div>
        </CredenzaFooter>
      </CredenzaContent>
    </Credenza>
  );
}
