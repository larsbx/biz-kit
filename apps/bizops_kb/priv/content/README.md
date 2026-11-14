# bizops-kb

> Storage decision (2026-10-30): [Knowledge source custody and disposable retrieval indexes](docs/decisions/2026-10-30-source-custody-and-platform-storage.md).
> Revised 2026-11-14 for SpruceGoose's migration into Biz-kit.
> Biz-kit owns the selected operational integration; knowledge-specific adapters
> and live authority cutover remain implementation work.

This repository is the canonical source knowledge base for business operations.
It is an Obsidian-compatible vault organized with the Johnny.Decimal Small
Business System taxonomy.

## Authority

- Recorded checkout path: `/home/admin-papa/bizops-kb` (setup location, not a live host inventory)
- Default branch: `main`
- Original governing task: `tsk-20260801T112717Z-b2c026df`
- Source custody: this Git repository retains the editable source bytes.
- Operational integration target: Biz-kit's common signed admission through
  `CoopSubstrate`, with `BizKit.Identity`, retained `TaskCore` rules, and the
  `task_host` interface. The decision maps their implemented responsibilities
  separately from the proposed knowledge publication and retrieval adapters.
- Applicable SOPs remain versioned policy inputs. SpruceGoose is a retiring
  runtime, not a permanent integration dependency or a source of inherited grants.
- A live legacy workflow changes owner only after its replacement, history,
  recovery and old-writer fence are verified. New read-only imports do not
  require SpruceGoose or completion of its entire decommission.
- Generated views, indexes, mirrors, and caches are non-authoritative.

## Integration with Biz-kit

Pinned, attributed copies may be imported into Biz-kit. Keep the source
repository, commit, tree, original path, content digest and Johnny.Decimal ID
with each imported document; record transformations and applicable visibility.
The copy is an imported view while this repository remains the editable source.
If authorship moves, record the new source owner for that corpus and end the
previous write path. Each corpus has one editable authority.

Reading or copying a document does not admit an operational SOP, publish it to
another audience, or authorize its execution. Follow the decision's source,
access, publication and cutover checks for those separate operations.

## Provenance

Initialized on 2026-08-01 from the supplied Johnny.Decimal SBS archive. The
import used its Obsidian JDex variant (`Shukr-Transport`) as the initial vault.
The package's version marker reports a download date of 2026-08-01.

## Use

Open a checkout of this repository as an Obsidian vault. Make source changes
here, verify them, and commit them to Git. Keep generated or published copies
traceable to their pinned source.
