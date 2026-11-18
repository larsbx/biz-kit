import {
  KnowledgeState, categories, externalLink, knowledgeLink, operationsReturnLink,
  renderMarkdown, searchURL, workflowLink, workflowArtifactURL, validateWorkflowResponse,
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
let selectedWorkflow = initial.get("workflow") || null;
let selected = selectedWorkflow ? null : initial.get("doc") || null;
let request = null;
let poll = null;
let signedOut = false;
let logoutPending = false;
let debounce = null;
let focusDocument = !!(selected || selectedWorkflow);

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
  state.document = null;
  $("document-panel").hidden = true;
  $("library-browser").classList.remove("reading");
  for (const id of ["document-body", "document-title", "document-path", "document-category", "document-workflows"]) $(id).replaceChildren();
  $("document-source").removeAttribute("href");
}

function hideWorkflow() {
  state.workflow = null;
  $("workflow-panel").hidden = true;
  $("workflow-title").replaceChildren();
  $("workflow-body").replaceChildren();
  $("library-browser").classList.remove("reading");
}

function hideDetails() { hideDocument(); hideWorkflow(); }

function clear(message) {
  state.clear();
  hideDetails();
  $("workflow-previews").hidden = true;
  $("workflow-list").replaceChildren();
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
  const url = selectedWorkflow ? workflowLink(selectedWorkflow, options) : knowledgeLink(selected, options);
  if (url !== location.pathname + location.search) history[push ? "pushState" : "replaceState"]({}, "", url);
}

function navigate(id, anchor = "") {
  selected = id;
  selectedWorkflow = null;
  focusDocument = true;
  hideDetails();
  setLocation(true);
  if (anchor) history.replaceState({}, "", location.pathname + location.search + anchor);
  refresh();
}

function navigateWorkflow(id) {
  selectedWorkflow = id; selected = null; focusDocument = true;
  hideDetails(); setLocation(true); refresh();
}

function areaButton(label, id, count) {
  const button = el("button", { type: "button", className: `workspace-button${options.area === id ? " active" : ""}` },
    el("span", { className: "workspace-label", textContent: label }),
    el("span", { className: "workspace-count", textContent: String(count) }));
  button.dataset.area = id;
  button.setAttribute("aria-pressed", String(options.area === id));
  button.onclick = () => {
    options.area = id; options.category = ""; options.offset = 0; selected = null; selectedWorkflow = null;
    hideDetails(); setLocation(true); refresh();
  };
  return button;
}

function workflowCard(workflow) {
  const link = el("a", { className: "workflow-preview-card", href: workflowLink(workflow.id, options) },
    el("strong", { textContent: workflow.title }),
    el("span", { textContent: `${workflow.task_count} steps · Version ${workflow.version} · Preview` }));
  link.dataset.workflowId = workflow.id;
  if (selectedWorkflow === workflow.id) link.setAttribute("aria-current", "page");
  link.onclick = (event) => {
    if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault(); navigateWorkflow(workflow.id);
  };
  return link;
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
  const workflows = Array.isArray(state.value.workflows) ? state.value.workflows : [];
  $("workflow-previews").hidden = !workflows.length && state.value.workflows_available !== false;
  $("workflow-list").replaceChildren(...(state.value.workflows_available === false ?
    [empty("Workflow previews are unavailable. Reference documents remain available.")] : workflows.map(workflowCard)));
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
  $("document-workflows").replaceChildren(...(Array.isArray(value.workflows) ? value.workflows.map(workflowCard) : []));
  if (focusDocument) {
    focusDocument = false;
    $("document-title").focus({ preventScroll: true });
    const anchor = location.hash.slice(1);
    let target = null;
    try { target = anchor ? document.getElementById(decodeURIComponent(anchor)) : null; } catch { /* malformed anchor stays inert */ }
    (target || $("document-panel")).scrollIntoView({ block: "start" });
  }
}

