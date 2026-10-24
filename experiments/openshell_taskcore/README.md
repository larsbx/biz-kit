# OpenShell x TaskCore: isolated first slice (experiment)

**Status:** executable sandbox lifecycle/candidate **smoke** with offline fakes.
No live gateway, real agent, model, TaskCore command, signed ledger append, DoD
evidence admission, deployment, writer cutover or user-facing endpoint is
implemented by this experiment. Do not equate a passing unit test with those.

## Architecture decision

Keep the existing authoritative biz-kit structure:

1. **BizKit.Identity + grants** identify the actor; only the signed
   CoopSubstrate ledger and TaskCore admission determine task authority.
2. **Agent coordinator (future)** reads a *committed* scoped task and current
   grants, derives a run ticket and persists a ledger-linked execution intent.
   An agent's self-reported project IDs and policy flags are never trusted.
3. **OpenShell** executes the chosen agent image in a sandbox with a
   pre-approved, pinned workload template and controlled network/filesystem
   policy. The gateway's operational records are not business records.
4. **Candidate results** return via a typed result validator, with bounded
   stdout and exact task/scope/source correlation. They have no state effect.
5. **Authoritative effects** go through separate authenticated, typed biz-kit
   tools and the current ledger append gate; receipt/evidence custody and
   independent review are separate steps. Sandbox permissions are not grants.

For Dispatch, retain the provider-neutral
Dispatch.Integrations.Agent.Runtime and typed tool boundary. A later
OpenShell-backed Hermes adapter can implement it without granting the
language model a direct business writer. Do not replace or cut over the
private agent-runtime-platform while its standalone parity check is red.

## New: TaskCore-derived execution tickets

The dependency-free Elixir module
[TaskCore.AgentCandidates](../../apps/task_core/lib/task_core/agent_candidates.ex)
derives the exact seven-field Python sandbox ticket **only from the trusted
TaskCore replay**: a ready or in-progress task, its current version and last
accepted event ID, its DoD definition digest, and a live matching project-scoped
suggester grant. No source task title, personal data, agent signing key, grant
ID, or credentials are placed into the ticket.

The adapter intentionally requires **additional trusted host authorization**
before the task context may be read or execution may be dispatched. A
suggester grant is *not* a general-purpose task-read or execution grant.
The pure function is not the production authorization boundary, and its input
state is never accepted from an agent.

**Since this experiment was first authored**, TaskCore also gained
`TaskCore.AgentRuns` with operator-signed, serialized run-intent and
cancellation event types. See
[the signed run-intent ADR](../../docs/architecture/2026-10-24-signed-agent-runs.md).
It does **not** yet supply a durable coordinator/outbox or live tool proxy.

After the sandbox returns, the host must obtain CURRENT committed TaskCore
state and invoke AgentCandidates.current?/3 to refuse stale task revisions,
cancelled tasks and revoked grants. Even then, the candidate has no business
effect: typed suggestions, evidence custody, reviewer decisions and completion
must each pass their existing ledger gates.

The ticket payload shape is compatible across Elixir and Python; this still
does not wire a live API or introduce a second task/run ledger. Signed run
intents/cancellation now exist in the **same** CoopSubstrate ledger, but the
durable coordinator, runtime effects, safe retry and cancellation execution
remain separate implementation obligations.

## What the code demonstrates

The runner.py module uses NVIDIA's Python SDK calls create_from_template,
wait_ready, exec, delete, wait_deleted. It feeds a **fixed non-agent smoke
worker** a deliberately small immutable ticket, strictly validates the
candidate's scope/source, hashes its output, and returns a
**non-authoritative** in-memory receipt **only after cleanup**.
It never sends business credentials, reads the task DB, executes arbitrary
caller-provided shell commands, modifies policy, or calls an MCP/GraphQL writer.

Run offline tests (standard-library only, Python 3.11+):

    python3 -m unittest discover -s experiments/openshell_taskcore -p 'test_*.py' -v

