/**
 * Display preferences: how the app looks on this machine. They are a matter of
 * taste, not installation, so they live in the webview's storage rather than in
 * `config.json` alongside hosts and checks.
 */

export type Theme = "dark" | "light" | "contrast" | "system";

export const THEMES: { id: Theme; label: string; hint: string }[] = [
  { id: "dark", label: "Dark", hint: "The default" },
  { id: "light", label: "Light", hint: "For bright rooms" },
  { id: "contrast", label: "High contrast", hint: "Black background, brighter text and borders" },
  { id: "system", label: "Match system", hint: "Dark or light, following the OS setting" },
];

/** Base text size in px. Everything else in the stylesheet is relative to it. */
export const FONT = { min: 12, max: 22, step: 1, default: 15 } as const;

export type Prefs = { theme: Theme; fontSize: number };

export const DEFAULTS: Prefs = { theme: "dark", fontSize: FONT.default };

const KEY = "prefs";

const clampFont = (n: number) => Math.min(FONT.max, Math.max(FONT.min, Math.round(n)));

/** Parse stored prefs, keeping each valid field and defaulting the rest. */
export function parsePrefs(raw: string | null): Prefs {
  let v: Partial<Prefs> = {};
  try {
    v = raw ? JSON.parse(raw) : {};
  } catch {
    // A corrupt entry is display taste, not data: fall back to the defaults.
  }
  const theme = THEMES.some((t) => t.id === v?.theme) ? (v.theme as Theme) : DEFAULTS.theme;
  const fontSize = typeof v?.fontSize === "number" && Number.isFinite(v.fontSize)
    ? clampFont(v.fontSize)
    : DEFAULTS.fontSize;
  return { theme, fontSize };
}

export const prefs = $state<Prefs>(parsePrefs(localStorage.getItem(KEY)));

const systemDark = () => !window.matchMedia?.("(prefers-color-scheme: light)").matches;

/** The concrete theme a preference resolves to right now. */
export const resolveTheme = (t: Theme): Exclude<Theme, "system"> =>
  t === "system" ? (systemDark() ? "dark" : "light") : t;

/** Write prefs to the document and to storage. */
export function applyPrefs(p: Prefs = prefs, root: HTMLElement = document.documentElement) {
  root.dataset.theme = resolveTheme(p.theme);
  root.style.setProperty("--font-size", `${p.fontSize}px`);
  localStorage.setItem(KEY, JSON.stringify({ theme: p.theme, fontSize: p.fontSize }));
}

export function setFontSize(n: number) {
  prefs.fontSize = clampFont(n);
}

export function resetPrefs() {
  Object.assign(prefs, DEFAULTS);
}

/** Re-resolve "Match system" when the OS switches between dark and light. */
export function watchSystemTheme(onChange: () => void): () => void {
  const mq = window.matchMedia?.("(prefers-color-scheme: light)");
  if (!mq) return () => {};
  mq.addEventListener("change", onChange);
  return () => mq.removeEventListener("change", onChange);
}
