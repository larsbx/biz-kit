// A usable launcher includes connection setup, not just a command that fails
// when a hand-edited setting is missing. The server still owns sign-in.
import { procurementStatus, saveProcurementOrigin, openProcurement } from "../lib/api.js";
import { h } from "../lib/dom.js";

export function validateOrigin(raw) {
  const value = raw.trim();
  let url;
  try { url = new URL(value); } catch { throw new Error("Enter an HTTPS server origin, such as https://procurement.example.org."); }
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password || url.pathname !== "/" || value.includes("?") || value.includes("#")) {
    throw new Error("Use an HTTPS origin without a path, credentials, query, or fragment.");
  }
  return url.origin + "/";
}

export default {
  id: "procurement",
  label: "Procurement",
  hint: "Requests, quotes and orders",
  icon: "procurement",
  group: "Business",
  requiresHosts: false,
  single: true,
  mount(ctx) {
    let alive = true;
    let busy = false;
    let current = null;
    const status = h("p", { role: "status", "aria-live": "polite", "data-procurement-status": "" }, "Reading Procurement connection…");
    const error = h("p", { class: "err", role: "alert", hidden: true });
    const input = h("input", { type: "url", "aria-label": "Procurement server address", placeholder: "https://procurement.example.org", autocomplete: "off", spellcheck: false });
    const save = h("button", { class: "btn", type: "button", "data-procurement-save": "" }, "Save server address");
    const reload = h("button", { class: "btn", type: "button", "data-procurement-reload": "" }, "Reload connection");
    const open = h("button", { class: "btn primary", type: "button", "data-procurement-open": "" }, "Open procurement console");

    function controls() {
      input.disabled = busy || !current;
      save.disabled = busy || !current;
      reload.disabled = busy;
      open.disabled = busy || !current?.configured;
    }
    function problem(cause) {
      if (!alive) return;
      error.textContent = String(cause instanceof Error ? cause.message : cause);
      error.hidden = false;
    }
    function show(value) {
      current = value;
      input.value = value.origin ?? "";
      status.textContent = value.configured
        ? `Configured server: ${value.origin}. Open the console to connect.`
        : value.problem ?? "Procurement is not configured. Add its server address below.";
      ctx.setMeta(value.configured ? new URL(value.origin).host : "Setup required");
      controls();
    }
    async function refresh() {
      if (busy || !alive) return;
      busy = true;
      error.hidden = true;
      controls();
      try {
        const value = await procurementStatus();
        if (alive) show(value);
      } catch (cause) {
        if (alive) {
          current = null;
          status.textContent = "Cannot read the Procurement connection. Check the settings file below, then reload.";
          ctx.setMeta("Connection error");
          problem(cause);
        }
      } finally {
        busy = false;
        if (alive) controls();
      }
    }
    save.addEventListener("click", async () => {
      if (busy || !current || !alive) return;
      error.hidden = true;
      let origin;
      try { origin = validateOrigin(input.value); } catch (cause) { problem(cause); return; }
      const reviewed = current;
      busy = true;
      controls();
      try {
        const saved = await ctx.confirm({
          title: "Save Procurement server address?",
          why: "Only procurementOrigin changes. This does not install a server, sign in, or send credentials. Close an existing Procurement window before changing servers.",
          command: `${ctx.info.configPath}\nprocurementOrigin: ${JSON.stringify(reviewed.origin)} → ${JSON.stringify(origin)}`,
          action: "Save address",
          run: async () => {
            if (!alive) throw new Error("Procurement tile was closed; reopen it before saving.");
            const value = await saveProcurementOrigin(origin, reviewed.revision);
            if (alive) show(value);
          },
        });
        if (saved && alive) status.textContent = `Saved ${origin}. Open the console to sign in.`;
      } catch (cause) { problem(cause); }
      finally { busy = false; if (alive) controls(); }
    });
    reload.addEventListener("click", refresh);
    open.addEventListener("click", async () => {
      if (busy || !current?.configured || !alive) return;
      busy = true;
      controls();
      open.textContent = "Opening…";
      error.hidden = true;
      try {
        await openProcurement();
        if (alive) status.textContent = "Procurement window opened. Sign in there; an open window alone does not confirm server health.";
      } catch (cause) { problem(cause); }
      finally {
        busy = false;
        if (alive) { open.textContent = "Open procurement console"; controls(); }
      }
    });
    ctx.body.append(
      h("p", {}, "Manage requests, quotes, orders, and evidence in the private coordinator console."),
      status,
      open,
      h("fieldset", {}, h("legend", {}, "Connection"), h("label", {}, "Procurement HTTPS server address", input), h("div", { class: "actions" }, save, reload)),
      h("p", { class: "hint" }, "Use the address of a running Procurement service, not the Operations URL. The quick-start evidence runner stops its test server afterwards."),
      h("p", { class: "hint" }, "Desktop settings file ", h("code", {}, ctx.info.configPath)),
      error,
    );
    controls();
    refresh();
    return { destroy() { alive = false; } };
  },
};
