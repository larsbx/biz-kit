# Historical restaurant key-collision audit

The audit finds retained events that would violate the key-separation rules
in [PR #429](https://github.com/larsbx/biz-kit/pull/429). It reads the canonical
`ledger` stream in global sequence order. It verifies event signatures and
both hash chains through the captured head, then returns a report only if the
sequence and hash match. It uses Membership's fold for grant and role history.
The audit runs on demand in a process separate from the appender.

## Run the audit

Use the following command on a running restaurant release containing the
audit module. Direct the output to a location appropriate for chapter,
merchant, tenant and key identifiers.

```sh
bin/restaurant rpc '
  case CoopSubstrate.RestaurantKeyAudit.scan() do
    {:ok, report} -> IO.puts(Jason.encode!(report, pretty: true))
    {:error, reason} -> raise "restaurant key audit failed: #{inspect(reason)}"
  end
'
```

`scan/0` captures the head from `CoopSubstrate.Log` once. To repeat a run
against the same prefix, pass the report's `as_of` to `scan/1` with atom keys
and the hex hash decoded to binary. Use `nil` for the empty ledger's hash.
Verification failures and missing prefixes yield an error. Scanning costs one
full read and signature audit of the captured prefix. Running it on a
restored copy isolates that work from an active deployment.

Run the synthetic, PostgreSQL-backed acceptance tests from
`apps/coop_substrate` with
`mix test test/restaurant_key_audit_test.exs --warnings-as-errors`.

## Interpret a report

`historical_violations` contains one finding per triggering event and rule.
A triggering event can match several rules. Each finding includes the SHA-256
fingerprint of the 32 public-key bytes, the triggering event, and all earlier
events that witness that rule. Each event includes its event ID, canonical
record hash, global and stream positions, chapter, event type, key ID, and
applicable merchant, tenant or role. `revoked_in` gives the exact revocation
event through the audited head, or `null` when the prefix contains none.
Compare its global sequence to the triggering event's sequence to tell when
the revocation occurred.

| Rule | Retained evidence |
| --- | --- |
| `device_dispatch_key_reuse` | A restaurant device grant and a restaurant Dispatch grant use the same key in the chapter. Revoked grants count in either order. |
| `dispatch_role_key_reuse` | A restaurant Dispatch grant uses a currently declared role key, or a role declaration uses a key previously granted to restaurant Dispatch in that chapter. The second order counts revoked Dispatch grants. |
| `dispatch_cross_tenant_key_reuse` | Restaurant Dispatch grants use the same key for different tenants in one chapter. Same-tenant reuse across merchants is allowed. |
| `merchant_key_reuse` | Restaurant device or Dispatch grants repeat the same key at one merchant within a chapter. Earlier grants count even after revocation. |

In the first three rows, the corresponding separation rejection for a new
admission is `:key_not_separate`. The last row corresponds to
`:restaurant_key_already_granted`. Normal admission checks can take
precedence. The report records matched conditions on committed events.

## Evidence limits

A zero count describes the verified prefix of the ledger supplied to the
scanner. Establish the source and expected head independently when auditing
a backup or export. Use request or appender logs to establish rejected
attempts, and deployment or writer records to establish which admission
version handled a historical event. Use key custody records and independent
usage evidence to establish who held a private key or acted with it.
Host-local credentials, retired systems, procurement Dispatch keys and
DispatchCore dispatcher grants require their own evidence and policy scope.
