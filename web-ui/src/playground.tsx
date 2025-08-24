import React from "react";
import { createRoot } from "react-dom/client";
import { createShadowMount } from "./shadowHost";
import { ConnectModal } from "./components/ConnectModal";
import { SignMessageModal } from "./components/SignMessageModal";
import { SignTypedDataModal } from "./components/SignTypedDataModal";
import { SendTxModal } from "./components/SendTxModal";

function App() {
  const openConnect = async () => {
    const { root, cleanup } = createShadowMount();
    const onApprove = () => {
      cleanup();
      console.log("approved");
    };
    const onReject = () => {
      cleanup();
      console.log("rejected");
    };
    root.render(
      <ConnectModal
        host={location.host}
        onApprove={onApprove}
        onReject={onReject}
      />
    );
  };

  const openSignMessage = async () => {
    const { root, cleanup } = createShadowMount();
    const onApprove = () => {
      cleanup();
      console.log("sign message approved");
    };
    const onReject = () => {
      cleanup();
      console.log("sign message rejected");
    };
    const messageHex = "0x48656c6c6f2c20706c617967726f756e6421"; // "Hello, playground!"
    root.render(
      <SignMessageModal
        host={location.host}
        address="0xA0Cf…1234"
        messageHex={messageHex}
        onApprove={onApprove}
        onReject={onReject}
      />
    );
  };

  const openSignTypedData = async () => {
    const { root, cleanup } = createShadowMount();
    const onApprove = () => {
      cleanup();
      console.log("sign typed data approved");
    };
    const onReject = () => {
      cleanup();
      console.log("sign typed data rejected");
    };
    const typedData = {
      domain: { name: "Playground", version: "1", chainId: 1 },
      message: {
        contents: "Hello from EIP-712",
        from: { name: "Alice" },
        to: { name: "Bob" },
      },
      primaryType: "Mail",
      types: {
        EIP712Domain: [
          { name: "name", type: "string" },
          { name: "version", type: "string" },
          { name: "chainId", type: "uint256" },
        ],
        Person: [{ name: "name", type: "string" }],
        Mail: [
          { name: "from", type: "Person" },
          { name: "to", type: "Person" },
          { name: "contents", type: "string" },
        ],
      },
    };
    const typedDataJSON = JSON.stringify(typedData);
    root.render(
      <SignTypedDataModal
        host={location.host}
        address="0xA0Cf…1234"
        typedDataJSON={typedDataJSON}
        onApprove={onApprove}
        onReject={onReject}
      />
    );
  };

  const openSendTx = async () => {
    const { root, cleanup } = createShadowMount();
    const onApprove = () => {
      cleanup();
      console.log("send tx approved");
    };
    const onReject = () => {
      cleanup();
      console.log("send tx rejected");
    };
    const tx = {
      to: "0x1111111111111111111111111111111111111111",
      value: "0xde0b6b3a7640000", // 1 ETH in wei
      gas: "0x5208",
      gasPrice: "0x3b9aca00",
      data: "0x",
    };
    root.render(
      <SendTxModal
        host={location.host}
        tx={tx}
        onApprove={onApprove}
        onReject={onReject}
      />
    );
  };

  return (
    <div
      style={{
        padding: 24,
        fontFamily:
          "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
      }}
    >
      <h1>iOS Wallet UI Playground</h1>
      <p>Use this to test React modal components without the extension.</p>
      <button
        onClick={openConnect}
        style={{
          padding: 10,
          borderRadius: 8,
          background: "#2563eb",
          color: "#fff",
          border: 0,
        }}
      >
        Open Connect Modal
      </button>
      <div style={{ height: 12 }} />
      <button
        onClick={openSignMessage}
        style={{
          padding: 10,
          borderRadius: 8,
          background: "#2563eb",
          color: "#fff",
          border: 0,
        }}
      >
        Open Sign Message Modal
      </button>
      <div style={{ height: 12 }} />
      <button
        onClick={openSignTypedData}
        style={{
          padding: 10,
          borderRadius: 8,
          background: "#2563eb",
          color: "#fff",
          border: 0,
        }}
      >
        Open Sign Typed Data Modal
      </button>
      <div style={{ height: 12 }} />
      <button
        onClick={openSendTx}
        style={{
          padding: 10,
          borderRadius: 8,
          background: "#2563eb",
          color: "#fff",
          border: 0,
        }}
      >
        Open Send Tx Modal
      </button>
    </div>
  );
}

const rootEl = document.getElementById("root")!;
createRoot(rootEl).render(<App />);
