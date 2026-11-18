// Display preferences: theme and text size, kept in the webview's storage.
// Loaded before the stylesheet paints and before app.js, which wires the Settings view.
// Adopted from the Crew Deck (factorio-mods/deck/ui/prefs.js).
"use strict";

const PREFS = (() => {
  const KEY = "prefs"; // the key the SvelteKit app used, so saved settings carry over
  const THEMES = [
    { id: "dark", label: "Dark", hint: "The default" },
    { id: "light", label: "Light", hint: "Bright rooms" },
    { id: "contrast", label: "High contrast", hint: "Black, brighter text" },
    { id: "system", label: "Match system", hint: "Follows the OS" },
  ];
  const FONT = { min: 12, max: 22, step: 1, default: 15 };
  const DEFAULTS = { theme: "dark", fontSize: FONT.default };

  const clamp = (n) => Math.min(FONT.max, Math.max(FONT.min, Math.round(n)));

  // Keep each valid field, default the rest: a corrupt entry is taste, not data.
  function parse(raw) {
    let v = {};
    try { v = raw ? JSON.parse(raw) || {} : {}; } catch { /* defaults */ }
    return {
      theme: THEMES.some((t) => t.id === v.theme) ? v.theme : DEFAULTS.theme,
      fontSize: typeof v.fontSize === "number" && Number.isFinite(v.fontSize) ? clamp(v.fontSize) : DEFAULTS.fontSize,
    };
  }

  const mq = window.matchMedia ? window.matchMedia("(prefers-color-scheme: light)") : null;
  const resolve = (t) => (t === "system" ? (mq && mq.matches ? "light" : "dark") : t);

  let current;
  try { current = parse(localStorage.getItem(KEY)); } catch { current = { ...DEFAULTS }; }
  const listeners = [];

  function apply() {
    const root = document.documentElement;
    root.dataset.theme = resolve(current.theme);
    root.style.setProperty("--font-size", `${current.fontSize}px`);
    try { localStorage.setItem(KEY, JSON.stringify(current)); } catch { /* private window */ }
    for (const f of listeners) f(current);
  }

  function set(patch) {
    current = parse(JSON.stringify({ ...current, ...patch }));
    apply();
  }

  if (mq) mq.addEventListener("change", () => { if (current.theme === "system") apply(); });
  apply();

  return {
    THEMES, FONT, DEFAULTS, parse, resolve, set,
    get: () => ({ ...current }),
    reset: () => set(DEFAULTS),
    onChange: (f) => listeners.push(f),
  };
})();
