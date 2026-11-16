// Configs: browse matching files per host, edit, review the exact diff, and
// save only if the file still matches the version that was opened (the
// backend checks `expected`). Protected paths are read-only.

import { listConfigs, readConfig, diffConfig, writeConfig } from "../lib/api.js";
import { esc, h } from "../lib/dom.js";
import { icon } from "../lib/icons.js";

/** CSS class for one line of a unified diff, or "" for context. */
export function diffClass(l) {
  if (l.startsWith("+++") || l.startsWith("---") || l.startsWith("@@")) return "diff-hdr";
  if (l.startsWith("+")) return "diff-add";
  if (l.startsWith("-")) return "diff-del";
  return "";
}

export const diffHtml = (diff) =>
  diff.split("\n").map((l) => {
    const c = diffClass(l);
    return `<div${c ? ` class="${c}"` : ""}>${esc(l || " ")}</div>`;
  }).join("");

/**
 * A reviewed change may be saved only when it is for the open, writable file
 * and nothing (editor text or the opened version) moved since the review.
 */
export function canSave(st) {
  const r = st.reviewed;
  return Boolean(r && st.open && !st.open.protected && r.file === st.open && r.content === st.text && r.expected === st.orig);
}

/** A review result applies only if the editor still holds what was diffed. */
export const reviewStillCurrent = (st, file, content, expected) =>
  st.open === file && st.text === content && st.orig === expected;

