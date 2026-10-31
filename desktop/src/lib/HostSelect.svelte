<script lang="ts">
  import type { Host } from "./api";

  let { hosts, value = $bindable() }: { hosts: Host[]; value: string } = $props();
</script>

<select class="btn" bind:value>
  {#each hosts as h (h.name)}<option value={h.name}>{h.name}</option>{/each}
</select>
