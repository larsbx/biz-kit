// The source is data. Only explicitly created DOM nodes are rendered; HTML,
// scripts, embedded images and executable link schemes are never interpreted.
const opaqueId = /^[A-Za-z0-9._-]{1,128}$/;
const record = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

export function externalLink(value) {
  if (typeof value !== "string" || !/^https?:\/\//i.test(value) || /[\x00-\x20\x7f]/.test(value)) return null;
  try {
    const url = new URL(value);
    return ["http:", "https:"].includes(url.protocol) && !url.username && !url.password ? url.href : null;
  } catch {
    return null;
  }
}

export function headingId(value) {
  return `section-${String(value).normalize("NFC").toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "")}`;
}

export function operationsReturnLink(value = "", provider = "workos") {
  const incoming = new URLSearchParams(value);
  const query = new URLSearchParams({ provider });
  for (const key of ["workspace", "category", "q", "tab"]) {
    const text = incoming.get(key);
    if (text && text.length <= 256) query.set(key, text);
  }
  return `/operations?${query}`;
}

export function knowledgeLink(id, { provider = "workos", back = "", query = "", area = "", category = "", offset = 0 } = {}) {
  const params = new URLSearchParams({ provider });
  if (opaqueId.test(id ?? "")) params.set("doc", id);
  if (back) params.set("back", back);
  if (query) params.set("query", query);
  if (area) params.set("area", area);
  if (category) params.set("category", category);
  if (Number.isInteger(offset) && offset > 0 && offset <= 1000) params.set("offset", String(offset));
  return `/operations/knowledge?${params}`;
}

export function searchURL({ query = "", area = "", category = "", offset = 0, limit = 40 } = {}) {
  const params = new URLSearchParams({ query, offset: String(offset), limit: String(limit) });
  if (area) params.set("area", area);
  if (category) params.set("category", category);
  return `/api/v1/operations/knowledge?${params}`;
}

export function validateCatalogResponse(value) {
  if (!record(value) || value.schema_version !== 1 || typeof value.principal !== "string" || !value.principal ||
      !record(value.catalog) || value.catalog.read_only !== true || !Array.isArray(value.catalog.areas) ||
      !record(value.catalog.source) || !/^[0-9a-f]{40}$/.test(value.catalog.source.revision ?? "") ||
      !Number.isInteger(value.catalog.total) || value.catalog.total < 0 ||
      !record(value.results) || !Array.isArray(value.results.documents) ||
      !Number.isInteger(value.results.total) || value.results.total < 0 ||
      !Number.isInteger(value.results.offset) || value.results.offset < 0 ||
      !Number.isInteger(value.results.limit) || value.results.limit < 1 || value.results.limit > 100 ||
      !value.results.documents.every((doc) => record(doc) && opaqueId.test(doc.id ?? "") && typeof doc.title === "string")) {
    throw new Error("The reference library response is invalid.");
  }
  return value;
}

export class KnowledgeState {
  constructor() { this.generation = 0; this.value = null; this.document = null; }
  begin() { return ++this.generation; }
  current(generation) { return this.generation === generation; }
  accept(generation, value) {
    if (!this.current(generation)) return false;
    this.value = validateCatalogResponse(value);
    return true;
  }
  clear() { this.generation++; this.value = null; this.document = null; }
}

export function categories(areas, selectedArea = "") {
  return [...new Set(areas.filter((area) => !selectedArea || area.id === selectedArea)
    .flatMap((area) => (area.categories ?? []).map((category) => category.name)))].sort();
}

export function documentRows(documents, category = "") {
  return documents.filter((doc) => !category || doc.category === category);
}

function reference(target, label, links, options) {
  const fragment = (value) => {
    try { return headingId(decodeURIComponent(value)); }
    catch { return headingId(value); }
  };
  const resolved = links.find((link) => link.target === target && link.status === "resolved" && opaqueId.test(link.document_id ?? ""));
  if (resolved) {
    const anchor = target.includes("#") ? `#${fragment(target.slice(target.indexOf("#") + 1))}` : "";
    return { tag: "a", text: label, href: knowledgeLink(resolved.document_id, options) + anchor, internal: true };
  }
  if (target.startsWith("#")) return { tag: "a", text: label, href: `#${fragment(target.slice(1))}`, internal: true };
  const href = externalLink(target);
  return href ? { tag: "a", text: label, href, external: true } : { tag: "span", text: label, unresolved: true };
}

export function inlineParts(text, links = [], options = {}) {
  const parts = [];
  const pattern = /!?\[\[([^\]\n]+)\]\]|!?\[([^\]\n]*)\]\(([^)\n]+)\)|`([^`\n]+)`|\*\*([^*\n]+)\*\*|(?<!\*)\*([^*\n]+)\*(?!\*)/g;
  let last = 0;
  for (const match of text.matchAll(pattern)) {
    if (match.index > last) parts.push({ tag: "text", text: text.slice(last, match.index) });
    if (match[1] !== undefined) {
      const [target, ...labels] = match[1].split("|");
      parts.push(reference(target.trim(), labels.join("|").trim() || target.trim(), links, options));
    } else if (match[2] !== undefined) {
      parts.push(reference(match[3].trim(), match[2] || match[3], links, options));
    } else if (match[4] !== undefined) parts.push({ tag: "code", text: match[4] });
    else if (match[5] !== undefined) parts.push({ tag: "strong", text: match[5] });
    else parts.push({ tag: "em", text: match[6] });
    last = match.index + match[0].length;
  }
  if (last < text.length) parts.push({ tag: "text", text: text.slice(last) });
  return parts;
}

function tableCells(line) {
  const cells = []; let cell = ""; let wiki = 0; let code = false;
  const text = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === "\\" && text[i + 1] === "|") { cell += "|"; i++; continue; }
    if (text.slice(i, i + 2) === "[[") wiki++;
    if (text.slice(i, i + 2) === "]]") wiki = Math.max(0, wiki - 1);
    if (ch === "`") code = !code;
    if (ch === "|" && !wiki && !code) { cells.push(cell.trim()); cell = ""; }
    else cell += ch;
  }
  cells.push(cell.trim()); return cells;
}

