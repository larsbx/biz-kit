# BizKit.ExtensionV1 — nonmutating host-contract slice

This portable OTP app strictly validates Version 1 manifests and builds a
deterministic, explicit-module catalog. No runtime code loading, activation,
permissions, migrations, ledger append or persistence is performed.

* BizKit.Extension: manifest behaviour for compiled integrated applications.
* BizKit.Extension.Manifest.validate/1: namespace and writer enforcement,
  duplicate refusal, version checks and declared-grant consistency.
* BizKit.Extension.Catalog.build/1: explicit-module registry, minimum-version
  dependencies, deterministic topological order and fail-closed cycle checks.
* BizKit.Extension.Catalog.activation_plan/2: inert approved-only plan;
  it neither starts applications nor creates grants.

Manifest dependencies represent other extensions; ordinary Mix/OTP dependencies
are declared independently in the consuming application's mix.exs.
SchoolOps.Extension and Dispatch.Extension are read-only reference descriptors.
The schema for external consumers lives at
docs/contracts/biz-kit-extension-v1.schema.json.

Standalone test:

    cd apps/biz_kit_extension && mix test --no-start

Umbrella contract validation (compile without booting domain applications):

    mix run --no-start scripts/check-extension-contract.exs

See docs/architecture/2026-10-31-extension-v1-first-slice.md for incomplete
runtime, authorization, external compatibility and migration obligations.
