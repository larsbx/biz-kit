import type { Leaf, Node, Split } from "./layout";

/** A CSS length relative to the tiling surface, plus a fixed pixel offset. */
type Length = { percent: number; px: number };
type Rect = { x: Length; y: Length; w: Length; h: Length };
const add = (a: Length, b: Length): Length => ({ percent: a.percent + b.percent, px: a.px + b.px });
const scale = (a: Length, r: number): Length => ({ percent: a.percent * r, px: a.px * r });
const length = (a: Length) => `calc(${a.percent}% + ${a.px}px)`;
const style = (r: Rect) => `left:${length(r.x)};top:${length(r.y)};width:${length(r.w)};height:${length(r.h)}`;
const gap: Length = { percent: 0, px: 12 };

/**
 * Flatten geometry, never component ownership. Account for each 12px divider
 * before sharing the remaining space, just as the flex splitter does.
 */
export function layoutFrames(root: Node) {
  const panels: { leaf: Leaf; style: string }[] = [];
  const splits: { node: Split; style: string }[] = [];
  function visit(n: Node, rect: Rect) {
    if (n.t === "leaf") { panels.push({ leaf: n, style: style(rect) }); return; }
    splits.push({ node: n, style: style(rect) });
    const axis = n.dir === "h" ? "w" : "h";
    const origin = n.dir === "h" ? "x" : "y";
    const available = add(rect[axis], scale(gap, -1));
    const first = scale(available, n.r);
    visit(n.a, { ...rect, [axis]: first });
    visit(n.b, { ...rect, [origin]: add(rect[origin], add(first, gap)), [axis]: scale(available, 1 - n.r) });
  }
  visit(root, { x: { percent: 0, px: 0 }, y: { percent: 0, px: 0 }, w: { percent: 100, px: 0 }, h: { percent: 100, px: 0 } });
  return { panels, splits };
}
