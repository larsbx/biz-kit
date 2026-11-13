// `npm run check`: syntax-check every ES module under ui/ (there is no bundler
// or compiler to do it), and fail if anything still imports a framework.
// Portable across the CI matrix: no shell globbing.
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const root = new URL("../ui/", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
const files = [];
const walk = (dir) => {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.name.endsWith(".js")) files.push(p);
  }
};
walk(root);
walk(new URL("../../apps/task_host/priv/static/app/", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"));

let failed = 0;
for (const f of files) {
  try {
    execFileSync(process.execPath, ["--check", f], { stdio: "pipe" });
  } catch (e) {
    failed++;
    process.stderr.write(`${f}\n${e.stderr}\n`);
  }
  const src = readFileSync(f, "utf8");
  if (/from\s+["'](svelte|@sveltejs|react|vue)/.test(src)) {
    failed++;
    process.stderr.write(`${f}: imports a UI framework; ui/ is plain modules\n`);
  }
}
console.log(`${files.length - failed}/${files.length} ui modules ok`);
process.exit(failed ? 1 : 0);
