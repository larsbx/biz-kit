<script lang="ts">
  import { pending } from "./confirm.svelte";

  let busy = $state(false);
  let err = $state<string | null>(null);

  function close() {
    if (busy) return;
    pending.ask = null;
    err = null;
  }

  async function go() {
    const ask = pending.ask;
    if (!ask) return;
    busy = true;
    err = null;
    try {
      await ask.run();
      pending.ask = null;
    } catch (e) {
      err = String(e);
    } finally {
      busy = false;
    }
  }
</script>

<svelte:window onkeydown={(e) => { if (e.key === "Escape") close(); }} />

{#if pending.ask}
  {@const ask = pending.ask}
  <!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
  <div class="scrim" onmousedown={(e) => { if (e.target === e.currentTarget) close(); }}>
    <div class="modal">
      <h2>{ask.title}</h2>
      {#if ask.why}<p class="why">{ask.why}</p>{/if}
      <pre class="out">{ask.host ? `# on ${ask.host}\n` : ""}{ask.command}</pre>
      {#if err}<p class="err" style="margin-top: 10px">{err}</p>{/if}
      <div class="actions">
        <button class="btn" disabled={busy} onclick={close}>Cancel</button>
        <button class={"btn " + (ask.danger ? "danger" : "go")} disabled={busy} onclick={go}>
          {busy ? "Running…" : "Run"}
        </button>
      </div>
    </div>
  </div>
{/if}
