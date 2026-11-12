// TaskHost uses the desktop's binary layout and the very same divider controls.
// A section is mounted once. Closing parks it in the DOM; layout edits never
// recreate its forms, feed listeners, selections or signing state.
import { leaf, split, leaves, parseLayout, serialize, layoutFrames, closeLeaf, splitLeaf } from "./layout.js";
import { divider } from "./divider.js";

const EMPTY = "__empty__";
const element = (tag, className, text) => {
  const el = document.createElement(tag);
  el.className = className;
  if (text) el.textContent = text;
  return el;
};
const button = (label, text, action) => {
  const el = element("button", "tile-button", text);
  el.type = "button";
  el.title = label;
  el.setAttribute("aria-label", label);
  el.addEventListener("click", action);
  return el;
};
const read = (key) => { try { return localStorage.getItem(key); } catch { return null; } };
const save = (key, root) => { try { localStorage.setItem(key, JSON.stringify(serialize(root))); } catch { /* layout is optional */ } };

/** Collapse unavailable sections without changing the user's saved layout. */
export function visibleTree(root, available) {
  if (root.t === "leaf") return root.p === EMPTY || available.has(root.p) ? root : null;
  const a = visibleTree(root.a, available), b = visibleTree(root.b, available);
  return a && b ? { ...root, a, b } : a ?? b;
}

/** Choosing an open section swaps positions; a section's IDs must stay unique. */
export function chooseSection(root, id, panel) {
  const current = leaves(root).find((l) => l.id === id);
  if (!current) return root;
  const other = panel === EMPTY ? null : leaves(root).find((l) => l.p === panel);
  const visit = (n) => n.t === "leaf"
    ? n.id === id ? { ...n, p: panel } : n.id === other?.id ? { ...n, p: current.p } : n
    : { ...n, a: visit(n.a), b: visit(n.b) };
  return visit(root);
}

export function restoreSections(raw, ids) {
  const root = parseLayout(raw, new Set([...ids, EMPTY]));
  if (!root) return null;
  const named = leaves(root).map((l) => l.p).filter((p) => p !== EMPTY);
  return new Set(named).size === named.length ? root : null;
}

export function columns(ids) {
  if (!ids.length) return leaf(EMPTY);
  const build = (list, depth = 0) => {
    if (list.length === 1) return leaf(list[0]);
    const middle = Math.ceil(list.length / 2);
    return split(depth % 2 ? "v" : "h", middle / list.length, build(list.slice(0, middle), depth + 1), build(list.slice(middle), depth + 1));
  };
  return build(ids);
}

