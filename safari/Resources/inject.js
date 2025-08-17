//
//  inject.js
//  ios-wallet
//
//  Created by Stephan on 2025/08/17.
//

(function () {
  "use strict";

  // Generate UUIDv4 compliant identifier
  function generateUUID() {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(
      /[xy]/g,
      function (c) {
        const r = (Math.random() * 16) | 0;
        const v = c == "x" ? r : (r & 0x3) | 0x8;
        return v.toString(16);
      }
    );
  }

  // EIP-1193 Provider Implementation
  class EthereumProvider {
    constructor() {
      this.isConnected = false;
      this.chainId = "0x1"; // Ethereum mainnet
      this.selectedAddress = null;
      this.accounts = [];
      this._events = {};

      // Bind methods to preserve 'this' context
      this.request = this.request.bind(this);
      this.on = this.on.bind(this);
      this.removeListener = this.removeListener.bind(this);
      this.enable = this.enable.bind(this);
      this.send = this.send.bind(this);
      this.sendAsync = this.sendAsync.bind(this);
    }

    // EIP-1193 request method
    async request({ method, params = [] }) {
      console.log(`EIP-1193 request: ${method}`, params);

      switch (method) {
        case "eth_requestAccounts":
          return this._requestAccounts();

        case "eth_accounts":
          return this._getAccounts();

        case "eth_chainId":
          return this.chainId;

        case "eth_getBlockByNumber":
        case "eth_getBalance":
        case "eth_sendTransaction":
        case "eth_signTransaction":
        case "eth_sign":
        case "personal_sign":
        case "eth_signTypedData":
        case "eth_signTypedData_v1":
        case "eth_signTypedData_v3":
        case "eth_signTypedData_v4":
          throw new Error(`Method ${method} not implemented yet`);

        default:
          throw new Error(`Unsupported method: ${method}`);
      }
    }

    // Request accounts from the wallet
    async _requestAccounts() {
      return new Promise((resolve, reject) => {
        const requestId = this._generateRequestId();

        // Set up response listener
        const responseHandler = (event) => {
          if (
            event.source !== window ||
            !event.data ||
            event.data.source !== "ios-wallet-content" ||
            event.data.requestId !== requestId
          ) {
            return;
          }

          // Remove listener
          window.removeEventListener("message", responseHandler);

          const response = event.data.response;

          if (response.error) {
            reject(new Error(response.error));
            return;
          }

          this.accounts = response.result || [];
          this.selectedAddress = this.accounts[0] || null;
          this.isConnected = this.accounts.length > 0;

          // Emit accountsChanged event
          this._emit("accountsChanged", this.accounts);

          resolve(this.accounts);
        };

        // Add listener for response
        window.addEventListener("message", responseHandler);

        // Send request to content script
        window.postMessage(
          {
            source: "ios-wallet-inject",
            method: "eth_requestAccounts",
            params: [],
            requestId: requestId,
          },
          "*"
        );

        // Set timeout to prevent hanging
        setTimeout(() => {
          window.removeEventListener("message", responseHandler);
          reject(new Error("Request timeout"));
        }, 10000);
      });
    }

    // Get current accounts
    async _getAccounts() {
      return new Promise((resolve, reject) => {
        const requestId = this._generateRequestId();

        // Set up response listener
        const responseHandler = (event) => {
          if (
            event.source !== window ||
            !event.data ||
            event.data.source !== "ios-wallet-content" ||
            event.data.requestId !== requestId
          ) {
            return;
          }

          // Remove listener
          window.removeEventListener("message", responseHandler);

          const response = event.data.response;

          if (response.error) {
            reject(new Error(response.error));
            return;
          }

          this.accounts = response.result || [];
          resolve(this.accounts);
        };

        // Add listener for response
        window.addEventListener("message", responseHandler);

        // Send request to content script
        window.postMessage(
          {
            source: "ios-wallet-inject",
            method: "eth_accounts",
            params: [],
            requestId: requestId,
          },
          "*"
        );

        // Set timeout to prevent hanging
        setTimeout(() => {
          window.removeEventListener("message", responseHandler);
          reject(new Error("Request timeout"));
        }, 10000);
      });
    }

    // Generate unique request ID
    _generateRequestId() {
      return `req_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
    }

    // Event handling (EIP-1193)
    on(eventName, listener) {
      if (!this._events[eventName]) {
        this._events[eventName] = [];
      }
      this._events[eventName].push(listener);
    }

    removeListener(eventName, listener) {
      if (!this._events[eventName]) return;
      const index = this._events[eventName].indexOf(listener);
      if (index > -1) {
        this._events[eventName].splice(index, 1);
      }
    }

    _emit(eventName, ...args) {
      if (!this._events[eventName]) return;
      this._events[eventName].forEach((listener) => {
        try {
          listener(...args);
        } catch (error) {
          console.error("Event listener error:", error);
        }
      });
    }

    // Legacy methods for backwards compatibility
    enable() {
      console.warn(
        'ethereum.enable() is deprecated. Use ethereum.request({method: "eth_requestAccounts"}) instead.'
      );
      return this.request({ method: "eth_requestAccounts" });
    }

    send(methodOrPayload, callbackOrParams) {
      console.warn(
        "ethereum.send() is deprecated. Use ethereum.request() instead."
      );

      if (typeof methodOrPayload === "string") {
        // ethereum.send(method, params)
        return this.request({
          method: methodOrPayload,
          params: callbackOrParams || [],
        });
      } else {
        // ethereum.send(payload, callback)
        const payload = methodOrPayload;
        const callback = callbackOrParams;

        this.request({ method: payload.method, params: payload.params || [] })
          .then((result) =>
            callback(null, { id: payload.id, jsonrpc: "2.0", result })
          )
          .catch((error) => callback(error, null));
      }
    }

    sendAsync(payload, callback) {
      console.warn(
        "ethereum.sendAsync() is deprecated. Use ethereum.request() instead."
      );
      this.send(payload, callback);
    }
  }

  // Create provider instance
  const provider = new EthereumProvider();

  // Add additional properties for compatibility
  provider.isMetaMask = false; // Explicitly set to false to avoid confusion
  provider.isIOSWallet = true; // Custom identifier
  provider._metamask = undefined; // Ensure this doesn't exist

  // EIP-6963 Provider Info
  const providerInfo = {
    uuid: generateUUID(),
    name: "iOS Wallet",
    icon: "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' width='96' height='96' viewBox='0 0 96 96'><rect width='96' height='96' rx='12' fill='%234F46E5'/><path d='M48 20L68 40L48 52L28 40L48 20Z' fill='white'/><path d='M28 44L48 56L68 44L48 76L28 44Z' fill='white' opacity='0.8'/></svg>",
    rdns: "co.za.stephancill.ios-wallet",
  };

  // EIP-6963 Provider Detail
  const providerDetail = Object.freeze({
    info: providerInfo,
    provider: provider,
  });

  // EIP-6963 Event Implementation
  function announceProvider() {
    const event = new CustomEvent("eip6963:announceProvider", {
      detail: providerDetail,
    });
    window.dispatchEvent(event);
  }

  // Listen for provider requests
  window.addEventListener("eip6963:requestProvider", () => {
    announceProvider();
  });

  // Initial announcement
  announceProvider();

  // Backwards compatibility - set as window.ethereum if none exists
  if (!window.ethereum) {
    window.ethereum = provider;
  }

  console.log("iOS Wallet provider initialized with EIP-6963 support");
})();
