import { test } from "node:test";
import assert from "node:assert/strict";
import { planRun, linesHtml, doneOf } from "./scripts.js";
import { diffClass, diffHtml, canSave, reviewStillCurrent } from "./configs.js";

const script = { path: "/fixture/it's a script.sh", name: "it's a script.sh", summary: "fixture", hasApply: true, interpreter: "bash" };

test("dry run passes --dry-run explicitly and needs no confirmation", () => {
  assert.deepEqual(planRun(script, "run"), { args: ["--dry-run"], confirm: null });
});

test("apply reviews the exact argv", () => {
  const p = planRun(script, "apply");
  assert.deepEqual(p.args, ["--apply"]);
  assert.equal(p.confirm.command, JSON.stringify(["bash", script.path, "--apply"]));
  assert.equal(p.confirm.danger, true);
});

test("script without dry-run contract requires confirmation and runs with no args", () => {
  const p = planRun({ ...script, hasApply: false }, "run");
  assert.deepEqual(p.args, []);
  assert.equal(p.confirm.command, JSON.stringify(["bash", script.path]));
  assert.throws(() => planRun({ ...script, hasApply: false }, "apply"));
});

test("output lines escape text and mark stderr", () => {
  const lines = [{ kind: "stdout", text: "<b>" }, { kind: "stderr", text: "x" }, { kind: "done", code: 2 }];
  assert.equal(linesHtml(lines), '<div>&lt;b&gt;</div><div class="e">x</div>');
  assert.equal(doneOf(lines).code, 2);
});

test("diff line classification", () => {
  assert.equal(diffClass("+++ b/x"), "diff-hdr");
  assert.equal(diffClass("--- a/x"), "diff-hdr");
  assert.equal(diffClass("@@ -1 +1 @@"), "diff-hdr");
  assert.equal(diffClass("+new"), "diff-add");
  assert.equal(diffClass("-old"), "diff-del");
  assert.equal(diffClass(" ctx"), "");
  assert.equal(diffHtml("+<a>\n"), '<div class="diff-add">+&lt;a&gt;</div><div> </div>');
});

test("save only when the reviewed change is still current and writable", () => {
  const file = { host: "h", path: "/p", protected: false };
  const reviewed = { file, expected: "a", content: "b", diff: "d" };
  const st = { open: file, orig: "a", text: "b", reviewed };
  assert.equal(canSave(st), true);
  assert.equal(canSave({ ...st, text: "c" }), false);
  assert.equal(canSave({ ...st, orig: "z" }), false);
  assert.equal(canSave({ ...st, open: { ...file } }), false);
  assert.equal(canSave({ ...st, open: { ...file, protected: true }, reviewed: { ...reviewed, file: undefined } }), false);
  assert.equal(canSave({ ...st, reviewed: null }), false);
  assert.equal(reviewStillCurrent(st, file, "b", "a"), true);
  assert.equal(reviewStillCurrent(st, file, "c", "a"), false);
});