export function markdownBlocks(body) {
  const lines = String(body ?? "").replace(/\r\n?/g, "\n").split("\n");
  const blocks = [];
  let i = 0;
  if (lines[0] === "---") {
    const end = lines.indexOf("---", 1);
    if (end > 0) { blocks.push({ tag: "metadata", text: lines.slice(1, end).join("\n") }); i = end + 1; }
  }
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    const fence = line.match(/^\s*(`{3,}|~{3,})([^`]*)$/);
    if (fence) {
      const content = []; i++;
      const close = new RegExp(`^\\s*${fence[1][0]}{${fence[1].length},}\\s*$`);
      while (i < lines.length && !close.test(lines[i])) content.push(lines[i++]);
      if (i < lines.length) i++;
      blocks.push({ tag: "pre", text: content.join("\n") }); continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.+?)\s*#*$/);
    if (heading) { blocks.push({ tag: `h${Math.min(6, heading[1].length + 1)}`, text: heading[2], id: headingId(heading[2]) }); i++; continue; }
    if (/^\s*([-*_])(?:\s*\1){2,}\s*$/.test(line)) { blocks.push({ tag: "hr" }); i++; continue; }
    if (i + 1 < lines.length && line.includes("|") && /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(lines[i + 1])) {
      const header = tableCells(line); const rows = []; i += 2;
      while (i < lines.length && lines[i].trim() && lines[i].includes("|")) rows.push(tableCells(lines[i++]));
      blocks.push({ tag: "table", header, rows }); continue;
    }
    const item = line.match(/^\s*(?:([-+*])|\d+[.)])\s+(.+)$/);
    if (item) {
      const ordered = !item[1]; const items = [];
      while (i < lines.length) {
        const next = lines[i].match(/^\s*(?:([-+*])|\d+[.)])\s+(.+)$/);
        if (!next || !next[1] !== ordered) break;
        items.push(next[2].replace(/^\[ \]\s*/, "☐ ").replace(/^\[x\]\s*/i, "☑ ")); i++;
      }
      blocks.push({ tag: ordered ? "ol" : "ul", items }); continue;
    }
    if (/^\s*>/.test(line)) {
      const quote = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) quote.push(lines[i++].replace(/^\s*>\s?/, ""));
      blocks.push({ tag: "blockquote", text: quote.join("\n") }); continue;
    }
    const paragraph = [line]; i++;
    while (i < lines.length && lines[i].trim() && !/^\s*(?:#{1,6}\s|`{3}|~{3}|>|[-+*]\s|\d+[.)]\s)/.test(lines[i]) &&
           !(i + 1 < lines.length && lines[i].includes("|") && /^\s*\|?\s*:?-{3,}/.test(lines[i + 1]))) paragraph.push(lines[i++]);
    blocks.push({ tag: "p", text: paragraph.join("\n") });
  }
  return blocks;
}

export function renderMarkdown(container, body, { links = [], ...options } = {}) {
  const dom = container.ownerDocument;
  const node = (tag, text) => { const value = dom.createElement(tag); if (text !== undefined) value.textContent = text; return value; };
  const inline = (element, text) => {
    for (const part of inlineParts(text, links, options)) {
      if (part.tag === "text") { element.append(dom.createTextNode(part.text)); continue; }
      const child = node(part.tag, part.text);
      if (part.href) child.setAttribute("href", part.href);
      if (part.external) { child.setAttribute("target", "_blank"); child.setAttribute("rel", "noopener noreferrer"); }
      if (part.internal) child.dataset.knowledgeLink = "true";
      if (part.unresolved) { child.className = "unresolved-reference"; child.title = "Reference unavailable in this snapshot"; }
      element.append(child);
    }
    return element;
  };
  const fragment = dom.createDocumentFragment();
  for (const block of markdownBlocks(body)) {
    let element;
    if (block.tag === "metadata") {
      element = node("details"); element.className = "source-metadata";
      element.append(node("summary", "Source metadata"), node("pre", block.text));
    } else if (block.tag === "table") {
      element = node("div"); element.className = "table-scroll";
      const table = node("table"); const head = node("thead"); const heading = node("tr");
      for (const text of block.header) heading.append(inline(node("th"), text));
      head.append(heading); const tbody = node("tbody");
      for (const values of block.rows) {
        const row = node("tr"); for (const text of values) row.append(inline(node("td"), text)); tbody.append(row);
      }
      table.append(head, tbody); element.append(table);
    } else if (block.tag === "ul" || block.tag === "ol") {
      element = node(block.tag); for (const text of block.items) element.append(inline(node("li"), text));
    } else if (block.tag === "pre") { element = node("pre"); element.append(node("code", block.text)); }
    else if (block.tag === "hr") element = node("hr");
    else { element = inline(node(block.tag), block.text); if (block.id) element.id = block.id; }
    fragment.append(element);
  }
  container.replaceChildren(fragment);
}
