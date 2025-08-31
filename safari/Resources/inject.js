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
      this.send = this.send.bind(this);
      this.sendAsync = this.sendAsync.bind(this);
      this.enable = this.enable.bind(this);
    }

    // EIP-1193 request method
    async request({ method, params = [] }) {
      console.log(`EIP-1193 request: ${method}`, params);

      switch (method) {
        case "eth_requestAccounts":
        case "wallet_connect":
          return this._requestAccounts({ method, params });

        case "wallet_disconnect":
          return this._handleRequest({ method, params });

        case "eth_accounts":
          return this._getAccounts();

        case "eth_chainId":
          return this._fetchChainId();

        case "wallet_switchEthereumChain": {
          const p = params && params[0];
          const chainId = p && p.chainId;
          if (typeof chainId !== "string") {
            throw new Error("Invalid wallet_switchEthereumChain params");
          }
          // TODO: Refactor these helpers
          return this._switchEthereumChain(chainId);
        }

        case "eth_blockNumber":
        case "wallet_addEthereumChain":
        case "eth_signTypedData_v4":
        case "eth_sendTransaction":
        case "personal_sign":
          return this._handleRequest({ method, params });

        case "eth_getBlockByNumber":
        case "eth_getBalance":
        case "eth_signTransaction":
        case "eth_sign":
        case "eth_signTypedData":
        case "eth_signTypedData_v1":
        case "eth_signTypedData_v3":
          throw new Error(`Method ${method} not implemented yet`);

        default:
          throw new Error(`Unsupported method: ${method}`);
      }
    }

    // Request accounts from the wallet
    async _requestAccounts({ method, params }) {
      return new Promise((resolve, reject) => {
        const requestId = this._generateRequestId();

        // Set up response listener
        const responseHandler = (event) => {
          if (
            event.source !== window ||
            !event.data ||
            event.data.source !== "stupid-wallet-content" ||
            event.data.requestId !== requestId
          ) {
            return;
          }

          const response = event.data.response;

          console.log("wallet_connect response", response);

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

          this.accounts = (response.result?.accounts || []).map(
            (account) => account.address
          );
          this.selectedAddress = this.accounts[0] || null;
          this.isConnected = this.accounts.length > 0;

          // Emit accountsChanged event
          this._emit("accountsChanged", this.accounts);

          if (method === "eth_requestAccounts") {
            // eth_requestAccounts expects an array of addresses
            resolve(this.accounts);
          } else {
            resolve(response.result);
          }
        };

        // Add listener for response
        window.addEventListener("message", responseHandler);

        // Send request to content script
        window.postMessage(
          {
            source: "stupid-wallet-inject",
            method: "wallet_connect",
            params: params || [],
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
            event.data.source !== "stupid-wallet-content" ||
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
            source: "stupid-wallet-inject",
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

    async _fetchChainId() {
      return new Promise((resolve, reject) => {
        const requestId = this._generateRequestId();
        const responseHandler = (event) => {
          if (
            event.source !== window ||
            !event.data ||
            event.data.source !== "stupid-wallet-content" ||
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
            source: "stupid-wallet-inject",
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

    async _addEthereumChain(chainParams) {
      return new Promise((resolve, reject) => {
        const requestId = this._generateRequestId();
        const responseHandler = (event) => {
          if (
            event.source !== window ||
            !event.data ||
            event.data.source !== "stupid-wallet-content" ||
            event.data.requestId !== requestId
          ) {
            return;
          }
          const response = event.data.response;
          window.removeEventListener("message", responseHandler);
          if (response && response.error)
            return reject(new Error(response.error));
          resolve(response && response.result);
        };
        window.addEventListener("message", responseHandler);
        window.postMessage(
          {
            source: "stupid-wallet-inject",
            method: "wallet_addEthereumChain",
            params: [chainParams],
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

    async _switchEthereumChain(chainId) {
      return new Promise((resolve, reject) => {
        const requestId = this._generateRequestId();
        const responseHandler = (event) => {
          if (
            event.source !== window ||
            !event.data ||
            event.data.source !== "stupid-wallet-content" ||
            event.data.requestId !== requestId
          ) {
            return;
          }
          const response = event.data.response;
          window.removeEventListener("message", responseHandler);
          if (response && response.error)
            return reject(new Error(response.error));
          const newChainId = response && response.result;
          if (typeof newChainId === "string") {
            this.chainId = newChainId;
            this._emit("chainChanged", this.chainId);
          }
          resolve(newChainId || true);
        };
        window.addEventListener("message", responseHandler);
        window.postMessage(
          {
            source: "stupid-wallet-inject",
            method: "wallet_switchEthereumChain",
            params: [{ chainId }],
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

    async _handleRequest({ method, params }) {
      return new Promise((resolve, reject) => {
        const requestId = this._generateRequestId();

        const responseHandler = (event) => {
          if (
            event.source !== window ||
            !event.data ||
            event.data.source !== "stupid-wallet-content" ||
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
            source: "stupid-wallet-inject",
            method,
            params,
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
          .then((result) => {
            console.log("send callback", result);
            return callback(null, { id: payload.id, jsonrpc: "2.0", result });
          })
          .catch((error) => callback(error, null));
      }
    }

    sendAsync(payload, callback) {
      console.warn(
        "ethereum.sendAsync() is deprecated. Use ethereum.request() instead."
      );
      this.send(payload, callback);
    }

    // Legacy enable method (deprecated, but needed for backwards compatibility)
    async enable() {
      console.warn(
        "ethereum.enable() is deprecated. Use ethereum.request({ method: 'eth_requestAccounts' }) instead."
      );
      return this.request({ method: "eth_requestAccounts", params: [] });
    }
  }

  // Create provider instance
  const provider = new EthereumProvider();

  // Add additional properties for compatibility
  provider.isMetaMask = false; // Explicitly set to false to avoid confusion
  provider.isStupid = true; // Custom identifier
  provider._metamask = undefined; // Ensure this doesn't exist

  // EIP-6963 Provider Info
  const providerInfo = {
    uuid: "27f084db-06e7-462e-a6b1-fbc985850d42",
    name: "stupid wallet",
    icon: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGQAAABkCAYAAABw4pVUAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAANeSURBVHgB7ZuBrbIwFIWvf/4B3EDdwBF0Ah3BDXQDdQLdQJ3AEXQDdQLdQDfgcUxMiLYgKnBKzpc0eYEHhn69vW2hjSjGBA3/TFAhIWRICBkSQoaEkCEhZEgIGRJChoSQISFkSAgZEkKGhJAhIWRICBkSQoaEkCEhZEgIGRJChoSQISFkSAgZQQnZ7/fW7/et0WjcC/7ebDZWK6JAWC6X+KDPWdrtdnQ+n6M6EISQ2WzmlZGUstvtotChFnK9XqPRaJQpI1nW63UUMrRCIKPb7eaS8SiIqFChFPKNjEeZTCb3+4QGnZA0Gc1m8+VYmrgQkz3dsBdD2ePx+HI8rniLk/bL8eFwaNvt1mJZL+cul4t1Oh2bz+cWDBER6GbM0dIRBYgctHbz5AucQ0SYJ1p6vV4Q0UIjxDe0fcgAaUIe51HxltKFHQ6HiBkKIaikLBkgS8iD6XTqlYI8xCylciG+rsaVkN8VknZfI0/2lQvxjZJcFeYSgryTRlpeYqRSIb68sVgsnP/vEoKZfBa+LixLZhVUJsS3WDgej73XIJ98IgT4IoVtqaUSIb4kjr49i+fJIUZV7+LrHpmklC4kTxJ38XztOxKTv+2a7aMgYhkoXUg8s3ZWyLtD0edWnkcIWK1W3iExw6JkqULyJnEXzxM/tPi8MEspTYhrhJSVxF24IuwTWKWUJsT1ogndTd4lctd9Pl1mjxclvTmlqrePpQjBw9mbk78sXEK+mXUjd7mk5Bm9/ZJSlt9dy9/xZM3iCLG8fHJNGo9l/ef73m43q4LCheDB8PlOEjx83NLtV+C9xzdAChpIksFgYFXw3wrG1dLi7uDjlt5qtawI0EDwkut0Ot1/45cNJhdRCSSHquivv+nzXaOj0L80SVJ4hAD00XGl3aMFr1x/nQfqRClCwK+6gLrL1MfWZEgIGRJChoSQISFk1ELItzN1JhQhZEgIGRJChoSQISFkSAgZEkKGhJAhIWRICBkSQoaEkCEhZEgIGRJChoSQISFkSAgZEkKGhJAhIWQEJwR7OZ4paotCFQQnBHs4kptrsNeksr0cBdDAngQLEGxtQKnb1/DBCqkrSupkSAgZEkKGhJAhIWRICBkSQoaEkCEhZEgIGRJChoSQISFkSAgZEkKGhJAhIWT8AewWK6g0tBhEAAAAAElFTkSuQmCC",
    rdns: "co.za.stephancill.stupid-wallet",
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
    console.log("setting window.ethereum to provider");
    window.ethereum = provider;
  } else {
    console.log("window.ethereum already exists");
  }

  console.log("stupid wallet provider initialized with EIP-6963 support");
})();
