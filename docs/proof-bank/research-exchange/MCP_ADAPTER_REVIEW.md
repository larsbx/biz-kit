# Bounded MCP admission adapter — proposed changes

Prepared November 6, 2026 against main
`83954f1fbffbee1df5fb25e69ab3b34bc92346e8` (PR #325).

The project is a nonprofit, open source research exchange. Contributor benefits
are recognition and nonmonetary ecosystem credits. This proposal issues neither
credits nor awards. The old formal module names `Reward` and `Reservation` are
retained as published, reviewed mathematical definitions; they are not a new
monetary business model. Credit policy and its formal model require a separate
review before issuance. This adapter has no monetary settlement operation.

## Proposed implementation

| Component | Implemented behavior |
| --- | --- |
| Elixir domain server | Serialized, bounded in-memory admission; no production startup wiring |
| Authentication | Operator-provisioned opaque credentials; hashed registry; principal, expiry, scopes and library grants checked per operation |
| MCP stdio | Initialization/version negotiation, ping, tool discovery and tool calls; no HTTP listener |
| Library discovery | Authorized metadata for operator-reviewed, revision-pinned library snapshots |
| Proof submission | Exact revision, snapshot, generation, target and artifact digest; immutable UTF-8 artifact stored by value |
| Verification request | Exact submitted binding, random nonce, boot identity, five-minute expiry, internal worker capability and one memory-only capacity slot |
| Receipts | Canonical UTF-8 JSON; domain-separated SHA-256 and server HMAC; exact contributor/source/artifact/environment/policy/core binding |
| Internal observations | Separate worker and meter authentication, full binding validation, expiry and one-use replay fences; cumulative evidence receipts |
| Future persistence port | Expected-version transaction/outbox interface, documented but not implemented or installed |
| CI proposal | Scoped adapter formatting, compilation, tests and reviewed-core-source check; separate from mathematical acceptance |

Implementation: [`apps/research_exchange`](../../../apps/research_exchange).
Reproduction and the operator configuration contract are in its README.
No external dependencies are added. Python remains only in the existing proof
and CI tooling; the new service adapter and its tests are Elixir.

## Evidence assessed

Both original hosted core runs completed successfully. The local adapter results
below come from the November 6 review. The adapter workflow checks the PR head.

| Evidence | Observed result | Meaning |
| --- | --- | --- |
| [PR-head core run 42251647204](https://github.com/larsbx/biz-kit/actions/runs/42251647204) at `80eb34a0c0c07650f140bb392753dd053bd8212d` | Passed | Hosted core acceptance at the original PR head |
| [Merged-main core run 42252781785](https://github.com/larsbx/biz-kit/actions/runs/42252781785) at `83954f1fbffbee1df5fb25e69ab3b34bc92346e8` | Passed | Hosted core acceptance at the original merge commit |
| Fresh local complete core profile | All ten stages passed; no skipped stages | Acceptance evidence for the unchanged mathematical core on this trusted local host |
| New adapter suite | 29 executable tests, including an actual local stdio subprocess | Evidence for the tested adapter behavior; no universal theorem or production refinement claim |
| Formatting and warning-free compilation | Passed on Elixir 1.19.0 / OTP 27.3.4 | Source and compilation checks |
| Existing CI inventory regressions | Six tests passed; complete workflow inventory | Trigger coverage only, not hosted execution |

The core replay used the pinned Lean 4.35.0, Quint 0.33.1, Apalache 0.62.4 and
JRE distributions plus the already documented executable-location adapter. It
audited theorem axioms, exported and replayed 1,532 declarations with both the
official kernel and independent checker, passed four Lean negative controls,
51 existing Python tests, 1,898 differential traces / 3,856 states, two exhausted
bounded models, seven scenarios and four targeted model mutants.

Local core receipt SHA-256:
`c3955e0b9b0d8d64ceea57d7b5519882a7dc3e6e393911464f14c46095780c08`.
The review bundle contains that receipt and its evidence. The first attempted
replay refused a different cached Lean tree at the runtime hash gate. The retry
used the clean pinned installation and passed without changing source, runtime
pins or acceptance rules. No failed stage was relabeled as a pass.

The core source manifest remains unchanged at
`b22af2eb8fa3c7822faf6fac0d1cadd5cd0f65698865007671a5af48f9f50564`.
No new Lean theorem or Quint model is claimed for the adapter.

## Adversarial coverage

The suite exercises missing/expired/revoked credentials; independent scopes;
unauthorized library discovery/submission; forbidden contributor identity,
trusted-verifier and settlement fields; stale revision/snapshot/generation;
wrong artifact hash; altered receipts; identity substitution on reads and
verification; exact retries and conflicting key reuse; concurrent duplicate
requests; worker/meter/receipt credential separation; forged verifier claims;
every binding component substituted in signed worker observations; expired,
cross-job and cross-boot capabilities; environment changes; observation replay;
bounded artifacts/state; malformed internal observations; MCP initialization and
version fallback; non-effectful notifications; duplicate JSON keys, batches,
invalid IDs and oversized messages. Lean and Quint catalog admissions use the
same source-binding checks.

## Explicit limits and next integration obligations

The public Internet service is not implemented. Credentials are local operator
provisioning, not OAuth federation. Catalog hashes name approved snapshots and
environments; no actual library checkout or container materialization is done.
Submitted theorem names and artifacts are untrusted. No artifact is executed.

MAC-authenticated worker observations authenticate what a separately controlled
worker says; they do not prove honest execution, a theorem statement, physical
compute or a trustworthy machine. All receipts explicitly keep mathematical
acceptance and credit issuance false. The worker and meter ports are internal
host APIs, never MCP tools; OS/BEAM isolation is an explicit requirement.

Reservations, idempotency records and artifacts are memory-only and process-local.
Restart loses them. There is no reservation release, persistent ledger, atomic
settlement, global quota conservation, execution-stop acknowledgment, public
receipt signature, reward issuance or mapping into the core's `trusted = true`.
The adapter does not invoke `Reward.accept` or `Reservation.settle`.

Before public execution, implement and test immutable materialization, approved
environment provisioning, network-disabled Lean/Quint sandboxes and resource
limits, independent target/axiom/evidence checking, persistent version-fenced
reservation/outbox transactions, authenticated meter provenance, crash recovery
and current-grant revalidation. Specify a concrete representation relation to
the Lean states before claiming service refinement. Recognition and ecosystem
credit allocation remain separately governed, nonmonetary work.

## Related work

The loopback HTTP/SQLite pilot in [#335](https://github.com/larsbx/biz-kit/pull/335)
and the terminal rejection and refund extension in
[#336](https://github.com/larsbx/biz-kit/pull/336) exercise durable transactions
and disposable fixture credits. This draft targets `main` and keeps the MCP
admission protocol independently reviewable. Connecting the two requires a
separate representation and authorization review, including an update to the
reviewed core pin if the proof package changes.
