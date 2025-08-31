import React from "react";
import { ConnectModal } from "./components/ConnectModal";
import { SignMessageModal } from "./components/SignMessageModal";
import { SignTypedDataModal } from "./components/SignTypedDataModal";
import { SendTxModal } from "./components/SendTxModal";
import { FAST_METHODS, UI_METHODS } from "./lib/constants";

declare const browser: any;

type ApprovalResult =
  | { approved: true; finalResponse: any }
  | { approved: false; finalResponse: any };

type ModalState = {
  method: (typeof UI_METHODS)[number];
  params: any[];
  requestId: string;
  resolve: (r: ApprovalResult) => void;
};

export function App({ container }: { container: HTMLDivElement }) {
  const [modal, setModal] = React.useState<ModalState | null>(null);

  const normalizePersonalSignParams = React.useCallback(
    (params: any[]): [string | undefined, string | undefined] => {
      if (!params || params.length < 2) return [undefined, undefined];
      const p0 = params[0];
      const p1 = params[1];
      if (
        typeof p0 === "string" &&
        p0.startsWith("0x") &&
        typeof p1 === "string"
      ) {
        return [p0, p1];
      } else if (
        typeof p1 === "string" &&
        p1.startsWith("0x") &&
        typeof p0 === "string"
      ) {
        return [p1, p0];
      }
      return [p0, p1];
    },
    []
  );

  const normalizeSignTypedDataV4Params = React.useCallback(
    (params: any[]): [string | undefined, string | undefined] => {
      if (!params || params.length < 2) return [undefined, undefined];
      const p0 = params[0];
      const p1 = params[1];
      if (
        typeof p0 === "string" &&
        p0.startsWith("0x") &&
        typeof p1 === "string"
      ) {
        return [p0, p1];
      } else if (
        typeof p1 === "string" &&
        p1.startsWith("0x") &&
        typeof p0 === "string"
      ) {
        return [p1, p0];
      }
      return [p0, p1];
    },
    []
  );

  React.useEffect(() => {
    const handleMessage = async (event: MessageEvent) => {
      if (event.source !== window) return;
      if (!event.data || event.data.source !== "stupid-wallet-inject") return;

      if (FAST_METHODS.includes(event.data.method)) return; // Non-UI handled by bridge

      const method: ModalState["method"] = event.data.method;

      try {
        const response = await browser.runtime.sendMessage({
          type: "WALLET_REQUEST",
          method,
          params: event.data.params,
          requestId: event.data.requestId,
        });

        const post = (finalResponse: any) => {
          window.postMessage(
            {
              source: "stupid-wallet-content",
              requestId: event.data.requestId,
              response: finalResponse,
            },
            "*"
          );
        };

        if (response && response.pending === true) {
          setModal({
            method,
            params: event.data.params ?? [],
            requestId: event.data.requestId,
            resolve: (r) => post(r.finalResponse),
          });
          return;
        }

        // Non-pending response (edge) -> just forward
        post(response);
      } catch (error: any) {
        window.postMessage(
          {
            source: "stupid-wallet-content",
            requestId: event.data.requestId,
            response: { error: error?.message || "Unknown error" },
          },
          "*"
        );
      }
    };

    window.addEventListener("message", handleMessage);
    return () => window.removeEventListener("message", handleMessage);
  }, [normalizePersonalSignParams, normalizeSignTypedDataV4Params]);

  React.useEffect(() => {
    try {
      container.style.pointerEvents = modal ? "auto" : "none";
    } catch {}
  }, [modal, container]);

  if (!modal) return null;

  const computeParams = (): any[] => {
    switch (modal.method) {
      case "personal_sign": {
        const [messageHex, address] = modal.params as [
          string | undefined,
          string | undefined
        ];
        return [messageHex, address].filter(
          (p): p is string => typeof p === "string"
        );
      }
      case "eth_signTypedData_v4": {
        const [address, typedDataJSON] = modal.params as [
          string | undefined,
          string | undefined
        ];
        return [address, typedDataJSON].filter(
          (p): p is string => typeof p === "string"
        );
      }
      default:
        return modal.params ?? [];
    }
  };

  const onReject = async () => {
    try {
      const finalResponse = await browser.runtime.sendMessage({
        type: "WALLET_CONFIRM",
        approved: false,
        method: modal.method,
        params: computeParams(),
        requestId: modal.requestId,
      });
      modal.resolve({ approved: false, finalResponse });
      setModal(null);
    } catch (e) {
      throw e;
    }
  };

  const onApprove = async () => {
    try {
      const finalResponse = await browser.runtime.sendMessage({
        type: "WALLET_CONFIRM",
        approved: true,
        method: modal.method,
        params: computeParams(),
        requestId: modal.requestId,
      });
      modal.resolve({ approved: true, finalResponse });
      setModal(null);
    } catch (e) {
      throw e;
    }
  };

  if (
    modal.method === "wallet_connect" ||
    modal.method === "eth_requestAccounts"
  ) {
    console.log("modal params", modal.params);

    return (
      <ConnectModal
        host={location.host}
        onApprove={onApprove}
        onReject={onReject}
        capabilities={modal.params?.[0]?.capabilities}
      />
    );
  }
  if (modal.method === "personal_sign") {
    const [messageHex, address] = modal.params as [
      string | undefined,
      string | undefined
    ];
    return (
      <SignMessageModal
        host={location.host}
        address={address}
        messageHex={messageHex || ""}
        onApprove={onApprove}
        onReject={onReject}
      />
    );
  }
  if (modal.method === "eth_signTypedData_v4") {
    const [address, typedDataJSON] = modal.params as [
      string | undefined,
      string | undefined
    ];
    return (
      <SignTypedDataModal
        host={location.host}
        address={address}
        typedDataJSON={typedDataJSON || ""}
        onApprove={onApprove}
        onReject={onReject}
      />
    );
  }
  if (modal.method === "eth_sendTransaction") {
    return (
      <SendTxModal
        host={location.host}
        tx={modal.params[0] || {}}
        onApprove={onApprove}
        onReject={onReject}
      />
    );
  }
  return null;
}
