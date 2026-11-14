# BizOps workflow preview and explicit adoption

Date: 2026-11-14. Status: implemented source contract; live deployment and
engagement-specific adoption require their own evidence.

## Purpose and source selection

The [reference catalog](2026-11-14-bizops-kb-catalog.md) makes procedures
readable. This increment adds a concrete workflow that governance can review
and adopt through the existing TaskCore hierarchy. It creates no new business
ledger or execution adapter.

The source catalog deliberately selects `larsbx/bizops-kb` commit
`8749d8db1abd3145b22c6a27da2cc49a41c303fe`, tree
`79f146858c5d9d850df69b67294cb3fabf131bd1`. The upstream README and custody ADR
now describe Biz-kit as the selected integration target during SpruceGoose's
migration. Both procedure bodies remain byte-identical to the first import.
The catalog retains all 216 Markdown files, their original paths and an
independently verifiable raw commit/tree proof.

| Source | SHA-256 | Purpose |
| --- | --- | --- |
| `24.12` — Hermes assistant on-site deployment | `0803f0b19737eae54b6df585fac4e5136d7fbadb151873b90aa6227e7df20c34` | Preparation, discovery, office setup, enrollment and handoff |
| `24.12d` — Hermes assistant owner sign-off | `7fa0018dee855d5a3dd6f542914ac0bb98fc1df83d1e189bc925826e66732d53` | Owner Part A before setup and witnessed Part B acceptance |

These are public reference copies under the owner's copying authorization.
They contain blank sign-off templates, not completed company records. Actual
engagement records and evidence belong in their authorized project scope.
No source ownership or historical publication authority transfers here.

## The reviewed adaptation

The version-1 manifest lives at
`apps/bizops_kb/priv/workflows/office-assistant-onboarding-v1.json`. It is a real
schema-2 blueprint in JSON syntax, which the existing YAML reader accepts.
Its project key is `office-assistant`, roadmap is `office-setup`, and workflow
is `office-onboarding`.

| Task | Depends on | Completion evidence |
| --- | --- | --- |
| Owner scope | — | Signed Part A, restricted list, two key holders, current stack/channel decisions, data terms and risk acknowledgements |
| Preflight | Owner scope | Staff/device roster, tested signed installer, isolated cloud stack, network ACLs and prepared references |
| Discovery | Owner scope | Role use cases, machine audit, classified document inventory, owner-reviewed index and folder plan |
| Office zone | Preflight, discovery | Vault/upload and sync tests, successful backup restore, two-employee pilot |
| Staff enrollment | Office zone | Every employee's round-trips and upload tests, restricted-chat refusal, device/department isolation |
| Staff training | Staff enrollment | Training attendance, quick cards, safe-use and escalation demonstration |
| Admin handoff | Staff enrollment | Witnessed add/revoke with support, sync cutoff before tailnet removal, support and key-holder handoff |
| Owner acceptance | Staff training, admin handoff | All Part B evidence, owner and installer signatures, accepted open items and follow-up date |

The first task requires confirmation of the current engagement and stack.
Historical product names in source prose do not prove that a corresponding
service is installed, authorized or current. Companion notes remain references
to select and review for that engagement; this bundle contains only the two
named source procedures. Completion criteria use the existing evidence and
review process, including the review of owner signatures.

## Binding the procedures to an adopted workflow

`TaskCore.Blueprint` accepts an optional `readiness_contract` on a workflow.
The [portable contract](../../apps/task_core/docs/source-bound-workflows.md)
defines its strict, versioned shape:

```json
{
  "schema_version": 1,
  "sop_digest": "<SHA-256 of retained SOP bundle>",
  "sop_version": "1.0.0",
  "input_digests": {
    "source_24_12": "<SHA-256 of original deployment procedure>",
    "source_24_12d": "<SHA-256 of original owner sign-off procedure>"
  },
  "manifest_input": "workflow_manifest"
}
```

Every task requires exactly those two named inputs plus `workflow_manifest`.
The SOP artifact, `office-assistant-onboarding-v1.sop.md`, contains the selected
source repository, commit, tree, paths, hashes and original document bytes,
with a versioned explanatory wrapper. `BizOpsKB.Workflows` reproduces that
bundle from the loaded catalog and requires byte equality with the retained
artifact, then verifies its digest and both source digests against the blueprint.
Missing artifacts, changed sources, a different catalog revision, malformed
schema and altered pins make the preview/download unavailable.

