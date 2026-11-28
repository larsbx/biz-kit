# Chapter key-collision audit

The audit finds retained events that the chapter key fence
(`CoopSubstrate.KeyFence`) would refuse today: within
a chapter, a public key bound by two holders, or by two restaurant grants the
fence keeps apart. It reads the canonical `ledger` stream in global sequence
order, verifies event signatures and both hash chains through the captured
head, and returns a report only if the sequence and hash match.

The audit is the fence replayed. It folds the appender's own admission gate
over the verified prefix and, before each key event folds, asks the fence
which rules that event breaks against the gate its prefix left. A finding
therefore exists at exactly the events the current fence refuses, whatever
appender admitted them. It covers restaurant device and Dispatch grants,
declared role keys, dispatcher grants and procurement route and operator
keys. The module keeps its original name, `CoopSubstrate.RestaurantKeyAudit`.

## Run the audit

Every release that carries the ledger has the entrypoint. It runs read-only
and never needs the appender: only EventStore's read client starts, in
read-only PostgreSQL sessions. Give it the release's runtime environment and
`EVENTSTORE_*` settings, and direct the output to a location appropriate for
chapter, merchant, tenant, cooperative and key identifiers.

```sh
# From a release copy, beside a running node or with none:
bin/restaurant eval 'CoopSubstrate.ReleaseTasks.audit_keys()'
bin/procurement eval 'CoopSubstrate.ReleaseTasks.audit_keys()'

# On a host that runs from a checkout:
mix run --no-start -e 'CoopSubstrate.ReleaseTasks.audit_keys()'

# On a running node, reusing its EventStore client:
bin/restaurant rpc 'CoopSubstrate.ReleaseTasks.audit_keys()'
```

It audits the ledger's stored head and prints the report as JSON. It exits 0
when no finding is open. When a finding is open it raises after printing
(`key audit: N open finding(s) of M`), and it raises without a report when the
prefix does not verify or the head does not match (`key audit refused: ...`).
Either way `eval` and `mix run` exit non-zero. It never halts the VM, so under
`rpc` the raise ends only the calling VM and the running node is untouched.

To repeat an audit against the same prefix, for example on a restored copy,
pass the report's `as_of` as `audit_keys(as_of: "SEQ:HEX")`: the global
sequence and the hex global hash, joined by a colon (`0:` for an empty
ledger). Capture the same form from the live appender with:

```sh
bin/restaurant rpc 'h = CoopSubstrate.Log.head(); IO.puts("#{h.global_seq}:#{h.global_hash && Base.encode16(h.global_hash, case: :lower)}")'
```

An audit costs one full read and signature audit of the prefix, the same as
a boot; a restored copy isolates that work from an active deployment.
`RestaurantKeyAudit.scan/0` and `scan/1` still return the report from Elixir.

Run the synthetic, PostgreSQL-backed acceptance tests from
`apps/coop_substrate` with
`mix test test/restaurant_key_audit_test.exs test/key_fence_agreement_test.exs --warnings-as-errors`.
The appender-free entrypoint is tested by
`scripts/retirement_preflight_acceptance.exs --restore`, and in a packaged
release beside its running node by `scripts/restaurant-release-smoke.sh`.

## Run order

Run it once per ledger: restaurant, procurement, and any other ledger with
these keys.

1. Before upgrading, run the new release copy's `eval` against the live
   database, or against a restored copy for a large ledger. It applies the new
   rules whatever appender is live. Remediate open findings first, especially
   procurement collisions: once the fence runs, renewing a colliding route or
   operator grant is refused until its key is rotated.
2. Deploy the fenced release as the singleton appender.
3. Run it again, to cover events admitted between the two runs.
4. Re-run after each remediation until it exits 0. Closed findings stay
   listed, because grants and procurement versions keep counting.

## Interpret a report

The report has the schema `restaurant-key-collision-audit.v2`, its `as_of`
head, `historical_violations`, `violation_count` and `open_count`.

