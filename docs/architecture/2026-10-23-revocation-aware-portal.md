# Revocation-aware portal authentication

Focused follow-up to the portal P1 in `docs/roadmap.md`, based on main
`29d3462` (merged PR #66).

## Binding and validation

Identity stores session rows under `{native?, SHA256(token)}`, rather than the
bearer token. Public bearer lookups hash their input. A portal reference is
`wsr_` or `nsr_` followed by base64url SHA256(token); supplying that reference
as a bearer hashes it again and does not authenticate. References are internal
lookup handles, not credentials accepted at API or sign-in token boundaries.
They belong only in trusted application state (the existing signed/encrypted
portal cookie). The browser still authenticates through that protected cookie;
this does not make a stolen cookie harmless.

BizKitSession supplies the reference with verified claims. Portal exchange
requires the reference to resolve to the same principal and takes the sign-in
time from Identity. Signature-only OIDC adapters without a revocable Identity
source cannot open portal sessions; their existing machine API remains unchanged.
Deployments using those adapters must use the Identity sign-in bridge for the
portal. Existing subject-only browser cookies fail closed and require sign-in.
Phoenix filters token and authorization parameters from request logs.

Both PortalSession and RequireSubject resolve the reference on every protected
request, including GET/POST role selection and stream reconnect. Identity checks
the originating session and resolves its identity binding again. Logout,
principal revocation, removed/reassigned identity bindings and expiry all deny
access independently of Dispatch role assignments. Sign-in timestamps in cookie
state are refreshed from the source, not trusted for step-up decisions.

Portal logout also revokes the source reference before clearing the cookie, so
replaying the previous cookie cannot restore access after a successful logout.

Both SSE transport loops check the same source before every refresh or heartbeat,
before invoking the existing stream authorization/rendering code. A failed check
ends the loop without another frame; the existing subscription `after` releases
listeners. Idle closure is bounded by the existing heartbeat interval, not an
instantaneous push notification. Requests/ticks authenticated before revocation
may finish; this does not fence concurrent in-flight output.

## Cluster and rollout

All lookups and revocations use the existing cluster Sessions singleton. Native
references use the same durable digest and read-ticket protocol as bearer
lookups, preserving #66's stale-read protection. PostgreSQL storage layout does
not change. Identity binding configuration must be consistent on all nodes.
Network partition fencing remains outside the existing singleton guarantees.

The in-memory ETS key shape changes. Restart the Identity singleton during a
coordinated deployment of all nodes, rather than mixing old/new session code.
Browser source sessions then require sign-in. Native sessions restore from the
unchanged durable store. No zero-downtime mixed-version migration is claimed.

Open PR #67 changes stream transport. Its eventual integration must preserve the
source check before both stream ticks and the existing role/relationship checks.

## Validation and remaining obligations

New Identity regressions cover non-bearer separation, malformed references,
expiry at the exact boundary, logout, principal revocation, binding removal,
native restoration and a deterministic paused-read/revocation overlap.
Dispatch integration tests exchange a real Identity token through the router,
replay the encrypted cookie, retain the role assignment, and check protected
pages, GET/POST role selection, both SSE tick paths and reconnects after each
ending condition. A remote-node case checks authentication and revocation over
the connected singleton; it does not claim a multi-node PostgreSQL deployment.
Ordinary sessions and both streams have positive controls. Actual controller
loop tests revoke at the first snapshot write, queue a refresh and forbid any
subsequent chunk, so removing the transport check causes a deterministic failure.
Production PostgreSQL native-store tests also assert invalidation and successful
unrevoked restoration through the reference API.

Local environment initially has no Elixir or PostgreSQL. An isolated extracted
Elixir 1.14 / OTP 25 runtime compiled the Identity sources and ran the reference,
existing durable-session, stale-read race and cluster-session files: **18 tests,
0 failures**. This fallback is not the supported Elixir 1.19 / OTP 27 acceptance
lane, nor Dispatch/PostgreSQL execution. Subsequently the same 18 tests passed
on an isolated supported Elixir 1.19 / OTP 27.3.4 runner. These direct ExUnit
runs do not exercise the unavailable Req provider dependencies or Dispatch.
After fetching the unchanged locked dependencies through a local cache that
retains Hex signature/checksum verification, normal `mix test` in
`apps/biz_kit_identity` on Elixir 1.19 / OTP 27.3.4 passed: **44 tests,
0 failures**. Existing intentional kill/restart tests emit logger formatter
errors, as previously recorded for #66. Changed source parses and is formatted;
`git diff --check` passes.

`Portal authentication acceptance / portal-auth-postgis` adds a focused hosted
Elixir 1.19 / OTP 27 job with PostgreSQL 16 / PostGIS, full Identity regressions,
Dispatch migrations and `mix test --include integration`. Hosted results must be
recorded at the tested head before this correction is called validated.
Consolidation still runs the production PostgreSQL native-store regressions.

The separate administrative-transaction P1 remains open. Adding a workflow does
not make it a required branch-protection check: the estate-wide required hosted
integration P2 remains open until that requirement is independently established.
