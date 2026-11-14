// This is the frontend embedded by the current Tauri frontendDist (../ui).
import { openProcurement } from "../lib/api.js";
import { readConnection, saveConnection, httpsOrigin } from "../lib/procurement-connection.js";
import { h } from "../lib/dom.js";

export default {
  id: "procurement", label: "Procurement", hint: "Requests, quotes and orders",
  icon: "procurement", group: "Business", requiresHosts: false,
  mount(ctx) {
    let saved = null, busy = false, alive = true;
    const input = h("input", { type: "url", placeholder: "https://procurement.example.org",
      autocomplete: "off", spellcheck: false, "data-procurement-origin": "" });
    const status = h("p", { class: "hint", "data-procurement-status": "" }, "Loading saved connection…");
    const version = h("p", { class: "hint", "data-desktop-version": "" });
    const error = h("p", { class: "err", role: "alert", hidden: true });
    const save = h("button", { class: "btn", type: "button", "data-procurement-save": "" }, "Save server address…");
    const reload = h("button", { class: "btn", type: "button", "data-procurement-reload": "" }, "Reload saved address");
    const open = h("button", { class: "btn primary", type: "button", "data-procurement-open": "" }, "Open procurement console");
    const dirty = () => input.value.trim() !== (saved?.origin ?? "");
    function render() {
      if (!alive) return;
      save.disabled = busy || !saved || !dirty(); reload.disabled = busy; input.disabled = busy;
      open.disabled = busy || !saved?.origin || dirty();
      status.textContent = saved?.origin ? `Saved server: ${saved.origin}` : "No server configured. Enter the private Procurement service's HTTPS origin.";
      version.textContent = saved ? `Desktop ${saved.desktopVersion} · ${saved.configPath}` : "";
    }
    function failed(cause) { if (alive) { error.textContent = String(cause instanceof Error ? cause.message : cause); error.hidden = false; } }
    async function load() {
      if (busy || !alive) return;
      busy = true; error.hidden = true; render();
      try { saved = await readConnection(); if (alive) input.value = saved.origin ?? ""; }
      catch (e) { saved = null; failed(e); }
      finally { busy = false; render(); }
    }
    save.addEventListener("click", async () => {
      if (busy || !saved || !dirty()) return;
      let origin;
      try { origin = httpsOrigin(input.value); } catch (e) { failed(e); return; }
      const expectedRevision = saved.revision;
      busy = true; error.hidden = true; render();
      try {
        await ctx.confirm({
          title: "Save Procurement server address?",
          why: "Only procurementOrigin changes. Other settings are preserved; an existing file is backed up. This does not install or start a server.",
          command: `${saved.configPath}\nprocurementOrigin: ${JSON.stringify(saved.origin)} → ${JSON.stringify(origin)}`,
          host: "this desktop", action: "Save server address", danger: false,
          run: async () => { saved = await saveConnection(origin, expectedRevision); if (alive) input.value = saved.origin ?? ""; },
        });
      } catch (e) { failed(e); }
      finally { busy = false; render(); }
    });
    reload.addEventListener("click", load);
    input.addEventListener("input", render);
    open.addEventListener("click", async () => {
      if (busy || open.disabled) return;
      busy = true; error.hidden = true; render();
      try { await openProcurement(); } catch (e) { failed(e); }
      finally { busy = false; render(); }
    });
    ctx.body.append(h("p", {}, "Manage requests, quotes, orders, and evidence in the private coordinator console."),
      h("label", {}, "Procurement server address", input), h("div", { class: "row" }, save, reload),
      status, open, error, version);
    load();
    return { destroy() { alive = false; } };
  },
};
