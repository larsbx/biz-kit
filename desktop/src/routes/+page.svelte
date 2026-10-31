<script lang="ts">
  import { onMount } from "svelte";
  import { type AppInfo, appInfo } from "#lib/api.js";
  import { GROUPS, PANELS, type Panel } from "#lib/panels.js";
  import PanelContent from "#lib/PanelContent.svelte";
  import Confirm from "#lib/Confirm.svelte";
  import Icon from "#lib/Icon.svelte";
  import { DEFAULTS, FONT, prefs, setFontSize } from "#lib/prefs.svelte.js";

  let info = $state<AppInfo | null>(null);
  let err = $state<string | null>(null);
  let active = $state(localStorage.getItem("panel") || "health");

  onMount(() => {
    appInfo().then((i) => (info = i)).catch((e) => (err = String(e)));
  });

  $effect(() => { localStorage.setItem("panel", active); });

  const panel = $derived(PANELS.find((p) => p.id === active) ?? PANELS[0]);
  const settings = PANELS.find((p) => p.id === "settings")!;
  /** Sidebar order, which is also the Ctrl+number order. */
  const ordered = [...GROUPS.flatMap((g) => PANELS.filter((p) => p.group === g)), settings];
  const shortcut = (p: Panel) =>
    p.id === "settings" ? "Ctrl+," : `Ctrl+${ordered.indexOf(p) + 1}`;
  const unavailable = (p: Panel) => p.requiresHosts && info !== null && info.hosts.length === 0;

  let navEl: HTMLElement;

  function go(id: string, focus = false) {
    active = id;
    if (focus) navEl?.querySelector<HTMLButtonElement>(`[data-panel="${id}"]`)?.focus();
  }

  function onKey(e: KeyboardEvent) {
    if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
    if (e.key === ",") {
      go("settings");
    } else if (/^[1-9]$/.test(e.key) && ordered[Number(e.key) - 1]) {
      go(ordered[Number(e.key) - 1].id);
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

  /** Up/Down/Home/End move between sidebar entries, as in a native list. */
  function onNavKey(e: KeyboardEvent) {
    const i = ordered.findIndex((p) => p.id === active);
    const to = { ArrowDown: i + 1, ArrowUp: i - 1, Home: 0, End: ordered.length - 1 }[e.key];
    if (to === undefined) return;
    e.preventDefault();
    go(ordered[(to + ordered.length) % ordered.length].id, true);
  }
</script>

<svelte:window onkeydown={onKey} />

{#snippet entry(p: Panel)}
  <button
    data-panel={p.id}
    class={"entry" + (active === p.id ? " on" : "") + (unavailable(p) ? " off" : "")}
    aria-current={active === p.id ? "page" : undefined}
    tabindex={active === p.id ? 0 : -1}
    title={`${p.label} (${shortcut(p)})${unavailable(p) ? " — needs a host in the config file" : ""}`}
    onclick={() => go(p.id)}
  >
    <Icon name={p.icon} />
    <span class="text">
      <span class="label">{p.label}</span>
      <span class="hint">{unavailable(p) ? "No hosts configured" : p.hint}</span>
    </span>
    <kbd>{shortcut(p).replace("Ctrl+", "")}</kbd>
  </button>
{/snippet}

<div class="app">
  <aside class="side">
    <div class="brand">
      biz-kit
      <small class="trunc">{info?.hosts.map((h) => h.name).join(" · ")}</small>
    </div>
    <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
    <nav class="nav" aria-label="Panels" bind:this={navEl} onkeydown={onNavKey}>
      {#each GROUPS as g (g)}
        <div class="group">{g}</div>
        {#each PANELS.filter((p) => p.group === g) as p (p.id)}{@render entry(p)}{/each}
      {/each}
      <div class="nav-foot">{@render entry(settings)}</div>
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
