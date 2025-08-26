import { createRoot, Root } from "react-dom/client";
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

  const rootEl = document.createElement("div");
  // Tailwind base context so shadcn tokens/utilities apply within the shadow tree
  rootEl.className = "font-sans text-foreground";
  // Enable interactions for content rendered inside the shadow root
  rootEl.style.pointerEvents = "auto";
  const portalEl = document.createElement("div");

  const styleEl = document.createElement("style");
  styleEl.textContent = shadowCss as string;
  shadow.appendChild(styleEl);
  shadow.appendChild(rootEl);
  shadow.appendChild(portalEl);

  // iOS: ensure scroll inside shadow tree doesn't bubble to page/drawer handlers
  const isScrollable = (el: Element | null): boolean => {
    if (!el || !(el instanceof HTMLElement)) return false;
    const cs = getComputedStyle(el);
    const canScrollY =
      (cs.overflowY === "auto" || cs.overflowY === "scroll") &&
      el.scrollHeight > el.clientHeight;
    const canScrollX =
      (cs.overflowX === "auto" || cs.overflowX === "scroll") &&
      el.scrollWidth > el.clientWidth;
    return canScrollX || canScrollY;
  };
  const findScrollable = (start: EventTarget | null): HTMLElement | null => {
    let el: any = start;
    while (el && el !== rootEl && el !== portalEl) {
      if (isScrollable(el)) return el as HTMLElement;
      el = el.parentElement;
    }
    return null;
  };
  const onTouchMoveCapture = (e: Event) => {
    const target = (e as any).composedPath
      ? ((e as any).composedPath()[0] as Element)
      : (e.target as Element);
    const scrollable = findScrollable(target);
    if (scrollable) e.stopPropagation();
  };
  const onWheelCapture = (e: Event) => {
    const target = (e as any).composedPath
      ? ((e as any).composedPath()[0] as Element)
      : (e.target as Element);
    const scrollable = findScrollable(target);
    if (scrollable) e.stopPropagation();
  };
  const hostEl = (shadow as any).host ?? container;
  try {
    hostEl.addEventListener("touchmove", onTouchMoveCapture, {
      capture: true,
      passive: true,
    });
    hostEl.addEventListener("wheel", onWheelCapture, {
      capture: true,
      passive: true,
    });
  } catch {}

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
