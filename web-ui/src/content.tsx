import React from "react";
// Ensure head exists early for libraries that inject <style> into document.head
try {
  if (typeof document !== "undefined" && !document.head) {
    const h = document.createElement("head");
    document.documentElement?.insertBefore(
      h,
      document.documentElement.firstChild || null
    );
  }
} catch {}
import { createShadowMount } from "./shadowHost";
import { ConnectModal } from "./components/ConnectModal";
import { SignMessageModal } from "./components/SignMessageModal";
import { SignTypedDataModal } from "./components/SignTypedDataModal";
import { SendTxModal } from "./components/SendTxModal";

declare const browser: any;

async function presentConnectModal(): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    const { root, cleanup } = createShadowMount();
    const handleApprove = () => {
      cleanup();
      resolve(true);
    };
    const handleReject = () => {
      cleanup();
      resolve(false);
    };
    root.render(
      <ConnectModal
        host={location.host}
        onApprove={handleApprove}
        onReject={handleReject}
      />
    );
  });
}

async function presentSignMessageModal(
  messageHex: string,
  address?: string
): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    const { root, cleanup } = createShadowMount();
    const onApprove = () => {
      cleanup();
      resolve(true);
    };
    const onReject = () => {
      cleanup();
      resolve(false);
    };
    root.render(
      <SignMessageModal
        host={location.host}
        address={address}
        messageHex={messageHex}
        onApprove={onApprove}
        onReject={onReject}
      />
    );
  });
}

async function presentTypedDataModal(
  typedDataJSON: string,
  address?: string
): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    const { root, cleanup } = createShadowMount();
    const onApprove = () => {
      cleanup();
      resolve(true);
    };
    const onReject = () => {
      cleanup();
      resolve(false);
    };
    root.render(
      <SignTypedDataModal
        host={location.host}
        address={address}
        typedDataJSON={typedDataJSON}
        onApprove={onApprove}
        onReject={onReject}
      />
    );
  });
}

async function presentSendTxModal(tx: Record<string, any>): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    const { root, cleanup } = createShadowMount();
    const onApprove = () => {
      cleanup();
      resolve(true);
    };
    const onReject = () => {
      cleanup();
      resolve(false);
    };
    root.render(
      <SendTxModal
        host={location.host}
        tx={tx}
        onApprove={onApprove}
        onReject={onReject}
      />
    );
  });
}

function normalizePersonalSignParams(
  params: any[]
): [string | undefined, string | undefined] {
  if (!params || params.length < 2) return [undefined, undefined];
  const p0 = params[0];
  const p1 = params[1];
  if (typeof p0 === "string" && p0.startsWith("0x") && typeof p1 === "string") {
    return [p0, p1];
  } else if (
    typeof p1 === "string" &&
    p1.startsWith("0x") &&
    typeof p0 === "string"
  ) {
    return [p1, p0];
  }
  return [p0, p1];
}

function normalizeSignTypedDataV4Params(
  params: any[]
): [string | undefined, string | undefined] {
  if (!params || params.length < 2) return [undefined, undefined];
  const p0 = params[0];
  const p1 = params[1];
  if (typeof p0 === "string" && p0.startsWith("0x") && typeof p1 === "string") {
    return [p0, p1];
  } else if (
    typeof p1 === "string" &&
    p1.startsWith("0x") &&
    typeof p0 === "string"
  ) {
    return [p1, p0];
  }
  return [p0, p1];
}

window.addEventListener("message", async (event) => {
  if (event.source !== window) return;
  if (!event.data || event.data.source !== "stupid-wallet-inject") return;

  try {
    const response = await browser.runtime.sendMessage({
      type: "WALLET_REQUEST",
      method: event.data.method,
      params: event.data.params,
      requestId: event.data.requestId,
    });

    if (
      response &&
      response.pending === true &&
      event.data.method === "eth_requestAccounts"
    ) {
      const approved = await presentConnectModal();
      const finalResponse = await browser.runtime.sendMessage({
        type: "WALLET_CONFIRM",
        approved,
        method: event.data.method,
      });

      window.postMessage(
        {
          source: "stupid-wallet-content",
          requestId: event.data.requestId,
          response: finalResponse,
        },
        "*"
      );
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
      const approved = await presentSignMessageModal(messageHex, address);
      const finalResponse = await browser.runtime.sendMessage({
        type: "WALLET_CONFIRM",
        approved,
        method: event.data.method,
        params: [messageHex, address].filter(Boolean),
      });
      window.postMessage(
        {
          source: "stupid-wallet-content",
          requestId: event.data.requestId,
          response: finalResponse,
        },
        "*"
      );
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
      const approved = await presentTypedDataModal(typedDataJSON, address);
      const finalResponse = await browser.runtime.sendMessage({
        type: "WALLET_CONFIRM",
        approved,
        method: event.data.method,
        params: [address, typedDataJSON].filter(Boolean),
      });
      window.postMessage(
        {
          source: "stupid-wallet-content",
          requestId: event.data.requestId,
          response: finalResponse,
        },
        "*"
      );
      return;
    }

    if (
      response &&
      response.pending === true &&
      event.data.method === "eth_sendTransaction"
    ) {
      const tx = (event.data.params && event.data.params[0]) || {};
      const approved = await presentSendTxModal(tx);
      const finalResponse = await browser.runtime.sendMessage({
        type: "WALLET_CONFIRM",
        approved,
        method: event.data.method,
        params: [tx],
      });
      window.postMessage(
        {
          source: "stupid-wallet-content",
          requestId: event.data.requestId,
          response: finalResponse,
        },
        "*"
      );
      return;
    }

    window.postMessage(
      {
        source: "stupid-wallet-content",
        requestId: event.data.requestId,
        response,
      },
      "*"
    );
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
});

browser.runtime.onMessage.addListener((message: any) => {
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
});

window.postMessage({ source: "stupid-wallet-content", type: "ready" }, "*");
