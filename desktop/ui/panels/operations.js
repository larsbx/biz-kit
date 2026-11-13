// Operations: the task host's own /operations page, running inside the app.
// The page is a native child webview (src-tauri/src/operations.rs) laid over
// this tile's body and moved with it -- the Crew Deck's game-tile pattern. It
// signs in and authorizes on its own; this panel only places it.
import { inApp, operationsHide, operationsPlace, operationsReload, operationsStatus } from "../lib/api.js";
import { esc, h } from "../lib/dom.js";
import { icon } from "../lib/icons.js";

/** The rectangle the webview should take, or null when it must be hidden. */
export function placement(rect, { covered, connected }) {
  if (!connected || covered || !rect) return null;
  const r = {
    x: Math.round(rect.left), y: Math.round(rect.top),
    w: Math.round(rect.width), h: Math.round(rect.height),
  };
  return r.w >= 2 && r.h >= 2 ? r : null;
}

export const samePlace = (a, b) =>
  a === b || (a !== null && b !== null && a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h);

export default {
  id: "operations",
  label: "Operations",
  hint: "Today's work across projects",
  icon: "operations",
  group: "Business",
  requiresHosts: false,
  // One native webview: a second tile would only fight the first for it.
  single: true,
  mount(ctx) {
    let alive = true;
    let url = null;
    let shown = null; // the last rectangle sent, or null if hidden
    const hole = h("div", { class: "ops-hole" });
    ctx.body.append(hole);

    const reload = h("button", { class: "icon-btn", title: "Reload the Operations page", "aria-label": "Reload", html: icon("refresh") });
    reload.addEventListener("click", () => operationsReload().catch(problem));
    ctx.tools.append(reload);

    function problem(e) {
      hole.innerHTML = `<div><strong>Operations isn't available</strong><p>${esc(e?.message ?? e)}</p>
        <p class="hint">Desktop settings file <code>${esc(ctx.info.configPath)}</code></p></div>`;
      ctx.setMeta("");
    }

    let queued = false;
    async function place() {
      if (!alive || queued) return;
      queued = true;
      await new Promise((ok) => requestAnimationFrame(ok));
      queued = false;
      if (!alive) return;
      const next = placement(ctx.body.getBoundingClientRect(), { covered: ctx.covered(), connected: url !== null });
      if (samePlace(next, shown)) return;
      shown = next;
      try {
        if (next) await operationsPlace(next);
        else await operationsHide();
      } catch (e) {
        shown = null;
        problem(e);
      }
    }

    const observer = new ResizeObserver(place);
    observer.observe(ctx.body);

    if (!inApp()) {
      problem("Only in the desktop app.");
    } else {
      operationsStatus().then((s) => {
        if (!alive) return;
        if (!s.url) return problem(s.problem ?? "Operations is not configured.");
        url = s.url;
        hole.innerHTML = `<div>Loading <code>${esc(url)}</code>…</div>`;
        ctx.setMeta(new URL(url).host);
        place();
      }).catch(problem);
    }

    return {
      layout: place,
      destroy() {
        alive = false;
        observer.disconnect();
        reload.remove();
        if (shown) operationsHide().catch(() => {});
        shown = null;
      },
    };
  },
};
