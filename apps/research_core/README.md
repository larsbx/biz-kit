# FieldWitness ResearchCore — pure boundary

This dependency-free umbrella app is the first, **inert** integration increment
for sponsoring field anthropology, ethnography, and oral-history preservation
in biz-kit. It contains no writer, HTTP endpoint, identity provider, payments,
recording upload, participant roster, archive, or public publication system.

`ResearchCore.Access` models only the **release-eligibility conjunction**:

* Every named narrator has an active grant for the exact material and audience.
* The named community also has an active grant for that same pair.
* Scope, record identity, current revision and permitted reviewer kinds are exact.
* A financial sponsor, project owner, operator, agent or reviewer is not thereby
  a narrator or community authority.
* Withdrawal removes eligibility for **future** releases; it cannot retract
  previously exported or downloaded recordings.

The host MUST first verify each narrator's identity and each community
representative's authority, then authenticate/sign/commit versioned review
events against authoritative replay state. A successful `release_eligible?/4`
result is only one condition for release, never a download authorization.

Run `cd apps/research_core && mix test --no-start` on Elixir 1.19.
See [the design boundary](../../docs/architecture/2026-11-27-fieldwitness-biz-kit-boundary.md)
for finance, privacy, custody, migration and formal-proof obligations.

## Signed review-intent preflight

`ResearchCore.SignedReviews` verifies a domain-separated, exact-scope
Ed25519 intent under a **host-supplied current authority** mapping (actor, key,
epoch, scope). It refuses stale revisions, tampering and revoked/rotated keys
when the host provides their correct current state. It performs no signing-key
registration, event append, signature custody or authorization for downloads.

Do not let sponsors or API clients supply the trusted authority mapping.
A future CoopSubstrate integration must resolve identity, cultural authority,
key epochs, source revisions and approvals from the serialized signed log.
