# ExtensionV1 first implementation slice

Date: 2026-10-31. Scope: NONMUTATING, COMPILE-TIME INTEGRATION ONLY.

Implements the first slice of the October 28 cross-repository extension ADR.
This is not a production plugin loader, application runtime or ledger cutover.

## Delivered

- Independently compilable, dependency-free biz_kit_extension OTP package.
- Strict Version 1 manifest with domain ID and implementation version, extension
  dependencies, declared capabilities and requested grants, command/event owner,
  projections, migrations, deployment, manual activation and host health mode.
- Rejection of unrecognized fields, invalid version and identifier formats,
  unqualified or duplicate names, foreign business writers, commands requiring
  undeclared grants, missing/outdated dependencies and cycles.
- Deterministic catalog over explicitly supplied compiled modules with a dry-run
  manual approval plan. No privilege is created by a declaration.
- SchoolOps and Dispatch reference descriptors. Both currently have no
  extension-registered commands/events; operational commands remain governed
  by existing domain authentication and admission.
- External JSON Schema for the common descriptor format and a CI workflow
  for core tests, real host descriptors and independent portability.

A projection may refer to another domain's event but cannot own that event.
The host does not dynamically load or discover modules from untrusted names.

## Remaining safety and integration obligations

1. Implement host lifecycle, actual enable/disable, failure isolation, health,
   rollback and source-pinned approval. Current activation_plan returns data only.
2. Implement authenticated external manifest negotiation, source provenance,
   error compatibility and a second-language client conformance harness.
3. Bind SchoolOps and Dispatch commands to real signed, scoped ledger admission.
   Add revocation, replay, idempotency, concurrency and negative permission tests
   at the actual writer; no parallel domain authority.
4. Enforce global event ownership and safe migration/revision compatibility
   at deployment; local namespace checks are not full writer-cutover evidence.
5. Preserve the open Eatsbot salvage R0–R6 gates until source/history/obligation
   reconciliation, client parity, verified single-writer cutover and retirement.
6. Obtain exact-head hosted CI and review. Unit and schema checks alone do not
   prove deployed interoperability, ledger acceptance, student data safety or
   financial operations.

Hawala retains independent financial semantics; this extension package does
not enable a financial writer or sign on behalf of a participant.
