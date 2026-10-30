<script lang="ts">
  import type { AppInfo } from "./api";
  import type { Panel } from "./panels";

  let { info, panel }: { info: AppInfo; panel: Panel } = $props();
  const Current = $derived(panel.component);
</script>

{#if panel.requiresHosts && info.hosts.length === 0}
  <div class="body">
    <div class="empty">
      No hosts configured. Add them to <code class="mono">{info.configPath}</code>
    </div>
  </div>
{:else}
  <Current {info} />
{/if}
