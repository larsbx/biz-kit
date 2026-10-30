<script lang="ts">
  import { untrack } from "svelte";
  import { type AppInfo, type Unit, listUnits, unitActionScript, runOn, previewCommand } from "../api";
  import { confirm } from "../confirmation.svelte";
  import HostSelect from "../HostSelect.svelte";

  const ACTIONS = ["start", "stop", "restart", "enable", "disable"] as const;
  const DESTRUCTIVE = new Set(["stop", "disable", "restart"]);

  let { info }: { info: AppInfo } = $props();
  const hosts = $derived(info.hosts);

  // The first host is only the starting choice; the picker owns it after.
  let host = $state(untrack(() => info.hosts[0]?.name ?? ""));
  let units = $state<Unit[]>([]);
  let q = $state("");
  let only = $state<"all" | "active" | "limit">("all");
  let loading = $state(false);
  let err = $state<string | null>(null);

  function fmt(s: number) {
    if (!isFinite(s)) return "∞";
    return s >= 60 ? `${Math.round(s / 60)}min` : `${+s.toFixed(s < 1 ? 3 : 0)}s`;
  }

  async function load(h = host) {
    if (!h) return;
    loading = true; err = null;
    try { units = await listUnits(h); }
    catch (e) { err = String(e); units = []; }
    finally { loading = false; }
  }
  $effect(() => { load(host); });

  const shown = $derived.by(() => {
    const needle = q.toLowerCase();
    return units
      .filter((u) => (only === "active" ? u.active === "active" : only === "limit" ? u.limitUnreachable : true))
      .filter((u) => !needle || u.id.toLowerCase().includes(needle))
      .sort((a, b) => Number(b.limitUnreachable) - Number(a.limitUnreachable) || a.id.localeCompare(b.id));
  });

  const badCount = $derived(units.filter((u) => u.limitUnreachable).length);

  async function act(u: Unit, action: string) {
    const script = await unitActionScript(u.scope, u.id, action);
    const command = await previewCommand(u.host, script);
    confirm({
      title: `${action} ${u.id} on ${u.host}?`,
      why:
        u.scope === "system"
          ? "System scope runs through sudo -n: it fails instead of prompting unless the user has passwordless sudo for this command."
          : undefined,
      command,
      host: u.host,
      danger: DESTRUCTIVE.has(action),
      run: async () => {
        const out = await runOn(u.host, script);
        if (out.code !== 0) throw new Error(out.stderr.trim() || `exit ${out.code}`);
        await load();
      },
    });
  }
</script>

<div class="bar">
  <h1>Services</h1>
  <HostSelect {hosts} bind:value={host} />
  <div class="chips">
    {#each ["all", "active", "limit"] as const as k (k)}
      <button class={"chip" + (only === k ? " on" : "")} onclick={() => (only = k)}>
        {k === "limit" ? `restart loop risk (${badCount})` : k}
      </button>
    {/each}
  </div>
  <input type="text" placeholder="Filter…" bind:value={q} style="width: 160px" />
  <div class="spacer"></div>
  <button class="btn" onclick={() => load()} disabled={loading}>{loading ? "Loading…" : "Refresh"}</button>
</div>
<div class="body">
  {#if err}<p class="err">{err}</p>{/if}
  {#if !err && !loading && shown.length === 0}<div class="empty">no units match</div>{/if}
  {#if shown.length > 0}
    <table>
      <thead>
        <tr>
          <th>unit</th><th>scope</th><th>active</th><th>enabled</th>
          <th>restart</th><th>limit</th><th style="width: 250px"></th>
        </tr>
      </thead>
      <tbody>
        {#each shown as u (u.scope + u.id)}
          <tr>
            <td class="mono">{u.id}</td>
            <td><span class="pill">{u.scope}</span></td>
            <td>
              <span class={"pill " + (u.active === "active" ? "ok" : u.active === "failed" ? "bad" : "")}>{u.active}</span>
            </td>
            <td><span class="pill">{u.enabled}</span></td>
            <td class="mono" style="color: var(--dim)">
              {u.restart && u.restart !== "no" ? `${u.restart} / ${fmt(u.restartSec)}` : "—"}
            </td>
            <td>
              {#if u.limitUnreachable}
                <span class="pill bad" title={`${fmt(u.restartSec)} × ${u.limitBurst} ≥ ${fmt(u.limitInterval)} — limiter can never trip`}>unreachable</span>
              {:else if u.restart && u.restart !== "no"}
                <span class="pill ok">{u.limitBurst}/{fmt(u.limitInterval)}</span>
              {:else}
                <span class="pill">—</span>
              {/if}
            </td>
            <td>
              <div class="row" style="justify-content: flex-end">
                {#each ACTIONS as a (a)}
                  <button class={"btn" + (DESTRUCTIVE.has(a) ? " danger" : "")} onclick={() => act(u, a)}>{a}</button>
                {/each}
              </div>
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  {/if}
</div>
