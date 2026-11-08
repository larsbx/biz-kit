# Procurement MVP: signed persistence and coordinator console

Status: implementation and acceptance tests authored on PR #334. Not deployed;
Elixir, PostgreSQL, HTTP, Lean, Quint and release-build execution require exact-head
hosted receipts. The locally executed Python model is not runtime conformance.

## Narrow product

One private coordinator console, three server-rendered views: requests,
quotes/orders, operations/evidence. Existing CommerceCore workflow remains the
only business reducer. No new database, notification service, payment processor,
Dispatch dependency, capital ledger, investment unit or marketplace framework.
Business participation is explicit governance enrollment. Enrollment, consent,
merchant quotes, delivery and payment references are **operator attestations**,
not independently verified business registration, buyer signatures or bank facts.
Costs and membership economics are not calculated or exported by this slice.

## Admission and recovery

The existing canonical Log remains the writer and PostgreSQL EventStore remains
the durable source. Four private event specifications use the existing extension
registry, registered before Log recovery; conflicting registrations abort boot.
`AdmissionGate` wraps the existing Membership projection and adds procurement
state only when procurement events exist. Legacy gates retain their original shape.
`Log.replay(AdmissionGate)` rebuilds the procurement view. A Membership-only replay
intentionally does not expose procurement data.

Log checks procurement live authority before generic validity/folding. Procurement
commands and authority events are singleton batches. An exact retry is considered
only after current grant and session checks, and returns the original persisted
event without a new append. Changed command content is rejected. The admission
clock is checked against the signed second; a request queued across a second may
be refused and retried. Decisions at expiry use the actual admission milliseconds.
Historical replay uses the signed instant and does not invalidate old accepted
facts merely because authority or a quote expires later.

Grants are chapter/cooperative/operator/key scoped and versioned. Governance must
already be declared: generic role bootstrap permissiveness is not used. Revocation
or replacement invalidates old sessions. Explicit grant revocation is required;
revoking the grant issuer's governance key does not retrospectively revoke every
recipient grant. Read requests are signed, checked and selected inside the Log
mailbox, and cannot be appended. A snapshot represents authorization at that
serialized read point; it cannot retract bytes already delivered to a client.

The substrate has no new compile-time dependency on the larger CommerceCore app.
The procurement host includes CommerceCore explicitly in its release closure.
The fixed kernel module must be loadable to admit or replay procurement commands;
otherwise admission rejects and replay fails closed. Never open this ledger with
an older release that lacks the procurement event registry and kernel.

## Coordinator access

Pilot only: one configured coordinator, a high-entropy random access token whose
SHA-256 digest is configured, and an independently granted server-held signing key.
No passwords or signing seeds are sent in forms. Cookie sessions are encrypted,
signed, Secure, HttpOnly and SameSite=Strict, with a four-hour maximum. Forms use
CSRF protection; displayed records are HTML-escaped; responses are no-store and
have a restrictive CSP. Actor, cooperative, key and grant version are host-derived,
not accepted from form attributes. Current ledger authority is rechecked for every
protected read and write. Rotating the configured login digest invalidates existing
sessions; browser logout drops that browser's cookie but is not a durable blacklist
of a previously stolen cookie. Ledger grant revocation is the emergency cutoff.

The application listens only on loopback when `PROCUREMENT_ENABLED=true`. It has
no default credential. Terminate HTTPS on a trusted reverse proxy and keep the port
private. Use an identity-aware proxy/rate limiting for the pilot; this is not a
multi-user identity product, MFA or a comprehensive abuse-prevention implementation.
The host is a trusted signer: compromise of the process/signing seed is outside
cookie authentication guarantees. Do not place the governance seed in its service
environment. Database administrators and trusted in-process Log callers remain
inside the substrate trust boundary. Raw evidence documents stay outside the log.

## Formal-first obligations and evidence

`Admission.lean` contains six theorem proofs about an abstract admission function:
revoked denial, replaced-grant denial, retry inertia, stale-version denial, admitted
increment, and competing-version at-most-once. `admission.qnt` independently models
queueing, expiry, replacement, retries and restart. Neither proves Elixir/SQL/HTTP
refinement or unbounded behavior of the deployment.

Local authoring checks: the independent Python finite model explored 240 states and
1,136 transitions and detected five deliberate authority/version/retry mutations.
Python byte-compilation, shell syntax and workflow structure are separately checked.
No local Elixir/Lean/Quint runtime was available. Do not relabel generated tests,
source inspection or Python results as passing hosted implementation checks.

