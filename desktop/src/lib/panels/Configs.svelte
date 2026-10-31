<script lang="ts">
  import { untrack } from "svelte";
  import PanelBar from "../PanelBar.svelte";
  import { type AppInfo, type ConfigEntry, listConfigs, readConfig, diffConfig, writeConfig } from "../api";
  import { confirm } from "../confirmation.svelte";
  import HostSelect from "../HostSelect.svelte";

  let { info }: { info: AppInfo } = $props();
  const hosts = $derived(info.hosts);

  // The first host is only the starting choice; the picker owns it after.
  let host = $state(untrack(() => info.hosts[0]?.name ?? ""));
  let items = $state<ConfigEntry[]>([]);
  let open = $state<ConfigEntry | null>(null);
  let orig = $state("");
  let text = $state("");
  let diff = $state<string | null>(null);
  let busy = $state(false);
  let err = $state<string | null>(null);

  async function load(h = host) {
    if (!h) return;
    busy = true; err = null; open = null; diff = null;
    try { items = await listConfigs(h); }
    catch (e) { err = String(e); items = []; }
    finally { busy = false; }
  }
  $effect(() => { load(host); });

  async function openFile(c: ConfigEntry) {
    busy = true; err = null; diff = null;
    try {
      const s = await readConfig(c.host, c.path);
      orig = s; text = s; open = c;
    } catch (e) { err = String(e); }
    finally { busy = false; }
  }

  async function review() {
    if (!open) return;
    busy = true; err = null;
    try { diff = await diffConfig(open.host, open.path, text); }
    catch (e) { err = String(e); }
    finally { busy = false; }
  }

  function save() {
    const file = open;
    if (!file) return;
    confirm({
      title: `Overwrite ${file.path}?`,
      why: "A timestamped .bak copy is written first. JSON files are validated before the write.",
      command: `# on ${file.host}\ncp -a ${file.path} ${file.path}.bak-<timestamp>\n# then replace with your edited contents`,
      host: file.host,
      danger: true,
      run: async () => {
        await writeConfig(file.host, file.path, text);
        orig = text;
        diff = null;
        await load();
      },
    });
  }

  const dirty = $derived(text !== orig);

  function diffClass(l: string) {
    return l.startsWith("+++") || l.startsWith("---") || l.startsWith("@@")
      ? "diff-hdr"
      : l.startsWith("+") ? "diff-add"
      : l.startsWith("-") ? "diff-del"
      : undefined;
  }
</script>

<PanelBar title="Configs">
  <HostSelect {hosts} bind:value={host} />
  <div class="spacer"></div>
  {#if open}
    {#if open.protected}<span class="pill">read-only</span>{/if}
    {#if dirty}<span class="pill warn">unsaved</span>{/if}
    <button class="btn" onclick={review} disabled={busy || !dirty}>Review diff</button>
    <button class="btn danger" onclick={save} disabled={busy || !dirty || open.protected}>Save…</button>
    <button class="btn" onclick={() => { open = null; diff = null; }} disabled={busy}>Close</button>
  {:else}
    <button class="btn" onclick={() => load()} disabled={busy}>Refresh</button>
  {/if}
</PanelBar>

<div class="body">
  {#if err}<p class="err">{err}</p>{/if}

  {#if !open}
    <table>
      <thead><tr><th>Type</th><th>Path</th><th style="width: 6rem">Size</th></tr></thead>
      <tbody>
        {#each items as c (c.path)}
          <tr style="cursor: pointer" onclick={() => openFile(c)}>
            <td>{c.label} {#if c.protected}<span class="pill">read-only</span>{/if}</td>
            <td class="mono trunc" style="max-width: 36rem">{c.path}</td>
            <td style="color: var(--dim)">{c.size}</td>
          </tr>
        {/each}
      </tbody>
    </table>
    {#if !busy && items.length === 0}
      <div class="empty">No matching files on {host}. Patterns are set under <code class="mono">configs</code> in {info.configPath}</div>
    {/if}
  {:else}
    <div class="mono" style="font-size: .92rem; color: var(--dim); margin-bottom: 8px">{open.host}:{open.path}</div>
    {#if diff}
      <div class="row" style="margin-bottom: 6px">
        <strong style="font-size: .92rem">Pending change</strong>
        <div class="spacer"></div>
        <button class="btn" onclick={() => (diff = null)}>Back to editor</button>
      </div>
      <pre class="out">{#each diff.split("\n") as l, i (i)}<div class={diffClass(l)}>{l || " "}</div>{/each}</pre>
    {:else}
      <textarea class="editor" bind:value={text} spellcheck={false} readonly={open.protected}></textarea>
    {/if}
  {/if}
</div>
