// Lightweight content bridge that initializes at document_start
// Handles non-UI EIP-1193 requests immediately so autoConnect is fast

import { FAST_METHODS } from "./lib/constants";

const DEBUG_PREFIX = "[stupid-wallet-content]";
function debugLog(...args: any[]) {
  try {
    console.debug(DEBUG_PREFIX, ...args);
  } catch {}
}

function postWindowResponse(requestId: string, response: any) {
  try {
    debugLog("postWindowResponse", { requestId, response });
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

  debugLog("handleWindowMessage", { method, params, requestId });

  if (!FAST_METHODS.includes(method as any)) {
    debugLog("delegating to UI flow", { method, requestId });
    return; // UI flows are handled by the React app
  }

  try {
    debugLog("sending runtime request", { method, params, requestId });
    browser.runtime
      .sendMessage({ type: "WALLET_REQUEST", method, params, requestId })
      .then((response: any) => {
        debugLog("runtime response", { requestId, response });
        postWindowResponse(requestId, response);
      })
      .catch((error: any) => {
        debugLog("runtime error", {
          requestId,
          error: error?.message || error,
        });
        postWindowResponse(requestId, {
          error: error?.message || "Unknown error",
        });
      });
  } catch (error: any) {
    debugLog("sendMessage threw", {
      requestId,
      error: error?.message || error,
    });
    postWindowResponse(requestId, { error: error?.message || "Unknown error" });
  }
}

function handleRuntimeMessage(message: any) {
  if (message && message.type === "WALLET_RESPONSE" && message.requestId) {
    debugLog("handleRuntimeMessage", message);
    postWindowResponse(message.requestId, message.response);
  }
}

try {
  window.addEventListener("message", handleWindowMessage);
  browser.runtime.onMessage.addListener(handleRuntimeMessage);
  debugLog("listeners registered");
} catch {}

// Signal readiness to the injected script early
try {
  debugLog("posting ready signal");
  window.postMessage({ source: "stupid-wallet-content", type: "ready" }, "*");
} catch {}
