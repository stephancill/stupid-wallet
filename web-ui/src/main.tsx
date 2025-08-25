import { App } from "./App";
import { Providers } from "./components/Providers";
import { createShadowMount } from "./shadowHost";
// Ensure head exists early for libraries that inject <style> into document.head
try {
  if (typeof document !== "undefined" && !document.head) {
    const h = document.createElement("head");
    document.documentElement?.insertBefore(
      h,
      document.documentElement.firstChild || null
    );
  }
} catch {}

const { root, container } = createShadowMount();
root.render(
  <Providers>
    <App container={container} />
  </Providers>
);
