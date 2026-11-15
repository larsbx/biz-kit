import { workViews } from "./operations-tiles.js";
import {
  SnapshotState,
  taskRows,
  selectRows,
  metrics,
  lifecycleLabel,
  projectLink,
  timingLabel,
  workflowRows,
} from "./operations-view.js";
import { KnowledgeSuggestions, projectKnowledgeLink } from "./project-knowledge.js";

const $ = (id) => document.getElementById(id);
const state = new SnapshotState();
const params = new URLSearchParams(location.search);
const provider = params.get("provider") || "workos";
const options = {
  workspace: params.get("workspace") || "",
  category: params.get("category") || "",
  query: params.get("q") || "",
  tab: ["today", "upcoming", "all", "review", "unscheduled", "completed", "workflows"].includes(params.get("tab")) ? params.get("tab") : "today",
};
$("search").value = options.query;
let request = null;
let poll = null;
let signedOut = false;
let logoutPending = false;
let previousPrincipal = null;
let lastUpdated = null;
let unavailable = "Connecting to your workspaces…";
const knowledgeSuggestions = new KnowledgeSuggestions({ principal: () => state.value?.principal, provider });

const tabs = {
  today: [
    "Today",
    "A clear view of the work that needs your attention.",
    "Today’s work",
  ],
  upcoming: [
    "Upcoming",
    "Scheduled work and deadlines in the next seven days.",
    "Next seven days",
  ],
  all: [
    "All work",
    "Everything still open across your selected workspaces.",
    "Active work",
  ],
  review: [
    "Review",
    "Submitted evidence waiting for a review. Open the task to see your available actions.",
    "Awaiting evidence review",
  ],
  unscheduled: [
    "Unscheduled",
    "Active work without a schedule or due date.",
    "Work to plan",
  ],
  completed: [
    "Closed work",
    "Completed and cancelled tasks, with their recorded lifecycle states.",
    "Closed work",
  ],
  workflows: [
    "Workflows",
    "Reusable workflows available in your projects. Open a project to start a run.",
    "Workflow templates",
  ],
};

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  Object.assign(node, attrs);
  node.append(
    ...children.filter((child) => child !== null && child !== undefined),
  );
  return node;
}

function setStatus(message, error = false) {
  $("status").textContent = message;
  $("status").className = error ? "error" : "";
}

function empty(title, detail) {
  return el(
    "div",
    { className: "empty" },
    el("h3", { textContent: title }),
    el("p", { textContent: detail }),
  );
}

function resetFilters() {
  options.workspace = "";
  options.category = "";
  options.query = "";
  $("search").value = "";
}

function clear(message) {
  knowledgeSuggestions.clear(message);
  state.clear();
  lastUpdated = null;
  unavailable = message;
  $("settings-content").replaceChildren();
  if ($("settings-dialog").open) $("settings-dialog").close();
  render();
}

function workspaceButton(label, id, count) {
  const button = el(
    "button",
    {
      type: "button",
      className: `workspace-button${options.workspace === id ? " active" : ""}`,
    },
    el("span", { className: "workspace-dot", ariaHidden: "true" }),
    el("span", { className: "workspace-label", textContent: label }),
    el("span", { className: "workspace-count", textContent: String(count) }),
  );
  button.dataset.workspace = id;
  button.setAttribute("aria-pressed", String(options.workspace === id));
  button.onclick = () => {
    options.workspace = id;
    render();
  };
  return button;
}

function card(row, timeZone) {
  const { task, workspace } = row;
  const badges = [
    el("span", {
      className: `badge${task.state === "in_progress" ? " progress" : ""}`,
      textContent: lifecycleLabel(task.state),
    }),
  ];
  if (row.timing.overdue)
    badges.push(
      el("span", { className: "badge warning", textContent: "Past due" }),
    );
  const todos = Array.isArray(task.todos) ? task.todos : [];
  const open = todos.filter((todo) => todo.state === "open").length;
  const done = todos.filter((todo) => todo.state === "done").length;
  const node = el(
    "article",
    { className: "task-card" },
    el(
      "div",
      {},
      el(
        "div",
        { className: "task-meta" },
        el("span", {
          className: "workspace-tag",
          textContent: workspace.label,
        }),
        el("span", { textContent: workspace.category }),
      ),
      el(
        "div",
        { className: "task-title-line" },
        el("h3", { textContent: task.title || row.id }),
        ...badges,
      ),
      task.description
        ? el("p", {
            className: "task-description",
            textContent: task.description,
          })
        : null,
      el("div", {
        className: "timing",
        textContent: timingLabel(row, timeZone),
      }),
      row.stage
        ? el("div", { className: "stage", textContent: row.stage })
        : null,
      todos.length
        ? el("div", {
            className: "stage",
            textContent: `${done} checklist items complete · ${open} open`,
          })
        : null,
    ),
    el("a", {
      className: "button",
      href: projectLink(workspace, { taskId: row.id, provider }),
      textContent: "Open task",
    }),
    knowledgeSuggestions.disclosure(workspace, { task_id: row.id }),
  );
  node.dataset.taskKey = row.key;
  return node;
}

