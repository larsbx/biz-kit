# Rate limits

Date: 2026-10-19. Status: **implemented**. Closes the limit noted in
[device enrolment](2026-10-19-device-enrolment.md) and
[device revocation](2026-10-19-device-revocation.md).

## Decision

Every request SpruceGoose serves is limited per client
(`SpruceGoose.Web.RateLimit`). The limiter is plugged into the endpoint
ahead of `Plug.Parsers`, so a throttled request is refused before its body
is read, and requests for paths with no route count too. The path decides
the bucket:

| Bucket | Paths | Default |
| --- | --- | --- |
| `:sign_in` | `/auth/*`, `/oauth/*`, `/.well-known/*` | 30 per minute |
| `:capability` | `/api/v1/enrolments/*`, `/api/v1/grants/*`, `/api/v1/principals/*`: no session; a code, grant or principal ID, and a governance signature where one is needed | 60 per minute |
| `:api` | everything else: the web view, `/api/v1/commands/:id`, device challenges, everything under a project (feed, commands, devices), MCP | 600 per minute |

Beyond its limit a client gets `429 {"error": "rate_limited"}` with
`retry-after` in seconds, and the request goes no further: no body is
parsed, no controller runs and nothing is held or looked up. Each bucket counts separately, so a
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
`10.0.0.0/8,fd00::/8`. A malformed entry, such as a prefix outside 0–32
for IPv4 or 0–128 for IPv6, stops the server: a bad entry could otherwise
make every client a trusted proxy, free to pick its own key.

## The client

The client is the peer address. Behind a reverse proxy every peer is the
proxy, so for a peer inside `trusted_proxies` the client is the rightmost
`x-forwarded-for` address that is not itself a trusted proxy: the nearest
hop no trusted proxy vouches for. An untrusted peer's `x-forwarded-for` is
ignored, so a client cannot choose its own key. If the header is not an
address, the last trusted hop counts the request, which is stricter rather
than looser.

## Verification

`SpruceGoose.Web.RateLimitTest` (11 tests, through the endpoint as served):
- Beyond its limit a client gets 429 with `retry-after`; another client, and
  another bucket for the same client, are unaffected.
- A new window starts afresh, and ended windows are swept.
- **Before the body.** A throttled client posting malformed JSON or a large
  body gets 429 and no parsing. Moving the limiter after `Plug.Parsers`
  fails this test.
- **Every route counts.** With every limit at zero, each route the router
  lists, and a path with no route, answers 429.
- The path decides the bucket, offboarding's `/api/v1/principals/*`
  included.
- Clients behind proxies:
  - forwarded IPv4 and IPv6 clients are told apart;
  - an untrusted peer's header is ignored;
  - a malformed header falls back to the last trusted hop;
  - CIDR parsing, refusing prefixes out of range.

The rest of the suite runs with limits set out of reach (`config/test.exs`).

## Limits

- Counts live in memory, in one process for the whole [cluster](2026-10-19-cluster.md), so a
  client's limit holds however its requests are spread over the nodes. If
  that process moves, counting starts afresh.
- Limits are per address. Many people behind one NAT share a bucket; the
  defaults leave room for that, and they are configuration.
