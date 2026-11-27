# FieldWitness in biz-kit: research sovereignty and sponsorship boundary

Date: 2026-11-27. Status: **phase-1 pure ResearchCore only; no live integration**.
This is an implementation contract, not an assertion of research/ethics
approval, financial licensure, or deployed archival custody.

## Product and authority

FieldWitness is a new research and cultural-preservation domain in biz-kit,
not a second operator ledger or financial platform. Research institutions and
eligible producer-cooperative businesses can make documented B2B sponsorship
agreements, subject to their own principal/agency permissions. Individuals may
support a separate public sponsorship channel through a qualified external
provider; they do not thereby enter the producer-only B2B marketplace or
receive cooperative shares.

A research project maps to the existing `{chapter, tenant, project}` TaskCore
scope, with an accountable human project owner and independently checked
operator grants. Ownership and ordinary grants do **not** confer narrator
consent, community cultural authority, ethics approval, content access or
publication rights. Sponsorship does not purchase historical conclusions or
the narrator's testimony.

| Domain | Existing substrate | New obligation |
| --- | --- | --- |
| Organization and operator | Keel, BizKit Identity, TaskCore project grants | Researcher credentials and community-representative authority evidence |
| Research work | TaskCore/TaskHost; signed task/DoD evidence | Ethics reviews, narrator participation, consent, field sessions |
| Media custody | CoopSubstrate artifact receipts and out-of-ledger bytes | Private encrypted large-blob store, retention/withdrawal, reliable key lifecycle |
| Provenance | Exact source/custody receipts, project knowledge review | Senad+-compatible segment/transcript lineage and independent verifier |
| Funding | CommerceCore, SCF Core conceptual adapters | Typed external payment/donation/grant reconciliation and controlled milestone release |
| Automation | AgentCore bounded execution | Machine-generated transcripts labeled as such and requiring human review |

## Pure phase-1 contract (implemented)

`apps/research_core/lib/research_core/access.ex` provides an inert, dependency-free
decision kernel. `new_record/4` accepts exactly one chapter/tenant/project
scope, a record identity, 1–32 unique narrator identifiers and one community
identity. Identities here are **caller-asserted** and not authenticated.

`review/7` grants or revokes one exact material
(`:audio`, `:transcript`, `:excerpt`) and audience
(`:research`, `:public`) pair under an optimistic record revision.
Only an exact listed narrator or the listed community may be *proposed* as
the actor; neither `:sponsor` nor `:operator` is a consent role. These pure
operations are not signed commands or evidence of consent.

`release_eligible?/4` requires an active grant from **every** narrator and
the community for the exact material and audience. It is never enough for
authorization: the future host must separately enforce signer identity,
revocation, ethics approval, recipient permissions, time/retention policy,
artifact availability and record-currentness at delivery. In particular,
granting public excerpts never grants access to raw audio or translations.

## Integration rules — DO NOT shortcut

1. Admit versioned reviews through existing CoopSubstrate signed authority,
   and retain exact source identity, current revision, event hash, signer key
   epoch, policy revision and withdrawal provenance. Refuse forged, stale or
   cross-project commands. A signed business grant cannot silently become a
   cultural grant.
2. Store raw audio/video and transcripts **outside** the immutable ledger.
   Hashes, aliases, recording metadata and even pseudonymous identifiers
   can reveal sensitive facts; avoid posting them in public commitments.
   Existing `ArtifactCustodyRecordedV1` is project-scoped but the current
   evidence path is limited to 8 MiB per artifact/16 MiB per operation. Do
   not route large interview recordings through that path without a reviewed
   private large-blob adapter and an independent custody check.
3. Support individual consent and independently evidenced community cultural
   authority. Cultural protocols and traditional-knowledge labels are not
   a substitute for the consent of the actual narrators. If authority is
   disputed or withdrawn, content access remains denied pending review.
4. Withdrawal must fail closed on **new** reads/downloads and publication
   requests, without rewriting historical signed events. Previously exported
   media cannot be recalled; explain this limitation in consent materials.
   Account for retention and deletion obligations, backups and any lawful hold.
5. Separate sponsorship **pledge**, **payment receipt**, **grant restriction**,
   **milestone acceptance** and **authorized disbursement**. None of the pure
   research kernel moves funds. An external provider handles custody/payments.
   Procurement, annual USD 250 producer-coop capital, asset shares, legacy
   patronage, setoff and optional investments are not interchangeable with
   grant/donation/service receipts. No new finance writer is admitted here.
6. Generated transcripts, translations, interpretations and oral testimony
   must preserve provenance and uncertainty. File integrity and attributable
   review do not establish historical truth or scientific validation.

## Verification boundary

The first executable conformance controls are
`apps/research_core/test/access_test.exs`:

* FW-1: the unopened/unsigned state cannot release any material.
* FW-2: all narrators AND community are necessary (all 8 subsets covered).
* FW-3: sponsor/operator/governance keys are not cultural consent.
* FW-4: exact audience, material and project scope cannot be widened.
* FW-5: stale reviews and duplicate/no-op reviews are refused.
* FW-6: withdrawal blocks future release eligibility.
* FW-7: accepted action streams replay deterministically.

This is **Elixir executable evidence**, not a Lean proof, deployed gate,
independent verifier, lawful payment route, or end-to-end consent enforcement.

Next formal tasks: Lean model of the record grant-set transition, safety and
revocation theorems; Quint trace model including concurrent host reads,
key revocation and stale writes; executable correspondence against the Elixir
transition function; mutation controls and exact-source replay.

Next integration tasks: signed event schemas and host commands, private
large-object archive with a reader fence, qualified ethics/community review,
grant-service agreements with external settlement receipts, and a scoped
field application. Publication must remain blocked until those gates exist.

Related sources: `docs/architecture/2026-11-02-project-ownership.md`,
`2026-10-12-artifact-custody.md`, `2026-11-14-project-knowledge.md`,
`2026-11-07-producer-coop-at-cost-capital-pooling.md` and
`2026-11-13-producer-capital-integration.md`.
