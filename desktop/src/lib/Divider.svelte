<script lang="ts">
  import { type Split, clampRatio, setRatio } from "./layout";
  import { tiling } from "./tiling.svelte";

  let { node, style, preview }: { node: Split; style: string; preview: (id: number, ratio: number | null) => void } = $props();

  let box = $state<HTMLElement>();
  /** The ratio while a divider is being dragged; committed to the tree on release. */
  let dragging = $state<number | null>(null);
  const r = $derived(dragging ?? node.r);

  function commit(v: number) {
    tiling.root = setRatio(tiling.root, node.id, v);
  }

  function down(e: PointerEvent) {
    if (!box) return;
    e.preventDefault();
    const d = e.currentTarget as HTMLElement;
    d.setPointerCapture(e.pointerId);
    const rect = box.getBoundingClientRect();
    const dir = node.dir;
    const move = (ev: PointerEvent) => {
      const size = (dir === "h" ? rect.width : rect.height) - 12;
      if (size <= 0) return;
      dragging = clampRatio(((dir === "h" ? ev.clientX - rect.left : ev.clientY - rect.top) - 6) / size);
      preview(node.id, dragging);
    };
    const up = () => {
      d.removeEventListener("pointermove", move);
      d.removeEventListener("pointerup", up);
      d.removeEventListener("pointercancel", cancel);
      d.removeEventListener("lostpointercapture", cancel);
      if (dragging !== null) commit(dragging);
      dragging = null;
      preview(node.id, null);
    };
    const cancel = () => { dragging = null; up(); };
    d.addEventListener("pointermove", move);
    d.addEventListener("pointerup", up);
    d.addEventListener("pointercancel", cancel);
    d.addEventListener("lostpointercapture", cancel);
  }

  /** Arrow keys move a focused divider, Home/End/Enter jump, as for any separator. */
  function key(e: KeyboardEvent) {
    const back = node.dir === "h" ? "ArrowLeft" : "ArrowUp";
    const fwd = node.dir === "h" ? "ArrowRight" : "ArrowDown";
    const to = { [back]: node.r - 0.05, [fwd]: node.r + 0.05, Home: 0, End: 1, Enter: 0.5 }[e.key];
    if (to === undefined) return;
    e.preventDefault();
    commit(to);
  }
</script>

  <div class={"split " + node.dir} {style} bind:this={box}>
    <div class="pane" style:flex="{r} 1 0"></div>
    <!-- A focusable separator with a value is an ARIA widget (a window splitter); the linter treats every separator as static. -->
    <!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
    <div
      class={"divider" + (dragging !== null ? " drag" : "")}
      role="separator"
      tabindex="0"
      aria-label="Resize tiles"
      aria-orientation={node.dir === "h" ? "vertical" : "horizontal"}
      aria-valuemin={15}
      aria-valuemax={85}
      aria-valuenow={Math.round(r * 100)}
      title="Drag to resize · arrow keys when focused · Enter to even out"
      onpointerdown={down}
      onkeydown={key}
      ondblclick={() => commit(0.5)}
    ></div>
    <div class="pane" style:flex="{1 - r} 1 0"></div>
  </div>
