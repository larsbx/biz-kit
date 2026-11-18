// Procurement: opens the private coordinator console in its own window
// (src-tauri/src/procurement.rs keeps it on the configured HTTPS origin).
import { openProcurement } from "../lib/api.js";
import { esc, h } from "../lib/dom.js";

export default {
  id: "procurement",
  label: "Procurement",
  hint: "Requests, quotes and orders",
  icon: "procurement",
  group: "Business",
  requiresHosts: false,
  mount(ctx) {
    const error = h("div", { hidden: true });
    const button = h("button", { class: "btn primary" }, "Open procurement console");
    button.addEventListener("click", async () => {
      button.disabled = true;
      button.textContent = "Opening…";
      error.hidden = true;
      try {
        await openProcurement();
      } catch (cause) {
        error.innerHTML = `<p class="err" role="alert">${esc(cause instanceof Error ? cause.message : cause)}</p>
          <p class="hint">Desktop settings file <code>${esc(ctx.info.configPath)}</code></p>`;
        error.hidden = false;
      } finally {
        button.disabled = false;
        button.textContent = "Open procurement console";
      }
    });
    ctx.body.append(
      h("p", {}, "Manage requests, quotes, orders, and evidence in the private coordinator console."),
      button,
      error,
    );
    return {};
  },
};
