// Services: systemd units on one host, with start/stop/restart/enable/disable.
// Flags units whose start limiter can never trip (README "Restart-loop audit").

import { listUnits, unitActionScript, previewCommand, runOn } from "../lib/api.js";
import { esc, h } from "../lib/dom.js";
import { icon } from "../lib/icons.js";

export const ACTIONS = ["start", "stop", "restart", "enable", "disable"];
export const DESTRUCTIVE = new Set(["stop", "disable", "restart"]);
const FILTERS = ["all", "active", "limit"];

export function fmt(s) {
  if (!isFinite(s)) return "∞";
  return s >= 60 ? `${Math.round(s / 60)}min` : `${+s.toFixed(s < 1 ? 3 : 0)}s`;
}

/** Filter by state ("all" | "active" | "limit") and substring; loop risks first, then by id. */
export function shownUnits(units, only, q) {
  const needle = q.toLowerCase();
  return units
    .filter((u) => (only === "active" ? u.active === "active" : only === "limit" ? u.limitUnreachable : true))
    .filter((u) => !needle || u.id.toLowerCase().includes(needle))
    .sort((a, b) => Number(b.limitUnreachable) - Number(a.limitUnreachable) || a.id.localeCompare(b.id));
}

export const loopRisk = (units) => units.filter((u) => u.limitUnreachable).length;

const restarts = (u) => u.restart && u.restart !== "no";

function row(u, i) {
  const activeCls = u.active === "active" ? "ok" : u.active === "failed" ? "bad" : "";
  const limit = u.limitUnreachable
    ? `<span class="pill bad" title="${esc(`${fmt(u.restartSec)} × ${u.limitBurst} ≥ ${fmt(u.limitInterval)} — limiter can never trip`)}">unreachable</span>`
    : restarts(u)
      ? `<span class="pill ok">${esc(u.limitBurst)}/${esc(fmt(u.limitInterval))}</span>`
      : `<span class="pill">—</span>`;
  const btns = ACTIONS.map((a) =>
    `<button class="btn${DESTRUCTIVE.has(a) ? " danger" : ""}" data-i="${i}" data-a="${a}">${a}</button>`).join("");
  return `<tr>
    <td class="mono">${esc(u.id)}</td>
    <td><span class="pill">${esc(u.scope)}</span></td>
    <td><span class="pill ${activeCls}">${esc(u.active)}</span></td>
    <td><span class="pill">${esc(u.enabled)}</span></td>
    <td class="mono" style="color:var(--muted)">${restarts(u) ? esc(`${u.restart} / ${fmt(u.restartSec)}`) : "—"}</td>
    <td>${limit}</td>
    <td><div class="row" style="justify-content:flex-end">${btns}</div></td></tr>`;
}

export default {
  id: "services",
  label: "Services",
  hint: "Start, stop, restart units",
  icon: "services",
  group: "Hosts",
  requiresHosts: true,
  mount(ctx) {
    const hosts = ctx.info?.hosts ?? [];
    let host = hosts[0]?.name ?? "";
    let units = [], shown = [], q = "", only = "all", loading = false, err = null, dead = false, seq = 0;

    const sel = h("select", { "aria-label": "Host", onchange: () => { host = sel.value; load(); } },
      hosts.map((x) => h("option", { value: x.name }, x.name)));
    sel.value = host;
    const chips = h("div", { class: "chips" });
    const input = h("input", { type: "text", placeholder: "Filter…", style: "width:13rem",
      oninput: () => { q = input.value; render(); } });
    const btn = h("button", { class: "btn", title: "Refresh", onclick: () => load() });
    ctx.tools.append(sel, chips, input, btn);

    ctx.body.replaceChildren();
    const onClick = (e) => {
      const b = e.target.closest("button[data-a]");
      if (b && shown[+b.dataset.i]) act(shown[+b.dataset.i], b.dataset.a);
    };
    ctx.body.addEventListener("click", onClick);

    function render() {
      if (dead) return;
      const bad = loopRisk(units);
      chips.innerHTML = FILTERS.map((k) =>
        `<button class="chip${only === k ? " on" : ""}" data-k="${k}">${k === "limit" ? `restart loop risk (${bad})` : k}</button>`).join("");
      btn.disabled = loading;
      btn.innerHTML = `${icon("refresh")} ${loading ? "Loading…" : "Refresh"}`;
      shown = shownUnits(units, only, q);
      let html = err ? `<p class="err">${esc(err)}</p>` : "";
      if (!err && !loading && !shown.length) html += `<div class="empty">no units match</div>`;
      if (shown.length) {
        html += `<table><thead><tr><th>unit</th><th>scope</th><th>active</th><th>enabled</th>
          <th>restart</th><th>limit</th><th></th></tr></thead><tbody>${shown.map(row).join("")}</tbody></table>`;
      }
      ctx.body.innerHTML = html;
      const failed = units.filter((u) => u.active === "failed").length;
      ctx.setMeta(err ? `${host} · error` : loading ? `${host} · loading`
        : [host, `${units.length} units`, failed && `${failed} failed`, bad && `${bad} loop risk`].filter(Boolean).join(" · "));
    }
    chips.addEventListener("click", (e) => {
      const c = e.target.closest("[data-k]");
      if (c) { only = c.dataset.k; render(); }
    });

    async function load() {
      const h0 = host;
      if (!h0) { render(); return; }
      const my = ++seq; // a host switch mid-load must not show the old host's units
      loading = true; err = null; render();
      try { const r = await listUnits(h0); if (my === seq) units = r; }
      catch (e) { if (my === seq) { err = String(e); units = []; } }
      finally { if (my === seq) { loading = false; render(); } }
    }

    async function act(u, action) {
      try {
        const script = await unitActionScript(u.scope, u.id, action);
        const command = await previewCommand(u.host, script);
        await ctx.confirm({
          title: `${action} ${u.id} on ${u.host}?`,
          why: u.scope === "system"
            ? "System scope runs through sudo -n: it fails instead of prompting unless the user has passwordless sudo for this command."
            : undefined,
          command,
          host: u.host,
          danger: DESTRUCTIVE.has(action),
          run: async () => {
            const out = await runOn(u.host, script);
            if (out.code !== 0) throw new Error(out.stderr.trim() || `exit ${out.code}`);
            if (!dead) await load();
          },
        });
      } catch (e) { err = String(e); render(); }
    }

    load();
    return {
      destroy() {
        dead = true; seq++;
        ctx.body.removeEventListener("click", onClick);
        sel.remove(); chips.remove(); input.remove(); btn.remove();
      },
    };
  },
};
