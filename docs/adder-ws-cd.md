# Adder-ws deployment trigger and activation acceptance

Status: **activation blocked pending tailnet evidence**. The host scripts and
units are exported in [`deploy/adder-ws-cd/`](../deploy/adder-ws-cd/README.md),
with their hashes, the host's CI gate and rollback, a failure-injection suite,
and which rows of the host acceptance matrix below it covers. The tailnet
policy rows remain open. Do not interpret HTTP 202 or a green trigger job as a
completed deployment.

## Workflow boundary

Only `larsbx/biz-kit`, `refs/heads/main`, `ADDER_WS_CD=true` and
`ADDER_WS_CD_ACCEPTANCE=v1` together permit credentials to be used. Manual
dispatch on another branch skips the job. No checkout or application artifacts
run in the credential-bearing job; its GitHub token has no requested permissions.
The action is pinned, Tailscale is versioned, caching is disabled, subnet routes
and tailnet DNS are declined, and its declared post action attempts logout.
The inspected action verifies downloaded binaries against the vendor's HTTPS
checksum endpoint; this is not an independently pinned binary checksum. Avoid
step/runner debug logging for credential-bearing deployments. Verify ephemeral
node removal in the first acceptance run;
forced runner termination is not evidence that cleanup ran.

There is no HTTP bearer secret or signed request. Authentication and authorization
are supplied by the Tailscale peer identity and **the complete effective tailnet
policy**, plus a listener bound only to adder-ws's Tailscale IP. HTTP is carried
inside the encrypted tailnet. Never expose port 8791 through a public listener,
proxy, Funnel, LAN wildcard, or subnet route bypass. If this boundary cannot be
established, add application authentication on both host and workflow before
activation. OAuth credentials are never sent in the HTTP request.

The OAuth client must have only the `auth_keys` write scope for the dedicated
`tag:biz-kit-deploy`, not a reusable general `tag:ci` identity. Restrict tag owners
and client access; use credentials dedicated to this repository. Secrets are
`TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET`. Maintainers able to edit main/workflows
or access these credentials are part of the deployment trust boundary.

An illustrative policy fragment (merge into, then test, the existing policy):

```json
{
  "tagOwners": {"tag:biz-kit-deploy": ["autogroup:admin"]},
  "grants": [{
    "src": ["tag:biz-kit-deploy"],
    "dst": ["100.67.165.25"],
    "ip": ["tcp:8791"]
  }],
  "tests": [{
    "src": "tag:biz-kit-deploy",
    "accept": ["100.67.165.25:8791"],
    "deny": ["100.67.165.25:22", "100.67.165.25:443"]
  }]
}
```

Grants/ACL allows are additive. Adding this fragment does not narrow existing
wildcard or tag rules. Inspect all grants, legacy ACLs, tag owners, routes and
other clients that can mint this tag. Extend deny tests to every other host and
port category in the actual tailnet, and test that an unrelated tailnet identity
cannot reach 8791. Policy tests and live allowed/denied probes are required.

The POST is empty. Only HTTP 202 acknowledges acceptance. Bodies are discarded,
redirects rejected, curl configuration and proxies bypassed, connections bounded
to 5 seconds and total transfer to 15 seconds. There are no automatic POST retries:
a timeout may mean the host accepted the request. Inspect host state before
retrying. The action's retry setting applies only to joining the tailnet.

The concurrency group avoids cancelling the active trigger. GitHub may coalesce
pending runs; it is not a FIFO and does not wait for the host deployment to finish.
The host must lock deployments and preserve a wake-up arriving during a build.
Fetching current main means a trigger may deploy a later revision than its own SHA.
This workflow does not wait for main's other CI checks; the host acceptance must
establish a pre-execution validation policy. Compilation alone is insufficient
evidence of application acceptance.

## Reproducible repository checks

```sh
python3 -m pip install PyYAML==6.0.3
python3 tools/test_adder_ws_cd.py
```

These run the workflow's actual shell against loopback HTTP fixtures and test
202, unexpected successes, redirects, authorization errors, busy/error responses,
connection refusal, poisoned proxy/curl defaults, response-body log injection,
missing credentials and boundary mutation controls. They do not exercise the
Tailscale action, policy, systemd, production compile/restart, or recovery.

## Host inspection required before setting the acceptance variable

Use an authenticated shell as the actual deployment owner. Export sanitized
copies of the installed scripts and units into a reviewable PR; do not export
tokens, private keys, environment files, command-line credentials or journal
payloads. Record the owner, paths and SHA-256 hashes of those copies. The
export lives in [`deploy/adder-ws-cd/`](../deploy/adder-ws-cd/README.md), with
owner, paths and `SHA256SUMS`. Inspect:

```sh
systemctl --user cat biz-kit-cd.service biz-kit-cd.path biz-kit-cd-trigger.socket biz-kit-cd-trigger@.service
systemctl --user show biz-kit-cd.service -p ExecStart -p WorkingDirectory -p Restart -p TimeoutStartUSec
systemctl --user show biz-kit-cd-trigger.socket -p Listen -p Accept
ss -ltn '( sport = :8791 )'
git -C ~/biz-kit symbolic-ref --short HEAD
git -C ~/biz-kit status --porcelain=v1 --untracked-files=all
git -C ~/biz-kit rev-parse HEAD
sha256sum ~/bin/biz-kit-cd ~/bin/biz-kit-cd-trigger
```

