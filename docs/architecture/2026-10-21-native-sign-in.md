# Native sign-in: apps get a biz-kit session

Date: 2026-10-21. Status: **implemented** in `BizKit.Identity`
(`NativeLogins`), SpruceGoose's `AuthController`, and dispatch's
`Dispatch.Identity.Tokens.BizKitSession`. The first client is the d-patch
Android field app.

## Why

[Identity](2026-10-18-identity.md) gives a person a biz-kit principal and a
session, but the session is a browser cookie. A native app cannot hold that
cookie, and dispatch's `/v1` API, which the field app calls, verified only
tokens from its own OIDC issuer. The field app therefore had no way to sign in.

## Decision

biz-kit brokers sign-in for native apps, following OAuth 2.0 for Native Apps
(RFC 8252) with PKCE (RFC 7636). The app never talks to the provider and never
learns which provider it is:

```
app ── system browser ──► GET  /auth/:provider/native/login?redirect_uri&code_challenge&code_challenge_method=S256&state
                              → provider sign-in (WorkOS today), state cookie set
browser ◄── provider ──── GET  /auth/:provider/callback        (shared with web sign-in)
                              → 302 redirect_uri?code=…&state=…   (or error=access_denied)
app ─────────────────────► POST /auth/token  grant_type=authorization_code, code, code_verifier, redirect_uri
                              → {access_token, token_type: "Bearer"}   (no expires_in: until signed out)
app ─────────────────────► dispatch /v1 …   Authorization: Bearer <access_token>
```

- **The access token is a biz-kit session that lasts until the person signs
  out** (decided 2026-10-21). It has no time limit, unlike a browser's
  one-hour session, and is kept by hash in SpruceGoose's Postgres
  (`BizKit.Identity.SessionStore`, `SpruceGoose.Web.NativeSessionStore`), so a
  restart or a move of the session process does not end it. Native tokens are
  `nat_`-prefixed, so a browser's cookie never reaches the store. The identity
  is still resolved again on every use: logging out, revoking the principal's
  sessions or removing the binding ends the app's access at once, in
  SpruceGoose and in dispatch (whose claims carry `expires_at: nil`).
- **Redirect URIs are allowlisted** (`:native_redirect_uris`,
  `BIZKIT_NATIVE_REDIRECT_URIS`), matched exactly. A request that fails a check
  gets a `400` and is never redirected anywhere (RFC 6749 §4.1.2.1).
- **Only `S256`.** A `plain` challenge is the verifier itself, readable by any
  app registered for the same private-use scheme.
- **One-time, short-lived, bound.** A request lives ten minutes and completes
  once, through the provider it began with. A code lives sixty seconds, is spent
  by its first exchange whether right or wrong, and works only with the verifier
  that started the sign-in and the redirect URI it was issued for. The identity
  is resolved again at the exchange, so a binding removed in between yields no
  session.
- **A denied sign-in still returns to the app**, with `error=access_denied` and
  the app's `state`; the reason stays in the log.
- **Dispatch accepts the session** through a token-verifier adapter
  (`TOKEN_VERIFIER_ADAPTER=Dispatch.Identity.Tokens.BizKitSession`). The subject
  is the principal (`prn_…`); a dispatch user acting through biz-kit is
  registered with that principal as its `oidc_subject`. Nothing is matched on
  email.

`/auth/me` and `/auth/logout` accept the bearer session, so the app can learn
its principal (the `sub` its capability document is bound to) and sign out.
Nowhere else in SpruceGoose does an `Authorization` header mean a session:
there it still means a signed request.

Each session also records when the person signed in (`authenticated_at`),
kept with a native session across restarts, so an operation that needs a
recent sign-in can ask (2026-10-22-role-administration.md).

## Rejected alternatives

| Alternative | Why not |
| --- | --- |
| The app runs PKCE against WorkOS directly; dispatch verifies WorkOS JWTs | The app and dispatch would both be bound to the provider, and replacing it would mean an app release. Identity's rule is that a provider change changes how sessions start, nothing else |
| SpruceGoose's local OAuth 2.1 server (AshAuthentication) | It is a removal target in [one source of truth](2026-10-11-single-source-of-truth.md); new clients must not deepen it |
| A long-lived refresh token | A second credential with its own revocation story; a durable session that lasts until sign-out gives the same continuity with one credential |
| A one-hour session, re-signed in through the browser | The first version. A shift outlasts it, and a restart signed every device out |
| Accept `plain` PKCE for older clients | Every supported Android release has SHA-256 |

## Limits

- Requests and codes live in memory in one process for the
  [cluster](2026-10-19-cluster.md); a restart loses sign-ins in flight, which
  are simply begun again. Native sessions are cached there and kept in Postgres.
- A stolen device token works until the person signs out, the principal's
  sessions are revoked, or the binding is removed. That is the price of no
  time limit; device revocation and the signed device key bound what it can do.
- Dispatch selects one token verifier. A deployment that turns this on stops
  accepting its former OIDC issuer's tokens on `/v1`.

## Verification

- `BizKit.Identity.DurableSessionsTest` (8): no time limit; surviving a
  restart of the session process with only a hash stored; logout, principal
  revocation and unbinding ending it, restart or not; browsers' sessions
  keeping their limit and never stored or looked up there.
- Mutations: removing the read-back, the stored deletion on logout or
  revocation, the absent time limit, the native-only lookup or the hashing each
  fails a test.

- `BizKit.Identity.NativeSignInTest` (9): the round trip; redirect, method,
  challenge and state checks before anything is stored; a code without its
  verifier, at another redirect, twice, or made up; denial without a code;
  single-use requests bound to their provider; unbinding before the exchange;
  RFC 7636 Appendix B's S256 vector.
- Mutations: removing the PKCE check, the redirect match, the re-resolution,
  single use, the `S256`-only rule, the allowlist, or the provider binding each
  fails a test.
- `SpruceGoose.Web.NativeSignInTest` (10): a session surviving a restart until
  sign-out, against Postgres; the browser round trip over HTTP to a
  bearer session, `/auth/me` and bearer logout; refusals; a request that fails
  validation never redirects; the shared callback still needs the browser's own
  state; web sign-in unchanged.
- `Dispatch.Identity.Tokens.BizKitSessionTest` (5): a session yields its
  principal; logout, revocation and unbinding end it; expiry is reported; and
  over `/v1`, a biz-kit session reaches the principal's dispatch user and is
  refused once it ends.
