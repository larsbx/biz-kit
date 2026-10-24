# Evergreen: test-server deployment intake (2026-10-24)

## Scope

Evergreen is an **existing, running test server**. It is not an application,
fleet identity authority, SpruceGoose successor, or production promotion target.
Do not attempt to recover Mama, reconstruct old ICM inventory, or repoint the
retired SpruceGoose remote client as part of this work. Legacy documents are
historical leads, not live host observations.

The intended future control path is ChatGPT -> GitHub deployment request ->
independently recoverable, narrowly authorized test-host executor -> actual host
observations. Biz-kit TaskCore and AgentCore may plan/review/track this work,
but neither an agent nor the business ledger should be required to repair
a failed deployment. Production is deliberately out of scope.

## First deliverable: observation only

Run the portable audit under the *actual non-root service user* on Evergreen,
after reviewing the exact repository revision. Do not run it through sudo or
as root. It accepts only \`--environment test\`, requires an externally chosen
expected hostname, and cannot make changes:

~~~sh
python3 ops/test_host/preflight.py \
  --environment test \
  --expected-host ubuntu-8gb-evergreen \
  --min-free-gib 4
~~~

The hostname above is a historical label to verify against live reality,
not an independently established current machine identity. If the current
hostname differs, record that mismatch and determine the correct authorized
target; do **not** use \`--expected-host "$(hostname)"\` to turn a mismatch
into a pass.

Optionally add \`--require-unit some-actual-test.service\` once an actual
test-only application unit has been identified. The script checks hostname,
non-root execution, Linux, disk/inodes, user-systemd responsiveness, a rootless
Podman runtime, selected unit activity, and wildcard TCP listeners. It never
prints command output, credentials, endpoints, IPs, service names or listening
ports. It reports only a redacted JSON summary. Exit 2 signals a failed gate;
listener warnings require a separate exposure review. Even a fully passing
report has \`deployment_authorized=false\` and
\`live_deployment_verified=false\`.

Run offline regression tests without contacting Evergreen:

~~~sh
python3 -m unittest discover -s ops/test_host -p 'test_*.py' -v
~~~

The matching GitHub Actions workflow performs **only** these offline tests.
No SSH credentials, GitHub environment secrets, deployments, releases, or
runtime mutations are created by this change.

## Required live audit beyond this preflight

Record a dated, operator-reviewed inventory from Evergreen (not ICM):

1. Exact host identity, active network routes, Caddy/TLS/DNS ownership and
   externally reachable listeners. Confirm test/prod isolation.
2. Actual systemd user/system services, rootless Podman containers, volume
   mounts, runtime users, Linux capabilities, and agent workspace separation.
3. Actual PostgreSQL/PostGIS instances, data ownership, app credentials
   boundary, migration state, and **non-production** sample data.
4. Independent backup integrity, scratch restore, available disk/inodes,
   artifact retention and failure recovery.
5. Allowed deployment account and permissions, source of SSH/Tailscale trust,
   GitHub environment protection, host identity pins, and revocation behavior.

Keep raw sensitive evidence in owner-controlled storage, not a public GitHub
issue, Actions artifact or agent transcript. Treat all live facts as unknown
until measured; a test-machine preflight is not a security certification.

## Next implementation slices (after live evidence)

**A. Choose the first test application.** Use an actual build artifact from a
current source commit; record the repo, exact SHA, lock/build digest,
dependencies, expected loopback upstream, health endpoint and chosen domain.
The existing \`orchestration\` release still includes legacy SpruceGoose.
Do not represent it as SpruceGoose-free. Do not make a production writer switch.

**B. Host-restricted executor.** Give GitHub a narrowly scoped entry point,
not a general SSH shell and not a shared agent host credential. Deploy only an
allowlisted release/environment tuple. Accept content-addressed, previously
verified artifacts; do not execute commands from a GitHub issue, PR body,
ChatGPT prompt, or application payload. Bind a one-time request to exact
commit, artifact digest, environment, target, action, and approval. Verify
current authorization again at execution. Keep the executor independently
recoverable if biz-kit is down.

**C. Test activation and rollback.** Install into an isolated, test-only
release slot, verify the host/unit target, perform approved migrations only
against a test database after a verified backup, switch a test-only route,
probe real application health, and record host-observed effects. If the probe
fails, revert to the last verified artifact without destroying data. Prove
retry/replay refusal and forced interruption recovery in staging.

**D. Chat-to-GitHub control.** Expose a fixed deployment-request form with
allowlisted inputs; validate its content before scheduling. A GitHub commit or
green build alone is never a deployment grant. Enable chat-triggered test
deployment only once GitHub connectivity, host permissions, artifact custody,
health checks, and rollback have passed acceptance tests. Production requires
its own separate environment, host inventory and approval controls.

## Retirement boundaries

Biz-kit owns business admission, identity, shared ledger and TaskCore. AgentCore
is engine-neutral \`launch/poll/cancel\` plus approved profiles and attempt
reconciliation; it is **not** the server's root deployment authority.
SpruceGoose is for selective salvage and retirement. No need to reactivate its
historical deployment service. See
\`docs/architecture/2026-10-20-sprucegoose-salvage.md\` and
\`docs/architecture/2026-10-24-signed-agent-runs.md\`.
