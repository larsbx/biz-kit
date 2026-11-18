// Project-derived knowledge. Read scopes, rendered drafts and signed decisions
// are kept together; the public reference catalog is a separate resource.
const record = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const segment = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const digest = /^[0-9a-f]{64}$/;
const text = (value, max) => typeof value === "string" && value.length <= max;
const contextId = value => text(value, 256) && value.trim().length > 0 &&
  new TextEncoder().encode(value).length <= 256 && !/[\x00-\x1f\x7f]/.test(value);
export const knowledgeStatuses = ["pending", "approved", "rejected", "withdrawn", "stale"];
export const knowledgeStatusLabel = (status) => ({
  pending: "Pending approval", approved: "Approved", rejected: "Rejected", withdrawn: "Withdrawn", stale: "Source changed",
})[status] || "Unavailable";

export function knowledgeScope(value) {
  const parts = Array.isArray(value) ? value : [value?.chapter_id, value?.tenant_id, value?.project_id];
  if (parts.length !== 3 || !parts.every(part => typeof part === "string" && segment.test(part))) {
    throw new Error("The project knowledge scope is invalid.");
  }
  return { chapter_id: parts[0], tenant_id: parts[1], project_id: parts[2] };
}

export function projectKnowledgePath(scope) {
  const s = knowledgeScope(scope);
  return `/api/v1/chapters/${encodeURIComponent(s.chapter_id)}/tenants/${encodeURIComponent(s.tenant_id)}/projects/${encodeURIComponent(s.project_id)}/knowledge`;
}

export function projectKnowledgeLink(scope, { provider = "workos", candidateId = null, status = null } = {}) {
  const s = knowledgeScope(scope);
  const query = new URLSearchParams({ chapter: s.chapter_id, tenant: s.tenant_id, project: s.project_id, provider });
  if (candidateId && segment.test(candidateId)) query.set("knowledge", candidateId);
  if (knowledgeStatuses.includes(status)) query.set("knowledge_status", status);
  return `/app?${query}#knowledge-heading`;
}

export function knowledgeContext(value) {
  if (record(value) && Object.keys(value).length === 1 && contextId(value.task_id)) {
    return { task_id: value.task_id };
  }
  if (record(value) && Object.keys(value).length === 2 &&
      contextId(value.roadmap_key) && contextId(value.workflow_id)) {
    return { roadmap_key: value.roadmap_key, workflow_id: value.workflow_id };
  }
  throw new Error("Choose a task or workflow for suggested knowledge.");
}

export function knowledgeSuggestionsURL(scope, context) {
  return `${projectKnowledgePath(scope)}/suggestions?${new URLSearchParams(knowledgeContext(context))}`;
}

export function validateKnowledgeEnvelope(value, principal, scope) {
  const s = knowledgeScope(scope);
  if (!record(value) || value.schema_version !== 1 || value.principal !== principal || !principal ||
      !record(value.scope) || !Object.entries(s).every(([key, expected]) => value.scope[key] === expected)) {
    throw new Error("The project knowledge response does not match this session and project.");
  }
  return value;
}

export function validateKnowledgeCandidate(item, scope = null) {
  if (!record(item) || !segment.test(item.id ?? "") || item.generator_version !== 1 ||
      !["completed_task", "adopted_workflow"].includes(item.kind) || !text(item.title, 512) || !item.title ||
      !text(item.summary, 8192) || !text(item.body, 262144) || !record(item.source) ||
      !digest.test(item.source_fingerprint ?? "") || !digest.test(item.draft_digest ?? "") ||
      !Number.isSafeInteger(item.review_version) || item.review_version < 0 ||
      !knowledgeStatuses.includes(item.status) || typeof item.current !== "boolean" ||
      !(item.review === null || record(item.review))) {
    throw new Error("The project knowledge draft is invalid.");
  }
  const sourceScope = knowledgeScope(item.source.scope);
  if (scope && JSON.stringify(sourceScope) !== JSON.stringify(knowledgeScope(scope))) {
    throw new Error("The knowledge source belongs to another project.");
  }
  return item;
}

export function knowledgeSnapshot(candidate) {
  return Object.fromEntries(["generator_version", "kind", "title", "summary", "body", "source"].map(key => [key, candidate[key]]));
}

