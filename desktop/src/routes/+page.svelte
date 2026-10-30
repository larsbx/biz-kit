<script lang="ts">
  import { onMount } from "svelte";
  import { type AppInfo, appInfo } from "#lib/api.js";
  import { PANELS } from "#lib/panels.js";
  import PanelContent from "#lib/PanelContent.svelte";
  import Confirm from "#lib/Confirm.svelte";

  let info = $state<AppInfo | null>(null);
  let err = $state<string | null>(null);
  let active = $state(localStorage.getItem("panel") || "health");

  onMount(() => {
    appInfo().then((i) => (info = i)).catch((e) => (err = String(e)));
  });

  $effect(() => { localStorage.setItem("panel", active); });

  const panel = $derived(PANELS.find((p) => p.id === active) ?? PANELS[0]);
</script>

<div class="app">
  <aside class="side">
    <div class="brand">
      biz-kit
      <small class="trunc">{info?.hosts.map((h) => h.name).join(" · ")}</small>
    </div>
    <nav class="nav">
      {#each PANELS as p (p.id)}
        <button class={active === p.id ? "on" : ""} onclick={() => (active = p.id)}>{p.label}</button>
      {/each}
    </nav>
    <div class="side-foot trunc" title={info?.configPath}>
      {info ? `${info.hosts.length} hosts · ${info.configPath}` : ""}
    </div>
  </aside>
  <main class="main">
    {#if err}
      <div class="body"><p class="err">{err}</p></div>
    {:else if !info}
      <div class="body"><div class="empty">Loading…</div></div>
    {:else}
      {#key active}<PanelContent {info} {panel} />{/key}
    {/if}
  </main>
</div>

<Confirm />
