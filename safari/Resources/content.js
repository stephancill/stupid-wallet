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

    // Send response back to injected script
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

// Notify injected script that content script is ready
window.postMessage(
  {
    source: "ios-wallet-content",
    type: "ready",
  },
  "*"
);
