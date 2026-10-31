<script lang="ts">
  import type { AppInfo } from "./api";
  import type { Panel } from "./panels";
  import PanelBar from "./PanelBar.svelte";

  let { info, panel }: { info: AppInfo; panel: Panel } = $props();
  const Current = $derived(panel.component);
</script>

{#if panel.requiresHosts && info.hosts.length === 0}
  <!-- The header still renders, so the tile can be changed or closed. -->
  <PanelBar title={panel.label}><div class="spacer"></div></PanelBar>
  <div class="body">
    <div class="empty">
      No hosts configured. Add them to <code class="mono">{info.configPath}</code>
    </div>
  </div>
{:else}
  <Current {info} />
{/if}
