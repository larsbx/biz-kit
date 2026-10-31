<script lang="ts">
  import { onMount } from "svelte";
  import { type AppInfo, appInfo } from "#lib/api.js";
  import { GROUPS, PANELS, type Panel } from "#lib/panels.js";
  import Confirm from "#lib/Confirm.svelte";
  import Icon from "#lib/Icon.svelte";
  import Tiles from "#lib/Tiles.svelte";
  import { PRESETS, currentPreset, leaves, retainPanels } from "#lib/layout.js";
  import { addPanel, restoreLayout, saveLayout, sidebar, tiling, toggleSidebar } from "#lib/tiling.svelte.js";
  import { DEFAULTS, FONT, prefs, setFontSize } from "#lib/prefs.svelte.js";
  import { pending } from "#lib/confirmation.svelte.js";

  let info = $state<AppInfo | null>(null);
  let err = $state<string | null>(null);

  restoreLayout(PANELS.map((p) => p.id));

  onMount(() => {
    appInfo().then((i) => (info = i)).catch((e) => (err = String(e)));
  });

  $effect(() => saveLayout(tiling.root));

  const settings = PANELS.find((p) => p.id === "settings")!;
  /** Sidebar order, which is also the Ctrl+number order. */
  const ordered = [...GROUPS.flatMap((g) => PANELS.filter((p) => p.group === g)), settings];
  const shortcut = (p: Panel) =>
    p.id === "settings" ? "Ctrl+," : `Ctrl+${ordered.indexOf(p) + 1}`;
  const unavailable = (p: Panel) => p.requiresHosts && info !== null && info.hosts.length === 0;
  const open = $derived(new Set(leaves(tiling.root).map((l) => l.p)));
  const preset = $derived(currentPreset(tiling.root));

  function usePreset(name: string) {
    tiling.zoomed = null;
    tiling.root = retainPanels(PRESETS.find((p) => p.name === name)!.build(), tiling.root);
  }

  function onKey(e: KeyboardEvent) {
    if (e.key === "Escape" && tiling.zoomed !== null && !pending.ask) {
      tiling.zoomed = null;
      return;
    }
    if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
    if (e.key === "b" || e.key === "B") {
      toggleSidebar();
    } else if (e.key === ",") {
      addPanel("settings");
    } else if (/^[1-9]$/.test(e.key) && ordered[Number(e.key) - 1]) {
      addPanel(ordered[Number(e.key) - 1].id);
    } else if (e.key === "+" || e.key === "=") {
      setFontSize(prefs.fontSize + FONT.step);
    } else if (e.key === "-") {
      setFontSize(prefs.fontSize - FONT.step);
    } else if (e.key === "0") {
      setFontSize(DEFAULTS.fontSize);
    } else {
      return;
    }
    e.preventDefault();
  }
</script>

<svelte:window onkeydown={onKey} />

{#snippet entry(p: Panel)}
  {@const on = open.has(p.id)}
  <button
    data-panel={p.id}
    class={"entry" + (on ? " on" : "") + (unavailable(p) ? " off" : "")}
    aria-pressed={on}
    title={`${p.label} (${shortcut(p)}): ${on ? "open, click to highlight it" : "click to add it as a tile"}${unavailable(p) ? " — needs a host in the config file" : ""}`}
    onclick={() => addPanel(p.id)}
  >
    <Icon name={p.icon} />
    <span class="text">
      <span class="label">{p.label}</span>
      <span class="hint">{unavailable(p) ? "No hosts configured" : p.hint}</span>
    </span>
    <span class="state" aria-hidden="true">{on ? "●" : "+"}</span>
    <kbd>{shortcut(p).replace("Ctrl+", "")}</kbd>
  </button>
{/snippet}

<div class="app">
  <aside class={"side" + (sidebar.hidden ? " rail" : "")}>
    <div class="brand">
      <button class="icon-btn side-toggle" onclick={toggleSidebar} aria-expanded={!sidebar.hidden}
        title={sidebar.hidden ? "Show sidebar (Ctrl+B)" : "Hide sidebar (Ctrl+B)"}
        aria-label={sidebar.hidden ? "Show sidebar" : "Hide sidebar"}>
        <Icon name="sidebar" />
      </button>
      {#if !sidebar.hidden}
        <span class="brand-text">
          biz-kit
          <small class="trunc">{info?.hosts.map((h) => h.name).join(" · ")}</small>
        </span>
      {/if}
    </div>
    <nav class="nav" aria-label="Panels">
      {#each GROUPS as g (g)}
        <div class="group">{g}</div>
        {#each PANELS.filter((p) => p.group === g) as p (p.id)}{@render entry(p)}{/each}
      {/each}
      <div class="group">Layouts</div>
      {#each PRESETS as l (l.name)}
        <button class={"entry layout" + (preset === l.name ? " on" : "")} aria-pressed={preset === l.name}
          title={`${l.name}: ${l.hint}`} onclick={() => usePreset(l.name)}>
          <Icon name="layout" />
          <span class="text"><span class="label">{l.name}</span><span class="hint">{l.hint}</span></span>
        </button>
      {/each}
      <div class="nav-foot">{@render entry(settings)}</div>
    </nav>
    {#if !sidebar.hidden}
      <div class="side-foot trunc" title={info?.configPath}>
        {info ? `${info.hosts.length} hosts · ${info.configPath}` : ""}
      </div>
    {/if}
  </aside>
  <main class="main tiles">
    {#if err}
      <div class="body"><p class="err">{err}</p></div>
    {:else if !info}
      <div class="body"><div class="empty">Loading…</div></div>
    {:else}
      <Tiles node={tiling.root} {info} />
    {/if}
  </main>
</div>

<Confirm />