function workflowCard(row) {
  const steps = Array.isArray(row.workflow.definitions)
    ? row.workflow.definitions.length
    : 0;
  return el(
    "article",
    { className: "task-card" },
    el(
      "div",
      {},
      el(
        "div",
        { className: "task-meta" },
        el("span", {
          className: "workspace-tag",
          textContent: row.workspace.label,
        }),
        el("span", { textContent: row.workspace.category }),
      ),
      el("h3", { textContent: row.workflow.name || row.id }),
      el("p", {
        className: "task-description",
        textContent: `${steps} steps · ${row.workflow.roadmap_name || "Workflow"}`,
      }),
    ),
    el("a", {
      className: "button",
      href: projectLink(row.workspace, {
        provider,
        section: "workflow-heading",
      }),
      textContent: "Open workflow",
    }),
    knowledgeSuggestions.disclosure(row.workspace, { roadmap_key: row.workflow.roadmap_key, workflow_id: row.workflow.workflow_id }),
  );
}

function viewNodes(snapshot, tab, rows = taskRows(snapshot)) {
  let nodes;
  if (tab === "workflows") {
    const query = options.query.trim().toLocaleLowerCase();
    const workflows = workflowRows(
      snapshot,
      options.workspace,
      options.category,
    ).filter(
      (r) =>
        !query ||
        [r.workflow.name, r.workflow.roadmap_name, r.workspace.label].some(
          (v) =>
            String(v ?? "")
              .toLocaleLowerCase()
              .includes(query),
        ),
    );
    nodes = workflows.map(workflowCard);
  } else
    nodes = selectRows(rows, { ...options, tab }).map((row) =>
      card(row, snapshot.time_zone),
    );

  return nodes;
}

function renderWorkViews(snapshot) {
  for (const [tab, node] of workViews) {
    const nodes = snapshot ? viewNodes(snapshot, tab) : [];
    node.replaceChildren(...(nodes.length ? nodes : [empty(
      snapshot ? "Nothing in this view" : "Your work will appear here",
      snapshot ? "Choose another workspace or change your search." : unavailable,
    )]));
  }
}

