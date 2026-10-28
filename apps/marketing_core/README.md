# MarketingCore — pure Eatsbot salvage (first slice)

Source: Eatsbot \`Marketing.Attribution\`, \`Touchpoint\`, \`Visit\`.
This package is independent of Ash, PostgreSQL, Telegram and the umbrella.
No production writer, dispatcher, sender, customer contact database or financial
authority is created.

- \`Attribution.eligible?/3\` requires **confirmed** delivery evidence; a queued
  notification is not a qualifying visit. Uses microsecond-precise intervals.
- \`Touchpoint.code/1\` preserves Eatsbot's non-ambiguous public QR/NFC code
  generation, not Hawala participant identity or transaction QR consent.
- \`Redemption\` preserves checked-in rate snapshots and one-use idempotency.
  Commission rounding uses explicit integer ppm half-up: **not yet a proof of
  legacy Money/Decimal arithmetic parity** or owed/settled financial state.

A production host must validate SalesCore consent, sender receipts, merchant
scope, promotion validity, cashier grants, touchpoint/code uniqueness and
persist signed admissible events. This standalone pure kernel does none of that.

Run \`cd apps/marketing_core && mix test --no-start\` or use the dedicated
portable CI lane. The retirement plan and tracking issue are in biz-kit #175/#176.
