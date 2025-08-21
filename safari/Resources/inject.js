//
//  inject.js
//  ios-wallet
//
//  Created by Stephan on 2025/08/17.
//

(function () {
  "use strict";

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
          return this._fetchChainId();

        case "eth_signTypedData_v4": {
          if (!params || params.length < 2) {
            throw new Error("Invalid eth_signTypedData_v4 params");
          }
          // Normalize params: prefer [address, typedDataJSON]
          let address, typedDataJSON;
          const p0 = params[0];
          const p1 = params[1];
          if (typeof p0 === "string" && typeof p1 === "string") {
            // Either [address, json] or [json, address]
            if (p0.startsWith("0x")) {
              address = p0;
              typedDataJSON = p1;
            } else if (p1.startsWith("0x")) {
              address = p1;
              typedDataJSON = p0;
            } else {
              // Fallback assume [address, json]
              address = p0;
              typedDataJSON = p1;
            }
          } else {
            address = p0;
            typedDataJSON = p1;
          }
          return this._signTypedDataV4(address, typedDataJSON);
        }

        case "eth_sendTransaction": {
          if (!params || params.length < 1 || typeof params[0] !== "object") {
            throw new Error("Invalid eth_sendTransaction params");
          }
          const tx = params[0] || {};
          return this._sendTransaction(tx);
        }

        case "personal_sign": {
          if (!params || params.length < 2) {
            throw new Error("Invalid personal_sign params");
          }
          let messageHex, address;
          const p0 = params[0];
          const p1 = params[1];
          if (
            typeof p0 === "string" &&
            p0.startsWith("0x") &&
            typeof p1 === "string"
          ) {
            messageHex = p0;
            address = p1;
          } else if (
            typeof p1 === "string" &&
            p1.startsWith("0x") &&
            typeof p0 === "string"
          ) {
            messageHex = p1;
            address = p0;
          } else {
            messageHex = p0;
            address = p1;
          }
          return this._personalSign(messageHex, address);
        }

        case "eth_getBlockByNumber":
        case "eth_getBalance":
        case "eth_signTransaction":
        case "eth_sign":
        case "eth_signTypedData":
        case "eth_signTypedData_v1":
        case "eth_signTypedData_v3":
          // eth_signTypedData_v4 and eth_sendTransaction handled above
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

          const response = event.data.response;

          // Ignore interim pending responses if any (content doesn't forward them)
          if (response && response.pending) {
            return;
          }

          // Remove listener for final response
          window.removeEventListener("message", responseHandler);

          if (response.error) {
            if (response.error === "User rejected the request") {
              console.log("User rejected the connection request");
            }
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

        // Set timeout to prevent hanging (45 seconds for embedded modal)
        setTimeout(() => {
          window.removeEventListener("message", responseHandler);
          reject(new Error("Request timeout"));
        }, 45000);
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

    // personal_sign helper
    async _personalSign(messageHex, address) {
      return new Promise((resolve, reject) => {
        const requestId = this._generateRequestId();

        const responseHandler = (event) => {
          if (
            event.source !== window ||
            !event.data ||
            event.data.source !== "ios-wallet-content" ||
            event.data.requestId !== requestId
          ) {
            return;
          }

          const response = event.data.response;
          window.removeEventListener("message", responseHandler);

          if (response && response.error) {
            reject(new Error(response.error));
            return;
          }

          resolve(response && response.result);
        };

        window.addEventListener("message", responseHandler);

        window.postMessage(
          {
            source: "ios-wallet-inject",
            method: "personal_sign",
            params: [messageHex, address],
            requestId,
          },
          "*"
        );

        setTimeout(() => {
          window.removeEventListener("message", responseHandler);
          reject(new Error("Request timeout"));
        }, 45000);
      });
    }

    async _fetchChainId() {
      return new Promise((resolve, reject) => {
        const requestId = this._generateRequestId();
        const responseHandler = (event) => {
          if (
            event.source !== window ||
            !event.data ||
            event.data.source !== "ios-wallet-content" ||
            event.data.requestId !== requestId
          ) {
            return;
          }
          const response = event.data.response;
          window.removeEventListener("message", responseHandler);
          if (response && response.error) {
            reject(new Error(response.error));
            return;
          }
          if (response && response.result) {
            this.chainId = response.result;
            this._emit("chainChanged", this.chainId);
          }
          resolve((response && response.result) || this.chainId);
        };
        window.addEventListener("message", responseHandler);
        window.postMessage(
          {
            source: "ios-wallet-inject",
            method: "eth_chainId",
            params: [],
            requestId,
          },
          "*"
        );
        setTimeout(() => {
          window.removeEventListener("message", responseHandler);
          resolve(this.chainId);
        }, 8000);
      });
    }

    // eth_signTypedData_v4 helper
    async _signTypedDataV4(address, typedDataJSON) {
      return new Promise((resolve, reject) => {
        const requestId = this._generateRequestId();

        const responseHandler = (event) => {
          if (
            event.source !== window ||
            !event.data ||
            event.data.source !== "ios-wallet-content" ||
            event.data.requestId !== requestId
          ) {
            return;
          }

          const response = event.data.response;
          window.removeEventListener("message", responseHandler);

          if (response && response.error) {
            reject(new Error(response.error));
            return;
          }

          resolve(response && response.result);
        };

        window.addEventListener("message", responseHandler);

        window.postMessage(
          {
            source: "ios-wallet-inject",
            method: "eth_signTypedData_v4",
            params: [address, typedDataJSON],
            requestId,
          },
          "*"
        );

        setTimeout(() => {
          window.removeEventListener("message", responseHandler);
          reject(new Error("Request timeout"));
        }, 45000);
      });
    }

    // eth_sendTransaction helper
    async _sendTransaction(tx) {
      return new Promise((resolve, reject) => {
        const requestId = this._generateRequestId();

        const responseHandler = (event) => {
          if (
            event.source !== window ||
            !event.data ||
            event.data.source !== "ios-wallet-content" ||
            event.data.requestId !== requestId
          ) {
            return;
          }

          const response = event.data.response;
          window.removeEventListener("message", responseHandler);

          if (response && response.error) {
            reject(new Error(response.error));
            return;
          }

          resolve(response && response.result);
        };

        window.addEventListener("message", responseHandler);

        window.postMessage(
          {
            source: "ios-wallet-inject",
            method: "eth_sendTransaction",
            params: [tx],
            requestId,
          },
          "*"
        );

        setTimeout(() => {
          window.removeEventListener("message", responseHandler);
          reject(new Error("Request timeout"));
        }, 60000);
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
    uuid: "27f084db-06e7-462e-a6b1-fbc985850d42",
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
