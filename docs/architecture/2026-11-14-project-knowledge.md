# Project knowledge from recorded work

Status: implemented increment; production rollout uses the existing Task Host
release process.

## Behavior

The project's knowledge queue populates from its existing signed operational
state. Opening the project app or refreshing Operations discovers eligible
sources automatically. There is no manual generation command, background
governance key, new business ledger, or model service to configure.

The first two source adapters are deliberately factual:

| Source | Eligibility | Generated draft |
| --- | --- | --- |
| Completed task | Completed under its current accepted Definition of Done, with retained evidence custody receipts | Task title and description, completion criteria, accepted review and exact source references |
| Adopted workflow | The project's current hierarchy selects the retained adopted blueprint revision | Workflow and step descriptions, dependencies, completion criteria and adopted source pins |

These are summaries of what was recorded. They do not infer lessons, business
results, or evidence contents that the source metadata does not contain.
Evidence digests and receipt identifiers are references; artifact bodies stay
behind their existing custody access controls. In-progress tasks and unaccepted
evidence do not create completed-task knowledge.

## Approval and currentness

Every new candidate starts pending approval. Its identity is stable for the
project and source, while a source fingerprint and a draft digest identify the
exact revision. Ordinary scheduling or todo changes do not change a completed
task's knowledge revision. Completion provenance uses the actual completion
command, not the task's latest miscellaneous event.

An enrolled governance administrator can approve, reject or withdraw a draft.
The browser displays the draft and source references, checks the exact prepared
command, and signs it with its existing device key. The common ledger admits
`KnowledgeCandidateReviewedV1`; task evidence-reviewer authority alone cannot
approve knowledge. Governance command-line clients can use the same signed
command path.

Each decision binds the project scope, candidate ID, exact source and draft,
decision, reason and expected review version. Admission reconstructs the current
candidate before accepting approval or rejection. A concurrent decision,
changed draft, changed source or revoked governance key refuses the held
command. Approval also checks that the referenced source artifacts are still
available and intact at the append boundary, including generic event submission.

The accepted event retains the reviewed snapshot. Folding and replay preserve
that snapshot and the signed decision without reading today's filesystem.
Refreshes neither append duplicate candidate events nor resurrect an unchanged
rejection. A substantive source change requires a new review. Withdrawal removes
an approval from suggestions and remains possible when the source is superseded
or unavailable. Historical decisions remain in the common log.

## Suggestions during Operations

Operations workspace cards show counts and a link to that project's knowledge
queue. The project app offers pending, approved and historical review states,
with source details and governance actions. Task and workflow cards can reveal
suggested knowledge without leaving the current work context.

Suggestions select current approved items in the exact project. Ranking first
uses the same adopted workflow revision and task definition, then bounded title
and topic matching. Each result includes an explanation. A different revision
of the same workflow is excluded, so a reference for a newer adoption is not
offered as procedural advice for an older pinned run. A completed task does not
recommend its own recap to itself. At most five available results are returned;
source availability is checked after ranking, for at most twenty candidates.

Pending, rejected, withdrawn, stale and unavailable items do not appear as
operational recommendations. Suggestions do not adopt workflows, instantiate
tasks, change readiness, substitute an SOP, or start external actions.

## Scope and access

`TaskCore.Knowledge` derives candidates and admits/folds signed decisions.
`CoopSubstrate.Knowledge` prepares and submits held commands. The Task Host
controller authenticates reads and applies the current exact-project feed or
administrator grant. `TaskHost.ProjectKnowledgeSuggestions` resolves context
from that same canonical state, without accepting client-supplied task text or
source pins.

The read endpoints are under:

```text
/api/v1/chapters/:chapter/tenants/:tenant/projects/:project/knowledge
```

They provide the bounded queue, candidate details and contextual suggestions.
Review preparation and signature submission use the candidate's `/reviews`
routes. Responses recheck current access and are not cached. The browser clears
private content on access/session loss or page hiding, fences late responses,
and refreshes visible knowledge periodically as well as after source or review
changes.

The shared imported `bizops-kb` catalog remains a separate reference library.
Approving project knowledge does not copy company data into its static assets
or publish it to GitHub. Its broad Operations-library read gate is not used for
project-derived drafts, snippets, counts or recommendations.

## Extension points

Additional source adapters need an explicit project scope, source eligibility,
bounded extraction, versioned generator, stable identity and source pins. A
nondeterministic model-generated draft would require retained generated bytes
and provenance; it cannot replace this deterministic projection without a new
custody contract. No external documents, messages or databases are harvested by
this increment.

Focused core, HTTP and JavaScript acceptance tests cover automatic discovery,
exact signed review, persistent rejection, withdrawal, source replacement,
scope isolation, authority revocation and contextual relevance. Browser and
hosted checks are reported separately from local executable results in the PR;
this document does not assert that a release has been deployed.
