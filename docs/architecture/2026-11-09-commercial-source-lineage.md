# Commercial Source Lineage — Signed-Core Replay (November 9, 2026)

Status: **business-accounting read projection only**; no new legal, financial,
or administrative authority. Supersedes no historical signed event.

## Motivation

The existing source-bound proof proposal and merged
`CommercialSetoffIntentRecordedV1` bind exact projected debt IDs, balances
and counterparties, but do **not** bind the original signed source
event's immutable provenance or every intervening assignment/closure.
P0 issue #299 demands a live serialized source-level fence and independently
authenticated trade/legal evidence before a source-bound discharge can be
enabled. This PR implements a prerequisite **lineage read model only**.

## What this increment adds

`CoopSubstrate.CommercialSourceLineage` is derived entirely from the same
canonical business signed-event stream as `Membership.obligations`. Its
`commercial_source_lineage[{chapter, obligation_id}]` stores:

- `original_signed_core_digest`: SHA-256 of
  `Envelope.signing_bytes/1` from the *original*
  `ObligationRecorded` event; its source signers authenticate these bytes.
- `latest_signed_core_digest`: signed-core SHA-256 for the last
  assignment or discharge event; a pointer to a signed event core,
  **not** a full event-record hash.
- `source_revision`: 1 at original recording; incremented at each
  assignment or discharge applied by the canonical fold.
- `source_kind`: original attested, assigned,
  direct-discharge-attested, legacy-netting-closed, or
  legacy-netting-derived residual.
- `original_only` and `open`: conservative read-only eligibility.
  Original-only eligibility turns false irreversibly on assignment even if
  the debtor is subsequently assigned back.
- `legal_effect: :not_verified` and `financial_settlement: :none`
  as explicit nonclaims.

During `NettingExecuted` historical replay, the implementation finds the
*same currently open bilateral, same-denomination source obligations*
that the existing membership projection closes, and marks their
lineage closed. Any residual claim inserted by that event is flagged as
`legacy_netting_residual`, without a genuine original
`ObligationRecorded` source core. This does not alter the legacy signed
netting schema or its already existing effect.

No additional writer or physical ledger exists. Every bit of lineage state
is rebuilt deterministically from authenticated events in the existing
`CoopSubstrate.Log` on restart.

## Important distinctions

The original signed **core** hash is not
`CoopSubstrate.Protocol.Envelope.event_hash/1`: the latter includes the
log-assigned sequence/chain fields and signatures. The signed core is
available inside the serialized appender's *pre-assignment* fold, so its
digest is stable between proposed and committed objects; the core is
nevertheless authenticated by the accepted Ed25519 signatures.

This does NOT verify that a sale actually happened or that a member is an
authorized agent of an independently identified business. It does NOT
authenticate foreign-node evidence, establish a legal setoff agreement or
discharge, protect against source reuse, establish sanctions/licensing
permissions, or instruct any bank/crypto settlement provider.

The new read projection does not itself prohibit legacy aggregate-signed
`NettingExecuted`; that remains the P0 bypass requiring a separate
protected execution profile and migration rule.

## Acceptance and failure controls

The executable test suite must demonstrate that:

1. An accepted, dual-signed original obligation produces the same signed
   core digest as independent `Envelope.signing_bytes/1` replay.
2. Restarting the canonical Log reproduces the exact lineage map.
3. Assigning an obligation away and then back does not recover its
   original-only eligibility; its revision increases.
4. Direct discharge and legacy bilateral netting close source eligibility.
5. A legacy netting residual remains a *derived* accounting claim, not a
   newly verified invoice or origin-only source.
6. No financial balance, held customer value, payment instruction, or
   legally effective discharge is created by this projection.

Changes to business financial disposition must remain under the existing
signed append gate and its independently established legal controls.

## Follow-on before source-bound discharge

A new versioned signed **commercial discharge** event must cryptographically
bind full original source-event hashes/revisions and signed actor,
agency, legal-effect and jurisdiction evidence. Its serialized gate must
revalidate the exact current sources, source lineage, and unique
source-level fence atomically with posting. A pure signed-core digest and
a caller-supplied Boolean legal decision cannot substitute for that evidence.
An explicit protected profile must prevent the historic aggregate-signed
netting route from bypassing the new requirement while preserving historical
event replay. Multilateral/cross-node settlement requires separate
proofs of conditional agreement and conservative HELD recovery.

Related: merged #344, #298, #342; open P0 #299 and audit #290.
