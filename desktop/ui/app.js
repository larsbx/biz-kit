// biz-kit desktop shell: the Crew Deck's layout (title bar, sidebar of panels
// and layouts, Settings as a sidebar view, tiles with a picker, split, zoom
// and close), over biz-kit's panels. Plain ES modules, no framework.

import { appInfo, inApp } from "./lib/api.js";
import { $, esc, h, store } from "./lib/dom.js";
import { icon } from "./lib/icons.js";
import { divider } from "./lib/divider.js";
import {
  PRESETS, closeLeaf, currentPreset, layoutFrames, leaves, parseLayout,
  reconcile, retainPanels, serialize, setPanel, splitLeaf,
} from "./lib/layout.js";
import { GROUPS, PANELS, panelById } from "./lib/panels.js";

const LAYOUT_KEY = "layout";
const SIDEBAR_KEY = "sidebar";

// Sidebar order is also the Ctrl+1..9 order.
const ORDER = GROUPS.flatMap((g) => PANELS.filter((p) => p.group === g));

let info = null;
let root = retainPanels(
  parseLayout(store.get(LAYOUT_KEY), new Set(PANELS.map((p) => p.id))) ?? PRESETS[0].build(),
  PRESETS[0].build(),
);
let zoomed = null;
/** leaf id -> { leaf, el, body, tools, meta, instance, confirm } — the live tiles. */
const tiles = new Map();
const dividers = new Map(); // split id -> element
let surface = null;

// ---------- tiles ----------

function setRoot(next) {
  root = next;
  if (zoomed !== null && !leaves(root).some((l) => l.id === zoomed)) zoomed = null;
  render();
}

function unavailable(panel) {
  return panel.requiresHosts && info !== null && info.hosts.length === 0;
}

function nextPanel(current) {
  const open = new Set(leaves(root).map((l) => l.p));
  return (ORDER.find((p) => !open.has(p.id)) ?? panelById(current)).id;
}

function render() {
  if (!info) return;
  if (!surface) {
    surface = h("div", { class: "tile-surface" });
    $("#tiles").replaceChildren(surface);
  }
  const { panels, splits } = layoutFrames(root);
  const plan = reconcile([...tiles.keys()], root);
  for (const id of plan.destroy) destroyTile(id);
  for (const { leaf, style } of panels) {
    const t = tiles.get(leaf.id) ?? createTile(leaf);
    t.leaf = leaf;
    t.el.setAttribute("style", style);
    t.el.classList.toggle("zoomed", zoomed === leaf.id);
    const zoomBtn = t.el.querySelector('[data-act="zoom"]');
    zoomBtn.setAttribute("aria-pressed", String(zoomed === leaf.id));
    zoomBtn.title = zoomed === leaf.id ? "Restore (Esc)" : "Zoom to fill";
    zoomBtn.setAttribute("aria-label", zoomed === leaf.id ? "Restore" : "Zoom");
    zoomBtn.innerHTML = icon(zoomed === leaf.id ? "restore" : "zoom");
    const closeBtn = t.el.querySelector('[data-act="close"]');
    closeBtn.disabled = root.t !== "split";
    closeBtn.title = root.t === "split" ? "Close tile" : "The last tile can't be closed";
  }
  // Dividers are cheap and own no state: rebuild them.
  for (const el of dividers.values()) el.remove();
  dividers.clear();
  for (const { node, style } of splits) {
    const el = buildDivider(node);
    el.setAttribute("style", style);
    surface.append(el);
    dividers.set(node.id, el);
  }
  store.set(LAYOUT_KEY, JSON.stringify(serialize(root)));
  updateSidebar();
  scheduleLayout();
}

