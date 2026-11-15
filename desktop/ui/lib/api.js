// The backend's commands (src-tauri/src/*.rs), one wrapper each. With no
// bundler the Tauri API comes from `withGlobalTauri` as window.__TAURI__.
//
// Shapes (camelCase from serde):
//   AppInfo  { configPath, scriptsDir, hosts: [{ name, ssh, label }] }
//   Unit     { host, scope, id, active, enabled, restart, restartSec, limitInterval, limitBurst, limitUnreachable }
//   Health   { host, reachable, error, uptime, load, diskPct, diskUsed, diskTotal, memUsedMb, memTotalMb,
//              swapUsedMb, swapTotalMb, failedUnits: [], checks: [{ label, ok, detail }] }
//   Script   { path, name, summary, hasApply, interpreter }
//   ConfigEntry { host, path, label, size, protected }
//   Output   { stdout, stderr, code, command }
//   Line     { kind: "stdout" | "stderr", text } | { kind: "done", code }

const tauri = () => {
  const t = globalThis.__TAURI__;
  if (!t) throw new Error("Only in the desktop app");
  return t;
};
const invoke = (cmd, args) => tauri().core.invoke(cmd, args);

export const inApp = () => Boolean(globalThis.__TAURI__);

export const appInfo = () => invoke("app_info");
export const listUnits = (host) => invoke("list_units", { host });
export const hostHealth = (host) => invoke("host_health", { host });
export const listScripts = () => invoke("list_scripts");
export const listConfigs = (host) => invoke("list_configs", { host });

export const readConfig = (host, path) => invoke("read_config", { host, path });
export const diffConfig = (host, path, content, expected) => invoke("diff_config", { host, path, content, expected });
export const writeConfig = (host, path, content, expected) => invoke("write_config", { host, path, content, expected });

export const unitActionScript = (scope, unit, action) => invoke("unit_action_script", { scope, unit, action });
export const previewCommand = (host, script) => invoke("preview_command", { host, script });
export const runOn = (host, script) => invoke("run_on", { host, script });

export const openProcurement = () => invoke("open_procurement");

/** Run a local script, streaming each line to `onLine`; resolves when it has been started. */
export function runScript(path, args, onLine) {
  const ch = new (tauri().core.Channel)();
  ch.onmessage = onLine;
  return invoke("run_script", { path, args, onLine: ch });
}

// --- Dispatch (src-tauri/src/dispatch.rs) -------------------------------------
// The session stays in the backend; these name a /v1 path and get the reply
// { status, body }.

export const dispatchStatus = () => invoke("dispatch_status"); // { api, signedIn }
export const dispatchSignIn = () => invoke("dispatch_sign_in");
export const dispatchSignOut = () => invoke("dispatch_sign_out");
export const dispatchRequest = (method, path, opts = {}) =>
  invoke("dispatch_request", {
    method,
    path,
    body: opts.body ?? null,
    roleAssignmentId: opts.roleAssignmentId ?? null,
    idempotencyKey: opts.idempotencyKey ?? null,
  });

// --- Operations (src-tauri/src/operations.rs) ---------------------------------
// The task host's /operations page in a child webview laid over its tile.

export const operationsStatus = () => invoke("operations_status"); // { url, configured }
/** Show the Operations webview at a rectangle in CSS pixels of the main window. */
export const operationsPlace = (rect) => invoke("operations_place", rect);
export const operationsHide = () => invoke("operations_hide");
export const operationsReload = () => invoke("operations_reload");
