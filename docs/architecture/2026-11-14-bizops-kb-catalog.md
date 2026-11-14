# bizops-kb reference catalog in Operations

Date: 2026-11-14 (America/New_York).
Status: implementation for review; production deployment is a separate gate.

## Purpose

Make the existing business knowledge vault useful inside biz-kit: browse the
Johnny.Decimal structure, search reference text, follow related procedures,
and see exact source provenance. Reuse the Operations host and its session and
workspace checks.

The owner explicitly authorized source copying after the private upstream / public
destination distinction was identified. This selects a pinned content snapshot,
following the existing SchoolOps content pattern, for this reference corpus.
It does not convert the authoring repository into a biz-kit subtree or make a
document an approved executable workflow.

## Delivered boundary

- `apps/bizops_kb`: read-only catalog, integrity checks and TaskCore workflow
  previews. TaskCore is its only app dependency.
- `priv/content`: exact Markdown from upstream commit
  `8749d8db1abd3145b22c6a27da2cc49a41c303fe`; 216 documents, 106,105 bytes,
  including the revised October 30 source-custody decision.
- `priv/catalog.json`: deterministic stable IDs, original paths, categories,
  byte sizes, SHA-256 digests, and Git blob identities.
- `priv/source-proof.json`: the exact upstream Git commit and complete tree
  membership needed for independent offline source verification.
- `scripts/bizops-kb/snapshot.py`: reproducible import/check; no GitHub token
  or network is needed to verify the committed copy.
- TaskHost Knowledge page and GET API: bounded search, category navigation,
  safe document rendering and wiki links, source revision, current session
  and Operations workspace authorization, and noncacheable responses.

Original source text is preserved, including historical references to Buzz,
Hermes, SpruceGoose, and earlier commercial choices. The UI labels it as
reference material. Most catalog records are taxonomy scaffolds, so an imported
record count is not a count of implemented business workflows.

## Identity and source verification

The importer reads immutable Git objects, not the source working tree. Every
copied file must be a regular nonexecutable Markdown blob. Source paths retain
their Unicode characters and Johnny.Decimal suffixes; IDs are strings, not
floating-point numbers. Non-Johnny.Decimal source documents receive a stable
path-derived identifier.

The offline checker reconstructs Git trees in Git's byte ordering, checks the
raw commit hash and declared root, and verifies every copied blob against that
tree. It also checks the deterministic catalog, exact file inventory, and all
45 current wiki links. A coordinated edit of a file and its catalog digest
still fails against the retained source proof. These are identity checks, not
a proof that the content is true, current, licensed for another recipient, or
approved as a procedure.

Default runtime reads first bind the packaged manifest to its compiled SHA-256,
then verify both document hashes and size, reject duplicate IDs/paths,
traversal and content symlinks, and resolve documents only through catalog IDs.
If any source bytes are missing or inconsistent, the host reports the catalog
unavailable. It does not serve a silently partial or substituted source.
Changing document bytes and recomputing their manifest hashes cannot bypass
the compiled pin. Replacing the source snapshot requires review and rebuilding
the app. Trusted library callers may explicitly load another root without that
package pin; the HTTP host uses only the pinned default. Relocating identical
package bytes uses `load_packaged(root)` and retains the same pin.

## Access and rendering

This imported corpus is intentionally shared reference material. All users
with a current Operations session and at least one authorized configured
workspace may read the same snapshot. Current access is checked before reads
and the session is rechecked before responding. Responses use `no-store`.
No authorization is inferred from a category name or prose about an access tier.

The browser renders text using DOM nodes. Raw HTML, embedded scripts, and
active Markdown are not executed. Internal wiki links resolve only to known
catalog records; external links use allowed URL schemes. Search is bounded,
deterministic, and operates on the verified copy.

Do not append private operational or employee records to this shared dataset
and assume folder naming protects them. A future scoped corpus needs explicit
publication/access/withdrawal semantics and separate acceptance.