function render() {
  knowledgeSuggestions.beginRender();
  const navigation = new URLSearchParams({ provider });
  for (const [key, value] of [["workspace", options.workspace], ["category", options.category], ["q", options.query], ["tab", options.tab]]) {
    if (value) navigation.set(key, value);
  }
  $("knowledge-link").href = `/operations/knowledge?${new URLSearchParams({ provider, back: navigation.toString() })}`;
  const snapshot = state.value;
  const [title, description, heading] = tabs[options.tab];
  $("view-title").textContent = title;
  $("view-description").textContent = description;
  $("list-title").textContent = heading;
  for (const button of $("view-tabs").querySelectorAll("button")) {
    if (button.dataset.tab === options.tab)
      button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  }
  $("task-list").setAttribute("aria-busy", "false");
  if (!snapshot) {
    renderWorkViews(null);
    $("operations-title").textContent = "Operations";
    document.title = "Operations · Biz-kit";
    $("workspace-list").replaceChildren();
    $("workspace-actions").replaceChildren();
    $("category-filter").replaceChildren(
      el("option", { value: "", textContent: "All categories" }),
    );
    $("task-list").replaceChildren(
      empty("Your work will appear here", unavailable),
    );
    $("result-count").textContent = "";
    $("date-label").textContent = "YOUR DAY, IN ONE PLACE";
    $("time-zone").textContent = "";
    for (const id of ["today", "overdue", "review"])
      $(`metric-${id}`).textContent = "—";
    knowledgeSuggestions.endRender();
    return;
  }

  if (!snapshot.workspaces.some((w) => w.id === options.workspace))
    options.workspace = "";
  const categories = [
    ...new Set(snapshot.workspaces.map((w) => w.category)),
  ].sort();
  if (!categories.includes(options.category)) options.category = "";
  $("category-filter").replaceChildren(
    el("option", { value: "", textContent: "All categories" }),
    ...categories.map((category) =>
      el("option", { value: category, textContent: category }),
    ),
  );
  $("category-filter").value = options.category;
  $("operations-title").textContent = snapshot.title;
  document.title = `${snapshot.title} · Biz-kit`;
  $("date-label").textContent = new Intl.DateTimeFormat(undefined, {
    timeZone: snapshot.time_zone,
    weekday: "long",
    month: "long",
    day: "numeric",
  }).format(Date.now());
  $("time-zone").textContent = snapshot.time_zone;
  renderWorkViews(snapshot);
  const rows = taskRows(snapshot);
  $("workspace-list").replaceChildren(
    workspaceButton("All workspaces", "", metrics(rows).active),
    ...snapshot.workspaces.map((w) =>
      workspaceButton(
        w.label,
        w.id,
        metrics(rows.filter((r) => r.workspace.id === w.id)).active,
      ),
    ),
  );

  const scoped = rows.filter(
    (r) =>
      (!options.workspace || r.workspace.id === options.workspace) &&
      (!options.category || r.workspace.category === options.category),
  );
  const counts = metrics(scoped);
  for (const id of ["today", "overdue", "review"])
    $(`metric-${id}`).textContent = String(counts[id]);
  const nodes = viewNodes(snapshot, options.tab, rows);

  $("result-count").textContent =
    `${nodes.length} ${options.tab === "workflows" ? "workflows" : "tasks"}`;
  if (!snapshot.workspaces.length) {
    $("task-list").replaceChildren(
      empty(
        "No workspaces available",
        "Your administrator can connect existing projects to this view and grant you the appropriate access.",
      ),
    );
  } else if (!nodes.length) {
    const detail = options.query
      ? "Try a different search or select another workspace."
      : options.tab === "today"
        ? "Nothing is due, scheduled, or in progress today. Open All work to see other active tasks."
        : options.tab === "workflows"
          ? "Workflows appear here after a project adopts a blueprint. Open its project to manage available workflows."
          : "There is no work matching this view. Choose another view or workspace.";
    $("task-list").replaceChildren(empty("Nothing in this view", detail));
  } else $("task-list").replaceChildren(...nodes);

  $("workspace-actions").replaceChildren(
    ...snapshot.workspaces
      .filter(
        (w) =>
          (!options.workspace || w.id === options.workspace) &&
          (!options.category || w.category === options.category),
      )
      .map((w) =>
        el(
          "div",
          { className: "workspace-card" },
          el("h3", { textContent: w.label }),
          el("p", {
            textContent:
              "Open this project to manage tasks, checklists, and workflow runs.",
          }),
          el("a", {
            href: projectLink(w, { provider }),
            textContent: "Open workspace →",
          }),
          w.knowledge ? el("p", { className: "workspace-knowledge" },
            el("a", {
              href: projectKnowledgeLink(w, { provider }),
              textContent: `Project knowledge: ${w.knowledge.pending_count} pending approval · ${w.knowledge.approved_count} approved`,
            })) : null,
          w.has_infrastructure_review === true
            ? el(
                "p",
                {},
                el("a", {
                  href: `/operations/workspaces/${encodeURIComponent(w.id)}/infrastructure-review`,
                  textContent: "Review infrastructure evidence",
                }),
              )
            : null,
        ),
      ),
  );
  knowledgeSuggestions.endRender();
}

