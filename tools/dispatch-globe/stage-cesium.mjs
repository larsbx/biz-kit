import { cp, mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.join(here, "node_modules/cesium");
const destination = path.resolve(here, "../../apps/dispatch/priv/static/vendor/cesium");
const installed = JSON.parse(await readFile(path.join(packageRoot, "package.json"), "utf8"));
if (installed.version !== "1.138.0") throw new Error("Dispatch requires Cesium 1.138.0; run npm ci.");

// Copy the prebuilt ESM browser distribution only. There is no application
// bundler or Node service, and no CDN is contacted by the running viewer.
await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
for (const entry of ["index.js", "Assets", "Workers", "Widgets"]) {
  await cp(path.join(packageRoot, "Build/Cesium", entry), path.join(destination, entry), { recursive: true });
}
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
const manifest = { package: "cesium", version: installed.version, files };
await writeFile(path.join(destination, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`Staged Cesium ${installed.version}: ${files.length} files, ${files.reduce((sum, file) => sum + file.bytes, 0)} bytes.`);
