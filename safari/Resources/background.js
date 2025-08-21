// Background script for iOS Wallet Safari Extension
// Handles communication between content script and native app

const NATIVE_APP_ID = "co.za.stephancill.ios-wallet"; // Bundle ID of containing app

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
      case "eth_requestAccounts": {
        sendResponse({ pending: true });
        break;
      }
      case "eth_accounts": {
        await handleAccounts(sendResponse);
        break;
      }
      case "eth_chainId": {
        const native = await callNative({ method: "eth_chainId", params: [] });
        if (native && native.result)
          return sendResponse({ result: native.result });
        if (native && native.error)
          return sendResponse({ error: native.error });
        return sendResponse({ result: "0x1" });
      }
      case "eth_blockNumber": {
        const native = await callNative({
          method: "eth_blockNumber",
          params: [],
        });
        if (native && native.result)
          return sendResponse({ result: native.result });
        if (native && native.error)
          return sendResponse({ error: native.error });
        return sendResponse({ error: "Failed to get block number" });
      }
      case "wallet_addEthereumChain": {
        const native = await callNative({
          method: "wallet_addEthereumChain",
          params,
        });
        if (native && native.result)
          return sendResponse({ result: native.result });
        if (native && native.error)
          return sendResponse({ error: native.error });
        return sendResponse({ error: "Failed to add chain" });
      }
      case "wallet_switchEthereumChain": {
        const native = await callNative({
          method: "wallet_switchEthereumChain",
          params,
        });
        if (native && native.result)
          return sendResponse({ result: native.result });
        if (native && native.error)
          return sendResponse({ error: native.error });
        return sendResponse({ error: "Failed to switch chain" });
      }
      case "eth_signTypedData_v4": {
        // Show in-page modal first; complete after approval
        sendResponse({ pending: true });
        break;
      }
      case "personal_sign": {
        // Show in-page modal first; complete after approval
        sendResponse({ pending: true });
        break;
      }
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
    if (method === "eth_requestAccounts") {
      const native = await callNative({
        method: "eth_requestAccounts",
        params: [],
      });
      if (native && native.result)
        return sendResponse({ result: native.result });
      if (native && native.error) return sendResponse({ error: native.error });
      return sendResponse({ result: [] });
    }

    if (method === "personal_sign") {
      const native = await callNative({
        method: "personal_sign",
        params: params || [],
      });
      if (native && native.result)
        return sendResponse({ result: native.result });
      if (native && native.error) return sendResponse({ error: native.error });
      return sendResponse({ error: "Signing failed" });
    }

    if (method === "eth_signTypedData_v4") {
      const native = await callNative({
        method: "eth_signTypedData_v4",
        params: params || [],
      });
      if (native && native.result)
        return sendResponse({ result: native.result });
      if (native && native.error) return sendResponse({ error: native.error });
      return sendResponse({ error: "Signing failed" });
    }

    if (method === "eth_sendTransaction") {
      const native = await callNative({
        method: "eth_sendTransaction",
        params: params || [],
      });
      if (native && native.result)
        return sendResponse({ result: native.result });
      if (native && native.error) return sendResponse({ error: native.error });
      return sendResponse({ error: "Transaction failed" });
    }

    return sendResponse({ error: `Unsupported confirm method ${method}` });
  } catch (error) {
    console.error("Error confirming:", error);
    sendResponse({ error: "Failed to confirm request" });
  }
}

async function handleAccounts(sendResponse) {
  try {
    const native = await callNative({
      method: "eth_accounts",
      params: [],
    });

    if (native && native.result) {
      console.log("Returning accounts (native):", native.result);
      sendResponse({ result: native.result });
    } else if (native && native.error) {
      console.error("Native handler error:", native.error);
      sendResponse({ error: native.error });
    } else {
      console.log("No accounts found");
      sendResponse({ result: [] });
    }
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
