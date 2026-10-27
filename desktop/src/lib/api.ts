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

// --- Dispatch (`src-tauri/src/dispatch.rs`) ---------------------------------
// The session stays in the backend; these name a /v1 path and get the reply.

export type DispatchStatus = { api: string | null; signedIn: boolean };
export type Reply<T> = { status: number; body: T };

export type Problem = { code: string; detail: string };

export type RoleChoice = { id: string; label: string };

export type BoardStop = {
  stop_id: string;
  sequence: number;
  kind: "PICKUP" | "DELIVERY" | "OTHER";
  address_text: string;
  window_start: string | null;
  window_end: string | null;
  contact_name: string | null;
  contact_phone_e164: string | null;
};

export type TripStatus = "PLANNED" | "ACTIVE" | "COMPLETED" | "CANCELLED";

export type BoardTrip = {
  assignment_id: string;
  operator_participant_id: string;
  vehicle_id: string | null;
  trailer_id: string | null;
  status: TripStatus;
  starts_at: string;
  ends_at: string | null;
  version: number;
};

export type BoardLoad = {
  load_id: string;
  external_reference: string | null;
  commodity_text: string | null;
  status: "DRAFT" | "TENDERED" | "BOOKED" | "IN_TRANSIT" | "DELIVERED" | "CANCELLED";
  created_at: string;
  version: number;
  stops: BoardStop[];
  trips: BoardTrip[];
};

export type Equipment = { id: string; unit_number: string; plate: string | null };
export type Fleet = {
  drivers: { participant_id: string; public_name: string }[];
  vehicles: Equipment[];
  trailers: Equipment[];
};

export const dispatchStatus = () => invoke<DispatchStatus>("dispatch_status");
export const dispatchSignIn = () => invoke<void>("dispatch_sign_in");
export const dispatchSignOut = () => invoke<void>("dispatch_sign_out");

export const dispatchRequest = <T>(
  method: "GET" | "POST" | "PATCH",
  path: string,
  opts: { body?: unknown; roleAssignmentId?: string; idempotencyKey?: string } = {},
) =>
  invoke<Reply<T>>("dispatch_request", {
    method,
    path,
    body: opts.body ?? null,
    roleAssignmentId: opts.roleAssignmentId ?? null,
    idempotencyKey: opts.idempotencyKey ?? null,
  });
