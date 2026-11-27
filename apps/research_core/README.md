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
