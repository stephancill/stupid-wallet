// Content script - bridge between injected script and extension background
// This script runs in the isolated world and can access browser APIs

console.log("iOS Wallet content script loaded");

// Listen for messages from the injected script
window.addEventListener("message", async (event) => {
  // Only accept messages from the same origin
  if (event.source !== window) return;

  // Only handle our wallet messages
  if (!event.data || event.data.source !== "ios-wallet-inject") return;

  console.log("Content script received message:", event.data);

  try {
    // Forward the request to the background script
    const response = await browser.runtime.sendMessage({
      type: "WALLET_REQUEST",
      method: event.data.method,
      params: event.data.params,
      requestId: event.data.requestId,
    });

    console.log("Content script received response:", response);

    // If the request requires in-page confirmation, show embedded modal
    if (
      response &&
      response.pending === true &&
      event.data.method === "eth_requestAccounts"
    ) {
      const approved = await showEmbeddedConnectModal();

      // Send the decision back to background to complete the flow
      const finalResponse = await browser.runtime.sendMessage({
        type: "WALLET_CONFIRM",
        approved,
        method: event.data.method,
      });

      // Send final response back to injected script
      window.postMessage(
        {
          source: "ios-wallet-content",
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
      const approved = await showEmbeddedSignModal(messageHex, address);

      const finalResponse = await browser.runtime.sendMessage({
        type: "WALLET_CONFIRM",
        approved,
        method: event.data.method,
        params: [messageHex, address].filter(Boolean),
      });

      window.postMessage(
        {
          source: "ios-wallet-content",
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
      const approved = await showEmbeddedTypedDataModal(typedDataJSON, address);
      const finalResponse = await browser.runtime.sendMessage({
        type: "WALLET_CONFIRM",
        approved,
        method: event.data.method,
        params: [address, typedDataJSON].filter(Boolean),
      });
      window.postMessage(
        {
          source: "ios-wallet-content",
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
      const approved = await showEmbeddedTxModal(tx);
      const finalResponse = await browser.runtime.sendMessage({
        type: "WALLET_CONFIRM",
        approved,
        method: event.data.method,
        params: [tx],
      });
      window.postMessage(
        {
          source: "ios-wallet-content",
          requestId: event.data.requestId,
          response: finalResponse,
        },
        "*"
      );
      return;
    }

    // Send immediate response back to injected script (no confirmation needed)
    window.postMessage(
      {
        source: "ios-wallet-content",
        requestId: event.data.requestId,
        response: response,
      },
      "*"
    );
  } catch (error) {
    console.error("Content script error:", error);

    // Send error back to injected script
    window.postMessage(
      {
        source: "ios-wallet-content",
        requestId: event.data.requestId,
        response: {
          error: error.message || "Unknown error",
        },
      },
      "*"
    );
  }
});

// Provide a way for background to push final responses in other flows if needed
browser.runtime.onMessage.addListener((message) => {
  if (message && message.type === "WALLET_RESPONSE" && message.requestId) {
    window.postMessage(
      {
        source: "ios-wallet-content",
        requestId: message.requestId,
        response: message.response,
      },
      "*"
    );
  }
});

// Notify injected script that content script is ready
window.postMessage(
  {
    source: "ios-wallet-content",
    type: "ready",
  },
  "*"
);

function normalizePersonalSignParams(params) {
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

function normalizeSignTypedDataV4Params(params) {
  if (!params || params.length < 2) return [undefined, undefined];
  const p0 = params[0];
  const p1 = params[1];
  if (typeof p0 === "string" && p0.startsWith("0x") && typeof p1 === "string") {
    // [address, json] in our normalization
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

// Embedded modal using Shadow DOM to avoid CSS conflicts
async function showEmbeddedConnectModal() {
  return new Promise((resolve) => {
    const container = document.createElement("div");
    container.id = "ios-wallet-modal-root";
    container.style.position = "fixed";
    container.style.inset = "0";
    container.style.zIndex = "2147483647"; // on top

    const shadow = container.attachShadow({ mode: "closed" });

    const style = document.createElement("style");
    style.textContent = `
      @keyframes iosw-fade-in { from { opacity: 0 } to { opacity: 1 } }
      .backdrop { position: fixed; inset: 0; background: rgba(0,0,0,0.4); }
      .panel {
        position: fixed; left: 50%; top: 50%; transform: translate(-50%, -50%);
        width: min(92vw, 420px); background: #fff; color: #111;
        border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,0.2);
        animation: iosw-fade-in 120ms ease-out;
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        overflow: hidden;
      }
      .header { padding: 16px 20px; border-bottom: 1px solid #eee; font-weight: 600; }
      .body { padding: 16px 20px; }
      .foot { padding: 16px 20px; display: flex; gap: 10px; justify-content: flex-end; }
      .btn { padding: 10px 14px; border-radius: 8px; border: 1px solid transparent; cursor: pointer; font-weight: 600; }
      .btn-secondary { background: #fff; color: #d00; border-color: #e5e5e5; }
      .btn-primary { background: #2563eb; color: #fff; }
      .addr { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background: #f5f5f5; padding: 6px 8px; border-radius: 6px; }
    `;

    const wrapper = document.createElement("div");
    wrapper.innerHTML = `
      <div class="backdrop"></div>
      <div class="panel" role="dialog" aria-modal="true" aria-label="Connect Wallet">
        <div class="header">Connect Wallet</div>
        <div class="body">
          <div>This site wants to connect to your wallet.</div>
          <div style="margin-top:8px; font-size:12px; color:#555;">Site: <strong>${location.host}</strong></div>
        </div>
        <div class="foot">
          <button class="btn btn-secondary" id="iosw-reject">Reject</button>
          <button class="btn btn-primary" id="iosw-approve">Connect</button>
        </div>
      </div>
    `;

    shadow.appendChild(style);
    shadow.appendChild(wrapper);
    document.documentElement.appendChild(container);

    const cleanup = () => {
      container.remove();
    };

    shadow.getElementById("iosw-reject").addEventListener("click", () => {
      cleanup();
      resolve(false);
    });

    shadow.getElementById("iosw-approve").addEventListener("click", () => {
      cleanup();
      resolve(true);
    });
  });
}

async function showEmbeddedSignModal(messageHex, address) {
  return new Promise((resolve) => {
    const container = document.createElement("div");
    container.id = "ios-wallet-modal-root";
    container.style.position = "fixed";
    container.style.inset = "0";
    container.style.zIndex = "2147483647";

    const shadow = container.attachShadow({ mode: "closed" });

    const style = document.createElement("style");
    style.textContent = `
      @keyframes iosw-fade-in { from { opacity: 0 } to { opacity: 1 } }
      .backdrop { position: fixed; inset: 0; background: rgba(0,0,0,0.4); }
      .panel { position: fixed; left: 50%; top: 50%; transform: translate(-50%, -50%); width: min(92vw, 520px); background: #fff; color: #111; border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,0.2); animation: iosw-fade-in 120ms ease-out; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; overflow: hidden; }
      .header { padding: 16px 20px; border-bottom: 1px solid #eee; font-weight: 600; }
      .body { padding: 16px 20px; display:flex; flex-direction:column; gap: 10px; }
      .foot { padding: 16px 20px; display: flex; gap: 10px; justify-content: flex-end; }
      .btn { padding: 10px 14px; border-radius: 8px; border: 1px solid transparent; cursor: pointer; font-weight: 600; }
      .btn-secondary { background: #fff; color: #d00; border-color: #e5e5e5; }
      .btn-primary { background: #2563eb; color: #fff; }
      .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
      .preview { background:#f9fafb; border:1px solid #eee; border-radius:8px; padding:12px; max-height:180px; overflow:auto; }
      .meta { color:#555; font-size:12px; }
    `;

    const tryDecode = () => {
      try {
        if (messageHex && messageHex.startsWith("0x")) {
          const bytes = new Uint8Array((messageHex.length - 2) / 2);
          for (let i = 2, j = 0; i < messageHex.length; i += 2, j++) {
            bytes[j] = parseInt(messageHex.slice(i, i + 2), 16);
          }
          const text = new TextDecoder().decode(bytes);
          return text;
        }
      } catch (_) {}
      return null;
    };

    const decoded = tryDecode();

    const wrapper = document.createElement("div");
    wrapper.innerHTML = `
      <div class="backdrop"></div>
      <div class="panel" role="dialog" aria-modal="true" aria-label="Sign Message">
        <div class="header">Sign Message</div>
        <div class="body">
          <div class="meta">Site: <strong>${location.host}</strong></div>
          <div class="meta">Address: <span class="mono">${
            address || "(current)"
          }</span></div>
          <div class="meta">Method: <span class="mono">personal_sign</span></div>
          <div>
            <div style="font-weight:600;margin-bottom:6px;">Message</div>
            <div class="preview mono">${
              decoded
                ? decoded.replace(/</g, "&lt;").replace(/>/g, "&gt;")
                : messageHex
            }</div>
          </div>
        </div>
        <div class="foot">
          <button class="btn btn-secondary" id="iosw-reject">Reject</button>
          <button class="btn btn-primary" id="iosw-approve">Sign</button>
        </div>
      </div>
    `;

    shadow.appendChild(style);
    shadow.appendChild(wrapper);
    document.documentElement.appendChild(container);

    const cleanup = () => container.remove();
    shadow.getElementById("iosw-reject").addEventListener("click", () => {
      cleanup();
      resolve(false);
    });
    shadow.getElementById("iosw-approve").addEventListener("click", () => {
      cleanup();
      resolve(true);
    });
  });
}

async function showEmbeddedTypedDataModal(typedDataJSON, address) {
  return new Promise((resolve) => {
    const container = document.createElement("div");
    container.id = "ios-wallet-modal-root";
    container.style.position = "fixed";
    container.style.inset = "0";
    container.style.zIndex = "2147483647";

    const shadow = container.attachShadow({ mode: "closed" });

    const style = document.createElement("style");
    style.textContent = `
      @keyframes iosw-fade-in { from { opacity: 0 } to { opacity: 1 } }
      .backdrop { position: fixed; inset: 0; background: rgba(0,0,0,0.4); }
      .panel { position: fixed; left: 50%; top: 50%; transform: translate(-50%, -50%); width: min(92vw, 560px); background: #fff; color: #111; border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,0.2); animation: iosw-fade-in 120ms ease-out; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; overflow: hidden; }
      .header { padding: 16px 20px; border-bottom: 1px solid #eee; font-weight: 600; }
      .body { padding: 16px 20px; display:flex; flex-direction:column; gap: 10px; }
      .foot { padding: 16px 20px; display: flex; gap: 10px; justify-content: flex-end; }
      .btn { padding: 10px 14px; border-radius: 8px; border: 1px solid transparent; cursor: pointer; font-weight: 600; }
      .btn-secondary { background: #fff; color: #d00; border-color: #e5e5e5; }
      .btn-primary { background: #2563eb; color: #fff; }
      .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
      .preview { background:#f9fafb; border:1px solid #eee; border-radius:8px; padding:12px; max-height:220px; overflow:auto; white-space:pre-wrap; }
      .meta { color:#555; font-size:12px; }
    `;

    let pretty;
    try {
      pretty = JSON.stringify(JSON.parse(typedDataJSON || "{}"), null, 2);
    } catch (_) {
      pretty = typedDataJSON || "";
    }

    const wrapper = document.createElement("div");
    wrapper.innerHTML = `
      <div class="backdrop"></div>
      <div class="panel" role="dialog" aria-modal="true" aria-label="Sign Typed Data">
        <div class="header">Sign Typed Data</div>
        <div class="body">
          <div class="meta">Site: <strong>${location.host}</strong></div>
          <div class="meta">Address: <span class="mono">${
            address || "(current)"
          }</span></div>
          <div class="meta">Method: <span class="mono">eth_signTypedData_v4</span></div>
          <div>
            <div style="font-weight:600;margin-bottom:6px;">Typed Data (EIP-712)</div>
            <div class="preview mono">${(pretty || "")
              .replace(/</g, "&lt;")
              .replace(/>/g, "&gt;")}</div>
          </div>
        </div>
        <div class="foot">
          <button class="btn btn-secondary" id="iosw-reject">Reject</button>
          <button class="btn btn-primary" id="iosw-approve">Sign</button>
        </div>
      </div>
    `;

    shadow.appendChild(style);
    shadow.appendChild(wrapper);
    document.documentElement.appendChild(container);

    const cleanup = () => container.remove();
    shadow.getElementById("iosw-reject").addEventListener("click", () => {
      cleanup();
      resolve(false);
    });
    shadow.getElementById("iosw-approve").addEventListener("click", () => {
      cleanup();
      resolve(true);
    });
  });
}

async function showEmbeddedTxModal(tx) {
  return new Promise((resolve) => {
    const container = document.createElement("div");
    container.id = "ios-wallet-modal-root";
    container.style.position = "fixed";
    container.style.inset = "0";
    container.style.zIndex = "2147483647";

    const shadow = container.attachShadow({ mode: "closed" });

    const style = document.createElement("style");
    style.textContent = `
      @keyframes iosw-fade-in { from { opacity: 0 } to { opacity: 1 } }
      .backdrop { position: fixed; inset: 0; background: rgba(0,0,0,0.4); }
      .panel { position: fixed; left: 50%; top: 50%; transform: translate(-50%, -50%); width: min(92vw, 560px); background: #fff; color: #111; border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,0.2); animation: iosw-fade-in 120ms ease-out; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; overflow: hidden; }
      .header { padding: 16px 20px; border-bottom: 1px solid #eee; font-weight: 600; }
      .body { padding: 16px 20px; display:flex; flex-direction:column; gap: 10px; }
      .foot { padding: 16px 20px; display: flex; gap: 10px; justify-content: flex-end; }
      .btn { padding: 10px 14px; border-radius: 8px; border: 1px solid transparent; cursor: pointer; font-weight: 600; }
      .btn-secondary { background: #fff; color: #d00; border-color: #e5e5e5; }
      .btn-primary { background: #2563eb; color: #fff; }
      .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
      .row { display:flex; align-items:center; gap:10px; }
      .kv { display:grid; grid-template-columns: 120px 1fr; gap:8px; }
      .preview { background:#f9fafb; border:1px solid #eee; border-radius:8px; padding:12px; max-height:180px; overflow:auto; white-space:pre-wrap; }
    `;

    const to = tx.to || "(contract creation)";
    const value = tx.value || "0x0";
    const data = tx.data || tx.input || "0x";
    const gas = tx.gas || tx.gasLimit || "";
    const gasPrice = tx.maxFeePerGas || tx.gasPrice || "";

    const wrapper = document.createElement("div");
    wrapper.innerHTML = `
      <div class="backdrop"></div>
      <div class="panel" role="dialog" aria-modal="true" aria-label="Send Transaction">
        <div class="header">Send Transaction</div>
        <div class="body">
          <div class="kv">
            <div>To</div><div class="mono">${to}</div>
            <div>Value</div><div class="mono">${value}</div>
            <div>Gas</div><div class="mono">${gas}</div>
            <div>Gas Price/Max Fee</div><div class="mono">${gasPrice}</div>
          </div>
          <div>
            <div style="font-weight:600;margin:10px 0 6px;">Data</div>
            <div class="preview mono">${(data || "0x").slice(0, 820)}</div>
          </div>
        </div>
        <div class="foot">
          <button class="btn btn-secondary" id="iosw-reject">Reject</button>
          <button class="btn btn-primary" id="iosw-approve">Send</button>
        </div>
      </div>
    `;

    shadow.appendChild(style);
    shadow.appendChild(wrapper);
    document.documentElement.appendChild(container);

    const cleanup = () => container.remove();
    shadow.getElementById("iosw-reject").addEventListener("click", () => {
      cleanup();
      resolve(false);
    });
    shadow.getElementById("iosw-approve").addEventListener("click", () => {
      cleanup();
      resolve(true);
    });
  });
}
