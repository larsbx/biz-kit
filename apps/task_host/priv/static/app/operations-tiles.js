import { mountTiles } from "./tiles.js";
import { leaf, split } from "./layout.js";

const $ = (selector) => document.querySelector(selector);
const source = $(".shell");
const host = document.createElement("div");
host.id = "main";
host.tabIndex = -1;
host.setAttribute("role", "main");
$("#main").id = "operations-source";
source.before(host);
const sections = [
  ["workspaces", "Workspaces", $(".sidebar")],
  ["session", "Workspace & session", $(".topbar")],
  // Extract nested sections before mounting their original parents.
  ["status", "Connection status", $(".status-box")],
  ["overview", "View overview", $(".page-heading")],
  ["today", "On your radar today", $("#metric-today").parentElement],
  ["overdue", "Past due", $("#metric-overdue").parentElement],
  ["review", "Awaiting review", $("#metric-review").parentElement],
  ["filters", "Search & category", $(".toolbar")],
  ["work", "Work & workflows", $(".work-panel")],
  ["projects", "Open workspaces", $("#workspace-actions")],
].map(([id, label, node]) => ({ id, label, node }));

// Work views can also be opened side by side, with the same workspace/search scope.
export const workViews = new Map([
  ["today", "Today"], ["upcoming", "Upcoming"], ["all", "All work"],
  ["review", "Review"], ["unscheduled", "Unscheduled"],
  ["completed", "Closed"], ["workflows", "Workflows"],
].map(([id, label]) => {
  const node = document.createElement("div");
  node.className = "work-panel";
  node.setAttribute("aria-live", "polite");
  sections.push({ id: "view-" + id, label, node });
  return [id, node];
}));

export const operationsTiles = mountTiles({
  host, sections, key: "biz-kit.operations.tiles.v1",
  defaultLayout: () => {
    const summary = split("h", 1 / 3, leaf("today"), split("h", .5, leaf("overdue"), leaf("review")));
    const tools = split("v", .35, leaf("filters"), split("v", .3, leaf("status"), leaf("projects")));
    const work = split("h", .72, leaf("work"), tools);
    const header = split("h", .5, leaf("overview"), leaf("session"));
    return split("h", .2, leaf("workspaces"), split("v", .2, header, split("v", .22, summary, work)));
  },
});
source.hidden = true;
