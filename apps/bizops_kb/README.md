# Business knowledge catalog and workflow previews

The Johnny.Decimal business reference library from `larsbx/bizops-kb`, available
inside the Operations workspace at `/operations/knowledge`.

The owner authorized copying the source into biz-kit. This snapshot contains
216 Markdown documents, including the upstream README and storage decision.
The original paths, Unicode names, suffixed IDs such as `24.12a`, source bytes,
attribution, and internal links are preserved. No license or additional rights
grant is inferred from the import.

## Source and purpose

| Item | Value |
| --- | --- |
| Authoring repository | `larsbx/bizops-kb` |
| Pinned revision | `8749d8db1abd3145b22c6a27da2cc49a41c303fe` |
| Source tree | `79f146858c5d9d850df69b67294cb3fabf131bd1` |
| Imported Markdown bytes | 106,105 |
| Resolved wiki links | 45 |
| Operational meaning | Shared reference material; no SOP adoption or execution authority |

Many entries are filing-category scaffolds. Longer procedures record particular
deployment or commercial choices at their source revision. Their presence does
not establish current implementation, production acceptance, or approval to
perform an action. Current business policies still govern actual workflows.

This revision includes the [updated October 30 source-custody decision][custody].
The 214 numbered notes are unchanged from the initial import; the source README
and decision now describe the migration to Biz-kit. The existing shared-reference
publication scope is unchanged.

The app has no network client, database, writer, worker, or agent invocation.
Workflow validation uses the portable `task_core` app.
The host requires a current Operations session and access to a configured
workspace. This is one shared, intentionally published reference corpus;
folder names and terms such as "restricted" in procedure text are not document
access-control labels. Company-private records need a separate scoped
publication design before they are added.

## Read API

`BizOpsKB.Catalog.load/0` binds the packaged manifest to its compiled SHA-256
before verifying every retained document's SHA-256, Git blob identity, size,
path, and UTF-8 encoding. Coordinated edits to a document and its recorded hashes
cannot retain the packaged source identity. It refuses
the complete catalog if any document is missing or inconsistent. The catalogue
supports bounded text search, area/category filtering, stable-ID lookup, and
unambiguous Obsidian wiki-link resolution. It never evaluates Markdown or
metadata as code.

`load_packaged(root)` applies the same compiled pin to relocated package bytes.
The explicit `load(root: root)` API remains available for trusted callers that
select a different snapshot, including test fixtures; that call does not establish
the packaged source pin. The HTTP host uses the pinned default and accepts no
request-selected root or digest. A deliberate source refresh requires review and
recompilation.

The compiled catalog pin does not cover `priv/workflows`; workflow definitions
are validated separately, and signed adoption verifies their exact Biz-kit Git
commit and manifest bytes.

The standalone source checker additionally verifies the exact upstream Git
commit and reconstructs its complete tree. The source proof records identities
for non-Markdown source files without copying their bodies. Git object identity
binds this imported content to the chosen revision; it does not establish
semantic correctness or procedural approval, and the checker does not claim a
separate signing-key trust decision.

`BizOpsKB.Workflows` verifies the authored schema-2 workflow and its retained
SOP bundle against the selected catalog. The preview includes the tasks,
dependencies, individual completion criteria, source documents and exact input
digests. The manifest is JSON, a YAML-compatible representation accepted by the
existing blueprint reader. Downloaded bytes are the bytes whose digests appear
in the preview.

## Verify

From the repository root, with Python 3, Elixir 1.19, and OTP 27:

```sh
python3 scripts/bizops-kb/snapshot.py check
python3 -m unittest discover -s scripts/bizops-kb -p 'test_*.py'
elixir -r apps/bizops_kb/lib/bizops_kb/catalog.ex \
  -r apps/bizops_kb/test/test_helper.exs \
  apps/bizops_kb/test/catalog_test.exs
node --test apps/task_host/test/js/knowledge.test.mjs
```

The catalog test fixture supplies an explicit content root, so this verification
does not need the umbrella's runtime dependencies. HTTP/session acceptance runs
in the existing Operations workspace workflow with PostgreSQL and TaskHost.
With the normal umbrella dependencies installed, `cd apps/bizops_kb && mix test`
also exercises workflow validation. The dedicated BizOps acceptance workflow
compiles TaskCore outside the umbrella and runs both suites without downloading
the host's dependencies.

## Update from the authoring repository

Edit and review source in `bizops-kb`, then import an exact reviewed commit:

```sh
python3 scripts/bizops-kb/snapshot.py import \
  --source /path/to/bizops-kb \
  --revision <full-40-character-commit>
python3 scripts/bizops-kb/snapshot.py check
```

The importer reads Git objects at that commit, so unrelated working-tree edits
cannot enter the snapshot. It stages and verifies the new import before
replacing the generated files. It refuses an existing snapshot with local
changes. Review the resulting source revision and document diff in a biz-kit
PR. Update the recorded counts and pinned-source test when deliberately moving
to a new source revision.

The current update selects the November 14 custody revision: only the upstream
README and custody decision changed from the first imported revision. The
procedures `24.12` and `24.12d` retain their original bytes. A future catalog
revision makes a workflow unavailable unless its SOP bundle and source contract
are deliberately reviewed together; it never substitutes newer source bytes.

Authoring remains in `bizops-kb`; `priv/content` is a generated copy. Git review
publishes this fixed reference snapshot. No live SpruceGoose permission,
promotion receipt, or distribution obligation is transferred by this import.

Source custody, current reader access, and operational approval remain separate.
There is no live upstream subscription or per-document withdrawal command in
this reader. Revoking all configured workspace access or the identity session
refuses subsequent API reads. Withdrawing one published document requires a
reviewed snapshot update and host rebuild; previously delivered bytes cannot be
recalled. A future governed distribution adapter needs explicit publication,
installation policy, withdrawal, and replay acceptance through the common log.

## Office assistant onboarding workflow

Open **Workflow previews** in the library, or follow the related workflow from
`24.12` or `24.12d`. The version-1 adaptation has eight tasks: owner scope,
preflight, discovery, office setup, staff enrollment, training, admin handoff and
owner acceptance. Owner Part A precedes setup; Part B follows the witnessed
tests and handoff. Original product names remain in the source documents, and
the first task requires the owner to confirm the current stack and scope.

The authored manifest is
[`priv/workflows/office-assistant-onboarding-v1.json`](priv/workflows/office-assistant-onboarding-v1.json).
Its optional TaskCore readiness contract pins both original source digests and
the versioned SOP bundle. At signed adoption, TaskCore also binds the exact
manifest digest; generic readiness commands cannot change these inputs.

Governance can adopt a reviewed manifest from an explicitly selected commit
using `mix coop.blueprint --source-checkout /path/to/biz-kit`. The local Git
verifier hashes the commit, directory trees and blob, so working-tree edits
cannot replace the selected manifest. Adoption, operator run creation,
readiness, scoped artifact custody, SOP acknowledgement, evidence review and
completion retain their existing separate commands. No task is created by
browsing or downloading a preview.

See [the workflow contract and adoption instructions](../../docs/architecture/2026-11-14-bizops-kb-workflows.md).

[custody]: https://github.com/larsbx/bizops-kb/blob/8749d8db1abd3145b22c6a27da2cc49a41c303fe/docs/decisions/2026-10-30-source-custody-and-platform-storage.md
