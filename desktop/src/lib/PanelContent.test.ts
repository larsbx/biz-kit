import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/svelte";
import { invoke } from "@tauri-apps/api/core";
import PanelContent from "./PanelContent.svelte";
import { PANELS } from "./panels";
import type { AppInfo } from "./api";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn(), Channel: vi.fn() }));

const info: AppInfo = { configPath: "/config.json", scriptsDir: "/scripts", hosts: [] };
const panel = (id: string) => PANELS.find((p) => p.id === id)!;

afterEach(() => { cleanup(); vi.resetAllMocks(); localStorage.clear(); });

describe("panel connection requirements", () => {
  it("renders repeated Health failure lines without crashing the desktop", async () => {
    vi.mocked(invoke).mockResolvedValue({
      host: "local", reachable: true, error: null, uptime: "", load: "", diskPct: 0,
      diskUsed: "", diskTotal: "", memUsedMb: 0, memTotalMb: 0, swapUsedMb: 0,
      swapTotalMb: 0, failedUnits: ["Repeated failure", "Repeated failure"], checks: [],
    });
    render(PanelContent, {
      info: { ...info, hosts: [{ name: "local", label: "Local", ssh: null }] },
      panel: panel("health"),
    });
    expect(await screen.findAllByText("Repeated failure")).toHaveLength(2);
  });

  it("opens Dispatch and uses its API with no SSH hosts", async () => {
    vi.mocked(invoke).mockResolvedValue({ signedIn: false, api: "https://dispatch.example", auth: "https://auth.example" });
    render(PanelContent, { info, panel: panel("dispatch") });
    expect(await screen.findByRole("button", { name: "Sign in" })).toBeTruthy();
    expect(screen.getByText("https://dispatch.example")).toBeTruthy();
    expect(invoke).toHaveBeenCalledWith("dispatch_status");
    expect(screen.queryByText(/No hosts configured/)).toBeNull();
  });

  it("shows Dispatch's own configuration prompt when its API is absent", async () => {
    vi.mocked(invoke).mockResolvedValue({ signedIn: false, api: null });
    render(PanelContent, { info, panel: panel("dispatch") });
    expect(await screen.findByText(/Dispatch is not configured/)).toBeTruthy();
    expect(screen.queryByText(/No hosts configured/)).toBeNull();
  });

  it.each(["health", "services", "scripts", "configs"])("keeps the empty-host prompt for %s", (id) => {
    render(PanelContent, { info, panel: panel(id) });
    expect(screen.getByText(/No hosts configured/)).toBeTruthy();
    expect(invoke).not.toHaveBeenCalled();
  });

  it("opens a host-backed panel when a host is present", async () => {
    vi.mocked(invoke).mockResolvedValue([]);
    render(PanelContent, {
      info: { ...info, hosts: [{ name: "local", label: "Local", ssh: null }] },
      panel: panel("services"),
    });
    expect(screen.queryByText(/No hosts configured/)).toBeNull();
    await vi.waitFor(() => expect(invoke).toHaveBeenCalledWith("list_units", { host: "local" }));
  });
});
