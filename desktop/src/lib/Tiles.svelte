<script lang="ts">
  import type { AppInfo } from "./api";
  import { type Node, clampRatio, setRatio } from "./layout";
  import Tile from "./Tile.svelte";
  import Tiles from "./Tiles.svelte";
  import { tiling } from "./tiles.svelte";

  let { node, info }: { node: Node; info: AppInfo } = $props();

  let box = $state<HTMLElement>();
  /** The ratio while a divider is being dragged; committed to the tree on release. */
  let dragging = $state<number | null>(null);
  const r = $derived(dragging ?? (node.t === "split" ? node.r : 1));

  function commit(v: number) {
    tiling.root = setRatio(tiling.root, node.id, v);
  }

  function down(e: PointerEvent) {
    if (node.t !== "split" || !box) return;
    e.preventDefault();
    const d = e.currentTarget as HTMLElement;
    d.setPointerCapture(e.pointerId);
    const rect = box.getBoundingClientRect();
    const dir = node.dir;
    const move = (ev: PointerEvent) => {
      dragging = clampRatio(dir === "h" ? (ev.clientX - rect.left) / rect.width : (ev.clientY - rect.top) / rect.height);
    };
    const up = () => {
      d.removeEventListener("pointermove", move);
      d.removeEventListener("pointerup", up);
      if (dragging !== null) commit(dragging);
      dragging = null;
    };
    d.addEventListener("pointermove", move);
    d.addEventListener("pointerup", up);
  }

  /** Arrow keys move a focused divider, Home/End/Enter jump, as for any separator. */
  function key(e: KeyboardEvent) {
    if (node.t !== "split") return;
    const back = node.dir === "h" ? "ArrowLeft" : "ArrowUp";
    const fwd = node.dir === "h" ? "ArrowRight" : "ArrowDown";
    const to = { [back]: node.r - 0.05, [fwd]: node.r + 0.05, Home: 0, End: 1, Enter: 0.5 }[e.key];
    if (to === undefined) return;
    e.preventDefault();
    commit(to);
  }
</script>

{#if node.t === "leaf"}
  <Tile leaf={node} {info} />
{:else}
  <div class={"split " + node.dir} bind:this={box}>
    <div class="pane" style:flex="{r} 1 0"><Tiles node={node.a} {info} /></div>
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
    <div class="pane" style:flex="{1 - r} 1 0"><Tiles node={node.b} {info} /></div>
  </div>
{/if}
