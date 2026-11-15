// The tiling layout: a binary tree whose leaves are panels and whose inner
// nodes split their space horizontally ("h", side by side) or vertically
// ("v", stacked) at ratio `r`. Every function here is pure: it returns a new
// tree and leaves its input alone, so the shell can simply reassign.
//
//   Leaf  = { t: "leaf", id, p }
//   Split = { t: "split", id, dir: "h" | "v", r, a, b }

let nextId = 1;
export const leaf = (p) => ({ t: "leaf", id: nextId++, p });
export const split = (dir, r, a, b) => ({ t: "split", id: nextId++, dir, r, a, b });

/** A pane never shrinks below this share of its split. */
export const MIN_RATIO = 0.15;
export const clampRatio = (r) => Math.min(1 - MIN_RATIO, Math.max(MIN_RATIO, r));

export function leaves(n, out = []) {
  if (n.t === "leaf") out.push(n);
  else { leaves(n.a, out); leaves(n.b, out); }
  return out;
}

function map(n, f) {
  const hit = f(n);
  if (hit) return hit;
  if (n.t === "leaf") return n;
  const a = map(n.a, f), b = map(n.b, f);
  return a === n.a && b === n.b ? n : { ...n, a, b };
}

/** Put panel `p` beside (h) or below (v) leaf `id`, sharing its space evenly. */
export const splitLeaf = (root, id, dir, p) =>
  map(root, (n) => (n.t === "leaf" && n.id === id ? split(dir, 0.5, n, leaf(p)) : undefined));

/** Remove leaf `id`; its sibling takes the space. The last tile cannot be closed. */
export function closeLeaf(root, id) {
  if (root.t === "leaf") return root;
  return map(root, (n) => {
    if (n.t !== "split") return undefined;
    if (n.a.t === "leaf" && n.a.id === id) return n.b;
    if (n.b.t === "leaf" && n.b.id === id) return n.a;
    return undefined;
  });
}

/** Show panel `p` in leaf `id`. The leaf gets a new id so the old panel is destroyed. */
export const setPanel = (root, id, p) =>
  map(root, (n) => (n.t === "leaf" && n.id === id ? leaf(p) : undefined));

export const setRatio = (root, id, r) =>
  map(root, (n) => (n.t === "split" && n.id === id ? { ...n, r: clampRatio(r) } : undefined));

/** Match panel occurrences in reading order, retaining each live instance at most once. */
export function retainPanels(next, current) {
  const available = leaves(current);
  return map(next, (n) => {
    if (n.t !== "leaf") return undefined;
    const index = available.findIndex((l) => l.p === n.p);
    return index < 0 ? n : available.splice(index, 1)[0];
  });
}

export const shape = (n) => (n.t === "leaf" ? n.p : [n.dir, shape(n.a), shape(n.b)]);

export const PRESETS = [
  {
    name: "Operations desk",
    hint: "Operations large, dispatch beside",
    build: () => split("h", 0.66, leaf("operations"), leaf("dispatch")),
  },
  {
    name: "Operations + hosts",
    hint: "Operations; dispatch over hosts beside",
    build: () => split("h", 0.62, leaf("operations"), split("v", 0.6, leaf("dispatch"), leaf("hosts"))),
  },
  {
    name: "Dispatch desk",
    hint: "Dispatch large, operations beside",
    build: () => split("h", 0.62, leaf("dispatch"), leaf("operations")),
  },
  {
    name: "Single",
    hint: "One panel, full size",
    build: () => leaf("operations"),
  },
];

/** The preset whose arrangement the tree still has. Resizing keeps it; a split or close doesn't. */
export function currentPreset(root) {
  const s = JSON.stringify(shape(root));
  return PRESETS.find((p) => JSON.stringify(shape(p.build())) === s)?.name ?? null;
}

export const serialize = (n) =>
  n.t === "leaf" ? { t: "leaf", p: n.p } : { t: "split", dir: n.dir, r: n.r, a: serialize(n.a), b: serialize(n.b) };

/**
 * Rebuild a stored layout, or return null if any part of it is malformed or
 * names a panel that no longer exists: a half-restored layout is worse than
 * the default. (A layout saved before Health, Services, Scripts and Configs
 * became tabs of Hosts names panels that no longer exist, so it falls back too.)
 */
export function parseLayout(raw, panels) {
  const build = (v, depth) => {
    if (!v || typeof v !== "object" || depth > 12) return null;
    if (v.t === "leaf") return typeof v.p === "string" && panels.has(v.p) ? leaf(v.p) : null;
    if (v.t !== "split" || (v.dir !== "h" && v.dir !== "v") || typeof v.r !== "number" || !Number.isFinite(v.r)) return null;
    const a = build(v.a, depth + 1), b = build(v.b, depth + 1);
    return a && b ? split(v.dir, clampRatio(v.r), a, b) : null;
  };
  try {
    return raw ? build(JSON.parse(raw), 0) : null;
  } catch {
    return null;
  }
}

// ---- geometry -------------------------------------------------------------
// Tiles are absolutely positioned on one flat surface, never re-parented, so a
// panel keeps its DOM (scroll, inputs, running output) through splits, closes,
// resizes and preset changes. Each 12px divider is accounted for before the
// remaining space is shared, just as a flex splitter would.

const GAP = 12;
const add = (a, b) => ({ percent: a.percent + b.percent, px: a.px + b.px });
const scale = (a, r) => ({ percent: a.percent * r, px: a.px * r });
const cssLength = (a) => `calc(${a.percent}% + ${a.px}px)`;
const cssRect = (r) => `left:${cssLength(r.x)};top:${cssLength(r.y)};width:${cssLength(r.w)};height:${cssLength(r.h)}`;

/** Every leaf and split with the CSS rectangle it occupies on the surface. */
export function layoutFrames(root) {
  const panels = [];
  const splits = [];
  const gap = { percent: 0, px: GAP };
  function visit(n, rect) {
    if (n.t === "leaf") { panels.push({ leaf: n, style: cssRect(rect) }); return; }
    splits.push({ node: n, style: cssRect(rect) });
    const axis = n.dir === "h" ? "w" : "h";
    const origin = n.dir === "h" ? "x" : "y";
    const available = add(rect[axis], scale(gap, -1));
    const first = scale(available, n.r);
    visit(n.a, { ...rect, [axis]: first });
    visit(n.b, { ...rect, [origin]: add(rect[origin], add(first, gap)), [axis]: scale(available, 1 - n.r) });
  }
  const zero = { percent: 0, px: 0 }, full = { percent: 100, px: 0 };
  visit(root, { x: zero, y: zero, w: full, h: full });
  return { panels, splits };
}

/**
 * What a re-render must do with the live panel instances: which leaf ids are
 * new (mount), which survive (keep their DOM), and which are gone (destroy).
 */
export function reconcile(liveIds, root) {
  const next = leaves(root).map((l) => l.id);
  const live = new Set(liveIds);
  const wanted = new Set(next);
  return {
    mount: next.filter((id) => !live.has(id)),
    keep: next.filter((id) => live.has(id)),
    destroy: [...live].filter((id) => !wanted.has(id)),
  };
}
