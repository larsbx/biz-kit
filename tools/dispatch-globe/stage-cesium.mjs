import { cp, mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { build, version as esbuildVersion } from "esbuild";

const here = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.join(here, "node_modules/cesium");
const destination = path.resolve(here, "../../apps/dispatch/priv/static/vendor/cesium");
const installed = JSON.parse(await readFile(path.join(packageRoot, "package.json"), "utf8"));
if (installed.version !== "1.138.0") throw new Error("Dispatch requires Cesium 1.138.0; run npm ci.");
// Cesium uses only the decoder. The aggregate package also eagerly initializes
// four unused WebAssembly tools, so resolve its supported decoder-only entry.
const aliases = { meshoptimizer: "meshoptimizer/decoder" };

// Build only the explicit engine exports. Cesium's aggregate browser bundle
// includes the unused Viewer/Knockout UI, which evaluates code at import time
// and cannot run with JavaScript eval prohibited. CesiumWidget owns the same
// scene, entity display, camera and imagery without importing that UI.
await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
const result = await build({
  absWorkingDir: here,
  entryPoints: ["cesium-entry.mjs"],
  outfile: path.join(destination, "index.js"),
  bundle: true,
  format: "esm",
  platform: "browser",
  alias: aliases,
  target: "es2022",
  minify: true,
  treeShaking: true,
  metafile: true,
  legalComments: "inline"
});
const inputs = Object.keys(result.metafile.inputs).sort();
if (inputs.some(input => input.includes("@cesium/widgets") || /knockout/i.test(input))) {
  throw new Error("Dispatch's globe must not import the Cesium UI or Knockout");
}
for (const entry of ["Assets", "Workers"]) {
  await cp(path.join(packageRoot, "Build/Cesium", entry), path.join(destination, entry), { recursive: true });
}
await mkdir(path.join(destination, "Widgets"), { recursive: true });
await cp(
  path.join(packageRoot, "Build/Cesium/Widgets/CesiumWidget/CesiumWidget.css"),
  path.join(destination, "Widgets/widgets.css")
);
await cp(path.join(packageRoot, "LICENSE.md"), path.join(destination, "LICENSE.md"));
await stat(path.join(destination, "Assets/Textures/NaturalEarthII/0/0/0.jpg"));

async function inventory(directory, prefix = "") {
  const records = [];
  for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
    const relative = `${prefix}${entry.name}`;
    if (entry.isDirectory()) records.push(...await inventory(path.join(directory, entry.name), `${relative}/`));
    else {
      const bytes = await readFile(path.join(directory, entry.name));
      records.push({ path: relative, bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") });
    }
  }
  return records;
}
const files = await inventory(destination);
const manifest = {
  package: "cesium", version: installed.version,
  build: { entry: "cesium-entry.mjs", esbuild: esbuildVersion, aliases, inputs },
  files
};
await writeFile(path.join(destination, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`Staged Cesium ${installed.version}: ${files.length} files, ${files.reduce((sum, file) => sum + file.bytes, 0)} bytes.`);
