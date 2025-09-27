// Background script for stupid wallet Safari Extension
// Handles communication between content script and native app

const NATIVE_APP_ID = "co.za.stephancill.stupid-wallet"; // Bundle ID of containing app

// Store site metadata for pending requests so it can be accessed during confirmation
const pendingRequests = new Map();

// Store connection state per domain
const connectedDomains = new Set();

// Clean up old pending requests to prevent memory leaks
function cleanupOldRequests() {
  const now = Date.now();
  const timeout = 5 * 60 * 1000; // 5 minutes timeout

  for (const [requestId, metadata] of pendingRequests.entries()) {
    if (metadata.timestamp && now - metadata.timestamp > timeout) {
      console.log(`Cleaning up expired request: ${requestId}`);
      pendingRequests.delete(requestId);
    }
  }
}

// Run cleanup every 2 minutes
setInterval(cleanupOldRequests, 2 * 60 * 1000);

// Load connection state from storage
async function loadConnectionState() {
  try {
    const result = await browser.storage.local.get(["connectedDomains"]);
    if (result.connectedDomains) {
      result.connectedDomains.forEach((domain) => connectedDomains.add(domain));
      console.log("Loaded connected domains:", Array.from(connectedDomains));
    }
  } catch (error) {
    console.warn("Failed to load connection state:", error);
  }
}

// Save connection state to storage
async function saveConnectionState() {
  try {
    await browser.storage.local.set({
      connectedDomains: Array.from(connectedDomains),
    });
  } catch (error) {
    console.warn("Failed to save connection state:", error);
  }
}

// Check if domain is connected
function isDomainConnected(domain) {
  return connectedDomains.has(domain);
}

// Mark domain as connected
function connectDomain(domain) {
  connectedDomains.add(domain);
  saveConnectionState();
  console.log(`Domain ${domain} connected`);
}

// Disconnect domain
function disconnectDomain(domain) {
  connectedDomains.delete(domain);
  saveConnectionState();
  console.log(`Domain ${domain} disconnected`);
}

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
  const { method, params, requestId } = message;

  console.log("Background received wallet request:", method, params);

  // Extract site metadata from sender
  let siteMetadata = {};
  try {
    if (sender && sender.tab && sender.tab.url) {
      const tab = sender.tab;
      const url = new URL(tab.url);
      siteMetadata = {
        url: tab.url,
        domain: url.hostname,
        scheme: url.protocol.replace(":", ""),
        origin: url.origin,
      };
    } else if (sender && sender.url) {
      const url = new URL(sender.url);
      siteMetadata = {
        url: sender.url,
        domain: url.hostname,
        scheme: url.protocol.replace(":", ""),
        origin: url.origin,
      };
    } else if (sender && sender.frameUrl) {
      // Handle iframe scenarios
      const url = new URL(sender.frameUrl);
      siteMetadata = {
        url: sender.frameUrl,
        domain: url.hostname,
        scheme: url.protocol.replace(":", ""),
        origin: url.origin,
      };
    } else {
      // If no direct URL info, leave siteMetadata empty and let native handler handle fallback
      console.warn("No direct URL information available in sender");
    }
  } catch (error) {
    console.warn("Failed to extract site metadata:", error);
  }

  console.log("Site metadata:", siteMetadata);

  // Store site metadata for this request so it can be accessed during confirmation
  if (requestId) {
    pendingRequests.set(requestId, {
      ...siteMetadata,
      timestamp: Date.now(),
    });
  }

  try {
    switch (method) {
      // Fast methods - confirmation not required
      case "eth_accounts": {
        // Only return accounts if domain is connected
        if (!isDomainConnected(siteMetadata.domain)) {
          return sendResponse({ result: [] });
        }
        const native = await callNative({
          method,
          params,
          siteMetadata,
        });
        if (native && native.result)
          return sendResponse({ result: native.result });
        if (native && native.error)
          return sendResponse({ error: native.error });
        return sendResponse({ error: "Request failed" });
      }
      case "stupid_getWalletAddress": {
        // Special method for connection previews - bypasses connection state check
        const native = await callNative({
          method: "eth_accounts", // Use eth_accounts internally to get the address
          params,
          siteMetadata,
        });
        if (native && native.result)
          return sendResponse({ result: native.result });
        if (native && native.error)
          return sendResponse({ error: native.error });
        return sendResponse({ error: "Request failed" });
      }
      case "eth_chainId":
      case "eth_blockNumber":
      case "eth_getTransactionByHash":
      case "wallet_addEthereumChain":
      case "wallet_getCapabilities":
      case "wallet_getCallsStatus":
      case "wallet_switchEthereumChain": {
        const native = await callNative({
          method,
          params,
          siteMetadata,
        });
        if (native && native.result)
          return sendResponse({ result: native.result });
        if (native && native.error)
          return sendResponse({ error: native.error });
        return sendResponse({ error: "Request failed" });
      }
      case "wallet_disconnect": {
        // Disconnect the domain
        disconnectDomain(siteMetadata.domain);
        const native = await callNative({
          method,
          params,
          siteMetadata,
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
      case "eth_sendTransaction":
      case "wallet_sendCalls": {
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
  const { approved, method, params, requestId } = message;
  console.log("Handling WALLET_CONFIRM:", approved, method, params);

  if (!approved) {
    // Clean up stored metadata on rejection
    if (requestId) {
      pendingRequests.delete(requestId);
    }
    sendResponse({ error: "User rejected the request" });
    return;
  }

  // Retrieve stored site metadata for this request
  const storedData = requestId ? pendingRequests.get(requestId) : null;
  const siteMetadata =
    storedData && typeof storedData === "object" ? storedData : {};
  console.log("Retrieved site metadata for confirmation:", siteMetadata);

  try {
    const native = await callNative({
      method,
      params,
      siteMetadata,
    });
    if (native && native.result) {
      // Mark domain as connected for connection methods
      if (
        (method === "eth_requestAccounts" || method === "wallet_connect") &&
        siteMetadata.domain
      ) {
        connectDomain(siteMetadata.domain);
      }

      // Clean up stored metadata after successful confirmation
      if (requestId) {
        pendingRequests.delete(requestId);
      }
      return sendResponse({ result: native.result });
    }
    if (native && native.error) {
      // Clean up stored metadata even on error
      if (requestId) {
        pendingRequests.delete(requestId);
      }
      return sendResponse({ error: native.error });
    }
    // Clean up stored metadata on failure
    if (requestId) {
      pendingRequests.delete(requestId);
    }
    return sendResponse({ error: "Signing failed" });
  } catch (error) {
    console.error("Error confirming:", error);
    // Clean up stored metadata on exception
    if (requestId) {
      pendingRequests.delete(requestId);
    }
    sendResponse({ error: "Failed to confirm request" });
  }
}

// Handle extension installation/startup
browser.runtime.onInstalled.addListener(async () => {
  console.log("stupid wallet Safari Extension installed");
  await loadConnectionState();
});

browser.runtime.onStartup.addListener(async () => {
  console.log("stupid wallet Safari Extension started");
  await loadConnectionState();
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
