# The end-to-end stack

Date: 2026-10-21. Status: **implemented** in `scripts/e2e-stack.sh`,
`apps/dispatch/priv/repo/e2e.exs` and `BizKit.Identity.Providers.Development`.
Its tests are d-patch's (`e2e/`, Section 33.4 of its specification), which run
the portal in Chromium, the field app's protocol as an HTTP client, and the
real app on an emulator, against this stack.

## One command

```
scripts/e2e-stack.sh            # fresh databases, fixtures, then serve
scripts/e2e-stack.sh --prepare  # fresh databases and fixtures only
```

It needs PostgreSQL with PostGIS on localhost. It drops and recreates the
event store, SpruceGoose's and dispatch's databases, seeds a carrier with its
six role profiles and two people (a `DRIVER` and a `DISPATCHER`), and serves:

| | Where | What |
| --- | --- | --- |
| dispatch | `:4000` | `/v1`, the portal, its streams; `TOKEN_VERIFIER_ADAPTER=BizKitSession` |
| SpruceGoose | `127.0.0.1:4001` | `/auth`: native sign-in, `/auth/me`, `/auth/logout` |

`.e2e/stack.json` tells the tests who is who: each person's provider name,
principal, participant and role assignment, and the tenant.

## Signing in without a provider

Each seeded person is a provider name (`/auth/driver/…`, `/auth/dispatcher/…`)
backed by `BizKit.Identity.Providers.Development`, which sends the browser
straight back to the callback as that person. It works only where
`:allow_development_provider` is set, which `runtime.exs` does for `:dev`
alone; no release sets it. Everything after the provider is the real flow:
PKCE, the one-time code, a native session that lasts until sign-out, bindings
to principals, and dispatch's `/v1` checks.

## Fixtures during a run

`mix run priv/repo/e2e.exs revoke <tenant> <role_assignment_id>` ends an
assignment as an administrator would (scenario 16: a dispatcher loses the
operations stream on the next heartbeat).

## Limits

- Scenario 14's second role profile (`Courier`) compiles only in dispatch's
  test environment, deliberately; the dev stack does not have it.
- The development provider is the only one; a WorkOS round trip is covered by
  SpruceGoose's own tests with WorkOS stubbed.
