# SalesCore consent event wire contract, v1

`SalesCore.ConsentWire.decode/2` defines a narrow decoded-JSON boundary,
`bizkit.sales.consent.v1`, for cross-domain marketing preference commands.

No client can choose an authenticated principal, authorizing role, trusted
clock, evidence verification or tenant scope by including JSON fields. Those
come from the already authorized host context: merchant tenant, party
binding, allowed operations, verified consent receipt and timestamp.
Grant requires a matching previously verified receipt; withdrawal does not
require any marketing evidence to avoid obstructing opt-out.

Only explicit `customer` and `business_contact` promotional audience classes
are accepted. Learner, guardian, employee or driver roles never create
promotional opt-in. Channels use a fixed vocabulary, with no dynamic atoms.

This parser intentionally cannot decide the legality of marketing contact:
the host still must verify valid proof, lawful basis and jurisdiction,
retention, authenticated session and party ownership, suppression events
and an authoritative serialized append. Any message dispatcher must check
the **latest** revocation state immediately before sending.

Duplicate raw JSON object keys must be rejected by the byte-decoder
before constructing this map; once a decoder collapses them, a map parser
cannot detect them.

No user PII, contact addresses, messaging credentials, customer databases,
notification endpoints or new ledger writer are introduced by this contract.
