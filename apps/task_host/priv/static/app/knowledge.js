import {
  KnowledgeState, categories, externalLink, knowledgeLink, operationsReturnLink,
  renderMarkdown, searchURL,
} from "./knowledge-view.js";

const $ = (id) => document.getElementById(id);
const state = new KnowledgeState();
const initial = new URLSearchParams(location.search);
const provider = initial.get("provider") || "workos";
const back = initial.get("back") || "";
const offsetFrom = (params) => {
  const value = Number(params.get("offset") || 0);
  return Number.isInteger(value) && value >= 0 && value <= 1000 ? value : 0;
};
const options = {
  provider, back, query: initial.get("query") || "", area: initial.get("area") || "",
  category: initial.get("category") || "", offset: offsetFrom(initial), limit: 40,
};
let selected = initial.get("doc") || null;
let request = null;
let poll = null;
let signedOut = false;
let logoutPending = false;
let debounce = null;
let focusDocument = !!selected;

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  Object.assign(node, attrs);
  node.append(...children.filter((child) => child !== null));
  return node;
}

function status(message, error = false) {
  $("status").textContent = message;
  $("status").className = error ? "error" : "";
}

function empty(message) {
  return el("div", { className: "empty" }, el("p", { textContent: message }));
}

function hideDocument() {
  $("document-panel").hidden = true;
  $("library-browser").classList.remove("reading");
  for (const id of ["document-body", "document-title", "document-path", "document-category"]) $(id).replaceChildren();
  $("document-source").removeAttribute("href");
}

function clear(message) {
  state.clear();
  hideDocument();
  $("area-list").replaceChildren();
  $("document-list").replaceChildren(empty(message));
  $("category-filter").replaceChildren(el("option", { value: "", textContent: "All categories" }));
  $("result-count").textContent = "";
  $("page-label").textContent = "";
  $("source-revision").hidden = true;
  $("source-revision").removeAttribute("href");
  $("source-revision").textContent = "";
  $("previous").disabled = true;
  $("next").disabled = true;
  $("document-list").setAttribute("aria-busy", "false");
}

function setLocation(push = false) {
  const url = knowledgeLink(selected, options);
  if (url !== location.pathname + location.search) history[push ? "pushState" : "replaceState"]({}, "", url);
}

function navigate(id, anchor = "") {
  selected = id;
  focusDocument = true;
  hideDocument();
  setLocation(true);
  if (anchor) history.replaceState({}, "", location.pathname + location.search + anchor);
  refresh();
}

function areaButton(label, id, count) {
  const button = el("button", { type: "button", className: `workspace-button${options.area === id ? " active" : ""}` },
    el("span", { className: "workspace-label", textContent: label }),
    el("span", { className: "workspace-count", textContent: String(count) }));
  button.dataset.area = id;
  button.setAttribute("aria-pressed", String(options.area === id));
  button.onclick = () => {
    options.area = id; options.category = ""; options.offset = 0; selected = null;
    hideDocument(); setLocation(true); refresh();
  };
  return button;
}

function documentCard(doc) {
  const link = el("a", { className: "document-card", href: knowledgeLink(doc.id, options) },
    el("span", { className: "eyebrow", textContent: doc.category || doc.area || "REFERENCE" }),
    el("h3", { textContent: doc.jd_id ? `${doc.jd_id} · ${doc.title}` : doc.title }),
    doc.snippet ? el("p", { textContent: doc.snippet }) : null);
  link.dataset.documentId = doc.id;
  if (selected === doc.id) link.setAttribute("aria-current", "page");
  link.onclick = (event) => {
    if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault(); navigate(doc.id);
  };
  return link;
}

