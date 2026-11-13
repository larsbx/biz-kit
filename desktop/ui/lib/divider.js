// Shared by the desktop and TaskHost. The caller owns the tree and its tiles.
import { clampRatio, setRatio } from "./layout.js";

export function divider(node, { getRoot, commit, preview, focus }) {
  const el = document.createElement("div");
  el.className = `split ${node.dir}`;
  const a = document.createElement("div"), b = document.createElement("div");
  a.className = b.className = "pane";
  const d = document.createElement("div");
  d.className = "divider";
  for (const [key, value] of Object.entries({
    role: "separator", tabindex: "0", "aria-label": "Resize tiles",
    "aria-orientation": node.dir === "h" ? "vertical" : "horizontal",
    "aria-valuemin": "15", "aria-valuemax": "85",
    title: "Drag to resize · arrow keys when focused · double-click or Enter to even out",
  })) d.setAttribute(key, value);
  const show = (r) => {
    a.style.flex = `${r} 1 0`; b.style.flex = `${1 - r} 1 0`;
    d.setAttribute("aria-valuenow", String(Math.round(r * 100)));
  };
  show(node.r);
  el.append(a, d, b);
  d.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    e.preventDefault();
    d.setPointerCapture(e.pointerId);
    d.classList.add("drag");
    const box = el.getBoundingClientRect();
    let ratio = node.r;
    const move = (event) => {
      const size = (node.dir === "h" ? box.width : box.height) - 12;
      if (size <= 0) return;
      ratio = clampRatio(((node.dir === "h" ? event.clientX - box.left : event.clientY - box.top) - 6) / size);
      show(ratio);
      preview(setRatio(getRoot(), node.id, ratio));
    };
    const end = (event) => {
      d.removeEventListener("pointermove", move);
      d.removeEventListener("pointerup", end);
      d.removeEventListener("pointercancel", end);
      d.removeEventListener("lostpointercapture", end);
      d.classList.remove("drag");
      commit(setRatio(getRoot(), node.id, event.type === "pointercancel" ? node.r : ratio));
      focus?.(node.id);
    };
    d.addEventListener("pointermove", move);
    d.addEventListener("pointerup", end);
    d.addEventListener("pointercancel", end);
    d.addEventListener("lostpointercapture", end);
  });
  d.addEventListener("keydown", (e) => {
    const back = node.dir === "h" ? "ArrowLeft" : "ArrowUp";
    const forward = node.dir === "h" ? "ArrowRight" : "ArrowDown";
    const ratio = { [back]: node.r - 0.05, [forward]: node.r + 0.05, Home: 0, End: 1, Enter: 0.5 }[e.key];
    if (ratio === undefined) return;
    e.preventDefault();
    commit(setRatio(getRoot(), node.id, ratio));
    focus?.(node.id);
  });
  d.addEventListener("dblclick", () => { commit(setRatio(getRoot(), node.id, 0.5)); focus?.(node.id); });
  return el;
}
