import { readFile } from "node:fs/promises";

export const profile = JSON.parse(await readFile(new URL("./profile.json", import.meta.url), "utf8"));

/** Enforce the selected package budget against emitted bytes, not source estimates. */
export function checkAssetBudget(manifest, selected = profile) {
  if (manifest.package !== "cesium" || manifest.version !== selected.sources.cesium ||
      manifest.build?.esbuild !== selected.sources.esbuild || !Array.isArray(manifest.files)) {
    throw new Error("The staged assets do not match the selected Dispatch profile");
  }
  const files = new Set();
  let total = 0;
  for (const entry of manifest.files) {
    if (typeof entry.path !== "string" || files.has(entry.path) ||
        !Number.isSafeInteger(entry.bytes) || entry.bytes < 0) {
      throw new Error("Invalid staged asset inventory");
    }
    files.add(entry.path);
    total += entry.bytes;
  }
  const engine = manifest.files.find(entry => entry.path === "index.js");
  if (!engine || !Number.isSafeInteger(total) || total > selected.budgets.staged_asset_bytes ||
      engine.bytes > selected.budgets.engine_bytes) {
    throw new Error("The emitted Dispatch globe exceeds its selected asset budget");
  }
  return { profile: selected.id, staged_asset_bytes: total, engine_bytes: engine.bytes, files: files.size };
}
