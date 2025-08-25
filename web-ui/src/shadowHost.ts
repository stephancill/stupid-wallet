import React from "react";
import { createRoot, Root } from "react-dom/client";
// Inline Tailwind CSS into Shadow DOM (using a dedicated bundle to ensure all layers/imports resolve)
// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore
import shadowCss from "./shadow.css?inline";

export type ShadowMount = {
  container: HTMLDivElement;
  cleanup: () => void;
  root: Root;
  shadow: ShadowRoot | HTMLElement;
  rootEl: HTMLDivElement;
  portalEl: HTMLDivElement;
};

let currentPortalContainer: HTMLDivElement | null = null;
export function getPortalContainer(): HTMLDivElement | null {
  return currentPortalContainer;
}

export function createShadowMount(): ShadowMount {
  const container = document.createElement("div");
  container.id = "stupid-wallet-modal-root";
  container.style.position = "fixed";
  container.style.inset = "0";
  container.style.zIndex = "2147483647";
  // Allow host page to remain interactive when no modal is shown
  container.style.pointerEvents = "none";

  let shadow: ShadowRoot | HTMLElement;
  try {
    if (typeof (container as any).attachShadow === "function") {
      shadow = (container as any).attachShadow({ mode: "open" });
    } else {
      shadow = container;
    }
  } catch (_) {
    // Fallback for environments where Shadow DOM is restricted
    shadow = container;
  }

  const tailwindStyle = document.createElement("style");
  tailwindStyle.textContent = shadowCss as string;

  const style = document.createElement("style");
  style.textContent = `
    :host { all: initial; }
    *, *::before, *::after { box-sizing: border-box; }
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

  // Provide shadcn/tailwind CSS variables within the shadow root.
  // Tailwind v4 defines tokens under :root / .dark in the page. Those do not cross into Shadow DOM,
  // so we mirror them on :host here.
  const vars = document.createElement("style");
  vars.textContent = `
    :host {
      --radius: 0.625rem;
      --background: oklch(1 0 0);
      --foreground: oklch(0.145 0 0);
      --card: oklch(1 0 0);
      --card-foreground: oklch(0.145 0 0);
      --popover: oklch(1 0 0);
      --popover-foreground: oklch(0.145 0 0);
      --primary: oklch(0.205 0 0);
      --primary-foreground: oklch(0.985 0 0);
      --secondary: oklch(0.97 0 0);
      --secondary-foreground: oklch(0.205 0 0);
      --muted: oklch(0.97 0 0);
      --muted-foreground: oklch(0.556 0 0);
      --accent: oklch(0.97 0 0);
      --accent-foreground: oklch(0.205 0 0);
      --destructive: oklch(0.577 0.245 27.325);
      --border: oklch(0.922 0 0);
      --input: oklch(0.922 0 0);
      --ring: oklch(0.708 0 0);
    }
    :host(.dark) {
      --background: oklch(0.145 0 0);
      --foreground: oklch(0.985 0 0);
      --card: oklch(0.205 0 0);
      --card-foreground: oklch(0.985 0 0);
      --popover: oklch(0.205 0 0);
      --popover-foreground: oklch(0.985 0 0);
      --primary: oklch(0.922 0 0);
      --primary-foreground: oklch(0.205 0 0);
      --secondary: oklch(0.269 0 0);
      --secondary-foreground: oklch(0.985 0 0);
      --muted: oklch(0.269 0 0);
      --muted-foreground: oklch(0.708 0 0);
      --accent: oklch(0.269 0 0);
      --accent-foreground: oklch(0.985 0 0);
      --destructive: oklch(0.704 0.191 22.216);
      --border: oklch(1 0 0 / 10%);
      --input: oklch(1 0 0 / 15%);
      --ring: oklch(0.556 0 0);
    }
  `;

  const rootEl = document.createElement("div");
  // Tailwind base context so shadcn tokens/utilities apply within the shadow tree
  rootEl.className = "font-sans text-foreground";
  // Enable interactions for content rendered inside the shadow root
  rootEl.style.pointerEvents = "auto";
  const portalEl = document.createElement("div");

  shadow.appendChild(vars);
  shadow.appendChild(tailwindStyle);
  shadow.appendChild(style);
  shadow.appendChild(rootEl);
  shadow.appendChild(portalEl);
  // Attach only to <body> to avoid altering <html> children which can break app frameworks
  const attach = () => {
    if (document.body && !container.isConnected) {
      document.body.appendChild(container);
    }
  };

  if (document.body) {
    attach();
  } else {
    // Wait for body to exist (e.g., during early document load)
    const observer = new MutationObserver(() => {
      if (document.body) {
        attach();
        observer.disconnect();
      }
    });
    try {
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
      });
    } catch {}
    window.addEventListener(
      "DOMContentLoaded",
      () => {
        attach();
        observer.disconnect();
      },
      { once: true }
    );
  }

  const root = createRoot(rootEl);

  const cleanup = () => {
    try {
      root.unmount();
    } catch {}
    container.remove();
    if (currentPortalContainer === portalEl) {
      currentPortalContainer = null;
    }
  };

  currentPortalContainer = portalEl;
  return { container, cleanup, root, shadow, rootEl, portalEl };
}