function renderList() {
  const { catalog, results } = state.value;
  $("area-list").replaceChildren(areaButton("All areas", "", catalog.total),
    ...catalog.areas.map((area) => areaButton(area.name, area.id, area.count)));
  const names = categories(catalog.areas, options.area);
  $("category-filter").replaceChildren(el("option", { value: "", textContent: "All categories" }),
    ...names.map((name) => el("option", { value: name, textContent: name })));
  $("category-filter").value = options.category;
  $("list-title").textContent = options.query ? "Search results" : "Documents";
  $("result-count").textContent = `${results.total} documents`;
  $("document-list").replaceChildren(...(results.documents.length ? results.documents.map(documentCard) :
    [empty("No matching documents. Try another area, category, or search.")]));
  $("document-list").setAttribute("aria-busy", "false");
  $("previous").disabled = results.offset === 0;
  $("next").disabled = results.offset + results.limit >= results.total;
  $("page-label").textContent = results.total ?
    `${results.offset + 1}–${Math.min(results.offset + results.documents.length, results.total)} of ${results.total}` : "";
  const source = catalog.source;
  const sourceURL = externalLink(`https://github.com/${source.repository}/tree/${source.revision}`);
  $("source-revision").textContent = `${source.repository} · ${source.revision.slice(0, 12)}`;
  $("source-revision").hidden = !sourceURL;
  if (sourceURL) $("source-revision").href = sourceURL;
}

function renderDocument(value) {
  if (!value) { hideDocument(); return; }
  if (value.missing) {
    hideDocument();
    $("document-panel").hidden = false;
    $("library-browser").classList.add("reading");
    $("document-title").textContent = "Document unavailable";
    $("document-source").hidden = true;
    $("document-body").replaceChildren(empty("This document is not included in this snapshot. Choose another reference."));
    return;
  }
  const doc = value.document;
  if (value.schema_version !== 1 || value.read_only !== true || value.principal !== state.value.principal ||
      value.source?.revision !== state.value.catalog.source.revision || doc?.id !== selected ||
      typeof doc.body !== "string" || !Array.isArray(doc.links)) throw new Error("The document response is invalid.");
  state.document = doc;
  $("document-panel").hidden = false;
  $("library-browser").classList.add("reading");
  $("document-title").textContent = doc.jd_id ? `${doc.jd_id} · ${doc.title}` : doc.title;
  $("document-category").textContent = doc.category || doc.area || "REFERENCE";
  $("document-path").textContent = doc.path;
  const href = externalLink(doc.source_url);
  $("document-source").hidden = !href;
  if (href) $("document-source").href = href;
  else $("document-source").removeAttribute("href");
  renderMarkdown($("document-body"), doc.body, { ...options, links: doc.links });
  if (focusDocument) {
    focusDocument = false;
    $("document-title").focus({ preventScroll: true });
    const anchor = location.hash.slice(1);
    let target = null;
    try { target = anchor ? document.getElementById(decodeURIComponent(anchor)) : null; } catch { /* malformed anchor stays inert */ }
    (target || $("document-panel")).scrollIntoView({ block: "start" });
  }
}

async function fetchJSON(url, controller) {
  const response = await fetch(url, { credentials: "same-origin", cache: "no-store", signal: controller.signal,
    headers: { accept: "application/json" } });
  if (!response.ok) {
    const error = new Error(response.status === 401 ? "Sign in to browse the reference library." :
      response.status === 403 ? "Access to an Operations workspace is required." :
      response.status === 400 ? "Use a shorter search and try again." :
      response.status === 404 ? "This document is not included in this snapshot." : "The reference library is unavailable. Try Refresh.");
    error.status = response.status; throw error;
  }
  return response.json();
}

