import { invoke, Channel } from "@tauri-apps/api/core";

export type Host = { name: string; ssh: string | null; label: string };

export type Unit = {
  host: string;
  scope: "user" | "system";
  id: string;
  active: string;
  enabled: string;
  restart: string;
  restartSec: number;
  limitInterval: number;
  limitBurst: number;
  limitUnreachable: boolean;
};

export type Health = {
  host: string;
  reachable: boolean;
  error: string | null;
  uptime: string;
  load: string;
  diskPct: number;
  diskUsed: string;
  diskTotal: string;
  memUsedMb: number;
  memTotalMb: number;
  swapUsedMb: number;
  swapTotalMb: number;
  failedUnits: string[];
  tailscaleIp: string;
  syncthing: { running: boolean; folders: number; connectedPeers: number; errors: string[] } | null;
};

export type Script = {
  path: string;
  name: string;
  summary: string;
  hasApply: boolean;
  interpreter: string;
};

export type ConfigEntry = {
  host: string;
  path: string;
  label: string;
  exists: boolean;
  size: number;
};

export type Output = { stdout: string; stderr: string; code: number; command: string };

export type Line =
  | { kind: "stdout"; text: string }
  | { kind: "stderr"; text: string }
  | { kind: "done"; code: number };

// Rust serialises struct fields as snake_case; Tauri v2 does not rename them, so
// normalise here rather than sprinkling snake_case through the components.
function camel<T>(v: any): T {
  if (Array.isArray(v)) return v.map(camel) as any;
  if (v && typeof v === "object") {
    const out: any = {};
    for (const [k, val] of Object.entries(v)) {
      out[k.replace(/_([a-z])/g, (_, c) => c.toUpperCase())] = camel(val);
    }
    return out;
  }
  return v;
}

export const listHosts = () => invoke<Host[]>("list_hosts").then(camel<Host[]>);
export const listUnits = (host: string) =>
  invoke<Unit[]>("list_units", { host }).then(camel<Unit[]>);
export const hostHealth = (host: string) =>
  invoke<Health>("host_health", { host }).then(camel<Health>);
export const listScripts = () => invoke<Script[]>("list_scripts").then(camel<Script[]>);
export const listConfigs = (host: string) =>
  invoke<ConfigEntry[]>("list_configs", { host }).then(camel<ConfigEntry[]>);

export const readConfig = (host: string, path: string) =>
  invoke<string>("read_config", { host, path });
export const diffConfig = (host: string, path: string, content: string) =>
  invoke<string>("diff_config", { host, path, content });
export const writeConfig = (host: string, path: string, content: string) =>
  invoke<string>("write_config", { host, path, content });

export const unitActionScript = (scope: string, unit: string, action: string) =>
  invoke<string>("unit_action_script", { scope, unit, action });
export const previewCommand = (host: string, script: string) =>
  invoke<string>("preview_command", { host, script });
export const runOn = (host: string, script: string) =>
  invoke<Output>("run_on", { host, script }).then(camel<Output>);

export function runScript(path: string, args: string[], onLine: (l: Line) => void) {
  const ch = new Channel<Line>();
  ch.onmessage = (m) => onLine(camel<Line>(m));
  return invoke<void>("run_script", { path, args, onLine: ch });
}
