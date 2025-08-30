// Background script for stupid wallet Safari Extension
// Handles communication between content script and native app

const NATIVE_APP_ID = "co.za.stephancill.stupid-wallet"; // Bundle ID of containing app

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  console.log("Background received message:", message);

  if (message.type === "WALLET_REQUEST") {
    handleWalletRequest(message, sender, sendResponse);
  } else if (message.type === "WALLET_CONFIRM") {
    handleWalletConfirm(message, sendResponse);
  } else {
    sendResponse({ error: "Unknown message type" });
  }

  return true; // Keep message channel open for async response
});

async function handleWalletRequest(message, sender, sendResponse) {
  const { method, params } = message;

  console.log("Background received wallet request:", method, params);

  try {
    switch (method) {
      // Fast methods - confirmation not required
      case "eth_accounts":
      case "eth_chainId":
      case "eth_blockNumber":
      case "wallet_addEthereumChain":
      case "wallet_switchEthereumChain": {
        const native = await callNative({
          method,
          params,
        });
        if (native && native.result)
          return sendResponse({ result: native.result });
        if (native && native.error)
          return sendResponse({ error: native.error });
        return sendResponse({ error: "Request failed" });
      }
      // Methods that require confirmation
      case "eth_requestAccounts":
      case "wallet_connect":
      case "eth_signTypedData_v4":
      case "personal_sign":
      case "eth_sendTransaction": {
        // Show in-page modal first; complete after approval
        sendResponse({ pending: true });
        break;
      }
      default:
        sendResponse({ error: `Method ${method} not implemented` });
    }
  } catch (error) {
    console.error("Error handling wallet request:", error);
    sendResponse({ error: error.message });
  }
}

async function handleWalletConfirm(message, sendResponse) {
  const { approved, method, params } = message;
  console.log("Handling WALLET_CONFIRM:", approved, method, params);

  if (!approved) {
    sendResponse({ error: "User rejected the request" });
    return;
  }

  try {
    const native = await callNative({
      method,
      params,
    });
    if (native && native.result) return sendResponse({ result: native.result });
    if (native && native.error) return sendResponse({ error: native.error });
    return sendResponse({ error: "Signing failed" });
  } catch (error) {
    console.error("Error confirming:", error);
    sendResponse({ error: "Failed to confirm request" });
  }
}

// Handle extension installation/startup
browser.runtime.onInstalled.addListener(() => {
  console.log("stupid wallet Safari Extension installed");
});

browser.runtime.onStartup.addListener(() => {
  console.log("stupid wallet Safari Extension started");
});

async function callNative(payload) {
  return new Promise((resolve, reject) => {
    browser.runtime.sendNativeMessage(
      NATIVE_APP_ID,
      payload,
      function (response) {
        console.log("Received sendNativeMessage response:");
        console.log(response);
        if (browser.runtime.lastError) {
          reject(new Error(browser.runtime.lastError.message));
        } else {
          resolve(response);
        }
      }
    );
  });
}