async function refresh() {
  if (document.hidden || signedOut || logoutPending) return;
  request?.abort();
  const controller = new AbortController(); request = controller;
  const generation = state.begin();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  $("refresh").disabled = true;
  $("document-list").setAttribute("aria-busy", "true");
  try {
    const [catalog, detail] = await Promise.all([
      fetchJSON(searchURL(options), controller),
      selected ? fetchJSON(`/api/v1/operations/knowledge/documents/${encodeURIComponent(selected)}`, controller)
        .catch((error) => { if (error.status === 404) return { missing: true }; throw error; }) : null,
    ]);
    if (!state.accept(generation, catalog)) return;
    renderList(); renderDocument(detail);
    $("sign-in").hidden = true; $("sign-out").hidden = false;
    status(`Source ${catalog.catalog.source.revision.slice(0, 12)} · ${catalog.catalog.total} documents`);
  } catch (error) {
    if (!state.current(generation)) return;
    clear(error.name === "AbortError" ? "The connection timed out. Try Refresh." : error.message);
    status(error.status === 401 ? "Sign in to continue" : error.message, error.status !== 401);
    if (error.status === 401) { $("sign-in").hidden = false; $("sign-out").hidden = true; }
    else if (error.status === 403) { $("sign-in").hidden = true; $("sign-out").hidden = false; }
  } finally {
    clearTimeout(timeout);
    if (request === controller) { request = null; $("refresh").disabled = logoutPending; }
  }
}

function search() {
  clearTimeout(debounce);
  options.query = $("search").value;
  options.offset = 0; selected = null;
  hideDocument(); setLocation(); refresh();
}

$("search").value = options.query;
$("operations-home").href = $("back-to-operations").href = operationsReturnLink(back, provider);
$("sign-in").href = `/auth/${encodeURIComponent(provider)}/login`;
$("search-form").onsubmit = (event) => { event.preventDefault(); search(); };
$("search").oninput = () => { clearTimeout(debounce); debounce = setTimeout(search, 300); };
$("category-filter").onchange = () => { options.category = $("category-filter").value; search(); };
$("previous").onclick = () => { options.offset = Math.max(0, options.offset - options.limit); setLocation(); refresh(); };
$("next").onclick = () => { options.offset += options.limit; setLocation(); refresh(); };
$("refresh").onclick = () => { if (!logoutPending) { signedOut = false; refresh(); } };
$("close-document").onclick = () => { selected = null; hideDocument(); setLocation(true); refresh(); };
$("document-body").onclick = (event) => {
  const link = event.target.closest("a[data-knowledge-link]");
  if (!link || event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const url = new URL(link.href, location.href);
  if (url.origin !== location.origin || url.pathname !== "/operations/knowledge") return;
  const id = url.searchParams.get("doc");
  if (id && id !== selected) { event.preventDefault(); navigate(id, url.hash); }
};

$("sign-out").onclick = async () => {
  if (logoutPending) return;
  logoutPending = true; signedOut = true; request?.abort(); clearTimeout(debounce);
  $("refresh").disabled = true;
  clear("Signed out. Sign in to browse the reference library.");
  $("sign-in").hidden = false; $("sign-out").hidden = true; status("Signing out…");
  try {
    const response = await fetch("/auth/logout", { method: "POST", credentials: "same-origin", cache: "no-store" });
    if (!response.ok) throw new Error("Logout failed");
    status("Signed out");
  } catch { status("Could not end your session. Try Sign out again.", true); $("sign-out").hidden = false; }
  finally { logoutPending = false; $("refresh").disabled = false; }
};

window.addEventListener("popstate", () => {
  const params = new URLSearchParams(location.search);
  selected = params.get("doc"); options.query = params.get("query") || "";
  options.area = params.get("area") || ""; options.category = params.get("category") || ""; options.offset = offsetFrom(params);
  $("search").value = options.query; focusDocument = !!selected; refresh();
});
document.addEventListener("visibilitychange", () => {
  if (document.hidden) { request?.abort(); clearTimeout(debounce); clear("Return to refresh the reference library."); }
  else refresh();
});
window.addEventListener("pagehide", () => { request?.abort(); clearTimeout(debounce); clearInterval(poll); clear("Refresh to browse the reference library."); });
window.addEventListener("pageshow", (event) => { if (event.persisted) { clearInterval(poll); poll = setInterval(refresh, 15_000); refresh(); } });
refresh();
poll = setInterval(refresh, 15_000);