Read the scripts locally with secret-safe output. Resolve any differently named
socket service from its installed unit rather than assuming the example name.
Check executable/config ownership, PATH, environment loading, allowed repository
origin, unit privilege boundaries and persistent user-manager/linger settings.
The trigger must validate exact method/path, refuse payload-provided commands,
refs, paths and environment, impose bounded parsing/connection timeouts, and
return 202 only after the wake-up has been accepted reliably. If a unit start is
already active, systemd start coalescing alone does not preserve a later update.

## Host acceptance matrix

Run destructive failure injection in an isolated checkout and test service first.
Record command, revision, expected outcome and observed outcome for every row.
Do not mark a row passed from the workflow contract tests.

| Check | Required observed result |
| --- | --- |
| Clean main / off-main / detached / tracked edit / untracked file / local-ahead / divergence | Only a clean main eligible for fast-forward proceeds; all refused states leave files and running service intact; no reset/clean discards work |
| Fetch or dependency resolution failure | Nonzero deploy outcome; no restart and no advancement of last-good |
| Backend compile failure | No restart; previous service stays healthy, including a tested cold restart from retained good artifacts |
| Desktop build failure | No promotion of failed artifacts or last-good; any partial component success has explicit retry semantics |
| All deploy-relevant paths | Backend/config/dependency/release/assets and desktop changes are classified; unknown paths use a conservative validation policy |
| Retry same fetched HEAD after a failed build | Work is computed against last successful deployment, not the already-fast-forwarded checkout HEAD; failed work is rebuilt |
| Restart or health-check failure | Nonzero outcome; restore retained executable/config revision and verify health; failed recovery remains failed and visible |
| Last-good checkpoint | Written atomically and durably only after all required builds, promotion, restart and health checks; crash cannot falsely advance it |
| Two simultaneous deploy invocations | One host lock covers fetch through checkpoint; no overlapping build/promotion/restart; manual invocations use the same lock |
| Main advances while a deployment is running | Accepted later wake-up survives; host fetches/reconciles again and eventually reaches current main; busy response is not falsely accepted |
| Wrong method/path, malformed/oversized request, disconnected sender | Rejected/bounded; cannot run arbitrary commands or erase wake-ups |
| Host restart during accepted work | Durable pending state is recovered; otherwise 202 is only volatile acceptance and activation remains blocked |
| Tailnet policy | CI identity reaches only 8791 on adder-ws; unrelated identity denied; LAN/public access denied |
| Main acceptance policy | Required application checks for the selected revision pass before execution; checks and revision are recorded |

Keeping only a last-good SHA is not artifact rollback. An in-place build or
checkout may replace files a running service needs; verify retained runnable
artifacts and recovery explicitly. Database changes need their own compatible
cutover plan and must not be guessed by this trigger.

## Controlled first deployment

1. Leave `ADDER_WS_CD` unset/false. Establish authenticated host access, inspect
   and version the sanitized host implementation, complete the matrix, record
   baseline running revision, healthy state and retained recovery artifacts.
2. Configure the dedicated OAuth client, repository secrets and effective policy.
   Verify the positive and negative tailnet probes and listener binding. Record
   policy revision and script/unit hashes without credential values.
3. After hosted CD contract checks pass on the exact PR head and required
   application acceptance passes, merge the dormant workflow. Set
   `ADDER_WS_CD_ACCEPTANCE=v1` only against the recorded host/policy evidence.
4. Set `ADDER_WS_CD=true`; manually dispatch **main** once. Record workflow URL,
   202 acknowledgement, host journal deployment outcome, actual fetched revision,
   build results, health results, last-good checkpoint and post-action node cleanup.
   A green job alone does not complete this step.
5. Exercise one harmless follow-up main change to demonstrate the push path and
   advancement-during-build case. Record successful convergence and lack of overlap.
   On failure, disable `ADDER_WS_CD`, inspect the host, and use the tested recovery
   path. Disabling the variable blocks future triggers; it does not cancel host work.

Revalidate acceptance after host scripts, units, privilege or policy changes;
clear the acceptance variable while that evidence is stale.

## Inspection receipt (2026-10-30)

PR #209 original head `3437ef269f759ce82d1d056a8adc1032778e60bd` had a completed
automated code review with no findings and no inline review threads. Its five
reported workflow runs included four successes and one failed location acceptance
run `41090679743`: courier trial 1 timed out after 30 seconds and reported
`OFFLINE expected=0 actual=2`; courier trials 2/3 and all driver/browser trials passed.
This is not deployment acceptance and has not been dismissed as a proven flake.

In this inspection environment adder-ws did not resolve, its Tailscale IP endpoint
was unreachable, no Tailscale executable was installed, and no SSH credentials
were present. The GitHub connector does not expose repository secret/variable
administration or Tailscale policy administration. Credential presence, effective
policy, installed host behavior and live deployment are therefore **unverified**.
No activation variables were changed and no deployment was initiated here.
