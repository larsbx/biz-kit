# Procurement MVP: signed persistence and coordinator console

Status: implementation and acceptance sources on PR #334, not a deployed or
accepted MVP. This continuation adds bounded clock-refusal handling and an actual
packaged-release acceptance runner. Its 15 Python runner/control tests passed
locally, including a real TLS proxy/Secure-cookie round trip. Elixir, PostgreSQL,
Lean, Quint and the packaged application were not executed locally. Those require
successful exact-head hosted receipts; runner tests are not application acceptance.

## Narrow product

One private coordinator console, three server-rendered views: requests,
quotes/orders, operations/evidence. Existing CommerceCore workflow remains the
only business reducer. No new authoritative database, notification service,
payment processor, Dispatch dependency, capital ledger or marketplace framework.
Business participation is explicit governance enrollment. Enrollment, consent,
merchant quotes, delivery and payment references are **operator attestations**,
not independently verified business registration, buyer signatures or bank facts.
Cost capture, scorecard export and membership economics remain unconnected.

## Admission and recovery

The canonical Log remains the writer and PostgreSQL EventStore the durable source.
Four private event specifications use the existing extension registry, registered
before Log recovery; conflicting registrations abort boot. `AdmissionGate` wraps
Membership and adds procurement state only when procurement events exist. Legacy
gates retain their original shape. `Log.replay(AdmissionGate)` rebuilds procurement;
a Membership-only replay intentionally does not expose procurement data.

Log checks live authority before generic validity/folding. Procurement commands
and authority events are singleton batches. Exact retries require current grant
and session checks and return the original persisted event without appending.
Changed command content is rejected. Decisions at expiry use actual admission
milliseconds. Historical replay uses the signed instant: later expiry cannot
invalidate previously admitted business facts.

Grants are chapter/cooperative/operator/key scoped and versioned. Governance must
already be declared; generic role bootstrap permissiveness is not used by the
production enrollment helper. Revocation or replacement invalidates old sessions.
Revoking an issuer's governance key does not retrospectively revoke every recipient
grant: revoke those grants explicitly. Signed read requests are authorized and
selected inside Log and cannot be appended. Authorization holds at that read point;
it cannot retract bytes already delivered.

The host includes CommerceCore in its release closure; the generic substrate has
no new compile-time dependency on it. An unavailable kernel rejects admission and
fails historical replay closed. An older release without these event types and
kernel is not a safe rollback after procurement records exist.

### Clock-boundary handling

The original signed-second freshness check remains unchanged. A signature can
cross a second boundary while queued. `ProcurementHost.Admission.run/1` makes at
most three attempts for only the explicit pre-append freshness refusal: the direct
snapshot error or singleton write `{:reject, 0, :stale_procurement_admission_time}`.
Each attempt builds a fresh signed envelope using the same command ID, expected
version, attributes and session deadline; Log rechecks current authority.

No retry is made for expired/revoked authority, a stale workflow version, storage
failure, timeout, process exit, exception or another uncertain outcome. There is
no extension of grant, session or quote lifetime. Eight ExUnit cases specify these
boundaries; their execution is pending. The formal admission policy is unchanged;
these cases are not an implementation-refinement theorem for the retry wrapper.

## Coordinator access

Pilot only: one configured coordinator, a high-entropy access token whose SHA-256
digest is configured, and an independently granted server-held signing key. No
passwords or signing seeds enter forms. Cookie sessions are encrypted, signed,
Secure, HttpOnly and SameSite=Strict with a four-hour maximum. Forms use CSRF;
records are HTML-escaped; responses are no-store with a restrictive CSP. Actor,
cooperative, key and grant version are host-derived, never trusted form fields.

Rotating the configured login digest invalidates sessions. Logout drops that
browser's cookie but is not a durable blacklist of a stolen cookie. Ledger grant
revocation is the emergency cutoff. Protected reads and writes recheck authority.
The host is a trusted signer: process/signing-seed compromise is outside cookie
authentication guarantees. Database administrators and trusted in-process callers
remain inside the substrate trust boundary. Raw evidence stays outside the log.

HTTP listens only on loopback when `PROCUREMENT_ENABLED=true`, with no default
credential. Use an appropriate HTTPS reverse proxy and keep the port private.
Identity-aware access/rate limiting, production proxy configuration, MFA and
comprehensive abuse prevention are not supplied by this pilot. Never place the
governance seed in the long-running service environment.

## Formal and implementation evidence

`Admission.lean` contains six abstract admission theorem proofs: revoked denial,
replaced-grant denial, retry inertia, stale-version denial, admitted increment and
competing-version at-most-once. `admission.qnt` independently models queueing,
expiry, replacement, retries and restart. Neither proves Elixir/SQL/HTTP refinement
or unbounded deployment behavior. Existing lifecycle proofs/models remain required.

Earlier authoring ran the independent Python admission model: 240 states, 1,136
transitions, five detected negative controls. This continuation locally ran 15
runner/control tests, Python compilation, shell syntax and workflow gate checks.
Do not relabel these as passing Elixir, SQL, Lean, Quint or release acceptance.

Application acceptance sources include the existing 10 PostgreSQL/Log tests,
5 Plug-pipeline HTTP tests, 8 new retry-wrapper unit tests, and existing kernel and
Log/envelope regressions. They are authored tests, not completed receipts.

### Packaged-release acceptance

