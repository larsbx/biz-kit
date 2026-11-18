<script lang="ts">
  import PanelBar from "../PanelBar.svelte";
  import { openProcurement, type AppInfo } from "../api";

  let { info }: { info: AppInfo } = $props();
  let opening = $state(false);
  let error = $state<string | null>(null);

  async function open() {
    opening = true;
    error = null;
    try {
      await openProcurement();
    } catch (cause) {
      error = cause instanceof Error ? cause.message : String(cause);
    } finally {
      opening = false;
    }
  }
</script>

<PanelBar title="Procurement" />
<div class="procurement">
  <p>Manage requests, quotes, orders, and evidence in the private coordinator console.</p>
  <button onclick={open} disabled={opening}>{opening ? "Opening…" : "Open procurement console"}</button>
  {#if error}
    <p role="alert">{error}</p>
    <p>Desktop settings file <code>{info.configPath}</code></p>
  {/if}
</div>

<style>
  .procurement { padding: 0.75rem; }
</style>
