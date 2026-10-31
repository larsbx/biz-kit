<script lang="ts">
  import type { AppInfo } from "./api";
  import { type Node, setRatio } from "./layout";
  import { layoutFrames } from "./layoutFrames";
  import Divider from "./Divider.svelte";
  import Tile from "./Tile.svelte";

  let { node, info }: { node: Node; info: AppInfo } = $props();
  let drag = $state<{ id: number; ratio: number } | null>(null);
  const frames = $derived(layoutFrames(drag ? setRatio(node, drag.id, drag.ratio) : node));
</script>

<div class="tile-surface">
  <!-- One keyed owner for every panel, independent of its path in the tree. -->
  {#each frames.panels as frame (frame.leaf.id)}
    <Tile leaf={frame.leaf} style={frame.style} {info} />
  {/each}
  {#each frames.splits as frame (frame.node.id)}
    <Divider node={frame.node} style={frame.style}
      preview={(id, ratio) => { drag = ratio === null ? null : { id, ratio }; }} />
  {/each}
</div>
