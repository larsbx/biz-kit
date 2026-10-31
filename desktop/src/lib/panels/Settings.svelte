<script lang="ts">
  import type { AppInfo } from "../api";
  import { FONT, THEMES, prefs, resetPrefs, setFontSize } from "../prefs.svelte";

  let { info }: { info: AppInfo } = $props();
</script>

<div class="bar">
  <h1>Settings</h1>
  <div class="spacer"></div>
  <button class="btn" onclick={resetPrefs}>Restore defaults</button>
</div>
<div class="body settings">
  <section>
    <h2>Theme</h2>
    <div class="themes" role="radiogroup" aria-label="Theme">
      {#each THEMES as t (t.id)}
        <label class={"theme" + (prefs.theme === t.id ? " on" : "")}>
          <input type="radio" name="theme" value={t.id} bind:group={prefs.theme} />
          <span class={"swatch " + t.id} aria-hidden="true"><i></i><i></i><i></i></span>
          <span class="name">{t.label}</span>
          <span class="sub">{t.hint}</span>
        </label>
      {/each}
    </div>
  </section>

  <section>
    <h2><label for="font-size">Text size</label></h2>
    <div class="row slider-row">
      <button class="btn" aria-label="Smaller text" disabled={prefs.fontSize <= FONT.min}
        onclick={() => setFontSize(prefs.fontSize - FONT.step)}>A−</button>
      <input id="font-size" class="slider grow" type="range" min={FONT.min} max={FONT.max} step={FONT.step}
        value={prefs.fontSize} oninput={(e) => setFontSize(Number(e.currentTarget.value))} />
      <button class="btn" aria-label="Larger text" disabled={prefs.fontSize >= FONT.max}
        onclick={() => setFontSize(prefs.fontSize + FONT.step)}>A+</button>
      <span class="mono value">{prefs.fontSize}px</span>
    </div>
    <p class="sub">
      Default {FONT.default}px. Shortcuts: <kbd>Ctrl</kbd> <kbd>+</kbd> / <kbd>−</kbd> to change,
      <kbd>Ctrl</kbd> <kbd>0</kbd> to reset.
    </p>
    <div class="card preview">
      <h3>Preview</h3>
      <div class="sub">This is how panel text, tables and output will read.</div>
      <div class="kv"><span>disk /</span><span>42% · 81G/193G</span></div>
      <div class="meter"><i style="width: 42%"></i></div>
    </div>
  </section>

  <section>
    <h2>Navigation</h2>
    <p class="sub">
      <kbd>Ctrl</kbd> <kbd>1</kbd>–<kbd>5</kbd> opens a panel, <kbd>Ctrl</kbd> <kbd>,</kbd> opens
      Settings, and <kbd>↑</kbd> <kbd>↓</kbd> move through the sidebar.
    </p>
  </section>

  <section>
    <h2>Installation</h2>
    <div class="kv"><span>config file</span><span class="mono">{info.configPath}</span></div>
    <div class="kv"><span>scripts directory</span><span class="mono">{info.scriptsDir}</span></div>
    <div class="kv">
      <span>hosts</span><span>{info.hosts.map((h) => h.name).join(", ") || "none"}</span>
    </div>
    <p class="sub">Hosts, checks and config patterns are edited in the config file.</p>
  </section>
</div>

<style>
  .settings { display: flex; flex-direction: column; gap: 1.6rem; max-width: 52rem; }
  h2 { font-size: 1.08rem; margin: 0 0 .6rem; font-weight: 600; }
  .sub { color: var(--dim); font-size: .85rem; margin: .5rem 0 0; }
  .themes { display: grid; grid-template-columns: repeat(auto-fill, minmax(11rem, 1fr)); gap: .6rem; }
  .theme {
    display: flex; flex-direction: column; gap: .25rem; cursor: pointer;
    background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: .7rem .8rem;
  }
  .theme:hover { border-color: var(--dim); }
  .theme.on { border-color: var(--accent); box-shadow: inset 0 0 0 1px var(--accent); }
  .theme:has(input:focus-visible) { outline: 2px solid var(--accent); outline-offset: 2px; }
  .theme input { position: absolute; opacity: 0; pointer-events: none; }
  .theme .name { font-weight: 600; }
  .theme .sub { margin: 0; }
  .swatch { display: flex; height: 1.6rem; border-radius: 5px; overflow: hidden; border: 1px solid var(--line); }
  .swatch i { flex: 1; }
  .swatch.dark i:nth-child(1) { background: #14161a; }
  .swatch.dark i:nth-child(2) { background: #21252c; }
  .swatch.dark i:nth-child(3) { background: #6aa9ff; }
  .swatch.light i:nth-child(1) { background: #f5f6f8; }
  .swatch.light i:nth-child(2) { background: #e3e7ed; }
  .swatch.light i:nth-child(3) { background: #2563c9; }
  .swatch.contrast i:nth-child(1) { background: #000; }
  .swatch.contrast i:nth-child(2) { background: #fff; }
  .swatch.contrast i:nth-child(3) { background: #4db2ff; }
  .swatch.system i:nth-child(1) { background: #14161a; }
  .swatch.system i:nth-child(2) { background: #f5f6f8; }
  .swatch.system i:nth-child(3) { background: linear-gradient(90deg, #6aa9ff, #2563c9); }
  .slider-row { gap: .75rem; }
  .value { min-width: 3.5rem; text-align: right; }
  .preview { margin-top: .8rem; max-width: 26rem; }
  .settings .kv { gap: 1rem; }
  .settings .kv span:last-child { text-align: right; overflow-wrap: anywhere; }
</style>
