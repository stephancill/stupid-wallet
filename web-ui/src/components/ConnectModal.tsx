import React from "react";
import { useQuery } from "@tanstack/react-query";
import Address from "@/components/Address";
import { RequestModal } from "@/components/RequestModal";

type ConnectModalProps = {
  host: string;
  address?: string;
  onApprove: () => void;
  onReject: () => void;
};

export function ConnectModal({
  host,
  address: providedAddress,
  onApprove,
  onReject,
}: ConnectModalProps) {
  const [isSubmitting, setIsSubmitting] = React.useState(false);

  const { data: accounts, isLoading: isAccountsLoading } = useQuery({
    queryKey: ["accounts"],
    queryFn: async () => {
      const { result }: { result: string[] } =
        await browser.runtime.sendMessage({
          type: "WALLET_REQUEST",
          method: "eth_accounts",
          params: [],
        });
      return result || [];
    },
    enabled: !providedAddress,
  });

  const walletAddress = providedAddress || accounts?.[0];

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
      primaryButtonTitle="Connect"
      onPrimary={handleApprove}
      onReject={onReject}
      isSubmitting={isSubmitting}
    >
      <div className="space-y-4 text-sm">
        <div>This site wants to connect to your wallet.</div>
        <div className="grid grid-cols-[60px_1fr] gap-x-3 gap-y-2">
          <div className="text-muted-foreground">Site</div>
          <div className="break-all">
            <strong className="text-foreground">{host}</strong>
          </div>
          <div className="text-muted-foreground">Wallet</div>
          <div className="break-all">
            {isAccountsLoading && !providedAddress ? (
              <div className="text-muted-foreground">
                Loading wallet address...
              </div>
            ) : walletAddress ? (
              <Address address={walletAddress} mono showEnsAvatar />
            ) : (
              <div className="text-muted-foreground">
                No wallet address available
              </div>
            )}
          </div>
        </div>
      </div>
    </RequestModal>
  );
}