`historical_violations` contains one finding per triggering event and rule,
in ledger order. A triggering event can match several rules. Each finding
includes the rule, the `refusal` the fence gives a new event that breaks it,
the SHA-256 fingerprint of the 32 public-key bytes, the triggering event, all
earlier events that witness that rule, `open` and `remediation`.

Each event includes its event ID, canonical record hash, global and stream
positions, chapter, event type, key ID, its `class`, and the applicable
merchant, tenant, role, cooperative, operator or dispatcher. `revoked_in`
gives the exact grant or role-key revocation through the audited head, or
`null`. Compare its global sequence to the triggering event's sequence to tell
when the revocation occurred. `active_at_head` tells whether the binding
still holds at the head:

- a restaurant grant until it is revoked;
- a role key while it is still declared on that key;
- a dispatcher always, since dispatcher grants are never revoked;
- a procurement route or operator slot while its current version is active on
  that key.

A finding is `open` while any of its bindings is active at the head. The seed
sat with two holders, so the finding closes only once that seed is retired
from every binding involved, even one that looked legitimate on its own.

| Rule | Retained evidence | Refusal |
| --- | --- | --- |
| `device_dispatch_key_reuse` | A restaurant device grant and a restaurant Dispatch grant use the same key in the chapter. Revoked grants count in either order. | `key_not_separate` |
| `device_role_key_reuse` | A restaurant device grant uses a currently declared role key, or a role declaration uses a key previously granted to a device in that chapter. The second order counts revoked grants. | `key_not_separate` |
| `dispatch_role_key_reuse` | The same, for a restaurant Dispatch grant. | `key_not_separate` |
| `dispatch_cross_tenant_key_reuse` | Restaurant Dispatch grants use the same key for different tenants in one chapter. Same-tenant reuse across merchants is allowed. | `key_not_separate` |
| `merchant_key_reuse` | Restaurant device or Dispatch grants repeat the same key at one merchant within a chapter. Earlier grants count even after revocation. | `restaurant_key_already_granted` |
| `holder_key_reuse` | Two holders bind the same key in the chapter: the restaurant (grants and role keys), a dispatcher grant, a cooperative's procurement route, or the procurement operators. Grants and dispatchers count forever, role keys while declared, and every active procurement version even once rotated away or deactivated. One operator key serving several cooperatives is one holder. | `key_not_separate` |

Normal admission checks take precedence over the fence. The report records
matched conditions on committed events.

`remediation` lists one step for the class of each binding still active at
the head:

| Class | Remediation |
| --- | --- |
| `restaurant_device` | Revoke the grant with `restaurant.manage revoke-device`, then enroll a new key ID with a new seed. |
| `restaurant_dispatch` | Revoke the grant, then `grant-dispatch` a new key ID with a new seed file on the Dispatch machine. |
| `governance_key` | Declare a replacement governance key, then revoke this one (`RoleKeyRevoked`) from an administrator browser or with `mix coop.owner.succeed`, never the chapter's last one. The seed has been on another machine: rotate it even once the other binding is revoked. |
| `role_key` | No shipped command revokes a steward, checkpoint or setoff-reviewer key: governance signs its `RoleKeyRevoked`. |
| `dispatcher` | No ledger revocation exists. Retire the seed off the ledger; the finding stays open. |
| `procurement_route`, `procurement_operator` | Enroll the slot with `ProcurementHost.ReleaseTasks.enroll` at its next `expected_version`, inactive or on a fresh key ([procurement host](2026-11-08-procurement-mvp-host.md)). The fence never refuses a deactivation, and a fresh key has no other holder. |

## Evidence limits

A zero count describes the verified prefix of the ledger supplied to the
scanner. Establish the source and expected head independently when auditing
a backup or export. Use request or appender logs to establish rejected
attempts, and deployment or writer records to establish which admission
version handled a historical event. Use key custody records and independent
usage evidence to establish who held a private key or acted with it.

Each ledger is audited alone. A seed shared across ledgers, such as a
Dispatch key used by both a restaurant and a procurement ledger, is invisible
to it. Host-local credentials and retired systems require their own evidence
and policy scope.
