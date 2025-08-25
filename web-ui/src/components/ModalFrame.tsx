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

type ModalFrameProps = {
  title: string;
  children: React.ReactNode;
  primaryLabel: string;
  secondaryLabel: string;
  onPrimary: () => void | Promise<void>;
  onSecondary: () => void;
};

export function ModalFrame(props: ModalFrameProps) {
  const {
    title,
    children,
    primaryLabel,
    secondaryLabel,
    onPrimary,
    onSecondary,
  } = props;
  const [isSubmitting, setIsSubmitting] = React.useState(false);

  const handlePrimaryClick = async () => {
    try {
      setIsSubmitting(true);
      await onPrimary();
    } catch (_) {
      // If the approve action throws, re-enable controls so the user can retry or cancel
      setIsSubmitting(false);
    }
  };
  return (
    <Credenza
      open
      onOpenChange={(isOpen) => {
        if (!isOpen && !isSubmitting) onSecondary();
      }}
    >
      <CredenzaContent className="sm:max-w-lg bg-card text-card-foreground">
        <CredenzaHeader>
          <CredenzaTitle>{title}</CredenzaTitle>
          <CredenzaDescription className="sr-only">{title}</CredenzaDescription>
        </CredenzaHeader>
        <div className="body">{children}</div>
        <CredenzaFooter>
          <div className="flex w-full justify-end gap-2">
            <Button
              variant="secondary"
              onClick={onSecondary}
              disabled={isSubmitting}
            >
              {secondaryLabel}
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
                primaryLabel
              )}
            </Button>
          </div>
        </CredenzaFooter>
      </CredenzaContent>
    </Credenza>
  );
}
