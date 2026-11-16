// Hosts: Health, Services, Scripts and Configs in one tile, as tabs. They are
// housekeeping next to Operations and Dispatch, so they share one pane.
//
// Each tab is the original panel module, mounted the first time it is shown
// and kept mounted after: switching tabs never loses a draft, a running
// script's output or a filter. Each gets its own body and its own slot in the
// tile header; only the active tab's are visible.
import { h, store } from "../lib/dom.js";
import health from "./health.js";
import services from "./services.js";
import scripts from "./scripts.js";
import configs from "./configs.js";

export const TABS = [health, services, scripts, configs];
const TAB_KEY = "hosts.tab";

/** The tab to open: the remembered one if it still exists, else the first. */
export const initialTab = (stored) => (TABS.some((t) => t.id === stored) ? stored : TABS[0].id);

export default {
  id: "hosts",
  label: "Hosts",
  hint: "Health, services, scripts, configs",
  icon: "services",
  group: "Hosts",
  requiresHosts: true,
  mount(ctx) {
    const subs = new Map(); // tab id -> { body, tools, meta, instance }
    const bar = h("div", { class: "hosts-tabs", role: "tablist", "aria-label": "Host tools" });
    const stack = h("div", { class: "hosts-stack" });
    ctx.body.classList.add("flush");
    ctx.body.append(bar, stack);
    let active = null;

    for (const t of TABS) {
      const tab = h("button", { class: "hosts-tab", role: "tab", "data-tab": t.id, "aria-selected": "false" }, t.label);
      tab.addEventListener("click", () => show(t.id));
      bar.append(tab);
    }

    function show(id) {
      active = id;
      store.set(TAB_KEY, id);
      for (const tab of bar.children) tab.setAttribute("aria-selected", String(tab.dataset.tab === id));
      if (!subs.has(id)) {
        const panel = TABS.find((t) => t.id === id);
        const body = h("div", { class: "hosts-body", "data-panel": id });
        const tools = h("span", { class: "hosts-tools" });
        stack.append(body);
        ctx.tools.append(tools);
        const sub = { body, tools, meta: "", instance: null };
        subs.set(id, sub);
        sub.instance = panel.mount({
          ...ctx,
          body,
          tools,
          setMeta: (text) => { sub.meta = text ?? ""; if (active === id) ctx.setMeta(sub.meta); },
        }) ?? {};
      }
      for (const [k, s] of subs) {
        s.body.hidden = k !== id;
        s.tools.hidden = k !== id;
      }
      ctx.setMeta(subs.get(id).meta);
      subs.get(id).instance.layout?.();
    }

    show(initialTab(store.get(TAB_KEY)));

    return {
      layout: () => subs.get(active)?.instance.layout?.(),
      destroy() {
        for (const s of subs.values()) {
          try { s.instance.destroy?.(); } catch (e) { console.error(e); }
          s.tools.remove();
        }
        subs.clear();
      },
    };
  },
};