export function knowledgeReviewAllowed(candidate, decision) {
  if (decision === "withdraw") {
    return candidate.review?.decision === "approve" && record(candidate.review.snapshot);
  }
  if (decision === "approve") return candidate.current && ["pending", "rejected", "withdrawn"].includes(candidate.status);
  return decision === "reject" && candidate.current && candidate.status === "pending";
}

// Build the exact payload independently of the held envelope. In particular,
// withdrawing an earlier approval signs that reviewed snapshot, never a new draft.
export function knowledgeReviewCommand(scope, candidate, decision, reason) {
  const s = knowledgeScope(scope);
  validateKnowledgeCandidate(candidate, s);
  if (!knowledgeReviewAllowed(candidate, decision) || !text(reason, 1000) ||
      new TextEncoder().encode(reason).length > 1000 || !reason.trim()) {
    throw new Error("Choose an available decision and explain the review.");
  }
  const reviewed = decision === "withdraw" ? candidate.review : candidate;
  const snapshot = decision === "withdraw" ? reviewed.snapshot : knowledgeSnapshot(candidate);
  if (!digest.test(reviewed.source_fingerprint ?? "") || !digest.test(reviewed.draft_digest ?? "") ||
      snapshot?.generator_version !== 1) throw new Error("The reviewed knowledge snapshot is invalid.");
  if (JSON.stringify(knowledgeScope(snapshot.source?.scope)) !== JSON.stringify(s)) {
    throw new Error("The reviewed knowledge source belongs to another project.");
  }
  return {
    type: "KnowledgeCandidateReviewedV1", chapter: s.chapter_id, exact: true,
    payload: {
      tenant_id: s.tenant_id, project_id: s.project_id, candidate_id: candidate.id,
      expected_review_version: candidate.review_version, generator_version: snapshot.generator_version,
      source_fingerprint: { __bytes__: reviewed.source_fingerprint },
      draft_digest: { __bytes__: reviewed.draft_digest }, snapshot, decision, reason: reason.trim(),
    },
  };
}

export function knowledgeReviewRequest(command, keyId) {
  const p = command.payload;
  return {
    governance_key_id: keyId, decision: p.decision, expected_review_version: p.expected_review_version,
    generator_version: p.generator_version, source_fingerprint: p.source_fingerprint.__bytes__,
    draft_digest: p.draft_digest.__bytes__, snapshot: p.snapshot, reason: p.reason,
  };
}

// One request per context; revocation, hiding or a principal change invalidates
// every pending read, even if aborting the transport arrives too late.
export class KnowledgeRequests {
  constructor() { this.epoch = 0; this.pending = new Map(); }
  begin(key) {
    this.pending.get(key)?.controller.abort();
    const token = { key, epoch: this.epoch, controller: new AbortController() };
    this.pending.set(key, token);
    return token;
  }
  current(token) { return !!token && token.epoch === this.epoch && this.pending.get(token.key) === token; }
  cancel(key) { this.pending.get(key)?.controller.abort(); this.pending.delete(key); }
  clear() {
    this.epoch++;
    for (const token of this.pending.values()) token.controller.abort();
    this.pending.clear();
  }
  async read(key, url, principal, scope) {
    const token = this.begin(key);
    const timeout = setTimeout(() => token.controller.abort(), 10_000);
    try {
      const response = await fetch(url, { credentials: "same-origin", cache: "no-store",
        headers: { accept: "application/json" }, signal: token.controller.signal });
      if (!this.current(token)) return null;
      if (!response.ok) {
        const error = new Error(response.status === 401 ? "Sign in to read project knowledge." :
          response.status === 403 ? "Your access to this project has ended." : "Project knowledge is unavailable. Try refreshing.");
        error.status = response.status; throw error;
      }
      const value = validateKnowledgeEnvelope(await response.json(), principal, scope);
      return this.current(token) ? { token, value } : null;
    } catch (error) {
      error.knowledgeToken = token; throw error;
    } finally { clearTimeout(timeout); }
  }
}

function el(doc, tag, attrs = {}, ...children) {
  const node = doc.createElement(tag);
  Object.assign(node, attrs);
  node.append(...children.filter(child => child !== null && child !== undefined));
  return node;
}

