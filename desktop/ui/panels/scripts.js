// Scripts: discover local .sh/.py scripts and run them with live output.
// A script that declares a dry-run/apply split runs --dry-run explicitly;
// --apply, and any script without the split, goes through ctx.confirm with
// the exact argv shown.

import { listScripts, runScript } from "../lib/api.js";
import { esc, h } from "../lib/dom.js";
import { icon } from "../lib/icons.js";

/**
 * Pure workflow: what pressing a button means.
 * mode: "run" (the primary button) or "apply".
 * Returns { args, confirm } where confirm is null (start immediately) or the
 * ask fields (without run) to pass to ctx.confirm.
 */
export function planRun(s, mode) {
  if (mode === "apply") {
    if (!s.hasApply) throw new Error(`${s.name} has no --apply mode`);
    return {
      args: ["--apply"],
      confirm: {
        title: `Run ${s.name} with --apply?`,
        why: "This makes real changes. The dry run shows exactly what it would do.",
        command: JSON.stringify([s.interpreter, s.path, "--apply"]),
        danger: true,
      },
    };
  }
  if (s.hasApply) return { args: ["--dry-run"], confirm: null };
  return {
    args: [],
    confirm: {
      title: `Run ${s.name}?`,
      why: "This script has no declared dry-run/apply split. Review its process arguments before running it.",
      command: JSON.stringify([s.interpreter, s.path]),
      danger: true,
    },
  };
}

/** Render streamed lines (excluding "done") as HTML; stderr gets class "e". */
export function linesHtml(lines) {
  return lines
    .filter((l) => l.kind !== "done")
    .map((l) => `<div${l.kind === "stderr" ? ' class="e"' : ""}>${esc(l.text)}</div>`)
    .join("");
}

export const doneOf = (lines) => lines.find((l) => l.kind === "done");

export default {
  id: "scripts",
  label: "Scripts",
  hint: "Run with live output",
  icon: "scripts",
  group: "Hosts",
  requiresHosts: true,

  mount(ctx) {
    let scripts = [];
    let sel = null;
    let lines = [];
    let running = false;
    let err = null;
    let alive = true;
    let runId = 0;

    const rescan = h("button", { class: "btn", title: "Rescan", onclick: () => load() });
    rescan.innerHTML = icon("refresh");
    ctx.tools.append(rescan);

    const errEl = h("p", { class: "err" });
    const dirEl = h("div", { class: "mono trunc hint" });
    const cards = h("div", { class: "cards", style: "margin-bottom:16px" });
    const outHead = h("div", { class: "row", style: "margin-bottom:6px" });
    const out = h("pre", { class: "out" });
    const outWrap = h("div", {}, outHead, out);
    ctx.body.append(errEl, dirEl, cards, outWrap);

    function renderMeta() {
      const d = doneOf(lines);
      ctx.setMeta(running ? `${sel?.name} running` : d ? `${sel?.name} exit ${d.code}` : `${scripts.length} scripts`);
    }

    function renderCards() {
      errEl.hidden = !err;
      errEl.textContent = err ?? "";
      dirEl.textContent = ctx.info?.scriptsDir ?? "";
      rescan.disabled = running;
      cards.replaceChildren();
      if (scripts.length === 0) {
        cards.append(h("div", { class: "empty" }, `No .sh or .py scripts in ${ctx.info?.scriptsDir ?? ""}`));
      }
      for (const s of scripts) {
        const row = h("div", { class: "row" },
          h("button", { class: "btn", disabled: running, onclick: () => press(s, "run") }, s.hasApply ? "Dry run" : "Run"),
          s.hasApply ? h("button", { class: "btn danger", disabled: running, onclick: () => press(s, "apply") }, "Apply") : null);
        cards.append(h("div", { class: "card" },
          h("h3", { class: "mono", style: "font-size:.92rem" }, s.name),
          h("div", { class: "sub" }, s.summary || "—"),
          row));
      }
      renderMeta();
    }

    function renderOut() {
      outWrap.hidden = lines.length === 0 && !running;
      const d = doneOf(lines);
      outHead.replaceChildren(
        h("strong", { class: "mono", style: "font-size:.92rem" }, sel?.name ?? ""),
        running ? h("span", { class: "pill warn" }, "running…") : null,
        d ? h("span", { class: "pill " + (d.code === 0 ? "ok" : "bad") }, `exit ${d.code}`) : null,
        h("div", { class: "grow" }),
        h("button", { class: "btn", disabled: running, onclick: () => { lines = []; renderOut(); renderMeta(); } }, "Clear"));
      out.innerHTML = linesHtml(lines);
      out.scrollTop = out.scrollHeight; // follow the tail
    }

    async function load() {
      try { scripts = await listScripts(); err = null; }
      catch (e) { err = String(e); }
      if (alive) renderCards();
    }

    function start(s, args) {
      const id = ++runId;
      sel = s; lines = []; running = true; err = null;
      renderCards(); renderOut();
      runScript(s.path, args, (l) => {
        if (!alive || id !== runId) return;
        lines.push(l);
        if (l.kind === "done") { running = false; renderCards(); }
        renderOut();
      }).catch((e) => {
        if (!alive || id !== runId) return;
        err = String(e); running = false; renderCards(); renderOut();
      });
    }

    function press(s, mode) {
      const plan = planRun(s, mode);
      if (!plan.confirm) return start(s, plan.args);
      ctx.confirm({ ...plan.confirm, run: async () => start(s, plan.args) });
    }

    renderCards(); renderOut();
    load();

    return {
      destroy() { alive = false; rescan.remove(); },
    };
  },
};
