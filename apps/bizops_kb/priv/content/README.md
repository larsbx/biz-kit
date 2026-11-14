# bizops-kb

> Storage decision (2026-10-30): [Knowledge source custody and disposable retrieval indexes](docs/decisions/2026-10-30-source-custody-and-platform-storage.md).
> Selected integration target; implementation and cutover remain gated.
> Current services, permissions and durable owners remain in force.

This repository is the canonical source knowledge base for business operations.
It is an Obsidian-compatible vault organized with the Johnny.Decimal Small
Business System taxonomy.

## Authority

- Canonical path: `/home/admin-papa/bizops-kb`
- Default branch: `main`
- Governing task: `tsk-20260801T112717Z-b2c026df`
- Source custody: this Git repository retains the editable source bytes.
- Operational admission, provenance, promotion, and distribution remain
  governed through SpruceGoose and the Systemwide SOP.
- Generated views, indexes, mirrors, and caches are non-authoritative.

## Provenance

Initialized on 2026-08-01 from the supplied Johnny.Decimal SBS archive. The
import used its Obsidian JDex variant (`Shukr-Transport`) as the initial vault.
The package's version marker reports a download date of 2026-08-01.

## Use

Open `/home/admin-papa/bizops-kb` as an Obsidian vault. Make source changes
here, verify them, and commit them to Git. Do not edit a generated or published
copy as though it were authoritative.