// No source text becomes HTML or an arbitrary URL. Original pins are shown in
// full, so the draft and the exact ledger evidence can be reviewed together.
export function renderKnowledgeDraft(container, candidate, scope = null) {
  validateKnowledgeCandidate(candidate, scope);
  const doc = container.ownerDocument;
  const pins = [
    ["Source fingerprint", candidate.source_fingerprint], ["Draft digest", candidate.draft_digest],
    ["Review version", String(candidate.review_version)],
  ];
  container.replaceChildren(...[
    candidate.source_available === false ? el(doc, "p", { className: "knowledge-note", textContent: "Source files are currently unavailable. This knowledge cannot be suggested for work." }) : null,
    el(doc, "pre", { className: "knowledge-body", textContent: candidate.body }),
    el(doc, "details", { className: "knowledge-provenance" },
      el(doc, "summary", { textContent: "Source records and exact version" }),
      el(doc, "dl", {}, ...pins.flatMap(([label, value]) => [el(doc, "dt", { textContent: label }), el(doc, "dd", { textContent: value })])),
      el(doc, "pre", { textContent: JSON.stringify(candidate.source, null, 2) }),
      candidate.review ? el(doc, "p", { textContent: `Last decision: ${candidate.review.decision}. ${candidate.review.reason || ""}` }) : null),
  ].filter(node => node !== null));
}

export function retainedApproval(candidate) {
  if (!knowledgeReviewAllowed(candidate, "withdraw")) return null;
  return {
    ...candidate.review.snapshot, id: candidate.id,
    source_fingerprint: candidate.review.source_fingerprint, draft_digest: candidate.review.draft_digest,
    review_version: candidate.review_version, review: candidate.review, status: "approved", current: false,
  };
}

const sameVersion = (left, right) => left?.id === right?.id && left.source_fingerprint === right.source_fingerprint &&
  left.draft_digest === right.draft_digest && left.review_version === right.review_version && left.status === right.status;

