import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { CSP } from "./fixtures.mjs";

test("the emitted engine imports with string code generation disabled; the old aggregate fails", async () => {
  const temporary = await mkdtemp(path.join(tmpdir(), "dispatch-globe-no-eval-"));
  try {
    async function importWithoutEval(source, name) {
      // Give Node the browser's ESM interpretation without changing a byte of
      // either artifact. Cesium's npm root otherwise treats its Build/*.js as CJS.
      const target = path.join(temporary, `${name}.mjs`);
      await writeFile(target, await readFile(source));
      const probe = `
        try {
          const engine = await import(${JSON.stringify(pathToFileURL(target).href)});
          console.log(JSON.stringify({ exports: Object.keys(engine), widget: typeof engine.CesiumWidget }));
        } catch (error) {
          console.error(error.name + ": " + error.message);
          process.exitCode = 1;
        }
      `;
      return spawnSync(process.execPath, ["--disallow-code-generation-from-strings", "--input-type=module", "-e", probe], { encoding: "utf8", timeout: 15000 });
    }
    const original = await importWithoutEval(new URL("../node_modules/cesium/Build/Cesium/index.js", import.meta.url), "aggregate");
    assert.equal(original.status, 1, "the negative control must reproduce the CSP defect");
    assert.match(original.stderr, /EvalError: Code generation from strings disallowed/);

    const focused = await importWithoutEval(new URL("../../../apps/dispatch/priv/static/vendor/cesium/index.js", import.meta.url), "engine");
    assert.equal(focused.status, 0, focused.stderr);
    const result = JSON.parse(focused.stdout);
    assert.equal(result.widget, "function");
    assert.ok(!result.exports.includes("Viewer"));
    assert.ok(!result.exports.includes("knockout"));
    assert.equal(result.exports.length, 14);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("build inventory excludes the unused widget/Knockout graph and preserves attribution", async () => {
  const root = new URL("../../../apps/dispatch/priv/static/vendor/cesium/", import.meta.url);
  const manifest = JSON.parse(await readFile(new URL("manifest.json", root), "utf8"));
  assert.equal(manifest.build.entry, "cesium-entry.mjs");
  assert.equal(manifest.build.esbuild, "0.28.2");
  assert.ok(manifest.build.inputs.some(input => input.endsWith("/Widget/CesiumWidget.js")));
  assert.ok(manifest.build.inputs.every(input => !input.includes("@cesium/widgets") && !/knockout/i.test(input)));
  assert.deepEqual(manifest.build.aliases, { meshoptimizer: "meshoptimizer/decoder" });
  assert.deepEqual(manifest.build.inputs.filter(input => input.includes("/meshoptimizer/")), [
    "node_modules/meshoptimizer/meshopt_decoder.mjs"
  ]);
  assert.ok(manifest.files.some(file => file.path === "LICENSE.md"));
  const css = await readFile(new URL("Widgets/widgets.css", root), "utf8");
  assert.match(css, /\.cesium-widget/);
  assert.doesNotMatch(css, /cesium-baseLayerPicker|cesium-animation|cesium-timeline/);
});

test("the browser fixture enforces the exact production controller CSP", async () => {
  const controller = await readFile(new URL("../../../apps/dispatch/lib/dispatch_web/controllers/fleet_map_controller.ex", import.meta.url), "utf8");
  const expression = controller.match(/@csp\s+([\s\S]*?)\n\s*\n/)?.[1];
  assert.ok(expression, "the production CSP literal must be found");
  const quoted = /"(?:[^"\\]|\\.)*"/g;
  assert.equal(expression.replace(quoted, "").replaceAll("<>", "").trim(), "", "evaluate only a literal concatenation");
  const actual = [...expression.matchAll(quoted)].map(match => JSON.parse(match[0])).join("");
  assert.equal(CSP, actual);
  assert.ok(actual.split(";").some(directive => directive.trim() === "script-src 'self' 'wasm-unsafe-eval'"));
  assert.doesNotMatch(actual, /'unsafe-eval'/);
});