function createTile(leaf) {
  const panel = panelById(leaf.p);
  const options = PANELS.map((p) => `<option value="${p.id}"${p.id === leaf.p ? " selected" : ""}>${esc(p.label)}</option>`).join("");
  const el = h("section", { class: `tile ${panel.id}`, "data-panel": panel.id, "aria-label": panel.label });
  const head = h("div", { class: "tile-head" });
  head.innerHTML = `
    <span class="tile-title"><select class="picker" aria-label="Panel in this tile" title="Change what this tile shows">${options}</select></span>
    <span class="tile-meta"></span>
    <span class="tile-tools">
      <span class="tile-slot"></span>
      <button class="icon-btn" data-act="h" title="Split right" aria-label="Split right">${icon("split-h")}</button>
      <button class="icon-btn" data-act="v" title="Split down" aria-label="Split down">${icon("split-v")}</button>
      <button class="icon-btn" data-act="zoom" title="Zoom to fill" aria-label="Zoom" aria-pressed="false">${icon("zoom")}</button>
      <button class="icon-btn" data-act="close" title="Close tile" aria-label="Close tile">${icon("close")}</button>
    </span>`;
  const body = h("div", { class: "tile-body" });
  el.append(head, body);
  surface.append(el);

  const t = { leaf, el, body, tools: $(".tile-slot", head), meta: $(".tile-meta", head), instance: null };
  tiles.set(leaf.id, t);

  $("select", head).addEventListener("change", (e) => setRoot(setPanel(root, t.leaf.id, e.target.value)));
  head.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (!act) return;
    if (act === "h" || act === "v") { zoomed = null; setRoot(splitLeaf(root, t.leaf.id, act, nextPanel(t.leaf.p))); }
    if (act === "zoom") { zoomed = zoomed === t.leaf.id ? null : t.leaf.id; render(); }
    if (act === "close" && root.t === "split") setRoot(closeLeaf(root, t.leaf.id));
  });

  mountPanel(t, panel);
  return t;
}

function mountPanel(t, panel) {
  if (unavailable(panel)) {
    // The header still renders, so the tile can be changed or closed.
    t.body.innerHTML = `<div class="empty">No hosts configured. Add them to <code>${esc(info.configPath)}</code></div>`;
    return;
  }
  const single = panel.single && [...tiles.values()].some((o) => o !== t && o.leaf.p === panel.id && o.instance);
  if (single) {
    t.body.innerHTML = `<div class="empty">${esc(panel.label)} is already open in another tile.</div>`;
    return;
  }
  const ctx = {
    body: t.body,
    tools: t.tools,
    info,
    setMeta: (text) => { t.meta.textContent = text ?? ""; },
    confirm: (ask) => askInTile(t, ask),
    covered: () => zoomed !== null && zoomed !== t.leaf.id,
  };
  try {
    t.instance = panel.mount(ctx) ?? {};
  } catch (e) {
    t.body.innerHTML = `<div class="empty err">${esc(panel.label)} failed to start: ${esc(e)}</div>`;
    t.instance = {};
  }
}

function destroyTile(id) {
  const t = tiles.get(id);
  if (!t) return;
  try { t.instance?.destroy?.(); } catch (e) { console.error(e); }
  t.el.remove();
  tiles.delete(id);
}

function buildDivider(node) {
  return divider(node, {
    getRoot: () => root,
    commit: setRoot,
    preview: (next) => {
      for (const { leaf, style } of layoutFrames(next).panels) tiles.get(leaf.id)?.el.setAttribute("style", style);
      scheduleLayout();
    },
    focus: (id) => dividers.get(id)?.querySelector(".divider")?.focus(),
  });
}

/** Show panel `p`: highlight it if it is open, otherwise split the largest tile along its longer side. */
function addPanel(p) {
  const all = leaves(root);
  const existing = all.find((l) => l.p === p);
  if (existing) {
    if (zoomed !== null) { zoomed = existing.id; render(); }
    const el = tiles.get(existing.id)?.el;
    el?.animate?.([{ outlineColor: "var(--accent)" }, { outlineColor: "transparent" }], { duration: 800, easing: "ease-out" });
    el?.querySelector("select, button")?.focus();
    return;
  }
  let best = null;
  for (const l of all) {
    const r = tiles.get(l.id)?.el.getBoundingClientRect();
    const w = r?.width ?? 0, hgt = r?.height ?? 0;
    if (!best || w * hgt > best.w * best.h) best = { l, w, h: hgt };
  }
  if (!best) return;
  zoomed = null;
  setRoot(splitLeaf(root, best.l.id, best.w >= best.h ? "h" : "v", p));
}

/** Tell every panel its tile may have moved; the Operations webview follows its tile. */
let layoutQueued = false;
function scheduleLayout() {
  if (layoutQueued) return;
  layoutQueued = true;
  requestAnimationFrame(() => {
    layoutQueued = false;
    for (const t of tiles.values()) { try { t.instance?.layout?.(); } catch (e) { console.error(e); } }
  });
}

// ---------- in-tile confirmation ----------

