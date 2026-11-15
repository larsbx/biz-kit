# Procurement contract review V1

This implements an inert subset of the [Hanbali taxonomy](2026-11-13-hanbali-commercial-contract-taxonomy.md), sections 3.1, 3.2 and 7. The private Elixir entry point is `CoopSubstrate.Procurement.review_contract/3`. It signs the exact record and evaluates it in the Log mailbox against the current operator grant, business enrollments and accepted or fulfilled order revision. The read envelope cannot be appended. Reviews can be repeated and are evaluated against the current snapshot each time.

| Candidate | Purchase invoice and ownership | Order seller | Goods consideration |
| --- | --- | --- | --- |
| Wakalah | Supplier invoices the member. Evidence shows member ownership and a current mandate for the cooperative, covering the supplier, goods, quantity, currency, spend and fee. | Supplier | Original supplier goods price. Agency compensation is separately agreed and supported. |
| Musawamah | Supplier invoices the cooperative. Evidence shows the cooperative acquired and possessed the identified goods before resale. | Cooperative | Negotiated goods price. The record carries no acquisition-cost assertion. |
| Tawliyah | Same ownership sequence as musawamah. | Cooperative | The asserted acquisition cost and resale goods price must both match the original supplier goods price. Service charges are separate. |

The record binds its schema version, exact request and quote revisions, legal entities, identified goods, quantity, currency, consideration, service charge, delivery site and timing, payment due date, purchase and agreement times, and an opaque case reference. The existing quote total represents goods consideration in this review. The separate service amount requires its own cost and assent evidence. V1 covers one supplier and a single fixed payment due date.

A trusted `CoopSubstrate.ProcurementContractEvidence` implementation must resolve private, case-scoped evidence. It attests party authority and assent to the canonical record digest, maps the cooperative to its enrolled legal identity, and verifies source documents and current mandate status. The integration suite supplies a synthetic resolver. The review fails closed in an installation without a resolver. No UI or production resolver is configured by this change.

A positive result is a private `validated_inert` observation. The result includes a record digest and observation time, with doctrinal adoption and civil applicability independently undetermined and runtime activation inactive. The ledger head, admission gate and event history remain identical across the read. The result confers no permission to post accounting, settle, transfer title or issue financial rights.

The procurement host acceptance script runs the new ExUnit cases against disposable PostgreSQL. `formal/lean/check.sh` builds and replays the abstract role, title, cost and accounting-authority obligations. The Lean statements model normalized evidence and the read boundary. ExUnit checks the runtime path using synthetic evidence.
