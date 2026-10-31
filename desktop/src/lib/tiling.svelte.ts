import { PRESETS, type Leaf, type Node, leaves, parseLayout, retainPanels, serialize, splitLeaf } from "./layout";

const KEY = "layout";

/** The live layout. `zoomed` is a leaf shown over the whole tiling area, others stay mounted. */
export const tiling = $state<{ root: Node; zoomed: number | null }>({
  root: PRESETS[0].build(),
  zoomed: null,
});

/** Restore the saved layout, keeping only panels that still exist. */
export function restoreLayout(panelIds: Iterable<string>) {
  tiling.root = retainPanels(parseLayout(localStorage.getItem(KEY), new Set(panelIds)) ?? PRESETS[0].build(), tiling.root);
  tiling.zoomed = null;
}

export function saveLayout(root: Node) {
  try { localStorage.setItem(KEY, JSON.stringify(serialize(root))); } catch { /* storage full: layout is a nicety */ }
}

/** What a tile tells the panel header inside it. Getters keep it reactive. */
export type TileCtx = {
  readonly leaf: Leaf;
  readonly panels: { id: string; label: string }[];
  readonly canClose: boolean;
  readonly zoomed: boolean;
  choose: (p: string) => void;
  split: (dir: "h" | "v") => void;
  close: () => void;
  zoom: () => void;
};

/** Tile elements by leaf id, to measure them and flash them. Not reactive state. */
export const tileEls = new Map<number, HTMLElement>();

function flash(el: HTMLElement) {
  el.animate?.(
    [{ outlineColor: "var(--accent)" }, { outlineColor: "transparent" }],
    { duration: 800, easing: "ease-out" },
  );
  el.querySelector<HTMLElement>("select, button")?.focus();
}

/**
 * Show panel `p`: highlight it if it is already in a tile, otherwise split the
 * largest tile along its longer side and put it there.
 */
export function addPanel(p: string) {
  const all = leaves(tiling.root);
  const existing = all.find((l) => l.p === p);
  if (existing) {
    if (tiling.zoomed !== null) tiling.zoomed = existing.id;
    const el = tileEls.get(existing.id);
    if (el) flash(el);
    return;
  }
  let best: { l: Leaf; w: number; h: number } | null = null;
  for (const l of all) {
    const r = tileEls.get(l.id)?.getBoundingClientRect();
    const w = r?.width ?? 0, h = r?.height ?? 0;
    if (!best || w * h > best.w * best.h) best = { l, w, h };
  }
  if (!best) return;
  tiling.zoomed = null;
  tiling.root = splitLeaf(tiling.root, best.l.id, best.w >= best.h ? "h" : "v", p);
}
