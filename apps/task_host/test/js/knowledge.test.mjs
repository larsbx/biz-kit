import { test } from "node:test";
import assert from "node:assert/strict";
import {
  externalLink, headingId, knowledgeLink, operationsReturnLink, searchURL,
  validateCatalogResponse, KnowledgeState, categories, markdownBlocks,
  inlineParts, renderMarkdown,
} from "../../priv/static/app/knowledge-view.js";

const snapshot = () => ({
  schema_version: 1, principal: "prn_reader",
  catalog: { read_only: true, total: 2, source: { repository: "example/reference", revision: "a".repeat(40) }, areas: [] },
  results: { documents: [{ id: "doc-01", title: "Source" }], total: 2, offset: 0, limit: 40 },
});

test("reference snapshots reject malformed content and executable authority claims", () => {
  assert.equal(validateCatalogResponse(snapshot()).results.total, 2);
  for (const change of [
    { principal: "" }, { schema_version: 2 }, { results: { documents: [] } },
    { catalog: { ...snapshot().catalog, read_only: false } },
    { results: { ...snapshot().results, documents: [{ id: "../../private", title: "bad" }] } },
  ]) assert.throws(() => validateCatalogResponse({ ...snapshot(), ...change }));
});

test("a late read cannot repopulate the library after revocation, logout or hiding", () => {
  const state = new KnowledgeState(); const old = state.begin(); state.clear();
  assert.equal(state.accept(old, snapshot()), false);
  const current = state.begin(); assert.equal(state.accept(current, snapshot()), true);
  state.document = { body: "a document" }; state.clear();
  assert.equal(state.value, null); assert.equal(state.document, null);
});

test("only explicit HTTP(S) URLs without credentials or control characters become external links", () => {
  assert.equal(externalLink("https://example.org/a?q=1#b"), "https://example.org/a?q=1#b");
  for (const value of ["javascript:alert(1)", "data:text/html,abc", "file:///etc/passwd", "//example.org", "/admin/delete", "https://user:pass@example.org", "https://example.org/\na", " https://example.org", "vbscript:test"]) {
    assert.equal(externalLink(value), null, value);
  }
});

test("internal navigation preserves filters and cannot create an external return destination", () => {
  const link = new URL(knowledgeLink("doc-01", { provider: "second", query: "SOP & notes", area: "20 Operations", category: "24 Execution", offset: 40, back: "tab=review&workspace=desk" }), "https://host.test");
  assert.equal(link.pathname, "/operations/knowledge");
  assert.equal(link.searchParams.get("query"), "SOP & notes");
  assert.equal(link.searchParams.get("offset"), "40");
  const back = new URL(operationsReturnLink("tab=review&workspace=desk&redirect=https://evil.test", "second"), "https://host.test");
  assert.equal(back.pathname, "/operations"); assert.equal(back.origin, "https://host.test");
  assert.equal(back.searchParams.get("workspace"), "desk"); assert.equal(back.searchParams.has("redirect"), false);
  assert.equal(new URL(knowledgeLink("../../bad"), "https://host.test").searchParams.has("doc"), false);
});

test("server search receives category and pagination without losing Unicode or punctuation", () => {
  const url = new URL(searchURL({ query: "24.12a", area: "🚀 Operations", category: "R&D", offset: 40, limit: 40 }), "https://host.test");
  assert.equal(url.searchParams.get("area"), "🚀 Operations");
  assert.equal(url.searchParams.get("category"), "R&D");
  assert.equal(url.searchParams.get("offset"), "40");
  const areas = [{ id: "a", categories: [{ name: "24 Operations" }] }, { id: "b", categories: [{ name: "91 Notes" }] }];
  assert.deepEqual(categories(areas, "a"), ["24 Operations"]);
});

test("wiki IDs with letter suffixes resolve exactly while unknown references stay inert", () => {
  const links = [{ target: "24.12a Setup#Review", status: "resolved", document_id: "doc-12a" }];
  const parts = inlineParts("[[24.12a Setup#Review|Read setup]] and [[24.12 Missing]]", links);
  assert.equal(parts[0].text, "Read setup");
  assert.match(parts[0].href, /doc=doc-12a#section-review$/);
  assert.equal(parts[2].unresolved, true);
  assert.equal(parts[2].href, undefined);
  assert.equal(headingId("Équipe & مراجعة"), "section-équipe-مراجعة");
  const encoded = inlineParts("[Guide](./Other.md#Use%20it)", [{ target: "./Other.md#Use%20it", status: "resolved", document_id: "other" }]);
  assert.match(encoded[0].href, /#section-use-it$/);
  assert.doesNotThrow(() => inlineParts("[Guide](#Bad%encoding)"));
});

test("Markdown scripts, unsafe links and embedded media are never executable nodes", () => {
  const source = '<script>alert(1)</script> [bad](javascript:alert(1)) ![image](https://example.org/tracker.png)';
  const parts = inlineParts(source);
  assert.equal(parts[0].tag, "text"); assert.match(parts[0].text, /<script>/);
  assert.ok(parts.some((part) => part.text === "bad" && part.unresolved));
  assert.equal(parts.some((part) => part.tag === "img" || part.tag === "script"), false);
  assert.ok(parts.some((part) => part.tag === "a" && part.external && part.text === "image"));
});

test("headings, lists, fenced code and tables retain useful structure", () => {
  const blocks = markdownBlocks('---\nstatus: draft\n---\n# Procedure\n\n- [ ] Review\n- [x] Record\n\n```sh\nrm -rf /example\n```\n\n| Source | State |\n| --- | --- |\n| [[24.12a|Setup]] | draft |');
  assert.deepEqual(blocks.map((block) => block.tag), ["metadata", "h2", "ul", "pre", "table"]);
  assert.deepEqual(blocks[2].items, ["☐ Review", "☑ Record"]);
  assert.equal(blocks[3].text, "rm -rf /example");
  assert.deepEqual(blocks[4].rows, [["[[24.12a|Setup]]", "draft"]]);
});

// A tiny DOM enforces the renderer's contract: content can only be appended as
// text or explicitly constructed elements. Assigning HTML is an immediate fault.
class Element {
  constructor(tag, ownerDocument) { this.tag = tag; this.ownerDocument = ownerDocument; this.children = []; this.attrs = {}; this.dataset = {}; this.textContent = ""; }
  set innerHTML(_) { throw new Error("HTML injection attempted"); }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute(key, value) { this.attrs[key] = value; }
}
const dom = {
  createElement: (tag) => new Element(tag, dom),
  createTextNode: (text) => Object.assign(new Element("#text", dom), { textContent: text }),
  createDocumentFragment: () => new Element("#fragment", dom),
};
const descendants = (node) => [node, ...node.children.flatMap(descendants)];

test("the actual DOM renderer emits text for HTML and locks external anchor attributes", () => {
  const container = new Element("div", dom);
  renderMarkdown(container, '# Title\n<script src="evil"></script>\n\n[External](https://example.org)\n\n```html\n<img onerror=evil()>\n```');
  const nodes = descendants(container);
  assert.equal(nodes.some((node) => ["script", "img", "iframe"].includes(node.tag)), false);
  const anchor = nodes.find((node) => node.tag === "a");
  assert.equal(anchor.attrs.rel, "noopener noreferrer");
  assert.equal(anchor.attrs.target, "_blank");
  assert.ok(nodes.some((node) => node.textContent.includes("<script")));
  assert.ok(nodes.some((node) => node.tag === "code" && node.textContent === "<img onerror=evil()>"));
});
