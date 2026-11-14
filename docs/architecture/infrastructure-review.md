# Review Ship and Keel evidence in Biz-kit

Open **Review infrastructure evidence** on an Operations workspace. Biz-kit
requires a current session and the workspace's existing project read grant
or chapter administrator access. Ship independently checks its own session
and baseline grant. Sign in at the Ship origin before opening the review link.

## Configure a fixture review

1. Start the isolated Ship fixture from the [pinned quickstart](https://github.com/larsbx/ship/blob/d75c158726110df0215552ef288118bb18a462d6/README.md#graft-source-review-quickstart).
   Set the synthetic catalog's repository label to `larsbx/biz-kit`.
2. Add `infrastructure_review` to the existing workspace object in
   `TASK_HOST_OPERATIONS_CONFIG`. Set `origin` to Ship's distinct
   browser-facing hostname and origin, `key` to the baseline key, and
   `record` to the exact corresponding Ship catalog entry. Use HTTPS for
   remote instances. For a local fixture, use different hostnames such as
   `localhost` for Biz-kit and `127.0.0.1` for Ship. Cookies are scoped by
   hostname across ports.
3. Set `TASK_HOST_KEEL_REVIEW_MANIFEST` to the local path of the exact
   [Keel manifest](https://github.com/larsbx/keel/blob/3a5f16476e8f0f5ed3290fa5c61b1d7be1b0badd/polyglot.manifest.toml)
   and restart Biz-kit. Biz-kit checks its bytes against the reviewed SHA-256
   before displaying the declared roles. A missing or changed file suppresses
   the declarations and leaves the Ship link available.

The Ship link includes the digest of the baseline key and complete record,
including repository, destination, recorded verifier, commit, tree, bundle
digest and result type. Biz-kit sends the browser directly to Ship. Ship
keeps the catalog, bundles and source access under its control. The digest
binds evidence and carries no access grant. Ship rejects changed bindings
with HTTP 409. After checking the new record, update the workspace
configuration and restart Biz-kit. During an outage, the browser reports
Ship's connection failure and Biz-kit continues to display its pinned link.

## Replay acceptance

Use Linux with Git, Python 3, `prlimit`, Erlang 27 and Elixir 1.19.
From the Biz-kit checkout, point `SHIP_CHECKOUT` to an authorized Ship
checkout at the reviewed revision:

```bash
test "$(git -C "$SHIP_CHECKOUT" rev-parse HEAD)" = d75c158726110df0215552ef288118bb18a462d6
PYTHONPATH="$SHIP_CHECKOUT" python3 apps/task_host/test/integration/ship_review.py -v
```

The replay uses the real Ship HTTP handler and a synthetic Git bundle. It
checks the exact revision, anonymous and unscoped access, stale evidence,
review-only authority and loss of Ship connectivity.

With the PostgreSQL test stores initialized as in the Operations acceptance
workflow:

```bash
cd apps/task_host
mix test test/task_host/operations_test.exs \
  test/task_host/web/operations_test.exs \
  test/task_host/web/infrastructure_review_test.exs
```

## Contracts for live integration

| Authority | Contract still needed |
| --- | --- |
| Source verification | Authenticated catalog export and signed upstream provenance tied to repository, revision, tree, bundle, verifier, and trusted runner identity |
| Identity | Reviewed identity mapping, grant revocation, and scoped sign-in handoff between Biz-kit and Ship |
| Proof acceptance | Canonical proof receipts tied to exact revision, obligations, checker and toolchain. Versioned Keel compatibility and normalization vectors for new manifests |
| CI authority | Canonical required-check evidence tied to the exact revision and workflow identity |
| Deployment approval | Independently authorized approval for the exact signed release, target, and target generation |
| Deployment execution | Live target adapter with durable fencing, audited execution, health checks and rollback evidence |
