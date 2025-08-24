import React from "react";
import { Button } from "@/components/ui/button";
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
  onPrimary: () => void;
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
  return (
    <Credenza
      open
      onOpenChange={(isOpen) => {
        if (!isOpen) onSecondary();
      }}
    >
      <CredenzaContent className="sm:max-w-lg bg-card text-card-foreground">
        <CredenzaHeader>
          <CredenzaTitle>{title}</CredenzaTitle>
          <CredenzaDescription className="sr-only">{title}</CredenzaDescription>
        </CredenzaHeader>
        <div className="body">{children}</div>
        <CredenzaFooter>
          <Button variant="secondary" onClick={onSecondary}>
            {secondaryLabel}
          </Button>
          <Button onClick={onPrimary}>{primaryLabel}</Button>
        </CredenzaFooter>
      </CredenzaContent>
    </Credenza>
  );
}