function renderWorkflow(value) {
  if (!value) { hideWorkflow(); return; }
  if (value.missing || value.unavailable) {
    hideWorkflow(); $("workflow-panel").hidden = false; $("library-browser").classList.add("reading");
    $("workflow-title").textContent = "Workflow preview unavailable";
    $("workflow-body").replaceChildren(empty(value.unavailable ?
      "This workflow could not be verified. Reference documents remain available." :
      "This workflow is not included in the current snapshot."));
    return;
  }
  validateWorkflowResponse(value, state.value.principal, state.value.catalog.source.revision);
  const workflow = value.workflow;
  if (workflow.id !== selectedWorkflow) throw new Error("The workflow preview is invalid.");
  state.workflow = workflow;
  $("workflow-panel").hidden = false;
  $("library-browser").classList.add("reading");
  $("workflow-title").textContent = workflow.title;
  const names = new Map(workflow.tasks.map(task => [task.id, task.title]));
  const tasks = workflow.tasks.map(task => el("li", { className: "workflow-step" },
    el("h3", { textContent: task.title }),
    task.description ? el("p", { textContent: task.description }) : null,
    el("p", { className: "workflow-dependencies", textContent: task.depends_on.length ?
      `After: ${task.depends_on.map(id => names.get(id) || id).join("; ")}` : "No predecessor steps." }),
    el("strong", { textContent: "Evidence to finish" }),
    el("ul", {}, ...task.definition_of_done.map(criterion => el("li", { textContent: criterion.description })))));
  const sourceNodes = workflow.sources.map(source => {
    const link = el("a", { href: knowledgeLink(source.id, options), textContent: `${source.id} · ${source.title}` });
    link.dataset.knowledgeLink = "true";
    const external = externalLink(source.source_url);
    return el("li", { className: "workflow-source" }, link,
      external ? el("p", {}, el("a", { href: external, target: "_blank", rel: "noopener noreferrer", textContent: "Original source" })) : null,
      el("code", { textContent: `SHA-256 ${source.sha256}` }));
  });
  const adoption = workflow.adoption;
  const fields = [
    ["Manifest repository", adoption.repository], ["Manifest path", adoption.path],
    ["Project", adoption.project_key], ["Roadmap", adoption.roadmap_key], ["Workflow", adoption.workflow_id],
    ["Manifest SHA-256", adoption.manifest_sha256], ["SOP SHA-256", workflow.sop.sha256],
    ["SOP version", workflow.sop.version],
  ];
  const details = el("details", { className: "workflow-provenance" },
    el("summary", { textContent: "Sources and adoption details" }),
    el("p", { textContent: "Pin the manifest repository's full commit before governance adoption." }),
    el("dl", {}, ...fields.flatMap(([label, value]) => [el("dt", { textContent: label }), el("dd", { textContent: String(value ?? "") })])),
    el("h3", { textContent: "Required inputs" }),
    el("dl", {}, ...Object.entries(workflow.required_inputs).flatMap(([name, digest]) =>
      [el("dt", { textContent: name }), el("dd", { textContent: digest })])),
    el("h3", { textContent: "Source documents" }), el("ul", {}, ...sourceNodes));
  const downloads = el("div", { className: "workflow-downloads" },
    el("a", { className: "button", href: workflowArtifactURL(workflow.id, "manifest", adoption.manifest_sha256), textContent: "Download manifest" }),
    el("a", { className: "button", href: workflowArtifactURL(workflow.id, "sop", workflow.sop.sha256), textContent: "Download SOP" }));
  $("workflow-body").replaceChildren(
    el("p", { className: "subtle", textContent: `${workflow.tasks.length} steps · Version ${workflow.version}` }),
    typeof workflow.summary === "string" ? el("p", { textContent: workflow.summary }) : el("span"),
    el("div", { className: "workflow-notice" },
      el("p", { textContent: "This is a draft workflow. Reviewing or downloading it creates no work." }),
      el("p", { textContent: "A governance signer adopts an exact revision for the intended project. An operator creates a run separately." }),
      el("p", { textContent: "Exact source documents and the workflow manifest must be available before a task can start." })),
    downloads, el("h3", { textContent: "Proposed steps" }), el("ol", { className: "workflow-steps" }, ...tasks), details);
  if (focusDocument) {
    focusDocument = false; $("workflow-title").focus({ preventScroll: true });
    $("workflow-panel").scrollIntoView({ block: "start" });
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
    const selectedURL = selectedWorkflow ? `/api/v1/operations/knowledge/workflows/${encodeURIComponent(selectedWorkflow)}` :
      selected ? `/api/v1/operations/knowledge/documents/${encodeURIComponent(selected)}` : null;
    const [catalog, detail] = await Promise.all([
      fetchJSON(searchURL(options), controller),
      selectedURL ? fetchJSON(selectedURL, controller)
        .catch((error) => {
          if (error.status === 404) return { missing: true };
          if (selectedWorkflow && error.status === 503) return { unavailable: true };
          throw error;
        }) : null,
    ]);
    if (!state.accept(generation, catalog)) return;
    renderList();
    if (selectedWorkflow) { hideDocument(); renderWorkflow(detail); }
    else { hideWorkflow(); renderDocument(detail); }
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
  options.offset = 0; selected = null; selectedWorkflow = null;
  hideDetails(); setLocation(); refresh();
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
$("close-document").onclick = $("close-workflow").onclick = () => {
  selected = null; selectedWorkflow = null; hideDetails(); setLocation(true); refresh();
};
const followReference = (event) => {
  const link = event.target.closest("a[data-knowledge-link]");
  if (!link || event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const url = new URL(link.href, location.href);
  if (url.origin !== location.origin || url.pathname !== "/operations/knowledge") return;
  const id = url.searchParams.get("doc");
  if (id && id !== selected) { event.preventDefault(); navigate(id, url.hash); }
};
$("document-body").onclick = $("workflow-body").onclick = followReference;

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
  selectedWorkflow = params.get("workflow"); selected = selectedWorkflow ? null : params.get("doc"); options.query = params.get("query") || "";
  options.area = params.get("area") || ""; options.category = params.get("category") || ""; options.offset = offsetFrom(params);
  $("search").value = options.query; focusDocument = !!(selected || selectedWorkflow); refresh();
});
document.addEventListener("visibilitychange", () => {
  if (document.hidden) { request?.abort(); clearTimeout(debounce); clear("Return to refresh the reference library."); }
  else refresh();
});
window.addEventListener("pagehide", () => { request?.abort(); clearTimeout(debounce); clearInterval(poll); clear("Refresh to browse the reference library."); });
window.addEventListener("pageshow", (event) => { if (event.persisted) { clearInterval(poll); poll = setInterval(refresh, 15_000); refresh(); } });
refresh();
poll = setInterval(refresh, 15_000);
