<script lang="ts">
  import { onMount, tick } from "svelte";
  import PanelBar from "../PanelBar.svelte";
  import { type AppInfo, type Script, type Line, listScripts, runScript } from "../api";
  import { confirm } from "../confirmation.svelte";

  let { info }: { info: AppInfo } = $props();
  const scriptsDir = $derived(info.scriptsDir);

  let scripts = $state<Script[]>([]);
  let sel = $state<Script | null>(null);
  let lines = $state<Line[]>([]);
  let running = $state(false);
  let err = $state<string | null>(null);
  let outEl = $state<HTMLPreElement>();

  async function load() {
    try { scripts = await listScripts(); }
    catch (e) { err = String(e); }
  }
  onMount(load);

  // Follow the tail while a long run streams in.
  $effect(() => {
    lines.length;
    tick().then(() => { if (outEl) outEl.scrollTop = outEl.scrollHeight; });
  });

  function start(s: Script, apply: boolean) {
    sel = s;
    lines = [];
    running = true;
    err = null;
    runScript(s.path, apply ? ["--apply"] : [], (l) => {
      lines.push(l);
      if (l.kind === "done") running = false;
    }).catch((e) => { err = String(e); running = false; });
  }

  function onApply(s: Script) {
    confirm({
      title: `Run ${s.name} with --apply?`,
      why: "This makes real changes. The dry run shows exactly what it would do.",
      command: `${s.interpreter} ${s.path} --apply`,
      danger: true,
      run: async () => start(s, true),
    });
  }

  const done = $derived(lines.find((l) => l.kind === "done") as { kind: "done"; code: number } | undefined);
</script>

<PanelBar title="Scripts">
  <span class="mono trunc" style="color: var(--dim); font-size: .92rem">{scriptsDir}</span>
  <div class="spacer"></div>
  <button class="btn" onclick={load} disabled={running}>Rescan</button>
</PanelBar>
<div class="body">
  {#if err}<p class="err">{err}</p>{/if}
  {#if scripts.length === 0}<div class="empty">No .sh or .py scripts in {scriptsDir}</div>{/if}

  <div class="cards" style="margin-bottom: 16px">
    {#each scripts as s (s.path)}
      <div class="card">
        <h3 class="mono" style="font-size: .92rem">{s.name}</h3>
        <div class="sub">{s.summary || "—"}</div>
        <div class="row">
          <button class="btn" disabled={running} onclick={() => start(s, false)}>{s.hasApply ? "Dry run" : "Run"}</button>
          {#if s.hasApply}
            <button class="btn danger" disabled={running} onclick={() => onApply(s)}>Apply</button>
          {/if}
        </div>
      </div>
    {/each}
  </div>

  {#if lines.length > 0 || running}
    <div class="row" style="margin-bottom: 6px">
      <strong class="mono" style="font-size: .92rem">{sel?.name}</strong>
      {#if running}<span class="pill warn">running…</span>{/if}
      {#if done}<span class={"pill " + (done.code === 0 ? "ok" : "bad")}>exit {done.code}</span>{/if}
      <div class="spacer"></div>
      <button class="btn" onclick={() => (lines = [])} disabled={running}>Clear</button>
    </div>
    <pre class="out" bind:this={outEl}>{#each lines as l, i (i)}{#if l.kind !== "done"}<div class={l.kind === "stderr" ? "e" : undefined}>{l.text}</div>{/if}{/each}</pre>
  {/if}
</div>
