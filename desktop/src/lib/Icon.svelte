<script lang="ts" module>
  /** Stroke paths on a 24×24 grid. One entry per panel icon. */
  const PATHS = {
    health: ["M22 12h-4l-3 9L9 3l-3 9H2"],
    services: [
      "M4 3h16a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z",
      "M4 13h16a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-4a2 2 0 0 1 2-2z",
      "M6 7h.01M6 17h.01",
    ],
    scripts: ["M4 17l6-6-6-6", "M12 19h8"],
    configs: ["M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z", "M14 2v6h6", "M8 13h8M8 17h5"],
    dispatch: [
      "M1 4h14v12H1z",
      "M15 8h4l4 4v4h-8",
      "M5.5 21a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM18.5 21a2 2 0 1 0 0-4 2 2 0 0 0 0 4z",
    ],
    settings: ["M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3", "M1 14h6M9 8h6M17 16h6"],
    layout: ["M4 3h16a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z", "M12 3v18M12 12h9"],
    "split-h": ["M4 4h16a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1z", "M12 4v16"],
    "split-v": ["M4 4h16a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1z", "M3 12h18"],
    zoom: ["M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7"],
    restore: ["M4 14h6v6M20 10h-6V4M14 10l7-7M3 21l7-7"],
    close: ["M6 6l12 12M18 6L6 18"],
    sidebar: ["M4 3h16a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z", "M9 3v18"],
  } satisfies Record<string, string[]>;

  export type IconName = keyof typeof PATHS;
</script>

<script lang="ts">
  let { name }: { name: IconName } = $props();
</script>

<svg class="icon" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor"
  stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  {#each PATHS[name] as d (d)}<path {d} />{/each}
</svg>