`tests/procurement_mvp/release_acceptance.py` unpacks the actual release archive
and uses its bundled runtime. It does not run the app through Mix or test BEAMs.
The required sequence is:

1. Validate packaged source identity and initialize a fresh synthetic database.
2. Seed explicit synthetic governance/businesses offline, then start the artifact
   without the governance key in the host environment.
3. Drive rendered forms through a certificate-verified loopback HTTPS fixture,
   with normal Secure cookies and CSRF. Deny unauthenticated access and missing
   CSRF; complete request, qualification, two quote revisions, exact acceptance
   and fulfillment. Reject the obsolete quote at the current aggregate version.
4. Repeat the exact original request command and require six persisted commands
   and version six, the frozen second quote, and no implied payment evidence.
5. Stop/start the packaged process, reread the order through HTTP, and compare the
   canonical head/hash and replayed state after restart.
6. Revoke offline while the host is stopped; use the old session to attempt a
   write before any denied read clears its cookie. Require refusal and an unchanged
   ledger. Dump to a custom PostgreSQL archive, restore into a second fresh database
   with errors fatal, replay and compare the head/hash/state, then require that
   revoked credentials still cannot log in to the restored application.

The fixture is not a graphical browser and is not the intended production proxy.
Synthetic SQL restore does not validate backup of external evidence, service
secrets or the production host filesystem. Offline fixture code lives under tests,
not in the application release, and refuses non-acceptance databases. No public
bootstrap endpoint is added. It never starts a second live appender.

A success receipt requires all 12 checks, a matching source revision and archive
SHA-256. Failed/skipped/missing checks and stale receipts are rejected; a failed
rerun removes the previous success receipt. Receipts are explicitly
`unsigned-runner-observation`, not cryptographic runner attestations or proof that
arbitrary supplied receipt JSON is truthful. Source identity and artifact digest
must be read together with the actual trusted execution evidence.

The final CI gate requires runner controls, actual runtime/release acceptance and
independent Lean/Quint replay. A failed or skipped prerequisite is not success.

## Reproduce and build

Requires a clean committed checkout, Elixir 1.19 / OTP 27, Rust, Python 3.12+,
OpenSSL, PostgreSQL 16 server/client tools and the locked dependencies. Use a
disposable loopback instance: the harness resets `coop_substrate_eventstore_test`
and creates/deletes its own random `procurement_acceptance_*` databases. It must
not use production. The explicit opt-in is required even when only building via
this acceptance harness.

```sh
export EVENTSTORE_USERNAME=postgres EVENTSTORE_PASSWORD=postgres EVENTSTORE_HOST=localhost
export PROCUREMENT_RELEASE_ACCEPTANCE=disposable-local-postgres
bash scripts/test-procurement-host.sh
```

The harness stages the dependency closure, executes tests, builds the actual
`procurement` release, embeds `SOURCE_REVISION`, packages it and runs the packaged
acceptance sequence. Receipts, logs and the archive are under
`.artifacts/procurement-host`; `release/receipt.json` exists only after successful
completion. This does not deploy to the user's host.

Runner controls alone, without Elixir or PostgreSQL:

```sh
python3 -m unittest discover -s tests/procurement_mvp -p test_release_acceptance.py -v
```

## Production configuration and explicit enrollment

The release uses `config/procurement_runtime.exs`, not unrelated umbrella secrets.
Set privately at deployment:

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

Do not use synthetic acceptance credentials or publish real secrets in CI artifacts.
Remote database TLS policy remains a deployment obligation. Initialize the stores
explicitly before service boot:

```sh
bin/procurement eval 'ProcurementHost.ReleaseTasks.migrate()'
```

Use an already-established chapter governance key in a separate offline enrollment
process. A JSON file supplies `type`, `chapter_id`, and `payload`. For an operator,
`ProcurementOperatorGrantedV1` requires `cooperative_id`, `operator_id`, `key_id`,
`pubkey_hex` (public only), `active`, `expires_at_ms`, and `expected_version`. For a
business, `ProcurementBusinessEnrolledV1` requires `cooperative_id`, `business_id`,
`active`, `evidence_ref`, and `expected_version`. First version expects zero. Revoke
with `active: false` and the current version; versions never reset. Enroll both
buyer and merchant before creating/accepting a quote.

```sh
# Stop the ordinary service first. Only this separate process gets governance secrets.
PROCUREMENT_ENABLED=false bin/procurement eval 'ProcurementHost.ReleaseTasks.enroll("/private/enrollment.json")'
# It needs PROCUREMENT_GOVERNANCE_KEY_ID and PROCUREMENT_GOVERNANCE_SEED_HEX.
# Remove those variables before launching the ordinary service.
bin/procurement start
```

Production enrollment does not create self-signed genesis authority. New chapters
use the existing explicit governance bootstrap procedure; the service must never
make its own key authoritative. The helper starts the same canonical Log, so it
must not run beside the ordinary service as a second production writer.

## Remaining launch gate

Obtain successful exact-head hosted compilation, proofs, application tests and
packaged acceptance. Then test that artifact on the actual target host behind the
intended HTTPS proxy, with a graphical browser and an authorized business workflow.
Check restart/revocation, restore procedures, artifact identity, signing-key custody,
proxy logging/rate limiting, secret rotation and compatible rollback. Cost capture
and scorecard export remain a separate small product implementation obligation.

No automatic merge or deployment. No claim of full branch acceptance, independent
external-evidence verification, legal compliance, settlement or end-to-end refinement.
