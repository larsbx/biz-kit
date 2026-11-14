# Business knowledge catalog

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
| Pinned revision | `ca356e34e6b1c4a2fb9f576c34196ca3bf13beee` |
| Source tree | `7a29785f90feca8871da0b14b6fcd76401fc8278` |
| Imported Markdown bytes | 93,482 |
| Resolved wiki links | 45 |
| Operational meaning | Shared reference material; no SOP adoption or execution authority |

Many entries are filing-category scaffolds. Longer procedures record particular
deployment or commercial choices at their source revision. Their presence does
not establish current implementation, production acceptance, or approval to
perform an action. Current business policies still govern actual workflows.

The app has no network client, database, writer, worker, or agent invocation.
The host requires a current Operations session and access to a configured
workspace. This is one shared, intentionally published reference corpus;
folder names and terms such as "restricted" in procedure text are not document
access-control labels. Company-private records need a separate scoped
publication design before they are added.

## Read API

`BizOpsKB.Catalog.load/1` reads the manifest and verifies every retained
document's SHA-256, Git blob identity, size, path, and UTF-8 encoding. It refuses
the complete catalog if any document is missing or inconsistent. The catalogue
supports bounded text search, area/category filtering, stable-ID lookup, and
unambiguous Obsidian wiki-link resolution. It never evaluates Markdown or
metadata as code.

The standalone source checker additionally verifies the exact upstream Git
commit and reconstructs its complete tree. The source proof records identities
for non-Markdown source files without copying their bodies. Git object identity
binds this imported content to the chosen revision; it does not establish
semantic correctness or procedural approval, and the checker does not claim a
separate signing-key trust decision.

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

Authoring remains in `bizops-kb`; `priv/content` is a generated copy. Git review
publishes this fixed reference snapshot. No live SpruceGoose permission,
promotion receipt, or distribution obligation is transferred by this import.

## Workflow follow-up

The deployment procedure `24.12` and its owner sign-off `24.12d` are a concrete
candidate for a later reviewed workflow. Author a real schema-2 YAML blueprint
at a safe ASCII source path, bind exact SOP bytes through TaskCore readiness,
and use signed admission plus existing evidence review. The original vault
paths remain intact. A retrieved document and a generated draft workflow never
substitute for that adoption step.
