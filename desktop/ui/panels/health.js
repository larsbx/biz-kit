// Health: one card per host -- disk, memory, swap, failed units, checks.
// Hosts are probed in parallel: one unreachable box must not stall the rest.

import { hostHealth } from "../lib/api.js";
import { esc, h } from "../lib/dom.js";
import { icon } from "../lib/icons.js";

export const meterClass = (pct) => (pct >= 90 ? "bad" : pct >= 80 ? "warn" : "");
export const gb = (mb) => (mb / 1024).toFixed(1);
export const pct = (used, total) => (total ? Math.round((used / total) * 100) : 0);

/** Short tile summary, e.g. "3 hosts · 1 unreachable · 2 failed units". */
export function summarize(hosts, data) {
  const parts = [`${hosts.length} host${hosts.length === 1 ? "" : "s"}`];
  let down = 0, failed = 0;
  for (const { name } of hosts) {
    const d = data[name];
    if (d === null || (d && !d.reachable)) down++;
    else if (d && !d.error) failed += d.failedUnits?.length ?? 0;
  }
  if (down) parts.push(`${down} unreachable`);
  if (failed) parts.push(`${failed} failed`);
  return parts.join(" · ");
}

const meter = (p) => `<div class="meter"><i class="${meterClass(p)}" style="width:${Math.min(p, 100)}%"></i></div>`;

function card(host, d) {
  let html = `<h3>${esc(host.name)}${d && !d.reachable ? ' <span class="pill bad">unreachable</span>' : ""}</h3>
    <div class="sub">${esc(host.label)}</div>`;
  if (d === undefined) html += `<div class="empty">probing…</div>`;
  else if (d === null) html += `<div class="err">probe failed</div>`;
  if (d?.error) html += `<div class="err">${esc(d.error)}</div>`;
  if (d?.reachable && !d.error) {
    html += `<div class="kv"><span>uptime</span><span>${esc(d.uptime || "—")}</span></div>
      <div class="kv"><span>load</span><span class="mono">${esc(d.load)}</span></div>
      <div class="kv" style="margin-top:6px"><span>disk /</span><span>${esc(d.diskPct)}% · ${esc(d.diskUsed)}/${esc(d.diskTotal)}</span></div>
      ${meter(Number(d.diskPct) || 0)}
      <div class="kv" style="margin-top:6px"><span>memory</span><span>${gb(d.memUsedMb)}/${gb(d.memTotalMb)} GB</span></div>
      ${meter(pct(d.memUsedMb, d.memTotalMb))}`;
    if (d.swapTotalMb > 0) {
      html += `<div class="kv" style="margin-top:6px"><span>swap</span><span>${gb(d.swapUsedMb)}/${gb(d.swapTotalMb)} GB</span></div>
        ${meter(pct(d.swapUsedMb, d.swapTotalMb))}`;
    }
    const f = d.failedUnits ?? [];
    html += `<div class="kv"><span>failed units</span><span class="pill ${f.length ? "warn" : "ok"}">${f.length}</span></div>`;
    if (f.length) {
      html += `<div class="mono" style="font-size:.85rem;color:var(--muted);margin-top:4px">
        ${f.slice(0, 6).map((u) => `<div class="trunc">${esc(u)}</div>`).join("")}
        ${f.length > 6 ? `<div>+${f.length - 6} more</div>` : ""}</div>`;
    }
    (d.checks ?? []).forEach((c, i) => {
      const detail = String(c.detail ?? "");
      html += `<div class="kv"${i === 0 ? ' style="margin-top:8px"' : ""}><span>${esc(c.label)}</span>
        <span class="trunc pill ${c.ok ? "ok" : "bad"}" title="${esc(detail)}" style="max-width:14rem;display:inline-block">${esc(detail.split("\n")[0] || (c.ok ? "ok" : "failed"))}</span></div>`;
    });
  }
  return html;
}

export default {
  id: "health",
  label: "Health",
  hint: "Disk, memory, failures",
  icon: "health",
  group: "Hosts",
  requiresHosts: true,
  mount(ctx) {
    const hosts = ctx.info?.hosts ?? [];
    const data = {}; // name -> Health | null (probe threw) | undefined (pending)
    let loading = false, dead = false;

    const btn = h("button", { class: "icon-btn", title: "Refresh", "aria-label": "Refresh", onclick: () => load() });
    ctx.tools.append(btn);
    const grid = h("div", { class: "cards" });
    ctx.body.replaceChildren(grid);

    const cards = new Map(hosts.map((x) => {
      const el = h("div", { class: "card" });
      grid.append(el);
      return [x.name, el];
    }));
    const draw = (x) => { cards.get(x.name).innerHTML = card(x, data[x.name]); };
    const drawBtn = () => {
      btn.disabled = loading;
      btn.innerHTML = icon("refresh");
      btn.title = loading ? "Refreshing…" : "Refresh";
    };

    async function load() {
      if (loading || dead) return;
      loading = true; drawBtn();
      await Promise.all(hosts.map(async (x) => {
        try { data[x.name] = await hostHealth(x.name); } catch { data[x.name] = null; }
        if (!dead) { draw(x); ctx.setMeta(summarize(hosts, data)); }
      }));
      loading = false;
      if (!dead) drawBtn();
    }

    hosts.forEach(draw);
    drawBtn();
    if (hosts.length) load(); else grid.innerHTML = `<div class="empty">no hosts configured</div>`;

    return { destroy() { dead = true; btn.remove(); } };
  },
};
