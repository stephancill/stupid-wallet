import React from "react";
import { createRoot, Root } from "react-dom/client";

export type ShadowMount = {
  container: HTMLDivElement;
  cleanup: () => void;
  root: Root;
  shadow: ShadowRoot;
  rootEl: HTMLDivElement;
};

export function createShadowMount(): ShadowMount {
  const container = document.createElement("div");
  container.id = "stupid-wallet-modal-root";
  container.style.position = "fixed";
  container.style.inset = "0";
  container.style.zIndex = "2147483647";

  const shadow = container.attachShadow({ mode: "closed" });

  const style = document.createElement("style");
  style.textContent = `
    @keyframes iosw-fade-in { from { opacity: 0 } to { opacity: 1 } }
    .backdrop { position: fixed; inset: 0; background: rgba(0,0,0,0.4); z-index: 2147483647; }
    .panel {
      position: fixed; left: 50%; top: 50%; transform: translate(-50%, -50%);
      width: min(92vw, 420px); background: #fff; color: #111;
      border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,0.2);
      animation: iosw-fade-in 120ms ease-out;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      overflow: hidden; z-index: 2147483647;
    }
    .header { padding: 16px 20px; border-bottom: 1px solid #eee; font-weight: 600; }
    .body { padding: 16px 20px; }
    .foot { padding: 16px 20px; display: flex; gap: 10px; justify-content: flex-end; }
    .btn { padding: 10px 14px; border-radius: 8px; border: 1px solid transparent; cursor: pointer; font-weight: 600; }
    .btn-secondary { background: #fff; color: #d00; border-color: #e5e5e5; }
    .btn-primary { background: #2563eb; color: #fff; }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .preview { background:#f9fafb; border:1px solid #eee; border-radius:8px; padding:12px; max-height:220px; overflow:auto; white-space:pre-wrap; }
    .meta { color:#555; font-size:12px; margin-bottom: 6px; }
    .row { display:flex; align-items:center; gap:10px; }
    .kv { display:grid; grid-template-columns: 120px 1fr; gap:8px; }
  `;

  const rootEl = document.createElement("div");

  shadow.appendChild(style);
  shadow.appendChild(rootEl);
  document.documentElement.appendChild(container);

  const root = createRoot(rootEl);

  const cleanup = () => {
    try {
      root.unmount();
    } catch {}
    container.remove();
  };

  return { container, cleanup, root, shadow, rootEl };
}
