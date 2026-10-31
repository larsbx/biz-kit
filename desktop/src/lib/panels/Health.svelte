<script lang="ts">
  import { onMount } from "svelte";
  import { type AppInfo, type Health, hostHealth } from "../api";

  let { info }: { info: AppInfo } = $props();
  const hosts = $derived(info.hosts);

  let data = $state<Record<string, Health | null>>({});
  let loading = $state(false);

  async function load() {
    loading = true;
    // Hosts are probed in parallel: one unreachable box must not stall the rest.
    await Promise.all(
      hosts.map(async (h) => {
        try {
          data[h.name] = await hostHealth(h.name);
        } catch {
          data[h.name] = null;
        }
      }),
    );
    loading = false;
  }

  onMount(() => { if (hosts.length) load(); });

  const meterClass = (pct: number) => (pct >= 90 ? "bad" : pct >= 80 ? "warn" : "");
  const gb = (mb: number) => (mb / 1024).toFixed(1);
</script>

{#snippet meter(pct: number)}
  <div class="meter"><i class={meterClass(pct)} style:width="{Math.min(pct, 100)}%"></i></div>
{/snippet}

<div class="bar">
  <h1>Health</h1>
  <div class="spacer"></div>
  <button class="btn" onclick={load} disabled={loading}>{loading ? "Refreshing…" : "Refresh"}</button>
</div>
<div class="body">
  <div class="cards">
    {#each hosts as h (h.name)}
      {@const d = data[h.name]}
      {@const memPct = d && d.memTotalMb ? Math.round((d.memUsedMb / d.memTotalMb) * 100) : 0}
      <div class="card">
        <h3>
          {h.name}
          {#if d && !d.reachable}<span class="pill bad">unreachable</span>{/if}
        </h3>
        <div class="sub">{h.label}</div>
        {#if !d}<div class="empty">probing…</div>{/if}
        {#if d?.error}<div class="err">{d.error}</div>{/if}
        {#if d?.reachable && !d.error}
          <div class="kv"><span>uptime</span><span>{d.uptime || "—"}</span></div>
          <div class="kv"><span>load</span><span class="mono">{d.load}</span></div>

          <div class="kv" style="margin-top: 6px">
            <span>disk /</span><span>{d.diskPct}% · {d.diskUsed}/{d.diskTotal}</span>
          </div>
          {@render meter(d.diskPct)}

          <div class="kv" style="margin-top: 6px">
            <span>memory</span><span>{gb(d.memUsedMb)}/{gb(d.memTotalMb)} GB</span>
          </div>
          {@render meter(memPct)}

          {#if d.swapTotalMb > 0}
            <div class="kv" style="margin-top: 6px">
              <span>swap</span><span>{gb(d.swapUsedMb)}/{gb(d.swapTotalMb)} GB</span>
            </div>
            {@render meter(Math.round((d.swapUsedMb / d.swapTotalMb) * 100))}
          {/if}

          <div class="kv">
            <span>failed units</span>
            <span class={d.failedUnits.length ? "pill warn" : "pill ok"}>{d.failedUnits.length}</span>
          </div>
          {#if d.failedUnits.length > 0}
            <div class="mono" style="font-size: .85rem; color: var(--dim); margin-top: 4px">
              {#each d.failedUnits.slice(0, 6) as u (u)}<div class="trunc">{u}</div>{/each}
              {#if d.failedUnits.length > 6}<div>+{d.failedUnits.length - 6} more</div>{/if}
            </div>
          {/if}

          {#each d.checks as c, i (c.label + i)}
            <div class="kv" style:margin-top={i === 0 ? "8px" : undefined}>
              <span>{c.label}</span>
              <span
                class={"trunc pill " + (c.ok ? "ok" : "bad")}
                title={c.detail}
                style="max-width: 14rem; display: inline-block"
              >{c.detail.split("\n")[0] || (c.ok ? "ok" : "failed")}</span>
            </div>
          {/each}
        {/if}
      </div>
    {/each}
  </div>
</div>
