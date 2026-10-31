<script lang="ts">
  import { setContext } from "svelte";
  import type { AppInfo } from "./api";
  import { type Leaf, closeLeaf, leaves, setPanel, splitLeaf } from "./layout";
  import { PANELS } from "./panels";
  import PanelContent from "./PanelContent.svelte";
  import { type TileCtx, tileEls, tiling } from "./tiling.svelte";

  let { leaf, info }: { leaf: Leaf; info: AppInfo } = $props();

  const panel = $derived(PANELS.find((p) => p.id === leaf.p) ?? PANELS[0]);
  /** A new panel goes where it is least likely to be open already. */
  const nextPanel = () => {
    const open = new Set(leaves(tiling.root).map((l) => l.p));
    return (PANELS.find((p) => !open.has(p.id)) ?? panel).id;
  };

  setContext<TileCtx>("tile", {
    get leaf() { return leaf; },
    panels: PANELS.map(({ id, label }) => ({ id, label })),
    get canClose() { return tiling.root.t === "split"; },
    get zoomed() { return tiling.zoomed === leaf.id; },
    choose: (p) => { tiling.root = setPanel(tiling.root, leaf.id, p); },
    split: (dir) => { tiling.zoomed = null; tiling.root = splitLeaf(tiling.root, leaf.id, dir, nextPanel()); },
    close: () => {
      if (tiling.zoomed === leaf.id) tiling.zoomed = null;
      tiling.root = closeLeaf(tiling.root, leaf.id);
    },
    zoom: () => { tiling.zoomed = tiling.zoomed === leaf.id ? null : leaf.id; },
  });

  function register(el: HTMLElement) {
    tileEls.set(leaf.id, el);
    return () => { tileEls.delete(leaf.id); };
  }
</script>

<section class={"tile" + (tiling.zoomed === leaf.id ? " zoomed" : "")} data-panel={leaf.p}
  aria-label={panel.label} {@attach register}>
  <PanelContent {info} {panel} />
</section>
