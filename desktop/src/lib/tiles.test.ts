import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, within } from "@testing-library/svelte";
import { invoke } from "@tauri-apps/api/core";
import Page from "../routes/+page.svelte";
import { DEFAULTS, prefs, resetPrefs } from "./prefs.svelte";
import { tiling } from "./tiles.svelte";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn(), Channel: vi.fn() }));

const info = { configPath: "/config.json", scriptsDir: "/scripts", hosts: [] };

beforeEach(() => {
  localStorage.clear();
  vi.mocked(invoke).mockImplementation(async (cmd: string) =>
    cmd === "app_info" ? info : cmd === "dispatch_status" ? { api: null, signedIn: false } : []);
});
afterEach(() => { cleanup(); resetPrefs(); vi.resetAllMocks(); });

const tiles = () => [...document.querySelectorAll<HTMLElement>("section.tile")];
const panelsShown = () => tiles().map((t) => t.dataset.panel);
const tile = (p: string) => document.querySelector<HTMLElement>(`section.tile[data-panel="${p}"]`)!;
const ctrl = (key: string) => fireEvent.keyDown(window, { key, ctrlKey: true });

async function renderPage() {
  render(Page);
  await vi.waitFor(() => expect(tiles().length).toBeGreaterThan(0));
}

describe("tiling", () => {
  it("opens on the Overview preset, marked in the sidebar", async () => {
    await renderPage();
    expect(panelsShown()).toEqual(["health", "services"]);
    expect(screen.getByRole("button", { name: /^Overview/ }).getAttribute("aria-pressed")).toBe("true");
    expect(document.querySelector('[data-panel="health"].entry')!.getAttribute("aria-pressed")).toBe("true");
  });

  it("adds a panel from the sidebar once, then highlights it instead", async () => {
    await renderPage();
    await fireEvent.click(document.querySelector('.entry[data-panel="configs"]')!);
    expect(panelsShown()).toContain("configs");
    const n = tiles().length;
    await fireEvent.click(document.querySelector('.entry[data-panel="configs"]')!);
    expect(tiles().length).toBe(n);
    expect(screen.getByRole("button", { name: /^Overview/ }).getAttribute("aria-pressed")).toBe("false");
  });

  it("splits, swaps, zooms and closes from the tile header", async () => {
    await renderPage();
    const h = within(tile("health"));
    await fireEvent.click(h.getByRole("button", { name: "Split down" }));
    expect(tiles().length).toBe(3);
    expect(panelsShown()).toContain("scripts"); // the first panel not already open

    await fireEvent.change(within(tile("scripts")).getByLabelText("Panel in this tile"), { target: { value: "dispatch" } });
    expect(panelsShown()).toEqual(["health", "dispatch", "services"]);

    await fireEvent.click(within(tile("services")).getByRole("button", { name: "Zoom" }));
    expect(tile("services").classList.contains("zoomed")).toBe(true);
    expect(tiles().length).toBe(3); // the others stay mounted
    await fireEvent.keyDown(window, { key: "Escape" });
    expect(tile("services").classList.contains("zoomed")).toBe(false);

    await fireEvent.click(within(tile("dispatch")).getByRole("button", { name: "Close tile" }));
    await fireEvent.click(within(tile("health")).getByRole("button", { name: "Close tile" }));
    expect(panelsShown()).toEqual(["services"]);
    expect((within(tile("services")).getByRole("button", { name: "Close tile" }) as HTMLButtonElement).disabled).toBe(true);
  });

  it("switches presets and remembers the layout", async () => {
    await renderPage();
    await fireEvent.click(screen.getByRole("button", { name: /^Everything/ }));
    expect(panelsShown()).toEqual(["health", "services", "scripts", "configs"]);
    expect(JSON.parse(localStorage.getItem("layout")!).t).toBe("split");
  });

  it("resizes with the keyboard on a focused divider", async () => {
    await renderPage();
    const d = screen.getByRole("separator");
    const ratio = () => (tiling.root.t === "split" ? tiling.root.r : NaN);
    const start = ratio();
    await fireEvent.keyDown(d, { key: "ArrowRight" });
    expect(ratio()).toBeCloseTo(start + 0.05);
    await fireEvent.keyDown(d, { key: "Enter" });
    expect(tiling.root.t === "split" && tiling.root.r).toBe(0.5);
  });

  it("answers keyboard shortcuts", async () => {
    await renderPage();
    await ctrl(",");
    expect(panelsShown()).toContain("settings");
    await ctrl("5");
    expect(panelsShown()).toContain("dispatch");
    const n = tiles().length;
    await ctrl("1");
    expect(tiles().length).toBe(n);
    await ctrl("=");
    expect(prefs.fontSize).toBe(DEFAULTS.fontSize + 1);
    await ctrl("0");
    expect(prefs.fontSize).toBe(DEFAULTS.fontSize);
  });
});
