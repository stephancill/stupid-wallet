// Background script for iOS Wallet Safari Extension
// Handles communication between content script and native app

const NATIVE_APP_ID = "co.za.stephancill.ios-wallet"; // Bundle ID of containing app

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  console.log("Background received message:", message);

  if (message.type === "WALLET_REQUEST") {
    handleWalletRequest(message, sendResponse);
  } else {
    sendResponse({ error: "Unknown message type" });
  }

  return true; // Keep message channel open for async response
});

async function handleWalletRequest(message, sendResponse) {
  const { method, params } = message;

  try {
    switch (method) {
      case "eth_requestAccounts":
        await handleRequestAccounts(sendResponse);
        break;

      case "eth_accounts":
        await handleGetAccounts(sendResponse);
        break;

      default:
        sendResponse({ error: `Method ${method} not implemented` });
    }
  } catch (error) {
    console.error("Error handling wallet request:", error);
    sendResponse({ error: error.message });
  }
}

async function handleRequestAccounts(sendResponse) {
  try {
    const native = await callNative({
      method: "eth_requestAccounts",
      params: [],
    });
    if (native && native.result) {
      console.log("Returning accounts (native):", native.result);
      sendResponse({ result: native.result });
      return;
    }
    sendResponse({ result: [] });
  } catch (error) {
    console.error("Error requesting accounts:", error);
    sendResponse({ error: "Failed to request accounts" });
  }
}

async function handleGetAccounts(sendResponse) {
  try {
    const native = await callNative({ method: "eth_accounts", params: [] });
    if (native && native.result) {
      console.log("Returning current accounts (native):", native.result);
      sendResponse({ result: native.result });
      return;
    }
    sendResponse({ result: [] });
  } catch (error) {
    console.error("Error getting accounts:", error);
    sendResponse({ error: "Failed to get accounts" });
  }
}

// Handle extension installation/startup
browser.runtime.onInstalled.addListener(() => {
  console.log("iOS Wallet Safari Extension installed");
});

browser.runtime.onStartup.addListener(() => {
  console.log("iOS Wallet Safari Extension started");
});

async function callNative(payload) {
  try {
    // Safari routes native messages to containing app. ID may be ignored but keep for clarity
    if (browser.runtime.sendNativeMessage.length === 2) {
      return await browser.runtime.sendNativeMessage(NATIVE_APP_ID, payload);
    }
    return await browser.runtime.sendNativeMessage(payload);
  } catch (e) {
    console.warn("sendNativeMessage failed:", e);
    return null;
  }
}
