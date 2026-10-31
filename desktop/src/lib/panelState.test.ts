import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, within } from "@testing-library/svelte";
import { invoke } from "@tauri-apps/api/core";
import Page from "../routes/+page.svelte";
import { PANELS } from "./panels";
import { serialize } from "./layout";
import { restoreLayout, tileEls, tiling } from "./tiling.svelte";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn(), Channel: vi.fn() }));
const original = '{"token":"original-fixture"}';
const draft = (n: number) => `{"token":"unsaved-secret-${n}"}`;
const storedLeaf = (p = "configs") => ({ t: "leaf", p });
const storedSplit = (a: unknown, b: unknown, dir = "h") => ({ t: "split", dir, r: 0.4, a, b });
const configTiles = () => [...document.querySelectorAll<HTMLElement>('section.tile[data-panel="configs"]')];
const button = (tile: HTMLElement, name: string) => within(tile).getByRole("button", { name });
const editorIn = (tile: HTMLElement) => within(tile).queryByRole("textbox") as HTMLTextAreaElement | null;

beforeEach(() => {
  localStorage.clear();
  sessionStorage.clear();
  vi.mocked(invoke).mockImplementation(async (cmd, args) => {
    const host = (args as { host?: string })?.host ?? "local";
    if (cmd === "app_info") return {
      configPath: "/fixture/config.json", scriptsDir: "/fixture/scripts",
      hosts: [{ name: "local", label: "Local", ssh: null }, { name: "remote", label: "Remote", ssh: "fixture" }],
    };
    if (cmd === "list_configs") return [{ host, path: "/fixture/app.json", label: "Fixture", size: original.length, protected: false }];
    if (cmd === "read_config") return original;
    if (cmd === "diff_config") return "-original\n+fixture-draft";
    if (cmd === "dispatch_status") return { api: null, signedIn: false };
    if (cmd === "host_health") return { host, reachable: false, error: "Fixture", checks: [], failedUnits: [] };
    return [];
  });
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.resetAllMocks(); vi.unstubAllGlobals(); });

async function start(layout: unknown = storedLeaf()) {
  localStorage.setItem("layout", JSON.stringify(layout));
  render(Page);
  await screen.findAllByText("/fixture/app.json");
  return configTiles();
}
async function edit(tile: HTMLElement, n: number) {
  await fireEvent.click(await within(tile).findByText("/fixture/app.json"));
  const editor = await within(tile).findByRole("textbox") as HTMLTextAreaElement;
  expect(editor.value).toBe(original);
  await fireEvent.input(editor, { target: { value: draft(n) } });
  return editor;
}
function kept(tile: HTMLElement, editor: HTMLTextAreaElement, n: number) {
  expect(tile.isConnected).toBe(true);
  expect(editorIn(tile)).toBe(editor);
  expect(editor.value).toBe(draft(n));
  expect(within(tile).getByText("unsaved")).toBeTruthy();
}
function noStoredContents() {
  for (const storage of [localStorage, sessionStorage]) {
    const values = Array.from({ length: storage.length }, (_, i) => storage.getItem(storage.key(i)!)).join("");
    expect(values).not.toContain("unsaved-secret");
    expect(values).not.toContain("original-fixture");
  }
}