export class ProjectKnowledgeQueue {
  constructor({ container, scope, principal, canReview, decide, selectedId = null, status = "pending" }) {
    this.container = container; this.scope = knowledgeScope(scope); this.principal = principal;
    this.canReview = canReview; this.decide = decide; this.selectedId = selectedId;
    this.status = knowledgeStatuses.includes(status) ? status : "pending";
    this.offset = 0; this.limit = 25; this.value = null; this.reads = new KnowledgeRequests(); this.expanded = new Set();
    this.focusedId = selectedId && segment.test(selectedId) ? selectedId : null;
    this.focused = null; this.detailCache = new Map(); this.reasons = new Map();
    if (selectedId && segment.test(selectedId)) this.expanded.add(selectedId);
    const doc = container.ownerDocument;
    this.filter = el(doc, "select", { value: this.status, ariaLabel: "Knowledge status" },
      ...knowledgeStatuses.map(value => el(doc, "option", { value, textContent: knowledgeStatusLabel(value) })));
    this.filter.value = this.status;
    this.filter.onchange = () => {
      this.status = this.filter.value; this.offset = 0; this.focusedId = null; this.focused = null; this.refresh();
    };
    this.refreshButton = el(doc, "button", { type: "button", textContent: "Refresh knowledge" });
    this.refreshButton.onclick = () => this.refresh();
    this.message = el(doc, "p", { className: "knowledge-note", role: "status", textContent: "Sign in to load project knowledge." });
    this.list = el(doc, "div", { className: "knowledge-list" });
    this.previous = el(doc, "button", { type: "button", textContent: "Previous", disabled: true });
    this.next = el(doc, "button", { type: "button", textContent: "Next", disabled: true });
    this.previous.onclick = () => { this.offset = Math.max(0, this.offset - this.limit); this.refresh(); };
    this.next.onclick = () => { this.offset += this.limit; this.refresh(); };
    container.replaceChildren(el(doc, "div", { className: "knowledge-toolbar" }, this.filter, this.refreshButton), this.message, this.list,
      el(doc, "div", { className: "knowledge-toolbar" }, this.previous, this.next));
  }
  clear(message = "Refresh to read project knowledge.") {
    this.reads.clear(); this.value = null; this.focused = null; this.detailCache.clear(); this.reasons.clear();
    this.list.replaceChildren(); this.message.textContent = message;
    this.previous.disabled = true; this.next.disabled = true; this.refreshButton.disabled = false;
  }
  render() {
    if (!this.value) return;
    const doc = this.container.ownerDocument;
    const items = this.focused ? [this.focused, ...this.value.items.filter(item => item.id !== this.focused.id)] : this.value.items;
    this.list.replaceChildren(...items.map(listed => {
      const cached = this.detailCache.get(listed.id);
      const candidate = cached && sameVersion(cached.candidate, listed) ? cached.candidate : listed;
      const details = el(doc, "details", { className: "knowledge-draft", open: this.expanded.has(candidate.id) });
      details.append(el(doc, "summary", { textContent: "Read draft and sources" }));
      const body = el(doc, "div"); renderKnowledgeDraft(body, candidate, this.scope); details.append(body);
      details.ontoggle = () => {
        if (details.open) { this.expanded.add(candidate.id); this.loadDetail(candidate, body); }
        else this.expanded.delete(candidate.id);
      };
      const approval = retainedApproval(candidate);
      let previous = null;
      if (approval) {
        const approvedBody = el(doc, "div"); renderKnowledgeDraft(approvedBody, approval, this.scope);
        previous = el(doc, "details", { className: "knowledge-previous-approval" },
          el(doc, "summary", { textContent: "Previously approved version — withdraw this version" }), approvedBody);
      }
      const reasonKey = `${candidate.id}/${candidate.draft_digest}`;
      const reasonInput = el(doc, "textarea", { rows: 2, maxLength: 1000, value: this.reasons.get(reasonKey) || "",
        ariaLabel: `Review reason for ${candidate.title}`, placeholder: "Explain the decision for the signed record." });
      reasonInput.oninput = () => this.reasons.set(reasonKey, reasonInput.value);
      const actions = this.canReview() ? ["approve", "reject", "withdraw"].filter(decision => knowledgeReviewAllowed(candidate, decision)).map(decision => {
        const label = { approve: candidate.status === "pending" ? "Approve draft…" : "Reconsider and approve…", reject: "Reject draft…", withdraw: "Withdraw approval…" }[decision];
        const button = el(doc, "button", { type: "button", textContent: label });
        button.onclick = async () => {
          if (!this.canReview()) return;
          details.open = true;
          if (decision === "withdraw" && previous) previous.open = true;
          const reason = reasonInput.value.trim();
          if (!reason) { this.message.textContent = "Enter a reason before reviewing this exact version."; reasonInput.focus(); return; }
          try {
            const result = await this.decide(candidate, decision, reason);
            if (result) { this.reasons.delete(reasonKey); await this.refresh(); }
          } catch (error) { this.message.textContent = error.message; }
        };
        return button;
      }) : [];
      const node = el(doc, "article", { className: "knowledge-item" },
        this.focused?.id === candidate.id ? el(doc, "p", { className: "knowledge-note", textContent: "Selected knowledge" }) : null,
        el(doc, "div", { className: "knowledge-title" }, el(doc, "h3", { textContent: candidate.title }),
          el(doc, "span", { className: `knowledge-badge knowledge-${candidate.status}`, textContent: knowledgeStatusLabel(candidate.status) })),
        el(doc, "p", { className: "knowledge-note", textContent: candidate.kind === "completed_task" ? "From a completed task and its accepted evidence review." : "From an adopted workflow definition." }),
        el(doc, "p", { textContent: candidate.summary }), details, previous,
        actions.length ? el(doc, "label", { className: "knowledge-reason-field" }, "Review reason", reasonInput) : null,
        el(doc, "div", { className: "knowledge-toolbar" }, ...actions),
        !this.canReview() && candidate.status === "pending" ? el(doc, "p", { className: "knowledge-note", textContent: "An enrolled administrator reviews this draft." }) : null);
      node.dataset.knowledgeCandidate = candidate.id; node.dataset.knowledgeStatus = candidate.status;
      return node;
    }));
    if (!items.length) this.list.append(el(doc, "p", { className: "knowledge-note", textContent:
      this.status === "pending" ? "No drafts waiting for approval. Eligible completed work and adopted workflows appear here automatically." : "No knowledge in this view." }));
    const counts = this.value.counts;
    this.message.textContent = `${counts.pending || 0} pending approval · ${counts.approved || 0} approved · ${this.value.total} in this view`;
    this.previous.disabled = this.offset === 0; this.next.disabled = this.offset + this.value.items.length >= this.value.total;
  }
  async loadDetail(candidate, container) {
    const principal = this.principal();
    const cached = this.detailCache.get(candidate.id);
    if (!principal || document.hidden || (cached && sameVersion(cached.candidate, candidate) && Date.now() - cached.loaded < 15_000)) return;
    try {
      const result = await this.reads.read(`detail/${candidate.id}`, `${projectKnowledgePath(this.scope)}/${encodeURIComponent(candidate.id)}`, principal, this.scope);
      if (!result || !this.reads.current(result.token) || this.principal() !== principal || !this.value) return;
      const detail = validateKnowledgeCandidate(result.value.candidate, this.scope);
      const current = this.focused?.id === candidate.id ? this.focused : this.value.items.find(item => item.id === candidate.id);
      if (!sameVersion(current, candidate)) return;
      if (!sameVersion(detail, candidate)) { container.replaceChildren(); await this.refresh(); return; }
      this.detailCache.set(candidate.id, { candidate: detail, loaded: Date.now() });
      renderKnowledgeDraft(container, detail, this.scope);
    } catch (error) {
      if (error.knowledgeToken && !this.reads.current(error.knowledgeToken)) return;
      container.replaceChildren();
      container.textContent = error.message;
      if ([401, 403].includes(error.status)) this.clear(error.message);
    }
  }
  async refresh() {
    const principal = this.principal();
    if (!principal || document.hidden) return;
    this.refreshButton.disabled = true;
    const params = new URLSearchParams({ status: this.status, limit: this.limit, offset: this.offset });
    try {
      const result = await this.reads.read("queue", `${projectKnowledgePath(this.scope)}?${params}`, principal, this.scope);
      if (!result || !this.reads.current(result.token) || this.principal() !== principal) return;
      const value = result.value;
      if (!Array.isArray(value.items) || value.items.length > 100 || !record(value.counts) ||
          !Number.isSafeInteger(value.total) || value.total < 0 ||
          !knowledgeStatuses.every(status => Number.isSafeInteger(value.counts[status]) && value.counts[status] >= 0)) throw new Error("The project knowledge list is invalid.");
      value.items.forEach(item => validateKnowledgeCandidate(item, this.scope));
      if (this.focusedId) {
        const selected = await this.reads.read("selected", `${projectKnowledgePath(this.scope)}/${encodeURIComponent(this.focusedId)}`, principal, this.scope);
        if (!selected || !this.reads.current(selected.token) || !this.reads.current(result.token) || this.principal() !== principal) return;
        this.focused = validateKnowledgeCandidate(selected.value.candidate, this.scope);
        if (this.focused.id !== this.focusedId) throw new Error("The selected knowledge record changed.");
        this.detailCache.set(this.focused.id, { candidate: this.focused, loaded: Date.now() });
      }
      this.value = value; this.render();
      if (this.selectedId) {
        const selected = [...this.list.children].find(node => node.dataset.knowledgeCandidate === this.selectedId);
        if (selected) { this.selectedId = null; selected.scrollIntoView({ block: "nearest" }); }
      }
    } catch (error) {
      if (!error.knowledgeToken || this.reads.current(error.knowledgeToken)) this.clear(error.name === "AbortError" ? "Knowledge refresh timed out. Try refreshing." : error.message);
    } finally { this.refreshButton.disabled = false; }
  }
}

