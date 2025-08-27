// Initialize the lightweight bridge at document_start
import "./bridge";

async function init() {
  // Top-frame only
  try {
    if (window.top !== window) return;
  } catch {
    // Cross-origin frame access can throw; if so, bail
    return;
  }

  // Avoid duplicate mounts
  if (document.getElementById("stupid-wallet-modal-root")) return;

  // Defer importing UI modules with side effects (e.g., CSS injection)
  const [{ createShadowMount }, { App }, { Providers }] = await Promise.all([
    import("./shadowHost"),
    import("./App"),
    import("./components/Providers"),
  ]);

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

function whenHeadReady(cb: () => void) {
  if (document.head) {
    cb();
    return;
  }
  const obs = new MutationObserver(() => {
    if (document.head) {
      obs.disconnect();
      cb();
    }
  });
  obs.observe(document.documentElement || document, {
    childList: true,
    subtree: true,
  });
}

if (document.readyState === "loading") {
  window.addEventListener("DOMContentLoaded", () => whenHeadReady(init), {
    once: true,
  });
} else {
  whenHeadReady(init);
}
