<script lang="ts">
  import { getContext, type Snippet } from "svelte";
  import Icon from "./Icon.svelte";
  import type { TileCtx } from "./tiling.svelte";

  /**
   * A panel's header row. Inside a tile it also carries the tile's controls --
   * the panel picker where the title would be, and split, zoom and close at the
   * end -- so a tile has one header, not two.
   */
  let { title, children }: { title: string; children?: Snippet } = $props();
  const tile = getContext<TileCtx | undefined>("tile");
</script>

<div class="bar">
  {#if tile}
    <select class="picker" aria-label="Panel in this tile" title="Change what this tile shows"
      value={tile.leaf.p} onchange={(e) => tile.choose(e.currentTarget.value)}>
      {#each tile.panels as p (p.id)}<option value={p.id}>{p.label}</option>{/each}
    </select>
  {:else}
    <h1>{title}</h1>
  {/if}
  {@render children?.()}
  {#if tile}
    <span class="tile-tools">
      <button class="icon-btn" title="Split right" aria-label="Split right" onclick={() => tile.split("h")}>
        <Icon name="split-h" />
      </button>
      <button class="icon-btn" title="Split down" aria-label="Split down" onclick={() => tile.split("v")}>
        <Icon name="split-v" />
      </button>
      <button class="icon-btn" title={tile.zoomed ? "Restore (Esc)" : "Zoom to fill"}
        aria-label={tile.zoomed ? "Restore" : "Zoom"} aria-pressed={tile.zoomed} onclick={tile.zoom}>
        <Icon name={tile.zoomed ? "restore" : "zoom"} />
      </button>
      <button class="icon-btn" title={tile.canClose ? "Close tile" : "The last tile can't be closed"}
        aria-label="Close tile" disabled={!tile.canClose} onclick={tile.close}>
        <Icon name="close" />
      </button>
    </span>
  {/if}
</div>
