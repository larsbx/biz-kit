// TaskHost serves an allowlisted static directory; Tauri packages ui/ directly.
// Keep the shared tiling model and divider identical in both deliverables.
import { readFileSync, writeFileSync } from "node:fs";
const check = process.argv.includes("--check");
for (const file of ["layout.js", "divider.js"]) {
  const source = new URL(`../ui/lib/${file}`, import.meta.url);
  const target = new URL(`../../apps/task_host/priv/static/app/${file}`, import.meta.url);
  const bytes = readFileSync(source);
  if (check) {
    if (!bytes.equals(readFileSync(target))) throw new Error(`${file}: run node tools/sync-task-tiles.mjs from desktop/`);
  } else writeFileSync(target, bytes);
}
