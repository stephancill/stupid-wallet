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

  const { root, container } = createShadowMount();
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