export function mountTiles({ host, sections, key, defaultLayout }) {
  const byId = new Map(sections.map((p) => [p.id, p]));
  let root = restoreSections(read(key), byId.keys()) ?? defaultLayout();
  let zoomed = null;
  const tiles = new Map(), dividers = new Map();
  const toolbar = element("nav", "tiles-toolbar");
  toolbar.setAttribute("aria-label", "Section layout");
  const add = element("select", "tile-picker");
  add.setAttribute("aria-label", "Add section");
  const reset = button("Reset section layout", "Reset layout", () => { zoomed = null; commit(defaultLayout()); });
  toolbar.append(add, reset, element("span", "tiles-help", "Split · choose a section · drag gaps to resize"));
  const surface = element("div", "section-tiles");
  host.classList.add("tiled-workspace");
  host.append(toolbar, surface);

  const allowed = (p) => !p.node.hidden && !p.gate?.hidden;
  const available = () => new Set(sections.filter(allowed).map((p) => p.id));
  const options = (select, current) => {
    select.replaceChildren();
    const option = (id, label) => {
      const opt = element("option", "", label); opt.value = id; select.append(opt);
    };
    option(EMPTY, select === add ? "Add section…" : "Choose section…");
    for (const p of sections.filter(allowed)) option(p.id, p.label);
    select.value = current ?? EMPTY;
  };
  const tileKey = (l) => l.p === EMPTY ? `empty:${l.id}` : l.p;
  function create(l) {
    const p = byId.get(l.p);
    const el = element("section", "section-tile");
    el.dataset.section = l.p;
    const head = element("div", "section-tile-head");
    const picker = element("select", "tile-picker");
    picker.setAttribute("aria-label", "Section in this tile");
    const body = element("div", "section-tile-body");
    const t = { el, picker, leaf: l, body };
    picker.addEventListener("change", () => commit(chooseSection(root, t.leaf.id, picker.value)));
    const divide = (dir) => {
      zoomed = null;
      const open = new Set(leaves(root).map((n) => n.p));
      const next = sections.find((p) => allowed(p) && !open.has(p.id))?.id ?? EMPTY;
      commit(splitLeaf(root, t.leaf.id, dir, next));
    };
    t.zoom = button("Zoom", "⛶", () => { zoomed = zoomed === t.leaf.id ? null : t.leaf.id; render(); });
    t.close = button("Close tile", "×", () => {
      const next = closeLeaf(root, t.leaf.id);
      if (visibleTree(next, available())) { zoomed = null; commit(next); add.focus(); }
    });
    head.append(picker, button("Split right", "◧", () => divide("h")), button("Split down", "⬒", () => divide("v")), t.zoom, t.close);
    if (p) { p.node.dataset.tileContent = ""; body.append(p.node); }
    else body.append(element("p", "tiles-empty", "Choose a section above. Choosing an open section exchanges its position with this tile."));
    el.append(head, body);
    surface.append(el);
    tiles.set(tileKey(l), t);
    return t;
  }

  // Mount all real sections once, even if closed or gated. Existing application
  // renderers can still look up their IDs and update hidden content as before.
  for (const p of sections) create(leaf(p.id));

  function paint(tree) {
    for (const { leaf: l, style } of layoutFrames(tree).panels) tiles.get(tileKey(l))?.el.setAttribute("style", style);
    for (const { node, style } of layoutFrames(tree).splits) dividers.get(node.id)?.setAttribute("style", style);
  }
  function commit(next) { root = next; save(key, root); render(); }
  function render() {
    const shown = visibleTree(root, available());
    const visible = shown ? leaves(shown) : [];
    if (!visible.some((l) => l.id === zoomed)) zoomed = null;
    surface.classList.toggle("has-zoom", zoomed !== null);
    for (const t of tiles.values()) t.el.hidden = true;
    for (const l of visible) {
      const t = tiles.get(tileKey(l)) ?? create(l);
      t.leaf = l;
      t.el.hidden = zoomed !== null && zoomed !== l.id;
      t.el.classList.toggle("tile-zoomed", zoomed === l.id);
      t.el.setAttribute("aria-label", byId.get(l.p)?.label ?? "Empty tile");
      t.zoom.setAttribute("aria-pressed", String(zoomed === l.id));
      t.zoom.setAttribute("aria-label", zoomed === l.id ? "Restore" : "Zoom");
      t.zoom.title = zoomed === l.id ? "Restore (Esc)" : "Zoom to fill";
      t.close.disabled = visible.length <= 1;
      options(t.picker, l.p);
    }
    for (const [id, t] of tiles) if (id.startsWith("empty:") && !visible.some((l) => tileKey(l) === id)) { t.el.remove(); tiles.delete(id); }
    for (const el of dividers.values()) el.remove();
    dividers.clear();
    if (shown && zoomed === null) for (const { node, style } of layoutFrames(shown).splits) {
      const el = divider(node, {
        getRoot: () => root, commit,
        preview: (next) => { const tree = visibleTree(next, available()); if (tree) paint(tree); },
        focus: (id) => dividers.get(id)?.querySelector(".divider")?.focus(),
      });
      el.setAttribute("style", style); surface.append(el); dividers.set(node.id, el);
    }
    if (shown) paint(shown);
    options(add);
  }

  function open(id) {
    if (!byId.has(id) || !allowed(byId.get(id))) return;
    zoomed = null;
    if (!leaves(root).some((l) => l.p === id)) {
      const visible = visibleTree(root, available());
      const best = visible && leaves(visible).reduce((best, l) => {
        const box = tiles.get(tileKey(l))?.el.getBoundingClientRect();
        const area = (box?.width ?? 0) * (box?.height ?? 0);
        return !best || area > best.area ? { l, area, box } : best;
      }, null);
      commit(best ? splitLeaf(root, best.l.id, best.box.width >= best.box.height ? "h" : "v", id) : split("h", 0.5, root, leaf(id)));
    } else render();
    tiles.get(id)?.picker.focus();
  }
  add.addEventListener("change", () => { if (add.value !== EMPTY) open(add.value); });
  function reveal(target) {
    const p = sections.find((p) => p.node === target || p.node.contains(target));
    if (p && allowed(p)) { open(p.id); return true; }
    return false;
  }
  let pendingHash = true;
  function hash() {
    let id; try { id = decodeURIComponent(location.hash.slice(1)); } catch { return; }
    const target = document.getElementById(id);
    if (target && reveal(target)) pendingHash = false;
  }
  let lastAvailable = [...available()].join("|");
  const observer = new MutationObserver(() => {
    const next = [...available()].join("|");
    if (next === lastAvailable) return;
    lastAvailable = next;
    render();
    if (pendingHash) hash();
  });
  for (const node of new Set(sections.flatMap((p) => [p.node, p.gate]).filter(Boolean))) observer.observe(node, { attributes: true, attributeFilter: ["hidden"] });
  const escape = (e) => {
    if (e.key === "Escape" && zoomed !== null && !document.querySelector("dialog[open]")) { zoomed = null; render(); }
  };
  document.addEventListener("keydown", escape);
  window.addEventListener("hashchange", () => { pendingHash = true; hash(); });
  render(); hash();
  return { open, reveal, refresh: render };
}