## Relationship to existing architecture

The [shared storage contract](2026-10-30-postgres-event-log-redis-consolidation.md)
and [revised upstream source-custody ADR][custody] continue to govern operational authority.
The reference import introduces no log, database, Redis index, scheduler,
financial writer, or execution port. Git retains the editable source.
The code-review/release path publishes a fixed reference copy; operational
adoption uses the separate signed workflow controls described below.

The legacy SpruceGoose knowledge table migration is not reused as a working
catalog or a source of permission. No legacy promotion/distribution receipt
is migrated or retired. This feature is independent of the larger writer
decommission and PostgreSQL backend replacement.

Existing artifact custody is task-bound; it is not widened to become a vault
upload API. TaskCore blueprints/readiness are the workflow integration seam.

The migration assigns integration responsibilities as follows. These boundaries
do not imply that catalog publication, installation policy or withdrawal
commands already exist.

| Responsibility | Integration owner and requirement |
| --- | --- |
| Editable source and attribution | `bizops-kb` Git history; retain the exact repository, commit, tree, path and blob identity. An ownership move must be decided explicitly. |
| Authentication and principals | `BizKit.Identity`; use current sessions and canonical principal bindings. |
| Reference UI and source verification | `task_host` hosts this catalog and the existing blueprint source-verification interface. |
| Adopted task and SOP rules | `TaskCore`; bind reviewed SOP versions and required inputs when a workflow is explicitly adopted. |
| Operational admission and replay | `CoopSubstrate.Log`; existing signed workflow adoption uses the common history. Future catalog publication and withdrawal commands must use it as well. |
| Task-bound evidence bytes | `CoopSubstrate.ArtifactCustody`, configured through `COOP_ARTIFACT_DIR`; do not treat the reference import as an upload grant. |
| SQL and Redis | Shared projections and rebuildable operational data; neither becomes editable source custody or an independent authority. |

The retired `/mcp` endpoint and local OAuth issuer are not integration targets.
Copying this pinned, attributed corpus is independent of the remaining SpruceGoose
decommission. Before any operational writer cutover, account for that workflow's
active readers, installations, retained history, withdrawal state and replay;
do not infer retirement of every legacy obligation from this reference import.

This reader has no live upstream subscription or per-document withdrawal writer.
Revoking the session or all configured workspace grants prevents subsequent API
reads. Withdrawing a document from the published reference snapshot requires a
reviewed import and rebuild. Previously delivered bytes cannot be recalled.
Current document/installation policy and signed withdrawal admission remain
requirements for a future governed distribution adapter.

## Workflow increment

The [workflow increment](2026-11-14-bizops-kb-workflows.md) implements the first
eight-task adaptation of `24.12` and `24.12d`, with a preview and retained
artifacts at ASCII-safe paths. The authored manifest is a separate Git blob
from the original Markdown. An optional TaskCore contract binds its exact SOP
and inputs through ordinary readiness admission. Explicit signed adoption is
available from a verified local Git checkout; run creation remains separate.

This increment also selects upstream revision `8749d8db`, incorporating the
revised SpruceGoose migration custody policy and README. Only those two source
documents changed from the first import at `ca356e34`; the two procedures used
by the workflow remain byte-identical. Source authorship remains in `bizops-kb`.

## Acceptance

The dedicated catalog workflow checks source provenance, reproducible import,
tampering/path/symlink controls, bounded catalog lookup, wiki links, and safe
browser rendering. Operations workspace acceptance compiles the actual host
dependency and checks anonymous/no-workspace/revoked access, GET API behavior,
and the existing Operations flows. Record the evaluated source revision and
actual workflow outcomes; passing the pure catalog checks alone is not hosted
or deployment evidence.

[custody]: https://github.com/larsbx/bizops-kb/blob/8749d8db1abd3145b22c6a27da2cc49a41c303fe/docs/decisions/2026-10-30-source-custody-and-platform-storage.md
