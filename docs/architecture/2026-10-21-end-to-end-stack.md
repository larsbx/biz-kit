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
six role profiles, a second field profile (`COURIER`), and five people (a
`DRIVER`, a `DISPATCHER`, a `COURIER` and two `ADMIN`s, since no one may grant
themselves a role), and serves:

| | Where | What |
| --- | --- | --- |
| dispatch | `:4000` | `/v1`, the portal, its streams; `TOKEN_VERIFIER_ADAPTER=BizKitSession` |
| SpruceGoose | `127.0.0.1:4001` | `/auth`: native sign-in, `/auth/me`, `/auth/logout` |

Set `SPRUCE_GOOSE_PUBLIC_URL=http://10.0.2.2:4001` when an Android emulator
signs in: the development provider sends the browser back to that URL, and
the emulator reaches the host's loopback as `10.0.2.2`.

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

`scripts/e2e-stack.sh fixture revoke <tenant> <role_assignment_id>` ends an
assignment as an administrator would (scenario 16: a dispatcher loses the
operations stream on the next heartbeat).

## Limits

- Scenario 14's second profile is the test profile `Courier`, compiled in
  dev and test and allowlisted there only. A release compiles `lib` alone, so
  production can never name it.
- `/auth` limits sign-in requests per client (30 a minute). The tests sign
  each person in once and keep the session, as the app does.
- The development provider is the only one; a WorkOS round trip is covered by
  SpruceGoose's own tests with WorkOS stubbed.

## What the first runs found

Each of these passed dispatch's own suite and failed in a browser or under the
app's real request shapes. Each fix carries a dispatch test that fails without it.

- **No portal page ever opened its stream.** Datastar's attributes compile
  their expressions with `Function()`, which Section 26.1's `script-src 'self'`
  forbids. `priv/static/js/streams.js` opens the stream a page names with
  `data-dispatch-stream` and applies `datastar-patch-elements` by id: plain
  SSE, no expressions, no CSP change.
- **Every real `EventSource` got a 406.** The streams shared the pages'
  `accepts ["html"]`, and MIME has no extension for `text/event-stream`. They
  now use the same pipeline without content negotiation (`:portal_session`).
- **A refused declaration under an `Idempotency-Key` answered 500, then 422.**
  Ash rolls the ledger's transaction back itself, and `Declarations` then
  re-read inside the doomed transaction to look for a lost race. A refusal is
  not a race: it is answered as the 403 it is.
- **The login-state cookie was `Secure` over plain HTTP** in dev, so the
  callback never saw it. Dev, and only dev, sets `:secure_cookies false`.
