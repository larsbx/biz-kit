# Procurement and Dispatch from separate release archives

The `--packaged-only` gate targets the next execution boundary after PR #417.
A production-profile Procurement archive owns the canonical ledger. An
independent Dispatch **test-profile** archive supplies the worker, PostgreSQL
assignments, and authenticated courier Router. Each Dispatch action launches a
fresh bundled ERTS process from the extracted archive. The fixture asserts the
runtime and Dispatch BEAM paths, checks that the canonical appender is absent,
and starts the Dispatch application before exercising the worker or Router.

The runner creates and drops separate randomized Procurement and Dispatch
databases on a disposable IPv4 loopback PostgreSQL cluster. Dispatch migrations
run through its own archive. The test uses a disposable database role with
schema and PostGIS setup privileges. That role is shared by the runner's
database connections. This gate exercises ledger ownership and data separation
at the application boundary. Production database ACLs require their own gate.

The real Dispatch Finch client uses an origin-scoped connection pool with
verified TLS and a test certificate trusted only for that pool. Signed work
requests through two additional loopback listeners must fail with the exact
unknown-CA and hostname errors, respectively. The fixture CA signs two leaves.
The unknown-CA probe presents the same loopback certificate as the working
endpoint and uses the default trust store. The wrong-hostname probe trusts the
fixture CA for its origin and presents a different name. Both listeners check
that their proxies receive no HTTP requests. The Procurement backend is reached by the fixture's
loopback reverse proxy. The normal Dispatch transport and runtime configuration
are unchanged by the fixture.

The lifecycle reuses PR #417's quote binding, service authorization, custody
and exact retry checks. It adds packaged courier refusals for a missing session
and missing CSRF token. Offline checks verify the accepted quote, three signed
custody steps, exact event sequence, delivery proof, restored ledger and
coordinator revocation. The previously focused worker tests remain the evidence
for the additional role revocation, cancellation and recovery scenarios they
exercise. Starting a new packaged process over committed Dispatch rows tests
cold restart recovery.

## Run on an isolated test machine

Use a clean checkout containing this change, Linux, OTP 27.3.4, Elixir 1.19.0
for OTP 27, Rust/Cargo 1.91.1, Hex/Rebar, Python 3.12 or newer, OpenSSL,
`flock`, PostgreSQL 16 clients, and a disposable PostgreSQL 16 cluster with
PostGIS available. The account must be able to create and drop the test
databases and install PostGIS in them. Resolve the locked dependencies as in
the existing real-worker workflow. Supply the username and password for
that disposable role in `EVENTSTORE_USERNAME` and `EVENTSTORE_PASSWORD`.

```sh
EVENTSTORE_HOST=127.0.0.1 \
PROCUREMENT_DISPATCH_ACCEPTANCE=disposable-local-postgres \
bash scripts/test-procurement-dispatch.sh --packaged-only
```

Set `EVENTSTORE_PORT` if the test cluster uses a port other than 5432.
This mode does not need `dispatch_test` or a source-worker run. The original
script invocation and existing hosted workflow still run the source-worker gate.

The runner writes under
`.artifacts/procurement-dispatch-packaged/<full-source-revision>/`.
Check both release archive hashes with `sha256sum -c artifact.sha256`.
The `packaged/receipt.json` record is written after cleanup and binds the
same source revision, both archive hashes, the TLS fixture fingerprints,
dispatch process observations, and per-log hashes. It is an unsigned runner
observation. The canonical custody events are independently signature-checked
by the packaged ledger inspection.

## Hosted acceptance

The **Procurement and Dispatch packaged-process acceptance** workflow checks out
the exact pull request head (or the selected commit for a manual run). Its
dedicated `packaged-only` job builds both archives there and runs the command
above. The disposable GitHub-hosted Ubuntu 24.04 runner installs OTP and Elixir
from `.tool-versions`, Rust/Cargo 1.91.1, and PostgreSQL 16 clients. The job pins
the PostgreSQL 16/PostGIS 3.4 service image by digest, publishes its database
port on IPv4 loopback, and records the resolved server, extension and client
versions.

The `procurement-dispatch-packaged-<revision>` artifact is uploaded after the
runner succeeds and the job verifies the packaged receipt against the checkout
revision and both actual archive hashes. It contains the two archives, their
checksum manifest, the revision and toolchain records, and
`packaged/receipt.json`. The receipt carries SHA-256 hashes of the fixture CA
and both server certificate PEM files, the exact TLS and courier refusals, and
the three signed custody steps observed in the original and restored ledger.
The packaged ledger inspector verifies the persisted signatures and event chains.
The artifact excludes the fixture keys, database dump and runtime logs.

## Evidence boundaries

| Boundary | Gate |
| --- | --- |
| Packaged Procurement with source Dispatch VMs | Existing PR #417 real-worker suite |
| Packaged Procurement with packaged Dispatch processes | Dedicated hosted `packaged-only` job, using bundled Dispatch `eval`, the test profile, and verified loopback HTTPS on one runner |
| Installed desktop | Native Tauri/WebKit and desktop installer acceptance |
| Courier browser and external identity | Separate graphical courier and identity-provider acceptance |
| Target-host deployment | Production-profile Dispatch startup and trust configuration on distinct hosts |

This gate's two archives contain bundled runtimes and launchers. The product
requirement is one distributable executable for each local Biz-Kit instance,
with peer interoperability required across supported versions. A later gate
must start that same executable twice on separate hosts, exercise both
directions with independently provisioned keys and trust, and require
same-version and supported cross-version pairs to preserve the signed protocol,
ledger ownership, retries and cold recovery.
