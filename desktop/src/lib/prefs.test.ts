import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { DEFAULTS, FONT, applyPrefs, parsePrefs, prefs, resetPrefs, resolveTheme } from "./prefs.svelte";
import Settings from "./panels/Settings.svelte";
import Page from "../routes/+page.svelte";

vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn().mockResolvedValue({ configPath: "/config.json", scriptsDir: "/scripts", hosts: [] }),
  Channel: vi.fn(),
}));

const info = { configPath: "/config.json", scriptsDir: "/scripts", hosts: [] };

afterEach(() => { cleanup(); resetPrefs(); localStorage.clear(); });

describe("parsePrefs", () => {
  it("defaults to the dark theme at a larger text size", () => {
    expect(parsePrefs(null)).toEqual({ theme: "dark", fontSize: 15 });
    expect(DEFAULTS.fontSize).toBeGreaterThan(13);
  });

  it("keeps valid fields and replaces invalid ones", () => {
    expect(parsePrefs('{"theme":"light","fontSize":18}')).toEqual({ theme: "light", fontSize: 18 });
    expect(parsePrefs('{"theme":"neon","fontSize":"big"}')).toEqual(DEFAULTS);
    expect(parsePrefs("not json")).toEqual(DEFAULTS);
  });

  it("clamps the text size to the slider's range", () => {
    expect(parsePrefs('{"fontSize":4}').fontSize).toBe(FONT.min);
    expect(parsePrefs('{"fontSize":99}').fontSize).toBe(FONT.max);
  });
});

describe("applyPrefs", () => {
  it("sets the theme and base size on the document and persists them", () => {
    const root = document.createElement("div");
    applyPrefs({ theme: "contrast", fontSize: 19 }, root);
    expect(root.dataset.theme).toBe("contrast");
    expect(root.style.getPropertyValue("--font-size")).toBe("19px");
    expect(JSON.parse(localStorage.getItem("prefs")!)).toEqual({ theme: "contrast", fontSize: 19 });
  });

  it("resolves 'system' to a concrete theme", () => {
    expect(["dark", "light"]).toContain(resolveTheme("system"));
  });
});

describe("Settings panel", () => {
  it("changes the theme and text size", async () => {
    render(Settings, { info });
    await fireEvent.click(screen.getByLabelText(/Light/));
    expect(prefs.theme).toBe("light");
    await fireEvent.input(screen.getByLabelText("Text size"), { target: { value: "20" } });
    expect(prefs.fontSize).toBe(20);
    await fireEvent.click(screen.getByRole("button", { name: "Smaller text" }));
    expect(prefs.fontSize).toBe(19);
    await fireEvent.click(screen.getByRole("button", { name: "Restore defaults" }));
    expect(prefs).toEqual(DEFAULTS);
  });
});

describe("sidebar navigation", () => {
  it("groups panels, marks the current one, and answers keyboard shortcuts", async () => {
    render(Page);
    expect(screen.getByText("Hosts")).toBeTruthy();
    expect(screen.getByText("Business")).toBeTruthy();
    const current = () => document.querySelector('[aria-current="page"]')?.getAttribute("data-panel");
    expect(current()).toBe("health");

    await fireEvent.keyDown(window, { key: ",", ctrlKey: true });
    expect(current()).toBe("settings");
    await fireEvent.keyDown(window, { key: "5", ctrlKey: true });
    expect(current()).toBe("dispatch");
    await fireEvent.keyDown(document.querySelector('[data-panel="dispatch"]')!, { key: "ArrowUp" });
    expect(current()).toBe("configs");

    await fireEvent.keyDown(window, { key: "=", ctrlKey: true });
    expect(prefs.fontSize).toBe(DEFAULTS.fontSize + 1);
    await fireEvent.keyDown(window, { key: "0", ctrlKey: true });
    expect(prefs.fontSize).toBe(DEFAULTS.fontSize);
  });
});
