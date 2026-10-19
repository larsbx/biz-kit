# Rate limits

Date: 2026-10-19. Status: **implemented**. Closes the limit noted in
[device enrolment](2026-10-19-device-enrolment.md) and
[device revocation](2026-10-19-device-revocation.md).

## Decision

Every route SpruceGoose serves is limited per client
(`SpruceGoose.Web.RateLimit`), in one of three buckets:

| Bucket | Routes | Default |
| --- | --- | --- |
| `:sign_in` | `/auth/*`, the OAuth consent and protocol routes | 30 per minute |
| `:capability` | `/api/v1/enrolments/*`, `/api/v1/grants/*`: no session, a code or grant ID is the capability | 60 per minute |
| `:api` | the web view, `/api/v1/commands/:id`, device challenges, everything under a project (feed, commands, devices), MCP | 600 per minute |

Beyond its limit a client gets `429 {"error": "rate_limited"}` with
`retry-after` in seconds, and the request goes no further: no controller
runs and nothing is held or looked up. Each bucket counts separately, so a
client that exhausts sign-in can still use the API.

Limits are a backstop against guessing and flooding, not access control.
Who may do what is still decided by sessions, signatures and the ledger's
grants. The memory bounds already in place (held commands per owner,
enrolment requests) stay.

## Counting

A fixed window per bucket and client: one `:ets.update_counter/4` per
request, so counting is atomic without a process in the path. Windows that
have ended are swept every minute. A fixed window lets a client make up to
twice its limit across a window boundary. That is acceptable for a backstop,
and much simpler than a sliding window.

Configuration is read on every request:

```elixir
config :spruce_goose, SpruceGoose.Web.RateLimit,
  limits: %{sign_in: {30, 60_000}, capability: {60, 60_000}, api: {600, 60_000}},
  trusted_proxies: []
```

At runtime, `SPRUCE_GOOSE_TRUSTED_PROXIES` sets the proxies, for example
`10.0.0.0/8,fd00::/8`.

## The client

The client is the peer address. Behind a reverse proxy every peer is the
proxy, so for a peer inside `trusted_proxies` the client is the rightmost
`x-forwarded-for` address that is not itself a trusted proxy: the nearest
hop no trusted proxy vouches for. An untrusted peer's `x-forwarded-for` is
ignored, so a client cannot choose its own key. If the header is not an
address, the last trusted hop counts the request, which is stricter rather
than looser.

## Verification

`SpruceGoose.Web.RateLimitTest` (9 tests):
- Beyond its limit a client gets 429 with `retry-after`; another client, and
  another bucket for the same client, are unaffected.
- A new window starts afresh, and ended windows are swept.
- **Every route has a bucket.** With every limit at zero, each route the
  router lists answers 429. Removing a scope's limit fails this test and
  names the routes. Routes added later to an existing scope, such as
  offboarding's `/api/v1/principals/*` in the capability scope, are covered
  by the same check.
- Clients behind proxies:
  - forwarded IPv4 and IPv6 clients are told apart;
  - an untrusted peer's header is ignored;
  - a malformed header falls back to the last trusted hop;
  - CIDR parsing.

The rest of the suite runs with limits set out of reach (`config/test.exs`).

## Limits

- Counts live in this node's memory, like sessions and held commands.
  Several nodes would each count their own share, so a deployment with more
  than one needs a shared store (one of the open items).
- Limits are per address. Many people behind one NAT share a bucket; the
  defaults leave room for that, and they are configuration.
