import { mountTiles, columns } from "./tiles.js";
import { leaf, split } from "./layout.js";

const source = document.querySelector("main");
const host = document.createElement("div");
host.setAttribute("role", "main");
source.before(host);
document.body.classList.add("project-tiles");
const sections = [...source.querySelectorAll(":scope > section")]
  .filter((node) => node.id !== "admin-section")
  .map((node) => ({ id: node.getAttribute("aria-labelledby"), label: node.querySelector("h2").textContent, node }));
const admin = document.getElementById("admin-section");
for (const [index, node] of [...admin.querySelectorAll(":scope > .card")].entries()) {
  sections.push({ id: `admin-${index}`, label: node.querySelector("h3").textContent, node, gate: admin });
}
sections.push({ id: "connection", label: "Connection status", node: document.getElementById("status") });
export const projectTiles = mountTiles({
  host, sections, key: "biz-kit.task-host.tiles.v1",
  defaultLayout: () => split("h", .6,
    split("v", .65, leaf("tasks-heading"), columns(["workflow-heading", "reviews-heading"])),
    columns(["pending-heading", "device-heading", "delegations-heading", "history-heading", "connection"])),
});
source.hidden = true;