At `TaskBlueprintAppliedV1` fold, TaskCore resolves `workflow_manifest` to the
event's exact retained manifest digest. This avoids making a manifest contain
its own hash. Each instantiated task carries the same resolved contract.
`TaskReadinessDefinedV1` admission checks the SOP digest, version and complete
input-digest map, including when a caller bypasses the run-readiness helper.
Contract mismatches return `blueprint_readiness_contract_mismatch` without
changing business state; existing validation may reject malformed or stale
definitions earlier. A new blueprint revision cannot silently change an existing
run's bindings. Existing schema-2 workflows without this optional contract
retain their previous behavior.

The contract fixes readiness inputs. It does not replace governance or freeze
all task text: the existing governance command for revising completion criteria
on proposed tasks still applies. Governance must review any such change.

## Browse and download

Open `/operations/knowledge?workflow=office-assistant-onboarding-v1`, choose
**Workflow previews**, or follow the related workflow from either source note.
The page shows tasks, dependencies, completion criteria, original source links
and exact adoption/input digests. It offers the exact manifest and SOP bytes.

The preview and downloads require the same current session and Operations
workspace access as the catalog, rechecked before response. All use `no-store`;
attachments additionally use a restrictive content policy. Revocation and
logout clear preview data. The endpoints only read:

- `GET /api/v1/operations/knowledge/workflows/:id`
- `GET /api/v1/operations/knowledge/workflows/:id/manifest`
- `GET /api/v1/operations/knowledge/workflows/:id/sop`

An unavailable workflow does not prevent browsing an otherwise valid catalog.
The page does not sign an adoption or instantiate tasks.

Browser download URLs also carry `expected_sha256`, the digest displayed in the
preview. The host refuses a different artifact with HTTP 409
`stale_workflow_preview`; refreshing selects the new preview explicitly.
Malformed pins return 400. A direct API call without this optional pin requests
the current verified artifact, so automated consumers should supply the pin.

## Explicit adoption from a selected Git commit

Use a trusted checkout containing the reviewed commit, Git 2.45 or later, the
existing governance key configuration and the intended TaskHost server. Select
the full commit explicitly; do not use a moving branch as the adoption identity.

```sh
mix coop.blueprint CHAPTER/TENANT/office-assistant \
  larsbx/biz-kit REVIEWED_FULL_40_CHARACTER_COMMIT \
  apps/bizops_kb/priv/workflows/office-assistant-onboarding-v1.json \
  --source-checkout /path/to/biz-kit \
  --server https://your-task-host.example
```

The new local verifier reads raw Git objects with replacement objects and lazy
fetch disabled. It verifies the requested commit's hash, each directory tree
and the final regular blob, and bounds object sizes. It never executes the
manifest or reads its working-tree replacement. The checkout's GitHub origin
must match the repository label; that check is label consistency, not proof of
remote authentication or a signing-key trust decision. The caller selects the
trusted commit. The default Forgejo verifier remains available when
`--source-checkout` is omitted; this increment adds no GitHub HTTP verifier.

The CLI shows the source and workflow, asks for confirmation unless explicitly
passed `--yes`, and uses `Blueprints.expected?` before signing. The server
retains the exact bytes and admits the existing governance event. Adopting
this blueprint records a template, with no task run or deployment effect.

An authorized operator separately instantiates `office-setup/office-onboarding`
under that revision in the owned project. After tasks are proposed, governance
uses the existing run-readiness controls, taking the SOP version/digest and
three required input digests from the preview. The inputs are the exact two
original Markdown files and adopted manifest. The ordinary scoped custody
path permits their storage once readiness names them. Each operator must
acknowledge the exact SOP, and task start still checks actual bytes and
predecessors. Evidence review and completion remain separate signed actions.

## Acceptance and remaining boundary

Catalog/workflow tests exercise actual schema normalization, source/bundle
binding, DAG order, changed revisions and bytes, malformed JSON, unknown paths,
symlinks and missing artifacts. TaskCore tests cover strict contract validation,
binding at adoption, replay and direct readiness attempts with substituted
digests. Local Git tests cover immutable object selection and refusal paths.

TaskHost acceptance uses a synthetic Git repository and synthetic principals
with the actual manifest, CLI, HTTP, signatures and common ledger. It covers
adoption separately from run creation, readiness refusal/acceptance and task
start prerequisites. Browser acceptance covers preview navigation, digest-checked
downloads, access revocation and logout. Record actual local and hosted results
at the evaluated revision; declaring a test does not establish that it passed.
The existing Quint lifecycle model abstracts readiness to a boolean; the new
digest equality contract is covered by executable tests, not that abstraction.

This increment establishes no live office deployment, real customer sign-off,
knowledge publication/withdrawal ledger, Redis index, document-delivery job,
legacy writer cutover or permission transfer from SpruceGoose.
