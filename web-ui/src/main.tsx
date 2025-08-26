import { App } from "./App";
import { Providers } from "./components/Providers";
import { createShadowMount } from "./shadowHost";
// Initialize the lightweight bridge at document_start
import "./bridge";

function init() {
  // Top-frame only
  try {
    if (window.top !== window) return;
  } catch {
    // Cross-origin frame access can throw; if so, bail
    return;
  }

  // Avoid duplicate mounts
  if (document.getElementById("stupid-wallet-modal-root")) return;

  const { root, container, shadow } = createShadowMount();
  // Mirror host page dark mode onto the shadow host once
  try {
    const isDark = document.documentElement.classList.contains("dark");
    if (isDark) {
      (shadow as any).host?.classList?.add("dark");
    }
  } catch {}
  // Attach to body
  try {
    if (document.body && !container.isConnected) {
      document.body.appendChild(container);
    }
  } catch {}
  root.render(
    <Providers>
      <App container={container} />
    </Providers>
  );
}

if (document.readyState === "loading") {
  window.addEventListener("DOMContentLoaded", init, { once: true });
} else {
  init();
}