The tests simulate success, nonzero exit, transport and readiness failures,
sandbox identity swap, mismatched task/source/scope, malformed/large output,
unsafe tickets, incorrect template, and cleanup failures.

### Manual gateway smoke (not admission integration)

An operator must provision an OpenShell gateway and a *reviewed* workload
template with a pinned Python-containing image and a restrictive policy
before running. The SDK/gateway should be pinned to the **same reviewed
OpenShell release**. Choose a template that does not need a network provider
or external credentials. Use an isolated staging workspace, narrowly scoped
gateway credentials, short resource/TTL limits, and a workspace quota. Do not
rely solely on labels or a template name as a security boundary; enforce
gateway RBAC and effective policy.

From a trusted local operator Python process after installing the reviewed
NVIDIA openshell SDK and registering a gateway:

    from experiments.openshell_taskcore.runner import local_smoke
    result = local_smoke(
        {
            "chapter_id": "demo", "tenant_id": "demo", "project_id": "demo",
            "task_id": "demo", "task_version": 1,
            "source_event_id": "demo-123",
            "definition_digest": "a" * 64,
        },
        workspace="staging",
        workload_template="reviewed-python-worker",
    )
    print(result)

The dummy values above do **not** establish an admitted task; the local
function intentionally provides no signature verification or ledger writes.
Do not expose it on a network endpoint or supply sensitive task content.
Successful smoke requires a live, configured gateway and the named template;
those have **not** been exercised as part of this stage. Failure to confirm
deletion must trigger out-of-band sandbox reconciliation before retrying.

## Future authoritative integration acceptance

- Validate signed actor/agent identity and **fresh** tenant/project grants
  inside the authoritative admission/dispatch boundary. Bind tickets to exact
  committed task revisions and artifact digests; do not treat a caller-supplied
  ticket as proof of authorization.
- Build a dispatcher for the now signed ledger run-intent/cancellation
  records with durable outbox, leases, recovery of orphans, result idempotency
  and sandbox-ID fencing. A post-append
  crash must not create a second business action or lose work.
- Prove revoke-while-running: ongoing sandbox access can be terminated, and
  revoked agents cannot append **new** commands. No permission should derive
  from the sandbox ID, output text, or stale projections.
- Add typed business tool proxy with independent authorization, no direct
  Postgres/ledger or long-lived secret access. OpenShell policy-prover coverage
  does **not** prove MCP/GraphQL application authorization.
- Link **verified custody** and any reviewer decision to task DoD. Neither
  stdout, its hash, nor OpenShell execution status completes a task.
- Demonstrate a genuine Hermes/Pi worker under OpenShell, plus a non-Hermes
  worker, conformance with Dispatch's agent port, staging end-to-end tests,
  runtime benchmarks (especially voice latency), and rollback to current
  Podman runtime.
- Preserve SchoolOps private learner boundaries and commerce/customer
  consent and Dispatch location permissions independently of sandbox policy.
- Address unresolved biz-kit session, administrative and DB CI security gates
  before granting agent write privileges in production.

**NVIDIA references** (review against a pinned tagged release, not floating
main): [OpenShell](https://github.com/NVIDIA/OpenShell),
[Python SDK](https://docs.nvidia.com/openshell/latest/sdk/python),
[Sandboxes](https://docs.nvidia.com/openshell/latest/how-it-works/sandboxes/overview),
[policy prover](https://docs.nvidia.com/openshell/latest/how-it-works/policies/prover),
[support matrix](https://docs.nvidia.com/openshell/latest/about/support-matrix).

**Internal boundaries:** [Task delegation](../../docs/architecture/2026-10-18-task-delegation.md),
[task core](../../docs/architecture/2026-10-20-task-core.md),
[one source of truth](../../docs/architecture/2026-10-11-single-source-of-truth.md),
[modular business platform](../../docs/architecture/2026-10-24-modular-business-platform.md).
