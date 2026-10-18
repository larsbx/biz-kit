import { invoke, Channel } from "@tauri-apps/api/core";

export type Host = { name: string; ssh: string | null; label: string };

export type AppInfo = { configPath: string; scriptsDir: string; hosts: Host[] };

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

export type CheckResult = { label: string; ok: boolean; detail: string };

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
  checks: CheckResult[];
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
  size: number;
  protected: boolean;
};

export type Output = { stdout: string; stderr: string; code: number; command: string };

export type Line =
  | { kind: "stdout"; text: string }
  | { kind: "stderr"; text: string }
  | { kind: "done"; code: number };

export const appInfo = () => invoke<AppInfo>("app_info");
export const listUnits = (host: string) => invoke<Unit[]>("list_units", { host });
export const hostHealth = (host: string) => invoke<Health>("host_health", { host });
export const listScripts = () => invoke<Script[]>("list_scripts");
export const listConfigs = (host: string) => invoke<ConfigEntry[]>("list_configs", { host });

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
  invoke<Output>("run_on", { host, script });

export function runScript(path: string, args: string[], onLine: (l: Line) => void) {
  const ch = new Channel<Line>();
  ch.onmessage = onLine;
  return invoke<void>("run_script", { path, args, onLine: ch });
}