// A shared disclosure for Operations cards and the signed project action view.
// Entries never cross project/principal boundaries and withdrawn results are
// refreshed while open; response content is only inserted as text.
export class KnowledgeSuggestions {
  constructor({ principal, provider = "workos" }) {
    this.principal = principal; this.provider = provider; this.entries = new Map(); this.reads = new KnowledgeRequests();
  }
  beginRender() { for (const entry of this.entries.values()) entry.views = []; }
  endRender() {
    for (const [key, entry] of this.entries) if (!entry.views.length) { this.reads.cancel(key); this.entries.delete(key); }
  }
  clear(message = "Refresh to read suggested knowledge.") {
    this.reads.clear();
    for (const entry of this.entries.values()) {
      entry.items = null; entry.message = message; this.paint(entry);
    }
    this.entries.clear();
  }
  disclosure(scope, context, doc = document) {
    try { scope = knowledgeScope(scope); context = knowledgeContext(context); }
    catch { return null; }
    const key = JSON.stringify([scope, context]);
    if (!this.entries.has(key)) this.entries.set(key, { key, scope, context, open: false, items: null, views: [], message: "Open to find approved knowledge for this work." });
    const entry = this.entries.get(key);
    const node = el(doc, "details", { className: "knowledge-suggestions", open: entry.open });
    const body = el(doc, "div", { className: "knowledge-suggestion-list" });
    node.append(el(doc, "summary", { textContent: "Suggested knowledge" }), body);
    entry.views.push({ node, body }); this.paint(entry);
    node.ontoggle = () => {
      entry.open = node.open;
      if (node.open) this.load(entry);
    };
    return node;
  }
  paint(entry) {
    for (const { body } of entry.views) {
      const doc = body.ownerDocument;
      body.replaceChildren(...(entry.items ? entry.items.map(item => {
        const content = el(doc, "div"); renderKnowledgeDraft(content, item, entry.scope);
        const details = el(doc, "details", {}, el(doc, "summary", { textContent: "Read approved knowledge" }), content);
        const link = el(doc, "a", { href: projectKnowledgeLink(entry.scope, { provider: this.provider, candidateId: item.id, status: "approved" }), textContent: item.title });
        const node = el(doc, "article", { className: "knowledge-suggestion" },
          el(doc, "div", { className: "knowledge-title" }, link, el(doc, "span", { className: "knowledge-badge knowledge-approved", textContent: "Approved" })),
          el(doc, "p", { className: "knowledge-reason", textContent: item.reason }),
          el(doc, "p", { textContent: item.summary }), details);
        node.dataset.suggestedKnowledge = item.id; return node;
      }) : []));
      if (!entry.items?.length) body.append(el(doc, "p", { className: "knowledge-note", textContent: entry.items ? "No approved knowledge matches this work yet." : entry.message }));
    }
  }
  async load(entry) {
    const principal = this.principal();
    if (!principal || document.hidden || entry.loading || !entry.views.some(view => view.node.isConnected)) return;
    // A task can appear in several Operations tiles. Their toggle events and
    // the visible-page poll share one read, without weakening cancellation.
    entry.loading = true;
    try {
      entry.message = "Finding approved project knowledge…"; this.paint(entry);
      const result = await this.reads.read(entry.key, knowledgeSuggestionsURL(entry.scope, entry.context), principal, entry.scope);
      if (!result || !this.reads.current(result.token) || this.principal() !== principal || this.entries.get(entry.key) !== entry) return;
      if (!Array.isArray(result.value.items) || result.value.items.length > 20) throw new Error("The knowledge suggestions are invalid.");
      for (const item of result.value.items) {
        validateKnowledgeCandidate(item, entry.scope);
        if (item.status !== "approved" || !item.current || !text(item.reason, 2048) || !item.reason) throw new Error("Suggested knowledge must have a current approval.");
      }
      const context = result.value.context;
      if (!record(context) || !Object.entries(entry.context).every(([key, value]) => context[key] === value)) throw new Error("The suggested knowledge context changed.");
      entry.items = result.value.items; this.paint(entry);
    } catch (error) {
      if (error.knowledgeToken && !this.reads.current(error.knowledgeToken)) return;
      entry.items = null; entry.message = error.name === "AbortError" ? "Suggestions timed out. Reopen to retry." : error.message; this.paint(entry);
      if (error.status === 401) this.clear(error.message);
      else if (error.status === 403) {
        for (const other of this.entries.values()) if (JSON.stringify(other.scope) === JSON.stringify(entry.scope)) {
          this.reads.cancel(other.key); other.items = null; other.message = error.message; this.paint(other);
        }
      }
    } finally { entry.loading = false; }
  }
  refreshOpen() {
    for (const entry of this.entries.values()) if (entry.open) this.load(entry);
  }
}