describe("mounted panel lifetime", () => {
  it.each(["Split right", "Split down"])("preserves independent duplicate editors across %s and nested splits", async (split) => {
    const [first] = await start();
    const a = await edit(first, 1);
    await fireEvent.click(button(first, split));
    const other = [...document.querySelectorAll<HTMLElement>("section.tile")].find((t) => t !== first)!;
    await fireEvent.change(within(other).getByLabelText("Panel in this tile"), { target: { value: "configs" } });
    const second = configTiles()[1];
    await fireEvent.change(second.querySelector("select.btn")!, { target: { value: "remote" } });
    const b = await edit(second, 2);
    // Host selection is instance-local as well as the document and text.
    expect((first.querySelector("select.btn") as HTMLSelectElement).value).toBe("local");
    await fireEvent.click(button(first, "Split down"));
    kept(first, a, 1);
    kept(second, b, 2);
    expect((second.querySelector("select.btn") as HTMLSelectElement).value).toBe("remote");
    expect(vi.mocked(invoke).mock.calls.filter(([cmd]) => cmd === "read_config")).toHaveLength(2);
    noStoredContents();
  });

  it.each([false, true])("keeps both editors when closing an adjacent pane promotes their subtree (before=%s)", async (before) => {
    const configs = storedSplit(storedLeaf(), storedLeaf(), "v");
    const [first, second] = await start(before
      ? storedSplit(storedLeaf("services"), configs)
      : storedSplit(configs, storedLeaf("services")));
    const a = await edit(first, 1), b = await edit(second, 2);
    await fireEvent.click(button(document.querySelector<HTMLElement>('[data-panel="services"].tile')!, "Close tile"));
    kept(first, a, 1); kept(second, b, 2);
    // Context still names the correct leaf after promotion and keyed moves.
    await fireEvent.click(button(first, "Close tile"));
    kept(second, b, 2);
    expect(first.isConnected).toBe(false);
    expect(tileEls.size).toBe(1);
    noStoredContents();
  });

  it("preserves drafts through sidebar/shortcut insertion, zoom, and keyboard/double-click resizing", async () => {
    const [tile] = await start();
    const editor = await edit(tile, 1);
    await fireEvent.click(document.querySelector('.entry[data-panel="services"]')!);
    kept(tile, editor, 1);
    await fireEvent.keyDown(window, { key: ",", ctrlKey: true });
    kept(tile, editor, 1);
    await fireEvent.click(button(tile, "Zoom"));
    expect(tile.style.inset).toBe("0px");
    await fireEvent.keyDown(window, { key: "Escape" });
    for (const divider of screen.getAllByRole("separator")) {
      await fireEvent.keyDown(divider, { key: "ArrowRight" });
      await fireEvent.keyDown(divider, { key: "ArrowDown" });
      await fireEvent.doubleClick(divider);
      kept(tile, editor, 1);
    }
    await fireEvent.click(document.querySelector('.entry[data-panel="configs"]')!);
    kept(tile, editor, 1);
    expect(configTiles()).toHaveLength(1);
    noStoredContents();
  });

  it("preserves review mode and sends the correct surviving draft to the backend", async () => {
    const [tile] = await start(storedSplit(storedLeaf("services"), storedLeaf()));
    await edit(tile, 1);
    await fireEvent.click(button(tile, "Review diff"));
    const review = await within(tile).findByText("+fixture-draft");
    await fireEvent.click(button(document.querySelector<HTMLElement>('[data-panel="services"].tile')!, "Close tile"));
    expect(within(tile).getByText("+fixture-draft")).toBe(review);
    await fireEvent.click(button(tile, "Back to editor"));
    expect(editorIn(tile)?.value).toBe(draft(1));
    await fireEvent.click(button(tile, "Review diff"));
    expect(invoke).toHaveBeenLastCalledWith("diff_config", { host: "local", path: "/fixture/app.json", content: draft(1) });
  });

  it.each([false, true])("keeps the editor through pointer resize and cleanup (cancel=%s)", async (cancel) => {
    const [tile] = await start(storedSplit(storedLeaf(), storedLeaf("services")));
    const editor = await edit(tile, 1);
    const divider = screen.getByRole("separator");
    const initial = tiling.root;
    const initialStyle = tile.style.width;
    vi.spyOn(divider.parentElement!, "getBoundingClientRect").mockReturnValue({ left: 0, top: 0, width: 1012, height: 600 } as DOMRect);
    Object.defineProperty(divider, "setPointerCapture", { value: vi.fn(), configurable: true });
    vi.stubGlobal("PointerEvent", class extends MouseEvent {
      pointerId = 1;
    });
    await fireEvent.pointerDown(divider, { clientX: 406, clientY: 100 });
    await fireEvent.pointerMove(divider, { clientX: 706, clientY: 100 });
    expect(tile.style.width).not.toBe(initialStyle);
    expect(tiling.root).toBe(initial); // preview only; persistent ratio commits on release
    kept(tile, editor, 1);
    await (cancel ? fireEvent.pointerCancel(divider) : fireEvent.pointerUp(divider));
    kept(tile, editor, 1);
    expect(tiling.root.t === "split" && tiling.root.r).toBe(cancel ? 0.4 : 0.7);
    if (cancel) expect(tile.style.width).toBe(initialStyle);
    noStoredContents();
  });

  it("keeps another panel's local filter when its position changes", async () => {
    const [tile] = await start(storedSplit(storedLeaf("services"), storedLeaf()));
    const services = document.querySelector<HTMLElement>('[data-panel="services"].tile')!;
    const filter = await within(services).findByPlaceholderText("Filter…") as HTMLInputElement;
    await fireEvent.input(filter, { target: { value: "retain-this-filter" } });
    await fireEvent.click(button(services, "Split down"));
    await fireEvent.click(button(tile, "Close tile"));
    expect(within(services).getByPlaceholderText("Filter…")).toBe(filter);
    expect(filter.value).toBe("retain-this-filter");
  });

  it("retains panels through presets and live restoration, with only geometry saved across a reload", async () => {
    const [tile] = await start();
    const editor = await edit(tile, 1);
    await fireEvent.click(screen.getByRole("button", { name: /^Everything/ }));
    kept(tile, editor, 1);
    const saved = localStorage.getItem("layout")!;
    restoreLayout(PANELS.map((p) => p.id));
    await vi.waitFor(() => kept(tile, editor, 1));
    expect(JSON.stringify(serialize(tiling.root))).toBe(saved);
    noStoredContents();
    cleanup();
    render(Page);
    await screen.findByText("/fixture/app.json");
    expect(configTiles().every((tile) => editorIn(tile) === null)).toBe(true);
    expect(JSON.stringify(serialize(tiling.root))).toBe(saved);
    const fresh = configTiles()[0];
    await fireEvent.click(within(fresh).getByText("/fixture/app.json"));
    expect((await within(fresh).findByRole("textbox") as HTMLTextAreaElement).value).toBe(original);
  });

  it("restores duplicate panel occurrences without sharing or persisting their drafts", async () => {
    const [first, second] = await start(storedSplit(storedLeaf(), storedLeaf(), "v"));
    const a = await edit(first, 1), b = await edit(second, 2);
    restoreLayout(PANELS.map((p) => p.id));
    await vi.waitFor(() => { kept(first, a, 1); kept(second, b, 2); });
    noStoredContents();
    cleanup();
    render(Page);
    await screen.findAllByText("/fixture/app.json");
    expect(configTiles()).toHaveLength(2);
    expect(screen.queryByRole("textbox")).toBeNull();
    expect(tileEls.size).toBe(2);
  });
});
