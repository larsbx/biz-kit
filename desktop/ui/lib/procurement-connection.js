// The installed UI edits only the procurement origin, with a native revision guard.
const invoke = (name, args) => {
  const api = globalThis.__TAURI__?.core;
  if (!api) throw new Error("Only in the desktop app");
  return api.invoke(name, args);
};
export const readConnection = () => invoke("procurement_connection");
export const saveConnection = (origin, expectedRevision) =>
  invoke("save_procurement_connection", { origin, expectedRevision });

export function httpsOrigin(raw) {
  const url = new URL(raw.trim());
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password ||
      url.pathname !== "/" || url.search || url.hash) {
    throw new Error("Use an HTTPS server origin without a path, credentials, query or fragment.");
  }
  return url.origin;
}
