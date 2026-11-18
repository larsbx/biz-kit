import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { checkAssetBudget, profile } from "../profile.mjs";

test("the actual staged package meets the selected minimal profile's byte budgets", async () => {
  const manifest = JSON.parse(await readFile(new URL("../../../apps/dispatch/priv/static/vendor/cesium/manifest.json", import.meta.url), "utf8"));
  const result = checkAssetBudget(manifest);
  assert.equal(result.profile, "dispatch-fleet-workspace-v2");
  assert.ok(result.files > 0 && result.engine_bytes > 0);
  assert.ok(result.staged_asset_bytes <= profile.budgets.staged_asset_bytes);
});

test("a bloated package or engine is refused even when the other budget passes", () => {
  const manifest = {
    package: "cesium", version: profile.sources.cesium,
    build: { esbuild: profile.sources.esbuild },
    files: [{ path: "index.js", bytes: 1 }]
  };
  assert.throws(() => checkAssetBudget({ ...manifest, files: [
    ...manifest.files, { path: "extra.bin", bytes: profile.budgets.staged_asset_bytes }
  ] }), /exceeds/);
  assert.throws(() => checkAssetBudget({ ...manifest, files: [
    { path: "index.js", bytes: profile.budgets.engine_bytes + 1 }
  ] }), /exceeds/);
  assert.throws(() => checkAssetBudget({ ...manifest, version: "0.0.0" }), /do not match/);
  assert.throws(() => checkAssetBudget({ ...manifest, files: [...manifest.files, ...manifest.files] }), /Invalid/);
});
