# ExtensionV1 semantic upgrade assessment

Date: 2026-11-02. Stage: **portable compatibility policy; no deployment activation**.

`BizKit.Extension.Upgrade.assess/2` compares two strictly validated V1
manifests and emits a deterministic migration-review result.

The safe same-major path preserves extension identity, every existing
command/event/projection declaration and its owner/grants/source mapping,
existing dependency/version requirements, and published capability/grant/
migration names. Removed or modified contracts require a separately reviewed
breaking migration and do not pass this path.

New capabilities, grant *requests*, commands, events, projections and
dependencies are **reported** as additions. Any changed manifest needs explicit
review even if every addition is structurally compatible. These are requests,
not grants. A declared capability never authorizes a business write. The
upgrade checker also rejects source version regression and manifest edits
without a version bump.

This intentionally does not run migrations, start or stop domain applications,
update the registry, verify signed current approvals, compare database records,
or admit events. Merged ReleaseLock PR #260 provides source and manifest fingerprints;
neither result is deployment authorization.
SchoolOps and Dispatch's existing operational authorities remain unchanged.

Next: a trusted build/host process must check the reviewed release lock, actual
source artifact provenance, and a current governance-signed deployment command
in the canonical ledger before any executable activation. Command admission
must independently recheck current scoped business grants at its own writer.
