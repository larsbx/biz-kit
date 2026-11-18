# ExtensionV1: fail-closed descriptor visibility registry

Date: 2026-11-01. Status: **staged read-only process; not production activation**.

Following merged [ExtensionV1 PR #224](https://github.com/larsbx/biz-kit/pull/224),
the portable contract gains a supervised-compatible `BizKit.Extension.Registry`
process. A trusted host passes a fixed list of compiled descriptor modules;
the registry validates the complete catalog on startup and begins with every
descriptor **hidden**. It is deliberately not started automatically in
`biz_kit_extension`'s OTP application or platform releases.

The registry provides:
- Deterministic installed and visible descriptor inventories.
- Atomic replacement of visible IDs, dependent-before-parent prevention and
  deterministic topological ordering by the validated Catalog.
- Manifest lookup only for visible IDs; invalid transitions leave prior
  visibility untouched.
- Fail-closed restart: no visibility survives a crash or process restart.
- Unit tests for dependency enforcement, invalid/untrusted module identifiers,
  duplicate extensions, independent host instances and lost ephemeral state.

**Important boundaries:** This registry modifies only metadata visibility.
It cannot activate or stop a domain OTP application, grant a principal
permission, commit events, approve a migration or bind a command handler. A
local caller can request visibility, so this must **not** be presented as a
security enforcement boundary or as signed governance approval. The registry
does not load remote module names; the host allowlist must be trusted compiled
code. Existing SchoolOps and Dispatch functionality is unchanged.

## Next acceptance obligations (issue #225)

1. Authenticate and durably bind deployment approval to a pinned extension
   package, manifest revision and governance scope before any actual activation.
2. Add a supervised runtime lifecycle with health, isolation and rollback,
   never executing untrusted code on the host via manifest identifiers.
3. Route admitted extension commands through *existing* principal/grant and
   signed-ledger append checks, with revocation and duplicate/retry regression.
4. Prove external protocol compatibility with an independently deployed client
   and validate migration/writer ownership against real operational authorities.
5. Gate all changes on exact-head CI. Passing read-only registry tests does
   not satisfy production lifecycle or financial/learner privacy acceptance.
