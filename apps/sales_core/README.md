# SalesCore: CRM pipeline, consent and campaigns

Pure, tenant-scoped rules for lead/opportunity progression, consent grant/
withdrawal and marketing audience plans. Two independent consumer classes
(restaurants and freight brokers) have conformance fixtures.

- An explicit evidence reference is required for each marketing grant.
- Only customer/business-contact categories are eligible for promotional
  grants; learner, guardian, driver and employee classifications never
  infer marketing permission.
- Channel and jurisdiction must match, and a withdrawal suppresses even a
  previously unknown contact. Fresh opt-in evidence is needed to regrant.
- A `Campaign.plan/5` result contains opaque IDs, no delivery transport,
  contact addresses or recipient PII. It is a *candidate*, not send approval.
- `Pipeline` requires a quote reference before marking a proposal won,
  but has no accounting, invoice or commission authority.

Eatsbot already has Telegram subscriber/promotion resources. The
`EatsbotCore.Marketing.ConsentBridge` refuses to automatically upgrade
legacy subscribed rows without new cross-domain evidence, and recognizes
unsubscribed records as suppressed. It does not mutate those tables.

Run `mix test --no-start` from `apps/sales_core`.