export default {
  id: "configs",
  label: "Configs",
  hint: "Edit files, diff first",
  icon: "configs",
  group: "Hosts",
  requiresHosts: true,

  mount(ctx) {
    const hosts = ctx.info?.hosts ?? [];
    const st = { host: hosts[0]?.name ?? "", items: [], open: null, orig: "", text: "", diff: null, reviewed: null, busy: false, err: null };
    let alive = true;
    let loadSeq = 0;
    const dirty = () => st.open !== null && st.text !== st.orig;

    const hostSel = h("select", { onchange: () => discardOk().then((ok) => { if (ok) { st.host = hostSel.value; load(); } else hostSel.value = st.host; }) },
      hosts.map((x) => h("option", { value: x.name }, x.name)));
    hostSel.value = st.host;
    const refresh = h("button", { class: "btn", title: "Refresh", onclick: () => discardOk().then((ok) => ok && load()) });
    refresh.innerHTML = icon("refresh");
    ctx.tools.append(hostSel, refresh);

    const errEl = h("p", { class: "err" });
    const view = h("div");
    ctx.body.append(errEl, view);

    const editor = h("textarea", { class: "editor", spellcheck: false });
    editor.addEventListener("input", () => {
      st.text = editor.value;
      renderBar();
    });
    const bar = h("div", { class: "row", style: "margin-bottom:8px" });

    // Leaving an edited file asks first; the shell runs ask.run only on yes.
    async function discardOk() {
      if (!dirty()) return true;
      return ctx.confirm({
        title: `Discard unsaved edits to ${st.open.path}?`,
        why: "Your changes have not been saved and will be lost.",
        command: `${st.open.host}:${st.open.path}`,
        host: st.open.host,
        danger: true,
        action: "Discard",
        run: async () => {},
      });
    }

    function setMeta() {
      ctx.setMeta(st.open ? `${st.open.host}:${st.open.path}${dirty() ? " · unsaved" : ""}` : `${st.items.length} files on ${st.host}`);
    }

    function renderBar() {
      const o = st.open;
      bar.replaceChildren(
        h("span", { class: "mono trunc grow", style: "color:var(--muted)" }, `${o.host}:${o.path}`),
        o.protected ? h("span", { class: "pill" }, "read-only") : null,
        dirty() ? h("span", { class: "pill warn" }, "unsaved") : null,
        h("button", { class: "btn", disabled: st.busy || !dirty(), onclick: review }, "Review diff"),
        h("button", { class: "btn danger", disabled: st.busy || !dirty() || !canSave(st), onclick: save }, "Save…"),
        h("button", { class: "btn", disabled: st.busy, onclick: () => discardOk().then((ok) => { if (ok) { closeFile(); render(); } }) }, "Close"));
      setMeta();
    }

    function closeFile() { st.open = null; st.diff = null; st.reviewed = null; st.orig = st.text = ""; }

    function render() {
      if (!alive) return;
      errEl.hidden = !st.err;
      errEl.textContent = st.err ?? "";
      refresh.disabled = st.busy;
      hostSel.disabled = st.busy;
      if (!st.open) {
        const rows = st.items.map((c) => h("tr", { style: "cursor:pointer", onclick: () => openFile(c) },
          h("td", {}, c.label, " ", c.protected ? h("span", { class: "pill" }, "read-only") : null),
          h("td", { class: "mono trunc", style: "max-width:36rem" }, c.path),
          h("td", { style: "color:var(--muted)" }, String(c.size))));
        view.replaceChildren(
          h("table", {}, h("thead", {}, h("tr", {}, h("th", {}, "Type"), h("th", {}, "Path"), h("th", { style: "width:6rem" }, "Size"))), h("tbody", {}, rows)),
          !st.busy && st.items.length === 0
            ? h("div", { class: "empty" }, `No matching files on ${st.host}. Patterns are set under `, h("code", { class: "mono" }, "configs"), ` in ${ctx.info?.configPath ?? ""}`)
            : null);
        setMeta();
        return;
      }
      renderBar();
      if (st.diff !== null) {
        const pre = h("pre", { class: "out", html: diffHtml(st.diff) });
        view.replaceChildren(bar,
          h("div", { class: "row", style: "margin-bottom:6px" },
            h("strong", {}, "Pending change"), h("div", { class: "grow" }),
            h("button", { class: "btn", onclick: () => { st.diff = null; render(); } }, "Back to editor")),
          pre);
      } else {
        editor.readOnly = Boolean(st.open.protected);
        if (editor.value !== st.text) editor.value = st.text;
        view.replaceChildren(bar, editor);
      }
    }

    async function load() {
      if (!st.host) return render();
      const seq = ++loadSeq;
      st.busy = true; st.err = null; closeFile(); render();
      try { const items = await listConfigs(st.host); if (seq === loadSeq) st.items = items; }
      catch (e) { if (seq === loadSeq) { st.err = String(e); st.items = []; } }
      finally { if (seq === loadSeq) { st.busy = false; render(); } }
    }

    async function openFile(c) {
      st.busy = true; st.err = null; st.diff = null; st.reviewed = null; render();
      try {
        const s = await readConfig(c.host, c.path);
        st.orig = s; st.text = s; st.open = c;
      } catch (e) { st.err = String(e); }
      finally { st.busy = false; render(); }
    }

    async function review() {
      if (!st.open) return;
      st.busy = true; st.err = null;
      const file = st.open, expected = st.orig, content = st.text;
      st.reviewed = null; renderBar();
      try {
        const result = await diffConfig(file.host, file.path, content, expected);
        if (reviewStillCurrent(st, file, content, expected)) {
          st.diff = result;
          st.reviewed = { file, expected, content, diff: result };
        }
      } catch (e) { st.err = String(e); }
      finally { st.busy = false; render(); }
    }

    function save() {
      if (!canSave(st)) return;
      const change = st.reviewed;
      const { file } = change;
      ctx.confirm({
        title: `Save reviewed changes to ${file.path}?`,
        why: "The file must still match the version you opened. A backup is preserved before replacement.",
        command: change.diff,
        host: file.host,
        danger: true,
        run: async () => {
          await writeConfig(file.host, file.path, change.content, change.expected);
          st.orig = change.content;
          st.diff = null;
          st.reviewed = null;
          await load();
        },
      });
    }

    load();

    return {
      destroy() { alive = false; loadSeq++; hostSel.remove(); refresh.remove(); },
    };
  },
};