Actual acceptance sources: 10 PostgreSQL/Log tests and 5 HTTP tests in this slice,
plus the existing kernel and Log/envelope regressions. They exercise lifecycle,
restart after expiry, exact retry after restart, changed content, revocation before
queued admission, concurrent accept/cancel, undeclared businesses, signatures,
wrong scope, grant replacement, session/quote expiry, CSRF and escaping.
HTTP tests call the real Plug pipeline with cookies/forms/CSRF and real Log; they
are not a graphical-browser or public-host test. The CI gate requires both actual
runtime/release tests and Lean/Quint replay; skipped jobs are not success. Checks
are source-bound and retain toolchain logs and the release artifact hash.

## Reproduce and build

Requires Elixir 1.19 / OTP 27, Rust, Python, PostgreSQL and the locked dependencies.
Use a disposable local PostgreSQL instance: the harness resets the database named
`coop_substrate_eventstore_test`. Never point it at production.

```sh
export EVENTSTORE_USERNAME=postgres EVENTSTORE_PASSWORD=postgres EVENTSTORE_HOST=localhost
bash scripts/test-procurement-host.sh
```

The harness stages only the actual dependency closure, runs the existing kernel,
10 ledger tests, legacy Log/envelope tests, and 5 HTTP tests, and builds the actual
`procurement` release definition. Receipts and a release archive are saved under
`.artifacts/procurement-host`. It does not deploy the archive or prove backup restore.

The release uses `config/procurement_runtime.exs`, not the umbrella's unrelated
Dispatch/SpruceGoose runtime settings. Set at deployment:

```
EVENTSTORE_USERNAME, EVENTSTORE_PASSWORD, EVENTSTORE_DATABASE
EVENTSTORE_HOST (default localhost), EVENTSTORE_PORT (default 5432)
PROCUREMENT_DATA_DIR (persistent private absolute directory)
PROCUREMENT_ENABLED=true
PROCUREMENT_PORT=4080
PROCUREMENT_CHAPTER, PROCUREMENT_COOPERATIVE, PROCUREMENT_OPERATOR
PROCUREMENT_KEY_ID, PROCUREMENT_GRANT_VERSION
PROCUREMENT_SIGNING_SEED_HEX (32-byte Ed25519 seed, 64 hex characters)
PROCUREMENT_LOGIN_SHA256 (SHA-256 of a random >=32-byte URL-safe access token)
PROCUREMENT_SECRET_KEY_BASE (at least 64 random characters)
```

Generate secrets privately, not in a committed example or CI artifact. Configure
PostgreSQL on a protected local network; remote database TLS policy is a deployment
obligation. Initialize the stores before boot, using the existing migration task:

```sh
bin/procurement eval 'ProcurementHost.ReleaseTasks.migrate()'
```

### Explicit enrollment, not automatic governance

Use an already-established chapter governance key in a separate offline enrollment
process. Prepare a JSON file with `type`, `chapter_id`, and `payload`. For an operator
use `ProcurementOperatorGrantedV1` with `cooperative_id`, `operator_id`, `key_id`,
`pubkey_hex` (public key only), `active`, `expires_at_ms`, and `expected_version`.
For a business use `ProcurementBusinessEnrolledV1` with `cooperative_id`, `business_id`,
`active`, `evidence_ref`, and `expected_version`. First version expects zero. Revoke
an operator with `active: false` and the current expected version; versions do not
reset. Enroll both buyer and merchant before creating/accepting a quote.

```sh
# In a separate process, with HTTP disabled and the existing governance secret:
PROCUREMENT_ENABLED=false bin/procurement eval 'ProcurementHost.ReleaseTasks.enroll("/private/enrollment.json")'
# That process alone needs PROCUREMENT_GOVERNANCE_KEY_ID and PROCUREMENT_GOVERNANCE_SEED_HEX.
# Remove those variables before launching the long-running service.
bin/procurement start
```

Enrollment does not create a self-signed genesis authority. A new chapter must first
use the existing explicit governance bootstrap procedure. The service must never
automatically make its own key authoritative. The enrollment helper must run while
the ordinary service is stopped; it starts the same single canonical Log and is
not a second concurrent production writer.

## Remaining launch gate

Hosted exact-head compilation/proofs/tests must pass first. Then test the built
artifact behind the intended HTTPS proxy: sign in, complete a real authorized
request, restart, verify the frozen accepted record, revoke during admission, and
restore a database backup into an isolated instance. Match artifact hash to source
receipt. Verify server-held key custody, proxy logging/rate limiting and secret
rotation. Retain a compatible rollback artifact; older software without these event
types is not a safe rollback after procurement events have been written.

No automatic merge or deployment. No full branch acceptance, external evidence
verification, legal compliance, financial settlement, or end-to-end refinement claim.
