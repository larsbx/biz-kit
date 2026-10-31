/**
 * The tiling layout: a binary tree whose leaves are panels and whose inner
 * nodes split their space horizontally ("h", side by side) or vertically
 * ("v", stacked) at ratio `r`. Every function here is pure: it returns a new
 * tree and leaves its input alone, so the store can simply reassign.
 */

export type Leaf = { t: "leaf"; id: number; p: string };
export type Split = { t: "split"; id: number; dir: "h" | "v"; r: number; a: Node; b: Node };
export type Node = Leaf | Split;

let nextId = 1;
export const leaf = (p: string): Leaf => ({ t: "leaf", id: nextId++, p });
export const split = (dir: "h" | "v", r: number, a: Node, b: Node): Split =>
  ({ t: "split", id: nextId++, dir, r, a, b });

/** A pane never shrinks below this share of its split. */
export const MIN_RATIO = 0.15;
export const clampRatio = (r: number) => Math.min(1 - MIN_RATIO, Math.max(MIN_RATIO, r));

export function leaves(n: Node, out: Leaf[] = []): Leaf[] {
  if (n.t === "leaf") out.push(n);
  else { leaves(n.a, out); leaves(n.b, out); }
  return out;
}

function map(n: Node, f: (n: Node) => Node | undefined): Node {
  const hit = f(n);
  if (hit) return hit;
  if (n.t === "leaf") return n;
  const a = map(n.a, f), b = map(n.b, f);
  return a === n.a && b === n.b ? n : { ...n, a, b };
}

/** Put panel `p` beside (h) or below (v) leaf `id`, sharing its space evenly. */
export const splitLeaf = (root: Node, id: number, dir: "h" | "v", p: string): Node =>
  map(root, (n) => (n.t === "leaf" && n.id === id ? split(dir, 0.5, n, leaf(p)) : undefined));

/** Remove leaf `id`; its sibling takes the space. The last tile cannot be closed. */
export function closeLeaf(root: Node, id: number): Node {
  if (root.t === "leaf") return root;
  return map(root, (n) => {
    if (n.t !== "split") return undefined;
    if (n.a.t === "leaf" && n.a.id === id) return n.b;
    if (n.b.t === "leaf" && n.b.id === id) return n.a;
    return undefined;
  });
}

/** Show panel `p` in leaf `id`. The leaf gets a new id so the old panel unmounts. */
export const setPanel = (root: Node, id: number, p: string): Node =>
  map(root, (n) => (n.t === "leaf" && n.id === id ? leaf(p) : undefined));

export const setRatio = (root: Node, id: number, r: number): Node =>
  map(root, (n) => (n.t === "split" && n.id === id ? { ...n, r: clampRatio(r) } : undefined));

type Shape = string | ["h" | "v", Shape, Shape];
export const shape = (n: Node): Shape => (n.t === "leaf" ? n.p : [n.dir, shape(n.a), shape(n.b)]);

export type Preset = { name: string; hint: string; build: () => Node };

export const PRESETS: Preset[] = [
  {
    name: "Overview",
    hint: "Health beside services",
    build: () => split("h", 0.36, leaf("health"), leaf("services")),
  },
  {
    name: "Operate",
    hint: "Services over configs, scripts beside",
    build: () => split("h", 0.62, split("v", 0.55, leaf("services"), leaf("configs")), leaf("scripts")),
  },
  {
    name: "Everything",
    hint: "Every host panel in a grid",
    build: () => split("v", 0.5,
      split("h", 0.5, leaf("health"), leaf("services")),
      split("h", 0.5, leaf("scripts"), leaf("configs"))),
  },
  {
    name: "Dispatch desk",
    hint: "Dispatch large, health beside",
    build: () => split("h", 0.7, leaf("dispatch"), leaf("health")),
  },
  {
    name: "Single",
    hint: "One panel, full size",
    build: () => leaf("health"),
  },
];

/** The preset whose arrangement the tree still has. Resizing keeps it; a split or close doesn't. */
export function currentPreset(root: Node): string | null {
  const s = JSON.stringify(shape(root));
  return PRESETS.find((p) => JSON.stringify(shape(p.build())) === s)?.name ?? null;
}

type Stored = { t: "leaf"; p: string } | { t: "split"; dir: "h" | "v"; r: number; a: Stored; b: Stored };

export const serialize = (n: Node): Stored =>
  n.t === "leaf" ? { t: "leaf", p: n.p } : { t: "split", dir: n.dir, r: n.r, a: serialize(n.a), b: serialize(n.b) };

/**
 * Rebuild a stored layout, or return null if any part of it is malformed or
 * names a panel that no longer exists: a half-restored layout is worse than
 * the default.
 */
export function parseLayout(raw: string | null, panels: ReadonlySet<string>): Node | null {
  const build = (v: unknown, depth: number): Node | null => {
    if (!v || typeof v !== "object" || depth > 12) return null;
    const o = v as Record<string, unknown>;
    if (o.t === "leaf") return typeof o.p === "string" && panels.has(o.p) ? leaf(o.p) : null;
    if (o.t !== "split" || (o.dir !== "h" && o.dir !== "v") || typeof o.r !== "number" || !Number.isFinite(o.r)) return null;
    const a = build(o.a, depth + 1), b = build(o.b, depth + 1);
    return a && b ? split(o.dir, clampRatio(o.r), a, b) : null;
  };
  try {
    return raw ? build(JSON.parse(raw), 0) : null;
  } catch {
    return null;
  }
}
