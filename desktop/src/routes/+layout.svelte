<script lang="ts">
  import "#lib/styles.css";
  import { applyPrefs, prefs, watchSystemTheme } from "#lib/prefs.svelte.js";

  let { children } = $props();

  // Applied once before first paint, then again on every change.
  applyPrefs();
  $effect(() => applyPrefs({ theme: prefs.theme, fontSize: prefs.fontSize }));
  $effect(() => watchSystemTheme(() => applyPrefs()));
</script>

{@render children()}
