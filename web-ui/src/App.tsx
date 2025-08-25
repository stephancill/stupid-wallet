import React from "react";
import { ConnectModal } from "./components/ConnectModal";
import { SignMessageModal } from "./components/SignMessageModal";
import { SignTypedDataModal } from "./components/SignTypedDataModal";
import { SendTxModal } from "./components/SendTxModal";

declare const browser: any;

type ApprovalResult =
  | { approved: true; finalResponse: any }
  | { approved: false; finalResponse: any };

type ModalState = null | {
  type: "connect" | "personal_sign" | "sign_typed" | "send_tx";
  method:
    | "eth_requestAccounts"
    | "personal_sign"
    | "eth_signTypedData_v4"
    | "eth_sendTransaction";
  params: any[];
  resolve: (r: ApprovalResult) => void;
  tx?: Record<string, any>;
};

export function App({ container }: { container: HTMLDivElement }) {
  const [modal, setModal] = React.useState<ModalState>(null);

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

      try {
        const response = await browser.runtime.sendMessage({
          type: "WALLET_REQUEST",
          method: event.data.method,
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

        if (
          response &&
          response.pending === true &&
          event.data.method === "eth_requestAccounts"
        ) {
          setModal({
            type: "connect",
            method: "eth_requestAccounts",
            params: [],
            resolve: (r) => post(r.finalResponse),
          });
          return;
        }

        if (
          response &&
          response.pending === true &&
          event.data.method === "personal_sign"
        ) {
          const [messageHex, address] = normalizePersonalSignParams(
            event.data.params
          );
          setModal({
            type: "personal_sign",
            method: "personal_sign",
            params: [messageHex, address],
            resolve: (r) => post(r.finalResponse),
          });
          return;
        }

        if (
          response &&
          response.pending === true &&
          event.data.method === "eth_signTypedData_v4"
        ) {
          const [address, typedDataJSON] = normalizeSignTypedDataV4Params(
            event.data.params
          );
          setModal({
            type: "sign_typed",
            method: "eth_signTypedData_v4",
            params: [address, typedDataJSON],
            resolve: (r) => post(r.finalResponse),
          });
          return;
        }

        if (
          response &&
          response.pending === true &&
          event.data.method === "eth_sendTransaction"
        ) {
          const tx = (event.data.params && event.data.params[0]) || {};
          setModal({
            type: "send_tx",
            method: "eth_sendTransaction",
            params: [tx],
            tx,
            resolve: (r) => post(r.finalResponse),
          });
          return;
        }

        // Not pending -> return immediately
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

    const handleRuntimeMessage = (message: any) => {
      if (message && message.type === "WALLET_RESPONSE" && message.requestId) {
        window.postMessage(
          {
            source: "stupid-wallet-content",
            requestId: message.requestId,
            response: message.response,
          },
          "*"
        );
      }
    };

    window.addEventListener("message", handleMessage);
    browser.runtime.onMessage.addListener(handleRuntimeMessage);
    window.postMessage({ source: "stupid-wallet-content", type: "ready" }, "*");

    return () => {
      window.removeEventListener("message", handleMessage);
      try {
        browser.runtime.onMessage.removeListener(handleRuntimeMessage);
      } catch {}
    };
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
      });
      modal.resolve({ approved: true, finalResponse });
      setModal(null);
    } catch (e) {
      throw e;
    }
  };

  if (modal.type === "connect") {
    return (
      <ConnectModal
        host={location.host}
        onApprove={onApprove}
        onReject={onReject}
      />
    );
  }
  if (modal.type === "personal_sign") {
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
  if (modal.type === "sign_typed") {
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
  if (modal.type === "send_tx") {
    return (
      <SendTxModal
        host={location.host}
        tx={modal.tx || {}}
        onApprove={onApprove}
        onReject={onReject}
      />
    );
  }
  return null;
}