async function refresh() {
  if (document.hidden || signedOut || logoutPending) return;
  request?.abort();
  const controller = new AbortController();
  request = controller;
  const generation = state.begin();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  $("refresh").disabled = true;
  try {
    const response = await fetch("/api/v1/operations", {
      credentials: "same-origin",
      cache: "no-store",
      signal: controller.signal,
      headers: { accept: "application/json" },
    });
    if (!state.current(generation)) return;
    if (response.status === 401) {
      clear("Sign in to see the projects you can access.");
      $("sign-in").hidden = false;
      $("sign-out").hidden = true;
      $("session-label").textContent = "";
      setStatus("Sign in to continue");
      return;
    }
    if (!response.ok)
      throw new Error(
        response.status === 503
          ? "The operations configuration is unavailable. Ask your administrator to check it."
          : "Could not refresh your workspaces. Try Refresh again.",
      );
    const value = await response.json();
    if (!state.accept(generation, value)) return;
    if (previousPrincipal !== null && previousPrincipal !== value.principal) {
      resetFilters(); knowledgeSuggestions.clear();
    }
    previousPrincipal = value.principal;
    lastUpdated = Date.now();
    $("sign-in").hidden = true;
    $("sign-out").hidden = false;
    $("session-label").textContent = "Signed in";
    setStatus(
      `Updated ${new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit", second: "2-digit" }).format(lastUpdated)}`,
    );
    render();
    knowledgeSuggestions.refreshOpen();
    if ($("settings-dialog").open) renderSettings();
  } catch (error) {
    if (!state.current(generation)) return;
    const message =
      error.name === "AbortError"
        ? "The refresh timed out. Your work will reload when the connection returns."
        : error.message;
    clear(message);
    setStatus("Workspaces unavailable · retrying", true);
  } finally {
    clearTimeout(timeout);
    if (request === controller) {
      request = null;
      $("refresh").disabled = logoutPending;
    }
  }
}

function renderSettings() {
  const snapshot = state.value;
  $("settings-content").replaceChildren(
    ...(snapshot
      ? [
          el("p", { textContent: `Display timezone: ${snapshot.time_zone}` }),
          ...snapshot.workspaces.map((w) =>
            el(
              "div",
              { className: "setting-row" },
              el("strong", { textContent: w.label }),
              el("p", { textContent: w.category }),
              el("code", {
                textContent: `${w.chapter_id} / ${w.tenant_id} / ${w.project_id}`,
              }),
            ),
          ),
        ]
      : [
          el("p", {
            textContent:
              "Sign in and refresh to see your available workspace settings.",
          }),
        ]),
  );
}

$("sign-in").href = `/auth/${encodeURIComponent(provider)}/login`;
$("refresh").onclick = () => {
  if (!logoutPending) {
    signedOut = false;
    refresh();
  }
};
$("search").oninput = () => {
  options.query = $("search").value;
  render();
};
$("category-filter").onchange = () => {
  options.category = $("category-filter").value;
  render();
};
$("view-tabs").onclick = (event) => {
  const button = event.target.closest("button[data-tab]");
  if (button && Object.hasOwn(tabs, button.dataset.tab)) {
    options.tab = button.dataset.tab;
    render();
  }
};
$("settings").onclick = () => {
  renderSettings();
  $("settings-dialog").showModal();
};
$("settings-top").onclick = $("settings").onclick;
$("close-settings").onclick = () => $("settings-dialog").close();
$("sign-out").onclick = async () => {
  if (logoutPending) return;
  logoutPending = true;
  $("refresh").disabled = true;
  signedOut = true;
  request?.abort();
  clear("Signed out. Sign in when you are ready to return.");
  resetFilters();
  previousPrincipal = null;
  $("sign-out").hidden = true;
  $("sign-in").hidden = false;
  $("session-label").textContent = "";
  setStatus("Signing out…");
  try {
    const result = await fetch("/auth/logout", {
      method: "POST",
      credentials: "same-origin",
      cache: "no-store",
    });
    if (!result.ok) throw new Error("Logout failed");
    clear("Signed out. Sign in when you are ready to return.");
    setStatus("Signed out");
  } catch {
    setStatus("Could not end your session. Try Sign out again.", true);
    $("sign-out").hidden = false;
  } finally {
    logoutPending = false;
    $("refresh").disabled = false;
  }
};

document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    request?.abort();
    clear("Return to this page to refresh your workspaces.");
  } else refresh();
});
window.addEventListener("pagehide", () => {
  request?.abort();
  clearInterval(poll);
  clear("Refresh to reconnect to your workspaces.");
});
window.addEventListener("pageshow", (event) => {
  if (event.persisted) {
    clearInterval(poll);
    poll = setInterval(refresh, 15_000);
    refresh();
  }
});
render();
refresh();
poll = setInterval(refresh, 15_000);