function askInTile(t, ask) {
  t.el.querySelector(".tile-confirm")?.remove();
  return new Promise((resolve) => {
    const err = h("p", { class: "err", hidden: true });
    const cancel = h("button", { class: "btn" }, "Cancel");
    const label = ask.action ?? "Run";
    const go = h("button", { class: `btn ${ask.danger ? "danger" : "go"}` }, label);
    const box = h("div", { class: "tile-confirm", role: "dialog", "aria-label": ask.title },
      h("div", { class: "ask" },
        h("h2", {}, ask.title),
        ask.why ? h("p", { class: "why" }, ask.why) : null,
        h("pre", { class: "out" }, `${ask.host ? `# on ${ask.host}\n` : ""}${ask.command}`),
        err,
        h("div", { class: "actions" }, cancel, go)));
    let busy = false;
    const close = (ok) => {
      if (busy) return;
      box.remove();
      box.removeEventListener("keydown", onKey);
      resolve(ok);
    };
    const onKey = (e) => { if (e.key === "Escape") { e.stopPropagation(); close(false); } };
    cancel.addEventListener("click", () => close(false));
    go.addEventListener("click", async () => {
      busy = true;
      go.disabled = cancel.disabled = true;
      go.textContent = "Running…";
      err.hidden = true;
      try {
        await ask.run?.();
        busy = false;
        close(true);
      } catch (e) {
        busy = false;
        go.disabled = cancel.disabled = false;
        go.textContent = label;
        err.textContent = String(e);
        err.hidden = false;
      }
    });
    box.addEventListener("keydown", onKey);
    t.el.append(box);
    cancel.focus();
  });
}

// ---------- sidebar ----------

const shortcut = (p) => `Ctrl ${ORDER.indexOf(p) + 1}`;

function updateSidebar() {
  const open = new Set(leaves(root).map((l) => l.p));
  $("#panel-groups").innerHTML = GROUPS.map((g) => `
    <section><h2>${esc(g)}</h2><ul class="panel-list">${PANELS.filter((p) => p.group === g).map((p) => {
      const on = open.has(p.id);
      const off = unavailable(p);
      const tip = `${p.label} (${shortcut(p).replace(" ", "+")}): ${on ? "open, click to highlight it" : "click to add it as a tile"}${off ? " — needs a host in the config file" : ""}`;
      return `<li><button class="side-item panel${on ? " on" : ""}${off ? " off" : ""}" data-panel="${p.id}" title="${esc(tip)}" aria-pressed="${on}">
        <span class="glyph">${icon(p.icon)}</span>
        <span class="text"><span class="label">${esc(p.label)}</span><span class="sub">${esc(off ? "No hosts configured" : p.hint)}</span></span>
        <kbd>${ORDER.indexOf(p) + 1}</kbd>
        <span class="state" aria-hidden="true">${on ? "●" : "+"}</span></button></li>`;
    }).join("")}</ul></section>`).join("");
  const preset = currentPreset(root);
  $("#layout-list").innerHTML = PRESETS.map((l) => `
    <li><button class="side-item layout${preset === l.name ? " on" : ""}" data-layout="${esc(l.name)}" aria-pressed="${preset === l.name}" title="${esc(`${l.name}: ${l.hint}`)}">
      <span class="glyph">◫</span>
      <span class="text"><span class="label">${esc(l.name)}</span><span class="sub">${esc(l.hint)}</span></span></button></li>`).join("");
}

$("#panel-groups").addEventListener("click", (e) => {
  const p = e.target.closest("[data-panel]")?.dataset.panel;
  if (p) addPanel(p);
});
$("#layout-list").addEventListener("click", (e) => {
  const name = e.target.closest("[data-layout]")?.dataset.layout;
  const preset = PRESETS.find((l) => l.name === name);
  if (!preset) return;
  zoomed = null;
  setRoot(retainPanels(preset.build(), root));
});

function toggleSidebar(show) {
  document.body.classList.toggle("no-sidebar", show === undefined ? undefined : !show);
  store.set(SIDEBAR_KEY, document.body.classList.contains("no-sidebar") ? "hidden" : "shown");
  scheduleLayout();
}
$("#toggle-sidebar").addEventListener("click", () => toggleSidebar());
if (store.get(SIDEBAR_KEY) === "hidden") document.body.classList.add("no-sidebar");

// ---------- settings (in the sidebar; the Operations webview would cover a dialog) ----------

function showSettings(on) {
  $("#view-deck").hidden = on;
  $("#view-settings").hidden = !on;
  $("#open-settings").classList.toggle("on", on);
  if (on) { toggleSidebar(true); $("#themes input:checked")?.focus(); }
}
function renderPrefs(p) {
  $("#themes").innerHTML = PREFS.THEMES.map((t) => `
    <label class="theme${p.theme === t.id ? " on" : ""}">
      <input type="radio" name="theme" value="${t.id}"${p.theme === t.id ? " checked" : ""}>
      <span class="swatch ${t.id}" aria-hidden="true"><i></i><i></i><i></i></span>
      <span class="label">${esc(t.label)}</span><span class="sub">${esc(t.hint)}</span></label>`).join("");
  const r = $("#font-size");
  r.value = p.fontSize;
  $("#font-value").textContent = `${p.fontSize}px`;
  $("#font-down").disabled = p.fontSize <= PREFS.FONT.min;
  $("#font-up").disabled = p.fontSize >= PREFS.FONT.max;
}
const fontSlider = $("#font-size");
Object.assign(fontSlider, { min: PREFS.FONT.min, max: PREFS.FONT.max, step: PREFS.FONT.step });
$("#font-default").textContent = PREFS.FONT.default;
fontSlider.addEventListener("input", () => PREFS.set({ fontSize: Number(fontSlider.value) }));
$("#font-down").addEventListener("click", () => PREFS.set({ fontSize: PREFS.get().fontSize - PREFS.FONT.step }));
$("#font-up").addEventListener("click", () => PREFS.set({ fontSize: PREFS.get().fontSize + PREFS.FONT.step }));
$("#themes").addEventListener("change", (e) => {
  PREFS.set({ theme: e.target.value });
  $(`#themes input[value="${e.target.value}"]`)?.focus();
});
$("#reset-prefs").addEventListener("click", PREFS.reset);
$("#open-settings").addEventListener("click", () => showSettings($("#view-settings").hidden));
$("#settings-item").addEventListener("click", () => showSettings(true));
$("#close-settings").addEventListener("click", () => showSettings(false));
// A new text size reflows every tile, so the Operations webview has to follow its tile.
PREFS.onChange((p) => { renderPrefs(p); scheduleLayout(); });
renderPrefs(PREFS.get());

// ---------- keys and window ----------

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    if (!$("#view-settings").hidden) { showSettings(false); return; }
    if (zoomed !== null && !document.querySelector(".tile-confirm")) { zoomed = null; render(); return; }
  }
  if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
  const k = e.key.toLowerCase();
  if (k === "b") toggleSidebar();
  else if (k === ",") showSettings($("#view-settings").hidden);
  else if (/^[1-9]$/.test(k) && ORDER[Number(k) - 1]) addPanel(ORDER[Number(k) - 1].id);
  else if (k === "+" || k === "=") PREFS.set({ fontSize: PREFS.get().fontSize + PREFS.FONT.step });
  else if (k === "-") PREFS.set({ fontSize: PREFS.get().fontSize - PREFS.FONT.step });
  else if (k === "0") PREFS.set({ fontSize: PREFS.FONT.default });
  else return;
  e.preventDefault();
});
document.querySelectorAll("[data-win]").forEach((b) => b.addEventListener("click", () => {
  if (inApp()) globalThis.__TAURI__.window.getCurrentWindow()[b.dataset.win]();
}));
window.addEventListener("resize", scheduleLayout);
new ResizeObserver(scheduleLayout).observe($("#tiles"));

// ---------- start ----------

function chips() {
  $("#chips").innerHTML = info.hosts.map((h) =>
    `<span class="chip" title="${esc(h.label || h.name)}${h.ssh ? ` (ssh ${esc(h.ssh)})` : ""}"><span class="dot ${h.ssh ? "" : "ok"}"></span>${esc(h.name)}</span>`).join("");
  $("#sync").textContent = `${info.hosts.length} host${info.hosts.length === 1 ? "" : "s"}`;
  $("#config-path").textContent = info.configPath;
  $("#config-path").title = info.configPath;
}

appInfo().then((i) => {
  info = i;
  chips();
  render();
}).catch((e) => {
  $("#tiles").innerHTML = `<div class="empty err">${esc(e)}</div>`;
  $("#sync").textContent = "config unreadable";
  $("#sync").classList.add("bad");
  updateSidebar();
});
updateSidebar();
