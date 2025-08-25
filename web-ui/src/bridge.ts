// Lightweight content bridge that initializes at document_start
// Handles non-UI EIP-1193 requests immediately so autoConnect is fast

const FAST_METHODS = new Set<
  | "eth_accounts"
  | "eth_chainId"
  | "eth_blockNumber"
  | "wallet_addEthereumChain"
  | "wallet_switchEthereumChain"
>([
  "eth_accounts",
  "eth_chainId",
  "eth_blockNumber",
  "wallet_addEthereumChain",
  "wallet_switchEthereumChain",
]);

function postWindowResponse(requestId: string, response: any) {
  try {
    window.postMessage(
      {
        source: "stupid-wallet-content",
        requestId,
        response,
      },
      "*"
    );
  } catch {}
}

function handleWindowMessage(event: MessageEvent) {
  if (event.source !== window) return;
  const data = (event as any).data;
  if (!data || data.source !== "stupid-wallet-inject") return;

  const method: string = data.method;
  const params: any[] = data.params || [];
  const requestId: string = data.requestId;

  if (!FAST_METHODS.has(method as any)) {
    return; // UI flows are handled by the React app
  }

  try {
    browser.runtime
      .sendMessage({ type: "WALLET_REQUEST", method, params, requestId })
      .then((response: any) => {
        postWindowResponse(requestId, response);
      })
      .catch((error: any) => {
        postWindowResponse(requestId, {
          error: error?.message || "Unknown error",
        });
      });
  } catch (error: any) {
    postWindowResponse(requestId, { error: error?.message || "Unknown error" });
  }
}

function handleRuntimeMessage(message: any) {
  if (message && message.type === "WALLET_RESPONSE" && message.requestId) {
    postWindowResponse(message.requestId, message.response);
  }
}

try {
  window.addEventListener("message", handleWindowMessage);
  browser.runtime.onMessage.addListener(handleRuntimeMessage);
} catch {}

// Signal readiness to the injected script early
try {
  window.postMessage({ source: "stupid-wallet-content", type: "ready" }, "*");
} catch {}
