# Shared sales and marketing capability: scope and acceptance

Linked issue #84; 2026-10-24. Pure contract slice.

Existing Eatsbot Marketing has branch-scoped Telegram subscriptions, promotions,
attribution and explicit unsubscribe. Those existing resource policies and
transport remain authoritative: this PR does **not** move subscriber addresses
or send promotions.

Introduces tenant-scoped, replayable consent decisions, default-deny audience
selection and a generic opportunity/quote pipeline. Restaurant and freight
broker fixtures are the first two domain consumers. No learner, guardian,
driver or employee identity becomes a promotional audience by role inference.
Transactional/service notices must have a separate authorization basis and
cannot be sent through this marketing planner by claiming a customer role.

Still required before production CRM/campaign service: verified identity
and party links, contact encryption/retention, jurisdictional policy,
evidence custody, authenticated consent recording, append serialization,
duplicate notification delivery controls, opt-out race/retry tests and deletion
versus immutable-audit design. Public Git stores no contact addresses.

Shared `SalesCore` policy is not a marketing transport, billing system or
complete CRM data store. A future host must validate the current consent
watermark immediately before delivery, and be able to suppress scheduled
messages after withdrawal across all relevant channels.
